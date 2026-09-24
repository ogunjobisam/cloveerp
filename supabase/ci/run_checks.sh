#!/usr/bin/env bash
#
# Every check in the catalogue, against a database that is already built.
#
# This is the build's runner. It used to be a local convenience beside a
# workflow that kept two hand-typed lists — sixty assertions and seventy-two
# suite wrappers — while the catalogue held seventy-three and seventy-two.
# Twelve assertions never ran in any build, among them the four that say
# whether stock, the subledgers, the inventory valuation and the batch
# genealogy agree with themselves. A check that exists and is not run is a
# check that is not there.
#
# So there is no list here. erp.ci_check_catalogue() reads pg_proc and returns
# every erp.assert_* and erp_test.assert_* that can be called with no
# arguments, in the order they should run: structural assertions, adversarial
# suites, the one procedure, and the whole-database reconciliation last. A new
# check is run by existing. A check that takes arguments is run by the routine
# registered as driving it in erp_meta.check_run_exemption, or is exempt for a
# written reason; erp.assert_ci_coverage() refuses anything else.
#
# When everything has run, the names that ran are handed back to
# erp.assert_ci_ran(), which refuses if the catalogue holds a name this script
# did not run, or this script ran a name the catalogue does not hold. The
# database keeps the list; the runner only proves it followed it.
#
# Nothing is skipped. The two skips this file used to carry are gone for good
# reasons: the per-tenant reconciliations are now driven for every organisation
# by erp.assert_whole_database_reconciles(), and erp_test.gateway_suite()
# passes 49/49 on a host without pg_jsonschema because erp.jsonb_matches_schema()
# enforces `required` in SQL before asking the extension.
#
# Two cadences, since 20260924560000. A push runs every check not registered
# in erp_meta.check_cadence; the nightly runs every check. The register names
# five demonstration suites whose fixtures trade an organisation for minutes,
# twenty of the twenty-seven a push used to wait. What a push leaves is printed
# here by name, and erp.assert_ci_ran() is told which cadence ran, so it still
# refuses a push that left anything unregistered unrun, and refuses a cadence
# it does not know. The nightly is the from-empty build and owes everything.
#
# Each check is timed, and the ten slowest are printed at the end and into the
# step summary when there is one. The walk on main took 27 minutes before
# anything said which check the time went on; that is what this prints.
#
# Usage: CATALOGUE_CADENCE=push|nightly supabase/ci/run_checks.sh
# Reads PSQL from the environment, defaulting to a plain psql. The cadence
# defaults to nightly, which is every check, so a bare run owes everything.
set -uo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
CADENCE="${CATALOGUE_CADENCE:-nightly}"
case "$CADENCE" in
  push|nightly) ;;
  *) echo "CATALOGUE_CADENCE must be push or nightly, not '$CADENCE'." >&2; exit 2 ;;
esac

fail=0
pass=0
ran=()
timings=()

# Milliseconds where date knows %N (GNU), whole seconds where it does not
# (BSD, a Mac): a timing that is coarse beats a script that stops.
now_ms() {
  local t
  t=$(date +%s%3N 2>/dev/null)
  if [[ "$t" =~ ^[0-9]+$ ]]; then echo "$t"; else echo "$(( $(date +%s) * 1000 ))"; fi
}

run_one() {
  local name="$1" call="$2"
  local out started elapsed
  started=$(now_ms)
  if out="$($PSQL_CMD -tAc "$call;" 2>&1)"; then
    elapsed=$(( $(now_ms) - started ))
    pass=$((pass + 1))
    printf '  ok   %-58s %6d ms  %s\n' "$name" "$elapsed" "${out:0:64}"
  else
    elapsed=$(( $(now_ms) - started ))
    fail=$((fail + 1))
    printf '  FAIL %-58s %6d ms\n%s\n' "$name" "$elapsed" "$out"
  fi
  # It ran, whichever way it went. The failure count fails the build; the
  # list proves the catalogue was followed.
  ran+=("$name")
  timings+=("$elapsed $name")
}

# What the cadence leaves to the nightly, by name, before anything runs: a
# push log that does not say what it skipped is a push log that hides it.
if [[ "$CADENCE" == push ]]; then
  mapfile -t deferred < <($PSQL_CMD -tAc "
    select c.qualified_name
      from erp.ci_check_catalogue() c
      join erp_meta.check_cadence k
        on k.schema_name = c.schema_name and k.function_name = c.function_name
     order by c.seq, c.schema_name, c.function_name;")
  echo "Cadence push: ${#deferred[@]} check(s) registered in erp_meta.check_cadence wait for the nightly:"
  for d in "${deferred[@]}"; do [[ -n "$d" ]] && echo "  -    $d"; done
else
  echo "Cadence nightly: every check in the catalogue."
fi

mapfile -t rows < <($PSQL_CMD -tAc "
  select c.phase || '|' || c.qualified_name || '|' || c.call
    from erp.ci_check_catalogue() c
   where '$CADENCE' = 'nightly'
      or not exists (select 1 from erp_meta.check_cadence k
                      where k.schema_name = c.schema_name and k.function_name = c.function_name)
   order by c.seq, c.schema_name, c.function_name;")

if [[ ${#rows[@]} -eq 0 ]]; then
  echo "erp.ci_check_catalogue() returned nothing. That is the failure, not a pass." >&2
  exit 1
fi

echo "Running ${#rows[@]} checks from erp.ci_check_catalogue() at cadence $CADENCE."
walk_started=$(now_ms)
phase=""
for row in "${rows[@]}"; do
  [[ -z "$row" ]] && continue
  IFS='|' read -r p name call <<<"$row"
  if [[ "$p" != "$phase" ]]; then
    phase="$p"
    echo "── $phase"
  fi
  run_one "$name" "$call"
done

# Hand the list back. A catalogue check missing from it, or a name in it that
# the catalogue does not carry, is a refusal.
echo "── coverage"
list=$(printf "'%s'," "${ran[@]}")
list="array[${list%,}]::text[]"
if out="$($PSQL_CMD -tAc "select erp.assert_ci_ran($list, '$CADENCE');" 2>&1)"; then
  printf '  ok   %-58s %s\n' "erp.assert_ci_ran" "$out"
else
  fail=$((fail + 1))
  printf '  FAIL %-58s\n%s\n' "erp.assert_ci_ran" "$out"
fi

walk_ms=$(( $(now_ms) - walk_started ))

echo "── the ten slowest"
slowest="$(printf '%s\n' "${timings[@]}" | sort -rn | head -10 | awk '{ printf "  %7d ms  %s\n", $1, $2 }')"
echo "$slowest"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Catalogue, cadence $CADENCE"
    echo "${#rows[@]} checks in $(( walk_ms / 1000 )) s; pass ${pass}, fail ${fail}. The ten slowest:"
    echo '```'
    echo "$slowest"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo
echo "pass ${pass}, fail ${fail}, of ${#rows[@]} catalogue checks at cadence $CADENCE, in $(( walk_ms / 1000 )) s"
[[ $fail -eq 0 ]]
