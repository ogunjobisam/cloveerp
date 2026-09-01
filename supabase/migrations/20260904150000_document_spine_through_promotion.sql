-- =============================================================================
-- The document spine, through promotion
--
-- The recorded decision said document sequences are configuration that cannot
-- be promotion-guarded because six module installers write them directly. Two
-- things about that turned out to be wrong, and the second is the interesting
-- one.
--
-- It is four installers, not six. The six came from grepping migration files,
-- which counts inserts inside function bodies that later migrations replaced.
-- The catalogue says four: configure_procurement, configure_procurement_controls,
-- configure_production and configure_sales, plus erp.upsert_numbering_rule,
-- which is the promoter's own writer and must keep writing directly.
--
-- And the obstacle was never numbering. Installing a module on a LIVE
-- organisation today lands the numbering rules and the document types
-- immediately and ungoverned, while the state machines those document types
-- name wait in a submitted change set for a second administrator. Measured on
-- a fresh build: three numbering rules, three document types, zero state
-- machines, and erp.dead_configuration_report() answering "a document type
-- names a state machine that does not exist" three times over. A module
-- installs itself half into one governance regime and half into another, and
-- the half that lands first depends on the half that has not.
--
-- So this does not guard numbering and leave the rest. It moves the whole
-- spine — sequences and document types both — into the installer's own change
-- set, which is where every other thing a module installs already goes. After
-- it, installing a module on a live organisation changes nothing until
-- somebody approves it, which is what the submitted change set was always
-- claiming.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A document type the promoter can write
-- -----------------------------------------------------------------------------

create or replace function erp.upsert_document_type(
  p_code                text,
  p_base_type_code      text,
  p_name                text,
  p_numbering_rule_code text,
  p_entity_code         text default null,
  p_site_code           text default null,
  p_state_machine_code  text default null,
  p_approval_chain_code text default null,
  p_stock_movement_type text default null,
  p_posting_rule_code   text default null,
  p_create_permission   text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_rule   erp.numbering_rule%rowtype;
  v_entity uuid; v_site uuid; v_id uuid;
begin
  -- The sequence first, because a document type without one cannot issue a
  -- reference, and a type that exists but cannot be raised is worse than one
  -- that does not exist: it appears on menus. Both land in the same change
  -- set, and erp.promote_change_set() applies items in seq order, so the rule
  -- is already there — unless somebody built a change set that names a rule it
  -- does not carry, which is what this refusal is for.
  select * into v_rule from erp.numbering_rule
   where tenant_id = v_tenant and code = p_numbering_rule_code;
  if not found then
    raise exception
      'ERPWARE_UNKNOWN_NUMBERING_RULE: document type % names sequence %, which '
      'this organisation does not have', p_code, p_numbering_rule_code
      using errcode = '23503',
      hint = 'Add the numbering_rule item to the same change set, before the '
             'document_type item that needs it.';
  end if;

  -- Entity: explicit if given, otherwise the sequence's. Three installers set
  -- it two different ways — two pass the first active entity, one takes the
  -- rule's — and both reduce to this, because the rule they name carries the
  -- same entity either way.
  if p_entity_code is not null then
    select id into v_entity from erp.entity
     where tenant_id = v_tenant and code = p_entity_code;
    if v_entity is null then
      raise exception 'ERPWARE_UNKNOWN_ENTITY: %', p_entity_code using errcode = '23503';
    end if;
  else
    v_entity := v_rule.entity_id;
  end if;

  if p_site_code is not null then
    select id into v_site from erp.site
     where tenant_id = v_tenant and code = p_site_code;
    if v_site is null then
      raise exception 'ERPWARE_UNKNOWN_SITE: %', p_site_code using errcode = '23503';
    end if;
  else
    v_site := v_rule.site_id;
  end if;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id, site_id,
    state_machine_code, approval_chain_code, numbering_rule_id,
    stock_movement_type, posting_rule_code, create_permission)
  values (v_tenant, p_code, p_base_type_code, p_name, v_entity, v_site,
          p_state_machine_code, p_approval_chain_code, v_rule.id,
          p_stock_movement_type, p_posting_rule_code, p_create_permission)
  on conflict (tenant_id, code) do update
    set base_type_code = excluded.base_type_code,
        name = excluded.name,
        entity_id = excluded.entity_id,
        site_id = excluded.site_id,
        state_machine_code = excluded.state_machine_code,
        approval_chain_code = excluded.approval_chain_code,
        numbering_rule_id = excluded.numbering_rule_id,
        stock_movement_type = excluded.stock_movement_type,
        posting_rule_code = excluded.posting_rule_code,
        create_permission = excluded.create_permission,
        status = 'active', updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.upsert_document_type is
  'The promoter''s writer for erp.document_type. Resolves the sequence, the '
  'entity and the site by code, so a change set carries names rather than '
  'identifiers and can be promoted into an organisation that has never seen '
  'the one it was written against.';

-- -----------------------------------------------------------------------------
-- The promoter, and the manifest
--
-- Both DUMPED and patched at one block each. apply_change_set_item gains a
-- document_type branch (43 kinds, was 42) and configuration_manifest gains the
-- matching capture block, so a document type crosses environments as names
-- rather than identifiers.
-- -----------------------------------------------------------------------------

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
          nullif(p ->> 'parent', ''));
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
end;
$function$;

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
      from t
      join erp.report rp on rp.tenant_id = t.tenant_id and rp.status = 'active'

  )
  select en.object_kind, en.object_key, en.content, md5(en.content::text)
    from entries en
   where p_kinds is null or en.object_kind = any (p_kinds)
   order by 1, 2
$function$;

-- -----------------------------------------------------------------------------
-- The four installers
--
-- Each dumped from the built schema and patched: the direct writes come out,
-- the same values go in as change-set items, and the comments that explained
-- each document type travel with it. The ordering matters and is not
-- incidental — erp.add_change_set_item() numbers items in the order they
-- appear, erp.promote_change_set() applies them in that order, so every
-- sequence and lifecycle a document type names is already written when its own
-- item is reached.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION erp.configure_procurement(p_approval_threshold_minor bigint DEFAULT 1000000, p_approver_role text DEFAULT 'administrator'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_entity_code text;
  v_cs     uuid;
begin
  select e.id, e.code into v_entity, v_entity_code from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: configure an entity before a module'
      using errcode = '23503';
  end if;

  if not exists (select 1 from erp.ledger l
                  where l.tenant_id = v_tenant and l.status = 'active') then
    raise exception
      'ERPWARE_NO_LEDGER: this tenant has no chart of accounts, and procurement '
      'documents reach one'
      using errcode = '23503',
            hint = 'Run erp.configure_finance() first. The dependency is real: '
                   'a receipt that cannot be accounted for is not a receipt.';
  end if;

  v_cs := erp.install_module_config(
    'procurement-lifecycle', 'Procurement lifecycle',
    'Requisition, purchase order and receipt: their states, the transitions '
    'between them, and the approval a purchase order needs above a threshold.',
    jsonb_build_array(
      jsonb_build_object('kind','state_machine','key','requisition','payload',
        jsonb_build_object(
          'code','requisition','object_type','document','name','Requisition',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','submitted','name','Submitted','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','ordered','name','Ordered','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','submitted','required_permission','procurement.requisition'),
            jsonb_build_object('code','approve','name','Approve','from','submitted','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','submitted','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','order','name','Convert to order','from','approved','to','ordered','required_permission','procurement.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.requisition'),
            jsonb_build_object('code','cancel_submitted','name','Cancel','from','submitted','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','purchase_order','payload',
        jsonb_build_object(
          'code','purchase_order','object_type','document','name','Purchase order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','sent','name','Sent to supplier','is_committed',true,'sort_order',40),
            jsonb_build_object('code','partially_received','name','Partially received','is_committed',true,'sort_order',50),
            jsonb_build_object('code','received','name','Received','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit for approval','from','draft','to','pending_approval','required_permission','procurement.order'),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','send','name','Send to supplier','from','approved','to','sent','required_permission','procurement.order'),
            jsonb_build_object('code','receive_partial','name','Receive part','from','sent','to','partially_received','required_permission','procurement.receive'),
            jsonb_build_object('code','receive_rest','name','Receive remainder','from','partially_received','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','receive_all','name','Receive in full','from','sent','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','close','name','Close','from','received','to','closed','required_permission','procurement.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.order'),
            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','object_type','document','name','Goods receipt',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','procurement.receive'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.receive')))),

      jsonb_build_object('kind','approval_chain','key','purchase_order_value','payload',
        jsonb_build_object(
          'code','purchase_order_value','name','Purchase order value approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'purchase_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer_manager','name','Buying manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','finance','name','Finance',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','total_minor'), p_approval_threshold_minor)))))),

      -- The spine, in the change set and after the lifecycles it names.
      -- erp.promote_change_set() applies items in seq order and
      -- erp.add_change_set_item() assigns seq in the order they appear here,
      -- so a document type is written only once its state machine, its chain
      -- and its sequence exist. Written directly, as these were, they landed
      -- on a live organisation pointing at state machines still waiting for a
      -- second administrator — three of them, which
      -- erp.dead_configuration_report() reported and nothing refused.
      jsonb_build_object('kind','numbering_rule','key','requisition','payload',
        jsonb_build_object('code','requisition','entity',v_entity_code,
          'prefix','REQ-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','purchase_order','payload',
        jsonb_build_object('code','purchase_order','entity',v_entity_code,
          'prefix','PO-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','goods_receipt','payload',
        jsonb_build_object('code','goods_receipt','entity',v_entity_code,
          'prefix','GRN-','pad_to',6,'reset_period','yearly','next_value',1)),

      -- A requisition asks; it neither moves stock nor reaches a ledger, and
      -- product content says so. The nulls are the honest answer rather than
      -- an omission: erp.assert_no_dead_configuration() fails the build if a
      -- base type disagrees with them in either direction.
      jsonb_build_object('kind','document_type','key','requisition','payload',
        jsonb_build_object('code','requisition','base_type','requisition',
          'name','Requisition','entity',v_entity_code,
          'numbering_rule','requisition','state_machine','requisition')),
      -- An order commits. Nothing has moved and nothing is owed yet, so the
      -- entry belongs in the parallel commitment ledger, not the statutory one.
      jsonb_build_object('kind','document_type','key','purchase_order','payload',
        jsonb_build_object('code','purchase_order','base_type','purchase_order',
          'name','Purchase order','entity',v_entity_code,
          'numbering_rule','purchase_order','state_machine','purchase_order',
          'approval_chain','purchase_order_value',
          'posting_rule','purchase_commitment')),
      -- A receipt is the first point at which both ledgers have something to say.
      jsonb_build_object('kind','document_type','key','goods_receipt','payload',
        jsonb_build_object('code','goods_receipt','base_type','receipt',
          'name','Goods receipt','entity',v_entity_code,
          'numbering_rule','goods_receipt','state_machine','goods_receipt',
          'stock_movement_type','goods_receipt',
          'posting_rule','goods_receipt'))));

  return v_cs;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.configure_procurement_controls(p_approver_role text DEFAULT 'administrator'::text, p_over_receipt_pct numeric DEFAULT 5, p_price_variance_pct numeric DEFAULT 2, p_price_variance_minor bigint DEFAULT 100)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'procurement-controls', 'Procurement controls',
    'What may be received against an order, what may be invoiced against a '
    'receipt, and who has to look when neither agrees.',
    jsonb_build_array(
      jsonb_build_object('kind','approval_chain','key','match_exception','payload',
        jsonb_build_object(
          'code','match_exception','name','Invoice match exception',
          'object_type','match_exception',
          'applies_when','true'::jsonb, 'priority',100,
          'material_fields', jsonb_build_array('quantity_variance','price_variance_minor'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer','name','Buyer',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      jsonb_build_object('kind','receipt_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default receipt tolerance',
          'over_pct', p_over_receipt_pct,
          -- Under-delivery is not an error: the rest is still outstanding, and
          -- that is what the outstanding quantity is for.
          'under_pct', 100,
          'over_action','accept')),

      jsonb_build_object('kind','match_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default match tolerance',
          'quantity_pct', 0,
          'price_pct', p_price_variance_pct,
          'price_absolute_minor', p_price_variance_minor,
          'approval_chain','match_exception')),

      -- The purchase invoice, which procurement has been missing since it was
      -- built. Without it there is no third document to match against and, more
      -- pointedly, nothing ever debits goods-received-not-invoiced: the finance
      -- bridge credits 2100 on every receipt and the balance grows for ever.
      jsonb_build_object('kind','state_machine','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','object_type','document','name','Purchase invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','registered','name','Registered','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','disputed','name','Disputed','sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','register','name','Register','from','draft','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','dispute','name','Dispute','from','registered','to','disputed','required_permission','procurement.match'),
            jsonb_build_object('code','resolve','name','Resolve','from','disputed','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','pay','name','Record payment','from','registered','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.match')))),

      -- Registering the invoice is what clears GRNI: the receipt credited it,
      -- and this debits it and credits the supplier instead.
      jsonb_build_object('kind','posting_rule','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','name','Purchase invoice','ledger','GL',
          'event_type','document.purchase_invoice.registered',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','2100','side','debit','rate',1,
                               'description','Clearing goods received not invoiced'),
            jsonb_build_object('account','2000','side','credit','rate',1,
                               'description','Trade payable')))),

      -- The spine, in the change set. This installer took its document type's
      -- entity from the sequence rather than resolving one itself;
      -- erp.upsert_document_type() keeps that by inheriting the rule's entity
      -- when the payload names none, so no entity is stated here either.
      jsonb_build_object('kind','numbering_rule','key','purchase_invoice','payload',
        jsonb_build_object('code','purchase_invoice',
          'entity', (select e.code from erp.entity e
                      where e.tenant_id = v_tenant and e.status = 'active'
                      order by e.code limit 1),
          'prefix','PINV-','pad_to',6,'reset_period','yearly','next_value',1)),
      -- Base invoice_reference carries sales.invoice, which is right for
      -- sales_invoice and wrong here: every transition on this lifecycle wants
      -- procurement.match, so raising one must too.
      jsonb_build_object('kind','document_type','key','purchase_invoice','payload',
        jsonb_build_object('code','purchase_invoice',
          'base_type','invoice_reference','name','Purchase invoice',
          'numbering_rule','purchase_invoice','state_machine','purchase_invoice',
          'posting_rule','purchase_invoice',
          'create_permission','procurement.match'))));

  return v_cs;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.configure_production(p_issue_method erp.issue_method DEFAULT 'backflush'::erp.issue_method)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_entity_code text;
  v_cs     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'works_order', null);

  select e.id, e.code into v_entity, v_entity_code from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  -- The variance accounts. Split, because the split is the point of measuring.
  insert into erp.account (
    tenant_id, entity_id, code, name, account_type, is_postable, currency, status)
  select v_tenant, v_entity, a.code, a.name, 'expense'::erp.account_type, true,
         e.base_currency, 'active'
    from (values
      ('5100', 'Work in progress'),
      ('9200', 'Material usage variance'),
      ('9300', 'Labour efficiency variance')
    ) as a(code, name)
    join erp.entity e on e.id = v_entity
  on conflict (tenant_id, entity_id, code) do update set status = 'active';

  v_cs := erp.install_module_config(
    'production', 'Production',
    'How works orders consume material and how the difference between what '
    'they should have cost and what they did is accounted for.',
    jsonb_build_array(
      -- The sequence goes through the change set like everything else the
      -- module installs. It used to be written directly, above, which on a
      -- live organisation meant half the module landed before anybody had
      -- approved the other half.
      jsonb_build_object('kind','numbering_rule','key','works_order','payload',
        jsonb_build_object(
          'code','works_order', 'entity', v_entity_code, 'prefix','WO-',
          'pad_to', 6, 'reset_period','yearly', 'next_value', 1)),
      jsonb_build_object('kind','config','key','production.issue_method','payload',
        jsonb_build_object(
          'config_type','production.issue_method',
          'value', to_jsonb(p_issue_method::text)))));

  return v_cs;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.configure_sales(p_discount_threshold_pct numeric DEFAULT 15, p_approver_role text DEFAULT 'administrator'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_entity_code text;
  v_cs     uuid;
begin
  select e.id, e.code into v_entity, v_entity_code from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: configure an entity before a module'
      using errcode = '23503';
  end if;

  if not exists (select 1 from erp.ledger l
                  where l.tenant_id = v_tenant and l.status = 'active') then
    raise exception
      'ERPWARE_NO_LEDGER: this tenant has no chart of accounts, and sales '
      'documents reach one'
      using errcode = '23503',
            hint = 'Run erp.configure_finance() first. The dependency is real: '
                   'a receipt that cannot be accounted for is not a receipt.';
  end if;

  v_cs := erp.install_module_config(
    'sales-lifecycle', 'Sales lifecycle',
    'Quotation, sales order and delivery: their states, the approvals a '
    'discount and a credit exposure require, and the despatch that moves stock.',
    jsonb_build_array(
      jsonb_build_object('kind','state_machine','key','quotation','payload',
        jsonb_build_object(
          'code','quotation','object_type','document','name','Quotation',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','sent','name','Sent','sort_order',20),
            jsonb_build_object('code','accepted','name','Accepted','is_terminal',true,'sort_order',30),
            jsonb_build_object('code','expired','name','Expired','is_terminal',true,'sort_order',40),
            jsonb_build_object('code','declined','name','Declined','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','send','name','Send','from','draft','to','sent','required_permission','sales.order'),
            jsonb_build_object('code','accept','name','Accept','from','sent','to','accepted','required_permission','sales.order'),
            jsonb_build_object('code','decline','name','Decline','from','sent','to','declined','required_permission','sales.order'),
            jsonb_build_object('code','expire','name','Expire','from','sent','to','expired','required_permission','sales.order')))),

      jsonb_build_object('kind','state_machine','key','sales_order','payload',
        jsonb_build_object(
          'code','sales_order','object_type','document','name','Sales order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','confirmed','name','Confirmed','is_committed',true,'sort_order',30),
            jsonb_build_object('code','picking','name','Picking','is_committed',true,'sort_order',40),
            jsonb_build_object('code','despatched','name','Despatched','is_committed',true,'sort_order',50),
            jsonb_build_object('code','invoiced','name','Invoiced','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','pending_approval','required_permission','sales.order'),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','confirmed','required_permission','sales.order'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','sales.order'),
            jsonb_build_object('code','pick','name','Start picking','from','confirmed','to','picking','required_permission','sales.despatch'),
            jsonb_build_object('code','despatch','name','Despatch','from','picking','to','despatched','required_permission','sales.despatch'),
            jsonb_build_object('code','invoice','name','Invoice','from','despatched','to','invoiced','required_permission','sales.invoice'),
            jsonb_build_object('code','close','name','Close','from','invoiced','to','closed','required_permission','sales.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.order'),
            jsonb_build_object('code','cancel_confirmed','name','Cancel','from','confirmed','to','cancelled','required_permission','sales.order')))),

      -- An invoice is raised, issued, and either paid or credited. It moves no
      -- stock; what it does is turn a despatch into a receivable, which is why
      -- it is the only document type here that reaches a ledger and not a
      -- warehouse.
      jsonb_build_object('kind','state_machine','key','sales_invoice','payload',
        jsonb_build_object(
          'code','sales_invoice','object_type','document','name','Sales invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','issued','name','Issued','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','credited','name','Credited','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','sales.invoice'),
            jsonb_build_object('code','settle','name','Record payment','from','issued','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','credit','name','Credit','from','issued','to','credited','required_permission','sales.invoice'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.invoice')))),

      -- The mirror of goods receipt, and the whole point of the stock bridge:
      -- same shape, opposite direction, same posting code.
      jsonb_build_object('kind','state_machine','key','delivery','payload',
        jsonb_build_object(
          'code','delivery','object_type','document','name','Delivery',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','sales.despatch'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.despatch')))),

      -- Two bands on one chain. A discount above the threshold needs someone
      -- who may approve discounts; an order that takes the customer past their
      -- credit limit needs someone who may release credit. Either can fire
      -- alone, both can fire together, and neither is expressed in a second
      -- rule language — both are JsonLogic over the same context.
      jsonb_build_object('kind','approval_chain','key','sales_order_terms','payload',
        jsonb_build_object(
          'code','sales_order_terms','name','Sales order terms approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'sales_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id','max_discount_pct'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','sales_manager','name','Sales manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','discount','name','Discount approval',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','max_discount_pct'), p_discount_threshold_pct))),
            jsonb_build_object('seq',3,'code','credit','name','Credit release',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              -- The sum is computed into the context rather than in the rule,
              -- so the interpreter needs no arithmetic and the configured rule
              -- stays one readable comparison.
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','exposure_after_minor'),
                jsonb_build_object('var','credit_limit_minor'))))))),

      -- The spine, in the change set and after the lifecycles it names, for
      -- the same reason as procurement's: written directly, these landed on a
      -- live organisation ahead of the state machines they point at.
      jsonb_build_object('kind','numbering_rule','key','quotation','payload',
        jsonb_build_object('code','quotation','entity',v_entity_code,
          'prefix','QUO-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','sales_order','payload',
        jsonb_build_object('code','sales_order','entity',v_entity_code,
          'prefix','SO-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','delivery','payload',
        jsonb_build_object('code','delivery','entity',v_entity_code,
          'prefix','DN-','pad_to',6,'reset_period','yearly','next_value',1)),
      jsonb_build_object('kind','numbering_rule','key','sales_invoice','payload',
        jsonb_build_object('code','sales_invoice','entity',v_entity_code,
          'prefix','INV-','pad_to',6,'reset_period','yearly','next_value',1)),

      jsonb_build_object('kind','document_type','key','quotation','payload',
        jsonb_build_object('code','quotation','base_type','quotation',
          'name','Quotation','entity',v_entity_code,
          'numbering_rule','quotation','state_machine','quotation')),
      -- The mirror of the purchase order: same parallel ledger, sides
      -- reversed, and nothing about that reversal is in code.
      jsonb_build_object('kind','document_type','key','sales_order','payload',
        jsonb_build_object('code','sales_order','base_type','sales_order',
          'name','Sales order','entity',v_entity_code,
          'numbering_rule','sales_order','state_machine','sales_order',
          'approval_chain','sales_order_terms','posting_rule','sales_commitment')),
      jsonb_build_object('kind','document_type','key','delivery','payload',
        jsonb_build_object('code','delivery','base_type','delivery',
          'name','Delivery','entity',v_entity_code,
          'numbering_rule','delivery','state_machine','delivery',
          'stock_movement_type','despatch','posting_rule','delivery')),
      -- The sales order lifecycle has always had an `invoice` transition into
      -- an `invoiced` state, and there was no invoice for it to raise. Spec
      -- 5.6 asks for "invoicing derived from validated delivery with role
      -- separation enforced" — the separation being that despatching and
      -- invoicing are different permissions, which the lifecycle already
      -- required and nothing could exercise.
      jsonb_build_object('kind','document_type','key','sales_invoice','payload',
        jsonb_build_object('code','sales_invoice','base_type','invoice_reference',
          'name','Sales invoice','entity',v_entity_code,
          'numbering_rule','sales_invoice','state_machine','sales_invoice',
          'posting_rule','sales_invoice'))));

  return v_cs;
end;
$function$;


-- -----------------------------------------------------------------------------
-- The register, which is what actually turns the guard on
-- -----------------------------------------------------------------------------

insert into erp_meta.promotable_surface (schema_name, table_name, object_kind, rationale)
values
  ('erp', 'numbering_rule', 'numbering_rule',
   'A document sequence decides what every reference in the organisation looks '
   'like and where it restarts. §4.8 lists it as configuration and it was the '
   'only §4.8 surface outside promotion — not because sequences are special, '
   'but because the document types that need them were outside too.'),
  ('erp', 'document_type', 'document_type',
   'A document type names a lifecycle, an approval chain, a sequence, a stock '
   'movement type and a posting rule. Every one of those is promoted; the row '
   'that ties them together was not, so the tying could be changed on a live '
   'organisation without anybody approving it.')
on conflict (schema_name, table_name) do update set
  object_kind = excluded.object_kind, rationale = excluded.rationale;

-- Generated from the register, not listed again here. Both tables get their
-- guard from this call, and erp.assert_configuration_promotable() reads the
-- same rows to check each has a promoter branch and a manifest block.
select erp.apply_live_config_guards();
select erp.assert_configuration_promotable();

-- -----------------------------------------------------------------------------
-- A sequence counts, and counting is not configuring
--
-- Registering erp.numbering_rule turned the procurement suite red on a line
-- nobody had thought about: erp.next_document_number() UPDATES the rule it
-- reads, advancing next_value and rolling current_period. The guard is a
-- blanket before-insert-or-update-or-delete trigger, so it refused a document
-- being raised — not a configuration edit at all.
--
-- The row carries two kinds of thing. Prefix, suffix, padding, reset period,
-- entity and site are configuration: they decide what every reference in the
-- organisation looks like, and changing one on a live organisation without
-- approval is exactly what promotion exists to prevent. next_value and
-- current_period are state: they are how far the sequence has counted.
--
-- erp.configuration_manifest() already knew this and said so — it captures the
-- rule and deliberately omits next_value, "because carrying it across would
-- rewind or fast-forward the target's own numbering". The guard did not know
-- it. So the distinction becomes a register that both can read, rather than a
-- comment in one function and a blind spot in another.
-- -----------------------------------------------------------------------------

create table if not exists erp_meta.live_mutable_column (
  schema_name text not null,
  table_name  text not null,
  column_name text not null,
  rationale   text not null,
  primary key (schema_name, table_name, column_name)
);

comment on table erp_meta.live_mutable_column is
  'Columns on a promotable surface that hold state rather than configuration, '
  'so a live organisation may change them without a change set. Read by '
  'erp.guard_live_configuration(). Deliberately tiny: every row here is a hole '
  'in the promotion guarantee, and each one has to earn its place by being '
  'something the product itself writes in the course of operating.';

select erp_meta.register_table('erp_meta', 'live_mutable_column', 'platform_internal',
  'Which columns on a guarded table are state rather than configuration.');

insert into erp_meta.live_mutable_column (schema_name, table_name, column_name, rationale)
values
  ('erp', 'numbering_rule', 'next_value',
   'How far the sequence has counted. erp.next_document_number() advances it '
   'every time a document is raised, which is operating the organisation '
   'rather than configuring it.'),
  ('erp', 'numbering_rule', 'current_period',
   'Which period the sequence is counting within, rolled by the same function '
   'when reset_period says the count starts again. The period a sequence '
   'resets ON is configuration; the period it is IN is not.')
on conflict (schema_name, table_name, column_name) do update set
  rationale = excluded.rationale;

create or replace function erp.guard_live_configuration()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid;
  v_live    boolean;
  v_changed text[];
begin
  v_tenant := coalesce(new.tenant_id, old.tenant_id);

  -- A promotion is in progress: this write IS the supported route.
  if nullif(current_setting('erp.promotion_id', true), '') is not null then
    return coalesce(new, old);
  end if;

  -- A tenant purge takes everything, configuration included.
  if nullif(current_setting('erp.purge_tenant_id', true), '')::uuid = v_tenant then
    return coalesce(new, old);
  end if;

  select e.is_live into v_live
    from erp.environment e
   where e.tenant_id = v_tenant and e.is_self;

  -- Until a tenant declares this environment live, it is being built. The
  -- guard would otherwise make onboarding impossible.
  if not coalesce(v_live, false) then
    return coalesce(new, old);
  end if;

  -- An update that touches only state columns is the product operating, not
  -- somebody configuring. Insert and delete are never that: a row appearing or
  -- disappearing is a configuration change whatever columns it carries.
  if tg_op = 'UPDATE' then
    select coalesce(array_agg(n.k), '{}')
      into v_changed
      from jsonb_each(to_jsonb(new)) as n(k, v)
      left join jsonb_each(to_jsonb(old)) as o(k, v) on o.k = n.k
     where n.v is distinct from o.v
       -- Housekeeping, written by the attribution triggers on every update.
       and n.k not in ('updated_at', 'updated_by')
       and not exists (
         select 1 from erp_meta.live_mutable_column lmc
          where lmc.schema_name = tg_table_schema
            and lmc.table_name = tg_table_name
            and lmc.column_name = n.k);

    if v_changed = '{}' then
      return new;
    end if;

    raise exception
      'ERPWARE_LIVE_CONFIG_EDIT: % may not be changed directly in a live '
      'environment; promote a change set instead (columns: %)',
      tg_table_name, array_to_string(v_changed, ', ')
      using errcode = '42501',
            hint = 'erp.promote_change_set() is the supported route. For an '
                   'emergency, erp.set_kill_switch() disables a target without '
                   'editing it.';
  end if;

  raise exception
    'ERPWARE_LIVE_CONFIG_EDIT: % may not be changed directly in a live environment; promote a change set instead',
    tg_table_name
    using errcode = '42501',
          hint = 'erp.promote_change_set() is the supported route. For an emergency, erp.set_kill_switch() disables a target without editing it.';
end;
$$;

comment on function erp.guard_live_configuration is
  'Refuses a direct configuration edit on a live organisation. An update that '
  'changes only columns registered in erp_meta.live_mutable_column is allowed '
  'through — a sequence advancing its counter is the product operating rather '
  'than somebody configuring — and the message now names the columns that were '
  'refused, which "numbering_rule may not be changed" did not.';

-- -----------------------------------------------------------------------------
-- Two suites that build broken configuration on purpose
--
-- erp_test.sales_suite() and erp_test.finance_suite() prove that
-- erp.assert_no_dead_configuration() catches a document type that moves stock
-- and names no movement type, or reaches a ledger and names no posting rule.
-- They build one by updating erp.document_type directly — which the guard now
-- refuses, correctly, because that is the whole point of registering the table.
--
-- The cases are still worth having: dead configuration can arrive through a
-- promoted change set or be built during the bootstrap window, and
-- erp.go_live() refuses to close that window over it. So the sabotage moves to
-- where such a mistake can actually be made, rather than being exempted from
-- the guard it exists alongside. The suites say so out loud instead of
-- silently poking erp.environment mid-test.
-- -----------------------------------------------------------------------------

create or replace function erp_test.reopen_bootstrap_window(p_tenant uuid)
returns void
language sql
set search_path = ''
as $$
  update erp.environment set is_live = false
   where tenant_id = p_tenant and is_self;
$$;

comment on function erp_test.reopen_bootstrap_window is
  'Puts an organisation back into the state it was in while being built, so a '
  'suite can construct the broken configuration it means to catch. Only a '
  'test does this: erp.go_live() is the one-way door in the product.';

create or replace function erp_test.close_bootstrap_window(p_tenant uuid)
returns void
language sql
set search_path = ''
as $$
  update erp.environment set is_live = true
   where tenant_id = p_tenant and is_self;
$$;

comment on function erp_test.close_bootstrap_window is
  'The other half of erp_test.reopen_bootstrap_window(). A suite that left an '
  'organisation not live would make every later case in it meaningless, '
  'because the guard it is testing would never fire.';
CREATE OR REPLACE FUNCTION erp_test.sales_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  cs0 uuid; cs1 uuid; cs2 uuid; v_second uuid; v_tok text; res jsonb; t record;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid;
  v_sup uuid; v_cust uuid; v_item uuid;
  v_grn uuid; v_dn uuid; v_so uuid; v_quo uuid; v_dn2 uuid;
  q0 numeric; q1 numeric; q2 numeric;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzsales','Sales Suite','a@zzsales.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzsales.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  cs0 := erp.configure_finance();
  cs1 := erp.configure_procurement(1000000);
  cs2 := erp.configure_sales(15);

  return query select 'two modules install through one shared installer',
    cs1 is not null and cs2 is not null and cs1 <> cs2,
    'erp.install_module_config() authored both';

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(cs0); perform erp.promote_change_set(cs0);
  perform erp.approve_change_set(cs1); perform erp.promote_change_set(cs1);
  perform erp.approve_change_set(cs2); perform erp.promote_change_set(cs2);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'promotion installs seven lifecycles across both modules',
    (select count(*) from erp.state_machine m
      where m.tenant_id = r.tenant_id and m.status='active') = 7,
    'requisition, purchase order, goods receipt, quotation, sales order, '
    'delivery, sales invoice';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CUST','Customer','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor', 1000000),'active');
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  select coalesce(sum(quantity),0) into q0 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  -- Inbound.
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 500, 1000, 'inbound');
  perform erp.transition_document(v_grn,'post');
  select coalesce(sum(quantity),0) into q1 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  return query select 'a posted receipt raises an inbound movement and on-hand rises',
    q1 - q0 = 500 and exists (select 1 from erp.stock_movement m
      where m.document_id = v_grn and m.movement_type = 'goods_receipt'
        and m.to_location_id is not null and m.from_location_id is null),
    format('%s to %s', q0, q1);

  -- Outbound, through the same function.
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 200, 2500, 'outbound');
  update erp.document_line set location_id = v_recv where document_id = v_dn;
  perform erp.transition_document(v_dn,'post');
  select coalesce(sum(quantity),0) into q2 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  return query select 'a posted delivery raises an outbound movement and on-hand falls',
    q2 - q1 = -200 and exists (select 1 from erp.stock_movement m
      where m.document_id = v_dn and m.movement_type = 'despatch'
        and m.from_location_id is not null and m.to_location_id is null),
    format('%s to %s, same erp.post_document() as the receipt', q1, q2);

  return query select 'the ledger and the cached balance agree after both',
    (select count(*) from erp.stock_reconciliation_report()) = 0,
    'a movement inserted but not reflected is not a movement';

  -- Posting twice would double the stock, and the ledger is append-only.
  begin
    perform erp.post_document(v_dn);
    v_ok := false; v_msg := 'a document posted twice';
  exception when sqlstate '23505' then v_ok := true; v_msg := left(sqlerrm,58); end;
  return query select 'a document cannot post twice', v_ok, v_msg;

  -- B7's own balance guard, reached through the bridge.
  v_dn2 := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn2, v_item, 99999, 2500, 'more than exists');
  update erp.document_line set location_id = v_recv where document_id = v_dn2;
  begin
    perform erp.transition_document(v_dn2,'post');
    v_ok := false; v_msg := 'despatched more than was on hand';
  exception when others then
    v_ok := (sqlerrm like '%NEGATIVE_STOCK%'); v_msg := left(sqlerrm,58);
  end;
  return query select 'despatching more than is on hand is refused', v_ok, v_msg;

  -- Lineage across the module boundary.
  v_quo := erp.open_document('quotation', v_cust);
  perform erp.add_document_line(v_quo, v_item, 10, 2500, 'quoted');
  v_so := erp.open_document('sales_order', v_cust, null, v_site);
  perform erp.add_document_line(v_so, v_item, 10, 2500, 'ordered');
  perform erp.link_documents(v_quo, v_so, 'fulfils');
  return query select 'lineage runs quotation to order, both ways',
    (select count(*) from erp.document_lineage(v_quo)) >= 2,
    'spec 4.5';

  -- The discount band. 20% is above the 15% threshold.
  update erp.document_line set discount_pct = 20 where document_id = v_so;
  perform erp.transition_document(v_so,'submit');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_so and tk.status='pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'a discount above the threshold opens the discount step',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_so and tk.step_code='discount'
               and tk.status = 'pending'),
    '20 per cent against a threshold of 15';

  -- The credit band, on the same chain and from the same context. It cannot be
  -- read until the discount step is decided — sequences open one at a time —
  -- and asserting it earlier is asserting something that cannot yet be true.
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_so and tk.status='pending'
              and tk.step_code = 'discount'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  -- 25,000 against a limit of 1,000,000, so credit is skipped — and the skip
  -- is what proves the context carried the customer's own limit and the
  -- comparison actually ran, rather than the step simply never opening.
  return query select 'the credit step reads the customer''s limit and is skipped under it',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_so and tk.step_code='credit'
               and tk.status = 'skipped'),
    'exposure 25000 against a credit limit of 1000000';

  -- Dead configuration, both directions. Built inside a reopened bootstrap
  -- window, because erp.document_type is promotion-guarded now and a live
  -- organisation cannot be given a broken one directly — which is the
  -- property the guard was registered for.
  perform erp_test.reopen_bootstrap_window(r.tenant_id);

  begin
    update erp.document_type set stock_movement_type = null
     where tenant_id = r.tenant_id and code = 'delivery';
    perform erp.assert_no_dead_configuration();
    v_ok := false; v_msg := 'a stock-moving type with no movement passed';
  exception when others then
    v_ok := (sqlerrm like '%DEAD_CONFIGURATION%'); v_msg := left(sqlerrm,52);
  end;
  update erp.document_type set stock_movement_type = 'despatch'
   where tenant_id = r.tenant_id and code = 'delivery';
  return query select 'a type that moves stock but names no movement fails the build',
    v_ok, v_msg;

  begin
    update erp.document_type set stock_movement_type = 'despatch'
     where tenant_id = r.tenant_id and code = 'quotation';
    perform erp.assert_no_dead_configuration();
    v_ok := false; v_msg := 'a movement bound to a type that moves nothing passed';
  exception when others then
    v_ok := (sqlerrm like '%DEAD_CONFIGURATION%'); v_msg := left(sqlerrm,52);
  end;
  update erp.document_type set stock_movement_type = null
   where tenant_id = r.tenant_id and code = 'quotation';
  return query select 'a movement bound to a type that moves no stock fails the build',
    v_ok, v_msg;

  perform erp_test.close_bootstrap_window(r.tenant_id);

  -- Journals are checked by DEFERRABLE INITIALLY DEFERRED triggers, which fire
  -- at commit — after this suite has deleted its own tenant. Firing them here
  -- checks them against data that still exists.
  set constraints all immediate;

  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$function$;
CREATE OR REPLACE FUNCTION erp_test.finance_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  csf uuid; csp uuid; css uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid;
  v_sup uuid; v_cust uuid; v_item uuid;
  v_po uuid; v_grn uuid; v_dn uuid; v_so uuid; v_inv uuid;
  v_j uuid; v_rule uuid;
  n_dr bigint; n_cr bigint; b_inv bigint; b_cogs bigint; b_grni bigint;
  b_commit bigint; b_rec bigint; b_rev bigint;
  v_ok boolean; v_msg text; v_count integer;
begin
  select * into r from erp.provision_tenant('zzfin','Finance Suite','a@zzfin.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzfin.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(1000000);
  css := erp.configure_sales(15);

  return query select 'a tenant gets two ledgers, not one',
    (select count(*) from erp.ledger l
      where l.tenant_id = r.tenant_id and l.status='active') = 2
    and (select count(*) from erp.ledger l
          where l.tenant_id = r.tenant_id and l.ledger_kind='management') = 1,
    'spec 5.7 opens with "chart of accounts and parallel ledgers"';

  return query select 'the calendar covers both ledgers for the whole year',
    (select count(*) from erp.fiscal_period p
      where p.tenant_id = r.tenant_id) = 24,
    'twelve periods each; a ledger without a calendar refuses every posting';

  -- Posting rules are configuration, so before promotion they do not exist.
  -- This is the case that would have caught a rule written directly.
  return query select 'posting rules do not exist until they are promoted',
    (select count(*) from erp.posting_rule pr where pr.tenant_id = r.tenant_id) = 0,
    'submitted as a change set the author may not approve';

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(css); perform erp.promote_change_set(css);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'promotion installs five posting rules',
    (select count(*) from erp.posting_rule pr
      where pr.tenant_id = r.tenant_id and pr.status = 'active') = 5,
    'receipt, delivery, invoice, and a commitment rule for each order type';

  return query select 'every configured document type answers for itself',
    (select count(*) from erp.dead_configuration_report()) = 0,
    'no type claims an effect nothing can honour, in either direction';

  -- Fixtures.
  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CUST','Customer','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor', 100000000),'active');
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  -- ---------------------------------------------------------------------------
  -- Inbound: a receipt debits inventory and credits GRNI.
  -- ---------------------------------------------------------------------------
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 500, 1000, 'inbound');
  perform erp.transition_document(v_grn,'post');

  select j.id into v_j from erp.journal j
   where j.tenant_id = r.tenant_id and j.document_id = v_grn;

  select sum(l.debit_minor), sum(l.credit_minor) into n_dr, n_cr
    from erp.journal_line l where l.journal_id = v_j;

  return query select 'a posted receipt raises a balanced journal',
    v_j is not null and n_dr = 500000 and n_cr = 500000,
    format('debits %s, credits %s on 500 at 1000 minor', n_dr, n_cr);

  select sum(l.debit_minor) - sum(l.credit_minor) into b_inv
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '1200';
  select sum(l.credit_minor) - sum(l.debit_minor) into b_grni
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '2100';

  return query select 'the receipt lands on inventory and goods-received-not-invoiced',
    b_inv = 500000 and b_grni = 500000,
    format('1200 debit %s, 2100 credit %s — from configuration, not from code',
           b_inv, b_grni);

  -- ---------------------------------------------------------------------------
  -- Outbound: the same function, the opposite side of the same account.
  -- ---------------------------------------------------------------------------
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 200, 2500, 'outbound');
  update erp.document_line set location_id = v_recv where document_id = v_dn;
  perform erp.transition_document(v_dn,'post');

  select j.id into v_j from erp.journal j
   where j.tenant_id = r.tenant_id and j.document_id = v_dn;
  select sum(l.debit_minor) into b_cogs
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '5000';
  select sum(l.credit_minor) into b_inv
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '1200';

  return query select 'a delivery credits the account the receipt debited',
    b_cogs = 500000 and b_inv = 500000,
    format('5000 debit %s, 1200 credit %s — same erp.post_document_finance()',
           b_cogs, b_inv);

  -- ---------------------------------------------------------------------------
  -- The parallel ledger. This is the case that decides whether affects_finance
  -- on an order type was honoured or edited away.
  -- ---------------------------------------------------------------------------
  v_so := erp.open_document('sales_order', v_cust, null, v_site);
  perform erp.add_document_line(v_so, v_item, 100, 2500, 'ordered');
  perform erp.transition_document(v_so,'submit');
  perform erp.transition_document(v_so,'approve');

  select sum(l.credit_minor) - sum(l.debit_minor) into b_commit
    from erp.journal_line l
    join erp.journal j on j.id = l.journal_id
    join erp.ledger led on led.id = j.ledger_id
    join erp.account a on a.id = l.account_id
   where j.document_id = v_so and led.code = 'COMMIT' and a.code = '8200';

  return query select 'a confirmed order posts a commitment to the parallel ledger',
    b_commit = 250000,
    format('8200 credit %s in COMMIT, nothing in GL', b_commit);

  return query select 'the commitment stays out of the statutory ledger',
    not exists (select 1 from erp.journal j
                 join erp.ledger led on led.id = j.ledger_id
                where j.document_id = v_so and led.code = 'GL'),
    'an order is a commitment, not a transaction';

  -- A sales order passes through three committed states. Only the first posts.
  perform erp.transition_document(v_so,'pick');
  perform erp.transition_document(v_so,'despatch');
  select count(*) into v_count from erp.journal j where j.document_id = v_so;

  return query select 'three committed states raise one journal, not three',
    v_count = 1,
    format('%s journal(s) after confirm, pick and despatch', v_count);

  -- ---------------------------------------------------------------------------
  -- The invoice, and the subledger that has to agree with it.
  -- ---------------------------------------------------------------------------
  v_inv := erp.open_document('sales_invoice', v_cust, null, v_site);
  perform erp.add_document_line(v_inv, v_item, 200, 2500, 'invoiced');
  perform erp.transition_document(v_inv,'issue');

  select j.id into v_j from erp.journal j
   where j.tenant_id = r.tenant_id and j.document_id = v_inv;
  select sum(l.debit_minor) into b_rec
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '1100';
  select sum(l.credit_minor) into b_rev
    from erp.journal_line l join erp.account a on a.id = l.account_id
   where l.journal_id = v_j and a.code = '4000';

  return query select 'an issued invoice raises a receivable and revenue',
    b_rec = 500000 and b_rev = 500000,
    format('1100 debit %s, 4000 credit %s', b_rec, b_rev);

  -- Control accounts carry their detail. Derived from the account, so it cannot
  -- be forgotten by configuration.
  select coalesce(sum(s.debit_minor - s.credit_minor), 0) into b_rec
    from erp.subledger_item s
    join erp.account a on a.id = s.control_account_id
   where s.tenant_id = r.tenant_id and a.code = '1100';

  return query select 'posting a control account writes its subledger detail',
    b_rec = 500000
    and (select count(*) from erp.subledger_item s
          join erp.account a on a.id = s.control_account_id
         where s.tenant_id = r.tenant_id and a.code = '1100'
           and s.party_id = v_cust) = 1,
    format('receivable subledger %s, against the customer', b_rec);

  -- Inventory is a control account as well, so the receipt and the delivery
  -- each wrote one — with no party on it, because stock is owed to nobody.
  return query select 'a control account with no counterparty carries none',
    (select count(*) from erp.subledger_item s
      join erp.account a on a.id = s.control_account_id
     where s.tenant_id = r.tenant_id and a.code = '1200') = 2
    and not exists (
      select 1 from erp.subledger_item s
       join erp.account a on a.id = s.control_account_id
      where s.tenant_id = r.tenant_id and a.code = '1200' and s.party_id is not null),
    'a customer against a stock balance is noise dressed as analysis';

  return query select 'the subledger and its control account agree',
    (select count(*) from erp.subledger_reconciliation_report()) = 0,
    'the month-end discovery nobody wants, asserted continuously';

  -- ---------------------------------------------------------------------------
  -- Negative controls.
  -- ---------------------------------------------------------------------------
  begin
    perform erp.post_document_finance(v_inv);
    v_ok := false; v_msg := 'a document was journalled twice';
  exception when sqlstate '23505' then v_ok := true; v_msg := left(sqlerrm,58); end;
  return query select 'a document cannot be journalled twice', v_ok, v_msg;

  -- A rule that does not balance is refusable without a document, so it is
  -- refused at promotion rather than at month end.
  -- Break the rule first and read the static report, THEN provoke the raise.
  -- The other way round passes for the wrong reason: a PL/pgSQL exception block
  -- is a subtransaction, so the failing assertion rolls the broken fixture back
  -- with it and the report that follows is looking at a rule that is fine.
  update erp.posting_rule
     set posting_lines = jsonb_build_array(
           jsonb_build_object('account','1200','side','debit','rate',1),
           jsonb_build_object('account','2100','side','credit','rate',0.5))
   where tenant_id = r.tenant_id and code = 'goods_receipt';

  return query select 'an unbalanced rule fails the build statically',
    (select count(*) from erp.dead_configuration_report()
      where finding = 'a posting rule does not balance') = 1,
    'answerable without a document, so it is answered at promotion';

  begin
    perform erp.assert_posting_rule_balances('goods_receipt', 1);
    v_ok := false; v_msg := 'an unbalanced rule was accepted';
  exception when others then
    v_ok := (sqlerrm like '%POSTING_RULE_UNBALANCED%'); v_msg := left(sqlerrm,58);
  end;
  return query select 'and promotion refuses it by name', v_ok, v_msg;

  update erp.posting_rule
     set posting_lines = jsonb_build_array(
           jsonb_build_object('account','1200','side','debit','rate',1),
           jsonb_build_object('account','2100','side','credit','rate',1))
   where tenant_id = r.tenant_id and code = 'goods_receipt';

  -- A type that reaches the ledger and names no rule. Built inside a reopened
  -- bootstrap window: erp.document_type is promotion-guarded now, so a live
  -- organisation cannot be given a broken one directly.
  perform erp_test.reopen_bootstrap_window(r.tenant_id);

  update erp.document_type set posting_rule_code = null
   where tenant_id = r.tenant_id and code = 'delivery';

  return query select 'a type that reaches a ledger and names no rule fails the build',
    (select count(*) from erp.dead_configuration_report()
      where finding = 'a document type reaches the ledger but names no posting rule'
        and reference = 'delivery') = 1,
    'exactly what affects_finance was before this migration';

  update erp.document_type set posting_rule_code = 'delivery'
   where tenant_id = r.tenant_id and code = 'delivery';

  perform erp_test.close_bootstrap_window(r.tenant_id);

  -- Spec 4.7: every posting traces to an operational event and the rule version
  -- that produced it. B7 enforces it; this asserts the bridge satisfies it.
  return query select 'every posted line names its event and its rule version',
    not exists (
      select 1 from erp.journal_line l
       join erp.journal j on j.id = l.journal_id
      where l.tenant_id = r.tenant_id and j.source_code <> 'manual'
        and (l.source_event_id is null or l.posting_rule_version is null)),
    'spec 4.7, and the reason the event store finally has rows in it';

  return query select 'and those events are real events in the store',
    (select count(*) from erp.event e
      where e.tenant_id = r.tenant_id and e.event_type = 'document.posted') = 4,
    'receipt, delivery, order commitment and invoice';

  -- The journal balance triggers are DEFERRABLE INITIALLY DEFERRED, so they
  -- fire at commit — which is after this suite has deleted its own tenant, and
  -- they would then look for the lines of a journal that no longer exists and
  -- report an empty journal. Firing them here checks the thing they are for,
  -- against data that is still there, and clears the queue.
  set constraints all immediate;

  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$function$;

-- -----------------------------------------------------------------------------
-- The suite
--
-- The claim is narrow and checkable: installing a module on a live
-- organisation changes nothing until somebody approves it, and when they do,
-- the whole spine arrives at once and consistently. The falsifications matter
-- as much — a direct edit is refused, a counter advance is not, and a document
-- type that names a sequence its change set does not carry is refused by name
-- rather than landing without one.
-- -----------------------------------------------------------------------------

create or replace function erp_test.document_spine_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();   -- the approver, because B6 refuses self-approval
  v_t uuid; res jsonb; v_second uuid; v_tok text; c uuid;
  v_ok boolean; v_msg text; n integer; v_ref text; v_next bigint;
begin
  insert into auth.users (id, email)
  values (a1, 'spine1@zzspine.test'), (a2, 'spine2@zzspine.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.onboard_tenant('Spine', 'zzspine');
  v_t := erp.require_tenant_id();

  res := public.erp_invite_principal('spine2@zzspine.test', 'Second');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  perform erp.configure_finance();
  -- Live from here, which is where the whole problem lived: before this
  -- migration a module installed onto a live organisation landed its sequences
  -- and document types immediately and left its lifecycles in a submitted
  -- change set.
  perform erp_test.close_bootstrap_window(v_t);

  -- ── Nothing lands before somebody approves ──────────────────────────────

  perform erp.configure_procurement();

  return query select 'installing a module on a live organisation writes no configuration',
    (select count(*) from erp.numbering_rule where tenant_id = v_t) = 0
      and (select count(*) from erp.document_type where tenant_id = v_t) = 0
      and (select count(*) from erp.state_machine where tenant_id = v_t) = 0,
    format('%s sequences, %s document types, %s lifecycles',
      (select count(*) from erp.numbering_rule where tenant_id = v_t),
      (select count(*) from erp.document_type where tenant_id = v_t),
      (select count(*) from erp.state_machine where tenant_id = v_t));

  return query select 'and the dead configuration it used to leave behind is gone',
    (select count(*) from erp.dead_configuration_report()) = 0,
    'three document types naming state machines that did not exist yet, '
    'reported by the product and refused by nothing';

  -- ── And then it all lands together ──────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = v_t and cs.status = 'ready' order by cs.created_at
  loop
    perform erp.approve_change_set(c);
    perform erp.promote_change_set(c);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'promotion brings the whole spine at once',
    (select count(*) from erp.numbering_rule where tenant_id = v_t) = 3
      and (select count(*) from erp.document_type where tenant_id = v_t) = 3
      and (select count(*) from erp.state_machine where tenant_id = v_t) = 3,
    format('%s sequences, %s document types, %s lifecycles',
      (select count(*) from erp.numbering_rule where tenant_id = v_t),
      (select count(*) from erp.document_type where tenant_id = v_t),
      (select count(*) from erp.state_machine where tenant_id = v_t));

  return query select 'every document type reached a real sequence and a real lifecycle',
    not exists (
      select 1 from erp.document_type dt
       where dt.tenant_id = v_t
         and (dt.numbering_rule_id is null
              or not exists (select 1 from erp.state_machine m
                              where m.tenant_id = v_t and m.code = dt.state_machine_code))),
    'the promoter resolves both by code, so the change set carries names and '
    'the identifiers are the target environment''s own';

  return query select 'and nothing is dead',
    (select count(*) from erp.dead_configuration_report()) = 0,
    'the product''s own report, on the organisation the suite just built';

  -- ── The guard, both ways ────────────────────────────────────────────────

  begin
    update erp.numbering_rule set prefix = 'XX-'
     where tenant_id = v_t and code = 'purchase_order';
    v_ok := false; v_msg := 'a sequence prefix was changed directly on a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'changing what a reference looks like needs a change set',
    v_ok, v_msg;

  begin
    update erp.document_type set state_machine_code = 'quotation'
     where tenant_id = v_t and code = 'purchase_order';
    v_ok := false; v_msg := 'a document type''s lifecycle was rebound directly';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and so does rebinding a document type''s lifecycle', v_ok, v_msg;

  -- The other direction, which is the one that made this hard. A sequence
  -- counting is not a sequence being configured, and the guard has to be able
  -- to tell the difference or raising a document becomes a configuration edit.
  select nr.next_value into v_next from erp.numbering_rule nr
   where nr.tenant_id = v_t and nr.code = 'purchase_order';
  v_ref := erp.next_document_number(
    (select nr.id from erp.numbering_rule nr where nr.tenant_id = v_t and nr.code = 'purchase_order'));

  return query select 'but a sequence may still count on a live organisation',
    v_ref is not null
      and (select nr.next_value from erp.numbering_rule nr
            where nr.tenant_id = v_t and nr.code = 'purchase_order') > v_next,
    format('issued %s, and next_value moved from %s', v_ref, v_next);

  return query select 'because the columns that are state are registered as state',
    (select count(*) from erp_meta.live_mutable_column
      where schema_name = 'erp' and table_name = 'numbering_rule') = 2,
    'next_value and current_period; everything else on the row is what a '
    'reference looks like, and that needs approving';

  -- ── A change set that names a sequence it does not carry ────────────────

  perform erp_test.reopen_bootstrap_window(v_t);
  c := erp.create_change_set('ZZSPINE-BAD', 'A document type with no sequence');
  perform erp.add_change_set_item(c, 'document_type', 'orphan',
    jsonb_build_object('code','orphan','base_type','requisition','name','Orphan',
                       'numbering_rule','no_such_sequence'));
  perform erp.submit_change_set(c);
  perform erp.approve_change_set(c);
  begin
    perform erp.promote_change_set(c);
    v_ok := false; v_msg := 'a document type was created with no sequence behind it';
  exception when others then
    v_ok := sqlerrm like '%ERPWARE_UNKNOWN_NUMBERING_RULE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a document type naming a sequence nobody carries is refused by name',
    v_ok, v_msg;

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_t);
  delete from erp.tenant where id = v_t;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);

  return query select 'and the suite removes the organisation it built',
    not exists (select 1 from erp.document_type dt where dt.tenant_id = v_t),
    'the spine cascades with the tenant, as every tenant-scoped table does';
end $$;

create or replace function erp_test.assert_document_spine_suite()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Two before approval, three after, four on the guard, one on a change set
  -- that names what it does not carry, and the cleanup.
  c_expected constant integer := 11;
begin
  create temporary table if not exists zz_spine_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_spine_result;
  insert into zz_spine_result select * from erp_test.document_spine_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_pass, v_total, v_detail from zz_spine_result;

  if v_total <> c_expected then
    raise exception
      'ERPWARE_SUITE_SHRANK: %/% cases ran, % expected', v_pass, v_total, c_expected
      using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_DOCUMENT_SPINE_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('document spine: %s/%s', v_pass, v_total);
end $$;

-- ── The decision this closes ─────────────────────────────────────────────────

update erp_meta.policy_decision set
  title = 'Document sequences and document types are configuration, and are '
          'promotion-guarded',
  decision =
    'Taken. erp.numbering_rule and erp.document_type are both registered in '
    'erp_meta.promotable_surface, both carry a promoter branch and a manifest '
    'block, and the four installers that wrote them directly now put them in '
    'their own change set. Installing a module on a live organisation writes '
    'nothing until somebody approves it.',
  rationale =
    'Two things in the original record were wrong. It is four installers, not '
    'six — the six came from grepping migration files, which counts inserts in '
    'function bodies that later migrations replaced; the catalogue says four. '
    'And the obstacle was never numbering. Measured on a fresh build, '
    'installing procurement on a live organisation landed three sequences and '
    'three document types immediately and ungoverned while the three state '
    'machines those types name waited in a submitted change set, and '
    'erp.dead_configuration_report() answered "a document type names a state '
    'machine that does not exist" three times over. A module installed half '
    'into one governance regime and half into another, and the half that '
    'landed first depended on the half that had not. Guarding sequences alone '
    'would have made that worse; moving the whole spine into the change set '
    'removes it.',
  evidence =
    'erp_test.document_spine_suite() installs a module on a live organisation '
    'and finds nothing written and nothing dead, then promotes and finds the '
    'spine complete and consistent. Registering the tables also exposed that '
    'erp.next_document_number() UPDATES the rule it reads, so the guard now '
    'reads erp_meta.live_mutable_column to tell a sequence counting from a '
    'sequence being configured — the same distinction '
    'erp.configuration_manifest() had already made in a comment and the guard '
    'had not. erp.assert_configuration_promotable(): 35 surfaces, all '
    'promotable, capturable and guarded.',
  status = 'accepted', decided_at = now()
 where code = 'numbering_rules_outside_promotion';

-- Generated, in this order, because a register is only worth having if
-- something reads it: erp_meta.live_mutable_column arrived above and its row
-- security comes from erp.apply_row_security() reading erp_meta.table_policy.
-- erp.assert_isolation() failed the build on exactly this, twice in one day.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_configuration_promotable();
select erp.assert_isolation();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp_test.assert_document_spine_suite();
