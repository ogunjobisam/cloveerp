#!/usr/bin/env bash
#
# Build an empty Supabase project from the migrations: the demonstration's
# first build (.github/workflows/demo_from_empty.yml).
#
# A release (release.yml) applies what a deployment has not run with
# `supabase db push`, and that is right for a database that already holds
# everything before it. It is wrong for an empty one, three ways:
#
#   the replay   every migration from 0001, including suite calls that later
#                migrations corrected; supabase/ci/replay_migrations.sh says
#                which, and the schema build skips them the same way
#                (supabase/ci/replay_superseded_calls.txt).
#   the clock    the session pooler drops PGOPTIONS, so a statement_timeout
#                given there never applies (21 September), and an old
#                migration's tail runs suites for minutes. Each migration here
#                runs after an explicit `set statement_timeout = 0`, a
#                statement the server executes, in the same session.
#   the owner    public.erp_platform_claim_ownership() makes the first person
#                to ask the platform's owner while the staff list is empty,
#                and this project is public while it builds. So the owner is
#                written into erp_meta.platform_staff inside the transaction
#                of the migration that creates it: there is no committed state
#                in which the list exists and is empty (20261010062000).
#
# Each migration is one transaction, and the same transaction records it in
# supabase_migrations.schema_migrations, the table the Supabase CLI keeps, so
# the next `supabase db push` finds every one applied, and a build that stops
# part-way resumes at the migration that stopped it.
#
# Usage: build_from_empty.sh <database url> <owner email>
#
# Environment:
#   PSQL          the psql command (default: psql)
#   RESUME        yes to carry on a build that stopped part-way. Otherwise a
#                 database with an erp schema, or with any migration recorded,
#                 is refused.
#   REPLAY_DIR    migrations already prepared by replay_migrations.sh (default:
#                 prepared here, in a temporary directory)
#   VACUUM_EVERY  vacuum and analyse after this many migrations (default 20):
#                 six hundred migrations of DDL bloat the catalogue, and a
#                 replay that is not vacuumed slows to minutes a migration
#   PAUSE_SECONDS rest between migrations (default 0). The demonstration is a
#                 1 GB instance, and a small instance's disk runs on a burst
#                 budget that a sustained write drains (5 October); one
#                 migration at a time, one connection, with a rest between,
#                 keeps the build from being one long burst
set -euo pipefail

DB="${1:?usage: build_from_empty.sh <database url> <owner email>}"
OWNER="${2:?usage: build_from_empty.sh <database url> <owner email>}"
PSQL_CMD="${PSQL:-psql}"
RESUME="${RESUME:-no}"
VACUUM_EVERY="${VACUUM_EVERY:-20}"
PAUSE_SECONDS="${PAUSE_SECONDS:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

refuse() {
  echo "x $*" >&2
  exit 2
}

# The owner is written into SQL through a psql variable, quoted by psql; the
# shape is checked anyway, so a typo is said here and not by the database an
# hour in.
[[ "$OWNER" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
  refuse "'$OWNER' is not an email address; the platform's owner is named by the address they sign in with."
[[ "$VACUUM_EVERY" =~ ^[0-9]+$ ]] || refuse "VACUUM_EVERY must be a whole number."
[[ "$PAUSE_SECONDS" =~ ^[0-9]+$ ]] || refuse "PAUSE_SECONDS must be a whole number."

q() { $PSQL_CMD "$DB" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }

# ── What is there already ────────────────────────────────────────────────────
has_erp=$(q -c "select to_regnamespace('erp') is not null")
has_history=$(q -c "select to_regclass('supabase_migrations.schema_migrations') is not null")
recorded=0
if [[ "$has_history" == "t" ]]; then
  recorded=$(q -c "select count(*) from supabase_migrations.schema_migrations")
fi

if [[ "$RESUME" == yes ]]; then
  # Carrying on is for a build that this script started and that stopped: the
  # history it kept says where, and no organisation has been made since. A
  # database where anybody trades is never "carried on".
  [[ "$has_history" == "t" && "$recorded" -gt 0 ]] ||
    refuse "RESUME=yes, but this database has no migration recorded: there is nothing to carry on. Run without it."
  if [[ "$has_erp" == "t" ]]; then
    tenants=$(q -c "select case when to_regclass('erp.tenant') is null then 0 else (select count(*) from erp.tenant) end")
    [[ "$tenants" -eq 0 ]] ||
      refuse "RESUME=yes, but this database holds $tenants organisation(s); a build from empty is never carried on over a database somebody uses."
  fi
  echo "carrying on: $recorded migration(s) already recorded"
else
  [[ "$has_erp" != "t" ]] ||
    refuse "this database already has an erp schema; a build from empty builds empty databases only. A build that stopped part-way is carried on with RESUME=yes."
  [[ "$recorded" -eq 0 ]] ||
    refuse "this database already records $recorded migration(s) in supabase_migrations.schema_migrations, so something has been pushed to it; a build from empty builds empty databases only."
fi

# ── The history the CLI keeps, in the CLI's own shape ────────────────────────
# Create if absent and add the columns if missing, as `supabase db push` does
# itself, so whichever of the two arrives first the table is the same.
q -c "create schema if not exists supabase_migrations" \
  -c "create table if not exists supabase_migrations.schema_migrations (version text not null primary key)" \
  -c "alter table supabase_migrations.schema_migrations add column if not exists statements text[]" \
  -c "alter table supabase_migrations.schema_migrations add column if not exists name text" > /dev/null

applied="$(q -c "select version from supabase_migrations.schema_migrations")"

# ── The migrations a replay applies ──────────────────────────────────────────
if [[ -z "${REPLAY_DIR:-}" ]]; then
  REPLAY_DIR="$(mktemp -d)/migrations"
  "$HERE/replay_migrations.sh" "$REPLAY_DIR"
fi
[[ -d "$REPLAY_DIR" ]] || refuse "$REPLAY_DIR is not a directory."
REPLAY_DIR="$(cd "$REPLAY_DIR" && pwd)"

work="$(mktemp -d)"
log="$work/migration.log"
total=$(ls "$REPLAY_DIR"/*.sql | wc -l | tr -d ' ')
done_now=0
skipped=0
since_vacuum=0
started=$(date +%s)

for f in "$REPLAY_DIR"/*.sql; do
  base="$(basename "$f")"
  if ! [[ "$base" =~ ^([0-9]+)_([A-Za-z0-9_-]+)\.sql$ ]]; then
    refuse "$base is not named <version>_<name>.sql, so it cannot be recorded the way the CLI records it."
  fi
  version="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"

  if grep -qx "$version" <<< "$applied"; then
    skipped=$((skipped + 1))
    continue
  fi

  # One file, one transaction: the timeout, the migration, the owner and the
  # record. \i keeps the migration's own text exactly as replay_migrations.sh
  # left it.
  {
    echo "set statement_timeout = 0;"
    echo "\\i '$f'"
    cat <<'SQL'
-- The owner, from the moment there is a staff list to be on (20261010062000).
-- Through a setting rather than in the statement: psql does not interpolate a
-- variable inside a dollar-quoted body, and before the list exists an insert
-- naming it would not parse.
select set_config('cloveerp.platform_owner', :'owner', true) is not null as owner_set;
-- Every reference to the list is dynamic: PL/pgSQL plans a whole condition,
-- so naming the table in an `and` after to_regclass() fails before the list
-- exists rather than short-circuiting.
do $owner$
declare
  v_empty boolean;
begin
  if to_regclass('erp_meta.platform_staff') is null then
    return;
  end if;
  execute 'select not exists (select 1 from erp_meta.platform_staff s where s.revoked_at is null)'
     into v_empty;
  if v_empty then
    execute format(
      'insert into erp_meta.platform_staff (email, display_name, staff_role) values (%L, %L, %L)',
      lower(current_setting('cloveerp.platform_owner')),
      lower(current_setting('cloveerp.platform_owner')),
      'owner');
  end if;
end
$owner$;
insert into supabase_migrations.schema_migrations (version, name, statements)
values (:'version', :'name', '{}'::text[])
on conflict (version) do nothing;
SQL
  } > "$work/apply.sql"

  attempt=1
  while :; do
    if $PSQL_CMD "$DB" -X -q -v ON_ERROR_STOP=1 --single-transaction \
         -v owner="$OWNER" -v version="$version" -v name="$name" \
         -f "$work/apply.sql" > "$log" 2>&1; then
      break
    fi
    # A deadlock is a coincidence, not a verdict (release.yml says why): the
    # migration rolled back whole and goes again. Anything else stops the
    # build, and RESUME=yes carries on from this migration once it is fixed.
    if grep -q '40P01\|deadlock detected' "$log" && [[ "$attempt" -lt 3 ]]; then
      echo "! $base deadlocked on attempt $attempt; going again in $((attempt * ${DEADLOCK_WAIT:-30})) s"
      sleep $((attempt * ${DEADLOCK_WAIT:-30}))
      attempt=$((attempt + 1))
      continue
    fi
    echo "x $base failed; the $((done_now + skipped)) migration(s) before it are applied and recorded, and RESUME=yes carries on from it:" >&2
    sed -n '/ERROR:/,$p' "$log" | head -n 40 >&2
    grep -q 'ERROR:' "$log" || tail -n 40 "$log" >&2
    exit 1
  done

  done_now=$((done_now + 1))
  since_vacuum=$((since_vacuum + 1))
  echo "- $base ($((done_now + skipped))/$total)"

  if [[ "$VACUUM_EVERY" -gt 0 && "$since_vacuum" -ge "$VACUUM_EVERY" ]]; then
    # Outside the transaction, which VACUUM cannot run inside. Best effort:
    # what this role may not vacuum it is told so and skips.
    $PSQL_CMD "$DB" -X -q -c "vacuum analyze" > /dev/null 2>&1 || true
    since_vacuum=0
  fi
  [[ "$PAUSE_SECONDS" -eq 0 ]] || sleep "$PAUSE_SECONDS"
done

$PSQL_CMD "$DB" -X -q -v ON_ERROR_STOP=1 -c "analyze" > /dev/null

owner_rows=$(q -c "select count(*) from erp_meta.platform_staff where lower(email) = lower('$(printf '%s' "$OWNER" | sed "s/'/''/g")') and staff_role = 'owner' and revoked_at is null")
[[ "$owner_rows" -eq 1 ]] || {
  echo "x every migration applied, and $OWNER is not the platform's owner; the console is claimable. Nothing else is wrong; register them before anybody signs in." >&2
  exit 1
}

echo "built: $done_now migration(s) applied, $skipped already recorded, $total in all, in $(( $(date +%s) - started )) s; $OWNER is the platform's owner"
