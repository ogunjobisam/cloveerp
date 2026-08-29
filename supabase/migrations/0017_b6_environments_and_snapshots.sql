-- =============================================================================
-- ERPWare — B6 (part 1/2): environments, the configuration manifest, snapshots,
-- the live-edit guard and kill switches
-- Spec 3.11:
--   "Rollback restores a versioned snapshot in one action, with blast-radius
--    preview; a kill switch disables an individual rule, job or command class
--    immediately"
--   "Environments cannot silently diverge: direct edits to live configuration
--    are not permitted, and drift is detected continuously"
--
-- Everything here rests on one idea: the tenant's entire configuration can be
-- rendered as a canonical list of (kind, key, content) with a hash per entry.
-- Once that exists, four separate requirements become the same mechanism —
--
--   a snapshot        is a stored manifest
--   a diff            is two manifests compared by hash
--   drift detection   is two manifests from different environments compared
--   tenant export     is a manifest plus the transaction data (spec 2.5)
--
-- — and the alternative is four bespoke implementations that disagree about
-- what "the configuration" means.
--
-- The live-edit prohibition is enforced rather than documented. A guard on
-- every configuration table refuses writes in an environment declared live
-- unless a promotion is in progress. Without that, "promotion is the only
-- route" is a policy that holds until the first urgent Friday afternoon.
-- =============================================================================

create type erp.environment_kind as enum (
  'development', 'test', 'staging', 'production', 'training', 'sandbox'
);

create table erp.environment (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references erp.tenant(id) on delete cascade,
  code        text not null,
  name        text not null,
  kind        erp.environment_kind not null,
  -- Live environments refuse direct configuration edits.
  is_live     boolean not null default false,
  -- Exactly one environment per tenant IS this database. The others are known
  -- to us only through the manifests they publish.
  is_self     boolean not null default false,
  description text,
  status      erp.record_status not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

create unique index environment_one_self
  on erp.environment (tenant_id) where is_self;

comment on table erp.environment is
  'The environments a tenant runs. One is this database; the rest are known '
  'through the configuration manifests they publish, which is what makes drift '
  'between them detectable rather than a surprise at go-live.';

-- -----------------------------------------------------------------------------
-- The configuration manifest
--
-- One canonical rendering of everything a tenant has configured. Read-only, and
-- the single definition of "the configuration" for snapshots, diffs, drift and
-- export alike.
-- -----------------------------------------------------------------------------

create or replace function erp.configuration_manifest(p_kinds text[] default null)
returns table (
  object_kind  text,
  object_key   text,
  content      jsonb,
  content_hash text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  entries as (
    -- Configuration values in force
    select 'config'::text as object_kind,
           co.config_type_code || '|' || coalesce(co.code, '') || '|' ||
             coalesce(e.code, '-') || '|' || coalesce(s.code, '-') as object_key,
           jsonb_build_object(
             'config_type', co.config_type_code,
             'code', co.code,
             'entity', e.code,
             'site', s.code,
             'value', cv.value,
             'effective_from', cv.effective_from,
             'effective_to', cv.effective_to,
             'version', cv.version) as content
      from t
      join erp.config_object co on co.tenant_id = t.tenant_id and co.status = 'active'
      join erp.config_version cv
        on cv.tenant_id = co.tenant_id and cv.config_object_id = co.id
       and cv.status = 'active'
      left join erp.entity e on e.id = co.entity_id
      left join erp.site s   on s.id = co.site_id

    union all

    -- Rule sets, with the rules of the version in force
    select 'rule_set',
           rs.decision_point_code || '|' || rs.code,
           jsonb_build_object(
             'decision_point', rs.decision_point_code,
             'code', rs.code,
             'name', rs.name,
             'entity', e.code,
             'site', s.code,
             'version', rsv.version,
             'effective_from', rsv.effective_from,
             'effective_to', rsv.effective_to,
             'rules', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'seq', r.seq, 'code', r.code, 'name', r.name,
                        'condition', r.condition, 'outcome', r.outcome,
                        'stop_on_match', r.stop_on_match, 'is_active', r.is_active)
                      order by r.seq)
                 from erp.rule r
                where r.tenant_id = rsv.tenant_id
                  and r.rule_set_version_id = rsv.id), '[]'::jsonb))
      from t
      join erp.rule_set rs on rs.tenant_id = t.tenant_id and rs.status = 'active'
      join erp.rule_set_version rsv
        on rsv.tenant_id = rs.tenant_id and rsv.rule_set_id = rs.id and rsv.status = 'active'
      left join erp.entity e on e.id = rs.entity_id
      left join erp.site s   on s.id = rs.site_id

    union all

    -- State machines, with their states and transitions
    select 'state_machine',
           sm.code,
           jsonb_build_object(
             'code', sm.code,
             'object_type', sm.object_type,
             'name', sm.name,
             'entity', e.code,
             'site', s.code,
             'version', smv.version,
             'effective_from', smv.effective_from,
             'states', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'code', st.code, 'name', st.name,
                        'is_initial', st.is_initial, 'is_terminal', st.is_terminal,
                        'is_committed', st.is_committed, 'sort_order', st.sort_order,
                        'on_enter', st.on_enter, 'on_exit', st.on_exit)
                      order by st.code)
                 from erp.state st
                where st.tenant_id = smv.tenant_id
                  and st.state_machine_version_id = smv.id), '[]'::jsonb),
             'transitions', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'code', tr.code, 'name', tr.name,
                        'from', fs.code, 'to', ts.code,
                        'guard', tr.guard, 'effects', tr.effects,
                        'required_permission', tr.required_permission,
                        'is_automatic', tr.is_automatic, 'sort_order', tr.sort_order)
                      order by tr.code)
                 from erp.transition tr
                 join erp.state fs on fs.id = tr.from_state_id
                 join erp.state ts on ts.id = tr.to_state_id
                where tr.tenant_id = smv.tenant_id
                  and tr.state_machine_version_id = smv.id), '[]'::jsonb))
      from t
      join erp.state_machine sm on sm.tenant_id = t.tenant_id and sm.status = 'active'
      join erp.state_machine_version smv
        on smv.tenant_id = sm.tenant_id and smv.state_machine_id = sm.id and smv.status = 'active'
      left join erp.entity e on e.id = sm.entity_id
      left join erp.site s   on s.id = sm.site_id

    union all

    -- Approval chains, with their steps
    select 'approval_chain',
           ac.code,
           jsonb_build_object(
             'code', ac.code,
             'object_type', ac.object_type,
             'name', ac.name,
             'applies_when', ac.applies_when,
             'priority', ac.priority,
             'entity', e.code,
             'site', s.code,
             'version', acv.version,
             'effective_from', acv.effective_from,
             'material_fields', to_jsonb(acv.material_fields),
             'value_field', acv.value_field,
             'tolerance_pct', acv.tolerance_pct,
             'tolerance_absolute', acv.tolerance_absolute,
             'steps', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'seq', st.seq, 'code', st.code, 'name', st.name,
                        'approver_kind', st.approver_kind,
                        'role', r.code, 'user', u.email,
                        'min_approvals', st.min_approvals,
                        'condition', st.condition,
                        'escalate_after', st.escalate_after,
                        'allow_delegation', st.allow_delegation)
                      order by st.seq, st.code)
                 from erp.approval_step st
                 left join erp.role r on r.id = st.role_id
                 left join erp.app_user u on u.id = st.app_user_id
                where st.tenant_id = acv.tenant_id
                  and st.approval_chain_version_id = acv.id), '[]'::jsonb))
      from t
      join erp.approval_chain ac on ac.tenant_id = t.tenant_id and ac.status = 'active'
      join erp.approval_chain_version acv
        on acv.tenant_id = ac.tenant_id and acv.approval_chain_id = ac.id and acv.status = 'active'
      left join erp.entity e on e.id = ac.entity_id
      left join erp.site s   on s.id = ac.site_id

    union all

    -- Terminology overrides
    select 'terminology',
           ro.key || '|' || ro.locale || '|' || coalesce(e.code, '-'),
           jsonb_build_object('key', ro.key, 'locale', ro.locale,
                              'value', ro.value, 'entity', e.code)
      from t
      join erp.resource_override ro on ro.tenant_id = t.tenant_id and ro.status = 'active'
      left join erp.entity e on e.id = ro.entity_id

    union all

    -- Legislation bindings
    select 'legislation_binding',
           e.code || '|' || b.pack_code,
           jsonb_build_object('entity', e.code, 'pack', b.pack_code,
                              'pack_version', b.pack_version,
                              'effective_from', b.effective_from,
                              'effective_to', b.effective_to)
      from t
      join erp.entity_legislation_binding b on b.tenant_id = t.tenant_id and b.status = 'active'
      join erp.entity e on e.id = b.entity_id

    union all

    -- Event subscriptions
    select 'event_subscription',
           es.consumer_code || '|' || es.event_pattern,
           jsonb_build_object('consumer', es.consumer_code, 'pattern', es.event_pattern,
                              'module', es.module_code, 'max_attempts', es.max_attempts)
      from t
      join erp.event_subscription es on es.tenant_id = t.tenant_id and es.status = 'active'

    union all

    -- Roles and their permission grants: who may do what is configuration too
    select 'role',
           r.code,
           jsonb_build_object('code', r.code, 'name', r.name, 'name_key', r.name_key,
                              'from_template', r.from_template,
                              'permissions', coalesce((
                                select jsonb_agg(jsonb_build_object(
                                         'permission', rp.permission_code,
                                         'data_classes', to_jsonb(rp.data_classes))
                                       order by rp.permission_code)
                                  from erp.role_permission rp
                                 where rp.tenant_id = r.tenant_id and rp.role_id = r.id), '[]'::jsonb))
      from t
      join erp.role r on r.tenant_id = t.tenant_id and r.status = 'active'
  )
  select en.object_kind, en.object_key, en.content, md5(en.content::text)
    from entries en
   where p_kinds is null or en.object_kind = any (p_kinds)
   order by 1, 2
$$;

comment on function erp.configuration_manifest is
  'The canonical rendering of everything a tenant has configured, one row per '
  'object with a content hash. Snapshots, diffs, drift detection and tenant '
  'export are all this function plus a comparison.';

-- -----------------------------------------------------------------------------
-- Snapshots
-- -----------------------------------------------------------------------------

create table erp.config_snapshot (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  reason         text,
  environment_id uuid,
  taken_at       timestamptz not null default now(),
  taken_by       uuid,
  entry_count    integer not null default 0,
  -- The manifest at the moment it was taken.
  content        jsonb not null,
  content_hash   text not null,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, environment_id)
    references erp.environment (tenant_id, id) on delete set null
);

create index on erp.config_snapshot (tenant_id, taken_at desc);

create or replace function erp.take_config_snapshot(
  p_reason text default null, p_code text default null)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_content jsonb;
  v_count   integer;
  v_id      uuid;
  v_code    text := coalesce(p_code,
                     'snap-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US'));
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', m.object_kind, 'key', m.object_key,
           'content', m.content, 'hash', m.content_hash)
           order by m.object_kind, m.object_key), '[]'::jsonb),
         count(*)
    into v_content, v_count
    from erp.configuration_manifest() m;

  insert into erp.config_snapshot (
    tenant_id, code, reason, environment_id, taken_by, entry_count, content, content_hash)
  values (
    v_tenant, v_code, p_reason,
    (select e.id from erp.environment e where e.tenant_id = v_tenant and e.is_self),
    erp.current_principal_id(), v_count, v_content, md5(v_content::text))
  returning id into v_id;

  return v_id;
end;
$$;

-- Spec 3.11: rollback carries a blast-radius preview. What a restore would
-- change, before it changes it.
create or replace function erp.blast_radius(p_snapshot_id uuid)
returns table (object_kind text, object_key text, change text,
               current_content jsonb, snapshot_content jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  with snap as (
    select e.value ->> 'kind' as kind,
           e.value ->> 'key'  as key,
           e.value -> 'content' as content,
           e.value ->> 'hash' as hash
      from erp.config_snapshot s
      cross join lateral jsonb_array_elements(s.content) e
     where s.tenant_id = erp.require_tenant_id()
       and s.id = p_snapshot_id
  ),
  live as (select * from erp.configuration_manifest())
  select coalesce(l.object_kind, s.kind),
         coalesce(l.object_key, s.key),
         case
           when s.key is null then 'would be removed'
           when l.object_key is null then 'would be restored'
           else 'would be reverted'
         end,
         l.content, s.content
    from live l
    full outer join snap s
      on s.kind = l.object_kind and s.key = l.object_key
   where l.content_hash is distinct from s.hash
   order by 1, 2
$$;

comment on function erp.blast_radius(uuid) is
  'What restoring a snapshot would change, before it changes it. "Would be '
  'removed" is the row that matters: configuration created since the snapshot '
  'disappears, and that is rarely what someone rolling back has in mind.';

-- -----------------------------------------------------------------------------
-- Kill switches
--
-- Spec 3.11: "a kill switch disables an individual rule, job or command class
-- immediately". Immediately means not through promotion — this is the one
-- deliberate exception to that rule, because the whole point is to stop
-- something that is actively causing harm.
-- -----------------------------------------------------------------------------

create type erp.kill_target_kind as enum (
  'rule_set', 'rule', 'state_machine', 'approval_chain',
  'job', 'command_class', 'integration', 'event_consumer'
);

create table erp.kill_switch (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  target_kind    erp.kill_target_kind not null,
  target_key     text not null,
  is_active      boolean not null default true,
  reason         text not null,
  activated_by   uuid,
  activated_at   timestamptz not null default now(),
  deactivated_by uuid,
  deactivated_at timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, target_kind, target_key)
);

create index on erp.kill_switch (tenant_id, target_kind) where is_active;

create or replace function erp.is_killed(p_kind erp.kill_target_kind, p_key text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1 from erp.kill_switch k
     where k.tenant_id = erp.current_tenant_id()
       and k.target_kind = p_kind
       and k.target_key = p_key
       and k.is_active)
$$;

create or replace function erp.set_kill_switch(
  p_kind erp.kill_target_kind, p_key text, p_reason text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'kill_switch', null);

  insert into erp.kill_switch (tenant_id, target_kind, target_key, reason, activated_by)
  values (v_tenant, p_kind, p_key, p_reason, erp.current_principal_id())
  on conflict (tenant_id, target_kind, target_key) do update
    set is_active = true, reason = excluded.reason,
        activated_by = excluded.activated_by, activated_at = now(),
        deactivated_by = null, deactivated_at = null, updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.clear_kill_switch(
  p_kind erp.kill_target_kind, p_key text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'kill_switch', null);

  update erp.kill_switch
     set is_active = false, deactivated_by = erp.current_principal_id(),
         deactivated_at = now(), updated_at = now()
   where tenant_id = erp.require_tenant_id()
     and target_kind = p_kind and target_key = p_key;
end;
$$;

-- -----------------------------------------------------------------------------
-- The live-edit guard
--
-- Spec 3.11: "direct edits to live configuration are not permitted; promotion
-- is the only route". A policy nobody can breach beats a policy everybody
-- agrees with.
-- -----------------------------------------------------------------------------

create or replace function erp.guard_live_configuration()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_live   boolean;
begin
  v_tenant := coalesce(new.tenant_id, old.tenant_id);

  -- A promotion is in progress: this write IS the supported route.
  if nullif(current_setting('erp.promotion_id', true), '') is not null then
    return coalesce(new, old);
  end if;

  -- A tenant purge takes everything, configuration included.
  if nullif(current_setting('erp.purge_tenant_id', true), '')::uuid = v_tenant then
    return coalesce(new, old);
  end if;

  select e.is_live into v_live
    from erp.environment e
   where e.tenant_id = v_tenant and e.is_self;

  -- Until a tenant declares this environment live, it is being built. The
  -- guard would otherwise make onboarding impossible.
  if not coalesce(v_live, false) then
    return coalesce(new, old);
  end if;

  raise exception
    'ERPWARE_LIVE_CONFIG_EDIT: % may not be changed directly in a live environment; promote a change set instead',
    tg_table_name
    using errcode = '42501',
          hint = 'erp.promote_change_set() is the supported route. For an emergency, erp.set_kill_switch() disables a target without editing it.';
end;
$$;

create or replace function erp.apply_live_config_guards()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tables text[] := array[
    'config_object', 'config_version',
    'rule_set', 'rule_set_version', 'rule',
    'state_machine', 'state_machine_version', 'state', 'transition',
    'approval_chain', 'approval_chain_version', 'approval_step',
    'resource_override', 'entity_legislation_binding', 'event_subscription',
    'role', 'role_permission'
  ];
  t       text;
  v_count integer := 0;
begin
  foreach t in array v_tables loop
    execute format('drop trigger if exists t_%s_live_guard on erp.%I', t, t);
    execute format(
      'create trigger t_%s_live_guard before insert or update or delete on erp.%I
         for each row execute function erp.guard_live_configuration()', t, t);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

select erp.apply_live_config_guards();

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
