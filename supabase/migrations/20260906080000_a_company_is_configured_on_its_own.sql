-- A company is configured on its own.
--
-- The product had companies in the schema and one company in practice. Every
-- installer picked the first active entity by code and configured that one:
-- the finance installer gave it the ledgers, the periods and the chart, the
-- procurement and sales installers bound their document types and number
-- series to it, and the posting bridge posted every document to the ledger the
-- rule named, whichever company the document belonged to. The second company
-- the demonstration carries was created by a raw insert, and the migration
-- that added it fixed the resulting misplacement by renaming the trading
-- company so it sorted first (20260905030000 says so in its header). A company
-- had no door to be created through, no promoter kind to arrive by, and no
-- question in the onboarding interview to be asked about.
--
-- This file gives a company a way in and a finance installation of its own.
--
-- A company is created on purpose: erp.create_entity() behind a door, and an
-- `entity` kind in the promoter so a company arrives by change set like every
-- other piece of configuration. The onboarding interview gains a section,
-- "organisation shape": how many companies, in which currencies and
-- countries, under which legislation, costing how, identifying handling units
-- at what level, allocating by what method. Its answers propose companies,
-- legislation bindings, a costing policy, an identity policy and the
-- allocation setting, each through the promoter.
--
-- Finance is installed per company. erp.configure_finance() takes the company;
-- named or not, it gives that company its own general and commitment ledgers,
-- twelve periods from the company's own fiscal year start (the old installer
-- wrote January to December whatever the company said), and the accounts the
-- purpose register says an installer creates. Posting rules stay the
-- organisation's: one rule per event, ledger named by code, and the bridge
-- now resolves that code inside the document's own company, so a goods
-- receipt in the Dutch company posts to the Dutch general ledger. A rule may
-- still be promoted for one company alone, and the promoter supersedes rules
-- within a company rather than across all of them.
--
-- What does not change, and why. Document types and number series remain the
-- organisation's (one `sales_order`, one `INV-` series); a company-specific
-- series and the order types that go with it are Phase 8's, under 5.3. The
-- default when no company is named is still the first by code, because the
-- demonstration and its suites pin that. The statutory chart pack still
-- places its accounts on the first company; a second company under the
-- statutory chart is later work, and the header of 20260905030000 remains the
-- honest account of it. erp.create_site() still defaults to the first company
-- by creation date rather than by code, two rules where there should be one;
-- recorded, not fixed here.
--
-- One thing is added early for a later file: a relation kind, `mirrors`, for
-- an order in one company mirrored as an order in another. An enum value
-- added in a transaction cannot be used in the same transaction, so it is
-- declared here and used in 20260906082000.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A relation kind for a later file
-- ═════════════════════════════════════════════════════════════════════════════

alter type erp.document_relation_kind add value if not exists 'mirrors';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A company is created on purpose
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.upsert_entity(
  p_code                    text,
  p_name                    text,
  p_legal_name              text default null,
  p_base_currency           character default null,
  p_country_code            character default null,
  p_reporting_locale        text default 'en',
  p_document_locale         text default 'en',
  p_fiscal_year_start_month smallint default 1,
  p_parent_code             text default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_code   text := erp.slug_code(p_code);
  v_ccy    char(3);
  v_ctry   char(2);
  v_parent uuid;
  v_id     uuid;
begin
  if v_code is null or coalesce(btrim(p_name), '') = '' then
    raise exception 'CLOVEERP_ENTITY_CODE_REQUIRED: a company needs a code and a name'
      using errcode = '23514',
            hint = 'Give the company a short code (letters, digits, dashes) and its trading name.';
  end if;

  -- Defaults follow the organisation's first company: the currency and the
  -- country it was provisioned with.
  select coalesce(p_base_currency, e.base_currency), coalesce(p_country_code, e.country_code)
    into v_ccy, v_ctry
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
   order by e.code limit 1;
  v_ccy  := coalesce(v_ccy, p_base_currency, 'GBP');
  v_ctry := coalesce(v_ctry, p_country_code);

  if not exists (select 1 from erp_ref.currency c where c.code = v_ccy) then
    raise exception 'CLOVEERP_UNKNOWN_CURRENCY: % is not a currency the product knows', v_ccy
      using errcode = '23503', hint = 'Use an ISO 4217 code from erp_ref.currency.';
  end if;
  if v_ctry is not null and not exists (select 1 from erp_ref.country c where c.code = v_ctry) then
    raise exception 'CLOVEERP_UNKNOWN_COUNTRY: % is not a country the product knows', v_ctry
      using errcode = '23503', hint = 'Use an ISO 3166-1 alpha-2 code from erp_ref.country.';
  end if;
  if not exists (select 1 from erp_ref.locale l where l.code = coalesce(p_reporting_locale, 'en') and l.is_active)
     or not exists (select 1 from erp_ref.locale l where l.code = coalesce(p_document_locale, 'en') and l.is_active) then
    raise exception 'CLOVEERP_UNKNOWN_LOCALE: % or % is not an active locale', p_reporting_locale, p_document_locale
      using errcode = '23503', hint = 'Choose a locale from erp_ref.locale; de, de-AT, de-CH, en, en-GB, en-IE, en-US, fr, nl and others are active.';
  end if;
  if coalesce(p_fiscal_year_start_month, 1) not between 1 and 12 then
    raise exception 'CLOVEERP_FISCAL_YEAR_START_INVALID: % is not a month', p_fiscal_year_start_month
      using errcode = '23514', hint = 'The fiscal year starts in a month numbered 1 to 12.';
  end if;
  if p_parent_code is not null then
    select e.id into v_parent from erp.entity e
     where e.tenant_id = v_tenant and e.code = erp.slug_code(p_parent_code);
    if v_parent is null then
      raise exception 'CLOVEERP_UNKNOWN_ENTITY: no company is coded %', p_parent_code
        using errcode = '23503', hint = 'Create the parent company first, or name an existing one.';
    end if;
  end if;

  insert into erp.entity (tenant_id, code, name, legal_name, parent_entity_id, base_currency, country_code,
                          reporting_locale, document_locale, fiscal_year_start_month, status)
  values (v_tenant, v_code, btrim(p_name), coalesce(nullif(btrim(p_legal_name), ''), btrim(p_name)), v_parent,
          v_ccy, v_ctry, coalesce(p_reporting_locale, 'en'), coalesce(p_document_locale, 'en'),
          coalesce(p_fiscal_year_start_month, 1), 'active')
  on conflict (tenant_id, code) do update
    set name = excluded.name, legal_name = excluded.legal_name, parent_entity_id = excluded.parent_entity_id,
        base_currency = excluded.base_currency, country_code = excluded.country_code,
        reporting_locale = excluded.reporting_locale, document_locale = excluded.document_locale,
        fiscal_year_start_month = excluded.fiscal_year_start_month,
        status = 'active', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function erp.upsert_entity(text, text, text, character, character, text, text, smallint, text) from public, anon, authenticated;

comment on function erp.upsert_entity is
  'Creates or amends a company of the organisation by code. The promoter''s '
  'routine; the party a company is comes from the entity trigger.';

create or replace function erp.create_entity(
  p_code                    text,
  p_name                    text,
  p_legal_name              text default null,
  p_base_currency           character default null,
  p_country_code            character default null,
  p_reporting_locale        text default 'en',
  p_document_locale         text default 'en',
  p_fiscal_year_start_month smallint default 1,
  p_parent_code             text default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure', null, null, null, 'entity', null);
  if exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.code = erp.slug_code(p_code)) then
    raise exception 'CLOVEERP_ENTITY_EXISTS: a company is already coded %', erp.slug_code(p_code)
      using errcode = '23505',
            hint = 'Amend the existing company as master data, or promote an entity item to change it.';
  end if;
  return erp.upsert_entity(p_code, p_name, p_legal_name, p_base_currency, p_country_code,
                           p_reporting_locale, p_document_locale, p_fiscal_year_start_month, p_parent_code);
end;
$$;
revoke all on function erp.create_entity(text, text, text, character, character, text, text, smallint, text) from public, anon, authenticated;

comment on function erp.create_entity is
  'Creates a company of the organisation: code, name, currency, country, '
  'locales, fiscal year start, optional parent. Refuses a code in use.';

create or replace function public.erp_create_entity(
  p_code                    text,
  p_name                    text,
  p_legal_name              text default null,
  p_base_currency           text default null,
  p_country_code            text default null,
  p_reporting_locale        text default 'en',
  p_document_locale         text default 'en',
  p_fiscal_year_start_month integer default 1,
  p_parent_code             text default null)
returns uuid
language sql
volatile
set search_path = ''
as $$
  select erp.create_entity(p_code, p_name, p_legal_name, p_base_currency::character(3), p_country_code::character(2),
                           p_reporting_locale, p_document_locale, p_fiscal_year_start_month::smallint, p_parent_code)
$$;
revoke all on function public.erp_create_entity(text, text, text, text, text, text, text, integer, text) from public, anon;
grant execute on function public.erp_create_entity(text, text, text, text, text, text, text, integer, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_create_entity', 'erp.create_entity',
   'Creates a company of the organisation. Gated on administration.configure; the company''s party and internal role come from the entity trigger.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A company arrives by promotion, and the interview asks about it
-- ═════════════════════════════════════════════════════════════════════════════

do $promoter$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n1  text := E'when ''legislation_binding'' then';
  v_n2  text := 'Promotable kinds: config, terminology,';
begin
  if (select count(*) from regexp_matches(v_def, 'when ''legislation_binding'' then', 'g')) <> 1
     or (select count(*) from regexp_matches(v_def, 'Promotable kinds: config, terminology,', 'g')) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: erp.apply_change_set_item is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'when ''entity'' then\n'
    || E'      if i.operation = ''remove'' then\n'
    || E'        update erp.entity e set status = ''inactive'', updated_at = now()\n'
    || E'         where e.tenant_id = v_tenant and e.code = (p ->> ''code'');\n'
    || E'      else\n'
    || E'        perform erp.upsert_entity(p ->> ''code'', p ->> ''name'', p ->> ''legal_name'',\n'
    || E'          (p ->> ''currency'')::character(3), (p ->> ''country'')::character(2),\n'
    || E'          coalesce(p ->> ''locale'', ''en''), coalesce(p ->> ''document_locale'', p ->> ''locale'', ''en''),\n'
    || E'          coalesce((p ->> ''fiscal_year_start_month'')::smallint, 1::smallint), p ->> ''parent'');\n'
    || E'      end if;\n\n'
    || E'    ' || v_n1);
  v_def := replace(v_def, v_n2, 'Promotable kinds: entity, config, terminology,');
  execute v_def;
end
$promoter$;

-- A company before anything that names one. The promoter applies roles and
-- terminology first because later kinds reference them; a legislation binding,
-- a site-scoped setting or a costing policy may now name a company that the
-- same change set creates, so the company goes first of all.
do $order$
declare
  v_def text := pg_get_functiondef('erp.promote_change_set(uuid,text[],boolean)'::regprocedure);
  v_n1  text := E'         when ''role'' then 1 when ''terminology'' then 2 when ''config'' then 3';
begin
  if (select count(*) from regexp_matches(v_def, 'when ''role'' then 1 when ''terminology'' then 2 when ''config'' then 3', 'g')) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: erp.promote_change_set is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'         when ''entity'' then 0\n' || v_n1);
  execute v_def;
end
$order$;

-- Capture reads it back, so a manifest lifted from one organisation carries
-- its companies as well as the configuration that names them. erp.entity is
-- not registered in erp_meta.promotable_surface on purpose: a company is
-- created through a door on a live organisation, like a site, and the
-- live-edit guard the register generates would refuse exactly that. The
-- promoter arm is the interview's route; the door is the administrator's.
do $manifest$
declare
  v_def text := pg_get_functiondef('erp.configuration_manifest(text[])'::regprocedure);
  v_n1  text := E'    select ''legislation_binding'',';
begin
  if (select count(*) from regexp_matches(v_def, 'select ''legislation_binding'',', 'g')) <> 1 then
    raise exception 'CLOVEERP_MANIFEST_UNRECOGNISED: erp.configuration_manifest is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1,
       E'    select ''entity'',\n'
    || E'           e.code,\n'
    || E'           jsonb_build_object(''code'', e.code, ''name'', e.name, ''legal_name'', e.legal_name,\n'
    || E'                              ''currency'', e.base_currency, ''country'', e.country_code,\n'
    || E'                              ''locale'', e.reporting_locale, ''document_locale'', e.document_locale,\n'
    || E'                              ''fiscal_year_start_month'', e.fiscal_year_start_month,\n'
    || E'                              ''parent'', (select pe.code from erp.entity pe where pe.id = e.parent_entity_id))\n'
    || E'      from t\n'
    || E'      join erp.entity e on e.tenant_id = t.tenant_id and e.status = ''active''\n\n'
    || E'    union all\n\n'
    || v_n1);
  execute v_def;
end
$manifest$;

-- The interview's seventh section.
insert into erp_ref.interview_question
  (code, section, surface, seq, prompt, prompt_key, help, answer_shape, choices, maps_to, applies_when, is_required) values
  ('org.multi_company', 'B.7', 'entity', 70,
   'Does the organisation trade as more than one company?',
   'interview.org.multi_company',
   'A company is a legal entity with its own ledgers, currency and country. One organisation, several companies, is ordinary.',
   'boolean', null, null, null, true),
  ('org.companies', 'B.7', 'entity', 71,
   'Which companies, by code and name?',
   'interview.org.companies',
   'One pair per company: a short code on the left, the trading name on the right. The first company already exists.',
   'text_pairs', null, 'entity', 'org.multi_company', false),
  ('org.currencies', 'B.7', 'entity', 72,
   'In which currency does each company keep its books?',
   'interview.org.currencies',
   'Company code on the left, ISO currency on the right. A company not listed keeps the first company''s currency.',
   'text_pairs', null, null, 'org.companies', false),
  ('org.countries', 'B.7', 'entity', 73,
   'In which country is each company established?',
   'interview.org.countries',
   'Company code on the left, ISO country on the right.',
   'text_pairs', null, null, 'org.companies', false),
  ('org.locales', 'B.7', 'entity', 74,
   'In which language does each company report and issue documents?',
   'interview.org.locales',
   'Company code on the left, a locale such as en-GB, en-IE or de on the right.',
   'text_pairs', null, null, 'org.companies', false),
  ('org.fiscal_year_start', 'B.7', 'entity', 75,
   'In which month does the fiscal year start?',
   'interview.org.fiscal_year_start',
   'A month number, 1 to 12. Applies to every company named here.',
   'integer', null, null, null, false),
  ('org.legislation', 'B.7', 'legislation_binding', 76,
   'Which legislation applies to each company?',
   'interview.org.legislation',
   'Company code on the left, a legislation pack code on the right: gb_vat, ie_vat, de_ust.',
   'text_pairs', null, 'legislation_binding', 'org.companies', false),
  ('org.costing_method', 'B.7', 'costing_policy', 77,
   'How is stock costed by default?',
   'interview.org.costing_method',
   'Average re-costs on every receipt; standard holds a set cost and posts the difference to variance; FIFO consumes receipt layers oldest first.',
   'choice', '["average","standard","fifo"]'::jsonb, 'costing_policy', null, false),
  ('org.identity_level', 'B.7', 'container_identity_policy', 78,
   'At what level does a handling unit carry an identity?',
   'interview.org.identity_level',
   'None means stock is identified by product, batch and serial only. A level names the finest unit a scanner will be asked to identify.',
   'choice', '["none","unit","case","carton","pallet","master_pallet"]'::jsonb, 'container_identity_policy', null, false),
  ('org.allocation_method', 'B.7', 'config', 79,
   'How is stock chosen for an order?',
   'interview.org.allocation_method',
   'First-expiring first for stock with an expiry date; first-in or last-in first-out otherwise.',
   'choice', '["fefo","fifo","lifo"]'::jsonb, 'config', null, false),
  ('org.consignment', 'B.7', 'entity', 80,
   'Does the organisation hold stock it does not own, or keep its stock at a provider''s site?',
   'interview.org.consignment',
   'Consignment inbound, contract manufacturing and third-party logistics all separate who owns stock from who holds it; the product records both on every movement.',
   'boolean', null, null, null, false)
on conflict (code) do update
  set section = excluded.section, surface = excluded.surface, seq = excluded.seq, prompt = excluded.prompt,
      prompt_key = excluded.prompt_key, help = excluded.help, answer_shape = excluded.answer_shape,
      choices = excluded.choices, maps_to = excluded.maps_to, applies_when = excluded.applies_when,
      is_required = excluded.is_required;

-- The organisation-shape answers become change-set items. Product logic, in
-- the product schema; the interview's proposer calls it for its seventh section.
create or replace function erp.propose_organisation_shape(p_session_id uuid, p_change_set_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_items  integer := 0;
  v_first  record;
  e        jsonb;
  v_code   text;
  v_ccy    text; v_ctry text; v_loc text; v_pack text;
  v_fy     integer;
  v_choice text;
  v_pairs  jsonb;
begin
  select e0.code, e0.base_currency, e0.country_code into v_first
    from erp.entity e0 where e0.tenant_id = v_tenant and e0.status = 'active' order by e0.code limit 1;

  select (ia.answer #>> '{}')::integer into v_fy from erp.interview_answer ia
   where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.fiscal_year_start';

  -- Companies first, so their bindings promote after them (items promote in
  -- the order they were added).
  for e in
    select jsonb_array_elements(coalesce((
      select ia.answer from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.companies'), '[]'::jsonb))
  loop
    v_code := erp.slug_code(e ->> 'left');
    continue when v_code is null or coalesce(btrim(e ->> 'right'), '') = '';
    select upper(btrim(x ->> 'right')) into v_ccy from jsonb_array_elements(coalesce((
      select ia.answer from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.currencies'), '[]'::jsonb)) x
     where erp.slug_code(x ->> 'left') = v_code limit 1;
    select upper(btrim(x ->> 'right')) into v_ctry from jsonb_array_elements(coalesce((
      select ia.answer from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.countries'), '[]'::jsonb)) x
     where erp.slug_code(x ->> 'left') = v_code limit 1;
    select btrim(x ->> 'right') into v_loc from jsonb_array_elements(coalesce((
      select ia.answer from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.locales'), '[]'::jsonb)) x
     where erp.slug_code(x ->> 'left') = v_code limit 1;

    perform erp.add_change_set_item(p_change_set_id, 'entity', v_code,
      jsonb_build_object(
        'code', v_code, 'name', btrim(e ->> 'right'),
        'currency', coalesce(v_ccy, v_first.base_currency),
        'country', coalesce(v_ctry, v_first.country_code),
        'locale', coalesce(v_loc, 'en'),
        'fiscal_year_start_month', coalesce(v_fy, 1)));
    v_items := v_items + 1;
  end loop;

  for e in
    select jsonb_array_elements(coalesce((
      select ia.answer from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.legislation'), '[]'::jsonb))
  loop
    v_code := erp.slug_code(e ->> 'left');
    v_pack := lower(btrim(e ->> 'right'));
    continue when v_code is null or coalesce(v_pack, '') = '';
    if not exists (select 1 from erp_ref.legislation_pack lp where lp.code = v_pack and lp.is_current) then
      raise exception 'CLOVEERP_UNKNOWN_LEGISLATION_PACK: % is not a legislation pack the product ships', v_pack
        using errcode = '23503',
              hint = 'Name a current pack code from erp_ref.legislation_pack, or leave the legislation question unanswered.';
    end if;
    perform erp.add_change_set_item(p_change_set_id, 'legislation_binding', v_code || '|' || v_pack,
      jsonb_build_object('entity', v_code, 'pack', v_pack,
                         'pack_version', (select lp.version from erp_ref.legislation_pack lp where lp.code = v_pack and lp.is_current order by lp.version desc limit 1)));
    v_items := v_items + 1;
  end loop;

  select (ia.answer #>> '{}') into v_choice from erp.interview_answer ia
   where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.costing_method';
  if v_choice in ('average', 'standard', 'fifo') then
    perform erp.add_change_set_item(p_change_set_id, 'costing_policy', 'DEFAULT',
      jsonb_build_object('code', 'DEFAULT', 'name', 'Default costing', 'method', v_choice,
                         'variance_account', case when v_choice = 'standard' then erp.chart_account_code('purchase_price_variance') end));
    v_items := v_items + 1;
  end if;

  select (ia.answer #>> '{}') into v_choice from erp.interview_answer ia
   where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.identity_level';
  if v_choice in ('none', 'unit', 'case', 'carton', 'pallet', 'master_pallet') then
    perform erp.add_change_set_item(p_change_set_id, 'container_identity_policy', 'DEFAULT',
      jsonb_build_object('code', 'DEFAULT', 'name', 'Default identity level',
                         'identity_level', v_choice,
                         'count_method', case when v_choice in ('none', 'unit') then 'by_unit' else 'hybrid' end));
    v_items := v_items + 1;
  end if;

  select (ia.answer #>> '{}') into v_choice from erp.interview_answer ia
   where ia.tenant_id = v_tenant and ia.session_id = p_session_id and ia.question_code = 'org.allocation_method';
  if v_choice in ('fefo', 'fifo', 'lifo') then
    perform erp.add_change_set_item(p_change_set_id, 'config', 'stock.allocation_policy',
      jsonb_build_object('config_type', 'stock.allocation_policy',
                         'value', jsonb_build_object('expiry_controlled', 'fefo', 'default', v_choice,
                                                     'single_batch_per_order', false, 'prefer_nearest_location', true)));
    v_items := v_items + 1;
  end if;

  return v_items;
end;
$$;
revoke all on function erp.propose_organisation_shape(uuid, uuid) from public, anon, authenticated;

comment on function erp.propose_organisation_shape is
  'Turns the interview''s organisation-shape answers into change-set items: '
  'companies, their legislation bindings, a default costing policy, a default '
  'identity level and the allocation setting.';

do $propose$
declare
  v_def text := pg_get_functiondef('erp_ai.propose_from_interview(uuid)'::regprocedure);
  v_n   text := E'    if v_items = 0 then';
begin
  if (select count(*) from regexp_matches(v_def, E'    if v_items = 0 then', 'g')) <> 1 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp_ai.propose_from_interview is not the body this migration patches';
  end if;
  execute replace(v_def, v_n,
       E'    if v_section.section = ''B.7'' then\n'
    || E'      v_items := v_items + erp.propose_organisation_shape(p_session_id, v_cs);\n'
    || E'    end if;\n\n'
    || v_n);
end
$propose$;

-- The interview suite counted six sections; there are seven.
do $suite$
declare
  v_def text := pg_get_functiondef('erp_test.onboarding_interview_suite()'::regprocedure);
  v_a   text := '(select count(distinct q.section) from erp_ref.interview_question q) = 6,';
  v_b   text := 'the question bank is data, and covers all six sections';
begin
  if position(v_a in v_def) = 0 or position(v_b in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp_test.onboarding_interview_suite no longer pins six sections';
  end if;
  v_def := replace(v_def, v_a, '(select count(distinct q.section) from erp_ref.interview_question q) = 7,');
  v_def := replace(v_def, v_b, 'the question bank is data, and covers all seven sections');
  execute v_def;
end
$suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Finance is installed per company
-- ═════════════════════════════════════════════════════════════════════════════

-- The two-argument installer cannot gain an overload without making every
-- existing call ambiguous, so it is dropped and recreated with the company as
-- a third, defaulted argument. The public door follows it.
drop function if exists public.erp_configure_finance(integer, character);
drop function if exists erp.configure_finance(integer, character);

create function erp.configure_finance(
  p_fiscal_year integer default null,
  p_currency    character default null,
  p_entity_id   uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  e        erp.entity%rowtype;
  v_ccy    char(3);
  v_start  integer;
  v_year   integer;
  v_gl     uuid;
  v_commit uuid;
  v_cs     uuid;
  m        integer;
  v_from   date;
begin
  perform erp.authorise('finance.configure', null, null, null, 'ledger', null);

  if p_entity_id is null then
    select * into e from erp.entity x
     where x.tenant_id = v_tenant and x.status = 'active'
     order by x.code limit 1;
  else
    select * into e from erp.entity x
     where x.tenant_id = v_tenant and x.id = p_entity_id and x.status = 'active';
    if not found then
      raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not an active company of this organisation', p_entity_id
        using errcode = '23503', hint = 'Create the company first; the finance installer configures one company at a time.';
    end if;
  end if;

  if e.id is null then
    raise exception 'CLOVEERP_NO_ENTITY: configure an entity before finance'
      using errcode = '23503', hint = 'Create a company; finance is installed per company.';
  end if;
  v_ccy := coalesce(p_currency, e.base_currency, 'GBP');

  -- The statutory ledger, and a parallel management ledger for commitments.
  insert into erp.ledger (tenant_id, entity_id, code, name, ledger_kind, currency, is_primary, status)
  values (v_tenant, e.id, 'GL', 'General ledger', 'statutory', v_ccy, true, 'active')
  on conflict (tenant_id, entity_id, code) do update set status = 'active'
  returning id into v_gl;

  insert into erp.ledger (tenant_id, entity_id, code, name, ledger_kind, currency, is_primary, status)
  values (v_tenant, e.id, 'COMMIT', 'Commitments', 'management', v_ccy, false, 'active')
  on conflict (tenant_id, entity_id, code) do update set status = 'active'
  returning id into v_commit;

  -- Twelve periods from the company's own fiscal year start, open. The year is
  -- named by the calendar year it starts in, and the current date falls inside
  -- it; a period that does not exist refuses the posting rather than inventing
  -- one, so the calendar is not optional.
  v_start := coalesce(e.fiscal_year_start_month, 1);
  v_year  := coalesce(p_fiscal_year,
               case when extract(month from current_date)::integer >= v_start
                    then extract(year from current_date)::integer
                    else extract(year from current_date)::integer - 1 end);
  for m in 1..12 loop
    v_from := (make_date(v_year, v_start, 1) + ((m - 1) || ' months')::interval)::date;
    insert into erp.fiscal_period (
      tenant_id, ledger_id, code, fiscal_year, period_number,
      starts_on, ends_on, status)
    select v_tenant, l.id, format('%s-%s', v_year, lpad(m::text, 2, '0')),
           v_year, m::smallint,
           v_from, (v_from + interval '1 month - 1 day')::date, 'open'
      from (values (v_gl), (v_commit)) as l(id)
    on conflict (tenant_id, ledger_id, fiscal_year, period_number) do nothing;
  end loop;

  -- The chart: every account the purpose register says an installer creates,
  -- on this company. With §8.1's statutory chart chosen the pack ships the
  -- accounts instead, and seeding these too would leave two charts, one of
  -- which nothing posts to.
  if not erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date) then
    insert into erp.account (
      tenant_id, entity_id, code, name, account_type, control_kind,
      is_postable, currency, status)
    select v_tenant, e.id, p.default_code, p.name, p.account_type, p.control_kind,
           true, v_ccy, 'active'
      from erp_ref.chart_account_purpose p
     where p.installer_creates
    on conflict (tenant_id, entity_id, code) do update
      set name = excluded.name, status = 'active';
  end if;

  -- Posting rules are the organisation's, promoted once: which accounts each
  -- operational document reaches, and on which side, with the ledger named by
  -- code and resolved inside the document's own company at posting.
  select cs.id into v_cs from erp.change_set cs
   where cs.tenant_id = v_tenant and cs.code = 'finance-posting';
  if v_cs is not null then
    return v_cs;
  end if;

  v_cs := erp.install_module_config(
    'finance-posting', 'Finance posting rules',
    'Which accounts each operational document reaches, and on which side. '
    'Promoted rather than written, because this is the configuration that '
    'decides what the accounts say.',
    jsonb_build_array(
      jsonb_build_object('kind','posting_rule','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','name','Goods receipt','ledger','GL',
          'event_type','document.goods_receipt.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('inventory'),'side','debit','rate',1,
                               'description','Inventory received'),
            jsonb_build_object('account', erp.chart_account_code('goods_received_not_invoiced'),'side','credit','rate',1,
                               'description','Goods received not invoiced')))),
      jsonb_build_object('kind','posting_rule','key','delivery','payload',
        jsonb_build_object(
          'code','delivery','name','Delivery','ledger','GL',
          'event_type','document.delivery.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('cost_of_sales'),'side','debit','rate',1,
                               'description','Cost of goods sold'),
            jsonb_build_object('account', erp.chart_account_code('inventory'),'side','credit','rate',1,
                               'description','Inventory despatched')))),
      jsonb_build_object('kind','posting_rule','key','sales_invoice','payload',
        jsonb_build_object(
          'code','sales_invoice','name','Sales invoice','ledger','GL',
          'event_type','document.invoice.posted',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('trade_receivable'),'side','debit','rate',1,
                               'description','Trade receivable'),
            jsonb_build_object('account', erp.chart_account_code('revenue'),'side','credit','rate',1,
                               'description','Revenue')))),
      jsonb_build_object('kind','posting_rule','key','purchase_commitment','payload',
        jsonb_build_object(
          'code','purchase_commitment','name','Purchase commitment','ledger','COMMIT',
          'event_type','document.purchase_order.confirmed',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('purchase_commitment'),'side','debit','rate',1,
                               'description','Committed to a supplier'),
            jsonb_build_object('account', erp.chart_account_code('commitment_offset'),'side','credit','rate',1,
                               'description','Commitment offset')))),
      jsonb_build_object('kind','posting_rule','key','sales_commitment','payload',
        jsonb_build_object(
          'code','sales_commitment','name','Sales commitment','ledger','COMMIT',
          'event_type','document.sales_order.confirmed',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', erp.chart_account_code('commitment_offset'),'side','debit','rate',1,
                               'description','Commitment offset'),
            jsonb_build_object('account', erp.chart_account_code('sales_commitment'),'side','credit','rate',1,
                               'description','Committed to a customer'))))));

  return v_cs;
end;
$$;
revoke all on function erp.configure_finance(integer, character, uuid) from public, anon, authenticated;

comment on function erp.configure_finance is
  'Installs finance for one company (the first by code when none is named): '
  'its general and commitment ledgers, twelve periods from its fiscal year '
  'start, the accounts the purpose register says an installer creates, and, '
  'once per organisation, the posting rules.';

create function public.erp_configure_finance(
  p_fiscal_year integer default null,
  p_currency    character default null,
  p_entity_id   uuid default null)
returns uuid
language sql
volatile
set search_path = ''
as $$ select erp.configure_finance(p_fiscal_year, p_currency, p_entity_id) $$;
revoke all on function public.erp_configure_finance(integer, character, uuid) from public, anon;
grant execute on function public.erp_configure_finance(integer, character, uuid) to authenticated, service_role;

update erp_ref.part5_capability
   set artefacts = array['erp.account', 'erp.ledger', 'erp.configure_finance(integer,character,uuid)']
 where code = '5.7.chart_ledgers';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The bridge posts to the document's company
-- ═════════════════════════════════════════════════════════════════════════════

do $bridge$
declare
  v_def text := pg_get_functiondef('erp.post_document_finance(uuid)'::regprocedure);
  v_n1  text := E'     and r.code = dt.posting_rule_code\n     and r.status = ''active''';
  v_n2  text := E'   order by r.version desc limit 1;';
  v_n3  text := E'    raise exception ''CLOVEERP_POSTING_RULE_HAS_NO_LEDGER: % names no ledger'', pr.code\n'
             || E'      using errcode = ''23503'';\n'
             || E'  end if;\n';
begin
  if position(v_n1 in v_def) = 0 or position(v_n2 in v_def) = 0 or position(v_n3 in v_def) = 0 then
    raise exception 'CLOVEERP_NEEDLE_NOT_FOUND: erp.post_document_finance is not the body this migration patches';
  end if;
  v_def := replace(v_def, v_n1, v_n1 || E'\n     and (r.entity_id is null or r.entity_id = d.entity_id)');
  v_def := replace(v_def, v_n2, E'   order by (r.entity_id is not null) desc, r.version desc limit 1;');
  v_def := replace(v_def, v_n3, v_n3
    || E'\n'
    || E'  if led.entity_id <> d.entity_id then\n'
    || E'    select * into led from erp.ledger l\n'
    || E'     where l.tenant_id = v_tenant and l.entity_id = d.entity_id\n'
    || E'       and l.code = led.code and l.status = ''active'';\n'
    || E'    if not found then\n'
    || E'      raise exception ''CLOVEERP_NO_LEDGER_FOR_ENTITY: % posts to a ledger coded %, which this company does not have'', dt.code, pr.code\n'
    || E'        using errcode = ''23503'',\n'
    || E'              hint = ''Run the finance installer for the company the document belongs to; a company posts to its own ledgers.'';\n'
    || E'    end if;\n'
    || E'  end if;\n');
  execute v_def;
end
$bridge$;

-- The promoter supersedes a rule within a company, and picks a rule's home
-- ledger deterministically when two companies hold one of that code.
do $rules$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_a   text := E'        update erp.posting_rule pr set status = ''withdrawn'', updated_at = now()\n'
             || E'         where pr.tenant_id = v_tenant and pr.code = (p ->> ''code'')\n'
             || E'           and pr.status = ''active'';';
  v_b   text := E'               updated_at = now()\n'
             || E'         where pr.tenant_id = v_tenant and pr.code = (p ->> ''code'')\n'
             || E'           and pr.status = ''active'';';
  v_c   text := E'              and (v_entity is null or l.entity_id = v_entity)\n'
             || E'            order by l.code limit 1),';
begin
  if position(v_a in v_def) = 0 or position(v_b in v_def) = 0 or position(v_c in v_def) = 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the posting_rule arm of erp.apply_change_set_item is not the text this migration patches';
  end if;
  v_def := replace(v_def, v_a,
       E'        update erp.posting_rule pr set status = ''withdrawn'', updated_at = now()\n'
    || E'         where pr.tenant_id = v_tenant and pr.code = (p ->> ''code'')\n'
    || E'           and pr.entity_id is not distinct from v_entity\n'
    || E'           and pr.status = ''active'';');
  v_def := replace(v_def, v_b,
       E'               updated_at = now()\n'
    || E'         where pr.tenant_id = v_tenant and pr.code = (p ->> ''code'')\n'
    || E'           and pr.entity_id is not distinct from v_entity\n'
    || E'           and pr.status = ''active'';');
  v_def := replace(v_def, v_c,
       E'              and (v_entity is null or l.entity_id = v_entity)\n'
    || E'            order by (select e.code from erp.entity e where e.id = l.entity_id), l.code limit 1),');
  execute v_def;
end
$rules$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.companies_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_e1 uuid; v_e2 uuid; v_e3 uuid;
  v_ccy char(3);
  v_supplier uuid; v_item uuid; v_site2 uuid;
  v_doc uuid; v_line uuid;
  v_s uuid; v_cs uuid;
  res jsonb;
  v_msg text;
  v_n integer; v_m integer; v_before integer; v_year integer;
  chk record;
  v_out text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-company', 'Companies suite', 'admin@zz-company.test', 'Company Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000d3', 'admin@zz-company.test');
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000d3')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id, e.base_currency into v_e1, v_ccy from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;
  select count(*) into v_before from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_e1;

  -- 1. A second company through the door.
  v_cases := v_cases + 1;
  v_e2 := public.erp_create_entity('ZZ-EU', 'Zz Europe', 'Zz Europe BV', 'EUR', 'NL', 'en', 'en', 4);
  case_name := 'a second company is created through the door, is a party, and keeps what it was told';
  passed := exists (select 1 from erp.entity e where e.id = v_e2 and e.base_currency = 'EUR' and e.country_code = 'NL'
                                                  and e.fiscal_year_start_month = 4 and e.party_id is not null)
        and exists (select 1 from erp.party_role r join erp.entity e on e.party_id = r.party_id
                     where e.id = v_e2 and r.role_kind = 'internal');
  detail := format('ZZ-EU: currency %s, country %s, fiscal year from month %s, party present: %s',
                   (select base_currency from erp.entity where id = v_e2), (select country_code from erp.entity where id = v_e2),
                   (select fiscal_year_start_month from erp.entity where id = v_e2), (select party_id is not null from erp.entity where id = v_e2));
  return next;

  -- 2. A duplicate code is refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    perform public.erp_create_entity('ZZ-EU', 'Zz Europe again');
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'a duplicate company code is refused by name';
  passed := coalesce(v_msg like 'CLOVEERP_ENTITY_EXISTS%', false);
  detail := left(coalesce(v_msg, 'no refusal'), 120);
  return next;

  -- 3. Finance for the second company.
  v_cases := v_cases + 1;
  perform erp.configure_finance(null, null, v_e2);
  v_year := case when extract(month from current_date)::integer >= 4 then extract(year from current_date)::integer
                 else extract(year from current_date)::integer - 1 end;
  select count(*) into v_n from erp.fiscal_period fp join erp.ledger l on l.id = fp.ledger_id
   where l.tenant_id = v_tenant and l.entity_id = v_e2 and l.code = 'GL';
  select count(*) into v_m from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_e2;
  case_name := 'finance configured for it gives it its own ledgers, twelve periods from April and the register''s chart';
  passed := exists (select 1 from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_e2 and l.code = 'GL' and l.is_primary and l.currency = 'EUR')
        and exists (select 1 from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_e2 and l.code = 'COMMIT')
        and v_n = 12
        and (select min(fp.starts_on) from erp.fiscal_period fp join erp.ledger l on l.id = fp.ledger_id
              where l.entity_id = v_e2 and l.code = 'GL') = make_date(v_year, 4, 1)
        and v_m = 16
        and (select count(*) from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_e1) = v_before
        and (select count(*) from erp.change_set cs where cs.tenant_id = v_tenant and cs.code = 'finance-posting') = 1;
  detail := format('%s period(s) on its GL from %s (expected 12 from %s); %s account(s) (expected 16); first company still %s; one finance-posting change set',
                   v_n, (select min(fp.starts_on) from erp.fiscal_period fp join erp.ledger l on l.id = fp.ledger_id where l.entity_id = v_e2 and l.code = 'GL'),
                   make_date(v_year, 4, 1), v_m, (select count(*) from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_e1));
  return next;

  -- 4. Posting rules stay the organisation's.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.posting_rule pr where pr.tenant_id = v_tenant and pr.code = 'goods_receipt' and pr.status = 'active';
  case_name := 'posting rules stay the organisation''s: one active goods_receipt rule, bound to no company';
  passed := v_n = 1 and (select pr.entity_id is null from erp.posting_rule pr where pr.tenant_id = v_tenant and pr.code = 'goods_receipt' and pr.status = 'active');
  detail := format('%s active goods_receipt rule(s) (expected 1), company-bound: %s', v_n,
                   (select pr.entity_id is not null from erp.posting_rule pr where pr.tenant_id = v_tenant and pr.code = 'goods_receipt' and pr.status = 'active'));
  return next;

  -- 5. A receipt on the second company posts to its own ledger.
  v_cases := v_cases + 1;
  v_site2 := erp.create_site('ZZ-EU-WH', 'Zz Europe warehouse', 'warehouse', v_e2);
  v_doc := erp.open_document('goods_receipt', v_supplier, v_e2, v_site2, null, null, 'EUR');
  v_line := erp.add_document_line(v_doc, v_item, 10, 1000, 'received in Europe');
  perform erp.transition_document(v_doc, 'post', 'companies suite');
  set constraints all immediate;
  case_name := 'a goods receipt on the second company posts to the second company''s ledger';
  passed := exists (select 1 from erp.journal j join erp.ledger l on l.id = j.ledger_id
                     where j.tenant_id = v_tenant and j.document_id = v_doc and l.entity_id = v_e2 and j.entity_id = v_e2 and j.status = 'posted')
        and not exists (select 1 from erp.journal j join erp.ledger l on l.id = j.ledger_id
                         where j.tenant_id = v_tenant and j.document_id = v_doc and l.entity_id = v_e1);
  detail := format('journal on the Dutch ledger: %s; on the first company''s: %s',
                   exists (select 1 from erp.journal j join erp.ledger l on l.id = j.ledger_id where j.document_id = v_doc and l.entity_id = v_e2),
                   exists (select 1 from erp.journal j join erp.ledger l on l.id = j.ledger_id where j.document_id = v_doc and l.entity_id = v_e1));
  return next;

  -- 6. The default installer still lands on the first company by code.
  v_cases := v_cases + 1;
  case_name := 'the default installer still lands on the first company by code';
  passed := (select nr.entity_id from erp.numbering_rule nr where nr.tenant_id = v_tenant and nr.code = 'purchase_order') = v_e1
        and (select dt.entity_id from erp.document_type dt where dt.tenant_id = v_tenant and dt.code = 'sales_order') = v_e1;
  detail := 'purchase_order numbering and sales_order document type bound to the first company';
  return next;

  -- 7. The interview proposes a company and promotion creates it.
  v_cases := v_cases + 1;
  v_s := (public.erp_start_interview('zz-company-shape') ->> 'session_id')::uuid;
  perform public.erp_answer_interview(v_s, 'org.multi_company', 'true'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.companies', '[{"left":"ZZ-US","right":"Zz Americas"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.currencies', '[{"left":"ZZ-US","right":"USD"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.costing_method', '"standard"'::jsonb);
  res := public.erp_propose_from_interview(v_s);
  select (x ->> 'change_set_id')::uuid into v_cs from jsonb_array_elements(res -> 'proposals') x where x ->> 'section' = 'B.7';
  v_n := (select count(*) from erp.change_set_item i where i.change_set_id = v_cs and i.object_kind = 'entity');
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  select e.id into v_e3 from erp.entity e where e.tenant_id = v_tenant and e.code = 'ZZ-US';
  case_name := 'the interview''s organisation shape proposes a company and promotion creates it';
  passed := v_cs is not null and v_n = 1 and v_e3 is not null
        and (select e.base_currency from erp.entity e where e.id = v_e3) = 'USD'
        and exists (select 1 from erp.costing_policy c where c.tenant_id = v_tenant and c.code = 'DEFAULT' and c.method = 'standard');
  detail := format('B.7 change set %s with %s entity item(s); ZZ-US created in %s; default costing policy: %s',
                   v_cs, v_n, (select e.base_currency from erp.entity e where e.id = v_e3),
                   (select c.method::text from erp.costing_policy c where c.tenant_id = v_tenant and c.code = 'DEFAULT'));
  return next;

  -- 8. Every per-organisation check still passes with three companies.
  v_cases := v_cases + 1;
  v_n := 0; v_out := null;
  for chk in select d.function_name, d.arguments from erp_meta.diagnostic_check d
            where d.kind = 'assertion' and d.scope = 'tenant' and d.function_name <> 'assert_whole_database_reconciles'
            order by d.seq
  loop
    begin
      execute format('select erp.%I(%s)', chk.function_name, coalesce(chk.arguments, ''));
    exception when others then
      v_n := v_n + 1;
      v_out := coalesce(v_out || '; ', '') || chk.function_name || ': ' || left(sqlerrm, 80);
    end;
  end loop;
  case_name := 'every per-organisation check in the register passes with three companies';
  passed := v_n = 0;
  detail := coalesce(v_out, 'all tenant-scoped assertions green');
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 9. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-company')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000d3');
  detail := 'zz-company rolled back with its three companies';
  return next;

  if v_cases <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: companies_suite ran % cases, expected 9', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_companies_suite()
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
  create temp table if not exists _companies on commit drop as
    select * from erp_test.companies_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _companies;
  drop table _companies;
  if v_fail > 0 then
    raise exception E'CLOVEERP_COMPANIES_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: companies_suite ran % cases, expected 9', v_all;
  end if;
  return format('companies: %s/%s cases passed', v_all, v_all);
end;
$$;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D4', 'erp_test', 'assert_companies_suite',
   'A company arrives through a door or by promotion from the interview, is installed on its own, and posts to its own ledger; the register''s per-organisation checks hold with three companies.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_companies_suite();
select erp_test.assert_onboarding_interview_suite();
select erp_test.assert_demo_chart_suite();
select erp_test.assert_finance_suite();
select erp_test.assert_numbering_suite();
select erp_test.assert_provisioning_suite();
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
select erp.assert_resource_coverage('en');
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
