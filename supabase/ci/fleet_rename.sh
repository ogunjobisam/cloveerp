#!/usr/bin/env bash
#
# A client deployment moved to a new address
# (.github/workflows/fleet_rename.yml).
#
# A client is served at <address>.<APEX>. Its code never changes (every event
# on its row names it, and the history is append-only), but its address may:
# the owner asks from the Fleet view (erp_platform_rename_deployment,
# 20261012030000), which checks the new address is free across the fleet and
# queues a request; the sweep (fleet_sweep.yml) starts this with the request's
# id; and this carries it out, in an order in which every step can be undone,
# and undoes the ones done when a later one is known to have failed:
#
#   1. the project's auth settings (provision_project.sh configure with the
#      new address): the site URL, and the redirects allowed, which are the
#      new address and every address the client was moved from (each is held
#      for it for good, erp_meta.deployment_previous_address, and never given
#      to anyone else), so a sign-in link asked for at an old address still
#      comes back, and goes nowhere that is not the client's;
#   2. its functions' CLOVEERP_APP_URL (provision_project.sh secrets): the
#      links its emails carry;
#   3. in its own database, in one transaction: where it is served
#      (erp_meta.set_deployment_identity, which is also erp.deployment_code())
#      and its one organisation's code, which is that address
#      (erp_meta.rename_client_organisation);
#   4. on the control plane, the register: the new address, and the old one
#      held for it, sending anyone who uses it to the new one for ninety days
#      (erp_meta.finish_deployment_rename);
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
# A write whose answer is lost may have committed. Steps 3 and 4 are each read
# back when they fail, with patience (a pause of 15, 30 and then 60 seconds
# before each of three tries, READ_BACK_PAUSES), and an answer while this
# run's own lost statement is still at work there (pg_stat_activity, by this
# run's application name) is no answer yet. Found at the new address, the step
# is taken as done; found at the old one, it did not commit, and what was done
# before it is undone. Not found at all, nothing is undone, because undoing a
# step that may have committed is how a client ends at its old address with
# its register at the new one: this says so and stops (exit 3), and the
# workflow's last step reads the register again and settles the request from
# what it says.
#
# A rename asked for again after one that stopped finds the client's
# database already at the new address: the run before moved it, and this one
# carries on. A step of it that fails puts nothing back toward the old
# address, since this run never moved the database there and the run before
# may have set the rest: it says the client is (partly) at the new address
# and that asking for the same rename again finishes it, and stops (exit 3)
# with the request left for the workflow's last step.
#
# A run that began with the database at the old address, and stops at a step
# known to have failed, puts every piece back there: the database if this
# run moved it, and the auth settings and the functions' address whichever
# run set them (a run before may have set both and stopped before its
# database moved; each is idempotent). Each is then read back, and "at the
# old address as before" is said only when every one reads back there.
# Otherwise this says which piece is where and stops (exit 3), the request
# left for the workflow's last step.
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
#   CLIENT_STATEMENT_TIMEOUT    each statement on the client (default 60s): the
#                               pooler drops PGOPTIONS, so it is set in SQL
#   READ_BACK_PAUSES            the pauses before each read-back (default
#                               "15 30 60")
#   FLEET_SLEEP                 the sleep command (default sleep)
#   PSQL, CURL, API, MAPI_*     the commands and settings the rehearsal
#                               (fleet_rename_rehearsal.sh) stands in for
#
# Every value reaches SQL as a psql variable on standard input. The client's
# connection string is masked before anything else is printed, and must name
# its project and no other deployment's.
#
# Exit: 0 renamed and settled; 1 not renamed (every piece put back and read
# back at the old address, and the request settled as failed), or renamed
# and the request could not be settled; 2 nothing was touched, and the
# request is settled as failed when it can be; 3 the client may be (partly)
# at the new address (whether step 3 or 4 took could not be learned, and
# nothing was undone; a rename carried on stopped at a step, and nothing was
# put back; or a piece could not be put back, or read back, at the old
# address), and the request is left for the workflow's last step to settle.
#
# bash 3.2 and 5.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV="$HERE/provision_project.sh"
CODE="${1:-}"; FROM="${2:-}"; TO="${3:-}"; REQUEST="${4:-}"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
SLEEP_CMD="${FLEET_SLEEP:-sleep}"
APEX="${APEX:-cloveerp.com}"
TIMEOUT="${CLIENT_STATEMENT_TIMEOUT:-60s}"
READ_BACK_PAUSES="${READ_BACK_PAUSES:-15 30 60}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

in_actions() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }
mask() { if in_actions && [[ -n "${1:-}" ]]; then echo "::add-mask::$1"; fi; }
say_error() { if in_actions; then echo "::error::$*"; else echo "x $*" >&2; fi; }
is_address() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; }

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_rename.XXXXXX")
trap 'rm -rf "$work"' EXIT

one_line() { printf '%s' "${1:-no reason given}" | tr -s ' \t\r\n' '    ' | cut -c 1-300; }
# said [file]: what psql or the API said was wrong, on one line.
said() {
  local f="${1:-$work/err}" first
  first=$(grep -E 'ERROR|FATAL|error|refus|answered|could not|^x ' "$f" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$f" 2> /dev/null || true)
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
PAUSE_COUNT=0
PAUSE_TOTAL=0
for pause in $READ_BACK_PAUSES; do
  [[ "$pause" =~ ^[0-9]+$ ]] || refuse "READ_BACK_PAUSES ('${READ_BACK_PAUSES}') is not a list of seconds"
  PAUSE_COUNT=$((PAUSE_COUNT + 1))
  PAUSE_TOTAL=$((PAUSE_TOTAL + pause))
done
[[ "$PAUSE_COUNT" -ge 1 ]] || refuse "READ_BACK_PAUSES is empty, so a lost answer could never be asked about again"
OLD_ORIGIN="https://${FROM}.${APEX}"
NEW_ORIGIN="https://${TO}.${APEX}"
# This run's own sessions, by name: a read-back asks whether one of them is
# still at work where an answer was lost.
APP="fleet_rename ${REQUEST}"
export PGAPPNAME="$APP"

ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regprocedure('erp_meta.finish_deployment_rename(text,text)') is not null
        and to_regclass('erp_meta.deployment_previous_address') is not null)::text;
SQL
) || refuse "the control plane could not be read ($(said))"
[[ "$ready" == true ]] || refuse "the control plane cannot record a rename yet (20261012030000 is not released there)"

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
# Every address it was moved from, which it holds for good.
held=$(cp_q -v code="$CODE" 2> "$work/err" <<'SQL'
-- fleet: cp-held
select coalesce(string_agg(p.address, ' ' order by p.moved_at, p.address), '')
  from erp_meta.deployment_previous_address p where p.code = :'code';
SQL
) || refuse "the register could not say which addresses ${CODE} was moved from ($(said))"
for a in $held; do
  is_address "$a" || refuse "the register holds '${a}' for ${CODE}, which is not an address"
done

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
[[ "$c_can" == true ]] || refuse "${CODE}'s database cannot rename its organisation yet (20261012030000 has not been released to it): release it, then ask again"
case "$c_code" in
  "$FROM") AGAIN=no ;;
  "$TO") AGAIN=yes ;;
  *) refuse "${CODE}'s database says it is served at ${c_code:-no address}, neither ${FROM} nor ${TO}" ;;
esac

# also_allow <site address> <address...>: the addresses given, each once,
# without the site's own: the redirects allowed beside the site's.
also_allow() {
  local site="$1" a list=" "
  shift
  for a in "$@"; do
    [[ -n "$a" && "$a" != "$site" && "$list" != *" $a "* ]] || continue
    list="${list}${a} "
  done
  list="${list# }"
  printf '%s' "${list% }"
}
# Moved: the new address, and the one it leaves and every one it left before,
# all held for it. Put back: the old address, and every one held for it,
# which is the new one too when it was one of them.
ALLOW_TO=$(also_allow "$TO" "$FROM" $held)
ALLOW_FROM=$(also_allow "$FROM" $held)
# redirects <address> <also allowed>: the redirects allowed, in words.
redirects() {
  if [[ -z "$2" ]]; then
    printf 'the one redirect https://%s.%s/**' "$1" "$APEX"
  else
    printf 'redirects to https://%s.%s/** and to the addresses held for it (%s)' "$1" "$APEX" "$(printf '%s' "$2" | sed 's/ /, /g')"
  fi
}

# ── The steps, each undone if a later one is known to have failed ────────────
DONE_STEPS=""
READ_BACK=""
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

# The read-backs: where it is now, and how many of this run's own sessions
# are still at work there (one is a statement whose answer was lost, still
# running).
client_now() {
  $PSQL_CMD "$URL" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$TIMEOUT" -v app="$APP" 2> "$work/err.read" <<'SQL'
-- fleet: client-code
set statement_timeout = :'timeout';
select coalesce(erp.deployment_code(), '') || '|'
       || (select count(*) from pg_catalog.pg_stat_activity a
            where a.application_name = :'app' and a.pid <> pg_catalog.pg_backend_pid()
              and coalesce(a.state, 'idle') <> 'idle')::text;
SQL
}
register_now() {
  cp_q -v code="$CODE" -v app="$APP" 2> "$work/err.read" <<'SQL'
-- fleet: cp-address
set statement_timeout = '30s';
select coalesce(to_jsonb(d) ->> 'address', d.code) || '|'
       || (select count(*) from pg_catalog.pg_stat_activity a
            where a.application_name = :'app' and a.pid <> pg_catalog.pg_backend_pid()
              and coalesce(a.state, 'idle') <> 'idle')::text
  from erp_meta.deployment d where d.code = :'code';
SQL
}

# read_back <reader>: after each pause, asks; prints the address at the first
# clear answer and returns 0; returns 1 when no try had one.
read_back() {
  local pause got where busy
  for pause in $READ_BACK_PAUSES; do
    $SLEEP_CMD "$pause"
    if got=$("$1"); then
      IFS='|' read -r where busy <<< "$got"
      if [[ "${busy:-0}" == 0 ]]; then
        printf '%s' "$where"
        return 0
      fi
      echo "! asked again after ${pause} s: this run's statement whose answer was lost is still at work there" >&2
    else
      echo "! asked again after ${pause} s, and no answer: $(said "$work/err.read")" >&2
    fi
  done
  return 1
}

# sha256_of <text>: its SHA-256, as the Management API lists a secret's.
sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
  fi
}

# put_back: every piece back at the old address, in reverse, and then each
# read back. The database only when this run moved it (it was at the old
# address when this run began, or this would be a rename carried on); the
# function secret and the auth settings whatever this run did, since the run
# before may have set them (a rename that stopped after its first two steps
# and before its database moved), and each is idempotent. Sets
# PIECES_WHERE to where each piece is, in words, and returns 0 only when
# every one is at the old address.
put_back() {
  local db="" functions="" auth="" got site digest want_old want_new ok=yes
  case " $DONE_STEPS " in
    *" database "*)
      if client_move "$OLD_ORIGIN" "$FROM"; then
        event identity done "put back: served at ${OLD_ORIGIN}, organisation ${FROM}"
        db="at ${FROM}"
      else
        event identity failed "could not be put back to ${FROM}: $(said)"
        db="still at ${TO} (it could not be put back: $(said))"
        ok=no
      fi ;;
    *)
      # Never moved by this run: where it was, or where it answered when
      # asked again after its move failed.
      if [[ -n "$READ_BACK" && "$READ_BACK" != "$FROM" ]]; then
        db="at ${READ_BACK}, as it answered when asked again"
        ok=no
      else
        db="at ${FROM}"
      fi ;;
  esac
  if "$PROV" secrets "$REF" "CLOVEERP_APP_URL=${OLD_ORIGIN}" > /dev/null 2> "$work/err"; then
    event functions done "put back: CLOVEERP_APP_URL ${OLD_ORIGIN}"
  else
    functions="it could not be put back: $(said)"
    event functions failed "CLOVEERP_APP_URL could not be put back to ${OLD_ORIGIN}: $(said)"
  fi
  if ALSO_ALLOW="$ALLOW_FROM" "$PROV" configure "$REF" "$FROM" > /dev/null 2> "$work/err"; then
    event configure done "put back: site ${OLD_ORIGIN}, $(redirects "$FROM" "$ALLOW_FROM")"
  else
    auth="it could not be put back: $(said)"
    event configure failed "the auth settings could not be put back to ${OLD_ORIGIN}: $(said)"
  fi

  # Read back, each: "as before" is said of what is, not of what was asked.
  if got=$("$PROV" site "$REF" 2> "$work/err"); then
    site="${got#site=}"
    case "$site" in
      "$OLD_ORIGIN") auth="at ${FROM}" ;;
      "$NEW_ORIGIN") auth="at ${TO}${auth:+ (${auth})}"; ok=no ;;
      *) auth="at ${site:-no site}${auth:+ (${auth})}"; ok=no ;;
    esac
  else
    auth="not known: they could not be read back ($(said))${auth:+; ${auth}}"; ok=no
  fi
  want_old=$(sha256_of "$OLD_ORIGIN")
  want_new=$(sha256_of "$NEW_ORIGIN")
  if got=$("$PROV" secret-digest "$REF" CLOVEERP_APP_URL 2> "$work/err"); then
    digest="${got#digest=}"
    case "$digest" in
      "$want_old") functions="at ${FROM}" ;;
      "$want_new") functions="at ${TO}${functions:+ (${functions})}"; ok=no ;;
      "") functions="not set${functions:+ (${functions})}"; ok=no ;;
      *) functions="neither ${FROM} nor ${TO}${functions:+ (${functions})}"; ok=no ;;
    esac
  else
    functions="not known: it could not be read back ($(said))${functions:+; ${functions}}"; ok=no
  fi
  PIECES_WHERE="its database is ${db}; its auth settings are ${auth}; its functions' address (CLOVEERP_APP_URL) is ${functions}"
  [[ "$ok" == yes ]]
}

# resumed_stop <step> <why>: a step known to have failed in a rename carried
# on (its database was already at the new address when this run began).
# Nothing is put back toward the old address: this run never moved the
# database, and the run before may have set what came before it (see the
# header). Said, on the row, and exit 3; the request is the workflow's last
# step's to settle, from what the register says then.
resumed_stop() {
  local step="$1" why="$2" where words
  case "$step" in
    "the auth settings")
      where="its database is at ${TO}, its auth settings may be at either address, its functions' address is where the run before left it, and the register still has it at ${FROM}" ;;
    "the function secret")
      where="its database and its auth settings are at ${TO}, its functions' address may be at either, and the register still has it at ${FROM}" ;;
    "the database")
      where="its auth settings and its functions' address are at ${TO}, its database answered at ${READ_BACK:-no address} when asked again, and the register still has it at ${FROM}" ;;
    *)
      where="its auth settings, its functions' address and its database are at ${TO}, and the register still has it at ${FROM}" ;;
  esac
  words="${step} failed (${why}). ${CODE}'s database was already at ${TO} when this run began (a rename that stopped, carried on), so nothing was put back toward ${FROM}: ${CODE} is partly at ${TO}; ${where}. Ask for the same rename (${FROM} to ${TO}) again: every step can be repeated, and that finishes it; this run's last step settles the request from what the register says."
  event rename failed "not finished moving to ${TO}: ${words}"
  say_error "${CODE} was not finished moving to ${TO}: ${words}"
  echo "- ${CODE}: NOT finished moving to ${TO}, and partly there: ${words}" >> "$SUMMARY"
  exit 3
}

# stop <step> <why>: a step is known to have failed, and the database is at
# the old address (or this run moved it, and puts it back): every piece is
# put back there and read back (put_back). Only when each reads back at the
# old address do the row and the request say it is there as before, and the
# run is red (exit 1). Otherwise they say where each piece is, and the
# request is left for the workflow's last step (exit 3), as when a write's
# answer is lost. In a rename carried on, nothing is put back
# (resumed_stop).
stop() {
  local step="$1" why="$2" left words
  if [[ "$AGAIN" == yes ]]; then
    resumed_stop "$step" "$why"
  fi
  PIECES_WHERE=""
  if put_back; then
    left=" Each piece was put back, and read back at ${FROM} (its database, its auth settings and its functions' address, whichever run had set them): ${CODE} is at ${FROM} as before."
    event rename failed "not moved to ${TO}: ${step} failed (${why}).${left}"
    say_error "${CODE} was not renamed to ${TO}: ${step} failed (${why}).${left}"
    echo "- ${CODE}: NOT renamed to ${TO}: ${step} failed (${why}).${left}" >> "$SUMMARY"
    # Where it is first: the outcome is cut at 300 characters, and the
    # reason before it can be long.
    settle failure "${CODE} is at ${FROM} as before, each piece put back and read back there: ${step} failed (${why})" || true
    exit 1
  fi
  words="${step} failed (${why}). Not every piece is back at ${FROM}: ${PIECES_WHERE}. Ask for the same rename (${FROM} to ${TO}) again, which carries it on to ${TO} (every step can be repeated); or, to keep it at ${FROM}, set its auth settings and its functions' address from the register again (fleet_secrets.yml, patch_auth and set_function_secrets). This run's last step settles the request from what the register says."
  event rename failed "not moved to ${TO}, and not all back at ${FROM}: ${words}"
  say_error "${CODE} was not renamed to ${TO}, and is not all back at ${FROM}: ${words}"
  echo "- ${CODE}: NOT renamed to ${TO}, and NOT all back at ${FROM}: ${words}" >> "$SUMMARY"
  exit 3
}

# unknown <step> <why> <where things stand>: a write whose answer was lost,
# and whose read-back never came. Nothing is undone: see the header. Said,
# on the row when it can be, and exit 3; the request is the workflow's last
# step's to settle, from what the register says then.
unknown() {
  local step="$1" why="$2" where="$3" words
  words="whether ${step} took the move to ${TO} could not be learned: its answer was lost (${why}), and no clear answer came when it was asked again ${PAUSE_COUNT} time(s) over the next ${PAUSE_TOTAL} seconds. Nothing was undone: ${where}. Every step can be repeated, so asking for the same rename again (${FROM} to ${TO}) finishes it; this run's last step reads the register once more and settles the request from what it says."
  event rename failed "$words"
  say_error "${CODE}: ${words}"
  echo "- ${CODE}: NOT KNOWN whether renamed to ${TO}: ${words}" >> "$SUMMARY"
  exit 3
}

# 1. The auth settings.
if ! ALSO_ALLOW="$ALLOW_TO" "$PROV" configure "$REF" "$TO" > /dev/null 2> "$work/err"; then
  # A PATCH that went through and read back wrong may have changed them.
  DONE_STEPS="auth"
  event configure failed "auth settings for ${NEW_ORIGIN} not applied: $(said)"
  stop "the auth settings" "$(said)"
fi
DONE_STEPS="auth"
event configure done "site ${NEW_ORIGIN}, $(redirects "$TO" "$ALLOW_TO")"

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
  # A commit whose answer was lost is a commit: the database is asked before
  # anything is undone.
  if ! now=$(read_back client_now); then
    unknown "its database" "$why" "its auth settings and its functions' address are at ${TO}, its database may be at either, and the register still has it at ${FROM}"
  fi
  READ_BACK="$now"
  if [[ "$now" != "$TO" ]]; then
    event identity failed "not moved to ${TO}: ${why}"
    stop "the database" "$why"
  fi
  echo "${CODE}'s database answered at ${TO} when asked again: the move had committed"
fi
DONE_STEPS="database functions auth"
event identity done "served at ${NEW_ORIGIN}; its organisation's code is ${TO}"

# 4. The register.
if ! cp_q -v code="$CODE" -v to="$TO" > /dev/null 2> "$work/err" <<'SQL'
-- fleet: cp-finish
set statement_timeout = '10s';
select erp_meta.finish_deployment_rename(:'code', :'to');
SQL
then
  why=$(said)
  # A commit whose answer was lost is a commit: the register is asked before
  # anything is undone.
  if ! now=$(read_back register_now); then
    unknown "the register" "$why" "its auth settings, its functions' address and its database are at ${TO}, and the register may have it at either"
  fi
  if [[ "$now" != "$TO" ]]; then
    stop "the register" "$why"
  fi
  echo "the register answered with ${CODE} at ${TO} when asked again: the move had committed"
fi

echo "${CODE}: moved from ${FROM} to ${TO}; ${OLD_ORIGIN} sends people to ${NEW_ORIGIN} for ninety days"
{
  echo "## ${CODE} renamed"
  echo "- from ${OLD_ORIGIN} to ${NEW_ORIGIN}"
  echo "- the old address sends people to the new one for ninety days, and is held for ${CODE} for good"
} >> "$SUMMARY"
settle success "${CODE} moved from ${FROM} to ${TO}: auth settings, CLOVEERP_APP_URL, its database and the register" || exit 1
