set lock_timeout = '30s';

-- =============================================================================
-- 20260927200000  An adjustment is born of a count
-- -----------------------------------------------------------------------------
-- PR10, M2a: node I4 of docs/spec/simplification-review.md, "adjustment born
-- from count variance, using reason codes". The auto-post inside tolerance is
-- node I3 and the next milestone (M2b); nothing here changes who may post a
-- count, or when a count posts.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Two routines wrote a count_adjustment movement, and they did not write it
-- the same way.
--
--   (a) erp.post_count() inserted the movement itself: no document, no
--       number, nothing to open from the Stock adjustments screen, and a
--       variance posted in error had no lineage for the adjustment that put
--       it right. Its reason was the bare string count_variance, which is not
--       a code in the register: the register's is COUNT_VARIANCE.
--   (b) erp.post_stock_adjustment() costed every line whoever owned the
--       stock. Harmless while nothing raised an adjustment of stock the
--       company does not own, and wrong the moment anything did: checked on
--       the demonstration data, a consigned unit written off through the door
--       was costed against the company's valuation, and
--       erp.assert_inventory_reconciles() then refused by exactly that cost.
--       erp.post_count() skipped the costing for such stock; the door did not.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * One route to the ledger for a variance. erp.post_count() keeps its
--     door, its permission and CLOVEERP_COUNT_SELF_POSTING, and its posting
--     date, the day Post is pressed. Where the organisation has an active
--     stock adjustment type whose movement type is count_adjustment, it no
--     longer writes a movement: it raises the count's adjustment and posts
--     it, through erp.raise_count_adjustment(), which is not a door. Where it
--     has none, or has retyped it, it writes the movement as before.
--   * The day and the moment of a count's post are read once. The raise
--     takes the moment, dates the adjustment by the site's day at that
--     moment, and hands both to the line routine, which reads no clock of its
--     own: a post that runs across the site's midnight cannot date the
--     document one day and back-date the movement to the other.
--   * One adjustment per count with a variance, one line. Opened through
--     erp.open_document(); the owner of the stock counted on the header
--     (stock_owner_party_id), and its place, batch and handling unit on the
--     line; the reason COUNT_VARIANCE from the register. A count with no
--     variance raises nothing and moves nothing, as before.
--   * Approved by the system, not by a second press. The count's own approval
--     is the adjustment's: the move is derived from
--     erp.count_task_is_approved() (decision 6, 20260922380000), read again
--     by erp.derived_move_fact() with the adjustment's state locked, the way
--     the count sheet's close is (20260927100000).
--   * Posted through the adjustment's own line routine,
--     erp.post_adjustment_lines(), split out of erp.post_stock_adjustment(),
--     which keeps its authorisation and hands on. The routine costs only
--     stock the company owns, which fixes (b) for the free-hand door as well.
--   * A count that names no location is refused by name
--     (CLOVEERP_COUNT_HAS_NO_PLACE) rather than posted to the site's default
--     place, which the adjustment's line routine would otherwise choose.
--   * The count task carries its adjustment: count_task.adjustment_document_id
--     and adjustment_line_id. A count on a sheet is linked line to line:
--     the adjustment's line `corrects` the sheet's.
--   * The registers: the count row of the reversal register, the base type's
--     description, and the transition driver register, restated.
--   * The suites that read count_variance, or a count's movement by its want
--     of a document, re-pinned. erp_test.count_adjustment_suite is the proof:
--     on an organisation seeded as the demonstration is, the route this
--     retires and the route it installs post the same movements, journals,
--     subledger, layers, unit costs and balances.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * I3, the post as the count is recorded, and the policy on who may post
--     inside tolerance: M2b.
--   * A hand-typed COUNT_VARIANCE adjustment is still accepted by the door,
--     so a counter who holds inventory.adjust can still raise, approve and
--     post the variance of their own count in a live organisation without
--     meeting CLOVEERP_COUNT_SELF_POSTING. A known bypass, left for PR11's I5,
--     which gives the adjustment an approval chain.
--   * The count's adjustment is approved as the system's move, derived from
--     the count's own approval, so whatever the organisation requires to
--     approve a stock adjustment does not apply to it. A permission moved
--     onto the approve is recorded against the move as not held and is not
--     asked for; an approval chain named on the type is never consulted,
--     because the stock adjustment lifecycle has no submit and a chain is
--     only requested at submit. Not a regression: the movement the post
--     wrote before this met neither. It is a decision I5 has to take, and
--     erp_test.count_adjustment_suite pins today's behaviour so that it
--     must: when I5 gives the adjustment a submit, the approve from draft
--     this raises will fail, and the case that pins it with it.
--   * A count's adjustment is a posted document like any other: it takes an
--     ADJ number from the type's numbering rule, and its post counts once in
--     the documents_posted meter. Kept on purpose; a variance was not metered
--     before, and is now metered as what it is.
--   * The route leans on the stock adjustment type's configuration: its
--     create_permission is what erp.open_document() asks of the person
--     posting the count, and its stock_movement_type is what the line
--     routine writes. The first is intended: whoever may raise a stock
--     adjustment may post a count's variance through one, and an
--     organisation that narrows the one narrows the other. The second is
--     not left to chance: a type whose movement type is anything but
--     count_adjustment would write a variance under another movement, so
--     the post falls back to the old movement for it, as for no type.
--   * The approval of a count outside tolerance is unchanged: the counter may
--     still approve their own, and the post is where the second person stands.
--   * No configuration moves, so inventory-operations stays at version 7. An
--     organisation with no active stock adjustment type (one on version 4 or
--     earlier), or one whose type writes another movement, posts its
--     variance as it always has, by the movement
--     erp.post_count() writes itself, unchanged — the fallback M1a and M1b
--     keep for an organisation that has not taken their version. It moves to
--     the adjustment when it upgrades.
--   * The client needs no change. The adjustment's approve and post stay
--     buttons for a hand-typed adjustment; the count's adjustment passes
--     through both inside the post and is never shown waiting on either.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_COUNT_ADJUSTMENT_RAISED',
  'Raising the stock adjustment of a count that already has one.',
  'A count''s variance is written into the stock once, by the adjustment raised when it was posted; a second would write it twice.',
  'Open the count''s adjustment from the Stock adjustments screen. If the stock is still wrong, count the place again.');

select erp.register_refusal('CLOVEERP_COUNT_HAS_NO_VARIANCE',
  'Raising a stock adjustment for a count that found what was expected.',
  'A count with no variance changes nothing, so there is nothing for an adjustment to say; it is posted without one.',
  'Post the count. It moves nothing and needs no adjustment.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_NEEDS_A_MOMENT',
  'Writing a stock adjustment''s lines without the moment and the day it is posted at.',
  'The day decides whether the adjustment is back-dated and the moment is when its stock moved. Both are read once, by whatever posts it, so that the two cannot fall either side of the site''s midnight; a line routine left to guess would guess the day before.',
  'Post the adjustment from the Stock adjustments screen, or post the count it belongs to.');

select erp.register_refusal('CLOVEERP_COUNT_HAS_NO_PLACE',
  'Posting the variance of a count that names no location.',
  'A count''s variance is written back to the place that was counted. A count with no place would have its variance put wherever the site''s default happens to be, which is a place nobody counted.',
  'Cancel the count and raise it again for the place it was meant to count.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. A count task carries its adjustment
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.count_task
  add column adjustment_document_id uuid,
  add column adjustment_line_id uuid,
  add constraint count_task_adjustment_document_fkey
    foreign key (tenant_id, adjustment_document_id) references erp.document (tenant_id, id) on delete restrict,
  add constraint count_task_adjustment_line_fkey
    foreign key (tenant_id, adjustment_line_id) references erp.document_line (tenant_id, id) on delete restrict,
  -- The adjustment has one line and it is the variance: one without the
  -- other is a count half posted.
  add constraint count_task_adjustment_together
    check ((adjustment_document_id is null) = (adjustment_line_id is null));

-- One count per adjustment, and one per line: the grain is the task.
create unique index count_task_adjustment_document_key on erp.count_task (tenant_id, adjustment_document_id)
  where adjustment_document_id is not null;
create unique index count_task_adjustment_line_key on erp.count_task (tenant_id, adjustment_line_id)
  where adjustment_line_id is not null;

comment on column erp.count_task.adjustment_document_id is
  'The stock adjustment the count''s variance was posted through (20260927200000); null for a count with no variance, one not yet posted, or one posted before its variance had an adjustment.';
comment on column erp.count_task.adjustment_line_id is
  'The line of the stock adjustment that is the count''s variance (20260927200000); null with adjustment_document_id.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The adjustment's line routine, which costs only what the company owns
--
-- erp.post_stock_adjustment() split in two. The door keeps what it asks of
-- the person: inventory.adjust, and finance.post for a date before today. The
-- line routine keeps everything that is true of the document whoever posts
-- it — not dated ahead, not posted twice, approved, with a reason — and
-- writes the legs, the journals and the post. erp.raise_count_adjustment()
-- calls the routine directly, after erp.post_count() has asked the person.
--
-- Deployed body, asserted whole: the door is restated below from the body
-- this migration was written against, and refuses to restate any other.
-- ─────────────────────────────────────────────────────────────────────────────

do $door_anchor$
begin
  if md5(pg_get_functiondef('erp.post_stock_adjustment(uuid)'::regprocedure))
     is distinct from '16c5faf1048490e97368641a1fdb1572' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.post_stock_adjustment(uuid) is not the body 20260927200000 splits';
  end if;
end
$door_anchor$;

create or replace function erp.post_adjustment_lines(p_document_id uuid, p_at timestamptz, p_today date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  v_type   text;
  v_state  text;
  v_on     date;
  v_when   timestamptz;
  v_reason text;
  v_ccy    char(3);
  v_loc    uuid;
  v_unit   bigint;
  v_id     bigint;
  v_mv_cost bigint;
  v_journal uuid;
  ln       record;
  v_n      integer := 0;
  v_up     numeric := 0;
  v_down   numeric := 0;
  v_cost   bigint := 0;
  v_journals integer := 0;
  v_owned  boolean;
begin
  -- The legs of a stock adjustment, its journals and its post
  -- (20260927200000). Asks nothing of the person: erp.post_stock_adjustment()
  -- has, for an adjustment typed by hand, and erp.post_count() has, for the
  -- one a count raises. Everything true of the document whoever posts it is
  -- asked here, so neither route can skip it.
  --
  -- The moment of the post and the site's day, p_at and p_today, are the
  -- caller's, read once: the caller has already decided by them whether the
  -- date asks finance.post, and a second read here could fall the other side
  -- of the site's midnight and date the movement by a day nobody asked about.
  if p_at is null or p_today is null then
    raise exception 'CLOVEERP_ADJUSTMENT_NEEDS_A_MOMENT: % is posted at no moment',
      p_document_id
      using errcode = '22004',
            hint = 'Post the adjustment from the Stock adjustments screen, or post the count it belongs to.';
  end if;

  d := erp.adjustment_document(p_document_id);

  v_on := coalesce(d.posting_date, d.document_date);

  if v_on > p_today then
    raise exception
      'CLOVEERP_ADJUSTMENT_IN_THE_FUTURE: % is dated %, which is after today',
      d.document_number, v_on
      using errcode = '22007',
            hint = 'Date the adjustment the day the count was taken, or leave it empty for today.';
  end if;

  if exists (select 1 from erp.stock_movement m
              where m.tenant_id = v_tenant and m.document_id = p_document_id) then
    raise exception
      'CLOVEERP_ADJUSTMENT_ALREADY_POSTED: % has already changed the stock it names',
      d.document_number
      using errcode = '23505',
            hint = 'Raise a new adjustment for a further correction; the stock ledger is never written twice for one document.';
  end if;

  v_state := erp.document_state_code(p_document_id);
  if v_state is distinct from 'approved' then
    raise exception
      'CLOVEERP_ADJUSTMENT_NOT_APPROVED: % is %, and stock is not written off on '
      'one person''s word', d.document_number,
      coalesce(v_state, 'in no state at all')
      using errcode = '42501',
            hint = 'Have the adjustment approved first. That approval is the whole control on a write-off.';
  end if;

  v_reason := nullif(btrim(coalesce(d.attributes ->> 'reason_code', '')), '');
  if v_reason is null then
    raise exception
      'CLOVEERP_ADJUSTMENT_NEEDS_A_REASON: % says nothing about why the stock '
      'changed', d.document_number
      using errcode = '23514',
            hint = 'Cancel it and raise the adjustment again with a reason from the register.';
  end if;

  select * into dt from erp.document_type
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;
  v_type := coalesce(dt.stock_movement_type, 'count_adjustment');

  v_ccy := coalesce(d.currency,
                    (select e.base_currency from erp.entity e
                      where e.tenant_id = v_tenant and e.id = d.entity_id));

  -- The document's own date, read the way erp.post_document_stock() reads it,
  -- so an adjustment dated last month orders with last month and
  -- erp.post_movement_finance() dates its journal there too.
  v_when := case when v_on >= p_today
                 then p_at
                 else (v_on::timestamp + interval '12 hours') at time zone 'UTC'
            end;

  -- Stock the company does not own is not on its books (20260927200000).
  -- erp.stamp_movement_parties() takes the owner from the document and
  -- strips the cost from such a movement, but the costing store has been
  -- told by then: a unit issued from, or received into, the company's own
  -- valuation for stock that was never in it. Asked once, of the owner the
  -- movement will carry, and not asked of the store at all when the answer
  -- is no — as erp.post_count() did for a count of consigned stock.
  v_owned := coalesce(d.stock_owner_party_id, erp.entity_party(d.entity_id))
             = erp.entity_party(d.entity_id);

  perform erp.ensure_site_location(d.site_id);

  for ln in
    select l.* from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = p_document_id
       and not l.is_cancelled and l.quantity <> 0
     order by l.line_no
  loop
    if ln.quantity > 0 then
      -- Stock found. It arrives at what the books already say a unit of it is
      -- worth: nothing was bought, so there is no price to value it at.
      v_loc := coalesce(ln.location_id,
                        erp.default_posting_location(d.site_id, 'in'::erp.movement_direction,
                                                     ln.item_id, ln.batch_id, ln.quantity));
      if v_loc is null then
        raise exception
          'CLOVEERP_ADJUSTMENT_HAS_NO_PLACE: % has nowhere to put the stock it found',
          d.document_number
          using errcode = '23503',
                hint = 'Give the line a location, or add a goods-in location to the site on the Warehouse layout screen.';
      end if;

      v_unit := case when v_owned then
                  erp.receive_cost(
                    ln.item_id, d.site_id, ln.quantity,
                    -- What a unit is worth under whichever method costs it (20260920250000).
                    coalesce(erp.unit_cost_at(ln.item_id, d.site_id), 0),
                    v_ccy, ln.batch_id, null)
                end;

      insert into erp.stock_movement (
        tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
        container_id, to_location_id, to_status, quantity, uom_id, unit_cost_minor,
        currency, reason_code, document_id, document_line_id, occurred_at)
      values (
        v_tenant, d.entity_id, d.site_id, v_type, ln.item_id, ln.batch_id, ln.serial_id,
        ln.container_id, v_loc, 'available'::erp.stock_status, ln.quantity,
        coalesce(ln.uom_id, (select i.stock_uom_id from erp.item i where i.id = ln.item_id)),
        v_unit, v_ccy, v_reason, p_document_id, ln.id, v_when)
      returning id into v_id;

      v_up := v_up + ln.quantity;
    else
      -- Stock missing. The stock-aware resolver, not the configured bay: what
      -- is not there was standing wherever the rest of it is standing.
      v_loc := coalesce(ln.location_id,
                        erp.default_posting_location(d.site_id, 'out'::erp.movement_direction,
                                                     ln.item_id, ln.batch_id, -ln.quantity));
      if v_loc is null then
        raise exception
          'CLOVEERP_ADJUSTMENT_HAS_NO_PLACE: % has nowhere for the missing stock to leave from',
          d.document_number
          using errcode = '23503',
                hint = 'Give the line a location, or add a storage location to the site on the Warehouse layout screen.';
      end if;

      v_unit := case when v_owned then erp.issue_cost(ln.item_id, d.site_id, -ln.quantity) end;

      insert into erp.stock_movement (
        tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
        container_id, from_location_id, from_status, quantity, uom_id, unit_cost_minor,
        currency, reason_code, document_id, document_line_id, occurred_at)
      values (
        v_tenant, d.entity_id, d.site_id, v_type, ln.item_id, ln.batch_id, ln.serial_id,
        ln.container_id, v_loc, 'available'::erp.stock_status, -ln.quantity,
        coalesce(ln.uom_id, (select i.stock_uom_id from erp.item i where i.id = ln.item_id)),
        v_unit, v_ccy, v_reason, p_document_id, ln.id, v_when)
      returning id into v_id;

      v_down := v_down + (-ln.quantity);
    end if;

    -- Inventory against the stock adjustments account, at the movement's exact
    -- cost and on the movement's date, through the rule the inventory installer
    -- has shipped since 20260906050000. A movement worth nothing raises no
    -- journal, and says nothing by raising one.
    v_journal := erp.post_movement_finance(v_id);
    if v_journal is not null then
      v_journals := v_journals + 1;
    end if;

    -- What the adjustment put through the profit and loss: stock missing is a
    -- cost and adds, stock found is a cost unmade and takes away.
    select coalesce(m.cost_minor, 0) into v_mv_cost
      from erp.stock_movement m where m.id = v_id;
    v_cost := v_cost + case when ln.quantity > 0 then -v_mv_cost else v_mv_cost end;

    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    raise exception
      'CLOVEERP_ADJUSTMENT_HAS_NO_LINES: % says nothing changed', d.document_number
      using errcode = '23514',
            hint = 'Add a line saying which product and by how much, then post it.';
  end if;

  perform erp.transition_document(p_document_id, 'post', 'Adjusted');

  return jsonb_build_object(
    'document_id', p_document_id,
    'document_number', d.document_number,
    'adjusted_on', v_on,
    'reason_code', v_reason,
    'lines', v_n,
    'found', v_up,
    'missing', v_down,
    'cost_minor', v_cost,
    'journals', v_journals,
    'currency', v_ccy,
    'state', erp.document_state_code(p_document_id));
end;
$$;

revoke all on function erp.post_adjustment_lines(uuid, timestamptz, date) from public, anon;

comment on function erp.post_adjustment_lines(uuid, timestamptz, date) is
  'Writes an approved stock adjustment''s lines into the stock ledger and, through '
  'erp.post_movement_finance(), the general ledger, and posts it (20260927200000). Costs only '
  'stock the company owns. Reads no clock: the moment of the post and the site''s day at it are '
  'the caller''s, read once. Asks no permission: called by erp.post_stock_adjustment() and '
  'erp.raise_count_adjustment(), each after its own.';

create or replace function erp.post_stock_adjustment(p_document_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  d        erp.document%rowtype;
  v_on     date;
  v_today  date;
  v_at     timestamptz;
begin
  d := erp.adjustment_document(p_document_id);

  perform erp.authorise('inventory.adjust', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  v_on := coalesce(d.posting_date, d.document_date);

  -- The site's day and the moment of the post, each read once here and
  -- handed to the line routine, so the day finance.post is asked by is the
  -- day the ledger is written by (20260927200000).
  v_today := erp.local_today(d.site_id);
  v_at    := clock_timestamp();

  -- Asked again here, and not only at the raise: the posting is where the
  -- ledger is written, and the document's date could have been changed between
  -- the two by anybody who may edit a draft.
  if v_on < v_today then
    perform erp.authorise('finance.post', d.entity_id, d.site_id, null,
                          'document', p_document_id);
  end if;

  -- Everything else, and the ledger, is the line routine's (20260927200000),
  -- which a count's own adjustment is posted through as well.
  return erp.post_adjustment_lines(p_document_id, v_at, v_today);
end;
$$;

revoke all on function erp.post_stock_adjustment(uuid) from public, anon;

comment on function erp.post_stock_adjustment(uuid) is
  'Writes an approved stock adjustment into the stock ledger and the general ledger, both dated the '
  'day the adjustment says the fact was true. Stock found arrives at what the books already say it is '
  'worth; stock missing leaves at what it cost; stock the company does not own is not costed '
  '(20260927200000). Asks inventory.adjust, and finance.post as well for a date earlier than today; a '
  'closed period refuses it at the ledger. The lines are erp.post_adjustment_lines().';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The fact a count's adjustment is approved and posted from
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.count_task_is_approved(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- True when the stock adjustment is the variance of an approved count and
  -- says nothing else (20260927200000): the count names it and its one line,
  -- the line is the count's item, place, batch and handling unit by the
  -- count's variance, the header carries the owner counted and the reason
  -- COUNT_VARIANCE, and nothing else is on it. The approval the count
  -- already has is then the adjustment's, and nobody approves it twice. Read
  -- by the engine as the fact the adjustment's approve and post are derived
  -- from, with the adjustment's state locked.
  select exists (
    select 1
      from erp.count_task t
      join erp.document d
        on d.tenant_id = t.tenant_id and d.id = t.adjustment_document_id
      join erp.document_line l
        on l.tenant_id = t.tenant_id and l.id = t.adjustment_line_id and l.document_id = d.id
     where t.tenant_id = erp.current_tenant_id()
       and t.adjustment_document_id = p_document_id
       and t.status = 'approved'
       and coalesce(t.variance, 0) <> 0
       and not d.is_cancelled
       and d.site_id = t.site_id
       and d.stock_owner_party_id is not distinct from
             coalesce(t.owner_party_id, erp.entity_party(d.entity_id))
       and d.attributes ->> 'reason_code' = 'COUNT_VARIANCE'
       and not l.is_cancelled
       and l.item_id = t.item_id
       and l.quantity = t.variance
       and l.location_id is not distinct from t.location_id
       and l.batch_id is not distinct from t.batch_id
       and l.container_id is not distinct from t.container_id
       and not exists (select 1 from erp.document_line o
                        where o.tenant_id = t.tenant_id and o.document_id = d.id
                          and o.id <> l.id and not o.is_cancelled))
$$;

revoke all on function erp.count_task_is_approved(uuid) from public, anon;

comment on function erp.count_task_is_approved(uuid) is
  'True when a stock adjustment is exactly the variance of an approved count task, and nothing more '
  '(20260927200000): the fact its approve and post are derived from.';

-- The adjustment's two moves, read again with its state locked. Deployed
-- body, asserted needle: one arm more in the document case.
do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$             then 'erp.count_sheet_is_finished'
$o$;
  v_new constant text := $n$             then 'erp.count_sheet_is_finished'
           -- A count's own stock adjustment, approved and posted as the
           -- count is posted (20260927200000), asked for by
           -- erp.raise_count_adjustment(). The approval is the count's.
           when dt.base_type_code = 'adjustment' and p_transition_code in ('approve', 'post')
            and erp.object_current_state('document', p_object_id)
                  = case p_transition_code when 'approve' then 'draft' else 'approved' end
            and erp.count_task_is_approved(p_object_id)
             then 'erp.count_task_is_approved'
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count sheet arm found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The count's adjustment, raised and posted
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.raise_count_adjustment(p_task_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        erp.count_task%rowtype;
  s        erp.site%rowtype;
  v_owner  uuid;
  v_on     date;
  v_at     timestamptz;
  v_doc    uuid;
  v_line   uuid;
  v_uom    uuid;
  v_item   text;
  v_note   text;
  v_ref    text;
  v_prev   text;
begin
  -- The variance of an approved count, as a stock adjustment of its own
  -- (20260927200000). Called by erp.post_count(), which has locked the task,
  -- asked inventory.adjust of the person and applied the self-posting rule;
  -- this asks nothing of them that the post has not.
  select * into t from erp.count_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_COUNT_TASK: %', p_task_id using errcode = '23503',
      hint = 'The count task does not exist in this organisation.';
  end if;

  if t.adjustment_document_id is not null then
    raise exception 'CLOVEERP_COUNT_ADJUSTMENT_RAISED: the count of % has been posted through %',
      coalesce((select i.code from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id), p_task_id::text),
      coalesce((select d.document_number from erp.document d
                 where d.tenant_id = v_tenant and d.id = t.adjustment_document_id),
               t.adjustment_document_id::text)
      using errcode = '23505',
            hint = 'Open the count''s adjustment from the Stock adjustments screen. If the stock is still wrong, count the place again.';
  end if;

  if t.status <> 'approved' then
    raise exception
      'CLOVEERP_COUNT_NOT_APPROVED: % is %, and a variance is not written into '
      'the ledger on one person''s word', p_task_id, t.status
      using errcode = '42501',
            hint = 'Record the count; within tolerance it approves itself, otherwise the programme''s approval chain decides.';
  end if;

  if coalesce(t.variance, 0) = 0 then
    raise exception 'CLOVEERP_COUNT_HAS_NO_VARIANCE: the count % found what was expected, so there is nothing to adjust',
      p_task_id
      using errcode = '23514',
            hint = 'Post the count. It moves nothing and needs no adjustment.';
  end if;

  -- The variance goes back to the place counted. With none, the line routine
  -- would choose the site's default place, which nobody counted.
  if t.location_id is null then
    raise exception 'CLOVEERP_COUNT_HAS_NO_PLACE: the count of % names no location, so there is nowhere its variance of % belongs',
      coalesce((select i.code from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id), p_task_id::text),
      trim_scale(t.variance)
      using errcode = '23502',
            hint = 'Cancel the count and raise it again for the place it was meant to count.';
  end if;

  select * into s from erp.site where tenant_id = v_tenant and id = t.site_id;
  select i.code, i.stock_uom_id into v_item, v_uom
    from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id;
  v_owner := coalesce(t.owner_party_id, erp.entity_party(s.entity_id));
  -- The moment Post is pressed, read once, as the movement erp.post_count()
  -- wrote took it, and the site's day at that moment, read from it once.
  -- Both are handed to the line routine, which reads no clock: the
  -- adjustment, its movement and its journal are dated by one reading, so a
  -- post that runs across the site's midnight cannot date the document one
  -- day and back-date its movement to the other, without finance.post.
  v_at := clock_timestamp();
  v_on := (v_at at time zone erp.local_timezone(t.site_id))::date;
  v_note := format('Counted %s of %s where the ledger held %s',
                   trim_scale(t.counted_quantity), coalesce(v_item, 'the product'),
                   trim_scale(t.counted_quantity - t.variance));
  v_ref := coalesce((select d.document_number from erp.document d
                      where d.tenant_id = v_tenant and d.id = t.document_id),
                    (select p.code from erp.count_programme p
                      where p.tenant_id = v_tenant and p.id = t.count_programme_id));

  -- The register's code, and whatever the organisation insists on for it.
  perform erp.check_reason_code('STOCK_ADJUSTMENT', 'COUNT_VARIANCE', v_note);

  -- Through the door every document is opened by, which asks inventory.adjust
  -- from the type's own row: what the post has already asked.
  v_doc := erp.open_document('stock_adjustment', null, s.entity_id, t.site_id,
                             null, null, null);

  update erp.document
     set document_date = v_on,
         posting_date  = v_on,
         our_reference = v_ref,
         stock_owner_party_id = v_owner,
         attributes = coalesce(attributes, '{}'::jsonb)
                      || jsonb_build_object('reason_code', 'COUNT_VARIANCE',
                                            'reason_note', v_note,
                                            'count_task_id', t.id),
         updated_at = now()
   where tenant_id = v_tenant and id = v_doc;

  -- One line, the variance, in the stock unit the count was taken in and at
  -- the place, batch and handling unit counted. No price: what the change is
  -- worth is what the costing store says.
  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
    batch_id, location_id, container_id, unit_price_minor, net_minor)
  values (
    v_tenant, v_doc, 10, t.item_id, erp.line_description(t.item_id, null),
    t.variance, v_uom, t.batch_id, t.location_id, t.container_id, 0, 0)
  returning id into v_line;

  update erp.count_task
     set adjustment_document_id = v_doc, adjustment_line_id = v_line, updated_at = now()
   where tenant_id = v_tenant and id = p_task_id;

  -- A count on a sheet: the adjustment's line corrects the sheet's.
  if t.document_line_id is not null then
    insert into erp.document_relation (
      tenant_id, from_document_id, to_document_id, relation_kind,
      from_line_id, to_line_id, quantity)
    values (v_tenant, v_doc, t.document_id, 'corrects', v_line, t.document_line_id, t.variance);
  end if;

  -- Approved and posted as the system's moves, derived from the count's own
  -- approval, each named in erp.deriving_move immediately before it and put
  -- back after.
  v_prev := coalesce(current_setting('erp.deriving_move', true), '');
  perform set_config('erp.deriving_move', v_doc::text || ':approve', true);
  perform erp.transition_document(v_doc, 'approve', 'Approved with its count');
  perform set_config('erp.deriving_move', v_doc::text || ':post', true);
  perform erp.post_adjustment_lines(v_doc, v_at, v_on);
  perform set_config('erp.deriving_move', v_prev, true);

  return v_doc;
end;
$$;

revoke all on function erp.raise_count_adjustment(uuid) from public, anon;

comment on function erp.raise_count_adjustment(uuid) is
  'Raises the stock adjustment that is an approved count''s variance, approves it from the count''s '
  'own approval and posts it through erp.post_adjustment_lines() (20260927200000). Not a door: '
  'erp.post_count() calls it, after asking inventory.adjust and applying the self-posting rule.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The route this retires, kept where the proof can reach it
--
-- erp.post_count() as it stood before this migration, verbatim under another
-- name: the reference erp_test.count_adjustment_suite posts the same counts
-- through, beside the route that replaces it. Read from the deployed body, so
-- it is the route that was, not a copy somebody typed.
-- ─────────────────────────────────────────────────────────────────────────────

do $as_it_was$
declare
  v_def text := pg_get_functiondef('erp.post_count(uuid)'::regprocedure);
  v_old constant text := 'CREATE OR REPLACE FUNCTION erp.post_count(p_task_id uuid)';
  v_hits integer;
begin
  if md5(v_def) is distinct from '590ee66899cd12e0056b94d8e677e562' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.post_count(uuid) is not the body 20260927200000 retires';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.post_count(uuid) header found % time(s)', v_hits;
  end if;
  execute replace(v_def, v_old,
    'CREATE OR REPLACE FUNCTION erp_test.post_count_as_it_was(p_task_id uuid)');
end
$as_it_was$;

revoke all on function erp_test.post_count_as_it_was(uuid) from public, anon;

comment on function erp_test.post_count_as_it_was(uuid) is
  'erp.post_count() as it was before 20260927200000, which wrote the variance''s movement itself: '
  'the reference erp_test.count_adjustment_suite holds the adjustment route to. Not for use.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. The post raises the adjustment and writes no movement of its own
-- ─────────────────────────────────────────────────────────────────────────────

do $post$
declare
  v_sig constant text := 'erp.post_count(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  select i.stock_uom_id into v_uom from erp.item i where i.id = t.item_id;
  v_company := erp.entity_party_for_site(t.site_id);
  v_owner   := coalesce(t.owner_party_id, v_company);
  v_ccy     := coalesce((select e.base_currency from erp.entity e
                          join erp.site s on s.entity_id = e.id where s.id = t.site_id), 'GBP');

  -- An adjustment is a movement like any other, which is what keeps
  -- erp.assert_stock_reconciles() true through a count. Stock the company does
  -- not own moves without a cost: it was never on the books.
  if t.variance > 0 then
    v_cost := case when v_owner = v_company then
                erp.receive_cost(t.item_id, t.site_id, t.variance,
                  -- What a unit is worth under whichever method costs it (20260920250000).
                  coalesce(erp.unit_cost_at(t.item_id, t.site_id), 0),
                  v_ccy, t.batch_id, null)
              end;
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, container_id,
      to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code, owner_party_id)
    select v_tenant, s.entity_id, t.site_id, 'count_adjustment', t.item_id, t.batch_id, t.container_id,
           t.location_id, 'available', t.variance, v_uom, v_cost, v_ccy,
           'count_variance', v_owner
      from erp.site s where s.id = t.site_id
    returning id into v_move;
    perform erp.post_movement_finance(v_move);
  else
    v_cost := case when v_owner = v_company then erp.issue_cost(t.item_id, t.site_id, -t.variance) end;
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, container_id,
      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code, owner_party_id)
    select v_tenant, s.entity_id, t.site_id, 'count_adjustment', t.item_id, t.batch_id, t.container_id,
           t.location_id, 'available', -t.variance, v_uom, v_cost, v_ccy,
           'count_variance', v_owner
      from erp.site s where s.id = t.site_id
    returning id into v_move;
    perform erp.post_movement_finance(v_move);
  end if;
$o$,
    $n$  -- The variance is a stock adjustment of its own (20260927200000): opened
  -- through erp.open_document(), carrying the owner and the handling unit
  -- counted, under the register's COUNT_VARIANCE, approved from this count's
  -- own approval and posted through the adjustment's line routine, which is
  -- the one route a variance has to either ledger. It is dated today at the
  -- site, the day Post is pressed, as the movement below is. Stock the
  -- company does not own still moves without a cost: the line routine asks
  -- the costing store only for the company's own.
  --
  -- An organisation with no stock adjustment type (below inventory-operations
  -- 5) posts as it always has, by the movement written here, unchanged: the
  -- fallback M1a and M1b keep for an organisation that has not taken their
  -- version. So does one whose type writes a movement other than
  -- count_adjustment, read the way the line routine reads it: the variance
  -- would otherwise reach the stock ledger as some other kind of move.
  if exists (select 1 from erp.document_type dt
              where dt.tenant_id = v_tenant and dt.code = 'stock_adjustment'
                and dt.base_type_code = 'adjustment' and dt.status = 'active'
                and coalesce(dt.stock_movement_type, 'count_adjustment') = 'count_adjustment') then
    perform erp.raise_count_adjustment(p_task_id);
  else
  select i.stock_uom_id into v_uom from erp.item i where i.id = t.item_id;
  v_company := erp.entity_party_for_site(t.site_id);
  v_owner   := coalesce(t.owner_party_id, v_company);
  v_ccy     := coalesce((select e.base_currency from erp.entity e
                          join erp.site s on s.entity_id = e.id where s.id = t.site_id), 'GBP');

  -- An adjustment is a movement like any other, which is what keeps
  -- erp.assert_stock_reconciles() true through a count. Stock the company does
  -- not own moves without a cost: it was never on the books.
  if t.variance > 0 then
    v_cost := case when v_owner = v_company then
                erp.receive_cost(t.item_id, t.site_id, t.variance,
                  -- What a unit is worth under whichever method costs it (20260920250000).
                  coalesce(erp.unit_cost_at(t.item_id, t.site_id), 0),
                  v_ccy, t.batch_id, null)
              end;
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, container_id,
      to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code, owner_party_id)
    select v_tenant, s.entity_id, t.site_id, 'count_adjustment', t.item_id, t.batch_id, t.container_id,
           t.location_id, 'available', t.variance, v_uom, v_cost, v_ccy,
           'count_variance', v_owner
      from erp.site s where s.id = t.site_id
    returning id into v_move;
    perform erp.post_movement_finance(v_move);
  else
    v_cost := case when v_owner = v_company then erp.issue_cost(t.item_id, t.site_id, -t.variance) end;
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id, batch_id, container_id,
      from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
      reason_code, owner_party_id)
    select v_tenant, s.entity_id, t.site_id, 'count_adjustment', t.item_id, t.batch_id, t.container_id,
           t.location_id, 'available', -t.variance, v_uom, v_cost, v_ccy,
           'count_variance', v_owner
      from erp.site s where s.id = t.site_id
    returning id into v_move;
    perform erp.post_movement_finance(v_move);
  end if;
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
$post$;

comment on function erp.post_count(uuid) is
  'Posts an approved count: a variance through a stock adjustment of its own, raised, approved from '
  'the count''s approval and posted by erp.raise_count_adjustment() under COUNT_VARIANCE, against the '
  'owner''s position and in the handling unit counted, costed only when the company owns the stock '
  '(20260927200000); by a movement of its own, as before, in an organisation with no active stock '
  'adjustment type or one whose type writes another movement than count_adjustment. A count with no variance posts with no adjustment. Authorises inventory.adjust; '
  'once the organisation is live, the counter does not post their own variance.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. What the registers say about it
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.document_type
   set description = 'A count sheet: the places one raise put to be counted, each with a blank for '
                  || 'its figure. It posts nothing; each count posts its own variance through a stock '
                  || 'adjustment erp.post_count() raises for it (20260927200000).'
 where code = 'count';

do $base$
begin
  if (select description from erp_ref.document_type where code = 'count')
     not like '%a stock adjustment erp.post_count() raises for it (20260927200000).' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: base type count is missing';
  end if;
end
$base$;

-- The count row of the reversal register names the route a variance now takes.
do $route$
declare
  v_sig constant text := 'erp.document_reversal_route()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$Each count on it posts its own variance through erp.post_count(), dated where the movement is; a variance posted in error is put right by counting the place again or by a stock adjustment on its own date.$o$;
  v_new constant text := $n$Each count on it posts its own variance through a stock adjustment erp.post_count() raises, whose line corrects the sheet''s; a variance posted in error is put right by counting the place again or by a further stock adjustment on its own date.$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count row found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$route$;

-- The driver register, restated whole as every change to it is, and its
-- rows as they were. The stock adjustment's approve and post stay screen
-- rows: a row names what a person presses, and a hand-typed adjustment is
-- still approved and posted by one. The count's own adjustment is moved by
-- erp.raise_count_adjustment() as the system's move, which the register does
-- not list as a second driver; it is recorded where every derived move is,
-- in erp.derived_move_fact() and on the transition log's derived fact. The
-- purchase order's close is the precedent
-- (src/components/erp/available-transitions.ts reads the newest restatement,
-- and its list does not move).
create or replace function erp.transition_driver_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      -- Ordered because an order was raised from all of it (20260922360000).
      -- The routine's move takes its authority from that fact, whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only a move made by hand.
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      -- Approved with its requisition, by the conversion that raises it and
      -- by nothing else (20260922380000).
      ('purchase_order',     'inherit_approval',       'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000). The
      -- bill's close takes its authority from erp.order_is_settled(), whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only the close by hand.
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part_picked',   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_rest',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'routine', 'erp.issue_sales_invoice(uuid,uuid,uuid)'),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'screen', ''),
      ('transfer_order',     'in_transit',             'screen', ''),
      ('transfer_order',     'received',               'screen', ''),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),

      -- A count's own adjustment is approved and posted by erp.post_count(),
      -- through erp.raise_count_adjustment(), both moves derived from
      -- erp.count_task_is_approved() whatever permission the organisation
      -- puts on them (20260927200000). It never waits on either, so neither
      -- is drawn for it; a hand-typed adjustment is approved and posted here.
      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'screen', ''),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),

      -- ── The count sheet (20260927100000) ──────────────────────────────────
      -- Issued by the raise that opens it, once every place is on it; closed
      -- by the last of its counts to be posted or cancelled, derived from
      -- erp.count_sheet_is_finished() whatever permission the organisation
      -- puts on the move. Neither is a button.
      ('count_sheet',        'issue',                  'routine', 'erp.raise_count_tasks(text)'),
      ('count_sheet',        'close',                  'routine', 'erp.close_count_sheet_when_finished(uuid)'),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which the inventory installer
      -- now ships identically. None of them is left to a door, so the document
      -- page draws every move each one declares.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
$$;

revoke all on function erp.transition_driver_register() from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- A9. The suites that read what this moves
--
-- A count's movement now carries the register's COUNT_VARIANCE, which is the
-- point, and a document, which is its adjustment. Four suites found it by the
-- bare string or by its want of a document. Nothing else reads either: no
-- view, report or routine matches the lower-case string, the journal's
-- description is read by nothing, and the client never names it.
-- ─────────────────────────────────────────────────────────────────────────────

do $controls_suite$
declare
  v_sig constant text := 'erp_test.controls_finish_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$      select count(*) into v_moves_before
        from erp.stock_movement m
       where m.tenant_id = r.tenant_id and m.item_id = v_cnt and m.reason_code = 'count_variance';$o$,
    $n$      -- The register's code since 20260927200000, when a variance became an adjustment.
      select count(*) into v_moves_before
        from erp.stock_movement m
       where m.tenant_id = r.tenant_id and m.item_id = v_cnt and m.reason_code = 'COUNT_VARIANCE';$n$,
    $o$      select count(*) into v_moves_after
        from erp.stock_movement m
       where m.tenant_id = r.tenant_id and m.item_id = v_cnt and m.reason_code = 'count_variance';$o$,
    $n$      select count(*) into v_moves_after
        from erp.stock_movement m
       where m.tenant_id = r.tenant_id and m.item_id = v_cnt and m.reason_code = 'COUNT_VARIANCE';$n$];
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
$controls_suite$;

do $identity_suite$
declare
  v_sig constant text := 'erp_test.identity_policy_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$        and exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.reason_code = 'count_variance'
$o$,
    $n$        and exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.reason_code = 'COUNT_VARIANCE'
$n$,
    $o$        and exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.item_id = v_cons and m.reason_code = 'count_variance'
$o$,
    $n$        and exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.item_id = v_cons and m.reason_code = 'COUNT_VARIANCE'
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
$identity_suite$;

do $inventory_suite$
declare
  v_sig constant text := 'erp_test.inventory_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$                 where m.tenant_id = r.tenant_id and m.reason_code = 'count_variance'),$o$;
  v_new constant text := $n$                 where m.tenant_id = r.tenant_id and m.reason_code = 'COUNT_VARIANCE'),$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % reason anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$inventory_suite$;

-- The count's movement is its adjustment's, and is found through the count.
do $fifo_suite$
declare
  v_sig constant text := 'erp_test.fifo_is_costed_from_its_layers_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$       and m.movement_type = 'count_adjustment' and m.document_id is null;$o$;
  v_new constant text := $n$       and m.movement_type = 'count_adjustment'
       -- Through the count's own adjustment since 20260927200000.
       and m.document_id = (select t.adjustment_document_id from erp.count_task t
                             where t.tenant_id = v_tenant and t.id = v_task);$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count movement anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$fifo_suite$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.count_adjustment_suite
--
-- The same counts posted both ways from the same state, in an organisation
-- configured and seeded the way the demonstration is: once through the route
-- this retires (erp_test.post_count_as_it_was(), inside a block that is
-- rolled back), once through erp.post_count(). What reached the stock
-- ledger, the general ledger, the subledger and the costing store is read
-- the same way after each, and must be the same, reason and document aside:
-- those two differ, and are the point.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.count_posting_fingerprint(p_mark bigint, p_journals uuid[], p_subledger uuid[], p_layers jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What the counts posted since the mark wrote, in the current organisation,
  -- with nothing in it that differs between two runs of the same postings: no
  -- row ids, no timestamps finer than the day, and not the reason or the
  -- document, which erp_test.count_adjustment_suite reads for itself
  -- (20260927200000). Every journal and every subledger row written since
  -- the mark, whatever wrote it, with its source as a field: a second route
  -- to the ledger, a document-level journal from a posting rule on the type
  -- most of all, is then a difference and not a thing nobody looked at.
  with mv as (
    select m.* from erp.stock_movement m
     where m.tenant_id = erp.current_tenant_id() and m.id > p_mark),
  moved as (select distinct mv.item_id, mv.site_id from mv),
  nj as (
    select j.* from erp.journal j
     where j.tenant_id = erp.current_tenant_id()
       and not (j.id = any (coalesce(p_journals, '{}'::uuid[])))),
  ns as (
    select si.* from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id()
       and not (si.id = any (coalesce(p_subledger, '{}'::uuid[]))))
  select jsonb_build_object(
    'movements', (select coalesce(jsonb_agg(x.v order by x.v::text), '[]'::jsonb) from (
       select jsonb_build_object(
                'item', m.item_id, 'site', m.site_id, 'entity', m.entity_id, 'type', m.movement_type,
                'from', m.from_location_id, 'from_status', m.from_status,
                'to', m.to_location_id, 'to_status', m.to_status,
                'quantity', trim_scale(m.quantity), 'uom', m.uom_id,
                'unit', m.unit_cost_minor, 'cost', m.cost_minor, 'currency', m.currency,
                'owner', m.owner_party_id, 'custody', m.custody_party_id,
                'batch', m.batch_id, 'serial', m.serial_id, 'container', m.container_id,
                'day', (m.occurred_at at time zone 'UTC')::date) as v
         from mv m) x),
    'journals', (select coalesce(jsonb_agg(nj.source_code order by nj.source_code), '[]'::jsonb) from nj),
    'journal_lines', (select coalesce(jsonb_agg(x.v order by x.v::text), '[]'::jsonb) from (
       select jsonb_build_object(
                'source', j.source_code, 'ledger', j.ledger_id, 'entity', j.entity_id, 'period', j.fiscal_period_id,
                'posting_date', j.posting_date, 'status', j.status, 'line', jl.line_no,
                'account', a.code, 'debit', jl.debit_minor, 'credit', jl.credit_minor,
                'base_debit', jl.base_debit_minor, 'base_credit', jl.base_credit_minor,
                'currency', jl.currency, 'rate', jl.exchange_rate,
                'rule', jl.posting_rule_id, 'rule_version', jl.posting_rule_version,
                'says', jl.description) as v
         from nj j
         join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
         join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id) x),
    'subledger', (select coalesce(jsonb_agg(x.v order by x.v::text), '[]'::jsonb) from (
       select jsonb_build_object(
                'source', j.source_code,
                'kind', si.control_kind, 'account', si.control_account_id, 'item', si.item_id,
                'party', si.party_id, 'debit', si.debit_minor, 'credit', si.credit_minor,
                'currency', si.currency, 'posting_date', si.posting_date) as v
         from ns si
         left join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id) x),
    'layers', (select coalesce(jsonb_agg(x.v order by x.v::text), '[]'::jsonb) from (
       select jsonb_build_object(
                'item', l.item_id, 'site', l.site_id, 'batch', l.batch_id,
                'quantity', trim_scale(l.quantity), 'was', trim_scale((p_layers ->> l.id::text)::numeric),
                'remaining', trim_scale(l.remaining), 'unit', l.unit_cost_minor, 'currency', l.currency) as v
         from erp.stock_valuation_layer l
        where l.tenant_id = erp.current_tenant_id()
          and (not (coalesce(p_layers, '{}'::jsonb) ? l.id::text)
               or (p_layers ->> l.id::text)::numeric is distinct from l.remaining)) x),
    'unit_costs', (select coalesce(jsonb_agg(x.v order by x.v::text), '[]'::jsonb) from (
       select jsonb_build_object('item', mo.item_id, 'site', mo.site_id,
                                 'unit', erp.unit_cost_at(mo.item_id, mo.site_id)) as v
         from moved mo) x),
    'balances', (select coalesce(jsonb_agg(x.v order by x.v::text), '[]'::jsonb) from (
       select jsonb_build_object(
                'item', b.item_id, 'site', b.site_id, 'location', b.location_id,
                'batch', b.batch_id, 'serial', b.serial_id, 'container', b.container_id,
                'status', b.stock_status, 'owner', b.owner_party_id, 'custody', b.custody_party_id,
                'quantity', trim_scale(b.quantity)) as v
         from erp.stock_balance b
         join moved mo on mo.item_id = b.item_id and mo.site_id = b.site_id
        where b.tenant_id = erp.current_tenant_id()) x))
$$;

revoke all on function erp_test.count_posting_fingerprint(bigint, uuid[], uuid[], jsonb) from public, anon;

comment on function erp_test.count_posting_fingerprint(bigint, uuid[], uuid[], jsonb) is
  'What the postings since a mark wrote to the stock ledger, every journal and subledger row whatever '
  'its source, the layers, the unit costs and the balances, without ids, times, reasons or documents: '
  'the two routes erp_test.count_adjustment_suite compares (20260927200000).';

create or replace function erp_test.count_adjustment_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_auth    uuid := gen_random_uuid();
  r         record;
  x         record;
  v_fixture text;
  v_site uuid; v_loc uuid; v_item uuid; v_sup uuid; v_company uuid; v_case uuid; v_uom uuid;
  v_f1 uuid; v_f2 uuid; v_pk uuid;
  v_grn uuid; v_line uuid; v_doc uuid; v_task uuid;
  v_cons_task uuid; v_case_task uuid; v_zero_task uuid; v_plain_task uuid;
  v_bitem uuid; v_bat1 uuid; v_bat2 uuid;
  v_subledger uuid[];
  v_guard   jsonb;
  v_t0 timestamptz; v_t1 timestamptz;
  v_smv1 uuid; v_smv2 uuid;
  v_loc2 uuid;
  v_ids     uuid[] := '{}';
  v_q       numeric;
  v_mark    bigint;
  v_journals uuid[];
  v_layers  jsonb;
  v_a       jsonb;
  v_b       jsonb;
  v_a_why   jsonb;
  v_a_docs  integer;
  v_a_err   text;
  v_a_checks text;
  v_b_checks text;
  v_tasks integer; v_approved integer; v_varied integer; v_on_sheet integer;
  v_n integer; v_n2 integer; v_n3 integer; v_n4 integer;
  v_err text; v_err2 text; v_err3 text; v_err4 text;
  v_state text; v_fact text;
  v_before numeric; v_after numeric; v_co_before numeric; v_co_after numeric;
  res jsonb;
  k text;
begin
  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-cadj-' || v_hex, 'Count adjustment suite',
      'a@zz-cadj-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(r.admin_token);
    -- The demonstration builder refuses a live organisation, as it should.
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

    -- The demonstration's configuration and a slice of its trading, built by
    -- the routines the tenant screen and supabase/ci/seed_demo.sql run: its
    -- items, places, average costs, posting rules, count programme and sheet.
    v_fixture := 'configuring the demonstration';
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    v_fixture := 'seeding the demonstration''s trading';
    perform erp.seed_demo_history(current_date - 30, null, 1);

    -- Positions the demonstration lacks (design §2): stock a supplier owns,
    -- on the first item at the first place the company holds stock; two
    -- products costed first in, first out, each received twice at two
    -- prices, one to be found short and one over; and a product received in
    -- a case under a policy that counts it by the case. All received on
    -- receipts, so the books hold what the shelves do.
    v_fixture := 'the consigned, layered and packed positions';
    select b.site_id, b.location_id, b.item_id into v_site, v_loc, v_item
      from erp.stock_balance b
      join erp.item i on i.tenant_id = b.tenant_id and i.id = b.item_id
      join erp.location l on l.tenant_id = b.tenant_id and l.id = b.location_id
     where b.tenant_id = r.tenant_id and b.quantity > 0 and b.container_id is null
     order by i.code, l.code
     limit 1;
    select i.stock_uom_id into v_uom from erp.item i where i.id = v_item;
    v_company := erp.entity_party_for_site(v_site);
    select pr.party_id into v_sup
      from erp.party_role pr
      join erp.party p on p.tenant_id = pr.tenant_id and p.id = pr.party_id
     where pr.tenant_id = r.tenant_id and pr.role_kind = 'supplier' and pr.status = 'active'
     order by p.code
     limit 1;

    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id,
      to_location_id, to_status, quantity, uom_id, currency, owner_party_id, reason_code)
    select r.tenant_id, s.entity_id, v_site, 'goods_receipt', v_item, v_loc, 'available', 5,
           v_uom, 'GBP', v_sup, 'consignment_fixture'
      from erp.site s where s.id = v_site;

    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-CADJ-F1', 'Layered, found over', v_uom, 'active') returning id into v_f1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-CADJ-F2', 'Layered, found short', v_uom, 'active') returning id into v_f2;
    insert into erp.item (tenant_id, code, name, stock_uom_id, item_class, status)
    values (r.tenant_id, 'ZZ-CADJ-P', 'Packed in a case', v_uom, 'ZZCADJ', 'active') returning id into v_pk;
    insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
    values (r.tenant_id, 'zz_cadj_f1', 'Count adjustment suite, F1', 'fifo', v_f1, 'active'),
           (r.tenant_id, 'zz_cadj_f2', 'Count adjustment suite, F2', 'fifo', v_f2, 'active');
    insert into erp.container_identity_policy (tenant_id, code, name, item_class, site_id,
      device_task_code, identity_level, count_method, effective_from)
    values (r.tenant_id, 'ZZ-CADJ-CASE', 'Count the suite''s product by the case', 'ZZCADJ', v_site,
            'count', 'case', 'by_container', current_date - 1);

    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_f1, 10, 400, 'First layer');
    perform erp.add_document_line(v_grn, v_f2, 10, 400, 'First layer');
    update erp.document_line set location_id = v_loc where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_f1, 10, 600, 'Second layer');
    perform erp.add_document_line(v_grn, v_f2, 10, 600, 'Second layer');
    update erp.document_line set location_id = v_loc where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');

    v_case := erp.create_handling_unit(v_site, v_loc, 'case', null, 'ZZ-CADJ-' || v_hex, v_pk);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    v_line := erp.add_document_line(v_grn, v_pk, 3, 250, 'Packed');
    update erp.document_line set location_id = v_loc, container_id = v_case where id = v_line;
    perform erp.transition_document(v_grn, 'post');

    -- A product tracked by batch, received in two batches at two places
    -- (a raise counts an item once at a place, whatever its batches): one to
    -- be found short, one over, each counted and posted in its batch.
    select b.location_id into v_loc2
      from erp.stock_balance b
      join erp.location l on l.tenant_id = b.tenant_id and l.id = b.location_id
     where b.tenant_id = r.tenant_id and b.site_id = v_site and b.location_id <> v_loc
       and b.quantity > 0 and b.container_id is null
     order by l.code
     limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, status)
    values (r.tenant_id, 'ZZ-CADJ-B', 'Tracked by batch', v_uom, true, 'active') returning id into v_bitem;
    v_bat1 := erp.create_batch(v_bitem, 'ZZ-CADJ-B1-' || v_hex);
    v_bat2 := erp.create_batch(v_bitem, 'ZZ-CADJ-B2-' || v_hex);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    v_line := erp.add_document_line(v_grn, v_bitem, 6, 300, 'First batch');
    update erp.document_line set location_id = v_loc, batch_id = v_bat1 where id = v_line;
    v_line := erp.add_document_line(v_grn, v_bitem, 6, 300, 'Second batch');
    update erp.document_line set location_id = v_loc2, batch_id = v_bat2 where id = v_line;
    perform erp.transition_document(v_grn, 'post');

    -- Every count inside tolerance, so every task is approved as it is
    -- recorded and is Post's to finish.
    v_fixture := 'raising and recording the counts';
    update erp.count_programme set tolerance_absolute = 1000000, tolerance_pct = 999
     where tenant_id = r.tenant_id and code = 'cycle_a';
    v_tasks := erp.raise_count_tasks('cycle_a');

    -- A deterministic variance per task, cycling 0, +2, -1, +3, -2 in item
    -- order and never below nothing. The positions added above are pinned
    -- whatever the cycle says: the consigned one loses one, the case gains
    -- two, and of the two layered products one gains two and one loses three.
    v_approved := 0;
    for x in
      select t.id, t.owner_party_id, t.container_id, t.item_id, t.batch_id,
             t.expected_quantity + t.movement_during - t.committed_quantity as expect,
             row_number() over (order by i.code, l.code, t.owner_party_id, t.container_id) as n
        from erp.count_task t
        join erp.item i on i.tenant_id = t.tenant_id and i.id = t.item_id
        left join erp.location l on l.tenant_id = t.tenant_id and l.id = t.location_id
       where t.tenant_id = r.tenant_id and t.status = 'open'
       order by n
    loop
      v_q := case when x.owner_party_id = v_sup then x.expect - 1
                  when x.container_id = v_case then x.expect + 2
                  when x.item_id = v_f1 then x.expect + 2
                  when x.item_id = v_f2 then x.expect - 3
                  when x.batch_id = v_bat1 then x.expect - 2
                  when x.batch_id = v_bat2 then x.expect + 1
                  else greatest(0, x.expect + (array[0, 2, -1, 3, -2])[1 + (x.n % 5)::integer]) end;
      if erp.record_count(x.id, v_q)::text = 'approved' then
        v_approved := v_approved + 1;
      end if;
      v_ids := v_ids || x.id;
    end loop;

    select count(*) filter (where t.variance <> 0),
           count(*) filter (where t.document_line_id is not null)
      into v_varied, v_on_sheet
      from erp.count_task t where t.tenant_id = r.tenant_id and t.id = any (v_ids);
    select t.id into v_cons_task from erp.count_task t
     where t.tenant_id = r.tenant_id and t.id = any (v_ids) and t.owner_party_id = v_sup;
    select t.id into v_case_task from erp.count_task t
     where t.tenant_id = r.tenant_id and t.id = any (v_ids) and t.container_id = v_case;
    select t.id into v_zero_task from erp.count_task t
     where t.tenant_id = r.tenant_id and t.id = any (v_ids) and t.variance = 0
     order by t.id limit 1;

    -- 1. The fixture is what the comparison needs.
    return query select 'the demonstration raises its counts, every one approved, on a sheet, with variances, a consigned, a packed, two layered and two batches among them',
      v_tasks = cardinality(v_ids) and v_tasks >= 30 and v_approved = v_tasks
      and v_on_sheet = v_tasks and v_varied > v_tasks / 2 and v_varied < v_tasks
      and (select t.variance from erp.count_task t where t.id = v_cons_task) = -1
      and (select t.variance from erp.count_task t where t.id = v_case_task) = 2
      and (select t.counts_container from erp.count_task t where t.id = v_case_task)
      and (select string_agg(trim_scale(t.variance)::text, ',' order by t.variance) from erp.count_task t
            where t.tenant_id = r.tenant_id and t.item_id in (v_f1, v_f2)) = '-3,2'
      and (select string_agg(trim_scale(t.variance)::text, ',' order by t.variance) from erp.count_task t
            where t.tenant_id = r.tenant_id and t.item_id = v_bitem and t.batch_id in (v_bat1, v_bat2)) = '-2,1',
      format('%s task(s) raised, %s approved, %s on a sheet, %s with a variance; consigned %s, packed %s, batches %s',
             v_tasks, v_approved, v_on_sheet, v_varied,
             coalesce((select trim_scale(t.variance)::text from erp.count_task t where t.id = v_cons_task), 'no task'),
             coalesce((select trim_scale(t.variance)::text from erp.count_task t where t.id = v_case_task), 'no task'),
             coalesce((select string_agg(trim_scale(t.variance)::text, ',' order by t.variance) from erp.count_task t
                        where t.tenant_id = r.tenant_id and t.item_id = v_bitem), 'no task'));

    -- 2–7. Before either route, each rolled back.
    --
    -- 2, 3. An organisation with no stock adjustment type, and one whose type
    --    writes another movement than count_adjustment, post their variance
    --    as they always have, by the movement erp.post_count() writes itself,
    --    and the books still agree.
    select t.id into v_plain_task from erp.count_task t
     where t.tenant_id = r.tenant_id and t.id = any (v_ids) and t.variance <> 0
       and t.owner_party_id = v_company and t.container_id is null and t.batch_id is null
       and t.item_id not in (v_f1, v_f2)
     order by t.id limit 1;
    foreach k in array array['inactive', 'retyped'] loop
      v_fixture := format('posting with the stock adjustment type %s', k);
      v_err := null; v_err2 := null;
      begin
        if k = 'inactive' then
          update erp.document_type set status = 'inactive'
           where tenant_id = r.tenant_id and code = 'stock_adjustment';
        else
          update erp.document_type set stock_movement_type = 'scrap'
           where tenant_id = r.tenant_id and code = 'stock_adjustment';
        end if;
        select coalesce(max(m.id), 0) into v_mark from erp.stock_movement m;
        select coalesce(array_agg(j.id), '{}') into v_journals from erp.journal j
         where j.tenant_id = r.tenant_id;
        perform erp.post_count(v_plain_task);
        select count(*),
               count(*) filter (where m.reason_code = 'count_variance' and m.document_id is null
                                  and m.movement_type = 'count_adjustment'
                                  and m.cost_minor is not null and m.cost_minor > 0)
          into v_n, v_n2
          from erp.stock_movement m where m.tenant_id = r.tenant_id and m.id > v_mark;
        select count(*) into v_n3 from erp.journal j
         where j.tenant_id = r.tenant_id and not (j.id = any (v_journals));
        select count(*) into v_n4 from erp.document d
          join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
         where d.tenant_id = r.tenant_id and dt.base_type_code = 'adjustment' and d.attributes ? 'count_task_id';
        v_state := (select t.status::text || ' ' || coalesce(t.adjustment_document_id::text, 'no adjustment')
                      from erp.count_task t where t.id = v_plain_task);
        begin
          perform erp.assert_stock_reconciles();
          perform erp.assert_inventory_reconciles();
          perform erp.assert_subledger_reconciles();
          perform erp.assert_inventory_sane();
          v_err2 := 'passed';
        exception when others then v_err2 := left(sqlerrm, 200); end;
        raise exception 'CLOVEERP_ROUTE_UNDO';
      exception when others then
        if sqlerrm <> 'CLOVEERP_ROUTE_UNDO' then v_err := left(sqlerrm, 200); end if;
      end;
      return query select case k
               when 'inactive' then 'an organisation with no stock adjustment type posts its variance by the movement it always did, and the books reconcile'
               else 'a stock adjustment type that writes another movement is not used: the variance posts by the movement it always did, and the books reconcile' end,
        v_err is null and v_n = 1 and v_n2 = 1 and v_n3 = 1 and v_n4 = 0
        and v_state = 'posted no adjustment' and v_err2 = 'passed'
        and (select dt.status::text || ' ' || coalesce(dt.stock_movement_type, 'none') from erp.document_type dt
              where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment') = 'active count_adjustment',
        coalesce('stopped: ' || v_err,
          format('%s movement(s), %s by the old route and costed; %s journal(s); %s adjustment(s); task %s; books %s',
                 v_n, v_n2, v_n3, v_n4, v_state, v_err2));
    end loop;

    -- 4. A count that names no location is refused by name, not posted to
    --    the site's default place.
    v_fixture := 'posting a count with no place';
    v_err := null;
    begin
      update erp.count_task set location_id = null where id = v_plain_task;
      perform erp.post_count(v_plain_task);
      v_err := 'posted';
    exception when others then v_err := left(sqlerrm, 200); end;
    return query select 'a count that names no location is refused by name rather than posted to a default place',
      v_err like 'CLOVEERP_COUNT_HAS_NO_PLACE:%'
      and (select t.status::text from erp.count_task t where t.id = v_plain_task) = 'approved'
      and (select t.location_id from erp.count_task t where t.id = v_plain_task) is not null
      and not exists (select 1 from erp.document d
                       where d.tenant_id = r.tenant_id and d.attributes ->> 'count_task_id' = v_plain_task::text),
      v_err;

    -- 5. A count with no variance raises no adjustment.
    v_err2 := null;
    begin
      perform erp.raise_count_adjustment(v_zero_task);
      v_err2 := 'raised';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    return query select 'a count with no variance raises no adjustment',
      v_err2 like 'CLOVEERP_COUNT_HAS_NO_VARIANCE:%',
      v_err2;

    -- 6. What the organisation requires to approve a stock adjustment is not
    --    asked of a count's: the approve is derived from the count's own
    --    approval. Today's behaviour, pinned so that PR11's I5 has to meet it
    --    (see the header): a permission moved onto the approve is recorded as
    --    not held and not asked for, and a chain named on the type is never
    --    requested, because the lifecycle has no submit and a chain is only
    --    requested at submit. When I5 gives it one, the approve from draft
    --    below fails, and so does this case.
    v_fixture := 'posting past the organisation''s own approval of an adjustment';
    v_err := null; v_guard := null;
    begin
      insert into erp_ref.permission (code, module_code, action, name_key)
      values ('inventory.zz_cadj_approve', 'inventory', 'zz_cadj_approve', 'permission.inventory.zz_cadj_approve');
      -- A version in force is not edited, so the organisation's move is a new
      -- version of the adjustment's lifecycle, identical but for the approve's
      -- permission, in force from today.
      select smv.id into v_smv1
        from erp.state_machine_version smv
        join erp.state_machine sm on sm.id = smv.state_machine_id
       where sm.tenant_id = r.tenant_id and smv.status = 'active'
         and sm.code = (select dt.state_machine_code from erp.document_type dt
                         where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment');
      insert into erp.state_machine_version (tenant_id, state_machine_id, version, status, effective_from, note)
      select smv.tenant_id, smv.state_machine_id,
             (select max(v2.version) + 1 from erp.state_machine_version v2 where v2.state_machine_id = smv.state_machine_id),
             'draft', current_date, 'the count adjustment suite'
        from erp.state_machine_version smv where smv.id = v_smv1
      returning id into v_smv2;
      insert into erp.state (tenant_id, state_machine_version_id, code, name_key, name, description,
                             is_initial, is_terminal, is_committed, sort_order, on_enter, on_exit)
      select s.tenant_id, v_smv2, s.code, s.name_key, s.name, s.description,
             s.is_initial, s.is_terminal, s.is_committed, s.sort_order, s.on_enter, s.on_exit
        from erp.state s where s.state_machine_version_id = v_smv1;
      insert into erp.transition (tenant_id, state_machine_version_id, code, name_key, name, description,
                                  from_state_id, to_state_id, guard, required_permission, effects,
                                  is_automatic, sort_order)
      select tr.tenant_id, v_smv2, tr.code, tr.name_key, tr.name, tr.description, f2.id, t2.id, tr.guard,
             case when tr.code = 'approve' then 'inventory.zz_cadj_approve' else tr.required_permission end,
             tr.effects, tr.is_automatic, tr.sort_order
        from erp.transition tr
        join erp.state f on f.id = tr.from_state_id
        join erp.state tt on tt.id = tr.to_state_id
        join erp.state f2 on f2.state_machine_version_id = v_smv2 and f2.code = f.code
        join erp.state t2 on t2.state_machine_version_id = v_smv2 and t2.code = tt.code
       where tr.state_machine_version_id = v_smv1;
      perform erp.activate_state_machine_version(v_smv2, current_date);
      select count(*) into v_n from erp.transition tr
       where tr.state_machine_version_id = v_smv2 and tr.code = 'approve'
         and tr.required_permission = 'inventory.zz_cadj_approve';
      insert into erp.approval_chain (tenant_id, code, name, object_type, applies_when)
      values (r.tenant_id, 'zz_cadj_adjustment', 'Count adjustment suite: a stock adjustment is approved', 'document',
              '{"==": [{"var": "document_type"}, "stock_adjustment"]}'::jsonb);
      update erp.document_type set approval_chain_code = 'zz_cadj_adjustment'
       where tenant_id = r.tenant_id and code = 'stock_adjustment';
      perform erp.post_count(v_plain_task);
      select t.adjustment_document_id into v_doc from erp.count_task t where t.id = v_plain_task;
      select l.guard_data -> 'derived' into v_guard from erp.state_transition_log l
       where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_doc
         and l.transition_code = 'approve';
      select count(*) into v_n2 from erp.approval_request ar
       where ar.tenant_id = r.tenant_id and ar.object_type = 'document' and ar.object_id = v_doc;
      -- The lifecycle as it stands: no submit, and the approve leaves the
      -- state a document is opened in.
      select count(*) filter (where tr.code = 'submit'),
             count(*) filter (where tr.code = 'approve' and fs.is_initial and fs.code = 'draft')
        into v_n3, v_n4
        from erp.transition tr
        join erp.state fs on fs.id = tr.from_state_id
        join erp.state_machine_version v on v.id = tr.state_machine_version_id
        join erp.state_machine sm on sm.id = v.state_machine_id
       where tr.tenant_id = r.tenant_id and v.status = 'active'
         and sm.code = (select dt.state_machine_code from erp.document_type dt
                         where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment');
      v_state := erp.object_current_state('document', v_doc);
      raise exception 'CLOVEERP_ROUTE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_ROUTE_UNDO' then v_err := left(sqlerrm, 200); end if;
    end;
    return query select 'a count''s adjustment is approved past a permission moved onto the approve and a chain named on the type, because its lifecycle has no submit',
      v_err is null and v_n = 1 and v_state = 'posted'
      and v_guard ->> 'fact' = 'erp.count_task_is_approved'
      and v_guard ->> 'permission' = 'inventory.zz_cadj_approve'
      and (v_guard ->> 'actor_permitted')::boolean is false
      and v_n2 = 0 and v_n3 = 0 and v_n4 = 1
      and (select dt.approval_chain_code from erp.document_type dt
            where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment') is null,
      coalesce('stopped: ' || v_err,
        format('%s approve moved; adjustment %s; derived %s; %s approval request(s); %s submit(s); approve from draft %s',
               v_n, v_state, coalesce(v_guard::text, 'nothing'), v_n2, v_n3, v_n4));

    -- 7. A post that runs across the site's midnight is dated by one reading.
    --    The site's time zone is stubbed, within the block, to fall a day
    --    later once the adjustment has its line: the moment the raise decided
    --    is the one the line routine uses, so the movement is not back-dated
    --    to the day before and its journal is dated with the document.
    v_fixture := 'posting a count across the site''s midnight';
    v_err := null; v_n := null; v_n2 := null; v_state := null;
    begin
      execute $stub$
        create or replace function erp.local_timezone(p_site_id uuid default null)
        returns text
        language sql
        volatile
        set search_path = ''
        as $body$
          -- A stub for erp_test.count_adjustment_suite, rolled back with it.
          select case when exists (select 1 from erp.document d
                                     join erp.document_line l on l.tenant_id = d.tenant_id and l.document_id = d.id
                                    where d.tenant_id = erp.current_tenant_id() and d.attributes ? 'count_task_id')
                      then 'Pacific/Kiritimati' else 'Etc/GMT+12' end
        $body$
      $stub$;
      v_t0 := clock_timestamp();
      perform erp.post_count(v_plain_task);
      v_t1 := clock_timestamp();
      select count(*) filter (where m.occurred_at between v_t0 and v_t1
                                and (m.occurred_at at time zone 'Etc/GMT+12')::date = d.document_date),
             count(*) filter (where j.posting_date = d.document_date and d.posting_date = d.document_date)
        into v_n, v_n2
        from erp.count_task t
        join erp.document d on d.tenant_id = t.tenant_id and d.id = t.adjustment_document_id
        join erp.stock_movement m on m.tenant_id = t.tenant_id and m.document_id = d.id
        left join erp.event ev on ev.tenant_id = m.tenant_id and ev.aggregate_id = m.movement_uid
        left join erp.journal j on j.tenant_id = m.tenant_id and j.source_event_id = ev.id
       where t.id = v_plain_task;
      v_state := erp.object_current_state('document',
                   (select t.adjustment_document_id from erp.count_task t where t.id = v_plain_task));
      raise exception 'CLOVEERP_ROUTE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_ROUTE_UNDO' then v_err := left(sqlerrm, 200); end if;
    end;
    return query select 'a post that runs across the site''s midnight dates the adjustment, its movement and its journal by one reading',
      v_err is null and v_state = 'posted' and v_n = 1 and v_n2 = 1
      and erp.local_timezone(v_site) is distinct from 'Etc/GMT+12',
      coalesce('stopped: ' || v_err,
        format('adjustment %s; %s movement(s) at the moment of the post, on the document''s day; %s journal(s) on it',
               v_state, v_n, v_n2));

    -- The mark both routes are read from.
    select coalesce(max(m.id), 0) into v_mark from erp.stock_movement m;
    select coalesce(array_agg(j.id), '{}') into v_journals from erp.journal j
     where j.tenant_id = r.tenant_id;
    select coalesce(array_agg(si.id), '{}') into v_subledger from erp.subledger_item si
     where si.tenant_id = r.tenant_id;
    select coalesce(jsonb_object_agg(l.id::text, l.remaining), '{}'::jsonb) into v_layers
      from erp.stock_valuation_layer l where l.tenant_id = r.tenant_id;

    -- Route A: as it was, and put back.
    v_fixture := 'posting as it was';
    begin
      foreach v_task in array v_ids loop
        perform erp_test.post_count_as_it_was(v_task);
      end loop;
      v_a := erp_test.count_posting_fingerprint(v_mark, v_journals, v_subledger, v_layers);
      select coalesce(jsonb_agg(distinct m.reason_code), '[]'::jsonb),
             count(*) filter (where m.document_id is not null)
        into v_a_why, v_a_docs
        from erp.stock_movement m where m.tenant_id = r.tenant_id and m.id > v_mark;
      begin
        perform erp.assert_stock_reconciles();
        perform erp.assert_inventory_reconciles();
        perform erp.assert_subledger_reconciles();
        perform erp.assert_inventory_sane();
        v_a_checks := 'passed';
      exception when others then v_a_checks := left(sqlerrm, 200); end;
      raise exception 'CLOVEERP_ROUTE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_ROUTE_UNDO' then
        v_a_err := left(sqlerrm, 200);
      end if;
    end;

    -- Route B: the adjustment, and kept.
    v_fixture := 'posting through the adjustment';
    select b.quantity into v_before from erp.stock_balance b
     where b.tenant_id = r.tenant_id and b.item_id = v_item and b.location_id = v_loc
       and b.owner_party_id = v_sup and b.container_id is null;
    select b.quantity into v_co_before from erp.stock_balance b
     where b.tenant_id = r.tenant_id and b.item_id = v_item and b.location_id = v_loc
       and b.owner_party_id = v_company and b.container_id is null;
    foreach v_task in array v_ids loop
      perform erp.post_count(v_task);
    end loop;
    v_b := erp_test.count_posting_fingerprint(v_mark, v_journals, v_subledger, v_layers);
    begin
      perform erp.assert_stock_reconciles();
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_inventory_sane();
      perform erp.assert_ownership_carried();
      v_b_checks := 'passed';
    exception when others then v_b_checks := left(sqlerrm, 200); end;

    -- 8–13. The two routes wrote the same thing, section by section.
    foreach k in array array['movements', 'journal_lines', 'subledger', 'layers', 'unit_costs', 'balances'] loop
      return query select format('posted through its adjustment, the counts write the same %s as the route they replace',
                                 replace(k, '_', ' ')),
        v_a_err is null and v_a is not null
        and jsonb_array_length(v_b -> k) > 0
        and v_a -> k = v_b -> k
        and (k <> 'journal_lines' or v_a -> 'journals' = v_b -> 'journals'),
        coalesce('route as it was stopped: ' || v_a_err,
          format('%s row(s) as it was, %s through the adjustment; only as it was: %s; only through the adjustment: %s',
                 jsonb_array_length(v_a -> k), jsonb_array_length(v_b -> k),
                 left(coalesce((select jsonb_agg(e)::text from jsonb_array_elements(v_a -> k) e
                                 where not (v_b -> k) @> jsonb_build_array(e)), 'nothing'), 120),
                 left(coalesce((select jsonb_agg(e)::text from jsonb_array_elements(v_b -> k) e
                                 where not (v_a -> k) @> jsonb_build_array(e)), 'nothing'), 120)));
    end loop;

    -- 14. What differs is what I4 changes: the reason and the document.
    select count(*),
           count(*) filter (where m.reason_code = 'COUNT_VARIANCE'),
           count(*) filter (where m.document_id is not null
                              and exists (select 1 from erp.count_task t
                                           where t.tenant_id = m.tenant_id
                                             and t.adjustment_document_id = m.document_id
                                             and t.adjustment_line_id = m.document_line_id))
      into v_n, v_n2, v_n3
      from erp.stock_movement m where m.tenant_id = r.tenant_id and m.id > v_mark;
    return query select 'only the reason and the document differ: count_variance and none as it was, the register''s COUNT_VARIANCE and the count''s adjustment now',
      v_a_why = '["count_variance"]'::jsonb and v_a_docs = 0
      and v_n = v_varied and v_n2 = v_n and v_n3 = v_n,
      format('as it was %s with %s document(s); now %s movement(s), %s under COUNT_VARIANCE, %s on their count''s adjustment line',
             v_a_why, v_a_docs, v_n, v_n2, v_n3);

    -- 15. Both routes leave the four ledgers agreeing.
    return query select 'stock, inventory, the subledger and ownership reconcile after either route',
      v_a_checks = 'passed' and v_b_checks = 'passed',
      format('as it was: %s; through the adjustment: %s', coalesce(v_a_checks, 'not run'), v_b_checks);

    -- 16. One adjustment per count with a variance, one line, posted; none
    --     for a count with none.
    select count(distinct t.adjustment_document_id),
           count(*) filter (where t.variance <> 0 and t.adjustment_document_id is not null
                              and erp.object_current_state('document', t.adjustment_document_id) = 'posted'
                              and (select count(*) from erp.document_line l
                                    where l.tenant_id = t.tenant_id and l.document_id = t.adjustment_document_id) = 1),
           count(*) filter (where t.variance = 0 and t.adjustment_document_id is null),
           count(*) filter (where t.status = 'posted')
      into v_n, v_n2, v_n3, v_n4
      from erp.count_task t where t.tenant_id = r.tenant_id and t.id = any (v_ids);
    return query select 'each count with a variance has one posted adjustment of one line, and a count with none has no adjustment',
      v_n = v_varied and v_n2 = v_varied and v_n3 = v_tasks - v_varied and v_n4 = v_tasks
      and (select count(*) from erp.document d
             join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
            where d.tenant_id = r.tenant_id and dt.base_type_code = 'adjustment'
              and d.attributes ? 'count_task_id') = v_varied,
      format('%s adjustment(s) for %s variance(s), %s posted of one line; %s of %s with none and no adjustment; %s posted',
             v_n, v_varied, v_n2, v_n3, v_tasks - v_varied, v_n4);

    -- 17. The adjustment carries the count: owner, place, batch, handling
    --     unit, the register's reason, the day it was posted and the task.
    select count(*) into v_n
      from erp.count_task t
      join erp.document d on d.tenant_id = t.tenant_id and d.id = t.adjustment_document_id
      join erp.document_line l on l.tenant_id = t.tenant_id and l.id = t.adjustment_line_id
      join erp.stock_movement m on m.tenant_id = t.tenant_id and m.document_line_id = l.id
     where t.tenant_id = r.tenant_id and t.id = any (v_ids)
       and d.stock_owner_party_id = coalesce(t.owner_party_id, v_company)
       and d.attributes ->> 'reason_code' = 'COUNT_VARIANCE'
       and d.attributes ->> 'count_task_id' = t.id::text
       and d.document_date = (m.occurred_at at time zone erp.local_timezone(t.site_id))::date
       and d.posting_date = d.document_date
       and d.document_number is not null
       and l.item_id = t.item_id and l.quantity = t.variance
       and l.location_id is not distinct from t.location_id
       and l.batch_id is not distinct from t.batch_id
       and l.container_id is not distinct from t.container_id;
    return query select 'each adjustment carries its count''s owner, place, batch, handling unit and task, under COUNT_VARIANCE, dated the day it was posted',
      v_n = v_varied,
      format('%s of %s adjustment(s) carry their count', v_n, v_varied);

    -- 18. Approved from the count's own approval, and posted.
    select count(*) filter (where l.transition_code = 'approve'
                              and l.guard_data #>> '{derived,fact}' = 'erp.count_task_is_approved'),
           count(*) filter (where l.transition_code = 'post')
      into v_n, v_n2
      from erp.count_task t
      join erp.state_transition_log l
        on l.tenant_id = t.tenant_id and l.object_type = 'document' and l.object_id = t.adjustment_document_id
     where t.tenant_id = r.tenant_id and t.id = any (v_ids);
    return query select 'each adjustment is approved as the system''s move, derived from its count''s approval, and posted by its own transition',
      v_n = v_varied and v_n2 = v_varied
      and coalesce(current_setting('erp.deriving_move', true), '') = '',
      format('%s derived approval(s), %s post(s), for %s adjustment(s); deriving_move "%s"',
             v_n, v_n2, v_varied, coalesce(current_setting('erp.deriving_move', true), ''));

    -- 19. The lineage: the adjustment's line corrects the sheet's.
    select count(*) into v_n
      from erp.count_task t
      join erp.document_relation rel
        on rel.tenant_id = t.tenant_id and rel.relation_kind = 'corrects'
       and rel.from_document_id = t.adjustment_document_id and rel.from_line_id = t.adjustment_line_id
       and rel.to_document_id = t.document_id and rel.to_line_id = t.document_line_id
       and rel.quantity = t.variance
     where t.tenant_id = r.tenant_id and t.id = any (v_ids);
    return query select 'each adjustment''s line corrects its count''s line on the sheet',
      v_n = v_varied
      and (select count(*) from erp.document_relation rel
            where rel.tenant_id = r.tenant_id and rel.relation_kind = 'corrects') = v_varied,
      format('%s of %s linked', v_n, v_varied);

    -- 20. Consigned: the supplier's position loses the unit, uncosted and
    --     unjournalled; the company's own is not touched.
    select b.quantity into v_after from erp.stock_balance b
     where b.tenant_id = r.tenant_id and b.item_id = v_item and b.location_id = v_loc
       and b.owner_party_id = v_sup and b.container_id is null;
    select b.quantity into v_co_after from erp.stock_balance b
     where b.tenant_id = r.tenant_id and b.item_id = v_item and b.location_id = v_loc
       and b.owner_party_id = v_company and b.container_id is null;
    return query select 'a count of stock the company does not own posts against the owner''s position with no cost and no journal',
      v_before = 5 and v_after = 4
      and v_co_after = v_co_before + coalesce((select t.variance from erp.count_task t
                                                 where t.tenant_id = r.tenant_id and t.id = any (v_ids)
                                                   and t.item_id = v_item and t.location_id = v_loc
                                                   and t.owner_party_id = v_company and t.container_id is null), 0)
      and exists (select 1 from erp.stock_movement m
                   join erp.count_task t on t.tenant_id = m.tenant_id and t.adjustment_document_id = m.document_id
                  where m.tenant_id = r.tenant_id and t.id = v_cons_task
                    and m.owner_party_id = v_sup and m.unit_cost_minor is null and m.cost_minor is null
                    and m.quantity = 1 and m.from_location_id = v_loc)
      and not exists (select 1 from erp.journal j
                       where j.tenant_id = r.tenant_id and j.source_code = 'stock.adjusted'
                         and not (j.id = any (v_journals))
                         and j.source_event_id in (select ev.id from erp.event ev
                                                     join erp.stock_movement m on m.movement_uid = ev.aggregate_id
                                                     join erp.count_task t on t.adjustment_document_id = m.document_id
                                                    where t.id = v_cons_task)),
      format('supplier''s position %s then %s; the company''s %s then %s',
             trim_scale(v_before), trim_scale(v_after), trim_scale(v_co_before), trim_scale(v_co_after));

    -- 21. Packed: the variance moves in the case it was counted in.
    return query select 'a count of stock in a handling unit posts in that unit',
      exists (select 1 from erp.stock_movement m
                join erp.count_task t on t.tenant_id = m.tenant_id and t.adjustment_document_id = m.document_id
               where m.tenant_id = r.tenant_id and t.id = v_case_task
                 and m.container_id = v_case and m.to_location_id = v_loc and m.quantity = 2)
      and (select b.quantity from erp.stock_balance b
            where b.tenant_id = r.tenant_id and b.item_id = v_pk and b.container_id = v_case) = 5,
      format('the case holds %s',
             coalesce((select trim_scale(b.quantity)::text from erp.stock_balance b
                        where b.tenant_id = r.tenant_id and b.item_id = v_pk and b.container_id = v_case), 'nothing'));

    -- 22. Layered: what is found is layered at what the books say a unit is
    --     worth, and what is missing leaves the oldest layer first.
    return query select 'a count of stock costed first in, first out layers what it finds and issues what is missing from the oldest layer',
      exists (select 1 from erp.stock_valuation_layer l
               where l.tenant_id = r.tenant_id and l.item_id = v_f1
                 and l.quantity = 2 and l.remaining = 2 and l.unit_cost_minor = 500)
      and (select string_agg(trim_scale(l.remaining)::text || '@' || l.unit_cost_minor, ',' order by l.received_at, l.id)
             from erp.stock_valuation_layer l
            where l.tenant_id = r.tenant_id and l.item_id = v_f2) = '7@400,10@600'
      and exists (select 1 from erp.stock_movement m
                   join erp.count_task t on t.tenant_id = m.tenant_id and t.adjustment_document_id = m.document_id
                  where m.tenant_id = r.tenant_id and t.item_id = v_f2 and m.cost_minor = 1200)
      and jsonb_array_length(v_b -> 'layers') >= 2,
      format('F1 layers %s; F2 layers %s',
             (select string_agg(trim_scale(l.remaining)::text || '@' || l.unit_cost_minor, ',' order by l.received_at, l.id)
                from erp.stock_valuation_layer l where l.tenant_id = r.tenant_id and l.item_id = v_f1),
             (select string_agg(trim_scale(l.remaining)::text || '@' || l.unit_cost_minor, ',' order by l.received_at, l.id)
                from erp.stock_valuation_layer l where l.tenant_id = r.tenant_id and l.item_id = v_f2));

    -- 23. Nothing is posted twice.
    begin
      perform erp.raise_count_adjustment(v_cons_task);
      v_err := 'raised';
    exception when others then v_err := left(sqlerrm, 200); end;
    begin
      perform erp.post_count(v_cons_task);
      v_err2 := 'posted';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    begin
      perform erp.post_stock_adjustment((select t.adjustment_document_id from erp.count_task t where t.id = v_cons_task));
      v_err3 := 'posted';
    exception when others then v_err3 := left(sqlerrm, 200); end;
    return query select 'a count posted through its adjustment is not raised, posted or adjusted again',
      v_err like 'CLOVEERP_COUNT_ADJUSTMENT_RAISED:%'
      and v_err2 like 'CLOVEERP_COUNT_NOT_APPROVED:%'
      and v_err3 like 'CLOVEERP_ADJUSTMENT_ALREADY_POSTED:%',
      v_err || ' / ' || v_err2 || ' / ' || v_err3;

    -- 24. The free-hand door costs only what the company owns, and derives
    --     nothing. A hand-typed COUNT_VARIANCE is still taken (PR11, I5).
    v_fixture := 'a hand-typed adjustment of consigned stock';
    res := erp.raise_stock_adjustment(v_site, 'COUNT_VARIANCE',
             jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', v_loc)),
             null, null, 'ZZ-CADJ-' || v_hex);
    v_doc := (res ->> 'document_id')::uuid;
    perform erp.set_document_stock_owner(v_doc, v_sup);
    perform set_config('erp.deriving_move', v_doc::text || ':approve', true);
    v_fact := erp.derived_move_fact('document', v_doc, 'approve');
    perform set_config('erp.deriving_move', '', true);
    perform erp.transition_document(v_doc, 'approve', 'suite');
    res := erp.post_stock_adjustment(v_doc);
    begin
      perform erp.assert_inventory_reconciles();
      perform erp.assert_stock_reconciles();
      v_err := 'passed';
    exception when others then v_err := left(sqlerrm, 200); end;
    return query select 'a hand-typed adjustment of stock the company does not own is not costed, and the books still agree',
      v_fact is null
      and (res ->> 'cost_minor')::bigint = 0 and (res ->> 'journals')::integer = 0
      and exists (select 1 from erp.stock_movement m
                   where m.tenant_id = r.tenant_id and m.document_id = v_doc
                     and m.owner_party_id = v_sup and m.cost_minor is null and m.reason_code = 'COUNT_VARIANCE')
      and (select b.quantity from erp.stock_balance b
            where b.tenant_id = r.tenant_id and b.item_id = v_item and b.location_id = v_loc
              and b.owner_party_id = v_sup and b.container_id is null) = 3
      and v_err = 'passed',
      format('derived fact %s; %s; books %s', coalesce(v_fact, 'none'), res - 'document_id', v_err);

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
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-cadj-' || v_hex)
            and coalesce(current_setting('erp.deriving_move', true), '') = ''
            and not exists (select 1 from erp_ref.permission p where p.code = 'inventory.zz_cadj_approve')
            and pg_get_functiondef('erp.local_timezone(uuid)'::regprocedure) not like '%A stub for erp_test.count_adjustment_suite%';
  detail := 'the organisation, its counts, its adjustments and their postings rolled back, no move named, '
            'the permission it made gone and the site''s time zone its own again';
  return next;
end;
$function$;

revoke all on function erp_test.count_adjustment_suite() from public, anon;

create or replace function erp_test.assert_count_adjustment_suite()
returns void
language plpgsql
security definer
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
    from erp_test.count_adjustment_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_COUNT_ADJUSTMENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A count variance posts through a stock adjustment of its own, and must post what erp.post_count() used to. Read the case that failed.';
  end if;
  if v_total <> 25 then
    raise exception 'CLOVEERP_COUNT_ADJUSTMENT_SUITE_SHRANK: % case(s), expected 25; the fixture stopped %', v_total,
      coalesce(v_ended, 'nowhere')
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_count_adjustment_suite() from public, anon;

comment on function erp_test.assert_count_adjustment_suite() is
  'On an organisation configured and seeded as the demonstration is, the counts posted through their '
  'own stock adjustments write the same movements, journals, subledger, layers, unit costs and '
  'balances as the route they replace, reason and document aside, every journal and subledger row read '
  'whatever its source; an organisation with no stock adjustment type, or one that writes another '
  'movement, posts by the old movement and reconciles; a count with no place is refused; the '
  'organisation''s own approval of an adjustment is not asked of a count''s (pinned for I5); a post '
  'across midnight is dated by one reading; consigned stock is not costed on '
  'either door, packed stock moves in its unit, layered stock is layered and issued oldest first, and each adjustment is approved from its count and '
  'corrects its sheet line (20260927200000).';

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
