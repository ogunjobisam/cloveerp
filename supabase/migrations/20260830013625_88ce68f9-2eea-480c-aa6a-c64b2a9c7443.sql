
-- 1. Currencies: the minor-unit exponent the client needs to render money.
create or replace function public.erp_currencies()
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', c.code, 'name', c.name, 'minor_units', c.minor_units)
           order by c.code), '[]'::jsonb)
    from erp_ref.currency c
   where c.is_active
$$;

-- 2. Document types configured by this tenant, with the permission
--    erp.open_document will actually authorise, derived from the same rule.
create or replace function public.erp_document_types(p_base_type_code text default null)
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'document_type_id', dt.id,
           'code', dt.code,
           'name', dt.name,
           'base_type_code', dt.base_type_code,
           'requires_party', bt.requires_party,
           'requires_site', bt.requires_site,
           'create_permission',
             case when bt.flow = 'inbound' then 'procurement.receive'
                  when dt.code = 'requisition' then 'procurement.requisition'
                  else 'procurement.order' end)
           order by dt.code), '[]'::jsonb)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = erp.current_tenant_id()
     and dt.status = 'active'::erp.record_status
     and (p_base_type_code is null or dt.base_type_code = p_base_type_code)
$$;

-- 3. Parties, optionally narrowed to a role (customer, supplier).
create or replace function public.erp_parties(p_role_kind text default null,
                                              p_search text default null)
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'party_id', p.id, 'code', p.code, 'name', p.name,
           'country_code', p.country_code, 'status', p.status,
           'roles', coalesce((
             select jsonb_agg(distinct r.role_kind)
               from erp.party_role r
              where r.tenant_id = p.tenant_id and r.party_id = p.id), '[]'::jsonb))
           order by p.code), '[]'::jsonb)
    from erp.party p
   where p.tenant_id = erp.current_tenant_id()
     and p.merged_into_id is null
     and p.status = 'active'::erp.record_status
     and (p_role_kind is null or exists (
           select 1 from erp.party_role r
            where r.tenant_id = p.tenant_id and r.party_id = p.id
              and r.role_kind::text = p_role_kind))
     and (p_search is null or p.name ilike '%'||p_search||'%' or p.code ilike '%'||p_search||'%')
$$;

-- 4. Items.
create or replace function public.erp_items(p_search text default null)
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'item_id', i.id, 'code', i.code, 'name', i.name,
           'item_class', i.item_class, 'lifecycle', i.lifecycle,
           'is_batch_controlled', i.is_batch_controlled,
           'status', i.status)
           order by i.code), '[]'::jsonb)
    from erp.item i
   where i.tenant_id = erp.current_tenant_id()
     and i.merged_into_id is null
     and i.status = 'active'::erp.record_status
     and (p_search is null or i.name ilike '%'||p_search||'%' or i.code ilike '%'||p_search||'%')
$$;

-- 5. What may happen to this document next, with "may not" and "not yet"
--    kept apart.
create or replace function public.erp_available_transitions(p_document_id uuid)
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', t.transition_code, 'name', t.name, 'to_state', t.to_state,
           'guard_passes', coalesce(t.guard_passes, true),
           'permitted', t.permitted, 'is_automatic', t.is_automatic)), '[]'::jsonb)
    from erp.available_transitions('document', p_document_id) t
$$;

-- 6. erp_document returned transitions without the two facts the screen needs
--    to tell "you may not" from "not yet", so every button was filtered out.
create or replace function public.erp_document(p_document_id uuid)
returns jsonb
language sql
stable
set search_path to ''
as $$
  select jsonb_build_object(
    'document', (
      select jsonb_build_object(
        'document_id', d.id, 'document_number', d.document_number,
        'document_type', dt.code, 'document_date', d.document_date,
        'currency', d.currency, 'party', p.name,
        'their_reference', d.their_reference,
        'total_minor', erp.document_value_minor(d.id),
        'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed)
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
        left join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        left join erp.state s on s.id = os.current_state_id
       where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'line_id', l.id, 'line_no', l.line_no, 'description', l.description,
        'quantity', l.quantity, 'unit_price_minor', l.unit_price_minor,
        'net_minor', l.net_minor, 'item', i.code) order by l.line_no)
        from erp.document_line l
        left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
       where l.tenant_id = erp.current_tenant_id() and l.document_id = p_document_id), '[]'::jsonb),
    'lineage', coalesce((
      select jsonb_agg(jsonb_build_object(
        'depth', depth, 'direction', direction, 'document_id', document_id,
        'document_number', document_number, 'base_type', base_type,
        'relation', relation_kind) order by depth)
        from erp.document_lineage(p_document_id)), '[]'::jsonb),
    'available_transitions', public.erp_available_transitions(p_document_id))
$$;

-- 7. Assurance ran every assertion as the caller, and the caller cannot read
--    erp_meta — so all nine reported "violated" when nothing was wrong. The
--    checks read structure, never tenant data, so running them as the owner
--    is the honest fix.
create or replace function public.erp_platform_assurance()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_result jsonb := '[]'::jsonb;
  v_check  text;
  v_error  text;
begin
  foreach v_check in array array[
    'erp.assert_isolation',
    'erp.assert_audit_coverage',
    'erp.assert_attribution_coverage',
    'erp.assert_session_context_hygiene',
    'erp.assert_gateway_integrity',
    'erp.assert_scheduler_integrity',
    'erp.assert_governed_views_are_safe',
    'erp.assert_intelligence_boundary',
    'erp.assert_public_api_safe'
  ] loop
    begin
      execute format('select %s()', v_check);
      v_error := null;
    exception when others then
      v_error := sqlerrm;
    end;

    v_result := v_result || jsonb_build_object(
      'check', v_check, 'ok', v_error is null, 'detail', v_error);
  end loop;

  return v_result;
end;
$$;

grant execute on function public.erp_currencies() to authenticated;
grant execute on function public.erp_document_types(text) to authenticated;
grant execute on function public.erp_parties(text, text) to authenticated;
grant execute on function public.erp_items(text) to authenticated;
grant execute on function public.erp_available_transitions(uuid) to authenticated;
grant execute on function public.erp_document(uuid) to authenticated;
grant execute on function public.erp_platform_assurance() to authenticated;
