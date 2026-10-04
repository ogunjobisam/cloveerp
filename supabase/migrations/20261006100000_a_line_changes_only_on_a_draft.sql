set lock_timeout = '30s';

-- =============================================================================
-- 20261006100000  A line changes only on a draft
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-32, J-119). Two
-- confirmed sales orders there had lines added after their approval was
-- asked, and the approval stood over the new value. A cancelled goods receipt
-- took a new line and a new price as if nothing had happened.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- erp.add_document_line() refused only a committed document (and a submitted
-- transfer or adjustment). Waiting for approval, submitted, approved and sent
-- are neither initial nor committed, so a sales order, a purchase order, a
-- requisition or a sent quotation took a line there. erp.price_document_line()
-- checked no state at all. And a document cancelled by its lifecycle keeps
-- its is_cancelled flag unset, so erp.protect_cancelled_document() never
-- fired for it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. One rule, read in one place. erp.document_lines_open(document) says
--      whether its lines may be added, priced, changed or removed: the
--      document is in its lifecycle's first state (draft; planned for a
--      shipment; or it has no lifecycle), is not cancelled by flag or by
--      state, and is not a type whose lines a routine writes (count sheet,
--      cash receipt, supplier payment, VAT return).
--      erp.require_lines_open(document) refuses by name otherwise, holding
--      the document's lifecycle row while it decides, the row a move holds,
--      so a line and a submit cannot cross. The refusals that were in
--      erp.add_document_line() move into it unchanged; two are new:
--      CLOVEERP_DOCUMENT_CANCELLED for a document its lifecycle cancelled,
--      and CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT for any other state past
--      draft, whose hint says how to get back to draft where the lifecycle
--      has a way, and to raise it again where it has none.
--   B. erp.add_document_line() and erp.price_document_line() ask it.
--   C. erp_test.approval_hold_suite proves it on a sales order and a purchase
--      order waiting for approval, a sent quotation, an approved requisition
--      and a receipt its lifecycle cancelled, and that a draft still takes
--      a line.
--   D. Suites that added or repriced a line after a move now do it before.
--
-- Draft only, rather than "not yet committed": an approval is given for what
-- the document said, and the reject moves already take a pending document
-- back to draft. Every production caller adds its lines before the first move
-- (read from the current bodies of erp.create_document_full, convert_document,
-- receive_against, the raise_* routines and the seed_demo_* routines).
--
-- Production: no row is changed. Documents past draft stop taking lines from
-- the next press.
--
-- Proof: erp_test.approval_hold_suite.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The rule
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT',
  'Adding, pricing, changing or removing a line on a document that is no longer a draft.',
  'A document is approved, sent or agreed for what it says when it leaves draft. A line changed after that would go through with an approval or an agreement given for something else.',
  'Take it back to draft, change it there and submit it again. Where it cannot go back, cancel it and raise it again, or raise a second one for the difference.');

create or replace function erp.document_lines_open(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Whether a document's lines may be added, priced, changed or removed
  -- (20261006100000): it is in its lifecycle's first state, or has none; it
  -- is not cancelled, by flag or by state; and its lines are not written by a
  -- routine of their own. erp.require_lines_open() refuses where this is
  -- false, and the document page draws its line controls where it is true.
  select exists (
    select 1
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      left join erp.state s on s.id = os.current_state_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
       and not d.is_cancelled
       and dt.base_type_code not in ('count', 'cash_receipt', 'cash_payment', 'vat_return')
       and (os.id is null or (s.is_initial and not s.is_committed and s.code <> 'cancelled')))
$$;

revoke all on function erp.document_lines_open(uuid) from public, anon;

comment on function erp.document_lines_open(uuid) is
  'Whether a document''s lines may be added, priced, changed or removed: in its first state, not cancelled, '
  'and not a type whose lines a routine writes (20261006100000).';

create or replace function erp.require_lines_open(p_document_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_os     uuid;
  st       record;
  v_back   text;
  v_hint   text;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select dt.base_type_code into v_base
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  -- The row a move holds while it moves the document (erp.perform_transition),
  -- held here while the line is decided, so a line and a submit cannot cross.
  select os.id into v_os
    from erp.object_state os
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id
     for update;

  -- Each line of a count sheet is a count, with a lock on its place, and
  -- erp.raise_count_tasks() writes them (20260927100000).
  if v_base = 'count' then
    raise exception
      'CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS: % is a count sheet, and its lines are the counts raised on it',
      d.document_number
      using errcode = '23514',
            hint = 'Raise a count for the place from Counting. It goes on a sheet of its own.';
  end if;

  -- Each line of a cash receipt is cash the bank received, and
  -- erp.apply_cash() writes them (20260930000000).
  if v_base = 'cash_receipt' then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH: % is a cash receipt, and its lines are the cash applied',
      d.document_number
      using errcode = '23514',
            hint = 'Apply the further cash from Cash in, or correct a misapplied receipt with a journal on the Journals screen.';
  end if;

  -- Each line of a supplier payment is a bill the run paid, and
  -- erp.pay_payment_run() writes them (20260930200000).
  if v_base = 'cash_payment' then
    raise exception
      'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH: % is a supplier payment, and its lines are the bills it paid',
      d.document_number
      using errcode = '23514',
            hint = 'Pay the further bills from Pay, or correct a misapplied payment with a journal on the Journals screen.';
  end if;

  -- A VAT return has no lines: it is its period's boxes (20261001100000).
  if v_base = 'vat_return' then
    raise exception
      'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD: % is a VAT return, and a return has no lines',
      d.document_number
      using errcode = '23514',
            hint = 'Finalise the period from VAT returns. The return is opened and finalised in the same press.';
  end if;

  -- A transfer order is changed only as a draft (20260928200000): a line
  -- added while it waits for approval would move with an approval given
  -- for less.
  -- A stock adjustment the same (20260928500000).
  if erp.adjustment_is_past_draft(p_document_id) then
    raise exception
      'CLOVEERP_ADJUSTMENT_CHANGED_ONLY_AS_A_DRAFT: % has been submitted, so it takes no new line',
      d.document_number
      using errcode = '23514',
            hint = 'Have it rejected back to draft and change it there, or raise a second adjustment for the rest.';
  end if;

  if erp.transfer_is_past_draft(p_document_id) then
    raise exception
      'CLOVEERP_TRANSFER_CHANGED_ONLY_AS_A_DRAFT: % has been submitted, so it takes no new line',
      d.document_number
      using errcode = '23514',
            hint = 'Have it rejected back to draft and change it there, or raise a second transfer for what is left.';
  end if;

  select s.id, s.code, s.is_initial, s.is_committed, s.is_terminal, s.state_machine_version_id
    into st
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.id = v_os;

  -- A committed document is one the outside world has seen. Changing what it
  -- says after the fact is what amendment and reversal are for.
  if coalesce(st.is_committed, false) then
    raise exception
      'CLOVEERP_DOCUMENT_COMMITTED: % has been committed; amend or reverse it '
      'rather than editing its lines', d.document_number
      using errcode = '42501';
  end if;

  -- Cancelled by its flag, or by its lifecycle, which leaves the flag unset.
  if d.is_cancelled or st.code = 'cancelled' then
    raise exception
      'CLOVEERP_DOCUMENT_CANCELLED: % has been cancelled, so its lines are kept as they were',
      d.document_number
      using errcode = '42501',
            hint = 'Raise a new one for what is still needed.';
  end if;

  -- Past draft: approved, sent or agreed for what it said when it left.
  if v_os is not null and not st.is_initial then
    -- The way back to draft where this lifecycle has one, read from the
    -- version the document is pinned to.
    select t.code into v_back
      from erp.transition t
      join erp.state ts on ts.id = t.to_state_id
     where t.tenant_id = v_tenant
       and t.state_machine_version_id = st.state_machine_version_id
       and t.from_state_id = st.id
       and ts.is_initial
       and not coalesce(t.is_automatic, false)
     order by t.sort_order, t.code
     limit 1;
    v_hint := case
      when v_back like 'reject%' then 'Have it rejected back to draft, change it there and submit it again.'
      when v_back is not null then 'Take it back to draft, change it there and submit it again.'
      when st.is_terminal then 'Raise a new one for what is still needed.'
      else 'Cancel it and raise it again, or raise a second one for the difference.'
    end;
    raise exception
      'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT: % is %, and its lines change only as a draft',
      d.document_number, st.code
      using errcode = '23514',
            hint = v_hint;
  end if;
end;
$$;

revoke all on function erp.require_lines_open(uuid) from public, anon;

comment on function erp.require_lines_open(uuid) is
  'Refuses a line added, priced, changed or removed on a document past draft, committed, cancelled, or whose '
  'lines a routine writes, holding the document''s lifecycle row while it decides (20261006100000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The two doors that write a line ask it
-- ─────────────────────────────────────────────────────────────────────────────

do $add$
declare
  v_sig   constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_from  constant text := $f$  -- Each line of a count sheet is a count, with a lock on its place, and
  -- erp.raise_count_tasks() writes them (20260927100000).
  if v_base = 'count' then$f$;
  v_to    constant text := $t$      'CLOVEERP_DOCUMENT_COMMITTED: % has been committed; amend or reverse it '
      'rather than editing its lines', d.document_number
      using errcode = '42501';
  end if;
$t$;
  v_new   constant text := $n$  -- Whether this document takes a line at all, read in one place
  -- (20261006100000): the types whose lines a routine writes, a transfer or
  -- adjustment past draft, committed, cancelled, and any other state past
  -- draft, each refused by name.
  perform erp.require_lines_open(p_document_id);
$n$;
  v_i     integer;
  v_j     integer;
begin
  if strpos(v_src, '20261006100000') > 0 then
    raise notice '% already asks erp.require_lines_open; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '709079e764f47b896aab844bbc8d0ece' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006100000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from) <> 1
     or (length(v_def) - length(replace(v_def, v_to, ''))) / length(v_to) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  v_i := strpos(v_def, v_from);
  v_j := strpos(v_def, v_to) + length(v_to);
  if v_j <= v_i then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors out of order', v_sig;
  end if;
  execute left(v_def, v_i - 1) || v_new || substr(v_def, v_j);
end
$add$;

do $price$
declare
  v_sig  constant text := 'erp.price_document_line(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;
$o$;
  v_new  constant text := $n$  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;

  -- A price is part of what a document says, so it changes only while the
  -- document is a draft (20261006100000). Until then this checked no state.
  perform erp.require_lines_open(l.document_id);
$n$;
begin
  if strpos(v_src, '20261006100000') > 0 then
    raise notice '% already asks erp.require_lines_open; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'b61946a8154500e8a2e6d8468c92e029' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006100000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$price$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof: erp_test.approval_hold_suite, six cases more
-- ─────────────────────────────────────────────────────────────────────────────

do $hold$
declare
  v_sig  constant text := 'erp_test.approval_hold_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $a$  v_seat_wrong  integer;
$a$;
  v_a_new constant text := $a$  v_seat_wrong  integer;
  -- Lines past draft (20261006100000).
  v_lso_add    text;
  v_lso_price  text;
  v_lpo_add    text;
  v_qt         uuid;
  v_qtl        uuid;
  v_lqt_add    text;
  v_lqt_price  text;
  v_cgrn_move  text;
  v_lgrn_add   text;
  v_lgrn_price text;
  v_dso        uuid;
  v_ldraft_add uuid;
  v_ldraft_err text;
  v_ldraft_price text;
  v_rq3        uuid;
  v_rq3_state  text;
  v_lrq_add    text;
$a$;
  v_b_old constant text := $b$      public.erp_document_lines(v_po, 'purchase_order', 200)) e);

    raise exception 'CLOVEERP_APPROVAL_HOLD_SUITE_UNDO';
$b$;
  v_b_new constant text := $b$      public.erp_document_lines(v_po, 'purchase_order', 200)) e);

    -- Lines change only as a draft (20261006100000). The sales order and the
    -- second purchase order are waiting for approval.
    begin
      perform erp.add_document_line(v_so, v_item, 1, 9900, 'One more widget');
      v_lso_add := 'the line was added';
    exception when others then
      v_lso_add := left(sqlerrm, 200);
    end;
    begin
      perform erp.price_document_line((select l.id from erp.document_line l
                                        where l.tenant_id = r.tenant_id and l.document_id = v_so
                                        order by l.line_no limit 1));
      v_lso_price := 'the line was repriced';
    exception when others then
      v_lso_price := left(sqlerrm, 200);
    end;
    begin
      perform erp.add_document_line(v_po2, v_item, 1, 5000, 'One more widget');
      v_lpo_add := 'the line was added';
    exception when others then
      v_lpo_add := left(sqlerrm, 200);
    end;
    -- A quotation once it is sent.
    v_qt := erp.open_document('quotation', v_cust, null, v_site);
    v_qtl := erp.add_document_line(v_qt, v_item, 2, 9900, 'Two widgets');
    perform erp.transition_document(v_qt, 'send');
    begin
      perform erp.add_document_line(v_qt, v_item, 1, 9900, 'One more widget');
      v_lqt_add := 'the line was added';
    exception when others then
      v_lqt_add := left(sqlerrm, 200);
    end;
    begin
      perform erp.price_document_line(v_qtl);
      v_lqt_price := 'the line was repriced';
    exception when others then
      v_lqt_price := left(sqlerrm, 200);
    end;
    -- The receipt, cancelled by its lifecycle: its flag stays unset.
    select x ->> 'code' into v_cgrn_move
      from jsonb_array_elements(public.erp_available_transitions(v_grn)) x
     where x ->> 'to_state' = 'cancelled' limit 1;
    perform erp.transition_document(v_grn, v_cgrn_move, 'the lorry was turned away');
    begin
      perform erp.add_document_line(v_grn, v_item, 1, 5000, 'One more widget');
      v_lgrn_add := 'the line was added';
    exception when others then
      v_lgrn_add := left(sqlerrm, 200);
    end;
    begin
      perform erp.price_document_line(v_sent_line);
      v_lgrn_price := 'the line was repriced';
    exception when others then
      v_lgrn_price := left(sqlerrm, 200);
    end;
    -- And a draft still takes a line; asking its price is not refused for
    -- its state (it may be refused for want of a price list).
    v_dso := erp.open_document('sales_order', v_cust, null, v_site);
    begin
      v_ldraft_add := erp.add_document_line(v_dso, v_item, 1, 9900, 'One widget');
    exception when others then
      v_ldraft_err := left(sqlerrm, 200);
    end;
    begin
      perform erp.price_document_line(v_ldraft_add);
      v_ldraft_price := 'repriced';
    exception when others then
      v_ldraft_price := left(sqlerrm, 200);
    end;

    raise exception 'CLOVEERP_APPROVAL_HOLD_SUITE_UNDO';
$b$;
  v_c_old constant text := $c$    v_approved4 := erp.transition_document(v_po4, 'approve');
$c$;
  v_c_new constant text := $c$    v_approved4 := erp.transition_document(v_po4, 'approve');

    -- An approved requisition takes no line (20261006100000).
    v_rq3 := erp.open_document('requisition', v_sup3);
    perform erp.add_document_line(v_rq3, v_item3, 1, 5000, 'One widget');
    perform erp.transition_document(v_rq3, 'submit');
    perform erp.approve_my_document_tasks(v_rq3, 'setting up');
    v_rq3_state := erp.transition_document(v_rq3, 'approve');
    begin
      perform erp.add_document_line(v_rq3, v_item3, 1, 5000, 'One more widget');
      v_lrq_add := 'the line was added';
    exception when others then
      v_lrq_add := left(sqlerrm, 200);
    end;
$c$;
  v_d_old constant text := $d$                                      v_task4_to = r3.admin_user_id, v_approved4));
  return next;
$d$;
  v_d_new constant text := $d$                                      v_task4_to = r3.admin_user_id, v_approved4));
  return next;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Lines change only as a draft (20261006100000)
  -- ───────────────────────────────────────────────────────────────────────────

  case_name := 'a sales order waiting for approval takes no new line and no new price';
  passed := coalesce(v_state is null
            and v_lso_add like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%'
            and v_lso_price like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%', false);
  detail := coalesce(v_state, format('adding: %s; repricing: %s', v_lso_add, v_lso_price));
  return next;

  case_name := 'nor does a purchase order waiting for approval';
  passed := coalesce(v_state is null and v_lpo_add like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%', false);
  detail := coalesce(v_state, v_lpo_add);
  return next;

  case_name := 'nor a quotation once it is sent';
  passed := coalesce(v_state is null
            and v_lqt_add like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%'
            and v_lqt_price like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%', false);
  detail := coalesce(v_state, format('adding: %s; repricing: %s', v_lqt_add, v_lqt_price));
  return next;

  case_name := 'a receipt its lifecycle cancelled takes no line and no price, and says it is cancelled';
  passed := coalesce(v_state is null and v_cgrn_move is not null
            and v_lgrn_add like 'CLOVEERP_DOCUMENT_CANCELLED%'
            and v_lgrn_price like 'CLOVEERP_DOCUMENT_CANCELLED%', false);
  detail := coalesce(v_state, format('cancelled by %s; adding: %s; repricing: %s',
                                     coalesce(v_cgrn_move, 'no move'), v_lgrn_add, v_lgrn_price));
  return next;

  case_name := 'a draft still takes a line, and asking its price is not refused for its state';
  passed := coalesce(v_state is null and v_ldraft_add is not null and v_ldraft_err is null
            and v_ldraft_price not like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%'
            and v_ldraft_price not like 'CLOVEERP_DOCUMENT_%', false);
  detail := coalesce(v_state, format('adding: %s; pricing: %s',
                                     coalesce(v_ldraft_err, 'added'), v_ldraft_price));
  return next;

  case_name := 'an approved requisition takes no new line';
  passed := coalesce(v_state3 is null and v_rq3_state = 'approved'
            and v_lrq_add like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%', false);
  detail := coalesce(v_state3, format('the requisition is %s; adding: %s', v_rq3_state, v_lrq_add));
  return next;
$d$;
  v_once integer;
begin
  if strpos(v_src, '20261006100000') > 0 then
    raise notice '% already proves lines past draft; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '2ddd7efaeb4479cae7fe20059f069039' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006100000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  foreach v_once in array array[
      (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old),
      (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old),
      (length(v_def) - length(replace(v_def, v_c_old, ''))) / length(v_c_old),
      (length(v_def) - length(replace(v_def, v_d_old, ''))) / length(v_d_old)] loop
    if v_once <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
    end if;
  end loop;
  execute replace(replace(replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new), v_c_old, v_c_new), v_d_old, v_d_new);
end
$hold$;

do $hold_count$
declare
  v_sig  constant text := 'erp_test.assert_approval_hold_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- Sixteen until 20260918910000, which added the light user at the door.
  c_expected constant integer := 17;
$o$;
  v_new  constant text := $n$  -- Sixteen until 20260918910000, which added the light user at the door;
  -- seventeen until 20261006100000, which added six cases on lines past draft.
  c_expected constant integer := 23;
$n$;
begin
  if strpos(v_src, '20261006100000') > 0 then
    raise notice '% already counts 23; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '32db14e2f73f93359923045cf6ae46bb' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006100000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$hold_count$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Suites that changed a line after a move
-- ─────────────────────────────────────────────────────────────────────────────

-- A suite that added or repriced a line after a move now does it before the
-- move, so its fixture is what the new rule allows; the rule is not loosened
-- for any of them. Where the line changed past the move IS what a case
-- proves (an order approved with its requisition, changed before it is
-- issued), the line is written as an order changed before this rule would
-- have been left, as the case's other branches already write theirs, and the
-- case also proves that the door now refuses the change.

-- Four suites ordered ten coats with erp_test.prepayment_order(..., false),
-- which approves the order, and then added ten scarves to it. Both lines now
-- go on the draft, which is then submitted and approved as that helper does.
do $two_line_orders$
declare
  r      record;
  v_src  text;
  v_def  text;
  v_old  text;
  v_new  text;
begin
  for r in
    select * from (values
      ('erp_test.inbound_freight_suite()',       'a6c44ba4f4831379bc5f4134c91b5d55', 'ZIF2'),
      ('erp_test.landed_cost_suite()',           '8825466ed319259bb3cc41e4cb6ae3b9', 'ZLC1'),
      ('erp_test.supplier_confirmation_suite()', '3a38b08b0d69c59eb073d75b897b690f', 'ZCO1'),
      ('erp_test.shipping_notice_suite()',       '2d3f9947e34d15ff3903ca1a666a8f43', 'ZNO1')
    ) as t(sig, digest, ref)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if strpos(v_src, '20261006100000') > 0 then
      raise notice '% already orders both lines as a draft; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.digest then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006100000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    v_old := format($o$    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, '%s', false);
    perform erp.add_document_line(v_po, v_item2, 10, 1000, 'scarves');
$o$, r.ref);
    v_new := format($n$    -- Both lines go on while the order is a draft (20261006100000): an
    -- approved order takes no new line. Then approved, as
    -- erp_test.prepayment_order approves it.
    v_po := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    perform erp.add_document_line(v_po, v_item, 10, 9000, 'bought for %s');
    perform erp.add_document_line(v_po, v_item2, 10, 1000, 'scarves');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'supplier prepayment suite');
$n$, r.ref);
    if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', r.sig;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end
$two_line_orders$;

-- erp_test.procurement_policy_suite proves that an order approved with its
-- requisition and then given a new line is refused at issue. The door now
-- refuses the new line itself, and the case says so; the line is then
-- written directly, as an order changed before this rule was left, so that
-- issuing it is still proved refused, as the case's price and value
-- branches already write theirs.
do $policy$
declare
  v_sig  constant text := 'erp_test.procurement_policy_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$        if v_i = 1 then
          perform erp.add_document_line(v_po, v_item, 1, 1000, 'one more line');
        elsif v_i = 2 then$o$;
  v_new  constant text := $n$        if v_i = 1 then
          -- The door refuses a line on an approved order (20261006100000).
          begin
            perform erp.add_document_line(v_po, v_item, 1, 1000, 'one more line');
            v_ok := false;
            v_msg := v_msg || 'the door added a line to an approved order; ';
          exception when others then
            if sqlerrm not like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%' then raise; end if;
          end;
          -- An order changed before then, as it was left.
          insert into erp.document_line (tenant_id, document_id, line_no, item_id, description,
                                         quantity, uom_id, unit_price_minor, net_minor, currency)
          select dl.tenant_id, dl.document_id, dl.line_no + 10, dl.item_id, 'one more line',
                 1, dl.uom_id, 1000, 1000, dl.currency
            from erp.document_line dl
           where dl.tenant_id = v_tenant and dl.id = v_pl;
        elsif v_i = 2 then$n$;
begin
  if strpos(v_src, '20261006100000') > 0 then
    raise notice '% already writes the added line directly; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '579e685d80a8dffaaac52a78a379ee0f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006100000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$policy$;

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
select erp.assert_personal_data_register_sound();
