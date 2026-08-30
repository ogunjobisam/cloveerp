-- =============================================================================
-- The reads a form needs
--
-- erp_create_document takes p_party_id. erp_add_document_line takes p_item_id.
-- Nothing on the public surface listed a party or an item, so those two
-- functions could be called only by somebody who already knew a uuid — which
-- is to say, from a SQL client, which is where this whole exercise started.
--
-- Six lookups and one status read. They are the smallest set that makes a
-- document form possible, and they arrive after the doors in
-- 20260829340000_master_data_doors.sql rather than before, because until a
-- tenant could create a party or an item these would have returned [] for
-- ever and looked like a working feature.
--
-- All seven are STABLE, so none needs an erp_meta.public_write_allowance row:
-- rule 3 of erp.public_api_report() fires only on provolatile = 'v'. Worth
-- stating, because the natural assumption on seeing a new public function is
-- that it must be allow-listed, and adding a row for a read would be
-- governance describing something it does not govern.
--
-- Tenant scoping is not asserted here by filtering alone — every one of these
-- reads erp.* tables that already carry a generated tenant_isolation policy,
-- and the explicit current_tenant_id() predicate is belt as well as braces.
-- erp_currencies is the deliberate exception and says so.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Parties
--
-- p_role_kind filters server-side rather than in the client, because a sales
-- order picker wants customers and a purchase order picker wants suppliers,
-- and filtering after a p_limit truncation would silently drop the ones the
-- caller was looking for.
-- -----------------------------------------------------------------------------

create or replace function public.erp_parties(
  p_role_kind text default null,
  p_search    text default null,
  p_limit     integer default 200
) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'party_id', p.id, 'code', p.code, 'name', p.name,
      'legal_name', p.legal_name, 'country_code', p.country_code,
      'status', p.status,
      'roles', coalesce((select jsonb_agg(distinct pr.role_kind::text)
                           from erp.party_role pr
                          where pr.tenant_id = p.tenant_id
                            and pr.party_id = p.id
                            and pr.status = 'active'), '[]'::jsonb)) as x
      from erp.party p
     where p.tenant_id = erp.current_tenant_id()
       -- A merged party still resolves for old references, but offering it in
       -- a picker would invite creating new ones against a dead record.
       and p.merged_into_id is null
       and p.status <> 'archived'
       and (p_role_kind is null
            or exists (select 1 from erp.party_role pr2
                        where pr2.tenant_id = p.tenant_id and pr2.party_id = p.id
                          and pr2.role_kind::text = p_role_kind
                          and pr2.status = 'active'))
       and (p_search is null or p.code ilike '%' || p_search || '%'
                             or p.name ilike '%' || p_search || '%')
     order by p.code
     limit greatest(coalesce(p_limit, 200), 1)
  ) s
$$;

-- -----------------------------------------------------------------------------
-- Items
--
-- lifecycle is returned rather than filtered on, so a draft item can be shown
-- as a draft instead of being invisible. A picker that silently omits a record
-- the caller can see elsewhere is how people conclude data has been lost.
-- -----------------------------------------------------------------------------

create or replace function public.erp_items(
  p_search text default null,
  p_limit  integer default 200
) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'item_id', i.id, 'code', i.code, 'name', i.name,
      'item_class', i.item_class, 'item_group', i.item_group,
      'lifecycle', i.lifecycle, 'status', i.status,
      'stock_uom_id', i.stock_uom_id,
      'stock_uom_code', u.code,
      'is_batch_controlled', i.is_batch_controlled,
      'is_serial_controlled', i.is_serial_controlled,
      'has_expiry', i.has_expiry) as x
      from erp.item i
      left join erp.uom u on u.tenant_id = i.tenant_id and u.id = i.stock_uom_id
     where i.tenant_id = erp.current_tenant_id()
       and i.status <> 'archived'
       and (p_search is null or i.code ilike '%' || p_search || '%'
                             or i.name ilike '%' || p_search || '%')
     order by i.code
     limit greatest(coalesce(p_limit, 200), 1)
  ) s
$$;

-- -----------------------------------------------------------------------------
-- Document types
--
-- The one that makes a document form possible at all. Without it a screen has
-- to hard-code 'quotation', 'sales_order', 'delivery' — the coded behaviour
-- this product's thesis denies — and would be wrong for any tenant that named
-- its types differently.
--
-- create_permission comes back too, so a screen can offer an action only where
-- the caller holds the permission the database will actually check. Before
-- 20260829350000 there was nothing honest to return here: the answer was
-- procurement.order for eight of the thirteen base types.
-- -----------------------------------------------------------------------------

create or replace function public.erp_document_types(
  p_base_type_code text default null
) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'document_type_id', dt.id, 'code', dt.code, 'name', dt.name,
      'base_type_code', dt.base_type_code, 'entity_id', dt.entity_id,
      'status', dt.status,
      -- Declared by product content, not by the tenant.
      'flow', bt.flow, 'module_code', bt.module_code,
      'affects_stock', bt.affects_stock, 'affects_finance', bt.affects_finance,
      'requires_party', bt.requires_party, 'requires_site', bt.requires_site,
      'create_permission', bt.create_permission) as x
      from erp.document_type dt
      join erp_ref.document_type bt on bt.code = dt.base_type_code
     where dt.tenant_id = erp.current_tenant_id()
       and dt.status = 'active'
       and (p_base_type_code is null or dt.base_type_code = p_base_type_code)
     order by dt.code
  ) s
$$;

-- -----------------------------------------------------------------------------
-- Locations, units, currencies
-- -----------------------------------------------------------------------------

create or replace function public.erp_locations(
  p_site_id uuid default null
) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'location_id', l.id, 'site_id', l.site_id, 'code', l.code, 'name', l.name,
      'location_type', l.location_type, 'is_pickable', l.is_pickable) as x
      from erp.location l
     where l.tenant_id = erp.current_tenant_id()
       and (p_site_id is null or l.site_id = p_site_id)
     order by l.code
  ) s
$$;

create or replace function public.erp_uoms()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'uom_id', u.id, 'code', u.code, 'name', u.name,
           'uom_class', u.uom_class, 'decimals', u.decimals, 'is_base', u.is_base)
           order by u.code), '[]'::jsonb)
    from erp.uom u
   where u.tenant_id = erp.current_tenant_id() and u.status = 'active'
$$;

-- erp_ref.currency is product content: identical for every tenant, and
-- deliberately NOT scoped by current_tenant_id(). Said out loud because a
-- reviewer of erp.public_api_report() should be able to tell an intentional
-- unscoped read from a forgotten predicate.
--
-- minor_units is the point of returning this at all. The app divides
-- total_minor by 100 unconditionally, which is right for GBP and wrong for
-- JPY by a factor of a hundred.
create or replace function public.erp_currencies()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', c.code, 'name', c.name, 'minor_units', c.minor_units)
           order by c.code), '[]'::jsonb)
    from erp_ref.currency c
   where c.is_active
$$;

-- -----------------------------------------------------------------------------
-- Where the tenant is in its own life
--
-- The configuration screen currently infers the bootstrap window from the
-- shape of the change-set list, because nothing reported it. This reports it.
-- -----------------------------------------------------------------------------

create or replace function public.erp_tenant_state()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select jsonb_build_object(
    'is_live', erp.tenant_is_live(),
    'environment', (select jsonb_build_object('environment_id', e.id, 'code', e.code,
                                              'name', e.name, 'is_live', e.is_live)
                      from erp.environment e
                     where e.tenant_id = erp.current_tenant_id() and e.is_self),
    -- erp.go_live() refuses below two, so a screen can say why before the
    -- button fails rather than after.
    'administrators', (select count(distinct ur.app_user_id)
                         from erp.user_role ur
                         join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                        where ur.tenant_id = erp.current_tenant_id()
                          and r.code = 'administrator'),
    'dead_configuration', coalesce((
      select jsonb_agg(jsonb_build_object('finding', d.finding, 'detail', d.detail))
        from erp.dead_configuration_report() d), '[]'::jsonb))
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.erp_parties(text, text, integer)',
    'public.erp_items(text, integer)',
    'public.erp_document_types(text)',
    'public.erp_locations(uuid)',
    'public.erp_uoms()',
    'public.erp_currencies()',
    'public.erp_tenant_state()'
  ]
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

-- =============================================================================
-- The suite
--
-- The mechanic that matters: `set local role authenticated`. The suite runs as
-- the migration owner, and the owner bypasses row-level security — so a
-- scoping test that only sets request.jwt.claims proves nothing at all. It
-- would be green and worthless, which is the exact failure this repository
-- keeps finding in its own work.
-- =============================================================================

create or replace function erp_test.reference_reads_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  ra record; rb record;
  a1 uuid := gen_random_uuid();
  b1 uuid := gen_random_uuid();
  v_owner text := current_user;
  v_uom_a uuid; v_uom_b uuid;
  v_json jsonb; v_n integer;
begin
  select * into ra from erp.provision_tenant(
    'zzreads-a', 'Reads A', 'a@zzreads.test', 'Reads A Admin');
  select * into rb from erp.provision_tenant(
    'zzreads-b', 'Reads B', 'b@zzreads.test', 'Reads B Admin');

  insert into auth.users (id, email) values (a1, 'a@zzreads.test');
  insert into auth.users (id, email) values (b1, 'b@zzreads.test');

  -- Claim both invitations rather than patching auth_user_id onto the row: a
  -- provisioned administrator is 'invited' until they claim, and
  -- erp.principal_context() resolves only an active principal. Setting the
  -- column alone leaves the subject resolving to nothing, which surfaces much
  -- later as ERPWARE_NO_TENANT_CONTEXT from require_tenant_id().
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(ra.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', b1)::text, true);
  perform erp.claim_invitation(rb.admin_token);
  perform set_config('request.jwt.claims', '', true);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (ra.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom_a;
  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (rb.tenant_id, 'BOX', 'Box', 'quantity', 0, true, 'active') returning id into v_uom_b;

  insert into erp.party (tenant_id, code, name, status)
  values (ra.tenant_id, 'CUST-A', 'Customer A', 'active');
  insert into erp.party (tenant_id, code, name, status)
  values (rb.tenant_id, 'CUST-B', 'Customer B', 'active');

  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  select ra.tenant_id, p.id, 'customer', 'active' from erp.party p
   where p.tenant_id = ra.tenant_id and p.code = 'CUST-A';

  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (ra.tenant_id, 'ITEM-A', 'Item A', v_uom_a, 'active');
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (rb.tenant_id, 'ITEM-B', 'Item B', v_uom_b, 'active');

  -- Every isolation case below asserts tenant B's rows are ABSENT, which would
  -- pass just as well if the fixture had never written them. So assert they
  -- exist first, as the owner, while both are still visible.
  select count(*) into v_n
    from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'CUST-B';
  return query select 'the other tenant''s fixtures really exist',
    v_n = 1
      and exists (select 1 from erp.item i
                   where i.tenant_id = rb.tenant_id and i.code = 'ITEM-B')
      and exists (select 1 from erp.uom u
                   where u.tenant_id = rb.tenant_id and u.code = 'BOX'),
    'without this the isolation cases below could pass by writing nothing';

  -- ---------------------------------------------------------------------
  -- Become tenant A for real, so RLS is actually in force.
  -- ---------------------------------------------------------------------
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', a1, 'role', 'authenticated')::text);
  set local role authenticated;

  v_json := public.erp_parties();
  return query select 'erp_parties returns this tenant and not the other',
    v_json @> '[{"code":"CUST-A"}]'::jsonb and not (v_json @> '[{"code":"CUST-B"}]'::jsonb),
    format('%s parties', jsonb_array_length(v_json));

  return query select 'and filters by role server-side',
    jsonb_array_length(public.erp_parties('customer')) = 1
      and jsonb_array_length(public.erp_parties('carrier')) = 0,
    'a picker truncated by p_limit cannot be filtered afterwards';

  v_json := public.erp_items();
  return query select 'erp_items returns this tenant and not the other',
    v_json @> '[{"code":"ITEM-A"}]'::jsonb and not (v_json @> '[{"code":"ITEM-B"}]'::jsonb),
    format('%s items', jsonb_array_length(v_json));

  return query select 'and resolves the stock unit code, not just its id',
    public.erp_items() @> '[{"stock_uom_code":"EA"}]'::jsonb,
    'a picker showing a uuid is not a picker';

  v_json := public.erp_uoms();
  return query select 'erp_uoms returns this tenant and not the other',
    v_json @> '[{"code":"EA"}]'::jsonb and not (v_json @> '[{"code":"BOX"}]'::jsonb),
    format('%s units', jsonb_array_length(v_json));

  return query select 'erp_locations is scoped to the tenant',
    public.erp_locations() = '[]'::jsonb,
    'tenant A has no locations; tenant B''s must not leak in';

  v_json := public.erp_currencies();
  return query select 'erp_currencies is product content, shared on purpose',
    jsonb_array_length(v_json) > 0 and v_json @> '[{"code":"GBP"}]'::jsonb,
    'identical for every tenant, and deliberately not scoped';

  return query select 'and carries minor_units, which is the point of it',
    v_json @> '[{"code":"JPY","minor_units":0}]'::jsonb
      and v_json @> '[{"code":"GBP","minor_units":2}]'::jsonb,
    'the app divides by 100 unconditionally, which is wrong for JPY by a '
    'factor of a hundred';

  v_json := public.erp_tenant_state();
  return query select 'erp_tenant_state reports the bootstrap window',
    (v_json ->> 'is_live') is not null
      and (v_json -> 'environment' ->> 'environment_id') is not null,
    format('is_live=%s', v_json ->> 'is_live');

  return query select 'and counts the administrators go-live requires',
    (v_json ->> 'administrators')::integer >= 1,
    'erp.go_live() refuses below two, so a screen can say why beforehand';

  return query select 'erp_document_types carries the permission to raise one',
    not exists (
      select 1 from jsonb_array_elements(public.erp_document_types()) e
       where e ->> 'create_permission' is null),
    'so a screen can offer an action only where the caller holds what the '
    'database will check';

  -- ---------------------------------------------------------------------
  -- Back to the owner to clean up.
  -- ---------------------------------------------------------------------
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  perform erp.begin_tenant_purge(ra.tenant_id);
  delete from erp.tenant where id = ra.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(rb.tenant_id);
  delete from erp.tenant where id = rb.tenant_id;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, b1);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t
                 where t.id in (ra.tenant_id, rb.tenant_id)),
    'both tenants and both fabricated subjects';
end;
$$;

create or replace function erp_test.assert_reference_reads_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Thirteen: one proving the other tenant's fixtures exist, eleven reads,
  -- and the purge.
  c_expected constant integer := 13;
begin
  create temporary table if not exists zz_reads_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_reads_result;
  insert into zz_reads_result select * from erp_test.reference_reads_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_reads_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_REFERENCE_READS_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_REFERENCE_READS_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('reference reads: %s/%s', v_pass, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_isolation();
