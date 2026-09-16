-- =============================================================================
-- An approval step asks who raised it
--
-- There are two approval systems in this product and they have never been
-- joined.
--
-- The one that decides — erp.approval_request, erp.approval_step,
-- erp.approval_task, erp.open_approval_seq — creates the tasks, holds the
-- document and drives My approvals. A step in it can name exactly two things,
-- and the constraint says so: a role, or a person.
--
-- The one that knows about people — erp.department, erp.principal_department,
-- erp.approval_band, erp.approver_assignment, erp.resolve_approval_chain —
-- routes by the raiser's department, by value bands within that department, by
-- a named person-to-approver assignment, and by the department's manager. It
-- resolves all of that correctly, writes one erp.approval_routing_stamp saying
-- what it decided, and stops. It creates no task and holds nothing.
--
-- So an administrator can open Organisation and approval routing, configure
-- departments, membership, value bands, named approvers, vacancy behaviour and
-- escalation, and change who approves nothing at all. The screen promises a
-- control it does not have, and the empty state of My approvals says requests
-- appear "when an approval band routes one to you", which no band has ever
-- done.
--
-- The join is small, because the routing engine is already written and already
-- right. A step gains a source to ask, and the thing that creates tasks starts
-- telling it which request it is answering for. That last part is the whole
-- defect underneath the defect: erp.step_approvers() is handed a step and a
-- scope and never the request, so it cannot see who raised the document and
-- could not route by them even if it wanted to.
--
--   approver_source     what the step asks for
--   ─────────────────   ────────────────────────────────────────────────────
--   line_manager        the manager of the raiser's department
--   department_band     the value bands configured for the raiser's department
--   named_assignment    the approver named for the raiser, or their department
--
-- A step that names none of these is a role or a person exactly as before, and
-- every chain in the product today is untouched.
--
-- What this does NOT do, and the migration after it will: a step that resolves
-- to nobody still refuses rather than falling back to the administrators, and
-- whoever asks for a document's approval is still not asked to give it. Both
-- are decisions the owner has taken and both change behaviour that suites
-- currently assert, so they are their own change with their own proof.
-- =============================================================================

-- ── 1. A step may name a source instead of a person ──────────────────────────

alter table erp.approval_step
  add column if not exists approver_source text;

alter table erp.approval_step
  drop constraint if exists approval_step_has_approver;

-- The enum is left alone deliberately. PostgreSQL will not let a value added to
-- an enum be used in the transaction that added it, so widening
-- erp.approver_kind would have split this migration in two for no gain. A
-- column beside it says the same thing and can be used at once.
alter table erp.approval_step
  add constraint approval_step_has_approver check (
    (approver_source is not null and role_id is null and app_user_id is null)
    or (approver_source is null and approver_kind = 'role'
        and role_id is not null and app_user_id is null)
    or (approver_source is null and approver_kind = 'user'
        and app_user_id is not null and role_id is null));

alter table erp.approval_step
  drop constraint if exists approval_step_source_known;

alter table erp.approval_step
  add constraint approval_step_source_known check (
    approver_source is null
    or approver_source in ('line_manager', 'department_band', 'named_assignment'));

comment on column erp.approval_step.approver_source is
  'Where this step finds its approver when it does not name one: the manager of '
  'the raiser''s department, the value bands of that department, or the approver '
  'named for that person. Null means the step names a role or a person itself, '
  'which is every step the product shipped before this.';

-- ── 2. The step is told which request it is answering for ────────────────────

-- The signature widens rather than gaining an overload: a defaulted fifth
-- argument beside the four-argument original would make every existing call
-- ambiguous, so the original goes.
drop function if exists erp.step_approvers(uuid, text, uuid, uuid);

create or replace function erp.step_approvers(
  p_step_id uuid, p_object_type text, p_entity_id uuid, p_site_id uuid,
  p_request_id uuid default null)
returns table (app_user_id uuid, delegated_from uuid)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.current_tenant_id();
  st          erp.approval_step%rowtype;
  v_requester uuid;
  v_value     bigint;
  v_ccy       char(3);
  v_dept      uuid;
  v_chain     jsonb;
  v_manager   uuid;
begin
  select * into st from erp.approval_step s where s.id = p_step_id;
  if not found then
    return;
  end if;

  -- A step that names a role or a person is answered exactly as it was before
  -- this migration, delegation and all.
  if st.approver_source is null then
    return query
      with base as (
        select case when st.approver_kind = 'user' then st.app_user_id else ur.app_user_id end as uid
          from erp.approval_step s2
          left join erp.user_role ur
            on s2.approver_kind = 'role'
           and ur.tenant_id = s2.tenant_id
           and ur.role_id = s2.role_id
           and ur.valid_from <= current_date
           and (ur.valid_to is null or ur.valid_to >= current_date)
           and (ur.entity_id is null or p_entity_id is null or ur.entity_id = p_entity_id)
           and (ur.site_id   is null or p_site_id   is null or ur.site_id   = p_site_id)
         where s2.id = p_step_id
      ),
      -- A delegation substitutes the delegate for the delegator. The original is
      -- recorded so the audit shows who the task belonged to.
      resolved as (
        select coalesce(d.to_user_id, b.uid) as uid,
               case when d.to_user_id is not null then b.uid end as from_uid
          from base b
          left join erp.approval_delegation d
            on d.tenant_id = v_tenant
           and d.from_user_id = b.uid
           and d.status = 'active'
           and d.valid_from <= current_date
           and (d.valid_to is null or d.valid_to >= current_date)
           and (d.object_type is null or d.object_type = p_object_type)
         where b.uid is not null
      )
      select distinct r.uid, r.from_uid from resolved r;
    return;
  end if;

  -- Everything below needs the request: who raised it, and for how much. A
  -- band is a band of value, and the routing engine reads the raiser's
  -- department from the raiser.
  if p_request_id is null then
    return;
  end if;

  select ar.requested_by,
         coalesce(ar.value_at_approval::bigint, (ar.context ->> 'total_minor')::bigint, 0),
         coalesce(nullif(ar.context ->> 'currency', ''), 'GBP')::char(3)
    into v_requester, v_value, v_ccy
    from erp.approval_request ar
   where ar.tenant_id = v_tenant and ar.id = p_request_id;

  if v_requester is null then
    return;
  end if;

  select pd.department_id into v_dept
    from erp.principal_department pd
   where pd.tenant_id = v_tenant and pd.app_user_id = v_requester
     and pd.is_primary and pd.status = 'active'
     and daterange(pd.valid_from, pd.valid_to, '[)') @> current_date
   limit 1;

  if st.approver_source = 'line_manager' then
    -- The manager of the department the raiser is in. There is no person-level
    -- reporting line in this product and this is what "line manager" has always
    -- meant in erp.resolve_band_approver().
    select d.manager_user_id into v_manager
      from erp.department d
     where d.tenant_id = v_tenant and d.id = v_dept;
    if v_manager is not null then
      return query select v_manager, null::uuid;
    end if;
    return;
  end if;

  -- The routing engine already answers both of the others, in the order
  -- Addendum B fixed: named assignment, then department band. It refuses on a
  -- vacancy and on self-approval; neither is this function's decision to make,
  -- so a refusal here means the step resolved to nobody and the caller says so
  -- in its own words.
  begin
    v_chain := erp.resolve_approval_chain(
      p_object_type, v_value, v_ccy, v_dept, v_requester, p_entity_id, p_site_id, current_date);
  exception when others then
    return;
  end;

  -- erp.apply_cover() has already substituted any delegate inside the routing
  -- engine, and the step it returns carries its own cover_trail. Joining
  -- erp.approval_delegation again here would substitute a second time.
  return query
    select distinct (s.value ->> 'approver_user_id')::uuid, null::uuid
      from jsonb_array_elements(coalesce(v_chain -> 'steps', '[]'::jsonb)) s
     where (s.value ->> 'approver_user_id') is not null
       and s.value ->> 'source' = st.approver_source;
end;
$$;

revoke all on function erp.step_approvers(uuid, text, uuid, uuid, uuid) from public, anon, authenticated;

comment on function erp.step_approvers(uuid, text, uuid, uuid, uuid) is
  'Who may satisfy a step. A step naming a role or a person is answered from '
  'that, as it always was. A step naming a source is answered by the routing '
  'engine that has known about departments, bands and named approvers all '
  'along and has never been asked.';

-- ── 3. And the thing that makes tasks tells it ───────────────────────────────

do $seq$
declare
  v_sig constant text := 'erp.open_approval_seq(uuid, integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
    'erp.step_approvers(st.id, v_req.object_type, v_req.entity_id, v_req.site_id)';
  v_n integer;
  v_new text;
begin
  v_n := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_n <> 3 then
    raise exception 'CLOVEERP_APPROVAL_SEQ_UNRECOGNISED: % asks erp.step_approvers % time(s), and this migration expects three', v_sig, v_n;
  end if;

  v_new := replace(v_def, v_needle,
    'erp.step_approvers(st.id, v_req.object_type, v_req.entity_id, v_req.site_id, p_request_id)');

  execute v_new;
end
$seq$;

-- ── 4. A promoted chain may say it ───────────────────────────────────────────

-- The applier reads a step payload and writes a row, and it wrote only the role
-- and the person. A chain promoted with a source would have lost it in silence,
-- which is the same class of fault as the one this migration is fixing.
do $applier$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_cols constant text :=
    E'        insert into erp.approval_step (\n'
    || E'          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,\n'
    || E'          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)';
  v_kind constant text := E'               e.value ->> ''name'', (e.value ->> ''approver_kind'')::erp.approver_kind,';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_cols, ''))) / length(v_cols) <> 1 then
    raise exception 'CLOVEERP_APPLIER_UNRECOGNISED: the approval step written by % is not the one this migration adds a column to', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_kind, ''))) / length(v_kind) <> 1 then
    raise exception 'CLOVEERP_APPLIER_UNRECOGNISED: the approver kind written by % is not the one this migration adds beside', v_sig;
  end if;

  v_new := replace(v_def, v_cols,
       E'        insert into erp.approval_step (\n'
    || E'          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,\n'
    || E'          approver_source,\n'
    || E'          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)');

  -- A step that names a source names no kind, and the column is not null, so
  -- the kind it is given is the one the constraint ignores.
  v_new := replace(v_new, v_kind,
       E'               e.value ->> ''name'',\n'
    || E'               coalesce((e.value ->> ''approver_kind'')::erp.approver_kind, ''role''),\n'
    || E'               e.value ->> ''approver_source'',');

  execute v_new;
end
$applier$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

-- The step resolver is asked directly rather than through a document's
-- lifecycle. What changed is which people a step resolves to, and driving a
-- purchase order through submission to prove it would test the lifecycle as
-- well and say less about either.
create or replace function erp_test.approval_step_source_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid;
  v_mgr uuid; v_named uuid; v_band uuid;
  v_dept uuid; v_ver uuid; v_req uuid;
  v_role uuid;
  v_step_role uuid; v_step_mgr uuid; v_step_named uuid; v_step_band uuid;
  v_who uuid; v_n integer;
  v_ok boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-step-source', 'Approval step source suite',
                              'admin@zz-step-source.test', 'Step Source Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000ea', 'admin@zz-step-source.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000ea')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id into v_entity
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;

  v_mgr   := (public.erp_invite_principal('mgr@zz-step-source.test', 'Department Manager') ->> 'app_user_id')::uuid;
  v_named := (public.erp_invite_principal('named@zz-step-source.test', 'Named Approver') ->> 'app_user_id')::uuid;
  v_band  := (public.erp_invite_principal('band@zz-step-source.test', 'Band Approver') ->> 'app_user_id')::uuid;

  -- A department the raiser is in, with a manager over it.
  insert into erp.department (tenant_id, entity_id, code, name, manager_user_id, status)
  values (v_tenant, v_entity, 'ZZDEPT', 'Buying', v_mgr, 'active')
  returning id into v_dept;
  insert into erp.principal_department (tenant_id, app_user_id, department_id, is_primary, status)
  values (v_tenant, v_admin, v_dept, true, 'active');

  -- A chain version to hang steps on, and a request that names the raiser.
  select v.id into v_ver
    from erp.approval_chain_version v
    join erp.approval_chain c on c.tenant_id = v.tenant_id and c.id = v.approval_chain_id
   where v.tenant_id = v_tenant order by c.code, v.id limit 1;

  insert into erp.approval_request (
    tenant_id, object_type, object_id, entity_id, site_id,
    approval_chain_version_id, status, context, value_at_approval, requested_by)
  values (v_tenant, 'document', gen_random_uuid(), v_entity, v_site,
          v_ver, 'pending',
          jsonb_build_object('total_minor', 500000, 'currency', 'GBP'),
          500000, v_admin)
  returning id into v_req;

  select r.id into v_role from erp.role r
   where r.tenant_id = v_tenant and r.code = 'administrator';

  -- ── 1. A step that names a role is untouched ─────────────────────────────
  v_cases := v_cases + 1;
  insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code,
                                 name, approver_kind, role_id)
  values (v_tenant, v_ver, 91, 'zz_role', 'By role', 'role', v_role)
  returning id into v_step_role;
  select count(*) into v_n
    from erp.step_approvers(v_step_role, 'document', v_entity, v_site, v_req);
  case_name := 'a step that names a role still resolves to whoever holds it';
  passed := v_n >= 1;
  detail := format('%s holder(s) of administrator', v_n);
  return next;

  -- ── 2. The raiser's department manager ───────────────────────────────────
  v_cases := v_cases + 1;
  insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code,
                                 name, approver_kind, approver_source)
  values (v_tenant, v_ver, 92, 'zz_mgr', 'By line manager', 'role', 'line_manager')
  returning id into v_step_mgr;
  select a.app_user_id into v_who
    from erp.step_approvers(v_step_mgr, 'document', v_entity, v_site, v_req) a limit 1;
  case_name := 'a step that asks for the line manager resolves to the manager of the department the raiser is in';
  passed := v_who = v_mgr;
  detail := format('resolved %s, the manager is %s', coalesce(v_who::text, 'nobody'), v_mgr);
  return next;

  -- ── 3. The approver named for that person ────────────────────────────────
  v_cases := v_cases + 1;
  perform erp.assign_named_approver('principal', v_admin, 'document', v_named);
  insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code,
                                 name, approver_kind, approver_source)
  values (v_tenant, v_ver, 93, 'zz_named', 'By named assignment', 'role', 'named_assignment')
  returning id into v_step_named;
  select a.app_user_id into v_who
    from erp.step_approvers(v_step_named, 'document', v_entity, v_site, v_req) a limit 1;
  case_name := 'a step that asks for the named approver resolves to the person assigned to the raiser';
  passed := v_who = v_named;
  detail := format('resolved %s, the assignment names %s', coalesce(v_who::text, 'nobody'), v_named);
  return next;

  -- ── 4. The band configured for that department ───────────────────────────
  v_cases := v_cases + 1;
  perform erp.upsert_approval_band(v_dept, 'document', 1, null, 0, v_band);
  insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code,
                                 name, approver_kind, approver_source)
  values (v_tenant, v_ver, 94, 'zz_band', 'By department band', 'role', 'department_band')
  returning id into v_step_band;
  select count(*) into v_n
    from erp.step_approvers(v_step_band, 'document', v_entity, v_site, v_req) a
   where a.app_user_id = v_band;
  case_name := 'a step that asks for the department band resolves to the approver that band names';
  passed := v_n = 1;
  detail := format('the band approver appears %s time(s)', v_n);
  return next;

  -- ── 5. Asked without a request, it says nobody rather than guessing ──────
  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.step_approvers(v_step_mgr, 'document', v_entity, v_site, null);
  case_name := 'a step that asks about the raiser resolves to nobody when it is not told which request';
  passed := v_n = 0;
  detail := format('%s approver(s) without a request', v_n);
  return next;

  -- ── 6. A step is one thing or the other, never both ─────────────────────
  v_cases := v_cases + 1;
  begin
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code,
                                   name, approver_kind, role_id, approver_source)
    values (v_tenant, v_ver, 95, 'zz_both', 'Both at once', 'role', v_role, 'line_manager');
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 80);
  end;
  case_name := 'a step may name a role or a source and not both';
  passed := v_ok;
  detail := v_msg;
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 7. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-step-source')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000ea');
  detail := 'zz-step-source rolled back with its department, bands and steps';
  return next;

  if v_cases <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: approval_step_source_suite ran % cases, expected 7', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.approval_step_source_suite() from public, anon;

create or replace function erp_test.assert_approval_step_source_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _step_source on commit drop as
    select * from erp_test.approval_step_source_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _step_source;
  drop table _step_source;
  if v_fail > 0 then
    raise exception E'CLOVEERP_APPROVAL_STEP_SOURCE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: approval_step_source_suite ran % cases, expected 7', v_all;
  end if;
  return format('an approval step asks who raised it: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_approval_step_source_suite() from public, anon;

select erp.apply_execute_grants();
select erp_test.assert_approval_step_source_suite();
