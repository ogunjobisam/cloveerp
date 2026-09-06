#!/usr/bin/env bash
#
# Every door the application names exists.
#
# The application calls the database by name: callErp("erp_something", args)
# through supabase.rpc, and every panel, action and invalidation key in
# src/lib/modules.tsx is a string. Nothing checked those strings against the
# schema. The generated types file is imported by nothing the app uses and was
# three days and four doors behind on the day this was written; six
# invalidation keys already named doors that do not exist, and nothing noticed
# because an invalidation of a key nobody queries is silent.
#
# So this extracts every erp_* literal from src and hands the list to
# erp.assert_app_doors_exist(), which refuses any name that is not a public
# door. A door renamed in a migration without its callers, or a caller typed
# against a door that was never built, fails the build here.
#
# Usage: supabase/ci/app_doors.sh [src-dir]   (default: src beside this script's repo)
# Reads PSQL from the environment like run_checks.sh. Prints the count.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$here/src}"

# Every quoted erp_* identifier in the application, once. Tests and the unused
# generated client are left out: a test may name a door on purpose to prove a
# refusal, and the generated file is a copy of the schema, not a caller.
mapfile -t doors < <(
  grep -rhoE '"erp_[a-z0-9_]+"' "$SRC" \
    --include='*.ts' --include='*.tsx' \
    --exclude='*.test.ts' --exclude='*.test.tsx' \
    --exclude-dir=integrations \
  | tr -d '"' | sort -u
)

if [[ ${#doors[@]} -eq 0 ]]; then
  echo "no erp_* names found under $SRC; that is the failure, not a pass" >&2
  exit 1
fi

list=$(printf "'%s'," "${doors[@]}")
list="array[${list%,}]::text[]"
out=$($PSQL_CMD -tAc "select erp.assert_app_doors_exist($list);")
echo "$out"
