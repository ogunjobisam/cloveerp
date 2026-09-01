-- =============================================================================
-- Promotion completes the report and output models
--
-- Two decisions were left open when Parts 19 and 15 landed, and they describe
-- the same hole from two sides:
--
--   report_version_outside_promotion — "a change set that promotes a report
--   moves the report row and leaves its definition behind"
--
--   output_model_outside_promotion — output_template_version, printer and
--   email_suppression "cannot yet move between an organisation's environments
--   through a change set"
--
-- The first sentence is the one worth attacking, because the failure it names
-- is not an error. It is a promotion that SUCCEEDS: the receiving environment
-- gets a report called "Stock by site", the screen lists it, and running it is
-- impossible because the version that says which columns, which view and which
-- permission never travelled. That state looks installed. Reproduced here
-- before it was fixed: promote a report with no version and the organisation
-- fails erp.assert_reports_reproducible() with "a report has no version".
--
-- So the version does not become a promotable kind of its own. A separate kind
-- could be promoted separately, which is the split all over again. It travels
-- INSIDE the report item, as a nested object, exactly as a rule set carries its
-- rules and a state machine its states — one item, one payload, arriving whole
-- or not at all. output_template_version travels inside output_template the
-- same way, carrying the decode check that proves a label will scan.
--
-- erp.printer becomes a kind of its own, because it is not a child of anything:
-- a printer's queue address, language and resolution decide what comes out when
-- somebody presses print, which is the same test erp.document_type passes, and
-- a sandbox that cannot mirror production's printers cannot rehearse a print
-- run.
--
-- erp.email_suppression does NOT, and that is a departure from what the second
-- decision literally asked for. It is not configuration: it records that an
-- address bounced or unsubscribed, produced by delivery outcomes rather than
-- authored, which is why it is the one table here with no attribution columns.
-- Promoting it would be wrong in both directions — a sandbox's test bounces
-- would suppress real customers, and production's list would copy real
-- addresses into a less controlled environment — and guarding it would be
-- wrong too, because a bounce arrives without a change set. It is recorded as
-- its own settled decision rather than quietly skipped.
--
-- What erp.assert_configuration_promotable() can and cannot see
-- -------------------------------------------------------------
-- The assertion checks four things per registered table: it exists, the
-- promoter has a branch for its kind, the manifest emits that kind, and the
-- live-edit guard is attached. Registering report_version under the EXISTING
-- report kind satisfies the middle two for free — the branch and the emission
-- were already there for the report row. So the assertion cannot tell whether
-- the payload actually carries the version, which is the whole subject here.
-- That is what erp_test.promotion_completeness_suite() is for: it promotes,
-- reads the manifest back, and fails if the definition did not make the trip.
-- =============================================================================
-- The three writers promotion needs. Each refuses at write time what the
-- integrity report would otherwise find later, because the useful moment to
-- say "this report cannot be run" is while somebody is authoring it.

create or replace function erp.upsert_report_version(
  p_report_code         text,
  p_view_code           text,
  p_columns             text[],
  p_group_by            text[],
  p_default_sort        text[],
  p_output_formats      text[],
  p_required_permission text,
  p_time_budget_ms      integer,
  p_row_cap             integer,
  p_effective_from      date,
  p_note                text,
  p_parameters          jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_report uuid;
  v_view   uuid;
  v_num    integer;
  v_id     uuid;
  v_from   date := coalesce(p_effective_from, current_date);
  v_bad    text;
begin
  select r.id into v_report from erp.report r
   where r.tenant_id = v_tenant and r.code = p_report_code;
  if v_report is null then
    raise exception 'ERPWARE_UNKNOWN_REPORT: this environment has no report %',
      p_report_code using errcode = '23503';
  end if;

  select gv.id into v_view from erp.governed_view gv
   where gv.tenant_id = v_tenant and gv.code = p_view_code;
  if v_view is null then
    raise exception
      'ERPWARE_PROMOTION_UNKNOWN_VIEW: this environment has no governed view %',
      p_view_code using errcode = '23503';
  end if;

  if coalesce(cardinality(p_columns), 0) = 0 then
    raise exception 'ERPWARE_REPORT_VERSION_HAS_NO_COLUMNS: % names no columns',
      p_report_code using errcode = '23514';
  end if;

  -- erp.authorise() refuses a permission code it does not know, so a version
  -- requiring one is a report nobody can run. §19.2 would find it; finding it
  -- here means it never lands.
  if not exists (select 1 from erp_ref.permission pm
                  where pm.code = p_required_permission) then
    raise exception 'ERPWARE_UNKNOWN_PERMISSION: % is not a permission',
      p_required_permission using errcode = '23503';
  end if;

  -- §19.1 puts scoping in the governed view precisely so a report cannot reach
  -- around it. A parameter that filters a scoping column is that reach.
  select string_agg(e.value ->> 'code', ', ')
    into v_bad
    from jsonb_array_elements(coalesce(p_parameters, '[]'::jsonb)) e
   where e.value ->> 'filters_column'
         in ('tenant_id', 'entity_id', 'site_id', 'department_id');
  if v_bad is not null then
    raise exception
      'ERPWARE_REPORT_PARAMETER_WIDENS_SCOPE: parameter(s) % filter a scoping column',
      v_bad using errcode = '42501';
  end if;

  -- One version in force. The previous is superseded rather than removed,
  -- because a run record still names it and §19.2 promises that figure stays
  -- reproducible.
  update erp.report_version rv
     set status = 'superseded', updated_at = now()
   where rv.tenant_id = v_tenant and rv.report_id = v_report
     and rv.status = 'active';

  select coalesce(max(rv.version), 0) + 1 into v_num
    from erp.report_version rv
   where rv.tenant_id = v_tenant and rv.report_id = v_report;

  insert into erp.report_version (
    tenant_id, report_id, version, governed_view_id, columns, group_by,
    default_sort, output_formats, required_permission, time_budget_ms,
    row_cap, status, effective_from, note)
  values (v_tenant, v_report, v_num, v_view, p_columns,
          coalesce(p_group_by, '{}'), coalesce(p_default_sort, '{}'),
          coalesce(p_output_formats, '{pdf}'), p_required_permission,
          coalesce(p_time_budget_ms, 30000), coalesce(p_row_cap, 50000),
          'active', v_from, p_note)
  returning id into v_id;

  insert into erp.report_parameter (
    tenant_id, report_version_id, code, name_key, data_type, is_required,
    default_value, filters_column)
  select v_tenant, v_id, e.value ->> 'code', e.value ->> 'name_key',
         e.value ->> 'data_type',
         coalesce((e.value ->> 'is_required')::boolean, false),
         e.value ->> 'default_value', e.value ->> 'filters_column'
    from jsonb_array_elements(coalesce(p_parameters, '[]'::jsonb)) e;

  return v_id;
end;
$$;

comment on function erp.upsert_report_version is
  'Specification v1.2 §19.2. Adds a version to an existing report and supersedes '
  'the one it replaces, so exactly one is ever in force. Refuses an unknown view '
  'or permission, a version with no columns, and a parameter that filters a '
  'scoping column — each of which erp.report_reproducibility_report() would '
  'otherwise report after the fact.';


create or replace function erp.upsert_output_template_version(
  p_template_code       text,
  p_rendering_engine    text,
  p_page                jsonb,
  p_blocks              jsonb,
  p_required_permission text,
  p_label_language      text,
  p_test_render         text,
  p_decode_check_passed boolean,
  p_decoded_value       text,
  p_effective_from      date,
  p_note                text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_template uuid;
  v_num      integer;
  v_id       uuid;
  v_from     date := coalesce(p_effective_from, current_date);
begin
  select t.id into v_template from erp.output_template t
   where t.tenant_id = v_tenant and t.code = p_template_code;
  if v_template is null then
    raise exception
      'ERPWARE_UNKNOWN_OUTPUT_TEMPLATE: this environment has no template %',
      p_template_code using errcode = '23503';
  end if;

  if not exists (select 1 from erp_ref.permission pm
                  where pm.code = p_required_permission) then
    raise exception 'ERPWARE_UNKNOWN_PERMISSION: % is not a permission',
      p_required_permission using errcode = '23503';
  end if;

  -- §15.4. A label that has not been proved to decode is a label that will be
  -- discovered unreadable by a scanner in a yard, which is the worst place to
  -- discover it. Refuse the promotion rather than the scan.
  if p_label_language is not null
     and not (p_test_render is not null
              and coalesce(p_decode_check_passed, false)
              and coalesce(btrim(p_decoded_value), '') <> '') then
    raise exception
      'ERPWARE_LABEL_DOES_NOT_DECODE: % is a % label with no passing decode check',
      p_template_code, p_label_language
      using errcode = '23514',
            hint = 'A label version becomes active only once a test render has '
                   'been decoded back to the value it encodes.';
  end if;

  update erp.output_template_version tv
     set status = 'superseded', updated_at = now()
   where tv.tenant_id = v_tenant and tv.output_template_id = v_template
     and tv.status = 'active';

  select coalesce(max(tv.version), 0) + 1 into v_num
    from erp.output_template_version tv
   where tv.tenant_id = v_tenant and tv.output_template_id = v_template;

  insert into erp.output_template_version (
    tenant_id, output_template_id, version, rendering_engine, page, blocks,
    required_permission, label_language, test_render, decode_check_passed,
    decoded_value, status, effective_from, note)
  values (v_tenant, v_template, v_num, p_rendering_engine,
          coalesce(p_page, '{}'::jsonb), coalesce(p_blocks, '[]'::jsonb),
          p_required_permission, p_label_language, p_test_render,
          coalesce(p_decode_check_passed, false), p_decoded_value,
          'active', v_from, p_note)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.upsert_output_template_version is
  'Specification v1.2 §15.2 and §15.4. Adds a version to an existing output '
  'template and supersedes the one it replaces. Refuses a label version whose '
  'test render has not been decoded back, because a label that will not scan '
  'must fail here rather than in a yard.';


create or replace function erp.upsert_printer(
  p_code              text,
  p_site_code         text,
  p_name              text,
  p_printer_type      text,
  p_language          text,
  p_dots_per_inch     integer,
  p_physical_location text,
  p_default_stock     text,
  p_queue_address     text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_site   uuid;
  v_id     uuid;
begin
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = p_site_code;
  if v_site is null then
    raise exception 'ERPWARE_PROMOTION_UNKNOWN_SITE: this environment has no site %',
      p_site_code using errcode = '23503';
  end if;

  insert into erp.printer (
    tenant_id, site_id, code, name, printer_type, language, dots_per_inch,
    physical_location, default_stock, queue_address)
  values (v_tenant, v_site, p_code, p_name, p_printer_type, p_language,
          p_dots_per_inch, p_physical_location, p_default_stock, p_queue_address)
  on conflict (tenant_id, code) do update set
    site_id = excluded.site_id, name = excluded.name,
    printer_type = excluded.printer_type, language = excluded.language,
    dots_per_inch = excluded.dots_per_inch,
    physical_location = excluded.physical_location,
    default_stock = excluded.default_stock,
    queue_address = excluded.queue_address,
    status = 'active', updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.upsert_printer is
  'Specification v1.2 §15.4. A printer is site configuration: its queue address, '
  'language and resolution decide what comes out when somebody presses print, '
  'which is the same test erp.document_type passes. Resolves the site by code '
  'because a change set built elsewhere knows nothing of this environment''s ids.';


-- ── The promoter: report carries its version, output_template carries its
--    version, and printer becomes a kind ────────────────────────────────────
CREATE OR REPLACE FUNCTION erp.apply_change_set_item(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  i         erp.change_set_item%rowtype;
  p         jsonb;
  v_entity  uuid;
  v_site    uuid;
  v_from    date;
  v_obj     uuid;
  v_ver     uuid;
  v_vnum    integer;
  r         record;
  v_state   uuid;
begin
  select * into i from erp.change_set_item where tenant_id = v_tenant and id = p_item_id;
  p := i.payload;

  -- Codes to local ids. A change set built elsewhere knows nothing of our keys.
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.code = (p ->> 'entity');
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.code = (p ->> 'site');
  v_from := coalesce(i.effective_from, (p ->> 'effective_from')::date, current_date);

  if (p ? 'entity') and (p ->> 'entity') is not null and v_entity is null then
    raise exception 'ERPWARE_PROMOTION_UNKNOWN_ENTITY: this environment has no entity %',
      p ->> 'entity' using errcode = '23503';
  end if;

  case i.object_kind

    when 'config' then
      if i.operation = 'remove' then
        update erp.config_object co set status = 'inactive', updated_at = now()
         where co.tenant_id = v_tenant
           and co.config_type_code = (p ->> 'config_type')
           and co.code is not distinct from (p ->> 'code')
           and co.entity_id is not distinct from v_entity
           and co.site_id is not distinct from v_site;
      else
        perform erp.set_config_value(
          p ->> 'config_type', p -> 'value', p ->> 'code', v_from,
          v_entity, v_site, 'promoted');
      end if;

    when 'terminology' then
      if i.operation = 'remove' then
        update erp.resource_override ro set status = 'inactive', updated_at = now()
         where ro.tenant_id = v_tenant and ro.key = (p ->> 'key')
           and ro.locale = (p ->> 'locale') and ro.entity_id is not distinct from v_entity;
      else
        insert into erp.resource_override (tenant_id, key, locale, value, entity_id)
        values (v_tenant, p ->> 'key', p ->> 'locale', p ->> 'value', v_entity)
        on conflict (tenant_id, key, locale,
                     coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
          do update set value = excluded.value, status = 'active', updated_at = now();
      end if;

    when 'legislation_binding' then
      if i.operation = 'remove' then
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack');
      else
        update erp.entity_legislation_binding b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.entity_id = v_entity
           and b.pack_code = (p ->> 'pack') and b.status = 'active';
        insert into erp.entity_legislation_binding (
          tenant_id, entity_id, pack_code, pack_version, effective_from, effective_to)
        values (v_tenant, v_entity, p ->> 'pack', (p ->> 'pack_version')::integer,
                v_from, (p ->> 'effective_to')::date);
      end if;

    when 'event_subscription' then
      if i.operation = 'remove' then
        update erp.event_subscription es set status = 'inactive', updated_at = now()
         where es.tenant_id = v_tenant and es.consumer_code = (p ->> 'consumer')
           and es.event_pattern = (p ->> 'pattern');
      else
        insert into erp.event_subscription (
          tenant_id, consumer_code, event_pattern, module_code, max_attempts)
        values (v_tenant, p ->> 'consumer', p ->> 'pattern', p ->> 'module',
                coalesce((p ->> 'max_attempts')::smallint, 8))
        on conflict (tenant_id, consumer_code, event_pattern) do update
          set module_code = excluded.module_code,
              max_attempts = excluded.max_attempts,
              status = 'active', updated_at = now();
      end if;

    when 'role' then
      if i.operation = 'remove' then
        update erp.role r set status = 'inactive', updated_at = now()
         where r.tenant_id = v_tenant and r.code = (p ->> 'code');
      else
        insert into erp.role (tenant_id, code, name, name_key, from_template)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
        on conflict (tenant_id, code) do update
          set name = excluded.name, name_key = excluded.name_key,
              status = 'active', updated_at = now()
        returning id into v_obj;

        -- The grant set is replaced wholesale: a promoted role is the role the
        -- change set describes, not a merge with whatever was here before.
        delete from erp.role_permission rp
         where rp.tenant_id = v_tenant and rp.role_id = v_obj;

        insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
        select v_tenant, v_obj, e.value ->> 'permission',
               coalesce((select array_agg(dc #>> '{}')
                           from jsonb_array_elements(e.value -> 'data_classes') dc),
                        '{}'::text[])
          from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
      end if;

    when 'rule_set' then
      if i.operation = 'remove' then
        update erp.rule_set rs set status = 'inactive', updated_at = now()
         where rs.tenant_id = v_tenant
           and rs.decision_point_code = (p ->> 'decision_point')
           and rs.code = (p ->> 'code');
      else
        insert into erp.rule_set (tenant_id, decision_point_code, code, name, entity_id, site_id)
        values (v_tenant, p ->> 'decision_point', p ->> 'code', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, decision_point_code, code) do update
          set name = excluded.name, status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.rule_set_version v
         where v.tenant_id = v_tenant and v.rule_set_id = v_obj;

        insert into erp.rule_set_version (
          tenant_id, rule_set_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.rule (
          tenant_id, rule_set_version_id, seq, code, name, condition, outcome,
          stop_on_match, is_active)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', e.value -> 'condition', e.value -> 'outcome',
               coalesce((e.value ->> 'stop_on_match')::boolean, true),
               coalesce((e.value ->> 'is_active')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'rules', '[]'::jsonb)) e;

        -- Activation runs the linter, so a promotion cannot introduce a rule
        -- that can never match.
        perform erp.activate_rule_set_version(v_ver, v_from);
      end if;

    when 'state_machine' then
      if i.operation = 'remove' then
        update erp.state_machine sm set status = 'inactive', updated_at = now()
         where sm.tenant_id = v_tenant and sm.code = (p ->> 'code');
      else
        insert into erp.state_machine (tenant_id, code, object_type, name, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'object_type', p ->> 'name', v_entity, v_site)
        on conflict (tenant_id, code) do update
          set object_type = excluded.object_type, name = excluded.name,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.state_machine_version v
         where v.tenant_id = v_tenant and v.state_machine_id = v_obj;

        insert into erp.state_machine_version (
          tenant_id, state_machine_id, version, status, effective_from, note)
        values (v_tenant, v_obj, v_vnum, 'draft', v_from, 'promoted')
        returning id into v_ver;

        insert into erp.state (
          tenant_id, state_machine_version_id, code, name, is_initial, is_terminal,
          is_committed, sort_order, on_enter, on_exit)
        select v_tenant, v_ver, e.value ->> 'code', e.value ->> 'name',
               coalesce((e.value ->> 'is_initial')::boolean, false),
               coalesce((e.value ->> 'is_terminal')::boolean, false),
               coalesce((e.value ->> 'is_committed')::boolean, false),
               coalesce((e.value ->> 'sort_order')::integer, 100),
               coalesce(e.value -> 'on_enter', '[]'::jsonb),
               coalesce(e.value -> 'on_exit', '[]'::jsonb)
          from jsonb_array_elements(coalesce(p -> 'states', '[]'::jsonb)) e;

        -- Transitions come second because they reference states by code.
        for r in select e.value as tr
                   from jsonb_array_elements(coalesce(p -> 'transitions', '[]'::jsonb)) e
        loop
          insert into erp.transition (
            tenant_id, state_machine_version_id, code, name, from_state_id, to_state_id,
            guard, effects, required_permission, is_automatic, sort_order)
          select v_tenant, v_ver, r.tr ->> 'code', r.tr ->> 'name',
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'from'),
                 (select st.id from erp.state st
                   where st.state_machine_version_id = v_ver and st.code = r.tr ->> 'to'),
                 coalesce(r.tr -> 'guard', 'true'::jsonb),
                 coalesce(r.tr -> 'effects', '[]'::jsonb),
                 r.tr ->> 'required_permission',
                 coalesce((r.tr ->> 'is_automatic')::boolean, false),
                 coalesce((r.tr ->> 'sort_order')::integer, 100);
        end loop;

        -- Activation runs the graph validation, so a promotion cannot
        -- introduce a state a document could enter and never leave.
        perform erp.activate_state_machine_version(v_ver, v_from);
      end if;

    when 'approval_chain' then
      if i.operation = 'remove' then
        update erp.approval_chain ac set status = 'inactive', updated_at = now()
         where ac.tenant_id = v_tenant and ac.code = (p ->> 'code');
      else
        insert into erp.approval_chain (
          tenant_id, code, name, object_type, applies_when, priority, entity_id, site_id)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'object_type',
                coalesce(p -> 'applies_when', 'true'::jsonb),
                coalesce((p ->> 'priority')::integer, 100), v_entity, v_site)
        on conflict (tenant_id, code) do update
          set name = excluded.name, object_type = excluded.object_type,
              applies_when = excluded.applies_when, priority = excluded.priority,
              status = 'active', updated_at = now()
        returning id into v_obj;

        select coalesce(max(v.version), 0) + 1 into v_vnum
          from erp.approval_chain_version v
         where v.tenant_id = v_tenant and v.approval_chain_id = v_obj;

        insert into erp.approval_chain_version (
          tenant_id, approval_chain_id, version, status, effective_from,
          material_fields, value_field, tolerance_pct, tolerance_absolute, note)
        values (
          v_tenant, v_obj, v_vnum, 'draft', v_from,
          coalesce((select array_agg(f #>> '{}')
                      from jsonb_array_elements(coalesce(p -> 'material_fields', '[]'::jsonb)) f),
                   '{}'::text[]),
          p ->> 'value_field',
          (p ->> 'tolerance_pct')::numeric,
          (p ->> 'tolerance_absolute')::numeric,
          'promoted')
        returning id into v_ver;

        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)
        select v_tenant, v_ver, (e.value ->> 'seq')::integer, e.value ->> 'code',
               e.value ->> 'name', (e.value ->> 'approver_kind')::erp.approver_kind,
               (select ro.id from erp.role ro
                 where ro.tenant_id = v_tenant and ro.code = e.value ->> 'role'),
               (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and u.email = e.value ->> 'user'),
               coalesce((e.value ->> 'min_approvals')::smallint, 1),
               coalesce(e.value -> 'condition', 'true'::jsonb),
               (e.value ->> 'escalate_after')::interval,
               coalesce((e.value ->> 'allow_delegation')::boolean, true)
          from jsonb_array_elements(coalesce(p -> 'steps', '[]'::jsonb)) e;

        -- Activation refuses a chain with no steps, so a promotion cannot
        -- install one that approves everything unchecked.
        perform erp.activate_approval_chain_version(v_ver, v_from);
      end if;

    -- Spec 5.7: "declarative posting rules from operational events". Declarative
    -- means configuration, and configuration in this product is promoted rather
    -- than edited — otherwise the rule that decides which account a receipt
    -- lands in would be the one thing in finance nobody had to get approved.
    --
    -- Rules are versioned in place: a new version supersedes the last rather
    -- than replacing it, because a journal line records the rule version that
    -- produced it and that reference must stay resolvable for ever.
    when 'posting_rule' then
      if i.operation = 'remove' then
        update erp.posting_rule pr set status = 'withdrawn', updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';
      else
        select coalesce(max(pr.version), 0) + 1 into v_vnum
          from erp.posting_rule pr
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code');

        -- Supersede the version in force, and only move its end date if it
        -- actually started earlier.
        --
        -- This is the defect 0019 found in every other activation path,
        -- arriving here through a door that did not exist when 0019 was
        -- written. Setting effective_to = v_from on a version that started on
        -- the same day produces an empty window, which posting_rule_range
        -- refuses. Invisible in normal use, because changes are made on later
        -- days than the versions they replace — and immediate the moment two
        -- change sets touch the same rule in one sitting, which is exactly
        -- what installing finance and then inventory does.
        update erp.posting_rule pr
           set status = 'superseded',
               effective_to = case when pr.effective_from < v_from then v_from
                                   else pr.effective_to end,
               updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code')
           and pr.status = 'active';

        insert into erp.posting_rule (
          tenant_id, code, name, entity_id, ledger_id, event_type, condition,
          posting_lines, version, status, effective_from, legislation_pack_code)
        values (
          v_tenant, p ->> 'code', p ->> 'name', v_entity,
          (select l.id from erp.ledger l
            where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')
              and (v_entity is null or l.entity_id = v_entity)
            order by l.code limit 1),
          p ->> 'event_type',
          coalesce(p -> 'condition', 'true'::jsonb),
          coalesce(p -> 'posting_lines', '[]'::jsonb),
          v_vnum, 'active', v_from, p ->> 'legislation_pack');

        -- A rule that does not balance would raise a journal that cannot post,
        -- and it would do so at month end rather than here. Refusing at
        -- promotion is the whole point of promoting it.
        perform erp.assert_posting_rule_balances(p ->> 'code', v_vnum);
      end if;

    -- Spec 5.1: what a good record looks like is a tenant's opinion, and an
    -- opinion that decides whether a record is fit to trade on belongs in the
    -- same promotion pipeline as everything else. Replaced rather than
    -- versioned: nothing records "the quality rule version that scored this",
    -- so a superseded version would be a row nobody could ever read.
    when 'data_quality_rule' then
      if i.operation = 'remove' then
        update erp.data_quality_rule q set status = 'inactive', updated_at = now()
         where q.tenant_id = v_tenant
           and q.object_type = (p ->> 'object_type')
           and q.code = (p ->> 'code');
      else
        insert into erp.data_quality_rule (
          tenant_id, object_type, code, name, kind, condition, weight,
          severity, message, entity_id, status)
        values (v_tenant, p ->> 'object_type', p ->> 'code', p ->> 'name',
                coalesce(p ->> 'kind', 'completeness'),
                coalesce(p -> 'condition', 'true'::jsonb),
                coalesce((p ->> 'weight')::integer, 1),
                coalesce(p ->> 'severity', 'warning'),
                coalesce(p ->> 'message', p ->> 'name'),
                v_entity, 'active')
        on conflict (tenant_id, object_type, code) do update
          set name = excluded.name, kind = excluded.kind,
              condition = excluded.condition, weight = excluded.weight,
              severity = excluded.severity, message = excluded.message,
              status = 'active', updated_at = now();
      end if;

    -- Which fields cannot change without somebody agreeing. Promoted for the
    -- same reason the approval chains themselves are: a control that its own
    -- subject can switch off is not a control.
    when 'field_approval_rule' then
      if i.operation = 'remove' then
        update erp.field_approval_rule f set status = 'inactive', updated_at = now()
         where f.tenant_id = v_tenant
           and f.object_type = (p ->> 'object_type')
           and f.field_name = (p ->> 'field_name');
      else
        if not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = (p ->> 'object_type')
                          and m.column_name = (p ->> 'field_name')) then
          raise exception
            'ERPWARE_PROMOTION_UNGOVERNABLE_FIELD: %.% is not a maintainable field',
            p ->> 'object_type', p ->> 'field_name'
            using errcode = '23503',
                  hint = 'A rule guarding a field nothing can change is a control '
                         'that will never fire.';
        end if;

        insert into erp.field_approval_rule (
          tenant_id, object_type, field_name, condition, approval_chain_code,
          sensitivity, reason_required, status)
        values (v_tenant, p ->> 'object_type', p ->> 'field_name',
                coalesce(p -> 'condition', 'true'::jsonb),
                p ->> 'approval_chain',
                coalesce((p ->> 'sensitivity')::integer, 100),
                coalesce((p ->> 'reason_required')::boolean, false),
                'active')
        on conflict (tenant_id, object_type, field_name) do update
          set condition = excluded.condition,
              approval_chain_code = excluded.approval_chain_code,
              sensitivity = excluded.sensitivity,
              reason_required = excluded.reason_required,
              status = 'active', updated_at = now();
      end if;

    -- Which stock is valued how. Promoted rather than written, because
    -- switching an item from FIFO to average changes what every future issue
    -- costs and therefore what the accounts say.
    when 'costing_policy' then
      if i.operation = 'remove' then
        update erp.costing_policy c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.costing_policy (
          tenant_id, code, name, method, item_class, entity_id, site_id,
          variance_account_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                (p ->> 'method')::erp.costing_method,
                p ->> 'item_class', v_entity, v_site,
                p ->> 'variance_account', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, method = excluded.method,
              item_class = excluded.item_class,
              variance_account_code = excluded.variance_account_code,
              status = 'active', updated_at = now();
      end if;

    -- What gets counted, how often, and how wrong a count may be before
    -- somebody has to look at it. A tolerance a warehouse can set for itself
    -- is not a tolerance.
    when 'count_programme' then
      if i.operation = 'remove' then
        update erp.count_programme c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.count_programme (
          tenant_id, code, name, site_id, kind, selector,
          tolerance_absolute, tolerance_pct, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_site,
                (p ->> 'kind')::erp.count_programme_kind,
                coalesce(p -> 'selector', 'true'::jsonb),
                coalesce((p ->> 'tolerance_absolute')::numeric, 0),
                coalesce((p ->> 'tolerance_pct')::numeric, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, kind = excluded.kind,
              selector = excluded.selector,
              tolerance_absolute = excluded.tolerance_absolute,
              tolerance_pct = excluded.tolerance_pct,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much more than was ordered may arrive, and what to do with it.
    when 'receipt_tolerance' then
      if i.operation = 'remove' then
        update erp.receipt_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.receipt_tolerance (
          tenant_id, code, name, item_class, over_pct, under_pct, over_action, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'over_pct')::numeric, 0),
                coalesce((p ->> 'under_pct')::numeric, 100),
                coalesce(p ->> 'over_action', 'accept'), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              over_pct = excluded.over_pct, under_pct = excluded.under_pct,
              over_action = excluded.over_action,
              status = 'active', updated_at = now();
      end if;

    -- How far an invoice may differ from the receipt before somebody looks.
    -- The most contested numbers in a finance function, and therefore exactly
    -- the ones that should be promoted rather than typed.
    when 'match_tolerance' then
      if i.operation = 'remove' then
        update erp.match_tolerance t set status = 'inactive', updated_at = now()
         where t.tenant_id = v_tenant and t.code = (p ->> 'code');
      else
        insert into erp.match_tolerance (
          tenant_id, code, name, item_class, quantity_pct, price_pct,
          price_absolute_minor, approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce((p ->> 'quantity_pct')::numeric, 0),
                coalesce((p ->> 'price_pct')::numeric, 0),
                coalesce((p ->> 'price_absolute_minor')::bigint, 0),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              quantity_pct = excluded.quantity_pct, price_pct = excluded.price_pct,
              price_absolute_minor = excluded.price_absolute_minor,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What may be spent, and what happens when it would be exceeded.
    when 'budget' then
      if i.operation = 'remove' then
        update erp.budget b set status = 'inactive', updated_at = now()
         where b.tenant_id = v_tenant and b.code = (p ->> 'code');
      else
        insert into erp.budget (
          tenant_id, entity_id, code, name, fiscal_year, selector, amount_minor,
          currency, on_exceed, approval_chain_code, status)
        select v_tenant,
               coalesce(v_entity, (select e.id from erp.entity e
                                    where e.tenant_id = v_tenant and e.status = 'active'
                                    order by e.code limit 1)),
               p ->> 'code', p ->> 'name',
               coalesce((p ->> 'fiscal_year')::integer,
                        extract(year from v_from)::integer),
               coalesce(p -> 'selector', 'true'::jsonb),
               (p ->> 'amount_minor')::bigint,
               coalesce(p ->> 'currency',
                        (select e.base_currency from erp.entity e
                          where e.tenant_id = v_tenant limit 1)),
               coalesce(p ->> 'on_exceed', 'block'),
               p ->> 'approval_chain', 'active'
        on conflict (tenant_id, code, fiscal_year) do update
          set name = excluded.name, selector = excluded.selector,
              amount_minor = excluded.amount_minor,
              on_exceed = excluded.on_exceed,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- How much risk of running out is acceptable, how far ahead the plan is
    -- fixed, and how orders are sized. Every one of those is a number a
    -- business argues about for a fortnight and then nobody revisits, which is
    -- precisely what promotion is for.
    when 'planning_policy' then
      if i.operation = 'remove' then
        update erp.planning_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.planning_policy (
          tenant_id, code, name, reorder_method, safety_stock_basis,
          service_level_pct, lot_sizing, fixed_lot_size, rounding_multiple,
          demand_time_fence_days, planning_time_fence_days, sourcing_rules, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'reorder_method')::erp.reorder_method, 'reorder_point'),
                coalesce(p ->> 'safety_stock_basis', 'statistical'),
                coalesce((p ->> 'service_level_pct')::numeric, 95),
                coalesce(p ->> 'lot_sizing', 'lot_for_lot'),
                (p ->> 'fixed_lot_size')::numeric,
                (p ->> 'rounding_multiple')::numeric,
                coalesce((p ->> 'demand_time_fence_days')::integer, 0),
                coalesce((p ->> 'planning_time_fence_days')::integer, 0),
                coalesce(p -> 'sourcing_rules', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, reorder_method = excluded.reorder_method,
              safety_stock_basis = excluded.safety_stock_basis,
              service_level_pct = excluded.service_level_pct,
              lot_sizing = excluded.lot_sizing,
              fixed_lot_size = excluded.fixed_lot_size,
              rounding_multiple = excluded.rounding_multiple,
              demand_time_fence_days = excluded.demand_time_fence_days,
              planning_time_fence_days = excluded.planning_time_fence_days,
              sourcing_rules = excluded.sourcing_rules,
              status = 'active', updated_at = now();
      end if;

    -- The margin floor, and whether anybody may go under it. Promoted because
    -- it is the number a sales force will ask to have moved.
    when 'pricing_policy' then
      if i.operation = 'remove' then
        update erp.pricing_policy pp set status = 'inactive', updated_at = now()
         where pp.tenant_id = v_tenant and pp.code = (p ->> 'code');
      else
        insert into erp.pricing_policy (
          tenant_id, code, name, entity_id, min_margin_pct, allow_below_cost,
          approval_chain_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name', v_entity,
                coalesce((p ->> 'min_margin_pct')::numeric, 0),
                coalesce((p ->> 'allow_below_cost')::boolean, false),
                p ->> 'approval_chain', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name,
              min_margin_pct = excluded.min_margin_pct,
              allow_below_cost = excluded.allow_below_cost,
              approval_chain_code = excluded.approval_chain_code,
              status = 'active', updated_at = now();
      end if;

    -- What is inspected and how much of it. Promoted because a sampling rule
    -- is exactly the sort of thing that gets loosened quietly under delivery
    -- pressure and should have to be argued for.
    when 'inspection_plan' then
      if i.operation = 'remove' then
        update erp.inspection_plan ip set status = 'inactive', updated_at = now()
         where ip.tenant_id = v_tenant and ip.code = (p ->> 'code');
      else
        insert into erp.inspection_plan (
          tenant_id, code, name, item_class, trigger_point, sampling_rule,
          characteristics, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',
                coalesce(p ->> 'trigger_point', 'receipt'),
                coalesce(p -> 'sampling_rule', '{}'::jsonb),
                coalesce(p -> 'characteristics', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, item_class = excluded.item_class,
              trigger_point = excluded.trigger_point,
              sampling_rule = excluded.sampling_rule,
              characteristics = excluded.characteristics,
              status = 'active', updated_at = now();
      end if;

    -- Which carriers may be used and what they charge. A tariff that anybody
    -- can edit is one where the cheapest carrier is whoever last touched it.
    when 'carrier' then
      if i.operation = 'remove' then
        update erp.carrier c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = (p ->> 'code');
      else
        insert into erp.carrier (tenant_id, code, name, services, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'services', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, services = excluded.services,
              status = 'active', updated_at = now();
      end if;

    -- What has to be true before a period closes. Promoted, because a close
    -- checklist that the people being checked can shorten is not a control.
    when 'close_task' then
      if i.operation = 'remove' then
        update erp.close_task_template ct set status = 'inactive', updated_at = now()
         where ct.tenant_id = v_tenant and ct.code = (p ->> 'code');
      else
        insert into erp.close_task_template (
          tenant_id, code, name, seq, depends_on, blocking_check,
          owner_role_code, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce((p ->> 'seq')::integer, 100),
                coalesce((select array_agg(d #>> '{}')
                            from jsonb_array_elements(coalesce(p -> 'depends_on',
                                                               '[]'::jsonb)) d),
                         '{}'::text[]),
                p ->> 'blocking_check', p ->> 'owner_role', 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, seq = excluded.seq,
              depends_on = excluded.depends_on,
              blocking_check = excluded.blocking_check,
              owner_role_code = excluded.owner_role_code,
              status = 'active', updated_at = now();
      end if;

    -- When a customer is chased and when they stop being sold to. The second
    -- is a commercial decision that finance owns and sales will ask to move,
    -- which is exactly what promotion is for.
    when 'dunning_policy' then
      if i.operation = 'remove' then
        update erp.dunning_policy dp set status = 'inactive', updated_at = now()
         where dp.tenant_id = v_tenant and dp.code = (p ->> 'code');
      else
        insert into erp.dunning_policy (tenant_id, code, name, levels, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                coalesce(p -> 'levels', '[]'::jsonb), 'active')
        on conflict (tenant_id, code) do update
          set name = excluded.name, levels = excluded.levels,
              status = 'active', updated_at = now();
      end if;


    -- ── Addendum B configuration surfaces ───────────────────────────────────
    --
    -- Each resolves the codes a change set carries to this environment's own
    -- ids, then calls the erp.* mechanism extracted in 20260901120000. None of
    -- them authorises: promotion authorised once, at the change set, which is
    -- what lets a promote-only principal promote somebody else's work.

    when 'department' then
      if i.operation = 'remove' then
        update erp.department d set status = 'inactive', updated_at = now()
         where d.tenant_id = v_tenant and d.code = upper(p ->> 'code');
      else
        perform erp.upsert_department(
          p ->> 'code', p ->> 'name',
          (select u.id from erp.app_user u
            where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'manager_email')),
          (select d2.id from erp.department d2
            where d2.tenant_id = v_tenant and d2.code = upper(p ->> 'parent')),
          p ->> 'default_cost_centre', v_entity, v_from);
      end if;

    when 'approval_band' then
      declare
        v_dept uuid;
      begin
        select d.id into v_dept from erp.department d
         where d.tenant_id = v_tenant and d.code = upper(p ->> 'department');
        if v_dept is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_DEPARTMENT: this environment has no department %',
            p ->> 'department' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.approval_band ab set status = 'inactive', updated_at = now()
           where ab.tenant_id = v_tenant and ab.department_id = v_dept
             and ab.object_type = (p ->> 'object_type')
             and ab.seq = (p ->> 'seq')::integer;
        else
          perform erp.upsert_approval_band(
            v_dept, p ->> 'object_type', (p ->> 'seq')::integer,
            (p ->> 'upper_bound_minor')::bigint,
            coalesce((p ->> 'lower_bound_minor')::bigint, 0),
            (select u.id from erp.app_user u
              where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'approver_email')),
            p ->> 'approver_role',
            coalesce((p ->> 'use_line_manager')::boolean, false),
            coalesce(p ->> 'currency', 'GBP'),
            coalesce((p ->> 'is_parallel')::boolean, false),
            coalesce((p ->> 'rerun_lower_bands')::boolean, true),
            (p ->> 'escalate_after_hours')::integer,
            coalesce(p ->> 'vacancy', 'hold_and_raise'),
            (p ->> 'tolerance_pct')::numeric);
        end if;
      end;

    when 'posting_class' then
      if i.operation = 'remove' then
        update erp.posting_class pc set status = 'inactive', updated_at = now()
         where pc.tenant_id = v_tenant
           and pc.kind = (p ->> 'kind')::erp.posting_class_kind
           and pc.code = (p ->> 'code');
      else
        perform erp.upsert_posting_class(
          p ->> 'kind', p ->> 'code', p ->> 'name', p ->> 'description', v_from);
      end if;

    -- The one that decides which ledger account a posting hits. §5 refuses a
    -- default-to-suspense, so an unresolved account is an exception rather
    -- than a quiet landing place — which is exactly why this belongs behind
    -- promotion rather than a direct write on a live organisation.
    when 'account_determination' then
      declare
        v_account uuid;
      begin
        select a.id into v_account from erp.account a
         where a.tenant_id = v_tenant and a.code = (p ->> 'account');
        if v_account is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_ACCOUNT: this environment has no account %',
            p ->> 'account' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.account_determination ad set status = 'inactive', updated_at = now()
           where ad.tenant_id = v_tenant
             and ad.transaction_type = (p ->> 'transaction_type')
             and ad.account_id = v_account;
        else
          perform erp.upsert_account_determination(
            p ->> 'transaction_type', v_account,
            (select pc.id from erp.posting_class pc
              where pc.tenant_id = v_tenant and pc.kind = 'item'
                and pc.code = (p ->> 'item_class')),
            (select pc.id from erp.posting_class pc
              where pc.tenant_id = v_tenant and pc.kind = 'party'
                and pc.code = (p ->> 'party_class')),
            v_site, v_entity,
            (select l.id from erp.ledger l
              where l.tenant_id = v_tenant and l.code = (p ->> 'ledger')),
            p ->> 'reason_code', p ->> 'legislation_pack',
            p -> 'dimensions', p ->> 'note', v_from);
        end if;
      end;

    when 'classification_axis' then
      if i.operation = 'remove' then
        update erp.classification_axis ca set status = 'inactive', updated_at = now()
         where ca.tenant_id = v_tenant and ca.code = upper(p ->> 'code');
      else
        perform erp.upsert_classification_axis(
          p ->> 'code', p ->> 'name',
          coalesce((p ->> 'is_mandatory')::boolean, false),
          p ->> 'item_classes',
          coalesce((p ->> 'seq')::integer, 100),
          p ->> 'name_key');
      end if;

    when 'classification_value' then
      declare
        v_axis uuid;
      begin
        select ca.id into v_axis from erp.classification_axis ca
         where ca.tenant_id = v_tenant and ca.code = upper(p ->> 'axis');
        if v_axis is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_AXIS: this environment has no classification axis %',
            p ->> 'axis' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.classification_value cv set status = 'inactive', updated_at = now()
           where cv.tenant_id = v_tenant and cv.axis_id = v_axis
             and cv.code = upper(p ->> 'code');
        else
          perform erp.upsert_classification_value(
            v_axis, p ->> 'code', p ->> 'name', p ->> 'abbreviation',
            (select cv2.id from erp.classification_value cv2
              where cv2.tenant_id = v_tenant and cv2.axis_id = v_axis
                and cv2.code = upper(p ->> 'parent')),
            p ->> 'name_key');
        end if;
      end;

    when 'code_template' then
      if i.operation = 'remove' then
        update erp.code_template ct set status = 'inactive', updated_at = now()
         where ct.tenant_id = v_tenant and ct.code = upper(p ->> 'code');
      else
        perform erp.upsert_code_template(
          p ->> 'code', p ->> 'name',
          coalesce(p -> 'segments', '[]'::jsonb),
          p ->> 'item_classes',
          coalesce(p ->> 'casing', 'upper'),
          v_entity);
      end if;

    when 'release_area' then
      declare
        v_ra_site uuid;
      begin
        v_ra_site := coalesce(v_site,
          (select s2.id from erp.site s2
            where s2.tenant_id = v_tenant and s2.status = 'active'
            order by s2.code limit 1));
        if v_ra_site is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SITE: a release area needs a site and this '
            'environment has none' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.release_area ra set status = 'inactive', updated_at = now()
           where ra.tenant_id = v_tenant and ra.site_id = v_ra_site
             and ra.code = upper(p ->> 'code');
        else
          perform erp.upsert_release_area(
            v_ra_site, p ->> 'code', p ->> 'name',
            (select l.id from erp.location l
              where l.tenant_id = v_tenant and l.site_id = v_ra_site
                and l.code = (p ->> 'location')),
            coalesce(p ->> 'replenishment_mode', 'pull'),
            p ->> 'channel', p ->> 'order_type', p ->> 'item_classes',
            (p ->> 'min_quantity')::numeric,
            (p ->> 'max_quantity')::numeric,
            coalesce((p ->> 'ageing_hours')::integer, 72),
            coalesce((p ->> 'gate_printing')::boolean, true));
        end if;
      end;

    -- approver_assignment carries a named approver rather than a band, and
    -- both subject and approver are people. Promoting a rule that names a
    -- person only works where that person exists in the target, so the
    -- subject and approver are carried by email and resolved here.
    when 'approver_assignment' then
      declare
        v_subject  uuid;
        v_approver uuid;
      begin
        select u.id into v_approver from erp.app_user u
         where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'approver_email');
        if v_approver is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_APPROVER: this environment has no principal %',
            p ->> 'approver_email' using errcode = '23503';
        end if;

        v_subject := case (p ->> 'subject_kind')
          when 'department' then (select d.id from erp.department d
                                   where d.tenant_id = v_tenant
                                     and d.code = upper(p ->> 'subject'))
          else (select u.id from erp.app_user u
                 where u.tenant_id = v_tenant and lower(u.email) = lower(p ->> 'subject'))
        end;
        if v_subject is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SUBJECT: this environment has no % %',
            p ->> 'subject_kind', p ->> 'subject' using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.approver_assignment aa set status = 'inactive', updated_at = now()
           where aa.tenant_id = v_tenant and aa.subject_id = v_subject
             and aa.object_type = (p ->> 'object_type')
             and aa.approver_user_id = v_approver;
        else
          perform erp.assign_named_approver(
            p ->> 'subject_kind', v_subject, p ->> 'object_type', v_approver,
            coalesce(p ->> 'mode', 'prepends'),
            (p ->> 'lower_bound_minor')::bigint,
            (p ->> 'upper_bound_minor')::bigint,
            p ->> 'reason', v_from, (p ->> 'valid_to')::date);
        end if;
      end;

    -- ── Starter Content Packs: eleven kinds a pack installs ─────────────────

    -- §2.1: "switched through a change set like any other configuration".
    when 'capability' then
      if i.operation = 'remove' then
        perform erp.set_capability(p ->> 'code', false,
          coalesce(p ->> 'reason', 'Removed by change set'), v_from);
      else
        perform erp.set_capability(p ->> 'code',
          coalesce((p ->> 'enabled')::boolean, true),
          coalesce(p ->> 'reason', 'Promoted by change set'), v_from);
      end if;

    when 'uom' then
      if i.operation = 'remove' then
        update erp.uom u set status = 'inactive', updated_at = now()
         where u.tenant_id = v_tenant and u.code = upper(p ->> 'code');
      else
        perform erp.upsert_uom(
          p ->> 'code', p ->> 'name',
          coalesce(p ->> 'uom_class', 'quantity')::erp.uom_class,
          coalesce((p ->> 'decimals')::smallint, 0::smallint),
          coalesce((p ->> 'is_base')::boolean, false));
        if p ? 'converts_to' then
          perform erp.upsert_uom_conversion(
            p ->> 'code', p ->> 'converts_to', (p ->> 'factor')::numeric,
            p ->> 'item');
        end if;
      end if;

    when 'reason_code' then
      if i.operation = 'remove' then
        perform erp.set_reason_code_status(p ->> 'category', p ->> 'code', false);
      else
        perform erp.upsert_reason_code(
          p ->> 'category', p ->> 'code', p ->> 'name',
          coalesce((p ->> 'requires_note')::boolean, false),
          coalesce((p ->> 'requires_approval')::boolean, false),
          coalesce((p ->> 'seq')::integer, 100));
      end if;

    when 'calendar' then
      if i.operation = 'remove' then
        update erp.calendar c set status = 'inactive', updated_at = now()
         where c.tenant_id = v_tenant and c.code = upper(p ->> 'code');
      else
        perform erp.upsert_calendar(
          p ->> 'code', p ->> 'name', coalesce(p ->> 'timezone', 'UTC'),
          coalesce((select array_agg(x::boolean order by ord)
                      from jsonb_array_elements_text(p -> 'working_days')
                             with ordinality y(x, ord)),
                   '{t,t,t,t,t,f,f}'::boolean[]));
        -- Exceptions travel with the calendar rather than as their own kind: a
        -- public holiday without the calendar it falls in is not a thing.
        if p ? 'exceptions' then
          for r in select value from jsonb_array_elements(p -> 'exceptions') loop
            perform erp.upsert_calendar_exception(
              p ->> 'code', (r.value ->> 'date')::date,
              coalesce((r.value ->> 'is_working')::boolean, false),
              r.value ->> 'description');
          end loop;
        end if;
      end if;

    when 'sod_rule' then
      if i.operation = 'remove' then
        update erp.sod_rule sr set status = 'inactive', updated_at = now()
         where sr.tenant_id = v_tenant and sr.code = upper(p ->> 'code');
      else
        perform erp.upsert_sod_rule(
          p ->> 'code', p ->> 'name',
          string_to_array(p ->> 'permissions_a', ','),
          string_to_array(p ->> 'permissions_b', ','),
          coalesce(p ->> 'severity', 'material')::erp.sod_severity,
          p ->> 'description', p ->> 'mitigation');
      end if;

    when 'numbering_rule' then
      if i.operation = 'remove' then
        update erp.numbering_rule nr set status = 'inactive', updated_at = now()
         where nr.tenant_id = v_tenant and nr.code = (p ->> 'code');
      else
        perform erp.upsert_numbering_rule(
          p ->> 'code', p ->> 'prefix', p ->> 'entity', p ->> 'site',
          p ->> 'suffix',
          coalesce((p ->> 'pad_to')::smallint, 6::smallint),
          coalesce(p ->> 'reset_period', 'yearly')::erp.number_reset,
          coalesce((p ->> 'next_value')::bigint, 1));
      end if;

    when 'document_type' then
      -- The other half of the spine. A document type is configuration by every
      -- test the product applies to the word: it names a lifecycle, a chain, a
      -- sequence, a movement type and a posting rule, and changing any of them
      -- changes what happens when somebody presses a button. It was outside
      -- promotion only because the sequence it needs was.
      if i.operation = 'remove' then
        update erp.document_type dt set status = 'inactive', updated_at = now()
         where dt.tenant_id = v_tenant and dt.code = (p ->> 'code');
      else
        perform erp.upsert_document_type(
          p ->> 'code', p ->> 'base_type', p ->> 'name',
          p ->> 'numbering_rule', p ->> 'entity', p ->> 'site',
          p ->> 'state_machine', p ->> 'approval_chain',
          p ->> 'stock_movement_type', p ->> 'posting_rule',
          p ->> 'create_permission');
      end if;

    -- §9.3's layouts. The last of the three template surfaces to become
    -- promotable, and the only one that renders a document rather than a
    -- message.
    when 'output_template' then
      if i.operation = 'remove' then
        update erp.output_template ot set status = 'inactive', updated_at = now()
         where ot.tenant_id = v_tenant and ot.code = (p ->> 'code');
      else
        perform erp.upsert_output_template(
          p ->> 'code', p ->> 'name_key', p ->> 'kind',
          nullif(p ->> 'base_type', ''),
          coalesce(nullif(p ->> 'page', ''), 'A4'),
          coalesce(p -> 'blocks', '[]'::jsonb));

        -- §15.2, and the same shape as a report: the template names the
        -- document, the version renders it. A label version also carries the
        -- decode check that proves it will scan, which is the part that must
        -- not be left behind.
        if p ? 'version' then
          perform erp.upsert_output_template_version(
            p ->> 'code',
            p -> 'version' ->> 'rendering_engine',
            coalesce(p -> 'version' -> 'page', '{}'::jsonb),
            coalesce(p -> 'version' -> 'blocks', '[]'::jsonb),
            p -> 'version' ->> 'required_permission',
            nullif(p -> 'version' ->> 'label_language', ''),
            nullif(p -> 'version' ->> 'test_render', ''),
            coalesce((p -> 'version' ->> 'decode_check_passed')::boolean, false),
            nullif(p -> 'version' ->> 'decoded_value', ''),
            v_from, 'promoted');
        end if;
      end if;

    -- §15.4's devices. A printer decides what comes out when somebody presses
    -- print — its queue address, language and resolution — which is the same
    -- test erp.document_type passes. And a sandbox that cannot mirror
    -- production's printers cannot rehearse a print run, which is most of what
    -- a sandbox is for.
    when 'printer' then
      if i.operation = 'remove' then
        update erp.printer pr set status = 'inactive', updated_at = now()
         where pr.tenant_id = v_tenant and pr.code = (p ->> 'code');
      else
        perform erp.upsert_printer(
          p ->> 'code', p ->> 'site', p ->> 'name', p ->> 'printer_type',
          nullif(p ->> 'language', ''),
          nullif(p ->> 'dots_per_inch', '')::integer,
          nullif(p ->> 'physical_location', ''),
          nullif(p ->> 'default_stock', ''),
          p ->> 'queue_address');
      end if;

    when 'notification_template' then
      if i.operation = 'remove' then
        delete from erp.notification_template nt
         where nt.tenant_id = v_tenant and nt.code = (p ->> 'code');
      else
        perform erp.upsert_notification_template(
          p ->> 'code',
          coalesce(p ->> 'channel_kind', 'in_app')::erp.notification_channel_kind,
          p ->> 'body_key', p ->> 'subject_key');
      end if;

    when 'kpi' then
      if i.operation = 'remove' then
        delete from erp.kpi k where k.tenant_id = v_tenant and k.code = (p ->> 'code');
      else
        perform erp.upsert_kpi(
          p ->> 'code', p ->> 'name', p ->> 'unit',
          coalesce((p ->> 'higher_is_better')::boolean, true),
          p ->> 'description', p ->> 'module_code',
          coalesce((p ->> 'currency_scoped')::boolean, false),
          p ->> 'name_key');
      end if;

    when 'report' then
      if i.operation = 'remove' then
        update erp.report rp set status = 'inactive', updated_at = now()
         where rp.tenant_id = v_tenant and rp.code = (p ->> 'code');
      else
        perform erp.upsert_report(
          p ->> 'code', p ->> 'name', p ->> 'description', p ->> 'module_code',
          coalesce(string_to_array(nullif(p ->> 'kpi_codes', ''), ','), '{}'),
          coalesce(string_to_array(nullif(p ->> 'audience_role_codes', ''), ','), '{}'),
          p ->> 'name_key');

        -- §19.2. The report row is a title; the version is the report. Moving
        -- one without the other leaves the receiving environment with a name
        -- and no definition — worse than nothing, because it looks installed.
        -- The key is optional so content that ships titles only keeps working;
        -- when it is present it travels inside this same item, so the two
        -- cannot be promoted apart.
        if p ? 'version' then
          perform erp.upsert_report_version(
            p ->> 'code',
            p -> 'version' ->> 'view',
            array(select jsonb_array_elements_text(
                    coalesce(p -> 'version' -> 'columns', '[]'::jsonb))),
            array(select jsonb_array_elements_text(
                    coalesce(p -> 'version' -> 'group_by', '[]'::jsonb))),
            array(select jsonb_array_elements_text(
                    coalesce(p -> 'version' -> 'default_sort', '[]'::jsonb))),
            array(select jsonb_array_elements_text(
                    coalesce(p -> 'version' -> 'output_formats', '[]'::jsonb))),
            p -> 'version' ->> 'required_permission',
            (p -> 'version' ->> 'time_budget_ms')::integer,
            (p -> 'version' ->> 'row_cap')::integer,
            v_from, 'promoted',
            coalesce(p -> 'version' -> 'parameters', '[]'::jsonb));
        end if;
      end if;

    when 'account' then
      if i.operation = 'remove' then
        update erp.account a set status = 'inactive', updated_at = now()
         where a.tenant_id = v_tenant and a.entity_id = v_entity
           and a.code = (p ->> 'code');
      else
        -- A tenant-neutral pack cannot know an organisation's company codes,
        -- so an item that names none lands on the primary company — the same
        -- fallback the budget and release_area branches already use for the
        -- same reason. Refusing instead would make the account kind
        -- unreachable from a pack, which is the one place it is most wanted.
        perform erp.upsert_account(
          coalesce(nullif(p ->> 'entity', ''),
                   (select e.code from erp.entity e
                     where e.tenant_id = v_tenant and e.status = 'active'
                     order by e.code limit 1)),
          p ->> 'code', p ->> 'name',
          (p ->> 'account_type')::erp.account_type,
          nullif(p ->> 'control_kind', '')::erp.control_account_kind,
          p ->> 'group_code',
          coalesce((p ->> 'is_postable')::boolean, true),
          coalesce(string_to_array(nullif(p ->> 'requires_dimensions', ''), ','), '{}'),
          nullif(p ->> 'currency', '')::character(3),
          nullif(p ->> 'parent', ''),
          coalesce((p ->> 'reconciliation_required')::boolean, false),
          coalesce((p ->> 'close_blocking')::boolean, false));
      end if;

    -- §9.1's scheduled jobs. erp.upsert_job() exists and erp.run_due_jobs()
    -- runs them; what was missing was a way for a pack to carry one.
    when 'job' then
      if i.operation = 'remove' then
        update erp.job j set is_enabled = false, updated_at = now()
         where j.tenant_id = v_tenant and j.code = (p ->> 'code');
      else
        perform erp.upsert_job(
          p ->> 'code', p ->> 'name', p ->> 'handler_code',
          coalesce(p ->> 'schedule_kind', 'interval'),
          (p ->> 'interval_seconds')::integer,
          (p ->> 'at_time')::time,
          p ->> 'days_of_week',
          (p ->> 'day_of_month')::integer,
          coalesce(p ->> 'timezone', 'UTC'),
          coalesce(p -> 'parameters', '{}'::jsonb),
          (p ->> 'timeout_seconds')::integer,
          (p ->> 'max_silence_seconds')::integer,
          -- §9.1: "Shipped disabled, enabled per tenant." A pack that switched
          -- on eleven jobs on an organisation's first day would be a pack that
          -- starts doing work nobody asked for.
          coalesce((p ->> 'is_enabled')::boolean, false));
      end if;

    when 'location' then
      declare
        v_loc_site uuid;
      begin
        v_loc_site := coalesce(v_site,
          (select s2.id from erp.site s2
            where s2.tenant_id = v_tenant and s2.status = 'active'
            order by s2.code limit 1));
        if v_loc_site is null then
          raise exception
            'ERPWARE_PROMOTION_UNKNOWN_SITE: a location needs a site and this environment has none'
            using errcode = '23503';
        end if;

        if i.operation = 'remove' then
          update erp.location l set status = 'inactive', updated_at = now()
           where l.tenant_id = v_tenant and l.site_id = v_loc_site
             and l.code = upper(p ->> 'code');
        else
          perform erp.upsert_location(
            (select s3.code from erp.site s3 where s3.id = v_loc_site),
            p ->> 'code', p ->> 'name', p ->> 'location_type',
            nullif(p ->> 'parent', ''), nullif(p ->> 'count_class', ''),
            (p ->> 'is_pickable')::boolean,
            case when p ? 'storage_conditions' then p -> 'storage_conditions' end);
        end if;
      end;

    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy, pricing_policy, inspection_plan, carrier, close_task, dunning_policy, department, approval_band, approver_assignment, posting_class, account_determination, classification_axis, classification_value, code_template, release_area, capability, uom, reason_code, calendar, sod_rule, numbering_rule, notification_template, kpi, report, account, location, job';
  end case;
end;$function$
;


-- ── Capture, the other direction. Promotion without capture is one-way: an
--    organisation could be written to but never lifted out of. ──────────────
CREATE OR REPLACE FUNCTION erp.configuration_manifest(p_kinds text[] DEFAULT NULL::text[])
 RETURNS TABLE(object_kind text, object_key text, content jsonb, content_hash text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with t as (select erp.require_tenant_id() as tenant_id),
  entries as (
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
       -- In force today, not merely once in force.
       and daterange(cv.effective_from, cv.effective_to, '[)') @> current_date
      left join erp.entity e on e.id = co.entity_id
      left join erp.site s   on s.id = co.site_id

    union all

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
        on rsv.tenant_id = rs.tenant_id and rsv.rule_set_id = rs.id
       and rsv.status = 'active'
       and daterange(rsv.effective_from, rsv.effective_to, '[)') @> current_date
      left join erp.entity e on e.id = rs.entity_id
      left join erp.site s   on s.id = rs.site_id

    union all

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
        on smv.tenant_id = sm.tenant_id and smv.state_machine_id = sm.id
       and smv.status = 'active'
       and daterange(smv.effective_from, smv.effective_to, '[)') @> current_date
      left join erp.entity e on e.id = sm.entity_id
      left join erp.site s   on s.id = sm.site_id

    union all

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
        on acv.tenant_id = ac.tenant_id and acv.approval_chain_id = ac.id
       and acv.status = 'active'
       and daterange(acv.effective_from, acv.effective_to, '[)') @> current_date
      left join erp.entity e on e.id = ac.entity_id
      left join erp.site s   on s.id = ac.site_id

    union all

    select 'terminology',
           ro.key || '|' || ro.locale || '|' || coalesce(e.code, '-'),
           jsonb_build_object('key', ro.key, 'locale', ro.locale,
                              'value', ro.value, 'entity', e.code)
      from t
      join erp.resource_override ro on ro.tenant_id = t.tenant_id and ro.status = 'active'
      left join erp.entity e on e.id = ro.entity_id

    union all

    select 'legislation_binding',
           e.code || '|' || b.pack_code,
           jsonb_build_object('entity', e.code, 'pack', b.pack_code,
                              'pack_version', b.pack_version,
                              'effective_from', b.effective_from,
                              'effective_to', b.effective_to)
      from t
      join erp.entity_legislation_binding b on b.tenant_id = t.tenant_id and b.status = 'active'
       and daterange(b.effective_from, b.effective_to, '[)') @> current_date
      join erp.entity e on e.id = b.entity_id

    union all

    select 'event_subscription',
           es.consumer_code || '|' || es.event_pattern,
           jsonb_build_object('consumer', es.consumer_code, 'pattern', es.event_pattern,
                              'module', es.module_code, 'max_attempts', es.max_attempts)
      from t
      join erp.event_subscription es on es.tenant_id = t.tenant_id and es.status = 'active'

    union all

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

    -- ── Addendum B configuration surfaces ───────────────────────────────────
    --
    -- Nine surfaces the manifest never described, which is why they could be
    -- authored into a change set but never captured out of one. Every block
    -- emits the same keys the matching erp.apply_change_set_item branch reads,
    -- and names nothing by id: a manifest that carried local ids would promote
    -- into one environment and nowhere else.

    union all

    select 'department',
           d.code,
           jsonb_build_object(
             'code', d.code,
             'name', d.name,
             'entity', e.code,
             'manager_email', mu.email,
             'parent', pd.code,
             'default_cost_centre', d.default_cost_centre,
             'effective_from', d.valid_from)
      from t
      join erp.department d on d.tenant_id = t.tenant_id and d.status = 'active'
       and daterange(d.valid_from, d.valid_to, '[)') @> current_date
      left join erp.entity e      on e.id = d.entity_id
      left join erp.app_user mu   on mu.id = d.manager_user_id
      left join erp.department pd on pd.id = d.parent_department_id

    union all

    select 'approval_band',
           d.code || '|' || ab.object_type || '|' || ab.seq,
           jsonb_build_object(
             'department', d.code,
             'object_type', ab.object_type,
             'seq', ab.seq,
             'lower_bound_minor', ab.lower_bound_minor,
             'upper_bound_minor', ab.upper_bound_minor,
             'currency', btrim(ab.currency),
             'is_parallel', ab.is_parallel,
             'rerun_lower_bands', ab.rerun_lower_bands,
             'escalate_after_hours',
               (extract(epoch from ab.escalate_after) / 3600)::integer,
             'vacancy', ab.vacancy::text,
             'tolerance_pct', ab.tolerance_pct,
             'effective_from', ab.valid_from,
             -- The band stores a resolution ladder; the door that built it took
             -- three arguments. Emit the arguments, not the ladder, so a
             -- captured band promotes through the same door it came from.
             'approver_email', (
               select u.email
                 from jsonb_array_elements(ab.resolution) r
                 join erp.app_user u
                   on u.tenant_id = ab.tenant_id
                  and u.id = (r.value ->> 'user_id')::uuid
                where r.value ->> 'kind' = 'user' limit 1),
             'approver_role', (
               select r.value ->> 'role_code'
                 from jsonb_array_elements(ab.resolution) r
                where r.value ->> 'kind' = 'role_in_department' limit 1),
             'use_line_manager', exists (
               select 1 from jsonb_array_elements(ab.resolution) r
                where r.value ->> 'kind' = 'line_manager'))
      from t
      join erp.approval_band ab on ab.tenant_id = t.tenant_id and ab.status = 'active'
       and daterange(ab.valid_from, ab.valid_to, '[)') @> current_date
      join erp.department d on d.id = ab.department_id

    union all

    select 'approver_assignment',
           aa.subject_kind::text || '|' ||
             coalesce(sd.code, sr.code, su.email, '?') || '|' ||
             aa.object_type || '|' || au.email,
           jsonb_build_object(
             'subject_kind', aa.subject_kind::text,
             'subject', coalesce(sd.code, sr.code, su.email),
             'object_type', aa.object_type,
             'approver_email', au.email,
             'mode', aa.mode::text,
             'lower_bound_minor', aa.lower_bound_minor,
             'upper_bound_minor', aa.upper_bound_minor,
             'reason', aa.reason,
             'effective_from', aa.valid_from,
             'valid_to', aa.valid_to)
      from t
      join erp.approver_assignment aa
        on aa.tenant_id = t.tenant_id and aa.status = 'active'
       and daterange(aa.valid_from, aa.valid_to, '[)') @> current_date
      join erp.app_user au on au.id = aa.approver_user_id
      left join erp.department sd
        on aa.subject_kind = 'department' and sd.id = aa.subject_id
      left join erp.role sr
        on aa.subject_kind = 'role' and sr.id = aa.subject_id
      left join erp.app_user su
        on aa.subject_kind = 'principal' and su.id = aa.subject_id

    union all

    select 'posting_class',
           pc.kind::text || '|' || pc.code,
           jsonb_build_object(
             'kind', pc.kind::text,
             'code', pc.code,
             'name', pc.name,
             'description', pc.description,
             'effective_from', pc.valid_from)
      from t
      join erp.posting_class pc on pc.tenant_id = t.tenant_id and pc.status = 'active'
       and daterange(pc.valid_from, pc.valid_to, '[)') @> current_date

    union all

    -- §5 refuses a default-to-suspense, so an account determination rule that
    -- promotes into the wrong account is a wrong posting rather than a missing
    -- one. Every reference here is a code.
    select 'account_determination',
           ad.transaction_type || '|' || coalesce(ic.code, '-') || '|' ||
             coalesce(pcl.code, '-') || '|' || coalesce(s.code, '-') || '|' ||
             coalesce(e.code, '-') || '|' || coalesce(l.code, '-') || '|' ||
             coalesce(ad.legislation_pack_code, '-') || '|' ||
             coalesce(ad.reason_code, '-'),
           jsonb_build_object(
             'transaction_type', ad.transaction_type,
             'account', a.code,
             'item_class', ic.code,
             'party_class', pcl.code,
             'site', s.code,
             'entity', e.code,
             'ledger', l.code,
             'reason_code', ad.reason_code,
             'legislation_pack', ad.legislation_pack_code,
             'dimensions', ad.dimensions,
             'note', ad.note,
             'effective_from', ad.valid_from)
      from t
      join erp.account_determination ad
        on ad.tenant_id = t.tenant_id and ad.status = 'active'
       and daterange(ad.valid_from, ad.valid_to, '[)') @> current_date
      join erp.account a on a.id = ad.account_id
      left join erp.posting_class ic  on ic.id = ad.item_class_id
      left join erp.posting_class pcl on pcl.id = ad.party_class_id
      left join erp.site s   on s.id = ad.site_id
      left join erp.entity e on e.id = ad.entity_id
      left join erp.ledger l on l.id = ad.ledger_id

    union all

    select 'classification_axis',
           ca.code,
           jsonb_build_object(
             'code', ca.code,
             'name', ca.name,
             'name_key', ca.name_key,
             'is_mandatory', ca.is_mandatory,
             'seq', ca.seq,
             'item_classes', array_to_string(ca.item_classes, ','))
      from t
      join erp.classification_axis ca
        on ca.tenant_id = t.tenant_id and ca.status = 'active'
       and daterange(ca.valid_from, ca.valid_to, '[)') @> current_date

    union all

    select 'classification_value',
           ca.code || '|' || cv.code,
           jsonb_build_object(
             'axis', ca.code,
             'code', cv.code,
             'name', cv.name,
             'name_key', cv.name_key,
             'abbreviation', cv.abbreviation,
             'parent', pv.code)
      from t
      join erp.classification_value cv
        on cv.tenant_id = t.tenant_id and cv.status = 'active'
       and daterange(cv.valid_from, cv.valid_to, '[)') @> current_date
      join erp.classification_axis ca on ca.id = cv.axis_id
      left join erp.classification_value pv on pv.id = cv.parent_value_id

    union all

    -- Only the newest version of a template. Superseded versions are kept
    -- because assigned codes still point at them, and promoting a superseded
    -- version would hand the target a template the source has moved past.
    select 'code_template',
           ct.code,
           jsonb_build_object(
             'code', ct.code,
             'name', ct.name,
             'entity', e.code,
             'segments', ct.segments,
             'casing', ct.casing,
             'item_classes', array_to_string(ct.item_classes, ','))
      from t
      join erp.code_template ct on ct.tenant_id = t.tenant_id and ct.status = 'active'
       and daterange(ct.valid_from, ct.valid_to, '[)') @> current_date
       and ct.version = (select max(c2.version) from erp.code_template c2
                          where c2.tenant_id = ct.tenant_id and c2.code = ct.code)
      left join erp.entity e on e.id = ct.entity_id

    union all

    select 'release_area',
           s.code || '|' || ra.code,
           jsonb_build_object(
             'site', s.code,
             'code', ra.code,
             'name', ra.name,
             'location', lo.code,
             'replenishment_mode', ra.replenishment_mode,
             'channel', ra.channel_code,
             'order_type', ra.order_type_code,
             'item_classes', array_to_string(ra.item_classes, ','),
             'min_quantity', ra.min_quantity,
             'max_quantity', ra.max_quantity,
             'ageing_hours', ra.ageing_hours,
             'gate_printing', ra.gate_printing)
      from t
      join erp.release_area ra on ra.tenant_id = t.tenant_id and ra.status = 'active'
       and daterange(ra.valid_from, ra.valid_to, '[)') @> current_date
      join erp.site s on s.id = ra.site_id
      left join erp.location lo on lo.id = ra.location_id

    union all

    -- ── Starter Content Packs: capture for the eight surfaces the register
    --    now claims. Promotion without capture is one-way — a change set can
    --    be authored into an organisation but never lifted back out of one.

    select 'capability',
           tc.capability_code,
           jsonb_build_object(
             'code', tc.capability_code,
             'enabled', tc.is_enabled,
             'reason', tc.reason,
             'effective_from', tc.valid_from)
      from t
      join erp.tenant_capability tc on tc.tenant_id = t.tenant_id
       and daterange(tc.valid_from, tc.valid_to, '[)') @> current_date

    union all

    select 'reason_code',
           rc.category_code || '|' || rc.code,
           jsonb_build_object(
             'category', rc.category_code,
             'code', rc.code,
             'name', rc.name,
             'requires_note', rc.requires_note,
             'requires_approval', rc.requires_approval,
             'seq', rc.seq)
      from t
      join erp.reason_code rc on rc.tenant_id = t.tenant_id and rc.status = 'active'

    union all

    select 'calendar',
           c.code,
           jsonb_build_object(
             'code', c.code,
             'name', c.name,
             'timezone', c.timezone,
             'working_days', to_jsonb(c.working_days),
             'exceptions', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'date', ce.exception_date,
                        'is_working', ce.is_working,
                        'description', ce.description_key)
                      order by ce.exception_date)
                 from erp.calendar_exception ce
                where ce.tenant_id = c.tenant_id and ce.calendar_id = c.id),
               '[]'::jsonb))
      from t
      join erp.calendar c on c.tenant_id = t.tenant_id and c.status = 'active'

    union all

    select 'sod_rule',
           sr.code,
           jsonb_build_object(
             'code', sr.code,
             'name', sr.name,
             'description', sr.description,
             'permissions_a', array_to_string(sr.permissions_a, ','),
             'permissions_b', array_to_string(sr.permissions_b, ','),
             'severity', sr.severity,
             'mitigation', sr.mitigation_guidance)
      from t
      join erp.sod_rule sr on sr.tenant_id = t.tenant_id and sr.status = 'active'

    union all

    select 'numbering_rule',
           nr.code,
           jsonb_build_object(
             'code', nr.code,
             'entity', e.code,
             'site', s.code,
             'prefix', nr.prefix,
             'suffix', nr.suffix,
             'pad_to', nr.pad_to,
             'reset_period', nr.reset_period)
      from t
      join erp.numbering_rule nr on nr.tenant_id = t.tenant_id and nr.status = 'active'
      left join erp.entity e on e.id = nr.entity_id
      left join erp.site s on s.id = nr.site_id
    -- next_value is deliberately not captured. A manifest is a statement of
    -- configuration, and how far a sequence has counted is state: carrying it
    -- across would rewind or fast-forward the target's own numbering.

    union all

    select 'document_type',
           dt.code,
           jsonb_build_object(
             'code', dt.code,
             'base_type', dt.base_type_code,
             'name', dt.name,
             'entity', e.code,
             'site', s.code,
             'numbering_rule', nr.code,
             'state_machine', dt.state_machine_code,
             'approval_chain', dt.approval_chain_code,
             'stock_movement_type', dt.stock_movement_type,
             'posting_rule', dt.posting_rule_code,
             'create_permission', dt.create_permission)
      from t
      join erp.document_type dt on dt.tenant_id = t.tenant_id and dt.status = 'active'
      -- Inner, deliberately: a document type with no sequence cannot issue a
      -- reference, so it is not configuration another environment could adopt.
      -- erp.assert_no_dead_configuration() is where that shows up as a finding.
      join erp.numbering_rule nr on nr.id = dt.numbering_rule_id
      left join erp.entity e on e.id = dt.entity_id
      left join erp.site s on s.id = dt.site_id

    union all

    select 'output_template',
           ot.code,
           jsonb_build_object(
             'code', ot.code,
             'name_key', ot.name_key,
             'kind', ot.kind,
             'base_type', ot.base_type_code,
             'page', ot.page,
             'blocks', ot.blocks)
           || case when otv.id is null then '{}'::jsonb else jsonb_build_object(
                'version', jsonb_build_object(
                  'rendering_engine', otv.rendering_engine,
                  'page', otv.page,
                  'blocks', otv.blocks,
                  'required_permission', otv.required_permission,
                  'label_language', otv.label_language,
                  'test_render', otv.test_render,
                  'decode_check_passed', otv.decode_check_passed,
                  'decoded_value', otv.decoded_value)) end
      from t
      join erp.output_template ot on ot.tenant_id = t.tenant_id and ot.status = 'active'
      left join erp.output_template_version otv
        on otv.tenant_id = ot.tenant_id and otv.output_template_id = ot.id
       and otv.status = 'active'
       and daterange(otv.effective_from, otv.effective_to, '[)') @> current_date

    union all

    select 'printer',
           pr.code,
           jsonb_build_object(
             'code', pr.code,
             'site', si.code,
             'name', pr.name,
             'printer_type', pr.printer_type,
             'language', pr.language,
             'dots_per_inch', pr.dots_per_inch,
             'physical_location', pr.physical_location,
             'default_stock', pr.default_stock,
             'queue_address', pr.queue_address)
      from t
      join erp.printer pr on pr.tenant_id = t.tenant_id and pr.status = 'active'
      join erp.site si on si.tenant_id = pr.tenant_id and si.id = pr.site_id

    union all

    select 'notification_template',
           nt.code,
           jsonb_build_object(
             'code', nt.code,
             'channel_kind', nt.channel_kind,
             'subject_key', nt.subject_key,
             'body_key', nt.body_key)
      from t
      join erp.notification_template nt on nt.tenant_id = t.tenant_id

    union all

    select 'kpi',
           k.code,
           jsonb_build_object(
             'code', k.code,
             'name', k.name,
             'name_key', k.name_key,
             'description', k.description,
             'module_code', k.module_code,
             'unit', k.unit,
             'currency_scoped', k.currency_scoped,
             'higher_is_better', k.higher_is_better)
      from t
      join erp.kpi k on k.tenant_id = t.tenant_id

    union all

    select 'report',
           rp.code,
           jsonb_build_object(
             'code', rp.code,
             'name', rp.name,
             'name_key', rp.name_key,
             'description', rp.description,
             'module_code', rp.module_code,
             'kpi_codes', array_to_string(rp.kpi_codes, ','),
             'audience_role_codes', array_to_string(rp.audience_role_codes, ','))
           -- §19.2. Capture the definition in force, not the history: a
           -- promotion carries what the report IS today. Emitted as a nested
           -- object rather than its own kind, so a report and its definition
           -- cannot be lifted out separately and land apart.
           || case when rv.id is null then '{}'::jsonb else jsonb_build_object(
                'version', jsonb_build_object(
                  'view', gv.code,
                  'columns', to_jsonb(rv.columns),
                  'group_by', to_jsonb(rv.group_by),
                  'default_sort', to_jsonb(rv.default_sort),
                  'output_formats', to_jsonb(rv.output_formats),
                  'required_permission', rv.required_permission,
                  'time_budget_ms', rv.time_budget_ms,
                  'row_cap', rv.row_cap,
                  'parameters', coalesce((
                    select jsonb_agg(jsonb_build_object(
                             'code', pa.code, 'name_key', pa.name_key,
                             'data_type', pa.data_type,
                             'is_required', pa.is_required,
                             'default_value', pa.default_value,
                             'filters_column', pa.filters_column)
                           order by pa.code)
                      from erp.report_parameter pa
                     where pa.tenant_id = rv.tenant_id
                       and pa.report_version_id = rv.id), '[]'::jsonb))) end
      from t
      join erp.report rp on rp.tenant_id = t.tenant_id and rp.status = 'active'
      left join erp.report_version rv
        on rv.tenant_id = rp.tenant_id and rv.report_id = rp.id
       and rv.status = 'active'
       and daterange(rv.effective_from, rv.effective_to, '[)') @> current_date
      left join erp.governed_view gv
        on gv.tenant_id = rv.tenant_id and gv.id = rv.governed_view_id

  )
  select en.object_kind, en.object_key, en.content, md5(en.content::text)
    from entries en
   where p_kinds is null or en.object_kind = any (p_kinds)
   order by 1, 2$function$
;


-- ── The register, and the generator that turns it into triggers ────────────
insert into erp_meta.promotable_surface (schema_name, table_name, object_kind, rationale) values
  ('erp','report_version','report',
   'The definition a report run names when it says which version produced a figure. It travels inside the report item rather than as a kind of its own, so a report and its definition cannot be promoted apart — which is the failure v1.2 §19.2 describes.'),
  ('erp','report_parameter','report',
   'What a report may be asked, and therefore what it may be asked to widen. Promoted with the version it belongs to, because a version whose parameters stayed behind accepts nothing it was designed to accept.'),
  ('erp','output_template_version','output_template',
   'What actually renders, including the decode check that proves a label will scan. §15.4 makes that check the condition of an active label version, so it must move with it.'),
  ('erp','printer','printer',
   'v1.2 §15.4. Queue address, language and resolution decide what comes out when somebody presses print, which is the same test erp.document_type passes. A sandbox that cannot mirror production''s printers cannot rehearse a print run.');
select erp.apply_live_config_guards();


-- ── The two decisions this settles, and the one it opens and closes at once ─
update erp_meta.policy_decision set
  status = 'accepted',
  decision = 'erp.report_version and erp.report_parameter are promotable surfaces, carried inside the report change-set item rather than as a kind of their own.',
  rationale = 'Giving the version its own kind would let a report and its definition be promoted separately, which is the split this decision was opened about. Nesting the version inside the report item makes them one atomic change: they arrive together or neither does.',
  evidence = 'erp_meta.promotable_surface names both against object_kind report; erp.apply_change_set_item promotes the nested version through erp.upsert_report_version(); erp.configuration_manifest reads it back out; and erp_test.promotion_completeness_suite() promotes a report with no version, shows the receiving organisation failing erp.assert_reports_reproducible(), then promotes one with a version and shows it sound.',
  decided_at = now()
 where code = 'report_version_outside_promotion';

update erp_meta.policy_decision set
  status = 'accepted',
  decision = 'erp.output_template_version and erp.printer are promotable surfaces. erp.email_suppression is deliberately NOT, and is recorded separately.',
  rationale = 'A template version carries the decode check that proves a label will scan, and §15.4 makes that check the condition of an active label version, so it must move with it. A printer decides what comes out when somebody presses print, which is the same test erp.document_type passes. Suppression is neither: it is produced by delivery outcomes rather than authored.',
  evidence = 'erp_meta.promotable_surface names output_template_version against object_kind output_template and printer against its own kind; erp_test.promotion_completeness_suite() refuses a label whose decode check did not pass, shows nothing of that change set landing, and binds a promoted printer to the receiving environment''s own site by code.',
  decided_at = now()
 where code = 'output_model_outside_promotion';

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'email_suppression_is_not_configuration',
  'Email suppression stays outside promotion',
  'v1.2 §15.5',
  'erp.email_suppression is not a promotable surface and carries no live-config guard.',
  'It records that an address bounced, complained or unsubscribed — produced by delivery outcomes, not authored by anybody, which is why it carries no attribution columns while every configuration surface does. Promoting it would be wrong in both directions: a sandbox''s test bounces would suppress real customers, and production''s list would copy real addresses into a less controlled environment. Guarding it would be wrong too, because a bounce arrives at three in the morning without a change set, and a guard would mean the address kept being written to.',
  'accepted',
  'erp_test.promotion_completeness_suite() asserts it is absent from erp_meta.promotable_surface and from erp.configuration_manifest(), and that a suppression still lands on a live organisation with no change set.');


-- ── erp_test.reporting_suite() authored report versions directly, and said in
--    a comment that it could only do so because the tables were outside
--    promotion. They are inside it now, so those writes are refused. Its
--    subject is what §19.2 promises about RUNS, so it authors inside the
--    bootstrap window it already opened for its first fixture and closes it
--    again immediately — every erp.run_report() below still executes against a
--    live organisation. The promotion route is proven by the suite built for
--    it. ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION erp_test.reporting_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  r record;
  ad uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzrep-a';
  v_view uuid; v_report uuid; v_v1 uuid; v_v2 uuid;
  v_ok boolean; v_msg text; res jsonb; v_run uuid;
begin
  select * into r from erp.provision_tenant(
    v_code, 'Reporting A', 'admin-a@zzrep.test', 'Reporting A Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email) values (ad, 'admin-a@zzrep.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- erp.provision_tenant() declares the self environment live at the end, and
  -- erp.report carries a live-config guard — correctly, per D4. Building the
  -- fixture is configuration authoring, which belongs inside the bootstrap
  -- window, so the suite opens one rather than editing around the guard. The
  -- window closes before the run cases, so every erp.run_report() below is
  -- executed against a LIVE organisation, which is the state that matters.
  perform erp_test.reopen_bootstrap_window(v_tenant);

  insert into erp.governed_view
    (tenant_id, code, name, description, source_schema, source_name,
     required_permission, data_classes, lineage_columns)
  values (v_tenant, 'stock_position', 'Stock position',
          'On-hand by item and location.', 'erp', 'stock_movement',
          'reporting.read', '{}', '{item_id,location_id}')
  returning id into v_view;

  insert into erp.report
    (tenant_id, code, name, description, governed_view_id, kpi_codes,
     audience_role_codes, status)
  values (v_tenant, 'stock_by_site', 'Stock by site',
          'What is on hand, by site.', v_view, '{}', '{}', 'active')
  returning id into v_report;

  begin
    perform erp.assert_reports_reproducible();
    v_ok := false; v_msg := 'a report with no version was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_NOT_REPRODUCIBLE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a report with no version fails the assertion', v_ok, v_msg;

  insert into erp.report_version
    (tenant_id, report_id, version, governed_view_id, columns, group_by,
     default_sort, output_formats, required_permission,
     time_budget_ms, row_cap, status, effective_from)
  values (v_tenant, v_report, 1, v_view,
          '{site_code,item_code,quantity}', '{site_code}', '{site_code}',
          '{csv,pdf}', 'reporting.read', 5000, 100, 'active', current_date - 1)
  returning id into v_v1;

  return query select 'and passes once it has one',
    erp.assert_reports_reproducible() is not null, 'version 1 in force';

  -- Live from here. Everything below runs against a live organisation.
  perform erp_test.close_bootstrap_window(v_tenant);

  res := erp.run_report('stock_by_site', '{}'::jsonb, 10, 100);
  v_run := (res ->> 'run_id')::uuid;

  return query select 'a run completes within budget',
    (res ->> 'outcome') = 'completed', res ->> 'outcome';

  return query select 'and records the version that produced the figure',
    (select rr.version from erp.report_run rr where rr.id = v_run) = 1,
    'so a figure quoted in a meeting can be reproduced exactly';

  return query select 'and who ran it, and when',
    (select rr.run_by is not null and rr.run_at is not null
       from erp.report_run rr where rr.id = v_run),
    'a figure nobody can attribute is a figure nobody can question';

  -- report_version and report_parameter are promotable surfaces now, so on a
  -- live organisation the supported route for a new version is a change set —
  -- which erp_test.promotion_completeness_suite() proves end to end. This
  -- suite's subject is what §19.2 promises about RUNS, so it authors inside
  -- the same bootstrap window it opened for the first fixture and closes it
  -- again immediately: every erp.run_report() below still executes against a
  -- live organisation, which is the state that matters here.
  perform erp_test.reopen_bootstrap_window(v_tenant);

  update erp.report_version set effective_to = current_date, status = 'superseded'
   where id = v_v1;

  insert into erp.report_version
    (tenant_id, report_id, version, governed_view_id, columns, group_by,
     default_sort, output_formats, required_permission,
     time_budget_ms, row_cap, status, effective_from)
  values (v_tenant, v_report, 2, v_view,
          '{site_code,item_code,quantity,value_minor}', '{site_code}',
          '{site_code}', '{csv}', 'reporting.read', 5000, 100, 'active',
          current_date)
  returning id into v_v2;

  perform erp_test.close_bootstrap_window(v_tenant);

  res := erp.run_report('stock_by_site', '{}'::jsonb, 10, 100);

  return query select 'a later run uses the version now in force',
    (res ->> 'version')::integer = 2, format('version %s', res ->> 'version');

  return query select 'while the earlier figure still names the version that made it',
    (select rr.version from erp.report_run rr where rr.id = v_run) = 1,
    'the whole point of recording the version rather than the report';

  return query select 'and only one version is in force at a time',
    erp.assert_reports_reproducible() is not null,
    'two in force would make reproduced-exactly depend on which was chosen';

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.report_parameter
    (tenant_id, report_version_id, code, data_type, is_required, filters_column)
  values (v_tenant, v_v2, 'as_at', 'date', true, 'occurred_at');
  perform erp_test.close_bootstrap_window(v_tenant);

  begin
    perform erp.run_report('stock_by_site', '{}'::jsonb, 10, 100);
    v_ok := false; v_msg := 'a required parameter was not required';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_PARAMETER_MISSING%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a required parameter is required', v_ok, v_msg;

  begin
    perform erp.run_report('stock_by_site',
                           '{"as_at":"2026-09-01","entity_id":"anything"}'::jsonb, 10, 100);
    v_ok := false; v_msg := 'an undeclared parameter was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_PARAMETER_UNKNOWN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and a parameter nobody declared is refused', v_ok, v_msg;

  res := erp.run_report('stock_by_site', '{"as_at":"2026-09-01"}'::jsonb, 10, 100);
  return query select 'while the declared one is accepted and recorded',
    (res ->> 'outcome') = 'completed'
      and (select rr.parameters ->> 'as_at' from erp.report_run rr
            where rr.id = (res ->> 'run_id')::uuid) = '2026-09-01',
    'the parameters are recorded, not only the report';

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.report_parameter
    (tenant_id, report_version_id, code, data_type, is_required, filters_column)
  values (v_tenant, v_v2, 'company', 'uuid', false, 'entity_id');
  perform erp_test.close_bootstrap_window(v_tenant);

  begin
    perform erp.assert_reports_reproducible();
    v_ok := false; v_msg := 'a parameter filtering a scoping column was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_NOT_REPRODUCIBLE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a parameter that filters a scoping column is refused', v_ok, v_msg;

  perform erp_test.reopen_bootstrap_window(v_tenant);
  delete from erp.report_parameter
   where tenant_id = v_tenant and report_version_id = v_v2 and code = 'company';
  perform erp_test.close_bootstrap_window(v_tenant);

  res := erp.run_report('stock_by_site', '{"as_at":"2026-09-01"}'::jsonb, 5000, 100);
  return query select 'beyond the row cap the request defers rather than failing',
    (res ->> 'outcome') = 'deferred_to_extract',
    'the request becomes a scheduled extract rather than failing';

  return query select 'and says which budget it hit',
    (res ->> 'extract_reason') like '%rows against a cap of 100%',
    coalesce(res ->> 'extract_reason', '(none)');

  res := erp.run_report('stock_by_site', '{"as_at":"2026-09-01"}'::jsonb, 10, 60000);
  return query select 'the time budget defers it too',
    (res ->> 'outcome') = 'deferred_to_extract'
      and (res ->> 'extract_reason') like '%against a budget of 5000ms%',
    coalesce(res ->> 'extract_reason', '(none)');

  return query select 'and a deferral is recorded as a run, not lost',
    (select count(*) from erp.report_run rr
      where rr.tenant_id = v_tenant and rr.outcome = 'deferred_to_extract') = 2,
    'a question that was deferred is still a question somebody asked';

  -- §19.1: a report is not a way to see what a screen would refuse. The
  -- administrator holds every permission, so the check is that authorisation
  -- happens at all — proven by requiring one that does not exist, which
  -- erp.authorise() refuses.
  perform erp_test.reopen_bootstrap_window(v_tenant);
  update erp.report_version set required_permission = 'reporting.export' where id = v_v2;
  perform erp_test.close_bootstrap_window(v_tenant);
  begin
    perform erp.run_report('stock_by_site', '{"as_at":"2026-09-01"}'::jsonb, 10, 100);
    v_ok := true; v_msg := 'authorised on the version''s own permission';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 70);
  end;
  return query select 'the run authorises on the permission the VERSION names', v_ok, v_msg;

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id = ad;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code like 'zzrep-%')
      and not exists (select 1 from auth.users u where u.id = ad),
    'and the runs go with the organisation, because they are tenant-scoped';
end;$function$
;


-- ── The build fails here if the register and the deployed triggers disagree,
--    or if either model stopped being sound. ─────────────────────────────────

select erp.assert_configuration_promotable();
select erp.assert_reports_reproducible();
select erp.assert_output_integrity();
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
