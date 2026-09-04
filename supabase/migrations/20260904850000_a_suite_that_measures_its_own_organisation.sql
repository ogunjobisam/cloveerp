-- ─────────────────────────────────────────────────────────────────────────────
-- An acceptance suite that measured the whole database.
--
-- Found in Phase 2 of the production-readiness pass, and it is the reason the
-- suite has always been green: it is only correct when nothing else exists.
--
-- erp_test.starter_pack_acceptance_suite() builds an organisation, applies the
-- base pack to it, and finishes by calling erp.assert_reports_reproducible().
-- That assertion reads erp.report_reproducibility_report(), which has no tenant
-- filter at all — it is a platform-wide check, and reading it from inside a
-- per-organisation suite makes the suite's verdict depend on every other
-- organisation in the database.
--
-- In CI the database holds nothing else, so it passes. Measured here: with a
-- second organisation present the same suite reports 26/27 with eight findings
-- that belong to the other organisation entirely; purge that organisation and
-- the identical code returns 27/27. The suite was never testing what its name
-- says.
--
-- This is the same shape the reconciliation notes recorded against
-- assert_determination_coverage_suite — a case that is vacuous on an empty
-- build and wrong on a real one.
--
-- So the report gains an optional organisation. Null keeps the platform-wide
-- behaviour every existing caller depends on; the suite passes its own tenant
-- and now measures the organisation it actually built.
-- ─────────────────────────────────────────────────────────────────────────────

-- The zero-argument form must go first: adding a defaulted parameter beside it
-- creates two candidates for a bare call, and Postgres refuses to choose.
drop function if exists erp.report_reproducibility_report();

CREATE OR REPLACE FUNCTION erp.report_reproducibility_report(p_tenant_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with version_source as (
    select rv.id, rv.tenant_id, rv.version, rv.columns, rv.group_by, rv.default_sort,
           r.code as report_code,
           gv.source_schema, gv.source_name,
           pg_catalog.to_regclass(format('%I.%I', gv.source_schema, gv.source_name)) as rel
      from (select * from erp.report_version where p_tenant_id is null or tenant_id = p_tenant_id) rv
      join (select * from erp.report where p_tenant_id is null or tenant_id = p_tenant_id) r on r.tenant_id = rv.tenant_id and r.id = rv.report_id
      join erp.governed_view gv
        on gv.tenant_id = rv.tenant_id and gv.id = rv.governed_view_id
  )
  -- 1. A report with no version at all cannot be run, and cannot say which
  --    definition produced a figure.
  select 'a report has no version', r.code,
         'a report with no version is a name without a definition'
    from (select * from erp.report where p_tenant_id is null or tenant_id = p_tenant_id) r
   where not exists (select 1 from (select * from erp.report_version where p_tenant_id is null or tenant_id = p_tenant_id) rv
                      where rv.tenant_id = r.tenant_id and rv.report_id = r.id)

  union all

  -- 2. Two versions in force on the same day. The run record would name one of
  --    them and "reproduced exactly" would depend on which the planner chose.
  select 'a report has more than one version in force', r.code,
         format('%s versions effective today', count(*)::text)
    from (select * from erp.report where p_tenant_id is null or tenant_id = p_tenant_id) r
    join (select * from erp.report_version where p_tenant_id is null or tenant_id = p_tenant_id) rv
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
    from (select * from erp.report_run where p_tenant_id is null or tenant_id = p_tenant_id) rr
   where not exists (select 1 from (select * from erp.report_version where p_tenant_id is null or tenant_id = p_tenant_id) rv
                      where rv.tenant_id = rr.tenant_id and rv.id = rr.report_version_id)

  union all

  -- 5. A deferral that does not say which budget it hit. §19.3 distinguishes
  --    deferral from failure, and a deferral nobody can explain reads as one.
  select 'a deferred run does not say why', rr.id::text,
         'deferral without a reason is indistinguishable from a failure'
    from (select * from erp.report_run where p_tenant_id is null or tenant_id = p_tenant_id) rr
   where rr.outcome = 'deferred_to_extract'
     and coalesce(btrim(rr.extract_reason), '') = ''

  union all

  -- 6. A version whose required permission is not a permission. It would
  --    authorise against nothing, and erp.authorise() refuses an unknown code —
  --    so this is a report that cannot be run, found before somebody runs it.
  select 'a version requires a permission that does not exist', rv.id::text,
         rv.required_permission
    from (select * from erp.report_version where p_tenant_id is null or tenant_id = p_tenant_id) rv
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
$function$

;

-- ── And the suite asks the question about its own organisation ───────────────
CREATE OR REPLACE FUNCTION erp_test.starter_pack_acceptance_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  a1 uuid := gen_random_uuid();   -- the author
  a2 uuid := gen_random_uuid();   -- the approver, because B6 refuses self-approval
  r         record;
  c         record;
  res       jsonb;
  v_cs      uuid;
  v_tok     text;
  v_second  uuid;
  d         record;
  i         integer := 0;
  n         integer;
  n2        integer;
  v_ok      boolean; v_msg text;
  v_ready   integer;
begin
  select * into r from erp.provision_tenant(
    'zz13', 'Acceptance', 'admin@zz13.test', 'Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zz13.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- The modules. Installing one is not "further configuration" in §13's sense
  -- — it is what gives the product a procurement flow to configure at all —
  -- and the pack presupposes them: a requisition lifecycle comes from
  -- erp.configure_procurement(), not from erp_ref.pack_item.
  perform erp.configure_finance();
  perform erp.configure_procurement(1000000);
  perform erp.configure_sales();
  perform erp.configure_inventory();
  perform erp.configure_quality();
  perform erp.configure_logistics();
  perform erp.configure_period_close();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
    perform erp.approve_change_set(c.id);
    perform erp.promote_change_set(c.id);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- Installing a module registers the reporting views it brings, whether or
  -- not its change set is promoted — a view is the product's boundary, not the
  -- organisation's behaviour. Seven modules, fourteen views.
  select count(*) into n from erp.governed_view gv where gv.tenant_id = r.tenant_id;
  return query select 'installing a module registers the reporting views it brings',
    n = (select count(*) from erp_ref.module_governed_view m
          where m.install_code in ('finance-posting', 'procurement-lifecycle',
                                   'sales-lifecycle', 'inventory-operations',
                                   'quality', 'logistics', 'period-close')),
    format('%s views registered by seven installers', n);

  -- ── §2.1's route ────────────────────────────────────────────────────────

  res := erp.apply_preset('standard');
  return query select 'a live organisation switches capabilities through a change set',
    (res ->> 'route') = 'change_set' and (res ->> 'change_set_id') is not null,
    'erp.provision_tenant() marks the self environment live immediately, so '
    'the promotable-surface guard bites from the first day — and before this '
    'there was no promotion route to take instead, which left every '
    'organisation able to read the capability catalogue and none able to '
    'change it';

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) into n from erp.tenant_capability tc
   where tc.tenant_id = r.tenant_id and tc.is_enabled and tc.valid_to is null;
  return query select 'and promoting it switches on what the preset selects',
    n = 9, format('%s capabilities on after the Standard preset', n);

  -- ── §11, applied ────────────────────────────────────────────────────────

  res := erp.apply_content_pack('base');
  v_cs := (res ->> 'change_set_id')::uuid;
  return query select 'the base pack plans only what the capabilities allow',
    -- 340. It was 322 when §13's clause 5 was written, 326 after
    -- 20260904100000 added §9.1's four remaining scheduled jobs, 342 after
    -- 20260904170000 added §9.3's sixteen output templates, and 340 now that
    -- 20260904430000 holds back the two reports — match exceptions and
    -- ageing — whose views come with modules this organisation has not yet
    -- installed. The number is hardcoded on purpose — it is what makes a pack
    -- that grows by accident fail the build — so each deliberate growth
    -- updates it and says what moved it.
    (res ->> 'items')::integer = 340
      and jsonb_array_length(res -> 'advisories') = 8,
    format('%s of %s items, %s advisories naming the capabilities and modules that held the rest back',
           res ->> 'items',
           (select count(*) from erp_ref.pack_item where pack_code = 'base'),
           jsonb_array_length(res -> 'advisories'));

  -- The two advisories that are new: each names the report, the view and the
  -- module that brings it, so the reader knows what to install.
  return query select 'a report whose view is not installed is held back and named',
    -- The advisories are the conflict strings themselves, not objects.
    exists (select 1 from jsonb_array_elements_text(res -> 'advisories') a
             where a like 'report(s) match_exceptions are held back%'
               and a like '%procurement-controls module%')
    and exists (select 1 from jsonb_array_elements_text(res -> 'advisories') a
             where a like 'report(s) ageing are held back%'
               and a like '%receivables module%'),
    '§11.7: not missing, early — the same additive rule as a capability off';

  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'a pack promoted with twelve decisions unanswered';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_DECISIONS_OUTSTANDING%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'promotion refuses while a required decision remains', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  for d in select * from erp.pack_decisions('base') where not answered loop
    i := i + 1;
    perform erp.answer_pack_decision('base', d.object_kind, d.object_key,
      jsonb_build_object('upper_bound_minor', i * 500000));
  end loop;
  return query select 'and §3.4''s twelve approval bands are all of them',
    i = 12, format('%s decisions, every one an approval threshold', i);

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'the answer lands, not the pack''s placeholder',
    (select ab.upper_bound_minor from erp.approval_band ab
      join erp.department dp on dp.id = ab.department_id
     where ab.tenant_id = r.tenant_id and dp.code = 'PROC'
       and ab.object_type = 'requisition' and ab.seq = 1) is not null,
    'a band whose threshold is still null is a chain that approves everything';

  -- The gap this migration closes: every report the pack landed carries a
  -- version in force, reading a view the organisation holds.
  select count(*), count(*) filter (where exists (
           select 1 from erp.report_version rv
            where rv.tenant_id = rp.tenant_id and rv.report_id = rp.id
              and rv.status = 'active' and rv.effective_from <= current_date
              and (rv.effective_to is null or rv.effective_to > current_date)))
    into n, n2
    from erp.report rp where rp.tenant_id = r.tenant_id;
  return query select 'every report the pack landed has a version in force',
    -- 13: eighteen, less the three whose capability the Standard preset leaves
    -- off (planning exceptions, production variance, recall despatch list)
    -- and the two whose view waits for a module (match exceptions, ageing).
    n = 13 and n2 = n,
    format('%s reports, %s with a version — the thirteen the Standard preset '
           'and seven modules allow', n, n2);

  -- ── §13's seven clauses ─────────────────────────────────────────────────

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'four of §13''s seven clauses hold after Standard and the base pack',
    v_ready = 4,
    format('%s of 7 ready with nothing configured by hand', v_ready);

  return query select 'clauses 1, 2, 4 and 7 are the four',
    (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
      where clause in (1, 2, 4, 7)),
    'requisition to invoice; determination with no suspense fallback; count '
    'and variance; period close';

  -- The two clauses §13 describes after "having chosen the Standard preset"
  -- and §2.3 puts in Full. Settled as: §13 means Full. The report says which
  -- preset each clause needs, derived from erp_ref.preset_capability, so
  -- neither document had to be rewritten and neither is quoted at the reader.
  return query select 'clause 3 needs Full, and says so rather than reading as a fault',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 3) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 3)
      = 'Container identity is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 3), 'nothing missing');

  return query select 'clause 6 needs Full for the same reason, and nothing else',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 6) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 6)
      = 'Recall management is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 6), 'nothing missing');

  -- The invariant the whole change is for: nothing a preset can switch on is
  -- ever reported as something the pack failed to provide. §13's last sentence
  -- logs a pack gap against the product, and a preset nobody chose is not one.
  return query select 'no clause blames the pack for a capability a preset carries',
    not exists (
      select 1 from erp.pack_acceptance_report(r.tenant_id) ar
       where ar.missing is not null
         and ar.missing like '%is off%'
         and ar.missing not like '%preset)%'),
    'before this, two clauses answered a reader with a paragraph about §2.3 '
    'disagreeing with §13';

  return query select 'clause 5''s gap is a site''s, not the pack''s',
    (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 5)
      = 'no marshalling area configured for any site; ',
    'a marshalling area belongs to a site, and a site is an organisation''s own '
    '— §11 lists none in a pack for the same reason';

  -- ── The Full preset closes both, which is what names the cause ──────────

  res := erp.apply_preset('full');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.apply_content_pack('base');
  return query select 're-applying the base pack plans exactly what was held back',
    -- 11, not 13: planning exceptions and production variance now wait for
    -- the planning and production modules, whose views they read.
    (res ->> 'items')::integer = 11,
    format('%s items — §11.7''s "a tenant that skipped manufacturing at '
           'onboarding can add it later, and the change set contains only what '
           'is missing"', res ->> 'items');

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'the Full preset closes clauses 3 and 6 and nothing else changes',
    v_ready = 6
      and (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
            where clause in (3, 6)),
    format('%s of 7 ready; only clause 5 remains, and it wants a site', v_ready);

  return query select 'and a third application plans nothing at all',
    (select count(*) from erp.plan_content_pack('base')) = 0,
    'additive, per §11.7';

  -- ── The last four reports arrive with the modules that bring their views ─

  perform erp.configure_receivables();
  perform erp.configure_procurement_controls();
  perform erp.configure_planning();
  perform erp.configure_production();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
    perform erp.approve_change_set(c.id);
    perform erp.promote_change_set(c.id);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.apply_content_pack('base');
  return query select 'installing the modules that bring the views plans exactly the reports held back',
    (res ->> 'items')::integer = 4
      and (select string_agg(csi.object_key, ',' order by csi.object_key)
             from erp.change_set_item csi
            where csi.change_set_id = (res ->> 'change_set_id')::uuid)
          = 'ageing,match_exceptions,planning_exceptions,production_variance',
    format('%s items: %s', res ->> 'items',
           (select string_agg(csi.object_key, ', ' order by csi.object_key)
              from erp.change_set_item csi
             where csi.change_set_id = (res ->> 'change_set_id')::uuid));

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*), count(*) filter (where (
           select count(*) from erp.report_version rv
            where rv.tenant_id = rp.tenant_id and rv.report_id = rp.id
              and rv.status = 'active' and rv.effective_from <= current_date
              and (rv.effective_to is null or rv.effective_to > current_date)) = 1)
    into n, n2
    from erp.report rp where rp.tenant_id = r.tenant_id;
  return query select 'all eighteen base reports now hold exactly one version in force',
    n = 18 and n2 = 18,
    format('%s reports, %s with exactly one version in force', n, n2);

  -- The assertion this whole change is for, asked of the organisation the
  -- suite built. Before 20260904430000 it failed here with eighteen findings.
  begin
    -- Over the organisation this suite built, not over the database. The
    -- assertion is platform-wide by design, and reading it from inside a
    -- per-organisation suite made this case pass only while nothing else
    -- existed: with a second organisation present it reported eight findings
    -- belonging entirely to that other organisation.
    if exists (select 1 from erp.report_reproducibility_report(r.tenant_id)) then
      raise exception 'ERPWARE_REPORT_NOT_REPRODUCIBLE: % finding(s)',
        (select count(*) from erp.report_reproducibility_report(r.tenant_id));
    end if;
    v_ok := true; v_msg := 'erp.report_reproducibility_report() is clean over the pack-installed reports';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  return query select 'and the organisation''s reports are reproducible', v_ok, v_msg;

  -- ── §10, over the base ──────────────────────────────────────────────────

  begin
    perform erp.apply_content_pack('outsourced_logistics');
    v_ok := false; v_msg := 'a profile pack applied with its capability off';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_CONFLICT%'
        and sqlerrm like '%third_party_custody%';
    v_msg := left(sqlerrm, 58);
  end;
  return query select 'a profile pack whose capability is off is refused by name',
    v_ok, v_msg;

  res := erp.apply_content_pack('manufacturing');
  return query select 'and one whose capability is on applies over the base',
    -- 12, not 13: erp.configure_production() above already set
    -- production.issue_method to the value the pack carries, and §11.7 plans
    -- only what is missing.
    (res ->> 'items')::integer = 12, format('%s items', res ->> 'items');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select '§10''s five works order types all land',
    (select count(*) from erp.classification_value cv
       join erp.classification_axis ca on ca.id = cv.axis_id
      where cv.tenant_id = r.tenant_id and ca.code = 'WORKS_ORDER_TYPE'
        and cv.status = 'active') = 5,
    'production, assembly, kitting, rework, repack';

  return query select '§11.6: the organisation records which packs it holds, and at which version',
    (select count(*) from erp.tenant_pack tp
      where tp.tenant_id = r.tenant_id and tp.status = 'applied') = 4
    and (select bool_and(tp.version = '1.0.0') from erp.tenant_pack tp
          where tp.tenant_id = r.tenant_id and tp.status = 'applied'),
    'base three times and manufacturing once, each with its version';

  -- ── §12, checkable rather than trusted ──────────────────────────────────

  return query select 'every pack value states where it came from',
    not exists (select 1 from erp_ref.pack_item where length(provenance) <= 20)
    and not exists (select 1 from erp_ref.content_pack where length(provenance) <= 30),
    '§12: "every value carries a provenance note naming the standard or '
    'practice it derives from, so the review is checkable rather than trusted"';

  -- Cleanup, so the next suite starts from the schema rather than from this.
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'a suite that leaves an organisation makes the next one measure this one';
end;
$function$

;
