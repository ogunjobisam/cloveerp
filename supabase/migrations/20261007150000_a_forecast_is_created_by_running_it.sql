set lock_timeout = '30s';

-- =============================================================================
-- 20261007150000  A forecast is created by running it
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-22). "Run a forecast"
-- asks for a forecast code and says "A short code of your own choosing", but
-- erp.run_forecast refused any code no forecast already had
-- (CLOVEERP_UNKNOWN_FORECAST), and nothing outside the suites ever wrote an
-- erp.forecast row. So no organisation, even one that has installed Planning,
-- could ever make a forecast: on live none ever has. The form's two numbers,
-- the periods ahead and the history used, also said nothing of the 6 and 24
-- the door takes when they are left empty.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.run_forecast: a code no forecast has yet is a new forecast. The
--      run authorises planning.forecast first, then writes the forecast under
--      that code (named by it, weekly, for every site), then runs it as
--      before. A forecast that is in use is run as before. A code a withdrawn
--      forecast holds, or no code at all, is still refused.
--   B. The door's write allowance says it creates the forecast.
--   C. The words for the two numbers: "Default 6." and "Default 24.".
--   D. erp_test.forecast_created_by_running_suite.
--
-- The screen's half is in src/lib/modules.tsx ("Run a forecast").
--
-- On production: one routine is restated and words are added. No table is
-- altered and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The run creates the forecast it names
-- ─────────────────────────────────────────────────────────────────────────────

do $forecast$
declare
  v_sig  constant text := 'erp.run_forecast(text,integer,integer)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select * into f from erp.forecast
   where tenant_id = v_tenant and code = p_forecast_code and status = 'active';
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_FORECAST: %', p_forecast_code using errcode = '23503';
  end if;
$o$;
  v_new  constant text := $n$  select * into f from erp.forecast
   where tenant_id = v_tenant and code = p_forecast_code and status = 'active';
  if not found then
    -- A code no forecast has yet is a new forecast (20261007150000): the form
    -- asks for "a short code of your own choosing", and nothing else writes
    -- one. A code a withdrawn forecast holds is not taken over, and no code
    -- is no forecast.
    if nullif(btrim(coalesce(p_forecast_code, '')), '') is null
       or exists (select 1 from erp.forecast x
                   where x.tenant_id = v_tenant and x.code = p_forecast_code) then
      raise exception 'CLOVEERP_UNKNOWN_FORECAST: %', p_forecast_code using errcode = '23503';
    end if;

    perform erp.authorise('planning.forecast', null, null, null, 'forecast', null);

    insert into erp.forecast (tenant_id, code, name)
    values (v_tenant, p_forecast_code, p_forecast_code)
    returning * into f;
  end if;
$n$;
begin
  if strpos(v_src, '20261007150000') > 0 then
    raise notice '% already creates the forecast it names; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '49b050e041729119df6e4d68dbd560aa' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007150000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$forecast$;

comment on function erp.run_forecast(text, integer, integer) is
  'Runs a forecast under planning.forecast and writes a draft version nobody has signed off yet. A code no forecast '
  'has yet is a new forecast, weekly and for every site, written before it is run (20261007150000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Its write allowance
-- ─────────────────────────────────────────────────────────────────────────────

update erp_meta.public_write_allowance
   set rationale = 'Runs a forecast under planning.forecast, producing a version nobody has signed off yet; a code no '
                   'forecast has yet creates that forecast first (20261007150000).'
 where function_name = 'erp_run_forecast' and gate = 'erp.run_forecast';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). What Run a forecast takes when a number is left empty (20261007150000).'
  from (values
    ('Default 6.'),
    ('Default 24.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.forecast_created_by_running_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_recv uuid; v_item uuid;
  v_ver1 uuid; v_ver2 uuid; v_fc uuid;
  v_err  text; v_err2 text; v_err3 text;
  i      integer;
begin
  begin
    -- ── The fixture: an organisation with a year of demand for one product ──
    v_step := 'an organisation, an administrator, a buyer and a year of demand';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzfcr-' || v_tag, 'Forecast Created Suite',
      'admin@zzfcr-' || v_tag || '.test', 'Forecast Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzfcr-' || v_tag || '.test'),
           (s_buy, 'buyer@zzfcr-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    res := public.erp_invite_principal('buyer@zzfcr-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (rb.tenant_id, 'ZFCREA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZFCRMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (rb.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZFCRWID', 'Forecast Widget', v_uom, 'active') returning id into v_item;
    insert into erp.item_site (tenant_id, item_id, site_id, is_stocked, lead_time_days, status)
    values (rb.tenant_id, v_item, v_site, true, 7, 'active');
    insert into erp.stock_movement (
      tenant_id, entity_id, site_id, movement_type, item_id,
      to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency)
    values (rb.tenant_id, rb.entity_id, v_site, 'goods_receipt', v_item,
            v_recv, 'available', 5000, v_uom, 1000, 'GBP');
    for i in 1 .. 24 loop
      insert into erp.stock_movement (
        tenant_id, entity_id, site_id, movement_type, item_id,
        from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency, occurred_at)
      values (rb.tenant_id, rb.entity_id, v_site, 'despatch', v_item,
              v_recv, 'available', 20 + i, v_uom, 1000, 'GBP',
              date_trunc('week', current_date) - ((25 - i) || ' weeks')::interval + interval '1 day');
    end loop;

    -- ── 1. The words and the allowance ──────────────────────────────────────
    v_step := 'reading the registers';
    v_cases := v_cases + 1;
    case_name := 'the two numbers say what they default to, and the door''s allowance says it creates the forecast';
    passed := v_state is null
          and (select count(*) from erp_ref.resource x
                where x.locale = 'en' and x.key in (erp_ref.ui_key('Default 6.'), erp_ref.ui_key('Default 24.'))) = 2
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_run_forecast' and a.gate = 'erp.run_forecast'
                         and a.rationale like '%creates that forecast first%');
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. A new code is a new forecast ─────────────────────────────────────
    v_step := 'running a forecast under a code nobody has used';
    v_ver1 := public.erp_run_forecast('ZFCR-2026H1');
    select f.id into v_fc from erp.forecast f where f.tenant_id = rb.tenant_id and f.code = 'ZFCR-2026H1';
    v_cases := v_cases + 1;
    case_name := 'a forecast run under a code nobody has used creates that forecast, weekly and for every site, with a draft version and its lines';
    passed := v_state is null and v_fc is not null
          and exists (select 1 from erp.forecast f
                       where f.id = v_fc and f.name = 'ZFCR-2026H1' and f.bucket = 'week'
                         and f.site_id is null and f.entity_id is null and f.status = 'active')
          and exists (select 1 from erp.forecast_version fv
                       where fv.id = v_ver1 and fv.forecast_id = v_fc and fv.version = 1
                         and fv.status = 'draft' and (fv.parameters ->> 'periods')::integer = 6
                         and (fv.parameters ->> 'buckets_of_history')::integer = 24)
          and (select count(*) from erp.forecast_line fl
                where fl.forecast_version_id = v_ver1 and fl.item_id = v_item and fl.site_id = v_site) = 6;
    detail := coalesce(v_state, format('forecast %s, version %s', v_fc, v_ver1));
    return next;

    -- ── 3. Run again, it is the same forecast ───────────────────────────────
    v_step := 'running the same code again';
    v_ver2 := public.erp_run_forecast('ZFCR-2026H1', 4, 12);
    v_cases := v_cases + 1;
    case_name := 'run again under the same code, the forecast gains a second version and no second forecast';
    passed := v_state is null
          and (select count(*) from erp.forecast f where f.tenant_id = rb.tenant_id and f.code = 'ZFCR-2026H1') = 1
          and exists (select 1 from erp.forecast_version fv
                       where fv.id = v_ver2 and fv.forecast_id = v_fc and fv.version = 2)
          and (select count(*) from erp.forecast_line fl where fl.forecast_version_id = v_ver2) = 4;
    detail := coalesce(v_state, format('version %s', v_ver2));
    return next;

    -- ── 4. Not by somebody who may not forecast ─────────────────────────────
    v_step := 'a buyer running a forecast under a new code';
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin perform public.erp_run_forecast('ZFCR-BUYER'); v_err := 'run';
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody who may not forecast is refused, and no forecast is left behind';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERMISSION_DENIED%'
          and not exists (select 1 from erp.forecast f where f.tenant_id = rb.tenant_id and f.code = 'ZFCR-BUYER');
    detail := coalesce(v_state, v_err);
    return next;

    -- ── 5. No code, or a withdrawn forecast's code, is still refused ────────
    v_step := 'running with no code, and under a withdrawn forecast''s code';
    begin perform public.erp_run_forecast('  '); v_err2 := 'run';
    exception when others then v_err2 := sqlerrm; end;
    update erp.forecast set status = 'inactive' where id = v_fc;
    begin perform public.erp_run_forecast('ZFCR-2026H1'); v_err3 := 'run';
    exception when others then v_err3 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'no code, and the code of a forecast no longer in use, are refused rather than made into a forecast';
    passed := v_state is null
          and v_err2 like 'CLOVEERP_UNKNOWN_FORECAST%'
          and v_err3 like 'CLOVEERP_UNKNOWN_FORECAST%'
          and (select count(*) from erp.forecast f where f.tenant_id = rb.tenant_id) = 1
          and (select count(*) from erp.forecast_version fv where fv.forecast_id = v_fc) = 2;
    detail := coalesce(v_state, concat_ws(' / ', v_err2, v_err3));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_FORECAST_CREATED_BY_RUNNING_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.forecast_created_by_running_suite() from public, anon;

comment on function erp_test.forecast_created_by_running_suite() is
  'A forecast is created by running it (20261007150000): a new code is a new forecast with a draft version, the same '
  'code again a second version; a buyer, no code and a withdrawn forecast''s code are refused.';

create or replace function erp_test.assert_forecast_created_by_running_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.forecast_created_by_running_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_FORECAST_CREATED_BY_RUNNING_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A forecast could not be made by running it, or was made when it should not be. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_FORECAST_CREATED_BY_RUNNING_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('forecast created by running: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_forecast_created_by_running_suite() from public, anon;

comment on function erp_test.assert_forecast_created_by_running_suite() is
  'Running a forecast under a code nobody has used creates that forecast; only somebody who may forecast can (20261007150000).';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
