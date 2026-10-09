#!/usr/bin/env bash
#
# A client deployment's secrets, changed from a workflow
# (.github/workflows/fleet_secrets.yml), one client at a time.
#
# One Supabase project per client (the owner's decision of 7 October): each
# has a database password only the control plane's vault knows, Edge
# Function secrets of its own, and auth settings of its own. They change for
# a handful of reasons (a key revoked at the email provider, an address
# renamed, a password that may have been seen), and every one of them, done by
# hand in a dashboard, is one client among twenty done slightly differently,
# or a password pasted somewhere. So each is a subcommand here, run for one
# client or for every one whose project is up (built, live, suspended or
# retiring: a suspended client's project runs on, and a retiring one's until
# it is purged, and each still needs a key revoked at Resend replaced or a
# password that may have been seen changed), with a pause between clients so
# that the Management API's sixty calls a minute stay with the rest of the
# fleet, stopping at the first client that fails so that one mistake is not
# made twenty times. Each client's row in the register says what was done
# (an event of phase note), and nothing secret is ever printed.
#
# Usage: fleet_secrets.sh <action> <code|all> <reason>
#
#   rotate_db_password    a new database password for the project: generated
#                         here, kept in the control plane's vault before the
#                         project is given it (cloveerp:provision:<code>:db_pass,
#                         the name a build keeps it under), set through the
#                         Management API, composed into the session-pooler URL
#                         and stored as cloveerp:deployment:<ref>:db_url, which
#                         release.yml reads; then that stored URL is read back
#                         and must answer select 1. The project's Edge
#                         Functions are given the new password by Supabase
#                         itself (SUPABASE_DB_URL follows a reset since
#                         November 2023). A rotation that stops part-way is
#                         mended by running it again: setting a password needs
#                         only the access token, never the old password.
#   set_function_secrets  RESEND_API_KEY, CLOVEERP_APP_URL (the deployment's
#                         origin, https://<address>.<APEX>) and
#                         CLOVEERP_INVITE_FROM, as a build sets them.
#   patch_auth            the auth and PostgREST settings a build applies
#                         (provision_project.sh configure): sign-up closed,
#                         addresses confirmed, the site URL of
#                         https://<address>.<APEX>, redirects to it and to
#                         every address the client was moved from (each held
#                         for it for good), custom SMTP through Resend.
#   resend_webhook        the project's own endpoint at Resend, which tells it
#                         what became of the mail it sent: made, or reused
#                         when it is right, or mended, or made again
#                         (provision_project.sh resend-webhook create, only
#                         for a database released 20261012050000, which
#                         records only its own mail, and asked so first; its
#                         id and signing secret kept in the control plane's
#                         vault before the project is given the secret), then
#                         proved by one signed event its function must take
#                         and record nothing of (resend-webhook prove). An
#                         endpoint that does not prove, however it fails, is
#                         deleted again at once with its vault entry, red: it
#                         is not left to run against a database that may keep
#                         the whole account's events. A client's checklist
#                         step is then ticked by the build (fleet_register.sh
#                         checklist-by-build), once the control plane has the
#                         routine, and unticked whenever its endpoint is
#                         deleted or none is left that its function takes.
#                         For a client built, live or suspended, or all of
#                         them (a client retiring is left out: its endpoint is
#                         deleted, not made); and for demonstration and
#                         control, the demonstration's project (DEMO_REF,
#                         its database CLOVEERP_DEMO_DATABASE_URL) and the
#                         control plane's (PRODUCTION_REF), which are in no
#                         register and have no checklist.
#   resend_webhook_delete a retiring or retired client's endpoint deleted at
#                         Resend, and its entry in the vault (resend-webhook
#                         delete), and its checklist step unticked. One
#                         client at a time, never all.
#
#   Both need RESEND_ADMIN_API_KEY, a full-access Resend key the workflows
#   alone hold. Without it they leave a notice, change nothing, and are not
#   red: the checklist keeps the step for the owner.
#
#   A client's address is the register's: its code until a rename moves it
#   (fleet_rename.sh, 20261012030000), and the code never changes. Set from the
#   code after a rename, these would send its sign-in links and its emails'
#   links back to an address that only redirects. And it is read again from
#   the register just before each client is changed, not once when the run
#   began: a rename that finished in between (fleet_rename.yml, which waits
#   for this workflow as this one waits for it) would otherwise be undone.
#
#   code    a client's code, which must be built, live, suspended or retiring
#           in the register (not retiring for resend_webhook; retiring or
#           retired for resend_webhook_delete); or all, every client that is
#           built, live, suspended or retiring (not retiring for
#           resend_webhook); or, for resend_webhook, demonstration or control.
#   reason  why, in words; it goes on each client's row.
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane: the register and its vault
#   SUPABASE_ACCESS_TOKEN       the Management API (provision_project.sh)
#   RESEND_API_KEY              set_function_secrets and patch_auth
#   RESEND_ADMIN_API_KEY        resend_webhook and resend_webhook_delete
#   DEMO_REF, PRODUCTION_REF    the projects resend_webhook demonstration and
#                               control are for
#   CLOVEERP_DEMO_DATABASE_URL  the demonstration's database, asked whether it
#                               keeps only its own mail before its endpoint is
#                               made (provision_project.sh resend-webhook)
#   APEX                        default cloveerp.com
#   MAIL_FROM                   patch_auth: the sender of sign-in links
#   INVITE_FROM                 set_function_secrets; default "Clove ERP <MAIL_FROM>"
#   PAUSE_SECONDS               between clients (default 20)
#   PROVE_ATTEMPTS, PROVE_WAIT  the new connection is tried this often, this
#                               many seconds apart (default 12 and 10): the
#                               pooler can take a moment to learn a password
#   PSQL, CURL, API, MAPI_*     the commands and settings the rehearsal
#                               (fleet_secrets_rehearsal.sh) stands in for
#   SLEEP                       the sleep command (default sleep)
#
# Generated values are masked (::add-mask::) before anything else is printed
# when run by GitHub Actions; elsewhere they are not printed at all.
#
# bash 3.2 and later: the rehearsal runs on a Mac as well as on a runner.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG="$HERE/fleet_register.sh"
PROV="$HERE/provision_project.sh"
PSQL_CMD="${PSQL:-psql}"
SLEEP_CMD="${SLEEP:-sleep}"
APEX="${APEX:-cloveerp.com}"
PAUSE_SECONDS="${PAUSE_SECONDS:-20}"
PROVE_ATTEMPTS="${PROVE_ATTEMPTS:-12}"
PROVE_WAIT="${PROVE_WAIT:-10}"

in_actions() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }
mask() { if in_actions; then echo "::add-mask::$1"; fi; }
# say_error <words>: what was not done, as an annotation on a runner.
say_error() { if in_actions; then echo "::error::$*"; else echo "x $*" >&2; fi; }
# say_notice <words>: what was not done, and is not a failure.
say_notice() { if in_actions; then echo "::notice::$*"; else echo "! $*" >&2; fi; }
refuse() { say_error "$*"; exit 2; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }

action="${1:-}"; code="${2:-}"; reason="${3:-}"
case "$action" in
  rotate_db_password|set_function_secrets|patch_auth|resend_webhook|resend_webhook_delete) ;;
  *) refuse "usage: fleet_secrets.sh rotate_db_password|set_function_secrets|patch_auth|resend_webhook|resend_webhook_delete <code|all> <reason>; '${action}' is not one of them, and nothing was changed." ;;
esac
if [[ "$code" != all ]] && ! [[ "$code" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  refuse "'${code}' is neither a client's code nor all; nothing was changed."
fi
if [[ "$action" == resend_webhook_delete && ( "$code" == all || "$code" == demonstration || "$code" == control ) ]]; then
  refuse "resend_webhook_delete is for one retiring or retired client at a time, named by its code, not ${code}; nothing was changed."
fi
reason="$(printf '%s' "$reason" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
[[ ${#reason} -ge 10 ]] || refuse "say why, in ten characters or more (it goes on each client's row); nothing was changed."

# Everything each client will need, before the first is touched: a run that
# stops at its third client for want of a setting is three clients changed
# and seventeen not.
[[ -n "${CLOVEERP_LIVE_DATABASE_URL:-}" ]] || refuse "CLOVEERP_LIVE_DATABASE_URL is not set, so the register cannot say which clients there are; nothing was changed."
[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] || refuse "SUPABASE_ACCESS_TOKEN is not set, so no project can be changed; nothing was changed."
[[ "$APEX" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || refuse "APEX ('${APEX}') is not a domain; nothing was changed."
case "$action" in
  set_function_secrets)
    [[ -n "${RESEND_API_KEY:-}" ]] || refuse "RESEND_API_KEY is not set, so the functions' email key cannot be set; nothing was changed."
    if [[ -z "${INVITE_FROM:-}" ]]; then
      [[ "${MAIL_FROM:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || refuse "neither INVITE_FROM nor MAIL_FROM is set, so invitations would have no sender; nothing was changed."
      INVITE_FROM="Clove ERP <${MAIL_FROM}>"
    fi ;;
  patch_auth)
    [[ -n "${RESEND_API_KEY:-}" ]] || refuse "RESEND_API_KEY is not set, so the projects' SMTP cannot be set; nothing was changed."
    [[ "${MAIL_FROM:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || refuse "MAIL_FROM is not an email address, so sign-in links would have no sender; nothing was changed." ;;
  resend_webhook|resend_webhook_delete)
    # Not red: the endpoint is a step of the checklist until the key exists.
    if [[ -z "${RESEND_ADMIN_API_KEY:-}" ]]; then
      say_notice "RESEND_ADMIN_API_KEY is not set, so no endpoint at Resend can be made or deleted, and nothing was changed: each client's checklist keeps the step for the owner. Add it as a repository secret (a full-access Resend key, used only by the workflows) and run this again."
      summary "- ${action} for ${code}: RESEND_ADMIN_API_KEY is not set, so nothing was changed"
      exit 0
    fi ;;
esac
for n in "$PAUSE_SECONDS" "$PROVE_ATTEMPTS" "$PROVE_WAIT"; do
  [[ "$n" =~ ^[0-9]+$ ]] || refuse "PAUSE_SECONDS, PROVE_ATTEMPTS and PROVE_WAIT must be whole numbers; nothing was changed."
done
[[ "$PROVE_ATTEMPTS" -ge 1 ]] || refuse "PROVE_ATTEMPTS must be 1 or more; nothing was changed."

# untick <code>: a client's checklist step for the webhook unticked by the
# build, because its endpoint was deleted or none is left that its function
# takes the events of: the Fleet view never says "set by the build" of an
# endpoint that is not there. Never fails the run; UNTICKED says what came
# of it, to be added to what is said.
untick() {
  local rc
  if "$REG" checklist-by-build "$1" resend_webhook false > /dev/null; then rc=0; else rc=$?; fi
  case "$rc" in
    0) UNTICKED="the checklist's step unticked" ;;
    5) UNTICKED="the checklist's step left as it was: the control plane has no erp_meta.deployment_checklist_by_build yet" ;;
    *) UNTICKED="the checklist's step could not be unticked (the line above says why)" ;;
  esac
}

# make_webhook <name> <ref> [code]: the project's endpoint at Resend made,
# reused, mended or made again, and proved by a signed event its function
# must take and record nothing of (provision_project.sh resend-webhook
# create, then prove). DONE_WHAT says what was done; FAILED_WHY what was
# not. Create asks the project's database first and makes nothing for one
# that has not been released 20261012050000, which would keep every event of
# the account, other projects' recipients among them. An endpoint that then
# does not prove, whatever the reason (a database that records the proof,
# a function that refuses it, or one that cannot be reached), is deleted
# again at once with its vault entry: it is never left running unproved.
# With a client's code, its checklist step is unticked whenever an endpoint
# is deleted or none is left that its function takes.
make_webhook() {
  local name="$1" ref="$2" client="${3:-}" out verdict id rc gone
  UNTICKED=""
  if out=$("$PROV" resend-webhook "$ref" create); then rc=0; else rc=$?; fi
  case "$rc" in
    0) ;;
    6)
      FAILED_WHY="${name}'s database has not been released 20261012050000, so it would keep other projects' recipients: no endpoint was made for it, and nothing was asked of Resend. Release to it first (deploy.yml), then run this again for ${name}"
      return 1 ;;
    3)
      if [[ -n "$client" ]]; then untick "$client"; fi
      FAILED_WHY="${name}'s endpoint at Resend was left part-way, with none its function takes the events of (the line above says why)${UNTICKED:+; ${UNTICKED}}; run this again for ${name}: it keeps what is right and makes again what is not"
      return 1 ;;
    *)
      FAILED_WHY="${name}'s endpoint at Resend was not made or found right, and nothing was changed (the line above says why); run this again for ${name}: it keeps what is right and makes again what is not"
      return 1 ;;
  esac
  verdict=$(sed -n 's/^resend-webhook=//p' <<< "$out")
  id=$(sed -n 's/^id=//p' <<< "$out")
  if "$PROV" resend-webhook "$ref" prove > /dev/null; then rc=0; else rc=$?; fi
  if [[ "$rc" -ne 0 ]]; then
    if "$PROV" resend-webhook "$ref" delete > /dev/null; then
      gone="so its endpoint ${id} was deleted again at Resend, with its entry in the vault"
    else
      gone="and its endpoint ${id} could not be deleted again at Resend (the line above says why): run this again, or delete it in Resend's dashboard"
    fi
    if [[ -n "$client" ]]; then untick "$client"; fi
    if [[ "$rc" -eq 4 ]]; then
      FAILED_WHY="${name}'s database recorded the signed event, which matches no mail it sent, so it would keep other projects' recipients, ${gone}${UNTICKED:+; ${UNTICKED}}. Release to it first (deploy.yml), then run this again for ${name}"
    else
      FAILED_WHY="${name}'s endpoint at Resend was ${verdict} (${id}), and its function did not take a signed event as it should (what it answered is said above), ${gone}${UNTICKED:+; ${UNTICKED}}. Run this again for ${name}"
    fi
    return 1
  fi
  DONE_WHAT="the email provider's webhook ${verdict} (${id}) and proved: a signed event reached its function, which recorded nothing"
}

# The demonstration and the control plane, which are in no register: each
# by the ref the workflow gives it, and nothing written on a row.
if [[ "$action" == resend_webhook && ( "$code" == demonstration || "$code" == control ) ]]; then
  if [[ "$code" == demonstration ]]; then
    target="${DEMO_REF:-}"; known_as="CLOVEERP_DEMO_PROJECT_REF"
  else
    target="${PRODUCTION_REF:-}"; known_as="CLOVEERP_PROJECT_REF"
  fi
  [[ "$target" =~ ^[a-z0-9]{20}$ ]] || refuse "the ${code}'s project ref (${known_as}, '${target}') is not one; nothing was changed."
  summary "## ${action}"
  summary "Why: ${reason}"
  echo "${code} (${target}): ${action}"
  FAILED_WHY=""; DONE_WHAT=""
  if make_webhook "$code" "$target"; then
    echo "${code}: ${DONE_WHAT}"
    summary "- ${code}: ${DONE_WHAT}"
    exit 0
  fi
  say_error "${code}: ${FAILED_WHY}."
  summary "- ${code}: FAILED: ${FAILED_WHY}"
  exit 1
fi

# Which clients: those whose project is up, with a project, where each is
# served, and the addresses each was moved from and holds. On standard input,
# not -c: psql substitutes :'code' only there. The address through to_jsonb:
# a control plane before 20261012030000 has no such column, and every client
# was served at its code; nor does it hold any address, and is not asked.
if ! held_known=$($PSQL_CMD "$CLOVEERP_LIVE_DATABASE_URL" -v ON_ERROR_STOP=1 -X -q -tA <<'SQL'
-- fleet: cp-held-known
select (to_regclass('erp_meta.deployment_previous_address') is not null)::text;
SQL
); then
  refuse "the register could not be read, so nothing was changed."
fi
# register_rows <code|all>: code|status|ref|address|held addresses (spaced).
register_rows() {
  if [[ "$held_known" == true ]]; then
    $PSQL_CMD "$CLOVEERP_LIVE_DATABASE_URL" -v ON_ERROR_STOP=1 -X -q -tA -F '|' -v code="$1" <<'SQL'
-- fleet: cp-rows
select d.code, case when d.status = 'retiring' and d.built_at is null then 'retiring, never built' else d.status end, coalesce(d.project_ref, ''), coalesce(to_jsonb(d) ->> 'address', d.code),
       coalesce((select string_agg(p.address, ' ' order by p.moved_at, p.address)
                   from erp_meta.deployment_previous_address p where p.code = d.code), '')
  from erp_meta.deployment d
 where (:'code' = 'all' and d.status in ('built', 'live', 'suspended', 'retiring') and d.project_ref is not null
        and (d.status <> 'retiring' or d.built_at is not null))
    or d.code = :'code'
 order by d.code;
SQL
  else
    $PSQL_CMD "$CLOVEERP_LIVE_DATABASE_URL" -v ON_ERROR_STOP=1 -X -q -tA -F '|' -v code="$1" <<'SQL'
-- fleet: cp-rows
select d.code, case when d.status = 'retiring' and d.built_at is null then 'retiring, never built' else d.status end, coalesce(d.project_ref, ''), coalesce(to_jsonb(d) ->> 'address', d.code), ''
  from erp_meta.deployment d
 where (:'code' = 'all' and d.status in ('built', 'live', 'suspended', 'retiring') and d.project_ref is not null
        and (d.status <> 'retiring' or d.built_at is not null))
    or d.code = :'code'
 order by d.code;
SQL
  fi
}
is_up() { case "$1" in built|live|suspended|retiring) return 0 ;; *) return 1 ;; esac; }
# eligible <status>: whether this action is for a client in it. A webhook is
# deleted only for a client that is going: retiring (built or not) or
# retired, whose project may already be gone while its endpoint is not; and
# made only for one that is staying (built, live or suspended): a retiring
# client's checklist is not ticked, and its endpoint would only be deleted.
eligible() {
  case "$action" in
    resend_webhook_delete) case "$1" in retiring*|retired) return 0 ;; *) return 1 ;; esac ;;
    resend_webhook) case "$1" in built|live|suspended) return 0 ;; *) return 1 ;; esac ;;
  esac
  is_up "$1"
}
is_address() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; }
if ! rows=$(register_rows "$code"); then
  refuse "the register could not be read, so nothing was changed."
fi
codes=(); refs=(); left_out=""
while IFS='|' read -r c s r a h; do
  [[ -n "$c" ]] || continue
  a="${a:-$c}"
  if [[ "$action" == resend_webhook_delete ]] && ! eligible "$s"; then
    refuse "${c} is ${s}, so its webhook is not deleted: resend_webhook_delete is for a client retiring or retired; nothing was changed."
  fi
  if [[ "$action" == resend_webhook && "$s" == retiring* ]]; then
    if [[ "$code" == all ]]; then
      left_out="${left_out} ${c}"
      continue
    fi
    refuse "${c} is ${s}, so no endpoint is made for it: a client going has its endpoint deleted (resend_webhook_delete), not made; nothing was changed."
  fi
  if ! eligible "$s"; then
    refuse "${c} is ${s}, not built, live, suspended or retiring, so it has no project for this workflow to change; nothing was changed."
  fi
  [[ "$r" =~ ^[a-z0-9]{20}$ ]] || refuse "${c} has no project ref in the register ('${r}'); nothing was changed."
  is_address "$a" || refuse "${c}'s address in the register ('${a}') is not one; nothing was changed."
  for x in $h; do
    is_address "$x" || refuse "the register holds '${x}' for ${c}, which is not an address; nothing was changed."
  done
  codes+=("$c"); refs+=("$r")
done <<< "$rows"
count=${#codes[@]}
if [[ -n "$left_out" ]]; then
  echo "left out, because they are retiring (resend_webhook_delete deletes their endpoints):${left_out}"
fi
if [[ "$count" -eq 0 ]]; then
  if [[ "$code" == all ]]; then
    echo "no client is built, live, suspended or retiring${left_out:+ but those retiring}; nothing to do"
    summary "- ${action}: no client is built, live, suspended or retiring${left_out:+ but those retiring (${left_out# })}; nothing to do"
    exit 0
  fi
  refuse "${code} is not in the register, so it has no secrets here; nothing was changed."
fi

summary "## ${action}"
summary "Why: ${reason}"
if [[ -n "$left_out" ]]; then
  summary "- left out, because they are retiring:${left_out}"
fi

# note <code> <status> <detail>: one line on the client's row; never fails
# the run (the change itself is what matters, and is said either way).
note() {
  "$REG" event "$1" note "$2" "$3" > /dev/null 2>&1 ||
    echo "! ${1}'s row in the register could not be told: ${3}" >&2
}

# redact <text> <secret>: the text with the secret taken out.
redact() {
  local text="$1" secret="$2"
  if [[ -n "$secret" ]]; then text="${text//${secret}/[hidden]}"; fi
  printf '%s' "$text"
}

rotate_db_password() {
  local c="$1" ref="$2" pool host port user dbname pass staging url_name url got attempt answer err=""
  staging="cloveerp:provision:${c}:db_pass"
  url_name="cloveerp:deployment:${ref}:db_url"

  # The pooler first: read before anything changes.
  if ! pool=$("$PROV" pooler "$ref"); then
    FAILED_WHY="the session pooler of ${ref} could not be read, so nothing was changed on ${c}"
    return 1
  fi
  host=$(sed -n 's/^host=//p' <<< "$pool"); port=$(sed -n 's/^port=//p' <<< "$pool")
  user=$(sed -n 's/^user=//p' <<< "$pool"); dbname=$(sed -n 's/^dbname=//p' <<< "$pool")
  if [[ -z "$host" || -z "$port" || -z "$user" || -z "$dbname" ]]; then
    FAILED_WHY="the session pooler of ${ref} did not say its host, port, user and database, so nothing was changed on ${c}"
    return 1
  fi

  # Forty letters and digits: no percent-encoding in the URL, as the build's.
  pass=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
  if [[ ${#pass} -ne 40 ]]; then
    FAILED_WHY="no password could be generated, so nothing was changed on ${c}"
    return 1
  fi
  mask "$pass"

  # Kept before the project is given it, so the password the project has is
  # never held only by this run.
  if ! printf '%s' "$pass" | "$REG" vault-put "$staging" > /dev/null; then
    FAILED_WHY="the new password could not be kept in the control plane's vault, so nothing was changed on ${c}"
    return 1
  fi
  if ! DB_PASS="$pass" "$PROV" password "$ref" > /dev/null; then
    FAILED_WHY="the Management API did not take the new password for ${ref}. The project may have its old password or the new one, which the vault keeps as ${staging}; the connection releases read (${url_name}) is unchanged, and works if the old one stands. Run the rotation again for ${c}: it sets a fresh password either way"
    return 1
  fi

  url="postgresql://${user}:${pass}@${host}:${port}/${dbname}"
  mask "$url"
  if ! printf '%s' "$url" | "$REG" vault-put "$url_name" > /dev/null; then
    FAILED_WHY="${ref} has a new database password, and the connection made from it could not be stored as ${url_name}, so releases to ${c} cannot connect until it is. The password is kept as ${staging}. Run the rotation again for ${c}"
    return 1
  fi
  "$REG" vault-del "$staging" > /dev/null || echo "! ${staging} could not be removed from the vault; it holds the password ${c} now has, and the next rotation or the retirement of ${c} removes it" >&2

  # What releases will read, read back, and asked to answer.
  got=$("$REG" vault-get "$url_name" || true)
  if [[ -n "$got" ]]; then mask "$got"; fi
  if [[ "$got" != "$url" ]]; then
    FAILED_WHY="${ref} has a new database password and ${url_name} does not read back as the connection stored for it, so releases to ${c} may not connect. Run the rotation again for ${c}"
    return 1
  fi
  attempt=1
  while :; do
    if answer=$(PGCONNECT_TIMEOUT=15 $PSQL_CMD "$got" -v ON_ERROR_STOP=1 -X -q -tAc 'select 1' 2>&1) && [[ "$answer" == 1 ]]; then
      break
    fi
    err=$(redact "$(printf '%s' "$answer" | head -n 3 | tr '\n' ' ')" "$pass")
    if [[ "$attempt" -ge "$PROVE_ATTEMPTS" ]]; then
      FAILED_WHY="${ref} has a new database password and ${url_name} holds its connection, and that connection did not answer in ${PROVE_ATTEMPTS} attempt(s): ${err}. Releases to ${c} fail until it does: run the rotation again for ${c}, and if that fails too, look at the project's database settings in the dashboard"
      return 1
    fi
    echo "! ${c}: the new connection did not answer on attempt ${attempt} of ${PROVE_ATTEMPTS} (${err}); asking again in ${PROVE_WAIT} s" >&2
    $SLEEP_CMD "$PROVE_WAIT"
    attempt=$((attempt + 1))
  done
  DONE_WHAT="database password rotated; the connection in the vault was replaced and answered"
}

set_function_secrets() {
  local c="$1" ref="$2" addr="$3" origin
  origin="https://${addr}.${APEX}"
  if ! "$PROV" secrets "$ref" "RESEND_API_KEY=${RESEND_API_KEY}" "CLOVEERP_APP_URL=${origin}" "CLOVEERP_INVITE_FROM=${INVITE_FROM}" > /dev/null; then
    FAILED_WHY="the Management API did not take ${c}'s function secrets, so they are as they were"
    return 1
  fi
  DONE_WHAT="function secrets set: RESEND_API_KEY, CLOVEERP_APP_URL (${origin}) and CLOVEERP_INVITE_FROM"
}

patch_auth() {
  local c="$1" ref="$2" addr="$3" held="$4" redirects
  if ! ALSO_ALLOW="$held" "$PROV" configure "$ref" "$addr" > /dev/null; then
    FAILED_WHY="${c}'s auth settings were not all applied (the line above says which did not take); run this again for ${c} once that is mended"
    return 1
  fi
  redirects="redirects to it"
  if [[ -n "$held" ]]; then redirects="redirects to it and to the addresses held for it ($(printf '%s' "$held" | sed 's/ /, /g'))"; fi
  DONE_WHAT="auth settings applied again: sign-up closed, addresses confirmed, site https://${addr}.${APEX}, ${redirects}, SMTP through Resend; PostgREST exposes public and graphql_public only"
}

resend_webhook() {
  local c="$1" ref="$2" rc
  make_webhook "$c" "$ref" "$c" || return 1
  # The checklist's step, ticked as the build ticks it. Not ticked is not a
  # failure: the endpoint is made and proved either way, and the step stays
  # on the checklist for the owner.
  if "$REG" checklist-by-build "$c" resend_webhook > /dev/null; then rc=0; else rc=$?; fi
  case "$rc" in
    0) DONE_WHAT="${DONE_WHAT}; the checklist's step ticked by the build" ;;
    5) DONE_WHAT="${DONE_WHAT}; the checklist keeps the step for the owner until the control plane has erp_meta.deployment_checklist_by_build" ;;
    *) DONE_WHAT="${DONE_WHAT}; the checklist's step could not be ticked (the line above says why), so it stays for the owner" ;;
  esac
}

resend_webhook_delete() {
  local c="$1" ref="$2" out
  UNTICKED=""
  if ! out=$("$PROV" resend-webhook "$ref" delete); then
    untick "$c"
    FAILED_WHY="${c}'s endpoint at Resend was not all deleted (the line above says what was left); the vault keeps it until it is, so run this again for ${c}; ${UNTICKED}"
    return 1
  fi
  untick "$c"
  DONE_WHAT="the email provider's webhook deleted ($(sed -n 's/^deleted=//p' <<< "$out") endpoint(s) at Resend), and its entry in the control plane's vault; ${UNTICKED}"
}

skipped=0
i=0
while [[ "$i" -lt "$count" ]]; do
  c="${codes[$i]}"; ref="${refs[$i]}"
  if [[ "$i" -gt 0 && "$PAUSE_SECONDS" -gt 0 ]]; then
    echo "a pause of ${PAUSE_SECONDS} s before ${c}, so the Management API serves the rest of the fleet too"
    $SLEEP_CMD "$PAUSE_SECONDS"
  fi
  echo "${c} (${ref}): ${action}"
  FAILED_WHY=""; DONE_WHAT=""
  # Where it is served now, and what it holds, read just before it is
  # changed: not what the register said when this run began.
  now=""
  if ! now=$(register_rows "$c"); then
    FAILED_WHY="the register could not be read again just before ${c} was changed, so nothing was changed on ${c}"
  else
    IFS='|' read -r _ s r addr held <<< "$(printf '%s\n' "$now" | head -n 1)"
    addr="${addr:-$c}"
    if [[ -z "$s" ]] || ! eligible "$s"; then
      echo "${c} is ${s:-no longer in the register} now, so it was left alone"
      summary "- ${c}: ${s:-no longer in the register} by the time its turn came; left alone"
      skipped=$((skipped + 1))
      i=$((i + 1))
      continue
    elif [[ "$r" != "$ref" ]]; then
      FAILED_WHY="the register now gives ${c} the project '${r}', not ${ref} as when this run began, so nothing was changed on ${c}"
    elif ! is_address "$addr"; then
      FAILED_WHY="${c}'s address in the register ('${addr}') is not one, so nothing was changed on ${c}"
    else
      for x in $held; do
        if ! is_address "$x"; then FAILED_WHY="the register holds '${x}' for ${c}, which is not an address, so nothing was changed on ${c}"; fi
      done
    fi
  fi
  if [[ -z "$FAILED_WHY" ]] && "$action" "$c" "$ref" "$addr" "$held"; then
    note "$c" done "${DONE_WHAT} (fleet_secrets.yml: ${reason})"
    echo "${c}: ${DONE_WHAT}"
    summary "- ${c}: ${DONE_WHAT}"
  else
    note "$c" failed "${action} stopped: ${FAILED_WHY} (fleet_secrets.yml: ${reason})"
    untouched=""
    j=$((i + 1))
    while [[ "$j" -lt "$count" ]]; do untouched="${untouched} ${codes[$j]}"; j=$((j + 1)); done
    say_error "${c}: ${FAILED_WHY}.${untouched:+ Not touched, because ${c} failed first:${untouched}.}"
    summary "- ${c}: FAILED: ${FAILED_WHY}"
    [[ -z "$untouched" ]] || summary "- not touched:${untouched}"
    exit 1
  fi
  i=$((i + 1))
done
if [[ "$skipped" -gt 0 ]]; then
  echo "${action}: $((count - skipped)) client(s) done, ${skipped} left alone because the register no longer has them up"
else
  echo "${action}: ${count} client(s) done"
fi
