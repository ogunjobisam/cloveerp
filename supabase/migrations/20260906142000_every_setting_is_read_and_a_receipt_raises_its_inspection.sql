-- =============================================================================
-- 20260906142000  Every setting is read, and a receipt raises its inspection
-- -----------------------------------------------------------------------------
-- Specification v1.6 §3.2 (configuration), §5.2 (shelf life), §5.6 (credit,
-- backorders), §5.8 (inspection), §3.7 (re-approval). Phase 9 of the
-- outstanding-work programme, closing deferred findings 14 and 27.
--
-- Finding 14. Five configuration types were declared, documented, shipped by
-- the profile packs and asked about in guidance, and read by nothing: a value
-- set for any of them was stored and silently ignored. The dead-configuration
-- report, whose name promises exactly this finding, had eleven clauses about
-- instances and none about a declared type nobody reads.
--
--   * stock.shelf_life_minimum: a batch under the site's minimum remaining
--     life is refused on receipt (erp.receive_against, erp.post_document_stock),
--     refused on a transfer that is not into quarantine (erp.move_container),
--     never offered for despatch (erp.commit_allocation) and never promised
--     (erp.reserve_for_line). erp.remaining_shelf_life_pct() is the one
--     measure; where a batch's life cannot be measured the check stands down.
--   * sales.credit_control: tolerance_pct widens the limit, overdue_days_block
--     holds a customer with debt past it, block_at_limit switches the limit
--     hold off, and check_at_capture refuses a sales order for a held customer
--     when it is taken (erp.create_document, CLOVEERP_CREDIT_HOLD_AT_CAPTURE).
--   * sales.backorder_policy: refuse turns a shortage into a refusal
--     (CLOVEERP_BACKORDER_REFUSED); partial_ship promises what exists and
--     keeps the shortage as the planner's exception; permit is as before.
--   * quality.quarantine_defaults: an accounting class in posting_classes
--     lands in quarantine on receipt; stock past ageing_days_warn in
--     quarantine is a finding of the quality report.
--   * approval.reapproval_tolerance: fills the tolerances an approval chain
--     leaves null; reapprove_on_supplier_change voids an approval when the
--     party changed.
--   * The twelfth clause of erp.dead_configuration_report(): a configuration
--     type nothing calls erp.config_value() for. erp.assert_no_dead_configuration()
--     fails the build on it from now on.
--
-- Finding 27. Nothing in the product raised an inspection: the installer
-- promoted a goods-in plan, the quarantine gate was the item flag alone, and
-- erp.raise_inspection() had one caller, a test. Now a goods receipt raises
-- the inspection its plan requires — for an item flagged for inspection, an
-- item of a class the quarantine defaults name, or an item a plan names by
-- item or class — and lands in quarantine when it did; a plan may be scoped
-- to a site; and a batch with an inspection nobody has dispositioned is not
-- released (CLOVEERP_INSPECTION_OUTSTANDING). The installer's tenant-wide
-- plan therefore applies to what is flagged for inspection, which is what an
-- organisation that installed quality and flagged nothing would expect.
--
-- Proof: erp_test.configuration_wiring_suite() (13 cases, pinned); the
-- quality and second-organisation suites re-pinned to the inspection the
-- receipt raises (29 and 13, unchanged); the dead-configuration assertion;
-- the standard assertions and the console.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Shelf life is measured once
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.remaining_shelf_life_pct(p_batch_id uuid, p_on date default current_date)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case
           when b.expires_on is null then null
           when coalesce(i.shelf_life_days, b.expires_on - b.manufactured_on) is null
                or coalesce(i.shelf_life_days, b.expires_on - b.manufactured_on) <= 0 then null
           else round(greatest(b.expires_on - p_on, 0) * 100.0
                      / coalesce(i.shelf_life_days, b.expires_on - b.manufactured_on), 2)
         end
    from erp.batch b
    join erp.item i on i.id = b.item_id
   where b.id = p_batch_id
$$;

revoke all on function erp.remaining_shelf_life_pct(uuid, date) from public, anon;

comment on function erp.remaining_shelf_life_pct(uuid, date) is
  'The share of a batch''s life left on a date: days to expiry over the '
  'item''s shelf life (or the batch''s own span when the item states none). '
  'Null when it cannot be measured — no expiry, no life — and every reader '
  'treats null as no objection.';

-- The item's accounting class is one the quarantine defaults name.
create or replace function erp.item_class_quarantined(p_item_id uuid, p_entity_id uuid, p_site_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from erp.item_posting_class ipc
      join erp.posting_class pc on pc.id = ipc.posting_class_id
     where ipc.item_id = p_item_id
       and ipc.status = 'active'
       and ipc.valid_from <= current_date
       and (ipc.valid_to is null or ipc.valid_to > current_date)
       and pc.code in (
         select jsonb_array_elements_text(
                  coalesce(erp.config_value('quality.quarantine_defaults', null, null, p_entity_id, p_site_id) -> 'posting_classes',
                           '[]'::jsonb))))
$$;

revoke all on function erp.item_class_quarantined(uuid, uuid, uuid) from public, anon;

-- ── Despatch: erp.commit_allocation never offers a batch under the minimum ──

do $commit$
declare
  v_def text;
  v_n1  text := E'  v_tz      text;\nbegin';
  v_r1  text := E'  v_tz      text;\n  v_min_pct numeric;\n  v_min_days integer;\nbegin';
  v_n2  text := E'  v_single  := coalesce((v_policy ->> ''single_batch_per_order'')::boolean, false) and it.is_batch_controlled;';
  v_r2  text := E'  -- stock.shelf_life_minimum: what is under the site''s minimum for despatch is never offered.\n'
             || E'  v_min_pct := coalesce((erp.config_value(''stock.shelf_life_minimum'', null, null, al.entity_id, al.site_id) ->> ''on_despatch_pct'')::numeric, 0);\n'
             || E'  v_min_days := coalesce(it.min_remaining_shelf_life_days, 0);\n'
             || E'  v_single  := coalesce((v_policy ->> ''single_batch_per_order'')::boolean, false) and it.is_batch_controlled;';
  v_n3  text := E'               and (p_location_id is null or b.location_id = p_location_id)\n             group by b.batch_id';
  v_r3  text := E'               and (p_location_id is null or b.location_id = p_location_id)\n'
             || E'               and (bt.id is null or coalesce(erp.remaining_shelf_life_pct(bt.id), 100) >= v_min_pct)\n'
             || E'               and (bt.expires_on is null or bt.expires_on - current_date >= v_min_days)\n'
             || E'             group by b.batch_id';
  v_n4  text := E'       and (v_batch is null or b.batch_id = v_batch)\n     order by';
  v_r4  text := E'       and (v_batch is null or b.batch_id = v_batch)\n'
             || E'       and (bt.id is null or coalesce(erp.remaining_shelf_life_pct(bt.id), 100) >= v_min_pct)\n'
             || E'       and (bt.expires_on is null or bt.expires_on - current_date >= v_min_days)\n'
             || E'     order by';
  v_n5  text := E'what is on hand is already committed to other orders.''';
  v_r5  text := E'what is on hand is already committed to other orders. A batch under the site''''s minimum remaining shelf life for despatch is never offered.''';
begin
  v_def := pg_get_functiondef('erp.commit_allocation(uuid,uuid,uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1
     or (length(v_def) - length(replace(v_def, v_n4, ''))) / length(v_n4) <> 1
     or (length(v_def) - length(replace(v_def, v_n5, ''))) / length(v_n5) <> 1 then
    raise exception 'CLOVEERP_COMMIT_ALLOCATION_UNRECOGNISED: erp.commit_allocation() is not the body this migration patches';
  end if;
  execute replace(replace(replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3), v_n4, v_r4), v_n5, v_r5);
end
$commit$;

-- ── Promise: erp.reserve_for_line does not promise short-life stock, and
--    honours sales.backorder_policy ──────────────────────────────────────────

do $reserve$
declare
  v_def text;
  v_n1  text := E'  v_cause  text;\nbegin';
  v_r1  text := E'  v_cause  text;\n  v_short  numeric := 0;\n  v_bo     jsonb;\n  v_bo_rule text;\nbegin';
  v_n2  text := E'  v_res := least(l.quantity, greatest(a.available, 0));';
  v_r2  text := E'  -- stock.shelf_life_minimum: stock under the site''s minimum for despatch is not promised.\n'
             || E'  select coalesce(sum(b.quantity), 0) into v_short\n'
             || E'    from erp.stock_balance b\n'
             || E'    join erp.batch bt on bt.id = b.batch_id\n'
             || E'   where b.tenant_id = v_tenant and b.item_id = l.item_id and b.site_id = d.site_id\n'
             || E'     and b.stock_status = ''available'' and b.quantity > 0\n'
             || E'     and coalesce(erp.remaining_shelf_life_pct(bt.id), 100)\n'
             || E'         < coalesce((erp.config_value(''stock.shelf_life_minimum'', null, null, d.entity_id, d.site_id) ->> ''on_despatch_pct'')::numeric, 0);\n'
             || E'  v_res := least(l.quantity, greatest(a.available - v_short, 0));';
  v_n3  text := E'  if v_unmet > 0 then\n    insert into erp.planning_exception (';
  v_r3  text := E'  -- sales.backorder_policy: what a shortage becomes.\n'
             || E'  v_bo := coalesce(erp.config_value(''sales.backorder_policy'', null, null, d.entity_id, d.site_id), ''{}''::jsonb);\n'
             || E'  v_bo_rule := coalesce(v_bo -> ''by_channel'' ->> coalesce(d.attributes ->> ''channel'', ''''), v_bo ->> ''default'', ''permit'');\n'
             || E'  if v_unmet > 0 and (v_bo_rule = ''refuse'' or (v_bo_rule = ''partial_ship'' and v_res <= 0)) then\n'
             || E'    raise exception ''CLOVEERP_BACKORDER_REFUSED: % of % cannot be filled at this site and the policy does not take a backorder'', v_unmet, l.quantity\n'
             || E'      using errcode = ''23514'',\n'
             || E'            hint = ''Reduce the line to what is available, choose another site, or set sales.backorder_policy to permit or partial_ship.'';\n'
             || E'  end if;\n'
             || E'  if v_unmet > 0 and v_bo_rule = ''partial_ship'' then\n'
             || E'    update erp.allocation set quantity = v_res, unmet_quantity = 0, unmet_cause = ''partial_ship'', updated_at = now()\n'
             || E'     where id = v_alloc;\n'
             || E'  end if;\n'
             || E'  if v_unmet > 0 then\n    insert into erp.planning_exception (';
begin
  v_def := pg_get_functiondef('erp.reserve_for_line(uuid,text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1 then
    raise exception 'CLOVEERP_RESERVE_FOR_LINE_UNRECOGNISED: erp.reserve_for_line() is not the body this migration patches';
  end if;
  execute replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3);
end
$reserve$;

-- ── Transfer: erp.move_container refuses a short-life batch moving anywhere
--    but quarantine or despatch ───────────────────────────────────────────────

do $move$
declare
  v_def text;
  v_n   text := E'  loop\n    insert into erp.stock_movement (\n      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,\n      container_id, from_location_id, from_status, to_location_id, to_status,';
  v_r   text := E'  loop\n'
             || E'    -- stock.shelf_life_minimum: a batch under the site''s minimum for a transfer\n'
             || E'    -- goes to quarantine or out of the door, nowhere else.\n'
             || E'    if r.batch_id is not null\n'
             || E'       and (select l.location_type::text from erp.location l where l.id = p_to_location_id) not in (''quarantine'', ''despatch'', ''scrap'')\n'
             || E'       and coalesce(erp.remaining_shelf_life_pct(r.batch_id), 100)\n'
             || E'           < coalesce((erp.config_value(''stock.shelf_life_minimum'', null, null,\n'
             || E'                        (select s.entity_id from erp.site s where s.id = r.site_id), r.site_id) ->> ''on_transfer_pct'')::numeric, 0) then\n'
             || E'      raise exception ''CLOVEERP_SHELF_LIFE_SHORT: batch % has % per cent of its life left, under the site''''s minimum for a transfer'',\n'
             || E'        (select b.batch_number from erp.batch b where b.id = r.batch_id), round(erp.remaining_shelf_life_pct(r.batch_id))\n'
             || E'        using errcode = ''23514'',\n'
             || E'              hint = ''Move it to quarantine or despatch it; lower on_transfer_pct in stock.shelf_life_minimum for this site if the minimum is wrong.'';\n'
             || E'    end if;\n'
             || E'    insert into erp.stock_movement (\n      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,\n      container_id, from_location_id, from_status, to_location_id, to_status,';
begin
  v_def := pg_get_functiondef('erp.move_container(uuid,uuid,text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_MOVE_CONTAINER_UNRECOGNISED: erp.move_container() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$move$;

-- ── Receipt against an order: the minimum, and the quarantine class ─────────

do $receive$
declare
  v_def text;
  v_n   text := E'  select i.quarantine_on_receipt into v_quarantine\n    from erp.item i where i.id = ol.item_id;\n';
  v_r   text := E'  select i.quarantine_on_receipt into v_quarantine\n    from erp.item i where i.id = ol.item_id;\n'
             || E'  -- stock.shelf_life_minimum: this site receives nothing under its minimum.\n'
             || E'  if p_batch_id is not null\n'
             || E'     and coalesce(erp.remaining_shelf_life_pct(p_batch_id), 100)\n'
             || E'         < coalesce((erp.config_value(''stock.shelf_life_minimum'', null, null, rd.entity_id, rd.site_id) ->> ''on_receipt_pct'')::numeric, 0) then\n'
             || E'    raise exception ''CLOVEERP_SHELF_LIFE_SHORT: batch % has % per cent of its life left and this site receives nothing under % per cent'',\n'
             || E'      (select b.batch_number from erp.batch b where b.id = p_batch_id), round(erp.remaining_shelf_life_pct(p_batch_id)),\n'
             || E'      (erp.config_value(''stock.shelf_life_minimum'', null, null, rd.entity_id, rd.site_id) ->> ''on_receipt_pct'')\n'
             || E'      using errcode = ''23514'',\n'
             || E'            hint = ''Refuse the delivery, or lower on_receipt_pct in stock.shelf_life_minimum for this site.'';\n'
             || E'  end if;\n'
             || E'  -- quality.quarantine_defaults: an accounting class that lands in quarantine.\n'
             || E'  v_quarantine := coalesce(v_quarantine, false) or erp.item_class_quarantined(ol.item_id, rd.entity_id, rd.site_id);\n';
begin
  v_def := pg_get_functiondef('erp.receive_against(uuid,uuid,numeric,uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_RECEIVE_AGAINST_UNRECOGNISED: erp.receive_against() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$receive$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Credit control reads its policy
-- ═════════════════════════════════════════════════════════════════════════════

do $check$
declare
  v_def text := pg_get_functiondef('erp.credit_position(uuid)'::regprocedure);
begin
  if (length(v_def) - length(replace(v_def, 'exposure.amt > terms.credit_limit_minor', ''))) / length('exposure.amt > terms.credit_limit_minor') <> 2
     or position('''within terms''' in v_def) = 0 then
    raise exception 'CLOVEERP_CREDIT_POSITION_UNRECOGNISED: erp.credit_position() is not the body this migration restates';
  end if;
end
$check$;

create or replace function erp.credit_position(p_party_id uuid)
returns table (credit_limit_minor bigint, exposure_minor bigint,
               headroom_minor bigint, credit_status text, is_blocked boolean,
               on_hold boolean, reason text)
language sql
stable
security invoker
set search_path = ''
as $$
  with terms as (
    select t.credit_limit_minor, t.credit_status, t.is_blocked, t.block_reason, t.entity_id
      from erp.party_role_terms t
      join erp.party_role pr on pr.id = t.party_role_id
     where t.tenant_id = erp.current_tenant_id()
       and pr.party_id = p_party_id and pr.role_kind = 'customer'
       and t.valid_from <= current_date
       and (t.valid_to is null or t.valid_to > current_date)
     order by t.valid_from desc limit 1
  ),
  -- sales.credit_control, at the terms' company.
  pol as (
    select coalesce(erp.config_value('sales.credit_control', null, null, (select t.entity_id from terms t), null), '{}'::jsonb) as v
  ),
  exposure as (
    -- Committed and not yet settled: orders in flight plus receivables
    -- outstanding. Counting only one of them understates by whichever half is
    -- currently larger.
    select coalesce((select sum(erp.document_value_minor(d.id))
                       from erp.document d
                       join erp.document_type dt on dt.id = d.document_type_id
                       join erp.object_state os on os.object_type = 'document'
                                               and os.object_id = d.id
                       join erp.state s on s.id = os.current_state_id
                      where d.tenant_id = erp.current_tenant_id()
                        and d.party_id = p_party_id
                        and dt.base_type_code = 'sales_order'
                        and s.is_committed and not s.is_terminal
                        and not d.is_cancelled), 0)
         + coalesce((select sum(si.debit_minor - si.credit_minor)
                       from erp.subledger_item si
                      where si.tenant_id = erp.current_tenant_id()
                        and si.party_id = p_party_id
                        and si.control_kind = 'receivable'), 0) as amt
  ),
  -- Debt past the policy's overdue window: an item still owing whose due date
  -- is further back than overdue_days_block.
  overdue as (
    select exists (
      select 1 from erp.subledger_item si, pol
       where si.tenant_id = erp.current_tenant_id()
         and si.party_id = p_party_id
         and si.control_kind = 'receivable'
         and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
         and si.due_date is not null
         and si.due_date < current_date - coalesce((pol.v ->> 'overdue_days_block')::integer, 30)) as any_overdue
  ),
  verdict as (
    select terms.credit_limit_minor,
           exposure.amt,
           coalesce(terms.is_blocked, false) as blocked,
           -- The limit, widened by the tolerance the policy allows.
           (terms.credit_limit_minor is not null
              and coalesce((pol.v ->> 'block_at_limit')::boolean, true)
              and exposure.amt > round(terms.credit_limit_minor * (1 + coalesce((pol.v ->> 'tolerance_pct')::numeric, 0) / 100))) as over_limit,
           overdue.any_overdue as overdue,
           terms.credit_status, terms.is_blocked, terms.block_reason
      from terms, exposure, pol, overdue
  )
  select v.credit_limit_minor, v.amt,
         v.credit_limit_minor - v.amt,
         v.credit_status, v.is_blocked,
         v.blocked or v.over_limit or v.overdue,
         case when v.blocked then coalesce(v.block_reason, 'blocked')
              when v.over_limit then 'exposure exceeds the credit limit'
              when v.overdue then 'debt is overdue beyond the policy''s window'
              else 'within terms' end
    from verdict v
$$;

comment on function erp.credit_position(uuid) is
  'The customer''s credit as the terms and sales.credit_control together say '
  'it: exposure is committed orders plus outstanding receivables; a hold is a '
  'block on the terms, exposure over the limit widened by tolerance_pct (unless '
  'block_at_limit is off), or debt overdue beyond overdue_days_block.';

-- A sales order for a held customer is refused when taken, if the policy
-- checks at capture.
do $capture$
declare
  v_def text;
  v_n1  text := E'  v_id     uuid;\nbegin';
  v_r1  text := E'  v_id     uuid;\n  v_cc     jsonb;\n  cp       record;\nbegin';
  v_n2  text := E'  if dt.numbering_rule_id is null then\n    raise exception ''CLOVEERP_DOCUMENT_NO_NUMBERING: % has no numbering rule bound'',';
  v_r2  text := E'  -- sales.credit_control: a held customer''s order is refused when taken, if the policy says so.\n'
             || E'  if bt.code = ''sales_order'' and p_party_id is not null then\n'
             || E'    v_cc := coalesce(erp.config_value(''sales.credit_control'', null, null, p_entity_id, p_site_id), ''{}''::jsonb);\n'
             || E'    if coalesce((v_cc ->> ''check_at_capture'')::boolean, true) then\n'
             || E'      select * into cp from erp.credit_position(p_party_id);\n'
             || E'      if found and cp.on_hold then\n'
             || E'        raise exception ''CLOVEERP_CREDIT_HOLD_AT_CAPTURE: the customer is on credit hold (%) and the policy checks credit when an order is taken'', cp.reason\n'
             || E'          using errcode = ''42501'',\n'
             || E'                hint = ''Raise the limit on the customer''''s terms, release an existing hold, or switch check_at_capture off in sales.credit_control.'';\n'
             || E'      end if;\n'
             || E'    end if;\n'
             || E'  end if;\n\n'
             || E'  if dt.numbering_rule_id is null then\n    raise exception ''CLOVEERP_DOCUMENT_NO_NUMBERING: % has no numbering rule bound'',';
begin
  v_def := pg_get_functiondef('erp.create_document(text,uuid,uuid,uuid,date,character,text,jsonb)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_CREATE_DOCUMENT_UNRECOGNISED: erp.create_document() is not the body this migration patches';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$capture$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Re-approval reads its tolerance
-- ═════════════════════════════════════════════════════════════════════════════

do $reapprove$
declare
  v_def text;
  v_n1  text := E'  v_pct    numeric;\nbegin';
  v_r1  text := E'  v_pct    numeric;\n  v_tol    jsonb;\n  v_abs    numeric;\n  v_p      numeric;\nbegin';
  v_n2  text := E'  if v_new_fp is distinct from v_req.material_fingerprint then';
  v_r2  text := E'  -- approval.reapproval_tolerance: the organisation''s policy fills what the chain leaves null.\n'
             || E'  v_tol := coalesce(erp.config_value(''approval.reapproval_tolerance'', null, null,\n'
             || E'                      nullif(p_context ->> ''entity_id'', '''')::uuid, nullif(p_context ->> ''site_id'', '''')::uuid), ''{}''::jsonb);\n'
             || E'  if coalesce((v_tol ->> ''reapprove_on_supplier_change'')::boolean, true)\n'
             || E'     and (p_context ->> ''party_id'') is distinct from (v_req.context ->> ''party_id'') then\n'
             || E'    required := true;\n'
             || E'    reason := ''the party changed since approval'';\n'
             || E'    return next; return;\n'
             || E'  end if;\n\n'
             || E'  if v_new_fp is distinct from v_req.material_fingerprint then';
  v_n3  text := E'      if (v_cv.tolerance_absolute is not null and v_delta > v_cv.tolerance_absolute)\n'
             || E'         or (v_cv.tolerance_pct is not null and (v_pct is null or v_pct > v_cv.tolerance_pct))\n'
             || E'         or (v_cv.tolerance_absolute is null and v_cv.tolerance_pct is null)\n'
             || E'      then';
  v_r3  text := E'      v_abs := coalesce(v_cv.tolerance_absolute, (v_tol ->> ''value_change_absolute_minor'')::numeric);\n'
             || E'      v_p   := coalesce(v_cv.tolerance_pct, (v_tol ->> ''value_change_pct'')::numeric);\n'
             || E'      if (v_abs is not null and v_delta > v_abs)\n'
             || E'         or (v_p is not null and (v_pct is null or v_pct > v_p))\n'
             || E'         or (v_abs is null and v_p is null)\n'
             || E'      then';
begin
  v_def := pg_get_functiondef('erp.check_reapproval_required(text,uuid,jsonb)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1 then
    raise exception 'CLOVEERP_REAPPROVAL_UNRECOGNISED: erp.check_reapproval_required() is not the body this migration patches';
  end if;
  execute replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3);
end
$reapprove$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Two reports learn a clause
-- ═════════════════════════════════════════════════════════════════════════════

-- Stock that has sat in quarantine past the site's ageing threshold.
do $quality$
declare
  v_def text;
  v_n   text := E'  -- A plan with no characteristics inspects nothing and records that it did.\n  select ''an inspection plan checks nothing'',';
  v_r   text := E'  -- quality.quarantine_defaults: stock held past the site''s ageing threshold.\n'
             || E'  select ''stock has sat in quarantine past the site''''s ageing threshold'',\n'
             || E'         i.code || '' @ '' || s.code,\n'
             || E'         format(''%s day(s) in quarantine; the site warns at %s and escalates at %s'',\n'
             || E'                (current_date - (b.first_received_at at time zone coalesce(s.timezone, ''UTC''))::date),\n'
             || E'                coalesce((q.v ->> ''ageing_days_warn'')::integer, 5), coalesce((q.v ->> ''ageing_days_escalate'')::integer, 10))\n'
             || E'    from erp.stock_balance b\n'
             || E'    join erp.item i on i.id = b.item_id\n'
             || E'    join erp.site s on s.id = b.site_id\n'
             || E'    cross join lateral (select coalesce(erp.config_value(''quality.quarantine_defaults'', null, null, s.entity_id, s.id), ''{}''::jsonb) as v) q\n'
             || E'   where b.tenant_id = erp.current_tenant_id()\n'
             || E'     and b.stock_status = ''quarantine'' and b.quantity > 0\n'
             || E'     and b.first_received_at < now() - make_interval(days => coalesce((q.v ->> ''ageing_days_warn'')::integer, 5))\n'
             || E'  union all\n'
             || E'  -- A plan with no characteristics inspects nothing and records that it did.\n  select ''an inspection plan checks nothing'',';
begin
  v_def := pg_get_functiondef('erp.quality_logistics_report()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_QUALITY_REPORT_UNRECOGNISED: erp.quality_logistics_report() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$quality$;

-- A configuration type declared and read by nothing. The clause reads the
-- catalogue the way erp.session_context_hygiene_report() does: a type no
-- function in the product names at all (erp.config_value() is the usual
-- reader; the price book reads its type through the configuration objects
-- directly) fails the build from now on.
do $dead$
declare
  v_def text;
  v_n   text := E'  select ''a ledger has no fiscal period covering today'',';
  v_r   text := E'  select ''a configuration type is declared and nothing reads it'',\n'
             || E'         ct.code,\n'
             || E'         format(''%s (%s): no function names %L, so a value set here is stored and ignored'',\n'
             || E'                ct.name_key, ct.module_code, ct.code)\n'
             || E'    from erp_ref.config_type ct\n'
             || E'   where not exists (\n'
             || E'     select 1 from pg_catalog.pg_proc p\n'
             || E'     join pg_catalog.pg_namespace n on n.oid = p.pronamespace\n'
             || E'    where n.nspname in (''erp'', ''public'')\n'
             || E'      and strpos(p.prosrc, '''''''' || ct.code || '''''''') > 0)\n'
             || E'  union all\n'
             || E'  select ''a ledger has no fiscal period covering today'',';
begin
  v_def := pg_get_functiondef('erp.dead_configuration_report()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_DEAD_CONFIGURATION_REPORT_UNRECOGNISED: erp.dead_configuration_report() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$dead$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. A receipt raises its inspection
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.inspection_plan add column if not exists site_id uuid;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'inspection_plan_tenant_id_site_id_fkey') then
    alter table erp.inspection_plan
      add constraint inspection_plan_tenant_id_site_id_fkey
      foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade;
  end if;
end
$fk$;

comment on column erp.inspection_plan.site_id is
  'The site the plan applies at; null means every site. A site''s own plan '
  'wins over the organisation''s.';

-- The plan may be scoped to a site, and a site's plan wins.
do $raise$
declare
  v_def text;
  v_n   text := E'     and (p.item_id = p_item_id or (p.item_id is null and p.item_class = v_class)\n'
             || E'          or (p.item_id is null and p.item_class is null))\n'
             || E'   order by (p.item_id is not null) desc, (p.item_class is not null) desc, p.code';
  v_r   text := E'     and (p.site_id is null or p.site_id = p_site_id)\n'
             || E'     and (p.item_id = p_item_id or (p.item_id is null and p.item_class = v_class)\n'
             || E'          or (p.item_id is null and p.item_class is null))\n'
             || E'   order by (p.site_id is not null) desc, (p.item_id is not null) desc, (p.item_class is not null) desc, p.code';
begin
  v_def := pg_get_functiondef('erp.raise_inspection(uuid,uuid,numeric,uuid,uuid,text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_RAISE_INSPECTION_UNRECOGNISED: erp.raise_inspection() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$raise$;

-- The promoter carries the site.
do $promoter$
declare
  v_def text;
  v_n1  text := E'          tenant_id, code, name, item_class, trigger_point, sampling_rule,\n'
             || E'          characteristics, status)\n'
             || E'        values (v_tenant, p ->> ''code'', p ->> ''name'', p ->> ''item_class'',';
  v_r1  text := E'          tenant_id, code, name, item_class, site_id, trigger_point, sampling_rule,\n'
             || E'          characteristics, status)\n'
             || E'        values (v_tenant, p ->> ''code'', p ->> ''name'', p ->> ''item_class'',\n'
             || E'                (select s.id from erp.site s where s.tenant_id = v_tenant and s.code = nullif(p ->> ''site'', '''')),';
  v_n2  text := E'          set name = excluded.name, item_class = excluded.item_class,\n'
             || E'              trigger_point = excluded.trigger_point,';
  v_r2  text := E'          set name = excluded.name, item_class = excluded.item_class,\n'
             || E'              site_id = excluded.site_id,\n'
             || E'              trigger_point = excluded.trigger_point,';
begin
  v_def := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the inspection_plan arm of erp.apply_change_set_item() is not the text this migration patches';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$promoter$;

-- The receipt: shelf life refused at the minimum, the inspection raised where
-- a plan applies, quarantine where it did.
do $stock$
declare
  v_def text;
  v_n1  text := E'  v_count    integer := 0;\n  v_owned    boolean;\n';
  v_r1  text := E'  v_count    integer := 0;\n  v_owned    boolean;\n  v_insp     uuid;\n  v_flag     boolean;\n  v_qclass   boolean;\n';
  v_n2  text := E'    insert into erp.stock_movement (\n      tenant_id, entity_id, site_id, movement_type, item_id,\n      batch_id, serial_id, container_id,';
  v_r2  text := E'    -- §5.8: a goods receipt raises the inspection its plan requires — for an item\n'
             || E'    -- flagged for inspection, an item of a class the quarantine defaults name, or\n'
             || E'    -- an item a plan names by item or class — and lands in quarantine when it did.\n'
             || E'    v_insp := null; v_flag := false; v_qclass := false;\n'
             || E'    if mt.direction = ''in'' and dt.base_type_code = ''receipt'' then\n'
             || E'      if ln.batch_id is not null\n'
             || E'         and coalesce(erp.remaining_shelf_life_pct(ln.batch_id), 100)\n'
             || E'             < coalesce((erp.config_value(''stock.shelf_life_minimum'', null, null, d.entity_id, d.site_id) ->> ''on_receipt_pct'')::numeric, 0) then\n'
             || E'        raise exception ''CLOVEERP_SHELF_LIFE_SHORT: batch % has % per cent of its life left and this site receives nothing under % per cent'',\n'
             || E'          (select b.batch_number from erp.batch b where b.id = ln.batch_id), round(erp.remaining_shelf_life_pct(ln.batch_id)),\n'
             || E'          (erp.config_value(''stock.shelf_life_minimum'', null, null, d.entity_id, d.site_id) ->> ''on_receipt_pct'')\n'
             || E'          using errcode = ''23514'',\n'
             || E'                hint = ''Refuse the delivery, or lower on_receipt_pct in stock.shelf_life_minimum for this site.'';\n'
             || E'      end if;\n'
             || E'      select i.quarantine_on_receipt into v_flag from erp.item i where i.id = ln.item_id;\n'
             || E'      v_qclass := erp.item_class_quarantined(ln.item_id, d.entity_id, d.site_id);\n'
             || E'      if coalesce(v_flag, false) or v_qclass\n'
             || E'         or exists (select 1 from erp.inspection_plan p\n'
             || E'                     where p.tenant_id = v_tenant and p.status = ''active'' and p.trigger_point = ''receipt''\n'
             || E'                       and (p.site_id is null or p.site_id = d.site_id)\n'
             || E'                       and (p.item_id = ln.item_id\n'
             || E'                            or (p.item_id is null and p.item_class = (select i.item_class from erp.item i where i.id = ln.item_id)))) then\n'
             || E'        v_insp := erp.raise_inspection(ln.item_id, d.site_id, ln.quantity, ln.batch_id, p_document_id, ''receipt'');\n'
             || E'      end if;\n'
             || E'    end if;\n\n'
             || E'    insert into erp.stock_movement (\n      tenant_id, entity_id, site_id, movement_type, item_id,\n      batch_id, serial_id, container_id,';
  v_n3  text := E'        case when mt.direction = ''in''\n'
             || E'                  and (select i.quarantine_on_receipt from erp.item i\n'
             || E'                        where i.id = ln.item_id)\n'
             || E'             then ''quarantine''::erp.stock_status';
  v_r3  text := E'        case when mt.direction = ''in''\n'
             || E'                  and (v_insp is not null or coalesce(v_flag, false) or v_qclass\n'
             || E'                       or (select i.quarantine_on_receipt from erp.item i\n'
             || E'                            where i.id = ln.item_id))\n'
             || E'             then ''quarantine''::erp.stock_status';
begin
  v_def := pg_get_functiondef('erp.post_document_stock(uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1 then
    raise exception 'CLOVEERP_POST_DOCUMENT_STOCK_UNRECOGNISED: erp.post_document_stock() is not the body this migration patches';
  end if;
  execute replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3);
end
$stock$;

-- A batch with an inspection nobody has dispositioned is not released.
do $release$
declare
  v_def text;
  v_n   text := E'  select coalesce(sum(sb.quantity), 0),\n'
             || E'         (array_agg(sb.location_id order by sb.quantity desc))[1]\n'
             || E'    into v_qty, v_from';
  v_r   text := E'  -- §5.8: the inspection the receipt raised stands between quarantine and release.\n'
             || E'  if exists (select 1 from erp.inspection ins\n'
             || E'              where ins.tenant_id = v_tenant and ins.batch_id = p_batch_id and ins.site_id = p_site_id\n'
             || E'                and ins.status <> ''cancelled'' and ins.disposition = ''pending''\n'
             || E'                and ins.id is distinct from p_inspection_id) then\n'
             || E'    raise exception ''CLOVEERP_INSPECTION_OUTSTANDING: batch % has an inspection nobody has dispositioned'', b.batch_number\n'
             || E'      using errcode = ''42501'',\n'
             || E'            hint = ''Record the results and disposition the inspection (erp_record_inspection_result, erp_disposition_inspection), then release naming it.'';\n'
             || E'  end if;\n\n'
             || E'  select coalesce(sum(sb.quantity), 0),\n'
             || E'         (array_agg(sb.location_id order by sb.quantity desc))[1]\n'
             || E'    into v_qty, v_from';
begin
  v_def := pg_get_functiondef('erp.release_batch(uuid,uuid,text,text,uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_RELEASE_BATCH_UNRECOGNISED: erp.release_batch() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$release$;

-- ── The two suites that raised the inspection by hand now read the one the
--    receipt raised ────────────────────────────────────────────────────────────

do $quality_suite$
declare
  v_def text;
  v_n   text := E'  v_insp := erp.raise_inspection(v_item, v_site, 100, v_batch, v_grn, ''receipt'');';
  v_r   text := E'  select ins.id into v_insp from erp.inspection ins\n'
             || E'   where ins.document_id = v_grn and ins.batch_id = v_batch limit 1;';
begin
  v_def := pg_get_functiondef('erp_test.quality_logistics_suite()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_FIXTURE_UNRECOGNISED: erp_test.quality_logistics_suite() does not raise the inspection by hand where this migration expects';
  end if;
  execute replace(v_def, v_n, v_r);
end
$quality_suite$;

do $nordwind$
declare
  v_def text;
  v_n1  text := E'  v_owner uuid; v_keeper uuid;\n';
  v_r1  text := E'  v_owner uuid; v_keeper uuid;\n  v_ins uuid;\n';
  v_n2  text := E'  perform public.erp_release_batch(v_b_soon, v_wh, ''Certificate of analysis reviewed, all characteristics within specification'', ''Qualified Person: N. Ward'', null);\n'
             || E'  perform public.erp_release_batch(v_b_late, v_wh, ''Certificate of analysis reviewed, all characteristics within specification'', ''Qualified Person: N. Ward'', null);';
  -- PH-SOON expired at +30 of a 365-day life: eight per cent, which the product's
  -- own receipt minimum now refuses. It stays the sooner batch at +280.
  v_n3  text := E'  v_b_soon := public.erp_create_batch((f ->> ''ph'')::uuid, ''PH-SOON'', current_date + 30, current_date - 10, (f ->> ''sup'')::uuid);';
  v_r3  text := E'  v_b_soon := public.erp_create_batch((f ->> ''ph'')::uuid, ''PH-SOON'', current_date + 280, current_date - 10, (f ->> ''sup'')::uuid);';
  v_r2  text := E'  -- The receipt raised an inspection per line; each is recorded and dispositioned\n'
             || E'  -- through the doors before the qualified release names it.\n'
             || E'  for v_ins in select ins.id from erp.inspection ins where ins.tenant_id = v_tenant and ins.document_id = v_doc loop\n'
             || E'    perform public.erp_record_inspection_result(v_ins, ''temperature'', 3, null, null);\n'
             || E'    perform public.erp_record_inspection_result(v_ins, ''packaging'', null, ''intact'', null);\n'
             || E'    perform public.erp_disposition_inspection(v_ins, ''accept'', ''harness: within specification'');\n'
             || E'  end loop;\n'
             || E'  perform public.erp_release_batch(v_b_soon, v_wh, ''Certificate of analysis reviewed, all characteristics within specification'', ''Qualified Person: N. Ward'',\n'
             || E'    (select ins.id from erp.inspection ins where ins.tenant_id = v_tenant and ins.batch_id = v_b_soon limit 1));\n'
             || E'  perform public.erp_release_batch(v_b_late, v_wh, ''Certificate of analysis reviewed, all characteristics within specification'', ''Qualified Person: N. Ward'',\n'
             || E'    (select ins.id from erp.inspection ins where ins.tenant_id = v_tenant and ins.batch_id = v_b_late limit 1));';
begin
  v_def := pg_get_functiondef('erp_test.second_organisation_suite()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1 then
    raise exception 'CLOVEERP_FIXTURE_UNRECOGNISED: erp_test.second_organisation_suite() does not release the two batches where this migration expects';
  end if;
  execute replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3);
end
$nordwind$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.configuration_wiring_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_ccy char(3); v_supplier uuid; v_customer uuid; v_cust_role uuid;
  v_recv uuid; v_bulk uuid;
  v_life uuid; v_raw uuid; v_desp uuid; v_plain uuid;
  v_b20 uuid; v_b90 uuid; v_b30 uuid;
  v_grn uuid; v_line uuid; v_so uuid; v_sol uuid; v_alloc uuid; v_insp uuid; v_plan uuid;
  v_ok boolean; v_msg text; v_n integer; v_q numeric; v_batch uuid; v_unmet numeric; v_cause text;
  cp record; v_chain uuid; v_ver uuid; v_req uuid; v_obj uuid := gen_random_uuid(); v_party uuid := gen_random_uuid();
  v_r1 boolean; v_r2 boolean; v_r3 boolean; v_reason text;
begin
  begin
    select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzwire', 'Configuration wiring suite', 'admin@zzwire.test', 'Wiring Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f2', 'admin@zzwire.test');
    perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000f2')::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);
    perform erp.configure_quality();

    select e.id, e.base_currency into v_entity, v_ccy from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
    select l.id into v_recv from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'receiving' limit 1;
    select l.id into v_bulk from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'bulk' limit 1;
    select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
    select pr.party_id, pr.id into v_customer, v_cust_role from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id limit 1;

    insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status, is_batch_controlled, has_expiry, shelf_life_days, quarantine_on_receipt)
    select v_tenant, 'ZZ-LIFE', 'Inspected, short-lived', 'RAW', u.id, 'active', true, true, 100, true from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
    returning id into v_life;
    insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
    select v_tenant, 'ZZ-RAWCLASS', 'Raw, not flagged', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
    returning id into v_raw;
    insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status, is_batch_controlled, has_expiry, shelf_life_days)
    select v_tenant, 'ZZ-DESP', 'Despatched by life', 'PACK', u.id, 'active', true, true, 100 from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
    returning id into v_desp;
    insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
    select v_tenant, 'ZZ-PLAIN', 'Plain', 'PACK', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
    returning id into v_plain;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (v_tenant, v_life, 'B-20', 'released', current_date - 80, current_date + 20) returning id into v_b20;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (v_tenant, v_desp, 'B-90', 'released', current_date - 10, current_date + 90) returning id into v_b90;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (v_tenant, v_desp, 'B-30', 'released', current_date - 70, current_date + 30) returning id into v_b30;

    -- 1. The product's minimum refuses a batch with a fifth of its life left.
    v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-W1', '{}'::jsonb);
    v_line := erp.add_document_line(v_grn, v_life, 25, 1000, 'short life', current_date);
    update erp.document_line set batch_id = v_b20, location_id = v_recv where id = v_line;
    v_ok := false; v_msg := null;
    begin
      perform erp.transition_document(v_grn, 'post', 'wiring suite');
      v_msg := 'it was received';
    exception when others then
      v_ok := sqlerrm like '%CLOVEERP_SHELF_LIFE_SHORT%'; v_msg := left(sqlerrm, 100);
    end;
    return query select 'a batch under the site''s minimum remaining life is refused on receipt', v_ok, v_msg;

    -- 2. A lower minimum at the site lets it in, and the plan puts it in quarantine with an inspection.
    perform erp.set_config_value('stock.shelf_life_minimum',
      '{"on_receipt_pct":10,"on_transfer_pct":50,"on_despatch_pct":33}'::jsonb,
      null, current_date, v_entity, v_site, 'wiring suite: a site that takes short-dated goods');
    perform erp.transition_document(v_grn, 'post', 'wiring suite');
    set constraints all immediate;
    select ins.id into v_insp from erp.inspection ins where ins.tenant_id = v_tenant and ins.document_id = v_grn;
    select coalesce(sum(b.quantity), 0) into v_q from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_life and b.stock_status = 'quarantine';
    return query select 'under the site''s own minimum the receipt lands in quarantine with the inspection its plan requires',
      v_insp is not null and v_q = 25
      and (select ins.sample_size from erp.inspection ins where ins.id = v_insp) = 6
      and (select ins.batch_id from erp.inspection ins where ins.id = v_insp) = v_b20,
      format('%s in quarantine (expected 25); inspection %s, sample %s (expected 6)', v_q, v_insp, (select ins.sample_size from erp.inspection ins where ins.id = v_insp));

    -- 3. Nothing is released past an inspection nobody dispositioned.
    v_ok := false; v_msg := null;
    begin
      perform erp.release_batch(v_b20, v_site, 'looked fine', 'QP/ZZ/1', null);
      v_msg := 'it was released';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_INSPECTION_OUTSTANDING%'; v_msg := left(sqlerrm, 100);
    end;
    perform erp.record_inspection_result(v_insp, 'temperature', 3);
    perform erp.record_inspection_result(v_insp, 'packaging', null, 'intact');
    perform erp.disposition_inspection(v_insp, 'accept', 'wiring suite: within specification');
    perform erp.release_batch(v_b20, v_site, 'inspection accepted', 'QP/ZZ/1', v_insp);
    select coalesce(sum(b.quantity), 0) into v_q from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_life and b.stock_status = 'available';
    return query select 'release is refused until the inspection is dispositioned, then names it',
      v_ok and v_q = 25, format('%s; then %s available after release', v_msg, v_q);

    -- 4. A plan naming a class, at this site, inspects an item nobody flagged.
    insert into erp.inspection_plan (tenant_id, code, name, item_class, site_id, trigger_point, sampling_rule, characteristics, status)
    values (v_tenant, 'zz-raw-here', 'Raw at this site', 'RAW', v_site, 'receipt',
            jsonb_build_object('scheme', 'fixed', 'size', 2),
            jsonb_build_array(jsonb_build_object('code', 'packaging', 'expected', 'intact')), 'active')
    returning id into v_plan;
    v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-W2', '{}'::jsonb);
    v_line := erp.add_document_line(v_grn, v_raw, 10, 500, 'raw, unflagged', current_date);
    update erp.document_line set location_id = v_recv where id = v_line;
    perform erp.transition_document(v_grn, 'post', 'wiring suite');
    set constraints all immediate;
    return query select 'a plan scoped to a class and a site inspects an unflagged item of that class there',
      exists (select 1 from erp.inspection ins where ins.tenant_id = v_tenant and ins.document_id = v_grn and ins.inspection_plan_id = v_plan and ins.sample_size = 2)
      and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = v_raw and b.stock_status = 'quarantine') = 10,
      'the site''s class plan raised it and the stock is held';
    update erp.inspection_plan set status = 'inactive', updated_at = now() where tenant_id = v_tenant and id = v_plan;

    -- Ten of each despatch batch at bulk; forty plain.
    v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-W3', '{}'::jsonb);
    v_line := erp.add_document_line(v_grn, v_desp, 10, 1000, 'long life', current_date);
    update erp.document_line set batch_id = v_b90, location_id = v_bulk where id = v_line;
    v_line := erp.add_document_line(v_grn, v_desp, 10, 1000, 'short life', current_date);
    update erp.document_line set batch_id = v_b30, location_id = v_bulk where id = v_line;
    v_line := erp.add_document_line(v_grn, v_plain, 40, 200, 'plain', current_date);
    update erp.document_line set location_id = v_bulk where id = v_line;
    perform erp.transition_document(v_grn, 'post', 'wiring suite');
    set constraints all immediate;

    -- 5. A promise leaves out what is under the despatch minimum.
    v_so := erp.open_document('sales_order', v_customer, null, v_site);
    v_sol := erp.add_document_line(v_so, v_desp, 15, 2500, 'fifteen');
    v_alloc := erp.reserve_for_line(v_sol);
    select a.unmet_quantity, a.unmet_cause into v_unmet, v_cause from erp.allocation a where a.id = v_alloc;
    return query select 'a reservation promises only stock over the site''s despatch minimum',
      v_unmet = 5, format('%s unmet of 15 (expected 5: the 30%% batch is not promised), cause %s', v_unmet, v_cause);

    -- 6. Committing that promise never offers the short-life batch.
    v_n := erp.commit_allocation(v_alloc);
    select count(*) filter (where l.batch_id <> v_b90) into v_q from erp.allocation_line l where l.allocation_id = v_alloc;
    return query select 'a commitment takes the long-life batch and never the one under the minimum',
      v_n = 1 and v_q = 0 and (select sum(l.quantity) from erp.allocation_line l where l.allocation_id = v_alloc) = 10,
      format('%s line(s), %s from a batch other than B-90 (expected 0)', v_n, v_q);

    -- 7. A backorder the policy refuses.
    perform erp.set_config_value('sales.backorder_policy', '{"default":"refuse","by_channel":{}}'::jsonb,
      null, current_date, v_entity, null, 'wiring suite: no backorders');
    v_so := erp.open_document('sales_order', v_customer, null, v_site);
    v_sol := erp.add_document_line(v_so, v_plain, 50, 300, 'fifty of forty');
    v_ok := false; v_msg := null;
    begin
      perform erp.reserve_for_line(v_sol);
      v_msg := 'it was reserved';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BACKORDER_REFUSED%'; v_msg := left(sqlerrm, 100);
    end;
    return query select 'where the policy refuses backorders a short line is refused by name', v_ok, v_msg;

    -- 8. A partial shipment promises what exists and keeps the shortage as the planner's.
    perform erp.set_config_value('sales.backorder_policy', '{"default":"partial_ship","by_channel":{}}'::jsonb,
      null, current_date, v_entity, null, 'wiring suite: ship what there is');
    v_alloc := erp.reserve_for_line(v_sol);
    select a.quantity, a.unmet_quantity, a.unmet_cause into v_q, v_unmet, v_cause from erp.allocation a where a.id = v_alloc;
    return query select 'where the policy ships partially the line is promised what exists and the shortage stays an exception',
      v_q = 40 and v_unmet = 0 and v_cause = 'partial_ship'
      and exists (select 1 from erp.planning_exception x where x.tenant_id = v_tenant and x.document_id = v_so and x.exception_kind = 'shortage'),
      format('promised %s (expected 40), unmet %s, cause %s', v_q, v_unmet, v_cause);

    -- 9. Credit: the tolerance widens the limit; block_at_limit switches the hold off.
    v_so := erp.open_document('sales_order', v_customer, null, v_site);
    v_sol := erp.add_document_line(v_so, v_plain, 14, 1000, 'exposure');
    perform erp.transition_document(v_so, 'submit');
    perform erp.transition_document(v_so, 'approve');
    insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, currency, credit_limit_minor, credit_status, is_blocked, valid_from)
    values (v_tenant, v_cust_role, v_entity, v_ccy, 10000, 'watch', false, current_date - 1);
    select * into cp from erp.credit_position(v_customer);
    v_r1 := cp.on_hold and cp.exposure_minor >= 14000;
    perform erp.set_config_value('sales.credit_control', '{"check_at_capture":true,"block_at_limit":true,"tolerance_pct":50,"overdue_days_block":30}'::jsonb,
      null, current_date, v_entity, null, 'wiring suite: half again');
    select * into cp from erp.credit_position(v_customer);
    v_r2 := not cp.on_hold;
    perform erp.set_config_value('sales.credit_control', '{"check_at_capture":true,"block_at_limit":false,"tolerance_pct":0,"overdue_days_block":30}'::jsonb,
      null, current_date, v_entity, null, 'wiring suite: no limit hold');
    select * into cp from erp.credit_position(v_customer);
    v_r3 := not cp.on_hold;
    return query select 'the credit policy''s tolerance widens the limit and block_at_limit switches the hold off',
      v_r1 and v_r2 and v_r3, format('held at the bare limit: %s; not held at 50%% tolerance: %s; not held with the limit hold off: %s', v_r1, v_r2, v_r3);

    -- 10. Credit at capture.
    perform erp.set_config_value('sales.credit_control', '{"check_at_capture":true,"block_at_limit":true,"tolerance_pct":0,"overdue_days_block":30}'::jsonb,
      null, current_date, v_entity, null, 'wiring suite: check when taken');
    v_ok := false; v_msg := null;
    begin
      perform erp.create_document('sales_order', v_entity, v_site, v_customer, current_date, v_ccy, 'ZZ-SO-HELD', '{}'::jsonb);
      v_msg := 'the order was taken';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_CREDIT_HOLD_AT_CAPTURE%'; v_msg := left(sqlerrm, 100);
    end;
    perform erp.set_config_value('sales.credit_control', '{"check_at_capture":false,"block_at_limit":true,"tolerance_pct":0,"overdue_days_block":30}'::jsonb,
      null, current_date, v_entity, null, 'wiring suite: check at release only');
    v_so := erp.create_document('sales_order', v_entity, v_site, v_customer, current_date, v_ccy, 'ZZ-SO-TAKEN', '{}'::jsonb);
    return query select 'a held customer''s order is refused when taken if the policy says so, and taken when it does not',
      v_ok and v_so is not null, v_msg;

    -- 11. Re-approval reads the organisation's tolerance where the chain states none.
    insert into erp.approval_chain (tenant_id, code, name, object_type, priority)
    values (v_tenant, 'zz-chain', 'Wiring chain', 'zz_object', 100) returning id into v_chain;
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status, effective_from, material_fields, value_field)
    values (v_tenant, v_chain, 1, 'active', current_date, '{}', 'total_minor') returning id into v_ver;
    insert into erp.approval_request (tenant_id, object_type, object_id, approval_chain_id, approval_chain_version_id, status, context, material_fingerprint, value_at_approval, decided_at)
    values (v_tenant, 'zz_object', v_obj, v_chain, v_ver, 'approved',
            jsonb_build_object('total_minor', 100000, 'party_id', v_party),
            erp.material_fingerprint(jsonb_build_object('total_minor', 100000, 'party_id', v_party), '{}', 'total_minor'),
            100000, now()) returning id into v_req;
    select required into v_r1 from erp.check_reapproval_required('zz_object', v_obj, jsonb_build_object('total_minor', 105000, 'party_id', v_party));
    select required, reason into v_r2, v_reason from erp.check_reapproval_required('zz_object', v_obj, jsonb_build_object('total_minor', 125000, 'party_id', v_party));
    select required into v_r3 from erp.check_reapproval_required('zz_object', v_obj, jsonb_build_object('total_minor', 100000, 'party_id', gen_random_uuid()));
    return query select 'a change within the organisation''s tolerance keeps its approval; beyond it, or a new party, voids it',
      not v_r1 and v_r2 and v_r3, format('5%% kept: %s; 25%% voided: %s (%s); party change voided: %s', not v_r1, v_r2, v_reason, v_r3);

    -- 12. A declared type nothing reads is dead configuration.
    insert into erp_ref.config_type (code, domain, module_code, name_key, description, value_schema, max_scope_level, is_singleton, default_value)
    values ('zz.unread', 'policy', 'inventory', 'config.zz.unread', 'A type this suite declares and nothing reads.',
            '{"type":"object"}'::jsonb, 'entity', true, '{}'::jsonb);
    return query select 'a configuration type nothing reads is reported as dead configuration',
      exists (select 1 from erp.dead_configuration_report() r
               where r.finding = 'a configuration type is declared and nothing reads it' and r.reference = 'zz.unread')
      and not exists (select 1 from erp.dead_configuration_report() r
                       where r.finding = 'a configuration type is declared and nothing reads it' and r.reference <> 'zz.unread'),
      'zz.unread reported; every shipped type has a reader';
    delete from erp_ref.config_type where code = 'zz.unread';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zzwire')
    and not exists (select 1 from erp_ref.config_type ct where ct.code = 'zz.unread'),
    'the organisation, its settings and the declared type rolled back';
end;
$$;

create or replace function erp_test.assert_configuration_wiring_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 13;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _configuration_wiring on commit drop as
    select * from erp_test.configuration_wiring_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _configuration_wiring;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_CONFIGURATION_WIRING_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_CONFIGURATION_WIRING_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('configuration wiring: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_configuration_wiring_suite() from public, anon, authenticated;
revoke all on function erp_test.configuration_wiring_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_configuration_wiring_suite();
select erp_test.assert_quality_logistics_suite();
select erp_test.assert_second_organisation_suite();
select erp_test.assert_door_isolation_suite();
select erp_test.assert_sales_depth_suite();
select erp_test.assert_allocation_policy_suite();
select erp_test.assert_identity_policy_suite();
select erp_test.assert_ownership_suite();
select erp.assert_no_dead_configuration();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
