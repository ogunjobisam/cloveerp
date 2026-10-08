#!/usr/bin/env bash
#
# One client's database, exported off the platform
# (.github/workflows/fleet_export.yml).
#
# A client leaving takes its business with it: the owner begins offboarding
# from the Fleet view, which asks for an export (erp_platform_begin_offboarding,
# 20261012030000), or an operator asks for one at any other time (Export now,
# erp_platform_request_export). The sweep (fleet_sweep.yml) starts this with
# the request's id, and the workflow's last step settles the request from
# what this says. The client's database is dumped as the restore drill dumps
# it, with its sign-ins, its stored documents (the Storage bucket
# document-output) are fetched beside it, and the whole is sealed to the
# owner's age key and put in the owner's bucket at
#
#   exports/<code>/<UTC time, YYYYMMDDTHHMMSSZ>.dump.age
#
# (supabase/ci/fleet_offsite.sh says what is inside and how to read it). The
# store is asked for the object again, and only then is the export written on
# the client's row in the control plane's register, with its size and sha256
# (erp_meta.record_deployment_export), where the Fleet view shows it, and
# where retiring the client looks for it.
#
# Retiring a client that had a database waits for a copy taken after its
# service was stopped: the copy that is the last of its business. The
# register's suspension stops its address at once, but its own database
# hears of it only when the status sync next runs (fleet_sync.yml), and until
# then a session held from before can still write. So when the register has
# the client suspended (its suspended_reason is set), its organisation is
# suspended here first, on its own database, through the status sync's own
# routine (erp_meta.follow_deployment_status(true, <the register's reason>));
# the reason is the owner's words about a client's business, and is given to
# the client's database and printed nowhere. Only when the routine answers
# that the organisation is suspended (or that the client has none yet) is
# the copy recorded as taken after the service stopped. When it cannot be
# made so (a database not yet released the routine, a routine that fails,
# an organisation in another state), the copy is still taken, recorded as
# taken while the client was served, and the run says why. Either way the
# copy is recorded with the moment its dump began, read from the control
# plane's own clock just before it, not with when it was recorded.
#
# Until the owner has made the bucket and the key, nothing is dumped: a plain
# error names what is missing, the client's row says so, and nothing is
# uploaded or recorded.
#
# The client's status is read before anything is written, and nothing is
# ever written on the row of a client that is not up to be exported (built,
# live, suspended, or retiring once built): a failed step on the row of one
# being built marks its build failed (erp_meta.record_deployment_event), and
# the build then cannot be marked built. Such a client is said, and left.
#
# Usage: fleet_export.sh <code>
#        CHECK_ONLY=yes fleet_export.sh <code>   only whether the client may
#                                                be exported and the bucket
#                                                and key are set: 0 if so, 1
#                                                (with the error, on the row
#                                                too when it is up) if not
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane: the register and its vault
#   PRODUCTION_REF, DEMO_REF    refs the client's connection must not name, as
#                               well as every other ref in the register
#   the settings of supabase/ci/fleet_offsite.sh
#   CLIENT_STATEMENT_TIMEOUT    each statement on the client (default 30s): the
#                               pooler drops PGOPTIONS, so it is set in SQL
#   OUTCOME_FILE                where the outcome is written, for the
#                               workflow's last step: a first line
#                               "success: ..." or "failure: ...", and a second
#                               line "told" once the client's row has been told
#   PSQL                        the command (the rehearsal's stand-in)
#   OFFSITE_NOW                 the time the object is named for (default now;
#                               the rehearsal's clock)
#
# The client's connection string and service key come from the control
# plane's vault, are masked before anything else is printed, and the
# connection must name the client's project and no other deployment's. Its
# database must say it is a client's.
#
# Exit: 0 exported and recorded; 1 not (an ::error:: line says why, and the
# client's row says so too when it is up and can be told); 2 nothing was
# tried.
#
# bash 3.2 and 5. Rehearsed on every build: supabase/ci/fleet_export_rehearsal.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supabase/ci/fleet_offsite.sh
. "$HERE/fleet_offsite.sh"

CODE="${1:-}"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
TIMEOUT="${CLIENT_STATEMENT_TIMEOUT:-30s}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

say_error() { if offsite_in_actions; then echo "::error::$*"; else echo "x $*" >&2; fi; }
mask() { if offsite_in_actions && [[ -n "${1:-}" ]]; then echo "::add-mask::$1"; fi; }

# The outcome, for the workflow's last step, which settles the request with
# it. Written on every way out; a run killed before any is written is said
# by that step itself.
OUTCOME="failure: the export stopped before it finished (cancelled, timed out or killed), and nothing was recorded"
TOLD=no
work=""
finish() {
  local rc=$?
  if [[ -n "${OUTCOME_FILE:-}" ]]; then
    { printf '%s\n' "$(printf '%s' "$OUTCOME" | tr -s ' \t\r\n' '    ' | cut -c 1-900)"
      if [[ "$TOLD" == yes ]]; then echo told; fi; } > "$OUTCOME_FILE" 2> /dev/null || true
  fi
  if [[ -n "$work" ]]; then rm -rf "$work"; fi
  return "$rc"
}
trap finish EXIT

if ! [[ "$CODE" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  OUTCOME="failure: '${CODE}' is not a client's code; nothing was exported"
  say_error "'${CODE}' is not a client's code. Nothing was exported."
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_export.XXXXXX")

said() {
  local first
  first=$(grep -E 'ERROR|FATAL|error|refus|could not|^x ' "$work/err" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$work/err" 2> /dev/null || true)
  first="${first#psql:<stdin>:*: }"
  first=$(printf '%s' "$first" | sed -E 's/^(ERROR|FATAL): +//')
  offsite_redact "${first:-no reason given}" "${url:-}" "${service_key:-}" "${SUSPENDED_REASON:-}"
}
cp_q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }
reg() { CLOVEERP_LIVE_DATABASE_URL="$CP_URL" PSQL="$PSQL_CMD" "$HERE/fleet_register.sh" "$@"; }

# tell <words>: the client's row told that its export was not made, once its
# status has been read and it is up (UP=yes); never before, and never for a
# client that is not (see the header). Never fails the run a second time:
# the export is what failed, and the workflow's last step tells the row when
# this could not, under the same rule.
UP=no
tell() {
  if [[ "$UP" != yes ]]; then
    echo "! ${CODE}'s row is not told: its status was not read as up" >&2
    return 0
  fi
  if [[ -n "$CP_URL" ]] && reg event "$CODE" export failed "export not made: $* (fleet_export.yml)" > /dev/null 2> "$work/err"; then
    TOLD=yes
  else
    echo "! ${CODE}'s row could not be told that its export failed ($(said))" >&2
  fi
}

# failed <words>: said, on the row, and the outcome.
failed() {
  OUTCOME="failure: $*"
  say_error "${CODE}: $*"
  echo "- ${CODE}: export FAILED: $*" >> "$SUMMARY"
  tell "$*"
  exit 1
}

offsite_mask

# ── The register: is it up to be exported, before anything is written ───────
# Read first, the not-configured way out included (which tells the row).
# Without a control plane nothing can be told, and the run stops below.
# With its status, the reason it is suspended, if it is (empty if not), as
# a JSON string last on the line, so a reason holding anything at all
# arrives whole; through to_jsonb, so a control plane not yet released
# 20261012030000 is said below rather than refused here.
SUSPENDED_REASON=""
if [[ -n "$CP_URL" ]]; then
  row=$(cp_q -v code="$CODE" 2> "$work/err" <<'SQL'
-- fleet: cp-row
select d.status || '|' || (d.built_at is not null)::text || '|' || coalesce(d.project_ref, '') || '|'
       || coalesce(d.api_url, '') || '|'
       || to_jsonb(coalesce(to_jsonb(d) ->> 'suspended_reason', ''))::text
  from erp_meta.deployment d where d.code = :'code';
SQL
  ) || failed "the register could not be read ($(said)). Nothing was exported"
  if [[ -z "$row" ]]; then
    failed "${CODE} is not in the control plane's register. Nothing was exported"
  fi
  IFS='|' read -r status built ref api reason_json <<< "$row"
  if [[ -n "${reason_json:-}" ]]; then
    SUSPENDED_REASON=$(jq -r 'if type == "string" then . else "" end' <<< "$reason_json" 2> /dev/null) ||
      failed "the register's reason for its suspension could not be read. Nothing was exported"
  fi
  case "$status" in
    built|live|suspended) : ;;
    retiring)
      [[ "$built" == true ]] ||
        failed "${CODE} is retiring and was never built, so there is no database to export. Nothing was exported, and nothing written on its row" ;;
    *) failed "${CODE} is ${status}: only a client whose database is up (built, live, suspended, or retiring once built) is exported. Nothing was exported, and nothing written on its row" ;;
  esac
  UP=yes
fi

missing=$(offsite_missing)
if [[ -n "$missing" ]]; then
  words="${CODE} cannot be exported until the owner has made somewhere to put it: $(printf '%s' "$missing" | paste -sd ';' - | sed 's/;/; and /g'). Nothing was dumped, uploaded or recorded"
  OUTCOME="failure: ${words}"
  say_error "${words}."
  echo "- ${CODE}: export FAILED: ${words}" >> "$SUMMARY"
  tell "$words"
  exit 1
fi
if [[ "${CHECK_ONLY:-}" == yes ]]; then
  OUTCOME="success: the bucket and the key are set"
  echo "the bucket and the key are set"
  exit 0
fi

if [[ -z "$CP_URL" ]]; then
  OUTCOME="failure: CLOVEERP_LIVE_DATABASE_URL is not set, so the register cannot say where ${CODE} is; nothing was exported"
  say_error "CLOVEERP_LIVE_DATABASE_URL is not set, so the register cannot say where ${CODE} is. Nothing was exported."
  exit 2
fi

# ── The register: may it record an export, and where is the client ──────────
ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regprocedure('erp_meta.record_deployment_export(text,text,bigint,text,timestamptz,boolean)') is not null)::text;
SQL
) || failed "the control plane could not be read ($(said)). Nothing was exported"
if [[ "$ready" != true ]]; then
  failed "the control plane cannot record an export yet (20261012030000 is not released there), so ${CODE} was not exported: release the control plane, then ask again"
fi
if ! [[ "$ref" =~ ^[a-z0-9]{20}$ ]]; then
  failed "the register gives it no project ref ('${ref}')"
fi
# Its stored documents are fetched from its project's own Storage API with
# its service key: the address must be its project's, exactly, or the key
# would be sent elsewhere (the register writes https://<ref>.supabase.co and
# nothing else, deployment_from_empty.yml).
api="${api%/}"
[[ -n "$api" ]] || api="https://${ref}.supabase.co"
[[ "$api" == "https://${ref}.supabase.co" ]] ||
  failed "the register's address for its project's API (${api}) is not its project's, so its service key would not be sent there; nothing was exported"
others=$(cp_q -v code="$CODE" 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '')
  from erp_meta.deployment d where d.code <> :'code' and d.project_ref is not null;
SQL
) || failed "the register could not say which other projects there are ($(said))"

# ── Its connection, as release.yml resolves it, and its service key ─────────
vault="cloveerp:deployment:${ref}:db_url"
url=$(reg vault-get "$vault" 2> "$work/err") || failed "the control plane's vault could not be read for ${vault} ($(said))"
mask "$url"
[[ -n "$url" ]] || failed "the control plane's vault has no ${vault}, so its database cannot be reached"
[[ "$url" == *"$ref"* ]] || failed "${vault} does not name its project (${ref}), so it was not read"
IFS=',' read -r -a refs <<< "${others},${PRODUCTION_REF:-xpzffnnhnhcqyjqcueja},${DEMO_REF:-}"
for other in ${refs[@]+"${refs[@]}"}; do
  other="${other// /}"
  if [[ -n "$other" && "$other" != "$ref" && "$url" == *"$other"* ]]; then
    failed "${vault} names another deployment's project (${other}), so it was not read"
  fi
done
key_name="cloveerp:deployment:${ref}:service_key"
service_key=$(reg vault-get "$key_name" 2> "$work/err") || failed "the control plane's vault could not be read for ${key_name} ($(said))"
mask "$service_key"
[[ -n "$service_key" ]] ||
  failed "the control plane's vault has no ${key_name}, so its stored documents (${OFFSITE_BUCKET}) cannot be fetched, and a copy without them is not the business's copy; nothing was exported"
kind=$($PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$TIMEOUT" 2> "$work/err" <<'SQL'
-- fleet: client-kind
set statement_timeout = :'timeout';
select coalesce(erp.deployment_kind(), '') || '|'
       || (to_regprocedure('erp_meta.follow_deployment_status(boolean,text)') is not null)::text;
SQL
) || failed "its database could not be reached ($(said))"
IFS='|' read -r kind can_follow <<< "$kind"
[[ "$kind" == client ]] || failed "its database says it is the ${kind:-unknown} deployment, not a client's, so it was not dumped"

# ── Its service stopped first, when the register has it suspended ───────────
# (see the header). STOPPED is what the register is told; NOT_STOPPED says
# why it is not, in words that never hold the reason.
STOPPED=false
NOT_STOPPED=""
if [[ -z "$SUSPENDED_REASON" ]]; then
  NOT_STOPPED="the register does not have it suspended, so its people could still change its data while it was copied"
elif [[ "$can_follow" != true ]]; then
  NOT_STOPPED="its database has not yet been released the routine that suspends its organisation (erp_meta.follow_deployment_status, 20261012030000), so whether its people could still change its data while it was copied is not known"
elif ! followed=$($PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$TIMEOUT" -v reason="$SUSPENDED_REASON" 2> "$work/err" <<'SQL'
-- fleet: client-follow
set statement_timeout = :'timeout';
select erp_meta.follow_deployment_status(true, nullif(:'reason', ''));
SQL
); then
  NOT_STOPPED="its organisation could not be suspended on its own database ($(said)), so whether its people could still change its data while it was copied is not known"
else
  org=$(jq -r 'if type == "object" and has("status") then (.status // "none") else "?" end' <<< "$followed" 2> /dev/null || echo "?")
  case "$org" in
    suspended|none)
      STOPPED=true
      if [[ "$org" == none ]]; then
        echo "${CODE} has no organisation yet, so nothing on its database can change its data"
      elif [[ "$(jq -r '.changed == true' <<< "$followed" 2> /dev/null)" == true ]]; then
        echo "${CODE}'s organisation suspended on its own database, as the register says, before it is copied"
        reg event "$CODE" note note "status: its organisation suspended on its own database, as the register says, before its export (fleet_export.yml)" > /dev/null 2> "$work/err" ||
          echo "! ${CODE}'s row could not be told that its organisation was suspended ($(said))" >&2
      else
        echo "${CODE}'s organisation is suspended on its own database"
      fi ;;
    "?") NOT_STOPPED="its database answered something that is not what the routine that suspends its organisation answers, so whether its people could still change its data while it was copied is not known" ;;
    *) NOT_STOPPED="its organisation is ${org} on its own database, not suspended, so its people could still change its data while it was copied" ;;
  esac
fi
if [[ "$STOPPED" != true && -n "$SUSPENDED_REASON" ]]; then
  if offsite_in_actions; then echo "::warning::${CODE}: ${NOT_STOPPED}. It is copied all the same, and recorded as taken while it was still served: it is not the last copy that retiring it waits for."
  else echo "! ${CODE}: ${NOT_STOPPED}. It is copied all the same, and recorded as taken while it was still served." >&2; fi
fi

# ── Dumped, its documents fetched, sealed, put, and asked for again ──────────
now="${OFFSITE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
[[ "$now" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || failed "the time '${now}' is not a UTC time"
stamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}T${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}Z"
object="exports/${CODE}/${stamp}.dump.age"
mkdir -p "$work/dump"
echo "exporting ${CODE} (project ${ref}, ${status}) to ${object}"
# When the copy was taken: the control plane's clock, the one the register
# keeps every other moment by, just before the dump begins (after its
# service was stopped, when it was).
taken_at=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-clock
select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
SQL
) || failed "the control plane's clock could not be read ($(said)), and a copy is recorded with when it was taken; nothing was dumped"
[[ "$taken_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$ ]] ||
  failed "the control plane's clock answered '$(offsite_redact "$taken_at")', which is not a time; nothing was dumped"
offsite_dump "$url" "$work/dump" "$CODE" "$ref" || failed "$OFFSITE_WHY"
OFFSITE_STORED=""
offsite_storage "$api" "$service_key" "$work/dump" || failed "$OFFSITE_WHY"
# Still stopped once its data and its documents are copied. A status sync
# working from a snapshot of the register read before the suspension could
# lift the suspension this run made while the copy was being taken, and its
# people write again until the next sync suspends it once more. Asked once
# more: anything but "suspended, and nothing to change" means its data may
# have changed during the copy, so this is not the last copy (20261012030000).
if [[ "$STOPPED" == true && "${org:-}" == suspended ]]; then
  if ! again=$($PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA -v timeout="$TIMEOUT" -v reason="$SUSPENDED_REASON" 2> "$work/err" <<'SQL'
-- fleet: client-follow-again
set statement_timeout = :'timeout';
select erp_meta.follow_deployment_status(true, nullif(:'reason', ''));
SQL
  ); then
    STOPPED=false
    NOT_STOPPED="whether its organisation stayed suspended while it was copied could not be confirmed ($(said)), so whether its people could change its data meanwhile is not known"
  elif [[ "$(jq -r 'if type == "object" and .status == "suspended" and .changed == false then "yes" else "no" end' <<< "$again" 2> /dev/null || echo no)" != yes ]]; then
    STOPPED=false
    NOT_STOPPED="its organisation was not still suspended once its data had been copied (its suspension was lifted meanwhile, and is made again now), so its people may have changed its data while it was copied"
  fi
  if [[ "$STOPPED" != true ]]; then
    if offsite_in_actions; then echo "::warning::${CODE}: ${NOT_STOPPED}. It is recorded as taken while it was still served: it is not the last copy that retiring it waits for."
    else echo "! ${CODE}: ${NOT_STOPPED}. It is recorded as taken while it was still served." >&2; fi
  fi
fi
offsite_seal "$work/dump" "$work/copy.age" || failed "$OFFSITE_WHY"
bytes=$(offsite_bytes "$work/copy.age")
sha=$(offsite_sha256 "$work/copy.age")
offsite_put "$work/copy.age" "$object" || failed "$OFFSITE_WHY"

recorded=$(cp_q -v code="$CODE" -v object="$object" -v bytes="$bytes" -v sha="$sha" -v taken_at="$taken_at" \
              -v stopped="$STOPPED" 2> "$work/err" <<'SQL'
-- fleet: cp-record
select erp_meta.record_deployment_export(:'code', :'object', :'bytes'::bigint, :'sha',
                                         :'taken_at'::timestamptz, :'stopped'::boolean);
SQL
) || failed "the copy is in the bucket as ${object} (${bytes} bytes, sha256 ${sha}), and the register refused to record it ($(said)); the Fleet view does not show it"
: "$recorded"
# The register's own record of the export is the step on the client's row.
TOLD=yes
if [[ "$STOPPED" == true ]]; then
  taken="taken at ${taken_at}, after its service was stopped"
else
  taken="taken at ${taken_at} while it was still served (${NOT_STOPPED}), so it is not the last copy that retiring it waits for"
fi
OUTCOME="success: ${CODE} exported as ${object} (${bytes} bytes, sha256 ${sha}; ${OFFSITE_STORED}); ${taken}"

echo "${CODE}: exported as ${object}, ${bytes} bytes, sha256 ${sha}, with ${OFFSITE_STORED}; ${taken}"
{
  echo "## ${CODE} exported"
  echo "- object: ${object}"
  echo "- ${bytes} bytes, sha256 ${sha}"
  echo "- its database, its sign-ins and ${OFFSITE_STORED} from ${OFFSITE_BUCKET}"
  echo "- ${taken}"
  echo "- read it with: age -d -i <the private key> ${object##*/} | tar -x"
} >> "$SUMMARY"
