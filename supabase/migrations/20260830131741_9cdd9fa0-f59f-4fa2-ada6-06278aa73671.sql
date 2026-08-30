-- =============================================================================
-- Addendum B 1 (continued): time-bounded cover, and the evidence behind it
--
-- Delegation lends authority and keeps the approver of record. Substitution
-- replaces the approver outright. Both are bounded in time, both can be
-- narrowed by object type and value, and neither is allowed to route a request
-- back to the person who raised it.
-- =============================================================================

create type erp.cover_kind as enum ('delegation', 'substitution');

-- The delegation table already exists and is already read by the approval
-- engine. It is extended in place rather than duplicated: cover has to mean
-- one thing everywhere.
alter table erp.approval_delegation
  add column kind              erp.cover_kind not null default 'delegation',
  add column lower_bound_minor bigint,
  add column upper_bound_minor bigint,
  add column valid_from_at     timestamptz,
  add column valid_to_at       timestamptz,
  add constraint approval_delegation_bounds
    check (upper_bound_minor is null or lower_bound_minor is null
           or upper_bound_minor > lower_bound_minor),
  add constraint approval_delegation_at_range
    check (valid_to_at is null or valid_from_at is null or valid_to_at > valid_from_at);

create index on erp.approval_delegation (tenant_id, to_user_id, status);

comment on table erp.approval_delegation is
  'Addendum B 1: time-bounded cover. Delegation keeps the approver of record; '
  'substitution replaces them. Neither may route a request to its requester.';

comment on column erp.approval_delegation.valid_from_at is
  'Precise start of cover. Falls back to valid_from at the start of that day.';

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, is_current)
values
  ('approval.cover_started', 1, 'approval', 'administration', 'event.approval.cover_started',
   'An approver handed their authority to a colleague for a period.', true),
  ('approval.cover_ended', 1, 'approval', 'administration', 'event.approval.cover_ended',
   'A cover arrangement was ended.', true),
  ('approval.cover_applied', 1, 'approval', 'administration', 'event.approval.cover_applied',
   'A resolved step routed to a delegate rather than the approver of record.', true)
on conflict (code, version) do nothing;

-- -----------------------------------------------------------------------------
-- Following the cover
-- -----------------------------------------------------------------------------

create or replace function erp.apply_cover(
  p_approver    uuid,
  p_object_type text,
  p_value_minor bigint,
  p_requester   uuid default null,
  p_at          timestamptz default null
) returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_at      timestamptz := coalesce(p_at, now());
  v_current uuid := p_approver;
  v_seen    uuid[] := array[p_approver];
  v_trail   jsonb := '[]'::jsonb;
  v_kind    text := null;
  r         record;
  i         integer := 0;
begin
  if p_approver is null then
    return jsonb_build_object('approver_user_id', null, 'covered', false);
  end if;

  -- Three hops is a cover arrangement; more than that is a lost request.
  while i < 3 loop
    i := i + 1;

    select d.* into r
      from erp.approval_delegation d
     where d.tenant_id = v_tenant
       and d.from_user_id = v_current
       and d.status = 'active'
       and coalesce(d.valid_from_at, d.valid_from::timestamptz) <= v_at
       and (coalesce(d.valid_to_at, (d.valid_to + 1)::timestamptz) is null
            or coalesce(d.valid_to_at, (d.valid_to + 1)::timestamptz) > v_at)
       and (d.object_type is null or d.object_type = p_object_type)
       and (d.lower_bound_minor is null or p_value_minor >= d.lower_bound_minor)
       and (d.upper_bound_minor is null or p_value_minor < d.upper_bound_minor)
       and not (d.to_user_id = any(v_seen))
       and (p_requester is null or d.to_user_id <> p_requester)
     order by (d.object_type is not null) desc,
              (d.lower_bound_minor is not null) desc,
              d.valid_from desc
     limit 1;

    exit when r.id is null;

    v_seen  := v_seen || r.to_user_id;
    v_trail := v_trail || jsonb_build_object(
      'delegation_id', r.id, 'kind', r.kind::text,
      'from_user_id', v_current, 'to_user_id', r.to_user_id,
      'reason', r.reason,
      'valid_from', coalesce(r.valid_from_at, r.valid_from::timestamptz),
      'valid_to', coalesce(r.valid_to_at, (r.valid_to + 1)::timestamptz));
    v_kind    := r.kind::text;
    v_current := r.to_user_id;
  end loop;

  if v_current = p_approver then
    return jsonb_build_object('approver_user_id', p_approver, 'covered', false);
  end if;

  return jsonb_build_object(
    -- Substitution replaces the approver; delegation lends their authority.
    'approver_user_id', v_current,
    'approver_of_record_user_id', case when v_kind = 'substitution' then null else p_approver end,
    'covered', true,
    'cover_kind', v_kind,
    'cover_trail', v_trail);
end;
$$;

comment on function erp.apply_cover(uuid,text,bigint,uuid,timestamptz) is
  'Addendum B 1: follows delegation up to three hops, refuses to loop, and '
  'never hands a request to the person who raised it.';

-- -----------------------------------------------------------------------------
-- Resolution, now cover-aware. Every step carries who acted and whose
-- authority they acted on.
-- -----------------------------------------------------------------------------

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
  v_cover     jsonb;
  v_step      jsonb;
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

    v_cover := erp.apply_cover(r.approver_user_id, p_object_type, p_value_minor, v_requester);

    v_step := jsonb_build_object(
      'seq', v_seq,
      'approver_user_id', v_cover->>'approver_user_id',
      'approver_of_record_user_id',
        coalesce(v_cover->>'approver_of_record_user_id',
                 case when (v_cover->>'covered')::boolean then null
                      else r.approver_user_id::text end),
      'covered', coalesce((v_cover->>'covered')::boolean, false),
      'cover_kind', v_cover->>'cover_kind',
      'cover_trail', coalesce(v_cover->'cover_trail', '[]'::jsonb),
      'source', 'named_assignment', 'rule_id', r.id, 'rule_version', r.version,
      'mode', r.mode, 'reason', r.reason);

    v_named := v_named || v_step;
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

      v_cover := erp.apply_cover(v_user, p_object_type, p_value_minor, v_requester);

      v_seq := v_seq + 1;
      v_steps := v_steps || jsonb_build_object(
        'seq', v_seq,
        'approver_user_id', v_cover->>'approver_user_id',
        'approver_of_record_user_id',
          coalesce(v_cover->>'approver_of_record_user_id',
                   case when (v_cover->>'covered')::boolean then null
                        else v_user::text end),
        'covered', coalesce((v_cover->>'covered')::boolean, false),
        'cover_kind', v_cover->>'cover_kind',
        'cover_trail', coalesce(v_cover->'cover_trail', '[]'::jsonb),
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

-- -----------------------------------------------------------------------------
-- Public surface: cover
-- -----------------------------------------------------------------------------

create or replace function public.erp_approval_delegations(p_include_ended boolean default false)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.read');
  select coalesce(jsonb_agg(x order by x->>'valid_from' desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'delegation_id', d.id,
      'delegator_user_id', d.from_user_id, 'delegator', du.display_name,
      'delegate_user_id', d.to_user_id, 'delegate', ru.display_name,
      'kind', d.kind::text, 'object_type', d.object_type,
      'lower_bound_minor', d.lower_bound_minor, 'upper_bound_minor', d.upper_bound_minor,
      'reason', d.reason,
      'valid_from', coalesce(d.valid_from_at, d.valid_from::timestamptz),
      'valid_to', coalesce(d.valid_to_at, (d.valid_to + 1)::timestamptz),
      'in_force', d.status = 'active'
                  and coalesce(d.valid_from_at, d.valid_from::timestamptz) <= now()
                  and (coalesce(d.valid_to_at, (d.valid_to + 1)::timestamptz) is null
                       or coalesce(d.valid_to_at, (d.valid_to + 1)::timestamptz) > now()),
      'status', d.status) as x
      from erp.approval_delegation d
      left join erp.app_user du on du.tenant_id = d.tenant_id and du.id = d.from_user_id
      left join erp.app_user ru on ru.tenant_id = d.tenant_id and ru.id = d.to_user_id
     where d.tenant_id = erp.current_tenant_id()
       and (p_include_ended or d.status = 'active')
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_delegate_approval(
  p_delegator_user_id uuid,
  p_delegate_user_id  uuid,
  p_valid_from        timestamptz default null,
  p_valid_to          timestamptz default null,
  p_kind              text default 'delegation',
  p_object_type       text default null,
  p_lower_bound_minor bigint default null,
  p_upper_bound_minor bigint default null,
  p_reason            text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from timestamptz := coalesce(p_valid_from, now());
  v_id uuid;
begin
  perform erp.authorise('administration.configure');

  if p_delegator_user_id = p_delegate_user_id then
    raise exception 'ERPWARE_COVER_SELF: an approver cannot cover for themselves'
      using errcode = '23514';
  end if;

  -- A cover arrangement that points back at an existing delegator would put a
  -- request into a loop, so it is refused at the point it is created.
  if exists (
    select 1 from erp.approval_delegation d
     where d.tenant_id = v_tenant
       and d.status = 'active'
       and d.from_user_id = p_delegate_user_id
       and d.to_user_id = p_delegator_user_id
       and (coalesce(d.valid_to_at, (d.valid_to + 1)::timestamptz) is null
            or coalesce(d.valid_to_at, (d.valid_to + 1)::timestamptz) > v_from)) then
    raise exception 'ERPWARE_COVER_LOOP: that person already delegates back to this approver'
      using errcode = '23514';
  end if;

  insert into erp.approval_delegation (
    tenant_id, from_user_id, to_user_id, kind, object_type,
    lower_bound_minor, upper_bound_minor, reason,
    valid_from, valid_to, valid_from_at, valid_to_at)
  values (v_tenant, p_delegator_user_id, p_delegate_user_id,
          coalesce(p_kind, 'delegation')::erp.cover_kind, p_object_type,
          p_lower_bound_minor, p_upper_bound_minor, p_reason,
          v_from::date, p_valid_to::date, v_from, p_valid_to)
  returning id into v_id;

  perform erp.append_event('approval.cover_started', 'approval', v_id,
    jsonb_build_object('delegator', p_delegator_user_id, 'delegate', p_delegate_user_id,
                       'kind', coalesce(p_kind, 'delegation'), 'object_type', p_object_type,
                       'valid_from', v_from, 'valid_to', p_valid_to, 'reason', p_reason));

  return jsonb_build_object('delegation_id', v_id, 'valid_from', v_from, 'valid_to', p_valid_to);
end;
$$;

create or replace function public.erp_end_approval_delegation(
  p_delegation_id uuid,
  p_reason        text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_owner uuid;
begin
  select d.from_user_id into v_owner
    from erp.approval_delegation d
   where d.tenant_id = v_tenant and d.id = p_delegation_id;

  if v_owner is null then
    raise exception 'ERPWARE_COVER_UNKNOWN: no such cover arrangement'
      using errcode = '23503';
  end if;

  -- A person may always end cover they gave; anyone else needs the right.
  if v_owner is distinct from erp.current_principal_id() then
    perform erp.authorise('administration.configure');
  end if;

  update erp.approval_delegation
     set valid_to_at = now(),
         valid_to = current_date,
         status = 'retired', updated_at = now()
   where tenant_id = v_tenant and id = p_delegation_id;

  perform erp.append_event('approval.cover_ended', 'approval', p_delegation_id,
    jsonb_build_object('reason', p_reason));

  return jsonb_build_object('delegation_id', p_delegation_id, 'status', 'retired');
end;
$$;

-- -----------------------------------------------------------------------------
-- Stamping a captured document
-- -----------------------------------------------------------------------------

create or replace function public.erp_stamp_document_approval(p_document_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        record;
  v_value  bigint;
  v_dept   uuid;
  v_chain  jsonb;
begin
  perform erp.authorise('documents.capture');

  select doc.id, doc.entity_id, doc.site_id, doc.currency, doc.created_by,
         dt.code as type_code
    into d
    from erp.document doc
    join erp.document_type dt on dt.tenant_id = doc.tenant_id and dt.id = doc.document_type_id
   where doc.tenant_id = v_tenant and doc.id = p_document_id;

  if d.id is null then
    raise exception 'ERPWARE_DOCUMENT_UNKNOWN: no such document' using errcode = '23503';
  end if;

  select coalesce(sum(l.net_minor + coalesce(l.tax_minor, 0)), 0)::bigint into v_value
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id
     and not l.is_cancelled;

  -- The department in force for whoever raised it, at the date it was raised.
  select pd.department_id into v_dept
    from erp.principal_department pd
   where pd.tenant_id = v_tenant
     and pd.app_user_id = d.created_by
     and pd.is_primary
     and pd.status = 'active'
     and daterange(pd.valid_from, pd.valid_to, '[)') @> current_date
   limit 1;

  v_chain := erp.resolve_approval_chain(
    lower(d.type_code), v_value, coalesce(d.currency, 'GBP')::char(3),
    v_dept, d.created_by, d.entity_id, d.site_id);

  insert into erp.approval_routing_stamp (
    tenant_id, object_type, object_id, department_id, value_minor, currency,
    resolved_chain, resolved_by)
  values (v_tenant, 'document', p_document_id, v_dept, v_value,
          coalesce(d.currency, 'GBP')::char(3), v_chain, erp.current_principal_id());

  perform erp.append_event('approval.chain_resolved', 'approval', p_document_id,
    v_chain || jsonb_build_object('document_id', p_document_id, 'type_code', d.type_code));

  if exists (select 1 from jsonb_array_elements(v_chain->'steps') st
              where (st->>'covered')::boolean) then
    perform erp.append_event('approval.cover_applied', 'approval', p_document_id, v_chain);
  end if;

  return v_chain;
end;
$$;

create or replace function public.erp_document_approval_chain(p_document_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('documents.read');
  select coalesce(jsonb_agg(jsonb_build_object(
           'stamp_id', s.id, 'resolved_at', s.resolved_at,
           'value_minor', s.value_minor, 'currency', s.currency,
           'resolved_chain', s.resolved_chain) order by s.resolved_at desc), '[]'::jsonb)
    into v_out
    from erp.approval_routing_stamp s
   where s.tenant_id = erp.current_tenant_id()
     and s.object_type = 'document'
     and s.object_id = p_document_id;
  return v_out;
end;
$$;

-- -----------------------------------------------------------------------------
-- The audit view: one row per resolved step, with the rule version that chose it
-- -----------------------------------------------------------------------------

create or replace function public.erp_approval_audit(
  p_object_type text default null,
  p_limit       integer default 200
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.audit_read');
  select coalesce(jsonb_agg(x order by x->>'resolved_at' desc, (x->>'seq')::int), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'stamp_id', s.id, 'resolved_at', s.resolved_at,
      'object_type', s.object_type, 'object_id', s.object_id,
      'department_code', dep.code,
      'value_minor', s.value_minor, 'currency', s.currency,
      'requester', req.display_name,
      'seq', (st->>'seq')::int,
      'source', st->>'source',
      'rule_id', st->>'rule_id',
      'rule_version', (st->>'rule_version')::int,
      'band_seq', (st->>'band_seq')::int,
      'approver', act.display_name,
      'approver_of_record', rec.display_name,
      'covered', coalesce((st->>'covered')::boolean, false),
      'cover_kind', st->>'cover_kind',
      'cover_trail', coalesce(st->'cover_trail', '[]'::jsonb)) as x
      from erp.approval_routing_stamp s
      cross join lateral jsonb_array_elements(coalesce(s.resolved_chain->'steps', '[]'::jsonb)) st
      left join erp.department dep on dep.tenant_id = s.tenant_id and dep.id = s.department_id
      left join erp.app_user req on req.tenant_id = s.tenant_id
                                and req.id = nullif(s.resolved_chain->>'requester','')::uuid
      left join erp.app_user act on act.tenant_id = s.tenant_id
                                and act.id = nullif(st->>'approver_user_id','')::uuid
      left join erp.app_user rec on rec.tenant_id = s.tenant_id
                                and rec.id = nullif(st->>'approver_of_record_user_id','')::uuid
     where s.tenant_id = erp.current_tenant_id()
       and (p_object_type is null or s.object_type = p_object_type)
     order by s.resolved_at desc
     limit least(greatest(coalesce(p_limit, 200), 1), 1000)
  ) q;
  return v_out;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_approval_delegations(boolean)',
    'public.erp_delegate_approval(uuid,uuid,timestamptz,timestamptz,text,text,bigint,bigint,text)',
    'public.erp_end_approval_delegation(uuid,text)',
    'public.erp_stamp_document_approval(uuid)',
    'public.erp_document_approval_chain(uuid)',
    'public.erp_approval_audit(text,integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;

select erp.apply_row_security();