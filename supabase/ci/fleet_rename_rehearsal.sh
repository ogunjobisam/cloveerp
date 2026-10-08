#!/usr/bin/env bash
#
# supabase/ci/fleet_rename.sh, rehearsed with no database and no Management
# API.
#
# A rename moves a paying client to a new address in four places that must
# agree: its project's auth settings, its functions' address, its own
# database (where it is served, and its organisation's code) and the control
# plane's register. Half a rename is a client whose sign-in links go to an
# address nobody serves, or whose organisation no longer matches the address
# it is served at. So every build runs it here first, against a psql that
# answers from files and a curl that answers from a script, both writing
# what they were asked in one log, in order: what it refuses before touching
# anything, and that it settles only the request that is its own; the four
# places in that order with an event for each; every step undone when a
# later one fails, and what could not be undone said; a commit whose answer
# was lost taken as a commit; a rename that stopped carried on when asked
# again; and nothing secret printed. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_rename.sh"
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
CP="postgresql://postgres.${PROD}:control-plane-password@pooler.example:5432/postgres"
ACME_URL="postgresql://postgres.${ACME}:acme-database-password@pooler.example:5432/postgres"
REQ=0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
OLD=https://acme.cloveerp.com
NEW=https://acme-foods.cloveerp.com
export FAKE_DIR="$work/fake"

BASE_ENV=(FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" PSQL="$work/bin/psql" CURL="$work/bin/curl"
          API="https://api.example" MAPI_SLEEP="$work/bin/sleep" SUPABASE_ACCESS_TOKEN=rehearsal-access-token
          RESEND_API_KEY=re_rehearsal_resend_key MAIL_FROM=noreply@cloveerp.com APEX=cloveerp.com
          PRODUCTION_REF="$PROD" DEMO_REF="$DEMO" TMPDIR="$work/tmp")
ARGS=(acme acme acme-foods "$REQ")

# The request the console made, the register and the client as they are on
# a good day.
seed() {
  printf '%s' "$ACME_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
  answer cp cp-ready true
  answer cp cp-request "claimed|rename|acme|acme|acme-foods"
  answer cp cp-row "live|${ACME}|acme"
  answer cp cp-refs "${BETA}"
  answer "$ACME" client-check "client|acme|true"
}

CASES=0
FAILED=0
# run <name> [@db:tag=answer | -vault | %vault=<url> | VAR=value ...] -- <arguments>
run() {
  CURRENT="$1"; shift
  local vars=() a db rest
  rm -rf "$FAKE_DIR" "$work/tmp"; mkdir -p "$FAKE_DIR/vault" "$work/tmp"
  seed
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      @*) a="${1#@}"; db="${a%%:*}"; rest="${a#*:}"; answer "$db" "${rest%%=*}" "${rest#*=}" ;;
      -vault) rm -f "$FAKE_DIR/vault/"* ;;
      %vault=*) printf '%s' "${1#%vault=}" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url" ;;
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
events() { cut -d'|' -f1-3 "$FAKE_DIR/events" 2> /dev/null | tr '\n' ' '; }
details() { cat "$FAKE_DIR/events" 2> /dev/null; }
untouched() { [[ ! -s "$FAKE_DIR/order.log" ]]; }
changed_nothing() { [[ "$(order)" != *"PATCH"* && "$(order)" != *"POST"* && "$(order)" != *"client-move"* && "$(order)" != *"cp-finish"* ]]; }
# tvar <tag> <name> [nth]: what the nth (default last) statement of that tag was given.
tvar() {
  local n
  if [[ -n "${3:-}" ]]; then
    n=$(awk -v t="$1" -v k="$3" '$3 == t { c++; if (c == k) n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  else
    n=$(awk -v t="$1" '$3 == t { n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  fi
  if [[ -n "$n" ]]; then sed -n "s/^$2=//p" "$FAKE_DIR/vars.$n" | head -n 1; fi
}
settled() { tvar cp-settle outcome; }
# body <nth curl call>
body() { cat "$FAKE_DIR/body.$1" 2> /dev/null; }
auth_site() { jq -r '.site_url + " " + .uri_allow_list' "$FAKE_DIR/auth.patched" 2> /dev/null; }

# 1. Refused before anything is read
run "a code that is not one" -- "Acme!" acme acme-foods "$REQ"
check '[[ $status -eq 2 && "$out" == *"is not a client"* ]] && untouched' "refused, nothing read"
run "an address that is not one" -- acme acme "Acme Foods" "$REQ"
check '[[ $status -eq 2 && "$out" == *"is not an address"* ]] && untouched' "refused, nothing read"
run "to where it is" -- acme acme acme "$REQ"
check '[[ $status -eq 2 && "$out" == *"acme is already its address"* ]] && untouched' "refused"
run "no request" -- acme acme acme-foods ""
check '[[ $status -eq 2 && "$out" == *"only for the request the Fleet view made"* ]] && untouched' "refused: a rename is the console's, checked there"
run "no email key" RESEND_API_KEY= -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"RESEND_API_KEY is not set"* ]] && untouched' "refused before the first statement"
run "no access token" SUPABASE_ACCESS_TOKEN= -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"SUPABASE_ACCESS_TOKEN is not set"* ]] && untouched' "refused"

# 2. Refused before anything is changed; settled only when the request is its own
run "a control plane without the routine" @cp:cp-ready=false -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"cannot record a rename yet (20261012020000"* && "$(order)" == "psql cp cp-ready;" ]]' "refused, the request not touched"
run "a request there is not" @cp:cp-request= -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"there is no request ${REQ}"* && -z "$(settled)" ]] && changed_nothing' "refused, nothing settled"
run "a request for an export" "@cp:cp-request=claimed|export|acme||" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"asks for a export, not a rename"* && -z "$(settled)" ]] && changed_nothing' "not this run's: nothing settled"
run "a request already settled" "@cp:cp-request=done|rename|acme|acme|acme-foods" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"is done, not claimed by the sweep"* && -z "$(settled)" ]] && changed_nothing' "not this run's: nothing settled"
run "a request for something else" "@cp:cp-request=claimed|rename|acme|acme|acme-ltd" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"asks to move acme from acme to acme-ltd, not acme from acme to acme-foods"* && "$(settled)" == "failure: nothing changed: request"* ]] && changed_nothing' \
      "refused, and its own request settled as failed"
run "a client being retired" "@cp:cp-row=retiring|${ACME}|acme" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"acme is retiring: only a built, live or suspended client is renamed"* && "$(settled)" == failure:* ]] && changed_nothing' "refused, settled"
run "a client moved since it was asked" "@cp:cp-row=live|${ACME}|acme-old" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"the register has acme at acme-old now, not acme"* && "$(settled)" == failure:* ]] && changed_nothing' "refused, settled"
run "no connection in the vault" -vault -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"has no cloveerp:deployment:${ACME}:db_url"* && "$(settled)" == failure:* ]] && changed_nothing' "refused, settled"
run "a connection that names another project" "%vault=postgresql://postgres.${ACME}:pw@pooler.example:5432/postgres?also=${BETA}" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"names another deployment'"'"'s project (${BETA})"* && "$(settled)" == failure:* ]] && changed_nothing' "refused, settled"
run "a database that is not a client's" "@${ACME}:client-check=demonstration||true" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"says it is the demonstration deployment"* ]] && changed_nothing' "refused"
run "a client not yet released the routine" "@${ACME}:client-check=client|acme|false" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"cannot rename its organisation yet (20261012020000 has not been released to it): release it, then ask again"* && "$(settled)" == failure:* ]] && changed_nothing' \
      "refused before its auth settings are touched"
run "a client served somewhere else" "@${ACME}:client-check=client|acme-ltd|true" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"served at acme-ltd, neither acme nor acme-foods"* ]] && changed_nothing' "refused"
run "a client that cannot be reached" "@${ACME}:client-check=ERROR:  could not connect" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"database could not be reached"* && "$(settled)" == failure:* ]] && changed_nothing' "refused, settled"

# 3. Renamed
run "a live client renamed" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$out" == *"acme: moved from acme to acme-foods; ${OLD} sends people to ${NEW} for ninety days"* ]]' "says so"
check '[[ "$(order)" == "psql cp cp-ready;psql cp cp-request;psql cp cp-row;psql cp cp-refs;psql cp vault-get cloveerp:deployment:${ACME}:db_url;psql ${ACME} client-check;event acme rename started;PATCH /v1/projects/${ACME}/config/auth;GET /v1/projects/${ACME}/config/auth;PATCH /v1/projects/${ACME}/postgrest;GET /v1/projects/${ACME}/postgrest;event acme configure done;POST /v1/projects/${ACME}/secrets;event acme functions done;psql ${ACME} client-move;event acme identity done;psql cp cp-finish;psql cp cp-settle;" ]]' \
      "checked, then the auth settings, the function secret, the database, the register, and the request, each step on the row"
check '[[ "$(jq -r ".site_url + \" \" + .uri_allow_list" <<< "$(body 1)")" == "${NEW} ${NEW}/**" && "$(jq -r .disable_signup <<< "$(body 1)")" == true && "$(jq -r .smtp_pass <<< "$(body 1)")" == re_rehearsal_resend_key ]]' \
      "the site and the one redirect at the new address, sign-up still closed, SMTP still Resend"
check '[[ "$(body 5)" == "[{\"name\":\"CLOVEERP_APP_URL\",\"value\":\"${NEW}\"}]" ]]' "the functions told the new address, and nothing else"
check '[[ "$(tvar client-move origin)" == "$NEW" && "$(tvar client-move to)" == acme-foods && "$(tvar client-move ref)" == "$ACME" ]]' "the database: served at the new address, its organisation the new code"
check '[[ "$(tr "\n" " " < "$FAKE_DIR/sql.$(awk "\$3 == \"client-move\" { print \$1 }" "$FAKE_DIR/psql.log")")" == *"begin; set local statement_timeout"*"set_deployment_identity(:'"'"'ref'"'"', :'"'"'origin'"'"');"*"rename_client_organisation(:'"'"'to'"'"'); commit;"* ]]' \
      "both in one transaction, the identity first"
check '[[ "$(tvar cp-finish code)" == acme && "$(tvar cp-finish to)" == acme-foods ]]' "the register: the code stays, the address moves"
check '[[ "$(tvar cp-settle id)" == "$REQ" && "$(settled)" == "success: acme moved from acme to acme-foods"* ]]' "the request settled as done"
check '[[ "$(details)" == *"acme|configure|done|site ${NEW}, the one redirect ${NEW}/** (fleet_rename.yml)"* ]]' "each event says what it did"
run "a suspended client renamed" "@cp:cp-row=suspended|${ACME}|acme" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(settled)" == success:* ]]' "renamed"
run "a rename that stopped, asked for again" "@${ACME}:client-check=client|acme-foods|true" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$out" == *"already at acme-foods: a rename that stopped is carried on"* && "$(order)" == *"client-move;"*"cp-finish;"* && "$(settled)" == success:* ]]' \
      "carried on: every step again, and settled"

# 4. A step that fails: what was done is undone, and said
run "auth settings refused" FAKE_AUTH_PATCH_STATUSES=403,200 -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"acme was not renamed to acme-foods: the auth settings failed"*"What had been done was put back, and acme is at acme as before."* ]]' "red, saying all is as it was"
check '[[ "$(auth_site)" == "${OLD} ${OLD}/**" && "$(order)" != *"secrets"* && "$(order)" != *"client-move"* && "$(order)" != *"cp-finish"* ]]' "the auth settings applied for the old address again; nothing further touched"
check '[[ "$(events)" == "acme|rename|started acme|configure|failed acme|configure|done acme|rename|failed " && "$(settled)" == "failure: the auth settings failed"* ]]' "the row and the request say so"
run "the function secret refused" FAKE_SECRETS_STATUSES=403,200 -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"the function secret failed"*"put back"* && "$(auth_site)" == "${OLD} ${OLD}/**" ]]' "red; the auth settings back at the old address"
check '[[ "$(body 6)" == "[{\"name\":\"CLOVEERP_APP_URL\",\"value\":\"${OLD}\"}]" && "$(order)" != *"client-move"* && "$(settled)" == failure:* ]]' "the secret put back too, in case it was set; the database not touched"
run "the database refuses" "@${ACME}:client-move=ERROR:  CLOVEERP_ADDRESS_TAKEN: no" "@${ACME}:client-code=acme" -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"the database failed (CLOVEERP_ADDRESS_TAKEN: no)"*"put back"* ]]' "red, saying why"
check '[[ "$(grep -c "^psql ${ACME} client-move" "$FAKE_DIR/order.log")" == 1 && "$(auth_site)" == "${OLD} ${OLD}/**" && "$(order)" != *"cp-finish"* ]]' \
      "its own transaction undid itself; the secret and the auth settings put back; the register not touched"
check '[[ "$(events)" == *"acme|identity|failed"*"acme|functions|done acme|configure|done acme|rename|failed "* && "$(settled)" == failure:* ]]' "each undoing on the row"
run "the database answered nothing, and had committed" "@${ACME}:client-move=ERROR:  server closed the connection unexpectedly" "@${ACME}:client-code=acme-foods" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(order)" == *"client-move;psql ${ACME} client-code;event acme identity done;psql cp cp-finish;"* && "$(settled)" == success:* ]]' "asked, and carried on"
run "the register refuses" "@cp:cp-finish=ERROR:  CLOVEERP_ADDRESS_TAKEN: acme-foods is another deployment's" @cp:cp-address=acme -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"the register failed (CLOVEERP_ADDRESS_TAKEN: acme-foods is another deployment'"'"'s)"*"put back, and acme is at acme as before"* ]]' "red, saying why"
check '[[ "$(tvar client-move origin 2)" == "$OLD" && "$(tvar client-move to 2)" == acme && "$(auth_site)" == "${OLD} ${OLD}/**" ]]' \
      "the database moved back, the secret and the auth settings put back"
check '[[ "$(order)" == *"cp-finish;psql cp cp-address;psql ${ACME} client-move;event acme identity done;POST"*"event acme functions done;PATCH"*"event acme configure done;event acme rename failed;psql cp cp-settle;" ]]' \
      "in reverse: the database, the secret, the auth settings; then the row and the request"
run "the register answered nothing, and had committed" "@cp:cp-finish=ERROR:  server closed the connection unexpectedly" @cp:cp-address=acme-foods -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(grep -c "client-move" "$FAKE_DIR/order.log")" == 1 && "$(settled)" == success:* ]]' "asked, and taken as done"
run "the register refuses, and the database will not go back" "@cp:cp-finish=ERROR:  no" @cp:cp-address=acme "@${ACME}:client-move#2=ERROR:  statement timeout" -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"could not all be put back: the database (still at acme-foods: statement timeout)"*"Ask for the same rename again"* ]]' "red, saying what is left and what to do"
check '[[ "$(events)" == *"acme|identity|failed"*"acme|rename|failed "* && "$(settled)" == *"could not all be put back"* ]]' "the row and the request say the same"
run "a request that cannot be settled" "@cp:cp-settle=ERROR:  CLOVEERP_DEPLOYMENT_STATE: not claimed" -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$(order)" == *"cp-finish;psql cp cp-settle;"* && "$out" == *"could not be settled"*"stays claimed"* ]]' "renamed, and red, saying the request stays open"

# 5. Nothing secret printed
run "on a runner" GITHUB_ACTIONS=true -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(printf "%s\n" "$out" | grep -F -- "$ACME_URL" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -cxF -- "::add-mask::$ACME_URL")" == 1 ]]' \
      "the connection masked, and printed nowhere else"
check '[[ "$out" != *"re_rehearsal_resend_key"* && "$out" != *"rehearsal-access-token"* && "$(details)" != *"re_rehearsal_resend_key"* && "$(cat "$work/summary")" != *"re_rehearsal_resend_key"* ]]' \
      "the email key and the access token printed nowhere, the row and the summary included"
run "on a runner, refused" GITHUB_ACTIONS=true "@${ACME}:client-check=client|acme-ltd|true" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$(printf "%s\n" "$out" | grep -c "^::error::acme was not renamed, and nothing was changed")" == 1 && "$(printf "%s\n" "$out" | grep -v "^::add-mask::" | grep -c "acme-database-password")" == 0 ]]' "one plain error, nothing secret"

echo "$CASES checks over a client's rename, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
