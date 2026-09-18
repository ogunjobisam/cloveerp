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
# checklist is raised, each task is ticked, and each tick runs its blocking
# check inside erp.complete_close_task(), where it cannot be ticked past.
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
#   2. public.erp_open_period_close() — raises the checklist onto the period.
#   3. public.erp_complete_close_task(task, null) for every task in its
#      dependency order, WITH NO WAIVER REASON. That is the whole point: the
#      four tie tasks are unwaivable and the other two carry a check or nothing,
#      so each one either passes on the seeded month's own figures or this step
#      goes red with the difference named. A waiver would turn the master gate
#      back into a tick box, so there is deliberately no way to pass one from
#      here.
#   4. public.erp_close_period() — and the month is closed.
#
# Then it reads back that every task finished 'complete' rather than 'waived',
# that four of them were ties, and that the period's status is 'closed'.
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

-- 3. Every task, in the order its dependencies allow, with no waiver reason.
create temp table ci_close_result (
  seq integer, code text, waivable boolean, check_name text, answer text);

do $tick$
declare
  r     record;
  v_out text;
begin
  for r in select t.id, t.seq, t.code, t.is_waivable, t.blocking_check
             from erp.close_task t
            where t.tenant_id = erp.require_tenant_id()
              and t.fiscal_period_id = (select period_id from pg_temp.ci_month)
            order by t.seq, t.code
  loop
    v_out := public.erp_complete_close_task(r.id, null);
    insert into pg_temp.ci_close_result
    values (r.seq, r.code, r.is_waivable,
            coalesce(r.blocking_check, '(no check)'), v_out);
  end loop;
end
$tick$;

select lpad(seq::text, 3) || '  ' || rpad(code, 22) || '  '
       || case when waivable then 'waivable' else 'TIE     ' end || '  '
       || rpad(check_name, 40) || '  ' || answer as checklist
  from pg_temp.ci_close_result order by seq, code;

-- 4. Closed.
select public.erp_close_period(:'period_id');

-- Read back. "The period says closed" and "nothing was waived to get it there"
-- are different claims, and the second is the one this step exists for.
do $proved$
declare
  m        record;
  v_status text;
  v_waived text;
  v_ties   integer;
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

  raise warning '% is closed: % tie task(s), none waived', m.period_code, v_ties;
end
$proved$;

commit;
SQL

wall_ms=$(( ($(date +%s%N) - started) / 1000000 ))
echo "the seeded month closed in ${wall_ms} ms"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## The seeded month is closed"
    echo "ci-demo's seeded month closed through the doors in ${wall_ms} ms: every close task complete, none waived, four of them ties."
  } >> "$GITHUB_STEP_SUMMARY"
fi
