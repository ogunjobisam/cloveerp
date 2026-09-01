-- =============================================================================
-- Screens for the remaining v1.2 Parts: the doors they call
--
-- Parts 14, 15, 18, 19 and 23 were each built as schema and proven by
-- assertion, and each stopped at the same wall: the reports live in schema erp,
-- and the app calls schema public. erp.device_operations_report(),
-- erp.output_integrity_report(), erp.entitlement_report(),
-- erp.report_reproducibility_report() and erp.decision_enforcement_report() all
-- fail the build when something is wrong, and none of them could be read from
-- a screen. Nothing behind them changes here; this adds the public doors and
-- the two writes a screen needs that no function yet performed.
--
-- Part 14 — a scan-rule writer. erp.scan_rule was read by erp.evaluate_scan()
--   and written by nothing but a test suite, so §14.4's "rules per step and per
--   product class" could only be configured by a migration.
-- Part 15 — a printer writer that authorises. erp.upsert_printer() is the
--   promoter's routine and trusts that promotion already checked; called from a
--   screen it is administrative configuration and says so.
-- Part 18 — the commercial summary. erp_meta is platform_internal, so a
--   definer scoped to the caller's own organisation is the only way an
--   organisation sees its own plan, and a platform door is the only way staff
--   see every plan and subscription.
-- Part 23 — the product decisions themselves. Eighteen decisions and their
--   thirty-nine checks have been in erp_ref since D1 and no screen could show
--   them; erp_platform_policy_decisions() shows the deviations, not the
--   product.
--
-- Every door is revoked from anon before the transaction ends, because
-- Supabase's default privileges would otherwise leave it callable by nobody in
-- particular. The build fails at the end of this file if any door is
-- ungoverned.
-- =============================================================================

-- ── Part 14 — devices ────────────────────────────────────────────────────────

create or replace function public.erp_device_operations()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'finding', r.finding, 'reference', r.reference, 'detail', r.detail)
         order by r.finding, r.reference), '[]'::jsonb)
    from erp.device_operations_report() r;
$$;

-- Every action in the organisation, newest first, for the supervisor's view of
-- the queue. erp_device_queue(p_device_code) is the operator's own device and
-- stays as it is; this is the person asking why a pick has sat conflicted
-- since Tuesday.
create or replace function public.erp_device_actions()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by received_at desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', a.id, 'device', d.code, 'site', s.code,
             'task_code', a.device_task_code, 'status', a.status,
             'input_method', a.input_method, 'keyed_reason', a.keyed_reason,
             'captured_at', a.captured_at, 'received_at', a.received_at,
             'applied_at', a.applied_at, 'conflict_reason', a.conflict_reason,
             'payload', a.payload) as x,
           a.received_at
      from erp.device_action a
      join erp.device d on d.tenant_id = a.tenant_id and d.id = a.device_id
      join erp.site s on s.tenant_id = d.tenant_id and s.id = d.site_id
     order by a.received_at desc
     limit 500) t;
$$;

create or replace function public.erp_scan_rules()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by seq, item_class nulls first), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', r.id, 'task_code', r.device_task_code, 'task_name', t.name,
             'task_group', t.task_group, 'item_class', r.item_class,
             'accepted_symbologies', to_jsonb(r.accepted_symbologies),
             'mandatory_identifiers', to_jsonb(r.mandatory_identifiers),
             'when_absent', r.when_absent, 'updated_at', r.updated_at) as x,
           t.seq, r.item_class
      from erp.scan_rule r
      join erp_ref.device_task t on t.code = r.device_task_code
     where r.tenant_id = erp.require_tenant_id()) s;
$$;

-- The three registers a scan-rule form chooses from. Product data, readable by
-- every signed-in user, the same as erp_device_tasks().
create or replace function public.erp_device_classes()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', c.code, 'name', c.name, 'description', c.description,
           'is_handsfree', c.is_handsfree, 'seq', c.seq)
         order by c.seq), '[]'::jsonb)
    from erp_ref.device_class c;
$$;

create or replace function public.erp_symbologies()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', y.code, 'name', y.name, 'is_gs1', y.is_gs1,
           'is_two_dimensional', y.is_two_dimensional, 'note', y.note, 'seq', y.seq)
         order by y.seq), '[]'::jsonb)
    from erp_ref.symbology y;
$$;

create or replace function public.erp_gs1_application_identifiers()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'ai', a.ai, 'name', a.name, 'field_name', a.field_name,
           'data_length', a.data_length, 'is_numeric', a.is_numeric, 'note', a.note)
         order by a.ai), '[]'::jsonb)
    from erp_ref.gs1_application_identifier a;
$$;

-- The writer §14.4 never had. One rule per step and product class; a rule
-- naming no class is the step's default and erp.evaluate_scan() prefers the
-- specific one. Lists arrive comma-separated because that is what every other
-- door taking a list does and what a form field can produce.
create or replace function erp.upsert_scan_rule(p_task_code text,
                                                p_accepted_symbologies text,
                                                p_mandatory_identifiers text default null,
                                                p_when_absent text default 'exception_with_reason',
                                                p_item_class text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant     uuid := erp.require_tenant_id();
  v_id         uuid;
  v_accepted   text[];
  v_mandatory  text[];
  v_item_class text;
  v_unknown    text;
begin
  perform erp.authorise('administration.configure', null, null, null, 'scan_rule', null);

  if not exists (select 1 from erp_ref.device_task t where t.code = p_task_code) then
    raise exception 'ERPWARE_UNKNOWN_DEVICE_TASK: % is not a device task', p_task_code
      using errcode = '23503';
  end if;

  v_accepted := coalesce((
    select array_agg(lower(btrim(u.s)) order by u.ord)
      from unnest(string_to_array(coalesce(p_accepted_symbologies, ''), ','))
           with ordinality u(s, ord)
     where btrim(u.s) <> ''), '{}');

  if cardinality(v_accepted) = 0 then
    raise exception
      'ERPWARE_SCAN_RULE_ACCEPTS_NOTHING: a scan rule must accept at least one symbology'
      using errcode = '23514';
  end if;

  select string_agg(s, ', ' order by s) into v_unknown
    from unnest(v_accepted) s
   where not exists (select 1 from erp_ref.symbology y where y.code = s);
  if v_unknown is not null then
    raise exception 'ERPWARE_UNKNOWN_SYMBOLOGY: % is not a symbology this product reads',
      v_unknown using errcode = '23503';
  end if;

  -- Mandatory identifiers are GS1 application identifiers, matched by AI the
  -- way erp.evaluate_scan() matches them. A rule demanding an identifier the
  -- parser does not know would refuse every scan and never say why.
  v_mandatory := coalesce((
    select array_agg(btrim(u.s) order by u.ord)
      from unnest(string_to_array(coalesce(p_mandatory_identifiers, ''), ','))
           with ordinality u(s, ord)
     where btrim(u.s) <> ''), '{}');

  select string_agg(s, ', ' order by s) into v_unknown
    from unnest(v_mandatory) s
   where not exists (select 1 from erp_ref.gs1_application_identifier a where a.ai = s);
  if v_unknown is not null then
    raise exception
      'ERPWARE_UNKNOWN_APPLICATION_IDENTIFIER: % is not a GS1 application identifier this product parses',
      v_unknown using errcode = '23503';
  end if;

  if p_when_absent not in ('refuse', 'exception_with_reason', 'accept') then
    raise exception
      'ERPWARE_SCAN_RULE_WHEN_ABSENT: % is not refuse, exception_with_reason or accept',
      p_when_absent using errcode = '23514';
  end if;

  v_item_class := nullif(btrim(coalesce(p_item_class, '')), '');

  -- The unique constraint treats two nulls as distinct, so an upsert on it
  -- would insert a second default rule for the step. Update where the class is
  -- not distinct, then insert.
  update erp.scan_rule r
     set accepted_symbologies  = v_accepted,
         mandatory_identifiers = v_mandatory,
         when_absent           = p_when_absent
   where r.tenant_id = v_tenant
     and r.device_task_code = p_task_code
     and r.item_class is not distinct from v_item_class
  returning r.id into v_id;

  if v_id is null then
    insert into erp.scan_rule (tenant_id, device_task_code, item_class,
                               accepted_symbologies, mandatory_identifiers, when_absent)
    values (v_tenant, p_task_code, v_item_class, v_accepted, v_mandatory, p_when_absent)
    returning id into v_id;
  end if;

  return v_id;
end;
$$;

create or replace function public.erp_upsert_scan_rule(p_task_code text,
                                                        p_accepted_symbologies text,
                                                        p_mandatory_identifiers text default null,
                                                        p_when_absent text default 'exception_with_reason',
                                                        p_item_class text default null)
returns uuid
language sql
set search_path = ''
as $$
  select erp.upsert_scan_rule(p_task_code, p_accepted_symbologies, p_mandatory_identifiers,
                              p_when_absent, p_item_class);
$$;

-- ── Part 15 — output ─────────────────────────────────────────────────────────

create or replace function public.erp_output_integrity()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'finding', r.finding, 'reference', r.reference, 'detail', r.detail)
         order by r.finding, r.reference), '[]'::jsonb)
    from erp.output_integrity_report() r;
$$;

create or replace function public.erp_output_template_versions()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by template_code, version desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', v.id, 'template_code', t.code, 'name_key', t.name_key,
             'kind', t.kind, 'base_type_code', t.base_type_code,
             'version', v.version, 'rendering_engine', v.rendering_engine,
             'page', v.page, 'label_language', v.label_language,
             'required_permission', v.required_permission, 'status', v.status,
             'effective_from', v.effective_from, 'effective_to', v.effective_to,
             'decode_check_passed', v.decode_check_passed,
             'decoded_value', v.decoded_value,
             'block_count', case when jsonb_typeof(v.blocks) = 'array'
                                 then jsonb_array_length(v.blocks) end,
             'note', v.note) as x,
           t.code as template_code, v.version
      from erp.output_template_version v
      join erp.output_template t on t.tenant_id = v.tenant_id and t.id = v.output_template_id) s;
$$;

create or replace function public.erp_printers()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x ->> 'code'), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', p.id, 'code', p.code, 'name', p.name, 'site', s.code,
             'printer_type', p.printer_type, 'language', p.language,
             'dots_per_inch', p.dots_per_inch,
             'physical_location', p.physical_location,
             'default_stock', p.default_stock, 'queue_address', p.queue_address,
             'status', p.status, 'updated_at', p.updated_at) as x
      from erp.printer p
      join erp.site s on s.tenant_id = p.tenant_id and s.id = p.site_id) t;
$$;

-- erp.upsert_printer() does not authorise, because the promoter that calls it
-- checked at approval. From a screen there is no approval, so the door checks.
-- erp.printer is a promotable surface: on a live organisation the guard
-- refuses a direct write and the screen shows the refusal, which is the rule
-- working, not the door failing. The screen picks a site from the session, so
-- the door takes the site's id and resolves the code the writer wants.
create or replace function public.erp_upsert_printer(p_code text,
                                                      p_site_id uuid,
                                                      p_name text,
                                                      p_printer_type text,
                                                      p_language text default null,
                                                      p_dots_per_inch integer default null,
                                                      p_physical_location text default null,
                                                      p_default_stock text default null,
                                                      p_queue_address text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_site_code text;
begin
  perform erp.authorise('administration.configure', null, p_site_id, null, 'printer', null);
  select s.code into v_site_code
    from erp.site s
   where s.tenant_id = erp.require_tenant_id() and s.id = p_site_id;
  if v_site_code is null then
    raise exception 'ERPWARE_UNKNOWN_SITE: % is not a site of this organisation', p_site_id
      using errcode = '23503';
  end if;
  return erp.upsert_printer(p_code, v_site_code, p_name, p_printer_type, p_language,
                            p_dots_per_inch, p_physical_location, p_default_stock,
                            p_queue_address);
end;
$$;

-- One row per request with its latest render and that render's latest
-- delivery, newest first. §15.5's audit trail is here: what was asked for,
-- what came out, whether it arrived.
create or replace function public.erp_output_requests()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by requested_at desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', q.id, 'template_code', t.code, 'version', r.version,
             'object_type', q.object_type, 'object_id', q.object_id,
             'destination_kind', q.destination_kind, 'printer', p.code,
             'locale', q.locale, 'copies', q.copies,
             'triggering_event', q.triggering_event,
             'requested_by', u.display_name, 'requested_at', q.requested_at,
             'rendered_at', r.rendered_at, 'format', r.format,
             'checksum', r.checksum, 'byte_size', r.byte_size,
             'document_reference', r.document_reference, 'is_copy', r.is_copy,
             'delivery_status', d.status, 'destination', d.destination,
             'attempts', d.attempts, 'confirmed_at', d.confirmed_at,
             'failure_reason', d.failure_reason) as x,
           q.requested_at
      from erp.output_request q
      join erp.output_template t on t.tenant_id = q.tenant_id and t.id = q.output_template_id
      left join erp.printer p on p.tenant_id = q.tenant_id and p.id = q.printer_id
      left join erp.app_user u on u.tenant_id = q.tenant_id and u.id = q.requested_by
      left join lateral (
        select * from erp.output_render r
         where r.tenant_id = q.tenant_id and r.output_request_id = q.id
         order by r.rendered_at desc limit 1) r on true
      left join lateral (
        select * from erp.output_delivery d
         where d.tenant_id = r.tenant_id and d.output_render_id = r.id
         order by d.updated_at desc limit 1) d on true
     order by q.requested_at desc
     limit 500) s;
$$;

create or replace function public.erp_email_suppressions()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by suppressed_at desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', e.id, 'address', e.address, 'reason', e.reason,
             'is_permanent', e.is_permanent, 'suppressed_at', e.suppressed_at,
             'note', e.note) as x,
           e.suppressed_at
      from erp.email_suppression e) s;
$$;

-- ── Part 18 — commercial ─────────────────────────────────────────────────────

-- The organisation's own plan, subscription, entitlements and meters, in one
-- read. erp_meta is platform_internal — row security on with no policy and a
-- blanket revoke — so the reader is a definer, scoped to the caller's own
-- tenant and gated on administration.read. §18.2 requires the meters to be
-- visible to the organisation continuously; this is where they become so.
create or replace function erp.commercial_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_plan   text;
begin
  perform erp.authorise('administration.read');
  v_plan := erp.tenant_plan_code(v_tenant);

  return jsonb_build_object(
    'plan', (select jsonb_build_object('code', p.code, 'name', p.name,
                                       'description', p.description)
               from erp_meta.plan p where p.code = v_plan),
    'subscription', (select jsonb_build_object(
                       'plan_code', s.plan_code, 'term_start', s.term_start,
                       'term_end', s.term_end, 'renews', s.renews,
                       'currency', s.currency, 'status', s.status, 'note', s.note)
                       from erp_meta.subscription s
                      where s.tenant_id = v_tenant and s.status <> 'terminated'
                      order by s.term_start desc
                      limit 1),
    'capabilities', coalesce((
      select jsonb_agg(pc.capability_code order by pc.capability_code)
        from erp_meta.plan_capability pc where pc.plan_code = v_plan), '[]'::jsonb),
    'entitlements', coalesce((
      select jsonb_agg(jsonb_build_object(
               'entitlement_code', e.entitlement_code, 'title', e.title, 'unit', e.unit,
               'limit_value', e.limit_value, 'used', e.used,
               'remaining', e.remaining, 'breached', e.breached)
             order by e.entitlement_code)
        from erp.entitlement_report(v_tenant) e), '[]'::jsonb),
    'meters', coalesce((
      select jsonb_agg(jsonb_build_object(
               'meter_code', m.meter_code, 'title', k.title, 'unit', k.unit,
               'period_start', m.period_start, 'period_end', m.period_end,
               'quantity', m.quantity, 'measured_at', m.measured_at)
             order by m.period_start desc, m.meter_code)
        from (select * from erp_meta.usage_meter u
               where u.tenant_id = v_tenant
               order by u.period_start desc, u.meter_code
               limit 48) m
        left join erp_meta.meter_kind k on k.code = m.meter_code), '[]'::jsonb));
end;
$$;

create or replace function public.erp_commercial_summary()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select erp.commercial_summary();
$$;

-- Every plan, what each entitles, and who is on it. Platform staff only:
-- subscriptions are the one thing in the product that is about money, and
-- an organisation sees its own through erp_commercial_summary().
create or replace function public.erp_platform_plans()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return jsonb_build_object(
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', p.code, 'name', p.name, 'description', p.description, 'seq', p.seq,
               'entitlements', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'entitlement_code', pe.entitlement_code, 'title', k.title,
                          'unit', k.unit, 'limit_value', pe.limit_value, 'note', pe.note)
                        order by pe.entitlement_code)
                   from erp_meta.plan_entitlement pe
                   left join erp_meta.entitlement_kind k on k.code = pe.entitlement_code
                  where pe.plan_code = p.code), '[]'::jsonb),
               'capabilities', coalesce((
                 select jsonb_agg(pc.capability_code order by pc.capability_code)
                   from erp_meta.plan_capability pc where pc.plan_code = p.code), '[]'::jsonb),
               'subscribers', (select count(*) from erp_meta.subscription s
                                where s.plan_code = p.code and s.status <> 'terminated'))
             order by p.seq)
        from erp_meta.plan p), '[]'::jsonb),
    'subscriptions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tenant_code', s.tenant_code, 'plan_code', s.plan_code,
               'term_start', s.term_start, 'term_end', s.term_end, 'renews', s.renews,
               'currency', s.currency, 'status', s.status, 'note', s.note,
               'updated_at', s.updated_at)
             order by s.tenant_code, s.term_start desc)
        from erp_meta.subscription s), '[]'::jsonb),
    'entitlement_kinds', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', k.code, 'title', k.title, 'unit', k.unit,
               'counts_what', k.counts_what)
             order by k.code)
        from erp_meta.entitlement_kind k), '[]'::jsonb),
    'findings', coalesce((
      select jsonb_agg(jsonb_build_object('finding', f.finding, 'detail', f.detail)
             order by f.finding)
        from erp.entitlement_enforcement_report() f), '[]'::jsonb));
end;
$$;

-- ── Part 19 — reports ────────────────────────────────────────────────────────

create or replace function public.erp_report_versions()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by report_code, version desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', v.id, 'report_code', r.code,
             'report_name', coalesce(r.name, r.name_key), 'module_code', r.module_code,
             'version', v.version, 'status', v.status,
             'governed_view', g.code,
             'source', case when g.id is null then null
                            else g.source_schema || '.' || g.source_name end,
             'columns', to_jsonb(v.columns), 'group_by', to_jsonb(v.group_by),
             'default_sort', to_jsonb(v.default_sort),
             'output_formats', to_jsonb(v.output_formats),
             'required_permission', v.required_permission,
             'time_budget_ms', v.time_budget_ms, 'row_cap', v.row_cap,
             'effective_from', v.effective_from, 'effective_to', v.effective_to,
             'note', v.note,
             'parameters', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'code', p.code, 'name_key', p.name_key, 'data_type', p.data_type,
                        'is_required', p.is_required, 'default_value', p.default_value,
                        'filters_column', p.filters_column)
                      order by p.code)
                 from erp.report_parameter p
                where p.tenant_id = v.tenant_id and p.report_version_id = v.id), '[]'::jsonb),
             'runs', (select count(*) from erp.report_run u
                       where u.tenant_id = v.tenant_id and u.report_version_id = v.id)) as x,
           r.code as report_code, v.version
      from erp.report_version v
      join erp.report r on r.tenant_id = v.tenant_id and r.id = v.report_id
      left join erp.governed_view g on g.tenant_id = v.tenant_id and g.id = v.governed_view_id) s;
$$;

create or replace function public.erp_report_runs()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by run_at desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', u.id, 'report_code', r.code, 'version', u.version,
             'parameters', u.parameters, 'run_by', a.display_name,
             'run_at', u.run_at, 'row_count', u.row_count,
             'duration_ms', u.duration_ms, 'outcome', u.outcome,
             'extract_reason', u.extract_reason) as x,
           u.run_at
      from erp.report_run u
      join erp.report r on r.tenant_id = u.tenant_id and r.id = u.report_id
      left join erp.app_user a on a.tenant_id = u.tenant_id and a.id = u.run_by
     order by u.run_at desc
     limit 500) s;
$$;

create or replace function public.erp_report_reproducibility()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'finding', r.finding, 'reference', r.reference, 'detail', r.detail)
         order by r.finding, r.reference), '[]'::jsonb)
    from erp.report_reproducibility_report() r;
$$;

-- ── Part 23 — product decisions ──────────────────────────────────────────────

-- The eighteen decisions the product is built on, each with the routines that
-- enforce it and whatever the enforcement report says today. Read-only, like
-- the policy decisions: a product decision is taken in a migration with its
-- checks beside it, and erp.assert_product_decisions_enforced() fails the
-- build when a check names a routine that is gone.
create or replace function public.erp_platform_product_decisions()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return (
    with f as (select * from erp.decision_enforcement_report())
    select coalesce(jsonb_agg(jsonb_build_object(
             'code', d.code, 'seq', d.seq, 'title', d.title,
             'decision', d.decision, 'rationale', d.rationale, 'cost', d.cost,
             'supersedes', d.supersedes, 'spec_reference', d.spec_reference,
             'registered_at', d.registered_at,
             'checks', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'schema_name', c.schema_name, 'routine_name', c.routine_name,
                        'note', c.note)
                      order by c.schema_name, c.routine_name)
                 from erp_ref.product_decision_check c
                where c.decision_code = d.code), '[]'::jsonb),
             'findings', coalesce((
               select jsonb_agg(jsonb_build_object('finding', f.finding, 'detail', f.detail)
                      order by f.finding)
                 from f where f.decision_code = d.code), '[]'::jsonb))
           order by d.seq), '[]'::jsonb)
      from erp_ref.product_decision d);
end;
$$;

-- ── Nobody in particular may not call any of this ────────────────────────────
--
-- Supabase carries DEFAULT PRIVILEGES on schema public that grant EXECUTE to
-- anon, so a new door is callable without signing in until it is revoked.

revoke all on function
  public.erp_device_operations(),
  public.erp_device_actions(),
  public.erp_scan_rules(),
  public.erp_device_classes(),
  public.erp_symbologies(),
  public.erp_gs1_application_identifiers(),
  public.erp_upsert_scan_rule(text, text, text, text, text),
  public.erp_output_integrity(),
  public.erp_output_template_versions(),
  public.erp_printers(),
  public.erp_upsert_printer(text, uuid, text, text, text, integer, text, text, text),
  public.erp_output_requests(),
  public.erp_email_suppressions(),
  public.erp_commercial_summary(),
  public.erp_platform_plans(),
  public.erp_report_versions(),
  public.erp_report_runs(),
  public.erp_report_reproducibility(),
  public.erp_platform_product_decisions()
  from public, anon;

grant execute on function
  public.erp_device_operations(),
  public.erp_device_actions(),
  public.erp_scan_rules(),
  public.erp_device_classes(),
  public.erp_symbologies(),
  public.erp_gs1_application_identifiers(),
  public.erp_upsert_scan_rule(text, text, text, text, text),
  public.erp_output_integrity(),
  public.erp_output_template_versions(),
  public.erp_printers(),
  public.erp_upsert_printer(text, uuid, text, text, text, integer, text, text, text),
  public.erp_output_requests(),
  public.erp_email_suppressions(),
  public.erp_commercial_summary(),
  public.erp_platform_plans(),
  public.erp_report_versions(),
  public.erp_report_runs(),
  public.erp_report_reproducibility(),
  public.erp_platform_product_decisions()
  to authenticated, service_role;

-- ── The registers that say what writes, what gates it, and who is a definer ──

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_upsert_scan_rule', 'erp.upsert_scan_rule',
   'Configures which symbologies and identifiers a device step accepts. §14.4 makes the rules per step and per product class; writing one is administrative configuration and gates on administration.configure.'),
  ('erp_upsert_printer', 'erp.authorise',
   'Registers or amends a printer. erp.upsert_printer() is the promoter''s routine and does not authorise because promotion already has; from a screen the door authorises administration.configure itself before delegating. erp.printer is a promotable surface, so a live organisation is refused a direct write by the guard and must go through a change.'),
  ('erp_platform_plans', 'erp_meta.require_platform',
   'Platform staff read of every plan and subscription, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_product_decisions', 'erp_meta.require_platform',
   'Platform staff read of the product decision register, gated on the platform staff list rather than on erp.authorise(), because the register belongs to the product and not to any organisation.')
on conflict (function_name) do nothing;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'commercial_summary',
   '§18.2 requires an organisation to see its own plan, entitlements and meters continuously; every table they live in is platform_internal, so the reader is a definer scoped to the caller''s own tenant and gated on administration.read.'),
  ('public', 'erp_platform_plans',
   'Platform-level read. erp_meta is platform_internal — RLS enabled with no policy and a blanket revoke — so no tenant session can reach it without a definer; gated on erp_meta.require_platform(''support'').'),
  ('public', 'erp_platform_product_decisions',
   'Platform-level read of erp_ref.product_decision and erp.decision_enforcement_report(), performed above every tenant and gated on erp_meta.require_platform(''support'').')
on conflict do nothing;

-- ── The strings the screens are renamed by ───────────────────────────────────

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.operations_devices', 'en', 'Devices and scanning', null,
   'Navigation label for the operations screen showing registered devices, the action queue, scan rules and the device operations report.'),
  ('nav.operations_output', 'en', 'Output and printing', null,
   'Navigation label for the operations screen showing output template versions, printers, output requests, deliveries and email suppressions.'),
  ('nav.administration_commercial', 'en', 'Plan and usage', null,
   'Navigation label for the administration screen showing the organisation''s plan, subscription, entitlements and usage meters.'),
  ('nav.reporting_reproducibility', 'en', 'Report versions and runs', null,
   'Navigation label for the reporting screen showing every report version, its parameters, the run history and the reproducibility report.')
on conflict (key, locale) do nothing;

-- ── The build fails here if any of that is ungoverned ───────────────────────

select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_session_context_hygiene();
select erp.assert_no_dead_configuration();
select erp.assert_device_operations_sound();
select erp.assert_output_integrity();
select erp.assert_entitlements_enforceable();
select erp.assert_reports_reproducible();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
