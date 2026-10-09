#!/usr/bin/env bash
#
# Every client's contract, held on its own database as the control plane
# holds it (.github/workflows/fleet_sync.yml).
#
# A client deployment's contract is signed, amended, renewed and invoiced on
# the control plane (20261011090000), and its database is where the contract
# is enforced: the plan its organisation onboards on, the bands it may grow
# to, the add-ons it may switch on. So the control plane keeps what it owes
# each client in erp_meta.deployment_push, and this sync carries it across
# (20261012040000): the position, the contract as the client is to hold it,
# newest first and sent every run, so a client rebuilt from empty, restored or
# resumed heals itself; and the notices, the contract's events in the order
# they were queued, each delivered once into the organisation's own event
# stream. Nothing is claimed: the position is reconciled, and the notices are
# made idempotent by the client, by push id.
#
# Every client in the control plane's register whose database is up (built,
# live, suspended or retiring) and has a project, one at a time, whatever
# code the run was started for: GitHub keeps one waiting run of the sync and
# cancels an older waiting one, so a run started for one client serves them
# all. For each:
#
#   1. its connection string from the control plane's vault
#      (cloveerp:deployment:<ref>:db_url), masked the moment it is read and
#      refused unless it names the client's project and no other
#      deployment's;
#   2. every statement there under a timeout, set in SQL (the pooler drops
#      PGOPTIONS);
#   3. its database must say it is a client's and have been released
#      erp_meta.apply_pushed_position and erp_meta.apply_pushed_notices: a
#      client a release behind is noted, owed the same at the next run, and
#      nothing is settled for it;
#   4. what the control plane owes it, from erp_meta.deployment_pushes_due;
#   5. one connection to the client for both: the position applied
#      (applied, replay, older or waiting; refused when its shape is wrong,
#      CLOVEERP_PUSH_MALFORMED), then the notices in order (applied, replay,
#      waiting or refused each; the client stops at the first that waits, so
#      the stream keeps its order, and those behind it stay pending);
#   6. one settle on the control plane, erp_meta.settle_deployment_pushes,
#      with every answer and its full words. A client that cannot be reached
#      settles nothing, so what it is owed stays pending for the next run.
#
# What a client is owed is the owner's business with that client: notes on a
# renewal declined, invoice totals, annual values. The logs and summaries of
# this repository are public. So nothing owed is ever printed, and psql is
# told VERBOSITY terse, so no DETAIL (where CLOVEERP_EVENT_PAYLOAD_INVALID
# puts the payload) reaches even this script; what is printed is counts,
# outcomes and CLOVEERP_ codes, and the full words go to the control plane in
# the settle's detail, which the Fleet view shows its owner. Payloads reach
# SQL compact (jq -c), as psql variables on standard input (psql substitutes
# :'name' only there, never in -c), and at most MAX_NOTICE_BYTES of notices
# in one run, so no variable outgrows what one argument may hold; the rest
# wait, in order, for the next run.
#
# Usage: fleet_commercial_sync.sh      (no code: every client up is served)
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane (required)
#   PRODUCTION_REF, DEMO_REF    refs a client's connection must not name, as
#                               well as every other ref in the register
#   PSQL                        the command (the rehearsal's stand-in)
#   CLIENT_STATEMENT_TIMEOUT    each statement on a client (default 30s)
#   CP_STATEMENT_TIMEOUT        what is owed, and the settle, on the control
#                               plane (default 60s)
#   MAX_NOTICE_BYTES            notices carried to one client in one run
#                               (default 98304; one is always carried)
#   MAX_NOTICES_PER_RUN         and at most this many (default 100), so the
#                               settle's answers fit one variable too
#   PAUSE_SECONDS               between clients (default 2)
#   FLEET_SLEEP                 the sleep command (default sleep)
#   PGCONNECT_TIMEOUT           seconds to reach a database (default 15)
#
# Exit: 0 when every client was served what it is owed (one a release behind
# is noted, and what waits waits); 1 when any could not be, or refused what
# it was sent, each said in an ::error:: line, and every other client served
# all the same; 2 when nothing was tried.
#
# bash 3.2 and 5. Rehearsed on every build with the shared stand-ins:
# supabase/ci/fleet_commercial_sync_rehearsal.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
SLEEP_CMD="${FLEET_SLEEP:-sleep}"
PAUSE="${PAUSE_SECONDS:-2}"
TIMEOUT="${CLIENT_STATEMENT_TIMEOUT:-30s}"
CP_TIMEOUT="${CP_STATEMENT_TIMEOUT:-60s}"
MAX_BYTES="${MAX_NOTICE_BYTES:-98304}"
MAX_NOTICES="${MAX_NOTICES_PER_RUN:-100}"
RUN="${GITHUB_RUN_ID:-local}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"
export PGAPPNAME="${PGAPPNAME:-fleet_commercial_sync}"

is_ref() { [[ "$1" =~ ^[a-z0-9]{20}$ ]]; }
is_uuid() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
is_interval() { [[ "$1" =~ ^[0-9]+(ms|s|min)?$ ]]; }

if [[ $# -gt 0 ]]; then
  echo "::error::fleet_commercial_sync.sh takes no code: every run serves every client whose database is up, because a waiting run started for one client may be cancelled by the next. Nothing was applied."
  exit 2
fi
if [[ -z "$CP_URL" ]]; then
  echo "::error::CLOVEERP_LIVE_DATABASE_URL is not set, so what the control plane owes its clients cannot be read. Nothing was applied."
  exit 2
fi
if ! [[ "$PAUSE" =~ ^[0-9]+$ ]]; then
  echo "::error::PAUSE_SECONDS must be a whole number. Nothing was applied."
  exit 2
fi
if ! [[ "$MAX_BYTES" =~ ^[0-9]+$ && "$MAX_NOTICES" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::MAX_NOTICE_BYTES and MAX_NOTICES_PER_RUN must be whole numbers, the second at least 1. Nothing was applied."
  exit 2
fi
# A statement that sets a timeout psql cannot read would be the first error
# on a connection whose errors are read in order.
if ! is_interval "$TIMEOUT" || ! is_interval "$CP_TIMEOUT"; then
  echo "::error::CLIENT_STATEMENT_TIMEOUT and CP_STATEMENT_TIMEOUT are a number of ms, s or min. Nothing was applied."
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_commercial_sync.XXXXXX")
trap 'rm -rf "$work"' EXIT

# On a runner GitHub hides a value printed after this; a terminal would show
# it, so nowhere else.
mask() {
  if [[ "${GITHUB_ACTIONS:-}" == true && -n "${1:-}" ]]; then
    echo "::add-mask::$1"
  fi
}

# What psql said was wrong, on one line, for a statement that carried
# nothing owed (the register, the vault, the check of a client): its words
# cannot hold a payload.
said() {
  local first
  first=$(grep -E 'ERROR|FATAL|error|refus|could not|^x ' "$work/err" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$work/err" 2> /dev/null || true)
  first="${first#psql:<stdin>:*: }"
  printf '%s' "${first:-no reason given}" | tr -s ' \t' '  ' | jq -Rr '.[0:300]'
}

# codes <words>: what went wrong with a statement that carried what is owed,
# in words a public log may hold: the CLOVEERP_ codes it names, else the kind
# of failure. Never the words themselves.
codes() {
  local c
  c=$(printf '%s\n' "$1" | grep -oE 'CLOVEERP_[A-Z0-9_]+' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//' || true)
  if [[ -n "$c" ]]; then
    printf '%s' "$c"
  elif printf '%s' "$1" | grep -q 'statement timeout'; then
    printf 'a statement timeout'
  elif printf '%s' "$1" | grep -qE 'could not connect|connection to server|server closed the connection|terminating connection|Tenant or user not found|timeout expired|SSL'; then
    printf 'the connection failed'
  elif [[ -z "$1" ]]; then
    printf 'no reason given'
  else
    printf 'an error that names no CLOVEERP_ code'
  fi
}

# Every statement here terse: no DETAIL, no CONTEXT, which is where a
# refusal's payload would be.
cp_q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA -v VERBOSITY=terse -v SHOW_CONTEXT=never "$@"; }
client_q() {
  local url="$1"
  shift
  $PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA -v VERBOSITY=terse -v SHOW_CONTEXT=never -v timeout="$TIMEOUT" "$@"
}
reg() { CLOVEERP_LIVE_DATABASE_URL="$CP_URL" PSQL="$PSQL_CMD" "$HERE/fleet_register.sh" "$@"; }

# ── The control plane: what it can say, and to whom ──────────────────────────
ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
select (to_regclass('erp_meta.deployment') is not null)::text || '|'
       || (to_regprocedure('erp_meta.deployment_pushes_due(text)') is not null)::text || '|'
       || (to_regprocedure('erp_meta.settle_deployment_pushes(text,text,jsonb)') is not null)::text;
SQL
) || { echo "::error::the control plane could not be read ($(said)). Nothing was applied."; exit 1; }
IFS='|' read -r has_register has_due has_settle <<< "$ready"
if [[ "$has_register" != true ]]; then
  echo "the control plane has no register of deployments yet, so no client is owed a contract"
  exit 0
fi
if [[ "$has_due" != true || "$has_settle" != true ]]; then
  echo "the control plane has no erp_meta.settle_deployment_pushes yet (20261012040000 is not released there), so nothing is carried to a client by this sync; what is owed waits for it"
  exit 0
fi

clients=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-clients
select coalesce(jsonb_agg(jsonb_build_object('code', d.code, 'ref', d.project_ref) order by d.code), '[]'::jsonb)
  from erp_meta.deployment d
 where d.status in ('built', 'live', 'suspended', 'retiring')
   and (d.status <> 'retiring' or d.built_at is not null)
   and d.project_ref is not null;
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). Nothing was applied."; exit 1; }
# Every ref the register knows, whatever its state, and production's and
# the demonstration's: a client's connection may name its own and no other.
all_refs=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-refs
select coalesce(string_agg(d.project_ref, ','), '') from erp_meta.deployment d where d.project_ref is not null;
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). Nothing was applied."; exit 1; }
all_refs="${all_refs},${PRODUCTION_REF:-xpzffnnhnhcqyjqcueja},${DEMO_REF:-}"

count=$(jq 'length' <<< "$clients")
if [[ "$count" -eq 0 ]]; then
  echo "no client in the register has a database that is up (built, live, suspended or retiring); nobody is owed a contract"
  exit 0
fi

echo "the register: ${count} client(s) whose database is up"
{
  echo "## Each client's contract, as the control plane holds it"
  echo
  echo "| client | position | notices | settled | not done |"
  echo "|---|---|---|---|---|"
} >> "$SUMMARY"

troubled=0
skipped=0

# ── One client ───────────────────────────────────────────────────────────────
# trouble <words>: said at once and gathered in TROUBLE, for the summary.
# Only counts, outcomes, codes and what the register says reach it.
trouble() {
  local said_here
  said_here=$(printf '%s' "$*" | sed -E 's/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+)/\1…@\2/g')
  echo "::error::${CODE}: ${said_here}"
  TROUBLE="${TROUBLE:+${TROUBLE}; }${said_here}"
}

# tally <results>: the notices' outcomes, counted, in words.
tally() {
  jq -r '[group_by(.outcome)[] | "\(length) \(.[0].outcome)"] | join(", ")' <<< "$1"
}

serve_client() {
  CODE="$1"
  TROUBLE=""
  local ref="$2"
  local url="" vault state kind can_position can_notices other due rc
  local position_id="" position_at="" position="" has_position=false has_notices=false
  local items='[]' sent='[]' n_due=0 n_sent=0 n_left=0 n_answered=0
  local results='[]' line idx=0 outcome detail answer pos_words="" notice_words="" settled=""
  local -a others

  if ! is_ref "$ref"; then
    trouble "the register gives it no project ref ('${ref}'), so nothing was applied there"
  else
    vault="cloveerp:deployment:${ref}:db_url"
    if ! url=$(reg vault-get "$vault" 2> "$work/err"); then
      url=""
      trouble "the control plane's vault could not be read for ${vault} ($(said)); nothing was applied there"
    else
      mask "$url"
      if [[ -z "$url" ]]; then
        trouble "the control plane's vault has no ${vault}, so it cannot be reached (its build from empty writes that entry); nothing was applied there"
      elif [[ "$url" != *"$ref"* ]]; then
        trouble "${vault} does not name its project (${ref}); nothing was applied there"
        url=""
      else
        IFS=',' read -r -a others <<< "$all_refs"
        for other in ${others[@]+"${others[@]}"}; do
          other="${other// /}"
          if [[ -n "$other" && "$other" != "$ref" && "$url" == *"$other"* ]]; then
            trouble "${vault} names another deployment's project (${other}); nothing was applied there"
            url=""
            break
          fi
        done
      fi
    fi
  fi

  # Its database: a client's, and released the two routines.
  if [[ -n "$url" ]]; then
    if ! state=$(client_q "$url" 2> "$work/err" <<'SQL'
-- fleet: client-state
set statement_timeout = :'timeout';
select coalesce(erp.deployment_kind(), '') || '|'
       || (to_regprocedure('erp_meta.apply_pushed_position(uuid,timestamptz,jsonb)') is not null)::text || '|'
       || (to_regprocedure('erp_meta.apply_pushed_notices(jsonb)') is not null)::text;
SQL
    ); then
      trouble "its database could not be reached or read ($(said)); nothing was applied there, and nothing settled"
      url=""
    else
      IFS='|' read -r kind can_position can_notices <<< "$state"
      if [[ "$kind" != client ]]; then
        trouble "its database says it is the ${kind:-unknown} deployment, not a client's; nothing was applied there"
        url=""
      elif [[ "$can_position" != true || "$can_notices" != true ]]; then
        echo "::notice::${CODE} has not yet been released the routines that hold its contract (20261012040000). The next train brings them, and the sync after it applies what it is owed. Nothing was applied or settled there."
        echo "| ${CODE} | | | | not released the routines yet |" >> "$SUMMARY"
        skipped=$((skipped + 1))
        return 0
      fi
    fi
  fi

  # What the control plane owes it.
  if [[ -n "$url" ]]; then
    if ! due=$(cp_q -v code="$CODE" -v timeout="$CP_TIMEOUT" 2> "$work/err" <<'SQL'
-- fleet: cp-due
set statement_timeout = :'timeout';
select erp_meta.deployment_pushes_due(:'code')::text;
SQL
    ); then
      trouble "what the control plane owes it could not be read ($(codes "$(cat "$work/err")")); nothing was applied there"
      url=""
    elif ! jq -e 'type == "object" and ((.notices // []) | type) == "array"
                  and (.position == null or ((.position | type) == "object" and (.position.id | type) == "string"))' \
                <<< "$due" > /dev/null 2>&1; then
      trouble "what the control plane owes it came back in a shape this sync does not read; nothing was applied there"
      url=""
    fi
  fi

  if [[ -n "$url" ]]; then
    if [[ "$(jq -r '.position != null' <<< "$due")" == true ]]; then
      position_id=$(jq -r '.position.id' <<< "$due")
      position_at=$(jq -r '.position.created_at // ""' <<< "$due")
      position=$(jq -c '.position.payload' <<< "$due")
      if ! is_uuid "$position_id" || [[ -z "$position_at" ]]; then
        trouble "the position the control plane owes it has no push id or no time it was queued; it was not sent"
        pos_words="not sent"
      else
        has_position=true
      fi
    fi
    # The notices as the client reads them, in the order they were queued:
    # what was queued is {"event_type", "event_version", "payload"}.
    items=$(jq -c '[(.notices // [])[] | {push_id: .id, queued_at: .created_at,
                                           event_type: (.payload.event_type // null),
                                           event_version: (.payload.event_version // null),
                                           payload: (.payload.payload // null)}]' <<< "$due")
    n_due=$(jq 'length' <<< "$items")
    # As many as fit in one variable, and as many as their answers fit in
    # the settle's, at least one: the rest wait, in order.
    sent=$(jq -c --argjson max "$MAX_BYTES" --argjson most "$MAX_NOTICES" '
      reduce .[] as $i ({items: [], bytes: 2, full: false};
        if .full then .
        else ($i | tojson | utf8bytelength) as $b
             | if (.items | length) > 0 and (.bytes + $b + 1 > $max or (.items | length) >= $most) then .full = true
               else .items += [$i] | .bytes += $b + 1 end
        end) | .items' <<< "$items")
    n_sent=$(jq 'length' <<< "$sent")
    n_left=$((n_due - n_sent))
    if [[ "$n_sent" -gt 0 ]]; then has_notices=true; fi
  fi

  if [[ -n "$url" && "$has_position" != true && "$has_notices" != true ]]; then
    echo "${CODE}: nothing owed"
    echo "| ${CODE} | ${pos_words:-none owed} | none owed | | ${TROUBLE} |" >> "$SUMMARY"
    if [[ -n "$TROUBLE" ]]; then troubled=$((troubled + 1)); fi
    return 0
  fi

  # Both on one connection, each statement its own (ON_ERROR_STOP off): a
  # position refused does not keep the notices from being delivered. Each
  # statement that fails gives psql's one ERROR line, in order.
  if [[ -n "$url" ]]; then
    rc=0
    $PSQL_CMD "$url" -v ON_ERROR_STOP=0 -X -q -tA -v VERBOSITY=terse -v SHOW_CONTEXT=never -v timeout="$TIMEOUT" \
      -v has_position="$has_position" -v position_id="$position_id" -v position_at="$position_at" -v position="$position" \
      -v has_notices="$has_notices" -v notices="$sent" > "$work/out" 2> "$work/err" <<'SQL' || rc=$?
-- fleet: client-apply
\set VERBOSITY terse
\set SHOW_CONTEXT never
set statement_timeout = :'timeout';
\if :has_position
select 'position' || chr(9) || erp_meta.apply_pushed_position(:'position_id'::uuid, :'position_at'::timestamptz, :'position'::jsonb)::text;
\endif
\if :has_notices
select 'notices' || chr(9) || erp_meta.apply_pushed_notices(:'notices'::jsonb)::text;
\endif
SQL
    grep -E '(^|: )(ERROR|FATAL):' "$work/err" > "$work/errors" 2> /dev/null || true
    if [[ "$rc" -ne 0 && ! -s "$work/out" ]]; then
      trouble "its database could not be reached to apply what it is owed ($(codes "$(cat "$work/err")")); nothing was applied there, and nothing settled"
      url=""
    elif [[ "$rc" -ne 0 ]]; then
      trouble "its connection ended before everything was answered ($(codes "$(cat "$work/err")")); what was answered is settled"
    fi
  fi

  if [[ -n "$url" && "$has_position" == true ]]; then
    answer=$(sed -n 's/^position	//p' "$work/out" | head -n 1)
    if [[ -n "$answer" ]]; then
      outcome=$(jq -r '.outcome // "" | tostring' <<< "$answer" 2> /dev/null || echo "")
      detail=$(jq -r '(.detail // "") | if type == "string" then . else tojson end | .[0:1000]' <<< "$answer" 2> /dev/null || echo "")
      case "$outcome" in
        applied|replay|older|waiting)
          results=$(jq -c --arg id "$position_id" --arg o "$outcome" --arg d "$detail" '. + [{id: $id, outcome: $o, detail: $d}]' <<< "$results")
          pos_words="$outcome"
          if [[ "$outcome" == waiting ]]; then
            echo "::notice::${CODE}'s database does not know a code its position names yet (it is behind on its release); it waits, unchanged, and is sent again at the next run."
          fi ;;
        refused)
          # Answered rather than raised: settled the same.
          results=$(jq -c --arg id "$position_id" --arg d "$detail" '. + [{id: $id, outcome: "refused", detail: $d}]' <<< "$results")
          pos_words=refused
          trouble "its database refused the position it was sent ($(codes "$detail")); its full words are in the settle's detail" ;;
        *)
          trouble "its database answered the position with something that is not applied, replay, older, waiting or refused; it was not settled" ;;
      esac
    else
      idx=$((idx + 1))
      line=$(sed -n "${idx}p" "$work/errors")
      line="${line#psql:<stdin>:*: }"
      if [[ "$line" == *CLOVEERP_PUSH_MALFORMED* ]]; then
        detail=$(printf '%s' "$line" | tr -s ' \t' '  ' | jq -Rr '.[0:1000]')
        results=$(jq -c --arg id "$position_id" --arg d "$detail" '. + [{id: $id, outcome: "refused", detail: $d}]' <<< "$results")
        pos_words=refused
        trouble "its database refused the position it was sent (CLOVEERP_PUSH_MALFORMED); its full words are in the settle's detail"
      else
        trouble "the position could not be applied ($(codes "$line")); it was not settled, and is sent again at the next run"
      fi
    fi
  fi

  if [[ -n "$url" && "$has_notices" == true ]]; then
    answer=$(sed -n 's/^notices	//p' "$work/out" | head -n 1)
    if [[ -z "$answer" ]]; then
      idx=$((idx + 1))
      line=$(sed -n "${idx}p" "$work/errors")
      trouble "the notices could not be applied ($(codes "$line")); none was settled, and they are sent again at the next run"
    elif ! answer=$(jq -c --argjson sent "$sent" '
        def items:
          if type == "array" then .
          elif type == "object" and ((.items // null) | type) == "array" then .items
          elif type == "object" and ((.results // null) | type) == "array" then .results
          elif type == "object" then to_entries | map((if (.value | type) == "object" then .value else {outcome: .value} end) + {push_id: .key})
          else error("not an answer") end;
        ($sent | map(.push_id)) as $ids
        | [items[] | {id: ((.push_id // .id) | tostring), outcome: ((.outcome // "") | tostring),
                      detail: ((.detail // .event_id // .result // "") | if type == "string" then . else tojson end | .[0:500])}
                   | select(.id as $x | $ids | index($x))]' <<< "$answer" 2> /dev/null); then
      trouble "its database answered the notices in a shape this sync does not read; none was settled"
    else
      n_answered=$(jq 'length' <<< "$answer")
      if [[ "$(jq '[.[] | select(.outcome | IN("applied", "replay", "waiting", "refused") | not)] | length' <<< "$answer")" -gt 0 ]]; then
        trouble "its database answered $(jq '[.[] | select(.outcome | IN("applied", "replay", "waiting", "refused") | not)] | length' <<< "$answer") notice(s) with something that is not applied, replay, waiting or refused; those were not settled"
        answer=$(jq -c '[.[] | select(.outcome | IN("applied", "replay", "waiting", "refused"))]' <<< "$answer")
      fi
      results=$(jq -c --argjson a "$answer" '. + $a' <<< "$results")
      notice_words=$(tally "$answer")
      line=$(jq '[.[] | select(.outcome == "waiting")] | length' <<< "$answer")
      if [[ "$line" -gt 0 ]]; then
        echo "::notice::${CODE}: ${line} notice(s) wait (no organisation yet, its onboarding under way, or an event its database does not know yet); they stay pending, in order, for the next run."
      fi
      line=$(jq '[.[] | select(.outcome == "refused")] | length' <<< "$answer")
      if [[ "$line" -gt 0 ]]; then
        trouble "its database refused ${line} notice(s) ($(codes "$(jq -r '.[] | select(.outcome == "refused") | .detail' <<< "$answer")")); each is failed on the control plane, with its full words in the detail"
      fi
      # The client stops at the first that waits: those behind it were not
      # answered, and stay pending, untouched.
      line=$((n_sent - n_answered))
      if [[ "$line" -gt 0 ]]; then
        notice_words="${notice_words:+${notice_words}, }${line} behind one that waits"
      fi
    fi
    if [[ "$n_left" -gt 0 ]]; then
      notice_words="${notice_words:+${notice_words}, }${n_left} left for the next run"
      echo "${CODE}: ${n_left} of ${n_due} notice(s) left for the next run (one run carries at most ${MAX_NOTICES} of them, and ${MAX_BYTES} bytes)"
    fi
  fi

  # One settle, every answer in it.
  if [[ -n "$url" && "$(jq 'length' <<< "$results")" -gt 0 ]]; then
    if ! cp_q -v code="$CODE" -v run="$RUN" -v results="$results" -v timeout="$CP_TIMEOUT" > /dev/null 2> "$work/err" <<'SQL'
-- fleet: cp-settle
\set VERBOSITY terse
set statement_timeout = :'timeout';
select erp_meta.settle_deployment_pushes(:'code', :'run', :'results'::jsonb)::text;
SQL
    then
      trouble "what it answered could not be settled on the control plane ($(codes "$(cat "$work/err")")); it stays as it was, and the next run's replay settles it"
    else
      settled=$(jq 'length' <<< "$results")
    fi
  fi

  if [[ "$has_position" != true && -n "$url" ]]; then pos_words="${pos_words:-none owed}"; fi
  if [[ "$has_notices" != true && -n "$url" ]]; then notice_words="none owed"; fi
  echo "${CODE}: position ${pos_words:-not answered}; notices ${notice_words:-not answered}; ${settled:-0} settled"
  echo "| ${CODE} | ${pos_words} | ${notice_words} | ${settled} | ${TROUBLE} |" >> "$SUMMARY"
  if [[ -n "$TROUBLE" ]]; then
    troubled=$((troubled + 1))
  fi
  return 0
}

for ((c = 0; c < count; c++)); do
  if [[ "$c" -gt 0 && "$PAUSE" -gt 0 ]]; then
    $SLEEP_CMD "$PAUSE"
  fi
  serve_client "$(jq -r ".[$c].code" <<< "$clients")" "$(jq -r ".[$c].ref" <<< "$clients")"
done

if [[ "$troubled" -gt 0 ]]; then
  echo "::error::${troubled} of ${count} client(s) could not be served what the control plane owes them, or refused it; each is said above, and what was answered is settled. Every other client was served."
  exit 1
fi
if [[ "$skipped" -gt 0 ]]; then
  echo "every client was served what the control plane owes it, but ${skipped} of ${count} not yet released the routines"
else
  echo "every client was served what the control plane owes it (${count})"
fi
