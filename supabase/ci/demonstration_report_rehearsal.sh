#!/usr/bin/env bash
#
# The deploy's demonstration report, rehearsed against captured output.
#
# supabase/ci/demonstration_catch_up.sh rehearses the CALL — the routine, over a
# connection that arrives with nothing set, which is the shape deploy.yml has.
# Nothing rehearsed the FORMATTING, and the formatting is what has failed: three
# times in one day, three different ways, each of them losing the finding while
# the step kept its composure. Every one of them would have been caught here, by
# fixtures and no database at all.
#
# So this feeds supabase/ci/demonstration_report.sh the shapes it will meet —
# a run that caught up, one that stopped inside its time, one that is stuck, a
# report that is not a report, and a stderr with notices in front of the error —
# and holds it to saying the thing that matters about each.
#
# No database, no network, a second to run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTER="$HERE/demonstration_report.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
CASES=0

# Runs the reporter and captures everything it says: stdout, and the summary it
# would have written to the step. Never lets a non-zero exit stop this script;
# the exit status is part of what is asserted.
run_reporter() {
  local report="$1" errors="$2" seconds="$3" answered="$4"
  : > "$WORK/summary.md"
  GITHUB_STEP_SUMMARY="$WORK/summary.md" \
    bash "$REPORTER" "$report" "$errors" "$seconds" "$answered" > "$WORK/out.txt" 2>&1
  REPORTER_STATUS=$?
  OUT="$(cat "$WORK/out.txt")"
  SUMMARY="$(cat "$WORK/summary.md")"
  return 0
}

expect() {
  local what="$1" haystack="$2" needle="$3"
  CASES=$((CASES + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ok   $what"
  else
    echo "  FAIL $what" >&2
    echo "       expected to find: $needle" >&2
    echo "       in:" >&2
    printf '%s\n' "$haystack" | sed 's/^/         /' >&2
    FAILED=1
  fi
}

expect_not() {
  local what="$1" haystack="$2" needle="$3"
  CASES=$((CASES + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  ok   $what"
  else
    echo "  FAIL $what" >&2
    echo "       expected NOT to find: $needle" >&2
    printf '%s\n' "$haystack" | sed 's/^/         /' >&2
    FAILED=1
  fi
}

expect_status() {
  local what="$1" want="$2"
  CASES=$((CASES + 1))
  if [[ "$REPORTER_STATUS" == "$want" ]]; then
    echo "  ok   $what"
  else
    echo "  FAIL $what — exit status was $REPORTER_STATUS, expected $want" >&2
    FAILED=1
  fi
}

echo "── the demonstration report, rehearsed against captured output"

# ── 1. A run that caught up ──────────────────────────────────────────────────
cat > "$WORK/caught.json" <<'J'
[{"organisation":"demo-ok","caught_up":true,"ran_out_of_time":false,
  "traded_from":"2026-09-20","traded_through":"2026-09-21","documents_built":12,
  "bills_raised":2,"periods_reopened":0,"periods_closed":1,"periods_left_open":0,
  "stopped_on":null,"notes":[]}]
J
: > "$WORK/empty.err"
run_reporter "$WORK/caught.json" "$WORK/empty.err" "4.2" true
expect_status "a run that caught up reports success" 0
expect "it names the organisation and what it built" "$OUT" "demo-ok: traded 2026-09-20 to 2026-09-21, 12 document(s)"
expect_not "and does not shout at a run that worked" "$OUT" "DID NOT CATCH UP"
expect_not "nor call it unfinished" "$OUT" "MORE TO DO"

# ── 2. A run that stopped inside the time it was allowed ─────────────────────
cat > "$WORK/pending.json" <<'J'
[{"organisation":"demo-cbb10384","caught_up":false,"ran_out_of_time":true,
  "traded_from":"2026-04-15","traded_through":"2026-05-28","documents_built":310,
  "bills_raised":0,"periods_reopened":10,"periods_closed":1,"periods_left_open":0,
  "stopped_on":null,"notes":["It ran out of the time this statement is allowed and stopped at 2026-05-28."]}]
J
run_reporter "$WORK/pending.json" "$WORK/empty.err" "181.0" true
expect_status "a run with more to do still reports success" 0
expect "it says there is more to do rather than that it failed" "$OUT" "MORE TO DO — demo-cbb10384"
expect "it says where the next deploy carries on from" "$OUT" "carries on from 2026-05-28"
expect "it counts that as progress, not a fault" "$OUT" "::notice::1 demonstration(s) have more to build"
expect_not "and does not raise it as a demonstration that is stuck" "$OUT" "::warning::1 demonstration(s) did not catch up"

# ── 3. A run that is genuinely stuck ─────────────────────────────────────────
cat > "$WORK/stalled.json" <<'J'
[{"organisation":"demo-stuck","caught_up":false,"ran_out_of_time":false,
  "traded_from":"2026-04-15","traded_through":"2026-04-14","documents_built":0,
  "bills_raised":0,"periods_reopened":0,"periods_closed":0,"periods_left_open":0,
  "stopped_on":"2026-04-15","notes":["2026-04-15 would not build: CLOVEERP_SOMETHING."]}]
J
run_reporter "$WORK/stalled.json" "$WORK/empty.err" "9.9" true
expect_status "a stuck demonstration still reports success, because the deploy is not failed by it" 0
expect "it says so in capitals" "$OUT" "DID NOT CATCH UP — demo-stuck"
expect "it names the day it stopped on" "$OUT" "STOPPED on 2026-04-15"
expect "it raises a warning a person will see" "$OUT" "::warning::1 demonstration(s) did not catch up: demo-stuck"
expect "and the step summary leads with it" "$SUMMARY" "**1 demonstration(s) did not catch up: demo-stuck.**"

# ── 4. A report that is not a report ─────────────────────────────────────────
#
# What psql wrote on 21 September, when the SET moved out of PGOPTIONS and into
# its own -c: a command tag ahead of the JSON. Whatever the leading noise is,
# the step must say it could not read its report, dump both files, and FAIL —
# not print a parse error and move on looking like a good run.
printf 'SET\n[{"organisation":"demo-ok","caught_up":true}]\n' > "$WORK/noise.json"
printf 'NOTICE:  something incidental\n' > "$WORK/notice.err"
run_reporter "$WORK/noise.json" "$WORK/notice.err" "121.9" true
expect_status "a report it cannot parse FAILS the step" 1
expect "it says plainly that it could not read its own report" "$OUT" "could not read its own report"
expect "it says the work may well have happened anyway" "$OUT" "may well have run and committed"
expect "it dumps the raw stdout so the next person can see the noise" "$OUT" "SET"
expect "and the raw stderr with it" "$OUT" "NOTICE:  something incidental"
expect "and it is an error, not a warning" "$OUT" "::error::"

# ── 5. psql did not answer: the ERROR survives, and the notice does not win ──
#
# The 21 September stderr: notices first, then the cancellation, then a long
# CONTEXT. The old step quoted the notice and cut the ERROR off the front.
cat > "$WORK/cancel.err" <<'E'
NOTICE:  CLOVEERP_COUNT_IN_PROGRESS: 900.000000 moved through a location being counted
NOTICE:  another incidental notice
ERROR:  canceling statement due to statement timeout
CONTEXT:  SQL statement "insert into erp.document (
    tenant_id, entity_id, site_id, document_type_id, document_number, party_id,
    party_role_id, document_date, currency, their_reference, attributes)
  values (
    v_tenant, p_entity_id, p_site_id, dt.id, v_number, p_party_id,
    coalesce(p_document_date, erp.local_today(p_site_id)),
    p_their_reference, p_attributes)
  returning id"
PL/pgSQL function erp.create_document(text,uuid,uuid,uuid,date,character,text,jsonb) line 55 at SQL statement
PL/pgSQL function erp.raise_customer_credit_note(uuid,text,text,jsonb) line 71 at assignment
PL/pgSQL function erp.demonstration_catch_up() line 126 at assignment
PL/pgSQL function erp.catch_up_demonstrations(text) line 80 at assignment
E
: > "$WORK/none.json"
run_reporter "$WORK/none.json" "$WORK/cancel.err" "121.9" false
expect_status "a demonstration psql could not answer for does not fail the step" 0
expect "the warning carries the ERROR" "$OUT" "::warning::the demonstration was not brought up to date; it is as the last deploy left it. canceling statement due to statement timeout"
expect_not "and not whichever notice came first" "$OUT" "::warning::the demonstration was not brought up to date; it is as the last deploy left it. NOTICE"
expect "the body begins at the ERROR rather than mid-statement" "$OUT" "ERROR:  canceling statement due to statement timeout"
expect "and still carries the innermost frames" "$OUT" "erp.catch_up_demonstrations(text) line 80 at assignment"

# ── 6. No demonstration at all ───────────────────────────────────────────────
echo '[]' > "$WORK/none_at_all.json"
run_reporter "$WORK/none_at_all.json" "$WORK/empty.err" "0.4" true
expect_status "an empty report is a report" 0
expect "it says there is no demonstration rather than saying nothing" "$OUT" "no demonstration organisation on this database"

echo
if [[ "$FAILED" -ne 0 ]]; then
  echo "the demonstration report does not say what it must: $CASES check(s) run, at least one failed" >&2
  exit 1
fi
echo "the demonstration report says what it must in every shape it will meet: $CASES checks"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## The demonstration report, rehearsed"
    echo "$CASES checks over the shapes deploy.yml will meet — caught up, more to" \
         "do, stuck, a report that is not a report, a cancellation behind two" \
         "notices, and no demonstration at all. The formatting is what failed" \
         "three times on 21 September; this is what would have caught all three."
  } >> "$GITHUB_STEP_SUMMARY"
fi
