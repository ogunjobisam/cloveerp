# The specification this codebase implements

`ERPWare_Foundation_Specification_v1.2.pdf` is the version of record — a tenant-neutral
ERP platform, 1 September 2026, 38 pages, Parts 1 to 19.

The `.txt` beside it is a page-marked text extraction of the same file
(`<<<PAGE n>>>` separators). It exists so that the next revision can be **diffed**
rather than re-read: a 38-page PDF is not reviewable by eye for what changed, and
"which clauses moved" is the first question any spec update has to answer.

Regenerate the extraction with:

```bash
python3 - <<'PY'
import pdfplumber
src = "docs/spec/ERPWare_Foundation_Specification_v1.2.pdf"
with pdfplumber.open(src) as pdf:
    open(src[:-4] + ".txt", "w").write(
        "".join(f"\n<<<PAGE {i}>>>\n{p.extract_text() or ''}"
                for i, p in enumerate(pdf.pages, 1)))
PY
```

## How the codebase tracks it

Not by a version string — by content, in registers that assertions read. That is the
house pattern: a register states what the specification requires, a generator or a
report derives behaviour from it, and an assertion fails the build when the two
disagree. So "does the code still match the specification" is a query, not a review.

The registers that carry specification content directly:

| register | holds | count at v1.2 |
|---|---|---|
| `erp_ref.part5_capability` | every capability Part 5 names, in the specification's own words | 90 |
| `erp_ref.acceptance_clause` | the seven things §12.13 says a new organisation can do unaided | 7 |
| `erp_ref.capability` | the capability switches of §12.2 | 28 |
| `erp_ref.content_pack` | the base and profile packs of §12 | 8 |
| `erp_ref.vocabulary` | the starter vocabularies of §12.4 | 49 |
| `erp_ref.output_block_kind` | the output block kinds of Part 15 | 12 |

Their assertions: `erp.assert_part5_coverage()`, `erp_test.assert_starter_pack_acceptance()`,
`erp.assert_capabilities_sound()`, `erp.assert_packs_installable()`,
`erp.assert_starter_vocabularies_sound()`, `erp.assert_output_templates_sound()`.

## When a new revision arrives

1. Add the PDF here and extract its text with the snippet above.
2. `diff` the two extractions. That is the change list, and it is the only honest one.
3. For each changed clause, find the register row that carries it. A specification
   change that does not land in a register is a change the assertions cannot police,
   which is the failure mode this layout exists to prevent.
4. Update the register, let the generator and assertion disagree, and fix what they
   name. Do not update behaviour and register in the same breath without running the
   assertion in between — that is how a register stops describing anything.

## Known gaps at v1.2

Measured, not estimated — these are Parts with no schema surface at all:

- **Part 14, Device Operations.** Zero tables matching device or scan. The warehouse
  application the specification describes as "a different application against the same
  functions" does not exist yet. This is the largest unbuilt Part.
- **Part 18, Commercial.** Subscription, entitlement and metering are barely present.
- **Part 19, Analytics.** The governed query layer of §19.1 is not built; report and
  KPI catalogue tables exist, the query layer above them does not.
