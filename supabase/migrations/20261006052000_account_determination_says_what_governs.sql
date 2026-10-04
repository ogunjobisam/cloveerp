set lock_timeout = '30s';

-- =============================================================================
-- 20261006052000  Which accounts things post to says what governs
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-27). The screen
-- Which accounts things post to promised what the database does not do. It
-- said an unmatched posting is refused, that every posting would be refused
-- until a rule exists, that nothing can be determined until an accounting
-- code exists, and that a product without one cannot be posted. The
-- demonstration has no rule and no accounting code, and posts every day.
--
-- ── WHAT GOVERNS ─────────────────────────────────────────────────────────────
--
-- erp.posting_line_determination() asks the rules here without raising. With
-- no match it posts to the account the document's posting rule names (its
-- step 4); it refuses only a posting rule line whose account says
-- 'determined', and no posting rule shipped today says that. A product with
-- no accounting code matches no rule here (erp.determine_account answers
-- item_posting_class_missing), so it, too, takes the posting rule's account.
-- erp_test.determination_posts_suite proves it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. Four screen strings, rendered through ui() on
--      src/routes/finance/account-determination.tsx: the page's how it works,
--      the empty accounting codes and rules panels, and the products panel's
--      description, now say that a posting takes the account its posting
--      rule names unless a rule here says otherwise. On a screen a posting
--      rule is an "accounting rule" (erp_ref.vocabulary posting_rule, which
--      erp.assert_vocabulary_aligned holds every screen string to).
--
-- The four strings they replace keep their rows: a tenant's renaming of one
-- is not thrown away, and nothing renders them any more.
--
-- On production: four rows are added to erp_ref.resource. No function, table
-- or organisation's row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The words the screen says
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Which accounts things post to says what governs (20261006052000).'
  from (values
    ('A posting takes the account its accounting rule names, unless a rule here says otherwise. One rule gives the account and its analysis together, and nothing falls into a suspense account.'),
    ('No accounting codes yet, so every posting takes the account its accounting rule names.'),
    ('No rules yet, so every posting takes the account its accounting rule names.'),
    ('Products without an accounting code are listed first. They take the account their accounting rule names.')
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
