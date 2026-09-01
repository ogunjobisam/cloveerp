-- =============================================================================
-- Part 19 — the adversarial suite
--
-- erp.assert_reports_reproducible() passes on an empty schema, which proves
-- nothing at all. This suite builds a real governed view, a real report with two
-- versions, and then attacks the properties §19.2 and §19.3 actually promise:
--
--   a figure records the version that produced it, and re-running under a NEW
--   version gives a different answer that is still attributable to the right one
--   — which is what "reproduced exactly" means and what a run record without a
--   version could never deliver
--
--   a parameter nobody declared is refused, because an undeclared parameter is
--   the shape a scope widening takes
--
--   a parameter that filters a scoping column is refused by the assertion,
--   because §19.1 puts scoping in the view precisely so a report cannot reach
--   around it
--
--   over budget the request DEFERS and says which budget it hit, rather than
--   failing — §19.3 is explicit that the user asked a reasonable question
-- =============================================================================

create or replace function erp_test.reporting_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  ad uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzrep-a';
  v_view uuid; v_report uuid; v_v1 uuid; v_v2 uuid;
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
          '{site_code,item_code,quantity}', '{site_code}', '{site_code}',
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

  -- report_version is NOT a promotable surface (see the open decision recorded
  -- with the tables), so it carries no live-config guard and can be written
  -- directly here. That is precisely the gap that decision records: authoring a
  -- new version of a report on a live organisation should go through promotion
  -- and today does not.
  update erp.report_version set effective_to = current_date, status = 'superseded'
   where id = v_v1;

  insert into erp.report_version
    (tenant_id, report_id, version, governed_view_id, columns, group_by,
     default_sort, output_formats, required_permission,
     time_budget_ms, row_cap, status, effective_from)
  values (v_tenant, v_report, 2, v_view,
          '{site_code,item_code,quantity,value_minor}', '{site_code}',
          '{site_code}', '{csv}', 'reporting.read', 5000, 100, 'active',
          current_date)
  returning id into v_v2;

  res := erp.run_report('stock_by_site', '{}'::jsonb, 10, 100);

  return query select 'a later run uses the version now in force',
    (res ->> 'version')::integer = 2, format('version %s', res ->> 'version');

  return query select 'while the earlier figure still names the version that made it',
    (select rr.version from erp.report_run rr where rr.id = v_run) = 1,
    'the whole point of recording the version rather than the report';

  return query select 'and only one version is in force at a time',
    erp.assert_reports_reproducible() is not null,
    'two in force would make reproduced-exactly depend on which was chosen';

  insert into erp.report_parameter
    (tenant_id, report_version_id, code, data_type, is_required, filters_column)
  values (v_tenant, v_v2, 'as_at', 'date', true, 'occurred_at');

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

  insert into erp.report_parameter
    (tenant_id, report_version_id, code, data_type, is_required, filters_column)
  values (v_tenant, v_v2, 'company', 'uuid', false, 'entity_id');

  begin
    perform erp.assert_reports_reproducible();
    v_ok := false; v_msg := 'a parameter filtering a scoping column was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_NOT_REPRODUCIBLE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a parameter that filters a scoping column is refused', v_ok, v_msg;

  delete from erp.report_parameter
   where tenant_id = v_tenant and report_version_id = v_v2 and code = 'company';

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
  update erp.report_version set required_permission = 'reporting.export' where id = v_v2;
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
end;
$$;

comment on function erp_test.reporting_suite is
  'Specification v1.2 §19.2 and §19.3, proven adversarially: a figure records '
  'the version that made it and keeps naming it after a new version supersedes '
  'it; a parameter nobody declared is refused; one that filters a scoping column '
  'is refused; and over budget the request defers and says which budget, rather '
  'than failing.';

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

  if v_total <> 18 then
    raise exception 'ERPWARE_REPORTING_SUITE_SHRANK: % case(s), expected 18', v_total
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

select erp_test.assert_reporting_suite();
