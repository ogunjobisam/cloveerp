set lock_timeout = '30s';

-- =============================================================================
-- 20261006180000  Who it would be bought from says which approval
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-109). On Item supply,
-- "Who would this be bought from?" answered APPROVED No for a supplier the
-- table above it marks Approved Yes, and printed ITEM SUPPLIER ID, PARTY ID
-- and SITE ID as raw identifiers:
--
--   (a) public.erp_resolve_item_supplier answered 'approved' as whether the
--       SUPPLIER is qualified (erp.party_role.is_approved, set by "Qualify a
--       supplier"), while the table's Approved column is whether this supply
--       arrangement is approved for use (erp.item_supplier.is_approved_for_use).
--       Two approvals shared one word, and the answer only ever named one.
--   (b) It answered the site as site_id, an identifier, and nothing a person
--       can read.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The door answers both approvals under their own names:
--      supplier_qualified (the supplier's qualification, what 'approved' was)
--      and approved_for_use (the arrangement's own approval; the rule only
--      ever chooses an approved one, so it says so rather than leaving the
--      reader to know it). 'approved' is gone. The site is answered as its
--      code, 'site', in place of site_id. item_supplier_id and party_id stay:
--      erp_test.planned_supplier_suite reads party_id, and the screen no
--      longer prints an identifier (src/components/erp/inquiry.tsx).
--   B. erp_test.item_supplier_answer_suite.
--
-- Nothing else reads the door's answer: planning and firming call
-- erp.resolve_item_supplier_row, which is unchanged.
--
-- On production: one door is patched. No table is altered and no row is
-- changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Both approvals, under their own names, and the site by its code
-- ─────────────────────────────────────────────────────────────────────────────

do $resolve$
declare
  v_sig  constant text := 'public.erp_resolve_item_supplier(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select jsonb_build_object(
    'item_supplier_id', s.id, 'party_id', s.party_id, 'supplier', p.name,
    'site_id', s.site_id, 'scope', case when s.site_id is null then 'item' else 'site' end,
    'preference_rank', s.preference_rank, 'is_default', s.is_default,
    'split_pct', s.split_pct, 'lead_time_days', s.lead_time_days,
    'min_order_quantity', s.min_order_quantity,
    'approved', coalesce(bool_or(r.is_approved), false))$o$;
  v_new  constant text := $n$  -- Two approvals, each under its own name (20261006180000, J-109): whether
  -- the supplier is qualified, and whether this arrangement is approved for
  -- use, which the rule requires of every row it chooses. The site by its
  -- code, not its identifier.
  select jsonb_build_object(
    'item_supplier_id', s.id, 'party_id', s.party_id, 'supplier', p.name,
    'site', (select si.code from erp.site si
              where si.tenant_id = s.tenant_id and si.id = s.site_id),
    'scope', case when s.site_id is null then 'item' else 'site' end,
    'preference_rank', s.preference_rank, 'is_default', s.is_default,
    'split_pct', s.split_pct, 'lead_time_days', s.lead_time_days,
    'min_order_quantity', s.min_order_quantity,
    'approved_for_use', s.is_approved_for_use,
    'supplier_qualified', coalesce(bool_or(r.is_approved), false))$n$;
begin
  if strpos(v_src, '20261006180000') > 0 then
    raise notice '% already names both approvals; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '8d67c5a0165a4e89fcbb32fef9cf9289' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006180000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$resolve$;

comment on function public.erp_resolve_item_supplier(uuid, uuid) is
  'Who a product would be bought from at a site, by the rule replenishment and planning use '
  '(erp.resolve_item_supplier_row), under procurement.read. Answers the supplier, the site by its code, '
  'whether the supplier is qualified (supplier_qualified) and whether the arrangement is approved for use '
  '(approved_for_use), each under its own name (20261006180000). Refused with CLOVEERP_NO_SUPPLIER when '
  'nobody supplies it there.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.item_supplier_answer_suite()
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
  v_site   uuid;
  v_code   text;
  v_uom    uuid;
  v_item   uuid;
  v_wide_item uuid;
  v_supp   uuid;
  v_other  uuid;
  v_before jsonb;
  v_after  jsonb;
  v_wide   jsonb;
begin
  begin
    -- ── The fixture: a product bought from one supplier anywhere and from ───
    -- ── another, not yet qualified, at one site; and a product bought only ──
    -- ── from the first, anywhere ────────────────────────────────────────────
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzisa-' || v_tag, 'Item Supplier Answer Suite',
      'admin@zzisa-' || v_tag || '.test', 'Item Supplier Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzisa-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'a product, its supplier everywhere and another at one site';
    select s.id, s.code into v_site, v_code from erp.site s
     where s.tenant_id = rb.tenant_id order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZZISA-ITEM', 'Something bought in', v_uom, 'active'::erp.record_status)
    returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZZISA-WIDE', 'Bought from one supplier anywhere', v_uom, 'active'::erp.record_status)
    returning id into v_wide_item;
    select p.id into v_supp from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
       and pr.role_kind = 'supplier' and pr.status = 'active'
     where p.tenant_id = rb.tenant_id order by p.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZZISA-SITE', 'The site''s own supplier', 'active'::erp.record_status)
    returning id into v_other;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_other, 'supplier', 'active');
    insert into erp.item_supplier (tenant_id, item_id, party_id, site_id, preference_rank,
                                   is_default, is_approved_for_use, status, valid_from)
    values (rb.tenant_id, v_item, v_supp,  null,   1, true,  true, 'active'::erp.record_status, current_date - 30),
           (rb.tenant_id, v_item, v_other, v_site, 5, false, true, 'active'::erp.record_status, current_date - 30),
           (rb.tenant_id, v_wide_item, v_supp, null, 1, true, true, 'active'::erp.record_status, current_date - 30);

    -- ── 1. At the site: the site's supplier, its site by code, both approvals
    v_step := 'the door asked at the site';
    v_before := public.erp_resolve_item_supplier(v_item, v_site);
    v_cases := v_cases + 1;
    case_name := 'asked at a site, the answer names the site by its code and says both approvals under their own names, with no identifier for the site';
    passed := v_state is null
          and (v_before ->> 'party_id')::uuid = v_other
          and v_before ->> 'site' = v_code
          and v_before ->> 'scope' = 'site'
          and not (v_before ? 'site_id')
          and not (v_before ? 'approved')
          and jsonb_typeof(v_before -> 'approved_for_use') = 'boolean'
          and (v_before ->> 'approved_for_use')::boolean
          and jsonb_typeof(v_before -> 'supplier_qualified') = 'boolean'
          and not (v_before ->> 'supplier_qualified')::boolean;
    detail := coalesce(v_state, left(v_before::text, 400));
    return next;

    -- ── 2. Qualifying the supplier is the approval 'supplier_qualified' reads
    v_step := 'the site''s supplier qualified';
    perform erp.qualify_supplier(v_other, interval '1 year', 'the item supplier answer suite');
    v_after := public.erp_resolve_item_supplier(v_item, v_site);
    v_cases := v_cases + 1;
    case_name := 'qualifying the supplier turns supplier_qualified on and leaves approved_for_use as the arrangement says';
    passed := v_state is null
          and (v_after ->> 'supplier_qualified')::boolean
          and (v_after ->> 'approved_for_use')::boolean
          and (select pr.is_approved from erp.party_role pr
                where pr.tenant_id = rb.tenant_id and pr.party_id = v_other
                  and pr.role_kind = 'supplier');
    detail := coalesce(v_state, left(v_after::text, 400));
    return next;

    -- ── 3. A supplier for the product anywhere names no site ────────────────
    v_step := 'the door asked for a product supplied the same everywhere';
    v_wide := public.erp_resolve_item_supplier(v_wide_item, v_site);
    v_cases := v_cases + 1;
    case_name := 'a supplier set up for the product anywhere is answered with no site and scope item';
    passed := v_state is null
          and (v_wide ->> 'party_id')::uuid = v_supp
          and v_wide ? 'site' and v_wide -> 'site' = 'null'::jsonb
          and v_wide ->> 'scope' = 'item'
          and not (v_wide ? 'site_id');
    detail := coalesce(v_state, left(v_wide::text, 400));
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
    raise exception 'CLOVEERP_ITEM_SUPPLIER_ANSWER_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.item_supplier_answer_suite() from public, anon;

comment on function erp_test.item_supplier_answer_suite() is
  'Who it would be bought from says which approval (20261006180000, J-109): the answer names the site by its '
  'code, says whether the supplier is qualified and whether the arrangement is approved for use under their '
  'own names, and qualifying the supplier is what turns supplier_qualified on.';

create or replace function erp_test.assert_item_supplier_answer_suite()
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
    from erp_test.item_supplier_answer_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ITEM_SUPPLIER_ANSWER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Who it would be bought from names an approval under the wrong word, or the site by an identifier. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_ITEM_SUPPLIER_ANSWER_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('who it would be bought from says which approval: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_item_supplier_answer_suite() from public, anon;

comment on function erp_test.assert_item_supplier_answer_suite() is
  'erp_resolve_item_supplier answers supplier_qualified and approved_for_use under their own names and the '
  'site by its code (20261006180000).';

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
