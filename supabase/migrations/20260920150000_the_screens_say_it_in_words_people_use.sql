set lock_timeout = '30s';

-- =============================================================================
-- 20260920150000  The screens say it in words people use
-- -----------------------------------------------------------------------------
-- The plain-English review of 18 September read every screen as somebody who
-- has never used an ERP. Its verdict in one line: the layouts are fine, the
-- words are the problem. Almost every screen opened with one clear sentence and
-- then added two that undid it; buttons were named after the record rather than
-- the job; and words nobody says out loud — dispositioned, excursion,
-- marshalling area, governed ledger — were printed on the screens of the people
-- least likely to say them.
--
-- The screens' own words changed in src. This is the part that lives here:
--
--   1. The first instruction a new administrator is ever given, on Home. It was
--      "Vocabularies, reason codes, states and tolerances arrive as change sets;
--      the acceptance suite says when the set is complete" — five pieces of
--      jargon in one sentence, before anybody has done anything, and "change
--      set" is one of the words erp_ref.vocabulary marks as never to be shown. It
--      reached a screen only because first-run steps are not erp_ref.resource
--      rows, so erp.assert_vocabulary_aligned() could not see it. Step 2 said
--      "change set" too.
--
--   2. CLOVEERP_NO_POSTING_LOCATION read "site has no active receiving location,
--      so a in movement has nowhere to go": an article glued to a direction code.
--      It now names the place the way the product names it (goods-in) and the
--      goods the way a person does (goods coming in).
--
--   3. Seven setup screens renamed on the Settings launchpad. Their titles are
--      nav.* rows, so the literal in src is only the fallback and the row is what
--      a person sees.
--
--   4. A row for every sentence the rewrite put on a screen, so each can still be
--      renamed by an organisation and supabase/ci/screen_strings.sh finds its row.
--      The rows the old sentences had are left where they are: an organisation's
--      own wording keyed on them is theirs, and removing product rows would
--      orphan it.
--
-- Two terms the review's list replaced are prescribed product terms in
-- erp_ref.vocabulary — "Handling unit" and "Marshalling area". The screens now
-- say "pallet" and "loading bay" as the owner asked; the glossary definitions
-- are not rewritten here, because a handling unit is also a tote or a carton and
-- the glossary is where that distinction is kept.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Home's first steps
-- ═════════════════════════════════════════════════════════════════════════════

do $first_run$
declare v_n integer;
begin
  update erp_ref.first_run_step s
     set title = 'Apply the ready-made setup',
         why   = 'We''ll set up your standard lists and limits for you. You can change any of it later.'
   where s.guide_code = 'administrator' and s.seq = 3;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: % administrator first-run step 3 row(s), expected 1', v_n
      using hint = 'The step is seeded by 20260904500000; this migration corrects its words and cannot insert it.';
  end if;

  update erp_ref.first_run_step s
     set why = 'Each one proposes its settings as an update you can read first; nothing is typed straight into a live organisation.'
   where s.guide_code = 'administrator' and s.seq = 2;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: % administrator first-run step 2 row(s), expected 1', v_n
      using hint = 'The step is seeded by 20260904500000; this migration corrects its words and cannot insert it.';
  end if;

  if exists (select 1 from erp_ref.first_run_step s
              where s.why ~* '\mchange sets?\M' or s.title ~* '\mchange sets?\M'
                 or s.why ~* 'acceptance suite') then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: a first-run step still says change set or acceptance suite'
      using hint = 'Another step carries the word; correct it here too.';
  end if;
end
$first_run$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A refusal that reads as a sentence
-- ═════════════════════════════════════════════════════════════════════════════

do $posting_location$
declare
  v_sig constant text := 'erp.default_posting_location(uuid,erp.movement_direction)';
  v_def text := pg_get_functiondef('erp.default_posting_location(uuid,erp.movement_direction)'::regprocedure);
  v_n   constant text :=
       E'      ''CLOVEERP_NO_POSTING_LOCATION: site has no active % location, so a % ''\n'
    || E'      ''movement has nowhere to go'', v_kind, p_direction\n';
  v_r   constant text :=
       E'      ''CLOVEERP_NO_POSTING_LOCATION: the site has no active % place, so % have nowhere to go'',\n'
    || E'      case v_kind when ''receiving''::erp.location_type then ''goods-in''\n'
    || E'                  when ''despatch''::erp.location_type then ''despatch''\n'
    || E'                  else ''staging'' end,\n'
    || E'      case p_direction when ''in''::erp.movement_direction then ''goods coming in''\n'
    || E'                       when ''out''::erp.movement_direction then ''goods going out''\n'
    || E'                       else ''goods being moved'' end\n';
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not raise its refusal once the way the 20260906060000 body does', v_sig
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;
  execute replace(v_def, v_n, v_r);
  if position('so a % ' in pg_get_functiondef(v_sig::regprocedure)) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % still glues an article to a direction', v_sig
      using hint = 'The rewrite did not take.';
  end if;
end
$posting_location$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Setup screens named for what they are for
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description) values
  ('nav.operations_assurance',        'en', 'Checks and sign-off',          'Settings tile; was Assurance.'),
  ('nav.operations_continuity',       'en', 'Backups and outages',          'Settings tile; was Continuity and incidents.'),
  ('nav.operations_cutover',          'en', 'Moving your old data in',      'Settings tile; was Migration and cutover.'),
  ('nav.logistics_release_areas',     'en', 'Loading bays',                 'Settings tile; was Marshalling areas.'),
  ('nav.finance_account_determination','en','Which accounts things post to','Settings tile; was Account determination.'),
  ('nav.finance_dimensions',          'en', 'Extra reporting tags',         'Settings tile; was Analysis dimensions.'),
  ('nav.tenant',                      'en', 'Going live and closing down',  'Settings tile; was Organisation lifecycle.'),
  ('module.tenant_lifecycle',         'en', 'Going live and closing down',  'Page title; was Organisation lifecycle.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A row for every new sentence on a screen
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string in plain words (20260920150000), rendered through ui().'
  from (values
    ('A code is composed from the classification by a versioned template, recorded once, and never silently rewritten — if the classification later changes, the divergence is reported rather than hidden.'),
    ('A complaint, something that did not go to plan, something that went outside its safe range — anything that needs answering.'),
    ('A confirmed order becomes a purchase order or a works order and leaves planning.'),
    ('A department is one object: it routes an approval and it carries the posting.'),
    ('A draft delivery for the order''s customer and site, holding what is left to deliver on each line at the order''s price. Confirm it when the goods leave.'),
    ('A draft goods receipt for the order''s supplier and site, holding what is left to receive on each line at the order''s price. Confirm it once the goods are counted in.'),
    ('A place nobody has counted shows as never counted rather than as agreeing. Nothing on this screen changes stock: confirm a count and the correction is made as a movement, with a reason.'),
    ('A posting class is what accounting cares about; the product is what operations cares about.'),
    ('A quote is assembled from price items, not typed.'),
    ('A regulated product cannot default to a supplier that is not on the approved list, and the shares recorded against a product''s suppliers may not add to more than the whole.'),
    ('A short code for this loading bay.'),
    ('A supplier-direct order is bought from a supplier who delivers to the customer; an order between your companies is copied into the company that supplies it. Pinning a line ties it to a batch, a location or a pallet.'),
    ('A warehouse is a shape, not a list: zones hold aisles, aisles hold bins, and a storage rule says which product belongs where.'),
    ('A wave allocates in detail against the area, what the area cannot cover raises directed replenishment rather than a shortage, and nothing prints until every line is covered.'),
    ('Accept an invoice that does not match'),
    ('Accruals, prepayments and corrections typed by hand.'),
    ('Add delivery costs to the stock value'),
    ('Add or change a loading bay'),
    ('Add the loading bay {name} ({code}), bringing in just what is short'),
    ('Add the loading bay {name} ({code}), bringing in just what is short; stock left more than {hours} hours goes back to storage'),
    ('Add the loading bay {name} ({code}), topped up when short'),
    ('Add the loading bay {name} ({code}), topped up when short; stock left more than {hours} hours goes back to storage'),
    ('Affected stock has shipped: start a recall and log every action against the clock.'),
    ('An adjustment carries the date the count was taken, the reason it changed, and an approval before anything is written. Its cost is counted on the day the count was taken, not the day it was typed in.'),
    ('An event closes once you have decided what happens to it and logged the actions.'),
    ('Backups and outages'),
    ('Bands decide who approves by value; a named assignment overrides that for a person, a role or a whole department.'),
    ('Batch history'),
    ('Book carrier'),
    ('Build a pallet'),
    ('Bulk export reads the same door incrementally.'),
    ('Change one week or month of a draft forecast. The calculated figure stays beside it.'),
    ('Change one week or month of a forecast'),
    ('Checks and sign-off'),
    ('Closing an order settles the difference from plan and stops further hours being recorded.'),
    ('Confirm a count'),
    ('Confirm a planned order'),
    ('Confirm a stock adjustment'),
    ('Confirm a supplier-direct order'),
    ('Confirm the plan'),
    ('Confirmed deliveries from the site above, from the last 30 days, that are not on a shipment yet. Tick every one travelling on this shipment.'),
    ('Corrections to what the system says is on the shelf: a count difference, damage, theft or a sample, each carrying the day it was found, a reason and an approval.'),
    ('Counting a location, recording what was found, and confirming the difference.'),
    ('Create the delivery from its sales order, confirm it when the goods leave, then plan the shipment, book the carrier and record proof of delivery.'),
    ('Create the order, release it to the floor, take out the materials, record the hours, take in the finished goods and close it.'),
    ('Creates a purchase order against the agreement. Each line draws down a standing order line.'),
    ('Days ahead'),
    ('Days left'),
    ('Days of stock left is what is on hand divided by what goes out each day. The order-by date is the day stock falls to the level you order at, so ordering after it is late. What is already on order is counted, so nothing waiting on a delivery is ordered twice.'),
    ('Days to arrive'),
    ('Decide a count difference'),
    ('Decide what happens to it'),
    ('Describe how the business works — your companies, departments, who signs off spending, how products are grouped and coded — and your answers become the set-up to match. Most questions come with a likely answer you can take with one press. Nothing changes until you accept what your answers propose.'),
    ('Did not go to plan'),
    ('Difference'),
    ('Difference in value'),
    ('Draw down from a standing order'),
    ('Each price item is a product of this organisation with a commercial shape: a plan tier, a feature add-on, a band of an entitlement, an environment, a support tier, a fixed-price service, or a legislation pack at nil.'),
    ('Every location with its quantity and value, the last count against it, and the difference between the two.'),
    ('Every week or month of one forecast, with the calculated figure beside any change you made.'),
    ('Everything started, with progress against the ordered quantity.'),
    ('Extra reporting tags'),
    ('Find a price'),
    ('Find a purchase price'),
    ('For a standing order only.'),
    ('Forecast the demand, sign it off, work out what to order, then confirm what the plan suggests.'),
    ('Getting picked goods out of the door and proving they arrived.'),
    ('Goods arrive, are put away, are counted, and are corrected or passed on.'),
    ('Governed views exposed to external tools as versioned contracts, deprecated on notice; credentials scoped to the organisation and to named views, expiring and revocable.'),
    ('Have the supplier send it direct'),
    ('Hours worked on each operation, so the difference from plan means something.'),
    ('How a pallet is identified and counted, by product class, by site or by the step it is built at.'),
    ('How fast each product is going out, and when you need to order more.'),
    ('How much you expect to need each week or month, from past sales and anything you know is coming.'),
    ('How pallets are identified and counted, for a product class or a site. Proposed as a change, so it is approved like any other setting.'),
    ('How this organisation is set up, in the order you would set it up.'),
    ('How this works'),
    ('In-app is the channel that always works; nothing addressed to you is lost because another channel failed.'),
    ('Invoices that do not match'),
    ('Loading bay'),
    ('Loading bays'),
    ('Making the system agree with the shelf.'),
    ('Margin shows live per line and in total against the cost model; a discount beyond the threshold is routed for approval; every version is retained; the order form is the quote rendered, not re-keyed.'),
    ('Meaning lives in the classification, not in the code.'),
    ('Most urgent first. Where no order level has been set, the one the product''s own history suggests is shown instead.'),
    ('Moving stock from one of your warehouses to another.'),
    ('Moving your old data in'),
    ('Needed while waiting'),
    ('No bills of materials yet. Define one from Actions before starting a works order for a made product.'),
    ('No loading bays yet. Allocation runs against the whole site until one exists.'),
    ('No quality events open. Report one from Actions when something needs investigating.'),
    ('No works orders to profile. Start one from Actions and it is counted here by status.'),
    ('No works orders yet, so the register is empty. Start one from Actions.'),
    ('No works orders yet. Start one from Actions.'),
    ('Non-conformances, complaints, things that did not go to plan, and their investigations.'),
    ('Nothing worked out yet. Work out what to order for a site and it is kept here.'),
    ('On pallet'),
    ('One person raises and submits a journal; somebody else who may approve journals posts it. A posted journal is never changed, only reversed.'),
    ('One supplier is the default for a product at a site; the rest are ranked alternatives.'),
    ('Only the steps your permissions make yours. Most tick themselves as you work.'),
    ('Only you can change these; an administrator manages what you may do, not who you are.'),
    ('Going live and closing down'),
    ('Optional. A loading bay set up for one order type only takes lines from an order of that type.'),
    ('Order at'),
    ('Order from another of your companies'),
    ('Order this product'),
    ('Pallet id'),
    ('Parts a plan needs'),
    ('Pass on'),
    ('Past weeks or months to use'),
    ('Plan one site under different assumptions, beside the real plan. A scenario''s orders are never real and cannot be confirmed; compare it with the real plan instead.'),
    ('Plans only use a forecast once somebody has signed it off.'),
    ('Problems found, what was decided about them, supplier approval and recalls — each against a deadline.'),
    ('Proof of delivery'),
    ('Put-away sends goods to the place the rules name, replenishment tops up the pick face they name, and picking prefers it once the first-expired rule has chosen the stock.'),
    ('Rates are maintained per currency and term; the cost beside each rate is what makes margin visible while quoting.'),
    ('Receipts confirmed against a purchase order. Stock lands in goods-in before it has a home.'),
    ('Received, not yet billed'),
    ('Record hours'),
    ('Report a problem'),
    ('Rules are written against the class, and one rule returns the account and its analysis together. Nothing falls into a suspense account: an unmatched posting is refused and reported.'),
    ('Scan a product, location or pallet'),
    ('Something is found, it is inspected, you decide what happens to it, and if it has left the building there is a recall.'),
    ('Spare buffer'),
    ('Standard, standing order, supplier-owned stock, supplier sends it direct, or between your companies. Fixed once the order is sent.'),
    ('Standing order line'),
    ('Standing order position'),
    ('Standing order runs to'),
    ('Start a recall'),
    ('Start at the top and work down. Nothing here is needed to get the day''s work done.'),
    ('Start making something'),
    ('Stock affected by a temperature problem'),
    ('Stock in a loading bay is allocated stock: out of counting scope and out of reach of other demand.'),
    ('Take in finished goods'),
    ('Take out materials'),
    ('Take stock a supplier still owns into your ownership where it stands. It is costed at the agreed price and recorded as received, not yet billed, because the supplier will bill what was used.'),
    ('The batch, location or pallet a sales line must be filled from.'),
    ('The contract is the source; the entitlement enforced is derived from it.'),
    ('The goods leave the first site''s shelves when they are loaded and stay that site''s stock, at the same value, until they are booked in at the other end.'),
    ('The lines of the standing order chosen above being drawn down, and how much of each.'),
    ('The same products with what sits behind the answer: how much went out, over how many days, what will be needed while an order is on its way, and the levels your organisation set.'),
    ('Top up to'),
    ('Traceable units, and what they came from.'),
    ('Use supplier-owned stock'),
    ('Week or month'),
    ('Went outside the safe range'),
    ('What is owed to each supplier, what is overdue, what has been paid, and what is held because an invoice does not match.'),
    ('What problems are being reported.'),
    ('What stock was standing in a place between two times, so you can see what a temperature problem affected.'),
    ('What the counter found in the place. The difference is worked out from it.'),
    ('What the product told you, what it held for your quiet hours, and what it could not deliver another way.'),
    ('What the system says is in each place, what it is worth, and what the last count found.'),
    ('What the system would set for one product and site, before you adopt it.'),
    ('What the works orders a plan created need in parts, by date.'),
    ('What this organisation is entitled to, what it is using, what it will pay next and when its term ends, without asking.'),
    ('What was agreed on a standing order, what has been drawn down, and what is left, line by line.'),
    ('What you need, less what you have and what is already coming, including the parts of anything you make.'),
    ('Which accounts things post to'),
    ('Work beside the steps: invoices that do not match, drawing down from standing orders, supplier-direct orders, approval limits, price lookups, supplier approval and delivery costs.'),
    ('Work beside the steps: stock reservations, credit limits and holds, and customer returns.'),
    ('Work out again what to buy and make at one site, and what needs your attention.'),
    ('Work out what to order'),
    ('Works order: plan against actual'),
    ('Your first-day questionnaire.'),
    ('Your names, the name the product shows for you, and the time zone and languages your screens and documents follow.'),
    ('held because an invoice does not match')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
