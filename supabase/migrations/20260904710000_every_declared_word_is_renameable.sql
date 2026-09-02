-- ─────────────────────────────────────────────────────────────────────────────
-- Every word a module declares is a word a tenant can change.
--
-- supabase/ci/screen_strings.sh has enforced one rule since it was written: a
-- ui("…") literal with no erp_ref.resource row cannot be renamed by an
-- organisation, and this product's claim is that every visible word can be.
-- It looked only at literals, because that is what a grep can see.
--
-- src/lib/modules.tsx is where that leaves a hole. It is a declaration, not a
-- screen: a module states its title, its blurb, its panels, their empty states
-- and their column headers as data, and the components render every one of them
-- through ui(). The words are just as visible as any literal — they are the
-- module tiles, the launchpad, the tab strips, the tables — and the check could
-- not see a single one of them, because by the time they reach ui() they are a
-- variable.
--
-- Measured rather than assumed: 473 declared strings and 474 literals, 903
-- distinct between them, of which 114 had no row at any locale. This migration
-- seeds all 114, and the same commit teaches screen_strings.sh to read the
-- declaration as well as the literals, so the hole does not reopen the next
-- time a panel is added. The check went from 487 strings to 903.
--
-- Most of the 114 are this branch's own: the Sage X3 module names, Product and
-- Business partner in place of Item and Party, Marshalling area in place of
-- Release area, and the empty states that now name what to do next rather than
-- reporting that nothing is there. The rest are older drift — blurbs rewritten
-- in the front end without the row that makes them renameable following behind.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text, 'Screen string declared in src/lib/modules.tsx or written as a ui() literal.'
  from (values
    ('1–30'),
    ('31–60'),
    ('60+'),
    ('A mandatory axis must be answered before a product can be created.'),
    ('Accessibility'),
    ('Allocated stock scopes, pull and push replenishment, ageing back to bulk, and print gating.'),
    ('Assembled from price items with margin live, discount approval routed, every version retained, the order form rendered.'),
    ('Business partner'),
    ('Business partner data quality'),
    ('Business partners and their posting class'),
    ('Categories and codes'),
    ('Classification axes and values, code templates composed from them, completeness gaps and divergences.'),
    ('Common data'),
    ('Continuity and incidents'),
    ('Coverage could not be measured. The report itself returned nothing, which is not the same as full coverage.'),
    ('Customers overdue'),
    ('Default suppliers, preference ranks, sourcing splits and approved-for-use status.'),
    ('Despatch'),
    ('Devices and scanning'),
    ('Every product answers every mandatory axis.'),
    ('Features and content'),
    ('Financials'),
    ('GRNI value'),
    ('Go-live, export and portability, and deletion that deletes.'),
    ('Guidance and adoption'),
    ('Manufacturing'),
    ('Marshalling areas'),
    ('Match exceptions'),
    ('Migration and cutover'),
    ('No aged stock to profile. Stock is banded by age here once anything has been on hand long enough to band.'),
    ('No aged stock. Nothing has been on hand long enough to fall into an age band.'),
    ('No batches yet. A batch is created when stock of a batch-controlled product is received, so a product has to be marked batch controlled first.'),
    ('No business partner exists yet, so nothing can be classed for settlement.'),
    ('No business partner exists yet, so there is nothing to score.'),
    ('No count tasks raised. Raise a counting programme under Actions and its tasks appear here.'),
    ('No deliveries in the window. On-time-in-full is measured from confirmed deliveries, so this fills once goods start leaving.'),
    ('No exceptions to profile. The plan is currently consistent with demand and supply.'),
    ('No fiscal calendar yet. Installing Financials creates one, and nothing can be posted to a period until it exists.'),
    ('No fixed assets recorded. An asset is capitalised from a posted purchase invoice.'),
    ('No intercompany balances. This appears once two companies in the organisation trade with each other.'),
    ('No ledger configured. Installing Financials is what creates one.'),
    ('No likely duplicates. Nothing in the common data scores closely enough to another record to be worth merging.'),
    ('No pack is defined. Define one under Actions above, then add reports to it.'),
    ('No product exists yet, so nothing can be classed for posting.'),
    ('No product has diverged from the classification behind its code.'),
    ('No quality events open. Raise one under Actions above when something needs investigating.'),
    ('No quality events to profile. Deviations, complaints and non-conformances are counted here by kind.'),
    ('No shipments planned. A shipment is planned against confirmed sales deliveries, so there has to be a sales order first.'),
    ('No supplier is qualified yet. Qualification is recorded against a business partner holding the supplier role.'),
    ('No taxable transactions in this period. Change the period, or post a document that carries tax.'),
    ('No warehouse tasks outstanding. Picks, putaways and replenishments are raised by the work, not from this screen.'),
    ('No works orders raised, so the register is empty. Raising one is done under Work.'),
    ('No works orders raised. Raise one under Actions above.'),
    ('No works orders to profile. Raise one under Work and it is counted here by status.'),
    ('Nobody needs chasing. Every customer is inside their terms, or has nothing outstanding at all.'),
    ('Nothing expires in the next thirty days. Only batch-controlled stock with an expiry date appears here.'),
    ('Nothing has been delivered in the last seven days.'),
    ('Nothing is old enough to provide against. Stock appears here once it has passed the slow-moving threshold this organisation set.'),
    ('Nothing is on hand yet. Receipting a purchase order is what first puts stock into an organisation.'),
    ('Nothing outstanding to profile. Customer invoices land here as they are posted, banded by how overdue they are.'),
    ('Nothing outstanding. Every customer invoice posted so far has been settled.'),
    ('Nothing posted yet. A trial balance is built from documents that have been posted.'),
    ('Nothing received awaiting an invoice. A goods receipt accrues here until the supplier invoice matches it.'),
    ('Nothing to value yet. Stock is valued from the moment it is received.'),
    ('On credit hold'),
    ('Onboarding interview'),
    ('Open Common data'),
    ('Open Configuration'),
    ('Open Purchasing'),
    ('Open Sales'),
    ('Open order lines'),
    ('Opening balances loaded as at a date, whether each load reconciles, the parallel-run figures, and which domains are cut over on that evidence.'),
    ('Organisation lifecycle'),
    ('Output and printing'),
    ('Outstanding balance by age band.'),
    ('Personal data and erasure'),
    ('Plan and usage'),
    ('Posting classes and the matrix that decides the account and analysis — with a gap report and no suspense fallback.'),
    ('Product'),
    ('Product class'),
    ('Product classes'),
    ('Product-suppliers'),
    ('Products and their posting class'),
    ('Products that are missing an answer a mandatory axis requires.'),
    ('Products without a class are listed first — they cannot be posted.'),
    ('Purchase requisitions, purchase orders and receipts.'),
    ('Purchasing'),
    ('Quality control'),
    ('Received not invoiced'),
    ('Recurring tasks'),
    ('Registered scanners and terminals, what each may do, the rules a scan is judged by, and the actions waiting to be applied.'),
    ('Report versions and runs'),
    ('Reports and inquiries'),
    ('Runs the budget deferred, produced as archived extracts; subscriptions by person or role; assembled packs with manifests; the analytics contract.'),
    ('Sales quotes, sales orders and deliveries.'),
    ('Suppliers by product'),
    ('Switch product features on and off, apply starter content packs, and see what this organisation cannot yet do.'),
    ('Template versions, printers, every request with its render and delivery, and the addresses mail may not go to.'),
    ('The accessibility statement: each WCAG 2.2 criterion, whether the product meets it, how, and the known exceptions.'),
    ('The plan this organisation is on, what it entitles, how much of each limit is used, and the meters behind the figures.'),
    ('The products and business partners every document depends on.'),
    ('The warehouse application: one task at a time, driven by scanning, with a queue that holds your work until the network returns.'),
    ('Users and authorisations'),
    ('Value at risk'),
    ('What the platform sells, at what rate per currency and term, and at what cost, so margin is visible while quoting.'),
    ('What the product told you, your channel preferences and quiet hours, and the routes from events to audiences.'),
    ('What was promised about staying up, whether a drill has proved it, and what happened when it did not.'),
    ('Where adoption is stalling, counted and never named; training scenarios practised in a demo organisation; the product''s help for every screen.'),
    ('Which columns hold a person''s data and what erasure does to each; requests to erase a principal or contact, executed by a second person, with the certificate.'),
    ('held by match exceptions'),
    ('nothing awaiting an invoice'),
    ('nothing overdue'),
    ('nothing waiting to be released'),
    ('open on the balance sheet')
  ) as v(text)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- The seeding is only worth anything if the words still obey the glossary:
-- an internal model term must not have reached the surface, and every product
-- term must still resolve through the locale fallback chain.
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
