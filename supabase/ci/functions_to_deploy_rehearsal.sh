#!/usr/bin/env bash
#
# supabase/ci/functions_to_deploy.sh, rehearsed against a repository made up
# for the purpose.
#
# The script decides which Edge Functions a release deploys (release.yml,
# "Deploy the Edge Functions"). Wrong one way, a function that changed is not
# deployed and a client is served stale code that nothing reports; wrong the
# other way, a train spends the Management API's sixty calls a minute on code
# that did not change. Either is learned on a train. So it runs here first,
# against a small git repository built in a temporary directory: functions
# that import their own files, files in worker/src/core and src/lib, with
# single and double quotes, a dynamic import, a side-effect import, an export
# from, a cycle, and an import of a file that is not there; and commits that
# change each of those, the files every function shares, nothing at all, and
# a commit that is not an ancestor. Seconds, no API, and nothing outside the
# temporary directory is read or written.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/functions_to_deploy.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
mkdir -p "$repo"

# The throwaway repository is its own: git never looks above it for another,
# and no user or system setting (a signing key, a hook path) reaches it.
export GIT_CEILING_DIRECTORIES="$work"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=rehearsal GIT_AUTHOR_EMAIL=rehearsal@example.com
export GIT_COMMITTER_NAME=rehearsal GIT_COMMITTER_EMAIL=rehearsal@example.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2> /dev/null || true
# A runner sets GITHUB_SHA to this repository's commit, which the made-up one
# does not have; each case says which commit it releases.
unset GITHUB_SHA
g() { git -C "$repo" "$@"; }

put() {
  # put <path> <content>: a file in the repository, made with its directory.
  mkdir -p "$repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$repo/$1"
}

g init -q -b main 2> /dev/null || { g init -q && g checkout -q -b main; }
put supabase/config.toml '[functions.alpha]
verify_jwt = false'
put supabase/functions/import_map.json '{"imports":{}}'
put supabase/functions/deno.json '{}'
put supabase/functions/_shared/cors.ts 'export const cors = {};'
put supabase/functions/alpha/index.ts 'import { help } from "./helper.ts";
export default help;'
put supabase/functions/alpha/helper.ts 'import { thing } from "../../../worker/src/core/thing.ts";
export const help = thing;'
put supabase/functions/beta/index.ts "import { money } from '../../../src/lib/money.ts';
export * from \"../../../src/lib/reexported.ts\";
export default money;"
put supabase/functions/beta/notes.txt 'notes beside the function, imported by nothing'
put supabase/functions/gamma/index.ts 'import "../../../worker/src/core/side.ts";
const later = await import( "../../../src/lib/late.ts" );
export default later;'
put supabase/functions/gamma/README.md 'gamma'
put supabase/functions/helpers_only/util.ts 'export const util = 1;'
put worker/src/core/thing.ts 'import { x } from "./x.ts";
export const thing = x;'
put worker/src/core/x.ts 'import { thing } from "./thing.ts";
export const x = 1;'
put worker/src/core/side.ts 'globalThis.side = true;'
put src/lib/money.ts "import { round } from './round.ts';
export const money = round;"
put src/lib/round.ts 'export const round = Math.round;'
put src/lib/reexported.ts 'export const reexported = 1;'
put src/lib/late.ts 'export const late = 1;'
put src/lib/unrelated.ts 'export const unrelated = 1;'
put README.md 'a repository made up for the rehearsal'
g add -A
g commit -q -m base
BASE=$(g rev-parse HEAD)

ALL_THREE="$work/on-project-all"
printf 'alpha\nbeta\ngamma\nsomething_else\n' > "$ALL_THREE"

change() {
  # change <message> <path> [content]: from the base, one file changed (or
  # removed, when no content is given and the file exists), committed; HEAD
  # is the new commit, and the working tree is it.
  g checkout -q --detach "$BASE"
  if [[ $# -ge 3 ]]; then
    put "$2" "$3"
  else
    rm -f "$repo/$2"
  fi
  g add -A
  g commit -q -m "$1"
  HEAD_SHA=$(g rev-parse HEAD)
}

CASES=0
FAILED=0
run() {
  # run <name> [arguments ...]: the script from the top of the repository;
  # its output in $out, its exit in $status.
  CURRENT="$1"; shift
  out=$(cd "$repo" && bash "$SCRIPT" "$@" 2>&1)
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
  fi
}
# basis: the first line's second and third fields; verdict/why <name>: a function's.
basis() { printf '%s\n' "$out" | awk -F '\t' 'NR == 1 && $1 == "basis" { print $2 "|" $3 }'; }
verdict() { printf '%s\n' "$out" | awk -F '\t' -v n="$1" '$2 == n && $1 != "basis" { print $1 }'; }
why() { printf '%s\n' "$out" | awk -F '\t' -v n="$1" '$2 == n && $1 != "basis" { print $3 }'; }
deployed() { printf '%s\n' "$out" | awk -F '\t' '$1 == "deploy" { printf "%s ", $2 }'; }
skipped() { printf '%s\n' "$out" | awk -F '\t' '$1 == "skip" { printf "%s ", $2 }'; }

# 1. Used wrongly: refused, and the caller deploys everything
run "no arguments"
check '[[ $status -eq 2 && "$out" == *"--last is not given"* ]]' "refused"
run "no list of what the project has" --last "$BASE"
check '[[ $status -eq 2 && "$out" == *"neither --on-project nor --not-listed"* ]]' "refused"
run "a list that is not a file" --last "$BASE" --on-project "$work/nothing-here"
check '[[ $status -eq 2 && "$out" == *"is not a file"* ]]' "refused"
run "something it is not told" --last "$BASE" --not-listed --force
check '[[ $status -eq 2 && "$out" == *"--force"* ]]' "refused"
CURRENT="not the top of the repository"
out=$(cd "$repo/src" && bash "$SCRIPT" --last "$BASE" --not-listed 2>&1); status=$?
check '[[ $status -eq 2 && "$out" == *"no supabase/functions here"* ]]' "refused"
mkdir -p "$work/not-git/supabase/functions"
CURRENT="not a git checkout"
out=$(cd "$work/not-git" && bash "$SCRIPT" --last "$BASE" --not-listed 2>&1); status=$?
check '[[ $status -eq 2 && "$out" == *"is not a git checkout"* ]]' "refused"
run "a commit being released that is not here" --last "$BASE" --not-listed --head 0123456789abcdef0123456789abcdef01234567
check '[[ $status -eq 2 && "$out" == *"is not in this checkout"* ]]' "refused"

# 2. Every function, for one reason
change "the readme" README.md 'a repository made up for the rehearsal, read again'
run "no earlier release known" --last "" --on-project "$ALL_THREE" --head "$HEAD_SHA" --target acme
check '[[ $status -eq 0 && "$(basis)" == "every|no earlier release of acme is known to have succeeded" ]]' "every function, and says why once"
check '[[ "$(deployed)" == "alpha beta gamma " && -z "$(skipped)" ]]' "each directory with an index.ts, in name order"
check '[[ "$out" != *"helpers_only"* && "$out" != *"_shared"* ]]' "a directory without an index.ts is no function"
check '[[ "$(why beta)" == "no earlier release of acme is known to have succeeded" ]]' "each says the same reason"
run "a last release that is not a commit id" --last main --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(basis)" == "every|the last release'"'"'s commit ('"'"'main'"'"') is not a commit id" && "$(deployed)" == "alpha beta gamma " ]]' "every function"
run "a last release this checkout does not have" --last 0123456789abcdef0123456789abcdef01234567 --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(basis)" == *"0123456789ab is not in this checkout" && "$(deployed)" == "alpha beta gamma " ]]' "every function"
change "elsewhere" src/lib/unrelated.ts 'export const unrelated = 2;'
SIDE=$HEAD_SHA
change "the readme" README.md 'a repository made up for the rehearsal, read again'
run "a last release that is not an ancestor" --last "$SIDE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(basis)" == "every|the last release'"'"'s commit ${SIDE:0:12} is not an ancestor of ${HEAD_SHA:0:12}" && "$(deployed)" == "alpha beta gamma " ]]' "every function"
run "the project's functions could not be listed" --last "$BASE" --not-listed --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(basis)" == "every|the functions on the project could not be listed" && "$(deployed)" == "alpha beta gamma " ]]' "every function: nothing says what is there"
run "not listed, and no earlier release either" --last "" --not-listed --head "$HEAD_SHA"
check '[[ "$(basis)" == "every|no earlier release of the target is known to have succeeded" ]]' "the first reason is the one given"
for shared in supabase/functions/_shared/cors.ts supabase/functions/import_map.json supabase/functions/deno.json supabase/config.toml; do
  change "a shared file" "$shared" 'changed for every function'
  run "${shared} changed" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
  check '[[ $status -eq 0 && "$(basis)" == "every|${shared} changed, and every function shares it" && "$(deployed)" == "alpha beta gamma " ]]' "every function shares it"
done

# 3. Only what changed
change "the readme" README.md 'a repository made up for the rehearsal, read again'
run "nothing a function is built from changed" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(basis)" == "compared|${BASE}" && -z "$(deployed)" && "$(skipped)" == "alpha beta gamma " ]]' "every function skipped, compared with the last release"
check '[[ "$(why alpha)" == "nothing it is built from changed" ]]' "and says why"
run "the commit being released, from GITHUB_SHA" --last "$BASE" --on-project "$ALL_THREE"
check '[[ $status -eq 0 && "$(skipped)" == "alpha beta gamma " ]]' "HEAD when GITHUB_SHA is not set"
CURRENT="the commit being released, from GITHUB_SHA"
out=$(cd "$repo" && GITHUB_SHA="$SIDE" bash "$SCRIPT" --last "$BASE" --on-project "$ALL_THREE" 2>&1); status=$?
check '[[ $status -eq 0 && "$(skipped)" == "alpha beta gamma " ]]' "GITHUB_SHA when it is set (there, only src/lib/unrelated.ts changed)"
change "a file worker/src/core imports" worker/src/core/x.ts 'import { thing } from "./thing.ts";
export const x = 2;'
run "a file reached through two imports and a cycle" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(deployed)" == "alpha " && "$(why alpha)" == "worker/src/core/x.ts changed" && "$(skipped)" == "beta gamma " ]]' \
      "alpha, through helper.ts and thing.ts, and the cycle back to thing.ts ends"
change "a file src/lib imports, in single quotes" src/lib/round.ts 'export const round = Math.floor;'
run "src/lib, imported in single quotes" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(deployed)" == "beta " && "$(why beta)" == "src/lib/round.ts changed" ]]' "beta, through money.ts"
change "an export from" src/lib/reexported.ts 'export const reexported = 2;'
run "a file re-exported" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(deployed)" == "beta " && "$(why beta)" == "src/lib/reexported.ts changed" ]]' "export ... from is followed"
change "a dynamic import" src/lib/late.ts 'export const late = 2;'
run "a file imported dynamically" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(deployed)" == "gamma " && "$(why gamma)" == "src/lib/late.ts changed" ]]' "import( ... ) is followed"
change "a side-effect import" worker/src/core/side.ts 'globalThis.side = false;'
run "a file imported for its effect" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(deployed)" == "gamma " && "$(why gamma)" == "worker/src/core/side.ts changed" ]]' "import \"...\" is followed"
change "a file nothing imports" src/lib/unrelated.ts 'export const unrelated = 3;'
run "a file no function is built from" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && -z "$(deployed)" ]]' "nothing deployed"
change "a function's own file" supabase/functions/gamma/README.md 'gamma, again'
run "a file in the function's own directory" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(deployed)" == "gamma " && "$(why gamma)" == "supabase/functions/gamma/README.md changed" ]]' "whatever kind of file it is"
change "a file the function no longer has" supabase/functions/beta/notes.txt
run "a file removed from the function's directory" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(deployed)" == "beta " && "$(why beta)" == "supabase/functions/beta/notes.txt changed" ]]' "deployed, though no list of its files has it any more"
change "the readme" README.md 'a repository made up for the rehearsal, read again'
printf 'alpha\ngamma\n' > "$work/on-project-two"
run "a function the project does not have" --last "$BASE" --on-project "$work/on-project-two" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(deployed)" == "beta " && "$(why beta)" == "it is not on the project yet" && "$(skipped)" == "alpha gamma " ]]' "deployed, and only it"
: > "$work/on-project-none"
run "a project with no function yet" --last "$BASE" --on-project "$work/on-project-none" --head "$HEAD_SHA"
check '[[ $status -eq 0 && "$(basis)" == "compared|${BASE}" && "$(deployed)" == "alpha beta gamma " && "$(why gamma)" == "it is not on the project yet" ]]' "every function, each new to it"
change "an import of a file that is not there" supabase/functions/alpha/helper.ts 'import { thing } from "../../../worker/src/core/thing.ts";
import { gone } from "./gone.ts";
export const help = thing;'
G=$HEAD_SHA
run "an import that cannot be followed" --last "$G" --on-project "$ALL_THREE" --head "$G"
check '[[ $status -eq 0 && "$(deployed)" == "alpha " && "$(why alpha)" == "an import could not be followed (supabase/functions/alpha/gone.ts)" && "$(skipped)" == "beta gamma " ]]' \
      "deployed though nothing changed: what it is built from is not known"

# 4. It only reads
CURRENT="the repository afterwards"
check '[[ -z "$(g status --porcelain)" ]]' "nothing written into the checkout"
CURRENT="the output"
change "a file worker/src/core imports" worker/src/core/x.ts 'export const x = 3;'
run "the output" --last "$BASE" --on-project "$ALL_THREE" --head "$HEAD_SHA"
check '[[ "$(printf "%s\n" "$out" | awk -F "\t" "NF != 3" | wc -l | tr -d " ")" == 0 && "$(printf "%s\n" "$out" | wc -l | tr -d " ")" == 4 ]]' \
      "one line of three tab-separated fields for the basis and for each function"

echo "$CASES checks over which functions a release deploys, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
