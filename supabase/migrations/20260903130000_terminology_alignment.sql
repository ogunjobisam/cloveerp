-- =============================================================================
-- Terminology Alignment — the base locale says what a UK operator already says
--
-- §1 of the alignment document names the actual problem: three vocabularies are
-- in play and the product mixes two of them. Model vocabulary (party, principal,
-- entity, tenant) is correct in a schema and wrong on a screen. The fix is not
-- to pick one — it is to stop using model vocabulary where product vocabulary
-- belongs.
--
-- §6 says this is a data change rather than a rewrite, and measuring first
-- confirms it: erp_ref.resource holds 691 English strings, AutoPanel resolves
-- every title, description, empty state and column heading through ui() at
-- render time, and erp.assert_resource_coverage('en') already passes. Ten
-- hard-coded strings in the app are the only exception and are changed
-- alongside this.
--
-- THREE THINGS THIS DOES THAT THE DOCUMENT DOES NOT ASK FOR, each because
-- measuring turned up something:
--
--   1. public.erp_resources(p_locale) did not walk the locale fallback chain.
--      erp.text() does, key by key, which is why notifications resolve
--      correctly — but the bulk load the interface uses returned only rows
--      matching the locale exactly. Asking for en-US returned four rows out of
--      691, so an American user would have seen the entire interface fall back
--      to hard-coded English. §6.4 says the en-US variant "is also the proof
--      that the fallback chain works". As built it would have proved the
--      opposite, so the resolver is fixed here first.
--
--   2. The register is erp_ref.vocabulary rather than a list in a comment, so
--      erp.assert_vocabulary_aligned() can police §4's never-on-a-screen rule
--      and erp.terminology_alignment_report() can show what still carries model
--      vocabulary. A glossary that is only prose drifts the first time somebody
--      adds a screen.
--
--   3. §5's six genuinely ambiguous terms are seeded as glossary keys rather
--      than left as advice, because "the base glossary should state its
--      meaning" is only true if there is a base glossary.
-- =============================================================================

-- ── The register ─────────────────────────────────────────────────────────────

create table if not exists erp_ref.vocabulary (
  code           text primary key,
  surface        text not null check (surface in ('product', 'internal', 'ambiguous')),
  -- What the base locale says. Null for an internal term: it has no product
  -- word because it should never reach a screen at all.
  product_term   text,
  -- What the schema says, where the two differ. Null where the model and the
  -- product agree, which §3's keep-as-they-are list is entirely made of.
  model_term     text,
  -- The en-US flip, where UK and US usage genuinely differ.
  us_term        text,
  -- Words a tenant might already use, seeded so they can override three keys
  -- and stop thinking about it.
  aliases        text[] not null default '{}',
  definition     text,
  spec_reference text not null,
  note           text,
  seq            integer not null default 100
);

comment on table erp_ref.vocabulary is
  'What this product calls things, and what it deliberately does not. Three '
  'surfaces: product terms the base locale uses, internal terms that must '
  'never reach a screen, and terms ambiguous enough to need defining once.';

select erp_meta.register_table('erp_ref', 'vocabulary', 'product_content',
  'The product vocabulary, and the model vocabulary it is not.');

-- §2 — where the current term is data-modelling language and a standard UK
-- term exists. model_term is what stays in the schema.
insert into erp_ref.vocabulary
  (code, surface, product_term, model_term, us_term, aliases, spec_reference, note, seq) values
  ('company', 'product', 'Company', 'entity', null,
   array['Entity','Legal entity'], 'Terminology §2',
   'Entity is consolidation language and it collides with the generic word for '
   'a data object, which is exactly where the ambiguity bites. UK finance says '
   'company; the group above it is the group.', 10),
  ('user', 'product', 'User', 'principal', null,
   array['Principal','Account'], 'Terminology §2',
   'Service account for the non-human case. Principal is identity-model '
   'language and no operator will recognise it.', 11),
  ('organisation', 'product', 'Organisation', 'tenant', 'Organization',
   array['Tenant','Client'], 'Terminology §2',
   'tenant stays in the schema and the isolation model, where it is precise.', 12),
  ('business_partner', 'product', 'Business partner', 'party', null,
   array['Party','Trading partner','Account'], 'Terminology §2',
   'The established term in mid-market ERP. Supplier and customer are used '
   'wherever only one role is meant.', 20),
  ('product', 'product', 'Product', 'item', null,
   array['Item','Article','SKU'], 'Terminology §2',
   'UK ERP overwhelmingly says product; item survives mainly in Dynamics '
   'lineage. Stock item for the stockable subset.', 21),
  ('handling_unit', 'product', 'Handling unit', 'container', null,
   array['Container','Pallet','Tote'], 'Terminology §2',
   'The industry-standard term for the recursive pallet-carton-tote concept, '
   'and unambiguous where "container" suggests shipping containers.', 22),
  ('accounting_code', 'product', 'Accounting code', 'posting class', null,
   array['Posting class','Item category','Product category'], 'Terminology §2',
   'What a UK X3 or Sage user already calls exactly this concept: the '
   'classification on a product that decides which accounts it posts to. One '
   'of the two the document would prioritise.', 30),
  ('nominal_account', 'product', 'Nominal account', 'account', 'General ledger account',
   array['Account','GL account','General ledger account'], 'Terminology §2',
   'UK practice, particularly in the Sage lineage. The chart of accounts is '
   'also the nominal ledger. General ledger remains understood, so it is kept '
   'as an alias rather than removed.', 31),
  ('accounting_period', 'product', 'Accounting period', 'fiscal period', null,
   array['Fiscal period','Period'], 'Terminology §2',
   'Fiscal is US usage. Financial calendar and financial year follow.', 32),
  ('analysis_code', 'product', 'Analysis code', 'dimension', null,
   array['Dimension','Analytical dimension','Cost centre'], 'Terminology §2',
   'Standard UK terminology for cost centre, department and project analysis. '
   'Analytical dimension is the formal alias.', 33),
  ('sales_ledger', 'product', 'Sales ledger', 'accounts receivable', 'Accounts receivable',
   array['Accounts receivable','AR','Receivables'], 'Terminology §2',
   'UK base term, with AR retained as an alias for groups that use it.', 34),
  ('purchase_ledger', 'product', 'Purchase ledger', 'accounts payable', 'Accounts payable',
   array['Accounts payable','AP','Payables'], 'Terminology §2',
   'UK base term, with AP retained as an alias.', 35),
  ('marshalling_area', 'product', 'Marshalling area', 'release area', null,
   array['Release area','Staging area'], 'Terminology §2',
   'The document''s author coined "release area" and it is standard nowhere. '
   'Marshalling is the established UK warehouse term for goods gathered ahead '
   'of despatch.', 40),
  ('goods_in', 'product', 'Goods-in', 'receiving', 'Receiving',
   array['Receiving','Inbound','Goods inwards'], 'Terminology §2',
   'The everyday UK warehouse term.', 41),
  ('goods_out', 'product', 'Goods-out', 'despatch staging', 'Shipping',
   array['Despatch staging','Outbound','Shipping'], 'Terminology §2',
   'The everyday UK warehouse term.', 42),
  ('cycle_count', 'product', 'Cycle count', null, null,
   array['Perpetual count','Rolling count'], 'Terminology §2',
   'Kept for the perpetual programme. Stocktake is added for the wall-to-wall '
   'annual, because UK operations distinguish the two clearly and the '
   'specification used one word for both.', 43),
  ('stocktake', 'product', 'Stocktake', null, 'Physical inventory',
   array['Wall-to-wall count','Annual count','Physical inventory'], 'Terminology §2',
   'The wall-to-wall annual, as distinct from the cycle count programme.', 44)
on conflict (code) do update set
  surface = excluded.surface, product_term = excluded.product_term,
  model_term = excluded.model_term, us_term = excluded.us_term,
  aliases = excluded.aliases, definition = excluded.definition,
  spec_reference = excluded.spec_reference, note = excluded.note,
  seq = excluded.seq;

-- §3 — already correct UK usage. In the register because "we deliberately did
-- not change this" is a decision, and a decision nobody wrote down gets made
-- again next year in the other direction.
insert into erp_ref.vocabulary
  (code, surface, product_term, model_term, us_term, aliases, spec_reference, note, seq) values
  ('stock', 'product', 'Stock', null, 'Inventory',
   array['Inventory'], 'Terminology §3',
   'Stock in operational language. Inventory is acceptable as a module name '
   'where it means the whole domain, but the ledger is a stock ledger and the '
   'count is a stock count.', 60),
  ('works_order', 'product', 'Works order', null, 'Work order',
   array['Work order','Production order','Manufacturing order'], 'Terminology §3',
   'UK manufacturing standard.', 61),
  ('despatch', 'product', 'Despatch', null, 'Dispatch',
   array['Dispatch','Shipment'], 'Terminology §3',
   'Both spellings are current in UK usage; despatch is the conventional '
   'logistics spelling and consistency matters more than the choice.', 62),
  ('batch', 'product', 'Batch', null, 'Lot',
   array['Lot'], 'Terminology §3',
   'UK and EU regulated practice says batch; lot is US. Lot stays a recognised '
   'alias.', 63),
  ('supplier', 'product', 'Supplier', null, 'Vendor',
   array['Vendor'], 'Terminology §3', 'Not vendor.', 64),
  ('grni', 'product', 'GRNI', null, null,
   array['Goods received not invoiced','GR/IR'], 'Terminology §3',
   'Established UK term. The US GR/IR is not.', 65),
  ('requisition', 'product', 'Requisition', null, null,
   array['Purchase requisition','Purchase request'], 'Terminology §3', null, 66),
  ('global_allocation', 'product', 'Global allocation', null, null,
   array[]::text[], 'Terminology §3',
   'From the incumbent system''s own vocabulary, which means every person '
   'configuring this already knows exactly what it means. Keeping it is a '
   'deliberate advantage, not an oversight.', 67),
  ('detailed_allocation', 'product', 'Detailed allocation', null, null,
   array[]::text[], 'Terminology §3', 'As above.', 68),
  ('qualified_person', 'product', 'Qualified Person', null, null,
   array[]::text[], 'Terminology §3',
   'A UK regulatory title, not to be softened.', 69),
  ('responsible_person', 'product', 'Responsible Person', null, null,
   array[]::text[], 'Terminology §3', 'As above.', 70)
on conflict (code) do update set
  surface = excluded.surface, product_term = excluded.product_term,
  model_term = excluded.model_term, us_term = excluded.us_term,
  aliases = excluded.aliases, definition = excluded.definition,
  spec_reference = excluded.spec_reference, note = excluded.note,
  seq = excluded.seq;

-- §4 — correct in the model, never on a screen. product_term is what to say
-- instead where there is something to say.
insert into erp_ref.vocabulary
  (code, surface, product_term, model_term, spec_reference, note, seq) values
  ('aggregate',             'internal', null, 'aggregate',             'Terminology §4', null, 80),
  ('event_envelope',        'internal', null, 'event envelope',        'Terminology §4', null, 81),
  ('outbox',                'internal', null, 'outbox',                'Terminology §4', null, 82),
  ('projection',            'internal', null, 'projection',            'Terminology §4', null, 83),
  ('upcaster',              'internal', null, 'upcaster',              'Terminology §4', null, 84),
  ('document_spine',        'internal', null, 'document spine',        'Terminology §4', null, 85),
  ('write_gateway',         'internal', null, 'write gateway',         'Terminology §4', null, 86),
  ('change_set',            'internal', 'Change',   'change set',      'Terminology §4',
   'Say change, or release.', 87),
  ('capability',            'internal', 'Feature',  'capability',      'Terminology §4',
   'The switch is a feature to a user and a capability to the engine.', 88),
  ('posting_rule',          'internal', 'Accounting rule', 'posting rule', 'Terminology §4', null, 89),
  ('determination_matrix',  'internal', 'Account determination', 'determination matrix',
   'Terminology §4', null, 90),
  ('party_role_terms',      'internal', 'Trading terms', 'party role terms', 'Terminology §4', null, 91)
on conflict (code) do update set
  surface = excluded.surface, product_term = excluded.product_term,
  model_term = excluded.model_term, us_term = excluded.us_term,
  aliases = excluded.aliases, definition = excluded.definition,
  spec_reference = excluded.spec_reference, note = excluded.note,
  seq = excluded.seq;

-- §5 — ambiguous enough that the product must state its meaning rather than
-- assume it. These become glossary keys below.
insert into erp_ref.vocabulary
  (code, surface, product_term, definition, spec_reference, seq) values
  ('site', 'ambiguous', 'Site',
   'A physical or logical operating location under a company. Some systems '
   'mean warehouse by this and some mean legal establishment; here it is '
   'neither on its own.', 'Terminology §5', 110),
  ('location', 'ambiguous', 'Location',
   'A storage position within a site: zone, aisle, rack, bin. Not a geographic '
   'place — where that is meant, the word is address or site.', 'Terminology §5', 111),
  ('allocation', 'ambiguous', 'Allocation',
   'Reserving stock against demand. Not the accounting sense of apportioning '
   'cost, which this product calls cost apportionment to avoid the collision.',
   'Terminology §5', 112),
  ('order_release', 'ambiguous', 'Order release',
   'Releasing an order to the warehouse. One of three unrelated senses of '
   'release, and always qualified for that reason.', 'Terminology §5', 113),
  ('batch_release', 'ambiguous', 'Batch release',
   'Releasing a batch from quarantine under named authority. The second sense '
   'of release.', 'Terminology §5', 114),
  ('promotion', 'ambiguous', 'Promotion',
   'Releasing a change to live. The third sense of release, and the reason the '
   'other two are always qualified.', 'Terminology §5', 115),
  ('confirm_delivery', 'ambiguous', 'Confirm delivery',
   'The operational sense of validating a delivery document. Validation is '
   'reserved for the regulatory sense — computerised system validation — so '
   'the two cannot be confused in an audit.', 'Terminology §5', 116),
  ('validation', 'ambiguous', 'Validation',
   'Computerised system validation, the regulatory sense. The operational act '
   'on a delivery document is confirm delivery.', 'Terminology §5', 117),
  ('class', 'ambiguous', 'Class',
   'Never used alone. Accounting code class, product class, count class and '
   'hazard class are four different things and the qualifier is always kept.',
   'Terminology §5', 118)
on conflict (code) do update set
  surface = excluded.surface, product_term = excluded.product_term,
  model_term = excluded.model_term, us_term = excluded.us_term,
  aliases = excluded.aliases, definition = excluded.definition,
  spec_reference = excluded.spec_reference, note = excluded.note,
  seq = excluded.seq;

-- ── The resolver, fixed before anything relies on it ─────────────────────────
--
-- erp.text() walks erp_ref.locale.parent_locale one key at a time, which is why
-- notifications resolve correctly in a regional variant. public.erp_resources()
-- — the door the interface loads its entire dictionary through — did not: it
-- matched the locale exactly. So erp_resources('en-US') returned the four rows
-- that happen to exist at that locale, and the other 687 strings fell back to
-- the English hard-coded in the components. Nobody noticed because nothing had
-- ever asked for a variant.
--
-- §6.4 wants an en-US variant that is "also the proof that the fallback chain
-- works". It could not have been, so this is the chain.

create or replace function public.erp_resources(p_locale text default 'en')
returns jsonb
language sql
stable
set search_path = ''
as $$
  with recursive chain(code, parent_locale, depth) as (
      select l.code, l.parent_locale, 0
        from erp_ref.locale l
       where l.code = coalesce(p_locale, 'en')
      union all
      select l.code, l.parent_locale, chain.depth + 1
        from chain
        join erp_ref.locale l on l.code = chain.parent_locale
       where chain.depth < 4
  ),
  -- Every locale in the chain plus 'en' as the floor, because a locale row that
  -- names no parent must still resolve rather than return almost nothing.
  steps as (
      select code, depth from chain
      union all
      select 'en', 99
  ),
  resolved as (
      select r.key,
             coalesce(
               (select o.value from erp.resource_override o
                 where o.tenant_id = erp.current_tenant_id()
                   and o.key = r.key and o.locale = r.locale
                   and o.status = 'active'::erp.record_status limit 1),
               r.value) as value,
             s.depth,
             row_number() over (partition by r.key order by s.depth) as rn
        from steps s
        join erp_ref.resource r on r.locale = s.code
  )
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from resolved where rn = 1
$$;

comment on function public.erp_resources is
  'Every resource key resolved for a locale: tenant override first, then the '
  'product string, walking erp_ref.locale.parent_locale and ending at en. '
  'Before this it matched the locale exactly, so asking for en-US returned the '
  'four rows that existed there and left 687 strings to the fallback compiled '
  'into the components.';

-- ── The base locale, aligned ─────────────────────────────────────────────────
--
-- Thirty-seven English strings carry model vocabulary. Each is stated here
-- rather than rewritten by a regular expression over the table: "dimension" is
-- not always replaceable by "analysis code" without recasting the sentence
-- around it, and a blind substitution would have produced "a reporting analysis
-- code value" where the sentence wanted something else.
--
-- Where the key does not exist yet, this inserts it, because several of these
-- are words the product uses on screen and has never had a row for.

insert into erp_ref.resource (key, locale, value, description) values
  ('audit.blurb', 'en',
   'Every recorded action in this organisation: who did what, to which object, and when.',
   'Terminology §2: tenant is model vocabulary.'),

  ('event.item.classified',      'en', 'Product classified', null),
  ('event.item.code_assigned',   'en', 'Product code assigned', null),
  ('event.item.code_diverged',   'en', 'Product code diverged from its template', null),
  ('event.posting.class_changed','en', 'Accounting code changed', null),
  ('event.posting.rule_resolved','en', 'Accounting rule resolved',
   'Terminology §4: posting rule is internal vocabulary. This was the only '
   'string in the product that broke that rule.'),
  ('event.tenant.key_created',   'en', 'Organisation key created', null),
  ('event.tenant.key_destroyed', 'en', 'Organisation key destroyed', null),
  ('event.tenant.key_rotated',   'en', 'Organisation key rotated', null),

  ('module.tenant_lifecycle',    'en', 'Organisation lifecycle', null),
  ('movement.container_move',    'en', 'Handling unit move', null),
  ('nav.tenant',                 'en', 'Organisation lifecycle', null),
  ('nav.tenant_settings',        'en', 'Organisation settings', null),

  ('ui.adopt_the_stocking_policy_the_engine_cal_icle0a', 'en',
   'Adopt the stocking policy the engine calculates for one product and site.', null),
  ('ui.average_party_record_score_gtquen', 'en',
   'average business partner record score', null),
  ('ui.combine_one_batch_into_another_of_the_sa_lf7hb8', 'en',
   'Combine one batch into another of the same product and condition.', null),
  ('ui.completeness_and_validity_of_party_maste_v5rmnd', 'en',
   'Completeness and validity of business partner master records.', null),
  ('ui.cost_basis_by_item_and_site_in_minor_uni_dxj7uz', 'en',
   'Cost basis by product and site, in minor units.', null),
  ('ui.cover_against_policy_by_item_and_site_9mlsyn', 'en',
   'Cover against policy, by product and site.', null),
  ('ui.each_department_is_also_a_reporting_dime_d9fuqy', 'en',
   'Each department is also a reporting analysis code, so a department means '
   'the same thing in a stock report and in a profit and loss.', null),
  ('ui.item_8pkkxy', 'en', 'Product', null),
  ('ui.item_and_site_positions_fshzg6', 'en', 'product and site positions', null),
  ('ui.likely_duplicate_parties_for_merge_with_1qewjc', 'en',
   'Likely duplicate business partners, for merge with a survivor and a reason.', null),
  ('ui.no_fiscal_calendar_yet_1orkrva', 'en', 'No financial calendar yet.', null),
  ('ui.no_party_master_data_to_assess_yet_13fdrkf', 'en',
   'No business partner master data to assess yet.', null),
  ('ui.no_stock_positions_yet_nothing_has_moved_1fukkx8', 'en',
   'No stock positions yet — nothing has moved into this organisation.', null),
  ('ui.party_data_quality_gejo2c', 'en', 'Business partner data quality', null),
  ('ui.party_e2ekhj', 'en', 'Business partner', null),
  ('ui.principals_roles_and_the_grants_between_1kg59m2', 'en',
   'Users, roles, and the grants between them.', null),
  ('ui.tenant_lifecycle_gxp8sh', 'en', 'Organisation lifecycle', null),
  ('ui.the_books_this_tenant_keeps_jzwzm6', 'en',
   'The books this organisation keeps.', null),
  ('ui.the_fiscal_calendar_and_where_it_is_open_pxr907', 'en',
   'The financial calendar and where it is open.', null),
  ('ui.the_items_and_parties_every_document_dep_1o86pt1', 'en',
   'The products and business partners every document depends on.', null),
  ('ui.the_projected_balance_for_one_item_and_s_wru6sj', 'en',
   'The projected balance for one product and site across the horizon.', null),
  ('ui.the_wording_of_every_label_per_tenant_bvbpd', 'en',
   'The wording of every label, per organisation.', null),
  ('ui.what_can_still_be_committed_for_one_item_arlzxw', 'en',
   'What can still be committed for one product at one site, on a date.', null),
  ('ui.what_each_entity_owes_another_before_eli_4oo7pk', 'en',
   'What each company owes another, before elimination.', null),
  ('ui.what_the_engine_would_set_for_one_item_a_5r7tyd', 'en',
   'What the engine would set for one product and site, before adopting it.', null)
on conflict (key, locale) do update set
  value = excluded.value,
  description = coalesce(excluded.description, erp_ref.resource.description);

-- ── en-US, which is also the test ────────────────────────────────────────────
--
-- §6.4 asks for a variant that flips the handful that genuinely differ, and
-- says it is "also the proof that the fallback chain works". That is the right
-- instinct and it is why these rows are few on purpose: an en-US caller should
-- get 691 strings, of which only these differ. If the chain breaks, this count
-- collapses and erp.assert_vocabulary_aligned() says so.

insert into erp_ref.resource (key, locale, value, description) values
  ('module.tenant_lifecycle', 'en-US', 'Organization lifecycle', null),
  ('nav.tenant',              'en-US', 'Organization lifecycle', null),
  ('nav.tenant_settings',     'en-US', 'Organization settings', null),
  ('audit.blurb',             'en-US',
   'Every recorded action in this organization: who did what, to which object, and when.', null),
  ('event.tenant.key_created',   'en-US', 'Organization key created', null),
  ('event.tenant.key_destroyed', 'en-US', 'Organization key destroyed', null),
  ('event.tenant.key_rotated',   'en-US', 'Organization key rotated', null),
  ('ui.tenant_lifecycle_gxp8sh', 'en-US', 'Organization lifecycle', null),
  ('ui.the_books_this_tenant_keeps_jzwzm6', 'en-US',
   'The books this organization keeps.', null),
  ('ui.no_stock_positions_yet_nothing_has_moved_1fukkx8', 'en-US',
   'No inventory positions yet — nothing has moved into this organization.', null),
  ('ui.the_wording_of_every_label_per_tenant_bvbpd', 'en-US',
   'The wording of every label, per organization.', null),
  ('glossary.stock',        'en-US', 'Inventory', null),
  ('glossary.works_order',  'en-US', 'Work order', null),
  ('glossary.despatch',     'en-US', 'Dispatch', null),
  ('glossary.batch',        'en-US', 'Lot', null),
  ('glossary.supplier',     'en-US', 'Vendor', null),
  ('glossary.sales_ledger', 'en-US', 'Accounts receivable', null),
  ('glossary.purchase_ledger', 'en-US', 'Accounts payable', null),
  ('glossary.nominal_account', 'en-US', 'General ledger account', null),
  ('glossary.stocktake',    'en-US', 'Physical inventory', null),
  ('glossary.goods_in',     'en-US', 'Receiving', null),
  ('glossary.goods_out',    'en-US', 'Shipping', null),
  ('glossary.organisation', 'en-US', 'Organization', null)
on conflict (key, locale) do update set value = excluded.value;

-- ── The glossary, generated from the register ────────────────────────────────
--
-- §9.6 of Starter Content Packs asks for "the keys most commonly overridden,
-- seeded in the base locale so an organisation renames rather than creates".
-- Every product and ambiguous term becomes one, generated rather than typed so
-- the register and the glossary cannot disagree.

insert into erp_ref.resource (key, locale, value, description)
select 'glossary.' || v.code, 'en', v.product_term,
       coalesce(v.definition, v.note, v.spec_reference)
  from erp_ref.vocabulary v
 where v.surface in ('product', 'ambiguous') and v.product_term is not null
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

-- ── Reading it ───────────────────────────────────────────────────────────────

create or replace function public.erp_glossary()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', v.code,
           'surface', v.surface,
           'term', v.product_term,
           'model_term', v.model_term,
           'us_term', v.us_term,
           'aliases', to_jsonb(v.aliases),
           'definition', v.definition,
           'note', v.note,
           'reference', v.spec_reference,
           -- The key a tenant overrides to rename it, which is the whole point
           -- of seeding a glossary rather than writing one down.
           'key', case when v.product_term is null then null
                       else 'glossary.' || v.code end)
         order by v.surface, v.seq, v.code), '[]'::jsonb)
    from erp_ref.vocabulary v
$$;

comment on function public.erp_glossary is
  'What this product calls things, what the schema calls them, what a tenant '
  'might call them, and the key to change it. Product content, so no tenant '
  'context is needed to read it.';

do $$
begin
  execute 'revoke all on function public.erp_glossary() from public, anon';
  execute 'grant execute on function public.erp_glossary() to authenticated';
end;
$$;

-- ── The assertion ────────────────────────────────────────────────────────────
--
-- §4's rule is the one that can be checked absolutely: these words are correct
-- in the model and carry no meaning to an operator, so none of them may appear
-- in a string the product shows. Exactly one did — "Posting rule resolved" —
-- and it is fixed above.

create or replace function erp.assert_vocabulary_aligned()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_detail text := ''; v_count integer := 0; r record; n integer;
begin
  -- 1. No internal term on a screen.
  for r in
    select v.code as term_code, v.model_term, res.key, res.locale,
           left(res.value, 70) as value
      from erp_ref.vocabulary v
      join erp_ref.resource res
        on res.value ~* ('\m' || v.model_term || '\M')
     where v.surface = 'internal'
       -- The glossary is where these words are allowed to appear, because
       -- stating what a word means is the opposite of using it as if everybody
       -- knew.
       and res.key not like 'glossary.%'
     order by v.code, res.key
  loop
    v_detail := v_detail || format(
      E'  %s (%s) says %L, which is model vocabulary — %s\n',
      r.key, r.locale, r.value, r.term_code);
    v_count := v_count + 1;
  end loop;

  -- 2. Every product and ambiguous term has its glossary key, so a tenant can
  --    rename it. A term nobody can override is a term the product imposes.
  for r in
    select v.code from erp_ref.vocabulary v
     where v.surface in ('product', 'ambiguous') and v.product_term is not null
       and not exists (select 1 from erp_ref.resource res
                        where res.key = 'glossary.' || v.code and res.locale = 'en')
     order by v.code
  loop
    v_detail := v_detail || format(
      E'  %s has no glossary.%s key in the base locale — nothing can rename it\n',
      r.code, r.code);
    v_count := v_count + 1;
  end loop;

  -- 3. The fallback chain. This is the check §6.4 was really asking for: an
  --    en-US caller must get every string, not only the ones authored at en-US.
  --    Before public.erp_resources() walked erp_ref.locale.parent_locale it
  --    returned four rows out of 691, and nothing would have said so.
  select count(*) into n
    from jsonb_object_keys(public.erp_resources('en-US')) k;
  if n < (select count(*) from erp_ref.resource where locale = 'en') then
    v_detail := v_detail || format(
      E'  erp_resources(''en-US'') resolves %s keys but the base locale has %s — the fallback chain is not being walked\n',
      n, (select count(*) from erp_ref.resource where locale = 'en'));
    v_count := v_count + 1;
  end if;

  -- 4. And it has to actually differ, or the variant proves nothing.
  if (public.erp_resources('en-US') ->> 'glossary.batch') is not distinct from
     (public.erp_resources('en') ->> 'glossary.batch') then
    v_detail := v_detail ||
      E'  en-US resolves glossary.batch to the same value as en — the variant is not overriding\n';
    v_count := v_count + 1;
  end if;

  -- 5. A us_term claimed in the register with no en-US row behind it is a
  --    promise the deployment does not keep.
  for r in
    select v.code, v.us_term from erp_ref.vocabulary v
     where v.us_term is not null
       and not exists (select 1 from erp_ref.resource res
                        where res.key = 'glossary.' || v.code and res.locale = 'en-US')
     order by v.code
  loop
    v_detail := v_detail || format(
      E'  %s claims the US term %L but no en-US glossary row carries it\n',
      r.code, r.us_term);
    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    raise exception E'ERPWARE_VOCABULARY_MISALIGNED: % finding(s)\n%', v_count, v_detail
      using errcode = '23514';
  end if;

  return format('vocabulary: %s product terms, %s internal terms kept off the '
                'surface, %s ambiguous terms defined, %s en-US flips',
    (select count(*) from erp_ref.vocabulary where surface = 'product'),
    (select count(*) from erp_ref.vocabulary where surface = 'internal'),
    (select count(*) from erp_ref.vocabulary where surface = 'ambiguous'),
    (select count(*) from erp_ref.resource where locale = 'en-US'));
end;
$$;

-- A REPORT for §2, not an assertion. The model terms are ordinary English
-- words — item, party, entity, account, dimension — and a string may use one
-- legitimately in a sentence that is not about the concept at all. Failing the
-- build on that would make the next person delete the check rather than the
-- string. So this names what still reads as model vocabulary and leaves the
-- judgement where it belongs.
create or replace function erp.terminology_alignment_report(p_locale text default 'en')
returns table (key text, finding text, reference text)
language sql
stable
set search_path = ''
as $$
  select res.key,
         format('says %L where the product term is %L', v.model_term, v.product_term),
         left(res.value, 90)
    from erp_ref.vocabulary v
    join erp_ref.resource res
      on res.locale = coalesce(p_locale, 'en')
     and res.value ~* ('\m' || v.model_term || '\M')
   where v.surface = 'product' and v.model_term is not null
     and res.key not like 'glossary.%'
   order by res.key, v.code
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values
  ('vocabulary_aligned', 'Vocabulary', 'assertion', 'platform',
   'assert_vocabulary_aligned', '', 'terminology_alignment_report', '',
   'No model vocabulary on a screen, every product term renameable by its own '
   'glossary key, and the locale fallback chain actually resolving.', true, 23),
  ('terminology_alignment', 'Terminology drift', 'report', 'platform',
   'terminology_alignment_report', '', null, '',
   'Product strings still carrying model vocabulary. A report rather than an '
   'assertion: item, party and account are ordinary words and a sentence may '
   'use one without meaning the concept.', false, 24)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind,
  scope = excluded.scope, detail_function = excluded.detail_function;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_vocabulary_aligned();
select erp.assert_resource_coverage('en');
select erp.assert_capabilities_sound();
select erp.assert_starter_vocabularies_sound();
select erp.assert_configuration_promotable();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp.assert_isolation();

-- ── What the report found on its first run ───────────────────────────────────
--
-- Four findings, and the fourth is the reason this is a report. Three were
-- real; "Account determination failed" is the term §4 PRESCRIBES for what the
-- model calls a determination matrix, so the word "account" in it is correct
-- and the finding is a false positive. An assertion would have failed the
-- build on the product's own recommended wording.

insert into erp_ref.resource (key, locale, value, description) values
  ('event.posting.account_recorded', 'en', 'Nominal account recorded', null),
  ('ui.account_oyp43g', 'en', 'Nominal account', null),
  ('ui.every_account_with_a_movement_by_ledger_16xm7kf', 'en',
   'Every nominal account with a movement, by ledger.', null)
on conflict (key, locale) do update set value = excluded.value;

create or replace function erp.terminology_alignment_report(p_locale text default 'en')
returns table (key text, finding text, reference text)
language sql
stable
set search_path = ''
as $$
  select res.key,
         format('says %L where the product term is %L', v.model_term, v.product_term),
         left(res.value, 90)
    from erp_ref.vocabulary v
    join erp_ref.resource res
      on res.locale = coalesce(p_locale, 'en')
     and res.value ~* ('\m' || v.model_term || '\M')
   where v.surface = 'product' and v.model_term is not null
     and res.key not like 'glossary.%'
     -- "Account determination" is §4's own prescribed replacement for
     -- "determination matrix", so the word account in it is the right word.
     -- Narrow, and named, rather than loosening the pattern.
     and not (v.code = 'nominal_account' and res.value ~* '\maccount determination\M')
   order by res.key, v.code
$$;

select erp.assert_vocabulary_aligned();

-- ── And what the report found about itself ───────────────────────────────────
--
-- Run against the corrected strings, it flagged all three again: the model term
-- "account" is a substring of the product term "Nominal account", so fixing a
-- string could never clear its own finding. A report nobody can satisfy is a
-- report everybody learns to ignore.
--
-- The rule that works generally: remove every occurrence of the product term
-- from the value first, then look for the model term in what is left. "Nominal
-- account recorded" becomes " recorded" and says nothing about accounts;
-- "Every account with a movement" is untouched and still does.

create or replace function erp.terminology_alignment_report(p_locale text default 'en')
returns table (key text, finding text, reference text)
language sql
stable
set search_path = ''
as $$
  select res.key,
         format('says %L where the product term is %L', v.model_term, v.product_term),
         left(res.value, 90)
    from erp_ref.vocabulary v
    join erp_ref.resource res
      on res.locale = coalesce(p_locale, 'en')
   where v.surface = 'product' and v.model_term is not null
     and res.key not like 'glossary.%'
     and regexp_replace(res.value, '\m' || v.product_term || '\M', '', 'gi')
           ~* ('\m' || v.model_term || '\M')
     -- "Account determination" is §4's own prescribed replacement for
     -- "determination matrix", so the word account in it is the right word.
     and not (v.code = 'nominal_account' and res.value ~* '\maccount determination\M')
   order by res.key, v.code
$$;

select erp.assert_vocabulary_aligned();

-- ── The ten strings that were never in the resource layer at all ─────────────
--
-- §6.3 says keep model names untouched, and this does — the schema still says
-- entity, party, principal and item. But ten user-facing strings in the app
-- were hard-coded rather than passed through ui(), so no row could have
-- renamed them: two scope selectors labelled "Entity", a Field labelled
-- "Principal", a "New item" dialog, a "New party" dialog, and five sentences.
-- Those are changed in the components, and their derived keys are seeded here
-- so a tenant can still rename them — which was not true before.
--
-- ui() derives its key from the English source text, so changing the source
-- changes the key. erp_ref.ui_key() computes the identical value in the
-- database, which is what makes seeding them here possible at all.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Terminology §2. Hard-coded in a component before this, so nothing '
       'could rename it.'
  from (values
    ('Company'),
    ('User'),
    ('Companies'),
    ('New product'),
    ('New business partner'),
    ('Creates the organisation, its root company, its administrator role, and a single-use invitation for its first administrator.'),
    ('Products, business partners and sites are named by code, so a file written elsewhere still loads here.'),
    ('The product list is this organisation''s own; an empty one means no products have been created yet.')
  ) t(text)
on conflict (key, locale) do update set
  value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description) values
  (erp_ref.ui_key('Company'),   'en-US', 'Entity', null),
  (erp_ref.ui_key('Companies'), 'en-US', 'Entities', null)
on conflict (key, locale) do update set value = excluded.value;
-- The one place the en-US variant goes the other way: "entity" is the term a
-- US finance team uses for a company within a group, and this document's
-- objection to it is specifically about UK usage.

select erp.assert_vocabulary_aligned();
select erp.assert_resource_coverage('en');

-- ── The hole the drift report could not see ─────────────────────────────────
--
-- After the rewrites above, eight ui() call sites carrying the two terms §7
-- says to prioritise — "Posting class", "Release areas", "Dimensions" — still
-- read the old way on screen, and erp.terminology_alignment_report() showed
-- zero drift. Both facts were correct and together they were the problem: the
-- report reads erp_ref.resource, and those strings were not in it.
--
-- Measuring the whole surface: the app passes 201 distinct strings through
-- ui(), and 128 of them had no row at any locale. So two thirds of the screen
-- chrome could not be renamed by a tenant, and was invisible to every check
-- that reads the resource table. "Renaming is a glossary change with no code
-- impact" was true of 73 strings and not of the rest.
--
-- All 201 are seeded here, with the aligned wording where the source carries
-- model vocabulary. The value equals the source for the other 178, which looks
-- redundant and is not: a row is what makes a string overridable, and the row
-- is what the drift report can see.
--
-- .github/workflows/schema.yml now extracts these literals from the components
-- and fails the build when one has no row, because a migration can seed what
-- exists today and only CI can notice the two hundred and second.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.source), 'en', t.value,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('A mandatory axis must be answered before an item can be created.', 'A mandatory axis must be answered before a product can be created.'),
    ('A partner class separates, for example, export from domestic settlement.', 'A partner class separates, for example, export from domestic settlement.'),
    ('A wave with short lines has raised replenishment and cannot print yet.', 'A wave with short lines has raised replenishment and cannot print yet.'),
    ('Abbreviation', 'Abbreviation'),
    ('Account', 'Account'),
    ('Account determination', 'Account determination'),
    ('Acted', 'Acted'),
    ('Actions', 'Actions'),
    ('Ageing', 'Ageing'),
    ('All', 'All'),
    ('Allocated', 'Allocated'),
    ('Any', 'Any'),
    ('Append-only: the code, the template version that composed it, and when.', 'Append-only: the code, the template version that composed it, and when.'),
    ('Applies to', 'Applies to'),
    ('Approval audit', 'Approval audit'),
    ('Approved', 'Approved'),
    ('Approver', 'Approver'),
    ('Approver away', 'Approver away'),
    ('Approvers', 'Approvers'),
    ('Area', 'Area'),
    ('Ask', 'Ask'),
    ('Ask a question', 'Ask a question'),
    ('Asking…', 'Asking…'),
    ('Axis', 'Axis'),
    ('Band', 'Band'),
    ('Bands', 'Bands'),
    ('By', 'By'),
    ('Cancel', 'Cancel'),
    ('Cause', 'Cause'),
    ('Channel', 'Channel'),
    ('Check without loading', 'Check without loading'),
    ('Checked', 'Checked'),
    ('Choose a CSV file', 'Choose a CSV file'),
    ('Choose a wave', 'Choose a wave'),
    ('Choose a wave above; lines show what allocated and what fell short.', 'Choose a wave above; lines show what allocated and what fell short.'),
    ('Choose…', 'Choose…'),
    ('Chosen by', 'Chosen by'),
    ('Classification and coding', 'Classification and coding'),
    ('Classification axes', 'Classification axes'),
    ('Classified as', 'Classified as'),
    ('Code', 'Code'),
    ('Code assignments', 'Code assignments'),
    ('Code divergences', 'Code divergences'),
    ('Code templates', 'Code templates'),
    ('Coded as', 'Coded as'),
    ('Company', 'Company'),
    ('Completeness gaps', 'Completeness gaps'),
    ('Cost centre', 'Cost centre'),
    ('Cover', 'Cover'),
    ('Cover in force', 'Cover in force'),
    ('Covered by', 'Covered by'),
    ('Dashboard', 'Dashboard'),
    ('Default', 'Default'),
    ('Deliberate overrides', 'Deliberate overrides'),
    ('Department', 'Department'),
    ('Departments', 'Departments'),
    ('Determination matrix', 'Account determination'),
    ('Dimensions', 'Analysis codes'),
    ('Download current', 'Download current'),
    ('Download empty template', 'Download empty template'),
    ('Every item answers every mandatory axis.', 'Every product answers every mandatory axis.'),
    ('Every line on this wave has allocated in full.', 'Every line on this wave has allocated in full.'),
    ('Everything', 'Everything'),
    ('Everywhere', 'Everywhere'),
    ('From', 'From'),
    ('Gated', 'Gated'),
    ('Gated on full allocation', 'Gated on full allocation'),
    ('Home', 'Home'),
    ('In force', 'In force'),
    ('Item', 'Product'),
    ('Item class', 'Product class'),
    ('Item classes', 'Product classes'),
    ('Item supply', 'Product supply'),
    ('Items and their posting class', 'Products and their accounting code'),
    ('Items that are missing an answer a mandatory axis requires.', 'Products that are missing an answer a mandatory axis requires.'),
    ('Items without a class are listed first — they cannot be posted.', 'Products without a class are listed first — they cannot be posted.'),
    ('Kind', 'Kind'),
    ('Lead time', 'Lead time'),
    ('Line', 'Line'),
    ('Lines', 'Lines'),
    ('Load', 'Load'),
    ('Loaded', 'Loaded'),
    ('Loading…', 'Loading…'),
    ('Location', 'Location'),
    ('Lower bands', 'Lower bands'),
    ('Manager', 'Manager'),
    ('Mandatory', 'Mandatory'),
    ('Max', 'Max'),
    ('Members', 'Members'),
    ('Membership', 'Membership'),
    ('Min', 'Min'),
    ('Minimum', 'Minimum'),
    ('Mode', 'Mode'),
    ('Name', 'Name'),
    ('Named approver assignments', 'Named approver assignments'),
    ('Next number', 'Next number'),
    ('No', 'No'),
    ('No approvals have been resolved yet.', 'No approvals have been resolved yet.'),
    ('No axes yet. Until one exists, items carry no structured meaning.', 'No axes yet. Until one exists, products carry no structured meaning.'),
    ('No bands are configured. Until one exists, nothing routes by value.', 'No bands are configured. Until one exists, nothing routes by value.'),
    ('No ceiling', 'No ceiling'),
    ('No codes have been composed yet.', 'No codes have been composed yet.'),
    ('No departments are configured yet.', 'No departments are configured yet.'),
    ('No item has a supplier yet. Purchasing cannot resolve anything until one does.', 'No product has a supplier yet. Purchasing cannot resolve anything until one does.'),
    ('No item has diverged from the classification behind its code.', 'No product has diverged from the classification behind its code.'),
    ('No items yet.', 'No products yet.'),
    ('No named assignments. Everything routes by department band.', 'No named assignments. Everything routes by department band.'),
    ('No overrides have been recorded.', 'No overrides have been recorded.'),
    ('No posting classes yet. Until one exists, nothing can be determined.', 'No accounting codes yet. Until one exists, nothing can be determined.'),
    ('No release areas yet. Allocation runs against the whole site until one exists.', 'No marshalling areas yet. Allocation runs against the whole site until one exists.'),
    ('No rules yet. Every posting would be refused until at least one exists.', 'No rules yet. Every posting would be refused until at least one exists.'),
    ('No templates yet. Item codes would then be typed by hand.', 'No templates yet. Product codes would then be typed by hand.'),
    ('No trading partners yet.', 'No trading partners yet.'),
    ('No values yet.', 'No values yet.'),
    ('No waves have been opened.', 'No waves have been opened.'),
    ('Nobody has been assigned to a department yet.', 'Nobody has been assigned to a department yet.'),
    ('Nobody is covering for anybody.', 'Nobody is covering for anybody.'),
    ('Not set', 'Not set'),
    ('Nothing has been routed yet.', 'Nothing has been routed yet.'),
    ('Object', 'Object'),
    ('Object type', 'Object type'),
    ('Of record', 'Of record'),
    ('On hand', 'On hand'),
    ('Only for', 'Only for'),
    ('Open', 'Open'),
    ('Opened', 'Opened'),
    ('Order', 'Order'),
    ('Order type', 'Order type'),
    ('Organisation and approval routing', 'Organisation and approval routing'),
    ('Outcome', 'Outcome'),
    ('Parallel', 'Parallel'),
    ('Parent', 'Parent'),
    ('Partner class', 'Partner class'),
    ('Party', 'Business partner'),
    ('People', 'People'),
    ('Person', 'Person'),
    ('Pick a wave to see its lines.', 'Pick a wave to see its lines.'),
    ('Posting class', 'Accounting code'),
    ('Posting classes', 'Accounting codes'),
    ('Primary', 'Primary'),
    ('Print the wave', 'Print the wave'),
    ('Printed', 'Printed'),
    ('Printing', 'Printing'),
    ('Printing blocked', 'Printing blocked'),
    ('Printing not gated', 'Printing not gated'),
    ('Printing readiness', 'Printing readiness'),
    ('Quantity', 'Quantity'),
    ('Rank', 'Rank'),
    ('Re-run', 'Re-run'),
    ('Ready to print', 'Ready to print'),
    ('Reason', 'Reason'),
    ('Record', 'Record'),
    ('Release areas', 'Marshalling areas'),
    ('Replaced', 'Replaced'),
    ('Replenishment raised by this wave', 'Replenishment raised by this wave'),
    ('Reports', 'Reports'),
    ('Requester', 'Requester'),
    ('Resolved by', 'Resolved by'),
    ('Routing decisions taken', 'Routing decisions taken'),
    ('Row', 'Row'),
    ('Rule version', 'Rule version'),
    ('Secondary', 'Secondary'),
    ('Segments', 'Segments'),
    ('Sequential', 'Sequential'),
    ('Short', 'Short'),
    ('Site', 'Site'),
    ('Specificity', 'Specificity'),
    ('Split', 'Split'),
    ('Status', 'Status'),
    ('Step', 'Step'),
    ('Subject', 'Subject'),
    ('Supplier', 'Supplier'),
    ('Suppliers by item', 'Suppliers by product'),
    ('Template', 'Template'),
    ('The permitted answers, and the abbreviation each contributes to a code.', 'The permitted answers, and the abbreviation each contributes to a code.'),
    ('To', 'To'),
    ('Trading partners and their posting class', 'Trading partners and their accounting code'),
    ('Transaction type', 'Transaction type'),
    ('Unanswered axis', 'Unanswered axis'),
    ('Until', 'Until'),
    ('Up to', 'Up to'),
    ('Vacancy', 'Vacancy'),
    ('Value', 'Value'),
    ('Value bands', 'Value bands'),
    ('Values', 'Values'),
    ('Version', 'Version'),
    ('Versioned. Amending a template never rewrites codes already assigned.', 'Versioned. Amending a template never rewrites codes already assigned.'),
    ('Wanted', 'Wanted'),
    ('Wave', 'Wave'),
    ('Wave lines', 'Wave lines'),
    ('Waves', 'Waves'),
    ('What posts differently', 'What posts differently'),
    ('When', 'When'),
    ('Why', 'Why'),
    ('Work', 'Work'),
    ('Working…', 'Working…'),
    ('Yes', 'Yes'),
    ('accepted', 'accepted'),
    ('rejected', 'rejected'),
    ('row(s) read', 'row(s) read'),
    ('short line(s)', 'short line(s)')
  ) t(source, value)
on conflict (key, locale) do nothing;
-- One of those 128 broke §4's never-on-a-screen rule and nothing had ever been
-- able to see it: a screen said "Determination matrix", which is the model's
-- word. It is "Account determination" above, and erp.assert_vocabulary_aligned()
-- refused this migration until it was — which is the first time that rule has
-- reached the components at all.
--
-- do nothing, not do update: the thirty-seven strings aligned earlier in
-- this file are already right, and re-stating their pre-alignment source
-- here would undo them.

select erp.assert_vocabulary_aligned();
