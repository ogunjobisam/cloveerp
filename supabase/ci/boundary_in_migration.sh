#!/usr/bin/env bash
#
# An ungoverned entry point cannot survive its own transaction.
#
# Specification v1.2 §16.2: "A migration that adds a callable function must
# register it and pass the boundary assertion in the same migration, so an
# ungoverned entry point cannot survive its own transaction."
#
# The build already runs erp.assert_public_api_safe() over the whole schema, and
# that catches an ungoverned door — eventually. "Eventually" is the gap this
# closes. A migration that creates a public function and does not assert lands
# green on any environment that applies it, and the ungoverned door exists there
# until some later build happens to run the assertion. Because every migration
# is applied --single-transaction, calling the assertion inside the migration
# means the door and the proof that it is governed either both land or neither
# does.
#
# The rule: a migration that creates a function in schema `public` must also
# call erp.assert_public_api_safe() in the same file.
#
# Twenty migrations predate this and cannot be corrected, because a migration is
# written once. They are named in boundary_grandfathered.txt rather than the bar
# being lowered — a rule with a visible list of exceptions is still a rule.
#
# Usage: supabase/ci/boundary_in_migration.sh
set -euo pipefail

HERE="$(dirname "$0")"
MIGRATIONS="$HERE/../migrations"
GRANDFATHERED="$HERE/boundary_grandfathered.txt"

FAILED=0
CHECKED=0

# Read the grandfathered list, ignoring comments and blanks.
is_grandfathered() {
  local base="$1"
  [ -f "$GRANDFATHERED" ] || return 1
  while read -r line; do
    case "$line" in ""|"#"*) continue ;; esac
    [ "$line" = "$base" ] && return 0
  done < "$GRANDFATHERED"
  return 1
}

for f in "$MIGRATIONS"/*.sql; do
  base="$(basename "$f")"

  # Does it create a callable entry point in the public schema?
  grep -qEi 'create( or replace)? function public\.' "$f" || continue

  CHECKED=$((CHECKED + 1))

  if grep -qi 'assert_public_api_safe' "$f"; then
    continue
  fi

  if is_grandfathered "$base"; then
    continue
  fi

  echo "✗ $base creates a function in schema public and does not call" >&2
  echo "  erp.assert_public_api_safe() in the same migration." >&2
  echo "  §16.2: an ungoverned entry point must not survive its own transaction." >&2
  FAILED=1
done

# A grandfathered entry naming a file that no longer exists is a list rotting
# quietly, which is how an exception register stops describing anything.
while read -r line; do
  case "$line" in ""|"#"*) continue ;; esac
  if [ ! -f "$MIGRATIONS/$line" ]; then
    echo "✗ $GRANDFATHERED names $line, which does not exist." >&2
    FAILED=1
  fi
done < "$GRANDFATHERED"

if [ "$FAILED" -ne 0 ]; then
  echo >&2
  echo "Add erp.assert_public_api_safe() to the end of the migration. The door" >&2
  echo "and the proof that it is governed then land together or not at all." >&2
  exit 1
fi

echo "boundary: $CHECKED migration(s) create a public entry point, and every one"
echo "          not grandfathered asserts the boundary in its own transaction"
