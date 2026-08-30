
-- ---------------------------------------------------------------- lists
create or replace function public.erp_works_orders(p_limit integer default 100)
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'order_number' desc), '[]'::jsonb) from (
    select jsonb_build_object('works_order_id', w.id, 'order_number', w.order_number,
      'kind', w.order_kind, 'item', i.code, 'item_name', i.name, 'site', s.code,
      'quantity', w.quantity, 'completed', w.quantity_completed, 'scrapped', w.quantity_scrapped,
      'status', w.status, 'planned_start', w.planned_start, 'planned_end', w.planned_end) as x
      from erp.works_order w
      join erp.item i on i.tenant_id = w.tenant_id and i.id = w.item_id
      left join erp.site s on s.tenant_id = w.tenant_id and s.id = w.site_id
     where w.tenant_id = erp.current_tenant_id()
     order by w.order_number desc limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_quality_events(p_limit integer default 100)
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'occurred_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('quality_event_id', q.id, 'reference', q.reference,
      'kind', q.event_kind, 'severity', q.severity, 'title', q.title, 'status', q.status,
      'item', i.code, 'occurred_at', q.occurred_at, 'due_at', q.due_at,
      'closed_at', q.closed_at) as x
      from erp.quality_event q
      left join erp.item i on i.tenant_id = q.tenant_id and i.id = q.item_id
     where q.tenant_id = erp.current_tenant_id()
     order by q.occurred_at desc limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_recalls()
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('recall_id', r.id, 'reference', r.reference,
    'title', r.title, 'classification', r.classification, 'status', r.status,
    'initiated_at', r.initiated_at, 'deadline_at', r.regulatory_deadline_at,
    'closed_at', r.closed_at, 'batches', coalesce(array_length(r.scope_batch_ids, 1), 0))
    order by r.initiated_at desc), '[]'::jsonb)
    from erp.recall r where r.tenant_id = erp.current_tenant_id()
$$;

create or replace function public.erp_shipments(p_limit integer default 100)
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'planned_despatch' desc nulls last), '[]'::jsonb) from (
    select jsonb_build_object('shipment_id', sh.id, 'reference', sh.reference,
      'status', sh.status, 'carrier', c.name, 'service_code', sh.service_code,
      'planned_despatch', sh.planned_despatch, 'planned_arrival', sh.planned_arrival,
      'actual_despatch', sh.actual_despatch, 'actual_arrival', sh.actual_arrival,
      'destination', p.name, 'freight_cost_minor', sh.freight_cost_minor,
      'currency', sh.currency, 'tracking_reference', sh.tracking_reference) as x
      from erp.shipment sh
      left join erp.party c on c.tenant_id = sh.tenant_id and c.id = sh.carrier_id
      left join erp.party p on p.tenant_id = sh.tenant_id and p.id = sh.destination_party_id
     where sh.tenant_id = erp.current_tenant_id()
     order by sh.planned_despatch desc nulls last limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_batches(p_limit integer default 200)
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'batch_number'), '[]'::jsonb) from (
    select jsonb_build_object('batch_id', b.id, 'batch_number', b.batch_number,
      'item', i.code, 'item_name', i.name, 'status', b.status,
      'manufactured_on', b.manufactured_on, 'expires_on', b.expires_on,
      'supplier_lot', b.supplier_lot, 'origin_country', b.origin_country) as x
      from erp.batch b
      join erp.item i on i.tenant_id = b.tenant_id and i.id = b.item_id
     where b.tenant_id = erp.current_tenant_id()
     order by b.batch_number limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_planned_orders(p_site_id uuid default null, p_limit integer default 200)
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'required_by'), '[]'::jsonb) from (
    select jsonb_build_object('planned_order_id', po.id, 'kind', po.order_kind,
      'item', i.code, 'item_name', i.name, 'site', s.code, 'quantity', po.quantity,
      'required_by', po.required_by, 'release_on', po.release_on, 'status', po.status,
      'converted', po.converted_document_id is not null) as x
      from erp.planned_order po
      join erp.item i on i.tenant_id = po.tenant_id and i.id = po.item_id
      left join erp.site s on s.tenant_id = po.tenant_id and s.id = po.site_id
     where po.tenant_id = erp.current_tenant_id()
       and (p_site_id is null or po.site_id = p_site_id)
     order by po.required_by limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_planning_exceptions(p_limit integer default 200)
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'last_seen_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('exception_id', e.id, 'kind', e.exception_kind,
      'severity', e.severity, 'message', e.message, 'item', i.code, 'site', s.code,
      'first_seen_at', e.first_seen_at, 'last_seen_at', e.last_seen_at,
      'acknowledged_at', e.acknowledged_at, 'resolved_at', e.resolved_at) as x
      from erp.planning_exception e
      left join erp.item i on i.tenant_id = e.tenant_id and i.id = e.item_id
      left join erp.site s on s.tenant_id = e.tenant_id and s.id = e.site_id
     where e.tenant_id = erp.current_tenant_id() and e.resolved_at is null
     order by e.last_seen_at desc limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_count_tasks(p_limit integer default 200)
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(x order by x->>'status'), '[]'::jsonb) from (
    select jsonb_build_object('task_id', c.id, 'item', i.code, 'site', s.code,
      'location', l.code, 'expected', c.expected_quantity, 'counted', c.counted_quantity,
      'variance', c.variance, 'within_tolerance', c.within_tolerance, 'status', c.status,
      'counted_at', c.counted_at, 'posted_at', c.posted_at) as x
      from erp.count_task c
      join erp.item i on i.tenant_id = c.tenant_id and i.id = c.item_id
      left join erp.site s on s.tenant_id = c.tenant_id and s.id = c.site_id
      left join erp.location l on l.tenant_id = c.tenant_id and l.id = c.location_id
     where c.tenant_id = erp.current_tenant_id()
     order by c.status, c.created_at desc limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_fiscal_periods()
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('fiscal_period_id', f.id, 'code', f.code,
    'ledger', l.code, 'ledger_kind', l.ledger_kind, 'fiscal_year', f.fiscal_year,
    'period_number', f.period_number, 'starts_on', f.starts_on, 'ends_on', f.ends_on,
    'status', f.status, 'closed_at', f.closed_at)
    order by f.fiscal_year desc, f.period_number desc), '[]'::jsonb)
    from erp.fiscal_period f
    join erp.ledger l on l.tenant_id = f.tenant_id and l.id = f.ledger_id
   where f.tenant_id = erp.current_tenant_id()
$$;

create or replace function public.erp_ledgers()
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('ledger_id', l.id, 'code', l.code,
    'name', l.name, 'kind', l.ledger_kind, 'currency', l.currency,
    'is_primary', l.is_primary, 'status', l.status) order by l.code), '[]'::jsonb)
    from erp.ledger l where l.tenant_id = erp.current_tenant_id()
$$;

-- --------------------------------------------- master data change requests
create or replace function public.erp_change_requests(p_object_type text default null)
returns jsonb language plpgsql stable set search_path to '' as $$
declare v_tenant uuid;
begin
  perform erp.authorise('master_data.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'change_request_id', cr.id, 'object_type', cr.object_type, 'object_id', cr.object_id,
      'status', cr.status, 'reason', cr.reason, 'proposed', cr.proposed,
      'before', cr.before_snapshot, 'requested_by', a.display_name,
      'created_at', cr.created_at, 'applied_at', cr.applied_at,
      'governance', erp.change_request_governance(cr.id))
      order by cr.created_at desc)
      from erp.change_request cr
      left join erp.app_user a on a.tenant_id = cr.tenant_id and a.id = cr.created_by
     where cr.tenant_id = v_tenant
       and (p_object_type is null or cr.object_type = p_object_type)), '[]'::jsonb);
end;
$$;

create or replace function public.erp_submit_change_request(p_request_id uuid)
returns jsonb language sql set search_path to '' as $$
  select jsonb_build_object('approval_request_id', erp.submit_change_request(p_request_id))
$$;

create or replace function public.erp_apply_change_request(p_request_id uuid)
returns jsonb language sql set search_path to '' as $$
  select jsonb_build_object('applied', erp.apply_change_request(p_request_id))
$$;

-- The approvals a principal is actually being asked for. Without this a
-- governed change request is a request nobody can see.
create or replace function public.erp_my_approvals()
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id', t.id, 'approval_request_id', t.approval_request_id,
    'object_type', ar.object_type, 'object_id', ar.object_id,
    'seq', t.seq, 'status', t.status, 'assigned_at', t.created_at,
    'requested_by', a.display_name, 'requested_at', ar.requested_at,
    'context', ar.context) order by t.created_at), '[]'::jsonb)
    from erp.approval_task t
    join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
    left join erp.app_user a on a.tenant_id = ar.tenant_id and a.id = ar.requested_by
   where t.tenant_id = erp.current_tenant_id()
     and t.status = 'pending'::erp.approval_task_status
     and (t.assignee_user_id = erp.current_principal_id()
          or exists (select 1 from erp.effective_permission ep
                      where ep.app_user_id = erp.current_principal_id()
                        and ep.role_id = t.assignee_role_id))
$$;

create or replace function public.erp_decide_approval(p_task_id uuid, p_approve boolean, p_comment text default null)
returns jsonb language sql set search_path to '' as $$
  select jsonb_build_object('status', erp.decide_approval_task(p_task_id, p_approve, p_comment))
$$;

-- ------------------------------------------------------------- imports
create or replace function public.erp_import_batches(p_limit integer default 50)
returns jsonb language plpgsql stable set search_path to '' as $$
declare v_tenant uuid;
begin
  perform erp.authorise('master_data.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object('batch_id', b.id, 'code', b.code, 'object_type', b.object_type,
        'source', b.source, 'status', b.status, 'row_count', b.row_count,
        'error_count', b.error_count, 'loaded_at', b.loaded_at,
        'rolled_back_at', b.rolled_back_at, 'created_at', b.created_at,
        'rows', coalesce((select jsonb_agg(jsonb_build_object(
                 'row_no', r.row_no, 'action', r.action, 'raw', r.raw,
                 'findings', r.findings, 'loaded', r.loaded) order by r.row_no)
                 from erp.import_row r where r.import_batch_id = b.id), '[]'::jsonb)) as x
        from erp.import_batch b
       where b.tenant_id = v_tenant
       order by b.created_at desc limit greatest(p_limit, 1)) t), '[]'::jsonb);
end;
$$;

create or replace function public.erp_preview_import(p_batch_id uuid)
returns jsonb language sql set search_path to '' as $$
  select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from erp.preview_import(p_batch_id) p
$$;

create or replace function public.erp_validate_import(p_batch_id uuid)
returns jsonb language sql set search_path to '' as $$
  select jsonb_build_object('errors', erp.validate_import(p_batch_id))
$$;

drop function if exists public.erp_rollback_import(uuid);
create or replace function public.erp_rollback_import(p_batch_id uuid)
returns jsonb language sql set search_path to '' as $$
  select jsonb_build_object('reversed', erp.rollback_import(p_batch_id))
$$;

-- ------------------------------------------------- interface resources
-- Product strings with the tenant's overrides applied. The interface reads
-- this rather than holding literals, so terminology is configuration.
create or replace function public.erp_resources(p_locale text default 'en')
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from (
    select r.key,
           coalesce(
             (select o.value from erp.resource_override o
               where o.tenant_id = erp.current_tenant_id()
                 and o.key = r.key and o.locale = r.locale
                 and o.status = 'active'::erp.record_status limit 1),
             r.value) as value
      from erp_ref.resource r
     where r.locale = coalesce(p_locale, 'en')) s
$$;

create or replace function public.erp_resource_catalog(p_locale text default 'en')
returns jsonb language sql stable set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'key', r.key, 'locale', r.locale, 'module_code', r.module_code,
    'product_value', r.value,
    'override', (select o.value from erp.resource_override o
                  where o.tenant_id = erp.current_tenant_id()
                    and o.key = r.key and o.locale = r.locale
                    and o.status = 'active'::erp.record_status limit 1))
    order by r.key), '[]'::jsonb)
    from erp_ref.resource r where r.locale = coalesce(p_locale, 'en')
$$;

create or replace function public.erp_set_resource_override(p_key text, p_value text,
                                                            p_locale text default 'en',
                                                            p_note text default null)
returns jsonb language plpgsql set search_path to '' as $$
declare v_tenant uuid; v_id uuid;
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.current_tenant_id();

  if not exists (select 1 from erp_ref.resource r
                  where r.key = p_key and r.locale = coalesce(p_locale, 'en')) then
    raise exception 'ERPWARE_VALIDATION: no such resource key in this locale';
  end if;

  if p_value is null or btrim(p_value) = '' then
    delete from erp.resource_override o
     where o.tenant_id = v_tenant and o.key = p_key and o.locale = coalesce(p_locale, 'en');
    return jsonb_build_object('key', p_key, 'override', null);
  end if;

  insert into erp.resource_override (tenant_id, key, locale, value, note, status, created_by)
  values (v_tenant, p_key, coalesce(p_locale, 'en'), p_value, p_note,
          'active'::erp.record_status, erp.current_principal_id())
  on conflict (tenant_id, key, locale, entity_id) do update
    set value = excluded.value, note = excluded.note,
        status = 'active'::erp.record_status,
        updated_at = now(), updated_by = erp.current_principal_id()
  returning id into v_id;

  return jsonb_build_object('key', p_key, 'override_id', v_id);
end;
$$;

-- --------------------------------------------------- tenant lifecycle
-- Portability, in one call, in open form. Whoever can read a domain can
-- export it, so the export authorises as administration.read and carries
-- only what this tenant owns.
create or replace function public.erp_export_tenant()
returns jsonb language plpgsql stable set search_path to '' as $$
declare v_tenant uuid; v_out jsonb;
begin
  perform erp.authorise('administration.read');
  v_tenant := erp.current_tenant_id();

  select jsonb_build_object(
    'exported_at', now(),
    'format', 'erpware.tenant-export.v1',
    'tenant', (select to_jsonb(t) from erp.tenant t where t.id = v_tenant),
    'entities', coalesce((select jsonb_agg(to_jsonb(e)) from erp.entity e where e.tenant_id = v_tenant), '[]'::jsonb),
    'sites', coalesce((select jsonb_agg(to_jsonb(s)) from erp.site s where s.tenant_id = v_tenant), '[]'::jsonb),
    'locations', coalesce((select jsonb_agg(to_jsonb(l)) from erp.location l where l.tenant_id = v_tenant), '[]'::jsonb),
    'principals', coalesce((select jsonb_agg(to_jsonb(u) - 'auth_user_id') from erp.app_user u where u.tenant_id = v_tenant), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(to_jsonb(r)) from erp.role r where r.tenant_id = v_tenant), '[]'::jsonb),
    'role_permissions', coalesce((select jsonb_agg(to_jsonb(rp)) from erp.role_permission rp where rp.tenant_id = v_tenant), '[]'::jsonb),
    'user_roles', coalesce((select jsonb_agg(to_jsonb(ur)) from erp.user_role ur where ur.tenant_id = v_tenant), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(i)) from erp.item i where i.tenant_id = v_tenant), '[]'::jsonb),
    'uoms', coalesce((select jsonb_agg(to_jsonb(u)) from erp.uom u where u.tenant_id = v_tenant), '[]'::jsonb),
    'parties', coalesce((select jsonb_agg(to_jsonb(p)) from erp.party p where p.tenant_id = v_tenant), '[]'::jsonb),
    'party_roles', coalesce((select jsonb_agg(to_jsonb(pr)) from erp.party_role pr where pr.tenant_id = v_tenant), '[]'::jsonb),
    'document_types', coalesce((select jsonb_agg(to_jsonb(dt)) from erp.document_type dt where dt.tenant_id = v_tenant), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(to_jsonb(d)) from erp.document d where d.tenant_id = v_tenant), '[]'::jsonb),
    'document_lines', coalesce((select jsonb_agg(to_jsonb(dl)) from erp.document_line dl where dl.tenant_id = v_tenant), '[]'::jsonb),
    'batches', coalesce((select jsonb_agg(to_jsonb(b)) from erp.batch b where b.tenant_id = v_tenant), '[]'::jsonb),
    'stock_movements', coalesce((select jsonb_agg(to_jsonb(m)) from erp.stock_movement m where m.tenant_id = v_tenant), '[]'::jsonb),
    'journals', coalesce((select jsonb_agg(to_jsonb(j)) from erp.journal j where j.tenant_id = v_tenant), '[]'::jsonb),
    'journal_lines', coalesce((select jsonb_agg(to_jsonb(jl)) from erp.journal_line jl where jl.tenant_id = v_tenant), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(ev)) from erp.event ev where ev.tenant_id = v_tenant), '[]'::jsonb),
    'audit', coalesce((select jsonb_agg(to_jsonb(al)) from erp.audit_log al where al.tenant_id = v_tenant), '[]'::jsonb),
    'resource_overrides', coalesce((select jsonb_agg(to_jsonb(ro)) from erp.resource_override ro where ro.tenant_id = v_tenant), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

-- Deletion is a request with a stated retention position, not a button that
-- drops rows: the purge itself runs under erp.begin_tenant_purge, which only
-- a trusted session may enter.
create or replace function public.erp_request_tenant_deletion(p_confirm_code text, p_reason text)
returns jsonb language plpgsql set search_path to '' as $$
declare v_tenant uuid; v_code text; v_overrides integer;
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.current_tenant_id();

  select t.code into v_code from erp.tenant t where t.id = v_tenant;
  if v_code is distinct from btrim(coalesce(p_confirm_code, '')) then
    raise exception 'ERPWARE_VALIDATION: the tenant code must be typed exactly to confirm deletion';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'ERPWARE_VALIDATION: a reason is required';
  end if;

  -- Suspension first: the tenant stops being operable the moment deletion is
  -- requested, so nothing new accumulates between request and purge.
  update erp.tenant t
     set status = 'suspended'::erp.tenant_status,
         suspended_at = now(),
         deleted_at = now(),
         retention_policy = coalesce(t.retention_policy, '{}'::jsonb)
                            || jsonb_build_object('deletion_requested_by', erp.current_principal_id(),
                                                  'deletion_requested_at', now(),
                                                  'deletion_reason', p_reason),
         updated_at = now(), updated_by = erp.current_principal_id()
   where t.id = v_tenant;

  -- Tenant-created wording is destroyed here rather than at purge, because it
  -- is the one class of tenant content that is also cached in every session.
  delete from erp.resource_override o where o.tenant_id = v_tenant;
  get diagnostics v_overrides = row_count;

  return jsonb_build_object('tenant_id', v_tenant, 'status', 'suspended',
                            'overrides_destroyed', v_overrides,
                            'note', 'Data is retained until the scheduled purge runs; export before then if portability is needed.');
end;
$$;

grant execute on function public.erp_works_orders(integer) to authenticated;
grant execute on function public.erp_quality_events(integer) to authenticated;
grant execute on function public.erp_recalls() to authenticated;
grant execute on function public.erp_shipments(integer) to authenticated;
grant execute on function public.erp_batches(integer) to authenticated;
grant execute on function public.erp_planned_orders(uuid, integer) to authenticated;
grant execute on function public.erp_planning_exceptions(integer) to authenticated;
grant execute on function public.erp_count_tasks(integer) to authenticated;
grant execute on function public.erp_fiscal_periods() to authenticated;
grant execute on function public.erp_ledgers() to authenticated;
grant execute on function public.erp_change_requests(text) to authenticated;
grant execute on function public.erp_submit_change_request(uuid) to authenticated;
grant execute on function public.erp_apply_change_request(uuid) to authenticated;
grant execute on function public.erp_my_approvals() to authenticated;
grant execute on function public.erp_decide_approval(uuid, boolean, text) to authenticated;
grant execute on function public.erp_import_batches(integer) to authenticated;
grant execute on function public.erp_preview_import(uuid) to authenticated;
grant execute on function public.erp_validate_import(uuid) to authenticated;
grant execute on function public.erp_rollback_import(uuid) to authenticated;
grant execute on function public.erp_resources(text) to authenticated;
grant execute on function public.erp_resource_catalog(text) to authenticated;
grant execute on function public.erp_set_resource_override(text, text, text, text) to authenticated;
grant execute on function public.erp_export_tenant() to authenticated;
grant execute on function public.erp_request_tenant_deletion(text, text) to authenticated;
