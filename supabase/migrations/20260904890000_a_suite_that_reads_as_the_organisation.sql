-- ─────────────────────────────────────────────────────────────────────────────
-- A suite that reads as the organisation.
--
-- erp_test.support_entry_suite already enters through the console's door — it
-- was written for a collision between a staff member's address and the invited
-- administrator's. It checks that entering works. This one checks what entering
-- LEAVES BEHIND, which is a different question and the one that was not asked.
--
-- erp_test.support_suite covers §17.1 thoroughly, and passed throughout the
-- period in which entering an organisation recorded nothing the organisation
-- could read. It passed because it calls erp.grant_support_access() directly —
-- the function that keeps the record — and never calls the door the console
-- actually uses, erp_platform_enter_tenant(), which did not.
--
-- That is the shape of the gap: a well-tested model, and a path into the
-- product that goes round it. So this suite starts from the door, not from the
-- model, and asks the questions the affected organisation would ask.
--
--   Somebody has administration rights in my organisation. Can I see that?
--   For how long do they have them? Does that end?
--   When they leave, does my screen say so?
--   And if they never leave, does anything take the rights away?
--
-- Every case reads as the organisation where it can, with no platform identity
-- in the session, because a record only the platform can read is not a record
-- the organisation has.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.support_visibility_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  r         record;
  v_tenant  uuid;
  v_admin   uuid := gen_random_uuid();
  v_staff   uuid := gen_random_uuid();
  v_res     jsonb;
  v_user    uuid;
  v_access  uuid;
  v_lapsed  uuid;
  v_ok      boolean;
  v_msg     text;
  v_seen    int;
  v_cases   int := 0;
  c_reason  constant text :=
    'Customer raised INC-9002: goods receipts are not posting to the ledger.';
begin
  select * into r from erp.provision_tenant(
    'zzvis-suite', 'Entry Suite', 'admin@zzvis-suite.test', 'Entry Suite Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email)
  values (v_admin, 'admin@zzvis-suite.test'), (v_staff, 'staff@zzvis-suite.test');

  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('staff@zzvis-suite.test', v_staff, 'Entry Suite Operator', 'owner');

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);

  -- ── The reason both doors ask for is the same reason ──────────────────────

  v_cases := v_cases + 1;
  begin
    perform public.erp_platform_enter_tenant(v_tenant, 'looking');
    v_ok := false; v_msg := 'a one-word reason let somebody into a customer organisation';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REASON_REQUIRED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'entering on a one-word reason is refused'::text, v_ok, v_msg;

  -- ── Entering ──────────────────────────────────────────────────────────────

  v_res    := public.erp_platform_enter_tenant(v_tenant, c_reason);
  v_user   := (v_res ->> 'principal_id')::uuid;
  v_access := (v_res ->> 'access_id')::uuid;

  v_cases := v_cases + 1;
  return query select 'entering hands back the window it opened'::text,
    v_access is not null and (v_res ->> 'expires_at') is not null,
    coalesce(format('access %s until %s', v_access, v_res ->> 'expires_at'),
             'no access recorded');

  v_cases := v_cases + 1;
  return query select 'and the principal it created holds administrator'::text,
    exists (select 1 from erp.user_role ur
              join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
             where ur.tenant_id = v_tenant and ur.app_user_id = v_user
               and ro.code = 'administrator'),
    'which is what makes the record below necessary';

  v_cases := v_cases + 1;
  return query select 'the window is live, and it is a write window'::text,
    erp.support_access_is_live(v_tenant, true),
    'an administrator grant recorded as read-only would put every change made '
    'during the session outside its access';

  -- ── What the ORGANISATION sees, with no platform identity in the session ──

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cases := v_cases + 1;
  select count(*) into v_seen from erp.support_access_report();
  return query select 'the organisation can see somebody is in its data'::text,
    v_seen = 1,
    format('%s entry on the organisation''s own screen, read with no platform '
           'identity in the session', v_seen);

  v_cases := v_cases + 1;
  return query select 'and it says by whom, until when and why'::text,
    exists (select 1 from erp.support_access_report() sr
             where sr.staff_email = 'staff@zzvis-suite.test'
               and sr.reason like 'Customer raised INC-9002%'
               and sr.still_live),
    '§17.1: by whom, when, for how long and why — while it is happening';

  -- ── Leaving ───────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  v_res := public.erp_platform_leave_tenant(v_tenant);

  v_cases := v_cases + 1;
  return query select 'leaving revokes the grant and closes the window'::text,
    (v_res ->> 'grants_revoked')::int = 1 and (v_res ->> 'windows_closed')::int = 1,
    format('%s grant(s) revoked, %s window(s) closed',
           v_res ->> 'grants_revoked', v_res ->> 'windows_closed');

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  v_cases := v_cases + 1;
  return query select 'and the organisation''s screen says it ended'::text,
    not erp.support_access_is_live(v_tenant)
      and exists (select 1 from erp.support_access_report() sr where not sr.still_live),
    'the entry stays; what changes is that it is no longer open';

  -- ── The session nobody closed ─────────────────────────────────────────────
  -- A support operator who enters and simply stops working is the case the
  -- expiry exists for. It is built directly rather than through the door: the
  -- door always grants four hours and erp.support_access is append-only, so a
  -- window that has run out cannot be produced by entering and waiting. What
  -- the sweep reads is exactly this — a principal holding administrator under
  -- an access whose window has passed.

  insert into erp.app_user (tenant_id, kind, status, display_name, email, user_locale)
  values (v_tenant, 'person', 'active', 'Lapsed Operator (Clove ERP owner)',
          'lapsed@zzvis-suite.test', 'en')
  returning id into v_lapsed;

  insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
  select v_tenant, v_lapsed, ro.id, 'Platform owner support access: ' || c_reason
    from erp.role ro
   where ro.tenant_id = v_tenant and ro.code = 'administrator' and ro.status = 'active';

  insert into erp.support_access
    (tenant_id, staff_email, staff_role, reason, is_write_access,
     granted_at, expires_at, app_user_id)
  values (v_tenant, 'staff@zzvis-suite.test', 'owner',
          c_reason || ' The visit nobody closed.', true,
          now() - interval '5 hours', now() - interval '1 hour', v_lapsed);

  v_cases := v_cases + 1;
  return query select 'an expired window still leaves the grant standing'::text,
    exists (select 1 from erp.user_role ur
              join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
             where ur.tenant_id = v_tenant and ur.app_user_id = v_lapsed
               and ro.code = 'administrator'),
    'which is why an expiry nothing acts on is a number, not a bound';

  v_cases := v_cases + 1;
  return query select 'while the organisation''s screen already reads closed'::text,
    not erp.support_access_is_live(v_tenant),
    'which is the danger exactly: the window says the visit is over and the '
    'administration rights it carried are still there';

  v_cases := v_cases + 1;
  return query select 'the sweep revokes it'::text,
    erp.expire_support_access(v_tenant) = 1,
    'erp.expire_support_access(), run on every platform housekeeping pass';

  v_cases := v_cases + 1;
  return query select 'and the rights are actually gone'::text,
    not exists (select 1 from erp.user_role ur
                  join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
                 where ur.tenant_id = v_tenant and ur.app_user_id = v_lapsed
                   and ro.code = 'administrator')
      and (select u.status from erp.app_user u
            where u.tenant_id = v_tenant and u.id = v_lapsed) = 'disabled',
    'the grant removed and the principal disabled, as leaving would have done';

  -- ── A session in progress is left alone ───────────────────────────────────

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);
  perform public.erp_platform_enter_tenant(v_tenant, c_reason || ' Second visit.');

  v_cases := v_cases + 1;
  return query select 'a still-open window is not swept'::text,
    erp.expire_support_access(v_tenant) = 0
      and exists (select 1 from erp.user_role ur
                    join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
                   where ur.tenant_id = v_tenant and ur.app_user_id = v_user
                     and ro.code = 'administrator'),
    'the sweep acts on windows that have passed, not on the session in progress';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp_meta.platform_audit where tenant_id = v_tenant;
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzvis-suite.test';
  delete from erp_meta.principal_preference where auth_user_id in (v_admin, v_staff);
  delete from auth.users where id in (v_admin, v_staff);

  v_cases := v_cases + 1;
  return query select 'the suite leaves nothing behind'::text,
    not exists (select 1 from erp.tenant t where t.code = 'zzvis-suite')
      and not exists (select 1 from erp_meta.platform_staff s
                       where s.email like '%@zzvis-suite.test'),
    'and the access log went with the organisation, being tenant-scoped';

  if v_cases <> 14 then
    raise exception 'ERPWARE_SUITE_SHRANK: support_visibility_suite ran % cases, expected 14', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.support_visibility_suite() from public, anon;

create or replace function erp_test.assert_support_visibility_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _se on commit drop as
    select * from erp_test.support_visibility_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail from _se;
  if v_fail > 0 then
    raise exception E'ERPWARE_SUPPORT_VISIBILITY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001',
      hint = 'Platform staff entered a customer organisation without the '
             'organisation being able to see it, or a support window expired '
             'without the rights it carried going with it.';
  end if;
  return format('support visibility: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_support_visibility_suite() from public, anon;
