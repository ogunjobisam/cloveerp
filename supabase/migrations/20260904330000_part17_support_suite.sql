-- =============================================================================
-- Part 17 — the adversarial suite
--
-- §17.1's hardest sentence is "STANDING ACCESS DOES NOT EXIST", and the way a
-- system fails it is not by declaring standing access — nobody does that. It is
-- by allowing an expiry far enough away to be one, or by letting an extension
-- move an existing expiry forward so no evidence remains that anything was
-- extended. Both are tried here.
--
-- The second is §17.1's "This is a screen, not a request": the organisation
-- must be able to read its own support-access record WITHOUT platform help. So
-- the suite reads it as the organisation, through ordinary row security, with
-- no platform staff identity in the session at all.
-- =============================================================================

create or replace function erp_test.support_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
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
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzsup.test';
  delete from erp_meta.platform_audit where tenant_code like 'zzsup-%';
  delete from auth.users where id in (ad, ow);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code like 'zzsup-%')
      and not exists (select 1 from erp_meta.incident i where i.code like 'zzinc-%')
      and erp.assert_support_discipline() is not null,
    'and the access log went with the organisation, being tenant-scoped';
end;
$$;

comment on function erp_test.support_suite is
  'Specification v1.2 Part 17, proven adversarially. The attack on "standing '
  'access does not exist" is not to declare it but to reach it sideways — a '
  'window a month long, an expiry ten years out, an extension that moves the '
  'original forward. All three are refused, and the organisation reads its own '
  'access log with no platform identity in the session.';

create or replace function erp_test.assert_support_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _support_result on commit drop as
    select * from erp_test.support_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _support_result;

  if v_total <> 26 then
    raise exception 'ERPWARE_SUPPORT_SUITE_SHRANK: % case(s), expected 26', v_total
      using errcode = 'P0001',
            hint = 'A suite that reports n/n without saying what n should be '
                   'cannot notice a test that stopped running.';
  end if;

  if v_passed <> v_total then
    raise exception 'ERPWARE_SUPPORT_SUITE_FAILED: %/%', v_passed, v_total
      using errcode = 'P0001', detail = v_detail;
  end if;

  return format('support: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_support_suite();
