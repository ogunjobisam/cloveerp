#!/usr/bin/env bash
#
# Every assertion and every suite, against a database that is already built.
#
# CI applies the migrations and then runs two lists: the structural assertions,
# and thirty-one adversarial suites. A migration that passes its own final
# assertions can still fail one of those, and did: 20260904720000 widened
# erp.assert_authorising_doors_are_volatile() and its summary sentence, which a
# suite written three migrations earlier pinned by regex. The build was green
# and the checks were not, because "the build is green" and "the checks pass"
# were never the same claim.
#
# So this runs both lists locally, and casts a wider net than the workflow does:
# every zero-argument erp.assert_* and erp_test.assert_* the database actually
# has, rather than the ones somebody remembered to add to the YAML. A check that
# exists and is not run is a check that is not there.
#
# Two classes are expected not to pass here. They are reported as skipped rather
# than hidden, because a skip nobody sees is how a real failure comes to look
# like a known one:
#
#   - Three assertions are per-tenant by construction and raise
#     ERPWARE_NO_TENANT_CONTEXT outside a tenant session.
#   - erp_test.gateway_suite() fails three of forty-nine cases wherever
#     extensions.jsonb_matches_schema is the `select true` stub, which a local
#     Postgres without pg_jsonschema is. Two cases assert that an invalid
#     connection and an invalid payload are refused; the third counts the
#     commands a worker claims, which is one higher because the invalid one was
#     accepted. All three pass in CI, where the extension is real. A count other
#     than 3/49 is not the stub and is not skipped.
#
# Usage: supabase/ci/run_checks.sh
# Reads PSQL from the environment, defaulting to a plain psql.
set -uo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"

fail=0
skip=0
pass=0

run_one() {
  local call="$1"
  local out
  if out="$($PSQL_CMD -tAc "select $call;" 2>&1)"; then
    pass=$((pass + 1))
    printf '  ok   %-56s %s\n' "$call" "${out:0:70}"
  elif [[ "$out" == *ERPWARE_NO_TENANT_CONTEXT* ]]; then
    skip=$((skip + 1))
    printf '  skip %-56s per-tenant, not runnable schema-level\n' "$call"
  elif [[ "$call" == *gateway_suite* && "$out" == *"GATEWAY_SUITE_FAILED: 3/49"* ]]; then
    skip=$((skip + 1))
    printf '  skip %-56s 3/49, exactly the jsonb_matches_schema stub\n' "$call"
  else
    fail=$((fail + 1))
    printf '  FAIL %-56s\n%s\n' "$call" "$out"
  fi
}

# Zero-argument assertions and suites, from the catalogue rather than from a
# list somebody maintains by hand.
mapfile -t checks < <($PSQL_CMD -tAc "
  select n.nspname || '.' || p.proname || '()'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where ((n.nspname = 'erp'      and p.proname like 'assert\_%')
       or (n.nspname = 'erp_test' and p.proname like 'assert\_%'))
     and p.pronargs = 0
     -- Functions only. The one property that cannot be observed from inside the
     -- transaction that would call it is a procedure, and is called below; a
     -- select on it fails for the wrong reason and reads like a regression.
     and p.prokind = 'f'
   order by n.nspname, p.proname;")

if [[ ${#checks[@]} -eq 0 ]]; then
  echo "No assertions found. That is the failure, not a pass." >&2
  exit 1
fi

echo "Running $(( ${#checks[@]} + 3 )) checks."
for c in "${checks[@]}"; do
  [[ -n "$c" ]] && run_one "$c"
done

# The two that take a defaulted argument, which pronargs = 0 does not see. A
# filter that quietly excludes a check is how erp.assert_determination_coverage
# went unnoticed on live for a fortnight.
run_one "erp.assert_resource_coverage('en')"
run_one "erp.assert_determination_coverage()"

# And the procedure.
if out="$($PSQL_CMD -tAc "call erp_test.assert_context_not_leaked();" 2>&1)"; then
  pass=$((pass + 1))
  printf '  ok   %-56s %s\n' "call erp_test.assert_context_not_leaked()" "${out:0:70}"
else
  fail=$((fail + 1))
  printf '  FAIL %-56s\n%s\n' "call erp_test.assert_context_not_leaked()" "$out"
fi

echo
echo "pass ${pass}, skip ${skip}, fail ${fail}"
[[ $fail -eq 0 ]]
