#!/usr/bin/env bash
#
# Every form asks for the permission its door asks for.
#
# The desk declares a door and a permission in the same breath — an action,
# a dialog, a button or an inquiry says fn: "erp_x" and permission: "a.b" —
# and nothing compared the two. The database is the enforcement, the
# permission prop is convenience, and when they disagree the convenience lies:
# a form shown to people the database refuses, or hidden from people it would
# serve. On 13 September three such forms were found by hand (merge under
# write against a door on approve; qualify supplier under procurement.order
# against master_data.approve; rollback under configure against promote), and
# a static walk then found fourteen more. No suite can see this class: one
# that asserts a role cannot press a button agrees with a form that nobody
# holding the right permission can reach.
#
# So this harvests every (door, permission) pair from src and hands the list
# to erp.assert_app_gates_match(), which follows each door into the erp.*
# functions it reaches and refuses a pair the chain never authorises. A door
# that authorises from data — a transition's required permission, a document
# type's create permission — cannot be judged from its text and is counted,
# not failed. A read that authorises nothing is scoped by row security and
# passes. A write that authorises nothing and carries a permission on the
# desk is the pattern CLAUDE.md forbids — a UI check as the only guard — and
# fails.
#
# Harvesting pairs across the lines of one object is beyond grep, so the
# harvest is Python, as supabase/ci/screen_strings.sh's is. It pairs only a
# door and a permission declared at the same level of one object literal or
# one JSX opening tag; a picker's read in a nested options: {…} is never the
# form's door. Values are string literals or same-file constants; a permission
# read from data (permission={type.create_permission}) cannot be harvested and
# is listed on stderr rather than guessed.
#
# Usage: supabase/ci/app_gates.sh [src-dir]   (default: src beside this script's repo)
# Reads PSQL from the environment like run_checks.sh. Prints the count.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$here/src}"

mapfile -t pairs < <(python3 - "$SRC" <<'PY'
import bisect, pathlib, re, sys

SRC = pathlib.Path(sys.argv[1])
DOOR_RE = re.compile(r"^erp_[a-z0-9_]+$")
PERM_RE = re.compile(r"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$")
# The framework relaying a declared spec — fn={a.fn} with the permission spread
# in. Not declarations: the spec they relay is harvested where it is declared.
PASS_THROUGH = {"actions-bar.tsx", "process-flow.tsx", "module-page.tsx", "auto.tsx"}
CONST_RE = re.compile(
    r'^\s*(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*(?::\s*[^=\n]+)?=\s*"((?:[^"\\]|\\.)*)"\s*(?:as\s+const)?\s*;?\s*$',
    re.M)
KV_RE = re.compile(r'(?<![\w$.?])(fn|permission)\s*:\s*'
                   r'(?:"((?:[^"\\]|\\.)*)"|([A-Za-z_$][\w$]*)(?![\w$(])|([^,\n}]+))')
ATTR_RE = re.compile(r'(?<![\w$.\-])(fn|permission)=')
TAG_RE = re.compile(r"<([A-Z][\w.]*)(?=[\s/>])")
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


def resolve(lit, ident, consts):
    if lit is not None:
        return lit, "literal"
    if ident is not None:
        if ident in ("string", "undefined", "null"):
            return None, "type"
        if ident in consts:
            return consts[ident], "const"
    return None, "dynamic"


def depth1_text(src, kind, start, end):
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


pairs, unharvestable, unbalanced = [], [], []
for path in sorted(list(SRC.rglob("*.tsx")) + list(SRC.rglob("*.ts"))):
    if skip(path):
        continue
    src = path.read_text()
    rel = str(path.relative_to(SRC.parent))
    kind = classify(src)
    opens = sum(1 for i, ch in enumerate(src) if kind[i] == "c" and ch == "{")
    closes = sum(1 for i, ch in enumerate(src) if kind[i] == "c" and ch == "}")
    if opens != closes:
        unbalanced.append(f"{rel}: {opens} open, {closes} close")
    consts = {m.group(1): m.group(2) for m in CONST_RE.finditer(src)}
    newlines = [i for i, c in enumerate(src) if c == "\n"]
    line_of = lambda off: bisect.bisect_right(newlines, off) + 1

    def record(door, perm, at):
        if door is None or perm is None or door[1] == "type" or perm[1] == "type":
            return
        if door[1] != "dynamic" and perm[1] != "dynamic":
            if DOOR_RE.match(door[0] or "") and PERM_RE.match(perm[0] or ""):
                pairs.append(f"{door[0]}|{perm[0]}")
            return
        if path.name not in PASS_THROUGH:
            unharvestable.append(f"{rel}:{at} fn={door[2].strip()} permission={perm[2].strip()}")

    # Object literals: fn and permission at the object's own level.
    stack = []
    for i, c in enumerate(src):
        if kind[i] != "c":
            continue
        if c == "{":
            stack.append(i)
        elif c == "}" and stack:
            start = stack.pop()
            text = depth1_text(src, kind, start, i)
            if "fn" not in text or "permission" not in text:
                continue
            found = {}
            for m in KV_RE.finditer(text):
                # depth1_text keeps one character per source character, so the
                # key's offset maps back; a key inside a comment is not a key.
                if m.group(1) in found or kind[start + 1 + m.start(1)] != "c":
                    continue
                value, how = resolve(m.group(2), m.group(3), consts)
                found[m.group(1)] = (value, how, m.group(0)[len(m.group(1)):].lstrip(" :\t"), m.start(1))
            if "fn" in found and "permission" in found:
                record(found["fn"], found["permission"], line_of(start + 1 + found["fn"][3]))

    # JSX opening tags: fn= and permission= at brace depth 0 of the tag.
    n = len(src)
    for m in TAG_RE.finditer(src):
        if kind[m.start()] != "c":
            continue
        i, depth, depths = m.end(), 0, {}
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
        found = {}
        for a in ATTR_RE.finditer(src, m.end(), i):
            if depths.get(a.start(), 1) != 0 or kind[a.start()] != "c" or a.group(1) in found:
                continue
            j = a.end()
            if j < n and src[j] == '"':
                k = src.find('"', j + 1)
                found[a.group(1)] = (src[j + 1:k], "literal", src[j:k + 1], a.start(1))
            elif j < n and src[j] == "{":
                d, k = 0, j
                while k < n:
                    if kind[k] == "c":
                        if src[k] == "{":
                            d += 1
                        elif src[k] == "}":
                            d -= 1
                            if d == 0:
                                break
                    k += 1
                inner = src[j + 1:k].strip()
                if re.fullmatch(r"[A-Za-z_$][\w$]*", inner):
                    value, how = resolve(None, inner, consts)
                elif re.fullmatch(r'"((?:[^"\\]|\\.)*)"', inner):
                    value, how = inner[1:-1], "literal"
                else:
                    value, how = None, "dynamic"
                found[a.group(1)] = (value, how, src[j:k + 1], a.start(1))
        if "fn" in found and "permission" in found:
            record(found["fn"], found["permission"], line_of(found["fn"][3]))

if unbalanced:
    # A file whose code braces do not balance was mis-tokenised, and an object
    # that never closes is an object never harvested. Say so and stop.
    print("app_gates.sh: code braces do not balance, so pairs may be lost:", file=sys.stderr)
    for u in unbalanced:
        print("  " + u, file=sys.stderr)
    sys.exit(2)
if unharvestable:
    print(f"app_gates.sh: {len(unharvestable)} declaration(s) read their permission from data and cannot be judged here:", file=sys.stderr)
    for u in unharvestable:
        print("  " + u, file=sys.stderr)
for p in sorted(set(pairs)):
    print(p)
PY
)

if [[ ${#pairs[@]} -eq 0 ]]; then
  echo "no (door, permission) pairs found under $SRC; that is the failure, not a pass" >&2
  exit 1
fi

list=$(printf "'%s'," "${pairs[@]}")
list="array[${list%,}]::text[]"
out=$($PSQL_CMD -tAc "select erp.assert_app_gates_match($list);")
echo "$out"
