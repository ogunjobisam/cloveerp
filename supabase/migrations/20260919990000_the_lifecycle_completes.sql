-- =============================================================================
-- The lifecycle completes
--
-- A sales order could not finish. It was submitted, approved, picked,
-- despatched — and then it stopped. `sales_order.invoice` moves it from
-- Despatched to Invoiced, `sales_order.close` moves it from Invoiced to Closed,
-- and in the product nothing ever performed the first of those, so the second
-- had no state to fire from. Every order the product has ever raised is sitting
-- in Despatched, delivered and billed and paid, because the move that says so
-- was declared and never wired.
--
-- Four transitions were reported as undriven. Three of the four reports were
-- wrong, and the way they were wrong is the useful part.
--
--   sales_order.invoice    UNDRIVEN. It is on DOOR_ONLY_TRANSITIONS in
--                          src/components/erp/available-transitions.ts, so the
--                          screens deliberately do not draw a button for it —
--                          "a sales order is invoiced because an invoice was
--                          raised", and the door named there is "Invoice a
--                          delivery". erp.invoice_from_delivery() raises the
--                          invoice, links it to the despatch, and never touches
--                          the order. No screen offers it and no routine
--                          performs it. This is the defect.
--
--   sales_order.close      DRIVEN, and unreachable, which is not the same
--                          thing. It is not door-only, so the document page
--                          draws "Close" on any order in Invoiced for anybody
--                          holding sales.order. There has never been an order
--                          in Invoiced.
--
--   purchase_order.close   DRIVEN. Not door-only either, and Received is
--                          reachable: erp.advance_orders_for_receipt() has
--                          moved orders there since 20260910165931. The button
--                          is drawn and it works. Nothing here changes it.
--
--   sales_invoice.credit   DRIVEN, BADLY. Not door-only, so the page draws a
--                          bare "Credit" button beside the credit note door
--                          that shipped on 18 September. Pressing it moves the
--                          invoice to Credited — a terminal state — with no
--                          credit note, no reversing journal, no goods back on
--                          the shelf and nothing owed back to the customer. It
--                          is exactly the failure the door-only list was
--                          written to prevent: "pressed as a bare move, each
--                          would say so with nothing behind it".
--                          erp.raise_customer_credit_note() writes the
--                          'credits' relation and leaves the invoice Issued, so
--                          the move that is honest is also the one nothing
--                          makes.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Why the demonstration month hid it
--
-- erp.seed_demo_history() performs all four by hand:
--
--     perform erp.transition_document(v_doc, 'invoice', 'demonstration');
--     perform erp.transition_document(ln.so_id, 'close', 'demonstration');
--
-- so the demonstration month shows orders that reach Invoiced and Closed while
-- the product cannot put one there. A builder that drives a transition the
-- product does not drive is a fixture, not evidence, and it is the reason a
-- broken chain looked finished on every screen anybody opened. The check this
-- migration adds therefore does not count the demonstration builders as
-- drivers; neither does it count the suites.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What drives the two that were not driven
--
-- The pattern is already in the repository, twice. A receipt posting advances
-- the purchase order it was received against (erp.advance_orders_for_receipt,
-- 20260910165931); a delivery posting advances the sales order it fulfils
-- (erp.advance_orders_for_delivery, 20260914064000). Both are called from
-- erp.transition_document() when the document that moved reaches a committed
-- state, and both leave an order that cannot move where it stands.
--
-- Two more of the same shape:
--
--   erp.advance_orders_for_invoice()          an invoice issuing moves the
--                                             orders it billed to Invoiced,
--                                             once every despatch of the order
--                                             has been invoiced
--
--   erp.credit_invoices_for_credit_note()     a credit note issuing moves the
--                                             invoice it reverses to Credited,
--                                             once every quantity that invoice
--                                             billed has come back
--
-- "Once every quantity has come back" is counted in quantities and not in
-- money, deliberately. The links are already there and they are exact:
-- erp.invoice_from_delivery() writes one 'invoices' relation per invoice line
-- carrying the quantity billed against a despatch line, and
-- erp.raise_customer_credit_note() writes one 'returns' relation per credit
-- line carrying the quantity coming back against the same despatch line. The
-- arithmetic is the one CLOVEERP_CREDIT_EXCEEDS_WHAT_WENT_OUT already does.
-- Comparing values instead would have to decide what tax, rounding and
-- settlement discount do to the comparison, and a partial credit would settle
-- an invoice whenever the prices happened to agree.
--
-- A partial credit therefore leaves the invoice Issued, which is right: the
-- customer still owes the rest of it, and Credited is terminal.
--
-- And `credit` joins the door-only list, so the page no longer draws a bare
-- Credit button. It already draws "Credit this invoice"
-- (erp_raise_customer_credit_note) on every committed sales invoice, which is
-- the same act with a document behind it.
--
-- sales_order.close and purchase_order.close stay buttons a person presses.
-- Closing an order is a judgement — an order may be closed short, or left open
-- because another despatch is expected — and neither of them was ever the
-- defect. What was broken about the sales one is that it could not be pressed,
-- and that is fixed by the state in front of it becoming reachable.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The check whose absence let four of these be argued about
--
-- Nothing in the build could say whether a declared transition can fire.
-- erp.dead_configuration_report() asks whether a transition declares effects
-- nothing executes; nothing asked whether the transition itself is executed by
-- anything. So erp.assert_every_transition_is_driven(), over
-- erp.undriven_transition_report(), which refuses seven findings:
--
--   1  a lifecycle the register does not name at all
--   2  a declared transition the register does not name
--   3  a register row naming a routine that does not exist
--   4  a register row naming a routine that performs no transition
--   5  a register row for a transition its lifecycle does not declare
--   6  an allowance with no reason written on it
--   7  a transition whose from-state nothing can reach
--
-- Finding 7 is the one that would have caught sales_order.close without anybody
-- arguing about what "driven" means: Closed is reached from Invoiced, Invoiced
-- is reached by `invoice`, and `invoice` is on the door-only list with no door.
--
-- The register (erp.transition_driver_register) says, for every transition of
-- every lifecycle this repository ships, what fires it:
--
--   'screen'    the document page draws a button for it. True for every
--               transition the screens do NOT leave to a door, because
--               erp_available_transitions returns every transition of the
--               current state and DocumentTransitions draws all of them.
--   'routine'   the screens leave it to a door or a mechanism, named here with
--               its signature, and the check confirms the routine exists and
--               performs transitions.
--   'undriven'  the named, justified register. Empty today, and kept.
--
-- The allowance list is empty, and the way it emptied is worth writing down.
-- This file was drafted with one row on it: sales_invoice.settle, because
-- erp.apply_cash() applied money to open items and left the invoice Issued, and
-- only the demonstration moved it, by hand, the same way it did the other four.
-- 20260919200000 landed while this was in review and made cash settle what it
-- pays, through erp.settle_paid_document(). The finding was real, it was
-- answered, and the register follows it rather than keeping a reason that has
-- stopped being true.
--
-- The same change is why 'routine' names the routine that PERFORMS the move and
-- not the door a person presses. erp.pay_payment_run() drove purchase_invoice's
-- `pay` directly when this was written; it now delegates to
-- erp.settle_paid_document(), and the first build after 20260919200000 landed
-- refused with
--
--     a registered driver that performs no transition — purchase_invoice.pay
--
-- which is finding 4 doing its job on its first day, against a change nobody
-- had told it about. A register that named the door would have stayed quietly
-- green while the door stopped driving anything. The performer is the only end
-- of that chain the database can check, so the performer is what is named.
--
-- The 'routine'/'screen' split is mirrored in DOOR_ONLY_TRANSITIONS, and
-- src/lib/stage-records.test.ts reads this file to prove the two agree — the
-- same way it already reads the spine to prove each door-only code exists.
--
-- Scope: document lifecycles. Every state machine this repository ships has
-- object_type 'document'; a lifecycle an organisation writes for itself is its
-- own business and the check does not read one.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does not claim
--
-- The check reads what a lifecycle declares and what the register says. It
-- cannot tell that a driver named for a transition really performs THAT
-- transition rather than some other one — erp.advance_orders_for_delivery()
-- computes the codes it performs from the database and names neither `pick` nor
-- `despatch` in its own text, which is why the register names routines rather
-- than scraping them. What it does close is the case that produced all four
-- reports: a transition with no button and no routine at all, and a state
-- nothing can reach.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The one move from here to there
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Read from the version the document runs under, as erp.perform_transition
-- reads it, because an organisation may have promoted a lifecycle whose move to
-- Invoiced is not called `invoice`.
--
-- One move, never a path of two. erp.advance_orders_for_delivery() walks two
-- because Despatched really is two moves from Confirmed and a delivery posting
-- is evidence of both. Neither of the moves here is like that: the state a
-- document must already be in IS the guard. An order at Picking is one hop and
-- then another from Invoiced, and walking it would despatch an order because
-- somebody billed a part delivery; an invoice still in Draft is one hop and
-- then another from Credited, and walking it would ISSUE an invoice because a
-- credit note was raised against it. Performing somebody else's move on the way
-- to your own is the defect this migration exists to remove, not a shortcut to
-- take while removing it.
--
-- Automatic transitions are the machine's own and are never returned.

create or replace function erp.transition_code_to(
  p_document_id uuid,
  p_to_state    text
) returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select t.code
    from erp.object_state os
    join erp.transition t
      on t.tenant_id = os.tenant_id
     and t.state_machine_version_id = os.state_machine_version_id
     and t.from_state_id = os.current_state_id
    join erp.state ts on ts.tenant_id = t.tenant_id and ts.id = t.to_state_id
   where os.tenant_id = erp.require_tenant_id()
     and os.object_type = 'document'
     and os.object_id = p_document_id
     and ts.code = p_to_state
     and not t.is_automatic
   order by t.sort_order, t.code
   limit 1
$$;

comment on function erp.transition_code_to(uuid, text) is
  'The single move this document''s own lifecycle declares from where it stands '
  'to the named state, read from the version the document runs under. Null when '
  'there is no such move — including when the state is two moves away, because '
  'a mechanism that performs somebody else''s move on the way to its own is the '
  'thing this file exists to stop.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The other end of a relation
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.document_relation is one row read either way — 0025 says so where the
-- table is declared, and means it: "navigable in both directions. One row, read
-- either way — because two rows per link is how a lineage graph ends up
-- asymmetric." The writers do not all agree on which end is which.
-- erp.create_delivery_from_order() writes the despatch as the FROM of 'fulfils'
-- and the order as the TO; erp.seed_demo_history() has written the order as the
-- FROM since 20260905010000. Both are the same link and both are correct under
-- the invariant; a reader that only looks one way sees half the documents in
-- this database and nothing says so.

create or replace function erp.related_documents(
  p_document_id uuid,
  p_kind        erp.document_relation_kind
) returns setof uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select distinct case when r.from_document_id = p_document_id
                       then r.to_document_id
                       else r.from_document_id end
    from erp.document_relation r
   where r.tenant_id = erp.require_tenant_id()
     and r.relation_kind = p_kind
     and (r.from_document_id = p_document_id or r.to_document_id = p_document_id)
     and r.from_document_id is not null
     and r.to_document_id is not null
$$;

comment on function erp.related_documents(uuid, erp.document_relation_kind) is
  'The documents at the other end of a relation of this kind, whichever end of '
  'the row this document is on. erp.document_relation is one row read either '
  'way (0025) and its writers do not all put the same document first.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. An invoice issuing moves the orders it billed
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.advance_orders_for_invoice(p_invoice_id uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_number text;
  r        record;
  v_open   boolean;
  v_step   text;
  v_moved  integer := 0;
begin
  select d.document_number into v_number
    from erp.document d
   where d.tenant_id = v_tenant and d.id = p_invoice_id;

  for r in
    select distinct od.id as order_id
      from erp.related_documents(p_invoice_id, 'invoices') as billed(delivery_id)
      join erp.document dn on dn.tenant_id = v_tenant and dn.id = billed.delivery_id
      join erp.document_type dnt
        on dnt.tenant_id = dn.tenant_id and dnt.id = dn.document_type_id
      cross join lateral erp.related_documents(dn.id, 'fulfils') as fulfilled(order_id)
      join erp.document od on od.tenant_id = v_tenant and od.id = fulfilled.order_id
      join erp.document_type odt
        on odt.tenant_id = od.tenant_id and odt.id = od.document_type_id
     where dnt.base_type_code = 'delivery'
       and odt.base_type_code = 'sales_order'
       and not od.is_cancelled
  loop
    -- Every despatch of this order has to have been billed. One that has not
    -- leaves the order where it is: it is still waiting to be invoiced, and
    -- saying otherwise would be this same defect in the other direction.
    select exists (
      select 1
        from erp.related_documents(r.order_id, 'fulfils') as f(delivery_id)
        join erp.document dn on dn.tenant_id = v_tenant and dn.id = f.delivery_id
        join erp.document_type dnt
          on dnt.tenant_id = dn.tenant_id and dnt.id = dn.document_type_id
       where dnt.base_type_code = 'delivery'
         and not dn.is_cancelled
         and not exists (
           select 1
             from erp.related_documents(dn.id, 'invoices') as b(invoice_id)
             join erp.document iv on iv.tenant_id = v_tenant and iv.id = b.invoice_id
             join erp.document_type it
               on it.tenant_id = iv.tenant_id and it.id = iv.document_type_id
            where it.base_type_code = 'invoice_reference'
              and not iv.is_cancelled))
      into v_open;

    if coalesce(v_open, true) then
      continue;
    end if;

    v_step := erp.transition_code_to(r.order_id, 'invoiced');
    if v_step is null then
      continue;
    end if;

    -- The invoice is already issued. An order that cannot move — a guard, a
    -- permission, an approval — is worth recording and is not worth undoing an
    -- invoice for, which is how erp.advance_orders_for_receipt() has treated
    -- the same case since 20260910165931.
    begin
      perform erp.transition_document(r.order_id, v_step,
                                      format('Invoiced in full by %s', v_number));
      v_moved := v_moved + 1;
    exception when others then
      perform erp.append_event(
        'document.progress_not_advanced', 'document', r.order_id,
        jsonb_build_object('transition', 'invoice', 'reason', sqlerrm,
                           'invoice_id', p_invoice_id),
        null, null);
    end;
  end loop;

  return v_moved;
end;
$$;

comment on function erp.advance_orders_for_invoice(uuid) is
  'Called when an invoice reaches a committed state. Moves each sales order the '
  'invoice billed — through the despatch it invoices and the order that despatch '
  'fulfils — to Invoiced, by the moves that order''s own lifecycle declares from '
  'where it stands. An order with a despatch nobody has billed, or one that '
  'cannot move, is left where it is.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A credit note issuing credits the invoice it reverses
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The credit note's lines name the despatch lines the goods are coming back
-- from ('returns'); the invoice's lines name the same despatch lines they
-- billed ('invoices'). So an invoice is fully credited when no line it billed
-- has a quantity still out, which is the arithmetic
-- erp.raise_customer_credit_note() already refuses on. Both of those links are
-- written by exactly one routine each, in one direction each, which is why
-- these read the rows as they are written rather than through
-- erp.related_documents().

create or replace function erp.credit_invoices_for_credit_note(p_credit_note_id uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_number text;
  r        record;
  v_out    boolean;
  v_step   text;
  v_moved  integer := 0;
begin
  select d.document_number into v_number
    from erp.document d
   where d.tenant_id = v_tenant and d.id = p_credit_note_id;

  for r in
    select distinct il.document_id as invoice_id
      from erp.document_relation cn
      join erp.document_relation inv
        on inv.tenant_id = cn.tenant_id
       and inv.to_line_id = cn.to_line_id
       and inv.relation_kind = 'invoices'
      join erp.document_line il
        on il.tenant_id = inv.tenant_id and il.id = inv.from_line_id
      join erp.document iv on iv.tenant_id = il.tenant_id and iv.id = il.document_id
      join erp.document_type it on it.tenant_id = iv.tenant_id and it.id = iv.document_type_id
     where cn.tenant_id = v_tenant
       and cn.from_document_id = p_credit_note_id
       and cn.relation_kind = 'returns'
       and cn.to_line_id is not null
       and it.base_type_code = 'invoice_reference'
       and not iv.is_cancelled
  loop
    -- Anything this invoice billed that has not all come back.
    select exists (
      select 1
        from erp.document_relation inv
        join erp.document_line il
          on il.tenant_id = inv.tenant_id and il.id = inv.from_line_id
       where inv.tenant_id = v_tenant
         and inv.relation_kind = 'invoices'
         and il.document_id = r.invoice_id
         and coalesce(inv.quantity, 0) > coalesce((
               select sum(rr.quantity)
                 from erp.document_relation rr
                 join erp.document cd on cd.tenant_id = rr.tenant_id and cd.id = rr.from_document_id
                where rr.tenant_id = v_tenant
                  and rr.to_line_id = inv.to_line_id
                  and rr.relation_kind = 'returns'
                  and not cd.is_cancelled), 0))
      into v_out;

    if coalesce(v_out, true) then
      continue;
    end if;

    v_step := erp.transition_code_to(r.invoice_id, 'credited');
    if v_step is null then
      continue;
    end if;

    begin
      perform erp.transition_document(r.invoice_id, v_step,
                                      format('Credited in full by %s', v_number));
      v_moved := v_moved + 1;
    exception when others then
      perform erp.append_event(
        'document.progress_not_advanced', 'document', r.invoice_id,
        jsonb_build_object('transition', 'credit', 'reason', sqlerrm,
                           'credit_note_id', p_credit_note_id),
        null, null);
    end;
  end loop;

  return v_moved;
end;
$$;

comment on function erp.credit_invoices_for_credit_note(uuid) is
  'Called when a credit note reaches a committed state. Moves an invoice to '
  'Credited once every quantity it billed has come back on a credit note, '
  'counted through the despatch lines both documents name. A partial credit '
  'leaves the invoice Issued, because the customer still owes the rest and '
  'Credited is terminal.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Both hung on the transition, where the other two already hang
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Deployed body, asserted needle. erp.transition_document() has been patched
-- five times since 20260829200000 defined it whole — the declared approval
-- effect (20260906100000), the approval hold (20260914062000), the receipt
-- advance (20260910165931), the delivery advance (20260914064000) and the two
-- base types the stock bridge holds off for (20260917130000, 20260918810000).
-- Re-emitting it from any file would drop every one of them, so the delivery
-- advance is the needle and all five are asserted still present afterwards.
--
-- Both bases are 'invoice_reference' and 'credit_reference', which the purchase
-- side shares with the sales side. That costs nothing: a purchase invoice
-- reaches no despatch that fulfils a sales order, and a supplier credit note
-- reaches no invoice whose lifecycle declares Credited, so
-- erp.transition_code_to() returns null and both routines do nothing. Naming
-- the document TYPE instead would be a second place for the sales side's list
-- of type codes to live.

do $bridge$
declare
  v_sig text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  v_old text := $p$  if coalesce(v_committed, false) and dt.base_type_code = 'delivery' then
    perform erp.advance_orders_for_delivery(p_document_id);
  end if;
$p$;
  v_new text := $q$  if coalesce(v_committed, false) and dt.base_type_code = 'delivery' then
    perform erp.advance_orders_for_delivery(p_document_id);
  end if;

  -- A sales order invoiced in full should not still read "Despatched"
  -- (20260919900000). Only an invoice raised from the despatch carries the line
  -- links this follows; any other invoice moves nothing.
  if coalesce(v_committed, false) and dt.base_type_code = 'invoice_reference' then
    perform erp.advance_orders_for_invoice(p_document_id);
  end if;

  -- An invoice every penny of which has been credited should not still read
  -- "Issued" (20260919900000). A partial credit moves nothing.
  if coalesce(v_committed, false) and dt.base_type_code = 'credit_reference' then
    perform erp.credit_invoices_for_credit_note(p_document_id);
  end if;
$q$;
  v_hits integer;
begin
  if position('erp.advance_orders_for_invoice(' in v_def) > 0
     or position('erp.credit_invoices_for_credit_note(' in v_def) > 0 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: % already advances an order for '
      'its invoice or credits an invoice for its credit note; this migration '
      'would hang both on it twice', v_sig
      using hint = 'The migration has already been applied to this database. Nothing to do.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: expected the delivery advance once '
      'in %, found %', v_sig, v_hits
      using hint = 'erp.transition_document() is not the 20260914064000 body this migration patches. Read pg_get_functiondef and re-cut the needle.';
  end if;

  execute replace(v_def, v_old, v_new);

  -- The five patches this body already carried are still in it.
  v_def := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  if position('erp.transition_declares_effect(' in v_def) = 0
     or position('erp.require_document_approval(' in v_def) = 0
     or position('erp.advance_orders_for_receipt(' in v_def) = 0
     or position('erp.advance_orders_for_delivery(' in v_def) = 0
     or position('''transfer_order'', ''adjustment''' in v_def) = 0
     or position('erp.advance_orders_for_invoice(' in v_def) = 0
     or position('erp.credit_invoices_for_credit_note(' in v_def) = 0 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: the rewrite dropped a patch the '
      'body already had, or did not take'
      using hint = 'Compare pg_get_functiondef with the five needles listed in 20260919900000 before re-running.';
  end if;
end
$bridge$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The demonstration stops doing by hand what the product now does
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.seed_demo_history() has moved the order to Invoiced itself since
-- 20260905010000, on the line after it issued the invoice. That is why a month
-- of demonstration data shows a finished sell side over a product that could
-- not finish one, and it is the reason to take it out rather than leave it as
-- a harmless duplicate: it is not harmless, it is the thing that hid this.
--
-- It would also now fail. Issuing the invoice moves the order, so the hand-
-- driven move that followed would be asked for from Invoiced, where the
-- lifecycle does not have it, and every slice of the month would stop there.
--
-- 20260912190000 did exactly this for the receipt, when posting one started
-- advancing the order it was received against; its comment is still in the
-- body and is asserted below, along with the nine other patches this function
-- carries.
--
-- The Friday customer credit note (20260918220000) credits a quarter of one
-- line, so erp.credit_invoices_for_credit_note() finds quantities still out and
-- leaves that invoice Issued, which is what a part credit should do. The cash
-- loop only settles an invoice that reads Issued, so an invoice this ever does
-- credit is skipped rather than refused.

do $history$
declare
  v_sig  constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def  text := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  v_n    constant text := E'    perform erp.transition_document(v_doc, ''invoice'', ''demonstration'');\n';
  v_r    constant text := E'    -- Issuing the invoice moves the order to Invoiced by itself\n'
                       || E'    -- (20260919900000), as it does in the product. Doing it here by hand\n'
                       || E'    -- is what made a month of demonstration data show a sell side the\n'
                       || E'    -- product could not produce.\n';
  v_hits integer;
  v_secdef boolean;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: expected % to move the order to Invoiced by hand exactly once, found %',
      v_sig, v_hits
      using hint = 'Read pg_get_functiondef(''erp.seed_demo_history(date,date,numeric)'') and re-cut the needle before re-running.';
  end if;

  execute replace(v_def, v_n, v_r);

  -- The hand-driven move is gone and the ten patches the body already carried
  -- are still in it. A re-emission from any file would have dropped every one.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  select p.prosecdef into v_secdef from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure;
  if position(E'transition_document(v_doc, ''invoice''' in v_def) > 0
     or position('0.92 + random()::numeric * 0.16' in v_def) = 0                         -- 20260906050000
     or position('Close only what actually arrived in Received.' in v_def) = 0           -- 20260912190000
     or (length(v_def) - length(replace(v_def, 'erp.approve_my_document_tasks(v_doc, ''demonstration'')', '')))
        / length('erp.approve_my_document_tasks(v_doc, ''demonstration'')') <> 2         -- 20260914062000
     or position('<<days>>' in v_def) = 0                                                -- 20260914072000
     or position('erp.receive_transfer(v_transfer)' in v_def) = 0                        -- 20260918100000
     or position('erp.raise_supplier_credit_note(' in v_def) = 0                         -- 20260918220000
     or position('erp.raise_customer_credit_note(' in v_def) = 0                         -- 20260918220000
     or position('erp.create_receipt_from_order(' in v_def) = 0                          -- 20260918600000
     or position('erp.create_delivery_from_order(' in v_def) = 0                         -- 20260918600000
     or position('erp.post_stock_adjustment(' in v_def) = 0                              -- 20260918810000
     or (length(v_def) - length(replace(v_def, E'  end loop days;\n', ''))) / length(E'  end loop days;\n') <> 1
     or not coalesce(v_secdef, false) then                                               -- 20260914030000
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % dropped a patch it already had, or did not stop driving the order to Invoiced by hand',
      v_sig
      using hint = 'Compare pg_get_functiondef with the markers listed in 20260919900000 before re-running.';
  end if;
end
$history$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. What fires each move
-- ═════════════════════════════════════════════════════════════════════════════
--
-- One row per transition of every document lifecycle this repository ships.
--
--   screen     the document page draws a button for it, because
--              erp_available_transitions() returns every transition of the
--              current state and DocumentTransitions draws all of them that
--              are not on DOOR_ONLY_TRANSITIONS
--   routine    the screens leave it to a door or a mechanism; the detail is
--              that routine's signature, and the check confirms it exists and
--              performs transitions
--   undriven   the named, justified allowance; the detail is the reason
--
-- Every row here that is not 'screen' is a door-only code in
-- src/components/erp/available-transitions.ts, and every door-only code there
-- is a row here that is not 'screen'. src/lib/stage-records.test.ts reads this
-- file and refuses the two lists if they disagree, the same way it already
-- reads the spine to refuse a door-only code no lifecycle declares.

create or replace function erp.transition_driver_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      ('requisition',        'order',                  'screen', ''),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      ('purchase_order',     'receive_rest',           'routine', 'erp.advance_orders_for_receipt(uuid)'),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'screen', ''),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'screen', ''),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'screen', ''),
      ('transfer_order',     'in_transit',             'screen', ''),
      ('transfer_order',     'received',               'screen', ''),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),

      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'screen', ''),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which the inventory installer
      -- now ships identically. None of them is left to a door, so the document
      -- page draws every move each one declares.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
$$;

comment on function erp.transition_driver_register() is
  'What fires each transition of every document lifecycle this repository '
  'ships: a button the document page draws (screen), a door or mechanism named '
  'by signature (routine), or a written-down allowance with its reason '
  '(undriven). Read by erp.undriven_transition_report(); mirrored in '
  'DOOR_ONLY_TRANSITIONS, which src/lib/stage-records.test.ts holds to it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- The report
--
-- p_register exists so the check can be falsified: a suite hands it a register
-- with a row taken out and reads the finding back. Null means the real one.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.undriven_transition_report(p_register jsonb default null)
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with recursive reg as (
    select r.machine_code, r.transition_code, r.driver, r.detail
      from jsonb_to_recordset(coalesce(p_register, erp.transition_driver_register()))
             as r(machine_code text, transition_code text, driver text, detail text)
  ),
  machines as (
    select m.tenant_id, m.code as machine_code, v.id as version_id
      from erp.state_machine m
      join erp.state_machine_version v
        on v.tenant_id = m.tenant_id and v.state_machine_id = m.id
     where m.object_type = 'document'
       and m.status = 'active'
       and v.status = 'active'
  ),
  declared as (
    select mc.machine_code, mc.version_id, t.code as transition_code,
           fs.code as from_state, ts.code as to_state
      from machines mc
      join erp.transition t
        on t.tenant_id = mc.tenant_id and t.state_machine_version_id = mc.version_id
      join erp.state fs on fs.tenant_id = t.tenant_id and fs.id = t.from_state_id
      join erp.state ts on ts.tenant_id = t.tenant_id and ts.id = t.to_state_id
  ),
  live as (
    select distinct d.version_id, d.machine_code, d.transition_code,
           d.from_state, d.to_state
      from declared d
      join reg r on r.machine_code = d.machine_code
                and r.transition_code = d.transition_code
     where r.driver in ('screen', 'routine')
  ),
  -- to_regprocedure() refuses a string that is not a function name at all, and
  -- a screen row's detail is the empty string, so the case guards the call
  -- rather than a where clause the planner is free to evaluate second.
  routine_driver as (
    select r.machine_code, r.transition_code, r.driver, r.detail,
           pg_catalog.to_regprocedure(
             case when r.driver = 'routine' then r.detail
                  else 'pg_catalog.now()' end) as driver_oid
      from reg r
  ),
  reach (version_id, state_code) as (
    select distinct mc.version_id, s.code
      from machines mc
      join erp.state s
        on s.tenant_id = mc.tenant_id and s.state_machine_version_id = mc.version_id
     where s.is_initial
    union
    select l.version_id, l.to_state
      from reach rr
      join live l on l.version_id = rr.version_id and l.from_state = rr.state_code
  )
  -- 1. A lifecycle the register does not name at all.
  select 'a document lifecycle the driver register does not name',
         min(mc.machine_code),
         'Nothing says what fires any of its moves. Add its transitions to '
         'erp.transition_driver_register(), or say there why they are not there.'
    from machines mc
   where not exists (select 1 from reg r where r.machine_code = mc.machine_code)
   group by mc.machine_code

  union all
  -- 2. A declared transition the register does not name.
  select 'a lifecycle transition nothing is registered to fire',
         min(format('%s.%s', d.machine_code, d.transition_code)),
         'Declared, and no button, door or allowance answers for it. Give it a '
         'mechanism, or a row in erp.transition_driver_register() saying which '
         'screen draws it.'
    from declared d
   where exists (select 1 from reg r where r.machine_code = d.machine_code)
     and not exists (select 1 from reg r
                      where r.machine_code = d.machine_code
                        and r.transition_code = d.transition_code)
   group by d.machine_code, d.transition_code

  union all
  -- 3. A register row naming a routine that does not exist.
  select 'a registered driver that does not exist',
         format('%s.%s', rd.machine_code, rd.transition_code),
         format('%s is named as the driver and no such routine exists. A '
                'register naming something renamed away reports green over '
                'nothing.', rd.detail)
    from routine_driver rd
   where rd.driver = 'routine'
     and rd.driver_oid is null

  union all
  -- 4. A register row naming a routine that performs no transition.
  select 'a registered driver that performs no transition',
         format('%s.%s', rd.machine_code, rd.transition_code),
         format('%s exists and its body calls neither erp.transition_document() '
                'nor erp.perform_transition(), so it cannot be what moves this '
                'document.', rd.detail)
    from routine_driver rd
    join pg_catalog.pg_proc p on p.oid = rd.driver_oid
   where rd.driver = 'routine'
     and position('transition_document(' in p.prosrc) = 0
     and position('perform_transition(' in p.prosrc) = 0

  union all
  -- 5. A register row for a transition its lifecycle does not declare.
  select 'a registered transition the lifecycle does not declare',
         format('%s.%s', r.machine_code, r.transition_code),
         'The register has drifted from the lifecycle: the transition was '
         'renamed or removed and its row was left behind.'
    from reg r
   where exists (select 1 from machines mc where mc.machine_code = r.machine_code)
     and not exists (select 1 from declared d
                      where d.machine_code = r.machine_code
                        and d.transition_code = r.transition_code)

  union all
  -- 6. An allowance with no reason written on it.
  select 'an undriven transition with no reason written down',
         format('%s.%s', r.machine_code, r.transition_code),
         'The register allows this one to be driven by nothing and says why '
         'nowhere. An allowance without a reason is a transition nobody '
         'decided about.'
    from reg r
   where r.driver = 'undriven'
     and coalesce(btrim(r.detail), '') = ''

  union all
  -- 7. A transition whose from-state nothing can reach.
  select 'a lifecycle transition nothing can reach',
         min(format('%s.%s', l.machine_code, l.transition_code)),
         format('It moves a document out of "%s", and no sequence of moves '
                'anything drives arrives there. Whatever should put a document '
                'in that state is the thing that is missing.', min(l.from_state))
    from live l
   where not exists (select 1 from reach rr
                      where rr.version_id = l.version_id
                        and rr.state_code = l.from_state)
   group by l.machine_code, l.transition_code

  union all
  -- 8. A register row for a driver that is neither of the three words.
  select 'a driver register row that says nothing known',
         format('%s.%s', r.machine_code, r.transition_code),
         format('driver is "%s"; it must be screen, routine or undriven.',
                coalesce(r.driver, 'null'))
    from reg r
   where coalesce(r.driver, '') not in ('screen', 'routine', 'undriven')
$$;

comment on function erp.undriven_transition_report(jsonb) is
  'Every document lifecycle transition that nothing can fire, every driver the '
  'register names and the database does not have, every register row the '
  'lifecycles have left behind, and every transition whose from-state no '
  'sequence of driven moves reaches. p_register overrides the register, so the '
  'check can be falsified against one with a row taken out.';

create or replace function erp.assert_every_transition_is_driven()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count   integer;
  v_detail  text;
  v_moves   integer;
  v_cycles  integer;
  v_allowed integer;
begin
  select count(*), string_agg(format('  %s — %s: %s', r.finding, r.reference, r.detail),
                              E'\n' order by r.reference, r.finding)
    into v_count, v_detail
    from erp.undriven_transition_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_TRANSITION_NOT_DRIVEN: % finding(s)\n%', v_count, v_detail
      using errcode = 'P0001',
            hint = 'Drive the transition — a mechanism on the document that '
                   'completes it, a door, or a screen action — and name what '
                   'drives it in erp.transition_driver_register(). A move that '
                   'must stay undriven takes a row there saying why. Removing '
                   'the transition from the lifecycle is the other honest answer.';
  end if;

  select count(distinct m.code),
         count(distinct (m.code, t.code)),
         count(distinct (m.code, t.code)) filter (where r.driver = 'undriven')
    into v_cycles, v_moves, v_allowed
    from erp.state_machine m
    join erp.state_machine_version v
      on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
    join erp.transition t
      on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id
    left join jsonb_to_recordset(erp.transition_driver_register())
           as r(machine_code text, transition_code text, driver text, detail text)
      on r.machine_code = m.code and r.transition_code = t.code
   where m.object_type = 'document'
     and m.status = 'active';

  return format('lifecycles: %s transition(s) across %s document lifecycle(s), '
                'each one fired by a screen or a routine; %s allowed to be '
                'driven by nothing, each with its reason',
                v_moves, v_cycles, v_allowed);
end;
$$;

comment on function erp.assert_every_transition_is_driven is
  'Every transition a document lifecycle declares is fired by something: a '
  'button the document page draws, a door or mechanism named in '
  'erp.transition_driver_register(), or a written-down allowance. Also refuses '
  'a driver the database does not have, a register row the lifecycles no longer '
  'declare, and a transition whose from-state no sequence of driven moves '
  'reaches — which is what sales_order.close was for as long as nothing '
  'invoiced an order.';

revoke all on function erp.assert_every_transition_is_driven() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('every_transition_is_driven', 'Every lifecycle transition is fired by something',
   'assertion', 'platform', 'erp', 'assert_every_transition_is_driven', '',
   'undriven_transition_report', '',
   'A document lifecycle can declare a move that nothing performs. Four did: a sales order could be invoiced and closed only by the demonstration builder, so every real order stopped at Despatched, and an invoice could be marked credited by a bare button with no credit note behind it. This reads every lifecycle against the register that says what fires each move, and refuses a move nothing fires and a state nothing reaches.',
   true, 102)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- The refusal is not registered in erp_ref.refusal: it is raised only by an
-- assert_ routine, which erp.refusal_report() deliberately does not count as a
-- raise, so a register row would read as raised nowhere and refuse the
-- migration. Its next action travels as the hint, where whoever reads a failed
-- build sees it.

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A month's trading in one organisation of its own: a hundred received, an
-- order of ten delivered in two halves, each half billed, and the invoice
-- credited back a bit at a time. Every case is inside the rollback fixture,
-- the count is pinned at both ends, and the count guard prints what the fixture
-- caught, because a break diagnosed from a missing row costs a whole build.
--
-- The three falsification cases are why erp.undriven_transition_report() takes
-- a register: a check that has never been seen to refuse is a check nobody
-- should believe. Each hands it a register that is wrong in one specific way
-- and reads the finding back.

create or replace function erp_test.lifecycle_completes_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 15;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_cust uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid;
  v_so uuid; v_sol uuid; v_so2 uuid; v_so3 uuid; v_so3l uuid;
  v_dn_a uuid; v_dn_b uuid; v_dn_c uuid;
  v_inv_a uuid; v_inv_b uuid; v_inv_c uuid;
  v_line_a uuid; v_cn1 uuid; v_cn2 uuid;
  v_after_a text; v_after_b text; v_closed text;
  v_credit_1 text; v_credit_2 text; v_draft_state text;
  v_msg1 text; v_msg2 text; v_verdict text;
  v_reg jsonb; v_reg_a jsonb; v_reg_b jsonb; v_reg_c jsonb; v_reg_d jsonb;
  v_hit_a boolean; v_hit_b boolean; v_hit_c boolean; v_hit_d boolean;
begin
  begin
    v_step := 'an organisation with finance, procurement, sales and inventory installed';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzlc-' || v_tag, 'Lifecycle Suite',
      'admin@zzlc-' || v_tag || '.test', 'Lifecycle Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzlc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');

    v_step := 'its own unit, site, places, supplier, customer and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZLEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZLSITE', 'Lifecycle suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZL-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZL-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZLSUP', 'Lifecycle Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZLCUS', 'Lifecycle Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer',
            jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZLWID', 'Lifecycle Suite Widget', v_uom, 'active')
    returning id into v_item;

    -- ── 1. The check passes over a whole organisation ───────────────────────
    v_step := 'the driver register against every lifecycle this organisation holds';
    v_cases := v_cases + 1;
    case_name := 'every transition every lifecycle declares is fired by something';
    begin
      v_verdict := erp.assert_every_transition_is_driven();
      passed := v_state is null;
      detail := left(coalesce(v_verdict, 'no verdict'), 200);
    exception when others then
      passed := false; detail := left(sqlerrm, 240);
    end;
    return next;

    -- ── The month: a hundred in, ten out in two halves ──────────────────────
    v_step := 'a hundred widgets arrive at ten pounds each';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets');
    perform erp.transition_document(v_po, 'submit', 'lifecycle suite');
    perform erp_test.approve_document(v_po, 'lifecycle suite');
    perform erp.transition_document(v_po, 'send', 'lifecycle suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'lifecycle suite');

    v_step := 'ten are sold, six go out and then the other four';
    v_so := erp.open_document('sales_order', v_cust, rb.entity_id, v_site);
    v_sol := erp.add_document_line(v_so, v_item, 10, 2500, 'ten widgets');
    perform erp.transition_document(v_so, 'submit', 'lifecycle suite');
    perform erp_test.approve_document(v_so, 'lifecycle suite');

    v_dn_a := (erp.create_delivery_from_order(
                 v_so,
                 jsonb_build_array(jsonb_build_object('line_id', v_sol, 'quantity', 6))
               ) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn_a, 'post', 'lifecycle suite');
    v_dn_b := (erp.create_delivery_from_order(
                 v_so,
                 jsonb_build_array(jsonb_build_object('line_id', v_sol, 'quantity', 4))
               ) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn_b, 'post', 'lifecycle suite');

    v_cases := v_cases + 1;
    case_name := 'the order delivered in full reads Despatched, and not yet Invoiced';
    passed := v_state is null
          and erp.object_current_state('document', v_so) = 'despatched';
    detail := format('the order reads %s',
                     coalesce(erp.object_current_state('document', v_so), 'nothing'));
    return next;

    -- ── 2. One despatch billed is not the whole order ───────────────────────
    v_step := 'the first despatch is invoiced';
    v_inv_a := erp.invoice_from_delivery(v_dn_a, true);
    perform erp.transition_document(v_inv_a, 'issue', 'lifecycle suite');
    v_after_a := erp.object_current_state('document', v_so);

    v_cases := v_cases + 1;
    case_name := 'an order with a despatch nobody has billed stays Despatched';
    passed := v_state is null and v_after_a = 'despatched';
    detail := format('one of the two despatches is invoiced and the order reads %s',
                     coalesce(v_after_a, 'nothing'));
    return next;

    v_step := 'the second despatch is invoiced';
    v_inv_b := erp.invoice_from_delivery(v_dn_b, true);
    perform erp.transition_document(v_inv_b, 'issue', 'lifecycle suite');
    v_after_b := erp.object_current_state('document', v_so);

    v_cases := v_cases + 1;
    case_name := 'an order every despatch of which is billed reads Invoiced';
    passed := v_state is null and v_after_b = 'invoiced';
    detail := format('both despatches are invoiced and the order reads %s; nobody pressed anything',
                     coalesce(v_after_b, 'nothing'));
    return next;

    v_cases := v_cases + 1;
    case_name := 'the move is recorded as the invoice that made it';
    passed := v_state is null and exists (
      select 1 from erp.state_transition_log l
       where l.tenant_id = rb.tenant_id and l.object_type = 'document'
         and l.object_id = v_so and l.transition_code = 'invoice'
         and l.reason like 'Invoiced in full by %');
    detail := 'the order''s history names the invoice, not a person';
    return next;

    -- ── 3. And can then be closed, which is what Invoiced was for ───────────
    v_step := 'the order is closed';
    perform erp.transition_document(v_so, 'close', 'lifecycle suite');
    v_closed := erp.object_current_state('document', v_so);

    v_cases := v_cases + 1;
    case_name := 'an invoiced order can be closed';
    passed := v_state is null and v_closed = 'closed';
    detail := format('the order reads %s; Close had no state to fire from until now',
                     coalesce(v_closed, 'nothing'));
    return next;

    -- ── 4. And the state machine still refuses what must not fire ───────────
    v_step := 'an order that has not been despatched is asked to be invoiced';
    v_so2 := erp.open_document('sales_order', v_cust, rb.entity_id, v_site);
    perform erp.add_document_line(v_so2, v_item, 5, 2500, 'five widgets');
    perform erp.transition_document(v_so2, 'submit', 'lifecycle suite');
    perform erp_test.approve_document(v_so2, 'lifecycle suite');
    begin
      perform erp.transition_document(v_so2, 'invoice', 'lifecycle suite');
      v_msg1 := 'no refusal';
    exception when others then
      v_msg1 := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a confirmed order cannot be marked invoiced';
    passed := v_state is null and v_msg1 like '%TRANSITION_NOT_PERMITTED%'
          and erp.object_current_state('document', v_so2) = 'confirmed';
    detail := left(v_msg1, 200);
    return next;

    -- ── 5. A credit note credits the invoice, a bit at a time ───────────────
    v_step := 'a quarter of the first invoice is credited';
    select l.id into v_line_a from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_inv_a
     order by l.line_no limit 1;
    v_cn1 := erp.raise_customer_credit_note(
               v_inv_a, 'ZLRET', 'Two came back damaged',
               jsonb_build_array(jsonb_build_object('line_id', v_line_a, 'quantity', 2)));
    perform erp.transition_document(v_cn1, 'issue', 'lifecycle suite');
    v_credit_1 := erp.object_current_state('document', v_inv_a);

    v_cases := v_cases + 1;
    case_name := 'a part credit leaves the invoice Issued';
    passed := v_state is null and v_credit_1 = 'issued';
    detail := format('two of six are back and the invoice reads %s; the customer still owes the rest',
                     coalesce(v_credit_1, 'nothing'));
    return next;

    v_step := 'the rest of the first invoice is credited';
    v_cn2 := erp.raise_customer_credit_note(
               v_inv_a, 'ZLRET', 'The other four came back too',
               jsonb_build_array(jsonb_build_object('line_id', v_line_a, 'quantity', 4)));
    perform erp.transition_document(v_cn2, 'issue', 'lifecycle suite');
    v_credit_2 := erp.object_current_state('document', v_inv_a);

    v_cases := v_cases + 1;
    case_name := 'an invoice every unit of which has come back reads Credited';
    passed := v_state is null and v_credit_2 = 'credited';
    detail := format('six of six are back and the invoice reads %s; nobody pressed anything',
                     coalesce(v_credit_2, 'nothing'));
    return next;

    -- ── 6. A credit note never issues the invoice on its way ────────────────
    v_step := 'a credit note is raised against an invoice nobody has issued';
    v_so3 := erp.open_document('sales_order', v_cust, rb.entity_id, v_site);
    v_so3l := erp.add_document_line(v_so3, v_item, 3, 2500, 'three widgets');
    perform erp.transition_document(v_so3, 'submit', 'lifecycle suite');
    perform erp_test.approve_document(v_so3, 'lifecycle suite');
    v_dn_c := (erp.create_delivery_from_order(v_so3) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn_c, 'post', 'lifecycle suite');
    v_inv_c := erp.invoice_from_delivery(v_dn_c, true);
    begin
      perform erp.transition_document(v_inv_c, 'credit', 'lifecycle suite');
      v_msg2 := 'no refusal';
    exception when others then
      v_msg2 := sqlerrm;
    end;
    v_draft_state := erp.object_current_state('document', v_inv_c);

    v_cases := v_cases + 1;
    case_name := 'an invoice still in draft cannot be credited';
    passed := v_state is null and v_msg2 like '%TRANSITION_NOT_PERMITTED%'
          and v_draft_state = 'draft';
    detail := format('%s; the invoice reads %s', left(v_msg2, 160),
                     coalesce(v_draft_state, 'nothing'));
    return next;

    -- ── 7. The check refuses three registers that are wrong ─────────────────
    v_step := 'the check is falsified against registers that are wrong';
    v_reg := erp.transition_driver_register();

    select jsonb_agg(e) into v_reg_a
      from jsonb_array_elements(v_reg) e
     where not (e ->> 'machine_code' = 'sales_order' and e ->> 'transition_code' = 'invoice');
    select exists (
      select 1 from erp.undriven_transition_report(v_reg_a) r
       where r.reference = 'sales_order.invoice'
         and r.finding like '%nothing is registered to fire%')
      into v_hit_a;

    v_cases := v_cases + 1;
    case_name := 'a transition the register does not name is refused';
    passed := v_state is null and coalesce(v_hit_a, false);
    detail := 'the report names sales_order.invoice when its row is taken out';
    return next;

    select jsonb_agg(case
             when e ->> 'machine_code' = 'sales_order' and e ->> 'transition_code' = 'invoice'
             then e || jsonb_build_object('detail', 'erp.no_such_mechanism(uuid)')
             else e end) into v_reg_b
      from jsonb_array_elements(v_reg) e;
    select exists (
      select 1 from erp.undriven_transition_report(v_reg_b) r
       where r.reference = 'sales_order.invoice'
         and r.finding like '%driver that does not exist%')
      into v_hit_b;

    v_cases := v_cases + 1;
    case_name := 'a driver the database does not have is refused';
    passed := v_state is null and coalesce(v_hit_b, false);
    detail := 'the report names a register row pointing at a routine nobody wrote';
    return next;

    select jsonb_agg(case
             when e ->> 'machine_code' = 'sales_order' and e ->> 'transition_code' = 'invoice'
             then e || jsonb_build_object('driver', 'undriven',
                                          'detail', 'left to nothing, for this case')
             else e end) into v_reg_c
      from jsonb_array_elements(v_reg) e;
    select exists (
      select 1 from erp.undriven_transition_report(v_reg_c) r
       where r.reference = 'sales_order.close'
         and r.finding like '%nothing can reach%')
      into v_hit_c;

    v_cases := v_cases + 1;
    case_name := 'a move whose state nothing reaches is refused, even though it has a button';
    passed := v_state is null and coalesce(v_hit_c, false);
    detail := 'with nothing invoicing an order, Close is named — which is what it was '
              'for every day this product has existed';
    return next;

    -- The allowance itself. No transition needs one today — the one this file
    -- was drafted with was answered by 20260919200000 before it landed — so
    -- without this case the allowance would be a door nobody has opened, and a
    -- register row saying nothing would go through it silently.
    select jsonb_agg(case
             when e ->> 'machine_code' = 'sales_order' and e ->> 'transition_code' = 'invoice'
             then e || jsonb_build_object('driver', 'undriven', 'detail', '   ')
             else e end) into v_reg_d
      from jsonb_array_elements(v_reg) e;
    select exists (
      select 1 from erp.undriven_transition_report(v_reg_d) r
       where r.reference = 'sales_order.invoice'
         and r.finding like '%no reason written down%')
      into v_hit_d;

    v_cases := v_cases + 1;
    case_name := 'an allowance that gives no reason is refused';
    passed := v_state is null and coalesce(v_hit_d, false);
    detail := 'a transition may be left to nothing, and only with the reason written beside it';
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzlc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzlc rolled back with its orders, its invoices and its credit notes');
  return next;

  -- The count guard says what stopped the fixture. Without this the wrapper
  -- never sees a row, so the message this suite caught into v_state — and the
  -- step that produced it — never reaches the build log, and every break costs
  -- a run to find.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_LIFECYCLE_COMPLETES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.lifecycle_completes_suite() from public, anon;

create or replace function erp_test.assert_lifecycle_completes_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 15;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _lifecycle_completes on commit drop as
    select * from erp_test.lifecycle_completes_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _lifecycle_completes;
  drop table _lifecycle_completes;
  if v_fail > 0 then
    raise exception E'CLOVEERP_LIFECYCLE_COMPLETES_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_LIFECYCLE_COMPLETES_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('the lifecycle completes: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_lifecycle_completes_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The generators, and the proof
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_dead_configuration();

-- The check this file exists for, against whatever lifecycles this database
-- already holds.
select erp.assert_every_transition_is_driven();

select erp_test.assert_lifecycle_completes_suite();
-- The suite whose fixture runs the whole chain this change alters: it delivers
-- an order, invoices the despatch and credits the invoice, so the order it
-- builds now reaches Invoiced and the invoice it credits in full now reaches
-- Credited. Proved here rather than left to the catalogue, because a break
-- found forty minutes later is a break found twice.
select erp_test.assert_credit_note_suite();
select erp_test.assert_delivery_from_order_suite();
