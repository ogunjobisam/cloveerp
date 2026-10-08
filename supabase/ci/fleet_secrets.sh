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
# client or for every built and live one, with a pause between clients so
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
#                         addresses confirmed, the site URL and redirects of
#                         https://<address>.<APEX>, custom SMTP through Resend.
#
#   A client's address is the register's: its code until a rename moves it
#   (fleet_rename.sh, 20261012020000), and the code never changes. Set from the
#   code after a rename, these would send its sign-in links and its emails'
#   links back to an address that only redirects.
#
#   code    a client's code, which must be built or live in the register; or
#           all, every client that is.
#   reason  why, in words; it goes on each client's row.
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane: the register and its vault
#   SUPABASE_ACCESS_TOKEN       the Management API (provision_project.sh)
#   RESEND_API_KEY              set_function_secrets and patch_auth
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
refuse() { say_error "$*"; exit 2; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }

action="${1:-}"; code="${2:-}"; reason="${3:-}"
case "$action" in
  rotate_db_password|set_function_secrets|patch_auth) ;;
  *) refuse "usage: fleet_secrets.sh rotate_db_password|set_function_secrets|patch_auth <code|all> <reason>; '${action}' is not one of them, and nothing was changed." ;;
esac
if [[ "$code" != all ]] && ! [[ "$code" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  refuse "'${code}' is neither a client's code nor all; nothing was changed."
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
esac
for n in "$PAUSE_SECONDS" "$PROVE_ATTEMPTS" "$PROVE_WAIT"; do
  [[ "$n" =~ ^[0-9]+$ ]] || refuse "PAUSE_SECONDS, PROVE_ATTEMPTS and PROVE_WAIT must be whole numbers; nothing was changed."
done
[[ "$PROVE_ATTEMPTS" -ge 1 ]] || refuse "PROVE_ATTEMPTS must be 1 or more; nothing was changed."

# Which clients: built or live, with a project, and where each is served.
# On standard input, not -c: psql substitutes :'code' only there. The address
# through to_jsonb: a control plane before 20261012020000 has no such column,
# and every client was served at its code.
if ! rows=$($PSQL_CMD "$CLOVEERP_LIVE_DATABASE_URL" -v ON_ERROR_STOP=1 -X -q -tA -F '|' -v code="$code" <<'SQL'
select d.code, d.status, coalesce(d.project_ref, ''), coalesce(to_jsonb(d) ->> 'address', d.code)
  from erp_meta.deployment d
 where (:'code' = 'all' and d.status in ('built', 'live') and d.project_ref is not null)
    or d.code = :'code'
 order by d.code;
SQL
); then
  refuse "the register could not be read, so nothing was changed."
fi
codes=(); refs=(); addrs=()
while IFS='|' read -r c s r a; do
  [[ -n "$c" ]] || continue
  a="${a:-$c}"
  if [[ "$s" != built && "$s" != live ]]; then
    refuse "${c} is ${s}, not built or live, so its secrets are not this workflow's to change; nothing was changed."
  fi
  [[ "$r" =~ ^[a-z0-9]{20}$ ]] || refuse "${c} has no project ref in the register ('${r}'); nothing was changed."
  [[ "$a" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || refuse "${c}'s address in the register ('${a}') is not one; nothing was changed."
  codes+=("$c"); refs+=("$r"); addrs+=("$a")
done <<< "$rows"
count=${#codes[@]}
if [[ "$count" -eq 0 ]]; then
  if [[ "$code" == all ]]; then
    echo "no client is built or live; nothing to do"
    summary "- ${action}: no client is built or live; nothing to do"
    exit 0
  fi
  refuse "${code} is not in the register, so it has no secrets here; nothing was changed."
fi

summary "## ${action}"
summary "Why: ${reason}"

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
  local c="$1" ref="$2" addr="$3"
  if ! "$PROV" configure "$ref" "$addr" > /dev/null; then
    FAILED_WHY="${c}'s auth settings were not all applied (the line above says which did not take); run this again for ${c} once that is mended"
    return 1
  fi
  DONE_WHAT="auth settings applied again: sign-up closed, addresses confirmed, site https://${addr}.${APEX}, SMTP through Resend; PostgREST exposes public and graphql_public only"
}

i=0
while [[ "$i" -lt "$count" ]]; do
  c="${codes[$i]}"; ref="${refs[$i]}"; addr="${addrs[$i]}"
  if [[ "$i" -gt 0 && "$PAUSE_SECONDS" -gt 0 ]]; then
    echo "a pause of ${PAUSE_SECONDS} s before ${c}, so the Management API serves the rest of the fleet too"
    $SLEEP_CMD "$PAUSE_SECONDS"
  fi
  echo "${c} (${ref}): ${action}"
  FAILED_WHY=""; DONE_WHAT=""
  if "$action" "$c" "$ref" "$addr"; then
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
echo "${action}: ${count} client(s) done"
