-- =============================================================================
-- §7's third breach behaviour
--
-- §7 names three things that can happen when a receipt breaches tolerance:
-- "block, warn, or route to approval". erp.receipt_tolerance.over_action
-- allowed accept, reject and quarantine — neither set contains the other, and
-- the Starter Content Packs work mapped block to reject, warn to accept and
-- route-to-approval to quarantine, recording that the third was a compromise:
-- "a quarantined over-receipt is not the same as one routed to an approval
-- band: quarantine is a place stock sits, approval is a decision somebody
-- makes".
--
-- Both halves of what the real thing needs are now present.
-- erp.request_approval() has been there since B4, and §3.4's approval bands
-- arrive with the base pack, so an organisation applying the pack has chains
-- for a receipt to route into.
--
-- ONE THING THIS DELIBERATELY DOES NOT DO: it does not make 'approve' the
-- pack's default. erp.request_approval() raises ERPWARE_NO_APPROVAL_CHAIN when
-- nothing routes, and the goods bay is the wrong place to discover that
-- nobody configured a chain. The pack keeps quarantine, which needs no chain;
-- 'approve' is there for an organisation that has one and wants the decision
-- made by a person rather than by a location.
-- =============================================================================

alter table erp.receipt_tolerance
  drop constraint if exists receipt_tolerance_over_action_check;

alter table erp.receipt_tolerance
  add constraint receipt_tolerance_over_action_check
  check (over_action in ('accept', 'reject', 'quarantine', 'approve'));

comment on column erp.receipt_tolerance.over_action is
  'Starter Content Packs §7: what happens when a receipt is over tolerance. '
  'reject is §7''s block, accept is its warn, and approve is its route to '
  'approval — quarantine is this product''s own fourth, which holds the stock '
  'without asking anybody.';

-- erp.check_receipt_tolerance() needs no change: it is STABLE, it returns
-- t.over_action, and 'approve' travels through it untouched. Raising the
-- approval belongs in the volatile caller that has the receipt in front of it,
-- which is the right split — the policy function decides, the operation acts.

-- erp.receive_against(), PATCHED rather than retyped.
--
-- The first attempt at this file rewrote the function from a partial read of
-- it, and diffing the result against the original showed three behaviours
-- silently dropped: the ERPWARE_NO_QUARANTINE_LOCATION refusal, the
-- erp.document_relation 'fulfils' link between the receipt line and the order
-- line, and erp.refresh_order_line_progress() — replaced by a hand-written
-- quantity_fulfilled update that was not the same logic. What follows is the
-- deployed definition with three small changes and nothing else.

create or replace function erp.receive_against(p_receipt_id uuid, p_order_line_id uuid, p_quantity numeric, p_batch_id uuid DEFAULT NULL::uuid)

returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  ol        erp.document_line%rowtype;
  od        erp.document%rowtype;
  rd        erp.document%rowtype;
  v_line    uuid;
  v_no      integer;
  v_action  text;
  v_open    numeric;
  v_quarantine boolean;
  -- §7's route to approval: everything quarantine does, and a person asked.
  v_hold    boolean;
  v_req     uuid;
begin
  select * into ol from erp.document_line
   where tenant_id = v_tenant and id = p_order_line_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_LINE: %', p_order_line_id using errcode = '23503';
  end if;

  select * into od from erp.document where tenant_id = v_tenant and id = ol.document_id;
  select * into rd from erp.document where tenant_id = v_tenant and id = p_receipt_id;

  perform erp.authorise('procurement.receive', rd.entity_id, rd.site_id, null,
                        'document', p_receipt_id);

  -- Tolerance is measured against what is still open, not against the whole
  -- order line: three receipts of a third each are not each a two-thirds
  -- under-delivery.
  v_open := ol.quantity - coalesce(ol.quantity_fulfilled, 0);
  v_action := erp.check_receipt_tolerance(ol.item_id, od.party_id, v_open, p_quantity);

  select i.quarantine_on_receipt into v_quarantine
    from erp.item i where i.id = ol.item_id;

  -- 'approve' holds the stock exactly as 'quarantine' does — an over-receipt
  -- waiting on a decision is not available stock — and additionally asks
  -- somebody. Computed once so the two places below cannot drift apart.
  v_hold := coalesce(v_quarantine, false) or v_action in ('quarantine', 'approve');

  select coalesce(max(l.line_no), 0) + 1 into v_no
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_receipt_id;

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
    unit_price_minor, net_minor, currency, batch_id, location_id)
  values (v_tenant, p_receipt_id, v_no, ol.item_id,
          coalesce(ol.description, 'received'), p_quantity, ol.uom_id,
          ol.unit_price_minor,
          -- net_minor is what erp.document_value_minor() sums. Writing a line
          -- without it gives a document that has lines and no value, which the
          -- ledger correctly refuses to post.
          round(p_quantity * ol.unit_price_minor)::bigint,
          coalesce(ol.currency, od.currency), p_batch_id,
          -- Quality routing. erp.item.quarantine_on_receipt has existed since
          -- B7 and nothing has ever read it, so an item that must be inspected
          -- went straight into available stock and could be picked before
          -- anybody looked at it.
          case when v_hold
               then (select l.id from erp.location l
                      where l.tenant_id = v_tenant and l.site_id = rd.site_id
                        and l.location_type = 'quarantine' and l.status = 'active'
                      order by l.code limit 1)
          end)
  returning id into v_line;

  if v_hold
     and (select location_id from erp.document_line where id = v_line) is null then
    raise exception
      'ERPWARE_NO_QUARANTINE_LOCATION: % must be inspected on receipt and this '
      'site has no quarantine location', ol.item_id
      using errcode = '23503',
      hint = 'Configure one. Receiving an inspect-on-arrival item into '
             'available stock lets it be picked before anybody looks at it.';
  end if;

  insert into erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind,
    from_line_id, to_line_id, quantity)
  values (v_tenant, p_receipt_id, ol.document_id, 'fulfils',
          v_line, p_order_line_id, p_quantity);

  -- Asked after the line and its lineage exist, so the request names something
  -- a person can open. A missing chain is a configuration gap, not a reason to
  -- refuse goods already on the bay: the stock is quarantined either way, and
  -- erp.receipt_approval_routing_report() names the gap where it can be fixed
  -- rather than leaving a warehouse operative to discover it.
  if v_action = 'approve' then
    begin
      v_req := erp.request_approval(
        'document', p_receipt_id,
        jsonb_build_object('reason', 'receipt over tolerance',
                           'ordered', v_open, 'received', p_quantity,
                           'order_line_id', p_order_line_id),
        1, rd.entity_id, rd.site_id);
    exception when others then
      if sqlerrm not like 'ERPWARE_NO_APPROVAL_CHAIN%' then raise; end if;
      v_req := null;
    end;
  end if;

  perform erp.refresh_order_line_progress(p_order_line_id);

  return v_line;
end;
$$;

-- The configuration gap, named where it can be acted on rather than at the bay.
create or replace function erp.receipt_approval_routing_report()
returns table (finding text, tolerance_code text, reference text)
language sql
stable
set search_path = ''
as $$
  select 'this tolerance routes an over-receipt to approval, and no approval '
         'chain covers a document — the stock would be quarantined and nobody '
         'asked',
         rt.code,
         format('over %s%%', rt.over_pct)
    from erp.receipt_tolerance rt
   where rt.tenant_id = erp.require_tenant_id()
     and rt.status = 'active' and rt.over_action = 'approve'
     and not exists (
       select 1 from erp.approval_chain ac
        where ac.tenant_id = rt.tenant_id and ac.status = 'active'
          and ac.object_type = 'document')
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('receipt_approval_routing', 'Receipt approval routing', 'report', 'tenant',
        'receipt_approval_routing_report', '', null, '',
        'Receipt tolerances set to route an over-delivery to approval where no '
        'chain would carry it. The stock is still held; the difference is '
        'whether anybody is asked.', false, 29)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind, scope = excluded.scope;

update erp_meta.policy_decision set
  decision =
    'erp.receipt_tolerance.over_action now allows approve as well as accept, '
    'reject and quarantine. §7''s three behaviours all exist: reject is block, '
    'accept is warn, approve is route to approval. The base pack keeps '
    'quarantine as its default.',
  rationale =
    'The compromise was recorded because a quarantined over-receipt is not a '
    'decision somebody made. It is one now: erp.receive_against() raises an '
    'approval request against the receipt when the tolerance says approve, '
    'holding the stock as quarantine does and additionally asking a person. '
    'The default stays quarantine because erp.request_approval() raises when '
    'nothing routes, and a goods bay is the wrong place to discover that no '
    'chain was configured — that gap is reported instead.',
  evidence =
    'erp.check_receipt_tolerance() is STABLE and returns the action; the '
    'volatile caller acts on it, which is why the approval is raised in '
    'erp.receive_against() and not in the policy function. '
    'erp.receipt_approval_routing_report() names a tolerance set to approve '
    'with no chain behind it.',
  status = 'accepted', decided_at = now()
 where code = 'receipt_tolerance_breach_actions';

select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_isolation();
