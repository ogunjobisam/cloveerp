# One screen, one document

Today raising a requisition takes three visits: create the header, open the
document, add each line, then price it. That is the shape of the database, not
the shape of the job. This makes the whole document — partner, dates, and every
line with its product, quantity and price — one form, saved once.

## What you will see

Pressing **New** on any document step opens a full-page form:

```text
 New requisition
 Supplier [ Co-op Wholesale ▾ ]   Site [ Leeds ▾ ]   Required [ 2026-10-01 ]
 Their reference [ ................ ]

 Lines
  Product              Quantity   Unit price   Description
 [ OAT-25  ▾ ]        [   100  ] [   1.85   ] [ .............. ]  ✕
 [ FLR-16  ▾ ]        [    60  ] [   2.10   ] [ .............. ]  ✕
 [ + Add a line ]

 [ Create ]   [ Create and send ]        Total  £311.00
```

- Product pickers, not typed codes; prices pre-filled from the agreed price for
  that partner and product where one exists, and still editable.
- A running total as you type.
- **Create** leaves it as a draft; **Create and send** does the create, the
  lines and the next step in one press, so a straightforward order is one form.
- It saves as a whole. If a line is wrong, nothing is created and the form tells
  you which line — you never get a half-made document to clean up.
- Editing an existing document keeps its lines in the same grid, so amending is
  the same screen as creating.

## Everywhere it applies

| Module | Now one form |
| --- | --- |
| Purchasing | Requisition, purchase order, goods receipt (lines received), supplier bill |
| Sales | Quotation, sales order, delivery note, sales invoice |
| Inventory | Stock adjustment, transfer, count sheet — all with their lines |
| Manufacturing | Works order with its components and operations |
| Despatch | Wave with its lines |
| Planning | Forecast with its lines |
| Quality | Event with its checks |
| Finance | Journal with its postings, payment run selection |

Steps that genuinely are a decision by somebody else — approve, post, pay —
stay as their own quick confirmation. Combining those would remove a control,
not a click.

## Technical notes

- One new governed function per family, doing header and lines in a single
  transaction, e.g. `erp_create_document_full(p_type_code, p_party_id,
  p_site_id, p_their_ref, p_required_date, p_currency, p_lines jsonb,
  p_submit boolean)`. It reuses `erp.open_document` and the existing add-line
  and transition routines, so numbering, lifecycle, approval bands and pricing
  are unchanged — only the number of round trips changes. Each new public
  function asserts its own governance in the same migration
  (`supabase/ci/boundary_in_migration.sh`), with `erp_test` cases for the
  all-or-nothing behaviour and for a line that fails validation.
- Price defaulting calls the existing resolve-price routines inside the same
  function when a line arrives without a price.
- Client: the existing `rows` field kind in `src/components/erp/action.tsx`
  grows typed columns (`item`, `money`, `number`) with the same pickers the
  single-field forms use, plus a computed footer total. `DocumentPanel` in
  `src/components/erp/documents.tsx` switches its **New** action to the
  combined function, and the stage panes in
  `src/components/erp/process-flow.tsx` use the same form so every step's
  create button is the full form.
- `ActionDialog` gains an optional second submit (`alsoSubmit`) rendering the
  "Create and send" button, which sets `p_submit`.
- Migrations forward-only. Checks: `bun run typecheck`, `bun run lint`,
  `bun run test`, `bun run build`, `supabase/ci/form_fields.sh`, and the schema
  assertion suite.

## Sequencing

1. Documents family (purchasing and sales) — the one you hit daily.
2. Inventory and despatch.
3. Manufacturing, planning, quality, finance.

Each stage ships working, so you can walk Clove Foods after the first.
