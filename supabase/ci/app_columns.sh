#!/usr/bin/env bash
#
# Every column a screen reads is one its door returns.
#
# A panel declares a door and the names it reads off each row in the same
# breath — fn: "erp_delivery_performance" and cell: "otif_pct" — and nothing
# compared the two. The helper renders a missing key as "—" and the arithmetic
# reads it as zero, so a name the door never emits does not fail: it produces a
# confident, permanently wrong number. On 16 September the logistics OTIF tile
# was 0% and red for every organisation because the door answers with
# on_time_pct; the works-order panel showed every order 0 completed and 0
# scrapped because the door says completed and scrapped; the planning tile
# "Unacknowledged" counted every exception ever raised because it tested
# !r["is_acknowledged"] against a door that emits acknowledged_at, and !undefined
# is true of every row. Thirty-five such names were found in one walk.
#
# No suite can see this class. A suite that proves the door returns the right
# figures agrees with a screen that asks it for a name it does not have, and
# TypeScript cannot help: every row is Record<string, unknown>, so r["otif_pct"]
# type-checks against a door that has never heard of it.
#
# So this harvests every (door, column) pair the desk declares and hands the
# list to erp.assert_app_columns_exist(), which derives what each door can
# produce FROM THE BUILT DATABASE — the TABLE parameters of a set-returning
# function, the jsonb_build_object keys of a json one, and, where the door is
# to_jsonb(x) over an erp.* function or view, that function's or view's own
# columns — so a rename in a migration fails the build on the day it lands
# rather than three weeks later on a screen. A door whose json the text cannot
# name is counted, not failed; a pair the register accounts for is allowed with
# its reason; anything else is refused.
#
# Harvesting names across the lines of one declaration is beyond grep, so the
# harvest is Python, as supabase/ci/app_gates.sh's and screen_strings.sh's are.
# It reads a name only inside a declaration that says how a row is SHOWN — a
# panel's columns, a stage list's title and status, a picker's value and label,
# a tile's arithmetic. An <RpcButton fn="erp_decide_approval" args={{p_task_id:
# r["task_id"]}}/> sitting in a panel's cell reads the panel's row, not its own
# door's, and is not a declaration of that door's shape; only a declaration that
# says how a row is shown rebinds what r means.
#
# A door's answer is not always flat, and a declaration says which part of it it
# renders. public.erp_settlement_statement() answers with one object whose
# `lines` key holds an array of objects, each of whose `candidates` key holds
# another; erp_analytics_contract answers with `views`, `credentials` and
# `findings`, three arrays of different shapes. A picker names the one it
# renders — options: { path: "lines", value: "line_id" }, and `within` goes one
# further — so line_id is harvested as `lines.line_id`, not as `line_id`, and
# the database is asked for the key path rather than the key. Flattening the
# answer instead would have said a picker on `credentials` may read
# `module_code`, which belongs to `views`: the very thing this refuses.
#
# Usage: supabase/ci/app_columns.sh [src-dir]   (default: src beside this repo)
# Reads PSQL from the environment like run_checks.sh. Prints the count.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$here/src}"

# The check reads the built database. Without psql there is no database to read,
# and a check that cannot run must say so rather than exit clean.
psql_bin="${PSQL_CMD%% *}"
if ! command -v "$psql_bin" >/dev/null 2>&1; then
  echo "app_columns.sh: '$psql_bin' is not on PATH." >&2
  echo "  This check asks the built database what each door returns; it cannot be" >&2
  echo "  answered from the migration text. Point PSQL at a database built from" >&2
  echo "  supabase/migrations (see .github/workflows/schema.yml) and run it again." >&2
  exit 127
fi

mapfile -t pairs < <(python3 - "$SRC" <<'PY'
import bisect, pathlib, re, sys

SRC = pathlib.Path(sys.argv[1])
DOOR_RE = re.compile(r"^erp_[a-z0-9_]+$")
NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")

CONST_RE = re.compile(
    r'^\s*(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*(?::\s*[^=\n]+)?=\s*"((?:[^"\\]|\\.)*)"\s*(?:as\s+const)?\s*;?\s*$',
    re.M)
REGEX_BEFORE = set("(,=:[!&|?{};>\n")


def skip(path):
    n = path.name
    return n.endswith(".test.ts") or n.endswith(".test.tsx") or n.endswith(".gen.ts") \
        or "integrations" in path.parts


def classify(src):
    """Per character: 'c' code, 's' string/regex/template, ' ' comment. Braces
    and keys are read from code only; values from the original text."""
    n = len(src)
    kind = [" "] * n

    def prev_code(i):
        j = i - 1
        while j >= 0:
            if kind[j] == "s":
                return src[j]
            if kind[j] == "c":
                if src[j] in " \t\r":
                    j -= 1
                    continue
                return src[j]
            if src[j] == "\n":
                return "\n"
            j -= 1
        return "\n"

    def scan_code(i, until_close):
        depth = 0
        while i < n:
            c = src[i]
            if c == "/" and i + 1 < n and src[i + 1] == "/":
                j = src.find("\n", i); i = n if j < 0 else j; continue
            if c == "/" and i + 1 < n and src[i + 1] == "*":
                j = src.find("*/", i + 2); i = n if j < 0 else j + 2; continue
            if c in "\"'":
                j = i + 1
                while j < n and src[j] != c and src[j] != "\n":
                    if src[j] == "\\":
                        j += 1
                    j += 1
                for k in range(i, min(j + 1, n)):
                    kind[k] = "s"
                i = j + 1; continue
            if c == "`":
                i = scan_template(i); continue
            if c == "/" and i + 1 < n and src[i + 1] not in ">= \t\n" and prev_code(i) in REGEX_BEFORE:
                j = i + 1; in_class = False
                while j < n and src[j] != "\n":
                    ch = src[j]
                    if ch == "\\":
                        j += 2; continue
                    if in_class:
                        if ch == "]":
                            in_class = False
                    elif ch == "[":
                        in_class = True
                    elif ch == "/":
                        break
                    j += 1
                for k in range(i, min(j + 1, n)):
                    kind[k] = "s"
                i = j + 1
                while i < n and src[i].isalpha():
                    kind[i] = "s"; i += 1
                continue
            if until_close:
                if c == "{":
                    depth += 1
                elif c == "}":
                    if depth == 0:
                        return i
                    depth -= 1
            kind[i] = "c"; i += 1
        return i

    def scan_template(i):
        kind[i] = "s"; i += 1
        while i < n:
            c = src[i]
            if c == "\\":
                kind[i] = "s"
                if i + 1 < n:
                    kind[i + 1] = "s"
                i += 2; continue
            if c == "`":
                kind[i] = "s"; return i + 1
            if c == "$" and i + 1 < n and src[i + 1] == "{":
                kind[i] = kind[i + 1] = "s"
                j = scan_code(i + 2, True)
                if j < n:
                    kind[j] = "s"
                i = j + 1; continue
            kind[i] = "s"; i += 1
        return i

    scan_code(0, False)
    return "".join(kind)


def depth1_text(src, kind, start, end):
    """The declaration's own level: everything nested is blanked, so a picker's
    keys inside options: {…} are not read as the panel's own."""
    out, depth = [], 0
    for i in range(start + 1, end):
        c = src[i]
        if kind[i] == "c":
            if c in "{[(":
                out.append(" " if depth else c); depth += 1; continue
            if c in "}])":
                depth -= 1; out.append(" " if depth else c); continue
        out.append(c if depth == 0 else (" " if c != "\n" else "\n"))
    return "".join(out)


# ── the shapes a column name is written in ──────────────────────────────────
FN_KV = re.compile(r'(?<![\w$.?])fn\s*:\s*"((?:[^"\\]|\\.)*)"')
FN_IDENT = re.compile(r'(?<![\w$.?])fn\s*:\s*([A-Za-z_$][\w$]*)(?![\w$(])')
# On the declaration's own level: one name.
KEY_STR = re.compile(r'(?<![\w$.?])(id|status|value|path)\s*:\s*"([a-z][a-z0-9_]*)"')
# Which list inside the answer a picker renders. A door that answers with an
# object of several arrays is read one array at a time, and the names in that
# declaration are the ARRAY ELEMENT's, not the answer's: path: "lines" with
# value: "line_id" reads lines[].line_id. `within` goes one further — the
# candidates of the line chosen above — so its key is a name of the outer
# element and everything else is a name of the inner one.
PATH_KEY = re.compile(r'(?<![\w$.?])path\s*:\s*"([a-z][a-z0-9_]*)"')
WITHIN_KEY = re.compile(r'(?<![\w$.?])within\s*:\s*\{')
IN_WITHIN = re.compile(r'(?<![\w$.?])(key|path)\s*:\s*"([a-z][a-z0-9_]*)"')
# On the declaration's own level: a list of names. depth1_text blanks what is
# inside the brackets, so the key is found there and the list read from source.
KEY_LIST = re.compile(r'(?<![\w$.?])(title|subtitle|label)\s*:\s*\[')
STR_IN_LIST = re.compile(r'"([a-z][a-z0-9_]*)"')
# Anywhere inside the declaration.
CELL_STR = re.compile(r'(?<![\w$.?])cell\s*:\s*"([a-z][a-z0-9_]*)"')
HELPER_1 = re.compile(r'(?<![\w$.])pill\(\s*"([a-z][a-z0-9_]*)"')
HELPER_2 = re.compile(r'(?<![\w$.])date\(\s*"(?:[^"\\]|\\.)*"\s*,\s*"([a-z][a-z0-9_]*)"')
MONEY_CELL = re.compile(r'(?<![\w$.])moneyCell\(\s*"([a-z][a-z0-9_]*)"(?:\s*,\s*"([a-z][a-z0-9_]*)")?')
ROW_INDEX = re.compile(r'(?<![\w$.])(?:r|row|rec)\s*\[\s*"([a-z][a-z0-9_]*)"\s*\]')
AGG = re.compile(r'(?<![\w$.])(?:sum|avg|money)\(\s*rows\s*,\s*"([a-z][a-z0-9_]*)"')
CTX_MONEY = re.compile(r'\.money\(\s*rows\s*,\s*"([a-z][a-z0-9_]*)"')

# A declaration that says how a row is SHOWN, rather than one that only names a
# door to call. An <RpcButton fn="erp_decide_approval" args={{p_task_id:
# r["task_id"]}}/> in a panel's cell reads the panel's row, not its own door's.
READING = re.compile(
    r'(?<![\w$.?])(?:columns|rowKey|cell|compute|describe|keep|arrange)\s*[:=]'
    r'|(?<![\w$.?])(?:id|status|value|path)\s*:\s*"'
    r'|(?<![\w$.?])(?:title|subtitle|label)\s*:\s*\['
    r'|(?<![\w$.?])(?:label|value|money)\s*:\s*\(')
TAG_RE = re.compile(r"<([A-Z][\w.]*)(?=[\s/<>])")
COLUMNS_CONST = re.compile(r'(?<![\w$.?])columns\s*[:=]\s*\{?\s*([A-Z][A-Z_0-9]*)\b')
CONST_ARRAY = re.compile(r'(?:^|\n)\s*(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*(?::[^=\n]*)?=\s*\[')


def harvest(src, kind, rel, consts, out, unread):
    n = len(src)
    newlines = [i for i, c in enumerate(src) if c == "\n"]
    line_of = lambda off: bisect.bisect_right(newlines, off) + 1

    # A const array of columns, so `columns: RECEIVABLES_AGEING_COLUMNS` is read
    # where it is declared rather than reported as belonging to no door.
    arrays = {}
    for m in CONST_ARRAY.finditer(src):
        o = src.index("[", m.end() - 1)
        if kind[o] != "c":
            continue
        d, j = 0, o
        while j < n:
            if kind[j] == "c":
                if src[j] == "[":
                    d += 1
                elif src[j] == "]":
                    d -= 1
                    if d == 0:
                        break
            j += 1
        arrays[m.group(1)] = (o, j)

    def balanced_brace(o):
        d, j = 0, o
        while j < n:
            if kind[j] == "c":
                if src[j] == "{":
                    d += 1
                elif src[j] == "}":
                    d -= 1
                    if d == 0:
                        return j
            j += 1
        return n

    def reads_under(text, base):
        """What this declaration's names are names OF: '' for the answer itself,
        'lines.' for an element of its lines array, 'lines.candidates.' for an
        element of that element's candidates. Returns the prefix and the names
        the path declaration itself reads."""
        pm = PATH_KEY.search(text)
        if not pm or kind[base + pm.start()] != "c":
            return "", []
        outer, extra = pm.group(1), [pm.group(1)]
        wm = WITHIN_KEY.search(text)
        if not wm or kind[base + wm.start()] != "c":
            return outer + ".", extra
        o = src.index("{", base + wm.end() - 1)
        inner = {m.group(1): m.group(2) for m in IN_WITHIN.finditer(src, o, balanced_brace(o))}
        if "key" in inner:
            extra.append(outer + "." + inner["key"])
        if "path" not in inner:
            return outer + ".", extra
        extra.append(outer + "." + inner["path"])
        return outer + "." + inner["path"] + ".", extra

    # 1. every declaration that names a door and says how its rows are shown
    scopes = []
    stack = []
    for i, c in enumerate(src):
        if kind[i] != "c":
            continue
        if c == "{":
            stack.append(i)
        elif c == "}" and stack:
            start = stack.pop()
            text = depth1_text(src, kind, start, i)
            door = None
            m = FN_KV.search(text)
            if m and kind[start + 1 + m.start()] == "c":
                door = m.group(1)
            else:
                m2 = FN_IDENT.search(text)
                if m2 and kind[start + 1 + m2.start()] == "c" and m2.group(1) in consts:
                    door = consts[m2.group(1)]
            if door and DOOR_RE.match(door) and READING.search(text):
                prefix, extra = reads_under(text, start + 1)
                scopes.append((start, i, door, prefix))
                for name in extra:
                    out.add((door, name, f"{rel}:{line_of(start)}"))

    for m in TAG_RE.finditer(src):
        if kind[m.start()] != "c":
            continue
        start = m.end()
        # <DataPanel<Row> …> — step over the type argument so the attributes,
        # not the type, are what is read.
        if start < n and src[start] == "<":
            d, j = 0, start
            while j < n:
                if kind[j] == "c":
                    if src[j] == "<":
                        d += 1
                    elif src[j] == ">":
                        d -= 1
                        if d == 0:
                            break
                j += 1
            start = j + 1
        i, depth, depths = start, 0, {}
        while i < n:
            c = src[i]
            if kind[i] == "c":
                if c in "{([":
                    depth += 1
                elif c in "})]":
                    depth -= 1
                elif c == ">" and depth == 0:
                    break
            depths[i] = depth
            i += 1
        tag = src[start:i]
        am = re.search(r'(?<![\w$.\-])fn=\s*"(erp_[a-z0-9_]+)"', tag)
        attrs = "".join(tag[k] if depths.get(start + k, 1) == 0 else " " for k in range(len(tag)))
        if am and depths.get(start + am.start(), 1) == 0 and READING.search(attrs):
            # A JSX declaration never names a sub-array: path is an object key
            # on a picker's options, and no tag carries one.
            scopes.append((start, i, am.group(1), ""))

    if not scopes:
        return

    # A declaration that names a const array of columns reads that array too.
    for (s, e, door, prefix) in list(scopes):
        region = depth1_text(src, kind, s, e) if src[s] == "{" else src[s:e]
        for m in COLUMNS_CONST.finditer(region):
            span = arrays.get(m.group(1))
            if span:
                scopes.append((span[0], span[1], door, prefix))

    def owner(off):
        """The innermost declaration holding this offset."""
        best = None
        for s in scopes:
            if s[0] <= off < s[1] and (best is None or s[0] > best[0]):
                best = s
        return best

    def add(door, name, at):
        if NAME_RE.match(name.split(".")[-1]):
            out.add((door, name, f"{rel}:{at}"))

    # 2. the declaration's own level
    for (start, end, door, prefix) in scopes:
        text = depth1_text(src, kind, start, end)
        base = start + 1
        for m in KEY_STR.finditer(text):
            if kind[base + m.start()] != "c":
                continue
            # `path` names a key of the answer itself; reads_under has already
            # recorded it, and prefixing it would read it as its own child.
            if m.group(1) == "path":
                continue
            add(door, prefix + m.group(2), line_of(base + m.start()))
        for m in KEY_LIST.finditer(text):
            if kind[base + m.start()] != "c":
                continue
            o, d, j = base + m.end() - 1, 0, base + m.end() - 1
            while j < n:
                if kind[j] == "c":
                    if src[j] == "[":
                        d += 1
                    elif src[j] == "]":
                        d -= 1
                        if d == 0:
                            break
                j += 1
            for s in STR_IN_LIST.finditer(src, o, j):
                if kind[s.start()] == "s":
                    add(door, prefix + s.group(1), line_of(s.start()))

    # 3. anywhere inside a declaration
    for pattern, groups in ((CELL_STR, (1,)), (HELPER_1, (1,)), (HELPER_2, (1,)),
                            (MONEY_CELL, (1, 2)), (ROW_INDEX, (1,)), (AGG, (1,)),
                            (CTX_MONEY, (1,))):
        for m in pattern.finditer(src):
            if kind[m.start()] != "c":
                continue
            o = owner(m.start())
            if o is None:
                # A row read outside every declaration is a form's row — the
                # lines somebody typed on their way into a write — not a door's.
                if pattern is not ROW_INDEX:
                    unread.append(f"{rel}:{line_of(m.start())} {m.group(0).strip()}")
                continue
            for g in groups:
                if m.group(g):
                    add(o[2], o[3] + m.group(g), line_of(m.start()))


out, unread = set(), []
for path in sorted(list(SRC.rglob("*.tsx")) + list(SRC.rglob("*.ts"))):
    if skip(path):
        continue
    src = path.read_text()
    rel = str(path.relative_to(SRC.parent))
    kind = classify(src)
    consts = {m.group(1): m.group(2) for m in CONST_RE.finditer(src)}
    harvest(src, kind, rel, consts, out, unread)

if unread:
    print(f"app_columns.sh: {len(unread)} column name(s) belong to no declaration and "
          f"cannot be judged here:", file=sys.stderr)
    for u in unread:
        print("  " + u, file=sys.stderr)
for door, name in sorted({(d, n) for d, n, _ in out}):
    print(f"{door}|{name}")
PY
)

if [[ ${#pairs[@]} -eq 0 ]]; then
  echo "no (door, column) pairs found under $SRC; that is the failure, not a pass" >&2
  exit 1
fi

list=$(printf "'%s'," "${pairs[@]}")
list="array[${list%,}]::text[]"
out=$($PSQL_CMD -tAc "select erp.assert_app_columns_exist($list, true);")
echo "$out"
