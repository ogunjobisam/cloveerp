#!/usr/bin/env bash
#
# No organisation's address is a page the application already has.
#
# An organisation is found at /<its code> (src/routes/$address.tsx), and that
# route is the least specific at the top level: /sales, /help and /signin are
# static routes and win. So an organisation holding the code "help" would own
# an address that only ever opens the help page — and a route added tomorrow
# at /acme would take the address of an organisation that has held it for a
# year, without an error anywhere.
#
# The database refuses a reserved code on the way in (erp.tenant_code_admits).
# What it cannot see is the list of routes. This hands it every top-level
# route name under src/routes, and erp.assert_route_names_reserved() refuses
# one that erp_meta.reserved_tenant_code does not hold — and one that an
# organisation already holds, so the collision is named before it ships.
#
# Usage: supabase/ci/app_addresses.sh [src-dir]   (default: src beside this script's repo)
# Reads PSQL from the environment like run_checks.sh. Prints the count.

set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$here/src}"
ROUTES="$SRC/routes"

# A top-level route is a file or a directory directly under src/routes. The
# root layout, the index and the address route itself are not names anybody
# types; a name holding a dot or a bracket (sitemap[.]xml) cannot be an
# address, so it cannot collide with one. TanStack's flat "a.b.tsx" files
# name their first segment before the dot.
mapfile -t names < <(
  find "$ROUTES" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -print \
  | sed -E -e "s#^$ROUTES/##" -e 's#\.tsx?$##' \
  | grep -vE '^(__root|index|\$address|README\.md)$' \
  | grep -vE '\[' \
  | sed -e 's#\..*$##' \
  | grep -E '^[a-z0-9][a-z0-9-]*$' \
  | sort -u
)

if [[ ${#names[@]} -eq 0 ]]; then
  echo "no top-level routes found under $ROUTES; that is the failure, not a pass" >&2
  exit 1
fi

list=$(printf "'%s'," "${names[@]}")
list="array[${list%,}]::text[]"
$PSQL_CMD -tAc "select erp.assert_route_names_reserved($list);"
