set lock_timeout = '30s';

-- =============================================================================
-- 20260928100000  A count is of the stock it counts
-- -----------------------------------------------------------------------------
-- PR11, M2: PR10's follow-ups (c) and (d). A count task is keyed by what it
-- counts, its batch and its stock status, so a variance posts to the status
-- that was counted, and a second batch of a product at the same place is
-- counted at all. Decisions D2 and D3 as taken on 25 September.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- On a database built from main (PR11 scoping, e2_counts.sql):
--
--   * (c) A place held nothing available and a hundred in quarantine. Its
--     count was raised expecting the hundred, recorded at 99, and posted the
--     difference out of AVAILABLE stock: the place then read available -1,
--     quarantine 100. count_task has no stock status, and both routes a
--     variance takes to the stock ledger, the count's stock adjustment
--     (erp.post_adjustment_lines) and the old movement written by
--     erp.post_count() where an organisation has no adjustment type, wrote
--     'available' as a literal.
--   * (d) Two batches of one product at one place, six and four, gave ONE
--     count task, of the first batch, expecting six. The second batch was
--     never counted. erp.raise_count_tasks() grouped the positions by batch
--     and by status, and then skipped every position after the first at the
--     place, because its "already in flight" test compared place, owner and
--     handling unit and not batch or status. It skipped inside one run, not
--     only across runs. Quarantined and available stock of one product at one
--     place gave one task in the same way, for whichever status came first.
--   * The soft lock a count holds on its place (count_lock) named the place
--     and the product only, so every count of the place took every movement
--     through it, and a status change inside the place was taken as stock
--     arriving: its to side was read, and its from side never.
--   * erp.recount_task() had the same in-flight test, so a count of one batch
--     could not be sent back while the other batch's count was open.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * New columns.
--       count_task.stock_status    the status the task counts. Raised with
--                                  it from this migration on; 'available'
--                                  when a row is written without one. Null
--                                  only for a count held for a person (D2).
--       count_lock.batch_id        the batch the lock covers, as the task.
--       count_lock.stock_status    the status it covers; null covers every
--                                  status, as a null item covers every item.
--       document_line.stock_status the status a stock adjustment's line
--                                  corrects; null is available, which is all
--                                  a line meant before. Read only by the
--                                  adjustment's line routine, so a count's
--                                  adjustment corrects the status counted.
--                                  The door that raises an adjustment by hand
--                                  is not changed: a hand adjustment still
--                                  corrects available stock.
--   * erp.raise_count_tasks(): a task and its count sheet line carry the
--     status of the position they count; the in-flight test compares batch
--     and status as well, a held count (null status) standing in the way of
--     every status at its place and batch; the quantity committed to orders
--     is read for the batch and status counted; the lock carries both.
--   * erp.note_count_lock_movement(), the stock movement trigger: a lock
--     takes a movement only of its own batch, and each side of it only in its
--     own status: into the place in its status adds, out of it takes away. A
--     status change of stock the count covers in every status moves nothing.
--   * erp.record_count(): the tolerance is unchanged, and judged against the
--     task's own expectation, which is now of one status and one batch. A
--     held count is refused (CLOVEERP_COUNT_STATUS_UNKNOWN).
--   * erp.post_count(): the old route's movement leaves from, or arrives in,
--     the task's status. A held count with a variance is refused with the
--     same code; one that found what was expected posts, as it moves nothing,
--     and its lock is released.
--   * erp.raise_count_adjustment(): the adjustment's line carries the status,
--     and says it in its note when it is not available.
--     erp.post_adjustment_lines() writes each line's movement in the line's
--     status, available when it names none.
--   * erp.count_post_hold_reason(): the variance the system has posted
--     unattended at a place is added up per status as well, as it already
--     was per batch, owner and handling unit. A count posted before a count
--     knew its status posted to available and is read so, so the bound does
--     not start again from nothing on the day this applies.
--   * erp.recount_task(): the same in-flight test as the raise, the
--     expectation re-read for the task's status, what is committed read for
--     its batch and status, and the new lock carrying both.
--   * public.erp_count_tasks() gains stock_status, with no signature change,
--     as 20260927400000 did, and says why a held count waits while it is
--     still open. erp_test.count_worklist_suite is re-pinned to 25 keys.
--   * erp.settle_approval_outcome(): a count whose status is not known is
--     not approved (CLOVEERP_COUNT_STATUS_UNKNOWN); the approver refuses it,
--     and a refused count is cancelled. erp.recount_task() refuses to count
--     one again as it is, for the same reason.
--   * erp.count_place_at(): what a place (a product and batch at a location,
--     or anywhere at a site) held at a moment, by status, owner and handling
--     unit, rebuilt backwards from the stock balance by taking away every
--     movement recorded since. It reads only the movements after the moment,
--     through the product's own index.
--   * D2. erp.settle_count_task_stock_status() is run once, below, over every
--     organisation. Every count task not yet posted or cancelled is given the
--     status whose quantity at its place, owner and handling unit, when the
--     task was raised, is what the task expected: the raise took the
--     expectation from exactly such a position. Where nothing but available
--     stood at the place, it is available, which is what it did until today.
--     Where no status, or more than one, matches while stock of another
--     status stood there, the status is left unknown and the task says why
--     in post_held_reason ('status_unknown: …'). Such a count is not
--     recorded, approved, counted again or posted with a variance, and is
--     cancelled and raised again. One approved already, which has no move to
--     cancel from, is put back to refused, once, by this migration (A9a),
--     with the reason on its history, so that it can be cancelled. The live
--     locks are given their task's batch and status. Posted and cancelled
--     tasks are history, left as they are. It is idempotent: a held task is
--     not looked at twice, and a task raised from here on is never unknown.
--   * D3. erp.count_posts_past_their_status_report(), in the diagnostic
--     register as a tenant report that does not run in CI, lists every count
--     posted before this migration whose expectation was what stood in
--     another status at its place when it was raised, and not what was
--     available: its difference, found or missing, went to available when it
--     belonged to that status. With what to do. It repairs nothing;
--     supabase/ops/20260928_count_posts_past_their_status.sql is how an
--     operator runs it, before the deploy as plain SQL and after it through
--     the function.
--   * erp_test.count_by_status_suite is the proof.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * Nothing PR11 M1 (20260928000000) touches: not erp.transition_document(),
--     erp.available_transitions(), erp.stock_state_refusal() or
--     erp.require_stock_backed_move(). The count's adjustment is still
--     approved and posted through the document door, and that is unchanged.
--   * No lifecycle, installer version, change set or register restatement.
--     No new public function.
--   * The count sheet's printed layout is not changed: a line carries its
--     status, and a layout that prints it is configuration, not this.
--   * erp.stock_audit_lines() still shows one count per place and product,
--     the latest, and so may show a posted count of one status over an open
--     count of another. Keying it by batch and status changes what the door
--     returns (a row per status, with the status and batch as columns, and
--     the book split the same way) and the Stock audit screen that reads it:
--     a change of the door's shape, not a patch, so it is left for its own
--     change.
--   * The lifecycle is not given a move from approved to refused. The one
--     approved count of unknown status there can be is put back by this
--     migration once; from here on none can be approved.
--   * The hand-typed adjustment door (erp.raise_stock_adjustment) is M4's.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusal this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_COUNT_STATUS_UNKNOWN',
  'Recording, posting, approving or counting again a count raised before a count knew which stock status it counts, whose place held stock in more than one status that its figure could be of.',
  'A count is of one status of the stock at its place: available, quarantined, blocked and so on. A count raised before this was known, at a place that held more than one, may have been of any of them, and posting its difference to the wrong one would leave that status wrong and the other untouched. It is held for a person rather than guessed.',
  'Cancel the count and raise the counting programme again, so that each status at the place is counted on its own. A count waiting for its approver is refused by the approver first, and then cancelled.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The columns
--
-- Each is added with no default, so no existing row is written: a nullable
-- column with no default is a change to the catalogue only. count_task's
-- default is set after the backfill (A9), so the backfill can tell a task
-- raised before this migration from one raised after it. Where the whole
-- file is applied in one transaction, as the deploy applies it, each lock
-- is held to the end; these three tables are small.
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.count_task    add column if not exists stock_status erp.stock_status;
alter table erp.count_lock    add column if not exists batch_id uuid;
alter table erp.count_lock    add column if not exists stock_status erp.stock_status;
-- document_line's is added after the backfill (A9b), so the lock that takes
-- on the busiest table of lines is not held while the backfill reads.

do $lock_batch_fkey$
begin
  if not exists (select 1 from pg_constraint c
                  where c.conrelid = 'erp.count_lock'::regclass
                    and c.conname = 'count_lock_batch_fkey') then
    -- Not valid first, so adding it takes no long lock on the batches, then
    -- validated against the locks there are, which are few.
    alter table erp.count_lock
      add constraint count_lock_batch_fkey foreign key (tenant_id, batch_id)
      references erp.batch (tenant_id, id) on delete restrict not valid;
  end if;
end
$lock_batch_fkey$;

alter table erp.count_lock validate constraint count_lock_batch_fkey;

comment on column erp.count_task.stock_status is
  'The stock status this count is of (20260928100000): its expectation, its sheet line, its lock and '
  'its variance are of stock in this status only. Null only for a count raised before a count knew '
  'its status, at a place that then held more than one; post_held_reason says so, and such a count is '
  'cancelled and raised again rather than guessed.';
comment on column erp.count_lock.batch_id is
  'The batch the count covers (20260928100000). A movement of another batch is not the count''s.';
comment on column erp.count_lock.stock_status is
  'The stock status the count covers (20260928100000); null covers every status. Each side of a '
  'movement through the place is the count''s only in this status.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. Raising: a task per batch and per status
--
-- Each patch below is applied to the body the named migration left, or
-- stops: every anchor must be found exactly once, and a restatement over a
-- body that has moved would drop whatever moved it. A body that already
-- carries this migration's change is left as it is, so the file can be
-- applied again.
-- ─────────────────────────────────────────────────────────────────────────────

-- The body 20260927100000 left.
do $raise_count_tasks$
declare
  v_sig constant text := 'erp.raise_count_tasks(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    -- 1. In flight: the same batch and status as well.
    $o$         and t.owner_party_id is not distinct from r.owner_party_id
         and t.container_id is not distinct from r.container_id);
$o$,
    $n$         and t.owner_party_id is not distinct from r.owner_party_id
         and t.container_id is not distinct from r.container_id
         -- And the same batch and stock status (20260928100000): two batches,
         -- or quarantined stock beside available, at one place are two
         -- counts. A count held because its status is not known stands in
         -- the way of every status at its place and batch until it is
         -- cancelled.
         and t.batch_id is not distinct from r.batch_id
         and (t.stock_status is null or t.stock_status = r.stock_status));
$n$,
    -- 2. What is committed to orders, of the batch and status counted.
    $o$       and al.location_id is not distinct from r.location_id
       and al.status in ('reserved', 'committed', 'picked');
$o$,
    $n$       and al.location_id is not distinct from r.location_id
       -- Of the batch and status counted (20260928100000).
       and al.batch_id is not distinct from r.batch_id
       and al.stock_status = r.stock_status
       and al.status in ('reserved', 'committed', 'picked');
$n$,
    -- 3. The sheet line says the status it counts.
    $o$        batch_id, location_id, container_id, unit_price_minor, net_minor)
      values (
        v_tenant, v_sheet, v_line_no, r.item_id, erp.line_description(r.item_id, null),
        r.quantity, erp.item_line_uom(r.item_id, v_sheet_dt),
        r.batch_id, r.location_id, r.container_id, 0, 0)
$o$,
    $n$        batch_id, location_id, container_id, unit_price_minor, net_minor,
        stock_status)
      values (
        v_tenant, v_sheet, v_line_no, r.item_id, erp.line_description(r.item_id, null),
        r.quantity, erp.item_line_uom(r.item_id, v_sheet_dt),
        r.batch_id, r.location_id, r.container_id, 0, 0,
        r.stock_status)   -- the status it counts (20260928100000)
$n$,
    -- 4. So does the task.
    $o$      document_id, document_line_id)
    values (v_tenant, pg.id, r.site_id, r.location_id, r.item_id, r.batch_id,
            r.quantity, v_committed, 'open',
            r.owner_party_id, r.container_id, r.counts_container,
            v_sheet, v_line)
$o$,
    $n$      document_id, document_line_id, stock_status)
    values (v_tenant, pg.id, r.site_id, r.location_id, r.item_id, r.batch_id,
            r.quantity, v_committed, 'open',
            r.owner_party_id, r.container_id, r.counts_container,
            v_sheet, v_line, r.stock_status)
$n$,
    -- 5. And its lock.
    $o$    insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id)
    values (v_tenant, v_task, r.location_id, r.item_id);
$o$,
    $n$    -- The batch and status it covers (20260928100000).
    insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id,
                                batch_id, stock_status)
    values (v_tenant, v_task, r.location_id, r.item_id, r.batch_id, r.stock_status);
$n$];
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already counts by batch and status; left as it is', v_sig;
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
$raise_count_tasks$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. Movement during a count reaches the count it is of
-- ─────────────────────────────────────────────────────────────────────────────

-- The body 20260829240000 left. Every stock movement fires it: the new
-- test reads only the lock's own columns, on the live-lock index it used.
do $note_count_lock_movement$
declare
  v_sig constant text := 'erp.note_count_lock_movement()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_delta numeric;
  r       record;
$o$,
    $n$  v_delta numeric;
  v_in    boolean;
  v_out   boolean;
  r       record;
$n$,
    $o$  for r in
    select l.count_task_id, l.location_id
      from erp.count_lock l
     where l.tenant_id = new.tenant_id
       and l.released_at is null
       and (l.item_id is null or l.item_id = new.item_id)
       and l.location_id in (new.from_location_id, new.to_location_id)
  loop
    v_delta := case when r.location_id = new.to_location_id then new.quantity
                    else -new.quantity end;
$o$,
    $n$  for r in
    select l.count_task_id, l.location_id, l.stock_status
      from erp.count_lock l
     where l.tenant_id = new.tenant_id
       and l.released_at is null
       and (l.item_id is null or l.item_id = new.item_id)
       and l.location_id in (new.from_location_id, new.to_location_id)
       -- Of the count's own batch (20260928100000): the other batch at the
       -- place is another count's.
       and (l.item_id is null or l.batch_id is not distinct from new.batch_id)
  loop
    -- Each side in the count's own status (20260928100000), a lock with no
    -- status covering every status: into the place adds, out of it takes
    -- away, so a status change inside the place moves the count it leaves
    -- and the count it joins, and a count of every status not at all.
    v_in  := r.location_id = new.to_location_id
             and (r.stock_status is null or r.stock_status = new.to_status);
    v_out := r.location_id = new.from_location_id
             and (r.stock_status is null or r.stock_status = new.from_status);
    continue when not (coalesce(v_in, false) or coalesce(v_out, false));
    v_delta := case when coalesce(v_in, false) then new.quantity else 0 end
             - case when coalesce(v_out, false) then new.quantity else 0 end;
$n$];
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already reads batch and status; left as it is', v_sig;
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
$note_count_lock_movement$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. Recording: a count whose status is not known is not recorded
-- ─────────────────────────────────────────────────────────────────────────────

-- The body 20260927300000 left.
do $record_count$
declare
  v_sig constant text := 'erp.record_count(uuid, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  end if;

  if p_quantity is null then
$o$;
  v_new constant text := $n$  end if;

  -- A count raised before a count knew its status, at a place that then
  -- held more than one, is held for a person (20260928100000): its figure
  -- could be of any of them, and would post to one of them by a guess.
  if t.stock_status is null then
    raise exception 'CLOVEERP_COUNT_STATUS_UNKNOWN: the count of % was raised before a count knew which stock it counts, and the place held stock in more than one status, so it is not recorded',
      coalesce((select i.code from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id), p_task_id::text)
      using errcode = '23514',
            detail = coalesce(t.post_held_reason, ''),
            hint = 'Cancel the count and raise the counting programme again, so that each status at the place is counted on its own.';
  end if;

  if p_quantity is null then
$n$;
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already refuses a count of no known status; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  if position('CLOVEERP_COUNT_NEEDS_A_QUANTITY' in v_def) < position(v_old in v_def)
     or position('erp.authorise(''inventory.count''' in v_def) > position(v_old in v_def) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no longer asks for its permission before its figure', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$record_count$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. Posting: to the status counted, by either route
-- ─────────────────────────────────────────────────────────────────────────────

-- The body 20260927300000 left.
do $post_count$
declare
  v_sig constant text := 'erp.post_count(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    return 0;
  end if;

  -- A variance is not written into the ledger by the person who counted it,
$o$,
    $n$    return 0;
  end if;

  -- A count with a variance and no known status is held for a person
  -- (20260928100000): the difference belongs to one status at the place,
  -- and nobody knows which. One that found what was expected has posted
  -- above, as it moves nothing.
  if t.stock_status is null then
    raise exception 'CLOVEERP_COUNT_STATUS_UNKNOWN: the count of % was raised before a count knew which stock it counts, and the place held stock in more than one status, so its variance of % has no status to post to',
      coalesce((select i.code from erp.item i where i.id = t.item_id), p_task_id::text),
      trim_scale(t.variance)
      using errcode = '23514',
            detail = coalesce(t.post_held_reason, ''),
            hint = 'Cancel the count and raise the counting programme again, so that each status at the place is counted on its own. A count already approved waits for somebody who may adjust stock to decide it.';
  end if;

  -- A variance is not written into the ledger by the person who counted it,
$n$,
    -- The old route: into the status counted, and out of it
    -- (20260928100000).
    $o$           t.location_id, 'available', t.variance, v_uom, v_cost, v_ccy,
$o$,
    $n$           t.location_id, t.stock_status, t.variance, v_uom, v_cost, v_ccy,
$n$,
    $o$           t.location_id, 'available', -t.variance, v_uom, v_cost, v_ccy,
$o$,
    $n$           t.location_id, t.stock_status, -t.variance, v_uom, v_cost, v_ccy,
$n$,
    $o$  -- An adjustment is a movement like any other, which is what keeps
$o$,
    $n$  -- The movement is of the status the count was of (20260928100000).
  --
  -- An adjustment is a movement like any other, which is what keeps
$n$];
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already posts to the status counted; left as it is', v_sig;
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
$post_count$;

-- The body 20260927300000 left: the count's adjustment says its status.
do $raise_count_adjustment$
declare
  v_sig constant text := 'erp.raise_count_adjustment(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_note := format('Counted %s of %s where the ledger held %s',
                   trim_scale(t.counted_quantity), coalesce(v_item, 'the product'),
                   trim_scale(t.counted_quantity - t.variance));
$o$,
    $n$  v_note := format('Counted %s of %s where the ledger held %s',
                   trim_scale(t.counted_quantity), coalesce(v_item, 'the product'),
                   trim_scale(t.counted_quantity - t.variance));
  -- The status, where it is not available (20260928100000).
  if t.stock_status is distinct from 'available' then
    v_note := v_note || format(' in %s', replace(coalesce(t.stock_status::text, 'an unknown status'), '_', ' '));
  end if;
$n$,
    $o$    batch_id, location_id, container_id, unit_price_minor, net_minor)
  values (
    v_tenant, v_doc, 10, t.item_id, erp.line_description(t.item_id, null),
    t.variance, v_uom, t.batch_id, t.location_id, t.container_id, 0, 0)
$o$,
    $n$    batch_id, location_id, container_id, unit_price_minor, net_minor,
    stock_status)
  values (
    v_tenant, v_doc, 10, t.item_id, erp.line_description(t.item_id, null),
    t.variance, v_uom, t.batch_id, t.location_id, t.container_id, 0, 0,
    t.stock_status)   -- the status counted (20260928100000)
$n$];
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already carries the status counted; left as it is', v_sig;
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
$raise_count_adjustment$;

-- The body 20260927200000 left: each line's movement in the line's status.
do $post_adjustment_lines$
declare
  v_sig constant text := 'erp.post_adjustment_lines(uuid, timestamptz, date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$        ln.container_id, v_loc, 'available'::erp.stock_status, ln.quantity,
$o$,
    $n$        ln.container_id, v_loc,
        -- The line's status, available when it names none (20260928100000).
        coalesce(ln.stock_status, 'available'::erp.stock_status), ln.quantity,
$n$,
    $o$        ln.container_id, v_loc, 'available'::erp.stock_status, -ln.quantity,
$o$,
    $n$        ln.container_id, v_loc,
        coalesce(ln.stock_status, 'available'::erp.stock_status), -ln.quantity,
$n$];
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already posts each line in its status; left as it is', v_sig;
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
$post_adjustment_lines$;

-- The body 20260927300000 left: what the system has posted unattended at a
-- place is added up per status too.
do $count_post_hold_reason$
declare
  v_sig constant text := 'erp.count_post_hold_reason(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$     and p.container_id is not distinct from t.container_id;
$o$,
    $n$     and p.container_id is not distinct from t.container_id
     -- And status (20260928100000). A count posted before a count knew its
     -- status posted to available, and reads so.
     and coalesce(p.stock_status, 'available') = coalesce(t.stock_status, 'available');
$n$,
    $o$     and o.container_id is not distinct from t.container_id;
$o$,
    $n$     and o.container_id is not distinct from t.container_id
     and coalesce(o.stock_status, 'available') = coalesce(t.stock_status, 'available');
$n$];
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already adds up per status; left as it is', v_sig;
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
$count_post_hold_reason$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. Counting again: the same key as the raise
-- ─────────────────────────────────────────────────────────────────────────────

-- The body 20260927000000 left.
do $recount_task$
declare
  v_sig constant text := 'erp.recount_task(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  perform erp.authorise('inventory.adjust', null, t.site_id, null,
                        'count_task', p_task_id);

  if exists (select 1 from erp.count_task o
$o$,
    $n$  perform erp.authorise('inventory.adjust', null, t.site_id, null,
                        'count_task', p_task_id);

  -- A count of no known status is not counted again as it is
  -- (20260928100000): the figure would again be of nobody knows which
  -- stock. It is cancelled, and the programme raised again.
  if t.stock_status is null then
    raise exception 'CLOVEERP_COUNT_STATUS_UNKNOWN: the count of % was raised before a count knew which stock it counts, and the place held stock in more than one status, so it is not counted again as it is',
      coalesce((select i.code from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id), p_task_id::text)
      using errcode = '23514',
            detail = coalesce(t.post_held_reason, ''),
            hint = 'Cancel the count and raise the counting programme again, so that each status at the place is counted on its own.';
  end if;

  if exists (select 1 from erp.count_task o
$n$,
    $o$                and o.owner_party_id is not distinct from t.owner_party_id
                and o.container_id is not distinct from t.container_id) then
$o$,
    $n$                and o.owner_party_id is not distinct from t.owner_party_id
                and o.container_id is not distinct from t.container_id
                -- The same batch and status, as the raise asks (20260928100000).
                and o.batch_id is not distinct from t.batch_id
                and (o.stock_status is null or o.stock_status = t.stock_status)) then
$n$,
    $o$     and b.owner_party_id is not distinct from t.owner_party_id
     and b.container_id is not distinct from t.container_id;
$o$,
    $n$     and b.owner_party_id is not distinct from t.owner_party_id
     and b.container_id is not distinct from t.container_id
     and b.stock_status = t.stock_status;   -- the status counted (20260928100000)
$n$,
    $o$     and al.location_id is not distinct from t.location_id
     and al.status in ('reserved', 'committed', 'picked');
$o$,
    $n$     and al.location_id is not distinct from t.location_id
     and al.batch_id is not distinct from t.batch_id
     and al.stock_status = t.stock_status
     and al.status in ('reserved', 'committed', 'picked');
$n$,
    $o$  insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id)
  values (v_tenant, p_task_id, t.location_id, t.item_id);
$o$,
    $n$  insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id,
                              batch_id, stock_status)
  values (v_tenant, p_task_id, t.location_id, t.item_id, t.batch_id, t.stock_status);
$n$];
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already counts again by batch and status; left as it is', v_sig;
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
$recount_task$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7b. Approval: a count of no known status is not approved
-- ─────────────────────────────────────────────────────────────────────────────

-- The body 20260927000000 left. The approver refuses it instead, which
-- leaves it refused, and a refused count is cancelled.
do $settle_approval_outcome$
declare
  v_sig constant text := 'erp.settle_approval_outcome(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    if found then
      -- By the lifecycle's move (20260927000000), the fact it is derived
$o$;
  v_new constant text := $n$    -- Not approved while nobody knows which stock it counts
    -- (20260928100000): its variance would have no status to post to.
    if found and q.status::text = 'approved'
       and exists (select 1 from erp.count_task t
                    where t.tenant_id = v_tenant and t.id = q.object_id and t.stock_status is null) then
      raise exception 'CLOVEERP_COUNT_STATUS_UNKNOWN: the count of % was raised before a count knew which stock it counts, and the place held stock in more than one status, so it is not approved',
        coalesce((select i.code from erp.count_task t join erp.item i on i.tenant_id = t.tenant_id and i.id = t.item_id
                   where t.tenant_id = v_tenant and t.id = q.object_id), q.object_id::text)
        using errcode = '23514',
              hint = 'Refuse the count instead. A refused count is then cancelled, and the counting programme raised again so that each status at the place is counted on its own.';
    end if;
    if found then
      -- By the lifecycle's move (20260927000000), the fact it is derived
$n$;
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already refuses to approve a count of no known status; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$settle_approval_outcome$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. What a place held at a moment
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.count_place_at(p_tenant_id uuid, p_site_id uuid, p_location_id uuid,
                                              p_item_id uuid, p_batch_id uuid, p_at timestamptz)
returns table(stock_status erp.stock_status, owner_party_id uuid, container_id uuid, quantity numeric)
language sql
stable
set search_path = ''
as $$
  -- What the company held of a product and batch at a location (anywhere
  -- at the site, for no location) at p_at, by status, owner and handling
  -- unit, as erp.raise_count_tasks() reads a place: in the company's own
  -- custody (20260928100000). Rebuilt backwards: the balance now, less every
  -- movement recorded after p_at, each side in its own status, owner,
  -- custody and place. Only the product's movements since p_at are read,
  -- through the (tenant, product, …) index, so a recent moment is cheap
  -- however long the place's history. An invoker's read: row security
  -- scopes it to the caller's organisation.
  with custody as (select erp.entity_party_for_site(p_site_id) as party_id),
  pos as (
    select b.stock_status, b.owner_party_id, b.container_id, b.quantity
      from erp.stock_balance b, custody c
     where b.tenant_id = p_tenant_id and b.item_id = p_item_id and b.site_id = p_site_id
       and (p_location_id is null or b.location_id = p_location_id)
       and b.batch_id is not distinct from p_batch_id
       and b.custody_party_id = c.party_id
    union all
    -- What arrived since, taken away.
    select m.to_status, coalesce(m.to_owner_party_id, m.owner_party_id), m.container_id, -m.quantity
      from erp.stock_movement m, custody c
     where m.tenant_id = p_tenant_id and m.item_id = p_item_id
       and m.recorded_at > p_at
       and m.batch_id is not distinct from p_batch_id
       and m.to_location_id is not null
       and coalesce(m.to_custody_party_id, m.custody_party_id) = c.party_id
       and (m.to_location_id = p_location_id
            or (p_location_id is null and exists (
                  select 1 from erp.location l
                   where l.tenant_id = m.tenant_id and l.id = m.to_location_id and l.site_id = p_site_id)))
    union all
    -- What left since, put back.
    select m.from_status, m.owner_party_id, m.container_id, m.quantity
      from erp.stock_movement m, custody c
     where m.tenant_id = p_tenant_id and m.item_id = p_item_id
       and m.recorded_at > p_at
       and m.batch_id is not distinct from p_batch_id
       and m.from_location_id is not null
       and m.custody_party_id = c.party_id
       and (m.from_location_id = p_location_id
            or (p_location_id is null and exists (
                  select 1 from erp.location l
                   where l.tenant_id = m.tenant_id and l.id = m.from_location_id and l.site_id = p_site_id)))
  )
  select p.stock_status, p.owner_party_id, p.container_id, sum(p.quantity)
    from pos p
   group by p.stock_status, p.owner_party_id, p.container_id
  having sum(p.quantity) <> 0
$$;

revoke all on function erp.count_place_at(uuid, uuid, uuid, uuid, uuid, timestamptz) from public, anon;

comment on function erp.count_place_at(uuid, uuid, uuid, uuid, uuid, timestamptz) is
  'What the company held of a product and batch at a location (or anywhere at a site) at a moment, by '
  'stock status, owner and handling unit: the balance now less every movement recorded since '
  '(20260928100000). For the count status backfill and the report of past count posts.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A9. D2: the counts in flight today are given their status, or held
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.settle_count_task_stock_status(p_tenant_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_assigned integer := 0;
  v_held     integer := 0;
  v_locks    integer := 0;
begin
  -- Decision D2 (20260928100000), for the count tasks not yet posted or
  -- cancelled that were raised before a count knew its stock status.
  -- erp.raise_count_tasks() took each task's expectation from one position
  -- of its place, of one status, owner and handling unit, so the place as it
  -- stood when the task was raised (erp.count_place_at) says which:
  --
  --   * exactly one status whose quantity, for the task's owner and handling
  --     unit, is what the task expected: that status;
  --   * none or several, with nothing but available stock at the place:
  --     available, which is what the count did until today;
  --   * none or several, with stock of another status there too: held for a
  --     person, with no status, and the place as it stood in
  --     post_held_reason ('status_unknown: …'). Nothing guesses.
  --
  -- Only work in flight is read; posted and cancelled counts are history.
  -- Run again, it finds nothing new: a held task is not looked at twice, and
  -- a task raised since has its status. For one organisation, or every
  -- organisation when none is named.
  with pending as (
    select t.id, t.tenant_id, t.site_id, t.location_id, t.item_id, t.batch_id, t.created_at,
           t.owner_party_id, t.container_id, t.expected_quantity
      from erp.count_task t
     where (p_tenant_id is null or t.tenant_id = p_tenant_id)
       and t.stock_status is null
       and t.status in ('open', 'counted', 'pending_approval', 'approved', 'rejected')
       and coalesce(t.post_held_reason, '') not like 'status_unknown:%'
  ),
  pos as (
    select p.id, x.stock_status, x.owner_party_id, x.container_id, x.quantity
      from pending p
      cross join lateral erp.count_place_at(p.tenant_id, p.site_id, p.location_id, p.item_id,
                                            p.batch_id, p.created_at) x
  ),
  judged as (
    select p.id, p.expected_quantity,
           -- The statuses whose quantity, for the task's owner and unit, is
           -- what it expected.
           (select array_agg(q.stock_status)
              from (select x.stock_status, sum(x.quantity) as quantity
                      from pos x
                     where x.id = p.id
                       and x.owner_party_id is not distinct from p.owner_party_id
                       and (p.container_id is null or x.container_id = p.container_id)
                     group by x.stock_status) q
             where q.quantity = p.expected_quantity) as matches,
           exists (select 1 from pos x
                    where x.id = p.id and x.stock_status <> 'available') as other_beside,
           (select string_agg(trim_scale(q.quantity) || ' ' || replace(q.stock_status::text, '_', ' '),
                              ', ' order by q.stock_status)
              from (select x.stock_status, sum(x.quantity) as quantity
                      from pos x where x.id = p.id group by x.stock_status) q) as place
      from pending p
  ),
  decided as (
    select j.*,
           case when cardinality(j.matches) = 1 then j.matches[1]
                when not j.other_beside then 'available'::erp.stock_status
           end as stock_status
      from judged j
  ),
  held as (
    update erp.count_task t
       set post_held_reason = left(format(
             'status_unknown: when this count was raised, expecting %s, the place held %s, so which of its stock the count is of is not known%s',
             trim_scale(d.expected_quantity), coalesce(d.place, 'nothing'),
             coalesce('; it said before: ' || t.post_held_reason, '')), 1000),
           updated_at = now()
      from decided d
     where t.id = d.id and d.stock_status is null
    returning t.id
  ),
  assigned as (
    update erp.count_task t
       set stock_status = d.stock_status, updated_at = now()
      from decided d
     where t.id = d.id and d.stock_status is not null
    returning t.id
  )
  select (select count(*) from assigned), (select count(*) from held)
    into v_assigned, v_held;

  -- The locks still live take their task's batch and status: a held task's
  -- lock keeps covering every status at its place.
  update erp.count_lock l
     set batch_id = t.batch_id, stock_status = t.stock_status, updated_at = now()
    from erp.count_task t
   where t.tenant_id = l.tenant_id and t.id = l.count_task_id
     and l.released_at is null
     and (p_tenant_id is null or l.tenant_id = p_tenant_id)
     and (l.batch_id is distinct from t.batch_id or l.stock_status is distinct from t.stock_status);
  get diagnostics v_locks = row_count;

  return jsonb_build_object('assigned', v_assigned, 'held', v_held, 'locks', v_locks);
end;
$$;

revoke all on function erp.settle_count_task_stock_status(uuid) from public, anon, authenticated;

comment on function erp.settle_count_task_stock_status(uuid) is
  'Decision D2 of PR11 (20260928100000): every count task in flight raised before a count knew its '
  'stock status is given the status whose quantity at its place, owner and unit when it was raised is '
  'what it expected, or available where nothing else stood there; otherwise it is held for a person '
  'with the reason in post_held_reason. Live locks take their task''s batch and status. Idempotent. '
  'Run once by its migration over every organisation, and by erp_test.count_by_status_suite for its own.';

-- Once, over every organisation. It reads only the counts in flight, and
-- for each only its product's movements since it was raised.
select erp.settle_count_task_stock_status(null);

-- ─────────────────────────────────────────────────────────────────────────────
-- A9a. Once: a held count already approved is put back to refused
--
-- An approved count moves only by its post, and a held count's variance has
-- no status to post to. The count task lifecycle has no move from approved
-- to refused, and giving it one is a new version of it, which is not this
-- migration's. So each such count, of which there can be none raised from
-- here on, is put back here, once: its lifecycle state and its column to
-- rejected, a line on its history saying so and why, and its lock released.
-- Refused, it is cancelled on the worklist. This is a statement of the
-- migration and not a routine, so nothing can do it again.
-- ─────────────────────────────────────────────────────────────────────────────

do $held_approved$
declare
  r       record;
  v_state uuid;
  v_n     integer := 0;
  v_why   constant text :=
    'Put back to refused by 20260928100000: raised before a count knew which stock it counts, at a place '
    'holding stock in more than one status, it could not be posted. Cancel it and raise the programme again.';
begin
  for r in
    select t.id, t.tenant_id, t.post_held_reason,
           os.id as os_id, os.state_machine_version_id as version_id, s.code as from_code
      from erp.count_task t
      left join erp.object_state os
        on os.tenant_id = t.tenant_id and os.object_type = 'count_task' and os.object_id = t.id
      left join erp.state s on s.tenant_id = os.tenant_id and s.id = os.current_state_id
     where t.stock_status is null and t.status = 'approved'
       and t.post_held_reason like 'status_unknown:%'
     for update of t
  loop
    if r.os_id is not null then
      select st.id into v_state
        from erp.state st
       where st.tenant_id = r.tenant_id and st.state_machine_version_id = r.version_id
         and st.code = 'rejected';
      if v_state is null or r.from_code is distinct from 'approved' then
        raise exception 'CLOVEERP_ANCHOR_MOVED: count task % reads % in a lifecycle with no refused state, or is not approved in it',
          r.id, coalesce(r.from_code, 'no state');
      end if;
      update erp.object_state
         set current_state_id = v_state, entered_at = clock_timestamp(), updated_at = now()
       where id = r.os_id;
      insert into erp.state_transition_log (tenant_id, object_type, object_id, transition_code,
                                            from_state_code, to_state_code, reason)
      values (r.tenant_id, 'count_task', r.id, null, 'approved', 'rejected', v_why);
    end if;
    update erp.count_task
       set status = 'rejected',
           post_held_reason = left(r.post_held_reason || '; ' || v_why, 1000),
           updated_at = now()
     where id = r.id;
    update erp.count_lock
       set released_at = now(), updated_at = now()
     where tenant_id = r.tenant_id and count_task_id = r.id and released_at is null;
    v_n := v_n + 1;
  end loop;
  raise notice '20260928100000: % held count(s) approved before it were put back to refused', v_n;
end
$held_approved$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A9b. From here on a task is written with a status, and a line can carry one
--
-- A task written with none, as a suite plants one, is a count of available
-- stock, which is what a count was. Set after the backfill, so the backfill
-- read only the tasks raised before it.
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.count_task alter column stock_status set default 'available';

alter table erp.document_line add column if not exists stock_status erp.stock_status;

comment on column erp.document_line.stock_status is
  'The stock status a stock adjustment''s line corrects (20260928100000); null is available. Written '
  'by a count''s adjustment, read by the adjustment''s line routine.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A10. D3: the past counts whose difference went to available
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.count_posts_past_their_status_report()
returns table(count_task_id uuid, posted_at timestamptz, item_code text, location_code text,
              batch_number text, adjustment_number text, expected_quantity numeric,
              variance numeric, counted_status text, available_then numeric, next_action text)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Decision D3 (20260928100000). Every count in the organisation it is run
  -- in that posted a difference before a count knew its stock status, and so
  -- posted it to available, whose expectation was what stood in another
  -- status at its place, owner and unit when it was raised (the raise took
  -- it from exactly one such position), and not what was available. Its
  -- difference, found or missing, belonged to that status. Read only; it
  -- repairs nothing, because what the shelves held then is for a person to
  -- say. The runbook carries the same reading as plain SQL, for the run
  -- before the deploy, when this does not exist yet.
  with t as (select erp.require_tenant_id() as tenant_id),
  posted as (
    select c.*
      from t
      join erp.count_task c on c.tenant_id = t.tenant_id
     where c.status = 'posted' and c.stock_status is null
       and coalesce(c.variance, 0) <> 0
  ),
  pos as (
    select p.id, x.stock_status, sum(x.quantity) as quantity
      from posted p
      cross join lateral erp.count_place_at(p.tenant_id, p.site_id, p.location_id, p.item_id,
                                            p.batch_id, p.created_at) x
     where x.owner_party_id is not distinct from p.owner_party_id
       and (p.container_id is null or x.container_id = p.container_id)
     group by p.id, x.stock_status
  ),
  judged as (
    select p.*,
           coalesce((select x.quantity from pos x
                      where x.id = p.id and x.stock_status = 'available'), 0) as available_then,
           (select string_agg(replace(x.stock_status::text, '_', ' '), ' or ' order by x.stock_status)
              from pos x
             where x.id = p.id and x.stock_status <> 'available'
               and x.quantity = p.expected_quantity) as counted_status
      from posted p
  )
  select j.id, j.posted_at, i.code, l.code, b.batch_number, d.document_number,
         j.expected_quantity, j.variance, j.counted_status, j.available_then,
         format('Check the place. If the count was of the %s stock, correct it by a status change that moves %s from %s to %s, once a person has agreed it; nothing is corrected automatically.',
                j.counted_status, trim_scale(abs(j.variance)),
                case when j.variance < 0 then j.counted_status else 'available' end,
                case when j.variance < 0 then 'available' else j.counted_status end)
    from judged j
    join erp.item i on i.tenant_id = j.tenant_id and i.id = j.item_id
    left join erp.location l on l.tenant_id = j.tenant_id and l.id = j.location_id
    left join erp.batch b on b.tenant_id = j.tenant_id and b.id = j.batch_id
    left join erp.document d on d.tenant_id = j.tenant_id and d.id = j.adjustment_document_id
   where j.counted_status is not null
     and j.available_then <> j.expected_quantity
   order by j.posted_at, j.id
$$;

-- Granted as every tenant report in the diagnostic register is: to the
-- signed-in, by erp.apply_execute_grants(), for erp.run_diagnostic(). It is
-- an invoker read of the caller's own organisation under row security, and
-- names no routine that writes.
revoke all on function erp.count_posts_past_their_status_report() from public, anon;

comment on function erp.count_posts_past_their_status_report() is
  'Every count in this organisation that posted a difference, found or missing, to available before a '
  'count knew its stock status, whose expectation was what stood in another status at its place when '
  'it was raised and not what was available: its difference belonged to that status. With what to do. '
  'Read only; a report, not an assertion, run by an operator '
  '(supabase/ops/20260928_count_posts_past_their_status.sql) (20260928100000).';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('count_posts_past_their_status', 'Counts whose difference went to available stock', 'report', 'tenant',
   'count_posts_past_their_status_report', '', null, '',
   'Counts posted before a count knew its stock status whose expectation was quarantined or other stock, not available, so their difference went to the wrong status; for a person to correct.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb;

-- ─────────────────────────────────────────────────────────────────────────────
-- A11. The worklist door says the status
-- ─────────────────────────────────────────────────────────────────────────────

-- The door as 20260927400000 left it, or stop.
do $door$
declare
  v_sig constant text := 'public.erp_count_tasks(integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    $o$      'post_held_reason', case when c.status = 'approved' then c.post_held_reason end,
$o$;
  v_new constant text :=
    $n$      -- The status the count is of, and why a count held because it is
      -- not known waits while it is still to be counted (20260928100000).
      'stock_status', c.stock_status,
      'post_held_reason', case when c.status = 'approved'
                                 or (c.stock_status is null
                                     and c.status in ('open', 'counted', 'pending_approval', 'rejected')
                                     and c.post_held_reason like 'status_unknown:%')
                               then c.post_held_reason end,
$n$;
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already says the status; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  if (select p.prosecdef or p.provolatile <> 's'
             or p.prolang <> (select l.oid from pg_language l where l.lanname = 'sql')
             or p.proconfig is distinct from array['search_path=""']
        from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is no longer a stable sql door with an empty search path', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$door$;

-- Its grants and governance, as before.
do $door_kept$
declare
  v_sig constant text := 'public.erp_count_tasks(integer)';
begin
  if not has_function_privilege('authenticated', v_sig, 'execute')
     or not has_function_privilege('service_role', v_sig, 'execute')
     or has_function_privilege('anon', v_sig, 'execute') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not executable by exactly the signed-in and the service', v_sig;
  end if;
  if (select p.provolatile <> 's' or p.prosecdef or p.prosrc like '%erp.authorise(%'
        from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no longer reads as a stable door that authorises nothing', v_sig;
  end if;
end
$door_kept$;

comment on function public.erp_count_tasks(integer) is
  'The organisation''s count tasks, open work first, up to p_limit: the place, the stock status '
  'counted, the figures and where each stands, the count sheet and line it is on (null when raised '
  'with no sheet), the stock adjustment its post wrote, whether the system posted it as it was '
  'recorded, why an approved count waits for somebody to post it or a count of no known status is '
  'held, and whether the reader counted it (20260927400000, 20260928100000). Authorises nothing; the '
  'tenant filter and row security scope it.';

-- The worklist suite reads the new key on every row (20260928100000).
do $count_worklist_suite$
declare
  v_sig constant text := 'erp_test.count_worklist_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    'sheet_line_no', 'site', 'site_id', 'status', 'task_id', 'variance', 'within_tolerance'];
$o$,
    $n$    'sheet_line_no', 'site', 'site_id', 'status', 'stock_status', 'task_id', 'variance',
    'within_tolerance'];   -- stock_status since 20260928100000: 25 keys
$n$,
    $o$        or x ? 'batch' is false or x -> 'batch' <> 'null'::jsonb;
$o$,
    $n$        or x ? 'batch' is false or x -> 'batch' <> 'null'::jsonb
        -- Every count here is of available stock (20260928100000).
        or x ->> 'stock_status' is distinct from 'available';
$n$];
  v_hits integer;
begin
  if position('20260928100000' in v_def) > 0 then
    raise notice '% already reads the status; left as it is', v_sig;
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
$count_worklist_suite$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.count_by_status_suite
--
-- One organisation, one place, not yet live, so each count inside its
-- tolerance posts as it is recorded by a counter who may only count. At the
-- place: a product sixty available and forty in quarantine; one only in
-- quarantine, counted where there is no stock adjustment type, by the old
-- route; one in two batches, two of the second promised to an order; four
-- raised as counts were raised before this migration; one waiting for its
-- approver; one counted again the next day, once live; and four planted as
-- the old route posted a count of quarantined stock, and of available.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.count_by_status_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_owner  text := current_user;
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  r        record;
  res      jsonb;
  v_tok    text; v_tok3 text;
  v_second uuid; v_counter uuid; p1 uuid;
  csf uuid; csp uuid; csi uuid;
  v_uom uuid; v_sup uuid; v_grn uuid; v_line uuid; v_company uuid; v_alloc uuid;
  s_main uuid; v_recv uuid;
  i_q uuid; i_f uuid; i_bt uuid; i_ka uuid; i_kh uuid; i_kl uuid; i_kq uuid; i_hp uuid; i_c uuid;
  i_r uuid; i_r2 uuid; i_r3 uuid; i_r4 uuid;
  b1 uuid; b2 uuid;
  pg_old uuid;
  t_qa uuid; t_qq uuid; t_f uuid; t_b1 uuid; t_b2 uuid;
  t_ka uuid; t_kh uuid; t_kl uuid; t_kq uuid; t_kp uuid; t_hp uuid; t_c uuid;
  v_req uuid; v_atask uuid;
  v_raised integer; v_raised2 integer; v_raised3 integer;
  v_st_qq text; v_st_qa text; v_st_f text; v_st_b2 text; v_st_b2r text; v_st_hp text; v_st_c text;
  v_settle jsonb; v_settle2 jsonb;
  v_err text; v_hint text; v_err_cancel text; v_err_approve text; v_err_recount text; v_err_cancel2 text;
  v_after_reject text; v_after_cancel text;
  v_rows jsonb; x_qa jsonb; x_qq jsonb; x_kh jsonb;
  v_books text;
  v_n integer;
  v_fixture text;
begin
  -- 1. The shape: the columns, their defaults, and the routines, the
  --    backfill executable by nobody signed in.
  return query select 'a count task, its lock and a document line each carry a stock status, the task''s written as available when none is given, the lock''s batch as well',
    (select format_type(a.atttypid, a.atttypmod) = 'erp.stock_status' and not a.attnotnull
            and pg_get_expr(d.adbin, d.adrelid) = '''available''::erp.stock_status'
       from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
      where a.attrelid = 'erp.count_task'::regclass and a.attname = 'stock_status')
    and (select count(*) from pg_attribute a
          where not a.attisdropped and not a.attnotnull and not a.atthasdef
            and ((a.attrelid = 'erp.count_lock'::regclass and a.attname in ('batch_id', 'stock_status'))
                 or (a.attrelid = 'erp.document_line'::regclass and a.attname = 'stock_status'))) = 3
    and exists (select 1 from pg_constraint c
                 where c.conrelid = 'erp.count_lock'::regclass and c.conname = 'count_lock_batch_fkey'
                   and c.convalidated)
    and to_regprocedure('erp.count_posts_past_their_status_report()') is not null
    and to_regprocedure('erp.count_place_at(uuid, uuid, uuid, uuid, uuid, timestamptz)') is not null
    and not has_function_privilege('authenticated', 'erp.settle_count_task_stock_status(uuid)', 'execute')
    and not has_function_privilege('anon', 'erp.settle_count_task_stock_status(uuid)', 'execute'),
    'count_task.stock_status, count_lock.batch_id and stock_status, document_line.stock_status; the report, the place rebuilt and the backfill';

  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-cbs-' || v_hex, 'Count by status suite',
      'a@zz-cbs-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    p1 := erp.current_principal_id();
    res := public.erp_invite_principal('second@zz-cbs-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('counter@zz-cbs-' || v_hex || '.test', 'Stock Counter');
    v_counter := (res ->> 'app_user_id')::uuid; v_tok3 := res ->> 'token';
    perform erp.grant_role(v_counter, 'stock_counter', null, null, 'counts the shelves');

    v_fixture := 'installing';
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(v_tok3);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    v_company := erp.entity_party(r.entity_id);

    v_fixture := 'the place and its stock';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into s_main;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, s_main, 'RECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'Q', 'Available and quarantined', v_uom, 'active') returning id into i_q;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'F', 'Quarantined, the old route', v_uom, 'active') returning id into i_f;
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, status) values
      (r.tenant_id, 'BT', 'Two batches', v_uom, true, 'active') returning id into i_bt;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'KA', 'Raised before, available only', v_uom, 'active') returning id into i_ka;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'KH', 'Raised before, as much of each', v_uom, 'active') returning id into i_kh;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'KL', 'Raised before, quarantined after', v_uom, 'active') returning id into i_kl;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'KQ', 'Raised before, of the quarantined', v_uom, 'active') returning id into i_kq;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'HP', 'Held, with its approver', v_uom, 'active') returning id into i_hp;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'C', 'Posted by the system yesterday', v_uom, 'active') returning id into i_c;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'R', 'Past: a quarantined shortfall to available', v_uom, 'active') returning id into i_r;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'R2', 'Past: an available count', v_uom, 'active') returning id into i_r2;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'R3', 'Past: as much of each', v_uom, 'active') returning id into i_r3;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'R4', 'Past: a quarantined excess to available', v_uom, 'active') returning id into i_r4;
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_main);
    perform erp.add_document_line(v_grn, i_q, 100, 100, 'Q');
    perform erp.add_document_line(v_grn, i_f, 50, 100, 'F');
    perform erp.add_document_line(v_grn, i_ka, 10, 100, 'KA');
    perform erp.add_document_line(v_grn, i_kh, 10, 100, 'KH');
    perform erp.add_document_line(v_grn, i_kl, 10, 100, 'KL');
    perform erp.add_document_line(v_grn, i_kq, 10, 100, 'KQ');
    perform erp.add_document_line(v_grn, i_hp, 100, 100, 'HP');
    perform erp.add_document_line(v_grn, i_c, 100, 100, 'C');
    perform erp.add_document_line(v_grn, i_r, 100, 100, 'R');
    perform erp.add_document_line(v_grn, i_r2, 5, 100, 'R2');
    perform erp.add_document_line(v_grn, i_r3, 10, 100, 'R3');
    perform erp.add_document_line(v_grn, i_r4, 10, 100, 'R4');
    perform erp.transition_document(v_grn, 'post');
    b1 := erp.create_batch(i_bt, 'ZZ-B1-' || v_hex);
    b2 := erp.create_batch(i_bt, 'ZZ-B2-' || v_hex);
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_main);
    v_line := erp.add_document_line(v_grn, i_bt, 6, 300, 'BT b1');
    update erp.document_line set location_id = v_recv, batch_id = b1 where id = v_line;
    v_line := erp.add_document_line(v_grn, i_bt, 4, 300, 'BT b2');
    update erp.document_line set location_id = v_recv, batch_id = b2 where id = v_line;
    perform erp.transition_document(v_grn, 'post');

    -- Two of batch two promised to an order.
    insert into erp.allocation (tenant_id, entity_id, site_id, item_id, quantity, uom_id)
    values (r.tenant_id, r.entity_id, s_main, i_bt, 2, v_uom) returning id into v_alloc;
    insert into erp.allocation_line (tenant_id, allocation_id, location_id, batch_id, stock_status, quantity, status)
    values (r.tenant_id, v_alloc, v_recv, b2, 'available', 2, 'reserved');

    -- Into quarantine where they stand: forty of Q, all of F, half of KH,
    -- four of KQ, and all of R, and of R4, half of R3.
    v_fixture := 'quarantine';
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
      from_location_id, from_status, to_location_id, to_status, quantity, uom_id, currency, reason_code)
    values (r.tenant_id, r.entity_id, s_main, 'status_change', i_q, v_recv, 'available', v_recv, 'quarantine', 40, v_uom, 'GBP', 'QA_HOLD'),
           (r.tenant_id, r.entity_id, s_main, 'status_change', i_f, v_recv, 'available', v_recv, 'quarantine', 50, v_uom, 'GBP', 'QA_HOLD'),
           (r.tenant_id, r.entity_id, s_main, 'status_change', i_kh, v_recv, 'available', v_recv, 'quarantine', 5, v_uom, 'GBP', 'QA_HOLD'),
           (r.tenant_id, r.entity_id, s_main, 'status_change', i_kq, v_recv, 'available', v_recv, 'quarantine', 4, v_uom, 'GBP', 'QA_HOLD'),
           (r.tenant_id, r.entity_id, s_main, 'status_change', i_r, v_recv, 'available', v_recv, 'quarantine', 100, v_uom, 'GBP', 'QA_HOLD'),
           (r.tenant_id, r.entity_id, s_main, 'status_change', i_r3, v_recv, 'available', v_recv, 'quarantine', 5, v_uom, 'GBP', 'QA_HOLD'),
           (r.tenant_id, r.entity_id, s_main, 'status_change', i_r4, v_recv, 'available', v_recv, 'quarantine', 10, v_uom, 'GBP', 'QA_HOLD');

    -- Inside two units, nobody to approve anything outside them; and one
    -- programme inside one unit, whose approver is an administrator.
    insert into erp.count_programme (tenant_id, code, name, kind, selector,
                                     tolerance_absolute, tolerance_pct, approval_chain_code, status)
    values (r.tenant_id, 'zz_cbs', 'By status and batch', 'cycle',
            '{"or": [{"==": [{"var": "item_code"}, "Q"]}, {"==": [{"var": "item_code"}, "F"]},
                     {"==": [{"var": "item_code"}, "BT"]}]}'::jsonb, 2, 0, null, 'active'),
           (r.tenant_id, 'zz_old', 'Raised before', 'cycle',
            '{"or": [{"==": [{"var": "item_code"}, "KA"]}, {"==": [{"var": "item_code"}, "KH"]},
                     {"==": [{"var": "item_code"}, "KL"]}, {"==": [{"var": "item_code"}, "KQ"]}]}'::jsonb,
            2, 0, null, 'active'),
           (r.tenant_id, 'zz_pend', 'With its approver', 'cycle',
            '{"==": [{"var": "item_code"}, "HP"]}'::jsonb, 1, 0, 'count_variance', 'active'),
           (r.tenant_id, 'zz_c', 'Counted again the next day', 'cycle',
            '{"==": [{"var": "item_code"}, "C"]}'::jsonb, 2, 0, null, 'active');
    select p.id into pg_old from erp.count_programme p where p.tenant_id = r.tenant_id and p.code = 'zz_old';

    -- Four counts as a count was raised before this migration: no status on
    -- the task or its lock, owned by the company as a raise writes it; and a
    -- fifth long posted. Raised now, after the quarantine above: KH expected
    -- five where five stood of each status, KQ four where four stood in
    -- quarantine; KL's place is quarantined only afterwards.
    v_fixture := 'raised before';
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id,
                                expected_quantity, status, stock_status, created_at, owner_party_id)
    values (r.tenant_id, pg_old, s_main, v_recv, i_ka, 10, 'open', null, clock_timestamp(), v_company)
    returning id into t_ka;
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id,
                                expected_quantity, status, stock_status, created_at, owner_party_id)
    values (r.tenant_id, pg_old, s_main, v_recv, i_kh, 5, 'open', null, clock_timestamp(), v_company)
    returning id into t_kh;
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id,
                                expected_quantity, status, stock_status, created_at, owner_party_id)
    values (r.tenant_id, pg_old, s_main, v_recv, i_kl, 10, 'open', null, clock_timestamp(), v_company)
    returning id into t_kl;
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id,
                                expected_quantity, status, stock_status, created_at, owner_party_id)
    values (r.tenant_id, pg_old, s_main, v_recv, i_kq, 4, 'open', null, clock_timestamp(), v_company)
    returning id into t_kq;
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id,
                                expected_quantity, counted_quantity, variance, status, stock_status,
                                created_at, posted_at, owner_party_id)
    values (r.tenant_id, pg_old, s_main, v_recv, i_kh, 10, 10, 0, 'posted', null,
            clock_timestamp() - interval '40 days', clock_timestamp() - interval '40 days', v_company)
    returning id into t_kp;
    insert into erp.count_lock (tenant_id, count_task_id, location_id, item_id)
    values (r.tenant_id, t_ka, v_recv, i_ka), (r.tenant_id, t_kh, v_recv, i_kh),
           (r.tenant_id, t_kl, v_recv, i_kl), (r.tenant_id, t_kq, v_recv, i_kq);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
      from_location_id, from_status, to_location_id, to_status, quantity, uom_id, currency, reason_code)
    values (r.tenant_id, r.entity_id, s_main, 'status_change', i_kl, v_recv, 'available', v_recv, 'quarantine', 3, v_uom, 'GBP', 'QA_HOLD');

    -- The counter raises the programme.
    v_fixture := 'raising';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_raised := public.erp_raise_count_tasks('zz_cbs');
    select t.id into t_qa from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_q and t.stock_status = 'available';
    select t.id into t_qq from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_q and t.stock_status = 'quarantine';
    select t.id into t_f  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_f;
    select t.id into t_b1 from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_bt and t.batch_id = b1;
    select t.id into t_b2 from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_bt and t.batch_id = b2;

    -- 2. Quarantined and available stock at one place: two counts.
    return query select 'quarantined and available stock of one product at one place raise two counts, each of its own status, expecting what that status holds, on its own sheet line and under its own lock',
      v_raised = 5
      and (select string_agg(t.stock_status::text || ' ' || trim_scale(t.expected_quantity), ', ' order by t.stock_status)
             from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_q) = 'available 60, quarantine 40'
      and (select count(*) from erp.count_task t
             join erp.document_line l on l.id = t.document_line_id
            where t.id in (t_qa, t_qq) and l.stock_status = t.stock_status
              and l.quantity = t.expected_quantity) = 2
      and (select count(*) from erp.count_lock l join erp.count_task t on t.id = l.count_task_id
            where t.id in (t_qa, t_qq) and l.released_at is null
              and l.stock_status = t.stock_status and l.batch_id is null) = 2
      and (select t.stock_status from erp.count_task t where t.id = t_f) = 'quarantine',
      format('%s count(s) raised; Q: %s; F: %s', v_raised,
             (select string_agg(t.stock_status::text || ' ' || trim_scale(t.expected_quantity), ', ' order by t.stock_status)
                from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_q),
             (select t.stock_status::text || ' ' || trim_scale(t.expected_quantity) from erp.count_task t where t.id = t_f));

    -- 3. Two batches at one place: two counts.
    return query select 'two batches of one product at one place raise two counts, one per batch, each on its own sheet line and under its own lock',
      (select string_agg(b.batch_number || ' ' || trim_scale(t.expected_quantity), ', ' order by b.batch_number)
         from erp.count_task t join erp.batch b on b.id = t.batch_id
        where t.tenant_id = r.tenant_id and t.item_id = i_bt)
        = format('ZZ-B1-%s 6, ZZ-B2-%s 4', v_hex, v_hex)
      and (select count(*) from erp.count_task t
             join erp.document_line l on l.id = t.document_line_id
            where t.id in (t_b1, t_b2) and l.batch_id = t.batch_id and l.stock_status = 'available') = 2
      and (select count(*) from erp.count_lock l join erp.count_task t on t.id = l.count_task_id
            where t.id in (t_b1, t_b2) and l.released_at is null and l.batch_id = t.batch_id
              and l.stock_status = 'available') = 2,
      coalesce((select string_agg(coalesce(b.batch_number, '-') || ' ' || trim_scale(t.expected_quantity), ', ' order by b.batch_number)
                  from erp.count_task t left join erp.batch b on b.id = t.batch_id
                 where t.tenant_id = r.tenant_id and t.item_id = i_bt), 'no count of BT');

    -- 4. What is promised to an order is read for the batch and status
    --    counted.
    return query select 'what is promised to orders is set aside only from the count of its own batch and status',
      (select t.committed_quantity from erp.count_task t where t.id = t_b2) = 2
      and (select t.committed_quantity from erp.count_task t where t.id = t_b1) = 0
      and (select t.committed_quantity from erp.count_task t where t.id = t_qa) = 0
      and (select t.committed_quantity from erp.count_task t where t.id = t_qq) = 0,
      format('batch two %s, batch one %s, Q available %s, Q quarantine %s',
             (select trim_scale(t.committed_quantity) from erp.count_task t where t.id = t_b2),
             (select trim_scale(t.committed_quantity) from erp.count_task t where t.id = t_b1),
             (select trim_scale(t.committed_quantity) from erp.count_task t where t.id = t_qa),
             (select trim_scale(t.committed_quantity) from erp.count_task t where t.id = t_qq));

    -- Stock moves while they are counted: five of Q into quarantine, one of
    -- batch one into quarantine.
    v_fixture := 'moving during the count';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
      from_location_id, from_status, to_location_id, to_status, quantity, uom_id, currency, reason_code)
    values (r.tenant_id, r.entity_id, s_main, 'status_change', i_q, null, v_recv, 'available', v_recv, 'quarantine', 5, v_uom, 'GBP', 'QA_HOLD'),
           (r.tenant_id, r.entity_id, s_main, 'status_change', i_bt, b1, v_recv, 'available', v_recv, 'quarantine', 1, v_uom, 'GBP', 'QA_HOLD');

    -- 5. Each count took only what moved in its own status and batch.
    return query select 'stock moving while it is counted reaches only the count of its own batch and status: out of available and into quarantine, and nothing of the other batch',
      (select t.movement_during from erp.count_task t where t.id = t_qa) = -5
      and (select t.movement_during from erp.count_task t where t.id = t_qq) = 5
      and (select t.movement_during from erp.count_task t where t.id = t_b1) = -1
      and (select t.movement_during from erp.count_task t where t.id = t_b2) = 0
      and (select t.movement_during from erp.count_task t where t.id = t_f) = 0,
      format('Q available %s, Q quarantine %s, BT batch one %s, batch two %s, F %s',
             (select trim_scale(t.movement_during) from erp.count_task t where t.id = t_qa),
             (select trim_scale(t.movement_during) from erp.count_task t where t.id = t_qq),
             (select trim_scale(t.movement_during) from erp.count_task t where t.id = t_b1),
             (select trim_scale(t.movement_during) from erp.count_task t where t.id = t_b2),
             (select trim_scale(t.movement_during) from erp.count_task t where t.id = t_f));

    -- 6. Raised again while they are in flight.
    v_fixture := 'raising again';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_raised2 := public.erp_raise_count_tasks('zz_cbs');
    return query select 'raising the programme again while its counts are in flight raises only what no count covers: the batch put into quarantine since',
      v_raised2 = 1
      and (select count(*) from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id in (i_q, i_f, i_bt)) = 6
      and exists (select 1 from erp.count_task t
                   where t.tenant_id = r.tenant_id and t.item_id = i_bt and t.batch_id = b1
                     and t.stock_status = 'quarantine' and t.expected_quantity = 1 and t.status = 'open'),
      format('%s count(s) raised the second time', v_raised2);

    -- The counter counts Q: one short in quarantine, one over in available,
    -- each inside the tolerance, so each posts as it is recorded.
    v_fixture := 'counting Q';
    v_st_qq := public.erp_record_count(t_qq, 44)::text;
    v_st_qa := public.erp_record_count(t_qa, 56)::text;

    -- 7. The quarantined count's shortfall left quarantine.
    return query select 'a count of quarantined stock posts its shortfall out of quarantine through its adjustment, whose line says so, and available stock is not touched by it',
      v_st_qq = 'posted'
      and (select l.stock_status from erp.count_task t join erp.document_line l on l.id = t.adjustment_line_id
            where t.id = t_qq) = 'quarantine'
      and (select string_agg(m.from_status::text || ' ' || trim_scale(m.quantity), ', ')
             from erp.count_task t join erp.stock_movement m on m.document_id = t.adjustment_document_id
            where t.id = t_qq) = 'quarantine 1'
      and (select d.attributes ->> 'reason_note' from erp.count_task t join erp.document d on d.id = t.adjustment_document_id
            where t.id = t_qq) like '% in quarantine',
      format('recorded %s; movement %s; note %s', v_st_qq,
             (select string_agg(coalesce(m.from_status::text, '-') || ' to ' || coalesce(m.to_status::text, '-') || ' ' || trim_scale(m.quantity), ', ')
                from erp.count_task t join erp.stock_movement m on m.document_id = t.adjustment_document_id
               where t.id = t_qq),
             (select d.attributes ->> 'reason_note' from erp.count_task t join erp.document d on d.id = t.adjustment_document_id
               where t.id = t_qq));

    -- 8. And the available count's excess reached available; the books agree.
    v_books := erp_test.count_books_agree();
    return query select 'a count of available stock at the same place posts to available, each status ends where it was counted, and the books agree',
      v_st_qa = 'posted'
      and (select string_agg(m.to_status::text || ' ' || trim_scale(m.quantity), ', ')
             from erp.count_task t join erp.stock_movement m on m.document_id = t.adjustment_document_id
            where t.id = t_qa) = 'available 1'
      and (select string_agg(b.stock_status::text || ' ' || trim_scale(b.quantity), ', ' order by b.stock_status)
             from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_q) = 'available 56, quarantine 44'
      and v_books = 'passed',
      format('recorded %s; Q stands %s; books %s', v_st_qa,
             (select string_agg(b.stock_status::text || ' ' || trim_scale(b.quantity), ', ' order by b.stock_status)
                from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_q), v_books);

    -- 9. The old route: an organisation with no stock adjustment type.
    v_fixture := 'the old route';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.document_type set status = 'inactive' where tenant_id = r.tenant_id and code = 'stock_adjustment';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_st_f := public.erp_record_count(t_f, 48)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.document_type set status = 'active' where tenant_id = r.tenant_id and code = 'stock_adjustment';
    return query select 'where there is no stock adjustment type, the movement a count writes leaves the status counted',
      v_st_f = 'posted'
      and (select t.adjustment_document_id from erp.count_task t where t.id = t_f) is null
      and (select string_agg(m.from_status::text || ' ' || trim_scale(m.quantity), ', ')
             from erp.stock_movement m
            where m.tenant_id = r.tenant_id and m.item_id = i_f and m.movement_type = 'count_adjustment') = 'quarantine 2'
      and (select string_agg(b.stock_status::text || ' ' || trim_scale(b.quantity), ', ' order by b.stock_status)
             from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_f and b.quantity <> 0) = 'quarantine 48'
      and erp_test.count_books_agree() = 'passed',
      format('recorded %s; F stands %s', v_st_f,
             (select string_agg(b.stock_status::text || ' ' || trim_scale(b.quantity), ', ' order by b.stock_status)
                from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_f));

    -- 10. Counted again: batch two, outside its tolerance with nobody to
    --     approve it, sent back while batch one's counts are still open.
    v_fixture := 'counting batch two again';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_st_b2 := public.erp_record_count(t_b2, 10)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_st_b2r := public.erp_recount_task(t_b2)::text;
    return query select 'a count of one batch is counted again while the other batch''s counts are open, re-reading what its own batch and status hold and are promised, under a lock of the same',
      v_st_b2 = 'counted' and v_st_b2r = 'open'
      and (select count(*) from erp.count_task t
            where t.tenant_id = r.tenant_id and t.item_id = i_bt and t.batch_id = b1 and t.status = 'open') = 2
      and (select t.expected_quantity = 4 and t.committed_quantity = 2 and t.status = 'open'
             from erp.count_task t where t.id = t_b2)
      and (select count(*) from erp.count_lock l
            where l.count_task_id = t_b2 and l.released_at is null
              and l.batch_id = b2 and l.stock_status = 'available') = 1
      and (select count(*) from erp.count_lock l where l.count_task_id = t_b2 and l.released_at is null) = 1,
      format('recorded %s, sent back %s; batch two expects %s with %s promised; its live locks %s',
             v_st_b2, v_st_b2r,
             (select trim_scale(t.expected_quantity) from erp.count_task t where t.id = t_b2),
             (select trim_scale(t.committed_quantity) from erp.count_task t where t.id = t_b2),
             (select string_agg(coalesce(l.stock_status::text, 'any') || ' of ' || coalesce(l.batch_id::text, 'no batch'), ', ')
                from erp.count_lock l where l.count_task_id = t_b2 and l.released_at is null));

    -- 11. The backfill, D2, over this organisation, twice.
    v_fixture := 'the backfill';
    v_settle := erp.settle_count_task_stock_status(r.tenant_id);
    v_settle2 := erp.settle_count_task_stock_status(r.tenant_id);
    return query select 'the counts raised before a count knew its status are given the status whose stock they expected, available where nothing else stood, and held only where as much stood in more than one; history and a second run are left alone',
      v_settle = '{"assigned": 3, "held": 1, "locks": 3}'::jsonb
      and v_settle2 = '{"assigned": 0, "held": 0, "locks": 0}'::jsonb
      and (select t.stock_status from erp.count_task t where t.id = t_ka) = 'available'
      and (select t.stock_status from erp.count_task t where t.id = t_kl) = 'available'
      and (select t.stock_status from erp.count_task t where t.id = t_kq) = 'quarantine'
      and (select t.stock_status is null
                  and t.post_held_reason like 'status_unknown: when this count was raised, expecting 5, the place held 5 available, 5 quarantine,%'
             from erp.count_task t where t.id = t_kh)
      and (select t.stock_status is null and t.post_held_reason is null from erp.count_task t where t.id = t_kp)
      and (select count(*) from erp.count_lock l join erp.count_task t on t.id = l.count_task_id
            where l.count_task_id in (t_ka, t_kl, t_kq) and l.stock_status = t.stock_status
              and l.released_at is null) = 3
      and (select l.stock_status is null from erp.count_lock l where l.count_task_id = t_kh),
      format('first %s, then %s; KQ %s; KH held: %s', v_settle, v_settle2,
             coalesce((select t.stock_status::text from erp.count_task t where t.id = t_kq), 'unknown'),
             coalesce((select t.post_held_reason from erp.count_task t where t.id = t_kh), 'no'));

    -- 12. The held count waits for a person, and the way out is to cancel it.
    v_fixture := 'the held count';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    begin
      perform public.erp_record_count(t_kh, 5);
    exception when others then
      get stacked diagnostics v_err = message_text, v_hint = pg_exception_hint;
    end;
    v_rows := public.erp_count_tasks(500);
    select x into x_kh from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_kh::text;
    select x into x_qa from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_qa::text;
    select x into x_qq from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_qq::text;
    v_raised3 := public.erp_raise_count_tasks('zz_old');
    begin
      perform public.erp_cancel_count_task(t_kh, 'Its place held as much quarantined stock beside it');
    exception when others then
      v_err_cancel := sqlerrm;
    end;
    return query select 'a count held because its status is not known is refused when recorded, in plain words, says why on the worklist, stands in the way of a second count of its place, and is cancelled',
      coalesce(v_err like 'CLOVEERP_COUNT_STATUS_UNKNOWN:%'
      and v_hint = 'Cancel the count and raise the counting programme again, so that each status at the place is counted on its own.'
      and x_kh -> 'stock_status' = 'null'::jsonb and x_kh ->> 'post_held_reason' like 'status_unknown:%'
      and x_qa ->> 'stock_status' = 'available' and x_qq ->> 'stock_status' = 'quarantine'
      and v_raised3 = 2
      and exists (select 1 from erp.count_task t
                   where t.tenant_id = r.tenant_id and t.item_id = i_kl and t.stock_status = 'quarantine'
                     and t.expected_quantity = 3)
      and exists (select 1 from erp.count_task t
                   where t.tenant_id = r.tenant_id and t.item_id = i_kq and t.stock_status = 'available'
                     and t.expected_quantity = 6)
      and not exists (select 1 from erp.count_task t
                       where t.tenant_id = r.tenant_id and t.item_id in (i_ka, i_kh) and t.id not in (t_ka, t_kh, t_kp))
      and v_err_cancel is null
      and (select t.status from erp.count_task t where t.id = t_kh) = 'cancelled', false),
      format('recorded: %s; hint: %s; raised %s beside; cancel %s; worklist %s',
             coalesce(left(v_err, 120), 'went through'), coalesce(v_hint, 'none'), v_raised3,
             coalesce(v_err_cancel, 'went through'), coalesce(x_kh::text, 'not listed'));

    -- 13. A held count with its approver: not approved, refused, not counted
    --     again as it is, and cancelled.
    v_fixture := 'the held count with its approver';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform public.erp_raise_count_tasks('zz_pend');
    select t.id into t_hp from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_hp;
    v_st_hp := public.erp_record_count(t_hp, 90)::text;
    -- Held, as the backfill holds a count raised before it.
    update erp.count_task
       set stock_status = null,
           post_held_reason = 'status_unknown: planted by the suite, as the backfill holds a count'
     where id = t_hp;
    update erp.count_lock set stock_status = null where count_task_id = t_hp and released_at is null;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select t.approval_request_id into v_req from erp.count_task t where t.id = t_hp;
    select tk.id into v_atask from erp.approval_task tk
     where tk.tenant_id = r.tenant_id and tk.approval_request_id = v_req
       and tk.status = 'pending' and tk.assignee_user_id = p1
     limit 1;
    begin
      perform erp.decide_approval_task(v_atask, true, 'looks right');
    exception when others then
      v_err_approve := sqlerrm;
    end;
    begin
      perform erp.decide_approval_task(v_atask, false, 'nobody knows which stock this is');
    exception when others then
      null;   -- already decided, when the approval above went through
    end;
    v_after_reject := (select t.status::text from erp.count_task t where t.id = t_hp);
    begin
      perform public.erp_recount_task(t_hp);
    exception when others then
      v_err_recount := sqlerrm;
    end;
    begin
      perform public.erp_cancel_count_task(t_hp, 'Nobody knows which stock it was of');
    exception when others then
      v_err_cancel2 := sqlerrm;
    end;
    v_after_cancel := (select t.status::text from erp.count_task t where t.id = t_hp);
    return query select 'a held count waiting for its approver is not approved but refused, is not counted again as it is, and is then cancelled',
      coalesce(v_st_hp = 'pending_approval'
      and v_err_approve like 'CLOVEERP_COUNT_STATUS_UNKNOWN:%'
      and v_after_reject = 'rejected'
      and v_err_recount like 'CLOVEERP_COUNT_STATUS_UNKNOWN:%'
      and v_err_cancel2 is null and v_after_cancel = 'cancelled', false),
      format('recorded %s; approve: %s; then %s; count again: %s; cancel: %s, then %s',
             v_st_hp, coalesce(left(v_err_approve, 80), 'went through'), coalesce(v_after_reject, '?'),
             coalesce(left(v_err_recount, 80), 'went through'), coalesce(left(v_err_cancel2, 80), 'went through'),
             coalesce(v_after_cancel, '?'));

    -- 14. The unattended bound reads a post from before a count knew its
    --     status as a post to available.
    v_fixture := 'the bound across a post from before';
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id,
                                expected_quantity, counted_quantity, variance, status, stock_status,
                                created_at, posted_at, posted_by_system, owner_party_id)
    values (r.tenant_id, pg_old, s_main, v_recv, i_c, 100, 98, -2, 'posted', null,
            now() - interval '1 day', now() - interval '1 day', true, v_company);
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform public.erp_raise_count_tasks('zz_c');
    select t.id into t_c from erp.count_task t
     where t.tenant_id = r.tenant_id and t.item_id = i_c and t.status = 'open';
    v_st_c := public.erp_record_count(t_c, 99)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    return query select 'a count inside its tolerance is held when, with a post of its place made by the system before a count knew its status, the variance comes outside it',
      coalesce(v_st_c = 'approved'
      and (select t.post_held_reason like 'held_cumulative:%' and t.stock_status = 'available'
             from erp.count_task t where t.id = t_c), false),
      format('recorded %s; held %s', v_st_c,
             coalesce((select t.post_held_reason from erp.count_task t where t.id = t_c), 'for nothing'));

    -- 15. D3: counts posted as the old route posted them, planted, found.
    v_fixture := 'the past';
    insert into erp.count_task (tenant_id, count_programme_id, site_id, location_id, item_id,
                                expected_quantity, counted_quantity, variance, status, stock_status,
                                created_at, posted_at, owner_party_id)
    values (r.tenant_id, pg_old, s_main, v_recv, i_r, 100, 99, -1, 'posted', null, clock_timestamp(), clock_timestamp(), v_company),
           (r.tenant_id, pg_old, s_main, v_recv, i_r2, 5, 4, -1, 'posted', null, clock_timestamp(), clock_timestamp(), v_company),
           (r.tenant_id, pg_old, s_main, v_recv, i_r3, 5, 4, -1, 'posted', null, clock_timestamp(), clock_timestamp(), v_company),
           (r.tenant_id, pg_old, s_main, v_recv, i_r4, 10, 11, 1, 'posted', null, clock_timestamp(), clock_timestamp(), v_company);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
      from_location_id, from_status, quantity, uom_id, currency, reason_code)
    values (r.tenant_id, r.entity_id, s_main, 'count_adjustment', i_r, v_recv, 'available', 1, v_uom, 'GBP', 'count_variance'),
           (r.tenant_id, r.entity_id, s_main, 'count_adjustment', i_r2, v_recv, 'available', 1, v_uom, 'GBP', 'count_variance'),
           (r.tenant_id, r.entity_id, s_main, 'count_adjustment', i_r3, v_recv, 'available', 1, v_uom, 'GBP', 'count_variance');
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
      to_location_id, to_status, quantity, uom_id, currency, reason_code)
    values (r.tenant_id, r.entity_id, s_main, 'count_adjustment', i_r4, v_recv, 'available', 1, v_uom, 'GBP', 'count_variance');
    select count(*) into v_n from erp.count_posts_past_their_status_report();
    return query select 'the report of past counts finds each whose expectation was quarantined stock and not available, a shortfall and an excess alike, and nothing else',
      v_n = 2
      and exists (select 1 from erp.count_posts_past_their_status_report() f
                   where f.item_code = 'R' and f.location_code = 'RECV' and f.variance = -1
                     and f.counted_status = 'quarantine' and f.available_then = 0
                     and f.next_action like 'Check the place.%moves 1 from quarantine to available%')
      and exists (select 1 from erp.count_posts_past_their_status_report() f
                   where f.item_code = 'R4' and f.variance = 1 and f.counted_status = 'quarantine'
                     and f.next_action like '%moves 1 from available to quarantine%'),
      format('%s finding(s): %s', v_n,
             coalesce((select string_agg(f.item_code || ' ' || trim_scale(f.variance) || ' of ' || f.counted_status, '; ')
                         from erp.count_posts_past_their_status_report() f), 'none'));

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
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-cbs-' || v_hex)
            and current_user = v_owner;
  detail := 'the organisation, its stock, counts, sheets, adjustments, approvals and planted history rolled back, and the role the suite began as';
  return next;
end;
$function$;

revoke all on function erp_test.count_by_status_suite() from public, anon;

comment on function erp_test.count_by_status_suite() is
  'A count is of the stock it counts (20260928100000): quarantined and available stock at one place, '
  'and two batches, each raise their own count, sheet line and lock; what is promised is set aside by '
  'batch and status; movement during the count reaches only its own; raising again raises only what '
  'no count covers; each variance posts to its own status, through the adjustment and by the old '
  'route, and the books agree; a batch is counted again beside the other; the counts raised before '
  'are given their status or held, once; a held count is refused when recorded, approved or counted '
  'again, and cancelled; the unattended bound reads a post from before as available; and the report '
  'finds planted past counts of quarantined stock posted to available.';

create or replace function erp_test.assert_count_by_status_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
  v_ended  text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false)),
         max(s.detail) filter (where s.case_name = 'the suite ran to its end')
    into v_failed, v_total, v_detail, v_ended
    from erp_test.count_by_status_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_COUNT_BY_STATUS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A count is of one batch and one stock status of its place. Read the case that failed.';
  end if;
  if v_total <> 16 then
    raise exception 'CLOVEERP_COUNT_BY_STATUS_SUITE_SHRANK: % case(s), expected 16; the fixture stopped %', v_total,
      coalesce(v_ended, 'nowhere')
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('counting by batch and status: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_count_by_status_suite() from public, anon;

comment on function erp_test.assert_count_by_status_suite() is
  'A count task is keyed by its batch and stock status: raised, locked, moved during, posted by '
  'either route and backfilled so, with a report of the past posts that were not (20260928100000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The words the worklist says of a count's status
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The counter''s worklist on the Counting screen, of the stock status a count is of (20260928100000).'
  from (values
    ('Awaiting inspection'),
    ('Damaged'),
    ('In production'),
    ('In transit'),
    ('On hold'),
    ('Raised before a count knew which stock it counts, at a place holding stock in more than one status, so it is not posted. It waits for somebody who may adjust stock to decide it.'),
    ('Raised before a count knew which stock it counts, at a place holding stock in more than one status. Cancel it and raise the programme again: each status is then counted on its own.')
  ) as v(text)
on conflict (key, locale) do nothing;

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
