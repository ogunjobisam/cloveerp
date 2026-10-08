#!/usr/bin/env bash
#
# Build an empty Supabase project from the migrations: the demonstration's
# first build, and every client's (.github/workflows/deployment_from_empty.yml).
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
#   the door     ...and that is only enough if nobody else can be there first.
#                20260830091046 itself makes owner whoever already signed up
#                as admin@erpware.dev, and the staff list is matched by email.
#                So this refuses to start unless the project's own settings,
#                read through the Management API, say sign-up is closed and an
#                address must be confirmed, and unless the only sign-in the
#                project holds is the owner's, confirmed: the owner makes it in
#                the dashboard before the build, and the build binds the staff
#                row to it. It refuses to call the build finished unless the
#                staff list is exactly that one row.
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
#   SUPABASE_ACCESS_TOKEN, PROJECT_REF
#                 required: the project's auth settings are read through the
#                 Management API (GET /v1/projects/<ref>/config/auth), with
#                 the patience of supabase/ci/management_api.sh (API, MAPI_*)
#   CURL          the curl command (default: curl)
#   PROGRESS_EVERY
#                 report progress after every this many migrations applied
#                 (default 0: never). A build runs for hours, and its log is
#                 not where the Fleet view looks
#   PROGRESS_CMD  the command that reports it, given "<n> of <total>
#                 migrations applied" as its last argument; split on spaces,
#                 so a plain command and its first arguments. Its failure
#                 never stops the build: progress is a courtesy, the
#                 migrations are the work
#   CHECK_ONLY    yes to make every check that comes before the build and stop
#                 there, changing nothing (deployment_from_empty.yml runs it before it
#                 provides anything)
set -euo pipefail

DB="${1:?usage: build_from_empty.sh <database url> <owner email>}"
OWNER="${2:?usage: build_from_empty.sh <database url> <owner email>}"
PSQL_CMD="${PSQL:-psql}"
RESUME="${RESUME:-no}"
VACUUM_EVERY="${VACUUM_EVERY:-20}"
PAUSE_SECONDS="${PAUSE_SECONDS:-0}"
CHECK_ONLY="${CHECK_ONLY:-no}"
PROGRESS_EVERY="${PROGRESS_EVERY:-0}"
PROGRESS_CMD="${PROGRESS_CMD:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supabase/ci/management_api.sh
. "$HERE/management_api.sh"

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
[[ "$PROGRESS_EVERY" =~ ^[0-9]+$ ]] || refuse "PROGRESS_EVERY must be a whole number."
[[ "$PROGRESS_EVERY" -eq 0 || -n "${PROGRESS_CMD// /}" ]] ||
  refuse "PROGRESS_EVERY is ${PROGRESS_EVERY} and PROGRESS_CMD is not set: there is nothing to report progress with."

q() { $PSQL_CMD "$DB" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }

# progress <words>: PROGRESS_CMD with the words as its last argument. Never
# fatal, and never reading the replay's standard input.
progress() {
  local cmd
  read -r -a cmd <<< "$PROGRESS_CMD"
  "${cmd[@]}" "$1" < /dev/null ||
    echo "! progress was not reported (${cmd[0]} exited $?); the build carries on"
}

# The owner as a SQL literal, for the few checks below that are not run
# through a psql variable.
OWNER_SQL="'$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]' | sed "s/'/''/g")'"

# ── Nobody can be there first ────────────────────────────────────────────────
[[ -n "${SUPABASE_ACCESS_TOKEN:-}" && "${PROJECT_REF:-}" =~ ^[a-z0-9]{20}$ ]] ||
  refuse "SUPABASE_ACCESS_TOKEN and PROJECT_REF are needed to read the project's auth settings; without them nothing says a stranger cannot sign up first."
auth=$(mapi GET "/v1/projects/${PROJECT_REF}/config/auth") ||
  refuse "could not read the project's auth settings from the Management API, so nothing says a stranger cannot sign up first. Nothing was changed."
[[ "$(jq -r '.disable_signup' <<< "$auth")" == "true" ]] ||
  refuse "sign-up is open on ${PROJECT_REF}. Turn it off (Authentication, Sign In / Providers, Allow new users to sign up) before the build: anybody who signs up while it runs could be matched to the platform's staff."
[[ "$(jq -r '.mailer_autoconfirm' <<< "$auth")" == "false" ]] ||
  refuse "${PROJECT_REF} confirms email addresses without asking (mailer_autoconfirm). Turn Confirm email on before the build: the platform's staff are recognised by a confirmed address."

users=$(q -c "select count(*) || ' ' || count(*) filter (where lower(email) = ${OWNER_SQL} and email_confirmed_at is not null) from auth.users")
if [[ "$users" != "1 1" ]]; then
  refuse "auth.users must hold exactly one sign-in, the owner's (${OWNER}), with its address confirmed; it holds ${users%% *}, of which ${users##* } is the owner's confirmed. Create it in the dashboard (Authentication, Users, Add user, with Auto Confirm User) and delete any other before the build."
fi

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

if [[ "$CHECK_ONLY" == yes ]]; then
  echo "checked: sign-up closed, confirmation required, the owner's confirmed sign-in is the only one, and the database is ready to build (resume: ${RESUME})"
  exit 0
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
  -- Bound to the owner's own confirmed sign-in, which the build refused to
  -- start without, so the row is theirs by id and not only by address.
  if v_empty then
    execute format(
      'insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role) '
      'select %L, (select u.id from auth.users u where lower(u.email) = %L and u.email_confirmed_at is not null limit 1), %L, %L',
      lower(current_setting('cloveerp.platform_owner')),
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
  if [[ "$PROGRESS_EVERY" -gt 0 && $((done_now % PROGRESS_EVERY)) -eq 0 ]]; then
    progress "$((done_now + skipped)) of ${total} migrations applied"
  fi

  if [[ "$VACUUM_EVERY" -gt 0 && "$since_vacuum" -ge "$VACUUM_EVERY" ]]; then
    # Outside the transaction, which VACUUM cannot run inside. Best effort:
    # what this role may not vacuum it is told so and skips.
    $PSQL_CMD "$DB" -X -q -c "vacuum analyze" > /dev/null 2>&1 || true
    since_vacuum=0
  fi
  [[ "$PAUSE_SECONDS" -eq 0 ]] || sleep "$PAUSE_SECONDS"
done

$PSQL_CMD "$DB" -X -q -v ON_ERROR_STOP=1 -c "analyze" > /dev/null

# Exactly one active row on the staff list: the owner, bound to their
# confirmed sign-in. Anything else — nobody, an unbound row, a second active
# row a migration made — is a console somebody other than the owner might
# reach. A revoked row (revoked_at set) is not: erp_meta.platform_actor() never
# matches one, and release.yml makes this same count before every release,
# where counting revoked rows would have refused every release for good once
# anybody had been added and removed (review of #448, COV-3).
staff=$(q -c "
  select count(*) || ' ' || count(*) filter (
           where lower(s.email) = ${OWNER_SQL}
             and s.staff_role = 'owner'
             and s.auth_user_id = (select u.id from auth.users u
                                    where lower(u.email) = ${OWNER_SQL}
                                      and u.email_confirmed_at is not null
                                    limit 1))
    from erp_meta.platform_staff s where s.revoked_at is null")
[[ "$staff" == "1 1" ]] || {
  echo "x every migration applied, and the platform's staff list is not exactly ${OWNER}, bound to their confirmed sign-in (active rows: ${staff%% *}; the owner's, bound: ${staff##* }). The console is not safe to open; nothing else is wrong." >&2
  exit 1
}

echo "built: $done_now migration(s) applied, $skipped already recorded, $total in all, in $(( $(date +%s) - started )) s; $OWNER is the platform's owner"
