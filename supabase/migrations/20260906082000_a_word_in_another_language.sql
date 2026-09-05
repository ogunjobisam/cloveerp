-- A word in another language.
--
-- The product resolves every label through a resource key, and it did so in
-- one language. The locale table listed fourteen locales; three of them were
-- German and carried no string at all, and `de` named no parent, so a German
-- user asking for a label received the key itself: erp.text() walked the
-- chain [de] and, finding nothing, returned 'glossary.batch'. Only the
-- front-end bundle door added an English floor, so the same person saw
-- English in the shell and a key in an email. A tenant could reword a label
-- only where the product already had one in that exact locale, and could not
-- add a word of its own at all; there was no way to ask "which of my labels
-- is this locale still serving in English?"
--
-- This file makes German a language the product speaks and makes the gaps
-- visible.
--
-- English is the floor for every locale. erp.locale_chain() ends in `en`
-- unless the chain already reached it, so a label with no German is served in
-- English, never as its key; de-AT falls through de to en.
--
-- The core German pack: about 560 strings — every key the coverage gate
-- reads (modules, permissions, settings, decision points, events, packs,
-- returns, governed views, and now scheduled-job names, document and movement
-- types, guides, adapters, migration domains and legislation rules), the
-- glossary, the navigation, notification subjects and bodies, output labels
-- and the next action of every registered refusal. erp.assert_resource_coverage
-- gains a German run (register seq 97), so a key the gate reads that gains no
-- German string fails the build like a missing English one does. What is not
-- in the pack is honest about it: erp.untranslated_report(locale) and the
-- door erp_untranslated list every key a locale is still serving from
-- English, tenant terms included, and the terminology screen shows them.
--
-- A tenant may define a word. erp_set_resource_override accepts a key under
-- custom. that the product never shipped, so an organisation that calls a
-- pallet a skid has a key for it; the bundle carries it, erp.text() resolves
-- it, and every other locale reports it as untranslated until somebody
-- translates it. A key outside custom. that the product does not know is
-- refused by name (CLOVEERP_UNKNOWN_RESOURCE_KEY) with the next action.
--
-- The gate the coverage assertion reads is widened from eight erp_ref tables
-- to every erp_ref table with a name_key column. That found one English gap:
-- the scheduled job integration.backlog_alert had a name key and no string
-- (deferred finding 19); the string is added here.
--
-- An approval band is in a currency and a document may not be. Bands were
-- compared with the document value as bare integers whatever the currencies:
-- a €100,000 order against a £80,000 band compared 100000 with 80000. The
-- resolver now converts the value into each band's currency through
-- erp.convert_minor(), which reads the organisation's rates (direct or
-- inverse) and refuses by name when there is none (CLOVEERP_NO_RATE), because
-- routing a document to the wrong approver on a guessed rate is the expensive
-- kind of quiet. A rate arrives through erp.load_exchange_rate() and the door
-- erp_set_exchange_rate, and it must say where it came from; the finance
-- register already flags a rate without a source. Named approver assignments
-- still compare bare figures: they carry no currency (deferred finding 22).
--
-- An order between two companies of one organisation is one event.
-- erp.raise_intercompany_order(sales_order, site) takes a sales order whose
-- customer is another company of the organisation and raises the mirrored
-- purchase order in that company, at the site named, in that company's own
-- currency with the rate stamped and the lines converted, links the two as
-- `mirrors` and appends document.mirrored. Part 5's 5.6.order_capture, partial
-- since the register was written, is built.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. English is the floor
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.locale_chain(p_locale text)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  v_chain text[] := '{}';
  v_cur   text := coalesce(p_locale, 'en');
  v_guard integer := 0;
begin
  while v_cur is not null and v_guard < 10 loop
    v_chain := v_chain || v_cur;
    select l.parent_locale into v_cur from erp_ref.locale l where l.code = v_cur;
    v_guard := v_guard + 1;
  end loop;
  -- The floor. A locale that names no parent still resolves to a word rather
  -- than to a key; the bundle door has done this since it was written and the
  -- text resolver did not, which is how an email and a screen disagreed.
  if not ('en' = any (v_chain)) then
    v_chain := v_chain || 'en'::text;
  end if;
  return v_chain;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What a locale still serves in English, and a word a tenant defines
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.untranslated_report(p_locale text default null)
returns table(key text, en_value text, served_from text, is_tenant_term boolean)
language sql
stable
set search_path = ''
as $$
  with steps as (
    select u.code
      from unnest(erp.locale_chain(coalesce(p_locale, 'en'))) with ordinality as u(code, ord)
     where u.code <> 'en'
  ),
  wanted as (
    select r.key, r.value, false as tenant_term
      from erp_ref.resource r
     where r.locale = 'en'
    union all
    select o.key, o.value, true
      from erp.resource_override o
     where o.tenant_id = erp.current_tenant_id()
       and o.locale = 'en' and o.status = 'active'
       and o.key like 'custom.%'
       and not exists (select 1 from erp_ref.resource r where r.key = o.key and r.locale = 'en')
  )
  select w.key, w.value, 'en', w.tenant_term
    from wanted w
   where exists (select 1 from steps)
     and not exists (
       select 1 from steps s
         join erp_ref.resource r on r.locale = s.code and r.key = w.key)
     and not exists (
       select 1 from steps s
         join erp.resource_override o
           on o.locale = s.code and o.key = w.key
          and o.tenant_id = erp.current_tenant_id() and o.status = 'active')
   order by w.key
$$;
revoke all on function erp.untranslated_report(text) from public, anon, authenticated;

comment on function erp.untranslated_report is
  'Every key a locale is still serving from English: no product string and no '
  'tenant override at any step of its chain before the floor. Tenant-defined '
  'terms under custom. are included, so a word an organisation coined shows '
  'as untranslated in every other locale until somebody translates it.';

drop function if exists public.erp_untranslated(text);
create function public.erp_untranslated(p_locale text default null)
returns table(key text, en_value text, served_from text, is_tenant_term boolean)
language sql
stable
set search_path = ''
as $$
  select * from erp.untranslated_report(p_locale)
$$;
revoke all on function public.erp_untranslated(text) from public, anon;
grant execute on function public.erp_untranslated(text) to authenticated, service_role;

-- The override door: a tenant may translate a product key into any active
-- locale, or define its own word under custom. Refusals name the next action.
create or replace function public.erp_set_resource_override(
  p_key text, p_value text, p_locale text default 'en', p_note text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_id     uuid;
  v_locale text := coalesce(p_locale, 'en');
begin
  perform erp.authorise('administration.configure');
  v_tenant := erp.current_tenant_id();

  if not exists (select 1 from erp_ref.locale l where l.code = v_locale and l.is_active) then
    raise exception 'CLOVEERP_UNKNOWN_LOCALE: % is not an active locale', v_locale
      using errcode = '23503',
            hint = 'Choose a locale from erp_ref.locale; de, de-AT, de-CH, en, en-GB, en-IE, en-US, fr, nl and others are active.';
  end if;

  if p_key like 'custom.%' then
    if p_key !~ '^custom\.[a-z0-9_]+(\.[a-z0-9_]+)*$' then
      raise exception 'CLOVEERP_UNKNOWN_RESOURCE_KEY: % is not a well-formed tenant term', p_key
        using errcode = '23514',
              hint = 'A tenant-defined term is custom. followed by lower-case words, digits and underscores separated by dots, such as custom.pallet_word.';
    end if;
  elsif not exists (select 1 from erp_ref.resource r where r.key = p_key) then
    raise exception 'CLOVEERP_UNKNOWN_RESOURCE_KEY: the product has no label keyed %', p_key
      using errcode = '23503',
            hint = 'Choose a key from the terminology screen to reword or translate it, or define a word of your own under custom.';
  end if;

  if p_value is null or btrim(p_value) = '' then
    delete from erp.resource_override o
     where o.tenant_id = v_tenant and o.key = p_key and o.locale = v_locale and o.entity_id is null;
    return jsonb_build_object('key', p_key, 'locale', v_locale, 'override', null);
  end if;

  insert into erp.resource_override (tenant_id, key, locale, value, note, status, created_by)
  values (v_tenant, p_key, v_locale, btrim(p_value), p_note,
          'active'::erp.record_status, erp.current_principal_id())
  on conflict (tenant_id, key, locale,
               coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid))
    do update
    set value = excluded.value, note = excluded.note,
        status = 'active'::erp.record_status,
        updated_at = now(), updated_by = erp.current_principal_id()
  returning id into v_id;

  return jsonb_build_object('key', p_key, 'locale', v_locale, 'override_id', v_id,
                            'tenant_term', p_key like 'custom.%');
end;
$$;
revoke all on function public.erp_set_resource_override(text, text, text, text) from public, anon;
grant execute on function public.erp_set_resource_override(text, text, text, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_resource_override', 'erp.authorise',
   'Rewords or translates a product label for this organisation, or defines a tenant term under custom.; gated on administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- The bundle carries tenant terms too. The first version joined overrides to
-- product rows, so a key with no product row never reached a screen.
create or replace function public.erp_resources(p_locale text default 'en')
returns jsonb
language sql
stable
set search_path = ''
as $$
  with recursive chain(code, parent_locale, depth) as (
      select l.code, l.parent_locale, 0
        from erp_ref.locale l
       where l.code = coalesce(p_locale, 'en')
      union all
      select l.code, l.parent_locale, chain.depth + 1
        from chain
        join erp_ref.locale l on l.code = chain.parent_locale
       where chain.depth < 4
  ),
  steps as (
      select code, depth from chain
      union all
      select 'en', 99
  ),
  resolved as (
      select r.key,
             coalesce(
               (select o.value from erp.resource_override o
                 where o.tenant_id = erp.current_tenant_id()
                   and o.key = r.key and o.locale = r.locale
                   and o.status = 'active'::erp.record_status limit 1),
               r.value) as value,
             s.depth
        from steps s
        join erp_ref.resource r on r.locale = s.code
      union all
      -- Tenant-defined terms: no product row to join, so they are their own
      -- source, at the depth of the locale they were written in.
      select o.key, o.value, s.depth
        from steps s
        join erp.resource_override o
          on o.locale = s.code
         and o.tenant_id = erp.current_tenant_id()
         and o.status = 'active'::erp.record_status
         and o.key like 'custom.%'
         and o.entity_id is null
  ),
  ranked as (
      select key, value, row_number() over (partition by key order by depth) as rn
        from resolved
  )
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from ranked where rn = 1
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The gate reads every name key, and one English gap closes
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('job_handler.integration_backlog_alert.name', 'en', 'Integration backlog alert', null,
   'Scheduled job name; the key existed and the string did not, and the gate read eight tables that did not include job handlers.'),
  ('event.document.mirrored', 'en', 'Sales order mirrored as a purchase order in another company', 'sales',
   'Event raised when an intercompany sales order is mirrored as a purchase order.')
on conflict (key, locale) do update set value = excluded.value;

create or replace function erp.resource_coverage_report(p_locale text default 'en')
returns table(source_table text, key text, finding text)
language plpgsql
stable
set search_path = ''
as $$
declare
  r record;
begin
  -- Every erp_ref table with a name_key column, read from the catalogue, so a
  -- table added tomorrow is gated the day it arrives rather than the day
  -- somebody remembers to list it.
  for r in
    select c.table_name
      from information_schema.columns c
     where c.table_schema = 'erp_ref' and c.column_name = 'name_key'
     order by c.table_name
  loop
    return query execute format(
      $q$ select %L, t.name_key, format('no %%s resource exists for this key', %L)
            from erp_ref.%I t
           where t.name_key is not null
             and not exists (select 1 from erp_ref.resource res
                              where res.key = t.name_key and res.locale = %L)
           order by t.name_key $q$,
      'erp_ref.' || r.table_name, p_locale, r.table_name, p_locale);
  end loop;
end;
$$;

create or replace function erp.assert_resource_coverage_de()
returns text
language sql
stable
set search_path = ''
as $$
  select erp.assert_resource_coverage('de')
$$;
revoke all on function erp.assert_resource_coverage_de() from public, anon, authenticated;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('resource_coverage_de', 'Every gated label has a German string', 'assertion', 'platform',
   'assert_resource_coverage_de', '', 'resource_coverage_report', '''de''',
   'Every key the coverage gate reads — modules, permissions, settings, events, packs, returns, views, jobs, document and movement types, guides, rules — has a German string, so a German user never sees a key or an English word where the product speaks.', true, 97)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, detail_arguments = excluded.detail_arguments,
      blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The German core pack
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value) values
  -- Settings, decision point, legislation, modules
  ('config.approval.reapproval_tolerance', 'de', 'Toleranz für erneute Genehmigung'),
  ('config.commercial.price_book', 'de', 'Preisbuch'),
  ('config.production.issue_method', 'de', 'Methode der Komponentenentnahme'),
  ('config.quality.quarantine_defaults', 'de', 'Standardwerte für Quarantäne'),
  ('config.sales.backorder_policy', 'de', 'Rückstandsregel'),
  ('config.sales.credit_control', 'de', 'Kreditkontrolle'),
  ('config.stock.allocation_policy', 'de', 'Zuteilungsregel'),
  ('config.stock.reservation_ageing', 'de', 'Alterung von Reservierungen und Bereitstellung'),
  ('config.stock.shelf_life_minimum', 'de', 'Mindestrestlaufzeit'),
  ('dp.tax.determination', 'de', 'Steuerfindung'),
  ('legislation.example_vat', 'de', 'Beispielhafte Umsatzsteuer (Rechtsraum XX)'),
  ('legislation.gb_vat', 'de', 'Umsatzsteuer Vereinigtes Königreich (VAT)'),
  ('legislation.ie_vat', 'de', 'Umsatzsteuer Irland (VAT)'),
  ('legislation.de_ust', 'de', 'Umsatzsteuer Deutschland'),
  ('module.administration', 'de', 'Verwaltung'),
  ('module.commercial', 'de', 'Verträge und Tarife'),
  ('module.finance', 'de', 'Finanzbuchhaltung'),
  ('module.governance', 'de', 'Änderungsanträge und Genehmigungen'),
  ('module.imports', 'de', 'Importe'),
  ('module.inventory', 'de', 'Lager'),
  ('module.logistics', 'de', 'Versand'),
  ('module.master_data', 'de', 'Stammdaten'),
  ('module.packs', 'de', 'Funktionen und Inhalte'),
  ('module.planning', 'de', 'Planung'),
  ('module.procurement', 'de', 'Einkauf'),
  ('module.production', 'de', 'Fertigung'),
  ('module.quality', 'de', 'Qualitätssicherung'),
  ('module.reporting', 'de', 'Berichte und Auswertungen'),
  ('module.sales', 'de', 'Verkauf'),
  ('module.tenant_lifecycle', 'de', 'Lebenszyklus der Organisation'),
  ('module.terminology', 'de', 'Terminologie'),
  -- Events
  ('event.approval.chain_resolved', 'de', 'Genehmigungskette ermittelt'),
  ('event.approval.cover_applied', 'de', 'Vertretung auf eine Genehmigung angewendet'),
  ('event.approval.cover_ended', 'de', 'Vertretung beendet'),
  ('event.approval.cover_started', 'de', 'Vertretung begonnen'),
  ('event.approval.escalated', 'de', 'Genehmigung eskaliert'),
  ('event.approval.reapproval_triggered', 'de', 'Erneute Genehmigung ausgelöst'),
  ('event.commercial.capability_refused', 'de', 'Funktion in diesem Tarif nicht verfügbar'),
  ('event.commercial.contract_amended', 'de', 'Vertrag geändert'),
  ('event.commercial.contract_renewed', 'de', 'Vertrag verlängert'),
  ('event.commercial.contract_signed', 'de', 'Vertrag unterzeichnet'),
  ('event.commercial.entitlement_exceeded', 'de', 'Tariflimit überschritten'),
  ('event.commercial.invoice_issued', 'de', 'Rechnung ausgestellt'),
  ('event.commercial.non_renewal_recorded', 'de', 'Nichtverlängerung erfasst'),
  ('event.commercial.notice_deadline_announced', 'de', 'Kündigungsfrist naht'),
  ('event.commercial.renewal_announced', 'de', 'Verlängerung naht'),
  ('event.commercial.review_announced', 'de', 'Überprüfung naht'),
  ('event.commercial.term_ended', 'de', 'Laufzeit beendet'),
  ('event.commercial.uplift_announced', 'de', 'Preisanpassung naht'),
  ('event.document.posted', 'de', 'Beleg im Hauptbuch gebucht'),
  ('event.document.mirrored', 'de', 'Kundenauftrag als Bestellung in einer anderen Gesellschaft gespiegelt'),
  ('event.integration.backlog_exceeded', 'de', 'Integrationsrückstand über dem Schwellenwert'),
  ('event.item.classified', 'de', 'Artikel klassifiziert'),
  ('event.item.code_assigned', 'de', 'Artikelnummer vergeben'),
  ('event.item.code_diverged', 'de', 'Artikelnummer weicht von ihrer Vorlage ab'),
  ('event.job.failed', 'de', 'Geplanter Job fehlgeschlagen'),
  ('event.master_record.merged', 'de', 'Stammsatz zusammengeführt'),
  ('event.posting.account_recorded', 'de', 'Sachkonto erfasst'),
  ('event.posting.class_changed', 'de', 'Kontierung geändert'),
  ('event.posting.determination_failed', 'de', 'Kontenfindung fehlgeschlagen'),
  ('event.posting.rule_resolved', 'de', 'Buchungsregel ermittelt'),
  ('event.release.allocation_completed', 'de', 'Freigabewelle zugeteilt'),
  ('event.release.printed', 'de', 'Freigabewelle gedruckt'),
  ('event.release.wave_opened', 'de', 'Freigabewelle eröffnet'),
  ('event.replenishment.stock_returned', 'de', 'Bestand an seinen Stammplatz zurückgeführt'),
  ('event.replenishment.task_raised', 'de', 'Nachschubauftrag erstellt'),
  ('event.sourcing.default_recorded', 'de', 'Standardlieferant erfasst'),
  ('event.stock.adjusted', 'de', 'Bestand ohne Beleg korrigiert'),
  ('event.subject.erased', 'de', 'Betroffene Person gelöscht'),
  ('event.support.access_granted', 'de', 'Supportzugang gewährt'),
  ('event.tenant.key_created', 'de', 'Organisationsschlüssel erstellt'),
  ('event.tenant.key_destroyed', 'de', 'Organisationsschlüssel vernichtet'),
  ('event.tenant.key_rotated', 'de', 'Organisationsschlüssel gewechselt'),
  -- Permissions
  ('permission.administration.audit_read', 'de', 'Prüfprotokoll lesen'),
  ('permission.administration.configure', 'de', 'Konfiguration ändern'),
  ('permission.administration.integrate', 'de', 'Integrationen verwalten'),
  ('permission.administration.jobs', 'de', 'Geplante Jobs verwalten'),
  ('permission.administration.promote', 'de', 'Konfiguration überführen'),
  ('permission.administration.read', 'de', 'Verwaltung ansehen'),
  ('permission.administration.roles', 'de', 'Rollen verwalten'),
  ('permission.administration.users', 'de', 'Benutzer verwalten'),
  ('permission.finance.approve_payment', 'de', 'Zahlungen freigeben'),
  ('permission.finance.close_period', 'de', 'Perioden abschließen'),
  ('permission.finance.configure', 'de', 'Finanzbuchhaltung konfigurieren'),
  ('permission.finance.post', 'de', 'Journale buchen'),
  ('permission.finance.read', 'de', 'Finanzbuchhaltung ansehen'),
  ('permission.finance.reopen_period', 'de', 'Perioden wieder öffnen'),
  ('permission.inventory.adjust', 'de', 'Bestand korrigieren'),
  ('permission.inventory.count', 'de', 'Inventuren durchführen'),
  ('permission.inventory.move', 'de', 'Bestand bewegen'),
  ('permission.inventory.read', 'de', 'Lager ansehen'),
  ('permission.inventory.write_off', 'de', 'Bestand abschreiben'),
  ('permission.logistics.despatch', 'de', 'Versand bestätigen'),
  ('permission.logistics.plan', 'de', 'Sendungen planen'),
  ('permission.logistics.read', 'de', 'Logistik ansehen'),
  ('permission.master_data.approve', 'de', 'Stammdatenänderungen genehmigen'),
  ('permission.master_data.import', 'de', 'Stammdaten importieren'),
  ('permission.master_data.read', 'de', 'Stammdaten ansehen'),
  ('permission.master_data.write', 'de', 'Stammdaten pflegen'),
  ('permission.planning.firm', 'de', 'Planaufträge fixieren'),
  ('permission.planning.forecast', 'de', 'Prognosen pflegen'),
  ('permission.planning.read', 'de', 'Planung ansehen'),
  ('permission.planning.run', 'de', 'Planung ausführen'),
  ('permission.procurement.approve', 'de', 'Einkauf genehmigen'),
  ('permission.procurement.match', 'de', 'Rechnungen abgleichen'),
  ('permission.procurement.order', 'de', 'Bestellungen erteilen'),
  ('permission.procurement.read', 'de', 'Einkauf ansehen'),
  ('permission.procurement.receive', 'de', 'Waren annehmen'),
  ('permission.procurement.requisition', 'de', 'Bedarfsanforderungen erstellen'),
  ('permission.production.execute', 'de', 'Fertigung erfassen'),
  ('permission.production.order', 'de', 'Fertigungsaufträge anlegen'),
  ('permission.production.read', 'de', 'Fertigung ansehen'),
  ('permission.production.release', 'de', 'Fertigung freigeben'),
  ('permission.quality.disposition', 'de', 'Quarantänebestand entscheiden'),
  ('permission.quality.inspect', 'de', 'Prüfungen erfassen'),
  ('permission.quality.read', 'de', 'Qualität ansehen'),
  ('permission.quality.recall', 'de', 'Rückrufe verwalten'),
  ('permission.quality.release_batch', 'de', 'Chargen freigeben'),
  ('permission.reporting.define', 'de', 'Berichte definieren'),
  ('permission.reporting.export', 'de', 'Daten exportieren'),
  ('permission.reporting.read', 'de', 'Berichte ansehen'),
  ('permission.sales.credit_release', 'de', 'Kreditsperren aufheben'),
  ('permission.sales.despatch', 'de', 'Aufträge versenden'),
  ('permission.sales.discount_approve', 'de', 'Rabatte genehmigen'),
  ('permission.sales.invoice', 'de', 'Rechnungen stellen'),
  ('permission.sales.order', 'de', 'Kundenaufträge erfassen'),
  ('permission.sales.price', 'de', 'Preise pflegen'),
  ('permission.sales.read', 'de', 'Verkauf ansehen'),
  -- Governed views
  ('reporting.view.account_balance', 'de', 'Sachkontensalden'),
  ('reporting.view.ageing', 'de', 'Fälligkeitsstruktur Debitoren und Kreditoren'),
  ('reporting.view.batch', 'de', 'Chargen'),
  ('reporting.view.batch_genealogy', 'de', 'Chargenverwendungsnachweis'),
  ('reporting.view.count_task', 'de', 'Inventuren'),
  ('reporting.view.grni', 'de', 'Wareneingang ohne Rechnung'),
  ('reporting.view.journal_line', 'de', 'Journalzeilen'),
  ('reporting.view.match_exception', 'de', 'Abgleichsabweichungen'),
  ('reporting.view.open_order_book', 'de', 'Offene Aufträge'),
  ('reporting.view.order_fulfilment', 'de', 'Auftragserfüllung'),
  ('reporting.view.planning_exception', 'de', 'Planungsausnahmen'),
  ('reporting.view.purchase_order_status', 'de', 'Bestellstatus'),
  ('reporting.view.quality_event', 'de', 'Qualitätsereignisse'),
  ('reporting.view.recall_impact', 'de', 'Rückruf: betroffene Lieferungen'),
  ('reporting.view.stock_movement', 'de', 'Lagerbewegungen'),
  ('reporting.view.stock_valuation', 'de', 'Bestandsbewertung'),
  ('reporting.view.supplier_performance', 'de', 'Lieferantenbewertung'),
  ('reporting.view.works_order', 'de', 'Fertigungsaufträge'),
  -- Legislation rules and returns
  ('rule.example_vat.energy', 'de', 'Haushaltsenergie zum ermäßigten Satz'),
  ('rule.example_vat.export', 'de', 'Ausfuhren zum Nullsatz'),
  ('rule.example_vat.food', 'de', 'Grundnahrungsmittel zum Nullsatz'),
  ('rule.example_vat.standard', 'de', 'Regelsteuersatz'),
  ('rule.gb_vat.export', 'de', 'Ausfuhren zum Nullsatz'),
  ('rule.gb_vat.food', 'de', 'Lebensmittel zum Nullsatz'),
  ('rule.gb_vat.books', 'de', 'Bücher zum Nullsatz'),
  ('rule.gb_vat.domestic_fuel', 'de', 'Haushaltsenergie zum ermäßigten Satz'),
  ('rule.gb_vat.standard', 'de', 'Regelsteuersatz'),
  ('rule.ie_vat.export', 'de', 'Ausfuhren und innergemeinschaftliche Lieferungen zum Nullsatz'),
  ('rule.ie_vat.food', 'de', 'Lebensmittel zum Nullsatz'),
  ('rule.ie_vat.books', 'de', 'Bücher zum Nullsatz'),
  ('rule.ie_vat.domestic_fuel', 'de', 'Haushaltsenergie zum ermäßigten Satz'),
  ('rule.ie_vat.standard', 'de', 'Regelsteuersatz'),
  ('rule.de_ust.export', 'de', 'Ausfuhr und innergemeinschaftliche Lieferung steuerfrei'),
  ('rule.de_ust.food', 'de', 'Lebensmittel zum ermäßigten Steuersatz'),
  ('rule.de_ust.books', 'de', 'Bücher zum ermäßigten Steuersatz'),
  ('rule.de_ust.standard', 'de', 'Regelsteuersatz'),
  ('output.example_vat.return', 'de', 'Umsatzsteuererklärung'),
  ('output.example_vat.box1', 'de', 'Feld 1: Umsatzsteuer auf Verkäufe'),
  ('output.example_vat.box4', 'de', 'Feld 4: Vorsteuer aus Einkäufen'),
  ('output.example_vat.box5', 'de', 'Feld 5: Zahllast'),
  ('output.gb_vat.return', 'de', 'Umsatzsteuererklärung (VAT Return)'),
  ('output.gb_vat.box1', 'de', 'Feld 1: Umsatzsteuer auf Verkäufe'),
  ('output.gb_vat.box4', 'de', 'Feld 4: Vorsteuer aus Einkäufen'),
  ('output.gb_vat.box5', 'de', 'Feld 5: Zahllast'),
  ('output.ie_vat.vat3', 'de', 'Umsatzsteuererklärung VAT3'),
  ('output.ie_vat.t1', 'de', 'T1: Umsatzsteuer auf Verkäufe'),
  ('output.ie_vat.t2', 'de', 'T2: Vorsteuer aus Einkäufen'),
  ('output.ie_vat.t3', 'de', 'T3: Zahllast'),
  ('output.de_ust.voranmeldung', 'de', 'Umsatzsteuer-Voranmeldung'),
  ('output.de_ust.kz81', 'de', 'Kz 81: Umsätze zum Regelsteuersatz'),
  ('output.de_ust.kz86', 'de', 'Kz 86: Umsätze zum ermäßigten Steuersatz'),
  ('output.de_ust.kz66', 'de', 'Kz 66: Vorsteuer'),
  ('output.de_ust.kz83', 'de', 'Kz 83: verbleibende Zahllast'),
  -- Shell, audit, devices, continuity
  ('action.sign_out', 'de', 'Abmelden'),
  ('adapter.example_http', 'de', 'Beispielhafter HTTP-Adapter'),
  ('adapter.example_http.order_create', 'de', 'Auftrag anlegen'),
  ('adapter.example_http.order_read', 'de', 'Auftrag lesen'),
  ('adapter.example_http.payment_instruct', 'de', 'Zahlung anweisen'),
  ('audit.apply', 'de', 'Filter anwenden'),
  ('audit.blurb', 'de', 'Jede erfasste Aktion in dieser Organisation: wer was an welchem Objekt getan hat, und wann.'),
  ('audit.col_action', 'de', 'Aktion'),
  ('audit.col_actor', 'de', 'Akteur'),
  ('audit.col_fields', 'de', 'Geänderte Felder'),
  ('audit.col_object', 'de', 'Objekt'),
  ('audit.col_reason', 'de', 'Grund'),
  ('audit.col_when', 'de', 'Wann'),
  ('audit.empty', 'de', 'Keine Prüfprotokolleinträge entsprechen diesen Filtern.'),
  ('audit.filter_action', 'de', 'Aktion'),
  ('audit.filter_actor', 'de', 'Akteur'),
  ('audit.filter_from', 'de', 'Von'),
  ('audit.filter_object', 'de', 'Objekttyp'),
  ('audit.filter_to', 'de', 'Bis'),
  ('audit.title', 'de', 'Prüfprotokoll'),
  ('continuity.never_drilled', 'de', 'Nie wiederhergestellt'),
  ('continuity.overdue', 'de', 'Wiederherstellungsübung überfällig'),
  ('device.keyed_needs_reason', 'de', 'Geben Sie an, warum dies getippt statt gescannt wurde'),
  ('device.queued_offline', 'de', 'Gespeichert – wird gesendet, sobald wieder online'),
  ('device.unrecognised_barcode', 'de', 'Dieser Barcode wurde nicht erkannt'),
  ('email.platform_sender', 'de', 'no-reply@cloveerp.com'),
  ('report.deferred_to_extract', 'de', 'Zu groß für die sofortige Anzeige – als Extrakt eingeplant'),
  ('support.access_expired', 'de', 'Der Supportzugang ist abgelaufen'),
  ('support.who_entered', 'de', 'Wer Ihre Daten eingesehen hat'),
  ('notice.incident_affects_you', 'de', 'Dies betrifft Ihre Organisation'),
  ('notice.maintenance_emergency', 'de', 'Notfallwartung'),
  ('notice.maintenance_planned', 'de', 'Geplante Wartung'),
  -- Document types
  ('document.adjustment', 'de', 'Bestandskorrektur'),
  ('document.count', 'de', 'Inventur'),
  ('document.credit_reference', 'de', 'Gutschrift'),
  ('document.delivery', 'de', 'Lieferschein'),
  ('document.invoice_reference', 'de', 'Rechnung'),
  ('document.purchase_order', 'de', 'Bestellung'),
  ('document.quotation', 'de', 'Angebot'),
  ('document.receipt', 'de', 'Wareneingang'),
  ('document.requisition', 'de', 'Bedarfsanforderung'),
  ('document.return_to_supplier', 'de', 'Rücksendung an Lieferanten'),
  ('document.sales_order', 'de', 'Kundenauftrag'),
  ('document.transfer_order', 'de', 'Umlagerungsauftrag'),
  ('document.works_order', 'de', 'Fertigungsauftrag'),
  -- Glossary
  ('glossary.accounting_code', 'de', 'Kontierung'),
  ('glossary.accounting_period', 'de', 'Buchungsperiode'),
  ('glossary.allocation', 'de', 'Zuteilung'),
  ('glossary.analysis_code', 'de', 'Analysekennzeichen'),
  ('glossary.batch', 'de', 'Charge'),
  ('glossary.batch_release', 'de', 'Chargenfreigabe'),
  ('glossary.business_partner', 'de', 'Geschäftspartner'),
  ('glossary.class', 'de', 'Klasse'),
  ('glossary.company', 'de', 'Gesellschaft'),
  ('glossary.confirm_delivery', 'de', 'Lieferung bestätigen'),
  ('glossary.cycle_count', 'de', 'Permanente Inventur'),
  ('glossary.despatch', 'de', 'Versand'),
  ('glossary.detailed_allocation', 'de', 'Detailzuteilung'),
  ('glossary.global_allocation', 'de', 'Globalzuteilung'),
  ('glossary.goods_in', 'de', 'Wareneingang'),
  ('glossary.goods_out', 'de', 'Warenausgang'),
  ('glossary.grni', 'de', 'WE ohne Rechnung'),
  ('glossary.handling_unit', 'de', 'Ladeeinheit'),
  ('glossary.location', 'de', 'Lagerplatz'),
  ('glossary.marshalling_area', 'de', 'Bereitstellungszone'),
  ('glossary.nominal_account', 'de', 'Sachkonto'),
  ('glossary.order_release', 'de', 'Auftragsfreigabe'),
  ('glossary.organisation', 'de', 'Organisation'),
  ('glossary.product', 'de', 'Artikel'),
  ('glossary.promotion', 'de', 'Überführung'),
  ('glossary.purchase_ledger', 'de', 'Kreditorenbuchhaltung'),
  ('glossary.qualified_person', 'de', 'Sachkundige Person'),
  ('glossary.requisition', 'de', 'Bedarfsanforderung'),
  ('glossary.responsible_person', 'de', 'Verantwortliche Person'),
  ('glossary.sales_ledger', 'de', 'Debitorenbuchhaltung'),
  ('glossary.site', 'de', 'Standort'),
  ('glossary.stock', 'de', 'Bestand'),
  ('glossary.stocktake', 'de', 'Inventur'),
  ('glossary.supplier', 'de', 'Lieferant'),
  ('glossary.user', 'de', 'Benutzer'),
  ('glossary.validation', 'de', 'Validierung'),
  ('glossary.works_order', 'de', 'Fertigungsauftrag'),
  -- Guides and migration domains
  ('guide.administrator', 'de', 'Die Organisation einrichten'),
  ('guide.finance', 'de', 'Finanzbuchhaltung'),
  ('guide.planning', 'de', 'Planung'),
  ('guide.procurement', 'de', 'Einkauf'),
  ('guide.production', 'de', 'Fertigung'),
  ('guide.quality', 'de', 'Qualität'),
  ('guide.reporting', 'de', 'Berichtswesen'),
  ('guide.sales', 'de', 'Verkauf'),
  ('guide.warehouse', 'de', 'Lager'),
  ('migration.domain.nominal', 'de', 'Hauptbuch'),
  ('migration.domain.purchase_ledger', 'de', 'Kreditorenbuchhaltung'),
  ('migration.domain.sales_ledger', 'de', 'Debitorenbuchhaltung'),
  ('migration.domain.stock', 'de', 'Bestand'),
  -- Scheduled jobs
  ('job_handler.approval_ageing.name', 'de', 'Alterung und Eskalation von Genehmigungen'),
  ('job_handler.dispatch_notifications.name', 'de', 'Benachrichtigungen versenden'),
  ('job_handler.distribute_subscriptions.name', 'de', 'Berichtsabonnements verteilen'),
  ('job_handler.expire_commercial_quotes.name', 'de', 'Angebote ablaufen lassen'),
  ('job_handler.expire_contracts.name', 'de', 'Verträge ablaufen lassen'),
  ('job_handler.expiry_horizon.name', 'de', 'Verfallshorizont prüfen'),
  ('job_handler.generate_invoice_schedules.name', 'de', 'Rechnungspläne erzeugen'),
  ('job_handler.grni_ageing.name', 'de', 'Alterung Wareneingang ohne Rechnung'),
  ('job_handler.integration_backlog.name', 'de', 'Integrationsrückstand prüfen'),
  ('job_handler.integration_backlog_alert.name', 'de', 'Integrationsrückstand melden'),
  ('job_handler.measure_active_users.name', 'de', 'Aktive Benutzer messen'),
  ('job_handler.produce_extracts.name', 'de', 'Berichtsextrakte erzeugen'),
  ('job_handler.propose_renewals.name', 'de', 'Verlängerungen vorschlagen'),
  ('job_handler.raise_contract_key_dates.name', 'de', 'Vertragstermine melden'),
  ('job_handler.reclaim_expired_commands.name', 'de', 'Abgelaufene Befehle zurückholen'),
  ('job_handler.reclaim_timed_out_runs.name', 'de', 'Abgebrochene Läufe zurückholen'),
  ('job_handler.report_entitlement_breaches.name', 'de', 'Tariflimit-Überschreitungen melden'),
  ('job_handler.report_silent_jobs.name', 'de', 'Stille Jobs melden'),
  ('job_handler.reservation_ageing.name', 'de', 'Alterung von Reservierungen und Bereitstellung'),
  ('job_handler.route_notifications.name', 'de', 'Benachrichtigungen weiterleiten'),
  ('job_handler.sequence_gaps.name', 'de', 'Lücken in Belegnummernkreisen prüfen'),
  ('job_handler.stock_to_ledger.name', 'de', 'Abstimmung Bestand zu Hauptbuch'),
  ('job_handler.suspense_balance.name', 'de', 'Saldo des Zwischenkontos prüfen'),
  -- Movement types
  ('movement.container_move', 'de', 'Umsetzen einer Ladeeinheit'),
  ('movement.count_adjustment', 'de', 'Inventurkorrektur'),
  ('movement.despatch', 'de', 'Versand'),
  ('movement.emergency_issue', 'de', 'Notentnahme'),
  ('movement.goods_receipt', 'de', 'Wareneingang'),
  ('movement.internal_transfer', 'de', 'Interne Umlagerung'),
  ('movement.opening_balance', 'de', 'Eröffnungsbestand'),
  ('movement.pick', 'de', 'Kommissionierung'),
  ('movement.production_issue', 'de', 'Fertigungsentnahme'),
  ('movement.production_output', 'de', 'Fertigungszugang'),
  ('movement.putaway', 'de', 'Einlagerung'),
  ('movement.receipt_no_order', 'de', 'Wareneingang ohne Bestellung'),
  ('movement.replenishment', 'de', 'Nachschub'),
  ('movement.return_from_customer', 'de', 'Kundenrücksendung'),
  ('movement.return_to_supplier', 'de', 'Rücksendung an Lieferanten'),
  ('movement.scrap', 'de', 'Verschrottung'),
  ('movement.status_change', 'de', 'Änderung des Bestandsstatus'),
  -- Navigation
  ('nav.administration_accessibility', 'de', 'Barrierefreiheit'),
  ('nav.administration_adoption', 'de', 'Anleitung und Einführung'),
  ('nav.administration_commercial', 'de', 'Tarif und Nutzung'),
  ('nav.administration_configuration', 'de', 'Konfiguration'),
  ('nav.administration_erasure', 'de', 'Personenbezogene Daten und Löschung'),
  ('nav.administration_onboarding', 'de', 'Einführungsinterview'),
  ('nav.administration_organisation', 'de', 'Organisationsstruktur'),
  ('nav.administration_packs', 'de', 'Funktionen und Inhalte'),
  ('nav.administration_permissions', 'de', 'Benutzer und Berechtigungen'),
  ('nav.audit', 'de', 'Prüfprotokoll'),
  ('nav.commercial_price_book', 'de', 'Preisbuch'),
  ('nav.commercial_quotes', 'de', 'Angebote'),
  ('nav.device', 'de', 'Scanner'),
  ('nav.enter_company', 'de', 'Eine Gesellschaft betreten (protokolliert)'),
  ('nav.finance_account_determination', 'de', 'Kontenfindung'),
  ('nav.governance', 'de', 'Änderungsanträge'),
  ('nav.imports', 'de', 'Importe'),
  ('nav.logistics_release_areas', 'de', 'Bereitstellungszonen'),
  ('nav.master_data', 'de', 'Stammdaten'),
  ('nav.master_data_classification', 'de', 'Kategorien und Nummern'),
  ('nav.master_data_item_supply', 'de', 'Artikel-Lieferanten'),
  ('nav.notifications', 'de', 'Benachrichtigungen'),
  ('nav.operations_assurance', 'de', 'Prüfung'),
  ('nav.operations_continuity', 'de', 'Kontinuität und Störungen'),
  ('nav.operations_cutover', 'de', 'Migration und Umstellung'),
  ('nav.operations_devices', 'de', 'Geräte und Scannen'),
  ('nav.operations_integrations', 'de', 'Integrationen'),
  ('nav.operations_jobs', 'de', 'Wiederkehrende Aufgaben'),
  ('nav.operations_output', 'de', 'Ausgabe und Druck'),
  ('nav.overview', 'de', 'Start'),
  ('nav.platform_console', 'de', 'Plattformkonsole'),
  ('nav.procurement', 'de', 'Einkauf'),
  ('nav.profile', 'de', 'Mein Profil'),
  ('nav.reporting_distribution', 'de', 'Abonnements, Pakete und Extrakte'),
  ('nav.reporting_reproducibility', 'de', 'Berichtsversionen und -läufe'),
  ('nav.sales', 'de', 'Verkauf'),
  ('nav.settings', 'de', 'Einstellungen'),
  ('nav.tenant', 'de', 'Lebenszyklus der Organisation'),
  ('nav.tenant_settings', 'de', 'Organisationseinstellungen'),
  ('nav.terminology', 'de', 'Terminologie'),
  ('nav.work', 'de', 'Arbeit'),
  ('nav.your_company', 'de', 'Ihre Gesellschaft'),
  -- Notifications
  ('notify.approval_escalated.body', 'de', 'Eine Genehmigung wurde nicht rechtzeitig bearbeitet und liegt nun bei Ihnen.'),
  ('notify.approval_escalated.subject', 'de', 'Genehmigung an Sie eskaliert'),
  ('notify.approval_overdue.body', 'de', 'Ein Beleg wartet länger auf Genehmigung, als die Stufe erlaubt.'),
  ('notify.approval_overdue.subject', 'de', 'Genehmigung überfällig'),
  ('notify.approval_requested.body', 'de', 'Ein Beleg wartet auf Ihre Genehmigung.'),
  ('notify.approval_requested.subject', 'de', 'Genehmigung angefordert'),
  ('notify.batch_released.body', 'de', 'Eine Charge wurde unter namentlicher Verantwortung freigegeben und ist verfügbar.'),
  ('notify.batch_released.subject', 'de', 'Charge freigegeben'),
  ('notify.count_variance_above_tolerance.body', 'de', 'Eine Inventur hat eine größere Abweichung ergeben, als ihr Programm zulässt.'),
  ('notify.count_variance_above_tolerance.subject', 'de', 'Inventurabweichung über der Toleranz'),
  ('notify.deviation_raised.body', 'de', 'Zu einer Charge wurde eine Abweichung erfasst; sie braucht eine Untersuchung und eine Korrekturmaßnahme.'),
  ('notify.deviation_raised.subject', 'de', 'Abweichung erfasst'),
  ('notify.expiry_threshold_breached.body', 'de', 'Eine Charge hat weniger Restlaufzeit, als die Mindestrestlaufzeit erlaubt.'),
  ('notify.expiry_threshold_breached.subject', 'de', 'Charge nähert sich dem Verfall'),
  ('notify.integration_backlog_above_threshold.body', 'de', 'Befehle oder Ereignisse warten länger, als der Schwellenwert erlaubt.'),
  ('notify.integration_backlog_above_threshold.subject', 'de', 'Integrationsrückstand'),
  ('notify.job_failed.body', 'de', 'Ein geplanter Job wurde nicht abgeschlossen. Sein Laufprotokoll nennt den Grund.'),
  ('notify.job_failed.subject', 'de', 'Geplanter Job fehlgeschlagen'),
  ('notify.match_exception.body', 'de', 'Eine Lieferantenrechnung stimmte nicht innerhalb der Toleranz mit Bestellung und Wareneingang überein.'),
  ('notify.match_exception.subject', 'de', 'Abweichung beim Rechnungsabgleich'),
  ('notify.order_intake_rejected.body', 'de', 'Ein von einem vorgelagerten System empfangener Auftrag konnte nicht angenommen werden. Der Grund steht am Auftrag.'),
  ('notify.order_intake_rejected.subject', 'de', 'Auftrag beim Eingang abgelehnt'),
  ('notify.period_close_task_overdue.body', 'de', 'Eine Aufgabe des Periodenabschlusses hat ihr Fälligkeitsdatum überschritten; der Abschluss ist blockiert.'),
  ('notify.period_close_task_overdue.subject', 'de', 'Abschlussaufgabe überfällig'),
  ('notify.quality_event_raised.body', 'de', 'Ein Qualitätsereignis wurde erfasst und braucht eine Untersuchung.'),
  ('notify.quality_event_raised.subject', 'de', 'Qualitätsereignis erfasst'),
  ('notify.receipt_discrepancy.body', 'de', 'Ein Wareneingang weicht stärker von seiner Bestellung ab, als die Toleranz erlaubt.'),
  ('notify.receipt_discrepancy.subject', 'de', 'Wareneingang außerhalb der Toleranz'),
  ('notify.stock_shortage_on_release.body', 'de', 'Ein Auftrag konnte nicht vollständig freigegeben werden: der Bestand reicht nicht.'),
  ('notify.stock_shortage_on_release.subject', 'de', 'Bestand bei Freigabe nicht ausreichend'),
  ('notify.support_access_granted.body', 'de', 'Einem Mitglied des Clove-ERP-Supports wurde ein zeitlich begrenztes Zugangsfenster zu Ihrer Organisation gewährt. Einstellungen → Betrieb → Kontinuität zeigt wer, warum und bis wann.'),
  ('notify.support_access_granted.subject', 'de', 'Der Clove-ERP-Support hat Zugang erhalten'),
  -- Output labels
  ('output.address_suppressed', 'de', 'Diese Adresse kann keine Nachrichten empfangen'),
  ('output.block.authorised_by', 'de', 'Genehmigt von'),
  ('output.block.completed_by', 'de', 'Abgeschlossen von'),
  ('output.block.customer', 'de', 'Kunde'),
  ('output.block.deliver_to', 'de', 'Lieferanschrift'),
  ('output.block.despatched_by', 'de', 'Versendet von'),
  ('output.block.invoice_to', 'de', 'Rechnungsanschrift'),
  ('output.block.packed_by', 'de', 'Verpackt von'),
  ('output.block.picked_by', 'de', 'Kommissioniert von'),
  ('output.block.received_by', 'de', 'Angenommen von'),
  ('output.block.return_to', 'de', 'Rücksendung an'),
  ('output.block.supplier', 'de', 'Lieferant'),
  ('output.field.batch', 'de', 'Charge'),
  ('output.field.brand_name', 'de', 'Handelsname'),
  ('output.field.currency', 'de', 'Währung'),
  ('output.field.description', 'de', 'Bezeichnung'),
  ('output.field.document_date', 'de', 'Datum'),
  ('output.field.document_number', 'de', 'Belegnummer'),
  ('output.field.due_date', 'de', 'Fällig'),
  ('output.field.entity_country', 'de', 'Land'),
  ('output.field.entity_name', 'de', 'Gesellschaft'),
  ('output.field.item_code', 'de', 'Artikel'),
  ('output.field.line_count', 'de', 'Positionen'),
  ('output.field.line_no', 'de', 'Pos.'),
  ('output.field.location', 'de', 'Lagerplatz'),
  ('output.field.net_amount', 'de', 'Netto'),
  ('output.field.notes', 'de', 'Bemerkungen'),
  ('output.field.our_reference', 'de', 'Unsere Referenz'),
  ('output.field.party_address', 'de', 'Anschrift'),
  ('output.field.party_name', 'de', 'Name'),
  ('output.field.quantity', 'de', 'Menge'),
  ('output.field.quantity_fulfilled', 'de', 'Erledigt'),
  ('output.field.required_date', 'de', 'Benötigt bis'),
  ('output.field.tax_amount', 'de', 'Steuer'),
  ('output.field.their_reference', 'de', 'Ihre Referenz'),
  ('output.field.total_gross', 'de', 'Gesamt'),
  ('output.field.total_net', 'de', 'Gesamt netto'),
  ('output.field.total_tax', 'de', 'Steuer gesamt'),
  ('output.field.unit_price', 'de', 'Einzelpreis'),
  ('output.field.uom', 'de', 'Einheit'),
  ('output.footer.acknowledgement', 'de', 'Diese Bestätigung bestätigt den Auftrag und ändert seine Bedingungen nicht.'),
  ('output.footer.certificate', 'de', 'Dieses Zertifikat bezieht sich auf die angegebenen Chargen.'),
  ('output.footer.credit_note', 'de', 'Diese Gutschrift bezieht sich auf die angegebene Referenz.'),
  ('output.footer.delivery_note', 'de', 'Bitte prüfen Sie die Ware bei Ankunft und melden Sie Fehlmengen.'),
  ('output.footer.invoice', 'de', 'Die Zahlung ist zum angegebenen Datum fällig.'),
  ('output.footer.pro_forma', 'de', 'Dies ist eine Pro-forma-Rechnung und keine Zahlungsaufforderung.'),
  ('output.footer.purchase_order', 'de', 'Diese Bestellung erfolgt zu den zwischen den Parteien vereinbarten Bedingungen.'),
  ('output.reissued_copy', 'de', 'Kopie'),
  ('output.template.bin_label', 'de', 'Lagerplatzetikett'),
  ('output.template.carton_label', 'de', 'Kartonetikett'),
  ('output.template.certificate_of_analysis', 'de', 'Analysenzertifikat'),
  ('output.template.commercial_invoice', 'de', 'Handelsrechnung'),
  ('output.template.credit_note', 'de', 'Gutschrift'),
  ('output.template.delivery_note', 'de', 'Lieferschein'),
  ('output.template.goods_receipt_note', 'de', 'Wareneingangsschein'),
  ('output.template.order_acknowledgement', 'de', 'Auftragsbestätigung'),
  ('output.template.order_form', 'de', 'Bestellformular'),
  ('output.template.packing_note', 'de', 'Packschein'),
  ('output.template.pallet_label', 'de', 'Palettenetikett'),
  ('output.template.picking_ticket', 'de', 'Kommissionierschein'),
  ('output.template.pro_forma', 'de', 'Pro-forma-Rechnung'),
  ('output.template.purchase_order', 'de', 'Bestellung'),
  ('output.template.report_extract', 'de', 'Berichtsextrakt'),
  ('output.template.returns_label', 'de', 'Rücksendeetikett'),
  ('output.template.transfer_note', 'de', 'Umlagerungsschein'),
  ('output.template.works_order_pack', 'de', 'Fertigungsauftragsmappe'),
  -- The next action of every registered refusal
  ('refusal.cloveerp_amendment_action_unknown.next_action', 'de', 'Verwenden Sie für jede Funktion in der Änderung die Aktion „add“ oder „remove“.'),
  ('refusal.cloveerp_amendment_already_signed.next_action', 'de', 'Nichts zu tun. Entwerfen Sie eine neue Änderung, wenn sich die Bedingungen erneut ändern sollen.'),
  ('refusal.cloveerp_amendment_changes_nothing.next_action', 'de', 'Geben Sie mindestens eine Änderung an: Tarif, eine Berechtigungsstufe, eine Funktion, das Laufzeitende, den Jahreswert, die Verlängerungsart, die Kündigungsfrist oder die Preisanpassungsregel.'),
  ('refusal.cloveerp_amendment_needs_reason.next_action', 'de', 'Geben Sie den Grund für die Änderung an.'),
  ('refusal.cloveerp_amendment_term_ends_before_it_starts.next_action', 'de', 'Wählen Sie ein Laufzeitende nach dem Beginn der aktuellen Laufzeit.'),
  ('refusal.cloveerp_band_has_no_ceiling.next_action', 'de', 'Geben Sie der Stufe eine Obergrenze.'),
  ('refusal.cloveerp_band_unresolvable.next_action', 'de', 'Nennen Sie auf der Stufe mindestens eine Rolle, eine Abteilung, einen benannten Genehmiger oder eine Auflösungsregel.'),
  ('refusal.cloveerp_band_within_plan.next_action', 'de', 'Wählen Sie eine Stufe über dem eigenen Wert des Tarifs für diese Berechtigung, oder belassen Sie den Wert des Tarifs.'),
  ('refusal.cloveerp_contract_already_signed.next_action', 'de', 'Nichts zu tun. Entwerfen Sie eine Änderung, wenn sich die Bedingungen ändern sollen.'),
  ('refusal.cloveerp_contract_has_no_order_form.next_action', 'de', 'Stellen Sie das Angebot aus, damit das Bestellformular erzeugt wird, und legen Sie dann den Vertrag an.'),
  ('refusal.cloveerp_contract_in_force.next_action', 'de', 'Entwerfen Sie eine Änderung mit der Anpassung und lassen Sie beide Parteien unterzeichnen.'),
  ('refusal.cloveerp_contract_not_in_force.next_action', 'de', 'Unterzeichnen Sie zuerst den Vertrag, oder öffnen Sie den Vertrag, der in Kraft ist.'),
  ('refusal.cloveerp_contract_terms_unknown.next_action', 'de', 'Wählen Sie als Verlängerungsart automatisch, nach Vereinbarung oder keine, und als Abrechnungsrhythmus jährlich, vierteljährlich oder monatlich.'),
  ('refusal.cloveerp_currency_not_on_book.next_action', 'de', 'Eröffnen Sie eine Preisbuchversion, die die Währung enthält, oder setzen Sie den Satz in einer, die sie führt.'),
  ('refusal.cloveerp_discount_out_of_range.next_action', 'de', 'Geben Sie einen Rabatt zwischen 0 und 99,99 % ein.'),
  ('refusal.cloveerp_document_is_empty.next_action', 'de', 'Fügen Sie den Inhalt des Dokuments an.'),
  ('refusal.cloveerp_feature_on_plan.next_action', 'de', 'Lassen Sie sie aus dem Angebot; der Tarif enthält sie bereits.'),
  ('refusal.cloveerp_invoice_not_issued.next_action', 'de', 'Stellen Sie zuerst die Rechnung aus und erfassen Sie dann die Zahlung.'),
  ('refusal.cloveerp_invoice_not_scheduled.next_action', 'de', 'Nichts zu tun, wenn sie bereits ausgestellt oder bezahlt ist. Wurde sie storniert, erzeugen Sie den Rechnungsplan erneut.'),
  ('refusal.cloveerp_legislation_is_not_priced.next_action', 'de', 'Setzen Sie den Satz auf null, oder bepreisen Sie den Tarif statt des Pakets.'),
  ('refusal.cloveerp_negative_rate.next_action', 'de', 'Geben Sie einen Satz von null oder mehr ein; wenden Sie stattdessen einen Rabatt auf der Angebotsposition an.'),
  ('refusal.cloveerp_no_entity.next_action', 'de', 'Legen Sie unter Verwaltung die Gesellschaft der Organisation an und öffnen Sie dann das Angebot.'),
  ('refusal.cloveerp_no_platform_organisation.next_action', 'de', 'Ein Plattformeigentümer bestimmt die Plattformorganisation in der Ansicht „Verträge“ der Konsole.'),
  ('refusal.cloveerp_no_rate_on_book.next_action', 'de', 'Setzen Sie den Satz für die Preisposition im Preisbuch in Währung und Laufzeit des Angebots.'),
  ('refusal.cloveerp_non_renewal_has_no_note.next_action', 'de', 'Geben Sie an, wer abgelehnt hat und warum.'),
  ('refusal.cloveerp_not_a_price_item.next_action', 'de', 'Wählen Sie eine Preisposition, oder registrieren Sie den Artikel als solche auf dem Preisbuch-Bildschirm.'),
  ('refusal.cloveerp_not_the_platform_organisation.next_action', 'de', 'Wechseln Sie zur Plattformorganisation, oder bitten Sie einen Plattformeigentümer, eine zu bestimmen.'),
  ('refusal.cloveerp_period_closed.next_action', 'de', 'Öffnen Sie die Periode wieder, oder buchen Sie den Eintrag in eine offene.'),
  ('refusal.cloveerp_permission_denied.next_action', 'de', 'Ein Administrator kann die fehlende Berechtigung auf dem Bildschirm „Berechtigungen“ erteilen.'),
  ('refusal.cloveerp_platform_cannot_contract_with_itself.next_action', 'de', 'Wählen Sie die Kundenorganisation.'),
  ('refusal.cloveerp_quote_already_superseded.next_action', 'de', 'Öffnen Sie die neueste Version und überarbeiten Sie diese.'),
  ('refusal.cloveerp_quote_expired.next_action', 'de', 'Überarbeiten Sie das Angebot; die nächste Version erhält ein neues Gültigkeitsdatum.'),
  ('refusal.cloveerp_quote_has_a_band.next_action', 'de', 'Entfernen Sie zuerst die vorhandene Stufenposition für diese Berechtigung, oder ändern Sie ihre Menge.'),
  ('refusal.cloveerp_quote_has_a_plan.next_action', 'de', 'Entfernen Sie zuerst die vorhandene Tarifposition, oder eröffnen Sie ein separates Angebot.'),
  ('refusal.cloveerp_quote_has_no_order_form.next_action', 'de', 'Stellen Sie das Angebot aus.'),
  ('refusal.cloveerp_quote_has_no_plan.next_action', 'de', 'Fügen Sie zuerst die Tarifposition hinzu.'),
  ('refusal.cloveerp_quote_is_.next_action', 'de', 'Lesen Sie den Zustand des Angebots und die Übergänge, die es anbietet; überarbeiten Sie es, um eine neue Version zu beginnen.'),
  ('refusal.cloveerp_quote_is_empty.next_action', 'de', 'Fügen Sie mindestens die Tarifposition hinzu.'),
  ('refusal.cloveerp_quote_needs_prerequisite.next_action', 'de', 'Fügen Sie die vorausgesetzte Funktion zum Angebot hinzu, oder wählen Sie einen Tarif, der sie enthält.'),
  ('refusal.cloveerp_quote_not_accepted.next_action', 'de', 'Erfassen Sie zuerst die Annahme des Kunden auf dem Angebot.'),
  ('refusal.cloveerp_renewal_not_proposed.next_action', 'de', 'Öffnen Sie das bereits erstellte Verlängerungsangebot, oder warten Sie, bis der Lauf die nächste Laufzeit vorschlägt.'),
  ('refusal.cloveerp_renewal_not_quoted.next_action', 'de', 'Erstellen Sie das Verlängerungsangebot aus dem Vorschlag, lassen Sie den Kunden annehmen und verlängern Sie dann.'),
  ('refusal.cloveerp_signature_incomplete.next_action', 'de', 'Nennen Sie den Unterzeichner des Kunden, den Unterzeichner der Plattform und was die Unterschrift bedeutet.'),
  ('refusal.cloveerp_unknown_amendment.next_action', 'de', 'Öffnen Sie den Vertrag und wählen Sie eine Änderung aus seiner Liste.'),
  ('refusal.cloveerp_unknown_contract.next_action', 'de', 'Wählen Sie einen Vertrag aus der Ansicht „Verträge“ der Konsole.'),
  ('refusal.cloveerp_unknown_invoice.next_action', 'de', 'Öffnen Sie den Vertrag und wählen Sie eine Rechnung aus seinem Rechnungsplan.'),
  ('refusal.cloveerp_unknown_legislation_pack.next_action', 'de', 'Wählen Sie ein Gesetzespaket aus denen, die die Plattform ausliefert.'),
  ('refusal.cloveerp_unknown_price_book.next_action', 'de', 'Eröffnen Sie eine heute gültige Preisbuchversion, oder wählen Sie eine, die es ist.'),
  ('refusal.cloveerp_unknown_price_item_kind.next_action', 'de', 'Wählen Sie eine der Preispositionsarten, die der Preisbuch-Bildschirm anbietet.'),
  ('refusal.cloveerp_unknown_quote.next_action', 'de', 'Wählen Sie ein Angebot auf dem Bildschirm „Angebote“.'),
  ('refusal.cloveerp_unknown_quote_line.next_action', 'de', 'Aktualisieren Sie das Angebot und wählen Sie eine Position daraus.'),
  ('refusal.cloveerp_unknown_renewal.next_action', 'de', 'Wählen Sie eine Verlängerung aus der Liste „Verlängerungen“.'),
  ('refusal.cloveerp_unknown_step.next_action', 'de', 'Laden Sie das Dashboard neu und führen Sie den Schritt aus dem Ersteinrichtungsbereich aus.'),
  ('refusal.cloveerp_unknown_term.next_action', 'de', 'Wählen Sie jährlich, mehrjährig oder monatlich.'),
  ('refusal.cloveerp_untrusted_sweep.next_action', 'de', 'Lassen Sie den geplanten Job ihn ausführen, oder führen Sie ihn als Betreiber aus der Plattformkonsole aus.')
on conflict (key, locale) do update set value = excluded.value;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. A value is converted before it is compared with a band
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.rate_or_inverse(
  p_from character, p_to character, p_on date default null, p_type text default 'spot')
returns numeric
language sql
stable
set search_path = ''
as $$
  select case
           when p_from is null or p_to is null or p_from = p_to then 1::numeric
           else coalesce(erp.rate_on(p_from, p_to, p_on, p_type),
                         1 / nullif(erp.rate_on(p_to, p_from, p_on, p_type), 0))
         end
$$;
revoke all on function erp.rate_or_inverse(character, character, date, text) from public, anon, authenticated;

create or replace function erp.convert_minor(
  p_value_minor bigint, p_from character, p_to character, p_on date default null, p_type text default 'spot')
returns bigint
language plpgsql
stable
set search_path = ''
as $$
declare
  v_rate numeric;
begin
  if p_value_minor is null or p_from is null or p_to is null or p_from = p_to then
    return p_value_minor;
  end if;
  v_rate := erp.rate_or_inverse(p_from, p_to, p_on, p_type);
  if v_rate is null then
    raise exception 'CLOVEERP_NO_RATE: no % rate from % to % on %', p_type, p_from, p_to, coalesce(p_on, current_date)
      using errcode = '22000',
            hint = 'Load a rate with erp_set_exchange_rate, naming its source, or express the value in the band''s currency. A figure converted on a guessed rate routes to the wrong approver quietly.';
  end if;
  return round(p_value_minor * v_rate)::bigint;
end;
$$;
revoke all on function erp.convert_minor(bigint, character, character, date, text) from public, anon, authenticated;

create or replace function erp.load_exchange_rate(
  p_from character, p_to character, p_rate numeric,
  p_valid_from date default null, p_type text default 'spot', p_source text default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('finance.configure', null, null, null, 'exchange_rate', null);

  if not exists (select 1 from erp_ref.currency c where c.code = p_from)
     or not exists (select 1 from erp_ref.currency c where c.code = p_to) then
    raise exception 'CLOVEERP_UNKNOWN_CURRENCY: % or % is not a currency the product knows', p_from, p_to
      using errcode = '23503', hint = 'Use ISO 4217 codes from erp_ref.currency.';
  end if;
  if p_from = p_to then
    raise exception 'CLOVEERP_RATE_SELF: a currency has no rate against itself' using errcode = '23514';
  end if;
  if coalesce(p_rate, 0) <= 0 then
    raise exception 'CLOVEERP_RATE_INVALID: % is not a rate', p_rate
      using errcode = '23514', hint = 'A rate is the number of units of the target currency per unit of the source, and is positive.';
  end if;
  if coalesce(p_type, '') not in ('spot', 'average', 'closing', 'budget', 'fixed') then
    raise exception 'CLOVEERP_RATE_TYPE_UNKNOWN: % is not a rate type', p_type
      using errcode = '23514', hint = 'Rate types are spot, average, closing, budget and fixed.';
  end if;
  if length(coalesce(btrim(p_source), '')) < 3 then
    raise exception 'CLOVEERP_RATE_NEEDS_SOURCE: a rate must say where it came from'
      using errcode = '23514',
            hint = 'Name the source, such as the central bank reference rate and its date; the finance register flags a rate that cannot be traced.';
  end if;

  insert into erp.exchange_rate (tenant_id, from_currency, to_currency, rate_type, rate, valid_from, source)
  values (v_tenant, p_from, p_to, p_type, p_rate, coalesce(p_valid_from, current_date), btrim(p_source))
  on conflict (tenant_id, from_currency, to_currency, rate_type, valid_from) do update
    set rate = excluded.rate, source = excluded.source, updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function erp.load_exchange_rate(character, character, numeric, date, text, text) from public, anon, authenticated;

drop function if exists public.erp_set_exchange_rate(text, text, numeric, date, text, text);
create function public.erp_set_exchange_rate(
  p_from text, p_to text, p_rate numeric,
  p_valid_from date default null, p_type text default 'spot', p_source text default null)
returns uuid
language sql
volatile
set search_path = ''
as $$
  select erp.load_exchange_rate(upper(p_from)::character(3), upper(p_to)::character(3), p_rate, p_valid_from, p_type, p_source)
$$;
revoke all on function public.erp_set_exchange_rate(text, text, numeric, date, text, text) from public, anon;
grant execute on function public.erp_set_exchange_rate(text, text, numeric, date, text, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_exchange_rate', 'erp.load_exchange_rate',
   'Loads or corrects an exchange rate for the organisation, with its source; gated on finance.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- The resolver compares the value in each band's own currency.
do $approval$
declare
  v_def text := pg_get_functiondef('erp.resolve_approval_chain(text,bigint,character,uuid,uuid,uuid,uuid,date)'::regprocedure);
  v_n1  text := E'         and ab.lower_bound_minor <= p_value_minor';
  v_n2  text := E'         and p_value_minor >= r.upper_bound_minor';
  v_n3  text := E'        ''upper_bound_minor'', r.upper_bound_minor);';
begin
  if (select count(*) from regexp_matches(v_def, 'and ab\.lower_bound_minor <= p_value_minor', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'and p_value_minor >= r\.upper_bound_minor', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, '''upper_bound_minor'', r\.upper_bound_minor\);', 'g')) <> 1 then
    raise exception 'CLOVEERP_RESOLVER_UNRECOGNISED: erp.resolve_approval_chain is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'         and ab.lower_bound_minor <= erp.convert_minor(p_value_minor, p_currency, ab.currency, v_on)');
  v_def := replace(v_def, v_n2,
       E'         and erp.convert_minor(p_value_minor, p_currency, r.currency, v_on) >= r.upper_bound_minor');
  v_def := replace(v_def, v_n3,
       E'        ''upper_bound_minor'', r.upper_bound_minor,\n'
    || E'        ''band_currency'', r.currency,\n'
    || E'        ''value_in_band_currency_minor'', erp.convert_minor(p_value_minor, p_currency, r.currency, v_on));');
  execute v_def;
end
$approval$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. An order between two companies is one event
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('document.mirrored', 1, 'document', 'sales', 'event.document.mirrored',
        'A sales order to another company of the organisation was mirrored as a purchase order in that company; the two are linked and this is the one event.',
        '{"type":"object","required":["sales_order_id","sales_order_number","purchase_order_number","selling_entity","buying_entity","currency","exchange_rate"],
          "properties":{"sales_order_id":{"type":"string"},"sales_order_number":{"type":"string"},
                        "purchase_order_number":{"type":"string"},"selling_entity":{"type":"string"},
                        "buying_entity":{"type":"string"},"currency":{"type":"string"},
                        "exchange_rate":{"type":"number"},"site":{"type":"string"}}}',
        true)
on conflict (code, version) do update
  set description = excluded.description, payload_schema = excluded.payload_schema, is_current = excluded.is_current;

create or replace function erp.raise_intercompany_order(p_sales_order_id uuid, p_site_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  so        erp.document%rowtype;
  sdt       erp.document_type%rowtype;
  v_seller  erp.entity%rowtype;
  v_buyer   erp.entity%rowtype;
  v_type    text;
  v_rate    numeric;
  v_po      uuid;
  v_po_no   text;
  v_site    text;
  l         record;
begin
  select * into so from erp.document where tenant_id = v_tenant and id = p_sales_order_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_sales_order_id using errcode = '23503';
  end if;
  select * into sdt from erp.document_type where tenant_id = v_tenant and id = so.document_type_id;
  if sdt.base_type_code <> 'sales_order' then
    raise exception 'CLOVEERP_NOT_A_SALES_ORDER: % is a %', so.document_number, sdt.code
      using errcode = '23514', hint = 'An intercompany order mirrors a sales order; open the sales order and raise it from there.';
  end if;
  if so.is_cancelled then
    raise exception 'CLOVEERP_DOCUMENT_CANCELLED: % is cancelled', so.document_number using errcode = '23514';
  end if;

  select * into v_seller from erp.entity where tenant_id = v_tenant and id = so.entity_id;
  select * into v_buyer from erp.entity e
   where e.tenant_id = v_tenant and e.party_id = so.party_id and e.status = 'active';
  if not found or v_buyer.id = v_seller.id then
    raise exception 'CLOVEERP_NOT_INTERCOMPANY: the customer on % is not another company of this organisation', so.document_number
      using errcode = '23514',
            hint = 'An intercompany order is a sales order whose customer is one of the organisation''s own companies (erp.entity.party_id). For an outside customer there is nothing to mirror.';
  end if;

  if exists (select 1 from erp.document_relation rel
              join erp.document po on po.id = rel.from_document_id
             where rel.tenant_id = v_tenant and rel.to_document_id = p_sales_order_id
               and rel.relation_kind = 'mirrors' and not po.is_cancelled) then
    raise exception 'CLOVEERP_ALREADY_MIRRORED: % already has a purchase order in %', so.document_number, v_buyer.code
      using errcode = '23505', hint = 'Open the linked purchase order; cancel it first if it must be raised again.';
  end if;

  select s.code into v_site from erp.site s
   where s.tenant_id = v_tenant and s.id = p_site_id and s.entity_id = v_buyer.id and s.status = 'active';
  if v_site is null then
    raise exception 'CLOVEERP_SITE_NOT_IN_COMPANY: the receiving site is not a site of %', v_buyer.code
      using errcode = '23503', hint = 'Name a site that belongs to the buying company; the purchase order is received there.';
  end if;

  -- The buying company's purchase order type: its own if it has one, else the
  -- organisation's.
  select dt.code into v_type from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'purchase_order' and dt.status = 'active'
   order by (dt.entity_id = v_buyer.id) desc, (dt.entity_id is null) desc, dt.code
   limit 1;
  if v_type is null then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT_TYPE: no purchase order type is configured'
      using errcode = '23503', hint = 'Install the procurement module (erp.configure_procurement) before raising intercompany orders.';
  end if;

  -- The mirror is in the buyer's own currency, at a rate the organisation
  -- loaded and can name, stamped on the document.
  v_rate := erp.rate_or_inverse(so.currency, v_buyer.base_currency, so.document_date);
  if v_rate is null then
    raise exception 'CLOVEERP_NO_RATE: no spot rate from % to % on %', so.currency, v_buyer.base_currency, so.document_date
      using errcode = '22000',
            hint = 'Load a rate with erp_set_exchange_rate, naming its source; the mirrored order is priced in the buying company''s currency.';
  end if;

  v_po := erp.open_document(v_type, v_seller.party_id, v_buyer.id, p_site_id,
                            so.document_number, so.required_date, v_buyer.base_currency);
  update erp.document
     set exchange_rate = v_rate,
         our_reference = so.document_number,
         notes = format('Mirror of sales order %s raised by %s', so.document_number, v_seller.code),
         updated_at = now()
   where id = v_po;

  for l in
    select dl.item_id, dl.quantity, dl.unit_price_minor, dl.description, dl.required_date
      from erp.document_line dl
     where dl.tenant_id = v_tenant and dl.document_id = p_sales_order_id and not dl.is_cancelled
     order by dl.line_no
  loop
    perform erp.add_document_line(v_po, l.item_id, l.quantity,
                                  round(coalesce(l.unit_price_minor, 0) * v_rate)::bigint,
                                  l.description, l.required_date);
  end loop;

  perform erp.link_documents(v_po, p_sales_order_id, 'mirrors');

  select document_number into v_po_no from erp.document where id = v_po;
  perform erp.append_event('document.mirrored', 'document', v_po,
    jsonb_build_object('sales_order_id', p_sales_order_id, 'sales_order_number', so.document_number,
                       'purchase_order_number', v_po_no, 'selling_entity', v_seller.code,
                       'buying_entity', v_buyer.code, 'currency', v_buyer.base_currency,
                       'exchange_rate', v_rate, 'site', v_site),
    v_buyer.id, p_site_id);

  return v_po;
end;
$$;
revoke all on function erp.raise_intercompany_order(uuid, uuid) from public, anon, authenticated;

comment on function erp.raise_intercompany_order is
  'Mirrors a sales order to another company of the organisation as a purchase '
  'order in that company, at the site named, in its own currency with the rate '
  'stamped and the lines converted; links the two as mirrors and appends one '
  'event. The purchase order follows its own lifecycle from draft.';

drop function if exists public.erp_raise_intercompany_order(uuid, uuid);
create function public.erp_raise_intercompany_order(p_sales_order_id uuid, p_site_id uuid)
returns uuid
language sql
volatile
set search_path = ''
as $$
  select erp.raise_intercompany_order(p_sales_order_id, p_site_id)
$$;
revoke all on function public.erp_raise_intercompany_order(uuid, uuid) from public, anon;
grant execute on function public.erp_raise_intercompany_order(uuid, uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_raise_intercompany_order', 'erp.raise_intercompany_order',
   'Mirrors an intercompany sales order as a purchase order in the buying company; the purchase order is opened through erp.open_document, which authorises the buyer''s create permission.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

update erp_ref.part5_capability
   set status = 'built',
       artefacts = array['erp.open_document(text,uuid,uuid,uuid,text,date,character)', 'erp.command',
                         'erp.raise_intercompany_order(uuid,uuid)', 'public.erp_raise_intercompany_order(uuid,uuid)'],
       gap = null
 where code = '5.6.order_capture';

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suites
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.locale_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_ui_key text; v_ui_en text;
  v_n integer; v_m integer;
  v_msg text; v_out text;
  res jsonb;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-locale', 'Locale suite', 'admin@zz-locale.test', 'Locale Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d6', 'admin@zz-locale.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d6')::text, true);
  perform erp.claim_invitation(v_token);

  select r.key, r.value into v_ui_key, v_ui_en from erp_ref.resource r
   where r.locale = 'en' and r.key like 'ui.%'
     and not exists (select 1 from erp_ref.resource d where d.key = r.key and d.locale = 'de')
   order by r.key limit 1;

  -- 1. The chain ends in English, and the gate is green in German.
  v_cases := v_cases + 1;
  v_out := erp.assert_resource_coverage_de();
  case_name := 'every locale chain ends in English, and every gated key has a German string';
  passed := erp.locale_chain('de') = array['de', 'en']
        and erp.locale_chain('de-AT') = array['de-AT', 'de', 'en']
        and erp.locale_chain('en') = array['en']
        and erp.locale_chain('en-IE') = array['en-IE', 'en']
        and v_out like 'resources: every referenced key resolves in de%';
  detail := format('de → %s; de-AT → %s; %s', array_to_string(erp.locale_chain('de'), ','), array_to_string(erp.locale_chain('de-AT'), ','), v_out);
  return next;

  -- 2. A core word is German.
  v_cases := v_cases + 1;
  case_name := 'a glossary word, a module and a permission read in German';
  passed := erp.text('glossary.batch', 'de') = 'Charge'
        and erp.text('module.inventory', 'de') = 'Lager'
        and erp.text('permission.sales.invoice', 'de') = 'Rechnungen stellen';
  detail := format('%s / %s / %s', erp.text('glossary.batch', 'de'), erp.text('module.inventory', 'de'), erp.text('permission.sales.invoice', 'de'));
  return next;

  -- 3. A label with no German is served in English, never as its key.
  v_cases := v_cases + 1;
  case_name := 'a label the pack does not carry is served in English rather than as its key';
  passed := v_ui_key is not null and erp.text(v_ui_key, 'de') = v_ui_en and erp.text(v_ui_key, 'de') <> v_ui_key;
  detail := format('%s in de → %s', v_ui_key, left(erp.text(v_ui_key, 'de'), 60));
  return next;

  -- 4. Austrian German falls through German to English.
  v_cases := v_cases + 1;
  case_name := 'de-AT falls through de, then en';
  passed := erp.text('glossary.batch', 'de-AT') = 'Charge' and erp.text(v_ui_key, 'de-AT') = v_ui_en;
  detail := format('glossary.batch → %s; %s → English', erp.text('glossary.batch', 'de-AT'), v_ui_key);
  return next;

  -- 5. The untranslated report and its door agree, and name the right keys.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.untranslated_report('de');
  select count(*) into v_m from public.erp_untranslated('de');
  case_name := 'the untranslated report lists what German still serves from English, and the door returns the same';
  passed := v_n > 0 and v_n = v_m
        and exists (select 1 from erp.untranslated_report('de') u where u.key = v_ui_key and u.served_from = 'en' and not u.is_tenant_term)
        and not exists (select 1 from erp.untranslated_report('de') u where u.key = 'glossary.batch')
        and not exists (select 1 from erp.untranslated_report('en'));
  detail := format('%s key(s) served from English in de; glossary.batch absent; en reports nothing', v_n);
  return next;

  -- 6. A tenant-defined term.
  v_cases := v_cases + 1;
  res := public.erp_set_resource_override('custom.pallet_word', 'Skid', 'en', 'what the floor calls a pallet');
  v_n := (select count(*) from erp.untranslated_report('de') u where u.key = 'custom.pallet_word' and u.is_tenant_term);
  perform public.erp_set_resource_override('custom.pallet_word', 'Palette', 'de');
  v_m := (select count(*) from erp.untranslated_report('de') u where u.key = 'custom.pallet_word');
  case_name := 'a tenant defines a word under custom.: the bundle carries it, the text resolver finds it, German reports it until translated';
  passed := (res ->> 'tenant_term')::boolean
        and public.erp_resources('en') ->> 'custom.pallet_word' = 'Skid'
        and erp.text('custom.pallet_word', 'en') = 'Skid'
        and v_n = 1
        and erp.text('custom.pallet_word', 'de') = 'Palette'
        and public.erp_resources('de') ->> 'custom.pallet_word' = 'Palette'
        and v_m = 0;
  detail := format('en bundle: %s; de text: %s; untranslated in de before %s, after %s',
                   public.erp_resources('en') ->> 'custom.pallet_word', erp.text('custom.pallet_word', 'de'), v_n, v_m);
  return next;

  -- 7. An unknown key outside custom. is refused by name.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    perform public.erp_set_resource_override('glossary.no_such_word', 'Nothing', 'en');
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a key the product never shipped, outside custom., is refused by name';
  passed := coalesce(v_msg like 'CLOVEERP_UNKNOWN_RESOURCE_KEY:%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 160);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 8. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-locale')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d6');
  detail := 'zz-locale rolled back with its terms';
  return next;

  if v_cases <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: locale_suite ran % cases, expected 8', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_locale_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _locale on commit drop as
    select * from erp_test.locale_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _locale;
  drop table _locale;
  if v_fail > 0 then
    raise exception E'CLOVEERP_LOCALE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: locale_suite ran % cases, expected 8', v_all;
  end if;
  return format('locale: %s/%s cases passed', v_all, v_all);
end;
$$;

create or replace function erp_test.approval_currency_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_approver uuid; v_dept uuid;
  v_chain jsonb;
  v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-approval-ccy', 'Approval currency suite', 'admin@zz-approval-ccy.test', 'Approval Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d7', 'admin@zz-approval-ccy.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d7')::text, true);
  perform erp.claim_invitation(v_token);

  insert into erp.app_user (tenant_id, kind, status, display_name, email)
  values (v_tenant, 'person', 'active', 'Zz Approver', 'approver@zz-approval-ccy.test')
  returning id into v_approver;
  v_dept := (erp.upsert_department('ZZ-BUY', 'Zz Einkauf', v_approver) ->> 'department_id')::uuid;
  -- One band: purchase orders of £800 and above go to the approver.
  perform erp.upsert_approval_band(v_dept, 'purchase_order', 1, null, 80000, v_approver, null, false, 'GBP');

  -- 1. Same currency: no conversion, the step records the band's currency.
  v_cases := v_cases + 1;
  v_chain := erp.resolve_approval_chain('purchase_order', 100000, 'GBP', v_dept, v_admin);
  case_name := 'a value in the band''s own currency is compared as it is, and the step says which currency';
  passed := jsonb_array_length(v_chain -> 'steps') = 1
        and v_chain -> 'steps' -> 0 ->> 'band_currency' = 'GBP'
        and (v_chain -> 'steps' -> 0 ->> 'value_in_band_currency_minor')::bigint = 100000
        and v_chain -> 'steps' -> 0 ->> 'approver_user_id' = v_approver::text;
  detail := format('%s step(s); band %s, value %s', jsonb_array_length(v_chain -> 'steps'),
                   v_chain -> 'steps' -> 0 ->> 'band_currency', v_chain -> 'steps' -> 0 ->> 'value_in_band_currency_minor');
  return next;

  -- 2. Another currency with no rate is refused by name.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    v_chain := erp.resolve_approval_chain('purchase_order', 100000, 'EUR', v_dept, v_admin);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a value in a currency the organisation has no rate for is refused, not compared as a bare number';
  passed := coalesce(v_msg like 'CLOVEERP_NO_RATE:%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 160);
  return next;

  -- 3. A rate through the door converts the value into the band.
  v_cases := v_cases + 1;
  perform public.erp_set_exchange_rate('EUR', 'GBP', 0.85, current_date, 'spot', 'ECB euro reference rate, suite fixture');
  v_chain := erp.resolve_approval_chain('purchase_order', 100000, 'EUR', v_dept, v_admin);
  case_name := 'with a rate loaded through the door, €1,000 converts to £850 and lands in the £800 band';
  passed := jsonb_array_length(v_chain -> 'steps') = 1
        and (v_chain -> 'steps' -> 0 ->> 'value_in_band_currency_minor')::bigint = 85000
        and v_chain -> 'steps' -> 0 ->> 'band_currency' = 'GBP'
        and v_chain ->> 'currency' = 'EUR';
  detail := format('%s step(s); €100000 → %s GBP minor', jsonb_array_length(v_chain -> 'steps'), v_chain -> 'steps' -> 0 ->> 'value_in_band_currency_minor');
  return next;

  -- 4. A converted value below the band finds no approver.
  v_cases := v_cases + 1;
  v_chain := erp.resolve_approval_chain('purchase_order', 90000, 'EUR', v_dept, v_admin);
  case_name := '€900 converts to £765 and falls below the £800 band: no step, chain exhausted';
  passed := jsonb_array_length(v_chain -> 'steps') = 0 and (v_chain ->> 'exhausted')::boolean;
  detail := format('%s step(s), exhausted %s', jsonb_array_length(v_chain -> 'steps'), v_chain ->> 'exhausted');
  return next;

  -- 5. Only the inverse rate is loaded; the resolver derives the direct one.
  v_cases := v_cases + 1;
  delete from erp.exchange_rate where tenant_id = v_tenant;
  perform erp.load_exchange_rate('GBP', 'EUR', 1.25, current_date, 'spot', 'ECB euro reference rate, suite fixture, inverse');
  v_chain := erp.resolve_approval_chain('purchase_order', 100000, 'EUR', v_dept, v_admin);
  case_name := 'with only GBP→EUR loaded, EUR→GBP is derived as its inverse: €1,000 is £800, exactly the band''s floor';
  passed := jsonb_array_length(v_chain -> 'steps') = 1
        and (v_chain -> 'steps' -> 0 ->> 'value_in_band_currency_minor')::bigint = 80000
        and erp.convert_minor(100000, 'EUR', 'GBP') = 80000;
  detail := format('%s step(s); converted %s', jsonb_array_length(v_chain -> 'steps'), erp.convert_minor(100000, 'EUR', 'GBP'));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 6. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-approval-ccy')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d7');
  detail := 'zz-approval-ccy rolled back with its band and rates';
  return next;

  if v_cases <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: approval_currency_suite ran % cases, expected 6', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_approval_currency_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _approval_ccy on commit drop as
    select * from erp_test.approval_currency_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _approval_ccy;
  drop table _approval_ccy;
  if v_fail > 0 then
    raise exception E'CLOVEERP_APPROVAL_CURRENCY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: approval_currency_suite ran % cases, expected 6', v_all;
  end if;
  return format('approval currency: %s/%s cases passed', v_all, v_all);
end;
$$;

create or replace function erp_test.intercompany_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_a uuid; v_b uuid; v_site_a uuid; v_site_b uuid; v_b_party uuid; v_a_party uuid;
  v_item1 uuid; v_item2 uuid; v_customer uuid;
  v_so uuid; v_so2 uuid; v_so3 uuid; v_po uuid;
  v_msg text;
  v_n integer;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-interco', 'Intercompany suite', 'admin@zz-interco.test', 'Interco Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d8', 'admin@zz-interco.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d8')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.party_id into v_a, v_a_party from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select s.id into v_site_a from erp.site s where s.tenant_id = v_tenant and s.entity_id = v_a order by s.code limit 1;
  select i.id into v_item1 from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;
  select i.id into v_item2 from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code offset 1 limit 1;
  select pr.party_id into v_customer from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id limit 1;

  v_b := erp.create_entity('ZZ-EU', 'Zz Europe', 'Zz Europe BV', 'EUR', 'NL', 'nl', 'nl', 1::smallint);
  select e.party_id into v_b_party from erp.entity e where e.id = v_b;
  v_site_b := erp.create_site('ZZ-EU-WH', 'Zz Europe warehouse', 'warehouse', v_b);

  -- A sales order in the first company to the second company, two lines.
  v_so := erp.open_document('sales_order', v_b_party, v_a, v_site_a, 'interco', null, null);
  perform erp.add_document_line(v_so, v_item1, 10, 1000, 'intercompany line one');
  perform erp.add_document_line(v_so, v_item2, 5, 2500, 'intercompany line two');

  -- 1. No rate, no mirror.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    perform erp.raise_intercompany_order(v_so, v_site_b);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a GBP order to a EUR company cannot be mirrored without a rate, and says so';
  passed := coalesce(v_msg like 'CLOVEERP_NO_RATE:%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 160);
  return next;

  -- 2. With a rate, the mirror is raised in the buyer's currency.
  v_cases := v_cases + 1;
  perform erp.load_exchange_rate('GBP', 'EUR', 1.2, current_date, 'spot', 'suite fixture rate');
  v_po := public.erp_raise_intercompany_order(v_so, v_site_b);
  case_name := 'the purchase order is raised in the buying company, at its site, in its currency, with the rate stamped and the lines converted';
  passed := exists (select 1 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
                     where d.id = v_po and d.tenant_id = v_tenant and d.entity_id = v_b and d.site_id = v_site_b
                       and d.party_id = v_a_party and d.currency = 'EUR' and d.exchange_rate = 1.2
                       and dt.base_type_code = 'purchase_order'
                       and d.our_reference = (select document_number from erp.document where id = v_so))
        and (select count(*) from erp.document_line dl where dl.document_id = v_po) = 2
        and exists (select 1 from erp.document_line dl where dl.document_id = v_po and dl.item_id = v_item1 and dl.quantity = 10 and dl.unit_price_minor = 1200)
        and exists (select 1 from erp.document_line dl where dl.document_id = v_po and dl.item_id = v_item2 and dl.quantity = 5 and dl.unit_price_minor = 3000);
  detail := (select format('%s in %s for %s EUR at rate %s, %s line(s)', d.document_number, e.code,
                           (select sum(dl.net_minor) from erp.document_line dl where dl.document_id = v_po), d.exchange_rate,
                           (select count(*) from erp.document_line dl where dl.document_id = v_po))
               from erp.document d join erp.entity e on e.id = d.entity_id where d.id = v_po);
  return next;

  -- 3. Linked as a mirror, and one event says so.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.event ev
   where ev.tenant_id = v_tenant and ev.event_type = 'document.mirrored' and ev.aggregate_id = v_po
     and ev.payload ->> 'buying_entity' = 'ZZ-EU' and ev.payload ->> 'selling_entity' = (select code from erp.entity where id = v_a);
  case_name := 'the two documents are linked as mirrors and document.mirrored was appended once';
  passed := exists (select 1 from erp.document_relation rel
                     where rel.tenant_id = v_tenant and rel.from_document_id = v_po and rel.to_document_id = v_so and rel.relation_kind = 'mirrors')
        and v_n = 1;
  detail := format('mirrors relation present; %s document.mirrored event(s)', v_n);
  return next;

  -- 4. Not twice.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    perform erp.raise_intercompany_order(v_so, v_site_b);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'raising the mirror again is refused by name';
  passed := coalesce(v_msg like 'CLOVEERP_ALREADY_MIRRORED:%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 160);
  return next;

  -- 5. An outside customer's order has nothing to mirror.
  v_cases := v_cases + 1;
  v_so2 := erp.open_document('sales_order', v_customer, v_a, v_site_a, null, null, null);
  perform erp.add_document_line(v_so2, v_item1, 1, 1000, 'ordinary customer');
  v_msg := null;
  begin
    perform erp.raise_intercompany_order(v_so2, v_site_b);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a sales order to an outside customer is not intercompany and is refused by name';
  passed := coalesce(v_msg like 'CLOVEERP_NOT_INTERCOMPANY:%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 160);
  return next;

  -- 6. The receiving site must belong to the buyer.
  v_cases := v_cases + 1;
  v_so3 := erp.open_document('sales_order', v_b_party, v_a, v_site_a, null, null, null);
  perform erp.add_document_line(v_so3, v_item1, 1, 1000, 'wrong site');
  v_msg := null;
  begin
    perform erp.raise_intercompany_order(v_so3, v_site_a);
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a receiving site outside the buying company is refused by name';
  passed := coalesce(v_msg like 'CLOVEERP_SITE_NOT_IN_COMPANY:%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 160);
  return next;

  -- 7. The mirror has its own lifecycle, and the sales order kept its number and currency.
  v_cases := v_cases + 1;
  case_name := 'the purchase order starts its own lifecycle in draft; the sales order is untouched';
  passed := exists (select 1 from erp.object_state os join erp.state s on s.id = os.current_state_id
                     where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = v_po and s.is_initial)
        and exists (select 1 from erp.document d where d.id = v_so and d.currency = 'GBP' and d.exchange_rate is null and d.entity_id = v_a)
        and (select count(*) from erp.document_line dl where dl.document_id = v_so) = 2;
  detail := format('purchase order state %s; sales order still GBP with 2 line(s)',
                   (select s.code from erp.object_state os join erp.state s on s.id = os.current_state_id
                     where os.object_type = 'document' and os.object_id = v_po));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 8. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-interco')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d8');
  detail := 'zz-interco rolled back with both companies and their orders';
  return next;

  if v_cases <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: intercompany_suite ran % cases, expected 8', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_intercompany_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _intercompany on commit drop as
    select * from erp_test.intercompany_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _intercompany;
  drop table _intercompany;
  if v_fail > 0 then
    raise exception E'CLOVEERP_INTERCOMPANY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: intercompany_suite ran % cases, expected 8', v_all;
  end if;
  return format('intercompany: %s/%s cases passed', v_all, v_all);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage();
select erp.assert_resource_coverage_de();
select erp_test.assert_locale_suite();
select erp_test.assert_approval_currency_suite();
select erp_test.assert_intercompany_suite();
select erp_test.assert_companies_suite();
select erp_test.assert_legislation_packs_suite();
select erp_test.assert_first_run_guidance_suite();
select erp_test.assert_output_template_suite();
select erp_test.assert_onboarding_interview_suite();
select erp_test.assert_sales_depth_suite();
select erp.assert_whole_database_reconciles();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_configuration_promotable();
select erp.assert_packs_installable();
select erp.assert_part5_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- And the whole console, green.
do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
