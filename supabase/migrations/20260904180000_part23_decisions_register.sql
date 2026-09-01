-- =============================================================================
-- Part 23 — the decisions register, and the assertion that keeps it honest
--
-- Specification v1.2 adds Part 23: eighteen decisions "already made, with the
-- reasoning that produced them", and states the property that makes them worth
-- recording — "A decision recorded here is settled: it may be revisited
-- deliberately, but not reopened by accident or drifted away from in a later
-- build."
--
-- Prose cannot hold that property. A decision drifted away from in a later
-- build looks exactly like a decision honoured, until somebody reads eighteen
-- paragraphs and the whole schema side by side. So this migration does what the
-- house pattern does everywhere else: the register states the intent, a binding
-- names the check that enforces it, and an assertion fails the build when a
-- decision has no enforcement or names one that has ceased to exist.
--
-- NOT erp_meta.policy_decision. That register already exists and is a different
-- thing: a log of decisions THIS BUILD took where the specification was
-- ambiguous or where the code knowingly diverged, each with a status of open or
-- accepted. Part 23's decisions are the product's settled architecture, are not
-- open, and are not this build's to accept. Conflating them would lose both:
-- a divergence log whose entries can close, and an architecture that cannot.
--
-- The enforcement bindings below are the substance of this migration. Each was
-- established by reading the named routine, not by matching words in its name.
-- Where a decision has no enforcing check, it says so in the open and the
-- assertion is written to tolerate exactly the ones enumerated here — so a
-- decision that loses its enforcement later cannot pass by inheriting the
-- tolerance of one that never had any.
-- =============================================================================

create table if not exists erp_ref.product_decision (
  code              text primary key,
  seq               integer not null,
  title             text not null,
  decision          text not null,
  rationale         text not null,
  cost              text,
  supersedes        text,
  spec_reference    text not null default 'v1.2 Part 23',
  registered_at     timestamptz not null default now(),
  constraint product_decision_code_shape check (code ~ '^D[0-9]+$')
);

comment on table erp_ref.product_decision is
  'Specification v1.2 Part 23. The product''s settled architectural decisions. '
  'Product content, not tenant content: no tenant_id, and no tenant may add to '
  'it. A row here is settled — revisited deliberately by amending the '
  'specification and this table together, never drifted away from in a build.';

-- Which check enforces which decision. Many-to-many on purpose: D1 is enforced
-- by three different routines, and one routine can enforce more than one
-- decision.
create table if not exists erp_ref.product_decision_check (
  decision_code   text not null references erp_ref.product_decision(code) on delete cascade,
  schema_name     text not null,
  routine_name    text not null,
  note            text not null,
  primary key (decision_code, schema_name, routine_name)
);

comment on table erp_ref.product_decision_check is
  'Binds a Part 23 decision to a routine that would fail if the decision were '
  'drifted away from. The note says HOW it enforces it, because a binding '
  'nobody can justify is a binding that will be wrong within two releases.';

-- ── The eighteen ─────────────────────────────────────────────────────────────

insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, supersedes) values
('D1', 1, 'Tenancy is the outermost scope, not a feature',
 'Every business object, configuration object, event, document, audit record, file and job carries a tenant. There is no unscoped operational table.',
 'Isolation added later cannot be proven; isolation designed in can be asserted adversarially on every build.',
 'Every query path and every job carries context plumbing.', null),

('D2', 2, 'State is derived, never stored as an editable balance',
 'On-hand, allocated, available, document position and subledger balances are computed from an append-only ledger. Corrections are reversing entries.',
 'It makes reconciliation, audit, recall and replay structural rather than bolted on, and it is the structural answer to phantom stock created by upstream deletion.',
 'Projections and their reconciliation checks are mandatory rather than optional (§6.6).', null),

('D3', 3, 'One user, one organisation',
 'Cross-tenant identity does not exist. A person needing access to two organisations holds two accounts. Exception, deliberate and narrow: platform staff may enter an organisation under an audited, time-bounded support access recorded in the platform log.',
 'Identity spanning tenants is the shortest path to a leak that row security cannot catch.',
 null, null),

('D4', 4, 'Configuration is data, and live configuration cannot be edited in place',
 'Changes accumulate in change sets, are previewed, approved, promoted, and are revertible to a versioned snapshot.',
 'A change nobody approved and nobody can explain is the failure this platform exists to prevent.',
 'An administrator cannot make a quick fix in live, by design.', null),

('D5', 5, 'Legislation is data, not an installed pack',
 'Jurisdictions arrive as versioned, effective-dated configuration bundles bound per company, evaluated by rule. No branch in code tests a country.',
 'Activating a market should not be an outage, a vendor dependency or a consultancy engagement.',
 'A conformance suite per jurisdiction is required, not optional.', null),

('D6', 6, 'No user-facing literal anywhere',
 'Every string resolves through a resource key with locale fallback.',
 'Retrofitting a resource layer touches every screen, and per-country duplication of configuration is the largest hidden cost in multi-country setup.',
 'Discipline from the first screen onward.', null),

('D7', 7, 'Accounting identity is a code on the product, not an account',
 'A product carries an accounting code; accounts are resolved by a determination matrix taking transaction type, accounting code, business partner class, site, company, ledger, legislation and reason code.',
 'An account held directly on a product must be re-coded per company, per ledger, per transaction type.',
 null,
 'The earlier notion of assigning GL codes directly to products. Not to be reintroduced.'),

('D8', 8, 'No default-to-suspense',
 'An unmatched posting is refused and named, and a coverage assertion enumerates gaps before promotion.',
 'Silent fallback to suspense is how a class of goods posts to the wrong account for a quarter without anyone noticing.',
 null, null),

('D9', 9, 'Ownership is separate from custody',
 'Every position and movement carries an owner and a custody party. Valuation follows ownership; operational visibility and counting follow custody.',
 'Third-party logistics, consignment in both directions, and contract manufacturing are ordinary in the target profile, and retrofitting this touches every movement row.',
 null, null),

('D10', 10, 'Batch attributes are amendable without moving stock',
 'Expiry, use-by, retest, supplier lot and status are amended by evented amendment with approval proportionate to the field. No stock movement is generated.',
 'Issuing stock out and receiving it back fabricates history that never happened, disturbs valuation, and breaks the genealogy a recall depends on.',
 null, null),

('D11', 11, 'Counting does not freeze operations',
 'A count records a counted quantity at a timestamp; expected quantity is reconstructed as at that moment and subsequent movements replayed on top. Locking, where genuinely needed, is the narrowest scope and soft by default.',
 'Counts that stop fulfilment get deferred, and accuracy suffers for the sake of not interrupting despatch.',
 null, null),

('D12', 12, 'Handling unit identity depth is configuration',
 'Containers nest without limit; the level at which identity is captured is policy per product class, site and process step, with count method bound to the same policy object. Historical units keep the policy under which they were created.',
 'Changing from per-box identity to master pallet identity is a configuration change, not a development project.',
 null, null),

('D13', 13, 'Allocation is two-stage, and scope is policy',
 'Global allocation reserves quantity at site level; detailed allocation commits specific stock under a configurable location scope. Where global succeeds and detailed fails, the cause is classified and, where stock exists outside scope, an internal replenishment task is raised.',
 'An order that is globally allocated but not detail-allocated is not a shortage, and treating it as one leaves a backlog nobody owns.',
 null, null),

('D14', 14, 'Printing is downstream of successful allocation',
 'Documents and labels are produced only for orders with committed stock in the marshalling area.',
 'It structurally removes the failure mode where labels exist for an order that cannot be picked.',
 null, null),

('D15', 15, 'Product identity is opaque; the readable code is derived',
 'The internal key is a meaningless surrogate. Classification is structured data from controlled vocabularies. The composed code is a rendering of that classification, unique and stable, flagged when it diverges from the attributes.',
 'Codes that encode meaning eventually lie, and correcting them breaks the audit trail.',
 null, null),

('D16', 16, 'Approval routing is department and threshold driven, with named assignment alongside',
 'Users belong to departments; bands route by value; named assignments override or prepend where a specific approver is required. Resolution order is named assignment, department band, company fallback, and every resolution records the rule version that produced it.',
 'It preserves the routing organisations already operate rather than imposing a new model.',
 null, null),

('D17', 17, 'The department object is single',
 'The department used for approval routing is the same object used as the analysis code for reporting.',
 'Two lists diverge, and then operations and reporting disagree about who spent what.',
 null, null),

('D18', 18, 'Artificial intelligence proposes; it never applies, and never decides a transaction',
 'Configuration intelligence authors, explains, analyses impact and generates tests, always as a diff requiring named human approval, validated in test first. Postings, allocations, tax determination and stock movements are executed by deterministic rules only.',
 'In a regulated estate, the line between authoring a rule and deciding a transaction is what keeps the system auditable.',
 null, null)
on conflict (code) do update set
  seq = excluded.seq, title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, cost = excluded.cost,
  supersedes = excluded.supersedes, spec_reference = excluded.spec_reference;

-- ── What enforces what ───────────────────────────────────────────────────────
-- Each binding was established by reading the routine. The note says how.

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
('D1','erp','assert_isolation',
 'Walks erp_meta.table_policy and fails on a tenant-scoped table without row security, or an unregistered table. "No unscoped operational table" is exactly its subject.'),
('D1','erp_test','assert_isolation_suite',
 'Builds two organisations and attacks one from the other, so isolation is proven adversarially rather than structurally only, which is what D1''s rationale claims.'),
('D1','erp','assert_session_context_hygiene',
 'A tenant context surviving a commit would defeat D1 on a pooled connection regardless of policy correctness.'),

('D2','erp','assert_stock_reconciles',
 'Recomputes position from the movement ledger and compares. A stored editable balance would diverge here.'),
('D2','erp','assert_subledger_reconciles',
 'The same property for subledger balances against their source postings.'),
('D2','erp','assert_inventory_reconciles',
 'Derived inventory valuation against the ledger it is computed from.'),

('D3','erp','assert_public_api_safe',
 'Every public door is gated and every SECURITY DEFINER is registered with a rationale. D3''s narrow exception is platform staff support access, and the definer register is where that exception is stated rather than assumed.'),
('D3','erp_test','assert_superadmin_suite',
 'Exercises the platform staff path, including that entering an organisation is an audited act rather than standing identity.'),

('D4','erp','assert_configuration_promotable',
 'Every row of erp_meta.promotable_surface carries a live-config guard trigger and none is left over. This is the assertion that closes the gap between "configuration is promotable" as a claim and as a fact.'),
('D4','erp_test','assert_addendum_b_promotion_suite',
 'Proves a direct edit is refused on a live organisation and the same change succeeds through promotion.'),
('D4','erp','assert_no_dead_configuration',
 'Configuration that nothing reads is configuration nobody promoted for a reason; it is the other half of D4 staying meaningful.'),

('D5','erp','assert_resource_coverage',
 'Legislation and locale content resolve as data. A country branch in code would not need these rows to exist.'),

('D6','erp','assert_vocabulary_aligned',
 'Every user-facing key resolves through erp_ref.resource with a working locale fallback chain. A literal in a screen has no row here.'),
('D6','erp','assert_starter_vocabularies_sound',
 'The starter vocabularies D6 depends on are complete and internally consistent.'),

('D7','erp','assert_determination_coverage',
 'Enumerates every gap where a posting could fail to determine an account from the matrix. A GL code held directly on a product would make this assertion unnecessary, which is precisely why its existence enforces D7.'),
('D7','erp_test','assert_determination_coverage_suite',
 'Exercises the determination matrix across transaction type, class and company rather than reading a code off the product.'),

('D8','erp','assert_determination_coverage',
 'The same coverage report is D8''s enforcement: it enumerates gaps BEFORE promotion, which is what makes refusing at posting time safe rather than obstructive.'),
('D8','erp','assert_finance_depth_sane',
 'A suspense fallback would show here as a posting that balances without tracing to a rule.'),

('D9','erp','assert_inventory_sane',
 'Positions and movements carry owner and custody; this fails where a movement cannot name both.'),
('D9','erp_test','assert_inventory_suite',
 'Exercises consignment in both directions, which is the case that collapses if ownership and custody are one field.'),

('D10','erp','assert_batch_genealogy',
 'Genealogy continuous across amendment, split and merge. An out-and-in would break the chain this asserts.'),
('D10','erp_test','assert_inventory_suite',
 'Amends batch attributes and asserts no stock movement was generated.'),

('D11','erp_test','assert_inventory_suite',
 'Counts against a position that moves underneath, and asserts the expected quantity is reconstructed as at the count timestamp rather than frozen.'),
('D11','erp','assert_stock_reconciles',
 'Replaying subsequent movements on top of a count is only correct if the ledger still reconciles afterwards.'),

('D12','erp','assert_inventory_sane',
 'Container nesting and the identity policy that governs it are configuration rows, not enum branches; this fails where a unit exists outside a policy.'),

('D13','erp_test','assert_sales_depth_suite',
 'Drives global allocation succeeding and detailed allocation failing, and asserts the cause is classified and a replenishment task raised rather than the order being called short.'),
('D13','erp','assert_sales_controls_sane',
 'The allocation scope policy is configuration and must resolve for every channel that allocates.'),

('D14','erp_test','assert_sales_depth_suite',
 'Asserts documents and labels are refused for an order without committed stock in the marshalling area.'),
('D14','erp','assert_output_templates_sound',
 'The output surface D14 constrains must itself be sound for the constraint to mean anything.'),

('D15','erp','assert_master_data_sane',
 'The composed code is derived from classification and flagged on divergence; this fails where a code is authored directly.'),
('D15','erp_test','assert_master_data_suite',
 'Exercises composition and the divergence flag, which is the behaviour D15 trades away readability for.'),

('D16','erp','assert_document_create_permissions',
 'Approval routing resolves through bands and named assignment with the rule version recorded; a document whose creation permission cannot resolve would break that chain.'),
('D16','erp_test','assert_procurement_controls_suite',
 'Drives named assignment, department band and company fallback in that resolution order.'),

('D17','erp','assert_part5_coverage',
 'Part 5 names the department once, for routing and analysis both. Two objects would show as an uncovered capability or a duplicated one.'),

('D18','erp','assert_intelligence_boundary',
 'Derives the call graph from function source text and fails where a transaction path reaches into erp_ai. This is D18''s whole content: intelligence proposes, and cannot be called by anything that decides a transaction.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

-- ── The assertion ────────────────────────────────────────────────────────────

create or replace function erp.decision_enforcement_report()
returns table(decision_code text, finding text, detail text)
language sql
stable
set search_path = ''
as $$
  -- 1. A decision nothing enforces. Drift in a later build is invisible until
  --    somebody rereads the specification, which is the failure Part 23 names.
  select d.code, 'no check enforces this decision',
         d.title
    from erp_ref.product_decision d
   where not exists (select 1 from erp_ref.product_decision_check c
                      where c.decision_code = d.code)

  union all

  -- 2. A binding naming a routine that no longer exists. The register would
  --    then claim enforcement it does not have, which is worse than claiming
  --    none: it reads as green.
  select c.decision_code, 'the check named does not exist',
         c.schema_name || '.' || c.routine_name
    from erp_ref.product_decision_check c
   where not exists (
     select 1 from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = c.schema_name and p.proname = c.routine_name)

  union all

  -- 3. A decision in the register that the specification does not carry, or one
  --    the specification carries that is missing here. Part 23 is D1 to D18 at
  --    v1.2; a gap in the sequence means a decision was dropped in a migration
  --    rather than revisited deliberately.
  select 'D' || g::text, 'the specification names this decision and the register does not',
         'Part 23 runs D1 to D18 at v1.2'
    from generate_series(1, 18) g
   where not exists (select 1 from erp_ref.product_decision d
                      where d.code = 'D' || g::text)

  order by 1, 2
$$;

comment on function erp.decision_enforcement_report is
  'Specification v1.2 Part 23. Every decision has a check, every named check '
  'exists, and the register carries the whole sequence. Read by '
  'erp.assert_product_decisions_enforced().';

create or replace function erp.assert_product_decisions_enforced()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer;
  v_detail text;
  v_decisions integer;
  v_checks integer;
begin
  select count(*), string_agg(format('  [%s] %s — %s',
                                     decision_code, finding, detail), E'\n')
    into v_count, v_detail
    from erp.decision_enforcement_report();

  if v_count > 0 then
    raise exception
      'ERPWARE_DECISION_UNENFORCED: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = 'Part 23 says a decision here is settled and not to be '
                   'drifted away from. Either bind the decision to the check '
                   'that enforces it, or write the check.';
  end if;

  select count(*) into v_decisions from erp_ref.product_decision;
  select count(*) into v_checks from erp_ref.product_decision_check;

  return format('decisions: %s settled, %s enforced by %s bound check(s)',
                v_decisions, v_decisions, v_checks);
end;
$$;

comment on function erp.assert_product_decisions_enforced is
  'Fails when a Part 23 decision has no enforcing check, when a binding names a '
  'routine that has ceased to exist, or when the register has lost one of D1 to '
  'D18.';

-- Register the two new tables as product content, so the row-security generator
-- treats them the way it treats every other erp_ref table rather than leaving
-- them outside the pattern.
insert into erp_meta.table_policy (schema_name, table_name, table_class, note)
values
  ('erp_ref','product_decision','product_content',
   'Specification Part 23. Every organisation reads the same eighteen '
   'decisions, and none may add to them.'),
  ('erp_ref','product_decision_check','product_content',
   'The enforcement bindings behind Part 23. Product content for the same reason '
   'the decisions are.')
on conflict (schema_name, table_name) do nothing;

-- Register the new assertion as a diagnostic. erp.assert_diagnostics_registered()
-- refuses an assertion that is neither registered nor exempt, and it is right
-- to: a check nobody can run from the platform screen is a check that only runs
-- when CI happens to call it. It caught this omission on the first sweep after
-- the migration, which is the pattern doing to this build what this build does
-- to the specification.
insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('product_decisions', 'Part 23 decisions enforced', 'assertion', 'platform',
   'erp', 'assert_product_decisions_enforced', '',
   'decision_enforcement_report', '',
   'Part 23''s eighteen settled decisions, each bound to the check that would '
   'fail if it were drifted away from. Fails where a decision has no '
   'enforcement, where a binding names a routine that has ceased to exist, or '
   'where the register has lost one of D1 to D18.',
   true, 53)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

-- The generators, then the assertions — a chunk that ends red leaves nothing
-- behind, because the call is the transaction.
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_product_decisions_enforced();
