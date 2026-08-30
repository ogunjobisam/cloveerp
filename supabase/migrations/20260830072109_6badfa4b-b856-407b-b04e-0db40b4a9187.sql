-- Audit log read wrapper (gated on administration.audit_read via erp.authorise,
-- which writes an access-decision audit row, so the function is volatile).
create or replace function public.erp_audit_log(
  p_action text default null,
  p_object_type text default null,
  p_actor text default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 200
) returns jsonb
language plpgsql
set search_path to ''
as $function$
declare v_tenant uuid;
begin
  perform erp.authorise('administration.audit_read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(x order by x_occurred_at desc) from (
      select jsonb_build_object(
        'id', e.id,
        'occurred_at', e.occurred_at,
        'recorded_at', e.recorded_at,
        'actor', e.actor_label,
        'actor_kind', e.actor_kind,
        'action', e.action,
        'object_type', e.object_type,
        'object_key', e.object_key,
        'changed_fields', e.changed_fields,
        'reason', e.reason,
        'data_class', e.data_class,
        'source', e.source
      ) as x, e.occurred_at as x_occurred_at
        from erp.audit_entry e
       where e.tenant_id = v_tenant
         and (p_action is null or e.action = p_action::erp.audit_action)
         and (p_object_type is null or e.object_type = p_object_type)
         and (p_actor is null or e.actor_label ilike '%' || p_actor || '%')
         and (p_from is null or e.occurred_at >= p_from)
         and (p_to is null or e.occurred_at < p_to + interval '1 day')
       order by e.occurred_at desc
       limit least(greatest(coalesce(p_limit, 200), 1), 1000)) t), '[]'::jsonb);
end;
$function$;

revoke all on function public.erp_audit_log(text, text, text, timestamptz, timestamptz, integer) from public, anon;
grant execute on function public.erp_audit_log(text, text, text, timestamptz, timestamptz, integer) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_audit_log', 'erp.authorise',
        'Read wrapper for erp.audit_entry, gated on administration.audit_read inside erp.authorise(), which writes an access-decision audit row. That audited write is the only write and the reason the function is volatile.')
on conflict (function_name) do nothing;

-- Seed the resource keys every screen already references (spec §7). Fallbacks
-- stop being the rendered text; tenant overrides can now change the wording.
insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('module.inventory',   'en', 'Inventory',          'inventory',      'Module title'),
  ('module.finance',     'en', 'Finance',            'finance',        'Module title'),
  ('module.planning',    'en', 'Planning',           'planning',       'Module title'),
  ('module.production',  'en', 'Production',         'production',     'Module title'),
  ('module.quality',     'en', 'Quality and recall', 'quality',        'Module title'),
  ('module.logistics',   'en', 'Logistics',          'logistics',      'Module title'),
  ('module.reporting',   'en', 'Reporting',          'reporting',      'Module title'),
  ('nav.sales',          'en', 'Sales',              'sales',          'Navigation tile'),
  ('nav.procurement',    'en', 'Procurement',        'procurement',    'Navigation tile'),
  ('nav.master_data',    'en', 'Master data',        'master_data',    'Navigation tile'),
  ('nav.governance',     'en', 'Change requests',    'master_data',    'Navigation tile'),
  ('nav.imports',        'en', 'Imports',            'master_data',    'Navigation tile'),
  ('nav.operations_jobs','en', 'Scheduled jobs',     'administration', 'Navigation tile'),
  ('nav.operations_integrations', 'en', 'Integrations', 'administration', 'Navigation tile'),
  ('nav.operations_assurance',    'en', 'Assurance',    'administration', 'Navigation tile'),
  ('nav.administration_configuration', 'en', 'Configuration', 'administration', 'Navigation tile'),
  ('nav.administration_permissions',   'en', 'Permissions',   'administration', 'Navigation tile'),
  ('nav.terminology',    'en', 'Terminology',        'administration', 'Navigation tile'),
  ('nav.tenant',         'en', 'Tenant lifecycle',   'administration', 'Navigation tile'),
  ('nav.audit',          'en', 'Audit log',          'administration', 'Navigation tile'),
  ('audit.title',        'en', 'Audit log',          'administration', 'Audit screen title'),
  ('audit.blurb',        'en', 'Every recorded action in this tenant: who did what, to which object, and when.', 'administration', 'Audit screen subtitle'),
  ('audit.filter_action','en', 'Action',             'administration', 'Filter label'),
  ('audit.filter_object','en', 'Object type',        'administration', 'Filter label'),
  ('audit.filter_actor', 'en', 'Actor',              'administration', 'Filter label'),
  ('audit.filter_from',  'en', 'From',               'administration', 'Filter label'),
  ('audit.filter_to',    'en', 'To',                 'administration', 'Filter label'),
  ('audit.apply',        'en', 'Apply filters',      'administration', 'Filter button'),
  ('audit.empty',        'en', 'No audit entries match these filters.', 'administration', 'Empty state'),
  ('audit.col_when',     'en', 'When',               'administration', 'Column header'),
  ('audit.col_actor',    'en', 'Actor',              'administration', 'Column header'),
  ('audit.col_action',   'en', 'Action',             'administration', 'Column header'),
  ('audit.col_object',   'en', 'Object',             'administration', 'Column header'),
  ('audit.col_fields',   'en', 'Changed fields',     'administration', 'Column header'),
  ('audit.col_reason',   'en', 'Reason',             'administration', 'Column header')
on conflict (key, locale) do nothing;
