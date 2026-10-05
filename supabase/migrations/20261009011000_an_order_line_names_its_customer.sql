set lock_timeout = '30s';

-- =============================================================================
-- 20261009011000  An order line names its customer
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-81). Reserve stock for
-- a line offered every sales order line as its order number, product and
-- quantity, and nothing said whose order it was: two orders for the same
-- product read the same. public.erp_document_lines, which the picker reads,
-- returned no party.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_document_lines answers 'party' on every line: the name of the
--      party its document is for, the customer of a sales order and the
--      supplier of a purchase order, or null for a document that names none.
--   B. erp_test.order_line_customer_suite, which reads a sales order's line as
--      the picker does and finds its customer, and a document with no party
--      read with none.
--
-- The screen's half is in src/routes/sales/index.tsx: Reserve stock for a line
-- labels each line with its customer and offers only lines of orders the Sales
-- order step lists.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Which lines are listed, and in what order. The read stays a plain read of the
-- organisation's own rows under row security, and authorises nothing.
--
-- On production: one function is replaced and a test function added. No table
-- is altered and no row of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Each line names its party
-- ─────────────────────────────────────────────────────────────────────────────

do $lines$
declare
  v_sig  constant text := 'public.erp_document_lines(uuid,text,integer,boolean,text[])';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$             'line_state', dl.line_state) as x$o$;
  v_new1 constant text := $n$             'line_state', dl.line_state,
             -- Whose document it is, so a line picker can say (20261009011000).
             'party', pa.name) as x$n$;
  v_old2 constant text := $o$      left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
$o$;
  v_new2 constant text := $n$      left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
      left join erp.party pa on pa.tenant_id = d.tenant_id and pa.id = d.party_id
$n$;
begin
  if strpos(v_src, '20261009011000') > 0 then
    raise notice '% already names the party; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'bc7726aca889c8d6aeb39db502ddf625' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261009011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$lines$;

revoke all on function public.erp_document_lines(uuid, text, integer, boolean, text[]) from public, anon;

comment on function public.erp_document_lines(uuid, text, integer, boolean, text[]) is
  'Lines of the organisation''s documents, optionally of one document or one type; a cancelled line is never '
  'listed. Each line names the party its document is for (20261009011000). p_open_only leaves out a line whose '
  'document is cancelled or in a terminal state, and a line already received and invoiced in full. '
  'p_document_states lists only lines whose document is in one of those states; an empty list lists nothing. '
  'Reads under row security as the caller, and authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.order_line_customer_suite()
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
  v_owner  text := current_user;
  v_site uuid; v_uom uuid; v_item uuid; v_cust uuid; v_so uuid; v_line uuid; v_req uuid; v_rline uuid;
  v_read jsonb; v_none jsonb;
begin
  begin
    -- ── The fixture: an organisation with a customer's order ─────────────────
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzolc-' || v_tag, 'Order Line Customer Suite',
      'admin@zzolc-' || v_tag || '.test', 'Order Line Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzolc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'its site, unit, product and customer';
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = rb.entity_id order by s.code limit 1;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZOLWID', 'Order Line Widget', v_uom, 'active') returning id into v_item;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZOLCUS', 'Order Line Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust, 'customer', 'active');

    v_step := 'a sales order for the customer, and a requisition, which is for nobody';
    v_so := erp.open_document('sales_order', v_cust, null, v_site);
    v_line := erp.add_document_line(v_so, v_item, 4, 1000, 'the order line customer suite');
    v_req := erp.open_document('requisition', null, null, v_site);
    v_rline := erp.add_document_line(v_req, v_item, 1, 1000, 'the order line customer suite');

    v_step := 'the lines read as Reserve stock for a line reads them';
    v_read := public.erp_document_lines(null, 'sales_order', 200, true,
                                        array['draft', 'pending_approval', 'confirmed', 'picking', 'partially_despatched']);
    v_none := public.erp_document_lines(v_req, null, 200, false, null);

    -- ── 1. A line names its customer ────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a sales order''s line, read as Reserve stock for a line reads it, names the order''s customer';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_read) l
                       where l ->> 'line_id' = v_line::text
                         and l ->> 'party' = 'Order Line Customer'
                         and l ->> 'document_number' = (select d.document_number from erp.document d where d.id = v_so));
    detail := coalesce(v_state, left(v_read::text, 400));
    return next;

    -- ── 2. A document for nobody names nobody ───────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a line of a document that names no party is still listed, and names none';
    passed := v_state is null
          and jsonb_array_length(v_none) = 1
          and v_none -> 0 ->> 'line_id' = v_rline::text
          and v_none -> 0 ? 'party'
          and jsonb_typeof(v_none -> 0 -> 'party') = 'null';
    detail := coalesce(v_state, left(v_none::text, 300));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzolc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzolc rolled back with its orders');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_ORDER_LINE_CUSTOMER_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
end;
$$;

revoke all on function erp_test.order_line_customer_suite() from public, anon;

comment on function erp_test.order_line_customer_suite() is
  'An order line names its customer (20261009011000): a sales order''s line, read through '
  'public.erp_document_lines as Reserve stock for a line reads it, names the order''s customer; a line of a '
  'document that names no party is listed with none.';

create or replace function erp_test.assert_order_line_customer_suite()
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
    from erp_test.order_line_customer_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ORDER_LINE_CUSTOMER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A line picker would not say whose order a line is on. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_ORDER_LINE_CUSTOMER_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('order line customer: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_order_line_customer_suite() from public, anon;

comment on function erp_test.assert_order_line_customer_suite() is
  'A document line, as the line pickers read it, names the party its document is for (20261009011000).';

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
