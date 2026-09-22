#!/usr/bin/env bash
#
# A check nobody has seen fail is a check nobody has seen.
#
# supabase/ci/preflight.sh exists to refuse eight kinds of mistake before a
# push, and every one of them is a pattern match over text — which is to say
# every one of them can silently stop matching, and the only symptom would be
# a build failing again for a reason preflight was supposed to have caught an
# hour earlier. That is worse than not having it, because by then nobody is
# looking at preflight any more.
#
# So each rule gets a fixture in supabase/ci/preflight_fixtures that is wrong
# in exactly its way and right in every other, and this asserts three things
# about each: that preflight refuses it (or, for the two advisory rules,
# advises and exits zero), that it names the rule, and that no OTHER rule
# fires — a rule that refuses everything proves nothing by refusing. The clean
# fixture keeps the whole thing honest by passing.
#
# Rule E is about a branch and not about a file, so it gets a throwaway git
# repository instead: a migration committed on main, a second one added on a
# branch, and then the working tree dirtied. Preflight must refuse that, and
# must not refuse the same repository clean.
#
# Usage: supabase/ci/preflight_falsification.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FIXTURES="$HERE/preflight_fixtures"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "  ✓ $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  ✗ $1" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# One fixture, one rule.
#
#   expect_refusal <fixture> <rule> [n]
#                                     preflight must exit non-zero naming <rule>,
#                                     and, given n, refuse exactly n times
#   expect_advice  <fixture> <rule>   preflight must exit zero naming <rule>
#   expect_silence <fixture>          preflight must exit zero saying nothing
#
# All three also assert that no rule but the named one speaks, which is what
# makes the fixture evidence about that rule rather than about preflight
# being noisy.
# ─────────────────────────────────────────────────────────────────────────────

run_fixture() {
  set +e
  OUT="$("$HERE/preflight.sh" "$FIXTURES/$1" 2>&1)"
  CODE=$?
  set -e
}

rules_named() {
  echo "$OUT" | sed -n 's/.*(preflight rule \([A-J]\).*/\1/p' | sort -u | tr -d '\n'
}

expect_refusal() {
  local fixture="$1" rule="$2" want="${3:-}" seen refusals
  run_fixture "$fixture"
  seen="$(rules_named)"
  refusals="$(echo "$OUT" | grep -c '^✗' || true)"
  if [ "$CODE" -eq 0 ]; then
    fail "$fixture: preflight exited 0; rule $rule did not refuse it"
    echo "$OUT" | sed 's/^/      /' >&2
  elif [ "$seen" != "$rule" ]; then
    fail "$fixture: expected rule $rule alone, heard from [$seen]"
    echo "$OUT" | sed 's/^/      /' >&2
  elif [ -n "$want" ] && [ "$refusals" -ne "$want" ]; then
    fail "$fixture: expected $want refusals from rule $rule, counted $refusals"
    echo "$OUT" | sed 's/^/      /' >&2
  else
    pass "$fixture — rule $rule refuses it, and nothing else does"
  fi
}

expect_advice() {
  local fixture="$1" rule="$2" seen
  run_fixture "$fixture"
  seen="$(rules_named)"
  if [ "$CODE" -ne 0 ]; then
    fail "$fixture: an advisory rule must not fail the run (exit $CODE)"
    echo "$OUT" | sed 's/^/      /' >&2
  elif [ "$seen" != "$rule" ]; then
    fail "$fixture: expected rule $rule alone, heard from [$seen]"
    echo "$OUT" | sed 's/^/      /' >&2
  else
    pass "$fixture — rule $rule advises, and the run still passes"
  fi
}

expect_silence() {
  local fixture="$1" seen
  run_fixture "$fixture"
  seen="$(rules_named)"
  if [ "$CODE" -ne 0 ] || [ -n "$seen" ]; then
    fail "$fixture: a migration with nothing wrong with it must pass in silence"
    echo "$OUT" | sed 's/^/      /' >&2
  else
    pass "$fixture — nothing wrong with it, and preflight says nothing"
  fi
}

echo "preflight falsification: each rule, in front of the mistake it exists for"

expect_silence  29999999010000_clean.sql
expect_refusal  29999999020000_rule_a_live_singleton.sql A
expect_refusal  29999999030000_rule_b_unraised.sql       B
expect_refusal  29999999040000_rule_c_gate.sql           C
expect_refusal  29999999050000_rule_d_help.sql           D
expect_refusal  29999999060000_rule_f_allowance.sql      F
expect_refusal  29999999070000_rule_f_home.sql           F
expect_advice   29999999080000_rule_g_collateral.sql     G
expect_advice   29999999090000_rule_h_guard.sql          H
# Three bounds in the fixture, one of each shape — {n,m}, {n}, {n,} — and a
# refusal for each: a shape that stopped matching would leave two, not none.
expect_refusal  29999999100000_rule_j_bound.sql          J 3

# ─────────────────────────────────────────────────────────────────────────────
# E — a branch, not a file.
# ─────────────────────────────────────────────────────────────────────────────

TMP="$(mktemp -d "${TMPDIR:-/tmp}/preflight-falsification-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/supabase/ci" "$TMP/supabase/migrations" "$TMP/src"
cp "$HERE/preflight.sh" "$HERE/preflight_rules.py" \
   "$HERE/migrations_immutable.sh" "$HERE/migrations_edited.txt" "$TMP/supabase/ci/"

git -C "$TMP" init --quiet --initial-branch=main 2>/dev/null \
  || { git -C "$TMP" init --quiet; git -C "$TMP" checkout --quiet -b main; }
git_do() { git -C "$TMP" -c user.email=preflight@example.invalid -c user.name=preflight "$@"; }

echo "-- the migration main already has" > "$TMP/supabase/migrations/20260101000000_first.sql"
git_do add -A
git_do commit --quiet -m "the first migration"

git_do checkout --quiet -b work
echo "-- the migration this branch adds" > "$TMP/supabase/migrations/20260102000000_second.sql"
git_do add -A
git_do commit --quiet -m "the second migration"

set +e
OUT="$(cd "$TMP" && PREFLIGHT_BASE=main "$TMP/supabase/ci/preflight.sh" 2>&1)"
CODE=$?
set -e
if [ "$CODE" -ne 0 ] || echo "$OUT" | grep -q "preflight rule E"; then
  fail "a committed branch: preflight must not refuse a clean tree (exit $CODE)"
  echo "$OUT" | sed 's/^/      /' >&2
else
  pass "a committed branch — the immutability verdict is about what would be pushed"
fi

echo "-- and then edited without committing" >> "$TMP/supabase/migrations/20260102000000_second.sql"

set +e
OUT="$(cd "$TMP" && PREFLIGHT_BASE=main "$TMP/supabase/ci/preflight.sh" 2>&1)"
CODE=$?
set -e
if [ "$CODE" -eq 0 ] || ! echo "$OUT" | grep -q "preflight rule E"; then
  fail "an uncommitted migration: rule E must refuse to report success (exit $CODE)"
  echo "$OUT" | sed 's/^/      /' >&2
else
  pass "an uncommitted migration — rule E refuses, because the verdict would be about nothing"
fi

# ─────────────────────────────────────────────────────────────────────────────
# I — a version is claimed once
#
# Directory-level rather than per-migration, so it gets the throwaway tree the
# rule E cases already build rather than a fixture of its own: a clean tree must
# stay quiet, and a second file claiming a version that is already taken must be
# refused with BOTH filenames named. Naming only one would leave whoever meets
# it hunting for the other.
# ─────────────────────────────────────────────────────────────────────────────

cp "$TMP/supabase/migrations/20260102000000_second.sql" \
   "$TMP/supabase/migrations/20260102000000_a_second_claim.sql"

set +e
OUT="$(cd "$TMP" && PREFLIGHT_BASE=main "$TMP/supabase/ci/preflight.sh" 2>&1)"
CODE=$?
set -e
if [ "$CODE" -eq 0 ] || ! echo "$OUT" | grep -q "preflight rule I"; then
  fail "two files, one version: rule I must refuse (exit $CODE)"
  echo "$OUT" | sed 's/^/      /' >&2
elif ! echo "$OUT" | grep -q "20260102000000_a_second_claim.sql" \
  || ! echo "$OUT" | grep -q "20260102000000_second.sql"; then
  fail "rule I refused but did not name both files, so it does not say what to move"
  echo "$OUT" | sed 's/^/      /' >&2
else
  pass "two files, one version — rule I refuses, and names both claims"
fi

rm -f "$TMP/supabase/migrations/20260102000000_a_second_claim.sql"

set +e
OUT="$(cd "$TMP" && PREFLIGHT_BASE=main "$TMP/supabase/ci/preflight.sh" 2>&1)"
CODE=$?
set -e
if echo "$OUT" | grep -q "preflight rule I"; then
  fail "one file per version: rule I must stay quiet"
  echo "$OUT" | sed 's/^/      /' >&2
else
  pass "one file per version — rule I says nothing"
fi

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "$FAILED of $((PASSED + FAILED)) did not hold. A rule that has stopped firing is" >&2
  echo "worse than no rule: the build is the only thing left catching it, an hour later." >&2
  exit 1
fi
echo "preflight falsification: $PASSED held — every rule fires on its own mistake,"
echo "                         on nobody else's, and stays quiet on a clean migration"
