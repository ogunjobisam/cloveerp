#!/usr/bin/env bash
#
# supabase/ci/fleet_secrets.sh, rehearsed with no database and no Management
# API.
#
# The script changes a client's database password, its functions' secrets or
# its auth settings, for one client or the whole fleet, and it runs for real
# only against paying clients' projects: a mistake in it is a client its
# releases cannot reach, or twenty. So every build runs it here first,
# against a psql that keeps the register and the vault in files and a curl
# that answers from a script, both writing down what they were asked, in one
# log, in order: what it refuses before touching anything; that a new
# password is in the vault before the project is given it, that the
# connection releases read is replaced only once the project has the
# password, and that it is read back and must answer; that each failure
# says what was and was not changed and leaves the rest of the fleet alone;
# the pause between clients; and that no password, key or connection string
# is ever printed, except to mask it. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_secrets.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
CP="postgresql://postgres.cpcpcpcpcpcpcpcpcpcp:control-plane-password@pooler.example:5432/postgres"
ACME=aaaaaaaaaaaaaaaaaaaa
BETA=bbbbbbbbbbbbbbbbbbbb

# ── A psql that keeps the register and the vault in files ───────────────────
cat > "$work/psql" <<'FAKE'
#!/usr/bin/env bash
# The first argument is the connection; -v name=value are kept as v_name;
# the statement is -c's or standard input's.
conn="$1"; shift
sql=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v) k="${2%%=*}"; val="${2#*=}"; printf -v "v_${k}" '%s' "$val"; shift 2 ;;
    -c|-tAc) sql="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$sql" ]] || sql="$(cat)"
mkdir -p "$FAKE_DIR/vault"
say() { echo "$*" >> "$FAKE_DIR/order.log"; }
if [[ -n "${FAKE_PSQL_FAIL:-}" && "$sql$(printf ' %s' "${v_name:-}")" == *"${FAKE_PSQL_FAIL}"* ]]; then
  say "psql refused: ${FAKE_PSQL_FAIL}"
  echo "psql: error: the rehearsal refuses this" >&2
  exit 1
fi
if [[ "$conn" != "$FAKE_CP" ]]; then
  # A client's connection: the proof. It answers once the attempts the
  # rehearsal says fail are spent.
  n=$(( $(cat "$FAKE_DIR/connects" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAKE_DIR/connects"
  say "connect $conn"
  if [[ "$n" -le "${FAKE_CONNECT_FAILS:-0}" ]]; then
    echo "psql: error: connection to $conn failed: FATAL: password authentication failed" >&2
    exit 2
  fi
  echo 1
  exit 0
fi
case "$sql" in
  *"from erp_meta.deployment d"*)
    say "register read for ${v_code}"
    [[ "${FAKE_REGISTER_DOWN:-}" == yes ]] && { echo "psql: error: could not connect" >&2; exit 2; }
    # code|status|ref[|address]: where it is served, its code unless given
    # (the register answers coalesce(address, code), 20261012020000).
    printf '%s\n' "${FAKE_ROWS:-}" | while IFS='|' read -r c s r a; do
      [[ -n "$c" ]] || continue
      if [[ "$v_code" == all ]]; then
        if [[ ( "$s" == built || "$s" == live ) && -n "$r" ]]; then echo "${c}|${s}|${r}|${a:-$c}"; fi
      elif [[ "$c" == "$v_code" ]]; then
        echo "${c}|${s}|${r}|${a:-$c}"
      fi
    done ;;
  *"vault.create_secret"*)
    printf '%s' "$v_value" > "$FAKE_DIR/vault/$v_name"
    say "vault-put $v_name" ;;
  *"vault.decrypted_secrets"*)
    say "vault-get $v_name"
    cat "$FAKE_DIR/vault/$v_name" 2>/dev/null ;;
  *"delete from vault.secrets"*)
    rm -f "$FAKE_DIR/vault/$v_name"
    say "vault-del $v_name" ;;
  *"record_deployment_event"*)
    say "event ${v_code} ${v_phase} ${v_status}"
    printf '%s\n' "${v_code}|${v_phase}|${v_status}|${v_detail}" >> "$FAKE_DIR/events" ;;
  *)
    echo "the rehearsal's psql does not know: $sql" >&2
    exit 3 ;;
esac
FAKE
chmod +x "$work/psql"

# ── A Management API that answers from the environment ───────────────────────
cat > "$work/curl" <<'FAKE'
#!/usr/bin/env bash
method=GET; url=""; body=""; want_status=no; dump=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|-d) body="$2"; shift 2 ;;
    -w) want_status=yes; shift 2 ;;
    -D|--dump-header) dump="$2"; shift 2 ;;
    -H|-o|--max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/calls"
path="${url#*//*/}"
echo "$method /$path" >> "$FAKE_DIR/order.log"
[[ -z "$body" ]] || printf '%s' "$body" > "$FAKE_DIR/body.$n"
status=200
# A status per call, from a comma list, the last one repeated.
if [[ -n "${FAKE_HTTP_STATUSES:-}" ]]; then
  IFS=',' read -r -a hseq <<< "$FAKE_HTTP_STATUSES"
  i=$(( n - 1 ))
  (( i < ${#hseq[@]} )) || i=$(( ${#hseq[@]} - 1 ))
  status="${hseq[$i]}"
fi
ref="${path#v1/projects/}"; ref="${ref%%/*}"
case "$method $path" in
  "GET v1/projects/"*"/config/database/pooler")
    [[ -z "${FAKE_POOLER_STATUS:-}" ]] || status="$FAKE_POOLER_STATUS"
    answer="[{\"database_type\":\"PRIMARY\",\"pool_mode\":\"session\",\"db_host\":\"aws-0-eu-central-1.pooler.supabase.com\",\"db_port\":5432,\"db_user\":\"postgres.${ref}\",\"db_name\":\"postgres\"}]" ;;
  "PATCH v1/projects/"*"/database/password")
    [[ -z "${FAKE_PASSWORD_STATUS:-}" ]] || status="$FAKE_PASSWORD_STATUS"
    answer='{}' ;;
  "POST v1/projects/"*"/secrets") answer='{}' ;;
  "PATCH v1/projects/"*"/config/auth") printf '%s' "$body" > "$FAKE_DIR/auth.patched"; answer='{}' ;;
  "GET v1/projects/"*"/config/auth")
    if [[ -n "${FAKE_AUTH:-}" ]]; then answer="$FAKE_AUTH"; else answer="$(cat "$FAKE_DIR/auth.patched" 2>/dev/null || echo '{}')"; fi ;;
  "PATCH v1/projects/"*"/postgrest") answer='{}' ;;
  "GET v1/projects/"*"/postgrest") answer='{"db_schema":"public, graphql_public"}' ;;
  *) answer='{}' ;;
esac
if [[ -n "$dump" ]]; then printf 'HTTP/2 %s\r\n\r\n' "$status" > "$dump"; fi
printf '%s' "$answer"
[[ "$want_status" == yes ]] && printf '\n%s' "$status"
exit 0
FAKE
chmod +x "$work/curl"

cat > "$work/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_DIR/sleeps"
echo "sleep $1" >> "$FAKE_DIR/order.log"
FAKE
chmod +x "$work/sleep"

ROWS="acme|live|${ACME}
beta|built|${BETA}
gamma|suspended|cccccccccccccccccccc
delta|requested|"
REASON="the rehearsal, every build"
BASE_ENV=(FAKE_CP="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" SUPABASE_ACCESS_TOKEN=rehearsal-token
          PSQL="$work/psql" CURL="$work/curl" API="https://api.example" MAPI_SLEEP="$work/sleep"
          SLEEP="$work/sleep" APEX=cloveerp.com MAIL_FROM=noreply@cloveerp.com
          RESEND_API_KEY=re_rehearsal_key PAUSE_SECONDS=20 PROVE_WAIT=10 "FAKE_ROWS=$ROWS")

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...] -- <arguments>: a fresh register and vault,
  # the script, its exit and everything it printed.
  CURRENT="$1"; shift
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  rm -rf "$work/fake"; mkdir -p "$work/fake/vault"
  if [[ -n "${SEED_URL:-}" ]]; then printf '%s' "$SEED_URL" > "$work/fake/vault/cloveerp:deployment:${ACME}:db_url"; fi
  : > "$work/summary"
  out=$(env -u GITHUB_ACTIONS FAKE_DIR="$work/fake" GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 \
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
    sed 's/^/       > /' "$work/fake/order.log" 2>/dev/null | head -n 20
  fi
}
order() { tr '\n' ';' 2>/dev/null < "$work/fake/order.log"; }
calls() { cat "$work/fake/calls" 2>/dev/null || echo 0; }
body() { cat "$work/fake/body.$1" 2>/dev/null; }
vault() { cat "$work/fake/vault/$1" 2>/dev/null; }
events() { cat "$work/fake/events" 2>/dev/null; }
sleeps() { tr '\n' ' ' 2>/dev/null < "$work/fake/sleeps"; }
untouched() { [[ ! -e "$work/fake/calls" ]] && ! grep -q '^vault-\|^event' "$work/fake/order.log" 2>/dev/null; }

# 1. Refused before anything is touched
run "an action it does not have" -- rotate_everything acme "$REASON"
check '[[ $status -eq 2 && "$out" == *"is not one of them, and nothing was changed"* ]] && untouched' "refused"
run "a code that is not one" -- rotate_db_password "Acme!" "$REASON"
check '[[ $status -eq 2 && "$out" == *"neither a client"* ]] && untouched' "refused"
run "no reason" -- rotate_db_password acme "because"
check '[[ $status -eq 2 && "$out" == *"say why"* ]] && untouched' "refused"
run "no control plane" CLOVEERP_LIVE_DATABASE_URL= -- rotate_db_password acme "$REASON"
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* ]] && untouched' "refused"
run "no access token" SUPABASE_ACCESS_TOKEN= -- rotate_db_password acme "$REASON"
check '[[ $status -eq 2 && "$out" == *"SUPABASE_ACCESS_TOKEN is not set"* ]] && untouched' "refused"
run "function secrets without the email key" RESEND_API_KEY= -- set_function_secrets all "$REASON"
check '[[ $status -eq 2 && "$out" == *"RESEND_API_KEY is not set"* ]] && untouched' "refused before the first client"
run "auth without a sender" MAIL_FROM=nobody -- patch_auth all "$REASON"
check '[[ $status -eq 2 && "$out" == *"MAIL_FROM is not an email address"* ]] && untouched' "refused before the first client"
run "a client the register does not have" -- rotate_db_password zeta "$REASON"
check '[[ $status -eq 2 && "$out" == *"zeta is not in the register"* ]] && untouched' "refused"
run "a suspended client" -- set_function_secrets gamma "$REASON"
check '[[ $status -eq 2 && "$out" == *"gamma is suspended, not built or live"* ]] && untouched' "refused"
run "a client still being built" -- patch_auth delta "$REASON"
check '[[ $status -eq 2 && "$out" == *"delta is requested, not built or live"* ]] && untouched' "refused"
run "a register that cannot be read" FAKE_REGISTER_DOWN=yes -- rotate_db_password all "$REASON"
check '[[ $status -eq 2 && "$out" == *"register could not be read"* ]] && untouched' "refused"
run "nobody built" "FAKE_ROWS=gamma|suspended|cccccccccccccccccccc" -- rotate_db_password all "$REASON"
check '[[ $status -eq 0 && "$out" == *"nothing to do"* ]] && untouched' "nothing to do, and green"

# 2. A password rotated
SEED_URL="postgresql://postgres.${ACME}:the-old-password@aws-0-eu-central-1.pooler.supabase.com:5432/postgres"
run "a password rotated" -- rotate_db_password acme "$REASON"
PASS=$(body 2 | jq -r .password)
NEW="postgresql://postgres.${ACME}:${PASS}@aws-0-eu-central-1.pooler.supabase.com:5432/postgres"
check '[[ $status -eq 0 && "$out" == *"acme: database password rotated"* ]]' "says so"
check '[[ "$PASS" =~ ^[A-Za-z0-9]{40}$ ]]' "forty letters and digits"
check '[[ "$(order)" == "register read for acme;GET /v1/projects/${ACME}/config/database/pooler;vault-put cloveerp:provision:acme:db_pass;PATCH /v1/projects/${ACME}/database/password;vault-put cloveerp:deployment:${ACME}:db_url;vault-del cloveerp:provision:acme:db_pass;vault-get cloveerp:deployment:${ACME}:db_url;connect ${NEW};event acme note done;" ]]' \
      "the pooler read, the password kept, then given to the project, then its connection stored, read back and connected to"
check '[[ "$(vault "cloveerp:deployment:${ACME}:db_url")" == "$NEW" && -z "$(vault cloveerp:provision:acme:db_pass)" ]]' \
      "the vault holds the new session-pooler connection, and the password's own entry is gone"
check '[[ "$(events)" == "acme|note|done|database password rotated; the connection in the vault was replaced and answered (fleet_secrets.yml: $REASON)" ]]' "the client's row says what was done and why"
check '[[ "$out" != *"$PASS"* && "$(cat "$work/summary")" != *"$PASS"* && "$(cat "$work/summary")" == *"- acme: database password rotated"* ]]' \
      "the password is printed nowhere, the summary included"
run "a password rotated, on a runner" GITHUB_ACTIONS=true -- rotate_db_password acme "$REASON"
PASS=$(body 2 | jq -r .password)
check '[[ $status -eq 0 && "$(printf "%s\n" "$out" | grep -F -- "$PASS" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -c "^::add-mask::")" -ge 2 ]]' \
      "the password and the connection are masked, and appear nowhere else"
check '[[ "$(printf "%s\n" "$out" | grep -nF -- "$PASS" | head -n 1 | cut -d: -f1)" == "$(printf "%s\n" "$out" | grep -n "^::add-mask::" | head -n 1 | cut -d: -f1)" ]]' \
      "masked before anything else that could carry it is printed"
run "a busy minute while the password is set" "FAKE_HTTP_STATUSES=200,429,200" -- rotate_db_password acme "$REASON"
check '[[ $status -eq 0 && "$(sleeps)" == "5 " && "$(grep -c "^PATCH" "$work/fake/order.log")" == 2 ]]' "asked again, as mapi asks, and rotated"
run "a pooler slow to learn the password" FAKE_CONNECT_FAILS=2 PROVE_ATTEMPTS=4 -- rotate_db_password acme "$REASON"
check '[[ $status -eq 0 && "$(cat "$work/fake/connects")" == 3 && "$(sleeps)" == "10 10 " && "$out" == *"attempt 1 of 4"* ]]' "asked again until it answers"

# 3. A rotation that stops says what it changed
run "a pooler that cannot be read" FAKE_POOLER_STATUS=404 -- rotate_db_password acme "$REASON"
check '[[ $status -eq 1 && "$out" == *"nothing was changed on acme"* && "$(order)" != *"PATCH"* && "$(order)" != *"vault-put"* ]]' "nothing changed, and says so"
check '[[ "$(vault "cloveerp:deployment:${ACME}:db_url")" == "$SEED_URL" && "$(events)" == "acme|note|failed|"* ]]' "the old connection stands, and the row says it failed"
run "a password the API will not take" FAKE_PASSWORD_STATUS=400 -- rotate_db_password acme "$REASON"
check '[[ $status -eq 1 && "$out" == *"did not take the new password"* && "$out" == *"Run the rotation again"* ]]' "says to run it again"
check '[[ "$(vault "cloveerp:deployment:${ACME}:db_url")" == "$SEED_URL" && "$(vault cloveerp:provision:acme:db_pass)" =~ ^[A-Za-z0-9]{40}$ ]]' \
      "the connection releases read is untouched, and the password the project may have is kept"
run "a connection that cannot be stored" "FAKE_PSQL_FAIL=cloveerp:deployment:${ACME}:db_url" -- rotate_db_password acme "$REASON"
check '[[ $status -eq 1 && "$out" == *"could not be stored"* && "$(vault cloveerp:provision:acme:db_pass)" == "$(body 2 | jq -r .password)" ]]' \
      "says so, and the password the project now has is still in the vault"
run "a connection that never answers" GITHUB_ACTIONS=true FAKE_CONNECT_FAILS=99 PROVE_ATTEMPTS=3 -- rotate_db_password acme "$REASON"
PASS=$(body 2 | jq -r .password)
check '[[ $status -eq 1 && "$out" == *"::error::acme:"*"did not answer in 3 attempt(s)"* && "$(cat "$work/fake/connects")" == 3 ]]' "red after the attempts, saying so"
check '[[ "$(printf "%s\n" "$out" | grep -F -- "$PASS" | grep -vc "^::add-mask::")" == 0 && "$out" == *"[hidden]"* ]]' "the error psql gave is printed with the password taken out"

# 4. The fleet, one at a time
run "every client" -- rotate_db_password all "$REASON"
check '[[ $status -eq 0 && "$out" == *"2 client(s) done"* && "$(events | cut -d"|" -f1-3 | tr "\n" " ")" == "acme|note|done beta|note|done " ]]' "the built and the live, not the suspended or the unbuilt"
check '[[ "$(sleeps)" == "20 " && "$(order)" == *"event acme note done;sleep 20;GET /v1/projects/${BETA}/config/database/pooler"* ]]' "a pause between clients, and none before the first"
check '[[ "$(body 2 | jq -r .password)" != "$(body 4 | jq -r .password)" && "$(vault "cloveerp:deployment:${BETA}:db_url")" == *"postgres.${BETA}:"* ]]' "each its own password and its own connection"
run "the first client fails" FAKE_POOLER_STATUS=500 MAPI_ATTEMPTS=1 -- rotate_db_password all "$REASON"
check '[[ $status -eq 1 && "$out" == *"Not touched, because acme failed first: beta"* && "$(order)" != *"${BETA}"* ]]' "the rest are not touched, and named"
check '[[ "$(cat "$work/summary")" == *"- acme: FAILED"* && "$(cat "$work/summary")" == *"- not touched: beta"* ]]' "the summary says the same"

# 5. The functions' secrets
run "function secrets" -- set_function_secrets acme "$REASON"
check '[[ $status -eq 0 && "$(order)" == "register read for acme;POST /v1/projects/${ACME}/secrets;event acme note done;" ]]' "one call, then the row"
check '[[ "$(body 1 | jq -r "map(.name + \"=\" + .value) | join(\";\")")" == "RESEND_API_KEY=re_rehearsal_key;CLOVEERP_APP_URL=https://acme.cloveerp.com;CLOVEERP_INVITE_FROM=Clove ERP <noreply@cloveerp.com>" ]]' \
      "the email key, the deployment's origin, and the sender made from MAIL_FROM"
check '[[ "$out" != *"re_rehearsal_key"* && "$(events)" != *"re_rehearsal_key"* && "$(cat "$work/summary")" != *"re_rehearsal_key"* ]]' "the key is printed nowhere"
run "function secrets with a sender given" "INVITE_FROM=Acme Support <help@acme.example>" -- set_function_secrets acme "$REASON"
check '[[ $status -eq 0 && "$(body 1 | jq -r ".[2].value")" == "Acme Support <help@acme.example>" ]]' "the sender given"
run "function secrets the API will not take" FAKE_HTTP_STATUSES=403 -- set_function_secrets all "$REASON"
check '[[ $status -eq 1 && "$out" == *"did not take acme"* && "$out" == *"Not touched, because acme failed first: beta"* ]]' "refused, and beta left alone"

# 6. The auth settings
run "auth settings" -- patch_auth acme "$REASON"
check '[[ $status -eq 0 && "$(order)" == "register read for acme;PATCH /v1/projects/${ACME}/config/auth;GET /v1/projects/${ACME}/config/auth;PATCH /v1/projects/${ACME}/postgrest;GET /v1/projects/${ACME}/postgrest;event acme note done;" ]]' \
      "applied as a build applies them, read back, then the row"
check '[[ "$(body 1 | jq -r .site_url)" == "https://acme.cloveerp.com" && "$(body 1 | jq -r .uri_allow_list)" == "https://acme.cloveerp.com/**" && "$(body 1 | jq -r .disable_signup)" == true && "$(body 1 | jq -r .smtp_pass)" == re_rehearsal_key ]]' \
      "the deployment's own address, sign-up closed, SMTP through Resend"
check '[[ "$out" != *"re_rehearsal_key"* ]]' "the key is not printed"
run "a renamed client's function secrets" "FAKE_ROWS=acme|live|${ACME}|acme-foods" -- set_function_secrets acme "$REASON"
check '[[ $status -eq 0 && "$(body 1 | jq -r ".[1].value")" == "https://acme-foods.cloveerp.com" && "$(events)" == *"CLOVEERP_APP_URL (https://acme-foods.cloveerp.com)"* ]]' \
      "the address the register has it at, not its code: a rename is not undone"
run "a renamed client's auth settings" "FAKE_ROWS=acme|live|${ACME}|acme-foods" -- patch_auth acme "$REASON"
check '[[ $status -eq 0 && "$(body 1 | jq -r .site_url)" == "https://acme-foods.cloveerp.com" && "$(body 1 | jq -r .uri_allow_list)" == "https://acme-foods.cloveerp.com/**" ]]' \
      "the site and the one redirect at its address, not its code"
run "an address in the register that is not one" "FAKE_ROWS=acme|live|${ACME}|Acme Foods" -- patch_auth acme "$REASON"
check '[[ $status -eq 2 && "$out" == *"acme'"'"'s address in the register ('"'"'Acme Foods'"'"') is not one"* ]] && untouched' "refused before anything is touched"
run "auth settings that do not take" 'FAKE_AUTH={"disable_signup":false,"mailer_autoconfirm":false,"site_url":"https://acme.cloveerp.com","smtp_host":"smtp.resend.com"}' -- patch_auth acme "$REASON"
check '[[ $status -eq 1 && "$out" == *"sign-up is still open"* && "$out" == *"auth settings were not all applied"* && "$(events)" == "acme|note|failed|"* ]]' "red, saying which did not take"

echo "$CASES checks over the fleet's secrets, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
