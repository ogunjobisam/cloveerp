#!/usr/bin/env bash
#
# supabase/ci/fleet_busy.sh, rehearsed with no GitHub.
#
# The fleet's workflows ask it, just before they touch a database, whether
# another is at work there: a copy before a release replays, a release before
# a copy is made, a rename and a change of secrets before each other, a new
# password and a rename, an export or a backup before each other. Wrong one
# way, two of them
# meet in a client's database and one fails halfway; wrong the other, two
# wait for each other until both give up. So every build runs it here first,
# against a gh that answers from files: which runs and steps count and which
# do not, that two runs asking about each other never both wait, that a
# GitHub that cannot be asked counts as busy, that a wait asks again and
# gives up when it said it would, and that every step a workflow or script
# asks about is a step of the workflow it names. Seconds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet_busy.sh"
# shellcheck source=supabase/ci/fleet_rehearsal_fakes.sh
. "$HERE/fleet_rehearsal_fakes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
fleet_fakes "$work/bin"
export FAKE_DIR="$work/fake"

BASE_ENV=(GH="$work/bin/gh" GH_REPO=cloveerp/rehearsal GITHUB_RUN_ID=500 FLEET_SLEEP="$work/bin/sleep" POLL_SECONDS=60)
WAIT="No copy of this database is being made"
REPLAY="Apply pending migrations by replay"

CASES=0
FAILED=0
# fresh: an empty GitHub; then the case's runs and jobs, then run.
fresh() { CURRENT="$1"; rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR"; }
run() {
  local vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
  shift || true
  out=$(env "${BASE_ENV[@]}" ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" 2>&1)
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
    sed 's/^/       > /' "$FAKE_DIR/order.log" 2> /dev/null | head -n 20
  fi
}
sleeps() { grep -c '^sleep 60$' "$FAKE_DIR/order.log" 2> /dev/null || true; }

# 1. A release to the target, as a copy asks about it
fresh "no release running"
run -- release acme
check '[[ $status -eq 0 && -z "$out" && "$(cat "$FAKE_DIR/gh.log")" == "repos/cloveerp/rehearsal/actions/workflows/deploy.yml/runs?per_page=50" ]]' "nothing busy, one question"
fresh "a release to acme replaying"
gh_run deploy.yml 41
gh_job 41 "release to acme / may the acme be released" completed
gh_job 41 "release to acme / release to the acme" in_progress "$WAIT=completed" "Pause the scheduler for the length of the replay=completed" "$REPLAY=in_progress"
run -- release acme
check '[[ $status -eq 1 && "$out" == "deploy.yml run 41: release to acme / release to the acme, past its wait for copies and not through its replay" ]]' "busy, naming the run"
fresh "a release to acme between its wait and its replay"
gh_run deploy.yml 41
gh_job 41 "release to acme / release to the acme" in_progress "$WAIT=completed" "$REPLAY=queued"
run -- release acme
check '[[ $status -eq 1 ]]' "busy: the scheduler is paused and the replay is next"
fresh "a release to acme still at its wait"
gh_run deploy.yml 41
gh_job 41 "release to acme / release to the acme" in_progress "$WAIT=in_progress" "$REPLAY=queued"
run -- release acme
check '[[ $status -eq 0 ]]' "not busy: it waits for the copy, and counting it would have both wait"
fresh "a release to acme not yet at its wait"
gh_run deploy.yml 41
gh_job 41 "release to acme / release to the acme" in_progress "Install the psql client=in_progress" "$WAIT=queued" "$REPLAY=queued"
run -- release acme
check '[[ $status -eq 0 ]]' "not busy: it will wait for the copy"
fresh "a release to acme through its replay"
gh_run deploy.yml 41
gh_job 41 "release to acme / release to the acme" in_progress "$WAIT=completed" "$REPLAY=completed" "Prove the acme database=in_progress"
run -- release acme
check '[[ $status -eq 0 ]]' "not busy: the proof only reads"
fresh "a release from before the wait existed"
gh_run deploy.yml 41
gh_job 41 "release to acme / release to the acme" in_progress "$REPLAY=in_progress"
run -- release acme
check '[[ $status -eq 1 ]]' "busy: a release that cannot wait for a copy is waited for"
fresh "a release to another client"
gh_run deploy.yml 41
gh_job 41 "release to acme-foods / release to the acme-foods" in_progress "$WAIT=completed" "$REPLAY=in_progress"
gh_job 41 "release to the demonstration / release to the demonstration" completed
run -- release acme
check '[[ $status -eq 0 ]]' "not busy: acme-foods is not acme"
fresh "the control plane"
gh_run deploy.yml 41
gh_job 41 "release to the control plane / release to the production" in_progress "$WAIT=completed" "$REPLAY=in_progress"
run -- release control-plane
check '[[ $status -eq 1 && "$out" == *"release to the production"* ]]' "the control plane is production's release"
fresh "a pull request's dry run, and a finished train"
gh_run deploy.yml 41 in_progress pull_request
gh_job 41 "release to acme / release to the acme" in_progress "$WAIT=completed" "$REPLAY=in_progress"
gh_run deploy.yml 42 completed
run -- release acme
check '[[ $status -eq 0 && "$(grep -c "/jobs" "$FAKE_DIR/gh.log")" == 0 ]]' "neither counted, nor asked about"
fresh "this run itself"
gh_run deploy.yml 500
gh_job 500 "release to acme / release to the acme" in_progress "$WAIT=completed" "$REPLAY=in_progress"
run -- release acme
check '[[ $status -eq 0 ]]' "never counted"
fresh "GitHub cannot be asked"
run FAKE_GH_FAIL=yes -- release acme
check '[[ $status -eq 2 && "$out" == "GitHub could not be asked which releases are running: HTTP 502"* ]]' "2, saying so"
fresh "no repository named"
run GH_REPO= -- release acme
check '[[ $status -eq 2 && "$out" == *"GH_REPO"* && ! -e "$FAKE_DIR/gh.log" ]]' "2, nothing asked"
fresh "a target that is not one"
run -- release "Acme!"
check '[[ $status -eq 9 && "$out" == *"usage"* ]]' "refused"

# 2. A copy of the target, as a release asks about it
fresh "a backup copying"
gh_run fleet_backup.yml 30
gh_job 30 "every database, copied off the platform" in_progress "Somewhere to put them=completed" "Copy every database=in_progress"
run -- copy demonstration
check '[[ $status -eq 1 && "$out" == "fleet_backup.yml run 30: copying databases off the platform" ]]' "busy, whichever database it is on"
fresh "a backup not yet copying"
gh_run fleet_backup.yml 30
gh_job 30 "every database, copied off the platform" in_progress "Install the client tools of the live major version, and age=in_progress" "Copy every database=queued"
run -- copy production
check '[[ $status -eq 0 ]]' "not busy"
fresh "an export of acme"
gh_run fleet_export.yml 31
gh_job 31 "export acme" in_progress "Export=in_progress"
run -- copy acme
check '[[ $status -eq 1 && "$out" == "fleet_export.yml run 31: exporting acme" ]]' "busy"
run -- copy beta
check '[[ $status -eq 0 ]]' "an export of acme is no copy of beta"
: > "$FAKE_DIR/gh.log"
run -- copy production
check '[[ $status -eq 0 && "$(grep -c "fleet_export.yml" "$FAKE_DIR/gh.log")" == 0 ]]' "nor of the control plane, which no export copies: not even asked"
fresh "an export of acme still waiting for a release"
gh_run fleet_export.yml 31
gh_job 31 "export acme" in_progress "No release to it is replaying=in_progress" "Export=queued"
run -- copy acme
check '[[ $status -eq 0 ]]' "not busy: that export waits for this release"

# 3. Runs of other workflows, ordered by their ids
STEP="Rename, step by step"
fresh "a rename renaming"
gh_run fleet_rename.yml 600
gh_job 600 "move acme from acme to acme-foods" in_progress "$STEP=in_progress"
run -- runs "fleet_rename.yml=$STEP"
check '[[ $status -eq 1 && "$out" == "fleet_rename.yml run 600: in \"$STEP\"" ]]' "busy, though it began after this run"
fresh "an earlier rename still waiting for a train"
gh_run fleet_rename.yml 400
gh_job 400 "move acme from acme to acme-foods" in_progress "No release train is running=in_progress" "$STEP=queued"
run -- runs "fleet_rename.yml=$STEP"
check '[[ $status -eq 1 && "$out" == *"run 400: began before this run, and has \"$STEP\" still to do"* ]]' "busy: it is ahead in the queue"
fresh "a later rename still waiting"
gh_run fleet_rename.yml 600
gh_job 600 "move acme from acme to acme-foods" in_progress "No release train is running=in_progress" "$STEP=queued"
run -- runs "fleet_rename.yml=$STEP"
check '[[ $status -eq 0 ]]' "not busy: it began after this run, and waits for it"
fresh "an earlier rename queued, its job not made yet"
gh_run fleet_rename.yml 400 queued
run -- runs "fleet_rename.yml=$STEP"
check '[[ $status -eq 1 ]]' "busy: ahead in the queue"
fresh "an earlier rename past its step"
gh_run fleet_rename.yml 400
gh_job 400 "move acme from acme to acme-foods" in_progress "$STEP=completed" "A run that stopped settles its request=in_progress"
run -- runs "fleet_rename.yml=$STEP"
check '[[ $status -eq 0 ]]' "not busy"
fresh "two runs asking about each other"
gh_run fleet_rename.yml 400
gh_job 400 "move acme from acme to acme-foods" in_progress "$STEP=queued"
gh_run fleet_secrets.yml 401
gh_job 401 "patch_auth for all" in_progress "Change them, one client at a time=queued"
run GITHUB_RUN_ID=400 -- runs "fleet_secrets.yml=Change them, one client at a time"
first=$status
run GITHUB_RUN_ID=401 -- runs "fleet_rename.yml=$STEP"
check '[[ $first -eq 0 && $status -eq 1 ]]' "the earlier goes, the later waits: never both"
fresh "several workflows at once"
gh_run fleet_export.yml 450
gh_job 450 "export acme" in_progress "Export=in_progress"
gh_run fleet_backup.yml 451
gh_job 451 "every database, copied off the platform" in_progress "Copy every database=completed"
run -- runs "fleet_rename.yml=$STEP" "fleet_export.yml=Export" "fleet_backup.yml=Copy every database"
check '[[ $status -eq 1 && "$out" == "fleet_export.yml run 450: in \"Export\"" ]]' "each asked, the busy one named"
fresh "a spec that is not one"
run -- runs "fleet_rename.yml"
check '[[ $status -eq 9 ]]' "refused"

# 3b. A new database password and a copy, asking about each other
ROT="Change the database passwords, one client at a time"
fresh "a rotation, then an export"
gh_run fleet_secrets.yml 400
gh_job 400 "rotate_db_password for all" in_progress "No rename, and for a password no export or backup, is under way=in_progress" "$ROT=queued"
gh_run fleet_export.yml 401
gh_job 401 "export acme" in_progress "No database password is being changed=in_progress" "Export=queued"
run GITHUB_RUN_ID=400 -- runs "fleet_rename.yml=Rename, step by step" "fleet_export.yml=Export" "fleet_backup.yml=Copy every database"
first=$status
run GITHUB_RUN_ID=401 -- runs "fleet_secrets.yml=$ROT"
check '[[ $first -eq 0 && $status -eq 1 && "$out" == "fleet_secrets.yml run 400: began before this run, and has \"$ROT\" still to do" ]]' \
      "the rotation, earlier, goes; the export waits for its passwords: never both"
fresh "an export, then a rotation"
gh_run fleet_export.yml 400
gh_job 400 "export acme" in_progress "No database password is being changed=in_progress" "Export=queued"
gh_run fleet_secrets.yml 401
gh_job 401 "rotate_db_password for all" in_progress "No rename, and for a password no export or backup, is under way=in_progress" "$ROT=queued"
run GITHUB_RUN_ID=401 -- runs "fleet_rename.yml=Rename, step by step" "fleet_export.yml=Export" "fleet_backup.yml=Copy every database"
first=$status
run GITHUB_RUN_ID=400 -- runs "fleet_secrets.yml=$ROT"
check '[[ $first -eq 1 && $status -eq 0 ]]' "the export, earlier, goes; the rotation waits for it: never both"
fresh "a backup copying, then a rotation"
gh_run fleet_backup.yml 400
gh_job 400 "every database, copied off the platform" in_progress "Copy every database=in_progress"
gh_run fleet_secrets.yml 401
gh_job 401 "rotate_db_password for all" in_progress "$ROT=queued"
run GITHUB_RUN_ID=401 -- runs "fleet_backup.yml=Copy every database"
first=$status
run GITHUB_RUN_ID=400 -- runs "fleet_secrets.yml=$ROT"
check '[[ $first -eq 1 && $status -eq 0 ]]' "the rotation waits for the backup; the backup, asking before each client, goes"
fresh "a rotation under way, and a backup begun after it"
gh_run fleet_secrets.yml 400
gh_job 400 "rotate_db_password for all" in_progress "$ROT=in_progress"
gh_run fleet_backup.yml 401
gh_job 401 "every database, copied off the platform" in_progress "Copy every database=in_progress"
run GITHUB_RUN_ID=401 -- runs "fleet_secrets.yml=$ROT"
check '[[ $status -eq 1 && "$out" == "fleet_secrets.yml run 400: in \"$ROT\"" ]]' "the backup waits before each client while the passwords change"
fresh "an earlier change of other secrets"
gh_run fleet_secrets.yml 400
gh_job 400 "patch_auth for all" in_progress "$ROT=completed" "Change them, one client at a time=in_progress"
run -- runs "fleet_secrets.yml=$ROT"
check '[[ $status -eq 0 ]]' "not busy for a copy: its rotation step was skipped, and no password changes"
run -- runs "fleet_secrets.yml=Change them, one client at a time" "fleet_secrets.yml=$ROT"
check '[[ $status -eq 1 && "$out" == *"in \"Change them, one client at a time\""* ]]' "busy for a rename, which asks about both of its steps"

# 3c. A backup asks from inside its own copying (runs-in): only a rotation in
# its step is waited for, never one still to reach it, which waits for the
# backup at its own wait
SECRETS_WAIT="No rename, and for a password no export or backup, is under way"
fresh "a rotation at its wait, begun before a backup copying"
gh_run fleet_secrets.yml 400 in_progress workflow_dispatch "fleet secrets: rotate_db_password for all"
gh_job 400 "rotate_db_password for all" in_progress "$SECRETS_WAIT=in_progress" "$ROT=queued" "Change them, one client at a time=queued"
gh_run fleet_backup.yml 401
gh_job 401 "every database, copied off the platform" in_progress "Copy every database=in_progress"
run GITHUB_RUN_ID=401 -- runs-in "fleet_secrets.yml=$ROT"
backup=$status
run GITHUB_RUN_ID=400 -- runs "fleet_rename.yml=Rename, step by step" "fleet_export.yml=Export" "fleet_backup.yml=Copy every database"
check '[[ $backup -eq 0 && $status -eq 1 && "$out" == "fleet_backup.yml run 401: in \"Copy every database\"" ]]' \
      "the backup goes; the rotation, though it began first, waits for it: never both"
run GITHUB_RUN_ID=401 -- wait 60 runs-in "fleet_secrets.yml=$ROT"
check '[[ $status -eq 0 && "$(sleeps)" == 0 ]]' "the backup's own wait before a client passes at once"
fresh "a rotation in its step, and a backup copying"
gh_run fleet_secrets.yml 400 in_progress workflow_dispatch "fleet secrets: rotate_db_password for all"
gh_job 400 "rotate_db_password for all" in_progress "$SECRETS_WAIT=completed" "$ROT=in_progress"
gh_run fleet_backup.yml 401
gh_job 401 "every database, copied off the platform" in_progress "Copy every database=in_progress"
run GITHUB_RUN_ID=401 -- runs-in "fleet_secrets.yml=$ROT"
check '[[ $status -eq 1 && "$out" == "fleet_secrets.yml run 400: in \"$ROT\"" ]]' "the backup waits before its next client; the rotation waits for nothing"
fresh "a rotation through its wait and about to begin its step"
gh_run fleet_secrets.yml 400 in_progress workflow_dispatch "fleet secrets: rotate_db_password for all"
gh_job 400 "rotate_db_password for all" in_progress "$SECRETS_WAIT=completed" "$ROT=queued" "Change them, one client at a time=queued"
run GITHUB_RUN_ID=401 -- runs-in "fleet_secrets.yml=$ROT"
check '[[ $status -eq 1 && "$out" == "fleet_secrets.yml run 400: in \"$ROT\"" ]]' "counted as in it: nothing is left for it to wait for"
fresh "a rotation queued, its job not made yet"
gh_run fleet_secrets.yml 400 queued workflow_dispatch "fleet secrets: rotate_db_password for all"
run GITHUB_RUN_ID=401 -- runs-in "fleet_secrets.yml=$ROT"
check '[[ $status -eq 0 ]]' "not counted: it will wait for the backup"
fresh "runs-in that is not one"
run -- runs-in "fleet_secrets.yml"
check '[[ $status -eq 9 ]]' "refused"

# 3d. Only a run that changes passwords is waited for as one: its title says
# so, long before GitHub can say it skips the step
fresh "a change of other secrets begun before, still at its own wait"
gh_run fleet_secrets.yml 400 in_progress workflow_dispatch "fleet secrets: patch_auth for all"
gh_job 400 "patch_auth for all" in_progress "$SECRETS_WAIT=in_progress" "$ROT=queued" "Change them, one client at a time=queued"
run -- runs "fleet_secrets.yml=$ROT"
check '[[ $status -eq 0 && "$(grep -c "runs/400/jobs" "$FAKE_DIR/gh.log")" == 0 ]]' "not busy for a copy: not even asked about"
run -- runs "fleet_secrets.yml=Change them, one client at a time" "fleet_secrets.yml=$ROT"
check '[[ $status -eq 1 && "$out" == "fleet_secrets.yml run 400: began before this run, and has \"Change them, one client at a time\" still to do" ]]' \
      "still busy for a rename, which it would meet in its other step"
fresh "a change of function secrets queued behind another"
gh_run fleet_secrets.yml 399 in_progress workflow_dispatch "fleet secrets: patch_auth for acme"
gh_job 399 "patch_auth for acme" in_progress "$ROT=completed" "Change them, one client at a time=in_progress"
gh_run fleet_secrets.yml 400 queued workflow_dispatch "fleet secrets: set_function_secrets for all"
run -- wait 60 runs "fleet_secrets.yml=$ROT"
check '[[ $status -eq 0 && "$(sleeps)" == 0 ]]' "neither waited for by an export: no password changes"
fresh "a rotation queued, titled so"
gh_run fleet_secrets.yml 400 queued workflow_dispatch "fleet secrets: rotate_db_password for all"
run -- runs "fleet_secrets.yml=$ROT"
check '[[ $status -eq 1 && "$out" == *"run 400: began before this run"* ]]' "busy: ahead in the queue"
fresh "a run from before titles named the action"
gh_run fleet_secrets.yml 400 queued workflow_dispatch "fleet secrets"
run -- runs "fleet_secrets.yml=$ROT"
check '[[ $status -eq 1 ]]' "busy: not knowing what it changes is not a clear road"

# 4. The wait
fresh "nothing to wait for"
run -- wait 30 release acme
check '[[ $status -eq 0 && "$(sleeps)" == 0 ]]' "0 at once"
fresh "a release that finishes"
gh_run deploy.yml 41
gh_job 41 "release to acme / release to the acme" in_progress "$WAIT=completed" "$REPLAY=in_progress"
# The third question finds it through its replay.
mkdir -p "$FAKE_DIR/gh"
cat > "$work/bin/gh2" <<FAKE
#!/usr/bin/env bash
n=\$(( \$(cat "\$FAKE_DIR/gh2.calls" 2> /dev/null || echo 0) + 1 ))
echo "\$n" > "\$FAKE_DIR/gh2.calls"
if [[ "\$n" -ge 5 ]]; then
  jq -c '.jobs[0].steps[1].status = "completed"' "\$FAKE_DIR/gh/runs_41_jobs.json" > "\$FAKE_DIR/gh/next" && mv "\$FAKE_DIR/gh/next" "\$FAKE_DIR/gh/runs_41_jobs.json"
fi
exec "$work/bin/gh" "\$@"
FAKE
chmod +x "$work/bin/gh2"
run GH="$work/bin/gh2" -- wait 30 release acme
check '[[ $status -eq 0 && "$(sleeps)" == 2 && "$out" == *"deploy.yml run 41"*"asking again in 60 s"* ]]' "asked again a minute later, twice, then went on"
fresh "a release that does not finish"
gh_run deploy.yml 41
gh_job 41 "release to acme / release to the acme" in_progress "$WAIT=completed" "$REPLAY=in_progress"
run -- wait 5 release acme
check '[[ $status -eq 1 && "$(sleeps)" == 5 && "$(printf "%s\n" "$out" | tail -n 1)" == "deploy.yml run 41: release to acme / release to the acme, past its wait for copies and not through its replay" ]]' \
      "1 after five minutes, saying what is still busy"
fresh "GitHub that cannot be asked, waited on"
run FAKE_GH_FAIL=yes -- wait 2 copy acme
check '[[ $status -eq 1 && "$(sleeps)" == 2 && "$out" == *"GitHub could not be asked"* ]]' "counted as busy, and given up on when it said it would"
fresh "no wait at all"
gh_run fleet_backup.yml 30
gh_job 30 "every database, copied off the platform" in_progress "Copy every database=in_progress"
run -- wait 0 copy acme
check '[[ $status -eq 1 && "$(sleeps)" == 0 ]]' "asked once"
fresh "a wait of no minutes given"
run -- wait soon copy acme
check '[[ $status -eq 9 ]]' "refused"

# 5. Every step asked about is a step of the workflow it names: a step
# renamed in one place and not the other is a wait that silently stops
# seeing it
ROOT="$HERE/../.."
names_of() { sed -n 's/^ *- name: //p' "$ROOT/.github/workflows/$1" 2> /dev/null; }
has_step() { names_of "$1" | grep -qxF -- "$2"; }
CURRENT="the steps asked about"
specs=$( { grep -ho '"[a-z0-9_.-]*\.yml=[^"]*"' "$ROOT"/.github/workflows/*.yml
           for f in "$ROOT"/supabase/ci/*.sh; do
             if [[ "$f" == *_rehearsal.sh ]]; then continue; fi
             grep -ho '"[a-z0-9_.-]*\.yml=[^"]*"' "$f"
           done; } | tr -d '"' | LC_ALL=C sort -u)
while IFS= read -r spec; do
  [[ -n "$spec" ]] || continue
  check 'has_step "${spec%%=*}" "${spec#*=}"' "${spec%%=*} has the step \"${spec#*=}\""
done <<< "$specs"
check '[[ "$(printf "%s\n" "$specs" | grep -c .)" -ge 5 ]]' "every pair found: rename, export, backup and both of fleet_secrets.yml's steps"
for asker in .github/workflows/fleet_export.yml supabase/ci/fleet_backup.sh .github/workflows/fleet_rename.yml; do
  check 'grep -qF "\"fleet_secrets.yml=$ROT\"" "$ROOT/$asker"' "${asker##*/} asks about a new database password by that step's name"
done
for pair in "release.yml RELEASE_WAIT_STEP" "release.yml RELEASE_REPLAY_STEP" "fleet_backup.yml BACKUP_STEP" "fleet_export.yml EXPORT_STEP" \
            "fleet_secrets.yml ROTATION_STEP"; do
  wf="${pair% *}"; var="${pair#* }"
  step_name=$(sed -n "s/^${var}=\"\(.*\)\"\$/\1/p" "$SCRIPT")
  check '[[ -n "$step_name" ]] && has_step "$wf" "$step_name"' "${var} (\"${step_name}\") is a step of ${wf}"
done
check '[[ "$(sed -n "s/^SECRETS_WORKFLOW=\"\(.*\)\"\$/\1/p" "$SCRIPT")" == fleet_secrets.yml ]]' "SECRETS_WORKFLOW is fleet_secrets.yml"
# A rotation is told by its run's title: the title the workflow gives it, and
# the actions it may name, are the ones fleet_busy.sh tells apart.
SECRETS_WF="$ROOT/.github/workflows/fleet_secrets.yml"
check 'grep -qxF "run-name: \"fleet secrets: \${{ inputs.action }} for \${{ inputs.code }}\"" "$SECRETS_WF"' \
      "fleet_secrets.yml titles each run with its action"
actions=$(awk '/^      action:/ { a = 1 } a && /^      code:/ { exit } a && /^          - / { sub(/^ *- /, ""); print }' "$SECRETS_WF" | tr '\n' ' ')
check '[[ "$actions" == "rotate_db_password set_function_secrets patch_auth " ]] && grep -qF "test(\"rotate_db_password\")" "$SCRIPT" && grep -qF "test(\"set_function_secrets|patch_auth\")" "$SCRIPT"' \
      "and its actions are the three the title rule tells apart"
check 'grep -qF "fleet_busy.sh\" wait \"\$ROTATION_WAIT\" runs-in \"\$ROTATION_SPEC\"" "$ROOT/supabase/ci/fleet_backup.sh"' \
      "fleet_backup.sh, asking from inside its copying, asks only whether a rotation is in its step"
check 'grep -qF "name: release to the \${{ inputs.target }}" "$ROOT/.github/workflows/release.yml" && grep -qF "name: export \${{ inputs.code }}" "$ROOT/.github/workflows/fleet_export.yml"' \
      "and the jobs it looks for by name are named so"

echo "$CASES checks over the fleet's waits for each other, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
