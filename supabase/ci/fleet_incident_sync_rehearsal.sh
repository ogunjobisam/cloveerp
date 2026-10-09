#!/usr/bin/env bash
#
# supabase/ci/fleet_incident_sync.sh, rehearsed with no database.
#
# The sync carries every incident and maintenance window that reaches a
# client into the client's own database, every ten minutes and whenever an
# incident or window that reaches one changes (fleet_sweep.yml, a job of its
# own). Wrong one way, a client's people are never told of an outage, or of a
# security incident whose report they owe; wrong the other, the control plane
# believes a client holds what it never received, or carries the same item
# every run because what it sent was rewritten on the way; and what it carries
# is incident bodies, in a repository whose logs are public. So every build
# runs it here first, against the shared stand-ins (fleet_rehearsal_fakes.sh),
# which answer as 20261012060000's routines answer: what it refuses before
# touching anything; that every client up is asked after whatever started the
# run; that a client owed nothing is never connected to, and one owed only
# the telling it has not reported, or only the daily check of what it holds,
# is; that the client is given what the control plane owes it whole, byte for
# byte, and the control plane the client's answer as it came, held and all;
# that both reach psql through a file it reads itself (\set `cat`), never an
# argument, however large (an incident of more than 200 KB, an answer too),
# each file only the script can read and gone the moment its statement is
# done, and every file gone however the run ends, a signal included; that
# past the sanity limit nothing is sent or settled, and that is said; that
# applied, replay, waiting and refused are each counted and settled, and a
# push refused whole settles nothing; that a client that cannot be reached or
# is a release behind settles nothing; that every statement carries a
# timeout and is terse; that nothing carried, no detail a client answered, no
# connection string and no DETAIL or CONTEXT is ever printed; and that the job
# in fleet_sweep.yml runs it in a concurrency group of its own. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_incident_sync.sh"
WF="$HERE/../../.github/workflows/fleet_sweep.yml"
JOB=incidents
STEP="Carry every incident and maintenance window to the clients it reaches"
# shellcheck source=supabase/ci/fleet_rehearsal_fakes.sh
. "$HERE/fleet_rehearsal_fakes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
fleet_fakes "$work/bin"

PROD=cpcpcpcpcpcpcpcpcpcp
DEMO=dddddddddddddddddddd
ACME=aaaaaaaaaaaaaaaaaaaa
BETA=bbbbbbbbbbbbbbbbbbbb
GAMMA=gggggggggggggggggggg
CP="postgresql://postgres.${PROD}:control-plane-password@pooler.example:5432/postgres"
ACME_URL="postgresql://postgres.${ACME}:acme-database-password@pooler.example:5432/postgres"
BETA_URL="postgresql://postgres.${BETA}:beta-database-password@pooler.example:5432/postgres"
GAMMA_URL="postgresql://postgres.${GAMMA}:gamma-database-password@pooler.example:5432/postgres"
export FAKE_DIR="$work/fake"

# What is carried, with incident bodies in it, as the control plane writes it
# (jsonb as text: a space after each colon and comma). None of these words may
# reach the log or the summary.
I1=11111111-1111-4111-8111-111111111111
I2=22222222-2222-4222-8222-222222222222
I3=77777777-7777-4777-8777-777777777777
W1=33333333-3333-4333-8333-333333333333
W2=44444444-4444-4444-8444-444444444444
D1=9f2c0d1e9f2c0d1e9f2c0d1e9f2c0d1e
D2=0b7e44aa0b7e44aa0b7e44aa0b7e44aa
D3=5d5d1c2b5d5d1c2b5d5d1c2b5d5d1c2b
D4=e1e1f0f0e1e1f0f0e1e1f0f0e1e1f0f0
INC1="{\"id\": \"${I1}\", \"code\": \"INC-2026-0042\", \"scope\": \"Card payments\", \"title\": \"Card payments failing at Stripeco\", \"review\": null, \"scribe\": \"C. Scribe\", \"updates\": [{\"id\": \"55555555-5555-4555-8555-555555555555\", \"body\": \"Stripeco says card numbers seen by jane.doe@acme.example may be exposed\", \"affected\": \"Card payments\", \"meanwhile\": null, \"posted_at\": \"2026-10-09T08:05:00+00:00\", \"posted_by\": \"Jane Doe\", \"being_done\": \"Talking to Stripeco\", \"is_no_change\": false, \"not_affected\": null, \"next_update_at\": null}], \"commander\": \"Jane Doe\", \"components\": [\"payments_api\"], \"created_at\": \"2026-10-09T08:00:00+00:00\", \"declared_at\": \"2026-10-09T08:00:00+00:00\", \"disclosures\": [{\"id\": \"66666666-6666-4666-8666-666666666666\", \"due_at\": \"2026-10-12T08:00:00+00:00\", \"created_at\": \"2026-10-09T08:00:00+00:00\", \"notified_at\": null, \"notified_by\": null, \"obligation_code\": \"ico_72h\"}], \"is_security\": true, \"resolved_at\": null, \"contained_at\": null, \"severity_code\": \"sev1\", \"is_data_integrity\": false, \"next_update_due_at\": \"2026-10-09T09:00:00+00:00\", \"review_completed_at\": null, \"communications_owner\": \"B. Comms\", \"origin_dependency_code\": null}"
INC2="{\"id\": \"${I2}\", \"code\": \"INC-2026-0041\", \"scope\": null, \"title\": \"Slow reports overnight\", \"review\": {\"document\": {\"actions\": [{\"done_at\": null, \"description\": \"Watch vacuum\"}], \"timeline\": [], \"duration_minutes\": 120, \"updates_promised\": 2}, \"assembled_at\": \"2026-10-08T12:00:00+00:00\"}, \"scribe\": \"C. Scribe\", \"updates\": [], \"commander\": \"A. Commander\", \"components\": [\"reporting\"], \"created_at\": \"2026-10-08T01:00:00+00:00\", \"declared_at\": \"2026-10-08T01:00:00+00:00\", \"disclosures\": [], \"is_security\": false, \"resolved_at\": \"2026-10-08T03:00:00+00:00\", \"contained_at\": null, \"severity_code\": \"sev3\", \"is_data_integrity\": false, \"next_update_due_at\": null, \"review_completed_at\": \"2026-10-08T12:00:00+00:00\", \"communications_owner\": \"B. Comms\", \"origin_dependency_code\": null}"
WIN1="{\"id\": \"${W1}\", \"code\": \"MW-2026-0007\", \"title\": \"Database upgrade on Sunday night\", \"detail\": null, \"ends_at\": \"2026-10-11T23:30:00+00:00\", \"starts_at\": \"2026-10-11T22:00:00+00:00\", \"created_at\": \"2026-10-09T07:00:00+00:00\", \"announced_at\": \"2026-10-09T07:00:00+00:00\", \"announced_by\": \"Ops\", \"cancelled_at\": null, \"is_emergency\": false, \"cancel_reason\": null, \"emergency_reason\": null}"
WIN2="{\"id\": \"${W2}\", \"code\": \"MW-2026-0008\", \"title\": \"Moving payments to Frankfurt\", \"detail\": \"payments_api read-only\", \"ends_at\": \"2026-10-12T23:00:00+00:00\", \"starts_at\": \"2026-10-12T22:00:00+00:00\", \"created_at\": \"2026-10-09T07:00:00+00:00\", \"announced_at\": \"2026-10-09T07:00:00+00:00\", \"announced_by\": \"Ops\", \"cancelled_at\": null, \"is_emergency\": false, \"cancel_reason\": null, \"emergency_reason\": null}"
ITEM_I1="{\"id\": \"${I1}\", \"digest\": \"${D1}\", \"payload\": ${INC1}}"
ITEM_I2="{\"id\": \"${I2}\", \"digest\": \"${D2}\", \"payload\": ${INC2}}"
ITEM_W1="{\"id\": \"${W1}\", \"digest\": \"${D3}\", \"payload\": ${WIN1}}"
ITEM_W2="{\"id\": \"${W2}\", \"digest\": \"${D4}\", \"payload\": ${WIN2}}"
# erp_meta.incident_pushes_due, as it answers; due_check, the same once a day,
# when the client is to say which copies it holds (check_held).
due() { printf '{"up": true, "code": "%s", "told_of": [%s], "windows": [%s], "incidents": [%s]}' "$1" "$2" "$3" "$4"; }
due_check() { printf '{"up": true, "code": "%s", "told_of": [%s], "windows": [%s], "incidents": [%s], "check_held": %s}' "$1" "$2" "$3" "$4" "$5"; }
DUE_ACME=$(due acme "" "$ITEM_W1" "${ITEM_I1}, ${ITEM_I2}")
DUE_GAMMA=$(due gamma "" "$ITEM_W2" "")
DUE_NONE() { due "$1" "" "" ""; }
TOLD2="2026-10-09T08:03:00.123456+00:00"
# erp_meta.apply_pushed_incidents, as it answers: each item's outcome, its
# words and the digest of what it was given; when its people were told; and
# every copy it holds, with the digest of what it holds.
ans() { printf '{"id": "%s", "detail": "%s", "digest": "%s", "outcome": "%s"}' "$1" "$2" "$3" "$4"; }
applied() { printf '{"held": [%s], "told": [%s], "windows": [%s], "incidents": [%s]}' "${4:-}" "$1" "$2" "$3"; }
held() { printf '{"id": "%s", "kind": "%s", "digest": "%s"}' "$1" "$2" "$3"; }
A_I1=$(ans "$I1" "holds INC-2026-0042 as the control plane carried it, with 1 update(s)" "$D1" applied)
A_I2=$(ans "$I2" "held already, since 8 Oct 2026 03:10:00 UTC" "$D2" replay)
A_W1=$(ans "$W1" "holds MW-2026-0007 as the control plane carried it" "$D3" applied)
A_W2=$(ans "$W2" "this deployment does not know component payments_api yet: it is behind on its release, and holds what it held" "$D4" waiting)
TOLD_ACME="{\"id\": \"${I1}\", \"told_at\": null}, {\"id\": \"${I2}\", \"told_at\": \"${TOLD2}\"}"
HELD_ACME="$(held "$I1" incident "$D1"), $(held "$I2" incident "$D2"), $(held "$W1" window "$D3")"
APPLIED_ACME=$(applied "$TOLD_ACME" "$A_W1" "${A_I1}, ${A_I2}" "$HELD_ACME")
APPLIED_GAMMA=$(applied "" "$A_W2" "")
# The daily check alone: owed nothing else, it says what it holds.
HELD_BETA="$(held "$I3" incident "$D1"), $(held "$W2" window "$D4")"
DUE_CHECK_BETA=$(due_check beta "" "" "" true)
CHECKED_BETA=$(applied "" "" "" "$HELD_BETA")
SILENT_BETA='{"told": [], "windows": [], "incidents": []}'
# An incident of more than 200 KB (a long security incident's timeline), and
# an answer of more than 200 KB (a client that holds a great many copies):
# neither fits in one argument on a runner (128 KiB).
I4=88888888-8888-4888-8888-888888888888
D5=a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5
BIG_BODY=$(printf 'Stripeco says the card batch %06d was replayed twice; ' $(seq 1 4000))
INC_BIG="{\"id\": \"${I4}\", \"code\": \"INC-2026-0050\", \"scope\": \"Card payments\", \"title\": \"Card payments replayed at Stripeco\", \"review\": null, \"scribe\": \"C. Scribe\", \"updates\": [{\"id\": \"99999999-9999-4999-8999-999999999999\", \"body\": \"${BIG_BODY}\", \"affected\": \"Card payments\", \"meanwhile\": null, \"posted_at\": \"2026-10-09T10:05:00+00:00\", \"posted_by\": \"the platform\", \"being_done\": \"Talking to Stripeco\", \"is_no_change\": false, \"not_affected\": null, \"next_update_at\": null}], \"commander\": \"Jane Doe\", \"components\": [\"payments_api\"], \"created_at\": \"2026-10-09T10:00:00+00:00\", \"declared_at\": \"2026-10-09T10:00:00+00:00\", \"disclosures\": [], \"is_security\": true, \"resolved_at\": null, \"contained_at\": null, \"severity_code\": \"sev1\", \"is_data_integrity\": false, \"next_update_due_at\": \"2026-10-09T11:00:00+00:00\", \"review_completed_at\": null, \"communications_owner\": \"B. Comms\", \"origin_dependency_code\": null}"
ITEM_BIG="{\"id\": \"${I4}\", \"digest\": \"${D5}\", \"payload\": ${INC_BIG}}"
DUE_BIG=$(due acme "" "$ITEM_W1" "$ITEM_BIG")
A_BIG=$(ans "$I4" "holds INC-2026-0050 as the control plane carried it, with 1 update(s)" "$D5" applied)
TOLD_BIG="{\"id\": \"${I4}\", \"told_at\": null}"
APPLIED_BIG=$(applied "$TOLD_BIG" "$A_W1" "$A_BIG" "$(held "$I4" incident "$D5"), $(held "$W1" window "$D3")")
HELD_FORMAT="{\"id\": \"%08d-aaaa-4aaa-8aaa-%012d\", \"kind\": \"incident\", \"digest\": \"${D1}\"}, "
HELD_MANY=$(printf "$HELD_FORMAT" $(seq 1 2500 | awk '{ print $1, $1 }'))
APPLIED_MANY=$(applied "$TOLD_ACME" "$A_W1" "${A_I1}, ${A_I2}" "${HELD_MANY}$(held "$W1" window "$D3")")
# The told_of case, and the items that are not what is owed: built here, at
# the top level, because bash 3.2 brace-expands "{a, b}" given as an argument
# inside a double-quoted command substitution.
TELL_I3="{\"id\": \"${I3}\", \"told_at\": \"${TOLD2}\"}"
UNTOLD_I3="{\"id\": \"${I3}\", \"told_at\": null}"
TOLD_ONLY=$(applied "$TELL_I3" "" "")
UNTOLD_ONLY=$(applied "$UNTOLD_I3" "" "")
ITEM_NO_ID="{\"id\": \"not-an-id\", \"digest\": \"${D1}\", \"payload\": ${INC1}}"
ITEM_NO_DIGEST="{\"id\": \"${I2}\", \"payload\": ${INC2}}"
NAMES_NO_CODE='invalid input syntax for type uuid: \"Stripeco card 4242\"'
A_I1_UNCODED=$(ans "$I1" "$NAMES_NO_CODE" "$D1" refused)
# erp_meta.settle_incident_pushes, as it answers.
settles() { printf '{"run": "4242", "code": "%s", "left": %s, "told": %s, "failed": %s, "applied": %s, "waiting": %s}' "$@"; }

BASE_ENV=(FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" PSQL="$work/bin/psql" FLEET_SLEEP="$work/bin/sleep"
          PRODUCTION_REF="$PROD" DEMO_REF="$DEMO" TMPDIR="$work/tmp" FAKE_WATCH_DIR="$work/tmp")

# The register and the clients as they are on a good day: acme owed two
# incidents and a window, beta nothing, gamma a window whose component it does
# not know yet; each connection in the vault and each database released the
# routine.
fresh() {
  CURRENT="$1"
  rm -rf "$FAKE_DIR" "$work/tmp"; mkdir -p "$FAKE_DIR/vault" "$work/tmp"
  printf '%s' "$ACME_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
  printf '%s' "$BETA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${BETA}_db_url"
  printf '%s' "$GAMMA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${GAMMA}_db_url"
  answer cp cp-ready "true|true|true"
  answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${ACME}\"},{\"code\":\"beta\",\"ref\":\"${BETA}\"},{\"code\":\"gamma\",\"ref\":\"${GAMMA}\"}]"
  answer cp cp-refs "${ACME},${BETA},${GAMMA},eeeeeeeeeeeeeeeeeeee"
  answer cp "cp-due@acme" "$DUE_ACME"
  answer cp "cp-due@beta" "$(DUE_NONE beta)"
  answer cp "cp-due@gamma" "$DUE_GAMMA"
  answer cp "cp-settle@acme" "$(settles acme 0 1 0 3 0)"
  answer cp "cp-settle@beta" "$(settles beta 0 0 0 0 0)"
  answer cp "cp-settle@gamma" "$(settles gamma 0 0 0 0 1)"
  answer "$ACME" client-state "client|true"
  answer "$BETA" client-state "client|true"
  answer "$GAMMA" client-state "client|true"
  answer "$ACME" client-apply "$APPLIED_ACME"
  answer "$GAMMA" client-apply "$APPLIED_GAMMA"
}

CASES=0
FAILED=0
# go [VAR=value ...] [-- arguments]: the script against the stand-ins as they stand.
go() {
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  : > "$work/summary"
  out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 \
          "${BASE_ENV[@]}" ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" 2>&1)
  status=$?
}
check() {
  CASES=$((CASES + 1))
  if eval "$1"; then
    echo "  ok   $CURRENT: $2"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL $CURRENT: $2"
    printf '%s\n' "$out" | sed 's/^/       | /' | head -n 25
    sed 's/^/       > /' "$FAKE_DIR/order.log" 2> /dev/null | head -n 40
  fi
}
order() { tr '\n' ';' 2> /dev/null < "$FAKE_DIR/order.log"; }
untouched() { [[ ! -s "$FAKE_DIR/order.log" ]]; }
summary() { cat "$work/summary"; }
# calls <database> <tag>: the numbers of those calls, in order.
calls() { awk -v d="$1" -v t="$2" '$2 == d && $3 == t { print $1 }' "$FAKE_DIR/psql.log" 2> /dev/null | tr '\n' ' '; }
# v <call> <name>: what that call was given as a variable.
v() { sed -n "s/^$2=//p" "$FAKE_DIR/vars.$1" 2> /dev/null | head -n 1; }
# tvar <database> <tag> <name>: the same, for the last call of that tag.
tvar() { local n; n=$(calls "$1" "$2" | awk '{ print $NF }'); [[ -z "$n" ]] || v "$n" "$3"; }
tsql() { local n; n=$(calls "$1" "$2" | awk '{ print $NF }'); [[ -z "$n" ]] || cat "$FAKE_DIR/sql.$n"; }
# settled <code>: the answer the control plane was given for that client.
settled() { local n; for n in $(calls cp cp-settle); do if [[ "$(v "$n" code)" == "$1" ]]; then v "$n" answer; fi; done; }
dues() { local n; for n in $(calls cp cp-due); do printf '%s ' "$(v "$n" code)"; done; }
# outcomes <code>: id:outcome of each answer settled for it, incidents then windows.
outcomes() { settled "$1" | jq -r '[(.incidents // [])[], (.windows // [])[]] | map("\(.id[0:8]):\(.outcome)") | join(" ")' 2> /dev/null; }
# pushed <ref>: what that client was given, the ids in order, by list.
pushed() {
  tvar "$1" client-apply push | jq -r '"incidents " + ((.incidents // []) | map(.id[0:8]) | join(" "))
                                      + "; windows " + ((.windows // []) | map(.id[0:8]) | join(" "))
                                      + "; told_of " + ((.told_of // []) | map(.[0:8]) | join(" "))' 2> /dev/null
}
bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }
# first <database> <tag> / last <database> <tag>: the number of that call.
first() { calls "$1" "$2" | awk '{ print $1 }'; }
last() { calls "$1" "$2" | awk '{ print $NF }'; }
# argv <call>: the length of the arguments psql was given at that call.
argv() { cat "$FAKE_DIR/argv.$1" 2> /dev/null; }
# read_from <call>: name, mode and path of each file psql read for a \set at that call.
read_from() { cat "$FAKE_DIR/files.$1" 2> /dev/null; }
# present <call>: the files in the run's directory while that call ran.
present() { cat "$FAKE_DIR/files_at.$1" 2> /dev/null; }
# left_behind: anything the run left in its temporary directory.
left_behind() { find "$work/tmp" -mindepth 1 2> /dev/null | head -n 5; }
# Nothing carried, nothing a client answered, and no connection string in
# what was printed (a mask line hides a value; it is not one shown).
private() {
  local where
  for where in "$(printf '%s\n' "$out" | grep -v '^::add-mask::')" "$(summary)"; do
    [[ "$where" != *"Stripeco"* && "$where" != *"jane.doe"* && "$where" != *"Jane Doe"* && "$where" != *"Card payments"* \
       && "$where" != *"Slow reports"* && "$where" != *"Database upgrade"* && "$where" != *"Frankfurt"* \
       && "$where" != *"INC-2026"* && "$where" != *"MW-2026"* && "$where" != *"payments_api"* && "$where" != *"held already"* \
       && "$where" != *"DETAIL"* && "$where" != *"CONTEXT"* && "$where" != *"HINT"* && "$where" != *"-password@"* ]] || return 1
  done
}

# 1. Refused before anything is touched
fresh "a code given"
go -- acme
check '[[ $status -eq 2 && "$out" == *"takes no code: every run carries to every client"* ]] && untouched' "refused: a run serves every client"
fresh "no control plane"
go CLOVEERP_LIVE_DATABASE_URL= --
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* ]] && untouched' "refused"
fresh "a pause that is not one"
go PAUSE_SECONDS=soon --
check '[[ $status -eq 2 ]] && untouched' "refused"
fresh "a timeout psql would not read"
go CLIENT_STATEMENT_TIMEOUT="30 seconds; drop" --
check '[[ $status -eq 2 && "$out" == *"CLIENT_STATEMENT_TIMEOUT and CP_STATEMENT_TIMEOUT"* ]] && untouched' "refused"
fresh "a control plane timeout psql would not read"
go CP_STATEMENT_TIMEOUT="1 hour" --
check '[[ $status -eq 2 ]] && untouched' "refused"
fresh "no bytes at all per run"
go MAX_PUSH_BYTES=0 --
check '[[ $status -eq 2 ]] && untouched' "refused"
fresh "more bytes than one jsonb value holds"
go MAX_PUSH_BYTES=268435456 --
check '[[ $status -eq 2 && "$out" == *"MAX_PUSH_BYTES must be a whole number from 1 to 268435455 (the most one jsonb value holds)"* ]] && untouched' "refused"
fresh "a limit larger than one argument holds"
go MAX_PUSH_BYTES=200000 --
check '[[ $status -eq 0 && -n "$(settled acme)" ]]' "taken: nothing carried passes through an argument"
fresh "a control plane that cannot be read"
answer cp cp-ready "ERROR:  could not connect"
go
check '[[ $status -eq 1 && "$out" == *"the control plane could not be read"* && "$(order)" == "psql cp cp-ready;" ]]' "red, nothing else asked"
fresh "a control plane with no register"
answer cp cp-ready "false|false|false"
go
check '[[ $status -eq 0 && "$out" == *"no register of deployments yet"* && "$(order)" == "psql cp cp-ready;" ]]' "nothing to do, and green"
fresh "a control plane a release behind"
answer cp cp-ready "true|false|false"
go
check '[[ $status -eq 0 && "$out" == *"(20261012060000 is not released there)"* && "$(order)" == "psql cp cp-ready;" ]]' \
      "said, green, and no client asked"
check '[[ "$(tsql cp cp-ready)" == *"to_regprocedure('"'"'erp_meta.incident_pushes_due(text)'"'"')"*"to_regprocedure('"'"'erp_meta.settle_incident_pushes(text,text,jsonb)'"'"')"* ]]' \
      "both routines asked after by their signatures"
fresh "a control plane with one routine of the two"
answer cp cp-ready "true|true|false"
go
check '[[ $status -eq 0 && "$out" == *"not released there"* && -z "$(calls cp cp-due)" ]]' "the same"
fresh "nobody up"
answer cp cp-clients "[]"
go
check '[[ $status -eq 0 && "$out" == *"nobody is owed an incident or a maintenance window"* && -z "$(calls cp cp-due)" ]]' "nothing to do"

# 2. Every client up is asked after, and given what it is owed whole
fresh "the fleet"
go
check '[[ $status -eq 0 && "$out" == *"every client was carried what reaches it of the control plane'"'"'s incidents and maintenance (3)"* ]]' "green"
check '[[ "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;psql cp cp-due;psql cp vault-get cloveerp:deployment:${ACME}:db_url;psql ${ACME} client-state;psql ${ACME} client-apply;psql cp cp-settle;psql cp cp-due;psql cp cp-due;sleep 2;psql cp vault-get cloveerp:deployment:${GAMMA}:db_url;psql ${GAMMA} client-state;psql ${GAMMA} client-apply;psql cp cp-settle;" ]]' \
      "one at a time: what it is owed first, then its own connection, checked, one statement, one settle; a pause between clients connected to"
check '[[ "$(dues)" == "acme beta gamma " ]]' "what each is owed asked by its own code"
check '[[ "$(order)" != *"${BETA}"* && -z "$(settled beta)" && "$out" == *"beta: nothing due"* ]]' \
      "beta, owed nothing: its connection never read, its database never touched, nothing settled"
check '[[ "$(tvar "$ACME" client-apply push)" == "$DUE_ACME" && "$(tvar "$ACME" client-apply push)" == *"Stripeco"* ]]' \
      "acme given what the control plane owes it whole, byte for byte: its code, up, told_of, every item with its id, digest and payload"
check '[[ "$(tvar "$GAMMA" client-apply push)" == "$DUE_GAMMA" ]]' "and gamma"
check '[[ "$(settled acme)" == "$APPLIED_ACME" && "$(settled gamma)" == "$APPLIED_GAMMA" ]]' \
      "the control plane given each client's answer as it came, byte for byte, in one settle each"
check '[[ "$(tvar cp cp-settle run)" == 4242 && "$(tsql cp cp-settle)" == *"erp_meta.settle_incident_pushes(:'"'"'code'"'"', :'"'"'run'"'"', :'"'"'answer'"'"'::jsonb)"* ]]' \
      "settled with the run's id"
check '[[ "$(tsql cp cp-due)" == *"erp_meta.incident_pushes_due(:'"'"'code'"'"')"* && "$(tsql cp cp-due)" == *"set statement_timeout = :'"'"'timeout'"'"';"* && "$(tvar cp cp-due timeout)" == 60s && "$(tvar cp cp-settle timeout)" == 60s ]]' \
      "what is owed, and the settle, under the control plane's own limit"
apply_sql=$(tsql "$ACME" client-apply)
check '[[ "$apply_sql" == *"\\set VERBOSITY terse"* && "$apply_sql" == *"\\set SHOW_CONTEXT never"* && "$apply_sql" == *"set statement_timeout = :'"'"'timeout'"'"';"* && "$(tvar "$ACME" client-apply timeout)" == 30s ]]' \
      "applied under the client's limit, terse, with no context"
check '[[ "$apply_sql" == *"select erp_meta.apply_pushed_incidents(:'"'"'push'"'"'::jsonb)::text;"* && "$(grep -c "apply_pushed_incidents" <<< "$apply_sql")" == 1 ]]' \
      "everything in one statement, as a variable"
check '[[ "$(tsql cp cp-settle)" == *"\\set SHOW_CONTEXT never"* ]]' "the settle with no context either"
# The push and the answer reach psql through a file it reads itself.
n_apply=$(last "$ACME" client-apply)
n_settle=$(first cp cp-settle)
check '[[ "$apply_sql" == *"\\set push \`cat :'"'"'push_file'"'"'\`"* && "$(tsql cp cp-settle)" == *"\\set answer \`cat :'"'"'answer_file'"'"'\`"* ]]' \
      "the push and the answer each read by psql from a file (\\set \`cat\`), not given as a variable"
check '[[ "$(v "$n_apply" push_file)" == "$work/tmp/fleet_incident_sync."*"/push.json" && "$(v "$n_settle" answer_file)" == "$work/tmp/fleet_incident_sync."*"/answer.json" ]]' \
      "each file in the run's own directory, named to psql by its path alone"
check '[[ "$(read_from "$n_apply")" == "push -rw------- $(v "$n_apply" push_file)" && "$(read_from "$n_settle")" == "answer -rw------- $(v "$n_settle" answer_file)" ]]' \
      "each file readable by the script alone (600) when psql reads it"
check '[[ "$(argv "$n_apply")" -lt 1024 && "$(argv "$n_settle")" -lt 1024 && "$(bytes "$DUE_ACME")" -gt 2048 ]]' \
      "no argument psql is given carries what is owed or what was answered"
check '[[ " $(present "$n_settle") " != *" push.json "* && " $(present "$n_settle") " == *" answer.json "* && " $(present "$(first "$GAMMA" client-state)") " != *".json "* && " $(present "$(first "$GAMMA" client-state)") " != *" out "* ]]' \
      "acme's push gone before its settle, and its answer before gamma is asked anything"
check '[[ -z "$(left_behind)" ]]' "and nothing left behind when the run is done"
check '[[ "$(tsql "$ACME" client-state)" == *"set statement_timeout = :'"'"'timeout'"'"';"*"erp.deployment_kind()"*"to_regprocedure('"'"'erp_meta.apply_pushed_incidents(jsonb)'"'"')"* ]]' \
      "the check before it, under the limit too"
bad=""
for n in $(awk '$3 != "vault-get" && $3 != "event" { print $1 }' "$FAKE_DIR/psql.log"); do
  [[ "$(v "$n" VERBOSITY)" == terse && "$(v "$n" SHOW_CONTEXT)" == never ]] || bad="$bad $n"
done
check '[[ -z "$bad" ]]' "every statement this script sends is VERBOSITY terse and SHOW_CONTEXT never"
bad=""
for n in $(awk '$3 != "vault-get" && $3 != "event" { print $1 }' "$FAKE_DIR/psql.log"); do
  grep -q "^set statement_timeout = :'timeout';" "$FAKE_DIR/sql.$n" && [[ -n "$(v "$n" timeout)" ]] || bad="$bad $n"
done
check '[[ -z "$bad" ]]' "and every one sets its statement timeout"
check '[[ "$(tsql cp cp-clients)" == *"'"'"'built'"'"', '"'"'live'"'"', '"'"'suspended'"'"', '"'"'retiring'"'"'"* && "$(tsql cp cp-clients)" == *"d.built_at is not null"* && "$(tsql cp cp-clients)" != *"d.code ="* ]]' \
      "every client whose database is up, a retiring one only once built, never one code"
check '[[ "$out" == *"::notice::gamma: 1 item(s) wait for a severity, component, provider or timeline its database does not know yet"* && "$(outcomes gamma)" == "44444444:waiting" ]]' \
      "gamma: its window waits, a notice, green, and what it waits for is in the settle, not the log"
check '[[ "$out" == *"acme: owed 2 incident(s), 1 window(s); answered 2 applied, 1 replay; 1 told; settled 3 applied, 0 waiting, 0 failed, 1 told"* ]]' \
      "a replay counted as one, beside what was applied, and the settle's own counts said"
check '[[ "$(summary)" == *"| acme | 2 incident(s), 1 window(s) | 2 applied, 1 replay | 1 | 3 applied, 0 waiting, 0 failed, 1 told |  |"* && "$(summary)" == *"| beta | nothing due |  |  |  |  |"* && "$(summary)" == *"| gamma | 0 incident(s), 1 window(s) | 1 waiting | 0 | 0 applied, 1 waiting, 0 failed, 0 told |  |"* ]]' \
      "the summary says each, in counts and outcomes"
check 'private' "nothing carried printed, nor anything answered: no title, body, name, address, code, component or detail"

# 3. A client owed nothing is never contacted; one owed only its telling is
fresh "nobody owed anything"
answer cp "cp-due@acme" "$(DUE_NONE acme)"
answer cp "cp-due@gamma" "$(DUE_NONE gamma)"
go
check '[[ $status -eq 0 && "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;psql cp cp-due;psql cp cp-due;psql cp cp-due;" ]]' \
      "green: what each is owed asked, no connection read, no client touched, nothing settled"
check '[[ "$out" == *"acme: nothing due"* && "$out" == *"gamma: nothing due"* ]]' "and said"
fresh "a deployment the control plane says is not up"
answer cp "cp-due@acme" '{"up": false, "code": "acme", "told_of": [], "windows": [], "incidents": []}'
go
check '[[ $status -eq 0 && "$(order)" != *"${ACME}"* && -z "$(settled acme)" && -n "$(settled gamma)" ]]' "owed empty lists, so never contacted"
fresh "only its telling to report"
answer cp "cp-due@beta" "$(due beta "\"${I3}\"" "" "")"
answer "$BETA" client-apply "$TOLD_ONLY"
answer cp "cp-settle@beta" "$(settles beta 0 1 0 0 0)"
go
check '[[ $status -eq 0 && "$(order)" == *"psql cp cp-due;sleep 2;psql cp vault-get cloveerp:deployment:${BETA}:db_url;psql ${BETA} client-state;psql ${BETA} client-apply;psql cp cp-settle;"* ]]' \
      "beta, owed no item but told_of, is contacted all the same"
check '[[ "$(tvar "$BETA" client-apply push)" == "$(due beta "\"${I3}\"" "" "")" && "$(pushed "$BETA")" == "incidents ; windows ; told_of 77777777" ]]' \
      "given what it is owed whole, told_of and all"
check '[[ "$(settled beta)" == "$TOLD_ONLY" ]]' \
      "and its answer settled as it came, so client_told_at fills in"
check '[[ "$(summary)" == *"| beta | 0 incident(s), 0 window(s), 1 to say when told | no item | 1 | 0 applied, 0 waiting, 0 failed, 1 told |  |"* ]]' \
      "the summary says so"
fresh "only its telling to report, and nobody told yet"
answer cp "cp-due@beta" "$(due beta "\"${I3}\"" "" "")"
answer "$BETA" client-apply "$UNTOLD_ONLY"
go
check '[[ $status -eq 0 && "$(settled beta)" == *"\"told_at\": null"* && "$out" == *"beta: owed 0 incident(s), 0 window(s), 1 to say when told; answered no item; 0 told"* ]]' \
      "settled all the same, green: the control plane asks again next run"
fresh "only the daily check of what it holds"
answer cp "cp-due@beta" "$DUE_CHECK_BETA"
answer "$BETA" client-apply "$CHECKED_BETA"
answer cp "cp-settle@beta" "$(settles beta 0 0 0 0 0)"
go
check '[[ $status -eq 0 && "$(order)" == *"psql cp cp-due;sleep 2;psql cp vault-get cloveerp:deployment:${BETA}:db_url;psql ${BETA} client-state;psql ${BETA} client-apply;psql cp cp-settle;"* ]]' \
      "beta, owed no item and no telling but asked what it holds, is contacted, applied and settled; green"
check '[[ "$(tvar "$BETA" client-apply push)" == "$DUE_CHECK_BETA" && "$(tvar "$BETA" client-apply push)" == *"\"check_held\": true"* ]]' \
      "given what it is owed whole, check_held and all"
check '[[ "$(settled beta)" == "$CHECKED_BETA" && "$(settled beta)" == *"\"held\": [{\"id\": \"${I3}\""* ]]' \
      "and its answer settled as it came, held and all, so a copy it lost is carried again"
check '[[ "$out" == *"beta: owed 0 incident(s), 0 window(s), a check of what it holds; answered 2 held; 0 told; settled 0 applied, 0 waiting, 0 failed, 0 told"* && "$(summary)" == *"| beta | 0 incident(s), 0 window(s), a check of what it holds | 2 held | 0 | 0 applied, 0 waiting, 0 failed, 0 told |  |"* ]]' \
      "said, and the summary says so, in counts"
check 'private' "and nothing it holds printed"
fresh "the daily check beside what is owed"
answer cp "cp-due@acme" "$(due_check acme "" "$ITEM_W1" "${ITEM_I1}, ${ITEM_I2}" true)"
go
check '[[ $status -eq 0 && "$(tvar "$ACME" client-apply push)" == "$(due_check acme "" "$ITEM_W1" "${ITEM_I1}, ${ITEM_I2}" true)" && "$(settled acme)" == "$APPLIED_ACME" ]]' \
      "given whole, settled as it came"
check '[[ "$out" == *"acme: owed 2 incident(s), 1 window(s), a check of what it holds; answered 2 applied, 1 replay, 3 held; 1 told"* ]]' "and what it holds counted beside the rest"
fresh "asked what it holds, and not saying"
answer cp "cp-due@beta" "$DUE_CHECK_BETA"
answer "$BETA" client-apply "$SILENT_BETA"
go
check '[[ $status -eq 1 && "$out" == *"::error::beta: it was asked which copies it holds, and its database did not say (no held in its answer)"* ]]' \
      "red, said"
check '[[ "$(settled beta)" == "$SILENT_BETA" && -n "$(settled gamma)" ]]' "settled all the same (what it did answer stands), and the next served"
fresh "nothing owed, and no check today"
answer cp "cp-due@acme" "$(due_check acme "" "" "" false)"
answer cp "cp-due@gamma" "$(DUE_NONE gamma)"
go
check '[[ $status -eq 0 && "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;psql cp cp-due;psql cp cp-due;psql cp cp-due;" ]]' \
      "neither items, nor told_of, nor check_held: no connection read, no client touched, nothing settled"
check '[[ "$out" == *"acme: nothing due"* && "$out" == *"beta: nothing due"* && "$out" == *"gamma: nothing due"* ]]' "and said"
fresh "a check that is not true or false"
answer cp "cp-due@beta" "$(due_check beta "" "" "" '"yes"')"
go
check '[[ $status -eq 1 && "$out" == *"beta: what the control plane owes it came back in a shape this sync does not read"* && "$(order)" != *"${BETA}"* ]]' \
      "red, never connected"

# 4. The answers
fresh "everything held already"
answer "$ACME" client-apply "$(applied "" "$(ans "$W1" "held already, since 9 Oct 2026 07:00:00 UTC" "$D3" replay)" "$(ans "$I1" "held already, since 9 Oct 2026 08:05:00 UTC" "$D1" replay), ${A_I2}")"
answer cp "cp-settle@acme" "$(settles acme 0 0 0 3 0)"
go
check '[[ $status -eq 0 && "$(outcomes acme)" == "11111111:replay 22222222:replay 33333333:replay" && "$(summary)" == *"| acme | 2 incident(s), 1 window(s) | 3 replay | 0 | 3 applied, 0 waiting, 0 failed, 0 told |  |"* ]]' \
      "a replay is counted and settled, and is green"
check 'private' "and none of its words printed"
fresh "an item refused"
REFUSED_ACME=$(applied "$TOLD_ACME" "$A_W1" "$(ans "$I1" "CLOVEERP_PUSHED_CODE_HELD: this deployment holds INC-2026-0042 for an incident of its own, so the control plane's is not taken" "$D1" refused), ${A_I2}")
answer "$ACME" client-apply "$REFUSED_ACME"
answer cp "cp-settle@acme" "$(settles acme 0 1 1 2 0)"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database refused 1 item(s) (CLOVEERP_PUSHED_CODE_HELD); each is settled failed on the control plane with its full words"* ]]' \
      "red, naming the refusal and no more"
check '[[ "$(settled acme)" == "$REFUSED_ACME" && "$(outcomes acme)" == "11111111:refused 22222222:replay 33333333:applied" ]]' \
      "settled as it came, the refusal with its words and the rest beside it"
check '[[ "$(summary)" == *"| acme | 2 incident(s), 1 window(s) | 1 applied, 1 replay, 1 refused | 1 | 2 applied, 0 waiting, 1 failed, 1 told |"* ]]' \
      "the summary counts it failed"
check 'private' "and none of it printed"
check '[[ -n "$(settled gamma)" ]]' "and the next client served"
fresh "an item refused in words that name no code"
answer "$ACME" client-apply "$(applied "" "$A_W1" "${A_I1_UNCODED}, ${A_I2}")"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database refused 1 item(s) (an error that names no CLOVEERP_ code)"* && "$(outcomes acme)" == "11111111:refused 22222222:replay 33333333:applied" ]] && private' \
      "red, settled, and the words that quote it never printed"
fresh "an item not answered"
answer "$ACME" client-apply "$(applied "$TOLD_ACME" "" "${A_I1}, ${A_I2}")"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database did not answer 1 of the 3 item(s) it was sent; those are not settled, and are owed again at the next run"* && "$(outcomes acme)" == "11111111:applied 22222222:replay" ]]' \
      "red; the answer settled as it came, so the one not in it stays owed"
check '[[ "$(summary)" == *"| acme | 2 incident(s), 1 window(s) | 1 applied, 1 replay, 1 not answered |"* ]]' "and the summary says so"
fresh "an item answered with something else"
answer "$ACME" client-apply "$(applied "" "$A_W1" "$(ans "$I1" "sent on" "$D1" delivered), ${A_I2}")"
go
check '[[ $status -eq 1 && "$out" == *"answered 1 item(s) with something that is not applied, replay, waiting or refused; nothing was settled"* && -z "$(settled acme)" && -n "$(settled gamma)" ]]' \
      "red, nothing settled (the control plane takes an answer whole, and would refuse it), the next served"
fresh "an answer that is not one"
answer "$ACME" client-apply '"done"'
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database answered in a shape this sync does not read; nothing was settled"* && -z "$(settled acme)" && -n "$(settled gamma)" ]]' \
      "red, nothing settled, the next served"
fresh "an answer in the shape before 20261012060000"
answer "$ACME" client-apply "[{\"kind\":\"incident\",\"id\":\"${I1}\",\"outcome\":\"applied\"}]"
go
check '[[ $status -eq 1 && "$out" == *"answered in a shape this sync does not read"* && -z "$(settled acme)" ]]' "a list is not read either"
fresh "an answer of nothing"
answer "$ACME" client-apply ""
go
check '[[ $status -eq 1 && "$out" == *"acme: what it is owed could not be applied there (no reason given)"* && -z "$(settled acme)" ]]' "red, nothing settled"
fresh "the push refused whole"
answer "$ACME" client-apply "ERROR:  CLOVEERP_PUSH_MALFORMED: the incidents and windows pushed are not applied: told_of names something that is not an incident's id" \
       "HINT:  Nothing was changed. Pass erp_meta.incident_pushes_due's answer as it came." \
       "CONTEXT:  PL/pgSQL function erp_meta.apply_pushed_incidents(jsonb) line 40 at RAISE, given ${INC1}" \
       "DETAIL:  ${INC1}"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database refused the push whole (CLOVEERP_PUSH_MALFORMED); nothing was applied or settled there, and all of it is owed again at the next run"* ]]' \
      "red, naming the refusal"
check '[[ -z "$(settled acme)" && "$(summary)" == *"| acme | 2 incident(s), 1 window(s) | refused whole |"* && -n "$(settled gamma)" ]]' \
      "nothing settled for it (there is no answer to give), and the next served"
check 'private' "no DETAIL, HINT or CONTEXT even read (terse), and nothing of it printed"
fresh "a database that turns out not to be a client's"
answer "$ACME" client-apply "ERROR:  CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the demonstration deployment, not a client's own, so it takes no incidents or maintenance from the register"
go
check '[[ $status -eq 1 && "$out" == *"its database refused the push whole (CLOVEERP_NOT_A_CLIENT_DEPLOYMENT)"* && -z "$(settled acme)" ]]' "red, nothing settled"
fresh "a statement that runs out of time"
answer "$ACME" client-apply "ERROR:  canceling statement due to statement timeout"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: what it is owed could not be applied there (a statement timeout); nothing was settled"* && -z "$(settled acme)" && -n "$(settled gamma)" ]]' \
      "red, nothing settled (it stays owed), the next served"
check '[[ " $(present "$(first "$GAMMA" client-state)") " != *".json "* && -z "$(left_behind)" ]]' \
      "its push gone before the next client, and nothing left behind"
fresh "a run cancelled while it applies"
answer "$ACME" client-apply "SIGNAL: TERM" "$APPLIED_ACME"
go
check '[[ $status -eq 143 && "$(order)" != *"psql cp cp-settle"* && "$(order)" != *"${GAMMA}"* ]]' \
      "it stops when the statement returns: nothing settled, no other client asked"
check '[[ -z "$(left_behind)" ]] && private' "and what it carried and was answered is gone with it, none of it printed"
fresh "a client that drops the connection while applying"
answer "$ACME" client-apply "ERROR:  terminating connection due to administrator command"
go
check '[[ $status -eq 1 && "$out" == *"acme: what it is owed could not be applied there (the connection failed)"* && -z "$(settled acme)" ]]' "red, nothing settled"
fresh "a settle the control plane refuses"
answer cp "cp-settle@acme" "ERROR:  CLOVEERP_PUSH_SETTLE_UNREADABLE: what acme answered of its incidents and windows is not settled: incident answer 1 says none of applied, replay, waiting or refused" \
       "DETAIL:  ${INC1}"
go
check '[[ $status -eq 1 && "$out" == *"acme: what it answered could not be settled on the control plane (CLOVEERP_PUSH_SETTLE_UNREADABLE)"* && -n "$(settled gamma)" ]]' \
      "red, the code alone said, and the next client served"
check 'private' "nothing of what the refusal quoted printed"

# 5. However large: whole, through files, and gone after
CURRENT="the fixtures"
check '[[ $(bytes "$ITEM_BIG") -gt 204800 && $(bytes "$DUE_BIG") -gt 204800 && $(bytes "$APPLIED_MANY") -gt 204800 ]]' \
      "an incident, and an answer, each of more than 200 KB: more than one argument holds on a runner"
fresh "an incident of more than 200 KB"
answer cp "cp-due@acme" "$DUE_BIG"
answer "$ACME" client-apply "$APPLIED_BIG"
answer cp "cp-settle@acme" "$(settles acme 0 0 0 2 0)"
go
check '[[ $status -eq 0 && "$(pushed "$ACME")" == "incidents 88888888; windows 33333333; told_of " && "$(outcomes acme)" == "88888888:applied 33333333:applied" ]]' \
      "carried and settled, green"
check '[[ "$(tvar "$ACME" client-apply push)" == "$DUE_BIG" ]]' \
      "given whole, byte for byte, as the control plane wrote it: nothing cut, packed or re-encoded"
check '[[ "$(argv "$(last "$ACME" client-apply)")" -lt 1024 ]]' "and none of it in an argument"
check '[[ "$(settled acme)" == "$APPLIED_BIG" ]]' "the answer settled as it came"
check '[[ "$out" == *"acme: owed 1 incident(s), 1 window(s); answered 2 applied; 0 told; settled 2 applied, 0 waiting, 0 failed, 0 told"* && -n "$(settled gamma)" ]]' \
      "said in counts, and the next client served"
check 'private && [[ -z "$(left_behind)" ]]' "nothing of it printed, and nothing left behind"
fresh "an answer of more than 200 KB"
answer "$ACME" client-apply "$APPLIED_MANY"
go
check '[[ $status -eq 0 && "$(settled acme)" == "$APPLIED_MANY" && "$(argv "$(first cp cp-settle)")" -lt 1024 ]]' \
      "settled as it came, byte for byte, none of it in an argument; green"
check '[[ -z "$(left_behind)" ]]' "and nothing left behind"
fresh "more than the sanity limit owed"
answer cp "cp-due@acme" "$DUE_BIG"
go MAX_PUSH_BYTES=100000
check '[[ $status -eq 1 && "$out" == *"::error::acme: what it is owed is $(bytes "$DUE_BIG") bytes, more than the 100000 one run carries to a client (MAX_PUSH_BYTES); nothing was sent there or settled, and all of it stays owed"* ]]' \
      "red, said out loud with its size"
check '[[ "$(order)" != *"${ACME}"* && -z "$(settled acme)" && -n "$(settled gamma)" ]]' \
      "nothing sent, its connection never read, nothing settled, the next served"
check '[[ "$(summary)" == *"| acme | 1 incident(s), 1 window(s) | none sent |"* ]] && private' "the summary says so, and nothing of it printed"
fresh "an answer past the sanity limit"
answer "$ACME" client-apply "$APPLIED_MANY"
go MAX_PUSH_BYTES=100000
check '[[ $status -eq 1 && "$out" == *"::error::acme: its answer is $(bytes "$APPLIED_MANY") bytes, more than the 100000 one run settles for a client (MAX_PUSH_BYTES); nothing was settled"* ]]' \
      "red, said out loud with its size"
check '[[ -z "$(settled acme)" && -n "$(settled gamma)" && -z "$(left_behind)" ]]' "nothing settled for it, the next served, nothing left behind"

# 6. A client that cannot be served settles nothing
fresh "a client that cannot be reached"
echo "FATAL:  Tenant or user not found" > "$FAKE_DIR/answers/${ACME}/CONNECT"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database could not be reached or read"*"nothing settled"* ]]' "red, said"
check '[[ -z "$(settled acme)" && -n "$(settled gamma)" ]]' "nothing settled for it, and the next client served"
fresh "a client a release behind"
answer "$ACME" client-state "client|false"
go
check '[[ $status -eq 0 && "$out" == *"::notice::acme has not yet been released the routine that holds the incidents and maintenance it is carried (20261012060000)"* && "$out" == *"but 1 of 3 not yet released the routine"* ]]' \
      "noted, green"
check '[[ "$(order)" != *"${ACME} client-apply"* && -z "$(settled acme)" && "$(summary)" == *"| acme | 2 incident(s), 1 window(s) | not released the routine yet |"* ]]' "nothing applied or settled for it"
fresh "a database that is not a client's"
answer "$ACME" client-state "demonstration|true"
go
check '[[ $status -eq 1 && "$out" == *"acme: its database says it is the demonstration deployment, not a client"* && "$(order)" != *"${ACME} client-apply"* && -z "$(settled acme)" ]]' "refused, nothing applied"
fresh "no connection in the vault"
rm -f "$FAKE_DIR/vault/cloveerp_deployment_${GAMMA}_db_url"
go
check '[[ $status -eq 1 && "$out" == *"gamma: the control plane'"'"'s vault has no cloveerp:deployment:${GAMMA}:db_url"* && "$(order)" != *"${GAMMA} client"* && -z "$(settled gamma)" && -n "$(settled acme)" ]]' \
      "red, never connected, the others served"
fresh "a connection that names another project"
printf '%s' "postgresql://postgres.${ACME}:pw@pooler.example:5432/postgres?also=${PROD}" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
go
check '[[ $status -eq 1 && "$out" == *"names another deployment'"'"'s project (${PROD})"* && "$(order)" != *"${ACME} client"* ]]' "refused, never connected"
fresh "a connection that names another client"
printf '%s' "$GAMMA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
go
check '[[ $status -eq 1 && "$out" == *"does not name its project (${ACME})"* && "$(calls "$GAMMA" client-state | wc -w | tr -d " ")" == 1 ]]' "refused, never connected"
fresh "a register row with no ref"
answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"not-a-ref\"},{\"code\":\"gamma\",\"ref\":\"${GAMMA}\"}]"
go
check '[[ $status -eq 1 && "$out" == *"acme: the register gives it no project ref"* && "$(dues)" == "gamma " ]]' "red, nothing asked for it"
fresh "what is owed cannot be read"
answer cp "cp-due@acme" "ERROR:  canceling statement due to statement timeout"
go
check '[[ $status -eq 1 && "$out" == *"acme: what the control plane owes it could not be read (a statement timeout)"* && "$(order)" != *"${ACME}"* && -n "$(settled gamma)" ]]' \
      "red, never connected, the next served"
fresh "what is owed in a shape the sync does not read"
answer cp "cp-due@acme" '[1, 2]'
go
check '[[ $status -eq 1 && "$out" == *"in a shape this sync does not read"* && "$(order)" != *"${ACME}"* ]]' "red, never connected"
fresh "what is owed in the shape before 20261012060000"
answer cp "cp-due@acme" "{\"incidents\": [${ITEM_I1}], \"windows\": []}"
go
check '[[ $status -eq 1 && "$out" == *"in a shape this sync does not read"* && "$(order)" != *"${ACME}"* ]]' "no code or told_of: red, never connected"
fresh "what is owed for another client"
answer cp "cp-due@acme" "$(due gamma "" "$ITEM_W1" "${ITEM_I1}, ${ITEM_I2}")"
go
check '[[ $status -eq 1 && "$out" == *"acme: what the control plane owes it came back in a shape this sync does not read"* && "$(order)" != *"${ACME}"* ]]' \
      "red, never connected: one client is never given another's"
fresh "an item owed with no id or digest"
answer cp "cp-due@acme" "$(due acme "" "$ITEM_W1" "${ITEM_NO_ID}, ${ITEM_NO_DIGEST}, ${ITEM_I1}")"
go
check '[[ $status -eq 1 && "$out" == *"acme: what the control plane owes it came back in a shape this sync does not read; nothing was applied there"* && "$(order)" != *"${ACME}"* && -n "$(settled gamma)" ]]' \
      "red, never connected: it is given whole or not at all"
check 'private' "and nothing of it printed"
fresh "windows alone"
answer cp "cp-due@acme" "$(due acme "" "$ITEM_W1" "")"
answer "$ACME" client-apply "$(applied "" "$A_W1" "")"
go
check '[[ $status -eq 0 && "$(pushed "$ACME")" == "incidents ; windows 33333333; told_of " && "$(outcomes acme)" == "33333333:applied" ]]' "read with no incidents at all"

# 7. Nothing secret printed
fresh "on a runner"
go GITHUB_ACTIONS=true
check '[[ $status -eq 0 ]]' "green"
for secret in "$ACME_URL" "$GAMMA_URL" "$CP"; do
  CASES=$((CASES + 1))
  if [[ "$(printf "%s\n" "$out" | grep -F -- "$secret" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -cxF -- "::add-mask::$secret")" == 1 ]]; then
    echo "  ok   $CURRENT: ${secret:0:24}… masked, and printed nowhere else"
  else
    FAILED=$((FAILED + 1)); echo "  FAIL $CURRENT: ${secret:0:24}… printed unmasked, or never masked"
  fi
done
check '[[ "$(printf "%s\n" "$out" | grep -n "^::add-mask::${CP}$" | cut -d: -f1)" == 1 ]]' "the control plane's first of all"
check '[[ "$out" != *"$BETA_URL"* ]]' "beta's never read, so never printed even masked"
check 'private' "nothing carried printed"
fresh "outside a runner"
go
check '[[ $status -eq 0 && "$out" != *"::add-mask::"* && "$out" != *"-password@"* ]]' "no mask line, and nothing secret"

# 8. The job in fleet_sweep.yml, and its step as the runner runs it
fresh "the job in fleet_sweep.yml"
# job_block <job>: that job's lines, from its key to the next job's.
job_block() { awk -v j="  $1:" '$0 == j { on = 1; print; next } on && /^  [A-Za-z0-9_-]+:[ ]*$/ { exit } on && /^[^ #]/ { exit } on' "$WF"; }
inc=$(job_block "$JOB")
swp=$(job_block sweep)
top=$(awk '/^jobs:/ { exit } { print }' "$WF")
check '[[ "$top" == *"  schedule:"*"    - cron: '"'"'*/10 * * * *'"'"'"*"  workflow_dispatch:"* ]]' "the sweep runs every ten minutes and on its wake"
check '[[ "$top" == *"erp_meta.incident_change_wakes_the_sweep"* && "$top" != *"doors call"* ]]' \
      "and says the wake for an incident is a trigger on the tables its doors write, not the doors"
check '[[ -n "$inc" && "$inc" != *"needs:"* && "$inc" != *"if:"*"github.event"* ]]' "the job runs on both, beside the sweep, never waiting for it"
check '[[ "$inc" == *"    concurrency:"$'"'"'\n'"'"'"      group: fleet-incidents"$'"'"'\n'"'"'"      cancel-in-progress: false"* ]]' \
      "a concurrency group of its own, a run never cancelled while it applies"
check '[[ "$swp" == *"    concurrency:"$'"'"'\n'"'"'"      group: fleet-sweep"$'"'"'\n'"'"'"      cancel-in-progress: false"* && "$top" != *$'"'"'\n'"'"'"concurrency:"* && "$top" != "concurrency:"* ]]' \
      "the sweep keeps its own, on its job, and the workflow holds neither"
check '[[ "$inc" == *"    permissions:"$'"'"'\n'"'"'"      contents: read"* && "$inc" != *"actions: write"* && "$inc" == *"timeout-minutes:"* ]]' \
      "contents read and nothing more, and a time limit"
check '[[ "$inc" == *"CLOVEERP_LIVE_DATABASE_URL: \${{ secrets.CLOVEERP_LIVE_DATABASE_URL }}"* && "$inc" == *"PRODUCTION_REF: "* && "$inc" == *"DEMO_REF: "* ]]' \
      "the control plane from its secret, and the refs a client's connection must not name"
runs=$(printf '%s\n' "$inc" | awk '/^ *run: [|]/ { on = 1; next } on && /^ *- (name|uses):/ { on = 0 } on')
check '[[ -n "$runs" && "$runs" != *"\${{"* ]]' "nothing reaches its run: blocks but through the environment"
script=$(workflow_step "$WF" "$STEP")
check '[[ "$script" == *"supabase/ci/fleet_incident_sync.sh"* && "$(printf "%s\n" "$inc" | grep -cF -- "- name: ${STEP}")" == 1 ]]' "the step is this job's"
CODE_RUN() {
  out=$(cd "$HERE/../.." && env -u GITHUB_ACTIONS PATH="$work/bin:$PATH" FAKE_CP_URL="$CP" PRODUCTION_REF="$PROD" DEMO_REF="$DEMO" \
          GITHUB_RUN_ID=4242 GITHUB_STEP_SUMMARY="$work/summary" TMPDIR="$work/tmp" "$@" bash -c "$script" 2>&1)
  status=$?
}
CODE_RUN CLOVEERP_LIVE_DATABASE_URL="$CP"
check '[[ -n "$script" && $status -eq 0 && "$(dues)" == "acme beta gamma " && "$(settled acme)" == "$APPLIED_ACME" && "$(settled gamma)" == "$APPLIED_GAMMA" ]]' \
      "as the runner runs it: every client asked after, each served"
fresh "the step with no control plane"
CODE_RUN CLOVEERP_LIVE_DATABASE_URL=
check '[[ $status -eq 1 && "$out" == *"::error::CLOVEERP_LIVE_DATABASE_URL is not set"* ]] && untouched' "red, nothing touched"

echo "$CASES checks over the incidents and maintenance carried to each client, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
