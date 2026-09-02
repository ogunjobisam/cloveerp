-- =============================================================================
-- Part 21: accessibility
--
-- Part 21 had no footprint: no audit, no statement, no keyboard or contrast
-- pass. This is the audit, as a register, and the statement, as a function
-- that reads it — so the statement can never say something the register does
-- not, and the register cannot be edited into a claim the build has not
-- checked.
--
-- erp_ref.accessibility_criterion holds every WCAG 2.2 Level A and AA success
-- criterion (55 of them, 4.1.1 having been withdrawn in 2.2) and says, for
-- each, whether Clove ERP meets it, how, and what the known exception is
-- where it does not. Two kinds of checking stand behind a "met":
--
--   automated — src/lib/accessibility.test.ts, run on every build. It
--   computes the contrast ratios from the design tokens in styles.css rather
--   than asserting them from memory, and sweeps the source for the patterns
--   that break a criterion silently: a control with no accessible name, a
--   field with no label, a header with no scope, a route with no title, an
--   outline removed and not replaced.
--
--   manual — the keyboard and screen-reader pass recorded here by date. The
--   things a build cannot see: focus order, whether the dialog returns focus
--   to what opened it, whether a status message is announced.
--
-- The pass that produced this register changed the product in three places
-- worth naming, because they are the reason the statement can claim what it
-- claims: muted text was 2.3:1 and is now 5.9:1; a keyboard user had no
-- visible focus and no way past the rail; a field's border was decoration.
--
-- What is honestly not met, or only partly, is in the register as such. A
-- statement that lists its exceptions is the accessibility statement Part 21
-- asks for; one that lists none is marketing.
-- =============================================================================

create table if not exists erp_ref.accessibility_criterion (
  criterion       text primary key,
  name            text not null,
  level           text not null check (level in ('A', 'AA')),
  principle       text not null
    check (principle in ('perceivable', 'operable', 'understandable', 'robust')),
  status          text not null
    check (status in ('met', 'partially_met', 'not_met', 'not_applicable')),
  -- What in the product satisfies it. Required for met and partially_met.
  how_met         text,
  -- What does not, or why it does not apply. Required for partially_met,
  -- not_met and not_applicable.
  known_exception text,
  checked_by      text not null check (checked_by in ('automated', 'manual', 'both', 'none')),
  reviewed_on     date not null,
  seq             smallint not null
);

comment on table erp_ref.accessibility_criterion is
  'Specification v1.2 Part 21. Every WCAG 2.2 A and AA success criterion, '
  'with whether Clove ERP meets it, how, what the known exception is, and '
  'which kind of checking stands behind the answer. The accessibility '
  'statement is erp.accessibility_statement() reading this; the build checks '
  'it with erp.assert_accessibility_register_sound() and '
  'src/lib/accessibility.test.ts.';

select erp_meta.register_table('erp_ref', 'accessibility_criterion', 'product_content',
  'Part 21. The WCAG 2.2 A/AA audit the accessibility statement is generated from.');

insert into erp_ref.accessibility_criterion
  (criterion, name, level, principle, status, how_met, known_exception, checked_by, reviewed_on, seq)
values
-- ── Perceivable ─────────────────────────────────────────────────────────────
('1.1.1', 'Non-text content', 'A', 'perceivable', 'met',
 'Icons are decorative and carry aria-hidden (lucide default); the brand mark is role=img with the product or organisation name; every <img> carries alt, which the build sweeps for.',
 null, 'both', '2026-09-02', 1),
('1.2.1', 'Audio-only and video-only (prerecorded)', 'A', 'perceivable', 'not_applicable',
 null, 'The product carries no audio or video.', 'manual', '2026-09-02', 2),
('1.2.2', 'Captions (prerecorded)', 'A', 'perceivable', 'not_applicable',
 null, 'The product carries no audio or video.', 'manual', '2026-09-02', 3),
('1.2.3', 'Audio description or media alternative (prerecorded)', 'A', 'perceivable', 'not_applicable',
 null, 'The product carries no audio or video.', 'manual', '2026-09-02', 4),
('1.2.4', 'Captions (live)', 'AA', 'perceivable', 'not_applicable',
 null, 'The product carries no live media.', 'manual', '2026-09-02', 5),
('1.2.5', 'Audio description (prerecorded)', 'AA', 'perceivable', 'not_applicable',
 null, 'The product carries no audio or video.', 'manual', '2026-09-02', 6),
('1.3.1', 'Info and relationships', 'A', 'perceivable', 'met',
 'Every field sits inside a <label> or names one; every table header carries scope=col; headings are real headings in order; navigation is a named <nav>; the build sweeps for the first three.',
 null, 'both', '2026-09-02', 7),
('1.3.2', 'Meaningful sequence', 'A', 'perceivable', 'met',
 'Reading order is document order on every breakpoint; the mobile layout moves the rail into a drawer rather than reordering content.',
 null, 'manual', '2026-09-02', 8),
('1.3.3', 'Sensory characteristics', 'A', 'perceivable', 'met',
 'Instructions name controls by their labels; nothing is referred to by shape, position or colour alone.',
 null, 'manual', '2026-09-02', 9),
('1.3.4', 'Orientation', 'AA', 'perceivable', 'met',
 'No orientation lock; the single breakpoint layout works in both.',
 null, 'manual', '2026-09-02', 10),
('1.3.5', 'Identify input purpose', 'AA', 'perceivable', 'partially_met',
 'The sign-in form carries autocomplete for username and current-password.',
 'The invitation form asks for an email address without an autocomplete token; action forms otherwise collect no personal data.',
 'manual', '2026-09-02', 11),
('1.4.1', 'Use of colour', 'A', 'perceivable', 'met',
 'Every status pill carries its word; the active navigation entry has an inset bar, a heavier weight and aria-current, not only a colour.',
 null, 'manual', '2026-09-02', 12),
('1.4.2', 'Audio control', 'A', 'perceivable', 'not_applicable',
 null, 'Nothing plays audio.', 'manual', '2026-09-02', 13),
('1.4.3', 'Contrast (minimum)', 'AA', 'perceivable', 'met',
 'Every text token clears 4.5:1 on the surfaces it is used on, computed from the oklch values in styles.css by the build. Muted ink was 2.3:1 and is now 5.9:1; the accent as text was 3.6:1 and is now 5.2:1.',
 null, 'automated', '2026-09-02', 14),
('1.4.4', 'Resize text', 'AA', 'perceivable', 'met',
 'Sizes are relative; nothing fixes a height on text; the viewport meta allows zoom.',
 null, 'manual', '2026-09-02', 15),
('1.4.5', 'Images of text', 'AA', 'perceivable', 'met',
 'The wordmark is text; the only raster is a tenant-supplied logo, which is the exception the criterion allows.',
 null, 'manual', '2026-09-02', 16),
('1.4.10', 'Reflow', 'AA', 'perceivable', 'met',
 'One breakpoint at 768px; below it the rail becomes a drawer and content takes the full width. Data tables scroll within their own container, which the criterion permits.',
 null, 'manual', '2026-09-02', 17),
('1.4.11', 'Non-text contrast', 'AA', 'perceivable', 'met',
 'The input border token clears 3:1 against both surfaces (it was 1.4:1 and shared the hairline token), and the focus ring is the accent at 5:1; the build computes both.',
 null, 'automated', '2026-09-02', 18),
('1.4.12', 'Text spacing', 'AA', 'perceivable', 'met',
 'No fixed heights on text containers; descriptions clamp by line count and offer a Show more control.',
 null, 'manual', '2026-09-02', 19),
('1.4.13', 'Content on hover or focus', 'AA', 'perceivable', 'met',
 'Menus and dialogs are Radix primitives: dismissible with Escape, persistent while hovered, and the trigger stays in the tab order. No custom tooltips.',
 null, 'manual', '2026-09-02', 20),
-- ── Operable ────────────────────────────────────────────────────────────────
('2.1.1', 'Keyboard', 'A', 'operable', 'met',
 'Every control is a native button, link, input or select, or a Radix primitive with keyboard handling; nothing responds to pointer events alone.',
 null, 'manual', '2026-09-02', 21),
('2.1.2', 'No keyboard trap', 'A', 'operable', 'met',
 'Dialogs and the drawer trap focus while open and release it on Escape or close, returning it to the trigger.',
 null, 'manual', '2026-09-02', 22),
('2.1.4', 'Character key shortcuts', 'A', 'operable', 'not_applicable',
 null, 'The product defines no single-character shortcuts.', 'manual', '2026-09-02', 23),
('2.2.1', 'Timing adjustable', 'A', 'operable', 'met',
 'The product sets no time limits; the session token refreshes automatically.',
 null, 'manual', '2026-09-02', 24),
('2.2.2', 'Pause, stop, hide', 'A', 'operable', 'partially_met',
 'Nothing moves, blinks or scrolls automatically.',
 'Data panels refetch every thirty seconds and replace their rows in place, with no control to pause the refresh. Rows do not move or animate when they change.',
 'manual', '2026-09-02', 25),
('2.3.1', 'Three flashes or below threshold', 'A', 'operable', 'met',
 'Nothing flashes.', null, 'manual', '2026-09-02', 26),
('2.4.1', 'Bypass blocks', 'A', 'operable', 'met',
 'A skip link is the first focusable element on every signed-in page and targets the main landmark; the build checks it is there.',
 null, 'both', '2026-09-02', 27),
('2.4.2', 'Page titled', 'A', 'operable', 'met',
 'Every route sets its own title; the build fails on one that does not.',
 null, 'automated', '2026-09-02', 28),
('2.4.3', 'Focus order', 'A', 'operable', 'met',
 'Focus follows document order; dialogs move focus in on open and back to the trigger on close.',
 null, 'manual', '2026-09-02', 29),
('2.4.4', 'Link purpose (in context)', 'A', 'operable', 'met',
 'Links carry their destination as text; tiles carry the screen name and a sentence.',
 null, 'manual', '2026-09-02', 30),
('2.4.5', 'Multiple ways', 'AA', 'operable', 'met',
 'The rail, the launchpad and the account menu each reach every screen the account may open.',
 null, 'manual', '2026-09-02', 31),
('2.4.6', 'Headings and labels', 'AA', 'operable', 'met',
 'Each screen has one h1 and a heading per panel; field labels say what the field is for, with a hint where that is not enough.',
 null, 'manual', '2026-09-02', 32),
('2.4.7', 'Focus visible', 'AA', 'operable', 'met',
 'One :focus-visible rule draws a two-pixel accent outline on everything that takes keyboard focus; the build checks the rule exists and that no component removes an outline without replacing it.',
 null, 'both', '2026-09-02', 33),
('2.4.11', 'Focus not obscured (minimum)', 'AA', 'operable', 'met',
 'scroll-padding-top matches the sticky header, so a control the browser scrolls to on focus lands below it.',
 null, 'both', '2026-09-02', 34),
('2.5.1', 'Pointer gestures', 'A', 'operable', 'met',
 'No multipoint or path-based gestures.', null, 'manual', '2026-09-02', 35),
('2.5.2', 'Pointer cancellation', 'A', 'operable', 'met',
 'Actions fire on click (up-event); nothing acts on pointer down.', null, 'manual', '2026-09-02', 36),
('2.5.3', 'Label in name', 'A', 'operable', 'met',
 'Accessible names are the visible labels; aria-label is used only where there is no visible text.',
 null, 'manual', '2026-09-02', 37),
('2.5.4', 'Motion actuation', 'A', 'operable', 'not_applicable',
 null, 'Nothing responds to device motion.', 'manual', '2026-09-02', 38),
('2.5.7', 'Dragging movements', 'AA', 'operable', 'not_applicable',
 null, 'Nothing is dragged.', 'manual', '2026-09-02', 39),
('2.5.8', 'Target size (minimum)', 'AA', 'operable', 'met',
 'Every control carries the shared 44px minimum height; menu items are 32px with spacing that clears the 24px minimum.',
 null, 'manual', '2026-09-02', 40),
-- ── Understandable ──────────────────────────────────────────────────────────
('3.1.1', 'Language of page', 'A', 'understandable', 'met',
 'The document declares lang=en; the build checks it.', null, 'automated', '2026-09-02', 41),
('3.1.2', 'Language of parts', 'AA', 'understandable', 'met',
 'Screen text resolves through one locale at a time; there are no passages in another language.',
 null, 'manual', '2026-09-02', 42),
('3.2.1', 'On focus', 'A', 'understandable', 'met',
 'Focusing a control changes nothing; a picker loads its options on focus without moving focus.',
 null, 'manual', '2026-09-02', 43),
('3.2.2', 'On input', 'A', 'understandable', 'met',
 'Changing the company or site filter re-scopes the data on the same screen; forms submit only on their button.',
 null, 'manual', '2026-09-02', 44),
('3.2.3', 'Consistent navigation', 'AA', 'understandable', 'met',
 'The rail and header are one component in one order on every screen.', null, 'manual', '2026-09-02', 45),
('3.2.4', 'Consistent identification', 'AA', 'understandable', 'met',
 'Refresh, Show more, Cancel and the action buttons are one component each, so the same thing is named the same way everywhere.',
 null, 'manual', '2026-09-02', 46),
('3.2.6', 'Consistent help', 'A', 'understandable', 'not_applicable',
 null, 'No help mechanism is offered yet. Part 22 adds contextual help; when it does, it sits in the header in the same place on every screen.',
 'manual', '2026-09-02', 47),
('3.3.1', 'Error identification', 'A', 'understandable', 'met',
 'A refusal is rendered as role=alert next to the form, in words, with the database''s text kept underneath for support.',
 null, 'manual', '2026-09-02', 48),
('3.3.2', 'Labels or instructions', 'A', 'understandable', 'met',
 'Every field has a label and, where the value is not obvious, a hint; required fields are marked to the browser.',
 null, 'both', '2026-09-02', 49),
('3.3.3', 'Error suggestion', 'AA', 'understandable', 'met',
 'Refusals teach: the friendly-error layer turns each refusal code into what happened and what to do next.',
 null, 'manual', '2026-09-02', 50),
('3.3.4', 'Error prevention (legal, financial, data)', 'AA', 'understandable', 'met',
 'Loads are previewed before they post; reversals, deletions and cutovers confirm first; promotions need a second person.',
 null, 'manual', '2026-09-02', 51),
('3.3.7', 'Redundant entry', 'A', 'understandable', 'met',
 'No process asks for the same information twice; the company and site scope is remembered per viewer.',
 null, 'manual', '2026-09-02', 52),
('3.3.8', 'Accessible authentication (minimum)', 'AA', 'understandable', 'met',
 'Password managers are allowed (autocomplete tokens), there is no puzzle or transcription, and a Google sign-in is offered as an alternative.',
 null, 'manual', '2026-09-02', 53),
-- ── Robust ──────────────────────────────────────────────────────────────────
('4.1.2', 'Name, role, value', 'A', 'robust', 'met',
 'Controls are native elements or Radix primitives with their roles and states; icon-only buttons carry aria-label; the build sweeps for a button or image with no name.',
 null, 'both', '2026-09-02', 54),
('4.1.3', 'Status messages', 'AA', 'robust', 'met',
 'Loading states are role=status, refusals role=alert, so both are announced without taking focus.',
 null, 'both', '2026-09-02', 55)
on conflict (criterion) do update set
  name = excluded.name, level = excluded.level, principle = excluded.principle,
  status = excluded.status, how_met = excluded.how_met,
  known_exception = excluded.known_exception, checked_by = excluded.checked_by,
  reviewed_on = excluded.reviewed_on, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.administration_accessibility', 'en', 'Accessibility', null,
   'Navigation label for the screen showing the accessibility statement: each WCAG 2.2 criterion, whether the product meets it, and the known exceptions.')
on conflict (key, locale) do nothing;

-- ── The register agrees with itself and with WCAG 2.2 ─────────────────────────

create or replace function erp.accessibility_register_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'the register does not hold every WCAG 2.2 A and AA criterion', 'count',
         format('%s row(s); WCAG 2.2 has 55 at A and AA', count(*))
    from erp_ref.accessibility_criterion
  having count(*) <> 55
  union all
  select 'criterion is not a WCAG identifier', c.criterion, c.name
    from erp_ref.accessibility_criterion c
   where c.criterion !~ '^[1-4]\.[0-9]+\.[0-9]+$'
  union all
  select 'principle does not match the criterion''s guideline', c.criterion,
         format('%s is under %s', c.criterion, c.principle)
    from erp_ref.accessibility_criterion c
   where c.principle <> case left(c.criterion, 1)
                          when '1' then 'perceivable' when '2' then 'operable'
                          when '3' then 'understandable' else 'robust' end
  union all
  select 'a criterion claimed as met says nothing about how', c.criterion, c.status
    from erp_ref.accessibility_criterion c
   where c.status in ('met', 'partially_met') and coalesce(c.how_met, '') = ''
  union all
  select 'a criterion not met names no exception', c.criterion, c.status
    from erp_ref.accessibility_criterion c
   where c.status in ('partially_met', 'not_met', 'not_applicable')
     and coalesce(c.known_exception, '') = ''
  union all
  select 'a criterion claimed as met has nothing checking it', c.criterion, c.status
    from erp_ref.accessibility_criterion c
   where c.status in ('met', 'partially_met') and c.checked_by = 'none'
  union all
  select 'a review is dated in the future', c.criterion, c.reviewed_on::text
    from erp_ref.accessibility_criterion c
   where c.reviewed_on > current_date
  union all
  select 'the navigation label has no base-locale resource', 'nav.administration_accessibility', ''
   where not exists (select 1 from erp_ref.resource r
                      where r.key = 'nav.administration_accessibility' and r.locale = 'en')
$$;

create or replace function erp.assert_accessibility_register_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text;
  v_met integer; v_partial integer; v_not integer; v_na integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.accessibility_register_report();

  if v_count > 0 then
    raise exception 'ERPWARE_ACCESSIBILITY_REGISTER_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  select count(*) filter (where status = 'met'),
         count(*) filter (where status = 'partially_met'),
         count(*) filter (where status = 'not_met'),
         count(*) filter (where status = 'not_applicable')
    into v_met, v_partial, v_not, v_na
    from erp_ref.accessibility_criterion;

  return format('accessibility: WCAG 2.2 A/AA — %s met, %s partially met, %s not met, %s not applicable',
                v_met, v_partial, v_not, v_na);
end;
$$;

comment on function erp.assert_accessibility_register_sound is
  'Fails where the WCAG 2.2 register is incomplete, misfiled, claims a '
  'criterion is met without saying how or what checks it, or leaves an '
  'exception unnamed.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('accessibility_register', 'Accessibility register sound', 'assertion', 'platform',
   'erp', 'assert_accessibility_register_sound', '', 'accessibility_register_report', '',
   'Every WCAG 2.2 A and AA criterion is in the register with a status, how it is met or what the exception is, and what checks it.',
   true, 64)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- ── The statement ─────────────────────────────────────────────────────────────

create or replace function erp.accessibility_statement()
returns jsonb
language sql
stable
set search_path = ''
as $$
  with c as (select * from erp_ref.accessibility_criterion)
  select jsonb_build_object(
    'product', 'Clove ERP',
    'standard', 'WCAG 2.2',
    'level_claimed', 'AA',
    -- Conformance is computed, not typed: partial while anything at A or AA
    -- is short of met.
    'conformance', case
      when exists (select 1 from c where c.status in ('partially_met', 'not_met'))
        then 'partially conforms'
      else 'conforms' end,
    'reviewed_on', (select max(c.reviewed_on) from c),
    'counts', (select jsonb_build_object(
        'met', count(*) filter (where c.status = 'met'),
        'partially_met', count(*) filter (where c.status = 'partially_met'),
        'not_met', count(*) filter (where c.status = 'not_met'),
        'not_applicable', count(*) filter (where c.status = 'not_applicable'),
        'total', count(*)) from c),
    'checked_by', jsonb_build_object(
        'automated', 'src/lib/accessibility.test.ts, run on every build: contrast from the design tokens, and source sweeps for unnamed controls, unlabelled fields, unscoped headers, untitled routes and removed outlines.',
        'manual', 'A keyboard and screen-reader pass on the shell, sign-in, a form dialog, a data table and the drawer, recorded per criterion by date.',
        'register', 'erp.assert_accessibility_register_sound() fails the build if a criterion is claimed without saying how or what checks it.'),
    'exceptions', (select coalesce(jsonb_agg(jsonb_build_object(
        'criterion', c.criterion, 'name', c.name, 'level', c.level,
        'status', c.status, 'exception', c.known_exception) order by c.seq), '[]'::jsonb)
        from c where c.status in ('partially_met', 'not_met')),
    'criteria', (select jsonb_agg(jsonb_build_object(
        'criterion', c.criterion, 'name', c.name, 'level', c.level,
        'principle', c.principle, 'status', c.status, 'how_met', c.how_met,
        'known_exception', c.known_exception, 'checked_by', c.checked_by,
        'reviewed_on', c.reviewed_on) order by c.seq) from c),
    'feedback', 'Report a barrier to your organisation''s administrator, who can raise it with the platform; support access into an organisation is audited and time-bounded.')
$$;

comment on function erp.accessibility_statement is
  'Part 21: the accessibility statement, generated from the register so it '
  'cannot claim what the register does not. Conformance is partial while any '
  'A or AA criterion is short of met, and the exceptions are listed.';

create or replace function public.erp_accessibility_statement()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  -- Product content, readable by every signed-in principal: a statement is
  -- for whoever is using the product, not for a permission.
  perform erp.require_tenant_id();
  return erp.accessibility_statement();
end;
$$;

-- Supabase carries DEFAULT PRIVILEGES on schema public that grant EXECUTE to
-- anon, so a new door is callable without signing in until it is revoked.
revoke all on function public.erp_accessibility_statement() from public, anon;
grant execute on function public.erp_accessibility_statement() to authenticated, service_role;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.accessibility_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r   record;
  a1  uuid := gen_random_uuid();
  res jsonb;
  v_ok boolean; v_msg text;
begin
  begin
    v_msg := erp.assert_accessibility_register_sound(); v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  return query select 'the register holds all 55 WCAG 2.2 A and AA criteria, each with its evidence',
    v_ok and v_msg like 'accessibility: WCAG 2.2 A/AA — % met, % partially met, 0 not met, % not applicable', v_msg;

  return query select 'every criterion is filed under the principle its number says',
    not exists (select 1 from erp_ref.accessibility_criterion c
                 where c.principle <> case left(c.criterion, 1)
                   when '1' then 'perceivable' when '2' then 'operable'
                   when '3' then 'understandable' else 'robust' end),
    'four principles, four leading digits';

  res := erp.accessibility_statement();
  return query select 'the statement is generated from the register and lists its exceptions rather than hiding them',
    res ->> 'conformance' = 'partially conforms'
    and (res -> 'counts' ->> 'total')::integer = 55
    and jsonb_array_length(res -> 'exceptions') = (select count(*) from erp_ref.accessibility_criterion c
                                                     where c.status in ('partially_met', 'not_met'))
    and jsonb_array_length(res -> 'criteria') = 55
    and res -> 'exceptions' @> '[{"criterion": "2.2.2"}]'::jsonb,
    format('%s; %s exception(s)', res ->> 'conformance', jsonb_array_length(res -> 'exceptions'));

  return query select 'a criterion claimed as met always says what checks it',
    not exists (select 1 from erp_ref.accessibility_criterion c
                 where c.status = 'met' and c.checked_by = 'none'),
    'automated, manual or both';

  -- The door needs a signed-in principal and nothing more.
  begin
    perform public.erp_accessibility_statement();
    v_ok := false; v_msg := 'the statement was read with no session';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_TENANT_CONTEXT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'the statement door needs a signed-in principal', v_ok, v_msg;

  select * into r from erp.provision_tenant(
    'zzacc', 'Accessibility', 'admin@zzacc.test', 'Accessibility Admin');
  insert into auth.users (id, email) values (a1, 'admin@zzacc.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_accessibility_statement();
  return query select 'and any signed-in principal may read it, without a permission',
    res ->> 'product' = 'Clove ERP' and res ->> 'standard' = 'WCAG 2.2',
    format('%s, %s, %s', res ->> 'product', res ->> 'standard', res ->> 'conformance');

  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id = a1;
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id)
    and not exists (select 1 from auth.users u where u.id = a1),
    'one organisation, gone';
end;
$$;

create or replace function erp_test.assert_accessibility_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _accessibility_result on commit drop as
    select * from erp_test.accessibility_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _accessibility_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_ACCESSIBILITY_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('accessibility: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_accessibility_register_sound();
select erp_test.assert_accessibility_suite();
