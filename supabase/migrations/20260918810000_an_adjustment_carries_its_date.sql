set lock_timeout = '30s';

-- =============================================================================
-- 20260918810000  An adjustment carries its date
-- -----------------------------------------------------------------------------
-- Six of the Definition of Done's seven seeded transactions are in the month
-- and asserted. The seventh, a stock adjustment, could not be seeded at all,
-- and 20260918600000 stopped rather than bodge it. Its finding was read again
-- against the deployed bodies before a line of this was written, and all of it
-- is true:
--
--   * erp.write_off_stock() (20260906143000) inserts erp.stock_movement with
--     no occurred_at, so the movement takes the column's default, the clock.
--   * erp.post_count() (20260829240000) does the same for both arms of a
--     count variance.
--   * erp.post_movement_finance() (20260906050000) dates the journal and the
--     subledger row on coalesce(m.occurred_at::date, current_date), so the
--     ledger follows the movement — which is why the movement being stamped
--     with the clock is the whole defect and not half of it.
--   * Neither takes a date. Neither makes a document. erp_ref.document_type
--     has carried the 'adjustment' base type — "A deliberate change to stock,
--     with a reason" — since 0025 and no installer has ever made a tenant
--     document type of it, so nothing in the product binds the scrap or
--     count_adjustment movement types to a document.
--   * erp_ref.reason_code has carried ten STOCK_ADJUSTMENT reasons since
--     20260903110000 and nothing uses one; erp.post_count() writes the string
--     'count_variance' in lower case, which is not a code in that register.
--
-- So a write-off built into last September would be dated today, fall outside
-- the month it was built for, carry no DEMO- reference, and be written a second
-- time by a second call on a day that built nothing else.
--
-- ── DECISION 1: A DOCUMENT, NOT A DATE ARGUMENT ──────────────────────────────
--
-- Two ways to give an adjustment a date. A p_adjusted_on argument on
-- erp.write_off_stock() is four lines; a stock adjustment document is this
-- file. The document wins, and not because it is grander:
--
--   A date on a bare movement is a date nobody agreed to. Every other dated
--   thing in this product is dated on a document — a receipt, a delivery, an
--   invoice, a transfer order — and the document is what carries the number
--   somebody can quote, the reason, the approval before it posts, the audit
--   trail of who raised it and who approved it, and the reference that makes a
--   seeded slice idempotent. A write-off is the one stock movement whose whole
--   substance is an assertion about the past: "this stock is not there, and it
--   was not there on this date". Backdating it is exactly the case that needs
--   an approver's name against it, and a bare function call has nowhere to put
--   one.
--
--   The idempotence the seeder needs is a property of documents. A day's slice
--   is skipped when a document carrying that day's DEMO- reference exists. A
--   movement has no reference, so a bare write-off could not be found and would
--   be written again on every rebuild.
--
--   The vocabulary is already here and inert. A base type, a name in two
--   locales, a reason register with ten entries, a movement type that allows
--   negative and requires a reason. Six pieces written for this and no
--   mechanism between them, which is the same shape 20260917130000 found for
--   the transfer order. An argument on write_off_stock leaves all six inert
--   and adds a seventh loose end.
--
-- What it costs: erp.write_off_stock() and erp.post_count() are left exactly as
-- they are. They remain the undated paths — a warehouse writing off a broken
-- pallet now, a count posting the variance it found now — and neither should
-- take a date, because neither has an approver. Nothing is deprecated here.
--
-- ── DECISION 2: THE JOURNAL IS THE MOVEMENT'S, NOT THE DOCUMENT'S ────────────
--
-- erp.post_movement_finance() already posts a count variance and a write-off
-- at the movement's exact cost — inventory against the stock adjustments
-- account (§8.1 5900, statutory 6300, an expense account) through the
-- stock_adjustment posting rule the inventory installer has shipped since
-- 20260906050000 — and it already dates the journal and the subledger row on
-- the movement's occurred_at. Give the movement its date and the ledger
-- follows it, to the day, with no new posting rule, no new basis and no new
-- account.
--
-- The alternative is a document posting rule read by erp.post_document_finance().
-- It cannot work here and saying why is worth four lines: that bridge refuses a
-- document whose erp.document_value_minor() is nought (CLOVEERP_ZERO_VALUE),
-- and an adjustment line carries no price because nothing is being bought or
-- sold; and a posting rule's lines have fixed sides, so one rule cannot both
-- debit inventory for stock found and credit it for stock lost.
--
-- So erp_ref.document_type.adjustment.affects_finance goes to FALSE. The flag
-- means "the document bridge raises this document's journal from a document
-- posting rule", and for an adjustment it does not: the journal comes from the
-- movement, at the movement's cost, on the movement's date. affects_stock stays
-- true, and erp.assert_no_dead_configuration() is satisfied either way — it
-- asks a type that reaches the ledger for a posting rule, and asks a type that
-- moves stock for a movement type, which this one names. The flip is inert for
-- every organisation that exists: nothing has ever made a document type on this
-- base type, so there is nothing for it to change until the type below arrives.
--
-- ── DECISION 3: BACKDATING BEFORE A LATER MOVEMENT IS ALLOWED, AND THE DATE
--    IS A DATE OF RECORD ─────────────────────────────────────────────────────
--
-- A backdated movement lands in the middle of a valuation history, and the
-- costing store has no history to land in the middle of. erp.item_cost is a
-- running position and erp.stock_valuation_layer a running stack; neither is
-- dated in a way that could be rewound, and FIFO consumption is a destructive
-- `update ... set remaining = remaining - v_take` that leaves no record of
-- which layers an issue took. So a write-off dated before a later issue
-- consumes the layers that are there NOW, not the ones that were there then,
-- and the later issue keeps the cost it was valued at.
--
-- That is stated rather than hidden, and what it does and does not cost is
-- exact:
--
--   IT DOES NOT MOVE A PENNY OF THE TOTAL. Thirty units at 20 and ten at 60.
--   An issue of thirty takes the older layer, 600. A write-off of five
--   backdated before that issue then takes five of the ten at 60, 300 — where,
--   had it truly happened first, it would have taken 100 and the issue 800.
--   600 + 300 = 900 and 100 + 800 = 900. The cost that has left the stock
--   ledger is the same figure either way, because the layers are the same
--   layers and only the order they were consumed in differs. Valuation and the
--   inventory control account therefore still agree to the penny, and every one
--   of the four ties holds. Case 8 of the suite proves exactly this, on a
--   product kept in layers at two prices, arithmetic and all.
--
--   WHAT IT DOES MOVE is which date and which account carried it. In the
--   example, 200 of cost sits on stock adjustments in the earlier period and
--   off cost of sales in the later one, where a true rewind would have put 100
--   on stock adjustments and 100 more through cost of sales. That is a
--   difference between periods and between two profit and loss accounts, and it
--   is real.
--
-- Refusing to backdate before the last movement of that product at that site
-- was considered and not taken. It is defensible and it is also wrong for the
-- case this exists for: a count on the last day of a month is keyed in on the
-- second of the next, by which time the product has moved half a dozen times,
-- and a rule that refuses the count is a rule that guarantees the shelf and the
-- system stay apart. The adjustment's date is therefore THE DATE THE FACT WAS
-- TRUE, not a date at which the valuation is rewound, and the screen says so in
-- those words.
--
-- ── DECISION 4: WHO MAY BACKDATE, AND HOW FAR ────────────────────────────────
--
-- Somebody who can date a stock movement into a past period can move profit
-- between months, so backdating is a second act and asks a second permission.
-- No new permission code is minted for it: the product already has one that
-- means "you may decide what date an entry reaches the ledger on", and it is
-- finance.post.
--
--   An adjustment dated TODAY asks inventory.adjust and nothing else. That is
--   the warehouse user counting stock this morning, and it is the ordinary
--   case.
--
--   An adjustment dated EARLIER asks inventory.adjust AND finance.post, at the
--   raise and again at the posting, because the posting is where the ledger is
--   written and the document's date may have been changed between the two. No
--   role in the base pack's library holds both by accident: warehouse_manager
--   has inventory.adjust and not finance.post, finance_clerk the reverse. An
--   administrator holds both, which is what the demonstration's seeder is.
--
--   An adjustment dated in the FUTURE is refused outright
--   (CLOVEERP_ADJUSTMENT_IN_THE_FUTURE). Stock that will be missing next week
--   is a forecast, and a forecast in the stock ledger is a lie the count would
--   then have to explain.
--
-- How far back: as far back as the books are open, and not one day further.
-- There is no invented horizon — "ninety days" is a number nothing checks.
-- erp.check_period_open() refuses a journal whose posting date falls in a
-- closed period (CLOVEERP_PERIOD_CLOSED), below every door, and
-- erp.post_movement_finance() dates the journal on the movement, so a backdated
-- adjustment meets that trigger like everything else. Case 9 of the suite
-- closes a period and proves it: the adjustment is refused, and nothing is
-- left behind.
--
-- ── WHY THE GENERIC STOCK BRIDGE IS HELD OFF ─────────────────────────────────
--
-- erp.transition_document() posts the stock side of any document whose base
-- type declares affects_stock, at the first committed state, through
-- erp.post_document_stock(). That bridge writes ONE row per line in ONE
-- direction — the movement type's — and for direction 'transfer' it writes
-- from and to the same location, which moves nothing. An adjustment goes up on
-- one line and down on the next, and count_adjustment's direction is
-- 'transfer'. The bridge cannot say what an adjustment does, so it is held off
-- for this base type by name, as 20260917130000 held it off for the transfer
-- order, and erp.post_stock_adjustment() writes the legs itself.
--
-- The document type still names count_adjustment, because
-- erp.assert_no_dead_configuration() requires a movement type wherever the base
-- type moves stock — and it is not dead: erp.post_stock_adjustment() reads it.
-- count_adjustment is the right type and not a compromise: it is one of the two
-- movement types that allows_negative — the other being emergency_issue, an
-- issue ahead of the paperwork — it requires_reason, it affects_valuation, and
-- erp.post_count() already writes it both ways: a gain with a to_location and a
-- loss with a from_location, which is exactly how erp.post_movement_finance()
-- tells one from the other.
--
-- ── EXISTING ORGANISATIONS ───────────────────────────────────────────────────
--
-- erp.configure_inventory() is patched so a new organisation installs the
-- lifecycle, the numbering rule and the document type. Existing ones take the
-- same three through the module upgrade register:
-- erp_ref.module_installer.current_version for inventory-operations goes to 5
-- and erp_ref.module_upgrade_item carries the three objects. All three kinds
-- are decided by containment in erp.configuration_manifest(), which is how
-- version 4's identical three were decided.
-- erp.ensure_demo_configuration() already takes an outstanding
-- inventory-operations upgrade whenever the planner offers one — the arm
-- 20260917130000 added is not written for the transfer order in particular —
-- so the demonstration takes version 5 with no new needle, and it sits above
-- the blanket update that strips the year from every numbering rule, so ADJ-
-- numbers carry no year like every other demonstration number.
--
-- ── THE MONTH'S SEVENTH TRANSACTION ──────────────────────────────────────────
--
-- SATURDAY — the weekend count. Every Saturday the warehouse counts the
-- product its bulk store holds most of and finds it one short; the shortfall is
-- written off through the doors a person uses, dated that Saturday under that
-- day's DEMO- reference, under COUNT_VARIANCE.
--
-- Saturday, and the argument for it rather than a shared weekday. A warehouse
-- counts when nothing is moving, which is the weekend, so the story is the true
-- one. And it shares a day with nothing: Monday's part receipt, Tuesday's
-- return, Wednesday's lorry, Thursday's bill and part delivery and Friday's
-- credit note are all weekdays, so no day's arithmetic comes to depend on
-- another's. Any run of seven days holds a Saturday, so the month always holds
-- four or five.
--
-- One unit, and the size matters. The Tuesday return needs a tenth of a receipt
-- line still on the shelf and the Wednesday lorry a quarter of what is standing
-- there; both are floors over balances in the hundreds, and one unit cannot
-- turn either of them into nothing. Nothing here draws on random(), so every
-- other document a day builds is the document it built before.
--
-- The demonstration's reason register gains the STOCK_ADJUSTMENT category,
-- generated from erp_ref.reason_code the way 20260918220000 generated the two
-- return categories from it, so the register and the pack cannot drift.
--
-- ── PROOF ────────────────────────────────────────────────────────────────────
--
-- erp_test.stock_adjustment_suite() (13 cases, pinned at both ends) builds its
-- own organisation, its own site and its own products, and says: an existing
-- organisation is offered the document type by the upgrade register and given
-- it; an adjustment is raised with a reason and a date and starts in draft;
-- approving it moves no stock and raises no journal, which is where the generic
-- bridge would have posted; posting it backdated writes a movement AND a
-- journal both dated that day; the write-off reaches the stock adjustments
-- account in the profit and loss for exactly the movement's cost; the movement
-- carries its reason code; stock found goes the other way and debits inventory;
-- a backdated adjustment behind a later issue leaves that issue's cost alone
-- and the total that has left is the same figure either way; a closed period
-- refuses it; a date in the future is refused; a person with inventory.adjust
-- and not finance.post may adjust today and not last week; the trial balance
-- balances and the stock ledger reconciles with all of it in the books; and the
-- fixture is undone. The suite's own fixture carries opening stock that was
-- never journalled, so it proves the two ties that do not depend on an opening
-- entry; the four together are proved where they belong, on a demonstration
-- whose whole month went through the ledger.
--
-- erp_test.demo_history_suite() gains a case and goes from nineteen to twenty,
-- in the suite and in the wrapper: the month adjusts stock on a Saturday, dated
-- that day, under that day's reference, with the movement and the journal
-- carrying the date and the cost reaching the stock adjustments account. Its
-- existing case on the four ties — the trial balance, stock valuation against
-- the inventory control, and both ageings against theirs — now runs with the
-- month's weekend counts in the books, which is the four-tie proof for a
-- backdated adjustment.
--
-- Collateral, restated with the reason. erp_test.site_transfer_suite()'s first
-- case reads inventory-operations back at version 4 after taking the upgrade;
-- the register now carries this as version 5, so it reads 5, and the number is
-- moved with the sentence that says why rather than the case being loosened to
-- read the version by name. supabase/ci/seed_demo.sql reports the weekend
-- counts beside the transfers, the credit notes, the part receipts, the bills
-- and the part deliveries; its document total grows by one a Saturday.
-- e2e/routes.ts gains the screen, as every new screen adds a line there.
-- erp_test.starter_pack_acceptance_suite() is NOT disturbed: the base pack
-- ships no stock adjustment lifecycle, so the inventory installer shipping one
-- takes nothing off the pack's plan.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. An adjustment's journal is its movement's
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.document_type
   set affects_finance = false,
       description = 'A deliberate change to stock, with a reason and a date. '
                     'Its journal is raised by the movement it writes, at the '
                     'movement''s exact cost and on the movement''s date, not '
                     'from a document posting rule: an adjustment line carries '
                     'no price, and one rule cannot both debit and credit '
                     'inventory.'
 where code = 'adjustment';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What a stock adjustment needs, written once and used twice
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The lifecycle is short on purpose. A draft is what somebody is keying in; an
-- approved adjustment is one a second pair of eyes has agreed to and nothing has
-- been written for yet; posted is when the stock moved and the ledger took it.
-- Both transitions OUT OF DRAFT carry inventory.adjust, the permission that
-- raises one — erp.assert_document_create_permissions() refuses a type that may
-- be raised by nobody who can then move it, and the steps after draft are left
-- open because the door that takes them asks inventory.adjust itself.

create or replace function erp.stock_adjustment_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'stock_adjustment', 'payload',
      jsonb_build_object(
        'code', 'stock_adjustment', 'object_type', 'document', 'name', 'Stock adjustment',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','approved','name','Approved','is_initial',false,'is_terminal',false,'is_committed',true,'sort_order',20),
          jsonb_build_object('code','posted','name','Posted','is_initial',false,'is_terminal',true,'is_committed',true,'sort_order',30),
          jsonb_build_object('code','cancelled','name','Cancelled','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',510)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','approve','name','Approved','from','draft','to','approved','required_permission','inventory.adjust','sort_order',10),
          jsonb_build_object('code','post','name','Posted','from','approved','to','posted','sort_order',20),
          jsonb_build_object('code','cancel','name','Cancelled','from','draft','to','cancelled','required_permission','inventory.adjust','sort_order',510),
          jsonb_build_object('code','approved_to_cancelled','name','Cancelled','from','approved','to','cancelled','sort_order',510)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'stock_adjustment', 'payload',
      jsonb_build_object('code','stock_adjustment','prefix','ADJ-','pad_to',6,
                         'reset_period','yearly','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'stock_adjustment', 'payload',
      jsonb_build_object('code','stock_adjustment','base_type','adjustment',
                         'name','Stock adjustment','numbering_rule','stock_adjustment',
                         'state_machine','stock_adjustment',
                         'stock_movement_type','count_adjustment',
                         'create_permission','inventory.adjust')))
$$;

revoke all on function erp.stock_adjustment_pack_items() from public, anon, authenticated;

comment on function erp.stock_adjustment_pack_items is
  'The lifecycle, the numbering rule and the document type a stock adjustment '
  'needs, as change-set items. One definition, read by the installer for new '
  'organisations and by the upgrade register for existing ones, so the two '
  'cannot say different things.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The adjustment behind an identifier
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.adjustment_document(p_document_id uuid)
returns erp.document
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503',
      hint = 'The stock adjustment does not exist in this organisation.';
  end if;

  select dt.base_type_code into v_base from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  if v_base is distinct from 'adjustment' then
    raise exception
      'CLOVEERP_NOT_A_STOCK_ADJUSTMENT: % is a %, and only a stock adjustment '
      'changes what the system says is on a shelf', d.document_number,
      coalesce(v_base, 'document')
      using errcode = '23514',
            hint = 'Raise a stock adjustment on the Stock adjustments screen.';
  end if;

  if d.site_id is null then
    raise exception
      'CLOVEERP_NO_SITE: % changes stock but names no site', d.document_number
      using errcode = '23502',
            hint = 'Raise the adjustment again naming the site whose shelf it is about.';
  end if;

  return d;
end;
$$;

revoke all on function erp.adjustment_document(uuid) from public, anon, authenticated;

comment on function erp.adjustment_document is
  'The stock adjustment behind an identifier, refusing anything that is not '
  'one and anything with no site: an adjustment is about a particular shelf.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Raising one
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The quantity on a line is SIGNED, which is what lets one document say what a
-- count says: three of this found, two of that missing. erp.document_line has
-- never constrained the sign and erp.add_document_line() has never insisted on
-- one; what refuses here is nought, because a line that changes nothing is a
-- line somebody meant to fill in.

create or replace function erp.raise_stock_adjustment(
  p_site_id     uuid,
  p_reason_code text,
  p_lines       jsonb default '[]'::jsonb,
  p_adjusted_on date default null,
  p_note        text default null,
  p_reference   text default null
) returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.site%rowtype;
  v_on     date := coalesce(p_adjusted_on, current_date);
  v_id     uuid;
  d        erp.document%rowtype;
  ln       jsonb;
  v_no     integer := 0;
  v_added  integer := 0;
  v_qty    numeric;
  v_line   uuid;
begin
  select * into s from erp.site where tenant_id = v_tenant and id = p_site_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503',
      hint = 'The site does not exist in this organisation.';
  end if;

  if v_on > current_date then
    raise exception
      'CLOVEERP_ADJUSTMENT_IN_THE_FUTURE: % is after today, and stock that will '
      'be missing next week is a forecast', v_on
      using errcode = '22007',
            hint = 'Date the adjustment the day the count was taken, or leave it empty for today.';
  end if;

  if coalesce(btrim(p_reason_code), '') = '' then
    raise exception
      'CLOVEERP_ADJUSTMENT_NEEDS_A_REASON: stock does not change by itself, and '
      'an adjustment nobody explained cannot be analysed'
      using errcode = '23514',
            hint = 'Pick a reason from the register — a count variance, damage, theft, a sample taken.';
  end if;

  -- A reason the organisation keeps in its register says what it insists on;
  -- one it does not keep insists on nothing, which is what lets a warehouse
  -- write its own words on the day.
  perform erp.check_reason_code('STOCK_ADJUSTMENT', p_reason_code, p_note);

  -- The permission the document type declares, asked here as well as inside
  -- erp.open_document(): that call reads the permission from the type's own
  -- row, so the door's text does not say which one it is, and a door whose
  -- gate cannot be read is a door no check can hold to the form in front of it.
  perform erp.authorise('inventory.adjust', s.entity_id, p_site_id, null,
                        'site', p_site_id);

  -- Backdating is a second act. Dating an entry into a past period moves profit
  -- between months, and finance.post is the permission this product already
  -- has for deciding what date an entry reaches the ledger on. Today asks
  -- nothing extra.
  if v_on < current_date then
    perform erp.authorise('finance.post', s.entity_id, p_site_id, null,
                          'site', p_site_id);
  end if;

  -- erp.open_document asks inventory.adjust again, from the type's own row.
  v_id := erp.open_document('stock_adjustment', null, s.entity_id, p_site_id,
                            p_reference, null, null);

  -- erp.create_document() dates a document today, which is right for every
  -- document raised as it happens and wrong for a count keyed in afterwards.
  -- Both dates, because erp.post_stock_adjustment() reads the posting date
  -- first, the way erp.post_document_stock() does.
  update erp.document
     set document_date = v_on,
         posting_date  = v_on,
         attributes = coalesce(attributes, '{}'::jsonb)
                      || jsonb_build_object('reason_code', upper(btrim(p_reason_code)))
                      || case when coalesce(btrim(p_note), '') = '' then '{}'::jsonb
                              else jsonb_build_object('reason_note', btrim(p_note)) end,
         updated_at = now()
   where tenant_id = v_tenant and id = v_id;

  for ln in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_no := v_no + 1;
    if coalesce(ln ->> 'item_id', '') = '' and coalesce(ln ->> 'quantity', '') = '' then
      continue;
    end if;
    if coalesce(ln ->> 'item_id', '') = '' then
      raise exception 'CLOVEERP_LINE_NEEDS_ITEM: line % has no product', v_no
        using errcode = '23502',
              hint = 'Choose a product on every line, or remove the line.';
    end if;
    v_qty := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    if v_qty = 0 then
      raise exception
        'CLOVEERP_ADJUSTMENT_LINE_NEEDS_A_CHANGE: line % changes nothing', v_no
        using errcode = '23514',
              hint = 'Put how many were found as a positive number and how many were missing as a negative one.';
    end if;

    -- No price. Nothing is being bought or sold; what the change is worth is
    -- whatever the costing store already says the stock is worth.
    v_line := erp.add_document_line(v_id, (ln ->> 'item_id')::uuid, v_qty, 0,
                                    nullif(ln ->> 'description', ''), null);

    if coalesce(ln ->> 'location_id', '') <> '' or coalesce(ln ->> 'batch_id', '') <> '' then
      update erp.document_line
         set location_id = coalesce(nullif(ln ->> 'location_id', '')::uuid, location_id),
             batch_id    = coalesce(nullif(ln ->> 'batch_id', '')::uuid, batch_id),
             updated_at  = now()
       where tenant_id = v_tenant and id = v_line;
    end if;

    v_added := v_added + 1;
  end loop;

  select * into d from erp.document where tenant_id = v_tenant and id = v_id;

  return jsonb_build_object(
    'document_id', v_id,
    'document_number', d.document_number,
    'site', s.code,
    'adjusted_on', v_on,
    'reason_code', d.attributes ->> 'reason_code',
    'lines', v_added,
    'state', erp.document_state_code(v_id));
end;
$$;

revoke all on function erp.raise_stock_adjustment(uuid, text, jsonb, date, text, text)
  from public, anon, authenticated;

comment on function erp.raise_stock_adjustment is
  'Opens a stock adjustment for a site, with its reason, its date and its '
  'lines, in one transaction. Quantities are signed: positive is stock found, '
  'negative is stock missing. Asks inventory.adjust, and finance.post as well '
  'when the date is earlier than today. Nothing moves until it is approved and '
  'posted.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Posting one
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.post_stock_adjustment(p_document_id uuid)
returns jsonb
language plpgsql
volatile
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
begin
  d := erp.adjustment_document(p_document_id);

  perform erp.authorise('inventory.adjust', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  v_on := coalesce(d.posting_date, d.document_date);

  if v_on > current_date then
    raise exception
      'CLOVEERP_ADJUSTMENT_IN_THE_FUTURE: % is dated %, which is after today',
      d.document_number, v_on
      using errcode = '22007',
            hint = 'Date the adjustment the day the count was taken, or leave it empty for today.';
  end if;

  -- Asked again here, and not only at the raise: the posting is where the
  -- ledger is written, and the document's date could have been changed between
  -- the two by anybody who may edit a draft.
  if v_on < current_date then
    perform erp.authorise('finance.post', d.entity_id, d.site_id, null,
                          'document', p_document_id);
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
  v_when := case when v_on >= current_date
                 then clock_timestamp()
                 else (v_on::timestamp + interval '12 hours') at time zone 'UTC'
            end;

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

      v_unit := erp.receive_cost(
                  ln.item_id, d.site_id, ln.quantity,
                  coalesce((select c.unit_cost_minor from erp.item_cost c
                             where c.tenant_id = v_tenant and c.item_id = ln.item_id
                               and c.site_id is not distinct from d.site_id), 0),
                  v_ccy, ln.batch_id, null);

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

      v_unit := erp.issue_cost(ln.item_id, d.site_id, -ln.quantity);

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

revoke all on function erp.post_stock_adjustment(uuid) from public, anon, authenticated;

comment on function erp.post_stock_adjustment is
  'Writes an approved stock adjustment into the stock ledger and the general '
  'ledger, both dated the day the adjustment says the fact was true. Stock '
  'found arrives at what the books already say it is worth; stock missing '
  'leaves at what it cost. Asks inventory.adjust, and finance.post as well for '
  'a date earlier than today; a closed period refuses it at the ledger.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. What a screen reads
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.stock_adjustments(p_limit integer default 100)
returns table (
  document_id     uuid,
  document_number text,
  state           text,
  site            text,
  adjusted_on     date,
  reason_code     text,
  reason_note     text,
  lines           integer,
  found           numeric,
  missing         numeric,
  cost_minor      bigint,
  currency        text
)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select d.id, d.document_number,
         erp.document_state_code(d.id),
         st.code,
         coalesce(d.posting_date, d.document_date),
         d.attributes ->> 'reason_code',
         d.attributes ->> 'reason_note',
         (select count(*)::integer from erp.document_line l
           where l.tenant_id = d.tenant_id and l.document_id = d.id
             and not l.is_cancelled and l.quantity <> 0),
         (select coalesce(sum(l.quantity) filter (where l.quantity > 0), 0)
            from erp.document_line l
           where l.tenant_id = d.tenant_id and l.document_id = d.id
             and not l.is_cancelled),
         (select coalesce(sum(-l.quantity) filter (where l.quantity < 0), 0)
            from erp.document_line l
           where l.tenant_id = d.tenant_id and l.document_id = d.id
             and not l.is_cancelled),
         -- What the adjustment put through the profit and loss: stock missing
         -- is a cost and reads positive, stock found is a cost unmade and
         -- reads negative, which is the way round the ledger has it.
         (select coalesce(sum(case when m.from_location_id is not null
                                   then coalesce(m.cost_minor, 0)
                                   else -coalesce(m.cost_minor, 0) end), 0)::bigint
            from erp.stock_movement m
           where m.tenant_id = d.tenant_id and m.document_id = d.id
             and not m.is_reversal),
         coalesce(d.currency, en.base_currency)::text
    from t
    join erp.document d on d.tenant_id = t.tenant_id
    join erp.entity en on en.tenant_id = d.tenant_id and en.id = d.entity_id
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.site st on st.tenant_id = d.tenant_id and st.id = d.site_id
   where dt.base_type_code = 'adjustment'
   order by coalesce(d.posting_date, d.document_date) desc, d.document_number desc
   limit greatest(coalesce(p_limit, 100), 1)
$$;

revoke all on function erp.stock_adjustments(integer) from public, anon, authenticated;

comment on function erp.stock_adjustments is
  'Every stock adjustment with the date it says the fact was true, its reason, '
  'how much was found and how much was missing, and what the change was worth '
  'on the books. Requires an organisation.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_raise_stock_adjustment(
  p_site_id     uuid,
  p_reason_code text,
  p_lines       jsonb default '[]'::jsonb,
  p_adjusted_on date default null,
  p_note        text default null,
  p_reference   text default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.raise_stock_adjustment(p_site_id, p_reason_code, p_lines,
                                    p_adjusted_on, p_note, p_reference)
$$;

revoke all on function public.erp_raise_stock_adjustment(uuid, text, jsonb, date, text, text)
  from public, anon;

comment on function public.erp_raise_stock_adjustment(uuid, text, jsonb, date, text, text) is
  'Raises a stock adjustment for a site with its reason, its date and its '
  'lines. Quantities are signed. Asks inventory.adjust, and finance.post as '
  'well for a date earlier than today. Runs as the caller.';

create or replace function public.erp_post_stock_adjustment(p_document_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.post_stock_adjustment(p_document_id)
$$;

revoke all on function public.erp_post_stock_adjustment(uuid) from public, anon;

comment on function public.erp_post_stock_adjustment(uuid) is
  'Writes an approved stock adjustment into both ledgers, dated the day it says '
  'the fact was true. Asks inventory.adjust, and finance.post as well for a '
  'date earlier than today. Runs as the caller.';

create or replace function public.erp_stock_adjustments(p_limit integer default 100)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
    from erp.stock_adjustments(p_limit) x
$$;

revoke all on function public.erp_stock_adjustments(integer) from public, anon;

comment on function public.erp_stock_adjustments(integer) is
  'Every stock adjustment with its date, its reason, what was found and missing '
  'and what the change was worth. Runs as the caller, so row security decides '
  'what is visible.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_raise_stock_adjustment', 'erp.raise_stock_adjustment',
   'Opens a stock adjustment and its lines under inventory.adjust, the permission '
   'the document type declares, and asks finance.post as well when the adjustment '
   'is dated before today — backdating a stock movement moves profit between '
   'periods, which is a ledger decision and not a warehouse one. It writes '
   'erp.document and erp.document_line only; no stock moves until it is approved '
   'and posted.'),
  ('erp_post_stock_adjustment', 'erp.post_stock_adjustment',
   'Writes an approved stock adjustment into erp.stock_movement and, through '
   'erp.post_movement_finance(), into the ledger — under inventory.adjust, and '
   'finance.post as well for a date earlier than today. Both are dated the day '
   'the adjustment says the fact was true, so a closed period refuses it at the '
   'ledger trigger below every door.')
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The generic stock bridge is held off for this base type
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Deployed body, asserted needle. erp.transition_document() has been patched
-- five times since the file that last defined it whole (20260904870000, in
-- upper case), the last of them 20260917130000, which is the line this one
-- extends. The finance arm needs no holding off: section 1 took
-- affects_finance off this base type, so erp.post_document_finance() is never
-- reached for an adjustment.

do $bridge$
declare
  v_def text := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  v_n   text := E'    if bt.affects_stock and dt.base_type_code <> ''transfer_order''\n';
  v_r   text := E'    -- A stock adjustment goes up on one line and down on the next, and\n'
             || E'    -- the movement type it names has direction ''transfer'', for which\n'
             || E'    -- erp.post_document_stock() writes from and to the same location and\n'
             || E'    -- moves nothing. It also posts at the FIRST committed state, which\n'
             || E'    -- for an adjustment is "approved" — before anybody has agreed the\n'
             || E'    -- stock really is what it says. erp.post_stock_adjustment() writes\n'
             || E'    -- the legs itself, on the document''s own date (20260918810000).\n'
             || E'    if bt.affects_stock and dt.base_type_code not in (''transfer_order'', ''adjustment'')\n';
  v_hits integer;
begin
  if position('''transfer_order'', ''adjustment''' in v_def) > 0 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: erp.transition_document() already '
      'holds the bridge off for the adjustment base type; this migration would do it twice';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: expected the stock bridge to hold off '
      'the transfer order once in erp.transition_document(), found %', v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  -- The five patches this body already carried are still in it. A re-emission
  -- from any file would have dropped every one of them.
  v_def := pg_get_functiondef('erp.transition_document(uuid,text,text)'::regprocedure);
  if position('erp.transition_declares_effect(' in v_def) = 0
     or position('erp.require_document_approval(' in v_def) = 0
     or position('erp.advance_orders_for_receipt(' in v_def) = 0
     or position('erp.advance_orders_for_delivery(' in v_def) = 0
     or position('''transfer_order'', ''adjustment''' in v_def) = 0 then
    raise exception
      'CLOVEERP_TRANSITION_BRIDGE_UNRECOGNISED: the rewrite dropped a patch the '
      'body already had, or did not take';
  end if;
end
$bridge$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. A new organisation installs it; an existing one upgrades to it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Deployed body, asserted needle. erp.configure_inventory() has been patched
-- four times since the file that last defined it whole (20260904160000, in
-- upper case), the last of them 20260917130000, whose appended expression this
-- one appends to in turn.

do $installer$
declare
  v_def text := pg_get_functiondef(
                  'erp.configure_inventory(erp.costing_method,text,numeric,numeric)'::regprocedure);
  v_n   text := E'    || erp.transfer_order_pack_items());';
  v_r   text := E'    || erp.transfer_order_pack_items()\n'
             || E'    || erp.stock_adjustment_pack_items());';
  v_hits integer;
begin
  if position('erp.stock_adjustment_pack_items()' in v_def) > 0 then
    raise exception
      'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: erp.configure_inventory() already '
      'installs a stock adjustment; this migration would install it twice';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: expected the transfer order pack to '
      'close the item array once in erp.configure_inventory(), found %', v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(
             'erp.configure_inventory(erp.costing_method,text,numeric,numeric)'::regprocedure);
  if position('erp.stock_adjustment_pack_items()' in v_def) = 0
     or position('erp.transfer_order_pack_items()' in v_def) = 0
     or position('stock.ownership_transferred' in v_def) = 0
     or position('stock.adjusted' in v_def) = 0
     or position('purchase_price_variance' in v_def) = 0 then
    raise exception
      'CLOVEERP_INVENTORY_INSTALLER_UNRECOGNISED: the rewrite dropped a patch the '
      'body already had, or did not take';
  end if;
end
$installer$;

-- ── The upgrade register, for organisations that already exist ──────────────

update erp_ref.module_installer
   set current_version = 5,
       description = 'Version 2 (20260906050000) added the stock adjustments account and the '
                     'stock_adjustment posting rule; version 3 (20260906143000) the '
                     'consignment_consumption rule; version 4 (20260917130000) the transfer '
                     'order — its lifecycle, its numbering rule and its document type — so '
                     'stock can move between two sites; version 5 (20260918810000) the stock '
                     'adjustment document, so a correction to the shelf carries its own date, '
                     'its reason and an approval.'
 where install_code = 'inventory-operations';

insert into erp_ref.module_upgrade_item
  (install_code, to_version, object_kind, object_key, payload, seq)
select 'inventory-operations', 5, x.value ->> 'kind', x.value ->> 'key',
       x.value -> 'payload', 160 + (x.ordinality::integer * 10)
  from jsonb_array_elements(erp.stock_adjustment_pack_items()) with ordinality x(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key) do update
  set payload = excluded.payload, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The demonstration keeps the reasons an adjustment may give
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Deployed body, asserted needle. 20260918220000 installed the two return
-- categories from erp_ref.reason_code, the catalogue the base content pack is
-- itself generated from; this widens that one statement rather than adding a
-- second, so the demonstration and the pack still cannot drift. The label the
-- arm reports moves with it, because "return reasons" would no longer say what
-- was installed.

do $reasons$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_def  text := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  v_n1   constant text := E'   where rc.category_code in (''RETURN_CUSTOMER'', ''RETURN_SUPPLIER'')\n';
  v_r1   constant text := E'   where rc.category_code in (''RETURN_CUSTOMER'', ''RETURN_SUPPLIER'', ''STOCK_ADJUSTMENT'')\n';
  v_n2   constant text := E'    v_did := v_did || ''"return reasons"''::jsonb;\n';
  v_r2   constant text := E'    v_did := v_did || ''"reason codes"''::jsonb;\n';
  v_hits integer;
begin
  if position('STOCK_ADJUSTMENT' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % already keeps adjustment reasons; this migration would keep them twice', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: expected the return categories to be named once in %, found %',
      v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: expected the reason register to be reported once in %, found %',
      v_sig, v_hits;
  end if;

  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);

  -- What the body already carried is still in it, and the register took.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('STOCK_ADJUSTMENT' in v_def) = 0
     or position('"reason codes"' in v_def) = 0
     or position('RETURN_SUPPLIER' in v_def) = 0
     or position('''MAIN-WH'', ''Main warehouse''' in v_def) = 0
     or position('chart_8_1' in v_def) = 0                                   -- 20260905020000
     or position('renamed ACME' in v_def) = 0                                -- 20260905030000
     or position('"inventory upgraded"' in v_def) = 0                        -- 20260906141000
     or position('"procurement controls"' in v_def) = 0                      -- 20260909212619
     or position('erp.seed_demo_item_suppliers(p_tenant_id)' in v_def) = 0   -- 20260914076000
     or position('erp.configure_tax(''GB'', 20)' in v_def) = 0               -- 20260916030000
     or position('entity_tax_registration' in v_def) = 0                     -- 20260916090000
     or position('"site transfers"' in v_def) = 0                            -- 20260917130000
     or position('''NORTH-DC'', ''Northern distribution centre''' in v_def) = 0  -- 20260918100000
     or position('"customer credit note"' in v_def) = 0                      -- 20260918170000
     or position('"supplier credit note"' in v_def) = 0 then                 -- 20260918170000
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % dropped a patch it already had, or did not take its adjustment reasons', v_sig;
  end if;
end
$reasons$;

comment on function erp.ensure_demo_configuration(uuid, uuid) is
  'Takes a demonstration organisation from provisioned to able to trade, once: '
  'sandbox, the installers, four years of periods, posting rules in force '
  'from two years back, numbering without the year, two sites of the trading '
  'company — a main warehouse and a distribution centre, each with its '
  'locations — the reasons a return and an adjustment may give, and master '
  'data to trade with. Idempotent; refused in a live environment.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 11. Every Saturday the warehouse counts
-- ═════════════════════════════════════════════════════════════════════════════

do $history$
declare
  v_sig  constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def  text := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  -- The end of the day, after every weekday block. What is built last in a day
  -- is built from what the day left on the shelf.
  v_n    constant text := E'  end loop days;\n';
  v_r    constant text := $r$  -- ── The weekend count ────────────────────────────────────────────────────
  -- Every Saturday the warehouse counts the product its bulk store holds most
  -- of and finds it one short (20260918810000). Raised through
  -- erp.raise_stock_adjustment() under COUNT_VARIANCE, dated that Saturday,
  -- approved and posted through erp.post_stock_adjustment(), so the movement
  -- and its journal both carry the day the count was taken.
  --
  -- Saturday, because a warehouse counts when nothing is moving and because it
  -- shares a day with nothing: the Monday receipt, the Tuesday return, the
  -- Wednesday lorry, the Thursday bill and part delivery and the Friday credit
  -- note are all weekdays. One unit, because the Tuesday return and the
  -- Wednesday lorry both size themselves against this shelf as a floor over a
  -- balance in the hundreds, and one unit cannot turn either into nothing.
  -- Nothing here draws on random(), so the rest of the day is what it was.
  if extract(isodow from v_day) = 6 then
    declare
      v_short  uuid;
      v_adj    uuid;
    begin
      select i.id into v_short
        from erp.item i
       cross join lateral (
         select coalesce(sum(b.quantity), 0) as on_hand
           from erp.stock_balance b
          where b.tenant_id = v_tenant and b.site_id = v_site
            and b.location_id = v_bulk and b.item_id = i.id
            and b.batch_id is null and b.serial_id is null and b.container_id is null
            and b.stock_status = 'available'::erp.stock_status) sb
       where v_bulk is not null
         and i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
         and i.attributes ? 'demo'
         and sb.on_hand >= 10
       order by sb.on_hand desc, i.code
       limit 1;

      if v_short is not null then
        v_seq := v_seq + 1;
        v_adj := (erp.raise_stock_adjustment(
                    v_site, 'COUNT_VARIANCE',
                    jsonb_build_array(jsonb_build_object(
                      'item_id', v_short, 'quantity', -1, 'location_id', v_bulk)),
                    v_day, 'One short on the weekend count',
                    v_prefix || lpad(v_seq::text, 3, '0'))
                   ->> 'document_id')::uuid;
        perform erp.transition_document(v_adj, 'approve', 'demonstration');
        perform erp.post_stock_adjustment(v_adj);
        v_built := v_built + 1;
      end if;
    end;
  end if;

  end loop days;
$r$;
  v_hits integer;
  v_secdef boolean;
begin
  if position('erp.raise_stock_adjustment(' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % already adjusts stock; this migration would adjust it twice', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: expected the day to end once in %, found %', v_sig, v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  -- What the body already carried is still in it, and the count took.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  select p.prosecdef into v_secdef from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure;
  if position('erp.post_stock_adjustment(v_adj)' in v_def) = 0
     or position('0.92 + random()::numeric * 0.16' in v_def) = 0                         -- 20260906050000
     or position('Close only what actually arrived in Received.' in v_def) = 0           -- 20260912190000
     or (length(v_def) - length(replace(v_def, 'erp.approve_my_document_tasks(v_doc, ''demonstration'')', '')))
        / length('erp.approve_my_document_tasks(v_doc, ''demonstration'')') <> 2         -- 20260914062000
     or position('<<days>>' in v_def) = 0                                                -- 20260914072000
     or position('erp.receive_transfer(v_transfer)' in v_def) = 0                        -- 20260918100000
     or position('erp.raise_supplier_credit_note(' in v_def) = 0                         -- 20260918220000
     or position('erp.raise_customer_credit_note(' in v_def) = 0                         -- 20260918220000
     or position('erp.create_receipt_from_order(' in v_def) = 0                          -- 20260918600000
     or position('erp.invoice_against(' in v_def) = 0                                    -- 20260918600000
     or position('erp.create_delivery_from_order(' in v_def) = 0                         -- 20260918600000
     or (length(v_def) - length(replace(v_def, E'  end loop days;\n', ''))) / length(E'  end loop days;\n') <> 1
     or not coalesce(v_secdef, false) then                                               -- 20260914030000
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % dropped a patch it already had, or did not take its weekend count', v_sig;
  end if;
end
$history$;

comment on function erp.seed_demo_history(date, date, numeric) is
  'Builds demonstration trading one day at a time through the spine — purchase '
  'orders and receipts, sales orders, despatches, invoices and cash, quotations, '
  'requisitions, every Monday a delivery that arrives short, every Tuesday a '
  'return to a supplier, every Wednesday a transfer from the main warehouse to '
  'the company''s other site, every Thursday a supplier''s bill above the order '
  'and a customer''s order delivered in part, every Friday a credit note to '
  'a customer and every Saturday a weekend count that writes one unit off — at '
  'most five days per call, starting no new day once a quarter of the caller''s '
  'statement timeout has gone, and says where the next call should start. A day '
  'already built, or inside a five-day slice built before, is skipped; refused '
  'in a live environment; every journal and movement is raised by the same '
  'bridges and doors a person''s document goes through.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 12. What is refused, and what to do about it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_NOT_A_STOCK_ADJUSTMENT',
  'Posting something that is not a stock adjustment as one.',
  'Only a stock adjustment changes what the system says is on a shelf without anything arriving or leaving. Every other document moves stock because goods actually went somewhere, and posts through the ordinary bridge.',
  'Open a stock adjustment on the Stock adjustments screen, or post the document you actually mean from its own screen.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_IN_THE_FUTURE',
  'Dating a stock adjustment after today.',
  'An adjustment states a fact about a shelf on a day. Stock that will be missing next week is a forecast, and a forecast written into the stock ledger and the accounts is a figure that the count on the day would then have to explain away.',
  'Date the adjustment the day the count was taken, or leave the date empty and today is used.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_NEEDS_A_REASON',
  'Adjusting stock without saying why it changed.',
  'Stock does not change by itself. An adjustment nobody explained cannot be analysed, and analysing them is the only way the number of them ever goes down: damage in storage, theft, a sample taken and a measure correction are four different problems with four different answers.',
  'Pick a reason from the register on the Stock adjustments screen — the reasons an organisation keeps are set on the Configuration screen.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_LINE_NEEDS_A_CHANGE',
  'A stock adjustment line that changes nothing.',
  'A line for nought units names a product and says nothing about it. It is a line somebody began and did not finish, and posting it would write a movement of no quantity into the stock ledger.',
  'Put how many were found as a positive number and how many were missing as a negative one, or take the line off.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_HAS_NO_LINES',
  'Posting a stock adjustment with nothing on it.',
  'An adjustment with no lines names no product and no quantity, so there is nothing for the stock ledger to record and nothing for the accounts to carry.',
  'Add a line saying which product and by how much, then post it.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_NOT_APPROVED',
  'Posting a stock adjustment nobody has approved.',
  'The approval is the whole control on a write-off. Anybody who can post an adjustment unapproved can make stock disappear off the books for any reason they care to type, and a backdated one moves profit between months while they do it.',
  'Have the adjustment approved first; it stays a draft, changing nothing, until somebody does.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_ALREADY_POSTED',
  'Posting a stock adjustment whose change has already been written.',
  'The stock ledger is append-only, so a second posting would take the same units off the shelf twice and put the same cost through the accounts twice, leaving the site short by the whole adjustment.',
  'Raise a new adjustment for a further correction. The first one stands as the record of what was found when.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_HAS_NO_PLACE',
  'Adjusting stock at a site with nowhere for it to be found or lost from.',
  'A movement names where the stock came from or went to. With no location on the line and no place at the site that can hold what the adjustment describes, there is no answer to give.',
  'Give the line a location, or add a goods-in place and a storage place to the site on the Warehouse layout screen.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 13. The words on the screen
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string on Stock adjustments, rendered through ui(). ' || v.why
  from (values
    ('Stock adjustments',
     'The screen where the system is made to agree with the shelf.'),
    ('Making the system agree with the shelf. An adjustment carries the date the count was taken, the reason it changed, and an approval before anything is written — and its cost reaches the stock adjustments account in your profit and loss on that date, not on the day it was keyed in.',
     'Said under the heading, because the date being the count''s rather than today''s is the whole point of the screen.'),
    ('Raise and post an adjustment',
     'The card holding the two steps of an adjustment.'),
    ('An adjustment is approved before anything is written, because a write-off nobody agreed to is stock disappearing off the books. Dating one before today needs the permission to post to the ledger as well, and a closed period refuses it outright.',
     'Said under that card, because both controls are ones people meet rather than read about.'),
    ('Raise a stock adjustment',
     'The button that opens an adjustment.'),
    ('Say what the stock really is',
     'The dialog heading for raising an adjustment.'),
    ('Nothing changes yet: the adjustment is a draft until it is approved and posted. Quantities are what you found, not what you want to change by — put stock found as a positive number and stock missing as a negative one.',
     'Said under that dialog, because the sign is the one thing people get wrong.'),
    ('Which shelf',
     'The site the adjustment is about.'),
    ('The site whose stock the count was taken at.',
     'Said under that site.'),
    ('Why it changed',
     'The reason code on the adjustment.'),
    ('Pick a reason from the register, or type one of your own. Some reasons are set up to need a note beside them.',
     'Said under that reason, because which ones need a note is an organisation''s own choice.'),
    ('Say what happened, in a sentence. Some reasons are set up to require this.',
     'Said under that note.'),
    ('What the count found',
     'The grid of products and quantities on an adjustment.'),
    ('One row per product. Positive for stock found, negative for stock missing. No prices: what the change is worth is whatever the books already say the stock is worth.',
     'Said under that grid, because people expect to be asked for a value and there is not one.'),
    ('When the count was taken',
     'The date the adjustment says the fact was true.'),
    ('The day the fact was true, which is not always today. A date before today needs the permission to post to the ledger, because it moves cost between months; a closed month refuses it; and a date after today is refused outright.',
     'Said under that date, because it is the field this screen exists for.'),
    ('Post a stock adjustment',
     'The button that writes an approved adjustment into both ledgers.'),
    ('Write the count into the books',
     'The dialog heading for posting an adjustment.'),
    ('Moves the stock and posts the cost to the stock adjustments account, both dated the day the count was taken. What the stock is worth is taken from the books as they stand now: an adjustment dated in the past does not change what earlier despatches were valued at, and no ERP can, because what a despatch took out of stock was recorded once and the layers are gone.',
     'Said under that dialog, because a backdated adjustment not rewinding the valuation is a real limitation and is better read before than discovered after.'),
    ('Stock adjustment',
     'The adjustment a step is being taken on.'),
    ('Every adjustment with the day the count was taken, its reason, what was found and what was missing, and what the change was worth on the books.',
     'Said under the table.'),
    ('No adjustments yet. Raise one above when a count finds the shelf and the system disagreeing.',
     'Said when there are none, because an empty table is otherwise indistinguishable from a broken one.'),
    ('Found',
     'How many units the count found more of.'),
    ('Worth',
     'What the change was worth, in money.'),
    ('Corrections to what the system says is on the shelf: a count variance, damage, theft or a sample, each carrying the day it was found, a reason and an approval.',
     'The tile''s own sentence on the launchpad.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- The tile's label and its guidance. A tile with no help topic ships with a
-- help button saying there is no guidance for this screen, and
-- src/lib/guidance.test.ts fails for it before that can happen.

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.inventory_adjustments', 'en', 'Stock adjustments', 'inventory',
   'Navigation label for the stock screen that makes the system agree with the shelf.')
on conflict (key, locale) do nothing;

insert into erp_ref.help_topic
  (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/inventory/adjustments', 'nav.inventory_adjustments', 'inventory',
   'Making the system agree with the shelf, on the day the count was taken. An adjustment carries its own date, a reason from your register, and an approval before anything is written; the stock moves and the cost reaches the stock adjustments account in your profit and loss, both dated that day.',
   '["Raise an adjustment naming the site, why the stock changed, and the day the count was taken. Quantities are signed: positive for stock found, negative for stock missing.","Have it approved. Nothing is written until somebody does, because a write-off nobody agreed to is stock disappearing off the books.","Post it. The stock moves and the cost posts to stock adjustments, both dated the day of the count rather than the day you keyed it in.","Dating one before today also needs the permission to post to the ledger, because it moves cost between months, and a closed month refuses it outright."]',
   'Look at the stock adjustments account in your profit and loss for the month the count was taken: the write-off is in that month, not in this one.',
   '{erp_raise_stock_adjustment,erp_post_stock_adjustment,erp_stock_adjustments}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;

-- ═════════════════════════════════════════════════════════════════════════════
-- 14. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Its own organisation, its own site and its own products. A suite that leans
-- on seeded data proves the seed as much as the mechanism.

create or replace function erp_test.stock_adjustment_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 13;
  v_cases   integer := 0;
  v_step    text := 'before the fixture started';
  v_state   text;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_ccy char(3);
  v_site    uuid; v_bulk uuid; v_recv uuid;
  v_uom     uuid; v_item uuid; v_fifo uuid; v_found uuid;
  v_adj     uuid; v_res jsonb; v_planned integer;
  v_role    uuid; v_principal uuid;
  v_when    date;
  v_qty     numeric; v_n integer;
  v_mv_at   timestamptz; v_jr_on date; v_adj_minor bigint; v_inv_minor bigint;
  v_issue   bigint; v_write bigint; v_val bigint; v_ledger bigint;
  v_period  uuid; v_was text;
  v_ok      boolean; v_msg text; v_tie text;
begin
  begin
  v_step := 'provisioning the organisation';
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-stock-adjust', 'Stock adjustment suite',
                              'admin@zz-stock-adjust.test', 'Stock Adjustment Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000e1', 'admin@zz-stock-adjust.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000e1')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.base_currency into v_entity, v_ccy
    from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;

  -- ── 1. An organisation that already exists takes it from the register ────
  v_step := 'taking the document type from the upgrade register';
  v_cases := v_cases + 1;
  delete from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.code = 'stock_adjustment';
  update erp.module_installation i set installer_version = 4
   where i.tenant_id = v_tenant and i.install_code = 'inventory-operations';

  select count(*) into v_planned
    from erp.plan_module_upgrade('inventory-operations') p
   where p.object_kind = 'document_type' and p.object_key = 'stock_adjustment';
  perform erp.upgrade_module_configuration('inventory-operations');

  case_name := 'an organisation that already exists takes the stock adjustment from the upgrade register';
  passed := v_planned = 1
        and exists (select 1 from erp.document_type dt
                     where dt.tenant_id = v_tenant and dt.code = 'stock_adjustment'
                       and dt.base_type_code = 'adjustment'
                       and dt.state_machine_code = 'stock_adjustment'
                       and dt.stock_movement_type = 'count_adjustment'
                       and dt.numbering_rule_id is not null)
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 5;
  detail := format('%s document type(s) planned, organisation now at version %s',
                   v_planned,
                   (select i.installer_version from erp.module_installation i
                     where i.tenant_id = v_tenant and i.install_code = 'inventory-operations'));
  return next;

  -- A site of this company, its places, and a product with a hundred on hand.
  v_step := 'building the site and the stock';
  insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
  values (v_tenant, v_entity, 'ZZ-ADJ', 'Adjustment depot', 'warehouse'::erp.site_type,
          'GB', 'active'::erp.record_status)
  returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, v_site, 'ZZ-ADJ-BULK', 'Adjustment bulk', 'bulk'::erp.location_type,
          true, 'active'::erp.record_status)
  returning id into v_bulk;
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
  values (v_tenant, v_site, 'ZZ-ADJ-IN', 'Adjustment goods in', 'receiving'::erp.location_type,
          false, 'active'::erp.record_status)
  returning id into v_recv;

  select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;

  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'ZZ-ADJ-1', 'Countable widget', v_uom, 'active'::erp.record_status)
  returning id into v_item;

  -- A hundred at 500 a unit, arriving as a valued receipt so the costing store
  -- has something to take from. No document: this is the opening position.
  perform erp.receive_cost(v_item, v_site, 100, 500, v_ccy);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
    quantity, uom_id, unit_cost_minor, currency, reason_code)
  values (v_tenant, v_entity, v_site, 'receipt_no_order', v_item, v_bulk,
          'available'::erp.stock_status, 100, v_uom, 500, v_ccy, 'OPENING');

  -- ── 2. An adjustment is raised with a reason and a date ──────────────────
  v_step := 'raising a backdated adjustment';
  v_cases := v_cases + 1;
  v_when := current_date - 20;
  v_res := erp.raise_stock_adjustment(
             v_site, 'DAMAGE_STORAGE',
             jsonb_build_array(jsonb_build_object(
               'item_id', v_item, 'quantity', -10, 'location_id', v_bulk)),
             v_when, 'A pallet went over in the racking', 'ZZ-COUNT-1');
  v_adj := (v_res ->> 'document_id')::uuid;
  case_name := 'an adjustment carries its own date, its reason and its lines, and starts in draft';
  passed := v_adj is not null
        and (v_res ->> 'adjusted_on')::date = v_when
        and (v_res ->> 'reason_code') = 'DAMAGE_STORAGE'
        and (v_res ->> 'lines')::integer = 1
        and (v_res ->> 'state') = 'draft'
        and (select d.document_date from erp.document d where d.id = v_adj) = v_when
        and (select d.posting_date from erp.document d where d.id = v_adj) = v_when;
  detail := format('%s dated %s, reason %s, %s line(s), %s',
                   v_res ->> 'document_number', v_res ->> 'adjusted_on',
                   v_res ->> 'reason_code', v_res ->> 'lines', v_res ->> 'state');
  return next;

  -- ── 3. Approving moves nothing ───────────────────────────────────────────
  --
  -- Approved is a stock adjustment's FIRST COMMITTED state, which is where
  -- erp.transition_document() posts the stock side of every other document
  -- that moves stock. Read after the transition, because reading before it
  -- would prove nothing about it.
  v_step := 'approving the adjustment';
  v_cases := v_cases + 1;
  perform erp.transition_document(v_adj, 'approve', 'suite');
  select coalesce(sum(b.quantity), 0) into v_qty
    from erp.stock_balance b where b.tenant_id = v_tenant and b.site_id = v_site;
  case_name := 'approving writes nothing: the generic posting bridge is held off at the first committed state';
  passed := v_qty = 100
        and not exists (select 1 from erp.stock_movement m
                         where m.tenant_id = v_tenant and m.document_id = v_adj)
        -- An adjustment's journal carries no document, so the absence is read
        -- where it would actually appear: no journal of this source at all.
        and not exists (select 1 from erp.journal j
                         where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted')
        and erp.document_state_code(v_adj) = 'approved';
  detail := format('%s on hand, %s movement(s) against it, %s stock journal(s) in the organisation',
                   v_qty,
                   (select count(*) from erp.stock_movement m
                     where m.tenant_id = v_tenant and m.document_id = v_adj),
                   (select count(*) from erp.journal j
                     where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted'));
  return next;

  -- ── 4. Posted: the movement and the journal both carry the date ──────────
  v_step := 'posting the backdated adjustment';
  v_cases := v_cases + 1;
  v_res := erp.post_stock_adjustment(v_adj);
  select m.occurred_at into v_mv_at
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.document_id = v_adj and not m.is_reversal
   order by m.id limit 1;
  -- The first and, at this point, the only journal the organisation's stock
  -- adjustments have raised.
  select j.posting_date into v_jr_on
    from erp.journal j
   where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted'
     and j.status = 'posted'
   order by j.posted_at desc limit 1;
  select coalesce(sum(b.quantity), 0) into v_qty
    from erp.stock_balance b where b.tenant_id = v_tenant and b.site_id = v_site;
  case_name := 'a stock adjustment dated twenty days ago writes a movement AND a journal both dated that day, and ten units leave the shelf';
  passed := v_mv_at::date = v_when
        and v_jr_on = v_when
        and v_qty = 90
        and (v_res ->> 'state') = 'posted'
        and (v_res ->> 'missing')::numeric = 10
        and (v_res ->> 'journals')::integer = 1;
  detail := format('movement at %s, journal on %s, %s on hand, %s',
                   v_mv_at, v_jr_on, v_qty, v_res ->> 'state');
  return next;

  -- ── 5. The write-off reaches the stock adjustments account ───────────────
  v_step := 'reading the stock adjustments account';
  v_cases := v_cases + 1;
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_adj_minor
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
   where j.tenant_id = v_tenant and j.status = 'posted'
     and a.code = erp.tenant_account_code('stock_adjustment');
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_inv_minor
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
   where j.tenant_id = v_tenant and j.status = 'posted'
     and a.code = erp.tenant_account_code('inventory');
  case_name := 'the write-off is a cost: 5000 on the stock adjustments account in the profit and loss, 5000 off inventory, at what the stock cost';
  passed := v_adj_minor = 5000 and v_inv_minor = -5000
        and (v_res ->> 'cost_minor')::bigint = 5000;
  detail := format('stock adjustments %s, inventory %s, the posting said %s',
                   v_adj_minor, v_inv_minor, v_res ->> 'cost_minor');
  return next;

  -- ── 6. The movement carries its reason ───────────────────────────────────
  v_step := 'reading the reason off the movement';
  v_cases := v_cases + 1;
  case_name := 'the movement carries the reason the adjustment gave, which is what a movement type that requires one is for';
  passed := exists (select 1 from erp.stock_movement m
                     where m.tenant_id = v_tenant and m.document_id = v_adj
                       and m.reason_code = 'DAMAGE_STORAGE'
                       and m.movement_type = 'count_adjustment'
                       and m.document_line_id is not null);
  detail := coalesce((select format('%s on a %s movement', m.reason_code, m.movement_type)
                        from erp.stock_movement m
                       where m.tenant_id = v_tenant and m.document_id = v_adj limit 1),
                     'no movement at all');
  return next;

  -- ── 7. Stock found goes the other way ────────────────────────────────────
  v_step := 'adjusting stock upwards';
  v_cases := v_cases + 1;
  v_res := erp.raise_stock_adjustment(
             v_site, 'FOUND',
             jsonb_build_array(jsonb_build_object(
               'item_id', v_item, 'quantity', 4, 'location_id', v_bulk)),
             v_when + 1, 'Four turned up behind the racking', 'ZZ-COUNT-2');
  v_found := (v_res ->> 'document_id')::uuid;
  perform erp.transition_document(v_found, 'approve', 'suite');
  v_res := erp.post_stock_adjustment(v_found);
  select coalesce(sum(b.quantity), 0) into v_qty
    from erp.stock_balance b where b.tenant_id = v_tenant and b.site_id = v_site;
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_inv_minor
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
   where j.tenant_id = v_tenant and j.status = 'posted'
     and a.code = erp.tenant_account_code('inventory');
  case_name := 'stock found goes the other way: four back on the shelf, 2000 back on to inventory, and the cost account credited';
  passed := v_qty = 94
        and (v_res ->> 'found')::numeric = 4
        and v_inv_minor = -3000
        and (select coalesce(sum(m.quantity), 0) from erp.stock_movement m
              where m.tenant_id = v_tenant and m.document_id = v_found
                and m.to_location_id is not null) = 4;
  detail := format('%s on hand, inventory now %s, found %s',
                   v_qty, v_inv_minor, v_res ->> 'found');
  return next;

  -- ── 8. Backdated behind a later issue ────────────────────────────────────
  --
  -- The decision this migration argues, proved arithmetically. Thirty at 20
  -- and ten at 60, kept in layers. An issue of thirty takes the older layer,
  -- 600. A write-off of five backdated BEFORE that issue then takes five of
  -- the ten at 60, 300, where a true rewind would have taken 100 and left the
  -- issue costing 800. 600 + 300 = 900 and 100 + 800 = 900: the same figure
  -- has left the stock ledger, so the valuation and the inventory account
  -- still agree. What moved is which date and which account carried it.
  v_step := 'backdating an adjustment behind a later issue';
  v_cases := v_cases + 1;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (v_tenant, 'ZZ-ADJ-2', 'Layered widget', v_uom, 'active'::erp.record_status)
  returning id into v_fifo;
  insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
  values (v_tenant, 'zz_adj_fifo', 'Layered widget in layers', 'fifo'::erp.costing_method,
          v_fifo, 'active'::erp.record_status);

  perform erp.receive_cost(v_fifo, v_site, 30, 20, v_ccy);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
    quantity, uom_id, unit_cost_minor, currency, reason_code)
  values (v_tenant, v_entity, v_site, 'receipt_no_order', v_fifo, v_bulk,
          'available'::erp.stock_status, 30, v_uom, 20, v_ccy, 'OPENING');
  perform erp.receive_cost(v_fifo, v_site, 10, 60, v_ccy);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, to_location_id, to_status,
    quantity, uom_id, unit_cost_minor, currency, reason_code)
  values (v_tenant, v_entity, v_site, 'receipt_no_order', v_fifo, v_bulk,
          'available'::erp.stock_status, 10, v_uom, 60, v_ccy, 'OPENING');

  -- The later issue, five days ago, at what FIFO says it took: the older 30.
  v_issue := erp.issue_cost(v_fifo, v_site, 30);
  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, from_location_id, from_status,
    quantity, uom_id, unit_cost_minor, currency, reason_code, occurred_at)
  values (v_tenant, v_entity, v_site, 'emergency_issue', v_fifo, v_bulk,
          'available'::erp.stock_status, 30, v_uom, v_issue, v_ccy, 'SUITE',
          (current_date - 5)::timestamp at time zone 'UTC')
  returning cost_minor into v_issue;

  v_res := erp.raise_stock_adjustment(
             v_site, 'COUNT_VARIANCE',
             jsonb_build_array(jsonb_build_object(
               'item_id', v_fifo, 'quantity', -5, 'location_id', v_bulk)),
             current_date - 10, 'Counted short ten days ago', 'ZZ-COUNT-3');
  v_adj := (v_res ->> 'document_id')::uuid;
  perform erp.transition_document(v_adj, 'approve', 'suite');
  v_res := erp.post_stock_adjustment(v_adj);
  v_write := (v_res ->> 'cost_minor')::bigint;
  select m.occurred_at into v_mv_at
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.document_id = v_adj and not m.is_reversal
   order by m.id limit 1;

  case_name := 'an adjustment backdated behind a later issue leaves that issue''s cost alone and takes what is on the shelf now: 600 then 300, which is the 100 and 800 a rewind would have given, to the penny';
  passed := v_issue = 600
        and v_write = 300
        and v_issue + v_write = 900
        and v_mv_at::date = current_date - 10
        and (select coalesce(sum(l.remaining * l.unit_cost_minor), 0)::bigint
               from erp.stock_valuation_layer l
              where l.tenant_id = v_tenant and l.item_id = v_fifo) = 300;
  detail := format('the issue cost %s, the backdated write-off %s, %s left in layers, movement dated %s',
                   v_issue, v_write,
                   (select coalesce(sum(l.remaining * l.unit_cost_minor), 0)::bigint
                      from erp.stock_valuation_layer l
                     where l.tenant_id = v_tenant and l.item_id = v_fifo),
                   v_mv_at::date);
  return next;

  -- ── 9. A closed period refuses it ────────────────────────────────────────
  --
  -- Below every door: erp.post_movement_finance() dates the journal on the
  -- movement, and erp.check_period_open() refuses a journal in a closed
  -- period. A dated adjustment is not a way round the close.
  v_step := 'closing a period and adjusting into it';
  v_cases := v_cases + 1;
  select fp.id, fp.status::text into v_period, v_was
    from erp.fiscal_period fp
    join erp.ledger l on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
   where fp.tenant_id = v_tenant and l.is_primary
     and (current_date - 40) between fp.starts_on and fp.ends_on
   limit 1;
  update erp.fiscal_period set status = 'closed', closed_at = clock_timestamp()
   where tenant_id = v_tenant and id = v_period;

  v_res := erp.raise_stock_adjustment(
             v_site, 'COUNT_VARIANCE',
             jsonb_build_array(jsonb_build_object(
               'item_id', v_item, 'quantity', -1, 'location_id', v_bulk)),
             current_date - 40, 'Counted short in a month that is shut', 'ZZ-COUNT-4');
  v_adj := (v_res ->> 'document_id')::uuid;
  perform erp.transition_document(v_adj, 'approve', 'suite');
  begin
    perform erp.post_stock_adjustment(v_adj);
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_PERIOD_CLOSED%';
    v_msg := left(sqlerrm, 90);
  end;
  update erp.fiscal_period set status = v_was::erp.period_status, closed_at = null
   where tenant_id = v_tenant and id = v_period;
  case_name := 'a closed period refuses a backdated adjustment at the ledger, below the doors, so a date is not a way round the close';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 10. Tomorrow is refused ──────────────────────────────────────────────
  v_step := 'dating an adjustment in the future';
  v_cases := v_cases + 1;
  begin
    perform erp.raise_stock_adjustment(
              v_site, 'COUNT_VARIANCE',
              jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1)),
              current_date + 1, 'Stock that will be missing tomorrow', 'ZZ-COUNT-5');
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_ADJUSTMENT_IN_THE_FUTURE%';
    v_msg := left(sqlerrm, 90);
  end;
  case_name := 'an adjustment dated after today is refused: stock that will be missing next week is a forecast';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 11. A warehouse may count today and not last month ───────────────────
  --
  -- The control, on the permission model rather than a second one of its own.
  -- A principal holding inventory.adjust and not finance.post adjusts today
  -- and is refused a date before today.
  v_step := 'a principal who may adjust but may not post to the ledger';
  v_cases := v_cases + 1;
  insert into erp.role (tenant_id, code, name, status)
  values (v_tenant, 'zz_counter', 'Stock counter', 'active'::erp.record_status)
  returning id into v_role;
  insert into erp.role_permission (tenant_id, role_id, permission_code)
  values (v_tenant, v_role, 'inventory.adjust'), (v_tenant, v_role, 'inventory.read');
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000e2', 'counter@zz-stock-adjust.test');
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant, '00000000-0000-4000-8000-0000000000e2', 'person'::erp.principal_kind,
          'active'::erp.principal_status, 'Stock Counter', 'counter@zz-stock-adjust.test')
  returning id into v_principal;
  insert into erp.user_role (tenant_id, app_user_id, role_id)
  values (v_tenant, v_principal, v_role);

  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000e2')::text, true);
  begin
    perform erp.raise_stock_adjustment(
              v_site, 'COUNT_VARIANCE',
              jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1,
                                                   'location_id', v_bulk)),
              null, 'Counted short this morning', 'ZZ-COUNT-6');
    v_ok := true; v_msg := 'today was allowed';
  exception when others then
    v_ok := false; v_msg := 'today was refused: ' || left(sqlerrm, 70);
  end;
  begin
    perform erp.raise_stock_adjustment(
              v_site, 'COUNT_VARIANCE',
              jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1,
                                                   'location_id', v_bulk)),
              current_date - 30, 'Counted short last month', 'ZZ-COUNT-7');
    v_ok := false; v_msg := v_msg || '; last month was allowed too';
  exception when others then
    v_ok := v_ok and sqlerrm like 'CLOVEERP_%';
    v_msg := v_msg || '; last month refused with ' || split_part(left(sqlerrm, 60), ':', 1);
  end;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000e1')::text, true);
  case_name := 'somebody who may adjust stock and may not post to the ledger counts today and cannot backdate: the control is the permission model, not a second one';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 12. The four ties hold with all of it in the books ───────────────────
  v_step := 'reading the ties';
  v_cases := v_cases + 1;
  select coalesce(sum(v.value_minor), 0)::bigint into v_val
    from erp.stock_valuation_report() v;
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_ledger
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
   where j.tenant_id = v_tenant and j.status = 'posted'
     and a.code = erp.tenant_account_code('inventory');
  begin
    v_tie := erp.assert_trial_balance_balances() || '; ' || erp.assert_stock_reconciles();
    v_ok := true;
  exception when others then
    v_ok := false; v_tie := left(sqlerrm, 200);
  end;
  case_name := 'the trial balance balances and the stock ledger reconciles with a backdated write-off, a stock find and a layered product in the books';
  passed := v_ok;
  detail := format('%s; valuation %s against inventory %s', v_tie, v_val, v_ledger);
  return next;

  perform set_config('request.jwt.claims', '', true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 13. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant where code = 'zz-stock-adjust')
        and not exists (select 1 from auth.users
                         where id in ('00000000-0000-4000-8000-0000000000e1',
                                      '00000000-0000-4000-8000-0000000000e2'));
  detail := coalesce(v_state,
                     'zz-stock-adjust rolled back with its depot, its adjustments and its ledger');
  return next;

  -- The count guard says what stopped the fixture, so the message this suite
  -- caught — and the step that produced it — reaches the build log.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: stock_adjustment_suite ran % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.stock_adjustment_suite() from public, anon;

comment on function erp_test.stock_adjustment_suite() is
  'A stock adjustment that carries its own date, proved and falsified. Taken '
  'from the upgrade register by an organisation that already exists; raised '
  'with a reason and a date; approving it writes nothing, which is where the '
  'generic bridge would have posted; posting it backdated dates the movement '
  'AND the journal that day and puts the cost on the stock adjustments '
  'account; the movement carries its reason; stock found goes the other way; a '
  'backdated adjustment behind a later issue leaves that issue''s cost alone '
  'and the total that has left is the same figure either way; a closed period '
  'refuses it; tomorrow is refused; and somebody who may adjust but may not '
  'post to the ledger counts today and cannot backdate. Rolls back everything '
  'it made.';

create or replace function erp_test.assert_stock_adjustment_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 13;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _stock_adjustment on commit drop as
    select * from erp_test.stock_adjustment_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _stock_adjustment;
  drop table _stock_adjustment;
  if v_fail > 0 then
    raise exception E'CLOVEERP_STOCK_ADJUSTMENT_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: stock_adjustment_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('an adjustment carries its date: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_stock_adjustment_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 15. The month adjusts stock
-- ═════════════════════════════════════════════════════════════════════════════
--
-- One case, needled on to the deployed body: 20260914062000 put
-- erp_test.approve_document() into it, 20260918220000 the credit notes and the
-- fifteen days, and 20260918600000 the part receipt, the bill and the part
-- delivery. A re-emission from any of those files would drop the others, so
-- each is asserted still present afterwards. The case goes where the last two
-- put theirs: after the fifteen days are built and before the sandbox is taken
-- away.

do $cases$
declare
  v_sig  constant text := 'erp_test.demo_history_suite()';
  v_def  text := pg_get_functiondef('erp_test.demo_history_suite()'::regprocedure);

  -- The last of the declarations, as 20260918600000 left them.
  v_o1 constant text := $o1$  v_left numeric; v_residue bigint; v_ppv bigint; g record;
$o1$;
  v_r1 constant text := $q1$  v_left numeric; v_residue bigint; v_ppv bigint; g record;
  -- What the weekend count found (20260918810000)
  v_adj_code text; v_counted bigint;
$q1$;

  -- The head of the sandbox case, which is where the new one goes.
  v_o2 constant text := $o2$  v_cases := v_cases + 1;
  delete from erp.environment where tenant_id = v_tenant and code = 'sandbox';
$o2$;
  v_r2 constant text := $q2$  -- ── 8j. The month adjusts stock ───────────────────────────────────────────
  -- Every Saturday the warehouse counts and writes one unit off
  -- (20260918810000), dated that Saturday under that day's reference, through
  -- the doors a person uses. The movement and its journal both carry the day
  -- of the count, and the cost reaches the stock adjustments account.
  v_adj_code := erp.tenant_account_code('stock_adjustment');

  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.document x
    join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
   where x.tenant_id = v_tenant and dt.base_type_code = 'adjustment';
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_counted
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
   where j.tenant_id = v_tenant and j.status = 'posted'
     and j.source_code = 'stock.adjusted' and a.code = v_adj_code;
  return query select 'the month adjusts stock: on a Saturday the weekend count writes one unit off, dated that day under that day''s reference, with the movement and the journal both carrying the date and the cost on the stock adjustments account'::text,
    v_n >= 1 and v_counted > 0
    and not exists (
      select 1
        from erp.document x
        join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
        join erp.stock_movement m on m.tenant_id = x.tenant_id and m.document_id = x.id
       where x.tenant_id = v_tenant and dt.base_type_code = 'adjustment'
         and (   extract(isodow from x.document_date) <> 6
              or x.their_reference not like 'DEMO-' || to_char(x.document_date, 'YYYYMMDD') || '-%'
              or erp.object_current_state('document', x.id) <> 'posted'
              or m.occurred_at::date <> x.document_date
              or m.reason_code <> 'COUNT_VARIANCE'
              or m.movement_type <> 'count_adjustment'
              or not exists (select 1 from erp.journal j
                              join erp.journal_line jl
                                on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                              join erp.account a
                                on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                             where j.tenant_id = v_tenant and j.status = 'posted'
                               and j.source_code = 'stock.adjusted'
                               and j.posting_date = x.document_date
                               and a.code = v_adj_code
                               and jl.debit_minor > 0))),
    format('%s adjustment(s), %s on the stock adjustments account', v_n, v_counted);

  v_cases := v_cases + 1;
  delete from erp.environment where tenant_id = v_tenant and code = 'sandbox';
$q2$;

  -- The count, pinned in the suite as well as in the wrapper.
  v_o3 constant text := $o3$  if v_cases <> 19 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % cases, expected 19', v_cases
$o3$;
  v_r3 constant text := $q3$  if v_cases <> 20 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % cases, expected 20', v_cases
$q3$;
  v_hits integer;
begin
  if position('base_type_code = ''adjustment''' in v_def) > 0 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % already reads the month''s adjustments', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_o1, ''))) / length(v_o1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % declares what the month billed % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o2, ''))) / length(v_o2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % takes the sandbox away % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o3, ''))) / length(v_o3);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % pins its count % time(s), not once', v_sig, v_hits;
  end if;

  v_def := replace(v_def, v_o1, v_r1);
  v_def := replace(v_def, v_o2, v_r2);
  v_def := replace(v_def, v_o3, v_r3);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp_test.approve_document(v_po, ''suite'')' in v_def) = 0   -- 20260914062000
     or position('purchase_credit_note' in v_def) = 0                      -- 20260918220000
     or position('perform erp.seed_demo_history(v_slice + 10, v_slice + 14, 1);' in v_def) = 0
     or position('purchase_invoice' in v_def) = 0                          -- 20260918600000
     or position('erp.assert_ageing_equals_control()' in v_def) = 0
     or position('''partially_received'', ''received''' in v_def) = 0
     or position('g.difference_minor = 0' in v_def) = 0                      -- 20260918700000
     or position('base_type_code = ''adjustment''' in v_def) = 0
     or position('v_cases <> 20' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % dropped a patch it already had, or did not take its case', v_sig;
  end if;
end
$cases$;

-- The wrapper, needled too: 20260906050000 rewrote every suite wrapper to count
-- a null verdict as a failure, and erp.assert_suite_verdicts_strict() refuses a
-- wrapper that has lost that. All this moves is the other end of the count.
do $wrapper$
declare
  v_sig  constant text := 'erp_test.assert_demo_history_suite()';
  v_def  text := pg_get_functiondef('erp_test.assert_demo_history_suite()'::regprocedure);
  v_o constant text := $o$  if v_all <> 19 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % case(s), expected 19', v_all
$o$;
  v_r constant text := $q$  if v_all <> 20 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % case(s), expected 20', v_all
$q$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_o, ''))) / length(v_o);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_WRAPPER_UNRECOGNISED: % pins its count % time(s), not once', v_sig, v_hits;
  end if;

  execute replace(v_def, v_o, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('not coalesce(passed, false)' in v_def) = 0                     -- 20260906050000
     or position('v_all <> 20' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_HISTORY_WRAPPER_UNRECOGNISED: % lost its null-verdict count, or did not take its pin', v_sig;
  end if;
end
$wrapper$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 16. The suite this one moved the goalposts for
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.site_transfer_suite()'s first case puts an organisation back to
-- inventory-operations version 3 with its transfer order removed, takes the
-- upgrade the way an administrator takes it, and reads the version back. It
-- read 4 because 4 was the register's latest; the register now carries the
-- stock adjustment as 5, so the same organisation arrives at 5.
--
-- Restated rather than relaxed, in the migration that made the old number
-- wrong. The claim the case exists to make is untouched: an organisation that
-- already exists IS offered the transfer order by the upgrade register, and
-- holds it afterwards with its base type, its lifecycle, its numbering rule and
-- its movement type.
--
-- The count of planned items does not move, and that was read rather than
-- assumed: the case counts
--
--     plan_module_upgrade('inventory-operations') where object_kind =
--     'document_type' AND object_key = 'transfer_order'
--
-- so it was already asking for its own document type by name and not for
-- "however many the planner offers". The stock adjustment is a second document
-- type from the same installer, and the planner rightly offers it too — but not
-- under that key, so the answer is still one.
--
-- Only the version moves, and the detail string now says why it moved, so the
-- next person reading a build log is told rather than left to find out.
-- Reading the version by name instead of by number would let the case survive
-- the next addition untouched, and surviving it is the failure: this number is
-- the only thing in the build that says the inventory installer now installs
-- something it did not.

do $transfer_case$
declare
  v_sig constant text := 'erp_test.site_transfer_suite()';
  v_def text := pg_get_functiondef('erp_test.site_transfer_suite()'::regprocedure);
  -- The verdict's last line, which is the only place the version is a number.
  -- The same subquery appears again in the detail below, without the "= 4;".
  v_n1  constant text := $n1$        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 4;
$n1$;
  v_r1  constant text := $r1$        -- 5 since 20260918810000: the register carries the stock adjustment
        -- as inventory-operations version 5, so an organisation put back to 3
        -- and upgraded arrives at 5 rather than 4. What the case asks the
        -- planner for, and what it reads back, is still the transfer order:
        -- the count above names its own object_key, so a second document type
        -- from the same installer does not change it.
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 5;
$r1$;
  -- What the build log says when it passes, and when it does not.
  v_n2  constant text := $n2$  detail := format('%s document type(s) planned, organisation now at version %s',
$n2$;
  v_r2  constant text := $r2$  detail := format('%s transfer order document type(s) planned, organisation now at version %s (5 rather than 4 since the stock adjustment joined the same installer)',
$r2$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SITE_TRANSFER_SUITE_UNRECOGNISED: % reads the module version back % time(s), not once',
      v_sig, v_hits
      using hint = 'A later migration restated the suite. Read its first case and patch its version.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SITE_TRANSFER_SUITE_UNRECOGNISED: % reports its upgrade % time(s), not once',
      v_sig, v_hits;
  end if;

  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);

  -- The new version took, and the rest of the suite is still in it.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('''inventory-operations'') = 5;' in v_def) = 0
     or position('transfer order document type(s) planned' in v_def) = 0
     or position('transfer_despatch' in v_def) = 0
     or position('CLOVEERP_TRANSFER_CROSSES_COMPANIES' in v_def) = 0
     or position('the oldest 30 at 20 each go' in v_def) = 0
     or position('v_cases <> 12' in v_def) = 0 then
    raise exception
      'CLOVEERP_SITE_TRANSFER_SUITE_UNRECOGNISED: % did not take its new version, or the rewrite dropped a case',
      v_sig;
  end if;
end
$transfer_case$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 17. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_stock_adjustment_suite();
select erp_test.assert_demo_history_suite();
select erp_test.assert_site_transfer_suite();
select erp_test.assert_plain_words_suite();

select erp.assert_write_only_columns();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_resource_coverage('en');
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_no_dead_configuration();
select erp.assert_isolation();
