-- ─────────────────────────────────────────────────────────────────────────────
-- The support session the organisation can see.
--
-- Found by the production-readiness pass, Phase 8, by entering one organisation
-- as platform staff and then reading that organisation's own records as the
-- organisation.
--
-- §17.1 is built and tested. erp.support_access records who entered, for how
-- long and why; erp.support_access_is_live() answers whether a window is open;
-- erp.support_action records what was changed under it; erp.assert_support_
-- discipline() finds a write made outside a write window; and the organisation
-- reads all of it unaided through erp.support_access_report(), which is what
-- /operations/continuity shows. erp_test.support_suite exercises every part.
--
-- None of it is reached by the door the console actually uses.
-- erp_platform_enter_tenant() creates a principal inside the customer's
-- organisation, grants it the administrator role, and records the fact in
-- erp_meta.platform_audit — a schema no tenant is granted. It writes nothing to
-- erp.support_access. Measured, with an operator holding administrator in the
-- organisation at that moment:
--
--   a platform operator holds administrator in northgate right now: true
--   erp.support_access_is_live(northgate)                        = false
--   rows on the organisation's own continuity screen             = 0
--   erp.assert_support_discipline()                              : no findings
--
-- So the affected organisation is shown an empty support-access log while
-- somebody is inside it with full administration rights; the discipline
-- assertion, which exists to find exactly this, sees no access and therefore no
-- writes to attribute to one. The record is not wrong — it does not exist. This
-- is the fault this codebase is built to refuse, in its quietest form: a screen
-- that reports an outcome ("nobody has been in here") the product never
-- established.
--
-- The repair puts the entry door through the model that was already there:
--
--   * entering records an erp.support_access row, so the session appears on the
--     organisation's own screen while it is happening, not afterwards;
--   * the reason must be a reason — the same twenty characters erp.grant_
--     support_access has always required, rather than merely non-empty, so the
--     two doors cannot disagree about what a reason is;
--   * leaving ends the window, so open and closed are facts rather than
--     labels. erp.support_access is append-only — a session that ended early
--     cannot be tidied into one that was granted for less — so ending is not
--     an edit to the row. A window is open while the principal it named is
--     still enabled, and leaving disables that principal; the row goes on
--     saying it was granted until four o'clock, which is true, and the screen
--     goes on saying who was in and why, which is the point;
--   * and erp.expire_support_access() makes the expiry real — it revokes the
--     administrator grant and disables the principal once the window has
--     passed, and runs on every platform housekeeping pass. Writing an
--     expires_at that nothing honours would be the same fault one level down.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The record can name the principal it created ─────────────────────────────
--
-- erp.support_access is append-only, so the principal cannot be written onto
-- the row afterwards. It is passed in.

-- The new argument is defaulted, so the six-argument function has to go rather
-- than stand beside it: two functions differing only in a trailing default make
-- every existing five-argument call ambiguous.
drop function if exists erp.grant_support_access(uuid, text, integer, boolean, text, uuid);

CREATE OR REPLACE FUNCTION erp.grant_support_access(p_tenant_id uuid, p_reason text, p_hours integer DEFAULT 4, p_write boolean DEFAULT false, p_request_reference text DEFAULT NULL::text, p_extension_of uuid DEFAULT NULL::uuid, p_app_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_staff  erp_meta.platform_staff;
  v_id     uuid;
  v_code   text;
  v_prior  erp.support_access%rowtype;
begin
  v_staff := erp_meta.require_platform('support');

  if p_hours is null or p_hours < 1 or p_hours > 168 then
    raise exception
      'ERPWARE_SUPPORT_WINDOW_INVALID: support access is granted in hours, from 1 to 168'
      using errcode = '22023',
            hint = '§17.1: access is time-bounded. A week is the ceiling, not a default.';
  end if;

  select t.code into v_code from erp.tenant t where t.id = p_tenant_id;
  if v_code is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  -- §17.1: "extension is a fresh act, recorded". The prior access must exist
  -- and belong to the same organisation; an extension of nothing is a grant
  -- wearing the word extension.
  if p_extension_of is not null then
    select * into v_prior from erp.support_access a
     where a.tenant_id = p_tenant_id and a.id = p_extension_of;
    if not found then
      raise exception
        'ERPWARE_NO_SUCH_ACCESS_TO_EXTEND: nothing here to extend'
        using errcode = '23503';
    end if;
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  insert into erp.support_access
    (tenant_id, staff_email, staff_role, reason, request_reference,
     is_write_access, expires_at, extension_of, app_user_id)
  values (p_tenant_id, v_staff.email, v_staff.staff_role, p_reason,
          p_request_reference, p_write, now() + make_interval(hours => p_hours),
          p_extension_of, p_app_user_id)
  returning id into v_id;

  perform erp_meta.platform_log(
    v_staff,
    case when p_extension_of is null then 'platform.support_access_granted'
         else 'platform.support_access_extended' end,
    p_tenant_id, v_code, p_reason,
    jsonb_build_object('hours', p_hours, 'write', p_write,
                       'access_id', v_id, 'extension_of', p_extension_of));

  return jsonb_build_object('access_id', v_id, 'expires_at', now() + make_interval(hours => p_hours),
                            'write', p_write, 'is_extension', p_extension_of is not null);
end;
$function$;

-- ── A window is open while the principal it named is still enabled ───────────
--
-- Leaving revokes the administrator grant and disables the principal, and the
-- sweep below does the same when nobody leaves. Neither can rewrite the access
-- row, and neither should: "granted until four o'clock" is what happened. What
-- the organisation needs to know is whether somebody is in there NOW, and that
-- is a fact about the principal, not about the clock.
--
-- A row naming no principal — erp.grant_support_access called on its own, which
-- is how §17.1 was exercised before there was a door — keeps the old meaning,
-- so nothing that passed before this reads differently after it.

CREATE OR REPLACE FUNCTION erp.support_access_is_live(p_tenant_id uuid, p_write boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from erp.support_access a
     where a.tenant_id = p_tenant_id
       and a.expires_at > now()
       and (not p_write or a.is_write_access)
       and (a.app_user_id is null
            or exists (select 1 from erp.app_user u
                        where u.tenant_id = a.tenant_id
                          and u.id = a.app_user_id
                          and u.status = 'active')))
$function$;

CREATE OR REPLACE FUNCTION erp.support_access_report()
 RETURNS TABLE(granted_at timestamp with time zone, expires_at timestamp with time zone, duration interval, staff_email text, staff_role text, reason text, request_reference text, write_access boolean, is_extension boolean, still_live boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select a.granted_at, a.expires_at, a.expires_at - a.granted_at,
         a.staff_email, a.staff_role, a.reason, a.request_reference,
         a.is_write_access, a.extension_of is not null,
         a.expires_at > now()
           and (a.app_user_id is null
                or exists (select 1 from erp.app_user u
                            where u.tenant_id = a.tenant_id
                              and u.id = a.app_user_id
                              and u.status = 'active'))
    from erp.support_access a
   where a.tenant_id = erp.require_tenant_id()
   order by a.granted_at desc
$function$;

-- ── The expiry, made real ────────────────────────────────────────────────────

create or replace function erp.expire_support_access(p_tenant_id uuid default null)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  a       record;
  v_gone  integer := 0;
  v_total integer := 0;
begin
  -- A support principal is the one erp_platform_enter_tenant created or
  -- adopted, named on the access row. Only those are touched: a customer's own
  -- administrator has no support_access row pointing at them.
  for a in
    select distinct sa.tenant_id, sa.app_user_id, sa.staff_email, sa.staff_role
      from erp.support_access sa
     where sa.app_user_id is not null
       and sa.expires_at <= now()
       and (p_tenant_id is null or sa.tenant_id = p_tenant_id)
       -- Not while any other window for the same principal is still open. An
       -- extension is a new row, and the old one expiring must not close it.
       and not exists (
         select 1 from erp.support_access live
          where live.tenant_id = sa.tenant_id
            and live.app_user_id = sa.app_user_id
            and live.expires_at > now())
       and exists (
         select 1 from erp.user_role ur
           join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
          where ur.tenant_id = sa.tenant_id
            and ur.app_user_id = sa.app_user_id
            and r.code = 'administrator')
  loop
    perform set_config('erp.job_tenant_id', a.tenant_id::text, true);

    delete from erp.user_role ur
     where ur.tenant_id = a.tenant_id
       and ur.app_user_id = a.app_user_id
       and ur.role_id in (select r.id from erp.role r
                           where r.tenant_id = a.tenant_id and r.code = 'administrator');
    get diagnostics v_gone = row_count;

    update erp.app_user set status = 'disabled'
     where tenant_id = a.tenant_id and id = a.app_user_id;

    insert into erp_meta.platform_audit
      (actor_email, actor_role, action, tenant_id, tenant_code, reason, detail)
    select a.staff_email, a.staff_role, 'platform.support_access_expired',
           a.tenant_id, t.code,
           'The support window closed; the grant it carried was revoked.',
           jsonb_build_object('grants_revoked', v_gone,
                              'app_user_id', a.app_user_id)
      from erp.tenant t where t.id = a.tenant_id;

    v_total := v_total + 1;
  end loop;

  perform set_config('erp.job_tenant_id', '', true);
  return v_total;
end;
$$;

revoke all on function erp.expire_support_access(uuid) from public, anon;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'expire_support_access',
  'Revokes an administrator grant inside a customer organisation when the '
  'support window that carried it has passed. It runs from the platform '
  'housekeeping pass, where there is no tenant context and no principal to '
  'act as, and it can only ever remove a grant an erp.support_access row '
  'named — never create one.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
revoke all on function erp.grant_support_access(uuid, text, integer, boolean, text, uuid, uuid) from public, anon;

comment on function erp.expire_support_access(uuid) is
  'Revokes the administrator grant a support session was given, once its '
  'window has passed. §17.1 bounds access in time; without this the bound is '
  'a number on a screen. Runs on every platform housekeeping pass, and is '
  'safe to call at any time — it acts only on principals named by an expired '
  'erp.support_access row with no later window still open.';

-- ── Entering records the session where the organisation can read it ──────────

CREATE OR REPLACE FUNCTION public.erp_platform_enter_tenant(p_tenant_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v        erp_meta.platform_staff;
  v_t      erp.tenant;
  v_user   uuid;
  v_owner  uuid;
  v_role   uuid;
  v_access jsonb;
begin
  v := erp_meta.require_platform('support');

  -- The same reason erp.grant_support_access has always required. It used to be
  -- merely non-empty here, which meant the door that actually grants access
  -- held a lower bar than the door that records it — and, once this function
  -- records the access, a one-word reason would have failed deep inside the
  -- insert instead of being refused by name.
  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception
      'ERPWARE_REASON_REQUIRED: entering a customer organisation needs a reason, '
      'not a word'
      using errcode = '22023',
      hint = '§17.1: say what you are looking at and for whom — the customer '
             'reads this on their own support-access screen. At least twenty '
             'characters.';
  end if;

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    -- No row bound to this account. Before making one, look for the email:
    -- erp.app_user is unique on (tenant_id, email), and the row most likely to
    -- be holding this staff member's address is the administrator the console
    -- invited when it created the organisation — very often typed in by the
    -- same person now trying to enter. Inserting over it raised 23505 on a
    -- unique index, which is the product refusing to work rather than the
    -- product telling somebody their name is taken.
    select u.id, u.auth_user_id into v_user, v_owner
      from erp.app_user u
     where u.tenant_id = p_tenant_id
       and lower(u.email) = lower(v.email)
     limit 1;

    if v_user is not null and v_owner is not null then
      -- Held by a different account. Adopting it would hand one person's
      -- identity inside a customer's organisation to another, which is a much
      -- worse thing than a refusal, so it is refused by name.
      raise exception
        'ERPWARE_EMAIL_TAKEN: a different account already holds % in this organisation', v.email
        using errcode = '22023';
    end if;

    if v_user is not null then
      update erp.app_user
         set auth_user_id = v.auth_user_id,
             status       = 'active'
       where id = v_user;
    else
      insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name,
                                email, user_locale)
      values (p_tenant_id, v.auth_user_id, 'person', 'active',
              v.display_name || ' (Clove ERP ' || v.staff_role || ')',
              v.email, 'en')
      returning id into v_user;
    end if;
  else
    update erp.app_user set status = 'active' where id = v_user;
  end if;

  select r.id into v_role from erp.role r
   where r.tenant_id = p_tenant_id and r.code = 'administrator' and r.status = 'active';

  if v_role is not null and not exists (
    select 1 from erp.user_role ur
     where ur.tenant_id = p_tenant_id and ur.app_user_id = v_user and ur.role_id = v_role)
  then
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (p_tenant_id, v_user, v_role,
            'Platform ' || v.staff_role || ' support access: ' || p_reason);
  end if;

  insert into erp_meta.principal_preference (auth_user_id, active_tenant_id)
  values (v.auth_user_id, p_tenant_id)
  on conflict (auth_user_id)
    do update set active_tenant_id = excluded.active_tenant_id, chosen_at = now();

  -- §17.1, and the point of this repair. The grant above gives administration
  -- rights inside somebody else's organisation; this is the row that says so on
  -- that organisation's own screen, while it is happening. The role granted is
  -- an administrator, so the window is a write window — recording it as
  -- read-only would put every change made during the session outside its
  -- access, which is the finding erp.assert_support_discipline() raises.
  v_access := erp.grant_support_access(p_tenant_id, p_reason, 4, true, null, null, v_user);

  perform erp_meta.platform_log(v, 'platform.tenant_entered', p_tenant_id,
                                v_t.code, p_reason,
                                jsonb_build_object('access_id', v_access ->> 'access_id',
                                                   'expires_at', v_access ->> 'expires_at'));

  return jsonb_build_object('tenant_id', p_tenant_id, 'code', v_t.code,
                            'principal_id', v_user,
                            'access_id', v_access ->> 'access_id',
                            'expires_at', v_access ->> 'expires_at');
end;
$function$;

-- ── Leaving closes the window it opened ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.erp_platform_leave_tenant(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v        erp_meta.platform_staff;
  v_user   uuid;
  v_gone   integer := 0;
  v_closed integer := 0;
begin
  v := erp_meta.require_platform('support');

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    raise exception 'ERPWARE_NOT_IN_TENANT: you hold no principal in this organisation'
      using errcode = '23503';
  end if;

  -- Counted before the principal is disabled, because disabling it is what
  -- closes the window: erp.support_access is append-only and an access that
  -- ended early is not an access that was granted for less.
  select count(*) into v_closed from erp.support_access sa
   where sa.tenant_id = p_tenant_id
     and sa.app_user_id = v_user
     and sa.expires_at > now();

  update erp.app_user set status = 'disabled'
   where tenant_id = p_tenant_id and id = v_user;

  -- The half that was missing. Without it the grant outlives every departure
  -- and the next entry is free.
  delete from erp.user_role ur
   where ur.tenant_id = p_tenant_id
     and ur.app_user_id = v_user
     and ur.role_id in (select r.id from erp.role r
                         where r.tenant_id = p_tenant_id and r.code = 'administrator');
  get diagnostics v_gone = row_count;

  delete from erp_meta.principal_preference
   where auth_user_id = v.auth_user_id and active_tenant_id = p_tenant_id;

  perform erp_meta.platform_log(v, 'platform.tenant_left', p_tenant_id, null,
                                'Support access ended.',
                                jsonb_build_object('grants_revoked', v_gone,
                                                   'windows_closed', v_closed));

  return jsonb_build_object('tenant_id', p_tenant_id, 'left', true,
                            'grants_revoked', v_gone,
                            'windows_closed', v_closed);
end;
$function$;

-- ── The housekeeping pass sweeps the windows that nobody closed ──────────────

CREATE OR REPLACE FUNCTION public.erp_platform_run_due_jobs(p_batch_size integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v erp_meta.platform_staff;
  t record;
  v_one jsonb;
  v_out jsonb := '[]'::jsonb;
  v_claimed integer := 0; v_ok integer := 0; v_failed integer := 0; v_worker integer := 0;
  v_expired integer := 0;
begin
  v := erp_meta.require_platform('operator');

  -- Before anything else: a support window that has passed is revoked. It is
  -- not a tenant's job — the grant belongs to platform staff — so it runs here
  -- rather than from erp.job, and it runs first so that a sweep is never
  -- skipped by a failure further down the loop.
  v_expired := erp.expire_support_access();

  for t in select id, code from erp.tenant where status = 'active' order by code loop
    -- The same transaction-local mechanism erp_platform_enter_tenant() uses:
    -- this runs as the owner, which erp.session_is_trusted() accepts, so the
    -- context is honoured and closes with the transaction whatever happens.
    perform set_config('erp.job_tenant_id', t.id::text, true);
    v_one := erp.run_due_jobs(p_batch_size);

    v_claimed := v_claimed + (v_one ->> 'claimed')::integer;
    v_ok      := v_ok      + (v_one ->> 'succeeded')::integer;
    v_failed  := v_failed  + (v_one ->> 'failed')::integer;
    v_worker  := v_worker  + (v_one ->> 'needs_worker')::integer;

    if (v_one ->> 'claimed')::integer > 0 then
      v_out := v_out || jsonb_build_array(
        jsonb_build_object('organisation', t.code) || v_one);
    end if;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);

  perform erp_meta.platform_log(v, 'platform.jobs_run', null, null, null,
    jsonb_build_object('claimed', v_claimed, 'succeeded', v_ok,
                       'failed', v_failed, 'needs_worker', v_worker,
                       'support_windows_expired', v_expired));

  return jsonb_build_object(
    'claimed', v_claimed, 'succeeded', v_ok, 'failed', v_failed,
    'needs_worker', v_worker, 'support_windows_expired', v_expired,
    'organisations', v_out);
end;
$function$;

select erp.assert_public_api_safe();

-- ── And the suite that entered on nineteen characters ────────────────────────
--
-- erp_test.superadmin_suite entered a customer organisation with the reason
-- 'suite: second visit'. Nineteen characters, one short of the twenty
-- erp.grant_support_access has always required — which is the point of aligning
-- the two doors rather than leaving them to disagree, and also the reason this
-- suite now has to say what it is doing. The rest of it is unchanged; it is
-- restated whole because a migration already on main cannot be edited.
create or replace function erp_test.superadmin_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  ow uuid := gen_random_uuid();   -- platform owner
  nb uuid := gen_random_uuid();   -- nobody
  r  record;
  v_ok boolean; v_msg text; res jsonb; n integer; v_grants integer;
begin
  insert into auth.users (id, email) values
    (ow, 'owner@zzsa.test'), (nb, 'nobody@zzsa.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzsa.test', ow, 'Superadmin Suite Owner', 'owner');

  -- ── A: the register is the allow-list ───────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', nb)::text, true);
  begin
    perform public.erp_platform_run_check('isolation');
    v_ok := false; v_msg := 'an account off the staff list ran a check';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_PLATFORM_STAFF%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'a caller who is not platform staff cannot run a check',
    v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  begin
    perform public.erp_platform_run_check('drop_everything');
    v_ok := false; v_msg := 'an unregistered name was executed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_DIAGNOSTIC%'; v_msg := left(sqlerrm, 58);
  end;
  -- The register is the allow-list, which is the whole safety argument for
  -- dispatching a function by name at all.
  return query select 'and a name that is not in the register is refused',
    v_ok, v_msg;

  return query select 'the register runs every assertion CI does, not nine of them',
    (select count(*) from erp_meta.diagnostic_check where kind = 'assertion') >= 24,
    format('%s registered', (select count(*) from erp_meta.diagnostic_check));

  -- An assertion nobody registered is the failure this exists to prevent.
  create function erp.assert_zz_unregistered() returns text
    language sql stable as $f$ select 'x' $f$;
  begin
    perform erp.assert_diagnostics_registered();
    v_ok := false; v_msg := 'an unregistered assertion passed unnoticed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DIAGNOSTICS_UNREGISTERED%'; v_msg := left(sqlerrm, 58);
  end;
  drop function erp.assert_zz_unregistered();
  return query select 'a new assertion that nobody registered is caught', v_ok, v_msg;

  -- And a register row naming something that is not there.
  insert into erp_meta.diagnostic_check
    (code, title, kind, scope, function_name, blurb)
  values ('zz_phantom', 'Phantom', 'assertion', 'platform',
          'assert_no_such_thing', 'Names a function that does not exist.');
  begin
    perform erp.assert_diagnostics_registered();
    v_ok := false; v_msg := 'a register naming a missing function passed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DIAGNOSTICS_UNREGISTERED%'; v_msg := left(sqlerrm, 58);
  end;
  delete from erp_meta.diagnostic_check where code = 'zz_phantom';
  -- A register that reports green over nothing is worse than no register.
  return query select 'and a register row naming a function that is gone',
    v_ok, v_msg;

  -- The half that was missing: a failure that names what failed.
  begin
    alter table erp.department disable row level security;
    res := erp.run_diagnostic('isolation');
    alter table erp.department enable row level security;
  exception when others then
    alter table erp.department enable row level security;
    raise;
  end;
  return query select 'a failing check returns the findings, not just false',
    (res ->> 'ok')::boolean is false
      and jsonb_array_length(res -> 'findings') > 0
      and res -> 'findings' -> 0 ->> 'table_name' = 'department',
    format('%s finding(s), first names %s', jsonb_array_length(res -> 'findings'),
           res -> 'findings' -> 0 ->> 'table_name');

  return query select 'and isolation is intact again afterwards',
    (erp.run_diagnostic('isolation') ->> 'ok')::boolean,
    'a suite that leaves row security off would fail every assertion after it';

  -- ── B: a job surface that can hold a job ────────────────────────────────

  select * into r from erp.provision_tenant('zzsa','Superadmin Suite','a@zzsa.test','Suite Admin');
  perform set_config('erp.job_tenant_id', r.tenant_id::text, true);

  return query select 'every handler the database claims to run exists',
    erp.assert_job_handlers_resolvable() like 'job handlers:%',
    erp.assert_job_handlers_resolvable();

  perform erp.upsert_job('zzreclaim', 'Reclaim timed-out runs',
                         'platform.reclaim_timed_out_runs', 'interval', 60);
  return query select 'a job can be created at all — nothing could before',
    (select count(*) from erp.job j where j.tenant_id = r.tenant_id) = 1,
    'erp.job had no insert anywhere in the product, so /operations/jobs was '
    'empty by construction and its Trigger action could only fail';

  return query select 'and the schedule trigger set its next run',
    (select j.next_run_at is not null from erp.job j
      where j.tenant_id = r.tenant_id and j.code = 'zzreclaim'),
    'computed by erp.maintain_job_schedule(), not duplicated by the door';

  begin
    perform erp.upsert_job('zzbad', 'Bad', 'platform.no_such_handler', 'interval', 60);
    v_ok := false; v_msg := 'a job named a handler nothing implements';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_JOB_HANDLER%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'a job naming a handler nothing implements is refused',
    v_ok, v_msg;

  update erp.job set next_run_at = now() - interval '1 minute'
   where tenant_id = r.tenant_id and code = 'zzreclaim';
  res := erp.run_due_jobs();
  return query select 'a due job runs and its run is recorded',
    (res ->> 'claimed')::integer = 1 and (res ->> 'succeeded')::integer = 1
      and (select count(*) from erp.job_run jr where jr.tenant_id = r.tenant_id) = 1,
    format('claimed %s, succeeded %s', res ->> 'claimed', res ->> 'succeeded');

  -- The honesty case. A handler that needs an outbound call must be refused by
  -- name; counting it as done would make the report a lie.
  update erp_ref.job_handler set sql_function = null
   where code = 'platform.reclaim_timed_out_runs';
  perform erp.upsert_job('zzworker', 'Needs the worker',
                         'platform.reclaim_timed_out_runs', 'interval', 60);
  update erp.job set next_run_at = now() - interval '1 minute'
   where tenant_id = r.tenant_id and code = 'zzworker';
  res := erp.run_due_jobs();
  update erp_ref.job_handler set sql_function = 'reclaim_timed_out_runs'
   where code = 'platform.reclaim_timed_out_runs';
  return query select 'a handler the database cannot run is refused by name',
    (res ->> 'needs_worker')::integer >= 1 and (res ->> 'succeeded')::integer = 0,
    'skipping it silently would report a clean pass over work nobody did';

  -- ── C: leaving actually leaves ──────────────────────────────────────────

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform public.erp_platform_enter_tenant(r.tenant_id, 'suite: investigating');

  select count(*) into v_grants
    from erp.user_role ur
    join erp.role ro on ro.id = ur.role_id
    join erp.app_user u on u.id = ur.app_user_id
   where ur.tenant_id = r.tenant_id and u.auth_user_id = ow
     and ro.code = 'administrator';
  return query select 'entering an organisation grants the administrator role',
    v_grants = 1, 'a real grant on a real principal, not an impersonation';

  res := public.erp_platform_leave_tenant(r.tenant_id);
  select count(*) into n
    from erp.user_role ur
    join erp.role ro on ro.id = ur.role_id
    join erp.app_user u on u.id = ur.app_user_id
   where ur.tenant_id = r.tenant_id and u.auth_user_id = ow
     and ro.code = 'administrator';
  return query select 'and leaving revokes it',
    n = 0 and (res ->> 'grants_revoked')::integer = 1,
    'it used to leave the grant in place for ever, dormant, for the next entry '
    'to find already there — and nothing in the product could call leave at all';

  perform public.erp_platform_enter_tenant(r.tenant_id, 'suite: entering a second time to check the principal is reused');
  select count(*) into n
    from erp.user_role ur
    join erp.role ro on ro.id = ur.role_id
    join erp.app_user u on u.id = ur.app_user_id
   where ur.tenant_id = r.tenant_id and u.auth_user_id = ow
     and ro.code = 'administrator';
  return query select 'so re-entering has to grant it again, and is recorded again',
    n = 1
      and (select count(*) from erp_meta.platform_audit
            where action = 'platform.tenant_entered' and tenant_id = r.tenant_id) = 2,
    'one audit line per period of access rather than one for the first ever';

  return query select 'and the console can say which organisations you are in',
    exists (select 1 from jsonb_array_elements(public.erp_platform_my_tenancies()) t
             where t.value ->> 'code' = 'zzsa'
               and (t.value ->> 'holds_administrator')::boolean),
    'nothing showed this, which is why nobody ever left';

  return query select 'and what each one is missing, without entering it',
    (select (t.value ->> 'accounts')::integer = 0
       from jsonb_array_elements(public.erp_platform_tenant_configuration()) t
      where t.value ->> 'code' = 'zzsa'),
    'this is the read that answers "has this organisation got master data?"';

  -- ── D: deployment state ─────────────────────────────────────────────────

  return query select 'deployment state reports the registers it is built on',
    (public.erp_platform_deployment_state() -> 'registers' ->> 'diagnostic_check')::integer > 0
      and (public.erp_platform_deployment_state() -> 'counts' ->> 'public_doors')::integer > 250,
    format('%s public doors, %s registered checks',
           public.erp_platform_deployment_state() -> 'counts' ->> 'public_doors',
           public.erp_platform_deployment_state() -> 'registers' ->> 'diagnostic_check');

  perform set_config('request.jwt.claims', json_build_object('sub', nb)::text, true);
  begin
    perform public.erp_platform_deployment_state();
    v_ok := false; v_msg := 'anybody signed in could read the deployment state';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_PLATFORM_STAFF%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'and is not readable by an account off the staff list',
    v_ok, v_msg;

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email = 'owner@zzsa.test';
  delete from auth.users where id in (ow, nb);

  return query select 'and the suite removes the organisation and the staff row',
    not exists (select 1 from erp_meta.platform_staff where email = 'owner@zzsa.test')
      and not exists (select 1 from erp.job j where j.tenant_id = r.tenant_id),
    'a staff row left behind changes what erp_platform_claim_ownership() does next';
end $$;
