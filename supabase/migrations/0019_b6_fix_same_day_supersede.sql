-- =============================================================================
-- ERPWare — B6: fix superseding a version that starts on the same day
--
-- Found by the first rollback that was tried.
--
-- Every activation path (configuration values, rule sets, state machines,
-- approval chains) closed the version currently in force by setting
-- effective_to to the new start date:
--
--     set effective_to = v_from,
--         status = case when effective_from >= v_from then 'superseded' ... end
--
-- That is right when the outgoing version started EARLIER: it gets the window
-- [its start, v_from) and becomes history. It is wrong when the outgoing
-- version started on the SAME date, because it produces effective_to =
-- effective_from — an empty window, which the range check refuses. The status
-- assignment in the same statement was meant to handle that case, but the
-- check constraint fires on the row as a whole, so it never got the chance.
--
-- In normal use this is invisible: changes are made on later days than the
-- versions they replace. It appears the moment something re-applies a value
-- effective from a date already in use — which is exactly what a rollback
-- does, and what promoting the same change set twice does.
--
-- The fix: only move effective_to when the outgoing version actually started
-- earlier. One that started on or after the new date is wholly replaced, so it
-- is marked superseded and its dates are left alone — it never applied, and
-- the exclusion constraint ignores non-active rows.
-- =============================================================================

create or replace function erp.set_config_value(
  p_type_code      text,
  p_value          jsonb,
  p_code           text default null,
  p_effective_from date default null,
  p_entity_id      uuid default null,
  p_site_id        uuid default null,
  p_note           text default null,
  p_activate       boolean default true
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_object  uuid;
  v_from    date := coalesce(p_effective_from, current_date);
  v_version integer;
  v_new     uuid;
begin
  insert into erp.config_object (tenant_id, config_type_code, code, entity_id, site_id)
  values (v_tenant, p_type_code, p_code, p_entity_id, p_site_id)
  on conflict (tenant_id, config_type_code, coalesce(code, ''),
               coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid),
               coalesce(site_id,   '00000000-0000-0000-0000-000000000000'::uuid))
    do update set status = 'active', updated_at = now()
  returning id into v_object;

  select coalesce(max(cv.version), 0) + 1
    into v_version
    from erp.config_version cv
   where cv.tenant_id = v_tenant and cv.config_object_id = v_object;

  if p_activate then
    update erp.config_version cv
       set effective_to = case when cv.effective_from < v_from
                               then v_from else cv.effective_to end,
           status = case when cv.effective_from >= v_from
                         then 'superseded'::erp.config_version_status
                         else cv.status end,
           updated_at = now()
     where cv.tenant_id = v_tenant
       and cv.config_object_id = v_object
       and cv.status = 'active'
       and (cv.effective_to is null or cv.effective_to > v_from);
  end if;

  insert into erp.config_version (
    tenant_id, config_object_id, version, value, status, effective_from, note)
  values (
    v_tenant, v_object, v_version, p_value,
    (case when p_activate then 'active' else 'draft' end)::erp.config_version_status,
    v_from, p_note)
  returning id into v_new;

  return v_new;
end;
$$;

create or replace function erp.activate_rule_set_version(
  p_rule_set_version_id uuid,
  p_effective_from      date default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_errors   text;
  v_count    integer;
  v_set      uuid;
  v_from     date := coalesce(p_effective_from, current_date);
begin
  select rsv.rule_set_id into v_set
    from erp.rule_set_version rsv
   where rsv.tenant_id = v_tenant and rsv.id = p_rule_set_version_id
     and rsv.status = 'draft';

  if not found then
    raise exception 'ERPWARE_RULE_SET_VERSION_NOT_DRAFT: % is not a draft version',
      p_rule_set_version_id using errcode = '23514';
  end if;

  select count(*), string_agg(format('  [%s] %s: %s — %s', l.severity, l.rule_code,
                                     l.finding, l.detail), E'\n')
    into v_count, v_errors
    from erp.lint_rule_set_version(p_rule_set_version_id) l
   where l.severity = 'error';

  if v_count > 0 then
    raise exception E'ERPWARE_RULE_SET_INVALID: % error(s)\n%', v_count, v_errors
      using errcode = '23514';
  end if;

  update erp.rule_set_version rsv
     set effective_to = case when rsv.effective_from < v_from
                             then v_from else rsv.effective_to end,
         status = case when rsv.effective_from >= v_from
                       then 'superseded'::erp.config_version_status
                       else rsv.status end,
         updated_at = now()
   where rsv.tenant_id = v_tenant
     and rsv.rule_set_id = v_set
     and rsv.status = 'active'
     and (rsv.effective_to is null or rsv.effective_to > v_from);

  update erp.rule_set_version
     set status = 'active', effective_from = v_from, updated_at = now()
   where tenant_id = v_tenant and id = p_rule_set_version_id;
end;
$$;

create or replace function erp.activate_state_machine_version(
  p_version_id     uuid,
  p_effective_from date default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_machine uuid;
  v_from    date := coalesce(p_effective_from, current_date);
  v_count   integer;
  v_errors  text;
begin
  select smv.state_machine_id into v_machine
    from erp.state_machine_version smv
   where smv.tenant_id = v_tenant and smv.id = p_version_id and smv.status = 'draft';

  if not found then
    raise exception 'ERPWARE_STATE_MACHINE_VERSION_NOT_DRAFT: %', p_version_id
      using errcode = '23514';
  end if;

  select count(*), string_agg(format('  [%s] %s: %s — %s',
                                     v.severity, coalesce(v.state_code, '(machine)'),
                                     v.finding, v.detail), E'\n')
    into v_count, v_errors
    from erp.validate_state_machine_version(p_version_id) v
   where v.severity = 'error';

  if v_count > 0 then
    raise exception E'ERPWARE_STATE_MACHINE_INVALID: % error(s)\n%', v_count, v_errors
      using errcode = '23514';
  end if;

  update erp.state_machine_version smv
     set effective_to = case when smv.effective_from < v_from
                             then v_from else smv.effective_to end,
         status = case when smv.effective_from >= v_from
                       then 'superseded'::erp.config_version_status
                       else smv.status end,
         updated_at = now()
   where smv.tenant_id = v_tenant
     and smv.state_machine_id = v_machine
     and smv.status = 'active'
     and (smv.effective_to is null or smv.effective_to > v_from);

  update erp.state_machine_version
     set status = 'active', effective_from = v_from, updated_at = now()
   where tenant_id = v_tenant and id = p_version_id;
end;
$$;

-- Approval chains had the same shape inline in the promotion applier. Giving
-- them a named activation function puts all four on one implementation.
create or replace function erp.activate_approval_chain_version(
  p_version_id     uuid,
  p_effective_from date default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_chain  uuid;
  v_from   date := coalesce(p_effective_from, current_date);
  v_steps  integer;
begin
  select acv.approval_chain_id into v_chain
    from erp.approval_chain_version acv
   where acv.tenant_id = v_tenant and acv.id = p_version_id and acv.status = 'draft';

  if not found then
    raise exception 'ERPWARE_APPROVAL_CHAIN_VERSION_NOT_DRAFT: %', p_version_id
      using errcode = '23514';
  end if;

  -- A chain with no steps approves everything instantly, which is almost never
  -- what someone configuring an approval chain intends.
  select count(*) into v_steps from erp.approval_step s
   where s.tenant_id = v_tenant and s.approval_chain_version_id = p_version_id;

  if v_steps = 0 then
    raise exception
      'ERPWARE_APPROVAL_CHAIN_EMPTY: this chain has no steps, so it would approve everything unchecked'
      using errcode = '23514';
  end if;

  update erp.approval_chain_version acv
     set effective_to = case when acv.effective_from < v_from
                             then v_from else acv.effective_to end,
         status = case when acv.effective_from >= v_from
                       then 'superseded'::erp.config_version_status
                       else acv.status end,
         updated_at = now()
   where acv.tenant_id = v_tenant
     and acv.approval_chain_id = v_chain
     and acv.status = 'active'
     and (acv.effective_to is null or acv.effective_to > v_from);

  update erp.approval_chain_version
     set status = 'active', effective_from = v_from, updated_at = now()
   where tenant_id = v_tenant and id = p_version_id;
end;
$$;
