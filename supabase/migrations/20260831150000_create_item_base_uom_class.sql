-- The other half of the base-unit fix.
--
-- 20260831130000 corrected erp.ensure_base_uom() to resolve a base unit within
-- the quantity class, because uom_one_base_per_class permits one base unit per
-- class and ordering by code across all of them picks whichever sorts first.
-- Its pull request said the bug was fixed. It was fixed in one of the two
-- places that resolve a base unit, and I did not check for the second.
--
-- erp.create_item() has the identical resolution and did not get the same
-- correction, so the product answered the same question two ways:
--
--   erp.create_item stocked the item in: CM
--   erp.ensure_base_uom would pick:      EA
--
-- on a tenant holding EA as its base quantity and CM as its base length, which
-- is an ordinary thing for a tenant to hold. An item stocked in centimetres is
-- not a validation error anywhere downstream: it prices, it posts, and it is
-- wrong.
--
-- The two functions stay separate rather than one calling the other, because
-- they answer different questions. ensure_base_uom() creates EA when a tenant
-- has none, which is right on the import path where there is no person to ask.
-- create_item() refuses with ERPWARE_NO_BASE_UOM and a hint naming the call
-- that fixes it, which is right when somebody is typing a form.

create or replace function erp.create_item(
  p_code text, p_name text, p_stock_uom_id uuid default null,
  p_item_class text default null, p_values jsonb default '{}'::jsonb)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $fn$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_uom    uuid := p_stock_uom_id;
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'item', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_ITEM_CODE_REQUIRED: an item needs a code'
      using errcode = '23514';
  end if;

  -- Same resolution erp.load_import does, so an item created either way holds
  -- the same unit.
  if v_uom is null then
    select u.id into v_uom
      from erp.uom u
     where u.tenant_id = v_tenant
       and u.is_base
       -- Stock is a quantity. Without this a tenant whose base length is CM
       -- gets CM as the stock unit of its next item, because CM sorts first.
       and u.uom_class = 'quantity'::erp.uom_class
       and u.status = 'active'
     order by u.code
     limit 1;
  end if;

  if v_uom is null then
    raise exception
      'ERPWARE_NO_BASE_UOM: this tenant has no base unit of measure, and an '
      'item is stocked in one'
      using errcode = '23502',
            hint = 'erp_create_uom(''EA'', ''Each'', ''quantity'', 0, true) '
                   'creates one. Every item in the tenant will be stocked in '
                   'it unless given another.';
  end if;

  if not exists (select 1 from erp.uom u
                  where u.tenant_id = v_tenant and u.id = v_uom) then
    raise exception 'ERPWARE_UNKNOWN_UOM: % is not a unit in this tenant', v_uom
      using errcode = '23503';
  end if;

  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id,
                        lifecycle, status)
  values (v_tenant, trim(p_code), coalesce(nullif(trim(p_name), ''), trim(p_code)),
          nullif(trim(coalesce(p_item_class, '')), ''), v_uom, 'active', 'active')
  returning id into v_id;

  if p_values <> '{}'::jsonb then
    perform erp.write_master_fields('item', v_id, p_values - 'code');
  end if;

  return v_id;
end;
$fn$;

-- The case that would have caught it. The suite already created EA and an
-- item, but never a base unit in a second class, so the resolution had only
-- one candidate and could not pick the wrong one.

create or replace function erp_test.master_data_doors_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $suite$

declare
  r record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_uom uuid; v_item uuid; v_party uuid; v_batch uuid;
  v_second uuid; v_tok text; res jsonb;
  v_ok boolean; v_msg text; v_item2 uuid; v_err integer; v_loaded integer; v_prev jsonb;
begin
  select * into r from erp.provision_tenant(
    'zzdoors', 'Doors Suite', 'admin@zzdoors.test', 'Doors Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- A principal with no role at all: a member of the tenant holding nothing.
  -- The cleanest negative control there is, because it needs no role authored
  -- to be restrictive.
  res := public.erp_invite_principal('nobody@zzdoors.test', 'No Permissions');
  v_second := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';

  -- ---------------------------------------------------------------------
  -- The refusal that used to be a constraint violation
  -- ---------------------------------------------------------------------

  begin
    perform erp.create_item('WIDGET', 'Widget');
    v_ok := false; v_msg := 'an item was created with no base unit';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_BASE_UOM%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an item before any unit is refused by name',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- The doors
  -- ---------------------------------------------------------------------

  v_uom := (public.erp_create_uom('ea', 'Each', 'quantity', 0, true) ->> 'uom_id')::uuid;

  return query select 'a unit of measure can be created at all',
    exists (select 1 from erp.uom u
             where u.id = v_uom and u.tenant_id = r.tenant_id
               and u.code = 'EA' and u.is_base and u.status = 'active'),
    'nothing in the product could create one before this migration';

  -- A tenant holding a base unit in more than one class, which
  -- uom_one_base_per_class explicitly permits. CM sorts before EA, so a
  -- resolution that ignores the class stocks a widget in centimetres.
  perform erp.create_uom('CM', 'Centimetre', 'length'::erp.uom_class,
                         2::smallint, true);

  -- erp.create_item directly, not the public wrapper: the wrapper resolves
  -- through erp.ensure_base_uom(), which was corrected separately, so calling
  -- it here would test the half that was already right.
  v_item2 := erp.create_item('WIDGET2', 'Widget the second');

  return query select 'an item is stocked in a quantity, not a length',
    (select u.uom_class from erp.uom u
       join erp.item i on i.stock_uom_id = u.id where i.id = v_item2)
      = 'quantity'::erp.uom_class,
    'CM sorts before EA, so ordering by code across every class picks it';

  v_item := (public.erp_create_item('WIDGET', 'Widget') ->> 'item_id')::uuid;

  return query select 'an item resolves the tenant base unit',
    (select i.stock_uom_id from erp.item i where i.id = v_item) = v_uom,
    'the same resolution erp.load_import does, so both paths agree';

  return query select 'and is created active rather than draft',
    (select i.lifecycle from erp.item i where i.id = v_item) = 'active',
    'the import stages as draft because nobody has looked; a typed record has '
    'been looked at';

  begin
    perform erp.create_item('OTHER', 'Other', gen_random_uuid());
    v_ok := false; v_msg := 'an unknown unit was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_UOM%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a unit from another tenant is refused',
    v_ok, v_msg;

  v_party := (public.erp_create_party_with_roles('ACME', 'Acme Ltd',
                array['customer', 'supplier'], 'GB') ->> 'party_id')::uuid;

  return query select 'a party can be created at all',
    exists (select 1 from erp.party p
             where p.id = v_party and p.tenant_id = r.tenant_id
               and p.status = 'active'),
    'one party across every role, so a receivable can net against a payable';

  return query select 'and holds the roles it was created with',
    (select count(*) from erp.party_role pr
      where pr.party_id = v_party and pr.status = 'active') = 2,
    'a party with no role is a name nobody can trade with';

  begin
    perform erp.create_party('', 'No code');
    v_ok := false; v_msg := 'a party with no code was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PARTY_CODE_REQUIRED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a party with no code is refused',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- The pipeline, end to end, through the public surface only
  -- ---------------------------------------------------------------------

  v_batch := erp.stage_import('party',
    jsonb_build_array(jsonb_build_object('code', 'IMPORTED', 'name', 'Imported Co')),
    'zzdoors-batch');

  -- 20260830014600 renamed this key from 'error_count' to 'errors'. It still
  -- carries the integer erp.validate_import() returns, not a list.
  v_err  := (public.erp_validate_import(v_batch) ->> 'errors')::integer;
  v_prev := public.erp_preview_import(v_batch);
  v_loaded := erp.load_import(v_batch);

  return query select 'validate is reachable from the public surface',
    v_err = 0, format('%s errors', v_err);

  return query select 'preview is reachable, and returns the rows',
    jsonb_array_length(v_prev) = 1, format('%s rows previewed', jsonb_array_length(v_prev));

  return query select 'and load then accepts the batch',
    v_loaded = 1
      and exists (select 1 from erp.party p
                   where p.tenant_id = r.tenant_id and p.code = 'IMPORTED'),
    'load refuses anything not previewed, and only preview sets that status — '
    'so before this migration the pipeline could not complete';

  -- ---------------------------------------------------------------------
  -- The negative controls: the doors are gated
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);

  begin
    perform erp.create_party('SNEAK', 'Sneak Ltd');
    v_ok := false; v_msg := 'a principal with no permissions created a party';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a principal without master_data.write cannot create a party',
    v_ok, v_msg;

  begin
    perform erp.create_item('SNEAK', 'Sneak item');
    v_ok := false; v_msg := 'a principal with no permissions created an item';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor an item',
    v_ok, v_msg;

  begin
    perform erp.create_uom('SNEAK', 'Sneak unit');
    v_ok := false; v_msg := 'a principal with no permissions created a unit';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor a unit of measure',
    v_ok, v_msg;

  begin
    perform erp.validate_import(v_batch);
    v_ok := false; v_msg := 'validate ran for a principal holding nothing';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and validate_import now authorises, which it never did',
    v_ok, v_msg;

  begin
    perform erp.preview_import(v_batch);
    v_ok := false; v_msg := 'preview ran for a principal holding nothing';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'as does preview_import',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'every other suite purges; this one does too';
end;
$suite$;

-- Seventeen cases became eighteen.
create or replace function erp_test.assert_master_data_doors_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 18;
begin
  create temporary table if not exists zz_doors_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_doors_result;
  insert into zz_doors_result select * from erp_test.master_data_doors_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_doors_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_MASTER_DATA_DOORS_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_MASTER_DATA_DOORS_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('master data doors: %s/%s', v_pass, v_total);
end;
$$;

select erp.assert_public_api_safe();
select erp.assert_isolation();
