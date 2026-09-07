#!/usr/bin/env bash
#
# Every permission code the application names exists in the catalogue.
#
# erp.assert_authorise_codes_exist() already proves this of the gates in the
# database, where a gate on a code the catalogue does not hold refuses
# everybody and the refusal looks like the system working. The application's
# gates had no such proof.
#
# The client gate is hasPermission(session, "module.action"), and the code is a
# bare string. Nothing compared those strings with erp_ref.permission, and the
# failure they cause is the quietest one this application has: hasPermission()
# asks whether the session's list contains the code, a code the catalogue does
# not hold is in nobody's list, and so the control is refused for everybody, in
# silence, for ever. There is no error, no refusal, no empty state — the button
# is simply disabled with "Requires administration.approve" on it, which was
# true of the approve and reject buttons on /governance on the day this was
# written. No test can see that: a suite that asserts a role cannot press the
# button agrees with a screen nobody can press it on.
#
# So this extracts every permission code from src and hands the list to
# erp.assert_app_permissions_exist(), which refuses any code the catalogue does
# not hold. A permission renamed in a migration without its screens, or a
# screen typed against a permission that was never catalogued, fails the build
# here.
#
# Three shapes, because the app names a permission three ways:
#
#   1. hasPermission(session, "…") — the gate itself, called from a route.
#   2. permission: "…" — the declared form. A tile in src/lib/modules.tsx, a
#      nav entry, an inquiry spec: the component reads the field and passes it
#      to hasPermission(), so by the time it reaches the gate it is a variable
#      and a grep for the call site sees none of them. Most of the codes the
#      product names are this shape.
#   3. permission="…" — the same field as a JSX prop on ActionBar, RpcButton
#      and the rest, where the literal is at the call site and the gate is in
#      the component. Same blind spot again, and the shape the defect above
#      was in.
#
# Matched by position rather than by shape: a permission code is module.action,
# which is also what a resource key, a file name and a dotted identifier look
# like, so a grep for the shape alone would hand the assertion strings that
# were never permissions and fail the build on them. Add a shape here only
# after checking the string reaches hasPermission().
#
# Usage: supabase/ci/app_permissions.sh [src-dir]   (default: src beside this script's repo)
# Reads PSQL from the environment like run_checks.sh. Prints the count.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$here/src}"

# Tests are left out for the reason app_doors.sh leaves them out: a test may
# name a code on purpose to prove a refusal.
code='"[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*"'
find_codes() {
  grep -rhoE "$1" "$SRC" \
    --include='*.ts' --include='*.tsx' \
    --exclude='*.test.ts' --exclude='*.test.tsx' || true
}

mapfile -t codes < <(
  {
    find_codes "hasPermission\([^,)]+,[[:space:]]*$code"
    find_codes "permission:[[:space:]]*$code"
    find_codes "permission=$code"
  } | grep -oE "$code" | tr -d '"' | sort -u
)

if [[ ${#codes[@]} -eq 0 ]]; then
  echo "no permission codes found under $SRC; that is the failure, not a pass" >&2
  exit 1
fi

list=$(printf "'%s'," "${codes[@]}")
list="array[${list%,}]::text[]"
out=$($PSQL_CMD -tAc "select erp.assert_app_permissions_exist($list);")
echo "$out"
