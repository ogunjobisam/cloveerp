#!/usr/bin/env bash
#
# The migrations a from-empty replay applies.
#
# The same files as supabase/migrations, less the suite calls that
# supabase/ci/replay_superseded_calls.txt names: each of those lines becomes a
# comment saying why, so every other line keeps its number and an error from
# the replay still points at the right line of the committed file.
#
# Nothing under supabase/migrations is touched. A deploy applies only what the
# live database has not run, and has run every file named in the register, so
# this is a statement about replays and nothing else.
#
# Usage: supabase/ci/replay_migrations.sh <destination directory>
#        REPLAY_REGISTER=<file> to read another register (its refusals are
#        tested that way, without touching the real one)
set -euo pipefail

DEST="${1:?usage: $0 <destination directory>}"
REGISTER="${REPLAY_REGISTER:-$(dirname "$0")/replay_superseded_calls.txt}"
MIGRATIONS="$(dirname "$0")/../migrations"

if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  echo "x $DEST is not empty; refusing to mix a replay's migrations with anything else." >&2
  exit 2
fi
mkdir -p "$DEST"
cp "$MIGRATIONS"/*.sql "$DEST"/

FAILED=0
SKIPPED=0
while read -r migration line superseded_by routine _; do
  case "$migration" in ""|"#"*) continue ;; esac

  if [ ! -f "$MIGRATIONS/$migration" ]; then
    echo "x $REGISTER names $migration, which does not exist." >&2
    FAILED=1; continue
  fi
  if [ ! -f "$MIGRATIONS/$superseded_by" ]; then
    echo "x $REGISTER supersedes $migration by $superseded_by, which does not exist." >&2
    FAILED=1; continue
  fi
  if [[ ! "$migration" < "$superseded_by" ]]; then
    echo "x $REGISTER supersedes $migration by $superseded_by, which does not come after it." >&2
    FAILED=1; continue
  fi

  expected="select ${routine}();"
  actual="$(sed -n "${line}p" "$MIGRATIONS/$migration")"
  if [ "$actual" != "$expected" ]; then
    echo "x $migration:$line is '$actual', not '$expected'." >&2
    FAILED=1; continue
  fi

  sed -i.bak "${line}s|.*|-- replay: ${expected} superseded by ${superseded_by} (supabase/ci/replay_superseded_calls.txt)|" \
    "$DEST/$migration"
  rm -f "$DEST/$migration.bak"
  echo "- $migration:$line  ${routine}  (superseded by $superseded_by)"
  SKIPPED=$((SKIPPED + 1))
done < "$REGISTER"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "replay: $(ls "$DEST"/*.sql | wc -l | tr -d ' ') migration(s), $SKIPPED superseded suite call(s) not made"
