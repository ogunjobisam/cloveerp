#!/usr/bin/env bash
#
# A client deployment moved to a new address
# (.github/workflows/fleet_rename.yml).
#
# A client is served at <address>.<APEX>. Its code never changes (every event
# on its row names it, and the history is append-only), but its address may:
# the owner asks from the Fleet view (erp_platform_rename_deployment,
# 20261012020000), which checks the new address is free across the fleet and
# queues a request; the sweep (fleet_sweep.yml) starts this with the request's
# id; and this carries it out, in an order in which every step can be undone,
# and undoes the ones done when a later one fails:
#
#   1. the project's auth settings (provision_project.sh configure with the
#      new address): the site URL and the one redirect allowed, so a sign-in
#      link comes back to the new address and nowhere else;
#   2. its functions' CLOVEERP_APP_URL (provision_project.sh secrets): the
#      links its emails carry;
#   3. in its own database, in one transaction: where it is served
#      (erp_meta.set_deployment_identity, which is also erp.deployment_code())
#      and its one organisation's code, which is that address
#      (erp_meta.rename_client_organisation);
#   4. on the control plane, the register: the new address, the old one kept
#      for ninety days, in which the directory sends anyone who uses it to the
#      new one (erp_meta.finish_deployment_rename);
#   5. the request settled, with what happened.
#
# Each step is an event on the client's row. Nothing is touched until
# everything it needs has been read and checked: the request is the one asked
# for and still claimed, the register still has the client at the old
# address, and the client's database is reachable, says it is a client, has
# the routine step 3 needs and is at the old address (or, when a rename that
# stopped is asked for again, already at the new one: every step can be
# repeated).
#
# Usage: fleet_rename.sh <code> <from> <to> <request id>
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane: the register and its vault
#   SUPABASE_ACCESS_TOKEN       the Management API (provision_project.sh)
#   RESEND_API_KEY, MAIL_FROM   step 1 applies the auth settings a build
#                               applies, SMTP included
#   APEX                        default cloveerp.com
#   PRODUCTION_REF, DEMO_REF    refs the client's connection must not name, as
#                               well as every other ref in the register
#   CLIENT_STATEMENT_TIMEOUT    step 3's limit (default 60s): the pooler drops
#                               PGOPTIONS, so it is set in SQL
#   PSQL, CURL, API, MAPI_*     the commands and settings the rehearsal
#                               (fleet_rename_rehearsal.sh) stands in for
#
# Every value reaches SQL as a psql variable on standard input. The client's
# connection string is masked before anything else is printed, and must name
# its project and no other deployment's.
#
# Exit: 0 renamed and settled; 1 not renamed (what was done was undone, or
# says what could not be, and the request is settled as failed), or renamed
# and the request could not be settled; 2 nothing was touched, and the
# request is settled as failed when it can be.
#
# bash 3.2 and 5.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$HERE/provision_project.sh"
CODE="${1:-}"; FROM="${2:-}"; TO="${3:-}"; REQUEST="${4:-}"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
APEX="${APEX:-cloveerp.com}"
TIMEOUT="${CLIENT_STATEMENT_TIMEOUT:-60s}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

in_actions() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }
mask() { if in_actions && [[ -n "${1:-}" ]]; then echo "::add-mask::$1"; fi; }
say_error() { if in_actions; then echo "::error::$*"; else echo "x $*" >&2; fi; }
is_address() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; }

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_rename.XXXXXX")
trap 'rm -rf "$work"' EXIT

one_line() { printf '%s' "${1:-no reason given}" | tr -s ' \t\r\n' '    ' | cut -c 1-300; }
said() {
  local first
  first=$(grep -E 'ERROR|FATAL|error|refus|answered|could not|^x ' "$work/err" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$work/err" 2> /dev/null || true)
  first="${first#psql:<stdin>:*: }"
  first=$(printf '%s' "$first" | sed -E 's/^(ERROR|FATAL): +//')
  first="${first#x }"
  if [[ -n "${RESEND_API_KEY:-}" ]]; then first="${first//"${RESEND_API_KEY}"/[hidden]}"; fi
  one_line "$first"
}
cp_q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }
reg() { CLOVEERP_LIVE_DATABASE_URL="$CP_URL" PSQL="$PSQL_CMD" "$HERE/fleet_register.sh" "$@"; }

# event <phase> <status> <detail>: one step on the client's row. Never fails
# the run: the step itself is what matters, and is said here either way.
event() {
  reg event "$CODE" "$1" "$2" "$3 (fleet_rename.yml)" > /dev/null 2> "$work/err.event" ||
    echo "! ${CODE}'s row could not be told: ${3}" >&2
}

# settle <success|failure> <words>: the request, settled. Says, and returns
# 1, when it cannot be: the request then stays claimed.
SETTLED=no
settle() {
  local outcome="${1}: ${2}"
  if [[ -z "$REQUEST" || -z "$CP_URL" ]]; then return 1; fi
  if cp_q -v id="$REQUEST" -v outcome="$(one_line "$outcome")" > /dev/null 2> "$work/err" <<'SQL'
-- fleet: cp-settle
select erp_meta.settle_fleet_request(:'id'::uuid, :'outcome');
SQL
  then
    SETTLED=yes
    return 0
  fi
  say_error "the request ${REQUEST} could not be settled ($(said)); it stays claimed, and the Fleet view shows it open until the register lets it go."
  return 1
}

# refuse <words>: nothing was touched; said, and the request settled as
# failed when it is this run's to settle.
SETTLE_ON_REFUSAL=no
refuse() {
  say_error "${CODE:-the client} was not renamed, and nothing was changed: $*"
  echo "- ${CODE:-?}: NOT renamed, nothing changed: $*" >> "$SUMMARY"
  if [[ "$SETTLE_ON_REFUSAL" == yes ]]; then settle failure "nothing changed: $*" || true; fi
  exit 2
}

# ── Before anything is touched ───────────────────────────────────────────────
is_address "$CODE" || refuse "'${CODE}' is not a client's code"
is_address "$FROM" || refuse "'${FROM}' is not an address"
is_address "$TO" || refuse "'${TO}' is not an address"
[[ "$FROM" != "$TO" ]] || refuse "${FROM} is already its address"
[[ "$REQUEST" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  refuse "'${REQUEST}' is not a request's id; a rename is carried out only for the request the Fleet view made, which the console checked"
[[ -n "$CP_URL" ]] || refuse "CLOVEERP_LIVE_DATABASE_URL is not set, so the register cannot be read"
[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] || refuse "SUPABASE_ACCESS_TOKEN is not set, so the project's auth settings cannot be changed"
[[ -n "${RESEND_API_KEY:-}" ]] || refuse "RESEND_API_KEY is not set, so the project's auth settings (SMTP among them) cannot be applied"
[[ "${MAIL_FROM:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || refuse "MAIL_FROM is not an email address, so sign-in links would have no sender"
[[ "$APEX" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || refuse "APEX ('${APEX}') is not a domain"
OLD_ORIGIN="https://${FROM}.${APEX}"
NEW_ORIGIN="https://${TO}.${APEX}"

ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regprocedure('erp_meta.finish_deployment_rename(text,text)') is not null)::text;
SQL
) || refuse "the control plane could not be read ($(said))"
[[ "$ready" == true ]] || refuse "the control plane cannot record a rename yet (20261012020000 is not released there)"

asked=$(cp_q -v id="$REQUEST" 2> "$work/err" <<'SQL'
-- fleet: cp-request
select r.status || '|' || r.kind || '|' || coalesce(r.payload ->> 'code', '') || '|'
       || coalesce(r.payload ->> 'from', '') || '|' || coalesce(r.payload ->> 'to', '')
  from erp_meta.fleet_request r where r.id = :'id'::uuid;
SQL
) || refuse "the request ${REQUEST} could not be read ($(said))"
[[ -n "$asked" ]] || refuse "there is no request ${REQUEST}"
IFS='|' read -r r_status r_kind r_code r_from r_to <<< "$asked"
[[ "$r_kind" == rename ]] || refuse "request ${REQUEST} asks for a ${r_kind}, not a rename"
[[ "$r_status" == claimed ]] || refuse "request ${REQUEST} is ${r_status}, not claimed by the sweep: it is not this run's to carry out"
# From here the request is this run's: whatever happens, it is settled.
SETTLE_ON_REFUSAL=yes
[[ "$r_code" == "$CODE" && "$r_from" == "$FROM" && "$r_to" == "$TO" ]] ||
  refuse "request ${REQUEST} asks to move ${r_code} from ${r_from} to ${r_to}, not ${CODE} from ${FROM} to ${TO}"

row=$(cp_q -v code="$CODE" 2> "$work/err" <<'SQL'
-- fleet: cp-row
select d.status || '|' || coalesce(d.project_ref, '') || '|' || coalesce(to_jsonb(d) ->> 'address', d.code)
  from erp_meta.deployment d where d.code = :'code';
SQL
) || refuse "the register could not be read ($(said))"
[[ -n "$row" ]] || refuse "${CODE} is not in the register"
IFS='|' read -r status REF address <<< "$row"
case "$status" in
  built|live|suspended) : ;;
  *) refuse "${CODE} is ${status}: only a built, live or suspended client is renamed" ;;
esac
[[ "$address" == "$FROM" ]] || refuse "the register has ${CODE} at ${address} now, not ${FROM}"
[[ "$REF" =~ ^[a-z0-9]{20}$ ]] || refuse "the register gives ${CODE} no project ref ('${REF}')"
others=$(cp_q -v code="$CODE" 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '')
  from erp_meta.deployment d where d.code <> :'code' and d.project_ref is not null;
SQL
) || refuse "the register could not say which other projects there are ($(said))"

vault="cloveerp:deployment:${REF}:db_url"
URL=$(reg vault-get "$vault" 2> "$work/err") || refuse "the control plane's vault could not be read for ${vault} ($(said))"
mask "$URL"
[[ -n "$URL" ]] || refuse "the control plane's vault has no ${vault}, so ${CODE}'s database cannot be reached"
[[ "$URL" == *"$REF"* ]] || refuse "${vault} does not name ${CODE}'s project (${REF})"
IFS=',' read -r -a refs <<< "${others},${PRODUCTION_REF:-xpzffnnhnhcqyjqcueja},${DEMO_REF:-}"
for other in ${refs[@]+"${refs[@]}"}; do
  other="${other// /}"
  if [[ -n "$other" && "$other" != "$REF" && "$URL" == *"$other"* ]]; then
    refuse "${vault} names another deployment's project (${other})"
  fi
done

client=$($PSQL_CMD "$URL" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$TIMEOUT" 2> "$work/err" <<'SQL'
-- fleet: client-check
set statement_timeout = :'timeout';
select coalesce(erp.deployment_kind(), '') || '|' || coalesce(erp.deployment_code(), '') || '|'
       || (to_regprocedure('erp_meta.rename_client_organisation(text)') is not null)::text;
SQL
) || refuse "${CODE}'s database could not be reached ($(said))"
IFS='|' read -r c_kind c_code c_can <<< "$client"
[[ "$c_kind" == client ]] || refuse "${CODE}'s database says it is the ${c_kind:-unknown} deployment, not a client's"
[[ "$c_can" == true ]] || refuse "${CODE}'s database cannot rename its organisation yet (20261012020000 has not been released to it): release it, then ask again"
case "$c_code" in
  "$FROM") AGAIN=no ;;
  "$TO") AGAIN=yes ;;
  *) refuse "${CODE}'s database says it is served at ${c_code:-no address}, neither ${FROM} nor ${TO}" ;;
esac

# ── The steps, each undone if a later one fails ──────────────────────────────
DONE_STEPS=""
echo "${CODE} (project ${REF}, ${status}): from ${OLD_ORIGIN} to ${NEW_ORIGIN}"
if [[ "$AGAIN" == yes ]]; then
  echo "${CODE}'s database is already at ${TO}: a rename that stopped is carried on"
fi
event rename started "moving from ${FROM} to ${TO}: auth settings, function secret, database, then the register"

# client_move <origin> <organisation code>: step 3, or its undoing.
client_move() {
  $PSQL_CMD "$URL" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$TIMEOUT" -v ref="$REF" -v origin="$1" -v to="$2" \
      > /dev/null 2> "$work/err" <<'SQL'
-- fleet: client-move
begin;
set local statement_timeout = :'timeout';
select erp_meta.set_deployment_identity(:'ref', :'origin');
select erp_meta.rename_client_organisation(:'to');
commit;
SQL
}

# undo: every step done, in reverse; returns 1 when any could not be.
undo() {
  local bad=""
  case " $DONE_STEPS " in
    *" database "*)
      if client_move "$OLD_ORIGIN" "$FROM"; then
        event identity done "put back: served at ${OLD_ORIGIN}, organisation ${FROM}"
      else
        bad="${bad} the database (still at ${TO}: $(said))"
        event identity failed "could not be put back to ${FROM}: $(said)"
      fi ;;
  esac
  case " $DONE_STEPS " in
    *" functions "*)
      if "$PROV" secrets "$REF" "CLOVEERP_APP_URL=${OLD_ORIGIN}" > /dev/null 2> "$work/err"; then
        event functions done "put back: CLOVEERP_APP_URL ${OLD_ORIGIN}"
      else
        bad="${bad} the function secret (still ${NEW_ORIGIN}: $(said))"
        event functions failed "CLOVEERP_APP_URL could not be put back to ${OLD_ORIGIN}: $(said)"
      fi ;;
  esac
  case " $DONE_STEPS " in
    *" auth "*)
      if "$PROV" configure "$REF" "$FROM" > /dev/null 2> "$work/err"; then
        event configure done "put back: site ${OLD_ORIGIN}"
      else
        bad="${bad} the auth settings (perhaps still ${NEW_ORIGIN}: $(said))"
        event configure failed "the auth settings could not be put back to ${OLD_ORIGIN}: $(said)"
      fi ;;
  esac
  UNDO_LEFT="$bad"
  [[ -z "$bad" ]]
}

# stop <step> <why>: a step failed; what was done is undone, the row and the
# request say so, and the run is red.
stop() {
  local step="$1" why="$2" left
  UNDO_LEFT=""
  if [[ -z "$DONE_STEPS" ]] || undo; then
    left="${DONE_STEPS:+ What had been done was put back, and ${CODE} is at ${FROM} as before.}"
    [[ -n "$left" ]] || left=" Nothing had been changed yet."
  else
    left=" What had been done could not all be put back:${UNDO_LEFT}. Ask for the same rename again, which carries on from where it is, or put these back by hand."
  fi
  event rename failed "not moved to ${TO}: ${step} failed (${why}).${left}"
  say_error "${CODE} was not renamed to ${TO}: ${step} failed (${why}).${left}"
  echo "- ${CODE}: NOT renamed to ${TO}: ${step} failed (${why}).${left}" >> "$SUMMARY"
  settle failure "${step} failed (${why}).${left}" || true
  exit 1
}

# 1. The auth settings.
if ! "$PROV" configure "$REF" "$TO" > /dev/null 2> "$work/err"; then
  # A PATCH that went through and read back wrong may have changed them.
  DONE_STEPS="auth"
  event configure failed "auth settings for ${NEW_ORIGIN} not applied: $(said)"
  stop "the auth settings" "$(said)"
fi
DONE_STEPS="auth"
event configure done "site ${NEW_ORIGIN}, the one redirect ${NEW_ORIGIN}/**"

# 2. The functions' address.
if ! "$PROV" secrets "$REF" "CLOVEERP_APP_URL=${NEW_ORIGIN}" > /dev/null 2> "$work/err"; then
  why=$(said)
  # An answer that never came may follow a secret that was set: put back
  # either way, which is harmless if it was not.
  DONE_STEPS="functions auth"
  event functions failed "CLOVEERP_APP_URL not set to ${NEW_ORIGIN}: ${why}"
  stop "the function secret" "$why"
fi
DONE_STEPS="functions auth"
event functions done "CLOVEERP_APP_URL ${NEW_ORIGIN}"

# 3. The database, in one transaction: served at the new address, and its
# organisation's code the same.
if ! client_move "$NEW_ORIGIN" "$TO"; then
  why=$(said)
  # A commit whose answer was lost is a commit: ask the database.
  now=$($PSQL_CMD "$URL" -v ON_ERROR_STOP=1 -X -q -tA 2> /dev/null <<'SQL' || true
-- fleet: client-code
select coalesce(erp.deployment_code(), '');
SQL
  )
  if [[ "$now" != "$TO" ]]; then
    event identity failed "not moved to ${TO}: ${why}"
    stop "the database" "$why"
  fi
fi
DONE_STEPS="database functions auth"
event identity done "served at ${NEW_ORIGIN}; its organisation's code is ${TO}"

# 4. The register.
if ! cp_q -v code="$CODE" -v to="$TO" > /dev/null 2> "$work/err" <<'SQL'
-- fleet: cp-finish
select erp_meta.finish_deployment_rename(:'code', :'to');
SQL
then
  why=$(said)
  # A commit whose answer was lost is a commit: ask the register.
  now=$(cp_q -v code="$CODE" 2> /dev/null <<'SQL' || true
-- fleet: cp-address
select coalesce(to_jsonb(d) ->> 'address', d.code) from erp_meta.deployment d where d.code = :'code';
SQL
  )
  if [[ "$now" != "$TO" ]]; then
    stop "the register" "$why"
  fi
fi

echo "${CODE}: moved from ${FROM} to ${TO}; ${OLD_ORIGIN} sends people to ${NEW_ORIGIN} for ninety days"
{
  echo "## ${CODE} renamed"
  echo "- from ${OLD_ORIGIN} to ${NEW_ORIGIN}"
  echo "- the old address sends people to the new one for ninety days"
} >> "$SUMMARY"
settle success "${CODE} moved from ${FROM} to ${TO}: auth settings, CLOVEERP_APP_URL, its database and the register" || exit 1
