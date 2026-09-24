set lock_timeout = '30s';

-- =============================================================================
-- 20260924100000  Order to cash is walked in seven presses
-- -----------------------------------------------------------------------------
-- PR6, M4: node S9 of docs/spec/simplification-review.md, "O2C step budget of
-- seven", which names erp_test.step_budget_suite as its proof. The last node
-- of the sales reseed PR6 builds.
--
-- The procurement cycle has been walked by pressing since PR4
-- (erp_test.six_step_walk, 20260923200000). Order to cash was only counted
-- from the screens' strip, which the flow budget says understates it. This
-- walks it: an organisation installed as the Configuration screen installs
-- finance, procurement, sales, receivables and tax, VAT-registered, with a
-- customer on credit terms; four people who are not administrators (a
-- seller, a sales manager, the warehouse and accounts); seven presses of the
-- desk's public doors in their sessions; and every move the cycle made read
-- back from the transition log, in order. Nothing here changes how the
-- product behaves.
--
-- The seven are what PR5 and PR6 made possible: the quotation is accepted by
-- its conversion (S1), the order is despatched by its delivery and closed by
-- its settled invoice (S2, S3), credit is weighed once, with the order, and
-- passes it inside the customer's limit (S4), the manager is asked because
-- the order is over the threshold (S5),
-- and the invoice is issued and filed in one press (S6).
--
-- What the walk does not prove: the company's registration number, its
-- registered office and VAT number, and the customer's billing address are
-- written by the fixture, because no public door writes them yet. An
-- organisation cannot issue its first invoice from the desk until one does
-- (found on review, queued as its own task).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The order-to-cash cycle, walked
--
-- The mirror of erp_test.six_step_walk() (20260923200000): an organisation
-- installed as the Configuration screen installs it, four people who are not
-- administrators, and seven public doors pressed in their sessions. Each
-- press is recorded with what the door returned; the first refusal is
-- recorded and the walk stops there.
--
--   1. the seller raises a quotation, sent as it is made
--   2. the seller converts it; the order is submitted as it is made
--   3. the sales manager approves the order, in one press
--   4. the warehouse delivers everything, posted as it is made
--   5. the seller invoices the delivery
--   6. the seller issues the invoice
--   7. accounts records the customer's payment
--
-- The quotation reads accepted, the order closed (by its settled invoice,
-- 20260923800000) and the invoice paid, and nobody pressed any of those.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.order_to_cash_walk()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  c_undo   constant text := 'CLOVEERP_ORDER_TO_CASH_WALK_UNDO';
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code   text;
  a1       uuid := gen_random_uuid();   -- the first administrator, who sets up
  a2       uuid := gen_random_uuid();   -- the second, who approves the changes
  s_sell   uuid := gen_random_uuid();
  s_mgr    uuid := gen_random_uuid();
  s_wh     uuid := gen_random_uuid();
  s_acc    uuid := gen_random_uuid();
  p_sell   uuid;
  p_mgr    uuid;
  p_wh     uuid;
  p_acc    uuid;
  r        record;
  res      jsonb;
  v_tok_a2 text;
  v_tok_s  text;
  v_tok_m  text;
  v_tok_w  text;
  v_tok_c  text;
  v_role   uuid;
  cs_fin   uuid;
  cs_proc  uuid;
  cs_sales uuid;
  cs_recv  uuid;
  cs_tax   uuid;
  v_issue  uuid;
  v_path   text;
  v_issue_status text;
  v_decided text;
  v_moves  jsonb;
  v_uom    uuid;
  v_site   uuid;
  v_sup    uuid;
  v_cust   uuid;
  v_item   uuid;
  v_grn    uuid;
  v_lines  jsonb;
  v_steps  jsonb := '[]'::jsonb;
  v_subs   uuid[] := '{}';
  v_block  text;
  v_quo    uuid;
  v_so     uuid;
  v_dn     uuid;
  v_inv    uuid;
  v_owed   bigint;
  v_ccy    text;
  v_admins integer;
  v_manager_asked boolean;
  v_out    jsonb;
begin
  begin
    v_code := 'zzo2c-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'Order to cash walk', 'admin@' || v_code || '.test', 'Walk Admin');

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp_test.administrator_approval_off(r.tenant_id);

    -- The sales manager's role, which is tenant data and so made in the
    -- bootstrap window a fixture is allowed: takes and approves orders and
    -- reads them, and nothing else.
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_walk_sales_manager', 'Walk sales manager', 'active')
    returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (r.tenant_id, v_role, 'sales.order'),
      (r.tenant_id, v_role, 'sales.read'),
      (r.tenant_id, v_role, 'reporting.read');
    perform erp_test.close_bootstrap_window(r.tenant_id);

    res := public.erp_invite_principal('second@' || v_code || '.test', 'Second Admin');
    v_tok_a2 := res ->> 'token';
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('seller@' || v_code || '.test', 'Sal Seller');
    p_sell := (res ->> 'app_user_id')::uuid; v_tok_s := res ->> 'token';
    perform erp.grant_role(p_sell, 'sales', null, null, 'sells');
    res := public.erp_invite_principal('manager@' || v_code || '.test', 'Max Manager');
    p_mgr := (res ->> 'app_user_id')::uuid; v_tok_m := res ->> 'token';
    perform erp.grant_role(p_mgr, 'zz_walk_sales_manager', null, null, 'approves orders');
    res := public.erp_invite_principal('warehouse@' || v_code || '.test', 'Wren Warehouse');
    p_wh := (res ->> 'app_user_id')::uuid; v_tok_w := res ->> 'token';
    perform erp.grant_role(p_wh, 'warehouse', null, null, 'despatches');
    res := public.erp_invite_principal('accounts@' || v_code || '.test', 'Ash Accounts');
    p_acc := (res ->> 'app_user_id')::uuid; v_tok_c := res ->> 'token';
    perform erp.grant_role(p_acc, 'finance', null, null, 'records what customers pay');

    -- Installed as the Configuration screen installs it, the sales chain
    -- naming the manager's role. Live, so the other administrator approves
    -- and promotes each change.
    cs_fin := erp.configure_finance();
    select (d ->> 'lifecycle_change_set_id')::uuid into cs_proc
      from public.erp_configure_procurement(1000000, null) d;
    cs_sales := (public.erp_configure_sales(15, 'zz_walk_sales_manager') ->> 'change_set_id')::uuid;
    cs_recv := public.erp_configure_receivables();
    cs_tax := public.erp_configure_tax('GB', 20);

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok_a2);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_sales);
    perform erp.promote_change_set(cs_sales);
    perform erp.approve_change_set(cs_recv);
    perform erp.promote_change_set(cs_recv);
    perform erp.approve_change_set(cs_tax);
    perform erp.promote_change_set(cs_tax);

    perform set_config('request.jwt.claims', json_build_object('sub', s_sell)::text, true);
    perform erp.claim_invitation(v_tok_s);
    perform set_config('request.jwt.claims', json_build_object('sub', s_mgr)::text, true);
    perform erp.claim_invitation(v_tok_m);
    perform set_config('request.jwt.claims', json_build_object('sub', s_wh)::text, true);
    perform erp.claim_invitation(v_tok_w);
    perform set_config('request.jwt.claims', json_build_object('sub', s_acc)::text, true);
    perform erp.claim_invitation(v_tok_c);

    -- Master data and the stock, as a fixture.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'CUST', 'Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_cust, 'customer', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;
    -- What an invoice must carry by law: the company's number, registered
    -- office and VAT number, and where the customer is billed. These four
    -- stand in for doors the product does not have yet: no public door
    -- writes a company's registration number, its VAT registration or a
    -- party's address, so an organisation cannot set them from the desk
    -- (found on review, queued as its own task).
    update erp.entity set registration_number = '07123456'
     where tenant_id = r.tenant_id and id = r.entity_id;
    insert into erp.party_address (tenant_id, party_id, address_kind, label, lines,
                                   locality, postcode, country_code, is_default, valid_from)
    select r.tenant_id, e.party_id, 'registered', 'Registered office',
           array['1 Ledger Way'], 'Leeds', 'LS1 1AA', 'GB', true, current_date
      from erp.entity e where e.tenant_id = r.tenant_id and e.id = r.entity_id;
    insert into erp.party_address (tenant_id, party_id, address_kind, label, lines,
                                   locality, postcode, country_code, is_default, valid_from)
    values (r.tenant_id, v_cust, 'billing', 'Invoice to', array['2 Buyer Street'],
            'York', 'YO1 1AA', 'GB', true, current_date);
    insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction,
                                             registration_type, registration_number, valid_from)
    values (r.tenant_id, r.entity_id, 'GB', 'VAT', 'GB123456789', current_date - 365);
    -- The customer's credit, set on its door: room for the order, so the
    -- credit step is asked and passes over (20260923900000).
    perform public.erp_set_credit_limit(v_cust, 1000000, false, 'Opening limit agreed at the account review.');
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 50, 5000, 'the stock');
    perform erp.transition_document(v_grn, 'post', 'order to cash walk');

    select count(*) into v_admins
      from erp.organisation_administrators() a
     where a.app_user_id in (p_sell, p_mgr, p_wh, p_acc);

    -- ─────────────────────────────────────────────────────────────────────
    -- The seven presses.
    -- ─────────────────────────────────────────────────────────────────────
    -- Ten widgets at 150.00: over the sales manager's 1,000.00.
    v_lines := jsonb_build_array(jsonb_build_object(
                 'item_id', v_item, 'quantity', 10, 'unit_price_minor', 15000,
                 'description', 'Ten widgets'));

    -- 1. The seller quotes, and the quotation is sent as it is made.
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', s_sell)::text, true);
      res := public.erp_create_document_full('quotation', v_cust, v_site, null, null, null, v_lines, 'auto');
      v_quo := (res ->> 'document_id')::uuid;
      v_steps := v_steps || jsonb_build_object('step', 1, 'door', 'erp_create_document_full',
                   'person', 'seller', 'result', res);
      v_subs := v_subs || s_sell;
    exception when others then
      v_block := format('1 seller erp_create_document_full(quotation): %s', left(sqlerrm, 300));
    end;

    -- 2. The customer accepts; the seller converts the quotation, and the
    --    order is submitted as it is made.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_sell)::text, true);
        res := public.erp_convert_document(v_quo, null, null, null, 'auto');
        v_so := (res ->> 'document_id')::uuid;
        v_steps := v_steps || jsonb_build_object('step', 2, 'door', 'erp_convert_document',
                     'person', 'seller', 'result', res);
        v_subs := v_subs || s_sell;
      exception when others then
        v_block := format('2 seller erp_convert_document: %s', left(sqlerrm, 300));
      end;
    end if;

    -- 3. The sales manager approves the order, in one press.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
        v_manager_asked := exists (
          select 1 from erp.approval_task t
            join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
           where q.tenant_id = r.tenant_id and q.object_id = v_so
             and t.step_code = 'sales_manager' and t.assignee_user_id = p_mgr);
        perform set_config('request.jwt.claims', json_build_object('sub', s_mgr)::text, true);
        res := public.erp_transition_document(v_so, 'approve', null);
        v_steps := v_steps || jsonb_build_object('step', 3, 'door', 'erp_transition_document',
                     'move', 'approve', 'person', 'manager', 'result', res);
        v_subs := v_subs || s_mgr;
      exception when others then
        v_block := format('3 manager erp_transition_document(approve): %s', left(sqlerrm, 300));
      end;
    end if;

    -- 4. The warehouse delivers everything, posted as it is made.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_wh)::text, true);
        res := public.erp_create_delivery_from_order(v_so, null, 'auto');
        v_dn := (res ->> 'document_id')::uuid;
        v_steps := v_steps || jsonb_build_object('step', 4, 'door', 'erp_create_delivery_from_order',
                     'person', 'warehouse', 'result', res);
        v_subs := v_subs || s_wh;
      exception when others then
        v_block := format('4 warehouse erp_create_delivery_from_order(post): %s', left(sqlerrm, 300));
      end;
    end if;

    -- 5. The seller invoices the delivery.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_sell)::text, true);
        res := to_jsonb(public.erp_invoice_from_delivery(v_dn, false, null));
        v_inv := coalesce((res ->> 'document_id')::uuid, (res #>> '{}')::uuid);
        v_steps := v_steps || jsonb_build_object('step', 5, 'door', 'erp_invoice_from_delivery',
                     'person', 'seller', 'result', res);
        v_subs := v_subs || s_sell;
      exception when others then
        v_block := format('5 seller erp_invoice_from_delivery: %s', left(sqlerrm, 300));
      end;
    end if;

    -- 6. The seller issues it, in the one press the desk draws
    --    (src/components/erp/invoice-issue.tsx and
    --    src/lib/document-output.functions.ts, 20260923500000): the tax point
    --    the press states; the issue, which moves the draft to Issued, posts
    --    it and takes its number; the issue read back; and the filed copy
    --    completed. The file itself is the server function's upload, which a
    --    database walk stands in for with the row the upload leaves.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_sell)::text, true);
        perform public.erp_set_invoice_tax_point(v_inv, current_date);
        res := to_jsonb(public.erp_issue_sales_invoice(v_inv, null));
        v_issue := (res ->> 'document_issue_id')::uuid;
        perform public.erp_document_issues(v_inv, 10);
        v_path := r.tenant_id::text || '/' || (res ->> 'issued_number') || '.pdf';
        insert into storage.objects (bucket_id, name, metadata, user_metadata)
        values ('document-output', v_path,
                jsonb_build_object('mimetype', 'application/pdf', 'size', 20480),
                jsonb_build_object('sha256', repeat('a', 64)));
        res := res || jsonb_build_object('filed',
                 to_jsonb(public.erp_complete_document_issue(v_issue, v_path, repeat('a', 64))));
        v_steps := v_steps || jsonb_build_object('step', 6,
                     'door', 'erp_set_invoice_tax_point, erp_issue_sales_invoice, erp_document_issues, erp_complete_document_issue',
                     'person', 'seller', 'result', res);
        v_subs := v_subs || s_sell;
      exception when others then
        v_block := format('6 seller erp_issue_sales_invoice: %s', left(sqlerrm, 300));
      end;
    end if;

    -- 7. Accounts records what the customer paid, and it settles the invoice.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
        select sum(si.debit_minor - si.credit_minor)::bigint, min(si.currency)
          into v_owed, v_ccy
          from erp.subledger_item si
         where si.tenant_id = r.tenant_id and si.document_id = v_inv and si.control_kind = 'receivable';
        perform set_config('request.jwt.claims', json_build_object('sub', s_acc)::text, true);
        res := to_jsonb(public.erp_apply_cash(v_cust, v_owed, v_ccy::character(3), 'Remittance ' || v_hex));
        v_steps := v_steps || jsonb_build_object('step', 7, 'door', 'erp_apply_cash',
                     'person', 'accounts', 'result', res);
        v_subs := v_subs || s_acc;
      exception when others then
        v_block := format('7 accounts erp_apply_cash: %s', left(sqlerrm, 300));
      end;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    -- Who decided the manager's step, and every move the cycle made, in the
    -- order it made them: what shows which moves were pressed and which the
    -- documents made by themselves.
    select string_agg(format('%s:%s', t.status, t.decided_via), ',') into v_decided
      from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = v_so
       and t.step_code = 'sales_manager' and t.decided_by = p_mgr;
    select coalesce(jsonb_agg(format('%s.%s',
             case l.object_id when v_quo then 'quotation' when v_so then 'order'
                              when v_dn then 'delivery' when v_inv then 'invoice' end,
             l.transition_code) order by l.occurred_at, l.id), '[]'::jsonb)
      into v_moves
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document'
       and l.object_id in (v_quo, v_so, v_dn, v_inv)
       and coalesce(l.transition_code, '') <> '';
    select di.status::text into v_issue_status from erp.document_issue di
     where di.tenant_id = r.tenant_id and di.id = v_issue;
    v_out := jsonb_build_object(
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'administrators_pressing', v_admins,
      'manager_asked', coalesce(v_manager_asked, false),
      'quotation_state', erp.object_current_state('document', v_quo),
      'order_state', erp.object_current_state('document', v_so),
      'delivery_state', erp.object_current_state('document', v_dn),
      'invoice_state', erp.object_current_state('document', v_inv),
      'owed', v_owed,
      'issue_status', v_issue_status,
      'manager_decided', v_decided,
      'credit_step', (select string_agg(t.status::text, ',') from erp.approval_task t
                        join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
                       where q.tenant_id = r.tenant_id and q.object_id = v_so and t.step_code = 'credit'),
      'moves', v_moves,
      'blocked', v_block,
      'steps', v_steps);

    raise exception using message = c_undo;
  exception when others then
    if sqlerrm <> c_undo then
      v_out := jsonb_build_object('presses', 0, 'people', 0, 'blocked',
                 'setting up: ' || left(sqlerrm, 300), 'steps', v_steps);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. What proves it: the walk is case 9 of erp_test.step_budget_suite(),
--     which node S9 names
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig constant text := 'erp_test.step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs text[][] := array[
    array[$o$  c_expected constant integer := 8;$o$,
          $n$  c_expected constant integer := 9;$n$],
    array[$o$  v_wait    jsonb;
$o$, $n$  v_wait    jsonb;
  v_o2c     jsonb;
$n$],
    array[$o$  if v_cases <> c_expected then$o$,
          $n$  -- ── 9. Order to cash, walked ───────────────────────────────────────────
  --
  -- The plan's target for the cycle is seven (20260924100000). Four people
  -- who are not administrators, seven presses, and every state the cycle
  -- reaches after the order is approved reached by what happened, not by a
  -- press: the quotation accepted by its conversion, the order despatched by
  -- its delivery and closed by its settled invoice, the invoice paid by the
  -- cash.
  v_o2c := erp_test.order_to_cash_walk();

  v_cases := v_cases + 1;
  case_name := 'the order-to-cash cycle is walked by four people in seven presses, from a quotation to a filed invoice paid and a closed order, and the six moves nobody pressed are made by what happened';
  passed := coalesce(v_o2c ->> 'blocked' is null
            and (v_o2c ->> 'presses')::integer = 7
            and (v_o2c ->> 'people')::integer = 4
            and (v_o2c ->> 'administrators_pressing')::integer = 0
            and (v_o2c ->> 'manager_asked')::boolean
            and v_o2c ->> 'quotation_state' = 'accepted'
            and v_o2c ->> 'order_state' = 'closed'
            and v_o2c ->> 'delivery_state' = 'posted'
            and v_o2c ->> 'invoice_state' = 'paid'
            and v_o2c ->> 'issue_status' = 'issued'
            and v_o2c ->> 'manager_decided' = 'approved:desk'
            and v_o2c ->> 'credit_step' = 'skipped'
            -- Every move, in order. Seven were pressed; the quotation's
            -- accept, the order's pick, despatch, invoice and close, and the
            -- invoice's settle were made by what happened.
            and v_o2c -> 'moves' = jsonb_build_array(
                  'quotation.send', 'quotation.accept', 'order.submit', 'order.approve',
                  'delivery.post', 'order.pick', 'order.despatch',
                  'invoice.issue', 'order.invoice', 'invoice.settle', 'order.close'), false);
  detail := coalesce('blocked at ' || (v_o2c ->> 'blocked') || '; ', '')
            || format('%s press(es) by %s people (%s of them administrators); the manager asked %s and decided %s; credit %s; issue %s; moves %s; the quotation reads %s, the order %s, the delivery %s, the invoice %s',
                      coalesce(v_o2c ->> 'presses', '0'), coalesce(v_o2c ->> 'people', '0'),
                      coalesce(v_o2c ->> 'administrators_pressing', 'an unknown number'),
                      coalesce(v_o2c ->> 'manager_asked', 'false'),
                      coalesce(v_o2c ->> 'manager_decided', 'nothing'),
                      coalesce(v_o2c ->> 'credit_step', 'not asked'),
                      coalesce(v_o2c ->> 'issue_status', 'nothing'),
                      coalesce(v_o2c ->> 'moves', '[]'),
                      coalesce(v_o2c ->> 'quotation_state', 'nothing'),
                      coalesce(v_o2c ->> 'order_state', 'nothing'),
                      coalesce(v_o2c ->> 'delivery_state', 'nothing'),
                      coalesce(v_o2c ->> 'invoice_state', 'nothing'));
  return next;

  if v_cases <> c_expected then$n$]];
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
$suite$;

do $assert$
declare
  v_sig constant text := 'erp_test.assert_step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  c_expected constant integer := 8;$o$;
  v_new constant text := $n$  c_expected constant integer := 9;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % case count anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert$;

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
