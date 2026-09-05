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
# Usage: supabase/ci/run_checks.sh
# Reads PSQL from the environment, defaulting to a plain psql.
set -uo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"

fail=0
pass=0
ran=()

run_one() {
  local name="$1" call="$2"
  local out
  if out="$($PSQL_CMD -tAc "$call;" 2>&1)"; then
    pass=$((pass + 1))
    printf '  ok   %-58s %s\n' "$name" "${out:0:72}"
  else
    fail=$((fail + 1))
    printf '  FAIL %-58s\n%s\n' "$name" "$out"
  fi
  # It ran, whichever way it went. The failure count fails the build; the
  # list proves the catalogue was followed.
  ran+=("$name")
}

mapfile -t rows < <($PSQL_CMD -tAc "
  select phase || '|' || qualified_name || '|' || call
    from erp.ci_check_catalogue()
   order by seq, schema_name, function_name;")

if [[ ${#rows[@]} -eq 0 ]]; then
  echo "erp.ci_check_catalogue() returned nothing. That is the failure, not a pass." >&2
  exit 1
fi

echo "Running ${#rows[@]} checks from erp.ci_check_catalogue()."
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
if out="$($PSQL_CMD -tAc "select erp.assert_ci_ran($list);" 2>&1)"; then
  printf '  ok   %-58s %s\n' "erp.assert_ci_ran" "$out"
else
  fail=$((fail + 1))
  printf '  FAIL %-58s\n%s\n' "erp.assert_ci_ran" "$out"
fi

echo
echo "pass ${pass}, fail ${fail}, of ${#rows[@]} catalogue checks"
[[ $fail -eq 0 ]]
