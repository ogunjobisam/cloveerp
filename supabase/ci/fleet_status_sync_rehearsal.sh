#!/usr/bin/env bash
#
# supabase/ci/fleet_status_sync.sh, rehearsed with no database.
#
# The sync runs every hour, and at once whenever a client is suspended,
# reinstated or offboarded, against every client's own project, and what it
# does there is suspend a paying client's organisation or lift a suspension:
# wrong one way, a suspended client trades on; wrong the other, a paying one
# is shut out, or a suspension its own console made is lifted by the fleet.
# So every build runs it here first, against the shared stand-ins
# (fleet_rehearsal_fakes.sh: a psql that answers from files by database and
# statement, and keeps the vault and the events): what it refuses before
# touching anything, that each client up is told the register's word and its
# reason, that a change is written on the client's row and nothing is
# written when it is in step (a client with no organisation yet included),
# that a suspension made on the client's own
# console is left and said, that one client's trouble never stops the next
# and is not written twice in a row, that every statement on a client
# carries a timeout, and that no connection string and no reason is printed.
# Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_status_sync.sh"
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
REASON="Unpaid since August; Jane Doe at jane.doe@acme.example asked us to hold"
export FAKE_DIR="$work/fake"

BASE_ENV=(FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" PSQL="$work/bin/psql" FLEET_SLEEP="$work/bin/sleep"
          PRODUCTION_REF="$PROD" DEMO_REF="$DEMO" TMPDIR="$work/tmp")

# clients <json>: what the register says of the clients up.
clients() { answer cp cp-clients "$1"; }
LIVE_ACME="{\"code\":\"acme\",\"ref\":\"${ACME}\",\"status\":\"live\",\"suspended\":false,\"reason\":\"\"}"
SUSP_ACME="{\"code\":\"acme\",\"ref\":\"${ACME}\",\"status\":\"suspended\",\"suspended\":true,\"reason\":\"${REASON}\"}"
LIVE_BETA="{\"code\":\"beta\",\"ref\":\"${BETA}\",\"status\":\"live\",\"suspended\":false,\"reason\":\"\"}"
RETIRING_GAMMA="{\"code\":\"gamma\",\"ref\":\"${GAMMA}\",\"status\":\"retiring\",\"suspended\":true,\"reason\":\"Offboarding while unpaid\"}"
IN_STEP_ACTIVE='{"changed":false,"status":"active","by_fleet":false}'

# The register and the clients as they are on a good day: acme suspended by
# the owner, beta live, gamma being offboarded while suspended; each
# connection in the vault and each database released the routine.
seed() {
  printf '%s' "$ACME_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
  printf '%s' "$BETA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${BETA}_db_url"
  printf '%s' "$GAMMA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${GAMMA}_db_url"
  answer cp cp-ready "true|true"
  clients "[${SUSP_ACME},${LIVE_BETA},${RETIRING_GAMMA}]"
  answer cp cp-refs "${ACME},${BETA},${GAMMA},eeeeeeeeeeeeeeeeeeee"
  answer "$ACME" client-state "client|true"
  answer "$BETA" client-state "client|true"
  answer "$GAMMA" client-state "client|true"
  answer "$ACME" client-follow '{"changed":true,"status":"suspended","by_fleet":true}'
  answer "$BETA" client-follow "$IN_STEP_ACTIVE"
  answer "$GAMMA" client-follow '{"changed":true,"status":"suspended","by_fleet":true}'
}

CASES=0
FAILED=0
# run <name> [@db:tag=answer | VAR=value ...] -- <arguments>
run() {
  CURRENT="$1"; shift
  local vars=() a db rest
  rm -rf "$FAKE_DIR" "$work/tmp"; mkdir -p "$FAKE_DIR/vault" "$work/tmp"
  seed
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      @*) a="${1#@}"; db="${a%%:*}"; rest="${a#*:}"; answer "$db" "${rest%%=*}" "${rest#*=}" ;;
      *) vars+=("$1") ;;
    esac
    shift
  done
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
    printf '%s\n' "$out" | sed 's/^/       | /' | head -n 20
    sed 's/^/       > /' "$FAKE_DIR/order.log" 2> /dev/null | head -n 40
  fi
}
order() { tr '\n' ';' 2> /dev/null < "$FAKE_DIR/order.log"; }
events() { cat "$FAKE_DIR/events" 2> /dev/null; }
untouched() { [[ ! -s "$FAKE_DIR/order.log" ]]; }
follows() { grep -c "client-follow$" "$FAKE_DIR/order.log" 2> /dev/null || true; }
# tvar <database> <tag> <name>: what the last statement of that tag on that database was given.
tvar() {
  local n
  n=$(awk -v d="$1" -v t="$2" '$2 == d && $3 == t { n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  if [[ -n "$n" ]]; then sed -n "s/^$3=//p" "$FAKE_DIR/vars.$n" | head -n 1; fi
}
tsql() {
  local n
  n=$(awk -v d="$1" -v t="$2" '$2 == d && $3 == t { n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  [[ -z "$n" ]] || cat "$FAKE_DIR/sql.$n"
}

# 1. Refused before anything is touched
run "no control plane" CLOVEERP_LIVE_DATABASE_URL= --
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* ]] && untouched' "refused"
run "a code that is not one" -- "Acme!"
check '[[ $status -eq 2 && "$out" == *"is not a client'"'"'s code"* ]] && untouched' "refused"
run "a pause that is not one" PAUSE_SECONDS=soon --
check '[[ $status -eq 2 ]] && untouched' "refused"
run "a control plane that cannot be read" "@cp:cp-ready=ERROR:  could not connect" --
check '[[ $status -eq 1 && "$out" == *"the control plane could not be read"* && "$(order)" == "psql cp cp-ready;" ]]' "red, nothing else asked"
run "a control plane with no register" "@cp:cp-ready=false|false" --
check '[[ $status -eq 0 && "$out" == *"no register of deployments yet"* && "$(order)" == "psql cp cp-ready;" ]]' "nothing to do, and green"
run "a control plane before suspensions had reasons" "@cp:cp-ready=true|false" --
check '[[ $status -eq 0 && "$out" == *"cannot say which clients are suspended yet (20261012030000"* && "$(order)" == "psql cp cp-ready;" ]]' \
      "nothing followed: not knowing is not \"nobody is suspended\""
run "nobody up" "@cp:cp-clients=[]" --
check '[[ $status -eq 0 && "$out" == *"nobody to follow it"* && "$(follows)" == 0 ]]' "nothing to do"
run "a code the register does not have" "@cp:cp-clients=[]" "@cp:cp-status=" -- zeta
check '[[ $status -eq 1 && "$out" == *"zeta'"'"' is not in the control plane"* ]]' "red"
run "a code that is not up" "@cp:cp-clients=[]" "@cp:cp-status=retired" -- omega
check '[[ $status -eq 0 && "$out" == *"omega is retired: only a client whose database is up"* ]]' "a notice, and green"

# 2. Every client up follows the register
run "the fleet" --
check '[[ $status -eq 0 && "$out" == *"every client'"'"'s organisation follows the register (3)"* ]]' "green"
check '[[ "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;psql cp vault-get cloveerp:deployment:${ACME}:db_url;psql ${ACME} client-state;psql ${ACME} client-follow;event acme note note;sleep 2;psql cp vault-get cloveerp:deployment:${BETA}:db_url;psql ${BETA} client-state;psql ${BETA} client-follow;sleep 2;psql cp vault-get cloveerp:deployment:${GAMMA}:db_url;psql ${GAMMA} client-state;psql ${GAMMA} client-follow;event gamma note note;" ]]' \
      "one at a time, a pause between, each from its own connection; a row written only where something changed"
check '[[ "$(tvar "$ACME" client-follow suspended)" == true && "$(tvar "$ACME" client-follow reason)" == "$REASON" ]]' "acme is told it is suspended, and why"
check '[[ "$(tvar "$BETA" client-follow suspended)" == false && -z "$(tvar "$BETA" client-follow reason)" ]]' "beta is told it is not"
check '[[ "$(tvar "$GAMMA" client-follow suspended)" == true ]]' "gamma, offboarding while suspended, stays suspended"
check '[[ "$(events)" == "acme|note|note|status: its organisation suspended on its own database, as the register says (fleet_sync.yml)
gamma|note|note|status: its organisation suspended on its own database, as the register says (fleet_sync.yml)" ]]' \
      "each change on the client's row, beginning \"status:\""
check '[[ "$(tsql "$ACME" client-follow)" == *"set statement_timeout = :'"'"'timeout'"'"';"*"erp_meta.follow_deployment_status(:'"'"'suspended'"'"'::boolean, nullif(:'"'"'reason'"'"', '"'"''"'"'))"* && "$(tvar "$ACME" client-follow timeout)" == 30s ]]' \
      "the routine, its words as variables, under a limit"
check '[[ "$(tsql "$ACME" client-state)" == *"set statement_timeout = :'"'"'timeout'"'"';"*"follow_deployment_status(boolean,text)"* ]]' "and the check before it, too"
check '[[ "$(tsql cp cp-clients)" == *"suspended_reason is not null"*"'"'"'built'"'"', '"'"'live'"'"', '"'"'suspended'"'"', '"'"'retiring'"'"'"* ]]' \
      "the register asked for every client whose database is up, and suspended means a reason is held"
check '[[ "$(cat "$work/summary")" == *"| acme | suspended | suspended | yes |  |"*"| beta | not suspended | active |  |  |"* ]]' "the summary says each"
run "a client reinstated" "@cp:cp-clients=[${LIVE_ACME}]" "@${ACME}:client-follow={\"changed\":true,\"status\":\"active\",\"by_fleet\":false}" --
check '[[ $status -eq 0 && "$(tvar "$ACME" client-follow suspended)" == false && "$(events)" == "acme|note|note|status: its organisation active again on its own database, as the register says (fleet_sync.yml)" ]]' \
      "the suspension lifted, and said"
run "one client asked for" -- acme
check '[[ $status -eq 0 && "$(tvar cp cp-clients only)" == acme && "$(follows)" == 3 ]]' "the register asked for it alone (the stand-in answers the same)"
run "a client suspended on its own console" "@cp:cp-clients=[${LIVE_ACME}]" "@${ACME}:client-follow={\"changed\":false,\"status\":\"suspended\",\"by_fleet\":false}" --
check '[[ $status -eq 0 && "$out" == *"acme'"'"'s organisation is suspended on its own console, not by the fleet, so it is left as it is"* && -z "$(events)" ]]' \
      "left as it is, said, nothing written"
run "a client in step" "@${ACME}:client-follow={\"changed\":false,\"status\":\"suspended\",\"by_fleet\":true}" "@${GAMMA}:client-follow={\"changed\":false,\"status\":\"suspended\",\"by_fleet\":true}" --
check '[[ $status -eq 0 && -z "$(events)" && "$out" == *"acme: in step (suspended)"* ]]' "nothing written"
# A client is built with no organisation, and has one once it is onboarded:
# the routine's answer then (jsonb as psql prints it) is a client in step.
NO_ORG='{"status": null, "changed": false, "by_fleet": false}'
BUILT_BETA="{\"code\":\"beta\",\"ref\":\"${BETA}\",\"status\":\"built\",\"suspended\":false,\"reason\":\"\"}"
run "a client with no organisation yet" "@cp:cp-clients=[${SUSP_ACME},${BUILT_BETA},${RETIRING_GAMMA}]" "@${BETA}:client-follow=${NO_ORG}" --
check '[[ $status -eq 0 && "$out" == *"beta: no organisation yet, so nothing to follow"* && "$out" != *"::error::"* && "$out" == *"every client'"'"'s organisation follows the register (3)"* ]]' \
      "green, and said: nothing to follow is not trouble"
check '[[ "$(events)" != *"beta|"* && "$(follows)" == 3 && "$(cat "$work/summary")" == *"| beta | not suspended | no organisation yet |  |  |"* ]]' \
      "nothing written on its row, the others followed, and the summary says no organisation yet"
run "the sync a client's build asks for, before it is onboarded" "@cp:cp-clients=[${BUILT_BETA}]" "@${BETA}:client-follow=${NO_ORG}" -- beta
check '[[ $status -eq 0 && -z "$(events)" && "$(tvar cp cp-clients only)" == beta && "$out" == *"1 of 1 client(s) with no organisation yet"* ]]' \
      "green: deployment_from_empty.yml's sync of a new client is not red"
run "a client suspended before it is onboarded" "@cp:cp-clients=[${SUSP_ACME}]" "@${ACME}:client-follow=${NO_ORG}" --
check '[[ $status -eq 0 && -z "$(events)" && "$(cat "$work/summary")" == *"| acme | suspended | no organisation yet |"* && "$(tvar "$ACME" client-follow suspended)" == true ]]' \
      "told it is suspended; nothing there to suspend, nothing written, green"
run "an answer with no status that is not the routine's" "@${ACME}:client-follow={\"changed\":true,\"status\":null}" --
check '[[ $status -eq 1 && "$out" == *"acme: its database answered something that is not what the routine answers"* ]]' \
      "red: a change with no status is not the empty client's answer"
run "an answer that says nothing of a status" "@${ACME}:client-follow={\"changed\":false}" --
check '[[ $status -eq 1 && "$out" == *"not what the routine answers"* ]]' "red"

run "a client not yet released the routine" "@${BETA}:client-state=client|false" --
check '[[ $status -eq 0 && "$out" == *"beta has not yet been released the routine"*"20261012030000"* && "$out" == *"but 1 of 3 not yet released the routine"* ]]' \
      "a notice, green, and the others followed"
check '[[ "$(order)" != *"${BETA} client-follow"* && "$(follows)" == 2 ]]' "nothing asked of it"

# 3. One client's trouble never stops the next
run "a client that cannot be reached" "@${ACME}:client-state=ERROR:  could not connect to server" --
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database could not be reached or read (ERROR: could not connect to server); nothing was changed there"* && "$(follows)" == 2 ]]' \
      "red, said, and the others followed"
check '[[ "$(events)" == "acme|note|failed|status: not followed on its own database: its database could not be reached or read"*"(fleet_sync.yml)"*"gamma|note|note|"* ]]' "acme's row says so"
run "the same trouble the hour after" "@${ACME}:client-state=ERROR:  could not connect to server" \
    "@cp:cp-last-note=failed status: not followed on its own database: its database could not be reached or read (ERROR: could not connect to server); nothing was changed there (fleet_sync.yml)" --
check '[[ $status -eq 1 && "$out" == *"acme: the register already says so"* && "$(events)" != *"acme|note|failed"* ]]' "red, and not written twice in a row"
run "a routine that refuses" "@${GAMMA}:client-follow=ERROR:  CLOVEERP_DEPLOYMENT_STATE: not a client" --
check '[[ $status -eq 1 && "$out" == *"gamma: its organisation could not be made to follow the register (ERROR: CLOVEERP_DEPLOYMENT_STATE: not a client)"* && "$(events)" == *"gamma|note|failed|"* ]]' "red, said"
run "a routine that leaves it active" "@${ACME}:client-follow={\"changed\":false,\"status\":\"active\",\"by_fleet\":false}" --
check '[[ $status -eq 1 && "$out" == *"acme: the register has it suspended, and its organisation is active after the routine ran"* ]]' "red: the register's word did not take"
run "an answer that is not the routine's" "@${ACME}:client-follow=1" --
check '[[ $status -eq 1 && "$out" == *"not what the routine answers"* ]]' "red"
run "no connection in the vault" --
rm -f "$FAKE_DIR/vault/cloveerp_deployment_${BETA}_db_url"; rm -rf "$FAKE_DIR/order.log" "$FAKE_DIR/events" "$FAKE_DIR/psql."* "$FAKE_DIR/count."*
out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 "${BASE_ENV[@]}" bash "$SCRIPT" 2>&1); status=$?
check '[[ $status -eq 1 && "$out" == *"beta: the control plane'"'"'s vault has no cloveerp:deployment:${BETA}:db_url"* && "$(order)" != *"${BETA} client"* && "$(follows)" == 2 ]]' \
      "red, never connected, the others followed"
run "a connection that names another project" "@cp:cp-clients=[${SUSP_ACME}]" --
printf '%s' "postgresql://postgres.${ACME}:pw@pooler.example:5432/postgres?also=${BETA}" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
rm -rf "$FAKE_DIR/order.log" "$FAKE_DIR/events"
out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 "${BASE_ENV[@]}" bash "$SCRIPT" 2>&1); status=$?
check '[[ $status -eq 1 && "$out" == *"names another deployment'"'"'s project (${BETA})"* && "$(order)" != *"${ACME} client"* ]]' "refused, never connected"
run "a database that is not a client's" "@${ACME}:client-state=demonstration|true" --
check '[[ $status -eq 1 && "$out" == *"acme: its database says it is the demonstration deployment"* && "$(order)" != *"${ACME} client-follow"* ]]' "refused"
run "a trouble naming somebody" "@${ACME}:client-follow=ERROR:  permission denied for jane.doe@acme.example" --
check '[[ $status -eq 1 && "$out" != *"jane.doe@acme.example"* && "$out" == *"j…@acme.example"* && "$(events)" != *"jane.doe@"* && "$(cat "$work/summary")" != *"jane.doe@"* ]]' \
      "the address shortened in the log, the summary and the row"

# 4. Nothing secret printed, and no reason
run "on a runner" GITHUB_ACTIONS=true --
check '[[ $status -eq 0 ]]' "green"
for secret in "$ACME_URL" "$BETA_URL" "$GAMMA_URL"; do
  CASES=$((CASES + 1))
  if [[ "$(printf "%s\n" "$out" | grep -F -- "$secret" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -cxF -- "::add-mask::$secret")" == 1 ]]; then
    echo "  ok   $CURRENT: ${secret:0:24}… masked, and printed nowhere else"
  else
    FAILED=$((FAILED + 1)); echo "  FAIL $CURRENT: ${secret:0:24}… printed unmasked, or never masked"
  fi
done
check '[[ "$out" != *"Unpaid since August"* && "$out" != *"jane.doe"* && "$(cat "$work/summary")" != *"Unpaid"* && "$(events)" != *"Unpaid"* ]]' \
      "the owner's reason, given to the client's database, is printed nowhere: not the log, the summary or the row"
check '[[ "$out" != *"control-plane-password"* ]]' "nor the control plane's connection"
run "outside a runner" --
check '[[ $status -eq 0 && "$out" != *"::add-mask::"* && "$out" != *"-password@"* ]]' "no mask line, and nothing secret"

echo "$CASES checks over each client's organisation following the register, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
