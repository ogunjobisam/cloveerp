set lock_timeout = '30s';

-- =============================================================================
-- 20261010150000  A purchase from abroad accounts for its VAT on the return
-- -----------------------------------------------------------------------------
-- The demonstration's VAT return listed every bill and credit note from its
-- German suppliers as "a purchase from abroad states no tax, and may need the
-- reverse charge": nothing of them reached box 1 or box 4. The v1 gate (7
-- October) left its severity open. Decided under the owner's standing
-- approval for the run: a return whose boxes 1 and 4 leave out VAT the
-- business must account for is a wrong figure, so it is fixed, not shipped.
--
-- What the law asks of a VAT-registered business in Great Britain:
--
--   goods brought in from abroad carry import VAT, which since 1 January 2021
--   a registered business accounts for on its own return by postponed VAT
--   accounting: the VAT is declared in box 1 and reclaimed in box 4, and the
--   value is in box 7;
--
--   services bought from a supplier abroad are under the reverse charge,
--   which puts the VAT in box 1 and box 4 the same way.
--
-- Either way box 5, what is paid, does not move, and neither does the ledger:
-- the VAT is declared and reclaimed at once. So nothing is posted. The return
-- reads it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.self_accounted_vat_minor(document): the VAT a registered company
--      accounts for itself on a purchase from a supplier in another country
--      who charged none. Each line at the rate the same thing would carry
--      bought at home, asked of the organisation's own tax rules as a
--      domestic supply, so zero-rated goods account for nothing. Null when
--      the rules cannot say, which is what the exception below still reports.
--   B. erp.vat_return_boxes() adds it to box 1 and to box 4, signed as the
--      document is (a credit note from abroad takes it back).
--   C. erp.vat_exceptions() reports a purchase from abroad only where that
--      VAT could not be worked out.
--   D. erp_test.purchase_from_abroad_vat_suite proves it.
--
-- ── WHAT STAYS AS IT WAS ─────────────────────────────────────────────────────
--
-- Nothing posts differently. A supplier abroad who did charge UK VAT is read
-- from the ledger as before. Returns already finalised keep the figures they
-- were finalised with.
--
-- Production: three routines replaced or added. No table or row changes.
--
-- Proof: erp_test.purchase_from_abroad_vat_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The VAT a purchase from abroad accounts for itself
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.self_accounted_vat_minor(p_document_id uuid)
returns bigint
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.current_tenant_id();
  d         erp.document%rowtype;
  v_entity_country text;
  v_party_country  text;
  l         record;
  o         record;
  v_total   bigint := 0;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found or erp.document_trade_side(p_document_id) is distinct from 'purchase' then
    return 0;
  end if;

  select e.country_code into v_entity_country from erp.entity e
   where e.tenant_id = v_tenant and e.id = d.entity_id;
  select p.country_code into v_party_country from erp.party p
   where p.tenant_id = v_tenant and p.id = d.party_id;

  -- From another country, to a company registered for VAT when it was
  -- supplied, and charged no VAT by the supplier.
  if v_party_country is null or v_entity_country is null or v_party_country = v_entity_country
     or not erp.entity_is_tax_registered(d.entity_id, coalesce(d.tax_point, d.document_date))
     or exists (select 1 from erp.tax_determination td
                 where td.tenant_id = v_tenant and td.document_id = p_document_id
                   and td.tax_minor <> 0) then
    return 0;
  end if;

  for l in
    select dl.net_minor, i.item_class, i.tax_class
      from erp.document_line dl
      left join erp.item i on i.tenant_id = dl.tenant_id and i.id = dl.item_id
     where dl.tenant_id = v_tenant and dl.document_id = p_document_id
       and not coalesce(dl.is_cancelled, false)
  loop
    -- The rate the same supply would carry bought at home, from the
    -- organisation's own rules: the facts erp.determine_tax() gives them,
    -- with the supply domestic.
    begin
      select * into o from erp.evaluate_rules('tax.determination',
        jsonb_build_object(
          'supply_type', 'domestic',
          'item_class', coalesce(l.item_class, 'standard'),
          'tax_class', coalesce(l.tax_class, 'unstated'),
          'customer_registered', true,
          'net_minor', l.net_minor),
        d.document_date, d.entity_id, d.site_id);
    exception when others then
      return null;
    end;
    if not coalesce(o.matched, false) or (o.outcome ->> 'rate_pct') is null then
      return null;
    end if;
    v_total := v_total + round(l.net_minor * (o.outcome ->> 'rate_pct')::numeric / 100.0)::bigint;
  end loop;

  return v_total;
end;
$$;

revoke all on function erp.self_accounted_vat_minor(uuid) from public, anon, authenticated;

comment on function erp.self_accounted_vat_minor(uuid) is
  'The VAT a company registered for it accounts for itself on a purchase from a supplier in another country who '
  'charged none: postponed import VAT on goods, the reverse charge on services (20261010150000). Each line at the '
  'rate the same supply bought at home would carry, by the organisation''s own rules; null where they cannot say. '
  'Declared in box 1 and reclaimed in box 4, so box 5 and the ledger do not move.';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The return declares and reclaims it
-- ═════════════════════════════════════════════════════════════════════════════

do $vat_return_boxes$
declare
  v_sig  constant text := 'erp.vat_return_boxes(uuid, date, date)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$           coalesce(sum(x.tax_minor) filter (where x.side = 'sale'), 0)::bigint     as box1,
           coalesce(sum(x.tax_minor) filter (where x.side = 'purchase'), 0)::bigint as box4,$o$;
  v_new1 constant text := $n$           -- With the VAT a purchase from abroad accounts for itself
           -- (20261010150000): declared in box 1, reclaimed in box 4.
           (coalesce(sum(x.tax_minor) filter (where x.side = 'sale'), 0)
              + coalesce(sum(sa.minor), 0))::bigint                               as box1,
           (coalesce(sum(x.tax_minor) filter (where x.side = 'purchase'), 0)
              + coalesce(sum(sa.minor), 0))::bigint                               as box4,$n$;
  v_old2 constant text := $o$      from co left join x on x.entity_id = co.id
$o$;
  v_new2 constant text := $n$      from co left join x on x.entity_id = co.id
      left join lateral (
        select case when x.side = 'purchase' and x.tax_minor = 0
                    then x.sign * coalesce(erp.self_accounted_vat_minor(x.document_id), 0)
                    else 0 end as minor) sa on true
$n$;
  n integer;
begin
  if position('erp.self_accounted_vat_minor(' in v_def) > 0 then
    raise notice '% already declares the VAT a purchase from abroad accounts for; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % boxes 1 and 4 found % time(s)', v_sig, n;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % join found % time(s)', v_sig, n;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$vat_return_boxes$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The exception reports only what could not be worked out
-- ═════════════════════════════════════════════════════════════════════════════

do $vat_exceptions$
declare
  v_sig  constant text := 'erp.vat_exceptions(uuid, date, date)';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- (e) Flag: reverse charge is not built.
  select x.entity_id, 'a purchase from abroad states no tax, and may need the reverse charge', false,
         x.document_number,
         format('%s is from a supplier in %s; the reverse charge is not computed, so nothing of it is in box 1 or box 4',
                x.document_number, p.country_code)
    from t
    join x on true
    join erp.party p on p.tenant_id = t.tenant_id and p.id = x.party_id
    join erp.entity e on e.tenant_id = t.tenant_id and e.id = x.entity_id
   where x.side = 'purchase' and x.determined_tax_minor = 0 and x.tax_minor = 0
     and p.country_code is not null and e.country_code is not null
     and p.country_code <> e.country_code
$o$;
  v_new  constant text := $n$  -- (e) Flag: a purchase from abroad whose own VAT could not be worked out.
  -- The rest are declared in box 1 and reclaimed in box 4 (20261010150000).
  select x.entity_id, 'a purchase from abroad states no tax, and its rate could not be worked out', false,
         x.document_number,
         format('%s is from a supplier in %s, and no tax rule says what the same supply would carry bought at home, '
                'so nothing of it is in box 1 or box 4',
                x.document_number, p.country_code)
    from t
    join x on true
    join erp.party p on p.tenant_id = t.tenant_id and p.id = x.party_id
    join erp.entity e on e.tenant_id = t.tenant_id and e.id = x.entity_id
   where x.side = 'purchase' and x.determined_tax_minor = 0 and x.tax_minor = 0
     and p.country_code is not null and e.country_code is not null
     and p.country_code <> e.country_code
     and erp.self_accounted_vat_minor(x.document_id) is null
$n$;
  n integer;
begin
  if position('its rate could not be worked out' in v_def) > 0 then
    raise notice '% already reports only what could not be worked out; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % abroad finding found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$vat_exceptions$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.purchase_from_abroad_vat_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  b        record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3); v_country char(2);
  v_de uuid; v_gb uuid; v_widget uuid; v_bread uuid;
  v_po uuid; v_pol1 uuid; v_pol2 uuid; v_grn uuid; v_bill uuid;
  v_po2 uuid; v_pol3 uuid; v_grn2 uuid; v_bill2 uuid;
  v_sa bigint; v_sa2 bigint; v_n bigint;
  v_before record;
begin
  begin
    v_step := 'an organisation registered for VAT in Great Britain, buying from Germany and at home';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzpfa-' || v_tag, 'Purchase From Abroad Suite',
      'admin@zzpfa-' || v_tag || '.test', 'Purchase From Abroad Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzpfa-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();
    perform erp.configure_tax('GB', 20);
    v_entity := rb.entity_id;
    select e.base_currency, e.country_code into v_ccy, v_country from erp.entity e where e.id = v_entity;
    insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction,
                                             registration_type, registration_number, valid_from)
    values (rb.tenant_id, v_entity, 'GB', 'VAT', 'GB123456789', current_date - 365);

    v_step := 'its site, places, unit, a supplier in Germany, one at home, and two products';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZFEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, v_entity, 'ZFSITE', 'Purchase from abroad suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZF-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZF-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZFDE', 'A supplier in Germany', 'DE', 'active') returning id into v_de;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZFGB', 'A supplier at home', v_country, 'active') returning id into v_gb;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_de, 'supplier', 'active'), (rb.tenant_id, v_gb, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, item_class, tax_class, stock_uom_id, lifecycle, status)
    values (rb.tenant_id, 'ZF-WIDGET', 'A widget', 'finished_good', 'standard', v_uom, 'active', 'active')
    returning id into v_widget;
    insert into erp.item (tenant_id, code, name, item_class, tax_class, stock_uom_id, lifecycle, status)
    values (rb.tenant_id, 'ZF-BREAD', 'A loaf of bread', 'finished_good', 'zero_rated', v_uom, 'active', 'active')
    returning id into v_bread;

    select * into v_before from erp.vat_return_boxes(v_entity, current_date - 1, current_date + 1);

    v_step := 'ten widgets at a hundred pounds and ten loaves at ten, bought from Germany, received and billed with no VAT';
    v_po := erp.open_document('purchase_order', v_de, v_entity, v_site);
    v_pol1 := erp.add_document_line(v_po, v_widget, 10, 10000, 'ten widgets');
    v_pol2 := erp.add_document_line(v_po, v_bread, 10, 1000, 'ten loaves');
    perform erp.transition_document(v_po, 'submit', 'purchase from abroad suite');
    perform erp_test.approve_document(v_po, 'purchase from abroad suite');
    perform erp.transition_document(v_po, 'send', 'purchase from abroad suite');
    v_grn := erp.open_document('goods_receipt', v_de, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol1, 10, null);
    perform erp.receive_against(v_grn, v_pol2, 10, null);
    perform erp.transition_document(v_grn, 'post', 'purchase from abroad suite');
    v_bill := erp.open_document('purchase_invoice', v_de, v_entity, v_site);
    perform erp.invoice_against(v_bill, v_pol1, 10, null);
    perform erp.invoice_against(v_bill, v_pol2, 10, null);
    perform erp.transition_document(v_bill, 'register', 'purchase from abroad suite');

    v_sa := erp.self_accounted_vat_minor(v_bill);

    v_cases := v_cases + 1;
    case_name := 'the German bill accounts for twenty per cent on the widgets and nothing on the bread';
    passed := v_state is null and v_sa = 20000;
    detail := format('%s accounted for on 1000.00 of widgets and 100.00 of bread', v_sa);
    return next;

    select * into b from erp.vat_return_boxes(v_entity, current_date - 1, current_date + 1);

    v_cases := v_cases + 1;
    case_name := 'it is declared in box 1 and reclaimed in box 4, and box 5 does not move';
    passed := v_state is null
          and b.box1_minor - v_before.box1_minor = 20000
          and b.box4_minor - v_before.box4_minor = 20000
          and b.box5_minor = v_before.box5_minor;
    detail := format('box 1 %s, box 4 %s, box 5 %s (was %s, %s, %s)',
                     b.box1_minor, b.box4_minor, b.box5_minor,
                     v_before.box1_minor, v_before.box4_minor, v_before.box5_minor);
    return next;

    v_cases := v_cases + 1;
    case_name := 'and its value is in box 7';
    passed := v_state is null and b.box7_pounds - v_before.box7_pounds = 1100;
    detail := format('box 7 %s pounds', b.box7_pounds);
    return next;

    v_cases := v_cases + 1;
    case_name := 'nothing posts for it: the tax control account has not moved';
    passed := v_state is null
          and not exists (
            select 1 from erp.journal j
              join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
              join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
             where j.tenant_id = rb.tenant_id and j.document_id = v_bill and a.control_kind = 'tax'
               and (jl.debit_minor <> 0 or jl.credit_minor <> 0));
    detail := 'the VAT is declared and reclaimed on the return, not posted';
    return next;

    select count(*) into v_n
      from erp.vat_exceptions(v_entity, current_date - 1, current_date + 1) x
     where x.reference = (select d.document_number from erp.document d where d.id = v_bill);

    v_cases := v_cases + 1;
    case_name := 'the return no longer lists the bill as needing the reverse charge';
    passed := v_state is null and v_n = 0;
    detail := format('%s exception(s) name the bill', v_n);
    return next;

    -- ── 6. At home, nothing is self-accounted ───────────────────────────────
    v_step := 'ten widgets bought at home, billed with twenty per cent stated';
    v_po2 := erp.open_document('purchase_order', v_gb, v_entity, v_site);
    v_pol3 := erp.add_document_line(v_po2, v_widget, 10, 10000, 'ten widgets at home');
    perform erp.transition_document(v_po2, 'submit', 'purchase from abroad suite');
    perform erp_test.approve_document(v_po2, 'purchase from abroad suite');
    perform erp.transition_document(v_po2, 'send', 'purchase from abroad suite');
    v_grn2 := erp.open_document('goods_receipt', v_gb, v_entity, v_site);
    perform erp.receive_against(v_grn2, v_pol3, 10, null);
    perform erp.transition_document(v_grn2, 'post', 'purchase from abroad suite');
    v_bill2 := erp.open_document('purchase_invoice', v_gb, v_entity, v_site);
    perform erp.invoice_against(v_bill2, v_pol3, 10, null);
    perform erp.state_supplier_tax(v_bill2, 20000, 'S', 'purchase from abroad suite');
    perform erp.transition_document(v_bill2, 'register', 'purchase from abroad suite');
    v_sa2 := erp.self_accounted_vat_minor(v_bill2);
    select * into b from erp.vat_return_boxes(v_entity, current_date - 1, current_date + 1);

    v_cases := v_cases + 1;
    case_name := 'a bill from home accounts for nothing itself, and its stated VAT is in box 4 as before';
    passed := v_state is null and v_sa2 = 0
          and b.box4_minor - v_before.box4_minor = 40000
          and b.box1_minor - v_before.box1_minor = 20000;
    detail := format('self-accounted %s; box 1 %s, box 4 %s', v_sa2, b.box1_minor, b.box4_minor);
    return next;

    -- ── 7. The return still agrees with the ledger ──────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the return still reports no disagreement with the ledger';
    passed := v_state is null and coalesce(b.ledger_disagreements, -1) = 0;
    detail := format('%s ledger disagreement(s)', b.ledger_disagreements);
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzpfa-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzpfa rolled back with its orders, receipts and bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PURCHASE_FROM_ABROAD_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_purchase_from_abroad_vat_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _purchase_from_abroad on commit drop as
    select * from erp_test.purchase_from_abroad_vat_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _purchase_from_abroad;
  drop table _purchase_from_abroad;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PURCHASE_FROM_ABROAD_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_PURCHASE_FROM_ABROAD_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a purchase from abroad accounts for its VAT: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.purchase_from_abroad_vat_suite() from public, anon;
revoke all on function erp_test.assert_purchase_from_abroad_vat_suite() from public, anon;

comment on function erp_test.purchase_from_abroad_vat_suite() is
  'A purchase from abroad accounts for its VAT (20261010150000): goods from Germany billed with no VAT are declared '
  'in box 1 and reclaimed in box 4 at the rate they would carry at home, zero-rated goods at nothing, box 5 and the '
  'ledger unmoved, the exception gone; a bill from home is unchanged.';

comment on function erp_test.assert_purchase_from_abroad_vat_suite() is
  'erp_test.purchase_from_abroad_vat_suite(), eight cases: postponed VAT on purchases from abroad.';

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
