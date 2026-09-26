#!/usr/bin/env bash
#
# The seeded month is closed.
#
# The v1 Definition of Done states one master gate: after a seeded month is
# posted AND THE PERIOD CLOSED, the four ties hold. The build did the first half
# and not the second. supabase/ci/seed_demo.sql posts a month of trading into
# ci-demo and supabase/ci/run_checks.sh asserts the ties over it — but nothing
# in .github or supabase/ci had ever called erp.close_period() at all. Every
# close in the repository happened inside a suite that builds a throwaway
# organisation of its own and posts a handful of documents into it, so the four
# close tasks made unwaivable on 17 September (20260918400000, and the ageing
# task of 20260918510000) had never once been asked about real data.
#
# Ties asserted outside a close are a weaker claim than the one the Definition
# of Done makes. A close runs the same assertions THROUGH THE CONTROL: the
# checklist is raised, each task's blocking check runs where it cannot be
# ticked past, and the close runs them again before anything shuts.
#
# So this closes the month the seed posted into, as the demonstration
# organisation's administrator, through the doors a person uses:
#
#   1. public.erp_configure_period_close() — the Period close module, installed
#      the way /administration/configuration installs it.
#      erp.ensure_demo_configuration() installs six modules and this is not one
#      of them, so a demonstration organisation has no close checklist until
#      somebody asks for one, and erp.close_period() rightly refuses a period
#      that has nothing saying it is ready (CLOVEERP_CLOSE_NO_TASKS).
#   2. public.erp_open_period_close() — the first of the close's two presses
#      (20260929200000). It raises the checklist onto the period, opens the
#      month's COMMIT period with it, and runs every task's check, completing
#      each one that passes.
#   3. public.erp_complete_close_task(task, null) for anything the opening
#      left open, in dependency order, WITH NO WAIVER REASON. On the seeded
#      month there should be nothing: the four tie tasks are unwaivable and the
#      other two carry a check, so each passes on the month's own figures, and
#      a task left open is completed here only so that its refusal names the
#      difference and this step goes red with it. A waiver would turn the
#      master gate back into a tick box, so there is deliberately no way to
#      pass one from here.
#   4. public.erp_close_period() — the second press. It runs every completed
#      task's check again and closes GL and COMMIT together.
#
# Then it reads back that every task finished 'complete' rather than 'waived',
# that four of them were ties, that the opening left nothing to tick, and that
# the month is 'closed' on GL and on every ledger that closes with it, at one
# moment.
# supabase/ci/ties_thrice.sh runs the four ties three times over afterwards.
#
# Reads PSQL from the environment like run_checks.sh.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"

started=$(date +%s%N)

$PSQL_CMD <<'SQL'
\set ON_ERROR_STOP on

begin;

-- As the demonstration organisation's administrator. The impersonation is
-- transaction-local, like every context (supabase/ci/drain_rehearsal.sh).
select t.id as tenant_id from erp.tenant t where t.code = 'ci-demo' \gset
select u.auth_user_id as admin_auth
  from erp.app_user u
 where u.tenant_id = :'tenant_id' and u.email = 'admin@ci-demo.test' \gset
select set_config('request.jwt.claims',
                  json_build_object('sub', :'admin_auth')::text, true) as ctx \gset

-- 1. The checklist the organisation has never installed.
do $install$
begin
  if not exists (select 1 from erp.change_set c
                  where c.tenant_id = erp.require_tenant_id()
                    and c.code = 'period-close') then
    perform public.erp_configure_period_close();
  end if;
end
$install$;

-- The month the seed posted into: the period of the primary ledger holding the
-- earliest document in the organisation. Derived rather than repeating the
-- arithmetic seed_demo.sql uses, so a change to the seed's dates moves this
-- with it instead of quietly closing an empty month. The read below refuses
-- none and refuses two.
create temp table ci_month as
  select fp.id as period_id, fp.code as period_code, fp.status as status_before
    from erp.fiscal_period fp
    join erp.ledger l on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
   where fp.tenant_id = erp.require_tenant_id()
     and l.is_primary
     and (select min(d.document_date) from erp.document d
           where d.tenant_id = erp.require_tenant_id())
         between fp.starts_on and fp.ends_on;

select period_id, period_code, status_before from pg_temp.ci_month \gset

\echo '── closing' :period_code 'of ci-demo, which is' :status_before

do $ready$
declare m record;
begin
  select * into m from pg_temp.ci_month;
  if m.status_before <> 'open' then
    raise exception 'CLOVEERP_CI_MONTH_NOT_OPEN: the seeded month % is % before the build has closed anything',
      m.period_code, m.status_before
      using hint = 'Something else closed it first. The build seeds and closes once.';
  end if;
end
$ready$;

-- 2. The checklist onto the period.
select public.erp_open_period_close(:'period_id') as tasks_raised \gset
\echo '── checklist raised:' :tasks_raised 'task(s)'

-- 3. What the opening left open, in the order its dependencies allow, with no
-- waiver reason: a failing check refuses here, naming the difference.
create temp table ci_close_result (
  seq integer, code text, waivable boolean, check_name text, answer text, by_opening boolean);

do $tick$
declare
  r     record;
  v_out text;
begin
  for r in select t.id, t.seq, t.code, t.is_waivable, t.blocking_check, t.status, t.check_output
             from erp.close_task t
            where t.tenant_id = erp.require_tenant_id()
              and t.fiscal_period_id = (select period_id from pg_temp.ci_month)
            order by t.seq, t.code
  loop
    if r.status = 'complete' then
      v_out := coalesce(r.check_output, 'complete');
    else
      v_out := public.erp_complete_close_task(r.id, null);
    end if;
    insert into pg_temp.ci_close_result
    values (r.seq, r.code, r.is_waivable,
            coalesce(r.blocking_check, '(no check)'), v_out, r.status = 'complete');
  end loop;
end
$tick$;

select lpad(seq::text, 3) || '  ' || rpad(code, 22) || '  '
       || case when waivable then 'waivable' else 'TIE     ' end || '  '
       || rpad(check_name, 40) || '  '
       || case when by_opening then '' else '(ticked) ' end || answer as checklist
  from pg_temp.ci_close_result order by seq, code;

-- 4. Closed, on every ledger of the month.
select public.erp_close_period(:'period_id');

-- Read back. "The period says closed" and "nothing was waived to get it there"
-- are different claims, and the second is the one this step exists for.
do $proved$
declare
  m        record;
  v_status text;
  v_waived text;
  v_ties   integer;
  v_ticked text;
  v_half   text;
  v_sibs   integer;
begin
  select * into m from pg_temp.ci_month;

  select fp.status::text into v_status
    from erp.fiscal_period fp
   where fp.tenant_id = erp.require_tenant_id() and fp.id = m.period_id;

  if v_status is distinct from 'closed' then
    raise exception 'CLOVEERP_CI_MONTH_NOT_CLOSED: % is % after erp.close_period()',
      m.period_code, coalesce(v_status, 'gone');
  end if;

  select string_agg(format('%s (%s)', t.code, coalesce(t.waiver_reason, 'no reason given')),
                    ', ' order by t.seq)
    into v_waived
    from erp.close_task t
   where t.tenant_id = erp.require_tenant_id()
     and t.fiscal_period_id = m.period_id
     and t.status <> 'complete';

  if v_waived is not null then
    raise exception 'CLOVEERP_CI_CLOSE_WAS_WAIVED: % closed with %', m.period_code, v_waived
      using hint = 'The close is the gate the Definition of Done names only if every task passed on its own figures.';
  end if;

  select count(*) into v_ties
    from erp.close_task t
   where t.tenant_id = erp.require_tenant_id()
     and t.fiscal_period_id = m.period_id
     and not t.is_waivable;

  if v_ties < 4 then
    raise exception 'CLOVEERP_CI_TIES_MISSING: % carried % unwaivable tie task(s), not four',
      m.period_code, v_ties
      using hint = 'The four ties are the trial balance, the inventory valuation, the subledgers and the ageing. A close carrying fewer is not the master gate.';
  end if;

  -- Two presses: the opening completed every task, so nothing was ticked.
  select string_agg(r.code, ', ' order by r.seq) into v_ticked
    from pg_temp.ci_close_result r where not r.by_opening;
  if v_ticked is not null then
    raise exception 'CLOVEERP_CI_CLOSE_NOT_TWO_PRESSES: the opening of % left % to be ticked by hand', m.period_code, v_ticked
      using hint = 'Opening the close runs every task''s check and completes each that passes (20260929200000). A task it leaves open either has no check or failed one.';
  end if;

  -- And the month is closed on every ledger that closes with it, at one moment.
  select count(*),
         string_agg(format('%s %s', l.code, fp.status), ', ')
           filter (where fp.status <> 'closed' or fp.closed_at is distinct from gl.closed_at)
    into v_sibs, v_half
    from erp.period_siblings(m.period_id) s(id)
    join erp.fiscal_period fp on fp.tenant_id = erp.require_tenant_id() and fp.id = s.id
    join erp.ledger l on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
    cross join (select g.closed_at from erp.fiscal_period g
                 where g.tenant_id = erp.require_tenant_id() and g.id = m.period_id) gl;

  if v_sibs = 0 or v_half is not null then
    raise exception 'CLOVEERP_CI_MONTH_HALF_CLOSED: % closed on GL and not with %', m.period_code,
      coalesce(v_half, 'any other ledger: it has no sibling')
      using hint = 'erp.close_period() closes the month''s statutory and management ledgers together (20260929200000).';
  end if;

  raise warning '% is closed on % ledger(s) at one moment: % tie task(s), none waived, none ticked by hand',
    m.period_code, v_sibs + 1, v_ties;
end
$proved$;

commit;
SQL

wall_ms=$(( ($(date +%s%N) - started) / 1000000 ))
echo "the seeded month closed in ${wall_ms} ms"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## The seeded month is closed"
    echo "ci-demo's seeded month closed through the doors in two presses and ${wall_ms} ms, on GL and COMMIT together: every close task complete, none waived, four of them ties."
  } >> "$GITHUB_STEP_SUMMARY"
fi
