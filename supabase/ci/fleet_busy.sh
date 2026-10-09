#!/usr/bin/env bash
#
# Whether another of the fleet's workflows is at work where this one is about
# to be, asked of GitHub; and a wait until it is not.
#
# Several workflows reach the same client's project, and some must not
# overlap: a dump (fleet_backup.yml, fleet_export.yml) holds a share lock on
# every table it copies, and a release replaying into that database meets it
# and fails on its own thirty-second lock limit; a rename (fleet_rename.yml)
# and a change of secrets (fleet_secrets.yml) both set the project's auth
# settings and its functions' address, from what each read when it began; a
# new database password (fleet_secrets.yml, rotate_db_password, in its step
# of its own) breaks every run that read the old connection from the vault.
# Each used to look once, at its start, for a release train anywhere, or not
# at all. So each now asks here, just before it touches a database, about
# each thing that would meet it there, and both sides of each pair ask: a
# copy and a release, a rename and a change of secrets, a rotation and a
# rename, an export or a backup. The waits are arranged so that two runs
# that ask about each other never wait for each other.
#
# Usage:
#
#   fleet_busy.sh release <target>
#       A release (deploy.yml, through release.yml) to <target>
#       (control-plane, demonstration or a client's code) that has passed its
#       own wait for copies, release.yml's "No copy of this database is being
#       made", and not yet finished "Apply pending migrations by replay".
#       Asked before a copy of that database is made. A release still before
#       or at its wait is not counted: it waits for the copy, and counting it
#       would have the two wait for each other.
#
#   fleet_busy.sh copy <target>
#       A copy being made of <target> (production is the control plane): a
#       fleet_backup.yml run in its "Copy every database" step (which
#       database it is on is not something GitHub can say, so any), or, for a
#       client, a fleet_export.yml run of that client in its "Export" step.
#       Asked by release.yml before its first migration.
#
#   fleet_busy.sh runs <workflow file>=<step name> ...
#       A run of one of those workflows, other than this one, that is in that
#       step; or that began before this one (a smaller run id) and has not
#       finished that step yet, because it is ahead in the queue. An earlier
#       run never waits for a later one that has not reached the step, so
#       two runs that ask this about each other never wait for each other,
#       as long as each asks before its own step that the other asks about.
#       A step skipped (its if: false) is finished. Every name asked about
#       is checked against its workflow by fleet_busy_rehearsal.sh.
#
#   fleet_busy.sh runs-in <workflow file>=<step name> ...
#       A run of one of those workflows, other than this one, that is in that
#       step, or has just finished the step before it and is about to begin
#       it (no step of its job running, and that one the next); whatever its
#       run id, and nothing ahead in the queue. Asked from inside a step that
#       the other run asks about (fleet_backup.sh, inside "Copy every
#       database", about a rotation): a run that has not reached its step
#       waits for this one, at its own wait, so counting it here would have
#       the two wait for each other.
#
#   A run of fleet_secrets.yml is counted for its step "Change the database
#   passwords, one client at a time" only when it changes passwords: its
#   title (run-name, "fleet secrets: <action> for <code>") names
#   rotate_db_password, or names no action at all (a run from before titles
#   said). One that names another action skips that step, but GitHub cannot
#   say so until the run reaches it, after its own wait of up to an hour.
#   And for its step "Change them, one client at a time" only when its title
#   does not name resend_webhook (or resend_webhook_delete): those make or
#   delete a project's endpoint at the email provider, at the project's ref,
#   and set no address and no auth setting, which is what a rename waits for
#   that step over; they take minutes a client, and a rename would wait out
#   the whole fleet's for nothing.
#
#   fleet_busy.sh wait <minutes> <one of the four above>
#       Asked every POLL_SECONDS (default 60) until nothing is busy (exit 0),
#       or until <minutes> have passed (exit 1, saying what still is). A
#       GitHub that cannot be asked counts as busy, as every wait in these
#       workflows always has: not knowing is not a clear road.
#
# Exit, without wait: 0 nothing is busy, and nothing is printed; 1 something
# is, one line per run on standard output saying which and why; 2 GitHub
# could not be asked, said on standard output (1 and 2 print the same way,
# so wait can repeat it).
#
# Environment:
#   GH             the gh command (default gh); the rehearsal's stand-in
#   GH_REPO        owner/name of this repository
#   GH_TOKEN       gh's token: the workflow's own suffices, since the
#                  repository is public and so are its runs
#   GITHUB_RUN_ID  this run, which is never counted
#   POLL_SECONDS   wait's pause between questions (default 60)
#   FLEET_SLEEP    the sleep command (default sleep)
#
# Nothing here is secret, and nothing here touches a database.
#
# bash 3.2 and 5. Rehearsed on every build: supabase/ci/fleet_busy_rehearsal.sh.
set -euo pipefail

GH_CMD="${GH:-gh}"
SLEEP_CMD="${FLEET_SLEEP:-sleep}"
POLL="${POLL_SECONDS:-60}"
SELF="${GITHUB_RUN_ID:-0}"
[[ "$SELF" =~ ^[0-9]+$ ]] || SELF=0

# The steps the waits are arranged around. A step renamed in its workflow
# must be renamed here, or a wait stops seeing it.
RELEASE_WAIT_STEP="No copy of this database is being made"
RELEASE_REPLAY_STEP="Apply pending migrations by replay"
BACKUP_STEP="Copy every database"
EXPORT_STEP="Export"
SECRETS_WORKFLOW="fleet_secrets.yml"
ROTATION_STEP="Change the database passwords, one client at a time"
CHANGES_STEP="Change them, one client at a time"

usage() {
  echo "x usage: fleet_busy.sh release <target> | copy <target> | runs <workflow>=<step> ... | runs-in <workflow>=<step> ... | wait <minutes> <one of them>" >&2
  exit 9
}

is_target() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; }

# open_runs <workflow file> [rotations|changes]: the id of each run of it
# that has not finished and was not started by a pull request (a pull
# request's runs only read); with rotations, only those whose title does not
# name an action other than rotate_db_password; with changes, only those
# whose title does not name resend_webhook (see the header).
open_runs() {
  local only='.'
  if [[ "${2:-}" == rotations ]]; then
    only='select(((.display_title // "") | test("rotate_db_password")) or ((.display_title // "") | test("set_function_secrets|patch_auth|resend_webhook") | not))'
  elif [[ "${2:-}" == changes ]]; then
    only='select((.display_title // "") | test("resend_webhook") | not)'
  fi
  $GH_CMD api "repos/${GH_REPO}/actions/workflows/$1/runs?per_page=50" \
    --jq ".workflow_runs[] | select(.status != \"completed\" and .event != \"pull_request\") | ${only} | .id"
}

# jobs_of <run id>: one JSON line per job of its latest attempt, with its
# steps' names and statuses.
jobs_of() {
  $GH_CMD api "repos/${GH_REPO}/actions/runs/$1/jobs?per_page=100" --paginate \
    --jq '.jobs[] | {name, status, steps: [(.steps // [])[] | {name, status}]} | tojson'
}

# ask <question...>: prints one line per busy run; returns 0 when none, 1
# when some, 2 when GitHub could not be asked.
ask() {
  local what="$1" ids id jobs found="" line
  shift
  if [[ -z "${GH_REPO:-}" ]]; then
    echo "GitHub could not be asked: GH_REPO (owner/name) is not set"
    return 2
  fi
  case "$what" in
    release)
      local target="${1:-}" label
      is_target "$target" || usage
      label="$target"
      if [[ "$target" == control-plane ]]; then label=production; fi
      ids=$(open_runs deploy.yml 2>&1) || { echo "GitHub could not be asked which releases are running: $(printf '%s' "$ids" | head -n 1)"; return 2; }
      for id in $ids; do
        [[ "$id" != "$SELF" ]] || continue
        jobs=$(jobs_of "$id" 2>&1) || { echo "GitHub could not be asked about deploy.yml run ${id}: $(printf '%s' "$jobs" | head -n 1)"; return 2; }
        # The job release.yml names "release to the <target>", inside the
        # job of deploy.yml that called it ("<caller> / release to the …").
        line=$(printf '%s\n' "$jobs" | jq -r --arg t "release to the ${label}" --arg w "$RELEASE_WAIT_STEP" --arg r "$RELEASE_REPLAY_STEP" '
          select(.name == $t or (.name | endswith(" / " + $t)))
          | select(.status == "in_progress")
          | ([.steps[] | select(.name == $w) | .status][0] // "absent") as $wait
          | ([.steps[] | select(.name == $r) | .status][0] // "absent") as $replay
          | select(($wait == "completed" or $wait == "absent") and $replay != "completed")
          | .name' 2> /dev/null | head -n 1)
        if [[ -n "$line" ]]; then
          echo "deploy.yml run ${id}: ${line}, past its wait for copies and not through its replay"
          found=yes
        fi
      done ;;
    copy)
      local target="${1:-}" export_job=""
      is_target "$target" || usage
      case "$target" in
        production|control-plane|demonstration) : ;;
        *) export_job="export ${target}" ;;
      esac
      ids=$(open_runs fleet_backup.yml 2>&1) || { echo "GitHub could not be asked which backups are running: $(printf '%s' "$ids" | head -n 1)"; return 2; }
      for id in $ids; do
        [[ "$id" != "$SELF" ]] || continue
        jobs=$(jobs_of "$id" 2>&1) || { echo "GitHub could not be asked about fleet_backup.yml run ${id}: $(printf '%s' "$jobs" | head -n 1)"; return 2; }
        if printf '%s\n' "$jobs" | jq -e --arg s "$BACKUP_STEP" 'select(any(.steps[]; .name == $s and .status == "in_progress"))' > /dev/null 2>&1; then
          echo "fleet_backup.yml run ${id}: copying databases off the platform"
          found=yes
        fi
      done
      if [[ -n "$export_job" ]]; then
        ids=$(open_runs fleet_export.yml 2>&1) || { echo "GitHub could not be asked which exports are running: $(printf '%s' "$ids" | head -n 1)"; return 2; }
        for id in $ids; do
          [[ "$id" != "$SELF" ]] || continue
          jobs=$(jobs_of "$id" 2>&1) || { echo "GitHub could not be asked about fleet_export.yml run ${id}: $(printf '%s' "$jobs" | head -n 1)"; return 2; }
          if printf '%s\n' "$jobs" | jq -e --arg j "$export_job" --arg s "$EXPORT_STEP" 'select(.name == $j and any(.steps[]; .name == $s and .status == "in_progress"))' > /dev/null 2>&1; then
            echo "fleet_export.yml run ${id}: exporting ${target}"
            found=yes
          fi
        done
      fi ;;
    runs|runs-in)
      local spec wf step state which
      [[ $# -gt 0 ]] || usage
      for spec in "$@"; do
        wf="${spec%%=*}"; step="${spec#*=}"
        [[ "$wf" =~ ^[a-z0-9_.-]+\.yml$ && -n "$step" && "$step" != "$spec" ]] || usage
        which=""
        if [[ "$wf" == "$SECRETS_WORKFLOW" && "$step" == "$ROTATION_STEP" ]]; then which=rotations; fi
        if [[ "$wf" == "$SECRETS_WORKFLOW" && "$step" == "$CHANGES_STEP" ]]; then which=changes; fi
        ids=$(open_runs "$wf" "$which" 2>&1) || { echo "GitHub could not be asked which ${wf} runs are going: $(printf '%s' "$ids" | head -n 1)"; return 2; }
        for id in $ids; do
          [[ "$id" != "$SELF" ]] || continue
          jobs=$(jobs_of "$id" 2>&1) || { echo "GitHub could not be asked about ${wf} run ${id}: $(printf '%s' "$jobs" | head -n 1)"; return 2; }
          # in_progress in any job, or next in a job that is running with no
          # step running (between the step before and it); done when
          # completed in one (a skipped step is completed); otherwise still
          # to do.
          state=$(printf '%s\n' "$jobs" | jq -rs --arg s "$step" '
            [.[].steps[] | select(.name == $s) | .status] as $st
            | if any($st[]; . == "in_progress") then "in"
              elif any($st[]; . == "completed") then "done"
              elif any(.[]; .status == "in_progress"
                            and (any(.steps[]; .status == "in_progress") | not)
                            and ([.steps[] | select(.status != "completed")][0].name // "") == $s) then "next"
              else "ahead" end' 2> /dev/null || echo ahead)
          if [[ "$state" == in || ( "$state" == next && "$what" == runs-in ) ]]; then
            echo "${wf} run ${id}: in \"${step}\""
            found=yes
          elif [[ "$what" == runs && "$state" != done && "$id" -lt "$SELF" ]]; then
            echo "${wf} run ${id}: began before this run, and has \"${step}\" still to do"
            found=yes
          fi
        done
      done ;;
    *) usage ;;
  esac
  [[ -z "$found" ]]
}

cmd="${1:-}"
shift || true
case "$cmd" in
  release|copy|runs|runs-in)
    rc=0
    ask "$cmd" "$@" || rc=$?
    exit "$rc" ;;
  wait)
    minutes="${1:-}"
    shift || true
    [[ "$minutes" =~ ^[0-9]+$ && "$POLL" =~ ^[1-9][0-9]*$ ]] || usage
    [[ $# -gt 0 ]] || usage
    # Counted in questions, not read off the clock: the same on a runner
    # and in the rehearsal, whose sleep does not sleep.
    tries=$(( minutes * 60 / POLL ))
    asked=0
    while :; do
      rc=0
      said=$(ask "$@") || rc=$?
      if [[ "$rc" -eq 0 ]]; then
        exit 0
      fi
      if [[ "$rc" -eq 9 ]]; then exit 9; fi
      if [[ "$asked" -ge "$tries" ]]; then
        printf '%s\n' "$said"
        exit 1
      fi
      printf '%s\n' "$said" | sed "s/\$/; asking again in ${POLL} s/"
      $SLEEP_CMD "$POLL"
      asked=$((asked + 1))
    done ;;
  *) usage ;;
esac
