#!/usr/bin/env bash
#
# Every incident and maintenance window that reaches a client, carried into
# the client's own database (.github/workflows/fleet_sweep.yml, a job of its
# own).
#
# Incidents and maintenance windows are declared, updated and resolved on the
# control plane's console. Before 20261012060000 they reached only the
# organisations on the control plane's own database; a client on its own
# project got no banner and no email, and for a security incident never saw
# the clock of the report it owes as data controller. Its banner, its
# continuity screen and its drain (erp.communicate_incidents, every minute)
# are on its own database, so that is where a copy has to be. The control
# plane keeps which client deployments each incident and window reaches
# (erp_meta.incident_deployment, erp_meta.maintenance_window_deployment, and
# the "every client" flag) and the digest each last answered; it decides what
# a client is owed, and the client decides what it does with it. This sync
# carries the one to the other and the answer back, and reshapes neither:
#
#   due     erp_meta.incident_pushes_due(code), on the control plane:
#           {code, up, incidents: [{id, digest, payload}], windows: [the
#           same], told_of: [incident ids], check_held}. Incidents open or
#           resolved in the last thirty days, windows upcoming, under way, or
#           ended or cancelled in the last thirty, each whose digest differs
#           from the one the client last answered, oldest first, fifty of
#           each at most (the rest come next run); told_of, the incidents the
#           client holds whose telling it has not reported yet; check_held,
#           true once every twenty-four hours for each deployment (absent or
#           false otherwise), when the client is to say which copies it holds
#           even if it is owed nothing else, so that one restored to an
#           earlier point, which no longer holds what it once answered, is
#           carried it again. A deployment that is not up is owed empty lists.
#   apply   erp_meta.apply_pushed_incidents(due), on the client, given that
#           object whole as the control plane wrote it. It keeps each item by
#           the control plane's id and deletes no incident, window or update
#           it received, and answers {incidents: [{id, outcome, detail,
#           digest}], windows: [the same], told: [{id, told_at}], held:
#           [{kind, id, digest}]}: applied; replay (the same digest held
#           already); waiting (a severity, component, provider or timeline it
#           does not know yet, or a failure that may pass); or refused (it
#           holds the code for one of its own, CLOVEERP_PUSHED_CODE_HELD, or
#           the item is not in its form, CLOVEERP_PUSH_MALFORMED). told_at is
#           the first delivery to its people, or null; held, every copy it was
#           carried and holds in the thirty days, with the digest of what it
#           holds. A push it cannot read at all raises
#           CLOVEERP_PUSH_MALFORMED (22023), and a database that is not a
#           client's CLOVEERP_NOT_A_CLIENT_DEPLOYMENT (55000): nothing is
#           applied, nothing is settled, and all of it is owed again.
#   settle  erp_meta.settle_incident_pushes(code, run, answer), on the
#           control plane, given the client's answer exactly as it came, and
#           answering {code, run, applied, waiting, failed, left, told}.
#           Applied and replay record the digest; refused is failed, with the
#           client's words, and not carried again until it changes; waiting
#           is carried again next run; the first time the client says its
#           people were told is kept as client_told_at; and a copy the
#           client does not hold as it was last carried, by held, has its
#           digest forgotten, so the next run carries it again. It refuses
#           only an answer it cannot read (CLOVEERP_PUSH_SETTLE_UNREADABLE).
#
# Neither is reshaped because of the digest: the client's is md5 of what it
# was given, and the control plane compares it with md5 of what it computed.
# A payload re-encoded on its way (a number rewritten, say) would differ, and
# be carried again every run, forever.
#
# Every client in the control plane's register whose database is up (built,
# live, suspended, or retiring with a build) and has a project, one at a
# time. For each:
#
#   1. due; a client owed nothing (no incident, no window, no telling to
#      report, and no check of what it holds) is not connected to at all, so
#      the ten-minute sweep costs a client nothing on a quiet day but the
#      one check a day. One owed only told_of is still applied and settled:
#      that is how client_told_at fills in, runs after the incident was
#      carried; and so is one owed only check_held, whose answer is what it
#      holds;
#   2. its connection string from the control plane's vault
#      (cloveerp:deployment:<ref>:db_url), masked the moment it is read and
#      refused unless it names the client's project and no other
#      deployment's;
#   3. its database must say it is a client's and have been released
#      erp_meta.apply_pushed_incidents: a client a release behind is noted,
#      owed the same at the next run, and nothing is settled for it;
#   4. apply, in one statement under a timeout, with due whole, byte for
#      byte, however large its incidents are: never cut, packed or passed
#      over. Only a due larger than MAX_PUSH_BYTES (8 MiB, a sanity limit
#      far above a long security incident with its review) is refused: said
#      in an ::error:: line every run while it is owed, with nothing sent,
#      nothing settled, and all of it owed still;
#   5. settle, in one statement, with the answer as it came (refused the
#      same way past MAX_PUSH_BYTES). A client that cannot be reached, or
#      refuses the push whole, settles nothing, so what it is owed stays
#      owed.
#
# When it runs: every ten minutes, and on the sweep's wake. The wake for an
# incident or window is a trigger on the tables its doors write
# (erp_meta.incident_change_wakes_the_sweep on erp_meta.incident,
# incident_update, incident_disclosure, incident_review, maintenance_window,
# and a client deployment named on incident_deployment or
# maintenance_window_deployment), not the doors themselves, so every writer is
# covered; it wakes only for what reaches a client deployment that is up, once
# a transaction (erp_meta.wake_the_sweep()). A settle writes only rows reached
# as every client, and updates, which wake nothing, so a run never wakes the
# next.
#
# What is carried is incident bodies: what broke, who is affected, for a
# security incident what may have been exposed, and the names of those
# handling it. The logs and summaries of this repository are public. So
# nothing carried, and no detail a client answered, is ever printed; every
# statement is VERBOSITY terse and SHOW_CONTEXT never, so no DETAIL or
# CONTEXT reaches even this script; what is printed is counts, outcomes and
# CLOVEERP_ codes. The client's words go to the control plane in the settle,
# which the console shows its owner.
#
# What is carried, and the answer, never pass through a command line: one
# argument holds 128 KiB on a runner, and a long security incident with its
# review is more. Each is written, exactly as it was read, to a file of its
# own (push.json, answer.json) in this run's directory, which only this
# script can open (umask 077: the directory 700, the file 600), and psql
# reads it itself, \set push `cat :'push_file'` on standard input (psql
# substitutes :'name' only there, never in -c; it quotes the path for the
# shell, and takes off one trailing newline, of which the file has none).
# Each file is removed the moment its statement is done, and the directory
# with everything in it on every way out of the script, an error or a
# cancelled run's signal included. None is ever printed.
#
# Usage: fleet_incident_sync.sh      (no code: every client up is served)
#
# Environment:
#   CLOVEERP_LIVE_DATABASE_URL  the control plane (required)
#   PRODUCTION_REF, DEMO_REF    refs a client's connection must not name, as
#                               well as every other ref in the register
#   PSQL                        the command (the rehearsal's stand-in)
#   CLIENT_STATEMENT_TIMEOUT    each statement on a client (default 30s)
#   CP_STATEMENT_TIMEOUT        each statement on the control plane
#                               (default 60s)
#   MAX_PUSH_BYTES              the most carried to one client in one run,
#                               and the most of its answer settled: a sanity
#                               limit, refused out loud past it (default
#                               8388608, 8 MiB; at most 268435455, the most
#                               one jsonb value holds)
#   PAUSE_SECONDS               between clients connected to (default 2)
#   FLEET_SLEEP                 the sleep command (default sleep)
#   PGCONNECT_TIMEOUT           seconds to reach a database (default 15)
#
# Exit: 0 when every client was carried what it is owed (one a release behind
# is noted, and what waits waits); 1 when any could not be, or refused what it
# was sent, each said in an ::error:: line, and every other client served all
# the same; 2 when nothing was tried.
#
# bash 3.2 and 5. Rehearsed on every build with the shared stand-ins:
# supabase/ci/fleet_incident_sync_rehearsal.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP_URL="${CLOVEERP_LIVE_DATABASE_URL:-}"
PSQL_CMD="${PSQL:-psql}"
SLEEP_CMD="${FLEET_SLEEP:-sleep}"
PAUSE="${PAUSE_SECONDS:-2}"
TIMEOUT="${CLIENT_STATEMENT_TIMEOUT:-30s}"
CP_TIMEOUT="${CP_STATEMENT_TIMEOUT:-60s}"
MAX_BYTES="${MAX_PUSH_BYTES:-8388608}"
# The most one jsonb value holds: past it, either database refuses the value
# whatever this script allows.
JSONB_MOST=268435455
RUN="${GITHUB_RUN_ID:-local}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}"
export PGAPPNAME="${PGAPPNAME:-fleet_incident_sync}"

is_ref() { [[ "$1" =~ ^[a-z0-9]{20}$ ]]; }
is_interval() { [[ "$1" =~ ^[0-9]+(ms|s|min)?$ ]]; }
bytes_of() { printf '%s' "$1" | wc -c | tr -d ' '; }

if [[ $# -gt 0 ]]; then
  echo "::error::fleet_incident_sync.sh takes no code: every run carries to every client whose database is up what reaches it, because a waiting run of the sweep may be cancelled by the next. Nothing was applied."
  exit 2
fi
if [[ -z "$CP_URL" ]]; then
  echo "::error::CLOVEERP_LIVE_DATABASE_URL is not set, so what the control plane owes its clients of its incidents and maintenance cannot be read. Nothing was applied."
  exit 2
fi
if ! [[ "$PAUSE" =~ ^[0-9]+$ ]]; then
  echo "::error::PAUSE_SECONDS must be a whole number. Nothing was applied."
  exit 2
fi
if ! [[ "$MAX_BYTES" =~ ^[1-9][0-9]{0,8}$ ]] || [[ "$MAX_BYTES" -gt "$JSONB_MOST" ]]; then
  echo "::error::MAX_PUSH_BYTES must be a whole number from 1 to ${JSONB_MOST} (the most one jsonb value holds). Nothing was applied."
  exit 2
fi
# A statement that sets a timeout psql cannot read would be the first error
# on a connection whose errors are read in order.
if ! is_interval "$TIMEOUT" || ! is_interval "$CP_TIMEOUT"; then
  echo "::error::CLIENT_STATEMENT_TIMEOUT and CP_STATEMENT_TIMEOUT are a number of ms, s or min. Nothing was applied."
  exit 2
fi

# What is carried and what is answered are written here, for psql to read:
# nobody but this script may open them, and they go with the directory
# however the script ends. bash runs the EXIT trap for a signal that ends it
# as well; HUP, INT and TERM are made plain exits here all the same, so that
# nothing depends on it. (A cancelled run's SIGKILL runs nothing; the
# runner's disk goes with the runner.)
umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/fleet_incident_sync.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
push_file="$work/push.json"
answer_file="$work/answer.json"
# forget: what one client was carried and answered, gone before the next.
forget() { rm -f "$push_file" "$answer_file" "$work/out"; }

# On a runner GitHub hides a value printed after this; a terminal would show
# it, so nowhere else.
mask() {
  if [[ "${GITHUB_ACTIONS:-}" == true && -n "${1:-}" ]]; then
    echo "::add-mask::$1"
  fi
}
# The control plane's own string is a secret GitHub masks already; masked
# here too, so that nothing depends on how this script is started.
mask "$CP_URL"

# What psql said was wrong, on one line, for a statement that carried
# nothing owed (the register, the vault, the check of a client): its words
# cannot hold an incident.
said() {
  local first
  first=$(grep -E 'ERROR|FATAL|error|refus|could not|^x ' "$work/err" 2> /dev/null | head -n 1 || true)
  [[ -n "$first" ]] || first=$(head -n 1 "$work/err" 2> /dev/null || true)
  first="${first#psql:<stdin>:*: }"
  printf '%s' "${first:-no reason given}" | tr -s ' \t' '  ' | jq -Rr '.[0:300]'
}

# codes <words>: what went wrong with a statement that carried what is owed,
# or what a client answered of it, in words a public log may hold: the
# CLOVEERP_ codes it names, else the kind of failure. Never the words
# themselves.
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
# refusal's payload would be; and every one under a timeout, set in SQL (the
# pooler drops PGOPTIONS).
cp_q() { $PSQL_CMD "$CP_URL" -v ON_ERROR_STOP=1 -X -q -tA -v VERBOSITY=terse -v SHOW_CONTEXT=never -v timeout="$CP_TIMEOUT" "$@"; }
client_q() {
  local url="$1"
  shift
  $PSQL_CMD "$url" -v ON_ERROR_STOP=1 -X -q -tA -v VERBOSITY=terse -v SHOW_CONTEXT=never -v timeout="$TIMEOUT" "$@"
}
reg() { CLOVEERP_LIVE_DATABASE_URL="$CP_URL" PSQL="$PSQL_CMD" "$HERE/fleet_register.sh" "$@"; }

# ── The control plane: what it can say, and to whom ──────────────────────────
ready=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-ready
set statement_timeout = :'timeout';
select (to_regclass('erp_meta.deployment') is not null)::text || '|'
       || (to_regprocedure('erp_meta.incident_pushes_due(text)') is not null)::text || '|'
       || (to_regprocedure('erp_meta.settle_incident_pushes(text,text,jsonb)') is not null)::text;
SQL
) || { echo "::error::the control plane could not be read ($(said)). Nothing was applied."; exit 1; }
IFS='|' read -r has_register has_due has_settle <<< "$ready"
if [[ "$has_register" != true ]]; then
  echo "the control plane has no register of deployments yet, so no client is owed an incident or a maintenance window"
  exit 0
fi
if [[ "$has_due" != true || "$has_settle" != true ]]; then
  echo "the control plane has no erp_meta.incident_pushes_due and erp_meta.settle_incident_pushes yet (20261012060000 is not released there), so no incident or maintenance window is carried to a client by this sync; what reaches them waits for it"
  exit 0
fi

clients=$(cp_q 2> "$work/err" <<'SQL'
-- fleet: cp-clients
set statement_timeout = :'timeout';
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
set statement_timeout = :'timeout';
select coalesce(string_agg(d.project_ref, ','), '') from erp_meta.deployment d where d.project_ref is not null;
SQL
) || { echo "::error::the control plane's register could not be read ($(said)). Nothing was applied."; exit 1; }
all_refs="${all_refs},${PRODUCTION_REF:-xpzffnnhnhcqyjqcueja},${DEMO_REF:-}"

count=$(jq 'length' <<< "$clients")
if [[ "$count" -eq 0 ]]; then
  echo "no client in the register has a database that is up (built, live, suspended or retiring); nobody is owed an incident or a maintenance window"
  exit 0
fi

echo "the register: ${count} client(s) whose database is up"
{
  echo "## Incidents and maintenance carried to each client"
  echo
  echo "| client | owed | answered | told | settled | not done |"
  echo "|---|---|---|---|---|---|"
} >> "$SUMMARY"

troubled=0
skipped=0
connected=0

# ── One client ───────────────────────────────────────────────────────────────
# trouble <words>: said at once and gathered in TROUBLE, for the summary.
# Only counts, outcomes, codes and what the register says reach it.
trouble() {
  local said_here
  said_here=$(printf '%s' "$*" | sed -E 's/([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+)/\1…@\2/g')
  echo "::error::${CODE}: ${said_here}"
  TROUBLE="${TROUBLE:+${TROUBLE}; }${said_here}"
}

# row: this client's line in the summary, and its count of trouble.
row() {
  echo "| ${CODE} | ${OWED_WORDS} | ${ANSWER_WORDS} | ${TOLD_WORDS} | ${SETTLED_WORDS} | ${TROUBLE} |" >> "$SUMMARY"
  if [[ -n "$TROUBLE" ]]; then
    troubled=$((troubled + 1))
  fi
}

serve_client() {
  CODE="$1"
  TROUBLE=""
  OWED_WORDS=""
  ANSWER_WORDS=""
  TOLD_WORDS=""
  SETTLED_WORDS=""
  local ref="$2"
  local url="" vault state kind can_apply other due answer="" settled sent_ids counts line rc=0 settle_rc=0 size
  local n_inc=0 n_win=0 n_told_of=0 n_sent=0 check_held=false
  local a_applied=0 a_replay=0 a_waiting=0 a_refused=0 a_other=0 a_missing=0 a_told=0 a_held=0 a_has_held=false
  local -a others

  if ! is_ref "$ref"; then
    trouble "the register gives it no project ref ('${ref}'), so nothing was applied there"
    row
    return 0
  fi

  # What the control plane owes it, before anything is asked of the client.
  if ! due=$(cp_q -v code="$CODE" 2> "$work/err" <<'SQL'
-- fleet: cp-due
set statement_timeout = :'timeout';
select erp_meta.incident_pushes_due(:'code')::text;
SQL
  ); then
    trouble "what the control plane owes it could not be read ($(codes "$(cat "$work/err")")); nothing was applied there"
    row
    return 0
  fi
  # Read, never changed: that it is what the client takes, and what it holds.
  if [[ "$due" == *$'\n'* ]] || ! counts=$(jq -r --arg code "$CODE" '
        def uuid: if type == "string" then test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") else false end;
        def item: if type == "object"
                  then (.id | uuid) and (.digest | if type == "string" then length > 0 else false end)
                       and (.payload | type == "object")
                  else false end;
        def list(f): if type == "array" then all(.[]; f) else false end;
        if type == "object" and .code == $code
           and (.incidents | list(item)) and (.windows | list(item)) and (.told_of | list(uuid))
           and (.check_held | . == null or type == "boolean")
        then "\(.incidents | length) \(.windows | length) \(.told_of | length) \(.check_held == true)"
        else error("not what a client is owed") end' <<< "$due" 2> /dev/null) || [[ -z "$counts" ]]; then
    trouble "what the control plane owes it came back in a shape this sync does not read; nothing was applied there"
    row
    return 0
  fi
  read -r n_inc n_win n_told_of check_held <<< "$counts"
  if [[ $((n_inc + n_win + n_told_of)) -eq 0 && "$check_held" != true ]]; then
    echo "${CODE}: nothing due"
    OWED_WORDS="nothing due"
    row
    return 0
  fi
  OWED_WORDS="${n_inc} incident(s), ${n_win} window(s)"
  if [[ "$n_told_of" -gt 0 ]]; then
    OWED_WORDS="${OWED_WORDS}, ${n_told_of} to say when told"
  fi
  if [[ "$check_held" == true ]]; then
    OWED_WORDS="${OWED_WORDS}, a check of what it holds"
  fi
  n_sent=$((n_inc + n_win))

  # Whole, as the control plane wrote it, or not at all. The limit is a
  # sanity limit, not a size anything owed reaches; past it, nothing is sent
  # and nothing is passed over in silence.
  size=$(bytes_of "$due")
  if [[ "$size" -gt "$MAX_BYTES" ]]; then
    trouble "what it is owed is ${size} bytes, more than the ${MAX_BYTES} one run carries to a client (MAX_PUSH_BYTES); nothing was sent there or settled, and all of it stays owed"
    ANSWER_WORDS="none sent"
    row
    return 0
  fi
  sent_ids=$(jq -c '[(.incidents // [])[].id, (.windows // [])[].id]' <<< "$due")

  # Its connection, read only now that it is owed something.
  if [[ "$connected" -gt 0 && "$PAUSE" -gt 0 ]]; then
    $SLEEP_CMD "$PAUSE"
  fi
  connected=$((connected + 1))
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

  # Its database: a client's, and released the routine.
  if [[ -n "$url" ]]; then
    if ! state=$(client_q "$url" 2> "$work/err" <<'SQL'
-- fleet: client-state
set statement_timeout = :'timeout';
select coalesce(erp.deployment_kind(), '') || '|'
       || (to_regprocedure('erp_meta.apply_pushed_incidents(jsonb)') is not null)::text;
SQL
    ); then
      trouble "its database could not be reached or read ($(said)); nothing was applied there, and nothing settled"
      url=""
    else
      IFS='|' read -r kind can_apply <<< "$state"
      if [[ "$kind" != client ]]; then
        trouble "its database says it is the ${kind:-unknown} deployment, not a client's; nothing was applied there"
        url=""
      elif [[ "$can_apply" != true ]]; then
        echo "::notice::${CODE} has not yet been released the routine that holds the incidents and maintenance it is carried (20261012060000). The next train brings it, and the sweep after it carries what reaches it. Nothing was applied there."
        ANSWER_WORDS="not released the routine yet"
        skipped=$((skipped + 1))
        url=""
      fi
    fi
  fi
  if [[ -z "$url" ]]; then
    echo "${CODE}: owed ${OWED_WORDS}; ${ANSWER_WORDS:-not applied}; nothing settled"
    row
    return 0
  fi

  # Everything it is owed, in one statement, as it is owed. Answered item by
  # item: a code held by one of its own, or a component it does not know yet,
  # is an answer, not an error, so one item never holds up the rest. Given
  # through a file psql reads itself, never as an argument (above), and the
  # file gone the moment the statement is done, however it went.
  printf '%s' "$due" > "$push_file"
  client_q "$url" -v push_file="$push_file" > "$work/out" 2> "$work/err" <<'SQL' || rc=$?
-- fleet: client-apply
\set VERBOSITY terse
\set SHOW_CONTEXT never
\set push `cat :'push_file'`
set statement_timeout = :'timeout';
select erp_meta.apply_pushed_incidents(:'push'::jsonb)::text;
SQL
  rm -f "$push_file"
  answer=$(cat "$work/out")
  rm -f "$work/out"
  line=$(grep -E '(^|: )(ERROR|FATAL):' "$work/err" 2> /dev/null | head -n 1 || true)
  if [[ "$rc" -ne 0 ]]; then
    case "$line" in
      *CLOVEERP_PUSH_MALFORMED*|*CLOVEERP_NOT_A_CLIENT_DEPLOYMENT*)
        # The push whole: there is no answer to settle, so nothing is, and
        # all of it is owed again.
        trouble "its database refused the push whole ($(codes "$line")); nothing was applied or settled there, and all of it is owed again at the next run"
        ANSWER_WORDS="refused whole" ;;
      *)
        trouble "what it is owed could not be applied there ($(codes "$(cat "$work/err")")); nothing was settled, and all of it is owed again at the next run"
        ANSWER_WORDS="not answered" ;;
    esac
    answer=""
  elif [[ -z "$answer" ]]; then
    trouble "what it is owed could not be applied there (no reason given); nothing was settled, and all of it is owed again at the next run"
    ANSWER_WORDS="not answered"
  elif [[ "$answer" == *$'\n'* ]] || ! counts=$(printf '%s\n%s\n' "$sent_ids" "$answer" | jq -r -n '
        def list: if type == "array" then . else error("not a list") end;
        input as $sent | input
        | if type == "object" then . else error("not an answer") end
        | ((.incidents // []) | list) as $i | ((.windows // []) | list) as $w | ((.told // []) | list) as $t
        | ((.held // []) | list) as $h
        | ($i + $w) as $a
        | if all($a[]; type == "object" and (.id | type == "string") and (.outcome | type == "string"))
             and all($h[]; type == "object")
          then . else error("an answer that is not one") end
        | [($a | map(select(.outcome == "applied")) | length),
           ($a | map(select(.outcome == "replay")) | length),
           ($a | map(select(.outcome == "waiting")) | length),
           ($a | map(select(.outcome == "refused")) | length),
           ($a | map(select(.outcome | IN("applied", "replay", "waiting", "refused") | not)) | length),
           ($sent - ($a | map(.id)) | length),
           ($t | map(select(type == "object" and .told_at != null)) | length),
           ($h | length),
           has("held")]
        | map(tostring) | join(" ")' 2> /dev/null) || [[ -z "$counts" ]]; then
    trouble "its database answered in a shape this sync does not read; nothing was settled"
    ANSWER_WORDS="not read"
    answer=""
  else
    read -r a_applied a_replay a_waiting a_refused a_other a_missing a_told a_held a_has_held <<< "$counts"
    ANSWER_WORDS=""
    [[ "$a_applied" -eq 0 ]] || ANSWER_WORDS="${ANSWER_WORDS:+${ANSWER_WORDS}, }${a_applied} applied"
    [[ "$a_replay" -eq 0 ]] || ANSWER_WORDS="${ANSWER_WORDS:+${ANSWER_WORDS}, }${a_replay} replay"
    [[ "$a_waiting" -eq 0 ]] || ANSWER_WORDS="${ANSWER_WORDS:+${ANSWER_WORDS}, }${a_waiting} waiting"
    [[ "$a_refused" -eq 0 ]] || ANSWER_WORDS="${ANSWER_WORDS:+${ANSWER_WORDS}, }${a_refused} refused"
    [[ "$a_other" -eq 0 ]] || ANSWER_WORDS="${ANSWER_WORDS:+${ANSWER_WORDS}, }${a_other} not read"
    [[ "$a_missing" -eq 0 ]] || ANSWER_WORDS="${ANSWER_WORDS:+${ANSWER_WORDS}, }${a_missing} not answered"
    if [[ "$check_held" == true ]]; then
      ANSWER_WORDS="${ANSWER_WORDS:+${ANSWER_WORDS}, }${a_held} held"
    fi
    ANSWER_WORDS="${ANSWER_WORDS:-no item}"
    TOLD_WORDS="$a_told"
    if [[ "$a_other" -gt 0 ]]; then
      # The control plane settles an answer whole, and would refuse this.
      trouble "its database answered ${a_other} item(s) with something that is not applied, replay, waiting or refused; nothing was settled"
      answer=""
    fi
    if [[ "$a_missing" -gt 0 ]]; then
      trouble "its database did not answer ${a_missing} of the ${n_sent} item(s) it was sent; those are not settled, and are owed again at the next run"
    fi
    if [[ "$check_held" == true && "$a_has_held" != true ]]; then
      # Settled all the same: what it did answer stands. What it holds goes
      # unchecked until it says.
      trouble "it was asked which copies it holds, and its database did not say (no held in its answer); a copy it lost is not carried again until it does"
    fi
    if [[ "$a_waiting" -gt 0 ]]; then
      echo "::notice::${CODE}: ${a_waiting} item(s) wait for a severity, component, provider or timeline its database does not know yet (it is behind on its release), or for a failure that may pass; they are carried again at the next run."
    fi
    if [[ "$a_refused" -gt 0 ]]; then
      trouble "its database refused ${a_refused} item(s) ($(codes "$(jq -r '((.incidents // []) + (.windows // []))[] | select(.outcome == "refused") | (.detail // "" | tostring)' <<< "$answer")")); each is settled failed on the control plane with its full words, and is not carried again until it changes"
    fi
  fi

  # One settle, with the answer as it came (held and all): what the client
  # did not answer is not in it, so it stays owed. Through a file psql reads
  # itself, as the push was, gone the moment the statement is done.
  if [[ -n "$answer" ]]; then
    size=$(bytes_of "$answer")
    if [[ "$size" -gt "$MAX_BYTES" ]]; then
      trouble "its answer is ${size} bytes, more than the ${MAX_BYTES} one run settles for a client (MAX_PUSH_BYTES); nothing was settled, and what it holds now it answers as replay at the next run"
    else
      printf '%s' "$answer" > "$answer_file"
      settled=$(cp_q -v code="$CODE" -v run="$RUN" -v answer_file="$answer_file" 2> "$work/err" <<'SQL'
-- fleet: cp-settle
\set VERBOSITY terse
\set SHOW_CONTEXT never
\set answer `cat :'answer_file'`
set statement_timeout = :'timeout';
select erp_meta.settle_incident_pushes(:'code', :'run', :'answer'::jsonb)::text;
SQL
      ) || settle_rc=$?
      rm -f "$answer_file"
      if [[ "$settle_rc" -ne 0 ]]; then
        trouble "what it answered could not be settled on the control plane ($(codes "$(cat "$work/err")")); it stays owed, and what it holds now it answers as replay at the next run"
      else
        SETTLED_WORDS=$(jq -r '"\(.applied) applied, \(.waiting) waiting, \(.failed) failed, \(.told) told"
                               + (if (.left // 0) > 0 then ", \(.left) left" else "" end)' <<< "$settled" 2> /dev/null || true)
        SETTLED_WORDS="${SETTLED_WORDS:-settled}"
      fi
    fi
  fi

  echo "${CODE}: owed ${OWED_WORDS}; answered ${ANSWER_WORDS:-nothing}; ${TOLD_WORDS:-0} told; settled ${SETTLED_WORDS:-nothing}"
  row
  return 0
}

for ((c = 0; c < count; c++)); do
  serve_client "$(jq -r ".[$c].code" <<< "$clients")" "$(jq -r ".[$c].ref" <<< "$clients")"
  forget
done

if [[ "$troubled" -gt 0 ]]; then
  echo "::error::${troubled} of ${count} client(s) could not be carried what reaches them of the control plane's incidents and maintenance, or refused it; each is said above, and what was answered is settled. Every other client was served."
  exit 1
fi
if [[ "$skipped" -gt 0 ]]; then
  echo "every client was carried what reaches it, but ${skipped} of ${count} not yet released the routine"
else
  echo "every client was carried what reaches it of the control plane's incidents and maintenance (${count})"
fi
