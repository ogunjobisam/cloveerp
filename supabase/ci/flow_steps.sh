#!/usr/bin/env bash
#
# Every cycle costs the number of actions it declares.
#
# Rule 8 of the flow doctrine says each cycle declares the most user actions its
# happy path may cost, and that adding a step means raising the declared number
# in the same change, in the open, with a reason. Nothing declared anything of
# the sort, and nothing counted: the count on a step of a process strip is the
# backlog sitting at that step, read live, and has never had anything to do with
# how many times a person presses a button to get through a cycle.
#
# So this counts. A cycle's cost is the number of DISTINCT VERBS its strip
# offers — the actionFn, the actionFns and the createFn of each of its steps —
# and that is what a person presses. The strips are the eight FlowSpec
# declarations in src: six on module definitions in src/lib/modules.tsx, and
# PURCHASE_TO_PAY and ORDER_TO_CASH beside their routes.
#
# What is read is a declaration and not prose: a cycle's own `code`, its verbs
# by function name, how many steps it has, and how many of those steps keep no
# list of their own. No label, hint, note or title is looked at, so rewording a
# screen couples nothing to this and a branch that renames a step does not break
# a branch that does not. That distinction is why the cycle carries a `code`.
#
# The list goes to erp.assert_flow_step_budgets(), which refuses a cycle over
# its declared budget and a declaration that has drifted from the screens in
# either direction — a strip that gained a verb the register does not know
# about, and a register row for a cycle the screens no longer draw.
#
# Reading a declaration across the lines it is written on is beyond grep, so the
# reading is Python, as supabase/ci/app_columns.sh's and app_gates.sh's are. It
# reads the repository and nothing else.
#
# Usage: supabase/ci/flow_steps.sh [src-dir]   (default: src beside this repo)
# Reads PSQL from the environment like run_checks.sh. Prints the count.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$here/src}"

mapfile -t rows < <(SRC="$SRC" python3 <<'PY'
import os
import pathlib
import re
import sys

SRC = pathlib.Path(os.environ["SRC"])

# A flow is declared either as a named constant beside its route, or inline on
# a module definition. Both open a brace; the brace is what is matched, because
# the contents run over many lines and nest.
OPENER = re.compile(r"const\s+[A-Za-z_0-9]+\s*:\s*FlowSpec\s*=\s*\{|\bflow\s*:\s*\{")
CODE = re.compile(r'\bcode:\s*"([^"]*)"')
VERB = re.compile(r'\b(?:actionFn|createFn):\s*"([^"]*)"')
VERBS = re.compile(r"\bactionFns:\s*\[([^\]]*)\]")
COUNTS = re.compile(r'\btypeCode:\s*"|\blist:\s*[A-Za-z{]')


def closing(text, start):
    """The index of the brace that closes the one opening at `start`."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return len(text) - 1


def steps_of(block):
    """Each step object of a flow, as text, without descending into its parts.

    A step carries nested objects of its own — a list's args, a picker's
    options — and a scan that does not skip past a step it has already taken
    reads those as further steps. The last reading of these files did exactly
    that and reported nine steps on a strip that draws five.
    """
    array = block.index("[", block.index("stages:"))
    out, i = [], array + 1
    while i < len(block):
        if block[i] == "]":
            break
        if block[i] == "{":
            end = closing(block, i)
            out.append(block[i:end + 1])
            i = end + 1
            continue
        i += 1
    return out


found, unnamed = [], []
for path in sorted(list(SRC.rglob("*.tsx")) + list(SRC.rglob("*.ts"))):
    if path.name.endswith(".test.ts") or path.name.endswith(".test.tsx"):
        continue
    text = path.read_text()
    rel = str(path.relative_to(SRC.parent))
    for m in OPENER.finditer(text):
        open_at = text.index("{", m.start())
        block = text[open_at:closing(text, open_at) + 1]
        if "stages:" not in block:
            continue
        code = CODE.search(block)
        if code is None:
            unnamed.append(rel)
            continue
        steps = steps_of(block)
        verbs, no_list = set(), 0
        for step in steps:
            if COUNTS.search(step) is None:
                no_list += 1
            verbs.update(VERB.findall(step))
            for group in VERBS.findall(step):
                verbs.update(v.strip().strip('"') for v in group.split(",") if v.strip())
        found.append((code.group(1), len(verbs), len(steps), no_list))

if unnamed:
    print("flow_steps.sh: %d process strip(s) declare no cycle code, so no budget can "
          "belong to them: %s" % (len(unnamed), ", ".join(sorted(set(unnamed)))),
          file=sys.stderr)
    sys.exit(1)

for code, verbs, steps, no_list in sorted(found):
    print("%s|%d|%d|%d" % (code, verbs, steps, no_list))
PY
)

if [[ ${#rows[@]} -eq 0 ]]; then
  echo "no process strip found under $SRC; that is the failure, not a pass" >&2
  exit 1
fi

list=$(printf "'%s'," "${rows[@]}")
list="array[${list%,}]::text[]"
out=$($PSQL_CMD -tAc "select erp.assert_flow_step_budgets($list);")
echo "$out"
