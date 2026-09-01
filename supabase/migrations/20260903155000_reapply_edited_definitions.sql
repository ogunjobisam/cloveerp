-- =============================================================================
-- Two functions, re-applied — because editing a migration that has already run
-- changes nothing where it has already run
--
-- The Supabase preview branch failed on every commit from b10b9c5 onward:
--
--   ERPWARE_PACK_NOT_INSTALLABLE: 1 finding(s)
--     base carries kind 'job', which erp.apply_change_set_item cannot promote
--
-- The build was green. Both are correct, and the gap between them is the point.
--
-- CI stands the schema up from NOTHING on every push, so a migration edited
-- after it was pushed is simply part of the file that gets replayed — the
-- edited version is the only version an empty database ever sees. A preview
-- branch, a staging database and the live project are not empty: they have
-- already applied that file, and Supabase says so plainly in its own comment
-- on the pull request — "only new migration files are pushed".
--
-- So an edit to an applied migration is invisible to the one check designed to
-- catch everything, and lands nowhere it matters. THREE were made here, and I
-- had counted two until the check below was written and found the third:
--
--   20260903120000  gained the 'job' change-set kind and a company fallback on
--                   the 'account' kind, after it had been applied
--   20260903130000  gained 201 screen-string rows and a corrected
--                   erp.terminology_alignment_report(), after it had been applied
--   20260903140000  had erp.pack_conflicts() rewritten when the base pack
--                   showed its duplicate-code check was four-for-four false
--                   positives, after it had been applied
--
-- The first is what broke the preview: 20260903160000 is a NEW file, so its
-- five §9.1 job items arrived on a branch whose erp.apply_change_set_item()
-- still had no branch for them. The second would have shown up later and
-- quietly: two thirds of the screen unrenameable on every environment except a
-- freshly built one.
--
-- This file is those definitions as a fresh build produces them, generated
-- from a database built from every migration in order rather than typed — so
-- an environment that has already applied the originals converges on exactly
-- what an empty one gets, and an empty one re-creates two functions it just
-- created.
--
-- The timestamp is 155000 rather than the end of the sequence, and that is the
-- whole of why this works. A repair placed last runs last: reproducing the
-- preview branch exactly — main, then each of this branch's migrations at the
-- version it was FIRST pushed — showed 160000, 170000 and 180000 all failing
-- before a repair at 200000 was reached. It has to sit between the last file
-- the preview applied and the first one that needs it.
--
-- .github/workflows/schema.yml gains the check that would have caught the edits
-- in the first place: a migration file touched by more than one commit on a
-- branch has been edited after it was pushed, and nothing that replays into an
-- empty database can ever notice. supabase/ci/migrations_edited.txt is the
-- register of the three, each naming this file as its repair — and the check
-- refuses an entry whose repair does not exist, so an exemption cannot be a way
-- of switching the check off.
-- =============================================================================

-- The promoter, with the 'job' kind and the account company fallback.

create or replace function erp.apply_change_set_item(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $$
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
$$;

-- Conflict detection, with the duplicate-code check that does not fire on
-- reason codes sharing a code across two categories.

create or replace function erp.pack_conflicts(p_pack_code text)
 RETURNS TABLE(severity text, conflict text, reference text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if not exists (select 1 from erp_ref.content_pack where code = p_pack_code) then
    raise exception 'ERPWARE_UNKNOWN_PACK: %', p_pack_code using errcode = '23503';
  end if;

  return query
  -- §11.3, first named conflict: "account ranges colliding with a legislation
  -- pack". §8.1 says that where a bound legislation pack defines a statutory
  -- structure, it wins — so a pack account whose code already exists with a
  -- different name is the collision, and the existing row is the winner.
  select 'blocking',
         format('account %s already exists as %L and the pack would call it %L',
                pi.payload ->> 'code', a.name, pi.payload ->> 'name'),
         p_pack_code || ' / ' || pi.object_key
    from erp_ref.pack_item pi
    join erp.account a
      on a.tenant_id = v_tenant and a.code = (pi.payload ->> 'code')
     and a.status = 'active'
   where pi.pack_code = p_pack_code and pi.object_kind = 'account'
     and a.name is distinct from (pi.payload ->> 'name')

  union all

  -- Second: duplicate codes. Two items in one pack claiming the same object
  -- differ only in which lands last, which is not a decision anybody made.
  --
  -- Stated as identical payloads under different keys, not as a shared code.
  -- The first version grouped by object_kind and payload->>'code', and the
  -- base pack refused to apply because of it: reason codes are unique per
  -- CATEGORY, so ORDERED_IN_ERROR exists under both return-to-supplier and
  -- customer return, and WRONG_QUANTITY, CUSTOMER_REQUEST and
  -- SYSTEM_CORRECTION likewise. Four false positives out of four findings. The
  -- object_key already carries the full identity — category|code here,
  -- kind|code for a posting class — and the primary key makes it unique, so
  -- the only duplicate left to find is the same row written twice under two
  -- names.
  select 'blocking',
         format('%s items in this pack write an identical %s payload under '
                'different keys, so all but one are dead',
                count(*), pi.object_kind),
         p_pack_code || ' / ' || string_agg(pi.object_key, ', ' order by pi.object_key)
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
   group by pi.object_kind, pi.payload
  having count(*) > 1

  union all

  -- And the authoring error that would silently break §11.7: an object_key
  -- that does not agree with the code in its own payload. The key is what
  -- erp.plan_content_pack() matches against the manifest, so a key naming one
  -- thing and a payload writing another makes the item permanently missing —
  -- it lands, and the next application plans it again for ever.
  select 'blocking',
         format('%s %s writes code %L, which its own key does not name',
                pi.object_kind, pi.object_key, pi.payload ->> 'code'),
         p_pack_code
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
     and pi.payload ? 'code'
     and position(upper(pi.payload ->> 'code') in upper(pi.object_key)) = 0

  union all

  -- Third: unmet capability dependencies. An item gated on a capability that
  -- is off is skipped rather than blocked — that is §2 working as intended —
  -- but a PACK gated on a capability that is off has nothing to say at all.
  select 'blocking',
         format('this pack needs the %s capability, which is off for this organisation',
                cp.requires_capability),
         p_pack_code
    from erp_ref.content_pack cp
   where cp.code = p_pack_code
     and cp.requires_capability is not null
     and not erp.capability_enabled(cp.requires_capability)

  union all

  -- And advisory: items this organisation will not receive because their own
  -- capability is off. Not a conflict — a consequence — but somebody reading
  -- a diff of forty items when the pack has ninety deserves to know why.
  select 'advisory',
         format('%s item(s) are held back because the %s capability is off',
                count(*), pi.requires_capability),
         p_pack_code
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
     and pi.requires_capability is not null
     and not erp.capability_enabled(pi.requires_capability)
   group by pi.requires_capability;
end;
$$;

select erp.assert_configuration_promotable();
select erp.assert_packs_installable();
select erp.assert_public_api_safe();
select erp.assert_isolation();

-- The drift report, stripping the product term before looking for the model
-- term so that a corrected string can actually clear its own finding.

create or replace function erp.terminology_alignment_report(p_locale text DEFAULT 'en'::text)
 RETURNS TABLE(key text, finding text, reference text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $$
  select res.key,
         format('says %L where the product term is %L', v.model_term, v.product_term),
         left(res.value, 90)
    from erp_ref.vocabulary v
    join erp_ref.resource res
      on res.locale = coalesce(p_locale, 'en')
   where v.surface = 'product' and v.model_term is not null
     and res.key not like 'glossary.%'
     and regexp_replace(res.value, '\m' || v.product_term || '\M', '', 'gi')
           ~* ('\m' || v.model_term || '\M')
     -- "Account determination" is §4's own prescribed replacement for
     -- "determination matrix", so the word account in it is the right word.
     and not (v.code = 'nominal_account' and res.value ~* '\maccount determination\M')
   order by res.key, v.code
$$;

-- ── And the product wording, whole ───────────────────────────────────────────
--
-- The 201 screen-string rows were added to a migration that had already run, so
-- they exist only where the schema was built from nothing. Rather than pick out
-- which rows those were and get it subtly wrong, this is erp_ref.resource as a
-- fresh build produces it — every key, every locale, upserted.
--
-- Safe to state whole: erp_ref.resource is PRODUCT content. What an
-- organisation renames lives in erp.resource_override, which this does not
-- touch, so converging the product wording cannot overwrite anybody's own.

insert into erp_ref.resource (key, locale, value, description) values
('action.sign_out', 'en', 'Sign out', 'Account menu'),
  ('adapter.example_http', 'en', 'Illustrative HTTP adapter', ''),
  ('adapter.example_http.order_create', 'en', 'Create order', ''),
  ('adapter.example_http.order_read', 'en', 'Read order', ''),
  ('adapter.example_http.payment_instruct', 'en', 'Instruct payment', ''),
  ('audit.apply', 'en', 'Apply filters', 'Filter button'),
  ('audit.blurb', 'en', 'Every recorded action in this organisation: who did what, to which object, and when.', 'Terminology §2: tenant is model vocabulary.'),
  ('audit.col_action', 'en', 'Action', 'Column header'),
  ('audit.col_actor', 'en', 'Actor', 'Column header'),
  ('audit.col_fields', 'en', 'Changed fields', 'Column header'),
  ('audit.col_object', 'en', 'Object', 'Column header'),
  ('audit.col_reason', 'en', 'Reason', 'Column header'),
  ('audit.col_when', 'en', 'When', 'Column header'),
  ('audit.empty', 'en', 'No audit entries match these filters.', 'Empty state'),
  ('audit.filter_action', 'en', 'Action', 'Filter label'),
  ('audit.filter_actor', 'en', 'Actor', 'Filter label'),
  ('audit.filter_from', 'en', 'From', 'Filter label'),
  ('audit.filter_object', 'en', 'Object type', 'Filter label'),
  ('audit.filter_to', 'en', 'To', 'Filter label'),
  ('audit.title', 'en', 'Audit log', 'Audit screen title'),
  ('config.approval.reapproval_tolerance', 'en', 'Re-approval tolerance', 'Starter Content Packs §7.'),
  ('config.production.issue_method', 'en', 'Component issue method', ''),
  ('config.quality.quarantine_defaults', 'en', 'Quarantine defaults', 'Starter Content Packs §7.'),
  ('config.sales.backorder_policy', 'en', 'Backorder policy', 'Starter Content Packs §7.'),
  ('config.sales.credit_control', 'en', 'Credit control', 'Starter Content Packs §7.'),
  ('config.stock.allocation_policy', 'en', 'Allocation policy', 'Starter Content Packs §7.'),
  ('config.stock.reservation_ageing', 'en', 'Reservation and staging ageing', 'Starter Content Packs §7.'),
  ('config.stock.shelf_life_minimum', 'en', 'Shelf-life minimums', 'Starter Content Packs §7.'),
  ('document.adjustment', 'en', 'Stock adjustment', ''),
  ('document.count', 'en', 'Stock count', ''),
  ('document.credit_reference', 'en', 'Credit note', ''),
  ('document.delivery', 'en', 'Delivery note', ''),
  ('document.invoice_reference', 'en', 'Invoice', ''),
  ('document.purchase_order', 'en', 'Purchase order', ''),
  ('document.quotation', 'en', 'Quotation', ''),
  ('document.receipt', 'en', 'Goods receipt', ''),
  ('document.requisition', 'en', 'Requisition', ''),
  ('document.return_to_supplier', 'en', 'Return to supplier', ''),
  ('document.sales_order', 'en', 'Sales order', ''),
  ('document.transfer_order', 'en', 'Transfer order', ''),
  ('document.works_order', 'en', 'Works order', ''),
  ('dp.tax.determination', 'en', 'Tax determination', ''),
  ('event.approval.chain_resolved', 'en', 'Approval chain resolved', ''),
  ('event.approval.cover_applied', 'en', 'Cover applied to an approval', ''),
  ('event.approval.cover_ended', 'en', 'Cover ended', ''),
  ('event.approval.cover_started', 'en', 'Cover started', ''),
  ('event.approval.escalated', 'en', 'Approval escalated', ''),
  ('event.approval.reapproval_triggered', 'en', 'Re-approval triggered', ''),
  ('event.document.posted', 'en', 'Document posted to the ledger', ''),
  ('event.item.classified', 'en', 'Product classified', ''),
  ('event.item.code_assigned', 'en', 'Product code assigned', ''),
  ('event.item.code_diverged', 'en', 'Product code diverged from its template', ''),
  ('event.master_record.merged', 'en', 'Master record merged', ''),
  ('event.posting.account_recorded', 'en', 'Nominal account recorded', ''),
  ('event.posting.class_changed', 'en', 'Accounting code changed', ''),
  ('event.posting.determination_failed', 'en', 'Account determination failed', ''),
  ('event.posting.rule_resolved', 'en', 'Accounting rule resolved', 'Terminology §4: posting rule is internal vocabulary. This was the only string in the product that broke that rule.'),
  ('event.release.allocation_completed', 'en', 'Release wave allocated', ''),
  ('event.release.printed', 'en', 'Release wave printed', ''),
  ('event.release.wave_opened', 'en', 'Release wave opened', ''),
  ('event.replenishment.stock_returned', 'en', 'Stock returned to its home location', ''),
  ('event.replenishment.task_raised', 'en', 'Replenishment task raised', ''),
  ('event.sourcing.default_recorded', 'en', 'Default supplier recorded', ''),
  ('event.tenant.key_created', 'en', 'Organisation key created', ''),
  ('event.tenant.key_destroyed', 'en', 'Organisation key destroyed', ''),
  ('event.tenant.key_rotated', 'en', 'Organisation key rotated', ''),
  ('glossary.accounting_code', 'en', 'Accounting code', 'What a UK X3 or Sage user already calls exactly this concept: the classification on a product that decides which accounts it posts to. One of the two the document would prioritise.'),
  ('glossary.accounting_period', 'en', 'Accounting period', 'Fiscal is US usage. Financial calendar and financial year follow.'),
  ('glossary.allocation', 'en', 'Allocation', 'Reserving stock against demand. Not the accounting sense of apportioning cost, which this product calls cost apportionment to avoid the collision.'),
  ('glossary.analysis_code', 'en', 'Analysis code', 'Standard UK terminology for cost centre, department and project analysis. Analytical dimension is the formal alias.'),
  ('glossary.batch', 'en', 'Batch', 'UK and EU regulated practice says batch; lot is US. Lot stays a recognised alias.'),
  ('glossary.batch_release', 'en', 'Batch release', 'Releasing a batch from quarantine under named authority. The second sense of release.'),
  ('glossary.business_partner', 'en', 'Business partner', 'The established term in mid-market ERP. Supplier and customer are used wherever only one role is meant.'),
  ('glossary.class', 'en', 'Class', 'Never used alone. Accounting code class, product class, count class and hazard class are four different things and the qualifier is always kept.'),
  ('glossary.company', 'en', 'Company', 'Entity is consolidation language and it collides with the generic word for a data object, which is exactly where the ambiguity bites. UK finance says company; the group above it is the group.'),
  ('glossary.confirm_delivery', 'en', 'Confirm delivery', 'The operational sense of validating a delivery document. Validation is reserved for the regulatory sense — computerised system validation — so the two cannot be confused in an audit.'),
  ('glossary.cycle_count', 'en', 'Cycle count', 'Kept for the perpetual programme. Stocktake is added for the wall-to-wall annual, because UK operations distinguish the two clearly and the specification used one word for both.'),
  ('glossary.despatch', 'en', 'Despatch', 'Both spellings are current in UK usage; despatch is the conventional logistics spelling and consistency matters more than the choice.'),
  ('glossary.detailed_allocation', 'en', 'Detailed allocation', 'As above.'),
  ('glossary.global_allocation', 'en', 'Global allocation', 'From the incumbent system''s own vocabulary, which means every person configuring this already knows exactly what it means. Keeping it is a deliberate advantage, not an oversight.'),
  ('glossary.goods_in', 'en', 'Goods-in', 'The everyday UK warehouse term.'),
  ('glossary.goods_out', 'en', 'Goods-out', 'The everyday UK warehouse term.'),
  ('glossary.grni', 'en', 'GRNI', 'Established UK term. The US GR/IR is not.'),
  ('glossary.handling_unit', 'en', 'Handling unit', 'The industry-standard term for the recursive pallet-carton-tote concept, and unambiguous where "container" suggests shipping containers.'),
  ('glossary.location', 'en', 'Location', 'A storage position within a site: zone, aisle, rack, bin. Not a geographic place — where that is meant, the word is address or site.'),
  ('glossary.marshalling_area', 'en', 'Marshalling area', 'The document''s author coined "release area" and it is standard nowhere. Marshalling is the established UK warehouse term for goods gathered ahead of despatch.'),
  ('glossary.nominal_account', 'en', 'Nominal account', 'UK practice, particularly in the Sage lineage. The chart of accounts is also the nominal ledger. General ledger remains understood, so it is kept as an alias rather than removed.'),
  ('glossary.order_release', 'en', 'Order release', 'Releasing an order to the warehouse. One of three unrelated senses of release, and always qualified for that reason.'),
  ('glossary.organisation', 'en', 'Organisation', 'tenant stays in the schema and the isolation model, where it is precise.'),
  ('glossary.product', 'en', 'Product', 'UK ERP overwhelmingly says product; item survives mainly in Dynamics lineage. Stock item for the stockable subset.'),
  ('glossary.promotion', 'en', 'Promotion', 'Releasing a change to live. The third sense of release, and the reason the other two are always qualified.'),
  ('glossary.purchase_ledger', 'en', 'Purchase ledger', 'UK base term, with AP retained as an alias.'),
  ('glossary.qualified_person', 'en', 'Qualified Person', 'A UK regulatory title, not to be softened.'),
  ('glossary.requisition', 'en', 'Requisition', 'Terminology §3'),
  ('glossary.responsible_person', 'en', 'Responsible Person', 'As above.'),
  ('glossary.sales_ledger', 'en', 'Sales ledger', 'UK base term, with AR retained as an alias for groups that use it.'),
  ('glossary.site', 'en', 'Site', 'A physical or logical operating location under a company. Some systems mean warehouse by this and some mean legal establishment; here it is neither on its own.'),
  ('glossary.stock', 'en', 'Stock', 'Stock in operational language. Inventory is acceptable as a module name where it means the whole domain, but the ledger is a stock ledger and the count is a stock count.'),
  ('glossary.stocktake', 'en', 'Stocktake', 'The wall-to-wall annual, as distinct from the cycle count programme.'),
  ('glossary.supplier', 'en', 'Supplier', 'Not vendor.'),
  ('glossary.user', 'en', 'User', 'Service account for the non-human case. Principal is identity-model language and no operator will recognise it.'),
  ('glossary.validation', 'en', 'Validation', 'Computerised system validation, the regulatory sense. The operational act on a delivery document is confirm delivery.'),
  ('glossary.works_order', 'en', 'Works order', 'UK manufacturing standard.'),
  ('job_handler.expiry_horizon.name', 'en', 'Expiry horizon sweep', 'Starter Content Packs §9.1.'),
  ('job_handler.grni_ageing.name', 'en', 'Goods-received-not-invoiced ageing', 'Starter Content Packs §9.1.'),
  ('job_handler.integration_backlog.name', 'en', 'Integration backlog check', 'Starter Content Packs §9.1.'),
  ('job_handler.reclaim_expired_commands.name', 'en', 'Reclaim expired commands', ''),
  ('job_handler.reclaim_timed_out_runs.name', 'en', 'Reclaim timed-out runs', ''),
  ('job_handler.report_silent_jobs.name', 'en', 'Report silent jobs', ''),
  ('job_handler.stock_to_ledger.name', 'en', 'Stock-to-ledger reconciliation', 'Starter Content Packs §9.1.'),
  ('legislation.example_vat', 'en', 'Illustrative VAT (jurisdiction XX)', ''),
  ('module.administration', 'en', 'Administration', ''),
  ('module.finance', 'en', 'Finance', ''),
  ('module.governance', 'en', 'Change requests and approvals', 'Module title'),
  ('module.imports', 'en', 'Imports', 'Module title'),
  ('module.inventory', 'en', 'Inventory and warehouse', ''),
  ('module.logistics', 'en', 'Logistics', ''),
  ('module.master_data', 'en', 'Master data', ''),
  ('module.packs', 'en', 'Features and content', 'Starter Content Packs §2 and §10.'),
  ('module.planning', 'en', 'Supply chain planning', ''),
  ('module.procurement', 'en', 'Procurement', ''),
  ('module.production', 'en', 'Production', ''),
  ('module.quality', 'en', 'Quality and compliance', ''),
  ('module.reporting', 'en', 'Reporting and analytics', ''),
  ('module.sales', 'en', 'Sales and order management', ''),
  ('module.tenant_lifecycle', 'en', 'Organisation lifecycle', 'Module title'),
  ('module.terminology', 'en', 'Terminology', 'Module title'),
  ('movement.container_move', 'en', 'Handling unit move', ''),
  ('movement.count_adjustment', 'en', 'Count adjustment', ''),
  ('movement.despatch', 'en', 'Despatch', ''),
  ('movement.emergency_issue', 'en', 'Emergency issue', ''),
  ('movement.goods_receipt', 'en', 'Goods receipt', ''),
  ('movement.internal_transfer', 'en', 'Internal transfer', ''),
  ('movement.pick', 'en', 'Pick', ''),
  ('movement.production_issue', 'en', 'Production issue', ''),
  ('movement.production_output', 'en', 'Production output', ''),
  ('movement.putaway', 'en', 'Putaway', ''),
  ('movement.receipt_no_order', 'en', 'Receipt without order', ''),
  ('movement.replenishment', 'en', 'Replenishment', ''),
  ('movement.return_from_customer', 'en', 'Customer return', ''),
  ('movement.return_to_supplier', 'en', 'Return to supplier', ''),
  ('movement.scrap', 'en', 'Scrap', ''),
  ('movement.status_change', 'en', 'Stock status change', ''),
  ('nav.administration_configuration', 'en', 'Configuration', 'Navigation tile'),
  ('nav.administration_packs', 'en', 'Features and content', 'Starter Content Packs §2 and §10.'),
  ('nav.administration_permissions', 'en', 'Permissions', 'Navigation tile'),
  ('nav.audit', 'en', 'Audit log', 'Navigation tile'),
  ('nav.enter_company', 'en', 'Enter a company (recorded)', 'Account menu'),
  ('nav.governance', 'en', 'Change requests', 'Navigation tile'),
  ('nav.imports', 'en', 'Imports', 'Navigation tile'),
  ('nav.master_data', 'en', 'Master data', 'Navigation tile'),
  ('nav.operations_assurance', 'en', 'Assurance', 'Navigation tile'),
  ('nav.operations_integrations', 'en', 'Integrations', 'Navigation tile'),
  ('nav.operations_jobs', 'en', 'Scheduled jobs', 'Navigation tile'),
  ('nav.platform_console', 'en', 'Platform console', 'Account menu'),
  ('nav.procurement', 'en', 'Procurement', 'Navigation tile'),
  ('nav.sales', 'en', 'Sales', 'Navigation tile'),
  ('nav.tenant', 'en', 'Organisation lifecycle', 'Navigation tile'),
  ('nav.tenant_settings', 'en', 'Organisation settings', 'Account menu'),
  ('nav.terminology', 'en', 'Terminology', 'Navigation tile'),
  ('nav.your_company', 'en', 'Your company', 'Account menu'),
  ('notify.approval_escalated.body', 'en', 'An approval was not actioned in time and has come to you.', 'Starter Content Packs §9.2.'),
  ('notify.approval_escalated.subject', 'en', 'Approval escalated to you', 'Starter Content Packs §9.2.'),
  ('notify.approval_overdue.body', 'en', 'A document has been waiting for approval longer than the band allows.', 'Starter Content Packs §9.2.'),
  ('notify.approval_overdue.subject', 'en', 'Approval overdue', 'Starter Content Packs §9.2.'),
  ('notify.approval_requested.body', 'en', 'A document is waiting for your approval.', 'Starter Content Packs §9.2.'),
  ('notify.approval_requested.subject', 'en', 'Approval requested', 'Starter Content Packs §9.2.'),
  ('notify.batch_released.body', 'en', 'A batch has been released under named authority and is available.', 'Starter Content Packs §9.2.'),
  ('notify.batch_released.subject', 'en', 'Batch released', 'Starter Content Packs §9.2.'),
  ('notify.count_variance_above_tolerance.body', 'en', 'A count found a difference larger than its programme permits.', 'Starter Content Packs §9.2.'),
  ('notify.count_variance_above_tolerance.subject', 'en', 'Count variance above tolerance', 'Starter Content Packs §9.2.'),
  ('notify.deviation_raised.body', 'en', 'A deviation has been raised against a batch and needs an investigation and a corrective action.', 'Starter Content Packs §10, regulated goods.'),
  ('notify.deviation_raised.subject', 'en', 'Deviation raised', 'Starter Content Packs §10, regulated goods.'),
  ('notify.expiry_threshold_breached.body', 'en', 'A batch has less remaining life than the shelf-life minimum allows.', 'Starter Content Packs §9.2.'),
  ('notify.expiry_threshold_breached.subject', 'en', 'Batch approaching expiry', 'Starter Content Packs §9.2.'),
  ('notify.integration_backlog_above_threshold.body', 'en', 'Commands or events have been waiting longer than the threshold allows.', 'Starter Content Packs §9.2.'),
  ('notify.integration_backlog_above_threshold.subject', 'en', 'Integration backlog', 'Starter Content Packs §9.2.'),
  ('notify.job_failed.body', 'en', 'A scheduled job did not complete. Its run record has the reason.', 'Starter Content Packs §9.2.'),
  ('notify.job_failed.subject', 'en', 'Scheduled job failed', 'Starter Content Packs §9.2.'),
  ('notify.match_exception.body', 'en', 'A supplier invoice did not match its order and receipt within tolerance.', 'Starter Content Packs §9.2.'),
  ('notify.match_exception.subject', 'en', 'Invoice match exception', 'Starter Content Packs §9.2.'),
  ('notify.order_intake_rejected.body', 'en', 'An order received from an upstream system could not be accepted. The reason is on the order.', 'Starter Content Packs §10, channel sales.'),
  ('notify.order_intake_rejected.subject', 'en', 'Order rejected at intake', 'Starter Content Packs §10, channel sales.'),
  ('notify.period_close_task_overdue.body', 'en', 'A period close task has passed its due date and the close is blocked.', 'Starter Content Packs §9.2.'),
  ('notify.period_close_task_overdue.subject', 'en', 'Close task overdue', 'Starter Content Packs §9.2.'),
  ('notify.quality_event_raised.body', 'en', 'A quality event has been raised and needs an investigation.', 'Starter Content Packs §9.2.'),
  ('notify.quality_event_raised.subject', 'en', 'Quality event raised', 'Starter Content Packs §9.2.'),
  ('notify.receipt_discrepancy.body', 'en', 'A receipt differs from its order by more than the tolerance permits.', 'Starter Content Packs §9.2.'),
  ('notify.receipt_discrepancy.subject', 'en', 'Receipt outside tolerance', 'Starter Content Packs §9.2.'),
  ('notify.stock_shortage_on_release.body', 'en', 'An order could not be released in full: stock is short.', 'Starter Content Packs §9.2.'),
  ('notify.stock_shortage_on_release.subject', 'en', 'Stock short on release', 'Starter Content Packs §9.2.'),
  ('output.example_vat.box1', 'en', 'Tax due on sales', ''),
  ('output.example_vat.box4', 'en', 'Tax reclaimed on purchases', ''),
  ('output.example_vat.box5', 'en', 'Net tax due', ''),
  ('output.example_vat.return', 'en', 'VAT return', ''),
  ('permission.administration.audit_read', 'en', 'Read the audit trail', ''),
  ('permission.administration.configure', 'en', 'Change configuration', ''),
  ('permission.administration.integrate', 'en', 'Administer integrations', ''),
  ('permission.administration.jobs', 'en', 'Administer scheduled jobs', ''),
  ('permission.administration.promote', 'en', 'Promote configuration', ''),
  ('permission.administration.read', 'en', 'View administration', ''),
  ('permission.administration.roles', 'en', 'Administer roles', ''),
  ('permission.administration.users', 'en', 'Administer users', ''),
  ('permission.finance.approve_payment', 'en', 'Approve payments', ''),
  ('permission.finance.close_period', 'en', 'Close periods', ''),
  ('permission.finance.configure', 'en', 'Configure finance', ''),
  ('permission.finance.post', 'en', 'Post journals', ''),
  ('permission.finance.read', 'en', 'View finance', ''),
  ('permission.finance.reopen_period', 'en', 'Reopen periods', ''),
  ('permission.inventory.adjust', 'en', 'Adjust stock', ''),
  ('permission.inventory.count', 'en', 'Perform stock counts', ''),
  ('permission.inventory.move', 'en', 'Move stock', ''),
  ('permission.inventory.read', 'en', 'View stock', ''),
  ('permission.inventory.write_off', 'en', 'Write off stock', ''),
  ('permission.logistics.despatch', 'en', 'Confirm despatch', ''),
  ('permission.logistics.plan', 'en', 'Plan shipments', ''),
  ('permission.logistics.read', 'en', 'View logistics', ''),
  ('permission.master_data.approve', 'en', 'Approve master data changes', ''),
  ('permission.master_data.import', 'en', 'Import master data', ''),
  ('permission.master_data.read', 'en', 'View master data', ''),
  ('permission.master_data.write', 'en', 'Maintain master data', ''),
  ('permission.planning.firm', 'en', 'Firm planned orders', ''),
  ('permission.planning.forecast', 'en', 'Maintain forecasts', ''),
  ('permission.planning.read', 'en', 'View planning', ''),
  ('permission.planning.run', 'en', 'Run planning', ''),
  ('permission.procurement.approve', 'en', 'Approve procurement', ''),
  ('permission.procurement.match', 'en', 'Match invoices', ''),
  ('permission.procurement.order', 'en', 'Issue purchase orders', ''),
  ('permission.procurement.read', 'en', 'View procurement', ''),
  ('permission.procurement.receive', 'en', 'Receive goods', ''),
  ('permission.procurement.requisition', 'en', 'Raise requisitions', ''),
  ('permission.production.execute', 'en', 'Record production', ''),
  ('permission.production.order', 'en', 'Raise works orders', ''),
  ('permission.production.read', 'en', 'View production', ''),
  ('permission.production.release', 'en', 'Release production', ''),
  ('permission.quality.disposition', 'en', 'Disposition quarantined stock', ''),
  ('permission.quality.inspect', 'en', 'Record inspections', ''),
  ('permission.quality.read', 'en', 'View quality', ''),
  ('permission.quality.recall', 'en', 'Manage recalls', ''),
  ('permission.quality.release_batch', 'en', 'Release batches', ''),
  ('permission.reporting.define', 'en', 'Define reports', ''),
  ('permission.reporting.export', 'en', 'Export data', ''),
  ('permission.reporting.read', 'en', 'View reports', ''),
  ('permission.sales.credit_release', 'en', 'Release credit holds', ''),
  ('permission.sales.despatch', 'en', 'Despatch orders', ''),
  ('permission.sales.discount_approve', 'en', 'Approve discounts', ''),
  ('permission.sales.invoice', 'en', 'Raise invoices', ''),
  ('permission.sales.order', 'en', 'Take sales orders', ''),
  ('permission.sales.price', 'en', 'Maintain pricing', ''),
  ('permission.sales.read', 'en', 'View sales', ''),
  ('rule.example_vat.energy', 'en', 'Domestic energy is reduced rated', ''),
  ('rule.example_vat.export', 'en', 'Exports are zero rated', ''),
  ('rule.example_vat.food', 'en', 'Basic food is zero rated', ''),
  ('rule.example_vat.standard', 'en', 'Standard rate', ''),
  ('ui.a_contractor_routed_to_their_engaging_ma_1egkazz', 'en', 'A contractor routed to their engaging manager, a new starter under supervision, a project team routed to the project owner.', 'Interface wording'),
  ('ui.a_department_1hmn4ci', 'en', 'A department', 'Interface wording'),
  ('ui.a_department_is_one_object_it_routes_an_bbg3tt', 'en', 'A department is one object: it routes an approval and it carries the posting. Bands decide who approves by value; a named assignment overrides that for a person, a role or a whole department.', 'Interface wording'),
  ('ui.a_mandatory_axis_must_be_answered_before_t258mt', 'en', 'A mandatory axis must be answered before a product can be created.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.a_partner_class_separates_for_example_ex_wh84w', 'en', 'A partner class separates, for example, export from domestic settlement.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.a_person_81gl1t', 'en', 'A person', 'Interface wording'),
  ('ui.a_role_jzqd70', 'en', 'A role', 'Interface wording'),
  ('ui.a_wave_with_short_lines_has_raised_reple_1wvoyjl', 'en', 'A wave with short lines has raised replenishment and cannot print yet.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.abbreviation_apwmtd', 'en', 'Abbreviation', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.accept_me22x5', 'en', 'Accept', 'Interface wording'),
  ('ui.accept_with_concession_4fwbu9', 'en', 'Accept with concession', 'Interface wording'),
  ('ui.accepted_7p703k', 'en', 'accepted', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.account_determination_1yz4psv', 'en', 'Account determination', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.account_oyp43g', 'en', 'Nominal account', 'Interface wording'),
  ('ui.accuracy_5ar1ij', 'en', 'Accuracy %', 'Interface wording'),
  ('ui.acknowledged_16pjkut', 'en', 'Acknowledged', 'Interface wording'),
  ('ui.across_all_planned_orders_6hf652', 'en', 'across all planned orders', 'Interface wording'),
  ('ui.acted_191zjze', 'en', 'Acted', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.action_2wk0tb', 'en', 'Action', 'Interface wording'),
  ('ui.actions_1rx51qc', 'en', 'Actions', 'Interface wording'),
  ('ui.active_recalls_17t59ep', 'en', 'Active recalls', 'Interface wording'),
  ('ui.add_or_amend_a_band_123ign0', 'en', 'Add or amend a band', 'Interface wording'),
  ('ui.add_or_amend_a_department_883mp1', 'en', 'Add or amend a department', 'Interface wording'),
  ('ui.administration_13wux9r', 'en', 'Administration', 'Interface wording'),
  ('ui.adopt_the_stocking_policy_the_engine_cal_icle0a', 'en', 'Adopt the stocking policy the engine calculates for one product and site.', 'Interface wording'),
  ('ui.age_band_1eh0xwj', 'en', 'Age band', 'Interface wording'),
  ('ui.age_days_1gruvqi', 'en', 'Age (days)', 'Interface wording'),
  ('ui.ageing_fvf4ak', 'en', 'Ageing', 'Interface wording'),
  ('ui.all_wnjk2s', 'en', 'All', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.allocate_a_landed_cost_1enfxp8', 'en', 'Allocate a landed cost', 'Interface wording'),
  ('ui.allocated_hxv4ya', 'en', 'Allocated', 'Interface wording'),
  ('ui.allow_self_invoice_k8libq', 'en', 'Allow self-invoice', 'Interface wording'),
  ('ui.amount_a2ky21', 'en', 'Amount', 'Interface wording'),
  ('ui.answer_1x69ce7', 'en', 'Answer', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.any_13li50t', 'en', 'Any', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.append_only_the_code_the_template_versio_1h5rzro', 'en', 'Append-only: the code, the template version that composed it, and when.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.applies_to_1ohnv0g', 'en', 'Applies to', 'Interface wording'),
  ('ui.apply_1k6e5zv', 'en', 'Apply', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.apply_calculated_policy_15nnqw9', 'en', 'Apply calculated policy', 'Interface wording'),
  ('ui.apply_cash_q5kc9q', 'en', 'Apply cash', 'Interface wording'),
  ('ui.approval_audit_10f0yrh', 'en', 'Approval audit', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.approve_a_payment_run_1c44vfq', 'en', 'Approve a payment run', 'Interface wording'),
  ('ui.approved_1j3qly2', 'en', 'Approved', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.approver_1czzcoo', 'en', 'Approver', 'Interface wording'),
  ('ui.approver_away_9whygy', 'en', 'Approver away', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.approver_role_code_79th1p', 'en', 'Approver role code', 'Interface wording'),
  ('ui.approvers_12rudap', 'en', 'Approvers', 'Interface wording'),
  ('ui.approvers_act_1y1sgdt', 'en', 'Approvers act', 'Interface wording'),
  ('ui.area_88rn8k', 'en', 'Area', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.arrived_on_1fywfib', 'en', 'Arrived on', 'Interface wording'),
  ('ui.ask_a_counting_programme_for_its_next_se_40t1ft', 'en', 'Ask a counting programme for its next set of tasks.', 'Interface wording'),
  ('ui.ask_a_question_1l184r', 'en', 'Ask a question', 'Interface wording'),
  ('ui.ask_the_warehouse_to_move_what_is_standi_voi1zh', 'en', 'Ask the warehouse to move what is standing in goods-in.', 'Interface wording'),
  ('ui.ask_yohkfm', 'en', 'Ask', 'Interface wording'),
  ('ui.asking_19nsic8', 'en', 'Asking…', 'Interface wording'),
  ('ui.assembly_88dy11', 'en', 'Assembly', 'Interface wording'),
  ('ui.asset_108qnnf', 'en', 'Asset', 'Interface wording'),
  ('ui.assign_a_named_approver_11126f7', 'en', 'Assign a named approver', 'Interface wording'),
  ('ui.assign_someone_to_a_department_1qfjf3s', 'en', 'Assign someone to a department', 'Interface wording'),
  ('ui.assurance_3cm5rq', 'en', 'Assurance', 'Interface wording'),
  ('ui.audit_finding_17a2an9', 'en', 'Audit finding', 'Interface wording'),
  ('ui.audit_log_1kguyfe', 'en', 'Audit log', 'Interface wording'),
  ('ui.available_to_promise_pozt5s', 'en', 'Available to promise', 'Interface wording'),
  ('ui.available_vp7tiw', 'en', 'Available', 'Interface wording'),
  ('ui.average_party_record_score_gtquen', 'en', 'average business partner record score', 'Interface wording'),
  ('ui.awaiting_despatch_mgoi1v', 'en', 'Awaiting despatch', 'Interface wording'),
  ('ui.awaiting_release_q3ob3e', 'en', 'awaiting release', 'Interface wording'),
  ('ui.axis_1turcic', 'en', 'Axis', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.balance_kxxksr', 'en', 'Balance', 'Interface wording'),
  ('ui.band_160umau', 'en', 'Band', 'Interface wording'),
  ('ui.band_number_1r4zhmn', 'en', 'Band number', 'Interface wording'),
  ('ui.band_one_takes_the_request_up_to_its_cei_zo483t', 'en', 'Band one takes the request up to its ceiling; higher bands add authority above it.', 'Interface wording'),
  ('ui.bands_zzpczz', 'en', 'Bands', 'Interface wording'),
  ('ui.basis_1s593bh', 'en', 'Basis', 'Interface wording'),
  ('ui.batch_1th9wnv', 'en', 'Batch', 'Interface wording'),
  ('ui.batch_genealogy_6q68ay', 'en', 'Batch genealogy', 'Interface wording'),
  ('ui.batch_ids_1g6tmit', 'en', 'Batch ids', 'Interface wording'),
  ('ui.batch_number_1g0mhsc', 'en', 'Batch number', 'Interface wording'),
  ('ui.batch_record_aef9i8', 'en', 'Batch record', 'Interface wording'),
  ('ui.batches_m22sy3', 'en', 'Batches', 'Interface wording'),
  ('ui.batches_reaching_their_expiry_inside_thi_191sbrw', 'en', 'Batches reaching their expiry inside thirty days.', 'Interface wording'),
  ('ui.below_cover_e2il1x', 'en', 'Below cover', 'Interface wording'),
  ('ui.blank_means_all_of_it_ut23oc', 'en', 'Blank means all of it.', 'Interface wording'),
  ('ui.book_a_shipment_19ksqwf', 'en', 'Book a shipment', 'Interface wording'),
  ('ui.book_operation_time_fwcny2', 'en', 'Book operation time', 'Interface wording'),
  ('ui.breadcrumb_dfc3fw', 'en', 'Breadcrumb', 'Interface wording'),
  ('ui.budget_against_actual_for_one_budget_cod_bih3v8', 'en', 'Budget against actual for one budget code.', 'Interface wording'),
  ('ui.budget_position_uilrcb', 'en', 'Budget position', 'Interface wording'),
  ('ui.building_1j2ryrt', 'en', 'Building…', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.by_n9pol0', 'en', 'By', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.calculated_stocking_policy_y6n4al', 'en', 'Calculated stocking policy', 'Interface wording'),
  ('ui.cancel_ew9em3', 'en', 'Cancel', 'Interface wording'),
  ('ui.candidate_1vb7im2', 'en', 'Candidate', 'Interface wording'),
  ('ui.carrier_7f8eqf', 'en', 'Carrier', 'Interface wording'),
  ('ui.carrier_code_1nebvb8', 'en', 'Carrier code', 'Interface wording'),
  ('ui.cause_vbnqgw', 'en', 'Cause', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.change_18wuq59', 'en', 'Change', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.change_request_19fuwuw', 'en', 'Change request', 'Interface wording'),
  ('ui.change_requests_y01ult', 'en', 'Change requests', 'Interface wording'),
  ('ui.channel_s4ids4', 'en', 'Channel', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.characteristic_1uvx3gc', 'en', 'Characteristic', 'Interface wording'),
  ('ui.check_without_loading_4m4p2j', 'en', 'Check without loading', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.checked_mocm06', 'en', 'Checked', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.choose_11hfygi', 'en', 'Choose…', 'Interface wording'),
  ('ui.choose_a_csv_file_1lc6iwf', 'en', 'Choose a CSV file', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.choose_a_wave_above_lines_show_what_allo_1l2fdo5', 'en', 'Choose a wave above; lines show what allocated and what fell short.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.choose_a_wave_o5rgnk', 'en', 'Choose a wave', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.chosen_by_19yic4o', 'en', 'Chosen by', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.class_mgtyu7', 'en', 'Class', 'Interface wording'),
  ('ui.classification_1ufvrz5', 'en', 'Classification', 'Interface wording'),
  ('ui.classification_and_coding_1gs4zy2', 'en', 'Classification and coding', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.classification_axes_7bbte2', 'en', 'Classification axes', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.classified_as_zwlvme', 'en', 'Classified as', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.close_1l0xxoj', 'en', 'Close', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.close_a_period_1srnx21', 'en', 'Close a period', 'Interface wording'),
  ('ui.close_a_quality_event_5h3qm1', 'en', 'Close a quality event', 'Interface wording'),
  ('ui.close_a_works_order_1dabxry', 'en', 'Close a works order', 'Interface wording'),
  ('ui.code_assignments_10x9876', 'en', 'Code assignments', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.code_divergences_wr3f73', 'en', 'Code divergences', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.code_templates_4ngldb', 'en', 'Code templates', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.code_xoaiok', 'en', 'Code', 'Interface wording'),
  ('ui.coded_as_up85bk', 'en', 'Coded as', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.combine_one_batch_into_another_of_the_sa_lf7hb8', 'en', 'Combine one batch into another of the same product and condition.', 'Interface wording'),
  ('ui.comma_separated_1vzsahj', 'en', 'Comma separated.', 'Interface wording'),
  ('ui.companies_ohmslk', 'en', 'Companies', 'Terminology §2. Hard-coded in a component before this, so nothing could rename it.'),
  ('ui.company_1hra0d8', 'en', 'Company', 'Terminology §2. Hard-coded in a component before this, so nothing could rename it.'),
  ('ui.complaint_jjpeai', 'en', 'Complaint', 'Interface wording'),
  ('ui.complete_a_close_task_1tk85y', 'en', 'Complete a close task', 'Interface wording'),
  ('ui.complete_a_warehouse_task_1t3vxk3', 'en', 'Complete a warehouse task', 'Interface wording'),
  ('ui.completed_1tmo59u', 'en', 'Completed', 'Interface wording'),
  ('ui.completeness_and_validity_of_party_maste_v5rmnd', 'en', 'Completeness and validity of business partner master records.', 'Interface wording'),
  ('ui.completeness_gaps_6wf2x6', 'en', 'Completeness gaps', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.completion_1tatcxz', 'en', 'Completion', 'Interface wording'),
  ('ui.component_availability_9s472b', 'en', 'Component availability', 'Interface wording'),
  ('ui.configuration_7beqft', 'en', 'Configuration', 'Interface wording'),
  ('ui.content_packs_4rf0hw', 'en', 'Content packs', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.corrective_action_1iqcjkd', 'en', 'Corrective action', 'Interface wording'),
  ('ui.cost_basis_by_item_and_site_in_minor_uni_dxj7uz', 'en', 'Cost basis by product and site, in minor units.', 'Interface wording'),
  ('ui.cost_centre_1l6b0ij', 'en', 'Cost centre', 'Interface wording'),
  ('ui.cost_t05i6w', 'en', 'Cost', 'Interface wording'),
  ('ui.count_accuracy_wtoc4p', 'en', 'Count accuracy', 'Interface wording'),
  ('ui.count_tasks_1qfoupa', 'en', 'Count tasks', 'Interface wording'),
  ('ui.counted_1v5v091', 'en', 'Counted', 'Interface wording'),
  ('ui.counted_quantity_i6ia1q', 'en', 'Counted quantity', 'Interface wording'),
  ('ui.cover_against_policy_by_item_and_site_9mlsyn', 'en', 'Cover against policy, by product and site.', 'Interface wording'),
  ('ui.cover_in_force_1snmsuk', 'en', 'Cover in force', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.cover_rh21pc', 'en', 'Cover', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.coverage_2uklyk', 'en', 'Coverage %', 'Interface wording'),
  ('ui.coverage_by_section_a0jv93', 'en', 'Coverage by section', 'Interface wording'),
  ('ui.coverage_could_not_be_measured_m4rhia', 'en', 'Coverage could not be measured.', 'Interface wording'),
  ('ui.covered_by_1cumwvi', 'en', 'Covered by', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.creates_the_organisation_its_root_compan_hfaupo', 'en', 'Creates the organisation, its root company, its administrator role, and a single-use invitation for its first administrator.', 'Terminology §2. Hard-coded in a component before this, so nothing could rename it.'),
  ('ui.credit_position_10kq3v3', 'en', 'Credit position', 'Interface wording'),
  ('ui.credit_q4hoys', 'en', 'Credit', 'Interface wording'),
  ('ui.critical_11om8bs', 'en', 'Critical', 'Interface wording'),
  ('ui.currency_5o3zh2', 'en', 'Currency', 'Interface wording'),
  ('ui.current_1dw4k8q', 'en', 'Current', 'Interface wording'),
  ('ui.customer_2reqex', 'en', 'Customer', 'Interface wording'),
  ('ui.customers_overdue_enough_to_contact_1iph5wf', 'en', 'Customers overdue enough to contact.', 'Interface wording'),
  ('ui.dashboard_4zftyz', 'en', 'Dashboard', 'Interface wording'),
  ('ui.data_quality_duplicates_and_specificatio_1egn1d1', 'en', 'Data quality, duplicates and specification coverage, read from operational tables.', 'Interface wording'),
  ('ui.date_and_time_e_g_2026_08_30_06_00_10yphom', 'en', 'Date and time, e.g. 2026-08-30 06:00', 'Interface wording'),
  ('ui.date_and_time_e_g_2026_08_30_18_00_itofvv', 'en', 'Date and time, e.g. 2026-08-30 18:00', 'Interface wording'),
  ('ui.days_left_1oqkq5n', 'en', 'Days left', 'Interface wording'),
  ('ui.days_pxfr8q', 'en', 'Days', 'Interface wording'),
  ('ui.debit_gzxerx', 'en', 'Debit', 'Interface wording'),
  ('ui.default_180_i5ioyl', 'en', 'Default 180.', 'Interface wording'),
  ('ui.default_60_1hajms6', 'en', 'Default 60.', 'Interface wording'),
  ('ui.default_76b532', 'en', 'Default', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.default_cost_centre_1hfdtsi', 'en', 'Default cost centre', 'Interface wording'),
  ('ui.deliberate_overrides_h38xg3', 'en', 'Deliberate overrides', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.deliveries_1gaaynd', 'en', 'Deliveries', 'Interface wording'),
  ('ui.delivery_ids_1nh1yhv', 'en', 'Delivery ids', 'Interface wording'),
  ('ui.delivery_performance_1ozclhf', 'en', 'Delivery performance', 'Interface wording'),
  ('ui.department_1430r53', 'en', 'Department', 'Interface wording'),
  ('ui.departments_and_membership_a_person_s_pr_1c0yw9v', 'en', 'Departments and membership. A person''s primary department at capture is the one that routes their request.', 'Interface wording'),
  ('ui.departments_membership_value_bands_and_n_ggkllc', 'en', 'Departments, membership, value bands and named approvers — who approves what, and why.', 'Interface wording'),
  ('ui.departments_zcmjcs', 'en', 'Departments', 'Interface wording'),
  ('ui.depreciation_1iqbmt4', 'en', 'Depreciation', 'Interface wording'),
  ('ui.destroy_lhre1x', 'en', 'Destroy', 'Interface wording'),
  ('ui.determination_matrix_za4m7x', 'en', 'Account determination', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.deviation_vj50qc', 'en', 'Deviation', 'Interface wording'),
  ('ui.dimensions_pewa8g', 'en', 'Analysis codes', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.disassembly_enmt6z', 'en', 'Disassembly', 'Interface wording'),
  ('ui.disposition_12yvh04', 'en', 'Disposition', 'Interface wording'),
  ('ui.disposition_an_inspection_dsas07', 'en', 'Disposition an inspection', 'Interface wording'),
  ('ui.done_13cn9g1', 'en', 'Done', 'Interface wording'),
  ('ui.download_current_fyg004', 'en', 'Download current', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.download_empty_template_1141fv6', 'en', 'Download empty template', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.dunning_worklist_a5d2oj', 'en', 'Dunning worklist', 'Interface wording'),
  ('ui.duplicate_candidates_lsipuo', 'en', 'Duplicate candidates', 'Interface wording'),
  ('ui.each_department_is_also_a_reporting_dime_d9fuqy', 'en', 'Each department is also a reporting analysis code, so a department means the same thing in a stock report and in a profit and loss.', 'Interface wording'),
  ('ui.effect_uq3mgk', 'en', 'Effect', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.end_a_membership_sv11vz', 'en', 'End a membership', 'Interface wording'),
  ('ui.end_a_named_assignment_1dw3wsp', 'en', 'End a named assignment', 'Interface wording'),
  ('ui.ends_on_18n75l8', 'en', 'Ends on', 'Interface wording'),
  ('ui.errors_1swmtuu', 'en', 'Errors', 'Interface wording'),
  ('ui.escalate_after_hours_zufeix', 'en', 'Escalate after (hours)', 'Interface wording'),
  ('ui.escalate_to_the_department_manager_104rztq', 'en', 'Escalate to the department manager', 'Interface wording'),
  ('ui.events_by_kind_1cedkn5', 'en', 'Events by kind', 'Interface wording'),
  ('ui.events_dispositions_supplier_qualificati_1mtd92r', 'en', 'Events, dispositions, supplier qualification and recall — each with a clock.', 'Interface wording'),
  ('ui.every_account_with_a_movement_by_ledger_16xm7kf', 'en', 'Every nominal account with a movement, by ledger.', 'Interface wording'),
  ('ui.every_item_answers_every_mandatory_axis_1sptct5', 'en', 'Every product answers every mandatory axis.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.every_line_on_this_wave_has_allocated_in_1kboj23', 'en', 'Every line on this wave has allocated in full.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.everything_1unt64g', 'en', 'Everything', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.everything_one_batch_touched_what_it_was_nnl9q2', 'en', 'Everything one batch touched — what it was made from and where it went.', 'Interface wording'),
  ('ui.everything_raised_with_progress_against_730h8v', 'en', 'Everything raised, with progress against the ordered quantity.', 'Interface wording'),
  ('ui.everywhere_e07k33', 'en', 'Everywhere', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.exceptions_by_kind_1o05bee', 'en', 'Exceptions by kind', 'Interface wording'),
  ('ui.excursion_14q3twf', 'en', 'Excursion', 'Interface wording'),
  ('ui.expected_119zxmh', 'en', 'Expected', 'Interface wording'),
  ('ui.expiring_in_30_days_1x3bmoa', 'en', 'Expiring in 30 days', 'Interface wording'),
  ('ui.expiry_horizon_1evzx19', 'en', 'Expiry horizon', 'Interface wording'),
  ('ui.fall_back_to_the_line_manager_1f4prf4', 'en', 'Fall back to the line manager', 'Interface wording'),
  ('ui.features_u1k6p6', 'en', 'Features', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.finance_1iwemj1', 'en', 'Finance', 'Interface wording'),
  ('ui.fixed_assets_1r5d3wq', 'en', 'Fixed assets', 'Interface wording'),
  ('ui.forecast_code_1r884hx', 'en', 'Forecast code', 'Interface wording'),
  ('ui.from_6s9hn9', 'en', 'From', 'Interface wording'),
  ('ui.gated_ny2ste', 'en', 'Gated', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.gated_on_full_allocation_d2swii', 'en', 'Gated on full allocation', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.go_live_export_and_portability_deletion_g7tyvw', 'en', 'Go-live, export and portability, deletion.', 'Interface wording'),
  ('ui.goods_received_not_invoiced_1kd66ku', 'en', 'Goods received not invoiced', 'Interface wording'),
  ('ui.govern_assure_zfw0cp', 'en', 'Govern & assure', 'Interface wording'),
  ('ui.group_deliveries_leaving_one_site_on_one_k6515c', 'en', 'Group deliveries leaving one site on one day.', 'Interface wording'),
  ('ui.held_a40u4e', 'en', 'held', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.held_back_12k2v2h', 'en', 'Held back', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.high_1gq8xlp', 'en', 'High', 'Interface wording'),
  ('ui.history_buckets_9f9ck', 'en', 'History buckets', 'Interface wording'),
  ('ui.history_yugfpb', 'en', 'History', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.hold_the_request_and_raise_an_exception_1ygc1mr', 'en', 'Hold the request and raise an exception', 'Interface wording'),
  ('ui.holds_p0h2fl', 'en', 'holds', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.home_n0mxf2', 'en', 'Home', 'Interface wording'),
  ('ui.horizon_days_11i6xpy', 'en', 'Horizon (days)', 'Interface wording'),
  ('ui.how_close_the_counts_came_by_programme_qn5oib', 'en', 'How close the counts came, by programme.', 'Interface wording'),
  ('ui.how_long_stock_has_been_standing_still_nx7ovz', 'en', 'How long stock has been standing still.', 'Interface wording'),
  ('ui.imports_1pi5v2d', 'en', 'Imports', 'Interface wording'),
  ('ui.in_force_jgi18h', 'en', 'In force', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.in_full_135owdv', 'en', 'In full', 'Interface wording'),
  ('ui.in_minor_units_pence_cents_c1cgnc', 'en', 'In minor units — pence, cents.', 'Interface wording'),
  ('ui.in_parallel_zv7ywl', 'en', 'In parallel', 'Interface wording'),
  ('ui.in_sequence_118s1n7', 'en', 'In sequence', 'Interface wording'),
  ('ui.in_the_last_ninety_days_46h8el', 'en', 'in the last ninety days', 'Interface wording'),
  ('ui.install_modules_and_promote_the_change_s_1aaibs6', 'en', 'Install modules and promote the change sets that put them in force.', 'Interface wording'),
  ('ui.instrument_11k9y6o', 'en', 'Instrument', 'Interface wording'),
  ('ui.integrations_1sd7qpm', 'en', 'Integrations', 'Interface wording'),
  ('ui.intercompany_position_b0elzn', 'en', 'Intercompany position', 'Interface wording'),
  ('ui.inventory_1jpyzfj', 'en', 'Inventory', 'Interface wording'),
  ('ui.invoice_a_delivery_e88lht', 'en', 'Invoice a delivery', 'Interface wording'),
  ('ui.issue_components_ahu3uc', 'en', 'Issue components', 'Interface wording'),
  ('ui.item_8pkkxy', 'en', 'Product', 'Interface wording'),
  ('ui.item_and_site_positions_fshzg6', 'en', 'product and site positions', 'Interface wording'),
  ('ui.item_class_jrtsg2', 'en', 'Product class', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.item_classes_11oxuoy', 'en', 'Product classes', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.item_supply_v8w5xl', 'en', 'Product supply', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.items_and_their_posting_class_12w1f1w', 'en', 'Products and their accounting code', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.items_that_are_missing_an_answer_a_manda_17xvaz0', 'en', 'Products that are missing an answer a mandatory axis requires.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.items_without_a_class_are_listed_first_t_1m8ppxe', 'en', 'Products without a class are listed first — they cannot be posted.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.kind_hqumoz', 'en', 'Kind', 'Interface wording'),
  ('ui.kitting_tqub47', 'en', 'Kitting', 'Interface wording'),
  ('ui.lead_time_14eo3vg', 'en', 'Lead time', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.ledger_el0kvg', 'en', 'Ledger', 'Interface wording'),
  ('ui.ledgers_17kn099', 'en', 'Ledgers', 'Interface wording'),
  ('ui.less_18u3mqg', 'en', 'Less', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.likely_duplicate_parties_for_merge_with_1qewjc', 'en', 'Likely duplicate business partners, for merge with a survivor and a reason.', 'Interface wording'),
  ('ui.limit_exposure_and_what_is_left_for_one_40xm0i', 'en', 'Limit, exposure and what is left for one customer.', 'Interface wording'),
  ('ui.line_166mv5z', 'en', 'Line', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.lines_12bghr0', 'en', 'Lines', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.load_t1oh6x', 'en', 'Load', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.loaded_l60lk0', 'en', 'Loaded', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.loading_cwepyb', 'en', 'Loading…', 'Interface wording'),
  ('ui.location_pghiva', 'en', 'Location', 'Interface wording'),
  ('ui.log_a_recall_action_qjio6f', 'en', 'Log a recall action', 'Interface wording'),
  ('ui.logistics_146p7sg', 'en', 'Logistics', 'Interface wording'),
  ('ui.low_1dcndpd', 'en', 'Low', 'Interface wording'),
  ('ui.lower_bands_6geh0i', 'en', 'Lower bands', 'Interface wording'),
  ('ui.lower_bands_re_run_ufshv', 'en', 'Lower bands re-run', 'Interface wording'),
  ('ui.make_k3edan', 'en', 'Make', 'Interface wording'),
  ('ui.manager_1u11j70', 'en', 'Manager', 'Interface wording'),
  ('ui.mandatory_dz4dp4', 'en', 'Mandatory', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.master_data_1l5vu8p', 'en', 'Master data', 'Interface wording'),
  ('ui.matched_16yj8hj', 'en', 'Matched', 'Interface wording'),
  ('ui.max_gtvgs9', 'en', 'Max', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.measured_value_1yohoi8', 'en', 'Measured value', 'Interface wording'),
  ('ui.medium_2pbr86', 'en', 'Medium', 'Interface wording'),
  ('ui.members_1ttovjk', 'en', 'Members', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.membership_1xonaih', 'en', 'Membership', 'Interface wording'),
  ('ui.merge_two_batches_uhc5k1', 'en', 'Merge two batches', 'Interface wording'),
  ('ui.message_1cam7ic', 'en', 'Message', 'Interface wording'),
  ('ui.min_cx9lh3', 'en', 'Min', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.minimum_793d7b', 'en', 'Minimum', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.minutes_f7vpn2', 'en', 'Minutes', 'Interface wording'),
  ('ui.mode_n44ilu', 'en', 'Mode', 'Interface wording'),
  ('ui.move_zaagxg', 'en', 'Move', 'Interface wording'),
  ('ui.name_4el6o6', 'en', 'Name', 'Interface wording'),
  ('ui.named_approver_assignments_1tm6mwt', 'en', 'Named approver assignments', 'Interface wording'),
  ('ui.near_miss_1c4tdd', 'en', 'Near miss', 'Interface wording'),
  ('ui.needed_by_15f13tl', 'en', 'Needed by', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.needs_bx5mje', 'en', 'Needs', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.needs_chasing_lrsd57', 'en', 'Needs chasing', 'Interface wording'),
  ('ui.net_11rvkl4', 'en', 'Net', 'Interface wording'),
  ('ui.net_and_tax_by_code_for_the_current_peri_6gg6j2', 'en', 'Net and tax by code for the current period.', 'Interface wording'),
  ('ui.net_book_value_1knb9jw', 'en', 'Net book value', 'Interface wording'),
  ('ui.never_switched_17tp1oc', 'en', 'Never switched.', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.new_batch_number_a9zta', 'en', 'New batch number', 'Interface wording'),
  ('ui.new_business_partner_1ys4mkz', 'en', 'New business partner', 'Terminology §2. Hard-coded in a component before this, so nothing could rename it.'),
  ('ui.new_product_j7i5mi', 'en', 'New product', 'Terminology §2. Hard-coded in a component before this, so nothing could rename it.'),
  ('ui.next_number_drm4a1', 'en', 'Next number', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_aged_stock_1yt76w9', 'en', 'No aged stock.', 'Interface wording'),
  ('ui.no_aged_stock_to_profile_12go9qn', 'en', 'No aged stock to profile.', 'Interface wording'),
  ('ui.no_approvals_have_been_resolved_yet_17jm5ty', 'en', 'No approvals have been resolved yet.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_axes_yet_until_one_exists_items_carry_1xv6iw3', 'en', 'No axes yet. Until one exists, products carry no structured meaning.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_bands_are_configured_until_one_exists_1xaii6t', 'en', 'No bands are configured. Until one exists, nothing routes by value.', 'Interface wording'),
  ('ui.no_batches_yet_1fl7v8m', 'en', 'No batches yet.', 'Interface wording'),
  ('ui.no_ceiling_1w4crxh', 'en', 'No ceiling', 'Interface wording'),
  ('ui.no_codes_have_been_composed_yet_1n42lkk', 'en', 'No codes have been composed yet.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_count_tasks_raised_csrxi9', 'en', 'No count tasks raised.', 'Interface wording'),
  ('ui.no_counts_posted_yet_so_accuracy_cannot_qypept', 'en', 'No counts posted yet, so accuracy cannot be stated.', 'Interface wording'),
  ('ui.no_deliveries_in_the_window_klity4', 'en', 'No deliveries in the window.', 'Interface wording'),
  ('ui.no_departments_are_configured_yet_5uvbvr', 'en', 'No departments are configured yet.', 'Interface wording'),
  ('ui.no_exceptions_the_plan_is_currently_cons_qhlopi', 'en', 'No exceptions — the plan is currently consistent.', 'Interface wording'),
  ('ui.no_exceptions_to_profile_ntrsg2', 'en', 'No exceptions to profile.', 'Interface wording'),
  ('ui.no_features_in_the_catalogue_s5xkok', 'en', 'No features in the catalogue.', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.no_fiscal_calendar_yet_1orkrva', 'en', 'No financial calendar yet.', 'Interface wording'),
  ('ui.no_fixed_assets_recorded_1m7l09z', 'en', 'No fixed assets recorded.', 'Interface wording'),
  ('ui.no_intercompany_balances_qvgd5i', 'en', 'No intercompany balances.', 'Interface wording'),
  ('ui.no_item_has_a_supplier_yet_purchasing_ca_19ecbyg', 'en', 'No product has a supplier yet. Purchasing cannot resolve anything until one does.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_item_has_diverged_from_the_classifica_1xl6zc9', 'en', 'No product has diverged from the classification behind its code.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_items_yet_d17dhi', 'en', 'No products yet.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_ledger_configured_installing_the_fina_1ybnzgk', 'en', 'No ledger configured. Installing the finance module is what creates one.', 'Interface wording'),
  ('ui.no_likely_duplicates_1kp1z8q', 'en', 'No likely duplicates.', 'Interface wording'),
  ('ui.no_named_assignments_everything_routes_b_2tii32', 'en', 'No named assignments. Everything routes by department band.', 'Interface wording'),
  ('ui.no_overrides_have_been_recorded_qwt4wp', 'en', 'No overrides have been recorded.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_packs_are_published_1w99mii', 'en', 'No packs are published.', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.no_party_master_data_to_assess_yet_13fdrkf', 'en', 'No business partner master data to assess yet.', 'Interface wording'),
  ('ui.no_planned_orders_nothing_is_short_again_1iguumb', 'en', 'No planned orders. Nothing is short against current demand.', 'Interface wording'),
  ('ui.no_posting_classes_yet_until_one_exists_1lyh86r', 'en', 'No accounting codes yet. Until one exists, nothing can be determined.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_quality_events_open_1s4jnsa', 'en', 'No quality events open.', 'Interface wording'),
  ('ui.no_quality_events_to_profile_iijmx2', 'en', 'No quality events to profile.', 'Interface wording'),
  ('ui.no_r5wqai', 'en', 'No', 'Interface wording'),
  ('ui.no_recalls_this_is_the_panel_you_want_to_1rbu64d', 'en', 'No recalls. This is the panel you want to stay empty.', 'Interface wording'),
  ('ui.no_release_areas_yet_allocation_runs_aga_1cd7ocp', 'en', 'No marshalling areas yet. Allocation runs against the whole site until one exists.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_rules_yet_every_posting_would_be_refu_1uduqry', 'en', 'No rules yet. Every posting would be refused until at least one exists.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_shipments_planned_19w0nzf', 'en', 'No shipments planned.', 'Interface wording'),
  ('ui.no_stock_positions_yet_nothing_has_moved_1fukkx8', 'en', 'No stock positions yet — nothing has moved into this organisation.', 'Interface wording'),
  ('ui.no_supplier_qualifications_recorded_1cbjno2', 'en', 'No supplier qualifications recorded.', 'Interface wording'),
  ('ui.no_taxable_transactions_in_this_period_x7qvk8', 'en', 'No taxable transactions in this period.', 'Interface wording'),
  ('ui.no_templates_yet_item_codes_would_then_b_bbgftj', 'en', 'No templates yet. Product codes would then be typed by hand.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_the_higher_band_replaces_them_1bppe5q', 'en', 'No — the higher band replaces them', 'Interface wording'),
  ('ui.no_trading_partners_yet_1y769s2', 'en', 'No trading partners yet.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_values_yet_skhbsw', 'en', 'No values yet.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_warehouse_tasks_outstanding_c5sspn', 'en', 'No warehouse tasks outstanding.', 'Interface wording'),
  ('ui.no_waves_have_been_opened_6zyvcp', 'en', 'No waves have been opened.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.no_works_orders_raised_a9e2pb', 'en', 'No works orders raised.', 'Interface wording'),
  ('ui.no_works_orders_to_profile_10tyfnv', 'en', 'No works orders to profile.', 'Interface wording'),
  ('ui.nobody_has_been_assigned_to_a_department_d29528', 'en', 'Nobody has been assigned to a department yet.', 'Interface wording'),
  ('ui.nobody_is_covering_for_anybody_2im3y8', 'en', 'Nobody is covering for anybody.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.nobody_needs_chasing_1gxk0e4', 'en', 'Nobody needs chasing.', 'Interface wording'),
  ('ui.non_conformance_1bh5c4c', 'en', 'Non-conformance', 'Interface wording'),
  ('ui.non_conformance_complaint_deviation_and_1e6qy3m', 'en', 'Non-conformance, complaint, deviation and their investigations.', 'Interface wording'),
  ('ui.not_applied_d8p1dj', 'en', 'not applied', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.not_set_1ntesau', 'en', 'Not set', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.note_5mau71', 'en', 'Note', 'Interface wording'),
  ('ui.nothing_1fa2s7g', 'en', 'Nothing.', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.nothing_depends_on_it_1h0hbpv', 'en', 'Nothing depends on it.', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.nothing_expires_in_the_next_thirty_days_1wsn2se', 'en', 'Nothing expires in the next thirty days.', 'Interface wording'),
  ('ui.nothing_has_been_routed_yet_1qbvul', 'en', 'Nothing has been routed yet.', 'Interface wording'),
  ('ui.nothing_is_old_enough_to_provide_against_1jy0mw6', 'en', 'Nothing is old enough to provide against.', 'Interface wording'),
  ('ui.nothing_outstanding_10jrbj0', 'en', 'Nothing outstanding.', 'Interface wording'),
  ('ui.nothing_outstanding_to_profile_46fhi4', 'en', 'Nothing outstanding to profile.', 'Interface wording'),
  ('ui.nothing_posted_yet_3cykmb', 'en', 'Nothing posted yet.', 'Interface wording'),
  ('ui.nothing_received_awaiting_an_invoice_1hm1u1b', 'en', 'Nothing received awaiting an invoice.', 'Interface wording'),
  ('ui.nothing_to_value_yet_78oile', 'en', 'Nothing to value yet.', 'Interface wording'),
  ('ui.number_r616tc', 'en', 'Number', 'Interface wording'),
  ('ui.object_1roz17e', 'en', 'Object', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.object_type_cvafji', 'en', 'Object type', 'Interface wording'),
  ('ui.observed_value_gidnio', 'en', 'Observed value', 'Interface wording'),
  ('ui.of_ordered_quantity_1qt6teq', 'en', 'of ordered quantity', 'Interface wording'),
  ('ui.of_part_5_measured_1hix7yu', 'en', 'of Part 5, measured', 'Interface wording'),
  ('ui.of_record_1kzipzh', 'en', 'Of record', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.off_1bicsne', 'en', 'off', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.on_hand_1taudc1', 'en', 'On hand', 'Interface wording'),
  ('ui.on_qvtz3k', 'en', 'On', 'Interface wording'),
  ('ui.on_qyxx3k', 'en', 'on', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.on_time_1s3ekg9', 'en', 'On time', 'Interface wording'),
  ('ui.on_time_in_full_last_ninety_days_iiq8f', 'en', 'On time in full, last ninety days.', 'Interface wording'),
  ('ui.on_time_in_full_ninety_days_ii51tx', 'en', 'on time in full, ninety days', 'Interface wording'),
  ('ui.on_time_in_full_over_the_last_ninety_day_1f7mz6y', 'en', 'On time, in full, over the last ninety days.', 'Interface wording'),
  ('ui.one_published_policy_nothing_under_ninet_128k3g9', 'en', 'One published policy: nothing under ninety days, a quarter to six months, half to a year, all of it beyond.', 'Interface wording'),
  ('ui.only_for_1i94aao', 'en', 'Only for', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.open_1mnbg09', 'en', 'open', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.open_a_period_close_hey0jz', 'en', 'Open a period close', 'Interface wording'),
  ('ui.open_events_m3mhzy', 'en', 'Open events', 'Interface wording'),
  ('ui.open_exceptions_b02v39', 'en', 'Open exceptions', 'Interface wording'),
  ('ui.open_n6hn1l', 'en', 'Open', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.open_periods_v9wuyr', 'en', 'Open periods', 'Interface wording'),
  ('ui.open_shipments_1oax0vi', 'en', 'Open shipments', 'Interface wording'),
  ('ui.open_works_orders_1a58wus', 'en', 'Open works orders', 'Interface wording'),
  ('ui.opened_45zdhc', 'en', 'Opened', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.operation_9b62sm', 'en', 'Operation', 'Interface wording'),
  ('ui.order_6wrg3b', 'en', 'Order', 'Interface wording'),
  ('ui.order_line_1t8rdcn', 'en', 'Order line', 'Interface wording'),
  ('ui.order_type_2l6lwd', 'en', 'Order type', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.ordered_6krmuu', 'en', 'Ordered', 'Interface wording'),
  ('ui.ordered_less_completed_120do1a', 'en', 'ordered less completed', 'Interface wording'),
  ('ui.organisation_and_approval_routing_1vlf3aj', 'en', 'Organisation and approval routing', 'Interface wording'),
  ('ui.otif_by_customer_1634l1e', 'en', 'OTIF by customer', 'Interface wording'),
  ('ui.otif_nel955', 'en', 'OTIF', 'Interface wording'),
  ('ui.otif_qg3fje', 'en', 'OTIF %', 'Interface wording'),
  ('ui.outbound_gateway_health_and_the_queue_th_1m7yihd', 'en', 'Outbound gateway health and the queue that needs a decision.', 'Interface wording'),
  ('ui.outcome_spdxv', 'en', 'Outcome', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.outstanding_all_customers_8w0scz', 'en', 'outstanding, all customers', 'Interface wording'),
  ('ui.overdue_1qrzhgr', 'en', 'Overdue', 'Interface wording'),
  ('ui.overdue_60_1obswj0', 'en', 'Overdue 60+', 'Interface wording'),
  ('ui.parallel_1lj298y', 'en', 'Parallel', 'Interface wording'),
  ('ui.parent_1hn7qql', 'en', 'Parent', 'Interface wording'),
  ('ui.part_5_of_the_foundation_specification_m_1w4o6yg', 'en', 'Part 5 of the foundation specification, measured against the database.', 'Interface wording'),
  ('ui.part_5_section_by_section_measured_again_1yqjprh', 'en', 'Part 5, section by section, measured against the database.', 'Interface wording'),
  ('ui.partner_class_m1zenh', 'en', 'Partner class', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.party_data_quality_gejo2c', 'en', 'Business partner data quality', 'Interface wording'),
  ('ui.party_e2ekhj', 'en', 'Business partner', 'Interface wording'),
  ('ui.past_sixty_days_xp8kyp', 'en', 'past sixty days', 'Interface wording'),
  ('ui.payment_date_u4445z', 'en', 'Payment date', 'Interface wording'),
  ('ui.payment_run_16k46dg', 'en', 'Payment run', 'Interface wording'),
  ('ui.people_10i543y', 'en', 'People', 'Interface wording'),
  ('ui.period_11hwh7o', 'en', 'Period', 'Interface wording'),
  ('ui.periods_5ym48l', 'en', 'Periods', 'Interface wording'),
  ('ui.periods_ahead_18zrop0', 'en', 'Periods ahead', 'Interface wording'),
  ('ui.permissions_11gikqr', 'en', 'Permissions', 'Interface wording'),
  ('ui.person_1i84mn4', 'en', 'Person', 'Interface wording'),
  ('ui.pick_a_wave_to_see_its_lines_1xqbiar', 'en', 'Pick a wave to see its lines.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.plan_8icj76', 'en', 'Plan', 'Interface wording'),
  ('ui.plan_a_shipment_mxt5i5', 'en', 'Plan a shipment', 'Interface wording'),
  ('ui.planned_against_actual_materials_and_tim_19ozzs7', 'en', 'Planned against actual materials and time, once it has run.', 'Interface wording'),
  ('ui.planned_and_despatched_loads_1g8lvs', 'en', 'Planned and despatched loads.', 'Interface wording'),
  ('ui.planned_despatch_1v64ok1', 'en', 'Planned despatch', 'Interface wording'),
  ('ui.planned_finish_16ylwfs', 'en', 'Planned finish', 'Interface wording'),
  ('ui.planned_orders_1vyogau', 'en', 'Planned orders', 'Interface wording'),
  ('ui.planned_orders_and_the_exceptions_worth_vnc387', 'en', 'Planned orders and the exceptions worth acting on before they become shortages.', 'Interface wording'),
  ('ui.planned_quantity_1ba4s9q', 'en', 'Planned quantity', 'Interface wording'),
  ('ui.planning_1vvl51g', 'en', 'Planning', 'Interface wording'),
  ('ui.planning_exceptions_1n5k8a', 'en', 'Planning exceptions', 'Interface wording'),
  ('ui.post_a_count_nkomm3', 'en', 'Post a count', 'Interface wording'),
  ('ui.posting_class_nbqshh', 'en', 'Accounting code', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.posting_classes_1my1l15', 'en', 'Accounting codes', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.prepare_the_change_1nws68t', 'en', 'Prepare the change', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.present_1m3e00c', 'en', 'Present', 'Interface wording'),
  ('ui.presets_1sgjqd3', 'en', 'Presets', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.preventive_action_5nohqh', 'en', 'Preventive action', 'Interface wording'),
  ('ui.primary_1jcui61', 'en', 'Primary', 'Interface wording'),
  ('ui.primary_department_1ipjo5', 'en', 'Primary department', 'Interface wording'),
  ('ui.principals_roles_and_the_grants_between_1kg59m2', 'en', 'Users, roles, and the grants between them.', 'Interface wording'),
  ('ui.print_the_wave_1pn4oy8', 'en', 'Print the wave', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.printed_1g0l31l', 'en', 'Printed', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.printing_1hl0a3k', 'en', 'Printing', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.printing_blocked_vwgytk', 'en', 'Printing blocked', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.printing_not_gated_85vpg0', 'en', 'Printing not gated', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.printing_readiness_1obu4ig', 'en', 'Printing readiness', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.procurement_hchox1', 'en', 'Procurement', 'Interface wording'),
  ('ui.production_128dyd6', 'en', 'Production', 'Interface wording'),
  ('ui.products_business_partners_and_sites_are_1mhyc5v', 'en', 'Products, business partners and sites are named by code, so a file written elsewhere still loads here.', 'Terminology §2. Hard-coded in a component before this, so nothing could rename it.'),
  ('ui.programme_code_7u4gke', 'en', 'Programme code', 'Interface wording'),
  ('ui.programme_dfvy9h', 'en', 'Programme', 'Interface wording'),
  ('ui.propose_a_payment_run_697atd', 'en', 'Propose a payment run', 'Interface wording'),
  ('ui.proposed_master_data_changes_and_the_app_1wrpqab', 'en', 'Proposed master data changes and the approvals on them.', 'Interface wording'),
  ('ui.proposed_supply_with_the_date_it_has_to_1lroeid', 'en', 'Proposed supply, with the date it has to be released to land on time.', 'Interface wording'),
  ('ui.provision_1kiwnzz', 'en', 'Provision %', 'Interface wording'),
  ('ui.provision_minor_184rr34', 'en', 'Provision (minor)', 'Interface wording'),
  ('ui.purchase_order_1ql78xq', 'en', 'Purchase order', 'Interface wording'),
  ('ui.putaway_and_replenishment_raised_from_th_1tcd1i0', 'en', 'Putaway and replenishment, raised from the balances and waiting on a truck.', 'Interface wording'),
  ('ui.qualified_suppliers_25hymk', 'en', 'Qualified suppliers', 'Interface wording'),
  ('ui.quality_and_recall_e13p1o', 'en', 'Quality and recall', 'Interface wording'),
  ('ui.quality_events_orhq3r', 'en', 'Quality events', 'Interface wording'),
  ('ui.quantity_by_age_band_1nwb30l', 'en', 'Quantity by age band.', 'Interface wording'),
  ('ui.quantity_c75rso', 'en', 'Quantity', 'Interface wording'),
  ('ui.quantity_in_progress_aouk06', 'en', 'Quantity in progress', 'Interface wording'),
  ('ui.quantity_recovered_1mu3n4t', 'en', 'Quantity recovered', 'Interface wording'),
  ('ui.quantity_to_split_1xbp209', 'en', 'Quantity to split', 'Interface wording'),
  ('ui.quarantine_1v7h4kx', 'en', 'Quarantine', 'Interface wording'),
  ('ui.quotations_orders_and_deliveries_sq24mc', 'en', 'Quotations, orders and deliveries.', 'Interface wording'),
  ('ui.raise_a_quality_event_59kwvt', 'en', 'Raise a quality event', 'Interface wording'),
  ('ui.raise_a_recall_162xe3p', 'en', 'Raise a recall', 'Interface wording'),
  ('ui.raise_a_works_order_dgzcu6', 'en', 'Raise a works order', 'Interface wording'),
  ('ui.raise_count_tasks_1gqlpua', 'en', 'Raise count tasks', 'Interface wording'),
  ('ui.raise_putaway_tasks_mpfbfm', 'en', 'Raise putaway tasks', 'Interface wording'),
  ('ui.raise_replenishment_tasks_s1xbpz', 'en', 'Raise replenishment tasks', 'Interface wording'),
  ('ui.raised_by_the_counting_programme_and_wai_zir5mt', 'en', 'Raised by the counting programme and waiting on a person.', 'Interface wording'),
  ('ui.rank_cfd5qf', 'en', 'Rank', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.rate_vfzsxs', 'en', 'Rate %', 'Interface wording'),
  ('ui.re_approval_tolerance_1a6m45d', 'en', 'Re-approval tolerance (%)', 'Interface wording'),
  ('ui.re_run_1ex4nj4', 'en', 'Re-run', 'Interface wording'),
  ('ui.readiness_1nqh57j', 'en', 'Readiness', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.ready_to_print_m3wedy', 'en', 'Ready to print', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.reason_i36sl5', 'en', 'Reason', 'Interface wording'),
  ('ui.reason_recorded_with_the_switch_18nmfb', 'en', 'Reason (recorded with the switch)', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.recall_198tz9s', 'en', 'Recall', 'Interface wording'),
  ('ui.recall_evidence_rbknhx', 'en', 'Recall evidence', 'Interface wording'),
  ('ui.recall_readiness_330go8', 'en', 'Recall readiness', 'Interface wording'),
  ('ui.recalls_o5t66x', 'en', 'Recalls', 'Interface wording'),
  ('ui.receipt_7ncw6b', 'en', 'Receipt', 'Interface wording'),
  ('ui.receivables_1mmwuwk', 'en', 'Receivables', 'Interface wording'),
  ('ui.receivables_ageing_11gal89', 'en', 'Receivables ageing', 'Interface wording'),
  ('ui.receive_output_129rx67', 'en', 'Receive output', 'Interface wording'),
  ('ui.received_against_a_purchase_order_still_1yapb4v', 'en', 'Received against a purchase order, still awaiting an invoice.', 'Interface wording'),
  ('ui.record_186wx64', 'en', 'Record', 'Interface wording'),
  ('ui.record_a_count_fr7ua4', 'en', 'Record a count', 'Interface wording'),
  ('ui.record_an_inspection_result_15345fg', 'en', 'Record an inspection result', 'Interface wording'),
  ('ui.record_proof_of_delivery_tnct0l', 'en', 'Record proof of delivery', 'Interface wording'),
  ('ui.recorded_against_the_action_in_the_audit_12qzev2', 'en', 'Recorded against the action in the audit trail.', 'Interface wording'),
  ('ui.records_with_errors_1vusizi', 'en', 'Records with errors', 'Interface wording'),
  ('ui.redistribution_suggestions_5ob1mz', 'en', 'Redistribution suggestions', 'Interface wording'),
  ('ui.reference_1c7vrcq', 'en', 'Reference', 'Interface wording'),
  ('ui.regenerate_planned_orders_and_exceptions_1i22v2f', 'en', 'Regenerate planned orders and exceptions for one site.', 'Interface wording'),
  ('ui.reject_1kej36u', 'en', 'Reject', 'Interface wording'),
  ('ui.rejected_1we72vb', 'en', 'rejected', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.release_a_batch_18wxepx', 'en', 'Release a batch', 'Interface wording'),
  ('ui.release_a_works_order_tkbpx3', 'en', 'Release a works order', 'Interface wording'),
  ('ui.release_areas_xkwtxg', 'en', 'Marshalling areas', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.release_despite_shortages_125v9ig', 'en', 'Release despite shortages', 'Interface wording'),
  ('ui.reopen_a_period_usvkjs', 'en', 'Reopen a period', 'Interface wording'),
  ('ui.repackaging_jnhn5n', 'en', 'Repackaging', 'Interface wording'),
  ('ui.replaced_ij6x39', 'en', 'Replaced', 'Interface wording'),
  ('ui.replaces_the_department_bands_1ub03oj', 'en', 'Replaces the department bands', 'Interface wording'),
  ('ui.replenishment_raised_by_this_wave_fjx0ph', 'en', 'Replenishment raised by this wave', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.reporting_u7u0ct', 'en', 'Reporting', 'Interface wording'),
  ('ui.reports_wwt148', 'en', 'Reports', 'Interface wording'),
  ('ui.requester_uhx31h', 'en', 'Requester', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.required_by_cuhrnx', 'en', 'Required by', 'Interface wording'),
  ('ui.requisition_juyien', 'en', 'Requisition', 'Interface wording'),
  ('ui.requisitions_purchase_orders_and_goods_r_rhnwjq', 'en', 'Requisitions, purchase orders and goods receipts.', 'Interface wording'),
  ('ui.resolved_by_9y0nu', 'en', 'Resolved by', 'Interface wording'),
  ('ui.retire_a_band_8mu098', 'en', 'Retire a band', 'Interface wording'),
  ('ui.rework_2idq4d', 'en', 'Rework', 'Interface wording'),
  ('ui.root_cause_fpi7nq', 'en', 'Root cause', 'Interface wording'),
  ('ui.routing_decisions_taken_1kwesed', 'en', 'Routing decisions taken', 'Interface wording'),
  ('ui.row_1a833mj', 'en', 'Row', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.row_s_read_1w95fkz', 'en', 'row(s) read', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.rule_version_1teo9df', 'en', 'Rule version', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.run_a_forecast_1cni6m', 'en', 'Run a forecast', 'Interface wording'),
  ('ui.run_planning_ea718v', 'en', 'Run planning', 'Interface wording'),
  ('ui.sales_czo7yv', 'en', 'Sales', 'Interface wording'),
  ('ui.sales_order_ct8ubr', 'en', 'Sales order', 'Interface wording'),
  ('ui.scheduled_jobs_zroc08', 'en', 'Scheduled jobs', 'Interface wording'),
  ('ui.scope_clock_and_progress_the_deadline_is_h1ow0p', 'en', 'Scope, clock and progress. The deadline is a configured regulatory clock.', 'Interface wording'),
  ('ui.score_x9tsfp', 'en', 'Score', 'Interface wording'),
  ('ui.scrapped_17zcikn', 'en', 'Scrapped', 'Interface wording'),
  ('ui.secondary_75qooh', 'en', 'Secondary', 'Interface wording'),
  ('ui.section_cms19o', 'en', 'Section', 'Interface wording'),
  ('ui.segments_1va4m27', 'en', 'Segments', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.select_a_carrier_vdt7ra', 'en', 'Select a carrier', 'Interface wording'),
  ('ui.sell_1pquyhx', 'en', 'Sell', 'Interface wording'),
  ('ui.sequential_e9khv2', 'en', 'Sequential', 'Interface wording'),
  ('ui.service_1eklb0k', 'en', 'Service', 'Interface wording'),
  ('ui.service_code_lca13d', 'en', 'Service code', 'Interface wording'),
  ('ui.settle_8pdu3e', 'en', 'Settle', 'Interface wording'),
  ('ui.severity_v7rniq', 'en', 'Severity', 'Interface wording'),
  ('ui.shipments_10iuxtc', 'en', 'Shipments', 'Interface wording'),
  ('ui.shipments_carrier_bookings_and_delivery_6kek0m', 'en', 'Shipments, carrier bookings and delivery performance, with cost landing on stock.', 'Interface wording'),
  ('ui.short_1fn8tsl', 'en', 'short', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.short_line_s_e19rcn', 'en', 'short line(s)', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.short_qll2lx', 'en', 'Short', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.sign_off_a_forecast_1544ytf', 'en', 'Sign off a forecast', 'Interface wording'),
  ('ui.signature_1hcolxp', 'en', 'Signature', 'Interface wording'),
  ('ui.signed_by_13bof56', 'en', 'Signed by', 'Interface wording'),
  ('ui.site_1fo419q', 'en', 'Site', 'Interface wording'),
  ('ui.sits_in_front_of_the_department_bands_1i1qj14', 'en', 'Sits in front of the department bands', 'Interface wording'),
  ('ui.slow_moving_stock_provision_1ktters', 'en', 'Slow-moving stock provision', 'Interface wording'),
  ('ui.source_r5qyuw', 'en', 'Source', 'Interface wording'),
  ('ui.specification_coverage_8r5h0c', 'en', 'Specification coverage', 'Interface wording'),
  ('ui.specificity_16aatyn', 'en', 'Specificity', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.split_6a1ocj', 'en', 'Split', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.split_a_batch_g6fkls', 'en', 'Split a batch', 'Interface wording'),
  ('ui.stage_cscafh', 'en', 'Stage', 'Interface wording'),
  ('ui.staged_batches_preview_validation_load_a_us16s9', 'en', 'Staged batches, preview, validation, load and rollback.', 'Interface wording'),
  ('ui.state_8awmmu', 'en', 'State', 'Interface wording'),
  ('ui.status_3pd73', 'en', 'Status', 'Interface wording'),
  ('ui.step_jtn9kf', 'en', 'Step', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.stock_ageing_faregq', 'en', 'Stock ageing', 'Interface wording'),
  ('ui.stock_health_fttdwp', 'en', 'Stock health', 'Interface wording'),
  ('ui.stock_health_valuation_ageing_expiry_and_vlxbkk', 'en', 'Stock health, valuation, ageing, expiry and counting, all derived from the ledger.', 'Interface wording'),
  ('ui.stock_lines_xgmx2y', 'en', 'Stock lines', 'Interface wording'),
  ('ui.stock_value_5f5i1w', 'en', 'Stock value', 'Interface wording'),
  ('ui.subject_18ix78v', 'en', 'Subject', 'Interface wording'),
  ('ui.subject_identifier_1ygalee', 'en', 'Subject identifier', 'Interface wording'),
  ('ui.supplier_1d8252h', 'en', 'Supplier', 'Interface wording'),
  ('ui.supplier_invoice_1iuhv6q', 'en', 'Supplier invoice', 'Interface wording'),
  ('ui.supplier_lot_1uv55y6', 'en', 'Supplier lot', 'Interface wording'),
  ('ui.supplier_qualification_1moyq5o', 'en', 'Supplier qualification', 'Interface wording'),
  ('ui.suppliers_by_item_3m5mf6', 'en', 'Suppliers by product', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.supply_and_demand_x8savm', 'en', 'Supply and demand', 'Interface wording'),
  ('ui.switch_off_o9908w', 'en', 'Switch off', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.switch_on_32mr26', 'en', 'Switch on', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.tax_5yw72y', 'en', 'Tax', 'Interface wording'),
  ('ui.tax_report_ungblo', 'en', 'Tax report', 'Interface wording'),
  ('ui.temperature_excursion_impact_g8a4fl', 'en', 'Temperature excursion impact', 'Interface wording'),
  ('ui.template_s6qa0b', 'en', 'Template', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.tenant_lifecycle_gxp8sh', 'en', 'Organisation lifecycle', 'Interface wording'),
  ('ui.terminology_42eio4', 'en', 'Terminology', 'Interface wording'),
  ('ui.the_books_this_tenant_keeps_jzwzm6', 'en', 'The books this organisation keeps.', 'Interface wording'),
  ('ui.the_chain_as_it_was_resolved_with_the_ru_l7jw04', 'en', 'The chain as it was resolved, with the rule and version that chose each approver.', 'Interface wording'),
  ('ui.the_database_authorises_every_one_of_the_qsiltm', 'en', 'The database authorises every one of these; you only see the ones you hold.', 'Interface wording'),
  ('ui.the_fiscal_calendar_and_where_it_is_open_pxr907', 'en', 'The financial calendar and where it is open.', 'Interface wording'),
  ('ui.the_full_register_including_closed_order_afvyiq', 'en', 'The full register, including closed orders.', 'Interface wording'),
  ('ui.the_items_and_parties_every_document_dep_1o86pt1', 'en', 'The products and business partners every document depends on.', 'Interface wording'),
  ('ui.the_manufacturing_record_for_one_works_o_xc3v4f', 'en', 'The manufacturing record for one works order, as issued.', 'Interface wording'),
  ('ui.the_permitted_answers_and_the_abbreviati_w0bdvh', 'en', 'The permitted answers, and the abbreviation each contributes to a code.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.the_primary_department_in_force_when_a_r_14vt19x', 'en', 'The primary department in force when a request is raised is the one that routes it.', 'Interface wording'),
  ('ui.the_product_list_is_this_organisation_s_1fqhoqz', 'en', 'The product list is this organisation''s own; an empty one means no products have been created yet.', 'Terminology §2. Hard-coded in a component before this, so nothing could rename it.'),
  ('ui.the_projected_balance_for_one_item_and_s_wru6sj', 'en', 'The projected balance for one product and site across the horizon.', 'Interface wording'),
  ('ui.the_register_as_at_today_170rvl5', 'en', 'The register as at today.', 'Interface wording'),
  ('ui.the_structural_checks_the_build_runs_on_8bw5n5', 'en', 'The structural checks the build runs on every push.', 'Interface wording'),
  ('ui.the_trace_and_the_actions_logged_against_1fbrs4', 'en', 'The trace and the actions logged against one recall.', 'Interface wording'),
  ('ui.the_wording_of_every_label_per_tenant_bvbpd', 'en', 'The wording of every label, per organisation.', 'Interface wording'),
  ('ui.this_pack_cannot_be_applied_as_it_stands_1ux9amj', 'en', 'This pack cannot be applied as it stands', 'Screen wording on features and content, keyed by its own source text.'),
  ('ui.three_letter_code_1lbznpv', 'en', 'Three-letter code.', 'Interface wording'),
  ('ui.title_a7vsmh', 'en', 'Title', 'Interface wording'),
  ('ui.to_iaukp0', 'en', 'To', 'Interface wording'),
  ('ui.top_the_pick_faces_up_from_reserve_where_7zwsnm', 'en', 'Top the pick faces up from reserve where demand exceeds what is there.', 'Interface wording'),
  ('ui.total_1c0as9p', 'en', 'Total', 'Interface wording'),
  ('ui.traceable_units_with_their_genealogy_anc_pksgpo', 'en', 'Traceable units, with their genealogy anchors.', 'Interface wording'),
  ('ui.tracking_1gupqxo', 'en', 'Tracking', 'Interface wording'),
  ('ui.trading_partners_and_their_posting_class_1x2av6a', 'en', 'Trading partners and their accounting code', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.transaction_type_a0x64x', 'en', 'Transaction type', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.trial_balance_7g09e7', 'en', 'Trial balance', 'Interface wording'),
  ('ui.trial_balance_periods_receivables_tax_an_1mdz0o8', 'en', 'Trial balance, periods, receivables, tax and assets, read from the posted ledger.', 'Interface wording'),
  ('ui.turn_a_counted_task_into_a_stock_adjustm_j88qmg', 'en', 'Turn a counted task into a stock adjustment.', 'Interface wording'),
  ('ui.type_1m2zofh', 'en', 'Type', 'Interface wording'),
  ('ui.unacknowledged_9k3b1u', 'en', 'Unacknowledged', 'Interface wording'),
  ('ui.unanswered_axis_1h71o82', 'en', 'Unanswered axis', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.units_1jsp02k', 'en', 'units', 'Interface wording'),
  ('ui.until_rg2a5r', 'en', 'Until', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.up_to_911ajt', 'en', 'Up to', 'Interface wording'),
  ('ui.user_1qbyk9e', 'en', 'User', 'Terminology §2. Hard-coded in a component before this, so nothing could rename it.'),
  ('ui.vacancy_1ktrxxy', 'en', 'Vacancy', 'Interface wording'),
  ('ui.valid_from_plzsdb', 'en', 'Valid from', 'Interface wording'),
  ('ui.valid_to_1jp7ipa', 'en', 'Valid to', 'Interface wording'),
  ('ui.valuation_2f8gf4', 'en', 'Valuation', 'Interface wording'),
  ('ui.value_1m2g8kq', 'en', 'Value', 'Interface wording'),
  ('ui.value_bands_11oa4uq', 'en', 'Value bands', 'Interface wording'),
  ('ui.value_bands_and_named_assignments_resolu_1jdoows', 'en', 'Value bands and named assignments. Resolution runs named assignment first, then the department''s bands.', 'Interface wording'),
  ('ui.value_minor_1km2akm', 'en', 'Value (minor)', 'Interface wording'),
  ('ui.values_137f3h7', 'en', 'Values', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.variance_v89wim', 'en', 'Variance', 'Interface wording'),
  ('ui.version_q0zd4n', 'en', 'Version', 'Interface wording'),
  ('ui.versioned_amending_a_template_never_rewr_1qqz8bv', 'en', 'Versioned. Amending a template never rewrites codes already assigned.', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.waiver_reason_w1jobr', 'en', 'Waiver reason', 'Interface wording'),
  ('ui.wanted_idfnym', 'en', 'Wanted', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.warehouse_tasks_74rl6m', 'en', 'Warehouse tasks', 'Interface wording'),
  ('ui.warnings_1j8s2pg', 'en', 'Warnings', 'Interface wording'),
  ('ui.wave_cddyic', 'en', 'Wave', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.wave_lines_143ex13', 'en', 'Wave lines', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.waves_1f5tpqd', 'en', 'Waves', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.what_can_still_be_committed_for_one_item_arlzxw', 'en', 'What can still be committed for one product at one site, on a date.', 'Interface wording'),
  ('ui.what_each_entity_owes_another_before_eli_4oo7pk', 'en', 'What each company owes another, before elimination.', 'Interface wording'),
  ('ui.what_is_being_raised_against_quality_1d63ggy', 'en', 'What is being raised against quality.', 'Interface wording'),
  ('ui.what_is_outstanding_and_for_how_long_130jjyf', 'en', 'What is outstanding, and for how long.', 'Interface wording'),
  ('ui.what_is_running_what_failed_and_what_has_1csg81s', 'en', 'What is running, what failed, and what has stopped running.', 'Interface wording'),
  ('ui.what_posts_differently_betkha', 'en', 'What posts differently', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.what_stock_was_standing_in_a_place_betwe_urvpup', 'en', 'What stock was standing in a place between two times, so an excursion can be scoped.', 'Interface wording'),
  ('ui.what_the_engine_would_set_for_one_item_a_5r7tyd', 'en', 'What the engine would set for one product and site, before adopting it.', 'Interface wording'),
  ('ui.what_the_last_planning_run_could_not_rec_9k3teu', 'en', 'What the last planning run could not reconcile.', 'Interface wording'),
  ('ui.when_l5nax', 'en', 'When', 'Interface wording'),
  ('ui.when_nobody_resolves_8bdom1', 'en', 'When nobody resolves', 'Interface wording'),
  ('ui.where_slow_stock_at_one_site_would_sell_snld4q', 'en', 'Where slow stock at one site would sell at another.', 'Interface wording'),
  ('ui.where_the_plan_is_inconsistent_1nffuh1', 'en', 'Where the plan is inconsistent.', 'Interface wording'),
  ('ui.where_the_shop_floor_currently_sits_1l1tt9s', 'en', 'Where the shop floor currently sits.', 'Interface wording'),
  ('ui.whether_one_works_order_can_be_released_v8aww1', 'en', 'Whether one works order can be released against what is on hand.', 'Interface wording'),
  ('ui.whether_the_trace_for_a_recall_can_be_pr_swgvuh', 'en', 'Whether the trace for a recall can be produced inside the regulatory clock.', 'Interface wording'),
  ('ui.who_did_what_to_which_object_and_when_fi_1xgp1du', 'en', 'Who did what, to which object, and when — filterable by action, object, actor and date.', 'Interface wording'),
  ('ui.who_is_approved_to_supply_what_and_until_38mm79', 'en', 'Who is approved to supply what, and until when.', 'Interface wording'),
  ('ui.who_would_approve_this_ieeqgq', 'en', 'Who would approve this?', 'Interface wording'),
  ('ui.why_y9m5zt', 'en', 'Why', 'Screen wording, keyed by its own source text so a tenant can rename it.'),
  ('ui.within_tolerance_stfdr5', 'en', 'Within tolerance', 'Interface wording'),
  ('ui.work_1oz7yps', 'en', 'Work', 'Interface wording'),
  ('ui.working_1hfa4bu', 'en', 'Working…', 'Interface wording'),
  ('ui.works_order_1snyhil', 'en', 'Works order', 'Interface wording'),
  ('ui.works_order_register_8vkgca', 'en', 'Works order register', 'Interface wording'),
  ('ui.works_order_variance_h2fss8', 'en', 'Works order variance', 'Interface wording'),
  ('ui.works_orders_and_their_progress_against_4rbnhr', 'en', 'Works orders and their progress against plan, quantity by quantity.', 'Interface wording'),
  ('ui.works_orders_by_status_15dy2r3', 'en', 'Works orders by status', 'Interface wording'),
  ('ui.works_orders_hxo7ay', 'en', 'Works orders', 'Interface wording'),
  ('ui.write_off_stock_1abuv7r', 'en', 'Write off stock', 'Interface wording'),
  ('ui.year_5xgri4', 'en', 'Year', 'Interface wording'),
  ('ui.yes_1dudzcg', 'en', 'Yes', 'Interface wording'),
  ('ui.yes_lower_approvers_still_act_1qoa7pt', 'en', 'Yes — lower approvers still act', 'Interface wording'),
  ('audit.blurb', 'en-US', 'Every recorded action in this organization: who did what, to which object, and when.', ''),
  ('event.tenant.key_created', 'en-US', 'Organization key created', ''),
  ('event.tenant.key_destroyed', 'en-US', 'Organization key destroyed', ''),
  ('event.tenant.key_rotated', 'en-US', 'Organization key rotated', ''),
  ('glossary.batch', 'en-US', 'Lot', ''),
  ('glossary.despatch', 'en-US', 'Dispatch', ''),
  ('glossary.goods_in', 'en-US', 'Receiving', ''),
  ('glossary.goods_out', 'en-US', 'Shipping', ''),
  ('glossary.nominal_account', 'en-US', 'General ledger account', ''),
  ('glossary.organisation', 'en-US', 'Organization', ''),
  ('glossary.purchase_ledger', 'en-US', 'Accounts payable', ''),
  ('glossary.sales_ledger', 'en-US', 'Accounts receivable', ''),
  ('glossary.stock', 'en-US', 'Inventory', ''),
  ('glossary.stocktake', 'en-US', 'Physical inventory', ''),
  ('glossary.supplier', 'en-US', 'Vendor', ''),
  ('glossary.works_order', 'en-US', 'Work order', ''),
  ('module.inventory', 'en-US', 'Inventory and warehousing', ''),
  ('module.tenant_lifecycle', 'en-US', 'Organization lifecycle', ''),
  ('nav.tenant', 'en-US', 'Organization lifecycle', ''),
  ('nav.tenant_settings', 'en-US', 'Organization settings', ''),
  ('permission.inventory.write_off', 'en-US', 'Write off inventory', ''),
  ('permission.logistics.despatch', 'en-US', 'Confirm dispatch', ''),
  ('permission.sales.despatch', 'en-US', 'Dispatch orders', ''),
  ('ui.companies_ohmslk', 'en-US', 'Entities', ''),
  ('ui.company_1hra0d8', 'en-US', 'Entity', ''),
  ('ui.content_packs_4rf0hw', 'en-US', 'Content packs', ''),
  ('ui.no_stock_positions_yet_nothing_has_moved_1fukkx8', 'en-US', 'No inventory positions yet — nothing has moved into this organization.', ''),
  ('ui.tenant_lifecycle_gxp8sh', 'en-US', 'Organization lifecycle', ''),
  ('ui.the_books_this_tenant_keeps_jzwzm6', 'en-US', 'The books this organization keeps.', ''),
  ('ui.the_wording_of_every_label_per_tenant_bvbpd', 'en-US', 'The wording of every label, per organization.', '')
on conflict (key, locale) do update set
  value = excluded.value,
  description = nullif(excluded.description, '');

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
