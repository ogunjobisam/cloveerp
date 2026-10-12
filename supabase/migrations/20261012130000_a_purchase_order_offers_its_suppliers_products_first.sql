-- A purchase order offers its supplier's products first.
--
-- On the v1 known-issues list (KI-03, the live walk of 7 October): a purchase
-- order's product picker offered every product in the catalogue whatever the
-- supplier, so a buyer ordering steel bar from a steel mill scrolled past
-- cartons and cable. erp.item_supplier already says which products each
-- supplier sells, with the supplier's own code for each.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_items gains p_supplier_id and p_for_document, defaulted, so
--      every existing call answers as before. Given a supplier, or a purchase
--      order whose supplier it reads, it lists that supplier's products first,
--      each with the supplier's code for it, then every other product, marked
--      as not from this supplier: nothing is hidden, so a buyer can still
--      order something new from them. Each row says from_supplier (true or
--      false; null when no supplier was asked) and supplier_item_code. The
--      function is dropped and made again: a name carries one function.
--   B. erp_test.sales_priced_products_suite pinned the old arguments; it
--      learns the new ones.
--   C. Four screen strings: two for the product picker, and two for the
--      "Invoice a delivery" and "Bill a receipt" pickers when nothing is left
--      to invoice or bill (KI-05), which said "Nothing to choose from yet".
--   D. erp_test.suppliers_products_first_suite proves A.

drop function if exists public.erp_items(text, integer, boolean);

create function public.erp_items(
  p_search       text    default null,
  p_limit        integer default 200,
  p_sales_priced boolean default false,
  p_supplier_id  uuid    default null,
  p_for_document uuid    default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with supplier as (
    -- The supplier asked for, or the one a purchase order names.
    select coalesce(
             p_supplier_id,
             (select d.party_id
                from erp.document d
                join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
               where d.tenant_id = erp.current_tenant_id() and d.id = p_for_document
                 and dt.base_type_code = 'purchase_order')) as party_id
  )
  select coalesce(jsonb_agg(x order by (x->>'from_supplier') = 'true' desc, x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'item_id', i.id, 'code', i.code, 'name', i.name,
      'description', i.description,
      'item_class', i.item_class, 'item_group', i.item_group,
      'lifecycle', i.lifecycle, 'status', i.status,
      'stock_uom_id', i.stock_uom_id,
      'stock_uom_code', u.code,
      'is_batch_controlled', i.is_batch_controlled,
      'is_serial_controlled', i.is_serial_controlled,
      'has_expiry', i.has_expiry,
      -- Whether the supplier asked about sells it, and their code for it
      -- (20261012130000). Null when no supplier was asked.
      'from_supplier', case when sp.party_id is null then null else src.item_id is not null end,
      'supplier_item_code', src.supplier_item_code) as x
      from erp.item i
      cross join supplier sp
      left join erp.uom u on u.tenant_id = i.tenant_id and u.id = i.stock_uom_id
      left join lateral (
        select s.item_id, s.supplier_item_code
          from erp.item_supplier s
         where s.tenant_id = i.tenant_id and s.item_id = i.id and s.party_id = sp.party_id
           and s.status = 'active'
           and (s.valid_from is null or s.valid_from <= current_date)
           and (s.valid_to is null or s.valid_to >= current_date)
         order by s.is_default desc, s.preference_rank nulls last
         limit 1) src on true
     where i.tenant_id = erp.current_tenant_id()
       and i.status <> 'archived'
       and (p_search is null or i.code ilike '%' || p_search || '%'
                             or i.name ilike '%' || p_search || '%')
       -- Asked for priced products only, a product with a selling price in
       -- force today (20261007101000): one with none can only answer that
       -- nothing prices it.
       and (not coalesce(p_sales_priced, false)
            or exists (select 1 from erp.item_price p
                        where p.tenant_id = i.tenant_id and p.item_id = i.id
                          and p.price_kind in ('contract', 'promotion', 'sales_list')
                          and p.valid_from <= current_date
                          and (p.valid_to is null or p.valid_to > current_date)))
     -- The supplier's own first, so the limit is never spent before them.
     order by (src.item_id is not null) desc, i.code
     limit greatest(coalesce(p_limit, 200), 1)
  ) s
$$;
revoke all on function public.erp_items(text, integer, boolean, uuid, uuid) from public, anon;
grant execute on function public.erp_items(text, integer, boolean, uuid, uuid) to authenticated, service_role;
comment on function public.erp_items(text, integer, boolean, uuid, uuid) is
  'The organisation''s products not archived, by code. p_sales_priced lists only those with a selling price in force '
  'today (20261007101000). Given p_supplier_id, or p_for_document naming a purchase order, the supplier''s products '
  'come first with their code for each, then every other product, each row saying from_supplier (20261012130000). '
  'Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The pinned suite learns the new arguments
-- ─────────────────────────────────────────────────────────────────────────────

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.sales_priced_products_suite()'::regprocedure);
  v_old text := $p$public.erp_items(text,integer,boolean)$p$;
  v_new text := $q$public.erp_items(text,integer,boolean,uuid,uuid)$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 4 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.sales_priced_products_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A purchase order''s product picker, and pickers with nothing left to do (20261012130000).'
  from (values
    ('{product} (their code {code})'),
    ('{product} (not from this supplier)'),
    ('Every posted delivery has been invoiced.'),
    ('Every posted goods receipt has been billed.')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.suppliers_products_first_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid; v_site uuid; i_fg uuid; i_rm uuid; p_sup uuid; p_cus uuid;
  v_po     uuid; v_so uuid;
  v_all    jsonb; v_sup jsonb; v_doc jsonb; v_sale jsonb;
  v_first  jsonb;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzspf' || v_tag, 'Suppliers Products Suite',
      'admin@demo-zzspf' || v_tag || '.test', 'Products Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzspf' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_ent from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select i.id into i_fg from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
    select pt.id into p_sup from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'S-FAST';
    select pt.id into p_cus from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'C-HARBOUR';

    v_step := 'the supplier sells one product only, FG-1000, as ZZ-77';
    update erp.item_supplier set status = 'inactive' where tenant_id = v_tenant and party_id = p_sup;
    insert into erp.item_supplier (tenant_id, item_id, party_id, preference_rank, is_default, supplier_item_code, status)
    values (v_tenant, i_fg, p_sup, 1, false, 'ZZ-77', 'active');

    v_all := public.erp_items(p_limit => 1000);
    v_sup := public.erp_items(p_limit => 1000, p_supplier_id => p_sup);

    -- ── 1. Not asked, as before ─────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'not asked about a supplier, every product is listed by code, saying nothing of suppliers';
    passed := v_state is null and jsonb_array_length(v_all) > 1
          and not exists (select 1 from jsonb_array_elements(v_all) e where e -> 'from_supplier' <> 'null'::jsonb);
    detail := coalesce(v_state, format('%s product(s)', jsonb_array_length(v_all)));
    return next;

    -- ── 2. The supplier's own first, with their code ───────────────────────
    v_first := v_sup -> 0;
    v_cases := v_cases + 1;
    case_name := 'asked about a supplier, its own product comes first, with the supplier''s code for it';
    passed := v_state is null and v_first ->> 'code' = 'FG-1000'
          and (v_first ->> 'from_supplier')::boolean and v_first ->> 'supplier_item_code' = 'ZZ-77';
    detail := coalesce(v_state, coalesce(v_first::text, 'nothing'));
    return next;

    -- ── 3. Nothing hidden ──────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'every other product follows, marked as not from this supplier, so nothing is hidden';
    passed := v_state is null and jsonb_array_length(v_sup) = jsonb_array_length(v_all)
          and (select count(*) from jsonb_array_elements(v_sup) e where (e ->> 'from_supplier')::boolean) = 1
          and not exists (select 1 from jsonb_array_elements(v_sup) e where e -> 'from_supplier' = 'null'::jsonb);
    detail := coalesce(v_state, format('%s listed, %s from the supplier', jsonb_array_length(v_sup),
                       (select count(*) from jsonb_array_elements(v_sup) e where (e ->> 'from_supplier')::boolean)));
    return next;

    -- ── 4. A purchase order answers for its supplier ───────────────────────
    v_step := 'a purchase order to the supplier';
    v_po := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    v_doc := public.erp_items(p_limit => 1000, p_for_document => v_po);
    v_cases := v_cases + 1;
    case_name := 'a purchase order''s own supplier decides the order, as if the supplier were named';
    passed := v_state is null and v_doc = v_sup;
    detail := coalesce(v_state, coalesce((v_doc -> 0)::text, 'nothing'));
    return next;

    -- ── 5. A sales order names no supplier ─────────────────────────────────
    v_step := 'a sales order';
    v_so := erp.open_document('sales_order', p_cus, v_ent, v_site, 'CUST-PO-94');
    v_sale := public.erp_items(p_limit => 1000, p_for_document => v_so);
    v_cases := v_cases + 1;
    case_name := 'a document that is not a purchase order names no supplier, and the list is as before';
    passed := v_state is null and v_sale = v_all;
    detail := coalesce(v_state, format('%s product(s)', jsonb_array_length(v_sale)));
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
    raise exception 'CLOVEERP_SUPPLIERS_PRODUCTS_FIRST_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.suppliers_products_first_suite() from public, anon, authenticated;

create or replace function erp_test.assert_suppliers_products_first_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _suppliers_products_first on commit drop as
    select * from erp_test.suppliers_products_first_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _suppliers_products_first;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SUPPLIERS_PRODUCTS_FIRST_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_SUPPLIERS_PRODUCTS_FIRST_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('suppliers products first: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_suppliers_products_first_suite() from public, anon, authenticated;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_isolation();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
