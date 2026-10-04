set lock_timeout = '30s';

-- =============================================================================
-- 20261005500000  The demonstration has a price list
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October. The sales flow opens
-- with "work out what this customer pays for these products today", and Find
-- a price answered nothing for every product and customer; a new quotation
-- and a new requisition said "No agreed price" under every line. The
-- demonstration holds no row in erp.item_price at all.
--
-- It was built before price lists were (20261003720000), and its own trading
-- never needed one: erp.seed_demo_history() types each line's price from the
-- product's demo attributes, list_minor for what it sells at and cost_minor
-- for what its supplier charges. A person raising a document by hand has no
-- such attributes to read, and is shown nothing.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.seed_demo_prices(tenant): in a demonstration, each demo product
--      gets a sales list price at its list_minor, and a purchase list price
--      from the supplier its attributes name at its cost_minor: the same
--      figures its history trades at. A product that already has such a
--      price keeps it. Nothing in an organisation that is not a
--      demonstration.
--   B. erp.ensure_demo_configuration() calls it, so a new demonstration has
--      them from the start and an existing one gains them as it next trades.
--   C. Every demonstration there is today gains them here, and the migration
--      says which.
--
-- Proof: erp_test.demo_prices_suite.
-- =============================================================================

create or replace function erp.seed_demo_prices(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_ccy   character(3);
  v_sales integer := 0;
  v_buys  integer := 0;
begin
  -- A demonstration's price lists (20261005500000): what each demo product
  -- sells at and what its supplier charges, from the attributes its history
  -- already trades at. Only in a demonstration, and never over a price
  -- somebody set.
  if erp.current_tenant_id() is distinct from p_tenant_id then
    raise exception
      'CLOVEERP_DEMO_TENANT_MISMATCH: the session is in organisation % and this '
      'call names %', coalesce(erp.current_tenant_id()::text, 'nobody'), p_tenant_id
      using errcode = '42501',
      hint = 'Adopt the organisation first: erp.set_active_tenant() for a person, '
             'erp.set_job_tenant() for a worker.';
  end if;
  if not erp.tenant_is_demonstration(p_tenant_id) then
    return 0;
  end if;

  -- The currency the demonstration trades in: its trading company's.
  select e.base_currency into v_ccy
    from erp.entity e
    join erp.ledger l on l.tenant_id = e.tenant_id and l.entity_id = e.id and l.is_primary
   where e.tenant_id = p_tenant_id and e.status = 'active'
   order by e.code
   limit 1;
  if v_ccy is null then
    return 0;
  end if;

  insert into erp.item_price (tenant_id, item_id, price_kind, currency, amount_minor, valid_from)
  select p_tenant_id, i.id, 'sales_list'::erp.price_kind, v_ccy,
         (i.attributes -> 'demo' ->> 'list_minor')::bigint, date '2024-01-01'
    from erp.item i
   where i.tenant_id = p_tenant_id
     and i.status = 'active'::erp.record_status
     and (i.attributes -> 'demo' ->> 'list_minor') ~ '^[0-9]+$'
     and (i.attributes -> 'demo' ->> 'list_minor')::bigint > 0
     and not exists (select 1 from erp.item_price x
                      where x.tenant_id = i.tenant_id and x.item_id = i.id
                        and x.price_kind = 'sales_list');
  get diagnostics v_sales = row_count;

  insert into erp.item_price (tenant_id, item_id, price_kind, party_role_id, currency, amount_minor, valid_from)
  select p_tenant_id, i.id, 'purchase_list'::erp.price_kind, pr.id, v_ccy,
         (i.attributes -> 'demo' ->> 'cost_minor')::bigint, date '2024-01-01'
    from erp.item i
    join erp.party p
      on p.tenant_id = i.tenant_id
     and p.code = i.attributes -> 'demo' ->> 'supplier'
     and p.status = 'active'::erp.record_status
    join erp.party_role pr
      on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'supplier' and pr.status = 'active'
   where i.tenant_id = p_tenant_id
     and i.status = 'active'::erp.record_status
     and (i.attributes -> 'demo' ->> 'cost_minor') ~ '^[0-9]+$'
     and (i.attributes -> 'demo' ->> 'cost_minor')::bigint > 0
     and not exists (select 1 from erp.item_price x
                      where x.tenant_id = i.tenant_id and x.item_id = i.id
                        and x.price_kind = 'purchase_list');
  get diagnostics v_buys = row_count;

  return v_sales + v_buys;
end;
$$;

revoke all on function erp.seed_demo_prices(uuid) from public, anon;

comment on function erp.seed_demo_prices(uuid) is
  'A demonstration''s price lists: each demo product''s sales list price and its supplier''s purchase list '
  'price, from the attributes its history trades at (20261005500000). Called by erp.ensure_demo_configuration().';

do $configure$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if erp.seed_demo_item_suppliers(p_tenant_id) > 0 then
    v_did := v_did || '"product suppliers"'::jsonb;
  end if;
$o$;
  v_new  constant text := $n$  if erp.seed_demo_item_suppliers(p_tenant_id) > 0 then
    v_did := v_did || '"product suppliers"'::jsonb;
  end if;

  -- What each product sells at and what its supplier charges, so a price can
  -- be found by somebody raising a document by hand (20261005500000).
  if erp.seed_demo_prices(p_tenant_id) > 0 then
    v_did := v_did || '"price lists"'::jsonb;
  end if;
$n$;
begin
  if strpos(v_src, '20261005500000') > 0 then
    raise notice '% already seeds the price lists; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e135b34e4b923da667c9459271345000' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005500000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demo_prices_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  rc       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_conf   jsonb;
  v_again  jsonb;
  v_item   uuid; v_list bigint; v_cost bigint; v_customer uuid; v_supplier uuid;
  v_sell   jsonb; v_buy jsonb;
  v_items  integer; v_priced integer;
begin
  begin
    -- ── The fixture: a demonstration ────────────────────────────────────────
    v_step := 'a demonstration configured from nothing';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzpr' || v_tag, 'Demo Prices Suite',
      'admin@demo-zzpr' || v_tag || '.test', 'Prices Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzpr' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    v_conf := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select count(*) into v_items from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active' and i.attributes ? 'demo';
    select count(distinct x.item_id) into v_priced from erp.item_price x
     where x.tenant_id = rb.tenant_id and x.price_kind = 'sales_list';

    -- ── 1. Configured, it has its lists ─────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a demonstration configured from nothing holds a sales list price for every demo product, and says it added the price lists';
    passed := v_state is null and v_items > 0 and v_priced = v_items
          and (v_conf -> 'installed') ? 'price lists';
    detail := coalesce(v_state, format('%s demo product(s), %s with a sales list price', v_items, v_priced));
    return next;

    -- ── 2. Find a price answers ─────────────────────────────────────────────
    v_step := 'finding a price for a customer and for a supplier';
    select i.id, (i.attributes -> 'demo' ->> 'list_minor')::bigint, (i.attributes -> 'demo' ->> 'cost_minor')::bigint,
           (select p.id from erp.party p where p.tenant_id = i.tenant_id and p.code = i.attributes -> 'demo' ->> 'supplier')
      into v_item, v_list, v_cost, v_supplier
      from erp.item i
     where i.tenant_id = rb.tenant_id and i.attributes ? 'demo' and i.status = 'active'
       and (i.attributes -> 'demo' ->> 'supplier') is not null
     order by i.code limit 1;
    select p.id into v_customer
      from erp.party p join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'customer'
     where p.tenant_id = rb.tenant_id and p.status = 'active' order by p.code limit 1;
    v_sell := public.erp_resolve_price(v_item, v_customer, 1);
    v_buy := public.erp_resolve_purchase_price(v_item, v_supplier, 1, null, null);
    v_cases := v_cases + 1;
    case_name := 'Find a price answers the product''s list price for a customer, and Find a purchase price its supplier''s price, with no site chosen';
    passed := v_state is null
          and (v_sell #>> '{0,amount_minor}')::bigint = v_list
          and (v_buy ->> 'amount_minor')::bigint = v_cost;
    detail := coalesce(v_state, left(format('list %s cost %s | sell %s | buy %s', v_list, v_cost, v_sell, v_buy), 400));
    return next;

    -- ── 3. Asked again, nothing more ────────────────────────────────────────
    v_step := 'configuring again';
    v_again := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_cases := v_cases + 1;
    case_name := 'configured again, nothing is added';
    passed := v_state is null and not ((v_again -> 'installed') ? 'price lists')
          and erp.seed_demo_prices(rb.tenant_id) = 0;
    detail := coalesce(v_state, (v_again -> 'installed')::text);
    return next;

    -- ── 4. A price somebody set is kept ─────────────────────────────────────
    v_step := 'a product whose price somebody changed';
    update erp.item_price set amount_minor = v_list + 100
     where tenant_id = rb.tenant_id and item_id = v_item and price_kind = 'sales_list';
    perform erp.seed_demo_prices(rb.tenant_id);
    v_cases := v_cases + 1;
    case_name := 'a price somebody set is kept, and no second one is added beside it';
    passed := v_state is null
          and (select count(*) from erp.item_price x
                where x.tenant_id = rb.tenant_id and x.item_id = v_item and x.price_kind = 'sales_list') = 1
          and (public.erp_resolve_price(v_item, v_customer, 1) #>> '{0,amount_minor}')::bigint = v_list + 100;
    detail := coalesce(v_state, 'one sales list price, as changed');
    return next;

    -- ── 5. Not in an ordinary organisation ──────────────────────────────────
    v_step := 'an organisation that is not a demonstration';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant(
      'zzpr-' || v_tag, 'Not A Demo Suite', 'admin@zzpr-' || v_tag || '.test', 'Plain Admin');
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzpr-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    v_conf := erp.ensure_demo_configuration(rc.tenant_id, rc.admin_user_id);
    v_cases := v_cases + 1;
    case_name := 'an organisation that is not a demonstration is given no prices';
    passed := v_state is null and not ((v_conf -> 'installed') ? 'price lists')
          and not exists (select 1 from erp.item_price x where x.tenant_id = rc.tenant_id);
    detail := coalesce(v_state, (v_conf -> 'installed')::text);
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
    raise exception 'CLOVEERP_DEMO_PRICES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demo_prices_suite() from public, anon;

comment on function erp_test.demo_prices_suite() is
  'The demonstration has a price list (20261005500000): every demo product priced for sale and from its '
  'supplier, Find a price answering, nothing added twice or over a price somebody set, and nothing outside a demonstration.';

create or replace function erp_test.assert_demo_prices_suite()
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
    from erp_test.demo_prices_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMO_PRICES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The demonstration''s first sales step would find no price. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_DEMO_PRICES_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demo prices: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demo_prices_suite() from public, anon;

comment on function erp_test.assert_demo_prices_suite() is
  'A demonstration holds price lists for its products, and only a demonstration (20261005500000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Every demonstration there is today, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $seed$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.seed_demo_prices(r.id);
    if v_n > 0 then
      raise warning 'demo prices: % price(s) added to %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$seed$;

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
