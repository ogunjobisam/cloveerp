#!/usr/bin/env bash
#
# supabase/ci/template_restore.sh, rehearsed with no database.
#
# It runs for real when a client is built from a template
# (deployment_from_empty.yml) and when template.yml proves one, as postgres,
# into a database that is public while it is built. So here first, against a
# psql that answers from the environment and writes down what it was asked,
# and a pg_restore that keeps what it is given: what it refuses before
# anything is sent (a dump that is not the registered one, a manifest or a
# history that does not agree, migrations that are not this checkout's, a
# database that is not empty, any sign-in but the owner's, a role it does
# not make, a fingerprint that is not the register's), that the restore is
# ONE transaction holding the host's extensions and roles, the host's default
# privileges recorded and switched off before the dump and put back exactly
# after it, the dump less the public schema's creation and every default
# privilege but the product's own, anon taken back and the generators run,
# the fingerprint proved before the history and the owner are written (and,
# when it is not, the objects that differ named, by name only), the owner
# bound to their confirmed sign-in and the staff list checked, and the locks
# counted; that analyze and the platform's schedule come after it, never
# after a failed one, and that it exits 3 for a transaction that did not
# commit; and that no password, and never the owner's whole address, is
# printed. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/template_restore.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

URL="postgresql://postgres.abcdefghijklmnopqrst:s3cret-pass@pooler.example.invalid:5432/postgres"

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi
}

# ── A psql that answers from the environment ─────────────────────────────────
cat > "$work/psql" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/psql.log"
cmd=""; file=""; vars=""; single=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) cmd+="$2"$'\n'; shift 2 ;;
    -f) file="$2"; shift 2 ;;
    -v) vars+="$2"$'\n'; shift 2 ;;
    --single-transaction) single=yes; shift ;;
    *) shift ;;
  esac
done
if [[ -n "$file" ]]; then
  cp "$file" "$FAKE_DIR/restore.sql"
  printf '%s' "$vars" > "$FAKE_DIR/restore.vars"
  echo "$single" > "$FAKE_DIR/restore.single"
  # What \i would include, kept to read.
  body=$(sed -n "s/^\\\\i '\(.*\)'$/\1/p" "$file")
  [[ -z "$body" ]] || cp "$body" "$FAKE_DIR/body.sql"
  if [[ "${FAKE_RESTORE_FAIL:-}" == fingerprint ]]; then
    # As the transaction says a fingerprint that differs: the parts, the
    # restored objects in them, how many, then the refusal.
    echo "template_host_defaults=public functions: anon, authenticated, service_role"
    echo "template_parts=grants,rows"
    printf 'template_listing\tgrants\tfunction public.erp_deployment_for_host(p_host text)\tffffffffffffffff\n'
    printf 'template_listing\tgrants\tfunction public.erp_new_door()\t1111111111111111\n'
    printf 'template_listing\tgrants\tschema erp\t2222222222222222\n'
    printf 'template_listing\trows\terp_ref.resource\t4444444444444444\n'
    echo "template_listed=4"
    echo "psql:/tmp/restore.sql:40: ERROR:  CLOVEERP_TEMPLATE_FINGERPRINT: the restored schema is not the one the template was made from (these parts differ: grants, rows)" >&2
    exit 3
  fi
  if [[ -n "${FAKE_RESTORE_FAIL:-}" ]]; then
    echo "psql:/tmp/restore.sql:12: NOTICE:  something first" >&2
    echo "psql:/tmp/restore.sql:30: ERROR:  ${FAKE_RESTORE_FAIL} on postgresql://postgres.abcdefghijklmnopqrst:s3cret-pass@pooler.example.invalid:5432/postgres" >&2
    echo "DETAIL:  Key (email)=(owner@example.com) is not present." >&2
    exit 3
  fi
  echo "t"
  echo "template_host_defaults=${FAKE_HOST_DEFAULTS:-public functions: anon, authenticated, service_role}"
  echo "template_locks=${FAKE_LOCKS:-2417}"
  touch "$FAKE_DIR/restored"
  exit 0
fi
case "$cmd" in
  *"to_regnamespace('erp') is not null"*) echo "${FAKE_ERP:-f}" ;;
  *"to_regclass('supabase_migrations.schema_migrations') is not null"*) echo "${FAKE_HISTORY:-f}" ;;
  *"count(*) from supabase_migrations.schema_migrations"*)
    if [[ -e "$FAKE_DIR/restored" ]]; then echo "${FAKE_RECORDED_AFTER:-3}"; else echo "${FAKE_RECORDED:-0}"; fi ;;
  *"from erp_meta.platform_staff s where s.revoked_at is null"*) echo "${FAKE_STAFF:-1 1}" ;;
  *"from auth.users"*) echo "${FAKE_USERS:-1 1}" ;;
  *"from pg_catalog.pg_roles where rolname = any"*) echo "${FAKE_PRESENT_ROLES:-}" ;;
  *"select current_user"*) echo "${FAKE_RESTORER:-postgres}" ;;
  *"analyze"*)
    echo "analyze" >> "$FAKE_DIR/after"
    if [[ "${FAKE_AFTER_FAIL:-}" == analyze ]]; then echo "ERROR:  could not analyze" >&2; exit 3; fi ;;
  *"erp.ensure_platform_schedule()"*) echo "ensure_platform_schedule" >> "$FAKE_DIR/after"; echo '{"clove-jobs": "scheduled", "clove-dispatch": "not scheduled: no dispatch URL"}' ;;
  *"erp.ensure_cron_history_pruned()"*) echo "ensure_cron_history_pruned" >> "$FAKE_DIR/after"; echo "scheduled clove-cron-history" ;;
  *) echo "unexpected: $cmd" >> "$FAKE_DIR/unexpected" ;;
esac
exit 0
FAKE
chmod +x "$work/psql"

# ── And a pg_restore that keeps what it is given ─────────────────────────────
cat > "$work/pg_restore" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/pg_restore.log"
if [[ -n "${FAKE_PG_RESTORE_FAIL:-}" ]]; then
  echo "pg_restore: error: unsupported version (1.16) in file header" >&2
  exit 1
fi
list=no; file=""
for a in "$@"; do
  case "$a" in
    --list) list=yes ;;
    --use-list=*) cp "${a#--use-list=}" "$FAKE_DIR/toc.used" ;;
    --file=*) file="${a#--file=}" ;;
  esac
done
if [[ "$list" == yes ]]; then
  if [[ -n "${FAKE_TOC:-}" ]]; then printf '%s\n' "$FAKE_TOC"; exit 0; fi
  cat <<'TOC'
;
; Archive created at 2026-10-12 07:00:00 UTC
;
6; 2615 2200 SCHEMA - public pg_database_owner
7; 2615 16390 SCHEMA - erp postgres
8; 2615 16391 SCHEMA - erp_meta postgres
4021; 0 0 ACL - SCHEMA public pg_database_owner
301; 1259 16400 TABLE erp tenant postgres
4100; 826 16500 DEFAULT ACL erp DEFAULT PRIVILEGES FOR SEQUENCES postgres
4101; 826 16501 DEFAULT ACL public DEFAULT PRIVILEGES FOR TABLES supabase_admin
4102; 826 16502 DEFAULT ACL public DEFAULT PRIVILEGES FOR FUNCTIONS postgres
4103; 826 16503 DEFAULT ACL - DEFAULT PRIVILEGES FOR FUNCTIONS postgres
4104; 826 16504 DEFAULT ACL erp_ref DEFAULT PRIVILEGES FOR TABLES supabase_admin
TOC
  exit 0
fi
printf -- '-- REHEARSAL RESTORE BODY\nselect 1;\n' > "$file"
FAKE
chmod +x "$work/pg_restore"

# Three migrations, named the way the repository names them, and a template
# made from them.
mig="$work/migrations"
mkdir -p "$mig"
echo "select 1;" > "$mig/0001_first.sql"
echo "select 2;" > "$mig/20260830091046_ad905a9f-fe00-4810-961e-441bae0f46a0.sql"
echo "select 3;" > "$mig/20261012070000_a_client_is_built_from_a_template.sql"
later="$work/later_migrations"
mkdir -p "$later"
cp "$mig"/*.sql "$later"/
echo "select 4;" > "$later/20261012080000_one_more.sql"

tpl="$work/template"
mkdir -p "$tpl"
printf 'PGDMP rehearsal template\n' > "$tpl/template.dump"
printf '0001\tfirst\n20260830091046\tad905a9f-fe00-4810-961e-441bae0f46a0\n20261012070000\ta_client_is_built_from_a_template\n' > "$tpl/migrations.tsv"
# What the fingerprint hashed, as template_make.sh lists it: the build's.
{
  printf 'columns\terp.tenant.code\t0123456789abcdef\n'
  printf 'grants\tfunction public.erp_deployment_for_host(p_host text)\taaaaaaaaaaaaaaaa\n'
  printf 'grants\tfunction public.erp_old_door()\tbbbbbbbbbbbbbbbb\n'
  printf 'grants\tschema erp\t2222222222222222\n'
  printf 'rows\terp_ref.resource\t3333333333333333\n'
} > "$tpl/fingerprint.tsv"
DUMP_SHA=$(sha256_of "$tpl/template.dump")
make_manifest() {
  # make_manifest [jq filter]: the manifest template_make.sh writes, changed by the filter.
  jq -n --arg dump "$DUMP_SHA" --arg mig "$(sha256_of "$tpl/migrations.tsv")" --arg listing "$(sha256_of "$tpl/fingerprint.tsv")" '
    {format: "cloveerp.template.v1", git_sha: "0123456789abcdef0123456789abcdef01234567",
     newest_version: "20261012070000", migration_count: 3, made_at: "2026-10-12T07:00:00Z",
     pg_dump: "pg_dump (PostgreSQL) 17.6",
     schemas: ["erp", "erp_ref", "erp_meta", "erp_ai", "erp_test", "erp_ingress", "public"],
     extensions: [{name: "btree_gist", schema: "extensions", version: "1.7"},
                  {name: "pg_jsonschema", schema: "extensions", version: "0.3.3"},
                  {name: "pgcrypto", schema: "extensions", version: "1.3"}],
     roles: [{name: "clove_enquiry", login: false, inherit: false, bypassrls: false, superuser: false,
              builder_member: true, builder_set: true, builder_inherit: false}],
     files: {"template.dump": {sha256: $dump, bytes: 25}, "migrations.tsv": {sha256: $mig, rows: 3},
             "fingerprint.tsv": {sha256: $listing, rows: 5}},
     fingerprint: {columns: "aa", functions: "bb"}, fingerprint_sha256: "ff"}' | jq "${1:-.}" > "$tpl/manifest.json"
}
make_manifest

CASES=0
FAILED=0
run() {
  # run <name> [VAR=value ...]: a fresh fake, the script, its exit and output.
  local name="$1"; shift
  rm -rf "$work/fake"; mkdir -p "$work/fake"
  out=$(env FAKE_DIR="$work/fake" PSQL="$work/psql" PG_RESTORE="$work/pg_restore" MIGRATIONS_DIR="$mig" \
          TEMPLATE_SHA256="$DUMP_SHA" "$@" \
          bash "$SCRIPT" "${TARGET_URL:-$URL}" "${TEMPLATE_DIR:-$tpl}" "${OWNER:-Owner@Example.com}" 2>&1)
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
nothing_asked='[[ ! -s "$work/fake/psql.log" && ! -e "$work/fake/pg_restore.log" ]]'
nothing_restored='[[ ! -e "$work/fake/restore.sql" ]]'
no_secret='[[ "$out" != *"s3cret-pass"* ]]'
# The owner's address is never printed whole, whatever its case.
no_address='[[ "$out" != *"owner@example.com"* && "$out" != *"Owner@Example.com"* ]]'
# line <pattern>: the first line of the transaction's script that holds it.
line() { grep -n -F -- "$1" "$work/fake/restore.sql" | head -n 1 | cut -d: -f1; }
# The fingerprint as the manifest holds it, in another key order.
FP_REGISTERED='{"functions":"bb","columns":"aa"}'

# 1. The dump is the registered one
run "no registered sha256" TEMPLATE_SHA256=
check '[[ $status -eq 2 && "$out" == *"TEMPLATE_SHA256 must be the sha256 the register holds"* ]] && '"$nothing_asked" \
      "refused before anything connects"
run "a dump that is not the registered one" TEMPLATE_SHA256="$(printf '%064d' 7)"
check '[[ $status -eq 2 && "$out" == *"not the 0000000000000000… registered for it"* ]] && '"$nothing_asked" \
      "refused before anything connects"
make_manifest '.files["template.dump"].sha256 = "'"$(printf '%064d' 9)"'"'
run "a manifest naming another dump"
check '[[ $status -eq 2 && "$out" == *"manifest names a different dump"* ]] && '"$nothing_asked" "refused"
make_manifest '.files["migrations.tsv"].sha256 = "'"$(printf '%064d' 9)"'"'
run "a history the manifest does not name"
check '[[ $status -eq 2 && "$out" == *"migrations.tsv is not the one the manifest names"* ]] && '"$nothing_asked" "refused"
make_manifest '.migration_count = 4'
run "a manifest counting otherwise"
check '[[ $status -eq 2 && "$out" == *"the manifest says otherwise"* ]] && '"$nothing_asked" "refused"
make_manifest '.format = "something else"'
run "not a template's manifest"
check '[[ $status -eq 2 && "$out" == *"not a cloveerp.template.v1 manifest"* ]] && '"$nothing_asked" "refused"
make_manifest 'del(.fingerprint)'
run "no fingerprint"
check '[[ $status -eq 2 && "$out" == *"holds no fingerprint"* ]] && '"$nothing_asked" "refused: it could not be proved"
make_manifest '.roles[0].login = true'
run "a role that can sign in"
check '[[ $status -eq 2 && "$out" == *"clove_enquiry, which a restore does not make"* ]] && '"$nothing_asked" "refused"
make_manifest '.extensions[0].name = "x; drop table y"'
run "an extension that is not a name"
check '[[ $status -eq 2 && "$out" == *"will not be written into SQL"* ]] && '"$nothing_asked" "refused"
make_manifest

# 1a. The fingerprint is the register's, and its listing the manifest's
run "the register's fingerprint, in another key order" TEMPLATE_FINGERPRINT="$FP_REGISTERED"
check '[[ $status -eq 0 ]]' "accepted: the same fingerprint, whatever the order of its parts"
run "a fingerprint the register does not hold" TEMPLATE_FINGERPRINT='{"functions":"bb","columns":"ab"}'
check '[[ $status -eq 2 && "$out" == *"not the one the register holds for this template"* ]] && '"$nothing_asked" "refused before anything connects"
run "a registered fingerprint that is not JSON" TEMPLATE_FINGERPRINT='not json'
check '[[ $status -eq 2 && "$out" == *"not the one the register holds"* ]] && '"$nothing_asked" "refused"
mv "$tpl/fingerprint.tsv" "$tpl/fingerprint.kept"
run "no listing of what the fingerprint hashed"
check '[[ $status -eq 2 && "$out" == *"the template has no fingerprint.tsv"* ]] && '"$nothing_asked" "refused"
cp "$tpl/fingerprint.kept" "$tpl/fingerprint.tsv"
printf 'grants\tfunction public.erp_x()\tcccccccccccccccc\n' >> "$tpl/fingerprint.tsv"
run "a listing the manifest does not name"
check '[[ $status -eq 2 && "$out" == *"fingerprint.tsv is not the one the manifest names"* ]] && '"$nothing_asked" "refused"
printf 'grants\tnot a digest\n' > "$tpl/fingerprint.tsv"
make_manifest
run "a listing that is not one"
check '[[ $status -eq 2 && "$out" == *"fingerprint.tsv line 1 is not <part><TAB><object><TAB><digest>"* ]] && '"$nothing_asked" "refused"
mv "$tpl/fingerprint.kept" "$tpl/fingerprint.tsv"
make_manifest
check 'a=$(sed -n "/^LISTING_LINE=\$(cat <<'"'"'SQL'"'"'\$/,/^SQL\$/p" "$HERE/template_make.sh"); b=$(sed -n "/^LISTING_LINE=\$(cat <<'"'"'SQL'"'"'\$/,/^SQL\$/p" "$SCRIPT"); [[ -n "$a" && $(printf "%s\n" "$a" | wc -l) -eq 3 && "$a" == "$b" ]]' \
      "the listing's line is computed by exactly the text template_make.sh lists the template with"

# 2. The migrations are this checkout's
run "a checkout with a migration the template lacks" MIGRATIONS_DIR="$later"
check '[[ $status -eq 2 && "$out" == *"not this checkout"* && "$out" == *"20261012080000 one_more"* ]] && '"$nothing_asked" \
      "refused, naming the first difference"
OWNER="not-an-address" run "an owner that is not an email address"
check '[[ $status -eq 2 && "$out" == *"is not an email address"* && "$out" != *"not-an-address"* ]] && '"$nothing_asked" \
      "refused before anything connects, and what was given not repeated"

# 3. The database is empty, and the owner's sign-in the only one
run "a database with an erp schema" FAKE_ERP=t
check '[[ $status -eq 2 && "$out" == *"already has an erp schema"* ]] && '"$nothing_restored" "refused, and nothing restored"
run "a database with migrations recorded" FAKE_HISTORY=t FAKE_RECORDED=5
check '[[ $status -eq 2 && "$out" == *"already records 5 migration"* ]] && '"$nothing_restored" "refused, and nothing restored"
run "another sign-in" FAKE_USERS="2 1"
check '[[ $status -eq 2 && "$out" == *"exactly one sign-in, the owner'"'"'s (o…@example.com)"* ]] && '"$nothing_restored"' && '"$no_address" \
      "refused, nothing restored, and the owner named only as o…@example.com"
run "the owner's address not confirmed" FAKE_USERS="1 0"
check '[[ $status -eq 2 && "$out" == *"exactly one sign-in"* ]] && '"$nothing_restored" "refused, and nothing restored"
check 'grep -q "lower(email) = '"'"'owner@example.com'"'"'" "$work/fake/psql.log"' "the owner is looked for by their address, in lower case"
run "a dump pg_restore cannot read" FAKE_PG_RESTORE_FAIL=1
check '[[ $status -eq 2 && "$out" == *"pg_restore could not read the template"* ]] && '"$nothing_restored" "refused, and nothing restored"
run "a dump that is not the product's" FAKE_TOC=$'6; 2615 2200 SCHEMA - public pg_database_owner\n7; 2615 16390 SCHEMA - other postgres'
check '[[ $status -eq 2 && "$out" == *"creates no erp schema"* ]] && '"$nothing_restored" "refused, and nothing restored"

# 4. Restored
run "an empty database, the owner's sign-in the only one"
check '[[ $status -eq 0 && "$(cat "$work/fake/restore.single")" == yes && $(grep -c -- "-f " "$work/fake/psql.log") -eq 1 ]] && [[ ! -e "$work/fake/unexpected" ]]' \
      "one transaction, one script, and nothing asked that the rehearsal does not know"
check 'grep -qx "tmpl_owner=owner@example.com" "$work/fake/restore.vars" && grep -qx "tmpl_fingerprint={\"columns\":\"aa\",\"functions\":\"bb\"}" "$work/fake/restore.vars" && grep -qx "tmpl_schemas=erp erp_ref erp_meta erp_ai erp_test erp_ingress public" "$work/fake/restore.vars" && grep -qx "ON_ERROR_STOP=1" "$work/fake/restore.vars"' \
      "the owner, the fingerprint and the schemas reach it as psql variables, and the first error stops it"
check '[[ "$(sed -n 2p "$work/fake/restore.sql")" == "set statement_timeout = 0;" ]]' "the timeout off before anything else"
check 'grep -qx "create extension if not exists pg_jsonschema with schema extensions;" "$work/fake/restore.sql" && grep -qx "create extension if not exists pgcrypto with schema extensions;" "$work/fake/restore.sql" && grep -qx "create extension if not exists btree_gist with schema extensions;" "$work/fake/restore.sql"' \
      "the extensions the migrations create, where they created them"
check 'grep -qx "create role clove_enquiry nologin nobypassrls noinherit;" "$work/fake/restore.sql" && grep -qx "grant clove_enquiry to current_user with set true, inherit false;" "$work/fake/restore.sql"' \
      "the product's role, made as its migration made it, and the restorer able to become it"
check '[[ -s "$work/fake/body.sql" && "$(head -n 1 "$work/fake/body.sql")" == "-- REHEARSAL RESTORE BODY" ]] && grep -q -- "--no-owner" "$work/fake/pg_restore.log"' \
      "the dump's own script, written by pg_restore with no owner, included in the transaction"
check '! grep -q "SCHEMA - public" "$work/fake/toc.used" && grep -q "ACL - SCHEMA public" "$work/fake/toc.used" && grep -q "SCHEMA - erp postgres" "$work/fake/toc.used"' \
      "everything restored but the public schema's own creation, which the host has"
check 'grep -q "DEFAULT ACL erp DEFAULT PRIVILEGES FOR SEQUENCES postgres" "$work/fake/toc.used" && [[ $(grep -c " DEFAULT ACL " "$work/fake/toc.used") -eq 1 ]] && [[ "$out" == *"4 default privilege(s) the build host had (another role'"'"'s, public'"'"'s or every schema'"'"'s) are left to this host"* ]]' \
      "of the default privileges in the dump only the product's own kept (the restorer's, in a product schema); another role's, public's and every schema's left to this host, and said"
check 'grep -q "create temp table template_host_defaults on commit drop as" "$work/fake/restore.sql" && grep -q "from pg_catalog.pg_default_acl d" "$work/fake/restore.sql" && grep -q "d.defaclrole = (select r.oid from pg_catalog.pg_roles r where r.rolname = current_user)" "$work/fake/restore.sql" && grep -q "and (d.defaclnamespace = 0" "$work/fake/restore.sql" && grep -q "string_to_array(current_setting('"'"'cloveerp.template_schemas'"'"'), '"'"' '"'"')" "$work/fake/restore.sql"' \
      "the restoring role's default privileges recorded: in the dumped schemas, public among them, and in every schema"
check 'grep -q "alter default privileges for role %I%s revoke all on %s from %I" "$work/fake/restore.sql" && grep -q "alter default privileges for role %I%s grant %s on %s to %I%s" "$work/fake/restore.sql" && [[ $(grep -c "g.rolname in ('"'"'anon'"'"', '"'"'authenticated'"'"', '"'"'service_role'"'"')" "$work/fake/restore.sql") -eq 3 ]] && [[ $(grep -c "h.objtype in ('"'"'f'"'"', '"'"'r'"'"', '"'"'S'"'"')" "$work/fake/restore.sql") -eq 3 ]] && grep -q "when '"'"'f'"'"' then '"'"'functions'"'"' when '"'"'r'"'"' then '"'"'tables'"'"' else '"'"'sequences'"'"'" "$work/fake/restore.sql"' \
      "switched off for anon, authenticated and service_role on functions, tables and sequences, and granted back exactly, with any grant option"
check 'grep -q "CLOVEERP_TEMPLATE_DEFAULTS: the host'"'"''"'"'s default privileges were not put back as they were" "$work/fake/restore.sql" && grep -q "select \* from before_restore except select \* from after_restore" "$work/fake/restore.sql" && grep -q "select \* from after_restore except select \* from before_restore" "$work/fake/restore.sql"' \
      "and the transaction refused unless they are exactly as they were, privilege by privilege, both ways"
check '[[ "$out" == *"the host'"'"'s default privileges (public functions: anon, authenticated, service_role) were switched off while the dump ran, and put back as they were"* ]]' \
      "it says which default privileges it switched off and put back"
run "a host that gives anon, authenticated and service_role nothing by default" FAKE_HOST_DEFAULTS=none
check '[[ $status -eq 0 && "$out" == *"gives anon, authenticated and service_role nothing by default here, so nothing was switched off"* ]]' \
      "restored, and said so rather than claiming to have switched anything off"
run "a host that answers as a role that cannot be named" FAKE_RESTORER='Robert"; drop'
check '[[ $status -eq 2 && "$out" == *"not a role this can name"* ]] && '"$nothing_restored" "refused, and nothing restored"
run "an empty database, the owner's sign-in the only one"
check 'grep -qx "revoke all on all functions in schema erp, erp_ref, erp_meta, erp_ai, erp_test, erp_ingress, public from anon;" "$work/fake/restore.sql"' \
      "anon taken back from every product function"
check '[[ "$(grep -o "^select erp\.apply_[a-z_]*()" "$work/fake/restore.sql" | tr "\n" " ")" == "select erp.apply_row_security() select erp.apply_platform_internal_security() select erp.apply_append_only_guards() select erp.apply_attribution_triggers() select erp.apply_audit_coverage() select erp.apply_live_config_guards() select erp.apply_execute_grants() " ]]' \
      "the seven generators, in the order every migration runs them"
check 'grep -q "CLOVEERP_TEMPLATE_FINGERPRINT" "$work/fake/restore.sql" && grep -q "select erp_meta.schema_fingerprint() as have, current_setting('"'"'cloveerp.template_fingerprint'"'"')::jsonb as want;" "$work/fake/restore.sql" && grep -q "if v_have is distinct from v_want then" "$work/fake/restore.sql"' \
      "the fingerprint compared with the manifest's as jsonb, refusing the transaction when they differ"
check 'grep -q "from erp_meta.schema_fingerprint_detail() d, pg_temp.template_restored r" "$work/fake/restore.sql" && grep -q "where (r.have -> d.part) is distinct from (r.want -> d.part);" "$work/fake/restore.sql" && grep -q "if exists (select 1 from pg_temp.template_restored r where r.have is distinct from r.want) then" "$work/fake/restore.sql"' \
      "the objects listed only when it differs, and only in the parts that differ"
check 'grep -qx "  ('"'"'0001'"'"', '"'"'first'"'"', '"'"'{}'"'"'::text\[\])," "$work/fake/restore.sql" && grep -qx "  ('"'"'20261012070000'"'"', '"'"'a_client_is_built_from_a_template'"'"', '"'"'{}'"'"'::text\[\]);" "$work/fake/restore.sql" && [[ $(grep -c "::text\[\])[,;]$" "$work/fake/restore.sql") -eq 3 ]]' \
      "every migration recorded as build_from_empty.sh records it: version, name, no statements"
check 'grep -q "insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)" "$work/fake/restore.sql" && grep -q "u.email_confirmed_at is not null" "$work/fake/restore.sql" && grep -q "CLOVEERP_TEMPLATE_OWNER" "$work/fake/restore.sql"' \
      "the owner on the staff list, bound to their confirmed sign-in, and the list refused unless it is exactly them"
o_ext=$(line "create extension"); o_role=$(line "create role"); o_rec=$(line "create temp table template_host_defaults")
o_off=$(line '$defaults_off$;'); o_dump=$(line "\\i '"); o_back=$(line '$defaults_back$;'); o_revoke=$(line "from anon;")
o_gen=$(line "select erp.apply_execute_grants();"); o_fp=$(line "CLOVEERP_TEMPLATE_FINGERPRINT"); o_hist=$(line "insert into supabase_migrations")
o_owner=$(line "insert into erp_meta.platform_staff"); o_locks=$(line "template_locks=")
check '[[ -n "$o_locks" && -n "$o_rec" && -n "$o_off" && -n "$o_back" && $o_ext -lt $o_role && $o_role -lt $o_rec && $o_rec -lt $o_off && $o_off -lt $o_dump && $o_dump -lt $o_back && $o_back -lt $o_revoke && $o_revoke -lt $o_gen && $o_gen -lt $o_fp && $o_fp -lt $o_hist && $o_hist -lt $o_owner && $o_owner -lt $o_locks ]]' \
      "in order: the host, its default privileges recorded and switched off, the dump, them put back, the grants, the proof, then the history and the owner, the locks counted last"
check '[[ "$(tr "\n" " " < "$work/fake/after")" == "analyze ensure_platform_schedule ensure_cron_history_pruned " ]]' \
      "afterwards, outside the transaction: analyze, then the platform's schedule and its run history"
check 'n_f=$(grep -n -- "-f " "$work/fake/psql.log" | cut -d: -f1); n_a=$(grep -n -- "-c analyze" "$work/fake/psql.log" | cut -d: -f1); [[ -n "$n_a" && $n_f -lt $n_a ]]' \
      "and only after the transaction committed"
check '[[ "$out" == *"held 2417 lock(s) as it committed"* && "$out" == *"template_locks=2417"* && "$out" == *"restored: 3 migration(s) recorded, the newest 20261012070000"* && "$out" == *"o…@example.com is the platform"* ]]' \
      "it says what it restored, for whom, and how many locks the transaction held"
check "$no_secret"' && '"$no_address" "no password printed, and the owner's address never whole"
run "a role the host already has" FAKE_PRESENT_ROLES="clove_enquiry"
check '[[ $status -eq 0 ]] && ! grep -q "^create role" "$work/fake/restore.sql" && grep -qx "grant clove_enquiry to current_user with set true, inherit false;" "$work/fake/restore.sql"' \
      "not made again, and the restorer still able to become it"
make_manifest '.roles += [.roles[0] + {builder_set: false}]'
run "a role the manifest lists twice"
check '[[ $status -eq 0 && $(grep -c "^create role clove_enquiry " "$work/fake/restore.sql") -eq 1 && $(grep -c "^grant clove_enquiry to current_user" "$work/fake/restore.sql") -eq 1 ]] && grep -qx "grant clove_enquiry to current_user with set true, inherit false;" "$work/fake/restore.sql"' \
      "made once and granted once, with what either entry gave"
make_manifest

# 5. A restore that does not hold
run "a transaction that is refused" FAKE_RESTORE_FAIL="CLOVEERP_TEMPLATE_DEFAULTS: the host's default privileges were not put back as they were (gained public r authenticated=SELECT)"
check '[[ $status -eq 3 && "$out" == *"nothing of it was kept: it was one transaction"* && "$out" == *"CLOVEERP_TEMPLATE_DEFAULTS"* && "$out" != *"NOTICE"* ]] && [[ ! -e "$work/fake/after" ]]' \
      "exit 3, said from its ERROR on, and nothing run after it"
check "$no_secret"' && '"$no_address"' && [[ "$out" == *"(email)=(o…@example.com)"* ]]' \
      "the connection taken out of what it said, and the owner's address as the log may show it"
run "a fingerprint that is not the template's" FAKE_RESTORE_FAIL=fingerprint
check '[[ $status -eq 3 && "$out" == *"these parts differ: grants, rows"* && "$out" == *"4 object(s) in the parts that differ (grants, rows) are not as the template made them"* ]]' \
      "exit 3, the parts named, and how many objects in them differ"
check '[[ "$out" == *"grants  function public.erp_deployment_for_host(p_host text)  (not as the template made it)"* && "$out" == *"grants  function public.erp_new_door()  (not in the template)"* && "$out" == *"grants  function public.erp_old_door()  (missing from the restore)"* && "$out" == *"rows  erp_ref.resource  (not as the template made it)"* ]]' \
      "each object named: not as made, only in the restore, or missing from it"
check '[[ "$out" != *"erp.tenant.code"* && "$out" != *"schema erp  "* && "$out" != *"ffffffffffffffff"* && "$out" != *"aaaaaaaaaaaaaaaa"* && "$out" != *"4444444444444444"* && "$out" != *"template_listing"* ]] && [[ ! -e "$work/fake/after" ]]' \
      "names only: no digest, no listing line, nothing from a part that is the same or an object that is; nothing run after it"
run "a staff list that is not the owner afterwards" FAKE_STAFF="2 1"
check '[[ $status -eq 1 && "$out" == *"is not exactly o…@example.com"* ]] && '"$no_address" "exit 1: a restore that leaves anybody but the owner is not finished"
run "a history short afterwards" FAKE_RECORDED_AFTER=2
check '[[ $status -eq 1 && "$out" == *"2 migration(s) are recorded, not 3"* ]]' "exit 1, as a committed restore"
run "analyze failing afterwards" FAKE_AFTER_FAIL=analyze
check '[[ $status -eq 1 && "$out" == *"the template is restored, and then this failed: analyze"* ]]' "exit 1, said as a committed restore"

echo "$CASES checks over the template's restore, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
