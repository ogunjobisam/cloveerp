# Make the forms fillable

Today many dialogs ask for things a person cannot know: a record id pasted from
somewhere else, an exact code typed from memory, or a block of JSON. 265 free-text
boxes across the screens carry no explanation at all. This fixes that, everywhere,
with a rule the build can enforce so it does not come back.

## The rule

1. **Nothing that identifies an existing record is typed.** It is chosen from a
   list of that record, shown as its number/code and its name.
2. **A code being created may be typed, but the box suggests one and shows the
   house style** (for example `WH-01`), and offers the existing codes to pick from
   where the field can also refer to one.
3. **Anything still typed says what it expects** — one sentence and an example.
4. **No raw JSON in a form.** Lists become add-a-row controls or multi-select.

## What changes

### 1. Form controls (`src/components/erp/action.tsx`)

Add to the field types, alongside the existing text/number/date/money/choice/site/select:

- `combo` — a text box with a dropdown of existing values (HTML `datalist`), so a
  code can be picked or freshly typed. Backed by the same reference reads as `select`.
- `multi` — pick several from a reference read; sends an array. Replaces every
  JSON-array box (`p_batch_ids`, `p_delivery_ids`, `p_view_codes`, `p_dimension_codes`).
- `rows` — a small repeating editor (add/remove a row, each row a few fields) for
  the one or two places that genuinely send a list of objects, e.g. calling off a
  blanket order.
- `placeholder` and `default` on every field, so a form can arrive pre-filled with
  the sensible answer (today, this site, the only company) instead of empty.

Pickers gain a type-ahead filter box when the list is long, and keep the existing
"nothing to choose from yet" state.

### 2. Shared pickers (`src/components/erp/actions-bar.tsx`)

Extend the builders so a screen declares intent, not plumbing:
`pickDocument`, `pickChangeSet`, `pickDimension`, `pickReasonCode`, `pickTemplate`,
`pickPrinter`, `pickDevice`, `pickCarrier`, `pickJob`, `pickAppUser`,
`pickFiscalPeriod`, `pickUom`, `pickCurrency`, plus `codeField(...)` which produces
a properly hinted, suggested code box.

### 3. The sweep, screen by screen

Every `_id` text box becomes a picker; every code box becomes a combo or gains an
example; every remaining box gains a hint. Files, heaviest first:

`src/lib/modules.tsx` (60), `administration/organisation`, `operations/output`,
`master-data/index`, `reporting/distribution`, `master-data/classification`,
`finance/dimensions`, `finance/account-determination`, `operations/jobs`,
`operations/integrations`, `operations/devices`, `governance/index`,
`commercial/price-book`, `administration/configuration`, `logistics/release-areas`,
`procurement/index`, `operations/cutover`, `commercial/quotes`,
`administration/adoption`, `administration/terminology`, `sales/index`,
`notifications`, and the remaining smaller screens.

### 4. Lists the database does not yet publish

A few pickers have no read behind them: integration commands, mass changes,
distribution credentials, handling units (containers), carriers/services, and
analytics views. One forward-only migration adds the missing `public.erp_*` list
doors with the usual grants, permission checks and in-migration assertions —
read-only, no new write surface. Where a list cannot exist, the field keeps a
plain-English hint naming the screen the value is shown on.

### 5. Keeping it fixed

A build check (`supabase/ci/form_fields.sh`, run in the same place the other screen
checks run) fails when a form declares a text field whose name ends in `_id`, or a
text field with no hint. That is the guard against this drifting back.

## Technical notes

- Pickers reuse the existing `[fn, args]` query key so page Refresh still reaches them.
- Array and row fields send real arrays through `callErp`, so `mapArgs` JSON parsing
  disappears from the screens that use it.
- The migration follows house rules: forward-only, grants in the same migration,
  governance assertion in the same migration.
- Verified with `bun run typecheck`, `bun run lint`, `bun run test`, `bun run build`,
  plus a browser pass opening the reworked dialogs on the busiest screens.

## Order of work

1. Field kinds and shared pickers.
2. Migration for the missing list doors.
3. The screen sweep, module by module.
4. The build check, then full verification.
