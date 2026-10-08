#!/usr/bin/env bash
#
# supabase/ci/fleet_poll.sh, rehearsed with no database and no API.
#
# The poll reads every client's own database every hour and writes what it
# found on the control plane, where the Fleet view shows it. A poll that
# stops at the first client it cannot read leaves every client after it
# looking silent; one that writes a reading from the wrong database says a
# client is well when it is not; one that prints a connection string hands it
# to anyone who can read a run log. So every build runs it here first,
# against a psql that answers from files (by which database was asked and
# which statement) and a Management API that answers from the environment,
# and writes down what it was asked: each reading and its type, the
# assurance only in the daily poll and carried forward between them, the
# backups, what could not be read said in errors and never stopping the next
# client, a connection that is not the client's never used, statement
# timeouts on every statement, and nothing secret printed. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_poll.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── A psql that answers from files ───────────────────────────────────────────
# As in fleet_staff_sync_rehearsal.sh: the database from the connection
# string, the statement from its "-- fleet: <tag>" line; the answer is
# $FAKE_DIR/answers/<database>/<tag>#<nth call> or <tag>. A line starting
# ERROR: goes to stderr and, with ON_ERROR_STOP, stops there (exit 3);
# CONNECT is a database that cannot be reached (exit 2).
cat > "$work/psql" <<'FAKE'
#!/usr/bin/env bash
conn=""; vars=""; stop=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v)
      case "$2" in
        ON_ERROR_STOP=*) stop="${2#ON_ERROR_STOP=}" ;;
        *) vars+="$2"$'\n' ;;
      esac
      shift 2 ;;
    -c) echo "the rehearsal's psql was given -c, where psql never substitutes :'name'" >&2; exit 9 ;;
    -*) shift ;;
    *) [[ -n "$conn" ]] || conn="$1"; shift ;;
  esac
done
sql=$(cat)
var() { printf '%s' "$vars" | sed -n "s/^$1=//p" | head -n 1; }
n=$(( $(cat "$FAKE_DIR/psql.calls" 2> /dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/psql.calls"
if [[ "$conn" == "$FAKE_CP_URL" ]]; then
  target=cp
elif [[ "$conn" =~ postgres\.([a-z0-9]{20}) ]]; then
  target="${BASH_REMATCH[1]}"
else
  target=unknown
fi
tag=$(printf '%s\n' "$sql" | sed -n 's/^-- fleet: //p' | head -n 1)
if [[ -z "$tag" ]]; then
  case "$sql" in
    *"vault.decrypted_secrets"*) tag=vault-get ;;
    *"record_deployment_event"*) tag=event ;;
    *) tag=untagged ;;
  esac
fi
printf '%s\n' "$sql" > "$FAKE_DIR/sql.$n"
printf '%s' "$vars" > "$FAKE_DIR/vars.$n"
echo "$n $target $tag $stop" >> "$FAKE_DIR/psql.log"
dir="$FAKE_DIR/answers/$target"
if [[ -e "$dir/CONNECT" ]]; then
  echo "psql: error: connection to server at \"pooler.example\" (192.0.2.1), port 5432 failed: $(cat "$dir/CONNECT")" >&2
  exit 2
fi
if [[ "$tag" == vault-get ]]; then
  name=$(var name)
  if [[ -f "$FAKE_DIR/vault/${name//:/_}" ]]; then cat "$FAKE_DIR/vault/${name//:/_}"; fi
  exit 0
fi
k=$(( $(cat "$FAKE_DIR/count.$target.$tag" 2> /dev/null || echo 0) + 1 ))
echo "$k" > "$FAKE_DIR/count.$target.$tag"
file=""
for f in "$dir/$tag#$k" "$dir/$tag"; do
  if [[ -f "$f" ]]; then file="$f"; break; fi
done
[[ -n "$file" ]] || exit 0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == ERROR:* ]]; then
    echo "psql:<stdin>:3: $line" >&2
    echo "LINE 1: select ..." >&2
    if [[ "$stop" == 1 ]]; then exit 3; fi
  else
    printf '%s\n' "$line"
  fi
done < "$file"
exit 0
FAKE
chmod +x "$work/psql"

# ── And the Management API, as mapi asks it ──────────────────────────────────
cat > "$work/curl" <<'FAKE'
#!/usr/bin/env bash
method=GET; url=""; want_status=no; headers=""; dump=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|-d) shift 2 ;;
    -w) want_status=yes; shift 2 ;;
    -H) headers+="$2"$'\n'; shift 2 ;;
    -D|--dump-header) dump="$2"; shift 2 ;;
    --max-time|-o) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
n=$(( $(cat "$FAKE_DIR/curl.calls" 2> /dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/curl.calls"
echo "$method $url" >> "$FAKE_DIR/curl.log"
printf '%s' "$headers" > "$FAKE_DIR/headers.$n"
status="${FAKE_HTTP_STATUS:-200}"
if [[ -n "${FAKE_HTTP_STATUSES:-}" ]]; then
  IFS=',' read -r -a seq <<< "$FAKE_HTTP_STATUSES"
  i=$(( n - 1 ))
  (( i < ${#seq[@]} )) || i=$(( ${#seq[@]} - 1 ))
  status="${seq[$i]}"
fi
default_backups='{"region":"eu-central-1","walg_enabled":true,"pitr_enabled":false,"backups":[{"is_physical_backup":true,"status":"COMPLETED","inserted_at":"2026-10-07T02:00:11.000Z"},{"is_physical_backup":true,"status":"COMPLETED","inserted_at":"2026-10-08T02:00:09.000Z"},{"is_physical_backup":true,"status":"FAILED","inserted_at":"2026-10-06T02:00:00.000Z"}]}'
path="${url#*//*/}"
case "$method $path" in
  "GET v1/projects/"*"/database/backups") answer="${FAKE_BACKUPS:-$default_backups}" ;;
  *) answer='{}' ;;
esac
if [[ ! "$status" =~ ^2 ]]; then answer='{"message":"refused"}'; fi
if [[ -n "$dump" ]]; then
  printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n' "$status" > "$dump"
fi
printf '%s' "$answer"
[[ "$want_status" == yes ]] && printf '\n%s' "$status"
exit 0
FAKE
chmod +x "$work/curl"

cat > "$work/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "$1" >> "$FAKE_DIR/sleeps"
FAKE
chmod +x "$work/sleep"

# ── The fleet the rehearsal polls ────────────────────────────────────────────
CP="postgresql://control-plane"
A=aaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbb
PROD=xpzffnnhnhcqyjqcueja
DEMO=dddddddddddddddddddd
URL_A="postgresql://postgres.${A}:pw-acme-rehearsal-secret@pooler.example:5432/postgres"
URL_B="postgresql://postgres.${B}:pw-beta-rehearsal-secret@pooler.example:5432/postgres"
TOKEN="sbp_rehearsal_access_token"
SHA=6f0bd917534e7b56da32d121907892086fa7fb06
STAFF='["new@clove.example:support","ops@clove.example:operator","owner@clove.example:owner"]'
T="$(printf '\t')"
HEALTH_A="kind${T}client
release_sha${T}${SHA}
database_bytes${T}123456789
last_drain_pass_at${T}2026-10-08T12:00:00Z
open_support_windows${T}1
staff${T}${STAFF}"

answer() { mkdir -p "$work/fake/answers/$1"; printf '%s\n' "$3" > "$work/fake/answers/$1/$2"; }
vault() { mkdir -p "$work/fake/vault"; printf '%s' "$2" > "$work/fake/vault/${1//:/_}"; }
fresh() {
  rm -rf "$work/fake"; mkdir -p "$work/fake"
  answer cp cp-ready "true true"
  answer cp cp-staff '["owner@clove.example:owner","ops@clove.example:operator","new@clove.example:support"]'
  answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${A}\",\"health\":{\"release_sha\":\"old\",\"assurance_failures\":2,\"assurance_at\":\"2026-10-08T03:07:40Z\"}}]"
  answer cp cp-refs "${A},${B}"
  vault "cloveerp:deployment:${A}:db_url" "$URL_A"
  vault "cloveerp:deployment:${B}:db_url" "$URL_B"
  answer "$A" client-health "$HEALTH_A"
  answer "$A" client-assurance "1${T}40${T}vat_agrees"
  answer "$B" client-health "$HEALTH_A"
  answer "$B" client-assurance "0${T}40${T}"
}
two_clients() {
  answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${A}\",\"health\":{}},{\"code\":\"beta\",\"ref\":\"${B}\",\"health\":{}}]"
}

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...] -- light|full [code]
  local name="$1"; shift
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  out=$(env FAKE_DIR="$work/fake" FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" \
          PSQL="$work/psql" CURL="$work/curl" API="https://api.example" FLEET_SLEEP="$work/sleep" MAPI_SLEEP="$work/sleep" \
          SUPABASE_ACCESS_TOKEN="$TOKEN" PAUSE_SECONDS=0 GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$work/fake/summary" \
          PRODUCTION_REF="$PROD" DEMO_REF="$DEMO" ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" 2>&1)
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
    printf '%s\n' "$out" | sed 's/^/       | /' | head -n 25
  fi
}
calls() { awk -v t="$1" -v g="$2" '$2 == t && $3 == g { print $1 }' "$work/fake/psql.log" 2> /dev/null | tr '\n' ' '; }
ncalls() { awk -v t="$1" '$2 == t' "$work/fake/psql.log" 2> /dev/null | wc -l | tr -d ' '; }
var() { sed -n "s/^$2=//p" "$work/fake/vars.$1" 2> /dev/null | head -n 1; }
requests() { cat "$work/fake/curl.log" 2> /dev/null | tr '\n' ';'; }
sleeps() { cat "$work/fake/sleeps" 2> /dev/null | tr '\n' ' '; }
shown() { printf '%s\n' "$out" | grep -v '^::add-mask::'; }
# health <code>: what was written for it on the control plane (its last write).
health() {
  local n last=""
  for n in $(calls cp cp-record-health); do
    if [[ "$(var "$n" code)" == "$1" ]]; then last="$n"; fi
  done
  [[ -n "$last" ]] && var "$last" health
}
# h <code> <jq>: one thing about it.
h() { health "$1" | jq -r "$2"; }

# 1. Refused before anything is asked
fresh
run "no control plane" CLOVEERP_LIVE_DATABASE_URL= -- light
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* && ! -e "$work/fake/psql.log" ]]' "refused, and nothing read"
fresh
run "no mode" --
check '[[ $status -eq 2 && "$out" == *"light (every hour) or full"* && ! -e "$work/fake/psql.log" ]]' "refused, and nothing read"
fresh
run "a code that is not one" -- light "Acme!"
check '[[ $status -eq 2 && ! -e "$work/fake/psql.log" ]]' "refused, and nothing read"
fresh
answer cp cp-ready "false false"
run "no register yet" -- light
check '[[ $status -eq 0 && "$out" == *"no register of deployments yet"* && -z "$(calls cp cp-clients)" ]]' "nothing to poll, and said"

# 2. The hourly poll
fresh
run "the hourly poll" -- light
check '[[ $status -eq 0 && "$(calls cp cp-record-health)" != "" ]]' "succeeds, and writes the client's health on the control plane"
check '[[ "$(h acme .release_sha)" == "$SHA" && "$(h acme ".database_bytes | type")" == number && "$(h acme .database_bytes)" == 123456789 ]]' \
      "its newest proved release, and its size in bytes, a number"
check '[[ "$(h acme .last_drain_pass_at)" == 2026-10-08T12:00:00Z && "$(h acme .open_support_windows)" == 1 && "$(h acme ".open_support_windows | type")" == number ]]' \
      "its last drain pass, and how many support windows are open"
check '[[ "$(h acme .staff_in_step)" == true ]]' "its staff in step with the control plane's, whatever order each is listed in"
check '[[ "$(h acme .backups_count)" == 2 && "$(h acme .backups_latest_at)" == 2026-10-08T02:00:09.000Z ]]' \
      "its completed backups: how many, and the newest (a failed one is not counted)"
check '[[ "$(h acme ".errors | length")" == 0 && "$(h acme .polled_at)" =~ ^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T ]]' "nothing missed, and when"
check '[[ -z "$(calls "$A" client-assurance)" && "$(h acme .assurance_failures)" == 2 && "$(h acme .assurance_at)" == 2026-10-08T03:07:40Z ]]' \
      "the assurance is not run hourly; the last full poll's figures are carried forward"
check '[[ "$(health acme | jq -r "keys | join(\",\")")" == "assurance_at,assurance_failures,backups_count,backups_latest_at,database_bytes,errors,last_drain_pass_at,open_support_windows,polled_at,release_sha,staff_in_step" ]]' \
      "and nothing but the register's health keys"
n=$(calls "$A" client-health | tr -d " ")
check '[[ "$(awk -v n="$n" '"'"'$1 == n { print $4 }'"'"' "$work/fake/psql.log")" == 0 ]]' \
      "every reading its own statement, so one that fails costs only itself"
check 'grep -q "set statement_timeout = :'"'"'timeout'"'"';" "$work/fake/sql.$n" && [[ "$(var "$n" timeout)" == 30s ]]' \
      "with a statement timeout (30s)"
check '[[ "$(requests)" == "GET https://api.example/v1/projects/${A}/database/backups;" && "$(cat "$work/fake/headers.1")" == *"Authorization: Bearer ${TOKEN}"* ]]' \
      "the backups asked of the Management API, once"
check '[[ "$out" == *"::add-mask::${URL_A}"* && "$(shown)" != *"$URL_A"* && "$(shown)" != *"pw-acme-rehearsal-secret"* && "$out" != *"$TOKEN"* ]]' \
      "the connection string masked and never printed; the token never printed"
check '[[ "$(cat "$work/fake/summary")" == *"| acme | 6f0bd91 | 2 not green | 117 MB | 2026-10-08T12:00:00Z | 1 | in step | 2, newest 2026-10-08T02:00:09.000Z |  |"* ]]' \
      "the run's summary has a row for it"

# 3. The daily poll
fresh
run "the daily poll" -- full
check '[[ $status -eq 0 && "$(h acme .assurance_failures)" == 1 && "$(h acme .assurance_at)" != 2026-10-08T03:07:40Z && "$(h acme .assurance_at)" =~ ^20 ]]' \
      "the assurance run, and its failures counted now"
n=$(calls "$A" client-assurance | tr -d " ")
check '[[ "$(var "$n" timeout)" == 5min ]] && grep -q "set statement_timeout = :'"'"'timeout'"'"';" "$work/fake/sql.$n"' \
      "with the assurance's own, longer timeout"
check '[[ "$out" == *"::warning::acme: 1 of 40 assurance check(s) not green: vat_agrees"* ]]' "the checks not green are named in a warning"
fresh
answer "$A" client-assurance 'ERROR:  canceling statement due to statement timeout'
run "an assurance that runs out of time" -- full
check '[[ $status -eq 0 && "$(h acme .assurance_failures)" == null && "$(h acme ".errors[0]")" == *"the assurance could not be run (ERROR: canceling statement due to statement timeout)"* ]]' \
      "said in errors, and no stale figure is written as today's"

# 4. What cannot be read is said, and the rest kept
fresh
answer "$A" client-health "kind${T}client
release_sha${T}${SHA}
database_bytes${T}123456789
ERROR:  relation \"erp_meta.drain_pass\" does not exist
open_support_windows${T}1
staff${T}${STAFF}"
run "one reading that fails" -- light
check '[[ $status -eq 0 && "$(h acme ".errors[0]")" == "last_drain_pass_at could not be read (ERROR: relation \"erp_meta.drain_pass\" does not exist)" ]]' \
      "that reading is named in errors, with what psql said"
check '[[ "$(h acme .last_drain_pass_at)" == null && "$(h acme .open_support_windows)" == 1 && "$(h acme .release_sha)" == "$SHA" ]]' "and every other reading kept"
check '[[ "$out" == *"::warning::acme: last_drain_pass_at could not be read"* ]]' "and a warning says so"
fresh
two_clients
mkdir -p "$work/fake/answers/$A"; echo "FATAL:  Tenant or user not found" > "$work/fake/answers/$A/CONNECT"
run "a client that cannot be reached" PAUSE_SECONDS=2 -- light
check '[[ $status -eq 0 && "$(h acme ".errors[0]")" == *"its database could not be reached or read"*"Tenant or user not found"* ]]' \
      "written all the same, with errors saying why"
check '[[ "$(h acme .database_bytes)" == null && "$(h acme .backups_count)" == 2 ]]' "no database reading, and the backups still read"
check '[[ "$(h beta .release_sha)" == "$SHA" && "$(sleeps)" == "2 " ]]' "and the next client polled all the same, after a pause"
fresh
two_clients
rm -f "$work/fake/vault/cloveerp_deployment_${A}_db_url"
run "no connection in the vault" -- light
check '[[ $status -eq 0 && "$(ncalls "$A")" -eq 0 && "$(h acme ".errors[0]")" == *"vault has no cloveerp:deployment:${A}:db_url"* && "$(h beta ".errors | length")" == 0 ]]' \
      "said in its errors, nothing asked of it, and the next client read"
fresh
vault "cloveerp:deployment:${A}:db_url" "postgresql://postgres.${A}:pw@pooler.example:5432/postgres?x=${DEMO}"
run "a connection naming the demonstration" -- light
check '[[ $status -eq 0 && "$(ncalls "$A")" -eq 0 && "$(h acme ".errors[0]")" == *"names another deployment"*"(${DEMO}), so it was not read"* ]]' \
      "never used"
fresh
answer "$A" client-health "kind${T}production
release_sha${T}${SHA}
database_bytes${T}999"
run "a database that is not a client's" -- light
check '[[ $status -eq 0 && "$(h acme .release_sha)" == null && "$(h acme .database_bytes)" == null && "$(h acme ".errors[0]")" == *"says it is the production deployment, not a client"* ]]' \
      "nothing it says is kept"
fresh
answer "$A" client-health "kind${T}client
staff${T}[\"owner@clove.example:owner\",\"stranger@example.com:operator\"]"
run "staff out of step" -- light
check '[[ "$(h acme .staff_in_step)" == false ]]' "said so"

# 5. The backups
fresh
run "no access token" SUPABASE_ACCESS_TOKEN= -- light
check '[[ $status -eq 0 && -z "$(requests)" && "$(h acme ".errors[0]")" == *"SUPABASE_ACCESS_TOKEN is not available"* && "$(h acme .release_sha)" == "$SHA" ]]' \
      "not asked for, said in errors, and everything else read"
fresh
run "a busy minute" "FAKE_HTTP_STATUSES=429,200" -- light
check '[[ $status -eq 0 && "$(sleeps)" == "5 " && "$(h acme .backups_count)" == 2 ]]' "waited out, as mapi waits"
fresh
run "an API that stays down" MAPI_ATTEMPTS=2 FAKE_HTTP_STATUS=503 -- light
check '[[ $status -eq 0 && "$(h acme .backups_count)" == null && "$(h acme ".errors[0]")" == *"the backups could not be read"*"503"* ]]' "said in errors"
fresh
two_clients
run "an API that stays down, with two clients" FAKE_HTTP_STATUS=503 -- light
check '[[ $status -eq 0 && "$(requests | grep -o "database/backups;" | wc -l | tr -d " ")" == 2 && "$(h beta ".errors[0]")" == *"did not answer for acme earlier in this poll"* && "$(h beta .release_sha)" == "$SHA" ]]' \
      "asked twice for the first client, not at all for the next, whose database is still read"
fresh
run "a new project with no backup yet" 'FAKE_BACKUPS={"backups":[]}' -- light
check '[[ "$(h acme .backups_count)" == 0 && "$(h acme .backups_latest_at)" == null && "$(h acme ".errors | length")" == 0 ]]' \
      "none counted, and nothing missed"

# 6. Before the control plane can keep it, and when it will not
fresh
answer cp cp-ready "true false"
run "a control plane a release behind" -- light
check '[[ $status -eq 0 && "$out" == *"::notice::the control plane has no erp_meta.record_deployment_health yet"* && -z "$(calls cp cp-record-health)" && "$out" == *"acme: {"* ]]' \
      "noted, said in the log, and written nowhere"
fresh
two_clients
answer cp cp-record-health 'ERROR:  CLOVEERP_DEPLOYMENT_UNKNOWN: no deployment acme'
run "a control plane that will not keep it" -- light
check '[[ $status -eq 1 && "$out" == *"::error::acme: its health could not be written on the control plane"* && "$(calls "$B" client-health)" != "" ]]' \
      "the run ends red, and every client is read all the same"

# 7. One client, by code
fresh
run "one client" -- light acme
check '[[ $status -eq 0 && "$(var "$(calls cp cp-clients | tr -d " ")" only)" == acme ]]' "only that client is asked for"
fresh
answer cp cp-clients '[]'
run "a client the register does not hold" -- light zed
check '[[ $status -eq 1 && "$out" == *"is not a built or live client"* ]]' "refused"
fresh
answer cp cp-clients '[]'
run "no built client" -- light
check '[[ $status -eq 0 && "$out" == *"no built or live client"* ]]' "nothing to poll, and said"

# 8. Off a runner nothing is masked, because nothing is printed
fresh
run "outside a runner" GITHUB_ACTIONS= -- light
check '[[ $status -eq 0 && "$out" != *"::add-mask::"* && "$out" != *"$URL_A"* ]]' "no mask line, and no connection string"

echo "$CASES checks over the fleet's poll, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
