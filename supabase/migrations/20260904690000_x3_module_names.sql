-- ─────────────────────────────────────────────────────────────────────────────
-- The navigation says what erp_ref.vocabulary already decided.
--
-- The terminology layer has been UK ERP standard since 20260903130000: Stock
-- rather than Inventory, Product rather than Item, Despatch rather than
-- Shipment, Marshalling area rather than Release area, Business partner rather
-- than Party. erp_ref.vocabulary records those choices and lists the words
-- other systems use as aliases, so a search for "inventory" still finds stock.
--
-- The navigation ignored all of it. The rail said "Inventory and warehouse",
-- "Master data", "Procurement" — words the glossary had already ruled against
-- or that no Sage user would look for. A product whose thesis is that wording
-- is configuration should not hard-code a different vocabulary in its menu.
--
-- So the module names move to what somebody arriving from Sage X3 expects,
-- and to what this product's own glossary already prefers where the two
-- agree — which is most places, because X3's UK build and this vocabulary
-- come from the same tradition:
--
--   Inventory and warehouse  ->  Stock          (vocabulary: stock; "Inventory" is the alias it avoids)
--   Procurement              ->  Purchasing     (X3's module name)
--   Production               ->  Manufacturing  (X3's module name; the document stays a works order)
--   Finance                  ->  Financials     (X3's module name)
--   Master data              ->  Common data    (X3's module name)
--   Logistics                ->  Despatch       (vocabulary: despatch; "Shipment" is the alias it avoids)
--   Quality and compliance   ->  Quality control (X3's module name)
--   Supply chain planning    ->  Planning       (X3's module name)
--   Reporting and analytics  ->  Reports and inquiries (X3 calls a saved read an inquiry)
--   Sales and order management -> Sales
--
-- This is a migration and not an edit to the front end because that is the
-- claim the terminology layer makes: renaming is a glossary change with no
-- code impact. Every one of these is a row in erp_ref.resource that an
-- organisation can already override for itself, so a shop that says
-- "Inventory" can have it back without a deployment.
--
-- Three rows had drifted from the front end's fallback, and the database wins
-- at runtime, so the screen said one thing and the code said another:
--
--   nav.master_data_item_supply   database "Product supply defaults", code "Item supply"
--   nav.logistics_release_areas   database "Marshalling areas",       code "Release areas and waves"
--   nav.administration_onboarding database "People and invitations",  code "Onboarding interview"
--
-- The first two go the database's way: "Item" and "Release area" are the words
-- the glossary avoids, so the code was wrong and its fallback is corrected in
-- the same commit.
--
-- The third goes the other way. /administration/onboarding is the interview
-- that turns answers about how the organisation works into a change set per
-- section; it has nothing to do with inviting people, which is what
-- Users and authorisations does. "People and invitations" was not a wording
-- choice, it was a mislabel, and it is corrected here rather than preserved
-- out of deference to whichever side happens to be the database.
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.resource set value = v.value
  from (values
    -- The modules, in the order the work reads.
    ('module.master_data',        'Common data'),
    ('nav.master_data',           'Common data'),
    ('module.planning',           'Planning'),
    ('module.procurement',        'Purchasing'),
    ('nav.procurement',           'Purchasing'),
    ('module.production',         'Manufacturing'),
    ('module.quality',            'Quality control'),
    ('module.inventory',          'Stock'),
    ('module.logistics',          'Despatch'),
    ('module.sales',              'Sales'),
    ('module.finance',            'Financials'),
    ('module.reporting',          'Reports and inquiries'),

    -- The screens under them, where X3 has a name people look for.
    ('nav.master_data_item_supply',    'Product-suppliers'),
    ('nav.master_data_classification', 'Categories and codes'),
    ('nav.administration_permissions', 'Users and authorisations'),
    ('nav.reporting_reproducibility',  'Report versions and runs'),
    ('nav.operations_jobs',            'Recurring tasks'),
    ('nav.governance',                 'Change requests'),

    -- A mislabel, not a wording choice: this screen is the interview, and
    -- inviting people is Users and authorisations.
    ('nav.administration_onboarding',  'Onboarding interview')
  ) as v(key, value)
 where erp_ref.resource.key = v.key and erp_ref.resource.locale = 'en';

-- A rename that matched nothing is a rename that did not happen, and the
-- screens would go on saying the old word with nothing to show for it.
do $$
declare v_missing text;
begin
  select string_agg(k, ', ' order by k) into v_missing
    from (values
      ('module.master_data'), ('nav.master_data'), ('module.planning'),
      ('module.procurement'), ('nav.procurement'), ('module.production'),
      ('module.quality'), ('module.inventory'), ('module.logistics'),
      ('module.sales'), ('module.finance'), ('module.reporting'),
      ('nav.master_data_item_supply'), ('nav.master_data_classification'),
      ('nav.administration_permissions'), ('nav.reporting_reproducibility'),
      ('nav.operations_jobs'), ('nav.governance'), ('nav.administration_onboarding')
    ) as t(k)
   where not exists (select 1 from erp_ref.resource r where r.key = t.k and r.locale = 'en');
  if v_missing is not null then
    raise exception 'ERPWARE_UNKNOWN_RESOURCE_KEY: nothing to rename for %', v_missing
      using errcode = 'P0001',
            hint = 'The navigation key changed name. Update this migration to the key the front end actually asks for.';
  end if;
end;
$$;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
