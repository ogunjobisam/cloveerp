-- ---------------------------------------------------------------------------
-- 1. The platform owner reaches every organisation
-- ---------------------------------------------------------------------------

create or replace function erp_meta.is_platform_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from erp_meta.platform_staff s
     where s.revoked_at is null
       and s.staff_role = 'owner'
       and ( s.auth_user_id = (select auth.uid())
          or lower(s.email) = lower((select u.email from auth.users u
                                      where u.id = (select auth.uid()))) )
  )
$$;

comment on function erp_meta.is_platform_owner is
  'True when the caller is an unrevoked platform owner. The owner operates the '
  'product itself, so every organisation answers to them; every use is logged.';

grant execute on function erp_meta.is_platform_owner() to authenticated, service_role;

create or replace function erp.has_permission(
  p_permission_code text,
  p_entity_id       uuid default null,
  p_site_id         uuid default null,
  p_data_class      text default null,
  p_app_user_id     uuid default null
) returns boolean
language sql
stable
set search_path = ''
as $$
  -- Asking about somebody else is always answered from their grants; the
  -- override is about who is calling, not about who is being described.
  select (p_app_user_id is null and erp_meta.is_platform_owner())
      or exists (
    select 1
      from erp.effective_permission ep
     where ep.app_user_id = coalesce(p_app_user_id, erp.current_principal_id())
       and ep.permission_code = p_permission_code
       and ep.valid_from <= current_date
       and (ep.valid_to is null or ep.valid_to >= current_date)
       and (p_entity_id is null or ep.entity_id is null or ep.entity_id = p_entity_id)
       and (p_site_id   is null or ep.site_id   is null or ep.site_id   = p_site_id)
       and (p_data_class is null
            or cardinality(ep.data_classes) = 0
            or p_data_class = any (ep.data_classes))
  )
$$;

create or replace function erp.authorise(
  p_permission_code text,
  p_entity_id       uuid default null,
  p_site_id         uuid default null,
  p_data_class      text default null,
  p_object_type     text default null,
  p_object_id       uuid default null,
  p_correlation_id  uuid default null
) returns void
language plpgsql
set search_path = ''
as $$
declare
  v_granted boolean;
  v_status  text;
  v_mutates boolean;
begin
  -- The platform owner is the party operating the product. They pass, and the
  -- organisation sees exactly that in its own access log: the override is
  -- recorded under its own reason, never as an ordinary grant.
  if erp_meta.is_platform_owner() then
    perform erp.log_access_decision(
      p_permission_code, true, p_entity_id, p_site_id, p_data_class,
      p_object_type, p_object_id, 'platform owner override', p_correlation_id);
    return;
  end if;

  select t.status::text into v_status
    from erp.tenant t
   where t.id = erp.current_tenant_id();

  if v_status is not null and v_status in ('restricted', 'suspended') then
    select p.is_mutating into v_mutates
      from erp_ref.permission p where p.code = p_permission_code;

    if v_status = 'suspended' or coalesce(v_mutates, true) then
      perform erp.log_access_decision(
        p_permission_code, false, p_entity_id, p_site_id, p_data_class,
        p_object_type, p_object_id,
        format('organisation is %s', v_status), p_correlation_id);

      raise exception
        'CLOVEERP_ORGANISATION_%: this organisation is %, so % is refused',
        upper(v_status), v_status, p_permission_code
        using errcode = '42501',
              detail = case v_status
                         when 'restricted' then
                           'Reads and export remain available. Writes resume on '
                           'resolution, with no data lost in between.'
                         else
                           'Access is withdrawn and the data is intact. '
                           'Restoration is immediate on resolution.'
                       end;
    end if;
  end if;

  v_granted := erp.has_permission(p_permission_code, p_entity_id, p_site_id, p_data_class);
  perform erp.log_access_decision(
    p_permission_code, v_granted, p_entity_id, p_site_id, p_data_class,
    p_object_type, p_object_id,
    case when v_granted then null else 'no matching grant' end,
    p_correlation_id);

  if not v_granted then
    raise exception 'CLOVEERP_PERMISSION_DENIED: %', p_permission_code
      using errcode = '42501';
  end if;
end;
$$;

-- The navigation reads this list. An owner who may do everything should be
-- offered everything, rather than told no by a screen the database would allow.
create or replace function public.erp_session()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'principal_id', erp.current_principal_id(),
    'tenant_id',    erp.current_tenant_id(),
    'principal', (
      select jsonb_build_object(
               'display_name', u.display_name,
               'given_name', u.given_name,
               'family_name', u.family_name,
               'email', u.email,
               'kind', u.kind,
               'user_locale', u.user_locale,
               'document_locale', u.document_locale,
               'reporting_locale', u.reporting_locale,
               'timezone', u.timezone)
        from erp.app_user u where u.id = erp.current_principal_id()),
    'tenant', (
      select jsonb_build_object('code', t.code, 'name', t.name, 'status', t.status)
        from erp.tenant t where t.id = erp.current_tenant_id()),
    'entities', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'code', e.code, 'name', e.name)
                       order by e.code)
        from erp.entity e where e.tenant_id = erp.current_tenant_id()), '[]'::jsonb),
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name,
                                          'entity_id', s.entity_id) order by s.code)
        from erp.site s where s.tenant_id = erp.current_tenant_id()), '[]'::jsonb),
    'permissions', coalesce((
      select jsonb_agg(distinct code) from (
        select ep.permission_code as code
          from erp.effective_permission ep
         where ep.app_user_id = erp.current_principal_id()
           and ep.valid_from <= current_date
           and (ep.valid_to is null or ep.valid_to >= current_date)
        union
        select p.code from erp_ref.permission p
         where erp_meta.is_platform_owner()
      ) s), '[]'::jsonb)
  ))
$$;

-- ---------------------------------------------------------------------------
-- 2. Inviting somebody who is already on file
-- ---------------------------------------------------------------------------

create or replace function erp.invite_principal(
  p_email        text,
  p_display_name text,
  p_valid_for    interval default interval '7 days'
) returns table (app_user_id uuid, token text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_user   uuid;
  v_auth   uuid;
  v_kind   text;
  v_token  text;
begin
  perform erp.authorise('administration.users', null, null, null, 'app_user', null);

  if p_email is null or btrim(p_email) = '' then
    raise exception 'CLOVEERP_VALIDATION: an email address is required';
  end if;

  select u.id, u.auth_user_id, u.kind::text
    into v_user, v_auth, v_kind
    from erp.app_user u
   where u.tenant_id = v_tenant
     and lower(u.email) = lower(btrim(p_email));

  if v_user is not null then
    -- The record stays; the person comes back to it. Their grants, their
    -- history and everything attributed to them keep pointing at one person
    -- rather than at a second copy of them.
    if v_kind <> 'person' then
      raise exception
        'CLOVEERP_VALIDATION: % belongs to a machine account, not a person', p_email;
    end if;

    if v_auth is not null then
      raise exception
        'CLOVEERP_VALIDATION: % already signs in to this organisation, so there '
        'is nothing to invite', p_email
        using hint = 'Remove them first if their access should end.';
    end if;

    update erp.app_user u
       set status       = 'invited',
           display_name = coalesce(nullif(btrim(p_display_name), ''), u.display_name)
     where u.id = v_user;

    -- Any invitation still outstanding is withdrawn: one live token per person.
    update erp.invitation i
       set revoked_at = now(),
           revoked_reason = 'superseded by a new invitation'
     where i.tenant_id = v_tenant
       and i.app_user_id = v_user
       and i.claimed_at is null
       and i.revoked_at is null;
  else
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_tenant, 'person', 'invited', p_display_name, btrim(p_email))
    returning id into v_user;
  end if;

  -- 32 bytes of CSPRNG output. Returned once, below, and never recoverable
  -- from the table afterwards.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
  values (v_tenant, v_user,
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          now() + p_valid_for);

  return query select v_user, v_token;
end;
$$;

create or replace function erp.remove_principal(
  p_app_user_id uuid,
  p_reason      text default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.users', null, null, null, 'app_user',
                        p_app_user_id);

  if p_app_user_id = erp.current_principal_id() then
    raise exception 'CLOVEERP_VALIDATION: you cannot remove yourself';
  end if;

  update erp.app_user u
     set status = 'disabled'
   where u.id = p_app_user_id and u.tenant_id = v_tenant;

  if not found then
    raise exception 'CLOVEERP_VALIDATION: person not found in this organisation';
  end if;

  -- Access ends now, and the record of who held what stays readable.
  update erp.user_role ur
     set valid_to = current_date - 1
   where ur.tenant_id = v_tenant
     and ur.app_user_id = p_app_user_id
     and (ur.valid_to is null or ur.valid_to >= current_date);

  update erp.invitation i
     set revoked_at = now(),
         revoked_reason = coalesce(p_reason, 'the person was removed')
   where i.tenant_id = v_tenant
     and i.app_user_id = p_app_user_id
     and i.claimed_at is null
     and i.revoked_at is null;
end;
$$;

create or replace function public.erp_remove_principal(
  p_app_user_id uuid,
  p_reason      text default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform erp.remove_principal(p_app_user_id, p_reason);
  return jsonb_build_object('removed', p_app_user_id);
end;
$$;

comment on function public.erp_remove_principal is
  'Ends a person''s access without deleting them, so inviting the same address '
  'later returns to the same record.';

-- ---------------------------------------------------------------------------
-- 3. Roles for a job, which combine
-- ---------------------------------------------------------------------------

create or replace function erp.standard_role_permissions(p_code text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct p.code order by p.code), '{}')
    from erp_ref.permission p
   where p.module_code = case p_code
                           when 'purchasing'  then 'procurement'
                           when 'despatch'    then 'logistics'
                           when 'master_data' then 'master_data'
                           else p_code
                         end
      or p.code = any (case p_code
        when 'inventory'   then array['master_data.read','reporting.read']
        when 'purchasing'  then array['master_data.read','inventory.read','reporting.read']
        when 'sales'       then array['master_data.read','inventory.read','reporting.read']
        when 'finance'     then array['master_data.read','reporting.read','reporting.export']
        when 'production'  then array['inventory.read','master_data.read','reporting.read']
        when 'quality'     then array['inventory.read','production.read','reporting.read']
        when 'despatch'    then array['inventory.read','sales.read','reporting.read']
        when 'planning'    then array['inventory.read','procurement.read','production.read','reporting.read']
        when 'reporting'   then array['master_data.read']
        when 'master_data' then array['reporting.read']
        else '{}'::text[]
      end)
$$;

create or replace function erp.ensure_standard_roles(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_made  integer := 0;
  v_role  uuid;
  v_code  text;
  v_name  text;
  v_pair  text[];
begin
  foreach v_pair slice 1 in array array[
    array['inventory',   'Inventory'],
    array['purchasing',  'Purchasing'],
    array['sales',       'Sales'],
    array['finance',     'Finance'],
    array['production',  'Production'],
    array['quality',     'Quality'],
    array['despatch',    'Despatch'],
    array['planning',    'Planning'],
    array['reporting',   'Reporting'],
    array['master_data', 'Master data']
  ] loop
    v_code := v_pair[1];
    v_name := v_pair[2];

    -- A role already on file belongs to the organisation, however it was
    -- shaped. Seeding never rewrites one.
    if exists (select 1 from erp.role r
                where r.tenant_id = p_tenant_id and r.code = v_code) then
      continue;
    end if;

    insert into erp.role (tenant_id, code, name, description, status)
    values (p_tenant_id, v_code, v_name,
            format('What somebody working in %s needs. Combine it with others: '
                   'a person holds every permission of every role they hold.',
                   lower(v_name)),
            'active')
    returning id into v_role;

    insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
    select p_tenant_id, v_role, perm, '{}'
      from unnest(erp.standard_role_permissions(v_code)) perm;

    v_made := v_made + 1;
  end loop;

  return v_made;
end;
$$;

create or replace function erp.seed_standard_roles_on_tenant()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform erp.ensure_standard_roles(new.id);
  return new;
end;
$$;

drop trigger if exists t_tenant_standard_roles on erp.tenant;
create trigger t_tenant_standard_roles
  after insert on erp.tenant
  for each row execute function erp.seed_standard_roles_on_tenant();

do $$
declare
  t record;
begin
  for t in select id from erp.tenant loop
    perform set_config('erp.job_tenant_id', t.id::text, true);
    perform erp.ensure_standard_roles(t.id);
  end loop;
  perform set_config('erp.job_tenant_id', '', true);
end;
$$;

-- One call sets the whole set a person holds, so combining roles is a single
-- honest write rather than a grant here and a revoke there.
create or replace function public.erp_set_user_roles(
  p_app_user_id uuid,
  p_role_codes  text[],
  p_reason      text default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_codes   text[] := coalesce(p_role_codes, '{}');
  v_added   integer := 0;
  v_ended   integer := 0;
  v_code    text;
begin
  perform erp.authorise('administration.roles', null, null, null, 'user_role',
                        p_app_user_id);

  if not exists (select 1 from erp.app_user u
                  where u.id = p_app_user_id and u.tenant_id = v_tenant) then
    raise exception 'CLOVEERP_VALIDATION: person not found in this organisation';
  end if;

  if exists (select 1 from unnest(v_codes) c
              where not exists (select 1 from erp.role r
                                 where r.tenant_id = v_tenant
                                   and r.code = c
                                   and r.status = 'active')) then
    raise exception 'CLOVEERP_UNKNOWN_ROLE: one of those roles does not exist here'
      using errcode = '23503';
  end if;

  -- Unticked: the grant ends today. Organisation-wide grants only; a grant
  -- narrowed to an entity or a site was made deliberately and is left alone.
  with ended as (
    delete from erp.user_role ur
     using erp.role r
     where r.id = ur.role_id
       and ur.tenant_id = v_tenant
       and ur.app_user_id = p_app_user_id
       and ur.entity_id is null
       and ur.site_id is null
       and (ur.valid_to is null or ur.valid_to >= current_date)
       and not (r.code = any (v_codes))
    returning ur.id)
  select count(*) into v_ended from ended;

  foreach v_code in array v_codes loop
    if not exists (
      select 1 from erp.user_role ur join erp.role r on r.id = ur.role_id
       where ur.tenant_id = v_tenant
         and ur.app_user_id = p_app_user_id
         and r.code = v_code
         and ur.entity_id is null and ur.site_id is null
         and ur.valid_from <= current_date
         and (ur.valid_to is null or ur.valid_to >= current_date)
    ) then
      perform erp.grant_role(p_app_user_id, v_code, null, null,
                             coalesce(p_reason, 'set from the roles panel'));
      v_added := v_added + 1;
    end if;
  end loop;

  return jsonb_build_object('granted', v_added, 'revoked', v_ended);
end;
$$;

comment on function public.erp_set_user_roles is
  'Replaces the organisation-wide roles a person holds with exactly the set '
  'given. Roles combine: what they may do is the union of what their roles allow.';

revoke all on function public.erp_remove_principal(uuid, text) from public, anon;
revoke all on function public.erp_set_user_roles(uuid, text[], text) from public, anon;
grant execute on function public.erp_remove_principal(uuid, text) to authenticated, service_role;
grant execute on function public.erp_set_user_roles(uuid, text[], text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_remove_principal', 'erp.remove_principal',
   'Ends a person''s access and closes their open grants. Gated on '
   'administration.users inside erp.remove_principal(); refuses self-removal.'),
  ('erp_set_user_roles', 'erp.grant_role',
   'Sets the whole set of organisation-wide roles a person holds. Gated on '
   'administration.roles, and each grant still passes through erp.grant_role().')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

select erp.assert_public_api_safe();
