#!/usr/bin/env bash
#
# A client's template: the product's schemas as the migrations build them,
# dumped once in CI so a new client's database is restored from it rather
# than built by replaying every migration (.github/workflows/template.yml
# makes one after the schema build passes on main; deployment_from_empty.yml
# restores one with supabase/ci/template_restore.sh).
#
# A replay of every migration took 3 h 25 for the demonstration on a Micro
# instance, and grows with each migration. The template is the same schema in
# one restore. It is made from the database the schema build makes from the
# migrations, before any demonstration goes in (the owner's decision of 9
# October): never from the demonstration or any live database, which carry a
# kind, a project, an owner and a year of somebody's trading.
#
# So it refuses a database holding anything that belongs to one deployment and
# not to the product:
#
#   an organisation     erp.tenant: somebody's business, which a template
#                       would hand to every client built from it;
#   a staff row         erp_meta.platform_staff, revoked or not: the console
#                       of every client would open to whoever is on it;
#   a release           erp_meta.release: what was released where;
#   a deployment.*      erp_meta.platform_setting: the kind, project and
#     setting           address a deployment is told once and never again
#                       (mark_deployment, set_deployment_identity), which a
#                       restored client could then never be told;
#   a register row      erp_meta.deployment: the control plane's clients.
#
# And a database that is not what the migrations here build: a migration
# history that is not this directory's, a product schema or extension
# missing, a migration creating a schema the template does not dump, an
# extension living inside a dumped schema (pg_dump would leave its objects
# out), a role the product's grants name that can sign in or bypass row
# security (a restore does not make one), or no erp_meta.schema_fingerprint()
# (20261012070000), which is how a restore proves it is what was made.
#
# What it writes into <out dir>, which must be empty or absent:
#
#   template.dump    pg_dump, custom format, of the product's schemas (erp,
#                    erp_ref, erp_meta, erp_ai, erp_test, erp_ingress,
#                    public), their grants included and no owner named;
#   migrations.tsv   <version><TAB><name> for every file in the migrations
#                    directory, sorted: the history the Supabase CLI reads,
#                    exactly as build_from_empty.sh records it;
#   fingerprint.tsv  what erp_meta.schema_fingerprint_detail() hashed, one
#                    object a line: its part, its name and a digest of what it
#                    is. Never what decides a restore (the fingerprint does);
#                    what names the objects that differ when one does not
#                    reproduce it (template_restore.sh);
#   manifest.json    what was dumped, from which commit, each file's sha256,
#                    the extensions and roles the restore must provide, and
#                    the fingerprint the restore must reproduce.
#
# The template holds only what the public migrations already say: no
# connection string, key or password is in it, and nothing here prints one.
#
# Usage: template_make.sh <database url> <out dir>
#
# Prints, last, one line each: git_sha=, newest_version=, migration_count=,
# dump_sha256=, fingerprint_sha256= (for the workflow to read).
#
# Environment:
#   GIT_SHA         required: the commit whose migrations built the database
#   MIGRATIONS_DIR  the migrations (default: supabase/migrations beside this)
#   PSQL, PG_DUMP   the commands (default psql, pg_dump; the rehearsal's
#                   stand-ins). pg_dump must be at least the server's version
#
# bash 3.2 and 5: supabase/ci/template_make_rehearsal.sh runs it on a Mac as
# well as on a runner. No mapfile.
set -euo pipefail

DB="${1:?usage: template_make.sh <database url> <out dir>}"
OUT="${2:?usage: template_make.sh <database url> <out dir>}"
PSQL_CMD="${PSQL:-psql}"
PG_DUMP_CMD="${PG_DUMP:-pg_dump}"
GIT_SHA="${GIT_SHA:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$HERE/../migrations}"

# The product's schemas, as restore_drill.yml and fleet_offsite.sh dump them,
# less supabase_migrations: the build the template is made from was not made
# by the CLI, so its history is written from the directory instead.
TEMPLATE_SCHEMAS="erp erp_ref erp_meta erp_ai erp_test erp_ingress public"
# The extensions the migrations create (00_host_bootstrap.sql says which and
# where). pg_dump never carries an extension in a dump of some schemas, so the
# restore creates each first.
TEMPLATE_EXTENSIONS="pgcrypto pg_jsonschema btree_gist"
# Schemas a migration may create that belong to the host, not the product.
HOST_SCHEMAS="supabase_migrations vault extensions auth storage cron net graphql graphql_public realtime pgbouncer"
# One line a fingerprinted object: its part, its name and a digest of what it
# is. template_restore.sh computes the same line over what it restored
# (template_restore_rehearsal.sh holds the two to the same text).
LISTING_LINE=$(cat <<'SQL'
d.part || E'\t' || translate(d.object, E'\t\n\r\\', '    ') || E'\t' || left(encode(sha256(convert_to(coalesce(d.detail, ''), 'UTF8')), 'hex'), 16)
SQL
)

refuse() {
  echo "x $*" >&2
  exit 2
}

# Whatever a command said, with the connection string and its password taken
# out, on one line.
PASSWORD_IN_URL=""
if [[ "$DB" =~ ^[a-z]+://[^:/@]+:([^@]+)@ ]]; then PASSWORD_IN_URL="${BASH_REMATCH[1]}"; fi
redact() {
  local text="$1"
  text="${text//"${DB}"/[the database]}"
  if [[ -n "$PASSWORD_IN_URL" ]]; then text="${text//"${PASSWORD_IN_URL}"/[hidden]}"; fi
  printf '%s' "$text" | tr -s ' \t\r\n' '    ' | cut -c 1-400
}

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

in_list() {
  local item="$1" each
  shift
  for each in $*; do [[ "$each" == "$item" ]] && return 0; done
  return 1
}

# ── What is asked for ────────────────────────────────────────────────────────
[[ "$DB" =~ ^postgres(ql)?:// ]] || refuse "the first argument is not a database URL (postgresql://...)."
[[ "$GIT_SHA" =~ ^[0-9a-f]{40}$ ]] ||
  refuse "GIT_SHA must be the full commit the database was built from (forty hex characters); a template names its migrations by it."
[[ -d "$MIGRATIONS_DIR" ]] || refuse "$MIGRATIONS_DIR is not a directory of migrations."
if [[ -e "$OUT" && -n "$(ls -A "$OUT" 2> /dev/null)" ]]; then
  refuse "$OUT is not empty; a template is written into an empty directory, so nothing of another is mixed into it."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── The migrations, read without a database ──────────────────────────────────
# Named as build_from_empty.sh names them when it records each one, so the
# restored history is the one a replay would have written.
: > "$work/migrations.unsorted"
for f in "$MIGRATIONS_DIR"/*.sql; do
  [[ -e "$f" ]] || refuse "$MIGRATIONS_DIR holds no migration."
  base="$(basename "$f")"
  if ! [[ "$base" =~ ^([0-9]+)_([A-Za-z0-9_-]+)\.sql$ ]]; then
    refuse "$base is not named <version>_<name>.sql, so it cannot be recorded the way the CLI records it."
  fi
  printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "$work/migrations.unsorted"
done
LC_ALL=C sort "$work/migrations.unsorted" > "$work/migrations.tsv"
dupes=$(cut -f 1 "$work/migrations.tsv" | uniq -d | head -n 3 | tr '\n' ' ')
[[ -z "$dupes" ]] || refuse "more than one migration claims the version(s) ${dupes% }; the history cannot hold both."
count=$(grep -c . "$work/migrations.tsv" | tr -d ' ')
newest=$(tail -n 1 "$work/migrations.tsv" | cut -f 1)

# A schema a migration creates that the template does not dump would be
# missing from every client built from it, and nothing else would say so.
unknown=""
for s in $(grep -hoiE 'create[[:space:]]+schema([[:space:]]+if[[:space:]]+not[[:space:]]+exists)?[[:space:]]+"?[A-Za-z_][A-Za-z0-9_]*' "$MIGRATIONS_DIR"/*.sql \
             | awk '{ s = $NF; gsub(/"/, "", s); print tolower(s) }' | LC_ALL=C sort -u); do
  in_list "$s" "$TEMPLATE_SCHEMAS" || in_list "$s" "$HOST_SCHEMAS" || unknown="${unknown} ${s}"
done
[[ -z "$unknown" ]] ||
  refuse "a migration creates the schema(s)${unknown}, which the template does not dump and the host does not provide; add each to TEMPLATE_SCHEMAS here (and to restore_drill.yml's list) before a template is made."

# ── The database ─────────────────────────────────────────────────────────────
# ask <statement>: the answer, one row a line. A database that will not answer
# is a refusal that says what it said, with the connection taken out of it.
ask() {
  local out
  if ! out=$($PSQL_CMD "$DB" -v ON_ERROR_STOP=1 -X -q -tA -c "$1" 2> "$work/psql.err"); then
    refuse "the database did not answer ($(redact "$(cat "$work/psql.err")"))."
  fi
  printf '%s\n' "$out"
}

shape=$(ask "select concat_ws(' ',
  to_regclass('erp.tenant') is not null,
  to_regclass('erp_meta.platform_staff') is not null,
  to_regclass('erp_meta.release') is not null,
  to_regclass('erp_meta.platform_setting') is not null,
  to_regclass('erp_meta.deployment') is not null,
  to_regclass('supabase_migrations.schema_migrations') is not null,
  to_regprocedure('erp_meta.schema_fingerprint()') is not null)")
read -r has_tenant has_staff has_release has_setting has_register has_history has_fingerprint <<< "$shape"
[[ "$has_tenant" == t && "$has_staff" == t && "$has_release" == t && "$has_setting" == t ]] ||
  refuse "this is not a database the migrations built: erp.tenant, erp_meta.platform_staff, erp_meta.release or erp_meta.platform_setting is missing."

# Everything one deployment holds and the product does not, said at once.
held=$(ask "select (select count(*) from erp.tenant) || ' ' || (select count(*) from erp_meta.platform_staff) || ' ' || (select count(*) from erp_meta.release)")
read -r tenants staff releases <<< "$held"
settings=$(ask "select coalesce(string_agg(s.key, ', ' order by s.key), '') from erp_meta.platform_setting s where s.key like 'deployment.%'")
register=0
if [[ "$has_register" == t ]]; then
  register=$(ask "select count(*) from erp_meta.deployment")
fi
why=""
[[ "$tenants" == 0 ]] || why="${why}; ${tenants} organisation(s)"
[[ "$staff" == 0 ]] || why="${why}; ${staff} platform staff row(s)"
[[ "$releases" == 0 ]] || why="${why}; ${releases} release row(s)"
[[ -z "$settings" ]] || why="${why}; the setting(s) ${settings}"
[[ "$register" == 0 ]] || why="${why}; ${register} deployment(s) in the register"
if [[ -n "$why" ]]; then
  refuse "this database holds ${why#; }. A template carries only what the migrations build, because every client is restored from it; make it from the schema build's database before anything is seeded (template.yml does)."
fi

if [[ "$has_history" == t ]]; then
  ask "select version from supabase_migrations.schema_migrations" > "$work/recorded.unsorted"
  LC_ALL=C sort "$work/recorded.unsorted" | sed '/^$/d' > "$work/recorded"
  if ! cut -f 1 "$work/migrations.tsv" | diff -q - "$work/recorded" > /dev/null; then
    refuse "this database records a migration history that is not the migrations directory's ($(wc -l < "$work/recorded" | tr -d ' ') recorded, ${count} here); it was not built from these migrations."
  fi
fi

[[ "$has_fingerprint" == t ]] ||
  refuse "this database has no erp_meta.schema_fingerprint(), so a restore could not prove it is what was made; it predates 20261012070000."

missing=$(ask "select coalesce(string_agg(s, ' ' order by s), '') from unnest(string_to_array('${TEMPLATE_SCHEMAS}', ' ')) s where to_regnamespace(s) is null")
[[ -z "$missing" ]] || refuse "the product schema(s) ${missing} are missing; this is not a database the migrations built."

extensions=$(ask "select coalesce(json_agg(json_build_object('name', e.extname, 'schema', n.nspname, 'version', e.extversion) order by e.extname), '[]')
  from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
 where e.extname = any (string_to_array('${TEMPLATE_EXTENSIONS}', ' '))")
for e in $TEMPLATE_EXTENSIONS; do
  jq -e --arg e "$e" 'any(.[]; .name == $e)' <<< "$extensions" > /dev/null ||
    refuse "the extension ${e} is not in this database, and the migrations create it; a template made from it would not be what a replay builds."
done
inside=$(ask "select coalesce(string_agg(e.extname || ' (in ' || n.nspname || ')', ', ' order by e.extname), '')
  from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
 where n.nspname = any (string_to_array('${TEMPLATE_SCHEMAS}', ' '))")
[[ -z "$inside" ]] ||
  refuse "the extension(s) ${inside} live in a schema the template dumps; pg_dump leaves an extension's objects out of such a dump, so a client restored from it would lack them."

# The roles the product's grants name that the host does not provide: the
# restore makes each, as the migration that first made it did. Never one that
# can sign in or bypass row security.
roles=$(ask "with schemas as (
    select n.oid from pg_catalog.pg_namespace n where n.nspname = any (string_to_array('${TEMPLATE_SCHEMAS}', ' '))
  ), grantees as (
    select (aclexplode(p.proacl)).grantee g from pg_catalog.pg_proc p where p.pronamespace in (select oid from schemas) and p.proacl is not null
    union select (aclexplode(c.relacl)).grantee from pg_catalog.pg_class c where c.relnamespace in (select oid from schemas) and c.relacl is not null
    union select (aclexplode(t.typacl)).grantee from pg_catalog.pg_type t where t.typnamespace in (select oid from schemas) and t.typacl is not null
    union select (aclexplode(n.nspacl)).grantee from pg_catalog.pg_namespace n where n.oid in (select oid from schemas) and n.nspacl is not null
    union select (aclexplode(d.defaclacl)).grantee from pg_catalog.pg_default_acl d where d.defaclnamespace in (select oid from schemas)
  )
  select coalesce(json_agg(json_build_object(
           'name', r.rolname, 'login', r.rolcanlogin, 'inherit', r.rolinherit,
           'bypassrls', r.rolbypassrls, 'superuser', r.rolsuper,
           'builder_member', m.roleid is not null,
           'builder_set', coalesce(m.set_option, false), 'builder_inherit', coalesce(m.inherit_option, false))
         order by r.rolname), '[]')
    from pg_catalog.pg_roles r
    join (select distinct g from grantees where g <> 0) a on a.g = r.oid
    left join pg_catalog.pg_auth_members m on m.roleid = r.oid and m.member = (select oid from pg_catalog.pg_roles where rolname = current_user)
   where r.rolname not in ('postgres', 'anon', 'authenticated', 'service_role', 'authenticator', 'dashboard_user', 'pgbouncer')
     and r.rolname !~ '^(pg_|supabase_)'")
bad_roles=$(jq -r '[.[] | select(.login or .bypassrls or .superuser) | .name] | join(", ")' <<< "$roles")
[[ -z "$bad_roles" ]] ||
  refuse "the product's grants name the role(s) ${bad_roles}, which can sign in or bypass row security; a restore does not make such a role, so a template is not made with one in it."
odd_roles=$(jq -r '[.[] | select(.name | test("^[a-z_][a-z0-9_]*$") | not) | .name] | join(", ")' <<< "$roles")
[[ -z "$odd_roles" ]] || refuse "the product's grants name the role(s) ${odd_roles}, whose names a restore will not write into SQL."

fingerprint=$(ask "select erp_meta.schema_fingerprint()::text")
printf '%s' "$fingerprint" | jq -e . > /dev/null 2>&1 ||
  refuse "erp_meta.schema_fingerprint() did not answer JSON, so it cannot be kept in the manifest."
# Its sha256 is of the canonical form: keys sorted, compact, no newline.
printf '%s' "$fingerprint" | jq -cS . | tr -d '\n' > "$work/fingerprint.json"
fingerprint_sha256=$(sha256_of "$work/fingerprint.json")
# And what it hashed, object by object, sorted byte by byte.
if ! $PSQL_CMD "$DB" -v ON_ERROR_STOP=1 -X -q -tA \
       -c "select l.line from (select ${LISTING_LINE} as line from erp_meta.schema_fingerprint_detail() d) l order by l.line collate \"C\"" \
       > "$work/fingerprint.tsv" 2> "$work/psql.err"; then
  refuse "the database did not list what its fingerprint hashed ($(redact "$(cat "$work/psql.err")"))."
fi
sed -i.bak '/^$/d' "$work/fingerprint.tsv" && rm -f "$work/fingerprint.tsv.bak"
listed=$(grep -c . "$work/fingerprint.tsv" | tr -d ' ' || true)
[[ "${listed:-0}" -gt 0 ]] || refuse "erp_meta.schema_fingerprint_detail() listed nothing, so a restore that differs could not say where."
bad_line=$(grep -nvE $'^[a-z_]+\t[^\t]+\t[0-9a-f]{16}$' "$work/fingerprint.tsv" | head -n 1 || true)
[[ -z "$bad_line" ]] || refuse "erp_meta.schema_fingerprint_detail() listed a line that is not <part><TAB><object><TAB><digest> (line ${bad_line%%:*})."
unlisted=$(cut -f 1 "$work/fingerprint.tsv" | LC_ALL=C sort -u | while read -r part; do
             jq -e --arg p "$part" 'has($p)' "$work/fingerprint.json" > /dev/null || printf '%s ' "$part"
           done)
[[ -z "$unlisted" ]] || refuse "erp_meta.schema_fingerprint_detail() lists the part(s) ${unlisted% } that the fingerprint does not hash."

# ── The dump ─────────────────────────────────────────────────────────────────
schemas=()
for s in $TEMPLATE_SCHEMAS; do schemas+=("--schema=${s}"); done
mkdir -p "$OUT"
if ! err=$($PG_DUMP_CMD "$DB" --format=custom --no-owner --no-security-labels --no-publications --no-subscriptions \
             --lock-wait-timeout=60s "${schemas[@]}" --file="$OUT/template.dump" 2>&1); then
  rm -f "$OUT/template.dump"
  refuse "the product's schemas could not be dumped ($(redact "$err"))."
fi
[[ -s "$OUT/template.dump" ]] || { rm -f "$OUT/template.dump"; refuse "pg_dump wrote nothing."; }
dump_sha256=$(sha256_of "$OUT/template.dump")
dump_bytes=$(wc -c < "$OUT/template.dump" | tr -d ' ')
version=$($PG_DUMP_CMD --version 2> /dev/null | head -n 1 || true)

cp "$work/migrations.tsv" "$OUT/migrations.tsv"
migrations_sha256=$(sha256_of "$OUT/migrations.tsv")
cp "$work/fingerprint.tsv" "$OUT/fingerprint.tsv"
listing_sha256=$(sha256_of "$OUT/fingerprint.tsv")

jq -n --arg git_sha "$GIT_SHA" --arg newest "$newest" --argjson count "$count" \
      --arg made "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pg_dump "$version" --arg schemas "$TEMPLATE_SCHEMAS" \
      --argjson extensions "$extensions" --argjson roles "$roles" \
      --arg dump_sha "$dump_sha256" --argjson dump_bytes "$dump_bytes" --arg mig_sha "$migrations_sha256" \
      --arg listing_sha "$listing_sha256" --argjson listed "$listed" \
      --slurpfile fingerprint "$work/fingerprint.json" --arg fp_sha "$fingerprint_sha256" \
  '{format: "cloveerp.template.v1", git_sha: $git_sha, newest_version: $newest, migration_count: $count,
    made_at: $made, pg_dump: $pg_dump, schemas: ($schemas | split(" ")),
    extensions: $extensions, roles: $roles,
    files: {"template.dump": {sha256: $dump_sha, bytes: $dump_bytes},
            "migrations.tsv": {sha256: $mig_sha, rows: $count},
            "fingerprint.tsv": {sha256: $listing_sha, rows: $listed}},
    fingerprint: $fingerprint[0], fingerprint_sha256: $fp_sha}' > "$OUT/manifest.json"

echo "- dumped ${TEMPLATE_SCHEMAS// /, }: ${dump_bytes} bytes"
echo "- ${count} migrations, the newest ${newest}, from ${GIT_SHA:0:12}"
echo "- extensions to provide: $(jq -r 'map(.name + " in " + .schema) | join(", ")' <<< "$extensions")"
echo "- roles to provide: $(jq -r 'if length == 0 then "none" else map(.name) | join(", ") end' <<< "$roles")"
echo "- ${listed} object(s) fingerprinted, listed in fingerprint.tsv"
echo "git_sha=${GIT_SHA}"
echo "newest_version=${newest}"
echo "migration_count=${count}"
echo "dump_sha256=${dump_sha256}"
echo "fingerprint_sha256=${fingerprint_sha256}"
