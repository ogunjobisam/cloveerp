# Pick a step, then pick a record

Today the flow strip at the top of a screen names each step and carries a button,
but the button asks you to choose the record again inside the dialog, and every
list on the screen is dumped underneath in full. This turns each of those screens
into a step-driven workbench.

## How it will work

1. The flow strip stays where it is, but the boxes become selectable. Pressing
   **Goods receipt** puts that step in charge of the screen below it.
2. Below the strip, two panes:
   - **Left — the list for that step only.** Goods receipts when the step is goods
     receipt, requisitions when it is requisition. A search box at the top, 20 rows
     per page, and back/forward arrows with "Page 2 of 7". The page resets when the
     search changes.
   - **Right — the record you clicked.** Its number, date, partner, value and state,
     its lines, and the buttons that move *that* record on. The record is already
     chosen, so those dialogs no longer ask for it.
3. With no record chosen the right pane says so and still offers the step's
   "create a new one" button.
4. Steps you have no permission for stay visible and greyed, as now.

## Where it applies

Every screen with a flow already defined: Purchasing, Sales, Stock, Manufacturing,
Planning, Quality control, Despatch, Financials. Configuration and reporting screens
keep their current layout. The old full-length lists below the workbench are removed
on those screens where the workbench now shows the same records, so nothing appears
twice.

## Technical notes

- `src/components/erp/process-flow.tsx` grows from a strip into `ProcessWorkbench`:
  selected-stage state, a `StageList` (search + paging over `erp_documents` /
  a stage's declared read) and a `StageRecord` pane reusing `erp_document` and
  `erp_document_lines`.
- Paging and search are client-side over the rows already fetched for a stage
  (limit raised, capped), so no migration and no door change is needed. If a stage
  exceeds the cap the footer says so, the way `RecordBrowser` already does.
- `ActionDialog` gains an optional `prefill` map: named arguments are merged into
  the submitted args and their fields are not rendered, so a stage action on a
  selected record opens with one or two questions instead of six.
- `Stage` gains `recordArg` (which argument the selected record fills, e.g.
  `p_document_id`, `p_receipt_id`) and may carry more than one `actionFn`.
- Module flows in `src/lib/modules.tsx` and the procurement/sales route flows get
  those record arguments filled in.
- No database changes. Checks to pass: `bun run typecheck`, `bun run lint`,
  `bun run test`, `bun run build`, `bash supabase/ci/form_fields.sh`.
