set lock_timeout = '30s';

-- =============================================================================
-- 20260928400000  A transfer is three presses
-- -----------------------------------------------------------------------------
-- PR11, M6 and M7 (docs/spec/simplification-review.md §7, nodes I6 and I8):
-- the screens that decide a transfer, and the walk that proves what a
-- transfer costs, on top of M3 (20260928200000), which approves a transfer by
-- what it is worth and closes it when its goods have arrived.
--
-- ── WHAT CHANGES, AND WHERE ──────────────────────────────────────────────────
--
-- The screens (no door changes, no new public function):
--   * /inventory/transfers and /inventory/adjustments draw Approve and Reject
--     on a row waiting for approval, through erp_transition_document, only
--     where public.erp_available_transitions says the door would take the
--     move (src/components/erp/decision-moves.tsx). Nothing names a document
--     type: the adjustment's rows gain them the day its lifecycle has a
--     pending_approval state with approve and reject (M4). The driver
--     register already says approve and reject of the transfer order are the
--     screen's (20260928200000), so it is not restated.
--   * Stock's page draws three things done every day in its header (D15):
--     Raise a transfer order, Raise a stock adjustment, Raise count tasks.
--     The rest is behind More, and the strip's steps still carry the verbs
--     they name. Write off stays on the Correct step.
-- This migration is what those screens need of the database: the two words
-- the header says, seeded in English so each can be renamed.
--
-- The walk (M7):
--   * erp_test.transfer_walk walks a transfer by pressing, in a live
--     organisation, by people who are not administrators. Below the
--     organisation's threshold it is three presses by one person, raise,
--     despatch and receive, and it reads Closed with nobody pressing Close
--     and nobody asked to approve it. Over the threshold it is exactly one
--     press more, Approve, by a second person, which the screen offers to
--     that person and not to the one who raised it.
--   * erp_test.step_budget_suite case 12 holds the walk to that.
--   * The stock row of erp_meta.flow_budget keeps its numbers (6, 6, 5, 2)
--     and says where a transfer's cost is walked.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No door, table, lifecycle, chain, refusal or register restatement.
--   * Nothing of the adjustment's lifecycle, which is M4's (20260928300000).
--     This does not depend on it, and it does not depend on this.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The words Stock's header says
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A module page''s header, beside the verbs it does every day (20260928400000).'
  from (values
    ('More'),
    ('Less often')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The stock cycle's budget says where a transfer is walked
-- ─────────────────────────────────────────────────────────────────────────────

do $stock_budget$
declare
  v_n integer;
begin
  if exists (select 1 from erp_meta.flow_budget b
              where b.flow_code = 'stock' and position('20260928400000' in b.rationale) > 0) then
    return;
  end if;
  update erp_meta.flow_budget b
     set rationale =
       'The six actions over five steps are what the Stock screen''s strip draws, not what a count '
       'or a transfer costs. Both are walked by erp_test.step_budget_suite: a count at one press per '
       'place, each count inside its tolerance posting as it is recorded with nobody pressing Post '
       '(20260927400000); a transfer at three presses, raise, despatch and receive, closing itself '
       'with nobody pressing Close, and one press more by a second person when it is over the '
       'organisation''s threshold (20260928400000).'
   where b.flow_code = 'stock'
     and b.budget = 6 and b.decision_steps = 6 and b.stages = 5 and b.stages_without_a_list = 2
     and b.rationale = 'The six actions over five steps are what the Stock screen''s strip draws, not what a count '
                       'costs. A count is walked by erp_test.step_budget_suite at one press per place, each count '
                       'inside its tolerance posting as it is recorded with nobody pressing Post (20260927400000). '
                       'The plan''s three for a transfer is PR11''s.';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the stock flow budget is not 6/6/5/2 with the rationale 20260927400000 wrote (% row(s))', v_n;
  end if;
end
$stock_budget$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. A transfer, walked: erp_test.transfer_walk
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.transfer_walk()
returns jsonb
language plpgsql
set search_path = ''
as $function$
declare
  c_undo    constant text := 'CLOVEERP_TRANSFER_WALK_UNDO';
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code    text;
  a1        uuid := gen_random_uuid();   -- the administrator, who sets up
  s_mov     uuid := gen_random_uuid();   -- moves stock
  s_app     uuid := gen_random_uuid();   -- moves stock, and approves
  p_mov     uuid;
  p_app     uuid;
  r         record;
  res       jsonb;
  v_ccy     char(3);
  v_uom     uuid;
  v_item    uuid;
  s_a       uuid;
  s_b       uuid;
  l_a       uuid;
  v_ok      boolean;
  t_small   uuid;
  t_big     uuid;
  v_got     text;
  v_steps   jsonb := '[]'::jsonb;   -- below the threshold
  v_bsteps  jsonb := '[]'::jsonb;   -- over it
  v_subs    uuid[] := '{}';
  v_bsubs   uuid[] := '{}';
  v_block   text;
  v_raiser_offered boolean;
  v_approver_offered boolean;
  v_out     jsonb;
begin
  -- Two transfers of one organisation, walked by pressing (20260928400000):
  -- one worth less than the threshold the organisation set, one worth more.
  -- Each press is a public door, made by the person the screen offers it to.
  begin
    v_code := 'zzxfer-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'Transfer walk', 'admin@' || v_code || '.test', 'Walk Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    select e.base_currency into v_ccy from erp.entity e where e.id = r.entity_id;

    -- Two sites of one company, and two hundred at five pounds each at the
    -- first, as a fixture.
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (r.tenant_id, r.entity_id, 'ZZ-A', 'Despatching', 'warehouse', 'GB', 'active') returning id into s_a;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (r.tenant_id, r.entity_id, 'ZZ-B', 'Receiving', 'warehouse', 'GB', 'active') returning id into s_b;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, s_a, 'ZZ-A-BULK', 'A bulk', 'bulk', true, 'active') returning id into l_a;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, s_b, 'ZZ-B-IN', 'B in', 'receiving', false, 'active');
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-W', 'Widget', v_uom, 'active') returning id into v_item;
    perform erp.receive_cost(v_item, s_a, 200, 500, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
      to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (r.tenant_id, r.entity_id, s_a, 'receipt_no_order', v_item, l_a, 'available', 200, v_uom, 500,
      v_ccy, 'OPENING');

    -- Two people with the inventory role, neither an administrator.
    res := public.erp_invite_principal('mover@' || v_code || '.test', 'Mo Mover');
    p_mov := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_mov, 'inventory', null, null, 'moves stock');
    perform set_config('request.jwt.claims', json_build_object('sub', s_mov)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('approver@' || v_code || '.test', 'Ada Approver');
    p_app := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_app, 'inventory', null, null, 'moves stock and approves transfers');
    perform set_config('request.jwt.claims', json_build_object('sub', s_app)::text, true);
    perform erp.claim_invitation(res ->> 'token');

    -- The organisation's threshold, ten pounds at cost, set as the
    -- Configuration screen sets it; then live.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_propose_approval_chain('transfer_order_value', 'Transfer order value approval', 'document',
      jsonb_build_array(jsonb_build_object('seq', 1, 'code', 'stock_controller', 'name', 'Stock controller',
        'role', 'inventory', 'min_approvals', 1,
        'condition', jsonb_build_object('>', jsonb_build_array(jsonb_build_object('var', 'value_at_cost_minor'), 1000)))),
      jsonb_build_object('==', jsonb_build_array(jsonb_build_object('var', 'document_type'), 'transfer_order')),
      'value_at_cost_minor', 100, 'a threshold of ten pounds at cost');
    v_ok := (res ->> 'in_force')::boolean;
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

    -- ─────────────────────────────────────────────────────────────────────
    -- Below the threshold: one at five pounds. Raise, despatch, receive.
    -- ─────────────────────────────────────────────────────────────────────
    perform set_config('request.jwt.claims', json_build_object('sub', s_mov)::text, true);
    begin
      res := public.erp_raise_transfer_order(s_a, s_b,
               jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1)), null, 'walk');
      t_small := (res ->> 'document_id')::uuid;
      v_steps := v_steps || jsonb_build_object('door', 'erp_raise_transfer_order', 'person', 'mover', 'result', res ->> 'state');
      v_subs := v_subs || s_mov;
      res := public.erp_despatch_transfer(t_small);
      v_steps := v_steps || jsonb_build_object('door', 'erp_despatch_transfer', 'person', 'mover', 'result', res ->> 'state');
      v_subs := v_subs || s_mov;
      res := public.erp_receive_transfer(t_small);
      v_steps := v_steps || jsonb_build_object('door', 'erp_receive_transfer', 'person', 'mover', 'result', res ->> 'state');
      v_subs := v_subs || s_mov;
    exception when others then
      v_block := format('below the threshold, press %s: %s', jsonb_array_length(v_steps) + 1, left(sqlerrm, 300));
    end;

    -- ─────────────────────────────────────────────────────────────────────
    -- Over it: one at twenty-five pounds. Raise; Approve, by the other
    -- person; despatch; receive.
    -- ─────────────────────────────────────────────────────────────────────
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_mov)::text, true);
        res := public.erp_raise_transfer_order(s_a, s_b,
                 jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5)), null, 'walk');
        t_big := (res ->> 'document_id')::uuid;
        v_bsteps := v_bsteps || jsonb_build_object('door', 'erp_raise_transfer_order', 'person', 'mover', 'result', res ->> 'state');
        v_bsubs := v_bsubs || s_mov;

        -- Whether the screen draws Approve for each of them: the move would
        -- go through (src/lib/decision-moves.ts reads the same keys).
        select coalesce(bool_or(x ->> 'code' = 'approve'), false) into v_raiser_offered
          from jsonb_array_elements(public.erp_available_transitions(t_big)) x
         where (x ->> 'permitted')::boolean and (x ->> 'guard_passes')::boolean
           and not (x ->> 'is_automatic')::boolean and x ->> 'refused' is null;
        perform set_config('request.jwt.claims', json_build_object('sub', s_app)::text, true);
        select coalesce(bool_or(x ->> 'code' = 'approve'), false) into v_approver_offered
          from jsonb_array_elements(public.erp_available_transitions(t_big)) x
         where (x ->> 'permitted')::boolean and (x ->> 'guard_passes')::boolean
           and not (x ->> 'is_automatic')::boolean and x ->> 'refused' is null;

        res := public.erp_transition_document(t_big, 'approve', null);
        v_bsteps := v_bsteps || jsonb_build_object('door', 'erp_transition_document', 'person', 'approver', 'result', res ->> 'state');
        v_bsubs := v_bsubs || s_app;

        perform set_config('request.jwt.claims', json_build_object('sub', s_mov)::text, true);
        res := public.erp_despatch_transfer(t_big);
        v_bsteps := v_bsteps || jsonb_build_object('door', 'erp_despatch_transfer', 'person', 'mover', 'result', res ->> 'state');
        v_bsubs := v_bsubs || s_mov;
        res := public.erp_receive_transfer(t_big);
        v_bsteps := v_bsteps || jsonb_build_object('door', 'erp_receive_transfer', 'person', 'mover', 'result', res ->> 'state');
        v_bsubs := v_bsubs || s_mov;
      exception when others then
        v_block := format('over the threshold, press %s: %s', jsonb_array_length(v_bsteps) + 1, left(sqlerrm, 300));
      end;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_out := jsonb_build_object(
      'threshold_set', coalesce(v_ok, false),
      'live', erp.tenant_is_live(r.tenant_id),
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'over_presses', jsonb_array_length(v_bsteps),
      'over_people', (select count(distinct u) from unnest(v_bsubs) u),
      'administrators_pressing', (select count(*) from erp.organisation_administrators() a
                                   where a.app_user_id in (p_mov, p_app)),
      'results', (select jsonb_agg(s ->> 'result') from jsonb_array_elements(v_steps) s),
      'over_results', (select jsonb_agg(s ->> 'result') from jsonb_array_elements(v_bsteps) s),
      'state', erp.document_state_code(t_small),
      'over_state', erp.document_state_code(t_big),
      -- Nobody asked below the threshold: the request asked nobody.
      'asked', (select count(*) from erp.approval_task t
                  join erp.approval_request q on q.id = t.approval_request_id
                 where q.tenant_id = r.tenant_id and q.object_id = t_small and t.status <> 'skipped'),
      -- Closed on the fact that it all arrived, not by a press.
      'closed_by', (select l.guard_data -> 'derived' ->> 'fact' from erp.state_transition_log l
                     where l.tenant_id = r.tenant_id and l.object_id = t_small and l.transition_code = 'close'),
      'over_closed_by', (select l.guard_data -> 'derived' ->> 'fact' from erp.state_transition_log l
                          where l.tenant_id = r.tenant_id and l.object_id = t_big and l.transition_code = 'close'),
      'approve_offered_to_raiser', v_raiser_offered,
      'approve_offered_to_approver', v_approver_offered,
      'in_transit', coalesce(erp.transfer_in_transit_quantity(t_small), 0)
                    + coalesce(erp.transfer_in_transit_quantity(t_big), 0),
      'arrived', (select coalesce(sum(m.quantity), 0) from erp.stock_movement m
                   where m.tenant_id = r.tenant_id and m.document_id in (t_small, t_big)
                     and m.site_id = s_b and m.to_status = 'available'),
      'blocked', v_block,
      'steps', v_steps,
      'over_steps', v_bsteps);

    raise exception using message = c_undo;
  exception when others then
    if sqlerrm <> c_undo then
      v_out := jsonb_build_object('presses', 0, 'people', 0, 'blocked',
                 'setting up: ' || left(sqlerrm, 300), 'steps', v_steps, 'over_steps', v_bsteps);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$function$;

revoke all on function erp_test.transfer_walk() from public, anon;

comment on function erp_test.transfer_walk() is
  'Two transfers walked by pressing (20260928400000), in a live organisation that has set a threshold, by '
  'two people with the inventory role who are not administrators: one under the threshold raised, '
  'despatched and received by one person, and one over it with Approve pressed by the other. Returns '
  'the presses, the people, how each ended and what closed it, who was asked, and whether the screen '
  'offers Approve to each person on the one waiting. Rolled back. For erp_test.step_budget_suite, case 12.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. step_budget_suite case 12
-- ─────────────────────────────────────────────────────────────────────────────

do $step_budget_suite$
declare
  v_sig constant text := 'erp_test.step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 11;
  v_cases   integer := 0;
$o$,
    $n$  c_expected constant integer := 12;
  v_cases   integer := 0;
$n$,
    $o$  v_count   jsonb;
begin
$o$,
    $n$  v_count   jsonb;
  v_xfer    jsonb;
begin
$n$,
    $o$  if v_cases <> c_expected then
$o$,
    $n$  -- ── 12. A transfer, walked ────────────────────────────────────────────
  --
  -- The plan's target is three (20260928400000). People who are not
  -- administrators, in a live organisation that has set its threshold. Under
  -- it: raise, despatch, receive, by one person; nobody is asked to approve
  -- it, and it reads Closed with nobody pressing Close. Over it: exactly one
  -- press more, Approve, by a second person, which the screen offers to them
  -- and not to the person who raised it.
  v_xfer := erp_test.transfer_walk();

  v_cases := v_cases + 1;
  case_name := 'a transfer under the threshold is three presses by one person, raise, despatch and receive, and closes itself with nobody asked to approve it; one over the threshold is one press more, Approve, by somebody else';
  passed := coalesce(v_xfer ->> 'blocked' is null
            and (v_xfer ->> 'threshold_set')::boolean
            and (v_xfer ->> 'live')::boolean
            and (v_xfer ->> 'administrators_pressing')::integer = 0
            and (v_xfer ->> 'presses')::integer = 3
            and (v_xfer ->> 'people')::integer = 1
            and v_xfer -> 'results' = '["approved", "in_transit", "closed"]'::jsonb
            and v_xfer ->> 'state' = 'closed'
            and (v_xfer ->> 'asked')::integer = 0
            and v_xfer ->> 'closed_by' = 'erp.transfer_is_received_in_full'
            and (v_xfer ->> 'over_presses')::integer = 4
            and (v_xfer ->> 'over_people')::integer = 2
            and v_xfer -> 'over_results' = '["pending_approval", "approved", "in_transit", "closed"]'::jsonb
            and v_xfer ->> 'over_state' = 'closed'
            and v_xfer ->> 'over_closed_by' = 'erp.transfer_is_received_in_full'
            and not (v_xfer ->> 'approve_offered_to_raiser')::boolean
            and (v_xfer ->> 'approve_offered_to_approver')::boolean
            and (v_xfer ->> 'in_transit')::numeric = 0
            and (v_xfer ->> 'arrived')::numeric = 6, false);
  detail := coalesce('blocked at ' || (v_xfer ->> 'blocked') || '; ', '')
            || format('threshold set %s, live %s, %s administrator(s) pressing; under it %s press(es) by %s person(s), %s, closed by %s, %s asked; over it %s press(es) by %s people, %s, closed by %s; Approve offered to the raiser %s and to the approver %s; %s on the road, %s arrived',
                      coalesce(v_xfer ->> 'threshold_set', 'unknown'), coalesce(v_xfer ->> 'live', 'unknown'),
                      coalesce(v_xfer ->> 'administrators_pressing', 'an unknown number of'),
                      coalesce(v_xfer ->> 'presses', '0'), coalesce(v_xfer ->> 'people', '0'),
                      coalesce(v_xfer ->> 'results', '[]'), coalesce(v_xfer ->> 'closed_by', 'nothing'),
                      coalesce(v_xfer ->> 'asked', 'an unknown number'),
                      coalesce(v_xfer ->> 'over_presses', '0'), coalesce(v_xfer ->> 'over_people', '0'),
                      coalesce(v_xfer ->> 'over_results', '[]'), coalesce(v_xfer ->> 'over_closed_by', 'nothing'),
                      coalesce(v_xfer ->> 'approve_offered_to_raiser', 'unknown'), coalesce(v_xfer ->> 'approve_offered_to_approver', 'unknown'),
                      coalesce(v_xfer ->> 'in_transit', 'unknown'), coalesce(v_xfer ->> 'arrived', 'nothing'));
  return next;

  if v_cases <> c_expected then
$n$];
  v_hits integer;
begin
  -- Applied already: the case is there.
  if position('erp_test.transfer_walk()' in v_def) > 0 then
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$step_budget_suite$;

do $assert_step_budget_suite$
declare
  v_sig constant text := 'erp_test.assert_step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- Counting, walked, is case 11 (20260927400000).
  c_expected constant integer := 11;
$o$;
  v_new constant text := $n$  -- Counting, walked, is case 11 (20260927400000); a transfer, walked,
  -- is case 12 (20260928400000).
  c_expected constant integer := 12;
$n$;
  v_hits integer;
begin
  if position(v_new in v_def) > 0 then
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % expected-count anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert_step_budget_suite$;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
