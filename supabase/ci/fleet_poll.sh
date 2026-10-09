#!/usr/bin/env bash
#
# How each client is, read from its own database and the Management API, and
# written on its row in the control plane's register for the Fleet view.
#
# One Supabase project per client (the owner's decision of 7 October) means
# a client's health is in a database the control plane cannot see: whether
# its last release was proved, whether its assurance is green, how big it
# has grown on a 1 GB instance, whether its email still drains, whether
# somebody is inside it on a support window, whether its staff list is the
# control plane's, and whether Supabase has backed it up. Until this, each of
# those was a question somebody had to think to ask, one project at a time.
#
# For each client in the register whose database is up (built, live,
# suspended or retiring: a suspended client's address is not served, and its
# project runs on), or the one code given, one at a time, over its connection
# string from the control plane's vault
# (masked the moment it is read, refused unless it names its own project and
# no other deployment's, and its database must say it is a client's):
#
#   release_sha           the newest proved release (erp_meta.release), read
#                         as app.yml reads it to decide what to ship
#   database_bytes        pg_database_size(current_database())
#   last_drain_pass_at    the newest finished drain pass (erp_meta.drain_pass)
#   open_support_windows  support windows not yet expired (erp.support_access,
#                         as the client's console lists them)
#   staff_in_step         its active staff, address and rank, are exactly the
#                         control plane's (fleet_staff_sync.sh keeps them so)
#   backups_latest_at,    its completed backups, from the Management API
#   backups_count         (GET /v1/projects/<ref>/database/backups)
#   assurance_failures,   full only: erp.platform_assurance(), the checks not
#   assurance_at          green, and when. A light poll carries the last full
#                         poll's figures forward rather than forgetting them
#   errors                what could not be read, each in plain words
#   polled_at
#
# and writes them with erp_meta.record_deployment_health(code, health) on the
# control plane (20261012010000); before that routine is released they are
# printed here and in the summary only. A client that cannot be read at all
# is still written, with errors saying why, so the Fleet view says so within
# the hour; the register's "silent" flag is for a poll that has stopped.
#
# And its usage, every poll: erp_meta.usage_meter for the current month and
# the two before it, summed by meter and period over every organisation its
# database holds or held and purged (a purge is audited as
# platform.tenant_purged, and a re-onboarded organisation has a new id, so a
# month both shared counts both), and only those: the meters of the test
# organisations a build from empty runs its suites with are left out (their
# rows stay behind, deleted with no purge recorded). Written with
# erp_meta.record_deployment_usage(code, rows) on the
# control plane (20261012040000), which replaces each period's figure and
# deletes none. A meter with no row in those months is not measured (nothing
# runs erp.measure_active_users, so active_users never is), which is not
# nought: it is sent as no row, and said as not measured. The figures are a
# named client's business and these logs are public, so only how many rows
# were read is printed, never a quantity. A usage that cannot be read is an
# entry in errors, like any other reading.
#
# One client never stops the poll: every reading is its own statement, a
# statement that fails or runs out of time is an entry in errors, and the
# next client is read all the same.
#
# Usage: fleet_poll.sh light|full [code]
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL    the control plane (required)
#   SUPABASE_ACCESS_TOKEN         the Management API, for the backups; without
#                                 it they are an entry in errors
#   PRODUCTION_REF, DEMO_REF      refs a client's connection must not name, as
#                                 well as every other ref in the register
#   PSQL, CURL                    the commands (the rehearsal's stand-ins)
#   CLIENT_STATEMENT_TIMEOUT      each reading (default 30s): the pooler
#                                 drops PGOPTIONS, so it is set in SQL
#   ASSURANCE_STATEMENT_TIMEOUT   the assurance, full only (default 5min)
#   PAUSE_SECONDS                 between clients (default 5)
#   FLEET_SLEEP                   the sleep command (default sleep)
#   PGCONNECT_TIMEOUT             seconds to reach a database (default 15)
#   and the MAPI_* settings of supabase/ci/management_api.sh.
#
# Exit: 0 when every client's health was written (a client that could not be
# read is a warning and an entry in its errors); 1 when the control plane
# could not be read or a client's health or usage could not be written on it;
# 2 when nothing was tried.
#
# bash 3.2 and 5. Rehearsed on every build with a psql and a curl that answer
# from a script: supabase/ci/fleet_poll_rehearsal.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# mapi: the Management API asked with the fleet's patience.
# shellcheck source=supabase/ci/management_api.sh
. "$HERE/management_api.sh"

MODE="${1:-}"
ONLY="${2:-}"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
SLEEP_CMD="${FLEET_SLEEP:-sleep}"
PAUSE="${PAUSE_SECONDS:-5}"
TIMEOUT="${CLIENT_STATEMENT_TIMEOUT:-30s}"
ASSURANCE_TIMEOUT="${ASSURANCE_STATEMENT_TIMEOUT:-5min}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"
export PGAPPNAME="${PGAPPNAME:-fleet_poll}"

is_code() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]]; }
is_ref() { [[ "$1" =~ ^[a-z0-9]{20}$ ]]; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

case "$MODE" in
  light|full) : ;;
  *)
    echo "::error::the poll is light (every hour) or full (once a day, with the assurance), not '${MODE}'. Nothing was read."
    exit 2 ;;
esac
if [[ -z "$CP_URL" ]]; then
  echo "::error::CLOVEERP_LIVE_DATABASE_URL is not set, so the register cannot be read or written. Nothing was read."
  exit 2
fi
if [[ -n "$ONLY" ]] && ! is_code "$ONLY"; then
  echo "::error::'${ONLY}' is not a client's code. Nothing was read."
  exit 2
fi
if ! [[ "$PAUSE" =~ ^[0-9]+$ ]]; then
  echo "::error::PAUSE_SECONDS must be a whole number. Nothing was read."
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_poll.XXXXXX")
trap 'rm -rf "$work"' EXIT

# On a runner GitHub hides a value printed after this; a terminal would show
# it, so nowhere else.
mask() {
  if [[ "${GITHUB_ACTIONS:-}" == true && -n "${1:-}" ]]; then
    echo "::add-mask::$1"
  fi
}

# One line of what went wrong, cut by character (jq), never half of one.
one_line() {
  printf '%s' "${1:-no reason given}" | tr -s ' \t\r\n' '    ' | jq -Rr '.[0:300]'
}
said() {
  local first
  first=$(grep -E 'ERROR|FATAL|error|refus|answered|could not|^x ' "$work/err" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$work/err" 2> /dev/null || true)
  first="${first#psql:<stdin>:*: }"
  one_line "$first"
}

cp_q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }
reg() { CLOVEERP_LIVE_DATABASE_URL="$CP_URL" PSQL="$PSQL_CMD" "$HERE/fleet_register.sh" "$@"; }

# ── The control plane: who to poll, and where to write it ────────────────────
ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regclass('erp_meta.deployment') is not null)::text
       || ' ' || (to_regprocedure('erp_meta.record_deployment_health(text,jsonb)') is not null)::text
       || ' ' || (to_regprocedure('erp_meta.record_deployment_usage(text,jsonb)') is not null)::text;
SQL
) || { echo "::error::the control plane could not be read ($(said)). Nothing was polled."; exit 1; }
read -r has_register can_record can_usage <<< "$ready"
if [[ "$has_register" != true ]]; then
  echo "the control plane has no register of deployments yet, so there is no client to poll"
  exit 0
fi
if [[ "$can_record" != true ]]; then
  echo "::notice::the control plane has no erp_meta.record_deployment_health yet (20261012010000 is not released there), so what is read is said here and in the summary, and written nowhere."
fi
if [[ "$can_usage" != true ]]; then
  echo "::notice::the control plane has no erp_meta.record_deployment_usage yet (20261012040000 is not released there), so each client's usage is read, counted here, and written nowhere."
fi

staff=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-staff
select coalesce(jsonb_agg(lower(btrim(s.email)) || ':' || s.staff_role order by lower(btrim(s.email)), s.staff_role), '[]'::jsonb)
  from erp_meta.platform_staff s
 where s.revoked_at is null;
SQL
) || { echo "::error::the control plane's staff list could not be read ($(said)). Nothing was polled."; exit 1; }
staff=$(jq -cS 'sort' <<< "$staff")

clients=$(cp_q -v only="$ONLY" 2> "$work/err" <<'SQL'
-- fleet: cp-clients
select coalesce(jsonb_agg(jsonb_build_object('code', d.code, 'ref', d.project_ref,
                                             'health', coalesce(to_jsonb(d) -> 'health', '{}'::jsonb))
                          order by d.code), '[]'::jsonb)
  from erp_meta.deployment d
 where d.status in ('built', 'live', 'suspended', 'retiring')
   and (d.status <> 'retiring' or d.built_at is not null)
   and d.project_ref is not null
   and (:'only' = '' or d.code = :'only');
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). Nothing was polled."; exit 1; }
all_refs=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '') from erp_meta.deployment d where d.project_ref is not null;
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). Nothing was polled."; exit 1; }
all_refs="${all_refs},${PRODUCTION_REF:-xpzffnnhnhcqyjqcueja},${DEMO_REF:-}"

count=$(jq 'length' <<< "$clients")
if [[ "$count" -eq 0 ]]; then
  if [[ -n "$ONLY" ]]; then
    echo "::error::'${ONLY}' is not a client in the register whose database is up (built, live, suspended or retiring). Nothing was polled."
    exit 1
  fi
  echo "no client in the register has a database that is up (built, live, suspended or retiring); nothing to poll"
  exit 0
fi

echo "a ${MODE} poll of ${count} client(s)"
{
  echo "## The fleet's health (${MODE} poll)"
  echo
  echo "| client | release | assurance | size | last drain pass | support windows | staff | backups | usage | not read |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
} >> "$SUMMARY"

unwritten=0
unread=0

# ── One client ───────────────────────────────────────────────────────────────
poll_client() {
  local code="$1" ref="$2" prior="$3"
  local url="" vault rc line key value k items missing errs other
  local health errors read_ok=no usage usage_rows="" usage_words="" unwritten_here=no
  local -a others
  errors='[]'
  health='{}'

  # missed <words>: one more thing that could not be read.
  missed() { errors=$(jq -c --arg e "$(one_line "$*")" '. + [$e]' <<< "$errors"); }
  # put <key> <json value>: one reading.
  put() { health=$(jq -c --arg k "$1" --argjson v "$2" '. + {($k): $v}' <<< "$health"); }

  # Its connection, as release.yml resolves it.
  if ! is_ref "$ref"; then
    missed "the register gives it no project ref ('${ref}')"
  else
    vault="cloveerp:deployment:${ref}:db_url"
    if ! url=$(reg vault-get "$vault" 2> "$work/err"); then
      url=""
      missed "the control plane's vault could not be read for ${vault} ($(said))"
    else
      mask "$url"
      if [[ -z "$url" ]]; then
        missed "the control plane's vault has no ${vault}, so its database cannot be reached"
      elif [[ "$url" != *"$ref"* ]]; then
        missed "${vault} does not name its project (${ref}), so it was not read"
        url=""
      else
        IFS=',' read -r -a others <<< "$all_refs"
        for other in ${others[@]+"${others[@]}"}; do
          other="${other// /}"
          if [[ -n "$other" && "$other" != "$ref" && "$url" == *"$other"* ]]; then
            missed "${vault} names another deployment's project (${other}), so it was not read"
            url=""
            break
          fi
        done
      fi
    fi
  fi

  # Its database: every reading its own statement, so one that fails or
  # runs out of time costs that reading and no other (ON_ERROR_STOP off).
  if [[ -n "$url" ]]; then
    rc=0
    $PSQL_CMD "$url" -v ON_ERROR_STOP=0 -X -q -tA -v timeout="$TIMEOUT" > "$work/out" 2> "$work/err" <<'SQL' || rc=$?
-- fleet: client-health
set statement_timeout = :'timeout';
select 'kind' || chr(9) || erp.deployment_kind();
select 'release_sha' || chr(9) || coalesce((select r.git_sha from erp_meta.release r where r.proved_at is not null and r.git_sha is not null order by r.recorded_at desc limit 1), '');
select 'database_bytes' || chr(9) || pg_database_size(current_database());
select 'last_drain_pass_at' || chr(9) || coalesce((select to_char(max(p.finished_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') from erp_meta.drain_pass p), '');
select 'open_support_windows' || chr(9) || (select count(*) from erp.support_access a where a.expires_at > now());
select 'staff' || chr(9) || coalesce((select jsonb_agg(lower(btrim(s.email)) || ':' || s.staff_role order by lower(btrim(s.email)), s.staff_role) from erp_meta.platform_staff s where s.revoked_at is null), '[]'::jsonb)::text;
select 'usage' || chr(9) || jsonb_build_object(
         'kinds', coalesce((select jsonb_agg(k.code order by k.code) from erp_meta.meter_kind k), '[]'::jsonb),
         'rows', coalesce((select jsonb_agg(jsonb_build_object('meter_code', u.meter_code, 'period_start', u.period_start,
                                                               'period_end', u.period_end, 'quantity', u.quantity,
                                                               'measured_at', u.measured_at)
                                            order by u.meter_code, u.period_start, u.period_end)
                             from (select m.meter_code, m.period_start, m.period_end,
                                          sum(m.quantity) as quantity, max(m.measured_at) as measured_at
                                     from erp_meta.usage_meter m
                                    where m.period_start >= (date_trunc('month', current_date) - interval '2 months')::date
                                      and m.period_start <= current_date
                                      and (exists (select 1 from erp.tenant t where t.id = m.tenant_id)
                                           or exists (select 1 from erp_meta.platform_audit a
                                                       where a.action = 'platform.tenant_purged'
                                                         and a.tenant_id = m.tenant_id))
                                    group by m.meter_code, m.period_start, m.period_end) u), '[]'::jsonb))::text;
SQL
    if [[ "$rc" -ne 0 || ! -s "$work/out" ]]; then
      missed "its database could not be reached or read ($(said))"
    else
      value=$(sed -n 's/^kind	//p' "$work/out" | head -n 1)
      if [[ "$value" != client ]]; then
        missed "its database says it is the ${value:-unknown} deployment, not a client's, so nothing it says was kept"
      else
        read_ok=yes
      fi
    fi
  fi

  if [[ "$read_ok" == yes ]]; then
    # The statements that said nothing, paired in order with the errors
    # psql gave: each failed statement gives exactly one.
    grep -E '(^|: )(ERROR|FATAL):' "$work/err" > "$work/errors" 2> /dev/null || true
    errs=0
    missing=""
    for k in release_sha database_bytes last_drain_pass_at open_support_windows staff usage; do
      if ! grep -q "^${k}	" "$work/out"; then
        missing="${missing} ${k}"
      fi
    done
    for k in $missing; do
      errs=$((errs + 1))
      line=$(sed -n "${errs}p" "$work/errors")
      line="${line#psql:<stdin>:*: }"
      missed "${k} could not be read (${line:-no reason given})"
    done

    value=$(sed -n 's/^release_sha	//p' "$work/out" | head -n 1)
    if [[ -n "$value" ]]; then put release_sha "$(jq -cn --arg v "$value" '$v')"; fi
    value=$(sed -n 's/^database_bytes	//p' "$work/out" | head -n 1)
    if [[ "$value" =~ ^[0-9]+$ ]]; then put database_bytes "$value"; fi
    value=$(sed -n 's/^last_drain_pass_at	//p' "$work/out" | head -n 1)
    if [[ -n "$value" ]]; then put last_drain_pass_at "$(jq -cn --arg v "$value" '$v')"; fi
    value=$(sed -n 's/^open_support_windows	//p' "$work/out" | head -n 1)
    if [[ "$value" =~ ^[0-9]+$ ]]; then put open_support_windows "$value"; fi
    value=$(sed -n 's/^staff	//p' "$work/out" | head -n 1)
    if [[ -n "$value" ]]; then
      if value=$(jq -cS 'sort' <<< "$value" 2> /dev/null); then
        if [[ "$value" == "$staff" ]]; then put staff_in_step true; else put staff_in_step false; fi
      else
        missed "its staff list came back in a shape that could not be read"
      fi
    fi

    # Its usage: the rows as the control plane keeps them, and the meters
    # with none in these months, which are not measured (never nought).
    value=$(sed -n 's/^usage	//p' "$work/out" | head -n 1)
    if [[ -n "$value" ]]; then
      if usage=$(jq -ce '
            select(type == "object" and (.rows | type) == "array" and (.kinds | type) == "array")
            | select(all(.rows[]; (.meter_code | type) == "string" and (.period_start | type) == "string"
                                  and (.period_end | type) == "string" and (.quantity | type) == "number" and .quantity >= 0))
            | {rows, not_measured: (.kinds - [.rows[].meter_code])}' <<< "$value" 2> /dev/null); then
        usage_rows=$(jq -c '.rows' <<< "$usage")
        usage_words="$(jq -r '.rows | length' <<< "$usage") row(s)"
        k=$(jq -r '.not_measured | join(", ")' <<< "$usage")
        if [[ -n "$k" ]]; then usage_words="${usage_words}; not measured: ${k}"; fi
      else
        missed "its usage came back in a shape that could not be read"
      fi
    fi
  fi

  # The assurance, once a day: the same checks every release proves.
  if [[ "$MODE" == full && "$read_ok" == yes ]]; then
    rc=0
    $PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$ASSURANCE_TIMEOUT" > "$work/out" 2> "$work/err" <<'SQL' || rc=$?
-- fleet: client-assurance
set statement_timeout = :'timeout';
select count(*) filter (where a ->> 'ok' = 'false') || chr(9) || count(*) || chr(9)
       || coalesce(string_agg(a ->> 'code', ' ' order by a ->> 'code') filter (where a ->> 'ok' = 'false'), '')
  from jsonb_array_elements(erp.platform_assurance()) a;
SQL
    IFS='	' read -r value items k < "$work/out" || true
    if [[ "$rc" -eq 0 && "$value" =~ ^[0-9]+$ ]]; then
      put assurance_failures "$value"
      put assurance_at "$(jq -cn --arg v "$(now)" '$v')"
      if [[ "$value" -gt 0 ]]; then
        echo "::warning::${code}: ${value} of ${items} assurance check(s) not green: ${k}"
      fi
    else
      missed "the assurance could not be run ($(said))"
    fi
  elif [[ "$MODE" == light ]]; then
    # A light poll does not run it; the last full poll's figures stand.
    value=$(jq -c '{assurance_failures, assurance_at} | with_entries(select(.value != null))' <<< "$prior" 2> /dev/null || echo '{}')
    health=$(jq -c --argjson p "$value" '. + $p' <<< "$health")
  fi

  # Its backups, from the Management API.
  if is_ref "$ref"; then
    if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
      missed "the backups were not asked for: SUPABASE_ACCESS_TOKEN is not available to the poll"
    elif [[ -n "$backups_down" ]]; then
      missed "the backups were not asked for: the Management API did not answer for ${backups_down} earlier in this poll"
    elif value=$(MAPI_ATTEMPTS="${POLL_MAPI_ATTEMPTS:-2}" MAPI_TIMEOUT="${POLL_MAPI_TIMEOUT:-20}" MAPI_MAX_WAIT="${POLL_MAPI_MAX_WAIT:-30}" \
                 mapi GET "/v1/projects/${ref}/database/backups" 2> "$work/err"); then
      sed -n '/^!/p' "$work/err"
      if items=$(jq -c '[(.backups // [])[] | select(.status == "COMPLETED")]
                        | {backups_count: length,
                           backups_latest_at: (map(.inserted_at) | max)}
                        | with_entries(select(.value != null))' <<< "$value" 2> /dev/null); then
        health=$(jq -c --argjson b "$items" '. + $b' <<< "$health")
      else
        missed "the backups came back in a shape that could not be read"
      fi
    else
      sed -n '/^!/p' "$work/err"
      # An API that is down (busy, failing or silent to the end) is not asked
      # again for the rest of this poll: every client's database readings are
      # written well inside the job's time, and the backups wait an hour.
      if grep -qE 'had no answer|on each of|longer than MAPI_MAX_WAIT' "$work/err"; then backups_down="$code"; fi
      missed "the backups could not be read ($(said))"
    fi
  fi

  health=$(jq -c --argjson e "$errors" --arg at "$(now)" '. + {errors: $e, polled_at: $at}' <<< "$health")

  if [[ "$(jq 'length' <<< "$errors")" -gt 0 ]]; then
    unread=$((unread + 1))
    echo "::warning::${code}: $(jq -r 'join("; ")' <<< "$errors")"
  fi
  echo "${code}: ${health}"
  # How much was read, never a figure: a named client's usage is its business.
  if [[ -n "$usage_words" ]]; then echo "${code}: usage, ${usage_words}"; fi
  jq -r --arg c "$code" --arg u "$usage_words" '"| \($c) | \(.release_sha // "" | .[0:7]) | \(if .assurance_failures == null then "" elif .assurance_failures == 0 then "green" else "\(.assurance_failures) not green" end) | \(if .database_bytes == null then "" else "\(.database_bytes / 1048576 | floor) MB" end) | \(.last_drain_pass_at // "") | \(.open_support_windows // "") | \(if .staff_in_step == null then "" elif .staff_in_step then "in step" else "out of step" end) | \(if .backups_count == null then "" else "\(.backups_count), newest \(.backups_latest_at // "none")" end) | \($u) | \(.errors | join("; ")) |"' <<< "$health" >> "$SUMMARY"

  if [[ "$can_record" == true ]]; then
    if ! cp_q -v code="$code" -v health="$health" > /dev/null 2> "$work/err" <<'SQL'
-- fleet: cp-record-health
select erp_meta.record_deployment_health(:'code', :'health'::jsonb);
SQL
    then
      echo "::error::${code}: its health could not be written on the control plane ($(said))."
      unwritten_here=yes
    fi
  fi

  # Its usage, when there is a row of it: none sent is none deleted.
  if [[ "$can_usage" == true && -n "$usage_rows" && "$usage_rows" != "[]" ]]; then
    if ! cp_q -v code="$code" -v usage="$usage_rows" > /dev/null 2> "$work/err" <<'SQL'
-- fleet: cp-record-usage
\set VERBOSITY terse
select erp_meta.record_deployment_usage(:'code', :'usage'::jsonb);
SQL
    then
      # The refusal's code, never its words, which may quote a figure; and
      # VERBOSITY terse keeps the DETAIL that would from being printed at all.
      k=$(grep -oE 'CLOVEERP_[A-Z0-9_]+' "$work/err" 2> /dev/null | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//' || true)
      if [[ -z "$k" ]] && grep -q 'statement timeout' "$work/err" 2> /dev/null; then k="a statement timeout"; fi
      echo "::error::${code}: its usage could not be written on the control plane (${k:-an error that names no CLOVEERP_ code})."
      unwritten_here=yes
    fi
  fi
  if [[ "$unwritten_here" == yes ]]; then unwritten=$((unwritten + 1)); fi
  return 0
}

# Set once the Management API stops answering, so later clients are not kept
# waiting on it (their database readings still are taken).
backups_down=""
for ((c = 0; c < count; c++)); do
  if [[ "$c" -gt 0 && "$PAUSE" -gt 0 ]]; then
    $SLEEP_CMD "$PAUSE"
  fi
  poll_client "$(jq -r ".[$c].code" <<< "$clients")" \
              "$(jq -r ".[$c].ref" <<< "$clients")" \
              "$(jq -c ".[$c].health // {}" <<< "$clients")"
done

if [[ "$unwritten" -gt 0 ]]; then
  echo "::error::the health or usage of ${unwritten} of ${count} client(s) could not be written on the control plane; each is said above. Every client was read."
  exit 1
fi
if [[ "$unread" -gt 0 ]]; then
  echo "${count} client(s) polled; ${unread} with something that could not be read, each said above and in its errors"
else
  echo "${count} client(s) polled; everything read"
fi
