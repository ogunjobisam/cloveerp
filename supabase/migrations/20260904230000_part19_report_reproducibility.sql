-- =============================================================================
-- Part 19 — report definitions that are versioned, parameterised and reproducible
--
-- The governed query layer of §19.1 already exists: erp.governed_view,
-- erp.kpi, erp.kpi_version, erp.report, and erp.assert_governed_views_are_safe()
-- refusing a view that is not security_invoker or a source with row security
-- switched off. That machinery is sound and this migration does not touch it.
--
-- What §19.2 asks for and was not there:
--
--   "report — versioned, effective-dated: governed view, parameters, columns,
--   grouping, default sort, permitted output formats, required permission"
--
-- erp.report carried none of version, effective dating, parameters, columns,
-- grouping, sort, formats or permission. It named a governed view and some KPI
-- codes, and that was the whole definition.
--
--   "Every rendered report records its definition version, parameters, the user,
--   and the time — so a figure quoted in a meeting can be reproduced exactly."
--
-- Nothing recorded a rendered report at all. That sentence is the strongest
-- claim in Part 19 and it had no table behind it: a figure quoted in a meeting
-- could not be reproduced, because nothing remembered which definition produced
-- it or what it was asked.
--
--   §19.3 "Interactive execution has a time budget and a row cap; beyond either,
--   the request becomes a scheduled extract rather than failing."
--
-- Note "rather than failing". A budget that raises an error is not what this
-- says: the user asked a reasonable question and must get an answer, later.
--
-- Versioning mirrors erp.kpi_version exactly — a separate version table,
-- effective-dated, with the same "effective_to is null or after effective_from"
-- constraint — rather than inventing a second shape for the same idea. Two
-- versioning patterns in one schema is how a codebase stops being readable.
-- =============================================================================

-- ── §19.2 the version ───────────────────────────────────────────────────────

create table if not exists erp.report_version (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references erp.tenant(id) on delete cascade,
  report_id             uuid not null,
  version               integer not null,
  governed_view_id      uuid not null,
  columns               text[] not null default '{}',
  group_by              text[] not null default '{}',
  default_sort          text[] not null default '{}',
  output_formats        text[] not null default '{csv}',
  required_permission   text not null default 'reporting.read',
  -- §19.3. Milliseconds and rows, because "a time budget and a row cap" are the
  -- two things an interactive request can exceed.
  time_budget_ms        integer not null default 5000,
  row_cap               integer not null default 10000,
  status                text not null default 'active',
  effective_from        date not null default current_date,
  effective_to          date,
  note                  text,
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  constraint report_version_version_positive check (version >= 1),
  constraint report_version_dates_ordered
    check (effective_to is null or effective_to > effective_from),
  constraint report_version_budget_positive
    check (time_budget_ms > 0 and row_cap > 0),
  constraint report_version_status_known
    check (status in ('draft','active','superseded')),
  constraint report_version_has_columns
    check (cardinality(columns) > 0),
  constraint report_version_unique_per_report
    unique (tenant_id, report_id, version),
  -- The tenant-scoped foreign key target every child below uses. Referencing
  -- (tenant_id, id) rather than id alone is what stops a child row pointing at
  -- another organisation's version.
  constraint report_version_tenant_id_key unique (tenant_id, id),
  constraint report_version_report_fk
    foreign key (tenant_id, report_id) references erp.report (tenant_id, id) on delete cascade,
  constraint report_version_view_fk
    foreign key (tenant_id, governed_view_id) references erp.governed_view (tenant_id, id)
);

comment on table erp.report_version is
  'Specification v1.2 §19.2: a report is "versioned, effective-dated: governed '
  'view, parameters, columns, grouping, default sort, permitted output formats, '
  'required permission". Shaped after erp.kpi_version rather than inventing a '
  'second versioning pattern for the same idea.';

comment on column erp.report_version.time_budget_ms is
  '§19.3''s time budget. Exceeding it makes the request a scheduled extract, '
  'never an error: the question was reasonable and deserves an answer, later.';

-- ── §19.2 typed parameters that cannot widen scope ──────────────────────────

create table if not exists erp.report_parameter (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  report_version_id   uuid not null,
  code                text not null,
  name_key            text,
  data_type           text not null,
  is_required         boolean not null default false,
  default_value       text,
  -- The scope guard. §19.2: "a report cannot be parameterised into reading
  -- outside its scope". A parameter that filters a column is safe; one that
  -- names a scoping column would let the caller ask for another company's rows
  -- through a report, which §19.1 forbids in the same breath as saying scoping
  -- lives in the view.
  filters_column      text not null,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint report_parameter_type_known
    check (data_type in ('text','integer','numeric','date','timestamptz','boolean','uuid')),
  constraint report_parameter_unique_per_version unique (tenant_id, report_version_id, code),
  constraint report_parameter_version_fk
    foreign key (tenant_id, report_version_id)
      references erp.report_version (tenant_id, id) on delete cascade
);

comment on table erp.report_parameter is
  'Specification v1.2 §19.2: "Parameters are typed and validated; a report '
  'cannot be parameterised into reading outside its scope." filters_column is '
  'what makes the second half checkable — a parameter naming a scoping column '
  'is refused by erp.assert_reports_reproducible().';

-- ── §19.2 the record that makes a figure reproducible ───────────────────────

create table if not exists erp.report_run (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  report_id           uuid not null,
  report_version_id   uuid not null,
  version             integer not null,
  parameters          jsonb not null default '{}',
  run_by              uuid,
  run_at              timestamptz not null default now(),
  row_count           integer,
  duration_ms         integer,
  outcome             text not null,
  extract_reason      text,
  constraint report_run_outcome_known
    check (outcome in ('completed','deferred_to_extract','refused')),
  -- §19.3: deferral is not failure, and it must say which budget it hit.
  constraint report_run_extract_reason_present
    check ((outcome <> 'deferred_to_extract') or extract_reason is not null),
  constraint report_run_version_fk
    foreign key (tenant_id, report_version_id)
      references erp.report_version (tenant_id, id) on delete cascade
);

create index if not exists report_run_by_report
  on erp.report_run (tenant_id, report_id, run_at desc);

comment on table erp.report_run is
  'Specification v1.2 §19.2: "Every rendered report records its definition '
  'version, parameters, the user, and the time — so a figure quoted in a meeting '
  'can be reproduced exactly." Append-only: a run that could be edited would '
  'reproduce a figure nobody actually saw.';

-- ── §19.3 execution, which defers rather than fails ─────────────────────────

create or replace function erp.run_report(p_report_code text,
                                          p_parameters jsonb default '{}',
                                          p_estimated_rows integer default null,
                                          p_estimated_ms integer default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_report  erp.report%rowtype;
  v_ver     erp.report_version%rowtype;
  v_param   record;
  v_run     uuid;
  v_reason  text;
  v_outcome text;
begin
  select * into v_report from erp.report r
   where r.tenant_id = v_tenant and r.code = p_report_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_REPORT: % is not a report in this organisation', p_report_code
      using errcode = '23503';
  end if;

  -- The version in force TODAY, which is what makes a figure reproducible: a
  -- report re-run tomorrow under a new version is a different figure, and the
  -- run record says which one produced it.
  select * into v_ver from erp.report_version rv
   where rv.tenant_id = v_tenant and rv.report_id = v_report.id
     and rv.status = 'active'
     and rv.effective_from <= current_date
     and (rv.effective_to is null or rv.effective_to > current_date)
   order by rv.version desc
   limit 1;

  if not found then
    raise exception
      'ERPWARE_REPORT_NOT_IN_FORCE: % has no version in force on %',
      p_report_code, current_date
      using errcode = '23503',
            hint = 'A report with no effective version is a definition nobody '
                   'has agreed to yet.';
  end if;

  -- §19.1: "a report is not a way to see what a screen would refuse."
  perform erp.authorise(v_ver.required_permission, null, null, null,
                        'report', v_report.id);

  -- §19.2: typed and validated. A required parameter absent, or one nobody
  -- declared, is refused before anything is read.
  for v_param in
    select * from erp.report_parameter rp
     where rp.tenant_id = v_tenant and rp.report_version_id = v_ver.id
  loop
    if v_param.is_required
       and not (p_parameters ? v_param.code)
       and v_param.default_value is null then
      raise exception 'ERPWARE_REPORT_PARAMETER_MISSING: % requires %',
        p_report_code, v_param.code
        using errcode = '23502';
    end if;
  end loop;

  if exists (
    select 1 from jsonb_object_keys(p_parameters) k
     where not exists (select 1 from erp.report_parameter rp
                        where rp.tenant_id = v_tenant
                          and rp.report_version_id = v_ver.id
                          and rp.code = k))
  then
    raise exception
      'ERPWARE_REPORT_PARAMETER_UNKNOWN: % was given a parameter it does not declare',
      p_report_code
      using errcode = '22023',
            hint = 'An undeclared parameter is the shape a scope widening takes.';
  end if;

  -- §19.3. Deferral, not failure.
  v_reason := case
    when p_estimated_rows is not null and p_estimated_rows > v_ver.row_cap
      then format('estimated %s rows against a cap of %s',
                  p_estimated_rows, v_ver.row_cap)
    when p_estimated_ms is not null and p_estimated_ms > v_ver.time_budget_ms
      then format('estimated %sms against a budget of %sms',
                  p_estimated_ms, v_ver.time_budget_ms)
    else null end;

  v_outcome := case when v_reason is null then 'completed'
                    else 'deferred_to_extract' end;

  insert into erp.report_run
    (tenant_id, report_id, report_version_id, version, parameters,
     run_by, row_count, duration_ms, outcome, extract_reason)
  values (v_tenant, v_report.id, v_ver.id, v_ver.version, p_parameters,
          erp.current_principal_id(), p_estimated_rows, p_estimated_ms,
          v_outcome, v_reason)
  returning id into v_run;

  return jsonb_build_object(
    'run_id', v_run,
    'report', p_report_code,
    'version', v_ver.version,
    'outcome', v_outcome,
    'extract_reason', v_reason,
    'columns', to_jsonb(v_ver.columns),
    'parameters', p_parameters);
end;
$$;

comment on function erp.run_report is
  'Specification v1.2 §19.2 and §19.3. Resolves the version in force, authorises '
  'on it, validates the parameters, and records the run. Over budget it defers '
  'to an extract and says which budget it hit — "the request becomes a scheduled '
  'extract rather than failing".';

-- ── The assertion ───────────────────────────────────────────────────────────

create or replace function erp.report_reproducibility_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- 1. A report with no version at all cannot be run, and cannot say which
  --    definition produced a figure.
  select 'a report has no version', r.code,
         'a report with no version is a name without a definition'
    from erp.report r
   where not exists (select 1 from erp.report_version rv
                      where rv.tenant_id = r.tenant_id and rv.report_id = r.id)

  union all

  -- 2. Two versions in force on the same day. The run record would name one of
  --    them and "reproduced exactly" would depend on which the planner chose.
  select 'a report has more than one version in force', r.code,
         format('%s versions effective today', count(*)::text)
    from erp.report r
    join erp.report_version rv
      on rv.tenant_id = r.tenant_id and rv.report_id = r.id
   where rv.status = 'active'
     and rv.effective_from <= current_date
     and (rv.effective_to is null or rv.effective_to > current_date)
   group by r.code
  having count(*) > 1

  union all

  -- 3. §19.2's scope guard. A parameter that filters a scoping column is a
  --    parameter that can ask for somebody else's rows — which §19.1 forbids in
  --    the same breath as putting scoping in the view.
  select 'a parameter filters a scoping column', rp.code,
         format('%s is scoping, and a report cannot be parameterised outside its scope',
                rp.filters_column)
    from erp.report_parameter rp
   where rp.filters_column in ('tenant_id', 'entity_id', 'site_id', 'department_id')

  union all

  -- 4. A run naming a version that has gone. The record would claim
  --    reproducibility it cannot deliver, which is worse than recording nothing.
  select 'a run names a version that no longer exists', rr.id::text,
         'the figure it produced can no longer be reproduced'
    from erp.report_run rr
   where not exists (select 1 from erp.report_version rv
                      where rv.tenant_id = rr.tenant_id and rv.id = rr.report_version_id)

  union all

  -- 5. A deferral that does not say which budget it hit. §19.3 distinguishes
  --    deferral from failure, and a deferral nobody can explain reads as one.
  select 'a deferred run does not say why', rr.id::text,
         'deferral without a reason is indistinguishable from a failure'
    from erp.report_run rr
   where rr.outcome = 'deferred_to_extract'
     and coalesce(btrim(rr.extract_reason), '') = ''

  union all

  -- 6. A version whose required permission is not a permission. It would
  --    authorise against nothing, and erp.authorise() refuses an unknown code —
  --    so this is a report that cannot be run, found before somebody runs it.
  select 'a version requires a permission that does not exist', rv.id::text,
         rv.required_permission
    from erp.report_version rv
   where not exists (select 1 from erp_ref.permission p
                      where p.code = rv.required_permission)

  order by 1, 2
$$;

comment on function erp.report_reproducibility_report is
  'Specification v1.2 §19.2 and §19.3. Read by erp.assert_reports_reproducible().';

create or replace function erp.assert_reports_reproducible()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_reports integer; v_runs integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.report_reproducibility_report();

  if v_count > 0 then
    raise exception 'ERPWARE_REPORT_NOT_REPRODUCIBLE: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§19.2 requires a figure quoted in a meeting to be '
                   'reproducible exactly. That needs one version in force, '
                   'parameters that cannot widen scope, and a run record that '
                   'still resolves.';
  end if;

  select count(*) into v_reports from erp.report_version;
  select count(*) into v_runs from erp.report_run;
  return format('reporting: %s report version(s), %s run(s), every figure traceable',
                v_reports, v_runs);
end;
$$;

comment on function erp.assert_reports_reproducible is
  'Fails where a report has no version or more than one in force, where a '
  'parameter could widen scope, where a run names a version that has gone, '
  'where a deferral does not say why, or where a version requires a permission '
  'that does not exist.';

-- ── Registration ────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp','report_version','tenant_scoped',
   'Part 19 §19.2. The versioned, effective-dated definition of a report.'),
  ('erp','report_parameter','tenant_scoped',
   'Part 19 §19.2. Typed parameters, with the column each filters so the scope guard is checkable.'),
  ('erp','report_run','tenant_scoped_append_only',
   'Part 19 §19.2. The record that makes a figure reproducible. Append-only: a run that could be edited would reproduce a figure nobody saw.')
on conflict (schema_name, table_name) do nothing;

-- §19.2 says "Reports are configuration and promote through change sets, so a
-- tenant's own reports move between its environments the same way everything
-- else does." erp.report already promotes. Its version and parameters do NOT,
-- and this migration does not make them.
--
-- That is a real gap, not an oversight, so it is recorded rather than left for
-- somebody to discover: promoting a report today moves the name and leaves the
-- definition behind. Closing it means a promoter branch inside
-- erp.apply_change_set_item — a 45-branch CASE — and a matching arm in
-- erp.configuration_manifest, which is a change worth making deliberately and
-- with its own suite rather than appended to this one.
--
-- Registering the tables as promotable WITHOUT that branch would be worse than
-- leaving them out: erp.assert_configuration_promotable() would fail, and the
-- only way to make it pass would be to claim a promoter branch that does not
-- exist. The register refusing to hold a claim nobody can honour is the whole
-- point of it.
insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values
  ('report_version_outside_promotion',
   'A report promotes, but its version and parameters do not',
   'v1.2 §19.2',
   'erp.report_version and erp.report_parameter are tenant-scoped, row-secured '
   'and audited, but are not on erp_meta.promotable_surface, so a change set '
   'that promotes a report moves the report row and leaves its definition '
   'behind.',
   'Closing it needs a branch in erp.apply_change_set_item and an arm in '
   'erp.configuration_manifest. Both are deliberate changes to the promoter, '
   'and doing them as an afterthought to the table design is how a promoter '
   'branch ends up writing half an object. Recorded open so the next change to '
   'reporting starts from a known gap rather than rediscovering it.',
   'open',
   'erp_meta.promotable_surface holds erp.report and not erp.report_version; '
   'erp.apply_change_set_item has no branch for a report version.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('report_reproducibility', 'Reports reproducible', 'assertion', 'platform',
   'erp', 'assert_reports_reproducible', '',
   'report_reproducibility_report', '',
   'Part 19''s claim that a figure quoted in a meeting can be reproduced '
   'exactly: one version in force per report, parameters that cannot be used '
   'to widen scope, and a run record that still resolves to the definition '
   'that produced it.',
   true, 55)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- Part 23: D1 gains an enforcement point here. A report is the classic route to
-- reading another organisation's rows, and §19.1 puts the scoping in the view
-- precisely so a report cannot forget it.
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
('D1','erp','assert_reports_reproducible',
 'A parameter naming a scoping column would let a caller ask for another organisation''s rows through a report. This refuses that shape, which is D1 defended where it is most tempting to leak.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

insert into erp_ref.resource (key, locale, value, description) values
('report.deferred_to_extract', 'en',
 'Too large to show now — scheduled as an extract',
 '§19.3: beyond the time budget or row cap the request becomes a scheduled extract rather than failing.')
on conflict (key, locale) do update set value = excluded.value;

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
select erp.assert_configuration_promotable();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_reports_reproducible();
select erp.assert_product_decisions_enforced();
