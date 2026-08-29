-- =============================================================================
-- ERPWare — B4 (part 1/2): the state machine engine
-- Spec 3.6:
--   "Document and object lifecycles are defined as configuration: states,
--    permitted transitions, guards, required roles, side effects"
--   "Transition validation prevents unreachable states, orphaned states and
--    undeclared transitions — the class of defect that produces blind spots in
--    hand-coded status logic"
--   "State machines are versioned; in-flight documents complete under the
--    definition they started with"
--
-- The middle clause names a specific failure, so it is worth being precise
-- about how each part of it is prevented:
--
--   undeclared transitions   are impossible by construction. There is no
--                            "set the status field" operation. State changes
--                            only through erp.perform_transition(), which
--                            requires a declared transition whose from-state
--                            matches where the object actually is. A status
--                            column that anyone can UPDATE is exactly the blind
--                            spot the spec is describing, so there isn't one.
--
--   unreachable states       are found by walking the graph forward from the
--                            initial state. A state nothing can reach is dead
--                            configuration that reads as though it works.
--
--   orphaned states          are found by walking backwards from the terminal
--                            states. A state with no route onward is a document
--                            that can enter a condition it can never leave —
--                            the worst kind, because it looks fine until a real
--                            document is stuck in it.
--
-- Both walks run before a version can be put in force, not as a report someone
-- might run.
--
-- The last clause is why object_state pins the version it started under. A
-- lifecycle change must not strand or silently re-route documents already
-- moving through the old one.
-- =============================================================================

create table erp.state_machine (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  -- What this lifecycle governs, e.g. 'document.purchase_order'.
  object_type  text not null,
  name         text,
  description  text,
  entity_id    uuid,
  site_id      uuid,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)
    references erp.site (tenant_id, id) on delete cascade,
  constraint state_machine_site_needs_entity
    check (site_id is null or entity_id is not null)
);

create index on erp.state_machine (tenant_id, object_type) where status = 'active';

create table erp.state_machine_version (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  state_machine_id uuid not null,
  version          integer not null check (version >= 1),
  status           erp.config_version_status not null default 'draft',
  effective_from   date not null default current_date,
  effective_to     date,
  note             text,
  change_set_id    uuid,
  approved_by      uuid,
  approved_at      timestamptz,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, state_machine_id, version),
  foreign key (tenant_id, state_machine_id)
    references erp.state_machine (tenant_id, id) on delete cascade,
  constraint state_machine_version_range
    check (effective_to is null or effective_to > effective_from),
  constraint state_machine_version_no_overlap
    exclude using gist (
      tenant_id with =,
      state_machine_id with =,
      daterange(effective_from, effective_to, '[)') with &&
    ) where (status = 'active')
);

create table erp.state (
  id                       uuid not null default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant(id) on delete cascade,
  state_machine_version_id uuid not null,
  code                     text not null,
  name_key                 text,
  name                     text,
  description              text,
  is_initial               boolean not null default false,
  is_terminal              boolean not null default false,
  -- Marks states where the object is considered committed, for reporting and
  -- for re-approval decisions.
  is_committed             boolean not null default false,
  sort_order               integer not null default 100,
  -- Declarative side effects, interpreted by the module that owns the object.
  on_enter                 jsonb not null default '[]'::jsonb,
  on_exit                  jsonb not null default '[]'::jsonb,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, state_machine_version_id, code),
  foreign key (tenant_id, state_machine_version_id)
    references erp.state_machine_version (tenant_id, id) on delete cascade,
  constraint state_not_initial_and_terminal
    check (not (is_initial and is_terminal))
);

-- Exactly one entry point. Two initial states means "where does a new document
-- start?" has no answer.
create unique index state_one_initial
  on erp.state (tenant_id, state_machine_version_id) where is_initial;

create table erp.transition (
  id                       uuid not null default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant(id) on delete cascade,
  state_machine_version_id uuid not null,
  code                     text not null,
  name_key                 text,
  name                     text,
  description              text,
  from_state_id            uuid not null,
  to_state_id              uuid not null,
  -- A declarative guard over the facts supplied at transition time, evaluated
  -- by the B3 interpreter. Rules about when a document may move are
  -- configuration, not code.
  guard                    jsonb not null default 'true'::jsonb,
  -- Authorisation for the move, checked against the B1 permission model.
  required_permission      text references erp_ref.permission(code),
  -- Declarative effects, e.g. [{"emit_event": "order.approved"},
  --                            {"require_approval": {"chain": "..."}}]
  effects                  jsonb not null default '[]'::jsonb,
  -- Transitions the system may take on its own, versus ones a person drives.
  is_automatic             boolean not null default false,
  sort_order               integer not null default 100,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, state_machine_version_id, code),
  foreign key (tenant_id, state_machine_version_id)
    references erp.state_machine_version (tenant_id, id) on delete cascade,
  -- Composite, so a transition cannot reference another tenant's states. That
  -- they also belong to the SAME VERSION is a separate check (t_transition_states
  -- below) — a foreign key can carry the tenant through but not the version.
  foreign key (tenant_id, from_state_id)
    references erp.state (tenant_id, id) on delete cascade,
  foreign key (tenant_id, to_state_id)
    references erp.state (tenant_id, id) on delete cascade,
  constraint transition_not_self check (from_state_id <> to_state_id)
);

create index on erp.transition (tenant_id, state_machine_version_id, from_state_id);

-- A version that has been in force is history: documents moved through it and
-- their trail must keep meaning what it meant.
create or replace function erp.protect_active_state_machine()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status erp.config_version_status;
  v_version uuid := coalesce(new.state_machine_version_id, old.state_machine_version_id);
begin
  select smv.status into v_status
    from erp.state_machine_version smv where smv.id = v_version;

  if v_status in ('active', 'superseded') then
    raise exception
      'ERPWARE_STATE_MACHINE_IN_FORCE: this version has been in force and cannot be changed; create a new version'
      using errcode = '42501';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger t_state_protect
  before insert or update or delete on erp.state
  for each row execute function erp.protect_active_state_machine();

create trigger t_transition_protect
  before insert or update or delete on erp.transition
  for each row execute function erp.protect_active_state_machine();

-- A transition must join two states of its own version. Without this a
-- transition could point at a state belonging to a different version of the
-- same lifecycle, and the graph walks would silently traverse between them.
create or replace function erp.check_transition_states()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_from uuid;
  v_to   uuid;
begin
  select s.state_machine_version_id into v_from from erp.state s where s.id = new.from_state_id;
  select s.state_machine_version_id into v_to   from erp.state s where s.id = new.to_state_id;

  if v_from is distinct from new.state_machine_version_id
     or v_to is distinct from new.state_machine_version_id then
    raise exception
      'ERPWARE_TRANSITION_CROSSES_VERSIONS: a transition must join two states of its own lifecycle version'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger t_transition_states
  before insert or update on erp.transition
  for each row execute function erp.check_transition_states();

-- -----------------------------------------------------------------------------
-- Validation — the reason this engine exists
-- -----------------------------------------------------------------------------

create or replace function erp.validate_state_machine_version(p_version_id uuid)
returns table (severity text, state_code text, finding text, detail text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_initial uuid;
  v_states  integer;
  v_terminals integer;
begin
  select count(*) into v_states
    from erp.state s
   where s.tenant_id = v_tenant and s.state_machine_version_id = p_version_id;

  if v_states = 0 then
    severity := 'error'; state_code := null;
    finding := 'the lifecycle has no states';
    detail := 'a state machine with no states cannot govern anything';
    return next;
    return;
  end if;

  select s.id into v_initial
    from erp.state s
   where s.tenant_id = v_tenant and s.state_machine_version_id = p_version_id
     and s.is_initial;

  if v_initial is null then
    severity := 'error'; state_code := null;
    finding := 'no initial state';
    detail := 'a new object would have nowhere to start';
    return next;
    return;
  end if;

  select count(*) into v_terminals
    from erp.state s
   where s.tenant_id = v_tenant and s.state_machine_version_id = p_version_id
     and s.is_terminal;

  if v_terminals = 0 then
    severity := 'error'; state_code := null;
    finding := 'no terminal state';
    detail := 'nothing governed by this lifecycle could ever be finished';
    return next;
  end if;

  -- --- Unreachable: walk forward from the initial state -----------------------
  return query
  with recursive reachable as (
    select s.id
      from erp.state s
     where s.tenant_id = v_tenant
       and s.state_machine_version_id = p_version_id
       and s.is_initial
    union
    select t.to_state_id
      from erp.transition t
      join reachable r on r.id = t.from_state_id
     where t.tenant_id = v_tenant
       and t.state_machine_version_id = p_version_id
  )
  select 'error', s.code,
         'state is unreachable',
         'no sequence of transitions leads here from the initial state, so this state is dead configuration'
    from erp.state s
   where s.tenant_id = v_tenant
     and s.state_machine_version_id = p_version_id
     and s.id not in (select id from reachable);

  -- --- Orphaned: walk backwards from the terminal states ----------------------
  -- A state that cannot reach an end is a document that can enter a condition
  -- it can never leave.
  return query
  with recursive can_finish as (
    select s.id
      from erp.state s
     where s.tenant_id = v_tenant
       and s.state_machine_version_id = p_version_id
       and s.is_terminal
    union
    select t.from_state_id
      from erp.transition t
      join can_finish c on c.id = t.to_state_id
     where t.tenant_id = v_tenant
       and t.state_machine_version_id = p_version_id
  )
  select 'error', s.code,
         'state cannot reach a terminal state',
         'an object entering this state could never be completed or closed'
    from erp.state s
   where s.tenant_id = v_tenant
     and s.state_machine_version_id = p_version_id
     and s.id not in (select id from can_finish);

  -- --- Terminal states with a way out are not terminal ------------------------
  return query
  select 'error', s.code,
         'terminal state has outgoing transitions',
         'a state declared terminal must be an end; either clear the flag or remove the transitions'
    from erp.state s
   where s.tenant_id = v_tenant
     and s.state_machine_version_id = p_version_id
     and s.is_terminal
     and exists (select 1 from erp.transition t
                  where t.tenant_id = v_tenant
                    and t.from_state_id = s.id);

  -- --- Guards that cannot be evaluated ---------------------------------------
  -- Probed against empty facts: the interpreter is pure, so a structural fault
  -- (unknown operator, malformed var) shows up regardless of the data.
  declare
    r      record;
    v_junk jsonb;
  begin
    for r in
      select t.code, t.guard from erp.transition t
       where t.tenant_id = v_tenant and t.state_machine_version_id = p_version_id
    loop
      begin
        v_junk := erp.jsonlogic(r.guard, '{}'::jsonb);
      exception when others then
        severity := 'error'; state_code := r.code;
        finding := 'transition guard cannot be evaluated';
        detail := sqlerrm;
        return next;
      end;
    end loop;
  end;

  -- --- Two transitions between the same pair, both automatic ------------------
  -- The system would have no basis for choosing.
  return query
  select 'warning', s.code,
         'more than one automatic transition leaves this state',
         format('%s automatic transitions from here; the engine has no basis to choose between them',
                count(*)::text)
    from erp.transition t
    join erp.state s on s.id = t.from_state_id
   where t.tenant_id = v_tenant
     and t.state_machine_version_id = p_version_id
     and t.is_automatic
   group by s.code
  having count(*) > 1;

  return;
end;
$$;

comment on function erp.validate_state_machine_version(uuid) is
  'Walks the lifecycle graph forwards from the initial state and backwards from '
  'the terminal states. Catches dead configuration and, more importantly, '
  'states an object could enter and never leave.';

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
     set effective_to = v_from,
         status = case when smv.effective_from >= v_from then 'superseded' else smv.status end,
         updated_at = now()
   where smv.tenant_id = v_tenant
     and smv.state_machine_id = v_machine
     and smv.status = 'active'
     and (smv.effective_to is null or smv.effective_to > v_from);

  update erp.state_machine_version smv
     set status = 'superseded', updated_at = now()
   where smv.tenant_id = v_tenant
     and smv.state_machine_id = v_machine
     and smv.status = 'active'
     and smv.effective_to is not null
     and smv.effective_to <= smv.effective_from;

  update erp.state_machine_version
     set status = 'active', effective_from = v_from, updated_at = now()
   where tenant_id = v_tenant and id = p_version_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Instances
-- -----------------------------------------------------------------------------

create table erp.object_state (
  id                       uuid not null default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant(id) on delete cascade,
  object_type              text not null,
  object_id                uuid not null,
  entity_id                uuid,
  site_id                  uuid,
  -- Pinned at the start. Spec 3.6: an in-flight document completes under the
  -- definition it started with, so a lifecycle change cannot strand it.
  state_machine_version_id uuid not null,
  current_state_id         uuid not null,
  entered_at               timestamptz not null default now(),
  entered_by               uuid,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  primary key (id),
  unique (tenant_id, object_type, object_id),
  foreign key (tenant_id, state_machine_version_id)
    references erp.state_machine_version (tenant_id, id) on delete restrict,
  foreign key (tenant_id, current_state_id)
    references erp.state (tenant_id, id) on delete restrict
);

create index on erp.object_state (tenant_id, object_type, current_state_id);

create table erp.state_transition_log (
  id             bigint generated always as identity primary key,
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  occurred_at    timestamptz not null default clock_timestamp(),
  object_type    text not null,
  object_id      uuid not null,
  transition_id  uuid,
  transition_code text,
  from_state_code text,
  to_state_code  text not null,
  actor_id       uuid,
  reason         text,
  guard_data     jsonb,
  correlation_id uuid
);

create index on erp.state_transition_log (tenant_id, object_type, object_id, occurred_at);

-- -----------------------------------------------------------------------------
-- Driving an object through its lifecycle
-- -----------------------------------------------------------------------------

create or replace function erp.start_lifecycle(
  p_object_type text,
  p_object_id   uuid,
  p_entity_id   uuid default null,
  p_site_id     uuid default null,
  p_on          date default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_on      date := coalesce(p_on, current_date);
  v_version uuid;
  v_state   uuid;
  v_code    text;
begin
  select smv.id into v_version
    from erp.state_machine sm
    join erp.state_machine_version smv
      on smv.tenant_id = sm.tenant_id
     and smv.state_machine_id = sm.id
     and smv.status = 'active'
     and daterange(smv.effective_from, smv.effective_to, '[)') @> v_on
   where sm.tenant_id = v_tenant
     and sm.object_type = p_object_type
     and sm.status = 'active'
     and (sm.site_id   is null or sm.site_id   = p_site_id)
     and (sm.entity_id is null or sm.entity_id = p_entity_id)
   order by (sm.site_id is not null) desc, (sm.entity_id is not null) desc
   limit 1;

  if v_version is null then
    raise exception 'ERPWARE_NO_LIFECYCLE: no state machine in force for % on %',
      p_object_type, v_on using errcode = '23503';
  end if;

  select s.id, s.code into v_state, v_code
    from erp.state s
   where s.tenant_id = v_tenant
     and s.state_machine_version_id = v_version
     and s.is_initial;

  insert into erp.object_state (
    tenant_id, object_type, object_id, entity_id, site_id,
    state_machine_version_id, current_state_id, entered_by)
  values (
    v_tenant, p_object_type, p_object_id, p_entity_id, p_site_id,
    v_version, v_state, erp.current_principal_id());

  insert into erp.state_transition_log (
    tenant_id, object_type, object_id, to_state_code, actor_id, reason, correlation_id)
  values (
    v_tenant, p_object_type, p_object_id, v_code, erp.current_principal_id(),
    'lifecycle started', erp.current_correlation_id());

  return v_code;
end;
$$;

-- The only way an object's state changes. There is deliberately no setter.
create or replace function erp.perform_transition(
  p_object_type     text,
  p_object_id       uuid,
  p_transition_code text,
  p_data            jsonb default '{}'::jsonb,
  p_reason          text default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_os       erp.object_state%rowtype;
  v_t        erp.transition%rowtype;
  v_from     text;
  v_to       text;
  v_effects  jsonb;
begin
  select * into v_os
    from erp.object_state os
   where os.tenant_id = v_tenant
     and os.object_type = p_object_type
     and os.object_id = p_object_id
   for update;

  if not found then
    raise exception 'ERPWARE_NO_LIFECYCLE_INSTANCE: % % has not started a lifecycle',
      p_object_type, p_object_id using errcode = '23503';
  end if;

  -- The transition must be declared, in the version this object started under,
  -- and must leave from where the object actually is. Those three conditions
  -- together are what makes an undeclared transition impossible.
  select * into v_t
    from erp.transition t
   where t.tenant_id = v_tenant
     and t.state_machine_version_id = v_os.state_machine_version_id
     and t.code = p_transition_code
     and t.from_state_id = v_os.current_state_id;

  if not found then
    select s.code into v_from from erp.state s where s.id = v_os.current_state_id;
    raise exception
      'ERPWARE_TRANSITION_NOT_PERMITTED: % is not a declared transition out of % for %',
      p_transition_code, v_from, p_object_type
      using errcode = '23514',
            hint = 'Declared transitions are visible in erp.available_transitions()';
  end if;

  if not erp.jsonlogic_bool(v_t.guard, p_data) then
    raise exception 'ERPWARE_TRANSITION_GUARD_FAILED: the guard on % did not pass',
      p_transition_code
      using errcode = '23514', detail = p_data::text;
  end if;

  if v_t.required_permission is not null then
    perform erp.authorise(v_t.required_permission, v_os.entity_id, v_os.site_id,
                          null, p_object_type, p_object_id);
  end if;

  select s.code into v_from from erp.state s where s.id = v_t.from_state_id;
  select s.code into v_to   from erp.state s where s.id = v_t.to_state_id;

  update erp.object_state
     set current_state_id = v_t.to_state_id,
         entered_at = now(),
         entered_by = erp.current_principal_id(),
         updated_at = now()
   where id = v_os.id;

  insert into erp.state_transition_log (
    tenant_id, object_type, object_id, transition_id, transition_code,
    from_state_code, to_state_code, actor_id, reason, guard_data, correlation_id)
  values (
    v_tenant, p_object_type, p_object_id, v_t.id, v_t.code,
    v_from, v_to, erp.current_principal_id(), p_reason, p_data,
    erp.current_correlation_id());

  return v_to;
end;
$$;

comment on function erp.perform_transition is
  'The only route by which an object changes state. There is no setter, which '
  'is what removes the hand-coded-status blind spot the specification names: a '
  'move that was never declared cannot be performed.';

-- What a user may do next, for menus and for API discoverability.
create or replace function erp.available_transitions(
  p_object_type text,
  p_object_id   uuid,
  p_data        jsonb default '{}'::jsonb
) returns table (
  transition_code text,
  name            text,
  to_state        text,
  guard_passes    boolean,
  permitted       boolean,
  is_automatic    boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  select t.code, t.name, ts.code,
         erp.jsonlogic_bool(t.guard, p_data),
         t.required_permission is null
           or erp.has_permission(t.required_permission, os.entity_id, os.site_id),
         t.is_automatic
    from erp.object_state os
    join erp.transition t
      on t.tenant_id = os.tenant_id
     and t.state_machine_version_id = os.state_machine_version_id
     and t.from_state_id = os.current_state_id
    join erp.state ts on ts.id = t.to_state_id
   where os.tenant_id = erp.require_tenant_id()
     and os.object_type = p_object_type
     and os.object_id = p_object_id
   order by t.sort_order, t.code
$$;

create or replace function erp.object_current_state(
  p_object_type text, p_object_id uuid)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select s.code
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = erp.require_tenant_id()
     and os.object_type = p_object_type
     and os.object_id = p_object_id
$$;

select erp_meta.register_table('erp', 'state_transition_log', 'tenant_scoped_append_only',
  'Spec 3.6: a document''s state history is complete. History is evidence.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'state_transition_log',
   'Append-only history already carrying actor, reason, from-state and to-state.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
