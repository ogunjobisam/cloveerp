#!/usr/bin/env bash
#
# supabase/ci/provision_project.sh, rehearsed with no Management API.
#
# The script makes and sets up a client's Supabase project, and it runs for
# real only when a client is being onboarded: a mistake in it is learned on a
# paying client's project, or by making a second one by accident. So every
# build runs it here first, against a curl that answers from a script and
# writes down what it was asked: what each subcommand refuses, what each one
# sends (sign-up closed, addresses confirmed, the site URL, custom SMTP, the
# exposed schemas, a confirmed owner), that a setting read back wrong stops
# it, and that no password, key or secret value is ever printed. Seconds.
#
# And the patience every Management API call in the fleet's workflows has
# (supabase/ci/management_api.sh, mapi): a 429 or a 5xx asked again after a
# pause that doubles, never shorter than Retry-After; given up after
# MAPI_ATTEMPTS, saying so; any other 4xx never asked again. The pauses are
# written down, not slept.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/provision_project.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── A Management API that answers from the environment ───────────────────────
cat > "$work/curl" <<'FAKE'
#!/usr/bin/env bash
# Every request is written down as "METHOD URL", its body kept under the
# request's number, and the answer chosen by the path.
method=GET; url=""; body=""; want_status=no; fail=no; headers=""; dump=""
DEFAULT_FUNCTIONS='[{"id":"f1","slug":"dispatch","name":"dispatch","status":"ACTIVE","version":3},{"id":"f2","slug":"invite","name":"invite","status":"ACTIVE","version":1}]'
DEFAULT_CREATE='{"ref":"abcdefghijklmnopqrst","status":"COMING_UP"}'
DEFAULT_POSTGREST='{"db_schema":"public, graphql_public"}'
DEFAULT_KEYS='[{"type":"publishable","name":"default","api_key":"sb_publishable_rehearsal"},{"type":"secret","name":"default","api_key":"sb_secret_rehearsal"}]'
DEFAULT_POOLER='[{"database_type":"PRIMARY","pool_mode":"session","db_host":"aws-0-eu-central-1.pooler.supabase.com","db_port":5432,"db_user":"postgres.abcdefghijklmnopqrst","db_name":"postgres"}]'
DEFAULT_ADMIN='{"id":"u1","email":"owner@example.com"}'
DEFAULT_LIST='{"projects":[],"pagination":{"count":0}}'
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|-d) body="$2"; shift 2 ;;
    -w) want_status=yes; shift 2 ;;
    --fail-with-body) fail=yes; shift ;;
    -H) headers+="$2"$'\n'; shift 2 ;;
    -D|--dump-header) dump="$2"; shift 2 ;;
    -o) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/calls"
echo "$method $url" >> "$FAKE_DIR/curl.log"
[[ -z "$body" ]] || printf '%s' "$body" > "$FAKE_DIR/body.$n"
printf '%s' "$headers" > "$FAKE_DIR/headers.$n"
path="${url#*//*/}"
status="${FAKE_HTTP_STATUS:-200}"
# Or a status per call, from a comma list, the last one repeated: 429,429,200
# is a busy minute that ends. 000 is no answer at all (curl exits 7).
if [[ -n "${FAKE_HTTP_STATUSES:-}" ]]; then
  IFS=',' read -r -a hseq <<< "$FAKE_HTTP_STATUSES"
  i=$(( n - 1 ))
  (( i < ${#hseq[@]} )) || i=$(( ${#hseq[@]} - 1 ))
  status="${hseq[$i]}"
fi
answer=""
case "$method $path" in
  "GET v1/organizations/"*"/projects"*) answer="${FAKE_LIST:-$DEFAULT_LIST}" ;;
  "POST v1/projects") answer="${FAKE_CREATE:-$DEFAULT_CREATE}" ;;
  "GET v1/projects/"*"/config/auth")
    if [[ -n "${FAKE_AUTH:-}" ]]; then answer="$FAKE_AUTH"
    elif [[ -s "$FAKE_DIR/auth.patched" ]]; then answer="$(cat "$FAKE_DIR/auth.patched")"
    else answer='{"disable_signup":false,"mailer_autoconfirm":true}'; fi ;;
  "PATCH v1/projects/"*"/config/auth") printf '%s' "$body" > "$FAKE_DIR/auth.patched"; answer='{}' ;;
  "GET v1/projects/"*"/postgrest") answer="${FAKE_POSTGREST:-$DEFAULT_POSTGREST}" ;;
  "PATCH v1/projects/"*"/postgrest") answer='{}' ;;
  "GET v1/projects/"*"/api-keys"*) answer="${FAKE_KEYS:-$DEFAULT_KEYS}" ;;
  "GET v1/projects/"*"/config/database/pooler") answer="${FAKE_POOLER:-$DEFAULT_POOLER}" ;;
  "PATCH v1/projects/"*"/database/password") answer='{}' ;;
  "POST v1/projects/"*"/secrets") answer='{}' ;;
  "GET v1/projects/"*"/functions") answer="${FAKE_FUNCTIONS:-$DEFAULT_FUNCTIONS}" ;;
  "GET v1/projects/"*)
    # A status per call, from a list, the last one repeated.
    seq=(${FAKE_STATUSES:-ACTIVE_HEALTHY})
    i=$(( $(cat "$FAKE_DIR/status.calls" 2>/dev/null || echo 0) ))
    echo $((i + 1)) > "$FAKE_DIR/status.calls"
    (( i < ${#seq[@]} )) || i=$(( ${#seq[@]} - 1 ))
    answer="{\"ref\":\"abcdefghijklmnopqrst\",\"status\":\"${seq[$i]}\"}" ;;
  "POST auth/v1/admin/users") status="${FAKE_ADMIN_STATUS:-200}"; answer="${FAKE_ADMIN_BODY:-$DEFAULT_ADMIN}" ;;
  "POST auth/v1/otp"*) answer='{}' ;;
  *) answer='{}' ;;
esac
# The headers, as curl -D writes them; a Retry-After on any answer that is
# not a 2xx when FAKE_RETRY_AFTER says so.
if [[ -n "$dump" ]]; then
  {
    printf 'HTTP/2 %s\r\n' "$status"
    printf 'content-type: application/json\r\n'
    if [[ -n "${FAKE_RETRY_AFTER:-}" && ! "$status" =~ ^2 ]]; then printf 'Retry-After: %s\r\n' "$FAKE_RETRY_AFTER"; fi
    printf '\r\n'
  } > "$dump"
fi
if [[ "$status" == 000 ]]; then
  [[ "$want_status" == yes ]] && printf '\n000'
  echo "curl: (7) Failed to connect to the rehearsal's API" >&2
  exit 7
fi
printf '%s' "$answer"
[[ "$want_status" == yes ]] && printf '\n%s' "$status"
[[ "$fail" == no || "$status" =~ ^2 ]] || exit 22
exit 0
FAKE
chmod +x "$work/curl"

# A sleep that only writes down how long it was asked to wait.
cat > "$work/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_DIR/sleeps"
FAKE
chmod +x "$work/sleep"

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...] -- <subcommand args>: a fresh fake, the script, its exit and output.
  local name="$1"; shift
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  rm -rf "$work/fake"; mkdir -p "$work/fake"
  out=$(env FAKE_DIR="$work/fake" CURL="$work/curl" API="https://api.example" MAPI_SLEEP="$work/sleep" \
          SUPABASE_ACCESS_TOKEN=rehearsal-token ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" 2>&1)
  status=$?
  err=""
  CURRENT="$name"
}
run_mapi() {
  # run_mapi <name> [VAR=value ...] -- METHOD PATH [BODY]: mapi itself,
  # sourced as the workflows source it; its stdout in $out, its stderr in $err.
  local name="$1"; shift
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  rm -rf "$work/fake"; mkdir -p "$work/fake"
  out=$(env FAKE_DIR="$work/fake" CURL="$work/curl" API="https://api.example" MAPI_SLEEP="$work/sleep" \
          SUPABASE_ACCESS_TOKEN=rehearsal-token ${vars[@]+"${vars[@]}"} \
          bash -c 'set -euo pipefail; . "$0"; mapi "$@"' "$HERE/management_api.sh" "$@" 2> "$work/stderr")
  status=$?
  err=$(cat "$work/stderr")
  CURRENT="$name"
}
check() {
  CASES=$((CASES + 1))
  if eval "$1"; then
    echo "  ok   $CURRENT: $2"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL $CURRENT: $2"
    printf '%s\n%s\n' "$out" "${err:-}" | sed 's/^/       | /' | head -n 20
  fi
}
requests() { cat "$work/fake/curl.log" 2>/dev/null | tr '\n' ';'; }
calls() { cat "$work/fake/calls" 2>/dev/null || echo 0; }
sleeps() { cat "$work/fake/sleeps" 2>/dev/null | tr '\n' ' '; }
body() { cat "$work/fake/body.$1" 2>/dev/null; }

PASS="rehearsal-password-of-twenty-four-or-more"
CREATE=(ORG_SLUG=orgslug REGION=eu-central-1 INSTANCE_SIZE=micro "DB_PASS=$PASS")

# 1. No token
run "no access token" SUPABASE_ACCESS_TOKEN= -- create acme "Acme Ltd"
check '[[ $status -eq 2 && "$out" == *"SUPABASE_ACCESS_TOKEN is not set"* && ! -e "$work/fake/curl.log" ]]' \
      "refused before anything is asked"

# 2. create
run "a code that is not an address" "${CREATE[@]}" -- create "Acme!" "Acme Ltd"
check '[[ $status -eq 2 && "$out" == *"not an address-shaped code"* && ! -e "$work/fake/curl.log" ]]' "refused before anything is asked"
run "a short password" ORG_SLUG=o REGION=r INSTANCE_SIZE=micro DB_PASS=short -- create acme "Acme Ltd"
check '[[ $status -eq 2 && "$out" == *"DB_PASS must be set, 24 characters"* && ! -e "$work/fake/curl.log" ]]' "refused before anything is asked"
run "a project of that name already" "${CREATE[@]}" 'FAKE_LIST={"projects":[{"ref":"zzzzzzzzzzzzzzzzzzzz","name":"Clove ERP - Acme Ltd"}],"pagination":{"count":1}}' -- create acme "Acme Ltd"
check '[[ $status -eq 2 && "$out" == *"already exists (zzzzzzzzzzzzzzzzzzzz)"* && "$(requests)" == "GET https://api.example/v1/organizations/orgslug/projects?limit=100;" ]]' \
      "refused with the existing ref, and no second project made"
run "a new project" "${CREATE[@]}" -- create acme "Acme Ltd"
check '[[ $status -eq 0 && "$out" == *"ref=abcdefghijklmnopqrst"* ]]' "prints the ref"
check '[[ "$(requests)" == "GET https://api.example/v1/organizations/orgslug/projects?limit=100;POST https://api.example/v1/projects;" ]]' "lists the organisation's projects, then creates"
check '[[ "$(body 2 | jq -r .name)" == "Clove ERP - Acme Ltd" && "$(body 2 | jq -r .organization_slug)" == "orgslug" && "$(body 2 | jq -r .region)" == "eu-central-1" && "$(body 2 | jq -r .desired_instance_size)" == "micro" && "$(body 2 | jq -r .db_pass)" == "$PASS" ]]' \
      "the body names the project, the organisation, the region, the size and the password"
check '[[ "$out" != *"$PASS"* ]]' "the password is not printed"

# 3. wait
run "a project coming up" POLL_SECONDS=0 "FAKE_STATUSES=COMING_UP COMING_UP ACTIVE_HEALTHY" -- wait abcdefghijklmnopqrst
check '[[ $status -eq 0 && "$out" == *"status=ACTIVE_HEALTHY"* && $(grep -c "GET https://api.example/v1/projects/abcdefghijklmnopqrst" "$work/fake/curl.log") -eq 3 ]]' \
      "polls until healthy"
run "a project that failed to start" POLL_SECONDS=0 FAKE_STATUSES=INIT_FAILED -- wait abcdefghijklmnopqrst
check '[[ $status -eq 2 && "$out" == *"INIT_FAILED"* ]]' "refused rather than waited for"
run "a project that never comes up" POLL_SECONDS=0 WAIT_SECONDS=0 FAKE_STATUSES=COMING_UP -- wait abcdefghijklmnopqrst
check '[[ $status -eq 2 && "$out" == *"still COMING_UP"* ]]' "refused at the limit, and says to resume"

# 4. configure
CONF=(APEX=cloveerp.com RESEND_API_KEY=re_rehearsal_key MAIL_FROM=noreply@cloveerp.com)
run "no Resend key" APEX=cloveerp.com MAIL_FROM=noreply@cloveerp.com -- configure abcdefghijklmnopqrst acme
check '[[ $status -eq 2 && "$out" == *"RESEND_API_KEY is not set"* && ! -e "$work/fake/curl.log" ]]' "refused before anything is asked"
run "configured" "${CONF[@]}" -- configure abcdefghijklmnopqrst acme
check '[[ $status -eq 0 && "$out" == *"origin=https://acme.cloveerp.com"* ]]' "says the origin"
check '[[ "$(requests)" == "PATCH https://api.example/v1/projects/abcdefghijklmnopqrst/config/auth;GET https://api.example/v1/projects/abcdefghijklmnopqrst/config/auth;PATCH https://api.example/v1/projects/abcdefghijklmnopqrst/postgrest;GET https://api.example/v1/projects/abcdefghijklmnopqrst/postgrest;" ]]' \
      "patches auth, reads it back, patches PostgREST, reads it back"
check '[[ "$(body 1 | jq -r .disable_signup)" == "true" && "$(body 1 | jq -r .mailer_autoconfirm)" == "false" && "$(body 1 | jq -r .site_url)" == "https://acme.cloveerp.com" && "$(body 1 | jq -r .uri_allow_list)" == "https://acme.cloveerp.com/**" && "$(body 1 | jq -r .password_min_length)" == "12" ]]' \
      "sign-up closed, confirmation required, the site URL and redirects, a twelve-character password"
check '[[ "$(body 1 | jq -r .smtp_host)" == "smtp.resend.com" && "$(body 1 | jq -r .smtp_pass)" == "re_rehearsal_key" && "$(body 1 | jq -r .smtp_admin_email)" == "noreply@cloveerp.com" && "$(body 1 | jq -r .smtp_port)" == "465" ]]' \
      "custom SMTP through Resend"
check '[[ "$(body 3 | jq -r .db_schema)" == "public, graphql_public" ]]' "PostgREST exposes public and graphql_public only"
check '[[ "$out" != *"re_rehearsal_key"* ]]' "the Resend key is not printed"
run "a PATCH that did not take" "${CONF[@]}" 'FAKE_AUTH={"disable_signup":false,"mailer_autoconfirm":false,"site_url":"https://acme.cloveerp.com","smtp_host":"smtp.resend.com"}' -- configure abcdefghijklmnopqrst acme
check '[[ $status -eq 2 && "$out" == *"sign-up is still open"* ]]' "refused when the setting read back wrong"
run "PostgREST still exposing erp" "${CONF[@]}" 'FAKE_POSTGREST={"db_schema":"public, erp"}' -- configure abcdefghijklmnopqrst acme
check '[[ $status -eq 2 && "$out" == *"exposes"* ]]' "refused when the erp schema is still exposed"

# 5. keys
run "keys without a file to put the secret in" -- keys abcdefghijklmnopqrst
check '[[ $status -eq 2 && "$out" == *"SECRET_OUT"* && ! -e "$work/fake/curl.log" ]]' "refused before anything is asked"
run "keys" "SECRET_OUT=$work/secret.key" -- keys abcdefghijklmnopqrst
check '[[ $status -eq 0 && "$out" == *"publishable=sb_publishable_rehearsal"* && "$(cat "$work/secret.key")" == "sb_secret_rehearsal" && "$out" != *"sb_secret_rehearsal"* ]]' \
      "the publishable key is printed, the secret key is written to the file and nowhere else"
check '[[ "$(requests)" == "GET https://api.example/v1/projects/abcdefghijklmnopqrst/api-keys?reveal=true;" ]]' "asks for the keys revealed"
run "legacy keys only" "SECRET_OUT=$work/secret2.key" 'FAKE_KEYS=[{"name":"anon","api_key":"anon-jwt"},{"name":"service_role","api_key":"service-jwt"}]' -- keys abcdefghijklmnopqrst
check '[[ $status -eq 0 && "$out" == *"publishable=anon-jwt"* && "$(cat "$work/secret2.key")" == "service-jwt" ]]' "falls back to anon and service_role"

# 6. owner
run "owner without the service key" PROJECT_API_URL=https://api.example -- owner abcdefghijklmnopqrst owner@example.com
check '[[ $status -eq 2 && "$out" == *"SERVICE_KEY is not set"* && ! -e "$work/fake/curl.log" ]]' "refused before anything is asked"
run "owner made" SERVICE_KEY=sb_secret_rehearsal PROJECT_API_URL=https://api.example -- owner abcdefghijklmnopqrst owner@example.com
check '[[ $status -eq 0 && "$out" == *"owner=owner@example.com"* && "$(requests)" == "POST https://api.example/auth/v1/admin/users;" ]]' "one call to the admin API"
check '[[ "$(body 1 | jq -r .email)" == "owner@example.com" && "$(body 1 | jq -r .email_confirm)" == "true" && -n "$(body 1 | jq -r .password)" ]]' "confirmed, with a password nobody knows"
check '[[ "$out" != *"$(body 1 | jq -r .password)"* && "$out" != *"sb_secret_rehearsal"* ]]' "neither the password nor the key is printed"
run "owner made with a new-format secret key" SERVICE_KEY=sb_secret_rehearsal PROJECT_API_URL=https://api.example -- owner abcdefghijklmnopqrst owner@example.com
check '[[ $status -eq 0 && "$(cat "$work/fake/headers.1")" == *"apikey: sb_secret_rehearsal"* && "$(cat "$work/fake/headers.1")" != *"Authorization"* ]]' "the new-format secret key goes as apikey only, never as a bearer"
check '[[ "$(body 1 | jq -r .password)" =~ [a-z] && "$(body 1 | jq -r .password)" =~ [A-Z] && "$(body 1 | jq -r .password)" =~ [0-9] && $(body 1 | jq -r .password | tr -d "\n" | wc -c) -ge 12 ]]' "the password always meets the project's rule"
run "owner made with a legacy service key" SERVICE_KEY=eyJlegacy.jwt.key PROJECT_API_URL=https://api.example -- owner abcdefghijklmnopqrst owner@example.com
check '[[ $status -eq 0 && "$(cat "$work/fake/headers.1")" == *"Authorization: Bearer eyJlegacy.jwt.key"* ]]' "a legacy service key, a JWT, goes as a bearer too"
run "owner already there" SERVICE_KEY=k PROJECT_API_URL=https://api.example FAKE_ADMIN_STATUS=422 'FAKE_ADMIN_BODY={"msg":"A user with this email address has already been registered"}' -- owner abcdefghijklmnopqrst owner@example.com
check '[[ $status -eq 0 && "$out" == *"already exists"* ]]' "fine"
run "the admin API refuses" SERVICE_KEY=k PROJECT_API_URL=https://api.example FAKE_ADMIN_STATUS=401 'FAKE_ADMIN_BODY={"msg":"invalid"}' -- owner abcdefghijklmnopqrst owner@example.com
check '[[ $status -eq 2 && "$out" == *"answered 401"* ]]' "refused"

# 7. pooler
run "the pooler" -- pooler abcdefghijklmnopqrst
check '[[ $status -eq 0 && "$out" == *"host=aws-0-eu-central-1.pooler.supabase.com"* && "$out" == *"port=5432"* && "$out" == *"user=postgres.abcdefghijklmnopqrst"* && "$out" == *"dbname=postgres"* ]]' \
      "prints the session pooler's parts"
run "a project whose pooler defaults to transaction mode" 'FAKE_POOLER=[{"database_type":"PRIMARY","pool_mode":"transaction","db_host":"aws-1-eu-central-1.pooler.supabase.com","db_port":6543,"db_user":"postgres.abcdefghijklmnopqrst","db_name":"postgres"}]' -- pooler abcdefghijklmnopqrst
check '[[ $status -eq 0 && "$out" == *"host=aws-1-eu-central-1.pooler.supabase.com"* && "$out" == *"port=5432"* && "$out" != *"6543"* ]]' "the connection is the session pooler on 5432, whatever mode the project defaults to"
run "a pooler user naming another project" 'FAKE_POOLER=[{"database_type":"PRIMARY","pool_mode":"session","db_host":"h","db_port":5432,"db_user":"postgres.zzzzzzzzzzzzzzzzzzzz","db_name":"postgres"}]' -- pooler abcdefghijklmnopqrst
check '[[ $status -eq 2 && "$out" == *"does not name abcdefghijklmnopqrst"* ]]' "refused"

# 8. password
run "the password" "DB_PASS=$PASS" -- password abcdefghijklmnopqrst
check '[[ $status -eq 0 && "$(body 1 | jq -r .password)" == "$PASS" && "$out" != *"$PASS"* ]]' "sent, not printed"

# 9. secrets
run "a SUPABASE_ secret" -- secrets abcdefghijklmnopqrst SUPABASE_URL=x
check '[[ $status -eq 2 && "$out" == *"may not start with SUPABASE_"* && ! -e "$work/fake/curl.log" ]]' "refused before anything is asked"
run "secrets" -- secrets abcdefghijklmnopqrst RESEND_API_KEY=re_rehearsal_key CLOVEERP_APP_URL=https://acme.cloveerp.com
check '[[ $status -eq 0 && "$out" == *"secrets=RESEND_API_KEY CLOVEERP_APP_URL"* && "$(body 1 | jq -r "[.[].name] | join(\" \")")" == "RESEND_API_KEY CLOVEERP_APP_URL" && "$(body 1 | jq -r ".[0].value")" == "re_rehearsal_key" ]]' \
      "the names are said, the values sent"
check '[[ "$out" != *"re_rehearsal_key"* ]]' "the values are not printed"

# 10. The API answering an error
run "an API error" "${CREATE[@]}" FAKE_HTTP_STATUS=401 -- create acme "Acme Ltd"
check '[[ $status -eq 2 && "$out" == *"GET /v1/organizations/orgslug/projects"* && "$out" == *"failed"* ]]' "refused, naming the call"
check '[[ "$out" == *"answered 401"* && "$(calls)" -eq 1 && -z "$(sleeps)" ]]' "says the status, and a 401 is never asked again"

# 11. mapi: a busy minute waited out, a verdict taken as one
P=/v1/projects/abcdefghijklmnopqrst/postgrest
run_mapi "a busy minute" "FAKE_HTTP_STATUSES=429,429,200" -- GET "$P"
check '[[ $status -eq 0 && "$out" == "{\"db_schema\":\"public, graphql_public\"}" && "$(calls)" -eq 3 && "$(sleeps)" == "5 10 " ]]' \
      "asked again after 5 s and 10 s, and the third answer's body is printed"
check '[[ "$err" == *"GET $P answered 429 on attempt 1 of 5; asking again in 5 s"* && "$err" == *"on attempt 2 of 5; asking again in 10 s"* ]]' \
      "says so each time it waits"
run_mapi "an API that stays down" MAPI_ATTEMPTS=3 FAKE_HTTP_STATUSES=503 -- GET "$P"
check '[[ $status -eq 1 && "$(calls)" -eq 3 && "$(sleeps)" == "5 10 " && -z "$out" && "$err" == *"answered 503 on each of 3 attempt(s)"* ]]' \
      "given up after MAPI_ATTEMPTS, saying so, and no body printed"
run_mapi "a 400" FAKE_HTTP_STATUSES=400 -- PATCH "$P" '{"db_schema":"erp"}'
check '[[ $status -eq 1 && "$(calls)" -eq 1 && -z "$(sleeps)" && "$err" == *"PATCH $P answered 400"* ]]' \
      "never asked again: a 4xx other than 429 is a verdict on the request"
run_mapi "a 404" "FAKE_HTTP_STATUSES=404,200" -- GET "$P"
check '[[ $status -eq 1 && "$(calls)" -eq 1 && -z "$(sleeps)" ]]' "nor a 404"
run_mapi "a Retry-After longer than the backoff" "FAKE_HTTP_STATUSES=429,200" FAKE_RETRY_AFTER=17 -- GET "$P"
check '[[ $status -eq 0 && "$(calls)" -eq 2 && "$(sleeps)" == "17 " ]]' "waits as long as the API asked, not the 5 s backoff"
run_mapi "a Retry-After shorter than the backoff" "FAKE_HTTP_STATUSES=429,429,200" FAKE_RETRY_AFTER=1 -- GET "$P"
check '[[ $status -eq 0 && "$(sleeps)" == "5 10 " ]]' "never less than the backoff"
run_mapi "a Retry-After longer than anybody waits" FAKE_HTTP_STATUSES=429 FAKE_RETRY_AFTER=3600 -- GET "$P"
check '[[ $status -eq 1 && "$(calls)" -eq 1 && -z "$(sleeps)" && "$err" == *"asked for 3600 s"* ]]' \
      "given up at once, rather than waited out past the job's own limit"
run_mapi "no answer at all" "FAKE_HTTP_STATUSES=000,200" -- GET "$P"
check '[[ $status -eq 0 && "$(calls)" -eq 2 && "$(sleeps)" == "5 " ]]' "a connection that failed is asked again"
run_mapi "no token" SUPABASE_ACCESS_TOKEN= -- GET "$P"
check '[[ $status -eq 2 && "$err" == *"SUPABASE_ACCESS_TOKEN is not set"* && ! -e "$work/fake/curl.log" ]]' "refused before anything is asked"
run_mapi "a body" -- POST /v1/projects/abcdefghijklmnopqrst/secrets '[{"name":"A","value":"b"}]'
check '[[ $status -eq 0 && "$(body 1)" == "[{\"name\":\"A\",\"value\":\"b\"}]" && "$(cat "$work/fake/headers.1")" == *"Authorization: Bearer rehearsal-token"* && "$(cat "$work/fake/headers.1")" == *"Content-Type: application/json"* ]]' \
      "the body goes as JSON and the token as the bearer"
check '[[ "$out$err" != *"rehearsal-token"* ]]' "the token is never printed"

# 12. The functions a project already has (release.yml, "Deploy the Edge Functions")
run_mapi "the functions on a project" -- GET /v1/projects/abcdefghijklmnopqrst/functions
check '[[ $status -eq 0 && "$(requests)" == "GET https://api.example/v1/projects/abcdefghijklmnopqrst/functions;" && "$(jq -r ".[].slug" <<< "$out" | tr "\n" " ")" == "dispatch invite " ]]' \
      "one GET, and the slugs read the way the release reads them"
run_mapi "a project with no function yet" "FAKE_FUNCTIONS=[]" -- GET /v1/projects/abcdefghijklmnopqrst/functions
check '[[ $status -eq 0 && -z "$(jq -r ".[].slug" <<< "$out")" ]]' "nothing there, so every function is new to it"

# 13. Every subcommand waits a busy minute out, through api()
run "a busy minute while making a project" "${CREATE[@]}" "FAKE_HTTP_STATUSES=429,200,200" -- create acme "Acme Ltd"
check '[[ $status -eq 0 && "$out" == *"ref=abcdefghijklmnopqrst"* && "$(requests)" == "GET https://api.example/v1/organizations/orgslug/projects?limit=100;GET https://api.example/v1/organizations/orgslug/projects?limit=100;POST https://api.example/v1/projects;" ]]' \
      "the list asked again, then one project made"
run "a busy minute that does not end" "${CREATE[@]}" MAPI_ATTEMPTS=2 FAKE_HTTP_STATUSES=429 -- create acme "Acme Ltd"
check '[[ $status -eq 2 && "$out" == *"GET /v1/organizations/orgslug/projects?limit=100 failed"* && "$(requests)" != *"POST"* ]]' \
      "refused, naming the call, and no project made"

# 14. sign-in-link: the project's own mail, proved at the end of a build
LINK=(sign-in-link abcdefghijklmnopqrst owner@example.com https://acme.cloveerp.com/signin)
run "a sign-in link without the publishable key" PROJECT_API_URL=https://api.example -- "${LINK[@]}"
check '[[ $status -eq 2 && "$out" == *"PUBLISHABLE_KEY is not set"* && ! -e "$work/fake/curl.log" ]]' "refused before anything is asked"
run "a sign-in link" PUBLISHABLE_KEY=sb_publishable_rehearsal PROJECT_API_URL=https://api.example -- "${LINK[@]}"
check '[[ $status -eq 0 && "$out" == *"sign-in-link=sent"* && "$(requests)" == "POST https://api.example/auth/v1/otp?redirect_to=https%3A%2F%2Facme.cloveerp.com%2Fsignin;" ]]' \
      "one request to the project's auth API, coming back to the sign-in page"
check '[[ "$(body 1 | jq -r .email)" == "owner@example.com" && "$(body 1 | jq -r .create_user)" == "false" ]]' \
      "for the owner, and nobody is made"
check '[[ "$(cat "$work/fake/headers.1")" == *"apikey: sb_publishable_rehearsal"* && "$(cat "$work/fake/headers.1")" != *"Authorization"* && "$(cat "$work/fake/headers.1")" != *"rehearsal-token"* ]]' \
      "the new-format publishable key goes as apikey only, and the access token not at all"
run "a sign-in link with a legacy anon key" PUBLISHABLE_KEY=eyJanon.jwt.key PROJECT_API_URL=https://api.example -- "${LINK[@]}"
check '[[ $status -eq 0 && "$(cat "$work/fake/headers.1")" == *"Authorization: Bearer eyJanon.jwt.key"* ]]' "a legacy anon key, a JWT, goes as a bearer too"
run "a mailer that is busy for a moment" PUBLISHABLE_KEY=sb_publishable_rehearsal PROJECT_API_URL=https://api.example "FAKE_HTTP_STATUSES=429,200" -- "${LINK[@]}"
check '[[ $status -eq 0 && "$(calls)" -eq 2 && "$(sleeps)" == "5 " ]]' "asked again, as mapi asks"
run "SMTP that refuses" PUBLISHABLE_KEY=sb_publishable_rehearsal PROJECT_API_URL=https://api.example MAPI_ATTEMPTS=2 FAKE_HTTP_STATUSES=500 -- "${LINK[@]}"
check '[[ $status -eq 2 && "$out" == *"SMTP Settings"* && "$out" == *"smtp.resend.com"* && "$out" == *"RESEND_API_KEY"* && "$out" != *"sign-in-link=sent"* ]]' \
      "refused, naming the SMTP settings to check"
run "no such sign-in" PUBLISHABLE_KEY=sb_publishable_rehearsal PROJECT_API_URL=https://api.example FAKE_HTTP_STATUSES=422 -- "${LINK[@]}"
check '[[ $status -eq 2 && "$(calls)" -eq 1 && "$out" == *"answered 422"* ]]' "refused at once: a 422 is not a busy minute"

echo "$CASES checks over the project provisioning, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
