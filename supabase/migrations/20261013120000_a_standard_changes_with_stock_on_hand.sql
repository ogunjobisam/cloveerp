-- A standard changes with stock on hand.
--
-- Manufacturing depth, the piece deferred from part 2 (owner, 14 October
-- 2026: "carry on with the revaluation"). A standard-costed product's standard
-- could be set only while none of it was held: erp.set_standard_cost refused
-- with CLOVEERP_STANDARD_REVALUATION_NOT_BUILT, because changing it would
-- have revalued the stock with no journal. So a product made or bought every
-- week could never take a new standard, and "Adopt as standard cost" on the
-- product structure screen was refused for exactly the products it was for.
--
-- ── DECISIONS (taken under the owner's standing approval) ───────────────────
--
--   * What is held is revalued at the new standard as the standard changes:
--     the stock's value becomes the quantity held at the new standard, and
--     the difference is posted, Dr inventory and Cr stock adjustments when it
--     rises, the other way when it falls. Stock adjustments is the account
--     the books already use for a change in stock's value that is not a
--     purchase or a sale; no new account.
--   * The journal is traced to the stock adjustment posting rule, and the
--     change is an event, item.standard_revalued, saying from what to what,
--     on how much stock, and by how much.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.set_standard_cost revalues what is held, and posts the difference.
--   B. erp.adopt_rolled_up_cost says what the stock was revalued by, and the
--      product structure screen no longer warns it will be refused.
--   C. erp_test.standard_revaluation_suite proves A and B.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The standard changes, and what is held is revalued
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.item.standard_revalued', 'en', 'Standard cost changed, stock revalued', 'finance',
   'Event raised when a product''s standard cost changes and the stock held is revalued at it.'),
  ('event.item.standard_revalued', 'de', 'Standardkosten geändert, Bestand neu bewertet', 'finance',
   'Ereignis, wenn sich die Standardkosten eines Produkts ändern und der Bestand neu bewertet wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('item.standard_revalued', 1, 'item', 'finance', 'event.item.standard_revalued',
        'A product''s standard cost changed, and the stock held at the site was revalued at it.',
        '{"type":"object","required":["was_minor","standard_minor","quantity","revalued_minor"],"properties":{"was_minor":{"type":"integer"},"standard_minor":{"type":"integer"},"quantity":{"type":"number"},"revalued_minor":{"type":"integer"}}}'::jsonb,
        true)
on conflict do nothing;

create or replace function erp.set_standard_cost(p_item_id uuid, p_site_id uuid, p_unit_cost_minor bigint,
                                                 p_currency character default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_method  erp.costing_method;
  v_ccy     character(3);
  ic        erp.item_cost%rowtype;
  v_id      uuid;
  v_entity  uuid;
  v_new     bigint;
  v_diff    bigint;
  v_event   uuid;
  v_journal uuid;
  v_ledger  uuid;
  v_inv     uuid;
  v_kind    erp.account.control_kind%type;
  v_adj     uuid;
  v_rule    uuid;
  v_version integer;
  v_date    date;
begin
  perform erp.authorise('finance.configure', null, p_site_id, null, 'item_cost', null);
  if not exists (select 1 from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id) then
    raise exception 'CLOVEERP_UNKNOWN_ITEM: %', p_item_id using errcode = '23503';
  end if;
  if p_site_id is not null and not exists (select 1 from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id) then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503';
  end if;
  v_method := erp.costing_method_for(p_item_id, p_site_id);
  if v_method <> 'standard' then
    raise exception 'CLOVEERP_NOT_STANDARD_COSTED: this item is costed by % here, so it has no standard to set', v_method
      using errcode = '23514', hint = 'Promote a costing policy with method standard for the item''s class or site, then set the standard.';
  end if;
  if coalesce(p_unit_cost_minor, 0) <= 0 then
    raise exception 'CLOVEERP_COST_NONPOSITIVE: a standard cost is a positive figure in minor units' using errcode = '23514';
  end if;
  v_ccy := coalesce(p_currency,
                    (select e.base_currency from erp.site s join erp.entity e on e.id = s.entity_id where s.id = p_site_id),
                    (select e.base_currency from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1));

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id and c.site_id is not distinct from p_site_id
     for update;
  if not found then
    insert into erp.item_cost (tenant_id, item_id, site_id, method, unit_cost_minor, currency, quantity_on_hand, value_minor)
    values (v_tenant, p_item_id, p_site_id, 'standard', p_unit_cost_minor, v_ccy, 0, 0)
    returning id into v_id;
    return v_id;
  end if;

  -- What is held, at the new standard (20261013120000). It was refused here
  -- while stock was on hand, because nothing posted the difference.
  v_new := round(coalesce(ic.quantity_on_hand, 0) * p_unit_cost_minor)::bigint;
  v_diff := v_new - coalesce(ic.value_minor, 0);

  update erp.item_cost
     set method = 'standard', unit_cost_minor = p_unit_cost_minor, currency = v_ccy, value_minor = v_new,
         updated_at = now()
   where id = ic.id
   returning id into v_id;

  if v_diff <> 0 then
    select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id;
    v_entity := coalesce(v_entity,
                         (select e.id from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1));
    v_date := case when p_site_id is not null then erp.local_today(p_site_id) else current_date end;

    v_event := erp.append_event('item.standard_revalued', 'item', p_item_id,
      jsonb_build_object('was_minor', ic.unit_cost_minor, 'standard_minor', p_unit_cost_minor,
                         'quantity', ic.quantity_on_hand, 'revalued_minor', v_diff),
      v_entity, p_site_id);

    select lg.id into v_ledger from erp.ledger lg
     where lg.tenant_id = v_tenant and lg.entity_id = v_entity and lg.is_primary and lg.status = 'active';
    select a.id, a.control_kind into v_inv, v_kind from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = erp.chart_account_code('inventory') and a.status = 'active';
    select a.id into v_adj from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = erp.chart_account_code('stock_adjustment') and a.status = 'active';
    select pr.id, pr.version into v_rule, v_version from erp.posting_rule pr
     where pr.tenant_id = v_tenant and pr.code = 'stock_adjustment' and pr.status = 'active'
       and (pr.entity_id is null or pr.entity_id = v_entity)
     order by (pr.entity_id is null), pr.version desc limit 1;
    if v_ledger is null or v_inv is null or v_adj is null or v_rule is null then
      raise exception 'CLOVEERP_ACCOUNT_NOT_ON_CHART: the company holding the stock lacks inventory, stock adjustments or the stock adjustment rule to revalue it'
        using errcode = '23514', hint = 'Upgrade finance and inventory, which install them, then change the standard.';
    end if;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id, posting_date,
                             description, status)
    values (v_tenant, v_entity, v_ledger, 'item.standard_revalued', v_event, v_date,
            format('%s revalued at its new standard, %s to %s a unit',
                   (select i.code from erp.item i where i.id = p_item_id), ic.unit_cost_minor, p_unit_cost_minor),
            'draft')
    returning id into v_journal;

    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate, posting_rule_id, posting_rule_version,
                                  source_event_id, description)
    values (v_tenant, v_journal, 1, v_inv, greatest(v_diff, 0), greatest(-v_diff, 0), v_ccy,
            greatest(v_diff, 0), greatest(-v_diff, 0), 1, v_rule, v_version, v_event,
            'Stock held, at the new standard'),
           (v_tenant, v_journal, 2, v_adj, greatest(-v_diff, 0), greatest(v_diff, 0), v_ccy,
            greatest(-v_diff, 0), greatest(v_diff, 0), 1, v_rule, v_version, v_event,
            'The change in its value');

    if v_kind is not null then
      insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                      item_id, journal_id, currency, debit_minor, credit_minor, posting_date)
      values (v_tenant, v_entity, v_ledger, v_kind, v_inv, p_item_id, v_journal, v_ccy,
              greatest(v_diff, 0), greatest(-v_diff, 0), v_date);
    end if;

    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
     where id = v_journal;
  end if;

  return v_id;
end;
$$;
revoke all on function erp.set_standard_cost(uuid, uuid, bigint, character) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Adopting a roll-up says what it revalued
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.adopt_rolled_up_cost(p_item_id uuid, p_site_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_cost  bigint;
  v_was   bigint;
  v_value bigint;
begin
  perform erp.authorise('finance.configure', null, p_site_id, null, 'item_cost', p_item_id, null);
  v_was := erp.unit_cost_at(p_item_id, p_site_id);
  if not exists (select 1 from erp.bom b where b.tenant_id = erp.require_tenant_id() and b.item_id = p_item_id
                                         and b.status = 'active' and (b.site_id is null or b.site_id = p_site_id)) then
    raise exception 'CLOVEERP_NOT_MADE_HERE: the product has no bill of materials in force here, so nothing rolls up'
      using errcode = '23514', hint = 'Define its bill of materials, and its routing, first.';
  end if;
  v_cost := erp.roll_up_standard_cost(p_item_id, p_site_id);
  v_value := erp.item_stock_value(p_item_id, p_site_id);
  -- erp.set_standard_cost authorises finance.configure, refuses a product not
  -- standard-costed, and revalues what is held (20261013120000).
  perform erp.set_standard_cost(p_item_id, p_site_id, v_cost, null);
  return jsonb_build_object('item_id', p_item_id, 'was_minor', v_was, 'standard_minor', v_cost,
                            'revalued_minor', erp.item_stock_value(p_item_id, p_site_id) - v_value);
end;
$$;
revoke all on function erp.adopt_rolled_up_cost(uuid, uuid) from public, anon;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Revaluing stock at a new standard (20261013120000).'
  from (values
    ('Stock on hand is revalued at the new standard; the difference posts to stock adjustments.'),
    ('The rolled-up cost is now the product''s standard, and the stock held was revalued at it.')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.standard_revaluation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_site   uuid;
  v_uom    uuid;
  v_sup    uuid;
  v_bolt   uuid;
  v_grn    uuid;
  v_inv0   bigint;
  v_adj0   bigint;
  x        jsonb;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzsrv' || v_tag, 'Standard Revaluation Suite',
      'admin@demo-zzsrv' || v_tag || '.test', 'Revaluation Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzsrv' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    v_step := 'ten bolts held at a standard of £2';
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    select p.id into v_sup from erp.party p where p.tenant_id = v_tenant and p.status = 'active' order by p.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (v_tenant, 'ZSRVB' || v_tag, 'Revalued bolt', v_uom, 'active') returning id into v_bolt;
    insert into erp.costing_policy (tenant_id, code, method, item_id) values (v_tenant, 'ZSRV-STD', 'standard', v_bolt);
    perform erp.set_standard_cost(v_bolt, v_site, 200, null);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_bolt, 10, 200, 'bolts');
    perform erp.transition_document(v_grn, 'post');
    v_inv0 := erp_test.account_balance_minor(erp.chart_account_code('inventory'));
    v_adj0 := erp_test.account_balance_minor(erp.chart_account_code('stock_adjustment'));

    -- ── 1. Up ───────────────────────────────────────────────────────────────
    v_step := 'the standard raised to £2.50';
    perform erp.set_standard_cost(v_bolt, v_site, 250, null);
    v_cases := v_cases + 1;
    case_name := 'a standard raised with ten held revalues them, £5 more in stock and £5 credited to stock adjustments';
    passed := v_state is null
          and erp.item_stock_value(v_bolt, v_site) = 2500
          and erp_test.account_balance_minor(erp.chart_account_code('inventory')) - v_inv0 = 500
          and erp_test.account_balance_minor(erp.chart_account_code('stock_adjustment')) - v_adj0 = -500;
    detail := coalesce(v_state, format('stock %s; inventory +%s; adjustments +%s', erp.item_stock_value(v_bolt, v_site),
                                       erp_test.account_balance_minor(erp.chart_account_code('inventory')) - v_inv0,
                                       erp_test.account_balance_minor(erp.chart_account_code('stock_adjustment')) - v_adj0));
    return next;

    -- ── 2. Down ─────────────────────────────────────────────────────────────
    v_step := 'the standard lowered to £1.80';
    perform erp.set_standard_cost(v_bolt, v_site, 180, null);
    v_cases := v_cases + 1;
    case_name := 'lowered, the ten are worth £18, and stock adjustments takes the £7 they lost';
    passed := v_state is null
          and erp.item_stock_value(v_bolt, v_site) = 1800
          and erp_test.account_balance_minor(erp.chart_account_code('inventory')) - v_inv0 = -200
          and erp_test.account_balance_minor(erp.chart_account_code('stock_adjustment')) - v_adj0 = 200;
    detail := coalesce(v_state, format('stock %s', erp.item_stock_value(v_bolt, v_site)));
    return next;

    -- ── 3. Said ─────────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'each change is an event saying from what to what, on how much, and its journal is traced to a rule';
    passed := v_state is null
          and (select count(*) from erp.event e
                where e.tenant_id = v_tenant and e.event_type = 'item.standard_revalued' and e.aggregate_id = v_bolt) = 2
          and exists (select 1 from erp.event e
                       where e.tenant_id = v_tenant and e.event_type = 'item.standard_revalued'
                         and (e.payload ->> 'was_minor')::bigint = 250 and (e.payload ->> 'standard_minor')::bigint = 180
                         and (e.payload ->> 'revalued_minor')::bigint = -700)
          and not exists (select 1 from erp.journal_line jl join erp.journal j on j.id = jl.journal_id
                           where j.tenant_id = v_tenant and j.source_code = 'item.standard_revalued'
                             and jl.posting_rule_id is null);
    detail := coalesce(v_state, (select string_agg(e.payload::text, ' | ') from erp.event e
                                  where e.tenant_id = v_tenant and e.event_type = 'item.standard_revalued'));
    return next;

    -- ── 4. Unchanged ────────────────────────────────────────────────────────
    v_step := 'the same standard again';
    perform erp.set_standard_cost(v_bolt, v_site, 180, null);
    v_cases := v_cases + 1;
    case_name := 'setting the standard it already has posts nothing';
    passed := v_state is null
          and (select count(*) from erp.journal j
                where j.tenant_id = v_tenant and j.source_code = 'item.standard_revalued') = 2;
    detail := coalesce(v_state, (select count(*)::text from erp.journal j
                                  where j.tenant_id = v_tenant and j.source_code = 'item.standard_revalued'));
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
    raise exception 'CLOVEERP_STANDARD_REVALUATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.standard_revaluation_suite() from public, anon, authenticated;

create or replace function erp_test.assert_standard_revaluation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _standard_revaluation on commit drop as
    select * from erp_test.standard_revaluation_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _standard_revaluation;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_STANDARD_REVALUATION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_STANDARD_REVALUATION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('standard revaluation: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_standard_revaluation_suite() from public, anon, authenticated;

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
select erp.assert_no_caller_reachable_internal_routines();
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
select erp.assert_write_only_columns();
