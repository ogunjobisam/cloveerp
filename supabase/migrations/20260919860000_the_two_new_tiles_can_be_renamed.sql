-- The two new tiles can be renamed.
--
-- 20260919850000 seeded every ui("…") literal the close and reconciliation
-- screens say, and missed the four strings that are not ui() literals at all:
-- a screen's own name and description in src/lib/modules.tsx, which the
-- launchpad and the navigation render through ui() after reading them as data.
--
-- That is the second of the four sources supabase/ci/screen_strings.sh
-- harvests, and the one a grep cannot see: by the time the string reaches ui()
-- it is a variable, so nothing in the file it is rendered from looks like a
-- screen string. The check found all four and named them; this is them.
--
-- The nav keys themselves (nav.finance_close, nav.finance_reconciliation) were
-- seeded in both locales by the previous migration and are a different thing:
-- a key the screen asks for by name. These are the words the tile declaration
-- carries directly, and a tenant renaming "Closing the month" expects both to
-- move.

set lock_timeout = '30s';

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Screen string declared as tile data in src/lib/modules.tsx: the name or the description of the period close checklist or the reconciliation screen.'
  from (values
    ('Closing the month'),
    ('Do the books tie'),
    ('The checklist that has to be true before the books are closed: every task, who did it, and what the close is waiting for.'),
    ('The trial balance, the ageings against their control accounts, the subledgers and the stock valuation — checked against the ledger now, for this organisation.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- Named rather than counted: a seed that quietly inserted three of four would
-- leave the fourth to the build, fifty minutes later.
do $seeded$
declare v_missing text;
begin
  select string_agg(w.text, ' | ') into v_missing
    from (values
      ('Closing the month'),
      ('Do the books tie'),
      ('The checklist that has to be true before the books are closed: every task, who did it, and what the close is waiting for.'),
      ('The trial balance, the ageings against their control accounts, the subledgers and the stock valuation — checked against the ledger now, for this organisation.')
    ) as w(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(w.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_TILE_STRING_UNSEEDED: % has no en resource row, so no tenant can rename it', v_missing
      using errcode = '23503',
            hint = 'erp_ref.ui_key() keys the row; insert it above rather than leaving it to supabase/ci/screen_strings.sh.';
  end if;
end
$seeded$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
