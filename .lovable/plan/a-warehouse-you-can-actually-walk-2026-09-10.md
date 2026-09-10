# A warehouse you can actually walk

You already have a Warehouse layout screen with zones, bins, and rules that say
where a product belongs. Three things are missing before it is a real
warehouse: shelves and aisles as places in their own right, a walking order so
picking follows a sensible route rather than alphabetical codes, and the
ability to point a whole product group at a *zone* instead of naming one bin at
a time.

## 1. Shelves and aisles

Storage places gain two more kinds — **aisle** and **shelf** — so a site reads
the way the building does:

```text
Leeds warehouse
  Ambient zone
    Aisle A
      Shelf A1
        Bin A1-01, A1-02 ...
      Shelf A2
    Aisle B
  Chilled zone
  Goods-in / Despatch / Quarantine
```

Any place can hold stock or simply group the places beneath it; the layout
screen shows the tree indented, with capacity and occupancy rolled up so you
can see how full an aisle is, not just a bin.

## 2. Pick path

Every place gets a **walk order** number. Picking, put-away and replenishment
lists come out in that order, so a picker walks the aisles once in sequence
instead of criss-crossing the floor.

- **Set walk order** on any single place, typed in.
- **Renumber pick path** on a site or a zone: walks the tree in code order and
  numbers everything beneath it in tens (10, 20, 30 …), leaving gaps so a new
  bin can be slotted in without renumbering the lot.
- The layout screen shows the walk order beside each place and can sort by it,
  which is the pick path read top to bottom.

## 3. Assign products to a zone

Storage rules today name one exact place. They will also accept a zone, an
aisle or a shelf. A rule that names a zone means "anything in this product
group belongs somewhere in here" — when put-away runs, it looks inside that
zone and picks the first bin in walk order that is open and not full, rather
than making you write a rule per bin.

A new **Assign products to a zone** form on the Warehouse layout screen: choose
a product or a product classification, choose the zone, say whether it is for
put-away, for the pick face, or both, and give it a priority so a second choice
is named when the first is full.

## What changes in the flow

- **Put away** resolves the rule, expands a zone target into its bins in walk
  order, skips blocked and full ones, and falls back to today's behaviour when
  nothing matches. It already says why when it raises nothing.
- **Replenishment** tops up the ruled pick face; where the rule names a zone it
  takes the first pick face in that zone by walk order.
- **Picking** still chooses *which* stock by FEFO/FIFO/LIFO — that is
  untouched. Where several places could serve, the ruled one wins, then walk
  order. Resulting tasks are listed in walk order.

## Technical shape

- Migration: add `aisle` and `shelf` to `erp.location_type`; add
  `erp.location.pick_sequence integer`; index on `(tenant_id, site_id,
  pick_sequence)`.
- Rewrite `erp.resolve_storage_locations` to expand a non-bin target through
  `erp.location.path` into its storable descendants, ordered by rule
  specificity, then priority, then `pick_sequence`, then code; keep the blocked
  and capacity filters.
- New governed doors, each authorising `administration.configure` and
  asserting its own governance in the same migration:
  `erp_set_location_sequence`, `erp_renumber_pick_path(p_root_location_id,
  p_site_id)`. Widen `erp_create_location` / `erp_update_location` with
  `p_pick_sequence`, and `erp_locations` to return it plus rolled-up occupancy.
- `erp.raise_putaway_tasks`, `erp.raise_replenishment_tasks` and
  `erp.commit_allocation` order candidate locations by `pick_sequence`;
  `erp_warehouse_tasks` returns in walk order.
- Front end: `src/routes/inventory/warehouse.tsx` gains the walk-order column,
  the two pick-path actions, `aisle`/`shelf` in the type list, and the
  zone-assignment form. Resource keys seeded for every new label.

## Verification

`bun run typecheck`, `bun run lint`, `bun run test`, `bun run build`,
`supabase/ci/form_fields.sh`, `supabase/ci/screen_strings.sh`, plus new
assertions: a zone rule resolves to a bin inside that zone, a full bin is
skipped for the next in walk order, renumbering leaves gaps and is repeatable,
and the pick-path doors refuse a caller without the permission. Then the Clove
Foods data is re-walked so put-away spreads across bins instead of stacking
everything in A-BULK-01.
