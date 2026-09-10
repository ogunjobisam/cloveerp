# Every step says what it found, and what feeds it

## What I checked first

Goods received **already** land in goods-in. When a receipt is posted, each line
goes to the site's goods-in place unless the item must be inspected, in which
case it goes to quarantine. Nothing needs changing there. The reason your
put-away run raised nothing is that the demo company's stock was loaded straight
into bulk storage when the demo was created — so there was genuinely nothing
standing in goods-in to move. The screen just didn't say so.

So the fix is not to change where stock lands. It is to stop every one of these
"raise the next batch of work" buttons from closing silently.

## What will change

**1. Each of these actions will report what it found.**

| Screen | Action | When it finds nothing it will say |
| --- | --- | --- |
| Stock | Raise put-away tasks | Nothing is standing in goods-in at this site |
| Stock | Raise replenishment tasks | No pick face is below its top-up level |
| Stock | Raise count tasks | Nothing at this site is due to be counted |
| Despatch | Plan a shipment | No deliveries are ready to leave |
| Planning | Run the plan / Firm a planned order | Nothing suggested a new order |
| Purchasing | Propose a payment run | No supplier bill is approved and due |
| Sales | Generate invoice schedules | No order is due to be billed |
| Quality | Raise an inspection | Nothing received needs inspecting |

Each message names the step, the site and the date you chose, so you know which
one to change and try again. Where work *is* raised, it says how many and the
list beside it refreshes immediately.

**2. Each empty step will say what feeds it.** Instead of "No records", the
Put away step will read "Nothing to put away. Work appears here once goods are
received into goods-in." Same for picks, counts, shipments, planned orders,
payment proposals and inspections — every step names the step before it, so the
process strip reads as a chain even when a step is empty.

**3. Every form keeps naming its record** at the top, as it now does, and
finishes with the same spoken result.

## Technical notes

- `outcomeOf()` in `src/components/erp/action.tsx` grows a per-action message
  map keyed by function name, replacing the single generic "nothing was raised"
  sentence. Actions declare an optional `emptyNote` in `ActionSpec`
  (`src/components/erp/actions-bar.tsx`) which `ActionDialog` prefers.
- `Stage` in `src/components/erp/process-flow.tsx` grows an optional `fedBy`
  string; `StageList` renders it as the empty state instead of the generic one.
- Stage and action declarations in `src/lib/modules.tsx` and the hand-written
  `/procurement`, `/sales`, `/finance` routes carry the new strings.
- No database change and no migration: posting, task generation and permissions
  are all correct as they stand.
- Checks: `bun run typecheck`, `bun run lint`, `bun run test`, `bun run build`,
  `bash supabase/ci/form_fields.sh`, `bash supabase/ci/screen_strings.sh`.
