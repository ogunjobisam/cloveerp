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
# places in that order with an event for each; the redirects allowed being
# the new address and every one held for the client, never the new one
# alone; every step undone when a later one is known to have failed, and
# what could not be undone said; a write whose answer was lost read back
# with patience, taken as done when it shows, undone only when it shows it
# did not commit, and never undone while that is not known (exit 3, the
# request left for the workflow's last step); a rename that stopped carried
# on when asked again, and one carried on that fails never put back toward
# the old address nor said to be there (exit 3); and nothing secret printed.
# Seconds.
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
          API="https://api.example" MAPI_SLEEP="$work/bin/sleep" FLEET_SLEEP="$work/bin/sleep"
          SUPABASE_ACCESS_TOKEN=rehearsal-access-token
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
      # Where a run before left the project: its functions' address, and
      # its auth settings' site.
      %secret=*) jq -cn --arg v "${1#%secret=}" '{CLOVEERP_APP_URL: $v}' > "$FAKE_DIR/secrets.held" ;;
      %site=*) jq -cn --arg s "${1#%site=}" '{site_url: $s, uri_allow_list: ($s + "/**")}' > "$FAKE_DIR/auth.patched" ;;
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
# secret_at: the functions' address the project holds now.
secret_at() { jq -r '.CLOVEERP_APP_URL // ""' "$FAKE_DIR/secrets.held" 2> /dev/null; }
sleeps() { grep '^sleep ' "$FAKE_DIR/order.log" 2> /dev/null | cut -d' ' -f2 | tr '\n' ' '; }
# undone_nothing: one move of the database, the secret never put back, and
# the auth settings still at the new address.
undone_nothing() {
  [[ "$(grep -c "^psql ${ACME} client-move" "$FAKE_DIR/order.log")" == 1 && "$(grep -c '^POST' "$FAKE_DIR/order.log")" == 1 \
     && "$(grep -c '^PATCH /v1/projects/.*/config/auth' "$FAKE_DIR/order.log")" == 1 && "$(auth_site)" == "${NEW} ${NEW}/**,${OLD}/**" ]]
}

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
check '[[ $status -eq 2 && "$out" == *"cannot record a rename yet (20261012030000"* && "$(order)" == "psql cp cp-ready;" ]]' "refused, the request not touched"
check '[[ "$(cat "$FAKE_DIR/sql.1")" == *"finish_deployment_rename(text,text)"*"erp_meta.deployment_previous_address"* ]]' "asked for the routine and the addresses held, which arrive together"
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
check '[[ $status -eq 2 && "$out" == *"cannot rename its organisation yet (20261012030000 has not been released to it): release it, then ask again"* && "$(settled)" == failure:* ]] && changed_nothing' \
      "refused before its auth settings are touched"
run "a client served somewhere else" "@${ACME}:client-check=client|acme-ltd|true" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"served at acme-ltd, neither acme nor acme-foods"* ]] && changed_nothing' "refused"
run "a client that cannot be reached" "@${ACME}:client-check=ERROR:  could not connect" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"database could not be reached"* && "$(settled)" == failure:* ]] && changed_nothing' "refused, settled"

# 3. Renamed
run "a live client renamed" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$out" == *"acme: moved from acme to acme-foods; ${OLD} sends people to ${NEW} for ninety days"* ]]' "says so"
check '[[ "$(order)" == "psql cp cp-ready;psql cp cp-request;psql cp cp-row;psql cp cp-refs;psql cp cp-held;psql cp vault-get cloveerp:deployment:${ACME}:db_url;psql ${ACME} client-check;event acme rename started;PATCH /v1/projects/${ACME}/config/auth;GET /v1/projects/${ACME}/config/auth;PATCH /v1/projects/${ACME}/postgrest;GET /v1/projects/${ACME}/postgrest;event acme configure done;POST /v1/projects/${ACME}/secrets;event acme functions done;psql ${ACME} client-move;event acme identity done;psql cp cp-finish;psql cp cp-settle;" ]]' \
      "checked, then the auth settings, the function secret, the database, the register, and the request, each step on the row"
check '[[ "$(jq -r ".site_url + \" \" + .uri_allow_list" <<< "$(body 1)")" == "${NEW} ${NEW}/**,${OLD}/**" && "$(jq -r .disable_signup <<< "$(body 1)")" == true && "$(jq -r .smtp_pass <<< "$(body 1)")" == re_rehearsal_resend_key ]]' \
      "the site at the new address; the redirects the new address and the old one it now holds, not the new alone; sign-up still closed, SMTP still Resend"
check '[[ "$(body 5)" == "[{\"name\":\"CLOVEERP_APP_URL\",\"value\":\"${NEW}\"}]" ]]' "the functions told the new address, and nothing else"
check '[[ "$(tvar client-move origin)" == "$NEW" && "$(tvar client-move to)" == acme-foods && "$(tvar client-move ref)" == "$ACME" ]]' "the database: served at the new address, its organisation the new code"
check '[[ "$(tr "\n" " " < "$FAKE_DIR/sql.$(awk "\$3 == \"client-move\" { print \$1 }" "$FAKE_DIR/psql.log")")" == *"begin; set local statement_timeout"*"set_deployment_identity(:'"'"'ref'"'"', :'"'"'origin'"'"');"*"rename_client_organisation(:'"'"'to'"'"'); commit;"* ]]' \
      "both in one transaction, the identity first"
check '[[ "$(tvar cp-finish code)" == acme && "$(tvar cp-finish to)" == acme-foods ]]' "the register: the code stays, the address moves"
check '[[ "$(tvar cp-settle id)" == "$REQ" && "$(settled)" == "success: acme moved from acme to acme-foods"* ]]' "the request settled as done"
check '[[ "$(details)" == *"acme|configure|done|site ${NEW}, redirects to ${NEW}/** and to the addresses held for it (acme) (fleet_rename.yml)"* ]]' "each event says what it did"
check '[[ "$(sed -n "/-- fleet: cp-finish/,\$p" "$FAKE_DIR/sql.$(awk "\$3 == \"cp-finish\" { print \$1 }" "$FAKE_DIR/psql.log")")" == *"set statement_timeout = '"'"'10s'"'"';"* ]]' \
      "the register's write has a limit, so a read-back after it knows the write is over"
run "a client moved before, renamed again" "@cp:cp-held=acme-old acme-older" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(jq -r .uri_allow_list <<< "$(body 1)")" == "${NEW}/**,${OLD}/**,https://acme-old.cloveerp.com/**,https://acme-older.cloveerp.com/**" ]]' \
      "every address it holds stays allowed: the one it leaves and each it left before"
run "a rename walked back to its own code" "@cp:cp-request=claimed|rename|acme|acme-foods|acme" "@cp:cp-row=live|${ACME}|acme-foods" \
    "@cp:cp-held=acme" "@${ACME}:client-check=client|acme-foods|true" -- acme acme-foods acme "$REQ"
check '[[ $status -eq 0 && "$(jq -r ".site_url + \" \" + .uri_allow_list" <<< "$(body 1)")" == "${OLD} ${OLD}/**,${NEW}/**" && "$(tvar client-move origin)" == "$OLD" && "$(settled)" == success:* ]]' \
      "back at its code, which it held; the address it leaves allowed once"
run "a client holding addresses whose auth settings are refused" "@cp:cp-held=acme-old" FAKE_AUTH_PATCH_STATUSES=403,200 -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$(auth_site)" == "${OLD} ${OLD}/**,https://acme-old.cloveerp.com/**" ]]' "put back at the old address, with what it held before"
run "an address held that is not one" "@cp:cp-held=acme Old" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"holds '"'"'Old'"'"' for acme, which is not an address"* ]] && changed_nothing' "refused before anything is touched"
run "a suspended client renamed" "@cp:cp-row=suspended|${ACME}|acme" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(settled)" == success:* ]]' "renamed"
run "a rename that stopped, asked for again" "@${ACME}:client-check=client|acme-foods|true" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$out" == *"already at acme-foods: a rename that stopped is carried on"* && "$(order)" == *"client-move;"*"cp-finish;"* && "$(settled)" == success:* ]]' \
      "carried on: every step again, and settled"

# 4. A step that fails: what was done is undone, and said
run "auth settings refused" FAKE_AUTH_PATCH_STATUSES=403,200 -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"acme was not renamed to acme-foods: the auth settings failed"*"put back, and read back at acme"*"acme is at acme as before."* ]]' "red, saying all is as it was"
check '[[ "$(auth_site)" == "${OLD} ${OLD}/**" && "$(secret_at)" == "$OLD" && "$(order)" != *"client-move"* && "$(order)" != *"cp-finish"* ]]' \
      "the auth settings applied for the old address again, and its functions' address put back there too, whichever run set it; the database and the register not touched"
check '[[ "$(order)" == *"event acme configure failed;POST /v1/projects/${ACME}/secrets;event acme functions done;PATCH /v1/projects/${ACME}/config/auth;"*"event acme configure done;GET /v1/projects/${ACME}/config/auth;GET /v1/projects/${ACME}/secrets;event acme rename failed;psql cp cp-settle;" ]]' \
      "each put back, then each read back, before anything is said"
check '[[ "$(events)" == "acme|rename|started acme|configure|failed acme|functions|done acme|configure|done acme|rename|failed " && "$(settled)" == "failure: acme is at acme as before, each piece put back and read back there: the auth settings failed"* ]]' "the row and the request say so"
run "the function secret refused" FAKE_SECRETS_STATUSES=403,200 -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"the function secret failed"*"put back"* && "$(auth_site)" == "${OLD} ${OLD}/**" ]]' "red; the auth settings back at the old address"
check '[[ "$(body 6)" == "[{\"name\":\"CLOVEERP_APP_URL\",\"value\":\"${OLD}\"}]" && "$(order)" != *"client-move"* && "$(settled)" == failure:* ]]' "the secret put back too, in case it was set; the database not touched"
run "the database refuses" "@${ACME}:client-move=ERROR:  CLOVEERP_ADDRESS_TAKEN: no" "@${ACME}:client-code=acme" -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"the database failed (CLOVEERP_ADDRESS_TAKEN: no)"*"put back"* ]]' "red, saying why"
check '[[ "$(grep -c "^psql ${ACME} client-move" "$FAKE_DIR/order.log")" == 1 && "$(auth_site)" == "${OLD} ${OLD}/**" && "$(order)" != *"cp-finish"* ]]' \
      "its own transaction undid itself; the secret and the auth settings put back; the register not touched"
check '[[ "$(events)" == *"acme|identity|failed"*"acme|functions|done acme|configure|done acme|rename|failed "* && "$(settled)" == failure:* ]]' "each undoing on the row"
run "the database answered nothing, and had committed" "@${ACME}:client-move=ERROR:  server closed the connection unexpectedly" "@${ACME}:client-code=acme-foods" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(order)" == *"client-move;sleep 15;psql ${ACME} client-code;event acme identity done;psql cp cp-finish;"* && "$(settled)" == success:* ]]' "asked after a pause, and carried on"
check '[[ "$(tvar client-code app)" == "fleet_rename ${REQ}" && "$(sed -n "/-- fleet: client-code/,\$p" "$FAKE_DIR/sql.$(awk "\$3 == \"client-code\" { print \$1 }" "$FAKE_DIR/psql.log")")" == *"set statement_timeout = :'"'"'timeout'"'"';"*"pg_stat_activity"* ]]' \
      "the read-back has its limit, and asks after this run's own sessions by name"
run "the register refuses" "@cp:cp-finish=ERROR:  CLOVEERP_ADDRESS_TAKEN: acme-foods is another deployment's" @cp:cp-address=acme -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"the register failed (CLOVEERP_ADDRESS_TAKEN: acme-foods is another deployment'"'"'s)"*"put back, and read back at acme"*"acme is at acme as before."* ]]' "red, saying why"
check '[[ "$(tvar client-move origin 2)" == "$OLD" && "$(tvar client-move to 2)" == acme && "$(auth_site)" == "${OLD} ${OLD}/**" ]]' \
      "the database moved back, the secret and the auth settings put back"
check '[[ "$(order)" == *"cp-finish;sleep 15;psql cp cp-address;psql ${ACME} client-move;event acme identity done;POST"*"event acme functions done;PATCH"*"event acme configure done;GET /v1/projects/${ACME}/config/auth;GET /v1/projects/${ACME}/secrets;event acme rename failed;psql cp cp-settle;" ]]' \
      "in reverse: the database, the secret, the auth settings; each read back; then the row and the request"
run "the register answered nothing, and had committed" "@cp:cp-finish=ERROR:  server closed the connection unexpectedly" @cp:cp-address=acme-foods -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(grep -c "client-move" "$FAKE_DIR/order.log")" == 1 && "$(settled)" == success:* ]]' "asked, and taken as done"
run "the register refuses, and the database will not go back" "@cp:cp-finish=ERROR:  no" @cp:cp-address=acme "@${ACME}:client-move#2=ERROR:  statement timeout" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"is not all back at acme"*"its database is still at acme-foods (it could not be put back: statement timeout); its auth settings are at acme; its functions'"'"' address (CLOVEERP_APP_URL) is at acme."*"Ask for the same rename (acme to acme-foods) again"* && "$out" != *"as before"* ]]' \
      "exit 3, saying which piece is where and what to do"
check '[[ "$(events)" == *"acme|identity|failed"*"acme|rename|failed "* && "$(details)" == *"not all back at acme"*"its database is still at acme-foods"* && "$(order)" != *"cp-settle"* ]]' \
      "the row says the same; the request left for the workflow's last step"
run "a request that cannot be settled" "@cp:cp-settle=ERROR:  CLOVEERP_DEPLOYMENT_STATE: not claimed" -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$(order)" == *"cp-finish;psql cp cp-settle;"* && "$out" == *"could not be settled"*"stays claimed"* ]]' "renamed, and red, saying the request stays open"

# 4b. A rename carried on (its database already at the new address, moved by
# the run that stopped) undoes only what this run did, which is nothing that
# would put it back: a step that fails leaves it partly at the new address,
# says so, and leaves the request for the workflow's last step (exit 3)
AGAIN_CHECK="@${ACME}:client-check=client|acme-foods|true"
run "a rename carried on, its auth settings refused" FAKE_AUTH_PATCH_STATUSES=403,200 "$AGAIN_CHECK" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"the auth settings failed"*"database was already at acme-foods when this run began"*"nothing was put back toward acme"*"Ask for the same rename (acme to acme-foods) again"* ]]' \
      "exit 3, saying it is partly at the new address and that asking again finishes it"
check '[[ "$out" != *"put back, and"* && "$out" != *"is at acme as before"* && "$(cat "$work/summary")" == *"NOT finished moving to acme-foods, and partly there"* ]]' \
      "nothing claims the client is back where it was, the summary included"
check '[[ "$(grep -c "^PATCH /v1/projects/.*/config/auth" "$FAKE_DIR/order.log")" == 1 && "$(order)" != *"POST"* && "$(order)" != *"client-move"* && "$(order)" != *"cp-finish"* && -z "$(auth_site)" ]]' \
      "the auth settings not applied for the old address again; the secret, the database and the register not touched"
check '[[ "$(order)" != *"cp-settle"* && -z "$(settled)" && "$(events)" == "acme|rename|started acme|configure|failed acme|rename|failed " ]]' \
      "the request left for the last step of the workflow, which settles it from the register; the row says why"
check '[[ "$(details)" == *"acme|rename|failed|not finished moving to acme-foods: the auth settings failed"*"partly at acme-foods; its database is at acme-foods"* ]]' \
      "and the row says where each thing is"
run "a rename carried on, its function secret refused" FAKE_SECRETS_STATUSES=403,200 "$AGAIN_CHECK" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"the function secret failed"*"nothing was put back toward acme"* && "$out" != *"is at acme as before"* ]]' "exit 3, said"
check '[[ "$(grep -c "^POST" "$FAKE_DIR/order.log")" == 1 && "$(grep -c "^PATCH /v1/projects/.*/config/auth" "$FAKE_DIR/order.log")" == 1 && "$(auth_site)" == "${NEW} ${NEW}/**,${OLD}/**" && "$(order)" != *"client-move"* && "$(order)" != *"cp-settle"* ]]' \
      "the auth settings stay at the new address, the secret is not put back, nothing settled"
run "a rename carried on, and the register refuses" "@cp:cp-finish=ERROR:  CLOVEERP_DEPLOYMENT_STATE: no" @cp:cp-address=acme "$AGAIN_CHECK" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"the register failed (CLOVEERP_DEPLOYMENT_STATE: no)"*"its auth settings, its functions'"'"' address and its database are at acme-foods, and the register still has it at acme"* ]]' \
      "exit 3, saying where each thing is"
check 'undone_nothing && [[ "$(order)" != *"cp-settle"* && "$out" != *"is at acme as before"* ]]' "the database not moved back, nothing put back, nothing settled"
run "a rename carried on, and its database will not say it moved" "@${ACME}:client-move=ERROR:  CLOVEERP_DEPLOYMENT_STATE: no" "@${ACME}:client-code=acme-ltd|0" "$AGAIN_CHECK" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"the database failed"*"its database answered at acme-ltd when asked again"* && "$(order)" != *"cp-finish"* && "$(grep -c "^POST" "$FAKE_DIR/order.log")" == 1 ]]' \
      "exit 3, the register not touched, nothing put back"
run "a rename that began at the old address still puts back what it did" FAKE_SECRETS_STATUSES=403,200 -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$out" == *"put back, and read back at acme"*"acme is at acme as before."* && "$(auth_site)" == "${OLD} ${OLD}/**" && "$(settled)" == failure:* ]]' \
      "undone, settled, and \"as before\": its database was never at the new address"

# 4c. Asked again after a run that stopped before its database moved: that
# run set the auth settings and the functions' address to the new address
# (a lost answer at its third step, never committed; or a cancel between its
# second and third), and its database is still at the old one. This run
# stops at its first step. Every piece is put back, whichever run set it, and
# read back; "as before" only when each reads back at the old address
LEFT_AT_NEW=("%secret=${NEW}" "%site=${NEW}")
run "asked again after a run that stopped before its database moved, its auth settings refused" "${LEFT_AT_NEW[@]}" FAKE_AUTH_PATCH_STATUSES=403,200 -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$(secret_at)" == "$OLD" && "$(auth_site)" == "${OLD} ${OLD}/**" && "$(grep -c "^POST" "$FAKE_DIR/order.log")" == 1 && "$(body 2)" == "[{\"name\":\"CLOVEERP_APP_URL\",\"value\":\"${OLD}\"}]" ]]' \
      "the functions' address the run before left at the new address put back too, though this run never set it"
check '[[ "$(order)" == *"GET /v1/projects/${ACME}/config/auth;GET /v1/projects/${ACME}/secrets;event acme rename failed;psql cp cp-settle;" && "$out" == *"put back, and read back at acme"*"acme is at acme as before."* && "$(settled)" == "failure: acme is at acme as before, each piece put back and read back there: the auth settings failed ("* ]]' \
      "each read back at the old address, and only then said to be there as before, and settled"
run "asked again after a run that stopped before its database moved, its functions' address not put back" "${LEFT_AT_NEW[@]}" FAKE_AUTH_PATCH_STATUSES=403,200 FAKE_SECRETS_STATUSES=403 -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"is not all back at acme"*"its database is at acme; its auth settings are at acme; its functions'"'"' address (CLOVEERP_APP_URL) is at acme-foods (it could not be put back: POST /v1/projects/${ACME}/secrets answered 403"* && "$out" != *"as before"* ]]' \
      "exit 3, saying which piece is where: never \"as before\" while its emails would link to the new address"
check '[[ "$(order)" != *"cp-settle"* && "$(details)" == *"acme|rename|failed|not moved to acme-foods, and not all back at acme"*"is at acme-foods"* && "$(cat "$work/summary")" == *"NOT all back at acme"* ]]' \
      "the request left for the workflow's last step; the row and the summary say where each piece is"
run "asked again after a run that stopped before its database moved, its auth settings not put back" "${LEFT_AT_NEW[@]}" FAKE_AUTH_PATCH_STATUSES=403 -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"its auth settings are at acme-foods (it could not be put back: "*"its functions'"'"' address (CLOVEERP_APP_URL) is at acme."* && "$(secret_at)" == "$OLD" && "$(order)" != *"cp-settle"* ]]' \
      "exit 3: the auth settings read back where the run before left them"
run "a step refused, and the functions' address cannot be read back" FAKE_AUTH_PATCH_STATUSES=403,200 FAKE_SECRETS_LIST_STATUSES=403 -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"its functions'"'"' address (CLOVEERP_APP_URL) is not known: it could not be read back"* && "$out" != *"as before"* && "$(order)" != *"cp-settle"* ]]' \
      "exit 3: what cannot be read back is not said to be back"
run "a step refused, and the functions' address listed as a value, not a digest" FAKE_AUTH_PATCH_STATUSES=403,200 \
    "FAKE_SECRETS_LIST=[{\"name\":\"CLOVEERP_APP_URL\",\"value\":\"${OLD}\"}]" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"not known: it could not be read back (${ACME} lists CLOVEERP_APP_URL with something that is not a SHA-256 digest"* ]]' \
      "not taken as a digest, and not printed"

# 5. A write whose answer was lost: read back with patience; undone only when
# it shows it did not commit; never undone while that is not known
LOST="ERROR:  server closed the connection unexpectedly"
GONE="ERROR:  could not connect to server: Connection refused"
run "the register's answer lost, and the control plane gone" "@cp:cp-finish=$LOST" "@cp:cp-address=$GONE" "@cp:cp-settle=$GONE" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"whether the register took the move to acme-foods could not be learned"*"Nothing was undone"*"asking for the same rename again (acme to acme-foods) finishes it"* ]]' \
      "exit 3, saying it is not known and what to do"
check 'undone_nothing && [[ "$(order)" != *"cp-settle"* && "$(sleeps)" == "15 30 60 " && "$(grep -c "^psql cp cp-address" "$FAKE_DIR/order.log")" == 3 ]]' \
      "asked three times after 15, 30 and 60 seconds; nothing undone, and the request left for the workflow's last step"
check '[[ "$(cat "$work/summary")" == *"NOT KNOWN whether renamed to acme-foods"* && "$out" != *"put back"* && "$out" != *"is at acme as before"* ]]' \
      "the summary says the same, and nothing claims the client is back where it was"
run "the register's answer lost, then found at the new address" "@cp:cp-finish=$LOST" "@cp:cp-address#1=$GONE" "@cp:cp-address#2=$GONE" "@cp:cp-address#3=acme-foods|0" -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(sleeps)" == "15 30 60 " && "$(settled)" == success:* && "$out" == *"the register answered with acme at acme-foods when asked again"* ]] && undone_nothing' \
      "taken as done at the third try, and settled"
run "the register's answer lost, its statement still at work, then not committed" "@cp:cp-finish=$LOST" "@cp:cp-address#1=acme|1" "@cp:cp-address#2=acme|0" -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$(sleeps)" == "15 30 " && "$out" == *"still at work there"* && "$out" == *"the register failed"*"put back, and read back at acme"*"acme is at acme as before."* ]]' \
      "an answer while its own statement still runs is no answer; once it has ended, the old address proves it, and all is undone"
check '[[ "$(tvar client-move origin 2)" == "$OLD" && "$(auth_site)" == "${OLD} ${OLD}/**" && "$(settled)" == failure:* ]]' "put back, and settled as failed"
run "the register's statement at work every time it is asked" "@cp:cp-finish=$LOST" "@cp:cp-address=acme|1" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$(sleeps)" == "15 30 60 " ]] && undone_nothing' "not known: nothing undone"
run "the database's answer lost, and it does not answer" "@${ACME}:client-move=$LOST" "@${ACME}:client-code=$GONE" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$out" == *"whether its database took the move to acme-foods could not be learned"*"the register still has it at acme"* ]]' \
      "exit 3, saying where each thing may be"
check '[[ "$(grep -c "^psql ${ACME} client-move" "$FAKE_DIR/order.log")" == 1 && "$(grep -c "^POST" "$FAKE_DIR/order.log")" == 1 && "$(auth_site)" == "${NEW} ${NEW}/**,${OLD}/**" && "$(order)" != *"cp-finish"* && "$(order)" != *"cp-settle"* ]]' \
      "nothing undone, the register not touched, the request left"
check '[[ "$(events)" == *"acme|rename|failed"* && "$(events)" != *"acme|identity|failed"* ]]' "the row says it is not known, not that the database failed"
run "the database's answer lost, and it shows it did not commit" "@${ACME}:client-move=$LOST" "@${ACME}:client-code#1=$GONE" "@${ACME}:client-code#2=acme|0" -- "${ARGS[@]}"
check '[[ $status -eq 1 && "$(sleeps)" == "15 30 " && "$out" == *"the database failed"*"put back, and read back at acme"*"acme is at acme as before."* && "$(auth_site)" == "${OLD} ${OLD}/**" && "$(order)" != *"cp-finish"* ]]' \
      "undone once it is known, and the register never touched"
run "the pauses can be set" READ_BACK_PAUSES="1 2" "@cp:cp-finish=$LOST" "@cp:cp-address=$GONE" -- "${ARGS[@]}"
check '[[ $status -eq 3 && "$(sleeps)" == "1 2 " && "$out" == *"2 time(s) over the next 3 seconds"* ]]' "and are said"
run "pauses that are not seconds" "READ_BACK_PAUSES=soon" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$out" == *"READ_BACK_PAUSES"* ]] && untouched' "refused before anything is read"

# 6. Nothing secret printed
run "on a runner" GITHUB_ACTIONS=true -- "${ARGS[@]}"
check '[[ $status -eq 0 && "$(printf "%s\n" "$out" | grep -F -- "$ACME_URL" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -cxF -- "::add-mask::$ACME_URL")" == 1 ]]' \
      "the connection masked, and printed nowhere else"
check '[[ "$out" != *"re_rehearsal_resend_key"* && "$out" != *"rehearsal-access-token"* && "$(details)" != *"re_rehearsal_resend_key"* && "$(cat "$work/summary")" != *"re_rehearsal_resend_key"* ]]' \
      "the email key and the access token printed nowhere, the row and the summary included"
run "on a runner, refused" GITHUB_ACTIONS=true "@${ACME}:client-check=client|acme-ltd|true" -- "${ARGS[@]}"
check '[[ $status -eq 2 && "$(printf "%s\n" "$out" | grep -c "^::error::acme was not renamed, and nothing was changed")" == 1 && "$(printf "%s\n" "$out" | grep -v "^::add-mask::" | grep -c "acme-database-password")" == 0 ]]' "one plain error, nothing secret"

echo "$CASES checks over a client's rename, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
