#!/usr/bin/env bash
#
# supabase/ci/template_make.sh, rehearsed with no database.
#
# The template it makes is what every client built from one is restored from
# (template.yml makes it, deployment_from_empty.yml restores it), so a mistake
# in it is learned in every client or not at all. Here first, against a psql
# that answers from the environment and a pg_dump that keeps what it is
# given: what it refuses before anything is dumped (an organisation, a staff
# row, a release, a deployment.* setting, a register row; a history, schema,
# extension or role that is not what the migrations build; no fingerprint, or
# a listing of what it hashed that is empty, malformed or names a part it
# does not hash; a migration creating a schema the template does not dump),
# what it asks pg_dump for, the manifest, the history and the listing it
# writes, and that no password is ever printed. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/template_make.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

URL="postgresql://postgres:s3cret-pass@db.example.invalid:5432/clove_erp"
SHA="0123456789abcdef0123456789abcdef01234567"

# ── A psql that answers from the environment ─────────────────────────────────
cat > "$work/psql" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/psql.log"
cmd=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) cmd+="$2"$'\n'; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "${FAKE_PSQL_FAIL:-}" ]]; then
  echo "psql: error: connection to postgresql://postgres:s3cret-pass@db.example.invalid:5432/clove_erp failed: FATAL: password authentication failed" >&2
  exit 2
fi
# Defaults with braces in them, which a ${VAR:-default} would cut short.
ext_default='[{"name":"btree_gist","schema":"extensions","version":"1.7"},{"name":"pg_jsonschema","schema":"extensions","version":"0.3.3"},{"name":"pgcrypto","schema":"extensions","version":"1.3"}]'
roles_default='[{"name":"clove_enquiry","login":false,"inherit":false,"bypassrls":false,"superuser":false,"builder_member":true,"builder_set":true,"builder_inherit":false}]'
fp_default='{"functions": "bb", "columns": "aa"}'
listing_default=$(printf 'columns\terp.tenant.code\t0123456789abcdef\nfunctions\terp.f(p_a text)\tfedcba9876543210\n')
case "$cmd" in
  *"from erp_meta.schema_fingerprint_detail() d) l order by l.line"*)
    printf '%s\n' "$cmd" > "$FAKE_DIR/listing.sql"
    if [[ -n "${FAKE_LISTING_FAIL:-}" ]]; then echo "ERROR:  function erp_meta.schema_fingerprint_detail() does not exist" >&2; exit 3; fi
    printf '%s\n' "${FAKE_LISTING-$listing_default}" ;;
  *"to_regprocedure('erp_meta.schema_fingerprint()') is not null"*) echo "${FAKE_SHAPE:-t t t t t f t}" ;;
  *"count(*) from erp.tenant"*) echo "${FAKE_HELD:-0 0 0}" ;;
  *"s.key like 'deployment.%'"*) echo "${FAKE_SETTINGS:-}" ;;
  *"count(*) from erp_meta.deployment"*) echo "${FAKE_REGISTER:-0}" ;;
  *"select version from supabase_migrations"*) printf '%s' "${FAKE_RECORDED:-}" ;;
  *"to_regnamespace(s) is null"*) echo "${FAKE_MISSING:-}" ;;
  *"'version', e.extversion"*) echo "${FAKE_EXTENSIONS:-$ext_default}" ;;
  *"' (in ' ||"*) echo "${FAKE_INSIDE:-}" ;;
  *"aclexplode"*) echo "${FAKE_ROLES:-$roles_default}" ;;
  *"schema_fingerprint()::text"*) echo "${FAKE_FINGERPRINT:-$fp_default}" ;;
  *) echo "unexpected: $cmd" >> "$FAKE_DIR/unexpected" ;;
esac
exit 0
FAKE
chmod +x "$work/psql"

# ── And a pg_dump that keeps what it is given ────────────────────────────────
cat > "$work/pg_dump" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then echo "pg_dump (PostgreSQL) 17.6"; exit 0; fi
printf '%s\n' "$@" > "$FAKE_DIR/pg_dump.args"
if [[ -n "${FAKE_DUMP_FAIL:-}" ]]; then
  echo "pg_dump: error: connection to server at postgresql://postgres:s3cret-pass@db.example.invalid failed" >&2
  for a in "$@"; do [[ "$a" == --file=* ]] && printf 'half' > "${a#--file=}"; done
  exit 1
fi
for a in "$@"; do
  [[ "$a" == --file=* ]] && printf 'PGDMP rehearsal dump of %s\n' "${FAKE_DUMP_BODY:-the product}" > "${a#--file=}"
done
exit 0
FAKE
chmod +x "$work/pg_dump"

# Three migrations, named the way the repository names them.
mig="$work/migrations"
mkdir -p "$mig"
echo "create schema if not exists erp;" > "$mig/0001_first.sql"
echo "select 2; -- create schema if not exists supabase_migrations" > "$mig/20260830091046_ad905a9f-fe00-4810-961e-441bae0f46a0.sql"
printf 'create schema if not exists erp_meta;\ncreate   SCHEMA "erp_ref";\n' > "$mig/20261012070000_a_client_is_built_from_a_template.sql"
odd="$work/odd_migrations"
mkdir -p "$odd"
cp "$mig"/*.sql "$odd"/
echo "create schema if not exists erp_extra;" > "$odd/20261012080000_a_new_schema.sql"

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...]: a fresh fake and output directory, the script, its exit and output.
  local name="$1"; shift
  rm -rf "$work/fake" "$work/out"; mkdir -p "$work/fake"
  out=$(env FAKE_DIR="$work/fake" PSQL="$work/psql" PG_DUMP="$work/pg_dump" MIGRATIONS_DIR="$mig" GIT_SHA="$SHA" "$@" \
          bash "$SCRIPT" "${TARGET_URL:-$URL}" "${OUT_DIR:-$work/out}" 2>&1)
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
nothing_asked='[[ ! -s "$work/fake/psql.log" && ! -e "$work/fake/pg_dump.args" ]]'
nothing_dumped='[[ ! -e "$work/fake/pg_dump.args" && ! -e "$work/out/template.dump" && ! -e "$work/out/manifest.json" ]]'
no_secret='[[ "$out" != *"s3cret-pass"* ]]'

# 1. What is asked for
run "no commit named" GIT_SHA=
check '[[ $status -eq 2 && "$out" == *"GIT_SHA must be the full commit"* ]] && '"$nothing_asked" "refused before anything connects"
TARGET_URL="not a url" run "not a database URL"
check '[[ $status -eq 2 && "$out" == *"not a database URL"* ]] && '"$nothing_asked" "refused before anything connects"
mkdir -p "$work/full"; echo x > "$work/full/left-over"
OUT_DIR="$work/full" run "an output directory with something in it"
check '[[ $status -eq 2 && "$out" == *"is not empty"* && "$(cat "$work/full/left-over")" == x ]] && '"$nothing_asked" \
      "refused, and what was there is left alone"

# 2. A migration creating a schema the template would not dump
run "a migration creating an unknown schema" MIGRATIONS_DIR="$odd"
check '[[ $status -eq 2 && "$out" == *"erp_extra"* && "$out" == *"TEMPLATE_SCHEMAS"* ]] && '"$nothing_asked" \
      "refused from the migrations' text, before anything connects"

# 3. What one deployment holds and the product does not
run "a database holding an organisation" FAKE_HELD="1 0 0"
check '[[ $status -eq 2 && "$out" == *"holds 1 organisation(s)"* ]] && '"$nothing_dumped" "refused, and nothing dumped"
run "a staff row" FAKE_HELD="0 1 0"
check '[[ $status -eq 2 && "$out" == *"1 platform staff row(s)"* ]] && '"$nothing_dumped" "refused, and nothing dumped"
run "a release" FAKE_HELD="0 0 2"
check '[[ $status -eq 2 && "$out" == *"2 release row(s)"* ]] && '"$nothing_dumped" "refused, and nothing dumped"
run "a deployment setting" FAKE_SETTINGS="deployment.kind, deployment.ref"
check '[[ $status -eq 2 && "$out" == *"the setting(s) deployment.kind, deployment.ref"* ]] && '"$nothing_dumped" "refused, naming each"
run "a register row" FAKE_REGISTER=3
check '[[ $status -eq 2 && "$out" == *"3 deployment(s) in the register"* ]] && '"$nothing_dumped" "refused, and nothing dumped"
run "the demonstration" FAKE_HELD="4 2 9" FAKE_SETTINGS="deployment.kind" FAKE_REGISTER=0
check '[[ $status -eq 2 && "$out" == *"4 organisation(s); 2 platform staff row(s); 9 release row(s); the setting(s) deployment.kind"* ]] && '"$nothing_dumped" \
      "everything it holds said in one refusal"
run "a control plane without its register yet" FAKE_SHAPE="t t t t f f t" FAKE_HELD="0 0 0"
check '[[ $status -eq 0 ]] && ! grep -q "count(\*) from erp_meta.deployment" "$work/fake/psql.log"' \
      "the register is not asked about where it does not exist"

# 4. Not what the migrations build
run "not a database the migrations built" FAKE_SHAPE="f t t t t f t"
check '[[ $status -eq 2 && "$out" == *"not a database the migrations built"* ]] && '"$nothing_dumped" "refused"
run "a history that is not this directory's" FAKE_SHAPE="t t t t t t t" FAKE_RECORDED=$'0001\n20260830091046\n'
check '[[ $status -eq 2 && "$out" == *"migration history that is not the migrations directory"* ]] && '"$nothing_dumped" "refused"
run "a history that is this directory's" FAKE_SHAPE="t t t t t t t" FAKE_RECORDED=$'20261012070000\n0001\n20260830091046\n'
check '[[ $status -eq 0 && -s "$work/out/template.dump" ]]' "accepted, in whatever order the database lists it"
run "no fingerprint" FAKE_SHAPE="t t t t t f f"
check '[[ $status -eq 2 && "$out" == *"no erp_meta.schema_fingerprint()"* && "$out" == *"20261012070000"* ]] && '"$nothing_dumped" "refused"
run "a product schema missing" FAKE_MISSING="erp_ai"
check '[[ $status -eq 2 && "$out" == *"product schema(s) erp_ai are missing"* ]] && '"$nothing_dumped" "refused"
run "an extension missing" FAKE_EXTENSIONS='[{"name":"btree_gist","schema":"extensions","version":"1.7"},{"name":"pgcrypto","schema":"extensions","version":"1.3"}]'
check '[[ $status -eq 2 && "$out" == *"extension pg_jsonschema is not in this database"* ]] && '"$nothing_dumped" "refused"
run "an extension inside a dumped schema" FAKE_INSIDE="pg_trgm (in public)"
check '[[ $status -eq 2 && "$out" == *"pg_trgm (in public) live in a schema the template dumps"* ]] && '"$nothing_dumped" "refused"
run "a role that can sign in" FAKE_ROLES='[{"name":"clove_enquiry","login":true,"inherit":false,"bypassrls":false,"superuser":false,"builder_member":true,"builder_set":true,"builder_inherit":false}]'
check '[[ $status -eq 2 && "$out" == *"clove_enquiry, which can sign in or bypass row security"* ]] && '"$nothing_dumped" "refused"
run "a role that bypasses row security" FAKE_ROLES='[{"name":"helper","login":false,"inherit":true,"bypassrls":true,"superuser":false,"builder_member":false,"builder_set":false,"builder_inherit":false}]'
check '[[ $status -eq 2 && "$out" == *"helper, which can sign in"* ]] && '"$nothing_dumped" "refused"
run "a fingerprint that is not JSON" FAKE_FINGERPRINT="not json"
check '[[ $status -eq 2 && "$out" == *"did not answer JSON"* ]] && '"$nothing_dumped" "refused"
run "nothing listed of what the fingerprint hashed" FAKE_LISTING=""
check '[[ $status -eq 2 && "$out" == *"listed nothing"* ]] && '"$nothing_dumped" "refused: a restore that differs could not say where"
run "a listing line that is not one" FAKE_LISTING=$'columns\terp.tenant.code\tnot-a-digest'
check '[[ $status -eq 2 && "$out" == *"not <part><TAB><object><TAB><digest> (line 1)"* ]] && '"$nothing_dumped" "refused"
run "a listing naming a part the fingerprint does not hash" FAKE_LISTING=$'columns\terp.tenant.code\t0123456789abcdef\ntriggers\terp.t.tr\t0123456789abcdef'
check '[[ $status -eq 2 && "$out" == *"lists the part(s) triggers that the fingerprint does not hash"* ]] && '"$nothing_dumped" "refused"
run "a listing that cannot be read" FAKE_LISTING_FAIL=1
check '[[ $status -eq 2 && "$out" == *"did not list what its fingerprint hashed"* && "$out" == *"does not exist"* ]] && '"$nothing_dumped" "refused, saying why"

# 5. What fails is said, and no password with it
run "a database that does not answer" FAKE_PSQL_FAIL=1
check '[[ $status -eq 2 && "$out" == *"did not answer"* && "$out" == *"password authentication failed"* ]] && '"$no_secret" \
      "refused, saying why, the connection taken out"
run "a dump that fails" FAKE_DUMP_FAIL=1
check '[[ $status -eq 2 && "$out" == *"could not be dumped"* && ! -e "$work/out/template.dump" && ! -e "$work/out/manifest.json" ]] && '"$no_secret" \
      "refused, the half-written dump removed, the password not printed"

# 6. A template made
run "a database the migrations built, before anything was seeded"
m="$work/out/manifest.json"
check '[[ $status -eq 0 && -s "$work/out/template.dump" && -s "$m" && -s "$work/out/migrations.tsv" && -s "$work/out/fingerprint.tsv" ]] && [[ ! -e "$work/fake/unexpected" ]]' \
      "the dump, the history, the listing and the manifest written, and nothing asked that the rehearsal does not know"
check '[[ "$(cat "$work/out/fingerprint.tsv")" == "$(printf "columns\terp.tenant.code\t0123456789abcdef\nfunctions\terp.f(p_a text)\tfedcba9876543210")" && "$(jq -r ".files[\"fingerprint.tsv\"].sha256" "$m")" == "$(sha256_of "$work/out/fingerprint.tsv")" && "$(jq -r ".files[\"fingerprint.tsv\"].rows" "$m")" == 2 ]]' \
      "the listing of what the fingerprint hashed, one object a line, named in the manifest with its sha256 and rows"
listing_line=$(sed -n "/^LISTING_LINE=\$(cat <<'SQL'\$/,/^SQL\$/p" "$SCRIPT" | sed -n 2p)
check '[[ -n "$listing_line" ]] && grep -qF "select l.line from (select ${listing_line} as line from erp_meta.schema_fingerprint_detail() d) l order by l.line collate \"C\"" "$work/fake/listing.sql" && [[ "$listing_line" == *"translate(d.object, E'"'"'\t\n\r\\\\'"'"', '"'"'    '"'"')"* && "$listing_line" == *"left(encode(sha256(convert_to(coalesce(d.detail, '"'"''"'"'), '"'"'UTF8'"'"')), '"'"'hex'"'"'), 16)"* ]]' \
      "listed byte by byte, each object's name kept to one field (no tab, line break or backslash) and what it is digested"

check 'grep -qx -- "--format=custom" "$work/fake/pg_dump.args" && grep -qx -- "--no-owner" "$work/fake/pg_dump.args" && grep -qx -- "--lock-wait-timeout=60s" "$work/fake/pg_dump.args" && grep -qx -- "--file=$work/out/template.dump" "$work/fake/pg_dump.args"' \
      "a custom-format dump that names no owner and waits a minute at most for a lock"
check '[[ "$(grep -- "^--schema=" "$work/fake/pg_dump.args" | sort | tr "\n" " ")" == "--schema=erp --schema=erp_ai --schema=erp_ingress --schema=erp_meta --schema=erp_ref --schema=erp_test --schema=public " ]]' \
      "every product schema and no other: not auth, storage or the migration history"
check '[[ "$(head -n 1 "$work/fake/pg_dump.args")" == "$URL" ]]' "the database named once, as pg_dump's first argument"
check '[[ "$(cat "$work/out/migrations.tsv")" == "$(printf "0001\tfirst\n20260830091046\tad905a9f-fe00-4810-961e-441bae0f46a0\n20261012070000\ta_client_is_built_from_a_template")" ]]' \
      "the history: every migration's version and name, sorted, as build_from_empty.sh records them"
check '[[ "$(jq -r ".format, .git_sha, .newest_version, .migration_count" "$m" | tr "\n" " ")" == "cloveerp.template.v1 $SHA 20261012070000 3 " ]]' \
      "the manifest names its commit, its newest migration and how many"
check '[[ -s "$work/out/template.dump" && "$(jq -r ".files[\"template.dump\"].sha256" "$m")" == "$(sha256_of "$work/out/template.dump")" && "$(jq -r ".files[\"migrations.tsv\"].sha256" "$m")" == "$(sha256_of "$work/out/migrations.tsv")" && "$(jq -r ".files[\"template.dump\"].bytes" "$m")" == "$(wc -c < "$work/out/template.dump" | tr -d " ")" ]]' \
      "each file's sha256, and the dump's size"
check '[[ "$(jq -c ".fingerprint" "$m")" == "{\"columns\":\"aa\",\"functions\":\"bb\"}" ]] && printf "%s" "{\"columns\":\"aa\",\"functions\":\"bb\"}" > "$work/fp" && [[ "$(jq -r ".fingerprint_sha256" "$m")" == "$(sha256_of "$work/fp")" ]]' \
      "the fingerprint as the database gave it, and the sha256 of its canonical form"
check '[[ "$(jq -r ".extensions | map(.name + \"@\" + .schema) | join(\" \")" "$m")" == "btree_gist@extensions pg_jsonschema@extensions pgcrypto@extensions" && "$(jq -r ".roles[0].name, .roles[0].builder_set, .roles[0].builder_inherit" "$m" | tr "\n" " ")" == "clove_enquiry true false " ]]' \
      "the extensions and the roles a restore must provide"
check '[[ "$(jq -r ".schemas | join(\" \")" "$m")" == "erp erp_ref erp_meta erp_ai erp_test erp_ingress public" ]]' "the schemas it holds"
check '[[ "$out" == *"git_sha=$SHA"* && "$out" == *"newest_version=20261012070000"* && "$out" == *"migration_count=3"* && "$out" == *"dump_sha256=$(sha256_of "$work/out/template.dump")"* && "$out" == *"fingerprint_sha256=$(jq -r .fingerprint_sha256 "$m")"* ]]' \
      "what the workflow reads, one line each"
check "$no_secret"' && [[ -s "$m" ]] && ! grep -q "s3cret-pass" "$m" "$work/out/migrations.tsv"' \
      "no password printed, and none in what it wrote"
check '[[ -s "$work/fake/pg_dump.args" ]] && ! grep -q "supabase_migrations" "$work/fake/pg_dump.args"' \
      "the history is written from the directory, never dumped from a build the CLI did not make"

echo "$CASES checks over the template's making, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
