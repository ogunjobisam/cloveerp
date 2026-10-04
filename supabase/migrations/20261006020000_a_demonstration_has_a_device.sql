set lock_timeout = '30s';

-- =============================================================================
-- 20261006020000  A demonstration has a device
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-47). The Scanner
-- (/device) showed only "No active device is registered. Ask an
-- administrator to register one." The person reading it was the
-- administrator, and the demonstration had no device: no seeder ever
-- registered one (erp.seed_demo(), erp.seed_demo_master_data() and
-- erp.ensure_demo_configuration() never write erp.device), so every
-- demonstration opened the scanner on an empty list and could not show it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.seed_demo_devices(tenant): in a demonstration, each active site
--      that keeps stock (a warehouse or a distribution centre) and has no
--      device at all is given one active handheld, coded HH-<site>. A site
--      with a device of any status keeps what it has, and a code already
--      taken is left alone. Nothing in an organisation that is not a
--      demonstration.
--   B. erp.ensure_demo_configuration() calls it, so a new demonstration has
--      one and an existing one gains one as it next trades.
--   C. DEMONSTRATIONS ONLY (organisations whose code is like 'demo-%'; not
--      clove-foods, not clove-erp, nobody's own data): every demonstration
--      there is today gains its handhelds here.
--
-- The scanner's empty state also links an administrator to where a device
-- is registered (src/routes/device.tsx); that needs no words of its own.
--
-- On production: each demonstration gains one handheld per stock site that
-- has none (two in a demonstration as configured: HH-MAIN-WH, HH-NORTH-DC).
-- erp.device is a quiet table; nothing is altered. Every other
-- organisation's rows are untouched.
--
-- Proof: erp_test.demo_devices_suite.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A handheld at each stock site of a demonstration
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.seed_demo_devices(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer := 0;
begin
  -- A demonstration's scanners (20261006020000): one active handheld at each
  -- active site that keeps stock and has no device, so the Scanner can be
  -- shown. Only in a demonstration, and never over a device somebody
  -- registered or retired.
  if erp.current_tenant_id() is distinct from p_tenant_id then
    raise exception
      'CLOVEERP_DEMO_TENANT_MISMATCH: the session is in organisation % and this '
      'call names %', coalesce(erp.current_tenant_id()::text, 'nobody'), p_tenant_id
      using errcode = '42501',
      hint = 'Adopt the organisation first: erp.set_active_tenant() for a person, '
             'erp.set_job_tenant() for a worker.';
  end if;
  if not erp.tenant_is_demonstration(p_tenant_id) then
    return 0;
  end if;

  insert into erp.device (tenant_id, site_id, code, name, device_class, status)
  select p_tenant_id, s.id, 'HH-' || s.code, 'Handheld, ' || s.name, 'handheld', 'active'
    from erp.site s
   where s.tenant_id = p_tenant_id
     and s.status = 'active'::erp.record_status
     and s.site_type in ('warehouse'::erp.site_type, 'distribution'::erp.site_type)
     and not exists (select 1 from erp.device d
                      where d.tenant_id = p_tenant_id and d.site_id = s.id)
   order by s.code
  on conflict (tenant_id, code) do nothing;
  get diagnostics v_n = row_count;

  return v_n;
end;
$$;

revoke all on function erp.seed_demo_devices(uuid) from public, anon;

comment on function erp.seed_demo_devices(uuid) is
  'A demonstration''s handhelds: one active handheld at each active warehouse or distribution site that has no device, '
  'so the Scanner can be shown (20261006020000). Called by erp.ensure_demo_configuration().';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A demonstration is configured with them
-- ─────────────────────────────────────────────────────────────────────────────

do $configure$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if erp.seed_demo_legal_details(p_tenant_id) > 0 then
    v_did := v_did || '"company and customer details"'::jsonb;
  end if;
$o$;
  v_new  constant text := $n$  if erp.seed_demo_legal_details(p_tenant_id) > 0 then
    v_did := v_did || '"company and customer details"'::jsonb;
  end if;

  -- A handheld at each site that keeps stock, so the Scanner can be shown
  -- (20261006020000).
  if erp.seed_demo_devices(p_tenant_id) > 0 then
    v_did := v_did || '"devices"'::jsonb;
  end if;
$n$;
begin
  if strpos(v_src, '20261006020000') > 0 then
    raise notice '% already seeds the devices; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c85c9b261446bf99a8a7f94ad00bc6f2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006020000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demo_devices_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  rc       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_conf   jsonb;
  v_again  jsonb;
  v_open   jsonb;
  v_sites  integer; v_bad integer; v_devices integer; v_after integer;
  v_kept   text;
begin
  begin
    -- ── The fixture: a demonstration ────────────────────────────────────────
    v_step := 'a demonstration configured from nothing';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzdv' || v_tag, 'Demo Devices Suite',
      'admin@demo-zzdv' || v_tag || '.test', 'Devices Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzdv' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    v_conf := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select count(*) into v_sites
      from erp.site s
     where s.tenant_id = rb.tenant_id and s.status = 'active'
       and s.site_type in ('warehouse', 'distribution');

    -- ── 1. Every stock site has a handheld ──────────────────────────────────
    select count(*) into v_bad
      from erp.site s
     where s.tenant_id = rb.tenant_id and s.status = 'active'
       and s.site_type in ('warehouse', 'distribution')
       and not exists (select 1 from erp.device d
                        where d.tenant_id = s.tenant_id and d.site_id = s.id
                          and d.status = 'active' and d.device_class = 'handheld');
    v_cases := v_cases + 1;
    case_name := 'every stock site of a demonstration has an active handheld';
    passed := v_state is null and v_sites > 0 and v_bad = 0
          and (v_conf -> 'installed') ? 'devices';
    detail := coalesce(v_state, format('%s stock site(s), %s without', v_sites, v_bad));
    return next;

    -- ── 2. The Scanner can be shown: its administrator opens a session ──────
    v_step := 'the administrator opens a session on the demonstration''s handheld';
    v_open := erp.open_device_session('HH-MAIN-WH');
    v_cases := v_cases + 1;
    case_name := 'the demonstration''s administrator can open a session on its handheld';
    passed := v_state is null and v_open ->> 'device' = 'HH-MAIN-WH' and v_open ->> 'session_id' is not null;
    detail := coalesce(v_state, v_open::text);
    return next;

    -- ── 3. Asked again, nothing more, and a device somebody retired stays ───
    v_step := 'a handheld somebody retired, configured again';
    select count(*) into v_devices from erp.device d where d.tenant_id = rb.tenant_id;
    update erp.device set status = 'retired'
     where tenant_id = rb.tenant_id and code = 'HH-NORTH-DC';
    v_again := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select count(*) into v_after from erp.device d where d.tenant_id = rb.tenant_id;
    select d.status into v_kept from erp.device d where d.tenant_id = rb.tenant_id and d.code = 'HH-NORTH-DC';
    v_cases := v_cases + 1;
    case_name := 'configured again nothing is added, and a device somebody retired stays retired';
    passed := v_state is null and not ((v_again -> 'installed') ? 'devices')
          and erp.seed_demo_devices(rb.tenant_id) = 0
          and v_after = v_devices and v_kept = 'retired';
    detail := coalesce(v_state, format('%s | %s device(s) then %s | HH-NORTH-DC %s',
                                       v_again -> 'installed', v_devices, v_after, v_kept));
    return next;

    -- ── 4. Not in an ordinary organisation ──────────────────────────────────
    v_step := 'an organisation that is not a demonstration';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant(
      'zzdv-' || v_tag, 'Not A Demo Devices Suite', 'admin@zzdv-' || v_tag || '.test', 'Plain Admin');
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzdv-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    v_conf := erp.ensure_demo_configuration(rc.tenant_id, rc.admin_user_id);
    v_cases := v_cases + 1;
    case_name := 'an organisation that is not a demonstration is given no device';
    passed := v_state is null and not ((v_conf -> 'installed') ? 'devices')
          and not exists (select 1 from erp.device d where d.tenant_id = rc.tenant_id);
    detail := coalesce(v_state, (v_conf -> 'installed')::text);
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
    raise exception 'CLOVEERP_DEMO_DEVICES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demo_devices_suite() from public, anon;

comment on function erp_test.demo_devices_suite() is
  'A demonstration has a device (20261006020000): every demo stock site has an active handheld its administrator '
  'can open; nothing twice, nothing overwritten, nothing outside a demonstration.';

create or replace function erp_test.assert_demo_devices_suite()
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
    from erp_test.demo_devices_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMO_DEVICES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The demonstration''s Scanner would open on no device. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_DEMO_DEVICES_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demo devices: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demo_devices_suite() from public, anon;

comment on function erp_test.assert_demo_devices_suite() is
  'A demonstration has a handheld at each stock site, and only a demonstration is given one (20261006020000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Every demonstration there is today, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $seed$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.seed_demo_devices(r.id);
    -- The checks the writes left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the tables.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'demo devices: % handheld(s) registered in %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$seed$;

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
