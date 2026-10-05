set lock_timeout = '30s';

-- =============================================================================
-- 20261007082000  The words a wrapped line hid can be renamed
-- -----------------------------------------------------------------------------
-- Found building the journey fixes, 4 October (J-172).
-- supabase/ci/screen_strings.sh read ui("…") with a grep, one line at a time.
-- Prettier wraps a long call, putting the string on the line below ui(, and
-- a wrapped call was never read: its words reached the screen with nothing
-- checking they had the row a tenant renames them by. On the day this was
-- found 183 strings were wrapped that way, and 41 of them had no row, across
-- thirteen screens: Organisation and approval routing, Which accounts things
-- post to, Categories and codes, Warehouse layout, Stock audit, Stock
-- forecast, Notifications and others.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. screen_strings.sh reads a ui( call across lines (this change, outside
--      the migrations), and src/lib/screen-strings.test.ts holds it to that.
--   B. The 41 strings it then found without a row are given their en row,
--      keyed by erp_ref.ui_key(text) as every screen string is. The words are
--      the screens' own, character for character; none is reworded. No German
--      row is asked for: the German coverage check reads the reference tables'
--      name keys, not screen strings.
--
-- On production: 41 rows are added to erp_ref.resource where they are not
-- there already. No row of any organisation is changed.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui() in a call prettier wraps over lines, which the screen strings check '
       'did not read until 20261007082000 (J-172).'
  from (values
    ('A business partner class separates, for example, export from domestic settlement.'),
    ('A receipt posts into a receiving location and a despatch picks from storage, so a site needs at least one of each before goods can move.'),
    ('Cover is followed at resolution time, up to three hops, and never back to the person who raised the request.'),
    ('Every active place at every site, whether or not anything stands in it, with the last count against it.'),
    ('Every departure from the matrix, with the reason given and the person who gave it.'),
    ('Every place at every site, with what sits above it, what it holds, and what is standing in it now.'),
    ('Every stock movement and every document that touches goods names one of these. A site belongs to a legal entity, which is what decides the ledger it posts to.'),
    ('No axes yet. Define one under Actions above; until one exists, products carry no structured meaning.'),
    ('No channel is configured, so only in-app delivery works. Add one under Actions above.'),
    ('No codes have been composed yet. A code is composed when a product is created against a template.'),
    ('No departments are configured yet. Create one under Actions above; approvals route by department before they route by anything else.'),
    ('No locations to audit yet. Add locations under Warehouse layout, and receive stock into them, and each one is listed here with its balance.'),
    ('No locations yet. Add one above — until a site has a goods-in place and somewhere to store, nothing can be received.'),
    ('No locations yet. Add one under Actions above — until then, goods receipts cannot be posted at this site.'),
    ('No overrides have been recorded. Every posting so far has followed the matrix above.'),
    ('No route is defined, so no event reaches anybody. Define one under Actions above.'),
    ('No sites yet. Add one under Actions above — until then, purchase orders, receipts and despatches cannot be raised.'),
    ('No stock standing anywhere and no counts raised. Receive a purchase order and put it away, and the lines appear here.'),
    ('No storage rules yet. Goods are still put away and picked — just to whichever open place comes first, rather than where you would have put them.'),
    ('No templates yet. Product codes would then be typed by hand rather than composed from the classification.'),
    ('No values yet. A value belongs to an axis, so define an axis first and add its values under Actions above.'),
    ('No waves have been opened. Open one under Actions above and its lines are picked together.'),
    ('Nobody has been assigned to a department yet, so nothing routes by department. Assign somebody under Actions above.'),
    ('Nobody is covering for anybody. Record cover under Actions above before somebody is away, not after.'),
    ('Nobody is subscribed to a report. Subscribe to one under Actions above and it is produced on a cadence and delivered.'),
    ('Nothing has been routed yet. A decision is stamped here the first time a request meets an approval band.'),
    ('Nothing posted to income or expense in this period. Post a sales invoice or a supplier bill and it appears here.'),
    ('Nothing to forecast yet. A product needs stock, a movement out, or a purchase order against it before there is anything to measure.'),
    ('Pick a wave to see exactly what is short and why before printing is attempted, rather than after it is refused.'),
    ('Products whose classification has moved on from the one their code was composed from. Reported, never silently recoded.'),
    ('Rank one is used unless a site-specific row overrides it. An unapproved row is never resolved.'),
    ('Suggested from the reorder point, what is already on order and the order multiple.'),
    ('The accounting vocabulary, and how many products or business partners currently carry each class.'),
    ('The same audit one line deeper: which product the quantity is, what it costs, and what the last count expected against what it found. Value in a bin is its share of the product''s valuation at that site, not a separate cost.'),
    ('The supplier, the site and the product come from this line. Only the quantity and the date you need it by are left to confirm.'),
    ('This account does not hold the permission the price book needs, so there is nothing to show here.'),
    ('Transaction type, posting classes and place on the left; the account and its analysis on the right.'),
    ('What each area serves, how it replenishes, and what is sitting in it now.'),
    ('What put-away, replenishment and picking read. With no rule at a site, put-away falls back to the first open bulk location and picking to the nearest pick face.'),
    ('What this organisation has configured. A message routed to a kind with no enabled channel fails with its reason and is delivered in-app instead, so nothing addressed to somebody is lost.'),
    ('Where a message goes when it is not in-app: an email sender, or a webhook that posts to a chat service. A webhook names its URL here and its credential as a reference, never the credential itself.')
  ) as v(text)
on conflict (key, locale) do nothing;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
