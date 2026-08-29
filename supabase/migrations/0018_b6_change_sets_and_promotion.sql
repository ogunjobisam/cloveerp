-- =============================================================================
-- ERPWare — B6 (part 2/2): change sets, promotion, rollback, drift
-- Spec 3.11:
--   "Changes accumulate as named change sets with diffs against the target
--    environment"
--   "Promotion is previewed, gated by approval, validated by tests, scopeable
--    and scheduled, and requires no downtime"
--
-- The payload format of a change-set item is exactly the content format of a
-- manifest entry. That is not tidiness for its own sake — it means the diff
-- between two environments can be turned into a change set mechanically, a
-- change set can be previewed against any environment with the same comparison
-- that produced it, and a rollback is a change set built from a snapshot.
-- Three features, one format.
--
-- Payloads reference things by CODE, never by id. A change set built in
-- development has to apply in production, where every surrogate key differs.
-- =============================================================================

create type erp.change_set_status as enum (
  'draft', 'ready', 'approved', 'promoting', 'promoted', 'failed',
  'rolled_back', 'cancelled'
);

create type erp.change_operation as enum ('upsert', 'remove');

create table erp.change_set (
  id                    uuid not null default gen_random_uuid(),
  tenant_id             uuid not null references erp.tenant(id) on delete cascade,
  code                  text not null,
  name                  text not null,
  description           text,
  status                erp.change_set_status not null default 'draft',
  source_environment_id uuid,
  target_environment_id uuid,
  -- Spec 3.11: promotion is scheduled. Null means "as soon as approved".
  scheduled_for         timestamptz,
  approval_request_id   uuid,
  approved_by           uuid,
  approved_at           timestamptz,
  promoted_at           timestamptz,
  rollback_snapshot_id  uuid,
  failure_reason        text,
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, source_environment_id)
    references erp.environment (tenant_id, id) on delete set null,
  foreign key (tenant_id, target_environment_id)
    references erp.environment (tenant_id, id) on delete set null
);

create index on erp.change_set (tenant_id, status);

create table erp.change_set_item (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  change_set_id uuid not null,
  seq           integer not null,
  object_kind   text not null,
  object_key    text not null,
  operation     erp.change_operation not null default 'upsert',
  -- Same shape as a manifest entry's content. Codes, never ids.
  payload       jsonb not null default '{}'::jsonb,
  effective_from date,
  note          text,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  unique (tenant_id, change_set_id, object_kind, object_key),
  foreign key (tenant_id, change_set_id)
    references erp.change_set (tenant_id, id) on delete cascade
);

create index on erp.change_set_item (tenant_id, change_set_id, seq);

create table erp.promotion (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  change_set_id  uuid not null,
  environment_id uuid,
  status         text not null default 'running'
                   check (status in ('running', 'succeeded', 'failed', 'rolled_back')),
  snapshot_id    uuid,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  applied_count  integer not null default 0,
  scope_kinds    text[],
  error          text,
  actor_id       uuid,
  primary key (id),
  foreign key (tenant_id, change_set_id)
    references erp.change_set (tenant_id, id) on delete cascade
);

create index on erp.promotion (tenant_id, change_set_id, started_at desc);

-- -----------------------------------------------------------------------------
-- Building a change set
-- -----------------------------------------------------------------------------

create or replace function erp.create_change_set(
  p_code text, p_name text, p_description text default null,
  p_scheduled_for timestamptz default null)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', null);

  insert into erp.change_set (
    tenant_id, code, name, description, scheduled_for, created_by,
    source_environment_id)
  values (
    v_tenant, p_code, p_name, p_description, p_scheduled_for,
    erp.current_principal_id(),
    (select e.id from erp.environment e where e.tenant_id = v_tenant and e.is_self))
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.add_change_set_item(
  p_change_set_id uuid,
  p_object_kind   text,
  p_object_key    text,
  p_payload       jsonb,
  p_operation     erp.change_operation default 'upsert',
  p_effective_from date default null,
  p_note          text default null)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_seq    integer;
  v_id     uuid;
begin
  if (select cs.status from erp.change_set cs
       where cs.tenant_id = v_tenant and cs.id = p_change_set_id) <> 'draft' then
    raise exception 'ERPWARE_CHANGE_SET_NOT_DRAFT: items may only be added while the set is draft'
      using errcode = '23514';
  end if;

  select coalesce(max(i.seq), 0) + 10 into v_seq
    from erp.change_set_item i
   where i.tenant_id = v_tenant and i.change_set_id = p_change_set_id;

  insert into erp.change_set_item (
    tenant_id, change_set_id, seq, object_kind, object_key, operation,
    payload, effective_from, note)
  values (
    v_tenant, p_change_set_id, v_seq, p_object_kind, p_object_key, p_operation,
    p_payload, p_effective_from, p_note)
  on conflict (tenant_id, change_set_id, object_kind, object_key) do update
    set payload = excluded.payload, operation = excluded.operation,
        effective_from = excluded.effective_from, note = excluded.note,
        updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

-- "Changes accumulate as named change sets": capture everything that has moved
-- since a snapshot, so an administrator configures normally in a development
-- environment and then collects the result, rather than remembering to declare
-- each change as they make it.
create or replace function erp.capture_change_set_from_snapshot(
  p_change_set_id uuid, p_snapshot_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_count  integer := 0;
begin
  for r in
    with snap as (
      select e.value ->> 'kind' as kind, e.value ->> 'key' as key,
             e.value -> 'content' as content, e.value ->> 'hash' as hash
        from erp.config_snapshot s
        cross join lateral jsonb_array_elements(s.content) e
       where s.tenant_id = v_tenant and s.id = p_snapshot_id
    ),
    live as (select * from erp.configuration_manifest())
    select coalesce(l.object_kind, s.kind) as kind,
           coalesce(l.object_key, s.key)   as key,
           case when l.object_key is null then 'remove' else 'upsert' end as op,
           coalesce(l.content, s.content)  as content
      from live l
      full outer join snap s on s.kind = l.object_kind and s.key = l.object_key
     where l.content_hash is distinct from s.hash
  loop
    perform erp.add_change_set_item(
      p_change_set_id, r.kind, r.key, r.content, r.op::erp.change_operation);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Spec 3.11: promotion is previewed. What this set would do to THIS
-- environment, computed the same way the drift comparison is.
create or replace function erp.preview_change_set(p_change_set_id uuid)
returns table (object_kind text, object_key text, effect text,
               current_content jsonb, proposed_content jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  select i.object_kind, i.object_key,
         case
           when i.operation = 'remove' and m.object_key is null then 'no change (already absent)'
           when i.operation = 'remove' then 'removes'
           when m.object_key is null then 'creates'
           when md5(i.payload::text) = m.content_hash then 'no change (identical)'
           else 'updates'
         end,
         m.content, i.payload
    from erp.change_set_item i
    left join erp.configuration_manifest() m
      on m.object_kind = i.object_kind and m.object_key = i.object_key
   where i.tenant_id = erp.require_tenant_id()
     and i.change_set_id = p_change_set_id
   order by i.seq
$$;

-- -----------------------------------------------------------------------------
-- Applying one item
--
-- Payloads name things by code; this is where codes become the local ids of
-- whichever environment is applying them.
-- -----------------------------------------------------------------------------

create or replace function erp.apply_change_set_item(p_item_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  i         erp.change_set_item%rowtype;
  p         jsonb;
  v_entity  uuid;
  v_site    uuid;
  v_from    date;
  v_obj     uuid;
  v_ver     uuid;
  v_vnum    integer;
  r         record;
  v_state   uuid;
begin
  select * into i from erp.change_set_item where tenant_id = v_tenant and id = p_item_id;
  p := i.payload;

  -- Codes to local ids. A change set built elsewhere knows nothing of our keys.
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.code = (p ->> 'entity');
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = (p ->> 'site');
  v_from := coalesce(i.effective_from, (p ->> 'effective_from')::date, current_date);

  if (p ? 'entity') and (p ->> 'entity') is not null and v_entity is null then
    raise exception 'ERPWARE_PROMOTION_UNKNOWN_ENTITY: this environment has no entity %',
      p ->> 'entity' using errcode = '23503';
  end if;

  case i.object_kind

    when 'config' then
      if i.operation = 'remove' then
        update erp.config_object co set status = 'inactive', updated_at = now()
         where co.tenant_id = v_tenant
           and co.config_type_code = (p ->> 'config_type')
           and co.code is not distinct from (p ->> 'code')
           and co.entity_id is not distinct from v_entity
           and co.site_id is not distinct from v_site;
      else
        perform erp.set_config_value(
          p ->> 'config_type', p -> 'value', p ->> 'code', v_from,
          v_entity, v_site, 'promoted');
      end if;

    when 'terminology' then
      if i.operation = 'remove' then
        update erp.resource_override ro set status = 'inactive', updated_at = now()
         where ro.tenant_id = v_tenant and ro.key = (p ->> 'key')
           and ro.locale = (p ->> 'locale') and ro.entity_id is not distinct from v_entity;
      else
        insert into erp.resource_override (tenant_id, key, locale, value, entity_id)
        values (v_tenant, p ->> 'key', p ->> 'locale', p ->> 'value', v_entity)
        on conflict (tenant_id, key, locale,
                     coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
          do update set value = excluded.value, status = 'active', updated_at = now();
      end if;

    when 'legislation_binding' then
      if i.operation = 'remove' then
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack');
      else
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack') and b.status = 'active';
        insert into erp.entity_legislation_binding (
          tenant_id, entity_id, pack_code, pack_version, effective_from, effective_to)
        values (v_tenant, v_entity, p ->> 'pack', (p ->> 'pack_version')::integer,
                v_from, (p ->> 'effective_to')::date);
      end if;

    when 'event_subscription' then
      if i.operation = 'remove' then
        update erp.event_subscription es set status = 'inactive', updated_at = now()
         where es.tenant_id = v_tenant and es.consumer_code = (p ->> 'consumer')
           and es.event_pattern = (p ->> 'pattern');
      else
        insert into erp.event_subscription (
          tenant_id, consumer_code, event_pattern, module_code, max_attempts)
        values (v_tenant, p ->> 'consumer', p ->> 'pattern', p ->> 'module',
                coalesce((p ->> 'max_attempts')::smallint, 8))
        on conflict (tenant_id, consumer_code, event_pattern) do update
          set module_code = excluded.module_code,
              max_attempts = excluded.max_attempts,
              status = 'active', updated_at = now();
      end if;

    when 'role' then
      if i.operation = 'remove' then
        update erp.role r set status = 'inactive', updated_at = now()
         where r.tenant_id = v_tenant and r.code = (p ->> 'code');
      else
        insert into erp.role (tenant_id, code, name, name_key, from_template)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
        on conflict (tenant_id, code) do update
          set name = excluded.name, name_key = excluded.name_key,
              status = 'active', updated_at = now()
        returning id into v_obj;

        -- The grant set is replaced wholesale: a promoted role is the role the
        -- change set describes, not a merge with whatever was here before.
        delete from erp.role_permission rp
         where rp.tenant_id = v_tenant and rp.role_id = v_obj;

        insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
        select v_tenant, v_obj, e.value ->> 'permission',
               coalesce((select array_agg(dc #>> '{}')
                           from jsonb_array_elements(e.value -> 'data_classes') dc),
                        '{}'::text[])
          from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
      end if;

    when 'rule_set' then
      if i.operation = 'remove' then
        update erp.rule_set rs set status = 'inactive', updated_at = now()
         where rs.tenant_id = v_tenant
           and rs.decision_point_code = (p ->> 'decision_point')
           and rs.code = (p ->> 'code');
      else
        insert into erp.rule_set (tenant_id, decision_point_code, code, name, entity_id, site_id)
        values (v_tenant, p ->> 'decision_point', p ->> 'code', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, decision_point_code, code) do update
          set name = excluded.name, status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.rule_set_version v
         where v.tenant_id = v_tenant and v.rule_set_id = v_obj;

        insert into erp.rule_set_version (
          tenant_id, rule_set_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.rule (
          tenant_id, rule_set_version_id, seq, code, name, condition, outcome,
          stop_on_match, is_active)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', e.value -> 'condition', e.value -> 'outcome',
               coalesce((e.value ->> 'stop_on_match')::boolean, true),
               coalesce((e.value ->> 'is_active')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'rules', '[]'::jsonb)) e;

        -- Activation runs the linter, so a promotion cannot introduce a rule
        -- that can never match.
        perform erp.activate_rule_set_version(v_ver, v_from);
      end if;

    when 'state_machine' then
      if i.operation = 'remove' then
        update erp.state_machine sm set status = 'inactive', updated_at = now()
         where sm.tenant_id = v_tenant and sm.code = (p ->> 'code');
      else
        insert into erp.state_machine (tenant_id, code, object_type, name, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'object_type', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, code) do update
          set object_type = excluded.object_type, name = excluded.name,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.state_machine_version v
         where v.tenant_id = v_tenant and v.state_machine_id = v_obj;

        insert into erp.state_machine_version (
          tenant_id, state_machine_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.state (
          tenant_id, state_machine_version_id, code, name, is_initial, is_terminal,
          is_committed, sort_order, on_enter, on_exit)
        select v_tenant, v_ver, e.value ->> 'code', e.value ->> 'name',
               coalesce((e.value ->> 'is_initial')::boolean, false),
               coalesce((e.value ->> 'is_terminal')::boolean, false),
               coalesce((e.value ->> 'is_committed')::boolean, false),
               coalesce((e.value ->> 'sort_order')::integer, 100),
               coalesce(e.value -> 'on_enter', '[]'::jsonb),
               coalesce(e.value -> 'on_exit', '[]'::jsonb)
          from jsonb_array_elements(coalesce(p -> 'states', '[]'::jsonb)) e;

        -- Transitions come second because they reference states by code.
        for r in select e.value as tr
                   from jsonb_array_elements(coalesce(p -> 'transitions', '[]'::jsonb)) e
        loop
          insert into erp.transition (
            tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id,
            guard, effects, required_permission, is_automatic, sort_order)
          select v_tenant, v_ver, r.tr ->> 'code', r.tr ->> 'name',
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'from'),
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'to'),
                 coalesce(r.tr -> 'guard', 'true'::jsonb),
                 coalesce(r.tr -> 'effects', '[]'::jsonb),
                 r.tr ->> 'required_permission',
                 coalesce((r.tr ->> 'is_automatic')::boolean, false),
                 coalesce((r.tr ->> 'sort_order')::integer, 100);
        end loop;

        -- Activation runs the graph validation, so a promotion cannot
        -- introduce a state a document could enter and never leave.
        perform erp.activate_state_machine_version(v_ver, v_from);
      end if;

    when 'approval_chain' then
      if i.operation = 'remove' then
        update erp.approval_chain ac set status = 'inactive', updated_at = now()
         where ac.tenant_id = v_tenant and ac.code = (p ->> 'code');
      else
        insert into erp.approval_chain (
          tenant_id, code, name, object_type, applies_when, priority, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'object_type',
                coalesce(p -> 'applies_when', 'true'::jsonb),
                coalesce((p ->> 'priority')::integer, 100), v_entity, v_site)
        on conflict (tenant_id, code) do update
          set name = excluded.name, object_type = excluded.object_type,
              applies_when = excluded.applies_when, priority = excluded.priority,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.approval_chain_version v
         where v.tenant_id = v_tenant and v.approval_chain_id = v_obj;

        insert into erp.approval_chain_version (
          tenant_id, approval_chain_id, version, status, effective_from,
          material_fields, value_field, tolerance_pct, tolerance_absolute, note)
        values (
          v_tenant, v_obj, v_vnum, 'draft', v_from,
          coalesce((select array_agg(f #>> '{}')
                      from jsonb_array_elements(coalesce(p -> 'material_fields', '[]'::jsonb)) f),
                   '{}'::text[]),
          p ->> 'value_field',
          (p ->> 'tolerance_pct')::numeric,
          (p ->> 'tolerance_absolute')::numeric,
          'promoted')
        returning id into v_ver;

        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', (e.value ->> 'approver_kind')::erp.approver_kind,
               (select ro.id from erp.role ro
                 where ro.tenant_id = v_tenant and ro.code = e.value ->> 'role'),
               (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and u.email = e.value ->> 'user'),
               coalesce((e.value ->> 'min_approvals')::smallint, 1),
               coalesce(e.value -> 'condition', 'true'::jsonb),
               (e.value ->> 'escalate_after')::interval,
               coalesce((e.value ->> 'allow_delegation')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'steps', '[]'::jsonb)) e;

        -- Activation refuses a chain with no steps, so a promotion cannot
        -- install one that approves everything unchecked.
        perform erp.activate_approval_chain_version(v_ver, v_from);
      end if;

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain';
  end case;
end;
$$;

-- -----------------------------------------------------------------------------
-- Gating and promoting
-- -----------------------------------------------------------------------------

create or replace function erp.submit_change_set(p_change_set_id uuid)
returns erp.change_set_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_chain  uuid;
  v_req    uuid;
  v_items  integer;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', p_change_set_id);

  select count(*) into v_items from erp.change_set_item
   where tenant_id = v_tenant and change_set_id = p_change_set_id;

  if v_items = 0 then
    raise exception 'ERPWARE_CHANGE_SET_EMPTY: nothing to promote' using errcode = '23514';
  end if;

  -- If the tenant has configured an approval chain for change sets, promotion
  -- goes through the same engine as everything else rather than a private one.
  v_chain := erp.select_approval_chain('change_set',
               jsonb_build_object('item_count', v_items));

  if v_chain is not null then
    v_req := erp.request_approval('change_set', p_change_set_id,
               jsonb_build_object('item_count', v_items));
    update erp.change_set set status = 'ready', approval_request_id = v_req, updated_at = now()
     where tenant_id = v_tenant and id = p_change_set_id;
    return 'ready';
  end if;

  update erp.change_set set status = 'ready', updated_at = now()
   where tenant_id = v_tenant and id = p_change_set_id;
  return 'ready';
end;
$$;

create or replace function erp.approve_change_set(p_change_set_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cs       erp.change_set%rowtype;
  v_status erp.approval_status;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  select * into cs from erp.change_set where tenant_id = v_tenant and id = p_change_set_id;

  if cs.status <> 'ready' then
    raise exception 'ERPWARE_CHANGE_SET_NOT_READY: % is %', cs.code, cs.status
      using errcode = '23514';
  end if;

  if cs.approval_request_id is not null then
    select ar.status into v_status from erp.approval_request ar where ar.id = cs.approval_request_id;
    if v_status <> 'approved' then
      raise exception 'ERPWARE_CHANGE_SET_APPROVAL_PENDING: the approval request is %', v_status
        using errcode = '23514';
    end if;
  end if;

  -- Whoever raised the change may not be the one who waves it through.
  if cs.created_by is not null and cs.created_by = erp.current_principal_id() then
    raise exception
      'ERPWARE_CHANGE_SET_SELF_APPROVAL: the author of a change set may not approve it'
      using errcode = '42501';
  end if;

  update erp.change_set
     set status = 'approved', approved_by = erp.current_principal_id(),
         approved_at = now(), updated_at = now()
   where tenant_id = v_tenant and id = p_change_set_id;
end;
$$;

create or replace function erp.promote_change_set(
  p_change_set_id uuid,
  p_scope_kinds   text[] default null,
  p_ignore_schedule boolean default false)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  cs         erp.change_set%rowtype;
  v_promo    uuid;
  v_snapshot uuid;
  v_applied  integer := 0;
  r          record;
  v_entity   record;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  select * into cs from erp.change_set
   where tenant_id = v_tenant and id = p_change_set_id for update;

  if cs.status <> 'approved' then
    raise exception 'ERPWARE_CHANGE_SET_NOT_APPROVED: % is %', cs.code, cs.status
      using errcode = '42501';
  end if;

  if cs.scheduled_for is not null and not p_ignore_schedule and now() < cs.scheduled_for then
    raise exception 'ERPWARE_CHANGE_SET_NOT_DUE: % is scheduled for %', cs.code, cs.scheduled_for
      using errcode = '23514';
  end if;

  -- Snapshot first. Rollback is only "one action" if the previous state was
  -- captured before anything moved.
  v_snapshot := erp.take_config_snapshot(
    format('before promotion of %s', cs.code),
    format('pre-%s-%s', cs.code, to_char(clock_timestamp(), 'YYYYMMDDHH24MISS')));

  insert into erp.promotion (
    tenant_id, change_set_id, environment_id, snapshot_id, scope_kinds, actor_id)
  values (
    v_tenant, p_change_set_id,
    (select e.id from erp.environment e where e.tenant_id = v_tenant and e.is_self),
    v_snapshot, p_scope_kinds, erp.current_principal_id())
  returning id into v_promo;

  update erp.change_set
     set status = 'promoting', rollback_snapshot_id = v_snapshot, updated_at = now()
   where id = p_change_set_id;

  -- Opens the window in which configuration may be written in a live
  -- environment. Transaction-scoped, so it closes whatever happens next.
  perform set_config('erp.promotion_id', v_promo::text, true);

  for r in
    select i.id from erp.change_set_item i
     where i.tenant_id = v_tenant
       and i.change_set_id = p_change_set_id
       and (p_scope_kinds is null or i.object_kind = any (p_scope_kinds))
     order by
       -- Roles and terminology before the things that reference them.
       case i.object_kind
         when 'role' then 1 when 'terminology' then 2 when 'config' then 3
         when 'legislation_binding' then 4 when 'event_subscription' then 5
         when 'rule_set' then 6 when 'state_machine' then 7
         when 'approval_chain' then 8 else 9 end,
       i.seq
  loop
    perform erp.apply_change_set_item(r.id);
    v_applied := v_applied + 1;
  end loop;

  -- Spec 3.11: "validated by tests". The pack conformance suite is the test
  -- that matters most here, because a promotion that quietly changes a tax
  -- answer is the expensive kind.
  for v_entity in
    select distinct b.entity_id from erp.entity_legislation_binding b
     where b.tenant_id = v_tenant and b.status = 'active'
  loop
    perform erp.assert_legislation_conformance(v_entity.entity_id);
  end loop;

  update erp.promotion
     set status = 'succeeded', finished_at = now(), applied_count = v_applied
   where id = v_promo;

  update erp.change_set
     set status = 'promoted', promoted_at = now(), updated_at = now()
   where id = p_change_set_id;

  perform set_config('erp.promotion_id', '', true);

  return v_promo;
end;
$$;

comment on function erp.promote_change_set is
  'Snapshot, apply, validate. The whole thing is one transaction, so a failure '
  'anywhere leaves the environment exactly as it was — which is what "requires '
  'no downtime" has to mean in practice: not that promotion is fast, but that '
  'a half-applied configuration never exists.';

-- -----------------------------------------------------------------------------
-- Rollback
-- -----------------------------------------------------------------------------

create or replace function erp.rollback_to_snapshot(
  p_snapshot_id uuid, p_reason text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
  v_code   text := 'rollback-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS');
  r        record;
  v_promo  uuid;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'config_snapshot', p_snapshot_id);

  -- A rollback is a change set like any other, so it is previewable, audited
  -- and itself rollback-able. Restoring by a private back door would be the
  -- one configuration change with no record of what it did.
  insert into erp.change_set (tenant_id, code, name, description, status, created_by)
  values (v_tenant, v_code, 'Rollback', p_reason, 'draft', erp.current_principal_id())
  returning id into v_cs;

  for r in
    select e.value ->> 'kind' as kind, e.value ->> 'key' as key,
           e.value -> 'content' as content
      from erp.config_snapshot s
      cross join lateral jsonb_array_elements(s.content) e
     where s.tenant_id = v_tenant and s.id = p_snapshot_id
  loop
    perform erp.add_change_set_item(v_cs, r.kind, r.key, r.content, 'upsert');
  end loop;

  -- Anything created since the snapshot is removed, which is exactly what the
  -- blast-radius preview warned about.
  for r in select * from erp.blast_radius(p_snapshot_id) where change = 'would be removed'
  loop
    perform erp.add_change_set_item(
      v_cs, r.object_kind, r.object_key, r.current_content, 'remove');
  end loop;

  update erp.change_set
     set status = 'approved', approved_by = erp.current_principal_id(), approved_at = now()
   where id = v_cs;

  v_promo := erp.promote_change_set(v_cs);

  update erp.promotion set status = 'rolled_back' where id = v_promo;
  update erp.change_set set status = 'rolled_back' where id = v_cs;

  return v_cs;
end;
$$;

-- -----------------------------------------------------------------------------
-- Drift
--
-- Spec 3.11: "Environments cannot silently diverge [...] drift is detected
-- continuously". Other environments publish their manifests here; comparison is
-- then the same hash comparison used everywhere else in this migration.
-- -----------------------------------------------------------------------------

create table erp.environment_manifest (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  environment_id uuid not null,
  captured_at    timestamptz not null default now(),
  entry_count    integer not null default 0,
  content        jsonb not null,
  content_hash   text not null,
  primary key (id),
  foreign key (tenant_id, environment_id)
    references erp.environment (tenant_id, id) on delete cascade
);

create index on erp.environment_manifest (tenant_id, environment_id, captured_at desc);

create or replace function erp.publish_manifest(p_environment_code text default null)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_env     uuid;
  v_content jsonb;
  v_count   integer;
  v_id      uuid;
begin
  select e.id into v_env from erp.environment e
   where e.tenant_id = v_tenant
     and (case when p_environment_code is null then e.is_self else e.code = p_environment_code end);

  if v_env is null then
    raise exception 'ERPWARE_UNKNOWN_ENVIRONMENT: %', coalesce(p_environment_code, '(self)')
      using errcode = '23503';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', m.object_kind, 'key', m.object_key,
           'content', m.content, 'hash', m.content_hash)
           order by m.object_kind, m.object_key), '[]'::jsonb), count(*)
    into v_content, v_count
    from erp.configuration_manifest() m;

  insert into erp.environment_manifest (
    tenant_id, environment_id, entry_count, content, content_hash)
  values (v_tenant, v_env, v_count, v_content, md5(v_content::text))
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.detect_drift(p_environment_code text)
returns table (object_kind text, object_key text, finding text,
               here jsonb, there jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  with latest as (
    select em.content
      from erp.environment_manifest em
      join erp.environment e
        on e.tenant_id = em.tenant_id and e.id = em.environment_id
     where em.tenant_id = erp.require_tenant_id()
       and e.code = p_environment_code
     order by em.captured_at desc
     limit 1
  ),
  there as (
    select e.value ->> 'kind' as kind, e.value ->> 'key' as key,
           e.value -> 'content' as content, e.value ->> 'hash' as hash
      from latest cross join lateral jsonb_array_elements(latest.content) e
  ),
  here as (select * from erp.configuration_manifest())
  select coalesce(h.object_kind, t.kind),
         coalesce(h.object_key, t.key),
         case
           when t.key is null then 'present here, absent there'
           when h.object_key is null then 'absent here, present there'
           else 'differs'
         end,
         h.content, t.content
    from here h
    full outer join there t on t.kind = h.object_kind and t.key = h.object_key
   where h.content_hash is distinct from t.hash
   order by 1, 2
$$;

comment on function erp.detect_drift(text) is
  'Compares this environment''s live configuration against the last manifest '
  'published by another. Runs on a schedule (B9), so divergence surfaces while '
  'it is still one change rather than at the next release.';

select erp.apply_live_config_guards();
select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
