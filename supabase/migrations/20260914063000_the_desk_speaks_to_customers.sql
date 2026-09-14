-- The desk speaks to customers.
--
-- A user guide was written for the companies being onboarded, and the person
-- writing it found the desk still talking to the people who built it. Most of
-- what was found is the desk's own business and changed in the desk: Home no
-- longer offers demo data to somebody who cannot make it, a missing
-- permission is named the way a person reads it, the specification's coverage
-- figures are shown to platform operators and owners only, amounts are typed
-- in pounds and pence, the stock forecast's second button says what the New
-- document form says, and six forms that asked for an id or a line of JSON
-- now ask a question or offer a list.
--
-- Two things the desk says are held here, and both are words:
--
--   1. One name for people and access. The menu said "Users and
--      authorisations", the page said "Permissions", the help said "People and
--      permissions", and a refusal pointed at "the Permissions screen". The
--      menu's word is nav.administration_permissions, and the database's row
--      wins at runtime over the desk's fallback, so the rename is a row. The
--      refusal a missing grant raises names the screen by the same name. The
--      route stays /administration/permissions; only the words move.
--
--   2. Every string the desk now shows has a row it can be renamed by.
--      supabase/ci/screen_strings.sh harvests the screens and refuses a string
--      with no row keyed erp_ref.ui_key(text). The strings a form stopped
--      showing keep their rows: a row nobody asks for is harmless, and an
--      organisation that renamed one keeps what it wrote.
--
-- Nothing here creates, changes or grants a function.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. One name for people and access
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.resource
   set value = 'People and permissions'
 where key = 'nav.administration_permissions'
   and locale = 'en';

-- The refusal is re-registered through the register's own writer, which
-- writes the row and its mirrored resource keys together, so the two cannot
-- say different things. What it refused and why are restated as
-- 20260904630000 registered them; only the next action changes.
select erp.register_refusal('CLOVEERP_PERMISSION_DENIED',
  'An action the account holds no permission for.',
  'Absence of a grant is a refusal, not a default.',
  'An administrator can grant the missing permission under People and permissions.');

-- A rename that matched nothing is a rename that did not happen, and the
-- screens would go on saying the old words with nothing to show for it.
do $one_name$
declare v_missing text;
begin
  select string_agg(t.k, ', ' order by t.k) into v_missing
    from (values
      ('nav.administration_permissions', 'People and permissions'),
      (erp_ref.refusal_key('CLOVEERP_PERMISSION_DENIED', 'next_action'),
       'An administrator can grant the missing permission under People and permissions.')
    ) as t(k, v)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = t.k and r.locale = 'en' and r.value = t.v);
  if v_missing is null and not exists (
       select 1 from erp_ref.refusal f
        where f.code = 'CLOVEERP_PERMISSION_DENIED'
          and f.next_action = 'An administrator can grant the missing permission under People and permissions.') then
    v_missing := 'erp_ref.refusal CLOVEERP_PERMISSION_DENIED';
  end if;
  if v_missing is not null then
    raise exception 'CLOVEERP_RENAME_SHORT: nothing was renamed for %', v_missing
      using hint = 'The key the desk asks for changed name, or row security refused the write. Point this migration at the key the desk reads now.';
  end if;
end
$one_name$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    -- The menu, the page and the help, under one name.
    ('People and permissions',
     'The name of the screen where people are invited and given roles.'),
    -- Reports and inquiries, whose tile no longer mentions the specification.
    ('Data quality and duplicate business partners, read from operational tables.',
     'The Reports and inquiries tile, once specification coverage became a platform figure.'),
    -- The order dialog on the stock forecast, in the words of the New document form.
    ('Create and move on',
     'The second button on a form that raises a document and moves it forward.'),
    -- Amounts in pounds and pence.
    ('Leave empty to take the order line''s price.',
     'Invoice against an order: the unit price, now typed in pounds and pence.'),
    ('What the carrier charges for this shipment.',
     'Book a shipment: the cost, now typed in pounds and pence.'),
    -- Match a settlement line: chosen, not typed.
    ('Statement line',
     'Match a settlement line: the line, chosen from the statement chosen above it.'),
    ('Receivable',
     'Match a settlement line: the receivable, chosen from the candidates of the line.'),
    ('The open receivables this line could settle. A line already matched has none.',
     'Match a settlement line: what the receivable picker offers.'),
    -- Adjust a forecast bucket: chosen, not typed.
    ('Bucket',
     'Adjust a forecast bucket: the bucket, chosen from the forecast version chosen above it.'),
    ('Product, site, the week or month it starts, and the figure it holds now.',
     'Adjust a forecast bucket: what each bucket in the picker shows.'),
    -- Run a scenario: three questions instead of a line of JSON.
    ('Demand multiplier',
     'Run a scenario: the demand assumption.'),
    ('Every demand times this: 1.5 is half as much again. Leave empty to plan demand as it stands.',
     'Run a scenario: the demand assumption explained.'),
    ('Lead time change, in days',
     'Run a scenario: the lead time assumption.'),
    ('Days added to every lead time, or taken off with a minus. Leave empty for none.',
     'Run a scenario: the lead time assumption explained.'),
    ('Reorder point multiplier',
     'Run a scenario: the reorder point assumption.'),
    ('Every reorder point times this. Leave empty to keep them as they are.',
     'Run a scenario: the reorder point assumption explained.'),
    -- Propose how stock is chosen: four questions instead of a line of JSON.
    ('Stock taken first',
     'Propose how stock is chosen: the order stock is taken in.'),
    ('Stock with an expiry date',
     'Propose how stock is chosen: the order expiry-controlled stock is taken in.'),
    ('Leave unchosen to take it in the same order as everything else.',
     'Propose how stock is chosen: the expiry-controlled order explained.'),
    ('First in, first out',
     'Propose how stock is chosen: FIFO.'),
    ('First to expire, first out',
     'Propose how stock is chosen: FEFO.'),
    ('Last in, first out',
     'Propose how stock is chosen: LIFO.'),
    ('One batch per order',
     'Propose how stock is chosen: whether an order may be filled from several batches.'),
    ('Yes leaves an order short rather than filling it from two batches.',
     'Propose how stock is chosen: one batch per order explained.'),
    ('Nearest location first',
     'Propose how stock is chosen: whether the nearest location decides between equal stock.'),
    ('Between stock the rule above cannot separate, take the nearest.',
     'Propose how stock is chosen: nearest location first explained.'),
    -- Call off a blanket order: lines chosen from the blanket, not typed.
    ('Blanket line',
     'Call off a blanket order: a line of the blanket order chosen above.'),
    ('The lines of the blanket order chosen above being called off, and how much of each.',
     'Call off a blanket order: the line editor explained.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
