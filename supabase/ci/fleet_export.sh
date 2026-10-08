#!/usr/bin/env bash
#
# One client's database, exported off the platform
# (.github/workflows/fleet_export.yml).
#
# A client leaving takes its business with it: the owner begins offboarding
# from the Fleet view, which asks for an export (erp_platform_begin_offboarding,
# 20261012020000), or asks for one at any other time (Export now,
# erp_platform_request_export). The sweep (fleet_sweep.yml) starts this. The
# client's database is dumped as the restore drill dumps it, with its
# sign-ins, sealed to the owner's age key, and put in the owner's bucket at
#
#   exports/<code>/<UTC time, YYYYMMDDTHHMMSSZ>.dump.age
#
# (supabase/ci/fleet_offsite.sh says what is inside and how to read it). The
# store is asked for the object again, and only then is the export written on
# the client's row in the control plane's register, with its size and sha256
# (erp_meta.record_deployment_export), where the Fleet view shows it.
#
# Until the owner has made the bucket and the key, nothing is dumped: a plain
# error names what is missing, and nothing is uploaded or recorded.
#
# Usage: fleet_export.sh <code>
#        CHECK_ONLY=yes fleet_export.sh <code>   only whether the bucket and
#                                                key are set: 0 if they are,
#                                                1 (with the error) if not
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane: the register and its vault
#   PRODUCTION_REF, DEMO_REF    refs the client's connection must not name, as
#                               well as every other ref in the register
#   the settings of supabase/ci/fleet_offsite.sh
#   PSQL                        the command (the rehearsal's stand-in)
#   OFFSITE_NOW                 the time the object is named for (default now;
#                               the rehearsal's clock)
#
# The client's connection string comes from the control plane's vault, is
# masked before anything else is printed, and must name the client's project
# and no other deployment's. Its database must say it is a client's.
#
# Exit: 0 exported and recorded; 1 not (an ::error:: line says why, and the
# client's row says so too when it got that far); 2 nothing was tried.
#
# bash 3.2 and 5. Rehearsed on every build: supabase/ci/fleet_export_rehearsal.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supabase/ci/fleet_offsite.sh
. "$HERE/fleet_offsite.sh"

CODE="${1:-}"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"

say_error() { if offsite_in_actions; then echo "::error::$*"; else echo "x $*" >&2; fi; }
mask() { if offsite_in_actions && [[ -n "${1:-}" ]]; then echo "::add-mask::$1"; fi; }

if ! [[ "$CODE" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  say_error "'${CODE}' is not a client's code. Nothing was exported."
  exit 2
fi

offsite_mask
missing=$(offsite_missing)
if [[ -n "$missing" ]]; then
  say_error "${CODE} cannot be exported until the owner has made somewhere to put it: $(printf '%s' "$missing" | paste -sd ';' - | sed 's/;/; and /g'). Nothing was dumped, uploaded or recorded."
  exit 1
fi
if [[ "${CHECK_ONLY:-}" == yes ]]; then
  echo "the bucket and the key are set"
  exit 0
fi

if [[ -z "$CP_URL" ]]; then
  say_error "CLOVEERP_LIVE_DATABASE_URL is not set, so the register cannot say where ${CODE} is. Nothing was exported."
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_export.XXXXXX")
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

# failed <words>: said, and written on the client's row (never failing the
# run a second time: the export is what failed).
failed() {
  say_error "${CODE}: $*"
  echo "- ${CODE}: export FAILED: $*" >> "$SUMMARY"
  reg event "$CODE" export failed "export not made: $* (fleet_export.yml)" > /dev/null 2> "$work/err" ||
    echo "! ${CODE}'s row could not be told that its export failed ($(said))" >&2
  exit 1
}

# ── The register: may it be exported, and where is it ───────────────────────
ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regprocedure('erp_meta.record_deployment_export(text,text,bigint,text)') is not null)::text;
SQL
) || { say_error "the control plane could not be read ($(said)). Nothing was exported."; exit 1; }
if [[ "$ready" != true ]]; then
  say_error "the control plane cannot record an export yet (20261012020000 is not released there), so ${CODE} was not exported: release the control plane, then ask again."
  exit 1
fi
row=$(cp_q -v code="$CODE" 2> "$work/err" <<'SQL'
-- fleet: cp-row
select d.status || '|' || coalesce(d.project_ref, '')
  from erp_meta.deployment d where d.code = :'code';
SQL
) || { say_error "the register could not be read ($(said)). Nothing was exported."; exit 1; }
if [[ -z "$row" ]]; then
  say_error "${CODE} is not in the control plane's register. Nothing was exported."
  exit 1
fi
IFS='|' read -r status ref <<< "$row"
case "$status" in
  built|live|suspended|retiring) : ;;
  *)
    say_error "${CODE} is ${status}: only a client whose database is up (built, live, suspended or retiring) is exported. Nothing was exported."
    exit 1 ;;
esac
if ! [[ "$ref" =~ ^[a-z0-9]{20}$ ]]; then
  failed "the register gives it no project ref ('${ref}')"
fi
others=$(cp_q -v code="$CODE" 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '')
  from erp_meta.deployment d where d.code <> :'code' and d.project_ref is not null;
SQL
) || failed "the register could not say which other projects there are ($(said))"

# ── Its connection, as release.yml resolves it ───────────────────────────────
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
kind=$($PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA 2> "$work/err" <<'SQL'
-- fleet: client-kind
select coalesce(erp.deployment_kind(), '');
SQL
) || failed "its database could not be reached ($(said))"
[[ "$kind" == client ]] || failed "its database says it is the ${kind:-unknown} deployment, not a client's, so it was not dumped"

# ── Dumped, sealed, put, and asked for again ─────────────────────────────────
now="${OFFSITE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
[[ "$now" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || failed "the time '${now}' is not a UTC time"
stamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}T${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}Z"
object="exports/${CODE}/${stamp}.dump.age"
mkdir -p "$work/dump"
echo "exporting ${CODE} (project ${ref}, ${status}) to ${object}"
offsite_dump "$url" "$work/dump" "$CODE" "$ref" || failed "$OFFSITE_WHY"
offsite_seal "$work/dump" "$work/copy.age" || failed "$OFFSITE_WHY"
bytes=$(offsite_bytes "$work/copy.age")
sha=$(offsite_sha256 "$work/copy.age")
offsite_put "$work/copy.age" "$object" || failed "$OFFSITE_WHY"

recorded=$(cp_q -v code="$CODE" -v object="$object" -v bytes="$bytes" -v sha="$sha" 2> "$work/err" <<'SQL'
-- fleet: cp-record
select erp_meta.record_deployment_export(:'code', :'object', :'bytes'::bigint, :'sha');
SQL
) || failed "the copy is in the bucket as ${object} (${bytes} bytes, sha256 ${sha}), and the register refused to record it ($(said)); the Fleet view does not show it"
: "$recorded"

echo "${CODE}: exported as ${object}, ${bytes} bytes, sha256 ${sha}"
{
  echo "## ${CODE} exported"
  echo "- object: ${object}"
  echo "- ${bytes} bytes, sha256 ${sha}"
  echo "- read it with: age -d -i <the private key> ${object##*/} | tar -x"
} >> "$SUMMARY"
