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
method=GET; url=""; body=""; want_status=no; fail=no; headers=""
DEFAULT_CREATE='{"ref":"abcdefghijklmnopqrst","status":"COMING_UP"}'
DEFAULT_POSTGREST='{"db_schema":"public, graphql_public"}'
DEFAULT_KEYS='[{"type":"publishable","name":"default","api_key":"sb_publishable_rehearsal"},{"type":"secret","name":"default","api_key":"sb_secret_rehearsal"}]'
DEFAULT_POOLER='[{"database_type":"PRIMARY","pool_mode":"session","db_host":"aws-0-eu-central-1.pooler.supabase.com","db_port":5432,"db_user":"postgres.abcdefghijklmnopqrst","db_name":"postgres"}]'
DEFAULT_ADMIN='{"id":"u1","email":"owner@example.com"}'
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|-d) body="$2"; shift 2 ;;
    -w) want_status=yes; shift 2 ;;
    --fail-with-body) fail=yes; shift ;;
    -H) headers+="$2"$'\n'; shift 2 ;;
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
answer=""
case "$method $path" in
  "GET v1/projects") answer="${FAKE_LIST:-[]}" ;;
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
  "GET v1/projects/"*)
    # A status per call, from a list, the last one repeated.
    seq=(${FAKE_STATUSES:-ACTIVE_HEALTHY})
    i=$(( $(cat "$FAKE_DIR/status.calls" 2>/dev/null || echo 0) ))
    echo $((i + 1)) > "$FAKE_DIR/status.calls"
    (( i < ${#seq[@]} )) || i=$(( ${#seq[@]} - 1 ))
    answer="{\"ref\":\"abcdefghijklmnopqrst\",\"status\":\"${seq[$i]}\"}" ;;
  "POST auth/v1/admin/users") status="${FAKE_ADMIN_STATUS:-200}"; answer="${FAKE_ADMIN_BODY:-$DEFAULT_ADMIN}" ;;
  *) answer='{}' ;;
esac
printf '%s' "$answer"
[[ "$want_status" == yes ]] && printf '\n%s' "$status"
[[ "$fail" == no || "$status" =~ ^2 ]] || exit 22
exit 0
FAKE
chmod +x "$work/curl"

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...] -- <subcommand args>: a fresh fake, the script, its exit and output.
  local name="$1"; shift
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  rm -rf "$work/fake"; mkdir -p "$work/fake"
  out=$(env FAKE_DIR="$work/fake" CURL="$work/curl" API="https://api.example" \
          SUPABASE_ACCESS_TOKEN=rehearsal-token ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" 2>&1)
  status=$?
  CURRENT="$name"
}
check() {
  CASES=$((CASES + 1))
  if eval "$1"; then
    echo "  ok   $CURRENT: $2"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL $CURRENT: $2"
    echo "$out" | sed 's/^/       | /' | head -n 20
  fi
}
requests() { cat "$work/fake/curl.log" 2>/dev/null | tr '\n' ';'; }
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
run "a project of that name already" "${CREATE[@]}" 'FAKE_LIST=[{"ref":"zzzzzzzzzzzzzzzzzzzz","name":"Clove ERP - Acme Ltd"}]' -- create acme "Acme Ltd"
check '[[ $status -eq 2 && "$out" == *"already exists (zzzzzzzzzzzzzzzzzzzz)"* && "$(requests)" == "GET https://api.example/v1/projects;" ]]' \
      "refused with the existing ref, and no second project made"
run "a new project" "${CREATE[@]}" -- create acme "Acme Ltd"
check '[[ $status -eq 0 && "$out" == *"ref=abcdefghijklmnopqrst"* ]]' "prints the ref"
check '[[ "$(requests)" == "GET https://api.example/v1/projects;POST https://api.example/v1/projects;" ]]' "lists, then creates"
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
check '[[ $status -eq 2 && "$out" == *"GET /v1/projects"* && "$out" == *"failed"* ]]' "refused, naming the call"

echo "$CASES checks over the project provisioning, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
