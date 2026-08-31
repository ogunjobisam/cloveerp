#!/usr/bin/env bash
#
# Prove that the reconciliation script turns the production database's schema
# into the one this repository describes.
#
# The claim it checks is narrow and mechanical: take a build of the repository
# WITHOUT the eight migrations production is missing, apply the reconciliation
# to it, and the result must be catalogue-identical to a build of the whole
# repository from empty. Ten dimensions are compared, and any difference in any
# of them fails the run.
#
# This exists because the reconciliation cannot be validated the way every other
# change here is validated. CI builds from empty and applies the migration
# sequence; the reconciliation is a no-op on that path by design, so CI proves
# only that it does no harm, never that it does the job. This script is the part
# that proves it does the job.
#
#   ./supabase/ops/20260831_equivalence_check.sh
#
# Needs a PostgreSQL it can create databases on. Reads nothing from production
# and writes nothing to it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/erpware-equivalence.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"

PSQL="psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc"

# The migrations production does not have. Five of them are numbered earlier
# than work already applied there, which is the whole reason the reconciliation
# exists rather than a replay.
MISSING=(
  20260829330000_bootstrap_suite_purge.sql
  20260829340000_master_data_doors.sql
  20260829350000_document_authorisation.sql
  20260829360000_reference_reads.sql
  20260829370000_transition_context.sql
  20260830140000_reconcile_generated_surface.sql
  20260830150000_revoke_anon_execute.sql
  20260831130000_document_create_permission.sql
)

is_missing () {
  local name="$1"
  for m in "${MISSING[@]}"; do [ "$m" = "$name" ] && return 0; done
  return 1
}

build () {                       # build <dbname> <skip-missing:yes|no>
  local db="$1" skip="$2"
  psql -d postgres -qc "drop database if exists $db" >/dev/null
  psql -d postgres -qc "create database $db" >/dev/null
  PGDATABASE="$db" $PSQL -f "$ROOT/supabase/ci/00_host_bootstrap.sql" >/dev/null
  for f in "$ROOT"/supabase/migrations/*.sql; do
    if [ "$skip" = "yes" ] && is_missing "$(basename "$f")"; then continue; fi
    PGDATABASE="$db" $PSQL --single-transaction -f "$f" >/dev/null
  done
}

# Ten dimensions. Routines carry their body digest, their SET clause, and
# whether they are a function or procedure, definer or invoker, volatile or
# not — a rename or a silently dropped `security definer` has to show up.
dump () {                        # dump <dbname> <prefix>
  local db="$1" p="$2"
  psql -d "$db" -tAc "
    select n.nspname||'.'||f.proname||'('||pg_get_function_identity_arguments(f.oid)||')'
           ||' | '||md5(f.prosrc)||' | '||coalesce(array_to_string(f.proconfig,','),'-')
           ||' | '||f.prokind::text||f.prosecdef::text||f.provolatile::text
      from pg_proc f join pg_namespace n on n.oid = f.pronamespace
     where n.nspname in ('erp','erp_ref','erp_meta','erp_ai','erp_test')
        or (n.nspname = 'public' and f.proname like 'erp\_%')
     order by 1;" > "$p.routines"
  psql -d "$db" -tAc "
    select table_schema||'.'||table_name||'.'||column_name||' '||data_type||' null='||is_nullable
      from information_schema.columns
     where table_schema in ('erp','erp_ref','erp_meta','erp_ai') order by 1;" > "$p.columns"
  psql -d "$db" -tAc "
    select c.relname||'.'||t.tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid
     where not t.tgisinternal order by 1;" > "$p.triggers"
  psql -d "$db" -tAc "
    select c.relname||'.'||pol.polname from pg_policy pol join pg_class c on c.oid = pol.polrelid
     order by 1;" > "$p.policies"
  psql -d "$db" -tAc "select function_name||'|'||gate from erp_meta.public_write_allowance order by 1;" > "$p.writeallow"
  psql -d "$db" -tAc "select schema_name||'.'||function_name from erp_meta.security_definer_allowance order by 1;" > "$p.definer"
  psql -d "$db" -tAc "select code||'|'||create_permission from erp_ref.document_type order by 1;" > "$p.basetypes"
  psql -d "$db" -tAc "select key from erp_ref.resource where locale = 'en' order by 1;" > "$p.resources"
  psql -d "$db" -tAc "select code||' :: '||array_to_string(artefacts,'|') from erp_ref.part5_capability order by 1;" > "$p.part5"
  psql -d "$db" -tAc "
    select f.oid::regprocedure::text||' -> '||coalesce(array_to_string(f.proacl,','),'(default)')
      from pg_proc f where f.pronamespace = 'public'::regnamespace and f.proname like 'erp\_%'
     order by 1;" > "$p.grants"
}

echo "building the production baseline (repository minus ${#MISSING[@]} migrations)"
build erpware_eq_baseline yes

echo "building the whole repository from empty"
build erpware_eq_target no

echo "applying the reconciliation to the baseline"
PGDATABASE=erpware_eq_baseline $PSQL --single-transaction \
  -f "$HERE/20260831_live_reconciliation.sql" >/dev/null

echo "applying it a second time, which must change nothing"
PGDATABASE=erpware_eq_baseline $PSQL --single-transaction \
  -f "$HERE/20260831_live_reconciliation.sql" >/dev/null

echo "applying it to the target, where it must be a no-op"
PGDATABASE=erpware_eq_target $PSQL --single-transaction \
  -f "$HERE/20260831_live_reconciliation.sql" >/dev/null

dump erpware_eq_baseline "$WORK/reconciled"
dump erpware_eq_target   "$WORK/target"

echo
failed=0
for part in routines columns triggers policies writeallow definer basetypes resources part5 grants; do
  if diff -q "$WORK/reconciled.$part" "$WORK/target.$part" >/dev/null; then
    printf '  %-11s identical  (%s rows)\n' "$part" "$(wc -l < "$WORK/target.$part" | tr -d ' ')"
  else
    printf '  %-11s DIFFERS\n' "$part"
    diff "$WORK/reconciled.$part" "$WORK/target.$part" | head -20 | sed 's/^/      /'
    failed=1
  fi
done

echo
if [ "$failed" -eq 0 ]; then
  echo "equivalent: the reconciled baseline matches the repository on all ten dimensions"
else
  echo "NOT equivalent — see the differences above" >&2
fi
exit "$failed"
