set lock_timeout = '30s';

-- =============================================================================
-- 20261008200000  With no site, the product's own supplier is named
-- -----------------------------------------------------------------------------
-- Found building #410 (J-173). erp.resolve_item_supplier_row(item, site, day)
-- is the one rule for who a product is bought from: "Who would this be
-- bought from?" on Purchasing (public.erp_resolve_item_supplier), the planner
-- (erp.run_planning) and a planned order being firmed
-- (erp.planned_order_supplier) all read it. It sorted the rows by
--
--   (s.site_id is not null and s.site_id = p_site_id) desc
--
-- With a site asked that reads true for the site's own row and false for the
-- product's, as meant. With no site asked it reads null for every site's row
-- (true and null is null) and false for the product's, and a descending sort
-- puts null first. So "Who would this be bought from?" with no site named one
-- site's supplier ahead of the product's default.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.resolve_item_supplier_row sorts in three plain ranks: the site's
--      own row when a site is asked, then the product's own (no site), then
--      any other site's. With no site asked the product's own comes first;
--      with a site asked the site's own does, as before. Within a rank the
--      default and then the preference rank decide, as before. Which rows
--      are considered is unchanged: a product supplied only for one site is
--      still answered with that site's supplier when no site is asked.
--   B. erp_test.item_supplier_without_a_site_suite proves both, through the
--      rule and through the door.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Who may ask, the door's answer for a site, and the planner's answer (it
-- always asks for a site) are unchanged. On production: one function's sort
-- is replaced. No table is altered and no row of any organisation changes;
-- planned orders already made keep the supplier they were given.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The rule
-- ─────────────────────────────────────────────────────────────────────────────

do $resolve$
declare
  v_sig  constant text := 'erp.resolve_item_supplier_row(uuid,uuid,date)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$   order by (s.site_id is not null and s.site_id = p_site_id) desc,
            s.is_default desc, s.preference_rank$o$;
  v_new  constant text := $n$   -- In three ranks (20261008200000): the site's own row when a site is
   -- asked, then the product's own, then another site's. The old test read
   -- null, not false, for a site's row when no site was asked, and a
   -- descending sort put that site's supplier ahead of the product's.
   order by case when s.site_id is null then 1
                 when s.site_id = p_site_id then 0
                 else 2 end,
            s.is_default desc, s.preference_rank$n$;
begin
  if strpos(v_src, '20261008200000') > 0 then
    raise notice '% already sorts in three ranks; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'cb365cec568da79d4630d73af07f2c38' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261008200000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$resolve$;

comment on function erp.resolve_item_supplier_row(uuid, uuid, date) is
  'Who a product is bought from: approved, in-date rows only; the site''s own row when a site is asked, then the '
  'product''s own (no site), then another site''s; within that the default, then the preference rank. With no site '
  'asked the product''s own supplier is named (20261008200000). No row rather than a refusal.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.item_supplier_without_a_site_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  r        record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_north uuid; v_south uuid;
  v_item uuid; v_lone uuid;
  v_own uuid; v_north_supp uuid; v_lone_supp uuid;
  v_got uuid; v_got2 uuid; v_got3 uuid;
  res jsonb; res2 jsonb;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    -- A product with its own default supplier and, for one site, a
    -- different supplier that is that site's default and ranked better. The
    -- site's row goes in first, so a sort that ignores the rank of no site
    -- meets it first and cannot pass by luck.
    v_step := 'an organisation, two sites and a product with two suppliers';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zz-isw-' || v_hex, 'Supplier without a site suite',
      'admin@zz-isw-' || v_hex || '.test', 'Supplier Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zz-isw-' || v_hex || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'NORTH', 'North', 'warehouse', 'active') returning id into v_north;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'SOUTH', 'South', 'warehouse', 'active') returning id into v_south;

    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'OWN', 'The product''s own supplier', 'active') returning id into v_own;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'NORTHSUP', 'North''s supplier', 'active') returning id into v_north_supp;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'LONESUP', 'Only for one site', 'active') returning id into v_lone_supp;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_own, 'supplier', 'active'),
           (r.tenant_id, v_north_supp, 'supplier', 'active'),
           (r.tenant_id, v_lone_supp, 'supplier', 'active');

    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'BOLT', 'Bought for every site', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'LONE', 'Bought for one site only', v_uom, 'active') returning id into v_lone;

    insert into erp.item_supplier (tenant_id, item_id, party_id, site_id, preference_rank,
                                   is_default, is_approved_for_use, status, valid_from)
    values (r.tenant_id, v_item, v_north_supp, v_north, 1, true, true, 'active', current_date - 30),
           (r.tenant_id, v_item, v_own,        null,    5, true, true, 'active', current_date - 30),
           (r.tenant_id, v_lone, v_lone_supp,  v_north, 1, true, true, 'active', current_date - 30);

    -- ── 1. No site: the product's own ───────────────────────────────────────
    v_step := 'the rule asked with no site';
    v_got  := (erp.resolve_item_supplier_row(v_item, null, current_date)).party_id;
    v_got2 := (erp.resolve_item_supplier_row(v_item)).party_id;
    v_cases := v_cases + 1;
    case_name := 'asked with no site, the rule names the product''s own default supplier, not one site''s';
    passed := coalesce(v_state is null and v_got = v_own and v_got2 = v_own, false);
    detail := coalesce(v_state, format('named %s and %s; the product''s own is %s, North''s is %s',
                                       v_got, v_got2, v_own, v_north_supp));
    return next;

    -- ── 2. A site: the site's own ───────────────────────────────────────────
    v_step := 'the rule asked for North';
    v_got := (erp.resolve_item_supplier_row(v_item, v_north, current_date)).party_id;
    v_cases := v_cases + 1;
    case_name := 'asked for a site with a supplier of its own, the rule names that site''s supplier';
    passed := coalesce(v_state is null and v_got = v_north_supp, false);
    detail := coalesce(v_state, format('named %s; North''s is %s', v_got, v_north_supp));
    return next;

    -- ── 3. A site with none of its own: the product's own ───────────────────
    v_step := 'the rule asked for South';
    v_got := (erp.resolve_item_supplier_row(v_item, v_south, current_date)).party_id;
    v_cases := v_cases + 1;
    case_name := 'asked for a site with no supplier of its own, the rule names the product''s own, never another site''s';
    passed := coalesce(v_state is null and v_got = v_own, false);
    detail := coalesce(v_state, format('named %s; the product''s own is %s', v_got, v_own));
    return next;

    -- ── 4. Supplied for one site only ───────────────────────────────────────
    v_step := 'the rule asked for a product supplied for one site only';
    v_got  := (erp.resolve_item_supplier_row(v_lone, null, current_date)).party_id;
    v_got3 := (erp.resolve_item_supplier_row(v_lone, v_south, current_date)).party_id;
    v_cases := v_cases + 1;
    case_name := 'a product supplied for one site only is still answered with that supplier when no site is asked, and not for another site';
    passed := coalesce(v_state is null and v_got = v_lone_supp and v_got3 is null, false);
    detail := coalesce(v_state, format('no site %s, South %s', v_got, coalesce(v_got3::text, 'nobody')));
    return next;

    -- ── 5. The door answers by the same rule ────────────────────────────────
    v_step := 'Who would this be bought from? with and without a site';
    res  := public.erp_resolve_item_supplier(v_item);
    res2 := public.erp_resolve_item_supplier(v_item, v_north);
    v_cases := v_cases + 1;
    case_name := 'Who would this be bought from? names the product''s own supplier with no site, and the site''s with one';
    passed := coalesce(v_state is null
          and (res ->> 'party_id')::uuid = v_own and res ->> 'scope' = 'item'
          and (res2 ->> 'party_id')::uuid = v_north_supp and res2 ->> 'scope' = 'site', false);
    detail := coalesce(v_state, format('no site %s | North %s', res, res2));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  -- ── 6. Undone ─────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := coalesce(not exists (select 1 from erp.tenant where code = 'zz-isw-' || v_hex)
        and v_state is null, false);
  detail := coalesce('the fixture stopped early: ' || v_state,
                     'the organisation rolled back with its sites, products and suppliers');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_ITEM_SUPPLIER_WITHOUT_A_SITE_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_state, 'a case was added or lost');
  end if;
end;
$$;

revoke all on function erp_test.item_supplier_without_a_site_suite() from public, anon;

comment on function erp_test.item_supplier_without_a_site_suite() is
  'With no site, the product''s own supplier is named (20261008200000): the rule and the door name the product''s '
  'default with no site asked, the site''s own supplier for that site, the product''s own for a site with none, and a '
  'product supplied for one site only is still answered.';

create or replace function erp_test.assert_item_supplier_without_a_site_suite()
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
    from erp_test.item_supplier_without_a_site_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ITEM_SUPPLIER_WITHOUT_A_SITE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Who a product is bought from named the wrong supplier for the site asked, or for no site. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_ITEM_SUPPLIER_WITHOUT_A_SITE_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('item supplier without a site: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_item_supplier_without_a_site_suite() from public, anon;

comment on function erp_test.assert_item_supplier_without_a_site_suite() is
  'With no site asked the product''s own supplier is named, and with a site the site''s own (20261008200000).';

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
