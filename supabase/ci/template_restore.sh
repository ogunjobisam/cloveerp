#!/usr/bin/env bash
#
# A new client's database, restored from a template (supabase/ci/
# template_make.sh) instead of built by replaying every migration
# (build_from_empty.sh): deployment_from_empty.yml with method template
# (through supabase/ci/template_build.sh), and template.yml, which proves each
# template this way before it is recorded.
#
# The template runs as postgres in the client's database, so it is checked
# before anything is sent: its dump must be the one whose sha256 the control
# plane's register holds (TEMPLATE_SHA256; template.yml passes what it has
# just made), its manifest must say the same and, when the register's
# fingerprint is given (TEMPLATE_FINGERPRINT), hold that one, and its
# migration history must be exactly this checkout's migrations. And the
# database must be empty, with the owner's confirmed sign-in the only one in
# it, as a build from empty requires.
#
# Then ONE transaction (psql --single-transaction), so that no committed state
# exists in which the schema is there and anything below it is not:
#
#   the host        the extensions the migrations create, and the product's
#                   own roles (clove_enquiry), as the migrations made them;
#   its defaults    the restoring role's default privileges in the dumped
#                   schemas, in public and in every schema (pg_default_acl),
#                   recorded, and switched off for anon, authenticated and
#                   service_role on functions, tables and sequences. On a
#                   Supabase host a function created in public is granted to
#                   all three by those defaults, and a dump's grants are
#                   written against PostgreSQL's own defaults, so they never
#                   take those grants back: five service-role-only doors
#                   (erp_deployment_for_host, erp_supplier_notify_shipment,
#                   erp_supplier_respond, erp_supplier_response_peek,
#                   erp_tenant_by_address) would have kept an authenticated
#                   EXECUTE (20261012070000's finding);
#   the dump        pg_restore's script of the template, less the public
#                   schema's own creation, which the host has, and less every
#                   default privilege but the product's own (the restoring
#                   role's, in a product schema): public's and every schema's
#                   are the host's;
#   its defaults    put back exactly as they were, and the transaction refused
#                   (CLOVEERP_TEMPLATE_DEFAULTS) unless they are;
#   the grants      every product function revoked from anon, and the
#                   generators run again (row security, internal security,
#                   append-only, attribution, audit, live config, execute
#                   grants), as every migration ends;
#   the proof       erp_meta.schema_fingerprint() equal to the manifest's,
#                   or the transaction is refused (CLOVEERP_TEMPLATE_
#                   FINGERPRINT): a template that does not reproduce what was
#                   made leaves nothing behind, and the build carries on with
#                   a replay. The parts that differ are named, and the objects
#                   in them, by name only, from the template's own listing
#                   (fingerprint.tsv) and erp_meta.schema_fingerprint_detail();
#   the history     supabase_migrations.schema_migrations, one row a
#                   migration as build_from_empty.sh writes it, so the next
#                   `supabase db push` finds every one applied;
#   the owner       the platform's owner on the staff list, bound to their
#                   confirmed sign-in: public.erp_platform_claim_ownership()
#                   makes the first caller owner while the list is empty, so
#                   there is never a committed moment when it is
#                   (20261010062000). Refused unless the list is then exactly
#                   that one row.
#
# It says how many locks the transaction held as it committed: one
# transaction creates every table, index and function, and a small instance's
# lock table is shared by every connection (Micro's: 64 a connection).
#
# Afterwards, outside it: analyze (a restore brings no statistics), the
# platform's schedule (erp.ensure_platform_schedule() and
# erp.ensure_cron_history_pruned()), and the staff list and history counted
# once more.
#
# The deployment is not marked here (mark_deployment comes last, after its
# proof, in deployment_from_empty.yml), and nothing secret is printed: the
# connection string and its password are taken out of anything a command
# says, and the owner's address is never printed whole (the logs of a public
# repository are public).
#
# Usage: template_restore.sh <database url> <template dir> <owner email>
#
# Exits:
#   0  restored, and everything after it done
#   1  restored (committed), and then something after it failed
#   2  refused before anything was sent: the database is as it was
#   3  the one transaction did not commit: nothing of it was kept
#
# Environment:
#   TEMPLATE_SHA256       required: the sha256 of template.dump as registered
#   TEMPLATE_FINGERPRINT  the fingerprint the register holds for it (JSON);
#                         when set, the manifest's must be the same
#   MIGRATIONS_DIR        this checkout's migrations (default:
#                         supabase/migrations beside this); the template's
#                         history must be exactly them
#   PSQL, PG_RESTORE      the commands (default psql, pg_restore; the
#                         rehearsal's stand-ins). pg_restore must read the
#                         dump's format, so it is at least the version that
#                         made it
#
# bash 3.2 and 5 (supabase/ci/template_restore_rehearsal.sh runs it on a Mac).
set -euo pipefail

DB="${1:?usage: template_restore.sh <database url> <template dir> <owner email>}"
DIR="${2:?usage: template_restore.sh <database url> <template dir> <owner email>}"
OWNER="${3:?usage: template_restore.sh <database url> <template dir> <owner email>}"
PSQL_CMD="${PSQL:-psql}"
PG_RESTORE_CMD="${PG_RESTORE:-pg_restore}"
EXPECTED="${TEMPLATE_SHA256:-}"
REGISTERED_FINGERPRINT="${TEMPLATE_FINGERPRINT:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-$HERE/../migrations}"

# Run again after the dump, as every migration ends: idempotent, in this order.
GENERATORS="apply_row_security apply_platform_internal_security apply_append_only_guards apply_attribution_triggers apply_audit_coverage apply_live_config_guards apply_execute_grants"

# One line a fingerprinted object: its part, its name and a digest of what it
# is. The same expression as template_make.sh's, which wrote the template's
# fingerprint.tsv (template_restore_rehearsal.sh holds them to it).
LISTING_LINE=$(cat <<'SQL'
d.part || E'\t' || translate(d.object, E'\t\n\r\\', '    ') || E'\t' || left(encode(sha256(convert_to(coalesce(d.detail, ''), 'UTF8')), 'hex'), 16)
SQL
)

refuse() {
  echo "x $*" >&2
  exit 2
}

# The owner as the log may show them: never the whole address.
OWNER_LOWER=$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')
OWNER_SHOWN="${OWNER_LOWER:0:1}…@${OWNER_LOWER##*@}"

PASSWORD_IN_URL=""
if [[ "$DB" =~ ^[a-z]+://[^:/@]+:([^@]+)@ ]]; then PASSWORD_IN_URL="${BASH_REMATCH[1]}"; fi
redact() {
  local text="$1"
  text="${text//"${DB}"/[the database]}"
  if [[ -n "$PASSWORD_IN_URL" ]]; then text="${text//"${PASSWORD_IN_URL}"/[hidden]}"; fi
  text="${text//"${OWNER}"/${OWNER_SHOWN}}"
  text="${text//"${OWNER_LOWER}"/${OWNER_SHOWN}}"
  printf '%s' "$text"
}

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# ── What is asked for, before anything connects ──────────────────────────────
[[ "$DB" =~ ^postgres(ql)?:// ]] || refuse "the first argument is not a database URL (postgresql://...)."
[[ "$OWNER" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
  refuse "the owner given is not an email address; the platform's owner is named by the address they sign in with."
# As a SQL literal for the few questions asked with -c, which psql does not
# substitute a variable into; the transaction itself takes it as a variable.
OWNER_SQL="'$(printf '%s' "$OWNER_LOWER" | sed "s/'/''/g")'"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] ||
  refuse "TEMPLATE_SHA256 must be the sha256 the register holds for this template (sixty-four hex characters); a template is restored only when its dump is the one recorded."
[[ -d "$DIR" ]] || refuse "$DIR is not a template directory."
for f in manifest.json template.dump migrations.tsv fingerprint.tsv; do
  [[ -s "$DIR/$f" ]] || refuse "the template has no $f."
done
[[ -d "$MIGRATIONS_DIR" ]] || refuse "$MIGRATIONS_DIR is not a directory of migrations."

manifest="$DIR/manifest.json"
jq -e 'type == "object" and .format == "cloveerp.template.v1"' "$manifest" > /dev/null 2>&1 ||
  refuse "the manifest is not a cloveerp.template.v1 manifest."

# The dump is the registered one, and the manifest says so too.
actual=$(sha256_of "$DIR/template.dump")
if [[ "$actual" != "$EXPECTED" ]]; then
  refuse "template.dump's sha256 is ${actual:0:16}…, not the ${EXPECTED:0:16}… registered for it. A template that is not the one recorded is never restored: it would run as postgres in the client's database."
fi
[[ "$(jq -r '.files["template.dump"].sha256 // empty' "$manifest")" == "$EXPECTED" ]] ||
  refuse "the manifest names a different dump from the one registered."

# The history is this checkout's migrations, exactly.
[[ "$(sha256_of "$DIR/migrations.tsv")" == "$(jq -r '.files["migrations.tsv"].sha256 // empty' "$manifest")" ]] ||
  refuse "migrations.tsv is not the one the manifest names."
bad_line=$(grep -nvE $'^[0-9]+\t[A-Za-z0-9_-]+$' "$DIR/migrations.tsv" | head -n 1 || true)
[[ -z "$bad_line" ]] || refuse "migrations.tsv line ${bad_line%%:*} is not <version><TAB><name>."
count=$(grep -c . "$DIR/migrations.tsv" | tr -d ' ')
newest=$(tail -n 1 "$DIR/migrations.tsv" | cut -f 1)
[[ "$count" == "$(jq -r '.migration_count' "$manifest")" && "$newest" == "$(jq -r '.newest_version' "$manifest")" ]] ||
  refuse "migrations.tsv holds ${count} migrations, the newest ${newest}; the manifest says otherwise."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: > "$work/here.unsorted"
for f in "$MIGRATIONS_DIR"/*.sql; do
  [[ -e "$f" ]] || continue
  base="$(basename "$f")"
  if [[ "$base" =~ ^([0-9]+)_([A-Za-z0-9_-]+)\.sql$ ]]; then
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "$work/here.unsorted"
  else
    refuse "$base is not named <version>_<name>.sql."
  fi
done
LC_ALL=C sort "$work/here.unsorted" > "$work/here.tsv"
if ! diff -q "$work/here.tsv" "$DIR/migrations.tsv" > /dev/null; then
  first=$(diff "$work/here.tsv" "$DIR/migrations.tsv" | grep -E '^[<>]' | head -n 1 | tr '\t' ' ' || true)
  refuse "the template's migrations are not this checkout's (${count} in the template, the newest ${newest}; $(grep -c . "$work/here.tsv" | tr -d ' ') here; first difference: ${first}). A client restored from it would be a different schema from the one its releases expect."
fi

# The listing of what the fingerprint hashed, object by object: what names
# the objects that differ when the restore does not reproduce it. Only ever
# read to say what differs; whether it differs is the fingerprint's.
[[ "$(sha256_of "$DIR/fingerprint.tsv")" == "$(jq -r '.files["fingerprint.tsv"].sha256 // empty' "$manifest")" ]] ||
  refuse "fingerprint.tsv is not the one the manifest names."
bad_line=$(grep -nvE $'^[a-z_]+\t[^\t]+\t[0-9a-f]{16}$' "$DIR/fingerprint.tsv" | head -n 1 || true)
[[ -z "$bad_line" ]] || refuse "fingerprint.tsv line ${bad_line%%:*} is not <part><TAB><object><TAB><digest>."

# The fingerprint, the extensions and the roles the manifest asks for, in the
# shapes that can be written into SQL.
fingerprint=$(jq -c '.fingerprint' "$manifest")
[[ "$fingerprint" != null && -n "$fingerprint" ]] || refuse "the manifest holds no fingerprint, so the restore could not be proved."
[[ "${#fingerprint}" -lt 100000 ]] || refuse "the manifest's fingerprint is ${#fingerprint} characters; a fingerprint is a hash a part."
if [[ -n "$REGISTERED_FINGERPRINT" ]]; then
  same=$(jq -n --argjson a "$fingerprint" --argjson b "$REGISTERED_FINGERPRINT" '$a == $b' 2> /dev/null || echo invalid)
  [[ "$same" == true ]] ||
    refuse "the manifest's fingerprint is not the one the register holds for this template, so what the restore proves would not be what was recorded."
fi
schemas=$(jq -r '.schemas | join(" ")' "$manifest")
for s in $schemas; do
  [[ "$s" =~ ^[a-z_][a-z0-9_]*$ ]] || refuse "the manifest names a schema '${s}' that will not be written into SQL."
done
[[ " $schemas " == *" erp "* && " $schemas " == *" erp_meta "* ]] || refuse "the manifest's schemas (${schemas}) are not the product's."
product_schemas=""
for s in $schemas; do [[ "$s" == public ]] || product_schemas="${product_schemas} ${s}"; done
extensions=$(jq -r '.extensions[] | .name + " " + .schema' "$manifest")
while read -r name schema; do
  [[ -n "$name" ]] || continue
  [[ "$name" =~ ^[a-z0-9_]+$ && "$schema" =~ ^[a-z_][a-z0-9_]*$ ]] ||
    refuse "the manifest names an extension '${name}' in '${schema}', which will not be written into SQL."
done <<< "$extensions"
roles=$(jq -c '.roles // []' "$manifest")
bad_roles=$(jq -r '[.[] | select((.name | test("^[a-z_][a-z0-9_]*$") | not) or .login or .bypassrls or .superuser) | .name] | join(", ")' <<< "$roles")
[[ -z "$bad_roles" ]] || refuse "the manifest asks for the role(s) ${bad_roles}, which a restore does not make."

# ── The database: empty, and the owner's sign-in the only one ────────────────
ask() {
  local out
  if ! out=$($PSQL_CMD "$DB" -v ON_ERROR_STOP=1 -X -q -tA -c "$1" 2> "$work/psql.err"); then
    refuse "the database did not answer ($(redact "$(cat "$work/psql.err")" | tr -s ' \t\r\n' '    ' | cut -c 1-400))."
  fi
  printf '%s\n' "$out"
}

has_erp=$(ask "select to_regnamespace('erp') is not null")
[[ "$has_erp" != t ]] ||
  refuse "this database already has an erp schema; a template is restored into an empty database only. Nothing was changed."
has_history=$(ask "select to_regclass('supabase_migrations.schema_migrations') is not null")
if [[ "$has_history" == t ]]; then
  recorded=$(ask "select count(*) from supabase_migrations.schema_migrations")
  [[ "$recorded" == 0 ]] ||
    refuse "this database already records ${recorded} migration(s); a template is restored into an empty database only. Nothing was changed."
fi
users=$(ask "select count(*) || ' ' || count(*) filter (where lower(email) = ${OWNER_SQL} and email_confirmed_at is not null) from auth.users")
[[ "$users" == "1 1" ]] ||
  refuse "auth.users must hold exactly one sign-in, the owner's (${OWNER_SHOWN}), with its address confirmed; it holds ${users%% *}, of which ${users##* } is the owner's confirmed. Nothing was changed."

# Each role the manifest asks for: there already, or made as the migration
# that first made it did. A role this cannot make is a refusal now, not a
# missing grantee halfway through the dump.
present_roles=$(ask "select coalesce(string_agg(rolname, ' '), '') from pg_catalog.pg_roles where rolname = any (string_to_array('$(jq -r 'map(.name) | join(" ")' <<< "$roles")', ' '))")

# ── The restore's script ─────────────────────────────────────────────────────
if ! err=$($PG_RESTORE_CMD --list "$DIR/template.dump" 2>&1 > "$work/toc.all"); then
  refuse "pg_restore could not read the template ($(printf '%s' "$err" | tr -s ' \t\r\n' '    ' | cut -c 1-300))."
fi
grep -q 'SCHEMA - erp ' "$work/toc.all" || grep -q 'SCHEMA - erp$' "$work/toc.all" ||
  refuse "the template's table of contents creates no erp schema; it is not a template of the product."
# The public schema exists on every host; everything in it is restored. And
# default privileges only the product's own: the restorer's (the role that
# runs the migrations, which is the role restoring here) in a product schema
# (0004: authenticated's use of erp's sequences). Another role's are the build
# host's, public's and every schema's are the host's own, which the client's
# host sets for itself and the transaction puts back as it found them. A
# table of contents line is "<id>; <catalog> <oid> DEFAULT ACL <schema, or ->
# DEFAULT PRIVILEGES FOR <kind> <role>".
restorer=$(ask "select current_user")
[[ "$restorer" =~ ^[a-z_][a-z0-9_]*$ ]] || refuse "the database answers as '${restorer}', which is not a role this can name."
grep -v 'SCHEMA - public' "$work/toc.all" |
  awk -v me="$restorer" -v product=" ${product_schemas# } " '
    / DEFAULT ACL / { if ($NF == me && index(product, " " $6 " ") > 0) print; next }
    { print }' > "$work/toc"
host_defaults=$(grep -c ' DEFAULT ACL ' "$work/toc.all" || true)
kept_defaults=$(grep -c ' DEFAULT ACL ' "$work/toc" || true)
if [[ "$host_defaults" != "$kept_defaults" ]]; then
  echo "- $((host_defaults - kept_defaults)) default privilege(s) the build host had (another role's, public's or every schema's) are left to this host"
fi
if ! err=$($PG_RESTORE_CMD --no-owner --use-list="$work/toc" --file="$work/body.sql" "$DIR/template.dump" 2>&1); then
  refuse "pg_restore could not write the template's script ($(printf '%s' "$err" | tr -s ' \t\r\n' '    ' | cut -c 1-300))."
fi
[[ -s "$work/body.sql" ]] || refuse "pg_restore wrote an empty script."

# ── One transaction ──────────────────────────────────────────────────────────
{
  cat <<'SQL'
-- supabase/ci/template_restore.sh: one transaction (psql --single-transaction).
set statement_timeout = 0;
select set_config('cloveerp.template_owner', lower(:'tmpl_owner'), true) is not null as owner_set;
select set_config('cloveerp.template_fingerprint', :'tmpl_fingerprint', true) is not null as fingerprint_set;
select set_config('cloveerp.template_schemas', :'tmpl_schemas', true) is not null as schemas_set;
-- The host: what the dump assumes exists.
SQL
  while read -r name schema; do
    [[ -n "$name" ]] || continue
    echo "create extension if not exists ${name} with schema ${schema};"
  done <<< "$extensions"
  n=$(jq 'length' <<< "$roles")
  i=0
  while [[ "$i" -lt "$n" ]]; do
    role=$(jq -c ".[$i]" <<< "$roles")
    name=$(jq -r '.name' <<< "$role")
    if [[ " ${present_roles} " != *" ${name} "* ]]; then
      if [[ "$(jq -r '.inherit' <<< "$role")" == true ]]; then inherit=inherit; else inherit=noinherit; fi
      echo "create role ${name} nologin nobypassrls ${inherit};"
    fi
    if [[ "$(jq -r '.builder_member' <<< "$role")" == true ]]; then
      echo "grant ${name} to current_user with set $(jq -r '.builder_set' <<< "$role"), inherit $(jq -r '.builder_inherit' <<< "$role");"
    fi
    i=$((i + 1))
  done
  cat <<'SQL'
-- The host's default privileges for the restoring role, in the dumped
-- schemas, in public and in every schema, as they are; then switched off for
-- anon, authenticated and service_role, so nothing the dump creates is
-- granted what the build's was not.
create temp table template_host_defaults on commit drop as
select coalesce(n.nspname::text, '') as schema_name, d.defaclobjtype::text as objtype, d.defaclacl as acl
  from pg_catalog.pg_default_acl d
  left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
 where d.defaclrole = (select r.oid from pg_catalog.pg_roles r where r.rolname = current_user)
   and (d.defaclnamespace = 0
        or n.nspname = any (pg_catalog.string_to_array(current_setting('cloveerp.template_schemas'), ' ')));
do $defaults_off$
declare
  r record;
begin
  for r in
    select distinct h.schema_name, h.objtype, g.rolname::text as grantee
      from pg_temp.template_host_defaults h
     cross join lateral pg_catalog.aclexplode(h.acl) x
      join pg_catalog.pg_roles g on g.oid = x.grantee
     where h.objtype in ('f', 'r', 'S')
       and g.rolname in ('anon', 'authenticated', 'service_role')
     order by 1, 2, 3
  loop
    execute pg_catalog.format('alter default privileges for role %I%s revoke all on %s from %I',
      current_user,
      case when r.schema_name = '' then '' else pg_catalog.format(' in schema %I', r.schema_name) end,
      case r.objtype when 'f' then 'functions' when 'r' then 'tables' else 'sequences' end,
      r.grantee);
  end loop;
end
$defaults_off$;
select 'template_host_defaults=' || coalesce(pg_catalog.string_agg(z.said, '; ' order by z.said), 'none')
  from (select coalesce(nullif(h.schema_name, ''), 'every schema') || ' '
               || case h.objtype when 'f' then 'functions' when 'r' then 'tables' else 'sequences' end || ': '
               || pg_catalog.string_agg(distinct g.rolname::text, ', ' order by g.rolname::text) as said
          from pg_temp.template_host_defaults h
         cross join lateral pg_catalog.aclexplode(h.acl) x
          join pg_catalog.pg_roles g on g.oid = x.grantee
         where h.objtype in ('f', 'r', 'S')
           and g.rolname in ('anon', 'authenticated', 'service_role')
         group by h.schema_name, h.objtype) z;
-- The template.
SQL
  echo "\\i '$work/body.sql'"
  cat <<'SQL'
-- The host's default privileges put back exactly as they were, or nothing is
-- kept.
do $defaults_back$
declare
  r      record;
  v_diff text;
begin
  for r in
    select h.schema_name, h.objtype, g.rolname::text as grantee, x.privilege_type, x.is_grantable
      from pg_temp.template_host_defaults h
     cross join lateral pg_catalog.aclexplode(h.acl) x
      join pg_catalog.pg_roles g on g.oid = x.grantee
     where h.objtype in ('f', 'r', 'S')
       and g.rolname in ('anon', 'authenticated', 'service_role')
     order by 1, 2, 3, 4
  loop
    execute pg_catalog.format('alter default privileges for role %I%s grant %s on %s to %I%s',
      current_user,
      case when r.schema_name = '' then '' else pg_catalog.format(' in schema %I', r.schema_name) end,
      r.privilege_type,
      case r.objtype when 'f' then 'functions' when 'r' then 'tables' else 'sequences' end,
      r.grantee,
      case when r.is_grantable then ' with grant option' else '' end);
  end loop;

  with before_restore as (
    select h.schema_name, h.objtype,
           coalesce(g.rolname::text, 'public') || '=' || x.privilege_type || case when x.is_grantable then '+' else '' end as item
      from pg_temp.template_host_defaults h
     cross join lateral pg_catalog.aclexplode(h.acl) x
      left join pg_catalog.pg_roles g on g.oid = x.grantee
  ), after_restore as (
    select coalesce(n.nspname::text, '') as schema_name, d.defaclobjtype::text as objtype,
           coalesce(g.rolname::text, 'public') || '=' || x.privilege_type || case when x.is_grantable then '+' else '' end as item
      from pg_catalog.pg_default_acl d
      left join pg_catalog.pg_namespace n on n.oid = d.defaclnamespace
     cross join lateral pg_catalog.aclexplode(d.defaclacl) x
      left join pg_catalog.pg_roles g on g.oid = x.grantee
     where d.defaclrole = (select me.oid from pg_catalog.pg_roles me where me.rolname = current_user)
       and (d.defaclnamespace = 0
            or n.nspname = 'public'
            or n.nspname in (select h.schema_name from pg_temp.template_host_defaults h))
  )
  select pg_catalog.string_agg(z.how || ' ' || coalesce(nullif(z.schema_name, ''), 'every schema') || ' ' || z.objtype || ' ' || z.item,
                               '; ' order by z.schema_name, z.objtype, z.item, z.how)
    into v_diff
    from ((select 'lost' as how, w.* from (select * from before_restore except select * from after_restore) w)
          union all
          (select 'gained' as how, o.* from (select * from after_restore except select * from before_restore) o)) z;
  if v_diff is not null then
    raise exception 'CLOVEERP_TEMPLATE_DEFAULTS: the host''s default privileges were not put back as they were (%)', v_diff
      using hint = 'Nothing was kept. Build this deployment from empty instead, and look at what the template''s dump sets.';
  end if;
end
$defaults_back$;
-- Anon executes nothing in the product, and the product's own grants made
-- again.
SQL
  echo "revoke all on all functions in schema $(printf '%s' "$schemas" | sed 's/ /, /g') from anon;"
  for g in $GENERATORS; do echo "select erp.${g}();"; done
  cat <<'SQL'
-- The proof: what was restored is what was made, or nothing is kept. The
-- parts that differ, and the objects in them, are written out for the script
-- to name before the transaction is refused.
create temp table template_restored on commit drop as
select erp_meta.schema_fingerprint() as have, current_setting('cloveerp.template_fingerprint')::jsonb as want;
create temp table template_restored_listing (line text) on commit drop;
select 'template_parts=' || pg_catalog.string_agg(k.key, ',' order by k.key)
  from pg_temp.template_restored r
 cross join lateral (select e.key from pg_catalog.jsonb_each(r.have) e
                     union select e.key from pg_catalog.jsonb_each(r.want) e) k
 where (r.have -> k.key) is distinct from (r.want -> k.key)
having count(*) > 0;
SQL
  cat <<SQL
do \$listing\$
begin
  if exists (select 1 from pg_temp.template_restored r where r.have is distinct from r.want) then
    insert into pg_temp.template_restored_listing (line)
    select ${LISTING_LINE}
      from erp_meta.schema_fingerprint_detail() d, pg_temp.template_restored r
     where (r.have -> d.part) is distinct from (r.want -> d.part);
  end if;
end
\$listing\$;
SQL
  cat <<'SQL'
select 'template_listing' || E'\t' || l.line from pg_temp.template_restored_listing l order by l.line collate "C";
select 'template_listed=' || count(*) from pg_temp.template_restored_listing;
do $fingerprint$
declare
  v_want  jsonb := (select r.want from pg_temp.template_restored r);
  v_have  jsonb := (select r.have from pg_temp.template_restored r);
  v_parts text;
begin
  if v_have is distinct from v_want then
    if jsonb_typeof(v_want) = 'object' and jsonb_typeof(v_have) = 'object' then
      select string_agg(k.key, ', ' order by k.key) into v_parts
        from (select key from jsonb_each(v_want) union select key from jsonb_each(v_have)) k
       where (v_want -> k.key) is distinct from (v_have -> k.key);
    end if;
    raise exception 'CLOVEERP_TEMPLATE_FINGERPRINT: the restored schema is not the one the template was made from (%)',
      coalesce('these parts differ: ' || v_parts, 'its fingerprint differs')
      using hint = 'Nothing was kept. Build this deployment from empty instead, and make the template again (template.yml).';
  end if;
end
$fingerprint$;
-- The history the CLI reads, in its own shape, as build_from_empty.sh writes it.
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text not null primary key);
alter table supabase_migrations.schema_migrations add column if not exists statements text[];
alter table supabase_migrations.schema_migrations add column if not exists name text;
SQL
  echo "insert into supabase_migrations.schema_migrations (version, name, statements) values"
  awk -F '\t' -v n="$count" '{ printf "  (%c%s%c, %c%s%c, %c{}%c::text[])%s\n", 39, $1, 39, 39, $2, 39, 39, 39, (NR == n ? ";" : ",") }' "$DIR/migrations.tsv"
  cat <<'SQL'
-- The owner, bound to their confirmed sign-in, before anything is committed.
insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
select current_setting('cloveerp.template_owner'), u.id, current_setting('cloveerp.template_owner'), 'owner'
  from auth.users u
 where lower(u.email) = current_setting('cloveerp.template_owner')
   and u.email_confirmed_at is not null;
do $owner$
declare
  v_rows  integer;
  v_bound integer;
begin
  select count(*),
         count(*) filter (where lower(s.email) = current_setting('cloveerp.template_owner')
                            and s.staff_role = 'owner'
                            and s.auth_user_id = (select u.id from auth.users u
                                                   where lower(u.email) = current_setting('cloveerp.template_owner')
                                                     and u.email_confirmed_at is not null
                                                   limit 1))
    into v_rows, v_bound
    from erp_meta.platform_staff s
   where s.revoked_at is null;
  if v_rows <> 1 or v_bound <> 1 then
    raise exception 'CLOVEERP_TEMPLATE_OWNER: the staff list is not exactly the owner, bound to their confirmed sign-in (% active row(s), % of them the owner''s)', v_rows, v_bound
      using hint = 'Nothing was kept. The owner''s confirmed sign-in must be the only one in auth.users.';
  end if;
end
$owner$;
select 'template_locks=' || count(*) from pg_catalog.pg_locks where pid = pg_catalog.pg_backend_pid();
SQL
} > "$work/restore.sql"

echo "- restoring ${count} migrations' schema (the newest ${newest}) in one transaction"
started=$(date +%s)
log="$work/restore.log"
if ! $PSQL_CMD "$DB" -X -q -tA -v ON_ERROR_STOP=1 --single-transaction \
       -v tmpl_owner="$OWNER_LOWER" -v tmpl_fingerprint="$fingerprint" -v tmpl_schemas="$schemas" \
       -f "$work/restore.sql" > "$log" 2>&1; then
  echo "x the template did not restore, and nothing of it was kept: it was one transaction." >&2
  if grep -q 'ERROR:' "$log"; then
    redact "$(sed -n '/ERROR:/,$p' "$log" | grep -v $'^template_listing\t' | head -n 40)" >&2
  else
    redact "$(grep -v $'^template_listing\t' "$log" | tail -n 40)" >&2
  fi
  echo >&2
  # The objects in the parts that differ, by name: what the template's own
  # listing holds and what the restore held, compared.
  parts=$(sed -n 's/^template_parts=//p' "$log" | tail -n 1)
  listed=$(sed -n 's/^template_listed=//p' "$log" | tail -n 1)
  if [[ -n "$parts" && -n "$listed" ]]; then
    grep $'^template_listing\t' "$log" | cut -f 2- > "$work/restored.tsv" || true
    awk -F '\t' -v parts=",${parts}," '
      FNR == NR { if (index(parts, "," $1 ",") > 0) made[$1 "\t" $2] = $3; next }
      { k = $1 "\t" $2
        if (!(k in made)) print $1 "\t" $2 "\tnot in the template"
        else if (made[k] != $3) print $1 "\t" $2 "\tnot as the template made it"
        delete made[k] }
      END { for (k in made) print k "\tmissing from the restore" }' "$DIR/fingerprint.tsv" "$work/restored.tsv" |
      LC_ALL=C sort > "$work/differ.tsv"
    differ=$(grep -c . "$work/differ.tsv" | tr -d ' ' || true)
    if [[ "${differ:-0}" -gt 0 ]]; then
      echo "x ${differ} object(s) in the parts that differ (${parts//,/, }) are not as the template made them:" >&2
      head -n 30 "$work/differ.tsv" | awk -F '\t' '{ print "  " $1 "  " $2 "  (" $3 ")" }' >&2
      [[ "$differ" -le 30 ]] || echo "  … and $((differ - 30)) more" >&2
    fi
  fi
  exit 3
fi
defaults=$(sed -n 's/^template_host_defaults=//p' "$log" | tail -n 1)
locks=$(sed -n 's/^template_locks=//p' "$log" | tail -n 1)
if [[ -z "$defaults" || "$defaults" == none ]]; then
  echo "- the host gives anon, authenticated and service_role nothing by default here, so nothing was switched off while the dump ran"
else
  echo "- the host's default privileges (${defaults}) were switched off while the dump ran, and put back as they were"
fi
echo "- restored in $(( $(date +%s) - started )) s; the transaction held ${locks:-an unknown number of} lock(s) as it committed"

# ── Afterwards ───────────────────────────────────────────────────────────────
# Each its own statement, as build_from_empty.sh's analyse is: what fails
# here fails a committed restore, which the build's Retry carries on from.
after() {
  local out
  if ! out=$($PSQL_CMD "$DB" -X -q -tA -v ON_ERROR_STOP=1 -c "$1" 2>&1); then
    echo "x the template is restored, and then this failed: $1" >&2
    redact "$out" >&2
    echo >&2
    exit 1
  fi
  printf '%s\n' "$out"
}
after "analyze" > /dev/null
echo "- schedule: $(after "select erp.ensure_platform_schedule()::text" | tr -s ' \n' '  ' | cut -c 1-300)"
echo "- run history: $(after "select erp.ensure_cron_history_pruned()::text" | tr -s ' \n' '  ' | cut -c 1-300)"

recorded=$(after "select count(*) from supabase_migrations.schema_migrations")
[[ "$recorded" == "$count" ]] || {
  echo "x the template is restored and ${recorded} migration(s) are recorded, not ${count}." >&2
  exit 1
}
staff=$(after "select count(*) || ' ' || count(*) filter (
           where lower(s.email) = ${OWNER_SQL}
             and s.staff_role = 'owner'
             and s.auth_user_id = (select u.id from auth.users u
                                    where lower(u.email) = ${OWNER_SQL}
                                      and u.email_confirmed_at is not null
                                    limit 1))
    from erp_meta.platform_staff s where s.revoked_at is null")
[[ "$staff" == "1 1" ]] || {
  echo "x the template is restored, and the platform's staff list is not exactly ${OWNER_SHOWN}, bound to their confirmed sign-in (active rows: ${staff%% *}; the owner's, bound: ${staff##* }). The console is not safe to open." >&2
  exit 1
}

echo "restored: ${count} migration(s) recorded, the newest ${newest}, from the template made at $(jq -r '.git_sha[0:12]' "$manifest") (dump ${EXPECTED:0:12}, fingerprint $(jq -r '.fingerprint_sha256[0:12]' "$manifest") reproduced); ${OWNER_SHOWN} is the platform's owner"
echo "template_locks=${locks:-}"
