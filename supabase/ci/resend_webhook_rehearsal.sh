#!/usr/bin/env bash
#
# Each project's endpoint at Resend, rehearsed with no Resend, no Management
# API and no database: supabase/ci/provision_project.sh resend-webhook,
# fleet_secrets.sh's resend_webhook and resend_webhook_delete, and the step
# of deployment_from_empty.yml that makes a new client's.
#
# The endpoint is how a project hears what became of the mail it sent, and
# it is made for real only against Resend's account and a paying client's
# project: a mistake in it is a client whose bounces are never recorded, an
# endpoint whose every event is refused, two endpoints for one project, or a
# signing secret in a public log. So every build runs it here first, against
# the shared stand-ins (fleet_rehearsal_fakes.sh): a Resend that keeps its
# endpoints in files, a Management API that keeps a project's secrets and
# lists their digests, a resend_webhook function that checks the signature
# as the real one does, and a control plane whose vault and register are
# files, all writing what they were asked in one log, in order. What it
# refuses before asking anything; that nothing is made for a project whose
# own database has not been released 20261012050000, asked first on that
# database; that an endpoint is made at the project's own address for the
# six events the function reads, its secret kept in the vault before the
# project is given it, and read back by digest; that one that is right, and
# signed with the secret the vault keeps, is kept, one whose secret the
# vault does not hold or Resend does not sign with is made again, any other
# at the project's address deleted first, and one at another project's
# address only forgotten; that Resend giving no secret leaves no endpoint;
# a busy minute waited out, a deletion answered 404 counted done, and an
# answer lost when one was made never leaving a second nor claiming a
# deletion it did not make; the proof signed as src/lib/email/resend-webhook.ts
# signs (signatures it made are checked here, one with an unpadded key);
# an endpoint that does not prove deleted again, whatever the failure, and
# the checklist unticked whenever one is deleted or none is left working;
# the fleet one client at a time, a client retiring left out, the
# demonstration and the control plane by their refs, a retired client's
# endpoint deleted; the build's step never red, ticking the checklist only
# once proved, and nothing for a client retiring; the reviewer's cases of 9
# October (X1 to X4) among them; and no admin key, no signing secret and no
# address ever printed, except to mask it. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROV="$HERE/provision_project.sh"
SECRETS="$HERE/fleet_secrets.sh"
WF="$ROOT/.github/workflows/deployment_from_empty.yml"
SECRETS_WF="$ROOT/.github/workflows/fleet_secrets.yml"
STEP="The email provider's webhook"
# shellcheck source=supabase/ci/fleet_rehearsal_fakes.sh
. "$HERE/fleet_rehearsal_fakes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
fleet_fakes "$work/bin"
export FAKE_DIR="$work/fake"

PROD=cpcpcpcpcpcpcpcpcpcp
DEMO=dddddddddddddddddddd
ACME=aaaaaaaaaaaaaaaaaaaa
BETA=bbbbbbbbbbbbbbbbbbbb
GAMMA=cccccccccccccccccccc
OMEGA=oooooooooooooooooooo
CP="postgresql://postgres.${PROD}:control-plane-password@pooler.example:5432/postgres"
DEMO_DB="postgresql://postgres.${DEMO}:demonstration-password@pooler.example:5432/postgres"
ADMIN=re_admin_rehearsal_key
SENDING=re_sending_rehearsal_key
TOKEN=rehearsal-access-token
EVENTS='["email.sent","email.delivery_delayed","email.delivered","email.opened","email.complained","email.bounced"]'
# A signing secret, and the signature src/lib/email/resend-webhook.ts's
# webhookSignature() made for it over the proof below, fixed in time
# (id msg_cloveerp_proof_rehearsal, timestamp 1760000000, the body PROOF).
SECRET="whsec_cmVoZWFyc2FsLXNpZ25pbmcta2V5LTAxISEh"
PROOF='{"type":"email.delivered","created_at":"2025-10-09T08:53:20Z","data":{"email_id":"cloveerp-proof-msg_cloveerp_proof_rehearsal"}}'
LIBRARY_SIGNED="KCNsv7EmPJr01w7LNGf7G/vzaKnjpP25RSwiQXWamtU="
OTHER="whsec_b3RoZXItcHJvamVjdHMtc2lnbmluZy1rZXk="
# A key Resend could give with its base64 unpadded, which atob reads and
# openssl does not unless it is padded, and the signature webhookSignature()
# made with it over the same proof (bun, 9 October).
UNPADDED="whsec_dW5wYWRkZWQtc2lnbmluZy1rZXktMA"
UNPADDED_SIGNED="zo1SMEl7zlQishvcNnpgEFZkERHb0SS5mNV4tfPZcHU="
REASON="the rehearsal, every build"

url_of() { printf 'https://%s.supabase.co/functions/v1/resend_webhook' "$1"; }
name_of() { printf 'cloveerp:deployment:%s:resend_webhook' "$1"; }
db_name_of() { printf 'cloveerp:deployment:%s:db_url' "$1"; }
db_url_of() { printf 'postgresql://postgres.%s:client-password@pooler.example:5432/postgres' "$1"; }
# The question create asks a project's own database first.
ASKED="target-keeps-its-own-mail"

BASE_ENV=(FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" PSQL="$work/bin/psql" CURL="$work/bin/curl"
          FAKE_DEMO_URL="$DEMO_DB" CLOVEERP_DEMO_DATABASE_URL="$DEMO_DB"
          MAPI_SLEEP="$work/bin/sleep" SLEEP="$work/bin/sleep" SUPABASE_ACCESS_TOKEN="$TOKEN"
          RESEND_ADMIN_API_KEY="$ADMIN" RESEND_API_KEY="$SENDING" FAKE_RESEND_KEY="$ADMIN"
          APEX=cloveerp.com MAIL_FROM=noreply@cloveerp.com PAUSE_SECONDS=20 TMPDIR="$work/tmp"
          PRODUCTION_REF="$PROD" DEMO_REF="$DEMO")

CASES=0
FAILED=0
# released <ref> [true|false]: the project's database as create finds it:
# its connection kept in the control plane's vault (a client's), and its
# answer to whether it has been released 20261012050000.
released() {
  local target="$1"
  case "$1" in
    "$PROD") target=cp ;;
    "$DEMO") target=demo ;;
    *) printf '%s' "$(db_url_of "$1")" > "$FAKE_DIR/vault/$(db_name_of "$1" | tr ':' '_')" ;;
  esac
  answer "$target" "$ASKED" "${2:-true}"
}
# fresh <name>: a Resend, a vault, a register and projects with nothing in
# them; every project's database released 20261012050000 (released, to
# say otherwise).
fresh() {
  CURRENT="$1"
  rm -rf "$FAKE_DIR" "$work/tmp"
  mkdir -p "$FAKE_DIR/vault" "$FAKE_DIR/resend" "$work/tmp"
  : > "$work/summary"
  out=""; status=0
  for r in "$PROD" "$DEMO" "$ACME" "$BETA" "$GAMMA" "$OMEGA"; do released "$r"; done
}
# unreleased <ref>: its database not reachable at all (no connection kept).
unreleased() {
  rm -f "$FAKE_DIR/vault/$(db_name_of "$1" | tr ':' '_')" "$FAKE_DIR/answers/$1/$ASKED"
}
# endpoint <id> <address> [events] [status]: one Resend already has.
endpoint() {
  jq -cn --arg i "$1" --arg e "$2" --argjson ev "${3:-$EVENTS}" --arg s "${4:-enabled}" --arg k "$OTHER" \
    '{id: $i, endpoint: $e, events: $ev, status: $s, signing_secret: $k}' > "$FAKE_DIR/resend/$1"
}
# kept <ref> <json>: what the control plane's vault keeps for it.
kept() { printf '%s' "$2" > "$FAKE_DIR/vault/$(name_of "$1" | tr ':' '_')"; }
# holds <ref> <secret>: the project's CLOVEERP_RESEND_WEBHOOK_SECRET.
holds() { jq -cn --arg v "$2" '{CLOVEERP_RESEND_WEBHOOK_SECRET: $v}' > "$FAKE_DIR/secrets.held"; }
# prov [VAR=value ...] -- <arguments>: provision_project.sh, as asked.
prov() {
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  out=$(env -u GITHUB_ACTIONS "${BASE_ENV[@]}" ${vars[@]+"${vars[@]}"} bash "$PROV" "$@" 2>&1)
  status=$?
}
# secrets [VAR=value ...] -- <arguments>: fleet_secrets.sh, as asked.
secrets() {
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 \
          "${BASE_ENV[@]}" ${vars[@]+"${vars[@]}"} bash "$SECRETS" "$@" 2>&1)
  status=$?
}
check() {
  CASES=$((CASES + 1))
  if eval "$1"; then
    echo "  ok   $CURRENT: $2"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL $CURRENT: $2"
    printf '%s\n' "$out" | sed 's/^/       | /' | head -n 20
    sed 's/^/       > /' "$FAKE_DIR/order.log" 2> /dev/null | head -n 40
  fi
}
order() { tr '\n' ';' 2> /dev/null < "$FAKE_DIR/order.log"; }
untouched() { [[ ! -s "$FAKE_DIR/order.log" ]]; }
changed_nothing() { ! grep -qE '^(POST|PATCH|DELETE) |vault-put|vault-del' "$FAKE_DIR/order.log" 2> /dev/null; }
vault_of() { cat "$FAKE_DIR/vault/$(name_of "$1" | tr ':' '_')" 2> /dev/null; }
vault_id() { vault_of "$1" | jq -r '.id // empty' 2> /dev/null; }
vault_secret() { vault_of "$1" | jq -r '.secret // empty' 2> /dev/null; }
project_secret() { jq -r '.CLOVEERP_RESEND_WEBHOOK_SECRET // empty' "$FAKE_DIR/secrets.held" 2> /dev/null; }
# at_resend: every endpoint Resend has, as id>address, sorted.
at_resend() { for f in "$FAKE_DIR/resend/"*; do [[ -f "$f" ]] && jq -r '.id + ">" + .endpoint' "$f"; done | LC_ALL=C sort | tr '\n' ' '; }
secret_of() { jq -r '.signing_secret' "$FAKE_DIR/resend/$1" 2> /dev/null; }
# nth <n> <method path>: the body of the nth call so made.
body_of() {
  local n
  n=$(grep -n "^$1\$" "$FAKE_DIR/order.log" | head -n 1 | cut -d: -f1)
  [[ -n "$n" ]] || return 0
  # order.log mixes psql and curl lines; curl numbers its own calls.
  n=$(head -n "$n" "$FAKE_DIR/order.log" | grep -cE '^(GET|POST|PATCH|DELETE) ')
  cat "$FAKE_DIR/body.$n" 2> /dev/null
}
headers_of_call() { cat "$FAKE_DIR/headers.$1" 2> /dev/null; }
# sign_as_resend <secret> <content>: as Resend signs a real event (Svix's
# scheme), the key's base64 padded as atob reads it.
sign_as_resend() {
  local key="${1#whsec_}" hex
  while (( ${#key} % 4 )); do key="${key}="; done
  hex=$(printf '%s' "$key" | openssl base64 -d -A | od -An -vtx1 | tr -d ' \n')
  printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${hex}" -binary | openssl base64 -A
}
sleeps() { grep '^sleep ' "$FAKE_DIR/order.log" 2> /dev/null | cut -d' ' -f2 | tr '\n' ' '; }
events() { cut -d'|' -f1-3 "$FAKE_DIR/events" 2> /dev/null | tr '\n' ' '; }
details() { cat "$FAKE_DIR/events" 2> /dev/null; }
# shown_only_masked <secret>: on a runner, printed on ::add-mask:: lines and
# nowhere else, and masked at least once.
shown_only_masked() {
  [[ -n "$1" && "$(printf '%s\n' "$out" | grep -F -- "$1" | grep -vc '^::add-mask::')" == 0 \
     && "$(printf '%s\n' "$out" | grep -cxF -- "::add-mask::$1")" -ge 1 ]]
}
# tvar <tag> <name>: what the last statement of that tag was given.
tvar() {
  local n
  n=$(awk -v t="$1" '$3 == t { n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  if [[ -n "$n" ]]; then sed -n "s/^$2=//p" "$FAKE_DIR/vars.$n" | head -n 1; fi
}
tsql() {
  local n
  n=$(awk -v t="$1" '$3 == t { n = $1 } END { print n }' "$FAKE_DIR/psql.log" 2> /dev/null)
  if [[ -n "$n" ]]; then cat "$FAKE_DIR/sql.$n"; fi
}
V="psql cp vault-get $(name_of "$ACME")"
# What create asks first: where acme's database is, and whether it has been
# released 20261012050000.
PRE="psql cp vault-get $(db_name_of "$ACME");psql ${ACME} ${ASKED}"
LIST="GET /webhooks?limit=100"
MADE="POST /webhooks"
S_GET="GET /v1/projects/${ACME}/secrets"
S_SET="POST /v1/projects/${ACME}/secrets"

# 1. Refused before anything is asked
fresh "no admin key"
prov RESEND_ADMIN_API_KEY= -- resend-webhook "$ACME" create
check '[[ $status -eq 2 && "$out" == *"RESEND_ADMIN_API_KEY is not set"* && "$out" == *"nothing was asked"* ]] && untouched' "refused, nothing asked"
fresh "a ref that is not one"
prov -- resend-webhook "Acme!" create
check '[[ $status -eq 2 && "$out" == *"not a project ref"* ]] && untouched' "refused, nothing asked"
fresh "an action it does not have"
prov -- resend-webhook "$ACME" rotate
check '[[ $status -eq 2 && "$out" == *"is not create, verify, delete or prove"* ]] && untouched' "refused, nothing asked"
fresh "no control plane"
prov CLOVEERP_LIVE_DATABASE_URL= -- resend-webhook "$ACME" create
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* ]] && untouched' "refused: the vault keeps every endpoint"
fresh "the events it asks for"
check '[[ "$(sed -n "/^const OF_TYPE/,/^};/p" "$ROOT/src/lib/email/resend-webhook.ts" | sed -n "s/^ *\"\(email\.[a-z_]*\)\":.*/\1/p" | jq -R . | jq -cs .)" == "$EVENTS" ]] && grep -qF "events='"'"'${EVENTS}'"'"'" "$PROV"' \
      "the six OF_TYPE reads in src/lib/email/resend-webhook.ts, in its order, and no other"

# 2. Made where there was none
fresh "made"
prov -- resend-webhook "$ACME" create
NEW=$(secret_of wh_fake_1)
check '[[ $status -eq 0 && "$out" == *"resend-webhook=created"* && "$out" == *"id=wh_fake_1"* ]]' "says it was made, and its id"
check '[[ "$(order)" == "${PRE};${V};${LIST};${MADE};psql cp vault-put $(name_of "$ACME");${S_GET};${S_SET};${S_GET};" ]]' \
      "the vault asked, Resend listed, the endpoint made, kept in the vault, and only then the project given it, and read back"
check '[[ "$(body_of "$MADE" | jq -r .endpoint)" == "$(url_of "$ACME")" && "$(body_of "$MADE" | jq -c .events)" == "$EVENTS" ]]' \
      "at the project's own function, for the six events"
check '[[ "$(vault_id "$ACME")" == wh_fake_1 && "$(vault_secret "$ACME")" == "$NEW" && "$(project_secret)" == "$NEW" && -n "$NEW" ]]' \
      "the vault keeps its id and secret, and the project holds the same secret"
check '[[ "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " ]]' "one endpoint"
check '[[ "$(headers_of_call 1)$(headers_of_call 2)" == *"Authorization: Bearer ${ADMIN}"* && "$(cat "$FAKE_DIR"/headers.* | grep -c "$SENDING")" == 0 && "$(headers_of_call 3)" == *"Authorization: Bearer ${TOKEN}"* ]]' \
      "Resend is asked with the admin key, never the sending key; the Management API with the access token"
check '[[ "$out" != *"$NEW"* && "$out" != *"$ADMIN"* && "$out" != *"$TOKEN"* ]]' "neither the secret nor a key is printed"
fresh "made, on a runner"
prov GITHUB_ACTIONS=true -- resend-webhook "$ACME" create
NEW=$(secret_of wh_fake_1)
check '[[ $status -eq 0 ]] && shown_only_masked "$NEW" && shown_only_masked "$(vault_of "$ACME")"' \
      "the secret, and what the vault keeps, masked and printed nowhere else"
check '[[ "$(printf "%s\n" "$out" | grep -nF -- "$NEW" | head -n 1 | cut -d: -f1)" == "$(printf "%s\n" "$out" | grep -nxF -- "::add-mask::${NEW}" | head -n 1 | cut -d: -f1)" ]]' \
      "masked before anything else that could carry it"

# 3. Kept when it is right
fresh "kept"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
holds "$ACME" "$OTHER"
endpoint wh_beta_1 "$(url_of "$BETA")"
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=reused"* && "$out" == *"id=wh_old_1"* ]]' "reused"
check '[[ "$(order)" == "${PRE};${V};${LIST};GET /webhooks/wh_old_1;${S_GET};" ]] && changed_nothing' "read, and nothing changed"
check '[[ "$(at_resend)" == "wh_beta_1>$(url_of "$BETA") wh_old_1>$(url_of "$ACME") " ]]' "another project's endpoint left alone"
fresh "kept, and the project given its secret again"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
holds "$ACME" "whsec_c29tZXRoaW5nLWVsc2U="
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=mended"* && "$(project_secret)" == "$OTHER" && "$(order)" == *"${S_GET};${S_SET};${S_GET};" && "$(order)" != *"POST /webhooks"* ]]' \
      "mended: the endpoint kept, the project given the vault's secret and read back"

# 4. Made again when it is not
fresh "the vault keeps no secret for it"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" '{"id":"wh_old_1"}'
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=recreated"* && "$(order)" == "${PRE};${V};${LIST};GET /webhooks/wh_old_1;DELETE /webhooks/wh_old_1;${MADE};"* ]]' \
      "deleted, then made: a secret Resend gave once is not asked for again"
check '[[ "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " && "$(vault_id "$ACME")" == wh_fake_1 && "$(project_secret)" == "$(secret_of wh_fake_1)" ]]' "one endpoint, kept, held"
fresh "the vault lost, the endpoint not"
endpoint wh_stray_1 "$(url_of "$ACME")"
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=recreated"* && "$(order)" == "${PRE};${V};${LIST};DELETE /webhooks/wh_stray_1;${MADE};"* && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " ]]' \
      "the endpoint nobody keeps deleted first, then one made: never two"
fresh "W6 the one the vault keeps points at another address, and another is at this one"
endpoint wh_old_1 "$(url_of "$BETA")"
endpoint wh_stray_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=recreated"* && "$(order)" == *"GET /webhooks/wh_old_1;psql cp vault-del $(name_of "$ACME");DELETE /webhooks/wh_stray_1;${MADE};"* ]]' \
      "the one elsewhere forgotten (its vault entry removed), the stray here deleted, one made"
check '[[ "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") wh_old_1>$(url_of "$BETA") " && "$(vault_id "$ACME")" == wh_fake_1 && "$(order)" != *"DELETE /webhooks/wh_old_1"* ]]' \
      "the one at another address, which may be that project's, never deleted"
check '[[ "$out" == *"wh_old_1 the vault kept for ${ACME} points at $(url_of "$BETA")"*"may be another project'"'"'s, so it was left at Resend and forgotten"* && "$out" == *"wh_stray_1 at Resend: it is at this project'"'"'s address and the vault does not keep it"* ]]' "each said why"
fresh "it hears other events"
endpoint wh_old_1 "$(url_of "$ACME")" '["email.sent"]'
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=recreated"* && "$(order)" == *"DELETE /webhooks/wh_old_1;${MADE};"* ]]' "made again"
fresh "Resend disabled it"
endpoint wh_old_1 "$(url_of "$ACME")" "$EVENTS" disabled
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"Resend has it disabled"* && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " ]]' "made again"
fresh "a stray on the listing's second page"
endpoint wh_a_1 "$(url_of "$BETA")"
endpoint wh_b_1 "$(url_of "$GAMMA")"
endpoint wh_z_1 "$(url_of "$ACME")"
prov FAKE_RESEND_PAGE=2 -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$(grep "^webhooks" "$FAKE_DIR/resend.lists" | tr "\n" " ")" == "webhooks?limit=100 webhooks?limit=100&after=wh_b_1 " && "$(order)" == *"DELETE /webhooks/wh_z_1;${MADE};"* ]]' \
      "every page read, and the stray on the second found and deleted"
check '[[ "$(at_resend)" == "wh_a_1>$(url_of "$BETA") wh_b_1>$(url_of "$GAMMA") wh_fake_1>$(url_of "$ACME") " ]]' "the others left alone"
fresh "gone at Resend"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=recreated"* && "$(order)" == "${PRE};${V};${LIST};${MADE};"* && "$(vault_id "$ACME")" == wh_fake_1 ]]' "made, nothing to delete"

# 4b. W2: kept only when Resend signs with the secret the vault keeps
fresh "X2 W2 Resend's secret for the kept endpoint is not the vault's (rotated in the dashboard)"
endpoint wh_old_1 "$(url_of "$ACME")"     # Resend signs its events with OTHER
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=recreated"* && "$out" == *"wh_old_1 at Resend: Resend signs its events with another secret than the vault keeps"* && "$(order)" == *"GET /webhooks/wh_old_1;DELETE /webhooks/wh_old_1;${MADE};"* ]]' \
      "not reused: deleted and made again"
check '[[ "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " && "$(vault_secret "$ACME")" == "$(secret_of wh_fake_1)" && "$(project_secret)" == "$(secret_of wh_fake_1)" ]]' \
      "one endpoint, its secret the vault's and the project's"
check '[[ "$out" != *"$OTHER"* && "$out" != *"$SECRET"* && "$out" != *"$(secret_of wh_fake_1)"* ]]' "no secret printed, Resend's or the vault's"
prov -- resend-webhook "$ACME" prove
proved=$status
prov -- resend-webhook "$ACME" verify
verified=$status
# A real event, signed as Resend signs it: with the secret of the endpoint
# Resend now has at the address.
real_id=$(at_resend | cut -d'>' -f1)
real_ts=$(date +%s)
real_body='{"type":"email.delivered","data":{"email_id":"re_1"}}'
real_sig=$(sign_as_resend "$(secret_of "$real_id")" "msg_real_1.${real_ts}.${real_body}")
real=$("$work/bin/curl" -sS -X POST -w '\n%{http_code}' -H "svix-id: msg_real_1" -H "svix-timestamp: ${real_ts}" -H "svix-signature: v1,${real_sig}" --data "$real_body" "$(url_of "$ACME")")
check '[[ $proved -eq 0 && $verified -eq 0 && "${real##*$'"'"'\n'"'"'}" == 200 ]]' "proved, verified, and a real event from the endpoint Resend has is taken"
fresh "W2 Resend will not say which secret the kept endpoint signs with"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
holds "$ACME" "$OTHER"
prov FAKE_RESEND_SECRET_UNREADABLE=yes -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=recreated"* && "$out" == *"Resend would not say which secret it signs with"* && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " && "$(vault_id "$ACME")" == wh_fake_1 ]]' \
      "not trusted: made again, and the secret Resend gave when it made it kept"
fresh "W2 verified, Resend signing with another secret than the vault keeps"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov -- resend-webhook "$ACME" verify
check '[[ $status -eq 2 && "$out" == *"signs the endpoint wh_old_1'"'"'s events with another secret than the vault keeps"* && "$out" != *"$SECRET"* && "$out" != *"$OTHER"* ]] && changed_nothing' \
      "refused, printing neither, changing nothing"
fresh "W2 verified, Resend not saying which secret it signs with"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
holds "$ACME" "$OTHER"
prov FAKE_RESEND_SECRET_UNREADABLE=yes -- resend-webhook "$ACME" verify
check '[[ $status -eq 2 && "$out" == *"would not say which secret the endpoint wh_old_1 signs with"* ]] && changed_nothing' "refused"
fresh "W2 Resend's secret masked on a runner before it could be printed"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov GITHUB_ACTIONS=true -- resend-webhook "$ACME" create
check '[[ $status -eq 0 ]] && shown_only_masked "$OTHER" && shown_only_masked "$(secret_of wh_fake_1)"' "masked, and printed nowhere else"

# 5. The signing secret Resend gives
fresh "no secret when made, given when asked"
prov FAKE_RESEND_NO_SECRET=yes -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$(order)" == "${PRE};${V};${LIST};${MADE};GET /webhooks/wh_fake_1;psql cp vault-put"* && "$(vault_secret "$ACME")" == "$(secret_of wh_fake_1)" ]]' \
      "asked for once, then kept"
fresh "no secret at all"
prov FAKE_RESEND_NO_SECRET=yes FAKE_RESEND_SECRET_UNREADABLE=yes -- resend-webhook "$ACME" create
check '[[ $status -eq 3 && "$out" == *"gave no signing secret"* && "$(order)" == "${PRE};${V};${LIST};${MADE};GET /webhooks/wh_fake_1;DELETE /webhooks/wh_fake_1;" ]]' \
      "refused, and the endpoint deleted: none is left whose events nobody can check"
check '[[ -z "$(at_resend)" && -z "$(vault_of "$ACME")" && ! -e "$FAKE_DIR/secrets.held" ]]' "the vault and the project as they were"

# 6. Busy minutes, lost answers, refusals
fresh "a busy minute"
prov FAKE_RESEND_STATUSES=429,200 -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$(sleeps)" == "5 " && "$(grep -c "^GET /webhooks?limit=100$" "$FAKE_DIR/order.log")" == 2 && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " ]]' \
      "waited out, as mapi waits, then made"
fresh "a busy minute when it is made"
prov FAKE_RESEND_STATUSES=200,429,200 -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$(grep -c "^POST /webhooks$" "$FAKE_DIR/order.log")" == 2 && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " ]]' \
      "a 429 says nothing was made, so it is asked again; one endpoint"
fresh "the answer lost when it was made"
prov FAKE_RESEND_CREATE_LOST=yes -- resend-webhook "$ACME" create
check '[[ $status -eq 3 && "$out" == *"Resend did not say it made the endpoint"* && "$out" == *"Run this again"* ]]' "refused, saying to run it again"
check '[[ "$(grep -c "^POST /webhooks$" "$FAKE_DIR/order.log")" == 1 && "$(order)" == *"${MADE};${LIST};DELETE /webhooks/wh_fake_1;" && -z "$(at_resend)" ]]' \
      "never asked twice; what it made found and deleted"
check '[[ -z "$(vault_of "$ACME")" && ! -e "$FAKE_DIR/secrets.held" && "$out" == *"Nothing is at $(url_of "$ACME") now"* ]]' "the vault and the project as they were, and that said"
fresh "X4 W5 the answer lost when it was made, and the listing after it fails too"
prov FAKE_RESEND_CREATE_LOST=yes FAKE_RESEND_STATUSES=200,200,500 MAPI_ATTEMPTS=2 -- resend-webhook "$ACME" create
check '[[ $status -eq 3 && "$out" == *"could not be listed again, so one it made may still be at $(url_of "$ACME")"* && "$out" == *"The next create deletes every endpoint at that address the vault does not keep"* ]]' \
      "red, saying truthfully that an endpoint may remain, and that the next create deletes it"
check '[[ "$out" != *"has been deleted"* && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " && -z "$(vault_of "$ACME")" && ! -e "$FAKE_DIR/secrets.held" ]]' \
      "never claiming a deletion it did not make: the stray is there, kept by nobody"
prov -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$(order)" == *"DELETE /webhooks/wh_fake_1;${MADE};"* && "$(at_resend)" == "wh_fake_2>$(url_of "$ACME") " && "$(vault_id "$ACME")" == wh_fake_2 ]]' \
      "the next create deletes the stray at the address, then makes one: never two"
fresh "W5 the answer lost when it was made, and what it made not deletable"
prov FAKE_RESEND_CREATE_LOST=yes FAKE_RESEND_STATUSES=200,200,200,403 -- resend-webhook "$ACME" create
check '[[ $status -eq 3 && "$out" == *"and wh_fake_1 at $(url_of "$ACME"), kept by nobody, could not be deleted"* && "$out" == *"The next create deletes it"* && "$out" != *"Nothing is at"* ]]' \
      "red, naming what is left"
fresh "X3 W4 a DELETE whose answer is lost (done at Resend, 502 to the caller)"
endpoint wh_stray_1 "$(url_of "$ACME")"
prov FAKE_RESEND_DELETE_LOST=yes -- resend-webhook "$ACME" create
check '[[ $status -eq 0 && "$out" == *"resend-webhook=recreated"* && "$(order)" == *"DELETE /webhooks/wh_stray_1;sleep 5;DELETE /webhooks/wh_stray_1;${MADE};"* && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " ]]' \
      "asked again, answered 404, and counted deleted: then one made"
check '[[ "$out" == *"wh_stray_1 is not at Resend (404), so it is deleted already"* && "$out" != *"x Resend DELETE"* ]]' "said so, and not as a failure"
fresh "W4 a deletion of a retired client's endpoint whose answer is lost"
endpoint wh_old_9 "$(url_of "$OMEGA")"
kept "$OMEGA" "{\"id\":\"wh_old_9\",\"secret\":\"${OTHER}\"}"
prov FAKE_RESEND_DELETE_LOST=yes -- resend-webhook "$OMEGA" delete
check '[[ $status -eq 0 && "$out" == *"deleted=1"* && -z "$(at_resend)" && -z "$(vault_of "$OMEGA")" ]]' "counted deleted, and the vault's entry removed"
fresh "W4 a deletion refused for another reason is still a failure"
endpoint wh_stray_1 "$(url_of "$ACME")"
prov FAKE_RESEND_STATUSES=200,403 -- resend-webhook "$ACME" create
check '[[ $status -eq 3 && "$out" == *"answered 403"* && "$out" == *"could not be deleted at Resend"* && "$(order)" != *"${MADE}"* ]]' "refused, nothing made"
fresh "a key without the permission"
prov FAKE_RESEND_KEY=someone-else -- resend-webhook "$ACME" create
check '[[ $status -eq 2 && "$out" == *"answered 401"* && "$out" == *"could not be listed"* ]] && changed_nothing' "refused, nothing changed"
fresh "a vault that will not keep it"
prov FAKE_VAULT_PUT_FAIL=resend_webhook -- resend-webhook "$ACME" create
check '[[ $status -eq 3 && "$out" == *"could not be kept in the control plane'"'"'s vault"* && "$(order)" == *"psql cp vault-put $(name_of "$ACME");DELETE /webhooks/wh_fake_1;" ]]' \
      "refused, and what was made deleted"
check '[[ -z "$(at_resend)" && ! -e "$FAKE_DIR/secrets.held" ]]' "the project never given a secret nobody keeps"
fresh "a project whose secrets cannot be read"
prov MAPI_ATTEMPTS=1 FAKE_SECRETS_LIST_STATUSES=403 -- resend-webhook "$ACME" create
check '[[ $status -eq 3 && "$out" == *"GET /v1/projects/${ACME}/secrets failed"* && "$out" != *"resend-webhook="* && "$(order)" != *"${S_SET}"* && "$(vault_id "$ACME")" == wh_fake_1 ]]' \
      "refused before the project is given anything, the endpoint kept in the vault for the next run"
fresh "a project that will not take the secret, then a second run"
prov FAKE_SECRETS_STATUSES=400 -- resend-webhook "$ACME" create
first=$status
FIRST_OUT="$out"
prov -- resend-webhook "$ACME" create
check '[[ $first -eq 3 && "$FIRST_OUT" == *"did not take its CLOVEERP_RESEND_WEBHOOK_SECRET"* && "$FIRST_OUT" == *"Run this again"* ]]' "refused, saying to run it again"
check '[[ $status -eq 0 && "$out" == *"resend-webhook=mended"* && "$(project_secret)" == "$(vault_secret "$ACME")" && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " ]]' \
      "the second run keeps the endpoint the vault kept and gives the project its secret"

# 7. Verified, changing nothing
fresh "verified"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
holds "$ACME" "$OTHER"
prov -- resend-webhook "$ACME" verify
check '[[ $status -eq 0 && "$out" == *"resend-webhook=verified"* && "$(order)" == "${V};${LIST};GET /webhooks/wh_old_1;${S_GET};" ]] && changed_nothing' "verified, nothing changed"
fresh "verified, with nothing in the vault"
endpoint wh_old_1 "$(url_of "$ACME")"
prov -- resend-webhook "$ACME" verify
check '[[ $status -eq 2 && "$out" == *"keeps no endpoint and secret"* && "$out" == *"make it with create"* ]] && changed_nothing' "refused"
fresh "verified, pointing elsewhere"
endpoint wh_old_1 "https://elsewhere.example/hook"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
holds "$ACME" "$OTHER"
prov -- resend-webhook "$ACME" verify
check '[[ $status -eq 2 && "$out" == *"points at https://elsewhere.example/hook"* ]] && changed_nothing' "refused"
fresh "verified, with a stray at the address"
endpoint wh_old_1 "$(url_of "$ACME")"
endpoint wh_stray_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
holds "$ACME" "$OTHER"
prov -- resend-webhook "$ACME" verify
check '[[ $status -eq 2 && "$out" == *"Resend also has wh_stray_1"* ]] && changed_nothing' "refused, naming it"
fresh "verified, the project holding another secret"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
holds "$ACME" "$SECRET"
prov -- resend-webhook "$ACME" verify
check '[[ $status -eq 2 && "$out" == *"is not the signing secret the vault keeps"* && "$out" != *"$SECRET"* && "$out" != *"$OTHER"* ]] && changed_nothing' "refused, printing neither"
fresh "verified, gone at Resend"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov -- resend-webhook "$ACME" verify
check '[[ $status -eq 2 && "$out" == *"Resend has no endpoint wh_old_1"* ]] && changed_nothing' "refused"

# 8. Deleted, for a client retired
fresh "deleted"
endpoint wh_old_1 "$(url_of "$ACME")"
endpoint wh_stray_1 "$(url_of "$ACME")"
endpoint wh_beta_1 "$(url_of "$BETA")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov -- resend-webhook "$ACME" delete
check '[[ $status -eq 0 && "$out" == *"resend-webhook=deleted"* && "$out" == *"deleted=2"* && "$(order)" == "${V};${LIST};DELETE /webhooks/wh_old_1;DELETE /webhooks/wh_stray_1;psql cp vault-del $(name_of "$ACME");" ]]' \
      "every endpoint at its address deleted, then the vault's entry"
check '[[ "$(at_resend)" == "wh_beta_1>$(url_of "$BETA") " && -z "$(vault_of "$ACME")" ]]' "another project's left alone"
fresh "W6 deleted, the one the vault keeps pointing at another project's address"
endpoint wh_old_1 "$(url_of "$BETA")"
endpoint wh_stray_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov -- resend-webhook "$ACME" delete
check '[[ $status -eq 0 && "$out" == *"deleted=1"* && "$(at_resend)" == "wh_old_1>$(url_of "$BETA") " && -z "$(vault_of "$ACME")" && "$(order)" != *"DELETE /webhooks/wh_old_1"* ]]' \
      "the one at this address deleted; the other, which may be that project's, left at Resend and forgotten"
check '[[ "$out" == *"wh_old_1 the vault keeps for ${ACME} points at $(url_of "$BETA")"*"left at Resend and only forgotten"* ]]' "and said"
fresh "a deletion Resend refuses"
endpoint wh_old_1 "$(url_of "$ACME")"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov MAPI_ATTEMPTS=1 FAKE_RESEND_STATUSES=200,500 -- resend-webhook "$ACME" delete
check '[[ $status -eq 2 && "$out" == *"could not be deleted at Resend"* && "$out" == *"the vault keeps"* && -n "$(vault_of "$ACME")" && "$(order)" != *"vault-del"* ]]' \
      "refused, and the vault keeps it for the next run"
fresh "nothing left at Resend"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${OTHER}\"}"
prov -- resend-webhook "$ACME" delete
check '[[ $status -eq 0 && "$out" == *"deleted=0"* && -z "$(vault_of "$ACME")" ]]' "the vault's entry removed"

# 9. Proved by a signed event
fresh "proved"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov RESEND_ADMIN_API_KEY= WEBHOOK_PROVE_TIME=1760000000 WEBHOOK_PROVE_ID=msg_cloveerp_proof_rehearsal -- resend-webhook "$ACME" prove
check '[[ $status -eq 0 && "$out" == *"resend-webhook=proved"* && "$(order)" == "${V};POST /functions/v1/resend_webhook;" ]]' \
      "one post to the project's function, with no admin key needed"
check '[[ "$(cat "$FAKE_DIR/body.1")" == "$PROOF" && "$(cat "$FAKE_DIR/webhook.posts")" == "msg_cloveerp_proof_rehearsal|1760000000|v1,${LIBRARY_SIGNED}|taken" ]]' \
      "signed exactly as src/lib/email/resend-webhook.ts signs"
check '[[ "$(cat "$FAKE_DIR/body.1")" != *"@"* && "$out" != *"$SECRET"* && "$out" != *"$LIBRARY_SIGNED"* ]]' "no address in it, and nothing secret printed"
fresh "W7 proved with a signing key whose base64 is not padded"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${UNPADDED}\"}"
holds "$ACME" "$UNPADDED"
prov RESEND_ADMIN_API_KEY= WEBHOOK_PROVE_TIME=1760000000 WEBHOOK_PROVE_ID=msg_cloveerp_proof_rehearsal -- resend-webhook "$ACME" prove
check '[[ $status -eq 0 && "$(cat "$FAKE_DIR/webhook.posts")" == "msg_cloveerp_proof_rehearsal|1760000000|v1,${UNPADDED_SIGNED}|taken" ]]' \
      "padded before it is read, so it signs as webhookSignature() signs with atob, and is taken"
check '[[ $(( (${#UNPADDED} - 6) % 4 )) -ne 0 && -z "$(printf "%s" "${UNPADDED#whsec_}" | openssl base64 -d -A 2> /dev/null)" ]]' \
      "a key openssl alone reads nothing of"
fresh "proved now"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov -- resend-webhook "$ACME" prove
check '[[ $status -eq 0 && "$(cut -d"|" -f4 "$FAKE_DIR/webhook.posts")" == taken && "$(( $(date +%s) - $(cut -d"|" -f2 "$FAKE_DIR/webhook.posts") ))" -lt 60 ]]' \
      "signed at the time it is sent, and taken"
fresh "a function holding another secret"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$OTHER"
prov WEBHOOK_PROVE_ATTEMPTS=3 -- resend-webhook "$ACME" prove
check '[[ $status -eq 2 && "$out" == *"did not take the signed event in 3 attempt(s)"* && "$(grep -c "|refused$" "$FAKE_DIR/webhook.posts")" == 3 && "$(sleeps)" == "10 10 " ]]' \
      "asked again, then refused, saying create gives it the vault's"
fresh "a secret that reaches the function late"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov FAKE_WEBHOOK_STATUSES=401,200 -- resend-webhook "$ACME" prove
check '[[ $status -eq 0 && "$(wc -l < "$FAKE_DIR/webhook.posts" | tr -d " ")" == 2 && "$(sleeps)" == "10 " ]]' "asked again, and proved"
fresh "a function busy for a moment"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov FAKE_WEBHOOK_STATUSES=503,200 -- resend-webhook "$ACME" prove
check '[[ $status -eq 0 && "$(sleeps)" == "10 " ]]' "asked again, and proved"
fresh "a gateway that asks for a signed-in caller"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov FAKE_WEBHOOK_STATUSES=401 'FAKE_WEBHOOK_REFUSAL={"code":401,"message":"Missing authorization header"}' -- resend-webhook "$ACME" prove
check '[[ $status -eq 2 && "$out" == *"verify_jwt must be false"* && "$(wc -l < "$FAKE_DIR/webhook.posts" | tr -d " ")" == 1 ]]' "refused at once, naming verify_jwt"
fresh "a database that records what is not its own"
kept "$ACME" "{\"id\":\"wh_old_1\",\"secret\":\"${SECRET}\"}"
holds "$ACME" "$SECRET"
prov 'FAKE_WEBHOOK_ANSWER={"recorded":true}' -- resend-webhook "$ACME" prove
check '[[ $status -eq 4 && "$out" == *"keeps other projects'"'"' events"* ]]' "refused apart (4), so the caller deletes the endpoint again"
fresh "nothing to sign with"
prov -- resend-webhook "$ACME" prove
check '[[ $status -eq 2 && "$out" == *"keeps no signing secret"* && ! -e "$FAKE_DIR/webhook.posts" ]]' "refused, nothing sent"

# 10. The fleet's: fleet_secrets.sh resend_webhook and resend_webhook_delete
register() {
  answer cp cp-held-known true
  answer cp "cp-rows@all" "acme|live|${ACME}|acme|" "beta|built|${BETA}|beta|" "gamma|suspended|${GAMMA}|gamma|"
  answer cp "cp-rows@acme" "acme|live|${ACME}|acme|"
  answer cp "cp-rows@beta" "beta|built|${BETA}|beta|"
  answer cp "cp-rows@gamma" "gamma|suspended|${GAMMA}|gamma|"
  answer cp "cp-rows@omega" "omega|retired|${OMEGA}|omega|"
  answer cp cp-has-checklist-by-build true
  # What the build reads of acme just before its webhook.
  answer cp cp-row "status=building" "ref=${ACME}" "api_url=https://${ACME}.supabase.co"
}
fresh "the fleet's, without the admin key"
register
secrets RESEND_ADMIN_API_KEY= GITHUB_ACTIONS=true -- resend_webhook all "$REASON"
check '[[ $status -eq 0 && "$out" == *"::notice::RESEND_ADMIN_API_KEY is not set"* && "$out" != *"::error::"* ]] && untouched' "a notice, green, nothing touched"
check '[[ "$(cat "$work/summary")" == *"RESEND_ADMIN_API_KEY is not set, so nothing was changed"* ]]' "the summary says so"
fresh "deleting the fleet's"
secrets -- resend_webhook_delete all "$REASON"
check '[[ $status -eq 2 && "$out" == *"one retiring or retired client at a time"* ]] && untouched' "refused"
fresh "one client's"
register
secrets -- resend_webhook acme "$REASON"
check '[[ $status -eq 0 && "$out" == *"acme: the email provider'"'"'s webhook created (wh_fake_1) and proved"* ]]' "made and proved"
check '[[ "$(order)" == "psql cp cp-held-known;psql cp cp-rows;psql cp cp-rows;${PRE};${V};${LIST};${MADE};psql cp vault-put $(name_of "$ACME");${S_GET};${S_SET};${S_GET};${V};POST /functions/v1/resend_webhook;psql cp cp-has-checklist-by-build;psql cp cp-checklist-by-build;event acme note done;" ]]' \
      "the register read again just before; made, kept, given, proved, ticked, then the row"
check '[[ "$(tvar cp-checklist-by-build code)" == acme && "$(tvar cp-checklist-by-build item)" == resend_webhook && "$(tvar cp-checklist-by-build done)" == true && "$(tsql cp-checklist-by-build)" == *"set statement_timeout"* && "$(tsql cp-checklist-by-build)" == *"erp_meta.deployment_checklist_by_build(:'"'"'code'"'"', :'"'"'item'"'"', (:'"'"'done'"'"')::boolean)"* ]]' \
      "ticked (done true) through erp_meta.deployment_checklist_by_build, as psql variables, under a timeout"
check '[[ "$(tsql cp-has-checklist-by-build)" == *"to_regprocedure('"'"'erp_meta.deployment_checklist_by_build(text,text,boolean)'"'"')"* && "$(tsql "$ASKED")" == *"to_regprocedure('"'"'erp_meta.deployment_checklist_by_build(text,text,boolean)'"'"')"* && "$(tsql "$ASKED")" == *"set statement_timeout"* ]]' \
      "the control plane and acme's own database each asked for the routine with its three arguments"
check '[[ "$(awk -v t="$ASKED" '"'"'$3 == t { print $2 }'"'"' "$FAKE_DIR/psql.log")" == "$ACME" && "$(tvar "$ASKED" VERBOSITY)" == terse ]]' \
      "W1 asked on acme's own database (its connection from the vault), before anything of Resend"
check '[[ "$(details)" == "acme|note|done|the email provider'"'"'s webhook created (wh_fake_1) and proved: a signed event reached its function, which recorded nothing; the checklist'"'"'s step ticked by the build (fleet_secrets.yml: ${REASON})" ]]' \
      "the row says what was done and why"
check '[[ "$(cut -d"|" -f4 "$FAKE_DIR/webhook.posts")" == taken ]]' "the proof taken by the function"
fresh "the whole fleet's, on a runner"
register
secrets GITHUB_ACTIONS=true -- resend_webhook all "$REASON"
check '[[ $status -eq 0 && "$out" == *"resend_webhook: 3 client(s) done"* && "$(events)" == "acme|note|done beta|note|done gamma|note|done " ]]' "every client up"
check '[[ "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") wh_fake_2>$(url_of "$BETA") wh_fake_3>$(url_of "$GAMMA") " && "$(vault_id "$BETA")" == wh_fake_2 && "$(sleeps)" == "20 20 " ]]' \
      "each its own endpoint at its own address, kept under its own ref, a pause between"
check 'shown_only_masked "$(secret_of wh_fake_1)" && shown_only_masked "$(secret_of wh_fake_2)" && shown_only_masked "$(secret_of wh_fake_3)" && [[ "$(details)$(cat "$work/summary")" != *"whsec_"* && "$out" != *"$ADMIN"* ]]' \
      "no secret printed but to mask it, none on a row or in the summary, and not the key"
fresh "a busy minute in the middle of the fleet"
register
secrets FAKE_RESEND_STATUSES=200,200,200,429,200 -- resend_webhook all "$REASON"
check '[[ $status -eq 0 && "$(events)" == "acme|note|done beta|note|done gamma|note|done " && "$(sleeps)" == *"5 "* ]]' "waited out, and every client done"
fresh "the first client fails"
register
secrets FAKE_RESEND_KEY=someone-else -- resend_webhook all "$REASON"
check '[[ $status -eq 1 && "$out" == *"acme'"'"'s endpoint at Resend was not made or found right"* && "$out" == *"Not touched, because acme failed first: beta gamma"* && "$(events)" == "acme|note|failed " ]]' \
      "red at acme, the rest untouched and named"
fresh "a control plane without the routine"
register
answer cp cp-has-checklist-by-build false
secrets -- resend_webhook acme "$REASON"
check '[[ $status -eq 0 && "$(order)" != *"cp-checklist-by-build"* && "$(details)" == *"the checklist keeps the step for the owner until the control plane has erp_meta.deployment_checklist_by_build"* ]]' \
      "made and proved, the step left for the owner, and green"
fresh "a client whose database keeps what is not its own"
register
secrets 'FAKE_WEBHOOK_ANSWER={"recorded":true}' -- resend_webhook acme "$REASON"
check '[[ $status -eq 1 && "$out" == *"would keep other projects'"'"' recipients, so its endpoint wh_fake_1 was deleted again at Resend, with its entry in the vault; the checklist'"'"'s step unticked"* && -z "$(at_resend)" && -z "$(vault_of "$ACME")" ]]' \
      "red, and the endpoint it made deleted again at once, with its vault entry"
check '[[ "$(order)" == *"POST /functions/v1/resend_webhook;${V};${LIST};DELETE /webhooks/wh_fake_1;psql cp vault-del $(name_of "$ACME");psql cp cp-has-checklist-by-build;psql cp cp-checklist-by-build;event acme note failed;" && "$(tvar cp-checklist-by-build done)" == false ]]' \
      "deleted right after the proof, then W3 unticked (done false), never ticked"
# W1: any proof that fails, not only one the database recorded.
fresh "X1 W1 a released database whose function never takes the proof (401 throughout)"
register
secrets FAKE_WEBHOOK_STATUSES=401 -- resend_webhook acme "$REASON"
check '[[ $status -eq 1 && -z "$(at_resend)" && -z "$(vault_of "$ACME")" && "$(wc -l < "$FAKE_DIR/webhook.posts" | tr -d " ")" == 6 ]]' \
      "asked six times, then red, and no endpoint left, nor its vault entry"
check '[[ "$out" == *"its function did not take a signed event as it should"*"so its endpoint wh_fake_1 was deleted again at Resend, with its entry in the vault; the checklist'"'"'s step unticked"* && "$(tvar cp-checklist-by-build done)" == false && "$(events)" == "acme|note|failed " ]]' \
      "said so, unticked, and the row says it failed"
fresh "X1b W1 the function answers 500 throughout"
register
secrets FAKE_WEBHOOK_STATUSES=500 -- resend_webhook acme "$REASON"
check '[[ $status -eq 1 && -z "$(at_resend)" && -z "$(vault_of "$ACME")" && "$(tvar cp-checklist-by-build done)" == false ]]' "no endpoint left, unticked"
fresh "X1 W1 a database that has not been released 20261012050000"
register
released "$ACME" false
secrets FAKE_WEBHOOK_STATUSES=401 -- resend_webhook acme "$REASON"
check '[[ $status -eq 1 && -z "$(at_resend)" && "$out" == *"acme'"'"'s database has not been released 20261012050000"* && "$out" == *"nothing was asked of Resend"* ]]' \
      "red, and nothing made"
check '[[ "$(order)" == "psql cp cp-held-known;psql cp cp-rows;psql cp cp-rows;${PRE};event acme note failed;" ]]' \
      "nothing asked of Resend, nothing kept, nothing unticked: nothing was there to untick"
fresh "W1 a database that cannot be reached"
register
unreleased "$ACME"
secrets -- resend_webhook acme "$REASON"
check '[[ $status -eq 1 && -z "$(at_resend)" && "$out" == *"has no cloveerp:deployment:${ACME}:db_url"* && "$(order)" == "psql cp cp-held-known;psql cp cp-rows;psql cp cp-rows;psql cp vault-get $(db_name_of "$ACME");event acme note failed;" ]]' \
      "red, and nothing asked of Resend"
fresh "W3 an endpoint left part-way (the project will not take its secret)"
register
secrets FAKE_SECRETS_STATUSES=400 -- resend_webhook acme "$REASON"
check '[[ $status -eq 1 && "$out" == *"left part-way, with none its function takes the events of"* && "$(tvar cp-checklist-by-build done)" == false && "$(order)" != *"POST /functions"* ]]' \
      "red, unticked, and never proved"
fresh "W3 nothing changed (Resend refused the listing): nothing unticked"
register
secrets FAKE_RESEND_KEY=someone-else -- resend_webhook acme "$REASON"
check '[[ $status -eq 1 && "$out" == *"nothing was changed"* && "$(order)" != *"checklist"* ]]' "red, the checklist as it was"
fresh "W3 an untick the control plane cannot make yet"
register
answer cp cp-has-checklist-by-build false
secrets FAKE_WEBHOOK_STATUSES=401 -- resend_webhook acme "$REASON"
check '[[ $status -eq 1 && -z "$(at_resend)" && "$out" == *"the checklist'"'"'s step left as it was: the control plane has no erp_meta.deployment_checklist_by_build yet"* ]]' "said"
# D4: a client going has its endpoint deleted, never made.
fresh "D4 the whole fleet's, a client retiring among them"
register
answer cp "cp-rows@all" "acme|live|${ACME}|acme|" "delta|retiring|${OMEGA}|delta|" "gamma|suspended|${GAMMA}|gamma|"
secrets -- resend_webhook all "$REASON"
check '[[ $status -eq 0 && "$out" == *"left out, because they are retiring (resend_webhook_delete deletes their endpoints): delta"* && "$(events)" == "acme|note|done gamma|note|done " ]]' \
      "left out, said, and the rest done"
check '[[ "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") wh_fake_2>$(url_of "$GAMMA") " && "$(cat "$work/summary")" == *"- left out, because they are retiring: delta"* ]]' \
      "no endpoint made for it, and the summary says so"
fresh "D4 a retiring client named"
register
answer cp "cp-rows@delta" "delta|retiring|${OMEGA}|delta|"
secrets -- resend_webhook delta "$REASON"
check '[[ $status -eq 2 && "$out" == *"delta is retiring, so no endpoint is made for it"* && "$(order)" == "psql cp cp-held-known;psql cp cp-rows;" ]]' "refused, nothing asked"
fresh "D4 a client retiring by its turn"
register
answer cp "cp-rows@beta" "beta|retiring|${BETA}|beta|"
secrets -- resend_webhook all "$REASON"
check '[[ $status -eq 0 && "$out" == *"beta is retiring now, so it was left alone"* && "$(events)" == "acme|note|done gamma|note|done " && "$(at_resend)" != *"$BETA"* ]]' \
      "left alone when its turn came"
fresh "a tick the control plane refuses"
register
answer cp cp-checklist-by-build "ERROR:  CLOVEERP_CHECKLIST_REFUSED: no"
secrets -- resend_webhook acme "$REASON"
check '[[ $status -eq 0 && "$(details)" == *"could not be ticked"* && "$(events)" == "acme|note|done " ]]' "made and proved, said, and green"
fresh "the demonstration's"
secrets -- resend_webhook demonstration "$REASON"
check '[[ $status -eq 0 && "$out" == *"demonstration: the email provider'"'"'s webhook created (wh_fake_1) and proved"* && "$(at_resend)" == "wh_fake_1>$(url_of "$DEMO") " && "$(vault_id "$DEMO")" == wh_fake_1 ]]' \
      "made at the demonstration's project, kept under its ref"
check '[[ "$(order)" != *"cp-rows"* && "$(order)" != *"checklist"* && ! -e "$FAKE_DIR/events" ]]' "no register read, no row, no checklist: it is in no register"
check '[[ "$(order)" == "psql demo ${ASKED};"* && "$(order)" != *"$(db_name_of "$DEMO")"* ]]' "W1 its own database asked first, through CLOVEERP_DEMO_DATABASE_URL"
fresh "the demonstration's, its database not released"
released "$DEMO" false
secrets -- resend_webhook demonstration "$REASON"
check '[[ $status -eq 1 && "$out" == *"demonstration'"'"'s database has not been released 20261012050000"* && "$(order)" == "psql demo ${ASKED};" ]]' "red, nothing asked of Resend"
fresh "the demonstration's, its database not given"
secrets CLOVEERP_DEMO_DATABASE_URL= -- resend_webhook demonstration "$REASON"
check '[[ $status -eq 1 && "$out" == *"cannot be reached"* && "$(order)" == "psql cp vault-get $(db_name_of "$DEMO");" ]]' "red, nothing asked of Resend"
fresh "the control plane's"
secrets -- resend_webhook control "$REASON"
check '[[ $status -eq 0 && "$(at_resend)" == "wh_fake_1>$(url_of "$PROD") " && "$(vault_id "$PROD")" == wh_fake_1 && "$(cat "$work/summary")" == *"- control: the email provider'"'"'s webhook created"* ]]' \
      "made at the control plane's project"
check '[[ "$(order)" == "psql cp ${ASKED};"* ]]' "W1 the control plane's own database asked first"
fresh "the control plane's, whose proof fails"
secrets FAKE_WEBHOOK_STATUSES=401 -- resend_webhook control "$REASON"
check '[[ $status -eq 1 && -z "$(at_resend)" && -z "$(vault_of "$PROD")" && "$(order)" != *"checklist"* ]]' "deleted again, and no checklist to untick"
fresh "the demonstration's, with no ref for it"
secrets DEMO_REF= -- resend_webhook demonstration "$REASON"
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_DEMO_PROJECT_REF"* ]] && untouched' "refused, nothing touched"
fresh "a retired client's deleted"
register
endpoint wh_old_9 "$(url_of "$OMEGA")"
kept "$OMEGA" "{\"id\":\"wh_old_9\",\"secret\":\"${OTHER}\"}"
secrets -- resend_webhook_delete omega "$REASON"
check '[[ $status -eq 0 && -z "$(at_resend)" && -z "$(vault_of "$OMEGA")" && "$(details)" == "omega|note|done|the email provider'"'"'s webhook deleted (1 endpoint(s) at Resend), and its entry in the control plane'"'"'s vault; the checklist'"'"'s step unticked (fleet_secrets.yml: ${REASON})" ]]' \
      "its endpoint and its vault entry gone, the step unticked, and its row says so"
check '[[ "$(tvar cp-checklist-by-build code)" == omega && "$(tvar cp-checklist-by-build done)" == false && "$(order)" != *"$ASKED"* ]]' "W3 unticked (done false); no database asked to delete"
fresh "a retired client's deleted, the control plane refusing the untick"
register
answer cp cp-checklist-by-build "ERROR:  CLOVEERP_DEPLOYMENT_STATE: omega is retired"
endpoint wh_old_9 "$(url_of "$OMEGA")"
secrets -- resend_webhook_delete omega "$REASON"
check '[[ $status -eq 0 && -z "$(at_resend)" && "$(details)" == *"the checklist'"'"'s step could not be unticked (the line above says why)"* ]]' "deleted, green, and said"
fresh "a live client's not deleted"
register
endpoint wh_old_1 "$(url_of "$ACME")"
secrets -- resend_webhook_delete acme "$REASON"
check '[[ $status -eq 2 && "$out" == *"acme is live, so its webhook is not deleted"* && "$(at_resend)" == "wh_old_1>$(url_of "$ACME") " ]] && changed_nothing' "refused, nothing changed"

# 11. The build's step (deployment_from_empty.yml), as the runner runs it
fresh "the build's steps"
steps=$(sed -n 's/^      - name: //p' "$WF" | tr '\n' ';')
check '[[ "$steps" == *"The functions'"'"' secrets;${STEP};Prove it;"* ]]' "after the functions' secrets, before the proof that marks it built"
block=$(awk -v s="      - name: ${STEP}" '$0 == s { on = 1; next } on && /^ *run:/ { exit } on' "$WF")
check '[[ "$block" == *"if: env.KIND == '"'"'client'"'"'"* && "$block" == *"RESEND_ADMIN_API_KEY: \${{ secrets.RESEND_ADMIN_API_KEY }}"* ]]' \
      "for a client, the admin key given to this step alone"
script=$(workflow_step "$WF" "$STEP")
# build [VAR=value ...]: the step, from the repository's root, against the stand-ins.
build() {
  : > "$work/env"
  out=$(cd "$ROOT" && env -u GITHUB_ACTIONS -u CURL -u PSQL PATH="$work/bin:$PATH" FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" \
          SUPABASE_ACCESS_TOKEN="$TOKEN" RESEND_ADMIN_API_KEY="$ADMIN" FAKE_RESEND_KEY="$ADMIN" TMPDIR="$work/tmp" \
          CODE=acme KIND=client PROJECT_REF="$ACME" GITHUB_RUN_ID=4242 GITHUB_ENV="$work/env" GITHUB_STEP_SUMMARY="$work/summary" \
          "$@" bash -c "$script" 2>&1)
  status=$?
}
fresh "a client's build"
register
build GITHUB_ACTIONS=true
check '[[ -n "$script" && $status -eq 0 && "$(at_resend)" == "wh_fake_1>$(url_of "$ACME") " && "$(project_secret)" == "$(secret_of wh_fake_1)" ]]' "made, at its address, and the project holds its secret"
check '[[ "$(order)" == "psql cp cp-row;event acme functions note;${PRE};${V};${LIST};${MADE};psql cp vault-put $(name_of "$ACME");${S_GET};${S_SET};${S_GET};${V};POST /functions/v1/resend_webhook;psql cp cp-has-checklist-by-build;psql cp cp-checklist-by-build;event acme functions note;" ]]' \
      "the register asked what acme is now; its database asked; made, proved, then ticked, each said on the row"
check '[[ "$(tvar cp-checklist-by-build code)" == acme && "$(tvar cp-checklist-by-build item)" == resend_webhook && "$(tvar cp-checklist-by-build done)" == true && "$(cut -d"|" -f4 "$FAKE_DIR/webhook.posts")" == taken ]]' "the proof taken, the step ticked for acme"
check '[[ "$(cat "$work/summary")" == *"- the email provider'"'"'s webhook: created (wh_fake_1), proved by a signed event; ticked on the checklist by the build"* && "$(grep -c "^PHASE=functions$" "$work/env")" == 1 ]]' \
      "the summary says so"
check 'shown_only_masked "$(secret_of wh_fake_1)" && shown_only_masked "$(db_url_of "$ACME")" && [[ "$(details)$(cat "$work/summary")" != *"whsec_"* ]]' \
      "the secret, and acme's database connection, printed nowhere but to mask them"
fresh "a build without the admin key"
register
build GITHUB_ACTIONS=true RESEND_ADMIN_API_KEY=
check '[[ $status -eq 0 && "$out" == *"::notice::RESEND_ADMIN_API_KEY is not set"* && "$(order)" == "event acme functions note;" && "$(cat "$work/summary")" == *"not made (RESEND_ADMIN_API_KEY is not set)"* ]]' \
      "a notice, the step left on the checklist, and green"
fresh "D4 a build of a client the owner began to retire meanwhile"
register
answer cp cp-row "status=retiring" "ref=${ACME}" "api_url=https://${ACME}.supabase.co"
build GITHUB_ACTIONS=true
check '[[ $status -eq 0 && "$out" == *"::notice::acme is retiring, so no webhook at the email provider was made for it."* && "$(order)" == "psql cp cp-row;event acme functions note;" && "$(cat "$work/summary")" == *"not made (acme is retiring)"* ]]' \
      "a notice, nothing asked of the database or Resend, and green"
fresh "D4 a build whose register cannot say what the client is now"
register
answer cp cp-row "ERROR:  the rehearsal's register is down"
build GITHUB_ACTIONS=true
check '[[ $status -eq 0 && "$out" == *"::warning::the register could not say what acme is now"* && "$(order)" == "psql cp cp-row;event acme functions note;" ]]' "a warning, nothing made, and green"
fresh "a build whose webhook cannot be made"
register
build GITHUB_ACTIONS=true FAKE_RESEND_KEY=someone-else
check '[[ $status -eq 0 && "$out" == *"::warning::acme'"'"'s webhook at the email provider was not made: nothing was changed"* && "$(order)" != *"checklist"* && "$(details)" == *"was not made: nothing was changed (the line above says why); the step stays on the checklist"* ]]' \
      "a warning, the checklist as it was, and the build goes on"
fresh "W1 a build whose database has not been released 20261012050000"
register
released "$ACME" false
build GITHUB_ACTIONS=true
check '[[ $status -eq 0 && "$out" == *"::warning::acme'"'"'s webhook at the email provider was not made: its database has not been released 20261012050000"* && "$(order)" == "psql cp cp-row;event acme functions note;${PRE};event acme functions note;" ]]' \
      "a warning, nothing asked of Resend"
fresh "W3 a build whose endpoint is left part-way"
register
build GITHUB_ACTIONS=true FAKE_SECRETS_STATUSES=400
check '[[ $status -eq 0 && "$out" == *"::warning::acme'"'"'s webhook at the email provider was not made: it was left part-way"*"; the checklist'"'"'s step unticked"* && "$(tvar cp-checklist-by-build done)" == false ]]' \
      "a warning, and unticked"
fresh "W1 a build whose webhook does not prove"
register
build GITHUB_ACTIONS=true FAKE_WEBHOOK_STATUSES=401 WEBHOOK_PROVE_ATTEMPTS=2
check '[[ $status -eq 0 && "$out" == *"::warning::acme'"'"'s webhook at the email provider was created (wh_fake_1), and its function did not take a signed event as it should"*"so it was deleted again, with its entry in the vault; the checklist'"'"'s step unticked"* ]]' \
      "a warning, saying the endpoint was deleted and the step unticked"
check '[[ -z "$(at_resend)" && -z "$(vault_of "$ACME")" && "$(tvar cp-checklist-by-build done)" == false && "$(order)" == *"POST /functions/v1/resend_webhook;${V};${LIST};DELETE /webhooks/wh_fake_1;psql cp vault-del $(name_of "$ACME");psql cp cp-has-checklist-by-build;psql cp cp-checklist-by-build;event acme functions note;" ]]' \
      "no endpoint left, nor its vault entry, and unticked (done false), never ticked"
fresh "a build whose database keeps what is not its own"
register
build GITHUB_ACTIONS=true 'FAKE_WEBHOOK_ANSWER={"recorded":true}'
check '[[ $status -eq 0 && "$out" == *"::warning::acme'"'"'s webhook at the email provider was created (wh_fake_1), and its database recorded a signed event that matches no mail it sent"* && -z "$(at_resend)" && -z "$(vault_of "$ACME")" && "$(tvar cp-checklist-by-build done)" == false ]]' \
      "a warning, the endpoint deleted again at once, unticked"
fresh "a build whose endpoint cannot be deleted again"
register
build GITHUB_ACTIONS=true FAKE_WEBHOOK_STATUSES=401 WEBHOOK_PROVE_ATTEMPTS=1 MAPI_ATTEMPTS=1 FAKE_RESEND_STATUSES=200,200,200,500
check '[[ $status -eq 0 && "$out" == *"and it could not be deleted again (the line above says why): delete wh_fake_1 in Resend'"'"'s dashboard"* && "$(tvar cp-checklist-by-build done)" == false ]]' \
      "a warning naming it, and unticked"
fresh "a build before the control plane can tick"
register
answer cp cp-has-checklist-by-build false
build GITHUB_ACTIONS=true
check '[[ $status -eq 0 && "$out" == *"::notice::acme'"'"'s webhook is made and proved"* && "$(order)" != *"cp-checklist-by-build"* && "$(cat "$work/summary")" == *"left on the checklist for the owner"* ]]' \
      "a notice, the owner ticks it"
fresh "a build whose tick is refused"
register
answer cp cp-checklist-by-build "ERROR:  CLOVEERP_CHECKLIST_REFUSED: no"
build GITHUB_ACTIONS=true
check '[[ $status -eq 0 && "$out" == *"::warning::acme'"'"'s webhook is made and proved, and the checklist could not be ticked"* ]]' "a warning, and green"
check '! printf "%s" "$script" | grep -qF "\${{"' "its inputs reach it only through the environment"

# 12. The workflow that changes the fleet's secrets offers them
fresh "fleet_secrets.yml"
actions=$(awk '/^      action:/ { a = 1 } a && /^      code:/ { exit } a && /^          - / { sub(/^ *- /, ""); print }' "$SECRETS_WF" | tr '\n' ' ')
check '[[ "$actions" == *"resend_webhook resend_webhook_delete "* ]]' "offers both"
check 'grep -qF "RESEND_ADMIN_API_KEY: \${{ secrets.RESEND_ADMIN_API_KEY }}" "$SECRETS_WF" && grep -qF "\"\${RESEND_ADMIN_API_KEY}\"; do" "$SECRETS_WF" && grep -qF "DEMO_REF: \${{ vars.CLOVEERP_DEMO_PROJECT_REF }}" "$SECRETS_WF" && grep -qF "PRODUCTION_REF: \${{ vars.CLOVEERP_PROJECT_REF" "$SECRETS_WF"' \
      "the admin key given and masked first, and the demonstration's and the control plane's refs"
check 'grep -qF "CLOVEERP_DEMO_DATABASE_URL: \${{ secrets.CLOVEERP_DEMO_DATABASE_URL }}" "$SECRETS_WF" && grep -qF "\"\${CLOVEERP_DEMO_DATABASE_URL}\" " "$SECRETS_WF"' \
      "W1 the demonstration's database given, so it can be asked first, and masked"
check '[[ "$(workflow_step "$SECRETS_WF" "Change them, one client at a time")" == *"supabase/ci/fleet_secrets.sh \"\${ACTION}\" \"\${CODE}\" \"\${REASON}\""* ]]' \
      "run by the step that changes the rest, its inputs through the environment"
check 'grep -qF "supabase/ci/resend_webhook_rehearsal.sh" "$ROOT/.github/workflows/schema.yml"' "and this rehearsal runs on every build"

# 13. The register's tick and untick
fresh "the register's checklist-by-build"
out=$(env "${BASE_ENV[@]}" bash "$HERE/fleet_register.sh" checklist-by-build acme resend_webhook maybe 2>&1); status=$?
check '[[ $status -eq 2 && "$out" == *"neither true (ticked) nor false (unticked)"* ]] && untouched' "anything but true or false refused, nothing asked"
answer cp cp-has-checklist-by-build true
out=$(env "${BASE_ENV[@]}" bash "$HERE/fleet_register.sh" checklist-by-build acme resend_webhook false 2>&1); status=$?
check '[[ $status -eq 0 && "$out" == "register: acme resend_webhook unticked by the build" && "$(tvar cp-checklist-by-build done)" == false ]]' "W3 unticked, said"
out=$(env "${BASE_ENV[@]}" bash "$HERE/fleet_register.sh" checklist-by-build acme resend_webhook 2>&1); status=$?
check '[[ $status -eq 0 && "$out" == "register: acme resend_webhook ticked by the build" && "$(tvar cp-checklist-by-build done)" == true ]]' "ticked by default"

echo "$CASES checks over each project's webhook at the email provider, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
