-- =============================================================================
-- The suite for a promotion that must not arrive half-finished
--
-- erp.assert_configuration_promotable() proves four structural things about
-- every registered surface, but it cannot prove the one that matters here.
-- report_version is registered under the EXISTING report kind, so the branch it
-- looks for and the manifest emission it looks for were both already there —
-- for the report ROW. The assertion is satisfied whether or not the payload
-- carries the version.
--
-- So this suite does the only thing that settles it: it promotes, then reads
-- the manifest back out, and fails if the definition did not make the trip.
--
-- The attack is the promotion that succeeds and leaves the receiving
-- organisation broken in a way that looks installed. The first two cases build
-- exactly that state — a report promoted with no version — and show
-- erp.assert_reports_reproducible() calling it what it is. Everything after
-- that is the fix, and the ways it can be got wrong: a version naming a view or
-- a permission this environment does not have, a version that selects nothing,
-- a parameter that filters a scoping column, a label whose decode check did not
-- pass, a printer at a site that does not exist here.
--
-- Two cases are about the table deliberately left out. erp.email_suppression
-- must be absent from the register AND from the manifest, and must still accept
-- a bounce on a live organisation with no change set — because a guard there
-- would mean an address kept being written to after it bounced.
-- =============================================================================

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
      '{site_code}', '{}', '{}', '{pdf}', 'reporting.read', 5000, 100,
      current_date, 'promoted', '[]'::jsonb);
    v_ok := false; v_msg := 'a version naming an absent view was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PROMOTION_UNKNOWN_VIEW%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a version naming a view this environment lacks is refused',
    v_ok, v_msg;

  begin
    perform erp.upsert_report_version('stock_by_site', 'stock_position',
      '{site_code}', '{}', '{}', '{pdf}', 'reporting.invented', 5000, 100,
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
      '{site_code}', '{}', '{}', '{pdf}', 'reporting.read', 5000, 100,
      current_date, 'promoted',
      '[{"code":"company","data_type":"uuid","filters_column":"entity_id"}]'::jsonb);
    v_ok := false; v_msg := 'a scope-widening parameter was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_PARAMETER_WIDENS_SCOPE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and a parameter that filters a scoping column',
    v_ok, v_msg;

  perform set_config('erp.promotion_id', '', true);

  -- ── The definition travels inside the same item ───────────────────────────

  v_cs := erp.create_change_set('zz69-b', 'Definition', 'The report and its version.');
  perform erp.add_change_set_item(v_cs, 'report', 'stock_by_site', jsonb_build_object(
    'code', 'stock_by_site', 'name', 'Stock by site',
    'description', 'What is on hand, by site.', 'module_code', 'inventory',
    'version', jsonb_build_object(
      'view', 'stock_position',
      'columns', '["site_code","item_code","quantity"]'::jsonb,
      'group_by', '["site_code"]'::jsonb,
      'default_sort', '["site_code"]'::jsonb,
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
      and (c_report -> 'version' -> 'columns') = '["site_code","item_code","quantity"]'::jsonb,
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
      'columns', '["site_code","item_code","quantity","value_minor"]'::jsonb,
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
  'with the decode check that proves it will scan.';

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

  if v_total <> 26 then
    raise exception 'ERPWARE_PROMOTION_COMPLETENESS_SUITE_SHRANK: % case(s), expected 26',
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

select erp_test.assert_promotion_completeness_suite();
