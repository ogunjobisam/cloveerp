-- =============================================================================
-- The doors master data never had
--
-- There is no erp.create_party, no erp.create_item and no erp.create_uom
-- anywhere in the sixty-four migrations before this one. The engine models
-- parties, items and units in detail — duplicate detection, merge, change
-- requests, data-quality scoring, field approval — and provides no way to
-- create one.
--
-- The only governed creation path is the import pipeline, and it is severed in
-- the middle. stage_import and load_import have public wrappers; validate and
-- preview do not, and load_import refuses any batch whose status is not
-- 'previewed', which only preview_import sets. So the pipeline is reachable at
-- both ends and broken between them.
--
-- Worse, the first item created by any route would fail. erp.item.stock_uom_id
-- is not null and resolves from the tenant's base unit; erp.uom is populated
-- only inside test fixtures. No installer creates one, and neither onboarding
-- door does. A real tenant's first item dies on a not-null violation naming a
-- column the caller has never heard of.
--
-- Three changes, and the reasoning for keeping them separate:
--
--   1. validate_import and preview_import now authorise. Neither did. Staging
--      and loading both check master_data.import and the two steps between
--      them checked nothing — which mattered little while they were
--      unreachable, and matters the moment they get wrappers.
--
--   2. Public wrappers for those two, completing the pipeline.
--
--   3. Single-record doors. Not instead of the pipeline: "import four thousand
--      suppliers with a review step" and "add this customer" are different
--      operations, and collapsing the second into the first makes the preview
--      — which exists to be a human pause — into theatre.
--
-- Where the two paths agree they share a definition: the doors write exactly
-- the columns load_import's insert branch writes, and anything beyond the
-- mandatory ones goes through erp.write_master_fields, the same function the
-- import uses.
--
-- Where they differ, they differ deliberately. The import stages records as
-- 'draft' because nobody has looked at them yet. A single-record door is the
-- looked-at path — the person typing the name is the review — so it creates
-- active records. A row nobody can see is not a safer row.
--
-- None of erp.uom, erp.party or erp.item carries a live-configuration guard:
-- erp.apply_live_config_guards() covers seventeen configuration tables and
-- these are not among them. That is right. Master data is not behaviour.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Units of measure
--
-- First, because nothing else can exist without one. A unit is not behaviour
-- and not configuration; it is a unit, and a tenant that cannot name one
-- cannot hold an item.
-- -----------------------------------------------------------------------------

create or replace function erp.create_uom(
  p_code      text,
  p_name      text,
  p_uom_class erp.uom_class default 'quantity',
  p_decimals  smallint default 0,
  p_is_base   boolean default false
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'uom', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_UOM_CODE_REQUIRED: a unit of measure needs a code'
      using errcode = '23514';
  end if;

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (v_tenant, upper(trim(p_code)), coalesce(nullif(trim(p_name), ''), upper(trim(p_code))),
          p_uom_class, greatest(p_decimals, 0::smallint), p_is_base, 'active')
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.create_uom(text, text, erp.uom_class, smallint, boolean) is
  'Creates a unit of measure under master_data.write. The first base unit a '
  'tenant creates is what makes erp.create_item possible at all.';

-- -----------------------------------------------------------------------------
-- Parties
--
-- One party across every role, so a receivable can net against a payable. The
-- roles are supplied here rather than added afterwards because a party with no
-- role is a name nobody can trade with, and forgetting the second call is the
-- easiest mistake this API could invite.
-- -----------------------------------------------------------------------------

create or replace function erp.create_party(
  p_code         text,
  p_name         text,
  p_role_kinds   erp.party_role_kind[] default '{}',
  p_country_code char(2) default null,
  p_legal_name   text default null,
  p_values       jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_kind   erp.party_role_kind;
begin
  perform erp.authorise('master_data.write', null, null, null, 'party', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_PARTY_CODE_REQUIRED: a party needs a code'
      using errcode = '23514';
  end if;

  -- The same four columns load_import's insert branch writes, plus the two a
  -- person typing a form would obviously supply.
  insert into erp.party (tenant_id, code, name, legal_name, country_code, status)
  values (v_tenant, trim(p_code), coalesce(nullif(trim(p_name), ''), trim(p_code)),
          nullif(trim(coalesce(p_legal_name, '')), ''), p_country_code, 'active')
  returning id into v_id;

  foreach v_kind in array coalesce(p_role_kinds, '{}'::erp.party_role_kind[])
  loop
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_id, v_kind, 'active')
    on conflict do nothing;
  end loop;

  -- Everything beyond the mandatory columns goes through the same function the
  -- import uses, so there is one definition of what may be written and one
  -- place the field-approval rules apply.
  if p_values <> '{}'::jsonb then
    perform erp.write_master_fields('party', v_id, p_values - 'code');
  end if;

  return v_id;
end;
$$;

comment on function erp.create_party(text, text, erp.party_role_kind[], char, text, jsonb) is
  'Creates a party and its roles under master_data.write. Writes the columns '
  'erp.load_import writes and delegates the rest to erp.write_master_fields, '
  'so the single-record door and the import agree on what a party is.';

-- -----------------------------------------------------------------------------
-- Items
--
-- The one that needed a named refusal. stock_uom_id is not null and is
-- resolved from the tenant's base unit; a tenant with no unit would otherwise
-- get a constraint violation naming a column nobody asked them about.
-- -----------------------------------------------------------------------------

create or replace function erp.create_item(
  p_code         text,
  p_name         text,
  p_stock_uom_id uuid default null,
  p_item_class   text default null,
  p_values       jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
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
     where u.tenant_id = v_tenant and u.is_base and u.status = 'active'
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
$$;

comment on function erp.create_item(text, text, uuid, text, jsonb) is
  'Creates an item under master_data.write, resolving the tenant''s base unit '
  'when none is named and refusing by name rather than by constraint when '
  'there is none.';

-- =============================================================================
-- The two pipeline steps that never authorised
--
-- Re-emitted verbatim with erp.authorise added. Both bodies are otherwise
-- unchanged from 20260829230000_master_data.sql.
-- =============================================================================

create or replace function erp.validate_import(p_batch_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_table  text;
  r        record;
  v_find   jsonb;
  v_target uuid;
  v_bad    text;
  v_errors integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- The gate this pipeline never had. Staging and loading both authorise
  -- master_data.import; validating and previewing did not, which left two
  -- of the four steps open to any principal who could reach the wrapper.
  perform erp.authorise('master_data.import', null, null, null,
                        'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = b.object_type;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
            order by row_no
  loop
    v_find := '[]'::jsonb;
    v_target := null;

    -- Every row must name the record it is about.
    if coalesce(r.raw ->> 'code', '') = '' then
      v_find := v_find || jsonb_build_object(
        'severity','error','message','no code, so this row names no record');
    else
      execute format('select t.id from erp.%I t where t.tenant_id = $1 and t.code = $2',
                     v_table)
        into v_target using v_tenant, r.raw ->> 'code';
    end if;

    -- Every other key must be a field this product agreed may be written.
    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k <> 'code'
       and not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = b.object_type and m.column_name = k);

    if v_bad is not null then
      v_find := v_find || jsonb_build_object(
        'severity','error','message', format('unknown or protected field(s): %s', v_bad));
    end if;

    update erp.import_row
       set findings = v_find,
           target_id = v_target,
           action = case
                      when jsonb_array_length(v_find) > 0 then 'reject'
                      when v_target is not null then 'update'
                      else 'insert' end,
           updated_at = now()
     where id = r.id;

    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch
     set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;

  return v_errors;
end;
$$;

create or replace function erp.preview_import(p_batch_id uuid)
returns table (row_no integer, action text, code text, target_id uuid,
               changes jsonb, findings jsonb)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- The gate this pipeline never had. Staging and loading both authorise
  -- master_data.import; validating and previewing did not, which left two
  -- of the four steps open to any principal who could reach the wrapper.
  perform erp.authorise('master_data.import', null, null, null,
                        'import_batch', p_batch_id);

  if b.status = 'received' then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATED: validate % before previewing it', b.code
      using errcode = '23514';
  end if;

  update erp.import_batch set status = 'previewed', updated_at = now()
   where id = p_batch_id and status = 'validated';

  return query
    select r.row_no, r.action, r.raw ->> 'code', r.target_id,
           case when r.target_id is null then r.raw
                else (select jsonb_object_agg(k.key, jsonb_build_object(
                               'from', erp.master_record(b.object_type, r.target_id) -> k.key,
                               'to',   k.value))
                        from jsonb_each(r.raw - 'code') k
                       where erp.master_record(b.object_type, r.target_id) -> k.key
                             is distinct from k.value)
           end,
           r.findings
      from erp.import_row r
     where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id
     order by r.row_no;
end;
$$;

-- =============================================================================
-- The public surface
-- =============================================================================

create or replace function public.erp_create_uom(
  p_code text, p_name text, p_uom_class text default 'quantity',
  p_decimals integer default 0, p_is_base boolean default false
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('uom_id',
  erp.create_uom(p_code, p_name, p_uom_class::erp.uom_class,
                 p_decimals::smallint, p_is_base)) $$;

create or replace function public.erp_create_party(
  p_code text, p_name text, p_role_kinds text[] default '{}',
  p_country_code text default null, p_legal_name text default null
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('party_id',
  erp.create_party(p_code, p_name, p_role_kinds::erp.party_role_kind[],
                   p_country_code::char(2), p_legal_name)) $$;

create or replace function public.erp_create_item(
  p_code text, p_name text, p_stock_uom_id uuid default null,
  p_item_class text default null
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('item_id',
  erp.create_item(p_code, p_name, p_stock_uom_id, p_item_class)) $$;

create or replace function public.erp_validate_import(p_batch_id uuid)
returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('error_count', erp.validate_import(p_batch_id)) $$;

-- preview_import is volatile because it is the step that sets status to
-- 'previewed'. That is the whole point of it: erp.load_import refuses a batch
-- nobody has previewed, so this call is the recorded human pause.
create or replace function public.erp_preview_import(p_batch_id uuid)
returns jsonb
language sql volatile security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'row_no', p.row_no, 'action', p.action, 'code', p.code,
           'target_id', p.target_id, 'changes', p.changes, 'findings', p.findings)
           order by p.row_no), '[]'::jsonb)
    from erp.preview_import(p_batch_id) p
$$;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.erp_create_uom(text, text, text, integer, boolean)',
    'public.erp_create_party(text, text, text[], text, text)',
    'public.erp_create_item(text, text, uuid, text)',
    'public.erp_validate_import(uuid)',
    'public.erp_preview_import(uuid)'
  ]
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_create_uom', 'erp.create_uom',
   'Creates a unit of measure under master_data.write. Nothing else in the '
   'product could create one, and erp.item.stock_uom_id is not null, so '
   'without this a tenant can hold no items at all.'),
  ('erp_create_party', 'erp.create_party',
   'Creates a party and its roles under master_data.write, writing the same '
   'columns the import pipeline writes and delegating the rest to '
   'erp.write_master_fields so both paths agree.'),
  ('erp_create_item', 'erp.create_item',
   'Creates an item under master_data.write, resolving the tenant base unit '
   'and refusing by name when there is none rather than by constraint.'),
  ('erp_validate_import', 'erp.validate_import',
   'Validates a staged import under master_data.import. The step was '
   'unreachable and ungated; it is now both reachable and gated.'),
  ('erp_preview_import', 'erp.preview_import',
   'Previews a validated import and marks it previewed under '
   'master_data.import. erp.load_import refuses a batch nobody has previewed, '
   'so this is the pause the pipeline is built around.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- =============================================================================
-- The suite
--
-- The cases that matter are the refusals. A door that creates a record is easy
-- to get right; a door that creates one for somebody who may not is the reason
-- the allow-list exists.
-- =============================================================================

create or replace function erp_test.master_data_doors_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_uom uuid; v_item uuid; v_party uuid; v_batch uuid;
  v_second uuid; v_tok text; res jsonb;
  v_ok boolean; v_msg text; v_err integer; v_loaded integer; v_prev jsonb;
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

  v_party := (public.erp_create_party('ACME', 'Acme Ltd',
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

  v_err  := (public.erp_validate_import(v_batch) ->> 'error_count')::integer;
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
$$;

create or replace function erp_test.assert_master_data_doors_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Seventeen: eight on the doors, three on the completed pipeline, five
  -- refusals, and the purge.
  c_expected constant integer := 17;
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

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_isolation();
