-- The interview offers its answers.
--
-- The onboarding interview asked thirty-three questions and offered nothing to
-- pick from. "Which departments own or approve spending?" sat above an empty
-- box while the base pack held fourteen departments with their cost centres;
-- the legislation question wanted a pack code (gb_vat) nobody setting up an
-- organisation could know; the goods-receipt question wanted an account number
-- from a chart the person had not seen and, before finance, did not exist.
-- Every answer was typed, and an interview where every answer is typed is an
-- interview that is abandoned at the third question.
--
-- Putting answers in front of people meant reading what an answer turns into,
-- and that found seven faults under the empty boxes:
--
--   * approval.object_type offered 'journal', which matches no document type,
--     so a band on it could never be consulted; approval.currency offered
--     three currencies of the twenty-five the register holds.
--   * A list element picked with its code — FIN, SUP_DOM, WORKS_ORDER_TYPE —
--     had nowhere to carry it: the proposer read every element as a string and
--     slugged it, SUP_DOM landing as SUP-DOM and an object slugging its whole
--     JSON text.
--   * The pair reader behind identity-by-class and allocation-by-site read
--     positions and two legacy key names, so {left,right} — the shape every
--     other pair question and the screen use — was skipped without a word.
--   * The approval threshold was multiplied by 100 whatever the currency: a
--     yen band sat a hundred times too high.
--   * A gate two levels up was not followed. org.currencies "applied" after
--     org.multi_company was answered no, because its own gate, org.companies,
--     had been answered earlier; and propose read every stored answer whether
--     its question applied or not.
--   * A single-company organisation could not set its own company's country,
--     currency, language or tax rules: all four sat behind "more than one
--     company", and the proposer only ever looked at companies it was creating.
--   * Two sessions proposed in the same second collided on the change-set
--     code, which was the section and a timestamp.
--
-- What changes:
--
--   1. The bank speaks plainly and asks one more thing. Every prompt and help
--      text is rewritten for someone who is not an accountant and seeded as a
--      resource under the key the bank already named; org.chart asks how
--      nominal accounts are numbered, in B.7 where the rest of the
--      organisation's shape is, so section codes and the suites that pin them
--      stay as they are. org.countries, org.currencies, org.locales and
--      org.legislation no longer wait for org.companies.
--   2. erp_ref.interview_suggestion holds what each question offers: plain
--      labels and one-line meanings for every choice and yes/no, the twelve
--      months, a few examples, and — inserted from erp_ref.pack_item here, so
--      they cannot drift from the packs — departments, accounting codes,
--      classification groupings and values, and role templates, each carrying
--      the feature its pack needs. Its label column is label_key, not
--      name_key: the two-language coverage check reads every name_key column,
--      and these words are English until someone translates them.
--   3. erp.capability_on_plan(), the yes-or-no half of
--      erp.require_capability_on_plan(), which now calls it: the screen needs
--      to grey out the statutory numbering on a plan without it, and asking
--      must neither raise nor record a refusal.
--   4. erp.interview_effective_answers() — only the answers whose question
--      applies, following every gate to the root — and erp.interview_questions()
--      rebuilt on it, returning what it returned plus the gate, the
--      suggestions, the left-hand things a pair question pairs, a likely answer
--      worked out for this organisation, and an example. Likely answers are
--      computed each time they are read and never written: an interview with
--      no answers still proposes nothing.
--   5. erp.answer_interview() reads "5,000" as five thousand, clears an answer
--      given as JSON null, refuses a missing answer by name, refuses a
--      fractional whole number before the proposer's cast could, and asks the
--      plan before accepting the statutory numbering. The door turns the SQL
--      null PostgREST makes of a JSON null into the clear.
--   6. Both proposers re-emitted from their live bodies with only these
--      changes: effective answers; {code,name} elements keep their code; the
--      pair reader reads {left,right}; a statutory numbering answer adds the
--      feature to B.7, refused when accounts already exist; an existing
--      company not listed as new still takes its tax rules, and its currency,
--      country, language and financial year while its books are not set up;
--      the threshold follows the currency's minor units; the change-set code
--      carries the session; and each proposal records its session and section
--      in two new columns, backfilled by the title it has always carried.
--   7. Two reads for the screen: public.erp_interview_sessions(), to resume an
--      interview and see where each section's changes stand, and
--      public.erp_change_set_items(), the lines of a change in the order the
--      promoter applies them.
--
-- Proof: the nineteen-case interview suite, the companies and legislation
-- suites, which drive B.7 through the doors, and the build's structural
-- assertions, all run at the end of this file.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The question bank, in plain words, with the numbering question
-- ═════════════════════════════════════════════════════════════════════════════

-- The numbering question sits after the fiscal year and before tax rules, so
-- everything from org.legislation on moves down one place.
do $renumber$
declare
  v_n integer;
begin
  with target (code, seq) as (values
    ('org.legislation', 77), ('org.costing_method', 78), ('org.identity_level', 79),
    ('org.allocation_method', 80), ('org.consignment', 81), ('org.policies_differ', 82),
    ('org.identity_by_class', 83), ('org.allocation_by_site', 84)
  ), moved as (
    update erp_ref.interview_question q set seq = t.seq
      from target t where q.code = t.code
    returning 1
  )
  select count(*) into v_n from moved;
  if v_n <> 8 then
    raise exception 'CLOVEERP_INTERVIEW_BANK_UNEXPECTED: % of 8 B.7 questions were found to renumber', v_n;
  end if;
end
$renumber$;

insert into erp_ref.interview_question
  (code, section, surface, seq, prompt, prompt_key, help, answer_shape, choices, maps_to, applies_when, is_required) values
  ('org.chart', 'B.7', 'capability', 76,
   'How should your nominal accounts be numbered?',
   'interview.org.chart',
   'Standard numbering is ready to use. Statutory numbering follows the ranges some countries'' rules set out. Choose before your books are set up: once they are, the numbering stays.',
   'choice', '["standard","statutory"]'::jsonb, 'capability', null, false)
on conflict (code) do update
  set section = excluded.section, surface = excluded.surface, seq = excluded.seq, prompt = excluded.prompt,
      prompt_key = excluded.prompt_key, help = excluded.help, answer_shape = excluded.answer_shape,
      choices = excluded.choices, maps_to = excluded.maps_to, applies_when = excluded.applies_when,
      is_required = excluded.is_required;

-- Every prompt and help text, for someone setting up a business rather than a
-- ledger. The resource rows further down are seeded from these columns, so the
-- two cannot say different things on the day they ship.
do $plain$
declare
  v_n integer;
begin
  with plain (code, prompt, help) as (values
    ('dept.list',
     'Which departments spend money or approve spending?',
     'Pick from the list or type your own. Name the teams that decide on spending, not every team you have: approval rules hang off these.'),
    ('approval.needed',
     'Does any document need someone''s sign-off before it counts?',
     'Answer yes if a purchase order, an invoice or another document must be signed off before it takes effect. You choose which document, and above what value, next.'),
    ('approval.object_type',
     'Which document needs sign-off?',
     'The kind of document the sign-off applies to. Sign-off for other documents can be added later.'),
    ('approval.currency',
     'Which currency is the sign-off value in?',
     'The value you give next is read in this currency. A document in another currency is converted before it is compared.'),
    ('approval.threshold',
     'Above what value does it need sign-off?',
     'In whole amounts of the currency above, such as 5,000. Below this value nobody is asked to sign off.'),
    ('approval.role',
     'Which role signs it off?',
     'Pick a role, or type its code as it appears on the Permissions screen. Leave it blank and answer yes to the next question to have the manager of the person who raised it sign off instead.'),
    ('approval.line_manager',
     'Should the manager of the person who raised it sign off too?',
     'Yes adds the manager of the person who raised the document. If you named no role above, the manager is the only one who signs off.'),
    ('posting.item_classes',
     'Which kinds of product need their own accounting code?',
     'Pick from the list or type your own. Give two kinds of product separate codes when their sales, costs or stock should land in different nominal accounts.'),
    ('posting.party_classes',
     'Which kinds of supplier and customer need their own accounting code?',
     'Pick from the list or type your own, such as domestic, EU or companies in your own group.'),
    ('posting.receipt_account',
     'When goods arrive, which nominal account does their value go to?',
     'Pick the nominal account for stock, or type its number. Nothing is parked in a holding account: a transaction with no rule behind it is refused, so this is asked rather than guessed.'),
    ('classification.axes',
     'How do you group products for search and reports?',
     'Pick from the list or type your own, such as brand, product family or storage condition.'),
    ('classification.mandatory',
     'Must every product have a value for each of these groupings?',
     'Yes means a product cannot be saved without a value for every grouping you listed. Most organisations make only product type compulsory.'),
    ('classification.values',
     'Which values does each grouping have?',
     'One row per value: the grouping on the left, the value on the right, such as Storage condition and Frozen.'),
    ('code.wanted',
     'Should new product codes follow a pattern?',
     'Answer yes to have codes issued automatically, rather than typed in by whoever adds the product.'),
    ('code.prefix',
     'What should a product code start with?',
     'A few letters that every new product code begins with.'),
    ('code.digits',
     'How many digits follow it?',
     'How long the running number after the letters is. Five digits allows 99,999 products, such as IT00001.'),
    ('release.areas',
     'Where is stock gathered before it is picked, packed or despatched?',
     'Pick from the list or type your own. These marshalling areas belong to a site, so a site must exist first.'),
    ('release.mode',
     'When an order needs more than an area holds, what should be brought in?',
     'Bring in just the shortfall, or top the area up to its maximum. Until a maximum is set, topping up works like bringing in the shortfall.'),
    ('release.ageing_hours',
     'After how many hours should unused stock go back to storage?',
     'Stock left in a marshalling area longer than this, and not needed by an open pick, is sent back to storage.'),
    ('org.multi_company',
     'Does your organisation trade as more than one company?',
     'A company here is a business registered in its own right, with its own books, currency and country. Several companies under one organisation is ordinary.'),
    ('org.companies',
     'Which other companies do you run?',
     'One row per company: a short code on the left, the trading name on the right. Your first company already exists and does not need adding.'),
    ('org.currencies',
     'Which currency does each company keep its books in?',
     'Company on the left, currency on the right. A new company you leave out takes your first company''s currency. A company whose books are already set up keeps its currency.'),
    ('org.countries',
     'Which country is each company registered in?',
     'Company on the left, country on the right. The country decides which tax rules are suggested.'),
    ('org.locales',
     'Which language does each company use for its reports and documents?',
     'Company on the left, language on the right, such as English for Ireland, or German.'),
    ('org.fiscal_year_start',
     'In which month does your financial year start?',
     'Applies to new companies, and to existing companies whose books are not set up yet.'),
    ('org.chart',
     'How should your nominal accounts be numbered?',
     'Standard numbering is ready to use. Statutory numbering follows the ranges some countries'' rules set out. Choose before your books are set up: once they are, the numbering stays.'),
    ('org.legislation',
     'Which tax rules apply to each company?',
     'Company on the left, the tax rules on the right, such as United Kingdom VAT. A company in a country with no rules listed can be left out.'),
    ('org.costing_method',
     'How should stock be valued by default?',
     'Average cost updates one cost per product with every delivery. Standard cost uses a cost you set and shows any difference from what you paid separately. First in, first out values stock at what the oldest remaining delivery cost.'),
    ('org.identity_level',
     'Do you label stock in larger units, such as cases or pallets, so they can be scanned as one?',
     'Choose no labels if stock is identified by product, batch and serial number only. Otherwise choose the smallest thing you label.'),
    ('org.allocation_method',
     'Which stock should be picked first for an order?',
     'Stock with an expiry date is always picked earliest expiry first. For everything else, choose oldest or newest stock first.'),
    ('org.consignment',
     'Do you hold stock you do not own, or keep your stock at someone else''s site?',
     'For example stock a supplier owns until you use it, goods made for a customer from their materials, or stock kept by a logistics provider. Who owns stock and who holds it are both recorded.'),
    ('org.policies_differ',
     'Does labelling or picking differ by kind of product or by site?',
     'Most organisations answer no. Answer yes if, say, a cold store picks by expiry while the rest picks oldest first, or finished goods go on pallets while raw materials stay loose.'),
    ('org.identity_by_class',
     'Which kinds of product are labelled differently, and at what level?',
     'One row per kind of product: its accounting code on the left, such as FG for finished goods, and the label level on the right.'),
    ('org.allocation_by_site',
     'Which sites pick stock differently, and how?',
     'One row per site: the site on the left, oldest or newest stock first on the right. Stock with an expiry date is always picked earliest expiry first.')
  ), updated as (
    update erp_ref.interview_question q
       set prompt = p.prompt, help = p.help
      from plain p
     where q.code = p.code
    returning 1
  )
  select count(*) into v_n from updated;
  if v_n <> 34 then
    raise exception 'CLOVEERP_INTERVIEW_BANK_UNEXPECTED: % of 34 questions were found to reword', v_n;
  end if;
end
$plain$;

-- Tax rules, currency, country and language apply to the company that already
-- exists as much as to new ones, so they no longer wait for a list of new
-- companies. And an answer about currency, country, language or the financial
-- year now becomes a change to a company, so the section is proposed for it.
update erp_ref.interview_question set applies_when = null
 where code in ('org.countries', 'org.currencies', 'org.locales', 'org.legislation');
update erp_ref.interview_question set maps_to = 'entity'
 where code in ('org.countries', 'org.currencies', 'org.locales', 'org.fiscal_year_start');

-- 'journal' matched no document type, so a band on it was never consulted; a
-- requisition is the document most organisations approve first.
update erp_ref.interview_question
   set choices = '["requisition","purchase_order","purchase_invoice","sales_order"]'::jsonb
 where code = 'approval.object_type';

-- Every currency the product knows, not three of them.
update erp_ref.interview_question
   set choices = (select jsonb_agg(c.code::text order by c.code) from erp_ref.currency c where c.is_active)
 where code = 'approval.currency';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What each question offers
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.interview_suggestion (
  question_code       text not null references erp_ref.interview_question(code) on delete cascade,
  value               text not null,
  seq                 integer not null default 100,
  -- The code a picked suggestion lands with, where it is a thing with a code.
  code                text,
  -- For a classification value, the grouping it belongs to.
  axis                text,
  label               text not null,
  label_key           text not null check (label_key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
  note                text,
  note_key            text check (note_key is null or note_key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
  source              text not null check (source in ('pack', 'choice', 'example')),
  -- The feature the suggestion's pack needs; offered only while it is on.
  requires_capability text references erp_ref.capability(code),
  primary key (question_code, value),
  constraint interview_suggestion_note_has_key check ((note is null) = (note_key is null))
);

comment on table erp_ref.interview_suggestion is
  'What each onboarding question offers to pick from: a plain label and one-line '
  'meaning for every choice and yes/no, months, examples, and starter-pack '
  'departments, accounting codes, groupings, values and role templates inserted '
  'from erp_ref.pack_item. Product content: neutral, the same for every '
  'organisation. Labels resolve through label_key and note_key.';

select erp_meta.register_table('erp_ref', 'interview_suggestion', 'product_content',
  'What each onboarding question offers to pick from. Product content: the same for every organisation.');

-- ── Choices and yes/no ───────────────────────────────────────────────────────

insert into erp_ref.interview_suggestion
  (question_code, value, seq, code, axis, label, label_key, note, note_key, source, requires_capability)
select v.question_code, v.value, v.seq, null, null, v.label,
       'interview.' || v.question_code || '.suggest.' || lower(v.value),
       v.note,
       case when v.note is not null
            then 'interview.' || v.question_code || '.suggest.' || lower(v.value) || '.note' end,
       'choice', null
  from (values
    ('org.multi_company', 'true', 10, 'More than one company', null::text),
    ('org.multi_company', 'false', 20, 'One company', null),
    ('org.chart', 'standard', 10, 'Standard numbering',
     'Bank 1000, stock 1200, sales 4000; ready to use. It cannot change once your books are set up.'),
    ('org.chart', 'statutory', 20, 'Statutory numbering',
     'Current assets in the 2000s, current liabilities in the 3000s, sales in the 5000s, cost of sales in the 6000s. It cannot change once your books are set up.'),
    ('org.costing_method', 'average', 10, 'Average cost',
     'Each delivery updates one average cost for the product.'),
    ('org.costing_method', 'standard', 20, 'Standard cost',
     'You set a cost per product; any difference from what you pay is shown separately.'),
    ('org.costing_method', 'fifo', 30, 'First in, first out',
     'Stock is valued at what the oldest remaining delivery cost.'),
    ('org.identity_level', 'none', 10, 'No labels',
     'Stock is identified by product, batch and serial number only.'),
    ('org.identity_level', 'unit', 20, 'Each unit',
     'Every saleable unit carries its own label.'),
    ('org.identity_level', 'case', 30, 'Case',
     'Cases or inner packs carry a label.'),
    ('org.identity_level', 'carton', 40, 'Carton',
     'Cartons carry a label; the same level as a case.'),
    ('org.identity_level', 'pallet', 50, 'Pallet',
     'Pallets carry a label.'),
    ('org.identity_level', 'master_pallet', 60, 'Master pallet',
     'A pallet of pallets carries a label.'),
    ('org.allocation_method', 'fefo', 10, 'Earliest expiry first',
     'The batch that expires soonest is picked first.'),
    ('org.allocation_method', 'fifo', 20, 'Oldest stock first',
     'What arrived first is picked first.'),
    ('org.allocation_method', 'lifo', 30, 'Newest stock first',
     'What arrived last is picked first.'),
    ('org.consignment', 'true', 10, 'Some stock is not ours, or not on our sites', null),
    ('org.consignment', 'false', 20, 'All our stock is ours and on our own sites', null),
    ('org.policies_differ', 'true', 10, 'It differs by product or site', null),
    ('org.policies_differ', 'false', 20, 'One rule everywhere', null),
    ('approval.needed', 'true', 10, 'Some documents need sign-off', null),
    ('approval.needed', 'false', 20, 'Nothing needs sign-off', null),
    ('approval.object_type', 'requisition', 10, 'Requisition',
     'An internal request to buy.'),
    ('approval.object_type', 'purchase_order', 20, 'Purchase order',
     'An order placed with a supplier.'),
    ('approval.object_type', 'purchase_invoice', 30, 'Purchase invoice',
     'A supplier''s bill, before it is paid.'),
    ('approval.object_type', 'sales_order', 40, 'Sales order',
     'An order taken from a customer.'),
    ('approval.line_manager', 'true', 10, 'Include their manager', null),
    ('approval.line_manager', 'false', 20, 'Only the role above', null),
    ('classification.mandatory', 'true', 10, 'Every product needs a value for each', null),
    ('classification.mandatory', 'false', 20, 'Values are optional', null),
    ('code.wanted', 'true', 10, 'Issue codes to a pattern', null),
    ('code.wanted', 'false', 20, 'People type codes in', null),
    ('release.mode', 'pull', 10, 'Just the shortfall',
     'Only the missing quantity is brought in.'),
    ('release.mode', 'push', 20, 'Top it up',
     'The area is filled to its maximum; until a maximum is set, this works like just the shortfall.')
  ) v(question_code, value, seq, label, note)
on conflict (question_code, value) do update
  set seq = excluded.seq, code = excluded.code, axis = excluded.axis, label = excluded.label,
      label_key = excluded.label_key, note = excluded.note, note_key = excluded.note_key,
      source = excluded.source, requires_capability = excluded.requires_capability;

-- ── The months, and a few examples ───────────────────────────────────────────

insert into erp_ref.interview_suggestion
  (question_code, value, seq, code, axis, label, label_key, note, note_key, source, requires_capability)
select v.question_code, v.value, v.seq, v.code, null, v.label,
       'interview.' || v.question_code || '.suggest.' || lower(v.value),
       v.note,
       case when v.note is not null
            then 'interview.' || v.question_code || '.suggest.' || lower(v.value) || '.note' end,
       v.source, null
  from (values
    ('org.fiscal_year_start', '1', 1, null::text, 'January', null::text, 'choice'),
    ('org.fiscal_year_start', '2', 2, null, 'February', null, 'choice'),
    ('org.fiscal_year_start', '3', 3, null, 'March', null, 'choice'),
    ('org.fiscal_year_start', '4', 4, null, 'April', null, 'choice'),
    ('org.fiscal_year_start', '5', 5, null, 'May', null, 'choice'),
    ('org.fiscal_year_start', '6', 6, null, 'June', null, 'choice'),
    ('org.fiscal_year_start', '7', 7, null, 'July', null, 'choice'),
    ('org.fiscal_year_start', '8', 8, null, 'August', null, 'choice'),
    ('org.fiscal_year_start', '9', 9, null, 'September', null, 'choice'),
    ('org.fiscal_year_start', '10', 10, null, 'October', null, 'choice'),
    ('org.fiscal_year_start', '11', 11, null, 'November', null, 'choice'),
    ('org.fiscal_year_start', '12', 12, null, 'December', null, 'choice'),
    ('code.prefix', 'IT', 10, null, 'IT', 'Codes such as IT00001.', 'example'),
    ('code.prefix', 'P', 20, null, 'P', 'Codes such as P00001.', 'example'),
    ('release.areas', 'PICKING', 10, 'PICKING', 'Picking', null, 'example'),
    ('release.areas', 'PACKING', 20, 'PACKING', 'Packing', null, 'example'),
    ('release.areas', 'DESPATCH', 30, 'DESPATCH', 'Despatch', null, 'example')
  ) v(question_code, value, seq, code, label, note, source)
on conflict (question_code, value) do update
  set seq = excluded.seq, code = excluded.code, axis = excluded.axis, label = excluded.label,
      label_key = excluded.label_key, note = excluded.note, note_key = excluded.note_key,
      source = excluded.source, requires_capability = excluded.requires_capability;

-- ── From the starter packs ───────────────────────────────────────────────────
--
-- Read from erp_ref.pack_item rather than restated, so a department renamed in
-- the base pack is renamed here by the same build. The packs' own descriptions
-- are written as provenance for whoever maintains them; the notes below are
-- what a person picking one needs, and a pack item with no note here falls
-- back to its description. A profile pack's items carry the feature that pack
-- needs, so they are offered only where it is switched on.

insert into erp_ref.interview_suggestion
  (question_code, value, seq, code, axis, label, label_key, note, note_key, source, requires_capability)
select distinct on (x.question_code, x.value)
       x.question_code, x.value, x.seq, x.code, x.axis, x.label,
       'interview.' || x.question_code || '.suggest.' || x.keyseg,
       x.note,
       case when x.note is not null
            then 'interview.' || x.question_code || '.suggest.' || x.keyseg || '.note' end,
       'pack', x.requires_capability
  from (
    -- Departments, with the cost centre the pack suggests.
    select 'dept.list' as question_code,
           pi.payload ->> 'code' as value, cp.seq * 1000 + pi.seq as seq,
           pi.payload ->> 'code' as code, null::text as axis,
           pi.payload ->> 'name' as label,
           lower(pi.payload ->> 'code') as keyseg,
           case when nullif(pi.payload ->> 'default_cost_centre', '') is not null
                then 'Suggested cost centre ' || (pi.payload ->> 'default_cost_centre') end as note,
           coalesce(pi.requires_capability, cp.requires_capability) as requires_capability,
           cp.seq as pack_seq
      from erp_ref.pack_item pi
      join erp_ref.content_pack cp on cp.code = pi.pack_code
     where pi.object_kind = 'department' and not pi.is_decision

    union all

    -- Accounting codes for products and for suppliers and customers.
    select case pi.payload ->> 'kind' when 'item' then 'posting.item_classes' else 'posting.party_classes' end,
           pi.payload ->> 'code', cp.seq * 1000 + pi.seq,
           pi.payload ->> 'code', null::text,
           pi.payload ->> 'name',
           lower(pi.payload ->> 'code'),
           coalesce(n.note, nullif(pi.payload ->> 'description', '')),
           coalesce(pi.requires_capability, cp.requires_capability),
           cp.seq
      from erp_ref.pack_item pi
      join erp_ref.content_pack cp on cp.code = pi.pack_code
      left join (values
        ('item', 'FG',               'Complete and ready to sell.'),
        ('item', 'SFG',              'Made here and used here; not sold as it is.'),
        ('item', 'RAW',              'Bought to be made into something else.'),
        ('item', 'PACK',             'Used when packing, and counted into the finished product.'),
        ('item', 'CONS',             'Used up in running the business rather than in a product.'),
        ('item', 'SPARE',            'Kept in case something breaks; how many get used is hard to predict.'),
        ('item', 'SERVICE',          'Bought and sold, but never held as stock.'),
        ('item', 'SAMPLE',           'Given away without a sale, so it needs its own code.'),
        ('item', 'PROMO',            'Sent out free or cheaply as part of a campaign.'),
        ('item', 'ASSET',            'Kept in stock, then treated as equipment the business owns once used.'),
        ('item', 'CUSTOWN',          'Held for a customer who still owns it.'),
        ('item', 'CONSIGN',          'Held for a supplier who owns it until you use it.'),
        ('item', 'CROSSDOCK',        'Received and sent straight on, without being put away.'),
        ('item', 'DROPSHIP',         'Sold by you, but sent by the supplier straight to the customer.'),
        ('party', 'SUP_DOM',         'A supplier in the same tax country as the company.'),
        ('party', 'SUP_EU',          'A supplier inside the EU customs union, which changes how tax is charged.'),
        ('party', 'SUP_ROW',         'A supplier outside the EU customs union; duty and import tax apply.'),
        ('party', 'SUP_IC',          'Another company in your group that supplies you.'),
        ('party', 'CUST_DOM',        'A customer in the same tax country as the company.'),
        ('party', 'CUST_EU',         'A customer inside the EU customs union.'),
        ('party', 'CUST_ROW',        'A customer outside the EU customs union; export paperwork applies.'),
        ('party', 'CUST_IC',         'Another company in your group that buys from you.'),
        ('party', 'CARRIER',         'Moves goods for you; paid as freight rather than for stock.'),
        ('party', 'EMPLOYEE',        'For staff expenses and advances.'),
        ('party', 'OTHER',           'Anyone the others do not cover, so no supplier or customer is left without a code.'),
        ('party', 'IC_SERVICE',      'Recharges and shared costs between companies in your group.'),
        ('party', 'CUST_MARKETPLACE','A marketplace that sells to consumers for you and pays you.'),
        ('party', 'PROVIDER_3PL',    'Holds your stock and charges for handling and storage, never for the goods.')
      ) n(kind, code, note) on n.kind = pi.payload ->> 'kind' and n.code = pi.payload ->> 'code'
     where pi.object_kind = 'posting_class' and not pi.is_decision
       and pi.payload ->> 'kind' in ('item', 'party')

    union all

    -- Groupings for products.
    select 'classification.axes',
           pi.payload ->> 'code', cp.seq * 1000 + pi.seq,
           pi.payload ->> 'code', null::text,
           pi.payload ->> 'name',
           lower(pi.payload ->> 'code'),
           n.note,
           coalesce(pi.requires_capability, cp.requires_capability),
           cp.seq
      from erp_ref.pack_item pi
      join erp_ref.content_pack cp on cp.code = pi.pack_code
      left join (values
        ('PRODUCT_TYPE',         'Stock, non-stock or service; every product needs one.'),
        ('STORAGE_COND',         'Ambient, cool, refrigerated, frozen, controlled or hazardous.'),
        ('HAZARD_CLASS',         'The UN dangerous-goods class, 1 to 9.'),
        ('ORIGIN',               'The country a product was made in.'),
        ('COMMODITY',            'The customs commodity code; the list of codes is not included.'),
        ('BRAND',                'Your brands; you add the values.'),
        ('FAMILY',               'Your product families; you add the values.'),
        ('SIZE_STRENGTH',        'Sizes or strengths; you add the values.'),
        ('PACK_FORMAT',          'How a product is packed; you add the values.'),
        ('APPLICATION',          'What a product is used for; you add the values.'),
        ('WORKS_ORDER_TYPE',     'Production, assembly, kitting, rework or repack.'),
        ('CONTROLLED_SUBSTANCE', 'The controlled-drug schedule a product falls under; you add the values.'),
        ('ELIMINATION',          'Which trading between your group''s companies cancels out in group figures; you add the values.')
      ) n(code, note) on n.code = pi.payload ->> 'code'
     where pi.object_kind = 'classification_axis' and not pi.is_decision

    union all

    -- Values on those groupings. Country of origin is left out: its values are
    -- the country register, offered on its own.
    select 'classification.values',
           (pi.payload ->> 'axis') || '|' || (pi.payload ->> 'code'), cp.seq * 1000 + pi.seq,
           pi.payload ->> 'code', pi.payload ->> 'axis',
           pi.payload ->> 'name',
           lower(pi.payload ->> 'axis') || '.' || lower(pi.payload ->> 'code'),
           null::text,
           coalesce(pi.requires_capability, cp.requires_capability),
           cp.seq
      from erp_ref.pack_item pi
      join erp_ref.content_pack cp on cp.code = pi.pack_code
     where pi.object_kind = 'classification_value' and not pi.is_decision
       and pi.payload ->> 'axis' <> 'ORIGIN'

    union all

    -- Role templates, as the roles that can sign off.
    select 'approval.role',
           pi.payload ->> 'code', cp.seq * 1000 + pi.seq,
           pi.payload ->> 'code', null::text,
           pi.payload ->> 'name',
           lower(pi.payload ->> 'code'),
           n.note,
           coalesce(pi.requires_capability, cp.requires_capability),
           cp.seq
      from erp_ref.pack_item pi
      join erp_ref.content_pack cp on cp.code = pi.pack_code
      left join (values
        ('administrator',         'Sets the system up and manages users; posts and approves nothing.'),
        ('finance_manager',       'Runs the books: posts, closes accounting periods and approves payments.'),
        ('finance_clerk',         'Posts and matches invoices; approves nothing.'),
        ('buyer',                 'Raises requisitions and purchase orders.'),
        ('procurement_manager',   'Approves requisitions and purchase orders.'),
        ('planner',               'Runs planning and firms up planned orders.'),
        ('production_supervisor', 'Creates, releases and runs works orders.'),
        ('production_operator',   'Records work on released works orders.'),
        ('warehouse_manager',     'Moves, counts, adjusts and writes off stock.'),
        ('warehouse_operative',   'Receives, moves, counts and despatches; cannot adjust.'),
        ('quality_manager',       'Inspects, decides what happens to stock, releases batches and runs recalls.'),
        ('quality_inspector',     'Inspects and records; does not release.'),
        ('responsible_person',    'The named person who releases batches and runs recalls.'),
        ('sales_manager',         'Sets prices, approves discounts and releases orders held on credit.'),
        ('sales_administrator',   'Takes orders and raises invoices.'),
        ('customer_service',      'Takes orders and answers customers.'),
        ('auditor',               'Reads everything and changes nothing.'),
        ('integration',           'For a connected system, not a person.')
      ) n(code, note) on n.code = pi.payload ->> 'code'
     where pi.object_kind = 'role' and not pi.is_decision
  ) x
 where x.value is not null and x.label is not null
 order by x.question_code, x.value, x.pack_seq
on conflict (question_code, value) do update
  set seq = excluded.seq, code = excluded.code, axis = excluded.axis, label = excluded.label,
      label_key = excluded.label_key, note = excluded.note, note_key = excluded.note_key,
      source = excluded.source, requires_capability = excluded.requires_capability;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The words, where an organisation can rename them
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select q.prompt_key, 'en', q.prompt, 'Onboarding interview: a question.'
  from erp_ref.interview_question q
union all
select q.prompt_key || '.help', 'en', q.help, 'Onboarding interview: the help under a question.'
  from erp_ref.interview_question q
 where q.help is not null
union all
select s.label_key, 'en', s.label, 'Onboarding interview: an answer offered to pick.'
  from erp_ref.interview_suggestion s
union all
select s.note_key, 'en', s.note, 'Onboarding interview: what an offered answer means.'
  from erp_ref.interview_suggestion s
 where s.note_key is not null
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select v.key, 'en', v.value, v.description
  from (values
    ('interview.org.companies.example', 'For example IE, with the trading name of your Irish company',
     'Onboarding interview: an example answer.'),
    ('interview.org.fiscal_year_start.example', 'For example 4, for a year that starts in April',
     'Onboarding interview: an example answer.'),
    ('interview.approval.threshold.example', 'For example 1,000 or 5,000',
     'Onboarding interview: an example answer.'),
    ('interview.code.prefix.example', 'For example IT or P',
     'Onboarding interview: an example answer.'),
    ('interview.code.digits.example', 'For example 5, which allows 99,999 products',
     'Onboarding interview: an example answer.'),
    ('interview.release.areas.example', 'For example Picking, Packing and Despatch',
     'Onboarding interview: an example answer.'),
    ('interview.release.ageing_hours.example', 'For example 72, which covers a weekend',
     'Onboarding interview: an example answer.'),
    ('interview.currency.decimals.0', 'Amounts have no decimal places, such as 5000.',
     'Onboarding interview: what a currency''s amounts look like.'),
    ('interview.currency.decimals.1', 'Amounts have one decimal place, such as 5000.0.',
     'Onboarding interview: what a currency''s amounts look like.'),
    ('interview.currency.decimals.2', 'Amounts have two decimal places, such as 5000.00.',
     'Onboarding interview: what a currency''s amounts look like.'),
    ('interview.currency.decimals.3', 'Amounts have three decimal places, such as 5000.000.',
     'Onboarding interview: what a currency''s amounts look like.'),
    ('interview.currency.decimals.4', 'Amounts have four decimal places, such as 5000.0000.',
     'Onboarding interview: what a currency''s amounts look like.'),
    ('interview.org.chart.unavailable.not_on_plan', 'Not included in your plan.',
     'Onboarding interview: why the statutory numbering cannot be picked.'),
    ('interview.org.chart.unavailable.posted', 'Something has already been posted, so the numbering can no longer change.',
     'Onboarding interview: why the statutory numbering cannot be picked.'),
    ('interview.org.chart.unavailable.books_set_up', 'Your books are already set up, so the numbering can no longer change.',
     'Onboarding interview: why the statutory numbering cannot be picked.'),
    ('interview.org.chart.unavailable.statutory_on', 'This organisation already uses the statutory numbering.',
     'Onboarding interview: why the standard numbering cannot be picked.'),
    ('interview.org.chart.unavailable.one_company', 'Statutory numbering can be set up for one company only for now, and you have more than one.',
     'Onboarding interview: why the statutory numbering cannot be picked.')
  ) v(key, value, description)
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- The nominal accounts a goods receipt can go to, by what each one is for.
insert into erp_ref.resource (key, locale, value, description)
select 'interview.account_purpose.' || cp.purpose, 'en', cp.name,
       'Onboarding interview: a nominal account offered by what it is for.'
  from erp_ref.chart_account_purpose cp
union all
select 'interview.account_purpose.' || cp.purpose || '.note', 'en', m.meaning,
       'Onboarding interview: what a nominal account is for.'
  from erp_ref.chart_account_purpose cp
  join (values
    ('bank',                        'Money in your bank accounts.'),
    ('trade_receivable',            'Money customers owe you for invoices not yet paid.'),
    ('inventory',                   'The value of the stock you hold.'),
    ('work_in_progress',            'The value of products you have started making but not finished.'),
    ('trade_payable',               'Money you owe suppliers for invoices not yet paid.'),
    ('goods_received_not_invoiced', 'Goods that have arrived but whose supplier invoice has not.'),
    ('tax_control',                 'Tax charged on sales and paid on purchases, held until you settle with the tax authority.'),
    ('retained_earnings',           'Profit kept in the business from earlier years.'),
    ('revenue',                     'What you have sold, before costs.'),
    ('cost_of_sales',               'What the stock you sold cost you.'),
    ('purchase_price_variance',     'The difference between what you paid a supplier and the set cost of the goods.'),
    ('material_usage_variance',     'The difference between the materials a works order should have used and what it used.'),
    ('stock_adjustment',            'The value of stock found missing or extra at a count, or written off.'),
    ('labour_efficiency_variance',  'The difference between the time a works order should have taken and the time it took.'),
    ('freight_variance',            'The difference between expected and actual delivery charges.'),
    ('operating_expenses',          'The day-to-day running costs of the business.'),
    ('purchase_commitment',         'Purchase orders placed but not yet received, kept as a memo outside your books.'),
    ('sales_commitment',            'Sales orders accepted but not yet delivered, kept as a memo outside your books.'),
    ('commitment_offset',           'The balancing side of those memo entries; it never needs attention.'),
    ('suspense',                    'A holding place for amounts not yet identified; it must be empty before a period closes.'),
    ('clearing',                    'A stop for money moving between two places, such as takings on their way to the bank; it should come back to zero.'),
    ('translation_difference',      'Small differences left when a group adds up companies that keep their books in different currencies.')
  ) m(purpose, meaning) on m.purpose = cp.purpose
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Is a feature on this organisation's plan?
-- ═════════════════════════════════════════════════════════════════════════════

-- The test erp.require_capability_on_plan() makes, as a boolean: no
-- subscription means no restriction; otherwise the plan or the contract in
-- force must carry it. Asking must not raise, and must not record a refusal
-- nobody made — the screen asks on every read.
create or replace function erp.capability_on_plan(p_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select erp.tenant_plan_code() is null
      or exists (select 1 from erp_meta.plan_capability pc
                  where pc.plan_code = erp.tenant_plan_code() and pc.capability_code = p_code)
      or exists (select 1 from erp_meta.contract_capability cc
                   join erp_meta.contract c on c.id = cc.contract_id
                  where c.tenant_id = erp.require_tenant_id()
                    and c.status in ('active', 'terminating')
                    and cc.capability_code = p_code
                    and cc.effective_from <= current_date
                    and (cc.effective_to is null or cc.effective_to > current_date))
$$;

comment on function erp.capability_on_plan(text) is
  'Whether a feature is available to this organisation: no subscription, on its '
  'plan, or sold by the contract in force. The yes-or-no half of '
  'erp.require_capability_on_plan(), which neither raises nor records anything.';

revoke all on function erp.capability_on_plan(text) from public, anon;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'capability_on_plan',
   'Reads erp_meta.plan_capability and erp_meta.contract_capability for the caller''s own organisation and answers yes or no. Definer because erp_meta is platform_internal; it writes nothing and says nothing about any other organisation.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- Same signature, return type and refusal as 20260904610000; the test itself
-- now lives in one place.
create or replace function erp.require_capability_on_plan(p_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_plan   text := erp.tenant_plan_code();
begin
  -- No subscription recorded is unmetered, as everywhere else here; on the
  -- plan, or sold as an add-on by the contract in force, is allowed. §17.9:
  -- the contract is the source of what is available, the plan is what it
  -- started from.
  if erp.capability_on_plan(p_code) then
    return;
  end if;

  perform erp.append_event(
    'commercial.capability_refused', 'tenant', v_tenant,
    jsonb_build_object('capability', p_code, 'plan', v_plan));

  raise exception
    'CLOVEERP_CAPABILITY_NOT_ON_PLAN: % is not available on the % plan or the contract', p_code, v_plan
    using errcode = '42501',
          hint = 'Raise the plan or add the feature to the contract by amendment. It is '
                 'refused rather than hidden, because a switch that silently '
                 'does nothing is worse than one that says why.';
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Which answers count
-- ═════════════════════════════════════════════════════════════════════════════

-- A question applies when its gate is answered with something that is not no
-- and not an empty list, and when its gate applies too — all the way up. The
-- bank's chains are two deep; the old one-level test let org.currencies apply
-- after "one company" because org.companies had been answered before.
create or replace function erp.interview_applies(p_session_id uuid)
returns table (question_code text, applies boolean)
language sql
stable
set search_path = ''
as $$
  with recursive ans as (
    select ia.question_code, ia.answer
      from erp.interview_answer ia
     where ia.tenant_id = erp.require_tenant_id()
       and ia.session_id = p_session_id
  ),
  direct as (
    select q.code, q.applies_when,
           case
             when q.applies_when is null then true
             else coalesce((
               select case jsonb_typeof(g.answer)
                        when 'boolean' then g.answer = 'true'::jsonb
                        when 'array'   then jsonb_array_length(g.answer) > 0
                        else coalesce(g.answer #>> '{}', '') <> ''
                      end
                 from ans g
                where g.question_code = q.applies_when), false)
           end as opens
      from erp_ref.interview_question q
  ),
  chain (code, ok, depth) as (
    select d.code, d.opens, 0 from direct d where d.applies_when is null
    union all
    select d.code, c.ok and d.opens, c.depth + 1
      from chain c
      join direct d on d.applies_when = c.code
     where c.depth < 16
  )
  select c.code, c.ok from chain c
$$;

comment on function erp.interview_applies(uuid) is
  'Whether each onboarding question applies in a session: its gate is answered '
  'yes or with something, and its gate applies too, to the root.';

-- The answers a proposal may act on: only those whose question applies. The
-- screen's "applies" and the proposer read the same thing.
create or replace function erp.interview_effective_answers(p_session_id uuid)
returns table (question_code text, section text, answer jsonb)
language sql
stable
set search_path = ''
as $$
  select ia.question_code, q.section, ia.answer
    from erp.interview_answer ia
    join erp_ref.interview_question q on q.code = ia.question_code
    join erp.interview_applies(p_session_id) ap on ap.question_code = ia.question_code
   where ia.tenant_id = erp.require_tenant_id()
     and ia.session_id = p_session_id
     and ap.applies
$$;

comment on function erp.interview_effective_answers(uuid) is
  'The answers in an onboarding session whose question applies, following every '
  'gate to the root. What propose, and accepting, act on.';

-- One element of a list answer: a name somebody typed, or {code, name} picked
-- from a suggestion. A code that was supplied is kept as it is — pack codes
-- carry underscores the slug would turn into dashes — and a typed name is
-- slugged exactly as before.
create or replace function erp.interview_list_item(p_element jsonb, out code text, out name text)
returns record
language sql
immutable
set search_path = ''
as $$
  select case
           when jsonb_typeof(p_element) = 'object' and nullif(btrim(p_element ->> 'code'), '') is not null
             then upper(btrim(p_element ->> 'code'))
           else erp.slug_code(case when jsonb_typeof(p_element) = 'object'
                                   then p_element ->> 'name' else p_element #>> '{}' end)
         end,
         nullif(btrim(case when jsonb_typeof(p_element) = 'object'
                           then coalesce(nullif(btrim(p_element ->> 'name'), ''), p_element ->> 'code')
                           else p_element #>> '{}' end), '')
$$;

-- A resource by key, or the column it was seeded from when there is none.
create or replace function erp.interview_text(p_key text, p_fallback text)
returns text
language sql
stable
set search_path = ''
as $$
  select case when p_key is null then p_fallback
              else coalesce(nullif(erp.text(p_key), p_key), p_fallback) end
$$;

revoke all on function erp.interview_applies(uuid) from public, anon;
revoke all on function erp.interview_effective_answers(uuid) from public, anon;
revoke all on function erp.interview_list_item(jsonb) from public, anon;
revoke all on function erp.interview_text(text, text) from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The questions, with what to pick from
-- ═════════════════════════════════════════════════════════════════════════════

-- A question's rows from the suggestion register, in the screen's shape, with
-- whether each already exists in this organisation and whether it is the
-- likely pick.
create or replace function erp.interview_suggestions(p_question_code text, p_likely text[] default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'value', s.value,
           'code', s.code,
           'label', erp.interview_text(s.label_key, s.label),
           'note', erp.interview_text(s.note_key, s.note),
           'axis', s.axis,
           'likely', coalesce(s.value = any (p_likely), false),
           'available', true,
           'unavailable_reason', null::text,
           'present', case s.question_code
             when 'dept.list' then exists (
               select 1 from erp.department d
                where d.tenant_id = t.id and d.code = s.code and d.status = 'active')
             when 'posting.item_classes' then exists (
               select 1 from erp.posting_class pc
                where pc.tenant_id = t.id and pc.kind::text = 'item' and pc.code = s.code and pc.status = 'active')
             when 'posting.party_classes' then exists (
               select 1 from erp.posting_class pc
                where pc.tenant_id = t.id and pc.kind::text = 'party' and pc.code = s.code and pc.status = 'active')
             when 'classification.axes' then exists (
               select 1 from erp.classification_axis ca
                where ca.tenant_id = t.id and ca.code = s.code and ca.status = 'active')
             when 'classification.values' then exists (
               select 1 from erp.classification_value cv
                 join erp.classification_axis ca on ca.id = cv.axis_id
                where ca.tenant_id = t.id and ca.code = s.axis and cv.code = s.code and cv.status = 'active')
             when 'approval.role' then exists (
               select 1 from erp.role r
                where r.tenant_id = t.id and r.code = s.code and r.status = 'active')
             when 'release.areas' then exists (
               select 1 from erp.release_area ra
                where ra.tenant_id = t.id and ra.code = s.code)
             else false
           end)
         order by s.seq, s.value), '[]'::jsonb)
    from erp_ref.interview_suggestion s
    cross join (select erp.require_tenant_id() as id) t
   where s.question_code = p_question_code
     and (s.requires_capability is null
          or erp.capability_on(t.id, s.requires_capability, current_date))
$$;

revoke all on function erp.interview_suggestions(text, text[]) from public, anon;

-- The output grows, so the old function goes first. Every column it returned
-- keeps its name — the interview suite reads applies — and the public door,
-- which is plpgsql and aggregates whatever comes back, needs no change.
drop function if exists erp.interview_questions(uuid);

create function erp.interview_questions(p_session_id uuid)
returns table (code text, section text, surface text, seq integer, prompt text, prompt_key text,
               help text, answer_shape text, choices jsonb, maps_to text, is_required boolean,
               applies boolean, answer jsonb, applies_when text, suggestions jsonb,
               left_suggestions jsonb, likely jsonb, example text)
language plpgsql
stable
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_tenant     uuid := erp.require_tenant_id();
  q            record;
  v_e0_ccy     text;
  v_e0_country text;
  v_e0_locale  text;
  v_e0_fy      integer;
  v_entities   integer;
  v_applies    jsonb;
  v_raw        jsonb;
  v_eff        jsonb;
  v_statutory  boolean;
  v_on_plan    boolean;
  v_finance    boolean;
  v_books      boolean;
  v_posted     boolean;
  v_chart      text;
  v_stat_ok    boolean;
  v_std_ok     boolean;
  v_one_co     boolean;
  v_companies  jsonb;
  v_countries  jsonb;
  v_sugg       jsonb;
  v_left       jsonb;
  v_likely     jsonb;
  v_pick       text;
begin
  -- The organisation as it stands: its first company by code, as the
  -- proposer picks it, and what has already been set up.
  select e0.base_currency::text, e0.country_code::text, e0.reporting_locale, e0.fiscal_year_start_month
    into v_e0_ccy, v_e0_country, v_e0_locale, v_e0_fy
    from erp.entity e0
   where e0.tenant_id = v_tenant and e0.status = 'active'
   order by e0.code
   limit 1;

  select count(*) into v_entities
    from erp.entity en where en.tenant_id = v_tenant and en.status = 'active';

  select coalesce(jsonb_object_agg(ap.question_code, ap.applies), '{}'::jsonb)
    into v_applies
    from erp.interview_applies(p_session_id) ap;

  select coalesce(jsonb_object_agg(ia.question_code, ia.answer), '{}'::jsonb)
    into v_raw
    from erp.interview_answer ia
   where ia.tenant_id = v_tenant and ia.session_id = p_session_id;

  select coalesce(jsonb_object_agg(ea.question_code, ea.answer), '{}'::jsonb)
    into v_eff
    from erp.interview_effective_answers(p_session_id) ea;

  v_statutory := erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date);
  v_on_plan   := erp.capability_on_plan('statutory_chart_8_1');
  v_finance   := exists (select 1 from erp.ledger l where l.tenant_id = v_tenant and l.code = 'GL');
  v_books     := v_finance
                 or exists (select 1 from erp.account ac where ac.tenant_id = v_tenant)
                 or exists (select 1 from erp.change_set cs where cs.tenant_id = v_tenant and cs.code = 'finance-posting');
  v_posted    := exists (select 1 from erp.journal_line jl where jl.tenant_id = v_tenant);
  -- The numbering a receipt account is offered in: the one in force when the
  -- statutory numbering is already on, else this session's answer.
  v_chart     := case when v_statutory then 'statutory' else coalesce(v_eff ->> 'org.chart', 'standard') end;
  -- The statutory numbering's accounts arrive as one pack, and a pack that
  -- names no company lands on the first one: a second company would have
  -- books and no chart. So it is offered to one company only, for now.
  v_one_co    := v_entities <= 1 and coalesce((v_eff -> 'org.multi_company') <> 'true'::jsonb, true);
  v_stat_ok   := v_statutory or (v_on_plan and not v_books and not v_posted and v_one_co);
  v_std_ok    := not v_statutory;

  v_countries := case when jsonb_typeof(v_eff -> 'org.countries') = 'array'
                      then v_eff -> 'org.countries' else '[]'::jsonb end;

  -- The companies a pair question pairs: those that exist, then those this
  -- session names as new.
  v_companies := coalesce((
      select jsonb_agg(jsonb_build_object('value', en.code, 'label', en.name, 'note', null::text, 'present', true)
                       order by en.code)
        from erp.entity en
       where en.tenant_id = v_tenant and en.status = 'active'), '[]'::jsonb)
    || coalesce((
      select jsonb_agg(jsonb_build_object('value', nc.code, 'label', nc.name, 'note', null::text, 'present', false)
                       order by nc.ord)
        from (select erp.slug_code(p.value ->> 'left') as code,
                     min(btrim(p.value ->> 'right')) as name,
                     min(p.ord) as ord
                from jsonb_array_elements(case when jsonb_typeof(v_eff -> 'org.companies') = 'array'
                                               then v_eff -> 'org.companies' else '[]'::jsonb end)
                     with ordinality p(value, ord)
               group by erp.slug_code(p.value ->> 'left')) nc
       where nc.code is not null
         and not exists (select 1 from erp.entity en
                          where en.tenant_id = v_tenant and en.code = nc.code and en.status = 'active')), '[]'::jsonb);

  for q in select iq.* from erp_ref.interview_question iq order by iq.seq, iq.code loop
    v_sugg := '[]'::jsonb;
    v_left := '[]'::jsonb;
    v_likely := null;
    v_pick := null;

    if q.answer_shape in ('boolean', 'choice') then
      v_likely := case q.code
        when 'org.multi_company'        then to_jsonb(v_entities > 1)
        when 'org.chart'                then to_jsonb(case when v_statutory then 'statutory' else 'standard' end)
        when 'org.costing_method'       then to_jsonb('average'::text)
        when 'org.identity_level'       then to_jsonb('none'::text)
        when 'org.allocation_method'    then to_jsonb(coalesce((
                                               select ct.default_value ->> 'default' from erp_ref.config_type ct
                                                where ct.code = 'stock.allocation_policy'), 'fifo'))
        when 'org.consignment'          then to_jsonb(erp.capability_on(v_tenant, 'consignment_stock', current_date)
                                                      or erp.capability_on(v_tenant, 'third_party_custody', current_date))
        when 'org.policies_differ'      then 'false'::jsonb
        when 'approval.object_type'     then to_jsonb('purchase_order'::text)
        when 'approval.currency'        then to_jsonb(v_e0_ccy)
        when 'classification.mandatory' then 'false'::jsonb
        when 'release.mode'             then to_jsonb('pull'::text)
        else null
      end;
      v_pick := v_likely #>> '{}';

      if q.code = 'approval.currency' then
        -- One per choice, named from the currency register.
        v_sugg := coalesce((
          select jsonb_agg(jsonb_build_object(
                   'value', ch.value, 'code', ch.value,
                   'label', ch.value || coalesce(' — ' || c.name, ''),
                   'note', case when c.minor_units is not null
                                then erp.interview_text('interview.currency.decimals.' || c.minor_units::text, null) end,
                   'axis', null::text,
                   'likely', coalesce(ch.value = v_pick, false),
                   'available', true, 'unavailable_reason', null::text, 'present', false)
                 order by ch.ord)
            from jsonb_array_elements_text(coalesce(q.choices, '[]'::jsonb)) with ordinality ch(value, ord)
            left join erp_ref.currency c on c.code = ch.value), '[]'::jsonb);
      else
        v_sugg := erp.interview_suggestions(q.code, array[v_pick]);
      end if;

      if q.code = 'org.chart' then
        -- The statutory numbering needs the plan, and an empty set of books.
        v_sugg := coalesce((
          select jsonb_agg(case x.value ->> 'value'
                             when 'statutory' then x.value || jsonb_build_object(
                               'available', v_stat_ok,
                               'unavailable_reason', case
                                 when v_stat_ok then null
                                 when not v_on_plan then erp.text('interview.org.chart.unavailable.not_on_plan')
                                 when v_posted then erp.text('interview.org.chart.unavailable.posted')
                                 when v_books then erp.text('interview.org.chart.unavailable.books_set_up')
                                 else erp.text('interview.org.chart.unavailable.one_company') end)
                             when 'standard' then x.value || jsonb_build_object(
                               'available', v_std_ok,
                               'unavailable_reason', case
                                 when v_std_ok then null
                                 else erp.text('interview.org.chart.unavailable.statutory_on') end)
                             else x.value
                           end
                           order by x.ord)
            from jsonb_array_elements(v_sugg) with ordinality x(value, ord)), '[]'::jsonb);
      end if;

    elsif q.answer_shape = 'integer' then
      if q.code = 'org.fiscal_year_start' then
        v_likely := to_jsonb(v_e0_fy);
        v_sugg := erp.interview_suggestions(q.code, array[v_e0_fy::text]);
      elsif q.code = 'code.digits' then
        v_likely := '5'::jsonb;
      elsif q.code = 'release.ageing_hours' then
        v_likely := to_jsonb(coalesce((
          select (ct.default_value ->> 'marshalling_area_hours')::integer
            from erp_ref.config_type ct where ct.code = 'stock.reservation_ageing'), 72));
      end if;

    elsif q.answer_shape = 'text' then
      if q.code = 'approval.role' then
        -- The role the base pack puts first on this kind of document, where
        -- this organisation has it.
        v_pick := (
          select pi.payload ->> 'approver_role'
            from erp_ref.pack_item pi
           where pi.pack_code = 'base' and pi.object_kind = 'approval_band'
             and pi.payload ->> 'object_type' = coalesce(v_eff ->> 'approval.object_type', 'purchase_order')
             and pi.payload ->> 'seq' = '1'
             and exists (select 1 from erp.role r
                          where r.tenant_id = v_tenant and r.status = 'active'
                            and r.code = pi.payload ->> 'approver_role')
           order by pi.object_key
           limit 1);
        v_likely := to_jsonb(v_pick);
        v_sugg := erp.interview_suggestions(q.code, array[v_pick])
               || coalesce((
                    select jsonb_agg(jsonb_build_object(
                             'value', r.code, 'code', r.code,
                             'label', coalesce(nullif(btrim(r.name), ''), erp.interview_text(r.name_key, null), r.code),
                             'note', r.description, 'axis', null::text,
                             'likely', coalesce(r.code = v_pick, false),
                             'available', true, 'unavailable_reason', null::text, 'present', true)
                           order by r.code)
                      from erp.role r
                     where r.tenant_id = v_tenant and r.status = 'active'
                       and not exists (select 1 from erp_ref.interview_suggestion s
                                        where s.question_code = 'approval.role' and s.value = r.code)), '[]'::jsonb);

      elsif q.code = 'posting.receipt_account' then
        -- Stock's account, in the numbering this session chose, or as the
        -- books already have it.
        v_pick := case
                    when v_finance then erp.tenant_account_code('inventory')
                    else (select case when v_chart = 'statutory' then cp.statutory_code else cp.default_code end
                            from erp_ref.chart_account_purpose cp where cp.purpose = 'inventory')
                  end;
        v_likely := to_jsonb(v_pick);
        v_sugg := coalesce((
          select jsonb_agg(jsonb_build_object(
                   'value', y.account_code, 'code', y.account_code,
                   'label', erp.interview_text('interview.account_purpose.' || y.purpose, y.name),
                   'note', erp.interview_text('interview.account_purpose.' || y.purpose || '.note', null),
                   'axis', null::text,
                   'likely', coalesce(y.account_code = v_pick, false),
                   'available', true, 'unavailable_reason', null::text,
                   'present', y.present)
                 order by (y.purpose = 'inventory') desc, y.seq, y.purpose)
            from (select distinct on (a.account_code)
                         a.purpose, a.name, a.seq, a.account_code, a.present
                    from (select cp.purpose, cp.name, cp.seq, cp.installer_creates, c.account_code,
                                 exists (select 1 from erp.account ac
                                          where ac.tenant_id = v_tenant and ac.code = c.account_code
                                            and ac.status = 'active') as present
                            from erp_ref.chart_account_purpose cp
                            cross join lateral (
                              select case when (v_finance and v_statutory)
                                            or (not v_finance and v_chart = 'statutory')
                                          then cp.statutory_code
                                          else cp.default_code end as account_code) c
                           where cp.account_type::text <> 'statistical'
                             and cp.purpose not in ('suspense', 'translation_difference', 'retained_earnings')) a
                   where (v_finance and a.present) or (not v_finance and a.installer_creates)
                   order by a.account_code, (a.purpose = 'inventory') desc, a.seq) y), '[]'::jsonb);

      elsif q.code = 'code.prefix' then
        v_sugg := erp.interview_suggestions(q.code, null);
      end if;

    elsif q.answer_shape = 'text_list' then
      v_sugg := erp.interview_suggestions(q.code, case q.code
        when 'dept.list' then array['PROC', 'FIN', 'SALES']
        when 'posting.item_classes' then array_remove(array[
          case when erp.capability_on(v_tenant, 'production', current_date) then 'SFG' end,
          case when erp.capability_on(v_tenant, 'consignment_stock', current_date) then 'CONSIGN' end], null)
        when 'posting.party_classes' then
          case when v_entities > 1 or (v_eff -> 'org.multi_company') = 'true'::jsonb
               then array['SUP_IC', 'CUST_IC'] end
        when 'classification.axes' then array['PRODUCT_TYPE']
        else null
      end);

    elsif q.answer_shape = 'text_pairs' then
      if q.code = 'org.companies' then
        v_left := coalesce((
          select jsonb_agg(c.value order by c.ord)
            from jsonb_array_elements(v_companies) with ordinality c(value, ord)
           where (c.value ->> 'present')::boolean), '[]'::jsonb);

      elsif q.code = 'org.currencies' then
        v_left := v_companies;
        v_sugg := coalesce((
          select jsonb_agg(jsonb_build_object(
                   'value', c.code::text, 'code', c.code::text,
                   'label', c.code::text || ' — ' || c.name,
                   'note', erp.interview_text('interview.currency.decimals.' || c.minor_units::text, null),
                   'axis', null::text, 'likely', false,
                   'available', true, 'unavailable_reason', null::text, 'present', false)
                 order by c.code)
            from erp_ref.currency c where c.is_active), '[]'::jsonb);
        -- A new company takes its country's currency, else the first
        -- company's; an existing one only where this session gave it a
        -- country whose currency differs and its books are not set up, since
        -- a company with a general ledger keeps its currency.
        v_likely := (
          select jsonb_agg(jsonb_build_object('left', d.company, 'right', d.ccy) order by d.ord)
            from (select b.company, b.ord, b.present, b.current_ccy, b.has_gl,
                         coalesce((select co.default_currency::text from erp_ref.country co
                                    where co.code = b.answered_country),
                                  b.current_ccy, v_e0_ccy) as ccy
                    from (select c.value ->> 'value' as company, c.ord,
                                 (c.value ->> 'present')::boolean as present,
                                 en.base_currency::text as current_ccy,
                                 exists (select 1 from erp.ledger l
                                          where l.tenant_id = v_tenant and l.entity_id = en.id
                                            and l.code = 'GL') as has_gl,
                                 (select upper(btrim(p.value ->> 'right')) from jsonb_array_elements(v_countries) p
                                   where erp.slug_code(p.value ->> 'left') = c.value ->> 'value'
                                     and nullif(btrim(p.value ->> 'right'), '') is not null
                                   limit 1) as answered_country
                            from jsonb_array_elements(v_companies) with ordinality c(value, ord)
                            left join erp.entity en
                              on en.tenant_id = v_tenant and en.status = 'active'
                             and en.code = c.value ->> 'value') b) d
           where d.ccy is not null
             and (not d.present or (d.ccy is distinct from d.current_ccy and not d.has_gl)));

      elsif q.code = 'org.countries' then
        v_left := v_companies;
        v_sugg := coalesce((
          select jsonb_agg(jsonb_build_object(
                   'value', c.code::text, 'code', c.code::text, 'label', c.name,
                   'note', null::text, 'axis', null::text, 'likely', false,
                   'available', true, 'unavailable_reason', null::text, 'present', false)
                 order by c.name)
            from erp_ref.country c where c.is_active), '[]'::jsonb);
        -- A new company is most likely where the first one is.
        v_likely := (
          select jsonb_agg(jsonb_build_object('left', c.value ->> 'value', 'right', v_e0_country) order by c.ord)
            from jsonb_array_elements(v_companies) with ordinality c(value, ord)
           where not (c.value ->> 'present')::boolean
             and v_e0_country is not null);

      elsif q.code = 'org.locales' then
        v_left := v_companies;
        v_sugg := coalesce((
          select jsonb_agg(jsonb_build_object(
                   'value', l.code, 'code', l.code, 'label', l.name,
                   'note', null::text, 'axis', null::text, 'likely', false,
                   'available', true, 'unavailable_reason', null::text, 'present', false)
                 order by l.code)
            from erp_ref.locale l where l.is_active), '[]'::jsonb);
        -- The language variant of the company's country, where one exists.
        v_likely := (
          select jsonb_agg(jsonb_build_object('left', d.company, 'right', d.loc) order by d.ord)
            from (select b.company, b.ord, b.present, b.current_locale, b.answered_country,
                         coalesce((select l.code from erp_ref.locale l
                                    where l.is_active
                                      and split_part(l.code, '-', 2) = coalesce(b.answered_country,
                                                                                case when not b.present then v_e0_country end)
                                    order by l.code limit 1),
                                  b.current_locale, v_e0_locale, 'en') as loc
                    from (select c.value ->> 'value' as company, c.ord,
                                 (c.value ->> 'present')::boolean as present,
                                 en.reporting_locale as current_locale,
                                 (select upper(btrim(p.value ->> 'right')) from jsonb_array_elements(v_countries) p
                                   where erp.slug_code(p.value ->> 'left') = c.value ->> 'value'
                                     and nullif(btrim(p.value ->> 'right'), '') is not null
                                   limit 1) as answered_country
                            from jsonb_array_elements(v_companies) with ordinality c(value, ord)
                            left join erp.entity en
                              on en.tenant_id = v_tenant and en.status = 'active'
                             and en.code = c.value ->> 'value') b) d
           where not d.present
              or (d.answered_country is not null and d.loc is distinct from d.current_locale));

      elsif q.code = 'org.legislation' then
        v_left := v_companies;
        v_sugg := coalesce((
          select jsonb_agg(jsonb_build_object(
                   'value', lp.code, 'code', lp.code,
                   'label', erp.interview_text(lp.name_key, lp.code),
                   'note', (select co.name from erp_ref.country co where co.code = lp.jurisdiction),
                   'axis', null::text, 'likely', false,
                   'available', true, 'unavailable_reason', null::text, 'present', false)
                 order by lp.code)
            from (select distinct on (p.code) p.code, p.name_key, p.jurisdiction
                    from erp_ref.legislation_pack p
                   where p.is_current and p.jurisdiction <> 'XX'
                   order by p.code, p.version desc) lp), '[]'::jsonb);
        -- The current pack for each company's country — answered this
        -- session, or as the company already is — where it is not bound yet.
        v_likely := (
          select jsonb_agg(jsonb_build_object('left', d.company, 'right', d.pack) order by d.ord)
            from (select b.company, b.ord, b.entity_id,
                         (select lp.code from erp_ref.legislation_pack lp
                           where lp.is_current and lp.jurisdiction <> 'XX'
                             and lp.jurisdiction = coalesce(b.answered_country, b.current_country)
                           order by lp.version desc, lp.code
                           limit 1) as pack
                    from (select c.value ->> 'value' as company, c.ord,
                                 en.id as entity_id,
                                 en.country_code::text as current_country,
                                 (select upper(btrim(p.value ->> 'right')) from jsonb_array_elements(v_countries) p
                                   where erp.slug_code(p.value ->> 'left') = c.value ->> 'value'
                                     and nullif(btrim(p.value ->> 'right'), '') is not null
                                   limit 1) as answered_country
                            from jsonb_array_elements(v_companies) with ordinality c(value, ord)
                            left join erp.entity en
                              on en.tenant_id = v_tenant and en.status = 'active'
                             and en.code = c.value ->> 'value') b) d
           where d.pack is not null
             and not exists (select 1 from erp.entity_legislation_binding lb
                              where lb.tenant_id = v_tenant and lb.entity_id = d.entity_id
                                and lb.pack_code = d.pack and lb.status = 'active'));

      elsif q.code = 'org.identity_by_class' then
        v_left := coalesce((
            select jsonb_agg(jsonb_build_object(
                     'value', x.value ->> 'value', 'label', x.value ->> 'label',
                     'note', x.value ->> 'note', 'present', (x.value ->> 'present')::boolean)
                   order by x.ord)
              from jsonb_array_elements(erp.interview_suggestions('posting.item_classes', null))
                   with ordinality x(value, ord)), '[]'::jsonb)
          || coalesce((
            select jsonb_agg(jsonb_build_object('value', pc.code, 'label', pc.name,
                                                'note', pc.description, 'present', true)
                             order by pc.code)
              from erp.posting_class pc
             where pc.tenant_id = v_tenant and pc.kind::text = 'item' and pc.status = 'active'
               and not exists (select 1 from erp_ref.interview_suggestion s
                                where s.question_code = 'posting.item_classes' and s.value = pc.code)), '[]'::jsonb);
        v_sugg := erp.interview_suggestions('org.identity_level', null);

      elsif q.code = 'org.allocation_by_site' then
        v_left := coalesce((
          select jsonb_agg(jsonb_build_object('value', st.code, 'label', st.name, 'note', null::text, 'present', true)
                           order by st.code)
            from erp.site st
           where st.tenant_id = v_tenant and st.status = 'active'), '[]'::jsonb);
        v_sugg := coalesce((
          select jsonb_agg(x.value order by x.ord)
            from jsonb_array_elements(erp.interview_suggestions('org.allocation_method', null))
                 with ordinality x(value, ord)
           where x.value ->> 'value' in ('fifo', 'lifo')), '[]'::jsonb);

      elsif q.code = 'classification.values' then
        -- The groupings chosen above, and the pack's values on them.
        v_left := coalesce((
          select jsonb_agg(jsonb_build_object(
                   'value', li.code, 'label', coalesce(li.name, li.code), 'note', null::text,
                   'present', exists (select 1 from erp.classification_axis ca
                                       where ca.tenant_id = v_tenant and ca.code = li.code
                                         and ca.status = 'active'))
                 order by x.ord)
            from jsonb_array_elements(case when jsonb_typeof(v_eff -> 'classification.axes') = 'array'
                                           then v_eff -> 'classification.axes' else '[]'::jsonb end)
                 with ordinality x(value, ord)
            cross join lateral erp.interview_list_item(x.value) li
           where li.code is not null), '[]'::jsonb);
        v_sugg := coalesce((
          select jsonb_agg(s.value order by s.ord)
            from jsonb_array_elements(erp.interview_suggestions(q.code, null)) with ordinality s(value, ord)
           where jsonb_array_length(v_left) = 0
              or exists (select 1 from jsonb_array_elements(v_left) l
                          where l.value ->> 'value' = s.value ->> 'axis')), '[]'::jsonb);
        v_likely := (
          select jsonb_agg(jsonb_build_object('left', s.value ->> 'axis', 'right', s.value ->> 'label',
                                              'code', s.value ->> 'code')
                           order by s.ord)
            from jsonb_array_elements(v_sugg) with ordinality s(value, ord)
           where jsonb_array_length(v_left) > 0);
      end if;
    end if;

    code             := q.code;
    section          := q.section;
    surface          := q.surface;
    seq              := q.seq;
    prompt           := erp.interview_text(q.prompt_key, q.prompt);
    prompt_key       := q.prompt_key;
    help             := erp.interview_text(q.prompt_key || '.help', q.help);
    answer_shape     := q.answer_shape;
    choices          := q.choices;
    maps_to          := q.maps_to;
    is_required      := q.is_required;
    applies          := coalesce((v_applies ->> q.code)::boolean, false);
    answer           := v_raw -> q.code;
    applies_when     := q.applies_when;
    suggestions      := v_sugg;
    left_suggestions := v_left;
    likely           := v_likely;
    example          := case
                          when exists (select 1 from erp_ref.resource r
                                        where r.key = q.prompt_key || '.example' and r.locale = 'en')
                            then erp.text(q.prompt_key || '.example')
                        end;
    return next;
  end loop;
end;
$$;

comment on function erp.interview_questions(uuid) is
  'The onboarding questions for a session: the bank row translated, whether it '
  'applies through every gate, the answer given, and what to pick from — '
  'suggestions, the left-hand things a pair question pairs, a likely answer '
  'worked out for this organisation, and an example. Likely answers are read, '
  'never stored.';

revoke all on function erp.interview_questions(uuid) from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. An answer
-- ═════════════════════════════════════════════════════════════════════════════

-- Same signature and return type as 20260901170000.
create or replace function erp.answer_interview(p_session_id uuid, p_question_code text, p_answer jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  q        erp_ref.interview_question%rowtype;
  v_answer jsonb := p_answer;
  v_type   text;
  v_wrong  boolean;
  v_digits text;
begin
  if not exists (select 1 from erp.interview_session s
                  where s.tenant_id = v_tenant and s.id = p_session_id
                    and s.status = 'open') then
    raise exception 'CLOVEERP_INTERVIEW_NOT_OPEN: % is not an open interview',
      p_session_id using errcode = '23503',
      hint = 'Start a new interview, or carry on with one that is still open.';
  end if;

  select * into q from erp_ref.interview_question where code = p_question_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_QUESTION: %', p_question_code
      using errcode = '23503',
            hint = 'Answer a question the interview lists.';
  end if;

  -- A missing answer is a mistake by the caller, not a not-null violation
  -- nobody can read. The public door turns the screen's clear into JSON null
  -- before it gets here.
  if p_answer is null then
    raise exception 'CLOVEERP_ANSWER_MISSING: % was sent no answer', p_question_code
      using errcode = '22023',
            hint = 'Send an answer in the question''s shape, or JSON null to clear the answer.';
  end if;

  -- JSON null clears: a question answered by mistake can be left unanswered
  -- again, which is what "skip what does not apply" needs.
  if jsonb_typeof(p_answer) = 'null' then
    delete from erp.interview_answer ia
     where ia.tenant_id = v_tenant and ia.session_id = p_session_id
       and ia.question_code = p_question_code;
    return jsonb_build_object('question', p_question_code, 'cleared', true);
  end if;

  -- "5,000" is five thousand. Commas only in groups of three, so "1,0" is not
  -- quietly ten; anything else that is not a number stays a string and is
  -- refused below as the wrong shape.
  if q.answer_shape in ('integer', 'money') and jsonb_typeof(p_answer) = 'string' then
    v_digits := btrim(p_answer #>> '{}');
    if v_digits ~ '^-?([0-9]{1,3}(,[0-9]{3})+|[0-9]+)(\.[0-9]+)?$' then
      v_answer := to_jsonb(replace(v_digits, ',', '')::numeric);
    end if;
  end if;
  v_type := jsonb_typeof(v_answer);

  -- Assigned rather than written inline: plpgsql ends an IF condition at the
  -- first THEN token, and a CASE expression is full of them.
  v_wrong := case q.answer_shape
               when 'text'       then v_type <> 'string'
               when 'boolean'    then v_type <> 'boolean'
               when 'integer'    then v_type <> 'number'
               when 'money'      then v_type <> 'number'
               when 'choice'     then v_type <> 'string'
               when 'text_list'  then v_type <> 'array'
               when 'text_pairs' then v_type <> 'array'
               else false
             end;

  if v_wrong then
    raise exception
      'CLOVEERP_ANSWER_SHAPE: % expects %, and was given %',
      p_question_code, q.answer_shape, v_type using errcode = '22023',
      hint = 'Answer in the shape the question asks for.';
  end if;

  -- A whole number with a fraction would reach the proposer's integer cast and
  -- fail there, where nobody can see which answer caused it. Assigned first,
  -- for the same reason as above.
  v_wrong := case when q.answer_shape = 'integer' then (v_answer #>> '{}')::numeric % 1 <> 0 else false end;
  if v_wrong then
    raise exception
      'CLOVEERP_ANSWER_SHAPE: % expects a whole number, and was given %',
      p_question_code, v_answer #>> '{}' using errcode = '22023',
      hint = 'Give a whole number.';
  end if;

  -- A choice question with a free-text answer is how a question bank becomes
  -- decoration.
  if q.answer_shape = 'choice'
     and not (v_answer #>> '{}' = any (
                select jsonb_array_elements_text(q.choices)))
  then
    raise exception 'CLOVEERP_ANSWER_NOT_A_CHOICE: % is not one of %',
      v_answer #>> '{}', q.choices::text using errcode = '22023',
      hint = 'Pick one of the answers the question offers.';
  end if;

  -- The statutory numbering is a feature a plan may not carry. Asked here, so
  -- the refusal arrives with the answer rather than at promotion.
  if p_question_code = 'org.chart' and v_answer #>> '{}' = 'statutory'
     and not erp.capability_on_plan('statutory_chart_8_1') then
    raise exception
      'CLOVEERP_CAPABILITY_NOT_ON_PLAN: statutory_chart_8_1 is not available on this organisation''s plan or contract'
      using errcode = '42501',
            hint = 'Keep the standard numbering, or add the statutory numbering to the plan or contract first.';
  end if;

  insert into erp.interview_answer (tenant_id, session_id, question_code, answer)
  values (v_tenant, p_session_id, p_question_code, v_answer)
  on conflict (tenant_id, session_id, question_code)
    do update set answer = excluded.answer, updated_at = now();

  return jsonb_build_object('question', p_question_code, 'recorded', true);
end;
$$;

-- Same signature and return type as 20260901170000. PostgREST binds a named
-- argument through json_to_record, which turns a JSON null into SQL null, so
-- the screen cannot send the clear any other way.
create or replace function public.erp_answer_interview(p_session_id uuid, p_question_code text, p_answer jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.answer_interview(p_session_id, p_question_code, coalesce(p_answer, 'null'::jsonb));
end;
$$;

revoke all on function public.erp_answer_interview(uuid, text, jsonb) from public, anon;
grant execute on function public.erp_answer_interview(uuid, text, jsonb) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. A proposal knows the interview it came from
-- ═════════════════════════════════════════════════════════════════════════════

-- Until now the only tie was the title's text. The session cascades to its
-- proposals, as the tenant already does to both.
alter table erp_ai.proposal
  add column if not exists interview_session_id uuid references erp.interview_session(id) on delete cascade;
alter table erp_ai.proposal
  add column if not exists interview_section text;

comment on column erp_ai.proposal.interview_session_id is
  'The onboarding interview session an onboarding_interview proposal was made from. Null for every other kind.';
comment on column erp_ai.proposal.interview_section is
  'The interview section (B.1 to B.7) an onboarding_interview proposal covers. Null for every other kind.';

create index if not exists proposal_interview_session_idx
  on erp_ai.proposal (tenant_id, interview_session_id)
  where interview_session_id is not null;

-- Every proposal the interview made before this carries the title
-- format('Addendum B %s, from interview %s', section, session code), and the
-- session code is unique within an organisation.
update erp_ai.proposal p
   set interview_session_id = s.id,
       interview_section = x.section
  from erp.interview_session s
  cross join (select distinct iq.section from erp_ref.interview_question iq) x
 where p.kind = 'onboarding_interview'
   and p.interview_session_id is null
   and s.tenant_id = p.tenant_id
   and p.title = format('Addendum B %s, from interview %s', x.section, s.code);

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The proposers
-- ═════════════════════════════════════════════════════════════════════════════

-- Re-emitted from the live body (20260906080000:353, patched by
-- 20260906143000:941). What changed: answers are read through
-- erp.interview_effective_answers(); a statutory numbering answer adds the
-- feature, refused once accounts exist and refused with more than one company;
-- an existing company takes a change to its country or language, and to its
-- currency or financial year only while it has no general ledger, keeping
-- everything else it has; a company listed as new that already exists is
-- treated as the existing company it is; the allocation setting keeps what the
-- organisation already set beside the method; the variance account follows
-- the numbering answer; and the pair reader reads {left,right} first.
create or replace function erp.propose_organisation_shape(p_session_id uuid, p_change_set_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_pair jsonb; v_k text; v_v text;
  v_tenant uuid := erp.require_tenant_id();
  v_items  integer := 0;
  v_first  record;
  e        jsonb;
  v_code   text;
  v_ccy    text; v_ctry text; v_loc text; v_pack text;
  v_fy     integer;
  v_choice text;
  v_pairs  jsonb;
  v_chart  text;
  v_ccys   jsonb; v_ctrys jsonb; v_locs jsonb;
  v_listed text[] := '{}'::text[];
  v_ent    record;
  v_statutory boolean;
  v_renamed jsonb := '{}'::jsonb;
  v_active  integer;
  v_new     integer;
  v_name    text;
  v_fy_here integer;
  v_here    jsonb;
begin
  select e0.code, e0.base_currency, e0.country_code into v_first
    from erp.entity e0 where e0.tenant_id = v_tenant and e0.status = 'active' order by e0.code limit 1;

  v_statutory := erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date);

  -- The numbering. Standard is what the finance installer already does, so
  -- only statutory proposes anything, and only while it is not on. The
  -- statutory accounts cannot land beside a chart that already exists — the
  -- two use the same numbers for different things — so that is refused here,
  -- where the answer can still be changed.
  select (ia.answer #>> '{}') into v_chart from erp.interview_effective_answers(p_session_id) ia
   where ia.question_code = 'org.chart';

  -- The statutory numbering's accounts arrive as one pack, and a pack that
  -- names no company puts them all on the first company by code. A second
  -- company would get books and no accounts to post to, so the numbering
  -- covers one company for now: refused here, while the answers can change.
  select count(*) into v_active
    from erp.entity en where en.tenant_id = v_tenant and en.status = 'active';
  select count(distinct erp.slug_code(x.value ->> 'left')) into v_new
    from erp.interview_effective_answers(p_session_id) ia
   cross join lateral jsonb_array_elements(case when jsonb_typeof(ia.answer) = 'array'
                                                then ia.answer else '[]'::jsonb end) x
   where ia.question_code = 'org.companies'
     and erp.slug_code(x.value ->> 'left') is not null
     and coalesce(btrim(x.value ->> 'right'), '') <> ''
     and not exists (select 1 from erp.entity en
                      where en.tenant_id = v_tenant and en.status = 'active'
                        and en.code = erp.slug_code(x.value ->> 'left'));
  if v_chart = 'statutory' and not v_statutory and v_active + v_new > 1 then
    raise exception
      'CLOVEERP_INTERVIEW_CHART_ONE_COMPANY: statutory numbering can be set up for one company only for now, and this organisation would have %', v_active + v_new
      using errcode = '23514',
            hint = 'Keep the standard numbering, or leave the numbering question unanswered, while you have more than one company.';
  end if;
  if v_statutory and v_new > 0 then
    raise exception
      'CLOVEERP_INTERVIEW_CHART_ONE_COMPANY: this organisation numbers its nominal accounts by statutory ranges, which can be set up for one company only for now, so another company cannot be added'
      using errcode = '23514',
            hint = 'Leave the new companies out of this interview.';
  end if;

  if v_chart = 'statutory' and not v_statutory then
    if exists (select 1 from erp.account a where a.tenant_id = v_tenant) then
      raise exception
        'CLOVEERP_INTERVIEW_CHART_ALREADY_CHOSEN: this organisation already has nominal accounts, and the statutory numbering is chosen before any exist'
        using errcode = '23514',
              hint = 'Answer standard to the numbering question, or leave it unanswered.';
    end if;
    perform erp.add_change_set_item(p_change_set_id, 'capability', 'statutory_chart_8_1',
      jsonb_build_object('code', 'statutory_chart_8_1', 'enabled', true,
                         'reason', 'Chosen in the onboarding interview'));
    v_items := v_items + 1;
  end if;

  select (ia.answer #>> '{}')::integer into v_fy from erp.interview_effective_answers(p_session_id) ia
   where ia.question_code = 'org.fiscal_year_start';

  select ia.answer into v_ccys from erp.interview_effective_answers(p_session_id) ia
   where ia.question_code = 'org.currencies';
  select ia.answer into v_ctrys from erp.interview_effective_answers(p_session_id) ia
   where ia.question_code = 'org.countries';
  select ia.answer into v_locs from erp.interview_effective_answers(p_session_id) ia
   where ia.question_code = 'org.locales';
  v_ccys  := case when jsonb_typeof(v_ccys) = 'array' then v_ccys else '[]'::jsonb end;
  v_ctrys := case when jsonb_typeof(v_ctrys) = 'array' then v_ctrys else '[]'::jsonb end;
  v_locs  := case when jsonb_typeof(v_locs) = 'array' then v_locs else '[]'::jsonb end;

  -- Companies first, so their bindings promote after them (items promote in
  -- the order they were added).
  for e in
    select jsonb_array_elements(coalesce((
      select ia.answer from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'org.companies'), '[]'::jsonb))
  loop
    v_code := erp.slug_code(e ->> 'left');
    continue when v_code is null or coalesce(btrim(e ->> 'right'), '') = '';
    -- A company that already exists is not created again with defaults:
    -- promoting an entity item rewrites every field it has, so it is left to
    -- the loop below, which keeps what the company already holds, and only
    -- the name given here travels.
    if exists (select 1 from erp.entity en
                where en.tenant_id = v_tenant and en.status = 'active' and en.code = v_code) then
      v_renamed := v_renamed || jsonb_build_object(v_code, btrim(e ->> 'right'));
      continue;
    end if;
    v_listed := v_listed || v_code;
    select upper(btrim(x ->> 'right')) into v_ccy from jsonb_array_elements(v_ccys) x
     where erp.slug_code(x ->> 'left') = v_code limit 1;
    select upper(btrim(x ->> 'right')) into v_ctry from jsonb_array_elements(v_ctrys) x
     where erp.slug_code(x ->> 'left') = v_code limit 1;
    select btrim(x ->> 'right') into v_loc from jsonb_array_elements(v_locs) x
     where erp.slug_code(x ->> 'left') = v_code limit 1;

    perform erp.add_change_set_item(p_change_set_id, 'entity', v_code,
      jsonb_build_object(
        'code', v_code, 'name', btrim(e ->> 'right'),
        'currency', coalesce(v_ccy, v_first.base_currency),
        'country', coalesce(v_ctry, v_first.country_code),
        'locale', coalesce(v_loc, 'en'),
        'fiscal_year_start_month', coalesce(v_fy, 1)));
    v_items := v_items + 1;
  end loop;

  -- A company that already exists — the one every organisation starts with,
  -- most often — takes what this session says about its country and
  -- language. Its currency and financial year change only while it has no
  -- general ledger: after that they are in its books, so a company with one
  -- restates them as they are (and promotion refuses anything else).
  -- Everything it already has is restated, because promoting an entity item
  -- rewrites the company; and nothing is proposed where nothing would change.
  for v_ent in
    select en.code, en.name, en.legal_name,
           en.base_currency::text as base_currency, en.country_code::text as country_code,
           en.reporting_locale, en.document_locale, en.fiscal_year_start_month::integer as fiscal_year_start_month,
           (select pe.code from erp.entity pe
             where pe.tenant_id = v_tenant and pe.id = en.parent_entity_id) as parent_code,
           exists (select 1 from erp.ledger l
                    where l.tenant_id = v_tenant and l.entity_id = en.id and l.code = 'GL') as has_gl
      from erp.entity en
     where en.tenant_id = v_tenant and en.status = 'active'
       and not (en.code = any (v_listed))
     order by en.code
  loop
    select upper(btrim(x ->> 'right')) into v_ccy from jsonb_array_elements(v_ccys) x
     where erp.slug_code(x ->> 'left') = v_ent.code and nullif(btrim(x ->> 'right'), '') is not null limit 1;
    select upper(btrim(x ->> 'right')) into v_ctry from jsonb_array_elements(v_ctrys) x
     where erp.slug_code(x ->> 'left') = v_ent.code and nullif(btrim(x ->> 'right'), '') is not null limit 1;
    select btrim(x ->> 'right') into v_loc from jsonb_array_elements(v_locs) x
     where erp.slug_code(x ->> 'left') = v_ent.code and nullif(btrim(x ->> 'right'), '') is not null limit 1;
    v_fy_here := v_fy;
    if v_ent.has_gl then
      v_ccy := null;
      v_fy_here := null;
    end if;
    v_name := coalesce(nullif(v_renamed ->> v_ent.code, ''), v_ent.name);

    continue when coalesce(v_ccy, v_ent.base_currency) is not distinct from v_ent.base_currency
              and coalesce(v_ctry, v_ent.country_code) is not distinct from v_ent.country_code
              and coalesce(v_loc, v_ent.reporting_locale) is not distinct from v_ent.reporting_locale
              and coalesce(v_loc, v_ent.document_locale) is not distinct from v_ent.document_locale
              and coalesce(v_fy_here, v_ent.fiscal_year_start_month) is not distinct from v_ent.fiscal_year_start_month
              and v_name is not distinct from v_ent.name;

    perform erp.add_change_set_item(p_change_set_id, 'entity', v_ent.code,
      jsonb_build_object(
        'code', v_ent.code, 'name', v_name, 'legal_name', v_ent.legal_name,
        'currency', coalesce(v_ccy, v_ent.base_currency),
        'country', coalesce(v_ctry, v_ent.country_code),
        'locale', coalesce(v_loc, v_ent.reporting_locale),
        'document_locale', coalesce(v_loc, v_ent.document_locale),
        'fiscal_year_start_month', coalesce(v_fy_here, v_ent.fiscal_year_start_month),
        'parent', v_ent.parent_code));
    v_items := v_items + 1;
  end loop;

  for e in
    select jsonb_array_elements(coalesce((
      select ia.answer from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'org.legislation'), '[]'::jsonb))
  loop
    v_code := erp.slug_code(e ->> 'left');
    v_pack := lower(btrim(e ->> 'right'));
    continue when v_code is null or coalesce(v_pack, '') = '';
    if not exists (select 1 from erp_ref.legislation_pack lp where lp.code = v_pack and lp.is_current) then
      raise exception 'CLOVEERP_UNKNOWN_LEGISLATION_PACK: % is not a legislation pack the product ships', v_pack
        using errcode = '23503',
              hint = 'Name a current pack code from erp_ref.legislation_pack, or leave the legislation question unanswered.';
    end if;
    perform erp.add_change_set_item(p_change_set_id, 'legislation_binding', v_code || '|' || v_pack,
      jsonb_build_object('entity', v_code, 'pack', v_pack,
                         'pack_version', (select lp.version from erp_ref.legislation_pack lp where lp.code = v_pack and lp.is_current order by lp.version desc limit 1)));
    v_items := v_items + 1;
  end loop;

  select (ia.answer #>> '{}') into v_choice from erp.interview_effective_answers(p_session_id) ia
   where ia.question_code = 'org.costing_method';
  if v_choice in ('average', 'standard', 'fifo') then
    -- The variance account in the numbering being chosen: this session's
    -- statutory answer is not on yet, so it cannot be read from the feature.
    perform erp.add_change_set_item(p_change_set_id, 'costing_policy', 'DEFAULT',
      jsonb_build_object('code', 'DEFAULT', 'name', 'Default costing', 'method', v_choice,
                         'variance_account', case when v_choice = 'standard' then
                           case when v_chart = 'statutory'
                                then (select cp.statutory_code from erp_ref.chart_account_purpose cp
                                       where cp.purpose = 'purchase_price_variance')
                                else erp.chart_account_code('purchase_price_variance') end
                         end));
    v_items := v_items + 1;
  end if;

  select (ia.answer #>> '{}') into v_choice from erp.interview_effective_answers(p_session_id) ia
   where ia.question_code = 'org.identity_level';
  if v_choice in ('none', 'unit', 'case', 'carton', 'pallet', 'master_pallet') then
    perform erp.add_change_set_item(p_change_set_id, 'container_identity_policy', 'DEFAULT',
      jsonb_build_object('code', 'DEFAULT', 'name', 'Default identity level',
                         'identity_level', v_choice,
                         'count_method', case when v_choice in ('none', 'unit') then 'by_unit' else 'hybrid' end));
    v_items := v_items + 1;
  end if;

  select (ia.answer #>> '{}') into v_choice from erp.interview_effective_answers(p_session_id) ia
   where ia.question_code = 'org.allocation_method';
  if v_choice in ('fefo', 'fifo', 'lifo') then
    -- The setting is written whole, so the rest of what is in force now —
    -- one batch per order, the nearest location first — is carried beside
    -- the method rather than put back to a default.
    perform erp.add_change_set_item(p_change_set_id, 'config', 'stock.allocation_policy',
      jsonb_build_object('config_type', 'stock.allocation_policy',
                         'value', jsonb_build_object('expiry_controlled', 'fefo',
                                                     'single_batch_per_order', false, 'prefer_nearest_location', true)
                                  || case when jsonb_typeof(erp.config_value('stock.allocation_policy')) = 'object'
                                          then erp.config_value('stock.allocation_policy') else '{}'::jsonb end
                                  || jsonb_build_object('default', v_choice)));
    v_items := v_items + 1;
  end if;

  -- Policies that differ by product class or by site: one scoped item per pair.
  -- {left,right} is what every pair question writes; the positional and named
  -- forms are still read.
  for v_pair in
    select pe.value from erp.interview_effective_answers(p_session_id) ia
    cross join lateral jsonb_array_elements(case when jsonb_typeof(ia.answer) = 'array' then ia.answer else '[]'::jsonb end) pe
     where ia.question_code = 'org.identity_by_class'
  loop
    v_k := upper(btrim(coalesce(v_pair ->> 'left', v_pair ->> 0, v_pair ->> 'class', v_pair ->> 'key')));
    v_v := lower(btrim(coalesce(v_pair ->> 'right', v_pair ->> 1, v_pair ->> 'level', v_pair ->> 'value')));
    continue when coalesce(v_k, '') = '' or v_v not in ('none', 'unit', 'case', 'carton', 'pallet', 'master_pallet');
    perform erp.add_change_set_item(p_change_set_id, 'container_identity_policy', 'CLASS-' || v_k,
      jsonb_build_object('code', 'CLASS-' || v_k, 'name', 'Identity for ' || v_k, 'item_class', v_k,
                         'identity_level', v_v,
                         'count_method', case when v_v in ('none', 'unit') then 'by_unit' else 'hybrid' end));
    v_items := v_items + 1;
  end loop;
  for v_pair in
    select pe.value from erp.interview_effective_answers(p_session_id) ia
    cross join lateral jsonb_array_elements(case when jsonb_typeof(ia.answer) = 'array' then ia.answer else '[]'::jsonb end) pe
     where ia.question_code = 'org.allocation_by_site'
  loop
    v_k := upper(btrim(coalesce(v_pair ->> 'left', v_pair ->> 0, v_pair ->> 'site', v_pair ->> 'key')));
    v_v := lower(btrim(coalesce(v_pair ->> 'right', v_pair ->> 1, v_pair ->> 'method', v_pair ->> 'value')));
    continue when coalesce(v_k, '') = '' or v_v not in ('fefo', 'fifo', 'lifo');
    -- What applies at that site now, carried beside the method as above.
    v_here := (select erp.config_value('stock.allocation_policy', null, null, s2.entity_id, s2.id)
                 from erp.site s2 where s2.tenant_id = v_tenant and s2.code = v_k);
    perform erp.add_change_set_item(p_change_set_id, 'config', 'stock.allocation_policy|*|' || v_k,
      jsonb_build_object('config_type', 'stock.allocation_policy', 'site', v_k,
                         'entity', (select e2.code from erp.site s2 join erp.entity e2 on e2.id = s2.entity_id
                                       where s2.tenant_id = v_tenant and s2.code = v_k),
                         'value', jsonb_build_object('expiry_controlled', 'fefo',
                                                     'single_batch_per_order', false, 'prefer_nearest_location', true)
                                  || case when jsonb_typeof(v_here) = 'object' then v_here else '{}'::jsonb end
                                  || jsonb_build_object('default', v_v)));
    v_items := v_items + 1;
  end loop;

  return v_items;
end;
$$;

comment on function erp.propose_organisation_shape(uuid, uuid) is
  'Turns the interview''s organisation-shape answers into change-set items: the '
  'statutory numbering when chosen, new companies, changes to an existing company '
  'whose books are not set up, legislation bindings, a default costing policy, a '
  'default identity level and the allocation setting, reading only answers whose '
  'question applies.';

-- Re-emitted from the live body (20260901170000:394, patched by
-- 20260906080000:474). What changed: sections and answers are read through
-- erp.interview_effective_answers(); list elements go through
-- erp.interview_list_item(), so a picked code is kept; classification values
-- take a supplied code, the grouping it was chosen under and the pack's
-- abbreviation; the threshold follows the currency's minor units; the
-- change-set code carries the session rather than the second; and the
-- proposal records its session and section.
--
-- And a record that already exists is never restated with blanks. Promoting
-- a department, an approval band, a grouping, a value, a product code pattern
-- or a marshalling area rewrites every field the promoter reads, so a field
-- the answer does not speak to is carried from the record as it stands: a
-- department keeps its cost centre, parent, company and manager; a grouping
-- keeps its product kinds, order and name key, and stays compulsory once it
-- is; a value keeps its abbreviation, parent and name key. A new department
-- takes the cost centre its starter pack suggests, and a new grouping the
-- order and compulsion its pack gives it.
create or replace function erp_ai.propose_from_interview(p_session_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  s          erp.interview_session%rowtype;
  v_section  record;
  v_cs       uuid;
  v_prop     uuid;
  v_items    integer;
  v_total    integer := 0;
  v_out      jsonb := '[]'::jsonb;
  a          jsonb;
  e          jsonb;
  v_code     text;
  v_name     text;
  v_axis     text;
  v_axes     jsonb;
  v_ccy      text;
  v_minor    integer;
  v_role     text;
  v_lm       boolean;
  v_obj      text;
  v_json     jsonb;
  v_lower    bigint;
begin
  select * into s from erp.interview_session
   where tenant_id = v_tenant and id = p_session_id for update;

  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INTERVIEW: %', p_session_id using errcode = '23503';
  end if;
  if s.status <> 'open' then
    raise exception 'CLOVEERP_INTERVIEW_NOT_OPEN: % is %', s.code, s.status
      using errcode = '23514';
  end if;

  if not exists (select 1 from erp.interview_answer
                  where tenant_id = v_tenant and session_id = p_session_id) then
    raise exception
      'CLOVEERP_INTERVIEW_EMPTY: % has no answers, and a proposal with no diff '
      'behind it is the hollow thing this was built to avoid', s.code
      using errcode = '23514';
  end if;

  -- Only answers whose question applies: an answer left behind under a gate
  -- that was later answered no is not what the person said in the end.
  for v_section in
    select distinct ia.section
      from erp.interview_effective_answers(p_session_id) ia
      join erp_ref.interview_question q on q.code = ia.question_code
     where q.maps_to is not null
     order by ia.section
  loop
    -- The session's code is unique in the organisation and a session proposes
    -- once, so two sessions proposed in the same second no longer collide.
    v_cs := erp.create_change_set(
      format('interview-%s-%s', lower(replace(v_section.section, '.', '')), s.code),
      format('Onboarding interview — %s', v_section.section),
      format('Proposed from the answers given in interview %s.', s.code));
    v_items := 0;

    -- ── B.1 Departments ──────────────────────────────────────────────────
    if v_section.section = 'B.1' then
      select ia.answer into a from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'dept.list';

      for e in select jsonb_array_elements(coalesce(a, '[]'::jsonb)) loop
        select li.code, li.name into v_code, v_name from erp.interview_list_item(e) li;
        continue when v_code is null;
        -- The payload keys erp.apply_change_set_item()'s department arm reads.
        v_json := (
          select jsonb_build_object(
                   'default_cost_centre', d.default_cost_centre,
                   'parent', (select pd.code from erp.department pd
                               where pd.tenant_id = d.tenant_id and pd.id = d.parent_department_id),
                   'entity', (select en.code from erp.entity en
                               where en.tenant_id = d.tenant_id and en.id = d.entity_id),
                   'manager_email', (select u.email from erp.app_user u
                                      where u.tenant_id = d.tenant_id and u.id = d.manager_user_id))
            from erp.department d
           where d.tenant_id = v_tenant and d.code = upper(v_code));
        if v_json is null then
          v_json := (
            select jsonb_build_object('default_cost_centre', nullif(pi.payload ->> 'default_cost_centre', ''))
              from erp_ref.pack_item pi
             where pi.object_kind = 'department' and pi.object_key = upper(v_code) and not pi.is_decision
             order by pi.pack_code
             limit 1);
        end if;
        perform erp.add_change_set_item(v_cs, 'department', v_code,
          jsonb_strip_nulls(jsonb_build_object('code', v_code, 'name', v_name)
                            || coalesce(v_json, '{}'::jsonb)));
        v_items := v_items + 1;
      end loop;
    end if;

    -- ── B.2 Approvals ────────────────────────────────────────────────────
    if v_section.section = 'B.2' then
      select (ia.answer #>> '{}') into v_obj from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'approval.object_type';
      select (ia.answer #>> '{}') into v_ccy from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'approval.currency';
      select (ia.answer #>> '{}') into v_role from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'approval.role';
      select coalesce((ia.answer)::text = 'true', false) into v_lm
        from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'approval.line_manager';
      select ia.answer into a from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'approval.threshold';
      -- Minor units are the currency's: a hundred pence to the pound, one yen
      -- to the yen.
      select c.minor_units into v_minor from erp_ref.currency c
       where c.code = coalesce(v_ccy, 'GBP');

      -- A band with no way to find an approver is refused by
      -- erp.upsert_approval_band(), so it is refused here rather than promoted
      -- and rejected at the far end.
      if a is not null and (v_role is not null or v_lm) then
        -- One band per department named in B.1: an approval rule that names no
        -- department applies to nothing.
        for e in
          select d.value from jsonb_array_elements(
            coalesce((select ia.answer from erp.interview_effective_answers(p_session_id) ia
                       where ia.question_code = 'dept.list'), '[]'::jsonb)) d
        loop
          select li.code into v_code from erp.interview_list_item(e) li;
          continue when v_code is null;
          v_lower := round((a #>> '{}')::numeric * (10::numeric ^ coalesce(v_minor, 2)))::bigint;
          -- A first band this department already has keeps what the answers
          -- do not speak to: its ceiling (while it is still above the new
          -- threshold), escalation, vacancy, tolerance and whether approvers
          -- sign in parallel.
          v_json := (
            select jsonb_build_object(
                     'upper_bound_minor', case when ab.upper_bound_minor > v_lower then ab.upper_bound_minor end,
                     'is_parallel', ab.is_parallel,
                     'rerun_lower_bands', ab.rerun_lower_bands,
                     'escalate_after_hours', round(extract(epoch from ab.escalate_after) / 3600)::integer,
                     'vacancy', ab.vacancy::text,
                     'tolerance_pct', ab.tolerance_pct)
              from erp.approval_band ab
              join erp.department d on d.tenant_id = ab.tenant_id and d.id = ab.department_id
             where ab.tenant_id = v_tenant and d.code = upper(v_code)
               and ab.object_type = coalesce(v_obj, 'purchase_order') and ab.seq = 1
               and ab.status = 'active'
             order by ab.valid_from desc
             limit 1);
          perform erp.add_change_set_item(v_cs, 'approval_band',
            format('%s|%s|1', v_code, coalesce(v_obj, 'purchase_order')),
            jsonb_strip_nulls(coalesce(v_json, '{}'::jsonb) || jsonb_build_object(
              'department', v_code,
              'object_type', coalesce(v_obj, 'purchase_order'),
              'seq', 1,
              'lower_bound_minor', v_lower,
              'currency', coalesce(v_ccy, 'GBP'),
              'approver_role', v_role,
              'use_line_manager', v_lm)));
          v_items := v_items + 1;
        end loop;
      end if;
    end if;

    -- ── B.3 Posting classes and determination ────────────────────────────
    if v_section.section = 'B.3' then
      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_effective_answers(p_session_id) ia
           where ia.question_code = 'posting.item_classes'), '[]'::jsonb))
      loop
        select li.code, li.name into v_code, v_name from erp.interview_list_item(e) li;
        continue when v_code is null;
        perform erp.add_change_set_item(v_cs, 'posting_class',
          'item|' || v_code,
          jsonb_build_object('kind', 'item', 'code', v_code,
                             'name', v_name));
        v_items := v_items + 1;
      end loop;

      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_effective_answers(p_session_id) ia
           where ia.question_code = 'posting.party_classes'), '[]'::jsonb))
      loop
        select li.code, li.name into v_code, v_name from erp.interview_list_item(e) li;
        continue when v_code is null;
        perform erp.add_change_set_item(v_cs, 'posting_class',
          'party|' || v_code,
          jsonb_build_object('kind', 'party', 'code', v_code,
                             'name', v_name));
        v_items := v_items + 1;
      end loop;

      select (ia.answer #>> '{}') into v_code from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'posting.receipt_account';

      if nullif(btrim(coalesce(v_code, '')), '') is not null then
        perform erp.add_change_set_item(v_cs, 'account_determination',
          'goods_receipt|-|-|-|-|-|-|-',
          jsonb_build_object('transaction_type', 'goods_receipt',
                             'account', btrim(v_code)));
        v_items := v_items + 1;
      end if;
    end if;

    -- ── B.4 Classification ───────────────────────────────────────────────
    if v_section.section = 'B.4' then
      select coalesce((ia.answer)::text = 'true', false) into v_lm
        from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'classification.mandatory';

      select ia.answer into v_axes from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'classification.axes';

      for e in select jsonb_array_elements(coalesce(v_axes, '[]'::jsonb)) loop
        select li.code, li.name into v_code, v_name from erp.interview_list_item(e) li;
        continue when v_code is null;
        -- The payload keys erp.apply_change_set_item()'s classification_axis
        -- arm reads. The compulsory answer can make a grouping compulsory,
        -- never optional again: the base pack makes product type compulsory
        -- because determination reads it first.
        v_json := (
          select jsonb_build_object(
                   'item_classes', array_to_string(ca.item_classes, ','),
                   'seq', ca.seq,
                   'name_key', ca.name_key,
                   'is_mandatory', ca.is_mandatory or coalesce(v_lm, false))
            from erp.classification_axis ca
           where ca.tenant_id = v_tenant and ca.code = upper(v_code));
        if v_json is null then
          v_json := (
            select jsonb_build_object(
                     'seq', case when jsonb_typeof(pi.payload -> 'seq') = 'number'
                                 then (pi.payload ->> 'seq')::integer end,
                     'is_mandatory', coalesce(pi.payload -> 'is_mandatory' = 'true'::jsonb, false)
                                     or coalesce(v_lm, false))
              from erp_ref.pack_item pi
             where pi.object_kind = 'classification_axis' and pi.object_key = upper(v_code) and not pi.is_decision
             order by pi.pack_code
             limit 1);
        end if;
        perform erp.add_change_set_item(v_cs, 'classification_axis', v_code,
          jsonb_strip_nulls(jsonb_build_object('code', v_code, 'name', v_name,
                                               'is_mandatory', coalesce(v_lm, false))
                            || coalesce(v_json, '{}'::jsonb)));
        v_items := v_items + 1;
      end loop;

      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_effective_answers(p_session_id) ia
           where ia.question_code = 'classification.values'), '[]'::jsonb))
      loop
        -- The grouping is the one chosen above that the left side names, by
        -- code or by name, so a picked STORAGE_COND stays STORAGE_COND; else
        -- the typed name slugged, as before.
        v_axis := coalesce(
          upper(nullif(btrim(e ->> 'axis'), '')),
          (select li.code
             from jsonb_array_elements(coalesce(v_axes, '[]'::jsonb)) x
            cross join lateral erp.interview_list_item(x.value) li
            where li.code = upper(btrim(e ->> 'left'))
               or lower(li.name) = lower(btrim(e ->> 'left'))
            order by (li.code = upper(btrim(e ->> 'left'))) desc
            limit 1),
          erp.slug_code(e ->> 'left'));
        v_code := coalesce(upper(nullif(btrim(e ->> 'code'), '')), erp.slug_code(e ->> 'right'));
        continue when v_axis is null or v_code is null;
        -- A value that already exists keeps its abbreviation — codes may
        -- already be built from it — its parent and its name key.
        v_json := (
          select jsonb_build_object(
                   'abbreviation', cv.abbreviation,
                   'parent', (select pv.code from erp.classification_value pv
                               where pv.tenant_id = cv.tenant_id and pv.id = cv.parent_value_id),
                   'name_key', cv.name_key)
            from erp.classification_value cv
            join erp.classification_axis ca on ca.tenant_id = cv.tenant_id and ca.id = cv.axis_id
           where cv.tenant_id = v_tenant and ca.code = upper(v_axis) and cv.code = upper(v_code));
        perform erp.add_change_set_item(v_cs, 'classification_value',
          v_axis || '|' || v_code,
          jsonb_strip_nulls(jsonb_build_object(
            'axis', v_axis,
            'code', v_code,
            'name', coalesce(nullif(btrim(e ->> 'right'), ''), v_code),
            'abbreviation', coalesce(
              (select pi.payload ->> 'abbreviation' from erp_ref.pack_item pi
                where pi.object_kind = 'classification_value'
                  and pi.object_key = v_axis || '|' || v_code
                order by pi.pack_code limit 1),
              nullif(left(regexp_replace(v_code, '[^A-Z0-9]', '', 'g'), 4), ''),
              left(v_code, 4)))
            || coalesce(v_json, '{}'::jsonb)));
        v_items := v_items + 1;
      end loop;
    end if;

    -- ── B.5 Code templates ───────────────────────────────────────────────
    if v_section.section = 'B.5' then
      select (ia.answer #>> '{}') into v_code from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'code.prefix';
      select ia.answer into a from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'code.digits';

      if nullif(btrim(coalesce(v_code, '')), '') is not null then
        -- A pattern that already exists keeps its name, casing, the product
        -- kinds it covers and its company; the answers speak to its shape.
        v_json := (
          select jsonb_build_object(
                   'name', ct.name,
                   'casing', ct.casing,
                   'item_classes', array_to_string(ct.item_classes, ','),
                   'entity', (select en.code from erp.entity en
                               where en.tenant_id = ct.tenant_id and en.id = ct.entity_id))
            from erp.code_template ct
           where ct.tenant_id = v_tenant and ct.code = 'ITEM'
           order by ct.version desc
           limit 1);
        perform erp.add_change_set_item(v_cs, 'code_template', 'ITEM',
          jsonb_strip_nulls(jsonb_build_object(
            'code', 'ITEM', 'name', 'Item code', 'casing', 'upper')
            || coalesce(v_json, '{}'::jsonb)
            || jsonb_build_object(
            'segments', jsonb_build_array(
              jsonb_build_object('kind', 'literal', 'value', upper(btrim(v_code))),
              jsonb_build_object('kind', 'sequence',
                                 'length', greatest(1, coalesce((a #>> '{}')::integer, 6)))))));
        v_items := v_items + 1;
      end if;
    end if;

    -- ── B.6 Release areas ────────────────────────────────────────────────
    if v_section.section = 'B.6' then
      -- A release area belongs to a site, and the promoter refuses one it
      -- cannot place. Refusing here, where the message can say what to do
      -- about it, beats refusing at promotion where it reads as a failure of
      -- the change set rather than of the answer.
      if not exists (select 1 from erp.site st
                      where st.tenant_id = v_tenant and st.status = 'active') then
        raise exception
          'CLOVEERP_INTERVIEW_NEEDS_SITE: release areas belong to a site and this '
          'organisation has none yet. Create a site first, or leave the release '
          'area questions unanswered.'
          using errcode = '23503';
      end if;

      select (ia.answer #>> '{}') into v_obj from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'release.mode';
      select ia.answer into a from erp.interview_effective_answers(p_session_id) ia
       where ia.question_code = 'release.ageing_hours';

      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_effective_answers(p_session_id) ia
           where ia.question_code = 'release.areas'), '[]'::jsonb))
      loop
        select li.code, li.name into v_code, v_name from erp.interview_list_item(e) li;
        continue when v_code is null;
        -- An area that already exists on the site it would land on keeps its
        -- location, channel, order type, product kinds, quantities and
        -- whether it holds printing back.
        v_json := (
          select jsonb_build_object(
                   'location', (select l.code from erp.location l
                                 where l.tenant_id = ra.tenant_id and l.id = ra.location_id),
                   'channel', ra.channel_code,
                   'order_type', ra.order_type_code,
                   'item_classes', array_to_string(ra.item_classes, ','),
                   'min_quantity', ra.min_quantity,
                   'max_quantity', ra.max_quantity,
                   'gate_printing', ra.gate_printing)
            from erp.release_area ra
           where ra.tenant_id = v_tenant and ra.code = upper(v_code)
             and ra.site_id = (select st.id from erp.site st
                                where st.tenant_id = v_tenant and st.status = 'active'
                                order by st.code limit 1));
        perform erp.add_change_set_item(v_cs, 'release_area', v_code,
          jsonb_strip_nulls(coalesce(v_json, '{}'::jsonb) || jsonb_build_object(
            'code', v_code, 'name', v_name,
            'replenishment_mode', coalesce(v_obj, 'pull'),
            'ageing_hours', greatest(1, coalesce((a #>> '{}')::integer, 72)))));
        v_items := v_items + 1;
      end loop;
    end if;

    -- A section that produced nothing gets no proposal and no empty change set
    -- left behind to be found later and wondered about.
    if v_section.section = 'B.7' then
      v_items := v_items + erp.propose_organisation_shape(p_session_id, v_cs);
    end if;

    if v_items = 0 then
      delete from erp.change_set where tenant_id = v_tenant and id = v_cs;
      continue;
    end if;

    insert into erp_ai.proposal (
      tenant_id, kind, title, rationale, change_set_id, status,
      produced_by, producer_label, interview_session_id, interview_section)
    values (
      v_tenant, 'onboarding_interview',
      format('Addendum B %s, from interview %s', v_section.section, s.code),
      format('Proposed from %s answer(s) given in interview %s. Every item '
             'below is a change-set item promoted through B6 like any other; '
             'nothing here writes configuration directly. Review the diff '
             'rather than this sentence.',
             (select count(*) from erp.interview_effective_answers(p_session_id) ia
              where ia.section = v_section.section), s.code),
      v_cs, 'proposed',
      -- Null on purpose. The person answered questions; the mapping from
      -- answers to a diff was made by the product, and recording them as the
      -- producer would block them from reviewing it under the self-approval
      -- rule for something they did not author.
      null, 'onboarding interview', p_session_id, v_section.section)
    returning id into v_prop;

    -- Explainability, §3.12: what was looked at, not just what was concluded.
    insert into erp_ai.proposal_evidence
      (tenant_id, proposal_id, source_kind, source_ref, observation)
    select v_tenant, v_prop, 'interview_answer', ia.question_code,
           format('%s — answered %s', q.prompt, ia.answer::text)
      from erp.interview_effective_answers(p_session_id) ia
      join erp_ref.interview_question q on q.code = ia.question_code
     where ia.section = v_section.section;

    v_total := v_total + v_items;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'section', v_section.section, 'proposal_id', v_prop,
      'change_set_id', v_cs, 'items', v_items));
  end loop;

  if v_total = 0 then
    raise exception
      'CLOVEERP_INTERVIEW_PROPOSES_NOTHING: % was answered but nothing it said '
      'turns into a change. Answering "no" to every gate is a valid interview '
      'and an empty proposal is not a useful one.', s.code
      using errcode = '23514';
  end if;

  update erp.interview_session
     set status = 'proposed', proposed_at = now(), updated_at = now()
   where id = p_session_id;

  return jsonb_build_object('interview', s.code, 'items', v_total,
                            'proposals', v_out);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Two reads for the screen
-- ═════════════════════════════════════════════════════════════════════════════

-- The interviews this organisation has, to resume one: open first, then the
-- newest; each with how far every section has got and where its proposed
-- changes stand. Sections run in the order the screen asks them, organisation
-- first.
create or replace function public.erp_interview_sessions()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.require_tenant_id();

  return jsonb_build_object(
    'live', erp.tenant_is_live(),
    'sessions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'session_id', s.id,
               'code', s.code,
               'status', s.status,
               'started_at', s.started_at,
               'proposed_at', s.proposed_at,
               'sections', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'section', x.section, 'questions', x.questions,
                          'applicable', x.applicable, 'answered', x.answered)
                        order by case when x.section = 'B.7' then 0 else 1 end, x.section)
                   from (select q.section,
                                count(*) as questions,
                                count(*) filter (where coalesce(ap.applies, false)) as applicable,
                                count(*) filter (where coalesce(ap.applies, false) and ia.id is not null) as answered
                           from erp_ref.interview_question q
                           left join erp.interview_applies(s.id) ap on ap.question_code = q.code
                           left join erp.interview_answer ia
                             on ia.tenant_id = v_tenant and ia.session_id = s.id and ia.question_code = q.code
                          group by q.section) x), '[]'::jsonb),
               'proposals', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'section', p.interview_section,
                          'proposal_id', p.id,
                          'change_set_id', cs.id,
                          'change_set_code', cs.code,
                          'change_set_status', cs.status::text,
                          'item_count', (select count(*) from erp.change_set_item i
                                          where i.tenant_id = v_tenant and i.change_set_id = cs.id))
                        order by case when p.interview_section = 'B.7' then 0 else 1 end,
                                 p.interview_section, p.created_at)
                   from erp_ai.proposal p
                   left join erp.change_set cs on cs.tenant_id = p.tenant_id and cs.id = p.change_set_id
                  where p.tenant_id = v_tenant
                    and p.kind = 'onboarding_interview'
                    and p.interview_session_id = s.id), '[]'::jsonb))
             order by (s.status = 'open') desc, s.started_at desc, s.code)
        from erp.interview_session s
       where s.tenant_id = v_tenant and s.status <> 'abandoned'), '[]'::jsonb));
end;
$$;

revoke all on function public.erp_interview_sessions() from public, anon;
grant execute on function public.erp_interview_sessions() to authenticated, service_role;

-- The lines of one change, in the order promotion applies them, so the screen
-- can say what each will do before anybody accepts it.
create or replace function public.erp_change_set_items(p_change_set_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('administration.read', null, null, null, 'change_set', p_change_set_id);
  v_tenant := erp.require_tenant_id();

  if not exists (select 1 from erp.change_set cs
                  where cs.tenant_id = v_tenant and cs.id = p_change_set_id) then
    raise exception 'CLOVEERP_CHANGE_SET_NOT_FOUND: no change % in this organisation', p_change_set_id
      using errcode = '23503',
            hint = 'Open a change listed on the Configuration or Onboarding screen.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'item_id', i.id,
             'seq', i.seq,
             'object_kind', i.object_kind,
             'object_key', i.object_key,
             'operation', i.operation::text,
             'payload', i.payload,
             'note', i.note)
           order by case i.object_kind
                      when 'entity' then 0 when 'role' then 1 when 'terminology' then 2
                      when 'config' then 3 when 'legislation_binding' then 4
                      when 'event_subscription' then 5 when 'rule_set' then 6
                      when 'state_machine' then 7 when 'approval_chain' then 8
                      else 9
                    end, i.seq)
      from erp.change_set_item i
     where i.tenant_id = v_tenant and i.change_set_id = p_change_set_id), '[]'::jsonb);
end;
$$;

revoke all on function public.erp_change_set_items(uuid) from public, anon;
grant execute on function public.erp_change_set_items(uuid) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 11. Registers, generators, and the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_interview_sessions', 'erp.authorise',
   'A read of this organisation''s onboarding interviews, their progress and their proposed changes. Volatile because erp.authorise() records the access decision; writes nothing else. administration.configure.'),
  ('erp_change_set_items', 'erp.authorise',
   'A read of one change''s lines in promotion order. Volatile because erp.authorise() records the access decision; writes nothing else. administration.read.'),
  ('erp_answer_interview', 'erp.authorise',
   'Records or clears one answer. Writes erp.interview_answer and nothing else. administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/administration/onboarding',
  array['erp_interview_sessions', 'erp_change_set_items']);

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_intelligence_boundary();
select erp.assert_guidance_sound();
select erp.assert_setup_walkthrough_actionable();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp_test.assert_onboarding_interview_suite();
select erp_test.assert_companies_suite();
select erp_test.assert_legislation_packs_suite();
