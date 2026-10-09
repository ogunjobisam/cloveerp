#!/usr/bin/env bash
#
# Every client's own organisation, suspended or not as the control plane's
# register says (.github/workflows/fleet_sync.yml).
#
# The owner suspends a client from the Fleet view (erp_platform_suspend_
# deployment, 20261012030000), and the register says so: its address answers
# that the service is suspended, and the application boots nothing for it.
# But the client's project runs on, and its own database knew nothing of it:
# anyone holding a session, or calling its API with a key, carried on. So
# each client's one organisation follows the register here, through a routine
# no session role can run, erp_meta.follow_deployment_status(): suspended
# while the register holds a reason for the suspension (a suspended client,
# or one being offboarded while suspended), active again when it no longer
# does. erp.authorise refuses everything for a suspended organisation. The
# routine lifts only a suspension it made itself: an organisation suspended
# on the client's own console is left as it is, and said.
#
# For each client in the control plane's register whose database is up
# (built, live, suspended or retiring), or the one code given, one at a time:
#
#   1. its connection string from the control plane's vault
#      (cloveerp:deployment:<ref>:db_url), masked the moment it is read and
#      refused unless it names the client's project and no other
#      deployment's; and its database must say it is a client's;
#   2. erp_meta.follow_deployment_status(<suspended>, <the register's
#      reason>), when its database has been released it: one not yet
#      released it is noted and left for the next train, and one with no
#      organisation yet (a client is built empty, and onboarded later) has
#      nothing to follow, which is said in the summary and is not trouble;
#   3. what changed is written on the client's row in the register, as a
#      note beginning "status:"; what could not be done is written as a
#      failed note, and not the same trouble twice in a row, so an hourly
#      run does not bury the Fleet view. A client already in step writes
#      nothing.
#
# Usage: fleet_status_sync.sh [code]
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane (required)
#   PRODUCTION_REF, DEMO_REF    refs a client's connection must not name, as
#                               well as every other ref in the register
#   PSQL                        the command (the rehearsal's stand-in)
#   CLIENT_STATEMENT_TIMEOUT    each statement on a client (default 30s): the
#                               pooler drops PGOPTIONS, so it is set in SQL
#   PAUSE_SECONDS               between clients (default 2)
#   FLEET_SLEEP                 the sleep command (default sleep)
#   PGCONNECT_TIMEOUT           seconds to reach a database (default 15)
#
# Every value reaches SQL as a psql variable on standard input (psql
# substitutes :'name' only there, never in -c). Nothing read from the vault
# is printed: on a runner each value is masked (::add-mask::) before
# anything else is said. The reason for a suspension is the owner's words
# about a client's business, and the logs of this repository are public: it
# is given to the client's database and printed nowhere.
#
# Exit: 0 when every client's organisation follows the register (a client
# not yet released the routine is noted and left for the next train, and one
# with no organisation yet has none to follow); 1 when
# any could not be made to, each said in an ::error:: line, and every other
# client followed all the same; 2 when nothing was tried.
#
# bash 3.2 and 5. Rehearsed on every build with a psql that answers from
# files: supabase/ci/fleet_status_sync_rehearsal.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
SLEEP_CMD="${FLEET_SLEEP:-sleep}"
PAUSE="${PAUSE_SECONDS:-2}"
TIMEOUT="${CLIENT_STATEMENT_TIMEOUT:-30s}"
ONLY="${1:-}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"
export PGAPPNAME="${PGAPPNAME:-fleet_status_sync}"

is_code() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]]; }
is_ref() { [[ "$1" =~ ^[a-z0-9]{20}$ ]]; }

if [[ -z "$CP_URL" ]]; then
  echo "::error::CLOVEERP_LIVE_DATABASE_URL is not set, so the control plane's register cannot be read. No client's organisation was changed."
  exit 2
fi
if [[ -n "$ONLY" ]] && ! is_code "$ONLY"; then
  echo "::error::'${ONLY}' is not a client's code. No client's organisation was changed."
  exit 2
fi
if ! [[ "$PAUSE" =~ ^[0-9]+$ ]]; then
  echo "::error::PAUSE_SECONDS must be a whole number. No client's organisation was changed."
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_status_sync.XXXXXX")
trap 'rm -rf "$work"' EXIT

# On a runner GitHub hides a value printed after this; a terminal would show
# it, so nowhere else.
mask() {
  if [[ "${GITHUB_ACTIONS:-}" == true && -n "${1:-}" ]]; then
    echo "::add-mask::$1"
  fi
}

# What psql said was wrong, on one line. Cut by character, not by byte (jq),
# so what is written in the register is never half a character.
said() {
  local first
  first=$(grep -E 'ERROR|FATAL|error|refus|could not|^x ' "$work/err" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$work/err" 2> /dev/null || true)
  first="${first#psql:<stdin>:*: }"
  printf '%s' "${first:-no reason given}" | tr -s ' \t' '  ' | jq -Rr '.[0:300]'
}

cp_q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }
client_q() {
  local url="$1"
  shift
  $PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$TIMEOUT" "$@"
}
reg() { CLOVEERP_LIVE_DATABASE_URL="$CP_URL" PSQL="$PSQL_CMD" "$HERE/fleet_register.sh" "$@"; }

# ── The register: which clients, and which are suspended ─────────────────────
ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regclass('erp_meta.deployment') is not null)::text || '|'
       || (exists (select 1 from pg_catalog.pg_attribute a
                    where a.attrelid = to_regclass('erp_meta.deployment')
                      and a.attname = 'suspended_reason' and not a.attisdropped))::text;
SQL
) || { echo "::error::the control plane could not be read ($(said)). No client's organisation was changed."; exit 1; }
IFS='|' read -r has_register has_reason <<< "$ready"
if [[ "$has_register" != true ]]; then
  echo "the control plane has no register of deployments yet, so there is no client to follow it"
  exit 0
fi
if [[ "$has_reason" != true ]]; then
  echo "the control plane cannot say which clients are suspended yet (20261012030000 is not released there); nothing to follow"
  exit 0
fi

clients=$(cp_q -v only="$ONLY" 2> "$work/err" <<'SQL'
-- fleet: cp-clients
select coalesce(jsonb_agg(jsonb_build_object('code', d.code, 'ref', d.project_ref, 'status', d.status,
                                             'suspended', d.suspended_reason is not null,
                                             'reason', coalesce(d.suspended_reason, ''))
                          order by d.code), '[]'::jsonb)
  from erp_meta.deployment d
 where d.status in ('built', 'live', 'suspended', 'retiring')
   and (d.status <> 'retiring' or d.built_at is not null)
   and d.project_ref is not null
   and (:'only' = '' or d.code = :'only');
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). No client's organisation was changed."; exit 1; }
# Every ref the register knows, whatever its state, and production's and
# the demonstration's: a client's connection may name its own and no other.
all_refs=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '') from erp_meta.deployment d where d.project_ref is not null;
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). No client's organisation was changed."; exit 1; }
all_refs="${all_refs},${PRODUCTION_REF:-xpzffnnhnhcqyjqcueja},${DEMO_REF:-}"

count=$(jq 'length' <<< "$clients")
if [[ "$count" -eq 0 ]]; then
  if [[ -n "$ONLY" ]]; then
    status=$(cp_q -v only="$ONLY" 2> "$work/err" <<'SQL'
-- fleet: cp-status
select coalesce((select d.status from erp_meta.deployment d where d.code = :'only'), '');
SQL
    ) || status=""
    if [[ -z "$status" ]]; then
      echo "::error::'${ONLY}' is not in the control plane's register. No client's organisation was changed."
      exit 1
    fi
    echo "::notice::${ONLY} is ${status}: only a client whose database is up (built, live, suspended or retiring) follows the register. Nothing was changed."
    exit 0
  fi
  echo "no client in the register has a database that is up (built, live, suspended or retiring); nobody to follow it"
  exit 0
fi

suspended_count=$(jq '[.[] | select(.suspended)] | length' <<< "$clients")
echo "the register: ${count} client(s) whose database is up, ${suspended_count} of them suspended"
{
  echo "## Each client's organisation, suspended as the register says"
  echo
  echo "| client | register | its organisation | changed | not done |"
  echo "|---|---|---|---|---|"
} >> "$SUMMARY"

troubled=0
skipped=0
unorganised=0

# ── One client ───────────────────────────────────────────────────────────────
# trouble <words>: said at once, gathered in TROUBLE, and written on its row.
trouble() {
  # Shortened wherever an address appears, a database's own words included:
  # this goes to the public log, the summary and the register's note.
  local said_here
  said_here=$(printf '%s' "$*" | sed -E 's/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+)/\1…@\2/g')
  echo "::error::${CODE}: ${said_here}"
  TROUBLE="${TROUBLE:+${TROUBLE}; }${said_here}"
}

follow_client() {
  CODE="$1"
  TROUBLE=""
  local ref="$2" want="$3" reason="$4"
  local url="" vault state kind can result changed org by_fleet words last other register_words org_words="" did=""
  local -a others

  if [[ "$want" == true ]]; then register_words=suspended; else register_words="not suspended"; fi

  if ! is_ref "$ref"; then
    trouble "the register gives it no project ref ('${ref}'), so nothing was changed there"
  else
    vault="cloveerp:deployment:${ref}:db_url"
    if ! url=$(reg vault-get "$vault" 2> "$work/err"); then
      url=""
      trouble "the control plane's vault could not be read for ${vault} ($(said)); nothing was changed there"
    else
      mask "$url"
      if [[ -z "$url" ]]; then
        trouble "the control plane's vault has no ${vault}, so it cannot be reached (its build from empty writes that entry); nothing was changed there"
      elif [[ "$url" != *"$ref"* ]]; then
        trouble "${vault} does not name its project (${ref}); nothing was changed there"
        url=""
      else
        IFS=',' read -r -a others <<< "$all_refs"
        for other in ${others[@]+"${others[@]}"}; do
          other="${other// /}"
          if [[ -n "$other" && "$other" != "$ref" && "$url" == *"$other"* ]]; then
            trouble "${vault} names another deployment's project (${other}); nothing was changed there"
            url=""
            break
          fi
        done
      fi
    fi
  fi

  if [[ -n "$url" ]]; then
    if ! state=$(client_q "$url" 2> "$work/err" <<'SQL'
-- fleet: client-state
set statement_timeout = :'timeout';
select coalesce(erp.deployment_kind(), '') || '|'
       || (to_regprocedure('erp_meta.follow_deployment_status(boolean,text)') is not null)::text;
SQL
    ); then
      trouble "its database could not be reached or read ($(said)); nothing was changed there"
      url=""
    else
      IFS='|' read -r kind can <<< "$state"
      if [[ "$kind" != client ]]; then
        trouble "its database says it is the ${kind:-unknown} deployment, not a client's; nothing was changed there"
        url=""
      elif [[ "$can" != true ]]; then
        echo "::notice::${CODE} has not yet been released the routine that makes its organisation follow the register (20261012030000). The next train brings it, and the sync after it follows the register. Nothing was changed there."
        echo "| ${CODE} | ${register_words} | | | not released the routine yet |" >> "$SUMMARY"
        skipped=$((skipped + 1))
        return 0
      fi
    fi
  fi

  if [[ -n "$url" ]]; then
    if ! result=$(client_q "$url" -v suspended="$want" -v reason="$reason" 2> "$work/err" <<'SQL'
-- fleet: client-follow
set statement_timeout = :'timeout';
select erp_meta.follow_deployment_status(:'suspended'::boolean, nullif(:'reason', ''));
SQL
    ); then
      trouble "its organisation could not be made to follow the register ($(said))"
    else
      changed=$(jq -r 'if .changed == true then "yes" else "no" end' <<< "$result" 2> /dev/null || echo "?")
      org=$(jq -r '.status // ""' <<< "$result" 2> /dev/null || echo "")
      by_fleet=$(jq -r 'if .by_fleet == true then "yes" else "no" end' <<< "$result" 2> /dev/null || echo "?")
      # A client is built with no organisation in it, and has one only once
      # it is onboarded: the routine then answers that it changed nothing
      # and that there is no status to follow ({"changed": false, "status":
      # null}). That is a client in step, not trouble.
      empty=$(jq -r 'if type == "object" and has("status") and .status == null and .changed == false
                     then "yes" else "no" end' <<< "$result" 2> /dev/null || echo "no")
      if [[ "$empty" == yes ]]; then
        org_words="no organisation yet"
        unorganised=$((unorganised + 1))
        echo "${CODE}: no organisation yet, so nothing to follow (the register has it ${register_words}); it follows once it is onboarded"
      elif [[ "$changed" == "?" || -z "$org" ]]; then
        trouble "its database answered something that is not what the routine answers ('$(printf '%s' "$result" | head -c 120)')"
      else
        org_words="$org"
        if [[ "$changed" == yes ]]; then
          if [[ "$want" == true ]]; then
            did="its organisation suspended on its own database, as the register says"
          else
            did="its organisation active again on its own database, as the register says"
          fi
          echo "${CODE}: ${did}"
        elif [[ "$org" == suspended && "$by_fleet" != yes ]]; then
          # Suspended on its own console, not by the fleet: left as it is,
          # whatever the register says.
          echo "::notice::${CODE}'s organisation is suspended on its own console, not by the fleet, so it is left as it is (the register has it ${register_words})."
          org_words="suspended on its own console"
        elif [[ "$want" == true && "$org" != suspended ]]; then
          trouble "the register has it suspended, and its organisation is ${org} after the routine ran"
        elif [[ "$want" != true && "$org" == suspended ]]; then
          trouble "the register has it not suspended, and its organisation is still suspended after the routine ran"
        else
          echo "${CODE}: in step (${org})"
        fi
      fi
    fi
  fi

  echo "| ${CODE} | ${register_words} | ${org_words} | ${did:+yes} | ${TROUBLE} |" >> "$SUMMARY"

  # The register: what changed, or what could not be done (not the same
  # trouble twice in a row). Nothing when the client was already in step.
  if [[ -n "$did" ]]; then
    if ! reg event "$CODE" note note "status: ${did} (fleet_sync.yml)" > /dev/null 2> "$work/err"; then
      echo "::warning::${CODE}: what was done could not be written in the control plane's register ($(said))."
    fi
  fi
  if [[ -n "$TROUBLE" ]]; then
    words=$(jq -rn --arg w "status: not followed on its own database: ${TROUBLE} (fleet_sync.yml)" '$w[0:1500]')
    last=$(cp_q -v code="$CODE" 2> /dev/null <<'SQL' || true
-- fleet: cp-last-note
select coalesce((select e.status || ' ' || coalesce(e.detail, '')
                   from erp_meta.deployment_event e
                  where e.code = :'code' and e.phase = 'note' and e.detail like 'status: %'
                  order by e.at desc, e.id desc limit 1), '');
SQL
    )
    if [[ "$last" == "failed ${words}" ]]; then
      echo "${CODE}: the register already says so"
    elif ! reg event "$CODE" note failed "$words" > /dev/null 2> "$work/err"; then
      echo "::warning::${CODE}: what could not be done could not be written in the control plane's register ($(said))."
    fi
    troubled=$((troubled + 1))
  fi
  return 0
}

for ((c = 0; c < count; c++)); do
  if [[ "$c" -gt 0 && "$PAUSE" -gt 0 ]]; then
    $SLEEP_CMD "$PAUSE"
  fi
  follow_client "$(jq -r ".[$c].code" <<< "$clients")" \
                "$(jq -r ".[$c].ref" <<< "$clients")" \
                "$(jq -r "if .[$c].suspended then \"true\" else \"false\" end" <<< "$clients")" \
                "$(jq -r ".[$c].reason" <<< "$clients")"
done

if [[ "$troubled" -gt 0 ]]; then
  echo "::error::${troubled} of ${count} client(s) could not be made to follow the register; each is said above, and written on its row in the register. Every other client followed it."
  exit 1
fi
if [[ "$unorganised" -gt 0 ]]; then
  echo "${unorganised} of ${count} client(s) with no organisation yet, so nothing to follow until it is onboarded"
fi
if [[ "$skipped" -gt 0 ]]; then
  echo "every client's organisation follows the register, but ${skipped} of ${count} not yet released the routine"
else
  echo "every client's organisation follows the register (${count})"
fi
