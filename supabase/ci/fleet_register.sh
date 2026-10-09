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
# runs the same ones.
#
# Every value reaches SQL as a psql variable (-v), which psql quotes, and the
# statement is fed on standard input: psql substitutes :'name' only there,
# never inside a -c string, which the first release after 20261011010000
# learned with "syntax error at or near :". Nothing here interpolates a value
# into statement text.
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
#   checklist-by-build <code> <item> [true|false]
#                                      a step of the client's checklist ticked
#                                      (true, the default) or unticked (false)
#                                      by the build itself, as the console
#                                      shows it ("set by the build"), through
#                                      erp_meta.deployment_checklist_by_build
#                                      (20261012050000). Exit 5, changing
#                                      nothing, when the control plane has no
#                                      such routine yet (the step stays the
#                                      owner's); 1 when it could not be asked
#                                      or refused
#
# Names in the vault: cloveerp:deployment:<ref>:db_url,
# cloveerp:deployment:<ref>:service_key,
# cloveerp:deployment:<ref>:resend_webhook (the project's endpoint at Resend,
# {id, secret}: provision_project.sh resend-webhook), and
# cloveerp:provision:<code>:db_pass while a project is being made and its ref
# is not yet known.
set -euo pipefail

CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
[[ -n "$CP_URL" ]] || { echo "x CLOVEERP_LIVE_DATABASE_URL is not set; the register cannot be reached." >&2; exit 2; }

# q [-v name=value ...] <<< "statement": the statement on stdin, so :'name' is
# substituted; one answer per row, tab-separated, nothing else printed.
q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }

is_code() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]]; }
is_name() { [[ "$1" =~ ^cloveerp:(deployment:[a-z0-9]{20}:(db_url|service_key|resend_webhook)|provision:[a-z0-9-]{3,63}:db_pass)$ ]]; }

cmd="${1:-}"; shift || true
case "$cmd" in
  row)
    code="${1:?usage: fleet_register.sh row <code>}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    q -v code="$code" <<'SQL'
-- fleet: cp-row
select 'status=' || d.status || E'\nref=' || coalesce(d.project_ref, '') || E'\napi_url=' || coalesce(d.api_url, '')
  from erp_meta.deployment d where d.code = :'code';
SQL
    ;;
  event)
    code="${1:?usage: fleet_register.sh event <code> <phase> <status> [detail]}"
    phase="${2:?phase}"; status="${3:?status}"; detail="${4:-}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    q -v code="$code" -v phase="$phase" -v status="$status" -v detail="$detail" -v run="${GITHUB_RUN_ID:-}" <<'SQL' > /dev/null
select erp_meta.record_deployment_event(:'code', :'phase', :'status', nullif(:'detail', ''), nullif(:'run', ''));
SQL
    echo "register: ${code} ${phase} ${status}${detail:+: ${detail}}"
    ;;
  project)
    code="${1:?usage: fleet_register.sh project <code> <ref> <api_url> <publishable_key> [region] [size]}"
    ref="${2:?ref}"; api_url="${3:-}"; key="${4:-}"; region="${5:-}"; size="${6:-}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    [[ "$ref" =~ ^[a-z0-9]{20}$ ]] || { echo "x '$ref' is not a project ref" >&2; exit 2; }
    q -v code="$code" -v ref="$ref" -v api_url="$api_url" -v key="$key" -v region="$region" -v size="$size" <<'SQL'
select erp_meta.register_deployment_project(:'code', :'ref', nullif(:'api_url', ''), nullif(:'key', ''), nullif(:'region', ''), nullif(:'size', ''));
SQL
    ;;
  built)
    code="${1:?usage: fleet_register.sh built <code>}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    q -v code="$code" <<'SQL'
select erp_meta.deployment_built(:'code');
SQL
    ;;
  vault-put)
    name="${1:?usage: fleet_register.sh vault-put <name> < value}"
    is_name "$name" || { echo "x '$name' is not a name this register keeps" >&2; exit 2; }
    value="$(cat)"
    [[ -n "$value" ]] || { echo "x nothing to put in the vault under $name" >&2; exit 2; }
    # Upsert, as two plain statements in one transaction: vault.secrets has
    # no unique name, so the entry is updated where it exists and created
    # where it does not. Plain statements rather than a DO block, because
    # psql does not substitute a variable inside a dollar-quoted body.
    # VERBOSITY terse: an error that points into the statement would
    # otherwise print the LINE it points at, the value substituted in it.
    q -v VERBOSITY=terse -v name="$name" -v value="$value" <<'SQL' > /dev/null
begin;
select vault.update_secret(s.id, :'value')
  from vault.secrets s where s.name = :'name';
select vault.create_secret(:'value', :'name', 'Kept by the fleet workflows for one client deployment (20261011020000). Never printed.')
 where not exists (select 1 from vault.secrets s where s.name = :'name');
commit;
SQL
    echo "vault: ${name} kept"
    ;;
  vault-get)
    name="${1:?usage: fleet_register.sh vault-get <name>}"
    is_name "$name" || { echo "x '$name' is not a name this register keeps" >&2; exit 2; }
    # The value alone: a caller captures this output, and a mask command
    # printed here would be captured with it. The caller masks.
    q -v name="$name" <<'SQL' | tr -d '\n'
select s.decrypted_secret from vault.decrypted_secrets s where s.name = :'name' order by s.created_at limit 1;
SQL
    ;;
  vault-del)
    name="${1:?usage: fleet_register.sh vault-del <name>}"
    is_name "$name" || { echo "x '$name' is not a name this register keeps" >&2; exit 2; }
    q -v name="$name" <<'SQL' > /dev/null
delete from vault.secrets s where s.name = :'name';
SQL
    echo "vault: ${name} removed"
    ;;
  checklist-by-build)
    code="${1:?usage: fleet_register.sh checklist-by-build <code> <item> [true|false]}"
    item="${2:?usage: fleet_register.sh checklist-by-build <code> <item> [true|false]}"
    done_="${3:-true}"
    is_code "$code" || { echo "x '$code' is not a code" >&2; exit 2; }
    [[ "$item" =~ ^[a-z_]{1,40}$ ]] || { echo "x '$item' is not a step of the checklist" >&2; exit 2; }
    [[ "$done_" == true || "$done_" == false ]] || { echo "x '$done_' is neither true (ticked) nor false (unticked)" >&2; exit 2; }
    # Asked first, because a control plane is released after the clients
    # (demonstration, clients, control plane): a build can run before the
    # control plane has the routine, and then the step stays the owner's.
    has=$(q -v VERBOSITY=terse <<'SQL'
-- fleet: cp-has-checklist-by-build
set statement_timeout = '30s';
select (to_regprocedure('erp_meta.deployment_checklist_by_build(text,text,boolean)') is not null)::text;
SQL
) || exit 1
    if [[ "$has" != true ]]; then
      echo "register: the control plane has no erp_meta.deployment_checklist_by_build yet, so ${item} on ${code}'s checklist stays as the owner set it"
      exit 5
    fi
    q -v VERBOSITY=terse -v code="$code" -v item="$item" -v done="$done_" <<'SQL' > /dev/null || exit 1
-- fleet: cp-checklist-by-build
set statement_timeout = '30s';
select erp_meta.deployment_checklist_by_build(:'code', :'item', (:'done')::boolean);
SQL
    if [[ "$done_" == true ]]; then
      echo "register: ${code} ${item} ticked by the build"
    else
      echo "register: ${code} ${item} unticked by the build"
    fi
    ;;
  *)
    echo "usage: fleet_register.sh row|event|project|built|vault-put|vault-get|vault-del|checklist-by-build ..." >&2
    exit 2
    ;;
esac
