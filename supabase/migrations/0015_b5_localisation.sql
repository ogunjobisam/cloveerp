-- =============================================================================
-- ERPWare — B5: legislation packs, language packs, and the conformance harness
-- Spec 3.10:
--   "Legislation packs: versioned, effective-dated bundles of parameters,
--    declarative rules and statutory output definitions, shipped with the
--    product and bound per entity. Adding a jurisdiction is configuration, not
--    installation, and never a code branch"
--   "Language and terminology: no user-facing literal anywhere; every string
--    resolves through a resource key. Locales with fallback chains so a variant
--    supplies only genuine differences. Separate axes for user language,
--    document language and reporting language"
--   "Both pack types are product content, neutral and shared; a tenant's
--    overrides are tenant content"
--
-- A legislation pack is data: parameters, declarative rules in the same
-- language the B3 engine already evaluates, statutory output definitions, and
-- — importantly — the conformance cases that prove the pack behaves. Adding
-- Ireland is inserting rows, binding them to an entity, and running the
-- conformance suite. There is no code path that tests for a jurisdiction.
--
-- One question the specification leaves open and a product has to answer:
-- when a tenant's own rules and a legislation pack disagree, who wins? Both
-- answers are wrong as a blanket rule. A tenant must be able to be stricter
-- than the law about its own approval thresholds; a tenant must NOT be able to
-- opt out of a tax rule by configuring around it. So each decision point
-- declares which it is, and legislation is authoritative where the product says
-- the answer is not the tenant's to choose.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Locales and the fallback chain
-- -----------------------------------------------------------------------------

create table erp_ref.locale (
  code           text primary key check (code ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  name           text not null,
  -- 'en-GB' falls back to 'en'. A variant then supplies only genuine
  -- differences rather than a full retranslation that drifts.
  parent_locale  text references erp_ref.locale(code),
  text_direction text not null default 'ltr' check (text_direction in ('ltr', 'rtl')),
  is_active      boolean not null default true,
  constraint locale_not_own_parent check (parent_locale is distinct from code)
);

comment on table erp_ref.locale is
  'Product content. Locales and their fallback parents, so a regional variant '
  'carries only what actually differs.';

-- The resolution order for a locale: itself, then its parent, and so on.
create or replace function erp.locale_chain(p_locale text)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  v_chain text[] := '{}';
  v_cur   text := p_locale;
  v_guard integer := 0;
begin
  while v_cur is not null and v_guard < 10 loop
    v_chain := v_chain || v_cur;
    select l.parent_locale into v_cur from erp_ref.locale l where l.code = v_cur;
    v_guard := v_guard + 1;
  end loop;
  return v_chain;
end;
$$;

-- -----------------------------------------------------------------------------
-- Resources — product strings, and tenant overrides
-- -----------------------------------------------------------------------------

create table erp_ref.resource (
  key         text not null check (key ~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'),
  locale      text not null references erp_ref.locale(code),
  value       text not null,
  module_code text references erp_ref.module(code),
  description text,
  primary key (key, locale)
);

comment on table erp_ref.resource is
  'Product content. Every user-facing string in the product, by key and locale. '
  'Nothing in the application emits a literal; it emits a key, and this is '
  'where the key becomes words.';

create index on erp_ref.resource (locale);

-- Spec 3.10: "a tenant's overrides are tenant content". This is where an
-- organisation's own vocabulary lives — one tenant's "job", another's "works
-- order" — without either leaking into the product or into each other.
create table erp.resource_override (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references erp.tenant(id) on delete cascade,
  key         text not null,
  locale      text not null references erp_ref.locale(code),
  value       text not null,
  -- Terminology may differ per entity (a group with differently-regulated
  -- subsidiaries) without forcing separate tenants.
  entity_id   uuid,
  note        text,
  status      erp.record_status not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (id),
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete cascade
);

create unique index resource_override_identity
  on erp.resource_override (
    tenant_id, key, locale,
    coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid));

create index on erp.resource_override (tenant_id, locale) where status = 'active';

-- The single resolution path for every user-facing string.
create or replace function erp.text(
  p_key       text,
  p_locale    text default null,
  p_entity_id uuid default null
) returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_locale text := coalesce(p_locale, 'en');
  v_chain  text[] := erp.locale_chain(v_locale);
  v_out    text;
  i        integer;
begin
  -- Walk the fallback chain once, preferring a tenant override at each step
  -- over the product string. A tenant's en-GB wording beats the product's
  -- en-GB wording, but the product's en-GB still beats the tenant's plain en.
  for i in 1 .. coalesce(array_length(v_chain, 1), 0) loop
    if v_tenant is not null then
      select ro.value into v_out
        from erp.resource_override ro
       where ro.tenant_id = v_tenant
         and ro.key = p_key
         and ro.locale = v_chain[i]
         and ro.status = 'active'
         and (ro.entity_id is null or ro.entity_id = p_entity_id)
       order by (ro.entity_id is not null) desc
       limit 1;
      if v_out is not null then return v_out; end if;
    end if;

    select r.value into v_out
      from erp_ref.resource r
     where r.key = p_key and r.locale = v_chain[i];
    if v_out is not null then return v_out; end if;
  end loop;

  -- A missing string surfaces as its key rather than as blank space: a visible
  -- gap gets fixed, an invisible one ships.
  return p_key;
end;
$$;

comment on function erp.text is
  'Resolves a resource key to words. Tenant override, then product string, at '
  'each step of the locale fallback chain. Returns the key itself when nothing '
  'matches, because a visible gap gets fixed and a blank one ships.';

-- Spec 3.10: separate axes for user language, document language and reporting
-- language. They are genuinely different questions — a British user may read
-- the UI in English while the invoice must print in French.
create or replace function erp.resolve_locale(
  p_axis text default 'user', p_entity_id uuid default null)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
    case p_axis
      when 'user'      then (select u.user_locale      from erp.app_user u
                              where u.id = erp.current_principal_id())
      when 'document'  then coalesce(
                              (select e.document_locale from erp.entity e
                                where e.id = p_entity_id),
                              (select u.document_locale from erp.app_user u
                                where u.id = erp.current_principal_id()))
      when 'reporting' then coalesce(
                              (select e.reporting_locale from erp.entity e
                                where e.id = p_entity_id),
                              (select u.reporting_locale from erp.app_user u
                                where u.id = erp.current_principal_id()))
    end,
    (select t.default_locale from erp.tenant t where t.id = erp.current_tenant_id()),
    'en')
$$;

-- -----------------------------------------------------------------------------
-- Legislation packs (product content)
-- -----------------------------------------------------------------------------

create table erp_ref.legislation_pack (
  code           text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  version        integer not null default 1 check (version >= 1),
  jurisdiction   text not null,
  name_key       text not null,
  description    text,
  -- When the law this pack encodes takes effect, not when we shipped it.
  effective_from date not null,
  effective_to   date,
  is_current     boolean not null default true,
  primary key (code, version),
  constraint legislation_pack_range check (effective_to is null or effective_to > effective_from)
);

comment on table erp_ref.legislation_pack is
  'Product content. A jurisdiction''s parameters, rules and statutory outputs, '
  'versioned and effective-dated. Adding a jurisdiction inserts rows here and '
  'binds them to an entity; it never adds a branch to the application.';

create table erp_ref.legislation_parameter (
  pack_code    text not null,
  pack_version integer not null,
  key          text not null,
  value        jsonb not null,
  name_key     text,
  description  text,
  primary key (pack_code, pack_version, key),
  foreign key (pack_code, pack_version)
    references erp_ref.legislation_pack (code, version) on delete cascade
);

-- Declarative rules shipped with the pack, in the same language the B3 engine
-- already evaluates. A tax rule is data, exactly as a tenant's own rules are.
create table erp_ref.legislation_rule (
  pack_code           text not null,
  pack_version        integer not null,
  code                text not null,
  decision_point_code text not null references erp_ref.decision_point(code),
  seq                 integer not null,
  name_key            text,
  condition           jsonb not null default 'true'::jsonb,
  outcome             jsonb not null default '{}'::jsonb,
  stop_on_match       boolean not null default true,
  primary key (pack_code, pack_version, code),
  foreign key (pack_code, pack_version)
    references erp_ref.legislation_pack (code, version) on delete cascade
);

create index on erp_ref.legislation_rule (decision_point_code, pack_code, pack_version, seq);

create table erp_ref.statutory_output (
  pack_code    text not null,
  pack_version integer not null,
  code         text not null,
  name_key     text not null,
  output_kind  text not null check (output_kind in ('return', 'report', 'file', 'declaration')),
  -- Definition of the output: sections, mappings and format. Data, so a filing
  -- format change is a pack version rather than a release.
  definition   jsonb not null default '{}'::jsonb,
  frequency    text,
  description  text,
  primary key (pack_code, pack_version, code),
  foreign key (pack_code, pack_version)
    references erp_ref.legislation_pack (code, version) on delete cascade
);

-- The conformance harness. Spec 2.4 makes running it part of onboarding:
-- "run the conformance suite for the selected legislation packs".
create table erp_ref.conformance_case (
  pack_code           text not null,
  pack_version        integer not null,
  code                text not null,
  name_key            text,
  description         text,
  decision_point_code text not null references erp_ref.decision_point(code),
  inputs              jsonb not null,
  expected_outcome    jsonb not null,
  citation            text,
  primary key (pack_code, pack_version, code),
  foreign key (pack_code, pack_version)
    references erp_ref.legislation_pack (code, version) on delete cascade
);

comment on table erp_ref.conformance_case is
  'Worked examples a pack must reproduce, with a citation to the source. This '
  'is what makes a legislation pack falsifiable rather than a claim: the pack '
  'ships with the evidence that it computes what the jurisdiction says.';

-- -----------------------------------------------------------------------------
-- Binding packs to entities (tenant content)
-- -----------------------------------------------------------------------------

create table erp.entity_legislation_binding (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  entity_id      uuid not null,
  pack_code      text not null,
  pack_version   integer not null,
  effective_from date not null default current_date,
  effective_to   date,
  note           text,
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  foreign key (tenant_id, entity_id)
    references erp.entity (tenant_id, id) on delete cascade,
  foreign key (pack_code, pack_version)
    references erp_ref.legislation_pack (code, version) on delete restrict,
  constraint entity_legislation_binding_range
    check (effective_to is null or effective_to > effective_from),
  -- One version of a given pack in force per entity at a time. Two versions of
  -- the same tax law applying on the same day has no meaning.
  constraint entity_legislation_no_overlap
    exclude using gist (
      tenant_id with =,
      entity_id with =,
      pack_code with =,
      daterange(effective_from, effective_to, '[)') with &&
    ) where (status = 'active')
);

create index on erp.entity_legislation_binding (tenant_id, entity_id)
  where status = 'active';

create or replace function erp.bound_legislation_packs(
  p_entity_id uuid, p_on date default null)
returns table (pack_code text, pack_version integer, jurisdiction text)
language sql
stable
security invoker
set search_path = ''
as $$
  select b.pack_code, b.pack_version, lp.jurisdiction
    from erp.entity_legislation_binding b
    join erp_ref.legislation_pack lp
      on lp.code = b.pack_code and lp.version = b.pack_version
   where b.tenant_id = erp.require_tenant_id()
     and b.entity_id = p_entity_id
     and b.status = 'active'
     and daterange(b.effective_from, b.effective_to, '[)') @> coalesce(p_on, current_date)
   order by b.pack_code
$$;

create or replace function erp.legislation_parameter(
  p_key text, p_entity_id uuid, p_on date default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select lp.value
    from erp.bound_legislation_packs(p_entity_id, p_on) b
    join erp_ref.legislation_parameter lp
      on lp.pack_code = b.pack_code and lp.pack_version = b.pack_version
   where lp.key = p_key
   limit 1
$$;

-- -----------------------------------------------------------------------------
-- Where legislation and tenant rules meet
-- -----------------------------------------------------------------------------

alter table erp_ref.decision_point
  add column legislation_authoritative boolean not null default false;

comment on column erp_ref.decision_point.legislation_authoritative is
  'True where the answer is not the tenant''s to choose. Tax determination is '
  'authoritative — a tenant may not configure its way out of a rate. Approval '
  'routing is not — a tenant may be stricter than the law. Where true, pack '
  'rules are evaluated first and a match wins; tenant rules only fill gaps.';

create or replace function erp.evaluate_legislation_rules(
  p_decision_point text,
  p_data           jsonb,
  p_entity_id      uuid,
  p_on             date
) returns table (outcome jsonb, rule_code text, pack_code text, trace jsonb)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  r         record;
  v_trace   jsonb := '[]'::jsonb;
  v_outcome jsonb := null;
  v_code    text;
  v_pack    text;
  v_hit     boolean;
begin
  if p_entity_id is null then
    return;
  end if;

  for r in
    select lr.*, b.pack_version as bound_version
      from erp.bound_legislation_packs(p_entity_id, p_on) b
      join erp_ref.legislation_rule lr
        on lr.pack_code = b.pack_code and lr.pack_version = b.pack_version
     where lr.decision_point_code = p_decision_point
     order by lr.pack_code, lr.seq
  loop
    v_hit := erp.jsonlogic_bool(r.condition, p_data);

    v_trace := v_trace || jsonb_build_array(jsonb_build_object(
      'source', 'legislation',
      'pack', r.pack_code,
      'seq', r.seq,
      'rule_code', r.code,
      'result', case when v_hit then 'matched' else 'no_match' end));

    if v_hit then
      v_outcome := coalesce(v_outcome, '{}'::jsonb) || r.outcome;
      v_code := r.code;
      v_pack := r.pack_code;
      exit when r.stop_on_match;
    end if;
  end loop;

  if v_outcome is not null then
    outcome := v_outcome; rule_code := v_code; pack_code := v_pack; trace := v_trace;
    return next;
  end if;
end;
$$;

-- Rebuilt to consult legislation as well as tenant rules. The order depends on
-- whether the decision point is one the tenant may override.
--
-- Dropped rather than replaced: the result gains a `source` column, and that
-- changes the function's return type.
drop function if exists erp.evaluate_rules(text, jsonb, date, uuid, uuid);

create or replace function erp.evaluate_rules(
  p_decision_point text,
  p_data           jsonb default '{}'::jsonb,
  p_on             date default null,
  p_entity_id      uuid default null,
  p_site_id        uuid default null
) returns table (
  matched             boolean,
  outcome             jsonb,
  rule_id             uuid,
  rule_code           text,
  rule_set_id         uuid,
  rule_set_version_id uuid,
  rule_set_version    integer,
  trace               jsonb,
  source              text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_on      date := coalesce(p_on, current_date);
  v_dp      erp_ref.decision_point%rowtype;
  v_set     record;
  v_leg     record;
  r         record;
  v_hit     boolean;
  v_trace   jsonb := '[]'::jsonb;
  v_outcome jsonb := null;
  v_stopped boolean := false;
begin
  select * into v_dp from erp_ref.decision_point where code = p_decision_point;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DECISION_POINT: %', p_decision_point
      using errcode = '23503';
  end if;

  if not extensions.jsonb_matches_schema(v_dp.input_schema::json, p_data) then
    raise exception 'ERPWARE_RULE_INPUT_INVALID: facts supplied to % do not match its input schema',
      p_decision_point using errcode = '23514', detail = p_data::text;
  end if;

  -- Where the answer is not the tenant's to choose, the pack answers first.
  if v_dp.legislation_authoritative then
    select * into v_leg
      from erp.evaluate_legislation_rules(p_decision_point, p_data, p_entity_id, v_on);
    if found then
      matched := true; outcome := v_leg.outcome; rule_code := v_leg.rule_code;
      trace := v_leg.trace; source := 'legislation:' || v_leg.pack_code;
      return next; return;
    end if;
    v_trace := coalesce(v_leg.trace, '[]'::jsonb);
  end if;

  select rs.id, rsv.id as version_id, rsv.version
    into v_set
    from erp.rule_set rs
    join erp.rule_set_version rsv
      on rsv.tenant_id = rs.tenant_id
     and rsv.rule_set_id = rs.id
     and rsv.status = 'active'
     and daterange(rsv.effective_from, rsv.effective_to, '[)') @> v_on
   where rs.tenant_id = v_tenant
     and rs.decision_point_code = p_decision_point
     and rs.status = 'active'
     and (rs.site_id   is null or rs.site_id   = p_site_id)
     and (rs.entity_id is null or rs.entity_id = p_entity_id)
   order by (rs.site_id is not null) desc, (rs.entity_id is not null) desc
   limit 1;

  if found then
    for r in
      select ru.id, ru.seq, ru.code, ru.condition, ru.outcome, ru.stop_on_match
        from erp.rule ru
       where ru.tenant_id = v_tenant
         and ru.rule_set_version_id = v_set.version_id
         and ru.is_active
       order by ru.seq
    loop
      if v_stopped then
        v_trace := v_trace || jsonb_build_array(jsonb_build_object(
          'source', 'tenant', 'seq', r.seq, 'rule_code', r.code, 'result', 'not_reached'));
        continue;
      end if;

      v_hit := erp.jsonlogic_bool(r.condition, p_data);

      v_trace := v_trace || jsonb_build_array(jsonb_build_object(
        'source', 'tenant',
        'seq', r.seq,
        'rule_code', r.code,
        'result', case when v_hit then 'matched' else 'no_match' end,
        'condition', r.condition));

      if v_hit then
        v_outcome := case when v_outcome is null then r.outcome else v_outcome || r.outcome end;
        rule_id   := r.id;
        rule_code := r.code;
        if r.stop_on_match then v_stopped := true; end if;
      end if;
    end loop;
  end if;

  if v_outcome is not null then
    matched := true; outcome := v_outcome;
    rule_set_id := v_set.id; rule_set_version_id := v_set.version_id;
    rule_set_version := v_set.version; trace := v_trace; source := 'tenant';
    return next; return;
  end if;

  -- Not authoritative, and the tenant said nothing: the pack fills the gap.
  if not v_dp.legislation_authoritative then
    select * into v_leg
      from erp.evaluate_legislation_rules(p_decision_point, p_data, p_entity_id, v_on);
    if found then
      matched := true; outcome := v_leg.outcome; rule_code := v_leg.rule_code;
      trace := v_trace || v_leg.trace; source := 'legislation:' || v_leg.pack_code;
      return next; return;
    end if;
  end if;

  if v_dp.requires_match then
    raise exception 'ERPWARE_RULE_NO_MATCH: no rule matched at % and it requires one',
      p_decision_point using errcode = '23514', detail = p_data::text;
  end if;

  matched := false;
  outcome := v_dp.default_outcome;
  rule_code := '(default)';
  rule_set_id := v_set.id;
  rule_set_version_id := v_set.version_id;
  rule_set_version := v_set.version;
  trace := v_trace;
  source := 'default';
  return next;
end;
$$;

-- evaluate_and_record gains the source of the answer.
alter table erp.rule_evaluation add column source text;

create or replace function erp.evaluate_and_record(
  p_decision_point text,
  p_data           jsonb default '{}'::jsonb,
  p_on             date default null,
  p_entity_id      uuid default null,
  p_site_id        uuid default null,
  p_object_type    text default null,
  p_object_id      uuid default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v        record;
begin
  select * into v
    from erp.evaluate_rules(p_decision_point, p_data, p_on, p_entity_id, p_site_id);

  insert into erp.rule_evaluation (
    tenant_id, decision_point_code, entity_id, site_id, effective_date,
    rule_set_id, rule_set_version_id, rule_set_version,
    matched_rule_id, matched_rule_code, inputs, outcome, trace, source,
    object_type, object_id, actor_id, correlation_id)
  values (
    v_tenant, p_decision_point, p_entity_id, p_site_id, coalesce(p_on, current_date),
    v.rule_set_id, v.rule_set_version_id, v.rule_set_version,
    v.rule_id, v.rule_code, p_data, v.outcome, v.trace, v.source,
    p_object_type, p_object_id, erp.current_principal_id(),
    erp.current_correlation_id());

  return v.outcome;
end;
$$;

-- -----------------------------------------------------------------------------
-- The conformance harness
-- -----------------------------------------------------------------------------

create or replace function erp.run_legislation_conformance(
  p_entity_id uuid, p_on date default null)
returns table (
  pack_code   text,
  case_code   text,
  passed      boolean,
  expected    jsonb,
  actual      jsonb,
  citation    text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  c      record;
  v_out  jsonb;
begin
  for c in
    select cc.*, b.pack_version as bound_version
      from erp.bound_legislation_packs(p_entity_id, p_on) b
      join erp_ref.conformance_case cc
        on cc.pack_code = b.pack_code and cc.pack_version = b.pack_version
     order by cc.pack_code, cc.code
  loop
    begin
      select r.outcome into v_out
        from erp.evaluate_rules(c.decision_point_code, c.inputs, p_on, p_entity_id, null) r;
    exception when others then
      v_out := jsonb_build_object('error', sqlerrm);
    end;

    pack_code := c.pack_code;
    case_code := c.code;
    -- Containment, not equality: a pack asserts the values it is responsible
    -- for, and a tenant rule adding an unrelated key alongside is not a
    -- conformance failure.
    passed    := (v_out @> c.expected_outcome);
    expected  := c.expected_outcome;
    actual    := v_out;
    citation  := c.citation;
    return next;
  end loop;
end;
$$;

comment on function erp.run_legislation_conformance is
  'Spec 2.4: run the conformance suite for the selected legislation packs. '
  'Replays each pack''s worked examples through the live rule engine against a '
  'real entity, so it proves the binding and the tenant''s own rules too — not '
  'just the pack in isolation.';

create or replace function erp.assert_legislation_conformance(
  p_entity_id uuid, p_on date default null)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_fail  integer;
  v_total integer;
  v_detail text;
begin
  select count(*) filter (where not r.passed), count(*),
         string_agg(format('  %s/%s: expected %s, got %s (%s)',
                           r.pack_code, r.case_code, r.expected, r.actual,
                           coalesce(r.citation, 'no citation')), E'\n')
           filter (where not r.passed)
    into v_fail, v_total, v_detail
    from erp.run_legislation_conformance(p_entity_id, p_on) r;

  if v_fail > 0 then
    raise exception E'ERPWARE_CONFORMANCE_FAILED: %/% case(s) failed\n%',
      v_fail, v_total, v_detail;
  end if;

  return format('conformance: %s/%s cases passed', v_total, v_total);
end;
$$;

-- -----------------------------------------------------------------------------
-- "No user-facing literal anywhere" as a checked property
--
-- The rule is unenforceable in the application from here, but the half that
-- lives in the database is checkable: every name_key the product references
-- must actually resolve in the base locale. A key with no string behind it is
-- the same defect as a hard-coded literal, arriving from the other direction.
-- -----------------------------------------------------------------------------

create or replace function erp.resource_coverage_report(p_locale text default 'en')
returns table (source_table text, key text, finding text)
language sql
stable
set search_path = ''
as $$
  with referenced as (
    select 'erp_ref.module'          as src, m.name_key  as k from erp_ref.module m
    union all
    select 'erp_ref.permission',      p.name_key from erp_ref.permission p
    union all
    select 'erp_ref.config_type',     c.name_key from erp_ref.config_type c
    union all
    select 'erp_ref.decision_point',  d.name_key from erp_ref.decision_point d
    union all
    select 'erp_ref.event_type',      e.name_key from erp_ref.event_type e
    union all
    select 'erp_ref.legislation_pack', lp.name_key from erp_ref.legislation_pack lp
    union all
    select 'erp_ref.statutory_output', so.name_key from erp_ref.statutory_output so
  )
  select r.src, r.k,
         format('no %s resource exists for this key', p_locale)
    from referenced r
   where r.k is not null
     and not exists (
       select 1 from erp_ref.resource res
        where res.key = r.k and res.locale = p_locale)
   order by 1, 2
$$;

create or replace function erp.assert_resource_coverage(p_locale text default 'en')
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s: %s', source_table, key), E'\n')
    into v_count, v_detail
    from erp.resource_coverage_report(p_locale);

  if v_count > 0 then
    raise exception E'ERPWARE_RESOURCE_GAP: % key(s) with no % string\n%',
      v_count, p_locale, v_detail;
  end if;

  return format('resources: every referenced key resolves in %s', p_locale);
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
