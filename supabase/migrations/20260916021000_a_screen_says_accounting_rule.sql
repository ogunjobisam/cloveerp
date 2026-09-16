-- A screen says accounting rule.
--
-- 20260916010000 registered CLOVEERP_POSTING_RULE_EMPTY with "A posting rule
-- that is in force and raises no lines." erp.assert_vocabulary_aligned()
-- refused it, and rightly: erp_ref.vocabulary holds posting_rule as an
-- internal term whose product word is "accounting rule", and Terminology §4's
-- rule is that an internal term never reaches a screen. A refusal is the most
-- screen-facing string the database has — it is what somebody reads at the
-- moment they are stopped — so it is the last place to use the schema's word.
--
-- The refusal is re-registered with the same meaning in the product's own
-- vocabulary. Its why and next action never used the internal term and are
-- restated unchanged, because erp.register_refusal writes the row and its
-- three resource keys together and a half-registration is how the register and
-- the dictionary drifted apart in the first place (20260912221000).
--
-- The code does not move. A code is what the client matches on, and the whole
-- point of the register is that the words can change without it.

select erp.register_refusal(
  'CLOVEERP_POSTING_RULE_EMPTY',
  'An accounting rule that is in force and raises no lines.',
  'A rule in force decides which accounts a document reaches and on which side. One that lists no lines would let a document post a journal with nothing in it, so the ledger would be silently short of what the document did.',
  'Give the rule at least one line to debit and one to credit, of equal value, then put it in force.');

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_vocabulary_aligned();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');

select erp.assert_every_posting_rule_raises_lines();
select erp_test.assert_posting_rules_raise_lines_suite();
