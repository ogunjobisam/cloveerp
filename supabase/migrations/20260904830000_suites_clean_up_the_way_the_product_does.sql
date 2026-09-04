-- ─────────────────────────────────────────────────────────────────────────────
-- Two suites taught to clean up the way the product does.
--
-- 20260904810000 made erp_meta.platform_audit append-only, which it should
-- always have been. Both of these suites tore down by deleting their own audit
-- rows after closing the purge, so the new guard refused them — correctly.
--
-- The guard permits exactly one removal: the erasure of a whole organisation,
-- inside that organisation's own purge window. So the deletes move inside the
-- window rather than the guard being loosened for a test. tenant_deletion_suite
-- also reopens a window for each organisation the scheduled sweep took, because
-- those rows outlive the tenant row itself.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp_test.support_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  r record;
  ad uuid := gen_random_uuid();
  ow uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzsup-a';
  v_ok boolean; v_msg text; res jsonb; v_access uuid; v_write_access uuid;
  v_inc uuid; v_count integer;
  c_reason constant text := 'Customer raised INC-4471: despatch confirmations are not printing.';
begin
  select * into r from erp.provision_tenant(
    v_code, 'Support A', 'admin-a@zzsup.test', 'Support A Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email) values (ad, 'admin-a@zzsup.test'), (ow, 'owner@zzsup.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzsup.test', ow, 'Support Owner', 'owner');

  -- ── §17.2 the scale is published and ordered ──────────────────────────────

  return query select 'the severity scale is published, not negotiated',
    (select count(*) from erp_ref.support_severity) = 4,
    (select string_agg(s.code || ' in ' || s.response_within_minutes || 'm', ', ' order by s.seq)
       from erp_ref.support_severity s);

  return query select 'and answers the worst fastest',
    not exists (select 1 from erp_ref.support_severity a
                  join erp_ref.support_severity b on b.seq > a.seq
                 where a.response_within_minutes > b.response_within_minutes),
    'a severity 1 answered more slowly than a severity 3 is a scale that means nothing';

  -- ── §17.1 curiosity is not a reason ───────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  begin
    perform erp.grant_support_access(v_tenant, 'looking', 4);
    v_ok := false; v_msg := 'a one-word reason was accepted';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a reason too short to be one is refused', v_ok, v_msg;

  -- ── §17.1 standing access does not exist ──────────────────────────────────

  begin
    perform erp.grant_support_access(v_tenant, c_reason, 24 * 30);
    v_ok := false; v_msg := 'a month of access was granted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SUPPORT_WINDOW_INVALID%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'access cannot be granted for a month', v_ok, v_msg;

  begin
    insert into erp.support_access
      (tenant_id, staff_email, staff_role, reason, expires_at)
    values (v_tenant, 'owner@zzsup.test', 'owner', c_reason,
            now() + interval '10 years');
    v_ok := false; v_msg := 'an expiry ten years out was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'nor written directly with an expiry that is one in name only',
    v_ok, v_msg;

  begin
    insert into erp.support_access
      (tenant_id, staff_email, staff_role, reason, expires_at)
    values (v_tenant, 'owner@zzsup.test', 'owner', c_reason, now() - interval '1 hour');
    v_ok := false; v_msg := 'an access expiring before it began was accepted';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'and an access cannot expire before it is granted', v_ok, v_msg;

  -- ── §17.1 a real grant ────────────────────────────────────────────────────

  res := erp.grant_support_access(v_tenant, c_reason, 4, false, 'INC-4471');
  v_access := (res ->> 'access_id')::uuid;

  return query select 'a bounded grant is recorded',
    v_access is not null and not (res ->> 'write')::boolean,
    format('expires %s, read-only', res ->> 'expires_at');

  return query select 'and read-only is the default',
    (select not a.is_write_access from erp.support_access a where a.id = v_access),
    '§17.1: read-only by default';

  return query select 'the access is live now',
    erp.support_access_is_live(v_tenant), 'within its window';

  return query select 'but not for writing',
    not erp.support_access_is_live(v_tenant, true),
    'a write needs an access granted for writing, not merely an access';

  -- ── §17.1 extension is a fresh act ────────────────────────────────────────

  -- Six hours, not four. now() is transaction time, so two four-hour grants in
  -- one transaction would expire at the same instant and prove nothing; an
  -- extension is more time, which is what makes the comparison below mean
  -- something.
  res := erp.grant_support_access(v_tenant, c_reason || ' Extending: the fix needs a second window.',
                                  6, false, 'INC-4471', v_access);

  return query select 'an extension is a NEW row naming what it extends',
    (res ->> 'is_extension')::boolean
      and (select a.extension_of from erp.support_access a
            where a.id = (res ->> 'access_id')::uuid) = v_access,
    'not an expiry moved forward, which would leave no evidence of extending';

  return query select 'and the original still says when it was to end',
    (select a.expires_at from erp.support_access a where a.id = v_access)
      < (select a.expires_at from erp.support_access a
          where a.id = (res ->> 'access_id')::uuid),
    'the record of the first window survives the second';

  begin
    perform erp.grant_support_access(v_tenant, c_reason, 4, false, null, gen_random_uuid());
    v_ok := false; v_msg := 'an extension of nothing was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_SUCH_ACCESS_TO_EXTEND%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an extension of nothing is a grant wearing the word', v_ok, v_msg;

  -- ── §17.1 a write is a separately recorded act ────────────────────────────

  -- A write needs an access granted for writing. erp.support_action is
  -- append-only, so this row cannot be tidied away afterwards — which is why
  -- the read-only violation is left to the very end of the suite, where the
  -- purge removes it with the organisation.
  res := erp.grant_support_access(v_tenant,
    'Applying the agreed correction for INC-4471 under a write window.',
    2, true, 'INC-4471');
  v_write_access := (res ->> 'access_id')::uuid;

  begin
    insert into erp.support_action
      (tenant_id, support_access_id, action, reason)
    values (v_tenant, v_write_access, 'corrected a stuck despatch',
            'Cleared the stuck despatch flag under INC-4471, agreed on the call.');
    v_ok := true; v_msg := 'recorded';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a support write is recorded separately from the session',
    v_ok, v_msg;

  return query select 'and a write window is what makes it permissible',
    erp.support_access_is_live(v_tenant, true),
    'read-only remains the default; writing is a distinct grant';

  return query select 'the discipline assertion is satisfied by a write under a write window',
    erp.assert_support_discipline() is not null, 'no findings';

  -- ── §17.1 a screen, not a request ─────────────────────────────────────────
  -- Read as the ORGANISATION, with no platform identity in the session.

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- Three: the original read-only window, its extension, and the write window.
  select count(*) into v_count from erp.support_access_report();
  return query select 'the organisation reads its own access log unaided',
    v_count = 3,
    format('%s entries, read with no platform identity in the session', v_count);

  return query select 'and it says by whom, for how long and why',
    exists (select 1 from erp.support_access_report() sr
             where sr.staff_email = 'owner@zzsup.test'
               and sr.duration = interval '4 hours'
               and sr.reason like 'Customer raised INC-4471%'),
    '§17.1: by whom, when, for how long and why';

  -- ── §17.3 an incident is declared, not drifted into ───────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  -- NOT NULL does not stop an empty string, which is why the report checks the
  -- three roles as well as the columns declaring them. Read the report rather
  -- than the assertion here: the assertion raises, and what is being tested is
  -- that the finding appears.
  insert into erp_meta.incident (code, severity_code, title, commander, communications_owner, scribe)
  values ('zzinc-1', 'sev1', 'Despatch stopped', 'A. Commander', '', 'C. Scribe');

  return query select 'an incident must name all three roles',
    exists (select 1 from erp.support_discipline_report() d
             where d.reference = 'zzinc-1'
               and d.finding like 'an incident names no commander%'),
    'commander, communications owner and scribe, however small the team';

  delete from erp_meta.incident where code = 'zzinc-1';

  return query select 'and the finding goes when the incident is declared properly',
    not exists (select 1 from erp.support_discipline_report() d where d.reference = 'zzinc-1'),
    'an empty string is not a person, and NOT NULL alone would not have said so';

  insert into erp_meta.incident
    (code, severity_code, title, commander, communications_owner, scribe)
  values ('zzinc-2', 'sev1', 'Despatch stopped', 'A. Commander', 'B. Comms', 'C. Scribe')
  returning id into v_inc;

  begin
    update erp_meta.incident set contained_at = now() where id = v_inc;
    v_ok := false; v_msg := 'an incident was contained without being scoped';
  exception when check_violation then
    v_ok := true; v_msg := 'refused by constraint';
  end;
  return query select 'and cannot be contained before its scope is known', v_ok, v_msg;

  update erp_meta.incident
     set contained_at = now(), scope = 'One organisation, despatch only.',
         affects_all_tenants = false
   where id = v_inc;

  insert into erp_meta.incident_update (incident_id, body, posted_by, is_no_change)
  values (v_inc, 'Contained. Still investigating the cause; no change since the last update.',
          'B. Comms', true);

  return query select 'an update saying nothing has changed is a first-class update',
    (select u.is_no_change from erp_meta.incident_update u where u.incident_id = v_inc),
    '§17.3: silence is what erodes trust during an outage';

  -- §17.3: a resolved severity 1 needs a review.
  update erp_meta.incident set resolved_at = now() where id = v_inc;

  begin
    perform erp.assert_support_discipline();
    v_ok := false; v_msg := 'a resolved severity 1 with no review passed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SUPPORT_DISCIPLINE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a resolved severity 1 with no review is a finding', v_ok, v_msg;

  update erp_meta.incident
     set review_url = 'https://reviews.example/zzinc-2', review_completed_at = now()
   where id = v_inc;

  return query select 'and passes once the review is written',
    erp.assert_support_discipline() is not null,
    '§17.3: blameless, for every severity 1 and 2';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  -- §17.1's read-only default, tested last: erp.support_action is append-only,
  -- so a write recorded against the read-only window cannot be removed. It goes
  -- when the organisation does, three statements below.
  insert into erp.support_action
    (tenant_id, support_access_id, action, reason)
  values (v_tenant, v_access, 'changed something under a read-only window',
          'Deliberately recorded against the read-only access, to prove it is found.');

  begin
    perform erp.assert_support_discipline();
    v_ok := false; v_msg := 'a write under read-only access passed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SUPPORT_DISCIPLINE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a write under READ-ONLY access is a finding', v_ok, v_msg;

  delete from erp_meta.incident_update where incident_id = v_inc;
  delete from erp_meta.incident where code like 'zzinc-%';

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  -- The platform audit trail is append-only, and the one removal it permits is
  -- the erasure of a whole organisation, inside that organisation's own purge.
  -- So the suite's own rows go while the window is open, not after it shuts.
  delete from erp_meta.platform_audit where tenant_id = v_tenant;
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzsup.test';
  delete from auth.users where id in (ad, ow);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code like 'zzsup-%')
      and not exists (select 1 from erp_meta.incident i where i.code like 'zzinc-%')
      and erp.assert_support_discipline() is not null,
    'and the access log went with the organisation, being tenant-scoped';
end;
$function$

;

CREATE OR REPLACE FUNCTION erp_test.tenant_deletion_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  ra record; rb record; rc record; rd record; re record;
  ow uuid := gen_random_uuid();
  op uuid := gen_random_uuid();
  ad uuid := gen_random_uuid();
  v_ok boolean; v_msg text; res jsonb; v_audit bigint;
begin
  select * into ra from erp.provision_tenant(
    'zzpurge-a', 'Purge A', 'admin-a@zzpurge.test', 'Purge A Admin');
  select * into rb from erp.provision_tenant(
    'zzpurge-b', 'Purge B', 'admin-b@zzpurge.test', 'Purge B Admin');
  select * into rc from erp.provision_tenant(
    'zzpurge-c', 'Purge C', 'admin-c@zzpurge.test', 'Purge C Admin');
  select * into rd from erp.provision_tenant(
    'zzpurge-d', 'Purge D', 'admin-d@zzpurge.test', 'Purge D Admin');
  select * into re from erp.provision_tenant(
    'zzpurge-e', 'Purge E', 'admin-e@zzpurge.test', 'Purge E Admin');

  insert into auth.users (id, email) values
    (ow, 'owner@zzpurge.test'), (op, 'operator@zzpurge.test'),
    (ad, 'admin-b@zzpurge.test');

  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzpurge.test', ow, 'Purge Owner', 'owner'),
         ('operator@zzpurge.test', op, 'Purge Operator', 'operator');

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a', 'testing');
    v_ok := false; v_msg := 'an operator purged an organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an operator may not purge an organisation', v_ok, v_msg;

  begin
    perform public.erp_platform_purge_due_tenants(0);
    v_ok := false; v_msg := 'an operator ran the deletion sweep';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'nor run the sweep', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a', 'testing');
    v_ok := false; v_msg := 'an active organisation was purged in one step';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_TENANT_STILL_ACTIVE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and an active organisation is refused even to an owner',
    v_ok, v_msg;

  update erp.tenant set status = 'suspended'::erp.tenant_status
   where id = ra.tenant_id;

  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-WRONG', 'testing');
    v_ok := false; v_msg := 'a wrong confirmation code was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_VALIDATION%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'the organisation code must be typed exactly', v_ok, v_msg;

  begin
    perform public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a', '   ');
    v_ok := false; v_msg := 'a purge with no reason was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REASON_REQUIRED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and a reason is required', v_ok, v_msg;

  res := public.erp_platform_purge_tenant(ra.tenant_id, 'zzpurge-a',
                                          'suite: proving deletion deletes');

  return query select 'an owner purges a suspended organisation',
    (res ->> 'purged')::boolean, coalesce(res ->> 'code', '(no code returned)');

  return query select 'and the organisation is actually gone',
    not exists (select 1 from erp.tenant t where t.id = ra.tenant_id),
    'the whole point: before this migration nothing in the product removed a row';

  return query select 'and nothing tenant-scoped survives it',
    not exists (select 1 from erp.app_user u    where u.tenant_id = ra.tenant_id)
      and not exists (select 1 from erp.environment e where e.tenant_id = ra.tenant_id)
      and not exists (select 1 from erp.change_set c where c.tenant_id = ra.tenant_id)
      and not exists (select 1 from erp.role r       where r.tenant_id = ra.tenant_id),
    'app_user, environment, change_set and role all follow the organisation';

  select count(*) into v_audit from erp_meta.platform_audit a
   where a.tenant_id = ra.tenant_id and a.action = 'platform.tenant_purged';
  return query select 'while the audit record outlives it',
    v_audit = 1,
    'erp_meta.platform_audit carries no foreign key to erp.tenant precisely so '
    'that the record of a deletion is not deleted by it';

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(rb.admin_token);

  res := public.erp_request_tenant_deletion('zzpurge-b', 'suite: the request half');

  return query select 'an administrator''s request suspends rather than deletes',
    (select t.status::text from erp.tenant t where t.id = rb.tenant_id) = 'suspended'
      and exists (select 1 from erp.tenant t where t.id = rb.tenant_id),
    'the rows are still there, which is the honest outcome';

  return query select 'and it no longer promises a purge that never happens',
    (res ->> 'note') not like '%scheduled purge%',
    'the note said data "is removed by the scheduled purge"; no such purge '
    'existed, and an administrator reading that believed the organisation was on '
    'its way out';

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  res := public.erp_platform_purge_tenant(rb.tenant_id, 'zzpurge-b',
                                          'suite: finishing what the request started');

  return query select 'an owner finishes what the request started',
    (res ->> 'purged')::boolean
      and not exists (select 1 from erp.tenant t where t.id = rb.tenant_id),
    'request then purge is the two-step, and both halves now exist';

  update erp.tenant set status = 'suspended'::erp.tenant_status,
         deleted_at = now() - interval '14 days' where id = rc.tenant_id;
  update erp.tenant set status = 'suspended'::erp.tenant_status,
         deleted_at = now() - interval '1 hour'  where id = rd.tenant_id;
  update erp.tenant set status = 'suspended'::erp.tenant_status,
         suspended_at = now(), deleted_at = null where id = re.tenant_id;

  res := public.erp_platform_purge_due_tenants(7);

  return query select 'the sweep takes an organisation past its grace period',
    (res ->> 'purged')::integer = 1
      and not exists (select 1 from erp.tenant t where t.id = rc.tenant_id),
    format('purged %s', res ->> 'purged');

  return query select 'and leaves one still inside it',
    exists (select 1 from erp.tenant t where t.id = rd.tenant_id),
    'deleted an hour ago against a seven-day grace: the window is the whole '
    'reason a mistaken request can be caught';

  return query select 'a suspension that was never a deletion request is not swept',
    exists (select 1 from erp.tenant t where t.id = re.tenant_id),
    'suspension sets suspended_at and leaves deleted_at null; only a request '
    'to be deleted sets that, and only that is swept';

  return query select 'and the sweep records each purge without an actor',
    exists (select 1 from erp_meta.platform_audit a
             where a.tenant_id = rc.tenant_id
               and a.action = 'platform.tenant_purged'
               and a.actor_email = 'system'),
    'the platform acted on somebody else''s request; naming whoever triggered '
    'the sweep would be a worse record than naming nobody';

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(rd.tenant_id);
  delete from erp_meta.platform_audit a where a.tenant_id = rd.tenant_id;
  delete from erp.tenant where id = rd.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(re.tenant_id);
  delete from erp_meta.platform_audit a where a.tenant_id = re.tenant_id;
  delete from erp.tenant where id = re.tenant_id;
  perform erp.end_tenant_purge();
  -- The organisations the sweep took are already gone, but their audit rows are
  -- not: append-only permits a removal only inside that organisation's purge,
  -- so each one gets its window reopened for exactly that.
  declare ra record;
  begin
    for ra in select distinct a.tenant_id from erp_meta.platform_audit a
               where a.tenant_code like 'zzpurge-%' and a.tenant_id is not null loop
      perform erp.begin_tenant_purge(ra.tenant_id);
      delete from erp_meta.platform_audit a where a.tenant_id = ra.tenant_id;
      perform erp.end_tenant_purge();
    end loop;
  end;
  delete from erp_meta.platform_staff s where s.email like '%@zzpurge.test';
  delete from auth.users u where u.id in (ow, op, ad);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t
                 where t.code like 'zzpurge-%')
      and not exists (select 1 from erp_meta.platform_staff s
                       where s.email like '%@zzpurge.test')
      and not exists (select 1 from auth.users u where u.id in (ow, op, ad)),
    'five organisations, both staff rows and all three fabricated subjects';
end $function$

;
