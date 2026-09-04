-- ─────────────────────────────────────────────────────────────────────────────
-- Notification routes that can exist.
--
-- Found by the production-readiness pass, Phase 9, chasing what looked like a
-- small thing: the integration backlog produces a report and never raises an
-- alert, so somebody has to remember to go and look. Following that back found
-- the reason, and it is not about the backlog.
--
-- §9.2 has three links. A template says what the product would say. A route
-- says who is told, on what event, through which channel. An event says the
-- thing happened. Measured across the base pack and every organisation built
-- from it:
--
--   notification templates the base pack ships           15
--   notification routes it can ship                       0
--   routes on northgate / meridian / caldera        0 / 0 / 0
--   notifications ever raised, in any organisation        0
--
-- Zero routes is not an oversight in the pack's content. erp.notification_route
-- had no branch in erp.apply_change_set_item and no row in
-- erp_meta.promotable_surface, so it was neither promotable nor
-- pack-installable: there was no mechanism by which a route could be shipped,
-- and the only way to get one was an administrator calling
-- erp_upsert_notification_route by hand, one route at a time, for a table whose
-- codes are not published anywhere. erp.route_notifications() runs, walks the
-- events, finds no route, and returns zero — correctly, and for ever.
--
-- That is the missing mechanism and this migration adds it: the promoter
-- branch, the surface registration, and the live-config guard that comes with
-- it.
--
-- Then the chain is proven end to end rather than declared fixed, on the three
-- conditions the product already computes and already runs a job for:
--
--   erp.fail_job_run              -> job.failed
--   erp.escalate_overdue_approvals -> approval.escalated   (already registered)
--   erp.alert_integration_backlog  -> integration.backlog_above_threshold
--
-- each with the base-pack template that was already waiting for it, and a route
-- that carries it to a role. erp_test.notification_chain_suite raises one and
-- watches a notification arrive.
--
-- Wiring the third of those found one more thing on the way, small and exactly
-- the same shape. erp.job carries parameters, erp.upsert_job() validates them
-- against the handler's parameter_schema, and erp.run_due_jobs() called every
-- handler with no arguments at all — so a threshold typed into a job was
-- checked and then discarded. No handler had declared a parameter yet, so
-- nothing was visibly wrong; the backlog alert would have been the first, and
-- would have quietly used its own default instead of the number somebody
-- entered. Handlers that want their job's parameters now take a single jsonb
-- and are given them, and erp.scheduler_integrity_report() refuses a handler
-- that declares properties it cannot be handed.
--
-- What this does NOT fix, and is reported rather than hidden: the other twelve
-- templates — receipt_discrepancy, match_exception, stock_shortage_on_release,
-- count_variance_above_tolerance, deviation_raised, quality_event_raised,
-- batch_released, expiry_threshold_breached, period_close_task_overdue,
-- order_intake_rejected, approval_requested, approval_overdue — name conditions
-- no part of the product raises an event for. Wiring those is domain work in
-- twelve modules, not a repair. erp.notification_chain_report() lists them, so
-- the gap is on a screen instead of in nobody's head, and
-- erp.assert_notification_routes_resolvable() stops a route being shipped that
-- names a template or an event type that does not exist.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The promoter learns the kind ─────────────────────────────────────────────

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

    -- §9.2. A notification template says what the product would tell somebody;
    -- a route says who is told and when. Fifteen templates shipped in the base
    -- pack and no route could ever be shipped with them, because this branch
    -- did not exist and notification_route was not a pack-installable kind. So
    -- erp.route_notifications() matched nothing, on every organisation, always.
    when 'notification_route' then
      if i.operation = 'remove' then
        update erp.notification_route nr set status = 'inactive', updated_at = now()
         where nr.tenant_id = v_tenant and nr.code = (p ->> 'code');
      else
        perform erp.upsert_notification_route(
          p ->> 'code', p ->> 'name', p ->> 'event_pattern',
          coalesce(p ->> 'severity', 'medium')::erp.notification_severity,
          coalesce(p ->> 'audience_kind', 'role'),
          p ->> 'role_code', p ->> 'department_code',
          nullif(p ->> 'app_user_id', '')::uuid,
          coalesce(p ->> 'channel_kind', 'in_app')::erp.notification_channel_kind,
          p ->> 'template_code',
          (p ->> 'digest_minutes')::integer,
          (p ->> 'escalate_after_minutes')::integer,
          p ->> 'escalate_to_role_code',
          coalesce((p ->> 'is_mandatory')::boolean, false));
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
              hint = 'Promotable kinds: config, terminology, legislation_binding, event_subscription, role, rule_set, state_machine, approval_chain, posting_rule, data_quality_rule, field_approval_rule, costing_policy, count_programme, receipt_tolerance, match_tolerance, budget, planning_policy, pricing_policy, inspection_plan, carrier, close_task, dunning_policy, department, approval_band, approver_assignment, posting_class, account_determination, classification_axis, classification_value, code_template, release_area, capability, uom, reason_code, calendar, sod_rule, numbering_rule, notification_template, notification_route, kpi, report, account, location, job';
  end case;
end;$function$

;

-- ── The surface, registered and guarded ──────────────────────────────────────

insert into erp_meta.promotable_surface (schema_name, table_name, object_kind, rationale)
values ('erp', 'notification_route', 'notification_route',
        '§9.2. Who is told, on what event, through which channel. The template '
        'says what the product would say; without a route it says it to nobody.')
on conflict (schema_name, table_name) do update set
  object_kind = excluded.object_kind, rationale = excluded.rationale;

-- Registering a surface is not guarding it. The generator is what puts the
-- live-config trigger on the table, so a route on a live organisation has to
-- travel through a change set like every other configuration surface.
select erp.apply_live_config_guards();

-- ── The three conditions the product already computes ────────────────────────

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description,
   payload_schema, is_current)
values
  ('job.failed', 1, 'job', 'administration', 'event.job.failed',
   'A scheduled job ran and did not succeed. Raised on the run that exhausts '
   'the job''s attempts, not on every retry, so a flapping dependency does not '
   'become its own outage.',
   '{"type": "object"}'::jsonb, true),
  -- erp_ref.is_past_tense() polices these, and rightly: an event is a thing
  -- that happened. "above_threshold" is a state, so the event is named for the
  -- crossing, and the base pack's integration_backlog_above_threshold template
  -- is what it renders through.
  ('integration.backlog_exceeded', 1, 'external_system', 'administration',
   'event.integration.backlog_exceeded',
   'The number of commands and inbound messages needing a person crossed the '
   'threshold the job was given. erp.integration_backlog() has always been able '
   'to say so; nothing asked it.',
   '{"type": "object"}'::jsonb, true)
on conflict (code, version) do update set
  aggregate_type = excluded.aggregate_type, module_code = excluded.module_code,
  name_key = excluded.name_key, description = excluded.description,
  payload_schema = excluded.payload_schema, is_current = excluded.is_current;

-- ── A job that alerts rather than a report nobody reads ──────────────────────

create or replace function erp.alert_integration_backlog(p_params jsonb default '{}'::jsonb)
returns integer
language plpgsql
set search_path to ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_threshold integer := coalesce((p_params ->> 'threshold')::integer, 10);
  v_count     integer;
  v_sys       uuid;
begin
  -- One jsonb argument, because that is how a handler receives the parameters
  -- its job carries. erp.run_due_jobs() called every handler with no arguments
  -- at all until 20260904930000, so a threshold typed into a job was validated
  -- and then thrown away.
  if v_threshold is null or v_threshold < 1 then
    raise exception
      'ERPWARE_THRESHOLD_INVALID: a backlog threshold is a count of one or more'
      using errcode = '22023',
      hint = 'Set it on the job''s parameters as {"threshold": 25}.';
  end if;

  select count(*) into v_count from erp.integration_backlog(10000);

  if v_count < v_threshold then
    return 0;
  end if;

  -- The event is about the queue, so it hangs off the system with the most
  -- behind it — that is the one somebody has to look at first.
  select c.external_system_id into v_sys
    from erp.command c
   where c.tenant_id = v_tenant and c.status in ('dead', 'pending_approval', 'failed')
   group by c.external_system_id
   order by count(*) desc
   limit 1;

  perform erp.append_event(
    'integration.backlog_exceeded', 'external_system',
    coalesce(v_sys, v_tenant),
    jsonb_build_object('backlog', v_count, 'threshold', v_threshold));

  return v_count;
end;
$$;

revoke all on function erp.alert_integration_backlog(jsonb) from public, anon;

comment on function erp.alert_integration_backlog(jsonb) is
  '§9.2. Raises integration.backlog_exceeded when the queue crosses the '
  'threshold the job was given. erp.integration_backlog() reports the same '
  'backlog and waits to be asked; this is the half that tells somebody.';

insert into erp_ref.job_handler
  (code, name_key, description, module_code, parameter_schema,
   default_timeout_seconds, forbids_overlap, is_current, sql_function)
values
  ('integration.backlog_alert', 'job_handler.integration_backlog_alert.name',
   'Raises an event when the integration backlog crosses its threshold.',
   'administration',
   '{"type": "object", "additionalProperties": false,
     "properties": {"threshold": {"type": "integer", "minimum": 1}}}'::jsonb,
   120, true, true, 'alert_integration_backlog')
on conflict (code) do update set
  name_key = excluded.name_key, description = excluded.description,
  module_code = excluded.module_code, parameter_schema = excluded.parameter_schema,
  default_timeout_seconds = excluded.default_timeout_seconds,
  forbids_overlap = excluded.forbids_overlap, is_current = excluded.is_current,
  sql_function = excluded.sql_function;

-- ── The job runner raises the event its template was waiting for ────────────

CREATE OR REPLACE FUNCTION erp.fail_job_run(p_run_id bigint, p_error text, p_summary jsonb DEFAULT '{}'::jsonb, p_retryable boolean DEFAULT true)
 RETURNS erp.job_run_outcome
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        erp.job_run%rowtype;
  j        erp.job%rowtype;
  v_fails  integer;
begin
  select * into r from erp.job_run
   where tenant_id = v_tenant and id = p_run_id for update;

  if not found or r.outcome <> 'running' then
    raise exception
      'ERPWARE_JOB_RUN_NOT_RUNNING: % was not claimed, or has already finished',
      p_run_id
      using errcode = '23514';
  end if;

  select * into j from erp.job where id = r.job_id;

  update erp.job_run
     set outcome = 'failed', finished_at = now(), lease_expires_at = null,
         error = p_error, summary = coalesce(p_summary, '{}'::jsonb)
   where id = p_run_id;

  v_fails := j.consecutive_failures + 1;

  update erp.job
     set consecutive_failures = v_fails,
         -- Out of attempts: stop the retry cadence and put the job back on its
         -- ordinary schedule, but raise the flag. A job hammering a broken
         -- dependency every minute is its own outage.
         is_failing = (v_fails >= j.max_attempts),
         next_run_at = case
           when j.schedule_kind = 'manual' then null
           when not p_retryable or v_fails >= j.max_attempts
             then erp.compute_next_run(
                    j.schedule_kind, j.interval_seconds, j.at_time,
                    j.days_of_week, j.day_of_month, j.timezone, now())
           else now() + make_interval(
                  secs => least(j.retry_backoff_seconds * power(2, v_fails - 1),
                                3600))
         end
   where id = j.id;

  -- §9.2. The base pack has shipped a job_failed template since it was
  -- written, and nothing ever raised the event it renders. Raised on the run
  -- that exhausts the attempts rather than on every retry: a job flapping
  -- against a broken dependency every minute would otherwise become its own
  -- outage, in somebody's inbox.
  if v_fails >= j.max_attempts then
    perform erp.append_event(
      'job.failed', 'job', j.id,
      jsonb_build_object('job_code', j.code, 'handler', j.handler_code,
                         'consecutive_failures', v_fails,
                         'error', left(coalesce(p_error, ''), 500)));
  end if;

  return 'failed';
end;
$function$

;

-- ── And the escalation job raises the event it has always had a template for ─

CREATE OR REPLACE FUNCTION erp.escalate_overdue_approvals()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        record;
  v_count  integer := 0;
begin
  for t in
    select tk.*, s.escalate_to_role_id, s.escalate_to_user_id, s.escalate_after
      from erp.approval_task tk
      join erp.approval_step s on s.id = tk.approval_step_id
     where tk.tenant_id = v_tenant
       and tk.status = 'pending'
       and tk.due_at is not null
       and tk.due_at <= now()
       and (s.escalate_to_role_id is not null or s.escalate_to_user_id is not null)
  loop
    update erp.approval_task
       set status = 'escalated', decided_at = now(), updated_at = now(),
           comment = 'escalated after ageing past its due time'
     where id = t.id;

    if t.escalate_to_user_id is not null then
      insert into erp.approval_task (
        tenant_id, approval_request_id, approval_step_id, step_code, seq,
        assignee_user_id, escalated_from, due_at)
      values (v_tenant, t.approval_request_id, t.approval_step_id, t.step_code, t.seq,
              t.escalate_to_user_id, t.id, now() + coalesce(t.escalate_after, interval '1 day'));
      v_count := v_count + 1;
    else
      insert into erp.approval_task (
        tenant_id, approval_request_id, approval_step_id, step_code, seq,
        assignee_user_id, assignee_role_id, escalated_from, due_at)
      select v_tenant, t.approval_request_id, t.approval_step_id, t.step_code, t.seq,
             ur.app_user_id, t.escalate_to_role_id, t.id,
             now() + coalesce(t.escalate_after, interval '1 day')
        from erp.user_role ur
       where ur.tenant_id = v_tenant
         and ur.role_id = t.escalate_to_role_id
         and ur.valid_from <= current_date
         and (ur.valid_to is null or ur.valid_to >= current_date);
      v_count := v_count + 1;
    end if;
    -- §9.2. approval.escalated has been in erp_ref.event_type since the event
    -- register was written, and the base pack has shipped an approval_escalated
    -- template to render it. Nothing raised it, so the route had nothing to
    -- match and the template rendered nothing.
    perform erp.append_event(
      'approval.escalated', 'approval', t.approval_request_id,
      jsonb_build_object('task_id', t.id, 'step_code', t.step_code,
                         'due_at', t.due_at,
                         'escalated_to_role', t.escalate_to_role_id,
                         'escalated_to_user', t.escalate_to_user_id));
  end loop;

  return v_count;
end;
$function$

;

-- ── The routes the base pack can now carry ───────────────────────────────────
--
-- Three, for the three conditions above. Each names a template the pack already
-- ships and a role the pack already creates, so a newly provisioned
-- organisation is told about a failing job, an escalated approval and a backlog
-- without anybody configuring anything.
--
-- Mandatory, because these are the ones a preference must not switch off
-- entirely: §15.6 turns a suppressed channel into in-app rather than into
-- silence, and a job that has stopped running is not a matter of taste.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, operation, requires_capability,
   is_decision, decision_prompt, provenance, seq)
values
  ('base', 'notification_route', 'job_failed',
   jsonb_build_object(
     'code', 'job_failed', 'name', 'A scheduled job has stopped',
     'event_pattern', 'job.failed', 'severity', 'high',
     'audience_kind', 'role', 'role_code', 'administrator',
     'channel_kind', 'email', 'template_code', 'job_failed',
     'is_mandatory', true),
   'upsert', null, false, null,
   'Starter Content Packs §9.2. The template shipped without a route; nothing '
   'was ever told a job had stopped.', 6210),

  ('base', 'notification_route', 'approval_escalated',
   jsonb_build_object(
     'code', 'approval_escalated', 'name', 'An approval has been escalated',
     'event_pattern', 'approval.escalated', 'severity', 'medium',
     'audience_kind', 'object_owner',
     'channel_kind', 'email', 'template_code', 'approval_escalated',
     'is_mandatory', false),
   'upsert', null, false, null,
   'Starter Content Packs §9.2. Goes to whoever raised the thing waiting on '
   'approval, which is who is blocked by it.', 6211),

  ('base', 'notification_route', 'integration_backlog_above_threshold',
   jsonb_build_object(
     'code', 'integration_backlog_above_threshold',
     'name', 'The integration backlog needs somebody',
     'event_pattern', 'integration.backlog_exceeded', 'severity', 'high',
     'audience_kind', 'role', 'role_code', 'integration',
     'channel_kind', 'email',
     'template_code', 'integration_backlog_above_threshold',
     'digest_minutes', 60, 'is_mandatory', true),
   'upsert', null, false, null,
   'Starter Content Packs §9.2. Digested hourly: a backlog that crosses the '
   'threshold every run should be one message, not sixty.', 6212)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, operation = excluded.operation,
  provenance = excluded.provenance, seq = excluded.seq;

-- And the job that raises the third, shipped disabled like every other job the
-- pack carries — §9.1: "Shipped disabled, enabled per tenant."
insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, operation, requires_capability,
   is_decision, decision_prompt, provenance, seq)
values
  ('base', 'job', 'integration_backlog_alert',
   jsonb_build_object(
     'code', 'integration_backlog_alert',
     'name', 'Integration backlog alert',
     'handler_code', 'integration.backlog_alert',
     'schedule_kind', 'interval', 'interval_seconds', 900,
     'parameters', jsonb_build_object('threshold', 25),
     'max_silence_seconds', 7200,
     'is_enabled', false),
   'upsert', null, false, null,
   'Starter Content Packs §9.1 and §9.2. The half of the backlog surface that '
   'tells somebody rather than waiting to be asked.', 6213)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, operation = excluded.operation,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── What the chain does and does not reach ───────────────────────────────────

create or replace function erp.notification_chain_report()
returns table (template_code text, finding text, detail text)
language sql
stable
set search_path to ''
as $$
  -- A template with no route says nothing to anybody. A route naming a
  -- template that does not exist renders nothing. A route waiting on an event
  -- type the product does not register waits for ever. All three are the same
  -- fault seen from different ends, so they are reported together.
  select pi.object_key, 'no route carries this template',
         'the base pack ships it and nothing routes it, so it renders to nobody'
    from erp_ref.pack_item pi
   where pi.object_kind = 'notification_template'
     and not exists (
       select 1 from erp_ref.pack_item r
        where r.object_kind = 'notification_route'
          and r.payload ->> 'template_code' = pi.object_key)

  union all

  select r.payload ->> 'template_code', 'the route names a template no pack ships',
         'route ' || r.object_key
    from erp_ref.pack_item r
   where r.object_kind = 'notification_route'
     and not exists (
       select 1 from erp_ref.pack_item t
        where t.object_kind = 'notification_template'
          and t.object_key = r.payload ->> 'template_code')

  union all

  select r.payload ->> 'template_code', 'the route waits on an unregistered event type',
         'route ' || r.object_key || ' waits on ' || (r.payload ->> 'event_pattern')
    from erp_ref.pack_item r
   where r.object_kind = 'notification_route'
     and not exists (
       select 1 from erp_ref.event_type e
        where e.is_current and r.payload ->> 'event_pattern' like e.code)

  order by 2, 1
$$;

revoke all on function erp.notification_chain_report() from public, anon;

create or replace function erp.assert_notification_routes_resolvable()
returns text
language plpgsql
stable
set search_path to ''
as $$
declare v_broken int; v_unrouted int; v_detail text;
begin
  -- A route that cannot work is a build failure. A template with no route is a
  -- gap, and twelve of them are open by design as this is written: the
  -- conditions they name are not raised anywhere in the product, and wiring
  -- them is domain work in twelve modules rather than a repair. So the two are
  -- counted apart, and only the first stops a build.
  select count(*) filter (where r.finding <> 'no route carries this template'),
         count(*) filter (where r.finding =  'no route carries this template'),
         string_agg(format('  %s — %s (%s)', r.template_code, r.finding, r.detail), E'\n')
           filter (where r.finding <> 'no route carries this template')
    into v_broken, v_unrouted, v_detail
    from erp.notification_chain_report() r;

  if v_broken > 0 then
    raise exception E'ERPWARE_NOTIFICATION_ROUTE_UNRESOLVABLE: % route(s) cannot work\n%',
      v_broken, v_detail
      using errcode = '23503',
      hint = 'A route names its template by code and waits on an event type in '
             'erp_ref.event_type. Ship both, or ship neither.';
  end if;

  return format('notification chain: every shipped route resolves; %s template(s) still carried by no route',
                v_unrouted);
end;
$$;

revoke all on function erp.assert_notification_routes_resolvable() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('notification_routes_resolvable', 'Notification routes reach something',
   'assertion', 'platform', 'erp', 'assert_notification_routes_resolvable', '',
   'notification_chain_report', '',
   'A route names a template and waits on an event type. Both must exist, or '
   'the organisation is told nothing and nothing says so.', true,
   (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;


-- ── And the manifest can capture one back out ────────────────────────────────

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

    -- §9.2. The promoter can apply a route and, until this, the manifest could
    -- not see one: a route could be promoted into an environment and never
    -- captured out of it, so a snapshot of a configured organisation silently
    -- omitted who gets told about what. Codes rather than ids, like every other
    -- kind here, so a manifest travels between environments.
    select 'notification_route',
           nr.code,
           jsonb_build_object(
             'code', nr.code,
             'name', nr.name,
             'event_pattern', nr.event_pattern,
             'severity', nr.severity,
             'audience_kind', nr.audience_kind,
             'role_code', (select ro.code from erp.role ro
                            where ro.tenant_id = nr.tenant_id and ro.id = nr.role_id),
             'department_code', (select d.code from erp.department d
                                  where d.tenant_id = nr.tenant_id and d.id = nr.department_id),
             'app_user_id', nr.app_user_id,
             'channel_kind', nr.channel_kind,
             'template_code', nr.template_code,
             'digest_minutes', nr.digest_minutes,
             'escalate_after_minutes', nr.escalate_after_minutes,
             'escalate_to_role_code', (select ro.code from erp.role ro
                                        where ro.tenant_id = nr.tenant_id
                                          and ro.id = nr.escalate_to_role_id),
             'is_mandatory', nr.is_mandatory)
      from t
      join erp.notification_route nr on nr.tenant_id = t.tenant_id
     where nr.status = 'active'

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

select erp.assert_notification_routes_resolvable();
select erp.assert_diagnostics_registered();
select erp.assert_configuration_promotable();
select erp.assert_scheduler_integrity();
select erp.assert_public_api_safe();

-- ── And a job's parameters reach the handler that declared them ─────────────

-- erp.alert_integration_backlog took an integer for the length of one
-- migration. Two overloads differing only in argument type make
-- erp.run_due_jobs()'s dynamic call ambiguous — "function is not unique" — so
-- the earlier shape goes rather than sitting beside the new one.
drop function if exists erp.alert_integration_backlog(integer);

CREATE OR REPLACE FUNCTION erp.run_due_jobs(p_batch_size integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant   uuid := erp.require_tenant_id();
  r          erp.job_run%rowtype;
  j          erp.job%rowtype;
  h          erp_ref.job_handler%rowtype;
  v_result   jsonb;
  v_claimed  integer := 0;
  v_ok       integer := 0;
  v_failed   integer := 0;
  v_worker   integer := 0;
  v_detail   jsonb := '[]'::jsonb;
begin
  for r in select * from erp.claim_job_runs('database', greatest(p_batch_size, 1)) loop
    v_claimed := v_claimed + 1;

    select * into j from erp.job where tenant_id = v_tenant and id = r.job_id;
    select * into h from erp_ref.job_handler where code = j.handler_code;

    if h.sql_function is null then
      -- Named, implemented, and not implementable here. Failing it without a
      -- retry is the honest answer: retrying will not make SQL able to make an
      -- HTTP request, and counting it as done would be a lie in the report.
      perform erp.fail_job_run(
        r.id,
        format('%s needs the worker: it makes an outbound call, which SQL cannot',
               j.handler_code),
        '{}'::jsonb, false);
      v_worker := v_worker + 1;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'job', j.code, 'outcome', 'needs the worker'));
      continue;
    end if;

    begin
      -- Uniform whatever the handler returns: a scalar comes back as a
      -- one-element array, a set as an array of rows.
      -- A job carries parameters, erp.upsert_job() validates them against the
      -- handler's parameter_schema, and until this they went no further: every
      -- handler was called with no arguments at all, so a threshold or a window
      -- typed into a job was checked and then discarded. Nothing had declared
      -- a parameter yet, so nothing was visibly wrong — the first handler to
      -- declare one would have quietly used its own default instead.
      --
      -- The convention is one argument: a handler that wants its job's
      -- parameters takes a single jsonb and is given them; one that does not is
      -- called as before. erp.scheduler_integrity_report() refuses a handler
      -- that declares properties and cannot accept them.
      if exists (
        select 1 from pg_catalog.pg_proc pp
          join pg_catalog.pg_namespace pn on pn.oid = pp.pronamespace
         where pn.nspname = 'erp' and pp.proname = h.sql_function
           and pp.pronargs = 1
           and pp.proargtypes[0] = 'jsonb'::regtype)
      then
        execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from erp.%I($1) t',
                       h.sql_function)
          into v_result
         using coalesce(j.parameters, '{}'::jsonb);
      else
        execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from erp.%I() t',
                       h.sql_function)
          into v_result;
      end if;
      perform erp.complete_job_run(r.id, jsonb_build_object('result', v_result));
      v_ok := v_ok + 1;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'job', j.code, 'outcome', 'ok', 'result', v_result));
    exception when others then
      perform erp.fail_job_run(r.id, sqlerrm);
      v_failed := v_failed + 1;
      v_detail := v_detail || jsonb_build_array(jsonb_build_object(
        'job', j.code, 'outcome', 'failed', 'error', left(sqlerrm, 200)));
    end;
  end loop;

  return jsonb_build_object(
    'claimed', v_claimed, 'succeeded', v_ok, 'failed', v_failed,
    'needs_worker', v_worker, 'runs', v_detail);
end;
$function$

;

CREATE OR REPLACE FUNCTION erp.scheduler_integrity_report()
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- Refusal 1, checked rather than trusted: every schedule kind the enum
  -- offers must be one erp.compute_next_run() can actually compute. A kind
  -- added to the type without a branch is a schedule that silently never fires.
  select 'a schedule kind has no implementation in erp.compute_next_run()',
         e.enumlabel,
         'a job configured with it would look scheduled and never run'
    from pg_catalog.pg_enum e
    join pg_catalog.pg_type t on t.oid = e.enumtypid
   where t.typname = 'job_schedule_kind'
     and t.typnamespace = 'erp'::regnamespace
     and position('''' || e.enumlabel || '''' in
                  (select p.prosrc from pg_catalog.pg_proc p
                    where p.pronamespace = 'erp'::regnamespace
                      and p.proname = 'compute_next_run')) = 0
  union all
  select 'erp.job_run has no guard against editing a finished run', 'erp.job_run',
         'run evidence could be revised after the fact'
   where not exists (
     select 1 from pg_catalog.pg_trigger tg
      where tg.tgrelid = 'erp.job_run'::regclass and not tg.tgisinternal
        and tg.tgfoid = 'erp.guard_finished_job_run()'::regprocedure)
  union all
  select 'erp.job has no schedule-maintenance trigger', 'erp.job',
         'next_run_at would be whatever a caller happened to write'
   where not exists (
     select 1 from pg_catalog.pg_trigger tg
      where tg.tgrelid = 'erp.job'::regclass and not tg.tgisinternal
        and tg.tgfoid = 'erp.maintain_job_schedule()'::regprocedure)
  union all
  -- Data: an enabled scheduled job with nowhere to go.
  select 'an enabled job has no next run', j.code,
         'it is enabled and scheduled but will never be claimed'
    from erp.job j
   where j.is_enabled and j.schedule_kind <> 'manual' and j.next_run_at is null
  union all
  -- Data: a run in flight far beyond any plausible lease.
  select 'a job run has been in flight for over a day', r.id::text,
         format('claimed by %s', coalesce(r.worker, 'unknown'))
    from erp.job_run r
   where r.outcome = 'running' and r.started_at < now() - interval '1 day'
  union all
  -- Schema: a handler that declares parameters and cannot be given them.
  -- erp.run_due_jobs() passes a job's parameters to a handler that takes one
  -- jsonb argument, and calls the rest with none. A handler that declares
  -- properties in its parameter_schema and does not accept that argument gets
  -- its parameters validated on the way in and silently dropped on the way
  -- out — which is how a threshold typed into a job becomes the function's own
  -- default without anybody being told.
  select 'a job handler declares parameters it cannot be given', h.code,
         'erp.' || h.sql_function || '() takes no jsonb argument, so '
           || 'erp.run_due_jobs() calls it with nothing'
    from erp_ref.job_handler h
   where h.is_current and h.sql_function is not null
     and h.parameter_schema -> 'properties' is not null
     and h.parameter_schema -> 'properties' <> '{}'::jsonb
     and not exists (
       select 1 from pg_catalog.pg_proc pp
         join pg_catalog.pg_namespace pn on pn.oid = pp.pronamespace
        where pn.nspname = 'erp' and pp.proname = h.sql_function
          and pp.pronargs = 1 and pp.proargtypes[0] = 'jsonb'::regtype)
$function$

;

select erp.assert_scheduler_integrity();

-- ── The chain, walked end to end ─────────────────────────────────────────────
--
-- Every part of §9.2 had a passing test before this and the chain had never
-- carried a single notification, because each test checked its own link. So
-- this one starts at the condition and ends at somebody's inbox, and fails if
-- any link in between is missing.

create or replace function erp_test.notification_chain_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  r        record;
  v_tenant uuid;
  v_admin  uuid := gen_random_uuid();
  v_admin2 uuid := gen_random_uuid();
  v_user2  uuid;
  v_cs     uuid;
  v_job    uuid;
  v_run    bigint;
  v_n      int;
  v_cases  int := 0;
  it       record;
begin
  select * into r from erp.provision_tenant(
    'zzchain', 'Chain Suite', 'admin@zzchain.test', 'Chain Suite Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email)
  values (v_admin, 'admin@zzchain.test'), (v_admin2, 'second@zzchain.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- Whoever raises a change set may not wave it through, so the suite needs
  -- somebody else to be.
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name,
                            email, user_locale)
  values (v_tenant, v_admin2, 'person', 'active', 'Chain Suite Second',
          'second@zzchain.test', 'en')
  returning id into v_user2;

  insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
  select v_tenant, v_user2, ro.id, 'the suite needs a second approver'
    from erp.role ro
   where ro.tenant_id = v_tenant and ro.code = 'administrator' and ro.status = 'active';

  -- ── The pack can carry a route at all ─────────────────────────────────────
  -- Planned rather than promoted: the base pack asks an organisation nine
  -- policy questions before it will install, and none of them is what this
  -- suite is about. What matters here is that routes appear in the plan, which
  -- they could not before notification_route was a kind.

  v_cases := v_cases + 1;
  select count(*) into v_n from erp.plan_content_pack('base') p
   where p.object_kind = 'notification_route';
  return query select 'the base pack can carry a notification route'::text,
    v_n >= 3,
    format('%s route(s) in the plan — it was structurally zero until the '
           'promoter learned the kind', v_n);

  -- ── And the promoter installs one ─────────────────────────────────────────
  -- Just the job_failed pair, promoted on its own: the template it renders
  -- through and the route that carries it.

  v_cs := erp.create_change_set('zzchain-routes', 'Chain suite routes',
                                'The job_failed template and the route that carries it', null);
  for it in
    select p.object_kind, p.object_key, p.payload
      from erp.plan_content_pack('base') p
     where (p.object_kind = 'notification_route' and p.object_key = 'job_failed')
        or (p.object_kind = 'notification_template' and p.object_key = 'job_failed')
     order by case p.object_kind when 'notification_template' then 1 else 2 end
  loop
    perform erp.add_change_set_item(v_cs, it.object_kind, it.object_key, it.payload,
                                    'upsert'::erp.change_operation, current_date,
                                    'the chain suite, walking §9.2 end to end');
  end loop;

  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin2, 'role', 'authenticated')::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  v_cases := v_cases + 1;
  return query select 'promoting one installs it'::text,
    exists (select 1 from erp.notification_route nr
             where nr.tenant_id = v_tenant and nr.code = 'job_failed'
               and nr.status = 'active'),
    'the promoter branch this migration adds, doing the thing it was added for';

  v_cases := v_cases + 1;
  return query select 'and it names the template that renders it'::text,
    exists (select 1 from erp.notification_route nr
              join erp.notification_template nt
                on nt.tenant_id = nr.tenant_id and nt.code = nr.template_code
             where nr.tenant_id = v_tenant and nr.code = 'job_failed'),
    'a route naming a template nobody ships renders nothing';

  -- ── A job that runs out of attempts ───────────────────────────────────────

  perform erp.upsert_job('zzfail', 'Failing job', 'platform.report_silent_jobs',
                         'interval', 3600, null, null, null, 'UTC', '{}'::jsonb,
                         null, null, true);
  select j.id into v_job from erp.job j where j.tenant_id = v_tenant and j.code = 'zzfail';
  update erp.job set max_attempts = 1, next_run_at = now() where id = v_job;

  v_cases := v_cases + 1;
  begin
    select cr.id into v_run
      from erp.claim_job_runs('chain-suite', 1, interval '5 minutes') cr limit 1;
    perform erp.fail_job_run(v_run, 'the dependency this job needs is not answering',
                             '{}'::jsonb, true);
    return query select 'a job that runs out of attempts raises an event'::text,
      exists (select 1 from erp.event e
               where e.tenant_id = v_tenant and e.event_type = 'job.failed'),
      'the base pack has shipped a job_failed template all along and nothing '
      'ever raised the event it renders';
  exception when others then
    return query select 'a job that runs out of attempts raises an event'::text,
      false, left(sqlerrm, 90);
  end;

  v_cases := v_cases + 1;
  perform erp.route_notifications();
  select count(*) into v_n from erp.notification n where n.tenant_id = v_tenant;
  return query select 'and somebody is actually told'::text,
    v_n > 0,
    format('%s notification(s) — this is the number that was zero on every '
           'organisation ever built from this pack', v_n);

  v_cases := v_cases + 1;
  return query select 'the notification reaches an administrator, not nobody'::text,
    exists (select 1 from erp.notification n
              join erp.app_user u on u.tenant_id = n.tenant_id and u.id = n.app_user_id
             where n.tenant_id = v_tenant and u.email like '%@zzchain.test'),
    'the route says role administrator and this organisation has two';

  -- ── The backlog half ──────────────────────────────────────────────────────

  -- Through the scheduler, not by calling the handler directly: what was broken
  -- was the delivery of a job's parameters, and a direct call is exactly the
  -- test that cannot see it.
  --
  -- The parameter is a threshold of nought, which the handler refuses by name.
  -- Its own default is ten, which it would accept — so a run that SUCCEEDS is a
  -- run that never received the number, and the case can tell the two apart.
  -- Asserting on the returned count could not: with an empty queue the handler
  -- answers nought whether the threshold is one or ten, which is how the first
  -- draft of this case passed against plumbing that was demonstrably broken.
  v_cases := v_cases + 1;
  perform erp.upsert_job('zzbacklog', 'Backlog alert', 'integration.backlog_alert',
                         'interval', 900, null, null, null, 'UTC',
                         '{"threshold": 0}'::jsonb, null, null, true);
  update erp.job set next_run_at = now()
   where tenant_id = v_tenant and code = 'zzbacklog';
  perform erp.run_due_jobs(10);
  return query select 'a job''s parameters reach the handler that declared them'::text,
    exists (select 1 from erp.job_run jr
              join erp.job jb on jb.tenant_id = jr.tenant_id and jb.id = jr.job_id
             where jr.tenant_id = v_tenant and jb.code = 'zzbacklog'
               and jr.outcome = 'failed'
               and jr.error like '%ERPWARE_THRESHOLD_INVALID%'),
    'the job says nought and the handler''s default is ten: refusing is the '
    'only outcome that proves the number arrived';

  v_cases := v_cases + 1;
  return query select 'an empty queue raises nothing'::text,
    erp.alert_integration_backlog('{"threshold": 1}'::jsonb) = 0,
    'an alert on a queue with nothing in it is this fault inverted';

  v_cases := v_cases + 1;
  begin
    perform erp.alert_integration_backlog('{"threshold": 0}'::jsonb);
    return query select 'a threshold of zero is refused'::text, false,
      'an alert that always fires is not a threshold';
  exception when others then
    return query select 'a threshold of zero is refused'::text,
      sqlerrm like 'ERPWARE_THRESHOLD_INVALID%', left(sqlerrm, 70);
  end;

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp_meta.platform_audit where tenant_id = v_tenant;
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (v_admin, v_admin2);

  v_cases := v_cases + 1;
  return query select 'the suite leaves nothing behind'::text,
    not exists (select 1 from erp.tenant t where t.code = 'zzchain'),
    'and the notifications went with the organisation, being tenant-scoped';

  if v_cases <> 10 then
    raise exception 'ERPWARE_SUITE_SHRANK: notification_chain_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.notification_chain_suite() from public, anon;

create or replace function erp_test.assert_notification_chain_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _nc on commit drop as
    select * from erp_test.notification_chain_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail from _nc;
  if v_fail > 0 then
    raise exception E'ERPWARE_NOTIFICATION_CHAIN_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001',
      hint = 'A link in §9.2 is missing: the condition raises no event, no '
             'route matches it, or the route reaches nobody.';
  end if;
  return format('notification chain: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_notification_chain_suite() from public, anon;

-- ── The acceptance suite counts four more items, and says why ───────────────
--
-- §13's clause: the pack's size is hardcoded so that a pack growing by
-- accident fails the build. Three routes and the job that raises the third
-- are a deliberate growth, so the number moves and the comment says what
-- moved it.

CREATE OR REPLACE FUNCTION erp_test.starter_pack_acceptance_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  a1 uuid := gen_random_uuid();   -- the author
  a2 uuid := gen_random_uuid();   -- the approver, because B6 refuses self-approval
  r         record;
  c         record;
  res       jsonb;
  v_cs      uuid;
  v_tok     text;
  v_second  uuid;
  d         record;
  i         integer := 0;
  n         integer;
  n2        integer;
  v_ok      boolean; v_msg text;
  v_ready   integer;
begin
  select * into r from erp.provision_tenant(
    'zz13', 'Acceptance', 'admin@zz13.test', 'Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zz13.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- The modules. Installing one is not "further configuration" in §13's sense
  -- — it is what gives the product a procurement flow to configure at all —
  -- and the pack presupposes them: a requisition lifecycle comes from
  -- erp.configure_procurement(), not from erp_ref.pack_item.
  perform erp.configure_finance();
  perform erp.configure_procurement(1000000);
  perform erp.configure_sales();
  perform erp.configure_inventory();
  perform erp.configure_quality();
  perform erp.configure_logistics();
  perform erp.configure_period_close();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
    perform erp.approve_change_set(c.id);
    perform erp.promote_change_set(c.id);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- Installing a module registers the reporting views it brings, whether or
  -- not its change set is promoted — a view is the product's boundary, not the
  -- organisation's behaviour. Seven modules, fourteen views.
  select count(*) into n from erp.governed_view gv where gv.tenant_id = r.tenant_id;
  return query select 'installing a module registers the reporting views it brings',
    n = (select count(*) from erp_ref.module_governed_view m
          where m.install_code in ('finance-posting', 'procurement-lifecycle',
                                   'sales-lifecycle', 'inventory-operations',
                                   'quality', 'logistics', 'period-close')),
    format('%s views registered by seven installers', n);

  -- ── §2.1's route ────────────────────────────────────────────────────────

  res := erp.apply_preset('standard');
  return query select 'a live organisation switches capabilities through a change set',
    (res ->> 'route') = 'change_set' and (res ->> 'change_set_id') is not null,
    'erp.provision_tenant() marks the self environment live immediately, so '
    'the promotable-surface guard bites from the first day — and before this '
    'there was no promotion route to take instead, which left every '
    'organisation able to read the capability catalogue and none able to '
    'change it';

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) into n from erp.tenant_capability tc
   where tc.tenant_id = r.tenant_id and tc.is_enabled and tc.valid_to is null;
  return query select 'and promoting it switches on what the preset selects',
    n = 9, format('%s capabilities on after the Standard preset', n);

  -- ── §11, applied ────────────────────────────────────────────────────────

  res := erp.apply_content_pack('base');
  v_cs := (res ->> 'change_set_id')::uuid;
  return query select 'the base pack plans only what the capabilities allow',
    -- 340. It was 322 when §13's clause 5 was written, 326 after
    -- 20260904100000 added §9.1's four remaining scheduled jobs, 342 after
    -- 20260904170000 added §9.3's sixteen output templates, and 340 now that
    -- 20260904430000 holds back the two reports — match exceptions and
    -- ageing — whose views come with modules this organisation has not yet
    -- installed, and 346 now that 20260904920000 added the three notification
    -- routes and the backlog-alert job and 20260904930000 added the
    -- support-access pair: the pack had shipped fifteen notification templates
    -- and could carry no route to any of them, because notification_route was
    -- not a kind the promoter knew. The number is
    -- hardcoded on purpose — it is what makes a pack that grows by accident
    -- fail the build — so each deliberate growth updates it and says what
    -- moved it.
    (res ->> 'items')::integer = 346
      and jsonb_array_length(res -> 'advisories') = 8,
    format('%s of %s items, %s advisories naming the capabilities and modules that held the rest back',
           res ->> 'items',
           (select count(*) from erp_ref.pack_item where pack_code = 'base'),
           jsonb_array_length(res -> 'advisories'));

  -- The two advisories that are new: each names the report, the view and the
  -- module that brings it, so the reader knows what to install.
  return query select 'a report whose view is not installed is held back and named',
    -- The advisories are the conflict strings themselves, not objects.
    exists (select 1 from jsonb_array_elements_text(res -> 'advisories') a
             where a like 'report(s) match_exceptions are held back%'
               and a like '%procurement-controls module%')
    and exists (select 1 from jsonb_array_elements_text(res -> 'advisories') a
             where a like 'report(s) ageing are held back%'
               and a like '%receivables module%'),
    '§11.7: not missing, early — the same additive rule as a capability off';

  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'a pack promoted with twelve decisions unanswered';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_DECISIONS_OUTSTANDING%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'promotion refuses while a required decision remains', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  for d in select * from erp.pack_decisions('base') where not answered loop
    i := i + 1;
    perform erp.answer_pack_decision('base', d.object_kind, d.object_key,
      jsonb_build_object('upper_bound_minor', i * 500000));
  end loop;
  return query select 'and §3.4''s twelve approval bands are all of them',
    i = 12, format('%s decisions, every one an approval threshold', i);

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'the answer lands, not the pack''s placeholder',
    (select ab.upper_bound_minor from erp.approval_band ab
      join erp.department dp on dp.id = ab.department_id
     where ab.tenant_id = r.tenant_id and dp.code = 'PROC'
       and ab.object_type = 'requisition' and ab.seq = 1) is not null,
    'a band whose threshold is still null is a chain that approves everything';

  -- The gap this migration closes: every report the pack landed carries a
  -- version in force, reading a view the organisation holds.
  select count(*), count(*) filter (where exists (
           select 1 from erp.report_version rv
            where rv.tenant_id = rp.tenant_id and rv.report_id = rp.id
              and rv.status = 'active' and rv.effective_from <= current_date
              and (rv.effective_to is null or rv.effective_to > current_date)))
    into n, n2
    from erp.report rp where rp.tenant_id = r.tenant_id;
  return query select 'every report the pack landed has a version in force',
    -- 13: eighteen, less the three whose capability the Standard preset leaves
    -- off (planning exceptions, production variance, recall despatch list)
    -- and the two whose view waits for a module (match exceptions, ageing).
    n = 13 and n2 = n,
    format('%s reports, %s with a version — the thirteen the Standard preset '
           'and seven modules allow', n, n2);

  -- ── §13's seven clauses ─────────────────────────────────────────────────

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'four of §13''s seven clauses hold after Standard and the base pack',
    v_ready = 4,
    format('%s of 7 ready with nothing configured by hand', v_ready);

  return query select 'clauses 1, 2, 4 and 7 are the four',
    (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
      where clause in (1, 2, 4, 7)),
    'requisition to invoice; determination with no suspense fallback; count '
    'and variance; period close';

  -- The two clauses §13 describes after "having chosen the Standard preset"
  -- and §2.3 puts in Full. Settled as: §13 means Full. The report says which
  -- preset each clause needs, derived from erp_ref.preset_capability, so
  -- neither document had to be rewritten and neither is quoted at the reader.
  return query select 'clause 3 needs Full, and says so rather than reading as a fault',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 3) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 3)
      = 'Container identity is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 3), 'nothing missing');

  return query select 'clause 6 needs Full for the same reason, and nothing else',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 6) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 6)
      = 'Recall management is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 6), 'nothing missing');

  -- The invariant the whole change is for: nothing a preset can switch on is
  -- ever reported as something the pack failed to provide. §13's last sentence
  -- logs a pack gap against the product, and a preset nobody chose is not one.
  return query select 'no clause blames the pack for a capability a preset carries',
    not exists (
      select 1 from erp.pack_acceptance_report(r.tenant_id) ar
       where ar.missing is not null
         and ar.missing like '%is off%'
         and ar.missing not like '%preset)%'),
    'before this, two clauses answered a reader with a paragraph about §2.3 '
    'disagreeing with §13';

  return query select 'clause 5''s gap is a site''s, not the pack''s',
    (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 5)
      = 'no marshalling area configured for any site; ',
    'a marshalling area belongs to a site, and a site is an organisation''s own '
    '— §11 lists none in a pack for the same reason';

  -- ── The Full preset closes both, which is what names the cause ──────────

  res := erp.apply_preset('full');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.apply_content_pack('base');
  return query select 're-applying the base pack plans exactly what was held back',
    -- 11, not 13: planning exceptions and production variance now wait for
    -- the planning and production modules, whose views they read.
    (res ->> 'items')::integer = 11,
    format('%s items — §11.7''s "a tenant that skipped manufacturing at '
           'onboarding can add it later, and the change set contains only what '
           'is missing"', res ->> 'items');

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'the Full preset closes clauses 3 and 6 and nothing else changes',
    v_ready = 6
      and (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
            where clause in (3, 6)),
    format('%s of 7 ready; only clause 5 remains, and it wants a site', v_ready);

  return query select 'and a third application plans nothing at all',
    (select count(*) from erp.plan_content_pack('base')) = 0,
    'additive, per §11.7';

  -- ── The last four reports arrive with the modules that bring their views ─

  perform erp.configure_receivables();
  perform erp.configure_procurement_controls();
  perform erp.configure_planning();
  perform erp.configure_production();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
    perform erp.approve_change_set(c.id);
    perform erp.promote_change_set(c.id);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.apply_content_pack('base');
  return query select 'installing the modules that bring the views plans exactly the reports held back',
    (res ->> 'items')::integer = 4
      and (select string_agg(csi.object_key, ',' order by csi.object_key)
             from erp.change_set_item csi
            where csi.change_set_id = (res ->> 'change_set_id')::uuid)
          = 'ageing,match_exceptions,planning_exceptions,production_variance',
    format('%s items: %s', res ->> 'items',
           (select string_agg(csi.object_key, ', ' order by csi.object_key)
              from erp.change_set_item csi
             where csi.change_set_id = (res ->> 'change_set_id')::uuid));

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*), count(*) filter (where (
           select count(*) from erp.report_version rv
            where rv.tenant_id = rp.tenant_id and rv.report_id = rp.id
              and rv.status = 'active' and rv.effective_from <= current_date
              and (rv.effective_to is null or rv.effective_to > current_date)) = 1)
    into n, n2
    from erp.report rp where rp.tenant_id = r.tenant_id;
  return query select 'all eighteen base reports now hold exactly one version in force',
    n = 18 and n2 = 18,
    format('%s reports, %s with exactly one version in force', n, n2);

  -- The assertion this whole change is for, asked of the organisation the
  -- suite built. Before 20260904430000 it failed here with eighteen findings.
  begin
    -- Over the organisation this suite built, not over the database. The
    -- assertion is platform-wide by design, and reading it from inside a
    -- per-organisation suite made this case pass only while nothing else
    -- existed: with a second organisation present it reported eight findings
    -- belonging entirely to that other organisation.
    if exists (select 1 from erp.report_reproducibility_report(r.tenant_id)) then
      raise exception 'ERPWARE_REPORT_NOT_REPRODUCIBLE: % finding(s)',
        (select count(*) from erp.report_reproducibility_report(r.tenant_id));
    end if;
    v_ok := true; v_msg := 'erp.report_reproducibility_report() is clean over the pack-installed reports';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  return query select 'and the organisation''s reports are reproducible', v_ok, v_msg;

  -- ── §10, over the base ──────────────────────────────────────────────────

  begin
    perform erp.apply_content_pack('outsourced_logistics');
    v_ok := false; v_msg := 'a profile pack applied with its capability off';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_CONFLICT%'
        and sqlerrm like '%third_party_custody%';
    v_msg := left(sqlerrm, 58);
  end;
  return query select 'a profile pack whose capability is off is refused by name',
    v_ok, v_msg;

  res := erp.apply_content_pack('manufacturing');
  return query select 'and one whose capability is on applies over the base',
    -- 12, not 13: erp.configure_production() above already set
    -- production.issue_method to the value the pack carries, and §11.7 plans
    -- only what is missing.
    (res ->> 'items')::integer = 12, format('%s items', res ->> 'items');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select '§10''s five works order types all land',
    (select count(*) from erp.classification_value cv
       join erp.classification_axis ca on ca.id = cv.axis_id
      where cv.tenant_id = r.tenant_id and ca.code = 'WORKS_ORDER_TYPE'
        and cv.status = 'active') = 5,
    'production, assembly, kitting, rework, repack';

  return query select '§11.6: the organisation records which packs it holds, and at which version',
    (select count(*) from erp.tenant_pack tp
      where tp.tenant_id = r.tenant_id and tp.status = 'applied') = 4
    and (select bool_and(tp.version = '1.0.0') from erp.tenant_pack tp
          where tp.tenant_id = r.tenant_id and tp.status = 'applied'),
    'base three times and manufacturing once, each with its version';

  -- ── §12, checkable rather than trusted ──────────────────────────────────

  return query select 'every pack value states where it came from',
    not exists (select 1 from erp_ref.pack_item where length(provenance) <= 20)
    and not exists (select 1 from erp_ref.content_pack where length(provenance) <= 30),
    '§12: "every value carries a provenance note naming the standard or '
    'practice it derives from, so the review is checkable rather than trusted"';

  -- Cleanup, so the next suite starts from the schema rather than from this.
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'a suite that leaves an organisation makes the next one measure this one';
end;
$function$

;

-- ── And the suite that set its routes up by hand ────────────────────────────
--
-- erp_test.output_channels_suite writes five notification routes directly on a
-- live organisation. That worked while the table was ungoverned; now that it is
-- a guarded configuration surface, the guard refuses it — correctly, and by
-- name. The suite's subject is what routing does, not how a route is installed,
-- so it sets its routes up with the bootstrap window open and closes it again
-- before the cases that need a live organisation.

CREATE OR REPLACE FUNCTION erp_test.output_channels_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  r record;
  ad uuid := gen_random_uuid(); op uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzoc-' || substr(md5(random()::text), 1, 6);
  v_second uuid; v_tok text; v_entity uuid; v_site uuid; v_admin uuid;
  res jsonb; v_ok boolean; v_msg text; v_n integer; v_id uuid; v_render uuid; v_delivery uuid;
  v_zpl203 text; v_zpl300 text; v_notif uuid;
begin
  select * into r from erp.provision_tenant(v_code, 'Output Channels', 'admin@zzoc.test', 'Channels Admin');
  v_tenant := r.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzoc.test'), (op, 'op@zzoc.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);
  v_admin := erp.current_principal_id();
  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  -- The suite's own event types, registered so the payload validator has a
  -- schema to hold them to, and removed at the end.
  insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description)
  values ('zzoc.thing_happened', 1, 'tenant', 'administration', 'event.zzoc', 'suite'),
         ('zzoc.mail_requested', 1, 'tenant', 'administration', 'event.zzoc', 'suite'),
         ('zzoc.digest_one_posted', 1, 'tenant', 'administration', 'event.zzoc', 'suite'),
         ('zzoc.digest_two_posted', 1, 'tenant', 'administration', 'event.zzoc', 'suite'),
         ('zzoc.urgent_thing_raised', 1, 'tenant', 'administration', 'event.zzoc', 'suite');

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (v_tenant, v_entity, 'DC1', 'Distribution centre', 'warehouse', 'active') returning id into v_site;
  perform erp.upsert_notification_template('tpl_inapp', 'in_app', 'notify.body.generic', 'notify.subject.generic');
  perform erp.upsert_notification_template('tpl_email', 'email', 'notify.body.generic', 'notify.subject.generic');
  -- A label template with a version that decodes, and two printers at
  -- different resolutions.
  perform erp.upsert_output_template('bin_label_test', 'output.template.bin_label', 'label', null, '100x150mm',
    '[{"kind": "title", "fields": ["document_number"]}, {"kind": "barcode", "fields": ["document_number"]}]'::jsonb);
  perform erp.upsert_output_template_version('bin_label_test', 'zpl', '{}'::jsonb, '[]'::jsonb, 'inventory.read',
    'zpl', '^XA^BCN^FD123^FS^XZ', true, '123', current_date - 1, 'test');
  perform erp.upsert_printer('LBL203', 'DC1', 'Bench label printer', 'label', 'zpl', 203, 'Bench 1', '100x150', 'tcp://10.0.0.11:9100');
  perform erp.upsert_printer('LBL300', 'DC1', 'Fine label printer', 'label', 'zpl', 300, 'Bench 2', '100x150', 'tcp://10.0.0.12:9100');
  perform erp.upsert_printer('DOC1', 'DC1', 'Office printer', 'document', 'pdf', null, 'Office', 'A4', 'ipp://10.0.0.20');
  perform erp.configure_notifications();
  perform erp_test.close_bootstrap_window(v_tenant);

  -- A second person, an operator with the administrator role too, so a role
  -- audience has two members.
  res := public.erp_invite_principal('op@zzoc.test', 'Channel Operator');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'suite');
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.claim_invitation(v_tok);
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);

  return query select 'installing notification services is a change set carrying the two jobs',
    (select count(*) from erp.job j where j.tenant_id = v_tenant
      and j.handler_code in ('notifications.route_events', 'notifications.dispatch')) = 2,
    'routed and dispatched every two minutes';

  -- ── §15.6 routing to an audience ──────────────────────────────────────────
  --
  -- notification_route became a guarded live-config surface in 20260904920000,
  -- so a live organisation changes one through a change set like every other
  -- configuration. This suite is about what routing DOES once a route exists —
  -- audiences, preferences, digests, escalation — and erp_test.notification_
  -- chain_suite is what proves a route can be installed at all. So the routes
  -- below are set up with the window open, and the window closes again before
  -- the cases that need a live organisation.
  perform erp_test.reopen_bootstrap_window(v_tenant);

  begin
    perform erp.upsert_notification_route('bad', 'Bad', 'stock.%', 'medium', 'role', 'administrator', null, null, 'email', 'tpl_inapp');
    v_ok := false; v_msg := 'a route named a template of another channel';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_NOTIFICATION_TEMPLATE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a route cannot name a template of another channel', v_ok, v_msg;

  perform erp.upsert_notification_route('admins_inapp', 'Administrators, in app', 'zzoc.%', 'medium',
                                        'role', 'administrator', null, null, 'in_app', 'tpl_inapp');
  perform erp.append_event('zzoc.thing_happened', 'tenant', v_tenant, '{"n": 1}'::jsonb, p_event_version => 1);
  select routed into v_n from erp.route_notifications();
  return query select 'an event matching a route reaches every member of its audience',
    v_n = 2 and (select count(*) from erp.notification n where n.tenant_id = v_tenant and n.status = 'pending') = 2,
    format('%s notification(s) for two administrators', v_n);

  select delivered into v_n from erp.dispatch_notifications();
  return query select 'in-app is delivered on the spot',
    v_n = 2 and (select count(*) from erp.notification n where n.tenant_id = v_tenant and n.status = 'delivered') = 2,
    'delivered, not merely sent';

  select (x ->> 'id')::uuid into v_notif from jsonb_array_elements(public.erp_my_notifications(10)) x limit 1;
  perform erp.mark_notification_read(v_notif);
  return query select 'a person marks their own notification read',
    (select n.status = 'read' and n.read_at is not null from erp.notification n where n.id = v_notif), 'read';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.mark_notification_read(v_notif);
    v_ok := false; v_msg := 'somebody else marked it read';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_YOUR_NOTIFICATION%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and nobody else can', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);

  -- ── §15.6 preferences within bounds, and the fallback ─────────────────────

  perform erp.upsert_notification_route('admins_email', 'Administrators, by email', 'zzoc.mail%', 'high',
                                        'role', 'administrator', null, null, 'email', 'tpl_email');
  begin
    perform erp.set_notification_preference('in_app', false);
    v_ok := false; v_msg := 'in-app was switched off';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_IN_APP_CANNOT_BE_SWITCHED_OFF%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'in-app cannot be switched off', v_ok, v_msg;

  perform erp.set_notification_preference('email', false);
  perform erp.append_event('zzoc.mail_requested', 'tenant', v_tenant, '{}'::jsonb, p_event_version => 1);
  perform erp.route_notifications();
  return query select 'a person who switched email off is reached in-app instead',
    (select n.channel_kind = 'in_app' from erp.notification n
      where n.tenant_id = v_tenant and n.app_user_id = v_admin
        and n.route_id = (select id from erp.notification_route where tenant_id = v_tenant and code = 'admins_email')
      order by n.created_at desc limit 1),
    'preference honoured; nothing lost';
  perform erp.set_notification_preference('email', true);

  insert into erp.email_suppression (tenant_id, address, reason, is_permanent) values (v_tenant, 'op@zzoc.test', 'complaint', true);
  select suppressed into v_n from erp.dispatch_notifications();
  return query select 'a suppressed address is refused and the alert reaches the person in-app',
    v_n = 1 and exists (
      select 1 from erp.notification f
       where f.tenant_id = v_tenant and f.app_user_id = v_second and f.channel_kind = 'in_app'
         and f.escalation_of = (select n.id from erp.notification n
                                 where n.tenant_id = v_tenant and n.app_user_id = v_second and n.status = 'suppressed')),
    'suppressed on email, delivered in-app';
  delete from erp.email_suppression where tenant_id = v_tenant;

  return query select 'the assertion sees the fallback and passes',
    erp.assert_output_channels_sound() is not null, 'every lost alert has its copy';

  -- ── §15.6 quiet hours, digest, escalation ─────────────────────────────────

  perform erp.set_my_quiet_hours(array[1,2,3,4,5,6,7]::smallint[], '00:00', '23:59', 'UTC', 'critical');
  perform erp.append_event('zzoc.thing_happened', 'tenant', v_tenant, '{"n": 2}'::jsonb, p_event_version => 1);
  select held into v_n from erp.route_notifications();
  return query select 'a notification below the override severity is held during quiet hours',
    v_n = 1 and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.app_user_id = v_admin and n.status = 'held'),
    'held until the window ends';
  update erp.notification set held_until = now() - interval '1 minute' where tenant_id = v_tenant and status = 'held';
  select released into v_n from erp.dispatch_notifications();
  return query select 'and released when the window ends', v_n = 1, 'released and delivered';
  perform erp.set_my_quiet_hours(null, null, null, 'UTC');

  perform erp.upsert_notification_route('digest', 'Digested', 'zzoc.digest%', 'low',
                                        'user', null, null, v_admin, 'in_app', 'tpl_inapp', 30);
  perform erp.append_event('zzoc.digest_one_posted', 'tenant', v_tenant, '{}'::jsonb, p_event_version => 1);
  perform erp.append_event('zzoc.digest_two_posted', 'tenant', v_tenant, '{}'::jsonb, p_event_version => 1);
  perform erp.route_notifications();
  update erp.notification set created_at = now() - interval '31 minutes' where tenant_id = v_tenant and digest_key is not null;
  select digested into v_n from erp.dispatch_notifications();
  return query select 'two events on a digesting route become one message',
    v_n = 1 and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.digest_of = 2 and n.status = 'delivered')
    and (select count(*) from erp.notification n where n.tenant_id = v_tenant and n.status = 'digested') = 2,
    'one digest of two, the originals folded';

  perform erp.upsert_notification_route('escalating', 'Escalates', 'zzoc.urgent%', 'high',
                                        'user', null, null, v_second, 'in_app', 'tpl_inapp', null, 15, 'administrator');
  perform erp.append_event('zzoc.urgent_thing_raised', 'tenant', v_tenant, '{}'::jsonb, p_event_version => 1);
  perform erp.route_notifications(); perform erp.dispatch_notifications();
  update erp.notification set created_at = now() - interval '16 minutes'
   where tenant_id = v_tenant and route_id = (select id from erp.notification_route where tenant_id = v_tenant and code = 'escalating');
  select escalated into v_n from erp.dispatch_notifications();
  return query select 'unacknowledged past the timer, it escalates to the role once',
    v_n = 2 and (select count(*) from erp.notification n where n.tenant_id = v_tenant and n.subject like 'Escalated:%') = 2
    and (select d.escalated from erp.dispatch_notifications() d) = 0,
    'two administrators told; not told again';

  perform erp_test.close_bootstrap_window(v_tenant);

  -- ── §15.3 ZPL scales to the printer ───────────────────────────────────────

  res := erp.render_label('bin_label_test', 'LBL203');
  v_zpl203 := res ->> 'zpl'; v_render := (res ->> 'render_id')::uuid; v_delivery := (res ->> 'delivery_id')::uuid;
  res := erp.render_label('bin_label_test', 'LBL300');
  v_zpl300 := res ->> 'zpl';
  return query select 'one label template renders at 203 and 300 dpi without a second template',
    v_zpl203 like '^XA%^XZ' and v_zpl300 like '^XA%^XZ'
    and v_zpl203 like '%^PW799%' and v_zpl300 like '%^PW1181%'
    and v_zpl203 like '%^BCN%' and v_zpl203 <> v_zpl300,
    format('203: %s chars, 300: %s chars', length(v_zpl203), length(v_zpl300));

  return query select 'the render is archived with its ZPL and queued to the printer',
    (select o.content = v_zpl203 and o.checksum = md5(v_zpl203) from erp.output_render o where o.id = v_render)
    and (select d.status = 'queued' and d.destination = 'tcp://10.0.0.11:9100' from erp.output_delivery d where d.id = v_delivery),
    'archived, queued';

  begin
    perform erp.render_label('bin_label_test', 'DOC1');
    v_ok := false; v_msg := 'a label was rendered to a document printer';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_PRINTER%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a label cannot go to a document printer', v_ok, v_msg;

  -- ── §15.4 routing, reprint, queue health ──────────────────────────────────

  begin
    perform erp.route_print(v_render, v_site, null);
    v_ok := false; v_msg := 'a print was routed with no route';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_PRINT_ROUTE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'with no route a print has nowhere to go, and says so', v_ok, v_msg;

  perform erp.upsert_print_route('labels_dc1', 'label', 'LBL203', null, v_site);
  perform erp.upsert_print_route('labels_bench2', 'label', 'LBL300', null, v_site, 'BENCH-2');
  res := erp.route_print(v_render, v_site, 'BENCH-2');
  return query select 'the most specific route wins: the workstation''s printer over the site''s',
    res ->> 'printer' = 'LBL300' and res ->> 'route' = 'labels_bench2', res ->> 'printer';
  res := erp.route_print(v_render, v_site, null);
  return query select 'and the site''s printer when no workstation is given',
    res ->> 'printer' = 'LBL203', res ->> 'printer';

  begin
    perform erp.upsert_print_route('bad_kind', 'label', 'DOC1');
    v_ok := false; v_msg := 'labels were routed to a document printer';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PRINTER_KIND_MISMATCH%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a label route cannot name a document printer', v_ok, v_msg;

  res := erp.reprint_output(v_render, 'LBL203');
  return query select 'a reprint is a new render marked as a copy of the original',
    (res ->> 'is_copy')::boolean and (res ->> 'reissue_of')::uuid = v_render
    and (select o.is_copy and o.content = v_zpl203 from erp.output_render o where o.id = (res ->> 'render_id')::uuid),
    'copy, same bytes, new row';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.confirm_delivery(v_delivery);
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  return query select 'the gateway confirms a delivery it made',
    (select d.status = 'confirmed' and d.confirmed_at is not null and d.attempts = 1 from erp.output_delivery d where d.id = v_delivery),
    'confirmed';

  -- created_at is frozen by the attribution trigger, so an old queued print is
  -- written old rather than aged.
  insert into erp.output_delivery (tenant_id, output_render_id, destination, destination_kind, status, attempts, created_at)
  values (v_tenant, v_render, 'tcp://10.0.0.12:9100', 'print', 'queued', 0, now() - interval '40 minutes');
  return query select 'a printer with queued prints and nothing confirmed for thirty minutes reads as offline',
    exists (select 1 from erp.print_queue_health_report() q where q.printer_code = 'LBL300' and q.signal like 'printer offline%'),
    'alerting before the operation notices';

  -- ── §15.5 sender identity ─────────────────────────────────────────────────

  return query select 'with no verified domain the organisation sends from the platform''s address',
    not (erp.sender_for('transactional') ->> 'own_domain')::boolean
    and erp.sender_for('transactional') ->> 'from_address' like '%@%', erp.sender_for('transactional') ->> 'from_address';

  perform erp.upsert_sender_identity('example-org.test', 'transactional', 'invoices', 'accounts@example-org.test');
  res := erp.record_sender_verification('example-org.test', true, true, false);
  return query select 'two records of three is not verified, and the reply-to is used meanwhile',
    not (res ->> 'verified')::boolean
    and erp.sender_for('transactional') ->> 'reply_to' = 'accounts@example-org.test'
    and not (erp.sender_for('transactional') ->> 'own_domain')::boolean,
    'SPF and DKIM, no DMARC';

  res := erp.record_sender_verification('example-org.test', true, true, true);
  return query select 'all three verified and the organisation sends as itself',
    (res ->> 'verified')::boolean
    and erp.sender_for('transactional') ->> 'from_address' = 'invoices@example-org.test'
    and (erp.sender_for('transactional') ->> 'own_domain')::boolean
    and not (erp.sender_for('operational') ->> 'own_domain')::boolean,
    'transactional as itself; operational still from the platform';

  return query select 'the checklist names the three records to publish, with why',
    jsonb_array_length(erp.sender_dns_checklist('example-org.test')) = 3
    and exists (select 1 from jsonb_array_elements(erp.sender_dns_checklist('example-org.test')) x
                 where x ->> 'record' = 'DMARC' and x ->> 'name' = '_dmarc.example-org.test'),
    'SPF, DKIM, DMARC';

  return query select 'output health reports the queue and the sender alongside the counts',
    (erp.output_health_report() ->> 'print_queue_depth')::integer >= 1
    and (erp.output_health_report() -> 'sender' ->> 'own_domain')::boolean,
    erp.output_health_report() ->> 'print_queue_depth';

  return query select 'and the assertion passes over all of it',
    erp.assert_output_channels_sound() is not null, 'sound';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (ad, op);
  delete from erp_ref.event_type where code like 'zzoc.%';
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant)
    and not exists (select 1 from erp_ref.event_type where code like 'zzoc.%'), 'organisation and event types gone';
end;
$function$

;
