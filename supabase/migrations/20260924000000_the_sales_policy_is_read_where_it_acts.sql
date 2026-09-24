set lock_timeout = '30s';

-- =============================================================================
-- 20260924000000  The sales policy is read where it acts
-- -----------------------------------------------------------------------------
-- PR6, M3: node S8 of docs/spec/simplification-review.md, the mirror of the
-- procurement policy (20260923100000).
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A delivery of more than was ordered was refused outright
-- (CLOVEERP_MORE_THAN_LEFT_TO_DELIVER), however little more, and an order
-- delivered short by a unit stayed Part despatched until somebody delivered
-- the last unit or cancelled what was left. Purchasing has had a policy for
-- both since PR4; selling had none.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
-- One configuration type, sales.policy, read through erp.sales_policy() at
-- the order's entity and site:
--
--   over_ship_pct    read by erp.create_delivery_from_order(): a line may be
--                    delivered up to what was ordered widened by this much,
--                    counting what is on deliveries already (default 0)
--   short_close_pct  read by erp.sales_line_is_delivered(): a line is delivered
--                    once no more than this share of it is left (default 0).
--                    One test, asked wherever a line is asked whether it
--                    still has goods to go: the order's move to Despatched,
--                    the release of what was held for the line, the stock the
--                    warehouse is asked to release, planning's firm demand
--                    and the stock forecast
--
-- The policy is proposed on the Sales screen with Propose the sales policy
-- (erp_propose_sales_policy), as an item of a change set that somebody else
-- approves and promotes, as the allocation policy is. At the defaults nothing
-- changes, and a new install writes no policy of its own: the installer, and
-- the upgrade register it would need, stay as they are.
--
-- The policy is read when it is asked. A short close raised later reads an
-- older line delivered for planning at once, but what is still held for that
-- line is released only by its next delivery, as before; until then it stays
-- held.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The policy
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value, consequence) values
  ('sales.policy', 'policy', 'sales',
   'config.sales.policy',
   'How much more than was ordered a delivery may take, and how little may be '
   'left undelivered for an order to read despatched.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'over_ship_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'short_close_pct', jsonb_build_object('type','number','minimum',0,'maximum',100))),
   'site', true,
   jsonb_build_object('over_ship_pct', 0, 'short_close_pct', 0),
   'Raising over_ship_pct lets a delivery send, and an invoice bill, more than '
   'the customer ordered, beyond what any credit check on the order counted; '
   'raising short_close_pct reads an order despatched with goods still owed to '
   'the customer, releases what was held for them and stops planning for them, '
   'and the customer is invoiced for what went.')
on conflict (code) do nothing;

insert into erp_ref.resource (key, locale, value, description) values
  ('config.sales.policy', 'en', 'Sales policy',
   'The name of the sales.policy configuration type.'),
  ('config.sales.policy', 'de', 'Vertriebsrichtlinie',
   'Der Name des Konfigurationstyps sales.policy.')
on conflict (key, locale) do nothing;

create or replace function erp.sales_policy(p_entity_id uuid default null,
                                            p_site_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The sales policy in force at an entity and site (20260924000000),
  -- layered key by key as the procurement policy is: the product's defaults,
  -- then what the organisation set, then its entity, then its site.
  select coalesce(ct.default_value, '{}'::jsonb)
      || coalesce(erp.config_value('sales.policy', null, null, null, null), '{}'::jsonb)
      || case when p_entity_id is null then '{}'::jsonb
              else coalesce(erp.config_value('sales.policy', null, null, p_entity_id, null), '{}'::jsonb) end
      || case when p_site_id is null then '{}'::jsonb
              else coalesce(erp.config_value('sales.policy', null, null, p_entity_id, p_site_id), '{}'::jsonb) end
    from erp_ref.config_type ct
   where ct.code = 'sales.policy'
$$;

comment on function erp.sales_policy(uuid, uuid) is
  'sales.policy at an entity and site, over its defaults (20260924000000). '
  'Read by erp.create_delivery_from_order (over_ship_pct) and, through '
  'erp.sales_line_is_delivered, by erp.advance_orders_for_delivery, '
  'erp.consume_allocations_for_delivery, erp_release_sequence, '
  'erp.scheduled_demand and erp.stock_forecast_lines (short_close_pct).';

create or replace function erp.sales_line_is_delivered(p_line_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A sales order line is delivered once no more than the sales policy's
  -- short_close_pct of it is left (20260924000000). At the default, 0, that
  -- is every unit. One test, so the order that reads despatched, the stock
  -- held for it, the stock the warehouse is asked to release and the demand
  -- planning and the stock forecast see cannot disagree (found on review).
  -- Asked of a sales order line; any other line reads not delivered.
  select coalesce(dl.quantity > 0
                  and coalesce(dl.quantity_fulfilled, 0)
                      >= dl.quantity * (1 - coalesce((erp.sales_policy(d.entity_id, d.site_id)
                                                        ->> 'short_close_pct')::numeric, 0) / 100.0),
                  false)
    from erp.document_line dl
    join erp.document d on d.tenant_id = dl.tenant_id and d.id = dl.document_id
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where dl.tenant_id = erp.current_tenant_id() and dl.id = p_line_id
     and dt.base_type_code = 'sales_order'
$$;

comment on function erp.sales_line_is_delivered(uuid) is
  'Whether a sales order line is delivered under the sales policy''s short_close_pct '
  '(20260924000000): what the order''s move to Despatched, the release of what was '
  'held for it and planning''s firm demand all read.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. over_ship_pct: a delivery may take a little more than was ordered
--
-- A line may be delivered up to its ordered quantity widened by the policy,
-- counting everything already on a delivery, posted or not. At the default,
-- 0, that is what was ordered, as before.
-- ─────────────────────────────────────────────────────────────────────────────

do $over_ship$
declare
  v_sig constant text := 'erp.create_delivery_from_order(uuid,jsonb,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs text[][] := array[
    array[$o$    select x.line_id, x.line_no, x.open_quantity
      from erp.deliverable_lines(p_order_id) x
     order by x.line_no
  loop$o$,
          $n$    select x.line_id, x.line_no, x.open_quantity,
           -- What the line may still take under the sales policy
           -- (20260924000000): the ordered quantity widened by
           -- over_ship_pct, less what is on deliveries already.
           greatest(x.ordered_quantity
                      * (1 + coalesce((erp.sales_policy(d.entity_id, d.site_id) ->> 'over_ship_pct')::numeric, 0) / 100.0)
                    - greatest(x.delivered_quantity, x.on_deliveries_quantity), 0) as room
      from erp.deliverable_lines(p_order_id) x
     order by x.line_no
  loop$n$],
    array[$o$    if v_qty > l.open_quantity then
      raise exception 'CLOVEERP_MORE_THAN_LEFT_TO_DELIVER: line % of % has % left to deliver, and % was asked for',
        l.line_no, d.document_number, trim_scale(l.open_quantity), trim_scale(v_qty)
        using errcode = '23514',
              hint = 'Deliver what is left, or less. What is already on a delivery, posted or not, is not left to deliver.';
    end if;$o$,
          $n$    if v_qty > l.room then
      raise exception 'CLOVEERP_MORE_THAN_LEFT_TO_DELIVER: line % of % has % left to deliver%, and % was asked for',
        l.line_no, d.document_number, trim_scale(l.open_quantity),
        case when l.room > l.open_quantity
             then format(' and may still take %s under the sales policy', trim_scale(round(l.room, 6)))
             else '' end,
        trim_scale(v_qty)
        using errcode = '23514',
              hint = 'Deliver what is left, or less. What is already on a delivery, posted or not, is not left to deliver. How much more than was ordered a delivery may take is set by the sales policy, proposed on the Sales screen with Propose the sales policy.';
    end if;$n$]];
  v_hits integer;
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
end
$over_ship$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. short_close_pct: a line is delivered when little enough is left
--
-- The mirror of the procurement policy's (20260923100000), read through
-- erp.sales_line_is_delivered() in every place that asks whether a line
-- still has goods to go: the delivery that leaves that little moves the
-- order to Despatched and releases what was still held for the line; the
-- warehouse is no longer asked to release stock for it (erp_release_sequence);
-- and neither planning nor the stock forecast asks for supply of the rest. At the default, 0, every unit must go, as
-- before, and each place reads as it did.
-- ─────────────────────────────────────────────────────────────────────────────

do $short_close$
declare
  v_sig text;
  v_def text;
  v_old text;
  v_new text;
  v_hits integer;
begin
  v_sig := 'erp.advance_orders_for_delivery(uuid)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_old := $o$    select coalesce(bool_and(dl.quantity_fulfilled >= dl.quantity), false)
      into v_full$o$;
  v_new := $n$    -- Delivered, line by line, under the sales policy (20260924000000).
    select coalesce(bool_and(erp.sales_line_is_delivered(dl.id)), false)
      into v_full$n$;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % full-delivery anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);

  v_sig := 'erp.consume_allocations_for_delivery(uuid)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_old := $o$    if exists (select 1 from erp.document_line ol
                where ol.tenant_id = v_tenant and ol.id = v_line
                  and ol.quantity > 0 and ol.quantity_fulfilled >= ol.quantity) then$o$;
  v_new := $n$    -- Delivered under the sales policy (20260924000000).
    if erp.sales_line_is_delivered(v_line) then$n$;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % release anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);

  v_sig := 'erp.scheduled_demand(uuid,uuid,date,date,uuid,uuid)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_old := $o$     and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
  union all$o$;
  v_new := $n$     and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
     -- Nor a line the sales policy reads delivered (20260924000000).
     and not erp.sales_line_is_delivered(dl.id)
  union all$n$;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % firm-demand anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);

  v_sig := 'public.erp_release_sequence(uuid,integer)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_old := $o$           and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
           and (p_site_id is null or d.site_id = p_site_id)$o$;
  v_new := $n$           and dl.quantity > coalesce(dl.quantity_fulfilled, 0)
           -- Nor a line the sales policy reads delivered (20260924000000).
           and not erp.sales_line_is_delivered(dl.id)
           and (p_site_id is null or d.site_id = p_site_id)$n$;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % open-line anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);

  v_sig := 'erp.stock_forecast_lines(uuid,integer)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_old := $o$                      and os.object_id = d.id and s.code in ('confirmed', 'picking', 'partially_despatched'))
       and coalesce(d.is_cancelled, false) = false
       and coalesce(dl.is_cancelled, false) = false
     group by dl.item_id, d.site_id
  ),$o$;
  v_new := $n$                      and os.object_id = d.id and s.code in ('confirmed', 'picking', 'partially_despatched'))
       and coalesce(d.is_cancelled, false) = false
       and coalesce(dl.is_cancelled, false) = false
       -- Nor a line the sales policy reads delivered (20260924000000).
       and not erp.sales_line_is_delivered(dl.id)
     group by dl.item_id, d.site_id
  ),$n$;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % demand anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$short_close$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The policy is proposed as a change, from the Sales screen
--
-- As the allocation policy is (20260906143000): an item of a change set,
-- which somebody else approves and promotes. The value is checked against
-- the type's shape before it is proposed.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.propose_sales_policy(
  p_entity_code text, p_site_code text, p_value jsonb, p_change_set_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity text := p_entity_code;
  ct       erp_ref.config_type%rowtype;
  v_key    text;
  v_cs     uuid := p_change_set_id;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', p_change_set_id);

  select * into ct from erp_ref.config_type c where c.code = 'sales.policy';
  -- The shape, and the bounds, asked here as well as by the schema: a
  -- percentage outside nought to a hundred means nothing on either key.
  if p_value is null or jsonb_typeof(p_value) <> 'object' or p_value = '{}'::jsonb
     or not erp.jsonb_matches_schema(ct.value_schema::json, p_value) then
    raise exception 'CLOVEERP_POLICY_VALUE_INVALID: the sales policy does not fit its declared shape'
      using errcode = '22023',
            hint = 'Over-delivery and short close are percentages from 0 to 100; give one or both.';
  end if;
  for v_key in select jsonb_object_keys(p_value) loop
    if v_key not in ('over_ship_pct', 'short_close_pct')
       or jsonb_typeof(p_value -> v_key) <> 'number'
       or (p_value ->> v_key)::numeric not between 0 and 100 then
      raise exception 'CLOVEERP_POLICY_VALUE_INVALID: the sales policy does not fit its declared shape'
        using errcode = '22023',
              hint = 'Over-delivery and short close are percentages from 0 to 100; give one or both.';
    end if;
  end loop;

  if p_site_code is not null then
    select e.code into v_entity
      from erp.site s join erp.entity e on e.id = s.entity_id
     where s.tenant_id = v_tenant and s.code = p_site_code;
    if v_entity is null then
      raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_code
        using errcode = '23503', hint = 'erp_sites() lists the sites by code; a site policy belongs to the site''s company.';
    end if;
  elsif p_entity_code is not null and not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.code = p_entity_code) then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not a company of this organisation', p_entity_code
      using errcode = '23503', hint = 'erp_entities() lists the companies by code.';
  end if;

  -- No change chosen: the proposal starts one of its own, as the screen says.
  if v_cs is null then
    v_cs := erp.create_change_set(
      'sales-policy-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US'),
      'Sales policy',
      'How much more than was ordered a delivery may take, and how little may be left for a line to count as delivered.');
  end if;

  return erp.add_change_set_item(v_cs, 'config',
    format('sales.policy|%s|%s', coalesce(v_entity, '*'), coalesce(p_site_code, '*')),
    jsonb_strip_nulls(jsonb_build_object(
      'config_type', 'sales.policy', 'value', p_value,
      'entity', v_entity, 'site', p_site_code)),
    'upsert', null, 'proposed from the Sales screen');
end;
$$;

revoke all on function erp.propose_sales_policy(text, text, jsonb, uuid) from public, anon;

comment on function erp.propose_sales_policy(text, text, jsonb, uuid) is
  'Proposes the sales policy for the organisation, a company or a site, as an item of '
  'a change set (20260924000000).';

create or replace function public.erp_propose_sales_policy(
  p_entity_code text, p_site_code text, p_value jsonb, p_change_set_id uuid)
returns uuid
language sql
set search_path = ''
as $$
  select erp.propose_sales_policy(p_entity_code, p_site_code, p_value, p_change_set_id)
$$;

revoke all on function public.erp_propose_sales_policy(text, text, jsonb, uuid) from public, anon;
grant execute on function public.erp_propose_sales_policy(text, text, jsonb, uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_propose_sales_policy', 'erp.propose_sales_policy',
   'Proposes how much more than was ordered a delivery may take and how little may be left for a line to read delivered, as a change-set item; authorises administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/sales', array['erp_propose_sales_policy']);

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The refusal says what the policy allows
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_MORE_THAN_LEFT_TO_DELIVER',
  'Delivering more of an order line than is left on it and than the sales policy allows beyond it.',
  'What is left is what was ordered less what posted deliveries delivered and what draft deliveries hold. The sales policy can let a line take a little more than was ordered; unless it does, nothing more.',
  'Deliver what is left, or less. Goods beyond what the policy allows need the order amended, an order of their own, or the sales policy proposed with more room on the Sales screen.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The words the Sales screen says for it (src/routes/sales/index.tsx)
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The sales policy''s proposal on the Sales screen (20260924000000).'
  from (values
    ('Propose the sales policy'),
    ('How much more than was ordered a delivery may take, and how little may be left for a line to count as delivered. Proposed as a change like any other configuration.'),
    ('Company'),
    ('Leave unchosen to set the policy for the whole organisation.'),
    ('Site'),
    ('Leave unchosen to apply the policy across the whole company.'),
    ('Over-delivery allowed (%)'),
    ('How much more than was ordered a delivery may take. 0 allows none; left empty, the broader setting applies.'),
    ('Short close (%)'),
    ('A line counts as delivered once no more than this share of it is left. 0 means every unit; left empty, the broader setting applies.'),
    ('Add to an existing change'),
    ('Leave unchosen to start a new change for this proposal.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What proves it: erp_test.despatch_tolerance_suite(), the name node S8
--    gives it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.despatch_tolerance_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  r       record;
  v_uom uuid; v_site uuid; v_sup uuid; v_cust uuid; v_item uuid; v_grn uuid;
  v_p0 jsonb; v_p1 jsonb; v_p2 jsonb;
  v_so uuid; v_l uuid; v_dn uuid; v_err text; v_err2 text; v_ok boolean; v_q numeric;
  v_st0 text; v_st2 text; v_log text;
  v_al0 uuid; v_al2 uuid; v_al0_st text; v_al2_st text; v_dem0 integer; v_dem2 integer;
  v_l0 uuid; v_bad text; v_item_id uuid; v_payload jsonb;
  v_item2 uuid; v_la uuid; v_lb uuid; v_seq jsonb; v_st3 text; v_fc_before numeric; v_fc_after numeric;
begin
  begin
    select * into r from erp.provision_tenant(
      'zz-spol-' || v_hex, 'Sales policy suite',
      'admin@zz-spol-' || v_hex || '.test', 'Policy Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zz-spol-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);

    select s.id into v_site from erp.site s
     where s.tenant_id = r.tenant_id and s.entity_id = r.entity_id order by s.code limit 1;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = r.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZSPSUP', 'Policy Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZSPCUS', 'Policy Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_cust, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZSPWID', 'Policy Suite Widget', v_uom, 'active') returning id into v_item;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 500, 100, 'the stock');
    perform erp.transition_document(v_grn, 'post', 'sales policy suite');

    -- 1. The defaults change nothing, and a narrower value layers key by key.
    v_p0 := erp.sales_policy(null, null);
    perform erp.set_config_value('sales.policy', jsonb_build_object('over_ship_pct', 10),
      null, null, r.entity_id, null, 'the sales policy suite');
    v_p1 := erp.sales_policy(r.entity_id, v_site);
    v_p2 := erp.sales_policy(null, null);
    return query select 'the sales policy reads nought and nought by default, and an entity''s value layers over it key by key',
      v_p0 = jsonb_build_object('over_ship_pct', 0, 'short_close_pct', 0)
      and (v_p1 ->> 'over_ship_pct')::numeric = 10 and (v_p1 ->> 'short_close_pct')::numeric = 0
      and (v_p2 ->> 'over_ship_pct')::numeric = 0,
      format('default %s; at the entity %s; at the organisation %s', v_p0, v_p1, v_p2);

    -- 2. over_ship_pct. Ten ordered: at nought the eleventh is refused; at
    --    ten per cent eleven go, and a twelfth is refused.
    perform erp.set_config_value('sales.policy', jsonb_build_object('over_ship_pct', 0),
      null, null, r.entity_id, null, 'the sales policy suite');
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_l := erp.add_document_line(v_so, v_item, 10, 1000, 'Ten widgets');
    perform erp.transition_document(v_so, 'submit', 'sales policy suite');
    perform erp_test.approve_document(v_so, 'sales policy suite');
    begin
      perform erp.create_delivery_from_order(v_so,
        jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 11)));
      v_err := 'delivered';
    exception when others then v_err := left(sqlerrm, 300); end;
    perform erp.set_config_value('sales.policy', jsonb_build_object('over_ship_pct', 10),
      null, null, r.entity_id, null, 'the sales policy suite');
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 5))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'sales policy suite');
    begin
      perform erp.create_delivery_from_order(v_so,
        jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 7)));
      v_err2 := 'delivered';
    exception when others then v_err2 := left(sqlerrm, 300); end;
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 6))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'sales policy suite');
    select dl.quantity_fulfilled into v_q from erp.document_line dl where dl.id = v_l;
    return query select 'at nought a delivery of more than was ordered is refused by name, naming the policy; at ten per cent the line takes eleven of ten, no more, and the order reads despatched',
      v_err like 'CLOVEERP_MORE_THAN_LEFT_TO_DELIVER:%has 10 left to deliver, and 11 was asked for'
      and v_err2 like 'CLOVEERP_MORE_THAN_LEFT_TO_DELIVER:%has 5 left to deliver and may still take 6 under the sales policy, and 7 was asked for'
      and v_q = 11
      and erp.object_current_state('document', v_so) = 'despatched',
      format('at nought: %s; at ten, after five: %s; then %s delivered, order %s', v_err, v_err2, trim_scale(v_q),
             erp.object_current_state('document', v_so));

    -- 3. short_close_pct. Ninety-nine of a hundred: at nought the order is
    --    part despatched; at two per cent it is despatched, moved by the
    --    delivery.
    perform erp.set_config_value('sales.policy', jsonb_build_object('over_ship_pct', 0, 'short_close_pct', 0),
      null, null, r.entity_id, null, 'the sales policy suite');
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_l := erp.add_document_line(v_so, v_item, 100, 1000, 'A hundred widgets');
    perform erp.transition_document(v_so, 'submit', 'sales policy suite');
    perform erp_test.approve_document(v_so, 'sales policy suite');
    v_al0 := erp.reserve_for_line(v_l);
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 99))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'sales policy suite');
    v_st0 := erp.object_current_state('document', v_so);
    v_l0 := v_l;
    -- Asked while the policy is still nought: the policy is read when the
    -- question is asked, so raising it later reads this line delivered too.
    select count(*) into v_dem0
      from erp.scheduled_demand(v_item, v_site, current_date - 365, current_date + 365) sd
     where sd.document_line_id = v_l0;

    perform erp.set_config_value('sales.policy', jsonb_build_object('over_ship_pct', 0, 'short_close_pct', 2),
      null, null, r.entity_id, null, 'the sales policy suite');
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_l := erp.add_document_line(v_so, v_item, 100, 1000, 'A hundred widgets');
    perform erp.transition_document(v_so, 'submit', 'sales policy suite');
    perform erp_test.approve_document(v_so, 'sales policy suite');
    v_al2 := erp.reserve_for_line(v_l);
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_l, 'quantity', 99))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'sales policy suite');
    v_st2 := erp.object_current_state('document', v_so);
    select al.status::text into v_al0_st from erp.allocation al where al.id = v_al0;
    select al.status::text into v_al2_st from erp.allocation al where al.id = v_al2;
    select count(*) filter (where sd.document_line_id = v_l)
      into v_dem2
      from erp.scheduled_demand(v_item, v_site, current_date - 365, current_date + 365) sd;
    select string_agg(l.transition_code || ':' || coalesce(l.reason, ''), ' / ' order by l.occurred_at)
      into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_so
       and l.transition_code like 'despatch%';
    return query select 'at nought ninety-nine of a hundred reads part despatched; at two per cent it reads despatched, moved by the delivery and nobody else',
      v_st0 = 'partially_despatched' and v_st2 = 'despatched' and v_log like '%Delivered in full by %',
      format('at nought: %s; at two: %s (%s)', v_st0, v_st2, coalesce(v_log, 'no move'));

    -- 4. What was held for the line is released and planning stops asking
    --    for the rest once it reads delivered; at nought both stay.
    return query select 'a line the policy reads delivered releases what was held for it and planning stops asking for the rest; at nought the unit still owed stays held and asked for',
      v_al0_st = 'reserved' and v_dem0 = 1
      and v_al2_st = 'released' and v_dem2 = 0,
      format('at nought: held %s, demand rows %s; at two: held %s, demand rows %s',
             v_al0_st, v_dem0, v_al2_st, v_dem2);

    -- 5. On an order still part despatched, a line the policy reads
    --    delivered is no longer offered to the warehouse or counted in the
    --    stock forecast; the line still open is.
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZSPGAD', 'Policy Suite Gadget', v_uom, 'active') returning id into v_item2;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item2, 50, 100, 'the gadgets');
    perform erp.transition_document(v_grn, 'post', 'sales policy suite');
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_la := erp.add_document_line(v_so, v_item, 100, 1000, 'A hundred widgets');
    v_lb := erp.add_document_line(v_so, v_item2, 10, 1000, 'Ten gadgets');
    perform erp.transition_document(v_so, 'submit', 'sales policy suite');
    perform erp_test.approve_document(v_so, 'sales policy suite');
    select f.demand into v_fc_before from erp.stock_forecast_lines(v_site, 90) f where f.item_id = v_item;
    v_dn := (erp.create_delivery_from_order(v_so,
               jsonb_build_array(jsonb_build_object('line_id', v_la, 'quantity', 99))) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'sales policy suite');
    v_st3 := erp.object_current_state('document', v_so);
    v_seq := public.erp_release_sequence(v_site, 500);
    select coalesce(f.demand, 0) into v_fc_after from erp.stock_forecast_lines(v_site, 90) f where f.item_id = v_item;
    return query select 'on an order still part despatched the line the policy reads delivered is not offered to the warehouse nor counted in the stock forecast, and the open line still is',
      v_st3 = 'partially_despatched'
      and not exists (select 1 from jsonb_array_elements(v_seq) e where e ->> 'line_id' = v_la::text)
      and exists (select 1 from jsonb_array_elements(v_seq) e where e ->> 'line_id' = v_lb::text)
      and coalesce(v_fc_before, 0) >= 100 and coalesce(v_fc_after, 0) = coalesce(v_fc_before, 0) - 100,
      format('order %s; widgets offered %s, gadgets offered %s; widget demand %s then %s', v_st3,
             exists (select 1 from jsonb_array_elements(v_seq) e where e ->> 'line_id' = v_la::text),
             exists (select 1 from jsonb_array_elements(v_seq) e where e ->> 'line_id' = v_lb::text),
             v_fc_before, v_fc_after);

    -- 6. The policy is proposed as a change, in its shape or not at all.
    begin
      perform erp.propose_sales_policy(null, null, jsonb_build_object('over_ship_pct', 150), null);
      v_bad := 'proposed';
    exception when others then v_bad := left(sqlerrm, 200); end;
    select s.code into v_log from erp.site s where s.id = v_site;
    v_item_id := erp.propose_sales_policy(null, v_log, jsonb_build_object('short_close_pct', 2), null);
    select i.payload into v_payload
      from erp.change_set_item i
     where i.tenant_id = r.tenant_id and i.object_kind = 'config'
       and i.object_key like 'sales.policy|%|' || v_log
     order by i.created_at desc limit 1;
    return query select 'the sales policy is proposed as an item of a change for a site, and a percentage over a hundred is refused by name',
      v_bad like 'CLOVEERP_POLICY_VALUE_INVALID:%'
      and v_payload ->> 'config_type' = 'sales.policy'
      and (v_payload -> 'value' ->> 'short_close_pct')::numeric = 2
      and v_payload ->> 'site' = v_log,
      format('refused: %s; proposed: %s', v_bad, v_payload);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-spol-' || v_hex);
  detail := 'the organisation, its policy, orders and deliveries rolled back';
  return next;
end;
$function$;

create or replace function erp_test.assert_despatch_tolerance_suite()
returns void
language plpgsql
security definer
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
    from erp_test.despatch_tolerance_suite() s;
  if v_total <> 7 then
    raise exception 'CLOVEERP_DESPATCH_TOLERANCE_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DESPATCH_TOLERANCE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An order that ships more than the policy allows, or reads despatched with too much still owed, is the case that failed. Read it.';
  end if;
end;
$$;

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
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
