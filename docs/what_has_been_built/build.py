#!/usr/bin/env python3
"""
Build docs/Clove_ERP_What_Has_Been_Built.docx from source.md and counts.json.

The document is an account of what the build contains, for a reader who will
not open a SQL client. It used to be written by hand and quoted the figures
of the day it was written; now it is generated from a Markdown source whose
figures are placeholders — {doors}, {migrations}, {part5_built} — filled from
counts.json, which docs/build_counts.sh writes from the built database.

    python3 docs/what_has_been_built/build.py           # (re)build the document
    python3 docs/what_has_been_built/build.py --check   # CI: rebuild and compare

The build is deterministic: the core properties carry a fixed date and author,
so two builds from the same source and counts are the same bytes, and --check
compares paragraph texts rather than bytes anyway, because a Word file also
carries the library version that wrote it.

Requires python-docx (pip install python-docx).
"""
import json
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

try:
    from docx import Document
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.shared import Pt
except ImportError:  # pragma: no cover
    print("python-docx is not installed: pip install python-docx", file=sys.stderr)
    sys.exit(2)

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SOURCE = HERE / "source.md"
COUNTS = HERE / "counts.json"
TARGET = ROOT / "docs" / "Clove_ERP_What_Has_Been_Built.docx"

FIXED_STAMP = datetime(2026, 9, 6, 12, 0, 0, tzinfo=timezone.utc)


def fill(text: str, counts: dict) -> str:
    def sub(m):
        key = m.group(1)
        if key not in counts:
            raise SystemExit(f"source.md names a figure counts.json does not hold: {key}")
        return str(counts[key])

    return re.sub(r"\{([a-z0-9_]+)\}", sub, text)


def add_runs(paragraph, text: str):
    """Bold for **…**, code for `…`; nothing else. The source is plain prose."""
    for part in re.split(r"(\*\*[^*]+\*\*|`[^`]+`)", text):
        if not part:
            continue
        if part.startswith("**"):
            paragraph.add_run(part[2:-2]).bold = True
        elif part.startswith("`"):
            run = paragraph.add_run(part[1:-1])
            run.font.name = "Consolas"
            run.font.size = Pt(9.5)
        else:
            paragraph.add_run(part)


def build(source: str, counts: dict) -> Document:
    doc = Document()
    style = doc.styles["Normal"]
    style.font.name = "Calibri"
    style.font.size = Pt(11)

    lines = fill(source, counts).splitlines()
    table_rows = []

    def flush_table():
        nonlocal table_rows
        rows = [r for r in table_rows if not re.match(r"^\s*\|?\s*-+", r)]
        if rows:
            cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
            width = max(len(c) for c in cells)
            table = doc.add_table(rows=0, cols=width)
            table.style = "Light Grid Accent 1"
            for i, row in enumerate(cells):
                tr = table.add_row().cells
                for j in range(width):
                    tr[j].text = ""
                    add_runs(tr[j].paragraphs[0], row[j] if j < len(row) else "")
                    if i == 0:
                        for run in tr[j].paragraphs[0].runs:
                            run.bold = True
            doc.add_paragraph()
        table_rows = []

    for line in lines:
        if line.startswith("|"):
            table_rows.append(line)
            continue
        if table_rows:
            flush_table()
        if not line.strip():
            continue
        m = re.match(r"^(#{1,3})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            if level == 1:
                p = doc.add_heading(m.group(2), level=0)
                p.alignment = WD_ALIGN_PARAGRAPH.LEFT
            else:
                doc.add_heading(m.group(2), level=level - 1)
            continue
        m = re.match(r"^[-*]\s+(.*)$", line)
        if m:
            add_runs(doc.add_paragraph(style="List Bullet"), m.group(1))
            continue
        m = re.match(r"^\d+\.\s+(.*)$", line)
        if m:
            add_runs(doc.add_paragraph(style="List Number"), m.group(1))
            continue
        add_runs(doc.add_paragraph(), line)
    if table_rows:
        flush_table()

    core = doc.core_properties
    core.author = "Clove ERP build"
    core.last_modified_by = "Clove ERP build"
    core.title = "Clove ERP — What has been built"
    core.subject = f"Specification {counts.get('spec_version', '')}, read from the built database"
    core.created = FIXED_STAMP
    core.modified = FIXED_STAMP
    core.revision = 1
    return doc


def paragraphs(path: Path) -> list[str]:
    d = Document(str(path))
    out = [p.text for p in d.paragraphs]
    for t in d.tables:
        for row in t.rows:
            out.append(" | ".join(c.text for c in row.cells))
    return out


def main(argv: list[str]) -> int:
    counts = json.loads(COUNTS.read_text())
    source = SOURCE.read_text()
    doc = build(source, counts)
    if "--check" in argv:
        with tempfile.NamedTemporaryFile(suffix=".docx", delete=False) as tmp:
            doc.save(tmp.name)
            fresh = paragraphs(Path(tmp.name))
        if not TARGET.exists():
            print(f"CLOVEERP_DOCUMENT_MISSING: {TARGET} is not committed; run build.py", file=sys.stderr)
            return 1
        held = paragraphs(TARGET)
        if fresh != held:
            diff = [(i, a, b) for i, (a, b) in enumerate(zip(held, fresh)) if a != b]
            for i, a, b in diff[:10]:
                print(f"paragraph {i}:\n  committed: {a[:120]}\n  rebuilt:   {b[:120]}", file=sys.stderr)
            if len(held) != len(fresh):
                print(f"committed has {len(held)} paragraphs, rebuilt has {len(fresh)}", file=sys.stderr)
            print("CLOVEERP_DOCUMENT_DRIFTED: the committed document does not match its source and counts; run build.py", file=sys.stderr)
            return 1
        print(f"document: {len(held)} paragraphs agree with the source and the database")
        return 0
    doc.save(str(TARGET))
    print(f"wrote {TARGET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
