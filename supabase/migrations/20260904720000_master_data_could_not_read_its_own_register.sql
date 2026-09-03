-- ─────────────────────────────────────────────────────────────────────────────
-- Master data was unreachable, and no assertion could see it.
--
-- Installing the Master data module failed with "permission denied for schema
-- erp_meta". So did every other part of that module — change requests, mass
-- change, imports, record merging, data-quality scoring — for exactly the same
-- reason, and had done since 20260829230000.
--
-- The mechanism, measured rather than guessed. erp_meta is platform-internal:
-- `authenticated` has no USAGE on the schema at all, by design, and reaches
-- what is in it only through SECURITY DEFINER doors. But
-- erp_meta.maintainable_field is read by fourteen SECURITY INVOKER functions
-- behind seventeen SECURITY INVOKER public doors, so every one of them runs as
-- the caller and every one of them is refused. Probed on live under
-- `set local role authenticated`: 42501, permission denied for schema erp_meta.
-- Reproduced identically on a fresh build of main, so it is a schema defect and
-- not live drift.
--
-- Why nothing caught it: every assertion and every suite runs as a privileged
-- role, which has access. The same shape as the STABLE-door fault in
-- 20260904670000 — a rule that holds for every test and fails for every real
-- caller. Finance installs because its promoter branch never touches the table;
-- master data's `field_approval_rule` branch does.
--
-- The root cause is a misfiled table, not a missing grant. Fourteen rows across
-- two object types, saying which columns of which tables may be maintained:
-- that is product reference content, the same category as erp_ref.reason_code
-- or erp_ref.uom. The registers agree — erp_meta.table_policy classes are
-- one-to-one with schemas, `platform_internal` only ever in erp_meta and
-- `product_content` only ever in erp_ref — so this one table was both in the
-- wrong schema and in the wrong class.
--
-- So it moves to erp_ref, where apply_row_security() gives it the product_read
-- policy and the grant its sixty-three siblings already have. The fourteen
-- function bodies are recreated pointing at the new location: mechanically
-- substituted from pg_get_functiondef, twenty-two references, nothing else
-- changed. Granting authenticated a way into erp_meta instead would have kept
-- the table where it does not belong and weakened the boundary to do it.
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp_ref.maintainable_field (
  object_type text not null,
  table_name  text not null,
  column_name text not null,
  data_kind   text not null,
  rationale   text not null,
  constraint maintainable_field_pkey primary key (object_type, column_name),
  constraint maintainable_field_data_kind_check
    check (data_kind = any (array['text','integer','numeric','boolean','jsonb','uuid','enum'])),
  constraint maintainable_field_rationale_check
    check (length(trim(both from rationale)) >= 20)
);

comment on table erp_ref.maintainable_field is
  'Which columns of which objects may be maintained through a change request, '
  'a mass change or an import. Product reference content: read by the master '
  'data feature as the caller, so it must live where authenticated can read it.';

insert into erp_ref.maintainable_field (object_type, table_name, column_name, data_kind, rationale)
  values
    ('item', 'item', 'attributes', 'jsonb', 'Tenant-defined fields, which is precisely what level 2 of the extension ladder puts here.'),
    ('item', 'item', 'item_class', 'text', 'Classification drives reporting and planning policy; reclassification is a normal mass change.'),
    ('item', 'item', 'item_group', 'text', 'Grouping for analysis. Changed together with class often enough to matter.'),
    ('item', 'item', 'lifecycle', 'enum', 'Draft to active to discontinued is the item''s own state, and is changed in bulk at range review.'),
    ('item', 'item', 'min_remaining_shelf_life_days', 'integer', 'Customer acceptance rules change per contract and apply across a range.'),
    ('item', 'item', 'name', 'text', 'The description everyone reads. Routinely corrected in bulk after a catalogue import.'),
    ('item', 'item', 'shelf_life_days', 'integer', 'A regulatory attribute that changes on supplier specification updates.'),
    ('item', 'item', 'status', 'enum', 'Active to inactive is how a record is withdrawn without being deleted.'),
    ('party', 'party', 'country_code', 'text', 'Drives tax determination and legislation binding, so it is maintained rather than assumed.'),
    ('party', 'party', 'legal_name', 'text', 'The registered name, which differs from the trading name and changes on incorporation events.'),
    ('party', 'party', 'name', 'text', 'The name shown on every document. Corrected after a merge or a rebrand.'),
    ('party', 'party', 'registration_number', 'text', 'Company registration, updated when a counterparty restructures.'),
    ('party', 'party', 'status', 'enum', 'Active to inactive is how a counterparty is withdrawn without being deleted.'),
    ('party', 'party', 'tax_identifier', 'text', 'Changes on registration, and a wrong one is a rejected statutory filing.')
on conflict (object_type, column_name) do update set
  table_name = excluded.table_name,
  data_kind  = excluded.data_kind,
  rationale  = excluded.rationale;

-- The fourteen readers, pointing at the new location. Every body is its own
-- previous definition with erp_meta.maintainable_field replaced by
-- erp_ref.maintainable_field and nothing else touched.

CREATE OR REPLACE FUNCTION erp.apply_change_request(p_request_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  cr       erp.change_request%rowtype;
  v_now    jsonb;
  v_table  text;
  v_sets   text := '';
  v_key    text;
  v_kind   text;
  v_type   text;
  v_count  integer := 0;
  v_drift  text;
begin
  select * into cr from erp.change_request
   where tenant_id = v_tenant and id = p_request_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CHANGE_REQUEST: %', p_request_id using errcode = '23503';
  end if;

  if erp.change_request_effective_status(p_request_id) <> 'approved' then
    raise exception
      'ERPWARE_CHANGE_REQUEST_NOT_APPROVED: % is %, and only an approved '
      'request may be applied',
      p_request_id, erp.change_request_effective_status(p_request_id)
      using errcode = '42501';
  end if;

  v_now := erp.master_record(cr.object_type, cr.object_id);

  -- The world may have moved while this waited. Applying anyway would silently
  -- undo whoever changed it in the meantime, which is the failure mode that
  -- makes people stop trusting a review queue.
  select string_agg(k, ', ') into v_drift
    from jsonb_object_keys(cr.proposed) k
   where (v_now -> k) is distinct from (cr.before_snapshot -> k);

  if v_drift is not null then
    raise exception
      'ERPWARE_CHANGE_REQUEST_STALE: % changed since this was proposed', v_drift
      using errcode = '40001',
      hint = 'Open a new request against the record as it now stands.';
  end if;

  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = cr.object_type;

  for v_key in select k from jsonb_object_keys(cr.proposed) k order by k
  loop
    select m.data_kind into v_kind
      from erp_ref.maintainable_field m
     where m.object_type = cr.object_type and m.column_name = v_key;

    if v_kind is null then
      raise exception 'ERPWARE_FIELD_NOT_MAINTAINABLE: %', v_key using errcode = '42501';
    end if;

    -- The identifier comes from the registry row, not from the key, and the
    -- value goes in as a parameterised jsonb extraction rather than as text
    -- spliced into the statement.
    -- The cast comes from the catalogue, not from data_kind. A hand-kept
    -- mapping cannot know that erp.item.lifecycle and erp.party.status are two
    -- different enums, and text assigned to either fails at run time — which
    -- is a defect that only appears the first time somebody maintains a status.
    -- format_type, not atttypid::regtype: the second drops the type modifier,
    -- so character(2) comes back as `character` and a two-letter country code
    -- is silently truncated to one before it reaches its foreign key. Caught
    -- by a build from empty, on a row that had been passing for an hour.
    select pg_catalog.format_type(a.atttypid, a.atttypmod) into v_type
      from pg_catalog.pg_attribute a
     where a.attrelid = format('erp.%I', v_table)::regclass and a.attname = v_key;

    v_sets := v_sets || case when v_sets = '' then '' else ', ' end
              || format('%I = ($2 ->> %L)::%s', v_key, v_key, v_type);
    v_count := v_count + 1;
  end loop;

  -- An enum column takes the text form, which Postgres coerces on assignment;
  -- an invalid label raises rather than being stored, which is the behaviour
  -- wanted here.
  execute format('update erp.%I set %s, updated_at = now(), updated_by = $3
                   where tenant_id = $1 and id = $4', v_table, v_sets)
    using v_tenant, cr.proposed, erp.current_principal_id(), cr.object_id;

  update erp.change_request
     set status = 'applied', applied_at = now(),
         applied_by = erp.current_principal_id(), updated_at = now()
   where id = p_request_id;

  return v_count;
end;
$function$
;

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
        if not exists (select 1 from erp_ref.maintainable_field m
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

CREATE OR REPLACE FUNCTION erp.data_quality_report(p_object_type text)
 RETURNS TABLE(object_id uuid, code text, name text, score integer, errors integer, warnings integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_table  text;
begin
  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = p_object_type;

  if v_table is null then
    raise exception 'ERPWARE_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503';
  end if;

  return query execute format($q$
    select t.id, t.code, t.name,
           erp.data_quality_score(%L, t.id),
           (select count(*)::integer from erp.score_master_record(%L, t.id) s
             where not s.satisfied and s.severity = 'error'),
           (select count(*)::integer from erp.score_master_record(%L, t.id) s
             where not s.satisfied and s.severity = 'warning')
      from erp.%I t
     where t.tenant_id = $1 and t.status <> 'archived'
     order by 4, t.code
  $q$, p_object_type, p_object_type, p_object_type, v_table) using v_tenant;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.master_data_configuration_report()
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- A rule guarding a field nothing can write would never fire, and would read
  -- on a governance screen as a control that exists.
  select 'a field approval rule guards a field that cannot be maintained',
         format('%s.%s', f.object_type, f.field_name),
         'erp_ref.maintainable_field does not list it, so no change request '
         'or mass change can ever touch it'
    from erp.field_approval_rule f
   where f.status = 'active'
     and not exists (select 1 from erp_ref.maintainable_field m
                      where m.object_type = f.object_type
                        and m.column_name = f.field_name)
  union all
  -- A rule that names a chain nobody promoted would route an approval into
  -- nothing, and erp.submit_change_request() would mark it pending for ever.
  select 'a field approval rule names an approval chain that does not exist',
         format('%s.%s', f.object_type, f.field_name),
         format('approval_chain_code = %s', f.approval_chain_code)
    from erp.field_approval_rule f
   where f.status = 'active'
     and f.approval_chain_code is not null
     and not exists (select 1 from erp.approval_chain ac
                      where ac.tenant_id = f.tenant_id
                        and ac.code = f.approval_chain_code
                        and ac.status = 'active')
  union all
  -- A quality rule about an object type this product cannot describe as facts
  -- would score nothing.
  select 'a data quality rule scores an object type that has no fields',
         format('%s.%s', q.object_type, q.code),
         'erp_ref.maintainable_field has no rows for it, so erp.master_record() '
         'cannot produce the facts the condition reads'
    from erp.data_quality_rule q
   where q.status = 'active'
     and not exists (select 1 from erp_ref.maintainable_field m
                      where m.object_type = q.object_type)
$function$
;

CREATE OR REPLACE FUNCTION erp.master_record(p_object_type text, p_object_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_row    jsonb;
  v_table  text;
begin
  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = p_object_type;

  if v_table is null then
    raise exception 'ERPWARE_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503',
      hint = 'erp_ref.maintainable_field is the list; adding a type means '
             'adding its fields with a rationale.';
  end if;

  -- The table name comes from the registry, never from the caller, so this
  -- format() cannot be steered by an argument.
  execute format('select to_jsonb(t) from erp.%I t where t.tenant_id = $1 and t.id = $2',
                 v_table)
    into v_row using v_tenant, p_object_id;

  return v_row;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.merge_master_record(p_object_type text, p_survivor_id uuid, p_duplicate_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_table  text;
  v_merged uuid;
begin
  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = p_object_type;

  if v_table is null then
    raise exception 'ERPWARE_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503';
  end if;

  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_MERGE_NEEDS_REASON: a merge is not undone, so it is not done silently'
      using errcode = '23514';
  end if;

  if p_survivor_id = p_duplicate_id then
    raise exception 'ERPWARE_MERGE_INTO_SELF: a record cannot be its own survivor'
      using errcode = '23514';
  end if;

  perform erp.authorise('master_data.approve', null, null, null,
                        p_object_type, p_duplicate_id);

  -- A survivor that has itself been merged would make the chain two hops long,
  -- and a chain nobody bounded eventually contains a cycle.
  execute format('select t.merged_into_id from erp.%I t
                   where t.tenant_id = $1 and t.id = $2', v_table)
    into v_merged using v_tenant, p_survivor_id;

  if v_merged is not null then
    raise exception
      'ERPWARE_MERGE_CHAIN: the survivor has itself been merged into %; merge '
      'into that record instead', v_merged
      using errcode = '23514';
  end if;

  execute format('update erp.%I t set merged_into_id = $2, status = ''inactive'',
                                      updated_at = now()
                   where t.tenant_id = $1 and t.id = $3
                     and t.merged_into_id is null', v_table)
    using v_tenant, p_survivor_id, p_duplicate_id;

  if not found then
    raise exception 'ERPWARE_ALREADY_MERGED_OR_MISSING: % % cannot be merged',
      p_object_type, p_duplicate_id using errcode = '23505';
  end if;

  -- Spec 4.10 and the audit stream: a merge is a fact about the record, and a
  -- fact belongs in the event store rather than in a status column alone.
  perform erp.append_event(
    -- The aggregate is 'master_record', not the object type: an event type is
    -- declared against one aggregate, and item and party merges are the same
    -- fact about the same kind of thing.
    'master_record.merged', 'master_record', p_duplicate_id,
    jsonb_build_object(
      'object_type', p_object_type,
      'survivor_id', p_survivor_id,
      'duplicate_id', p_duplicate_id,
      'reason', p_reason));
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.migration_register_report()
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- A loader the register names does not exist with the one argument the
  -- gate passes it.
  select 'loader function does not exist', d.domain_code,
         format('erp.%s(p_batch_id uuid) is named by the register and not by pg_proc', d.loader_function)
    from erp_ref.migration_domain d
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace = 'erp'::regnamespace and p.proname = d.loader_function
        and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_batch_id uuid'
        and p.prorettype = 'integer'::regtype)
  union all
  select 'figure function does not exist', d.domain_code,
         format('erp.%s(p_as_at date) returning bigint is named by the register and not by pg_proc', d.figure_function)
    from erp_ref.migration_domain d
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace = 'erp'::regnamespace and p.proname = d.figure_function
        and pg_catalog.pg_get_function_identity_arguments(p.oid) = 'p_as_at date'
        and p.prorettype = 'bigint'::regtype)
  union all
  select 'domain names a module that does not exist', d.domain_code, d.module_code
    from erp_ref.migration_domain d
   where not exists (select 1 from erp_ref.module m where m.code = d.module_code)
  union all
  select 'domain object type collides with a maintainable object type', d.domain_code, d.object_type
    from erp_ref.migration_domain d
   where exists (select 1 from erp_ref.maintainable_field m where m.object_type = d.object_type)
  union all
  select 'domain has no base-locale name', d.domain_code, d.name_key
    from erp_ref.migration_domain d
   where not exists (select 1 from erp_ref.resource r where r.key = d.name_key and r.locale = 'en')
  union all
  select 'row shape is not a list of keys', d.domain_code, left(d.row_keys::text, 80)
    from erp_ref.migration_domain d
   where jsonb_typeof(d.row_keys) <> 'array'
      or exists (select 1 from jsonb_array_elements(d.row_keys) k
                  where k ->> 'key' is null
                     or k ->> 'type' not in ('text', 'number', 'integer', 'date')
                     or jsonb_typeof(k -> 'required') <> 'boolean')
  union all
  select 'the opening stock movement type is not registered', 'opening_balance',
         'erp.load_opening_stock() writes movement_type opening_balance'
   where not exists (select 1 from erp_ref.movement_type t where t.code = 'opening_balance')
  union all
  select 'the migration clearing purpose is not on the chart', 'clearing',
         'every loader balances to erp.chart_account_code(''clearing'')'
   where not exists (select 1 from erp_ref.chart_account_purpose p where p.purpose = 'clearing')
  union all
  select 'the import pipeline does not hand opening balances to their loader', f.name,
         format('erp.%s() does not mention %s', f.name, f.needs)
    from (values ('validate_import', 'validate_opening_balances'),
                 ('load_import', 'load_opening_balances'),
                 ('rollback_import', 'reverse_opening_balances')) f(name, needs)
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace = 'erp'::regnamespace and p.proname = f.name
        and p.prosrc like '%' || f.needs || '%')
$function$
;

CREATE OR REPLACE FUNCTION erp.open_change_request(p_object_type text, p_object_id uuid, p_proposed jsonb, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_before jsonb;
  v_bad    text;
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null,
                        p_object_type, p_object_id);

  v_before := erp.master_record(p_object_type, p_object_id);
  if v_before is null then
    raise exception 'ERPWARE_UNKNOWN_RECORD: no % with id %', p_object_type, p_object_id
      using errcode = '23503';
  end if;

  if p_proposed is null or jsonb_typeof(p_proposed) <> 'object'
     or p_proposed = '{}'::jsonb then
    raise exception 'ERPWARE_EMPTY_CHANGE_REQUEST: a request that changes nothing'
      using errcode = '23514';
  end if;

  -- The allow-list, checked at the door. Everything downstream can then assume
  -- every key names a column this product agreed may be maintained.
  select string_agg(k, ', ') into v_bad
    from jsonb_object_keys(p_proposed) k
   where not exists (
     select 1 from erp_ref.maintainable_field m
      where m.object_type = p_object_type and m.column_name = k);

  if v_bad is not null then
    raise exception 'ERPWARE_FIELD_NOT_MAINTAINABLE: % on %', v_bad, p_object_type
      using errcode = '42501',
      hint = 'erp_ref.maintainable_field enumerates what may be changed this '
             'way, each with a rationale.';
  end if;

  insert into erp.change_request (
    tenant_id, object_type, object_id, proposed, before_snapshot, reason, status)
  values (v_tenant, p_object_type, p_object_id, p_proposed, v_before, p_reason, 'draft')
  returning id into v_id;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.open_mass_change(p_object_type text, p_selector jsonb, p_changes jsonb, p_reason text DEFAULT NULL::text, p_code text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_bad    text;
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'mass_change', null);

  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception 'ERPWARE_EMPTY_MASS_CHANGE: a mass change that changes nothing'
      using errcode = '23514';
  end if;

  select string_agg(k, ', ') into v_bad
    from jsonb_object_keys(p_changes) k
   where not exists (select 1 from erp_ref.maintainable_field m
                      where m.object_type = p_object_type and m.column_name = k);

  if v_bad is not null then
    raise exception 'ERPWARE_FIELD_NOT_MAINTAINABLE: % on %', v_bad, p_object_type
      using errcode = '42501';
  end if;

  -- A selector of `true` would match every record of the type. That is a
  -- legitimate thing to want and a terrible thing to do by accident, so it has
  -- to be said in words.
  if p_selector = 'true'::jsonb and coalesce(p_reason, '') = '' then
    raise exception
      'ERPWARE_UNSELECTIVE_MASS_CHANGE: a change with no selector touches every '
      '% and needs a reason', p_object_type
      using errcode = '23514';
  end if;

  insert into erp.mass_change (tenant_id, code, object_type, selector, changes, reason)
  values (v_tenant,
          coalesce(p_code, 'MC-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')),
          p_object_type, coalesce(p_selector, 'true'::jsonb), p_changes, p_reason)
  returning id into v_id;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.preview_mass_change(p_mass_change_id uuid)
 RETURNS TABLE(object_id uuid, code text, before_value jsonb, after_value jsonb)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  mc       erp.mass_change%rowtype;
  v_table  text;
  r        record;
  v_n      integer := 0;
begin
  select * into mc from erp.mass_change
   where tenant_id = v_tenant and id = p_mass_change_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_MASS_CHANGE: %', p_mass_change_id using errcode = '23503';
  end if;

  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = mc.object_type;

  for r in execute format(
    'select t.id, t.code, to_jsonb(t) as rec from erp.%I t
      where t.tenant_id = $1 and t.status <> ''archived'' order by t.code', v_table)
    using v_tenant
  loop
    if erp.jsonlogic_bool(mc.selector, r.rec) then
      object_id := r.id;
      code := r.code;
      before_value := (select jsonb_object_agg(k, r.rec -> k)
                         from jsonb_object_keys(mc.changes) k);
      after_value := mc.changes;
      v_n := v_n + 1;
      return next;
    end if;
  end loop;

  update erp.mass_change
     set status = case when status = 'draft' then 'previewed' else status end,
         affected = v_n, updated_at = now()
   where id = p_mass_change_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.rollback_import(p_batch_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_table  text;
  r        record;
  v_n      integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- Part 20: opening balances are reversed, not deleted, and the reversal
  -- carries the reason the screen's confirmation stands for.
  if exists (select 1 from erp_ref.migration_domain d where d.object_type = b.object_type) then
    return erp.reverse_opening_balances(p_batch_id, 'Rolled back from the import screen');
  end if;

  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'loaded' then
    raise exception 'ERPWARE_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = b.object_type;

  -- Reverse order, so that anything an earlier row depended on is still there
  -- while a later row is undone.
  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id and loaded
            order by row_no desc
  loop
    if r.before_snapshot is null then
      -- This row created the record, so undoing it removes the record. If
      -- something has referenced it since, the delete is refused and the
      -- rollback stops — cascading here would take real work with it.
      begin
        execute format('delete from erp.%I t where t.tenant_id = $1 and t.id = $2', v_table)
          using v_tenant, r.target_id;
      exception when foreign_key_violation then
        raise exception
          'ERPWARE_IMPORT_ROLLBACK_BLOCKED: % has been referenced since it was '
          'imported and cannot be removed', r.raw ->> 'code'
          using errcode = '23503',
          hint = 'Withdraw the record instead; deleting it would take whatever '
                 'now depends on it.';
      end;
    else
      perform erp.write_master_fields(
        b.object_type, r.target_id,
        (select jsonb_object_agg(k, r.before_snapshot -> k)
           from jsonb_object_keys(r.raw - 'code') k));
    end if;
    v_n := v_n + 1;
  end loop;

  update erp.import_batch
     set status = 'rolled_back', rolled_back_at = now(), updated_at = now()
   where id = p_batch_id;

  return v_n;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.stage_import(p_object_type text, p_rows jsonb, p_code text DEFAULT NULL::text, p_source text DEFAULT 'manual'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_code   text := coalesce(p_code, 'IMP-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'));
begin
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', null);

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'ERPWARE_EMPTY_IMPORT: an import of no rows' using errcode = '23514';
  end if;

  if not exists (select 1 from erp_ref.maintainable_field m
                  where m.object_type = p_object_type) then
    raise exception 'ERPWARE_UNKNOWN_OBJECT_TYPE: % is not maintainable', p_object_type
      using errcode = '23503';
  end if;

  insert into erp.import_batch (tenant_id, code, object_type, source, row_count)
  values (v_tenant, v_code, p_object_type, p_source, jsonb_array_length(p_rows))
  returning id into v_id;

  insert into erp.import_row (tenant_id, import_batch_id, row_no, raw)
  select v_tenant, v_id, (e.ordinality)::integer, e.value
    from jsonb_array_elements(p_rows) with ordinality e(value, ordinality);

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.validate_import(p_batch_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_table  text;
  r        record;
  v_find   jsonb;
  v_target uuid;
  v_bad    text;
  v_errors integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- Part 20: opening balances validate against the register's row shape and
  -- this organisation's records, not against maintainable fields.
  if exists (select 1 from erp_ref.migration_domain d where d.object_type = b.object_type) then
    return erp.validate_opening_balances(p_batch_id);
  end if;

  -- The gate this pipeline never had. Staging and loading both authorise
  -- master_data.import; validating and previewing did not, which left two
  -- of the four steps open to any principal who could reach the wrapper.
  perform erp.authorise('master_data.import', null, null, null,
                        'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = b.object_type;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
            order by row_no
  loop
    v_find := '[]'::jsonb;
    v_target := null;

    -- Every row must name the record it is about.
    if coalesce(r.raw ->> 'code', '') = '' then
      v_find := v_find || jsonb_build_object(
        'severity','error','message','no code, so this row names no record');
    else
      execute format('select t.id from erp.%I t where t.tenant_id = $1 and t.code = $2',
                     v_table)
        into v_target using v_tenant, r.raw ->> 'code';
    end if;

    -- Every other key must be a field this product agreed may be written.
    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k <> 'code'
       and not exists (select 1 from erp_ref.maintainable_field m
                        where m.object_type = b.object_type and m.column_name = k);

    if v_bad is not null then
      v_find := v_find || jsonb_build_object(
        'severity','error','message', format('unknown or protected field(s): %s', v_bad));
    end if;

    update erp.import_row
       set findings = v_find,
           target_id = v_target,
           action = case
                      when jsonb_array_length(v_find) > 0 then 'reject'
                      when v_target is not null then 'update'
                      else 'insert' end,
           updated_at = now()
     where id = r.id;

    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch
     set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;

  return v_errors;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.write_master_fields(p_object_type text, p_object_id uuid, p_values jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_table  text;
  v_sets   text := '';
  v_key    text;
  v_kind   text;
  v_type   text;
begin
  select distinct m.table_name into v_table
    from erp_ref.maintainable_field m where m.object_type = p_object_type;

  for v_key in select k from jsonb_object_keys(p_values) k order by k
  loop
    select m.data_kind into v_kind
      from erp_ref.maintainable_field m
     where m.object_type = p_object_type and m.column_name = v_key;

    if v_kind is null then
      raise exception 'ERPWARE_FIELD_NOT_MAINTAINABLE: % on %', v_key, p_object_type
        using errcode = '42501';
    end if;

    -- The cast comes from the catalogue, not from data_kind. A hand-kept
    -- mapping cannot know that erp.item.lifecycle and erp.party.status are two
    -- different enums, and text assigned to either fails at run time — which
    -- is a defect that only appears the first time somebody maintains a status.
    -- format_type, not atttypid::regtype: the second drops the type modifier,
    -- so character(2) comes back as `character` and a two-letter country code
    -- is silently truncated to one before it reaches its foreign key. Caught
    -- by a build from empty, on a row that had been passing for an hour.
    select pg_catalog.format_type(a.atttypid, a.atttypmod) into v_type
      from pg_catalog.pg_attribute a
     where a.attrelid = format('erp.%I', v_table)::regclass and a.attname = v_key;

    v_sets := v_sets || case when v_sets = '' then '' else ', ' end
              || format('%I = ($2 ->> %L)::%s', v_key, v_key, v_type);
  end loop;

  if v_sets = '' then return; end if;

  execute format('update erp.%I set %s, updated_at = now(), updated_by = $3
                   where tenant_id = $1 and id = $4', v_table, v_sets)
    using v_tenant, p_values, erp.current_principal_id(), p_object_id;
end;
$function$
;


-- The old home goes, and so does its registration. Leaving the table behind
-- would leave two answers to the same question, and the register would still
-- call product content platform-internal.
drop table if exists erp_meta.maintainable_field;

delete from erp_meta.table_policy
 where schema_name = 'erp_meta' and table_name = 'maintainable_field';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note)
  values ('erp_ref', 'maintainable_field', 'product_content',
          'moved from erp_meta: read by the master data feature as the caller')
on conflict (schema_name, table_name) do update set
  table_class = excluded.table_class, note = excluded.note;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

-- ─────────────────────────────────────────────────────────────────────────────
-- The same fault, three more doors.
--
-- Writing the check below rather than only the fix found the rest of the class,
-- which is the whole argument for writing it. Three further public doors are
-- SECURITY INVOKER and reach a platform_internal table, so each one is 42501
-- for every caller that is not a superuser:
--
--   erp_platform_run_check              -> erp_meta.platform_staff, diagnostic_check
--   erp_platform_record_support_action  -> erp_meta.platform_staff, incident*
--   erp_price_book                      -> erp_meta.plan, entitlement_kind
--
-- Every other erp_platform_* door is already SECURITY DEFINER gated on
-- erp_meta.require_platform('support'). These three were simply missed.
--
-- Two of them can be made definer as they stand, because the gate is already
-- inside: erp_platform_run_check calls require_platform('support') in its own
-- body, and erp_platform_record_support_action delegates to
-- erp.record_support_action, which does.
--
-- erp_price_book cannot. erp.price_book_report has no gate at all, so making
-- the door definer exactly as it is would turn a door nobody can open into one
-- anybody can — the platform's rate cards, its costs and its margins to any
-- signed-in user of any organisation. It gets the gate its siblings
-- erp_platform_plans and erp_platform_revenue already carry, in the same
-- change that makes it definer. A door that is broken is better than a door
-- that is open.
-- ─────────────────────────────────────────────────────────────────────────────

alter function public.erp_platform_run_check(text) security definer;
alter function public.erp_platform_record_support_action(uuid, text, text, text, uuid, boolean) security definer;

create or replace function public.erp_price_book()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v erp_meta.platform_staff;
begin
  -- The gate this door never had. erp.price_book_report() is ungated, so the
  -- definer context has to be earned here before it is used.
  v := erp_meta.require_platform('support');
  return erp.price_book_report();
end;
$$;

revoke all on function public.erp_price_book() from public, anon;
grant execute on function public.erp_price_book() to authenticated, service_role;

-- erp_meta.require_platform() records the staff access, so a door that calls it
-- writes. That makes it VOLATILE, which the write allow-list then requires a
-- rationale for — and the gate named here appears in this door's own body,
-- which is what assert_public_api_safe() checks.
insert into erp_meta.public_write_allowance (function_name, gate, rationale)
  values ('erp_price_book', 'erp_meta.require_platform',
          'Platform staff read of the rate cards, costs and margins. The gate records the access, which is the write.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
  values
    ('public', 'erp_platform_run_check',
     'Platform-level action. erp_meta is platform_internal — RLS enabled with no policy and a blanket revoke — so no tenant session can reach it without a definer; gated on erp_meta.require_platform(''support'') in this function''s own body.'),
    ('public', 'erp_platform_record_support_action',
     'Platform-level write. erp_meta is platform_internal, so no tenant session can reach it without a definer; gated on erp_meta.require_platform(''support'') inside erp.record_support_action.'),
    ('public', 'erp_price_book',
     'Platform-level read of rate cards and costs. erp_meta is platform_internal, so no tenant session can reach it without a definer; gated on erp_meta.require_platform(''support'') in this function''s own body.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- The rule, so the class stays closed.
--
-- A SECURITY INVOKER public door runs as the caller. `authenticated` has no
-- USAGE on erp_meta, so the moment such a door reaches a platform_internal
-- table — itself, or through an invoker function it calls — it is 42501 for
-- everybody who is not a superuser, and green in every test, because every
-- test runs privileged.
--
-- Two levels, deliberately, for the reason 20260904680000 settled: one level
-- misses erp_platform_record_support_action, which reaches erp_meta through
-- erp.support_discipline_report rather than directly. The full transitive
-- closure is not used because matching function names in text also matches
-- them inside comments, and a rule that cries wolf gets switched off. A door
-- three invoker calls deep would still slip through; that is a known and
-- accepted limit of a textual rule, and it is written here rather than
-- discovered later.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.caller_reachable_internal_report()
returns table (door text, via text, internal_table text)
language sql
stable
set search_path = ''
as $$
  with internal as (
    select tp.table_name
      from erp_meta.table_policy tp
     where tp.schema_name = 'erp_meta' and tp.table_class = 'platform_internal'
  ),
  invoker as (
    select n.nspname as sch, p.proname as nm, p.prosrc as src,
           n.nspname || '.' || p.proname as fqn
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public')
       and not p.prosecdef
       and p.prorettype <> 'pg_catalog.trigger'::regtype
  ),
  doors as (select i.nm as door, i.src from invoker i where i.sch = 'public' and i.nm like 'erp\_%'),
  lvl1 as (
    select d.door, c.fqn as via, c.src
      from doors d join invoker c on d.src like '%' || c.fqn || '(%'
     where c.sch = 'erp'
  ),
  lvl2 as (
    select l.door, c.fqn as via, c.src
      from lvl1 l join invoker c on l.src like '%' || c.fqn || '(%'
     where c.sch = 'erp'
  ),
  reach as (
    select d.door, 'the door itself' as via, d.src from doors d
    union all select l.door, l.via, l.src from lvl1 l
    union all select l.door, l.via, l.src from lvl2 l
  )
  select distinct r.door, r.via, 'erp_meta.' || i.table_name
    from reach r cross join internal i
   where r.src like '%erp\_meta.' || i.table_name || '%'
   order by 1, 2, 3;
$$;

comment on function erp.caller_reachable_internal_report() is
  'Public doors that run as the caller and reach a platform_internal table, so '
  'they are permission denied for every caller that is not a superuser and '
  'green in every test, which runs privileged.';

revoke all on function erp.caller_reachable_internal_report() from public, anon;
grant execute on function erp.caller_reachable_internal_report() to authenticated, service_role;

create or replace function erp.assert_no_caller_reachable_internals()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare n integer; v_detail text;
begin
  select count(*), string_agg(r.door || ' via ' || r.via || ' reads ' || r.internal_table, E'\n  ')
    into n, v_detail
    from erp.caller_reachable_internal_report() r;

  if n > 0 then
    raise exception E'ERPWARE_CALLER_REACHABLE_INTERNAL: % door(s) run as the caller and read platform-internal data, so every real caller is refused:\n  %',
      n, v_detail
      using errcode = 'P0001',
            hint = 'Either the door should be SECURITY DEFINER with a gate in its own body, '
                   'or the table is product reference content and belongs in erp_ref.';
  end if;

  return format('public doors: none of %s reaches platform-internal data as the caller',
                (select count(*) from pg_catalog.pg_proc p
                   join pg_catalog.pg_namespace nn on nn.oid = p.pronamespace
                  where nn.nspname = 'public' and p.proname like 'erp\_%' and not p.prosecdef));
end;
$$;

revoke all on function erp.assert_no_caller_reachable_internals() from public, anon;
grant execute on function erp.assert_no_caller_reachable_internals() to authenticated, service_role;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
  values
  ('caller_reachable_internals', 'Doors that run as the caller stay out of erp_meta',
   'assertion', 'platform', 'erp', 'assert_no_caller_reachable_internals', '{}',
   'caller_reachable_internal_report', '{}',
   'A SECURITY INVOKER public door that reads a platform_internal table is refused for every caller that is not a superuser, and passes every test, because tests run privileged.',
   true, 77)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, seq = excluded.seq;

-- Every assertion at the end, after the last registration, because a register
-- written later in the file is a register the assertion has not seen yet.


-- ─────────────────────────────────────────────────────────────────────────────
-- The volatility rule was written to one writer, and there are two.
--
-- 20260904670000 established that a public door reaching erp.authorise() cannot
-- be STABLE: authorise() writes an access-log row, PostgREST runs a STABLE
-- function inside a READ ONLY transaction, and the call fails with 25006 for
-- every caller and only through PostgREST. Thirteen doors were repaired and an
-- assertion was written.
--
-- The assertion named erp.authorise, because that was the writer in front of
-- me. erp_meta.require_platform() is the other one: it binds a staff member's
-- auth identity the first time it sees them, which is an UPDATE. Ten STABLE
-- platform doors reach it.
--
-- The failure is intermittent in the worst way. The write happens only when
-- auth_user_id is still null, so a platform staff member's very first click on
-- any of these ten screens fails with 25006, and every click afterwards works.
-- A bug report for that reads "it failed once and now it doesn't", which is
-- the kind of thing that never gets fixed because it never gets reproduced.
--
-- This is the third time a rule here has been written to the shape of the
-- example rather than to the mechanism. The rule is not "reaching authorise";
-- it is "reaching anything that writes". Both writers are now named, and named
-- in one place, so the next one is added to a list rather than discovered.
-- ─────────────────────────────────────────────────────────────────────────────

alter function public.erp_platform_commercial_state() volatile;
alter function public.erp_platform_contract(uuid) volatile;
alter function public.erp_platform_contract_document(uuid) volatile;
alter function public.erp_platform_contracts() volatile;
alter function public.erp_platform_disclosures() volatile;
alter function public.erp_platform_incident_organisations(text) volatile;
alter function public.erp_platform_incidents() volatile;
alter function public.erp_platform_invoices(uuid) volatile;
alter function public.erp_platform_maintenance_windows() volatile;
alter function public.erp_platform_revenue() volatile;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
select v.fn, 'erp_meta.require_platform',
       'Platform staff read. The gate binds the staff identity on first sight, which is the write; the door must therefore be volatile.'
  from (values
    ('erp_platform_commercial_state'), ('erp_platform_contract'),
    ('erp_platform_contract_document'), ('erp_platform_contracts'),
    ('erp_platform_disclosures'), ('erp_platform_incident_organisations'),
    ('erp_platform_incidents'), ('erp_platform_invoices'),
    ('erp_platform_maintenance_windows'), ('erp_platform_revenue')
  ) as v(fn)
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- The report, widened from one writer to a named list of them.
create or replace function erp.authorising_door_report()
returns table (door text, volatility text, finding text)
language sql
stable
set search_path = ''
as $$
  with writer as (
    -- The functions a door can reach that write, and what the write is. Adding
    -- a third means adding a row here, not rewriting the rule.
    select * from (values
      ('erp.authorise', 'writes an access-log row'),
      ('erp_meta.require_platform', 'binds the staff identity on first sight')
    ) as w(qname, what)
  ),
  fn as (
    select n.nspname || '.' || p.proname as qname, n.nspname as sch,
           p.prosrc, p.provolatile, p.oid
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ai', 'erp_meta', 'erp_ref', 'public')
  ),
  -- The writers themselves, plus every function that calls one: two levels, for
  -- the reason 20260904680000 settled — a door often reaches the writer through
  -- one function rather than directly.
  reaches as (
    select w.qname, w.what from writer w
    union
    select f.qname, w.what
      from fn f join writer w on f.prosrc ~ (replace(w.qname, '.', '\.') || '\s*\(')
  )
  select f.qname || '(' || pg_get_function_identity_arguments(f.oid) || ')',
         case f.provolatile when 's' then 'stable' else 'immutable' end,
         'a public door reaches ' || r.qname || '(), which ' || r.what
           || ', but is declared '
           || case f.provolatile when 's' then 'stable' else 'immutable' end
           || ', so PostgREST runs it in a read-only transaction and the call fails'
    from fn f
    join reaches r on f.prosrc ~ (replace(r.qname, '.', '\.') || '\s*\(')
   where f.sch = 'public'
     and f.provolatile in ('s', 'i')
   group by 1, 2, 3
   order by 1;
$$;

revoke all on function erp.authorising_door_report() from public, anon;
grant execute on function erp.authorising_door_report() to authenticated, service_role;

-- PostgREST caches volatility in its schema cache, so ten ALTERs change nothing
-- a caller can see until it is told to look again.
notify pgrst, 'reload schema';



-- The assertion's own summary named one writer too. A check that reports
-- something narrower than what it enforces is a check somebody will trust for
-- the wrong reason.
create or replace function erp.assert_authorising_doors_are_volatile()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
  v_doors    integer;
  v_reach    integer;
begin
  select count(*), string_agg(format('  %s [%s]', r.finding, r.door), E'\n' order by r.door)
    into v_count, v_findings
    from erp.authorising_door_report() r;
  if v_count > 0 then
    raise exception E'ERPWARE_AUTHORISING_DOOR_NOT_VOLATILE: % finding(s)\n%', v_count, v_findings
      using errcode = 'P0001',
            hint = 'Declare the door volatile. Reaching erp.authorise() or '
                   'erp_meta.require_platform() means writing, and PostgREST honours a '
                   'stable declaration by opening a read-only transaction.';
  end if;

  select count(*) into v_doors
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'erp\_%';

  with writer as (
    select * from (values ('erp.authorise'), ('erp_meta.require_platform')) as w(qname)
  ),
  fn as (
    select n.nspname || '.' || p.proname as qname, n.nspname as sch, p.prosrc
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ai', 'erp_meta', 'erp_ref', 'public')
  ),
  reaches as (
    select w.qname from writer w
    union
    select f.qname from fn f join writer w on f.prosrc ~ (replace(w.qname, '.', '\.') || '\s*\(')
  )
  select count(distinct f.qname) into v_reach
    from fn f join reaches r on f.prosrc ~ (replace(r.qname, '.', '\.') || '\s*\(')
   where f.sch = 'public';

  return format('doors: %s public entry points, %s reach a writer within one call and every one of those is volatile',
                v_doors, v_reach);
end;
$$;

revoke all on function erp.assert_authorising_doors_are_volatile() from public, anon;
grant execute on function erp.assert_authorising_doors_are_volatile() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- The suite: what an assertion cannot say.
--
-- The assertions above read the catalogue. This runs as the role that was
-- actually refused, which is the only way to show the fault is gone rather
-- than merely that the shape has changed.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.caller_reachable_internal_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
as $$
declare v_ok boolean; v_state text; v_msg text; v_n integer;
begin
  return query select 'the register moved to erp_ref, where product content lives',
    to_regclass('erp_ref.maintainable_field') is not null
      and to_regclass('erp_meta.maintainable_field') is null,
    'erp_ref.maintainable_field exists and erp_meta.maintainable_field does not';

  return query select 'it is registered as product content, not platform internal',
    exists (select 1 from erp_meta.table_policy tp
             where tp.schema_name = 'erp_ref' and tp.table_name = 'maintainable_field'
               and tp.table_class = 'product_content'),
    'erp_meta.table_policy agrees with where the table now lives';

  return query select 'no function anywhere still names the old location',
    (select count(*) = 0 from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      -- erp_test is excluded because a test that names the old location is not
      -- a caller reading it. The first run of this case failed on the only
      -- function in the database still naming it: this suite.
      where n.nspname <> 'erp_test'
        and p.prosrc like '%' || 'erp_meta' || '.' || 'maintainable_field' || '%'),
    'the fourteen readers were all rewritten';

  -- The case the whole migration exists for: read it as the role the product
  -- runs as. Before this change it raised 42501.
  begin
    set local role authenticated;
    select count(*) into v_n from erp_ref.maintainable_field;
    v_ok := v_n > 0;
    v_msg := v_n || ' rows readable as authenticated';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_ok := false;
    v_msg := v_state || ' ' || v_msg;
  end;
  reset role;
  return query select 'authenticated can read it, which is the whole point', v_ok, v_msg;

  -- And the boundary it must not have cost: erp_meta stays sealed.
  return query select 'erp_meta is still sealed to authenticated',
    not has_schema_privilege('authenticated', 'erp_meta', 'usage'),
    'no usage on the schema, so the platform-internal boundary is intact';

  return query select 'no public door reaches platform-internal data as the caller',
    (select count(*) = 0 from erp.caller_reachable_internal_report()),
    'erp.caller_reachable_internal_report() is empty';

  return query select 'no public door that reaches a writer is stable',
    (select count(*) = 0 from erp.authorising_door_report()),
    'erp.authorising_door_report() is empty, now over both writers';

  return query select 'the price book door gained the gate it never had',
    (select p.prosecdef and p.prosrc like '%require_platform%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'erp_price_book'),
    'security definer, and gated in its own body rather than trusting its caller';
end;
$$;

create or replace function erp_test.assert_caller_reachable_internal_suite()
returns text
language plpgsql
as $$
declare v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not s.passed), count(*),
         string_agg(format('  %s: %s', s.case_name, s.detail), E'\n')
           filter (where not s.passed)
    into v_failed, v_total, v_detail
    from erp_test.caller_reachable_internal_suite() s;

  if v_failed > 0 then
    raise exception E'ERPWARE_CALLER_REACHABLE_INTERNAL_SUITE: % of % case(s) failed\n%',
      v_failed, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('caller-reachable internals: %s of %s cases pass', v_total, v_total);
end;
$$;

select erp_test.assert_caller_reachable_internal_suite();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_no_caller_reachable_internals();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
