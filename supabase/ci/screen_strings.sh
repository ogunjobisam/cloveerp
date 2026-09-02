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
# Two sources, because the app says its words two ways:
#
#   1. ui("…") literals, anywhere under src.
#   2. The module declaration in src/lib/modules.tsx, where a module states its
#      title, blurb, panels, empty states and column headers as data and the
#      components pass every one of them through ui(). Those words are just as
#      visible — they are the tiles, the launchpad, the tab strips and the
#      tables — but by the time they reach ui() they are a variable, so a grep
#      for literals could not see a single one. 465 declared strings, 66 with
#      no row, on the day this was extended.
#
# Usage: supabase/ci/screen_strings.sh [src-dir]
# Reads PSQL from the environment, defaulting to a plain psql.
set -euo pipefail

SRC="${1:-src}"
PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
WORK="$(mktemp -d)"
# World-readable: \copy runs as the psql client, but a server-side COPY or a
# psql run as another user still has to be able to read the file.
chmod 755 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# ui("…") only. The single-argument form is the whole convention: t(key,
# fallback) names its key explicitly and is covered by
# erp.assert_resource_coverage().
grep -rhoE --exclude='*.test.ts' --exclude='*.test.tsx' 'ui\("(([^"\\]|\\.)*)"\)' "$SRC" \
  | sed -E 's/^ui\("//; s/"\)$//' | sort -u > "$WORK/literals.txt"

# The declared strings. Only the fields the components actually render through
# ui(): a `fn` or a permission code is not a word anybody reads.
python3 - "$SRC/lib/modules.tsx" > "$WORK/declared.txt" <<'PY'
import re, sys
try:
    src = open(sys.argv[1]).read()
except FileNotFoundError:
    sys.exit(0)
pat = re.compile(r'\b(title|description|empty|header|label|blurb|hint|note)\s*:\s*"((?:[^"\\]|\\.)*)"')
for v in sorted({m.group(2) for m in pat.finditer(src)}):
    print(v)
PY

cat "$WORK/literals.txt" "$WORK/declared.txt" | sort -u > "$WORK/strings.txt"

python3 - "$WORK/strings.txt" > "$WORK/strings.csv" <<'PY'
import csv, sys
w = csv.writer(sys.stdout)
for line in open(sys.argv[1]):
    # The source is a TypeScript string literal, so \" is a quote and \\ a
    # backslash. Undo that before comparing with what the database stores.
    w.writerow([line.rstrip("\n").replace('\\"', '"').replace("\\\\", "\\")])
PY
chmod 644 "$WORK/strings.csv"

$PSQL_CMD <<SQL
create temp table ui_literal(text text);
\copy ui_literal from '$WORK/strings.csv' with (format csv)
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
