set lock_timeout = '30s';

-- =============================================================================
-- 20260923300000  The procurement screens say what the reseed does
-- -----------------------------------------------------------------------------
-- PR4's screens step. M2 to M4 (20260922380000, 20260923100000,
-- 20260923200000) changed what the procurement doors do; the screens now say
-- so, and these are the words they say it in:
--
--   * Both Convert forms move the order on as it is made (p_transition
--     'auto'). An order to the supplier and site the requisition named is
--     approved with it; the hints under both fields say that changing either
--     loses that approval and the order asks for its own.
--   * The requisition page's button says "Convert", not "Create the purchase
--     order": a requisition whose lines are all on orders already is only
--     marked Ordered, and no order is made.
--   * Approve pressed by an approver whose decision is not the last one needed
--     keeps their decision and leaves the document where it is. The document
--     page now says so instead of showing the unchanged state in silence.
--
-- The bill pickers offering only draft bills needs no words: it changes what
-- is listed, not what is said.
--
-- supabase/ci/screen_strings.sh refuses a ui() string with no en row, so a
-- tenant can rename each of these.
-- =============================================================================

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). ' || v.why
  from (values
    ('Convert',
     'The button on a requisition''s page that converts it. Not "Create": a requisition whose lines are all on orders already is only marked Ordered.'),
    ('The requisition''s supplier, or the default supplier every product on it is bought from. Change it and the order loses the requisition''s approval and asks for its own.',
     'The hint under the supplier on both Convert forms. An order is approved with its requisition only when it goes to the supplier the requisition named.'),
    ('The requisition''s site. Change it and the order loses the requisition''s approval and asks for its own.',
     'The hint under the site on both Convert forms, for the same reason.'),
    ('Your decision is recorded; it is still waiting on somebody else''s.',
     'Said on a document''s page when an approver''s press decided their task and another decision is still needed, so the document did not move.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

do $seeded$
declare
  v_missing text;
  v_n integer;
begin
  select count(*), string_agg(quote_literal(v.text), E'\n  ')
    into v_n, v_missing
    from (values
      ('Convert'),
      ('The requisition''s supplier, or the default supplier every product on it is bought from. Change it and the order loses the requisition''s approval and asks for its own.'),
      ('The requisition''s site. Change it and the order loses the requisition''s approval and asks for its own.'),
      ('Your decision is recorded; it is still waiting on somebody else''s.')
    ) as v(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(v.text) and r.locale = 'en');

  if v_n > 0 then
    raise exception E'CLOVEERP_SCREEN_STRINGS_NOT_SEEDED: % of the four words this migration adds have no en row:\n  %',
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
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
