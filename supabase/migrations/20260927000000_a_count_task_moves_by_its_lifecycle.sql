set lock_timeout = '30s';

-- =============================================================================
-- 20260927000000  A count task moves by its lifecycle
-- -----------------------------------------------------------------------------
-- PR10, M1a: node I1 of docs/spec/simplification-review.md, first half. Built
-- the way PR7 M1 (20260924400000) moved the works order, and checked against
-- the built database before it was written.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A count task had no lifecycle. erp.count_task.status is an enum, and four
-- routines moved a task by writing it: erp.record_count(), erp.recount_task(),
-- erp.post_count() and erp.settle_approval_outcome(). No transition code, no
-- permission named on any move, and not one line in the state transition log.
-- erp.lifecycle_column_writer_register() allowed all four by name
-- (20260926000000) until this node could take them away.
--
-- Reading the bodies found three more things:
--
--   (a) erp.raise_count_tasks() skipped a place with a task open, counted or
--       waiting for approval, and not one approved and not yet posted. Raising
--       again over an approved count put a second task and a second live lock
--       on the same place, and the two then split what moved through it.
--   (b) `counted` was a dead end. A count outside its tolerance under a
--       programme with no approval chain stops there, and nothing could move
--       it: recount took only a rejected task, and posting only an approved one.
--   (c) `cancelled` was never set. erp.generate_count_tasks() waits while any
--       task of the programme is open, so one task nobody was ever going to
--       count stopped the programme's scheduled counting for good.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * The count task's lifecycle, authored as configuration like every other
--     cycle: erp.count_task_lifecycle_item(), object type count_task, code
--     count_task_lifecycle (not `count`: that is the retired base-pack machine
--     erp.transition_driver_register() still names). Installed by
--     erp.configure_inventory() for a new organisation and offered as version
--     6 of inventory-operations to one on version 5. Every move names the
--     permission its door already asked for.
--   * Two moves are the system's, not the person's, and take their authority
--     from a fact, as decision 6 (20260922380000) lets a move do:
--       - approve and reject are made by erp.settle_approval_outcome() when the
--         variance's approval request is decided. The approver is authorised
--         by being the one the task was assigned to, whatever role the
--         programme names, and holds no inventory permission of necessity.
--       - a count confirmed on the scanner, recorded by erp.record_count()
--         while erp.drain_device_actions() applies the operator's own queued
--         count, is authorised by inventory.scan, as the door always was.
--     erp.derived_move_fact() names both, and reads each fact again with the
--     task's state locked.
--   * One routine moves a task, erp.move_count_task(). A task that started a
--     lifecycle moves by its transition, through the engine, and the column
--     follows; one raised before its organisation took the lifecycle moves by
--     its column as it always has. The four movers call it, so the column is
--     written in one place and the writer register names that one.
--   * Raising a task starts its lifecycle where the organisation has one.
--   * (a) Raising skips a place whose count is approved and not yet posted.
--   * (b) A counted task is sent back to be counted again by erp.recount_task().
--   * (c) erp_cancel_count_task(): a task open, counted or refused is
--     cancelled, with a reason, and its count lock released.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * The retired base-pack `count` machine and its register rows stay, as the
--     works order's did: removing them is a reseed of configuration an
--     organisation may hold, which is the dead-configuration pull request's.
--   * erp.assert_every_transition_is_driven() reads document lifecycles only,
--     and erp.transition_driver_register() takes a screen, a routine or
--     nothing — it carries no row for works_order_lifecycle either. What fires
--     each move is proved by erp_test.count_lifecycle_suite instead: every
--     move the lifecycle declares is named by a door that calls
--     erp.move_count_task().
--   * The screen. erp_cancel_count_task is registered as waiting for one
--     (erp_meta.api_only_door, pending_screen); the words it will say are
--     seeded below.
--   * A task cancelled before its organisation took the lifecycle has no
--     history to carry its reason, and count_task has no column for one. The
--     reason is asked for, and kept, only where there is a lifecycle.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds, and the one it widens
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_COUNT_TASK_LIFECYCLE_DISAGREES',
  'Moving a count task whose lifecycle, as configured, arrives somewhere other than the count expects.',
  'The organisation''s count task lifecycle has been changed so that a move ends in a state the count does not have.',
  'Restore the count task lifecycle on the Configuration screen, or ask whoever changed it.');

select erp.register_refusal('CLOVEERP_COUNT_TASK_NOT_CANCELLABLE',
  'Cancelling a count that is waiting for its approver, approved, posted or already cancelled.',
  'A count waiting for a decision belongs to its approver until they decide it, an approved one is posted, and a posted one has already moved stock.',
  'Decide a waiting count first: refused, it can be counted again or cancelled. Post an approved one.');

select erp.register_refusal('CLOVEERP_COUNT_CANCELLATION_NEEDS_A_REASON',
  'Cancelling a count without saying why.',
  'A cancelled count leaves its place uncounted until the next one is raised, and the reason is what somebody reading the count later has to go on.',
  'Say why the count is being cancelled.');

-- Counted as well as rejected (b): the wording follows the door.
select erp.register_refusal('CLOVEERP_COUNT_TASK_NOT_REJECTED',
  'Sending a count back to be counted again when its approver has not refused it and it was not counted outside its tolerance.',
  'Counting again is what happens to a figure nobody can accept: one an approver refused, or one outside its tolerance with nobody to approve it. A count that is still open has not been recorded yet, one that is waiting has not been decided, and one that is approved or posted is accepted — reopening any of those would either lose a figure somebody entered or unpick a posting.',
  'If the place needs counting again, raise a new count for it from Counting. If this count is waiting for a decision, decide it first: refusing it is what sends it back.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The lifecycle, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.count_task_lifecycle_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The count task's lifecycle (20260927000000), read by
  -- erp.configure_inventory() for a new install and by the upgrade register
  -- for an organisation on version 5, so the two cannot disagree. The states
  -- are erp.count_task_status. Each move carries the permission its door
  -- asks for: recording inventory.count (a scanner confirmation is the
  -- system's, erp.derived_move_fact()); posting, recounting and discarding a
  -- figure inventory.adjust; withdrawing a task nobody has counted
  -- inventory.count, as raising it does. Approve and reject are the approval
  -- request's outcome, made by erp.settle_approval_outcome() on the
  -- approver's decision. No screen draws them: each is made by the door that
  -- does the work (erp.move_count_task()).
  select jsonb_build_object('kind','state_machine','key','count_task_lifecycle','payload',
        jsonb_build_object(
          'code','count_task_lifecycle','object_type','count_task','name','Count task',
          'states', jsonb_build_array(
            jsonb_build_object('code','open','name','Open','is_initial',true,'sort_order',10),
            jsonb_build_object('code','counted','name','Counted','sort_order',20),
            jsonb_build_object('code','pending_approval','name','Waiting for approval','sort_order',30),
            jsonb_build_object('code','approved','name','Approved','is_committed',true,'sort_order',40),
            jsonb_build_object('code','rejected','name','Refused','sort_order',50),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',60),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','record_approved','name','Record','from','open','to','approved','required_permission','inventory.count','sort_order',10),
            jsonb_build_object('code','record_pending','name','Record','from','open','to','pending_approval','required_permission','inventory.count','sort_order',11),
            jsonb_build_object('code','record_counted','name','Record','from','open','to','counted','required_permission','inventory.count','sort_order',12),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','inventory.adjust','sort_order',20),
            jsonb_build_object('code','reject','name','Refuse','from','pending_approval','to','rejected','required_permission','inventory.adjust','sort_order',21),
            jsonb_build_object('code','post','name','Post','from','approved','to','posted','required_permission','inventory.adjust','sort_order',30),
            jsonb_build_object('code','recount','name','Count again','from','rejected','to','open','required_permission','inventory.adjust','sort_order',40),
            jsonb_build_object('code','recount_counted','name','Count again','from','counted','to','open','required_permission','inventory.adjust','sort_order',41),
            jsonb_build_object('code','cancel','name','Cancel','from','open','to','cancelled','required_permission','inventory.count','sort_order',90),
            jsonb_build_object('code','cancel_counted','name','Cancel','from','counted','to','cancelled','required_permission','inventory.adjust','sort_order',91),
            jsonb_build_object('code','cancel_rejected','name','Cancel','from','rejected','to','cancelled','required_permission','inventory.adjust','sort_order',92))))
$$;

comment on function erp.count_task_lifecycle_item() is
  'The count task''s lifecycle (20260927000000): the configuration item '
  'erp.configure_inventory() and the inventory-operations upgrade register both read.';

do $configure$
declare
  v_sig constant text := 'erp.configure_inventory(erp.costing_method,text,numeric,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    || erp.stock_adjustment_pack_items());$o$;
  v_new constant text := $n$    || erp.stock_adjustment_pack_items()
    -- The count task's lifecycle (20260927000000), from its one helper.
    || jsonb_build_array(erp.count_task_lifecycle_item()));$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % stock adjustment items found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The upgrade register: version 6 for an organisation on version 5
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 6,
       description = description
         || ' Version 6 (20260927000000): a count task moves by a lifecycle, with a '
         || 'permission on every move and a line in the history for each.'
 where install_code = 'inventory-operations' and current_version = 5;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'inventory-operations', 6, 'state_machine', 'count_task_lifecycle',
       (erp.count_task_lifecycle_item() -> 'payload') - 'entity', 200
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'inventory-operations') is distinct from 6 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the inventory-operations installer is not at version 6';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'inventory-operations' and ui.to_version = 6
         and ui.object_kind = 'state_machine' and ui.object_key = 'count_task_lifecycle'
         and ui.payload = (erp.count_task_lifecycle_item() -> 'payload') - 'entity') <> 1
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'inventory-operations' and ui.to_version = 6) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 6 of inventory-operations is not the one item it ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. Two moves the system makes: the approver's decision, the scanner's count
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Deployed body, asserted needle: a second arm after the document one. Only
-- p_object_type 'count_task' reaches it, so no document move changes.

do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$     and not d.is_cancelled
$o$;
  v_new constant text := $n$     and not d.is_cancelled
  union all
  -- A count task's two moves the system makes (20260927000000), each asked
  -- for by name in erp.deriving_move immediately before the move:
  --
  --   approve, reject     erp.settle_approval_outcome(), when the variance's
  --                       approval request is decided that way. The approver
  --                       is authorised by being the assignee, whatever role
  --                       the programme names.
  --   record_*            erp.record_count(), while erp.drain_device_actions()
  --                       applies the operator's own queued count, which
  --                       erp.scan_confirms() says inventory.scan confirms.
  --
  -- Read again here, with the task's state locked: the request is the one
  -- the task is waiting on and was decided that way, or the confirmation
  -- still holds for this task's site.
  select case
           when p_transition_code in ('approve', 'reject')
            and t.status = 'pending_approval'
            and ar.status::text = case p_transition_code when 'approve' then 'approved' else 'rejected' end
             then 'erp.approval_request'
           when p_transition_code in ('record_approved', 'record_pending', 'record_counted')
            and t.status = 'open'
            and erp.scan_confirms('inventory.count', array['count'], null, t.site_id)
             then 'erp.scan_confirms'
         end
    from erp.count_task t
    left join erp.approval_request ar
      on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
   where p_object_type = 'count_task'
     and coalesce(current_setting('erp.deriving_move', true), '')
           = p_object_id::text || ':' || p_transition_code
     and t.tenant_id = erp.current_tenant_id()
     and t.id = p_object_id
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % cancelled-document anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. One routine moves a count task
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.move_count_task(
  p_task_id uuid,
  p_transition_code text,
  p_to erp.count_task_status,
  p_reason text default null)
returns erp.count_task_status
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_to     text;
begin
  -- A task that started a lifecycle moves by its transition: the engine looks
  -- the move up in the version the task started under, asks for its
  -- permission (or reads the fact a system move is derived from) and writes
  -- the history. The column follows it, so everything that reads the status
  -- reads the same answer.
  if exists (select 1 from erp.object_state os
              where os.tenant_id = v_tenant and os.object_type = 'count_task'
                and os.object_id = p_task_id) then
    v_to := erp.perform_transition('count_task', p_task_id, p_transition_code,
                                   '{}'::jsonb, p_reason);
    if v_to is distinct from p_to::text then
      raise exception 'CLOVEERP_COUNT_TASK_LIFECYCLE_DISAGREES: % moved the count to %, where it should be %',
        p_transition_code, v_to, p_to
        using errcode = '23514',
              hint = 'Restore the count task lifecycle on the Configuration screen, or ask whoever changed it.';
    end if;
  end if;

  -- A task raised before its organisation took the lifecycle has none, and
  -- moves as it always has: its door has already asked for the permission.
  update erp.count_task
     set status = p_to, updated_at = now()
   where tenant_id = v_tenant and id = p_task_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_TASK: %', p_task_id using errcode = '23503',
      hint = 'The count task does not exist in this organisation.';
  end if;

  return p_to;
end;
$$;

revoke all on function erp.move_count_task(uuid, text, erp.count_task_status, text) from public, anon;

comment on function erp.move_count_task(uuid, text, erp.count_task_status, text) is
  'The one place a count task''s status is written (20260927000000): by its '
  'transition where the task started a lifecycle, and as before where it did not. '
  'Called by the doors that do the work, after they have authorised it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The doors move the task through it
-- ─────────────────────────────────────────────────────────────────────────────

-- Raising starts the lifecycle where the organisation has one, and (a) a
-- place whose count is approved and not yet posted is not raised again. An
-- organisation with no count task lifecycle at all — one still on version 5
-- of inventory-operations — raises its tasks as it always did, and they move
-- by their column. One that has a lifecycle and none in force here —
-- expired, withdrawn, or for another site — is told so, rather than raising
-- a task that moves with no permission and no history, as a works order is.
-- Decided once for the run rather than caught per task, so a programme of a
-- thousand places does not open a thousand subtransactions.
do $raise$
declare
  v_sig constant text := 'erp.raise_count_tasks(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_committed numeric;
begin$o$,
    $n$  v_committed numeric;
  v_lifecycle boolean;
begin$n$,
    $o$  perform erp.authorise('inventory.count', null, pg.site_id, null,
                        'count_programme', pg.id);
$o$,
    $n$  perform erp.authorise('inventory.count', null, pg.site_id, null,
                        'count_programme', pg.id);

  v_lifecycle := exists (select 1 from erp.state_machine sm
                          where sm.tenant_id = v_tenant and sm.object_type = 'count_task');

  -- Decided once, before a task is raised (found on review: the refusal came
  -- at the first task, and took every programme's scheduled run with it).
  if v_lifecycle and not exists (
       select 1 from erp.state_machine sm
         join erp.state_machine_version smv
           on smv.tenant_id = sm.tenant_id and smv.state_machine_id = sm.id
          and smv.status = 'active'
          and daterange(smv.effective_from, smv.effective_to, '[)') @> current_date
        where sm.tenant_id = v_tenant and sm.object_type = 'count_task' and sm.status = 'active') then
    raise exception 'CLOVEERP_COUNT_LIFECYCLE_NOT_IN_FORCE: the organisation''s count task lifecycle is not in force today, so programme % raises no count',
      pg.code
      using errcode = '23514',
            hint = 'Restore the count task lifecycle on the Configuration screen, or promote a version of it in force today.';
  end if;
$n$,
    $o$       where t.tenant_id = v_tenant and t.status in ('open','counted','pending_approval')$o$,
    $n$       -- Approved and not yet posted is still in flight (20260927000000):
       -- its lock is live, and a second task over it would split what moves.
       -- So is a refused count, which is counted again or cancelled, and was
       -- raised again over (found on review: counted again beside its second,
       -- the place's variance posted twice).
       where t.tenant_id = v_tenant and t.status in ('open','counted','pending_approval','approved','rejected')$n$,
    $o$    insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id)
    values (v_tenant, v_task, r.location_id, r.item_id);
$o$,
    $n$    insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id)
    values (v_tenant, v_task, r.location_id, r.item_id);

    if v_lifecycle then
      perform erp.start_lifecycle('count_task', v_task,
                                  (select s.entity_id from erp.site s where s.id = r.site_id),
                                  r.site_id, p_machine_code => null::text);
    end if;
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$raise$;

-- Counted again only where no other count of the place is in flight: the
-- guard the raise now keeps, kept here too (found on review).
do $recount_guard$
declare
  v_sig constant text := 'erp.recount_task(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  perform erp.authorise('inventory.adjust', null, t.site_id, null,
                        'count_task', p_task_id);
$o$;
  v_new constant text := $n$  perform erp.authorise('inventory.adjust', null, t.site_id, null,
                        'count_task', p_task_id);

  if exists (select 1 from erp.count_task o
              where o.tenant_id = v_tenant and o.id <> t.id
                and o.status in ('open', 'counted', 'pending_approval', 'approved')
                and o.item_id = t.item_id
                and o.location_id is not distinct from t.location_id
                and o.owner_party_id is not distinct from t.owner_party_id
                and o.container_id is not distinct from t.container_id) then
    raise exception 'CLOVEERP_COUNT_ALREADY_IN_FLIGHT: another count of this place is under way, so % is not counted again beside it', p_task_id
      using errcode = '23514',
            hint = 'Finish or cancel the other count of the place, then count this one again, or cancel this one.';
  end if;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$recount_guard$;

-- One programme whose lifecycle is not in force does not stop the others'
-- scheduled counts.
do $generate$
declare
  v_sig constant text := 'erp.generate_count_tasks(jsonb)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    v_total := v_total + erp.raise_count_tasks(p.code);$o$;
  v_new constant text := $n$    begin
      v_total := v_total + erp.raise_count_tasks(p.code);
    exception when others then
      -- A lifecycle out of force is one programme's to fix (20260927000000);
      -- anything else stops the run as before.
      if sqlerrm not like 'CLOVEERP_COUNT_LIFECYCLE_NOT_IN_FORCE:%' then
        raise;
      end if;
    end;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$generate$;

select erp.register_refusal('CLOVEERP_COUNT_LIFECYCLE_NOT_IN_FORCE',
  'Raising counts while the organisation''s count task lifecycle has no version in force.',
  'A count raised then would move with no permission asked and no history kept.',
  'Restore the count task lifecycle on the Configuration screen, or promote a version of it in force today.');
select erp.register_refusal('CLOVEERP_COUNT_ALREADY_IN_FLIGHT',
  'Counting a place again while another count of it is under way.',
  'Two counts of one place each post the difference they find, and the stock is corrected twice.',
  'Finish or cancel the other count of the place, then count this one again, or cancel this one.');

-- Recording: the figure is written as before and the move is the lifecycle's.
-- A count the scanner confirms is the system's move on the operator's queued
-- count, derived from erp.scan_confirms(), as the door authorised it.
do $record$
declare
  v_sig constant text := 'erp.record_count(uuid,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_req    uuid;
begin$o$,
    $n$  v_req    uuid;
  v_scanned boolean;
begin$n$,
    $o$  if erp.scan_confirms('inventory.count', array['count'], null, t.site_id) then$o$,
    $n$  v_scanned := erp.scan_confirms('inventory.count', array['count'], null, t.site_id);
  if v_scanned then$n$,
    $o$         within_tolerance = v_ok, status = v_status,$o$,
    $n$         within_tolerance = v_ok,$n$,
    $o$   where id = p_task_id;

  return v_status;$o$,
    $n$   where id = p_task_id;

  -- The move (20260927000000): within tolerance, or approved as it was asked
  -- for, it is approved; outside it, it waits for its approver, or is counted
  -- where the programme names none.
  if v_scanned then
    perform set_config('erp.deriving_move', p_task_id::text || ':' ||
      case v_status when 'approved' then 'record_approved'
                    when 'pending_approval' then 'record_pending'
                    else 'record_counted' end, true);
  end if;
  perform erp.move_count_task(p_task_id,
    case v_status when 'approved' then 'record_approved'
                  when 'pending_approval' then 'record_pending'
                  else 'record_counted' end,
    v_status);
  perform set_config('erp.deriving_move', '', true);

  return v_status;$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$record$;

-- Recounting (b): a counted task as well as a refused one, and the move is
-- the lifecycle's.
do $recount$
declare
  v_sig constant text := 'erp.recount_task(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  if t.status <> 'rejected' then
    raise exception
      'CLOVEERP_COUNT_TASK_NOT_REJECTED: % is %, and only a count an approver '
      'refused is sent back to be counted again', p_task_id, t.status
      using errcode = '23514',
            hint = 'An open count is recorded, a counted one waits for its approver, '
                   'and a posted one is in the ledger. Raise a new count for the place instead.';
  end if;$o$,
    $n$  -- Counted as well as refused (20260927000000): a count outside its
  -- tolerance under a programme with no approval chain waits for nobody, and
  -- before this nothing could move it.
  if t.status not in ('rejected', 'counted') then
    raise exception
      'CLOVEERP_COUNT_TASK_NOT_REJECTED: % is %, and only a count an approver '
      'refused, or one counted outside its tolerance with nobody to approve it, '
      'is sent back to be counted again', p_task_id, t.status
      using errcode = '23514',
            hint = 'An open count is recorded, a waiting one is decided by its approver, '
                   'and an approved or posted one is accepted. Raise a new count for the place instead.';
  end if;$n$,
    $o$     set status              = 'open',
         expected_quantity   = v_expect,$o$,
    $n$     set expected_quantity   = v_expect,$n$,
    $o$   where c.tenant_id = v_tenant and c.id = p_task_id;
$o$,
    $n$   where c.tenant_id = v_tenant and c.id = p_task_id;

  perform erp.move_count_task(p_task_id,
    case when t.status = 'counted' then 'recount_counted' else 'recount' end, 'open');
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$recount$;

comment on function erp.recount_task(uuid) is
  'Sends a count an approver refused, or one counted outside its tolerance with no approval '
  'chain to decide it (20260927000000), back to be counted again: re-reads the expectation, '
  'takes a fresh lock, and moves the task by its lifecycle where it has one. Authorises inventory.adjust.';

update erp_meta.public_write_allowance
   set rationale = 'Sends a count an approver refused, or one counted outside its tolerance with nobody to approve it, back to be counted again. Refuses any other task, asks erp.authorise() for inventory.adjust on the task''s site, and writes only that task and its count lock.'
 where function_name = 'erp_recount_task';

-- Posting: both arms, the variance of nothing and the adjustment, post by the
-- lifecycle's move.
do $post$
declare
  v_sig constant text := 'erp.post_count(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    update erp.count_task set status = 'posted', posted_at = now(), updated_at = now()
     where id = p_task_id;$o$,
    $n$    update erp.count_task set posted_at = now(), updated_at = now()
     where id = p_task_id;
    perform erp.move_count_task(p_task_id, 'post', 'posted');$n$,
    $o$  update erp.count_task set status = 'posted', posted_at = now(), updated_at = now()
   where id = p_task_id;$o$,
    $n$  update erp.count_task set posted_at = now(), updated_at = now()
   where id = p_task_id;
  perform erp.move_count_task(p_task_id, 'post', 'posted');$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$post$;

-- Settling an approval: only the count task arm changes. The move is the
-- system's, derived from the decided request, so an approver the programme
-- named is not refused for holding no inventory permission.
do $settle$
declare
  v_sig constant text := 'erp.settle_approval_outcome(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    update erp.count_task t
       set status = q.status::text::erp.count_task_status,
           updated_at = now()
     where t.tenant_id = v_tenant
       and t.id = q.object_id
       and t.approval_request_id = q.id
       and t.status = 'pending_approval';
    get diagnostics v_moved = row_count;$o$;
  v_new constant text := $n$    perform 1 from erp.count_task t
     where t.tenant_id = v_tenant
       and t.id = q.object_id
       and t.approval_request_id = q.id
       and t.status = 'pending_approval'
       for update;
    if found then
      -- By the lifecycle's move (20260927000000), the fact it is derived
      -- from named immediately before it and cleared after.
      perform set_config('erp.deriving_move', q.object_id::text || ':' ||
        case when q.status::text = 'approved' then 'approve' else 'reject' end, true);
      perform erp.move_count_task(q.object_id,
        case when q.status::text = 'approved' then 'approve' else 'reject' end,
        q.status::text::erp.count_task_status);
      perform set_config('erp.deriving_move', '', true);
      v_moved := 1;
    end if;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count task arm found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$settle$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. (c) A count nobody is going to finish can be cancelled
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.cancel_count_task(p_task_id uuid, p_reason text)
returns erp.count_task_status
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        erp.count_task%rowtype;
begin
  select * into t from erp.count_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_TASK: %', p_task_id using errcode = '23503',
      hint = 'The count task does not exist in this organisation.';
  end if;

  -- Withdrawing a task nobody has counted is raising's other half, and asks
  -- what raising asks. Discarding a figure somebody recorded asks what
  -- sending it back to be counted again asks.
  perform erp.authorise(
    case when t.status in ('counted', 'rejected') then 'inventory.adjust' else 'inventory.count' end,
    null, t.site_id, null, 'count_task', p_task_id);

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_COUNT_CANCELLATION_NEEDS_A_REASON: say why count % is being cancelled', p_task_id
      using errcode = '22023', hint = 'Say why the count is being cancelled.';
  end if;

  -- Open, counted or refused: nobody is deciding it and nothing has posted.
  if t.status not in ('open', 'counted', 'rejected') then
    raise exception 'CLOVEERP_COUNT_TASK_NOT_CANCELLABLE: count % is %, and only one open, counted or refused is cancelled',
      p_task_id, t.status
      using errcode = '23514',
            hint = 'Decide a waiting count first: refused, it can be counted again or cancelled. Post an approved one.';
  end if;

  -- The lock goes with it, as posting and refusing release it: a lock left
  -- open would go on gathering movement into a task nobody is counting, and
  -- the next count of the place would inherit it.
  update erp.count_lock l
     set released_at = now(), updated_at = now()
   where l.tenant_id = v_tenant and l.count_task_id = p_task_id
     and l.released_at is null;

  perform erp.move_count_task(p_task_id,
    case t.status when 'open' then 'cancel'
                  when 'counted' then 'cancel_counted'
                  else 'cancel_rejected' end,
    'cancelled', btrim(p_reason));

  return 'cancelled'::erp.count_task_status;
end;
$$;

revoke all on function erp.cancel_count_task(uuid, text) from public, anon;

comment on function erp.cancel_count_task(uuid, text) is
  'Cancels a count task that is open, counted or refused, with a reason, and releases its '
  'count lock (20260927000000). Authorises inventory.count for a task nobody has counted, '
  'inventory.adjust for one whose figure it discards.';

create or replace function public.erp_cancel_count_task(p_task_id uuid, p_reason text)
returns erp.count_task_status
language sql
set search_path = ''
as $$ select erp.cancel_count_task(p_task_id, p_reason) $$;

revoke all on function public.erp_cancel_count_task(uuid, text) from public, anon;
grant execute on function public.erp_cancel_count_task(uuid, text) to authenticated, service_role;

comment on function public.erp_cancel_count_task(uuid, text) is
  'Cancels a count task nobody is going to finish, with a reason, and releases its lock (20260927000000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_cancel_count_task', 'erp.cancel_count_task',
   'Cancels a count task that is open, counted or refused, with a reason, and releases its count lock; authorises inventory.count, or inventory.adjust where a recorded figure is discarded.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- Until the Counting screen offers it: the next step of this node.
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_cancel_count_task', 'pending_screen', '/inventory/audit',
   'Cancels a count nobody is going to finish, with a reason, so scheduled counting is not held up by it. Belongs beside Record and Count again on the Counting screen, which does not offer it yet.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

select erp_meta.add_help_actions('/inventory/audit', array['erp_cancel_count_task']);

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The demonstration takes version 6 of inventory-operations in its catch-up
--
-- As production's newer version is taken (20260924400000): in a block of its
-- own, before the trading, a refusal a note. Tasks it raised before keep
-- moving by their column; the ones it raises from here have a lifecycle.
-- ─────────────────────────────────────────────────────────────────────────────

do $catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- ── Trading, up to the day this runs or the time this statement has ────────
$o$;
  v_new constant text := $n$  -- ── Inventory operations' newer version (20260927000000) ──────────────────
  begin
    if exists (select 1 from erp.module_installation i
                where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') then
      if exists (select 1 from erp.plan_module_upgrade('inventory-operations')) then
        perform erp.upgrade_module_configuration('inventory-operations');
        v_notes := v_notes || to_jsonb(format(
          'Inventory operations was upgraded to version %s.',
          (select mi.current_version from erp_ref.module_installer mi
            where mi.install_code = 'inventory-operations')));
      end if;
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'Inventory operations was not upgraded, so its counts move as they did: %s', sqlerrm));
  end;

  -- ── Trading, up to the day this runs or the time this statement has ────────
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % trading anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$catch_up$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The registers say what is left
--
-- A count task is still in the column register: a task raised before its
-- organisation took the lifecycle has none, and erp.move_count_task() writes
-- its column as the doors did. It is the only routine that does, so the four
-- allowances are one.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.lifecycle_column_register()
 returns jsonb
 language sql
 immutable
 set search_path to ''
as $function$
  select jsonb_agg(jsonb_build_object(
           'schema_name', x.schema_name, 'table_name', x.table_name,
           'column_name', x.column_name, 'detail', x.detail))
    from (values
      ('erp', 'works_order', 'status',
       'A works order moves by its lifecycle since 20260924400000, and the column follows it. Its one writer is erp.move_works_order(), which also moves an order raised before its organisation took the lifecycle, by the column, as every order moved before. The row goes when no organisation is left on version 1 of production.'),
      ('erp', 'planned_order', 'status',
       'The same shape as a works order: suggested by a run, converted when confirmed. The two states nothing entered, reviewed and firmed, are refused by planned_order_status_retired (20260925500000). Its moves belong on the spine with the rest.'),
      ('erp', 'count_task', 'status',
       'A count task moves by its lifecycle since 20260927000000, and the column follows it. Its one writer is erp.move_count_task(), which also moves a task raised before its organisation took the lifecycle, by the column, as every count moved before. The row goes when no organisation is left on version 5 of inventory-operations.')
    ) as x(schema_name, table_name, column_name, detail)
$function$;

create or replace function erp.lifecycle_column_writer_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(jsonb_build_object(
           'schema_name', x.schema_name, 'table_name', x.table_name, 'column_name', x.column_name,
           'writer', x.writer, 'detail', x.detail))
    from (values
      ('erp', 'works_order', 'status', 'erp.move_works_order(uuid,text,erp.works_order_status,text)',
       'The one door the works order''s lifecycle moves through (20260924400000): it moves the order and the column follows.'),
      ('erp', 'planned_order', 'status', 'erp.firm_planned_order(uuid,text)',
       'A planned order is suggested by a run and converted when it is confirmed; confirming it is the one move it makes.'),
      ('erp', 'count_task', 'status', 'erp.move_count_task(uuid,text,erp.count_task_status,text)',
       'The one door the count task''s lifecycle moves through (20260927000000): it moves the task and the column follows. Recording, the approver''s decision, posting, counting again and cancelling all call it.')
    ) as x(schema_name, table_name, column_name, writer, detail)
$$;

revoke all on function erp.lifecycle_column_writer_register() from public, anon;

comment on function erp.lifecycle_column_writer_register() is
  'The routines allowed to write a column erp.lifecycle_column_register() names, each with its '
  'reason (20260926000000; the count task''s four writers are one since 20260927000000). Read by '
  'erp.state_side_door_report(): any other writer is a finding, and so is an allowance that writes nothing.';

-- The suites that pinned what this moves.

-- The writer register is three rows, not six.
do $gate_suite$
declare
  v_sig constant text := 'erp_test.dead_configuration_gate_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    and jsonb_array_length(erp.lifecycle_column_writer_register()) = 6,$o$;
  v_new constant text := $n$    -- Three since 20260927000000: the count task's four writers are one.
    and jsonb_array_length(erp.lifecycle_column_writer_register()) = 3,$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % register length anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$gate_suite$;

-- An organisation put back and upgraded arrives at inventory-operations 6.
do $adjust_suite$
declare
  v_sig constant text := 'erp_test.stock_adjustment_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 5;$o$;
  v_new constant text := $n$              -- 6 since 20260927000000: the count task's lifecycle joined the installer.
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 6;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$adjust_suite$;

do $transfer_suite$
declare
  v_sig constant text := 'erp_test.site_transfer_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 5;$o$,
    $n$        -- And 6 since 20260927000000, when the count task's lifecycle joined it.
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 6;$n$,
    $o$organisation now at version %s (5 rather than 4 since the stock adjustment joined the same installer)$o$,
    $n$organisation now at version %s (6 rather than 4 since the stock adjustment and the count task''s lifecycle joined the same installer)$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$transfer_suite$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The words the screen will say for it
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A count cancelled, or a counted one counted again, from the Counting screen (20260927000000).'
  from (values
    ('Cancel the count'),
    ('For a count nobody is going to finish: open, counted, or refused by its approver. Its place is released, and the next scheduled count is raised as usual.'),
    ('Why the count is cancelled'),
    ('Outside its tolerance, with nobody to approve it. Count it again, or cancel it.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- The controls suite's third count raised a new task over the refused
-- second; a refused place is now counted again instead (20260927000000).
do $controls_suite$
declare
  v_sig constant text := 'erp_test.controls_finish_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      v_step := 'counting: before go-live the counter posts his own count';
      perform set_config('request.jwt.claims', json_build_object('sub', s_cole)::text, true);
      perform erp.raise_count_tasks('STOCKTAKE');
      select t.id into v_t3
        from erp.count_task t
       where t.tenant_id = r.tenant_id and t.item_id = v_cnt and t.status = 'open';$o$;
  v_new constant text := $n$      v_step := 'counting: before go-live the counter posts his own count';
      -- The refused count is counted again, not raised over (20260927000000).
      perform set_config('request.jwt.claims', json_build_object('sub', s_mia)::text, true);
      perform erp.recount_task(v_t2);
      v_t3 := v_t2;
      perform set_config('request.jwt.claims', json_build_object('sub', s_cole)::text, true);$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$controls_suite$;
-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The proof: erp_test.count_lifecycle_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.count_lifecycle_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_tok   text;
  v_second uuid;
  p1 uuid; p2 uuid;
  csf uuid; csp uuid; csi uuid;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid; v_grn uuid;
  i_a uuid; i_b uuid; i_c uuid; i_d uuid; i_e uuid; i_f uuid; i_g uuid;
  t_a uuid; t_b uuid; t_c uuid; t_d uuid; t_e uuid; t_f uuid; t_g uuid; t_g2 uuid;
  v_req uuid; v_task uuid;
  v_status text; v_status2 text; v_log text; v_err text; v_err2 text;
  v_fact text; v_perm boolean;
  v_n integer; v_n2 integer; v_locks integer;
  v_fixture text;
begin
  -- 1. Every move the lifecycle declares is made by a door: a routine that
  --    moves the task through erp.move_count_task() names it.
  return query select 'every move the count task lifecycle declares is made by a door',
    not exists (
      select 1
        from jsonb_array_elements(erp.count_task_lifecycle_item() #> '{payload,transitions}') t
       where not exists (
         select 1 from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'erp' and p.proname <> 'count_task_lifecycle_item'
           and p.prosrc ~ 'erp\.move_count_task\('
           and strpos(p.prosrc, '''' || (t.value ->> 'code') || '''') > 0)),
    (select string_agg(t.value ->> 'code', ', ')
       from jsonb_array_elements(erp.count_task_lifecycle_item() #> '{payload,transitions}') t);

  -- The lifecycle an installer ships is the one the upgrade offers.
  return query select 'a new organisation and an upgraded one are given the same count task lifecycle',
    (select count(*) from erp_ref.module_upgrade_item ui
      where ui.install_code = 'inventory-operations' and ui.object_key = 'count_task_lifecycle'
        and ui.payload = (erp.count_task_lifecycle_item() -> 'payload') - 'entity') = 1
    and (select mi.current_version from erp_ref.module_installer mi
          where mi.install_code = 'inventory-operations') = 6,
    'the upgrade item is the helper''s payload, as version 6';

  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-ctl-' || v_hex, 'Count lifecycle suite',
      'a@zz-ctl-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    p1 := erp.current_principal_id();
    res := public.erp_invite_principal('second@zz-ctl-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_fixture := 'installing';
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    p2 := erp.current_principal_id();
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    -- Configuration written directly below (a programme nobody approves), and
    -- one person counts and posts, as an organisation not yet live may.
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

    return query select 'installing inventory installs the count task lifecycle',
      exists (select 1 from erp.state_machine sm
               join erp.state_machine_version v
                 on v.tenant_id = sm.tenant_id and v.state_machine_id = sm.id and v.status = 'active'
              where sm.tenant_id = r.tenant_id and sm.code = 'count_task_lifecycle'
                and sm.object_type = 'count_task' and sm.status = 'active'),
      coalesce((select sm.status::text from erp.state_machine sm
                 where sm.tenant_id = r.tenant_id and sm.code = 'count_task_lifecycle'), 'not installed');

    v_fixture := 'the stock';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'A', 'Counted and posted', v_uom, 'active') returning id into i_a;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'B', 'Refused and counted again', v_uom, 'active') returning id into i_b;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'C', 'Approved and posted', v_uom, 'active') returning id into i_c;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'D', 'Approved, not yet posted', v_uom, 'active') returning id into i_d;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'E', 'Raised before the lifecycle', v_uom, 'active') returning id into i_e;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'F', 'Refused and cancelled', v_uom, 'active') returning id into i_f;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'G', 'Counted with nobody to approve it', v_uom, 'active') returning id into i_g;

    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, i_a, 100, 100, 'A');
    perform erp.add_document_line(v_grn, i_b, 100, 100, 'B');
    perform erp.add_document_line(v_grn, i_c, 100, 100, 'C');
    perform erp.add_document_line(v_grn, i_d, 100, 100, 'D');
    perform erp.add_document_line(v_grn, i_e, 100, 100, 'E');
    perform erp.add_document_line(v_grn, i_f, 100, 100, 'F');
    perform erp.add_document_line(v_grn, i_g, 100, 100, 'G');
    perform erp.transition_document(v_grn, 'post');

    -- A programme with no approval chain, over G alone: a count outside its
    -- tolerance stops at counted.
    insert into erp.count_programme (tenant_id, code, name, kind, selector,
                                     tolerance_absolute, tolerance_pct, approval_chain_code, status)
    values (r.tenant_id, 'zz_unapproved', 'Nobody approves', 'cycle',
            '{"==": [{"var": "item_code"}, "G"]}'::jsonb, 0, 0, null, 'active');

    -- 2. Raising starts the lifecycle.
    v_fixture := 'raising';
    perform erp.raise_count_tasks('zz_unapproved');
    perform erp.raise_count_tasks('cycle_a');
    select t.id into t_a from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_a;
    select t.id into t_b from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_b;
    select t.id into t_c from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_c;
    select t.id into t_d from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_d;
    select t.id into t_e from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_e;
    select t.id into t_f from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_f;
    select t.id into t_g from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_g;
    select count(*) into v_n from erp.count_task t where t.tenant_id = r.tenant_id;
    select count(*) into v_n2
      from erp.count_task t
      join erp.object_state os
        on os.tenant_id = t.tenant_id and os.object_type = 'count_task' and os.object_id = t.id
      join erp.state s on s.id = os.current_state_id and s.code = 'open'
     where t.tenant_id = r.tenant_id
       and exists (select 1 from erp.state_transition_log l
                    where l.tenant_id = t.tenant_id and l.object_type = 'count_task'
                      and l.object_id = t.id and l.to_state_code = 'open'
                      and l.transition_code is null);
    return query select 'a task raised after the lifecycle is installed starts it at open',
      v_n = 7 and v_n2 = 7,
      format('%s task(s) raised, %s started at open', v_n, v_n2);

    -- A task raised before its organisation took the lifecycle is one with no
    -- lifecycle instance, which is what taking its instance away leaves.
    delete from erp.object_state os
     where os.tenant_id = r.tenant_id and os.object_type = 'count_task' and os.object_id = t_e;

    -- 3. Within tolerance: recorded and approved, then posted.
    v_fixture := 'recording and posting A';
    v_status := erp.record_count(t_a, 101)::text;
    perform erp.post_count(t_a);
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_a
       and l.transition_code is not null;
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_a and l.released_at is null;
    return query select 'a count within tolerance is recorded and posted by its lifecycle, and the column follows',
      v_status = 'approved' and v_log = 'record_approved,post'
      and erp.object_current_state('count_task', t_a) = 'posted'
      and (select t.status::text from erp.count_task t where t.id = t_a) = 'posted'
      and v_locks = 0,
      format('recorded %s; history %s; lifecycle %s; %s live lock(s)', v_status, v_log,
             erp.object_current_state('count_task', t_a), v_locks);

    -- 4. Outside tolerance: waits, is refused by its approver, and is counted
    --    again. While it waits it cannot be cancelled.
    v_fixture := 'refusing and counting B again';
    v_status := erp.record_count(t_b, 50)::text;
    begin
      perform public.erp_cancel_count_task(t_b, 'Nobody is going to finish it');
      v_err := 'cancelled';
    exception when others then v_err := left(sqlerrm, 200); end;
    select t.approval_request_id into v_req from erp.count_task t where t.id = t_b;
    select tk.id into v_task from erp.approval_task tk
     where tk.tenant_id = r.tenant_id and tk.approval_request_id = v_req
       and tk.status = 'pending' and tk.assignee_user_id = p1
     limit 1;
    perform erp.decide_approval_task(v_task, false, 'that is not what is on the shelf');
    v_status2 := (select t.status::text from erp.count_task t where t.id = t_b);
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_b and l.released_at is null;
    select l.guard_data #>> '{derived,fact}' into v_fact
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_b
       and l.transition_code = 'reject';
    return query select 'a count outside tolerance waits, cannot be cancelled while it does, and is refused by its approver''s decision',
      v_status = 'pending_approval'
      and v_err like 'CLOVEERP_COUNT_TASK_NOT_CANCELLABLE:%'
      and v_status2 = 'rejected'
      and erp.object_current_state('count_task', t_b) = 'rejected'
      and v_locks = 0
      and v_fact = 'erp.approval_request',
      format('recorded %s; cancel: %s; then %s, lifecycle %s, %s live lock(s), derived from %s',
             v_status, v_err, v_status2, erp.object_current_state('count_task', t_b), v_locks,
             coalesce(v_fact, 'nothing'));

    -- 4b. A refused place is not raised again: it is counted again or
    --     cancelled (found on review: raised over, then counted again, the
    --     variance posted twice).
    perform erp.raise_count_tasks('cycle_a');
    select count(*) into v_n from erp.count_task t
     where t.tenant_id = r.tenant_id and t.item_id = i_b and t.status not in ('posted', 'cancelled');
    return query select 'a place whose count was refused is not raised a second task: it is counted again or cancelled',
      v_n = 1, format('%s task(s) in flight', v_n);

    v_status := erp.recount_task(t_b)::text;
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_b
       and l.transition_code is not null;
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_b and l.released_at is null;
    return query select 'a refused count is counted again by its lifecycle''s recount, with a fresh lock',
      v_status = 'open' and v_log = 'record_pending,reject,recount'
      and erp.object_current_state('count_task', t_b) = 'open'
      and (select t.status::text from erp.count_task t where t.id = t_b) = 'open'
      and v_locks = 1,
      format('%s; history %s; %s live lock(s)', v_status, v_log, v_locks);

    -- 5. Outside tolerance and approved: posted with its variance.
    v_fixture := 'approving and posting C';
    perform erp.record_count(t_c, 50);
    select t.approval_request_id into v_req from erp.count_task t where t.id = t_c;
    select tk.id into v_task from erp.approval_task tk
     where tk.tenant_id = r.tenant_id and tk.approval_request_id = v_req
       and tk.status = 'pending' and tk.assignee_user_id = p1
     limit 1;
    perform erp.decide_approval_task(v_task, true, 'the shelf was checked');
    v_status := erp.object_current_state('count_task', t_c);
    perform erp.post_count(t_c);
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_c
       and l.transition_code is not null;
    return query select 'an approved variance is approved by the decision and posted by the lifecycle',
      v_status = 'approved' and v_log = 'record_pending,approve,post'
      and (select t.status::text from erp.count_task t where t.id = t_c) = 'posted'
      and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
            where b.tenant_id = r.tenant_id and b.item_id = i_c) = 50,
      format('after the decision %s; history %s; %s on hand',
             v_status, v_log,
             (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
               where b.tenant_id = r.tenant_id and b.item_id = i_c));

    -- 6. (a) A place whose count is approved and not yet posted is not raised
    --    again: one task, and one live lock.
    v_fixture := 'raising over D';
    perform erp.record_count(t_d, 100);
    perform erp.raise_count_tasks('cycle_a');
    select count(*) into v_n from erp.count_task t
     where t.tenant_id = r.tenant_id and t.item_id = i_d and t.status not in ('posted', 'cancelled');
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.item_id = i_d and l.released_at is null;
    return query select 'a place whose count is approved and not yet posted is not raised a second task or a second lock',
      v_n = 1 and v_locks = 1
      and (select t.status::text from erp.count_task t where t.id = t_d) = 'approved',
      format('%s task(s) in flight, %s live lock(s)', v_n, v_locks);

    -- 7. A task raised before the lifecycle still moves, by its column.
    v_fixture := 'recording and posting E';
    v_status := erp.record_count(t_e, 100)::text;
    perform erp.post_count(t_e);
    return query select 'a task raised before its organisation took the lifecycle still moves, by its column',
      v_status = 'approved'
      and (select t.status::text from erp.count_task t where t.id = t_e) = 'posted'
      and not exists (select 1 from erp.object_state os
                       where os.object_type = 'count_task' and os.object_id = t_e)
      and not exists (select 1 from erp.state_transition_log l
                       where l.object_type = 'count_task' and l.object_id = t_e
                         and l.transition_code is not null),
      (select t.status::text from erp.count_task t where t.id = t_e);

    -- 8. A refused count can be cancelled instead of counted again.
    v_fixture := 'refusing and cancelling F';
    perform erp.record_count(t_f, 50);
    select t.approval_request_id into v_req from erp.count_task t where t.id = t_f;
    select tk.id into v_task from erp.approval_task tk
     where tk.tenant_id = r.tenant_id and tk.approval_request_id = v_req
       and tk.status = 'pending' and tk.assignee_user_id = p1
     limit 1;
    perform erp.decide_approval_task(v_task, false, 'not believed');
    v_status := public.erp_cancel_count_task(t_f, 'The shelf was emptied for a refit')::text;
    return query select 'a refused count is cancelled by its lifecycle, with its reason in the history',
      v_status = 'cancelled'
      and erp.object_current_state('count_task', t_f) = 'cancelled'
      and exists (select 1 from erp.state_transition_log l
                   where l.object_type = 'count_task' and l.object_id = t_f
                     and l.transition_code = 'cancel_rejected'
                     and l.reason = 'The shelf was emptied for a refit'),
      coalesce(erp.object_current_state('count_task', t_f), 'no lifecycle');

    -- 9. (b) A count outside its tolerance with nobody to approve it stops at
    --    counted, and is counted again.
    v_fixture := 'counting G again';
    v_status := erp.record_count(t_g, 40)::text;
    v_status2 := erp.recount_task(t_g)::text;
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_g
       and l.transition_code is not null;
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_g and l.released_at is null;
    return query select 'a count outside tolerance that nobody approves is counted, and can be counted again',
      v_status = 'counted' and v_status2 = 'open' and v_log = 'record_counted,recount_counted'
      and (select t.counted_quantity is null and t.expected_quantity = 100
             from erp.count_task t where t.id = t_g)
      and v_locks = 1,
      format('recorded %s, then %s; history %s; %s live lock(s)', v_status, v_status2, v_log, v_locks);

    -- 10. (c) An abandoned count is cancelled, with a reason, its lock goes,
    --     and scheduled counting is no longer held up by it.
    v_fixture := 'cancelling G';
    v_n := erp.generate_count_tasks(jsonb_build_object('programme', 'zz_unapproved'));
    begin
      perform public.erp_cancel_count_task(t_g, '   ');
      v_err := 'cancelled';
    exception when others then v_err := left(sqlerrm, 200); end;
    v_status := public.erp_cancel_count_task(t_g, 'Counted by mistake; the programme covers it tomorrow')::text;
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_g and l.released_at is null;
    v_n2 := erp.generate_count_tasks(jsonb_build_object('programme', 'zz_unapproved'));
    select t.id into t_g2 from erp.count_task t
     where t.tenant_id = r.tenant_id and t.item_id = i_g and t.status = 'open';
    return query select 'a cancelled count needs a reason, releases its lock, and no longer holds up scheduled counting',
      v_n = 0 and v_err like 'CLOVEERP_COUNT_CANCELLATION_NEEDS_A_REASON:%'
      and v_status = 'cancelled' and v_locks = 0
      and erp.object_current_state('count_task', t_g) = 'cancelled'
      and exists (select 1 from erp.state_transition_log l
                   where l.object_type = 'count_task' and l.object_id = t_g
                     and l.transition_code = 'cancel'
                     and l.reason = 'Counted by mistake; the programme covers it tomorrow')
      and v_n2 = 1 and t_g2 is not null
      and erp.object_current_state('count_task', t_g2) = 'open',
      format('%s raised while it was open; %s; then %s with %s live lock(s); %s raised after',
             v_n, v_err, v_status, v_locks, v_n2);

    -- 11. A move is the system's only on the routine's word, and only while
    --     its fact holds.
    perform set_config('erp.deriving_move', '', true);
    v_fact := erp.derived_move_fact('count_task', t_g2, 'record_approved');
    perform set_config('erp.deriving_move', t_g2::text || ':record_approved', true);
    v_err := erp.derived_move_fact('count_task', t_g2, 'record_approved');
    perform set_config('erp.deriving_move', t_d::text || ':approve', true);
    v_err2 := erp.derived_move_fact('count_task', t_d, 'approve');
    perform set_config('erp.deriving_move', '', true);
    return query select 'a count''s move is derived only when a routine names it and its fact holds',
      v_fact is null and v_err is null and v_err2 is null,
      format('unnamed %s, a desk count %s, an approved task %s',
             coalesce(v_fact, 'none'), coalesce(v_err, 'none'), coalesce(v_err2, 'none'));

    -- 12. Every task with a lifecycle says what its column says.
    select count(*) into v_n
      from erp.count_task t
      join erp.object_state os
        on os.tenant_id = t.tenant_id and os.object_type = 'count_task' and os.object_id = t.id
      join erp.state s on s.id = os.current_state_id
     where t.tenant_id = r.tenant_id and s.code <> t.status::text;
    return query select 'every count task''s lifecycle and its column agree',
      v_n = 0 and (select count(*) from erp.object_state os
                    where os.tenant_id = r.tenant_id and os.object_type = 'count_task') >= 8,
      format('%s disagree', v_n);

    -- 12b. A lifecycle out of force refuses its programme by name, and the
    --      scheduled run carries on for the rest (found on review: the
    --      refusal at the first task took every programme with it).
    update erp.environment e set is_live = false where e.tenant_id = r.tenant_id and e.is_self;
    update erp.state_machine sm set status = 'inactive'
     where sm.tenant_id = r.tenant_id and sm.object_type = 'count_task';
    begin
      perform erp.generate_count_tasks('{}'::jsonb);
      v_err := 'ran';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin
      perform erp.raise_count_tasks('cycle_a');
      v_err2 := 'raised';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    update erp.state_machine sm set status = 'active'
     where sm.tenant_id = r.tenant_id and sm.object_type = 'count_task';
    return query select 'a count task lifecycle out of force refuses its programme''s count by name, and scheduled counting carries on',
      v_err = 'ran' and v_err2 like 'CLOVEERP_COUNT_LIFECYCLE_NOT_IN_FORCE:%',
      v_err || ' / ' || v_err2;

    -- 13. The side door check reads the new register, and passes.
    begin
      v_err := erp_test.assert_no_state_side_doors();
    exception when others then v_err := 'refused: ' || left(sqlerrm, 200); end;
    return query select 'the count task''s status has one writer, and the side door check passes',
      v_err not like 'refused:%'
      and (select string_agg(a.writer, ', ')
             from jsonb_to_recordset(erp.lifecycle_column_writer_register())
                    as a(table_name text, writer text)
            where a.table_name = 'count_task') = 'erp.move_count_task(uuid,text,erp.count_task_status,text)',
      v_err;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(v_fixture || ': ' || sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-ctl-' || v_hex);
  detail := 'the organisation, its counts and their lifecycles rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.count_lifecycle_suite() from public, anon;

create or replace function erp_test.assert_count_lifecycle_suite()
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
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.count_lifecycle_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_COUNT_LIFECYCLE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A count that moves past its lifecycle has no permission on the move and no history of it. Read the case that failed.';
  end if;
  if v_total <> 19 then
    raise exception 'CLOVEERP_COUNT_LIFECYCLE_SUITE_SHRANK: % case(s), expected 19', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_count_lifecycle_suite() from public, anon;

comment on function erp_test.assert_count_lifecycle_suite() is
  'A count task moves by its lifecycle where it has one and by its column where it was raised '
  'before; a counted task is counted again, an abandoned one cancelled with its lock released, '
  'and an approved place is not raised twice (20260927000000).';

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
