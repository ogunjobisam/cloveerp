#!/usr/bin/env bash
# Put a bounded excerpt of a step's output in the job summary.
#
#   .github/summarise.sh <log file> [heading]
#
# GitHub caps the step summary at 1 MiB and discards the whole file when it
# goes over. The first gateway repair teed 13623k of migration NOTICEs at it
# and lost the summary entirely — and left a red ##[error] annotation on a job
# that had succeeded, which is the worst of both: no summary and a false alarm.
#
# The job log already holds every line. The summary holds the end of it, which
# is where a failure says what it was.
set -euo pipefail

log=${1:?usage: summarise.sh <log file> [heading]}
heading=${2:-}
limit=${SUMMARY_LIMIT_BYTES:-200000}
lines=${SUMMARY_LIMIT_LINES:-400}

# Nothing to write to outside Actions; saying so is not an error.
if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "no GITHUB_STEP_SUMMARY; leaving $log where it is" >&2
  exit 0
fi

excerpt=$(mktemp)
trap 'rm -f "$excerpt"' EXIT

if [[ ! -s "$log" ]]; then
  echo "(no output)" > "$excerpt"
elif [[ "$(wc -c < "$log")" -le "$limit" ]]; then
  cat "$log" > "$excerpt"
else
  {
    echo "-- the whole output is in the job log; its last ${lines} lines follow --"
    tail -n "$lines" "$log" | tail -c "$limit"
  } > "$excerpt"
fi

# Output cut mid-line — by the byte cap, or by a command that died partway —
# would otherwise swallow the closing fence onto its last line.
if [[ -n "$(tail -c1 "$excerpt")" ]]; then echo >> "$excerpt"; fi

{
  if [[ -n "$heading" ]]; then echo "$heading"; fi
  echo '```'
  cat "$excerpt"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"
