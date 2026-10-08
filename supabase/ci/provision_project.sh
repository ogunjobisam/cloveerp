#!/usr/bin/env bash
#
# A client's Supabase project, made and set up through the Management API:
# the part of a deployment's build from empty
# (.github/workflows/deployment_from_empty.yml) that happens before there is
# a database to build into.
#
# One Supabase project per client, one subdomain each, was the owner's
# decision of 7 October 2026. Each client project is made the way the
# demonstration's was on 6 October, which took an afternoon of dashboard
# screens, a token scoped without the permission it needed, sign-up switched
# off on the wrong project and a connection string pasted three times
# (demo-has-its-own-project). The afternoon is this script, and every step of
# it is rehearsed against a scripted curl on every build
# (supabase/ci/provision_project_rehearsal.sh), because a step that only ever
# runs for real against a paying client's project is learned on that client.
#
# Subcommands, each one Management API conversation, so the workflow can
# record progress in the control plane's register between them and carry on
# a build that stopped part-way:
#
#   create <code> <display name>   POST /v1/projects. Needs DB_PASS, ORG_SLUG,
#                                  REGION, INSTANCE_SIZE. Prints ref=<ref>.
#                                  Refuses when a project of that name already
#                                  exists: the register, not a retry, says
#                                  which project a code has.
#   wait <ref>                     until the project says ACTIVE_HEALTHY
#                                  (WAIT_SECONDS, default 1200; POLL_SECONDS,
#                                  default 20). INIT_FAILED or REMOVED stops it.
#   configure <ref> <code>         PATCH the auth settings a build refuses
#                                  without (build_from_empty.sh): sign-up
#                                  closed, addresses confirmed, the site URL
#                                  and redirect list of https://<code>.<APEX>,
#                                  a twelve-character password, and custom
#                                  SMTP through Resend (RESEND_API_KEY,
#                                  MAIL_FROM) — Supabase's own sender delivers
#                                  only to the project's team, so without this
#                                  no client could ever ask for a sign-in link
#                                  or reset a password. Then PATCH PostgREST to
#                                  expose public and graphql_public only, which
#                                  release.yml checks before every release.
#                                  Reads both back and refuses a setting that
#                                  did not take.
#   keys <ref>                     GET the API keys. Prints
#                                  publishable=<key> (public by design); the
#                                  secret key goes to the file SECRET_OUT and
#                                  nowhere else.
#   owner <ref> <owner email>      the owner's confirmed sign-in, through the
#                                  project's own admin API with SERVICE_KEY, so
#                                  build_from_empty.sh finds exactly one
#                                  sign-in, the owner's, confirmed. Already
#                                  there is fine.
#   pooler <ref>                   GET the session pooler: prints host=, port=,
#                                  user=, dbname= for the primary in session
#                                  mode. The password never passes through
#                                  here; the workflow composes the URL.
#   sign-in-link <ref> <email> <redirect url>
#                                  the end of a build: the owner is sent a
#                                  sign-in link through the project's own
#                                  auth API, as the sign-in screen asks for
#                                  one (PUBLISHABLE_KEY). Accepted proves the
#                                  project's own SMTP delivers beyond its team;
#                                  refused names the SMTP settings to check.
#   password <ref>                 PATCH the database password to DB_PASS, for
#                                  a build carried on after the password was
#                                  lost, and for rotation.
#   secrets <ref> NAME=VALUE ...   the Edge Functions' secrets (POST /secrets).
#                                  Values are read from the arguments and never
#                                  printed.
#
# Environment: SUPABASE_ACCESS_TOKEN (required; org-scoped, with the
# projects permissions), CURL (the curl command, default curl), API (default
# https://api.supabase.com), and the MAPI_* settings of
# supabase/ci/management_api.sh, through which every Management API call
# here is made: a 429 or a 5xx is asked again with backoff, never refused at
# the first answer.
#
# Nothing here touches a database: that is build_from_empty.sh, over a
# connection the workflow composes from `pooler` and the vault.
set -euo pipefail

CURL_CMD="${CURL:-curl}"
API="${API:-https://api.supabase.com}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# mapi and patient_request: a 429 or a 5xx asked again with backoff, any
# other 4xx a verdict (supabase/ci/management_api.sh).
# shellcheck source=supabase/ci/management_api.sh
. "$HERE/management_api.sh"

refuse() {
  echo "x $*" >&2
  exit 2
}

[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] ||
  refuse "SUPABASE_ACCESS_TOKEN is not set; nothing can be made or read through the Management API without it."

is_ref() { [[ "$1" =~ ^[a-z0-9]{20}$ ]]; }
is_code() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]]; }

# api <method> <path> [json body]: the body on success, a refusal naming the
# path on failure, after mapi has said the status and the API's own message
# (a 4xx from this API says what was wrong in plain words). A busy minute is
# waited out by mapi rather than refused here.
api() {
  local method="$1" path="$2" body="${3:-}"
  local out
  out=$(mapi "$method" "$path" "$body") || refuse "${method} ${path} failed."
  printf '%s' "$out"
}

cmd="${1:-}"
shift || true

case "$cmd" in

  create)
    code="${1:?usage: provision_project.sh create <code> <display name>}"
    name="${2:?usage: provision_project.sh create <code> <display name>}"
    is_code "$code" || refuse "'$code' is not an address-shaped code (one DNS label, 3 to 63 of a-z 0-9 -)."
    [[ -n "${DB_PASS:-}" && ${#DB_PASS} -ge 24 ]] || refuse "DB_PASS must be set, 24 characters or more; the workflow generates it and keeps it in the control plane's vault before anything is made."
    [[ -n "${ORG_SLUG:-}" ]] || refuse "ORG_SLUG (the Supabase organisation's slug, from the dashboard URL) is not set."
    [[ -n "${REGION:-}" ]] || refuse "REGION is not set (production and the demonstration are eu-central-1)."
    [[ -n "${INSTANCE_SIZE:-}" ]] || refuse "INSTANCE_SIZE is not set (the owner's choice for a client is micro)."
    # Plain ASCII: the name travels through the Management API and the
    # dashboard, and the first real call is no place to learn what either
    # does with a typographic dash.
    project_name="Clove ERP - ${name}"
    # The name, not the code, is what the dashboard shows and what a second
    # run would duplicate. A project of that name already in the organisation
    # is a build that got this far before: carry it on with its ref.
    # Listed through the organisation, which needs the organisation's
    # projects-read permission — the one an org-scoped token surely holds,
    # since it is the same scope that creates projects. GET /v1/projects
    # needs an account-wide permission that such a token may not have.
    existing=$(api GET "/v1/organizations/${ORG_SLUG}/projects?limit=100" | jq -r --arg n "$project_name" '[.projects[] | select(.name == $n)] | .[0].ref // empty')
    [[ -z "$existing" ]] ||
      refuse "a project named '${project_name}' already exists (${existing}). Carry that build on with confirm_project_ref=${existing} rather than making a second project for ${code}."
    body=$(jq -cn --arg name "$project_name" --arg org "$ORG_SLUG" --arg region "$REGION" --arg size "$INSTANCE_SIZE" --arg pass "$DB_PASS" \
             '{name: $name, organization_slug: $org, region: $region, desired_instance_size: $size, db_pass: $pass}')
    # Asked again only after a 429, which says nothing was made: making a
    # project is not safe to repeat, and a 5xx or no answer may come after the
    # project was made. Then the organisation is looked at again, by name,
    # before anything else is asked: a project that appeared is this build's
    # (none of that name existed a moment ago) and is carried on with.
    if made=$(MAPI_RETRY_ONLY_429=yes MAPI_TIMEOUT="${CREATE_TIMEOUT:-180}" mapi POST "/v1/projects" "$body"); then
      ref=$(printf '%s' "$made" | jq -r '.ref // .id // empty')
      is_ref "$ref" || refuse "the Management API made a project but answered no ref: $(printf '%s' "$made" | head -c 300)"
    else
      ref=""
      for pause in ${CREATE_RECHECK_PAUSES:-15 30 60}; do
        ${MAPI_SLEEP:-sleep} "$pause"
        ref=$(api GET "/v1/organizations/${ORG_SLUG}/projects?limit=100" | jq -r --arg n "$project_name" '[.projects[] | select(.name == $n)] | .[0].ref // empty')
        [[ -z "$ref" ]] || break
      done
      [[ -n "$ref" ]] ||
        refuse "POST /v1/projects gave no project, and none named '${project_name}' has appeared in ${ORG_SLUG}. Retry the build: it looks for the project by name again before making one."
      is_ref "$ref" || refuse "a project named '${project_name}' appeared, but its ref '${ref}' is not a ref."
      echo "POST /v1/projects had no clear answer, but '${project_name}' now exists (${ref}); carrying on with it" >&2
    fi
    echo "made ${project_name} (${ref}) in ${REGION} on ${INSTANCE_SIZE}" >&2
    echo "ref=${ref}"
    ;;

  wait)
    ref="${1:?usage: provision_project.sh wait <ref>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    limit="${WAIT_SECONDS:-1200}"
    poll="${POLL_SECONDS:-20}"
    waited=0
    while :; do
      status=$(api GET "/v1/projects/${ref}" | jq -r '.status // "UNKNOWN"')
      case "$status" in
        ACTIVE_HEALTHY) echo "${ref} is ACTIVE_HEALTHY after ${waited} s" >&2; echo "status=${status}"; exit 0 ;;
        INIT_FAILED|REMOVED|RESTORE_FAILED|PAUSE_FAILED) refuse "${ref} is ${status}; it will not come up on its own. Look at it in the dashboard." ;;
      esac
      (( waited < limit )) || refuse "${ref} is still ${status} after ${limit} s. Run again with resume once the dashboard shows it healthy."
      echo "${ref} is ${status}; waiting" >&2
      sleep "$poll"
      waited=$((waited + poll))
    done
    ;;

  configure)
    ref="${1:?usage: provision_project.sh configure <ref> <code>}"
    code="${2:?usage: provision_project.sh configure <ref> <code>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    is_code "$code" || refuse "'$code' is not an address-shaped code."
    [[ -n "${APEX:-}" ]] || refuse "APEX is not set (cloveerp.com)."
    [[ -n "${RESEND_API_KEY:-}" ]] || refuse "RESEND_API_KEY is not set, so the project's sign-in links and password resets would go through Supabase's own sender, which delivers only to the project's team. Add it as a repository secret."
    [[ "${MAIL_FROM:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || refuse "MAIL_FROM is not an email address; it is the sender of the project's sign-in links."
    origin="https://${code}.${APEX}"
    auth=$(jq -cn --arg site "$origin" --arg allow "${origin}/**" --arg host "${SMTP_HOST:-smtp.resend.com}" \
                  --arg user "${SMTP_USER:-resend}" --arg pass "$RESEND_API_KEY" --arg from "$MAIL_FROM" \
                  --arg sender "${MAIL_SENDER_NAME:-Clove ERP}" \
             '{disable_signup: true, mailer_autoconfirm: false,
               site_url: $site, uri_allow_list: $allow,
               password_min_length: 12,
               password_required_characters: "abcdefghijklmnopqrstuvwxyz:ABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789",
               smtp_host: $host, smtp_port: "465", smtp_user: $user, smtp_pass: $pass,
               smtp_admin_email: $from, smtp_sender_name: $sender}')
    api PATCH "/v1/projects/${ref}/config/auth" "$auth" > /dev/null
    # Read back, as build_from_empty.sh will: a PATCH the API accepted and
    # did not apply is the kind of thing learned an hour in.
    got=$(api GET "/v1/projects/${ref}/config/auth")
    [[ "$(jq -r '.disable_signup' <<< "$got")" == "true" ]] || refuse "sign-up is still open on ${ref} after the PATCH."
    [[ "$(jq -r '.mailer_autoconfirm' <<< "$got")" == "false" ]] || refuse "${ref} still confirms addresses without asking after the PATCH."
    [[ "$(jq -r '.site_url' <<< "$got")" == "$origin" ]] || refuse "${ref}'s site URL is '$(jq -r '.site_url' <<< "$got")', not ${origin}."
    [[ "$(jq -r '.smtp_host // empty' <<< "$got")" == "${SMTP_HOST:-smtp.resend.com}" ]] || refuse "${ref} has no custom SMTP host after the PATCH; its sign-in links would reach only the project's team."
    api PATCH "/v1/projects/${ref}/postgrest" '{"db_schema":"public, graphql_public"}' > /dev/null
    schemas=$(api GET "/v1/projects/${ref}/postgrest" | jq -r '.db_schema // empty')
    exposed=$(printf '%s' "$schemas" | tr ',' '\n' | tr -d ' ' | grep -Ex 'erp|erp_ref|erp_meta|erp_test' || true)
    [[ -n "$schemas" && -z "$exposed" ]] || refuse "${ref}'s PostgREST exposes '${schemas}' after the PATCH."
    echo "configured ${ref}: sign-up closed, confirmation required, site ${origin}, SMTP via ${SMTP_HOST:-smtp.resend.com}, exposed schemas ${schemas}" >&2
    echo "origin=${origin}"
    ;;

  keys)
    ref="${1:?usage: provision_project.sh keys <ref>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    [[ -n "${SECRET_OUT:-}" ]] || refuse "SECRET_OUT (the file the secret key is written to) is not set."
    keys=$(api GET "/v1/projects/${ref}/api-keys?reveal=true")
    publishable=$(printf '%s' "$keys" | jq -r '[.[] | select(.type == "publishable")][0].api_key // ([.[] | select(.name == "anon")][0].api_key // empty)')
    secret=$(printf '%s' "$keys" | jq -r '[.[] | select(.type == "secret")][0].api_key // ([.[] | select(.name == "service_role")][0].api_key // empty)')
    [[ -n "$publishable" ]] || refuse "${ref} has no publishable (or anon) key."
    [[ -n "$secret" ]] || refuse "${ref} has no secret (or service_role) key."
    ( umask 077; printf '%s' "$secret" > "$SECRET_OUT" )
    echo "keys read for ${ref}; the secret key is in ${SECRET_OUT}" >&2
    echo "publishable=${publishable}"
    ;;

  owner)
    ref="${1:?usage: provision_project.sh owner <ref> <owner email>}"
    owner="${2:?usage: provision_project.sh owner <ref> <owner email>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    [[ "$owner" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || refuse "'$owner' is not an email address."
    [[ -n "${SERVICE_KEY:-}" ]] || refuse "SERVICE_KEY is not set; the owner's sign-in is made through the project's admin API, which needs it."
    base="${PROJECT_API_URL:-https://${ref}.supabase.co}"
    # A password nobody knows: the owner signs in by emailed link, or sets
    # one from the console. Confirmed, so the build's check passes and the
    # staff row binds to it (20261010063000). Thirty-two random letters and
    # digits, then one of each kind the project's password rule asks for
    # (configure sets it), so the rule can never refuse it by chance.
    pass="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)aZ7"
    body=$(jq -cn --arg email "$owner" --arg pass "$pass" \
             '{email: $email, email_confirm: true, password: $pass}')
    # A secret key in the new format (sb_secret_…) is not a JWT and must not
    # travel as a bearer, as supabase/functions/invite says; a legacy
    # service_role key is a JWT and goes as both.
    if [[ "${SERVICE_KEY}" == sb_* ]]; then
      auth_headers=(-H "apikey: ${SERVICE_KEY}")
    else
      auth_headers=(-H "apikey: ${SERVICE_KEY}" -H "Authorization: Bearer ${SERVICE_KEY}")
    fi
    out=$($CURL_CMD -sS -w '\n%{http_code}' -X POST \
            "${auth_headers[@]}" -H "Content-Type: application/json" \
            --data "$body" "${base}/auth/v1/admin/users" 2>&1) || refuse "the admin API of ${ref} could not be reached."
    status=$(printf '%s' "$out" | tail -n 1)
    reply=$(printf '%s' "$out" | sed '$d')
    case "$status" in
      2*) echo "owner sign-in made for ${owner} on ${ref}, confirmed" >&2 ;;
      422|400)
        if grep -qi 'already' <<< "$reply"; then
          echo "owner sign-in for ${owner} already exists on ${ref}" >&2
        else
          refuse "the admin API of ${ref} refused the owner's sign-in (${status}): $(head -c 300 <<< "$reply")"
        fi ;;
      *) refuse "the admin API of ${ref} answered ${status}: $(head -c 300 <<< "$reply")" ;;
    esac
    echo "owner=${owner}"
    ;;

  pooler)
    ref="${1:?usage: provision_project.sh pooler <ref>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    pool=$(api GET "/v1/projects/${ref}/config/database/pooler")
    row=$(printf '%s' "$pool" | jq -c '[.[] | select(.database_type == "PRIMARY" and .pool_mode == "session")][0] // ([.[] | select(.database_type == "PRIMARY")][0] // empty)')
    [[ -n "$row" ]] || refuse "${ref} answered no primary pooler."
    host=$(jq -r '.db_host' <<< "$row"); port=$(jq -r '.db_port' <<< "$row")
    user=$(jq -r '.db_user' <<< "$row"); dbname=$(jq -r '.db_name' <<< "$row")
    # The SESSION pooler, always: the same host serves session mode on 5432
    # and transaction mode on 6543, and the API reports whichever mode the
    # project defaults to. Every build and release here holds a session
    # (set statement_timeout, one transaction per migration, pg_dump-like
    # reads), which is why every connection string in this repository is the
    # session pooler's.
    if [[ "$(jq -r '.pool_mode' <<< "$row")" != "session" ]]; then
      port=5432
    fi
    [[ "$user" == *"${ref}"* ]] || refuse "the pooler's user '${user}' does not name ${ref}; release.yml would refuse the connection it makes."
    echo "host=${host}"; echo "port=${port}"; echo "user=${user}"; echo "dbname=${dbname}"
    ;;

  sign-in-link)
    ref="${1:?usage: provision_project.sh sign-in-link <ref> <email> <redirect url>}"
    email="${2:?usage: provision_project.sh sign-in-link <ref> <email> <redirect url>}"
    redirect="${3:?usage: provision_project.sh sign-in-link <ref> <email> <redirect url>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || refuse "'$email' is not an email address."
    [[ "$redirect" =~ ^https://[^[:space:]]+$ ]] || refuse "'$redirect' is not an https address for the link to come back to."
    [[ -n "${PUBLISHABLE_KEY:-}" ]] || refuse "PUBLISHABLE_KEY is not set; the link is asked for the way the application asks for one, with the project's publishable key."
    base="${PROJECT_API_URL:-https://${ref}.supabase.co}"
    # Exactly what the sign-in screen sends (src/components/erp/gate.tsx,
    # signInWithOtp with shouldCreateUser false): nobody is made, and a link
    # goes to a sign-in that already exists. The project's auth API answers
    # only once its mailer has handed the message to the SMTP server, so a
    # 2xx is the proof that the project's own mail (configure: custom SMTP
    # through Resend) accepts a message for an address outside the
    # project's team, which Supabase's own sender never would.
    body=$(jq -cn --arg email "$email" '{email: $email, create_user: false}')
    back=$(jq -rn --arg r "$redirect" '$r | @uri')
    # A publishable key in the new format (sb_publishable_…) is not a JWT and
    # goes as apikey only, as owner's secret key does; a legacy anon key goes
    # as a bearer too.
    if [[ "${PUBLISHABLE_KEY}" == sb_* ]]; then
      key_headers=(-H "apikey: ${PUBLISHABLE_KEY}")
    else
      key_headers=(-H "apikey: ${PUBLISHABLE_KEY}" -H "Authorization: Bearer ${PUBLISHABLE_KEY}")
    fi
    patient_request "POST /auth/v1/otp on ${ref}" POST "${base}/auth/v1/otp?redirect_to=${back}" "$body" \
        "${key_headers[@]}" > /dev/null ||
      refuse "${ref}'s own mail did not accept a sign-in link for ${email}, so a client could not be sent one either. Check the project's SMTP settings (Authentication, Emails, SMTP Settings): host ${SMTP_HOST:-smtp.resend.com}, port 465, user ${SMTP_USER:-resend}, the password (the RESEND_API_KEY secret, which must be a live Resend key), and a sender (MAIL_FROM) on a domain Resend has verified."
    echo "a sign-in link for ${email} was accepted by ${ref}'s own mail, to come back to ${redirect}" >&2
    echo "sign-in-link=sent"
    ;;

  password)
    ref="${1:?usage: provision_project.sh password <ref>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    [[ -n "${DB_PASS:-}" && ${#DB_PASS} -ge 24 ]] || refuse "DB_PASS must be set, 24 characters or more."
    api PATCH "/v1/projects/${ref}/database/password" "$(jq -cn --arg p "$DB_PASS" '{password: $p}')" > /dev/null
    echo "database password set on ${ref}" >&2
    echo "password=set"
    ;;

  secrets)
    ref="${1:?usage: provision_project.sh secrets <ref> NAME=VALUE ...}"
    shift
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    [[ $# -gt 0 ]] || refuse "no secrets given."
    list='[]'
    names=""
    for kv in "$@"; do
      [[ "$kv" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || refuse "'${kv%%=*}' is not a secret name (A-Z, 0-9, _)."
      n="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
      [[ "$n" != SUPABASE_* ]] || refuse "${n}: a secret may not start with SUPABASE_; the project sets those itself."
      list=$(jq -c --arg n "$n" --arg v "$v" '. + [{name: $n, value: $v}]' <<< "$list")
      names="${names} ${n}"
    done
    api POST "/v1/projects/${ref}/secrets" "$list" > /dev/null
    echo "secrets set on ${ref}:${names}" >&2
    echo "secrets=${names# }"
    ;;

  *)
    refuse "usage: provision_project.sh create|wait|configure|keys|owner|pooler|sign-in-link|password|secrets ..."
    ;;
esac
