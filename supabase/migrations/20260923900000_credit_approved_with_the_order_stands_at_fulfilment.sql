-- =============================================================================
-- 20260923900000  Credit approved with the order stands at fulfilment
-- -----------------------------------------------------------------------------
-- PR6, M2: nodes S4 and S5 of docs/spec/simplification-review.md, as checked
-- against the built database before this was written.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- S4. Credit was approved twice. The credit step of sales_order_terms asked
-- about an order past its customer's limit when it was committed; then
-- erp.check_release_to_fulfilment() held the same order at picking for the
-- same excess, until somebody pressed Release a credit hold. The two did not
-- even measure the same thing: the step counted the orders in flight, the
-- hold counted those and what the customer already owed.
--
-- S5. The Sales manager step had no condition, so every order at any value
-- waited on a manager, and the chain left its re-approval tolerance to the
-- organisation's default.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * An order counts in its customer's exposure at what it has not yet
--     invoiced; an invoiced order was counted twice, as an order and as the
--     receivable (A0). The approval's context counts what the customer owes,
--     as the credit position does (A1), so the credit step and the hold read
--     one number. The credit position names overdue debt ahead of the limit.
--   * At fulfilment, an order held only for being over the limit goes through
--     on a credit step approved with it, or approved since on another of the
--     customer's orders, while what the customer owes and has on order is no
--     more than that approval read, widened by the tolerance
--     sales.credit_control allows, and the limit has not been cut (A2). A
--     customer on hold or with debt overdue is held as before, and Release a
--     credit hold stays the way past for everything else.
--   * Approve is not drawn for a discount or credit step its holder may not
--     give, now or further along the same press (A3), the open item from
--     PR5 M3.
--   * A new install's chain asks the Sales manager about an order worth more
--     than 1,000.00 and carries a tolerance of two per cent and 100.00 (A4).
--     An organisation already trading keeps its chain: see A4 for why.
--
-- ── WHAT CHANGES FOR DOCUMENTS IN FLIGHT ─────────────────────────────────────
--
-- An approval already given keeps the context it was given on, which counted
-- orders only. At fulfilment it is compared with what the customer owes and
-- has on order now, so an order approved before this was written goes
-- through if the customer owes no more than those orders came to, and is
-- held as before otherwise.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A0. What an order still has to invoice, and the invoices it has raised
--
-- An order invoiced was counted twice in the customer's exposure: as an
-- order in flight, which it stays until its invoices are settled, and as the
-- receivable its invoices raised (found on review). The order now counts
-- only what it has not yet invoiced; the receivable counts the rest.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.sales_order_invoices(p_order_id uuid)
returns table(invoice_id uuid)
language sql
stable
set search_path = ''
as $$
  -- The invoices raised for the order's deliveries, as
  -- erp.sales_order_is_settled() finds them (20260923800000), issued or on.
  select distinct iv.id
    from erp.related_documents(p_order_id, 'fulfils') as f(delivery_id)
    join erp.document dn on dn.tenant_id = erp.current_tenant_id() and dn.id = f.delivery_id
    join erp.document_type dnt on dnt.tenant_id = dn.tenant_id and dnt.id = dn.document_type_id
    cross join lateral erp.related_documents(dn.id, 'invoices') as b(invoice_id)
    join erp.document iv on iv.tenant_id = erp.current_tenant_id() and iv.id = b.invoice_id
    join erp.document_type it on it.tenant_id = iv.tenant_id and it.id = iv.document_type_id
    join erp.object_state os on os.tenant_id = iv.tenant_id and os.object_type = 'document' and os.object_id = iv.id
    join erp.state s on s.id = os.current_state_id
   where dnt.base_type_code = 'delivery' and not dn.is_cancelled
     and it.base_type_code = 'invoice_reference' and not iv.is_cancelled
     and s.is_committed
$$;

comment on function erp.sales_order_invoices(uuid) is
  'The issued (or paid, or credited) invoices raised for a sales order''s deliveries '
  '(20260923900000).';

create or replace function erp.sales_order_uninvoiced_minor(p_order_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- The order's value less the value of the invoices it has raised, never
  -- below nought: what the customer has on order and does not yet owe.
  select greatest(0, erp.document_value_minor(p_order_id)
                     - coalesce((select sum(erp.document_value_minor(i.invoice_id))
                                   from erp.sales_order_invoices(p_order_id) i), 0))::bigint
$$;

comment on function erp.sales_order_uninvoiced_minor(uuid) is
  'What a sales order has on order and has not yet invoiced, which is what it adds to '
  'its customer''s exposure beside the receivable (20260923900000).';

-- The credit position, restated with orders counted at what they have not
-- yet invoiced, and with whether debt is overdue said on its own column's
-- terms inside the one verdict, so the fulfilment check (A2) asks it rather
-- than copying it.

CREATE OR REPLACE FUNCTION erp.credit_position(p_party_id uuid)
 RETURNS TABLE(credit_limit_minor bigint, exposure_minor bigint, headroom_minor bigint, credit_status text, is_blocked boolean, on_hold boolean, reason text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with terms as (
    select t.credit_limit_minor, t.credit_status, t.is_blocked, t.block_reason, t.entity_id
      from erp.party_role_terms t
      join erp.party_role pr on pr.id = t.party_role_id
     where t.tenant_id = erp.current_tenant_id()
       and pr.party_id = p_party_id and pr.role_kind = 'customer'
       and t.valid_from <= current_date
       and (t.valid_to is null or t.valid_to > current_date)
     order by t.valid_from desc limit 1
  ),
  -- sales.credit_control, at the terms' company.
  pol as (
    select coalesce(erp.config_value('sales.credit_control', null, null, (select t.entity_id from terms t), null), '{}'::jsonb) as v
  ),
  exposure as (
    -- Committed and not yet settled: orders in flight plus receivables
    -- outstanding. Counting only one of them understates by whichever half is
    -- currently larger; counting an invoiced order in both overstated it by
    -- what it had invoiced, so an order counts what it has not yet invoiced
    -- (20260923900000).
    select coalesce((select sum(erp.sales_order_uninvoiced_minor(d.id))
                       from erp.document d
                       join erp.document_type dt on dt.id = d.document_type_id
                       join erp.object_state os on os.object_type = 'document'
                                               and os.object_id = d.id
                       join erp.state s on s.id = os.current_state_id
                      where d.tenant_id = erp.current_tenant_id()
                        and d.party_id = p_party_id
                        and dt.base_type_code = 'sales_order'
                        and s.is_committed and not s.is_terminal
                        and not d.is_cancelled), 0)
         + coalesce((select sum(si.debit_minor - si.credit_minor)
                       from erp.subledger_item si
                      where si.tenant_id = erp.current_tenant_id()
                        and si.party_id = p_party_id
                        and si.control_kind = 'receivable'), 0) as amt
  ),
  -- Debt past the policy's overdue window: an item still owing whose due date
  -- is further back than overdue_days_block.
  overdue as (
    select exists (
      select 1 from erp.subledger_item si, pol
       where si.tenant_id = erp.current_tenant_id()
         and si.party_id = p_party_id
         and si.control_kind = 'receivable'
         and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
         and si.due_date is not null
         and si.due_date < current_date - coalesce((pol.v ->> 'overdue_days_block')::integer, 30)) as any_overdue
  ),
  verdict as (
    select terms.credit_limit_minor,
           exposure.amt,
           coalesce(terms.is_blocked, false) as blocked,
           -- The limit, widened by the tolerance the policy allows.
           (terms.credit_limit_minor is not null
              and coalesce((pol.v ->> 'block_at_limit')::boolean, true)
              and exposure.amt > round(terms.credit_limit_minor * (1 + coalesce((pol.v ->> 'tolerance_pct')::numeric, 0) / 100))) as over_limit,
           overdue.any_overdue as overdue,
           terms.credit_status, terms.is_blocked, terms.block_reason
      from terms, exposure, pol, overdue
  )
  select v.credit_limit_minor, v.amt,
         v.credit_limit_minor - v.amt,
         v.credit_status, v.is_blocked,
         v.blocked or v.over_limit or v.overdue,
         -- Overdue debt is named ahead of the limit (20260923900000): a
         -- standing approval carries an order past the limit, never past debt
         -- the policy says stops supply, and the reason is what says which.
         case when v.blocked then coalesce(v.block_reason, 'blocked')
              when v.overdue then 'debt is overdue beyond the policy''s window'
              when v.over_limit then 'exposure exceeds the credit limit'
              else 'within terms' end
    from verdict v
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The approval reads the customer's exposure as the credit hold reads it
--
-- The credit step compared the orders in flight with the limit; the credit
-- hold at fulfilment, erp.credit_position(), compares the orders in flight and
-- what the customer already owes. An order approved on the first could be
-- held on the second for the debt the approver was never shown. The context
-- now carries the receivable too, read as erp.credit_position() reads it, so
-- the step and the hold measure the same thing and the approval can stand at
-- fulfilment (A2). (Both read the customer's newest terms in force; where a
-- customer has terms with more than one company the step prefers the order's
-- company's, and the fulfilment check then holds rather than lets through.)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp.document_transition_context(p_document_id uuid, p_transition_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_total  bigint;
  v_discount numeric;
  v_limit  bigint;
  v_exposure bigint;
  v_receivable bigint;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  v_total := erp.document_value_minor(p_document_id);

  select coalesce(max(l.discount_pct), 0) into v_discount
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled;

  -- The customer's limit, from their customer role. Absent means no limit was
  -- set, and an absent limit must not read as a limit of zero — that would put
  -- every order through credit release.
  -- The limit is read from the customer's trading terms in force, the one
  -- place a limit is set and the place the credit position reads
  -- (20260914074000), the document's company first. A customer with no terms
  -- in force is read from the limit their customer role carried before terms
  -- held it.
  select t.credit_limit_minor
    into v_limit
    from erp.party_role_terms t
    join erp.party_role pr on pr.tenant_id = t.tenant_id and pr.id = t.party_role_id
   where t.tenant_id = v_tenant and pr.party_id = d.party_id
     and pr.role_kind = 'customer'
     and t.valid_from <= current_date
     and (t.valid_to is null or t.valid_to > current_date)
   order by (t.entity_id = d.entity_id) desc, t.valid_from desc
   limit 1;

  if not found then
    select (pr.attributes ->> 'credit_limit_minor')::bigint
      into v_limit
      from erp.party_role pr
     where pr.tenant_id = v_tenant and pr.party_id = d.party_id
       and pr.role_kind = 'customer' and pr.status = 'active'
     limit 1;
  end if;

  -- Everything already committed for this customer and not yet invoiced or
  -- finished, excluding this document so the sum below is not doubled. An
  -- order counts what it has not yet invoiced, as the credit position counts
  -- it (20260923900000).
  select coalesce(sum(erp.sales_order_uninvoiced_minor(d2.id)), 0) into v_exposure
    from erp.document d2
    join erp.document_type dt2 on dt2.tenant_id = d2.tenant_id and dt2.id = d2.document_type_id
    join erp.object_state os2 on os2.tenant_id = d2.tenant_id
                             and os2.object_type = 'document' and os2.object_id = d2.id
    join erp.state s2 on s2.id = os2.current_state_id
   where d2.tenant_id = v_tenant
     and d2.party_id = d.party_id
     and dt2.base_type_code = 'sales_order'
     and s2.is_committed and not s2.is_terminal
     and d2.id <> p_document_id
     and not d2.is_cancelled;

  -- What the customer already owes, as erp.credit_position() counts it.
  select coalesce(sum(si.debit_minor - si.credit_minor), 0) into v_receivable
    from erp.subledger_item si
   where si.tenant_id = v_tenant
     and si.party_id = d.party_id
     and si.control_kind = 'receivable';

  v_ctx := jsonb_build_object(
    'document_type', dt.code,
    'document_number', d.document_number,
    'total_minor', v_total,
    'currency', d.currency,
    'party_id', d.party_id,
    'entity_id', d.entity_id,
    'transition', p_transition_code,
    'max_discount_pct', v_discount,
    'credit_limit_minor', coalesce(v_limit, 9223372036854775807),
    'receivable_minor', v_receivable,
    'exposure_after_minor', v_exposure + v_receivable + erp.sales_order_uninvoiced_minor(p_document_id));

  return v_ctx;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. Credit approved with the order stands at fulfilment, within tolerance
--
-- Spec S4: credit was approved twice, by the credit step of sales_order_terms
-- when the order was committed and again by Release a credit hold when it was
-- picked, for the same excess. The commitment one is kept. At fulfilment an
-- order held only for being over the limit goes through when:
--
--   * its standing approval on sales_order_terms approved the credit step,
--     the limit is no lower than the one that approval read, and what the
--     customer owes and has on order is no more than the approval read when
--     it was asked for, widened by the tolerance sales.credit_control allows.
--     The order's own invoicing and payment are counted as the order was, so
--     delivering and billing what was approved does not use the tolerance up
--     (the receivable carries tax the order does not); or
--   * a credit step approved since, for another of the customer's orders in
--     flight, read at least as much (and so read this order in it).
--
-- A customer on hold or with debt overdue is never let through on an
-- approval of the order: erp.credit_position() names those ahead of the
-- limit, and only its reason "exposure exceeds the credit limit" is carried.
-- Release a credit hold stays the way past for everything else.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp.check_release_to_fulfilment(p_document_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  c        record;
  q        erp.approval_request%rowtype;
  v_terms_entity uuid;
  v_tol    numeric;
  v_seen   bigint;
  v_seen_limit bigint;
  v_own    bigint;
  v_why    text;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found or d.party_id is null then
    return 'clear';
  end if;

  -- No terms in force is no credit control: the credit position answers no row.
  select * into c from erp.credit_position(d.party_id);
  if not found or not coalesce(c.on_hold, false) then
    return 'clear';
  end if;

  -- Somebody who may release credit holds released this order, with a reason.
  if d.attributes ? 'credit_released_by' then
    return 'released';
  end if;

  -- Held for the limit alone: the standing approval of the credit may carry
  -- it (20260923900000).
  if c.reason = 'exposure exceeds the credit limit' then
    -- The tolerance at the terms' company, as the credit position reads it.
    select t.entity_id into v_terms_entity
      from erp.party_role_terms t
      join erp.party_role pr on pr.id = t.party_role_id
     where t.tenant_id = v_tenant and pr.party_id = d.party_id and pr.role_kind = 'customer'
       and t.valid_from <= current_date and (t.valid_to is null or t.valid_to > current_date)
     order by t.valid_from desc limit 1;
    v_tol := coalesce((erp.config_value('sales.credit_control', null, null, v_terms_entity, null)
                         ->> 'tolerance_pct')::numeric, 0);

    select ar.* into q
      from erp.approval_request ar
     where ar.tenant_id = v_tenant
       and ar.object_type = 'document'
       and ar.object_id = p_document_id
       and ar.status = 'approved'
     order by ar.decided_at desc nulls last, ar.requested_at desc
     limit 1;

    if found then
      -- This order's own credit approval.
      if exists (select 1 from erp.approval_chain ac
                  where ac.tenant_id = v_tenant and ac.id = q.approval_chain_id
                    and ac.code = 'sales_order_terms')
         and exists (select 1 from erp.approval_task t
                      where t.tenant_id = v_tenant and t.approval_request_id = q.id
                        and t.step_code = 'credit' and t.status = 'approved') then
        v_seen := nullif(q.context ->> 'exposure_after_minor', '')::bigint;
        v_seen_limit := coalesce(nullif(q.context ->> 'credit_limit_minor', '')::bigint, 0);
        -- What the customer owes and has on order, with this order counted
        -- at its value as it was when the approval was asked for.
        select coalesce(sum(si.debit_minor - si.credit_minor), 0) into v_own
          from erp.subledger_item si
         where si.tenant_id = v_tenant and si.party_id = d.party_id
           and si.control_kind = 'receivable'
           and si.document_id in (select i.invoice_id from erp.sales_order_invoices(p_document_id) i);
        if v_seen is not null
           and c.credit_limit_minor >= v_seen_limit
           and c.exposure_minor - erp.sales_order_uninvoiced_minor(p_document_id) - v_own
               + erp.document_value_minor(p_document_id)
               <= round(v_seen * (1 + v_tol / 100)) then
          return 'approved';
        end if;
      end if;

      -- A credit step approved since, on another order of the customer's
      -- still in flight, that read at least what the customer has now.
      if exists (
           select 1
             from erp.approval_request q2
             join erp.approval_chain ac on ac.tenant_id = q2.tenant_id and ac.id = q2.approval_chain_id
                                       and ac.code = 'sales_order_terms'
             join erp.document d2 on d2.tenant_id = q2.tenant_id and d2.id = q2.object_id
             join erp.object_state os2 on os2.tenant_id = d2.tenant_id
                                      and os2.object_type = 'document' and os2.object_id = d2.id
             join erp.state s2 on s2.id = os2.current_state_id
            where q2.tenant_id = v_tenant
              and q2.object_type = 'document'
              and q2.status = 'approved'
              and q2.object_id <> p_document_id
              and d2.party_id = d.party_id and not d2.is_cancelled
              and s2.is_committed and not s2.is_terminal
              and q2.requested_at >= coalesce(q.decided_at, q.requested_at)
              and exists (select 1 from erp.approval_task t2
                           where t2.tenant_id = q2.tenant_id and t2.approval_request_id = q2.id
                             and t2.step_code = 'credit' and t2.status = 'approved')
              and c.credit_limit_minor >= coalesce(nullif(q2.context ->> 'credit_limit_minor', '')::bigint, 0)
              and c.exposure_minor <= round(coalesce(nullif(q2.context ->> 'exposure_after_minor', '')::bigint, 0)
                                            * (1 + v_tol / 100))) then
        return 'approved';
      end if;
    end if;
  end if;

  v_why := case
    when coalesce(c.is_blocked, false) then
      format('the customer is on credit hold (%s)', coalesce(nullif(btrim(c.reason), ''), 'no reason was recorded'))
    when c.reason = 'exposure exceeds the credit limit' and v_seen is not null then
      format('the customer owes and has on order %s, over their credit limit of %s and beyond the %s approved with the order at a limit of %s',
             to_char(c.exposure_minor / 100.0, 'FM999,999,999,990.00'),
             to_char(c.credit_limit_minor / 100.0, 'FM999,999,999,990.00'),
             to_char(v_seen / 100.0, 'FM999,999,999,990.00'),
             to_char(v_seen_limit / 100.0, 'FM999,999,999,990.00'))
    when c.reason = 'exposure exceeds the credit limit' then
      format('the customer owes and has on order %s, over their credit limit of %s',
             to_char(c.exposure_minor / 100.0, 'FM999,999,999,990.00'),
             to_char(c.credit_limit_minor / 100.0, 'FM999,999,999,990.00'))
    else 'the customer has debt overdue beyond the organisation''s credit policy'
  end;

  raise exception 'CLOVEERP_CREDIT_HOLD: % is held on credit, because %', d.document_number, v_why
    using errcode = '42501',
          hint = 'Somebody who may release credit holds can release the order on the Sales screen with Release a credit hold, giving the reason, or change the customer''s credit with Set a customer''s credit limit. Then pick or deliver it again.';
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. Approve is not drawn for a discount or credit step the holder cannot give
--
-- The open item from PR5 M3 (20260923600000): erp.transition_refusal()
-- foresaw every refusal of Approve but the permissions a sales order's
-- discount and credit steps ask for, so the control was drawn and the press
-- refused. It is foreseen now, with the code erp.authorise() raises, for the
-- step open now and for the ones the press would open for the same person.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp.transition_refusal(p_document_id uuid, p_transition_code text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_chain  text;
  q        erp.approval_request%rowtype;
  v_admin  boolean;
  v_terms  boolean;
  v_seq    integer;
  v_any    boolean;
  v_all    boolean;
  v_mine   boolean;
  st       record;
begin
  if p_transition_code is distinct from 'approve' or v_tenant is null then
    return null;
  end if;

  select dt.approval_chain_code into v_chain
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = p_document_id;
  if v_chain is null then
    return null;
  end if;

  select ar.* into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant
     and ar.object_type = 'document'
     and ar.object_id = p_document_id
     and ar.status in ('pending', 'approved', 'rejected')
   order by (ar.status = 'pending') desc, ar.requested_at desc, (ar.status = 'approved') desc
   limit 1;
  if not found then
    return null;
  end if;

  v_admin := erp.approves_as_administrator();

  if q.status = 'pending' then
    if v_admin then
      return null;
    end if;
    if exists (select 1 from erp.approval_task t
                where t.tenant_id = v_tenant and t.approval_request_id = q.id
                  and t.status = 'pending' and t.assignee_user_id = erp.current_principal_id()) then
      -- The press decides the holder's own task, and erp.decide_approval_task()
      -- refuses the person who asked, in a live organisation, whoever holds
      -- the task (found on review).
      if q.requested_by = erp.current_principal_id() and erp.tenant_is_live(v_tenant) then
        return 'CLOVEERP_DOCUMENT_SELF_APPROVAL';
      end if;

      -- A sales order's discount and credit steps are for somebody who may
      -- approve discounts and release credit, as erp.decide_approval_task()
      -- refuses them to anybody else (20260923900000). The press decides the
      -- holder's tasks one step after another (erp.approve_my_document_tasks),
      -- so the steps it would go on to open for them are asked too: the ones
      -- that apply, while every step that applies is theirs.
      v_terms := exists (select 1 from erp.approval_chain ac
                          where ac.tenant_id = v_tenant and ac.id = q.approval_chain_id
                            and ac.code = 'sales_order_terms');
      if v_terms then
        if exists (select 1 from erp.approval_task t
                    where t.tenant_id = v_tenant and t.approval_request_id = q.id
                      and t.status = 'pending' and t.assignee_user_id = erp.current_principal_id()
                      and ((t.step_code = 'discount'
                            and not erp.has_permission('sales.discount_approve', q.entity_id, q.site_id))
                        or (t.step_code = 'credit'
                            and not erp.has_permission('sales.credit_release', q.entity_id, q.site_id)))) then
          return 'CLOVEERP_PERMISSION_DENIED';
        end if;

        -- The press goes on only once every task open now is decided, which
        -- it can do only when they are all the holder's.
        v_seq := q.current_seq;
        v_all := not exists (select 1 from erp.approval_task t
                              where t.tenant_id = v_tenant and t.approval_request_id = q.id
                                and t.status = 'pending'
                                and t.assignee_user_id is distinct from erp.current_principal_id());
        while v_all and v_seq is not null loop
          select min(s.seq) into v_seq
            from erp.approval_step s
           where s.tenant_id = v_tenant
             and s.approval_chain_version_id = q.approval_chain_version_id
             and s.seq > v_seq;
          exit when v_seq is null;
          v_any := false;
          for st in
            select s.* from erp.approval_step s
             where s.tenant_id = v_tenant
               and s.approval_chain_version_id = q.approval_chain_version_id
               and s.seq = v_seq
          loop
            continue when not erp.jsonlogic_bool(st.condition, q.context);
            v_any := true;
            v_mine := exists (select 1 from erp.step_approvers(st.id, q.object_type, q.entity_id, q.site_id, q.id) a
                               where a.app_user_id = erp.current_principal_id()
                                 and a.app_user_id is distinct from q.requested_by);
            if not v_mine then
              v_all := false;
            elsif (st.code = 'discount'
                   and not erp.has_permission('sales.discount_approve', q.entity_id, q.site_id))
               or (st.code = 'credit'
                   and not erp.has_permission('sales.credit_release', q.entity_id, q.site_id)) then
              return 'CLOVEERP_PERMISSION_DENIED';
            end if;
          end loop;
        end loop;
      end if;
      return null;
    end if;
    return 'CLOVEERP_DOCUMENT_APPROVAL_PENDING';
  end if;

  if q.status = 'rejected' then
    return 'CLOVEERP_DOCUMENT_APPROVAL_REJECTED';
  end if;

  if q.requested_by = erp.current_principal_id()
     and erp.tenant_is_live(v_tenant)
     and not (erp.may_approve_own(q.requested_by, p_document_id)
              and erp.sole_approver_asked(q.id, q.requested_by))
     and exists (select 1 from erp.approval_task t
                  where t.tenant_id = v_tenant and t.approval_request_id = q.id
                    and t.status <> 'skipped')
     and not v_admin then
    return 'CLOVEERP_DOCUMENT_SELF_APPROVAL';
  end if;

  return null;
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The sales order terms chain a new install takes, from one helper
--
-- Spec S5: the Sales manager step had no condition, so every order at any
-- value waited on a manager. It now asks about an order worth more than
-- 1,000.00; below that no step applies unless the discount or the credit
-- does, and the request approves itself as a band below every threshold
-- always has (erp.request_approval()). The chain carries its own tolerance,
-- two per cent and no more than 100.00, where it left the organisation's
-- default (approval.reapproval_tolerance) to answer. It is what
-- erp.check_reapproval_required() reads; nothing a sales order does asks
-- that today, so until something does it is the chain's stated policy.
--
-- A new install takes it. An organisation already trading keeps the chain
-- it has (found on review): the chain names the organisation's own approver
-- role and discount threshold, and the upgrade register carries one payload
-- for everybody, so offering it as an upgrade would hand every step back to
-- the administrator at fifteen per cent. The installer stays at version 3:
-- nothing in the register changes. An organisation changes its chain on the
-- Configuration screen, through a change set, as it always could.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.sales_order_terms_item(
  p_discount_threshold_pct numeric default 15,
  p_approver_role text default 'administrator',
  p_manager_threshold_minor bigint default 100000)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The chain a new install of the sales lifecycle takes (20260923900000),
  -- from erp.configure_sales(), and what a suite compares a chain with.
  select jsonb_build_object('kind','approval_chain','key','sales_order_terms','payload',
        jsonb_build_object(
          'code','sales_order_terms','name','Sales order terms approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'sales_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id','max_discount_pct'),
          'tolerance_pct', 2, 'tolerance_absolute', 10000,
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','sales_manager','name','Sales manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','total_minor'), p_manager_threshold_minor))),
            jsonb_build_object('seq',2,'code','discount','name','Discount approval',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','max_discount_pct'), p_discount_threshold_pct))),
            jsonb_build_object('seq',3,'code','credit','name','Credit release',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              -- The sum is computed into the context rather than in the rule,
              -- so the interpreter needs no arithmetic and the configured rule
              -- stays one readable comparison. It is what the customer owes
              -- and has on order, as the credit hold reads it (20260923900000).
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','exposure_after_minor'),
                jsonb_build_object('var','credit_limit_minor')))))))
$$;

comment on function erp.sales_order_terms_item(numeric, text, bigint) is
  'The sales order terms approval chain as a new install of the sales lifecycle takes it '
  '(20260923900000): the configuration item erp.configure_sales() reads.';

do $configure$
declare
  v_sig constant text := 'erp.configure_sales(numeric,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      jsonb_build_object('kind','approval_chain','key','sales_order_terms','payload',
        jsonb_build_object(
          'code','sales_order_terms','name','Sales order terms approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'sales_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id','max_discount_pct'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','sales_manager','name','Sales manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','discount','name','Discount approval',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','max_discount_pct'), p_discount_threshold_pct))),
            jsonb_build_object('seq',3,'code','credit','name','Credit release',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              -- The sum is computed into the context rather than in the rule,
              -- so the interpreter needs no arithmetic and the configured rule
              -- stays one readable comparison.
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','exposure_after_minor'),
                jsonb_build_object('var','credit_limit_minor'))))))),
$o$;
  v_new constant text := $n$      -- The chain from its one helper (20260923900000).
      erp.sales_order_terms_item(p_discount_threshold_pct, p_approver_role),
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % sales order terms block found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. What proves it: erp_test.credit_control_suite()
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.credit_control_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  s_deleg uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_second uuid; v_tok text; u_deleg uuid;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid; v_grn uuid; v_ccy char(3);
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_role1 uuid; v_role2 uuid; v_role3 uuid;
  v_o1 uuid; v_o1l uuid; v_dn1 uuid; v_inv1 uuid;
  v_o2 uuid; v_o3 uuid; v_o4 uuid; v_o4l uuid; v_o8 uuid; v_o9 uuid; v_o10 uuid; v_o11 uuid;
  v_dn uuid; v_inv uuid; v_billed text; v_cover text; v_ref3 text; v_ref4 text;
  v_ctx jsonb; v_cp record; v_n integer; v_s text; v_s2 text; v_err text; v_err2 text;
  v_seen bigint; v_dn4 uuid; v_tol numeric; v_tabs numeric; v_cond jsonb;
  v_says text; v_says2 text; v_says3 text; v_says4 text; v_says5 text;
  v_ref text; v_ref2 text; v_offered jsonb;
begin
  begin
    select * into r from erp.provision_tenant(
      'zz-ccs-' || v_hex, 'Credit control suite',
      'admin@zz-ccs-' || v_hex || '.test', 'Credit Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zz-ccs-' || v_hex || '.test'), (a2, 'second@zz-ccs-' || v_hex || '.test'),
           (s_deleg, 'dee@zz-ccs-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    res := public.erp_invite_principal('second@zz-ccs-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select s.id into v_site from erp.site s
     where s.tenant_id = r.tenant_id and s.entity_id = r.entity_id order by s.code limit 1;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = r.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    select e.base_currency into v_ccy from erp.entity e where e.tenant_id = r.tenant_id and e.id = r.entity_id;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZCCSUP', 'Credit Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZCCC1', 'Credit Suite Account', 'active') returning id into v_c1;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_c1, 'customer', 'active') returning id into v_role1;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZCCC2', 'Credit Suite Second Account', 'active') returning id into v_c2;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_c2, 'customer', 'active') returning id into v_role2;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZCCC3', 'Credit Suite New Account', 'active') returning id into v_c3;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_c3, 'customer', 'active') returning id into v_role3;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZCCC4', 'Credit Suite Cash Account', 'active') returning id into v_c4;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_c4, 'customer', 'active');
    insert into erp.party_role_terms (
      tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)
    values (r.tenant_id, v_role1, r.entity_id, v_ccy, 500000, 'ok', false, current_date - 1),
           (r.tenant_id, v_role2, r.entity_id, v_ccy, 100000, 'ok', false, current_date - 1);
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZCCWID', 'Credit Suite Widget', v_uom, 'active') returning id into v_item;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 100, 1000, 'the stock');
    perform erp.transition_document(v_grn, 'post', 'credit control suite');

    -- 1. The approval reads what the customer owes as the credit hold does.
    v_o1 := erp.open_document('sales_order', v_c1, null, v_site);
    v_o1l := erp.add_document_line(v_o1, v_item, 2, 20000, 'Two widgets');
    perform erp.transition_document(v_o1, 'submit', 'credit control suite');
    perform erp_test.approve_document(v_o1, 'credit control suite');
    v_dn1 := (erp.create_delivery_from_order(v_o1) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn1, 'post', 'credit control suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_inv1 := erp.invoice_from_delivery(v_dn1);
    perform erp.transition_document(v_inv1, 'issue', 'credit control suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_o2 := erp.open_document('sales_order', v_c1, null, v_site);
    perform erp.add_document_line(v_o2, v_item, 1, 20000, 'One widget');
    v_ctx := erp.document_transition_context(v_o2, null);
    select * into v_cp from erp.credit_position(v_c1);
    return query select 'the approval reads what the customer owes and has on order as the credit hold reads it',
      (v_ctx ->> 'receivable_minor')::bigint > 0
      and (v_ctx ->> 'exposure_after_minor')::bigint = v_cp.exposure_minor + erp.document_value_minor(v_o2),
      format('owed %s; exposure after %s; credit position %s plus the order %s',
             v_ctx ->> 'receivable_minor', v_ctx ->> 'exposure_after_minor', v_cp.exposure_minor,
             erp.document_value_minor(v_o2));

    -- 2. The sales manager is asked about an order over the threshold only.
    perform erp.transition_document(v_o2, 'submit', 'credit control suite');
    select count(*) filter (where t.status <> 'skipped'), min(q.status::text)
      into v_n, v_s
      from erp.approval_request q
      left join erp.approval_task t on t.tenant_id = q.tenant_id and t.approval_request_id = q.id
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_o2;
    v_s2 := erp.transition_document(v_o2, 'approve', 'credit control suite');
    v_o3 := erp.open_document('sales_order', v_c1, null, v_site);
    perform erp.add_document_line(v_o3, v_item, 1, 150000, 'One widget, dearly');
    perform erp.transition_document(v_o3, 'submit', 'credit control suite');
    select string_agg(t.step_code || ':' || t.status, ',' order by t.seq)
      into v_err
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = v_o3 and q.status = 'pending';
    select v.tolerance_pct, v.tolerance_absolute, s.condition
      into v_tol, v_tabs, v_cond
      from erp.approval_chain c
      join erp.approval_chain_version v on v.tenant_id = c.tenant_id and v.approval_chain_id = c.id and v.status = 'active'
      join erp.approval_step s on s.tenant_id = v.tenant_id and s.approval_chain_version_id = v.id and s.code = 'sales_manager'
     where c.tenant_id = r.tenant_id and c.code = 'sales_order_terms';
    perform erp_test.approve_document(v_o3, 'credit control suite');
    return query select 'an order worth no more than 1,000.00 asks nobody and is approved by whoever submitted it; one worth more asks the sales manager; the chain carries its tolerance',
      v_n = 0 and v_s = 'approved' and v_s2 = 'confirmed'
      and v_err like 'sales_manager:pending%'
      and v_tol = 2 and v_tabs = 10000
      and v_cond = jsonb_build_object('>', jsonb_build_array(jsonb_build_object('var','total_minor'), 100000)),
      format('under: %s task(s) asked, request %s, order %s; over: %s; tolerance %s%% / %s; condition %s',
             v_n, v_s, v_s2, v_err, v_tol, v_tabs, v_cond);

    -- 3. Credit approved with the order is not asked for again at fulfilment.
    v_o4 := erp.open_document('sales_order', v_c1, null, v_site);
    v_o4l := erp.add_document_line(v_o4, v_item, 3, 110000, 'Three widgets over the limit');
    perform erp.transition_document(v_o4, 'submit', 'credit control suite');
    perform erp_test.approve_document(v_o4, 'credit control suite');
    select (q.context ->> 'exposure_after_minor')::bigint into v_seen
      from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_id = v_o4 and q.status = 'approved'
     order by q.decided_at desc limit 1;
    select * into v_cp from erp.credit_position(v_c1);
    v_says := erp.check_release_to_fulfilment(v_o4);
    begin
      v_dn4 := (erp.create_delivery_from_order(
        v_o4, jsonb_build_array(jsonb_build_object('line_id', v_o4l, 'quantity', 1))) ->> 'document_id')::uuid;
      perform erp.transition_document(v_dn4, 'post', 'credit control suite');
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      v_inv := erp.invoice_from_delivery(v_dn4);
      perform erp.transition_document(v_inv, 'issue', 'credit control suite');
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      v_billed := erp.check_release_to_fulfilment(v_o4);
    exception when others then v_err := left(sqlerrm, 200); end;
    return query select 'an order whose credit step was approved is delivered without a release, held as it is, and billing what it delivered, tax and all, does not use its tolerance up',
      v_cp.on_hold and v_says = 'approved' and v_dn4 is not null and v_billed = 'approved'
      and exists (select 1 from erp.approval_task t
                    join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
                   where q.tenant_id = r.tenant_id and q.object_id = v_o4
                     and t.step_code = 'credit' and t.status = 'approved')
      and not (select d.attributes ? 'credit_released_by' from erp.document d where d.id = v_o4),
      format('on hold %s (%s, exposure %s, approved at %s); says %s; delivery %s; once billed %s',
             v_cp.on_hold, v_cp.reason, v_cp.exposure_minor, v_seen, v_says, coalesce(v_dn4::text, v_err),
             coalesce(v_billed, v_err));

    -- 4. An order approved before that credit step, with nothing asked about
    --    credit, is carried by it: the approver read it. Other orders billed
    --    add their tax to what is owed; within the five per cent the policy
    --    allows the approval stands, beyond it the order is held by name and
    --    a release lets it go.
    v_cover := erp.check_release_to_fulfilment(v_o2);
    v_dn := (erp.create_delivery_from_order(v_o2) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'credit control suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_inv := erp.invoice_from_delivery(v_dn);
    perform erp.transition_document(v_inv, 'issue', 'credit control suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_says2 := erp.check_release_to_fulfilment(v_o4);
    v_dn := (erp.create_delivery_from_order(v_o3) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'credit control suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_inv := erp.invoice_from_delivery(v_dn);
    perform erp.transition_document(v_inv, 'issue', 'credit control suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select * into v_cp from erp.credit_position(v_c1);
    begin
      v_says3 := erp.check_release_to_fulfilment(v_o4);
    exception when others then v_err2 := left(sqlerrm, 300); end;
    perform erp.release_credit_hold(v_o4, 'the director agreed the rest on the phone');
    v_says4 := erp.check_release_to_fulfilment(v_o4);
    return query select 'a later credit approval carries an order it read; within the five per cent the credit policy allows the approval stands, beyond it the order is held by name, and a release lets it go',
      v_cover = 'approved'
      and v_says2 = 'approved' and v_says3 is null
      and v_err2 like 'CLOVEERP_CREDIT_HOLD:%over their credit limit of%beyond the%approved with the order%'
      and v_cp.exposure_minor > round(v_seen * 1.05)
      and v_says4 = 'released',
      format('earlier order %s; approved at %s, now %s; within: %s; beyond: %s; released: %s',
             v_cover, v_seen, v_cp.exposure_minor, v_says2, coalesce(v_says3, v_err2), v_says4);

    -- 5. A limit cut since, or a customer put on hold, is not carried by the
    --    approval.
    v_o8 := erp.open_document('sales_order', v_c2, null, v_site);
    perform erp.add_document_line(v_o8, v_item, 1, 150000, 'One widget over the second limit');
    perform erp.transition_document(v_o8, 'submit', 'credit control suite');
    perform erp_test.approve_document(v_o8, 'credit control suite');
    v_says := erp.check_release_to_fulfilment(v_o8);
    update erp.party_role_terms set credit_limit_minor = 90000
     where tenant_id = r.tenant_id and party_role_id = v_role2;
    v_err := null;
    begin
      perform erp.check_release_to_fulfilment(v_o8);
    exception when others then v_err := left(sqlerrm, 300); end;
    update erp.party_role_terms set credit_limit_minor = 100000, is_blocked = true, block_reason = 'Disputed invoices'
     where tenant_id = r.tenant_id and party_role_id = v_role2;
    v_err2 := null;
    begin
      perform erp.check_release_to_fulfilment(v_o8);
    exception when others then v_err2 := left(sqlerrm, 300); end;
    update erp.party_role_terms set is_blocked = false, block_reason = null
     where tenant_id = r.tenant_id and party_role_id = v_role2;
    v_says5 := erp.check_release_to_fulfilment(v_o8);
    return query select 'the approval does not carry an order past a limit cut since it was given, nor past a hold, and stands again once they are undone',
      v_says = 'approved'
      and v_err like 'CLOVEERP_CREDIT_HOLD:%beyond the%approved with the order at a limit of 1,000.00%'
      and v_err2 like 'CLOVEERP_CREDIT_HOLD:%on credit hold (Disputed invoices)%'
      and v_says5 = 'approved',
      format('%s; limit cut: %s; on hold: %s; undone: %s', v_says, v_err, v_err2, v_says5);

    -- 6. An order approved while it was within its limit has no credit
    --    approval to carry it.
    v_o9 := erp.open_document('sales_order', v_c3, null, v_site);
    perform erp.add_document_line(v_o9, v_item, 1, 50000, 'One widget for a new account');
    perform erp.transition_document(v_o9, 'submit', 'credit control suite');
    perform erp_test.approve_document(v_o9, 'credit control suite');
    insert into erp.party_role_terms (
      tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)
    values (r.tenant_id, v_role3, r.entity_id, v_ccy, 10000, 'watch', false, current_date - 1);
    v_err := null;
    begin
      perform erp.check_release_to_fulfilment(v_o9);
    exception when others then v_err := left(sqlerrm, 300); end;
    return query select 'an order approved while nothing was asked about credit is held once its customer is over a limit',
      v_err like 'CLOVEERP_CREDIT_HOLD:%over their credit limit of 100.00'
      and not exists (select 1 from erp.approval_task t
                        join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
                       where q.tenant_id = r.tenant_id and q.object_id = v_o9
                         and t.step_code = 'credit' and t.status = 'approved'),
      coalesce(v_err, 'released');

    -- 7. Approve is not drawn for a discount step its holder may not give.
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    insert into erp.role (tenant_id, code, name, status) values
      (r.tenant_id, 'zz_ccs_delegate', 'Suite delegate', 'active'),
      (r.tenant_id, 'zz_ccs_discounts', 'Suite discount approver', 'active'),
      (r.tenant_id, 'zz_ccs_credit', 'Suite credit approver', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select r.tenant_id, ro.id, x.perm
      from (values ('zz_ccs_delegate', 'sales.read'), ('zz_ccs_delegate', 'sales.order'),
                   ('zz_ccs_discounts', 'sales.discount_approve'),
                   ('zz_ccs_credit', 'sales.credit_release')) as x(role_code, perm)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;
    perform erp_test.close_bootstrap_window(r.tenant_id);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_deleg, 'person', 'active', 'Dee Delegate', 'dee@zz-ccs-' || v_hex || '.test', 'en')
    returning id into u_deleg;
    perform erp.grant_role(u_deleg, 'zz_ccs_delegate', null, null, 'takes sales orders');
    insert into erp.approval_delegation (tenant_id, from_user_id, to_user_id, reason)
    values (r.tenant_id, v_second, u_deleg, 'Away this week');
    v_o10 := erp.open_document('sales_order', v_c4, null, v_site);
    perform erp.add_document_line(v_o10, v_item, 1, 5000, 'One widget at a fifth off');
    update erp.document_line set discount_pct = 20 where tenant_id = r.tenant_id and document_id = v_o10;
    perform erp.transition_document(v_o10, 'submit', 'credit control suite');
    perform set_config('request.jwt.claims', json_build_object('sub', s_deleg)::text, true);
    v_ref := erp.transition_refusal(v_o10, 'approve');
    select e into v_offered
      from jsonb_array_elements(public.erp_available_transitions(v_o10)) e
     where e ->> 'code' = 'approve';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.grant_role(u_deleg, 'zz_ccs_discounts', null, null, 'may approve discounts');
    perform set_config('request.jwt.claims', json_build_object('sub', s_deleg)::text, true);
    v_ref2 := erp.transition_refusal(v_o10, 'approve');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select string_agg(t.step_code || ':' || t.status, ',' order by t.seq) into v_s
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = v_o10 and q.status = 'pending'
       and t.assignee_user_id = u_deleg;
    -- The same person holds the manager's step of an order past the limit;
    -- pressing would go on to its credit step, which is theirs too.
    v_o11 := erp.open_document('sales_order', v_c1, null, v_site);
    perform erp.add_document_line(v_o11, v_item, 1, 150000, 'One widget, dearly, over the limit');
    perform erp.transition_document(v_o11, 'submit', 'credit control suite');
    perform set_config('request.jwt.claims', json_build_object('sub', s_deleg)::text, true);
    v_ref3 := erp.transition_refusal(v_o11, 'approve');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.grant_role(u_deleg, 'zz_ccs_credit', null, null, 'may release credit');
    perform set_config('request.jwt.claims', json_build_object('sub', s_deleg)::text, true);
    v_ref4 := erp.transition_refusal(v_o11, 'approve');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'the holder of the manager''s step whose press would go on to a credit step they may not give is told so before pressing, and offered Approve once they may',
      v_ref3 = 'CLOVEERP_PERMISSION_DENIED' and v_ref4 is null
      and exists (select 1 from erp.approval_task t
                    join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
                   where q.tenant_id = r.tenant_id and q.object_id = v_o11 and q.status = 'pending'
                     and t.step_code = 'sales_manager' and t.status = 'pending' and t.assignee_user_id = u_deleg),
      format('before %s; after %s', coalesce(v_ref3, 'nothing'), coalesce(v_ref4, 'nothing'));

    return query select 'the holder of a discount step who may not approve discounts is told so instead of offered Approve, and offered it once they may',
      v_ref = 'CLOVEERP_PERMISSION_DENIED' and v_offered ->> 'refused' = 'CLOVEERP_PERMISSION_DENIED'
      and (v_offered ->> 'permitted')::boolean
      and v_ref2 is null and v_s like '%discount:pending%',
      format('before %s (offered %s); after %s; tasks %s', v_ref, v_offered, coalesce(v_ref2, 'nothing'), v_s);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-ccs-' || v_hex);
  detail := 'the organisation, its customers, orders, deliveries, invoices and approvals rolled back';
  return next;
end;
$function$;

create or replace function erp_test.assert_credit_control_suite()
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
    from erp_test.credit_control_suite() s;
  if v_total <> 9 then
    raise exception 'CLOVEERP_CREDIT_CONTROL_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CREDIT_CONTROL_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Credit asked for twice, or let through once too often, is the case that failed. Read it.';
  end if;
end;
$$;
-- ─────────────────────────────────────────────────────────────────────────────
-- B. The suites that asserted what this changes
--
-- erp_test.last_open_items_suite() proved the double approval: its order past
-- the limit was approved with its credit step and then held at picking for
-- the same excess. The limit is now cut after the approval, so what is held
-- is what the approver never saw; and its two small discounted
-- orders are priced over the sales manager's threshold, so the manager is
-- still the first step they meet. erp_test.sales_suite() decided "the first
-- task" meaning the manager's, which an order under the threshold no longer
-- has.
-- ─────────────────────────────────────────────────────────────────────────────

do $suites$
declare
  v_sig text;
  v_def text;
  v_old text;
  v_new text;
  v_hits integer;
  v_pairs text[][];
  i integer;
begin
  -- last_open_items_suite
  v_sig := 'erp_test.last_open_items_suite()';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_pairs := array[
    array[$o$    v_alloc_a := erp.reserve_for_line(v_so_a_line);
$o$, $n$    -- The limit is cut after the credit was approved with the order
    -- (20260923900000): the approval does not carry the order past a limit
    -- the approver never saw, so it is held at fulfilment for that.
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_c1, 'limit', 400000, 'on_hold', false,
                         'reason', 'Limit reviewed after the order was approved.'));
    if g.err_message is not null then
      raise exception 'the limit could not be reviewed: %', g.err_message;
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_alloc_a := erp.reserve_for_line(v_so_a_line);
$n$],
    array[$o$    perform erp.add_document_line(v_so_f, v_item, 1, 1000, 'One widget at a fifth off');$o$,
          $n$    perform erp.add_document_line(v_so_f, v_item, 1, 200000, 'One widget at a fifth off');$n$]];
  for i in 1 .. array_length(v_pairs, 1) loop
    v_old := v_pairs[i][1]; v_new := v_pairs[i][2];
    v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, i, v_hits;
    end if;
    v_def := replace(v_def, v_old, v_new);
  end loop;
  execute v_def;

  -- sales_suite
  v_sig := 'erp_test.sales_suite()';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_old := $o$            where q.object_id = v_so and tk.status='pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'a discount above the threshold opens the discount step',$o$;
  v_new := $n$            where q.object_id = v_so and tk.status='pending'
              and tk.step_code = 'sales_manager'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'a discount above the threshold opens the discount step',$n$;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % manager step anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);

end
$suites$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The words the page says instead of Approve, for a step the holder may
--    not give (src/components/erp/available-transitions.ts)
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). ' || v.why
  from (values
    ('This step is for somebody who may approve discounts or release credit.',
     'Said on a sales order instead of Approve, when the step waiting on the person is a discount or credit step they may not give (20260923900000).')
  ) as v(text, why)
on conflict (key, locale) do nothing;

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
