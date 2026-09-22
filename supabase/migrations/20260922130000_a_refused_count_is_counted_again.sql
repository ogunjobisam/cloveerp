set lock_timeout = '30s';

-- =============================================================================
-- 20260922130000  A refused count is counted again
-- -----------------------------------------------------------------------------
-- erp.record_count() refuses a task that is not 'open'
-- (20260829240000_inventory_operations.sql:1172), and nothing anywhere returns
-- a task to 'open'. So the rejected arm of erp.settle_approval_outcome() is a
-- one-way door: an approver who refuses a count has not asked for it to be
-- done again, they have destroyed it. The place is never counted, the variance
-- is never posted, and erp.count_accuracy_report() carries the task for ever as
-- a count that was neither accurate nor corrected.
--
-- Rejecting is the right answer often enough — "that figure is wrong, go and
-- count it again" is the ordinary outcome of a variance the approver does not
-- believe. It needs the second half.
--
-- ── WHAT REOPENING HAS TO DO ─────────────────────────────────────────────────
--
-- Not merely set the status. A count task carries the expectation it was raised
-- against, and that expectation has aged: erp.note_count_lock_movement() was
-- accumulating movement_during only while the lock was live, and the lock was
-- released when the count was refused (20260914070000 and the rejected arm of
-- erp.settle_approval_outcome()). Anything that moved through the place between
-- the refusal and the recount was counted by nobody.
--
-- So the task is re-raised in place, against the position as the records hold
-- it now, exactly as erp.raise_count_tasks() would raise it today:
--
--   * expected_quantity re-read from erp.stock_balance,
--   * committed_quantity re-read from the live allocation lines,
--   * movement_during back to zero, because the new expectation is current,
--   * counted_quantity, variance, within_tolerance, counted_at and counted_by
--     cleared — they describe the count that was refused, not the one asked for,
--   * approval_request_id cleared, so the refused request stops being this
--     task's request. erp.settle_approval_outcome() already anticipates this
--     in its own words: "a request superseded by a recount does not move the
--     recount". Its guard is on approval_request_id, and clearing the column is
--     what makes that sentence true.
--
-- and a fresh lock is taken, so movement during the recount is accumulated
-- again.
--
-- ── WHY inventory.adjust AND NOT inventory.count ─────────────────────────────
--
-- inventory.count is a light permission: it is what a scanner in the aisle
-- carries. The person who counted wrong should not be the person who decides
-- their count gets another go — that is the approver's refusal being undone by
-- its subject. Reopening is an act on an approval outcome and it re-reads the
-- expectation, so it asks for inventory.adjust, which is what posting the
-- variance asks for and what the count's approver already holds.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The door
-- ═════════════════════════════════════════════════════════════════════════════

-- Invoker rights, like erp.record_count() next door. The tenant is resolved by
-- erp.require_tenant_id() and every statement is scoped by it, so row security
-- is the enforcement rather than something this function has to step around.
create or replace function erp.recount_task(p_task_id uuid)
returns erp.count_task_status
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  t           erp.count_task%rowtype;
  v_expect    numeric;
  v_committed numeric;
begin
  select * into t from erp.count_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_TASK: %', p_task_id using errcode = '23503';
  end if;

  if t.status <> 'rejected' then
    raise exception
      'CLOVEERP_COUNT_TASK_NOT_REJECTED: % is %, and only a count an approver '
      'refused is sent back to be counted again', p_task_id, t.status
      using errcode = '23514',
            hint = 'An open count is recorded, a counted one waits for its approver, '
                   'and a posted one is in the ledger. Raise a new count for the place instead.';
  end if;

  perform erp.authorise('inventory.adjust', null, t.site_id, null,
                        'count_task', p_task_id);

  -- The position as the records hold it now, not as they held it when the
  -- refused count was raised. Same shape as erp.raise_count_tasks(): what the
  -- company holds in that place, in that unit, under that owner.
  select coalesce(sum(b.quantity), 0) into v_expect
    from erp.stock_balance b
   where b.tenant_id = v_tenant
     and b.site_id = t.site_id
     and b.location_id is not distinct from t.location_id
     and b.item_id = t.item_id
     and b.batch_id is not distinct from t.batch_id
     and b.owner_party_id is not distinct from t.owner_party_id
     and b.container_id is not distinct from t.container_id;

  select coalesce(sum(al.quantity), 0) into v_committed
    from erp.allocation_line al
    join erp.allocation a on a.id = al.allocation_id
   where al.tenant_id = v_tenant
     and a.item_id = t.item_id
     and al.location_id is not distinct from t.location_id
     and al.status in ('reserved', 'committed', 'picked');

  update erp.count_task c
     set status              = 'open',
         expected_quantity   = v_expect,
         committed_quantity  = v_committed,
         movement_during     = 0,
         counted_quantity    = null,
         variance            = null,
         within_tolerance    = null,
         counted_at          = null,
         counted_by          = null,
         approval_request_id = null,
         updated_at          = now()
   where c.tenant_id = v_tenant and c.id = p_task_id;

  -- A lock left open on a refused count would have gone on accumulating
  -- movement into a task nobody was counting; releasing before inserting keeps
  -- the live-lock index's one-lock-per-place meaning true either way.
  update erp.count_lock l
     set released_at = now(), updated_at = now()
   where l.tenant_id = v_tenant and l.count_task_id = p_task_id
     and l.released_at is null;

  insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id)
  values (v_tenant, p_task_id, t.location_id, t.item_id);

  -- No reason argument, and none needed: the reason a count is being done
  -- again is the comment the approver left when they refused it, which
  -- erp.decide_approval_task() already recorded on the approval task. Asking
  -- for it twice would be a second place for it to disagree with the first.
  -- What changed here is written by the row trigger erp.apply_audit_coverage()
  -- maintains over erp.count_task, column by column.

  return 'open'::erp.count_task_status;
end;
$$;

comment on function erp.recount_task(uuid) is
  'Sends a count an approver refused back to be counted again, re-read against '
  'the position as the records hold it now. Asks for inventory.adjust: undoing '
  'a refusal is the approver''s act, not the counter''s.';

create or replace function public.erp_recount_task(p_task_id uuid)
returns erp.count_task_status
language sql
set search_path = ''
as $$ select erp.recount_task(p_task_id) $$;

comment on function public.erp_recount_task(uuid) is
  'Desk door for erp.recount_task().';

-- The door writes, so it is named on the write allow-list with the gate that
-- decides it — the same shape as erp_record_count and erp_raise_count_tasks
-- beside it, whose gates are the erp functions they call.
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_recount_task', 'erp.recount_task',
   'Sends a count an approver refused back to be counted again. Refuses any task '
   'that is not rejected, asks erp.authorise() for inventory.adjust on the task''s '
   'site, and writes only that task and its count lock.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

revoke all on function public.erp_recount_task(uuid) from public, anon;
grant execute on function public.erp_recount_task(uuid) to authenticated, service_role;

select erp.register_refusal('CLOVEERP_COUNT_TASK_NOT_REJECTED',
  'Sending a count back to be counted again when its approver has not refused it.',
  'Counting again is what happens to a figure an approver did not believe. A count that is still open has not been recorded yet, one that is waiting has not been decided, and one that is posted is already in the ledger and its variance has moved stock — reopening any of those would either lose a figure somebody entered or unpick a posting.',
  'If the place needs counting again, raise a new count for it from Counting. If this count is waiting for a decision, decide it first: refusing it is what sends it back.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Cases 7 to 11 of erp_test.count_tolerance_suite(), which 20260922120000
-- raised. Appended rather than restated for the usual reason: the suite is one
-- routine and its earlier cases are the tolerance node's, so the count is
-- re-pinned here and the two nodes share one wrapper.

create or replace function erp_test.recount_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  r        record;
  it       record;
  v_uom    uuid; v_site uuid; v_recv uuid; v_sup uuid; v_item uuid;
  v_cs     uuid; v_grn uuid; v_task uuid; v_req uuid;
  v_cases  integer := 0;
  v_status text; v_reopened text; v_refusal text; v_hint text;
  v_expect numeric; v_expect_after numeric; v_moved numeric;
  v_locks  integer;
  v_within boolean;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-rec-' || v_hex, 'Recount suite',
    'admin@zz-rec-' || v_hex || '.test', 'Recount Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cs := erp.configure_finance();
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  v_cs := erp.configure_inventory('average');
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  v_cs := erp.configure_procurement(1000000);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_sup, 'supplier', 'active');
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'REC', 'Recounted widget', v_uom, 'active') returning id into v_item;

  for it in
    select pi.object_kind, pi.object_key, pi.payload
      from erp_ref.pack_item pi
     where pi.pack_code = 'base' and pi.object_kind = 'count_programme'
       and pi.object_key = 'CYCLE_A'
  loop
    v_cs := erp.create_change_set('zzrec-band-' || v_hex, 'Counting band from the base pack',
                                  'CYCLE_A as the base pack plans it.');
    perform erp.add_change_set_item(v_cs, it.object_kind, it.object_key, it.payload,
                                    'upsert', null, 'the recount suite');
    perform erp.submit_change_set(v_cs);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
  end loop;

  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 1000, 100, 'stock to count');
  perform erp.transition_document(v_grn, 'post', 'recount suite');

  -- A count well outside CYCLE_A's bands, so it raises a variance approval, and
  -- that request refused by hand: the approver does not believe the figure.
  perform erp.raise_count_tasks('CYCLE_A');
  select t.id into v_task
    from erp.count_task t
    join erp.count_programme pg on pg.id = t.count_programme_id
   where t.tenant_id = r.tenant_id and t.item_id = v_item
     and t.status = 'open' and pg.code = 'CYCLE_A'
   limit 1;
  v_status := erp.record_count(v_task, 400)::text;
  select t.approval_request_id into v_req
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;

  -- ── 1. A refused count is rejected, and its lock is released ───────────────
  v_cases := v_cases + 1;
  for it in select tk.id from erp.approval_task tk
             where tk.tenant_id = r.tenant_id
               and tk.approval_request_id = v_req and tk.status = 'pending'
  loop
    perform erp.decide_approval_task(it.id, false, 'that figure is not right, count it again');
  end loop;
  perform erp.settle_approval_outcome(v_req);
  select t.status::text into v_status
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  select count(*) into v_locks
    from erp.count_lock l
   where l.tenant_id = r.tenant_id and l.count_task_id = v_task and l.released_at is null;
  case_name := 'an approver who refuses a count leaves it rejected with no live lock';
  passed := v_status = 'rejected' and v_locks = 0;
  detail := format('the task is %s with %s live lock(s)', v_status, v_locks);
  return next;

  -- ── 2. And recording against it is refused ────────────────────────────────
  -- The dead end this node exists to open. Asserted rather than assumed,
  -- because if erp.record_count() ever accepted a rejected task the recount
  -- door would be solving a problem that had gone away.
  v_cases := v_cases + 1;
  v_refusal := null;
  begin
    perform erp.record_count(v_task, 995);
  exception when others then
    v_refusal := sqlerrm;
  end;
  case_name := 'a rejected count cannot simply be recorded again: that is the dead end';
  passed := v_refusal like 'CLOVEERP_COUNT_TASK_NOT_OPEN%';
  detail := coalesce(left(v_refusal, 120), 'it was recorded, and the dead end is not there');
  return next;

  -- ── 3. Stock moves while the count is dead ────────────────────────────────
  -- Nothing is accumulating movement_during: the lock went when the count was
  -- refused. This is why reopening re-reads rather than merely reopens.
  v_cases := v_cases + 1;
  select t.expected_quantity into v_expect
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 250, 100, 'arrived while the count was refused');
  perform erp.transition_document(v_grn, 'post', 'recount suite');
  select t.movement_during into v_moved
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  case_name := 'stock that moves while a count is refused reaches the task through nothing';
  passed := v_expect = 1000 and v_moved = 0;
  detail := format('expected %s on the refused task, movement_during %s, 250 having arrived',
                   v_expect, v_moved);
  return next;

  -- ── 4. Reopening re-reads the expectation ─────────────────────────────────
  v_cases := v_cases + 1;
  v_reopened := erp.recount_task(v_task)::text;
  select t.expected_quantity, t.movement_during, t.counted_quantity, t.within_tolerance,
         t.approval_request_id is null
    into v_expect_after, v_moved, v_expect, v_within, passed
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  select count(*) into v_locks
    from erp.count_lock l
   where l.tenant_id = r.tenant_id and l.count_task_id = v_task and l.released_at is null;
  case_name := 'reopening re-reads the expectation, clears the refused figure and takes a fresh lock';
  passed := passed and v_reopened = 'open' and v_expect_after = 1250 and v_moved = 0
        and v_expect is null and v_within is null and v_locks = 1;
  detail := format('reopened %s, expected %s (was 1000), movement_during %s, counted %s, '
                   'within_tolerance %s, %s live lock(s)',
                   v_reopened, v_expect_after, v_moved,
                   coalesce(v_expect::text, 'nothing'), coalesce(v_within::text, 'nothing'), v_locks);
  return next;

  -- ── 5. And the reopened count is counted, against the new figure ──────────
  -- 1245 of 1250 is five short, inside CYCLE_A's percentage — the tolerance
  -- node's own acceptance, arrived at through the recount. Against the old
  -- expectation of 1000 the same figure would be 245 over and refused, so this
  -- case also holds that the re-read is the figure that decides.
  v_cases := v_cases + 1;
  v_status := erp.record_count(v_task, 1245)::text;
  select t.within_tolerance into v_within
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  case_name := 'the reopened count is recorded against the new expectation and passes on it';
  passed := v_status = 'approved' and v_within;
  detail := format('counted 1245 of 1250 under CYCLE_A: %s, within_tolerance %s', v_status, v_within);
  return next;

  -- ── 6. The refused request does not move the recount ──────────────────────
  -- erp.settle_approval_outcome() says so in its own comment. It has two
  -- guards, approval_request_id and status = 'pending_approval', and this case
  -- holds the pair rather than either one: settling the refused request a
  -- second time after the recount has been approved must not drag it back.
  -- Removing the request id alone still passes here, because the status guard
  -- catches it — that arm is held by case 4, which reads the column directly.
  -- What this case would catch is the status guard going, or the whole rejected
  -- arm being widened to move any task the request names.
  v_cases := v_cases + 1;
  perform erp.settle_approval_outcome(v_req);
  select t.status::text into v_status
    from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_task;
  case_name := 'settling the refused request again does not drag the recount back to rejected';
  passed := v_status = 'approved';
  detail := format('after settling the old request a second time the task is %s', v_status);
  return next;

  -- ── 7. And a count that is not rejected is not reopened ───────────────────
  v_cases := v_cases + 1;
  v_refusal := null; v_hint := null;
  begin
    perform erp.recount_task(v_task);
  exception when others then
    v_refusal := sqlerrm;
    get stacked diagnostics v_hint = pg_exception_hint;
  end;
  case_name := 'an approved count is not sent back to be counted again, and the refusal is registered';
  passed := v_refusal like 'CLOVEERP_COUNT_TASK_NOT_REJECTED%'
        and v_hint is not null
        and exists (select 1 from erp_ref.refusal f
                     where f.code = 'CLOVEERP_COUNT_TASK_NOT_REJECTED');
  detail := coalesce(left(v_refusal, 140), 'it was reopened');
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 8. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-rec-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its stock and its count tasks');
  return next;

  if v_cases <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: recount_suite ran % cases, expected 8 — %',
      v_cases, coalesce(v_fixture, 'no case was skipped');
  end if;
end;
$$;

create or replace function erp_test.assert_recount_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ')
           filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.recount_suite() s;

  if v_total <> 8 then
    raise exception 'CLOVEERP_RECOUNT_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_RECOUNT_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Read the case that failed. A refused count that cannot be counted again is the defect this suite exists for.';
  end if;
end;
$$;

comment on function erp_test.recount_suite() is
  'A count an approver refused is sent back, re-read against the records as they stand, and counted again.';

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

-- erp_test.assert_recount_suite() is deliberately not called here. A suite run
-- inside its own migration runs the definition from that file for ever, and a
-- replay from an empty database dies on it rather than on anything a later
-- migration could repair — which is what 20260920310000 and 20260921715000 had
-- to undo. erp.ci_check_catalogue() gathers every no-argument assert_% in
-- erp_test, so the build runs this one on every pull request without being
-- asked, and erp.assert_ci_coverage() above refuses a check that exists and is
-- never run.
