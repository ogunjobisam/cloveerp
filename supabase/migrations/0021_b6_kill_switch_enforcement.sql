-- =============================================================================
-- ERPWare — B6: making the kill switch actually stop things
--
-- Migration 0017 gave kill switches a table, a setter and a predicate. None of
-- that stops anything on its own: a switch nobody consults is a note.
--
-- Spec 3.11 says a kill switch "disables an individual rule, job or command
-- class immediately". Immediately is the operative word — it is the one route
-- that deliberately bypasses promotion, because the point is to stop something
-- that is actively doing harm, and a change set takes approval.
--
-- What a killed rule set MUST NOT do is silently produce no answer. Tax
-- determination requires a match; if killing a tenant's rule set made that
-- decision point return nothing, the kill switch would turn a suspected
-- mispricing into a hard stop on every invoice. So a kill removes that layer
-- and evaluation continues to the next one — legislation, then the product
-- default — and the trace records that it was skipped and why.
--
-- This migration also re-states erp.apply_change_set_item() so that approval
-- chains activate through erp.activate_approval_chain_version() (added in 0019)
-- rather than the inline update it originally carried, which had the same
-- same-day supersede defect. Databases that applied the earlier definition need
-- this; a fresh one already has it from 0018.
-- =============================================================================

drop function if exists erp.evaluate_rules(text, jsonb, date, uuid, uuid);

create or replace function erp.evaluate_rules(
  p_decision_point text,
  p_data           jsonb default '{}'::jsonb,
  p_on             date default null,
  p_entity_id      uuid default null,
  p_site_id        uuid default null
) returns table (
  matched             boolean,
  outcome             jsonb,
  rule_id             uuid,
  rule_code           text,
  rule_set_id         uuid,
  rule_set_version_id uuid,
  rule_set_version    integer,
  trace               jsonb,
  source              text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_on      date := coalesce(p_on, current_date);
  v_dp      erp_ref.decision_point%rowtype;
  v_set     record;
  v_leg     record;
  r         record;
  v_hit     boolean;
  v_trace   jsonb := '[]'::jsonb;
  v_outcome jsonb := null;
  v_stopped boolean := false;
  v_killed  boolean := false;
begin
  select * into v_dp from erp_ref.decision_point where code = p_decision_point;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DECISION_POINT: %', p_decision_point
      using errcode = '23503';
  end if;

  if not extensions.jsonb_matches_schema(v_dp.input_schema::json, p_data) then
    raise exception 'ERPWARE_RULE_INPUT_INVALID: facts supplied to % do not match its input schema',
      p_decision_point using errcode = '23514', detail = p_data::text;
  end if;

  if v_dp.legislation_authoritative then
    select * into v_leg
      from erp.evaluate_legislation_rules(p_decision_point, p_data, p_entity_id, v_on);
    if found then
      matched := true; outcome := v_leg.outcome; rule_code := v_leg.rule_code;
      trace := v_leg.trace; source := 'legislation:' || v_leg.pack_code;
      return next; return;
    end if;
    v_trace := coalesce(v_leg.trace, '[]'::jsonb);
  end if;

  select rs.id, rs.code, rsv.id as version_id, rsv.version
    into v_set
    from erp.rule_set rs
    join erp.rule_set_version rsv
      on rsv.tenant_id = rs.tenant_id
     and rsv.rule_set_id = rs.id
     and rsv.status = 'active'
     and daterange(rsv.effective_from, rsv.effective_to, '[)') @> v_on
   where rs.tenant_id = v_tenant
     and rs.decision_point_code = p_decision_point
     and rs.status = 'active'
     and (rs.site_id   is null or rs.site_id   = p_site_id)
     and (rs.entity_id is null or rs.entity_id = p_entity_id)
   order by (rs.site_id is not null) desc, (rs.entity_id is not null) desc
   limit 1;

  if found then
    v_killed := erp.is_killed('rule_set', p_decision_point || '|' || v_set.code);

    if v_killed then
      -- Recorded, not silent. Someone reading this trace next week needs to
      -- know the rules did not simply fail to match.
      v_trace := v_trace || jsonb_build_array(jsonb_build_object(
        'source', 'tenant', 'rule_set', v_set.code, 'result', 'killed',
        'note', 'rule set disabled by kill switch; evaluation continued to the next layer'));
    else
      for r in
        select ru.id, ru.seq, ru.code, ru.condition, ru.outcome, ru.stop_on_match
          from erp.rule ru
         where ru.tenant_id = v_tenant
           and ru.rule_set_version_id = v_set.version_id
           and ru.is_active
         order by ru.seq
      loop
        if v_stopped then
          v_trace := v_trace || jsonb_build_array(jsonb_build_object(
            'source', 'tenant', 'seq', r.seq, 'rule_code', r.code, 'result', 'not_reached'));
          continue;
        end if;

        -- An individual rule may be killed without taking the set with it.
        if erp.is_killed('rule', p_decision_point || '|' || v_set.code || '|' || r.code) then
          v_trace := v_trace || jsonb_build_array(jsonb_build_object(
            'source', 'tenant', 'seq', r.seq, 'rule_code', r.code, 'result', 'killed'));
          continue;
        end if;

        v_hit := erp.jsonlogic_bool(r.condition, p_data);

        v_trace := v_trace || jsonb_build_array(jsonb_build_object(
          'source', 'tenant',
          'seq', r.seq,
          'rule_code', r.code,
          'result', case when v_hit then 'matched' else 'no_match' end,
          'condition', r.condition));

        if v_hit then
          v_outcome := case when v_outcome is null then r.outcome else v_outcome || r.outcome end;
          rule_id   := r.id;
          rule_code := r.code;
          if r.stop_on_match then v_stopped := true; end if;
        end if;
      end loop;
    end if;
  end if;

  if v_outcome is not null then
    matched := true; outcome := v_outcome;
    rule_set_id := v_set.id; rule_set_version_id := v_set.version_id;
    rule_set_version := v_set.version; trace := v_trace; source := 'tenant';
    return next; return;
  end if;

  if not v_dp.legislation_authoritative then
    select * into v_leg
      from erp.evaluate_legislation_rules(p_decision_point, p_data, p_entity_id, v_on);
    if found then
      matched := true; outcome := v_leg.outcome; rule_code := v_leg.rule_code;
      trace := v_trace || v_leg.trace; source := 'legislation:' || v_leg.pack_code;
      return next; return;
    end if;
  end if;

  if v_dp.requires_match then
    raise exception 'ERPWARE_RULE_NO_MATCH: no rule matched at % and it requires one',
      p_decision_point using errcode = '23514', detail = p_data::text;
  end if;

  matched := false;
  outcome := v_dp.default_outcome;
  rule_code := '(default)';
  rule_set_id := v_set.id;
  rule_set_version_id := v_set.version_id;
  rule_set_version := v_set.version;
  trace := v_trace;
  source := case when v_killed then 'default (rule set killed)' else 'default' end;
  return next;
end;
$$;

comment on function erp.evaluate_rules is
  'Evaluates legislation and tenant rules for a decision point at a date. A '
  'killed rule set is skipped rather than made to fail: evaluation falls '
  'through to the next layer, and the trace records that it was disabled.';

-- -----------------------------------------------------------------------------
-- Re-stated from 0018 so that approval chains activate through
-- erp.activate_approval_chain_version() rather than the inline update the
-- original carried, which had the same-day supersede defect fixed in 0019.
-- Identical to the definition in 0018; a fresh database already has it.
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
