#!/usr/bin/env bash
#
# supabase/ci/fleet_staff_sync.sh, rehearsed with no database and no API.
#
# The sync runs every hour against every client's own project, and what it
# does there is grant and remove the platform's ranks: a mistake in it would
# be learned as somebody let into a client's console, or the console's owner
# shut out of it. So every build runs it here first, against a psql that
# answers from files (by which database was asked and which statement) and a
# curl that stands in for each project's admin API, and writes down what it
# was asked: what it refuses before touching anything, that the control
# plane's list is followed (added, re-ranked, removed), that a sign-in is
# made only where there is none and only confirmed, that removals come after
# additions and the last owner's refusal is reported and the rest kept, that
# one client's trouble never stops the next, that every statement on a
# client carries a timeout, and that no connection string, key or password
# is ever printed. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_staff_sync.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── A psql that answers from files ───────────────────────────────────────────
# The database is the control plane ($FAKE_CP_URL) or the client whose ref the
# connection string names; the statement is its "-- fleet: <tag>" line, or,
# for fleet_register.sh's, its words. The answer is
# $FAKE_DIR/answers/<database>/<tag>.<email>, <tag>#<nth call>, or <tag>;
# a line of it starting ERROR: is said on stderr and, with ON_ERROR_STOP,
# stops there (exit 3). answers/<database>/CONNECT is a database that cannot
# be reached (exit 2). The vault is $FAKE_DIR/vault/<name, : as _>.
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
case "$tag" in
  vault-get)
    name=$(var name)
    if [[ -f "$FAKE_DIR/vault/${name//:/_}" ]]; then cat "$FAKE_DIR/vault/${name//:/_}"; fi
    exit 0 ;;
  event)
    printf '%s|%s|%s|%s\n' "$(var code)" "$(var phase)" "$(var status)" "$(var detail)" >> "$FAKE_DIR/events"
    if [[ -n "${FAKE_EVENT_FAILS:-}" ]]; then echo "psql:<stdin>:1: ERROR:  the register refused" >&2; exit 3; fi
    echo 1
    exit 0 ;;
esac
k=$(( $(cat "$FAKE_DIR/count.$target.$tag" 2> /dev/null || echo 0) + 1 ))
echo "$k" > "$FAKE_DIR/count.$target.$tag"
email=$(var email)
file=""
for f in ${email:+"$dir/$tag.$email"} "$dir/$tag#$k" "$dir/$tag"; do
  if [[ -f "$f" ]]; then file="$f"; break; fi
done
[[ -n "$file" ]] || exit 0
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == ERROR:* ]]; then
    echo "psql:<stdin>:3: $line" >&2
    if [[ "$stop" == 1 ]]; then exit 3; fi
  else
    printf '%s\n' "$line"
  fi
done < "$file"
exit 0
FAKE
chmod +x "$work/psql"

# ── And a project's admin API, as patient_request asks it ────────────────────
cat > "$work/curl" <<'FAKE'
#!/usr/bin/env bash
method=GET; url=""; body=""; want_status=no; headers=""; dump=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|-d) body="$2"; shift 2 ;;
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
printf '%s' "$body" > "$FAKE_DIR/body.$n"
printf '%s' "$headers" > "$FAKE_DIR/headers.$n"
status="${FAKE_HTTP_STATUS:-200}"
if [[ -n "${FAKE_HTTP_STATUSES:-}" ]]; then
  IFS=',' read -r -a seq <<< "$FAKE_HTTP_STATUSES"
  i=$(( n - 1 ))
  (( i < ${#seq[@]} )) || i=$(( ${#seq[@]} - 1 ))
  status="${seq[$i]}"
fi
path="${url#*//*/}"
made_id="${FAKE_ADMIN_ID:-99999999-9999-4999-8999-999999999999}"
refused='{"msg":"refused"}'
case "$method $path" in
  "POST auth/v1/admin/users")
    if [[ "$status" =~ ^2 ]]; then
      answer="{\"id\":\"${made_id}\",\"email\":\"x\",\"email_confirmed_at\":\"2026-10-08T00:00:00Z\"}"
    else
      answer="${FAKE_ADMIN_BODY:-$refused}"
    fi ;;
  *) answer='{}' ;;
esac
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

# ── The fleet the rehearsal keeps ────────────────────────────────────────────
CP="postgresql://control-plane"
A=aaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbb
PROD=xpzffnnhnhcqyjqcueja
DEMO=dddddddddddddddddddd
URL_A="postgresql://postgres.${A}:pw-acme-rehearsal-secret@pooler.example:5432/postgres"
URL_B="postgresql://postgres.${B}:pw-beta-rehearsal-secret@pooler.example:5432/postgres"
KEY_A="sb_secret_acme_rehearsal_key"
U_OWNER=11111111-1111-4111-8111-111111111111
U_OPS=22222222-2222-4222-8222-222222222222
U_GONE=33333333-3333-4333-8333-333333333333
U_MADE=99999999-9999-4999-8999-999999999999
CP_STAFF='[{"email":"owner@clove.example","name":"Olu Owner","role":"owner"},{"email":"ops@clove.example","name":"Ops Person","role":"operator"},{"email":"new@clove.example","name":"New Person","role":"support"}]'
CLIENT_STAFF="{\"staff\":[{\"email\":\"gone@clove.example\",\"role\":\"operator\",\"name\":\"Gone\",\"uid\":\"${U_GONE}\"},{\"email\":\"ops@clove.example\",\"role\":\"support\",\"name\":\"Ops Person\",\"uid\":\"${U_OPS}\"},{\"email\":\"owner@clove.example\",\"role\":\"owner\",\"name\":\"Olu Owner\",\"uid\":\"${U_OWNER}\"}],\"users\":[{\"email\":\"owner@clove.example\",\"id\":\"${U_OWNER}\",\"confirmed\":true},{\"email\":\"ops@clove.example\",\"id\":\"${U_OPS}\",\"confirmed\":true}]}"

answer() { mkdir -p "$work/fake/answers/$1"; printf '%s\n' "$3" > "$work/fake/answers/$1/$2"; }
vault() { mkdir -p "$work/fake/vault"; printf '%s' "$2" > "$work/fake/vault/${1//:/_}"; }
fresh() {
  rm -rf "$work/fake"; mkdir -p "$work/fake"
  answer cp cp-ready "true"
  answer cp cp-staff "$CP_STAFF"
  answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${A}\",\"api_url\":\"https://${A}.supabase.co\"}]"
  answer cp cp-refs "${A},${B}"
  vault "cloveerp:deployment:${A}:db_url" "$URL_A"
  vault "cloveerp:deployment:${A}:service_key" "$KEY_A"
  vault "cloveerp:deployment:${B}:db_url" "$URL_B"
  vault "cloveerp:deployment:${B}:service_key" "sb_secret_beta_rehearsal_key"
  answer "$A" client-state "client true true"
  answer "$A" client-staff "$CLIENT_STAFF"
  answer "$A" client-add '{"changed":true}'
  answer "$A" client-add.owner@clove.example '{"changed":false}'
  answer "$A" client-revoke '{"revoked":true,"changed":true}'
  answer "$B" client-state "client true true"
  answer "$B" client-staff '{"staff":[],"users":[]}'
  answer "$B" client-add '{"changed":true}'
}

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...] -- [code]: the script against the fakes as
  # they stand; its exit and everything it said.
  local name="$1"; shift
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  out=$(env FAKE_DIR="$work/fake" FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" \
          PSQL="$work/psql" CURL="$work/curl" FLEET_SLEEP="$work/sleep" MAPI_SLEEP="$work/sleep" \
          PAUSE_SECONDS=0 GITHUB_ACTIONS=true GITHUB_RUN_ID=4242 GITHUB_STEP_SUMMARY="$work/fake/summary" \
          PLATFORM_OWNER_EMAIL=" Owner@Clove.example " \
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
# The calls made to one database for one statement, in order: their numbers.
calls() { awk -v t="$1" -v g="$2" '$2 == t && $3 == g { print $1 }' "$work/fake/psql.log" 2> /dev/null | tr '\n' ' '; }
ncalls() { awk -v t="$1" '$2 == t' "$work/fake/psql.log" 2> /dev/null | wc -l | tr -d ' '; }
var() { sed -n "s/^$2=//p" "$work/fake/vars.$1" 2> /dev/null | head -n 1; }
# The addresses each call of a statement was made for, in order.
emails_of() { local n; for n in $(calls "$1" "$2"); do printf '%s ' "$(var "$n" email)"; done; }
events() { cat "$work/fake/events" 2> /dev/null; }
requests() { cat "$work/fake/curl.log" 2> /dev/null | tr '\n' ';'; }
sleeps() { cat "$work/fake/sleeps" 2> /dev/null | tr '\n' ' '; }
# Every line that is not a mask: what a log would show.
shown() { printf '%s\n' "$out" | grep -v '^::add-mask::'; }
# Every statement asked of one database stops at its first error.
stops_at_first_error() { [[ -z "$(awk -v t="$1" '$2 == t && $4 != 1' "$work/fake/psql.log")" ]]; }
# masked_first <value> <word>: the value's mask is printed before any other
# line that names <word>.
masked_first() {
  local m w
  m=$(printf '%s\n' "$out" | grep -n -F -x "::add-mask::$1" | head -n 1 | cut -d: -f1)
  w=$(printf '%s\n' "$out" | grep -n -F "$2" | grep -v '^[0-9]*:::add-mask::' | head -n 1 | cut -d: -f1)
  [[ -n "$m" && ( -z "$w" || "$m" -lt "$w" ) ]]
}
# The words the script writes, with their apostrophes.
LIST="the control plane's list"
REASON="Not on the control plane's staff list (fleet_sync.yml, run 4242)."
NOT_ON="is not on the control plane's list and could not be removed there"

# 1. Refused before anything is asked
fresh
run "no control plane" CLOVEERP_LIVE_DATABASE_URL= --
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* && ! -e "$work/fake/psql.log" ]]' "refused, and nothing read"
fresh
run "a code that is not one" -- "Acme!"
check '[[ $status -eq 2 && "$out" == *"is not a client"* && ! -e "$work/fake/psql.log" ]]' "refused, and nothing read"

# 2. A control plane list that cannot be right
fresh
answer cp cp-staff '[{"email":"ops@clove.example","name":"Ops","role":"operator"}]'
run "a control plane list without an owner" --
check '[[ $status -eq 1 && "$out" == *"has no owner"* && "$(ncalls "$A")" -eq 0 && -z "$(events)" ]]' \
      "nothing done on any client, rather than remove everybody everywhere"
fresh
answer cp cp-staff '[]'
run "an empty control plane list" --
check '[[ $status -eq 1 && "$out" == *"has no owner (0 active"* && "$(ncalls "$A")" -eq 0 ]]' "nothing done on any client"
fresh
answer cp cp-staff '[{"email":"other@clove.example","name":"Other","role":"owner"},{"email":"owner@clove.example","name":"Olu Owner","role":"administrator"}]'
run "a list that demotes the platform's owner" --
check '[[ $status -eq 1 && "$out" == *"does not make the platform"*"s owner (CLOVEERP_PLATFORM_OWNER_EMAIL, o…@clove.example) an owner"* && "$(ncalls "$A")" -eq 0 && -z "$(events)" ]]' \
      "nothing done on any client: every client's next release would have stopped"
fresh
answer cp cp-staff '[{"email":"other@clove.example","name":"Other","role":"owner"}]'
run "a list without the platform's owner" --
check '[[ $status -eq 1 && "$(ncalls "$A")" -eq 0 ]]' "nothing done on any client"
fresh
answer cp cp-staff '[{"email":"other@clove.example","name":"Other","role":"owner"}]'
answer "$A" client-staff '{"staff":[],"users":[]}'
run "no platform owner named" PLATFORM_OWNER_EMAIL= --
check '[[ $status -eq 0 && "$(emails_of "$A" client-add)" == "other@clove.example " ]]' "without the variable, the list is followed as it is"
fresh
answer cp cp-ready "false"
run "no register yet" --
check '[[ $status -eq 0 && "$out" == *"no register of deployments yet"* && "$(calls cp cp-staff)" == "" ]]' "nothing to keep, and said"
fresh
answer cp cp-clients '[]'
run "no built client" --
check '[[ $status -eq 0 && "$out" == *"no client in the register has a database that is up"* && "$(ncalls "$A")" -eq 0 ]]' "nothing to keep, and said"
fresh
mkdir -p "$work/fake/answers/cp"; echo "FATAL:  password authentication failed" > "$work/fake/answers/cp/CONNECT"
run "a control plane that cannot be reached" --
check '[[ $status -eq 1 && "$out" == *"the control plane could not be read"* && "$out" == *"password authentication failed"* ]]' "refused, saying why"

# 3. A client kept as the control plane's list says
fresh
run "a client one behind" --
check '[[ $status -eq 0 ]]' "succeeds"
check '[[ "$(emails_of "$A" client-add)" == "owner@clove.example ops@clove.example new@clove.example " ]]' \
      "every member of the control plane's staff kept there, in the control plane's order (owners first)"
check 'grep -q "order by erp_meta.platform_rank(s.staff_role) desc" "$work/fake/sql.$(calls cp cp-staff | tr -d " ")"' \
      "the control plane's list is read owners first"
n_new=$(calls "$A" client-add | awk "{print \$3}")
check '[[ "$(var "$n_new" uid)" == "$U_MADE" && "$(var "$n_new" role)" == support && "$(var "$n_new" name)" == "New Person" ]]' \
      "the newcomer bound to the sign-in made for them, at the control plane's rank and name"
n_ops=$(calls "$A" client-add | awk "{print \$2}")
check '[[ "$(var "$n_ops" uid)" == "$U_OPS" && "$(var "$n_ops" role)" == operator ]]' \
      "a member already there is re-ranked, bound to the sign-in they already have"
check '[[ "$(requests)" == "POST https://${A}.supabase.co/auth/v1/admin/users;" ]]' \
      "one sign-in made, for the one member who had none, on the client's own auth API"
check '[[ "$(jq -r .email "$work/fake/body.1")" == new@clove.example && "$(jq -r .email_confirm "$work/fake/body.1")" == true ]]' \
      "confirmed, for the newcomer's address"
pw=$(jq -r .password "$work/fake/body.1")
check '[[ ${#pw} -ge 12 && "$pw" =~ [a-z] && "$pw" =~ [A-Z] && "$pw" =~ [0-9] ]]' "with a password that meets the project's rule"
check '[[ "$out" != *"$pw"* ]]' "and the password is never printed"
check '[[ "$(cat "$work/fake/headers.1")" == *"apikey: ${KEY_A}"* && "$(cat "$work/fake/headers.1")" != *"Authorization"* ]]' \
      "the new-format secret key goes as apikey only, never as a bearer"
check '[[ "$(emails_of "$A" client-revoke)" == "gone@clove.example " ]]' "the one the control plane no longer names is removed"
n_rev=$(calls "$A" client-revoke | tr -d " ")
check '[[ "$(var "$n_rev" reason)" == "$REASON" ]]' "with a reason naming the run"
check '[[ "$n_rev" -gt "$n_new" ]]' "after every addition, so a new owner is there before an old one goes"
check '[[ "$(events)" == "acme|note|note|staff kept as $LIST: 1 added, 1 changed, 1 removed" ]]' \
      "written on its row in the register: how many added, changed and removed"
bad=""
for n in $(awk -v t="$A" '$2 == t && $3 ~ /^client-/ { print $1 }' "$work/fake/psql.log"); do
  if ! grep -q "set statement_timeout = :'timeout';" "$work/fake/sql.$n" || [[ "$(var "$n" timeout)" != 30s ]]; then
    bad="$bad $n"
  fi
done
check '[[ -z "$bad" && "$(ncalls "$A")" -ge 6 ]]' "every statement on the client sets its statement timeout (30s)"
check 'stops_at_first_error "$A"' "every statement on the client stops at its first error"
check 'masked_first "$URL_A" acme' "its connection string is masked before anything about it is said"
check '[[ "$(shown)" != *"$URL_A"* && "$(shown)" != *"pw-acme-rehearsal-secret"* ]]' "and is never printed"
check '[[ "$out" == *"::add-mask::${KEY_A}"* && "$(shown)" != *"$KEY_A"* ]]' "its secret key is masked, and never printed"
check '[[ "$(cat "$work/fake/summary")" == *"| acme | 1 | 1 | 1 |  |"* ]]' "the run's summary says what was done"

fresh
vault "cloveerp:deployment:${A}:service_key" "eyJlegacy.service.jwt"
run "a legacy service key" --
check '[[ $status -eq 0 && "$(cat "$work/fake/headers.1")" == *"Authorization: Bearer eyJlegacy.service.jwt"* && "$(shown)" != *"eyJlegacy.service.jwt"* ]]' \
      "a legacy key, a JWT, goes as a bearer too, and is never printed"

fresh
answer "$A" client-staff "{\"staff\":[{\"email\":\"owner@clove.example\",\"role\":\"owner\",\"name\":\"Olu Owner\",\"uid\":\"${U_OWNER}\"}],\"users\":[{\"email\":\"owner@clove.example\",\"id\":\"${U_OWNER}\",\"confirmed\":true},{\"email\":\"ops@clove.example\",\"id\":\"${U_OPS}\",\"confirmed\":true},{\"email\":\"new@clove.example\",\"id\":\"${U_MADE}\",\"confirmed\":true}]}"
answer "$A" client-add '{"changed":false}'
run "a client already in step" --
check '[[ $status -eq 0 && -z "$(requests)" && -z "$(calls "$A" client-revoke)" && -z "$(events)" ]]' \
      "nothing made, nothing removed, and nothing written in the register"
check '[[ "$out" == *"acme: 0 added, 0 changed, 0 removed, 3 already in step"* ]]' "and says it was in step"

# 4. The last owner, and one client's trouble never stops the next
fresh
answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${A}\",\"api_url\":\"https://${A}.supabase.co\"},{\"code\":\"beta\",\"ref\":\"${B}\",\"api_url\":\"https://${B}.supabase.co\"}]"
answer "$A" client-revoke 'ERROR:  CLOVEERP_LAST_OWNER: gone@clove.example is the only owner here, and the platform would have no owner'
run "the last owner" PAUSE_SECONDS=3 --
check '[[ $status -eq 1 && "$out" == *"::error::acme: g…@clove.example $NOT_ON (ERROR: CLOVEERP_LAST_OWNER"* ]]' \
      "reported in plain words, naming the refusal"
check '[[ "$(emails_of "$A" client-add)" == "owner@clove.example ops@clove.example new@clove.example " ]]' "everything else on that client kept"
check '[[ "$(emails_of "$B" client-add)" == "owner@clove.example ops@clove.example new@clove.example " ]]' "and the next client kept all the same"
check '[[ "$(events)" == *"acme|note|failed|staff kept as $LIST: 1 added, 1 changed, 0 removed; not done: g…@clove.example"* && "$(events)" == *"beta|note|note|staff kept as $LIST: 3 added, 0 changed, 0 removed"* ]]' \
      "each written on its own row, the trouble as a failure"
check '[[ "$(sleeps)" == "3 " ]]' "one client at a time, with a pause between them"
check '[[ "$out" == *"1 of 2 client(s) could not be made to match"* ]]' "the run ends red, saying how many"

check '[[ "$(shown)" != *"gone@clove.example"* && "$(events)" != *"gone@clove.example"* && "$out" == *"::add-mask::gone@clove.example"* ]]' "no person's full address in what the log shows or in the register's note, and the address masked"
fresh
answer cp cp-last-note "failed staff kept as $LIST: 1 added, 1 changed, 0 removed; not done: g…@clove.example $NOT_ON (ERROR: CLOVEERP_LAST_OWNER: g…@clove.example is the only owner here, and the platform would have no owner)"
answer "$A" client-revoke 'ERROR:  CLOVEERP_LAST_OWNER: gone@clove.example is the only owner here, and the platform would have no owner'
run "the same trouble an hour later" --
check '[[ $status -eq 1 && -z "$(events)" && "$out" == *"the register already says so"* ]]' "not written twice in a row"

# 5. A connection that is not the client's is never used
fresh
answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${A}\",\"api_url\":\"https://${A}.supabase.co\"},{\"code\":\"beta\",\"ref\":\"${B}\",\"api_url\":\"https://${B}.supabase.co\"}]"
rm -f "$work/fake/vault/cloveerp_deployment_${A}_db_url"
run "no connection in the vault" --
check '[[ $status -eq 1 && "$out" == *"vault has no cloveerp:deployment:${A}:db_url"* && "$(ncalls "$A")" -eq 0 ]]' "said, and nothing asked of it"
check '[[ "$(emails_of "$B" client-add)" == "owner@clove.example ops@clove.example new@clove.example " ]]' "the next client kept all the same"
fresh
vault "cloveerp:deployment:${A}:db_url" "postgresql://postgres.${A}:pw@pooler.example:5432/postgres?options=${PROD}"
run "a connection naming production" --
check '[[ $status -eq 1 && "$out" == *"names another deployment"*"s project (${PROD})"* && "$(ncalls "$A")" -eq 0 && -z "$(requests)" ]]' \
      "refused before it is used"
fresh
vault "cloveerp:deployment:${A}:db_url" "$URL_B"
run "a connection naming another client" --
check '[[ $status -eq 1 && "$out" == *"does not name its project (${A})"* && "$(ncalls "$B")" -eq 0 ]]' "refused before it is used"
fresh
answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${A}\",\"api_url\":\"https://elsewhere.example\"}]"
run "an auth API that is not the project's" --
check '[[ $status -eq 1 && "$out" == *"is not its project"* && "$(ncalls "$A")" -eq 0 && -z "$(requests)" ]]' \
      "its secret key is never sent there, and nothing is changed"
fresh
answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${A}\",\"api_url\":\"https://${A}.elsewhere.example\"}]"
run "an auth API whose host only contains the ref" --
check '[[ $status -eq 1 && "$out" == *"is not its project"* && -z "$(requests)" ]]' "not sent there either"
fresh
answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${A}\",\"api_url\":\"\"}]"
run "a register with no auth API address" --
check '[[ $status -eq 0 && "$(requests)" == "POST https://${A}.supabase.co/auth/v1/admin/users;" ]]' "its own project's, by its ref"
fresh
answer "$A" client-state "production true true"
run "a database that says it is production" --
check '[[ $status -eq 1 && "$out" == *"says it is the production deployment, not a client"* && -z "$(calls "$A" client-add)$(calls "$A" client-revoke)" ]]' \
      "refused, and nothing changed on it"
fresh
mkdir -p "$work/fake/answers/$A"; echo "FATAL:  Tenant or user not found" > "$work/fake/answers/$A/CONNECT"
run "a client that cannot be reached" --
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database could not be reached or read"* && "$out" == *"Tenant or user not found"* ]]' "said, with what psql said"
check '[[ "$(events)" == "acme|note|failed|"*"could not be reached"* ]]' "and written on its row"

# 6. A client not yet released the routines
fresh
answer "$A" client-state "client false false"
run "a client a release behind" --
check '[[ $status -eq 0 && "$out" == *"::notice::acme has not yet been released the routines that keep its staff"* && -z "$(calls "$A" client-add)$(calls "$A" client-staff)" && -z "$(events)" ]]' \
      "noted and left for the next train, nothing asked of it"

# 7. Sign-ins: never two, never unconfirmed, a busy minute waited out
fresh
answer "$A" client-staff "{\"staff\":[],\"users\":[{\"email\":\"owner@clove.example\",\"id\":\"${U_OWNER}\",\"confirmed\":true},{\"email\":\"ops@clove.example\",\"id\":\"${U_OPS}\",\"confirmed\":true},{\"email\":\"new@clove.example\",\"id\":\"${U_GONE}\",\"confirmed\":false}]}"
run "a sign-in that is not confirmed" --
check '[[ $status -eq 1 && "$out" == *"n…@clove.example has a sign-in there that is not confirmed"* && -z "$(requests)" ]]' \
      "not bound, not made again, and said"
check '[[ "$(emails_of "$A" client-add)" == "owner@clove.example ops@clove.example " ]]' "everyone else kept"
fresh
answer "$A" client-staff "{\"staff\":[],\"users\":[{\"email\":\"owner@clove.example\",\"id\":\"${U_OWNER}\",\"confirmed\":true},{\"email\":\"ops@clove.example\",\"id\":\"${U_OPS}\",\"confirmed\":true},{\"email\":\"ops@clove.example\",\"id\":\"${U_GONE}\",\"confirmed\":true}]}"
run "two confirmed sign-ins for one address" --
check '[[ $status -eq 1 && "$out" == *"o…@clove.example has more than one confirmed sign-in there"* && "$(emails_of "$A" client-add)" != *"ops@"* ]]' \
      "neither is bound, and it is said"
fresh
answer "$A" client-staff "{\"staff\":[{\"email\":\"ops@clove.example\",\"role\":\"support\",\"name\":\"Ops\",\"uid\":\"${U_GONE}\"}],\"users\":[{\"email\":\"owner@clove.example\",\"id\":\"${U_OWNER}\",\"confirmed\":true},{\"email\":\"ops@clove.example\",\"id\":\"${U_OPS}\",\"confirmed\":true},{\"email\":\"ops@clove.example\",\"id\":\"${U_GONE}\",\"confirmed\":true},{\"email\":\"new@clove.example\",\"id\":\"${U_MADE}\",\"confirmed\":true}]}"
run "two confirmed sign-ins, one of them already bound" --
n_ops=$(calls "$A" client-add | awk "{print \$2}")
check '[[ $status -eq 0 && "$(var "$n_ops" uid)" == "$U_GONE" ]]' "the one it is bound to is kept"
fresh
answer "$A" client-user "$U_MADE"
run "a sign-in made meanwhile" FAKE_HTTP_STATUSES=422 'FAKE_ADMIN_BODY={"code":"email_exists","msg":"A user with this email address has already been registered"}' --
n_new=$(calls "$A" client-add | awk "{print \$3}")
check '[[ $status -eq 0 && "$(var "$n_new" uid)" == "$U_MADE" && -n "$(calls "$A" client-user)" ]]' "read again and bound, not refused"
fresh
run "a busy admin API" "FAKE_HTTP_STATUSES=429,200" --
check '[[ $status -eq 0 && "$(sleeps)" == "5 " && "$(requests)" == "POST https://${A}.supabase.co/auth/v1/admin/users;POST https://${A}.supabase.co/auth/v1/admin/users;" ]]' \
      "asked again after a pause, as mapi asks"
check '[[ "$out" == *"answered 429 on attempt 1 of 5"* ]]' "and says it waited"
fresh
run "an admin API that refuses" FAKE_HTTP_STATUS=401 --
check '[[ $status -eq 1 && "$out" == *"a sign-in for n…@clove.example could not be made there"* && "$out" == *"answered 401"* && "$(requests)" == "POST https://${A}.supabase.co/auth/v1/admin/users;" ]]' \
      "said, and a 401 is never asked again"
check '[[ "$(emails_of "$A" client-add)" == "owner@clove.example ops@clove.example " && "$(emails_of "$A" client-revoke)" == "gone@clove.example " ]]' "everyone else kept"
fresh
rm -f "$work/fake/vault/cloveerp_deployment_${A}_service_key"
run "no secret key in the vault" --
check '[[ $status -eq 1 && "$out" == *"no cloveerp:deployment:${A}:service_key to make one with"* && -z "$(requests)" ]]' "said, and nothing sent"
fresh
answer "$A" client-add.ops@clove.example 'ERROR:  CLOVEERP_PLATFORM_STAFF_SIGN_IN_UNKNOWN: that sign-in is already bound to another member of staff, x@clove.example'
run "a refusal from the routine" --
check '[[ $status -eq 1 && "$out" == *"o…@clove.example could not be kept as operator (ERROR: CLOVEERP_PLATFORM_STAFF_SIGN_IN_UNKNOWN"* && "$(emails_of "$A" client-add)" == *"new@clove.example"* ]]' \
      "said in its own words, and the rest kept"
fresh
answer "$A" client-staff 'ERROR:  canceling statement due to statement timeout'
run "a staff list that times out" --
check '[[ $status -eq 1 && "$out" == *"its staff list could not be read (ERROR: canceling statement due to statement timeout)"* && -z "$(calls "$A" client-add)" ]]' \
      "said, and nothing changed on it"

# 8. One client, by code
fresh
run "one client" -- acme
check '[[ $status -eq 0 && "$(var "$(calls cp cp-clients | tr -d " ")" only)" == acme ]]' "only that client is asked for"
check 'grep -qF "d.status in ('"'"'built'"'"', '"'"'live'"'"', '"'"'suspended'"'"', '"'"'retiring'"'"')" "$work/fake/sql.$(calls cp cp-clients | tr -d " ")"' \
      "every client whose database is up: support may need to enter a suspended one"
fresh
answer cp cp-clients '[]'
answer cp cp-status 'retired'
run "a retired client" -- acme
check '[[ $status -eq 0 && "$out" == *"::notice::acme is retired"* && "$(ncalls "$A")" -eq 0 ]]' "noted, nothing done"
fresh
answer cp cp-clients '[]'
run "a client the register does not hold" -- zed
check '[[ $status -eq 1 && "$out" == *"zed"*" is not in the control plane"*"s register"* && "$(ncalls "$A")" -eq 0 ]]' "refused"

# 9. Off a runner nothing is masked, because nothing is printed
fresh
run "outside a runner" GITHUB_ACTIONS= --
check '[[ $status -eq 0 && "$out" != *"::add-mask::"* && "$out" != *"$URL_A"* && "$out" != *"$KEY_A"* ]]' \
      "no mask line, and no connection string or key"

# 10. The register refusing the note
fresh
run "a note the register refuses" FAKE_EVENT_FAILS=yes --
check '[[ $status -eq 0 && "$out" == *"::warning::acme: what was done could not be written in the control plane"* ]]' \
      "a warning; the staff were kept all the same"

echo "$CASES checks over the fleet's staff sync, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
