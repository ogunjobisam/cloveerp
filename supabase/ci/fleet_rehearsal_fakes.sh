#!/usr/bin/env bash
#
# Stand-ins for the commands the lifecycle scripts run, for their rehearsals
# (fleet_rename_rehearsal.sh, fleet_export_rehearsal.sh,
# fleet_backup_rehearsal.sh, fleet_status_sync_rehearsal.sh,
# fleet_busy_rehearsal.sh). Sourced, never run:
#
#   . supabase/ci/fleet_rehearsal_fakes.sh
#   fleet_fakes "$work"      # writes psql, curl, pg_dump, age, aws, sleep, gh
#
# Each writes what it was asked, in order, to $FAKE_DIR/order.log, and
# answers from files and the environment:
#
#   psql      The database from the connection string ($FAKE_CP_URL is cp,
#             $FAKE_DEMO_URL is demo, a pooler user postgres.<ref> is <ref>),
#             the statement from its "-- fleet: <tag>" line (vault reads and
#             events from fleet_register.sh by what they say). The answer is
#             $FAKE_DIR/answers/<database>/<tag>@<code> for a statement given
#             that code (-v code=...), else <tag>#<nth call> or <tag>; a line
#             starting ERROR: goes to stderr and, with ON_ERROR_STOP, stops
#             there (exit 3); a file CONNECT in the database's directory is a
#             database that cannot be reached (exit 2). Vault entries are
#             $FAKE_DIR/vault/<name, : as _>; events are appended to
#             $FAKE_DIR/events as code|phase|status|detail. -c is refused:
#             psql substitutes :'name' only on standard input.
#   curl      The Management API as mapi asks it: auth settings kept as
#             patched, PostgREST, secrets kept as set ($FAKE_DIR/secrets.held,
#             a JSON object of name to value) and listed as the API lists
#             them, each with the SHA-256 of its value. FAKE_HTTP_STATUSES is
#             a status per call; FAKE_AUTH_PATCH_STATUSES,
#             FAKE_SECRETS_STATUSES and FAKE_SECRETS_LIST_STATUSES per call
#             to that endpoint alone; FAKE_AUTH answers the auth GET, and
#             FAKE_SECRETS_LIST the secrets' GET.
#             And a project's Storage API (https://<ref>.supabase.co): a
#             bucket is $FAKE_DIR/storage/<ref>/<bucket>/, listed a folder at
#             a time as Storage lists it and fetched into -o; a bucket with
#             no directory answers 400, Bucket not found.
#             FAKE_STORAGE_LIST_STATUSES and FAKE_STORAGE_FETCH_STATUSES are
#             a status per call to each; FAKE_STORAGE_GONE is an object
#             listed and then not found. Each call's headers are kept in
#             $FAKE_DIR/headers.<n>.
#   gh        gh api, as fleet_busy.sh asks it: the answer to a path is
#             $FAKE_DIR/gh/<path after actions/, / as _>.json (gh_run,
#             gh_job), filtered by --jq; none is no runs and no jobs.
#             FAKE_GH_FAIL makes it fail.
#   pg_dump  Writes a small file naming what it dumped, from where.
#             FAKE_PG_DUMP_FAIL="<database> <schemas|auth.users>" fails it,
#             with an error that carries the connection string.
#   age       Writes the archive behind a header naming the recipient, and
#             keeps the archive's member list and manifest for the checks.
#             FAKE_AGE_FAIL fails it.
#   aws       A bucket in $FAKE_DIR/s3/<bucket>/<key>: s3 cp, s3 rm, s3api
#             head-object and list-objects-v2. Refuses unless the key and
#             secret in its environment are FAKE_EXPECT_KEY_ID and
#             FAKE_EXPECT_SECRET. FAKE_AWS_CP_FAIL, FAKE_AWS_LIST_FAIL,
#             FAKE_AWS_RM_FAIL and FAKE_HEAD_BYTES make it misbehave.
#   sleep     Says how long it would have slept.
#
# And workflow_step <workflow file> <step name>, which prints the run: block
# of that step as the runner would be given it, for a rehearsal to run a
# workflow's own words against these stand-ins.
#
# bash 3.2 and 5.

fleet_fakes() {
  local dir="$1"

  cat > "$dir/psql" <<'FAKE'
#!/usr/bin/env bash
conn=""; vars=""; stop=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v)
      case "$2" in
        ON_ERROR_STOP=*) stop="${2#ON_ERROR_STOP=}" ;;
        *) vars="${vars}${2}"$'\n' ;;
      esac
      shift 2 ;;
    -c|-tAc) echo "the rehearsal's psql was given -c, where psql never substitutes :'name'" >&2; exit 9 ;;
    -F) shift 2 ;;
    -*) shift ;;
    *) [[ -n "$conn" ]] || conn="$1"; shift ;;
  esac
done
sql=$(cat)
var() { printf '%s' "$vars" | sed -n "s/^$1=//p" | head -n 1; }
n=$(( $(cat "$FAKE_DIR/psql.calls" 2> /dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/psql.calls"
if [[ -n "${FAKE_CP_URL:-}" && "$conn" == "$FAKE_CP_URL" ]]; then
  target=cp
elif [[ -n "${FAKE_DEMO_URL:-}" && "$conn" == "$FAKE_DEMO_URL" ]]; then
  target=demo
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
echo "$n $target $tag" >> "$FAKE_DIR/psql.log"
dir="$FAKE_DIR/answers/$target"
if [[ -e "$dir/CONNECT" ]]; then
  echo "psql: error: connection to server at \"pooler.example\" (192.0.2.1), port 5432 failed: $(cat "$dir/CONNECT")" >&2
  echo "psql $target $tag: cannot connect" >> "$FAKE_DIR/order.log"
  exit 2
fi
case "$tag" in
  vault-get)
    name=$(var name)
    echo "psql $target vault-get $name" >> "$FAKE_DIR/order.log"
    if [[ -f "$FAKE_DIR/vault/${name//:/_}" ]]; then cat "$FAKE_DIR/vault/${name//:/_}"; fi
    exit 0 ;;
  event)
    if [[ -f "$dir/event" ]] && grep -q '^ERROR:' "$dir/event"; then
      echo "psql:<stdin>:1: $(grep '^ERROR:' "$dir/event" | head -n 1)" >&2
      exit 3
    fi
    echo "event $(var code) $(var phase) $(var status)" >> "$FAKE_DIR/order.log"
    printf '%s|%s|%s|%s\n' "$(var code)" "$(var phase)" "$(var status)" "$(var detail)" >> "$FAKE_DIR/events"
    exit 0 ;;
esac
echo "psql $target $tag" >> "$FAKE_DIR/order.log"
k=$(( $(cat "$FAKE_DIR/count.$target.$tag" 2> /dev/null || echo 0) + 1 ))
echo "$k" > "$FAKE_DIR/count.$target.$tag"
code=$(var code)
file=""
for f in ${code:+"$dir/$tag@$code"} "$dir/$tag#$k" "$dir/$tag"; do
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

  cat > "$dir/curl" <<'FAKE'
#!/usr/bin/env bash
method=GET; url=""; body=""; want_status=no; dump=""; outfile=""; headers=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|-d) body="$2"; shift 2 ;;
    -w) want_status=yes; shift 2 ;;
    -D|--dump-header) dump="$2"; shift 2 ;;
    -o|--output) outfile="$2"; shift 2 ;;
    -H) headers="${headers}${2}"$'\n'; shift 2 ;;
    --max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
n=$(( $(cat "$FAKE_DIR/curl.calls" 2> /dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/curl.calls"
path="${url#*//*/}"
host="${url#*//}"; host="${host%%/*}"
echo "$method /$path" >> "$FAKE_DIR/order.log"
[[ -z "$body" ]] || printf '%s' "$body" > "$FAKE_DIR/body.$n"
printf '%s' "$headers" > "$FAKE_DIR/headers.$n"
# pick <list> <counter file>: the next of a comma list, the last repeated.
pick() {
  local list="$1" counter="$2" k i
  local -a seq
  k=$(( $(cat "$counter" 2> /dev/null || echo 0) + 1 ))
  echo "$k" > "$counter"
  IFS=',' read -r -a seq <<< "$list"
  i=$(( k - 1 ))
  (( i < ${#seq[@]} )) || i=$(( ${#seq[@]} - 1 ))
  printf '%s' "${seq[$i]}"
}
status=200
if [[ -n "${FAKE_HTTP_STATUSES:-}" ]]; then status=$(pick "$FAKE_HTTP_STATUSES" "$FAKE_DIR/http.count"); fi
case "$method $path" in
  "PATCH v1/projects/"*"/config/auth")
    if [[ -n "${FAKE_AUTH_PATCH_STATUSES:-}" ]]; then status=$(pick "$FAKE_AUTH_PATCH_STATUSES" "$FAKE_DIR/authpatch.count"); fi
    if [[ "$status" =~ ^2 ]]; then printf '%s' "$body" > "$FAKE_DIR/auth.patched"; fi
    answer='{}' ;;
  "GET v1/projects/"*"/config/auth")
    if [[ -n "${FAKE_AUTH:-}" ]]; then answer="$FAKE_AUTH"; else answer="$(cat "$FAKE_DIR/auth.patched" 2> /dev/null || echo '{}')"; fi ;;
  "PATCH v1/projects/"*"/postgrest") answer='{}' ;;
  "GET v1/projects/"*"/postgrest") answer='{"db_schema":"public, graphql_public"}' ;;
  "POST v1/projects/"*"/secrets")
    if [[ -n "${FAKE_SECRETS_STATUSES:-}" ]]; then status=$(pick "$FAKE_SECRETS_STATUSES" "$FAKE_DIR/secrets.count"); fi
    if [[ "$status" =~ ^2 ]]; then
      held=$(cat "$FAKE_DIR/secrets.held" 2> /dev/null || echo '{}')
      jq -c --argjson add "$body" '. + ($add | map({(.name): .value}) | add // {})' <<< "$held" > "$FAKE_DIR/secrets.held"
    fi
    answer='{}' ;;
  "GET v1/projects/"*"/secrets")
    # As the API lists them: each name with the SHA-256 of its value, never
    # the value.
    if [[ -n "${FAKE_SECRETS_LIST_STATUSES:-}" ]]; then status=$(pick "$FAKE_SECRETS_LIST_STATUSES" "$FAKE_DIR/secretslist.count"); fi
    if [[ -n "${FAKE_SECRETS_LIST:-}" ]]; then
      answer="$FAKE_SECRETS_LIST"
    else
      answer=$(jq -c 'to_entries[]' "$FAKE_DIR/secrets.held" 2> /dev/null | while IFS= read -r e; do
                 v=$(jq -r .value <<< "$e")
                 if command -v sha256sum > /dev/null 2>&1; then d=$(printf '%s' "$v" | sha256sum | cut -d ' ' -f 1)
                 else d=$(printf '%s' "$v" | shasum -a 256 | cut -d ' ' -f 1); fi
                 jq -cn --arg n "$(jq -r .key <<< "$e")" --arg d "$d" '{name: $n, value: $d}'
               done | jq -cs '.')
    fi ;;
  "POST storage/v1/object/list/"*)
    # One folder of a bucket, as Storage lists it: folders by name with no
    # id, objects with their size; sorted by name, from offset, up to limit.
    bucket="${path#storage/v1/object/list/}"
    store="$FAKE_DIR/storage/${host%%.*}/${bucket}"
    if [[ -n "${FAKE_STORAGE_LIST_STATUSES:-}" ]]; then status=$(pick "$FAKE_STORAGE_LIST_STATUSES" "$FAKE_DIR/storagelist.count"); fi
    prefix=$(jq -r '.prefix // ""' <<< "$body"); limit=$(jq -r '.limit // 100' <<< "$body"); offset=$(jq -r '.offset // 0' <<< "$body")
    echo "${host%%.*}|${bucket}|${prefix}|${limit}|${offset}" >> "$FAKE_DIR/storage.lists"
    if [[ ! -d "$store" ]]; then
      status=400
      answer='{"statusCode":"404","error":"Bucket not found","message":"Bucket not found"}'
    elif [[ "$status" =~ ^2 ]]; then
      answer=$(
        if [[ -d "$store/$prefix" ]]; then
          ( cd "$store/$prefix" && ls -1A ) | LC_ALL=C sort | while IFS= read -r e; do
            if [[ -d "$store/$prefix/$e" ]]; then
              jq -cn --arg n "$e" '{name: $n, id: null, metadata: null}'
            else
              jq -cn --arg n "$e" --argjson b "$(wc -c < "$store/$prefix/$e" | tr -d ' ')" \
                '{name: $n, id: "00000000-0000-4000-8000-000000000000", metadata: {size: $b, mimetype: "application/pdf"}}'
            fi
          done
        fi | jq -cs --argjson o "$offset" --argjson l "$limit" '.[$o:$o + $l]')
    fi ;;
  "GET storage/v1/object/"*)
    rest="${path#storage/v1/object/}"; bucket="${rest%%/*}"; key="${rest#*/}"
    key=$(printf '%s' "$key" | sed 's/%20/ /g')
    file="$FAKE_DIR/storage/${host%%.*}/${bucket}/${key}"
    if [[ -n "${FAKE_STORAGE_FETCH_STATUSES:-}" ]]; then status=$(pick "$FAKE_STORAGE_FETCH_STATUSES" "$FAKE_DIR/storagefetch.count"); fi
    if [[ ! -f "$file" || "$key" == "${FAKE_STORAGE_GONE:-/}" ]]; then
      status=400
      answer='{"statusCode":"404","error":"not_found","message":"Object not found"}'
    elif [[ "$status" =~ ^2 ]]; then
      if [[ -n "$outfile" ]]; then cp "$file" "$outfile"; else cat "$file"; fi
      [[ "$want_status" == yes ]] && printf '\n%s' "$status"
      exit 0
    fi ;;
  *) answer='{}' ;;
esac
if [[ ! "$status" =~ ^2 && "$path" != storage/* ]] || [[ ! "$status" =~ ^2 && -z "${answer:-}" ]]; then
  answer='{"message":"refused by the rehearsal"}'
fi
if [[ -n "$dump" ]]; then printf 'HTTP/2 %s\r\n\r\n' "$status" > "$dump"; fi
if [[ -n "$outfile" ]]; then printf '%s' "$answer" > "$outfile"; else printf '%s' "$answer"; fi
[[ "$want_status" == yes ]] && printf '\n%s' "$status"
exit 0
FAKE

  cat > "$dir/pg_dump" <<'FAKE'
#!/usr/bin/env bash
conn=""; file=""; table=""; schemas=""; data_only=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) echo "pg_dump (PostgreSQL) 17.6"; exit 0 ;;
    --file=*) file="${1#--file=}"; shift ;;
    -f) file="$2"; shift 2 ;;
    --schema=*) schemas="${schemas}${schemas:+ }${1#--schema=}"; shift ;;
    --table=*) table="${1#--table=}"; shift ;;
    --data-only) data_only=yes; shift ;;
    -*) shift ;;
    *) [[ -n "$conn" ]] || conn="$1"; shift ;;
  esac
done
if [[ -n "${FAKE_CP_URL:-}" && "$conn" == "$FAKE_CP_URL" ]]; then
  target=cp
elif [[ -n "${FAKE_DEMO_URL:-}" && "$conn" == "$FAKE_DEMO_URL" ]]; then
  target=demo
elif [[ "$conn" =~ postgres\.([a-z0-9]{20}) ]]; then
  target="${BASH_REMATCH[1]}"
else
  target=unknown
fi
what="${table:-schemas}"
line="pg_dump $target $what"
if [[ "$data_only" == yes ]]; then line="$line data-only"; fi
echo "$line" >> "$FAKE_DIR/order.log"
printf '%s|%s|%s|%s\n' "$target" "$what" "$schemas" "$data_only" >> "$FAKE_DIR/pg_dump.log"
if [[ -n "${FAKE_PG_DUMP_FAIL:-}" && "$target $what" == "$FAKE_PG_DUMP_FAIL" ]]; then
  echo "pg_dump: error: connection to server failed using \"$conn\": FATAL: the rehearsal refuses this" >&2
  exit 1
fi
[[ -n "$file" ]] || { echo "pg_dump: the rehearsal wants --file" >&2; exit 1; }
printf 'PGDMP fake: %s %s [%s]\n' "$target" "$what" "$schemas" > "$file"
FAKE

  cat > "$dir/age" <<'FAKE'
#!/usr/bin/env bash
recipient=""; out=""; in=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--recipient) recipient="$2"; shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    -*) shift ;;
    *) in="$1"; shift ;;
  esac
done
n=$(( $(cat "$FAKE_DIR/age.calls" 2> /dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_DIR/age.calls"
echo "age $recipient" >> "$FAKE_DIR/order.log"
if [[ -n "${FAKE_AGE_FAIL:-}" ]]; then echo "age: error: the rehearsal refuses this" >&2; exit 1; fi
tar -tf "$in" | LC_ALL=C sort | tr '\n' ' ' > "$FAKE_DIR/age.members.$n"
tar -xOf "$in" manifest.json > "$FAKE_DIR/age.manifest.$n" 2> /dev/null || true
{ printf 'age-encryption.org/v1\n-> X25519 %s\n---\n' "$recipient"; cat "$in"; } > "$out"
FAKE

  cat > "$dir/aws" <<'FAKE'
#!/usr/bin/env bash
words=(); endpoint=""; bucket=""; key=""; prefix=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint-url) endpoint="$2"; shift 2 ;;
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --output) shift 2 ;;
    --*) shift ;;
    *) words+=("$1"); shift ;;
  esac
done
printf '%s|%s|%s\n' "$endpoint" "${AWS_DEFAULT_REGION:-}" "${AWS_REQUEST_CHECKSUM_CALCULATION:-}" >> "$FAKE_DIR/aws.env"
if [[ "${AWS_ACCESS_KEY_ID:-}" != "${FAKE_EXPECT_KEY_ID:-}" || "${AWS_SECRET_ACCESS_KEY:-}" != "${FAKE_EXPECT_SECRET:-}" ]]; then
  echo "An error occurred (InvalidAccessKeyId) when calling the operation: the rehearsal was given another key" >&2
  exit 1
fi
store="$FAKE_DIR/s3"
op="${words[0]:-} ${words[1]:-}"
case "$op" in
  "s3 cp")
    dst="${words[3]#s3://}"; bucket="${dst%%/*}"; key="${dst#*/}"
    echo "aws cp $key" >> "$FAKE_DIR/order.log"
    if [[ -n "${FAKE_AWS_CP_FAIL:-}" ]]; then
      echo "upload failed: ${words[2]} to s3://${bucket}/${key} An error occurred (AccessDenied) at ${endpoint} with key ${AWS_ACCESS_KEY_ID}" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$store/$bucket/$key")"
    cp "${words[2]}" "$store/$bucket/$key" ;;
  "s3 rm")
    dst="${words[2]#s3://}"; bucket="${dst%%/*}"; key="${dst#*/}"
    echo "aws rm $key" >> "$FAKE_DIR/order.log"
    if [[ -n "${FAKE_AWS_RM_FAIL:-}" ]]; then echo "delete failed: s3://${bucket}/${key} An error occurred (AccessDenied)" >&2; exit 1; fi
    rm -f "$store/$bucket/$key" ;;
  "s3api head-object")
    echo "aws head $key" >> "$FAKE_DIR/order.log"
    if [[ ! -f "$store/$bucket/$key" ]]; then echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; fi
    printf '{"ContentLength": %s, "ETag": "\\"fake\\""}\n' "${FAKE_HEAD_BYTES:-$(wc -c < "$store/$bucket/$key" | tr -d ' ')}" ;;
  "s3api list-objects-v2")
    echo "aws list $prefix" >> "$FAKE_DIR/order.log"
    if [[ -n "${FAKE_AWS_LIST_FAIL:-}" ]]; then echo "An error occurred (AccessDenied) when calling the ListObjectsV2 operation" >&2; exit 1; fi
    if [[ -d "$store/$bucket" ]]; then
      ( cd "$store/$bucket" && find . -type f | sed 's|^\./||' ) | LC_ALL=C sort | awk -v p="$prefix" 'index($0, p) == 1' |
        jq -R . | jq -s 'if length == 0 then {} else {Contents: map({Key: .})} end'
    else
      echo '{}'
    fi ;;
  *) echo "the rehearsal's aws does not know: ${words[*]}" >&2; exit 2 ;;
esac
FAKE

  cat > "$dir/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "sleep $1" >> "$FAKE_DIR/order.log"
FAKE

  cat > "$dir/gh" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == api ]] || { echo "the rehearsal's gh knows only gh api" >&2; exit 2; }
shift
path=""; jqx="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq|-q) jqx="$2"; shift 2 ;;
    --paginate) shift ;;
    -*) shift ;;
    *) [[ -n "$path" ]] || path="$1"; shift ;;
  esac
done
[[ "$path" =~ ^repos/[^/]+/[^/]+/actions/ ]] || { echo "the rehearsal's gh was asked ${path}, which is not a repository's actions" >&2; exit 2; }
p="${path%%\?*}"; p="${p#repos/*/*/actions/}"
echo "gh $p" >> "$FAKE_DIR/order.log"
echo "$path" >> "$FAKE_DIR/gh.log"
if [[ -n "${FAKE_GH_FAIL:-}" ]]; then echo "HTTP 502: Bad Gateway (https://api.github.com/${path})" >&2; exit 1; fi
file="$FAKE_DIR/gh/${p//\//_}.json"
if [[ -f "$file" ]]; then
  answer=$(cat "$file")
else
  case "$p" in */jobs) answer='{"jobs":[]}' ;; *) answer='{"workflow_runs":[]}' ;; esac
fi
printf '%s' "$answer" | jq -r "$jqx"
FAKE

  chmod +x "$dir/psql" "$dir/curl" "$dir/pg_dump" "$dir/age" "$dir/aws" "$dir/sleep" "$dir/gh"
}

# gh_run <workflow file> <run id> [status] [event] [title]: one run of it,
# added to what the fake gh says the workflow has (status default
# in_progress, event default workflow_dispatch; its display_title, as a
# run-name makes it, only when one is given).
gh_run() {
  local f="$FAKE_DIR/gh/workflows_${1}_runs.json" have
  mkdir -p "$FAKE_DIR/gh"
  have=$(cat "$f" 2> /dev/null || echo '{"workflow_runs":[]}')
  jq -c --argjson id "$2" --arg s "${3:-in_progress}" --arg e "${4:-workflow_dispatch}" --arg t "${5:-}" \
    '.workflow_runs += [{id: $id, status: $s, event: $e} + (if $t == "" then {} else {display_title: $t} end)]' <<< "$have" > "$f"
}

# gh_job <run id> <job name> <job status> [<step name>=<step status> ...]:
# one job of that run, with its steps.
gh_job() {
  local run="$1" name="$2" status="$3" f have steps='[]' kv
  shift 3
  f="$FAKE_DIR/gh/runs_${run}_jobs.json"
  mkdir -p "$FAKE_DIR/gh"
  for kv in "$@"; do
    steps=$(jq -c --arg n "${kv%=*}" --arg s "${kv##*=}" '. + [{name: $n, status: $s}]' <<< "$steps")
  done
  have=$(cat "$f" 2> /dev/null || echo '{"jobs":[]}')
  jq -c --arg n "$name" --arg s "$status" --argjson st "$steps" '.jobs += [{name: $n, status: $s, steps: $st}]' <<< "$have" > "$f"
}

# workflow_step <workflow file> <step name>: the step's run: block (| or one
# line), its indentation taken off; nothing when the workflow has no such
# step.
workflow_step() {
  awk -v want="$2" '
    function lead(s) { match(s, /^ */); return RLENGTH }
    state == 0 && index($0, "- name: ") && substr($0, index($0, "- name: ") + 8) == want { state = 1; base = lead($0); next }
    state >= 1 && index($0, "- name: ") && lead($0) <= base { exit }
    state == 1 && $0 ~ /^ *run: [|]/ { state = 2; next }
    state == 1 && $0 ~ /^ *run: / { sub(/^ *run: /, ""); print; exit }
    state == 2 {
      if ($0 ~ /^ *$/) { print ""; next }
      if (!at) at = lead($0)
      if (lead($0) < at) exit
      print substr($0, at + 1)
    }
  ' "$1"
}

# answer <database> <tag> <text...>: what the fake psql says to that statement
# (each argument one line); tag#n for the nth call only.
answer() {
  local target="$1" tag="$2"
  shift 2
  mkdir -p "$FAKE_DIR/answers/$target"
  printf '%s\n' "$@" > "$FAKE_DIR/answers/$target/$tag"
}
