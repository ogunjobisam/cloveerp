set lock_timeout = '30s';

-- =============================================================================
-- 20260923100000  The procurement policy is read where it acts
-- -----------------------------------------------------------------------------
-- PR4, M3: node P3 of docs/spec/simplification-review.md. The target flow
-- (docs/spec/p2p-target-flow.md §5) names thirteen parameters; PR4's decision
-- 5 delivers nine and defers four. Five of the nine already existed:
--
--   approval bands            the requisition_value chain (20260922380000)
--   reapproval price, value   approval.reapproval_tolerance, and the carried
--   reapproval on the party   approval's own tests (20260922380000)
--   over-receipt pct, action  erp.receipt_tolerance
--   invoice price tolerance   erp.match_tolerance
--
-- This adds the other three, as one configuration type rather than a second
-- settings mechanism: procurement.policy, read through erp.procurement_policy()
-- at the document's entity and site.
--
--   reapproval_qty_pct   read at Issue: a line of an order approved with its
--                        requisition may rise by this much and still issue
--                        (default 0: it may only fall)
--   short_close_pct      read by erp.order_receipt_position(): a line is
--                        received once no more than this share of it is
--                        outstanding (default 0; a new install writes 2)
--   invoice_match_mode   read by erp.match_three_way(): 'two_way' compares
--                        what is invoiced with what was ordered, for a line
--                        with no product; 'three_way' (the default), and any
--                        stocked line, with what was received
--
-- Deferred, as decided: requisition_required and direct_order_threshold_minor
-- (one switch that would refuse MRP, drop-ship, intercompany and blanket
-- orders), receipt_approval_required (a receipt has no approval state), and
-- the auto-approve threshold. Nine parameters for the cycle, inside doctrine
-- rule 7's fifteen.
--
-- ── WHAT ELSE ────────────────────────────────────────────────────────────────
--
-- Over-receipt is measured on everything received against the line, drafts
-- included, and this receipt. It was measured on the line's open quantity,
-- which counts drafts, so a second receipt behind a full draft saw nothing
-- open and was always accepted. The plan's "ordered less posted" would let the
-- same second receipt through, so it is not what this does.
--
-- A receipt that takes a line past what was ordered and is not refused leaves
-- a document.over_received event: the target flow's variance flag.
--
-- New installs of the procurement controls refuse an over-receipt beyond
-- tolerance ('reject') where they accepted it. An organisation that has them
-- keeps what it has: a receipt tolerance is not in the configuration
-- manifest, so an upgrade item for it would be offered for ever.
--
-- ── VERSION 3 ────────────────────────────────────────────────────────────────
--
-- Version 2's items are not changed, because organisations have promoted them.
-- Version 3 adds the policy item, and restates the purchase order machine
-- unchanged, because erp.undriven_transition_report() excuses inherit_approval
-- only while the CURRENT upgrade payload declares it (20260922380000). Every
-- later version must restate that machine too. A demonstration takes version 3
-- in its catch-up; a live organisation through Upgrade.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The policy
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value, consequence) values
  ('procurement.policy', 'policy', 'procurement',
   'config.procurement.policy',
   'How far a purchase order approved with its requisition may rise before it '
   'is issued, how little may be left outstanding for an order to read '
   'received, and whether a supplier''s bill is matched with the order alone or '
   'with what was received as well.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'reapproval_qty_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'short_close_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'invoice_match_mode', jsonb_build_object('type','string','enum',
         jsonb_build_array('three_way','two_way')))),
   'entity', true,
   jsonb_build_object('reapproval_qty_pct', 0, 'short_close_pct', 0,
                      'invoice_match_mode', 'three_way'),
   'Raising reapproval_qty_pct lets a buyer issue more than was approved; '
   'raising short_close_pct closes orders with goods still owed; two_way lets a '
   'bill settle goods nobody has received.')
on conflict (code) do nothing;

insert into erp_ref.resource (key, locale, value, description) values
  ('config.procurement.policy', 'en', 'Procurement policy',
   'The name of the procurement.policy configuration type.'),
  ('config.procurement.policy', 'de', 'Beschaffungsrichtlinie',
   'Der Name des Konfigurationstyps procurement.policy.')
on conflict (key, locale) do nothing;

create or replace function erp.procurement_policy(p_entity_id uuid default null,
                                                  p_site_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The procurement policy in force at an entity and site (20260923100000),
  -- layered key by key: the product's defaults, then what the organisation
  -- set, then its entity, then its site. A key a narrower value leaves out
  -- reads as the broader one's, not as the product default.
  select coalesce(ct.default_value, '{}'::jsonb)
      || coalesce(erp.config_value('procurement.policy', null, null, null, null), '{}'::jsonb)
      || case when p_entity_id is null then '{}'::jsonb
              else coalesce(erp.config_value('procurement.policy', null, null, p_entity_id, null), '{}'::jsonb) end
      || case when p_site_id is null then '{}'::jsonb
              else coalesce(erp.config_value('procurement.policy', null, null, p_entity_id, p_site_id), '{}'::jsonb) end
    from erp_ref.config_type ct
   where ct.code = 'procurement.policy'
$$;

comment on function erp.procurement_policy(uuid, uuid) is
  'procurement.policy at an entity and site, over its defaults (20260923100000). '
  'Read by erp.order_receipt_position (short_close_pct), erp.match_three_way '
  '(invoice_match_mode), erp.carried_order_change and '
  'erp.conversion_keeps_approval (reapproval_qty_pct).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C2. short_close_pct: an order is received when little enough is left
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.order_receipt_position(p_order_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- What the posted receipts say about an order: nothing yet, part of it, or
  -- all of it. Drafts hold a quantity against the line and receive nothing
  -- until they post. The lines are erp.receivable_lines(): the ones a receipt
  -- can be raised against, which leaves out cancelled lines and lines with no
  -- item.
  --
  -- A line is all there once what is outstanding on it is no more than the
  -- policy's short_close_pct of it (20260923100000). At the default, 0, that
  -- is every unit.
  select case
           when count(*) = 0
             or coalesce(sum(rl.received_quantity), 0) <= 0 then 'none'
           when bool_and(rl.received_quantity
                         >= rl.ordered_quantity * (1 - pp.short_close_pct / 100.0)) then 'full'
           else 'part'
         end
    from erp.receivable_lines(p_order_id) rl
    cross join (
      select coalesce((erp.procurement_policy(d.entity_id, d.site_id) ->> 'short_close_pct')::numeric, 0)
               as short_close_pct
        from erp.document d
       where d.tenant_id = erp.current_tenant_id() and d.id = p_order_id) pp
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C3. invoice_match_mode: two-way compares the bill with the order
-- ─────────────────────────────────────────────────────────────────────────────

do $match$
declare
  v_sig constant text := 'erp.match_three_way(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_qty_var numeric;
$o$;
  b1 constant text := $n$  v_qty_var numeric;
  v_base    numeric;
$n$;
  a2 constant text := $o$  v_qty_var := coalesce(ol.quantity_invoiced, 0) - coalesce(ol.quantity_fulfilled, 0);
  v_price_var := coalesce(v_inv_price, ol.unit_price_minor) - ol.unit_price_minor;

  v_qty_bad := coalesce(ol.quantity_fulfilled, 0) > 0
               and abs(v_qty_var) * 100.0 / ol.quantity_fulfilled
                   > coalesce(tol.quantity_pct, 0);
$o$;
  b2 constant text := $n$  -- Against what was received, unless the policy matches two ways
  -- (20260923100000) and the line is one nobody receives, having no product:
  -- then against what was ordered. A stocked line is matched against what
  -- arrived whatever the policy says, or a bill for goods that never came
  -- would settle its order and close it.
  v_base := case
              when erp.procurement_policy(d.entity_id, d.site_id) ->> 'invoice_match_mode' = 'two_way'
               and ol.item_id is null
                then coalesce(ol.quantity, 0)
              else coalesce(ol.quantity_fulfilled, 0)
            end;
  v_qty_var := coalesce(ol.quantity_invoiced, 0) - v_base;
  v_price_var := coalesce(v_inv_price, ol.unit_price_minor) - ol.unit_price_minor;

  v_qty_bad := v_base > 0
               and abs(v_qty_var) * 100.0 / v_base
                   > coalesce(tol.quantity_pct, 0);
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a1, b1), a2, b2);
end
$match$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C4. reapproval_qty_pct: what a born-approved order may become before Issue
--
-- 20260922380000 refused Issue on any change at all. The carried event now
-- records each line, so a line may fall or be cancelled (less than approved
-- always carries) and may rise by reapproval_qty_pct. A new line, or a line
-- whose item, unit, price, discount, words or currency changed, is refused as
-- before. An order carried before this has no lines on its event and is held
-- to its fingerprint exactly, as it was.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.carried_order_change(p_order_id uuid, p_carry jsonb)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_pct    numeric;
  v_why    text;
begin
  if p_carry is null then
    return null;
  end if;

  if jsonb_typeof(p_carry -> 'order_lines') is distinct from 'array' then
    if (p_carry ->> 'order_line_fingerprint') is distinct from erp.document_line_fingerprint(p_order_id)
       or (p_carry ->> 'order_value_minor')::bigint is distinct from erp.document_value_minor(p_order_id) then
      return 'changed since it was converted';
    end if;
    return null;
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = p_order_id;
  v_pct := coalesce((erp.procurement_policy(d.entity_id, d.site_id) ->> 'reapproval_qty_pct')::numeric, 0);

  select case
           when c.line is null then 'a line was added'
           when (c.line ->> 'item_id') is distinct from l.item_id::text
             or (c.line ->> 'uom_id') is distinct from l.uom_id::text
             or (c.line ->> 'unit_price_minor')::bigint is distinct from l.unit_price_minor
             or coalesce((c.line ->> 'discount_pct')::numeric, 0) <> coalesce(l.discount_pct, 0)
             or (c.line ->> 'description') is distinct from l.description
             or (c.line ->> 'currency') is distinct from l.currency::text
             then 'a line was changed'
           when l.quantity > (c.line ->> 'quantity')::numeric * (1 + v_pct / 100.0)
             or coalesce(l.net_minor, 0) > coalesce((c.line ->> 'net_minor')::numeric,
                                                    (c.line ->> 'quantity')::numeric
                                                    * (c.line ->> 'unit_price_minor')::numeric)
                                           * (1 + v_pct / 100.0) + 1
             then format('a line rose by more than %s per cent', v_pct)
         end
    into v_why
    from erp.document_line l
    left join lateral (
      select e.value as line
        from jsonb_array_elements(p_carry -> 'order_lines') e
       where e.value ->> 'id' = l.id::text) c on true
   where l.tenant_id = v_tenant and l.document_id = p_order_id and not l.is_cancelled
     and (c.line is null
          or (c.line ->> 'item_id') is distinct from l.item_id::text
          or (c.line ->> 'uom_id') is distinct from l.uom_id::text
          or (c.line ->> 'unit_price_minor')::bigint is distinct from l.unit_price_minor
          or coalesce((c.line ->> 'discount_pct')::numeric, 0) <> coalesce(l.discount_pct, 0)
          or (c.line ->> 'description') is distinct from l.description
          or (c.line ->> 'currency') is distinct from l.currency::text
          or l.quantity > (c.line ->> 'quantity')::numeric * (1 + v_pct / 100.0)
          or coalesce(l.net_minor, 0) > coalesce((c.line ->> 'net_minor')::numeric,
                                                 (c.line ->> 'quantity')::numeric
                                                 * (c.line ->> 'unit_price_minor')::numeric)
                                        * (1 + v_pct / 100.0) + 1)
   order by l.line_no
   limit 1;

  -- And the order as a whole, found on review: every line's value is its
  -- own, and a line written up directly would otherwise be read only by its
  -- quantity and price.
  if v_why is null
     and erp.document_value_minor(p_order_id)
         > (p_carry ->> 'order_value_minor')::numeric * (1 + v_pct / 100.0)
           + jsonb_array_length(p_carry -> 'order_lines') then
    v_why := format('the order rose by more than %s per cent', v_pct);
  end if;

  return v_why;
end $$;

comment on function erp.carried_order_change(uuid, jsonb) is
  'Why a purchase order approved with its requisition may not be issued as it '
  'now stands, or null (20260923100000): a line added or changed, or risen by '
  'more than procurement.policy''s reapproval_qty_pct. Read by the Issue guard '
  'in erp.transition_document().';

do $issue$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    if v_carry is not null
       and ((v_carry ->> 'order_line_fingerprint') is distinct from erp.document_line_fingerprint(p_document_id)
            or (v_carry ->> 'order_value_minor')::bigint is distinct from erp.document_value_minor(p_document_id)) then
      raise exception
        'CLOVEERP_CARRIED_ORDER_CHANGED: % has changed since it was approved with its requisition',
        coalesce(d.document_number, p_document_id::text)
$o$;
  v_new constant text := $n$    -- What it may have become is erp.carried_order_change()'s to say
    -- (20260923100000): less, or more by the policy's reapproval_qty_pct.
    if v_carry is not null
       and erp.carried_order_change(p_document_id, v_carry) is not null then
      raise exception
        'CLOVEERP_CARRIED_ORDER_CHANGED: % has changed since it was approved with its requisition: %',
        coalesce(d.document_number, p_document_id::text),
        erp.carried_order_change(p_document_id, v_carry)
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % issue anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$issue$;

-- The carried event records each line, and the family of orders raised from
-- one requisition may exceed its approved value by the same share.
do $carry$
declare
  v_sig constant text := 'erp.conversion_keeps_approval(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_over := v_cum - q.value_at_approval;
  if v_over > v_lines then
$o$;
  b1 constant text := $n$  v_over := v_cum - q.value_at_approval;
  -- By rounding, and by as much as reapproval_qty_pct lets a line rise
  -- (20260923100000); at its default, 0, by rounding only.
  if v_over > v_lines
              + floor(q.value_at_approval
                      * coalesce((erp.procurement_policy(o.entity_id, o.site_id)
                                  ->> 'reapproval_qty_pct')::numeric, 0) / 100.0) then
$n$;
  a2 constant text := $o$    'order_value_minor', erp.document_value_minor(p_order_id));
$o$;
  b2 constant text := $n$    'order_value_minor', erp.document_value_minor(p_order_id),
    -- Each line as it was carried, for the Issue guard (20260923100000).
    'order_lines', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', l.id, 'item_id', l.item_id, 'uom_id', l.uom_id,
               'unit_price_minor', l.unit_price_minor,
               'discount_pct', coalesce(l.discount_pct, 0),
               'description', l.description, 'currency', l.currency,
               'quantity', l.quantity, 'net_minor', l.net_minor) order by l.id), '[]'::jsonb)
        from erp.document_line l
       where l.tenant_id = v_tenant and l.document_id = p_order_id and not l.is_cancelled));
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a1, b1), a2, b2);
end
$carry$;

update erp_ref.event_type
   set payload_schema = jsonb_set(payload_schema, '{properties,order_lines}',
                                  jsonb_build_object('type', 'array'))
 where code = 'document.approval_carried' and version = 1
   and not (payload_schema -> 'properties' ? 'order_lines');

-- ─────────────────────────────────────────────────────────────────────────────
-- C5. Over-receipt, measured on the line, and flagged when it is let through
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('document.over_received', 1, 'document', 'procurement', 'event.document.over_received',
  'A goods receipt took an order line past what was ordered, inside its tolerance or held for a decision.',
  jsonb_build_object('type','object',
    'required', jsonb_build_array('order_id','order_line_id','receipt_line_id',
                                  'ordered_quantity','received_quantity','over_pct','action'),
    'properties', jsonb_build_object(
      'order_id', jsonb_build_object('type','string'),
      'order_line_id', jsonb_build_object('type','string'),
      'receipt_line_id', jsonb_build_object('type','string'),
      'ordered_quantity', jsonb_build_object('type','number'),
      'received_quantity', jsonb_build_object('type','number'),
      'over_pct', jsonb_build_object('type','number'),
      'action', jsonb_build_object('type','string'))), true)
on conflict (code, version) do nothing;
insert into erp_ref.resource (key, locale, value) values
  ('event.document.over_received', 'en', 'Received more than was ordered'),
  ('event.document.over_received', 'de', 'Mehr erhalten als bestellt')
on conflict (key, locale) do nothing;

do $receive$
declare
  v_sig constant text := 'erp.receive_against(uuid,uuid,numeric,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_open    numeric;
$o$;
  b1 constant text := $n$  v_open    numeric;
  v_before  numeric;
$n$;
  a2 constant text := $o$  -- Tolerance is measured against what is still open, not against the whole
  -- order line: three receipts of a third each are not each a two-thirds
  -- under-delivery.
  v_open := ol.quantity - coalesce(ol.quantity_fulfilled, 0);
  v_action := erp.check_receipt_tolerance(ol.item_id, od.party_id, v_open, p_quantity);
$o$;
  b2 constant text := $n$  -- Tolerance is measured on the line: everything already received against
  -- it, drafts included, and this receipt, against what was ordered
  -- (20260923100000). It was measured on what was still open, which counts
  -- drafts, so a receipt behind a full draft saw nothing open and was always
  -- accepted, however much it brought.
  --
  -- A cancelled line, one with no product and one with nothing on it take no
  -- receipt, as erp.create_receipt_from_order() already says (found on
  -- review: a cancelled line was received without limit).
  if ol.is_cancelled or ol.item_id is null or coalesce(ol.quantity, 0) <= 0 then
    raise exception 'CLOVEERP_NOT_A_LINE_TO_RECEIVE: % is not an open product line of %', p_order_line_id, od.document_number
      using errcode = '23503',
            hint = 'Choose lines of the order the goods arrived against. A cancelled line, or one with no product, is not received.';
  end if;
  select coalesce(sum(rel.quantity), 0) into v_before
    from erp.document_relation rel
    join erp.document rd2 on rd2.tenant_id = rel.tenant_id and rd2.id = rel.from_document_id
    join erp.document_type rdt2 on rdt2.tenant_id = rd2.tenant_id and rdt2.id = rd2.document_type_id
    left join erp.object_state ros on ros.tenant_id = rd2.tenant_id
                                  and ros.object_type = 'document' and ros.object_id = rd2.id
    left join erp.state rs on rs.id = ros.current_state_id
   where rel.tenant_id = v_tenant and rel.to_line_id = p_order_line_id
     and rel.relation_kind = 'fulfils' and rdt2.base_type_code = 'receipt'
     and not (rd2.is_cancelled or coalesce(rs.code = 'cancelled', false));
  v_open := greatest(ol.quantity - v_before, 0);
  v_action := erp.check_receipt_tolerance(ol.item_id, od.party_id, ol.quantity, v_before + p_quantity);
$n$;
  a3 constant text := $o$                           'ordered', v_open, 'received', p_quantity,
$o$;
  b3 constant text := $n$                           'ordered', ol.quantity, 'received', v_before + p_quantity,
$n$;
  a4 constant text := $o$  perform erp.refresh_order_line_progress(p_order_line_id);

  return v_line;
$o$;
  b4 constant text := $n$  perform erp.refresh_order_line_progress(p_order_line_id);

  -- The variance flag (20260923100000): past what was ordered and not
  -- refused, so somebody can see it without the receipt having been stopped.
  if ol.quantity > 0 and v_before + p_quantity > ol.quantity then
    perform erp.append_event('document.over_received', 'document', p_receipt_id,
      jsonb_build_object(
        'order_id', od.id, 'order_line_id', p_order_line_id, 'receipt_line_id', v_line,
        'ordered_quantity', ol.quantity, 'received_quantity', v_before + p_quantity,
        'over_pct', round((v_before + p_quantity - ol.quantity) * 100.0 / ol.quantity, 3),
        'action', v_action),
      rd.entity_id, rd.site_id);
  end if;

  return v_line;
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3),
      (length(v_def) - length(replace(v_def, a4, ''))) / length(a4)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3), a4, b4);
end
$receive$;

-- New installs refuse an over-receipt beyond tolerance.
do $controls$
declare
  v_sig constant text := 'erp.configure_procurement_controls(text,numeric,numeric,bigint)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$          'over_action','accept')),
$o$;
  v_new constant text := $n$          -- Beyond tolerance is refused (20260923100000): stock nobody agreed
          -- to buy. An organisation installed before keeps what it has.
          'over_action','reject')),
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % tolerance anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$controls$;

-- An upgrade never replaces a setting the organisation holds (found on
-- review): version 3's policy item is a whole value, and promoted over a
-- policy somebody set before pressing Upgrade it would put back the defaults.
-- A config item is planned only where the organisation has nothing for it.
do $plan$
declare
  v_sig constant text := 'erp.plan_module_upgrade(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$         case ui.object_kind
           when 'posting_rule' then exists (
$o$;
  v_new constant text := $n$         case ui.object_kind
           -- A setting the organisation holds is its own (20260923100000).
           when 'config' then exists (
             select 1 from erp.config_object co
              where co.tenant_id = v_tenant and co.status = 'active'
                and co.config_type_code = ui.payload ->> 'config_type'
                and co.code is not distinct from (ui.payload ->> 'code')
                and co.entity_id is null and co.site_id is null)
           when 'posting_rule' then exists (
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % kind anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$plan$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C6. Version 3 of the procurement lifecycle
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function erp.procurement_lifecycle_items(
  p_entity_code text, p_threshold_minor bigint, p_approver_role text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 3 of the procurement lifecycle (20260923100000; version 2 was
  -- 20260922380000), read by
  -- erp.configure_procurement() for a new install and by the upgrade register
  -- for an organisation on version 1, so the two cannot disagree.
  select jsonb_build_array(
      jsonb_build_object('kind','state_machine','key','requisition','payload',
        jsonb_build_object(
          'code','requisition','object_type','document','name','Requisition',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','submitted','name','Submitted','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','ordered','name','Ordered','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','submitted','required_permission','procurement.requisition','effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
            jsonb_build_object('code','approve','name','Approve','from','submitted','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','submitted','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','order','name','Convert to order','from','approved','to','ordered','required_permission','procurement.order','is_automatic',true),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.requisition'),
            jsonb_build_object('code','cancel_submitted','name','Cancel','from','submitted','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','purchase_order','payload',
        jsonb_build_object(
          'code','purchase_order','object_type','document','name','Purchase order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','sent','name','Issued','is_committed',true,'sort_order',40),
            jsonb_build_object('code','partially_received','name','Partially received','is_committed',true,'sort_order',50),
            jsonb_build_object('code','received','name','Received','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit for approval','from','draft','to','pending_approval','required_permission','procurement.order','effects',jsonb_build_array(jsonb_build_object('kind','require_approval'))),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','inherit_approval','name','Approved with its requisition','from','draft','to','approved','required_permission','procurement.order','is_automatic',true),
            jsonb_build_object('code','send','name','Issue to supplier','from','approved','to','sent','required_permission','procurement.order'),
            jsonb_build_object('code','receive_partial','name','Receive part','from','sent','to','partially_received','required_permission','procurement.receive','is_automatic',true),
            jsonb_build_object('code','receive_rest','name','Receive remainder','from','partially_received','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','receive_all','name','Receive in full','from','sent','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','close','name','Close','from','received','to','closed','required_permission','procurement.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.order'),
            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','object_type','document','name','Goods receipt',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','procurement.receive'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.receive')))),

      jsonb_build_object('kind','approval_chain','key','purchase_order_value','payload',
        jsonb_build_object(
          'code','purchase_order_value','name','Purchase order value approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'purchase_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer_manager','name','Buying manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','finance','name','Finance',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','total_minor'), p_threshold_minor)))))),

      -- The requisition is asked what the order used to be asked, so the order
      -- raised from it need not be asked again.
      jsonb_build_object('kind','approval_chain','key','requisition_value','payload',
        jsonb_build_object(
          'code','requisition_value','name','Requisition value approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'requisition')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer_manager','name','Buying manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','finance','name','Finance',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','total_minor'), p_threshold_minor)))))),

      -- The spine, in the change set and after the lifecycles it names.
      -- erp.promote_change_set() applies items in seq order and
      -- erp.add_change_set_item() assigns seq in the order they appear here,
      -- so a document type is written only once its state machine, its chain
      -- and its sequence exist.
      jsonb_build_object('kind','numbering_rule','key','requisition','payload',
        jsonb_build_object('code','requisition','entity',p_entity_code,
          'prefix','REQ-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','purchase_order','payload',
        jsonb_build_object('code','purchase_order','entity',p_entity_code,
          'prefix','PO-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','goods_receipt','payload',
        jsonb_build_object('code','goods_receipt','entity',p_entity_code,
          'prefix','GRN-','pad_to',6,'reset_period','yearly','next_value',1)),

      -- A requisition asks; it neither moves stock nor reaches a ledger. The
      -- nulls are the honest answer rather than an omission:
      -- erp.assert_no_dead_configuration() fails the build if a base type
      -- disagrees with them in either direction.
      jsonb_build_object('kind','document_type','key','requisition','payload',
        jsonb_build_object('code','requisition','base_type','requisition',
          'name','Requisition','entity',p_entity_code,
          'numbering_rule','requisition','state_machine','requisition',
          'approval_chain','requisition_value')),
      -- An order commits. Nothing has moved and nothing is owed yet, so the
      -- entry belongs in the parallel commitment ledger, not the statutory one.
      jsonb_build_object('kind','document_type','key','purchase_order','payload',
        jsonb_build_object('code','purchase_order','base_type','purchase_order',
          'name','Purchase order','entity',p_entity_code,
          'numbering_rule','purchase_order','state_machine','purchase_order',
          'approval_chain','purchase_order_value',
          'posting_rule','purchase_commitment')),
      -- A receipt is the first point at which both ledgers have something to say.
      jsonb_build_object('kind','document_type','key','goods_receipt','payload',
        jsonb_build_object('code','goods_receipt','base_type','receipt',
          'name','Goods receipt','entity',p_entity_code,
          'numbering_rule','goods_receipt','state_machine','goods_receipt',
          'stock_movement_type','goods_receipt',
          'posting_rule','goods_receipt')),

      -- The procurement policy (version 3, 20260923100000): a new install
      -- closes an order short when what is still outstanding on a line is no
      -- more than two per cent of it, as the target flow asks. The key is the
      -- configuration manifest's, so the upgrade can tell it is held.
      jsonb_build_object('kind','config','key','procurement.policy||-|-','payload',
        jsonb_build_object('config_type','procurement.policy','value',
          jsonb_build_object('reapproval_qty_pct',0,'short_close_pct',2,
                             'invoice_match_mode','three_way'))))
$$;

comment on function erp.procurement_lifecycle_items(text, bigint, text) is
  'The procurement lifecycle''s configuration items at the installer''s current '
  'version (3, 20260923100000): what erp.configure_procurement() installs and '
  'what the upgrade register offers an organisation on an earlier version.';

update erp_ref.module_installer
   set current_version = 3,
       description = description
         || ' Version 3 (20260923100000): the procurement policy, with orders '
         || 'closed short when no more than two per cent is outstanding.'
 where install_code = 'procurement-lifecycle' and current_version = 2;

-- The policy, and the purchase order machine restated as version 2 left it:
-- the undriven report excuses inherit_approval only while the current
-- version's payload declares it. Its seq is version 2's, so an organisation
-- on version 1 takes one purchase order machine, not two.
insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'procurement-lifecycle', 3, x.value ->> 'kind', x.value ->> 'key',
       (x.value -> 'payload') - 'entity',
       case x.value ->> 'kind' when 'state_machine' then 110 else 140 end
  from jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) x
 where (x.value ->> 'kind', x.value ->> 'key') in (
         ('state_machine','purchase_order'), ('config','procurement.policy||-|-'))
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
declare
  v_n integer;
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'procurement-lifecycle') is distinct from 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the procurement lifecycle installer is not at version 3';
  end if;
  select count(*) into v_n
    from erp_ref.module_upgrade_item ui
    join jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) x
      on x.value ->> 'kind' = ui.object_kind and x.value ->> 'key' = ui.object_key
     and (x.value -> 'payload') - 'entity' = ui.payload
   where ui.install_code = 'procurement-lifecycle' and ui.to_version = 3;
  if v_n <> 2 or (select count(*) from erp_ref.module_upgrade_item
                   where install_code = 'procurement-lifecycle' and to_version = 3) <> 2 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 3 of the procurement lifecycle has % matching item(s), expected 2', v_n;
  end if;
  -- Version 2's items are what organisations promoted, and stay as they were.
  if (select count(*) from erp_ref.module_upgrade_item
       where install_code = 'procurement-lifecycle' and to_version = 2) <> 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 2 of the procurement lifecycle no longer has its four items';
  end if;
end
$register$;

-- Version 1 for the suites, less the policy it never had.
create or replace function erp_test.procurement_lifecycle_v1_items(
  p_entity_code text, p_threshold_minor bigint default 1000000,
  p_approver_role text default 'administrator')
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(
    case
      when x.item ->> 'kind' = 'state_machine' and x.item ->> 'key' in ('requisition', 'purchase_order') then
        jsonb_set(jsonb_set(x.item, '{payload,transitions}',
          (select jsonb_agg(case when t.tr ->> 'code' = 'send'
                                 then (t.tr - 'is_automatic') || jsonb_build_object('name', 'Send to supplier')
                                 else t.tr - 'is_automatic' end order by t.o)
             from jsonb_array_elements(x.item -> 'payload' -> 'transitions') with ordinality t(tr, o)
            where t.tr ->> 'code' <> 'inherit_approval')),
          '{payload,states}',
          (select jsonb_agg(case when s.st ->> 'code' = 'sent'
                                 then s.st || jsonb_build_object('name', 'Sent to supplier') else s.st end order by s.o)
             from jsonb_array_elements(x.item -> 'payload' -> 'states') with ordinality s(st, o)))
      when x.item ->> 'kind' = 'document_type' and x.item ->> 'key' = 'requisition'
        then x.item #- '{payload,approval_chain}'
      else x.item end
    order by x.n)
  from jsonb_array_elements(erp.procurement_lifecycle_items(p_entity_code, p_threshold_minor, p_approver_role))
       with ordinality x(item, n)
  where not (x.item ->> 'kind' = 'approval_chain' and x.item ->> 'key' = 'requisition_value')
    and x.item ->> 'kind' <> 'config'
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C7. What proves it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.procurement_reseed_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_names constant text[] := array[
    'v1 as it stood: a requisition type with no chain approves on its permission',
    'the upgrade offers the four changes of version 2 and those of every later version, and says which replace what the organisation holds',
    'upgraded through Upgrade to the current version, v1 ends today and v2 starts today, both stay active, and the policy is held',
    'documents in flight finish on v1: the received order closes on its bill, the part-received one moves on with its next receipt',
    'an approval given on v1 carries nothing',
    'a requisition raised after the upgrade asks for requisition_value, and its order is born approved',
    'in the mixed state the undriven, reachable and dead-configuration reports read 0',
    'a move code the current upgrade payload ships is excused before anyone holds it',
    'a code only an older payload, or another lifecycle, declares is still reported',
    'the upgraded objects equal a fresh install of the current version at the defaults, compared through the manifest',
    'the upgrade rolls back through its snapshot: new documents start on the restored content, documents raised on v2 stay on v2',
    'an organisation that customised v1 keeps its order chain and gets the requisition chain at the defaults',
    'the catch-up upgrades a demonstration once and says so, and a second run plans nothing',
    'an upgrade that raises becomes a note: the demonstration stays on v1 and the catch-up carries on',
    'in a live organisation the upgrade is authored and waits, and its author cannot approve it',
    'a second administrator promotes it, the promotion stamps the installation, and it reads the current version',
    'the live organisation''s documents in flight finish on v1 after the promotion',
    'D2, fail closed: in a live organisation a requisition approved only by its requester carries nothing',
    'the suite leaves nothing behind'];
  v_codes constant text[] := array['zzrsa', 'zzrsf', 'zzrsb', 'demo-zzreseed', 'zzrsc'];
  v_undo  constant text := 'CLOVEERP_RESEED_SUITE_UNDO';
  v_items_before integer;
  -- The version this release ships, the upgrade rows an organisation on v1 is
  -- offered, the distinct objects they name, and the lifecycle's rows as they
  -- stood before the suite ran.
  v_cur   integer;
  v_after_v1 integer;
  v_objects_after_v1 integer;
  v_items_snap jsonb;
  v_step  integer := 0;
  v_ok    boolean;
  v_msg   text;
  v_err   text;
  v_purge_err text;
  v_ok14  boolean;
  v_msg14 text;
  i       integer;

  -- Who each organisation's administrators are to the database.
  a_a  uuid := gen_random_uuid();
  a_f  uuid := gen_random_uuid();
  a_b  uuid := gen_random_uuid();
  a_d  uuid := gen_random_uuid();
  a_c  uuid := gen_random_uuid();
  a_c2 uuid := gen_random_uuid();
  u_c2 uuid;
  v_tok text;

  ta uuid; tf uuid; tb uuid; td uuid; tc uuid;
  r  record;
  x  record;
  res jsonb; res2 jsonb;
  v_ent_code text; v_ent uuid; v_site uuid; v_item uuid; v_sup uuid;

  -- Organisation A's documents and versions.
  a_rq_draft uuid; a_rq_sub uuid; a_rq_app uuid;
  a_po_draft uuid; a_po_pend uuid; a_po_app uuid; a_po_sent uuid;
  a_po_part uuid; a_pl_part uuid; a_po_recv uuid; a_pl_recv uuid;
  a_req_v1 uuid; a_po_v1 uuid; a_req_v2 uuid; a_po_v2 uuid;
  a_cs uuid; a_rq_new uuid; a_po_born uuid;
  -- Organisation C's.
  c_po_app uuid; c_po_recv uuid; c_pl_recv uuid; c_rq_sub uuid; c_req_v1 uuid; c_po_v1 uuid;
  c_cs uuid;

  v_doc uuid; v_doc2 uuid; v_line uuid; v_g uuid; v_bill uuid;
  v_st text; v_st2 text; v_n integer; v_n2 integer; v_n3 integer;
  v_a jsonb; v_f jsonb; v_reg jsonb;
begin
  select count(*) into v_items_before from erp_ref.module_upgrade_item;
  select mi.current_version into v_cur from erp_ref.module_installer mi where mi.install_code = 'procurement-lifecycle';
  select count(*), count(distinct (ui.object_kind, ui.object_key))
    into v_after_v1, v_objects_after_v1
    from erp_ref.module_upgrade_item ui
   where ui.install_code = 'procurement-lifecycle' and ui.to_version > 1;
  select coalesce(jsonb_agg(to_jsonb(ui) order by ui.to_version, ui.object_kind, ui.object_key), '[]'::jsonb)
    into v_items_snap
    from erp_ref.module_upgrade_item ui where ui.install_code = 'procurement-lifecycle';

  begin
    -- ═════════════════════════════════════════════════════════════════════
    -- Organisation A: not live, v1 at the defaults, backdated 30 days
    -- ═════════════════════════════════════════════════════════════════════
    select * into r from erp.provision_tenant('zzrsa', 'Reseed Suite A', 'admin@zzrsa.test', 'Reseed Admin A');
    ta := r.tenant_id; v_ent := r.entity_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_a)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = ta and is_self;
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    select e.code into v_ent_code from erp.entity e where e.tenant_id = ta and e.id = v_ent;
    perform erp.install_module_config('procurement-lifecycle', 'Procurement lifecycle',
      'Version 1, as an organisation installed it before 20260922380000',
      erp_test.procurement_lifecycle_v1_items(v_ent_code));
    -- install_module_config() records the installer's current version; this
    -- organisation installed version 1, thirty days ago.
    update erp.module_installation
       set installer_version = 1, installed_at = now() - interval '30 days'
     where tenant_id = ta and install_code = 'procurement-lifecycle';
    res := erp.ensure_demo_configuration(ta, r.admin_user_id);
    v_site := (res ->> 'site_id')::uuid;
    update erp.state_machine_version v set effective_from = current_date - 30
      from erp.state_machine m
     where m.tenant_id = ta and m.id = v.state_machine_id and v.tenant_id = ta
       and m.code in ('purchase_order', 'requisition');
    select v.id into a_req_v1 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = ta and m.code = 'requisition' and v.version = 1;
    select v.id into a_po_v1 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = ta and m.code = 'purchase_order' and v.version = 1;
    select it.id into v_item from erp.item it where it.tenant_id = ta and it.status = 'active' order by it.code limit 1;
    select p.id into v_sup from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'supplier'
     where p.tenant_id = ta and p.status = 'active' order by p.code limit 1;

    -- In flight on v1.
    a_rq_draft := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_rq_draft, v_item, 3, 1000, 'v1 draft');
    a_rq_sub := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_rq_sub, v_item, 3, 1000, 'v1 submitted');
    perform erp.transition_document(a_rq_sub, 'submit');
    a_rq_app := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_rq_app, v_item, 3, 1000, 'v1 approved');
    perform erp.transition_document(a_rq_app, 'submit');
    v_st := erp.transition_document(a_rq_app, 'approve');

    a_po_draft := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_po_draft, v_item, 10, 1000, 'v1 order draft');
    a_po_pend := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_po_pend, v_item, 10, 1000, 'v1 order pending');
    perform erp.transition_document(a_po_pend, 'submit');
    a_po_app := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_po_app, v_item, 10, 1000, 'v1 order approved');
    perform erp.transition_document(a_po_app, 'submit');
    perform erp_test.approve_document(a_po_app, 'the reseed suite');
    a_po_sent := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_po_sent, v_item, 10, 1000, 'v1 order sent');
    perform erp.transition_document(a_po_sent, 'submit');
    perform erp_test.approve_document(a_po_sent, 'the reseed suite');
    perform erp.transition_document(a_po_sent, 'send');
    a_po_part := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    a_pl_part := erp.add_document_line(a_po_part, v_item, 10, 1000, 'v1 order part received');
    perform erp.transition_document(a_po_part, 'submit');
    perform erp_test.approve_document(a_po_part, 'the reseed suite');
    perform erp.transition_document(a_po_part, 'send');
    v_g := erp.open_document('goods_receipt', v_sup, v_ent, v_site);
    perform erp.receive_against(v_g, a_pl_part, 4, null);
    perform erp.transition_document(v_g, 'post');
    a_po_recv := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    a_pl_recv := erp.add_document_line(a_po_recv, v_item, 10, 1000, 'v1 order received');
    perform erp.transition_document(a_po_recv, 'submit');
    perform erp_test.approve_document(a_po_recv, 'the reseed suite');
    perform erp.transition_document(a_po_recv, 'send');
    v_g := erp.open_document('goods_receipt', v_sup, v_ent, v_site);
    perform erp.receive_against(v_g, a_pl_recv, 10, null);
    perform erp.transition_document(v_g, 'post');

    -- ── 1 ────────────────────────────────────────────────────────────────
    select count(*) into v_n from erp.approval_request q where q.tenant_id = ta and q.object_id = a_rq_app;
    v_ok := v_st = 'approved' and v_n = 0
      and (select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = ta and dt.code = 'requisition') is null
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_rq_app) = a_req_v1;
    v_msg := format('the v1 requisition moved to %s with %s approval request(s); its type names chain %s',
                    v_st, v_n, coalesce((select dt.approval_chain_code from erp.document_type dt
                                          where dt.tenant_id = ta and dt.code = 'requisition'), 'none'));
    return query select v_names[1], coalesce(v_ok, false), v_msg; v_step := 1;

    -- ── 2 ────────────────────────────────────────────────────────────────
    select count(*),
           count(*) filter (where p.effect = 'a newer version of configuration the organisation holds, which replaces it'
                              and (p.object_kind, p.object_key) in (('state_machine','requisition'),
                                    ('state_machine','purchase_order'), ('document_type','requisition'))),
           count(*) filter (where p.effect = 'configuration the organisation lacks'
                              and (p.object_kind, p.object_key) = ('approval_chain','requisition_value')),
           string_agg(p.object_kind || '.' || p.object_key || ' [' || p.effect || ']', '; ' order by p.seq)
      into v_n, v_n2, v_n3
      from erp.plan_module_upgrade('procurement-lifecycle') p
     where p.to_version = 2
       and exists (select 1 from erp_ref.module_upgrade_item ui
                    where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2
                      and ui.object_kind = p.object_kind and ui.object_key = p.object_key
                      and ui.payload = p.payload);
    select string_agg(format('v%s %s.%s [%s]', p.to_version, p.object_kind, p.object_key, p.effect), '; '
                      order by p.seq, p.to_version)
      into v_msg from erp.plan_module_upgrade('procurement-lifecycle') p;
    v_ok := v_n = 4 and v_n2 = 3 and v_n3 = 1
      -- Every row of every version after 1, each exactly as registered.
      and (select count(*) from erp.plan_module_upgrade('procurement-lifecycle')) = v_after_v1
      and (select count(*) from erp.plan_module_upgrade('procurement-lifecycle') p
            where p.to_version between 2 and v_cur
              and exists (select 1 from erp_ref.module_upgrade_item ui
                           where ui.install_code = 'procurement-lifecycle' and ui.to_version = p.to_version
                             and ui.object_kind = p.object_kind and ui.object_key = p.object_key
                             and ui.payload = p.payload)) = v_after_v1
      -- The current version restates the order machine as version 2 left it,
      -- which is what keeps inherit_approval excused.
      and exists (select 1 from erp.plan_module_upgrade('procurement-lifecycle') p
                   where p.to_version = v_cur and (p.object_kind, p.object_key) = ('state_machine', 'purchase_order')
                     and p.effect = 'a newer version of configuration the organisation holds, which replaces it'
                     and p.payload = (select ui.payload from erp_ref.module_upgrade_item ui
                                       where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2
                                         and (ui.object_kind, ui.object_key) = ('state_machine', 'purchase_order')))
      -- Version 1 had no procurement policy.
      and exists (select 1 from erp.plan_module_upgrade('procurement-lifecycle') p
                   where p.to_version > 2 and (p.object_kind, p.object_key) = ('config', 'procurement.policy||-|-')
                     and p.effect = 'configuration the organisation lacks');
    return query select v_names[2], coalesce(v_ok, false), coalesce(v_msg, 'nothing planned'); v_step := 2;

    -- ── 3 ────────────────────────────────────────────────────────────────
    res := erp.upgrade_module_configuration('procurement-lifecycle');
    a_cs := (res ->> 'change_set_id')::uuid;
    select v.id into a_req_v2 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = ta and m.code = 'requisition' and v.version = 2;
    select v.id into a_po_v2 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = ta and m.code = 'purchase_order' and v.version = 2;
    select string_agg(format('%s v%s %s %s..%s', m.code, v.version, v.status, v.effective_from,
                             coalesce(v.effective_to::text, '')), ', ' order by m.code, v.version),
           count(*) filter (where v.version = 1 and v.status = 'active' and v.effective_to = current_date),
           count(*) filter (where v.version = 2 and v.status = 'active' and v.effective_from = current_date
                              and v.effective_to is null)
      into v_msg, v_n, v_n2
      from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
     where m.tenant_id = ta and m.code in ('requisition', 'purchase_order');
    -- Every version's rows are planned, but an object two versions restate is
    -- one change-set item, and an unchanged restatement makes no third
    -- machine version.
    v_n3 := (select count(*) from erp.change_set_item ci where ci.tenant_id = ta and ci.change_set_id = a_cs);
    v_ok := (res ->> 'promoted')::boolean and (res ->> 'items')::integer = v_after_v1
      and (res ->> 'to_version')::integer = v_cur
      and v_n = 2 and v_n2 = 2 and v_n3 = v_objects_after_v1
      and (select count(*) from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
            where m.tenant_id = ta and m.code in ('requisition', 'purchase_order')) = 4
      and (select i.installer_version = v_cur and i.pending_change_set_id is null and i.change_set_id = a_cs
             from erp.module_installation i where i.tenant_id = ta and i.install_code = 'procurement-lifecycle')
      and erp.procurement_policy(null, null) ->> 'short_close_pct' = '2';
    return query select v_names[3], coalesce(v_ok, false),
      format('%s; %s change-set item(s) of %s object(s); %s; policy %s', res - 'change_set_id', v_n3, v_objects_after_v1,
             v_msg, erp.procurement_policy(null, null)); v_step := 3;

    -- ── 4 ────────────────────────────────────────────────────────────────
    v_bill := erp.open_document('purchase_invoice', v_sup, v_ent, v_site);
    perform erp.invoice_against(v_bill, a_pl_recv, 10, 1000);
    update erp.document set their_reference = 'ZZRS-A-1', due_date = current_date + 30
     where tenant_id = ta and id = v_bill;
    perform erp.transition_document(v_bill, 'register');
    v_g := erp.open_document('goods_receipt', v_sup, v_ent, v_site);
    perform erp.receive_against(v_g, a_pl_part, 6, null);
    perform erp.transition_document(v_g, 'post');
    v_st := erp.transition_document(a_po_app, 'send');
    v_st2 := erp_test.approve_document(a_po_pend, 'the reseed suite');
    v_ok := erp.object_current_state('document', a_po_recv) = 'closed'
      and erp.object_current_state('document', a_po_part) = 'received'
      and v_st = 'sent' and v_st2 = 'approved'
      and (select st.name from erp.object_state os join erp.state st on st.id = os.current_state_id
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_po_app) = 'Sent to supplier'
      and not exists (select 1 from erp.object_state os
                       where os.tenant_id = ta and os.object_type = 'document'
                         and os.object_id in (a_po_draft, a_po_pend, a_po_app, a_po_sent, a_po_part, a_po_recv)
                         and os.state_machine_version_id <> a_po_v1)
      and not exists (select 1 from erp.object_state os
                       where os.tenant_id = ta and os.object_type = 'document'
                         and os.object_id in (a_rq_draft, a_rq_sub, a_rq_app)
                         and os.state_machine_version_id <> a_req_v1);
    v_msg := format('received order %s, part-received order %s, approved order %s (%s), pending order %s; every one on v1: %s',
                    erp.object_current_state('document', a_po_recv), erp.object_current_state('document', a_po_part),
                    v_st, (select st.name from erp.object_state os join erp.state st on st.id = os.current_state_id
                            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_po_app),
                    v_st2,
                    not exists (select 1 from erp.object_state os
                                 where os.tenant_id = ta and os.object_type = 'document'
                                   and os.object_id in (a_po_draft, a_po_pend, a_po_app, a_po_sent, a_po_part, a_po_recv,
                                                        a_rq_draft, a_rq_sub, a_rq_app)
                                   and os.state_machine_version_id not in (a_po_v1, a_req_v1)));
    return query select v_names[4], coalesce(v_ok, false), v_msg; v_step := 4;

    -- ── 5 ────────────────────────────────────────────────────────────────
    res := erp.convert_document(a_rq_app, null, null, null, null);
    perform erp.transition_document(a_rq_sub, 'approve');
    res2 := erp.convert_document(a_rq_sub, null, null, null, null);
    v_ok := not (res ->> 'born_approved')::boolean and res ->> 'approval_not_carried' = 'no_approved_request'
      and erp.object_current_state('document', (res ->> 'document_id')::uuid) = 'draft'
      and not (res2 ->> 'born_approved')::boolean and res2 ->> 'approval_not_carried' = 'no_approved_request'
      and erp.object_current_state('document', (res2 ->> 'document_id')::uuid) = 'draft'
      and not exists (select 1 from erp.event ev where ev.tenant_id = ta and ev.event_type = 'document.approval_carried'
                         and ev.aggregate_id in ((res ->> 'document_id')::uuid, (res2 ->> 'document_id')::uuid));
    v_msg := format('approved on v1: born %s (%s), order %s; approved on v1 after the upgrade: born %s (%s), order %s',
                    res ->> 'born_approved', coalesce(res ->> 'approval_not_carried', 'carried'),
                    erp.object_current_state('document', (res ->> 'document_id')::uuid),
                    res2 ->> 'born_approved', coalesce(res2 ->> 'approval_not_carried', 'carried'),
                    erp.object_current_state('document', (res2 ->> 'document_id')::uuid));
    return query select v_names[5], coalesce(v_ok, false), v_msg; v_step := 5;

    -- ── 6 ────────────────────────────────────────────────────────────────
    a_rq_new := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(a_rq_new, v_item, 5, 1000, 'raised on v2');
    perform erp.transition_document(a_rq_new, 'submit');
    select c.code into v_st from erp.approval_request q join erp.approval_chain c on c.tenant_id = q.tenant_id and c.id = q.approval_chain_id
     where q.tenant_id = ta and q.object_type = 'document' and q.object_id = a_rq_new and q.status = 'pending';
    perform erp.approve_my_document_tasks(a_rq_new, 'the reseed suite');
    if erp.object_current_state('document', a_rq_new) = 'submitted' then
      perform erp.transition_document(a_rq_new, 'approve');
    end if;
    res := erp.convert_document(a_rq_new, null, null, null, null);
    a_po_born := (res ->> 'document_id')::uuid;
    v_ok := v_st = 'requisition_value'
      and (res ->> 'born_approved')::boolean
      and erp.object_current_state('document', a_po_born) = 'approved'
      and erp.object_current_state('document', a_rq_new) = 'ordered'
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_rq_new) = a_req_v2
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_po_born) = a_po_v2
      and not exists (select 1 from erp.approval_request q where q.tenant_id = ta and q.object_id = a_po_born);
    v_msg := format('asked for %s; order born %s (%s), order %s, requisition %s',
                    coalesce(v_st, 'nothing'), res ->> 'born_approved', coalesce(res ->> 'approval_not_carried', 'carried'),
                    erp.object_current_state('document', a_po_born), erp.object_current_state('document', a_rq_new));
    return query select v_names[6], coalesce(v_ok, false), v_msg; v_step := 6;

    -- ── 7 ────────────────────────────────────────────────────────────────
    select (select count(*) from erp.undriven_transition_report()),
           (select count(*) from erp.reachable_configuration_report()),
           (select count(*) from erp.dead_configuration_report())
      into v_n, v_n2, v_n3;
    v_ok := v_n = 0 and v_n2 = 0 and v_n3 = 0;
    select coalesce(string_agg(f.reference, ', '), '') into v_msg
      from (select u.reference from erp.undriven_transition_report() u
            union all select rc.reference from erp.reachable_configuration_report() rc
            union all select dc.reference from erp.dead_configuration_report() dc) f;
    return query select v_names[7], coalesce(v_ok, false),
      format('undriven %s, reachable %s, dead %s %s', v_n, v_n2, v_n3, v_msg); v_step := 7;

    -- ── 8 ────────────────────────────────────────────────────────────────
    -- A code the current payload ships and no organisation holds: the order
    -- machine the current version restates gains a synthetic move inside
    -- this block, which is rolled back.
    v_ok := null; v_msg := null;
    begin
      update erp_ref.module_upgrade_item ui
         set payload = jsonb_set(ui.payload, '{transitions}', (ui.payload -> 'transitions')
               || jsonb_build_array(jsonb_build_object('code', 'zz_reseed_shipped', 'name', 'Shipped', 'from', 'draft', 'to', 'approved')))
       where ui.install_code = 'procurement-lifecycle' and ui.to_version = v_cur
         and ui.object_kind = 'state_machine' and ui.object_key = 'purchase_order';
      get diagnostics i = row_count;
      if i <> 1 then
        raise exception 'version % restates no purchase order machine to ship a code in', v_cur;
      end if;
      v_reg := erp.transition_driver_register() || jsonb_build_array(
        jsonb_build_object('machine_code', 'purchase_order', 'transition_code', 'zz_reseed_shipped', 'driver', 'screen', 'detail', ''),
        jsonb_build_object('machine_code', 'purchase_order', 'transition_code', 'zz_reseed_unshipped', 'driver', 'screen', 'detail', ''));
      select count(*) filter (where u.reference = 'purchase_order.zz_reseed_shipped'),
             count(*) filter (where u.reference = 'purchase_order.zz_reseed_unshipped'
                                and u.finding = 'a registered transition the lifecycle does not declare')
        into v_n, v_n2
        from erp.undriven_transition_report(v_reg) u;
      v_n3 := (select count(*) from erp.transition t where t.code = 'zz_reseed_shipped');
      v_ok := v_n = 0 and v_n2 = 1 and v_n3 = 0;
      v_msg := format('shipped at version %s and held by nobody (%s held): %s finding(s); a code nothing ships: %s finding(s)',
                      v_cur, v_n3, v_n, v_n2);
      raise exception using message = v_undo;
    exception when others then
      if sqlerrm <> v_undo then v_ok := false; v_msg := 'the block refused: ' || left(sqlerrm, 200); end if;
    end;
    return query select v_names[8], coalesce(v_ok, false), v_msg; v_step := 8;

    -- ── 9 ────────────────────────────────────────────────────────────────
    v_ok := null; v_msg := null;
    begin
      insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
      values ('procurement-lifecycle', 1, 'state_machine', 'purchase_order',
              jsonb_build_object('code', 'purchase_order', 'object_type', 'document',
                'transitions', jsonb_build_array(jsonb_build_object('code', 'zz_reseed_older', 'from', 'draft', 'to', 'approved'))),
              999);
      -- Version 2's order machine, no longer the current payload once a later
      -- version restates it, gains a code of its own.
      update erp_ref.module_upgrade_item ui
         set payload = jsonb_set(ui.payload, '{transitions}', (ui.payload -> 'transitions')
               || jsonb_build_array(jsonb_build_object('code', 'zz_reseed_superseded', 'name', 'Superseded', 'from', 'draft', 'to', 'approved')))
       where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2 and ui.to_version < v_cur
         and ui.object_kind = 'state_machine' and ui.object_key = 'purchase_order';
      get diagnostics i = row_count;
      v_reg := erp.transition_driver_register() || jsonb_build_array(
        jsonb_build_object('machine_code', 'purchase_order', 'transition_code', 'zz_reseed_older', 'driver', 'screen', 'detail', ''),
        jsonb_build_object('machine_code', 'purchase_order', 'transition_code', 'zz_reseed_superseded', 'driver', 'screen', 'detail', ''),
        jsonb_build_object('machine_code', 'goods_receipt', 'transition_code', 'inherit_approval', 'driver', 'screen', 'detail', ''));
      select count(*) filter (where u.reference = 'purchase_order.zz_reseed_older'
                                and u.finding = 'a registered transition the lifecycle does not declare'),
             count(*) filter (where u.reference = 'goods_receipt.inherit_approval'
                                and u.finding = 'a registered transition the lifecycle does not declare'),
             count(*) filter (where u.reference = 'purchase_order.zz_reseed_superseded'
                                and u.finding = 'a registered transition the lifecycle does not declare')
        into v_n, v_n2, v_n3
        from erp.undriven_transition_report(v_reg) u;
      v_ok := v_n = 1 and v_n2 = 1 and i = 1 and v_n3 = 1;
      v_msg := format('a code only the version 1 payload declares: %s finding(s); only the superseded version 2 payload: %s finding(s); purchase_order''s code under goods_receipt: %s finding(s)',
                      v_n, case when i = 1 then v_n3::text else 'not placed' end, v_n2);
      raise exception using message = v_undo;
    exception when others then
      if sqlerrm <> v_undo then v_ok := false; v_msg := 'the block refused: ' || left(sqlerrm, 200); end if;
    end;
    return query select v_names[9], coalesce(v_ok, false), v_msg; v_step := 9;

    -- ── 10 ───────────────────────────────────────────────────────────────
    -- Organisation F: a fresh install at the current version, at the defaults.
    select coalesce(jsonb_object_agg(m.object_kind || '.' || m.object_key,
                      m.content - 'version' - 'effective_from' - 'effective_to'), '{}'::jsonb)
      into v_a
      from erp.configuration_manifest(array['state_machine', 'approval_chain', 'document_type', 'config']) m
     where (m.object_kind, m.object_key) in (('state_machine','requisition'), ('state_machine','purchase_order'),
                                             ('approval_chain','requisition_value'), ('document_type','requisition'),
                                             ('config','procurement.policy||-|-'));
    select * into r from erp.provision_tenant('zzrsf', 'Reseed Suite F', 'admin@zzrsf.test', 'Reseed Admin F');
    tf := r.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_f)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = tf and is_self;
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    perform erp.configure_procurement();
    select coalesce(jsonb_object_agg(m.object_kind || '.' || m.object_key,
                      m.content - 'version' - 'effective_from' - 'effective_to'), '{}'::jsonb)
      into v_f
      from erp.configuration_manifest(array['state_machine', 'approval_chain', 'document_type', 'config']) m
     where (m.object_kind, m.object_key) in (('state_machine','requisition'), ('state_machine','purchase_order'),
                                             ('approval_chain','requisition_value'), ('document_type','requisition'),
                                             ('config','procurement.policy||-|-'));
    -- Version 2's four objects, and the policy a later version added.
    v_ok := v_a = v_f and (select count(*) from jsonb_object_keys(v_a)) = 5
      and (select i.installer_version from erp.module_installation i
            where i.tenant_id = tf and i.install_code = 'procurement-lifecycle') = v_cur;
    select coalesce(string_agg(k, ', '), 'none') into v_msg
      from (select k from jsonb_object_keys(v_a || v_f) k
             where v_a -> k is distinct from v_f -> k) d;
    return query select v_names[10], coalesce(v_ok, false),
      format('%s object(s) compared; differing: %s; the fresh install reads v%s of v%s', (select count(*) from jsonb_object_keys(v_a)), v_msg,
             (select i.installer_version from erp.module_installation i
               where i.tenant_id = tf and i.install_code = 'procurement-lifecycle'), v_cur); v_step := 10;

    -- ── 11 ───────────────────────────────────────────────────────────────
    perform set_config('request.jwt.claims', json_build_object('sub', a_a)::text, true);
    v_doc := erp.rollback_to_snapshot(
      (select cs.rollback_snapshot_id from erp.change_set cs where cs.tenant_id = ta and cs.id = a_cs),
      'The reseed suite rehearses the reversal of the upgrade');
    v_doc2 := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(v_doc2, v_item, 1, 1000, 'raised after the rollback');
    v_st := erp.transition_document(a_po_born, 'send');
    select os.state_machine_version_id into v_line from erp.object_state os
     where os.tenant_id = ta and os.object_type = 'document' and os.object_id = v_doc2;
    v_ok := (select cs.status from erp.change_set cs where cs.tenant_id = ta and cs.id = v_doc) = 'rolled_back'
      and v_line not in (a_po_v1, a_po_v2)
      -- The new order runs exactly v1's moves.
      and (select array_agg(t.code order by t.code) from erp.transition t where t.state_machine_version_id = v_line)
          = (select array_agg(t.code order by t.code) from erp.transition t where t.state_machine_version_id = a_po_v1)
      and (select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = ta and dt.code = 'requisition') is null
      and v_st = 'sent'
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_po_born) = a_po_v2
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = ta and os.object_type = 'document' and os.object_id = a_rq_new) = a_req_v2;
    v_msg := format('new order on v%s (inherit_approval: %s), requisition chain %s; the born order issued on v2: %s; installation still reads v%s, plan %s item(s)',
                    (select v.version from erp.state_machine_version v where v.id = v_line),
                    exists (select 1 from erp.transition t where t.state_machine_version_id = v_line and t.code = 'inherit_approval'),
                    coalesce((select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = ta and dt.code = 'requisition'), 'none'),
                    v_st,
                    (select i.installer_version from erp.module_installation i where i.tenant_id = ta and i.install_code = 'procurement-lifecycle'),
                    (select count(*) from erp.plan_module_upgrade('procurement-lifecycle')));
    return query select v_names[11], coalesce(v_ok, false), v_msg; v_step := 11;

    -- ═════════════════════════════════════════════════════════════════════
    -- Organisation B: v1 with approver 'purchasing' and threshold 500000
    -- ═════════════════════════════════════════════════════════════════════
    select * into r from erp.provision_tenant('zzrsb', 'Reseed Suite B', 'admin@zzrsb.test', 'Reseed Admin B');
    tb := r.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_b)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = tb and is_self;
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    select e.code into v_ent_code from erp.entity e where e.tenant_id = tb and e.id = r.entity_id;
    perform erp.install_module_config('procurement-lifecycle', 'Procurement lifecycle',
      'Version 1, customised', erp_test.procurement_lifecycle_v1_items(v_ent_code, 500000, 'purchasing'));
    update erp.module_installation set installer_version = 1
     where tenant_id = tb and install_code = 'procurement-lifecycle';

    -- ── 12 ───────────────────────────────────────────────────────────────
    res := erp.upgrade_module_configuration('procurement-lifecycle');
    select m.content into v_a from erp.configuration_manifest(array['approval_chain']) m where m.object_key = 'purchase_order_value';
    select m.content into v_f from erp.configuration_manifest(array['approval_chain']) m where m.object_key = 'requisition_value';
    v_ok := (res ->> 'promoted')::boolean
      and (select bool_and(s ->> 'role' = 'purchasing') from jsonb_array_elements(v_a -> 'steps') s)
      and (select s -> 'condition' from jsonb_array_elements(v_a -> 'steps') s where s ->> 'code' = 'finance')
          = jsonb_build_object('>', jsonb_build_array(jsonb_build_object('var', 'total_minor'), 500000))
      and (select bool_and(s ->> 'role' = 'administrator') from jsonb_array_elements(v_f -> 'steps') s)
      and (select s -> 'condition' from jsonb_array_elements(v_f -> 'steps') s where s ->> 'code' = 'finance')
          = jsonb_build_object('>', jsonb_build_array(jsonb_build_object('var', 'total_minor'), 1000000))
      and (select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = tb and dt.code = 'purchase_order') = 'purchase_order_value'
      and (select dt.approval_chain_code from erp.document_type dt where dt.tenant_id = tb and dt.code = 'requisition') = 'requisition_value';
    v_msg := format('order chain roles %s over %s; requisition chain roles %s over %s',
                    (select string_agg(distinct s ->> 'role', ',') from jsonb_array_elements(v_a -> 'steps') s),
                    (select s -> 'condition' -> '>' -> 1 from jsonb_array_elements(v_a -> 'steps') s where s ->> 'code' = 'finance'),
                    (select string_agg(distinct s ->> 'role', ',') from jsonb_array_elements(v_f -> 'steps') s),
                    (select s -> 'condition' -> '>' -> 1 from jsonb_array_elements(v_f -> 'steps') s where s ->> 'code' = 'finance'));
    return query select v_names[12], coalesce(v_ok, false), v_msg; v_step := 12;

    -- ═════════════════════════════════════════════════════════════════════
    -- Organisation D: a demonstration, not live, on v1
    -- ═════════════════════════════════════════════════════════════════════
    select * into r from erp.provision_tenant('demo-zzreseed', 'Reseed Suite Demonstration', 'admin@demo-zzreseed.test', 'Reseed Admin D');
    td := r.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_d)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = td and is_self;
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    select e.code into v_ent_code from erp.entity e where e.tenant_id = td and e.id = r.entity_id;
    perform erp.install_module_config('procurement-lifecycle', 'Procurement lifecycle',
      'Version 1, as a demonstration installed it', erp_test.procurement_lifecycle_v1_items(v_ent_code));
    update erp.module_installation set installer_version = 1
     where tenant_id = td and install_code = 'procurement-lifecycle';
    perform erp.ensure_demo_configuration(td, r.admin_user_id);

    -- ── 14, run first, while D is on v1 ──────────────────────────────────
    -- A faulty item joins the current version inside this block, which is
    -- rolled back.
    begin
      insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
      values ('procurement-lifecycle', v_cur, 'document_type', 'zz_reseed_faulty',
              jsonb_build_object('code', 'zz_reseed_faulty', 'base_type', 'zz_no_such_base', 'name', 'Faulty',
                                 'state_machine', 'zz_no_such_machine', 'numbering_rule', 'zz_no_such_rule'),
              140);
      res := erp.demonstration_catch_up();
      v_ok14 := exists (select 1 from jsonb_array_elements_text(res -> 'notes') n
                         where n like 'The procurement lifecycle was not upgraded, so it trades on the version it has: %')
        and not exists (select 1 from jsonb_array_elements_text(res -> 'notes') n
                         where n like 'The procurement lifecycle was upgraded%')
        and res ? 'periods_closed'
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = td and i.install_code = 'procurement-lifecycle') = 1
        and not exists (select 1 from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
                         where m.tenant_id = td and m.code in ('requisition', 'purchase_order') and v.version > 1)
        and not exists (select 1 from erp.change_set cs where cs.tenant_id = td and cs.code like 'procurement-lifecycle-upgrade-%');
      v_msg14 := format('notes %s; installation v%s', res -> 'notes',
                        (select i.installer_version from erp.module_installation i
                          where i.tenant_id = td and i.install_code = 'procurement-lifecycle'));
      raise exception using message = v_undo;
    exception when others then
      if sqlerrm <> v_undo then v_ok14 := false; v_msg14 := 'the block refused: ' || left(sqlerrm, 200); end if;
    end;
    v_ok14 := v_ok14 and (select count(*) from erp_ref.module_upgrade_item ui
                           where ui.install_code = 'procurement-lifecycle' and ui.to_version > 1) = v_after_v1
      and not exists (select 1 from erp_ref.module_upgrade_item ui where ui.object_key = 'zz_reseed_faulty');

    -- ── 13 ───────────────────────────────────────────────────────────────
    res := erp.demonstration_catch_up();
    res2 := erp.demonstration_catch_up();
    v_ok := exists (select 1 from jsonb_array_elements_text(res -> 'notes') n
                     where n = format('The procurement lifecycle was upgraded to version %s.', v_cur))
      and not exists (select 1 from jsonb_array_elements_text(res2 -> 'notes') n where n like 'The procurement lifecycle%')
      and (select count(*) from erp.plan_module_upgrade('procurement-lifecycle')) = 0
      and (select i.installer_version from erp.module_installation i
            where i.tenant_id = td and i.install_code = 'procurement-lifecycle') = v_cur
      and (select count(*) from erp.change_set cs where cs.tenant_id = td and cs.code like 'procurement-lifecycle-upgrade-%') = 1
      and (select count(*) from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
            where m.tenant_id = td and m.code in ('requisition', 'purchase_order') and v.version = 2 and v.status = 'active') = 2;
    v_msg := format('first run %s; second run %s; installation v%s of v%s', res -> 'notes', res2 -> 'notes',
                    (select i.installer_version from erp.module_installation i
                      where i.tenant_id = td and i.install_code = 'procurement-lifecycle'), v_cur);
    return query select v_names[13], coalesce(v_ok, false), v_msg; v_step := 13;
    return query select v_names[14], coalesce(v_ok14, false), v_msg14; v_step := 14;

    -- ═════════════════════════════════════════════════════════════════════
    -- Organisation C: live, two administrators, v1 backdated
    -- ═════════════════════════════════════════════════════════════════════
    select * into r from erp.provision_tenant('zzrsc', 'Reseed Suite C', 'admin@zzrsc.test', 'Reseed Admin C');
    tc := r.tenant_id; v_ent := r.entity_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment set is_live = false where tenant_id = tc and is_self;
    select i.app_user_id, i.token into u_c2, v_tok from erp.invite_principal('second@zzrsc.test', 'Second Admin C') i;
    perform erp.grant_role(u_c2, 'administrator', null, null, 'the reseed suite: a second administrator', null, null, null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_c2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);
    perform erp.configure_finance(extract(year from current_date)::integer, null);
    select e.code into v_ent_code from erp.entity e where e.tenant_id = tc and e.id = v_ent;
    perform erp.install_module_config('procurement-lifecycle', 'Procurement lifecycle',
      'Version 1, as a customer installed it', erp_test.procurement_lifecycle_v1_items(v_ent_code));
    update erp.module_installation
       set installer_version = 1, installed_at = now() - interval '30 days'
     where tenant_id = tc and install_code = 'procurement-lifecycle';
    res := erp.ensure_demo_configuration(tc, r.admin_user_id);
    v_site := (res ->> 'site_id')::uuid;
    update erp.state_machine_version v set effective_from = current_date - 30
      from erp.state_machine m
     where m.tenant_id = tc and m.id = v.state_machine_id and v.tenant_id = tc
       and m.code in ('purchase_order', 'requisition');
    select v.id into c_req_v1 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = tc and m.code = 'requisition' and v.version = 1;
    select v.id into c_po_v1 from erp.state_machine_version v join erp.state_machine m on m.id = v.state_machine_id
     where m.tenant_id = tc and m.code = 'purchase_order' and v.version = 1;
    select it.id into v_item from erp.item it where it.tenant_id = tc and it.status = 'active' order by it.code limit 1;
    select p.id into v_sup from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'supplier'
     where p.tenant_id = tc and p.status = 'active' order by p.code limit 1;
    -- In flight on v1, seeded before it went live.
    c_rq_sub := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(c_rq_sub, v_item, 3, 1000, 'v1 submitted');
    perform erp.transition_document(c_rq_sub, 'submit');
    c_po_app := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    perform erp.add_document_line(c_po_app, v_item, 10, 1000, 'v1 order approved');
    perform erp.transition_document(c_po_app, 'submit');
    perform erp_test.approve_document(c_po_app, 'the reseed suite');
    c_po_recv := erp.open_document('purchase_order', v_sup, v_ent, v_site);
    c_pl_recv := erp.add_document_line(c_po_recv, v_item, 10, 1000, 'v1 order received');
    perform erp.transition_document(c_po_recv, 'submit');
    perform erp_test.approve_document(c_po_recv, 'the reseed suite');
    perform erp.transition_document(c_po_recv, 'send');
    v_g := erp.open_document('goods_receipt', v_sup, v_ent, v_site);
    perform erp.receive_against(v_g, c_pl_recv, 10, null);
    perform erp.transition_document(v_g, 'post');
    update erp.environment set is_live = true where tenant_id = tc and is_self;
    -- A change needs a second person here, as a customer's would.
    perform erp_test.administrator_approval_off(tc);

    -- ── 15 ───────────────────────────────────────────────────────────────
    res := erp.upgrade_module_configuration('procurement-lifecycle');
    c_cs := (res ->> 'change_set_id')::uuid;
    begin
      perform erp.approve_change_set(c_cs);
      v_err := 'its author approved it';
    exception when others then
      v_err := sqlerrm;
    end;
    v_ok := erp.tenant_is_live(tc)
      and not (res ->> 'promoted')::boolean and (res ->> 'items')::integer = v_after_v1
      and (res ->> 'to_version')::integer = v_cur
      and (select cs.status::text from erp.change_set cs where cs.tenant_id = tc and cs.id = c_cs) = 'ready'
      and (select i.installer_version = 1 and i.pending_change_set_id = c_cs
             from erp.module_installation i where i.tenant_id = tc and i.install_code = 'procurement-lifecycle')
      and not exists (select 1 from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
                       where m.tenant_id = tc and m.code in ('requisition', 'purchase_order') and v.version > 1)
      and v_err like 'CLOVEERP_CHANGE_SET_SELF_APPROVAL:%';
    v_msg := format('%s; change set %s; its author: %s', res - 'change_set_id',
                    (select cs.status::text from erp.change_set cs where cs.tenant_id = tc and cs.id = c_cs), left(v_err, 90));
    return query select v_names[15], coalesce(v_ok, false), v_msg; v_step := 15;

    -- ── 16 ───────────────────────────────────────────────────────────────
    perform set_config('request.jwt.claims', json_build_object('sub', a_c2)::text, true);
    perform erp.approve_change_set(c_cs);
    perform erp.promote_change_set(c_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);
    select * into x from erp.module_installations() mi where mi.install_code = 'procurement-lifecycle';
    v_ok := (select cs.status::text from erp.change_set cs where cs.tenant_id = tc and cs.id = c_cs) = 'promoted'
      and (select i.installer_version = v_cur and i.pending_change_set_id is null and i.change_set_id = c_cs
             from erp.module_installation i where i.tenant_id = tc and i.install_code = 'procurement-lifecycle')
      and x.installer_version = v_cur and x.current_version = v_cur and not x.upgrade_available
      and (select count(*) from erp.state_machine m join erp.state_machine_version v on v.state_machine_id = m.id
            where m.tenant_id = tc and m.code in ('requisition', 'purchase_order') and v.version = 2
              and v.status = 'active' and v.effective_from = current_date) = 2
      and (select count(*) from erp.plan_module_upgrade('procurement-lifecycle')) = 0;
    v_msg := format('installation v%s of v%s, upgrade available %s, pending %s',
                    x.installer_version, x.current_version, x.upgrade_available, coalesce(x.pending_change_set_id::text, 'none'));
    return query select v_names[16], coalesce(v_ok, false), v_msg; v_step := 16;

    -- ── 17 ───────────────────────────────────────────────────────────────
    v_st := erp.transition_document(c_po_app, 'send');
    v_st2 := erp.transition_document(c_rq_sub, 'approve');
    v_bill := erp.open_document('purchase_invoice', v_sup, v_ent, v_site);
    perform erp.invoice_against(v_bill, c_pl_recv, 10, 1000);
    update erp.document set their_reference = 'ZZRS-C-1', due_date = current_date + 30
     where tenant_id = tc and id = v_bill;
    perform erp.transition_document(v_bill, 'register');
    v_ok := v_st = 'sent' and v_st2 = 'approved'
      and erp.object_current_state('document', c_po_recv) = 'closed'
      and not exists (select 1 from erp.approval_request q where q.tenant_id = tc and q.object_id = c_rq_sub)
      and not exists (select 1 from erp.object_state os
                       where os.tenant_id = tc and os.object_type = 'document'
                         and os.object_id in (c_po_app, c_po_recv) and os.state_machine_version_id <> c_po_v1)
      and (select os.state_machine_version_id from erp.object_state os
            where os.tenant_id = tc and os.object_type = 'document' and os.object_id = c_rq_sub) = c_req_v1;
    v_msg := format('approved order %s, submitted requisition %s on its permission, received order %s on its bill; all on v1: %s',
                    v_st, v_st2, erp.object_current_state('document', c_po_recv),
                    not exists (select 1 from erp.object_state os
                                 where os.tenant_id = tc and os.object_type = 'document'
                                   and os.object_id in (c_po_app, c_po_recv, c_rq_sub)
                                   and os.state_machine_version_id not in (c_po_v1, c_req_v1)));
    return query select v_names[17], coalesce(v_ok, false), v_msg; v_step := 17;

    -- ── 18 ───────────────────────────────────────────────────────────────
    -- D2 is about the administrator override, which is on by default: back on.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', tc::text, true);
    perform erp_test.reopen_bootstrap_window(tc);
    perform erp.set_config_value('approval.administrator_override', '{"allowed": true}'::jsonb,
                                 null, null, null, null, 'the reseed suite: D2 is decided with the override on');
    perform erp_test.close_bootstrap_window(tc);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);

    -- a. Raised, and approved, by the same administrator.
    v_doc := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(v_doc, v_item, 2, 1000, 'own approval');
    perform erp.transition_document(v_doc, 'submit');
    v_st := erp.transition_document(v_doc, 'approve');
    res := erp.convert_document(v_doc, null, null, null, null);
    v_n := (select count(*) from erp.event ev
              join erp.approval_request q on q.tenant_id = ev.tenant_id and q.id = ev.aggregate_id
             where ev.tenant_id = tc and q.object_id = v_doc
               and ev.event_type = 'approval.administrator_decided'
               and coalesce((ev.payload ->> 'own_request')::boolean, false));
    -- b. Raised by one administrator, decided by the other.
    v_doc2 := erp.open_document('requisition', v_sup, v_ent, v_site);
    perform erp.add_document_line(v_doc2, v_item, 2, 1000, 'decided by another');
    perform erp.transition_document(v_doc2, 'submit');
    perform set_config('request.jwt.claims', json_build_object('sub', a_c2)::text, true);
    for x in select tk.id from erp.approval_task tk
               join erp.approval_request q on q.tenant_id = tk.tenant_id and q.id = tk.approval_request_id
              where tk.tenant_id = tc and q.object_id = v_doc2 and q.status = 'pending' and tk.status = 'pending'
              order by tk.seq
    loop
      perform erp.decide_approval_task(x.id, true, 'the reseed suite');
    end loop;
    v_st2 := erp.transition_document(v_doc2, 'approve');
    perform set_config('request.jwt.claims', json_build_object('sub', a_c)::text, true);
    res2 := erp.convert_document(v_doc2, null, null, null, null);
    v_ok := v_st = 'approved' and v_n >= 1
      and not (res ->> 'born_approved')::boolean
      and res ->> 'approval_not_carried' = 'approved_by_its_requester'
      and erp.object_current_state('document', (res ->> 'document_id')::uuid) = 'draft'
      and v_st2 = 'approved'
      and (res2 ->> 'born_approved')::boolean
      and erp.object_current_state('document', (res2 ->> 'document_id')::uuid) = 'approved';
    v_msg := format('own approval (%s override decision(s)): born %s (%s), order %s; decided by the other: born %s, order %s',
                    v_n, res ->> 'born_approved', coalesce(res ->> 'approval_not_carried', 'carried'),
                    erp.object_current_state('document', (res ->> 'document_id')::uuid),
                    res2 ->> 'born_approved', erp.object_current_state('document', (res2 ->> 'document_id')::uuid));
    return query select v_names[18], coalesce(v_ok, false), v_msg; v_step := 18;

    -- ═════════════════════════════════════════════════════════════════════
    -- Each organisation purged. Journals are checked by deferred triggers,
    -- fired here against data that still exists.
    -- ═════════════════════════════════════════════════════════════════════
    set constraints all immediate;
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    foreach v_doc in array array[ta, tf, tb, td, tc] loop
      if v_doc is not null then
        perform erp.begin_tenant_purge(v_doc);
        delete from erp.tenant where id = v_doc;
        perform erp.end_tenant_purge();
      end if;
    end loop;
  exception when others then
    -- Everything the suite did is rolled back with the block; each case it
    -- did not reach is reported, the first with the refusal.
    v_err := left(sqlerrm, 300);
    if v_step = 18 then v_purge_err := v_err; end if;
    for i in v_step + 1 .. 18 loop
      return query select v_names[i], false,
        case when i = v_step + 1 then 'the suite stopped here: ' || v_err else 'not reached' end;
    end loop;
  end;

  -- ── 19 ─────────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  select count(*) into v_n from erp.tenant tn where tn.code = any (v_codes);
  -- Version 2's four objects, as organisations promoted them.
  select count(*) into v_n2 from erp_ref.module_upgrade_item ui
   where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2
     and (ui.object_kind, ui.object_key) in (('state_machine','requisition'), ('state_machine','purchase_order'),
                                             ('approval_chain','requisition_value'), ('document_type','requisition'));
  -- The current version's rows, each what a fresh install writes.
  select count(*) into v_n3 from erp_ref.module_upgrade_item ui
    join jsonb_array_elements(erp.procurement_lifecycle_items(null, 1000000, 'administrator')) it
      on it.value ->> 'kind' = ui.object_kind and it.value ->> 'key' = ui.object_key
     and (it.value -> 'payload') - 'entity' = ui.payload
   where ui.install_code = 'procurement-lifecycle' and ui.to_version = v_cur;
  select string_agg(format('version %s: %s', g.to_version, g.n), ', ' order by g.to_version) into v_msg
    from (select ui.to_version, count(*) n from erp_ref.module_upgrade_item ui
           where ui.install_code = 'procurement-lifecycle' group by ui.to_version) g;
  return query select v_names[19],
    v_purge_err is null and v_n = 0 and v_n2 = 4
    and (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'procurement-lifecycle' and ui.to_version = 2) = 4
    and v_n3 > 0
    and v_n3 = (select count(*) from erp_ref.module_upgrade_item ui
                 where ui.install_code = 'procurement-lifecycle' and ui.to_version = v_cur)
    and (select coalesce(jsonb_agg(to_jsonb(ui) order by ui.to_version, ui.object_kind, ui.object_key), '[]'::jsonb)
           from erp_ref.module_upgrade_item ui where ui.install_code = 'procurement-lifecycle') = v_items_snap
    and (select count(*) from erp_ref.module_upgrade_item) = v_items_before
    and coalesce(current_setting('erp.carrying_approval', true), '') = ''
    and coalesce(current_setting('erp.deriving_move', true), '') = '',
    coalesce('the purge refused, and the rollback took everything: ' || v_purge_err || '; ', '') ||
    format('%s organisation(s) left; version 2 holds %s of its four objects; %s of version %s''s row(s) are what a fresh install writes; the lifecycle''s rows (%s) %s as they were; %s upgrade row(s), %s before',
           v_n, v_n2, v_n3, v_cur, coalesce(v_msg, 'none'),
           case when (select coalesce(jsonb_agg(to_jsonb(ui) order by ui.to_version, ui.object_kind, ui.object_key), '[]'::jsonb)
                        from erp_ref.module_upgrade_item ui where ui.install_code = 'procurement-lifecycle') = v_items_snap
                then 'are' else 'are not' end,
           (select count(*) from erp_ref.module_upgrade_item), v_items_before);
end;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- C7. The procurement policy, proved where it acts
--
-- Each parameter of procurement.policy is read where it acts, and the
-- over-receipt tolerance is measured on the line. A non-live organisation
-- with the demonstration's configuration (so version 3 of the procurement
-- lifecycle and the controls are new installs), undone at the end.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.procurement_policy_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_layer  jsonb;
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth   uuid := gen_random_uuid();
  v_demo   jsonb;
  v_entity uuid; v_site uuid; v_uom uuid; v_sup uuid; v_item uuid;
  v_p0 jsonb; v_p1 jsonb; v_p2 jsonb;
  v_ver integer; v_tol_action text; v_tol_pct numeric; v_tol_n integer;
  v_r uuid; v_rl uuid; res jsonb;
  v_po uuid; v_pl uuid; v_po2 uuid; v_pl2 uuid;
  v_g uuid; v_g2 uuid; v_bill uuid; v_carry jsonb;
  v_ok boolean; v_ok2 boolean; v_msg text; v_msg2 text; v_st text; v_st2 text;
  v_n integer; v_n2 integer; v_ev jsonb; v_x text; v_x2 text;
  v_i integer; v_x3 text; v_plan integer;
begin
  begin
    select p.tenant_id, p.admin_user_id, p.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzppol', 'Procurement Policy Suite', 'admin@zzppol.test', 'Policy Admin') p;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzppol.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);

    -- 1. Before anything is installed nothing is set, and the policy reads the
    --    product's defaults. A value that names one key leaves the others at
    --    theirs. Written at tenant scope before the install, so the install is
    --    what case 2 reads afterwards.
    v_p0 := erp.procurement_policy(null, null);
    perform erp.set_config_value('procurement.policy', jsonb_build_object('reapproval_qty_pct', 7),
                                 null, null, null, null, 'the procurement policy suite');
    v_p1 := erp.procurement_policy(null, null);
    return query select 'with nothing set the policy reads its defaults, and a key left out reads its default',
      v_p0 = jsonb_build_object('reapproval_qty_pct', 0, 'short_close_pct', 0, 'invoice_match_mode', 'three_way')
      and (v_p1 ->> 'reapproval_qty_pct')::numeric = 7
      and (v_p1 ->> 'short_close_pct')::numeric = 0
      and v_p1 ->> 'invoice_match_mode' = 'three_way',
      format('nothing set: %s; one key set: %s', v_p0, v_p1);

    -- 2. A new install: version 3 of the procurement lifecycle writes the
    --    policy at tenant scope, over what case 1 left there.
    v_demo := erp.ensure_demo_configuration(v_tenant, v_admin);
    v_entity := (v_demo ->> 'entity_id')::uuid;
    v_site := (v_demo ->> 'site_id')::uuid;
    select mi.installer_version into v_ver from erp.module_installation mi
     where mi.tenant_id = v_tenant and mi.install_code = 'procurement-lifecycle';
    v_p2 := erp.config_value('procurement.policy', null, null, null, null);
    -- The controls as a new install left them, read before any case moves them.
    select count(*), max(rt.over_action), max(rt.over_pct) into v_tol_n, v_tol_action, v_tol_pct
      from erp.receipt_tolerance rt
     where rt.tenant_id = v_tenant and rt.code = 'default' and rt.status = 'active'
       and rt.item_class is null and rt.party_id is null;
    -- An entity's own value layers over the organisation's key by key: set
    -- only reapproval_qty_pct there, and short_close_pct still reads 2.
    perform erp.set_config_value('procurement.policy', jsonb_build_object('reapproval_qty_pct', 5),
      null, null, v_entity, null, 'the procurement policy suite');
    v_layer := erp.procurement_policy(v_entity, v_site);
    update erp.config_object co set status = 'inactive', updated_at = now()
     where co.tenant_id = v_tenant and co.config_type_code = 'procurement.policy'
       and co.entity_id = v_entity and co.site_id is null;
    return query select 'a new install at version 3 holds short_close_pct 2 at tenant scope, and an entity''s value layers over it',
      (v_layer ->> 'reapproval_qty_pct')::numeric = 5 and (v_layer ->> 'short_close_pct')::numeric = 2 and
      v_ver = 3
      and (v_p2 ->> 'short_close_pct')::numeric = 2
      and (v_p2 ->> 'reapproval_qty_pct')::numeric = 0
      and v_p2 ->> 'invoice_match_mode' = 'three_way'
      and exists (select 1 from erp.config_object co
                   where co.tenant_id = v_tenant and co.config_type_code = 'procurement.policy'
                     and co.entity_id is null and co.site_id is null and co.status = 'active')
      and (erp.procurement_policy(v_entity, v_site) ->> 'short_close_pct')::numeric = 2,
      format('installer version %s; tenant value %s; with the entity''s %s', coalesce(v_ver::text, 'none'),
             coalesce(v_p2::text, 'none'), coalesce(v_layer::text, 'none'));

    select u.id into v_uom from erp.uom u
     where u.tenant_id = v_tenant and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZPSUP', 'Policy Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZPWID', 'Policy Suite Widget', v_uom, 'active') returning id into v_item;

    -- 3. short_close_pct. Ninety-nine of a hundred posted: at 0 the order is
    --    part received; at the install's 2 it is received, moved by the
    --    receipt and nobody else. The bill for the ninety-nine closes it.
    perform erp.set_config_value('procurement.policy',
      jsonb_build_object('reapproval_qty_pct', 0, 'short_close_pct', 0, 'invoice_match_mode', 'three_way'),
      null, null, null, null, 'the procurement policy suite');
    v_po2 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl2 := erp.add_document_line(v_po2, v_item, 100, 1000, 'a hundred');
    perform erp.transition_document(v_po2, 'submit', null);
    if erp.object_current_state('document', v_po2) = 'pending_approval' then
      perform erp_test.approve_document(v_po2, null);
    end if;
    perform erp.transition_document(v_po2, 'send', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl2, 99, null);
    perform erp.transition_document(v_g, 'post', null);
    v_st2 := erp.object_current_state('document', v_po2);

    perform erp.set_config_value('procurement.policy',
      jsonb_build_object('reapproval_qty_pct', 0, 'short_close_pct', 2, 'invoice_match_mode', 'three_way'),
      null, null, null, null, 'the procurement policy suite');
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred');
    perform erp.transition_document(v_po, 'submit', null);
    if erp.object_current_state('document', v_po) = 'pending_approval' then
      perform erp_test.approve_document(v_po, null);
    end if;
    perform erp.transition_document(v_po, 'send', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 99, null);
    perform erp.transition_document(v_g, 'post', null);
    v_st := erp.object_current_state('document', v_po);
    v_ok := exists (select 1 from erp.state_transition_log l
                     where l.tenant_id = v_tenant and l.object_type = 'document' and l.object_id = v_po
                       and l.transition_code = 'receive_all' and l.reason = 'Goods received');
    v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_pl, 99, 1000);
    update erp.document set their_reference = 'ZPPOL-3', due_date = current_date + 30
     where tenant_id = v_tenant and id = v_bill;
    v_x := erp.transition_document(v_bill, 'register', null);
    return query select 'short_close_pct 2 reads 99 of 100 received with nobody pressing anything, 0 reads it part received, and the bill for the 99 closes it',
      v_st2 = 'partially_received' and v_st = 'received' and v_ok
      and v_x = 'registered' and erp.object_current_state('document', v_po) = 'closed',
      format('at 0: %s; at 2: %s (moved by the receipt: %s); bill %s, order %s',
             v_st2, v_st, v_ok, v_x, erp.object_current_state('document', v_po));

    -- 4. reapproval_qty_pct at 0: a born-approved order may fall and issue,
    --    and may not rise.
    v_msg := ''; v_ok := true;
    for v_i in 1..2 loop
      v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
      perform erp.add_document_line(v_r, v_item, 10, 1000, 'ten');
      perform erp.transition_document(v_r, 'submit', null);
      perform erp.approve_my_document_tasks(v_r, 'the procurement policy suite');
      if erp.object_current_state('document', v_r) = 'submitted' then
        perform erp.transition_document(v_r, 'approve', null);
      end if;
      res := erp.convert_document(v_r, null, null, null);
      v_po := (res ->> 'document_id')::uuid;
      select dl.id into v_pl from erp.document_line dl where dl.tenant_id = v_tenant and dl.document_id = v_po;
      if erp.object_current_state('document', v_po) is distinct from 'approved' then
        v_ok := false; v_msg := v_msg || format('order %s was not born approved (%s); ', v_i, res ->> 'approval_not_carried');
        continue;
      end if;
      if v_i = 1 then
        perform erp.amend_document_line(v_pl, 8, 'fewer');
        begin
          v_x := erp.transition_document(v_po, 'send', null);
        exception when others then v_x := 'refused: ' || left(sqlerrm, 120); end;
      else
        perform erp.amend_document_line(v_pl, 11, 'more');
        begin
          perform erp.transition_document(v_po, 'send', null);
          v_x2 := 'issued';
        exception when others then v_x2 := left(sqlerrm, 200); end;
        v_ok2 := erp.object_current_state('document', v_po) = 'approved';
      end if;
    end loop;
    return query select 'reapproval_qty_pct 0: a born-approved order lowered issues, raised is refused and says why',
      v_ok and v_x = 'sent' and v_ok2
      and v_x2 like 'CLOVEERP_CARRIED_ORDER_CHANGED:%a line rose by more than 0 per cent%',
      format('%slowered: %s; raised: %s', v_msg, v_x, v_x2);

    -- 5. reapproval_qty_pct at 10: up five per cent issues, up fifteen does not.
    perform erp.set_config_value('procurement.policy',
      jsonb_build_object('reapproval_qty_pct', 10, 'short_close_pct', 2, 'invoice_match_mode', 'three_way'),
      null, null, null, null, 'the procurement policy suite');
    v_msg := ''; v_ok := true; v_x := null; v_x2 := null; v_ok2 := false;
    for v_i in 1..2 loop
      v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
      perform erp.add_document_line(v_r, v_item, 20, 1000, 'twenty');
      perform erp.transition_document(v_r, 'submit', null);
      perform erp.approve_my_document_tasks(v_r, 'the procurement policy suite');
      if erp.object_current_state('document', v_r) = 'submitted' then
        perform erp.transition_document(v_r, 'approve', null);
      end if;
      res := erp.convert_document(v_r, null, null, null);
      v_po := (res ->> 'document_id')::uuid;
      select dl.id into v_pl from erp.document_line dl where dl.tenant_id = v_tenant and dl.document_id = v_po;
      if erp.object_current_state('document', v_po) is distinct from 'approved' then
        v_ok := false; v_msg := v_msg || format('order %s was not born approved (%s); ', v_i, res ->> 'approval_not_carried');
        continue;
      end if;
      perform erp.amend_document_line(v_pl, case v_i when 1 then 21 else 23 end, 'more');
      begin
        if v_i = 1 then
          v_x := erp.transition_document(v_po, 'send', null);
        else
          perform erp.transition_document(v_po, 'send', null);
          v_x2 := 'issued';
        end if;
      exception when others then
        if v_i = 1 then v_x := 'refused: ' || left(sqlerrm, 120); else v_x2 := left(sqlerrm, 200); end if;
      end;
      if v_i = 2 then v_ok2 := erp.object_current_state('document', v_po) = 'approved'; end if;
    end loop;
    return query select 'reapproval_qty_pct 10: a line raised 5 per cent issues, raised 15 per cent is refused',
      v_ok and v_x = 'sent' and v_ok2
      and v_x2 like 'CLOVEERP_CARRIED_ORDER_CHANGED:%a line rose by more than 10 per cent%',
      format('%s+5%%: %s; +15%%: %s', v_msg, v_x, v_x2);

    -- 6. A line added, or a price changed, is refused however far a line may
    --    rise: at the most the policy allows, 100.
    perform erp.set_config_value('procurement.policy',
      jsonb_build_object('reapproval_qty_pct', 100, 'short_close_pct', 2, 'invoice_match_mode', 'three_way'),
      null, null, null, null, 'the procurement policy suite');
    v_msg := ''; v_ok := true; v_x := null; v_x2 := null; v_x3 := null;
    for v_i in 1..3 loop
      v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
      perform erp.add_document_line(v_r, v_item, 10, 1000, 'ten');
      perform erp.transition_document(v_r, 'submit', null);
      perform erp.approve_my_document_tasks(v_r, 'the procurement policy suite');
      if erp.object_current_state('document', v_r) = 'submitted' then
        perform erp.transition_document(v_r, 'approve', null);
      end if;
      res := erp.convert_document(v_r, null, null, null);
      v_po := (res ->> 'document_id')::uuid;
      select dl.id into v_pl from erp.document_line dl where dl.tenant_id = v_tenant and dl.document_id = v_po;
      if erp.object_current_state('document', v_po) is distinct from 'approved' then
        v_ok := false; v_msg := v_msg || format('order %s was not born approved (%s); ', v_i, res ->> 'approval_not_carried');
        continue;
      end if;
      begin
        if v_i = 1 then
          perform erp.add_document_line(v_po, v_item, 1, 1000, 'one more line');
        elsif v_i = 2 then
          -- No door reprices an order line; a direct write, as a buyer's
          -- edit of the price would leave it.
          update erp.document_line set unit_price_minor = 1100, net_minor = 11000
           where tenant_id = v_tenant and id = v_pl;
        else
          -- Found on review: the line's value written up with its price and
          -- quantity left alone.
          update erp.document_line set net_minor = 1000000
           where tenant_id = v_tenant and id = v_pl;
        end if;
        perform erp.transition_document(v_po, 'send', null);
        v_msg2 := 'issued';
      exception when others then v_msg2 := left(sqlerrm, 200); end;
      if v_i = 1 then v_x := v_msg2; elsif v_i = 2 then v_x2 := v_msg2; else v_x3 := v_msg2; end if;
      v_ok := v_ok and erp.object_current_state('document', v_po) = 'approved';
    end loop;
    return query select 'a line added, a line''s price changed, or its value written up, on a born-approved order is refused at any reapproval_qty_pct',
      v_ok
      and v_x like 'CLOVEERP_CARRIED_ORDER_CHANGED:%a line was added%'
      and v_x2 like 'CLOVEERP_CARRIED_ORDER_CHANGED:%a line was changed%'
      and v_x3 like 'CLOVEERP_CARRIED_ORDER_CHANGED:%',
      format('%sat 100%%: added: %s; repriced: %s; value written up: %s', v_msg, v_x, v_x2, v_x3);

    -- 7. An order carried before this migration recorded no lines: held to
    --    its fingerprint exactly, so even a lowered line is refused, at 100.
    --    The event log is append-only, so the old payload is appended after
    --    the new one: the guard reads the latest.
    v_r := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_r, v_item, 10, 1000, 'ten');
    perform erp.transition_document(v_r, 'submit', null);
    perform erp.approve_my_document_tasks(v_r, 'the procurement policy suite');
    if erp.object_current_state('document', v_r) = 'submitted' then
      perform erp.transition_document(v_r, 'approve', null);
    end if;
    res := erp.convert_document(v_r, null, null, null);
    v_po := (res ->> 'document_id')::uuid;
    select dl.id into v_pl from erp.document_line dl where dl.tenant_id = v_tenant and dl.document_id = v_po;
    select ev.payload into v_carry from erp.event ev
     where ev.tenant_id = v_tenant and ev.aggregate_id = v_po and ev.event_type = 'document.approval_carried'
     order by ev.global_seq desc limit 1;
    v_ok := jsonb_typeof(v_carry -> 'order_lines') = 'array';
    perform erp.append_event('document.approval_carried', 'document', v_po,
                             v_carry - 'order_lines', v_entity, v_site);
    perform erp.amend_document_line(v_pl, 8, 'fewer');
    begin
      perform erp.transition_document(v_po, 'send', null);
      v_x := 'issued';
    exception when others then v_x := left(sqlerrm, 200); end;
    return query select 'an order carried before its lines were recorded is held to its fingerprint: a lowered line is refused',
      v_ok and v_x like 'CLOVEERP_CARRIED_ORDER_CHANGED:%changed since it was converted%'
      and erp.object_current_state('document', v_po) = 'approved',
      format('lines recorded when carried: %s; lowered with them stripped: %s', v_ok, v_x);

    -- 8. invoice_match_mode. Two ways matches a line nobody receives (no
    --    product) against what was ordered; a stocked line is matched three
    --    ways whatever the policy says, against what was received (found on
    --    review: otherwise a stocked order closed paid for goods that never
    --    came). A bill before any goods is not a variance either way: the order
    --    it is for cannot settle until they arrive (erp.order_is_settled), and
    --    PR4's bill-first close depends on it registering.
    --      1 two_way, a service line of 10, billed 10          matched
    --      2 two_way, a service line of 10, billed 12          quantity variance
    --      3 two_way, a stocked line, 5 received, billed 10    quantity variance
    --      4 three_way, a stocked line, none received, 10      matched
    --      5 three_way, a stocked line, 5 received, billed 10  quantity variance
    v_msg := '';
    for v_i in 1..5 loop
      perform erp.set_config_value('procurement.policy',
        jsonb_build_object('reapproval_qty_pct', 0, 'short_close_pct', 2,
                           'invoice_match_mode', case when v_i <= 3 then 'two_way' else 'three_way' end),
        null, null, null, null, 'the procurement policy suite');
      v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
      if v_i <= 2 then
        insert into erp.document_line (tenant_id, document_id, line_no, item_id, description,
                                       quantity, uom_id, unit_price_minor, net_minor, currency)
        select v_tenant, v_po, 1, null, 'ten hours of service', 10, v_uom, 1000, 10000, d.currency
          from erp.document d where d.tenant_id = v_tenant and d.id = v_po
        returning id into v_pl;
      else
        v_pl := erp.add_document_line(v_po, v_item, 10, 1000, 'ten');
      end if;
      perform erp.transition_document(v_po, 'submit', null);
      if erp.object_current_state('document', v_po) = 'pending_approval' then
        perform erp_test.approve_document(v_po, null);
      end if;
      perform erp.transition_document(v_po, 'send', null);
      if v_i in (3, 5) then
        v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
        perform erp.receive_against(v_g, v_pl, 5, null);
        perform erp.transition_document(v_g, 'post', null);
      end if;
      v_bill := erp.open_document('purchase_invoice', v_sup, v_entity, v_site);
      perform erp.invoice_against(v_bill, v_pl, case when v_i = 2 then 12 else 10 end, 1000);
      update erp.document set their_reference = 'ZPPOL-8-' || v_i, due_date = current_date + 30
       where tenant_id = v_tenant and id = v_bill;
      begin
        v_x := erp.transition_document(v_bill, 'register', null);
      exception when others then v_x := 'refused: ' || left(sqlerrm, 80); end;
      select count(*) into v_n from erp.match_exception mx
       where mx.tenant_id = v_tenant and mx.order_line_id = v_pl;
      select count(*) into v_n2 from erp.match_exception mx
       where mx.tenant_id = v_tenant and mx.order_line_id = v_pl
         and mx.status in ('quantity_variance', 'both');
      if (v_i in (1, 4) and v_n <> 0) or (v_i in (2, 3, 5) and v_n2 < 1) then
        v_msg := v_msg || format('scenario %s: bill %s, %s exception(s), %s of quantity; ', v_i, v_x, v_n, v_n2);
      end if;
    end loop;
    return query select 'invoice_match_mode two_way matches a line nobody receives against the order; a stocked line is matched against what was received',
      v_msg = '', coalesce(nullif(v_msg, ''), 'two ways: a service line matched at 10 and varied at 12, a stocked line varied; three ways: matched before the goods, varied with 5 received');

    -- 9. Over-receipt at 5 per cent, refused beyond: 103 of 100 is received
    --    and flagged, 110 of 100 is refused.
    update erp.receipt_tolerance set over_pct = 5, over_action = 'reject'
     where tenant_id = v_tenant and code = 'default';
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred');
    v_po2 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl2 := erp.add_document_line(v_po2, v_item, 100, 1000, 'a hundred');
    foreach v_r in array array[v_po, v_po2] loop
      perform erp.transition_document(v_r, 'submit', null);
      if erp.object_current_state('document', v_r) = 'pending_approval' then
        perform erp_test.approve_document(v_r, null);
      end if;
      perform erp.transition_document(v_r, 'send', null);
    end loop;
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 103, null);
    perform erp.transition_document(v_g, 'post', null);
    select count(*), max(ev.payload::text)::jsonb into v_n, v_ev from erp.event ev
     where ev.tenant_id = v_tenant and ev.aggregate_id = v_g and ev.event_type = 'document.over_received';
    v_g2 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    begin
      perform erp.receive_against(v_g2, v_pl2, 110, null);
      v_x := 'accepted';
    exception when others then v_x := left(sqlerrm, 120); end;
    return query select 'over_pct 5, reject: 103 of 100 is received with one over_received event, 110 of 100 is refused',
      v_n = 1 and (v_ev ->> 'over_pct')::numeric = 3
      and (v_ev ->> 'ordered_quantity')::numeric = 100 and (v_ev ->> 'received_quantity')::numeric = 103
      and v_ev ->> 'order_line_id' = v_pl::text
      and erp.object_current_state('document', v_g) = 'posted'
      and erp.object_current_state('document', v_po) = 'received'
      and v_x like 'CLOVEERP_OVER_DELIVERY:%'
      and not exists (select 1 from erp.document_line dl where dl.tenant_id = v_tenant and dl.document_id = v_g2),
      format('103: %s event(s) %s, receipt %s, order %s; 110: %s', v_n, coalesce(v_ev::text, '-'),
             erp.object_current_state('document', v_g), erp.object_current_state('document', v_po), v_x);

    -- 10. The same, in two receipts: 60 then 43 is received and flagged; 60
    --     then 50 is refused.
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred');
    v_po2 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl2 := erp.add_document_line(v_po2, v_item, 100, 1000, 'a hundred');
    foreach v_r in array array[v_po, v_po2] loop
      perform erp.transition_document(v_r, 'submit', null);
      if erp.object_current_state('document', v_r) = 'pending_approval' then
        perform erp_test.approve_document(v_r, null);
      end if;
      perform erp.transition_document(v_r, 'send', null);
      v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
      perform erp.receive_against(v_g, case when v_r = v_po then v_pl else v_pl2 end, 60, null);
      perform erp.transition_document(v_g, 'post', null);
    end loop;
    select count(*) into v_n2 from erp.event ev
     where ev.tenant_id = v_tenant and ev.event_type = 'document.over_received'
       and ev.payload ->> 'order_line_id' in (v_pl::text, v_pl2::text);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    begin
      perform erp.receive_against(v_g, v_pl, 43, null);
      perform erp.transition_document(v_g, 'post', null);
      v_x := 'accepted';
    exception when others then v_x := left(sqlerrm, 120); end;
    select count(*), max(ev.payload::text)::jsonb into v_n, v_ev from erp.event ev
     where ev.tenant_id = v_tenant and ev.aggregate_id = v_g and ev.event_type = 'document.over_received';
    v_g2 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    begin
      perform erp.receive_against(v_g2, v_pl2, 50, null);
      v_x2 := 'accepted';
    exception when others then v_x2 := left(sqlerrm, 120); end;
    return query select 'over-receipt is measured on the line: 60 then 43 is received with the event, 60 then 50 is refused',
      v_n2 = 0 and v_x = 'accepted' and v_n = 1
      and (v_ev ->> 'over_pct')::numeric = 3 and (v_ev ->> 'received_quantity')::numeric = 103
      and erp.object_current_state('document', v_po) = 'received'
      and v_x2 like 'CLOVEERP_OVER_DELIVERY:%',
      format('events after the 60s: %s; 43: %s, %s event(s) %s; 50: %s', v_n2, v_x, v_n,
             coalesce(v_ev::text, '-'), v_x2);

    -- 11. Behind a draft receipt for the whole line, a second receipt for
    --     more is refused: the draft holds its hundred. Measured on what was
    --     open, it saw nothing open and was always accepted.
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred');
    perform erp.transition_document(v_po, 'submit', null);
    if erp.object_current_state('document', v_po) = 'pending_approval' then
      perform erp_test.approve_document(v_po, null);
    end if;
    perform erp.transition_document(v_po, 'send', null);
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    perform erp.receive_against(v_g, v_pl, 100, null);
    v_g2 := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    begin
      perform erp.receive_against(v_g2, v_pl, 10, null);
      v_x := 'accepted';
    exception when others then v_x := left(sqlerrm, 120); end;
    return query select 'a second receipt behind a draft receipt for the whole line is refused',
      erp.object_current_state('document', v_g) = 'draft'
      and v_x like 'CLOVEERP_OVER_DELIVERY:%110%100%',
      format('draft receipt %s; second receipt of 10: %s', erp.object_current_state('document', v_g), v_x);

    -- 12. Read in case 2, before case 9 wrote the tolerance.
    return query select 'a new install of the controls refuses over-receipt beyond tolerance',
      v_tol_n = 1 and v_tol_action = 'reject' and v_tol_pct = 5,
      format('%s default tolerance(s): over_pct %s, over_action %s', v_tol_n, v_tol_pct, coalesce(v_tol_action, 'none'));

    -- 13. An upgrade never replaces a policy the organisation holds (found on
    --     review): stood back at version 2 with its own policy, version 3 plans
    --     nothing for it.
    perform erp.set_config_value('procurement.policy',
      jsonb_build_object('reapproval_qty_pct', 5, 'short_close_pct', 0, 'invoice_match_mode', 'two_way'),
      null, null, null, null, 'the procurement policy suite');
    update erp.module_installation set installer_version = 2
     where tenant_id = v_tenant and install_code = 'procurement-lifecycle';
    select count(*) into v_plan from erp.plan_module_upgrade('procurement-lifecycle') pl
     where pl.object_kind = 'config';
    update erp.module_installation set installer_version = 3
     where tenant_id = v_tenant and install_code = 'procurement-lifecycle';
    return query select 'an upgrade does not replace a procurement policy the organisation holds',
      v_plan = 0 and erp.procurement_policy(null, null) ->> 'invoice_match_mode' = 'two_way',
      format('%s policy item(s) planned over the organisation''s own', v_plan);

    -- 14. A cancelled order line takes no receipt (found on review): it was
    --     received without limit, each receipt measured on its own.
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    v_pl := erp.add_document_line(v_po, v_item, 10, 1000, 'ten');
    v_pl2 := erp.add_document_line(v_po, v_item, 10, 1000, 'ten more');
    perform erp.transition_document(v_po, 'submit', null);
    if erp.object_current_state('document', v_po) = 'pending_approval' then
      perform erp_test.approve_document(v_po, null);
    end if;
    perform erp.transition_document(v_po, 'send', null);
    update erp.document_line set is_cancelled = true where tenant_id = v_tenant and id = v_pl2;
    v_g := erp.open_document('goods_receipt', v_sup, v_entity, v_site);
    begin
      perform erp.receive_against(v_g, v_pl2, 10, null);
      v_x := 'received';
    exception when others then v_x := left(sqlerrm, 120); end;
    return query select 'a cancelled order line takes no receipt',
      v_x like 'CLOVEERP_NOT_A_LINE_TO_RECEIVE:%', v_x;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzppol')
            and not exists (select 1 from auth.users u where u.id = v_auth);
  detail := 'the organisation, its configuration and its documents rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_procurement_policy_suite()
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
    from erp_test.procurement_policy_suite() s;
  if v_total <> 15 then
    raise exception 'CLOVEERP_PROCUREMENT_POLICY_SUITE_SHRANK: % case(s), expected 15', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PROCUREMENT_POLICY_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A procurement parameter that is not read where it acts is a setting that does nothing. Read the case that failed.';
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
