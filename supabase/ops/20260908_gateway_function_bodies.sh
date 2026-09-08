#!/usr/bin/env bash
#
# Make the twelve function bodies the remaining migrations patch match the
# bodies a build from empty produces.
#
# The first automated deploy stopped here:
#
#   Applying migration 20260906112000_a_lease_that_expires_says_what_it_knows.sql...
#   ERROR: CLOVEERP_ENGINE_UNRECOGNISED: erp.claim_command_batch is not the
#          body this migration patches (SQLSTATE P0001)
#
# That is a guard inside the migration, working. Seventeen of the migrations
# still to apply rewrite an existing function by reading
# pg_get_functiondef(), requiring exact substrings, and refusing rather than
# producing a mangled function. Between them they name twelve functions, all in
# the write gateway and the worker.
#
# The bodies do not match because everything up to 20260905040000 reached the
# live database through the Supabase MCP connector rather than by replaying the
# migration files. What the connector left is functionally equivalent and
# textually different, and text surgery needs textual equivalence. Marking
# those migrations applied recorded what exists; it could not make the text
# identical.
#
# So this builds the reference the migrations were written against — the
# repository, from empty, up to exactly the version live has already recorded —
# and compares the twelve. Where they differ, the reference body is the answer,
# and pg_get_functiondef() emits it as a CREATE OR REPLACE that can simply be
# run. Nothing here is written by hand: a body reconstructed by reading the
# migration chain is a guess, and a guess that satisfies one guard will fail
# the next.
#
#   ./supabase/ops/20260908_gateway_function_bodies.sh            # report only
#   ./supabase/ops/20260908_gateway_function_bodies.sh --apply    # and repair
#
# Needs a local PostgreSQL it can create databases on (the same one CI uses:
# supabase/postgres, for pg_jsonschema), and CLOVEERP_LIVE_DATABASE_URL for the
# live side. Reads live unless --apply is given, and even then writes nothing
# but CREATE OR REPLACE FUNCTION for functions that already differ.
#
# Once this reports no differences, the deploy resumes on its own:
# .github/workflows/deploy.yml with mark_applied unset.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/clove-erp-gateway-bodies.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"

PSQL="psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc"
REF_DB="clove_erp_gateway_reference"
APPLY="no"
[ "${1:-}" = "--apply" ] && APPLY="yes"

LIVE="${CLOVEERP_LIVE_DATABASE_URL:-}"
if [ -z "$LIVE" ]; then
  echo "CLOVEERP_LIVE_DATABASE_URL is not set; there is nothing to compare against." >&2
  exit 1
fi

# The twelve. Every CLOVEERP_ENGINE_UNRECOGNISED guard in the migrations from
# 20260906112000 onwards names one of these. Regenerate the list with:
#
#   grep -ho "CLOVEERP_ENGINE_UNRECOGNISED: [a-z_]*\.[a-z_]*" \
#     supabase/migrations/2026090611[2-9]*.sql supabase/migrations/202609061[2-4]*.sql \
#     | sed 's/.*: //' | sort -u
#
FUNCTIONS="
erp.claim_command_batch
erp.claim_email_batch
erp.claim_message_batch
erp.complete_email
erp.complete_message
erp.fail_email
erp.fail_message
erp.gateway_integrity_report
erp.integration_backlog
erp.reclaim_expired_commands
erp.release_integrity_report
erp.run_due_jobs_all_tenants
"
names_sql=$(printf "'%s'," $(printf '%s\n' $FUNCTIONS | sed 's/^erp\.//'))
names_sql="array[${names_sql%,}]"

# ── Where live actually is ───────────────────────────────────────────────────
#
# Not the mark_applied boundary. Live has applied fourteen of the migrations
# after it, so the bodies the next one expects are the ones a build carries at
# live's own high-water mark. Reading it rather than naming it means this stays
# right if more of them land before the repair runs.
boundary=$(psql "$LIVE" -v ON_ERROR_STOP=1 -tAc \
  "select coalesce(max(version), '') from supabase_migrations.schema_migrations")
if [ -z "$boundary" ]; then
  echo "live records no migrations at all; this script has nothing to reference." >&2
  exit 1
fi
echo "live's highest recorded migration: $boundary"

# ── The reference ────────────────────────────────────────────────────────────
echo "building a reference database up to $boundary ..."
psql -d postgres -qc "drop database if exists $REF_DB" >/dev/null
psql -d postgres -qc "create database $REF_DB" >/dev/null
PGDATABASE="$REF_DB" $PSQL -f "$ROOT/supabase/ci/00_host_bootstrap.sql" >/dev/null
applied=0
for f in "$ROOT"/supabase/migrations/*.sql; do
  v=$(basename "$f" | sed -E 's/^([0-9]+)_.*$/\1/')
  # Numerically: the repository carries both 0001 and 20260906111000, and a
  # lexicographic compare across those lengths is only accidentally right.
  if [ "$(awk -v a="$v" -v b="$boundary" 'BEGIN{print (a+0 <= b+0)}')" = "1" ]; then
    PGDATABASE="$REF_DB" $PSQL --single-transaction -f "$f" >/dev/null
    applied=$((applied + 1))
  fi
done
echo "reference built: $applied migration(s)"

# ── The twelve, from each side ───────────────────────────────────────────────
#
# By oid::regprocedure rather than by name, so an overload is compared with its
# own counterpart rather than silently with a sibling.
dump () {                        # dump <psql-target...> > file
  "$@" -v ON_ERROR_STOP=1 -tAc "
    select p.oid::regprocedure::text || E'\t' || md5(pg_get_functiondef(p.oid))
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'erp' and p.proname = any ($names_sql)
     order by 1;"
}

dump psql -d "$REF_DB" > "$WORK/reference.tsv"
dump psql "$LIVE"      > "$WORK/live.tsv"

echo
printf '%-64s %s\n' "FUNCTION" "STATE"
differ=""
missing=""
while IFS=$'\t' read -r sig digest; do
  [ -z "$sig" ] && continue
  live_digest=$(awk -F'\t' -v s="$sig" '$1 == s {print $2}' "$WORK/live.tsv")
  if [ -z "$live_digest" ]; then
    printf '%-64s %s\n' "$sig" "ABSENT ON LIVE"
    missing="$missing$sig"$'\n'
  elif [ "$live_digest" != "$digest" ]; then
    printf '%-64s %s\n' "$sig" "DIFFERS"
    differ="$differ$sig"$'\n'
  else
    printf '%-64s %s\n' "$sig" "matches"
  fi
done < "$WORK/reference.tsv"

if [ -n "$missing" ]; then
  echo
  echo "Some of the twelve do not exist on live at all. That is a different" >&2
  echo "problem from a drifted body and this script will not invent them." >&2
  exit 1
fi

if [ -z "$differ" ]; then
  echo
  echo "every one of the twelve already matches the reference; nothing to repair."
  exit 0
fi

# ── The repair ───────────────────────────────────────────────────────────────
#
# pg_get_functiondef() emits a complete CREATE OR REPLACE FUNCTION, so the
# reference's own output is the repair. CREATE OR REPLACE keeps the function's
# grants, and every migration re-runs erp.apply_execute_grants() regardless.
: > "$WORK/repair.sql"
while read -r sig; do
  [ -z "$sig" ] && continue
  psql -d "$REF_DB" -v ON_ERROR_STOP=1 -tAc \
    "select pg_get_functiondef('$sig'::regprocedure) || ';'" >> "$WORK/repair.sql"
  echo >> "$WORK/repair.sql"
done <<< "$differ"

echo
echo "$(grep -c '^CREATE OR REPLACE' "$WORK/repair.sql") function(s) to re-emit."

if [ "$APPLY" != "yes" ]; then
  cp "$WORK/repair.sql" "$ROOT/gateway_repair.sql"
  echo "written to gateway_repair.sql — read it, then re-run with --apply."
  exit 0
fi

echo "applying to live ..."
psql "$LIVE" -v ON_ERROR_STOP=1 --single-transaction -f "$WORK/repair.sql"

# ── Prove it ─────────────────────────────────────────────────────────────────
dump psql "$LIVE" > "$WORK/live_after.tsv"
if diff -q "$WORK/reference.tsv" "$WORK/live_after.tsv" >/dev/null; then
  echo "live now matches the reference on all twelve."
else
  echo "live still differs after the repair:" >&2
  diff "$WORK/reference.tsv" "$WORK/live_after.tsv" >&2 || true
  exit 1
fi
