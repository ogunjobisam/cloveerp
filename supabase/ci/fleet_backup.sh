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
#                                                 from the control plane's vault
#
# one at a time, with a pause between, because each is a dump of a small
# instance at work. The store is asked for each copy again, and only then are
# the copies of that database beyond the newest eight deleted: two months of
# Sundays. Nothing else in the bucket is ever deleted. A client's row in the
# control plane's register says that it was copied, or why not.
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
#   FLEET_SLEEP                 the sleep command (default sleep)
#   the settings of supabase/ci/fleet_offsite.sh
#   PSQL                        the command (the rehearsal's stand-in)
#   OFFSITE_NOW                 the time the copies are named for (default
#                               now; the rehearsal's clock)
#
# Exit: 0 when every database was copied, or when the bucket and key are not
# set yet; 1 when any was not (each said); 2 when nothing was tried.
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
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

say() { if offsite_in_actions; then echo "::$1::$2"; else echo "${1}: $2" >&2; fi; }
mask() { if offsite_in_actions && [[ -n "${1:-}" ]]; then echo "::add-mask::$1"; fi; }

if [[ -n "$ONLY" ]] && ! [[ "$ONLY" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  say error "'${ONLY}' is neither control-plane, demonstration nor a client's code. Nothing was copied."
  exit 2
fi
if ! [[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 && "$PAUSE" =~ ^[0-9]+$ ]]; then
  say error "KEEP must be a whole number of 1 or more, and PAUSE_SECONDS a whole number. Nothing was copied."
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
  offsite_redact "${first:-no reason given}"
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
prefs=("$PRODUCTION_REF" "$DEMO_REF"); states=("control plane" demonstration)
has=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regclass('erp_meta.deployment') is not null)::text;
SQL
) || { say error "the control plane could not be read ($(said)). Nothing was copied."; exit 1; }
all_refs="${PRODUCTION_REF},${DEMO_REF}"
if [[ "$has" == true ]]; then
  clients=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-clients
select d.code || '|' || coalesce(d.project_ref, '') || '|' || d.status
  from erp_meta.deployment d
 where d.status in ('built', 'live', 'suspended', 'retiring')
 order by d.code;
SQL
  ) || { say error "the control plane's register could not be read ($(said)). Nothing was copied."; exit 1; }
  refs=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '') from erp_meta.deployment d where d.project_ref is not null;
SQL
  ) || { say error "the control plane's register could not be read ($(said)). Nothing was copied."; exit 1; }
  all_refs="${all_refs},${refs}"
  while IFS='|' read -r c r s; do
    [[ -n "$c" ]] || continue
    kinds+=(client); names+=("$c"); prefs+=("$r"); states+=("$s")
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
backup_one() {
  local kind="$1" target="$2" ref="$3" url="" vault other dir key bytes sha keys old n drop
  local -a others
  WHY=""; DONE=""
  case "$kind" in
    control)
      url="$CP_URL"
      [[ "$url" == *"$ref"* ]] || { WHY="CLOVEERP_LIVE_DATABASE_URL does not name the control plane's project (${ref})"; return 1; } ;;
    demonstration)
      url="$DEMO_URL"
      [[ -n "$url" ]] || { WHY="CLOVEERP_DEMO_DATABASE_URL is not set"; return 1; }
      [[ -n "$ref" && "$url" == *"$ref"* ]] || { WHY="CLOVEERP_DEMO_DATABASE_URL does not name the demonstration's project (${ref:-CLOVEERP_DEMO_PROJECT_REF is not set})"; return 1; } ;;
    *)
      # Its copies are kept under its code, so a code that is one of the
      # two names above would mix its copies with theirs.
      case "$target" in
        control-plane|demonstration)
          WHY="its code is the name the ${target}'s copies are kept under, so it is not copied beside them"; return 1 ;;
      esac
      [[ "$ref" =~ ^[a-z0-9]{20}$ ]] || { WHY="the register gives it no project ref ('${ref}')"; return 1; }
      if [[ "$ref" == "$PRODUCTION_REF" || ( -n "$DEMO_REF" && "$ref" == "$DEMO_REF" ) ]]; then
        WHY="the register gives it the control plane's or the demonstration's project (${ref})"; return 1
      fi
      vault="cloveerp:deployment:${ref}:db_url"
      url=$(reg vault-get "$vault" 2> "$work/err") || { WHY="the control plane's vault could not be read for ${vault} ($(said))"; return 1; }
      mask "$url"
      [[ -n "$url" ]] || { WHY="the control plane's vault has no ${vault}"; return 1; }
      [[ "$url" == *"$ref"* ]] || { WHY="${vault} does not name its project (${ref})"; return 1; } ;;
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
i=0
while [[ "$i" -lt "$count" ]]; do
  kind="${kinds[$i]}"; target="${names[$i]}"; ref="${prefs[$i]}"; status="${states[$i]}"
  if [[ "$i" -gt 0 && "$PAUSE" -gt 0 ]]; then
    $SLEEP_CMD "$PAUSE"
  fi
  i=$((i + 1))
  echo "copying ${target} (${status}${ref:+, project ${ref}})"
  if backup_one "$kind" "$target" "$ref" < /dev/null; then
    copied=$((copied + 1))
    IFS='|' read -r key bytes sha kept <<< "$DONE"
    echo "${target}: ${key}, ${bytes} bytes, sha256 ${sha}; copies kept: ${kept}"
    echo "| ${target} | ${key} | ${bytes} | ${kept} | ${sha} |" >> "$SUMMARY"
    if [[ "$kind" == client ]]; then
      reg event "$target" note done "copied off the platform as ${key} (${bytes} bytes, sha256 ${sha}); copies kept: ${kept} (fleet_backup.yml)" > /dev/null 2> "$work/err" ||
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

echo "${copied} database(s) copied off the platform, ${missed} not"
[[ "$missed" -eq 0 ]]
