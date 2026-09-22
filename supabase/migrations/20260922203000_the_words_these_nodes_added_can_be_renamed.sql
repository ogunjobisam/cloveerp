set lock_timeout = '30s';

-- =============================================================================
-- 20260922203000  The words these nodes added can be renamed
-- -----------------------------------------------------------------------------
-- supabase/ci/screen_strings.sh refused this branch:
--
--   CLOVEERP_UNRENAMEABLE_SCREEN_STRINGS: 6 of 2493 have no en resource row,
--   so no tenant can rename them
--
-- Four of the six are C6's, the recount node (20260922130000), which put a
-- "Count it again" action on the stocktake screen and declared it in the
-- module register. Two are C1's, the supplier tax node (20260922170000), which
-- added the field a bill states its tax in.
--
-- The check is right and the omission was mine, twice. The terminology layer's
-- premise is that renaming is a glossary change with no code impact, and that
-- is only true of strings erp_ref.resource holds: a screen word with no row is
-- one no organisation can rename and one erp.terminology_alignment_report()
-- cannot see, so it shows no drift over exactly the words that are drifting.
--
-- ── WHY THE BUILD ONLY SAYS SO NOW ───────────────────────────────────────────
--
-- Nothing regressed here. This check runs after the catalogue, and the
-- catalogue has failed on every build of this branch until this one — first on
-- assert_no_state_side_doors, then twice on assert_invoice_tax_suite. The job
-- exited before reaching screen_strings.sh. Now that 331 of 331 checks pass,
-- the next thing in line is heard from for the first time.
--
-- Both nodes' migrations are pushed and immutable, so the rows are added here
-- rather than where the strings were written.
-- =============================================================================

-- The stocktake's recount action (20260922130000). The first two are declared
-- in src/lib/modules.tsx, where the module states its actions as data; the
-- third and fourth are the dialog on src/routes/inventory/audit.tsx, which
-- says the same thing at more length because it is said in front of somebody
-- about to do it.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). ' || v.why
  from (values
    ('Count it again',
     'The action on a refused stocktake, in the module register and on the dialog that runs it.'),
    ('Send a count the approver refused back to be counted, re-read against the records as they stand now.',
     'What the action does, as the stocktake screen states it beside the button.'),
    ('Send a count the approver refused back to be counted. The expected figure is re-read from the records as they stand now, so anything that moved through the place since the refusal is accounted for.',
     'The same thing at length, in the dialog, where the person is about to do it and the re-read is the part they need to know.'),
    ('Send it back to be counted',
     'The button that confirms the dialog.'),

    -- The supplier's tax on a bill (20260922170000).
    ('Tax the supplier charged',
     'The field a bill raised from a receipt states the supplier''s tax in, so the tax is stated before the ledger closes over it.'),
    ('The figure on their invoice. Leave empty if they charged none.',
     'The hint under that field. A supplier who charged nothing is a different fact from a supplier nobody asked.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

-- Six rows, and the build is refused again here rather than thirty minutes
-- later if the key function ever stops agreeing with the one the check calls.

do $seeded$
declare
  v_missing text;
  v_n integer;
begin
  select count(*), string_agg(quote_literal(v.text), E'\n  ')
    into v_n, v_missing
    from (values
      ('Count it again'),
      ('Send a count the approver refused back to be counted, re-read against the records as they stand now.'),
      ('Send a count the approver refused back to be counted. The expected figure is re-read from the records as they stand now, so anything that moved through the place since the refusal is accounted for.'),
      ('Send it back to be counted'),
      ('Tax the supplier charged'),
      ('The figure on their invoice. Leave empty if they charged none.')
    ) as v(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(v.text) and r.locale = 'en');

  if v_n > 0 then
    raise exception E'CLOVEERP_SCREEN_STRINGS_NOT_SEEDED: % of the six words this migration adds have no en row:\n  %',
      v_n, v_missing
      using hint = 'erp_ref.ui_key() decides the key. If it has changed, the rows this migration wrote are under the old one.';
  end if;
end
$seeded$;

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
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
