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
# Four sources, because the app says its words four ways:
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
#   4. The words inside the forms: a field's label and hint, an action's button
#      text, a dialog's title and description, the options in a select. Same
#      blind spot again and the largest instance of it — 357 with no row, which
#      is the honest size of what the terminology screen could not see.
#
# Sources 3 and 4 are scoped to the components that actually render what they
# are handed through ui(). That scoping is the whole difficulty: `label:` also
# appears in a marketing page's data, in a route's head() meta, and in
# RpcButton, ConfigTransfer and the branding panel, none of which call ui() —
# so demanding rows for those would be the register claiming a renameability
# the code does not provide, which is the same class of lie this script exists
# to catch. Add a component here only after checking it passes the string
# through ui().
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
pat = re.compile(r'\b(title|description|empty|header|label|blurb|hint|note|howItWorks)\s*:\s*"((?:[^"\\]|\\.)*)"')
for v in sorted({m.group(2) for m in pat.finditer(src)}):
    print(v)
PY

# The scanners sources 3 and 4 share. A JSX opening tag, or an action's object
# literal, is scanned rather than regexed whole, because a prop's value can
# contain a `>` and the tag can span lines; the scanner tracks quoting and
# brace depth so it stops at the tag's own `>` rather than at one inside an
# expression.
#
# It skips comments, and has to. An apostrophe in one — "the organisation's
# first" — is prose, not a quote. Read as a quote, it put what followed inside
# a string that closed only at the next stray apostrophe, if ever: a tag's scan
# ran off the end of the file and yielded nothing, so every word in it went
# unchecked, and an object's ran on into its neighbours. Nothing said so,
# because a tag that yields nothing looks like a tag with nothing to say, and
# adding an unrelated action to a file was enough to change which words were
# hidden. On the day this was fixed, 56 strings in 8 files were hidden that way
# — the Organisation screen's sites card among them. Words in a comment are not
# on the screen either, so they are not harvested.
cat > "$WORK/tsx_scan.py" <<'PY'
import re

def code(src, i):
    """src from i, read as TypeScript: (character, quoted) for all but comments.
    quoted is true inside a string literal, where a brace or `>` is only text."""
    quote = None
    while i < len(src):
        c = src[i]
        if quote:
            if c == "\\":
                yield src[i:i + 2], True
                i += 2
                continue
            if c == quote:
                quote = None
            yield c, True
        elif c in "\"'`":
            quote = c
            yield c, True
        elif src.startswith("//", i):
            i = src.find("\n", i)
            if i < 0:
                return
            continue
        elif src.startswith("/*", i):
            i = src.find("*/", i + 2)
            if i < 0:
                return
            i += 2
            continue
        else:
            yield c, False
        i += 1

def spans(src, name):
    """The text of each <Name …> opening tag, less its comments."""
    for m in re.finditer(r"<" + name + r"(?=[\s/>])", src):
        depth, text = 0, []
        for c, quoted in code(src, m.end()):
            if not quoted:
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                elif c == ">" and depth == 0:
                    yield "".join(text)
                    break
            text.append(c)

def objects_with_fn(src):
    """Object literals carrying `fn: "…"` — an action declared outside any JSX."""
    for m in re.finditer(r'\bfn:\s*"', src):
        start = src.rfind("{", 0, m.start())
        if start < 0:
            continue
        depth, text = 0, []
        for c, quoted in code(src, start):
            text.append(c)
            if not quoted:
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        yield "".join(text)
                        break
PY

# The prop strings.
PYTHONPATH="$WORK" python3 - "$SRC" > "$WORK/props.txt" <<'PY'
import re, pathlib, sys
from tsx_scan import spans

COMPONENTS = {"ActionBar": ("title", "note"), "AutoPanel": ("title", "description", "empty")}

found = set()
for path in pathlib.Path(sys.argv[1]).rglob("*.tsx"):
    if path.name.endswith(".test.tsx"):
        continue
    src = path.read_text()
    for component, props in COMPONENTS.items():
        if f"<{component}" not in src:
            continue
        for attrs in spans(src, component):
            for prop in props:
                for m in re.finditer(prop + r'="((?:[^"\\]|\\.)*)"', attrs):
                    found.add(m.group(1))
for value in sorted(found):
    print(value)
PY

PYTHONPATH="$WORK" python3 - "$SRC" > "$WORK/form.txt" <<'PY'
import re, pathlib, sys
from tsx_scan import spans, objects_with_fn

# Components that render the strings handed to them through ui(). Anything not
# on this list renders its props raw, so its words are not renameable and must
# not be demanded here: RpcButton, ConfigTransfer and the branding panel are
# each a real example.
COMPONENTS = ("ActionBar", "ActionDialog", "AutoPanel", "InquiryBoard")
PROPS = ("title", "note", "description", "empty", "submitLabel")
KEYS = ("label", "hint", "title", "description", "submitLabel", "header", "empty")

def harvest(text, out):
    for p in PROPS:
        for m in re.finditer(r'(?<![\w-])' + p + r'="((?:[^"\\]|\\.)*)"', text):
            out.add(m.group(1))
    for k in KEYS:
        for m in re.finditer(r"\b" + k + r'\s*:\s*"((?:[^"\\]|\\.)*)"', text):
            out.add(m.group(1))

found = set()
for path in pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "src").rglob("*.tsx"):
    if path.name.endswith(".test.tsx"):
        continue
    src = path.read_text()
    for component in COMPONENTS:
        if f"<{component}" in src:
            for tag in spans(src, component):
                harvest(tag, found)
    for obj in objects_with_fn(src):
        harvest(obj, found)
    # The shared field builders state their label as a default parameter.
    for m in re.finditer(r'(?<![\w-])label\s*=\s*"((?:[^"\\]|\\.)*)"', src):
        found.add(m.group(1))

for value in sorted(found):
    print(value)
PY

cat "$WORK/literals.txt" "$WORK/declared.txt" "$WORK/props.txt" "$WORK/form.txt" \
  | sort -u > "$WORK/strings.txt"

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
    raise exception E'CLOVEERP_UNRENAMEABLE_SCREEN_STRINGS: % of % have no en resource row, so no tenant can rename them:\n  %',
      n, total, v_missing;
  end if;
  raise notice 'screen strings: % of % have a row they can be renamed by', total, total;
end;
\$\$;
SQL
