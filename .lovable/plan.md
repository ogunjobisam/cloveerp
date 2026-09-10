# Process flows on every screen that can act

Give the operational screens the same shape as the Sage X3 purchasing screen you
liked: a left-to-right process chain across the top of the page, each step a
clickable box that opens the action that moves work to the next step, with the
enquiries and reports for that chain beside it.

## What you will see

On each module screen, above the existing cards, a **process strip**:

```text
 Requisition  →  Purchase order  →  Goods receipt  →  Supplier bill  →  Payment
 [ Raise ]       [ Approve/Send ]   [ Receive ]       [ Bill receipt ]  [ Pay run ]
```

- Each box names the stage and shows how many documents sit there right now.
- Clicking a box opens the action that advances that stage — the same dialogs
  that exist today, no new business logic.
- Boxes for permissions you do not hold are shown greyed, not hidden, so the
  shape of the process stays readable.
- Below the strip, the page keeps its current tabs, panels and reports.

## Chains to build

| Screen | Chain |
| --- | --- |
| Purchasing | Requisition → Purchase order → Goods receipt → Supplier bill → Payment |
| Sales | Quote → Sales order → Pick → Despatch → Invoice → Cash |
| Inventory | Receive → Put away → Count → Adjust → Transfer |
| Manufacturing | Works order → Release → Report progress → Complete → Close |
| Despatch | Wave → Allocate → Pick → Load → Ship |
| Planning | Forecast → Requirements run → Planned order → Firm |
| Quality | Event → Investigate → Disposition → Release/Reject |
| Finance | Invoice → Post → Match cash → Period close |

Screens that are configuration rather than a process (permissions, tenant,
devices, integrations) keep their present layout.

## Technical notes

- New `src/components/erp/process-flow.tsx`: a `ProcessFlow` component taking
  `stages: { label, hint, countFn?, countArgs?, action?, permission? }[]`.
  Counts come from existing read functions via the same query layer panels use;
  actions reuse `ActionDialog` from `action.tsx`, so nothing new reaches the
  database.
- Chain definitions live next to the module definitions in `src/lib/modules.tsx`
  as an optional `flow` on `ModuleDef`, so `ModulePage` renders it once for every
  module screen.
- `/procurement`, `/sales`, `/finance` are hand-written routes; each gets its
  chain declared locally and rendered above its current content.
- Responsive: the chain scrolls horizontally on a phone and wraps to a grid at
  small widths; arrows are decorative and hidden from screen readers.
- Verification: `bun run typecheck`, `bun run test`, `bun run lint`,
  `bun run build`, plus a browser pass over the changed screens.
