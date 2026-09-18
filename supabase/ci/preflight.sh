#!/usr/bin/env bash
#
# The conventions the build enforces and nothing catches sooner.
#
# The schema build stands the product up from an empty cluster and takes thirty
# to fifty minutes, and it is the only thing that can verify a migration,
# because there is no local PostgreSQL. Across five branches on 17 September it
# ran fifteen times and failed nine, and not one of those nine was the change
# being wrong. Every one was a convention — a suite a migration may not run, a
# refusal raised where the register cannot see it, a door that does not call
# the gate it declares, a help topic that does not exist, an immutability check
# run against an uncommitted tree. Each cost most of an hour to learn something
# a text search knows in two seconds.
#
# So this is that text search. It reads git and the migration text and nothing
# else: no database, no psql, no connection. If a rule here ever needs one it
# is the wrong rule and belongs in erp.ci_check_catalogue() with the rest.
#
# Six rules refuse and two advise, and the division is deliberate. A check that
# fires falsely is ignored within a day and is then worse than nothing, so a
# rule refuses only where the refusal is arithmetic — the same substring the
# database itself looks for, the same register, the same name. Where the answer
# needs a built database to know, such as what a total becomes once a new
# posting rule lands, it warns and exits zero: a number this cannot know is a
# number it must not claim.
#
#   A  a migration must not run a suite that needs to be alone in the world
#   B  a registered refusal must be raised where the register can see it
#   C  a public write door must call the gate it declares
#   D  help actions need a help topic
#   E  the immutability check must be run against what is committed
#   F  a new public door needs its allowance and a home
#   G  advisory: a total somebody wrote down has moved
#   H  advisory: a suite's count guard should print what its fixture caught
#
# Proved by supabase/ci/preflight_falsification.sh, which puts a fixture
# migration in front of each rule and refuses to believe a rule that stays
# quiet.
#
# Usage:
#   supabase/ci/preflight.sh                         every migration this branch adds
#   supabase/ci/preflight.sh path/to/migration.sql   a named migration: A–D and F–H
#
# Environment:
#   PREFLIGHT_BASE   the branch to compare against (default: origin/main)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE="${PREFLIGHT_BASE:-origin/main}"

FAILED=0

# ═════════════════════════════════════════════════════════════════════════════
# E — the immutability check must be run against what is committed
# ═════════════════════════════════════════════════════════════════════════════
#
# supabase/ci/migrations_immutable.sh diffs merge-base..HEAD, so it reads
# commits and not the working tree. Run it with the change uncommitted and it
# passes meaninglessly: a migration deleted in the working tree is still in
# HEAD, so the check sees nothing, says so, and the build then refuses the
# push. That happened on 17 September and cost a build.
#
# So preflight runs it, and refuses to report success while anything under
# supabase/migrations is uncommitted. That directory is the check's entire
# scope, and uncommitted work in it is exactly what makes the verdict describe
# a tree nobody is going to push. Dirt anywhere else is reported and not
# refused: it changes nothing about what merge-base..HEAD says, and a rule that
# refuses for a reason that does not matter is a rule people learn to skip.
#
# Branch mode only. A named migration is not a branch, and "is this branch's
# history sound" has no answer there.

run_branch_rule_e() {
  local dirty_migrations dirty_elsewhere
  dirty_migrations="$(git -C "$ROOT" status --porcelain -- 'supabase/migrations' || true)"
  dirty_elsewhere="$(git -C "$ROOT" status --porcelain -- . ':(exclude)supabase/migrations' || true)"

  if [ -n "$dirty_migrations" ]; then
    {
      echo "✗ supabase/migrations has uncommitted changes, so nothing below is about"
      echo "  what you would push."
      echo "$dirty_migrations" | sed 's/^/      /'
      echo "  A migration is immutable once pushed, and the check that says so reads"
      echo "  commits, not the working tree: it compares $BASE..HEAD. Run it with the"
      echo "  change uncommitted and it answers a question about a tree that does not"
      echo "  exist yet — a deleted migration is still in HEAD, so it passes here and"
      echo "  the build refuses the push."
      echo "  Commit first, then run this again."
      echo "  (preflight rule E)"
      echo ""
    } >&2
    FAILED=1
  fi

  if ! (cd "$ROOT" && "$HERE/migrations_immutable.sh" "$BASE"); then
    FAILED=1
  fi

  if [ -n "$dirty_elsewhere" ]; then
    echo "preflight: the working tree is dirty outside supabase/migrations. It does not"
    echo "           change the verdict above, which reads commits, but it is not what"
    echo "           you would push either:"
    echo "$dirty_elsewhere" | sed 's/^/             /'
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# A–D, F–H — read the migration text
# ═════════════════════════════════════════════════════════════════════════════
#
# Harvesting a function body out of dollar-quoted SQL, and telling a call the
# migration makes from a call inside a body it merely defines, is beyond grep,
# so this half is Python — as supabase/ci/screen_strings.sh's harvest is, and
# app_gates.sh's. It reads the repository and nothing else.

if [ "$#" -gt 0 ]; then
  python3 "$HERE/preflight_rules.py" "$ROOT" named "$@" || FAILED=1
  if [ "$FAILED" -ne 0 ]; then
    exit 1
  fi
  echo "preflight: A–D and F–H pass. E is a branch-level rule and was not run;"
  echo "           run supabase/ci/preflight.sh with no arguments before pushing."
  exit 0
fi

# Said the way supabase/ci/migrations_immutable.sh says it, and for the same
# reason: without the base branch there is no "what this branch adds", and a
# check that cannot ask its question must say so rather than answer it.
if ! git -C "$ROOT" rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "preflight: $BASE is not fetched here, so there is nothing to compare against" >&2
  echo "  Fetch it (git fetch origin main), or name a migration to check." >&2
  exit 0
fi

run_branch_rule_e

MERGE_BASE="$(git -C "$ROOT" merge-base "$BASE" HEAD)"
TARGETS=""
for f in $(git -C "$ROOT" diff --name-only "$MERGE_BASE..HEAD" -- 'supabase/migrations/*.sql'); do
  if [ -f "$ROOT/$f" ]; then
    TARGETS="$TARGETS $ROOT/$f"
  fi
done

if [ -z "$TARGETS" ]; then
  echo "preflight: this branch adds no migration, so A–D and F–H have nothing to read"
  exit "$FAILED"
fi

python3 "$HERE/preflight_rules.py" "$ROOT" branch $TARGETS || FAILED=1

exit "$FAILED"
