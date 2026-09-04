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
# Three sources, because the app says its words three ways:
#
#   1. ui("…") literals, anywhere under src.
#   2. The module declaration in src/lib/modules.tsx, where a module states its
#      title, blurb, panels, empty states and column headers as data and the
#      components pass every one of them through ui(). Those words are just as
#      visible — they are the tiles, the launchpad, the tab strips and the
#      tables — but by the time they reach ui() they are a variable, so a grep
#      for literals could not see a single one. 465 declared strings, 66 with
#      no row, on the day this was extended.
#   3. Strings a route passes to a component as a JSX prop, which the component
#      renders through ui(). The card headings and the sentence under them:
#      ActionBar's title and note, AutoPanel's title, description and empty.
#      Same blind spot as (2) and a different shape — the literal is at the
#      call site and the ui() call is in the component, so neither a grep for
#      ui("…") nor a read of modules.tsx sees it. 73 strings, 64 with no row,
#      on the day this was extended, and seeding them found three that said
#      "Receiving" and "principal" where the product prescribes Goods-in and
#      User.
#
# Not covered, and worth knowing before assuming this is exhaustive: the field
# labels and hints inside an action's declaration, and ActionDialog's own title
# and description. They go through ui() the same way. They were left out
# because they are a form's words rather than a screen's, and because the set
# is five times the size of this one — not because they are renameable.
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

# The prop strings. A JSX opening tag is scanned rather than regexed whole,
# because a prop's value can contain a `>` and the tag can span lines; the
# scanner tracks quoting and brace depth so it stops at the tag's own `>`
# rather than at one inside an expression.
python3 - "$SRC" > "$WORK/props.txt" <<'PY'
import re, pathlib, sys

COMPONENTS = {"ActionBar": ("title", "note"), "AutoPanel": ("title", "description", "empty")}

def opening_tags(src, name):
    for m in re.finditer(r"<" + name + r"(?=[\s/>])", src):
        i, depth, instr = m.end(), 0, None
        while i < len(src):
            c = src[i]
            if instr:
                if c == "\\":
                    i += 2
                    continue
                if c == instr:
                    instr = None
            elif c in "\"'`":
                instr = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            elif c == ">" and depth == 0:
                yield src[m.end() : i]
                break
            i += 1

found = set()
for path in pathlib.Path(sys.argv[1]).rglob("*.tsx"):
    if path.name.endswith(".test.tsx"):
        continue
    src = path.read_text()
    for component, props in COMPONENTS.items():
        if f"<{component}" not in src:
            continue
        for attrs in opening_tags(src, component):
            for prop in props:
                for m in re.finditer(prop + r'="((?:[^"\\]|\\.)*)"', attrs):
                    found.add(m.group(1))
for value in sorted(found):
    print(value)
PY

cat "$WORK/literals.txt" "$WORK/declared.txt" "$WORK/props.txt" | sort -u > "$WORK/strings.txt"

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
