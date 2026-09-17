set lock_timeout = '30s';

-- =============================================================================
-- 20260916590000  Settings that decide something
-- -----------------------------------------------------------------------------
-- 20260916430000 built the check that finds a control writing into the dark and
-- registered thirty-eight columns it found. Nineteen of those are deliberate.
-- Nineteen are defects whose rationale says so. This file closes three of them,
-- each in a different subsystem, sharing nothing but the shape: somebody was
-- offered a setting and the setting decided nothing.
--
--   A. erp.code_template.entity_id — a product code pattern can be scoped to
--      one company, and nothing asked which company it was for.
--   B. erp.job.max_silence_seconds — how long a job may go unheard from.
--   C. erp.printer.default_stock — the label stock loaded in the tray.
--
-- And a fourth the first attempt uncovered, described under D below.
--
-- erp.change_set_item.effective_from stays registered. Its rationale is
-- corrected rather than removed, and section 6 says why and what honouring it
-- would take.
--
-- ── WHY THIS IS NOT 20260916530000 ───────────────────────────────────────────
--
-- A first version under that number was refused by its own last assertion, and
-- the reason is worth keeping because it is the check being better than the
-- person who wrote it.
--
-- erp.code_template.item_classes — "Only for product classes", ticked on the
-- coding screen — was counted as read, and the only thing reading it was an
-- accident. erp.routine_decided_names() treats every name inside a 200-character
-- window after an `order by` as read, which its own comment says is deliberate
-- and errs towards READ. In public.erp_code_templates() the words
-- `'item_classes'` sat at character 199 of that window. Rewriting the door to
-- carry the company pushed them to 213, and a column nothing had ever consulted
-- stopped being read.
--
-- So the column was never read, and closing three write-only settings revealed
-- a fourth. It is closed here rather than registered, in section D, because
-- registering it would be writing a defect down as a decision — which
-- 20260916430000 exists to stop.
--
-- The 530000 file reached no environment and is replaced rather than edited.
--
-- ── A. A code pattern belongs to a company, and versioning ignored that ───────
--
-- erp.code_template.entity_id says which company a product code pattern is for.
-- It is written on insert and on update, carried in the export, carried in the
-- change set, and read by nothing that chooses anything.
--
-- Underneath it is a worse one, found by reading the writer rather than the
-- reader. erp.upsert_code_template() resolves the template it is about to amend
-- with
--
--     where t.tenant_id = v_tenant and t.code = upper(p_code)
--     order by t.version desc limit 1
--
-- and nothing else. The company is written and never looked at. So an
-- organisation with two companies, each with its own ITEM pattern, has one
-- pattern: saving the second company's finds the first company's, and either
-- overwrites it or — once the first has actually issued codes — archives it and
-- raises a version of it. The second company's segments then compose the first
-- company's codes, and the first company's screen shows a pattern it never
-- agreed to. Nothing refuses, nothing warns, and the audit trail reads as an
-- ordinary amendment.
--
-- That is the same defect 20260906080000 fixed for posting rules, in the same
-- words: "the promoter supersedes rules within a company rather than across all
-- of them". It is fixed here the same way, with `is not distinct from` rather
-- than `=` so that a pattern meant for every company keeps finding itself.
--
-- Scoping the lookup means two companies may hold the same code, which the
-- table's own unique constraint forbade: (tenant_id, code, version). It is
-- widened to (tenant_id, code, entity_id, version) with NULLS NOT DISTINCT, so
-- that "for every company" is one scope rather than a hole in the constraint.
-- Two things that keyed a template by code alone follow it:
--
--   * the promoter's `remove` arm, which retired every company's template of
--     that code, and now retires the one in the change set's own company;
--   * the configuration manifest, whose object key was the template's code, so
--     an export of two companies' ITEM patterns produced two items with the
--     same key and the second quietly replaced the first. The key is now the
--     company's code and the template's, and the "latest version" filter is per
--     company rather than per code.
--
-- And the read: public.erp_code_templates() now says which company each pattern
-- belongs to and puts a company's own ahead of the one that applies to every
-- company, so the list somebody picks from can be told apart. The screen shows
-- the column and offers the company when a pattern is written. Before this, a
-- pattern could only be scoped to a company by a change set or an import, and
-- no screen anywhere showed that it had been.
--
-- ── B. A job that stops running stops running quietly ────────────────────────
--
-- This one was half-built, and the half that was missing is the half a person
-- would notice.
--
-- erp.job.max_silence_seconds IS consulted: erp.job_silence_tolerance(erp.job)
-- prefers it over the tolerance derived from the schedule, erp.silent_jobs()
-- filters on the result, and erp.report_silent_jobs() raises job.silenced once a
-- day per job so a notification route can carry it. A disabled job, a manual
-- job and a job inside an outage window are all left alone, which is right.
--
-- Two things were wrong with that.
--
-- The first is that no route carried it. job.silenced has been a registered
-- event type since 20260906100000 and no organisation has ever had a route for
-- it, so the dead-man's switch has been raising an event into an empty room.
-- 20260913121000 built exactly the thing that fixes this — product routes every
-- organisation has without configuring one, in erp_ref.notification_route_default
-- — and job_failed is already one of them. job_silenced joins it: to the
-- administrators, by email, mandatory, linking to the jobs screen. An
-- organisation that wants it off writes an inactive route of that code, which is
-- how every product route is switched off.
--
-- The second is why the check could not see the read, and it is worth saying
-- because it is the documented cost of a rule over text. erp.silent_jobs() hands
-- the whole job row to erp.job_silence_tolerance(erp.job), and that function's
-- body names p_job.max_silence_seconds without naming erp.job at all. The column
-- is read; no body both names the table and names the column. 20260916430000's
-- header says this in advance — "a row passed whole into another routine that
-- decides on one field, without that field ever being named, reads as unread.
-- Nothing in this schema does that today" — and it was wrong about the last
-- sentence. Rather than register the exception, the budget is named where the
-- rows are chosen: erp.silent_jobs() now says outright that an explicit budget
-- wins and falls back to the derived tolerance. The behaviour is unchanged and
-- the reason a job was called silent is now legible at the place it is decided.
--
-- ── C. A label renders at its own size and never asks what is in the tray ────
--
-- §15.3 says "label stock and resolution are properties of the printer, not the
-- template". The resolution is: erp.render_label() scales every render to
-- pr.dots_per_inch. The stock is not: erp.compose_zpl() is handed the template's
-- own page size, and erp.printer.default_stock — the stock loaded in the tray,
-- typed in on the output screen under "Default stock" — is read by nothing. A
-- hundred by a hundred and fifty millimetre label goes to a printer loaded with
-- something else, prints across the gap between two labels, and the barcode does
-- not scan.
--
-- What happens on a mismatch, argued rather than assumed. Three options:
--
--   1. Print anyway. This is what happens today and it is the one option the
--      check's own words rule out: "silently printing the wrong size is not"
--      defensible.
--   2. Print and record a warning. Defensible, and it is what a queue with a
--      human operator beside it would want. It needs somewhere to record the
--      warning — the render, the delivery or the request — and a person who
--      reads it afterwards. The label is already printed by then.
--   3. Refuse.
--
-- Refuse. Three reasons. The label subsystem already refuses rather than
-- degrades everywhere else it can tell: a template version whose decode check
-- failed cannot be promoted, a printer that does not speak ZPL is refused rather
-- than approximated, and a label sent to a document printer is refused. A label
-- printed on the wrong stock is not a degraded label, it is waste plus a barcode
-- nobody can scan, and the second is worse than the first because it is
-- discovered at the receiving end. And a refusal is met by the person standing
-- at the printer, who is the one person who can fix it in ten seconds by loading
-- the right roll.
--
-- The comparison is deliberately narrow, because default_stock is free text and
-- always was: §15.3 said a label printer's stock "is not something this product
-- should have opinions about". erp.label_stock_size() reads a width and a height
-- out of a string — 100x150, 100 x 150 mm, 100x150mm — and returns nothing at
-- all for anything else. A4, "Zebra Z-Select", an empty field: nothing is
-- compared and the render goes through exactly as it does today. Only when BOTH
-- the printer and the template state a size, and the two disagree, is the render
-- refused. A size stated without a unit is read in millimetres, which is the
-- unit the template's page size already uses.
--
-- ── D. A code pattern says which products it is for, and nothing asked ───────
--
-- erp.code_template.item_classes is the list of product classes a pattern
-- applies to — "Tick every class this applies to. None ticked applies to every
-- product." It is offered on the coding screen, written by the door, carried in
-- the export and in the change set, and consulted by nothing: a product of any
-- class could always be created against any pattern, including one ticked for
-- one class alone.
--
-- public.erp_create_classified_item() now asks. A pattern that names no class
-- still applies to every product, exactly as the words under the field say. A
-- pattern that names classes and does not name this product's is refused,
-- before the sequence is consumed, so a refusal costs no number.
--
-- ── What is NOT changed ──────────────────────────────────────────────────────
--
--   * erp.compose_code() still takes a template id and composes from it. The
--     company is resolved where the template is chosen, not where the code is
--     built.
--   * The onboarding interview still reads the latest ITEM pattern by code to
--     keep its name and casing. It also carries that pattern's company into the
--     change set, so the scoped lookup finds the same row it always did.
--   * erp.job_silence_tolerance(erp.job) keeps its signature and its fallbacks.
--     Nothing about which jobs are silent changes.
--   * A printer whose stock is blank, or stated in words, prints as before.
--
-- Proof: erp_test.settings_that_decide_suite() (11 cases, wrapper pinned), and
-- the three rows removed from erp_meta.write_only_column, which the build
-- refuses to hold once something reads the column.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A. A code pattern belongs to a company
-- ═════════════════════════════════════════════════════════════════════════════

-- ── 1.1 The constraint that made one pattern per code per organisation ───────
--
-- Found by column set rather than by name: the constraint was declared inline
-- in a create table, so its name is whatever PostgreSQL generated on the day.

do $ct_unique$
declare v_name text;
begin
  select c.conname into v_name
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_class r on r.oid = c.conrelid
    join pg_catalog.pg_namespace n on n.oid = r.relnamespace
   where n.nspname = 'erp' and r.relname = 'code_template' and c.contype = 'u'
     and (select array_agg(a.attname::text order by a.attname)
            from unnest(c.conkey) k
            join pg_catalog.pg_attribute a
              on a.attrelid = c.conrelid and a.attnum = k)
         = array['code', 'tenant_id', 'version'];

  if v_name is not null then
    execute format('alter table erp.code_template drop constraint %I', v_name);
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint c
      join pg_catalog.pg_class r on r.oid = c.conrelid
      join pg_catalog.pg_namespace n on n.oid = r.relnamespace
     where n.nspname = 'erp' and r.relname = 'code_template'
       and c.conname = 'code_template_code_version_per_company')
  then
    -- NULLS NOT DISTINCT so that "every company" is one scope. Without it, an
    -- organisation could hold any number of unscoped patterns of the same code
    -- and version, which is the hole the old constraint did not have.
    alter table erp.code_template
      add constraint code_template_code_version_per_company
      unique nulls not distinct (tenant_id, code, entity_id, version);
  end if;
end
$ct_unique$;

comment on column erp.code_template.entity_id is
  'The company this product code pattern is for, or nothing for every company. '
  'erp.upsert_code_template() amends the pattern of that code IN THAT COMPANY, '
  'the promoter retires the one in the change set''s own company, and '
  'erp_code_templates() shows which company each belongs to and offers a '
  'company''s own first.';

-- ── 1.2 The writer resolves the template within its company ──────────────────

do $ct_upsert$
declare
  v_def text := pg_catalog.pg_get_functiondef(
    'erp.upsert_code_template(text,text,jsonb,text,text,uuid)'::regprocedure);
  v_old text := E'  select * into v_latest from erp.code_template t\n'
             || E'   where t.tenant_id = v_tenant and t.code = upper(p_code)\n'
             || E'   order by t.version desc limit 1;';
  v_new text := E'  select * into v_latest from erp.code_template t\n'
             || E'   where t.tenant_id = v_tenant and t.code = upper(p_code)\n'
             || E'     and t.entity_id is not distinct from p_entity_id\n'
             || E'   order by t.version desc limit 1;';
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception
      'CLOVEERP_TEMPLATE_WRITER_UNRECOGNISED: erp.upsert_code_template() does not resolve the template with the text this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and anchor on what is there now.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$ct_upsert$;

comment on function erp.upsert_code_template(text, text, jsonb, text, text, uuid) is
  'Writes a product code pattern, amending the one of that code in that company '
  'and raising a new version of it once it has issued codes. A pattern for every '
  'company and a pattern for one company are different patterns, which is why '
  'the company is matched with `is not distinct from` rather than `=`.';

-- ── 1.3 The promoter retires within the company it is promoting into ─────────

do $ct_promoter$
declare
  v_def text := pg_catalog.pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_old text := E'        update erp.code_template ct set status = ''inactive'', updated_at = now()\n'
             || E'         where ct.tenant_id = v_tenant and ct.code = upper(p ->> ''code'');';
  v_new text := E'        update erp.code_template ct set status = ''inactive'', updated_at = now()\n'
             || E'         where ct.tenant_id = v_tenant and ct.code = upper(p ->> ''code'')\n'
             || E'           and ct.entity_id is not distinct from v_entity;';
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception
      'CLOVEERP_PROMOTER_UNRECOGNISED: the code_template arm of erp.apply_change_set_item() is not the text this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and anchor on what is there now.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$ct_promoter$;

-- ── 1.4 The manifest keys a pattern by its company and its code ──────────────

do $ct_manifest$
declare
  v_def text := pg_catalog.pg_get_functiondef('erp.configuration_manifest(text[])'::regprocedure);
  v_ka  text := E'    select ''code_template'',\n'
             || E'           ct.code,';
  v_kb  text := E'    select ''code_template'',\n'
             || E'           coalesce(e.code || ''|'', '''') || ct.code,';
  v_va  text := E'       and ct.version = (select max(c2.version) from erp.code_template c2\n'
             || E'                          where c2.tenant_id = ct.tenant_id and c2.code = ct.code)';
  v_vb  text := E'       and ct.version = (select max(c2.version) from erp.code_template c2\n'
             || E'                          where c2.tenant_id = ct.tenant_id and c2.code = ct.code\n'
             || E'                            and c2.entity_id is not distinct from ct.entity_id)';
begin
  if (length(v_def) - length(replace(v_def, v_ka, ''))) / length(v_ka) <> 1
     or (length(v_def) - length(replace(v_def, v_va, ''))) / length(v_va) <> 1 then
    raise exception
      'CLOVEERP_MANIFEST_UNRECOGNISED: the code_template arm of erp.configuration_manifest() is not the text this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and anchor on what is there now.';
  end if;
  v_def := replace(v_def, v_ka, v_kb);
  v_def := replace(v_def, v_va, v_vb);
  execute v_def;
end
$ct_manifest$;

-- ── 1.5 The list says which company, and offers a company's own first ────────
--
-- Re-emitted rather than patched, which is only safe because nothing has ever
-- patched it: the guard below refuses if that has stopped being true.

do $ct_door$
declare
  v_def text := pg_catalog.pg_get_functiondef('public.erp_code_templates()'::regprocedure);
begin
  if position('''template_id'', t.id, ''code'', t.code, ''name'', t.name, ''version'', t.version,' in v_def) = 0
     or position('entity' in v_def) > 0 then
    raise exception
      'CLOVEERP_TEMPLATE_DOOR_UNRECOGNISED: public.erp_code_templates() is not the body this migration re-emits'
      using hint = 'Something has amended the door since it was written. Patch the live body instead of replacing it.';
  end if;
end
$ct_door$;

create or replace function public.erp_code_templates()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('master_data.read');
  -- scope_rank orders a company's own pattern ahead of the one that applies to
  -- every company, so the list somebody picks from offers the nearer of the two
  -- first. The company is carried as a code and never as a word: which company
  -- a pattern belongs to is data, what to call the absence of one is a screen
  -- string.
  select coalesce(jsonb_agg(x order by x->>'code', x->>'scope_rank', x->>'version'),
                  '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'template_id', t.id, 'code', t.code, 'name', t.name, 'version', t.version,
      'item_classes', coalesce(to_jsonb(t.item_classes), 'null'::jsonb),
      'segments', t.segments, 'casing', t.casing, 'next_value', t.next_value,
      'entity_id', t.entity_id,
      'entity_code', e.code,
      'scope_rank', case when t.entity_id is null then '1' else '0' end,
      'valid_from', t.valid_from, 'valid_to', t.valid_to, 'status', t.status) as x
      from erp.code_template t
      left join erp.entity e
        on e.tenant_id = t.tenant_id and e.id = t.entity_id
     where t.tenant_id = erp.current_tenant_id()) q;
  return v_out;
end;
$$;

comment on function public.erp_code_templates() is
  'Every product code pattern the organisation holds, with the company each is '
  'scoped to and a company''s own ahead of the pattern that applies to every '
  'company. Two patterns of the same code in different companies are two rows, '
  'which is what they have always been in the table and never been on a screen.';

-- ── 1.6 D. A pattern ticked for one kind of product is only for that kind ────

do $ct_classes$
declare
  v_def text := pg_catalog.pg_get_functiondef('public.erp_create_classified_item'::regproc);
  v_da  text := E'  v_missing  text[];\n'
             || E'  r          record;';
  v_db  text := E'  v_missing  text[];\n'
             || E'  v_tcode    text;\n'
             || E'  v_classes  text[];\n'
             || E'  v_applies  boolean;\n'
             || E'  r          record;';
  v_ca  text := '  perform erp.authorise(''master_data.write'');';
  v_cb  text := v_ca || E'\n'
             || E'\n'
             || E'  -- The classes ticked against the pattern, which until now were written and\n'
             || E'  -- read by nothing: a product of any class could be created against a pattern\n'
             || E'  -- ticked for one. Asked before the sequence is consumed, so a refusal costs\n'
             || E'  -- no number. A pattern that names no class applies to every product, which\n'
             || E'  -- is what the words under the field say.\n'
             || E'  select ct.code, ct.item_classes,\n'
             || E'         ct.item_classes is null or p_item_class = any (ct.item_classes)\n'
             || E'    into v_tcode, v_classes, v_applies\n'
             || E'    from erp.code_template ct\n'
             || E'   where ct.tenant_id = v_tenant and ct.id = p_template_id;\n'
             || E'\n'
             || E'  if not coalesce(v_applies, true) then\n'
             || E'    raise exception\n'
             || E'      ''CLOVEERP_TEMPLATE_NOT_FOR_THIS_CLASS: the code pattern % is for %, and this is a %'',\n'
             || E'      v_tcode, array_to_string(v_classes, '', ''), p_item_class\n'
             || E'      using errcode = ''23514'',\n'
             || E'            hint = ''Choose a code pattern that covers this kind of product, or tick this kind against the pattern.'';\n'
             || E'  end if;';
begin
  if (length(v_def) - length(replace(v_def, v_da, ''))) / length(v_da) <> 1
     or (length(v_def) - length(replace(v_def, v_ca, ''))) / length(v_ca) <> 1 then
    raise exception
      'CLOVEERP_CLASSIFIED_ITEM_UNRECOGNISED: public.erp_create_classified_item() is not the text this migration patches'
      using hint = 'Read the live body with pg_get_functiondef and anchor on what is there now.';
  end if;
  v_def := replace(v_def, v_da, v_db);
  v_def := replace(v_def, v_ca, v_cb);
  execute v_def;
end
$ct_classes$;

comment on function public.erp_create_classified_item(text, text, uuid, jsonb, boolean) is
  'Creates a product classified first and coded from that classification. The '
  'code pattern must be one that covers this kind of product: a pattern ticked '
  'for one class composed codes for every class until 16 September 2026, which '
  'is the whole reason the class list was offered.';

select erp.register_refusal('CLOVEERP_TEMPLATE_NOT_FOR_THIS_CLASS',
  'Creating a product from a code pattern that is not for that kind of product.',
  'A code pattern can be ticked for particular kinds of product, and the words under that field say a pattern with none ticked applies to every product. This pattern names some kinds and this product is not one of them, so the code it would compose would say the product is something it is not.',
  'Choose a pattern that covers this kind of product, or open the pattern and tick this kind against it.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. B. Silence reaches a person
-- ═════════════════════════════════════════════════════════════════════════════

-- ── 2.1 The budget is named where the silent jobs are chosen ─────────────────

do $silence$
declare
  v_def text := pg_catalog.pg_get_functiondef('erp.silent_jobs()'::regprocedure);
  v_old text := '    select jb.*, erp.job_silence_tolerance(jb) as tol';
  v_new text := E'    select jb.*,\n'
             || E'           case when jb.max_silence_seconds is not null\n'
             || E'                  then make_interval(secs => jb.max_silence_seconds)\n'
             || E'                else erp.job_silence_tolerance(jb) end as tol';
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception
      'CLOVEERP_SILENT_JOBS_UNRECOGNISED: erp.silent_jobs() does not choose its rows with the text this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and anchor on what is there now.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$silence$;

comment on function erp.silent_jobs() is
  'Spec 3.8: "a job that stops running raises an alert". The budget somebody '
  'typed against the job wins outright and is named here rather than only inside '
  'erp.job_silence_tolerance(erp.job); the schedule decides for a job that was '
  'given none. A disabled job, a manual job and a job inside an outage window '
  'are not silent, because nothing promised any of them would run.';

-- ── 2.2 The words silence is told in ─────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('notify.job_silenced.subject', 'en', 'Scheduled job has stopped running',
   'administration',
   'Subject when a scheduled job has gone longer without a successful run than it was given.'),
  ('notify.job_silenced.body', 'en',
   'A scheduled job has not finished successfully for longer than it is allowed to go quiet. Nothing has failed; it has stopped running, which is why nothing said so until now.',
   'administration',
   'Body when a scheduled job has gone longer without a successful run than it was given.'),
  ('notify.job_silenced.subject', 'de', 'Geplanter Job läuft nicht mehr',
   'administration',
   'Subject when a scheduled job has gone longer without a successful run than it was given.'),
  ('notify.job_silenced.body', 'de',
   'Ein geplanter Job wurde länger nicht erfolgreich abgeschlossen, als er still sein darf. Nichts ist fehlgeschlagen; er läuft nicht mehr, und genau deshalb hat bisher niemand etwas gesagt.',
   'administration',
   'Body when a scheduled job has gone longer without a successful run than it was given.')
on conflict (key, locale) do update
  set value = excluded.value, module_code = excluded.module_code,
      description = excluded.description;

-- ── 2.3 The route every organisation has ─────────────────────────────────────

insert into erp_ref.notification_route_default
  (code, event_pattern, severity, audience_kind, role_code, channel_kind,
   subject_key, body_key, link_path, is_mandatory)
values
  ('job_silenced', 'job.silenced', 'high', 'role', 'administrator', 'email',
   'notify.job_silenced.subject', 'notify.job_silenced.body', '/operations/jobs', true)
on conflict (code) do update set
  event_pattern = excluded.event_pattern, severity = excluded.severity,
  audience_kind = excluded.audience_kind, role_code = excluded.role_code,
  channel_kind = excluded.channel_kind, subject_key = excluded.subject_key,
  body_key = excluded.body_key, link_path = excluded.link_path,
  is_mandatory = excluded.is_mandatory;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. C. A label asks what is in the tray
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.label_stock_size(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  -- A width and a height out of free text, or nothing. 100x150, 100 x 150 mm
  -- and 100x150mm are the same size; A4, a blank field and a manufacturer's
  -- part number are no size at all and are never compared with anything. A
  -- number without a unit is read in millimetres, which is the unit
  -- erp.compose_zpl() already reads the template's page size in.
  select case
           when z.m is null then null
           else pg_catalog.format('%sx%smm',
                  pg_catalog.trim_scale((z.m[1])::numeric),
                  pg_catalog.trim_scale((z.m[2])::numeric))
         end
    from (select pg_catalog.regexp_match(
                   lower(coalesce(p_text, '')),
                   '([0-9]+(?:\.[0-9]+)?)\s*[x*]\s*([0-9]+(?:\.[0-9]+)?)\s*(?:mm)?') as m) z;
$$;

revoke all on function erp.label_stock_size(text) from public, anon, authenticated;

comment on function erp.label_stock_size(text) is
  'The width and height a piece of free text states, normalised to WxHmm, or '
  'nothing when it states no size. §15.3 kept a printer''s stock as free text '
  'on purpose; this reads the one thing out of it that can be compared with a '
  'template''s page size, and declines to guess at the rest.';

do $label$
declare
  v_def text := pg_catalog.pg_get_functiondef('erp.render_label(text,text,uuid,text)'::regprocedure);
  v_da  text := '  v_render jsonb; v_zpl text; v_request uuid; v_render_id uuid; v_delivery uuid;';
  v_db  text := '  v_render jsonb; v_zpl text; v_request uuid; v_render_id uuid; v_delivery uuid;'
             || E'\n  v_loaded text; v_drawn text;';
  v_ca  text := '  v_render := erp.render_output_template(p_template_code, p_document_id, p_locale);';
  v_cb  text := E'  -- §15.3: "label stock and resolution are properties of the printer, not\n'
             || E'  -- the template". The resolution has always been read; the stock never was,\n'
             || E'  -- so a label drawn at one size went to a printer loaded with another and\n'
             || E'  -- printed across the gap. Only compared when both say a size.\n'
             || E'  v_loaded := erp.label_stock_size(pr.default_stock);\n'
             || E'  v_drawn  := erp.label_stock_size(t.page);\n'
             || E'  if v_loaded is not null and v_drawn is not null and v_loaded <> v_drawn then\n'
             || E'    raise exception\n'
             || E'      ''CLOVEERP_LABEL_STOCK_MISMATCH: % is loaded with % and % is drawn at %'',\n'
             || E'      p_printer_code, v_loaded, p_template_code, v_drawn\n'
             || E'      using errcode = ''23514'',\n'
             || E'            hint = ''Load the stock this label is drawn for, or change what the printer says is loaded, or draw the label at the size that is in the tray.'';\n'
             || E'  end if;\n'
             || E'\n'
             || '  v_render := erp.render_output_template(p_template_code, p_document_id, p_locale);';
begin
  if (length(v_def) - length(replace(v_def, v_da, ''))) / length(v_da) <> 1
     or (length(v_def) - length(replace(v_def, v_ca, ''))) / length(v_ca) <> 1 then
    raise exception
      'CLOVEERP_RENDER_LABEL_UNRECOGNISED: erp.render_label() is not the text this migration patches'
      using hint = 'Read the live body with pg_get_functiondef and anchor on what is there now.';
  end if;
  v_def := replace(v_def, v_da, v_db);
  v_def := replace(v_def, v_ca, v_cb);
  execute v_def;
end
$label$;

comment on function erp.render_label(text, text, uuid, text) is
  'Composes a label as ZPL at the printer''s resolution, on the stock the '
  'printer says is loaded, and queues it. A label drawn at a size the printer '
  'is not loaded with is refused rather than printed across the gap between two '
  'labels; a printer that states no stock prints whatever it is sent.';

select erp.register_refusal('CLOVEERP_LABEL_STOCK_MISMATCH',
  'Printing a label drawn at one size on a printer loaded with another.',
  'The label would print across the gap between two labels, and the barcode on it would not scan. That is discovered by whoever receives the goods rather than by whoever printed them, which is the wrong end.',
  'Load the stock this label is drawn for, or change what the printer says is loaded, or draw the label at the size that is in the tray.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The register loses three rows
-- ═════════════════════════════════════════════════════════════════════════════

delete from erp_meta.write_only_column g
 where (g.schema_name, g.table_name, g.column_name) in (
   ('erp', 'code_template', 'entity_id'),
   ('erp', 'job', 'max_silence_seconds'),
   ('erp', 'printer', 'default_stock'));

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The row that stays, and what it would take
-- -----------------------------------------------------------------------------
-- erp.change_set_item.effective_from is left registered, and its rationale is
-- corrected, because the one it carries is wrong in a way that matters.
--
-- It said promotion "applies every item the moment the set is promoted. A date
-- in the future is accepted and ignored." Half of that is false.
-- erp.apply_change_set_item() reads the date on the item into v_from and hands
-- it to every arm that writes a dated version — the configuration value, the
-- legislation binding, the rule set, the state machine, the approval chain, the
-- posting rule, the posting class, the account determination. Those take effect
-- on the date, not at promotion, and always have. The check cannot see it
-- because the configuration transport is deliberately excluded from the read
-- walk: 20260916430000's header says counting it "would make the register empty
-- and the check useless", and it is right.
--
-- What is true is that every other kind — a role, a terminology override, a
-- classification axis or value, a code pattern, a release area, an approval
-- band, a printer, an output template — is applied at promotion whatever date
-- the item carries. So the field is honoured for about half the promotable
-- surfaces and silently ignored for the rest, which is worse than either
-- honouring it everywhere or refusing it where it cannot be honoured.
--
-- Honouring it everywhere is the larger change and the right one: the item is
-- held back at promotion and applied when its date arrives, which needs a
-- handler, a job every organisation runs, a state on the item saying it is
-- waiting, and a screen that shows what is waiting and lets somebody withdraw
-- it. That is a file of its own.
--
-- Refusing it is smaller but not small, and not correct on its own: it needs a
-- way to know which arms of erp.apply_change_set_item() date their write and
-- which do not, and the only honest source for that is the promoter's own body.
-- A list held anywhere else drifts the first time an arm is added.
--
-- Neither is done here, so the row stays with a rationale that says what is
-- actually true. No screen offers the date — only a change set built by the
-- interview, an import, or a pack — so nobody is at present looking at a
-- control that does nothing.
-- ═════════════════════════════════════════════════════════════════════════════

update erp_meta.write_only_column
   set rationale =
     'A KNOWN GAP as at 16 September 2026, restated on the same day because the '
     'first rationale was wrong. erp.apply_change_set_item() DOES read the date, '
     'into v_from, and every arm that writes a dated version — a configuration '
     'value, a legislation binding, a rule set, a state machine, an approval '
     'chain, a posting rule, a posting class, an account determination — takes '
     'effect on it. The check cannot see that because the configuration '
     'transport is deliberately outside the read walk. The gap is the other half: '
     'every kind that is not versioned — a role, a terminology override, a '
     'classification axis, a code pattern, a release area, a printer, an output '
     'template — is applied at promotion whatever date the item carries. '
     'Honouring those needs the item held back and a job to apply it when the '
     'date arrives; refusing them needs the promoter''s own body read to know '
     'which arms date their write. Neither is done. No screen offers the date.'
 where schema_name = 'erp' and table_name = 'change_set_item'
   and column_name = 'effective_from';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The words the screen gains
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Only for one company',
     'Said over the company a product code pattern is scoped to, on the classification and coding screen.'),
    ('Leave this empty for a pattern every company uses. A pattern for one company is amended on its own, and never versions another company''s pattern of the same code.',
     'Said under that field, because until now a pattern could only be scoped to a company by an import and no screen said it had been.'),
    ('Every company',
     'Shown in the company column of the code templates table when a pattern is not scoped to one.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.settings_that_decide_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_e1     uuid; v_e2     uuid; v_ccy character(3);
  v_site   uuid;
  v_t1     uuid; v_t2     uuid;
  v_job_a  uuid; v_job_b  uuid; v_job_c uuid;
  v_first  jsonb;
  v_rows   jsonb;
  v_ok     boolean; v_msg text;
  v_ok2    boolean; v_msg2 text;
  res      jsonb;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-settings', 'Settings suite', 'admin@zz-settings.test', 'Settings Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000f1', 'admin@zz-settings.test');
  perform set_config('request.jwt.claims',
    json_build_object('sub', '00000000-0000-4000-8000-0000000000f1')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.base_currency into v_e1, v_ccy
    from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  -- A second company of the suite's own, so the case does not depend on how
  -- many companies the demonstration happens to carry.
  v_e2 := public.erp_create_entity('ZZ-TWO', 'Second suite company',
                                   'Second Suite Company Ltd', v_ccy::text, 'GB', 'en', 'en', 1);

  -- ═══ A. A code pattern belongs to a company ═══════════════════════════════

  -- ── 1. Two companies hold their own pattern of one code ──────────────────
  v_cases := v_cases + 1;
  perform erp.upsert_code_template('ZZCT', 'First company pattern',
    '[{"kind":"literal","text":"AAA"},{"kind":"sequence","length":4}]'::jsonb,
    null, 'upper', v_e1);
  perform erp.upsert_code_template('ZZCT', 'Second company pattern',
    '[{"kind":"literal","text":"BBB"},{"kind":"sequence","length":4}]'::jsonb,
    null, 'upper', v_e2);

  select ct.id into v_t1 from erp.code_template ct
   where ct.tenant_id = v_tenant and ct.code = 'ZZCT' and ct.entity_id = v_e1;
  select ct.id into v_t2 from erp.code_template ct
   where ct.tenant_id = v_tenant and ct.code = 'ZZCT' and ct.entity_id = v_e2;

  case_name := 'saving one company''s code pattern does not find, overwrite or version another company''s of the same code';
  passed := v_t1 is not null and v_t2 is not null and v_t1 <> v_t2
        and (select ct.name from erp.code_template ct where ct.id = v_t1) = 'First company pattern'
        and (select ct.name from erp.code_template ct where ct.id = v_t2) = 'Second company pattern'
        and (select count(*) from erp.code_template ct
              where ct.tenant_id = v_tenant and ct.code = 'ZZCT') = 2
        and not exists (select 1 from erp.code_template ct
                         where ct.tenant_id = v_tenant and ct.code = 'ZZCT'
                           and ct.status <> 'active');
  detail := format('%s pattern(s) of ZZCT, %s active',
                   (select count(*) from erp.code_template ct
                     where ct.tenant_id = v_tenant and ct.code = 'ZZCT'),
                   (select count(*) from erp.code_template ct
                     where ct.tenant_id = v_tenant and ct.code = 'ZZCT' and ct.status = 'active'));
  return next;

  -- ── 2. And amending one amends that one ──────────────────────────────────
  v_cases := v_cases + 1;
  perform erp.upsert_code_template('ZZCT', 'Second company, amended',
    '[{"kind":"literal","text":"CCC"},{"kind":"sequence","length":4}]'::jsonb,
    null, 'upper', v_e2);
  case_name := 'amending a company''s pattern amends that company''s and leaves the other alone';
  passed := (select ct.name from erp.code_template ct where ct.id = v_t2) = 'Second company, amended'
        and (select ct.name from erp.code_template ct where ct.id = v_t1) = 'First company pattern'
        and (select count(*) from erp.code_template ct
              where ct.tenant_id = v_tenant and ct.code = 'ZZCT') = 2;
  detail := format('first: %s; second: %s',
                   (select ct.name from erp.code_template ct where ct.id = v_t1),
                   (select ct.name from erp.code_template ct where ct.id = v_t2));
  return next;

  -- ── 3. A pattern for every company is its own pattern, not either of those
  v_cases := v_cases + 1;
  perform erp.upsert_code_template('ZZCT', 'Every company pattern',
    '[{"kind":"literal","text":"ZZZ"},{"kind":"sequence","length":4}]'::jsonb,
    null, 'upper', null);
  case_name := 'a pattern for every company is a third pattern and does not disturb either company''s';
  passed := (select count(*) from erp.code_template ct
              where ct.tenant_id = v_tenant and ct.code = 'ZZCT') = 3
        and exists (select 1 from erp.code_template ct
                     where ct.tenant_id = v_tenant and ct.code = 'ZZCT' and ct.entity_id is null
                       and ct.name = 'Every company pattern')
        and (select ct.name from erp.code_template ct where ct.id = v_t1) = 'First company pattern';
  detail := format('%s pattern(s) of ZZCT', (select count(*) from erp.code_template ct
                     where ct.tenant_id = v_tenant and ct.code = 'ZZCT'));
  return next;

  -- ── 4. The list says which company, nearest first ────────────────────────
  v_cases := v_cases + 1;
  v_rows := public.erp_code_templates();
  select x into v_first from jsonb_array_elements(v_rows) x
   where x ->> 'code' = 'ZZCT' limit 1;
  case_name := 'the list of patterns names the company each is for and offers a company''s own before the one every company uses';
  passed := v_first is not null
        and (v_first ->> 'entity_id') is not null
        and (v_first ->> 'entity_code') is not null
        and exists (select 1 from jsonb_array_elements(v_rows) x
                     where x ->> 'code' = 'ZZCT' and (x ->> 'entity_id') is null
                       and x ->> 'entity_code' is null);
  detail := coalesce('first ZZCT offered is for ' || (v_first ->> 'entity_code'),
                     'no ZZCT pattern was offered');
  return next;

  -- ── 5. A pattern ticked for one kind of product is only for that kind ────
  v_cases := v_cases + 1;
  perform erp.upsert_code_template('ZZCTCLASS', 'Finished goods only',
    '[{"kind":"literal","text":"FIN"},{"kind":"sequence","length":4}]'::jsonb,
    'finished', 'upper', null);
  begin
    perform public.erp_create_classified_item('Suite product', 'raw',
      (select ct.id from erp.code_template ct
        where ct.tenant_id = v_tenant and ct.code = 'ZZCTCLASS'),
      '{}'::jsonb, false);
    v_ok := false; v_msg := 'a pattern for finished goods composed a raw product''s code';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_TEMPLATE_NOT_FOR_THIS_CLASS%';
    v_msg := left(sqlerrm, 90);
  end;
  begin
    perform public.erp_create_classified_item('Suite product', 'raw', v_t1,
                                              '{}'::jsonb, false);
    v_ok2 := true; v_msg2 := 'accepted';
  exception when others then
    v_ok2 := sqlerrm not like 'CLOVEERP_TEMPLATE_NOT_FOR_THIS_CLASS%';
    v_msg2 := left(sqlerrm, 60);
  end;
  case_name := 'a pattern ticked for one kind of product refuses another kind, and a pattern with none ticked takes every kind';
  passed := v_ok and v_ok2;
  detail := format('ticked: %s; unticked: %s', v_msg, v_msg2);
  return next;

  -- ═══ B. Silence reaches a person ══════════════════════════════════════════

  -- ── 6. The budget is what decides ────────────────────────────────────────
  --
  -- Three jobs on one schedule, each three hours quiet. The only thing that
  -- differs between the first two is the budget, so the budget is the only
  -- thing that can be deciding.
  v_cases := v_cases + 1;
  perform erp.upsert_job('zz_silent', 'Suite: a job given an hour',
    'administration.sequence_gaps', 'daily', null, '02:00'::time, null, null,
    'UTC', '{}'::jsonb, null, 3600, true);
  perform erp.upsert_job('zz_derived', 'Suite: a job left with its handler''s budget',
    'administration.sequence_gaps', 'daily', null, '02:00'::time, null, null,
    'UTC', '{}'::jsonb, null, null, true);
  perform erp.upsert_job('zz_quiet', 'Suite: a job deliberately switched off',
    'administration.sequence_gaps', 'daily', null, '02:00'::time, null, null,
    'UTC', '{}'::jsonb, null, 3600, false);
  select j.id into v_job_a from erp.job j where j.tenant_id = v_tenant and j.code = 'zz_silent';
  select j.id into v_job_b from erp.job j where j.tenant_id = v_tenant and j.code = 'zz_quiet';
  select j.id into v_job_c from erp.job j where j.tenant_id = v_tenant and j.code = 'zz_derived';
  insert into erp.job_run (tenant_id, job_id, scheduled_for, started_at, finished_at, outcome)
  values (v_tenant, v_job_a, now() - interval '3 hours', now() - interval '3 hours',
          now() - interval '3 hours', 'succeeded'),
         (v_tenant, v_job_b, now() - interval '3 hours', now() - interval '3 hours',
          now() - interval '3 hours', 'succeeded'),
         (v_tenant, v_job_c, now() - interval '3 hours', now() - interval '3 hours',
          now() - interval '3 hours', 'succeeded');

  case_name := 'three hours quiet is silent against an hour''s budget and is not against two days'': the budget is what decides';
  passed := exists (select 1 from erp.silent_jobs() s
                     where s.job_code = 'zz_silent' and s.tolerance = interval '1 hour')
        and not exists (select 1 from erp.silent_jobs() s where s.job_code = 'zz_derived')
        and (select erp.job_silence_tolerance(j) from erp.job j where j.id = v_job_a)
            = interval '1 hour'
        and (select erp.job_silence_tolerance(j) from erp.job j where j.id = v_job_c)
            = interval '2 days';
  detail := coalesce((select format('%s at a tolerance of %s', s.job_code, s.tolerance)
                        from erp.silent_jobs() s where s.job_code = 'zz_silent'),
                     'the job was not reported silent');
  return next;

  -- ── 7. A job somebody switched off does not alarm ────────────────────────
  v_cases := v_cases + 1;
  case_name := 'a job deliberately switched off is not silent, because nothing promised it would run';
  passed := not exists (select 1 from erp.silent_jobs() s where s.job_code = 'zz_quiet');
  detail := 'zz_quiet is as quiet as it was asked to be';
  return next;

  -- ── 8. And a person is told ──────────────────────────────────────────────
  v_cases := v_cases + 1;
  perform * from erp.report_silent_jobs();
  case_name := 'silence raises an event, and the route every organisation has carries it to the administrators';
  passed := exists (select 1 from erp.event ev
                     where ev.tenant_id = v_tenant and ev.event_type = 'job.silenced'
                       and ev.aggregate_id = v_job_a)
        and not exists (select 1 from erp.event ev
                         where ev.tenant_id = v_tenant and ev.event_type = 'job.silenced'
                           and ev.aggregate_id = v_job_b)
        and exists (select 1 from erp_ref.notification_route_default d
                     where d.code = 'job_silenced' and 'job.silenced' like d.event_pattern
                       and d.audience_kind = 'role' and d.role_code = 'administrator'
                       and d.is_mandatory)
        and not exists (select 1 from erp.notification_chain_report() x
                         where x.finding like 'the product route%');
  detail := format('%s job.silenced event(s) raised',
                   (select count(*) from erp.event ev
                     where ev.tenant_id = v_tenant and ev.event_type = 'job.silenced'));
  return next;

  -- ═══ C. A label asks what is in the tray ══════════════════════════════════

  v_cases := v_cases + 1;
  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (v_tenant, v_e1, 'ZZDC', 'Suite distribution centre', 'warehouse', 'active')
  returning id into v_site;
  perform erp.upsert_output_template('zz_bin_label', 'output.template.bin_label', 'label',
    null, '100x150mm',
    '[{"kind": "title", "fields": ["document_number"]}, {"kind": "barcode", "fields": ["document_number"]}]'::jsonb);
  perform erp.upsert_output_template_version('zz_bin_label', 'zpl', '{}'::jsonb, '[]'::jsonb,
    'inventory.read', 'zpl', '^XA^BCN^FD123^FS^XZ', true, '123', current_date - 1, 'suite');
  perform erp.upsert_printer('ZZFIT', 'ZZDC', 'Loaded with the right roll', 'label', 'zpl',
    203, 'Bench 1', '100x150mm', 'tcp://10.0.0.31:9100');
  perform erp.upsert_printer('ZZWRONG', 'ZZDC', 'Loaded with something else', 'label', 'zpl',
    203, 'Bench 2', '50x25mm', 'tcp://10.0.0.32:9100');
  perform erp.upsert_printer('ZZSILENT', 'ZZDC', 'Says nothing about its stock', 'label', 'zpl',
    203, 'Bench 3', 'Zebra Z-Select', 'tcp://10.0.0.33:9100');
  perform erp_test.close_bootstrap_window(v_tenant);

  res := erp.render_label('zz_bin_label', 'ZZFIT');
  case_name := 'a label drawn at the size the printer says is loaded prints';
  passed := (res ->> 'zpl') like '^XA%^XZ' and (res ->> 'printer') = 'ZZFIT';
  detail := format('%s characters of ZPL', length(res ->> 'zpl'));
  return next;

  v_cases := v_cases + 1;
  begin
    perform erp.render_label('zz_bin_label', 'ZZWRONG');
    v_ok := false; v_msg := 'it printed on the wrong stock';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_LABEL_STOCK_MISMATCH%';
    v_msg := left(sqlerrm, 90);
  end;
  case_name := 'a label drawn at one size is refused by a printer loaded with another, and one that states no size prints as it always did';
  passed := v_ok
        and (erp.render_label('zz_bin_label', 'ZZSILENT') ->> 'printer') = 'ZZSILENT'
        and erp.label_stock_size('Zebra Z-Select') is null
        and erp.label_stock_size('100 x 150 mm') = erp.label_stock_size('100x150mm');
  detail := v_msg;
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 11. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-settings')
        and not exists (select 1 from auth.users
                         where id = '00000000-0000-4000-8000-0000000000f1');
  detail := 'zz-settings rolled back with its patterns, its jobs and its printers';
  return next;

  if v_cases <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: settings_that_decide_suite ran % cases, expected 11', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.settings_that_decide_suite() from public, anon;

create or replace function erp_test.assert_settings_that_decide_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _settings_decide on commit drop as
    select * from erp_test.settings_that_decide_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _settings_decide;
  drop table _settings_decide;
  if v_fail > 0 then
    raise exception E'CLOVEERP_SETTINGS_THAT_DECIDE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: settings_that_decide_suite ran % cases, expected 11', v_all;
  end if;
  return format('three settings that decide something: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_settings_that_decide_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_write_only_columns();
select erp.assert_ci_coverage();
select erp_test.assert_settings_that_decide_suite();
