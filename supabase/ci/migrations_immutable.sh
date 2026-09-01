#!/usr/bin/env bash
#
# A migration is written once.
#
# The schema build stands everything up from NOTHING on every push, which means
# a migration edited after it was pushed is simply part of the file that gets
# replayed — the edited version is the only version an empty database ever
# sees, and the build is green. Every environment that has already applied that
# file sees nothing at all: Supabase's own preview branch says so in its comment
# on every pull request, "only new migration files are pushed", and so does the
# live project.
#
# So this is the one class of mistake the build structurally cannot catch, and
# it caught nothing until a preview branch failed on a change-set kind that the
# build had been happily replaying for four commits.
#
# The rule: on a branch, a migration file touched by more than one commit has
# been edited after it was pushed. Fix it forward — a NEW migration that
# re-applies the definition — rather than by editing the old one again.
#
# Usage: supabase/ci/migrations_immutable.sh [base-ref]
set -euo pipefail

BASE="${1:-origin/main}"
REGISTER="$(dirname "$0")/migrations_edited.txt"
MIGRATIONS="$(dirname "$0")/../migrations"

# A file already repaired by a later migration is exempt — and the register that
# says so has to name a repair that exists, or an exemption is just a way of
# turning the check off.
exempt() {
  local base
  base="$(basename "$1")"
  [ -f "$REGISTER" ] || return 1
  while read -r edited repair _; do
    case "$edited" in ""|"#"*) continue ;; esac
    [ "$edited" = "$base" ] || continue
    if [ ! -f "$MIGRATIONS/$repair" ]; then
      echo "x $REGISTER exempts $edited by naming $repair, which does not exist." >&2
      return 2
    fi
    return 0
  done < "$REGISTER"
  return 1
}

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "migrations: $BASE is not fetched here, so there is nothing to compare against" >&2
  exit 0
fi

MERGE_BASE="$(git merge-base "$BASE" HEAD)"
FAILED=0

# Every migration this branch adds or changes.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue

  # A file that already exists on the base branch is deployed. Any change to it
  # is an edit to something that has run somewhere.
  exempt "$f" || e=$?; e=${e:-0}
  if [ "$e" -eq 2 ]; then FAILED=1; unset e; continue; fi
  if [ "$e" -eq 0 ]; then unset e; continue; fi
  unset e

  if git cat-file -e "$MERGE_BASE:$f" 2>/dev/null; then
    echo "✗ $f exists on $BASE and this branch changes it." >&2
    echo "  It has been applied wherever $BASE is deployed, so the change lands nowhere." >&2
    FAILED=1
    continue
  fi

  # A file this branch introduces, then touches again in a later commit, was
  # edited after it was pushed — unless every one of those commits is still
  # unpushed, which this cannot know and does not need to: fixing it forward is
  # correct either way.
  n="$(git rev-list --count "$MERGE_BASE..HEAD" -- "$f")"
  if [ "$n" -gt 1 ]; then
    echo "✗ $f is touched by $n commits on this branch." >&2
    git log --oneline "$MERGE_BASE..HEAD" -- "$f" | sed 's/^/    /' >&2
    echo "  A migration is written once. Re-apply the definition in a NEW migration." >&2
    FAILED=1
  fi
done < <(git diff --name-only "$MERGE_BASE..HEAD" -- 'supabase/migrations/*.sql')

if [ "$FAILED" -ne 0 ]; then
  echo >&2
  echo "An edit to an applied migration is invisible to a build that starts from" >&2
  echo "an empty database, and reaches no environment that has already run it." >&2
  exit 1
fi

echo "migrations: every migration on this branch is written once, or repaired by one that is"
