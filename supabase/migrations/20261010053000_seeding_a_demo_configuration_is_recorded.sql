set lock_timeout = '30s';

-- =============================================================================
-- 20261010053000  Seeding a demo configuration is recorded, and so works
-- -----------------------------------------------------------------------------
-- Found rehearsing the rebuild of the live demonstration, 5 October. Master
-- data → Classification and coding → "Seed a demo configuration" calls
-- public.erp_seed_demo_configuration(), and it always refused:
--
--   CLOVEERP_UNKNOWN_EVENT_TYPE: configuration.preset_applied has no current
--   version
--
-- The door writes its axes, values, code template, supplier defaults and
-- release areas, and last of all records what it did with
-- erp.append_event('configuration.preset_applied', 'tenant', ...). That event
-- type was never declared in erp_ref.event_type, so erp.append_event()
-- refused, and the refusal took everything the door had written with it. No
-- demonstration has ever had its classification axes or release areas from
-- this button.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The event type is declared, as every other is: configuration.
--      preset_applied, version 1, on the tenant, in master data (the screen
--      the button is on), with the payload the door writes, and named in
--      English and German.
--   B. erp_test.demo_configuration_preset_suite, three cases, and its
--      assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- The door is as it was: refused in a live environment, to anybody who is not
-- platform staff while sign-up is closed, and without administration.
-- configure. No function, permission, refusal or screen is changed.
--
-- On production: one event type and its two names are added. No table is
-- altered and no row of any organisation is touched. The button works from
-- the next press.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The event type
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('configuration.preset_applied', 1, 'tenant', 'master_data', 'event.configuration.preset_applied',
   'The demonstration configuration was seeded from Classification and coding: classification axes and values, a code template, supplier defaults and release areas.',
   '{"type":"object","required":["items_classified","suppliers","release_areas"],"properties":{"items_classified":{"type":"integer"},"suppliers":{"type":"integer"},"release_areas":{"type":"integer"}}}'::jsonb, true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'configuration.preset_applied'
         and et.is_current and et.version = 1 and et.aggregate_type = 'tenant'
         and et.name_key = 'event.' || et.code) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: configuration.preset_applied is declared already, and not as 20261010053000 declares it';
  end if;
end
$event$;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.configuration.preset_applied', 'en', 'Demo configuration seeded', 'master_data',
   'Event raised when the demonstration configuration is seeded from Classification and coding (20261010053000).'),
  ('event.configuration.preset_applied', 'de', 'Demo-Konfiguration angelegt', 'master_data',
   'Ereignis, wenn die Demo-Konfiguration unter Klassifizierung und Codierung angelegt wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demo_configuration_preset_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'reading the event type';
  v_state  text;
  v_tenant uuid;
  v_res    jsonb;
  v_res2   jsonb;
  v_axes   integer;
  v_axes2  integer;
  v_areas  integer;
  v_events integer;
  v_events2 integer;
begin
  begin
    -- ── 1. Declared ─────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the event the demo configuration records is declared, current, and named in English and German';
    passed := exists (select 1 from erp_ref.event_type et
                       where et.code = 'configuration.preset_applied' and et.is_current
                         and et.aggregate_type = 'tenant')
          and (select count(distinct r.locale) from erp_ref.resource r
                 join erp_ref.event_type et on et.name_key = r.key
                where et.code = 'configuration.preset_applied' and et.is_current
                  and r.locale in ('en', 'de')) = 2;
    detail := coalesce((select format('version %s on %s, in %s', et.version, et.aggregate_type, et.module_code)
                          from erp_ref.event_type et
                         where et.code = 'configuration.preset_applied' and et.is_current),
                       'not declared');
    return next;

    -- ── The fixture: a demonstration configured to trade ────────────────────
    v_step := 'a demonstration configured to trade';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdcp-' || v_tag, 'Demo Configuration Suite', 'admin@zzdcp-' || v_tag || '.test', 'Demo Configuration Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzdcp-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;

    -- ── 2. The button works ─────────────────────────────────────────────────
    v_step := 'Seed a demo configuration';
    v_res := public.erp_seed_demo_configuration();
    select count(*) into v_axes from erp.classification_axis a
     where a.tenant_id = v_tenant and a.code in ('FAMILY', 'GRADE') and a.status = 'active';
    select count(*) into v_areas from erp.release_area r
     where r.tenant_id = v_tenant and r.code = 'DEMO-REL';
    select count(*) into v_events from erp.event e
     where e.tenant_id = v_tenant and e.event_type = 'configuration.preset_applied'
       and e.aggregate_type = 'tenant' and e.aggregate_id = v_tenant;
    v_cases := v_cases + 1;
    case_name := 'Seed a demo configuration writes its two axes, its release areas and its classifications, and records that it did';
    passed := v_state is null
          and (v_res ->> 'axes')::integer = 2 and v_axes = 2
          and (v_res ->> 'release_areas')::integer > 0 and v_areas = (v_res ->> 'release_areas')::integer
          and (v_res ->> 'items_classified')::integer > 0
          and v_events = 1;
    detail := coalesce(v_state, format('%s; %s axis/axes, %s release area(s), %s event(s)',
                                       v_res, v_axes, v_areas, v_events));
    return next;

    -- ── 3. And pressed again ────────────────────────────────────────────────
    v_step := 'Seed a demo configuration, pressed again';
    v_res2 := public.erp_seed_demo_configuration();
    select count(*) into v_axes2 from erp.classification_axis a
     where a.tenant_id = v_tenant and a.status = 'active';
    select count(*) into v_events2 from erp.event e
     where e.tenant_id = v_tenant and e.event_type = 'configuration.preset_applied';
    v_cases := v_cases + 1;
    case_name := 'pressed again it answers again, adds no axis, and records the second press';
    passed := v_state is null and v_res2 is not null
          and v_axes2 = v_axes and v_events2 = 2;
    detail := coalesce(v_state, format('%s; %s axis/axes, %s event(s)', v_res2, v_axes2, v_events2));
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
    raise exception 'CLOVEERP_DEMO_CONFIGURATION_PRESET_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demo_configuration_preset_suite() from public, anon;

comment on function erp_test.demo_configuration_preset_suite() is
  'Seed a demo configuration on Classification and coding (20261010053000): the event it records is declared and '
  'named, the button writes its axes, release areas and classifications and records that it did, and pressed again '
  'it answers again and adds no axis.';

create or replace function erp_test.assert_demo_configuration_preset_suite()
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
    from erp_test.demo_configuration_preset_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMO_CONFIGURATION_PRESET_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Seed a demo configuration refuses, or the event it records is not declared. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_DEMO_CONFIGURATION_PRESET_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demo configuration preset: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demo_configuration_preset_suite() from public, anon;

comment on function erp_test.assert_demo_configuration_preset_suite() is
  'Seed a demo configuration works, and the event it records is declared (20261010053000).';

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
