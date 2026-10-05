set lock_timeout = '30s';

-- =============================================================================
-- 20261010011000  A document says when it falls due and what it waits for
-- -----------------------------------------------------------------------------
-- Found in the live re-test of 5 October (B1, B4).
--
--   B1. An invoice's page showed no due date, although since #423 an invoice
--       is dated from its customer's terms when it is issued, and a bill from
--       its supplier's when it is raised: public.erp_document answered the
--       document's date and never its due_date. Nor did the invoice show the
--       customer's reference ("their ref RT2-O2C-Q1") that its quotation, its
--       order and its delivery all showed: erp.invoice_from_delivery opened
--       the invoice without it, so it was not on the invoice at all.
--   B4. A goods receipt just posted said "No line can be amended now: stock
--       has left against this document; amend by returning it". Nothing had
--       left; it had just arrived. erp.amendment_allowed said the same of any
--       document that had moved stock, whichever way. And the page said
--       "Nothing more happens to this document." of the receipt while it still
--       had to be billed, and of a posted delivery still to be invoiced: their
--       own lifecycles were over (posted is where both end), and the bill or
--       invoice that is still owed is another document's.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. A relation kind, `settles`, declared here for 20261010012000 (a
--      payment settles the bills it paid). An enum value added in a
--      transaction cannot be used in the same transaction.
--   B. erp.invoice_from_delivery opens the invoice with the delivery's own
--      reference, which the delivery carries from its order and the order
--      from its quotation.
--   C. erp.amendment_allowed says, of a document whose stock came in (a goods
--      receipt, a customer's return), that it was received and is amended by
--      sending the goods back. A document whose stock left reads as before.
--   D. erp.document_awaiting(document): what a document whose own moves are
--      over is still waiting for: a posted goods receipt received against an
--      order, with no supplier bill and something received not yet billed,
--      waits for the bill; a posted delivery with no invoice waits to be
--      invoiced. Samples and the supplier's own goods are settled elsewhere
--      and wait for nothing here.
--   E. public.erp_document answers due_date and awaiting. The page shows the
--      due date beside the reference, and what a document waits for, with
--      the verb that raises it, instead of "Nothing more happens".
--   F. Two screen strings, and erp_test.document_awaits_suite, six cases.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- An invoice already raised keeps the reference it has: only an invoice
-- raised from now on is opened with its delivery's. Nothing is re-dated. Who
-- may amend, bill, invoice or send back is unchanged, and so is every
-- cut-off: only the words of the one for stock that came in.
--
-- On production: three routines are edited where they answer or open, one is
-- added, and an enum value is added to erp.document_relation_kind. No table
-- is altered and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A relation kind for 20261010012000
-- ─────────────────────────────────────────────────────────────────────────────

alter type erp.document_relation_kind add value if not exists 'settles';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. An invoice carries its delivery's reference
-- ─────────────────────────────────────────────────────────────────────────────

do $invoice$
declare
  v_sig  constant text := 'erp.invoice_from_delivery(uuid,boolean,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  v_inv := erp.open_document('sales_invoice', dn.party_id, dn.entity_id, dn.site_id);
$o$;
  v_new  constant text := $n$  -- With the customer's reference the delivery carries from its order, and
  -- the order from its quotation (20261010011000, B1): the invoice is the
  -- document the customer matches against their own order.
  v_inv := erp.open_document('sales_invoice', dn.party_id, dn.entity_id, dn.site_id,
                             nullif(btrim(coalesce(dn.their_reference, '')), ''));
$n$;
begin
  if strpos(v_src, '20261010011000') > 0 then
    raise notice '% already carries the reference; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '598bb7048459f35a2e2356395e841c9f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$invoice$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Stock that came in is said to have come in
-- ─────────────────────────────────────────────────────────────────────────────

do $amend$
declare
  v_sig  constant text := 'erp.amendment_allowed(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_moved then
    allowed := false;
    cut_off := 'stock_has_moved';
    detail := 'stock has left against this document; amend by returning it, not '
              'by editing the document';
$o$;
  v_new  constant text := $n$  if v_moved then
    allowed := false;
    cut_off := 'stock_has_moved';
    -- Which way it moved (20261010011000, B4). A goods receipt's stock, and a
    -- customer's return, came in and went nowhere: nothing left against them.
    if not exists (select 1 from erp.stock_movement m
                    where m.tenant_id = v_tenant and m.document_id = p_document_id
                      and not m.is_reversal and m.from_location_id is not null) then
      detail := 'stock has been received against this document; amend it by sending '
                'the goods back, not by editing the document';
    else
      detail := 'stock has left against this document; amend by returning it, not '
                'by editing the document';
    end if;
$n$;
begin
  if strpos(v_src, '20261010011000') > 0 then
    raise notice '% already says which way stock moved; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd21be9db1a4d1b3ff433d3849bf37af4' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$amend$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. What a finished document still waits for
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.document_awaiting(p_document_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- What a document whose own moves are over still waits for, from another
  -- document (20261010011000, B4): 'bill' or 'invoice', or nothing.
  --
  --   bill     a goods receipt posted against an order, with no supplier bill
  --            (the test erp.bill_from_receipt refuses a second bill by) and an
  --            order line it fulfils still received beyond what was billed.
  --            Samples are settled from Samples and the supplier's own goods
  --            are billed for what was used; neither waits here.
  --   invoice  a delivery that moved stock and has no invoice (the test
  --            erp.invoice_from_delivery refuses a second invoice by).
  select case
           when dt.base_type_code = 'receipt'
            and s.code = 'posted'
            and not d.is_cancelled
            and d.stock_owner_party_id is null
            and not erp.is_sample_receipt(d.id)
            and not exists (
                  select 1 from erp.document_relation rel
                    join erp.document b on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
                    join erp.document_type bt on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
                   where rel.tenant_id = d.tenant_id and rel.to_document_id = d.id
                     and rel.relation_kind = 'invoices'
                     and bt.code = 'purchase_invoice' and not b.is_cancelled)
            and exists (
                  select 1 from erp.document_relation f
                    join erp.document_line ol on ol.tenant_id = f.tenant_id and ol.id = f.to_line_id
                   where f.tenant_id = d.tenant_id and f.from_document_id = d.id
                     and f.relation_kind = 'fulfils'
                     and not coalesce(ol.is_cancelled, false)
                     and coalesce(ol.quantity_fulfilled, 0) > coalesce(ol.quantity_invoiced, 0))
             then 'bill'
           when dt.base_type_code = 'delivery'
            and not d.is_cancelled
            and exists (select 1 from erp.stock_movement m
                         where m.tenant_id = d.tenant_id and m.document_id = d.id)
            and not exists (
                  select 1 from erp.document_relation rel
                    join erp.document i2 on i2.tenant_id = rel.tenant_id and i2.id = rel.from_document_id
                    join erp.document_type it on it.tenant_id = i2.tenant_id and it.id = i2.document_type_id
                   where rel.tenant_id = d.tenant_id and rel.to_document_id = d.id
                     and it.base_type_code = 'invoice_reference'
                     and not i2.is_cancelled)
             then 'invoice'
         end
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.object_state os
      on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
    left join erp.state s on s.id = os.current_state_id
   where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
$$;

revoke all on function erp.document_awaiting(uuid) from public, anon;

comment on function erp.document_awaiting(uuid) is
  'What a document whose own moves are over still waits for from another document: ''bill'' for a posted goods '
  'receipt with nothing billed yet, ''invoice'' for a posted delivery with no invoice, otherwise nothing '
  '(20261010011000). Read by public.erp_document.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The page is told the due date and what the document waits for
-- ─────────────────────────────────────────────────────────────────────────────

do $page$
declare
  v_sig  constant text := 'public.erp_document(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$        'their_reference', d.their_reference,
$o$;
  v_new1 constant text := $n$        'their_reference', d.their_reference,
        -- When it falls due (20261010011000, B1): a bill from its supplier's
        -- terms when it is raised, an invoice from its customer's when it is
        -- issued. A document with none answers null.
        'due_date', d.due_date,
$n$;
  v_old2 constant text := $o$        'is_sample', erp.is_sample_receipt(d.id),
$o$;
  v_new2 constant text := $n$        'is_sample', erp.is_sample_receipt(d.id),
        -- What it still waits for once its own moves are over
        -- (20261010011000, B4): a receipt its supplier's bill, a delivery its
        -- invoice. The page says so instead of "Nothing more happens".
        'awaiting', erp.document_awaiting(d.id),
$n$;
begin
  if strpos(v_src, '20261010011000') > 0 then
    raise notice '% already answers the due date; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '93404d441d8756b64b22d790f6328cd8' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$page$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The words the page says, and the proof
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). What a finished document still waits for (20261010011000).'
  from (values
    ('Waiting for the supplier''s bill: raise it with Bill a receipt.'),
    ('Waiting to be invoiced: raise the invoice with Invoice a delivery.')) v(text)
on conflict do nothing;

create or replace function erp_test.document_awaits_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid; v_site uuid; i_fg uuid; p_sup uuid; p_cus uuid;
  v_po     uuid; v_grn uuid; v_bill uuid; v_so uuid; v_dn uuid; v_inv uuid;
  x        jsonb;
  p        jsonb;
  v_wait   text;
  v_detail text;
  v_due    date;
begin
  begin
    -- ── The fixture: a demonstration that buys and sells ────────────────────
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzdaw' || v_tag, 'Document Awaits Suite',
      'admin@demo-zzdaw' || v_tag || '.test', 'Awaits Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzdaw' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_ent from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select i.id into i_fg from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
    select pt.id into p_sup from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'S-FAST';
    select pt.id into p_cus from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'C-HARBOUR';

    v_step := 'an order received in a posted goods receipt';
    v_po := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po, i_fg, 20, 4000, 'stock to sell');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'fixture');
    perform erp.transition_document(v_po, 'send', null);
    x := erp.create_receipt_from_order(v_po, null, 'post');
    v_grn := (x ->> 'document_id')::uuid;
    p := public.erp_document(v_grn);

    -- ── 1. A receipt posted and not billed waits for its bill ───────────────
    v_cases := v_cases + 1;
    case_name := 'a goods receipt posted and not yet billed says it waits for the supplier''s bill';
    passed := v_state is null and p -> 'document' ->> 'awaiting' = 'bill'
          and coalesce((p -> 'document' ->> 'is_terminal')::boolean, false);
    detail := coalesce(v_state, format('awaiting %s, state %s', p -> 'document' ->> 'awaiting',
                                       p -> 'document' ->> 'state'));
    return next;

    -- ── 2. Its cut-off says the stock came in ───────────────────────────────
    v_detail := p -> 'amendment' ->> 'detail';
    v_cases := v_cases + 1;
    case_name := 'a posted goods receipt''s cut-off says its stock was received, not that it left';
    passed := v_state is null and p -> 'amendment' ->> 'cut_off' = 'stock_has_moved'
          and v_detail like 'stock has been received against this document%'
          and strpos(v_detail, 'left') = 0;
    detail := coalesce(v_state, v_detail);
    return next;

    -- ── 3. Billed, it waits for nothing; the bill answers its due date ──────
    v_step := 'the supplier''s bill';
    v_bill := erp.bill_from_receipt(v_grn, 'DAW-BILL-1', current_date, null, true);
    select d.due_date into v_due from erp.document d where d.tenant_id = v_tenant and d.id = v_bill;
    p := public.erp_document(v_bill);
    v_cases := v_cases + 1;
    case_name := 'once billed the receipt waits for nothing, and the bill''s page answers the date it falls due';
    passed := v_state is null and erp.document_awaiting(v_grn) is null
          and v_due is not null and (p -> 'document' ->> 'due_date')::date = v_due
          and (p -> 'document') ? 'due_date';
    detail := coalesce(v_state, format('receipt awaiting %s | due %s, page %s', erp.document_awaiting(v_grn),
                                       v_due, p -> 'document' ->> 'due_date'));
    return next;

    -- ── 4. A delivery posted and not invoiced waits to be invoiced ──────────
    v_step := 'an order of the customer''s, delivered';
    v_so := erp.open_document('sales_order', p_cus, v_ent, v_site, 'CUST-PO-77');
    perform erp.add_document_line(v_so, i_fg, 2, 4950, 'sensor');
    perform erp.transition_document(v_so, 'submit', null);
    if erp.document_state_code(v_so) = 'pending_approval' then
      perform erp_test.approve_document(v_so, 'fixture');
    end if;
    begin
      perform erp.release_credit_hold(v_so, 'released for the fixture');
    exception when others then
      null;
    end;
    x := erp.create_delivery_from_order(v_so, null, 'post');
    v_dn := (x ->> 'document_id')::uuid;
    p := public.erp_document(v_dn);
    v_detail := p -> 'amendment' ->> 'detail';
    v_cases := v_cases + 1;
    case_name := 'a delivery posted and not yet invoiced waits to be invoiced, and its cut-off says its stock left';
    passed := v_state is null and p -> 'document' ->> 'awaiting' = 'invoice'
          and v_detail like 'stock has left against this document%';
    detail := coalesce(v_state, format('awaiting %s | %s', p -> 'document' ->> 'awaiting', v_detail));
    return next;

    -- ── 5. Its invoice carries the customer's reference ─────────────────────
    v_step := 'the invoice of the delivery';
    v_inv := erp.invoice_from_delivery(v_dn, true, 'one person despatches and invoices in the suite');
    p := public.erp_document(v_inv);
    v_cases := v_cases + 1;
    case_name := 'the invoice raised from the delivery carries the customer''s reference, and the delivery waits for nothing';
    passed := v_state is null
          and (select d.their_reference from erp.document d where d.tenant_id = v_tenant and d.id = v_dn) = 'CUST-PO-77'
          and p -> 'document' ->> 'their_reference' = 'CUST-PO-77'
          and erp.document_awaiting(v_dn) is null;
    detail := coalesce(v_state, format('invoice ref %s | delivery awaiting %s',
                                       p -> 'document' ->> 'their_reference', erp.document_awaiting(v_dn)));
    return next;

    -- ── 6. A document still moving waits for nothing from another ───────────
    v_wait := erp.document_awaiting(v_inv);
    v_cases := v_cases + 1;
    case_name := 'an invoice, an order and a draft wait for nothing from another document';
    passed := v_state is null and v_wait is null
          and erp.document_awaiting(v_so) is null and erp.document_awaiting(v_po) is null
          and erp.document_awaiting(erp.open_document('purchase_order', p_sup, v_ent, v_site)) is null;
    detail := coalesce(v_state, format('invoice %s | order %s | purchase order %s', v_wait,
                                       erp.document_awaiting(v_so), erp.document_awaiting(v_po)));
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
    raise exception 'CLOVEERP_DOCUMENT_AWAITS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.document_awaits_suite() from public, anon;

comment on function erp_test.document_awaits_suite() is
  'A document says when it falls due and what it waits for (20261010011000): a posted receipt waits for its bill '
  'and says its stock was received, a posted delivery waits for its invoice, the invoice carries the customer''s '
  'reference, and a bill''s page answers its due date.';

create or replace function erp_test.assert_document_awaits_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.document_awaits_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DOCUMENT_AWAITS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A document''s page says something untrue of it: its due date, its reference, its cut-off or what it waits for. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_DOCUMENT_AWAITS_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('document awaits: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_document_awaits_suite() from public, anon;

comment on function erp_test.assert_document_awaits_suite() is
  'A document''s page answers its due date, its customer''s reference, which way its stock moved and what it still '
  'waits for (20261010011000).';

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
