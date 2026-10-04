set lock_timeout = '30s';

-- =============================================================================
-- 20261005300000  An order sent is a sound issue
-- -----------------------------------------------------------------------------
-- The deploy of d099bc3 (4 October) applied nothing and then failed its proof:
--
--   platform_assurance() is not green on live:
--   document_issue: CLOVEERP_DOCUMENT_CONTRACT_INCOMPLETE: an issued row
--   cannot explain itself
--
-- An hour earlier a purchase order had been emailed to its supplier in the
-- demonstration, the first on live since 20261004930000 built it. Sending an
-- order reserves an erp.document_issue row of kind purchase_order, whose
-- frozen contract has the six sections every issue has and totals of net, tax
-- and gross. erp.assert_document_issue_sound() asks every row for
-- totals.vat_total_sterling_minor as well: the VAT total in sterling, which a
-- UK VAT invoice in another currency must state. A purchase order is not a
-- tax invoice and has no such figure, so the first order sent anywhere turned
-- the check red, and it stays red: an issued row is immutable.
--
-- The build never met it. The suites that send an order roll their rows back,
-- and the check runs over what is committed.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * erp.assert_document_issue_sound(): a purchase order's contract is
--     complete with its gross total; every other kind still owes the VAT
--     total in sterling.
--   * erp_test.order_issue_is_sound_suite: an order is sent, and the check is
--     run while its row stands; a row of another kind without the sterling
--     total is still refused.
-- =============================================================================

do $sound$
declare
  v_sig  constant text := 'erp.assert_document_issue_sound()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$        or contract_snapshot -> 'totals' ->> 'vat_total_sterling_minor' is null) then$o$;
  v_new  constant text := $n$        -- A purchase order is not a tax invoice: its contract is complete with
        -- its gross total. Every other kind owes the VAT total in sterling
        -- (20261005300000).
        or (document_kind = 'purchase_order'
            and contract_snapshot -> 'totals' ->> 'gross_minor' is null)
        or (document_kind <> 'purchase_order'
            and contract_snapshot -> 'totals' ->> 'vat_total_sterling_minor' is null)) then$n$;
begin
  if strpos(v_src, '20261005300000') > 0 then
    raise notice '% already reads a purchase order by its own totals; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'f969e724200447c95191686adaf60440' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005300000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$sound$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.order_issue_is_sound_suite()
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
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid; v_po uuid;
  di       erp.document_issue%rowtype;
  v_res    text;
  v_err    text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that sends a purchase order';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzois-' || v_tag, 'Order Issue Suite',
      'admin@zzois-' || v_tag || '.test', 'Issue Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzois-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZOCOAT', 'Issued Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZOBRAND');
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZOO1', false);
    perform public.erp_send_purchase_order(v_po, 'orders@zobrand-' || v_tag || '.test', null, null, null);
    select x.* into di from erp.document_issue x
     where x.tenant_id = rb.tenant_id and x.source_document_id = v_po;

    -- ── 1. The order's issue, as it is written ──────────────────────────────
    v_step := 'reading the order''s issue';
    v_cases := v_cases + 1;
    case_name := 'sending an order reserves an issue of kind purchase_order whose totals are net, tax and gross, with no VAT total in sterling';
    passed := v_state is null
          and di.document_kind = 'purchase_order'
          and di.contract_snapshot -> 'totals' ->> 'gross_minor' is not null
          and di.contract_snapshot -> 'totals' ->> 'vat_total_sterling_minor' is null;
    detail := coalesce(v_state, coalesce((di.contract_snapshot -> 'totals')::text, 'no issue row'));
    return next;

    -- ── 2. The check, while the row stands ──────────────────────────────────
    v_step := 'running the document-issue check over the order''s row';
    begin
      v_res := erp.assert_document_issue_sound();
    exception when others then
      v_res := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'the document-issue check passes while a sent order''s issue stands, as it does on a live database';
    passed := v_state is null and v_res like 'document issue:%';
    detail := coalesce(v_state, left(v_res, 300));
    return next;

    -- ── 3. Every other kind still owes the sterling total ───────────────────
    v_step := 'an issue of another kind without the sterling VAT total';
    insert into erp.document_issue
    select (jsonb_populate_record(null::erp.document_issue,
              to_jsonb(di) || jsonb_build_object(
                'id', gen_random_uuid(), 'document_kind', 'sales_invoice',
                'issued_number', 'ZZ-' || v_tag))).*;
    begin
      v_err := erp.assert_document_issue_sound();
    exception when others then
      v_err := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'an issue of any other kind without the VAT total in sterling is still refused';
    passed := v_state is null and v_err like 'CLOVEERP_DOCUMENT_CONTRACT_INCOMPLETE:%';
    detail := coalesce(v_state, left(v_err, 300));
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
    raise exception 'CLOVEERP_ORDER_ISSUE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.order_issue_is_sound_suite() from public, anon;

comment on function erp_test.order_issue_is_sound_suite() is
  'An order sent is a sound issue (20261005300000): the document-issue check is run while a sent purchase '
  'order''s row stands, and still refuses another kind without the VAT total in sterling.';

create or replace function erp_test.assert_order_issue_is_sound_suite()
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
    from erp_test.order_issue_is_sound_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ORDER_ISSUE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The first purchase order emailed on a live database would turn the deploy''s proof red. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_ORDER_ISSUE_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('order issue: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_order_issue_is_sound_suite() from public, anon;

comment on function erp_test.assert_order_issue_is_sound_suite() is
  'A sent purchase order''s issue row passes the document-issue check, and other kinds still owe the sterling VAT total (20261005300000).';

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
select erp.assert_document_issue_sound();
