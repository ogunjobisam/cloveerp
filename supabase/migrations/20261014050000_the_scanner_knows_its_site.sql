-- The scanner knows its site.
--
-- Found by the owner trying the phone's camera on the demonstration, 14
-- October 2026. "Handling unit build" asked a handheld registered to
-- Birmingham warehouse to scan its site, and erp.resolve_scan_reference took
-- site_id for no kind at all, so nothing scanned could ever answer it but a
-- raw identifier: the camera read a real barcode and was told "site_id
-- expects an identifier and N652P261500G is not one". parent_container_id
-- and party_id were the same. The screen half (the device's own site offered
-- in one press, and every step in words) is in src/routes/device.tsx.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.resolve_scan_reference reads a site by its code, a business
--      partner by its code, and a parent handling unit as any handling unit
--      (by its SSCC); what it cannot read is said without its field name.
--   B. erp_devices says each device's site by its identifier and name too,
--      so the scanner can offer it without a scan.
--   C. erp_test.scanner_site_suite proves A and B.

do $resolve$
declare
  v_sig   constant text := 'erp.resolve_scan_reference(text,text,jsonb,text)';
  v_def   text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    when p_key = 'container_id' then 'container'$o$,
    $n$    when p_key in ('container_id', 'parent_container_id') then 'container'
    -- A site and a business partner by their codes (20261014050000).
    when p_key = 'site_id' then 'site'
    when p_key = 'party_id' then 'party'$n$,
    $o$      when 'document_line' then (select count(*) from erp.document_line x where x.tenant_id = v_tenant and x.id = v_id)$o$,
    $n$      when 'document_line' then (select count(*) from erp.document_line x where x.tenant_id = v_tenant and x.id = v_id)
      when 'site' then (select count(*) from erp.site x where x.tenant_id = v_tenant and x.id = v_id)
      when 'party' then (select count(*) from erp.party x where x.tenant_id = v_tenant and x.id = v_id)$n$,
    $o$  elsif v_kind = 'shipment' then$o$,
    $n$  elsif v_kind = 'site' then
    select s.id, s.code || ' ' || s.name into v_id, v_label from erp.site s
     where s.tenant_id = v_tenant and upper(s.code) = upper(v_raw) and s.status = 'active' limit 1;
  elsif v_kind = 'party' then
    select p.id, p.code || ' ' || p.name into v_id, v_label from erp.party p
     where p.tenant_id = v_tenant and upper(p.code) = upper(v_raw) and p.status = 'active' limit 1;
  elsif v_kind = 'shipment' then$n$,
    $o$                   then format('%s expects an identifier and %s is not one', p_key, v_raw)$o$,
    $n$                   then format('%s is not something this step can read', v_raw)
                   when v_kind in ('site', 'party')
                   then format('no %s is coded %s', case v_kind when 'party' then 'business partner' else 'site' end, v_raw)$n$];
  v_hits  integer;
begin
  if position('20261014050000' in v_def) > 0 then
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$resolve$;

do $devices$
declare
  v_sig  constant text := 'public.erp_devices()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$'site', s.code, 'status', d.status,$o$;
  v_new  constant text := $n$'site', s.code, 'site_id', d.site_id, 'site_name', s.name, 'status', d.status,$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position($n$'site_id', d.site_id$n$ in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % site anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$devices$;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The scanner''s steps in words (20261014050000).'
  from (values
    ('Scan the site'),
    ('Scan the parent handling unit'),
    ('Scan the business partner'),
    ('Scan the document'),
    ('Code'),
    ('Type of handling unit'),
    ('Instrument'),
    ('Outcome'),
    ('Measured text'),
    ('How many scrapped?'),
    ('Cost'),
    ('Done?'),
    ('This device''s site'),
    ('Use this site'),
    ('Scan another site')) v(text)
on conflict do nothing;

create or replace function erp_test.scanner_site_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_site   uuid;
  v_code   text;
  v_party  uuid;
  x        jsonb;
  y        jsonb;
  z        jsonb;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzsst' || v_tag, 'Scanner Site Suite',
      'admin@demo-zzsst' || v_tag || '.test', 'Scanner Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzsst' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select s.id, s.code into v_site, v_code from erp.site s where s.tenant_id = v_tenant and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    insert into erp.device (tenant_id, site_id, code, name, device_class, status)
    values (v_tenant, v_site, 'ZSS-' || upper(v_tag), 'Suite handheld', 'handheld', 'active');
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (v_tenant, 'ZSSP' || upper(v_tag), 'Scanned Partner', 'GB', 'active') returning id into v_party;

    -- ── 1. A site by its code ───────────────────────────────────────────────
    v_step := 'a site scanned';
    x := erp.resolve_scan_reference('site_id', lower(v_code), '{}', 'ZSS-' || upper(v_tag));
    y := erp.resolve_scan_reference('site_id', v_site::text, '{}', null);
    v_cases := v_cases + 1;
    case_name := 'a site is read by its code, in any case, or by its identifier';
    passed := v_state is null
          and (x ->> 'resolved')::boolean and (x ->> 'id')::uuid = v_site and x ->> 'kind' = 'site'
          and (y ->> 'resolved')::boolean and (y ->> 'id')::uuid = v_site;
    detail := coalesce(v_state, x::text || ' | ' || y::text);
    return next;

    -- ── 2. Said in words ────────────────────────────────────────────────────
    v_step := 'what cannot be read';
    x := erp.resolve_scan_reference('site_id', 'N652P261500G', '{}', null);
    y := erp.resolve_scan_reference('code', 'N652P261500G', '{}', null);
    v_cases := v_cases + 1;
    case_name := 'a scan that is no site says so, and nothing says a field''s name';
    passed := v_state is null
          and not (x ->> 'resolved')::boolean and x ->> 'reason' = 'no site is coded N652P261500G'
          and not (y ->> 'resolved')::boolean and y ->> 'reason' = 'N652P261500G is not something this step can read'
          and position('_id' in (x ->> 'reason') || (y ->> 'reason')) = 0;
    detail := coalesce(v_state, (x ->> 'reason') || ' | ' || (y ->> 'reason'));
    return next;

    -- ── 3. A partner, and a parent unit ─────────────────────────────────────
    v_step := 'a partner and a parent unit';
    x := erp.resolve_scan_reference('party_id', 'zssp' || v_tag, '{}', null);
    z := erp.resolve_scan_reference('parent_container_id', '00350123456789012345', '{"sscc": "00350123456789012345"}', null);
    v_cases := v_cases + 1;
    case_name := 'a business partner is read by its code, and a parent unit as a handling unit';
    passed := v_state is null
          and (x ->> 'resolved')::boolean and (x ->> 'id')::uuid = v_party
          and z ->> 'kind' = 'container';
    detail := coalesce(v_state, x::text || ' | ' || z::text);
    return next;

    -- ── 4. The device says its site ─────────────────────────────────────────
    x := public.erp_devices();
    v_cases := v_cases + 1;
    case_name := 'a device says its site by identifier and name, so the scanner can offer it';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(x) d
                       where d ->> 'code' = 'ZSS-' || upper(v_tag) and (d ->> 'site_id')::uuid = v_site
                         and d ->> 'site' = v_code and coalesce(d ->> 'site_name', '') <> '');
    detail := coalesce(v_state, left(x::text, 200));
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
    raise exception 'CLOVEERP_SCANNER_SITE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.scanner_site_suite() from public, anon, authenticated;

create or replace function erp_test.assert_scanner_site_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _scanner_site on commit drop as
    select * from erp_test.scanner_site_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _scanner_site;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SCANNER_SITE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_SCANNER_SITE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('scanner site: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_scanner_site_suite() from public, anon, authenticated;

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
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_device_task_handlers_sound();
