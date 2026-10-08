#!/usr/bin/env bash
#
# Which Edge Functions a release deploys, and why: the decision release.yml's
# "Deploy the Edge Functions" step makes, in a file of its own so that it is
# rehearsed (supabase/ci/functions_to_deploy_rehearsal.sh) rather than learned
# on a train.
#
# Every function was deployed on every release until 8 October, each at least
# one Management API call, and one token's sixty calls a minute serve the whole
# fleet: a train of four clients asked for thirty-two deploys against that
# allowance, most of them of code that had not changed. A function is deployed
# when
#
#   it is not on the project yet;
#   anything it is built from changed between the commit the target last
#   released and this one: its own directory, and every file those import by
#   a relative path, followed through worker/src/core and src/lib as the
#   bundler follows them; or
#   anything every function shares changed: supabase/functions/_shared,
#   import_map.json, deno.json, supabase/config.toml.
#
# And every function is deployed whenever that comparison cannot be trusted:
# no earlier release of the target is known to have succeeded, its commit is
# not in this checkout or not an ancestor of this one, an import cannot be
# followed, or the project's functions could not be listed. Deploying a
# function that did not change costs one call; skipping one that did leaves
# a stale function serving a client, so every doubt deploys.
#
# Usage, from the top of the repository, with the commit being released
# checked out:
#
#   functions_to_deploy.sh --last <sha> (--on-project <file> | --not-listed)
#                          [--head <sha>] [--target <name>]
#
#   --last        the commit the target last released successfully; empty
#                 when none is known (a first release, a failed last one)
#   --on-project  a file naming the functions already on the project, one a
#                 line (the slugs of GET /v1/projects/<ref>/functions)
#   --not-listed  the project's functions could not be listed
#   --head        the commit being released (default GITHUB_SHA, else HEAD)
#   --target      what the reasons call the target (default "the target")
#
# Prints one line a decision, tab-separated, in this order:
#
#   basis    every     <why every function is deployed>    or
#   basis    compared  <the last release's commit>
#   deploy   <name>    <why>
#   skip     <name>    nothing it is built from changed
#
# one deploy or skip line for each directory under supabase/functions with an
# index.ts, in name order. Exit 2, saying why on stderr, when it is used wrongly
# or is not run from the top of a git checkout; the caller then deploys every
# function.
#
# bash 3.2 and later (the rehearsal runs on a Mac too): no mapfile, no
# associative arrays.
set -euo pipefail

usage() {
  echo "x usage: functions_to_deploy.sh --last <sha> (--on-project <file> | --not-listed) [--head <sha>] [--target <name>]" >&2
  exit 2
}

last=""; last_given=no
on_project=""; listed=""
head_sha="${GITHUB_SHA:-}"
target="the target"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --last) [[ $# -ge 2 ]] || usage; last="$2"; last_given=yes; shift 2 ;;
    --on-project) [[ $# -ge 2 ]] || usage; on_project="$2"; listed=yes; shift 2 ;;
    --not-listed) listed=no; shift ;;
    --head) [[ $# -ge 2 ]] || usage; head_sha="$2"; shift 2 ;;
    --target) [[ $# -ge 2 && -n "$2" ]] || usage; target="$2"; shift 2 ;;
    *) echo "x '$1' is not something functions_to_deploy.sh is told." >&2; usage ;;
  esac
done
[[ "$last_given" == yes ]] || { echo "x --last is not given (give it empty when no earlier release is known)." >&2; usage; }
[[ -n "$listed" ]] || { echo "x neither --on-project nor --not-listed is given." >&2; usage; }
if [[ "$listed" == yes && ! -f "$on_project" ]]; then
  echo "x the list of functions on the project (${on_project}) is not a file." >&2
  exit 2
fi
[[ -d supabase/functions ]] || { echo "x there is no supabase/functions here ($(pwd)); run this from the top of the repository." >&2; exit 2; }
git rev-parse --git-dir > /dev/null 2>&1 || { echo "x $(pwd) is not a git checkout." >&2; exit 2; }
[[ -n "$head_sha" ]] || head_sha=HEAD
git cat-file -e "${head_sha}^{commit}" 2> /dev/null || { echo "x the commit being released (${head_sha}) is not in this checkout." >&2; exit 2; }

existing=""
if [[ "$listed" == yes ]]; then
  existing=$(cat "$on_project")
fi

# Why every function goes, if one reason covers them all.
all=""
changed=""
if [[ -z "$last" ]]; then
  all="no earlier release of ${target} is known to have succeeded"
elif ! [[ "$last" =~ ^[0-9a-f]{7,40}$ ]]; then
  all="the last release's commit ('${last}') is not a commit id"
elif ! git cat-file -e "${last}^{commit}" 2> /dev/null; then
  all="the last release's commit ${last:0:12} is not in this checkout"
elif ! git merge-base --is-ancestor "$last" "$head_sha"; then
  all="the last release's commit ${last:0:12} is not an ancestor of ${head_sha:0:12}"
else
  changed=$(git diff --no-renames --name-only "$last" "$head_sha")
  shared=$(grep -m 1 -E '^(supabase/functions/_shared/|supabase/functions/import_map\.json$|supabase/functions/deno\.json$|supabase/config\.toml$)' <<< "$changed" || true)
  [[ -z "$shared" ]] || all="${shared} changed, and every function shares it"
fi
if [[ "$listed" != yes && -z "$all" ]]; then
  all="the functions on the project could not be listed"
fi

# norm <path>: the path with ./ and dir/../ taken out.
norm() {
  local rest="$1/" part out=""
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"; rest="${rest#*/}"
    case "$part" in
      ""|.) ;;
      ..) if [[ "$out" == */* ]]; then out="${out%/*}"; else out=""; fi ;;
      *) out="${out:+${out}/}${part}" ;;
    esac
  done
  printf '%s\n' "$out"
}
# imports <file>: the repository files it imports by a relative specifier
# (from, import, import()), one a line; ?<path> for one that names no file.
imports() {
  local dir spec target_file
  dir=$(dirname "$1")
  { grep -oE "(from|import)[[:space:]]*[(]?[[:space:]]*[\"'][.]{1,2}/[^\"']+[\"']" "$1" || true; } \
    | sed -E "s/^[^\"']*[\"']//; s/[\"']$//" \
    | while IFS= read -r spec; do
        target_file=$(norm "${dir}/${spec}")
        if [[ -f "$target_file" ]]; then echo "$target_file"; else echo "?${target_file}"; fi
      done
}
# sources <function>: every file it is built from, one a line: its own
# directory and, transitively, what those files import.
sources() {
  local queue seen="" f more
  queue=$(find "supabase/functions/$1" -type f | sort)
  while [[ -n "$queue" ]]; do
    f="${queue%%$'\n'*}"
    if [[ "$queue" == *$'\n'* ]]; then queue="${queue#*$'\n'}"; else queue=""; fi
    if grep -qxF -- "$f" <<< "$seen"; then continue; fi
    seen+="${f}"$'\n'
    case "$f" in
      \?*) ;;
      *.ts|*.tsx|*.mts|*.js|*.jsx|*.mjs)
        more=$(imports "$f")
        if [[ -n "$more" ]]; then queue+="${queue:+$'\n'}${more}"; fi ;;
    esac
  done
  printf '%s' "$seen"
}

tab=$'\t'
if [[ -n "$all" ]]; then
  echo "basis${tab}every${tab}${all}"
else
  echo "basis${tab}compared${tab}${last}"
fi

list=$(mktemp "${TMPDIR:-/tmp}/sources.XXXXXX")
trap 'rm -f "$list"' EXIT
for dir in supabase/functions/*/; do
  name=$(basename "$dir")
  [[ -f "${dir}index.ts" ]] || continue
  why="$all"
  if [[ -z "$why" ]] && ! grep -qxF -- "$name" <<< "$existing"; then
    why="it is not on the project yet"
  fi
  if [[ -z "$why" ]]; then
    files=$(sources "$name")
    unfollowed=$(grep -m 1 '^?' <<< "$files" || true)
    grep -v '^$' <<< "$files" > "$list" || true
    hit=$(grep -m 1 -xF -f "$list" <<< "$changed" || true)
    # A file the function no longer has (deleted since the last release) is
    # in no list of what it is built from, and still changed it.
    [[ -n "$hit" ]] || hit=$(grep -m 1 "^supabase/functions/${name}/" <<< "$changed" || true)
    if [[ -n "$unfollowed" ]]; then
      why="an import could not be followed (${unfollowed#?})"
    elif [[ -n "$hit" ]]; then
      why="${hit} changed"
    fi
  fi
  if [[ -z "$why" ]]; then
    echo "skip${tab}${name}${tab}nothing it is built from changed"
  else
    echo "deploy${tab}${name}${tab}${why}"
  fi
done
