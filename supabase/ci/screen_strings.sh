#!/usr/bin/env bash
#
# Every screen string has a row it can be renamed by.
#
# The terminology layer's premise is that renaming is a glossary change with no
# code impact. That is only true of strings erp_ref.resource holds — and when
# this was written, 128 of the app's 201 ui() literals had no row at any
# locale. Two thirds of the screen chrome could not be renamed by a tenant, and
# was invisible to erp.terminology_alignment_report(), which reads that table
# and therefore showed zero drift over strings it could not see.
#
# A migration seeds what exists on the day it is written. Only this notices the
# two hundred and second.
#
# Usage: supabase/ci/screen_strings.sh [src-dir]
# Reads PSQL from the environment, defaulting to a plain psql.
set -euo pipefail

SRC="${1:-src}"
PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ui("…") only. The single-argument form is the whole convention: t(key,
# fallback) names its key explicitly and is covered by
# erp.assert_resource_coverage().
grep -rhoE 'ui\("(([^"\\]|\\.)*)"\)' "$SRC" \
  | sed -E 's/^ui\("//; s/"\)$//' | sort -u > "$WORK/literals.txt"

python3 - "$WORK/literals.txt" > "$WORK/literals.csv" <<'PY'
import csv, sys
w = csv.writer(sys.stdout)
for line in open(sys.argv[1]):
    # The source is a TypeScript string literal, so \" is a quote and \\ a
    # backslash. Undo that before comparing with what the database stores.
    w.writerow([line.rstrip("\n").replace('\\"', '"').replace("\\\\", "\\")])
PY

$PSQL_CMD <<SQL
create temp table ui_literal(text text);
\copy ui_literal from '$WORK/literals.csv' with (format csv)
do \$\$
declare v_missing text; n integer; total integer;
begin
  select count(*) into total from ui_literal;
  select count(*), string_agg(quote_literal(u.text), E'\n  ')
    into n, v_missing
    from ui_literal u
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(u.text) and r.locale = 'en');
  if n > 0 then
    raise exception E'ERPWARE_UNRENAMEABLE_SCREEN_STRINGS: % of % have no en resource row, so no tenant can rename them:\n  %',
      n, total, v_missing;
  end if;
  raise notice 'screen strings: % of % have a row they can be renamed by', total, total;
end;
\$\$;
SQL
