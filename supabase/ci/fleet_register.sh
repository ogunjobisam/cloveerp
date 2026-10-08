#!/usr/bin/env bash
#
# The control plane's register of client deployments, from a workflow.
#
# One Supabase project per client, one subdomain each (20261011020000). The
# workflows that build a client's project (deployment_from_empty.yml) and
# release into it (release.yml, deploy.yml) record what they do on the
# client's row in erp_meta.deployment, and keep the project's connection
# string and secret key in the control plane's vault, named by the project's
# ref. This is the one place those statements are written, so each workflow
# runs the same ones and a value from the vault is masked in the log before
# anything else sees it.
#
# Usage: fleet_register.sh <command> ...   with CLOVEERP_LIVE_DATABASE_URL set
#
#   row <code>                         prints status=… ref=… api_url=…
#   event <code> <phase> <status> [detail]
#                                      one step recorded; the run id from
#                                      GITHUB_RUN_ID
#   project <code> <ref> <api_url> <publishable_key> [region] [size]
#   built <code>
#   vault-put <name>                   the value from stdin, never from an
#                                      argument (an argument is in ps)
#   vault-get <name>                   prints the value and nothing else, so a
#                                      caller captures it; empty when absent.
#                                      THE CALLER MASKS IT (::add-mask::)
#                                      before anything else is printed
#   vault-del <name>
#
# Names in the vault: cloveerp:deployment:<ref>:db_url,
# cloveerp:deployment:<ref>:service_key, and cloveerp:provision:<code>:db_pass
# while a project is being made and its ref is not yet known.
set -euo pipefail

CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
[[ -n "$CP_URL" ]] || { echo "x CLOVEERP_LIVE_DATABASE_URL is not set; the register cannot be reached." >&2; exit 2; }

q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }

is_code() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]]; }
is_name() { [[ "$1" =~ ^cloveerp:(deployment:[a-z0-9]{20}:(db_url|service_key)|provision:[a-z0-9-]{3,63}:db_pass)$ ]]; }

cmd="${1:-}"; shift || true
case "$cmd" in
  row)
    code="${1:?usage: fleet_register.sh row <code>}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    q -v code="$code" -c "select 'status=' || d.status || E'\nref=' || coalesce(d.project_ref, '') || E'\napi_url=' || coalesce(d.api_url, '') from erp_meta.deployment d where d.code = :'code'"
    ;;
  event)
    code="${1:?usage: fleet_register.sh event <code> <phase> <status> [detail]}"
    phase="${2:?phase}"; status="${3:?status}"; detail="${4:-}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    q -v code="$code" -v phase="$phase" -v status="$status" -v detail="$detail" -v run="${GITHUB_RUN_ID:-}" \
      -c "select erp_meta.record_deployment_event(:'code', :'phase', :'status', nullif(:'detail', ''), nullif(:'run', ''));" > /dev/null
    echo "register: ${code} ${phase} ${status}${detail:+: ${detail}}"
    ;;
  project)
    code="${1:?usage: fleet_register.sh project <code> <ref> <api_url> <publishable_key> [region] [size]}"
    ref="${2:?ref}"; api_url="${3:-}"; key="${4:-}"; region="${5:-}"; size="${6:-}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    [[ "$ref" =~ ^[a-z0-9]{20}$ ]] || { echo "x '$ref' is not a project ref" >&2; exit 2; }
    q -v code="$code" -v ref="$ref" -v api_url="$api_url" -v key="$key" -v region="$region" -v size="$size" \
      -c "select erp_meta.register_deployment_project(:'code', :'ref', nullif(:'api_url', ''), nullif(:'key', ''), nullif(:'region', ''), nullif(:'size', ''));"
    ;;
  built)
    code="${1:?usage: fleet_register.sh built <code>}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    q -v code="$code" -c "select erp_meta.deployment_built(:'code');"
    ;;
  vault-put)
    name="${1:?usage: fleet_register.sh vault-put <name> < value}"
    is_name "$name" || { echo "x '$name' is not a name this register keeps" >&2; exit 2; }
    value="$(cat)"
    [[ -n "$value" ]] || { echo "x nothing to put in the vault under $name" >&2; exit 2; }
    # Upsert: vault.secrets has no unique name, so the entry is looked up by
    # name and updated, or created. The value travels as a psql variable,
    # which psql quotes; it is never interpolated into the statement text.
    q -v name="$name" -v value="$value" <<'SQL' > /dev/null
do $v$
declare v_id uuid;
begin
  select s.id into v_id from vault.secrets s where s.name = :'name' order by s.created_at limit 1;
  if v_id is null then
    perform vault.create_secret(:'value', :'name', 'Kept by the fleet workflows for one client deployment (20261011020000). Never printed.');
  else
    perform vault.update_secret(v_id, :'value');
  end if;
end
$v$;
SQL
    echo "vault: ${name} kept"
    ;;
  vault-get)
    name="${1:?usage: fleet_register.sh vault-get <name>}"
    is_name "$name" || { echo "x '$name' is not a name this register keeps" >&2; exit 2; }
    # The value alone: a caller captures this output, and a mask command
    # printed here would be captured with it. The caller masks.
    q -v name="$name" -c "select s.decrypted_secret from vault.decrypted_secrets s where s.name = :'name' order by s.created_at limit 1" | tr -d '\n'
    ;;
  vault-del)
    name="${1:?usage: fleet_register.sh vault-del <name>}"
    is_name "$name" || { echo "x '$name' is not a name this register keeps" >&2; exit 2; }
    q -v name="$name" -c "delete from vault.secrets s where s.name = :'name';" > /dev/null
    echo "vault: ${name} removed"
    ;;
  *)
    echo "usage: fleet_register.sh row|event|project|built|vault-put|vault-get|vault-del ..." >&2
    exit 2
    ;;
esac
