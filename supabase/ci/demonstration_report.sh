#!/usr/bin/env bash
#
# What the deploy says about the demonstration, in one place that can be tested.
#
# This step has now held the answer and failed to print it three times in one
# day, and each time the step kept its composure and lost the finding:
#
#   1. tail -n 20 kept the END of psql's stderr, so the ERROR line was cut off
#      the front of a PL/pgSQL error and what reached the log began mid-
#      statement. The cancellation it was reporting had to be worked out from
#      the clock.
#   2. head -n 1 took stderr's FIRST line for the ::warning::, and psql writes
#      NOTICEs to stderr before the error, so the warning quoted a notice and
#      never the refusal.
#   3. Moving `set statement_timeout` out of PGOPTIONS (which the session pooler
#      drops) and into its own -c put a second result in the report, every jq
#      reading it failed, and the step printed six words — "jq: parse error" —
#      and nothing else.
#
# Each was a different mistake in the same half of the step: not the work, the
# reporting of it. So the reporting lives here rather than inline in
# .github/workflows/deploy.yml, and supabase/ci/demonstration_report_rehearsal.sh
# runs it against captured reports and captured stderr on every build. A step
# whose formatting is only ever exercised by production is a step that learns
# from production.
#
# Usage: demonstration_report.sh <report.json> <stderr> <seconds> <answered>
#   answered: true when psql exited 0, false when it did not.
#
# Exit status: 0 when it could say what happened, 1 when it could not — which
# is a failure of this step and is meant to be. A report it cannot parse is the
# one case where saying nothing is worse than saying too much, so it dumps
# both files raw and fails. The deploy step carries continue-on-error, so the
# release is not blocked by it; what it loses is the tick.
set -uo pipefail

report="${1:?a report file is required}"
errors="${2:?an error file is required}"
seconds="${3:?the elapsed seconds are required}"
answered="${4:?true or false is required}"

# The step summary when there is one, a sink when there is not, so this runs
# the same way under a rehearsal as under a deploy.
to_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat >> "$GITHUB_STEP_SUMMARY"
  else
    cat > /dev/null
  fi
}

# ── psql could not answer at all ─────────────────────────────────────────────
if [[ "$answered" != true ]]; then
  # The refusal itself, by name, and not whichever NOTICE happened to be
  # printed first (2 above).
  refusal=$(awk 'index($0, "ERROR:") { sub(/^.*ERROR:[[:space:]]*/, ""); print; exit }' "$errors")
  [[ -n "$refusal" ]] || refusal=$(grep -vi "NOTICE:" "$errors" 2>/dev/null | head -n 1)
  [[ -n "$refusal" ]] || refusal=$(head -n 1 "$errors" 2>/dev/null)
  [[ -n "$refusal" ]] || refusal="psql failed and wrote nothing to say why"

  # From the ERROR onwards, keeping the head — where the ERROR, DETAIL and HINT
  # are — and the tail, where the innermost frames are, when it is too long for
  # both (1 above).
  why=$(sed -n '/ERROR:/,$p' "$errors" 2>/dev/null)
  [[ -n "$why" ]] || why=$(cat "$errors" 2>/dev/null)
  if (( $(printf '%s\n' "$why" | wc -l) > 60 )); then
    why=$(printf '%s\n' "$why" | head -n 40
          echo "  … the middle of the statement it was running is cut here …"
          printf '%s\n' "$why" | tail -n 20)
  fi

  echo "the demonstration was NOT brought up to date, after ${seconds} s:"
  printf '%s\n' "$why"
  echo "::warning::the demonstration was not brought up to date; it is as the last deploy left it. ${refusal}"
  {
    echo "## Demonstration"
    echo "**Not brought up to date.** It is as the last deploy left it,"
    echo "which is what a prospect would be shown. The deploy is not failed"
    echo "by this — it is demonstration data, not an invariant — but nothing"
    echo "about the tick above says this worked."
    echo '```'
    printf '%s\n' "$why"
    echo '```'
  } | to_summary
  exit 0
fi

# ── psql answered; before anything reads it, is it a report? ─────────────────
#
# The one case that must not be survived quietly (3 above). Everything below
# assumes an array of objects, and a step that discovers otherwise one jq at a
# time prints a parse error and nothing about the demonstration.
if ! jq -e 'type == "array"' "$report" > /dev/null 2>&1; then
  echo "::error::the demonstration step could not read its own report. The catch-up itself may well have run and committed — psql exited 0 — but nothing here can say what it did. The raw report and the raw stderr are below."
  echo "the demonstration report could not be parsed, after ${seconds} s."
  echo "── what psql wrote to stdout, raw ──"
  cat "$report" 2>/dev/null || echo "(the report file could not be read)"
  echo "── what psql wrote to stderr, raw ──"
  cat "$errors" 2>/dev/null || echo "(the error file could not be read)"
  {
    echo "## Demonstration"
    echo "**The step could not read its own report.** psql exited 0, so the"
    echo "catch-up itself may well have run and committed; what failed is the"
    echo "reporting of it, and nothing here can say whether the demonstration"
    echo "moved. The raw output is in the step log."
  } | to_summary
  exit 1
fi

# ── Three readings, not two ──────────────────────────────────────────────────
#
# A run that stopped because the statement is only allowed so long has
# committed what it built and the next deploy carries on; that is progress and
# must not be shouted at in the words used for a demonstration that is stuck.
lines=$(jq -r '.[] |
  (if .caught_up == true then "- "
   elif .ran_out_of_time == true then "- MORE TO DO — "
   else "- DID NOT CATCH UP — " end)
  + "\(.organisation // "?"): traded \(.traded_from // "-") to \(.traded_through // "-"), "
  + "\(.documents_built // 0) document(s); \(.bills_raised // 0) supplier bill(s); "
  + "\(.periods_reopened // 0) month(s) reopened; "
  + "\(.periods_closed // 0) month(s) closed, \(.periods_left_open // 0) left open"
  + (if .ran_out_of_time == true then " — it stopped inside the time this statement is allowed; the next deploy carries on from \(.traded_through // "-")" else "" end)
  + (if .stopped_on then " — STOPPED on \(.stopped_on), and every day after it is unbuilt" else "" end)
' "$report")
notes=$(jq -r '.[] | . as $o | (.notes // [])[] | "- \($o.organisation // "?"): \(.)"' "$report")
stalled=$(jq -r '[.[] | select(.caught_up != true and .ran_out_of_time != true)] | length' "$report")
stalled_names=$(jq -r '[.[] | select(.caught_up != true and .ran_out_of_time != true) | .organisation // "?"] | join(", ")' "$report")
pending=$(jq -r '[.[] | select(.ran_out_of_time == true)] | length' "$report")
pending_names=$(jq -r '[.[] | select(.ran_out_of_time == true) | .organisation // "?"] | join(", ")' "$report")

echo "erp.catch_up_demonstrations() took ${seconds} s"
[[ -z "$lines" ]] && echo "no demonstration organisation on this database" || echo "$lines"
if [[ -n "$notes" ]]; then
  echo "$notes"
  while IFS= read -r n; do echo "::warning::${n}"; done <<< "$notes"
fi
if [[ "$stalled" != "0" && -n "$stalled_names" ]]; then
  echo "::warning::${stalled} demonstration(s) did not catch up: ${stalled_names}. Each still reads as whatever the last deploy left it as, which is what a prospect is shown."
fi
if [[ "$pending" != "0" && -n "$pending_names" ]]; then
  echo "::notice::${pending} demonstration(s) have more to build than one statement is allowed: ${pending_names}. Each committed what it built; run this workflow again, or wait for the next deploy, until they report caught up."
fi
{
  echo "## Demonstration"
  if [[ "$stalled" != "0" && -n "$stalled_names" ]]; then
    echo "**${stalled} demonstration(s) did not catch up: ${stalled_names}.**"
    echo "Each still reads as whatever the last deploy left it as, which is what"
    echo "a prospect is shown. The deploy is not failed by this — it is"
    echo "demonstration data, not an invariant — but nothing about the tick on"
    echo "this step says it worked."
    echo
  fi
  if [[ "$pending" != "0" && -n "$pending_names" ]]; then
    echo "**${pending} demonstration(s) have more to build than one statement is allowed:**"
    echo "${pending_names}. Each stopped inside its time and committed what it built,"
    echo "so this is progress rather than a fault — but it is not finished. Run this"
    echo "workflow again, or wait for the next deploy, until they report caught up."
    echo
  fi
  echo "erp.catch_up_demonstrations() took ${seconds} s."
  [[ -z "$lines" ]] && echo "No demonstration organisation on this database." || echo "$lines"
  [[ -z "$notes" ]] || { echo; echo "What it could not do:"; echo "$notes"; }
} | to_summary
