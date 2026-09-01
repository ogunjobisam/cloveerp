-- =============================================================================
-- The suite for a register that could not be written to
--
-- erp.assert_support_discipline() passed on every build ERPWare has ever made,
-- and it was not lying. It reads erp.support_discipline_report(), which fails an
-- incident missing a role, a resolved severity 1 with no review, and a live
-- incident that has gone quiet past its cadence. Every one of those findings was
-- correct, and none of them could ever fire, because no function wrote to
-- erp_meta.incident at all. An assertion over an empty table is a green light
-- with nothing behind it.
--
-- So the suite writes. Every case here declares, updates, contains or resolves
-- something through the new doors, and the attacks are the ones §17.3 cares
-- about: an incident declared with a role left blank, a severity that owes a
-- blameless review being closed without one, a channel that has gone quiet, and
-- an update appended to an incident after it was resolved — which rewrites what
-- people were told at the time.
--
-- The support-action cases are the same shape one level along. §17.1 makes
-- access time-bounded, reasoned and logged; the log had no writer, so the
-- discipline report's finding about actions under read-only access described
-- rows nothing could create. Now they can be created, and the two ways of
-- getting them wrong — an expired grant, somebody else's grant — are refused.
-- =============================================================================

create or replace function erp_test.incident_operations_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r        record;
  v_tenant uuid;
  v_code   text := 'zzinc-' || substr(md5(random()::text), 1, 6);
  op       uuid := gen_random_uuid();   -- platform operator
  su       uuid := gen_random_uuid();   -- platform support
  nb       uuid := gen_random_uuid();   -- nobody
  ad       uuid := gen_random_uuid();   -- tenant administrator
  v_ok     boolean; v_msg text; v_n integer;
  v_access uuid; v_other uuid; res jsonb;
  i1       text := 'zzinc-sev1';
  i3       text := 'zzinc-sev3';
begin
  insert into auth.users (id, email) values
    (op, 'op@zzinc.test'), (su, 'su@zzinc.test'),
    (nb, 'nb@zzinc.test'), (ad, 'admin@zzinc.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('op@zzinc.test', op, 'Incident Operator', 'operator'),
         ('su@zzinc.test', su, 'Incident Support', 'support');

  select * into r from erp.provision_tenant(
    v_code, 'Incident Org', 'admin@zzinc.test', 'Incident Admin');
  v_tenant := r.tenant_id;

  -- ── §17.3 declaring ───────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', nb)::text, true);
  begin
    perform erp.declare_incident('zzinc-x', 'sev1', 'Nobody declares this',
                                 'A', 'B', 'C');
    v_ok := false; v_msg := 'an account off the staff list declared an incident';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_PLATFORM%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an account that is not platform staff cannot declare one',
    v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);

  begin
    perform erp.declare_incident('zzinc-x', 'sev9', 'Invented severity',
                                 'A', 'B', 'C');
    v_ok := false; v_msg := 'an unpublished severity was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_SEVERITY%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a severity nobody published is refused', v_ok, v_msg;

  begin
    perform erp.declare_incident('zzinc-x', 'sev1', 'No scribe',
                                 'Commander', 'Comms', '   ');
    v_ok := false; v_msg := 'an incident was declared with a role left blank';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_INCIDENT_ROLES_UNFILLED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and an incident with a role left blank',
    v_ok, '§17.3 names three; a blank string satisfies NOT NULL and is not a person';

  perform erp.declare_incident(i1, 'sev1', 'Posting is failing for some organisations',
                               'A. Commander', 'B. Comms', 'C. Scribe', true);
  return query select 'a declaration with all three roles lands',
    (select r2.state from erp.incident_report() r2 where r2.code = i1) = 'live',
    'and reads as live until somebody says otherwise';

  return query select 'and the assertion that was always green now has something to read',
    erp.assert_support_discipline() is not null
      and (select count(*) from erp_meta.incident) > 0,
    'an assertion over an empty table is a green light with nothing behind it';

  -- ── §17.3 communication on a timer ────────────────────────────────────────

  begin
    perform erp.post_incident_update(i1, 'short');
    v_ok := false; v_msg := 'an update of five characters was accepted';
  exception when others then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'an update that says nothing is refused', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', su)::text, true);
  perform erp.post_incident_update(i1, 'Cause identified, mitigation being applied.');
  return query select 'support can post an update, which is what support is doing',
    (select r2.updates from erp.incident_report() r2 where r2.code = i1) = 1,
    'the cadence is a promise to keep talking, kept by whoever is on the channel';

  perform erp.post_incident_update(i1, 'No change since the last update.', true);
  return query select 'and "no change" is a real update, not a gap',
    (select r2.updates from erp.incident_report() r2 where r2.code = i1) = 2,
    'it is the one people stop sending, which is how a channel goes quiet';

  return query select 'a channel inside its cadence is not overdue',
    not (select r2.overdue from erp.incident_report() r2 where r2.code = i1),
    'sev1 is answered every 60 minutes';

  update erp_meta.incident_update set posted_at = now() - interval '3 hours'
   where incident_id = (select id from erp_meta.incident where code = i1);
  return query select 'and one that has gone quiet past its cadence is',
    (select r2.overdue from erp.incident_report() r2 where r2.code = i1),
    '§17.3''s silence, visible from the register rather than from somebody noticing';

  perform erp.post_incident_update(i1, 'Mitigation applied; monitoring recovery.');
  return query select 'posting again clears it',
    not (select r2.overdue from erp.incident_report() r2 where r2.code = i1),
    'which is the whole point of measuring it';

  -- ── §17.3 containment says who was affected ───────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);

  begin
    perform erp.contain_incident(i1, '', null);
    v_ok := false; v_msg := 'containment was claimed without saying what it reached';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CONTAINMENT_HAS_NO_SCOPE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'containment that does not say who was affected is refused',
    v_ok, v_msg;

  perform erp.contain_incident(i1, 'Two organisations on the EU cluster', false);
  return query select 'and with a scope it lands',
    (select r2.state from erp.incident_report() r2 where r2.code = i1) = 'contained'
      and (select r2.affects_all_tenants from erp.incident_report() r2 where r2.code = i1) = false,
    'a claim nobody can check is not a containment';

  -- ── §17.3 a blameless review is not optional ──────────────────────────────

  begin
    perform erp.resolve_incident(i1);
    v_ok := false; v_msg := 'a severity 1 was closed with no review';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REVIEW_REQUIRED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a severity that owes a review cannot be resolved without one',
    v_ok, v_msg;

  perform erp.resolve_incident(i1, 'https://reviews.example/zzinc-sev1');
  return query select 'and resolves once the review exists',
    (select r2.state from erp.incident_report() r2 where r2.code = i1) = 'resolved',
    'a review owed after the urgency has passed is a review nobody writes';

  begin
    perform erp.post_incident_update(i1, 'One more thing, after the fact.');
    v_ok := false; v_msg := 'an update was appended to a resolved incident';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_INCIDENT_RESOLVED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and nothing may be appended to it afterwards',
    v_ok, 'the record is what the review reads; appending rewrites what people were told';

  perform erp.declare_incident(i3, 'sev3', 'A report is slow',
                               'A. Commander', 'B. Comms', 'C. Scribe');
  perform erp.contain_incident(i3, 'One organisation', false);
  perform erp.resolve_incident(i3);
  return query select 'a severity that owes no review resolves without one',
    (select r2.state from erp.incident_report() r2 where r2.code = i3) = 'resolved',
    '§17.3 requires the review for severity 1 and 2, and means it for those';

  -- ── §17.1 the log that had no writer ──────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', su)::text, true);
  res := erp.grant_support_access(v_tenant, 'Investigating the posting failure under zzinc-sev1', 4, false, 'REQ-1');
  v_access := (res ->> 'access_id')::uuid;

  return query select 'a support grant can be issued',
    v_access is not null, 'time-bounded and reasoned, which always worked';

  perform erp.record_support_action(v_access, 'read_posting_rules',
    'Checking which ledger the cash application rule names', null, null, false);
  return query select 'and what was done under it can now be recorded',
    (select count(*) from erp.support_action a where a.support_access_id = v_access) = 1,
    '§17.1 says logged; the log had no writer until now';

  return query select 'a READ under a read-only grant is loggable',
    (select not a.is_write from erp.support_action a
      where a.support_access_id = v_access) and erp.assert_support_discipline() is not null,
    'the clause forbidding it forbade the thing §17.1 most wants recorded';

  begin
    perform erp.record_support_action(v_access, 'edit_posting_rule',
      'Changing the ledger', null, null, true);
    v_ok := false; v_msg := 'a write was recorded against a read-only grant';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SUPPORT_ACCESS_IS_READ_ONLY%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'but a WRITE under one is refused', v_ok, v_msg;

  return query select 'and an action that says nothing about itself counts as a write',
    (select a.is_write from erp.support_action a
      where a.support_access_id = v_access and a.action = 'read_posting_rules') is not null,
    'is_write defaults to true, so silence fails safe rather than passing quietly';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.record_support_action(v_access, 'poking about', 'Not my grant');
    v_ok := false; v_msg := 'an action was recorded against somebody else''s grant';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SUPPORT_ACCESS_NOT_YOURS%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an action against somebody else''s grant is refused',
    v_ok, 'it would attribute the work to the wrong person, which the log exists to get right';

  -- erp.support_access is append-only, so an expired grant is written as one
  -- rather than aged into existence — which is also how a real one looks the
  -- moment its window closes.
  perform set_config('request.jwt.claims', json_build_object('sub', su)::text, true);
  perform set_config('erp.job_tenant_id', v_tenant::text, true);
  insert into erp.support_access
    (tenant_id, staff_email, staff_role, reason, request_reference,
     is_write_access, granted_at, expires_at)
  values (v_tenant, 'su@zzinc.test', 'support',
          'A grant whose window has already closed', 'REQ-2',
          false, now() - interval '2 days', now() - interval '1 day')
  returning id into v_other;

  begin
    perform erp.record_support_action(v_other, 'late', 'After the window closed');
    v_ok := false; v_msg := 'an action was recorded after the grant expired';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SUPPORT_ACCESS_EXPIRED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and one after the window closed',
    v_ok, '§17.1: extension is a fresh act, recorded — not a clock nobody checked';

  -- ── The console can reach any of it at all ────────────────────────────────

  return query select 'the platform console can read incidents, continuity and access',
    (select count(*) from pg_catalog.pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('erp_platform_incidents','erp_platform_continuity',
                          'erp_platform_support_access',
                          'erp_platform_declare_incident',
                          'erp_platform_post_incident_update',
                          'erp_platform_contain_incident',
                          'erp_platform_resolve_incident',
                          'erp_platform_record_support_action')) = 8,
    'twenty-seven platform doors existed and not one reached Part 16 or Part 17';

  return query select 'and none of those doors is callable without signing in',
    not exists (select 1 from pg_catalog.pg_proc p
                 where p.pronamespace = 'public'::regnamespace
                   and p.proname in ('erp_platform_incidents','erp_platform_continuity',
                                     'erp_platform_support_access',
                                     'erp_platform_declare_incident',
                                     'erp_platform_post_incident_update',
                                     'erp_platform_contain_incident',
                                     'erp_platform_resolve_incident',
                                     'erp_platform_record_support_action')
                   and pg_catalog.has_function_privilege('anon', p.oid, 'execute')),
    'on this project a new public function is granted to anon until revoked';

  return query select 'the discipline and release assertions both still hold',
    erp.assert_support_discipline() is not null
      and erp.assert_release_integrity() is not null
      and erp.assert_public_api_safe() is not null,
    'with rows in the register this time';

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.incident_update
   where incident_id in (select id from erp_meta.incident where code like 'zzinc-%');
  delete from erp_meta.incident where code like 'zzinc-%';
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzinc.test';
  delete from auth.users where id in (op, su, nb, ad);

  select count(*) into v_n from erp_meta.incident where code like 'zzinc-%';
  return query select 'the suite leaves nothing behind',
    v_n = 0
      and not exists (select 1 from erp_meta.platform_staff where email like '%@zzinc.test')
      and erp.assert_support_discipline() is not null,
    'a staff row left behind changes what erp_platform_claim_ownership() does next';
end;
$$;

comment on function erp_test.incident_operations_suite is
  'Specification v1.2 §17.1 and §17.3. erp.assert_support_discipline() passed on '
  'every build and was not lying — it read a table no function could write to, '
  'which is a green light with nothing behind it. Every case here writes, and '
  'attacks what §17.3 cares about: a role left blank, a severity closed without '
  'the blameless review it owes, a channel gone quiet, and an update appended '
  'after resolution.';

create or replace function erp_test.assert_incident_operations_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _incident_ops_result on commit drop as
    select * from erp_test.incident_operations_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _incident_ops_result;

  if v_total <> 28 then
    raise exception 'ERPWARE_INCIDENT_OPS_SUITE_SHRANK: % case(s), expected 28', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_INCIDENT_OPS_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('incident operations: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_incident_operations_suite();
