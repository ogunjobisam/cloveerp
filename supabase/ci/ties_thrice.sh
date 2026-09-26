#!/usr/bin/env bash
#
# The four ties hold three times running, on the closed month.
#
# The v1 Definition of Done states the master gate once and the exit criterion
# once, and they are not the same sentence:
#
#   the gate      after a seeded month is posted and the period closed, all
#                 four ties hold;
#   the criterion the four ties hold on a freshly seeded month, THREE
#                 CONSECUTIVE RUNS.
#
# supabase/ci/run_checks.sh walks erp.ci_check_catalogue() exactly once, so the
# build proved one run. One run cannot tell a tie that holds from a tie that
# happens to hold this time — and this repository has had exactly that defect
# before (20260916610000: a suite that flaked on heap order, green on most runs).
# A figure that is right once and wrong twice is a figure nobody can act on.
#
# So this runs the four ties again, three times, in three separate sessions —
# three transactions, three snapshots — and refuses if any run disagrees with
# another, as well as if any run refuses. The ties are not listed here: they are
# read from the close tasks the month was closed on, the ones erp.set_close_task_tie()
# stamped unwaivable, so a fifth tie added to the product is run by this the day
# it lands and a tie removed from it fails the count. It also refuses to run at
# all unless the period is 'closed', and closed with the month's other ledgers
# (a month's checklist is raised once, on GL, and COMMIT closes with it:
# 20260929200000), because ties asserted before a close are the weaker claim
# the build already made.
#
# Runs after supabase/ci/close_month.sh, which closes ci-demo's seeded month.
# Reads PSQL from the environment like run_checks.sh.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
work="${RUNNER_TEMP:-/tmp}"
sql="$work/clove-ties.sql"

cat > "$sql" <<'SQL'
\set ON_ERROR_STOP on

begin;

select t.id as tenant_id from erp.tenant t where t.code = 'ci-demo' \gset
select u.auth_user_id as admin_auth
  from erp.app_user u
 where u.tenant_id = :'tenant_id' and u.email = 'admin@ci-demo.test' \gset
select set_config('request.jwt.claims',
                  json_build_object('sub', :'admin_auth')::text, true) as ctx \gset

create temp table ci_ties (seq integer, code text, check_name text, answer text);

do $ties$
declare
  p      record;
  r      record;
  v_out  text;
  v_n    integer;
  v_half text;
begin
  -- The month the build closed: the only period of this organisation carrying
  -- a close checklist, its COMMIT period having closed on it. `strict` rather
  -- than a silent first row.
  select fp.id, fp.code, fp.status::text as status, fp.closed_at into strict p
    from erp.fiscal_period fp
   where fp.tenant_id = erp.require_tenant_id()
     and exists (select 1 from erp.close_task t
                  where t.tenant_id = fp.tenant_id and t.fiscal_period_id = fp.id);

  if p.status <> 'closed' then
    raise exception
      'CLOVEERP_CI_TIES_BEFORE_CLOSE: % is %, so these are not the ties the Definition of Done names',
      p.code, p.status
      using hint = 'supabase/ci/close_month.sh runs first. A tie asserted outside a close is the weaker claim.';
  end if;

  select count(*),
         string_agg(fp.code || ' ' || fp.status::text, ', ')
           filter (where fp.status <> 'closed' or fp.closed_at is distinct from p.closed_at)
    into v_n, v_half
    from erp.period_siblings(p.id) s(id)
    join erp.fiscal_period fp on fp.tenant_id = erp.require_tenant_id() and fp.id = s.id;
  if v_n = 0 or v_half is not null then
    raise exception
      'CLOVEERP_CI_TIES_MONTH_HALF_CLOSED: % closed on its own, not with its other ledgers (%)',
      p.code, coalesce(v_half, 'it has none')
      using hint = 'erp.close_period() closes the month on every statutory and management ledger at one moment (20260929200000).';
  end if;

  for r in select t.seq, t.code, t.blocking_check
             from erp.close_task t
            where t.tenant_id = erp.require_tenant_id()
              and t.fiscal_period_id = p.id
              and not t.is_waivable
            order by t.seq, t.code
  loop
    execute format('select %s', r.blocking_check) into v_out;
    insert into pg_temp.ci_ties values (r.seq, r.code, r.blocking_check, v_out);
  end loop;

  select count(*) into v_n from pg_temp.ci_ties;
  if v_n <> 4 then
    raise exception 'CLOVEERP_CI_TIES_MISCOUNTED: % unwaivable tie(s) on %, not four', v_n, p.code
      using hint = 'The four are the trial balance, the inventory valuation, the subledgers and the ageing.';
  end if;
end
$ties$;

-- Prefixed, so the comparison reads rows and not whatever else psql says.
select 'TIE|' || code || '|' || check_name || '|' || answer
  from pg_temp.ci_ties order by seq, code;

rollback;
SQL

total_started=$(date +%s%N)
runs=()

for i in 1 2 3; do
  raw="$work/clove-ties-raw$i.txt"
  out="$work/clove-ties-run$i.txt"
  started=$(date +%s%N)
  if ! $PSQL_CMD -tA -f "$sql" > "$raw" 2>&1; then
    echo "::error::a tie refused on run $i, on the closed month. That is the finding, not a flake:"
    cat "$raw"
    exit 1
  fi
  ms=$(( ($(date +%s%N) - started) / 1000000 ))
  if ! grep '^TIE|' "$raw" > "$out"; then
    echo "::error::run $i answered no ties at all:"
    cat "$raw"
    exit 1
  fi
  echo "── run $i: $(wc -l < "$out" | tr -d ' ') tie(s) in ${ms} ms"
  sed 's/^TIE|/     /' "$out"
  runs+=("$ms")
done

total_ms=$(( ($(date +%s%N) - total_started) / 1000000 ))

# Three runs that hold are only three runs that AGREE. A tie that answers one
# thing now and another thing in a minute is the defect a single run cannot see.
disagreed=0
for i in 2 3; do
  if ! diff -u "$work/clove-ties-run1.txt" "$work/clove-ties-run$i.txt" > "$work/clove-ties-diff$i.txt"; then
    echo "::error::the four ties disagreed between run 1 and run $i on the closed month:"
    cat "$work/clove-ties-diff$i.txt"
    disagreed=1
  fi
done
[[ $disagreed -eq 0 ]] || exit 1

echo "the four ties held three consecutive times on the closed month, identically, in ${total_ms} ms (${runs[0]}, ${runs[1]}, ${runs[2]} ms)"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## The four ties hold three times running"
    echo "On ci-demo's closed month, in three separate sessions: ${runs[0]} ms, ${runs[1]} ms, ${runs[2]} ms (${total_ms} ms in all). Every run answered identically."
    echo '```'
    sed 's/^TIE|/  /' "$work/clove-ties-run1.txt"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
