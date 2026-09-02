-- =============================================================================
-- Part 17, repaired forward: containment has an hour to name who was affected
--
-- 20260904550000 made "a contained incident scoped to some organisations and
-- names none" a discipline finding, and made it fire the moment containment
-- was recorded. Naming the affected FOLLOWS containment — §17.3: "the first
-- question after containment is scope" — so the register's own support suite,
-- which contains an incident and asserts discipline in the same breath, tripped
-- the finding on every fresh build. The schema build on main is red for exactly
-- that reason.
--
-- The finding now bites once containment has stood for an hour unnamed. The
-- hour is the time it takes to say who, not a grace: an incident contained as
-- partial and still naming nobody an hour later IS silence toward the affected.
--
-- 20260904550000 has been applied wherever main is deployed, so it is not
-- edited; the two definitions are re-emitted here, and the service-notice suite
-- proves both halves: no finding inside the hour, a finding after it.
-- =============================================================================

create or replace function erp.support_discipline_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $function$
  -- §17.2: a severity with no stated response is a severity negotiated case by
  -- case, which is what "published" rules out.
  select 'a severity states no response or update cadence', s.code, s.name
    from erp_ref.support_severity s
   where s.response_within_minutes is null or s.update_every_minutes is null
  union all
  -- §17.2: the cadences must order with the severities. A severity 1 answered
  -- more slowly than a severity 3 is a scale that means nothing.
  select 'a more severe level is answered more slowly than a less severe one',
         a.code || ' vs ' || b.code,
         format('%s responds in %s minutes, %s in %s',
                a.code, a.response_within_minutes, b.code, b.response_within_minutes)
    from erp_ref.support_severity a
    join erp_ref.support_severity b on b.seq > a.seq
   where a.response_within_minutes > b.response_within_minutes
  union all
  -- §17.1: standing access does not exist. An unbounded grant is the shape it
  -- would take.
  select 'a support access has no expiry within a week of its grant',
         a.id::text, format('granted %s, expires %s', a.granted_at, a.expires_at)
    from erp.support_access a
   where a.expires_at > a.granted_at + interval '7 days'
  union all
  -- §17.1: a write performed under read-only access.
  select 'a support action was recorded against read-only access',
         act.id::text, act.action
    from erp.support_action act
    join erp.support_access acc
      on acc.tenant_id = act.tenant_id and acc.id = act.support_access_id
   where act.is_write and not acc.is_write_access
  union all
  -- §17.3: an incident declared without all three roles.
  select 'an incident names no commander, communications owner or scribe',
         i.code, i.title
    from erp_meta.incident i
   where coalesce(btrim(i.commander), '') = ''
      or coalesce(btrim(i.communications_owner), '') = ''
      or coalesce(btrim(i.scribe), '') = ''
  union all
  -- §17.3: a resolved severity 1 or 2 with no review.
  select 'a resolved severity 1 or 2 incident has no post-incident review',
         i.code, i.severity_code
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
   where s.requires_review and i.resolved_at is not null
     and (i.review_url is null or i.review_completed_at is null)
  union all
  -- §17.3: communication on a timer.
  select 'a live incident has gone longer than its cadence without an update',
         i.code,
         format('%s allows %s minutes between updates',
                i.severity_code, s.update_every_minutes)
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
   where i.resolved_at is null
     and now() - coalesce(
       (select max(u.posted_at) from erp_meta.incident_update u
         where u.incident_id = i.id), i.declared_at)
         > make_interval(mins => s.update_every_minutes)
  union all
  -- §17.3: "never silence toward affected ones". An incident contained as
  -- reaching some organisations and not all, with none named an hour later,
  -- is scoped to nobody: the affected are told nothing and cannot know they
  -- are affected. The hour is the time it takes to say who, not a grace.
  select 'a contained incident is scoped to some organisations and names none',
         i.code, i.scope
    from erp_meta.incident i
   where i.contained_at is not null
     and i.contained_at < now() - interval '1 hour'
     and i.affects_all_tenants is false
     and not exists (select 1 from erp_meta.incident_tenant t where t.incident_id = i.id)
  union all
  -- §17.4: a security incident on no disclosure path.
  select 'a security incident has no disclosure obligations dated',
         i.code, i.title
    from erp_meta.incident i
   where i.is_security
     and not exists (select 1 from erp_meta.incident_disclosure d where d.incident_id = i.id)
  union all
  -- §17.4: a stated timeline the platform let pass. The organisation's own
  -- obligations are shown to it rather than failed here; the platform cannot
  -- record what a controller told its regulator.
  select 'the platform''s disclosure deadline passed unrecorded',
         i.code, format('%s was due %s', d.obligation_code, d.due_at)
    from erp_meta.incident_disclosure d
    join erp_meta.incident i on i.id = d.incident_id
    join erp_ref.notice_period n on n.code = d.obligation_code
   where n.obliged_party = 'platform' and d.notified_at is null and d.due_at < now()
  order by 1, 2
$function$;

-- ── The suite, proving both halves ─────────────────────────────────────────

create or replace function erp_test.service_notice_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  ra record; rb record;
  ca text := 'zzsna-' || substr(md5(random()::text), 1, 6);
  cb text := 'zzsnb-' || substr(md5(random()::text), 1, 6);
  op uuid := gen_random_uuid();
  aa uuid := gen_random_uuid();
  ab uuid := gen_random_uuid();
  inc text := 'zzsn-inc';
  v_ok boolean; v_msg text; res jsonb; v_n integer;
begin
  insert into auth.users (id, email) values
    (op, 'op@zzsn.test'), (aa, 'a@zzsn.test'), (ab, 'b@zzsn.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('op@zzsn.test', op, 'Notice Operator', 'operator');

  select * into ra from erp.provision_tenant(ca, 'Affected Org', 'a@zzsn.test', 'A Admin');
  select * into rb from erp.provision_tenant(cb, 'Bystander Org', 'b@zzsn.test', 'B Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  perform erp.claim_invitation(ra.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  perform erp.claim_invitation(rb.admin_token);

  -- ── §17.3 scoped communication ────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.declare_incident(inc, 'sev2', 'Report runs failing for two organisations',
                               'A. Commander', 'B. Comms', 'C. Scribe');
  perform erp.post_incident_update(inc, 'We are looking at the report runner. Next update in two hours.');

  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'an incident nobody has been named in reaches no organisation',
    jsonb_array_length(res -> 'incidents') = 0, 'declared, not yet scoped: nobody alarmed';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  v_n := erp.name_affected_organisations(inc, array[ca]);
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'the organisation named as affected is told, with the updates',
    v_n = 1 and jsonb_array_length(res -> 'incidents') = 1
    and res -> 'incidents' -> 0 ->> 'code' = inc
    and jsonb_array_length(res -> 'incidents' -> 0 -> 'updates') = 1,
    res -> 'incidents' -> 0 ->> 'title';

  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  res := erp.service_notices();
  return query select 'and the bystander is not',
    jsonb_array_length(res -> 'incidents') = 0, 'never a broadcast that alarms the unaffected';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.name_affected_organisations(inc, array['no-such-org']);
    v_ok := false; v_msg := 'an organisation that does not exist was named';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_TENANT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'naming an organisation that does not exist is refused', v_ok, v_msg;

  perform erp.contain_incident(inc, 'The report runner, all organisations', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  res := erp.service_notices();
  return query select 'containment that reached everyone tells everyone',
    jsonb_array_length(res -> 'incidents') = 1
    and (res -> 'incidents' -> 0 ->> 'affects_all_tenants')::boolean,
    'scope is known after containment, and communication follows it';

  -- A second incident contained as partial with nobody named is the silence
  -- §17.3 forbids, and the discipline report says so.
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.declare_incident(inc || '-2', 'sev3', 'Slow label rendering at one site',
                               'A', 'B', 'C');
  perform erp.contain_incident(inc || '-2', 'One organisation''s label printer', false);
  return query select 'containment scoped to some has an hour to say who',
    not exists (select 1 from erp.support_discipline_report() f
                 where f.finding like 'a contained incident is scoped to some%' and f.reference = inc || '-2'),
    'no finding in the hour after containment';
  update erp_meta.incident set contained_at = now() - interval '2 hours' where code = inc || '-2';
  return query select 'a contained incident scoped to some and naming none an hour later is a finding',
    exists (select 1 from erp.support_discipline_report() f
             where f.finding like 'a contained incident is scoped to some%' and f.reference = inc || '-2'),
    'silence toward the affected, found rather than assumed';
  perform erp.name_affected_organisations(inc || '-2', array[cb]);
  return query select 'and naming them clears it',
    not exists (select 1 from erp.support_discipline_report() f
                 where f.reference = inc || '-2'), 'named';

  -- ── §17.4 planned maintenance against the notice period ──────────────────

  begin
    perform erp.announce_maintenance('zzsn-win-short', 'Tonight', 'Database restart',
                                     now() + interval '2 hours', now() + interval '3 hours', true);
    v_ok := false; v_msg := 'a two-hour notice was accepted as planned maintenance';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_MAINTENANCE_NOTICE_TOO_SHORT%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'planned maintenance inside the notice period is refused', v_ok, v_msg;

  begin
    perform erp.announce_maintenance('zzsn-win-em', 'Now', 'Failing disk',
                                     now() + interval '10 minutes', now() + interval '40 minutes',
                                     true, null, true, null);
    v_ok := false; v_msg := 'an emergency with no reason was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_EMERGENCY_HAS_NO_REASON%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'emergency maintenance without a reason is refused', v_ok, v_msg;

  perform erp.announce_maintenance('zzsn-win-em', 'Storage replacement', 'Failing disk on the primary',
                                   now() + interval '10 minutes', now() + interval '40 minutes',
                                   true, null, true, 'A disk is failing and will not last the notice period.');
  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  res := erp.service_notices();
  return query select 'an emergency with its reason is announced and reads as one',
    exists (select 1 from jsonb_array_elements(res -> 'maintenance') w
             where w ->> 'code' = 'zzsn-win-em' and (w ->> 'is_emergency')::boolean),
    'emergency, with its reason, to everyone';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.announce_maintenance('zzsn-win-nobody', 'For nobody', null,
                                     now() + interval '3 days', now() + interval '3 days 1 hour', false);
    v_ok := false; v_msg := 'a window for nobody in particular was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_MAINTENANCE_AFFECTS_NOBODY%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a window that is not for everyone names who it is for', v_ok, v_msg;

  perform erp.announce_maintenance('zzsn-win-a', 'Index rebuild', 'Reporting slower for an hour',
                                   now() + interval '3 days', now() + interval '3 days 1 hour',
                                   false, array[ca]);
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  v_ok := exists (select 1 from jsonb_array_elements(res -> 'maintenance') w where w ->> 'code' = 'zzsn-win-a');
  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  res := erp.service_notices();
  return query select 'a window for one organisation is shown to it and not to another',
    v_ok and not exists (select 1 from jsonb_array_elements(res -> 'maintenance') w where w ->> 'code' = 'zzsn-win-a'),
    'scoped like an incident';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.cancel_maintenance('zzsn-win-a', '  ');
    v_ok := false; v_msg := 'a cancellation with no reason was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CANCELLATION_HAS_NO_REASON%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a cancelled window says why', v_ok, v_msg;
  perform erp.cancel_maintenance('zzsn-win-a', 'Rebuilt online instead.');
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'and a cancelled window is no longer a notice',
    not exists (select 1 from jsonb_array_elements(res -> 'maintenance') w where w ->> 'code' = 'zzsn-win-a'),
    'cancelled';

  -- ── §17.4 the disclosure path ─────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.record_disclosure(inc, 'security_disclosure_to_organisation', 'told');
    v_ok := false; v_msg := 'a disclosure was recorded on an incident with no path';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_A_SECURITY_INCIDENT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a disclosure cannot be recorded before the incident is on the path', v_ok, v_msg;

  v_n := erp.flag_security_incident(inc);
  return query select 'flagging a security incident dates every published timeline from its declaration',
    v_n = 3
    and (select count(*) from erp.disclosure_report() d where d.incident_code = inc
           and d.due_at = (select i.declared_at from erp_meta.incident i where i.code = inc)
                          + make_interval(hours => (select n.hours from erp_ref.notice_period n where n.code = d.obligation_code))) = 3,
    format('%s obligation(s)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'the organisation sees its own obligations with the clock running',
    (select count(*) from jsonb_array_elements(res -> 'incidents' -> 0 -> 'obligations') o
      where o ->> 'obliged_party' = 'organisation') = 2
    and (res -> 'incidents' -> 0 ->> 'is_security')::boolean,
    'to the authority and to the people affected, both dated';

  -- The platform's deadline passes unrecorded: the report says so, then it is
  -- recorded and the finding clears.
  update erp_meta.incident_disclosure d set due_at = now() - interval '1 hour'
   where d.incident_id = (select i.id from erp_meta.incident i where i.code = inc)
     and d.obligation_code = 'security_disclosure_to_organisation';
  return query select 'a platform deadline passed unrecorded is a finding',
    exists (select 1 from erp.support_discipline_report() f
             where f.finding like 'the platform''s disclosure deadline%' and f.reference = inc),
    'stated timelines are failed, not remembered';
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.record_disclosure(inc, 'security_disclosure_to_organisation', 'Email to both administrators.');
  return query select 'and recording the disclosure clears it',
    not exists (select 1 from erp.support_discipline_report() f
                 where f.finding like 'the platform''s disclosure deadline%' and f.reference = inc)
    and (select d.notified_by from erp.disclosure_report() d
          where d.incident_code = inc and d.obligation_code = 'security_disclosure_to_organisation') = 'op@zzsn.test',
    'recorded, by whom';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.incident where code like 'zzsn-%';
  delete from erp_meta.maintenance_window where code like 'zzsn-%';
  perform erp.begin_tenant_purge(ra.tenant_id);
  delete from erp.tenant where id = ra.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(rb.tenant_id);
  delete from erp.tenant where id = rb.tenant_id;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzsn.test';
  delete from auth.users where id in (op, aa, ab);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id in (ra.tenant_id, rb.tenant_id))
    and not exists (select 1 from erp_meta.incident where code like 'zzsn-%')
    and not exists (select 1 from erp_meta.maintenance_window where code like 'zzsn-%')
    and not exists (select 1 from erp_meta.platform_staff where email like '%@zzsn.test'),
    'organisations, incidents, windows and staff gone';
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

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
select erp.assert_no_dead_configuration();
select erp.assert_support_discipline();
select erp.assert_diagnostics_registered();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
