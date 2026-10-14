-- A short pick is recorded where it was short.
--
-- Theme 4, phones and scanners (owner, 14 October 2026). The scanner's task
-- register has a Short pick ("A pick cannot be completed in full"; "Not
-- abandonable: a short pick not recorded leaves an order nobody knows is
-- short"), and no function applied it: its handler said "nothing yet records
-- the shortage against the line it was short on". So a picker who found two
-- where the book said ten could only pick nothing, or pick the two by hand
-- and leave the book saying the bin still held eight, which the next pick
-- would be sent to.
--
-- ── DECISIONS (taken under the owner's standing approval) ───────────────────
--
--   * What was found is picked; what was not is the order line's unmet
--     quantity, with the cause short_pick, as an allocation the stock could
--     not cover already says.
--   * The shortage is a record of its own, kept as it was written: the
--     reservation, the order line, the place, what the book held there, what
--     was found, what was short, why, and who said so.
--   * A place a picker found short is not offered to another pick of that
--     product until it has been counted. No stock is moved to say so: the
--     book is what is in question, and the count is what settles it. A count
--     of the place and product finished after the shortage closes it.
--   * The count itself is raised by whoever may count, from the list of short
--     picks to count; a picker on the scanner usually may not, and a short
--     pick refused for want of that permission is the order nobody knows is
--     short.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.pick_shortage, append-only, and erp.place_found_short().
--   B. erp_record_short_pick, and the scanner's Short pick applied by it.
--   C. erp.commit_allocation does not offer a place found short and not yet
--      counted, and takes a scanner's confirmation for a short pick as it
--      does for a pick.
--   D. erp_pick_shortages lists them, those still to count first.
--   E. erp_test.short_pick_suite proves A to D.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The record
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.pick_shortage (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  allocation_id     uuid not null,
  document_id       uuid,
  document_line_id  uuid,
  item_id           uuid not null,
  site_id           uuid not null,
  location_id       uuid not null,
  batch_id          uuid,
  quantity_booked   numeric(20,6) not null,
  quantity_found    numeric(20,6) not null,
  quantity_short    numeric(20,6) not null,
  reason            text not null,
  recorded_by       uuid,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  constraint pick_shortage_tenant_id_id_key unique (tenant_id, id),
  constraint pick_shortage_allocation_fk foreign key (tenant_id, allocation_id)
    references erp.allocation(tenant_id, id) on delete restrict,
  constraint pick_shortage_item_fk foreign key (tenant_id, item_id) references erp.item(tenant_id, id) on delete restrict,
  constraint pick_shortage_location_fk foreign key (tenant_id, location_id)
    references erp.location(tenant_id, id) on delete restrict,
  constraint pick_shortage_quantities check (quantity_found >= 0 and quantity_short > 0 and quantity_booked >= 0),
  constraint pick_shortage_said check (btrim(reason) <> '')
);
create index if not exists pick_shortage_place on erp.pick_shortage (tenant_id, location_id, item_id, created_at);

comment on table erp.pick_shortage is
  'A pick found short (20261014020000): the reservation, the order line, the place, what the book held there, what '
  'was found, what was short and why. Kept as written; a count of the place and product afterwards closes it.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'pick_shortage', 'tenant_scoped_append_only', 'A pick found short, kept as the picker recorded it.')
on conflict (schema_name, table_name) do nothing;

-- Whether a place was found short of a product and has not been counted
-- since: a count of that place and product finished after the shortage.
create or replace function erp.place_found_short(p_location_id uuid, p_item_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from erp.pick_shortage ps
     where ps.tenant_id = erp.require_tenant_id()
       and ps.location_id = p_location_id and ps.item_id = p_item_id
       and not exists (
         select 1 from erp.count_task ct
          where ct.tenant_id = ps.tenant_id and ct.location_id = ps.location_id and ct.item_id = ps.item_id
            and ct.status in ('counted', 'pending_approval', 'approved', 'posted')
            and ct.counted_at > ps.created_at))
$$;
revoke all on function erp.place_found_short(uuid, uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Recording it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.record_short_pick(p_allocation_id uuid, p_location_id uuid, p_quantity_found numeric,
                                                 p_reason text, p_batch_id uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  al       erp.allocation%rowtype;
  v_wanted numeric;
  v_booked numeric;
  v_short  numeric;
  v_id     uuid;
begin
  select * into al from erp.allocation where tenant_id = v_tenant and id = p_allocation_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_ALLOCATION: %', p_allocation_id using errcode = '23503',
      hint = 'The reservation does not exist in this organisation.';
  end if;
  -- Confirmed on the scanner as a pick is (20260915011000).
  if erp.scan_confirms('sales.despatch', array['short_pick'], al.entity_id, al.site_id) then
    perform erp.authorise('inventory.scan', al.entity_id, al.site_id, null, 'allocation', p_allocation_id, null);
  else
    perform erp.authorise('sales.despatch', al.entity_id, al.site_id, null, 'allocation', p_allocation_id, null);
  end if;
  if al.status <> 'reserved' then
    raise exception 'CLOVEERP_ALLOCATION_NOT_RESERVED: % is %', p_allocation_id, al.status
      using errcode = '23514',
            hint = 'Only a reservation still to pick can be found short; a committed or cancelled allocation is not picked again.';
  end if;
  if not exists (select 1 from erp.location l where l.tenant_id = v_tenant and l.id = p_location_id and l.site_id = al.site_id) then
    raise exception 'CLOVEERP_UNKNOWN_LOCATION: % is no place at the site this reservation is for', p_location_id
      using errcode = '23503', hint = 'Scan the place the pick was short at.';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'CLOVEERP_SHORT_PICK_UNSAID: a short pick needs a reason'
      using errcode = '23514', hint = 'Say what was found: an empty place, damaged stock, the wrong product.';
  end if;

  v_wanted := al.quantity - coalesce(al.unmet_quantity, 0);
  if p_quantity_found is null or p_quantity_found < 0 or p_quantity_found >= v_wanted then
    raise exception 'CLOVEERP_SHORT_PICK_NOT_SHORT: % of % is not short', coalesce(p_quantity_found::text, 'nothing'), v_wanted
      using errcode = '23514', hint = 'Give what was found, less than the pick asked for; a pick found in full is confirmed as a pick.';
  end if;
  v_short := v_wanted - p_quantity_found;

  select coalesce(sum(b.quantity), 0) into v_booked
    from erp.stock_balance b
   where b.tenant_id = v_tenant and b.location_id = p_location_id and b.item_id = al.item_id
     and b.stock_status = 'available' and (p_batch_id is null or b.batch_id = p_batch_id);

  -- What was found is picked from the place it was found; the rest is unmet,
  -- as stock that could not cover an allocation already is.
  update erp.allocation
     set unmet_quantity = coalesce(unmet_quantity, 0) + v_short, unmet_cause = 'short_pick', updated_at = now()
   where id = al.id;
  if p_quantity_found > 0 then
    perform erp.commit_allocation(al.id, p_location_id, p_batch_id);
  else
    update erp.allocation set status = 'released', updated_at = now() where id = al.id;
  end if;

  insert into erp.pick_shortage (tenant_id, allocation_id, document_id, document_line_id, item_id, site_id, location_id,
                                 batch_id, quantity_booked, quantity_found, quantity_short, reason, recorded_by)
  values (v_tenant, al.id, al.document_id, al.document_line_id, al.item_id, al.site_id, p_location_id, p_batch_id,
          v_booked, p_quantity_found, v_short, btrim(p_reason), erp.current_principal_id())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function erp.record_short_pick(uuid, uuid, numeric, text, uuid) from public, anon;

create or replace function public.erp_record_short_pick(p_allocation_id uuid, p_location_id uuid, p_quantity_found numeric,
                                                        p_reason text, p_batch_id uuid default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.record_short_pick(p_allocation_id, p_location_id, p_quantity_found, p_reason, p_batch_id) $$;
revoke all on function public.erp_record_short_pick(uuid, uuid, numeric, text, uuid) from public, anon;
grant execute on function public.erp_record_short_pick(uuid, uuid, numeric, text, uuid) to authenticated, service_role;
comment on function public.erp_record_short_pick(uuid, uuid, numeric, text, uuid) is
  'Records a pick found short at a place: what was found is picked, the rest is the line''s unmet quantity, and the '
  'place is not offered again for the product until it is counted (20261014020000). Authorises sales.despatch, or '
  'inventory.scan for a short pick confirmed on the scanner.';

-- The scanner's Short pick, applied (it was "nothing yet records the
-- shortage against the line it was short on").
update erp_ref.device_task_handler
   set module_code = 'sales',
       sql_function = 'record_short_pick',
       arguments = '[{"arg":"p_allocation_id","key":"allocation_id","type":"uuid","required":true},
                     {"arg":"p_location_id","key":"location_id","type":"uuid","required":true},
                     {"arg":"p_quantity_found","key":"quantity","type":"numeric","required":true},
                     {"arg":"p_reason","key":"reason","type":"text","required":true},
                     {"arg":"p_batch_id","key":"batch_id","type":"uuid"}]'::jsonb,
       not_handled_reason = null,
       note = 'Outbound. The place, then what was found there and why it was short: what was found is picked, the rest is the line''s unmet quantity, and the place is not offered again for the product until it is counted.'
 where device_task_code = 'short_pick';

-- A scanner confirms a short pick as it confirms a pick.
create or replace function erp.scan_confirmable_tasks()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['count', 'putaway', 'replenishment', 'pick', 'short_pick', 'receipt']::text[]
$$;

-- The drain suite counts the register: one more applies, one fewer waits.
do $drain$
declare
  v_sig  constant text := 'erp_test.device_drain_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$'%23 task(s) — 19 apply%1 read only, 3 not yet handled%'$o$;
  v_new  constant text := $n$'%23 task(s) — 20 apply%1 read only, 2 not yet handled%'$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % handler count anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$drain$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A place found short is not offered again until it is counted
-- ─────────────────────────────────────────────────────────────────────────────

do $commit$
declare
  v_sig   constant text := 'erp.commit_allocation(uuid,uuid,uuid)';
  v_def   text := pg_get_functiondef(v_sig::regprocedure);
  v_old1  constant text := $o$  if erp.scan_confirms('sales.despatch', array['pick'], al.entity_id, al.site_id) then$o$;
  v_new1  constant text := $n$  if erp.scan_confirms('sales.despatch', array['pick', 'short_pick'], al.entity_id, al.site_id) then$n$;
  v_old2  constant text := $o$       and l.status = 'active' and not l.is_blocked
$o$;
  v_new2  constant text := $n$       and l.status = 'active' and not l.is_blocked
       -- Not a place found short of it and not counted since (20261014020000).
       and not erp.place_found_short(b.location_id, al.item_id)
$n$;
  v_hits integer;
begin
  if position('20261014020000' in v_def) > 0 then
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % scanner anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 2 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % place anchor found % time(s), expected 2', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$commit$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The list
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_pick_shortages(p_limit integer default 200)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x ->> 'to_count')::boolean desc, x ->> 'recorded_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'pick_shortage_id', ps.id, 'item', i.code, 'item_name', i.name, 'site', s.code, 'location', l.code,
             'location_id', ps.location_id, 'item_id', ps.item_id,
             'order_number', d.document_number, 'quantity_booked', ps.quantity_booked,
             'quantity_found', ps.quantity_found, 'quantity_short', ps.quantity_short, 'reason', ps.reason,
             'recorded_at', ps.created_at,
             'to_count', erp.place_found_short(ps.location_id, ps.item_id)) as x
      from erp.pick_shortage ps
      join erp.item i on i.tenant_id = ps.tenant_id and i.id = ps.item_id
      join erp.site s on s.tenant_id = ps.tenant_id and s.id = ps.site_id
      join erp.location l on l.tenant_id = ps.tenant_id and l.id = ps.location_id
      left join erp.document d on d.tenant_id = ps.tenant_id and d.id = ps.document_id
     where ps.tenant_id = erp.require_tenant_id()
     order by ps.created_at desc
     limit greatest(coalesce(p_limit, 200), 1)) t
$$;
revoke all on function public.erp_pick_shortages(integer) from public, anon;
grant execute on function public.erp_pick_shortages(integer) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- Governance
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_record_short_pick', 'erp.record_short_pick',
   'Records a pick found short at a place; authorises sales.despatch, or inventory.scan on the scanner.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- The scanner applies a short pick through erp.record_short_pick, by its
-- handler; the door is for a device kit or integration that calls it direct.
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_record_short_pick', 'device', null,
   'The scanner''s Short pick reaches erp.record_short_pick through erp_record_device_action and the drain; this is the direct form a device kit calls.')
on conflict (function_name) do update set caller = excluded.caller, reason = excluded.reason;

select erp.register_refusal('CLOVEERP_SHORT_PICK_UNSAID',
  'Recording a short pick without saying why.',
  'Whoever counts the place reads what the picker found; a shortage with no reason tells them nothing.',
  'Say what was found: an empty place, damaged stock, the wrong product.');
select erp.register_refusal('CLOVEERP_SHORT_PICK_NOT_SHORT',
  'Recording a short pick for as much as the pick asked for, or more, or less than nothing.',
  'A pick found in full is a pick; recording it as short would hold a place that is right.',
  'Give what was found, less than the pick asked for; a pick found in full is confirmed as a pick.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Short picks (20261014020000).'
  from (values
    ('Short picks'),
    ('Places a picker found short, and what was found. A place is not offered to another pick of the product until it is counted: raise a count for it under Stock audit.'),
    ('No pick has been found short. A picker records one on the scanner when a place holds less than the book says.'),
    ('Booked'),
    ('Found'),
    ('Short'),
    ('To count')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.short_pick_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_entity uuid;
  v_site   uuid;
  v_uom    uuid;
  v_sup    uuid;
  v_cus    uuid;
  v_item   uuid;
  v_grn    uuid;
  v_bin_a  uuid;
  v_bin_b  uuid;
  v_so     uuid;
  v_line   uuid;
  v_alloc  uuid;
  v_alloc2 uuid;
  v_ok     boolean;
  v_msg    text;
  x        jsonb;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzshp' || v_tag, 'Short Pick Suite',
      'admin@demo-zzshp' || v_tag || '.test', 'Short Pick Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzshp' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    v_step := 'ten widgets booked in bin A, and ten in bin B';
    select s.id, s.entity_id into v_site, v_entity from erp.site s where s.tenant_id = v_tenant and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (v_tenant, 'ZSHPS' || upper(v_tag), 'Short Pick Supplier', 'GB', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status) values (v_tenant, v_sup, 'supplier', 'active');
    select p.id into v_cus from erp.party p join erp.party_role r on r.tenant_id = p.tenant_id and r.party_id = p.id
     where p.tenant_id = v_tenant and r.role_kind = 'customer' and r.status = 'active' and p.status = 'active'
     order by p.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZSHP' || v_tag, 'Short Pick Widget', v_uom, 'active') returning id into v_item;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status, is_pickable)
    values (v_tenant, v_site, 'ZSA' || upper(v_tag), 'Bin A', 'pick', 'active', true) returning id into v_bin_a;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status, is_pickable)
    values (v_tenant, v_site, 'ZSB' || upper(v_tag), 'Bin B', 'pick', 'active', true) returning id into v_bin_b;
    -- Received into the two bins, ten each; bin A's first, so it is picked first.
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.set_line_stock_identity(erp.add_document_line(v_grn, v_item, 10, 500, 'widgets'), null, v_bin_a, null);
    perform erp.transition_document(v_grn, 'post');
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.set_line_stock_identity(erp.add_document_line(v_grn, v_item, 10, 500, 'widgets'), null, v_bin_b, null);
    perform erp.transition_document(v_grn, 'post');

    v_step := 'an order for six, reserved';
    v_so := erp.open_document('sales_order', v_cus, v_entity, v_site);
    v_line := erp.add_document_line(v_so, v_item, 6, 900, 'widgets');
    v_alloc := erp.reserve_for_line(v_line, null);

    -- ── 1. Refused ──────────────────────────────────────────────────────────
    v_step := 'short picks refused';
    begin
      perform public.erp_record_short_pick(v_alloc, v_bin_a, 2, '   ');
      v_ok := false; v_msg := 'a short pick with no reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SHORT_PICK_UNSAID%'; v_msg := left(sqlerrm, 60);
    end;
    begin
      perform public.erp_record_short_pick(v_alloc, v_bin_a, 6, 'all there');
      v_ok := false; v_msg := v_msg || ' | a short pick found in full';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_SHORT_PICK_NOT_SHORT%'; v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    v_cases := v_cases + 1;
    case_name := 'a short pick needs a reason, and to be short';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. Two found of six ─────────────────────────────────────────────────
    v_step := 'two found in bin A';
    perform public.erp_record_short_pick(v_alloc, v_bin_a, 2, 'only two in the bin');
    v_cases := v_cases + 1;
    case_name := 'the two found are picked from bin A, the four not found are the line''s unmet quantity';
    passed := v_state is null
          and (select a.status::text from erp.allocation a where a.id = v_alloc) = 'committed'
          and (select a.unmet_quantity from erp.allocation a where a.id = v_alloc) = 4
          and (select a.unmet_cause from erp.allocation a where a.id = v_alloc) = 'short_pick'
          and (select sum(l.quantity) from erp.allocation_line l where l.allocation_id = v_alloc and l.location_id = v_bin_a) = 2;
    detail := coalesce(v_state, (select format('%s, unmet %s', a.status, a.unmet_quantity) from erp.allocation a where a.id = v_alloc));
    return next;

    -- ── 3. Recorded ─────────────────────────────────────────────────────────
    x := public.erp_pick_shortages();
    v_cases := v_cases + 1;
    case_name := 'the shortage is recorded with what the book held, what was found and why, and is listed to count';
    passed := v_state is null
          and jsonb_array_length(x) = 1
          and (x -> 0 ->> 'quantity_booked')::numeric = 10
          and (x -> 0 ->> 'quantity_found')::numeric = 2
          and (x -> 0 ->> 'quantity_short')::numeric = 4
          and x -> 0 ->> 'reason' = 'only two in the bin'
          and (x -> 0 ->> 'to_count')::boolean;
    detail := coalesce(v_state, left(x::text, 240));
    return next;

    -- ── 4. Not offered again ────────────────────────────────────────────────
    v_step := 'another order, for three';
    v_line := erp.add_document_line(v_so, v_item, 3, 900, 'more widgets');
    v_alloc2 := erp.reserve_for_line(v_line, null);
    perform erp.commit_allocation(v_alloc2);
    v_cases := v_cases + 1;
    case_name := 'the next pick of the product is sent to bin B, not to bin A, which is still to count';
    passed := v_state is null
          and not exists (select 1 from erp.allocation_line l where l.allocation_id = v_alloc2 and l.location_id = v_bin_a)
          and (select sum(l.quantity) from erp.allocation_line l where l.allocation_id = v_alloc2 and l.location_id = v_bin_b) = 3;
    detail := coalesce(v_state, (select string_agg(l.location_id::text || ':' || l.quantity, ', ')
                                   from erp.allocation_line l where l.allocation_id = v_alloc2));
    return next;

    -- ── 5. Counted, and offered again ───────────────────────────────────────
    v_step := 'bin A counted';
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id, expected_quantity,
                                counted_quantity, status, counted_at)
    select v_tenant, cp.id, v_site, v_bin_a, v_item, 10, 2, 'counted', now() + interval '1 second'
      from erp.count_programme cp where cp.tenant_id = v_tenant order by cp.code limit 1;
    v_cases := v_cases + 1;
    case_name := 'once the place is counted, it is offered again and listed as counted';
    passed := v_state is null
          and not erp.place_found_short(v_bin_a, v_item)
          and not (public.erp_pick_shortages() -> 0 ->> 'to_count')::boolean;
    detail := coalesce(v_state, public.erp_pick_shortages()::text);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_SHORT_PICK_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.short_pick_suite() from public, anon, authenticated;

create or replace function erp_test.assert_short_pick_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _short_pick on commit drop as
    select * from erp_test.short_pick_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _short_pick;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SHORT_PICK_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_SHORT_PICK_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('short pick: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_short_pick_suite() from public, anon, authenticated;

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
select erp.assert_write_only_columns();
select erp.assert_device_task_handlers_sound();
