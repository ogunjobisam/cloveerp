set lock_timeout = '30s';

-- =============================================================================
-- 20261002400000  A shipment is a document, and ships in one press
-- -----------------------------------------------------------------------------
-- LPR2 of docs/spec/logistics-target-flow.md: nodes L3 and L4.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A shipment was a side table with a status enum of eight values, four of
-- which nothing reached, moved by whichever routine last wrote the column. It
-- had no number anybody could quote (SH- and the clock), no lifecycle the
-- register could hold to its drivers, and despatch took four presses: plan,
-- select a carrier, book, proof. Selecting a carrier re-typed nothing it did
-- not already know, and booking asked the planner to type the service and
-- the cost the rate card had just priced.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * L3. The shipment is a document on base type `shipment`, numbered SHP-
--     when it is opened, with the lifecycle planned → booked → delivered, and
--     cancelled from planned or booked. It is configuration: installed by
--     erp.configure_logistics() for a new organisation, and offered as
--     version 2 of the logistics installer to one that has logistics. A
--     demonstration takes the upgrade in its catch-up; a live organisation's
--     administrator promotes it, and until then the ship door says so.
--   * erp.shipment stays, as the document's detail: carrier, weights, freight
--     and proof. Its status is a mirror kept by erp.mirror_shipment_status()
--     after each move, and nothing else writes it on a shipment that has a
--     document. tendered, despatched and exception are reached by nothing.
--   * L4. erp_ship_deliveries(): one press from posted deliveries. The
--     shipment is opened from them — one site, one customer — and takes the
--     carrier and service erp.select_carrier() recommends, priced by the rate
--     card, unless the planner names others or a cost. When a tariff or a
--     cost is known it is booked in the same statement; when neither is, it
--     is left planned rather than refused.
--   * The old doors stay, routed onto the document: Plan opens one, Book
--     books it. The Despatch strip no longer draws them (a decision of
--     29 September: kept one release for what calls them).
--   * Proof of delivery moves the document to delivered. erp_cancel_shipment()
--     cancels a planned or booked one and releases its deliveries.
--   * The despatch step budget is two.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * Flagging a cost typed above the rate card, the exceptions screen, and
--     "on its way" and "late": LPR3, with logistics.shipping_policy. The rate
--     card's price stays derivable from erp.select_carrier() for that.
--   * A shipment raised before this migration has no document. It keeps its
--     status and can be cancelled, which releases its deliveries to ship
--     again; it cannot be booked or delivered on the spine.
--
-- Proof: erp_test.shipment_document_suite (11 cases).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_SHIPMENT_NOT_INSTALLED',
  'Shipping deliveries in an organisation whose logistics module has no shipment document.',
  'The shipment became a document with version 2 of the logistics module, and an organisation on version 1 has nowhere to put one.',
  'Upgrade the logistics module from Administration, Configuration, then ship the deliveries.');

select erp.register_refusal('CLOVEERP_DELIVERY_NOT_SHIPPABLE',
  'Shipping something that is not a posted delivery, or a delivery a shipment still carries.',
  'A shipment carries goods that have left stock, once: a draft delivery has moved nothing, and one already on a shipment would travel twice.',
  'Pick the deliveries from Despatch: it lists the posted ones no shipment carries.');

select erp.register_refusal('CLOVEERP_SHIPMENT_MIXED_SITES',
  'Shipping deliveries from more than one site on one shipment.',
  'A shipment leaves from one site; a lorry that collects at two is two shipments.',
  'Ship each site''s deliveries on their own.');

select erp.register_refusal('CLOVEERP_SHIPMENT_DELIVERED',
  'Cancelling a shipment that has been delivered.',
  'Delivered is where a shipment ends: its proof is signed, and the goods are with the customer.',
  'Nothing to cancel. A return comes back as a return, on the sales side.');

select erp.register_refusal('CLOVEERP_SHIPMENT_BEFORE_THE_SPINE',
  'Booking or delivering a shipment raised before shipments were documents.',
  'It has no document, so there is no lifecycle to move it along (20261002400000).',
  'Cancel it, which releases its deliveries, and ship them again.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The base type, and its words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.document_type
  (code, name_key, module_code, flow, affects_stock, affects_finance, requires_party,
   requires_site, description, create_permission)
values
  ('shipment', 'document.shipment', 'logistics', 'outbound', false, false, true, true,
   'A shipment: posted deliveries of one site to one customer, booked with a carrier at a cost and '
   'signed for on arrival. Opened by erp.ship_deliveries(); its detail is erp.shipment. It moves no '
   'stock, which the deliveries moved, and posts nothing (20261002400000).',
   'logistics.plan')
on conflict (code) do update
  set name_key = excluded.name_key, module_code = excluded.module_code, flow = excluded.flow,
      affects_stock = excluded.affects_stock, affects_finance = excluded.affects_finance,
      requires_party = excluded.requires_party, requires_site = excluded.requires_site,
      description = excluded.description, create_permission = excluded.create_permission;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('document.shipment', 'en', 'Shipment', 'logistics', 'Document base type name (20261002400000).'),
  ('document.shipment', 'de', 'Sendung', 'logistics', null)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The lifecycle, numbering and type, as configuration
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.shipment_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The shipment (20261002400000), read by erp.configure_logistics() for a new
  -- install and by the upgrade register for an organisation on version 1, so
  -- the two cannot disagree. The lifecycle and the sequence before the type
  -- that names them.
  --
  -- Booked is the commitment: the carrier has been told. Delivered is terminal. Cancelled is reached from
  -- either and releases the deliveries.
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'shipment', 'payload',
      jsonb_build_object(
        'code', 'shipment', 'object_type', 'document', 'name', 'Shipment',
        'states', jsonb_build_array(
          jsonb_build_object('code','planned','name','Planned','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','booked','name','Booked','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',20),
          jsonb_build_object('code','delivered','name','Delivered','is_initial',false,'is_terminal',true,'is_committed',true,'sort_order',30),
          jsonb_build_object('code','cancelled','name','Cancelled','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',90)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','book','name','Book','from','planned','to','booked','required_permission','logistics.plan','sort_order',10),
          jsonb_build_object('code','deliver','name','Deliver','from','booked','to','delivered','required_permission','logistics.despatch','sort_order',20),
          jsonb_build_object('code','cancel','name','Cancel','from','planned','to','cancelled','required_permission','logistics.plan','sort_order',90),
          jsonb_build_object('code','cancel_booked','name','Cancel','from','booked','to','cancelled','required_permission','logistics.plan','sort_order',91)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'shipment', 'payload',
      jsonb_build_object('code','shipment','prefix','SHP-','pad_to',6,
                         'reset_period','never','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'shipment', 'payload',
      jsonb_build_object('code','shipment','base_type','shipment',
                         'name','Shipment','numbering_rule','shipment',
                         'state_machine','shipment',
                         'create_permission','logistics.plan')))
$$;

comment on function erp.shipment_pack_items() is
  'The shipment (20261002400000): its lifecycle, numbering rule and document type, the items '
  'erp.configure_logistics() and the logistics upgrade register both read.';

do $configure$
declare
  v_sig constant text := 'erp.configure_logistics()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$'base_minor',25000,'per_kg_minor',400))))));$o$;
  v_new constant text := $n$'base_minor',25000,'per_kg_minor',400)))))
      -- The shipment document (20261002400000), from its one helper.
      || erp.shipment_pack_items());$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % carrier list anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

update erp_ref.module_installer
   set current_version = 2,
       description = description
         || ' Version 2 (20261002400000): the shipment as a document, numbered SHP- and moved '
         || 'planned, booked, delivered or cancelled.'
 where install_code = 'logistics' and current_version = 1;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'logistics', 2, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       100 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.shipment_pack_items()) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'logistics') is distinct from 2 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the logistics installer is not at version 2';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'logistics' and ui.to_version = 2) <> 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 2 of logistics is not the three items the shipment ships';
  end if;
end
$register$;

-- The demonstration takes it before it trades, as it takes the others.
do $catch_up$
declare
  v_src  text := pg_get_functiondef('erp.demonstration_catch_up()'::regprocedure);
  v_old  text := E'  -- ── The rules an upgrade skipped (20261002300000) ─────────────────────────\n';
  v_new  text :=
      E'  -- ── Logistics'' newer version (20261002400000) ─────────────────────────────\n'
   || E'  --\n'
   || E'  -- Version 2 is the shipment as a document: a demonstration that installed\n'
   || E'  -- logistics before it cannot ship until it has it.\n'
   || E'  begin\n'
   || E'    if exists (select 1 from erp.module_installation i\n'
   || E'                where i.tenant_id = v_tenant and i.install_code = ''logistics'') then\n'
   || E'      if exists (select 1 from erp.plan_module_upgrade(''logistics'')) then\n'
   || E'        perform erp.upgrade_module_configuration(''logistics'');\n'
   || E'        v_notes := v_notes || to_jsonb(format(\n'
   || E'          ''Logistics was upgraded to version %s.'',\n'
   || E'          (select mi.current_version from erp_ref.module_installer mi\n'
   || E'            where mi.install_code = ''logistics'')));\n'
   || E'      end if;\n'
   || E'    end if;\n'
   || E'  exception when others then\n'
   || E'    v_notes := v_notes || to_jsonb(format(\n'
   || E'      ''Logistics was not upgraded, so it cannot ship: %s'', sqlerrm));\n'
   || E'  end;\n'
   || E'\n'
   || v_old;
begin
  if (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.demonstration_catch_up''s skipped-rules marker is not where 20261002400000 expects it';
  end if;
  execute replace(v_src, v_old, v_new);
end
$catch_up$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The shipment's document, and the mirror of its state
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.shipment add column if not exists document_id uuid;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'shipment_tenant_id_document_id_fkey') then
    alter table erp.shipment
      add constraint shipment_tenant_id_document_id_fkey
      foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'shipment_tenant_id_document_id_key') then
    alter table erp.shipment
      add constraint shipment_tenant_id_document_id_key unique (tenant_id, document_id);
  end if;
end
$fk$;

comment on column erp.shipment.document_id is
  'The shipment''s document (20261002400000): its number and its lifecycle. Null only on a shipment '
  'raised before shipments were documents.';

create or replace function erp.mirror_shipment_status(p_shipment_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  -- erp.shipment.status is the document's state, kept here for what reads the
  -- column (20261002400000). The only writer on a shipment with a document,
  -- after each move, as erp.move_count_task() keeps count_task.status.
  update erp.shipment sh
     set status = s.code::erp.shipment_status, updated_at = now()
    from erp.object_state os
    join erp.state s on s.tenant_id = os.tenant_id and s.id = os.current_state_id
   where sh.tenant_id = erp.require_tenant_id() and sh.id = p_shipment_id
     and os.tenant_id = sh.tenant_id and os.object_type = 'document' and os.object_id = sh.document_id
     and sh.status is distinct from s.code::erp.shipment_status;
end;
$$;

revoke all on function erp.mirror_shipment_status(uuid) from public, anon, authenticated;

comment on function erp.mirror_shipment_status(uuid) is
  'Writes erp.shipment.status from its document''s state (20261002400000). The one writer of the column '
  'on a shipment with a document.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Plan opens the document; Book books it; proof delivers it
-- ─────────────────────────────────────────────────────────────────────────────

do $plan$
declare
  v_sig constant text := 'erp.plan_shipment(uuid,uuid[],date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  update erp.shipment set status = 'planned', updated_at = now() where id = v_ship;
$o$;
  v_new constant text := $n$  update erp.shipment set status = 'planned', updated_at = now() where id = v_ship;

  -- Opened as a document where the organisation has one to open
  -- (20261002400000): numbered SHP-, moved by its lifecycle. One on
  -- logistics version 1 plans as it did.
  if exists (select 1 from erp.document_type dt
              where dt.tenant_id = v_tenant and dt.code = 'shipment' and dt.status = 'active') then
    update erp.shipment sh
       set document_id = erp.create_document(
             'shipment', sh.entity_id, sh.site_id, sh.destination_party_id, sh.planned_despatch,
             (select e.base_currency from erp.entity e where e.tenant_id = v_tenant and e.id = sh.entity_id),
             null, jsonb_build_object('shipment_id', sh.id)),
           updated_at = now()
     where sh.tenant_id = v_tenant and sh.id = v_ship;
    perform erp.mirror_shipment_status(v_ship);
  end if;
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % status anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$plan$;

do $book$
declare
  v_sig constant text := 'erp.book_shipment(uuid,text,text,bigint)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  perform erp.authorise('logistics.plan', sh.entity_id, sh.site_id, null,
                        'shipment', p_shipment_id);
$o$,
    $n$  perform erp.authorise('logistics.plan', sh.entity_id, sh.site_id, null,
                        'shipment', p_shipment_id);

  -- A shipment with a document is booked from planned, and only from there
  -- (20261002400000). One raised before shipments were documents cannot be.
  if sh.document_id is null
     and exists (select 1 from erp.document_type dt
                  where dt.tenant_id = v_tenant and dt.code = 'shipment' and dt.status = 'active') then
    raise exception 'CLOVEERP_SHIPMENT_BEFORE_THE_SPINE: % was raised before shipments were documents', sh.reference
      using errcode = '23514',
            hint = 'Cancel it, which releases its deliveries, and ship them again.';
  end if;
$n$,
    $o$  -- Spec 5.9: "freight cost capture and allocation".$o$,
    $n$  -- The commitment, on the document (20261002400000).
  if sh.document_id is not null then
    perform erp.transition_document(sh.document_id, 'book', 'booked with ' || p_carrier_code);
    perform erp.mirror_shipment_status(p_shipment_id);
  end if;

  -- Spec 5.9: "freight cost capture and allocation".$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) by 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[v_i], ''))) / length(v_pairs[v_i]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, (v_i + 1) / 2, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[v_i], v_pairs[v_i + 1]);
  end loop;
  execute v_def;
end
$book$;

do $proof$
declare
  v_sig constant text := 'erp.record_proof_of_delivery(uuid,timestamp with time zone,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SHIPMENT: %', p_shipment_id using errcode = '23503';
  end if;
$o$;
  v_new constant text := $n$  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SHIPMENT: %', p_shipment_id using errcode = '23503';
  end if;

  -- Delivered, on the document (20261002400000). A shipment raised before
  -- shipments were documents cannot be.
  if (select sh.document_id from erp.shipment sh where sh.tenant_id = v_tenant and sh.id = p_shipment_id) is not null then
    perform erp.transition_document(
      (select sh.document_id from erp.shipment sh where sh.tenant_id = v_tenant and sh.id = p_shipment_id),
      'deliver', 'signed for by ' || p_signed_by);
    perform erp.mirror_shipment_status(p_shipment_id);
  elsif exists (select 1 from erp.document_type dt
                 where dt.tenant_id = v_tenant and dt.code = 'shipment' and dt.status = 'active') then
    raise exception 'CLOVEERP_SHIPMENT_BEFORE_THE_SPINE: % was raised before shipments were documents',
      (select sh.reference from erp.shipment sh where sh.tenant_id = v_tenant and sh.id = p_shipment_id)
      using errcode = '23514',
            hint = 'Cancel it, which releases its deliveries, and ship them again.';
  end if;
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % not-found anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$proof$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. Ship these deliveries: one press
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.ship_deliveries(
  p_delivery_ids     uuid[],
  p_planned_despatch date   default null,
  p_carrier_code     text   default null,
  p_service_code     text   default null,
  p_cost_minor       bigint default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_site    uuid;
  v_sites   integer;
  v_bad     text;
  v_ship    uuid;
  v_carrier text := nullif(btrim(coalesce(p_carrier_code, '')), '');
  v_service text := nullif(btrim(coalesce(p_service_code, '')), '');
  v_cost    bigint := p_cost_minor;
  o         record;
begin
  if coalesce(array_length(p_delivery_ids, 1), 0) = 0 then
    raise exception 'CLOVEERP_EMPTY_SHIPMENT: a shipment of nothing' using errcode = '23514';
  end if;

  if not exists (select 1 from erp.document_type dt
                  where dt.tenant_id = v_tenant and dt.code = 'shipment' and dt.status = 'active') then
    raise exception 'CLOVEERP_SHIPMENT_NOT_INSTALLED: this organisation''s logistics has no shipment document'
      using errcode = '23514',
            hint = 'Upgrade the logistics module from Administration, Configuration, then ship the deliveries.';
  end if;

  -- Only posted deliveries no shipment still standing carries: what the
  -- Despatch strip lists (erp_deliveries_to_ship).
  select string_agg(coalesce(d.document_number, x.id::text), ', ' order by x.id) into v_bad
    from unnest(p_delivery_ids) x(id)
    left join erp.document d on d.tenant_id = v_tenant and d.id = x.id
    left join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.object_state os on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
    left join erp.state s on s.tenant_id = os.tenant_id and s.id = os.current_state_id
   where d.id is null
      or dt.base_type_code is distinct from 'delivery'
      or coalesce(d.is_cancelled, false)
      or not coalesce(s.is_committed, false)
      or exists (select 1 from erp.shipment_line sl
                   join erp.shipment sh on sh.tenant_id = sl.tenant_id and sh.id = sl.shipment_id
                  where sl.tenant_id = v_tenant and sl.document_id = x.id
                    and sh.status <> 'cancelled');
  if v_bad is not null then
    raise exception 'CLOVEERP_DELIVERY_NOT_SHIPPABLE: % is not a posted delivery that no shipment carries', v_bad
      using errcode = '23514',
            hint = 'Pick the deliveries from Despatch: it lists the posted ones no shipment carries.';
  end if;

  select min(d.site_id::text)::uuid, count(distinct d.site_id) into v_site, v_sites
    from erp.document d
   where d.tenant_id = v_tenant and d.id = any(p_delivery_ids);
  if v_sites > 1 then
    raise exception 'CLOVEERP_SHIPMENT_MIXED_SITES: these deliveries leave from % sites', v_sites
      using errcode = '23514',
            hint = 'Ship each site''s deliveries on their own.';
  end if;

  -- Planned, as a document: plan_shipment authorises logistics.plan at the
  -- site, refuses two customers, weighs the deliveries and opens it.
  v_ship := erp.plan_shipment(v_site, p_delivery_ids, coalesce(p_planned_despatch, erp.local_today()));

  -- The carrier and service the rate card recommends, unless the planner
  -- named others: the first row erp.select_carrier() gives, which is the
  -- cheapest that arrives in time. A carrier named without a service takes
  -- that carrier's first row the same way.
  if v_service is null then
    select c.carrier_code, c.service_code, c.cost_minor into o
      from erp.select_carrier(v_ship) c
     where v_carrier is null or c.carrier_code = v_carrier
     limit 1;
    if found then
      v_carrier := o.carrier_code;
      v_service := o.service_code;
    end if;
  end if;

  -- Booked in the same statement when a tariff or a cost is known. When
  -- neither is, it is left planned, not refused.
  if v_carrier is not null and v_service is not null
     and (v_cost is not null
          or exists (select 1 from erp.select_carrier(v_ship) c
                      where c.carrier_code = v_carrier and c.service_code = v_service)) then
    perform erp.book_shipment(v_ship, v_carrier, v_service, v_cost);
  end if;

  return v_ship;
end;
$$;

revoke all on function erp.ship_deliveries(uuid[], date, text, text, bigint) from public, anon, authenticated;

comment on function erp.ship_deliveries(uuid[], date, text, text, bigint) is
  'Ships posted deliveries of one site to one customer in one press (20261002400000): opens the '
  'shipment document, takes the carrier and service the rate card recommends unless others are named, '
  'and books it when a tariff or a cost is known; otherwise it is left planned. Returns the shipment.';

create or replace function public.erp_ship_deliveries(
  p_delivery_ids     uuid[],
  p_planned_despatch date   default null,
  p_carrier_code     text   default null,
  p_service_code     text   default null,
  p_cost_minor       bigint default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.ship_deliveries(p_delivery_ids, p_planned_despatch, p_carrier_code, p_service_code, p_cost_minor) $$;

comment on function public.erp_ship_deliveries(uuid[], date, text, text, bigint) is
  'Ship these deliveries (20261002400000): the Despatch strip''s first press. erp.ship_deliveries() '
  'authorises logistics.plan at the deliveries'' site.';

revoke all on function public.erp_ship_deliveries(uuid[], date, text, text, bigint) from public, anon;
grant execute on function public.erp_ship_deliveries(uuid[], date, text, text, bigint) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. Cancelled, and its deliveries released
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.cancel_shipment(p_shipment_id uuid, p_reason text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  sh       erp.shipment%rowtype;
  v_state  text;
begin
  select * into sh from erp.shipment
   where tenant_id = v_tenant and id = p_shipment_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SHIPMENT: %', p_shipment_id using errcode = '23503';
  end if;

  perform erp.authorise('logistics.plan', sh.entity_id, sh.site_id, null, 'shipment', p_shipment_id);

  if sh.status = 'delivered' then
    raise exception 'CLOVEERP_SHIPMENT_DELIVERED: % has been delivered', coalesce(
        (select d.document_number from erp.document d where d.tenant_id = v_tenant and d.id = sh.document_id),
        sh.reference)
      using errcode = '23514',
            hint = 'Nothing to cancel. A return comes back as a return, on the sales side.';
  end if;

  if sh.document_id is null then
    -- Raised before shipments were documents: cancelled where it stands, so
    -- its deliveries can be shipped again (20261002400000).
    update erp.shipment set status = 'cancelled', updated_at = now()
     where tenant_id = v_tenant and id = p_shipment_id and status <> 'cancelled';
    return;
  end if;

  v_state := erp.object_current_state('document', sh.document_id);
  perform erp.transition_document(sh.document_id,
                                  case when v_state = 'booked' then 'cancel_booked' else 'cancel' end,
                                  coalesce(nullif(btrim(p_reason), ''), 'cancelled'));
  perform erp.mirror_shipment_status(p_shipment_id);
end;
$$;

revoke all on function erp.cancel_shipment(uuid, text) from public, anon, authenticated;

comment on function erp.cancel_shipment(uuid, text) is
  'Cancels a planned or booked shipment, which releases its deliveries to ship again (20261002400000). '
  'A delivered one is refused. One raised before shipments were documents is cancelled where it stands.';

create or replace function public.erp_cancel_shipment(p_shipment_id uuid, p_reason text default null)
returns void
language sql
set search_path = ''
as $$ select erp.cancel_shipment(p_shipment_id, p_reason) $$;

comment on function public.erp_cancel_shipment(uuid, text) is
  'Cancel a shipment and release its deliveries (20261002400000). erp.cancel_shipment() authorises '
  'logistics.plan.';

revoke all on function public.erp_cancel_shipment(uuid, text) from public, anon;
grant execute on function public.erp_cancel_shipment(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_ship_deliveries', 'erp.ship_deliveries',
   'Opens a shipment document from posted deliveries of one site and one customer and books it with the '
   'carrier the rate card recommends, or one named; authorises logistics.plan at the site. Moves no stock '
   'and posts nothing.'),
  ('erp_cancel_shipment', 'erp.cancel_shipment',
   'Cancels a planned or booked shipment, which releases its deliveries to ship again; authorises '
   'logistics.plan at the shipment''s site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- The rate card's comparison is what Ship these deliveries takes its carrier
-- from, so no press on the strip asks for it any more. It stays a door for the
-- exceptions screen, where a shipment left planned is booked by hand (LPR3).
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_select_carrier', 'pending_screen', '/logistics',
   'The carriers that quote a shipment, cheapest in time first. Ship these deliveries books the first of them '
   'itself (20261002400000); the exceptions screen will offer the list for a shipment left planned (LPR3).'),
  ('erp_plan_shipment', 'integration', null,
   'Plan a shipment without booking it: kept one release, onto the shipment document, for anything built '
   'against it before Ship these deliveries replaced it on the strip (20261002400000). Withdrawn in LPR3.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

-- ─────────────────────────────────────────────────────────────────────────────
-- H. The list names the document
-- ─────────────────────────────────────────────────────────────────────────────

do $shipments$
declare
  v_sig constant text := 'public.erp_shipments(integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    select jsonb_build_object('shipment_id', sh.id, 'reference', sh.reference,$o$,
    $n$    select jsonb_build_object('shipment_id', sh.id, 'reference', sh.reference,
      -- The document's number where it has one (20261002400000).
      'document_id', sh.document_id, 'number', coalesce(doc.document_number, sh.reference),$n$,
    $o$      left join erp.party p on p.tenant_id = sh.tenant_id and p.id = sh.destination_party_id
$o$,
    $n$      left join erp.party p on p.tenant_id = sh.tenant_id and p.id = sh.destination_party_id
      left join erp.document doc on doc.tenant_id = sh.tenant_id and doc.id = sh.document_id
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) by 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[v_i], ''))) / length(v_pairs[v_i]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, (v_i + 1) / 2, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[v_i], v_pairs[v_i + 1]);
  end loop;
  execute v_def;
end
$shipments$;

-- ─────────────────────────────────────────────────────────────────────────────
-- I. What fires each move
-- ─────────────────────────────────────────────────────────────────────────────

do $drivers$
declare
  v_src text := pg_get_functiondef('erp.transition_driver_register()'::regprocedure);
  v_old text := $o$      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)$o$;
  v_new text := $n$      ('supplier_invoice',     'approved_to_rejected',      'screen', ''),

      -- ── Logistics (20261002400000) ────────────────────────────────────────
      -- Booked by the ship door in the press that opens it, or by Book for
      -- one it left planned; delivered by the proof and nothing else.
      ('shipment',             'book',                      'routine', 'erp.book_shipment(uuid,text,text,bigint)'),
      ('shipment',             'deliver',                   'routine', 'erp.record_proof_of_delivery(uuid,timestamp with time zone,text,text)'),
      ('shipment',             'cancel',                    'routine', 'erp.cancel_shipment(uuid,text)'),
      ('shipment',             'cancel_booked',             'routine', 'erp.cancel_shipment(uuid,text)')
    ) as x(machine_code, transition_code, driver, detail)$n$;
begin
  if (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.transition_driver_register''s last row is not where 20261002400000 expects it';
  end if;
  execute replace(v_src, v_old, v_new);
end
$drivers$;

-- ─────────────────────────────────────────────────────────────────────────────
-- J. Despatch costs two presses
-- ─────────────────────────────────────────────────────────────────────────────

update erp_meta.flow_budget
   set budget = 2, decision_steps = 2, stages = 2, stages_without_a_list = 0,
       rationale = 'Two presses from posted deliveries to a delivered shipment: Ship these deliveries, '
                || 'which opens the shipment and books the carrier the rate card recommends, and Record '
                || 'proof of delivery (20261002400000). The carrier bill is the third, with LPR4.'
 where flow_code = 'despatch';

-- ─────────────────────────────────────────────────────────────────────────────
-- K. The screen's words, rendered through ui()
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The Despatch strip in two presses (20261002400000).'
  from (values
    ('Ship the posted deliveries, then record proof of delivery when they arrive.'),
    ('Ship these deliveries'),
    ('Ship posted deliveries of one site to one customer. The carrier the rate card recommends is booked unless you name another.'),
    ('Posted deliveries of one site and one customer, not on a shipment yet. Tick every one travelling together.'),
    ('Leave empty to take the carrier the rate card recommends.'),
    ('Leave empty to take the carrier''s recommended service.'),
    ('Leave empty to take the rate card''s price.'),
    ('Shipments appear here once they are booked with a carrier.'),
    ('Cancel a shipment'),
    ('A planned or booked shipment. Its deliveries can be shipped again.'),
    ('Why it is not going, for whoever reads the shipment next.')
  ) as v(text)
on conflict do nothing;


-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.shipment_document_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  r       record;
  v_site uuid; v_site2 uuid; v_uom uuid; v_cust uuid; v_cust2 uuid; v_sup uuid; v_item uuid;
  v_loc uuid; v_loc2 uuid; v_grn uuid; v_grn2 uuid;
  v_dn1 uuid; v_dn2 uuid; v_dn3 uuid; v_dn4 uuid; v_dn5 uuid; v_dn6 uuid; v_dn_other uuid; v_dn_draft uuid;
  v_ship uuid; v_ship2 uuid; v_ship3 uuid; v_again uuid; v_legacy uuid;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_n integer;
  v_to_ship jsonb; v_to_ship2 jsonb;
begin
  begin
    v_step := 'an organisation with logistics installed as the Configuration screen installs it';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zzsd-' || v_tag, 'Shipment Document Suite', 'admin@zzsd-' || v_tag || '.test', 'Shipment Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzsd-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    perform erp.configure_logistics();

    -- ── 1. Installed as configuration ───────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'logistics installs the shipment as a document: four states, four moves, SHP- numbering, at installer version 2';
    passed := exists (select 1 from erp.document_type dt
                       where dt.tenant_id = r.tenant_id and dt.code = 'shipment' and dt.base_type_code = 'shipment'
                         and dt.status = 'active')
          and (select count(*) from erp.state s
                 join erp.state_machine_version v on v.tenant_id = s.tenant_id and v.id = s.state_machine_version_id and v.status = 'active'
                 join erp.state_machine m on m.tenant_id = v.tenant_id and m.id = v.state_machine_id
                where m.tenant_id = r.tenant_id and m.code = 'shipment') = 4
          and (select count(*) from erp.transition t
                 join erp.state_machine_version v on v.tenant_id = t.tenant_id and v.id = t.state_machine_version_id and v.status = 'active'
                 join erp.state_machine m on m.tenant_id = v.tenant_id and m.id = v.state_machine_id
                where m.tenant_id = r.tenant_id and m.code = 'shipment') = 4
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = r.tenant_id and i.install_code = 'logistics') = 2
          and not exists (select 1 from erp.plan_module_upgrade('logistics'));
    detail := 'type, lifecycle and numbering installed with logistics, nothing left to upgrade';
    return next;

    v_step := 'a site with stock, two customers, and deliveries: six posted, one at another site, one draft';
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'ZSMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'ZSNORTH', 'North', 'warehouse', 'active') returning id into v_site2;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'ZSSTK', 'Stock', 'bulk', 'active') returning id into v_loc;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site2, 'ZSSTK2', 'Stock', 'bulk', 'active') returning id into v_loc2;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZSCUST', 'Shipment suite customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZSCUST2', 'Shipment suite other customer', 'active') returning id into v_cust2;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust2, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZSSUP', 'Shipment suite supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    -- A kilogram a box, so the rate card's price is known: ROAD ECONOMY is
    -- the cheapest that arrives in time, at 2000 plus 50 a kilogram.
    insert into erp.item (tenant_id, code, name, stock_uom_id, gross_weight_g, status)
    values (r.tenant_id, 'ZSBOX', 'Shipment suite box', v_uom, 1000, 'active') returning id into v_item;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 40, 1000, 'in');
    update erp.document_line set location_id = v_loc where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');
    v_grn2 := erp.open_document('goods_receipt', v_sup, null, v_site2);
    perform erp.add_document_line(v_grn2, v_item, 10, 1000, 'in');
    update erp.document_line set location_id = v_loc2 where document_id = v_grn2;
    perform erp.transition_document(v_grn2, 'post');
    v_dn1 := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn1, v_item, 4, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn1;
    perform erp.transition_document(v_dn1, 'post');
    v_dn2 := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn2, v_item, 3, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn2;
    perform erp.transition_document(v_dn2, 'post');
    v_dn3 := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn3, v_item, 2, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn3;
    perform erp.transition_document(v_dn3, 'post');
    v_dn4 := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn4, v_item, 1, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn4;
    perform erp.transition_document(v_dn4, 'post');
    v_dn5 := erp.open_document('delivery', v_cust2, null, v_site);
    perform erp.add_document_line(v_dn5, v_item, 1, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn5;
    perform erp.transition_document(v_dn5, 'post');
    v_dn6 := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn6, v_item, 1, 2500, 'out');
    update erp.document_line set location_id = v_loc where document_id = v_dn6;
    perform erp.transition_document(v_dn6, 'post');
    v_dn_other := erp.open_document('delivery', v_cust, null, v_site2);
    perform erp.add_document_line(v_dn_other, v_item, 1, 2500, 'out');
    update erp.document_line set location_id = v_loc2 where document_id = v_dn_other;
    perform erp.transition_document(v_dn_other, 'post');
    v_dn_draft := erp.open_document('delivery', v_cust, null, v_site);
    perform erp.add_document_line(v_dn_draft, v_item, 1, 2500, 'not yet');

    -- ── 2. One press: planned and booked, the recommended carrier taken ─────
    v_step := 'two deliveries shipped, nothing named';
    v_ship := erp.ship_deliveries(array[v_dn1, v_dn2]);
    v_cases := v_cases + 1;
    case_name := 'Ship these deliveries opens the shipment and books it in the same statement, with the carrier, service and price the rate card recommends';
    passed := (select sh.status::text from erp.shipment sh where sh.id = v_ship) = 'booked'
          and erp.object_current_state('document', (select sh.document_id from erp.shipment sh where sh.id = v_ship)) = 'booked'
          and (select d.document_number from erp.document d
                where d.id = (select sh.document_id from erp.shipment sh where sh.id = v_ship)) like 'SHP-%'
          and (select c.code from erp.carrier c join erp.shipment sh on sh.carrier_id = c.id where sh.id = v_ship) = 'ROAD'
          and (select sh.service_code from erp.shipment sh where sh.id = v_ship) = 'ECONOMY'
          and (select sh.freight_cost_minor from erp.shipment sh where sh.id = v_ship) = 2350
          and (select sh.destination_party_id from erp.shipment sh where sh.id = v_ship) = v_cust
          and (select count(*) from erp.shipment_line sl where sl.shipment_id = v_ship) = 2;
    detail := (select format('%s %s, %s %s at %s', d.document_number, sh.status, c.code, sh.service_code, sh.freight_cost_minor)
                 from erp.shipment sh
                 left join erp.document d on d.id = sh.document_id
                 left join erp.carrier c on c.id = sh.carrier_id
                where sh.id = v_ship);
    return next;

    -- ── 3. The planner may name another ─────────────────────────────────────
    v_step := 'a delivery shipped by air at a cost the planner typed';
    v_ship2 := erp.ship_deliveries(array[v_dn3], current_date, 'AIR', 'EXPRESS', 99999);
    v_cases := v_cases + 1;
    case_name := 'a carrier, service and cost named on the same press are the ones booked';
    passed := (select sh.status::text from erp.shipment sh where sh.id = v_ship2) = 'booked'
          and (select c.code from erp.carrier c join erp.shipment sh on sh.carrier_id = c.id where sh.id = v_ship2) = 'AIR'
          and (select sh.service_code from erp.shipment sh where sh.id = v_ship2) = 'EXPRESS'
          and (select sh.freight_cost_minor from erp.shipment sh where sh.id = v_ship2) = 99999;
    detail := (select format('%s %s at %s', sh.status, sh.service_code, sh.freight_cost_minor)
                 from erp.shipment sh where sh.id = v_ship2);
    return next;

    -- ── 4. No tariff: planned, not refused ──────────────────────────────────
    v_step := 'a delivery shipped when no carrier is active';
    update erp.carrier set status = 'inactive' where tenant_id = r.tenant_id;
    v_ship3 := erp.ship_deliveries(array[v_dn4]);
    update erp.carrier set status = 'active' where tenant_id = r.tenant_id;
    v_cases := v_cases + 1;
    case_name := 'with no carrier to quote and no cost given, the shipment is left planned with its number, and not refused';
    passed := (select sh.status::text from erp.shipment sh where sh.id = v_ship3) = 'planned'
          and erp.object_current_state('document', (select sh.document_id from erp.shipment sh where sh.id = v_ship3)) = 'planned'
          and (select d.document_number from erp.document d
                where d.id = (select sh.document_id from erp.shipment sh where sh.id = v_ship3)) like 'SHP-%'
          and (select sh.carrier_id from erp.shipment sh where sh.id = v_ship3) is null;
    detail := (select format('%s %s', d.document_number, sh.status)
                 from erp.shipment sh left join erp.document d on d.id = sh.document_id where sh.id = v_ship3);
    return next;

    -- ── 5. What is not a shippable delivery ─────────────────────────────────
    v_step := 'deliveries the door must refuse';
    begin perform erp.ship_deliveries(array[v_dn_draft]); v_err := 'shipped';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin perform erp.ship_deliveries(array[v_dn1]); v_err2 := 'shipped';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    begin perform erp.ship_deliveries(array[v_dn6, v_dn_other]); v_err3 := 'shipped';
    exception when others then v_err3 := left(sqlerrm, 200); end;
    begin perform erp.ship_deliveries(array[v_dn5, v_dn6]); v_err4 := 'shipped';
    exception when others then v_err4 := left(sqlerrm, 200); end;
    begin perform erp.ship_deliveries(array[v_grn]); v_err5 := 'shipped';
    exception when others then v_err5 := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a draft, a delivery already on a shipment, two sites, two customers and a goods receipt are each refused by name';
    passed := v_err like 'CLOVEERP_DELIVERY_NOT_SHIPPABLE:%'
          and v_err2 like 'CLOVEERP_DELIVERY_NOT_SHIPPABLE:%'
          and v_err3 like 'CLOVEERP_SHIPMENT_MIXED_SITES:%'
          and v_err4 like 'CLOVEERP_MIXED_DESTINATIONS:%'
          and v_err5 like 'CLOVEERP_DELIVERY_NOT_SHIPPABLE:%';
    detail := concat_ws(' | ', v_err, v_err2, v_err3, v_err4, v_err5);
    return next;

    -- ── 6. Proof: only on a booked shipment, and it delivers the document ───
    v_step := 'proof recorded on a planned shipment, then on a booked one';
    v_err := null;
    begin perform erp.record_proof_of_delivery(v_ship3, now(), 'A. Patel'); v_err := 'recorded';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform erp.record_proof_of_delivery(v_ship, now(), 'A. Patel', 'POD-1');
    v_cases := v_cases + 1;
    case_name := 'proof of delivery is refused on a planned shipment, and moves a booked one to delivered';
    passed := v_err like 'CLOVEERP_SHIPMENT_NOT_BOOKED:%'
          and (select sh.status::text from erp.shipment sh where sh.id = v_ship) = 'delivered'
          and erp.object_current_state('document', (select sh.document_id from erp.shipment sh where sh.id = v_ship)) = 'delivered'
          and (select sh.proof_of_delivery ->> 'signed_by' from erp.shipment sh where sh.id = v_ship) = 'A. Patel';
    detail := concat_ws(' | ', v_err, (select sh.status::text from erp.shipment sh where sh.id = v_ship));
    return next;

    -- ── 7. Cancelled, and the deliveries released ───────────────────────────
    v_step := 'the booked and the planned shipment cancelled, the delivered one asked to be';
    v_err := null;
    begin perform erp.cancel_shipment(v_ship, 'too late'); v_err := 'cancelled';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform erp.cancel_shipment(v_ship2, 'the customer will collect');
    perform erp.cancel_shipment(v_ship3);
    v_to_ship := public.erp_deliveries_to_ship(null, null, 200);
    v_again := erp.ship_deliveries(array[v_dn3]);
    v_cases := v_cases + 1;
    case_name := 'a booked and a planned shipment cancel and release their deliveries, which ship again; a delivered one is refused';
    passed := v_err like 'CLOVEERP_SHIPMENT_DELIVERED:%'
          and (select sh.status::text from erp.shipment sh where sh.id = v_ship2) = 'cancelled'
          and erp.object_current_state('document', (select sh.document_id from erp.shipment sh where sh.id = v_ship2)) = 'cancelled'
          and (select sh.status::text from erp.shipment sh where sh.id = v_ship3) = 'cancelled'
          and erp.object_current_state('document', (select sh.document_id from erp.shipment sh where sh.id = v_ship3)) = 'cancelled'
          and exists (select 1 from jsonb_array_elements(v_to_ship) x where (x ->> 'document_id')::uuid = v_dn3)
          and exists (select 1 from jsonb_array_elements(v_to_ship) x where (x ->> 'document_id')::uuid = v_dn4)
          and not exists (select 1 from jsonb_array_elements(v_to_ship) x where (x ->> 'document_id')::uuid = v_dn1)
          and (select sh.status::text from erp.shipment sh where sh.id = v_again) = 'booked';
    detail := concat_ws(' | ', v_err, (select sh.status::text from erp.shipment sh where sh.id = v_again));
    return next;

    -- ── 8. The old doors, onto the document ─────────────────────────────────
    v_step := 'Plan then Book, as the old doors do';
    v_ship3 := erp.plan_shipment(v_site, array[v_dn4], current_date);
    perform erp.book_shipment(v_ship3, 'ROAD', 'NEXT_DAY');
    v_cases := v_cases + 1;
    case_name := 'Plan opens a shipment document and Book books it, so the doors kept for one release move the same lifecycle';
    passed := (select sh.document_id from erp.shipment sh where sh.id = v_ship3) is not null
          and erp.object_current_state('document', (select sh.document_id from erp.shipment sh where sh.id = v_ship3)) = 'booked'
          and (select sh.status::text from erp.shipment sh where sh.id = v_ship3) = 'booked';
    detail := (select format('%s %s', d.document_number, sh.status)
                 from erp.shipment sh left join erp.document d on d.id = sh.document_id where sh.id = v_ship3);
    return next;

    -- ── 9. A shipment from before ───────────────────────────────────────────
    v_step := 'a shipment with no document, as one raised before this migration';
    insert into erp.shipment (tenant_id, entity_id, site_id, reference, status, planned_despatch, destination_party_id)
    values (r.tenant_id, r.entity_id, v_site, 'SH-LEGACY-' || v_tag, 'booked', current_date, v_cust)
    returning id into v_legacy;
    insert into erp.shipment_line (tenant_id, shipment_id, document_id, weight_g)
    values (r.tenant_id, v_legacy, v_dn6, 1000);
    v_err := null; v_err2 := null;
    begin perform erp.book_shipment(v_legacy, 'ROAD', 'ECONOMY'); v_err := 'booked';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin perform erp.record_proof_of_delivery(v_legacy, now(), 'A. Patel'); v_err2 := 'delivered';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    perform erp.cancel_shipment(v_legacy, 'raised before the spine');
    v_to_ship2 := public.erp_deliveries_to_ship(null, null, 200);
    v_cases := v_cases + 1;
    case_name := 'a shipment with no document is refused booking and proof by name, and cancels, releasing its delivery';
    passed := v_err like 'CLOVEERP_SHIPMENT_BEFORE_THE_SPINE:%'
          and v_err2 like 'CLOVEERP_SHIPMENT_BEFORE_THE_SPINE:%'
          and (select sh.status::text from erp.shipment sh where sh.id = v_legacy) = 'cancelled'
          and exists (select 1 from jsonb_array_elements(v_to_ship2) x where (x ->> 'document_id')::uuid = v_dn6);
    detail := concat_ws(' | ', v_err, v_err2);
    return next;

    -- ── 10. Not installed: refused, and the upgrade offers it ───────────────
    v_step := 'the organisation put back to logistics version 1';
    v_err := null; v_n := null;
    begin
      update erp.module_installation i set installer_version = 1
       where i.tenant_id = r.tenant_id and i.install_code = 'logistics';
      update erp.document_type dt set status = 'inactive'
       where dt.tenant_id = r.tenant_id and dt.code = 'shipment';
      begin perform erp.ship_deliveries(array[v_dn6]); v_err := 'shipped';
      exception when others then v_err := left(sqlerrm, 200); end;
      select count(*) into v_n from erp.plan_module_upgrade('logistics') p
       where p.object_kind in ('state_machine', 'numbering_rule', 'document_type');
      raise exception 'CLOVEERP_V1_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_V1_UNDO' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'an organisation without the shipment document is refused by name and offered it as the logistics upgrade';
    passed := v_err like 'CLOVEERP_SHIPMENT_NOT_INSTALLED:%' and v_n >= 1;
    detail := format('%s; %s item(s) offered', v_err, v_n);
    return next;

    -- ── 11. Every move driven ───────────────────────────────────────────────
    v_step := 'the driver register asked of the shipment';
    v_cases := v_cases + 1;
    case_name := 'every shipment move is registered to the routine that fires it, and each of those routines moves a document';
    passed := not exists (select 1 from erp.undriven_transition_report() u where u.reference like 'shipment%')
          and (select count(*) from jsonb_array_elements(erp.transition_driver_register()) x
                where x ->> 'machine_code' = 'shipment' and x ->> 'driver' = 'routine') = 4;
    detail := coalesce((select string_agg(u.finding || ' ' || u.reference, '; ')
                          from erp.undriven_transition_report() u where u.reference like 'shipment%'),
                       'book, deliver, cancel and cancel_booked each driven');
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
    raise exception 'CLOVEERP_SHIPMENT_DOCUMENT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzsd-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1)
     or current_user <> v_owner then
    raise exception 'CLOVEERP_SHIPMENT_DOCUMENT_SUITE_LEAKED: the fixture was not undone';
  end if;
end;
$$;

revoke all on function erp_test.shipment_document_suite() from public, anon;

comment on function erp_test.shipment_document_suite() is
  'The shipment is a document on the spine, shipped in one press from posted deliveries, delivered by its '
  'proof and cancelled with its deliveries released (20261002400000).';

create or replace function erp_test.assert_shipment_document_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.shipment_document_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SHIPMENT_DOCUMENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Despatch would take more than its press, or a shipment would move outside its lifecycle. Read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_SHIPMENT_DOCUMENT_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('shipment document: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_shipment_document_suite() from public, anon;

comment on function erp_test.assert_shipment_document_suite() is
  'The shipment on the spine, and despatch in one press (20261002400000).';

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
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
