set lock_timeout = '30s';

-- =============================================================================
-- 20260916500000  A place that is full is skipped
-- -----------------------------------------------------------------------------
-- Two of the findings 20260916430000 wrote down, and they are twins.
--
--   * erp.location.capacity. The warehouse layout screen offers "Holds at most"
--     with the hint "Put-away skips a place that is already full", and
--     erp.create_location()/erp.update_location() store the number. Nothing has
--     ever read it. Put-away sent a pallet to a bin that was full, and the bin's
--     stated capacity had no more effect on where the pallet went than the name
--     of the aisle did.
--   * erp.storage_rule.max_quantity. The same screen offers "Fill to at most"
--     with the hint "Once the place holds this much, the next rule is used".
--     erp.resolve_storage_locations() selected the column and ordered by
--     priority; put-away compared max_quantity against what was STANDING in the
--     place but never against what was ARRIVING, so a rule that said "fill to
--     100" accepted a 100-pallet into a bin holding 99.
--
-- Both are the class the check was built for: the field saves, the toast says
-- saved, the value comes back next time, and the behaviour it promises never
-- happens. Both rows come out of erp_meta.write_only_column at the end of this
-- migration, because the register refuses a row whose column something now
-- reads and a register kept past its reason is a list nobody looks at.
--
-- ── WHAT NOW DECIDES ─────────────────────────────────────────────────────────
--
-- One routine answers "how much more will this place take", and everything that
-- needs the answer asks it:
--
--   erp.place_room(location, rule's limit) = the smaller of the two limits
--   somebody stated — the place's own "Holds at most" and the rule's own "Fill
--   to at most" — less what is standing there now, less what open warehouse
--   tasks already promise to bring. Null means nobody stated a limit, which is
--   "as much as it takes". least() passes over a null, so one limit and one
--   silence is the limit, and two silences is no limit.
--
-- erp.resolve_storage_locations() now carries that room beside each candidate,
-- which is what makes max_quantity a read: the rule's own column is handed to
-- the routine that decides. erp.putaway_target() walks the candidates best
-- first, takes the first with room for the WHOLE quantity arriving, and falls
-- back — as it always has — to the first open bulk-then-pick location at the
-- site, now asking that one the same question. Put-away and replenishment both
-- call it, so there is one answer and not two.
--
-- Counting what open tasks already promise matters more than it looks. Without
-- it, two pallets in the same run are both sent to the last bin with room for
-- one, and the second person to walk there finds it full.
--
-- ── WHAT HAPPENS WHEN EVERY CANDIDATE IS FULL ────────────────────────────────
--
-- The goods stay in goods-in, no task is raised for them, the rest of the run
-- carries on, and erp_putaway_holds() says so by name.
--
-- The alternatives were considered and rejected:
--
--   * Refusing the call. The goods have physically arrived — they are standing
--     in goods-in whatever the database says — and a refusal would also stop
--     the pallets that DO have somewhere to go from being put away. A refusal
--     nobody can act on at the moment it is raised is a refusal that teaches
--     people to press the button twice.
--   * Sending them anyway, to the best of the full places. That is the defect
--     this migration exists to remove, dressed as a courtesy.
--   * Raising the task and noting the overflow on it. erp.warehouse_task.note
--     is not returned by public.erp_warehouse_tasks(), so the note would be
--     written into the dark — the very class 20260916430000 refuses.
--
-- So the position is left where it is, which is true of the physical world, and
-- the fact is made visible where the capacity was set. public.erp_putaway_holds()
-- computes the answer on read rather than storing it — erp.data_quality_report()
-- is the precedent — so it is never stale, needs no table and leaves no rows to
-- clean up. It says which of two things happened: every place the rules name is
-- full, or no rule reaches this product and nowhere at the site has room. The
-- warehouse layout screen shows it under "Nothing could be put away", beside the
-- capacities and the rules that caused it.
--
-- ── WHAT THIS DELIBERATELY DOES NOT DO ───────────────────────────────────────
--
--   * It does not split a receipt across places. One position in goods-in still
--     raises at most one task, as it always has; a place with room for half of
--     what is arriving is skipped rather than part-filled. Splitting is a real
--     improvement and a different change, and it would alter what a warehouse
--     person is handed rather than only where they are sent.
--   * It does not convert units. A capacity is {quantity, uom} and stock
--     balances are in the item's own stock unit; the comparison is of plain
--     numbers, and the unit is recorded rather than honoured. A bin holding two
--     products counted in different units is compared against one capacity, and
--     the answer is only as good as the units the site uses. Converting needs a
--     uom conversion on every balance in the bin and is worth doing when a site
--     asks for it.
--   * It counts every product standing in the place, not only the one arriving.
--     That is what "holds at most" means on a shelf.
--
-- ── REPLENISHMENT SHARES THE PATH ────────────────────────────────────────────
--
-- erp.raise_replenishment_tasks() resolves its pick face through the same
-- routine, so it now skips a face with no room and never sends more than the
-- face will take. Put-away's behaviour is proven end to end below, against
-- stock actually received; replenishment's is proven through the room routine
-- and the call, because building a committed allocation against a short pick
-- face is a sales fixture rather than a warehouse one and the case would prove
-- the fixture more than the rule.
--
-- ── THE SUITE'S OWN FALSIFICATION MOVES ──────────────────────────────────────
--
-- erp_test.write_only_column_suite() case 6 falsified the check by deleting the
-- erp.location.capacity row and requiring a refusal naming it. That column is
-- now read, so the case is re-pointed at erp.notification_channel.credential_ref
-- — the one entry in the register whose whole point is that the database must
-- never be able to decide anything from it, and therefore the one least likely
-- to be fixed out from under the case. The case count does not change.
--
-- Proof: erp_test.putaway_capacity_suite() (9 cases, wrapper pinned).
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. How much more a place will take
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.place_room(
  p_location_id uuid, p_rule_max numeric default null)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.current_tenant_id();
  v_capacity numeric;
  v_limit    numeric;
  v_standing numeric;
begin
  -- "Holds at most", as the location screen offers it. A place whose capacity
  -- carries no quantity, or carries something that is not one, has stated
  -- nothing: the column is jsonb and the door is not the only way in, and a
  -- place nobody can put anything into is a worse answer than no limit.
  select case when jsonb_exists(l.capacity, 'quantity')
                   and (l.capacity ->> 'quantity') ~ '^[0-9]+(\.[0-9]+)?$'
              then (l.capacity ->> 'quantity')::numeric
         end
    into v_capacity
    from erp.location l
   where l.tenant_id = v_tenant
     and l.id = p_location_id;

  -- The tighter of the two limits anybody stated.
  v_limit := least(v_capacity, p_rule_max);
  if v_limit is null then
    return null;
  end if;

  select coalesce(sum(sb.quantity), 0)
    into v_standing
    from erp.stock_balance sb
   where sb.tenant_id = v_tenant
     and sb.location_id = p_location_id;

  -- What is already on its way counts as standing there.
  v_standing := v_standing
    + coalesce((select sum(greatest(t.quantity - t.quantity_done, 0))
                  from erp.warehouse_task t
                 where t.tenant_id = v_tenant
                   and t.to_location_id = p_location_id
                   and t.status = 'open'), 0);

  return v_limit - v_standing;
end $$;

comment on function erp.place_room(uuid, numeric) is
  'How much more one place will take: the smaller of what the place itself '
  'holds and what a storage rule allows, less what is standing there and what '
  'open warehouse tasks already promise to bring. Null when nobody stated a '
  'limit. Quantities are compared as plain numbers; the capacity''s unit is '
  'recorded, not converted.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The resolver carries the room beside each candidate
-- -----------------------------------------------------------------------------
-- A column is added to the answer, so the function is replaced rather than
-- redefined. Its callers are plpgsql and resolve it by name at run time.
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists erp.resolve_storage_locations(uuid, uuid, text);

create or replace function erp.resolve_storage_locations(
  p_item_id uuid, p_site_id uuid, p_kind text)
returns table (location_id uuid, max_quantity numeric, priority smallint, room numeric)
language sql
stable
set search_path = ''
as $$
  -- A rule's "fill to at most" states a limit only when it is a positive
  -- quantity; anything else states nothing, for the reason the capacity above
  -- states nothing.
  select r.location_id, r.max_quantity, r.priority,
         erp.place_room(r.location_id,
                        case when r.max_quantity > 0 then r.max_quantity end)
    from erp.storage_rule r
    join erp.location l
      on l.tenant_id = r.tenant_id and l.id = r.location_id
    left join erp.item i
      on i.tenant_id = r.tenant_id and i.id = p_item_id
   where r.tenant_id = erp.current_tenant_id()
     and r.site_id = p_site_id
     and r.rule_kind = p_kind
     and r.status = 'active'::erp.record_status
     and r.valid_from <= current_date
     and (r.valid_to is null or r.valid_to >= current_date)
     and (r.item_id = p_item_id
          or (r.item_id is null
              and (r.item_class is null or r.item_class = i.item_class)))
     and l.status = 'active'::erp.record_status
     and coalesce(l.is_blocked, false) = false
   order by (r.item_id is null)::int, (r.item_class is null)::int,
            r.priority, l.code
$$;

comment on function erp.resolve_storage_locations(uuid, uuid, text) is
  'The places a product belongs at a site, best first: a rule naming the '
  'product beats a rule naming its class, which beats a rule naming neither. '
  'Each candidate carries how much more it will take, so the rule''s own '
  '"fill to at most" and the place''s own "holds at most" are answered together.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Where one position in goods-in should go
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.putaway_target(
  p_item_id uuid,
  p_site_id uuid,
  p_quantity numeric,
  p_from_location_id uuid default null)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_target uuid;
  cand     record;
begin
  -- The layout first: the places the product belongs, best rule first, with a
  -- place skipped when what is standing there plus what is arriving would pass
  -- the smaller of the two limits somebody stated.
  for cand in
    select c.location_id, c.room
      from erp.resolve_storage_locations(p_item_id, p_site_id, 'putaway') c
  loop
    if cand.room is null or cand.room >= p_quantity then
      v_target := cand.location_id;
      exit;
    end if;
  end loop;

  -- No rule reaches this product: the old behaviour, which is bulk before pick
  -- face and code order within that, now asking the same question of room.
  if v_target is null then
    select l.id into v_target
      from erp.location l
     where l.tenant_id = v_tenant and l.site_id = p_site_id
       and l.status = 'active'::erp.record_status
       and coalesce(l.is_blocked, false) = false
       and l.location_type in ('bulk'::erp.location_type, 'pick'::erp.location_type)
       and coalesce(erp.place_room(l.id, null), p_quantity) >= p_quantity
     order by case when l.location_type = 'bulk'::erp.location_type then 0 else 1 end, l.code
     limit 1;
  end if;

  -- Somewhere it already is, is not somewhere to send it.
  if v_target is not null and v_target = p_from_location_id then
    return null;
  end if;

  return v_target;
end $$;

comment on function erp.putaway_target(uuid, uuid, numeric, uuid) is
  'The place one position standing in goods-in should be taken to: the first '
  'place the site''s storage rules name that has room for the whole quantity, '
  'then the first open bulk or pick location with room. Null when nowhere has '
  'room, which is not a refusal — the goods have arrived and stay where they '
  'are, and erp.putaway_holds() names them.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Put-away and replenishment ask it
-- -----------------------------------------------------------------------------
-- Both bodies were patched after their defining migration (20260914061500 moved
-- them from inventory.adjust to inventory.move, and repaired replenishment's
-- min(uuid)), so the live body is read with pg_get_functiondef() and the needle
-- is asserted to occur exactly once before it is replaced.
-- ═════════════════════════════════════════════════════════════════════════════

do $putaway$
declare
  v_sig text := 'erp.raise_putaway_tasks(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_n   text := $n$    v_target := null;

    -- The layout first: the places the product belongs, best rule first, with
    -- a rule skipped when its place already holds what the rule allows.
    for c in
      select * from erp.resolve_storage_locations(r.item_id, p_site_id, 'putaway')
    loop
      if c.max_quantity is null then
        v_target := c.location_id;
        exit;
      end if;

      select coalesce(sum(sb.quantity), 0) into v_standing
        from erp.stock_balance sb
       where sb.tenant_id = v_tenant and sb.location_id = c.location_id;

      if v_standing < c.max_quantity then
        v_target := c.location_id;
        exit;
      end if;
    end loop;

    -- No rule reaches this product: the old behaviour, which is bulk before
    -- pick face and code order within that.
    if v_target is null then
      select l.id into v_target
        from erp.location l
       where l.tenant_id = v_tenant and l.site_id = p_site_id
         and l.status = 'active'::erp.record_status
         and coalesce(l.is_blocked, false) = false
         and l.location_type in ('bulk'::erp.location_type, 'pick'::erp.location_type)
       order by case when l.location_type = 'bulk'::erp.location_type then 0 else 1 end, l.code
       limit 1;
    end if;$n$;
  v_r   text := $r$    -- Where it belongs AND where there is room for it, decided in one place so
    -- that erp.putaway_holds() answers from the same reasoning (20260916500000).
    v_target := erp.putaway_target(r.item_id, p_site_id, r.qty, r.location_id);$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PUTAWAY_DOOR_UNRECOGNISED: % does not choose its place the way this migration patches', v_sig
      using hint = 'A later migration changed the function. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp.putaway_target(' in v_def) = 0
     or position('resolve_storage_locations' in v_def) > 0 then
    raise exception 'CLOVEERP_PUTAWAY_DOOR_UNRECOGNISED: % did not take the shared target routine', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$putaway$;

do $replenish$
declare
  v_sig text := 'erp.raise_replenishment_tasks(uuid)';
  v_def text;
  v_n   text;
  v_r   text;
begin
  -- The two working variables the cap needs.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_n := $n$  v_to uuid;$n$;
  v_r := $r$  v_to uuid;
  v_qty numeric;$r$;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_REPLENISHMENT_DOOR_UNRECOGNISED: % does not declare v_to the way this migration patches', v_sig
      using hint = 'A later migration changed the function. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  -- The face it tops up, and how much of it the face will take.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_n := $n$    -- The pick face the layout names, when it names one.
    select coalesce(
             (select location_id from erp.resolve_storage_locations(r.item_id, p_site_id, 'pick_face') limit 1),
             r.to_location_id)
      into v_to;

    if v_to = r.from_location_id then
      continue;
    end if;$n$;
  v_r := $r$    -- The pick face the layout names, and the first of them with room for a
    -- top-up: a face already at what it holds is skipped the way put-away skips
    -- a full bin (20260916500000).
    select coalesce(
             (select cand.location_id
                from erp.resolve_storage_locations(r.item_id, p_site_id, 'pick_face') cand
               where cand.room is null or cand.room > 0
               limit 1),
             r.to_location_id)
      into v_to;

    if v_to = r.from_location_id then
      continue;
    end if;

    -- Never send more than the face will take.
    v_qty := least(r.qty, coalesce(erp.place_room(v_to, null), r.qty));
    if v_qty is null or v_qty <= 0 then
      continue;
    end if;$r$;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_REPLENISHMENT_DOOR_UNRECOGNISED: % does not choose its pick face the way this migration patches', v_sig
      using hint = 'A later migration changed the function. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  -- And the task it writes carries the capped quantity.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_n := $n$      r.from_location_id, v_to, r.stock_status, r.qty, v_actor, v_actor);$n$;
  v_r := $r$      r.from_location_id, v_to, r.stock_status, v_qty, v_actor, v_actor);$r$;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_REPLENISHMENT_DOOR_UNRECOGNISED: % does not write its task the way this migration patches', v_sig
      using hint = 'A later migration changed the function. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp.place_room(' in v_def) = 0 then
    raise exception 'CLOVEERP_REPLENISHMENT_DOOR_UNRECOGNISED: % does not read how much room the face has', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$replenish$;

comment on function erp.raise_putaway_tasks(uuid) is
  'Raises a putaway task for every position standing in a receiving location, '
  'sending it to the place the site''s storage rules name for that product that '
  'has room for the whole quantity — skipping a place that is blocked, or whose '
  'own capacity or whose rule''s limit it would pass — and to the first open '
  'bulk location with room when no rule reaches it. A position nowhere has room '
  'for stays in goods-in and is named by erp.putaway_holds().';

comment on function erp.raise_replenishment_tasks(uuid) is
  'Tops up a short pick face from bulk reserve, into the first face the site''s '
  'storage rules name that still has room, and never with more than that face '
  'will take.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. What could not be put away
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.putaway_holds(p_site_id uuid default null)
returns table (site_id uuid, item_id uuid, batch_id uuid, location_id uuid,
               stock_status erp.stock_status, quantity numeric, reason text)
language sql
stable
set search_path = ''
as $$
  select h.site_id, h.item_id, h.batch_id, h.location_id, h.stock_status, h.qty,
         case when h.places_named > 0 then 'every_place_is_full'
              else 'nowhere_has_room' end::text
    from (
      select sb.site_id, sb.item_id, sb.batch_id, sb.location_id, sb.stock_status,
             sum(sb.quantity) as qty,
             (select count(*)
                from erp.resolve_storage_locations(sb.item_id, sb.site_id, 'putaway')) as places_named
        from erp.stock_balance sb
        join erp.location l on l.tenant_id = sb.tenant_id and l.id = sb.location_id
       where sb.tenant_id = erp.current_tenant_id()
         and sb.quantity > 0
         and l.location_type = 'receiving'::erp.location_type
         and (p_site_id is null or sb.site_id = p_site_id)
       group by sb.site_id, sb.item_id, sb.batch_id, sb.location_id, sb.stock_status
    ) h
   where erp.putaway_target(h.item_id, h.site_id, h.qty, h.location_id) is null
     and not exists (select 1 from erp.warehouse_task t
                      where t.tenant_id = erp.current_tenant_id()
                        and t.status = 'open' and t.kind = 'putaway'
                        and t.item_id = h.item_id
                        and t.from_location_id = h.location_id
                        and coalesce(t.batch_id, '00000000-0000-0000-0000-000000000000'::uuid)
                            = coalesce(h.batch_id, '00000000-0000-0000-0000-000000000000'::uuid))
$$;

comment on function erp.putaway_holds(uuid) is
  'Every position standing in goods-in that put-away left where it is because '
  'nowhere has room for it, with which of the two things happened: every place '
  'its rules name is full, or no rule reaches it and nowhere at the site has '
  'room. Computed on read, so it is never stale.';

create or replace function public.erp_putaway_holds(p_site_id uuid default null)
returns jsonb language sql stable security invoker set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'hold_id', h.item_id::text || '-' || h.location_id::text
                      || coalesce('-' || h.batch_id::text, ''),
           'site', s.code, 'site_id', h.site_id,
           'item', i.code, 'item_name', i.name,
           'batch', b.batch_number,
           'location', l.code, 'location_name', l.name,
           'quantity', h.quantity,
           'reason', h.reason)
           order by s.code, i.code, l.code), '[]'::jsonb)
    from erp.putaway_holds(p_site_id) h
    join erp.site s on s.tenant_id = erp.current_tenant_id() and s.id = h.site_id
    join erp.item i on i.tenant_id = erp.current_tenant_id() and i.id = h.item_id
    join erp.location l on l.tenant_id = erp.current_tenant_id() and l.id = h.location_id
    left join erp.batch b on b.tenant_id = erp.current_tenant_id() and b.id = h.batch_id;
$$;

revoke all on function public.erp_putaway_holds(uuid) from public, anon;
grant execute on function public.erp_putaway_holds(uuid) to authenticated, service_role;

comment on function public.erp_putaway_holds(uuid) is
  'What put-away could not place, and why. Read by the warehouse layout screen '
  'beside the capacities and the storage rules that caused it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The register loses two rows
-- ═════════════════════════════════════════════════════════════════════════════

delete from erp_meta.write_only_column
 where schema_name = 'erp'
   and (table_name, column_name) in (('location', 'capacity'),
                                     ('storage_rule', 'max_quantity'));

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The write-only suite's falsification moves off the column that is fixed
-- ═════════════════════════════════════════════════════════════════════════════

do $falsify$
declare
  v_sig text := 'erp_test.write_only_column_suite()';
  v_def text;
  v_n   text;
  v_r   text;
begin
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_n := $n$    delete from erp_meta.write_only_column
     where schema_name = 'erp' and table_name = 'location' and column_name = 'capacity';$n$;
  v_r := $r$    delete from erp_meta.write_only_column
     where schema_name = 'erp' and table_name = 'notification_channel'
       and column_name = 'credential_ref';$r$;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: % does not falsify on erp.location.capacity the way this migration patches', v_sig
      using hint = 'A later migration changed the suite. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_n := $n$  passed := v_msg like 'CLOVEERP_WRITE_ONLY_COLUMN%'
        and v_msg like '%erp.location.capacity%'
        and exists (select 1 from erp_meta.write_only_column g
                     where g.schema_name = 'erp' and g.table_name = 'location'
                       and g.column_name = 'capacity');$n$;
  v_r := $r$  passed := v_msg like 'CLOVEERP_WRITE_ONLY_COLUMN%'
        and v_msg like '%erp.notification_channel.credential_ref%'
        and exists (select 1 from erp_meta.write_only_column g
                     where g.schema_name = 'erp' and g.table_name = 'notification_channel'
                       and g.column_name = 'credential_ref');$r$;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: % does not check the refusal on erp.location.capacity the way this migration patches', v_sig
      using hint = 'A later migration changed the suite. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp.location.capacity%' in v_def) > 0 then
    raise exception 'CLOVEERP_WRITE_ONLY_SUITE_UNRECOGNISED: % still falsifies on a column that is now read', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the suite.';
  end if;
end
$falsify$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The words the screen says
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Nothing could be put away',
     'The warehouse layout panel listing what is standing in goods-in with nowhere to go.'),
    ('Stock standing in goods-in that put-away left where it is, because nowhere has room for it. Raise what a place holds, make room in it, or add a storage rule naming somewhere else.',
     'Said under that panel, because the fix is one of three things and the person reading it chooses which.'),
    ('Nothing is waiting. Everything received has had somewhere to go.',
     'Said when the panel is empty, because an empty list here is the good outcome and should read as one.'),
    ('Every place it belongs in is full',
     'The reason shown when the site''s storage rules name places for the product and all of them are at what they hold.'),
    ('Nowhere at this site has room for it',
     'The reason shown when no storage rule reaches the product and no open bulk or pick location has room either.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.putaway_capacity_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tag  text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1     uuid := gen_random_uuid();
  rb     record;
  v_step text := 'provisioning';
  v_state text;
  -- The shape of the warehouse.
  v_uom uuid; v_sup uuid;
  v_site uuid; v_recv uuid;
  v_small uuid; v_big uuid; v_part uuid; v_promised uuid; v_free uuid;
  v_ruleonly uuid; v_pick uuid;
  v_site2 uuid; v_recv2 uuid; v_tiny uuid;
  -- The products.
  i_a uuid; i_b uuid; i_c uuid; i_d uuid; i_e uuid; i_f uuid; i_z uuid; i_g uuid;
  v_doc uuid; v_line uuid;
  -- What the run left.
  v_raised1 integer; v_raised2 integer;
  t_a text; t_b text; t_c text; t_d text; t_e text;
  v_f_tasks integer; v_f_standing numeric;
  v_holds2 integer; v_holds2_reason text; v_holds1 integer;
  v_room_pick numeric; v_room_free numeric; v_replen_reads boolean;
  v_left boolean;
begin
  begin
    v_step := 'an organisation with finance, procurement, sales and inventory installed';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('zzpac-' || v_tag, 'Put-away Capacity Suite',
                                               'admin@zzpac-' || v_tag || '.test', 'Capacity Suite Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');

    v_step := 'a site whose places say what they hold';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZPEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZPONE', 'Capacity suite site', 'warehouse', 'active')
    returning id into v_site;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZPSUP', 'Capacity Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');

    v_recv     := erp.create_location(v_site, 'ZP-RECV', 'Goods in', 'receiving');
    v_small    := erp.create_location(v_site, 'ZP-A-SMALL', 'Small bay', 'bulk', null, false, 10, 'EA');
    v_big      := erp.create_location(v_site, 'ZP-B-BIG', 'Big bay', 'bulk', null, false, 1000, 'EA');
    v_part     := erp.create_location(v_site, 'ZP-C-PART', 'Part-filled bay', 'bulk', null, false, 100, 'EA');
    v_promised := erp.create_location(v_site, 'ZP-D-PROM', 'Promised bay', 'bulk', null, false, 100, 'EA');
    v_free     := erp.create_location(v_site, 'ZP-E-FREE', 'Bay that states nothing', 'bulk', null, false);
    v_ruleonly := erp.create_location(v_site, 'ZP-F-RULE', 'Bay the rule caps', 'bulk', null, false);
    v_pick     := erp.create_location(v_site, 'ZP-G-PICK', 'Pick face', 'pick', null, true, 1, 'EA');

    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZPTWO', 'Capacity suite second site', 'warehouse', 'active')
    returning id into v_site2;
    v_recv2 := erp.create_location(v_site2, 'ZP2-RECV', 'Goods in', 'receiving');
    v_tiny  := erp.create_location(v_site2, 'ZP2-TINY', 'The only bay, and a small one', 'bulk', null, false, 5, 'EA');

    v_step := 'eight products';
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (rb.tenant_id, 'ZPA', 'Skipped for a small bay', v_uom, 'active'),
      (rb.tenant_id, 'ZPB', 'Skipped by its rule''s limit', v_uom, 'active'),
      (rb.tenant_id, 'ZPC', 'Skipped for what is standing there', v_uom, 'active'),
      (rb.tenant_id, 'ZPD', 'Skipped for what is promised there', v_uom, 'active'),
      (rb.tenant_id, 'ZPE', 'Sent to a bay that states nothing', v_uom, 'active'),
      (rb.tenant_id, 'ZPF', 'Nowhere to put it', v_uom, 'active'),
      (rb.tenant_id, 'ZPZ', 'What is already standing there', v_uom, 'active'),
      (rb.tenant_id, 'ZPG', 'What stands on the pick face', v_uom, 'active');
    select id into i_a from erp.item where tenant_id = rb.tenant_id and code = 'ZPA';
    select id into i_b from erp.item where tenant_id = rb.tenant_id and code = 'ZPB';
    select id into i_c from erp.item where tenant_id = rb.tenant_id and code = 'ZPC';
    select id into i_d from erp.item where tenant_id = rb.tenant_id and code = 'ZPD';
    select id into i_e from erp.item where tenant_id = rb.tenant_id and code = 'ZPE';
    select id into i_f from erp.item where tenant_id = rb.tenant_id and code = 'ZPF';
    select id into i_z from erp.item where tenant_id = rb.tenant_id and code = 'ZPZ';
    select id into i_g from erp.item where tenant_id = rb.tenant_id and code = 'ZPG';

    v_step := 'the rules that say where each belongs';
    perform erp.create_storage_rule(v_site, v_small,    'putaway', i_a, null, 10);
    perform erp.create_storage_rule(v_site, v_big,      'putaway', i_a, null, 20);
    perform erp.create_storage_rule(v_site, v_ruleonly, 'putaway', i_b, null, 10, 10);
    perform erp.create_storage_rule(v_site, v_big,      'putaway', i_b, null, 20);
    perform erp.create_storage_rule(v_site, v_part,     'putaway', i_c, null, 10);
    perform erp.create_storage_rule(v_site, v_big,      'putaway', i_c, null, 20);
    perform erp.create_storage_rule(v_site, v_promised, 'putaway', i_d, null, 10);
    perform erp.create_storage_rule(v_site, v_big,      'putaway', i_d, null, 20);
    perform erp.create_storage_rule(v_site, v_free,     'putaway', i_e, null, 10);

    v_step := 'a receipt into goods-in, sixty already standing in the part-filled bay, one on the pick face';
    v_doc := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    v_line := erp.add_document_line(v_doc, i_a, 100, 1000, 'arrives');
    update erp.document_line set location_id = v_recv where id = v_line;
    v_line := erp.add_document_line(v_doc, i_b, 100, 1000, 'arrives');
    update erp.document_line set location_id = v_recv where id = v_line;
    v_line := erp.add_document_line(v_doc, i_c, 50, 1000, 'arrives');
    update erp.document_line set location_id = v_recv where id = v_line;
    v_line := erp.add_document_line(v_doc, i_d, 50, 1000, 'arrives');
    update erp.document_line set location_id = v_recv where id = v_line;
    v_line := erp.add_document_line(v_doc, i_e, 100, 1000, 'arrives');
    update erp.document_line set location_id = v_recv where id = v_line;
    v_line := erp.add_document_line(v_doc, i_z, 60, 1000, 'already there');
    update erp.document_line set location_id = v_part where id = v_line;
    v_line := erp.add_document_line(v_doc, i_g, 1, 1000, 'on the face');
    update erp.document_line set location_id = v_pick where id = v_line;
    perform erp.transition_document(v_doc, 'post', 'the capacity suite''s receipt');

    v_step := 'eighty already promised into the promised bay';
    insert into erp.warehouse_task (tenant_id, site_id, kind, item_id,
      from_location_id, to_location_id, quantity, status)
    values (rb.tenant_id, v_site, 'putaway', i_z, v_part, v_promised, 80, 'open');

    v_step := 'a hundred arrive at the second site, whose only bay holds five';
    v_doc := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site2);
    v_line := erp.add_document_line(v_doc, i_f, 100, 1000, 'arrives');
    update erp.document_line set location_id = v_recv2 where id = v_line;
    perform erp.transition_document(v_doc, 'post', 'the capacity suite''s second receipt');

    v_step := 'put-away is raised at both sites';
    v_raised1 := erp.raise_putaway_tasks(v_site);
    v_raised2 := erp.raise_putaway_tasks(v_site2);

    select tl.code into t_a from erp.warehouse_task t
      join erp.location tl on tl.tenant_id = t.tenant_id and tl.id = t.to_location_id
     where t.tenant_id = rb.tenant_id and t.kind = 'putaway' and t.status = 'open'
       and t.item_id = i_a and t.from_location_id = v_recv;
    select tl.code into t_b from erp.warehouse_task t
      join erp.location tl on tl.tenant_id = t.tenant_id and tl.id = t.to_location_id
     where t.tenant_id = rb.tenant_id and t.kind = 'putaway' and t.status = 'open'
       and t.item_id = i_b and t.from_location_id = v_recv;
    select tl.code into t_c from erp.warehouse_task t
      join erp.location tl on tl.tenant_id = t.tenant_id and tl.id = t.to_location_id
     where t.tenant_id = rb.tenant_id and t.kind = 'putaway' and t.status = 'open'
       and t.item_id = i_c and t.from_location_id = v_recv;
    select tl.code into t_d from erp.warehouse_task t
      join erp.location tl on tl.tenant_id = t.tenant_id and tl.id = t.to_location_id
     where t.tenant_id = rb.tenant_id and t.kind = 'putaway' and t.status = 'open'
       and t.item_id = i_d and t.from_location_id = v_recv;
    select tl.code into t_e from erp.warehouse_task t
      join erp.location tl on tl.tenant_id = t.tenant_id and tl.id = t.to_location_id
     where t.tenant_id = rb.tenant_id and t.kind = 'putaway' and t.status = 'open'
       and t.item_id = i_e and t.from_location_id = v_recv;

    select count(*) into v_f_tasks from erp.warehouse_task t
     where t.tenant_id = rb.tenant_id and t.kind = 'putaway' and t.item_id = i_f;
    select coalesce(sum(sb.quantity), 0) into v_f_standing from erp.stock_balance sb
     where sb.tenant_id = rb.tenant_id and sb.item_id = i_f and sb.location_id = v_recv2;

    v_step := 'what could not be put away is asked for';
    select count(*), min(h.reason) into v_holds2, v_holds2_reason
      from erp.putaway_holds(v_site2) h;
    select count(*) into v_holds1 from erp.putaway_holds(v_site) h;

    v_step := 'the room the pick face has, and what replenishment reads';
    v_room_pick := erp.place_room(v_pick, null);
    v_room_free := erp.place_room(v_free, null);
    v_replen_reads := position('erp.place_room(' in
      pg_catalog.pg_get_functiondef('erp.raise_replenishment_tasks(uuid)'::regprocedure)) > 0;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_left := exists (select 1 from erp.tenant t where t.code = 'zzpac-' || v_tag);

  -- 1
  case_name := 'a place that cannot hold what is arriving is skipped for the next rule''s place';
  passed := v_state is null and t_a = 'ZP-B-BIG';
  detail := coalesce(v_state, 'a hundred, offered a bay holding ten, went to ' || coalesce(t_a, 'nowhere'));
  return next;

  -- 2
  case_name := 'a rule''s own fill-to limit is obeyed where the place itself states none';
  passed := v_state is null and t_b = 'ZP-B-BIG';
  detail := coalesce(v_state, 'a hundred, offered a bay capped at ten by its rule, went to ' || coalesce(t_b, 'nowhere'));
  return next;

  -- 3
  case_name := 'what is already standing in the place counts against what it holds';
  passed := v_state is null and t_c = 'ZP-B-BIG';
  detail := coalesce(v_state, 'fifty, offered a bay holding a hundred with sixty in it, went to ' || coalesce(t_c, 'nowhere'));
  return next;

  -- 4
  case_name := 'what an open task already promises to bring counts as standing there';
  passed := v_state is null and t_d = 'ZP-B-BIG';
  detail := coalesce(v_state, 'fifty, offered a bay holding a hundred with eighty promised, went to ' || coalesce(t_d, 'nowhere'));
  return next;

  -- 5
  case_name := 'a place that states no limit at all still takes everything';
  passed := v_state is null and t_e = 'ZP-E-FREE' and v_raised1 = 5;
  detail := coalesce(v_state, format('a hundred went to %s, and the run raised %s task(s)',
                                     coalesce(t_e, 'nowhere'), coalesce(v_raised1::text, 'no')));
  return next;

  -- 6
  case_name := 'when nowhere has room the goods stay in goods-in and no task is raised';
  passed := v_state is null and v_raised2 = 0 and v_f_tasks = 0 and v_f_standing = 100;
  detail := coalesce(v_state, format('the run raised %s, %s task(s) exist and %s are still in goods-in',
                                     coalesce(v_raised2::text, 'nothing'),
                                     coalesce(v_f_tasks::text, '?'), coalesce(v_f_standing::text, '?')));
  return next;

  -- 7
  case_name := 'what could not be put away is named with its reason, and a site that was placed names nothing';
  passed := v_state is null and v_holds2 = 1 and v_holds2_reason = 'nowhere_has_room' and v_holds1 = 0;
  detail := coalesce(v_state, format('%s held at the second site (%s), %s at the first',
                                     coalesce(v_holds2::text, '?'), coalesce(v_holds2_reason, 'no reason'),
                                     coalesce(v_holds1::text, '?')));
  return next;

  -- 8
  case_name := 'a pick face at what it holds has no room, a place that states nothing has no limit, and replenishment reads both';
  passed := v_state is null and v_room_pick = 0 and v_room_free is null and coalesce(v_replen_reads, false);
  detail := coalesce(v_state, format('pick face room %s, free bay room %s, replenishment reads the room routine: %s',
                                     coalesce(v_room_pick::text, 'null'),
                                     coalesce(v_room_free::text, 'null'),
                                     coalesce(v_replen_reads::text, 'unknown')));
  return next;

  -- 9
  case_name := 'the suite leaves nothing behind';
  passed := not coalesce(v_left, true);
  detail := 'an organisation, two sites, ten places, eight products, nine rules and a receipt rolled back';
  return next;
end;
$$;
revoke all on function erp_test.putaway_capacity_suite() from public, anon, authenticated;

comment on function erp_test.putaway_capacity_suite() is
  'Put-away against what a place holds: a bay too small, a rule''s own limit, '
  'what is standing there, what is promised there, a place that states nothing, '
  'and a site where nowhere has room — where the goods stay in goods-in and '
  'erp.putaway_holds() names them. Rolls back everything it made.';

create or replace function erp_test.assert_putaway_capacity_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _putaway_capacity on commit drop as
    select * from erp_test.putaway_capacity_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _putaway_capacity;
  drop table _putaway_capacity;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PUTAWAY_CAPACITY_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_PUTAWAY_CAPACITY_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read the failed case before the code: a place that says what it holds is being sent more than that, or a position nowhere has room for is not being named.';
  end if;
  return format('put-away capacity: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_putaway_capacity_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_resource_coverage('en');
select erp.assert_diagnostics_registered();
select erp.assert_suite_verdicts_strict();

select erp.assert_write_only_columns();
select erp_test.assert_write_only_column_suite();
select erp_test.assert_putaway_capacity_suite();
