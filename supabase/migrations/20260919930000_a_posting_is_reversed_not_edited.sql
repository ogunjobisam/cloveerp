set lock_timeout = '30s';

-- =============================================================================
-- 20260919930000  A posting is reversed, not edited
-- -----------------------------------------------------------------------------
-- A guard is landing that refuses amending a document once it is no longer only
-- ours. That is right, and it makes one question urgent: if a posted document is
-- wrong, what does a person actually do? The whole repository was read for the
-- answer before a line of this was written, and the answer was worse than
-- expected in one place and better in two others.
--
-- ── WHAT IS ALREADY THERE ────────────────────────────────────────────────────
--
--   public.erp_reverse_journal (20260914071000) is a complete reversal, and the
--   shape everything below follows: it mirrors every line of a posted journal
--   with the sides swapped, dates the mirror on a date of its own, requires a
--   reason, refuses a journal already reversed, links the two by
--   erp.journal.reverses_journal_id, and never touches the original. It applies
--   to journals somebody typed on the Journals screen — `source_code = 'manual'`
--   and `prepared_by not null` — and to nothing else. Its own hint says so:
--   "A document's postings are reversed by the document that made them."
--
--   The two credit notes (20260918170000, 20260918700000) are the document-level
--   answer where goods come back. A customer credit note reverses a despatch or
--   the invoice that billed one; a supplier credit note reverses a goods
--   receipt. Both post, both move the stock back at what it cost, both are
--   attributable and carry a reason code. Where the goods come back, the route
--   exists and is good.
--
-- ── WHERE THE HINT IS NOT TRUE ───────────────────────────────────────────────
--
--   A document's postings are NOT reversed by the document that made them.
--   Nothing reverses them at all. Read in full:
--
--   * erp.cancel_document() (0025) sets is_cancelled and writes no journal. It
--     is behind no door, is named by no screen, and is called by three suites.
--     So the feared shape — a cancellation that changes a state and leaves the
--     ledger saying the original still happened — is not what the product does.
--     It does nothing, which is a different and larger problem.
--
--   * No lifecycle has a cancel transition out of a committed state. A purchase
--     invoice goes draft → registered, and `cancel` runs draft → cancelled only;
--     a sales invoice the same from draft → issued. A registered supplier bill
--     cannot be cancelled, cannot be amended once the amendment guard lands,
--     cannot be credited — erp.raise_supplier_credit_note() refuses anything but
--     a `receipt` by name — and cannot be reversed, because erp_reverse_journal
--     takes hand-typed journals only. It is a complete dead end, and the seeded
--     demonstration raises one every Thursday, deliberately billed above the
--     agreed price so that somebody looks at it.
--
--   * A sales invoice has half a route. erp.raise_customer_credit_note() takes
--     it, but a credit note in this product is a goods return: every line must
--     reach a despatch (CLOVEERP_CREDIT_LINE_HAS_NO_DESPATCH) and every line
--     moves stock. For an invoice that is wrong about money and not about goods
--     — a price keyed wrong, the wrong customer, a bill raised twice — the only
--     instrument puts stock back on a shelf that nothing came back to.
--
-- ── WHAT IS NOT A GAP, SAID SO THAT NOBODY LOOKS AGAIN ───────────────────────
--
--   An order is not a dead end. `purchase_commitment` and `sales_commitment`
--   post into the COMMIT ledger, whose ledger_kind is `management` — the words
--   the onboarding interview uses for it are "kept as a memo outside your
--   books". Nothing an order writes reaches the trial balance, so there is no
--   figure in the accounts to unmake. (That the commitment is not released when
--   the order is cancelled is true and is a separate finding about the
--   memorandum ledger, not about reversal.)
--
--   A stock adjustment is not a dead end either. Since 20260918810000 its
--   journal is the movement's, raised by erp.post_movement_finance() on the
--   movement's own date, and the way back is the opposite adjustment on its own
--   date — which that migration built. Its affects_finance is false.
--
--   A transfer order writes no journal at all: value crosses at cost.
--
-- ── THE DECISION: MIRROR THE JOURNAL, DO NOT RE-RUN THE RULE ─────────────────
--
-- The obvious design is a reversal document that erp.post_document_finance()
-- posts from the same rule. It cannot be built, for three reasons, and each of
-- them is worth stating because each looks surmountable until it is read:
--
--   1. That bridge refuses a document that already has a journal
--      (CLOVEERP_ALREADY_JOURNALLED), so it cannot write a second journal
--      against the original at all.
--
--   2. A posting rule's lines carry a fixed side, and erp.journal_line checks
--      `debit_minor >= 0` with exactly one side positive. A contra therefore
--      cannot be "the same rule at a negative value"; it has to be a swap of
--      sides, which a rule cannot express.
--
--   3. The bridge recomputes every basis from the document as it stands on the
--      day it is asked — the rule version in force on the new date, the tax
--      determined again, the receipts matched again. A contra computed that way
--      is not guaranteed to net the original to nothing, and netting to nothing
--      is the one thing a reversal is for.
--
-- So the contra is the original journal's own lines with the sides swapped, on
-- a date of its own, which is exactly what erp_reverse_journal has done for a
-- hand-typed journal since 14 September. Three things follow from it that are
-- worth having on purpose:
--
--   * It names no account the original did not name, so no posting rule is
--     added, no basis is added, and erp.determination_coverage_report() cannot
--     move. A reversal cannot fail on a company whose chart is missing an
--     account, because it only ever posts to accounts that company already
--     posted to.
--
--   * It mirrors erp.subledger_item as well as erp.journal_line. The bridge
--     writes both from the same loop, and a reversal that wrote only the journal
--     would part the control account from the subledger and from the ageing —
--     two of the four unwaivable ties — on the first use. The four ties hold
--     because both sides of the pair are mirrored, exactly.
--
--   * It refuses a document that moved stock (CLOVEERP_REVERSAL_MOVED_STOCK).
--     Unmaking the journal of a despatch without moving the goods would leave
--     inventory in the accounts disagreeing with the stock ledger, which is the
--     third tie. That refusal names the credit note, which moves both together.
--
-- ── ITS OWN DATE, AND THE CLOSE ──────────────────────────────────────────────
--
-- DEPENDS ON #198 (20260919100000, erp.local_today). A PostgREST session runs
-- at UTC, so current_date is the database's day and not the day where the work
-- is happening: a document keyed at ten to one in the morning BST was written
-- with yesterday's date, and at a month end that is the previous accounting
-- period. #198 answers whose day it is once — the site's timezone, then the
-- organisation's, then UTC — and this reads that answer rather than deriving a
-- second one. It matters more here than almost anywhere: a reversal is dated
-- against the period it lands in, so a reversal an hour on the wrong side of
-- midnight can post into a different month from the journal it reverses, which
-- is the exact failure this migration exists to prevent. This migration sorts
-- after 20260919100000 and will not apply before it.
--
-- p_posting_date defaults to today and may be any open date. The period guard is
-- the product's single definition of one, erp.journal_period(), called before
-- anything is written: CLOVEERP_JOURNAL_NO_PERIOD for a date no period holds,
-- CLOVEERP_JOURNAL_PERIOD_CLOSED for one that is closed, whose hint already says
-- the next action in the words this needs — "Date the journal in an open period,
-- or ask somebody who may reopen periods to reopen it with the reason". A
-- September posting reversed in October posts in October. A date after today is
-- refused outright: a reversal dated ahead of itself is a forecast.
--
-- Under it, unchanged, sits erp.check_period_open() on erp.journal, which is
-- what makes the guard true rather than polite. The early call is so the person
-- is told which period and what to do instead, rather than meeting a trigger.
--
-- ── WHAT IT LEAVES, SAID RATHER THAN HIDDEN ──────────────────────────────────
--
--   The document's own state does not change. A reversed invoice is still
--   "registered" or "issued", because no lifecycle has a transition out of those
--   states and inventing one here would be a lifecycle change hiding inside a
--   ledger change. What does change is what it is worth: the subledger nets to
--   nothing, so it leaves the ageing and the open items of its own accord. The
--   screen says which, by reading the reversal back.
--
--   Cash already applied stays applied. Reverse an invoice a customer has part
--   paid and the pair nets to nothing while the receipt does not, so the party
--   carries money on account — which is the truth: they paid, and the charge was
--   unmade. Every tie still holds, because the control account nets the same
--   three rows the ageing does.
--
--   Reversing a bill puts goods received not invoiced back where the receipt
--   left it, so the receipt can be billed again correctly. The second bill
--   debits it again and the account comes back to nil, which is the arithmetic
--   erp.grni_reconciliation() reads.
--
-- ── AND A REGISTER, SO THE NEXT DEAD END CANNOT BE SILENT ────────────────────
--
-- erp.document_reversal_route() says, for every base type that reaches the
-- ledger, how that kind is undone and what to do instead. It is not decoration:
-- erp.assert_every_posting_can_be_undone() refuses a posting kind with no row,
-- refuses a row claiming `reversal` for a kind that moves stock, refuses a row
-- claiming `credit_note` unless a credit note routine names that base type,
-- refuses a row claiming `memorandum` if any organisation's rule for that kind
-- targets a ledger that keeps the books, and refuses a row claiming
-- `not_installed` if any organisation has ever made a document type of it.
--
-- Two kinds are registered as irreversible with the reason named: a sales credit
-- note and a supplier credit note are themselves reversals, and the product
-- already says what to do with a reversal raised in error — erp_reverse_journal
-- refuses one and tells you to raise the original again. Two more are registered
-- as not installed, which is a claim the assertion holds to: the day production
-- installs a works order type, the build says the register has gone stale.
--
-- Proof: erp_test.document_reversal_suite() (16 cases), which builds its own
-- organisation, buys a hundred, bills them, reverses the bill, and reads the
-- ledger, the subledger, the period and the attribution back.
-- =============================================================================

-- ── 1. The register: how each posting kind is undone ─────────────────────────

create or replace function erp.document_reversal_route()
returns table(base_type_code text, route text, next_action text, rationale text)
language sql
immutable
set search_path = ''
as $$
  select v.base_type_code, v.route, v.next_action, v.rationale
    from (values
      ('purchase_order'::text, 'memorandum'::text,
       'A purchase order puts a commitment in the memorandum ledger and nothing in the books. Cancel or close the order; there is no figure in the accounts to unmake.'::text,
       'The only rule a purchase order names is purchase_commitment, whose ledger is COMMIT — ledger_kind management, which the onboarding interview calls "kept as a memo outside your books". Nothing it writes reaches the trial balance, so a reversal would unmake nothing while saying something had been put right.'::text),

      ('sales_order', 'memorandum',
       'A sales order puts a commitment in the memorandum ledger and nothing in the books. Cancel or close the order; there is no figure in the accounts to unmake.',
       'The mirror of the purchase order: sales_commitment posts into COMMIT, a management ledger. The despatch and the invoice raised from the order are what reach the books, and each of those has a route of its own.'),

      ('receipt', 'credit_note',
       'Send the goods back on a supplier credit note, raised from the receipt that brought them in. It reverses what we owe and takes the stock off the shelf at what it cost, in one document.',
       'A goods receipt put stock on the shelf as well as a figure in the ledger. Unmaking its journal alone would leave inventory in the accounts disagreeing with the stock ledger, which is one of the four ties the month is closed on. erp.raise_supplier_credit_note() moves both.'),

      ('delivery', 'credit_note',
       'Take the goods back on a customer credit note, raised from the despatch or the invoice that billed it. It reverses the sale and puts the stock back at what it cost.',
       'A despatch took stock off the shelf as well as writing cost of sales. The way back has to move both, and erp.raise_customer_credit_note() does — valuing what comes back from the movement the despatch wrote, not from what it sold for.'),

      ('invoice_reference', 'reversal',
       'Reverse the posting. A contra journal is raised in an open period with its own date and the reason it was reversed; the invoice stays in the record and the pair nets to nothing.',
       'An invoice moves no stock — the despatch or the receipt did that — so everything it did is in the books and a contra journal unmakes all of it. This is the kind a credit note cannot answer when nothing is coming back: a price keyed wrong, the wrong customer, a bill raised twice.'),

      ('credit_reference', 'is_itself_a_reversal',
       'A credit note is already the reversal of an invoice. If it was raised in error, invoice the customer again for the goods that did not come back; reversing a reversal is posting the original a second time.',
       'The rule the product already applies to a hand-typed journal, in erp_reverse_journal: a journal that is itself a reversal is refused, and the next action is to raise the original again. A sales credit note also took goods back on to the shelf, so unmaking its journal alone would part the ledger from the stock as well.'),

      ('return_to_supplier', 'is_itself_a_reversal',
       'A supplier credit note is already the reversal of a receipt. If it was raised in error, receive the goods again against the order; reversing a reversal is posting the original a second time.',
       'The mirror of the sales credit note, and refused for the same two reasons: it is a reversal, and it moved goods off the shelf that unmaking its journal alone would not put back.'),

      ('works_order', 'not_installed',
       'Nothing raises a works order in this product yet. When production installs a document type on this base type, it needs a route on this register before it can post.',
       'erp_ref.document_type says a works order reaches the ledger, and no installer has ever made a tenant document type of it — erp.configure_production() ships the numbering rule, the work in progress account and the variance accounts, and no type. erp.assert_every_posting_can_be_undone() holds the claim: the day a type appears, the build says this row has gone stale.'),

      ('count', 'not_installed',
       'A stock count posts through erp.post_count(), which writes movements and no document, and a variance is put right by the next count or by a stock adjustment on its own date. When a count becomes a document, it needs a route on this register before it can post.',
       'The same shape as the works order: the base type says it reaches the ledger and no installer makes a type of it. What a count actually posts goes through erp.post_movement_finance() on the movement, which is dated and undone where the movement is.')
    ) as v(base_type_code, route, next_action, rationale)
$$;

revoke all on function erp.document_reversal_route() from public, anon, authenticated;

comment on function erp.document_reversal_route() is
  'For every base document type that reaches the ledger, how a posting of that '
  'kind is undone and what a person does instead: reversal (a contra journal '
  'through erp.reverse_document_posting), credit_note, memorandum (nothing '
  'reaches the books), is_itself_a_reversal, or not_installed. '
  'erp.assert_every_posting_can_be_undone() refuses a posting kind with no row '
  'and holds every claim on this register to what the product actually does.';

-- ── 2. The event a reversal raises ───────────────────────────────────────────
--
-- erp.check_journal_line_posting() refuses a machine-generated line that cannot
-- name its source event and posting rule. The mirrored lines keep the original's
-- rule and version — the explanation of the figure is the rule that produced it
-- — and take a new event, because unmaking a posting is a different act from
-- making it and the audit trail should not say otherwise.

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('document.posting_reversed', 1, 'document', 'finance', 'event.document.posting_reversed',
   'A document''s posting was reversed: a contra journal was raised on its own date, '
   'with the reason it was reversed for, and the original left standing.',
   jsonb_build_object(
     'type', 'object',
     'required', jsonb_build_array('document_number', 'posting_date', 'reason'),
     'properties', jsonb_build_object(
       'document_number',  jsonb_build_object('type', 'string'),
       'document_type',    jsonb_build_object('type', 'string'),
       'reverses_journal', jsonb_build_object('type', 'string'),
       'posting_date',     jsonb_build_object('type', 'string'),
       'reason',           jsonb_build_object('type', 'string'))),
   true)
on conflict (code, version) do update
  set aggregate_type = excluded.aggregate_type, module_code = excluded.module_code,
      name_key = excluded.name_key, description = excluded.description,
      payload_schema = excluded.payload_schema, is_current = excluded.is_current;

-- Both locales. erp.assert_resource_coverage('en') is what a migration calls, so
-- an event type with an English name and no German one applies cleanly and then
-- fails resource_coverage_de on the assurance run, which is where this was
-- found: "1 key(s) with no de string — erp_ref.event_type:
-- event.document.posting_reversed". The verb is the one German accounting uses
-- for exactly this and nothing else.
insert into erp_ref.resource (key, locale, value) values
  ('event.document.posting_reversed', 'en', 'Document posting reversed'),
  ('event.document.posting_reversed', 'de', 'Buchung des Belegs storniert')
on conflict (key, locale) do nothing;

-- ── 3. Reading a reversal back ───────────────────────────────────────────────

create or replace function erp.document_posting_reversal(p_document_id uuid)
returns table(journal_id uuid, journal_number text, posting_date date,
              reason text, reversed_by uuid, reversed_at timestamptz,
              reverses_journal_id uuid, reverses_journal_number text)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Both journals name the document, and the reversal names the journal it
  -- reverses. That is the whole link: the original is reachable from the
  -- reversal and the reversal from the original, and nothing on the document
  -- itself had to be rewritten to say so.
  select r.id, r.journal_number, r.posting_date,
         r.manual_reason, r.posted_by, r.posted_at,
         o.id, o.journal_number
    from erp.journal r
    join erp.journal o
      on o.tenant_id = r.tenant_id and o.id = r.reverses_journal_id
   where r.tenant_id = erp.current_tenant_id()
     and o.document_id = p_document_id
     and r.status = 'posted'
   order by r.posting_date, r.id
$$;

revoke all on function erp.document_posting_reversal(uuid) from public, anon, authenticated;

comment on function erp.document_posting_reversal(uuid) is
  'The contra journals raised against a document''s postings: when, by whom, for '
  'what reason, and which journal each one reverses. Empty where nothing has '
  'been reversed.';

-- ── 4. The instrument ────────────────────────────────────────────────────────

create or replace function erp.reverse_document_posting(
  p_document_id  uuid,
  p_reason       text,
  p_posting_date date default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid;
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  j        erp.journal%rowtype;
  v_base   text;
  v_route  text;
  v_next   text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_today  date;
  v_on     date;
  v_books  integer := 0;
  v_prior  text;
  v_prior_on date;
  v_event  uuid;
  v_new    uuid;
  v_n      integer := 0;
  v_ids    uuid[] := '{}';
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id
      using errcode = '23503',
            hint = 'Open the document from the Documents list and reverse it from there.';
  end if;

  -- Deciding what date an entry reaches the ledger on is finance.post, which is
  -- the same read 20260918810000 made of backdating a stock adjustment.
  perform erp.authorise('finance.post', d.entity_id, d.site_id, null,
                        'document', p_document_id);
  v_me := erp.current_principal_id();

  -- Whose day it is: the site's, then the organisation's, then UTC (#198). The
  -- database's own day is not it — a reversal defaulted from current_date at
  -- half past midnight BST would be dated yesterday, and at a month end
  -- yesterday is a different period from the one the person is standing in.
  v_today := erp.local_today(d.site_id);
  v_on    := coalesce(p_posting_date, v_today);

  select * into dt from erp.document_type
   where tenant_id = v_tenant and id = d.document_type_id;
  v_base := dt.base_type_code;

  select r.route, r.next_action into v_route, v_next
    from erp.document_reversal_route() r
   where r.base_type_code = v_base;

  if coalesce(v_route, '') <> 'reversal' then
    raise exception
      'CLOVEERP_DOCUMENT_NOT_REVERSIBLE: % is a %, and that is not undone by reversing its posting',
      d.document_number, lower(coalesce(dt.name, v_base))
      using errcode = '23514',
            hint = coalesce(v_next,
                     'This kind of document has no way back written down. Put one on '
                     'erp.document_reversal_route() before anything reverses it.');
  end if;

  if v_reason is null then
    raise exception
      'CLOVEERP_REVERSAL_NEEDS_A_REASON: reversing % needs the reason it is being reversed for',
      d.document_number
      using errcode = '23514',
            hint = 'Say why the posting is being unmade. The reason is kept on the '
                   'reversing journal, where whoever reviews the ledger reads it.';
  end if;

  if v_on > v_today then
    raise exception
      'CLOVEERP_REVERSAL_IN_THE_FUTURE: % is after today, which where this document was raised is %',
      v_on, v_today
      using errcode = '23514',
            hint = 'Date the reversal today, or in an open period that has already happened.';
  end if;

  -- A document that moved goods is undone by the document that moves them back.
  -- Unmaking the journal alone would leave inventory in the accounts disagreeing
  -- with the stock ledger, which is one of the four ties the month closes on.
  if exists (select 1 from erp.stock_movement m
              where m.tenant_id = v_tenant and m.document_id = p_document_id) then
    raise exception
      'CLOVEERP_REVERSAL_MOVED_STOCK: % moved stock, so unmaking its journal alone '
      'would leave the ledger saying one thing and the shelf another', d.document_number
      using errcode = '23514',
            hint = 'Raise a credit note against it instead: that reverses the money and '
                   'moves the goods back at what they cost, in one document.';
  end if;

  -- What is in the books, as against what is in a memorandum ledger. A
  -- commitment in COMMIT is not something anybody reverses.
  select count(*) into v_books
    from erp.journal x
    join erp.ledger l on l.tenant_id = x.tenant_id and l.id = x.ledger_id
   where x.tenant_id = v_tenant
     and x.document_id = p_document_id
     and x.status = 'posted'
     and x.reverses_journal_id is null
     and l.ledger_kind not in ('management', 'budget');

  if v_books = 0 then
    raise exception
      'CLOVEERP_NOTHING_WAS_POSTED: % has nothing in the books to reverse',
      d.document_number
      using errcode = '23514',
            hint = 'A document that has not reached a ledger is changed or cancelled '
                   'while it is still a draft. Check the document''s state: what it '
                   'carries may be a commitment in the memorandum ledger, which is '
                   'released by closing the order rather than by a reversal.';
  end if;

  select r.journal_number, r.posting_date into v_prior, v_prior_on
    from erp.journal r
    join erp.journal o on o.tenant_id = r.tenant_id and o.id = r.reverses_journal_id
   where r.tenant_id = v_tenant
     and o.document_id = p_document_id
     and r.status = 'posted'
   order by r.posting_date, r.id
   limit 1;

  if v_prior_on is not null then
    raise exception
      'CLOVEERP_ALREADY_REVERSED: the posting of % was reversed on % by journal %',
      d.document_number, v_prior_on, coalesce(v_prior, 'without a number yet')
      using errcode = '23505',
            hint = 'A posting is reversed once, or the ledger counts the correction '
                   'twice. Open the reversal to see it. If the original should stand '
                   'again, raise it again as a new document.';
  end if;

  for j in
    select x.* from erp.journal x
      join erp.ledger l on l.tenant_id = x.tenant_id and l.id = x.ledger_id
     where x.tenant_id = v_tenant
       and x.document_id = p_document_id
       and x.status = 'posted'
       and x.reverses_journal_id is null
       and l.ledger_kind not in ('management', 'budget')
     order by x.posting_date, x.id
  loop
    -- The product's one definition of whether a date may be posted into, called
    -- before anything is written so the refusal names the period and the next
    -- action rather than arriving from a trigger halfway through.
    perform erp.journal_period(j.ledger_id, v_on);

    v_event := erp.append_event(
      'document.posting_reversed', 'document', p_document_id,
      jsonb_build_object(
        'document_number',  d.document_number,
        'document_type',    dt.code,
        'reverses_journal', coalesce(j.journal_number, j.id::text),
        'posting_date',     v_on::text,
        'reason',           v_reason),
      d.entity_id, d.site_id);

    insert into erp.journal (
      tenant_id, entity_id, ledger_id, source_code, source_event_id, document_id,
      posting_date, description, status, reverses_journal_id, manual_reason,
      reference, created_by)
    values (
      v_tenant, j.entity_id, j.ledger_id, j.source_code, v_event, p_document_id,
      v_on,
      format('Reversal of %s: %s', coalesce(j.journal_number, d.document_number), v_reason),
      'draft', j.id, v_reason, d.document_number, v_me)
    returning id into v_new;

    -- The mirror image. Same accounts, same dimensions, same rule and version —
    -- the explanation of a figure is the rule that produced it — and the two
    -- sides swapped, so the pair nets to nothing and both stay readable.
    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate,
      dimensions, posting_rule_id, posting_rule_version, source_event_id,
      description)
    select v_tenant, v_new, l.line_no, l.account_id, l.credit_minor, l.debit_minor,
           l.currency, l.base_credit_minor, l.base_debit_minor, l.exchange_rate,
           l.dimensions, l.posting_rule_id, l.posting_rule_version, v_event,
           format('Reversal of %s', coalesce(l.description, 'the posting'))
      from erp.journal_line l
     where l.tenant_id = v_tenant and l.journal_id = j.id;

    -- And the detail behind the control accounts, for the same reason the bridge
    -- writes it in the same loop: a control account is the total of its own
    -- ledger, and a reversal that moved one without the other would part them.
    insert into erp.subledger_item (
      tenant_id, entity_id, ledger_id, control_kind, control_account_id,
      party_id, item_id, asset_code, document_id, journal_id, currency,
      debit_minor, credit_minor, due_date, posting_date)
    select v_tenant, s.entity_id, s.ledger_id, s.control_kind, s.control_account_id,
           s.party_id, s.item_id, s.asset_code, s.document_id, v_new, s.currency,
           s.credit_minor, s.debit_minor, s.due_date, v_on
      from erp.subledger_item s
     where s.tenant_id = v_tenant and s.journal_id = j.id;

    update erp.journal
       set status = 'posted', posted_at = now(), posted_by = v_me, updated_at = now()
     where tenant_id = v_tenant and id = v_new;

    v_ids := v_ids || v_new;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object(
    'document_id',       p_document_id,
    'document_number',   d.document_number,
    'posting_date',      v_on,
    'journals_reversed', v_n,
    'journal_ids',       to_jsonb(v_ids),
    'reason',            v_reason);
end;
$$;

revoke all on function erp.reverse_document_posting(uuid, text, date) from public, anon, authenticated;

comment on function erp.reverse_document_posting(uuid, text, date) is
  'Reverses what a document posted: a contra journal for each of its journals in '
  'a ledger that keeps the books, every line mirrored with the sides swapped and '
  'the subledger detail with it, dated p_posting_date (today by default) and '
  'carrying the reason. The original is never changed. Refuses a kind with '
  'another route (CLOVEERP_DOCUMENT_NOT_REVERSIBLE), a document that moved stock '
  '(CLOVEERP_REVERSAL_MOVED_STOCK), one that posted nothing '
  '(CLOVEERP_NOTHING_WAS_POSTED), a second reversal (CLOVEERP_ALREADY_REVERSED), '
  'no reason, a date after today, and a closed period.';

-- ── 5. The door ──────────────────────────────────────────────────────────────

create or replace function public.erp_reverse_document_posting(
  p_document_id  uuid,
  p_reason       text,
  p_posting_date date default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  return erp.reverse_document_posting(p_document_id, p_reason, p_posting_date);
end;
$$;

revoke all on function public.erp_reverse_document_posting(uuid, text, date) from public, anon;
grant execute on function public.erp_reverse_document_posting(uuid, text, date) to authenticated, service_role;

comment on function public.erp_reverse_document_posting(uuid, text, date) is
  'Under finance.post: reverses a posted invoice with a contra journal on its own '
  'date and its own reason, leaving the original in the record.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_reverse_document_posting', 'erp.reverse_document_posting',
   'Raises the contra journal that unmakes what an invoice posted, under '
   'finance.post — the permission that decides what date an entry reaches the '
   'ledger on. It writes erp.journal, erp.journal_line and erp.subledger_item, '
   'and nothing else: no existing journal, journal line, subledger row or '
   'document is changed, because a reversal is a new posting and that is the '
   'whole point of one.')
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

-- ── 6. What the refusals mean ────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_DOCUMENT_NOT_REVERSIBLE',
  'Reversing the posting of a document whose kind is undone some other way.',
  'Every kind of document that reaches the ledger has one way back, and it is not the same way for all of them. A goods receipt and a despatch moved goods, so they are undone by a credit note that moves the goods with the money. An order put a commitment in a memorandum ledger and nothing in the books. A credit note is already the reversal of something.',
  'Read what the refusal says to do instead: it names the route for that kind of document, which is a credit note for goods, cancelling or closing for an order, and raising the original again for a credit note.');

select erp.register_refusal(
  'CLOVEERP_REVERSAL_NEEDS_A_REASON',
  'Reversing a posting without saying why.',
  'A reversal is a second entry in the accounts, and six months later the only thing that distinguishes a correction from a mistake is the sentence somebody wrote at the time. Without it the ledger shows two entries and no explanation of either.',
  'Say why the posting is being unmade. It is kept on the reversing journal, beside who reversed it and when.');

select erp.register_refusal(
  'CLOVEERP_NOTHING_WAS_POSTED',
  'Reversing a document that never reached a ledger that keeps the books.',
  'A reversal unmakes a posting. A draft has not posted, and an order posts only a commitment into the memorandum ledger, which is outside the books by design.',
  'Check the document''s state. A draft is changed or cancelled where it stands; an order''s commitment is released by closing the order.');

select erp.register_refusal(
  'CLOVEERP_ALREADY_REVERSED',
  'Reversing a posting that has already been reversed.',
  'A posting reversed twice takes the correction out of the accounts twice, which leaves the ledger further from the truth than the original mistake did, and nothing downstream would say so.',
  'Open the reversal already against the document to see when and why it was made. If the original entry should stand again, raise it again as a new document rather than reversing the reversal.');

select erp.register_refusal(
  'CLOVEERP_REVERSAL_IN_THE_FUTURE',
  'Dating a reversal after today.',
  'A reversal dated ahead of itself is a forecast, and a forecast in the ledger is a figure the month end then has to explain away.',
  'Date the reversal today, or in an open period that has already happened.');

select erp.register_refusal(
  'CLOVEERP_REVERSAL_MOVED_STOCK',
  'Reversing the posting of a document that moved goods.',
  'The value of stock in the accounts and the stock the warehouse holds are held equal, and the month is closed on that being true. Unmaking the journal of a despatch or a receipt without moving the goods would break it on the first use.',
  'Raise a credit note against the document instead. It reverses the money and moves the goods back at what they cost, in one document, so the two never part.');

-- ── 7. The check that refuses the next silent dead end ───────────────────────

create or replace function erp.document_reversal_coverage_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- 1. A kind that reaches the ledger and says nothing about how it is undone.
  --    This is the whole reason the register exists: a document a person can
  --    post and cannot unpost is a defect, and it must not be able to arrive
  --    quietly.
  select 'a document kind reaches the ledger and says nothing about how it is undone',
         bt.code,
         'erp_ref.document_type.affects_finance is true and erp.document_reversal_route() '
         'has no row for it. Add one saying which route undoes it, or say why nothing does.'
    from erp_ref.document_type bt
   where bt.affects_finance
     and not exists (select 1 from erp.document_reversal_route() r
                      where r.base_type_code = bt.code)

  union all
  -- 2. A register row for a base type that does not exist.
  select 'the reversal register names a document kind that does not exist',
         r.base_type_code,
         'erp_ref.document_type has no such code. A register naming something renamed '
         'away reports green over nothing.'
    from erp.document_reversal_route() r
   where not exists (select 1 from erp_ref.document_type bt where bt.code = r.base_type_code)

  union all
  -- 3. A route nobody has taught the register to mean anything by.
  select 'the reversal register names a route that means nothing',
         r.base_type_code, format('route = %s', r.route)
    from erp.document_reversal_route() r
   where r.route not in ('reversal', 'credit_note', 'memorandum',
                         'is_itself_a_reversal', 'not_installed')

  union all
  -- 4. A row that says nothing a person can act on.
  select 'a reversal route says nothing a person can do next',
         r.base_type_code,
         'next_action and rationale are what the refusal says and what it is answerable '
         'for. A row with either missing is a register entry that reads as an answer and is not one.'
    from erp.document_reversal_route() r
   where coalesce(btrim(r.next_action), '') = ''
      or length(coalesce(btrim(r.rationale), '')) < 60

  union all
  -- 5. `reversal` claimed for a kind that moves stock. The instrument refuses
  --    one by name (CLOVEERP_REVERSAL_MOVED_STOCK), so the claim would be a lie
  --    the moment anybody took it up.
  select 'a kind is registered as reversible and moves stock, which the instrument refuses',
         r.base_type_code,
         'erp.reverse_document_posting() refuses a document that wrote a stock movement, '
         'because unmaking the journal alone would part inventory in the accounts from '
         'the stock ledger. Register this kind under credit_note instead.'
    from erp.document_reversal_route() r
    join erp_ref.document_type bt on bt.code = r.base_type_code
   where r.route = 'reversal' and bt.affects_stock

  union all
  -- 6. `reversal` claimed while the instrument does not read this register.
  --    One row, not per kind: the instrument decides what it accepts by asking
  --    the register, and if it ever stops, every claim here becomes decoration.
  select 'the register says a kind is reversible and the instrument does not read the register',
         'erp.reverse_document_posting',
         'Its source no longer mentions erp.document_reversal_route(), so what it accepts '
         'and what this register claims are two different answers.'
    from (select 1) as t(x)
   where exists (select 1 from erp.document_reversal_route() r where r.route = 'reversal')
     and not exists (
       select 1 from pg_catalog.pg_proc p
         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'erp' and p.proname = 'reverse_document_posting'
          and position('document_reversal_route' in p.prosrc) > 0)

  union all
  -- 7. `credit_note` claimed and no credit note routine takes that kind. The
  --    same substring test erp.public_api_report() makes of a door and its gate.
  select 'a kind is registered as undone by a credit note and no credit note routine takes it',
         r.base_type_code,
         'Neither erp.raise_customer_credit_note() nor erp.raise_supplier_credit_note() '
         'names this base type, so the route the refusal offers does not exist.'
    from erp.document_reversal_route() r
   where r.route = 'credit_note'
     and not exists (
       select 1 from pg_catalog.pg_proc p
         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'erp'
          and p.proname in ('raise_customer_credit_note', 'raise_supplier_credit_note')
          and position('''' || r.base_type_code || '''' in p.prosrc) > 0)

  union all
  -- 8. `memorandum` claimed and some organisation posts that kind into a ledger
  --    that keeps the books. "Nothing reaches the accounts" is a claim about
  --    configuration, and configuration is per organisation.
  select 'a kind is registered as memorandum and posts into a ledger that keeps the books',
         dt.code,
         format('%s names posting rule %s, whose ledger %s is of kind %s',
                dt.code, pr.code, l.code, l.ledger_kind)
    from erp.document_reversal_route() r
    join erp.document_type dt
      on dt.base_type_code = r.base_type_code and dt.status = 'active'
    join erp.posting_rule pr
      on pr.tenant_id = dt.tenant_id and pr.code = dt.posting_rule_code
     and pr.status = 'active'
    join erp.ledger l on l.tenant_id = pr.tenant_id and l.id = pr.ledger_id
   where r.route = 'memorandum'
     and l.ledger_kind not in ('management', 'budget')

  union all
  -- 9. `not_installed` claimed and somebody has installed one. The row was true
  --    when it was written; this is what stops it staying on the register after
  --    it stops being true.
  select 'a kind is registered as not installed and an organisation holds a document type of it',
         dt.code,
         format('erp.document_type %s is on base type %s. Give that base type a real '
                'route before anything posts one.', dt.code, r.base_type_code)
    from erp.document_reversal_route() r
    join erp.document_type dt on dt.base_type_code = r.base_type_code
   where r.route = 'not_installed'
$$;

revoke all on function erp.document_reversal_coverage_report() from public, anon, authenticated;

comment on function erp.document_reversal_coverage_report() is
  'Every way the reversal register and the product could have come apart: a '
  'posting kind with no route, a route that claims something the instrument or '
  'the credit notes do not do, a memorandum claim contradicted by a posting rule, '
  'and a not-installed claim contradicted by an installed type.';

create or replace function erp.assert_every_posting_can_be_undone()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_kinds integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.document_reversal_coverage_report();

  if v_count > 0 then
    raise exception 'CLOVEERP_POSTING_CANNOT_BE_UNDONE: % finding(s)', v_count
      using errcode = 'P0001',
            detail = v_detail,
            hint = 'A document a person can post and cannot unpost is a dead end, and '
                   'the whole purpose of erp.document_reversal_route() is that one '
                   'cannot arrive quietly. Give the kind a route, or correct the claim '
                   'the register makes about it.';
  end if;

  select count(*) into v_kinds
    from erp_ref.document_type bt where bt.affects_finance;

  return format('every posting kind has a way back: %s kind(s) reach the ledger, '
                'each with a route on the register', v_kinds);
end;
$$;

revoke all on function erp.assert_every_posting_can_be_undone() from public, anon;

comment on function erp.assert_every_posting_can_be_undone() is
  'Refuses a document kind that can be posted and has no way back — no reversal, '
  'no credit note, and no written reason why neither applies. Also holds every '
  'claim the register makes to what the product actually does, so a route cannot '
  'go stale silently.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('every_posting_can_be_undone', 'Every posting has a way back', 'assertion', 'platform', 'erp',
   'assert_every_posting_can_be_undone', '', 'document_reversal_coverage_report', '',
   'Every kind of document that reaches the ledger says how a posting of it is undone: '
   'reversed with a contra journal, credited with a credit note that moves the goods too, '
   'posted only into the memorandum ledger, already a reversal itself, or not built yet. '
   'A kind that can be posted and cannot be unposted fails the build.',
   true, 98)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- CLOVEERP_POSTING_CANNOT_BE_UNDONE is not registered in erp_ref.refusal. It is
-- raised only by an assert_ routine, which erp.refusal_report() deliberately does
-- not count as a raise — the build is what acts on it — so a register row would
-- read as raised nowhere and refuse this migration. Its next action travels as
-- the hint on the raise, which is where whoever reads a failed build sees it.
-- erp.assert_ageing_equals_control() (20260918510000) does the same.

-- ── 8. The words on the screen ───────────────────────────────────────────────
--
-- The door lives on the document a person is already looking at: you reverse an
-- invoice from the invoice. /documents has never carried a help topic, so a door
-- rendered on the document screen is registered under the module it belongs to,
-- and deciding what date an entry reaches the ledger on is finance's.

select erp_meta.add_help_actions('/finance', array['erp_reverse_document_posting']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Reverse what this invoice posted',
     'The dialog raised from a posted sales invoice or purchase invoice (20260919930000).'),
    ('The opposite journal is posted on the date you give, the invoice stays exactly as it is, and what it was worth comes off the ageing. Nothing already posted is rewritten.',
     'Said under that heading, because all four consequences land on different screens and a person is owed them before pressing it rather than afterwards.'),
    ('Why it is being reversed',
     'The reason on a reversal, which is required: six months later it is the only thing that tells a correction from a mistake.'),
    ('Kept on the reversing journal beside who reversed it and when. A bill keyed against the wrong supplier, an invoice raised twice, a price entered wrong.',
     'Said under the reason, because the examples are what make somebody write a useful one.'),
    ('The date it is reversed on',
     'The posting date of the reversal, which is its own and not the invoice''s.'),
    ('Today unless you say otherwise. A posting made last month and reversed this month belongs in this month; a month that is closed refuses it and says so.',
     'Said under the date, because dating a reversal back into the month of the original is the mistake this field exists to prevent.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ── 9. The screen sees the reversal ─────────────────────────────────────────
--
-- Without this the reversal is right and invisible: the invoice would still
-- read "registered" for its full value with nothing on it saying the posting
-- had been unmade, and the button that unmakes it would still be offered to
-- somebody the database is about to refuse. Needled rather than re-emitted,
-- because this body is 20260916030000's and 20260916510000's and not this
-- migration's to restate.

do $document$
declare
  v_sig    constant text := 'public.erp_document(uuid)';
  v_def    text := pg_get_functiondef('public.erp_document(uuid)'::regprocedure);
  v_needle constant text := $needle$    'available_transitions', public.erp_available_transitions(p_document_id))$needle$;
  v_new    constant text := $new$    'reversal', coalesce((
      select jsonb_agg(jsonb_build_object(
        'journal_id', r.journal_id, 'journal_number', r.journal_number,
        'posting_date', r.posting_date, 'reason', r.reason,
        'reversed_at', r.reversed_at,
        'reverses_journal_number', r.reverses_journal_number)
        order by r.posting_date)
        from erp.document_posting_reversal(p_document_id) r), '[]'::jsonb),
    'available_transitions', public.erp_available_transitions(p_document_id))$new$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not close on its available transitions exactly once as 20260916030000 wrote it', v_sig
      using hint = 'A later migration changed the document reader. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);

  if position('document_posting_reversal' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: the document reader did not take the reversal'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the reader.';
  end if;
end
$document$;

-- ── 10. The suite ────────────────────────────────────────────────────────────

create or replace function erp_test.document_reversal_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 18;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_cust uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid;
  v_so uuid; v_sol uuid; v_dn uuid; v_sinv uuid;
  v_pinv uuid; v_draft uuid;
  v_gl uuid; v_cal_start date; v_back date; v_old_period uuid;
  v_ap text;
  v_ap_before bigint; v_ap_after bigint; v_ap_reversed bigint;
  v_off integer; v_lines integer; v_sub bigint;
  v_orig_j uuid; v_orig_on date; v_orig_period uuid; v_orig_lines integer; v_orig_status text;
  v_rev record;
  v_rev_period uuid;
  v_res jsonb;
  v_msg text; v_ok boolean;
  v_me uuid; v_today date;
begin
  begin
    v_step := 'an organisation that buys, sells and keeps books';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzrv-' || v_tag, 'Reversal Suite',
      'admin@zzrv-' || v_tag || '.test', 'Reversal Suite Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzrv-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();

    v_me    := erp.current_principal_id();
    v_ap    := erp.tenant_account_code('trade_payable');

    -- A period before the installed calendar, so a bill can sit in a month that
    -- is not this one. Taken from the calendar rather than from a number of days
    -- back, because the fiscal year may start in any month and a suite that
    -- reads the clock instead of the configuration flakes one January.
    v_step := 'a month before the calendar the installer laid out';
    select l.id, min(fp.starts_on) into v_gl, v_cal_start
      from erp.fiscal_period fp
      join erp.ledger l on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
     where fp.tenant_id = rb.tenant_id and l.is_primary
     group by l.id;
    v_back := v_cal_start - 1;
    insert into erp.fiscal_period (
      tenant_id, ledger_id, code, fiscal_year, period_number,
      starts_on, ends_on, status)
    values (rb.tenant_id, v_gl, 'ZZPRIOR',
            extract(year from v_back)::integer, 13,
            (v_cal_start - interval '1 month')::date, v_back, 'open')
    returning id into v_old_period;

    -- The rules were promoted today, and a document dated before that would find
    -- no version in force. Moving the promotion back is a fixture detail, not a
    -- claim about anything: the demonstration's own seeder has the same need.
    update erp.posting_rule
       set effective_from = (v_cal_start - interval '2 months')::date
     where tenant_id = rb.tenant_id;

    v_step := 'its own unit, site, places, supplier, customer and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZREA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZRSITE', 'Reversal suite site', 'warehouse', 'active')
    returning id into v_site;

    -- The day the suite means everywhere below, read the way the instrument
    -- reads it (#198): the site's timezone, then the organisation's, then UTC.
    -- current_date here would be the database's day, and the two can be
    -- different days for an hour of every night.
    v_today := erp.local_today(v_site);
    perform erp.create_location(v_site, 'ZR-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZR-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZRSUP', 'Reversal Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZRCUS', 'Reversal Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer',
            jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRWID', 'Reversal Suite Widget', v_uom, 'active')
    returning id into v_item;

    -- ── 1. The register answers for every kind that reaches the ledger ──────
    v_step := 'the register';
    v_cases := v_cases + 1;
    case_name := 'every kind of document that reaches the ledger says how a posting of it is undone';
    begin
      perform erp.assert_every_posting_can_be_undone();
      passed := v_state is null;
      detail := 'erp.assert_every_posting_can_be_undone() found nothing: no posting kind is a dead end';
    exception when others then
      passed := false; detail := left(sqlerrm, 200);
    end;
    return next;

    -- ── The month: a hundred bought at a tenner, billed in the month before ──
    v_step := 'a hundred widgets arrive at ten pounds each';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets');
    perform erp.transition_document(v_po, 'submit', 'reversal suite');
    perform erp_test.approve_document(v_po, 'reversal suite');
    perform erp.transition_document(v_po, 'send', 'reversal suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'reversal suite');

    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_ap_before
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.status = 'posted' and a.code = v_ap;

    v_step := 'the supplier bills the hundred, in the month before this one';
    v_pinv := erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup, v_back);
    perform erp.invoice_against(v_pinv, v_pol, 100, 1000);
    perform erp.transition_document(v_pinv, 'register', 'reversal suite');

    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_ap_after
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.status = 'posted' and a.code = v_ap;

    v_cases := v_cases + 1;
    case_name := 'the bill posts what the supplier is owed';
    passed := v_state is null and v_ap_after - v_ap_before = 100000;
    detail := format('%s on %s, against %s before the bill', v_ap_after - v_ap_before, v_ap, v_ap_before);
    return next;

    select j.id, j.posting_date, j.fiscal_period_id, j.status::text
      into v_orig_j, v_orig_on, v_orig_period, v_orig_status
      from erp.journal j
     where j.tenant_id = rb.tenant_id and j.document_id = v_pinv;
    select count(*) into v_orig_lines from erp.journal_line l
     where l.tenant_id = rb.tenant_id and l.journal_id = v_orig_j;

    -- ── 2, 3, 4, 5, 6, 7. The reversal ──────────────────────────────────────
    v_step := 'reversing the bill, today';
    v_res := erp.reverse_document_posting(
               v_pinv, 'Keyed against the wrong supplier', v_today);

    select count(*) into v_off
      from (select jl.account_id
              from erp.journal j
              join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
             where j.tenant_id = rb.tenant_id and j.document_id = v_pinv
               and j.status = 'posted'
             group by jl.account_id
            having sum(jl.debit_minor - jl.credit_minor) <> 0) x;
    select count(*) into v_lines
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
     where j.tenant_id = rb.tenant_id and j.document_id = v_pinv and j.status = 'posted';

    v_cases := v_cases + 1;
    case_name := 'the pair nets to nothing, account by account, and not merely in total';
    passed := v_state is null and v_off = 0 and v_lines = v_orig_lines * 2;
    detail := format('%s account(s) left with a balance across %s line(s), which is %s doubled',
                     v_off, v_lines, v_orig_lines);
    return next;

    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0) into v_ap_reversed
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.status = 'posted' and a.code = v_ap;

    v_cases := v_cases + 1;
    case_name := 'what the supplier is owed goes back to where it was before the bill';
    passed := v_state is null and v_ap_reversed = v_ap_before;
    detail := format('%s on %s, which is what stood before the bill (%s)', v_ap_reversed, v_ap, v_ap_before);
    return next;

    select coalesce(sum(s.debit_minor - s.credit_minor), 0) into v_sub
      from erp.subledger_item s
     where s.tenant_id = rb.tenant_id and s.document_id = v_pinv;

    v_cases := v_cases + 1;
    case_name := 'the purchase ledger nets to nothing too, so the bill leaves the ageing and the control account still agrees with it';
    passed := v_state is null and v_sub = 0
          and exists (select 1 from erp.subledger_item s
                       where s.tenant_id = rb.tenant_id and s.document_id = v_pinv);
    detail := format('%s owed on the document across %s subledger row(s)', v_sub,
                     (select count(*) from erp.subledger_item s
                       where s.tenant_id = rb.tenant_id and s.document_id = v_pinv));
    return next;

    select * into v_rev from erp.document_posting_reversal(v_pinv) limit 1;
    select j.fiscal_period_id into v_rev_period
      from erp.journal j where j.tenant_id = rb.tenant_id and j.id = v_rev.journal_id;

    v_cases := v_cases + 1;
    case_name := 'the reversal posts in the period it is dated in, not the one the bill sits in';
    passed := v_state is null
          and v_rev.posting_date = v_today
          and v_orig_on = v_back
          and v_rev_period is not null
          and v_rev_period is distinct from v_orig_period;
    detail := format('the bill is dated %s in period %s, the reversal %s in period %s',
                     v_orig_on, v_orig_period, v_rev.posting_date, v_rev_period);
    return next;

    v_cases := v_cases + 1;
    case_name := 'the reversal says who reversed it, when, and why';
    passed := v_state is null
          and v_rev.reason = 'Keyed against the wrong supplier'
          and v_rev.reversed_by = v_me
          and v_rev.reversed_at is not null;
    detail := format('reversed by %s at %s for "%s"', v_rev.reversed_by, v_rev.reversed_at, v_rev.reason);
    return next;

    v_cases := v_cases + 1;
    case_name := 'the original is reachable from the reversal, and the reversal from the original';
    passed := v_state is null
          and v_rev.reverses_journal_id = v_orig_j
          and v_rev.journal_id = (v_res -> 'journal_ids' ->> 0)::uuid;
    detail := format('journal %s reverses journal %s, both naming the bill',
                     v_rev.journal_number, v_rev.reverses_journal_number);
    return next;

    select j.status::text, j.posting_date into v_orig_status, v_orig_on
      from erp.journal j where j.tenant_id = rb.tenant_id and j.id = v_orig_j;
    select count(*) into v_lines from erp.journal_line l
     where l.tenant_id = rb.tenant_id and l.journal_id = v_orig_j;

    v_cases := v_cases + 1;
    case_name := 'and nothing already posted was rewritten: the original journal stands where it was';
    passed := v_state is null and v_orig_status = 'posted'
          and v_orig_on = v_back and v_lines = v_orig_lines;
    detail := format('the bill''s journal is still %s, dated %s, on %s line(s)',
                     v_orig_status, v_orig_on, v_lines);
    return next;

    -- ── 8. Twice is refused ─────────────────────────────────────────────────
    v_step := 'reversing it a second time';
    begin
      perform erp.reverse_document_posting(v_pinv, 'And again', v_today);
      v_ok := false; v_msg := 'it was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_ALREADY_REVERSED%';
      v_msg := left(sqlerrm, 150);
    end;

    v_cases := v_cases + 1;
    case_name := 'a posting reversed twice would take the correction out twice, so the second is refused by name';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    -- ── 9, 10, 11, 12. The other refusals ───────────────────────────────────
    v_step := 'reversing without a reason';
    v_draft := erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup, v_today);
    perform erp.add_document_line(v_draft, v_item, 1, 1000, 'a line nobody has registered');
    begin
      perform erp.reverse_document_posting(v_draft, '   ', v_today);
      v_ok := false; v_msg := 'it was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_REVERSAL_NEEDS_A_REASON%';
      v_msg := left(sqlerrm, 150);
    end;

    v_cases := v_cases + 1;
    case_name := 'a reversal with nothing said about why is refused before anything else is judged';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    v_step := 'reversing a goods receipt';
    begin
      perform erp.reverse_document_posting(v_grn, 'The goods were never any good', v_today);
      v_ok := false; v_msg := 'it was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_REVERSAL_MOVED_STOCK%'
           or sqlerrm like 'CLOVEERP_DOCUMENT_NOT_REVERSIBLE%';
      v_msg := left(sqlerrm, 150);
    end;

    v_cases := v_cases + 1;
    case_name := 'a goods receipt is refused and sent to the credit note, which moves the goods back with the money';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    v_step := 'dating a reversal after today';
    begin
      perform erp.reverse_document_posting(v_draft, 'Tomorrow', v_today + 1);
      v_ok := false; v_msg := 'it was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_REVERSAL_IN_THE_FUTURE%';
      v_msg := left(sqlerrm, 150);
    end;

    v_cases := v_cases + 1;
    case_name := 'a reversal dated after today is a forecast, and is refused';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    v_step := 'reversing a draft';
    begin
      perform erp.reverse_document_posting(v_draft, 'Nothing has happened yet', v_today);
      v_ok := false; v_msg := 'it was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NOTHING_WAS_POSTED%';
      v_msg := left(sqlerrm, 150);
    end;

    v_cases := v_cases + 1;
    case_name := 'a bill still in draft has nothing in the books to reverse, and is told so';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    -- ── 13, 14, 15. The sell side, and a closed month ───────────────────────
    v_step := 'ten are sold at twenty-five pounds each, despatched and invoiced';
    v_so := erp.open_document('sales_order', v_cust, rb.entity_id, v_site);
    v_sol := erp.add_document_line(v_so, v_item, 10, 2500, 'ten widgets');
    perform erp.transition_document(v_so, 'submit', 'reversal suite');
    perform erp_test.approve_document(v_so, 'reversal suite');
    v_dn := (erp.create_delivery_from_order(v_so) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'reversal suite');
    v_sinv := erp.invoice_from_delivery(v_dn, true);
    perform erp.transition_document(v_sinv, 'issue', 'reversal suite');

    v_step := 'closing the month the bill sat in, and reversing into it';
    update erp.fiscal_period set status = 'closed', closed_at = clock_timestamp()
     where tenant_id = rb.tenant_id and id = v_old_period;
    begin
      perform erp.reverse_document_posting(v_sinv, 'Raised against the wrong customer', v_back);
      v_ok := false; v_msg := 'it was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_JOURNAL_PERIOD_CLOSED%';
      v_msg := left(sqlerrm, 200);
    end;

    v_cases := v_cases + 1;
    case_name := 'a closed month refuses the reversal and names the next action, so a date is not a way round the close';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    v_step := 'and posting it in the open month instead';
    v_res := erp.reverse_document_posting(
               v_sinv, 'Raised against the wrong customer', v_today);

    select count(*) into v_off
      from (select jl.account_id
              from erp.journal j
              join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
             where j.tenant_id = rb.tenant_id and j.document_id = v_sinv
               and j.status = 'posted'
             group by jl.account_id
            having sum(jl.debit_minor - jl.credit_minor) <> 0) x;
    select coalesce(sum(s.debit_minor - s.credit_minor), 0) into v_sub
      from erp.subledger_item s
     where s.tenant_id = rb.tenant_id and s.document_id = v_sinv;

    v_cases := v_cases + 1;
    case_name := 'the same instrument reverses a sales invoice, revenue and tax and the customer''s debt together';
    passed := v_state is null and v_off = 0 and v_sub = 0
          and (v_res ->> 'journals_reversed')::integer = 1;
    detail := format('%s account(s) left with a balance, %s owed on the sales ledger, %s journal(s) reversed',
                     v_off, v_sub, v_res ->> 'journals_reversed');
    return next;

    v_cases := v_cases + 1;
    case_name := 'and the despatch that sent the goods is untouched, because reversing the bill is not taking the goods back';
    passed := v_state is null
          and (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                where b.tenant_id = rb.tenant_id and b.item_id = v_item) = 90;
    detail := format('the shelf still holds %s of the hundred',
                     (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                       where b.tenant_id = rb.tenant_id and b.item_id = v_item));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzrv-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzrv rolled back with its bills, its journals and its reversals');
  return next;

  -- The count guard says what stopped the fixture. Without this the wrapper
  -- never sees a row, so the message this suite caught into v_state — and the
  -- step that produced it — never reaches the build log, and every break costs
  -- a run to find.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_DOCUMENT_REVERSAL_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.document_reversal_suite() from public, anon;

create or replace function erp_test.assert_document_reversal_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 18;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _document_reversal on commit drop as
    select * from erp_test.document_reversal_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _document_reversal;
  drop table _document_reversal;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DOCUMENT_REVERSAL_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_DOCUMENT_REVERSAL_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a posting is reversed, not edited: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_document_reversal_suite() from public, anon;

-- ── 11. The generators, then the checks that read what changed ──────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_guidance_sound();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_no_dead_configuration();

-- The register, against the product it describes.
select erp.assert_every_posting_can_be_undone();

-- And the reversal itself, on both invoices, in its own period, twice refused.
select erp_test.assert_document_reversal_suite();
