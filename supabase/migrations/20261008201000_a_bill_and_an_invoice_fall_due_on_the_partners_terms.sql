set lock_timeout = '30s';

-- =============================================================================
-- 20261008201000  A bill and an invoice fall due on the partner's terms
-- -----------------------------------------------------------------------------
-- Found building #417 (J-175). A business partner's payment terms are kept in
-- erp.party_role_terms (payment_terms_code, payment_days), and since #417 a
-- person can set them on the partner's page (erp_set_party_payment_terms).
-- Nothing that dates a bill or an invoice read them:
--
--   * erp.bill_from_receipt, and the three other doors that raise a bill
--     (erp.bill_from_consumption, erp.bill_from_shipment,
--     erp.bill_landed_cost), wrote due_date = the bill's date + 30 whatever
--     the supplier's terms said;
--   * a sales invoice was issued (erp.issue_sales_invoice, the one issue door)
--     with no due date at all, whatever the customer's terms said, and the
--     ledger read it as due on its own date.
--
-- The due date is money: the payment run proposes what falls due
-- (erp.propose_payment_run), and the dunning worklist and the credit position
-- age what is owed by it (erp.dunning_worklist, erp.credit_positions). Every
-- one of them reads the subledger item's due date, which posting copies from
-- the document.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.partner_due_date(party, role, company, day): the day a document
--      dated that day falls due on the partner's terms in force that day, in
--      that role (supplier terms for a bill, customer terms for an invoice).
--      The terms kept with the document's company come first. Net terms add
--      their days to the date; end-of-month terms add them to the last day of
--      its month. No terms in force, or terms cleared, answer nothing.
--   B. The four bill doors date a bill's due date from the supplier's terms
--      in force on the bill's date. A due date the person typed still wins,
--      and with no terms kept it is the bill's date + 30, as before.
--   C. erp.issue_sales_invoice dates a draft invoice's due date from the
--      customer's terms in force on the invoice's date, just before the issue
--      move posts it, so the ledger's item carries the same date. A due date
--      already written on the invoice is kept, and with no terms kept it is
--      issued with none, as before.
--   D. erp_test.partner_terms_due_date_suite proves both sides, the terms in
--      force on the date, a document issued before the terms change and one
--      issued before this change, and that the payment run and the dunning
--      worklist read the dates the terms give.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- A document already issued or registered is never re-dated: only a bill
-- being raised and a draft invoice being issued are dated here, and nothing
-- reads the terms again afterwards. An invoice already issued and not yet
-- numbered is numbered as it stands. The demonstration's own history dates
-- its documents itself and is unchanged. Who may raise, register or issue is
-- unchanged.
--
-- On production: five functions are replaced and one added. No table is
-- altered, and no existing document or ledger item of any organisation is
-- changed; the terms are read only for bills raised and invoices issued from
-- now on.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The rule
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.partner_due_date(
  p_party_id  uuid,
  p_role      text,
  p_entity_id uuid,
  p_on        date)
returns date
language sql
stable
set search_path = ''
as $$
  -- The day a document dated p_on falls due on the partner's terms in force
  -- that day, in that role (20261008201000). The row in force is the one
  -- erp.set_party_payment_terms writes: begun on or before the day, not yet
  -- ended, the latest begun; the document's own company's first. A row in
  -- force whose terms were cleared answers nothing, as no row does: the
  -- caller keeps its own default.
  select case when pt.day_basis = 'end_of_month'
              then (date_trunc('month', p_on::timestamp) + interval '1 month')::date - 1 + t.days
              else p_on + t.days
         end
    from (select coalesce(x.payment_days::integer, pt0.net_days) as days,
                 x.payment_terms_code as code
            from erp.party_role pr
            join erp.party_role_terms x
              on x.tenant_id = pr.tenant_id and x.party_role_id = pr.id
            left join erp_ref.payment_term pt0 on pt0.code = x.payment_terms_code
           where pr.tenant_id = erp.require_tenant_id()
             and pr.party_id = p_party_id
             and pr.role_kind::text = p_role
             and pr.status = 'active'
             and x.valid_from <= p_on
             and (x.valid_to is null or x.valid_to > p_on)
           order by (x.entity_id = p_entity_id) desc nulls last,
                    x.valid_from desc, x.created_at desc, x.id
           limit 1) t
    left join erp_ref.payment_term pt on pt.code = t.code
   where t.days is not null
$$;

revoke all on function erp.partner_due_date(uuid, text, uuid, date) from public, anon;

comment on function erp.partner_due_date(uuid, text, uuid, date) is
  'The day a document dated p_on falls due on the business partner''s payment terms in force that day, in the role '
  'given (supplier for a bill, customer for an invoice), the document''s company''s terms first; end-of-month terms '
  'count from the month''s last day. Null when no terms are kept (20261008201000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The four bill doors
-- ─────────────────────────────────────────────────────────────────────────────

do $bills$
declare
  r      record;
  v_src  text;
  v_def  text;
  v_old  constant text := $o$         due_date = coalesce(p_due_date, v_date + 30),$o$;
  v_new  text;
begin
  for r in
    select * from (values
      ('erp.bill_from_receipt(uuid,text,date,date,boolean,bigint,text)',
       '6fe6b4d9f04a14f5f9db6ca41e64f433', 'rd.party_id', 'rd.entity_id'),
      ('erp.bill_from_consumption(uuid,uuid,date,text,date,date,jsonb,boolean,bigint,text)',
       'b798977c4798405b60e0db2e76d0c324', 'p_supplier', 'v_entity'),
      ('erp.bill_from_shipment(uuid,text,bigint,bigint,text,date,date)',
       '552dcb5d9a8cd7b0c415f97c2f568403', 'v_party', 'sh.entity_id'),
      ('erp.bill_landed_cost(uuid,uuid,text,bigint,text,bigint,text,date,date)',
       '6916ff1cdc1f8cc3215cfe23a233456b', 'p_party_id', 'rc.entity_id')
    ) v(sig, digest, party, entity)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if strpos(v_src, '20261008201000') > 0 then
      raise notice '% already dates the bill on the supplier''s terms; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.digest then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261008201000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', r.sig;
    end if;
    v_new := format($n$         -- Due on the supplier's terms in force on the bill's date, unless
         -- the person gave the date; thirty days only where no terms are
         -- kept (20261008201000).
         due_date = coalesce(p_due_date,
                             erp.partner_due_date(%s, 'supplier', %s, v_date),
                             v_date + 30),$n$, r.party, r.entity);
    execute replace(v_def, v_old, v_new);
  end loop;
end
$bills$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The issue door
-- ─────────────────────────────────────────────────────────────────────────────

do $issue$
declare
  v_sig  constant text := 'erp.issue_sales_invoice(uuid,uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      perform erp.transition_document(p_document_id, 'issue', 'Issued with its number');$o$;
  v_new  constant text := $n$      -- Due on the customer's terms in force on the invoice's date, unless
      -- a due date is already written on it (20261008201000). Set while it
      -- is a draft, before the move posts it, so the ledger's item carries
      -- the same date. An invoice already issued is never re-dated.
      update erp.document x
         set due_date = erp.partner_due_date(x.party_id, 'customer', x.entity_id,
                                             coalesce(x.document_date, current_date)),
             updated_at = now()
       where x.tenant_id = v_tenant and x.id = p_document_id and x.due_date is null
         and erp.partner_due_date(x.party_id, 'customer', x.entity_id,
                                  coalesce(x.document_date, current_date)) is not null;
      perform erp.transition_document(p_document_id, 'issue', 'Issued with its number');$n$;
begin
  if strpos(v_src, '20261008201000') > 0 then
    raise notice '% already dates the invoice on the customer''s terms; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd14e3161d38d3b19d001b760ffef7128' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261008201000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$issue$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.partner_terms_due_date_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid;
  v_s7 uuid; v_s0 uuid; v_sboth uuid; v_schg uuid; v_seom uuid;
  v_c45 uuid; v_c0 uuid; v_c7 uuid; v_cold uuid;
  v_b7 uuid; v_b0 uuid; v_bboth uuid; v_btyped uuid; v_bold uuid; v_bnew uuid; v_beom uuid;
  v_i45 uuid; v_i0 uuid; v_i7 uuid; v_iold uuid;
  v_eom_day date; v_eom_due date;
  v_run uuid;
  v_d1 date; v_d2 date; v_d3 date; v_d4 date;
  v_n integer;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation set up to buy and sell';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzptd-' || v_tag, 'Partner Terms Due Date Suite',
      'admin@zzptd-' || v_tag || '.test', 'Terms Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzptd-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select e.id into v_entity from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPTDBOX', 'Box bought and sold on terms', v_uom, 'active') returning id into v_item;

    -- What an invoice needs before it can be issued by hand.
    update erp.entity set registration_number = coalesce(nullif(btrim(registration_number), ''), '07123456')
     where tenant_id = rb.tenant_id and id = v_entity;
    insert into erp.party_address (tenant_id, party_id, address_kind, label, lines, locality, postcode, country_code, is_default)
    select rb.tenant_id, e.party_id, 'registered', 'Registered office', array['1 Ledger Way'], 'Leeds', 'LS1 1AA', 'GB', true
      from erp.entity e
     where e.tenant_id = rb.tenant_id and e.id = v_entity
       and not exists (select 1 from erp.party_address x
                        where x.tenant_id = e.tenant_id and x.party_id = e.party_id and x.address_kind = 'registered');

    -- Suppliers: Net 7; none kept; a customer on Net 90 who also supplies,
    -- with no supplier terms; Net 60 until ten days ago and Net 14 since;
    -- end of month plus 30.
    v_s7    := erp_test.cash_payment_supplier('ZPTD-S7');
    v_s0    := erp_test.cash_payment_supplier('ZPTD-S0');
    v_sboth := erp_test.cash_payment_supplier('ZPTD-SB');
    v_schg  := erp_test.cash_payment_supplier('ZPTD-SC');
    v_seom  := erp_test.cash_payment_supplier('ZPTD-SE');
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sboth, 'customer', 'active');

    -- Customers: Net 45; none kept; Net 7; Net 45 for the invoice issued
    -- before this change.
    insert into erp.party (tenant_id, code, name, legal_name, status) values
      (rb.tenant_id, 'ZPTD-C45', 'Customer on Net 45', 'Customer 45 Ltd', 'active'),
      (rb.tenant_id, 'ZPTD-C0',  'Customer with no terms', 'Customer 0 Ltd', 'active'),
      (rb.tenant_id, 'ZPTD-C7',  'Customer on Net 7', 'Customer 7 Ltd', 'active'),
      (rb.tenant_id, 'ZPTD-CO',  'Customer invoiced before', 'Customer Old Ltd', 'active');
    select p.id into v_c45  from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'ZPTD-C45';
    select p.id into v_c0   from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'ZPTD-C0';
    select p.id into v_c7   from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'ZPTD-C7';
    select p.id into v_cold from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'ZPTD-CO';
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    select rb.tenant_id, x, 'customer', 'active' from unnest(array[v_c45, v_c0, v_c7, v_cold]) x;
    insert into erp.party_address (tenant_id, party_id, address_kind, label, lines, locality, postcode, country_code, is_default)
    select rb.tenant_id, x, 'billing', 'Invoice to', array['2 Buyer Street'], 'York', 'YO1 1AA', 'GB', true
      from unnest(array[v_c45, v_c0, v_c7, v_cold]) x;

    -- Terms set as a person sets them, then dated back a year, so they are
    -- in force on the back-dated documents below.
    v_step := 'the partners'' terms set on their pages';
    perform public.erp_set_party_payment_terms(v_s7,    'supplier', 'NET7');
    perform public.erp_set_party_payment_terms(v_sboth, 'customer', 'NET90');
    perform public.erp_set_party_payment_terms(v_seom,  'supplier', 'EOM30');
    perform public.erp_set_party_payment_terms(v_c45,   'customer', 'NET45');
    perform public.erp_set_party_payment_terms(v_c7,    'customer', 'NET7');
    perform public.erp_set_party_payment_terms(v_cold,  'customer', 'NET45');
    update erp.party_role_terms x set valid_from = current_date - 400
     where x.tenant_id = rb.tenant_id and x.valid_from = current_date
       and x.party_role_id in (select pr.id from erp.party_role pr
                                where pr.tenant_id = rb.tenant_id
                                  and pr.party_id in (v_s7, v_sboth, v_seom, v_c45, v_c7, v_cold));
    insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, currency, payment_terms_code,
                                      payment_days, valid_from, valid_to)
    select rb.tenant_id, pr.id, v_entity, 'GBP', t.code, t.days, t.f, t.u
      from erp.party_role pr
     cross join (values ('NET60', 60::smallint, current_date - 400, current_date - 10),
                        ('NET14', 14::smallint, current_date - 10, null::date)) t(code, days, f, u)
     where pr.tenant_id = rb.tenant_id and pr.party_id = v_schg and pr.role_kind = 'supplier';

    -- ── 1. A bill on Net 7 ──────────────────────────────────────────────────
    v_step := 'a bill raised from a goods receipt for the supplier on Net 7';
    v_b7 := erp_test.partner_terms_bill(v_entity, v_site, v_item, v_s7, 'ZPTD-B7', current_date - 3, null);
    v_cases := v_cases + 1;
    case_name := 'a bill from a goods receipt for a supplier on Net 7 is due seven days after its date, on the bill and on the ledger';
    v_d1 := (select d.due_date from erp.document d where d.id = v_b7);
    v_d2 := (select si.due_date from erp.subledger_item si
              where si.tenant_id = rb.tenant_id and si.document_id = v_b7 and si.control_kind = 'payable');
    passed := coalesce(v_state is null and v_d1 = current_date + 4 and v_d2 = v_d1, false);
    detail := coalesce(v_state, format('bill due %s, ledger due %s, expected %s', v_d1, v_d2, current_date + 4));
    return next;

    -- ── 2. No supplier terms: thirty days, as before ────────────────────────
    v_step := 'bills for a supplier with no terms, and for a customer who also supplies';
    v_b0    := erp_test.partner_terms_bill(v_entity, v_site, v_item, v_s0,    'ZPTD-B0', current_date - 3, null);
    v_bboth := erp_test.partner_terms_bill(v_entity, v_site, v_item, v_sboth, 'ZPTD-BB', current_date - 3, null);
    v_cases := v_cases + 1;
    case_name := 'a bill for a supplier with no terms kept is due thirty days after its date, as before, and a customer''s terms never date a bill';
    v_d1 := (select d.due_date from erp.document d where d.id = v_b0);
    v_d2 := (select d.due_date from erp.document d where d.id = v_bboth);
    passed := coalesce(v_state is null and v_d1 = current_date + 27 and v_d2 = current_date + 27, false);
    detail := coalesce(v_state, format('no terms %s, customer on Net 90 who supplies %s, expected %s',
                                       v_d1, v_d2, current_date + 27));
    return next;

    -- ── 3. A due date typed wins ────────────────────────────────────────────
    v_step := 'a bill for the supplier on Net 7 with its due date typed';
    v_btyped := erp_test.partner_terms_bill(v_entity, v_site, v_item, v_s7, 'ZPTD-BT', current_date - 3, current_date + 50);
    v_cases := v_cases + 1;
    case_name := 'a due date the person gives is kept over the supplier''s terms';
    v_d1 := (select d.due_date from erp.document d where d.id = v_btyped);
    passed := coalesce(v_state is null and v_d1 = current_date + 50, false);
    detail := coalesce(v_state, format('due %s, typed %s', v_d1, current_date + 50));
    return next;

    -- ── 4. The terms in force on the bill's date ────────────────────────────
    v_step := 'bills dated before and after the supplier''s terms changed';
    v_bold := erp_test.partner_terms_bill(v_entity, v_site, v_item, v_schg, 'ZPTD-BO', current_date - 20, null);
    v_bnew := erp_test.partner_terms_bill(v_entity, v_site, v_item, v_schg, 'ZPTD-BN', current_date, null);
    v_cases := v_cases + 1;
    case_name := 'the terms read are those in force on the bill''s date: Net 60 before they changed, Net 14 after';
    v_d1 := (select d.due_date from erp.document d where d.id = v_bold);
    v_d2 := (select d.due_date from erp.document d where d.id = v_bnew);
    passed := coalesce(v_state is null and v_d1 = current_date + 40 and v_d2 = current_date + 14, false);
    detail := coalesce(v_state, format('dated 20 days ago due %s (expected %s); dated today due %s (expected %s)',
                                       v_d1, current_date + 40, v_d2, current_date + 14));
    return next;

    -- ── 5. End of month ─────────────────────────────────────────────────────
    v_step := 'a bill for the supplier on end of month plus 30';
    v_eom_day := (date_trunc('month', (current_date - 40)::timestamp) + interval '9 days')::date;
    v_eom_due := (date_trunc('month', v_eom_day::timestamp) + interval '1 month')::date - 1 + 30;
    v_beom := erp_test.partner_terms_bill(v_entity, v_site, v_item, v_seom, 'ZPTD-BE', v_eom_day, null);
    v_cases := v_cases + 1;
    case_name := 'end of month terms count their days from the last day of the bill''s month';
    v_d1 := (select d.due_date from erp.document d where d.id = v_beom);
    passed := coalesce(v_state is null and v_d1 = v_eom_due, false);
    detail := coalesce(v_state, format('dated %s, due %s, expected %s', v_eom_day, v_d1, v_eom_due));
    return next;

    -- ── 6. An invoice on Net 45 ─────────────────────────────────────────────
    v_step := 'an invoice issued to the customer on Net 45';
    v_i45 := erp_test.partner_terms_invoice(v_c45, v_entity, v_site, v_item, current_date - 2, true);
    v_cases := v_cases + 1;
    case_name := 'an invoice issued to a customer on Net 45 is due forty-five days after its date, on the invoice, the ledger and the issued contract';
    v_d1 := (select d.due_date from erp.document d where d.id = v_i45);
    v_d2 := (select si.due_date from erp.subledger_item si
              where si.tenant_id = rb.tenant_id and si.document_id = v_i45 and si.control_kind = 'receivable');
    v_d3 := (select (di.contract_snapshot #>> '{header,due_date}')::date from erp.document_issue di
              where di.tenant_id = rb.tenant_id and di.source_document_id = v_i45);
    passed := coalesce(v_state is null and v_d1 = current_date + 43 and v_d2 = v_d1 and v_d3 = v_d1, false);
    detail := coalesce(v_state, format('invoice %s, ledger %s, contract %s, expected %s', v_d1, v_d2, v_d3, current_date + 43));
    return next;

    -- ── 7. No customer terms: none, as before ───────────────────────────────
    v_step := 'an invoice issued to the customer with no terms';
    v_i0 := erp_test.partner_terms_invoice(v_c0, v_entity, v_site, v_item, current_date - 2, true);
    v_cases := v_cases + 1;
    case_name := 'an invoice issued to a customer with no terms kept is issued with no due date, as before';
    v_d1 := (select d.due_date from erp.document d where d.id = v_i0);
    v_d2 := (select si.due_date from erp.subledger_item si
              where si.tenant_id = rb.tenant_id and si.document_id = v_i0 and si.control_kind = 'receivable');
    passed := coalesce(v_state is null and v_d1 is null and v_d2 is null
          and exists (select 1 from erp.subledger_item si
                       where si.tenant_id = rb.tenant_id and si.document_id = v_i0 and si.control_kind = 'receivable'), false);
    detail := coalesce(v_state, format('invoice %s, ledger %s', coalesce(v_d1::text, 'none'), coalesce(v_d2::text, 'none')));
    return next;

    -- ── 8. Terms changed later re-date nothing ──────────────────────────────
    v_step := 'the customer''s and the supplier''s terms changed after the invoice and the bill';
    perform public.erp_set_party_payment_terms(v_c45, 'customer', 'NET7');
    perform public.erp_set_party_payment_terms(v_s7,  'supplier', 'NET60');
    v_cases := v_cases + 1;
    case_name := 'terms changed after an invoice is issued and a bill registered change neither due date, on the document or the ledger';
    v_d1 := (select d.due_date from erp.document d where d.id = v_i45);
    v_d2 := (select si.due_date from erp.subledger_item si
              where si.tenant_id = rb.tenant_id and si.document_id = v_i45 and si.control_kind = 'receivable');
    v_d3 := (select d.due_date from erp.document d where d.id = v_b7);
    v_d4 := (select si.due_date from erp.subledger_item si
              where si.tenant_id = rb.tenant_id and si.document_id = v_b7 and si.control_kind = 'payable');
    passed := coalesce(v_state is null
          and v_d1 = current_date + 43 and v_d2 = v_d1
          and v_d3 = current_date + 4 and v_d4 = v_d3
          and (select x.payment_days from erp.party_role_terms x
                 join erp.party_role pr on pr.id = x.party_role_id
                where pr.tenant_id = rb.tenant_id and pr.party_id = v_c45 and pr.role_kind = 'customer'
                  and x.valid_from <= current_date and (x.valid_to is null or x.valid_to > current_date)
                order by x.valid_from desc limit 1) = 7, false);
    detail := coalesce(v_state, format('invoice %s / %s (expected %s); bill %s / %s (expected %s)',
                                       v_d1, v_d2, current_date + 43, v_d3, v_d4, current_date + 4));
    return next;

    -- ── 9. Issued before this change, numbered after ────────────────────────
    -- The issue move made before this change, with no due date, as it was;
    -- the door then numbers it as it stands.
    v_step := 'an invoice issued before the change and numbered after it';
    v_iold := erp_test.partner_terms_invoice(v_cold, v_entity, v_site, v_item, current_date - 2, false);
    perform erp.transition_document(v_iold, 'issue', 'issued before the terms were read');
    perform erp.issue_sales_invoice(v_iold);
    v_cases := v_cases + 1;
    case_name := 'an invoice already issued before the terms were read is numbered as it stands, and is not re-dated';
    v_d1 := (select d.due_date from erp.document d where d.id = v_iold);
    v_d2 := (select si.due_date from erp.subledger_item si
              where si.tenant_id = rb.tenant_id and si.document_id = v_iold and si.control_kind = 'receivable');
    passed := coalesce(v_state is null and v_d1 is null and v_d2 is null
          and exists (select 1 from erp.document_issue di
                       where di.tenant_id = rb.tenant_id and di.source_document_id = v_iold), false);
    detail := coalesce(v_state, format('invoice %s, ledger %s', coalesce(v_d1::text, 'none'), coalesce(v_d2::text, 'none')));
    return next;

    -- ── 10. What reads the due date ─────────────────────────────────────────
    -- A payment run for the week takes the bill due in four days and not the
    -- one due in forty; the dunning worklist chases the customer on Net 7
    -- invoiced thirty days ago, overdue by twenty-three.
    v_step := 'a payment run proposed for the week, and the dunning worklist';
    v_i7 := erp_test.partner_terms_invoice(v_c7, v_entity, v_site, v_item, current_date - 30, true);
    v_run := erp.propose_payment_run(current_date, null, interval '7 days');
    select o.oldest_days into v_n from erp.dunning_worklist() o where o.party_id = v_c7;
    v_cases := v_cases + 1;
    case_name := 'the payment run and the dunning worklist read the dates the terms give';
    passed := coalesce(v_state is null
          and exists (select 1 from erp.payment_proposal_line l
                       where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run
                         and l.document_id = v_b7 and l.due_date = current_date + 4)
          and not exists (select 1 from erp.payment_proposal_line l
                           where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run
                             and l.document_id in (v_bold, v_b0))
          and v_n = 23, false);
    detail := coalesce(v_state, format('run takes the Net 7 bill on %s line(s), the Net 60 and no-terms bills on %s; the Net 7 customer is %s day(s) overdue',
      (select count(*) from erp.payment_proposal_line l
        where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run and l.document_id = v_b7),
      (select count(*) from erp.payment_proposal_line l
        where l.tenant_id = rb.tenant_id and l.payment_proposal_id = v_run and l.document_id in (v_bold, v_b0)),
      coalesce(v_n::text, 'not')));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  -- ── 11. Undone ────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := coalesce(not exists (select 1 from erp.tenant where code = 'zzptd-' || v_tag)
        and v_state is null, false);
  detail := coalesce('the fixture stopped early: ' || v_state,
                     'the organisation rolled back with its partners, bills and invoices');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PARTNER_TERMS_DUE_DATE_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_state, 'a case was added or lost');
  end if;
end;
$$;

revoke all on function erp_test.partner_terms_due_date_suite() from public, anon;

comment on function erp_test.partner_terms_due_date_suite() is
  'A bill and an invoice fall due on the partner''s terms (20261008201000): supplier terms date a bill, customer terms '
  'an invoice, the terms in force on the document''s date, end of month counted from the month''s end, a typed date '
  'kept, no terms as before, nothing issued re-dated, and the payment run and dunning read the dates.';

create or replace function erp_test.partner_terms_bill(
  p_entity uuid, p_site uuid, p_item uuid, p_supplier uuid, p_ref text, p_date date, p_due date)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_po  uuid;
  v_pol uuid;
  v_grn uuid;
begin
  -- A bill registered from a goods receipt of one order, dated p_date, with
  -- the due date given or none (20261008201000).
  v_po := erp_test.prepayment_order(p_entity, p_site, p_item, p_supplier, 2, 1000, p_ref);
  select l.id into v_pol from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;
  v_grn := erp.open_document('goods_receipt', p_supplier, p_entity, p_site);
  perform erp.receive_against(v_grn, v_pol, 2, null);
  perform erp.transition_document(v_grn, 'post', null);
  return erp.bill_from_receipt(v_grn, p_ref || '-BILL', p_date, p_due, true);
end;
$$;

revoke all on function erp_test.partner_terms_bill(uuid, uuid, uuid, uuid, text, date, date) from public, anon;

comment on function erp_test.partner_terms_bill(uuid, uuid, uuid, uuid, text, date, date) is
  'Fixture for erp_test.partner_terms_due_date_suite (20261008201000): a bill registered from a goods receipt of one '
  'order, on the date given, with the due date given or none.';

create or replace function erp_test.partner_terms_invoice(
  p_customer uuid, p_entity uuid, p_site uuid, p_item uuid, p_date date, p_issue boolean)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_inv    uuid;
begin
  -- A sales invoice of one zero-rated line, dated p_date with its tax point
  -- that day, issued through the issue door when asked (20261008201000).
  v_inv := erp.open_document('sales_invoice', p_customer, p_entity, p_site);
  perform erp.add_document_line(v_inv, p_item, 1, 10000, 'box');
  update erp.document
     set document_date = p_date, tax_point = p_date
   where tenant_id = v_tenant and id = v_inv;
  update erp.document_line
     set net_minor = 10000, tax_code = 'Z', tax_rate_pct = 0, tax_minor = 0
   where tenant_id = v_tenant and document_id = v_inv;
  if p_issue then
    perform erp.issue_sales_invoice(v_inv);
  end if;
  return v_inv;
end;
$$;

revoke all on function erp_test.partner_terms_invoice(uuid, uuid, uuid, uuid, date, boolean) from public, anon;

comment on function erp_test.partner_terms_invoice(uuid, uuid, uuid, uuid, date, boolean) is
  'Fixture for erp_test.partner_terms_due_date_suite (20261008201000): a zero-rated sales invoice of one line, dated '
  'and tax-pointed on the day given, issued through erp.issue_sales_invoice when asked.';

create or replace function erp_test.assert_partner_terms_due_date_suite()
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
    from erp_test.partner_terms_due_date_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PARTNER_TERMS_DUE_DATE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A bill or an invoice fell due on a date the partner''s terms do not give. Read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_PARTNER_TERMS_DUE_DATE_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('partner terms due date: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_partner_terms_due_date_suite() from public, anon;

comment on function erp_test.assert_partner_terms_due_date_suite() is
  'A bill falls due on the supplier''s terms and an invoice on the customer''s, in force on its date, and nothing '
  'issued is re-dated (20261008201000).';

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
