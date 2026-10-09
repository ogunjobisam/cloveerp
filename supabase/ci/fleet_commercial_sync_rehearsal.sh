#!/usr/bin/env bash
#
# supabase/ci/fleet_commercial_sync.sh, rehearsed with no database.
#
# The sync carries what the control plane owes each client from its contract
# into the client's own database every hour, and whenever a contract changes:
# the position its enforcement reads (the plan, the bands, the add-ons) and
# the notices its organisation's event stream is told. Wrong one way, a client
# trades beyond what it bought, or below it; wrong the other, a notice is
# told twice, out of order, or lost; and what it carries is the owner's
# business with a client (a renewal declined and why, invoice totals, annual
# values), in a repository whose logs are public. So every build runs it here
# first, against the shared stand-ins (fleet_rehearsal_fakes.sh): what it
# refuses before touching anything, that every client up is served whatever
# code the run was started for, that the position and the notices go over
# one connection and every answer comes back in one settle (applied, replay,
# older, waiting, refused), that the notices keep their order and stop at the
# first that waits, that a client that cannot be reached, or a release behind,
# settles nothing, that every statement on a client carries a timeout and is
# terse, and that nothing owed, no connection string and no DETAIL is ever
# printed. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_commercial_sync.sh"
WF="$HERE/../../.github/workflows/fleet_sync.yml"
STEP="Keep every client's contract as the control plane holds it"
# shellcheck source=supabase/ci/fleet_rehearsal_fakes.sh
. "$HERE/fleet_rehearsal_fakes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
fleet_fakes "$work/bin"

PROD=cpcpcpcpcpcpcpcpcpcp
DEMO=dddddddddddddddddddd
ACME=aaaaaaaaaaaaaaaaaaaa
BETA=bbbbbbbbbbbbbbbbbbbb
GAMMA=gggggggggggggggggggg
CP="postgresql://postgres.${PROD}:control-plane-password@pooler.example:5432/postgres"
ACME_URL="postgresql://postgres.${ACME}:acme-database-password@pooler.example:5432/postgres"
BETA_URL="postgresql://postgres.${BETA}:beta-database-password@pooler.example:5432/postgres"
GAMMA_URL="postgresql://postgres.${GAMMA}:gamma-database-password@pooler.example:5432/postgres"
export FAKE_DIR="$work/fake"
T="$(printf '\t')"

# What is owed, with the owner's business in it: none of these words or
# figures may reach the log or the summary.
NOTE="Declined: moving to Rivalsoft in March, Jane Doe says"
TOTAL=48213.57
ANNUAL=7777700
P1=11111111-1111-4111-8111-111111111111
P2=22222222-2222-4222-8222-222222222222
N1=a0000000-0000-4000-8000-000000000001
N2=a0000000-0000-4000-8000-000000000002
N3=a0000000-0000-4000-8000-000000000003
POS='{"tenant_code":"acme","contract_ref":"c1c1c1c1-0000-4000-8000-00000000c1c1","contract_status":"active","plan_code":"growth","support_severity_code":null,"term_start":"2026-10-01","term_end":"2027-09-30","currency":"GBP","renews":true,"status":"active","entitlements":[{"code":"users","limit_value":25,"effective_from":"2026-10-01","effective_to":null}],"capabilities":[{"code":"statutory_chart_8_1","effective_from":"2026-10-01","effective_to":null}]}'
POS_B='{"tenant_code":"beta","contract_ref":"c2c2c2c2-0000-4000-8000-00000000c2c2","contract_status":"terminating","plan_code":"starter","support_severity_code":null,"term_start":"2026-01-01","term_end":"2026-12-31","currency":"GBP","renews":false,"status":"active","entitlements":[],"capabilities":[]}'
NOTICE1="{\"id\":\"${N1}\",\"created_at\":\"2026-10-09T08:00:01+00:00\",\"payload\":{\"event_type\":\"commercial.contract_signed\",\"event_version\":1,\"payload\":{\"contract_ref\":\"c1c1c1c1-0000-4000-8000-00000000c1c1\",\"annual_value_minor\":${ANNUAL}}}}"
NOTICE2="{\"id\":\"${N2}\",\"created_at\":\"2026-10-09T08:00:02+00:00\",\"payload\":{\"event_type\":\"commercial.invoice_issued\",\"event_version\":1,\"payload\":{\"invoice_total\":${TOTAL}}}}"
NOTICE3="{\"id\":\"${N3}\",\"created_at\":\"2026-10-09T08:00:03+00:00\",\"payload\":{\"event_type\":\"commercial.non_renewal_recorded\",\"event_version\":2,\"payload\":{\"note\":\"${NOTE}\"}}}"
DUE_ACME="{\"position\":{\"id\":\"${P1}\",\"created_at\":\"2026-10-09T08:00:00.123456+00:00\",\"payload\":${POS}},\"notices\":[${NOTICE1},${NOTICE2},${NOTICE3}]}"
DUE_BETA="{\"position\":{\"id\":\"${P2}\",\"created_at\":\"2026-09-01T10:00:00+00:00\",\"payload\":${POS_B}},\"notices\":[]}"
# The notices as the client is to read them, in the order queued.
ITEMS="[{\"push_id\":\"${N1}\",\"queued_at\":\"2026-10-09T08:00:01+00:00\",\"event_type\":\"commercial.contract_signed\",\"event_version\":1,\"payload\":{\"contract_ref\":\"c1c1c1c1-0000-4000-8000-00000000c1c1\",\"annual_value_minor\":${ANNUAL}}},{\"push_id\":\"${N2}\",\"queued_at\":\"2026-10-09T08:00:02+00:00\",\"event_type\":\"commercial.invoice_issued\",\"event_version\":1,\"payload\":{\"invoice_total\":${TOTAL}}},{\"push_id\":\"${N3}\",\"queued_at\":\"2026-10-09T08:00:03+00:00\",\"event_type\":\"commercial.non_renewal_recorded\",\"event_version\":2,\"payload\":{\"note\":\"${NOTE}\"}}]"
WAITS="commercial.non_renewal_recorded version 2 is not known here yet"
APPLIED_ACME="notices${T}[{\"push_id\":\"${N1}\",\"outcome\":\"applied\",\"event_id\":\"e0000000-0000-4000-8000-000000000001\"},{\"push_id\":\"${N2}\",\"outcome\":\"applied\",\"detail\":\"event e0000000-0000-4000-8000-000000000002\"},{\"push_id\":\"${N3}\",\"outcome\":\"waiting\",\"detail\":\"${WAITS}\"}]"

BASE_ENV=(FAKE_CP_URL="$CP" CLOVEERP_LIVE_DATABASE_URL="$CP" PSQL="$work/bin/psql" FLEET_SLEEP="$work/bin/sleep"
          PRODUCTION_REF="$PROD" DEMO_REF="$DEMO" TMPDIR="$work/tmp")

# The register and the clients as they are on a good day: acme owed its
# position and three notices, beta its position (held already), gamma
# nothing; each connection in the vault and each database released the
# routines.
fresh() {
  CURRENT="$1"
  rm -rf "$FAKE_DIR" "$work/tmp"; mkdir -p "$FAKE_DIR/vault" "$work/tmp"
  printf '%s' "$ACME_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
  printf '%s' "$BETA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${BETA}_db_url"
  printf '%s' "$GAMMA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${GAMMA}_db_url"
  answer cp cp-ready "true|true|true"
  answer cp cp-clients "[{\"code\":\"acme\",\"ref\":\"${ACME}\"},{\"code\":\"beta\",\"ref\":\"${BETA}\"},{\"code\":\"gamma\",\"ref\":\"${GAMMA}\"}]"
  answer cp cp-refs "${ACME},${BETA},${GAMMA},eeeeeeeeeeeeeeeeeeee"
  answer cp "cp-due@acme" "$DUE_ACME"
  answer cp "cp-due@beta" "$DUE_BETA"
  answer cp "cp-due@gamma" '{"position": null, "notices": []}'
  answer cp cp-settle '{"settled": 1}'
  answer "$ACME" client-state "client|true|true"
  answer "$BETA" client-state "client|true|true"
  answer "$GAMMA" client-state "client|true|true"
  answer "$ACME" client-apply "position${T}{\"outcome\": \"applied\", \"detail\": \"held: plan growth, 1 band, 1 add-on\"}" "$APPLIED_ACME"
  answer "$BETA" client-apply "position${T}{\"outcome\": \"replay\", \"detail\": \"already held\"}"
}

CASES=0
FAILED=0
# go [VAR=value ...] [-- arguments]: the script against the stand-ins as they stand.
go() {
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  : > "$work/summary"
  out=$(env -u GITHUB_ACTIONS GITHUB_STEP_SUMMARY="$work/summary" GITHUB_RUN_ID=4242 \
          "${BASE_ENV[@]}" ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" 2>&1)
  status=$?
}
check() {
  CASES=$((CASES + 1))
  if eval "$1"; then
    echo "  ok   $CURRENT: $2"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL $CURRENT: $2"
    printf '%s\n' "$out" | sed 's/^/       | /' | head -n 25
    sed 's/^/       > /' "$FAKE_DIR/order.log" 2> /dev/null | head -n 40
  fi
}
order() { tr '\n' ';' 2> /dev/null < "$FAKE_DIR/order.log"; }
untouched() { [[ ! -s "$FAKE_DIR/order.log" ]]; }
summary() { cat "$work/summary"; }
# calls <database> <tag>: the numbers of those calls, in order.
calls() { awk -v d="$1" -v t="$2" '$2 == d && $3 == t { print $1 }' "$FAKE_DIR/psql.log" 2> /dev/null | tr '\n' ' '; }
# v <call> <name>: what that call was given as a variable.
v() { sed -n "s/^$2=//p" "$FAKE_DIR/vars.$1" 2> /dev/null | head -n 1; }
# tvar <database> <tag> <name>: the same, for the last call of that tag.
tvar() { local n; n=$(calls "$1" "$2" | awk '{ print $NF }'); [[ -z "$n" ]] || v "$n" "$3"; }
tsql() { local n; n=$(calls "$1" "$2" | awk '{ print $NF }'); [[ -z "$n" ]] || cat "$FAKE_DIR/sql.$n"; }
# settled <code>: the answers the control plane was given for that client.
settled() { local n; for n in $(calls cp cp-settle); do if [[ "$(v "$n" code)" == "$1" ]]; then v "$n" results; fi; done; }
dues() { local n; for n in $(calls cp cp-due); do printf '%s ' "$(v "$n" code)"; done; }
same() { [[ "$(jq -cS . <<< "$1" 2> /dev/null)" == "$(jq -cS . <<< "$2" 2> /dev/null)" && -n "$1" ]]; }
# outcomes <code>: id:outcome of each answer settled for it, in order.
outcomes() { settled "$1" | jq -r 'map("\(.id[0:8]):\(.outcome)") | join(" ")' 2> /dev/null; }
# Nothing of the owner's business, and no connection string, in what was
# printed (a mask line hides a value; it is not one shown).
private() {
  local where
  for where in "$(printf '%s\n' "$out" | grep -v '^::add-mask::')" "$(summary)"; do
    [[ "$where" != *"Rivalsoft"* && "$where" != *"$TOTAL"* && "$where" != *"$ANNUAL"* && "$where" != *"growth"* \
       && "$where" != *"DETAIL"* && "$where" != *"-password@"* ]] || return 1
  done
}

# 1. Refused before anything is touched
fresh "a code given"
go -- acme
check '[[ $status -eq 2 && "$out" == *"takes no code: every run serves every client"* ]] && untouched' "refused: a run for one client serves them all"
fresh "no control plane"
go CLOVEERP_LIVE_DATABASE_URL= --
check '[[ $status -eq 2 && "$out" == *"CLOVEERP_LIVE_DATABASE_URL is not set"* ]] && untouched' "refused"
fresh "a pause that is not one"
go PAUSE_SECONDS=soon --
check '[[ $status -eq 2 ]] && untouched' "refused"
fresh "a timeout psql would not read"
go CLIENT_STATEMENT_TIMEOUT="30 seconds; drop" --
check '[[ $status -eq 2 && "$out" == *"CLIENT_STATEMENT_TIMEOUT and CP_STATEMENT_TIMEOUT"* ]] && untouched' "refused"
fresh "no notices at all per run"
go MAX_NOTICES_PER_RUN=0 --
check '[[ $status -eq 2 ]] && untouched' "refused"
fresh "a control plane that cannot be read"
answer cp cp-ready "ERROR:  could not connect"
go
check '[[ $status -eq 1 && "$out" == *"the control plane could not be read"* && "$(order)" == "psql cp cp-ready;" ]]' "red, nothing else asked"
fresh "a control plane with no register"
answer cp cp-ready "false|false|false"
go
check '[[ $status -eq 0 && "$out" == *"no register of deployments yet"* && "$(order)" == "psql cp cp-ready;" ]]' "nothing to do, and green"
fresh "a control plane a release behind"
answer cp cp-ready "true|false|false"
go
check '[[ $status -eq 0 && "$out" == *"no erp_meta.settle_deployment_pushes yet (20261012040000 is not released there)"* && "$(order)" == "psql cp cp-ready;" ]]' \
      "said, green, and no client asked"
check '[[ "$(tsql cp cp-ready)" == *"to_regprocedure('"'"'erp_meta.settle_deployment_pushes(text,text,jsonb)'"'"')"*"to_regprocedure('"'"'erp_meta.deployment_pushes_due(text)'"'"')"* || "$(tsql cp cp-ready)" == *"deployment_pushes_due(text)"*"settle_deployment_pushes(text,text,jsonb)"* ]]' \
      "both routines asked after by their signatures"
fresh "nobody up"
answer cp cp-clients "[]"
go
check '[[ $status -eq 0 && "$out" == *"nobody is owed a contract"* && -z "$(calls cp cp-due)" ]]' "nothing to do"

# 2. Every client up is served what it is owed
fresh "the fleet"
go
check '[[ $status -eq 0 && "$out" == *"every client was served what the control plane owes it (3)"* ]]' "green"
check '[[ "$(order)" == "psql cp cp-ready;psql cp cp-clients;psql cp cp-refs;psql cp vault-get cloveerp:deployment:${ACME}:db_url;psql ${ACME} client-state;psql cp cp-due;psql ${ACME} client-apply;psql cp cp-settle;sleep 2;psql cp vault-get cloveerp:deployment:${BETA}:db_url;psql ${BETA} client-state;psql cp cp-due;psql ${BETA} client-apply;psql cp cp-settle;sleep 2;psql cp vault-get cloveerp:deployment:${GAMMA}:db_url;psql ${GAMMA} client-state;psql cp cp-due;" ]]' \
      "one at a time, a pause between: its own connection, checked, what it is owed, one connection for both, one settle"
check '[[ "$(dues)" == "acme beta gamma " ]]' "what each is owed asked by its own code"
n=$(calls "$ACME" client-apply | tr -d " ")
check '[[ "$(v "$n" has_position)" == true && "$(v "$n" position_id)" == "$P1" && "$(v "$n" position_at)" == "2026-10-09T08:00:00.123456+00:00" ]] && same "$(v "$n" position)" "$POS"' \
      "acme: its position, with its push id and when it was queued beside it, never inside it"
check '[[ "$(v "$n" position)" == "$(jq -c . <<< "$POS")" && "$(v "$n" notices)" == "$(jq -c . <<< "$ITEMS")" ]]' "each compact (jq -c), one line"
check '[[ "$(v "$n" has_notices)" == true ]] && same "$(v "$n" notices)" "$ITEMS"' \
      "and its notices, in the order queued, each with its push id, when queued, its event and version, and its payload"
check 'same "$(settled acme)" "[{\"id\":\"${P1}\",\"outcome\":\"applied\",\"detail\":\"held: plan growth, 1 band, 1 add-on\"},{\"id\":\"${N1}\",\"outcome\":\"applied\",\"detail\":\"e0000000-0000-4000-8000-000000000001\"},{\"id\":\"${N2}\",\"outcome\":\"applied\",\"detail\":\"event e0000000-0000-4000-8000-000000000002\"},{\"id\":\"${N3}\",\"outcome\":\"waiting\",\"detail\":\"${WAITS}\"}]"' \
      "every answer settled in one call, with its full words"
check '[[ "$(tvar cp cp-settle run)" == 4242 && "$(tsql cp cp-settle)" == *"erp_meta.settle_deployment_pushes(:'"'"'code'"'"', :'"'"'run'"'"', :'"'"'results'"'"'::jsonb)"* ]]' \
      "settled with the run's id"
check '[[ "$(tsql cp cp-due)" == *"erp_meta.deployment_pushes_due(:'"'"'code'"'"')"* && "$(tsql cp cp-due)" == *"set statement_timeout = :'"'"'timeout'"'"';"* && "$(tvar cp cp-due timeout)" == 60s && "$(tvar cp cp-settle timeout)" == 60s ]]' \
      "what is owed, and the settle, under the control plane's own limit"
n=$(calls "$BETA" client-apply | tr -d " ")
check '[[ "$(v "$n" has_position)" == true && "$(v "$n" has_notices)" == false ]] && same "$(settled beta)" "[{\"id\":\"${P2}\",\"outcome\":\"replay\",\"detail\":\"already held\"}]"' \
      "beta: its position again every run, held already: a replay, settled"
check '[[ "$(order)" != *"${GAMMA} client-apply"* && -z "$(settled gamma)" && "$out" == *"gamma: nothing owed"* ]]' "gamma, owed nothing: nothing applied, nothing settled"
check '[[ "$(summary)" == *"| acme | applied | 2 applied, 1 waiting | 4 |  |"* && "$(summary)" == *"| beta | replay | none owed | 1 |  |"* && "$(summary)" == *"| gamma | none owed | none owed | |  |"* ]]' \
      "the summary says each, in counts and outcomes"
check '[[ "$out" == *"acme: position applied; notices 2 applied, 1 waiting; 4 settled"* && "$out" == *"::notice::acme: 1 notice(s) wait"* ]]' "and so does the log"
apply_sql=$(tsql "$ACME" client-apply)
check '[[ "$apply_sql" == *"\\set VERBOSITY terse"* && "$apply_sql" == *"set statement_timeout = :'"'"'timeout'"'"';"* && "$(tvar "$ACME" client-apply timeout)" == 30s ]]' \
      "both under the client's limit, and terse"
check '[[ "$apply_sql" == *"\\if :has_position"*"erp_meta.apply_pushed_position(:'"'"'position_id'"'"'::uuid, :'"'"'position_at'"'"'::timestamptz, :'"'"'position'"'"'::jsonb)"*"\\endif"*"\\if :has_notices"*"erp_meta.apply_pushed_notices(:'"'"'notices'"'"'::jsonb)"*"\\endif"* ]]' \
      "the position first, then the notices, each only when there is one"
check '[[ "$(tsql "$ACME" client-state)" == *"set statement_timeout = :'"'"'timeout'"'"';"*"erp.deployment_kind()"*"apply_pushed_position(uuid,timestamptz,jsonb)"*"apply_pushed_notices(jsonb)"* ]]' \
      "the check before them, under the limit too"
bad=""
for n in $(awk '$3 != "vault-get" && $3 != "event" { print $1 }' "$FAKE_DIR/psql.log"); do
  [[ "$(v "$n" VERBOSITY)" == terse ]] || bad="$bad $n"
done
check '[[ -z "$bad" ]]' "every statement this script sends is VERBOSITY terse"
check '[[ "$(tsql cp cp-clients)" == *"'"'"'built'"'"', '"'"'live'"'"', '"'"'suspended'"'"', '"'"'retiring'"'"'"* && "$(tsql cp cp-clients)" != *"d.code ="* && -z "$(tvar cp cp-clients only)" ]]' \
      "every client whose database is up, never one code"
check 'private' "nothing owed printed: no note, total, annual value or plan"

# 3. The position's answers
fresh "a position older than the one held"
answer "$ACME" client-apply "position${T}{\"outcome\":\"older\",\"detail\":\"holds one queued 2026-10-09T09:00:00Z\"}" "$APPLIED_ACME"
go
check '[[ $status -eq 0 && "$(outcomes acme)" == "11111111:older a0000000:applied a0000000:applied a0000000:waiting" ]]' "settled older, and the notices all the same"
fresh "a position that waits"
answer "$ACME" client-apply "position${T}{\"outcome\":\"waiting\",\"detail\":\"plan enterprise_plus is not known here yet\"}" "$APPLIED_ACME"
go
check '[[ $status -eq 0 && "$(settled acme | jq -r ".[0].outcome + \"|\" + .[0].detail")" == "waiting|plan enterprise_plus is not known here yet" ]]' \
      "settled waiting, with what it waits for"
check '[[ "$out" == *"::notice::acme'"'"'s database does not know a code its position names yet"* && "$out" != *"enterprise_plus"* ]]' \
      "a notice, green, and the code it waits for is in the settle, not the log"
fresh "a position refused"
answer "$ACME" client-apply "ERROR:  CLOVEERP_PUSH_MALFORMED: the position cannot be held: term_end is not a date in {\"note\": \"${NOTE}\"}" \
       "DETAIL:  ${POS}" "$APPLIED_ACME"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database refused the position it was sent (CLOVEERP_PUSH_MALFORMED)"* ]]' "red, naming the refusal"
check '[[ "$(settled acme | jq -r ".[0].outcome")" == refused && "$(settled acme | jq -r ".[0].detail")" == "ERROR: CLOVEERP_PUSH_MALFORMED: the position cannot be held: term_end is not a date in {\"note\": \"${NOTE}\"}" ]]' \
      "settled refused, its full words in the detail"
check '[[ "$(settled acme)" != *"DETAIL"* && "$(outcomes acme)" == *"a0000000:applied a0000000:applied a0000000:waiting"* ]]' \
      "no DETAIL even there (terse), and the notices delivered on the same connection all the same"
check 'private' "and the refusal's words printed nowhere"
check '[[ "$(order)" == *"${BETA} client-apply"* && -n "$(settled beta)" ]]' "and the next client served"
fresh "a position that runs out of time"
answer "$ACME" client-apply "ERROR:  canceling statement due to statement timeout" "$APPLIED_ACME"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: the position could not be applied (a statement timeout); it was not settled"* && "$(outcomes acme)" == "a0000000:applied a0000000:applied a0000000:waiting" ]]' \
      "red, the position not settled (it is sent again), the notices settled"
fresh "a position answered with something else"
answer "$ACME" client-apply "position${T}{\"outcome\":\"kept\"}" "$APPLIED_ACME"
go
check '[[ $status -eq 1 && "$out" == *"not applied, replay, older, waiting or refused"* && "$(outcomes acme)" != *"11111111"* ]]' "red, and not settled"
fresh "notices with no position"
answer cp "cp-due@acme" "{\"position\":null,\"notices\":[${NOTICE1}]}"
answer "$ACME" client-apply "notices${T}[{\"push_id\":\"${N1}\",\"outcome\":\"applied\",\"event_id\":\"e1\"}]"
go
n=$(calls "$ACME" client-apply | tr -d " ")
check '[[ $status -eq 0 && "$(v "$n" has_position)" == false && -z "$(v "$n" position_id)" && "$(outcomes acme)" == "a0000000:applied" && "$(summary)" == *"| acme | none owed | 1 applied | 1 |"* ]]' \
      "the notices alone, and settled"

# 4. The notices: in order, once, and stopped at the first that waits
fresh "a notice that waits holds those behind it"
answer "$ACME" client-apply "position${T}{\"outcome\":\"replay\"}" \
       "notices${T}[{\"push_id\":\"${N1}\",\"outcome\":\"applied\"},{\"push_id\":\"${N2}\",\"outcome\":\"waiting\",\"detail\":\"no organisation yet\"}]"
go
check '[[ $status -eq 0 && "$(outcomes acme)" == "11111111:replay a0000000:applied a0000000:waiting" && "$(settled acme)" != *"${N3}"* ]]' \
      "what was answered is settled; the one behind is left pending, untouched"
check '[[ "$(summary)" == *"| acme | replay | 1 applied, 1 waiting, 1 behind one that waits | 3 |"* ]]' "and the summary says so"
fresh "notices delivered before"
answer "$ACME" client-apply "position${T}{\"outcome\":\"replay\"}" \
       "notices${T}[{\"push_id\":\"${N1}\",\"outcome\":\"replay\",\"detail\":\"e1\"},{\"push_id\":\"${N2}\",\"outcome\":\"replay\",\"detail\":\"e2\"},{\"push_id\":\"${N3}\",\"outcome\":\"replay\",\"detail\":\"e3\"}]"
go
check '[[ $status -eq 0 && "$(outcomes acme)" == "11111111:replay a0000000:replay a0000000:replay a0000000:replay" ]]' \
      "a replay, with the event first made, settled as applied"
fresh "a notice refused"
answer "$ACME" client-apply "position${T}{\"outcome\":\"replay\"}" \
       "notices${T}[{\"push_id\":\"${N1}\",\"outcome\":\"applied\"},{\"push_id\":\"${N2}\",\"outcome\":\"refused\",\"detail\":\"CLOVEERP_EVENT_PAYLOAD_INVALID: {\\\"invoice_total\\\": ${TOTAL}} does not match commercial.invoice_issued\"},{\"push_id\":\"${N3}\",\"outcome\":\"refused\",\"detail\":\"commercial.something_else is not one of the ten\"}]"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database refused 2 notice(s) (CLOVEERP_EVENT_PAYLOAD_INVALID)"* ]]' "red, naming the refusal and no more"
check '[[ "$(outcomes acme)" == "11111111:replay a0000000:applied a0000000:refused a0000000:refused" && "$(settled acme | jq -r ".[2].detail")" == *"invoice_total"*"${TOTAL}"* ]]' \
      "settled refused (failed on the control plane), the full words in the detail"
check 'private' "and none of it printed"
fresh "an answer by push id"
answer "$ACME" client-apply "position${T}{\"outcome\":\"applied\"}" \
       "notices${T}{\"${N1}\": {\"outcome\": \"applied\"}, \"${N2}\": \"applied\", \"${N3}\": {\"outcome\": \"waiting\", \"detail\": \"busy\"}}"
go
check '[[ $status -eq 0 && "$(outcomes acme)" == "11111111:applied a0000000:applied a0000000:applied a0000000:waiting" ]]' "read as well"
fresh "an answer for a notice not sent"
answer "$ACME" client-apply "position${T}{\"outcome\":\"applied\"}" \
       "notices${T}[{\"push_id\":\"${N1}\",\"outcome\":\"applied\"},{\"push_id\":\"ffffffff-0000-4000-8000-000000000000\",\"outcome\":\"applied\"}]"
go
check '[[ "$(settled acme)" != *"ffffffff"* && "$(outcomes acme)" == "11111111:applied a0000000:applied" ]]' "never settled"
fresh "a notice answered with something else"
answer "$ACME" client-apply "position${T}{\"outcome\":\"applied\"}" "notices${T}[{\"push_id\":\"${N1}\",\"outcome\":\"delivered\"},{\"push_id\":\"${N2}\",\"outcome\":\"applied\"}]"
go
check '[[ $status -eq 1 && "$out" == *"answered 1 notice(s) with something that is not applied, replay, waiting or refused"* && "$(outcomes acme)" == "11111111:applied a0000000:applied" && "$(settled acme)" != *"${N1}"* ]]' \
      "red, that one not settled, the rest settled"
fresh "notices that could not be applied"
answer "$ACME" client-apply "position${T}{\"outcome\":\"replay\"}" "ERROR:  CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: only a client holds what is pushed"
go
check '[[ $status -eq 1 && "$out" == *"the notices could not be applied (CLOVEERP_NOT_A_CLIENT_DEPLOYMENT)"* && "$(outcomes acme)" == "11111111:replay" ]]' \
      "red, none settled, the position settled"
fresh "more notices than one run carries"
go MAX_NOTICE_BYTES=10
n=$(calls "$ACME" client-apply | tr -d " ")
check '[[ $status -eq 0 && "$(v "$n" notices | jq -r "map(.push_id) | join(\" \")")" == "$N1" && "$(outcomes acme)" == "11111111:applied a0000000:applied" ]]' \
      "the first always, the rest left pending, in order"
check '[[ "$out" == *"acme: 2 of 3 notice(s) left for the next run"* && "$(summary)" == *"2 left for the next run"* ]]' "and said"
fresh "more notices than one run answers"
go MAX_NOTICES_PER_RUN=2
n=$(calls "$ACME" client-apply | tr -d " ")
check '[[ "$(v "$n" notices | jq -r "map(.push_id) | join(\" \")")" == "$N1 $N2" && "$(settled acme)" != *"${N3}"* ]]' "two, in order"

# 5. A client that cannot be served settles nothing
fresh "a client that cannot be reached"
echo "FATAL:  Tenant or user not found" > "$FAKE_DIR/answers/${ACME}/CONNECT"
go
check '[[ $status -eq 1 && "$out" == *"::error::acme: its database could not be reached or read"*"nothing settled"* ]]' "red, said"
check '[[ "$(dues)" == "beta gamma " && -z "$(settled acme)" && -n "$(settled beta)" ]]' \
      "nothing asked of the control plane for it, nothing settled, and the next client served"
fresh "a client a release behind"
answer "$ACME" client-state "client|false|false"
go
check '[[ $status -eq 0 && "$out" == *"::notice::acme has not yet been released the routines that hold its contract (20261012040000)"* && "$out" == *"but 1 of 3 not yet released the routines"* ]]' \
      "noted, green"
check '[[ "$(dues)" == "beta gamma " && "$(order)" != *"${ACME} client-apply"* && -z "$(settled acme)" ]]' "nothing asked, applied or settled for it"
fresh "a client with one routine of the two"
answer "$ACME" client-state "client|true|false"
go
check '[[ $status -eq 0 && -z "$(settled acme)" && "$out" == *"acme has not yet been released"* ]]' "the same"
fresh "a database that is not a client's"
answer "$ACME" client-state "demonstration|true|true"
go
check '[[ $status -eq 1 && "$out" == *"acme: its database says it is the demonstration deployment, not a client"* && "$(dues)" == "beta gamma " ]]' "refused, nothing applied"
fresh "no connection in the vault"
rm -f "$FAKE_DIR/vault/cloveerp_deployment_${BETA}_db_url"
go
check '[[ $status -eq 1 && "$out" == *"beta: the control plane'"'"'s vault has no cloveerp:deployment:${BETA}:db_url"* && "$(order)" != *"${BETA} client"* && -z "$(settled beta)" && -n "$(settled acme)" ]]' \
      "red, never connected, the others served"
fresh "a connection that names another project"
printf '%s' "postgresql://postgres.${ACME}:pw@pooler.example:5432/postgres?also=${PROD}" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
go
check '[[ $status -eq 1 && "$out" == *"names another deployment'"'"'s project (${PROD})"* && "$(order)" != *"${ACME} client"* ]]' "refused, never connected"
fresh "a connection that names another client"
printf '%s' "$BETA_URL" > "$FAKE_DIR/vault/cloveerp_deployment_${ACME}_db_url"
go
check '[[ $status -eq 1 && "$out" == *"does not name its project (${ACME})"* && "$(calls "$BETA" client-state | wc -w | tr -d " ")" == 1 ]]' "refused, never connected"
fresh "nothing answered on the client"
answer "$ACME" client-apply "ERROR:  canceling statement due to statement timeout" "ERROR:  canceling statement due to statement timeout"
go
check '[[ $status -eq 1 && -z "$(settled acme)" && "$out" == *"the position could not be applied (a statement timeout)"* && "$out" == *"the notices could not be applied (a statement timeout)"* ]]' \
      "red, and nothing settled"
fresh "what is owed cannot be read"
answer cp "cp-due@acme" "ERROR:  canceling statement due to statement timeout"
go
check '[[ $status -eq 1 && "$out" == *"acme: what the control plane owes it could not be read (a statement timeout)"* && "$(order)" != *"${ACME} client-apply"* && -n "$(settled beta)" ]]' \
      "red, nothing applied there, the next served"
fresh "what is owed in a shape the sync does not read"
answer cp "cp-due@acme" '[1, 2]'
go
check '[[ $status -eq 1 && "$out" == *"in a shape this sync does not read"* && "$(order)" != *"${ACME} client-apply"* ]]' "red, nothing applied there"
fresh "a position with no push id"
answer cp "cp-due@acme" "{\"position\":{\"id\":\"not-a-push\",\"created_at\":\"2026-10-09T08:00:00Z\",\"payload\":${POS}},\"notices\":[]}"
go
check '[[ $status -eq 1 && "$out" == *"has no push id"* && "$(order)" != *"${ACME} client-apply"* && "$(summary)" == *"| acme | not sent |"* ]]' "red, not sent"
fresh "a settle the control plane refuses"
answer cp "cp-settle@acme" "ERROR:  CLOVEERP_PUSH_RESULTS_UNREADABLE: results[0] in ${POS}"
go
check '[[ $status -eq 1 && "$out" == *"acme: what it answered could not be settled on the control plane (CLOVEERP_PUSH_RESULTS_UNREADABLE)"* && -n "$(settled beta)" ]]' \
      "red, the code alone said, and the next client served"
check 'private' "nothing of what the refusal quoted printed"

# 6. Nothing secret printed
fresh "on a runner"
go GITHUB_ACTIONS=true
check '[[ $status -eq 0 ]]' "green"
for secret in "$ACME_URL" "$BETA_URL" "$GAMMA_URL"; do
  CASES=$((CASES + 1))
  if [[ "$(printf "%s\n" "$out" | grep -F -- "$secret" | grep -vc "^::add-mask::")" == 0 && "$(printf "%s\n" "$out" | grep -cxF -- "::add-mask::$secret")" == 1 ]]; then
    echo "  ok   $CURRENT: ${secret:0:24}… masked, and printed nowhere else"
  else
    FAILED=$((FAILED + 1)); echo "  FAIL $CURRENT: ${secret:0:24}… printed unmasked, or never masked"
  fi
done
check 'private && [[ "$out" != *"control-plane-password"* ]]' "nothing owed and no connection printed"
fresh "outside a runner"
go
check '[[ $status -eq 0 && "$out" != *"::add-mask::"* && "$out" != *"-password@"* ]]' "no mask line, and nothing secret"

# 7. The workflow's own step, as the runner runs it
fresh "the step in fleet_sync.yml"
steps=$(sed -n 's/^      - name: //p' "$WF" | tr '\n' ';')
check '[[ "$steps" == *"Keep every client'"'"'s staff as the control plane'"'"'s;Keep every client'"'"'s organisation suspended as the register says;${STEP};" ]]' \
      "third, after the staff and the status"
check '[[ "$(awk -v s="      - name: ${STEP}" '"'"'$0 == s { on = 1; next } on && /^ *run:/ { exit } on'"'"' "$WF")" == *"if: \${{ !cancelled() }}"* ]]' \
      "and run whatever happened before it"
script=$(workflow_step "$WF" "$STEP")
CODE_RUN() {
  out=$(cd "$HERE/../.." && env -u GITHUB_ACTIONS PATH="$work/bin:$PATH" FAKE_CP_URL="$CP" PRODUCTION_REF="$PROD" DEMO_REF="$DEMO" \
          GITHUB_RUN_ID=4242 GITHUB_STEP_SUMMARY="$work/summary" TMPDIR="$work/tmp" "$@" bash -c "$script" 2>&1)
  status=$?
}
CODE_RUN CLOVEERP_LIVE_DATABASE_URL="$CP" CODE=beta
check '[[ -n "$script" && $status -eq 0 && "$(dues)" == "acme beta gamma " && -n "$(settled acme)" && -n "$(settled beta)" ]]' \
      "a run started for beta serves every client"
fresh "the step with no control plane"
CODE_RUN CLOVEERP_LIVE_DATABASE_URL= CODE=
check '[[ $status -eq 1 && "$out" == *"::error::CLOVEERP_LIVE_DATABASE_URL is not set"* ]] && untouched' "red, nothing touched"

echo "$CASES checks over each client's contract as the control plane holds it, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
