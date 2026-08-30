-- =============================================================================
-- Addendum B, phase 1: departments, approval routing, dimension integration
--
-- The department is one object. It is the organisational unit that routes an
-- approval AND the analytical dimension a posting carries. Defining them
-- separately is how reporting ends up disagreeing with operations, so
-- erp.department provisions its own erp.dimension_value on the tenant's
-- DEPARTMENT dimension and keeps the two in step.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Departments
-- -----------------------------------------------------------------------------

create table erp.department (
  id                       uuid not null default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant(id) on delete cascade,
  entity_id                uuid,
  code                     text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
  name                     text not null,
  name_key                 text,
  manager_user_id          uuid,
  parent_department_id     uuid,
  default_cost_centre      text,
  default_dimensions       jsonb not null default '{}'::jsonb,
  dimension_value_id       uuid,
  valid_from               date not null default current_date,
  valid_to                 date,
  status                   erp.record_status not null default 'active',
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  primary key (id),
  unique (tenant_id, code),
  check (valid_to is null or valid_to > valid_from)
);

create index on erp.department (tenant_id, status);
create index on erp.department (tenant_id, parent_department_id);

comment on table erp.department is
  'Addendum B 1: organisational unit within an entity. The same row is the '
  'finance dimension value of Addendum B 3 - one object, not two.';

-- -----------------------------------------------------------------------------
-- Membership, effective-dated, one primary
-- -----------------------------------------------------------------------------

create table erp.principal_department (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  app_user_id    uuid not null,
  department_id  uuid not null,
  is_primary     boolean not null default true,
  valid_from     date not null default current_date,
  valid_to       date,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  check (valid_to is null or valid_to > valid_from)
);

create index on erp.principal_department (tenant_id, app_user_id, is_primary);
create index on erp.principal_department (tenant_id, department_id);

-- At most one primary membership in force at a time, per person.
create unique index principal_department_one_primary
  on erp.principal_department (tenant_id, app_user_id, valid_from)
  where is_primary and status = 'active';

-- -----------------------------------------------------------------------------
-- Value bands per department and object type
--
-- resolution is an ordered array of resolver objects, tried in order:
--   {"kind":"user","user_id":"..."}
--   {"kind":"role_in_department","role_code":"..."}
--   {"kind":"role","role_code":"...","scope":"entity"|"site"}
--   {"kind":"line_manager"}
-- -----------------------------------------------------------------------------

create type erp.vacancy_behaviour as enum ('hold_and_raise', 'escalate_to_manager');

create table erp.approval_band (
  id                 uuid not null default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  department_id      uuid not null,
  object_type        text not null,
  seq                integer not null default 1,
  lower_bound_minor  bigint not null default 0,
  upper_bound_minor  bigint,
  currency           char(3) not null default 'GBP',
  resolution         jsonb not null default '[]'::jsonb,
  is_parallel        boolean not null default false,
  rerun_lower_bands  boolean not null default true,
  escalate_after     interval,
  vacancy            erp.vacancy_behaviour not null default 'hold_and_raise',
  tolerance_pct      numeric(9,4),
  tolerance_absolute numeric(20,4),
  version            integer not null default 1,
  valid_from         date not null default current_date,
  valid_to           date,
  status             erp.record_status not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  primary key (id),
  unique (tenant_id, department_id, object_type, seq, valid_from),
  check (upper_bound_minor is null or upper_bound_minor > lower_bound_minor),
  check (jsonb_typeof(resolution) = 'array')
);

create index on erp.approval_band (tenant_id, object_type, department_id);

-- -----------------------------------------------------------------------------
-- Named approver assignment
-- -----------------------------------------------------------------------------

create type erp.approver_subject_kind as enum ('principal', 'role', 'department');
create type erp.approver_assignment_mode as enum ('replaces', 'prepends');

create table erp.approver_assignment (
  id                 uuid not null default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  subject_kind       erp.approver_subject_kind not null,
  subject_id         uuid not null,
  object_type        text not null,
  approver_user_id   uuid not null,
  mode               erp.approver_assignment_mode not null default 'prepends',
  lower_bound_minor  bigint,
  upper_bound_minor  bigint,
  reason             text,
  version            integer not null default 1,
  valid_from         date not null default current_date,
  valid_to           date,
  status             erp.record_status not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  primary key (id),
  check (upper_bound_minor is null or lower_bound_minor is null
         or upper_bound_minor > lower_bound_minor)
);

create index on erp.approver_assignment (tenant_id, object_type, subject_kind, subject_id);

-- -----------------------------------------------------------------------------
-- Routing stamp: the department the request was raised under, and the chain
-- that department produced. Append-only evidence.
-- -----------------------------------------------------------------------------

create table erp.approval_routing_stamp (
  id             bigint generated always as identity primary key,
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  object_type    text not null,
  object_id      uuid not null,
  department_id  uuid,
  value_minor    bigint,
  currency       char(3),
  resolved_chain jsonb not null,
  resolved_at    timestamptz not null default now(),
  resolved_by    uuid
);

create index on erp.approval_routing_stamp (tenant_id, object_type, object_id, resolved_at desc);

select erp_meta.register_table('erp', 'department', 'tenant_scoped');
select erp_meta.register_table('erp', 'principal_department', 'tenant_scoped');
select erp_meta.register_table('erp', 'approval_band', 'tenant_scoped');
select erp_meta.register_table('erp', 'approver_assignment', 'tenant_scoped');
select erp_meta.register_table('erp', 'approval_routing_stamp', 'tenant_scoped_append_only',
  'Addendum B 1: the routing decision as taken, evidence for every approval.');

do $$
declare t text;
begin
  foreach t in array array['department','principal_department','approval_band','approver_assignment'] loop
    execute format(
      'create trigger t_%1$s_attribution before insert or update on erp.%1$I
         for each row execute function erp.touch_attribution()', t);
    execute format(
      'create trigger t_%1$s_freeze before update on erp.%1$I
         for each row execute function erp.freeze_tenant_id()', t);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Event catalogue
-- -----------------------------------------------------------------------------

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, is_current)
values
  ('approval.chain_resolved', 1, 'approval', 'administration', 'event.approval.chain_resolved',
   'A routing decision was taken and stamped on the object.', true),
  ('approval.escalated', 1, 'approval', 'administration', 'event.approval.escalated',
   'A band aged out or self-approval was refused, so authority moved up.', true),
  ('approval.reapproval_triggered', 1, 'approval', 'administration', 'event.approval.reapproval_triggered',
   'A material change outside tolerance restarted approval.', true)
on conflict (code, version) do nothing;

-- -----------------------------------------------------------------------------
-- The department IS the dimension
-- -----------------------------------------------------------------------------

create or replace function erp.ensure_department_dimension()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  select d.id into v_id
    from erp.dimension d
   where d.tenant_id = v_tenant and d.code = 'DEPARTMENT';

  if v_id is null then
    insert into erp.dimension (tenant_id, code, name, derivation, is_mandatory_default)
    values (v_tenant, 'DEPARTMENT', 'Department',
            jsonb_build_object('from', 'requester_primary_department'), false)
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

comment on function erp.ensure_department_dimension() is
  'Addendum B 3: one department object. Approval routing and the finance '
  'dimension read the same rows.';

create or replace function erp.sync_department_dimension()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_dim uuid := erp.ensure_department_dimension();
  v_value uuid := new.dimension_value_id;
begin
  if v_value is null then
    select dv.id into v_value
      from erp.dimension_value dv
     where dv.tenant_id = new.tenant_id and dv.dimension_id = v_dim and dv.code = new.code;
  end if;

  if v_value is null then
    insert into erp.dimension_value (
      tenant_id, dimension_id, code, name, valid_from, valid_to, status)
    values (new.tenant_id, v_dim, new.code, new.name, new.valid_from, new.valid_to, new.status)
    returning id into v_value;
  else
    update erp.dimension_value
       set name = new.name, valid_from = new.valid_from,
           valid_to = new.valid_to, status = new.status
     where tenant_id = new.tenant_id and id = v_value;
  end if;

  new.dimension_value_id := v_value;
  return new;
end;
$$;

create trigger t_department_dimension
  before insert or update on erp.department
  for each row execute function erp.sync_department_dimension();

-- -----------------------------------------------------------------------------
-- Resolution
-- -----------------------------------------------------------------------------

create or replace function erp.resolve_band_approver(
  p_resolver     jsonb,
  p_department   uuid,
  p_requester    uuid,
  p_entity_id    uuid,
  p_site_id      uuid
) returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_kind   text := p_resolver->>'kind';
  v_user   uuid;
begin
  if v_kind = 'user' then
    v_user := nullif(p_resolver->>'user_id','')::uuid;

  elsif v_kind = 'line_manager' then
    select d.manager_user_id into v_user
      from erp.department d
     where d.tenant_id = v_tenant and d.id = p_department;

  elsif v_kind in ('role_in_department', 'role') then
    select ur.app_user_id into v_user
      from erp.user_role ur
      join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
      left join erp.principal_department pd
        on pd.tenant_id = ur.tenant_id
       and pd.app_user_id = ur.app_user_id
       and pd.department_id = p_department
       and pd.status = 'active'
       and daterange(pd.valid_from, pd.valid_to, '[)') @> current_date
     where ur.tenant_id = v_tenant
       and r.code = (p_resolver->>'role_code')
       and (v_kind <> 'role_in_department' or pd.id is not null)
       and (ur.valid_from is null or ur.valid_from <= current_date)
       and (ur.valid_to is null or ur.valid_to > current_date)
     order by (pd.id is not null) desc
     limit 1;
  end if;

  return v_user;
end;
$$;

create or replace function erp.resolve_approval_chain(
  p_object_type   text,
  p_value_minor   bigint,
  p_currency      char(3) default 'GBP',
  p_department_id uuid default null,
  p_requester     uuid default null,
  p_entity_id     uuid default null,
  p_site_id       uuid default null,
  p_on            date default null
) returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_on        date := coalesce(p_on, current_date);
  v_requester uuid := coalesce(p_requester, erp.current_principal_id());
  v_dept      uuid := p_department_id;
  v_steps     jsonb := '[]'::jsonb;
  v_named     jsonb := '[]'::jsonb;
  v_replaces  boolean := false;
  r           record;
  v_res       jsonb;
  v_user      uuid;
  v_seq       integer := 0;
begin
  -- The department at capture, not at approval time.
  if v_dept is null then
    select pd.department_id into v_dept
      from erp.principal_department pd
     where pd.tenant_id = v_tenant
       and pd.app_user_id = v_requester
       and pd.is_primary
       and pd.status = 'active'
       and daterange(pd.valid_from, pd.valid_to, '[)') @> v_on
     limit 1;
  end if;

  -- 1. Named assignment, on the principal or on the department.
  for r in
    select aa.*
      from erp.approver_assignment aa
     where aa.tenant_id = v_tenant
       and aa.object_type = p_object_type
       and aa.status = 'active'
       and daterange(aa.valid_from, aa.valid_to, '[)') @> v_on
       and (aa.lower_bound_minor is null or p_value_minor >= aa.lower_bound_minor)
       and (aa.upper_bound_minor is null or p_value_minor < aa.upper_bound_minor)
       and ((aa.subject_kind = 'principal'  and aa.subject_id = v_requester)
         or (aa.subject_kind = 'department' and aa.subject_id = v_dept)
         or (aa.subject_kind = 'role' and exists (
               select 1 from erp.user_role ur
                where ur.tenant_id = v_tenant
                  and ur.app_user_id = v_requester
                  and ur.role_id = aa.subject_id)))
     order by aa.subject_kind, aa.valid_from
  loop
    v_seq := v_seq + 1;
    if r.mode = 'replaces' then v_replaces := true; end if;
    v_named := v_named || jsonb_build_object(
      'seq', v_seq, 'approver_user_id', r.approver_user_id,
      'source', 'named_assignment', 'rule_id', r.id, 'rule_version', r.version,
      'mode', r.mode, 'reason', r.reason);
  end loop;

  -- 2. Department bands.
  if not v_replaces and v_dept is not null then
    for r in
      select ab.*
        from erp.approval_band ab
       where ab.tenant_id = v_tenant
         and ab.department_id = v_dept
         and ab.object_type = p_object_type
         and ab.status = 'active'
         and daterange(ab.valid_from, ab.valid_to, '[)') @> v_on
         and ab.lower_bound_minor <= p_value_minor
       order by ab.seq
    loop
      -- A higher band applies; lower bands re-run only where configured.
      if r.upper_bound_minor is not null
         and p_value_minor >= r.upper_bound_minor
         and not r.rerun_lower_bands then
        continue;
      end if;

      v_user := null;
      for v_res in select jsonb_array_elements(r.resolution) loop
        v_user := erp.resolve_band_approver(v_res, v_dept, v_requester, p_entity_id, p_site_id);
        exit when v_user is not null;
      end loop;

      if v_user is null then
        if r.vacancy = 'hold_and_raise' then
          raise exception
            'ERPWARE_APPROVER_VACANCY: band % for % resolves to nobody', r.seq, p_object_type
            using errcode = '23503';
        else
          select d.manager_user_id into v_user
            from erp.department d where d.tenant_id = v_tenant and d.id = v_dept;
        end if;
      end if;

      -- Self-approval is refused: escalate to the department manager, and
      -- where that is the requester too, to the parent department's manager.
      if v_user = v_requester then
        select coalesce(p.manager_user_id, d.manager_user_id) into v_user
          from erp.department d
          left join erp.department p
            on p.tenant_id = d.tenant_id and p.id = d.parent_department_id
         where d.tenant_id = v_tenant and d.id = v_dept;
        if v_user is null or v_user = v_requester then
          raise exception
            'ERPWARE_SELF_APPROVAL: no authority above the requester for %', p_object_type
            using errcode = '23503';
        end if;
      end if;

      v_seq := v_seq + 1;
      v_steps := v_steps || jsonb_build_object(
        'seq', v_seq, 'approver_user_id', v_user,
        'source', 'department_band', 'rule_id', r.id, 'rule_version', r.version,
        'band_seq', r.seq, 'parallel', r.is_parallel,
        'escalate_after', r.escalate_after,
        'lower_bound_minor', r.lower_bound_minor,
        'upper_bound_minor', r.upper_bound_minor);
    end loop;
  end if;

  return jsonb_build_object(
    'object_type', p_object_type,
    'department_id', v_dept,
    'value_minor', p_value_minor,
    'currency', p_currency,
    'requester', v_requester,
    'resolved_on', v_on,
    'steps', v_named || v_steps,
    'exhausted', jsonb_array_length(v_named || v_steps) = 0);
end;
$$;

comment on function erp.resolve_approval_chain(text,bigint,char,uuid,uuid,uuid,uuid,date) is
  'Addendum B 1: named assignment, then department band, then nothing. Every '
  'step names the rule and version that chose it. Self-approval escalates; a '
  'vacant band holds the request rather than routing silently upward.';

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_departments()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'department_id', d.id, 'code', d.code, 'name', d.name,
      'entity_id', d.entity_id, 'manager_user_id', d.manager_user_id,
      'manager', mu.display_name,
      'parent_department_id', d.parent_department_id,
      'parent_code', p.code,
      'default_cost_centre', d.default_cost_centre,
      'dimension_value_id', d.dimension_value_id,
      'valid_from', d.valid_from, 'valid_to', d.valid_to,
      'status', d.status,
      'member_count', (select count(*) from erp.principal_department pd
                        where pd.tenant_id = d.tenant_id
                          and pd.department_id = d.id
                          and pd.status = 'active'),
      'band_count', (select count(*) from erp.approval_band ab
                      where ab.tenant_id = d.tenant_id
                        and ab.department_id = d.id
                        and ab.status = 'active')) as x
      from erp.department d
      left join erp.department p on p.tenant_id = d.tenant_id and p.id = d.parent_department_id
      left join erp.app_user mu on mu.tenant_id = d.tenant_id and mu.id = d.manager_user_id
     where d.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_upsert_department(
  p_code                 text,
  p_name                 text,
  p_manager_user_id      uuid default null,
  p_parent_department_id uuid default null,
  p_default_cost_centre  text default null,
  p_entity_id            uuid default null,
  p_valid_from           date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  perform erp.authorise('administration.configure');

  insert into erp.department (
    tenant_id, code, name, manager_user_id, parent_department_id,
    default_cost_centre, entity_id, valid_from)
  values (
    v_tenant, upper(p_code), p_name, p_manager_user_id, p_parent_department_id,
    p_default_cost_centre, p_entity_id, coalesce(p_valid_from, current_date))
  on conflict (tenant_id, code) do update
    set name = excluded.name,
        manager_user_id = excluded.manager_user_id,
        parent_department_id = excluded.parent_department_id,
        default_cost_centre = excluded.default_cost_centre,
        entity_id = excluded.entity_id
  returning id into v_id;

  return jsonb_build_object('department_id', v_id, 'code', upper(p_code));
end;
$$;

create or replace function public.erp_department_members(p_department_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(x order by x->>'department_code', x->>'display_name'), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'membership_id', pd.id, 'app_user_id', pd.app_user_id,
      'display_name', u.display_name, 'email', u.email,
      'department_id', pd.department_id, 'department_code', d.code,
      'is_primary', pd.is_primary,
      'valid_from', pd.valid_from, 'valid_to', pd.valid_to,
      'status', pd.status) as x
      from erp.principal_department pd
      join erp.department d on d.tenant_id = pd.tenant_id and d.id = pd.department_id
      left join erp.app_user u on u.tenant_id = pd.tenant_id and u.id = pd.app_user_id
     where pd.tenant_id = erp.current_tenant_id()
       and (p_department_id is null or pd.department_id = p_department_id)
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_assign_department(
  p_app_user_id   uuid,
  p_department_id uuid,
  p_is_primary    boolean default true,
  p_valid_from    date default null,
  p_valid_to      date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from date := coalesce(p_valid_from, current_date);
  v_id uuid;
begin
  perform erp.authorise('administration.configure');

  -- One primary in force: close the standing one rather than duplicating it.
  if p_is_primary then
    update erp.principal_department
       set valid_to = v_from, status = 'inactive'
     where tenant_id = v_tenant
       and app_user_id = p_app_user_id
       and is_primary
       and status = 'active'
       and (valid_to is null or valid_to > v_from);
  end if;

  insert into erp.principal_department (
    tenant_id, app_user_id, department_id, is_primary, valid_from, valid_to)
  values (v_tenant, p_app_user_id, p_department_id, p_is_primary, v_from, p_valid_to)
  returning id into v_id;

  return jsonb_build_object('membership_id', v_id);
end;
$$;

create or replace function public.erp_end_department_membership(
  p_membership_id uuid,
  p_valid_to      date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure');
  update erp.principal_department
     set valid_to = coalesce(p_valid_to, current_date), status = 'inactive'
   where tenant_id = v_tenant and id = p_membership_id;
  return jsonb_build_object('membership_id', p_membership_id, 'ended', true);
end;
$$;

create or replace function public.erp_approval_bands(
  p_department_id uuid default null,
  p_object_type   text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(x order by x->>'department_code', x->>'object_type',
                            (x->>'seq')::int), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'band_id', ab.id, 'department_id', ab.department_id, 'department_code', d.code,
      'object_type', ab.object_type, 'seq', ab.seq,
      'lower_bound_minor', ab.lower_bound_minor, 'upper_bound_minor', ab.upper_bound_minor,
      'currency', ab.currency, 'resolution', ab.resolution,
      'is_parallel', ab.is_parallel, 'rerun_lower_bands', ab.rerun_lower_bands,
      'escalate_after', ab.escalate_after, 'vacancy', ab.vacancy,
      'tolerance_pct', ab.tolerance_pct, 'tolerance_absolute', ab.tolerance_absolute,
      'version', ab.version, 'valid_from', ab.valid_from, 'valid_to', ab.valid_to,
      'status', ab.status) as x
      from erp.approval_band ab
      join erp.department d on d.tenant_id = ab.tenant_id and d.id = ab.department_id
     where ab.tenant_id = erp.current_tenant_id()
       and (p_department_id is null or ab.department_id = p_department_id)
       and (p_object_type is null or ab.object_type = p_object_type)
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_upsert_approval_band(
  p_department_id     uuid,
  p_object_type       text,
  p_seq               integer,
  p_upper_bound_minor bigint default null,
  p_lower_bound_minor bigint default 0,
  p_approver_user_id  uuid default null,
  p_approver_role_code text default null,
  p_use_line_manager  boolean default false,
  p_currency          text default 'GBP',
  p_is_parallel       boolean default false,
  p_rerun_lower_bands boolean default true,
  p_escalate_after_hours integer default null,
  p_vacancy           text default 'hold_and_raise',
  p_tolerance_pct     numeric default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_resolution jsonb := '[]'::jsonb;
  v_id uuid;
begin
  perform erp.authorise('administration.configure');

  if p_approver_user_id is not null then
    v_resolution := v_resolution || jsonb_build_array(
      jsonb_build_object('kind','user','user_id', p_approver_user_id));
  end if;
  if p_approver_role_code is not null then
    v_resolution := v_resolution || jsonb_build_array(
      jsonb_build_object('kind','role_in_department','role_code', p_approver_role_code));
    v_resolution := v_resolution || jsonb_build_array(
      jsonb_build_object('kind','role','role_code', p_approver_role_code,'scope','entity'));
  end if;
  if p_use_line_manager then
    v_resolution := v_resolution || jsonb_build_array(jsonb_build_object('kind','line_manager'));
  end if;

  if jsonb_array_length(v_resolution) = 0 then
    raise exception 'ERPWARE_BAND_UNRESOLVABLE: a band must name at least one way to find an approver'
      using errcode = '23514';
  end if;

  insert into erp.approval_band (
    tenant_id, department_id, object_type, seq, lower_bound_minor, upper_bound_minor,
    currency, resolution, is_parallel, rerun_lower_bands,
    escalate_after, vacancy, tolerance_pct)
  values (
    v_tenant, p_department_id, p_object_type, p_seq,
    coalesce(p_lower_bound_minor, 0), p_upper_bound_minor,
    upper(coalesce(p_currency,'GBP'))::char(3), v_resolution, p_is_parallel, p_rerun_lower_bands,
    case when p_escalate_after_hours is null then null
         else make_interval(hours => p_escalate_after_hours) end,
    p_vacancy::erp.vacancy_behaviour, p_tolerance_pct)
  on conflict (tenant_id, department_id, object_type, seq, valid_from) do update
    set lower_bound_minor = excluded.lower_bound_minor,
        upper_bound_minor = excluded.upper_bound_minor,
        currency = excluded.currency,
        resolution = excluded.resolution,
        is_parallel = excluded.is_parallel,
        rerun_lower_bands = excluded.rerun_lower_bands,
        escalate_after = excluded.escalate_after,
        vacancy = excluded.vacancy,
        tolerance_pct = excluded.tolerance_pct,
        version = erp.approval_band.version + 1
  returning id into v_id;

  return jsonb_build_object('band_id', v_id);
end;
$$;

create or replace function public.erp_retire_approval_band(p_band_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure');
  update erp.approval_band
     set status = 'inactive', valid_to = current_date
   where tenant_id = v_tenant and id = p_band_id;
  return jsonb_build_object('band_id', p_band_id, 'retired', true);
end;
$$;

create or replace function public.erp_approver_assignments(p_object_type text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(x order by x->>'object_type'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'assignment_id', aa.id, 'subject_kind', aa.subject_kind, 'subject_id', aa.subject_id,
      'subject_label', coalesce(u.display_name, d.name, r.name),
      'object_type', aa.object_type,
      'approver_user_id', aa.approver_user_id, 'approver', au.display_name,
      'mode', aa.mode, 'lower_bound_minor', aa.lower_bound_minor,
      'upper_bound_minor', aa.upper_bound_minor, 'reason', aa.reason,
      'version', aa.version, 'valid_from', aa.valid_from, 'valid_to', aa.valid_to,
      'status', aa.status) as x
      from erp.approver_assignment aa
      left join erp.app_user u on u.tenant_id = aa.tenant_id and u.id = aa.subject_id
      left join erp.department d on d.tenant_id = aa.tenant_id and d.id = aa.subject_id
      left join erp.role r on r.tenant_id = aa.tenant_id and r.id = aa.subject_id
      left join erp.app_user au on au.tenant_id = aa.tenant_id and au.id = aa.approver_user_id
     where aa.tenant_id = erp.current_tenant_id()
       and (p_object_type is null or aa.object_type = p_object_type)
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_assign_named_approver(
  p_subject_kind      text,
  p_subject_id        uuid,
  p_object_type       text,
  p_approver_user_id  uuid,
  p_mode              text default 'prepends',
  p_lower_bound_minor bigint default null,
  p_upper_bound_minor bigint default null,
  p_reason            text default null,
  p_valid_from        date default null,
  p_valid_to          date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  perform erp.authorise('administration.configure');

  if p_subject_kind = 'principal' and p_subject_id = p_approver_user_id then
    raise exception 'ERPWARE_SELF_APPROVAL: a principal may not be assigned as their own approver'
      using errcode = '23514';
  end if;

  insert into erp.approver_assignment (
    tenant_id, subject_kind, subject_id, object_type, approver_user_id, mode,
    lower_bound_minor, upper_bound_minor, reason, valid_from, valid_to)
  values (
    v_tenant, p_subject_kind::erp.approver_subject_kind, p_subject_id, p_object_type,
    p_approver_user_id, p_mode::erp.approver_assignment_mode,
    p_lower_bound_minor, p_upper_bound_minor, p_reason,
    coalesce(p_valid_from, current_date), p_valid_to)
  returning id into v_id;

  return jsonb_build_object('assignment_id', v_id);
end;
$$;

create or replace function public.erp_end_approver_assignment(p_assignment_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure');
  update erp.approver_assignment
     set status = 'inactive', valid_to = current_date
   where tenant_id = v_tenant and id = p_assignment_id;
  return jsonb_build_object('assignment_id', p_assignment_id, 'ended', true);
end;
$$;

-- Preview: who would approve this, and which rule said so.
create or replace function public.erp_preview_approval_chain(
  p_object_type   text,
  p_value_minor   bigint,
  p_currency      text default 'GBP',
  p_department_id uuid default null,
  p_requester     uuid default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_chain jsonb;
begin
  perform erp.authorise('administration.read');
  v_chain := erp.resolve_approval_chain(
    p_object_type, p_value_minor, upper(coalesce(p_currency,'GBP'))::char(3),
    p_department_id, p_requester);

  return v_chain || jsonb_build_object(
    'steps', coalesce((
      select jsonb_agg(step || jsonb_build_object('approver',
               (select u.display_name from erp.app_user u
                 where u.tenant_id = erp.current_tenant_id()
                   and u.id = (step->>'approver_user_id')::uuid))
             order by (step->>'seq')::int)
        from jsonb_array_elements(v_chain->'steps') step), '[]'::jsonb));
end;
$$;

-- Stamps the resolved chain on an object: routing is decided once, at capture.
create or replace function public.erp_stamp_approval_routing(
  p_object_type   text,
  p_object_id     uuid,
  p_value_minor   bigint,
  p_currency      text default 'GBP',
  p_department_id uuid default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_chain jsonb;
begin
  perform erp.authorise('administration.configure');
  v_chain := erp.resolve_approval_chain(
    p_object_type, p_value_minor, upper(coalesce(p_currency,'GBP'))::char(3), p_department_id);

  insert into erp.approval_routing_stamp (
    tenant_id, object_type, object_id, department_id, value_minor, currency,
    resolved_chain, resolved_by)
  values (
    v_tenant, p_object_type, p_object_id, (v_chain->>'department_id')::uuid,
    p_value_minor, upper(coalesce(p_currency,'GBP'))::char(3),
    v_chain, erp.current_principal_id());

  perform erp.append_event('approval.chain_resolved', 'approval', p_object_id, v_chain);
  return v_chain;
end;
$$;

create or replace function public.erp_approval_routing_stamps(p_limit integer default 100)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.audit_read');
  select coalesce(jsonb_agg(x order by x->>'resolved_at' desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'stamp_id', s.id, 'object_type', s.object_type, 'object_id', s.object_id,
      'department_id', s.department_id, 'department_code', d.code,
      'value_minor', s.value_minor, 'currency', s.currency,
      'resolved_chain', s.resolved_chain, 'resolved_at', s.resolved_at,
      'resolved_by', u.display_name) as x
      from erp.approval_routing_stamp s
      left join erp.department d on d.tenant_id = s.tenant_id and d.id = s.department_id
      left join erp.app_user u on u.tenant_id = s.tenant_id and u.id = s.resolved_by
     where s.tenant_id = erp.current_tenant_id()
     order by s.resolved_at desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500)
  ) s;
  return v_out;
end;
$$;

-- -----------------------------------------------------------------------------
-- Dimensions: mandatory-by-account and permitted combinations
-- -----------------------------------------------------------------------------

create or replace function public.erp_dimensions()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'dimension_id', d.id, 'code', d.code, 'name', d.name,
      'derivation', d.derivation, 'is_mandatory_default', d.is_mandatory_default,
      'status', d.status,
      'value_count', (select count(*) from erp.dimension_value dv
                       where dv.tenant_id = d.tenant_id and dv.dimension_id = d.id
                         and dv.status = 'active')) as x
      from erp.dimension d
     where d.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_set_account_dimension_requirements(
  p_account_id uuid,
  p_dimension_codes text
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_codes text[];
begin
  perform erp.authorise('finance.configure');
  v_codes := case
    when coalesce(trim(p_dimension_codes), '') = '' then array[]::text[]
    else array(select upper(trim(c)) from unnest(string_to_array(p_dimension_codes, ',')) c
                where trim(c) <> '')
  end;

  -- Refuse a requirement naming a dimension the tenant has not defined:
  -- a posting can then never satisfy it.
  if exists (
    select 1 from unnest(v_codes) c
     where not exists (select 1 from erp.dimension d
                        where d.tenant_id = v_tenant and d.code = c and d.status = 'active'))
  then
    raise exception 'ERPWARE_UNKNOWN_DIMENSION: one or more codes are not configured dimensions'
      using errcode = '23503';
  end if;

  update erp.account set requires_dimensions = v_codes
   where tenant_id = v_tenant and id = p_account_id;

  return jsonb_build_object('account_id', p_account_id, 'requires_dimensions', to_jsonb(v_codes));
end;
$$;

create or replace function public.erp_dimension_rules()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'rule_id', r.id, 'code', r.code, 'name', r.name,
      'condition', r.condition, 'effect', r.effect, 'message', r.message,
      'entity_id', r.entity_id, 'status', r.status) as x
      from erp.dimension_combination_rule r
     where r.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_upsert_dimension_rule(
  p_code      text,
  p_name      text,
  p_condition jsonb,
  p_effect    text default 'block',
  p_message   text default null,
  p_entity_id uuid default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  perform erp.authorise('finance.configure');

  select r.id into v_id from erp.dimension_combination_rule r
   where r.tenant_id = v_tenant and r.code = upper(p_code);

  if v_id is null then
    insert into erp.dimension_combination_rule (
      tenant_id, entity_id, code, name, condition, effect, message)
    values (v_tenant, p_entity_id, upper(p_code), p_name,
            coalesce(p_condition, '{}'::jsonb), p_effect, p_message)
    returning id into v_id;
  else
    update erp.dimension_combination_rule
       set name = p_name, condition = coalesce(p_condition, '{}'::jsonb),
           effect = p_effect, message = p_message, entity_id = p_entity_id
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('rule_id', v_id, 'code', upper(p_code));
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants: authenticated only. Nothing here is public.
-- -----------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_departments()',
    'public.erp_upsert_department(text,text,uuid,uuid,text,uuid,date)',
    'public.erp_department_members(uuid)',
    'public.erp_assign_department(uuid,uuid,boolean,date,date)',
    'public.erp_end_department_membership(uuid,date)',
    'public.erp_approval_bands(uuid,text)',
    'public.erp_upsert_approval_band(uuid,text,integer,bigint,bigint,uuid,text,boolean,text,boolean,boolean,integer,text,numeric)',
    'public.erp_retire_approval_band(uuid)',
    'public.erp_approver_assignments(text)',
    'public.erp_assign_named_approver(text,uuid,text,uuid,text,bigint,bigint,text,date,date)',
    'public.erp_end_approver_assignment(uuid)',
    'public.erp_preview_approval_chain(text,bigint,text,uuid,uuid)',
    'public.erp_stamp_approval_routing(text,uuid,bigint,text,uuid)',
    'public.erp_approval_routing_stamps(integer)',
    'public.erp_dimensions()',
    'public.erp_set_account_dimension_requirements(uuid,text)',
    'public.erp_dimension_rules()',
    'public.erp_upsert_dimension_rule(text,text,jsonb,text,text,uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;

select erp.apply_row_security();
