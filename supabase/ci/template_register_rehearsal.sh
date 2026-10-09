#!/usr/bin/env bash
#
# supabase/ci/template_register.sh, and fleet_register.sh's build-method,
# rehearsed with no database, no GitHub and no bucket.
#
# Which template a client is restored from is decided here
# (deployment_from_empty.yml, template.yml): wrong one way, a client is
# restored from a template made from other migrations than the ones its
# releases expect; wrong the other, a good template is never used. So,
# against a small git repository made in a temporary directory, a psql that
# answers from the environment, a gh and an aws that keep what they are given:
# a template matches only when the commit it was made from has exactly this
# checkout's supabase/migrations, the newest such is chosen, anything the
# register says that is not a commit, a sha256 or a storage key is passed
# over, a fetched template is unpacked only when it is exactly its three
# files, the bucket's secret never reaches an argument or the output, a
# template is recorded with every value as a psql variable and the run that
# proved it, and a control plane released before the register says so and
# stops nothing. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
mkdir -p "$repo/supabase/ci" "$repo/supabase/migrations" "$repo/src"

# The throwaway repository is its own: git never looks above it for another,
# and no user or system setting reaches it.
export GIT_CEILING_DIRECTORIES="$work"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=rehearsal GIT_AUTHOR_EMAIL=rehearsal@example.com
export GIT_COMMITTER_NAME=rehearsal GIT_COMMITTER_EMAIL=rehearsal@example.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2> /dev/null || true
g() { git -C "$repo" "$@"; }

# The script runs from inside it, so this checkout is the made-up one.
cp "$HERE/template_register.sh" "$HERE/fleet_offsite.sh" "$repo/supabase/ci/"
SCRIPT="$repo/supabase/ci/template_register.sh"

g init -q -b main 2> /dev/null || { g init -q && g checkout -q -b main; }
echo "select 1;" > "$repo/supabase/migrations/0001_first.sql"
echo "select 2;" > "$repo/supabase/migrations/20261012070000_a_client_is_built_from_a_template.sql"
g add -A && g commit -q -m "two migrations"
C_TWO=$(g rev-parse HEAD)
echo "select 3;" > "$repo/supabase/migrations/20261012080000_a_third.sql"
g add -A && g commit -q -m "a third migration"
C_THREE=$(g rev-parse HEAD)
echo "edited" >> "$repo/supabase/migrations/20261012080000_a_third.sql"
g add -A && g commit -q -m "the third, edited"
C_EDITED=$(g rev-parse HEAD)
g checkout -q "$C_THREE" -- supabase/migrations/20261012080000_a_third.sql
echo "export const x = 1;" > "$repo/src/app.ts"
g add -A && g commit -q -m "the third as it was, and the application changed"
C_HEAD=$(g rev-parse HEAD)

URL="postgresql://postgres.xpzffnnhnhcqyjqcueja:s3cret-pass@pooler.example.invalid:5432/postgres"
SECRET="r2-secret-never-printed"
DUMP_SHA=$(printf '%064d' 1)

FP='{"columns":"aa","functions":"bb","version":1}'
# found <git sha> [dump] [key] [run]: the row provisioning_template_for answers, as jsonb text.
found() {
  jq -cn --arg sha "$1" --arg dump "${2:-$DUMP_SHA}" --arg key "${3:-artifact:77:cloveerp-template-20261012080000}" \
         --arg run "${4:-77}" --argjson fp "$FP" \
    '{id: "6f1f0c1e-0000-4000-8000-000000000001", git_sha: $sha, newest_migration: "20261012080000", migration_count: 3,
      dump_sha256: $dump, fingerprint: $fp, storage_key: $key, proving_run_id: $run, recorded_at: "2026-10-12T07:00:00+00:00"}'
}

# ── A psql that answers from the environment ─────────────────────────────────
cat > "$work/psql" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/psql.log"
vars=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v) vars+="$2"$'\n'; shift 2 ;;
    *) shift ;;
  esac
done
sql=$(cat)
case "$sql" in
  *"to_regclass('erp_meta.provisioning_template') is not null"*)
    printf '%s' "$sql" > "$FAKE_DIR/ready.sql"; echo "${FAKE_READY:-true true true}" ;;
  *"erp_meta.provisioning_template_for(:'newest', :'count'::integer)"*)
    printf '%s' "$vars" > "$FAKE_DIR/match.vars"
    if [[ -n "${FAKE_MATCH_FAIL:-}" ]]; then
      echo "psql: error: connection to server at \"pooler.example.invalid\", port 5432 failed: FATAL: password authentication failed for postgresql://postgres.xpzffnnhnhcqyjqcueja:s3cret-pass@pooler.example.invalid:5432/postgres" >&2
      exit 2
    fi
    printf '%s\n' "${FAKE_FOUND:-}" ;;
  *"from erp_meta.provisioning_template"*) echo "the table read directly: $sql" >> "$FAKE_DIR/unexpected" ;;
  *"select erp_meta.record_provisioning_template(:'git_sha'"*)
    printf '%s' "$vars" > "$FAKE_DIR/record.vars"; printf '%s' "$sql" > "$FAKE_DIR/record.sql"
    if [[ -n "${FAKE_RECORD_FAIL:-}" ]]; then
      echo "psql:<stdin>:1: ERROR:  CLOVEERP_NOT_THE_CONTROL_PLANE: this is a client deployment, and the register is the control plane's (postgresql://postgres.xpzffnnhnhcqyjqcueja:s3cret-pass@pooler.example.invalid:5432/postgres)" >&2
      echo "HINT:  Record it on the control plane." >&2
      exit 3
    fi
    echo "{\"git_sha\": \"x\", \"outcome\": \"${FAKE_OUTCOME-recorded}\"}" ;;
  *"to_regprocedure('erp_meta.record_deployment_build_method(text,text,text)') is not null"*) echo "${FAKE_HAS_RECORDER:-true}" ;;
  *"select erp_meta.record_deployment_build_method(:'code', :'method', nullif(:'template', ''))"*)
    printf '%s' "$vars" > "$FAKE_DIR/build.vars"; echo "${FAKE_SAID:-acme: building from the template of 3 migrations to 20261012080000, made at 0123456789ab and proved by run 77}" ;;
  *"'status=' || d.status"*) printf '%s' "$sql" > "$FAKE_DIR/row.sql"; printf 'status=building\nref=abcdefghijklmnopqrst\napi_url=\nbuild_method=template\n' ;;
  *) echo "unexpected: $sql" >> "$FAKE_DIR/unexpected" ;;
esac
exit 0
FAKE
chmod +x "$work/psql"

# ── A gh and an aws that hand over a prepared tar and keep what they were asked ─
cat > "$work/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/gh.log"
[[ -z "${FAKE_GH_FAIL:-}" ]] || { echo "no valid artifacts found to download" >&2; exit 1; }
dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in --dir) dir="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$dir" && cp "$FAKE_TAR" "$dir/template.tar"
FAKE
chmod +x "$work/gh"
cat > "$work/aws" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/aws.log"
env | grep -c "^AWS_SECRET_ACCESS_KEY=${CLOVEERP_BACKUP_S3_SECRET}$" >> "$FAKE_DIR/aws.secret_in_env"
[[ "$1 $2" == "s3 cp" ]] || exit 1
cp "$FAKE_TAR" "$4"
FAKE
chmod +x "$work/aws"

# The tars a fetch is handed: a template, one with something else in it, and
# one without the listing of what its fingerprint hashed.
mkdir -p "$work/tpl" "$work/odd" "$work/short"
printf '{"format":"cloveerp.template.v1"}\n' > "$work/tpl/manifest.json"
printf 'PGDMP\n' > "$work/tpl/template.dump"
printf '0001\tfirst\n' > "$work/tpl/migrations.tsv"
printf 'columns\terp.tenant.code\t0123456789abcdef\n' > "$work/tpl/fingerprint.tsv"
tar -C "$work/tpl" -cf "$work/good.tar" fingerprint.tsv manifest.json template.dump migrations.tsv
cp "$work/tpl/"* "$work/odd/"
printf 'not a template\n' > "$work/odd/extra.sh"
tar -C "$work/odd" -cf "$work/odd.tar" fingerprint.tsv manifest.json template.dump migrations.tsv extra.sh
cp "$work/tpl/"* "$work/short/"
tar -C "$work/short" -cf "$work/short.tar" manifest.json template.dump migrations.tsv
# A manifest to record.
mkdir -p "$work/made"
jq -n --arg sha "$C_HEAD" --arg dump "$DUMP_SHA" \
  '{format: "cloveerp.template.v1", git_sha: $sha, newest_version: "20261012080000", migration_count: 3,
    files: {"template.dump": {sha256: $dump}}, fingerprint: {functions: "bb", columns: "aa", version: 1}}' > "$work/made/manifest.json"

CASES=0
FAILED=0
run() {
  # run <name> <command and arguments> [-- VAR=value ...]: a fresh fake, the script, its exit and output.
  local name="$1"; shift
  local -a args envs
  args=(); envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do args+=("$1"); shift; done
  [[ $# -eq 0 ]] || { shift; envs=("$@"); }
  rm -rf "$work/fake" "$work/into"; mkdir -p "$work/fake"
  out=$(env FAKE_DIR="$work/fake" PSQL="$work/psql" GH="$work/gh" AWS="$work/aws" FAKE_TAR="$work/good.tar" \
          CLOVEERP_LIVE_DATABASE_URL="$URL" GITHUB_RUN_ID=424242 ${envs[@]+"${envs[@]}"} \
          bash "${TARGET:-$SCRIPT}" "${args[@]}" 2>&1)
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
no_secret='[[ "$out" != *"s3cret-pass"* && "$out" != *"$SECRET"* ]]'

# 1. Whether the control plane has the register
run "a control plane without the register" ready -- FAKE_READY="false false false"
check '[[ $status -eq 3 && "$out" == *"no register of templates yet (20261012070000"* ]]' "said, as not yet (3), not as a failure"
run "a control plane with the table and the recorder, not the lookup" ready -- FAKE_READY="true true false"
check '[[ $status -eq 3 ]]' "not ready: a build finds templates through erp_meta.provisioning_template_for"
run "a control plane with it" ready
check '[[ $status -eq 0 && "$out" == *"ready"* ]] && grep -q "to_regprocedure('"'"'erp_meta.record_provisioning_template(text,text,integer,text,jsonb,text,text)'"'"')" "$work/fake/ready.sql" && grep -q "to_regprocedure('"'"'erp_meta.provisioning_template_for(text,integer)'"'"')" "$work/fake/ready.sql"' \
      "ready: the register, its recorder and its lookup, by their signatures"
run "no control plane" ready -- CLOVEERP_LIVE_DATABASE_URL=
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* && ! -e "$work/fake/psql.log" ]]' "refused before anything is asked"

# 2. Which template matches this checkout
run "nothing registered" match
check '[[ $status -eq 3 && "$out" == *"no template is registered for these migrations (3, the newest 20261012080000)"* ]]' "none, saying for what"
check 'grep -qx "newest=20261012080000" "$work/fake/match.vars" && grep -qx "count=3" "$work/fake/match.vars" && [[ ! -e "$work/fake/unexpected" ]]' \
      "the register's own lookup asked, with this checkout's newest migration and count as variables, and the table never read"
run "made from a commit with the same migrations" match -- FAKE_FOUND="$(found "$C_THREE")"
check '[[ $status -eq 0 && "$out" == *"git_sha=$C_THREE"* && "$out" == *"dump_sha256=$DUMP_SHA"* && "$out" == *"storage_key=artifact:77:cloveerp-template-20261012080000"* && "$out" == *"proving_run_id=77"* ]]' \
      "matches: a change elsewhere in the repository is not a different schema"
check '[[ "$out" == *"fingerprint={\"columns\":\"aa\",\"functions\":\"bb\",\"version\":1}"* ]]' \
      "and the fingerprint the register holds, compact, for the restore to hold the manifest's to"
run "made from a commit whose migration has since been edited" match -- FAKE_FOUND="$(found "$C_EDITED" "$DUMP_SHA" "s3:templates/20261012080000/$C_EDITED/template.tar")"
check '[[ $status -eq 3 && "$out" == *"from migrations that are not this checkout"* && "$out" == *"${C_EDITED:0:12}"* ]]' \
      "does not match, though its newest migration and count are the same"
run "a commit this repository does not have" match -- FAKE_FOUND="$(found "$(printf '%040d' 5)")"
check '[[ $status -eq 3 && "$out" == *"which this repository does not have"* ]]' "none, saying why"
run "a dump that is not a sha256" match -- FAKE_FOUND="$(found "$C_THREE" short)"
check '[[ $status -eq 3 && "$out" == *"not in a form a build restores from"* ]]' "passed over"
run "a storage key that climbs out" match -- FAKE_FOUND="$(found "$C_THREE" "$DUMP_SHA" "s3:../escape")"
check '[[ $status -eq 3 && "$out" == *"not in a form a build restores from"* ]]' "passed over"
run "a storage key that is a URL" match -- FAKE_FOUND="$(found "$C_THREE" "$DUMP_SHA" "https://example.com/template.tar")"
check '[[ $status -eq 3 ]]' "passed over"
run "an answer that is not a row" match -- FAKE_FOUND="not json"
check '[[ $status -eq 3 && "$out" == *"not in a form a build restores from"* ]]' "passed over"
run "a register that cannot be asked" match -- FAKE_MATCH_FAIL=1
check '[[ $status -eq 2 && "$out" == *"the register could not be asked for a template"* && "$out" == *"password authentication failed"* ]] && '"$no_secret" \
      "refused, saying why, with the connection taken out"

# 3. Fetching it
run "a storage key that is not one" fetch "file:/etc/passwd" "$work/into"
check '[[ $status -eq 2 && "$out" == *"is not a template'"'"'s storage key"* ]]' "refused"
mkdir -p "$work/full"; echo x > "$work/full/left"
run "into a directory with something in it" fetch "artifact:77:t" "$work/full"
check '[[ $status -eq 2 && "$out" == *"is not empty"* && ! -e "$work/fake/gh.log" ]]' "refused before anything is fetched"
run "an artifact" fetch "artifact:77:cloveerp-template-20261012080000" "$work/into" -- GH_REPO=owner/repo
check '[[ $status -eq 0 && -s "$work/into/manifest.json" && -s "$work/into/template.dump" && -s "$work/into/migrations.tsv" && -s "$work/into/fingerprint.tsv" && ! -e "$work/into/template.tar" && ! -e "$work/into/artifact" ]]' \
      "the four files unpacked, and nothing else left"
check '[[ "$(cat "$work/fake/gh.log")" == "run download 77 --name cloveerp-template-20261012080000 --dir $work/into/artifact" ]]' \
      "gh asked for that run's artifact by name"
run "an artifact that is gone" fetch "artifact:77:t" "$work/into" -- FAKE_GH_FAIL=1
check '[[ $status -eq 2 && "$out" == *"ninety days"* ]]' "refused, saying how long an artifact is kept"
run "a tar with something else in it" fetch "artifact:77:t" "$work/into" -- FAKE_TAR="$work/odd.tar"
check '[[ $status -eq 2 && "$out" == *"not exactly fingerprint.tsv, manifest.json, migrations.tsv and template.dump"* && ! -e "$work/into/extra.sh" ]]' \
      "refused, and nothing of it unpacked"
run "a tar without the listing" fetch "artifact:77:t" "$work/into" -- FAKE_TAR="$work/short.tar"
check '[[ $status -eq 2 && "$out" == *"not exactly fingerprint.tsv"* && ! -e "$work/into/template.dump" ]]' "refused, and nothing of it unpacked"
run "a bucket with no settings" fetch "s3:templates/20261012080000/$C_HEAD/template.tar" "$work/into"
check '[[ $status -eq 2 && "$out" == *"bucket'"'"'s settings"* && ! -e "$work/fake/aws.log" ]]' "refused before the store is asked"
run "the bucket" fetch "s3:templates/20261012080000/$C_HEAD/template.tar" "$work/into" -- \
    CLOVEERP_BACKUP_S3_ENDPOINT=https://acct.r2.cloudflarestorage.com CLOVEERP_BACKUP_S3_BUCKET=clove-backups \
    CLOVEERP_BACKUP_S3_KEY_ID=key-id-rehearsal CLOVEERP_BACKUP_S3_SECRET="$SECRET"
check '[[ $status -eq 0 && -s "$work/into/template.dump" ]] && grep -q "^s3 cp s3://clove-backups/templates/20261012080000/$C_HEAD/template.tar $work/into/template.tar" "$work/fake/aws.log" && grep -q -- "--endpoint-url https://acct.r2.cloudflarestorage.com" "$work/fake/aws.log"' \
      "fetched from the bucket, at its endpoint, and unpacked"
check '! grep -q "$SECRET" "$work/fake/aws.log" && [[ "$(cat "$work/fake/aws.secret_in_env")" == 1 ]] && '"$no_secret" \
      "the secret in the store command's environment only: never an argument, never printed"

# 4. Recording it
run "no run to name" record "$work/made" "artifact:77:t" -- GITHUB_RUN_ID=
check '[[ $status -eq 2 && "$out" == *"GITHUB_RUN_ID is not set"* && ! -e "$work/fake/psql.log" ]]' "refused before anything is asked"
run "a control plane without the register" record "$work/made" "artifact:77:t" -- FAKE_READY="true false true"
check '[[ $status -eq 3 && ! -e "$work/fake/record.vars" ]]' "said, and nothing recorded"
run "recorded" record "$work/made" "artifact:424242:cloveerp-template-20261012080000"
check '[[ $status -eq 0 && "$out" == *") recorded, kept as artifact:424242:cloveerp-template-20261012080000, proved by run 424242"* && "$out" == *"outcome=recorded"* ]]' "said, with the register's outcome"
check 'grep -qx "git_sha=$C_HEAD" "$work/fake/record.vars" && grep -qx "newest=20261012080000" "$work/fake/record.vars" && grep -qx "count=3" "$work/fake/record.vars" && grep -qx "dump=$DUMP_SHA" "$work/fake/record.vars" && grep -qx "fingerprint={\"functions\":\"bb\",\"columns\":\"aa\",\"version\":1}" "$work/fake/record.vars" && grep -qx "key=artifact:424242:cloveerp-template-20261012080000" "$work/fake/record.vars" && grep -qx "run=424242" "$work/fake/record.vars"' \
      "every value a psql variable: the commit, the newest, the count, the dump, the fingerprint, where it is kept, the run"
check 'grep -q ":'"'"'count'"'"'::integer" "$work/fake/record.sql" && grep -q ":'"'"'fingerprint'"'"'::jsonb" "$work/fake/record.sql" && grep -q ":'"'"'run'"'"')::text;" "$work/fake/record.sql" && [[ ! -e "$work/fake/unexpected" ]]' \
      "the recorder called with its count an integer and its fingerprint jsonb, its answer read as JSON"
check "$no_secret" "no connection string printed"
run "recorded again, exactly so" record "$work/made" "artifact:424242:t" -- FAKE_OUTCOME=replay
check '[[ $status -eq 0 && "$out" == *"recorded already, exactly so (nothing changed)"* && "$out" == *"outcome=replay"* ]]' "a replay said as one"
run "recorded again from a later run" record "$work/made" "artifact:424242:t" -- FAKE_OUTCOME=renewed
check '[[ $status -eq 0 && "$out" == *"where it is kept and the run that proved it renewed"* && "$out" == *"outcome=renewed"* ]]' "a renewal said as one"
run "an answer that is not a recorded template" record "$work/made" "artifact:424242:t" -- FAKE_OUTCOME=
check '[[ $status -eq 2 && "$out" == *"not a recorded template"* ]]' "refused"
run "anywhere but the control plane" record "$work/made" "artifact:424242:t" -- FAKE_RECORD_FAIL=1
check '[[ $status -eq 2 && "$out" == *"the control plane did not record the template"* && "$out" == *"CLOVEERP_NOT_THE_CONTROL_PLANE"* ]] && '"$no_secret" \
      "refused, saying the register's refusal, with the connection taken out"

# 5. How a deployment is built, on its row (fleet_register.sh build-method), and the row saying so
TARGET="$HERE/fleet_register.sh" run "a template build" build-method acme template "$DUMP_SHA"
check '[[ $status -eq 0 && "$out" == *"register: acme: building from the template of 3 migrations"* ]] && grep -qx "code=acme" "$work/fake/build.vars" && grep -qx "method=template" "$work/fake/build.vars" && grep -qx "template=$DUMP_SHA" "$work/fake/build.vars" && [[ ! -e "$work/fake/unexpected" ]]' \
      "erp_meta.record_deployment_build_method asked with the code, the method and the dump, as variables, and its answer said"
TARGET="$HERE/fleet_register.sh" run "a build from empty" build-method acme from_empty -- FAKE_SAID="acme: building from empty, replaying every migration"
check '[[ $status -eq 0 && "$out" == *"acme: building from empty"* ]] && grep -qx "method=from_empty" "$work/fake/build.vars" && grep -qx "template=" "$work/fake/build.vars"' "the method alone, no template named"
TARGET="$HERE/fleet_register.sh" run "a control plane without the recorder" build-method acme from_empty -- FAKE_HAS_RECORDER=false
check '[[ $status -eq 0 && "$out" == *"cannot record how a deployment was built yet"* && ! -e "$work/fake/build.vars" ]]' \
      "said, and no build stopped for it"
TARGET="$HERE/fleet_register.sh" run "a method that is not one" build-method acme replay
check '[[ $status -eq 2 && "$out" == *"is not a build method"* && ! -e "$work/fake/psql.log" ]]' "refused before anything is asked"
TARGET="$HERE/fleet_register.sh" run "a template build naming no dump" build-method acme template
check '[[ $status -eq 2 && "$out" == *"names the sha256 of the dump it restored"* && ! -e "$work/fake/psql.log" ]]' "refused before anything is asked"
TARGET="$HERE/fleet_register.sh" run "a build from empty naming a dump" build-method acme from_empty "$DUMP_SHA"
check '[[ $status -eq 2 && "$out" == *"restores no template"* && ! -e "$work/fake/psql.log" ]]' "refused before anything is asked"
TARGET="$HERE/fleet_register.sh" run "the row" row acme
check '[[ $status -eq 0 && "$out" == *"build_method=template"* ]] && grep -q "coalesce(to_jsonb(d) ->> '"'"'build_method'"'"', '"'"''"'"')" "$work/fake/row.sql"' \
      "says how it is built, read so that a control plane without the column answers nothing rather than fails"

echo "$CASES checks over the register of templates, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
