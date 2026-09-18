-- =============================================================================
-- A zero-rated supply can be said
--
-- erp.configure_tax('GB', 20) is the product's own tax setup door: it is on the
-- Administration configuration screen, it authors a B6 change set, and since
-- 20260916030000 the demonstration builder calls it. Until this file it
-- installed two rules and no more:
--
--   seq 10  supply_type == 'export'     →  code Z, 0%
--   seq 20  supply_type == 'domestic'   →  code S, 20%
--
-- So an organisation set up by this product could charge twenty per cent or
-- nothing, and the only thing that decided which was where the goods went. A
-- British baker selling bread was charged 20% on a loaf. A landlord letting
-- a flat, an insurance broker, a private tutor: all standard-rated. A grant
-- that is not consideration for anything: standard-rated. The rate a supply
-- carries had nothing to do with what the supply was.
--
-- Three things were wrong and they are different faults.
--
--   1. There was no domestic zero rate and no reduced rate. Only the rate on
--      the residual and nothing else.
--
--   2. Zero-rated, exempt and outside the scope could not be told apart. All
--      three carry no tax, and the model had nowhere to say which one a supply
--      was: erp.tax_determination records a tax_code and a rate_pct, and a
--      zero is a zero. They are three different things. A zero-rated supply is
--      a taxable supply on which the rate happens to be nil, and the input tax
--      on what went into it is recoverable. An exempt supply is not taxable and
--      restricts recovery of the input tax attributable to it. Something
--      outside the scope is not a supply for this tax at all and does not
--      count towards the registration threshold. They are three different
--      lines on a return and three different answers to "may I reclaim the VAT
--      on what I bought to make it".
--
--   3. What looked like a residual was not one. `supply_type == 'domestic'` is
--      a positive determination that reads as a default. A supply the product
--      knows nothing about was not being defaulted to the standard rate; it
--      was being determined to be standard-rated, and the record of the
--      determination said so.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What was already right, and is not changed here
--
-- The legislation packs of 20260906081000 DO carry a domestic zero rate.
-- gb_vat v1 zero-rates food (Sch 8 Group 1) and books (Sch 8 Group 3), charges
-- 5% on domestic fuel (Sch 7A Group 1), zero-rates exports and ends in a
-- residual at 20% — each with the statute it was read from. Those packs are
-- not touched. Two reasons, and the second is the stronger:
--
--   * A pack is a version. A rule added to a version in force changes what
--     that version decided for documents it has already decided, which is the
--     one thing the pack model exists to prevent. United Kingdom exempt and
--     outside-the-scope rules belong in gb_vat v2, bound from its own
--     effective date. That is a separate, dated change.
--
--   * Labelling the German and Irish packs' rules with a treatment would be
--     this file making judgements about another country's law. §4 Nr. 1(a)
--     UStG makes an Ausfuhrlieferung *steuerfrei* — exempt in the words of the
--     statute — and yet input tax on it is recoverable, which is not what
--     "exempt" means in the sense this file needs. That is exactly the kind of
--     reading that belongs to somebody qualified to make it.
--
-- Nothing binds a legislation pack today in any case: a binding is only ever
-- authored from the onboarding interview's org.legislation answer, and the
-- demonstration organisation does not answer it. erp.configure_tax() is
-- therefore the live path, and it is the one this file repairs.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What a product can say, and what it may not
--
-- The packs read erp.item.item_class for food and books. That column is the
-- operational vocabulary — finished_good, raw_material, consumable, packaging
-- on the demonstration — and it is already read by costing policies, receipt
-- tolerances, match tolerances and count programmes. Overloading it further
-- would mean a product could not be a finished good and zero-rated at the same
-- time, and reclassifying for tax would silently move its costing.
--
-- So a product gains erp.item.tax_class: its own word, referencing
-- erp_ref.tax_treatment, null where nobody has said. It is registered in
-- erp_ref.maintainable_field, so it is set through the change request and mass
-- maintenance doors that already exist, under the permission they already ask,
-- on the screen that already shows them. No new door and no new screen: a
-- field that a person can already reach is better than a door that says the
-- same thing again.
--
-- WHAT THIS FILE DOES NOT DECIDE. Whether a particular biscuit is zero-rated
-- food or standard-rated confectionery, whether a particular letting is exempt
-- or opted to tax, whether a particular grant is consideration: those are
-- judgements for the organisation's accountant against the organisation's own
-- facts, and this product is not a tax adviser. What is built here is the
-- vocabulary and the mechanism — five treatments, a place on the product to
-- record which one applies, and rules that read what was recorded. The answer
-- is the organisation's, entered once per product and applied consistently
-- afterwards. Where it is not entered, the residual applies and says so.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The rates the door installs, and why these
--
--   seq 10  export             supply_type == 'export'          Z  0   zero_rated
--   seq 20  zero-rated class   tax_class == 'zero_rated'        Z  0   zero_rated
--   seq 30  reduced class      tax_class == 'reduced'           R  5   reduced
--   seq 40  exempt class       tax_class == 'exempt'            X  0   exempt
--   seq 50  outside the scope  tax_class == 'outside_scope'     O  0   outside_scope
--   seq 60  standard class     tax_class == 'standard'          S  20  standard
--   seq 99  residual           true                             S  20  standard
--
-- Export keeps the code it has had since 20260829300000. It is zero-rated on
-- the same treatment as a domestic zero-rated supply — both are taxable
-- supplies at nil with the input tax recoverable — and the two differ only in
-- the rule that reached them, which erp.tax_determination.rule_code records.
-- Changing the letter would have split one row of every existing return into
-- two for no gain.
--
-- Seq 60 is not redundant beside seq 99. A product whose owner has said
-- "standard" has been determined; a product nobody has classified has been
-- defaulted. Both end at 20%, and the difference between them is the whole of
-- what point 3 above was about: the rule code on the determination says which
-- happened, erp.tax_residual_report() counts the second, and the facts the
-- determination recorded say "tax_class": "unstated" in so many words.
--
-- Five per cent is the United Kingdom's reduced rate (VATA 1994 s.29A and
-- Sch 7A). The door's p_home_country argument has never been read by any
-- version of this function and is not read here either; an organisation
-- outside the United Kingdom binds a legislation pack, which is the mechanism
-- the product built for that, or edits the promoted rule set, which is the
-- mechanism it built for the rest. Changing the signature to take a second
-- rate would move a door that erp_meta.public_write_allowance, the Part 5
-- coverage register and public.erp_configure_tax() all name by argument list.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What is deliberately left
--
--   * Posted history is not restated. An organisation that has already
--     promoted the two-rule set keeps it; re-running erp.configure_tax() from
--     the Administration screen authors a new change set and promotes a new
--     version of the rule set from its own effective date, which is how every
--     other rate change in this product works. Determinations already made
--     stand, as 20260916030000 left the demonstration's first year of trading
--     standing.
--
--   * The demonstration organisation's products are not reclassified. Acme
--     Manufacturing sells widgets, gearboxes, control panels, steel bar and
--     bearings. Every one of them is standard-rated in the United Kingdom, and
--     giving any of them a zero-rated class to exercise the new rule would put
--     a wrong figure on a seeded trading year that other suites reconcile
--     against the ledger. The new rates are exercised by erp_test
--     .zero_rated_supply_suite() on its own fixture instead, which is where a
--     demonstration of a rate belongs.
--
--   * Input tax records no treatment. erp.state_supplier_tax() transcribes
--     what a supplier's invoice states, and what a supplier's supply was is
--     the supplier's classification, not ours to assert. The column is null on
--     those rows and the report shows it as such.
--
-- Proof: erp_test.assert_zero_rated_supply_suite() (13 cases, wrapper pinned)
-- and erp.assert_tax_treatments_are_distinct(), registered as the diagnostic
-- tax_treatments_distinct, which refuses a model in which zero-rated, exempt
-- and outside the scope have collapsed into one another.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The five treatments, and what distinguishes them
--
-- Product reference content: the treatments a value added tax knows, not a
-- tenant's opinion about them. The two boolean columns are the whole point of
-- the table — they are what makes zero-rated, exempt and outside the scope
-- three rows rather than one, and they are the questions a return and an input
-- tax claim actually ask.
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.tax_treatment (
  code                     text primary key
                             check (code ~ '^[a-z][a-z_]*$'),
  name                     text not null check (length(btrim(name)) > 0),
  -- Within the scope of the tax and taxable, whatever the rate happens to be.
  is_taxable_supply        boolean not null,
  -- Whether making this supply restricts recovery of the input tax
  -- attributable to it. The single sentence that separates exempt from
  -- zero-rated, and the reason they may not be one row.
  restricts_input_recovery boolean not null,
  -- Whether the value counts towards the registration threshold.
  counts_in_taxable_turnover boolean not null,
  description              text not null check (length(btrim(description)) >= 40)
);

comment on table erp_ref.tax_treatment is
  'The treatments a value added tax distinguishes: standard, reduced, '
  'zero-rated, exempt and outside the scope. Zero-rated, exempt and outside '
  'the scope all carry no tax and are not the same thing — they differ on '
  'whether the supply is taxable, whether input tax attributable to it is '
  'recoverable, and whether its value counts towards registration — so each '
  'is a row and the columns say which is which.';

insert into erp_ref.tax_treatment
  (code, name, is_taxable_supply, restricts_input_recovery,
   counts_in_taxable_turnover, description) values
  ('standard', 'Standard rated', true, false, true,
   'A taxable supply at the standard rate. Input tax attributable to it is recoverable and its value counts towards the registration threshold.'),
  ('reduced', 'Reduced rated', true, false, true,
   'A taxable supply at a reduced rate the legislation names for a described class of supply. Input tax attributable to it is recoverable.'),
  ('zero_rated', 'Zero rated', true, false, true,
   'A taxable supply on which the rate is nil. It is taxable: input tax attributable to it is recoverable in full, and its value counts towards the registration threshold. This is what separates it from an exempt supply.'),
  ('exempt', 'Exempt', false, true, false,
   'A supply within the scope of the tax on which no tax is chargeable and for which input tax attributable to it is not recoverable. Making exempt supplies alongside taxable ones is what puts an organisation into partial exemption.'),
  ('outside_scope', 'Outside the scope', false, false, false,
   'Not a supply within the scope of the tax at all, so no tax arises and nothing enters the taxable turnover. Different from exempt, which is within the scope and relieved.')
on conflict (code) do update
  set name = excluded.name,
      is_taxable_supply = excluded.is_taxable_supply,
      restricts_input_recovery = excluded.restricts_input_recovery,
      counts_in_taxable_turnover = excluded.counts_in_taxable_turnover,
      description = excluded.description;

insert into erp_meta.table_policy (schema_name, table_name, table_class, note)
values ('erp_ref', 'tax_treatment', 'product_content',
        'the treatments a value added tax distinguishes; read by the tax determination as the caller')
on conflict (schema_name, table_name) do update
  set table_class = excluded.table_class, note = excluded.note;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A product says which treatment it is
--
-- Its own column. erp.item.item_class is the operational vocabulary and is
-- already read by four other mechanisms; a product must be able to be a
-- finished good and zero-rated at once.
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.item add column if not exists tax_class text;

do $tax_class_fk$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint c
     where c.conrelid = 'erp.item'::regclass and c.conname = 'item_tax_class_fkey')
  then
    alter table erp.item
      add constraint item_tax_class_fkey
      foreign key (tax_class) references erp_ref.tax_treatment (code);
  end if;
end
$tax_class_fk$;

create index if not exists item_tax_class_idx
  on erp.item (tenant_id, tax_class) where tax_class is not null;

comment on column erp.item.tax_class is
  'Which tax treatment this product is, from erp_ref.tax_treatment. Null where '
  'nobody has said, and then the residual rule applies and the determination '
  'records that nobody said. Separate from item_class, which is the '
  'operational classification costing, receipt tolerance, match tolerance and '
  'count programmes already read.';

insert into erp_ref.maintainable_field
  (object_type, table_name, column_name, data_kind, rationale)
values ('item', 'item', 'tax_class', 'text',
        'Which tax treatment a product is — zero-rated, exempt, outside the scope, reduced or standard. The organisation''s accountant''s answer, entered once per product and read by every determination afterwards, and reclassified in bulk when a ruling changes.')
on conflict (object_type, column_name) do update
  set table_name = excluded.table_name, data_kind = excluded.data_kind,
      rationale = excluded.rationale;

do $maintained$
begin
  if not exists (select 1 from erp_ref.maintainable_field m
                  where m.object_type = 'item' and m.column_name = 'tax_class'
                    and m.table_name = 'item' and m.data_kind = 'text') then
    raise exception
      'CLOVEERP_REGISTER_NOT_WRITTEN: erp_ref.maintainable_field does not list item.tax_class after the insert'
      using hint = 'Without the register row the field cannot be reached by a change request, so a product could carry a treatment nobody can set.';
  end if;
end
$maintained$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The decision point learns the word
--
-- erp_ref.decision_point's input schema sets additionalProperties false and
-- B3's linter refuses a rule reading a fact the decision point never supplies
-- — erp.activate_rule_set_version() runs the linter, so a promotion carrying
-- a tax_class rule would be refused until the schema declares it. The outcome
-- schema gains treatment beside the rate and the code.
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.decision_point
   set input_schema =
         '{"type":"object","required":["item_class","supply_type"],
           "properties":{"item_class":{"type":"string"},
                         "tax_class":{"type":"string"},
                         "supply_type":{"type":"string"},
                         "net_minor":{"type":"integer"},
                         "customer_registered":{"type":"boolean"}},
           "additionalProperties":false}'::jsonb,
       outcome_schema =
         '{"type":"object","required":["rate_pct","code"],
           "properties":{"rate_pct":{"type":"number"},
                         "code":{"type":"string"},
                         "treatment":{"type":"string"}}}'::jsonb
 where code = 'tax.determination';

do $dp$
begin
  if not exists (
    select 1 from erp_ref.decision_point dp
     where dp.code = 'tax.determination'
       and dp.input_schema -> 'properties' ? 'tax_class'
       and dp.outcome_schema -> 'properties' ? 'treatment')
  then
    raise exception
      'CLOVEERP_DECISION_POINT_NOT_WIDENED: tax.determination does not declare tax_class and treatment after the update'
      using hint = 'Without the declaration the linter refuses every rule this migration installs, and the promotion below would fail.';
  end if;
end
$dp$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A determination records which treatment it applied
--
-- Null where the rule that decided did not say: a legislation pack's rules do
-- not, and erp.state_supplier_tax() transcribes a supplier's figure rather
-- than classifying their supply. Null is honest there; a treatment inferred
-- from a zero would be the collapse this file exists to undo.
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.tax_determination add column if not exists treatment text;

do $td_fk$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint c
     where c.conrelid = 'erp.tax_determination'::regclass
       and c.conname = 'tax_determination_treatment_fkey')
  then
    alter table erp.tax_determination
      add constraint tax_determination_treatment_fkey
      foreign key (treatment) references erp_ref.tax_treatment (code);
  end if;
end
$td_fk$;

comment on column erp.tax_determination.treatment is
  'Which of erp_ref.tax_treatment the rule that decided applied. Null where '
  'the rule did not say — a legislation pack rule, or a supplier''s stated '
  'figure — because a zero rate does not say by itself whether the supply was '
  'zero-rated, exempt or outside the scope.';

-- The body is needled rather than re-emitted: 20260906081000 put the
-- legislation pack and version into it, and re-emitting from 20260829300000
-- would drop that silently. Every anchor is asserted to occur exactly once
-- before anything is replaced.
do $determine$
declare
  v_sig constant text := 'erp.determine_tax(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_n1  constant text := E'  v_pack_version integer;\nbegin';
  v_n2  constant text :=
       E'    ''item_class'', coalesce(\n'
    || E'      (select i.item_class from erp.item i where i.id = l.item_id), ''standard''),';
  v_n3  constant text := E'  v_code := o.outcome ->> ''code'';';
  v_n4  constant text :=
       E'    taxable_minor, tax_minor, currency, jurisdiction, rule_code,\n'
    || E'    legislation_pack_code, legislation_pack_version,\n'
    || E'    determination_inputs, rule_evaluation_id, determined_at)';
  v_n5  constant text := E'          o.rule_code, v_pack, v_pack_version, v_facts, null, now())';
  v_hits integer;
begin
  -- Applied already? A replay that met this halfway is how the 8 September
  -- deploy lost twenty-three minutes.
  if position('v_treatment' in v_def) > 0 then
    raise exception
      'CLOVEERP_DETERMINE_TAX_ALREADY_RECORDS_TREATMENT: % already records a treatment; this migration would add it twice', v_sig
      using hint = 'Nothing to do. Check what previously applied this and remove the duplicate migration.';
  end if;

  select (case when position(v_n1 in v_def) > 0 then 1 else 0 end)
       + (case when position(v_n2 in v_def) > 0 then 1 else 0 end)
       + (case when position(v_n3 in v_def) > 0 then 1 else 0 end)
       + (case when position(v_n4 in v_def) > 0 then 1 else 0 end)
       + (case when position(v_n5 in v_def) > 0 then 1 else 0 end)
    into v_hits;

  if v_hits <> 5
     or (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3) <> 1
     or (length(v_def) - length(replace(v_def, v_n4, ''))) / length(v_n4) <> 1
     or (length(v_def) - length(replace(v_def, v_n5, ''))) / length(v_n5) <> 1
  then
    raise exception
      'CLOVEERP_DETERMINE_TAX_UNRECOGNISED: % is not the body this migration patches (% of 5 anchors found)', v_sig, v_hits
      using hint = 'A later migration changed it. Read the current body with pg_get_functiondef and re-anchor rather than re-emitting it.';
  end if;

  v_def := replace(v_def, v_n1,
       E'  v_pack_version integer;\n'
    || E'  v_treatment text;\n'
    || E'begin');

  -- The product's own word for what it is, beside the operational class. The
  -- word when nobody has said is 'unstated', not null: it is the fact the
  -- residual rule fell through on, and a determination that records it says
  -- in so many words that nothing classified this supply.
  v_def := replace(v_def, v_n2, v_n2 ||
       E'\n'
    || E'    ''tax_class'', coalesce(\n'
    || E'      (select i.tax_class from erp.item i where i.id = l.item_id), ''unstated''),');

  v_def := replace(v_def, v_n3, v_n3 ||
       E'\n'
    || E'  -- Which of the five this was. Null where the rule did not say: a\n'
    || E'  -- zero rate does not say by itself whether a supply was zero-rated,\n'
    || E'  -- exempt or outside the scope, and guessing collapses the three.\n'
    || E'  v_treatment := o.outcome ->> ''treatment'';');

  v_def := replace(v_def, v_n4,
       E'    taxable_minor, tax_minor, currency, jurisdiction, rule_code,\n'
    || E'    legislation_pack_code, legislation_pack_version, treatment,\n'
    || E'    determination_inputs, rule_evaluation_id, determined_at)');

  v_def := replace(v_def, v_n5,
       E'          o.rule_code, v_pack, v_pack_version, v_treatment, v_facts, null, now())');

  execute v_def;

  -- Re-emitted without what it was re-emitted for is the failure this catches.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('''tax_class'', coalesce(' in v_def) = 0
     or position('v_treatment := o.outcome ->> ''treatment''' in v_def) = 0
     or position('legislation_pack_code, legislation_pack_version, treatment,' in v_def) = 0
  then
    raise exception
      'CLOVEERP_DETERMINE_TAX_LOST_ITS_TREATMENT: % was re-emitted without reading the product''s tax class or recording the treatment', v_sig
      using hint = 'The replacement did not take. Do not proceed: every determination after this would silently lose the distinction.';
  end if;
end
$determine$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The door installs the rates a United Kingdom business needs
--
-- Needled on the rule array, which is the only part that changes. The call to
-- erp.install_module_config() around it, and the reason it is there — B6
-- refuses a direct write to a rule set in a live environment — are untouched.
-- ═════════════════════════════════════════════════════════════════════════════

do $configure$
declare
  v_sig constant text := 'erp.configure_tax(character, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'            -- Order matters and the engine stops on the first match, so the\n'
    || E'            -- narrow cases come first.\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',10,''code'',''export_zero'',''name'',''Export, zero rated'',\n'
    || E'              ''condition'', jsonb_build_object(''=='', jsonb_build_array(\n'
    || E'                jsonb_build_object(''var'',''supply_type''), ''export'')),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''Z'',''rate_pct'',0)),\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',20,''code'',''domestic_standard'',''name'',''Domestic standard rate'',\n'
    || E'              ''condition'', jsonb_build_object(''=='', jsonb_build_array(\n'
    || E'                jsonb_build_object(''var'',''supply_type''), ''domestic'')),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''S'',\n'
    || E'                                            ''rate_pct'',p_standard_rate)))))));';
  v_new text;
begin
  if position('residual_standard_rated' in v_def) > 0 then
    raise exception
      'CLOVEERP_CONFIGURE_TAX_ALREADY_HAS_ITS_RATES: % already installs the five treatments', v_sig
      using hint = 'Nothing to do. Check what previously applied this and remove the duplicate migration.';
  end if;

  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception
      'CLOVEERP_CONFIGURE_TAX_UNRECOGNISED: the rule array in % is not the one this migration replaces. It reads: %',
      v_sig, substr(v_def, greatest(position('''rules''' in v_def), 1), 600)
      using hint = 'A later migration changed it. Read the current body with pg_get_functiondef and re-anchor rather than re-emitting it.';
  end if;

  v_new := replace(v_def, v_old,
       E'            -- Order matters and the engine stops on the first match.\n'
    || E'            -- Where the goods went decides first, because an export is\n'
    || E'            -- zero-rated whatever it is; then what the product says it\n'
    || E'            -- is; then, and only then, the residual.\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',10,''code'',''export_zero'',''name'',''Export, zero rated'',\n'
    || E'              ''condition'', jsonb_build_object(''=='', jsonb_build_array(\n'
    || E'                jsonb_build_object(''var'',''supply_type''), ''export'')),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''Z'',''rate_pct'',0,\n'
    || E'                                            ''treatment'',''zero_rated'')),\n'
    || E'            -- A zero-rated supply at home. Taxable at nil, and the input\n'
    || E'            -- tax on what went into it is recoverable, which is what\n'
    || E'            -- separates it from the exempt rule four below.\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',20,''code'',''zero_rated_class'',''name'',''Zero rated'',\n'
    || E'              ''condition'', jsonb_build_object(''=='', jsonb_build_array(\n'
    || E'                jsonb_build_object(''var'',''tax_class''), ''zero_rated'')),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''Z'',''rate_pct'',0,\n'
    || E'                                            ''treatment'',''zero_rated'')),\n'
    || E'            -- Five per cent: VATA 1994 s.29A and Sch 7A. Which supplies\n'
    || E'            -- belong here is the organisation''s answer, recorded on the\n'
    || E'            -- product, not a reading this product makes.\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',30,''code'',''reduced_rated_class'',''name'',''Reduced rated'',\n'
    || E'              ''condition'', jsonb_build_object(''=='', jsonb_build_array(\n'
    || E'                jsonb_build_object(''var'',''tax_class''), ''reduced'')),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''R'',''rate_pct'',5,\n'
    || E'                                            ''treatment'',''reduced'')),\n'
    || E'            -- Exempt. No tax, and input tax attributable to it is not\n'
    || E'            -- recoverable. The rate is nil and the treatment is not.\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',40,''code'',''exempt_class'',''name'',''Exempt'',\n'
    || E'              ''condition'', jsonb_build_object(''=='', jsonb_build_array(\n'
    || E'                jsonb_build_object(''var'',''tax_class''), ''exempt'')),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''X'',''rate_pct'',0,\n'
    || E'                                            ''treatment'',''exempt'')),\n'
    || E'            -- Outside the scope. Not a supply for this tax at all, so\n'
    || E'            -- nothing enters the taxable turnover either.\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',50,''code'',''outside_scope_class'',''name'',''Outside the scope'',\n'
    || E'              ''condition'', jsonb_build_object(''=='', jsonb_build_array(\n'
    || E'                jsonb_build_object(''var'',''tax_class''), ''outside_scope'')),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''O'',''rate_pct'',0,\n'
    || E'                                            ''treatment'',''outside_scope'')),\n'
    || E'            -- Said to be standard rated, which is a determination.\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',60,''code'',''standard_rated_class'',''name'',''Standard rated'',\n'
    || E'              ''condition'', jsonb_build_object(''=='', jsonb_build_array(\n'
    || E'                jsonb_build_object(''var'',''tax_class''), ''standard'')),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''S'',\n'
    || E'                                            ''rate_pct'',p_standard_rate,\n'
    || E'                                            ''treatment'',''standard'')),\n'
    || E'            -- And the residual, which is a default and not a\n'
    || E'            -- determination. The standard rate is the right answer for\n'
    || E'            -- a supply nobody has classified — it is the one that\n'
    || E'            -- cannot understate the tax — but it is reached because\n'
    || E'            -- nothing else matched, and the determination says so: its\n'
    || E'            -- rule code is this one and the facts it recorded read\n'
    || E'            -- "tax_class": "unstated". erp.tax_residual_report() counts\n'
    || E'            -- them, so a default is never mistaken for an answer.\n'
    || E'            jsonb_build_object(\n'
    || E'              ''seq'',99,''code'',''residual_standard_rated'',\n'
    || E'              ''name'',''Residual: standard rated, because nothing said otherwise'',\n'
    || E'              ''condition'', to_jsonb(true),\n'
    || E'              ''outcome'', jsonb_build_object(''code'',''S'',\n'
    || E'                                            ''rate_pct'',p_standard_rate,\n'
    || E'                                            ''treatment'',''standard'')))))));');

  execute v_new;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('residual_standard_rated' in v_def) = 0
     or position('''treatment'',''exempt''' in v_def) = 0
     or position('''treatment'',''outside_scope''' in v_def) = 0
  then
    raise exception
      'CLOVEERP_CONFIGURE_TAX_LOST_ITS_RATES: % was re-emitted without the treatments it was re-emitted for', v_sig
      using hint = 'The replacement did not take. Do not proceed: the door would install two rules again.';
  end if;
end
$configure$;

comment on function erp.configure_tax(char, numeric) is
  'Spec 5.7: tax determination as promoted rules on B3''s decision point. '
  'Installs the five treatments a United Kingdom business needs — standard, '
  'reduced, zero-rated, exempt and outside the scope — read from the product''s '
  'own tax_class, with exports zero-rated first and a residual last that is '
  'visibly a default. Not optional: B6 refuses a direct write to a rule set in '
  'a live environment, which is exactly the control a tax rate should be under.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The return keeps the three zeroes apart
--
-- A returns-table function cannot gain a column by replacement, so it goes and
-- comes back, the way 20260916410000 added the direction. public
-- .erp_tax_report() reads it with to_jsonb(), so the door carries the new
-- column without being touched.
-- ═════════════════════════════════════════════════════════════════════════════

drop function if exists erp.tax_report(date, date, uuid);

create or replace function erp.tax_report(
  p_from date, p_to date, p_entity_id uuid default null)
returns table (direction text, jurisdiction text, treatment text, tax_code text,
               rate_pct numeric, taxable_minor bigint, tax_minor bigint,
               currency char(3), transactions bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  -- By jurisdiction and code, because that is the shape of every return; by
  -- direction, because tax charged and tax suffered are different boxes; and
  -- by treatment, because zero-rated, exempt and outside the scope all carry
  -- no tax and go in different places. Grouping the three together would
  -- overstate the recoverable input tax of every partially exempt business
  -- and understate nothing, which is the worse direction to be wrong in.
  select case erp.document_trade_side(d.id)
           when 'sale' then 'output'
           when 'purchase' then 'input'
           else 'unknown' end                     as direction,
         td.jurisdiction, td.treatment, td.tax_code, td.rate_pct,
         sum(td.taxable_minor)::bigint, sum(td.tax_minor)::bigint,
         td.currency, count(*)
    from erp.tax_determination td
    join erp.document d on d.id = td.document_id
   where td.tenant_id = erp.current_tenant_id()
     and d.document_date between p_from and p_to
     and (p_entity_id is null or td.entity_id = p_entity_id)
   group by 1, td.jurisdiction, td.treatment, td.tax_code, td.rate_pct, td.currency
   order by 1, 2, 3, 5 desc
$$;

revoke all on function erp.tax_report(date, date, uuid) from public, anon, authenticated;

comment on function erp.tax_report(date, date, uuid) is
  'Tax by direction, jurisdiction, treatment, code and rate for a period. '
  'Output is what was charged on supplies made; input is what suppliers '
  'charged and stated. Zero-rated, exempt and outside the scope are separate '
  'rows although all three carry no tax, because they are separate boxes on a '
  'return and separate answers on an input tax claim.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The default is visible
--
-- A residual is honest only while somebody can see how much of a period went
-- through it. This is a report and not an assertion: a supply nobody has
-- classified taking the standard rate is correct behaviour, not a fault, and a
-- check that refused it would be crying wolf by the end of the first week.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.tax_residual_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  -- How much of it, per company.
  select 'the standard rate was applied because nothing classified the supply',
         e.code,
         format('%s line(s) worth %s, carrying %s of tax, took the residual rule: '
                'the product they are for has no tax class, so the standard rate '
                'was a default and not a determination',
                count(*), sum(td.taxable_minor), sum(td.tax_minor))
    from erp.tax_determination td
    join t on t.tenant_id = td.tenant_id
    join erp.entity e on e.tenant_id = td.tenant_id and e.id = td.entity_id
   where td.rule_code = 'residual_standard_rated'
   group by e.code

  union all

  -- And which products they were, because that is the list somebody can act
  -- on: give the product a tax class and it leaves this report.
  select 'a product that has been invoiced has never been classified for tax',
         i.code,
         format('%s is sold and its tax class is not set, so every line of it '
                'takes the residual rather than a rate anybody chose', i.name)
    from erp.item i
    join t on t.tenant_id = i.tenant_id
   where i.tax_class is null
     and exists (select 1
                   from erp.tax_determination td
                   join erp.document_line dl
                     on dl.tenant_id = td.tenant_id and dl.id = td.document_line_id
                  where td.tenant_id = i.tenant_id
                    and dl.item_id = i.id
                    and td.rule_code = 'residual_standard_rated')

   order by 1, 2
$$;

revoke all on function erp.tax_residual_report() from public, anon, authenticated;

comment on function erp.tax_residual_report is
  'How much of an organisation''s tax was reached by the residual rule rather '
  'than by a determination. Not a fault: the standard rate is the right '
  'default for a supply nobody has classified. It is here so that a default '
  'is never read as an answer, and so that an organisation can see what it has '
  'not yet told the product about its own range.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq) values
  ('tax_reached_by_the_residual', 'Tax reached by the residual rule', 'report', 'tenant',
   'tax_residual_report', '', null, '',
   'The standard rate is the right default for a supply nobody has classified, and it is a default rather than a determination. This says how much of the tax charged was reached that way, so that a range nobody has classified for tax is visible rather than silently standard-rated. Give a product a tax class and it leaves this list.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      blurb = excluded.blurb;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. And the three may not collapse back into one
--
-- The property this whole file is about, held as a structural assertion rather
-- than left to be noticed. It reads the model and no tenant data, so it runs
-- on every build from an empty cluster.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.tax_treatment_report()
returns table(finding text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a treatment the product installs rules for is missing', v.code
    from (values ('standard'), ('reduced'), ('zero_rated'), ('exempt'),
                 ('outside_scope')) v(code)
   where not exists (select 1 from erp_ref.tax_treatment t where t.code = v.code)

  union all

  -- Zero-rated and exempt both carry no tax. If they ever agree on both of
  -- these, the model has stopped telling them apart and a partially exempt
  -- business would recover input tax it may not recover.
  select 'zero-rated and exempt are no longer distinguishable',
         format('both say taxable supply %s and restricts input recovery %s',
                z.is_taxable_supply, z.restricts_input_recovery)
    from erp_ref.tax_treatment z
    join erp_ref.tax_treatment x on x.code = 'exempt'
   where z.code = 'zero_rated'
     and z.is_taxable_supply = x.is_taxable_supply
     and z.restricts_input_recovery = x.restricts_input_recovery

  union all

  -- Outside the scope is not exempt. Exempt is within the scope and relieved;
  -- outside the scope never enters it, and does not count towards
  -- registration.
  select 'exempt and outside the scope are no longer distinguishable',
         format('both count in taxable turnover %s and restrict input recovery %s',
                x.counts_in_taxable_turnover, x.restricts_input_recovery)
    from erp_ref.tax_treatment x
    join erp_ref.tax_treatment o on o.code = 'outside_scope'
   where x.code = 'exempt'
     and x.counts_in_taxable_turnover = o.counts_in_taxable_turnover
     and x.restricts_input_recovery = o.restricts_input_recovery

  union all

  -- And the decision point has to be able to carry the distinction at all.
  select 'the tax decision point does not declare the fact a product states',
         'erp_ref.decision_point(tax.determination).input_schema has no tax_class property, '
         'so B3''s linter refuses every rule that reads one'
    from erp_ref.decision_point dp
   where dp.code = 'tax.determination'
     and not (dp.input_schema -> 'properties' ? 'tax_class')

  union all

  select 'the tax decision point does not declare the treatment an outcome states',
         'erp_ref.decision_point(tax.determination).outcome_schema has no treatment property, '
         'so a rule could not say which of the five it applied'
    from erp_ref.decision_point dp
   where dp.code = 'tax.determination'
     and not (dp.outcome_schema -> 'properties' ? 'treatment')
$$;

revoke all on function erp.tax_treatment_report() from public, anon, authenticated;

create or replace function erp.assert_tax_treatments_are_distinct()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s — %s', finding, detail), E'\n')
    into v_count, v_detail
    from erp.tax_treatment_report();

  if v_count > 0 then
    raise exception E'CLOVEERP_TAX_TREATMENTS_COLLAPSED: % finding(s)\n%', v_count, v_detail
      using hint = 'Zero-rated, exempt and outside the scope carry no tax and are three different things on a return. Restore the rows or the schema properties named above before anything determines tax again.';
  end if;

  return 'tax treatments: zero-rated, exempt and outside the scope are distinguishable';
end;
$$;

revoke all on function erp.assert_tax_treatments_are_distinct() from public, anon, authenticated;

comment on function erp.assert_tax_treatments_are_distinct is
  'The five treatments exist, zero-rated and exempt differ on whether input '
  'tax is recoverable, exempt and outside the scope differ on whether the '
  'value counts towards registration, and the decision point can carry both '
  'the product''s stated class and the rule''s stated treatment.';

-- An assertion that is not registered is one nothing can run from a screen,
-- and erp.assert_diagnostics_registered() refuses it. Platform scope: it reads
-- erp_ref and the decision point and needs no organisation.
insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq) values
  ('tax_treatments_distinct', 'Zero-rated, exempt and outside the scope are three things',
   'assertion', 'platform', 'assert_tax_treatments_are_distinct', '',
   'tax_treatment_report', '',
   'All three carry no tax and they are not the same thing: a zero-rated supply is taxable at nil and the input tax on it is recoverable; an exempt supply is not taxable and restricts recovery; something outside the scope is not a supply for this tax at all. They are different boxes on a return and different answers on a claim, so the product holds them as three treatments and this refuses a model in which they have collapsed into one another.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The word the report now says
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key('Treatment'), 'en', 'Treatment',
       'A screen string declared at its call site and rendered through ui(). '
       'The tax report''s column separating zero-rated from exempt and from '
       'outside the scope, which all carry no tax and go in different places.'
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.zero_rated_supply_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 13;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  rb       record;
  v_entity uuid; v_ccy char(3); v_country char(2); v_site uuid; v_uom uuid;
  v_home uuid; v_away uuid;
  v_std uuid; v_zero uuid; v_red uuid; v_exempt uuid; v_out uuid; v_said uuid;
  v_inv uuid; v_line uuid;
  v_ok boolean; v_msg text;
  r record;
begin
  begin
    v_step := 'an organisation with finance, sales and the product''s own tax rules';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzvat-' || v_tag, 'Zero Rated Supply Suite',
      'admin@zzvat-' || v_tag || '.test', 'Zero Rated Supply Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzvat-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_sales(15);
    -- The door under test.
    perform erp.configure_tax('GB', 20);

    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary
      order by l.code limit 1;
    select e.country_code into v_country
      from erp.entity e where e.tenant_id = rb.tenant_id and e.id = v_entity;

    v_step := 'its own site, unit, two customers and six products';
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, v_entity, 'ZVSITE', 'Zero rated suite site', 'office', 'active')
    returning id into v_site;

    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZVEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;

    -- A customer at home and a customer abroad. The country is what decides
    -- domestic from export, and it is the entity's own that it is compared to.
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZVHOME', 'Home customer', v_country, 'active')
    returning id into v_home;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZVAWAY', 'Export customer',
            case when v_country = 'NO' then 'NZ' else 'NO' end, 'active')
    returning id into v_away;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    select rb.tenant_id, p.id, 'customer', 'active'
      from erp.party p where p.tenant_id = rb.tenant_id and p.code in ('ZVHOME', 'ZVAWAY');

    -- Six products. Five say what they are; one says nothing, which is the
    -- case the residual is for.
    insert into erp.item (tenant_id, code, name, item_class, tax_class,
                          stock_uom_id, lifecycle, status)
    values
      (rb.tenant_id, 'ZV-NONE',    'Something nobody classified', 'finished_good', null,            v_uom, 'active', 'active'),
      (rb.tenant_id, 'ZV-ZERO',    'A loaf of bread',             'finished_good', 'zero_rated',    v_uom, 'active', 'active'),
      (rb.tenant_id, 'ZV-REDUCED', 'Domestic fuel',               'finished_good', 'reduced',       v_uom, 'active', 'active'),
      (rb.tenant_id, 'ZV-EXEMPT',  'A letting',                   'finished_good', 'exempt',        v_uom, 'active', 'active'),
      (rb.tenant_id, 'ZV-OUTSIDE', 'A grant that buys nothing',   'finished_good', 'outside_scope', v_uom, 'active', 'active'),
      (rb.tenant_id, 'ZV-STD',     'A widget, said to be standard','finished_good','standard',      v_uom, 'active', 'active');

    select i.id into v_std    from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZV-NONE';
    select i.id into v_zero   from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZV-ZERO';
    select i.id into v_red    from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZV-REDUCED';
    select i.id into v_exempt from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZV-EXEMPT';
    select i.id into v_out    from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZV-OUTSIDE';
    select i.id into v_said   from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZV-STD';

    v_step := 'one domestic invoice with a line for each of them';
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_home,
                                 current_date, v_ccy, 'ZV-HOME', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_std,    1, 10000, 'nobody said');
    perform erp.add_document_line(v_inv, v_zero,   1, 10000, 'bread');
    perform erp.add_document_line(v_inv, v_red,    1, 10000, 'fuel');
    perform erp.add_document_line(v_inv, v_exempt, 1, 10000, 'a letting');
    perform erp.add_document_line(v_inv, v_out,    1, 10000, 'a grant');
    perform erp.add_document_line(v_inv, v_said,   1, 10000, 'a widget');

    for r in select l.id from erp.document_line l
              where l.tenant_id = rb.tenant_id and l.document_id = v_inv
              order by l.line_no
    loop
      perform erp.determine_tax(r.id);
    end loop;

    -- ── 1. The residual, and that it says it is one ───────────────────────
    v_step := 'reading the residual back';
    v_cases := v_cases + 1;
    select td.tax_code, td.rate_pct, td.tax_minor, td.treatment, td.rule_code,
           td.determination_inputs ->> 'tax_class' as said
      into r
      from erp.tax_determination td
      join erp.document_line l on l.id = td.document_line_id
     where td.tenant_id = rb.tenant_id and l.item_id = v_std;
    case_name := 'a supply nobody classified takes the standard rate as a default, and the determination says it was a default';
    passed := r.tax_code = 'S' and r.rate_pct = 20 and r.tax_minor = 2000
          and r.treatment = 'standard'
          and r.rule_code = 'residual_standard_rated'
          and r.said = 'unstated';
    detail := format('%s at %s%%, treatment %s, by rule %s, on a tax class of %s',
                     r.tax_code, r.rate_pct, r.treatment, r.rule_code, r.said);
    return next;

    -- ── 2. Zero-rated ─────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    select td.tax_code, td.rate_pct, td.tax_minor, td.treatment, td.rule_code into r
      from erp.tax_determination td
      join erp.document_line l on l.id = td.document_line_id
     where td.tenant_id = rb.tenant_id and l.item_id = v_zero;
    case_name := 'a product said to be zero rated is charged nothing, and is zero rated rather than exempt';
    passed := r.tax_code = 'Z' and r.rate_pct = 0 and r.tax_minor = 0
          and r.treatment = 'zero_rated' and r.rule_code = 'zero_rated_class';
    detail := format('%s at %s%%, %s of tax, treatment %s, by rule %s',
                     r.tax_code, r.rate_pct, r.tax_minor, r.treatment, r.rule_code);
    return next;

    -- ── 3. Reduced ────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    select td.tax_code, td.rate_pct, td.tax_minor, td.treatment into r
      from erp.tax_determination td
      join erp.document_line l on l.id = td.document_line_id
     where td.tenant_id = rb.tenant_id and l.item_id = v_red;
    case_name := 'a product said to be reduced rated is charged five per cent';
    passed := r.tax_code = 'R' and r.rate_pct = 5 and r.tax_minor = 500
          and r.treatment = 'reduced';
    detail := format('%s at %s%%, %s of tax, treatment %s',
                     r.tax_code, r.rate_pct, r.tax_minor, r.treatment);
    return next;

    -- ── 4. Exempt ─────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    select td.tax_code, td.rate_pct, td.tax_minor, td.treatment into r
      from erp.tax_determination td
      join erp.document_line l on l.id = td.document_line_id
     where td.tenant_id = rb.tenant_id and l.item_id = v_exempt;
    case_name := 'an exempt supply is charged nothing and is recorded as exempt, not as zero rated';
    passed := r.tax_code = 'X' and r.rate_pct = 0 and r.tax_minor = 0
          and r.treatment = 'exempt';
    detail := format('%s at %s%%, %s of tax, treatment %s',
                     r.tax_code, r.rate_pct, r.tax_minor, r.treatment);
    return next;

    -- ── 5. Outside the scope ──────────────────────────────────────────────
    v_cases := v_cases + 1;
    select td.tax_code, td.rate_pct, td.tax_minor, td.treatment into r
      from erp.tax_determination td
      join erp.document_line l on l.id = td.document_line_id
     where td.tenant_id = rb.tenant_id and l.item_id = v_out;
    case_name := 'something outside the scope is charged nothing and is recorded as outside the scope, not as exempt';
    passed := r.tax_code = 'O' and r.rate_pct = 0 and r.tax_minor = 0
          and r.treatment = 'outside_scope';
    detail := format('%s at %s%%, %s of tax, treatment %s',
                     r.tax_code, r.rate_pct, r.tax_minor, r.treatment);
    return next;

    -- ── 6. Said to be standard, which is not the same as defaulted ────────
    v_cases := v_cases + 1;
    select td.rule_code, td.rate_pct into r
      from erp.tax_determination td
      join erp.document_line l on l.id = td.document_line_id
     where td.tenant_id = rb.tenant_id and l.item_id = v_said;
    case_name := 'a product said to be standard rated is determined by the rule that reads it, not by the residual';
    passed := r.rule_code = 'standard_rated_class' and r.rate_pct = 20;
    detail := format('decided by %s at %s%%', r.rule_code, r.rate_pct);
    return next;

    -- ── 7. Export still comes first, and is still zero rated ──────────────
    v_step := 'an export of the thing nobody classified';
    v_cases := v_cases + 1;
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_away,
                                 current_date, v_ccy, 'ZV-AWAY', '{}'::jsonb);
    select erp.add_document_line(v_inv, v_std, 1, 10000, 'shipped abroad') into v_line;
    perform erp.determine_tax(v_line);
    select td.tax_code, td.rate_pct, td.treatment, td.rule_code into r
      from erp.tax_determination td where td.document_line_id = v_line;
    case_name := 'an export is zero rated before anything else is asked, whatever the product is';
    passed := r.tax_code = 'Z' and r.rate_pct = 0
          and r.treatment = 'zero_rated' and r.rule_code = 'export_zero';
    detail := format('%s at %s%%, treatment %s, by rule %s',
                     r.tax_code, r.rate_pct, r.treatment, r.rule_code);
    return next;

    -- ── 8. Three zeroes, three rows on the return ─────────────────────────
    v_step := 'reading the return';
    v_cases := v_cases + 1;
    case_name := 'zero rated, exempt and outside the scope are three rows on the return although all three carry no tax';
    passed := (select count(distinct tr.treatment)
                 from erp.tax_report(current_date - 1, current_date + 1) tr
                where tr.direction = 'output' and tr.tax_minor = 0
                  and tr.treatment in ('zero_rated', 'exempt', 'outside_scope')) = 3;
    detail := coalesce((select string_agg(format('%s %s at %s%%', tr.treatment, tr.tax_code, tr.rate_pct), ', '
                                          order by tr.treatment)
                          from erp.tax_report(current_date - 1, current_date + 1) tr
                         where tr.tax_minor = 0),
                       'the return has no untaxed rows at all');
    return next;

    -- ── 9. And they do not add up to one another ──────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the exempt supply is not counted as zero rated on the return';
    passed := (select sum(tr.taxable_minor) from erp.tax_report(current_date - 1, current_date + 1) tr
                where tr.treatment = 'zero_rated' and tr.direction = 'output') = 20000
          and (select sum(tr.taxable_minor) from erp.tax_report(current_date - 1, current_date + 1) tr
                where tr.treatment = 'exempt' and tr.direction = 'output') = 10000;
    detail := format('zero rated %s, exempt %s, outside the scope %s',
                     coalesce((select sum(tr.taxable_minor) from erp.tax_report(current_date - 1, current_date + 1) tr
                                where tr.treatment = 'zero_rated'), -1),
                     coalesce((select sum(tr.taxable_minor) from erp.tax_report(current_date - 1, current_date + 1) tr
                                where tr.treatment = 'exempt'), -1),
                     coalesce((select sum(tr.taxable_minor) from erp.tax_report(current_date - 1, current_date + 1) tr
                                where tr.treatment = 'outside_scope'), -1));
    return next;

    -- ── 10. The default is visible, and only the default ──────────────────
    v_cases := v_cases + 1;
    case_name := 'the residual report counts the supply nobody classified and none of the five that were';
    passed := (select count(*) from erp.tax_residual_report()) = 2
          and exists (select 1 from erp.tax_residual_report() rr
                       where rr.detail like '1 line(s) worth 10000,%')
          and exists (select 1 from erp.tax_residual_report() rr
                       where rr.reference = 'ZV-NONE')
          and not exists (select 1 from erp.tax_residual_report() rr
                           where rr.reference in ('ZV-ZERO', 'ZV-REDUCED', 'ZV-EXEMPT',
                                                  'ZV-OUTSIDE', 'ZV-STD'));
    detail := coalesce((select string_agg(rr.reference || ': ' || left(rr.detail, 60), ' | '
                                          order by rr.reference)
                          from erp.tax_residual_report() rr),
                       'the residual report is empty');
    return next;

    -- ── 11. A product may not claim a treatment the product does not know ─
    v_step := 'refusing an invented treatment';
    v_cases := v_cases + 1;
    begin
      update erp.item set tax_class = 'mostly_zero'
       where tenant_id = rb.tenant_id and id = v_zero;
      v_ok := false; v_msg := 'it was accepted';
    exception when others then
      v_ok := sqlstate = '23503';
      v_msg := left(sqlerrm, 90);
    end;
    case_name := 'a product cannot be given a tax treatment the product has never heard of';
    passed := v_ok;
    detail := v_msg;
    return next;

    -- ── 12. Every rule the door installed says which treatment it applies ─
    v_step := 'reading the promoted rule set back';
    v_cases := v_cases + 1;
    case_name := 'every rule the tax door installed names one of the five treatments, and the residual is last';
    passed := not exists (
                select 1 from erp.rule ru
                  join erp.rule_set_version rsv on rsv.id = ru.rule_set_version_id
                  join erp.rule_set rs on rs.id = rsv.rule_set_id
                 where rs.tenant_id = rb.tenant_id
                   and rs.decision_point_code = 'tax.determination'
                   and rsv.status = 'active'
                   and not exists (select 1 from erp_ref.tax_treatment t
                                    where t.code = ru.outcome ->> 'treatment'))
          and (select max(ru.seq) from erp.rule ru
                 join erp.rule_set_version rsv on rsv.id = ru.rule_set_version_id
                 join erp.rule_set rs on rs.id = rsv.rule_set_id
                where rs.tenant_id = rb.tenant_id
                  and rs.decision_point_code = 'tax.determination'
                  and rsv.status = 'active'
                  and ru.code = 'residual_standard_rated')
              = (select max(ru.seq) from erp.rule ru
                   join erp.rule_set_version rsv on rsv.id = ru.rule_set_version_id
                   join erp.rule_set rs on rs.id = rsv.rule_set_id
                  where rs.tenant_id = rb.tenant_id
                    and rs.decision_point_code = 'tax.determination'
                    and rsv.status = 'active');
    detail := format('%s rule(s), all naming a known treatment, residual last',
                     (select count(*) from erp.rule ru
                        join erp.rule_set_version rsv on rsv.id = ru.rule_set_version_id
                        join erp.rule_set rs on rs.id = rsv.rule_set_id
                       where rs.tenant_id = rb.tenant_id
                         and rs.decision_point_code = 'tax.determination'
                         and rsv.status = 'active'));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 13. Undone ──────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzvat-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzvat rolled back with its products, its invoices and its determinations');
  return next;

  -- The count guard says what stopped the fixture. Without it the wrapper sees
  -- a number and not a reason, and every break costs another build to find.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_ZERO_RATED_SUPPLY_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.zero_rated_supply_suite() from public, anon;

create or replace function erp_test.assert_zero_rated_supply_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 13;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _zero_rated_supply on commit drop as
    select * from erp_test.zero_rated_supply_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _zero_rated_supply;
  drop table _zero_rated_supply;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ZERO_RATED_SUPPLY_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_ZERO_RATED_SUPPLY_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a zero-rated supply can be said: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_zero_rated_supply_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_resource_coverage('en');
select erp.assert_ci_coverage();
select erp.assert_tax_treatments_are_distinct();
select erp_test.assert_zero_rated_supply_suite();
