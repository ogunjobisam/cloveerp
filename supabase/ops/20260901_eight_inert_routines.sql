-- Bring production's last eight erp routines to the text main carries.
--
-- Applying 20260831_live_reconciliation.sql left twelve of thirteen dimensions
-- matching a build of main exactly. The thirteenth is erp: eight routines whose
-- bodies differ from the repository in ways that were checked one at a time and
-- found to change no behaviour.
--
--   perform_transition            main declares v_effects jsonb, never used
--   open_approval_seq             main initialises v_made := 0, always assigned
--                                 before every use
--   audit_coverage_report         one string literal on production, two
--                                 adjacent ones on main
--   decide_approval_task          production parenthesises the CASE before the
--                                 cast; the cast binds the same either way
--   evaluate_legislation_rules    main selects b.pack_version, never referenced
--   run_legislation_conformance   the same unused selected column
--   submit_command                main declares v_req in an inner block,
--                                 production in the outer one
--   request_approval              the supersede and cancel UPDATEs run in the
--                                 opposite order, over the same set of tasks
--
-- No gate, guard, permission check or tenant scope differs in any of them, so
-- this file fixes no defect. It exists so that a body-level comparison between
-- production and main comes back clean, which is what makes the next drift
-- visible. That is worth something and it is not worth much: if you would
-- rather not replace the state machine, the approval router and the
-- integration gateway to add an unused variable, not running this is a
-- defensible answer.
--
-- Every definition below was emitted by pg_get_functiondef() against a build of
-- main from empty. Nothing here was typed by hand.
--
--   psql "$DATABASE_URL" --single-transaction -f supabase/ops/20260901_eight_inert_routines.sql
--
-- It ends with the same 22 assertions the reconciliation ends with, so a
-- database this would leave in a state the product considers wrong rolls the
-- whole thing back instead.

CREATE OR REPLACE FUNCTION erp.audit_coverage_report()
 RETURNS TABLE(schema_name text, table_name text, finding text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select tp.schema_name, tp.table_name,
         'tenant-scoped table has no audit trigger and no registered exemption'
    from erp_meta.table_policy tp
    join pg_catalog.pg_class c
      on c.relname = tp.table_name
     and c.relnamespace::regnamespace::text = tp.schema_name
     and c.relkind = 'r'
   where tp.table_class = 'tenant_scoped'
     and not exists (
       select 1 from erp_meta.audit_exemption ae
        where ae.schema_name = tp.schema_name and ae.table_name = tp.table_name)
     and not exists (
       select 1 from pg_catalog.pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgfoid = 'erp.audit_row_change()'::regprocedure)

  union all

  select tp.schema_name, tp.table_name,
         'append-only table has no mutation guard, so a role that bypasses RLS '
         'could still edit or delete evidence'
    from erp_meta.table_policy tp
    join pg_catalog.pg_class c
      on c.relname = tp.table_name
     and c.relnamespace::regnamespace::text = tp.schema_name
     and c.relkind = 'r'
   where tp.table_class = 'tenant_scoped_append_only'
     and not exists (
       select 1 from pg_catalog.pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgfoid = 'erp.forbid_mutation()'::regprocedure)
  order by 1, 2
$function$

;

CREATE OR REPLACE FUNCTION erp.decide_approval_task(p_task_id uuid, p_approve boolean, p_comment text DEFAULT NULL::text)
 RETURNS erp.approval_status
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$

;

CREATE OR REPLACE FUNCTION erp.evaluate_legislation_rules(p_decision_point text, p_data jsonb, p_entity_id uuid, p_on date)
 RETURNS TABLE(outcome jsonb, rule_code text, pack_code text, trace jsonb)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  r         record;
  v_trace   jsonb := '[]'::jsonb;
  v_outcome jsonb := null;
  v_code    text;
  v_pack    text;
  v_hit     boolean;
begin
  if p_entity_id is null then
    return;
  end if;

  for r in
    select lr.*, b.pack_version as bound_version
      from erp.bound_legislation_packs(p_entity_id, p_on) b
      join erp_ref.legislation_rule lr
        on lr.pack_code = b.pack_code and lr.pack_version = b.pack_version
     where lr.decision_point_code = p_decision_point
     order by lr.pack_code, lr.seq
  loop
    v_hit := erp.jsonlogic_bool(r.condition, p_data);

    v_trace := v_trace || jsonb_build_array(jsonb_build_object(
      'source', 'legislation',
      'pack', r.pack_code,
      'seq', r.seq,
      'rule_code', r.code,
      'result', case when v_hit then 'matched' else 'no_match' end));

    if v_hit then
      v_outcome := coalesce(v_outcome, '{}'::jsonb) || r.outcome;
      v_code := r.code;
      v_pack := r.pack_code;
      exit when r.stop_on_match;
    end if;
  end loop;

  if v_outcome is not null then
    outcome := v_outcome; rule_code := v_code; pack_code := v_pack; trace := v_trace;
    return next;
  end if;
end;
$function$

;

CREATE OR REPLACE FUNCTION erp.open_approval_seq(p_request_id uuid, p_after_seq integer)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$

;

CREATE OR REPLACE FUNCTION erp.perform_transition(p_object_type text, p_object_id uuid, p_transition_code text, p_data jsonb DEFAULT '{}'::jsonb, p_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$

;

CREATE OR REPLACE FUNCTION erp.request_approval(p_object_type text, p_object_id uuid, p_context jsonb DEFAULT '{}'::jsonb, p_object_version integer DEFAULT 1, p_entity_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$

;

CREATE OR REPLACE FUNCTION erp.run_legislation_conformance(p_entity_id uuid, p_on date DEFAULT NULL::date)
 RETURNS TABLE(pack_code text, case_code text, passed boolean, expected jsonb, actual jsonb, citation text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  c      record;
  v_out  jsonb;
begin
  for c in
    select cc.*, b.pack_version as bound_version
      from erp.bound_legislation_packs(p_entity_id, p_on) b
      join erp_ref.conformance_case cc
        on cc.pack_code = b.pack_code and cc.pack_version = b.pack_version
     order by cc.pack_code, cc.code
  loop
    begin
      select r.outcome into v_out
        from erp.evaluate_rules(c.decision_point_code, c.inputs, p_on, p_entity_id, null) r;
    exception when others then
      v_out := jsonb_build_object('error', sqlerrm);
    end;

    pack_code := c.pack_code;
    case_code := c.code;
    -- Containment, not equality: a pack asserts the values it is responsible
    -- for, and a tenant rule adding an unrelated key alongside is not a
    -- conformance failure.
    passed    := (v_out @> c.expected_outcome);
    expected  := c.expected_outcome;
    actual    := v_out;
    citation  := c.citation;
    return next;
  end loop;
end;
$function$

;

CREATE OR REPLACE FUNCTION erp.submit_command(p_system_code text, p_operation_code text, p_payload jsonb DEFAULT '{}'::jsonb, p_dry_run boolean DEFAULT false, p_idempotency_key text DEFAULT NULL::text, p_ordering_key text DEFAULT NULL::text, p_source_object_type text DEFAULT NULL::text, p_source_object_id uuid DEFAULT NULL::uuid, p_entity_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid, p_correlation_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_sys       erp.external_system%rowtype;
  v_op        erp_ref.adapter_operation%rowtype;
  v_adapter   erp_ref.adapter%rowtype;
  v_enabled   erp.external_system_operation%rowtype;
  v_key       text;
  v_existing  erp.command%rowtype;
  v_id        uuid;
  v_needs     boolean;
  v_cred      text;
  v_chain     uuid;
  v_ordering  text;
begin
  -- Every outbound write is an integration action, whatever business reason
  -- prompted it. The calling module has already authorised its own action; this
  -- authorises leaving the building.
  perform erp.authorise('administration.integrate', p_entity_id, p_site_id, null,
                        'command', null, p_correlation_id);

  select * into v_sys from erp.external_system s
   where s.tenant_id = v_tenant and s.code = p_system_code;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_EXTERNAL_SYSTEM: %', p_system_code
      using errcode = '23503';
  end if;

  -- A live send needs a live system. A dry run against a draft configuration is
  -- exactly how a configuration gets proven before it goes live, so that is
  -- allowed.
  if v_sys.status <> 'active' and not p_dry_run then
    raise exception
      'ERPWARE_SYSTEM_NOT_ACTIVE: % is %; only a dry run may target it',
      p_system_code, v_sys.status
      using errcode = '42501';
  end if;

  select * into v_adapter from erp_ref.adapter a
   where a.code = v_sys.adapter_code and a.version = v_sys.adapter_version;

  if v_adapter.direction = 'inbound' then
    raise exception
      'ERPWARE_ADAPTER_IS_INBOUND: % cannot carry an outbound command',
      v_sys.adapter_code
      using errcode = '42501';
  end if;

  select * into v_op from erp_ref.adapter_operation o
   where o.adapter_code = v_sys.adapter_code
     and o.adapter_version = v_sys.adapter_version
     and o.code = p_operation_code;

  if not found then
    raise exception
      'ERPWARE_UNKNOWN_OPERATION: % is not an operation of adapter %@%',
      p_operation_code, v_sys.adapter_code, v_sys.adapter_version
      using errcode = '23503';
  end if;

  -- Refusal 3: absence of an enablement row means no.
  select * into v_enabled from erp.external_system_operation eo
   where eo.tenant_id = v_tenant
     and eo.external_system_id = v_sys.id
     and eo.operation_code = p_operation_code;

  if not found or not v_enabled.is_enabled then
    raise exception
      'ERPWARE_OPERATION_NOT_ENABLED: % is not enabled on %',
      p_operation_code, p_system_code
      using errcode = '42501',
      detail = 'Enable it in erp.external_system_operation. Absence is a refusal.';
  end if;

  if p_dry_run and not (v_adapter.supports_dry_run and v_op.supports_dry_run) then
    raise exception
      'ERPWARE_DRY_RUN_UNSUPPORTED: % on % cannot be simulated',
      p_operation_code, p_system_code
      using errcode = '42501';
  end if;

  -- Refusal 2.
  if not extensions.jsonb_matches_schema(v_op.request_schema::json, p_payload) then
    raise exception
      'ERPWARE_INVALID_COMMAND_PAYLOAD: payload does not satisfy the request '
      'schema for %', p_operation_code
      using errcode = '22023', detail = p_payload::text;
  end if;

  -- Spec 4.9: no module holds credentials. That includes putting one in a
  -- payload so the far side will accept it.
  select string_agg(format('  %s — %s', f.path, f.finding), E'\n') into v_cred
    from erp.inline_credential_findings(p_payload) f;

  if v_cred is not null then
    raise exception
      'ERPWARE_INLINE_CREDENTIAL: a command payload must not carry a credential'
      using errcode = '42501', detail = v_cred;
  end if;

  v_key := coalesce(
    p_idempotency_key,
    erp.derive_idempotency_key(v_sys.id, p_operation_code, p_payload,
                               p_source_object_type, p_source_object_id));

  -- Idempotency at the gateway: the same key is the same intent. Returning the
  -- existing command is the correct answer to a caller retrying after a timeout
  -- it never saw the result of.
  select * into v_existing from erp.command c
   where c.tenant_id = v_tenant
     and c.external_system_id = v_sys.id
     and c.idempotency_key = v_key;

  if found then
    if v_existing.payload is distinct from p_payload then
      raise exception
        'ERPWARE_IDEMPOTENCY_CONFLICT: key % already names a different intent '
        'on %', v_key, p_system_code
        using errcode = '23505',
        detail = 'The same key must not be reused for a different payload.';
    end if;
    return v_existing.id;
  end if;

  v_ordering := coalesce(
    p_ordering_key,
    case
      when v_enabled.ordering_key_path is not null
        then p_payload #>> string_to_array(v_enabled.ordering_key_path, '.')
      when v_op.default_ordering_key_path is not null
        then p_payload #>> string_to_array(v_op.default_ordering_key_path, '.')
    end);

  insert into erp.command (
    tenant_id, external_system_id, operation_code, payload, idempotency_key,
    ordering_key, dry_run, source_object_type, source_object_id, correlation_id,
    entity_id, site_id, max_attempts, next_attempt_at)
  values (
    v_tenant, v_sys.id, p_operation_code, p_payload, v_key,
    v_ordering, p_dry_run, p_source_object_type, p_source_object_id,
    coalesce(p_correlation_id, erp.current_correlation_id()),
    p_entity_id, p_site_id, v_sys.max_attempts, now())
  returning id into v_id;

  -- The approval gate. A read never needs one. A simulation never needs one —
  -- that is what makes preview useful. Everything else is decided by the
  -- system, the operation, and whether a chain routes it.
  v_needs := v_op.is_mutating
             and not p_dry_run
             and (v_sys.requires_approval
                  or coalesce(v_enabled.requires_approval, false));

  if v_op.is_mutating and not p_dry_run and not v_needs then
    v_chain := erp.select_approval_chain(
      'integration.command',
      jsonb_build_object('system_code', p_system_code,
                         'operation_code', p_operation_code,
                         'payload', p_payload),
      p_entity_id, p_site_id);
    v_needs := v_chain is not null;
  end if;

  if v_needs then
    declare
      v_req uuid;
    begin
      v_req := erp.request_approval(
        'integration.command', v_id,
        jsonb_build_object('system_code', p_system_code,
                           'operation_code', p_operation_code,
                           'payload', p_payload),
        1, p_entity_id, p_site_id);

      update erp.command
         set approval_required = true,
             approval_request_id = v_req,
             status = 'pending_approval'
       where id = v_id;
    end;
  else
    -- Approved without a chain is still a recorded decision: the lifecycle log
    -- shows it went straight through, and why.
    update erp.command set status = 'approved' where id = v_id;
    perform erp.release_command(v_id);
  end if;

  return v_id;
end;
$function$

;


-- ── Prove it, in the transaction that did it ────────────────────────────────

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_session_context_hygiene();
select erp.assert_gateway_integrity();
select erp.assert_scheduler_integrity();
select erp.assert_governed_views_are_safe();
select erp.assert_intelligence_boundary();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_master_data_sane();
select erp.assert_inventory_sane();
select erp.assert_procurement_controls_sane();
select erp.assert_planning_sane();
select erp.assert_production_sane();
select erp.assert_sales_controls_sane();
select erp.assert_quality_logistics_sane();
select erp.assert_finance_depth_sane();
select erp.assert_part5_coverage();
select erp.assert_transaction_control_routines();
select erp.assert_document_create_permissions();
select erp.assert_resource_coverage('en');
