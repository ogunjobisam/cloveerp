# Warehouse layout, storage rules, and a real Clove organisation

Two pieces of work. The first gives the warehouse a shape you can define —
zones, bins, and rules about what belongs where — and makes put-away and
picking obey it. The second gives you a genuine organisation of your own,
already stocked and mid-flow, to walk the whole thing end to end.

## 1. Warehouse layout

### What you will see

A new screen, **Stock → Warehouse layout**, laid out like the rest of the desk:
sites on the left, and for the chosen site the storage places beneath it as a
tree — a zone, the aisles under it, the bins under those.

For each place you can set:

- its code and name, and the place it sits inside
- what it is for: goods-in, bulk reserve, a pick face, quarantine, despatch
- whether it can be picked from
- how much it holds (a capacity figure and a unit)
- its counting class (how often it is counted)
- blocked or open, with a reason when blocked

And a second card, **Storage rules**, which is the part that makes the layout
do work rather than just describe it. A rule says: *this product* (or every
product of *this classification*) *belongs in this place, at this site, in this
order of preference* — one kind of rule for where goods are put away to, and
one for the pick face they are picked from. Rules carry a priority so the
second choice is named when the first is full or blocked.

### What changes in the flow

- **Put away** currently sends everything standing in goods-in to the first
  bulk location it finds, alphabetically. It will instead follow the storage
  rules for the product, best rule first, skipping places that are blocked or
  already at capacity, and falling back to today's behaviour when no rule
  matches. When it raises nothing, it will keep saying why.
- **Replenishment** will top up the pick face the rules name, rather than any
  pickable location it happens to find.
- **Picking** already prefers a pick face over bulk. It will additionally
  prefer the pick face the rules name for that product, before any other
  pickable place. The choosing method (FEFO/FIFO/LIFO) still wins first — a
  rule decides *where*, never *which stock*.

### Technical shape

- New table `erp.storage_rule`: tenant, site, optional item, optional
  classification value, rule kind (`putaway` | `pick_face`), target location,
  priority, effective dates, status. Tenant-scoped RLS and grants like every
  other table; a resolver function `erp.resolve_storage_locations(item, site,
  kind)` returning target locations in preference order.
- `erp.location` already carries `parent_location_id`, `path`, `capacity`,
  `count_class`, `is_pickable`, `is_blocked`. The doors do not expose them, so:
  widen `erp.create_location` / `public.erp_create_location` with parent,
  capacity, pickable and count class; add `erp.update_location`,
  `erp.block_location`, `erp.unblock_location` and their public doors; widen
  `public.erp_locations` to return parent, depth, capacity, occupancy and count
  class.
- New doors: `erp_storage_rules`, `erp_create_storage_rule`,
  `erp_remove_storage_rule`.
- `erp.raise_putaway_tasks` and `erp.raise_replenishment_tasks` call the
  resolver; `erp.commit_allocation` gains a pick-face-rule term in its ordering
  ahead of the existing pickable term.
- Every new door authorises (`administration.configure` for layout,
  `inventory.adjust` for the rules), is registered on the write allow-list, and
  asserts its own governance in the same migration, per the house rule.
- Front end: `src/routes/inventory/warehouse.tsx` built from the existing
  `ModulePage` / `DataPanel` / `ActionBar` parts, a `pickLocation`-style parent
  picker, and a stage entry in the Stock flow in `src/lib/modules.tsx`.
  Resource keys seeded for every new label.

## 2. A real Clove organisation

A tenant called **Clove Foods** — not a demo tenant, a live-shaped one you own
— provisioned through the public doors exactly as a customer would be, and
handed to your account as administrator.

It will have:

- one company, two sites: a Leeds warehouse and a small London depot
- a real layout at Leeds: goods-in, two bulk aisles with bins beneath them,
  two pick faces, quarantine, despatch — with storage rules pointing each
  product group at its aisle and pick face
- a supplier list, a customer list, and around a dozen products with costs,
  units and classifications
- opening stock in bulk and on the pick faces
- purchase orders in several states: some open, some part-received, some
  received and awaiting a supplier bill
- goods receipts standing in goods-in, so **Put away** has real work waiting
  the first time you press it
- a couple of sales orders ready to allocate and pick

Built by running the public doors against the live project as your own
principal, so nothing in it depends on the demo seeder and everything in it is
data you can edit, post and delete like any other organisation.

## Verification

`bun run typecheck`, `bun run lint`, `bun run test`, `bun run build`,
`supabase/ci/form_fields.sh`, `supabase/ci/screen_strings.sh`, plus new
assertions: put-away honours a rule, put-away skips a blocked target,
replenishment tops up the ruled pick face, picking prefers it, and the layout
doors refuse a caller without the permission.
