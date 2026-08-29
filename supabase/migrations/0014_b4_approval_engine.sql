-- =============================================================================
-- ERPWare — B4 (part 2/2): the approval engine
-- Spec 3.7:
--   "One approval engine consumed by every module: chains defined by scope,
--    value band, category and object type; sequential, parallel and conditional
--    steps; delegation, substitution and escalation on ageing"
--   "Re-approval rules on material change, with configurable tolerance"
--   "Complete approval audit, including the version of the object approved"
--
-- "One approval engine consumed by every module" is the load-bearing phrase.
-- Approvals are the single most duplicated mechanism in an ERP — every module
-- grows its own, and each one is subtly different in how it handles a delegated
-- approver or an amendment after sign-off. So this engine knows nothing about
-- purchase orders or journals. It approves an (object_type, object_id,
-- object_version) against a context, and every module hands it the same shape.
--
-- Two design notes worth stating:
--
--   Parallel steps share a sequence number. Steps at seq 10 all run at once;
--   seq 20 begins only when every step at seq 10 is satisfied. That makes
--   "sequential, parallel and conditional" one mechanism rather than three.
--
--   Approval is recorded against an object VERSION, and re-approval is decided
--   by comparing a fingerprint of the material fields. Without that, a document
--   approved at one value can be quietly amended to another and still carry its
--   signature — which is the failure that makes approval controls worthless.
-- =============================================================================

create type erp.approval_status as enum (
  'pending', 'approved', 'rejected', 'cancelled', 'superseded'
);

create type erp.approval_task_status as enum (
  'pending', 'approved', 'rejected', 'delegated', 'escalated', 'skipped', 'cancelled'
);

create type erp.approver_kind as enum ('role', 'user');

-- -----------------------------------------------------------------------------
-- Chains
-- -----------------------------------------------------------------------------

create table erp.approval_chain (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  name         text,
  description  text,
  object_type  text not null,
  entity_id    uuid,
  site_id      uuid,
  -- Spec 3.7: chains are chosen by value band, category and object type. Rather
  -- than columns for each, selection is a declarative condition over the
  -- request context, evaluated by the B3 interpreter — so a tenant whose
  -- routing depends on something the product never anticipated still expresses
  -- it as configuration.
  applies_when jsonb not null default 'true'::jsonb,
  -- Ties are broken by priority, then by scope specificity.
  priority     integer not null default 100,
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
  constraint approval_chain_site_needs_entity
    check (site_id is null or entity_id is not null)
);

create index on erp.approval_chain (tenant_id, object_type, priority)
  where status = 'active';

create table erp.approval_chain_version (
  id                uuid not null default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  approval_chain_id uuid not null,
  version           integer not null check (version >= 1),
  status            erp.config_version_status not null default 'draft',
  effective_from    date not null default current_date,
  effective_to      date,

  -- Re-approval on material change (spec 3.7). Paths into the request context
  -- that, if they change, invalidate an existing approval.
  material_fields   text[] not null default '{}'::text[],
  -- The path holding the value that tolerance applies to.
  value_field       text,
  -- A change within tolerance does not require re-approval. Both may be set;
  -- the change must be within BOTH to be tolerated.
  tolerance_pct     numeric(6,3) check (tolerance_pct is null or tolerance_pct >= 0),
  tolerance_absolute numeric check (tolerance_absolute is null or tolerance_absolute >= 0),

  note              text,
  change_set_id     uuid,
  approved_by       uuid,
  approved_at       timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, approval_chain_id, version),
  foreign key (tenant_id, approval_chain_id)
    references erp.approval_chain (tenant_id, id) on delete cascade,
  constraint approval_chain_version_range
    check (effective_to is null or effective_to > effective_from),
  constraint approval_chain_version_no_overlap
    exclude using gist (
      tenant_id with =,
      approval_chain_id with =,
      daterange(effective_from, effective_to, '[)') with &&
    ) where (status = 'active')
);

create table erp.approval_step (
  id                       uuid not null default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant(id) on delete cascade,
  approval_chain_version_id uuid not null,
  -- Steps sharing a seq run in PARALLEL. The next seq begins only when every
  -- step of the current one is satisfied. One mechanism, both behaviours.
  seq                      integer not null,
  code                     text not null,
  name                     text,
  description              text,
  approver_kind            erp.approver_kind not null,
  role_id                  uuid,
  app_user_id              uuid,
  -- How many of the eligible approvers must approve. Two-of-three sign-off is
  -- a step with min_approvals 2 against a role holding three people.
  min_approvals            smallint not null default 1 check (min_approvals >= 1),
  -- A conditional step: skipped when this does not hold for the context.
  condition                jsonb not null default 'true'::jsonb,
  -- Escalation on ageing.
  escalate_after           interval,
  escalate_to_role_id      uuid,
  escalate_to_user_id      uuid,
  allow_delegation         boolean not null default true,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, approval_chain_version_id, code),
  foreign key (tenant_id, approval_chain_version_id)
    references erp.approval_chain_version (tenant_id, id) on delete cascade,
  foreign key (tenant_id, role_id) references erp.role (tenant_id, id) on delete restrict,
  foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete restrict,
  foreign key (tenant_id, escalate_to_role_id) references erp.role (tenant_id, id) on delete restrict,
  foreign key (tenant_id, escalate_to_user_id) references erp.app_user (tenant_id, id) on delete restrict,
  constraint approval_step_has_approver check (
    (approver_kind = 'role' and role_id is not null and app_user_id is null) or
    (approver_kind = 'user' and app_user_id is not null and role_id is null)),
  constraint approval_step_escalation_target check (
    escalate_after is null
    or escalate_to_role_id is not null or escalate_to_user_id is not null)
);

create index on erp.approval_step (tenant_id, approval_chain_version_id, seq);

-- A chain version that has been in force decided real approvals; changing its
-- steps would rewrite what those approvals meant.
create or replace function erp.protect_active_approval_chain()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status erp.config_version_status;
begin
  select acv.status into v_status
    from erp.approval_chain_version acv
   where acv.id = coalesce(new.approval_chain_version_id, old.approval_chain_version_id);

  if v_status in ('active', 'superseded') then
    raise exception
      'ERPWARE_APPROVAL_CHAIN_IN_FORCE: this chain version has been in force and cannot be changed; create a new version'
      using errcode = '42501';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger t_approval_step_protect
  before insert or update or delete on erp.approval_step
  for each row execute function erp.protect_active_approval_chain();

-- -----------------------------------------------------------------------------
-- Delegation and substitution
-- -----------------------------------------------------------------------------

create table erp.approval_delegation (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  from_user_id   uuid not null,
  to_user_id     uuid not null,
  -- Null means every object type.
  object_type    text,
  valid_from     date not null default current_date,
  valid_to       date,
  reason         text,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, from_user_id)
    references erp.app_user (tenant_id, id) on delete cascade,
  foreign key (tenant_id, to_user_id)
    references erp.app_user (tenant_id, id) on delete cascade,
  constraint approval_delegation_range
    check (valid_to is null or valid_to >= valid_from),
  -- Delegating to yourself is a no-op that looks like cover.
  constraint approval_delegation_not_self check (from_user_id <> to_user_id)
);

create index on erp.approval_delegation (tenant_id, from_user_id, valid_from, valid_to)
  where status = 'active';

-- -----------------------------------------------------------------------------
-- Requests and tasks
-- -----------------------------------------------------------------------------

create table erp.approval_request (
  id                        uuid not null default gen_random_uuid(),
  tenant_id                 uuid not null references erp.tenant(id) on delete cascade,
  object_type               text not null,
  object_id                 uuid not null,
  -- Spec 3.7: the audit records the version of the object approved. An approval
  -- that does not name what it approved is not evidence of anything.
  object_version            integer not null default 1,
  entity_id                 uuid,
  site_id                   uuid,
  approval_chain_id         uuid,
  approval_chain_version_id uuid,
  status                    erp.approval_status not null default 'pending',
  -- The facts the chain was selected on and the steps are conditioned on.
  context                   jsonb not null default '{}'::jsonb,
  -- Digest of the material fields, for detecting a change that invalidates it.
  material_fingerprint      text,
  value_at_approval         numeric,
  current_seq               integer,
  requested_by              uuid,
  requested_at              timestamptz not null default now(),
  decided_at                timestamptz,
  decision_note             text,
  superseded_by             uuid,
  created_at                timestamptz not null default now(),
  created_by                uuid,
  updated_at                timestamptz not null default now(),
  updated_by                uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, approval_chain_version_id)
    references erp.approval_chain_version (tenant_id, id) on delete restrict
);

create index on erp.approval_request (tenant_id, object_type, object_id, status);
create index on erp.approval_request (tenant_id, status) where status = 'pending';

create table erp.approval_task (
  id                  uuid not null default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  approval_request_id uuid not null,
  approval_step_id    uuid,
  step_code           text not null,
  seq                 integer not null,
  assignee_user_id    uuid,
  assignee_role_id    uuid,
  status              erp.approval_task_status not null default 'pending',
  decided_by          uuid,
  decided_at          timestamptz,
  comment             text,
  due_at              timestamptz,
  -- Set when this task exists because another was delegated or escalated to it.
  delegated_from      uuid,
  escalated_from      uuid,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, approval_request_id)
    references erp.approval_request (tenant_id, id) on delete cascade,
  foreign key (tenant_id, assignee_user_id)
    references erp.app_user (tenant_id, id) on delete restrict
);

create index on erp.approval_task (tenant_id, approval_request_id, seq);
create index on erp.approval_task (tenant_id, assignee_user_id, status)
  where status = 'pending';
create index on erp.approval_task (tenant_id, due_at) where status = 'pending';

-- -----------------------------------------------------------------------------
-- Material change detection
-- -----------------------------------------------------------------------------

create or replace function erp.material_fingerprint(
  p_context jsonb, p_material_fields text[], p_value_field text default null)
returns text
language sql
immutable
set search_path = ''
as $$
  -- The value field is excluded: it is compared numerically against a tolerance
  -- rather than by equality, so folding it into the digest would make every
  -- penny a material change.
  select md5(coalesce(
    (select string_agg(f || '=' || coalesce((p_context #> string_to_array(f, '.'))::text, 'null'),
                       E'\n' order by f)
       from unnest(p_material_fields) f
      where p_value_field is null or f <> p_value_field),
    ''))
$$;

create or replace function erp.check_reapproval_required(
  p_object_type text,
  p_object_id   uuid,
  p_context     jsonb
) returns table (required boolean, reason text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_req    erp.approval_request%rowtype;
  v_cv     erp.approval_chain_version%rowtype;
  v_new_fp text;
  v_new_val numeric;
  v_delta  numeric;
  v_pct    numeric;
begin
  select * into v_req
    from erp.approval_request ar
   where ar.tenant_id = v_tenant
     and ar.object_type = p_object_type
     and ar.object_id = p_object_id
     and ar.status = 'approved'
   order by ar.decided_at desc
   limit 1;

  if not found then
    required := true;
    reason := 'no standing approval';
    return next; return;
  end if;

  select * into v_cv from erp.approval_chain_version acv
   where acv.id = v_req.approval_chain_version_id;

  v_new_fp := erp.material_fingerprint(p_context, v_cv.material_fields, v_cv.value_field);

  if v_new_fp is distinct from v_req.material_fingerprint then
    required := true;
    reason := 'a material field changed since approval';
    return next; return;
  end if;

  if v_cv.value_field is not null then
    v_new_val := (p_context #>> string_to_array(v_cv.value_field, '.'))::numeric;

    if v_new_val is distinct from v_req.value_at_approval then
      v_delta := abs(coalesce(v_new_val, 0) - coalesce(v_req.value_at_approval, 0));
      v_pct := case
        when coalesce(v_req.value_at_approval, 0) = 0 then null
        else v_delta * 100 / abs(v_req.value_at_approval)
      end;

      -- Where both tolerances are configured the change must be within BOTH:
      -- a percentage alone lets a large order drift by a large absolute sum,
      -- and an absolute alone is meaningless across orders of different size.
      if (v_cv.tolerance_absolute is not null and v_delta > v_cv.tolerance_absolute)
         or (v_cv.tolerance_pct is not null and (v_pct is null or v_pct > v_cv.tolerance_pct))
         or (v_cv.tolerance_absolute is null and v_cv.tolerance_pct is null)
      then
        required := true;
        reason := format('value moved by %s (%s%%), outside tolerance',
                         v_delta, coalesce(round(v_pct, 2)::text, 'n/a'));
        return next; return;
      end if;
    end if;
  end if;

  required := false;
  reason := 'no material change since approval';
  return next;
end;
$$;

comment on function erp.check_reapproval_required is
  'Spec 3.7: re-approval on material change, with configurable tolerance. '
  'Without this a document approved at one value can be amended to another and '
  'still carry its signature.';

-- -----------------------------------------------------------------------------
-- Chain selection and request creation
-- -----------------------------------------------------------------------------

create or replace function erp.select_approval_chain(
  p_object_type text,
  p_context     jsonb default '{}'::jsonb,
  p_entity_id   uuid default null,
  p_site_id     uuid default null,
  p_on          date default null
) returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_on     date := coalesce(p_on, current_date);
  r        record;
begin
  for r in
    select ac.id as chain_id, acv.id as version_id, ac.applies_when
      from erp.approval_chain ac
      join erp.approval_chain_version acv
        on acv.tenant_id = ac.tenant_id
       and acv.approval_chain_id = ac.id
       and acv.status = 'active'
       and daterange(acv.effective_from, acv.effective_to, '[)') @> v_on
     where ac.tenant_id = v_tenant
       and ac.object_type = p_object_type
       and ac.status = 'active'
       and (ac.site_id   is null or ac.site_id   = p_site_id)
       and (ac.entity_id is null or ac.entity_id = p_entity_id)
     order by ac.priority,
              (ac.site_id is not null) desc,
              (ac.entity_id is not null) desc,
              ac.code
  loop
    if erp.jsonlogic_bool(r.applies_when, p_context) then
      return r.version_id;
    end if;
  end loop;

  return null;
end;
$$;

-- Everyone eligible to act on a step, after delegations are applied.
create or replace function erp.step_approvers(
  p_step_id uuid, p_object_type text, p_entity_id uuid, p_site_id uuid)
returns table (app_user_id uuid, delegated_from uuid)
language sql
stable
security invoker
set search_path = ''
as $$
  with base as (
    select case when st.approver_kind = 'user' then st.app_user_id else ur.app_user_id end as uid
      from erp.approval_step st
      left join erp.user_role ur
        on st.approver_kind = 'role'
       and ur.tenant_id = st.tenant_id
       and ur.role_id = st.role_id
       and ur.valid_from <= current_date
       and (ur.valid_to is null or ur.valid_to >= current_date)
       and (ur.entity_id is null or p_entity_id is null or ur.entity_id = p_entity_id)
       and (ur.site_id   is null or p_site_id   is null or ur.site_id   = p_site_id)
     where st.id = p_step_id
  ),
  -- A delegation substitutes the delegate for the delegator. The original is
  -- recorded so the audit shows who the task belonged to.
  resolved as (
    select coalesce(d.to_user_id, b.uid) as uid,
           case when d.to_user_id is not null then b.uid end as from_uid
      from base b
      left join erp.approval_delegation d
        on d.tenant_id = erp.current_tenant_id()
       and d.from_user_id = b.uid
       and d.status = 'active'
       and d.valid_from <= current_date
       and (d.valid_to is null or d.valid_to >= current_date)
       and (d.object_type is null or d.object_type = p_object_type)
     where b.uid is not null
  )
  select distinct uid, from_uid from resolved
$$;

create or replace function erp.request_approval(
  p_object_type    text,
  p_object_id      uuid,
  p_context        jsonb default '{}'::jsonb,
  p_object_version integer default 1,
  p_entity_id      uuid default null,
  p_site_id        uuid default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_cv_id   uuid;
  v_cv      erp.approval_chain_version%rowtype;
  v_req     uuid;
  v_seq     integer;
begin
  v_cv_id := erp.select_approval_chain(p_object_type, p_context, p_entity_id, p_site_id);

  if v_cv_id is null then
    raise exception 'ERPWARE_NO_APPROVAL_CHAIN: nothing routes % under these conditions',
      p_object_type using errcode = '23503', detail = p_context::text;
  end if;

  select * into v_cv from erp.approval_chain_version where id = v_cv_id;

  -- A new request supersedes any pending one for the same object: two open
  -- approvals for one document is how a rejected amendment gets approved by
  -- accident.
  update erp.approval_request
     set status = 'superseded', decided_at = now(), updated_at = now()
   where tenant_id = v_tenant
     and object_type = p_object_type
     and object_id = p_object_id
     and status = 'pending';

  update erp.approval_task
     set status = 'cancelled', updated_at = now()
   where tenant_id = v_tenant
     and status = 'pending'
     and approval_request_id in (
       select id from erp.approval_request
        where tenant_id = v_tenant and object_type = p_object_type
          and object_id = p_object_id and status = 'superseded');

  insert into erp.approval_request (
    tenant_id, object_type, object_id, object_version, entity_id, site_id,
    approval_chain_id, approval_chain_version_id, context,
    material_fingerprint, value_at_approval, requested_by)
  values (
    v_tenant, p_object_type, p_object_id, p_object_version, p_entity_id, p_site_id,
    v_cv.approval_chain_id, v_cv_id, p_context,
    erp.material_fingerprint(p_context, v_cv.material_fields, v_cv.value_field),
    case when v_cv.value_field is null then null
         else (p_context #>> string_to_array(v_cv.value_field, '.'))::numeric end,
    erp.current_principal_id())
  returning id into v_req;

  v_seq := erp.open_approval_seq(v_req, null);

  if v_seq is null then
    -- A chain with no applicable step approves immediately. That is a
    -- legitimate configuration (a band below any threshold), and it is
    -- recorded as an approval rather than left pending for ever.
    update erp.approval_request
       set status = 'approved', decided_at = now(),
           decision_note = 'no approval step applied to this request',
           updated_at = now()
     where id = v_req;
  end if;

  return v_req;
end;
$$;

-- Opens the next sequence group with at least one applicable step, creating its
-- tasks. Returns the sequence opened, or null when the chain is exhausted.
create or replace function erp.open_approval_seq(
  p_request_id uuid, p_after_seq integer)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_req    erp.approval_request%rowtype;
  v_seq    integer;
  v_made   integer;
  st       record;
begin
  select * into v_req from erp.approval_request where tenant_id = v_tenant and id = p_request_id;

  loop
    select min(s.seq) into v_seq
      from erp.approval_step s
     where s.tenant_id = v_tenant
       and s.approval_chain_version_id = v_req.approval_chain_version_id
       and (p_after_seq is null or s.seq > p_after_seq);

    exit when v_seq is null;

    v_made := 0;

    for st in
      select s.* from erp.approval_step s
       where s.tenant_id = v_tenant
         and s.approval_chain_version_id = v_req.approval_chain_version_id
         and s.seq = v_seq
       order by s.code
    loop
      -- A conditional step that does not apply is recorded as skipped rather
      -- than omitted, so the audit shows it was considered.
      if not erp.jsonlogic_bool(st.condition, v_req.context) then
        insert into erp.approval_task (
          tenant_id, approval_request_id, approval_step_id, step_code, seq, status)
        values (v_tenant, p_request_id, st.id, st.code, st.seq, 'skipped');
        continue;
      end if;

      insert into erp.approval_task (
        tenant_id, approval_request_id, approval_step_id, step_code, seq,
        assignee_user_id, assignee_role_id, delegated_from, due_at)
      select v_tenant, p_request_id, st.id, st.code, st.seq,
             a.app_user_id,
             case when st.approver_kind = 'role' then st.role_id end,
             a.delegated_from,
             case when st.escalate_after is not null then now() + st.escalate_after end
        from erp.step_approvers(st.id, v_req.object_type, v_req.entity_id, v_req.site_id) a;

      get diagnostics v_made = row_count;

      if v_made = 0 then
        -- A step whose role has nobody in it would silently stall the request.
        raise exception
          'ERPWARE_APPROVAL_STEP_UNSTAFFED: step % has no eligible approver in scope',
          st.code using errcode = '23514';
      end if;
    end loop;

    -- If every step at this sequence was skipped, move on to the next.
    if exists (select 1 from erp.approval_task t
                where t.tenant_id = v_tenant
                  and t.approval_request_id = p_request_id
                  and t.seq = v_seq
                  and t.status = 'pending') then
      update erp.approval_request set current_seq = v_seq, updated_at = now()
       where id = p_request_id;
      return v_seq;
    end if;

    p_after_seq := v_seq;
  end loop;

  return null;
end;
$$;

-- -----------------------------------------------------------------------------
-- Deciding
-- -----------------------------------------------------------------------------

create or replace function erp.decide_approval_task(
  p_task_id  uuid,
  p_approve  boolean,
  p_comment  text default null
) returns erp.approval_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor  uuid := erp.current_principal_id();
  v_task   erp.approval_task%rowtype;
  v_req    erp.approval_request%rowtype;
  v_next   integer;
  v_all_ok boolean;
begin
  select * into v_task from erp.approval_task
   where tenant_id = v_tenant and id = p_task_id for update;

  if not found then
    raise exception 'ERPWARE_APPROVAL_TASK_NOT_FOUND: %', p_task_id using errcode = '23503';
  end if;

  if v_task.status <> 'pending' then
    raise exception 'ERPWARE_APPROVAL_TASK_DECIDED: this task is already %', v_task.status
      using errcode = '23514';
  end if;

  -- The task belongs to whoever it was assigned to. Anything looser and
  -- "who approved this" stops being answerable.
  if v_task.assignee_user_id is distinct from v_actor then
    raise exception 'ERPWARE_APPROVAL_NOT_ASSIGNEE: this task is not assigned to you'
      using errcode = '42501';
  end if;

  select * into v_req from erp.approval_request
   where tenant_id = v_tenant and id = v_task.approval_request_id for update;

  if v_req.status <> 'pending' then
    raise exception 'ERPWARE_APPROVAL_REQUEST_CLOSED: the request is already %', v_req.status
      using errcode = '23514';
  end if;

  update erp.approval_task
     set status = case when p_approve then 'approved' else 'rejected' end::erp.approval_task_status,
         decided_by = v_actor, decided_at = now(), comment = p_comment, updated_at = now()
   where id = p_task_id;

  if not p_approve then
    -- One rejection ends it. An approval chain is a set of people who must all
    -- be satisfied, so a single refusal is decisive.
    update erp.approval_request
       set status = 'rejected', decided_at = now(), decision_note = p_comment, updated_at = now()
     where id = v_req.id;

    update erp.approval_task set status = 'cancelled', updated_at = now()
     where tenant_id = v_tenant and approval_request_id = v_req.id and status = 'pending';

    return 'rejected';
  end if;

  -- Every step at this sequence must have reached its own min_approvals.
  select bool_and(sat.ok) into v_all_ok
    from (
      select count(*) filter (where t.status = 'approved') >= max(s.min_approvals) as ok
        from erp.approval_task t
        join erp.approval_step s on s.id = t.approval_step_id
       where t.tenant_id = v_tenant
         and t.approval_request_id = v_req.id
         and t.seq = v_task.seq
         and t.status <> 'skipped'
       group by t.approval_step_id
    ) sat;

  if not coalesce(v_all_ok, true) then
    return 'pending';
  end if;

  -- Satisfied steps need no further signatures; the outstanding tasks are
  -- closed rather than left to age and escalate.
  update erp.approval_task set status = 'skipped', updated_at = now()
   where tenant_id = v_tenant and approval_request_id = v_req.id
     and seq = v_task.seq and status = 'pending';

  v_next := erp.open_approval_seq(v_req.id, v_task.seq);

  if v_next is null then
    update erp.approval_request
       set status = 'approved', decided_at = now(), updated_at = now()
     where id = v_req.id;
    return 'approved';
  end if;

  return 'pending';
end;
$$;

create or replace function erp.delegate_approval_task(
  p_task_id uuid, p_to_user_id uuid, p_reason text default null)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor  uuid := erp.current_principal_id();
  v_task   erp.approval_task%rowtype;
  v_allow  boolean;
  v_new    uuid;
begin
  select * into v_task from erp.approval_task
   where tenant_id = v_tenant and id = p_task_id for update;

  if not found or v_task.status <> 'pending' then
    raise exception 'ERPWARE_APPROVAL_TASK_NOT_OPEN: %', p_task_id using errcode = '23514';
  end if;

  if v_task.assignee_user_id is distinct from v_actor then
    raise exception 'ERPWARE_APPROVAL_NOT_ASSIGNEE: only the assignee may delegate this task'
      using errcode = '42501';
  end if;

  select s.allow_delegation into v_allow
    from erp.approval_step s where s.id = v_task.approval_step_id;

  if not coalesce(v_allow, true) then
    raise exception 'ERPWARE_APPROVAL_DELEGATION_FORBIDDEN: step % may not be delegated',
      v_task.step_code using errcode = '42501';
  end if;

  update erp.approval_task
     set status = 'delegated', decided_by = v_actor, decided_at = now(),
         comment = p_reason, updated_at = now()
   where id = p_task_id;

  insert into erp.approval_task (
    tenant_id, approval_request_id, approval_step_id, step_code, seq,
    assignee_user_id, assignee_role_id, delegated_from, due_at)
  values (
    v_tenant, v_task.approval_request_id, v_task.approval_step_id, v_task.step_code,
    v_task.seq, p_to_user_id, v_task.assignee_role_id, v_actor, v_task.due_at)
  returning id into v_new;

  return v_new;
end;
$$;

-- Escalation on ageing. Run by the scheduler (B9).
create or replace function erp.escalate_overdue_approvals()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        record;
  v_count  integer := 0;
begin
  for t in
    select tk.*, s.escalate_to_role_id, s.escalate_to_user_id, s.escalate_after
      from erp.approval_task tk
      join erp.approval_step s on s.id = tk.approval_step_id
     where tk.tenant_id = v_tenant
       and tk.status = 'pending'
       and tk.due_at is not null
       and tk.due_at <= now()
       and (s.escalate_to_role_id is not null or s.escalate_to_user_id is not null)
  loop
    update erp.approval_task
       set status = 'escalated', decided_at = now(), updated_at = now(),
           comment = 'escalated after ageing past its due time'
     where id = t.id;

    if t.escalate_to_user_id is not null then
      insert into erp.approval_task (
        tenant_id, approval_request_id, approval_step_id, step_code, seq,
        assignee_user_id, escalated_from, due_at)
      values (v_tenant, t.approval_request_id, t.approval_step_id, t.step_code, t.seq,
              t.escalate_to_user_id, t.id, now() + coalesce(t.escalate_after, interval '1 day'));
      v_count := v_count + 1;
    else
      insert into erp.approval_task (
        tenant_id, approval_request_id, approval_step_id, step_code, seq,
        assignee_user_id, assignee_role_id, escalated_from, due_at)
      select v_tenant, t.approval_request_id, t.approval_step_id, t.step_code, t.seq,
             ur.app_user_id, t.escalate_to_role_id, t.id,
             now() + coalesce(t.escalate_after, interval '1 day')
        from erp.user_role ur
       where ur.tenant_id = v_tenant
         and ur.role_id = t.escalate_to_role_id
         and ur.valid_from <= current_date
         and (ur.valid_to is null or ur.valid_to >= current_date);
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- Reading
-- -----------------------------------------------------------------------------

create or replace function erp.approval_state(p_object_type text, p_object_id uuid)
returns table (
  request_id     uuid,
  status         erp.approval_status,
  object_version integer,
  chain_code     text,
  current_seq    integer,
  outstanding    bigint,
  requested_at   timestamptz,
  decided_at     timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
  select ar.id, ar.status, ar.object_version, ac.code, ar.current_seq,
         (select count(*) from erp.approval_task t
           where t.approval_request_id = ar.id and t.status = 'pending'),
         ar.requested_at, ar.decided_at
    from erp.approval_request ar
    left join erp.approval_chain ac on ac.id = ar.approval_chain_id
   where ar.tenant_id = erp.require_tenant_id()
     and ar.object_type = p_object_type
     and ar.object_id = p_object_id
   order by ar.requested_at desc
$$;

-- The complete approval audit for one object: who was asked, who acted, when,
-- with what comment, against which version of the object.
create view erp.approval_audit as
select
  ar.tenant_id,
  ar.object_type,
  ar.object_id,
  ar.object_version,
  ac.code            as chain_code,
  acv.version        as chain_version,
  ar.status          as request_status,
  ar.requested_by,
  ar.requested_at,
  ar.decided_at,
  ar.context,
  t.seq,
  t.step_code,
  t.status           as task_status,
  t.assignee_user_id,
  au.display_name    as assignee_name,
  t.decided_by,
  t.decided_at       as task_decided_at,
  t.comment,
  t.delegated_from,
  t.escalated_from,
  t.due_at
from erp.approval_request ar
left join erp.approval_chain ac on ac.id = ar.approval_chain_id
left join erp.approval_chain_version acv on acv.id = ar.approval_chain_version_id
left join erp.approval_task t
  on t.tenant_id = ar.tenant_id and t.approval_request_id = ar.id
left join erp.app_user au
  on au.tenant_id = ar.tenant_id and au.id = t.assignee_user_id;

comment on view erp.approval_audit is
  'Spec 3.7: complete approval audit, including the version of the object '
  'approved. Skipped, delegated and escalated tasks appear too, so the record '
  'shows what was considered and not only what was signed.';

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
