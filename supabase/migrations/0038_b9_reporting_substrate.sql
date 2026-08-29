-- =============================================================================
-- ERPWare — B9 (part 3/3): the reporting substrate
-- Spec 5.10 (Reporting and analytics), 3.3 (data classification)
--
-- Two clauses in 5.10 are invariants rather than features, and they are the
-- two this migration is built around:
--
--   "centrally defined KPI framework so a metric has one calculation"
--   "full traceability from any reported figure to its source event"
--
-- Everything else in 5.10 — catalogues, dashboards, drill-down, export,
-- scheduled distribution — is presentation over these two. Get them wrong and
-- no amount of dashboard fixes it: two teams quote different revenue figures
-- and nobody can say which is right, or a figure is queried and nobody can say
-- where it came from.
--
-- "A metric has one calculation" is enforced the way B3 enforces effective
-- dating: an exclusion constraint means at most one definition of a KPI is in
-- force at any instant, per tenant. Not a convention, not a review checklist —
-- a second overlapping definition cannot be inserted. Redefining a metric is
-- therefore always a dated supersession, which is also what makes a historical
-- figure reproducible: you can ask what the definition was in March.
--
-- "Full traceability" is enforced by refusing to register a reporting source
-- that cannot say how to get back to its rows. erp.governed_view.lineage_columns
-- is mandatory for anything a KPI reads, so drill-down is a property of the
-- registration rather than something each report reimplements.
--
-- And one lesson carried forward rather than relearned. The worst defect found
-- in this whole build was a view that bypassed row-level security because a
-- view runs as its owner and the owner holds BYPASSRLS. Reporting is where that
-- mistake is most tempting and most damaging — a "governed view for external
-- analytics tools" that quietly returns every tenant's data is precisely the
-- shape of it. So erp.assert_governed_views_are_safe() checks every registered
-- view is security_invoker and that everything underneath it has RLS enabled.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Governed sources
-- -----------------------------------------------------------------------------

create table erp.governed_view (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key        text,
  name            text,
  description     text,
  module_code     text references erp_ref.module(code),

  -- The relation this exposes. Schema-qualified and checked to exist.
  source_schema   text not null,
  source_name     text not null,

  -- Spec 5.10: role- and scope-limited. Reading through this source requires
  -- this permission, and the data classes name what may be seen — costs and
  -- margins being the routine case where "can see the order" and "can see what
  -- we paid" are different answers.
  required_permission text not null references erp_ref.permission(code),
  data_classes    text[] not null default '{}'::text[],

  -- Spec 5.10: "full traceability from any reported figure to its source
  -- event". These are the columns that identify the underlying rows, and they
  -- are mandatory for anything a KPI reads. A source that cannot say how to get
  -- back to its rows cannot be drilled into, and a figure nobody can drill into
  -- is a number on a slide.
  lineage_columns text[] not null default '{}'::text[],

  is_analytics_exposed boolean not null default false,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  constraint governed_view_has_a_label
    check (name_key is not null or name is not null)
);

comment on table erp.governed_view is
  'Spec 5.10: the governed sources reporting may read, each with the permission '
  'it requires, the data classes it exposes, and how to get back to the rows '
  'behind a figure.';

-- The relation must exist, and it must not be something that lets a reporting
-- session see past its tenant.
create or replace function erp.check_governed_view_source()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_relkind char;
  v_rls     boolean;
begin
  select c.relkind, c.relrowsecurity into v_relkind, v_rls
    from pg_catalog.pg_class c
   where c.relname = new.source_name
     and c.relnamespace = to_regnamespace(new.source_schema);

  if v_relkind is null then
    raise exception
      'ERPWARE_UNKNOWN_REPORTING_SOURCE: %.% does not exist',
      new.source_schema, new.source_name
      using errcode = '23503';
  end if;

  if v_relkind not in ('r', 'v', 'm', 'p') then
    raise exception
      'ERPWARE_INVALID_REPORTING_SOURCE: %.% is not a table, view or '
      'materialised view', new.source_schema, new.source_name
      using errcode = '22023';
  end if;

  -- A materialised view is a snapshot, and row-level security does not apply to
  -- reading one. Exposing it to analytics would hand over every tenant's rows.
  if v_relkind = 'm' and new.is_analytics_exposed then
    raise exception
      'ERPWARE_UNSAFE_ANALYTICS_SOURCE: %.% is a materialised view; RLS does '
      'not apply when reading one, so it cannot be exposed to analytics',
      new.source_schema, new.source_name
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger t_governed_view_source
  before insert or update on erp.governed_view
  for each row execute function erp.check_governed_view_source();

-- -----------------------------------------------------------------------------
-- KPIs: one metric, one calculation
-- -----------------------------------------------------------------------------

create type erp.kpi_aggregation as enum (
  'sum', 'count', 'count_distinct', 'average', 'minimum', 'maximum', 'ratio'
);

create table erp.kpi (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key        text,
  name            text,
  description     text,
  module_code     text references erp_ref.module(code),
  -- What the number is counted in. Two KPIs that agree on the calculation and
  -- disagree on the unit still disagree.
  unit            text,
  currency_scoped boolean not null default false,
  higher_is_better boolean,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  constraint kpi_has_a_label check (name_key is not null or name is not null)
);

comment on table erp.kpi is
  'Spec 5.10: the centrally defined metric. The calculation lives in '
  'erp.kpi_version, where an exclusion constraint guarantees exactly one is in '
  'force at a time.';

create table erp.kpi_version (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  kpi_id          uuid not null,
  version         integer not null check (version >= 1),

  governed_view_id uuid not null,
  aggregation     erp.kpi_aggregation not null,
  -- A column of the governed view, not an expression. An expression here would
  -- be SQL held as tenant configuration, which is a tenant-specific code path
  -- wearing a different hat (Part 7).
  measure_column  text,
  -- Optional JsonLogic over the source row, reusing B3's interpreter rather
  -- than inventing a second filter language.
  filter          jsonb,
  -- For 'ratio' only: the denominator.
  denominator_column text,

  status          erp.config_version_status not null default 'draft',
  effective_from  date not null,
  effective_to    date,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,

  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, kpi_id, version),
  foreign key (tenant_id, kpi_id) references erp.kpi (tenant_id, id) on delete cascade,
  foreign key (tenant_id, governed_view_id)
    references erp.governed_view (tenant_id, id) on delete restrict,

  constraint kpi_version_dates check (effective_to is null or effective_to > effective_from),
  constraint kpi_version_measure_present check (
    case aggregation
      when 'count' then true
      when 'ratio' then measure_column is not null and denominator_column is not null
      else measure_column is not null
    end),

  -- The invariant, structurally. Two definitions of one metric cannot both be
  -- in force: the insert fails. "A metric has one calculation" stops being a
  -- policy somebody has to uphold.
  constraint kpi_version_one_in_force
    exclude using gist (
      tenant_id with =,
      kpi_id with =,
      daterange(effective_from, effective_to, '[)') with &&
    ) where (status = 'active')
);

comment on constraint kpi_version_one_in_force on erp.kpi_version is
  'Spec 5.10: "a metric has one calculation". Two overlapping active '
  'definitions cannot be inserted, so redefining a metric is always a dated '
  'supersession — which is also what makes a historical figure reproducible.';

create index on erp.kpi_version (tenant_id, kpi_id, effective_from desc);

-- A KPI may only read a source that can be traced back. Refusing this at
-- definition time is the difference between drill-down being a property of the
-- platform and being something each report is expected to have remembered.
create or replace function erp.check_kpi_source_is_traceable()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  gv erp.governed_view%rowtype;
begin
  select * into gv from erp.governed_view
   where tenant_id = new.tenant_id and id = new.governed_view_id;

  if cardinality(gv.lineage_columns) = 0 then
    raise exception
      'ERPWARE_UNTRACEABLE_KPI_SOURCE: governed view % declares no lineage '
      'columns, so a figure computed from it could not be drilled into',
      gv.code
      using errcode = '22023',
      detail = 'Spec 5.10 requires traceability from any reported figure to '
               'its source.';
  end if;

  return new;
end;
$$;

create trigger t_kpi_version_traceable
  before insert or update on erp.kpi_version
  for each row execute function erp.check_kpi_source_is_traceable();

-- Which definition applies on a given date. Reports ask this rather than
-- picking a version, so a figure for March uses March's definition even if the
-- metric was redefined in June.
create or replace function erp.kpi_definition_in_force(
  p_kpi_code text,
  p_on       date default current_date
) returns erp.kpi_version
language sql
stable
security invoker
set search_path = ''
as $$
  select kv.*
    from erp.kpi_version kv
    join erp.kpi k on k.tenant_id = kv.tenant_id and k.id = kv.kpi_id
   where kv.tenant_id = erp.require_tenant_id()
     and k.code = p_kpi_code
     and kv.status = 'active'
     and kv.effective_from <= p_on
     and (kv.effective_to is null or kv.effective_to > p_on)
$$;

comment on function erp.kpi_definition_in_force(text, date) is
  'The one definition in force on a date. Reports ask by date rather than '
  'choosing a version, so a figure for March is computed the way March was.';

-- -----------------------------------------------------------------------------
-- The catalogue
-- -----------------------------------------------------------------------------

create table erp.report (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key        text,
  name            text,
  description     text,
  module_code     text references erp_ref.module(code),
  governed_view_id uuid,
  -- A report is a presentation of KPIs and columns from one governed source.
  -- It never carries its own calculation: that is what the KPI is for, and a
  -- report with its own arithmetic is the second definition of a metric
  -- arriving by the back door.
  kpi_codes       text[] not null default '{}'::text[],
  default_filter  jsonb,
  audience_role_codes text[] not null default '{}'::text[],
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, governed_view_id)
    references erp.governed_view (tenant_id, id) on delete restrict,
  constraint report_has_a_label check (name_key is not null or name is not null)
);

comment on table erp.report is
  'Spec 5.10: the governed report catalogue. A report presents KPIs; it never '
  'carries its own arithmetic, because that is a second definition of a metric '
  'arriving by the back door.';

-- -----------------------------------------------------------------------------
-- Traceability
-- -----------------------------------------------------------------------------

-- Given a KPI and a date, say exactly how the number would be produced: which
-- source, which definition, which lineage columns lead back to the rows. This
-- is the machine-readable answer to "where did this figure come from", and it
-- is derived from the registration rather than documented separately, so it
-- cannot drift from what the engine actually does.
create or replace function erp.figure_lineage(
  p_kpi_code text,
  p_on       date default current_date
) returns table (
  kpi_code        text,
  definition_version integer,
  effective_from  date,
  effective_to    date,
  source          text,
  aggregation     erp.kpi_aggregation,
  measure_column  text,
  filter          jsonb,
  lineage_columns text[],
  drill_down_sql  text
)
language sql
stable
security invoker
set search_path = ''
as $$
  select k.code, kv.version, kv.effective_from, kv.effective_to,
         format('%s.%s', gv.source_schema, gv.source_name),
         kv.aggregation, kv.measure_column, kv.filter, gv.lineage_columns,
         -- The query a person would run to see the rows behind the figure.
         -- Composed from the registration, not stored, so it cannot describe
         -- something the definition no longer does.
         format('select %s from %I.%I',
                array_to_string(
                  gv.lineage_columns
                  || case when kv.measure_column is not null
                          then array[kv.measure_column] else '{}'::text[] end,
                  ', '),
                gv.source_schema, gv.source_name)
    from erp.kpi_version kv
    join erp.kpi k  on k.tenant_id = kv.tenant_id and k.id = kv.kpi_id
    join erp.governed_view gv
      on gv.tenant_id = kv.tenant_id and gv.id = kv.governed_view_id
   where kv.tenant_id = erp.require_tenant_id()
     and k.code = p_kpi_code
     and kv.status = 'active'
     and kv.effective_from <= p_on
     and (kv.effective_to is null or kv.effective_to > p_on)
$$;

comment on function erp.figure_lineage(text, date) is
  'Spec 5.10: full traceability from a reported figure to its source. Derived '
  'from the registration rather than documented alongside it, so it cannot '
  'describe something the definition no longer does.';

-- -----------------------------------------------------------------------------
-- The invariant that carries the hardest-won lesson in this build
-- -----------------------------------------------------------------------------

create or replace function erp.governed_view_safety_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A view runs with its OWNER's permissions unless security_invoker is set,
  -- and the owner holds BYPASSRLS. This is exactly the defect that made
  -- erp.effective_permission return every tenant's grants, and reporting is
  -- where it is most tempting to reintroduce.
  select 'a governed view is not security_invoker',
         format('%s.%s', gv.source_schema, gv.source_name),
         'it would run as its owner, who bypasses row-level security, and '
         'return every tenant''s rows'
    from erp.governed_view gv
    join pg_catalog.pg_class c
      on c.relname = gv.source_name
     and c.relnamespace = to_regnamespace(gv.source_schema)
   where c.relkind = 'v'
     and coalesce(
           (select option_value = 'true'
              from pg_catalog.pg_options_to_table(c.reloptions)
             where option_name = 'security_invoker'), false) = false
  union all
  -- A registered table source with RLS switched off is the same leak by a
  -- shorter route.
  select 'a governed view reads a table with row-level security disabled',
         format('%s.%s', gv.source_schema, gv.source_name),
         'reporting through it would not be tenant-scoped'
    from erp.governed_view gv
    join pg_catalog.pg_class c
      on c.relname = gv.source_name
     and c.relnamespace = to_regnamespace(gv.source_schema)
   where c.relkind in ('r', 'p')
     and not c.relrowsecurity
  union all
  -- Refusal, checked as data as well as enforced by trigger: a KPI whose
  -- source cannot be drilled into.
  select 'a KPI reads a source that declares no lineage columns', k.code,
         format('governed view %s', gv.code)
    from erp.kpi_version kv
    join erp.kpi k on k.tenant_id = kv.tenant_id and k.id = kv.kpi_id
    join erp.governed_view gv
      on gv.tenant_id = kv.tenant_id and gv.id = kv.governed_view_id
   where cardinality(gv.lineage_columns) = 0
  union all
  -- A report carrying KPI codes that do not exist promises a figure it cannot
  -- produce.
  select 'a report references a KPI that does not exist', r.code, missing.code
    from erp.report r
    cross join lateral unnest(r.kpi_codes) as missing(code)
   where not exists (
     select 1 from erp.kpi k
      where k.tenant_id = r.tenant_id and k.code = missing.code)
$$;

create or replace function erp.assert_governed_views_are_safe()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.governed_view_safety_report();

  if v_count > 0 then
    raise exception 'ERPWARE_REPORTING_UNSAFE: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  return '';
end;
$$;

select erp_meta.register_table('erp', 'governed_view', 'tenant_scoped',
  'Spec 5.10: the governed sources reporting may read.');
select erp_meta.register_table('erp', 'kpi', 'tenant_scoped',
  'Spec 5.10: the centrally defined metric.');
select erp_meta.register_table('erp', 'kpi_version', 'tenant_scoped',
  'The calculation, effective-dated, at most one in force at a time.');
select erp_meta.register_table('erp', 'report', 'tenant_scoped',
  'Spec 5.10: the governed report catalogue.');

select erp.assert_governed_views_are_safe();

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_isolation();
