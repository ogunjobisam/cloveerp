#!/usr/bin/env bash
#
# Every database the platform runs, copied off the platform once a week
# (.github/workflows/fleet_backup.yml).
#
# Supabase backs each project up every day and keeps seven days of them,
# inside Supabase, beside the project: enough to undo a bad day, not enough
# for a project deleted by mistake, an account that cannot be reached, or a
# question asked about last month. So once a week each database is dumped as
# the restore drill dumps it, with its sign-ins, sealed to the owner's age
# key and put in the owner's bucket (supabase/ci/fleet_offsite.sh says what
# is inside and how to read it):
#
#   backups/control-plane/<YYYY-MM-DD>.dump.age   CLOVEERP_LIVE_DATABASE_URL
#   backups/demonstration/<YYYY-MM-DD>.dump.age   CLOVEERP_DEMO_DATABASE_URL
#   backups/<code>/<YYYY-MM-DD>.dump.age          each client that is built,
#                                                 live, suspended or retiring,
#                                                 from the control plane's vault,
#                                                 with its stored documents
#
# one at a time, with a pause between, because each is a dump of a small
# instance at work. The store is asked for each copy again, and only then are
# the copies of that database beyond the newest eight deleted: two months of
# Sundays. Nothing else in the bucket is ever deleted. A client's row in the
# control plane's register says that it was copied, or why not.
#
# Before each database, not once at the start: is a release replaying into
# it (supabase/ci/fleet_busy.sh release)? A dump holds a share lock on every
# table it copies, and a release that meets one fails on its own
# thirty-second lock limit; so a release past its own wait for copies is
# waited out, up to RELEASE_WAIT_MINUTES, and that database is not copied
# this time if it is still going. A release not yet at that wait is not
# waited for: it waits for this copy (release.yml, "No copy of this database
# is being made").
#
# And before each client's database, first: are its database passwords
# being changed (fleet_secrets.yml, rotate_db_password, in its step "Change
# the database passwords, one client at a time")? A new password breaks the
# connection read from the vault for the dumps. A rotation in that step (or
# through its own wait and about to begin it) is waited out, up to
# ROTATION_WAIT_MINUTES. One that has not reached it is not, whenever it
# began: this is asked from inside "Copy every database", the very step that
# rotation's own wait asks about, so it waits for this run instead
# (fleet_busy.sh runs-in, so the two never both wait). A run of
# fleet_secrets.yml that changes something else is never waited for. A
# rotation changes no password but clients', so the control plane and the
# demonstration do not ask.
#
# Then the register is read again for that client, just before it is copied:
# its status, project and API address now, not as they were when the run
# began, hours before it perhaps. One no longer up (retired meanwhile, its
# vault entries gone with it) is left alone: not copied, not counted as
# missed, and nothing written on its row.
#
# One database never stops the others: each that could not be copied is an
# ::error:: line, and the rest are copied all the same.
#
# Until the owner has made the bucket and the key, nothing is dumped: a
# notice names what is missing, and the run stays green.
#
# Usage: fleet_backup.sh [target]   control-plane, demonstration or a client's
#                                   code; every database when empty
#        CHECK_ONLY=yes fleet_backup.sh
#                                   only whether the bucket and key are set:
#                                   0 if they are, 3 (with the notice) if not
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane: copied, and its register
#                               and vault say where every client is
#   CLOVEERP_DEMO_DATABASE_URL  the demonstration
#   PRODUCTION_REF, DEMO_REF    the control plane's and the demonstration's
#                               refs: each connection must name its own and
#                               no other deployment's
#   KEEP                        copies kept per database (default 8)
#   PAUSE_SECONDS               between databases (default 10)
#   RELEASE_WAIT_MINUTES        how long a release replaying into a database
#                               is waited out before it (default 90: a
#                               release job's own limit is ninety-five
#                               minutes, of which up to thirty-five go on its
#                               own wait for copies, before its replay)
#   ROTATION_WAIT_MINUTES       how long a change of database passwords is
#                               waited out before each client (default 60)
#   GH, GH_REPO, GH_TOKEN       how GitHub is asked (fleet_busy.sh)
#   FLEET_SLEEP                 the sleep command (default sleep)
#   the settings of supabase/ci/fleet_offsite.sh
#   PSQL                        the command (the rehearsal's stand-in)
#   OFFSITE_NOW                 the time the copies are named for (default
#                               now; the rehearsal's clock)
#
# Exit: 0 when every database was copied (a client retired since the run
# began left alone), or when the bucket and key are not set yet; 1 when any
# was not (each said); 2 when nothing was tried.
#
# bash 3.2 and 5. Rehearsed on every build: supabase/ci/fleet_backup_rehearsal.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supabase/ci/fleet_offsite.sh
. "$HERE/fleet_offsite.sh"

ONLY="${1:-}"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
DEMO_URL="${CLOVEERP_DEMO_DATABASE_URL:-}"
PRODUCTION_REF="${PRODUCTION_REF:-xpzffnnhnhcqyjqcueja}"
DEMO_REF="${DEMO_REF:-}"
PSQL_CMD="${PSQL:-psql}"
SLEEP_CMD="${FLEET_SLEEP:-sleep}"
KEEP="${KEEP:-8}"
PAUSE="${PAUSE_SECONDS:-10}"
RELEASE_WAIT="${RELEASE_WAIT_MINUTES:-90}"
ROTATION_WAIT="${ROTATION_WAIT_MINUTES:-60}"
# The step of fleet_secrets.yml that changes database passwords, and nothing
# else; renamed there, renamed here (fleet_busy_rehearsal.sh checks it).
ROTATION_SPEC="fleet_secrets.yml=Change the database passwords, one client at a time"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

say() { if offsite_in_actions; then echo "::$1::$2"; else echo "${1}: $2" >&2; fi; }
mask() { if offsite_in_actions && [[ -n "${1:-}" ]]; then echo "::add-mask::$1"; fi; }

if [[ -n "$ONLY" ]] && ! [[ "$ONLY" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  say error "'${ONLY}' is neither control-plane, demonstration nor a client's code. Nothing was copied."
  exit 2
fi
if ! [[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 && "$PAUSE" =~ ^[0-9]+$ && "$RELEASE_WAIT" =~ ^[0-9]+$ && "$ROTATION_WAIT" =~ ^[0-9]+$ ]]; then
  say error "KEEP must be a whole number of 1 or more, and PAUSE_SECONDS, RELEASE_WAIT_MINUTES and ROTATION_WAIT_MINUTES whole numbers. Nothing was copied."
  exit 2
fi

offsite_mask
missing=$(offsite_missing)
if [[ -n "$missing" ]]; then
  say notice "no database is copied off the platform until the owner has made somewhere to put the copies: $(printf '%s' "$missing" | paste -sd ';' - | sed 's/;/; and /g'). Nothing was dumped, uploaded or recorded."
  echo "- not configured: nothing copied" >> "$SUMMARY"
  if [[ "${CHECK_ONLY:-}" == yes ]]; then exit 3; fi
  exit 0
fi
if [[ "${CHECK_ONLY:-}" == yes ]]; then
  echo "the bucket and the key are set"
  exit 0
fi
if [[ -z "$CP_URL" ]]; then
  say error "CLOVEERP_LIVE_DATABASE_URL is not set, so neither the control plane nor any client can be reached. Nothing was copied."
  exit 2
fi
mask "$CP_URL"
mask "$DEMO_URL"

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_backup.XXXXXX")
trap 'rm -rf "$work"' EXIT

said() {
  local first
  first=$(grep -E 'ERROR|FATAL|error|refus|could not|^x ' "$work/err" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$work/err" 2> /dev/null || true)
  first="${first#psql:<stdin>:*: }"
  first=$(printf '%s' "$first" | sed -E 's/^(ERROR|FATAL): +//')
  offsite_redact "${first:-no reason given}" "${SERVICE_KEY_NOW:-}"
}
cp_q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }
reg() { CLOVEERP_LIVE_DATABASE_URL="$CP_URL" PSQL="$PSQL_CMD" "$HERE/fleet_register.sh" "$@"; }

now="${OFFSITE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
if ! [[ "$now" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  say error "the time '${now}' is not a UTC time. Nothing was copied."
  exit 2
fi
day="${BASH_REMATCH[1]}"

# ── Which databases ──────────────────────────────────────────────────────────
# The control plane and the demonstration first, then the clients by code;
# kinds, names, refs and statuses side by side.
kinds=(control demonstration); names=(control-plane demonstration)
prefs=("$PRODUCTION_REF" "$DEMO_REF"); states=("control plane" demonstration); apis=("" "")
has=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regclass('erp_meta.deployment') is not null)::text;
SQL
) || { say error "the control plane could not be read ($(said)). Nothing was copied."; exit 1; }
all_refs="${PRODUCTION_REF},${DEMO_REF}"
if [[ "$has" == true ]]; then
  clients=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-clients
select d.code || '|' || coalesce(d.project_ref, '') || '|' || d.status || '|' || coalesce(d.api_url, '')
  from erp_meta.deployment d
 where d.status in ('built', 'live', 'suspended', 'retiring')
   and (d.status <> 'retiring' or d.built_at is not null)
 order by d.code;
SQL
  ) || { say error "the control plane's register could not be read ($(said)). Nothing was copied."; exit 1; }
  refs=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '') from erp_meta.deployment d where d.project_ref is not null;
SQL
  ) || { say error "the control plane's register could not be read ($(said)). Nothing was copied."; exit 1; }
  all_refs="${all_refs},${refs}"
  while IFS='|' read -r c r s a; do
    [[ -n "$c" ]] || continue
    kinds+=(client); names+=("$c"); prefs+=("$r"); states+=("$s"); apis+=("$a")
  done <<< "$clients"
fi
count=${#names[@]}
if [[ -n "$ONLY" ]]; then
  found=""
  i=0
  while [[ "$i" -lt "$count" ]]; do
    if [[ "${names[$i]}" == "$ONLY" && -z "$found" ]]; then found="$i"; fi
    i=$((i + 1))
  done
  if [[ -z "$found" ]]; then
    say error "'${ONLY}' is neither control-plane, demonstration nor a client the register holds as built, live, suspended or retiring. Nothing was copied."
    exit 1
  fi
  kinds=("${kinds[$found]}"); names=("${names[$found]}"); prefs=("${prefs[$found]}"); states=("${states[$found]}")
  apis=("${apis[$found]}")
  count=1
fi

{
  echo "## Off-platform copies, ${day}"
  echo
  echo "| database | copy | bytes | kept | sha256 |"
  echo "|---|---|---|---|---|"
} >> "$SUMMARY"

# ── One database ─────────────────────────────────────────────────────────────
WHY=""
DONE=""
STORED=""
SERVICE_KEY_NOW=""
GONE=""
# backup_one <kind> <target> <ref> [api]: 0 copied (DONE says what), 1 not
# (WHY says why), 3 a client no longer up, left alone (GONE says what it is).
backup_one() {
  local kind="$1" target="$2" ref="$3" api="${4:-}" url="" vault other dir key bytes sha keys old n drop
  local service_key="" key_name now_row now_status now_built
  local -a others
  WHY=""; DONE=""; STORED=""; SERVICE_KEY_NOW=""; GONE=""

  if [[ "$kind" == client ]]; then
    # Its copies are kept under its code, so a code that is one of the
    # two names the others' copies are kept under would mix them.
    case "$target" in
      control-plane|demonstration)
        WHY="its code is the name the ${target}'s copies are kept under, so it is not copied beside them"; return 1 ;;
    esac
    # A change of its database password under way is waited out first;
    # only one in its step, never one still to reach it, which waits for
    # this run (see the header).
    if ! "$HERE/fleet_busy.sh" wait "$ROTATION_WAIT" runs-in "$ROTATION_SPEC" > "$work/busy" 2>&1; then
      sed 's/^/  /' "$work/busy"
      WHY="a change of database passwords (fleet_secrets.yml) was still under way after ${ROTATION_WAIT} minute(s) ($(tail -n 1 "$work/busy" | cut -c 1-200)), so it was not copied this time"
      return 1
    fi
    if [[ -s "$work/busy" ]]; then sed 's/^/  /' "$work/busy"; fi
  fi

  # A release replaying into it now is waited out, before anything of it is
  # read (fleet_busy.sh; see the header).
  if ! "$HERE/fleet_busy.sh" wait "$RELEASE_WAIT" release "$target" > "$work/busy" 2>&1; then
    sed 's/^/  /' "$work/busy"
    WHY="a release to it was still replaying after ${RELEASE_WAIT} minute(s) ($(tail -n 1 "$work/busy" | cut -c 1-200)), so it was not copied this time"
    return 1
  fi
  if [[ -s "$work/busy" ]]; then sed 's/^/  /' "$work/busy"; fi

  case "$kind" in
    control)
      url="$CP_URL"
      [[ "$url" == *"$ref"* ]] || { WHY="CLOVEERP_LIVE_DATABASE_URL does not name the control plane's project (${ref})"; return 1; } ;;
    demonstration)
      url="$DEMO_URL"
      [[ -n "$url" ]] || { WHY="CLOVEERP_DEMO_DATABASE_URL is not set"; return 1; }
      [[ -n "$ref" && "$url" == *"$ref"* ]] || { WHY="CLOVEERP_DEMO_DATABASE_URL does not name the demonstration's project (${ref:-CLOVEERP_DEMO_PROJECT_REF is not set})"; return 1; } ;;
    *)
      # The register again, just before it is copied (see the header): its
      # status, project and API address now.
      now_row=$(cp_q -v code="$target" 2> "$work/err" <<'SQL'
-- fleet: cp-client
select d.status || '|' || (d.built_at is not null)::text || '|' || coalesce(d.project_ref, '') || '|'
       || coalesce(d.api_url, '')
  from erp_meta.deployment d where d.code = :'code';
SQL
      ) || { WHY="the register could not be read again just before it ($(said))"; return 1; }
      IFS='|' read -r now_status now_built ref api <<< "$now_row"
      case "$now_status" in
        built|live|suspended) : ;;
        retiring)
          [[ "$now_built" == true ]] || { GONE="retiring, and never built"; return 3; } ;;
        "") GONE="no longer in the register"; return 3 ;;
        *) GONE="$now_status"; return 3 ;;
      esac
      [[ "$ref" =~ ^[a-z0-9]{20}$ ]] || { WHY="the register gives it no project ref ('${ref}')"; return 1; }
      if [[ "$ref" == "$PRODUCTION_REF" || ( -n "$DEMO_REF" && "$ref" == "$DEMO_REF" ) ]]; then
        WHY="the register gives it the control plane's or the demonstration's project (${ref})"; return 1
      fi
      vault="cloveerp:deployment:${ref}:db_url"
      url=$(reg vault-get "$vault" 2> "$work/err") || { WHY="the control plane's vault could not be read for ${vault} ($(said))"; return 1; }
      mask "$url"
      [[ -n "$url" ]] || { WHY="the control plane's vault has no ${vault}"; return 1; }
      [[ "$url" == *"$ref"* ]] || { WHY="${vault} does not name its project (${ref})"; return 1; }
      # Its stored documents, from its own project's Storage API with its
      # service key: the address must be its project's, exactly, or the key
      # would be sent elsewhere.
      api="${api%/}"
      [[ -n "$api" ]] || api="https://${ref}.supabase.co"
      [[ "$api" == "https://${ref}.supabase.co" ]] || {
        WHY="the register's address for its project's API (${api}) is not its project's, so its service key would not be sent there"; return 1; }
      key_name="cloveerp:deployment:${ref}:service_key"
      service_key=$(reg vault-get "$key_name" 2> "$work/err") || { WHY="the control plane's vault could not be read for ${key_name} ($(said))"; return 1; }
      mask "$service_key"
      SERVICE_KEY_NOW="$service_key"
      [[ -n "$service_key" ]] || {
        WHY="the control plane's vault has no ${key_name}, so its stored documents (${OFFSITE_BUCKET}) cannot be fetched, and a copy without them is not the business's copy"; return 1; } ;;
  esac
  IFS=',' read -r -a others <<< "$all_refs"
  for other in ${others[@]+"${others[@]}"}; do
    other="${other// /}"
    if [[ -n "$other" && "$other" != "$ref" && "$url" == *"$other"* ]]; then
      WHY="its connection names another deployment's project (${other}), so it was not read"
      return 1
    fi
  done

  dir="$work/dump"
  rm -rf "$dir"; mkdir -p "$dir"
  key="backups/${target}/${day}.dump.age"
  offsite_dump "$url" "$dir" "$target" "$ref" || { WHY="$OFFSITE_WHY"; rm -rf "$dir"; return 1; }
  if [[ "$kind" == client ]]; then
    OFFSITE_STORED=""
    offsite_storage "$api" "$service_key" "$dir" || { WHY="$OFFSITE_WHY"; rm -rf "$dir"; return 1; }
    STORED="$OFFSITE_STORED"
  fi
  offsite_seal "$dir" "$work/copy.age" || { WHY="$OFFSITE_WHY"; rm -rf "$dir" "$work/copy.age"; return 1; }
  rm -rf "$dir"
  bytes=$(offsite_bytes "$work/copy.age")
  sha=$(offsite_sha256 "$work/copy.age")
  offsite_put "$work/copy.age" "$key" || { WHY="$OFFSITE_WHY"; rm -f "$work/copy.age"; return 1; }
  rm -f "$work/copy.age"

  # The newest KEEP of this database's copies, by the date in their names;
  # anything else under its prefix is not this script's, and is left.
  # Into a file, not $( ): OFFSITE_WHY must survive the call.
  if ! offsite_keys "backups/${target}/" > "$work/keys"; then
    DONE="${key}|${bytes}|${sha}|none deleted, because ${OFFSITE_WHY}"
    return 0
  fi
  keys=$(grep -E "^backups/${target}/[0-9]{4}-[0-9]{2}-[0-9]{2}\.dump\.age$" "$work/keys" | LC_ALL=C sort || true)
  n=$(printf '%s\n' "$keys" | grep -c . || true)
  drop=$(( n > KEEP ? n - KEEP : 0 ))
  if [[ "$drop" -gt 0 ]]; then
    for old in $(printf '%s\n' "$keys" | head -n "$drop"); do
      if ! offsite_delete "$old"; then
        DONE="${key}|${bytes}|${sha}|${n}, because ${OFFSITE_WHY}"
        return 0
      fi
      echo "  ${old} deleted: older than the newest ${KEEP}"
      n=$((n - 1))
    done
  fi
  DONE="${key}|${bytes}|${sha}|${n}"
}

copied=0
missed=0
left=0
i=0
while [[ "$i" -lt "$count" ]]; do
  kind="${kinds[$i]}"; target="${names[$i]}"; ref="${prefs[$i]}"; status="${states[$i]}"; api="${apis[$i]}"
  if [[ "$i" -gt 0 && "$PAUSE" -gt 0 ]]; then
    $SLEEP_CMD "$PAUSE"
  fi
  i=$((i + 1))
  echo "copying ${target} (${status}${ref:+, project ${ref}})"
  rc=0
  backup_one "$kind" "$target" "$ref" "$api" < /dev/null || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    # Retired since the run read the register: nothing to copy, nothing
    # missed, and nothing written on its row.
    left=$((left + 1))
    echo "${target} is no longer up (${GONE}) since this run began: left alone, and not copied"
    echo "| ${target} | left alone: no longer up (${GONE}) since the run began | | | |" >> "$SUMMARY"
  elif [[ "$rc" -eq 0 ]]; then
    copied=$((copied + 1))
    IFS='|' read -r key bytes sha kept <<< "$DONE"
    echo "${target}: ${key}, ${bytes} bytes, sha256 ${sha}${STORED:+, with ${STORED}}; copies kept: ${kept}"
    echo "| ${target} | ${key} | ${bytes} | ${kept} | ${sha} |" >> "$SUMMARY"
    if [[ "$kind" == client ]]; then
      reg event "$target" note done "copied off the platform as ${key} (${bytes} bytes, sha256 ${sha}${STORED:+, with ${STORED}}); copies kept: ${kept} (fleet_backup.yml)" > /dev/null 2> "$work/err" ||
        say warning "${target}'s row could not be told that it was copied ($(said))"
    fi
  else
    missed=$((missed + 1))
    say error "${target} was not copied: ${WHY}. The others are copied all the same."
    echo "| ${target} | NOT COPIED: ${WHY} | | | |" >> "$SUMMARY"
    if [[ "$kind" == client ]]; then
      reg event "$target" note failed "not copied off the platform this week: ${WHY} (fleet_backup.yml)" > /dev/null 2> "$work/err" ||
        say warning "${target}'s row could not be told that it was not copied ($(said))"
    fi
  fi
done

said_all="${copied} database(s) copied off the platform, ${missed} not"
if [[ "$left" -gt 0 ]]; then said_all="${said_all}; ${left} left alone, no longer up"; fi
echo "$said_all"
[[ "$missed" -eq 0 ]]
