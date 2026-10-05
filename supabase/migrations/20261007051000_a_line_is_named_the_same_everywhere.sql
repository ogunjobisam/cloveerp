set lock_timeout = '30s';

-- =============================================================================
-- 20261007051000  A line is named the same everywhere
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-157). One order's
-- lines were named three ways on its own page. The Lines card showed the
-- product's code and no name, and "—" under Description where the product
-- has no description of its own. Supplier confirmation and Shipping notices
-- showed only the line's description, so a line whose description had been
-- typed over ("JT-A added line") no longer said which product it was.
--
-- public.erp_document answered each line's product by its code only.
-- erp.purchase_order_confirmation and erp.shipping_notice answered
-- coalesce(l.description, i.name): the name only where nothing was typed,
-- and never the code.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_document's lines answer item_name, the product's name,
--      beside item (its code). Every key it answers today is kept.
--   B. erp.purchase_order_confirmation's and erp.shipping_notice's lines
--      answer item_code and item_name beside description, which is kept as
--      it is.
--      The Lines card, Supplier confirmation and Shipping notices show each
--      line's product as its code and name, and a description typed over it
--      beside that.
--   C. erp_test.line_names_suite.
--
-- Production: three read functions are patched. No table is altered and no
-- row is changed, in any organisation.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The document's own lines
-- ─────────────────────────────────────────────────────────────────────────────

do $document$
declare
  v_sig  constant text := 'public.erp_document(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$        'net_minor', l.net_minor, 'item', i.code,$o$;
  v_new  constant text := $n$        'net_minor', l.net_minor, 'item', i.code,
        -- The product's name beside its code (20261007051000, J-157).
        'item_name', i.name,$n$;
begin
  if strpos(v_src, '20261007051000') > 0 then
    raise notice '% already names each line''s product; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6a1ad86df4b7ed18950a24efc6b5565e' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007051000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$document$;

comment on function public.erp_document(uuid) is
  'One document as its page draws it: its summary (state, value, tax, whether its lines are open, whether it is '
  'a receipt of samples, and for a purchase order its freight terms, read through erp.order_freight_terms '
  '(20261007040000)), its lines (each product by its code and name (20261007051000)), whether it can be '
  'amended, its lineage (each related document by its own type, once for each way it relates, at its nearest '
  '(20261007050000)), its posting reversals and the moves open to it. Reads under row security as the caller, '
  'and authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The supplier's answer and the shipping notice
-- ─────────────────────────────────────────────────────────────────────────────

do $confirmation$
declare
  v_sig  constant text := 'erp.purchase_order_confirmation(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$                       'line_id', l.id, 'line_no', l.line_no, 'description', coalesce(l.description, i.name),$o$;
  v_new  constant text := $n$                       'line_id', l.id, 'line_no', l.line_no, 'description', coalesce(l.description, i.name),
                       -- The product by its code and name, whatever was typed
                       -- over its description (20261007051000, J-157).
                       'item_code', i.code, 'item_name', i.name,$n$;
begin
  if strpos(v_src, '20261007051000') > 0 then
    raise notice '% already names each line''s product; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '2aed21c3296b55dbd2200fe3afe5110a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007051000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$confirmation$;

comment on function erp.purchase_order_confirmation(uuid) is
  'A sent purchase order''s answer from its supplier, as its page reads it (20261004990000): the status, who '
  'answered and how, the supplier''s reference and note, any proposed changes, the buyer''s decision, the lines '
  '(each product by its code and name beside its description (20261007051000)) and what the reader may do.';

do $notice$
declare
  v_sig  constant text := 'erp.shipping_notice(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$                       'description', coalesce(l.description, i.name), 'quantity', nl.quantity,$o$;
  v_new  constant text := $n$                       'description', coalesce(l.description, i.name), 'quantity', nl.quantity,
                       -- The product by its code and name, whatever was typed
                       -- over its description (20261007051000, J-157).
                       'item_code', i.code, 'item_name', i.name,$n$;
begin
  if strpos(v_src, '20261007051000') > 0 then
    raise notice '% already names each line''s product; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a43da35c88ba31304501479986db1fc2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007051000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$notice$;

comment on function erp.shipping_notice(uuid) is
  'A shipping notice as a page reads it (20261005000000): its dates, carrier, lines (each product by its code '
  'and name beside its description (20261007051000)), cartons, receipt and differences, and why it was '
  'cancelled once it is (20261006061000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.line_names_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid;
  v_po     uuid; v_line uuid; v_notice uuid;
  v_doc    jsonb; v_conf jsonb; v_asn jsonb;
  v_dl     jsonb; v_cl jsonb; v_nl jsonb;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, a sent order whose line''s description was typed over, its answer and a notice';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzlnm-' || v_tag, 'Line Names Suite',
      'admin@zzlnm-' || v_tag || '.test', 'Line Names Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzlnm-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    -- A product with a name and no description of its own: the Lines card
    -- had only its code to show, and "—" beside it.
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZLNMCOAT', 'Line Names Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZLNMA');
    -- The line's description is typed over the product's, as the testers'
    -- "JT-A added line" was. Then approved and sent, as
    -- erp_test.shipping_notice_suite sends its order.
    v_po := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    v_line := erp.add_document_line(v_po, v_item, 10, 9000, 'Typed over');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'line names suite');
    perform public.erp_send_purchase_order(v_po, 'orders@zzlnm-' || v_tag || '.test', null, null, null);
    -- The buyer records the supplier's answer, and what they say is coming.
    perform public.erp_record_supplier_confirmation(v_po, jsonb_build_object('decision', 'confirm'));
    v_notice := (public.erp_record_shipping_notice(v_po, jsonb_build_object(
      'expected_arrival', (current_date + 3)::text,
      'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_line, 'quantity', 4)))) ->> 'notice_id')::uuid;

    v_doc  := public.erp_document(v_po);
    v_conf := public.erp_purchase_order_confirmation(v_po);
    v_asn  := (select n from jsonb_array_elements(public.erp_shipping_notices(null)) n
                where (n ->> 'notice_id')::uuid = v_notice);
    v_dl := v_doc -> 'lines' -> 0;
    v_cl := (select l from jsonb_array_elements(v_conf -> 'lines') l where (l ->> 'line_id')::uuid = v_line);
    v_nl := (select l from jsonb_array_elements(v_asn -> 'lines') l where (l ->> 'order_line_id')::uuid = v_line);

    -- ── 1. The Lines card ───────────────────────────────────────────────────
    v_step := 'reading the order''s lines';
    v_cases := v_cases + 1;
    case_name := 'the order''s own page answers each line''s product by its code and its name, and the description as it was typed';
    passed := coalesce(v_state is null
          and v_dl ->> 'item' = 'ZLNMCOAT'
          and v_dl ->> 'item_name' = 'Line Names Coat'
          and v_dl ->> 'description' = 'Typed over', false);
    detail := coalesce(v_state, left(format('line %s', v_dl), 500));
    return next;

    -- ── 2. The supplier's answer ────────────────────────────────────────────
    v_step := 'reading the order''s answer from its supplier';
    v_cases := v_cases + 1;
    case_name := 'the supplier''s answer names a line whose description was typed over by its product''s code and name, beside the typed description';
    passed := coalesce(v_state is null
          and v_cl ->> 'item_code' = 'ZLNMCOAT'
          and v_cl ->> 'item_name' = 'Line Names Coat'
          and v_cl ->> 'description' = 'Typed over', false);
    detail := coalesce(v_state, left(format('answer %s', coalesce(v_cl, v_conf)), 500));
    return next;

    -- ── 3. The shipping notice ──────────────────────────────────────────────
    v_step := 'reading the notice goods-in lists';
    v_cases := v_cases + 1;
    case_name := 'the shipping notice names the same line by the same code and name the order''s page gives it, beside the typed description';
    passed := coalesce(v_state is null
          and v_nl ->> 'item_code' = v_dl ->> 'item'
          and v_nl ->> 'item_name' = v_dl ->> 'item_name'
          and v_nl ->> 'description' = 'Typed over', false);
    detail := coalesce(v_state, left(format('notice line %s', coalesce(v_nl, v_asn)), 500));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_LINE_NAMES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.line_names_suite() from public, anon;

comment on function erp_test.line_names_suite() is
  'A line is named the same everywhere (20261007051000, J-157): the order''s page, its supplier''s answer and '
  'its shipping notice each answer a line''s product by its code and name, beside a description typed over it.';

create or replace function erp_test.assert_line_names_suite()
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
    from erp_test.line_names_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_LINE_NAMES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A line''s product is named differently on the order''s page, its supplier''s answer or its shipping notice. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_LINE_NAMES_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a line is named the same everywhere: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_line_names_suite() from public, anon;

comment on function erp_test.assert_line_names_suite() is
  'A line''s product is named by its code and name on the order''s page, its supplier''s answer and its '
  'shipping notice (20261007051000).';

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
