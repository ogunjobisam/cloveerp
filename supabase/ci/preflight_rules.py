#!/usr/bin/env python3
"""The text half of supabase/ci/preflight.sh. Read that file first.

Nothing here connects to anything. It reads supabase/migrations and src, and
every rule it refuses on is the same arithmetic the database itself does — the
same substring erp.public_api_report() looks for, the same name patterns
erp.refusal_report() excludes, the same register erp.assert_doors_have_a_home()
reads. A rule that cannot be decided from the text advises and does not refuse.

Usage: preflight_rules.py <repo-root> <branch|named> <migration.sql> ...
"""

import pathlib
import re
import sys

# ─────────────────────────────────────────────────────────────────────────────
# A. The live singletons
#
# A live database has exactly one of each of these and refuses the second by
# design. A suite whose fixture stands up its own throwaway one therefore
# passes on every build — an empty cluster has none — and can never pass on a
# deploy. 20260919010000 ended by running erp_test.assert_commercial_renewal_suite(),
# whose fixture designates its own tenant as the platform's organisation; it was
# green on every build and the deploy died on it with
# CLOVEERP_PLATFORM_ORGANISATION_ALREADY_DESIGNATED and rolled back whole.
#
# This list is meant to grow. Add a routine here when a deploy proves that live
# already holds the thing it creates — not when one looks as though it might.
# A marker added on a hunch is how a check starts crying wolf.
# ─────────────────────────────────────────────────────────────────────────────
def _blank(argument):
    """An argument that says nothing: absent, empty, or null."""
    a = argument.strip().lower()
    return a in ("", "null", "''", "''::text")


LIVE_SINGLETONS = {
    "erp.designate_platform_organisation": {
        "what": "designates the platform's organisation. Live already has "
                "clove-erp, and designating a second without saying why refuses "
                "with CLOVEERP_PLATFORM_ORGANISATION_ALREADY_DESIGNATED",
        # It refuses only when asked to move in silence. The second argument is
        # the reason, and a designation that states one moves the row instead —
        # which is why most fixtures pass live and this one did not.
        "refuses": lambda args: len(args) < 2 or _blank(args[1]),
        "instead": "give the call a reason, if the suite really must designate",
    },
    "public.erp_platform_claim_ownership": {
        "what": "claims the platform's first owner. Live already has staff, and "
                "the second claim refuses with CLOVEERP_PLATFORM_ALREADY_OWNED",
        "refuses": lambda args: True,
        "instead": "insert the fixture's staff row directly, as the other suites do",
    },
}

# ─────────────────────────────────────────────────────────────────────────────
# B. What erp.refusal_report() can see
#
# It scrapes prosrc for `raise exception 'CLOVEERP_…'` across these schemas and
# skips any routine named assert_% or %_suite, because a refusal raised only by
# a test is not a refusal the product makes. erp_test is not in its list at all,
# and a DO block is not a routine, so neither counts as a raise.
# ─────────────────────────────────────────────────────────────────────────────
RAISING_SCHEMAS = ("erp", "erp_meta", "erp_ref", "erp_ai", "public")

# ─────────────────────────────────────────────────────────────────────────────
# G. What moves a total somebody wrote down
#
# Adding one of these moves a count that another suite asserts as a bare
# literal — "promotion installs five posting rules", "seven lifecycles across
# both modules". The literal is deliberate: it is the only thing in the build
# that says an installer now installs something it did not. Preflight cannot
# know the new number, so it names the places that carry the old one.
# ─────────────────────────────────────────────────────────────────────────────
COLLATERAL = {
    "erp.posting_rule": "a posting rule",
    "erp.state_machine": "a lifecycle",
    "erp.document_type": "a document type",
    "erp.close_task_template": "a close task",
    "erp_meta.entitlement_kind": "an entitlement kind",
}
# A module installer grows by a row in erp_ref.module_upgrade_item rather than
# by an insert into the table itself; the object_kind says which total moves.
UPGRADE_KINDS = {
    "posting_rule": "erp.posting_rule",
    "state_machine": "erp.state_machine",
    "document_type": "erp.document_type",
    "close_task": "erp.close_task_template",
}


# ═════════════════════════════════════════════════════════════════════════════
# Reading SQL
# ═════════════════════════════════════════════════════════════════════════════
#
# Every derived view of a file is the same length as the file, so an offset in
# one is an offset in all of them and a finding can always name a line.

_NEXT = re.compile(r"--|/\*|'|\"|\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$")
_FUNC_HEAD = re.compile(
    r"\bcreate\s+(?:or\s+replace\s+)?(?:function|procedure)\s+"
    r"([a-z_][a-z0-9_]*)\s*\.\s*([a-z_][a-z0-9_]*)\s*\(", re.I)
_ENDS_AS = re.compile(r"\bas\s*$", re.I)
_ENDS_DO = re.compile(r"\bdo\s*$", re.I)
_STRIP_COMMENTS = re.compile(r"--[^\n]*|/\*.*?\*/", re.S)
_NOT_NEWLINE = re.compile(r"[^\n]")
_TAIL = 8000


def blank_out(text, spans):
    """Replace each span with spaces, keeping newlines so offsets and lines hold."""
    if not spans:
        return text
    out, pos = [], 0
    for lo, hi in sorted(spans):
        lo = max(lo, pos)
        if hi <= lo:
            continue
        out.append(text[pos:lo])
        out.append(_NOT_NEWLINE.sub(" ", text[lo:hi]))
        pos = hi
    out.append(text[pos:])
    return "".join(out)


class Migration:
    """One .sql file, lexed once."""

    def __init__(self, path, text):
        self.path = path
        self.text = text
        self.comments = []      # spans
        self.strings = []       # spans of quoted literals
        self.literals = []      # spans of dollar-quoted literals
        self.bodies = []        # spans of routine bodies
        self.do_blocks = []     # spans of DO blocks the migration runs
        self.functions = []     # (schema, name, start, end)
        self._walk(0, len(text), top=True)

        self.nocomments = blank_out(text, self.comments)
        # Code: nothing a literal says counts as something the file does.
        self.blank = blank_out(self.nocomments, self.strings + self.literals)
        # What the migration itself executes — outside every routine body it
        # merely defines and every literal it merely quotes. A DO block is not
        # a body: the migration runs it.
        self.runs = blank_out(self.blank, self.bodies)
        self.runs_raw = blank_out(
            blank_out(self.nocomments, self.literals), self.bodies)

    def _walk(self, lo, hi, top):
        """Lex [lo, hi), recording comments, quoted strings and dollar regions."""
        text = self.text
        i = lo
        while i < hi:
            m = _NEXT.search(text, i, hi)
            if not m:
                break
            tok = m.group(0)
            if tok == "--":
                end = text.find("\n", m.start())
                end = hi if end < 0 or end > hi else end
                self.comments.append((m.start(), end))
                i = end
            elif tok == "/*":
                depth, j = 1, m.end()
                while j < hi and depth:
                    if text.startswith("/*", j):
                        depth += 1
                        j += 2
                    elif text.startswith("*/", j):
                        depth -= 1
                        j += 2
                    else:
                        j += 1
                self.comments.append((m.start(), j))
                i = j
            elif tok == "'":
                j = m.end()
                while j < hi:
                    if text[j] == "'":
                        if j + 1 < hi and text[j + 1] == "'":
                            j += 2
                            continue
                        j += 1
                        break
                    j += 1
                self.strings.append((m.start(), j))
                i = j
            elif tok == '"':
                j = text.find('"', m.end())
                j = hi if j < 0 or j >= hi else j + 1
                self.strings.append((m.start(), j))
                i = j
            else:
                close = text.find(tok, m.end())
                if close < 0 or close >= hi:
                    # An unterminated dollar quote is a syntax error, and the
                    # build reports it far better than this can. Stop reading.
                    break
                inner_lo, inner_hi, end = m.end(), close, close + len(tok)
                kind = self._classify(m.start()) if top else "literal"
                if kind == "body":
                    schema, name = self._head(m.start())
                    self.functions.append((schema, name, inner_lo, inner_hi))
                    self.bodies.append((inner_lo, inner_hi))
                    self._walk(inner_lo, inner_hi, top=False)
                elif kind == "do":
                    self.do_blocks.append((inner_lo, inner_hi))
                    self._walk(inner_lo, inner_hi, top=False)
                else:
                    self.literals.append((inner_lo, inner_hi))
                i = end

    def _tail(self, offset):
        window = self.text[max(0, offset - _TAIL):offset]
        return _STRIP_COMMENTS.sub(" ", window)

    def _classify(self, offset):
        tail = self._tail(offset)
        if _ENDS_AS.search(tail) and _FUNC_HEAD.search(tail):
            return "body"
        if _ENDS_DO.search(tail):
            return "do"
        return "literal"

    def _head(self, offset):
        last = None
        for last in _FUNC_HEAD.finditer(self._tail(offset)):
            pass
        return (last.group(1).lower(), last.group(2).lower()) if last else ("?", "?")

    def line_of(self, offset):
        return self.text.count("\n", 0, offset) + 1

    def body_raw(self, fn):
        return self.nocomments[fn[2]:fn[3]]

    def body_code(self, fn):
        return self.blank[fn[2]:fn[3]]


# ═════════════════════════════════════════════════════════════════════════════
# The repository, read once
# ═════════════════════════════════════════════════════════════════════════════

class Repo:
    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.files = sorted((self.root / "supabase" / "migrations").glob("*.sql"))
        self.migrations = {}
        for p in self.files:
            self.migrations[p] = Migration(p, p.read_text(errors="replace"))

        # Every definition of every routine, in the order they are applied:
        # migrations run in filename order and CREATE OR REPLACE is the last
        # word, so the question is always "the last definition before this one".
        self.history = {}           # (schema, name) -> [(filename, Migration, fn)]
        for p in self.files:
            mig = self.migrations[p]
            for fn in mig.functions:
                self.history.setdefault((fn[0], fn[1]), []).append((p.name, mig, fn))
        self.routines = {k: (v[-1][1], v[-1][2]) for k, v in self.history.items()}

    def read(self, path):
        p = pathlib.Path(path)
        if p in self.migrations:
            return self.migrations[p]
        mig = Migration(p, p.read_text(errors="replace"))
        self.migrations[p] = mig
        return mig

    def routine_at(self, key, target):
        """The definition of a routine as of `target` — the migration's own first."""
        for fn in target.functions:
            if (fn[0], fn[1]) == key:
                return target, fn
        name = target.path.name
        found = None
        for filename, mig, fn in self.history.get(key, []):
            if filename <= name:
                found = (mig, fn)
        return found

    def earlier_or_same(self, target):
        """Every migration applied no later than this one."""
        name = pathlib.Path(target).name
        return [self.migrations[p] for p in self.files if p.name <= name]

    def all_migrations(self, target):
        """Every migration in the repository, and the one being checked.

        The registers — the write allow-list, erp_meta.api_only_door — are read
        by whole-schema assertions at the end of the build, not statement by
        statement, so a door registered by a later migration on the same branch
        is registered. Order matters for erp_meta.add_help_actions(), which
        refuses there and then; it does not matter here.
        """
        out = [self.migrations[p] for p in self.files]
        if target not in out:
            out.append(target)
        return out

    def app_doors(self):
        """Every erp_* name the application quotes, as app_doors.sh extracts it."""
        if getattr(self, "_doors", None) is not None:
            return self._doors
        doors = set()
        src = self.root / "src"
        if not src.is_dir():
            self._doors = doors
            return doors
        pat = re.compile(r'"(erp_[a-z0-9_]+)"')
        for p in src.rglob("*"):
            if p.suffix not in (".ts", ".tsx"):
                continue
            if p.name.endswith((".test.ts", ".test.tsx")):
                continue
            if "integrations" in p.parts:
                continue
            doors.update(pat.findall(p.read_text(errors="replace")))
        self._doors = doors
        return doors


# ═════════════════════════════════════════════════════════════════════════════
# Findings
# ═════════════════════════════════════════════════════════════════════════════

class Report:
    def __init__(self):
        self.failed = False
        self.warned = False

    def refuse(self, rule, where, headline, lines):
        self.failed = True
        print(f"✗ {where}: {headline}", file=sys.stderr)
        for line in lines:
            print(f"  {line}", file=sys.stderr)
        print(f"  (preflight rule {rule})", file=sys.stderr)
        print("", file=sys.stderr)

    def advise(self, rule, where, headline, lines):
        self.warned = True
        print(f"! {where}: {headline}")
        for line in lines:
            print(f"    {line}")
        print(f"    (preflight rule {rule}, advisory — this does not fail)")
        print("")


REPORT = Report()


def at(mig, offset):
    return f"{mig.path.name}:{mig.line_of(offset)}"


# ═════════════════════════════════════════════════════════════════════════════
# A — a migration must not run a suite that needs to be alone in the world
# ═════════════════════════════════════════════════════════════════════════════

_ASSERT_CALL = re.compile(r"\berp_test\s*\.\s*(assert_[a-z0-9_]+)\s*\(")
_TEST_CALL = re.compile(r"\berp_test\s*\.\s*([a-z0-9_]+)\s*\(")


def rule_a(repo, mig):
    for m in _ASSERT_CALL.finditer(mig.runs):
        entry = m.group(1)
        hit = reaches_singleton(repo, mig, entry)
        if not hit:
            continue
        chain, marker, where = hit
        spec = LIVE_SINGLETONS[marker]
        REPORT.refuse(
            "A", at(mig, m.start()),
            f"this migration runs erp_test.{entry}(), and that fixture "
            f"calls {marker}",
            [
                "  " + " → ".join(f"erp_test.{c}()" for c in chain)
                + f" → {marker}()   ({where})",
                f"{marker} {spec['what']}.",
                "An empty CI database has none of it, so the suite passes on every",
                "build. A live database has one, so it refuses, and the migration",
                "rolls back whole on the deploy — after the build has said yes.",
                "The suite itself is fine and does not need changing: it is in",
                "erp.ci_check_catalogue() and runs on every build already, which is",
                "where a fixture that must be the only one of its kind belongs.",
                f"Delete the call from the migration (or {spec['instead']}).",
                "A migration runs only what a live database can answer.",
            ])


def reaches_singleton(repo, target, entry, depth=6):
    """Walk the fixture from its wrapper. Returns (chain, marker, where) or None."""
    queue = [(entry, [entry])]
    seen = set()
    while queue:
        name, chain = queue.pop(0)
        if name in seen or len(chain) > depth:
            continue
        seen.add(name)
        found = repo.routine_at(("erp_test", name), target)
        if not found:
            continue
        mig, fn = found
        code, raw = mig.body_code(fn), mig.body_raw(fn)
        for marker, spec in LIVE_SINGLETONS.items():
            for pos in call_sites(code, marker):
                if spec["refuses"](call_args(code, raw, pos)):
                    return chain, marker, at(mig, fn[2] + pos)
        for m in _TEST_CALL.finditer(code):
            queue.append((m.group(1), chain + [m.group(1)]))
    return None


def call_sites(code, name):
    """Offsets of the '(' of every call to `name` in code."""
    needle, out, i = name + "(", [], 0
    while True:
        i = code.find(needle, i)
        if i < 0:
            return out
        out.append(i + len(name))
        i += len(needle)


def call_args(code, raw, open_paren):
    """The arguments of the call whose '(' sits at open_paren, as written."""
    args, depth, seg, i, n = [], 0, open_paren + 1, open_paren + 1, len(code)
    while i < n:
        c = code[i]
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                args.append(raw[seg:i])
                break
            depth -= 1
        elif c == "," and depth == 0:
            args.append(raw[seg:i])
            seg = i + 1
        i += 1
    return args


# ═════════════════════════════════════════════════════════════════════════════
# B — a registered refusal must be raised where the register can see it
# ═════════════════════════════════════════════════════════════════════════════

_REGISTER = re.compile(r"\berp\s*\.\s*register_refusal\s*\(\s*'([A-Z0-9_%]+)'")


def rule_b(repo, mig):
    codes = []
    for m in _REGISTER.finditer(mig.runs_raw):
        codes.append((m.group(1), m.start()))
    if not codes:
        return
    raisers = refusal_raisers(repo)
    for code, offset in codes:
        if code in raisers:
            continue
        where_else = test_only_raisers(repo, code)
        detail = [
            "erp.refusal_report() scrapes the source of every routine in",
            "erp, erp_meta, erp_ref, erp_ai and public for the literal, and skips",
            "any routine named assert_% or %_suite. A DO block is not a routine and",
            "does not count either. A code registered and raised nowhere it can see",
            "reads as \"a registered refusal is raised nowhere\", and",
            "erp.assert_refusals_name_next_action() fails the build on it.",
        ]
        if where_else:
            detail.insert(0, "The only raises are in " + ", ".join(sorted(where_else)) + ".")
        detail.append(
            "Raise it by literal from the routine that refuses — not from the suite")
        detail.append(
            "that proves it refuses — or take the registration out.")
        REPORT.refuse(
            "B", at(mig, offset),
            f"this migration registers {code}, and no routine the register "
            f"reads raises it",
            detail)


# Refusals said ERPWARE_ until 20260904980000 swept every routine to CLOVEERP_.
# Both are read, so a register written before the sweep still resolves.
_PREFIX = r"(?:CLOVEERP|ERPWARE)_"
_RAISE_LITERAL = re.compile(r"raise\s+exception\s+E?'(" + _PREFIX + r"[A-Z0-9_%]+)", re.I)
_RAISE = re.compile(r"raise\s+exception\b", re.I)
_CODE = re.compile(r"\b(" + _PREFIX + r"[A-Z0-9_]+)")


def refusal_raisers(repo):
    """Every code raised somewhere erp.refusal_report() will read it.

    Two shapes. The plain one is a `raise exception 'CLOVEERP_…'` written into
    the body of a routine the report looks at — erp, erp_meta, erp_ref, erp_ai
    or public, and not named assert_% or %_suite.

    The other is a needle: a migration reads a deployed routine with
    pg_get_functiondef(), splices a new refusal into the text, and executes the
    result. The raise is then inside a quoted literal in the migration and in
    no routine body here — but it is in prosrc on every database that applied
    it, which is what the report reads. Counting it is not a loophole: missing
    it would fail a migration for a refusal that is raised.
    """
    if getattr(repo, "_raisers", None) is not None:
        return repo._raisers
    out = set()
    for (schema, name), (mig, fn) in repo.routines.items():
        if schema not in RAISING_SCHEMAS:
            continue
        if name.startswith("assert_") or name.endswith("_suite"):
            continue
        out.update(_RAISE_LITERAL.findall(mig.body_raw(fn)))

    for path in repo.files:
        mig = repo.migrations[path]
        quoted = sorted(mig.strings + mig.literals)
        tests = test_body_spans(mig)
        for m in _RAISE.finditer(mig.nocomments):
            if not inside(quoted, m.start()) or inside(tests, m.start()):
                continue
            # A needle is built by concatenation, so `raise exception` and the
            # code it raises are often in neighbouring literals. Read on.
            out.update(_CODE.findall(mig.nocomments[m.end():m.end() + 300]))
    repo._raisers = out
    return out


def inside(spans, offset):
    for lo, hi in spans:
        if lo <= offset < hi:
            return True
        if lo > offset:
            return False
    return False


def test_body_spans(mig):
    return sorted((fn[2], fn[3]) for fn in mig.functions
                  if fn[1].startswith("assert_") or fn[1].endswith("_suite"))


def test_only_raisers(repo, code):
    pat = re.compile(r"raise\s+exception\s+E?'" + re.escape(code) + r"\b", re.I)
    out = set()
    for (schema, name), (mig, fn) in repo.routines.items():
        if pat.search(mig.body_raw(fn)):
            out.add(f"{schema}.{name}()")
    return out


# ═════════════════════════════════════════════════════════════════════════════
# C — a public write door must call the gate it declares
# ═════════════════════════════════════════════════════════════════════════════
#
# erp.public_api_report() asks, in so many words, whether the door's own prosrc
# contains `gate || '('`. It is a substring test and nothing more, so this is
# the same substring test. A door that delegates must name the delegate the way
# public.erp_firm_planned_order names erp.firm_planned_order.

_ALLOWANCE = re.compile(
    r"insert\s+into\s+erp_meta\s*\.\s*public_write_allowance\s*\(([^)]*)\)\s*values\b", re.I)
_ALLOWANCE_DELETE = re.compile(
    r"delete\s+from\s+erp_meta\s*\.\s*public_write_allowance\s+where\s+function_name\s*=\s*'([a-z0-9_]+)'",
    re.I)


def rule_c(repo, mig):
    for cols, rows, offset in allowance_rows(mig):
        try:
            i_fn, i_gate = cols.index("function_name"), cols.index("gate")
        except ValueError:
            continue
        for row in rows:
            if len(row) <= max(i_fn, i_gate):
                continue
            door, gate = row[i_fn], row[i_gate]
            if door is None or gate is None:
                continue
            if not repo.history.get(("public", door)) and not any(
                    (fn[0], fn[1]) == ("public", door) for fn in mig.functions):
                REPORT.refuse(
                    "C", at(mig, offset),
                    f"the write allow-list names public.{door}, and no migration "
                    f"creates it",
                    ["erp.public_api_report() calls this \"a write allow-list entry names",
                     "no function\": nothing is being permitted, and nothing is being",
                     "checked. Create the door, or drop the row."])
                continue
            written = [fn for fn in mig.functions if (fn[0], fn[1]) == ("public", door)]
            if not written:
                # The migration registers a door it does not write. Whether that
                # body calls the gate is between the door and
                # erp.public_api_report(); this rule judges what is in front of
                # it. A door patched by needle is written here in a sense — the
                # DO block that splices the gate in carries both names — and is
                # answered the same way.
                continue
            if any(gate + "(" in mig.body_raw(fn) for fn in written):
                continue
            if needles_gate(mig, door, gate):
                continue
            REPORT.refuse(
                "C", at(mig, offset),
                f"public.{door} is registered as gated by {gate}, and the body "
                f"this migration writes never calls it",
                [f"The door is written at {at(mig, written[-1][2])}.",
                 "erp.public_api_report() looks for the literal text",
                 f"\"{gate}(\" in the door's own source and finds nothing, so the build",
                 "refuses with \"a public API write function does not call its declared",
                 "gate\". A door that delegates must name the delegate — the way",
                 "public.erp_firm_planned_order names erp.firm_planned_order.",
                 "Either call the gate, or register the function the door actually calls."])


def needles_gate(mig, door, gate):
    """A door whose gate is spliced into a deployed body by a DO block."""
    for lo, hi in mig.do_blocks:
        block = mig.nocomments[lo:hi]
        if door in block and gate + "(" in block:
            return True
    return False


def allowance_rows(mig):
    """Every (columns, rows, offset) an insert into the allow-list carries."""
    out = []
    for m in _ALLOWANCE.finditer(mig.runs_raw):
        cols = [c.strip().lower() for c in m.group(1).split(",")]
        out.append((cols, tuple_values(mig.runs_raw, m.end()), m.start()))
    return out


def tuple_values(text, start):
    """The VALUES tuples after `start`, as lists of literals (None when not one)."""
    rows, i, n = [], start, len(text)
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n or text[i] != "(":
            break
        i, row, depth, cur = i + 1, [], 0, ""
        while i < n:
            c = text[i]
            if c == "'":
                j = i + 1
                while j < n:
                    if text[j] == "'":
                        if j + 1 < n and text[j + 1] == "'":
                            j += 2
                            continue
                        break
                    j += 1
                cur += text[i:j + 1]
                i = j + 1
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    row.append(cur)
                    i += 1
                    break
                depth -= 1
            elif c == "," and depth == 0:
                row.append(cur)
                cur = ""
                i += 1
                continue
            cur += c
            i += 1
        rows.append([as_literal(v) for v in row])
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i < n and text[i] == ",":
            i += 1
            continue
        break
    return rows


def as_literal(value):
    v = value.strip()
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("''", "'")
    return None


# ═════════════════════════════════════════════════════════════════════════════
# D — help actions need a help topic
# ═════════════════════════════════════════════════════════════════════════════

_ADD_HELP = re.compile(r"\berp_meta\s*\.\s*add_help_actions\s*\(\s*'([^']*)'")
_HELP_INSERT = re.compile(r"insert\s+into\s+erp_ref\s*\.\s*help_topic\b", re.I)


def rule_d(repo, mig):
    calls = [(m.group(1), m.start()) for m in _ADD_HELP.finditer(mig.runs_raw)]
    if not calls:
        return
    for path, offset in calls:
        if path in help_topics(repo, mig, offset):
            continue
        REPORT.refuse(
            "D", at(mig, offset),
            f"add_help_actions('{path}') has no help topic to add to",
            ["erp_meta.add_help_actions() updates erp_ref.help_topic by screen_path",
             "and raises CLOVEERP_NO_HELP_TOPIC when the update finds no row. No",
             "migration up to and including this one inserts a topic for that path,",
             "so the statement refuses and the migration rolls back whole.",
             "Insert the topic first — screen_path, nav_key, module_code, summary,",
             "steps and next_action — in this migration, above the call."])


def help_topics(repo, target, before):
    """Every screen_path a topic exists for by the time this call runs.

    Order matters here in a way it does not for the registers: the call updates
    a row and raises there and then if it finds none, so a topic inserted below
    it in the same file is a topic that does not exist yet.
    """
    if getattr(repo, "_topics", None) is None:
        repo._topics = {p.name: topic_paths(repo.migrations[p]) for p in repo.files}
    paths = set()
    for name, found in repo._topics.items():
        if name < target.path.name:
            paths |= found
    return paths | topic_paths(target, before)


def topic_paths(mig, before=None):
    """The screen paths an insert into erp_ref.help_topic names.

    Every quoted path in the statement, not just the screen_path column: a
    summary that happens to quote a path can only make this rule quieter, and
    this rule speaks only when nothing anywhere has the topic.
    """
    out = set()
    for m in _HELP_INSERT.finditer(mig.runs_raw):
        if before is not None and m.start() > before:
            continue
        out.update(re.findall(r"'(/[A-Za-z0-9_/\-]*)'",
                              statement_at(mig.runs_raw, m.start())))
    return out


def statement_at(text, start):
    """From `start` to the semicolon that ends the statement, skipping literals."""
    i, n = start, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            i = j + 1
            continue
        if c == ";":
            return text[start:i]
        i += 1
    return text[start:]


# ═════════════════════════════════════════════════════════════════════════════
# F — a new public door needs its allowance and a home
# ═════════════════════════════════════════════════════════════════════════════

_NOT_VOLATILE = re.compile(r"\b(stable|immutable)\b", re.I)


def rule_f(repo, mig):
    doors = [fn for fn in mig.functions
             if fn[0] == "public" and fn[1].startswith("erp_")]
    if not doors:
        return
    allowed = allowance_names(repo, mig)
    registered = api_only_names(repo, mig)
    named_by_app = repo.app_doors()

    for fn in doors:
        schema, name, bstart, _ = fn
        header = header_of(mig, bstart)
        volatile = not _NOT_VOLATILE.search(header)
        if volatile and name not in allowed:
            REPORT.refuse(
                "F", at(mig, bstart),
                f"public.{name} is VOLATILE and is on no write allow-list",
                ["A public door that is not declared STABLE or IMMUTABLE may write,",
                 "and erp.assert_public_api_safe() refuses one that is not registered:",
                 "\"a public API function writes but is not on the write allow-list\".",
                 "Add a row to erp_meta.public_write_allowance naming the door, the",
                 "gate its body calls, and why it may write — or declare it STABLE."])
        if name not in named_by_app and name not in registered:
            REPORT.refuse(
                "F", at(mig, bstart),
                f"public.{name} is named by no screen and registered for no caller",
                ["supabase/ci/app_doors.sh takes every \"erp_*\" literal out of src and",
                 "hands the list to erp.assert_doors_have_a_home(), which refuses a door",
                 "with neither: CLOVEERP_DOOR_HAS_NO_HOME. A door nobody can reach is a",
                 "capability the product claims and does not have.",
                 "Name it from a screen in src, or add a row to erp_meta.api_only_door",
                 "saying who calls it and why (caller 'pending_screen' with the intended",
                 "path is allowed, and says so on the console)."])


def header_of(mig, bstart):
    """The text between `create … function` and the body it opens."""
    window = mig.blank[max(0, bstart - 8000):bstart]
    last = None
    for last in _FUNC_HEAD.finditer(window):
        pass
    return window[last.start():] if last else window[-400:]


# Registering a door is not always a VALUES list — one migration registers
# three platform reads with `insert … select v.fn from (values …) as v(fn)`.
# For "is this door registered at all" the question is only whether the
# statement names it, so read every erp_* literal in the statement. Generous on
# purpose: this decides whether to stay silent, and a door read as registered
# when it is not is caught by the build, while the reverse is a check crying
# wolf at a door that is registered perfectly well.
_INSERT_ALLOWANCE = re.compile(
    r"insert\s+into\s+erp_meta\s*\.\s*public_write_allowance\b", re.I)
_INSERT_API_ONLY = re.compile(
    r"insert\s+into\s+erp_meta\s*\.\s*api_only_door\b", re.I)
_DOOR_LITERAL = re.compile(r"'(erp_[a-z0-9_]+)'")


def registered_names(repo, target, opener, remover=None):
    """Every door registered, reading each migration in the order it runs.

    One migration drops a door and its row and then re-registers the new
    signature forty lines later, so a pass that removed after it added would
    read that door as unregistered for ever.
    """
    names = set()
    for mig in repo.all_migrations(target):
        events = []
        for m in opener.finditer(mig.runs_raw):
            stmt = statement_at(mig.runs_raw, m.start())
            events.append((m.start(), "add", _DOOR_LITERAL.findall(stmt)))
        if remover:
            for m in remover.finditer(mig.runs_raw):
                events.append((m.start(), "remove", [m.group(1)]))
        for _, kind, doors in sorted(events):
            if kind == "add":
                names.update(doors)
            else:
                names.difference_update(doors)
    return names


def allowance_names(repo, target):
    return registered_names(repo, target, _INSERT_ALLOWANCE, _ALLOWANCE_DELETE)


def api_only_names(repo, target):
    return registered_names(repo, target, _INSERT_API_ONLY)


# ═════════════════════════════════════════════════════════════════════════════
# G — advisory: collateral counts
# ═════════════════════════════════════════════════════════════════════════════

_UPGRADE_ITEM = re.compile(
    r"insert\s+into\s+erp_ref\s*\.\s*module_upgrade_item\b", re.I)


def rule_g(repo, mig):
    moved = {}
    for rel, what in COLLATERAL.items():
        if re.search(r"insert\s+into\s+" + rel.replace(".", r"\s*\.\s*") + r"\b",
                     mig.runs_raw, re.I):
            moved[rel] = what
    for m in _UPGRADE_ITEM.finditer(mig.runs_raw):
        stmt = statement_at(mig.runs_raw, m.start())
        for kind, rel in UPGRADE_KINDS.items():
            if f"'{kind}'" in stmt and rel in COLLATERAL:
                moved[rel] = COLLATERAL[rel]
    if not moved:
        return
    for rel, what in sorted(moved.items()):
        places = literal_totals(repo, rel)
        if not places:
            continue
        lines = [
            f"Every one of these asserts a total over {rel} as a bare literal. A",
            "literal is the point — it is the only thing in the build that says an",
            "installer now installs something it did not — so the number moves and",
            "the sentence beside it says what the extra one is. Restate them here,",
            "in this migration, rather than finding out in forty minutes:",
        ]
        for routine, where, literal, phrase in places:
            lines.append(f"  {routine} — = {literal}   ({where})")
            if phrase:
                lines.append(f"      {phrase}")
        lines.append("This cannot know the new number, which is why it does not fail.")
        REPORT.advise("G", mig.path.name, f"this migration adds {what}", lines)


_COUNT_LITERAL = re.compile(
    r"count\s*\(\s*\*\s*\)\s*(?:from|FROM)\s+(REL)\b[^;]{0,400}?"
    r"(?:=|<>)\s*(\d+)")
# The sentence beside the number, which is what a reader recognises. One
# line only: a literal that runs over a newline is a body of prose, not a
# case name.
_PHRASE = re.compile(r"'([^'\n]{8,110})'")


def literal_totals(repo, rel):
    """Every place that counts `rel` against a literal, latest wording last."""
    pat = re.compile(_COUNT_LITERAL.pattern.replace(
        "REL", rel.replace(".", r"\s*\.\s*")), re.I | re.S)
    found = {}
    for path in repo.files:
        mig = repo.migrations[path]
        for m in pat.finditer(mig.nocomments):
            routine = (enclosing(mig, m.start())
                       or f"a DO block in {mig.path.name}")
            before = mig.nocomments[max(0, m.start() - 300):m.start()]
            phrases = _PHRASE.findall(before)
            found[routine] = (routine, at(mig, m.start()), m.group(2),
                              phrases[-1] if phrases else "")
    return sorted(found.values())


def enclosing(mig, offset):
    for schema, name, start, end in mig.functions:
        if start <= offset < end:
            return f"{schema}.{name}"
    return None


# ═════════════════════════════════════════════════════════════════════════════
# H — advisory: a suite's count guard must print its captured fixture error
# ═════════════════════════════════════════════════════════════════════════════
#
# A suite wraps its fixture in `exception when others then` and catches the
# message into a variable so the rollback still reports rows. If the fixture
# stops early the wrapper sees fewer cases than it expects and raises SHRANK —
# and if that raise does not print the captured message, the one thing that
# says WHERE the fixture stopped never reaches the build log, and the next
# diagnosis costs a whole run.

# The fixture's own handler, not a case's. A suite proves a refusal by catching
# it into a variable a dozen times over, and those are not this; the outer one
# is the handler that swallows the rollback sentinel the fixture raises to undo
# itself, and the message it keeps is the one that says where the fixture
# stopped.
_UNDO_RAISE = re.compile(r"raise\s+exception\s+E?'[A-Z0-9_]*_UNDO'", re.I)
_CAPTURE = re.compile(r"\b(v_[a-z0-9_]+)\s*:=[^;]{0,240}?\bsqlerrm\b", re.I)
_RAISE_HERE = re.compile(r"raise\s+exception\b", re.I)


def rule_h(repo, mig):
    for fn in mig.functions:
        schema, name, _, _ = fn
        if schema != "erp_test" or not name.endswith("_suite"):
            continue
        if name.startswith("assert_"):
            continue
        raw = mig.body_raw(fn)
        code = mig.body_code(fn)
        captured = None
        for m in _UNDO_RAISE.finditer(raw):
            c = _CAPTURE.search(raw, m.end(), m.end() + 900)
            if c:
                captured = c.group(1)
                break
        if not captured:
            continue

        guards = []
        for m in _RAISE_HERE.finditer(code):
            stmt = statement_at(raw, m.start())
            if "SHRANK" in stmt.upper():
                guards.append(stmt)
        if any(captured in g for g in guards):
            continue

        if not guards:
            headline = (f"erp_test.{name}() keeps its fixture error in {captured} "
                        f"and has no count guard of its own")
            tail = ["Add one. The wrapper's guard sees only a count, so a fixture that",
                    "stopped early is reported as a number with no reason beside it."]
        else:
            headline = f"erp_test.{name}()'s count guard does not print {captured}"
            tail = [f"Add {captured} to the raise — \"… expected %; the fixture stopped %\" —",
                    "the way erp_test.supplier_return_suite() does. The suite already",
                    "knows what went wrong and throws it away."]
        REPORT.advise(
            "H", mig.path.name, headline,
            ["A fixture that breaks half way returns fewer cases than the wrapper",
             "expects, and the wrapper raises SHRANK. If the count guard does not",
             "print the message the suite caught, the build log says only that the",
             "count is wrong, and finding out why costs another forty minutes."] + tail)


# ═════════════════════════════════════════════════════════════════════════════

def main():
    root, mode, targets = sys.argv[1], sys.argv[2], sys.argv[3:]
    repo = Repo(root)
    checked = 0
    for t in targets:
        p = pathlib.Path(t)
        if not p.exists():
            print(f"preflight: {t} does not exist", file=sys.stderr)
            return 1
        mig = repo.read(p)
        checked += 1
        rule_a(repo, mig)
        rule_b(repo, mig)
        rule_c(repo, mig)
        rule_d(repo, mig)
        rule_f(repo, mig)
        rule_g(repo, mig)
        rule_h(repo, mig)

    if REPORT.failed:
        print("", file=sys.stderr)
        print("Every rule above is something the build refuses and nothing catches",
              file=sys.stderr)
        print("sooner. Fixing it here costs a minute; finding it there costs an hour.",
              file=sys.stderr)
        return 1

    word = "migration" if checked == 1 else "migrations"
    suffix = " (with advice above)" if REPORT.warned else ""
    print(f"preflight: {checked} {word} checked, "
          f"nothing the build refuses is in them{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
