set lock_timeout = '30s';

-- =============================================================================
-- 20260930300000  The cash documents have their screens
-- -----------------------------------------------------------------------------
-- PR13 M4 (docs/spec/simplification-review.md §7 Finance, node F5): the
-- screens of the cash receipt (20260930000000, 20260930100000) and the
-- supplier payment (20260930200000).
--
-- ── WHAT CHANGES, AND WHERE ──────────────────────────────────────────────────
--
-- The screens (no door changes, no new public function):
--   * The Cash in step of /finance lists the receipts Apply cash and the
--     settlement statements open, posted, by customer, and still offers Apply
--     cash. It offers no New: nobody opens a receipt by hand.
--   * Apply cash says the receipt it made, "RCPT-000012: £600.00 applied to 1
--     open invoice and £100.00 on account", and links to it. The rows already
--     name it (document_id); its number is read from erp_document.
--   * Paying a run names the payment each supplier was sent, from the answer's
--     payments, and links to each.
--   * A supplier payment's page prints its remittance advice through
--     erp_render_remittance_advice, for somebody who holds finance.post, as a
--     count sheet prints. A cash document's page offers no New, Add line,
--     Reprice, Amend or approval stamp, and its Posted reads done.
-- This migration is what those screens need of the database:
--   * erp_render_remittance_advice has a screen, so its row in
--     erp_meta.api_only_door, waiting for one (20260930200000), goes.
--   * The money row of erp_meta.flow_budget keeps its budget of nine: Cash in
--     gains a list and no verb, so one step of seven keeps no list, where two
--     did. The row is restated with the reason.
--   * The one new screen word, seeded in English.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No door, table, lifecycle, refusal or register row beyond the two above.
--   * No step: the strip draws the same nine verbs over the same seven steps.
--   * The remittance advice's help action stays on /finance, where the Pay
--     step's outcome links to the payment.
--
-- Proved by erp_test.cash_documents_screens_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. What the screens need of the registers
-- ═════════════════════════════════════════════════════════════════════════════

-- A1. The remittance advice has a screen: the payment's page.

do $remittance_home$
declare
  v_n integer;
begin
  delete from erp_meta.api_only_door d
   where d.function_name = 'erp_render_remittance_advice'
     and d.caller = 'pending_screen'
     and d.intended_screen_path = '/finance';
  get diagnostics v_n = row_count;
  if v_n = 1 then
    return;
  end if;
  if exists (select 1 from erp_meta.api_only_door d
              where d.function_name = 'erp_render_remittance_advice') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp_render_remittance_advice is registered, but not as the pending /finance screen 20260930200000 wrote';
  end if;
  raise notice 'erp_render_remittance_advice already has its screen; left as it is';
end
$remittance_home$;

-- A2. The money cycle's budget says the Cash in step keeps a list

do $money_budget$
declare
  v_n integer;
begin
  if exists (select 1 from erp_meta.flow_budget b
              where b.flow_code = 'money' and position('20260930300000' in b.rationale) > 0) then
    raise notice 'the money budget already says Cash in keeps a list; left as it is';
    return;
  end if;
  update erp_meta.flow_budget b
     set stages_without_a_list = 1,
         rationale =
       'The nine actions over seven steps are what the Finance screen''s strip draws. The period close '
       'is not on the strip, and is walked by erp_test.step_budget_suite at two presses a month, open '
       'and close, for every ledger of the company together: opening runs every check and completes '
       'the checklist, closing asks the checks again and closes GL and COMMIT at one moment. A task that '
       'fails its check is one press more, to waive it with a reason (20260929200000). Cash in lists the '
       'receipts Apply cash opens, and adds no verb; Journals is a screen of its own and keeps no list '
       '(20260930300000).'
   where b.flow_code = 'money'
     and b.budget = 9 and b.decision_steps = 9 and b.stages = 7 and b.stages_without_a_list = 2
     and b.rationale =
       'The nine actions over seven steps are what the Finance screen''s strip draws. The period close '
       'is not on the strip, and is walked by erp_test.step_budget_suite at two presses a month, open '
       'and close, for every ledger of the company together: opening runs every check and completes '
       'the checklist, closing asks the checks again and closes GL and COMMIT at one moment. A task that '
       'fails its check is one press more, to waive it with a reason (20260929200000).';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the money flow budget is not 9/9/7/2 with the rationale 20260929200000 wrote (% row(s))', v_n;
  end if;
end
$money_budget$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.cash_documents_screens_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3); v_item uuid;
  v_inv uuid; v_cust uuid; v_gross bigint;
  v_rows jsonb; v_rcpt uuid; v_line uuid;
  v_listed jsonb; v_doc jsonb; v_moves jsonb;
  v_sa uuid; v_sb uuid; v_ba uuid; v_bb uuid;
  v_pay jsonb; v_pmt uuid; v_render jsonb;
  v_err text; v_err2 text; v_err3 text;
  v_n integer;
begin
  begin
    -- ── The fixture: an organisation configured as the demonstration is ─────
    v_step := 'an organisation that invoices, banks receipts and pays its suppliers';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcds-' || v_tag, 'Cash Documents Screens Suite',
      'admin@zzcds-' || v_tag || '.test', 'Cash Screens Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzcds-' || v_tag || '.test'),
           (a2, 'second@zzcds-' || v_tag || '.test'),
           (s_read, 'reader@zzcds-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'a second administrator, who approves and pays what the first proposes';
    res := public.erp_invite_principal('second@zzcds-' || v_tag || '.test', 'Cash Screens Second');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'a person who may read the books but not pay';
    res := public.erp_invite_principal('reader@zzcds-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit and product';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZDMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZDEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZDWID', 'Cash Screens Widget', v_uom, 'active') returning id into v_item;

    -- ── 1. What the strip counts ────────────────────────────────────────────
    v_step := 'the registers the strip and the payment''s page are held to';
    v_cases := v_cases + 1;
    case_name := 'the money cycle is nine actions over seven steps with one keeping no list, and the remittance advice waits for no screen';
    passed := v_state is null
          and exists (select 1 from erp_meta.flow_budget b
                       where b.flow_code = 'money' and b.budget = 9 and b.decision_steps = 9
                         and b.stages = 7 and b.stages_without_a_list = 1
                         and position('20260930300000' in b.rationale) > 0)
          and not exists (select 1 from erp_meta.api_only_door d
                           where d.function_name = 'erp_render_remittance_advice');
    detail := coalesce(v_state, (select format('%s/%s/%s/%s', b.budget, b.decision_steps, b.stages,
                                                b.stages_without_a_list)
                                   from erp_meta.flow_budget b where b.flow_code = 'money'));
    return next;

    -- ── 2. Apply cash names the receipt it made ─────────────────────────────
    v_step := 'an invoice paid, and £100 more kept on the customer''s account';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZDS2', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select jsonb_agg(to_jsonb(x)) into v_rows
      from public.erp_apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZDS2-PAID') x;
    v_rcpt := (v_rows -> 0 ->> 'document_id')::uuid;
    v_doc := public.erp_document(v_rcpt);
    v_cases := v_cases + 1;
    case_name := 'every row Apply cash answers names the one receipt it made, and the receipt''s page reads its number, customer, Posted, and a line of the cash per invoice and one kept on account';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 2
          and (select count(distinct r ->> 'document_id') from jsonb_array_elements(v_rows) r) = 1
          and not exists (select 1 from jsonb_array_elements(v_rows) r where r ->> 'document_id' is null)
          and v_doc #>> '{document,document_number}' = 'RCPT-000001'
          and v_doc #>> '{document,document_type}' = 'cash_receipt'
          and v_doc #>> '{document,party}' = (select p.name from erp.party p where p.id = v_cust)
          and v_doc #>> '{document,state}' = 'posted'
          and (v_doc #>> '{document,is_committed}')::boolean = false
          and (v_doc #>> '{document,total_minor}')::bigint = v_gross + 10000
          and jsonb_array_length(v_doc -> 'lines') = 2;
    detail := coalesce(v_state, left(format('rows %s; document %s', v_rows, v_doc -> 'document'), 400));
    return next;

    -- ── 3. The Cash in step lists it ────────────────────────────────────────
    v_step := 'the Cash in step''s read';
    v_listed := public.erp_documents('cash_receipt', 200, false, false, null, array['posted']);
    v_cases := v_cases + 1;
    case_name := 'the Cash in step''s read, posted receipts, lists the receipt with its customer, and a sales invoice''s read does not';
    passed := v_state is null
          and jsonb_array_length(v_listed) = 1
          and v_listed -> 0 ->> 'document_id' = v_rcpt::text
          and v_listed -> 0 ->> 'party' = (select p.name from erp.party p where p.id = v_cust)
          and v_listed -> 0 ->> 'state' = 'posted'
          and not exists (select 1
                            from jsonb_array_elements(public.erp_documents('sales_invoice', 200, false, false, null, null)) x
                           where x ->> 'document_id' = v_rcpt::text);
    detail := coalesce(v_state, left(v_listed::text, 400));
    return next;

    -- ── 4. The receipt's page offers nothing ────────────────────────────────
    v_step := 'what the receipt''s page and the Cash in step do not offer';
    v_moves := public.erp_available_transitions(v_rcpt);
    select l.id into v_line from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_rcpt order by l.line_no limit 1;
    begin
      perform public.erp_create_document_full('cash_receipt', v_cust, null, 'by hand', null, v_ccy, '[]'::jsonb, null);
      v_err := 'opened';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_add_document_line(v_rcpt, v_item, 1, 100, null);
      v_err2 := 'added';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_transition_document(v_rcpt, 'post', null);
      v_err3 := 'moved';
    exception when others then v_err3 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a posted receipt has no move to offer, and the New, Add line and Post a screen does not draw are refused to an administrator by name';
    passed := v_state is null
          and v_moves = '[]'::jsonb
          and v_err like 'CLOVEERP_CASH_DOCUMENT_IS_RAISED:%'
          and v_err2 like 'CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH:%'
          and v_err3 like 'CLOVEERP_%'
          and (select count(*) from erp.document_line l
                where l.tenant_id = rb.tenant_id and l.document_id = v_rcpt) = 2;
    detail := coalesce(v_state, left(format('moves %s; open: %s; line: %s; post: %s', v_moves, v_err, v_err2, v_err3), 500));
    return next;

    -- ── 5. Paying a run names each supplier's payment ───────────────────────
    v_step := 'two bills of two suppliers, paid in one run';
    v_sa := erp_test.cash_payment_supplier('ZDA');
    v_sb := erp_test.cash_payment_supplier('ZDB');
    v_ba := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sa, 20000, 'ZDA-INV-1');
    v_bb := erp_test.cash_payment_bill(v_entity, v_site, v_item, v_sb, 30000, 'ZDB-INV-1');
    v_pay := erp_test.cash_payment_run(array[v_ba, v_bb], a1, a2);
    select count(*) into v_n
      from jsonb_array_elements(v_pay -> 'payments') p
      join erp.document d on d.id = (p ->> 'document_id')::uuid
      join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.code = 'cash_payment'
       and d.document_number = p ->> 'document_number'
       and d.party_id = (p ->> 'party_id')::uuid
       and public.erp_document(d.id) #>> '{document,state}' = 'posted'
       and (public.erp_document(d.id) #>> '{document,total_minor}')::bigint = (p ->> 'paid_minor')::bigint
       and public.erp_available_transitions(d.id) = '[]'::jsonb;
    v_pmt := (v_pay #>> '{payments,0,document_id}')::uuid;
    v_cases := v_cases + 1;
    case_name := 'the Pay step''s answer lists a payment per supplier, each with the number, supplier and total its page reads, Posted, with no move to offer';
    passed := v_state is null
          and jsonb_array_length(v_pay -> 'payments') = 2
          and v_n = 2
          and (select string_agg(p ->> 'document_number', ',' order by p ->> 'document_number')
                 from jsonb_array_elements(v_pay -> 'payments') p) = 'PMT-000001,PMT-000002'
          and (v_pay ->> 'paid_minor')::bigint
              = (select sum((p ->> 'paid_minor')::bigint) from jsonb_array_elements(v_pay -> 'payments') p);
    detail := coalesce(v_state, left(v_pay::text, 400));
    return next;

    -- ── 6. The payment's page prints its remittance advice ──────────────────
    v_step := 'the remittance advice, printed from the payment''s page by somebody who may pay';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v_render := public.erp_render_remittance_advice(v_pmt, null);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'Print the remittance advice renders the payment it is pressed on, titled with its number, with a line per bill, for the person who paid it';
    passed := v_state is null
          and v_render ->> 'template' = 'remittance_advice'
          and (v_render ->> 'document_id')::uuid = v_pmt
          and exists (select 1 from jsonb_array_elements(v_render -> 'blocks') b
                       where b ->> 'kind' = 'title'
                         and b #>> '{fields,0,value}' = (v_pay #>> '{payments,0,document_number}'))
          and (select jsonb_array_length(b -> 'rows') from jsonb_array_elements(v_render -> 'blocks') b
                where b ->> 'kind' = 'lines') = 1;
    detail := coalesce(v_state, left(v_render::text, 400));
    return next;

    -- ── 7. Nobody who may not pay is offered it ─────────────────────────────
    v_step := 'the remittance advice asked for by somebody who may only read';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    begin
      perform public.erp_render_remittance_advice(v_pmt, null);
      v_err := 'rendered';
    exception when others then v_err := sqlerrm; end;
    v_n := case when erp.has_permission('finance.post') then 1 else 0 end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody who may read the books but not pay does not hold finance.post, which the page asks before it draws Print, and the door refuses them';
    passed := v_state is null
          and v_n = 0
          and erp.has_permission('finance.post')
          and v_err like 'CLOVEERP_PERMISSION_DENIED: finance.post%';
    detail := coalesce(v_state, format('reader holds finance.post: %s; render: %s', v_n = 1, left(v_err, 200)));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzcds-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2, s_read))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzcds rolled back with its receipts, payments and journals');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CASH_DOCUMENTS_SCREENS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.cash_documents_screens_suite() from public, anon;

comment on function erp_test.cash_documents_screens_suite() is
  'What the cash documents'' screens read (20260930300000). Apply cash''s rows name the receipt it '
  'made, which the Cash in step lists and whose page reads its number, customer and Posted; paying a '
  'run names each supplier''s payment; a cash document offers no move, and New, Add line and Post are '
  'refused by name; the remittance advice renders for whoever may pay and is refused, and not '
  'offered, to somebody who may only read; the strip''s budget and the door register follow.';

create or replace function erp_test.assert_cash_documents_screens_suite()
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
    from erp_test.cash_documents_screens_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CASH_DOCUMENTS_SCREENS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A cash document''s screen would draw what a door refuses, or lose the document it names. Read the case that failed.';
  end if;
  if v_total <> 8 then
    raise exception 'CLOVEERP_CASH_DOCUMENTS_SCREENS_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('cash documents screens: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_cash_documents_screens_suite() from public, anon;

comment on function erp_test.assert_cash_documents_screens_suite() is
  'The Cash in step lists the receipts Apply cash names, the Pay step names its payments, and a '
  'payment''s page prints its remittance advice for whoever may pay (20260930300000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A link on an outcome to the document it names: a receipt Apply cash made, a payment a run made (20260930300000).'
  from (values
    ('Open {document}')
  ) as v(text)
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
