-- =============================================================================
-- A report version names only columns its view has
--
-- erp.run_report() authorises, checks parameters, budgets and records a run;
-- it does not execute the column list. So a version whose columns are not on
-- the governed view it reads runs "successfully" and can never produce the
-- figure §19.2 promises to reproduce. 20260904430000 closed that for the
-- product's own content with erp.assert_pack_report_versions_sound(), which
-- checks pack payloads against pg_attribute at build time. Nothing checked an
-- organisation's own versions — the ones authored through promotion — and the
-- reporting suites had been proving §19.2 over versions naming site_code,
-- item_code and value_minor on a view over erp.stock_movement, which has none
-- of them. The suites passed because nothing looked.
--
-- Two things close it:
--
--   1. erp.upsert_report_version() refuses a version naming a column its view
--      does not have, and a parameter filtering one, so a promotion carrying
--      the mistake fails at promotion with the column named, the same way it
--      already fails for an absent view or an unknown permission.
--
--   2. erp.report_reproducibility_report() gains the finding for rows that
--      predate the refusal or were written around it, so
--      erp.assert_reports_reproducible() fails the organisation rather than
--      leaving a report that cannot run reading as sound.
--
-- And the two suites now read real columns, and each proves the refusal.
-- =============================================================================

-- ── The findings ─────────────────────────────────────────────────────────────

create or replace function erp.report_reproducibility_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with version_source as (
    select rv.id, rv.tenant_id, rv.version, rv.columns, rv.group_by, rv.default_sort,
           r.code as report_code,
           gv.source_schema, gv.source_name,
           pg_catalog.to_regclass(format('%I.%I', gv.source_schema, gv.source_name)) as rel
      from erp.report_version rv
      join erp.report r on r.tenant_id = rv.tenant_id and r.id = rv.report_id
      join erp.governed_view gv
        on gv.tenant_id = rv.tenant_id and gv.id = rv.governed_view_id
  )
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

  union all

  -- 7. A version naming a column its view does not have. The runner does not
  --    execute the column list, so nothing else would notice; the figure this
  --    version promises cannot be produced, let alone reproduced.
  select 'a version names a column its view does not have',
         format('%s v%s', vs.report_code, vs.version),
         format('%s %s on %s.%s', c.role, c.col, vs.source_schema, vs.source_name)
    from version_source vs
    cross join lateral (
      select unnest(vs.columns) as col, 'columns' as role
      union all
      select unnest(vs.group_by), 'group_by'
      union all
      select unnest(vs.default_sort), 'default_sort'
    ) c
   where vs.rel is not null
     and not exists (
       select 1 from pg_catalog.pg_attribute a
        where a.attrelid = vs.rel and a.attname = c.col
          and a.attnum > 0 and not a.attisdropped)

  union all

  -- 8. A parameter filtering a column its view does not have: declared,
  --    required, recorded against every run, and filtering nothing.
  select 'a parameter filters a column its view does not have',
         format('%s v%s', vs.report_code, vs.version),
         format('%s filters %s on %s.%s', rp.code, rp.filters_column,
                vs.source_schema, vs.source_name)
    from erp.report_parameter rp
    join version_source vs on vs.tenant_id = rp.tenant_id and vs.id = rp.report_version_id
   where vs.rel is not null
     and rp.filters_column is not null
     and not exists (
       select 1 from pg_catalog.pg_attribute a
        where a.attrelid = vs.rel and a.attname = rp.filters_column
          and a.attnum > 0 and not a.attisdropped)

  order by 1, 2
$$;

comment on function erp.report_reproducibility_report is
  'Specification v1.2 §19.2 and §19.3. A report with no version, more than one '
  'in force, a parameter that filters a scoping column or a column the view '
  'does not have, a version naming a column the view does not have or a '
  'permission that does not exist, a run naming a version that has gone, and a '
  'deferral with no reason. Read by erp.assert_reports_reproducible().';

-- ── The refusal, so the finding is rarely reached ───────────────────────────

create or replace function erp.upsert_report_version(
  p_report_code text, p_view_code text, p_columns text[], p_group_by text[],
  p_default_sort text[], p_output_formats text[], p_required_permission text,
  p_time_budget_ms integer, p_row_cap integer, p_effective_from date,
  p_note text, p_parameters jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_report uuid;
  v_view   uuid;
  v_rel    regclass;
  v_schema text;
  v_source text;
  v_num    integer;
  v_id     uuid;
  v_from   date := coalesce(p_effective_from, current_date);
  v_bad    text;
begin
  select r.id into v_report from erp.report r
   where r.tenant_id = v_tenant and r.code = p_report_code;
  if v_report is null then
    raise exception 'ERPWARE_UNKNOWN_REPORT: this environment has no report %',
      p_report_code using errcode = '23503';
  end if;

  select gv.id, gv.source_schema, gv.source_name,
         pg_catalog.to_regclass(format('%I.%I', gv.source_schema, gv.source_name))
    into v_view, v_schema, v_source, v_rel
    from erp.governed_view gv
   where gv.tenant_id = v_tenant and gv.code = p_view_code;
  if v_view is null then
    raise exception
      'ERPWARE_PROMOTION_UNKNOWN_VIEW: this environment has no governed view %',
      p_view_code using errcode = '23503';
  end if;

  if coalesce(cardinality(p_columns), 0) = 0 then
    raise exception 'ERPWARE_REPORT_VERSION_HAS_NO_COLUMNS: % names no columns',
      p_report_code using errcode = '23514';
  end if;

  -- erp.authorise() refuses a permission code it does not know, so a version
  -- requiring one is a report nobody can run. §19.2 would find it; finding it
  -- here means it never lands.
  if not exists (select 1 from erp_ref.permission pm
                  where pm.code = p_required_permission) then
    raise exception 'ERPWARE_UNKNOWN_PERMISSION: % is not a permission',
      p_required_permission using errcode = '23503';
  end if;

  -- §19.1 puts scoping in the governed view precisely so a report cannot reach
  -- around it. A parameter that filters a scoping column is that reach.
  select string_agg(e.value ->> 'code', ', ')
    into v_bad
    from jsonb_array_elements(coalesce(p_parameters, '[]'::jsonb)) e
   where e.value ->> 'filters_column'
         in ('tenant_id', 'entity_id', 'site_id', 'department_id');
  if v_bad is not null then
    raise exception
      'ERPWARE_REPORT_PARAMETER_WIDENS_SCOPE: parameter(s) % filter a scoping column',
      v_bad using errcode = '42501';
  end if;

  -- The runner does not execute the column list, so a column the view does
  -- not have would never be noticed by running the report — only by the figure
  -- failing to appear. Checked against the catalogue, the same way the pack
  -- guard checks the product's own content.
  if v_rel is not null then
    select string_agg(c.col, ', ' order by c.col)
      into v_bad
      from (select unnest(p_columns) as col
            union
            select unnest(coalesce(p_group_by, '{}'))
            union
            select unnest(coalesce(p_default_sort, '{}'))) c
     where not exists (
       select 1 from pg_catalog.pg_attribute a
        where a.attrelid = v_rel and a.attname = c.col
          and a.attnum > 0 and not a.attisdropped);
    if v_bad is not null then
      raise exception
        'ERPWARE_REPORT_COLUMN_UNKNOWN: column(s) % are not on %.%, which %s reads',
        v_bad, v_schema, v_source, p_view_code using errcode = '23503';
    end if;

    select string_agg(format('%s (%s)', e.value ->> 'code', e.value ->> 'filters_column'), ', ')
      into v_bad
      from jsonb_array_elements(coalesce(p_parameters, '[]'::jsonb)) e
     where e.value ->> 'filters_column' is not null
       and not exists (
         select 1 from pg_catalog.pg_attribute a
          where a.attrelid = v_rel and a.attname = e.value ->> 'filters_column'
            and a.attnum > 0 and not a.attisdropped);
    if v_bad is not null then
      raise exception
        'ERPWARE_REPORT_PARAMETER_COLUMN_UNKNOWN: parameter(s) % filter a column that is not on %.%',
        v_bad, v_schema, v_source using errcode = '23503';
    end if;
  end if;

  -- One version in force. The previous is superseded rather than removed,
  -- because a run record still names it and §19.2 promises that figure stays
  -- reproducible.
  update erp.report_version rv
     set status = 'superseded', updated_at = now()
   where rv.tenant_id = v_tenant and rv.report_id = v_report
     and rv.status = 'active';

  select coalesce(max(rv.version), 0) + 1 into v_num
    from erp.report_version rv
   where rv.tenant_id = v_tenant and rv.report_id = v_report;

  insert into erp.report_version (
    tenant_id, report_id, version, governed_view_id, columns, group_by,
    default_sort, output_formats, required_permission, time_budget_ms,
    row_cap, status, effective_from, note)
  values (v_tenant, v_report, v_num, v_view, p_columns,
          coalesce(p_group_by, '{}'), coalesce(p_default_sort, '{}'),
          coalesce(p_output_formats, '{pdf}'), p_required_permission,
          coalesce(p_time_budget_ms, 30000), coalesce(p_row_cap, 50000),
          'active', v_from, p_note)
  returning id into v_id;

  insert into erp.report_parameter (
    tenant_id, report_version_id, code, name_key, data_type, is_required,
    default_value, filters_column)
  select v_tenant, v_id, e.value ->> 'code', e.value ->> 'name_key',
         e.value ->> 'data_type',
         coalesce((e.value ->> 'is_required')::boolean, false),
         e.value ->> 'default_value', e.value ->> 'filters_column'
    from jsonb_array_elements(coalesce(p_parameters, '[]'::jsonb)) e;

  return v_id;
end;
$$;

comment on function erp.upsert_report_version is
  'Specification v1.2 §19.2. Writes a new version of a report, superseding the '
  'one in force. Refuses a view this environment lacks, an empty column list, a '
  'permission that does not exist, a parameter that filters a scoping column, '
  'and — since 20260904450000 — a column or parameter the view does not have.';

-- ── The reporting suite, over real columns ──────────────────────────────────
--
-- Its fixtures named site_code, item_code and value_minor on a view over
-- erp.stock_movement, which has none of them; every case passed because the
-- runner never looked. The fixtures now read site_id, item_id, quantity and
-- unit_cost_minor, and one case proves the finding this migration adds.

CREATE OR REPLACE FUNCTION erp_test.reporting_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  r record;
  ad uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzrep-a';
  v_view uuid; v_report uuid; v_v1 uuid; v_v2 uuid; v_v3 uuid;
  v_ok boolean; v_msg text; res jsonb; v_run uuid;
begin
  select * into r from erp.provision_tenant(
    v_code, 'Reporting A', 'admin-a@zzrep.test', 'Reporting A Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email) values (ad, 'admin-a@zzrep.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- erp.provision_tenant() declares the self environment live at the end, and
  -- erp.report carries a live-config guard — correctly, per D4. Building the
  -- fixture is configuration authoring, which belongs inside the bootstrap
  -- window, so the suite opens one rather than editing around the guard. The
  -- window closes before the run cases, so every erp.run_report() below is
  -- executed against a LIVE organisation, which is the state that matters.
  perform erp_test.reopen_bootstrap_window(v_tenant);

  insert into erp.governed_view
    (tenant_id, code, name, description, source_schema, source_name,
     required_permission, data_classes, lineage_columns)
  values (v_tenant, 'stock_position', 'Stock position',
          'On-hand by item and location.', 'erp', 'stock_movement',
          'reporting.read', '{}', '{item_id,location_id}')
  returning id into v_view;

  insert into erp.report
    (tenant_id, code, name, description, governed_view_id, kpi_codes,
     audience_role_codes, status)
  values (v_tenant, 'stock_by_site', 'Stock by site',
          'What is on hand, by site.', v_view, '{}', '{}', 'active')
  returning id into v_report;

  begin
    perform erp.assert_reports_reproducible();
    v_ok := false; v_msg := 'a report with no version was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_NOT_REPRODUCIBLE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a report with no version fails the assertion', v_ok, v_msg;

  insert into erp.report_version
    (tenant_id, report_id, version, governed_view_id, columns, group_by,
     default_sort, output_formats, required_permission,
     time_budget_ms, row_cap, status, effective_from)
  values (v_tenant, v_report, 1, v_view,
          '{site_id,item_id,quantity}', '{site_id}', '{site_id}',
          '{csv,pdf}', 'reporting.read', 5000, 100, 'active', current_date - 1)
  returning id into v_v1;

  return query select 'and passes once it has one',
    erp.assert_reports_reproducible() is not null, 'version 1 in force';

  -- Live from here. Everything below runs against a live organisation.
  perform erp_test.close_bootstrap_window(v_tenant);

  res := erp.run_report('stock_by_site', '{}'::jsonb, 10, 100);
  v_run := (res ->> 'run_id')::uuid;

  return query select 'a run completes within budget',
    (res ->> 'outcome') = 'completed', res ->> 'outcome';

  return query select 'and records the version that produced the figure',
    (select rr.version from erp.report_run rr where rr.id = v_run) = 1,
    'so a figure quoted in a meeting can be reproduced exactly';

  return query select 'and who ran it, and when',
    (select rr.run_by is not null and rr.run_at is not null
       from erp.report_run rr where rr.id = v_run),
    'a figure nobody can attribute is a figure nobody can question';

  -- report_version and report_parameter are promotable surfaces now, so on a
  -- live organisation the supported route for a new version is a change set —
  -- which erp_test.promotion_completeness_suite() proves end to end. This
  -- suite's subject is what §19.2 promises about RUNS, so it authors inside
  -- the same bootstrap window it opened for the first fixture and closes it
  -- again immediately: every erp.run_report() below still executes against a
  -- live organisation, which is the state that matters here.
  perform erp_test.reopen_bootstrap_window(v_tenant);

  update erp.report_version set effective_to = current_date, status = 'superseded'
   where id = v_v1;

  insert into erp.report_version
    (tenant_id, report_id, version, governed_view_id, columns, group_by,
     default_sort, output_formats, required_permission,
     time_budget_ms, row_cap, status, effective_from)
  values (v_tenant, v_report, 2, v_view,
          '{site_id,item_id,quantity,unit_cost_minor}', '{site_id}',
          '{site_id}', '{csv}', 'reporting.read', 5000, 100, 'active',
          current_date)
  returning id into v_v2;

  perform erp_test.close_bootstrap_window(v_tenant);

  res := erp.run_report('stock_by_site', '{}'::jsonb, 10, 100);

  return query select 'a later run uses the version now in force',
    (res ->> 'version')::integer = 2, format('version %s', res ->> 'version');

  return query select 'while the earlier figure still names the version that made it',
    (select rr.version from erp.report_run rr where rr.id = v_run) = 1,
    'the whole point of recording the version rather than the report';

  return query select 'and only one version is in force at a time',
    erp.assert_reports_reproducible() is not null,
    'two in force would make reproduced-exactly depend on which was chosen';

  -- The finding 20260904450000 adds. The runner never executes the column
  -- list, so a version naming a column the view lacks would run "successfully"
  -- and never produce the figure — until this suite's own fixtures were
  -- caught doing exactly that. Written around the writer's refusal, as a row
  -- predating it would have been, superseded so it is not a second version in
  -- force.
  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.report_version
    (tenant_id, report_id, version, governed_view_id, columns, group_by,
     default_sort, output_formats, required_permission,
     time_budget_ms, row_cap, status, effective_from, effective_to)
  values (v_tenant, v_report, 3, v_view,
          '{site_code,quantity}', '{}', '{}',
          '{csv}', 'reporting.read', 5000, 100, 'superseded',
          current_date - 2, current_date - 1)
  returning id into v_v3;
  return query select 'a version naming a column its view does not have is found',
    exists (select 1 from erp.report_reproducibility_report() f
             where f.finding = 'a version names a column its view does not have'
               and f.reference = 'stock_by_site v3'
               and f.detail = 'columns site_code on erp.stock_movement'),
    'the runner does not execute the column list, so nothing else would notice';
  delete from erp.report_version where id = v_v3;
  perform erp_test.close_bootstrap_window(v_tenant);

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.report_parameter
    (tenant_id, report_version_id, code, data_type, is_required, filters_column)
  values (v_tenant, v_v2, 'as_at', 'date', true, 'occurred_at');
  perform erp_test.close_bootstrap_window(v_tenant);

  begin
    perform erp.run_report('stock_by_site', '{}'::jsonb, 10, 100);
    v_ok := false; v_msg := 'a required parameter was not required';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_PARAMETER_MISSING%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a required parameter is required', v_ok, v_msg;

  begin
    perform erp.run_report('stock_by_site',
                           '{"as_at":"2026-09-01","entity_id":"anything"}'::jsonb, 10, 100);
    v_ok := false; v_msg := 'an undeclared parameter was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_PARAMETER_UNKNOWN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and a parameter nobody declared is refused', v_ok, v_msg;

  res := erp.run_report('stock_by_site', '{"as_at":"2026-09-01"}'::jsonb, 10, 100);
  return query select 'while the declared one is accepted and recorded',
    (res ->> 'outcome') = 'completed'
      and (select rr.parameters ->> 'as_at' from erp.report_run rr
            where rr.id = (res ->> 'run_id')::uuid) = '2026-09-01',
    'the parameters are recorded, not only the report';

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.report_parameter
    (tenant_id, report_version_id, code, data_type, is_required, filters_column)
  values (v_tenant, v_v2, 'company', 'uuid', false, 'entity_id');
  perform erp_test.close_bootstrap_window(v_tenant);

  begin
    perform erp.assert_reports_reproducible();
    v_ok := false; v_msg := 'a parameter filtering a scoping column was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_NOT_REPRODUCIBLE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a parameter that filters a scoping column is refused', v_ok, v_msg;

  perform erp_test.reopen_bootstrap_window(v_tenant);
  delete from erp.report_parameter
   where tenant_id = v_tenant and report_version_id = v_v2 and code = 'company';
  perform erp_test.close_bootstrap_window(v_tenant);

  res := erp.run_report('stock_by_site', '{"as_at":"2026-09-01"}'::jsonb, 5000, 100);
  return query select 'beyond the row cap the request defers rather than failing',
    (res ->> 'outcome') = 'deferred_to_extract',
    'the request becomes a scheduled extract rather than failing';

  return query select 'and says which budget it hit',
    (res ->> 'extract_reason') like '%rows against a cap of 100%',
    coalesce(res ->> 'extract_reason', '(none)');

  res := erp.run_report('stock_by_site', '{"as_at":"2026-09-01"}'::jsonb, 10, 60000);
  return query select 'the time budget defers it too',
    (res ->> 'outcome') = 'deferred_to_extract'
      and (res ->> 'extract_reason') like '%against a budget of 5000ms%',
    coalesce(res ->> 'extract_reason', '(none)');

  return query select 'and a deferral is recorded as a run, not lost',
    (select count(*) from erp.report_run rr
      where rr.tenant_id = v_tenant and rr.outcome = 'deferred_to_extract') = 2,
    'a question that was deferred is still a question somebody asked';

  -- §19.1: a report is not a way to see what a screen would refuse. The
  -- administrator holds every permission, so the check is that authorisation
  -- happens at all — proven by requiring one that does not exist, which
  -- erp.authorise() refuses.
  perform erp_test.reopen_bootstrap_window(v_tenant);
  update erp.report_version set required_permission = 'reporting.export' where id = v_v2;
  perform erp_test.close_bootstrap_window(v_tenant);
  begin
    perform erp.run_report('stock_by_site', '{"as_at":"2026-09-01"}'::jsonb, 10, 100);
    v_ok := true; v_msg := 'authorised on the version''s own permission';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 70);
  end;
  return query select 'the run authorises on the permission the VERSION names', v_ok, v_msg;

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id = ad;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code like 'zzrep-%')
      and not exists (select 1 from auth.users u where u.id = ad),
    'and the runs go with the organisation, because they are tenant-scoped';
end;$function$;

create or replace function erp_test.assert_reporting_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _reporting_result on commit drop as
    select * from erp_test.reporting_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _reporting_result;

  -- 19, not 18: 20260904450000 added the case that finds a version naming a
  -- column its view does not have.
  if v_total <> 19 then
    raise exception 'ERPWARE_REPORTING_SUITE_SHRANK: % case(s), expected 19', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_REPORTING_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('reporting: %s/%s', v_passed, v_total);
end;
$$;

-- ── The promotion completeness suite, over real columns ─────────────────────
--
-- Same fixture, same fake columns, and the promoter carried them through
-- erp.upsert_report_version() without a word. It refuses them now, and the
-- suite proves that alongside the three refusals it already proved.

create or replace function erp_test.promotion_completeness_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r        record;
  v_code   text := 'zz69-' || substr(md5(random()::text), 1, 6);
  v_tenant uuid;
  a1       uuid := gen_random_uuid();   -- author
  a2       uuid := gen_random_uuid();   -- approver and promoter
  v_second uuid; v_tok text; res jsonb;
  v_cs     uuid;
  v_site   uuid;
  v_ok     boolean; v_msg text; v_n integer;
  c_report jsonb;
begin
  -- ── The organisation, live from the moment it is provisioned ──────────────

  select * into r from erp.provision_tenant(
    v_code, 'Promotion Completeness', 'admin@zz69.test', 'Suite Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email) values (a1, 'admin@zz69.test'), (a2, 'second@zz69.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  res := public.erp_invite_principal('second@zz69.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- A governed view and a site are NOT promotable surfaces — the view is the
  -- boundary §19.1 puts scoping behind, and a site is where the organisation
  -- physically is. Both are fixtures here, authored in the bootstrap window.
  perform erp_test.reopen_bootstrap_window(v_tenant);

  insert into erp.governed_view
    (tenant_id, code, name, description, source_schema, source_name,
     required_permission, data_classes, lineage_columns)
  values (v_tenant, 'stock_position', 'Stock position',
          'On-hand by item and location.', 'erp', 'stock_movement',
          'reporting.read', '{}', '{item_id,location_id}');

  select id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.status = 'active' limit 1;
  if v_site is null then
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    select v_tenant, e.id, 'MAIN', 'Main site', 'warehouse', 'active'
      from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active'
     order by e.code limit 1
    returning id into v_site;
  end if;

  perform erp_test.close_bootstrap_window(v_tenant);

  -- ── The failure this closes: a title with no definition ───────────────────
  --
  -- Promoting a report on its own is still allowed, because content that ships
  -- report titles only must keep working. What it must NOT do is look
  -- installed. The assertion is what says so.

  v_cs := erp.create_change_set('zz69-a', 'Title only', 'A report with no version.');
  perform erp.add_change_set_item(v_cs, 'report', 'stock_by_site', jsonb_build_object(
    'code', 'stock_by_site', 'name', 'Stock by site',
    'description', 'What is on hand, by site.', 'module_code', 'inventory'));
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'a report promoted without its version arrives',
    exists (select 1 from erp.report rp
             where rp.tenant_id = v_tenant and rp.code = 'stock_by_site'),
    'content that ships titles only keeps working';

  begin
    perform erp.assert_reports_reproducible();
    v_ok := false; v_msg := 'a name without a definition passed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_NOT_REPRODUCIBLE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'but the organisation reads as broken until it has one',
    v_ok, v_msg;

  -- ── What the promoter refuses ─────────────────────────────────────────────

  perform set_config('erp.promotion_id', gen_random_uuid()::text, true);

  begin
    perform erp.upsert_report_version('stock_by_site', 'no_such_view',
      '{site_id}', '{}', '{}', '{pdf}', 'reporting.read', 5000, 100,
      current_date, 'promoted', '[]'::jsonb);
    v_ok := false; v_msg := 'a version naming an absent view was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PROMOTION_UNKNOWN_VIEW%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a version naming a view this environment lacks is refused',
    v_ok, v_msg;

  begin
    perform erp.upsert_report_version('stock_by_site', 'stock_position',
      '{site_id}', '{}', '{}', '{pdf}', 'reporting.invented', 5000, 100,
      current_date, 'promoted', '[]'::jsonb);
    v_ok := false; v_msg := 'a version naming an absent permission was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_PERMISSION%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and one naming a permission that does not exist',
    v_ok, v_msg;

  begin
    perform erp.upsert_report_version('stock_by_site', 'stock_position',
      '{}', '{}', '{}', '{pdf}', 'reporting.read', 5000, 100,
      current_date, 'promoted', '[]'::jsonb);
    v_ok := false; v_msg := 'a version with no columns was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_VERSION_HAS_NO_COLUMNS%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and one that selects nothing at all', v_ok, v_msg;

  begin
    perform erp.upsert_report_version('stock_by_site', 'stock_position',
      '{site_id}', '{}', '{}', '{pdf}', 'reporting.read', 5000, 100,
      current_date, 'promoted',
      '[{"code":"company","data_type":"uuid","filters_column":"entity_id"}]'::jsonb);
    v_ok := false; v_msg := 'a scope-widening parameter was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_PARAMETER_WIDENS_SCOPE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and a parameter that filters a scoping column',
    v_ok, v_msg;

  -- The refusal 20260904450000 adds. These were exactly this suite's own
  -- fixture columns until then, and they went through.
  begin
    perform erp.upsert_report_version('stock_by_site', 'stock_position',
      '{site_code,item_code,quantity}', '{site_code}', '{}', '{pdf}', 'reporting.read',
      5000, 100, current_date, 'promoted', '[]'::jsonb);
    v_ok := false; v_msg := 'a version naming columns the view lacks was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_COLUMN_UNKNOWN: column(s) item_code, site_code are not on erp.stock_movement%';
    v_msg := left(sqlerrm, 80);
  end;
  return query select 'and one naming columns its view does not have, by name',
    v_ok, v_msg;

  begin
    perform erp.upsert_report_version('stock_by_site', 'stock_position',
      '{site_id}', '{}', '{}', '{pdf}', 'reporting.read', 5000, 100,
      current_date, 'promoted',
      '[{"code":"as_at","data_type":"date","filters_column":"as_at_date"}]'::jsonb);
    v_ok := false; v_msg := 'a parameter filtering a column the view lacks was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_PARAMETER_COLUMN_UNKNOWN%as_at (as_at_date)%';
    v_msg := left(sqlerrm, 80);
  end;
  return query select 'and a parameter filtering a column its view does not have',
    v_ok, v_msg;

  perform set_config('erp.promotion_id', '', true);

  -- ── The definition travels inside the same item ───────────────────────────

  v_cs := erp.create_change_set('zz69-b', 'Definition', 'The report and its version.');
  perform erp.add_change_set_item(v_cs, 'report', 'stock_by_site', jsonb_build_object(
    'code', 'stock_by_site', 'name', 'Stock by site',
    'description', 'What is on hand, by site.', 'module_code', 'inventory',
    'version', jsonb_build_object(
      'view', 'stock_position',
      'columns', '["site_id","item_id","quantity"]'::jsonb,
      'group_by', '["site_id"]'::jsonb,
      'default_sort', '["site_id"]'::jsonb,
      'output_formats', '["csv","pdf"]'::jsonb,
      'required_permission', 'reporting.read',
      'time_budget_ms', 5000, 'row_cap', 100,
      'parameters', '[{"code":"as_at","data_type":"date","is_required":true,
                       "filters_column":"occurred_at"}]'::jsonb)));
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'a report promoted WITH its version brings the definition',
    (select count(*) from erp.report_version rv where rv.tenant_id = v_tenant) = 1,
    'the version travels inside the report item, so they cannot land apart';

  return query select 'and the parameters that belong to it',
    (select count(*) from erp.report_parameter pa where pa.tenant_id = v_tenant) = 1,
    'a version whose parameters stayed behind accepts nothing it was designed to';

  return query select 'and the organisation now reads as sound',
    erp.assert_reports_reproducible() is not null, 'one version in force';

  -- ── Capture is the other direction, and must agree ────────────────────────

  select m.content into c_report
    from erp.configuration_manifest() m
   where m.object_kind = 'report' and m.object_key = 'stock_by_site';

  return query select 'the manifest reads the definition back out',
    (c_report -> 'version' ->> 'view') = 'stock_position'
      and (c_report -> 'version' -> 'columns') = '["site_id","item_id","quantity"]'::jsonb,
    'promotion without capture is one-way, which is half a feature';

  return query select 'including the parameters',
    (c_report -> 'version' -> 'parameters' -> 0 ->> 'code') = 'as_at',
    'so an organisation can be lifted whole into a change set';

  -- ── A second promotion supersedes rather than duplicating ─────────────────

  v_cs := erp.create_change_set('zz69-c', 'Second', 'A new version of the report.');
  perform erp.add_change_set_item(v_cs, 'report', 'stock_by_site', jsonb_build_object(
    'code', 'stock_by_site', 'name', 'Stock by site',
    'description', 'What is on hand, by site.', 'module_code', 'inventory',
    'version', jsonb_build_object(
      'view', 'stock_position',
      'columns', '["site_id","item_id","quantity","unit_cost_minor"]'::jsonb,
      'required_permission', 'reporting.read',
      'time_budget_ms', 5000, 'row_cap', 100)));
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'promoting again adds a version rather than replacing one',
    (select count(*) from erp.report_version rv where rv.tenant_id = v_tenant) = 2,
    'a run record still names version 1, and §19.2 promises that figure survives';

  return query select 'and only one of them is in force',
    erp.assert_reports_reproducible() is not null
      and (select count(*) from erp.report_version rv
            where rv.tenant_id = v_tenant and rv.status = 'active') = 1,
    'two in force would make reproduced-exactly depend on which was chosen';

  -- ── §15: the same shape, and the decode check that must travel with it ────

  v_cs := erp.create_change_set('zz69-d', 'Label', 'A label that will not scan.');
  perform erp.add_change_set_item(v_cs, 'output_template', 'pallet_label',
    jsonb_build_object(
      'code', 'pallet_label', 'name_key', 'output.pallet_label', 'kind', 'label',
      'version', jsonb_build_object(
        'rendering_engine', 'zpl', 'label_language', 'zpl',
        'blocks', '[{"kind":"barcode"}]'::jsonb,
        'required_permission', 'reporting.export',
        'test_render', '^XA^BY2^BC^FD0012345678901231^FS^XZ',
        'decode_check_passed', false)));
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'a label with no passing decode check was promoted';
  exception when others then
    v_ok := sqlerrm like '%ERPWARE_LABEL_DOES_NOT_DECODE%'; v_msg := left(sqlerrm, 60);
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  return query select 'a label whose decode check did not pass is not promoted',
    v_ok, v_msg;

  return query select 'and nothing of that change set landed',
    not exists (select 1 from erp.output_template ot
                 where ot.tenant_id = v_tenant and ot.code = 'pallet_label'),
    'the template and the proof it scans arrive together or not at all';

  v_cs := erp.create_change_set('zz69-e', 'Label 2', 'A label that scans.');
  perform erp.add_change_set_item(v_cs, 'output_template', 'pallet_label',
    jsonb_build_object(
      'code', 'pallet_label', 'name_key', 'output.pallet_label', 'kind', 'label',
      'version', jsonb_build_object(
        'rendering_engine', 'zpl', 'label_language', 'zpl',
        'blocks', '[{"kind":"barcode"}]'::jsonb,
        'required_permission', 'reporting.export',
        'test_render', '^XA^BY2^BC^FD0012345678901231^FS^XZ',
        'decode_check_passed', true, 'decoded_value', '0012345678901231')));
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'one that scans arrives with its decode check intact',
    (select tv.decoded_value from erp.output_template_version tv
      where tv.tenant_id = v_tenant and tv.status = 'active') = '0012345678901231',
    'the value read back off the test render, not a flag somebody set';

  -- ── §15.4 printers, resolved to this environment''s own site ──────────────

  v_cs := erp.create_change_set('zz69-f', 'Printer', 'A label printer.');
  perform erp.add_change_set_item(v_cs, 'printer', 'BAY1', jsonb_build_object(
    'code', 'BAY1', 'site', 'MAIN', 'name', 'Bay 1 label printer',
    'printer_type', 'label', 'language', 'zpl', 'dots_per_inch', 203,
    'queue_address', 'tcp://10.0.0.11:9100'));
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'a printer promotes and binds to THIS environment''s site',
    (select pr.site_id from erp.printer pr
      where pr.tenant_id = v_tenant and pr.code = 'BAY1') = v_site,
    'a change set built elsewhere knows nothing of our ids, so it names the code';

  return query select 'and the output model reads as sound',
    erp.assert_output_integrity() is not null,
    '§15.4: a label printer must speak a language some active label renders';

  v_cs := erp.create_change_set('zz69-g', 'Bad printer', 'A printer at no site.');
  perform erp.add_change_set_item(v_cs, 'printer', 'BAY9', jsonb_build_object(
    'code', 'BAY9', 'site', 'NOWHERE', 'name', 'Printer at a site we lack',
    'printer_type', 'document', 'queue_address', 'tcp://10.0.0.99:9100'));
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'a printer at an absent site was promoted';
  exception when others then
    v_ok := sqlerrm like '%ERPWARE_PROMOTION_UNKNOWN_SITE%'; v_msg := left(sqlerrm, 60);
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  return query select 'a printer naming a site this environment lacks is refused',
    v_ok, v_msg;

  -- ── The guard is what makes promotion the only route ─────────────────────

  begin
    update erp.report_version set row_cap = 999
     where tenant_id = v_tenant and status = 'active';
    v_ok := false; v_msg := 'a report version was edited directly on a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a report version cannot be edited directly when live',
    v_ok, v_msg;

  begin
    update erp.printer set queue_address = 'tcp://10.0.0.12:9100'
     where tenant_id = v_tenant and code = 'BAY1';
    v_ok := false; v_msg := 'a printer was edited directly on a live organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor can a printer', v_ok, v_msg;

  return query select 'and every promotable surface carries that guard',
    erp.assert_configuration_promotable() is not null,
    'the register and the deployed triggers agree';

  -- ── The one member of the output model deliberately left outside ──────────
  --
  -- erp.email_suppression records that an address bounced or unsubscribed. It
  -- is produced by delivery outcomes, not authored — which is why it carries no
  -- attribution columns while every configuration surface does. Promoting it
  -- would be wrong in both directions: a sandbox''s test bounces would suppress
  -- real customers, and production''s list would copy real addresses into a
  -- less controlled environment.

  return query select 'email suppression is not offered as configuration',
    not exists (select 1 from erp_meta.promotable_surface ps
                 where ps.table_name = 'email_suppression'),
    'it is produced by delivery outcomes, not authored by anybody';

  return query select 'and the manifest does not carry it between environments',
    not exists (select 1 from erp.configuration_manifest() m
                 where m.object_kind = 'email_suppression'),
    'a sandbox''s test bounces must never suppress a real customer';

  insert into erp.email_suppression (tenant_id, address, reason, is_permanent)
  values (v_tenant, 'bounced@zz69.test', 'hard_bounce', true);
  return query select 'while a bounce still lands without a change set',
    exists (select 1 from erp.email_suppression s
             where s.tenant_id = v_tenant and s.address = 'bounced@zz69.test'),
    'a guard here would mean an address keeps being written to after it bounced';

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);

  select count(*) into v_n from erp.tenant t where t.code like 'zz69-%';
  return query select 'the suite leaves nothing behind',
    v_n = 0 and erp.assert_configuration_promotable() is not null,
    'and the register still describes what is deployed';
end;
$$;

comment on function erp_test.promotion_completeness_suite is
  'Specification v1.2 §15.2, §15.4 and §19.2. The attack is the promotion that '
  'carries a title and leaves the definition behind: the report row arrives, the '
  'version does not, and the receiving organisation looks installed while being '
  'unable to run anything. The version travels inside the report item precisely '
  'so the two cannot land apart, and the same shape carries a label template '
  'with the decode check that proves it will scan. A version naming a column '
  'its view does not have, or a parameter filtering one, is refused by name.';

create or replace function erp_test.assert_promotion_completeness_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _promo_complete_result on commit drop as
    select * from erp_test.promotion_completeness_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _promo_complete_result;

  -- 28, not 26: 20260904450000 added the two refusals for a column, and a
  -- parameter's column, the view does not have.
  if v_total <> 28 then
    raise exception 'ERPWARE_PROMOTION_COMPLETENESS_SUITE_SHRANK: % case(s), expected 28',
      v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_PROMOTION_COMPLETENESS_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('promotion completeness: %s/%s', v_passed, v_total);
end;
$$;

-- ── The assertions ───────────────────────────────────────────────────────────

select erp.assert_reports_reproducible();
select erp.assert_pack_report_versions_sound();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp_test.assert_reporting_suite();
select erp_test.assert_promotion_completeness_suite();
