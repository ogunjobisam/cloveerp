set lock_timeout = '30s';

-- =============================================================================
-- 20261010130000  The seed says what it is, and runs twice
-- -----------------------------------------------------------------------------
-- Two Definition of Done cases the v1 gate (7 October) held as S2:
--
--   DAT-04 "Every posted document records who, when and from what source.
--   Expect: present on all documents created during the seeded month." Who
--   and when were there. The source was not: the build's seeded month is
--   written by supabase/ci/seed_demo.sql, and 20260919930000 left the seed
--   scripts declaring nothing, so every row of its trail read 'undeclared'.
--   That migration's reason was that the scripts run statement by statement
--   outside a transaction the product controls. seed_demo.sql does not: it
--   is one transaction, opened by its own begin, on the trusted build role.
--   It can declare at its first statement, and erp.authorise() leaves a
--   declaration alone.
--
--   DEM-01 "One command generates a full month of transactions in a clean
--   tenant. Expect: completes without manual keying, repeatable,
--   idempotent." The builders were idempotent; the script was not, because
--   it provisioned 'ci-demo' unconditionally and a second run was refused.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_ref.audit_source gains 'seed': a script that seeds a
--      demonstration from a trusted connection.
--   B. The register of entry points says the seed declares it, and where.
--      The demonstration builders a person runs from the Organisation screen
--      are a person working in the application, and record 'screen' through
--      erp.authorise(), which is what happened.
--   C. supabase/ci/seed_demo.sql (not a migration) declares 'seed' first,
--      finds the organisation on a second run instead of provisioning it,
--      and ends by refusing a document without who or when, an audit row
--      without a source, or a second run that built anything. The build runs
--      it twice.
--
-- Production: one reference row and one register row. Nothing else.
-- =============================================================================

insert into erp_ref.audit_source (code, name, description, is_current, seq)
values ('seed', 'A seed script',
        'A script that seeds a demonstration organisation from a trusted connection, such as the build''s '
        'seeded month. Nobody was looking at a screen; the script wrote it.',
        true, 50)
on conflict (code) do update
  set name = excluded.name, description = excluded.description,
      is_current = excluded.is_current, seq = excluded.seq;

update erp_meta.audit_source_entry_point
   set records = 'seed',
       declares = true,
       declared_at = 'supabase/ci/seed_demo.sql, through erp.declare_source(''seed'') as its transaction opens',
       note = 'The build''s seed script is one transaction on the trusted build role, so it declares itself as it '
              'begins and every row it writes says a seed script wrote it (20261010130000). The demonstration '
              'builders a person runs from the Organisation screen pass erp.authorise(), which records the screen.'
 where entry_point = 'seed and demonstration data';

do $declared$
begin
  if not exists (select 1 from erp_meta.audit_source_entry_point e
                  where e.entry_point = 'seed and demonstration data'
                    and e.records = 'seed' and e.declares) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the seed''s row in the entry point register is not where it was';
  end if;
end
$declared$;

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
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
