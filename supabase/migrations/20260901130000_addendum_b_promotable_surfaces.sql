-- =============================================================================
-- Addendum B, Part 1b — the promoter, the guard, and the register that watches
-- both
--
-- 20260901120000 moved nine upsert mechanisms out of their public doors and
-- into erp.*, leaving the gate behind. This migration uses them.
--
-- The gap it closes, measured rather than assumed. On an organisation past
-- erp.go_live(), a direct insert into erp.rule_set is refused by
-- guard_live_configuration() and must be promoted. A direct insert into
-- erp.department, or erp.account_determination — which decides the ledger
-- account a posting hits — was accepted. Addendum B's cross-cutting section
-- promised the opposite: "every new surface is a configuration object:
-- effective-dated, versioned, change-set promotable, and editable through the
-- existing change-request and approval path". The tables were built with
-- direct doors and never wired to promotion or to the guard.
--
-- Three things follow, and the third is the one that matters most:
--
--   1. Nine branches in erp.apply_change_set_item, so a change set can carry
--      these surfaces. None of them authorises — promotion is authorised once,
--      at the change set, which is what lets a principal holding
--      administration.promote but not finance.configure promote a determination
--      rule somebody else authored.
--   2. Nine blocks in erp.configuration_manifest, so an organisation's existing
--      configuration can be *captured* into a change set and not only authored
--      into one. Without this half, promotion is one-way.
--   3. erp_meta.promotable_surface, and erp.assert_configuration_promotable()
--      over it. The hole existed because nothing was watching for it:
--      apply_live_config_guards() carried a hardcoded array of seventeen table
--      names, and a tenth surface would have repeated the omission in silence.
--      From here the register is the single statement of which tables are
--      configuration, the guard is generated from it, and the assertion fails
--      the build if a registered surface is not promotable, not capturable, or
--      not guarded.
--
-- erp_meta.table_policy cannot carry this. It classes all nine as
-- tenant_scoped — the same class as ordinary business data — and that column
-- drives RLS and trigger generation, so reclassifying them to say something
-- about promotion would perturb the generators to record a fact about
-- governance.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The register
-- -----------------------------------------------------------------------------

create table if not exists erp_meta.promotable_surface (
  schema_name text not null,
  table_name  text not null,
  object_kind text not null,
  rationale   text not null,
  primary key (schema_name, table_name)
);

comment on table erp_meta.promotable_surface is
  'Every table that holds configuration rather than business data, and the '
  'erp.change_set_item object_kind that promotes it. Read by '
  'erp.apply_live_config_guards() to generate the live-edit guard, and by '
  'erp.assert_configuration_promotable() to prove each surface is reachable '
  'from a change set in both directions. Adding a configuration table without '
  'a row here now fails the build rather than quietly escaping governance.';

select erp_meta.register_table(
  'erp_meta', 'promotable_surface', 'platform_internal',
  'Platform register of configuration surfaces. Not tenant data.');

insert into erp_meta.promotable_surface (schema_name, table_name, object_kind, rationale) values
  -- The seventeen that apply_live_config_guards() carried as a hardcoded array
  -- since 0017, now stated once where the assertion can read them.
  ('erp', 'config_object',              'config',              'B3 configuration object.'),
  ('erp', 'config_version',             'config',              'Versions of a B3 configuration object; promoted with it.'),
  ('erp', 'rule_set',                   'rule_set',            'B3 decision table.'),
  ('erp', 'rule_set_version',           'rule_set',            'Versions of a rule set; promoted with it.'),
  ('erp', 'rule',                       'rule_set',            'Rows of a rule set version; promoted with it.'),
  ('erp', 'state_machine',              'state_machine',       'B4 document lifecycle.'),
  ('erp', 'state_machine_version',      'state_machine',       'Versions of a state machine; promoted with it.'),
  ('erp', 'state',                      'state_machine',       'States of a state machine version; promoted with it.'),
  ('erp', 'transition',                 'state_machine',       'Transitions of a state machine version; promoted with it.'),
  ('erp', 'approval_chain',             'approval_chain',      'B4 approval chain.'),
  ('erp', 'approval_chain_version',     'approval_chain',      'Versions of an approval chain; promoted with it.'),
  ('erp', 'approval_step',              'approval_chain',      'Steps of an approval chain version; promoted with it.'),
  ('erp', 'resource_override',          'terminology',         'B5 terminology and branding override.'),
  ('erp', 'entity_legislation_binding', 'legislation_binding', 'B5 binding of a legislation pack to a company.'),
  ('erp', 'event_subscription',         'event_subscription',  'B2 subscription of a handler to an event.'),
  ('erp', 'role',                       'role',                'B1 role. Who may do what is configuration.'),
  ('erp', 'role_permission',            'role',                'Permissions of a role; promoted with it.'),

  -- The nine Addendum B surfaces. Each was a plain erp table with a direct
  -- public door and no promotion path at all.
  ('erp', 'department',                 'department',
   'Addendum B.1 organisational unit. Approval bands hang off it, so a '
   'department created directly on a live organisation changes who approves.'),
  ('erp', 'approval_band',              'approval_band',
   'Addendum B.2 value band. Decides who must approve what, and at what value.'),
  ('erp', 'approver_assignment',        'approver_assignment',
   'Addendum B.2 named approver. Names a person rather than a band, which is '
   'exactly the sort of change that should be reviewed before it is live.'),
  ('erp', 'posting_class',              'posting_class',
   'Addendum B.3 item and party posting class. The left-hand side of account '
   'determination.'),
  ('erp', 'account_determination',      'account_determination',
   'Addendum B.3 determination rule. Decides the ledger account a posting '
   'hits, and §5 refuses a default-to-suspense — so a wrong rule is a wrong '
   'posting, not a suspense entry somebody reconciles later.'),
  ('erp', 'classification_axis',        'classification_axis',
   'Addendum B.4 classification axis.'),
  ('erp', 'classification_value',       'classification_value',
   'Addendum B.4 classification value.'),
  ('erp', 'code_template',              'code_template',
   'Addendum B.5 code template. Changing the shape of an item code mid-life '
   'is a change every downstream system sees.'),
  ('erp', 'release_area',               'release_area',
   'Addendum B.6 release area and its replenishment policy.')
on conflict (schema_name, table_name)
  do update set object_kind = excluded.object_kind,
                rationale   = excluded.rationale;

-- -----------------------------------------------------------------------------
-- The guard, generated from the register rather than from an array
-- -----------------------------------------------------------------------------

create or replace function erp.apply_live_config_guards()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r       record;
  v_count integer := 0;
begin
  -- The array this replaced listed seventeen tables and was the only statement
  -- of which tables are configuration. Nine more existed and were not in it,
  -- and nothing could have noticed. Now the register says it once, the guard
  -- is generated, and erp.assert_configuration_promotable() reads the same row.
  for r in
    select ps.schema_name, ps.table_name
      from erp_meta.promotable_surface ps
      join pg_catalog.pg_class c on c.relname = ps.table_name
      join pg_catalog.pg_namespace n
        on n.oid = c.relnamespace and n.nspname = ps.schema_name
     where c.relkind = 'r'
     order by ps.schema_name, ps.table_name
  loop
    execute format('drop trigger if exists t_%s_live_guard on %I.%I',
                   r.table_name, r.schema_name, r.table_name);
    execute format(
      'create trigger t_%s_live_guard before insert or update or delete on %I.%I
         for each row execute function erp.guard_live_configuration()',
      r.table_name, r.schema_name, r.table_name);
    v_count := v_count + 1;
  end loop;

  -- And take the guard off anything that has left the register. The first
  -- version of this function only ever added, which meant deleting a row
  -- changed nothing that was deployed — a generator that does not converge is
  -- a list with extra steps. erp.apply_audit_coverage() removes the trigger
  -- from a table that has since become exempt for the same reason.
  for r in
    select n.nspname as schema_name, c.relname as table_name
      from pg_catalog.pg_trigger t
      join pg_catalog.pg_class c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where not t.tgisinternal
       and t.tgname = 't_' || c.relname || '_live_guard'
       and not exists (
         select 1 from erp_meta.promotable_surface ps
          where ps.schema_name = n.nspname and ps.table_name = c.relname)
  loop
    execute format('drop trigger t_%s_live_guard on %I.%I',
                   r.table_name, r.schema_name, r.table_name);
  end loop;

  return v_count;
end;
$$;

comment on function erp.apply_live_config_guards is
  'Attaches erp.guard_live_configuration() to every table in '
  'erp_meta.promotable_surface. Idempotent; called by every migration that '
  'adds a configuration surface.';


-- -----------------------------------------------------------------------------
-- The promoter: nine new branches, none of which authorises
-- -----------------------------------------------------------------------------

create or replace function erp.apply_change_set_item(p_item_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
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
    else
      raise exception 'ERPWARE_PROMOTION_UNKNOWN_KIND: % cannot be promoted', i.object_kind
        using errcode = '23514',
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy, pricing_policy, inspection_plan, carrier, close_task, dunning_policy, department, approval_band, approver_assignment, posting_class, account_determination, classification_axis, classification_value, code_template, release_area';
  end case;
end;
$$;


-- -----------------------------------------------------------------------------
-- The manifest: capture, so promotion is not one-way
-- -----------------------------------------------------------------------------

create or replace function erp.configuration_manifest(p_kinds text[] default null)
returns table(object_kind text, object_key text, content jsonb, content_hash text)
language sql
stable
set search_path = ''
as $$
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
  )
  select en.object_kind, en.object_key, en.content, md5(en.content::text)
    from entries en
   where p_kinds is null or en.object_kind = any (p_kinds)
   order by 1, 2
$$;


-- -----------------------------------------------------------------------------
-- A defect found by moving the code, not by reading it
--
-- erp.upsert_code_template supersedes a template that assigned codes already
-- point at, and set the old row to status 'retired'. erp.record_status has four
-- values — draft, active, inactive, archived — and 'retired' is not one of
-- them, so that path raised "invalid input value for enum" every time it was
-- taken. It survived because it is only reached once a template has actually
-- issued a code, which no test did.
--
-- 'archived' is the value meant: the superseded version is kept because
-- assigned codes still reference it, not because it is still in use.
-- -----------------------------------------------------------------------------

create or replace function erp.upsert_code_template(
  p_code text, p_name text, p_segments jsonb,
  p_item_classes text default null, p_casing text default 'upper',
  p_entity_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_classes text[];
  v_latest  erp.code_template%rowtype;
  v_used    boolean := false;
  v_id      uuid;
  v_version integer := 1;
begin
  if jsonb_typeof(coalesce(p_segments, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_segments) = 0 then
    raise exception 'ERPWARE_TEMPLATE_EMPTY: a template needs at least one segment'
      using errcode = '23514';
  end if;

  v_classes := case
    when p_item_classes is null or btrim(p_item_classes) = '' then null
    else (select array_agg(btrim(s)) from unnest(string_to_array(p_item_classes, ',')) s
           where btrim(s) <> '')
  end;

  select * into v_latest from erp.code_template t
   where t.tenant_id = v_tenant and t.code = upper(p_code)
   order by t.version desc limit 1;

  if v_latest.id is not null then
    select exists (select 1 from erp.item_code_assignment a
                    where a.tenant_id = v_tenant and a.template_id = v_latest.id)
      into v_used;
  end if;

  if v_latest.id is null then
    insert into erp.code_template (
      tenant_id, code, name, segments, item_classes, casing, entity_id, version)
    values (v_tenant, upper(p_code), p_name, p_segments, v_classes,
            coalesce(p_casing, 'upper'), p_entity_id, 1)
    returning id into v_id;
  elsif v_used then
    update erp.code_template set valid_to = current_date, status = 'archived',
                                 updated_at = now()
     where id = v_latest.id;
    v_version := v_latest.version + 1;
    insert into erp.code_template (
      tenant_id, code, name, segments, item_classes, casing, entity_id, version,
      next_value)
    values (v_tenant, upper(p_code), p_name, p_segments, v_classes,
            coalesce(p_casing, 'upper'), p_entity_id, v_version, v_latest.next_value)
    returning id into v_id;
  else
    update erp.code_template
       set name = p_name, segments = p_segments, item_classes = v_classes,
           casing = coalesce(p_casing, casing), entity_id = p_entity_id,
           updated_at = now()
     where id = v_latest.id
    returning id, version into v_id, v_version;
  end if;

  return jsonb_build_object('template_id', v_id, 'code', upper(p_code),
                            'version', v_version);
end;
$$;

-- -----------------------------------------------------------------------------
-- The assertion. This is the part that stops surface ten repeating the omission
-- -----------------------------------------------------------------------------

create or replace function erp.assert_configuration_promotable()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_promoter  text;
  v_manifest  text;
  v_findings  text := '';
  v_count     integer := 0;
  r           record;
begin
  select p.prosrc into v_promoter
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and p.proname = 'apply_change_set_item';

  select p.prosrc into v_manifest
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and p.proname = 'configuration_manifest';

  for r in
    select ps.schema_name, ps.table_name, ps.object_kind
      from erp_meta.promotable_surface ps
     order by ps.schema_name, ps.table_name
  loop
    -- 1. The table exists. A register naming a table that was renamed away is
    --    worse than no register.
    if not exists (
      select 1 from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
       where n.nspname = r.schema_name and c.relname = r.table_name
         and c.relkind = 'r')
    then
      v_count := v_count + 1;
      v_findings := v_findings || format(
        E'  %s.%s is registered as a configuration surface but no such table exists\n',
        r.schema_name, r.table_name);
      continue;
    end if;

    -- 2. Promotion can write it. The 22 kinds that came before are branches of
    --    a case statement, so the branch itself is the evidence.
    if position('when ''' || r.object_kind || '''' in v_promoter) = 0 then
      v_count := v_count + 1;
      v_findings := v_findings || format(
        E'  %s.%s: erp.apply_change_set_item has no branch for kind %L — a change set cannot promote it\n',
        r.schema_name, r.table_name, r.object_kind);
    end if;

    -- 3. Capture can read it back. Promotion without capture is one-way: the
    --    configuration can be authored into a change set but never lifted out
    --    of a working organisation into one.
    if position('select ''' || r.object_kind || '''' in v_manifest) = 0 then
      v_count := v_count + 1;
      v_findings := v_findings || format(
        E'  %s.%s: erp.configuration_manifest does not emit kind %L — it can be promoted but never captured\n',
        r.schema_name, r.table_name, r.object_kind);
    end if;

    -- 4. The live-edit guard is attached. Without it promotion is merely the
    --    polite route rather than the only one.
    if not exists (
      select 1 from pg_catalog.pg_trigger t
        join pg_catalog.pg_class c on c.oid = t.tgrelid
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
       where n.nspname = r.schema_name and c.relname = r.table_name
         and not t.tgisinternal
         and t.tgname = 't_' || r.table_name || '_live_guard')
    then
      v_count := v_count + 1;
      v_findings := v_findings || format(
        E'  %s.%s: no t_%s_live_guard trigger — it can still be edited directly on a live organisation\n',
        r.schema_name, r.table_name, r.table_name);
    end if;
  end loop;

  -- 5. And the other direction: a guard attached to a table nobody registered.
  --    The register cannot prove its own completeness — nothing can tell it
  --    that a tenth configuration surface exists and was never written down —
  --    but it can at least refuse to drift away from what is deployed.
  for r in
    select n.nspname as schema_name, c.relname as table_name
      from pg_catalog.pg_trigger t
      join pg_catalog.pg_class c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where not t.tgisinternal
       and t.tgname = 't_' || c.relname || '_live_guard'
       and not exists (
         select 1 from erp_meta.promotable_surface ps
          where ps.schema_name = n.nspname and ps.table_name = c.relname)
     order by 1, 2
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  %s.%s carries the live-edit guard but is not in erp_meta.promotable_surface — the register no longer describes what is deployed\n',
      r.schema_name, r.table_name);
  end loop;

  if v_count > 0 then
    raise exception
      E'ERPWARE_CONFIGURATION_NOT_PROMOTABLE: % finding(s)\n%', v_count, v_findings
      using errcode = '23514';
  end if;

  return format('configuration surfaces: %s registered, all promotable, capturable and guarded',
                (select count(*) from erp_meta.promotable_surface));
end;
$$;

comment on function erp.assert_configuration_promotable is
  'Every table in erp_meta.promotable_surface is (a) real, (b) handled by '
  'erp.apply_change_set_item, (c) emitted by erp.configuration_manifest, and '
  '(d) carrying the live-edit guard. Addendum B''s nine surfaces failed all '
  'four for as long as they existed, because nothing asked.';

-- -----------------------------------------------------------------------------
-- Apply, and prove it at the migration's own tail
-- -----------------------------------------------------------------------------

select erp.apply_live_config_guards();
select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_configuration_promotable();
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
