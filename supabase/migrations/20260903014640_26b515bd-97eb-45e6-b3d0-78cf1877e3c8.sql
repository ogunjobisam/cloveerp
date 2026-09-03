create or replace function erp.create_site(
  p_code text,
  p_name text,
  p_site_type text default 'warehouse',
  p_entity_id uuid default null,
  p_country_code char(2) default null,
  p_timezone text default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid := p_entity_id;
  v_id     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'site', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_SITE_CODE_REQUIRED: a site needs a code'
      using errcode = '23514';
  end if;

  if v_entity is null then
    select e.id into v_entity
      from erp.entity e
     where e.tenant_id = v_tenant
     order by e.created_at
     limit 1;
  end if;

  if v_entity is null then
    raise exception 'ERPWARE_ENTITY_REQUIRED: this organisation has no legal entity to hold a site'
      using errcode = '23514';
  end if;

  insert into erp.site (tenant_id, entity_id, code, name, site_type,
                        country_code, timezone, status)
  values (v_tenant, v_entity, trim(p_code),
          coalesce(nullif(trim(p_name), ''), trim(p_code)),
          p_site_type::erp.site_type, p_country_code,
          coalesce(nullif(trim(coalesce(p_timezone, '')), ''), 'UTC'), 'active')
  returning id into v_id;

  return v_id;
end $$;

comment on function erp.create_site(text, text, text, uuid, char, text) is
  'Creates a site under administration.configure, defaulting the legal entity '
  'to the organisation''s first. The single-record door that makes a newly '
  'provisioned organisation able to raise a document that needs a site.';

create or replace function public.erp_create_site(
  p_code text, p_name text, p_site_type text default 'warehouse',
  p_entity_id uuid default null, p_country_code text default null,
  p_timezone text default null
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('site_id',
  erp.create_site(p_code, p_name, p_site_type, p_entity_id,
                  p_country_code::char(2), p_timezone)) $$;

-- EDITED AFTER IT WAS APPLIED. See supabase/ci/migrations_edited.txt; the
-- repair that carries this to environments which already ran the original is
-- 20260904800000_reapply_the_doors_that_arrived_ungoverned.sql.
--
-- As written from the dashboard, this replaced a plpgsql, VOLATILE body that
-- began `perform erp.authorise('finance.read')` — a permission check and an
-- access-log row — and returned active entities only. The replacement was a
-- STABLE sql body with no gate at all, so listing an organisation's legal
-- entities stopped requiring a permission and stopped being recorded, while
-- its row in erp_meta.public_write_allowance went on declaring erp.authorise
-- as its gate. A register that describes something else is worse than no
-- register, so the gate is restored here exactly as it was.
create or replace function public.erp_entities()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'entity_id', e.id, 'code', e.code, 'name', e.name,
      'base_currency', e.base_currency, 'country_code', e.country_code) as x
      from erp.entity e
     where e.tenant_id = erp.current_tenant_id() and e.status = 'active'
  ) s;
  return v_out;
end;
$$;

comment on function public.erp_entities() is
  'The organisation''s active legal entities. Gated on finance.read and '
  'recorded, because which entities exist is part of how an organisation is '
  'structured; it briefly lost both and the register went on claiming '
  'otherwise.';

create or replace function public.erp_sites()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'site_id', s.id, 'code', s.code, 'name', s.name,
           'site_type', s.site_type, 'entity_id', s.entity_id,
           'entity_code', (select e.code from erp.entity e
                            where e.tenant_id = s.tenant_id and e.id = s.entity_id),
           'country_code', s.country_code, 'status', s.status)
           order by s.code), '[]'::jsonb)
    from erp.site s
$$;

revoke all on function public.erp_create_site(text, text, text, uuid, text, text) from public, anon;
revoke all on function public.erp_entities() from public, anon;
revoke all on function public.erp_sites() from public, anon;
grant execute on function public.erp_create_site(text, text, text, uuid, text, text) to authenticated;
grant execute on function public.erp_entities() to authenticated;
grant execute on function public.erp_sites() to authenticated;

do $$
declare v_ok boolean;
begin
  select count(*) = 3 into v_ok from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('erp_create_site', 'erp_entities', 'erp_sites');
  if not v_ok then raise exception 'wrappers missing'; end if;
end $$;

-- EDITED AFTER IT WAS APPLIED, as above.
--
-- erp_create_site writes and was not on the allow-list. It is a thin wrapper,
-- so it declares the erp.* function it delegates to rather than erp.authorise:
-- the register checks that a door's declared gate appears in that door's own
-- body, and erp_receive_against is registered the same way for the same
-- reason.
insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_site', 'erp.create_site',
   'Creates a site and the standard bays that go with it, under '
   'administration.configure. A new organisation cannot raise a purchase '
   'order, a receipt or a despatch until it has one, so this is the door that '
   'makes an empty organisation usable.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- §16.2: the door and the proof that it is governed, in the same transaction.
select erp.assert_public_api_safe();