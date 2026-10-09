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
#                                  and redirect list of https://<code>.<APEX>
#                                  (and of each address in ALSO_ALLOW, the
#                                  ones a renamed client holds),
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
#   site <ref>                     GET the auth settings: prints site=<the site
#                                  URL>, where the project's sign-in links
#                                  go. Changes nothing (fleet_rename.sh reads
#                                  it back).
#   secret-digest <ref> <NAME>     GET the Edge Functions' secrets: prints
#                                  digest=<the SHA-256 of NAME's value>, as
#                                  the API lists it (never the value), or
#                                  digest= when it has none. Changes nothing
#                                  (fleet_rename.sh reads CLOVEERP_APP_URL
#                                  back with it).
#   resend-webhook <ref> create|verify|delete|prove
#                                  the project's own endpoint at Resend, the
#                                  email provider, which tells it what became
#                                  of the mail it sent
#                                  (supabase/functions/resend_webhook). Below,
#                                  at the subcommand. Prints
#                                  resend-webhook=<what was done> and id=<the
#                                  endpoint's id>; never the admin key, the
#                                  signing secret, or an email address. Exit
#                                  2 refused, nothing changed; 3 stopped
#                                  after changing something, leaving no
#                                  endpoint the project's function takes the
#                                  events of; 4 its database recorded the
#                                  proof; 6 its database has not been
#                                  released 20261012050000.
#
# Environment: SUPABASE_ACCESS_TOKEN (required; org-scoped, with the
# projects permissions), CURL (the curl command, default curl), API (default
# https://api.supabase.com), and the MAPI_* settings of
# supabase/ci/management_api.sh, through which every Management API call
# here is made: a 429 or a 5xx is asked again with backoff, never refused at
# the first answer. resend-webhook also reads RESEND_ADMIN_API_KEY (a
# full-access Resend key, a repository secret only the workflows use; the
# projects' own RESEND_API_KEY only sends), RESEND_API (default
# https://api.resend.com), asked with the same patience,
# CLOVEERP_LIVE_DATABASE_URL, the control plane, whose vault keeps each
# endpoint (supabase/ci/fleet_register.sh, PSQL), and
# CLOVEERP_DEMO_DATABASE_URL, the demonstration's database, which
# resend-webhook create asks before it makes the demonstration's endpoint.
#
# Nothing here changes a client's database: that is build_from_empty.sh,
# over a connection the workflow composes from `pooler` and the vault. Only
# resend-webhook reaches a database: the control plane's vault, and, before
# it makes an endpoint, the project's own database, asked one question and
# changed in nothing.
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

# digest_of_secret <ref> <NAME>: the SHA-256 of the project's Edge Function
# secret NAME, in lower case, as the Management API lists it (never the
# value); empty when the project has none. Refuses what is not a list of
# secrets, and a listing that is not a digest, without printing it. Called
# as $(digest_of_secret ...) || exit 2: a command substitution does not
# inherit set -e, so every failure here exits by hand.
digest_of_secret() {
  local ref="$1" name="$2" got digest
  got=$(api GET "/v1/projects/${ref}/secrets") || exit 2
  digest=$(jq -r --arg n "$name" 'if type == "array" then ([.[] | select(.name == $n) | .value][0] // "") else error("not a list") end' <<< "$got" 2> /dev/null) ||
    refuse "${ref}'s secrets answered something that is not a list of them."
  # A digest is 64 hexadecimal characters; anything else is not one, and
  # is not printed.
  [[ -z "$digest" || "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || refuse "${ref} lists ${name} with something that is not a SHA-256 digest."
  printf '%s' "$digest" | tr 'A-F' 'a-f'
}

# sha256_of <value>: its SHA-256 in lower-case hexadecimal. The value goes
# through a pipe, never on a command line.
sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1
  fi
}

# mask <value>: hidden from a GitHub Actions log from here on. On standard
# error, because the callers capture standard output, and the runner reads
# its commands from both. Elsewhere nothing secret is printed at all.
mask() {
  if [[ "${GITHUB_ACTIONS:-}" == true && -n "${1:-}" ]]; then
    echo "::add-mask::$1" >&2
  fi
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
    # The redirects allowed: the site's own, and the addresses in ALSO_ALLOW
    # (space-separated), which are the ones a renamed client was moved from
    # and holds for good (fleet_rename.sh, fleet_secrets.sh): a sign-in link
    # asked for at one of them comes back there, and it is the client's.
    allow="${origin}/**"
    for a in ${ALSO_ALLOW:-}; do
      is_code "$a" || refuse "'${a}' in ALSO_ALLOW is not an address-shaped code."
      [[ "$a" != "$code" && ",${allow}," != *",https://${a}.${APEX}/**,"* ]] || continue
      allow="${allow},https://${a}.${APEX}/**"
    done
    auth=$(jq -cn --arg site "$origin" --arg allow "$allow" --arg host "${SMTP_HOST:-smtp.resend.com}" \
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
    # With addresses held beside its own, each redirect asked for is among
    # those it allows now (in any order): that is the point of asking.
    if [[ -n "${ALSO_ALLOW:-}" ]]; then
      have=",$(jq -r '.uri_allow_list // ""' <<< "$got" | tr -d ' '),"
      IFS=',' read -r -a wanted_redirects <<< "$allow"
      for w in "${wanted_redirects[@]}"; do
        [[ "$have" == *",${w},"* ]] || refuse "${ref} does not allow the redirect ${w} after the PATCH, so a sign-in link asked for there would not come back."
      done
    fi
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

  site)
    ref="${1:?usage: provision_project.sh site <ref>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    got=$(api GET "/v1/projects/${ref}/config/auth")
    site=$(jq -r '.site_url // empty' <<< "$got" 2> /dev/null) || refuse "${ref}'s auth settings answered something that is not JSON."
    echo "site=${site}"
    ;;

  secret-digest)
    ref="${1:?usage: provision_project.sh secret-digest <ref> <NAME>}"
    name="${2:?usage: provision_project.sh secret-digest <ref> <NAME>}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || refuse "'${name}' is not a secret name (A-Z, 0-9, _)."
    digest=$(digest_of_secret "$ref" "$name") || exit 2
    echo "digest=${digest}"
    ;;

  resend-webhook)
    # Resend tells a project what became of the mail it sent (delivered,
    # delayed, bounced, complained of) by posting to its function
    # supabase/functions/resend_webhook, which checks Resend's signature
    # (src/lib/email/resend-webhook.ts) and hands the event to
    # erp.record_email_delivery_event(). Until 9 October that endpoint was a
    # step of the checklist, made by hand in Resend's dashboard. Now every
    # project has an endpoint of its own (the owner's decision of 9 October,
    # batch 6), made here: https://<ref>.supabase.co/functions/v1/resend_webhook,
    # sent the six kinds of event the function reads (OF_TYPE in
    # src/lib/email/resend-webhook.ts; the rehearsal checks the two agree).
    # A Resend webhook hears every event of the whole account, and the
    # database records only what matches mail it sent itself
    # (20261012050000), so one client's endpoint never stores another's
    # recipients.
    #
    # The endpoint's id and signing secret are kept in the control plane's
    # vault as cloveerp:deployment:<ref>:resend_webhook, a JSON {id, secret},
    # before the project is given the secret (CLOVEERP_RESEND_WEBHOOK_SECRET,
    # which the function reads before its own vault), so the secret a project
    # holds is never held only by this run. The demonstration and the control
    # plane are kept the same way, under their own refs.
    #
    #   create  first, the project's own database is asked whether it has
    #           been released 20261012050000, which records only events that
    #           match mail it sent: it has when it has
    #           erp_meta.deployment_checklist_by_build(text,text,boolean),
    #           which that migration gives every database. One that has not
    #           would keep every event of the account, other projects'
    #           recipients among them, so nothing is asked of Resend and this
    #           exits 6: release to it first. The database is the control
    #           plane's (CLOVEERP_LIVE_DATABASE_URL) when <ref> is its
    #           project, the demonstration's (CLOVEERP_DEMO_DATABASE_URL)
    #           when <ref> is that, and otherwise the one the control plane's
    #           vault keeps as cloveerp:deployment:<ref>:db_url.
    #           Then reuse, mend or make, so it may be run any number of
    #           times: the endpoint the vault holds is reused when Resend
    #           still has it at this project's address, sent the six events
    #           and enabled, and signing with the secret the vault keeps (as
    #           GET /webhooks/<id> gives it: a secret rotated in Resend's
    #           dashboard would have every real event refused while a proof
    #           signed with the vault's passed); the project is then given
    #           that secret again only if its digest differs. Anything else
    #           at this address is deleted and made again: an endpoint that
    #           hears other events or is disabled; one whose secret the vault
    #           does not hold, or Resend signs with another or will not say
    #           (Resend gives the secret when an endpoint is made, so one
    #           made again is known); and any endpoint at this project's
    #           address that the vault does not hold, which is what a run
    #           that stopped between making one and keeping it leaves. One
    #           the vault holds that points at another address may be
    #           another project's: it is never deleted, only forgotten (its
    #           entry removed from the vault). Deleted first, made after, so
    #           a project never has two; a deletion Resend answers 404 to is
    #           done (a retry after an answer that was lost). Made through
    #           POST /webhooks, asked again only after a 429 (a 5xx or no
    #           answer may come after it was made: then whatever appeared at
    #           this address is deleted, or, when Resend cannot be asked,
    #           said to be perhaps left for the next run to delete). If
    #           Resend gives no signing secret when it makes one, it is asked
    #           for it once (GET /webhooks/<id>); if it still gives none, the
    #           endpoint is deleted (an endpoint whose events cannot be
    #           verified is refused at every event) and this refuses: kept by
    #           deletion, never by an endpoint nobody can check. Then the
    #           project's secret is read back by its digest. Stopped after it
    #           began to change anything, it exits 3: the project may have
    #           no endpoint whose events its function takes, and a caller
    #           that ticked the checklist unticks it.
    #   verify  changes nothing: the vault holds an endpoint and its secret,
    #           Resend has it at this address with the six events, enabled
    #           and signing with that secret, no other endpoint is at this
    #           address, and the project's CLOVEERP_RESEND_WEBHOOK_SECRET has
    #           the digest of the vault's.
    #   delete  for a client going, or an endpoint that did not prove: every
    #           endpoint at its address deleted at Resend (a 404 is one
    #           deleted already), then the vault's entry (kept until then, so
    #           a run that stops is carried on by another). One the vault
    #           holds that points elsewhere is left there and forgotten. The
    #           project's function secret is left: nothing signs with it.
    #   prove   one signed event posted to the function, signed with the
    #           vault's secret as Resend signs (Svix's scheme: HMAC-SHA256
    #           over id.timestamp.body, keyed by the secret's base64 after
    #           whsec_, padded to a whole number of quartets first, as atob
    #           reads one that is not): an email.delivered for a message id
    #           that is nobody's and no address at all, which the function
    #           must take (200) and the database must answer {"recorded":
    #           false}. A 401 is asked again (WEBHOOK_PROVE_ATTEMPTS, default
    #           6, WEBHOOK_PROVE_WAIT seconds apart, default 10): a secret
    #           just set may not have reached the function yet. Needs no admin
    #           key. Exit 4 when the database recorded it: one that keeps
    #           events not its own. On any failure the caller deletes the
    #           endpoint again with its vault entry, and unticks the
    #           checklist (fleet_secrets.sh, the build's step): an endpoint
    #           not proved is not left to run against a database that may
    #           keep what is not its own.
    #
    # Resend's webhook API as this was written (POST, GET, DELETE /webhooks,
    # GET /webhooks/<id>; {endpoint, events}; signing_secret given when one
    # is made and by GET /webhooks/<id>; a listing paged by limit and after)
    # is to be confirmed by the first live run; every answer is read
    # defensively, and every way this can stop says what it left. Should GET
    # /webhooks/<id> never give the secret, every create makes the endpoint
    # again (deleted first, so never two) and says why.
    ref="${1:?usage: provision_project.sh resend-webhook <ref> create|verify|delete|prove}"
    what="${2:?usage: provision_project.sh resend-webhook <ref> create|verify|delete|prove}"
    is_ref "$ref" || refuse "'$ref' is not a project ref."
    case "$what" in
      create|verify|delete|prove) ;;
      *) refuse "'${what}' is not create, verify, delete or prove; nothing was asked." ;;
    esac
    if [[ "$what" != prove && -z "${RESEND_ADMIN_API_KEY:-}" ]]; then
      refuse "RESEND_ADMIN_API_KEY is not set (a full-access Resend key, a repository secret only the workflows use), so no endpoint can be made, read or deleted; nothing was asked."
    fi
    [[ -n "${CLOVEERP_LIVE_DATABASE_URL:-}" ]] ||
      refuse "CLOVEERP_LIVE_DATABASE_URL is not set, so the control plane's vault, which keeps each endpoint and its signing secret, cannot be reached; nothing was asked."

    RESEND_API="${RESEND_API:-https://api.resend.com}"
    REG="$HERE/fleet_register.sh"
    endpoint="https://${ref}.supabase.co/functions/v1/resend_webhook"
    vault_name="cloveerp:deployment:${ref}:resend_webhook"
    secret_name="CLOVEERP_RESEND_WEBHOOK_SECRET"
    # OF_TYPE in src/lib/email/resend-webhook.ts, in its order.
    events='["email.sent","email.delivery_delayed","email.delivered","email.opened","email.complained","email.bounced"]'
    want_events=$(jq -c 'sort' <<< "$events")

    # resend <method> <path> [body]: Resend's API with the admin key, as
    # mapi asks the Management API (a 429 or a 5xx again, with backoff,
    # never sooner than Retry-After). The body on a 2xx; otherwise a
    # failure, the status and Resend's own words said on standard error.
    resend() {
      patient_request "Resend ${1} ${2%%\?*}" "$1" "${RESEND_API}${2}" "${3:-}" \
        -H "Authorization: Bearer ${RESEND_ADMIN_API_KEY}"
    }
    # every_endpoint: each endpoint Resend has, one JSON line each, {id,
    # endpoint, events, status}, through every page of the listing.
    every_endpoint() {
      local page after="" pages=0
      while :; do
        page=$(resend GET "/webhooks?limit=100${after:+&after=${after}}") || return 1
        jq -c '(.data // error("no data"))[] | {id: (.id // ""), endpoint: (.endpoint // .url // ""), events: (.events // []), status: (.status // "")}' <<< "$page" 2> /dev/null || {
          echo "x Resend listed its endpoints as something that is not a list of them" >&2
          return 1
        }
        [[ "$(jq -r '.has_more // false' <<< "$page")" == true ]] || return 0
        after=$(jq -r '(.data // []) | last | .id // empty' <<< "$page")
        pages=$((pages + 1))
        if [[ -z "$after" || "$pages" -ge 20 ]]; then
          echo "x Resend's listing of endpoints did not end after ${pages} page(s)" >&2
          return 1
        fi
      done
    }
    is_id() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,100}$ ]]; }
    # remove <id> <why>: deleted at Resend, or a failure said. A 404 is an
    # endpoint deleted already: a DELETE whose answer was lost (a 5xx after
    # it was done) is asked again, and the second answer is a 404.
    remove() {
      local said rc=0 st
      said=$(mktemp "${TMPDIR:-/tmp}/resend-delete.XXXXXX") || return 1
      MAPI_STATUS_FILE="$said.status" resend DELETE "/webhooks/$1" > /dev/null 2> "$said" || rc=$?
      st=$(cat "$said.status" 2> /dev/null || true)
      if [[ "$rc" -eq 0 ]]; then
        cat "$said" >&2
        echo "deleted the endpoint $1 at Resend: $2" >&2
      elif [[ "$st" == 404 ]]; then
        grep -v '^x ' "$said" >&2 || true
        echo "the endpoint $1 is not at Resend (404), so it is deleted already: $2" >&2
        rc=0
      else
        cat "$said" >&2
        rc=1
      fi
      rm -f "$said" "$said.status"
      return "$rc"
    }
    # sign <secret> <content>: the signature Resend sends (v1), as
    # src/lib/email/resend-webhook.ts computes it. The content through a
    # pipe; the key to openssl as hex. The base64 is padded to a whole number
    # of quartets first: atob reads an unpadded key, and openssl reads none
    # of a group that is not whole.
    sign() {
      local hex key="${1#whsec_}"
      while (( ${#key} % 4 )); do key="${key}="; done
      hex=$(printf '%s' "$key" | openssl base64 -d -A 2> /dev/null | od -An -vtx1 | tr -d ' \n')
      [[ -n "$hex" ]] || return 1
      printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${hex}" -binary | openssl base64 -A
    }
    # left: how this stops from here on. 2 while nothing has been changed;
    # 3 once anything has been deleted, made, forgotten or given, when the
    # project may be left with no endpoint whose events its function takes,
    # and a caller that ticked the checklist unticks it.
    left=2
    stop() {
      echo "x $*" >&2
      exit "$left"
    }

    # keeps_its_own_mail: whether the project's own database has been
    # released 20261012050000, asked before anything of Resend (create).
    # Exit 6 when it has not; a refusal when it cannot be asked.
    keeps_its_own_mail() {
      local url got
      if [[ "${CLOVEERP_LIVE_DATABASE_URL}" == *"$ref"* ]]; then
        url="$CLOVEERP_LIVE_DATABASE_URL"
      elif [[ -n "${CLOVEERP_DEMO_DATABASE_URL:-}" && "${CLOVEERP_DEMO_DATABASE_URL}" == *"$ref"* ]]; then
        url="$CLOVEERP_DEMO_DATABASE_URL"
      else
        url=$("$REG" vault-get "cloveerp:deployment:${ref}:db_url") ||
          refuse "the control plane's vault could not be read for ${ref}'s database, so whether it keeps only its own mail (20261012050000) is not known; nothing was asked of Resend."
        mask "$url"
        [[ -n "$url" ]] ||
          refuse "${ref}'s database cannot be reached: it is neither the control plane's nor the demonstration's (CLOVEERP_DEMO_DATABASE_URL), and the control plane's vault has no cloveerp:deployment:${ref}:db_url. Whether it keeps only its own mail (20261012050000) is not known, so nothing was asked of Resend."
        [[ "$url" == *"$ref"* ]] ||
          refuse "cloveerp:deployment:${ref}:db_url in the control plane's vault does not name ${ref}; nothing was asked of Resend."
      fi
      got=$(${PSQL:-psql} "$url" -v ON_ERROR_STOP=1 -v VERBOSITY=terse -X -q -tA <<'SQL'
-- fleet: target-keeps-its-own-mail
set statement_timeout = '30s';
select (to_regprocedure('erp_meta.deployment_checklist_by_build(text,text,boolean)') is not null)::text;
SQL
) || refuse "${ref}'s database could not be asked whether it keeps only its own mail (20261012050000) (the line above says why); nothing was asked of Resend."
      if [[ "$got" != true ]]; then
        echo "x ${ref}'s database has not been released 20261012050000, so it would keep every event of the account, other projects' recipients among them: no endpoint is made for it. Release to it first (deploy.yml), then run this again; nothing was asked of Resend." >&2
        exit 6
      fi
    }
    if [[ "$what" == create ]]; then
      keeps_its_own_mail
    fi

    # What the vault keeps for it, masked before anything else is printed.
    held=$("$REG" vault-get "$vault_name") ||
      refuse "the control plane's vault could not be read for ${vault_name}; nothing was asked of Resend."
    held_id=""; held_secret=""
    if [[ -n "$held" ]]; then
      mask "$held"
      held_secret=$(jq -r 'if type == "object" then (.secret // "") else "" end' <<< "$held" 2> /dev/null || true)
      mask "$held_secret"
      held_id=$(jq -r 'if type == "object" then (.id // "") else "" end' <<< "$held" 2> /dev/null || true)
      if [[ -n "$held_id" ]] && ! is_id "$held_id"; then
        refuse "the control plane's vault keeps something under ${vault_name} that does not name an endpoint; nothing was asked of Resend."
      fi
    fi

    case "$what" in
      create)
        all=$(every_endpoint) || refuse "Resend's endpoints could not be listed (the line above says what it answered); nothing was changed."
        reuse=no
        forget=no
        # What is deleted before anything is made: one "<id>=<why>" a line.
        doomed=""
        if [[ -n "$held_id" ]]; then
          if [[ -z "$(jq -r --arg i "$held_id" 'select(.id == $i) | .id' <<< "$all")" ]]; then
            echo "the endpoint the vault keeps for ${ref} (${held_id}) is no longer at Resend; one is made" >&2
          else
            one=$(resend GET "/webhooks/${held_id}") ||
              refuse "Resend lists the endpoint ${held_id} but would not give it (the line above says what it answered); nothing was changed."
            at=$(jq -r '.endpoint // .url // ""' <<< "$one" 2> /dev/null || true)
            hears=$(jq -c '(.events // []) | sort' <<< "$one" 2> /dev/null || true)
            state=$(jq -r '.status // ""' <<< "$one" 2> /dev/null || true)
            # The secret Resend signs this endpoint's events with, masked
            # before anything else is printed, and compared, never printed.
            signs=$(jq -r 'if type == "object" then (.signing_secret // "") else "" end' <<< "$one" 2> /dev/null || true)
            mask "$signs"
            why=""
            if [[ "$at" != "$endpoint" ]]; then
              # Not this project's address, so perhaps another project's
              # endpoint: never deleted from here.
              forget=yes
            elif [[ -z "$held_secret" ]]; then
              why="the vault keeps no signing secret for it"
            elif [[ -z "$signs" ]]; then
              why="Resend would not say which secret it signs with, so the vault's cannot be confirmed"
            elif [[ "$signs" != "$held_secret" ]]; then
              why="Resend signs its events with another secret than the vault keeps"
            elif [[ "$hears" != "$want_events" ]]; then
              why="it hears other events than the function reads"
            elif [[ -n "$state" && "$state" != enabled ]]; then
              why="Resend has it ${state}"
            fi
            if [[ "$forget" == yes ]]; then
              :
            elif [[ -z "$why" ]]; then
              reuse=yes
            else
              doomed="${held_id}=${why}"$'\n'
            fi
          fi
        fi
        if [[ "$forget" == yes ]]; then
          left=3
          "$REG" vault-del "$vault_name" > /dev/null ||
            stop "the endpoint ${held_id} the vault keeps for ${ref} points at ${at:-nothing}, not ${endpoint}, and ${vault_name} could not be removed from the control plane's vault; nothing was deleted at Resend. Run this again."
          echo "the endpoint ${held_id} the vault kept for ${ref} points at ${at:-nothing}, not ${endpoint}: it may be another project's, so it was left at Resend and forgotten (${vault_name} removed from the vault)" >&2
          held=""; held_id=""; held_secret=""
        fi
        # Every endpoint at this address the vault does not keep: its
        # secret is nobody's, so its every event would be refused.
        while IFS= read -r other; do
          [[ -n "$other" && "$other" != "$held_id" ]] || continue
          is_id "$other" || stop "Resend lists an endpoint at ${endpoint} with an id that is not one; nothing more was changed."
          doomed="${doomed}${other}=it is at this project's address and the vault does not keep it"$'\n'
        done <<< "$(jq -r --arg e "$endpoint" 'select(.endpoint == $e) | .id' <<< "$all")"
        if [[ "$reuse" == yes ]]; then
          verdict=reused
        elif [[ -n "$held_id" || -n "$doomed" || "$forget" == yes ]]; then
          verdict=recreated
        else
          verdict=created
        fi

        # Deleted first, so a project never has two.
        while IFS= read -r item; do
          [[ -n "$item" ]] || continue
          left=3
          remove "${item%%=*}" "${item#*=}" ||
            stop "the endpoint ${item%%=*} could not be deleted at Resend (the line above says what it answered), so no new one was made; run this again."
        done <<< "$doomed"

        if [[ "$reuse" != yes ]]; then
          body=$(jq -cn --arg e "$endpoint" --argjson ev "$events" '{endpoint: $e, events: $ev}')
          left=3
          if ! made=$(MAPI_RETRY_ONLY_429=yes resend POST /webhooks "$body"); then
            # A 5xx or no answer may come after Resend made it: whatever is
            # at this address now is nobody's, and is deleted. When Resend
            # cannot even be asked what it has, that is said, not hidden:
            # an endpoint it made may be there, and the next create, which
            # deletes every endpoint at this address the vault does not
            # keep, deletes it.
            if ! again=$(every_endpoint); then
              stop "Resend did not say it made the endpoint for ${ref} (the line above says what it answered), and its endpoints could not be listed again, so one it made may still be at ${endpoint}, kept by nobody. The next create deletes every endpoint at that address the vault does not keep; the project's secret is as it was. Run this again."
            fi
            remain=""
            while IFS= read -r stray; do
              [[ -n "$stray" ]] && is_id "$stray" || continue
              remove "$stray" "made by this run, whose answer was lost" || remain="${remain} ${stray}"
            done <<< "$(jq -r --arg e "$endpoint" 'select(.endpoint == $e) | .id' <<< "$again")"
            if [[ -n "$remain" ]]; then
              stop "Resend did not say it made the endpoint for ${ref} (the line above says what it answered), and${remain} at ${endpoint}, kept by nobody, could not be deleted (the lines above say why). The next create deletes it; the project's secret is as it was. Run this again."
            fi
            stop "Resend did not say it made the endpoint for ${ref} (the line above says what it answered). Nothing is at ${endpoint} now: anything it made there has been deleted. The project's secret is as it was. Run this again."
          fi
          new_id=$(jq -r '.id // empty' <<< "$made" 2> /dev/null || true)
          is_id "$new_id" || stop "Resend made an endpoint for ${ref} and answered no id that is one; the next run deletes whatever is at ${endpoint} and makes it again."
          new_secret=$(jq -r '.signing_secret // empty' <<< "$made" 2> /dev/null || true)
          mask "$new_secret"
          if [[ -z "$new_secret" ]]; then
            # Not given when it was made: asked for once.
            if got=$(resend GET "/webhooks/${new_id}"); then
              new_secret=$(jq -r '.signing_secret // empty' <<< "$got" 2> /dev/null || true)
              mask "$new_secret"
            fi
          fi
          if ! [[ "$new_secret" =~ ^whsec_[A-Za-z0-9+/]+=*$ ]]; then
            remove "$new_id" "Resend gave no signing secret for it" ||
              stop "Resend made the endpoint ${new_id} for ${ref} and gave no signing secret, when it was made or when asked again, and it could not be deleted (the line above says why): the next run deletes it. Confirm how Resend gives an endpoint's signing secret before running this again."
            stop "Resend made the endpoint ${new_id} for ${ref} and gave no signing secret, when it was made or when asked again, so no event it sent could be verified. It was deleted; the project's secret is as it was. Confirm how Resend gives an endpoint's signing secret before running this again."
          fi
          kept=$(jq -cn --arg i "$new_id" --arg s "$new_secret" '{id: $i, secret: $s}')
          mask "$kept"
          # The vault first: the secret the project is given is never held
          # only by this run.
          if ! printf '%s' "$kept" | "$REG" vault-put "$vault_name" > /dev/null; then
            remove "$new_id" "its signing secret could not be kept" ||
              stop "the endpoint ${new_id} made for ${ref} could not be kept in the control plane's vault as ${vault_name}, nor deleted (the line above says why): the next run deletes it. Run this again."
            stop "the endpoint made for ${ref} could not be kept in the control plane's vault as ${vault_name}, so it was deleted; the project's secret is as it was. Run this again."
          fi
          held_id="$new_id"; held_secret="$new_secret"
        fi

        # The project's secret: given only when its digest differs, then
        # read back.
        want_digest=$(sha256_of "$held_secret")
        have_digest=$(digest_of_secret "$ref" "$secret_name") || exit "$left"
        if [[ "$have_digest" != "$want_digest" ]]; then
          given=$(jq -cn --arg n "$secret_name" --arg v "$held_secret" '[{name: $n, value: $v}]')
          mask "$given"
          left=3
          if ! mapi POST "/v1/projects/${ref}/secrets" "$given" > /dev/null; then
            stop "the endpoint ${held_id} is kept in the vault as ${vault_name}, and the project ${ref} did not take its ${secret_name} (the line above says what the Management API answered), so its function refuses that endpoint's events. Run this again: it gives the project the vault's secret."
          fi
          have_digest=$(digest_of_secret "$ref" "$secret_name") || exit "$left"
          [[ "$have_digest" == "$want_digest" ]] ||
            stop "${ref}'s ${secret_name} does not read back as the secret the vault keeps for the endpoint ${held_id}; run this again."
          [[ "$verdict" != reused ]] || verdict=mended
        fi
        echo "${ref}: the endpoint ${held_id} at Resend (${verdict}) posts the six kinds of event to ${endpoint}; its signing secret is kept as ${vault_name}, Resend signs with it, and it is the project's ${secret_name}" >&2
        echo "resend-webhook=${verdict}"
        echo "id=${held_id}"
        ;;

      verify)
        [[ -n "$held_id" && -n "$held_secret" ]] ||
          refuse "the control plane's vault keeps no endpoint and secret for ${ref} (${vault_name}); make it with create."
        all=$(every_endpoint) || refuse "Resend's endpoints could not be listed (the line above says what it answered)."
        [[ -n "$(jq -r --arg i "$held_id" 'select(.id == $i) | .id' <<< "$all")" ]] ||
          refuse "Resend has no endpoint ${held_id}, which the vault keeps for ${ref}; create makes one."
        one=$(resend GET "/webhooks/${held_id}") || refuse "Resend would not give the endpoint ${held_id} (the line above says what it answered)."
        at=$(jq -r '.endpoint // .url // ""' <<< "$one" 2> /dev/null || true)
        [[ "$at" == "$endpoint" ]] || refuse "the endpoint ${held_id} points at ${at:-nothing}, not ${endpoint}; create forgets it and makes one at this project's address."
        signs=$(jq -r 'if type == "object" then (.signing_secret // "") else "" end' <<< "$one" 2> /dev/null || true)
        mask "$signs"
        [[ -n "$signs" ]] ||
          refuse "Resend would not say which secret the endpoint ${held_id} signs with, so it cannot be confirmed to be the one the vault keeps; create makes it again."
        [[ "$signs" == "$held_secret" ]] ||
          refuse "Resend signs the endpoint ${held_id}'s events with another secret than the vault keeps (rotated in its dashboard?), so the function refuses every one of them; create makes it again."
        [[ "$(jq -c '(.events // []) | sort' <<< "$one" 2> /dev/null || true)" == "$want_events" ]] ||
          refuse "the endpoint ${held_id} hears other events than the six the function reads; create makes it again."
        state=$(jq -r '.status // ""' <<< "$one" 2> /dev/null || true)
        [[ -z "$state" || "$state" == enabled ]] || refuse "Resend has the endpoint ${held_id} ${state}; create makes it again."
        others=$(jq -r --arg e "$endpoint" --arg i "$held_id" 'select(.endpoint == $e and .id != $i) | .id' <<< "$all" | tr '\n' ' ')
        [[ -z "${others// /}" ]] ||
          refuse "Resend also has ${others% } at ${endpoint}, which the vault does not keep, and whose events the function refuses; create deletes it."
        have_digest=$(digest_of_secret "$ref" "$secret_name") || exit 2
        [[ "$have_digest" == "$(sha256_of "$held_secret")" ]] ||
          refuse "${ref}'s ${secret_name} is not the signing secret the vault keeps for the endpoint ${held_id}, so its function refuses that endpoint's events; create gives it the vault's."
        echo "${ref}: the endpoint ${held_id} at Resend posts the six kinds of event to ${endpoint}, signed with the secret the vault keeps, and the project holds it" >&2
        echo "resend-webhook=verified"
        echo "id=${held_id}"
        ;;

      delete)
        all=$(every_endpoint) || refuse "Resend's endpoints could not be listed (the line above says what it answered); nothing was deleted."
        # The one the vault keeps, if it points at another address, may be
        # another project's: left at Resend, and only forgotten below.
        if [[ -n "$held_id" ]]; then
          held_at=$(jq -r --arg i "$held_id" 'select(.id == $i) | .endpoint' <<< "$all" | head -n 1)
          if [[ -n "$held_at" && "$held_at" != "$endpoint" ]]; then
            echo "the endpoint ${held_id} the vault keeps for ${ref} points at ${held_at}, not ${endpoint}: it may be another project's, so it is left at Resend and only forgotten" >&2
          fi
        fi
        gone=0
        while IFS= read -r one_id; do
          [[ -n "$one_id" ]] || continue
          is_id "$one_id" || refuse "Resend lists an endpoint for ${ref} with an id that is not one; nothing more was deleted."
          remove "$one_id" "${ref}'s endpoint, asked to be deleted" ||
            refuse "the endpoint ${one_id} could not be deleted at Resend (the line above says what it answered); the vault keeps ${vault_name} until it is, so run this again."
          gone=$((gone + 1))
        done <<< "$(jq -r --arg e "$endpoint" 'select(.endpoint == $e) | .id' <<< "$all" | awk '!seen[$0]++')"
        if [[ -n "$held" ]]; then
          "$REG" vault-del "$vault_name" > /dev/null ||
            refuse "${gone} endpoint(s) deleted at Resend for ${ref}, and ${vault_name} could not be removed from the control plane's vault; run this again."
        fi
        echo "${ref}: ${gone} endpoint(s) deleted at Resend${held:+, and ${vault_name} removed from the vault}" >&2
        echo "resend-webhook=deleted"
        echo "deleted=${gone}"
        ;;

      prove)
        [[ -n "$held_secret" ]] ||
          refuse "the control plane's vault keeps no signing secret for ${ref} (${vault_name}), so nothing can be signed; make the endpoint with create."
        url="${PROJECT_API_URL:-https://${ref}.supabase.co}/functions/v1/resend_webhook"
        attempts="${WEBHOOK_PROVE_ATTEMPTS:-6}"
        pause="${WEBHOOK_PROVE_WAIT:-10}"
        [[ "$attempts" =~ ^[1-9][0-9]*$ && "$pause" =~ ^[0-9]+$ ]] ||
          refuse "WEBHOOK_PROVE_ATTEMPTS and WEBHOOK_PROVE_WAIT must be whole numbers, the first at least 1; nothing was sent."
        attempt=1
        while :; do
          # Signed now (the function refuses a signature five minutes old),
          # with an id of its own each time. WEBHOOK_PROVE_TIME and
          # WEBHOOK_PROVE_ID fix them for the rehearsal, which checks the
          # signature against one src/lib/email/resend-webhook.ts made.
          ts="${WEBHOOK_PROVE_TIME:-$(date +%s)}"
          eid="${WEBHOOK_PROVE_ID:-msg_cloveerp_proof_${ts}_$(head -c 6 /dev/urandom | od -An -vtx1 | tr -d ' \n')}"
          at=$(jq -rn --argjson t "$ts" '$t | todate')
          event=$(jq -cn --arg at "$at" --arg m "cloveerp-proof-${eid}" '{type: "email.delivered", created_at: $at, data: {email_id: $m}}')
          sig=$(sign "$held_secret" "${eid}.${ts}.${event}") && [[ -n "$sig" ]] ||
            refuse "the signing secret the vault keeps for ${ref} is not one a signature can be made with; create makes the endpoint again."
          out=$($CURL_CMD -sS -X POST -w '\n%{http_code}' --max-time 30 -H "Content-Type: application/json" \
                  -H "svix-id: ${eid}" -H "svix-timestamp: ${ts}" -H "svix-signature: v1,${sig}" \
                  --data "$event" "$url" 2> /dev/null) || true
          if [[ "$out" == *$'\n'* ]]; then status="${out##*$'\n'}"; answer="${out%$'\n'*}"; else status="$out"; answer=""; fi
          [[ "$status" =~ ^[0-9][0-9][0-9]$ ]] || status=000
          said=$(printf '%s' "$answer" | tr '\n' ' ' | head -c 200)
          case "$status" in
            2??)
              recorded=$(jq -r 'if type == "object" and has("recorded") then (.recorded | tostring) else "" end' <<< "$answer" 2> /dev/null || true)
              case "$recorded" in
                false)
                  echo "${ref}: a signed event reached its function, which took it (${status}), and its database recorded nothing: the event matches no mail it sent" >&2
                  echo "resend-webhook=proved"
                  exit 0 ;;
                true)
                  # Exit 4, apart from every other refusal: the caller
                  # deletes the endpoint again, since every event of the
                  # account would be kept there, other projects' recipients
                  # among them.
                  echo "x ${ref}'s function took the signed event and its database recorded it, though it matches no mail the project sent: that database keeps other projects' events (it has not been released 20261012050000)." >&2
                  exit 4 ;;
                *)
                  refuse "${ref}'s function answered ${status} with something that is not its database's verdict on the event." ;;
              esac ;;
            401)
              case "$answer" in
                *[Aa]uthorization*|*JWT*)
                  refuse "the gateway in front of ${ref}'s resend_webhook asked for a signed-in caller (${said}): verify_jwt must be false for it (supabase/config.toml), as Resend sends no Authorization header." ;;
              esac ;;
            404|408|429|5??|000) : ;;
            *) refuse "${ref}'s resend_webhook answered ${status} to the signed event: ${said}" ;;
          esac
          if [[ "$attempt" -ge "$attempts" ]]; then
            refuse "${ref}'s resend_webhook did not take the signed event in ${attempts} attempt(s); it answered ${status}${said:+: ${said}}. A 401 is a function whose ${secret_name} is not the secret the vault keeps for the endpoint ${held_id}: create gives it the vault's."
          fi
          echo "! ${ref}'s resend_webhook answered ${status} on attempt ${attempt} of ${attempts}; asking again in ${pause} s" >&2
          ${MAPI_SLEEP:-sleep} "$pause"
          attempt=$((attempt + 1))
        done
        ;;
    esac
    ;;

  *)
    refuse "usage: provision_project.sh create|wait|configure|keys|owner|pooler|sign-in-link|password|secrets|site|secret-digest|resend-webhook ..."
    ;;
esac
