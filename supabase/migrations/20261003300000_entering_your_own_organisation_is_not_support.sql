-- ═════════════════════════════════════════════════════════════════════════════
-- Entering your own organisation is not support
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Found on 30 September in production. The platform owner onboarded their own
-- company from the console with their own address as its first administrator,
-- then pressed Enter on it. erp_platform_enter_tenant looked for a principal
-- holding their email, found the organisation's real administrator, adopted
-- it, and opened a four-hour support window on it. When the window lapsed,
-- erp.expire_support_access() revoked every administrator grant the principal
-- held — the real one included, because it matched grants by role, not by
-- what granted them — and disabled the principal. From then on the
-- organisation had no working administrator, and every Enter gave four hours
-- back as support and took them away again. Five windows in fifteen days.
--
-- Three rules, and a repair:
--
--   1. A member is not a visitor. A principal holding any grant that support
--      access did not give (erp.holds_member_grant) is a member. Enter, for a
--      member, binds the principal if it was waiting for them and switches to
--      the organisation: no window, no support grant, nothing to expire. An
--      invited member is bound and made active, as claiming the invitation
--      would. A member the organisation has suspended or disabled is refused —
--      staff do not re-enable themselves somewhere that disabled them.
--   2. Expiry and Leave take away only what a window gave: grants whose reason
--      is "Platform … support access: …". A principal is disabled only when no
--      member grant remains.
--   3. A lapsed window closes a sign-in only while it holds no member grant
--      (erp.support_window_closed). Support windows are append-only, so the
--      windows once opened on a member's principal stay on record; this is
--      what stops them from counting against it.
--
--   Repair: erp.restore_members_taken_by_support() re-enables an organisation's
--   onboarding administrator whose principal a support window adopted, and
--   restores the administrator grant expiry took. It recognises the case by
--   its shape — a principal the enter door did not create, holding the
--   address the organisation was onboarded for, with no administrator grant —
--   not by anybody's name. On the day it was written it matched one principal.

set lock_timeout = '30s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. What a member is
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.holds_member_grant(p_tenant_id uuid, p_app_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from erp.user_role ur
     where ur.tenant_id = p_tenant_id
       and ur.app_user_id = p_app_user_id
       and (ur.valid_to is null or ur.valid_to > now())
       and coalesce(ur.grant_reason, '') not like 'Platform % support access:%')
$$;

revoke all on function erp.holds_member_grant(uuid, uuid) from public, anon;

comment on function erp.holds_member_grant(uuid, uuid) is
  'Whether a principal holds any current grant that support access did not give: '
  'whether it is a member rather than a visitor (20261003300000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. A lapsed window closes only a visitor
-- ─────────────────────────────────────────────────────────────────────────────

-- Called from erp.principal_context() on every request, so it stays cheap: the
-- member check runs only for a principal that has a window, and is one probe
-- of user_role_tenant_id_app_user_id_idx.
create or replace function erp.support_window_closed(p_tenant_id uuid, p_app_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(max(sa.expires_at) <= now(), false)
         and not erp.holds_member_grant(p_tenant_id, p_app_user_id)
    from erp.support_access sa
   where sa.tenant_id = p_tenant_id
     and sa.app_user_id = p_app_user_id
$$;

comment on function erp.support_window_closed(uuid, uuid) is
  'Whether the support windows opened on a principal have all lapsed and it holds '
  'no member grant; a member''s own sign-in is never closed by a window (20261003300000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Expiry takes away only what the window gave
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.expire_support_access(p_tenant_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  a        record;
  v_gone   integer := 0;
  v_total  integer := 0;
  v_member boolean;
begin
  for a in
    select distinct sa.tenant_id, sa.app_user_id, sa.staff_email, sa.staff_role
      from erp.support_access sa
     where sa.app_user_id is not null
       and sa.expires_at <= now()
       and (p_tenant_id is null or sa.tenant_id = p_tenant_id)
       and not exists (
         select 1 from erp.support_access live
          where live.tenant_id = sa.tenant_id
            and live.app_user_id = sa.app_user_id
            and live.expires_at > now())
       and exists (
         select 1 from erp.user_role ur
          where ur.tenant_id = sa.tenant_id
            and ur.app_user_id = sa.app_user_id
            and ur.grant_reason like 'Platform % support access:%')
  loop
    perform erp_meta.act_in_tenant(a.tenant_id);

    delete from erp.user_role ur
     where ur.tenant_id = a.tenant_id
       and ur.app_user_id = a.app_user_id
       and ur.grant_reason like 'Platform % support access:%';
    get diagnostics v_gone = row_count;

    v_member := erp.holds_member_grant(a.tenant_id, a.app_user_id);
    if not v_member then
      update erp.app_user set status = 'disabled'
       where tenant_id = a.tenant_id and id = a.app_user_id;
    end if;

    insert into erp_meta.platform_audit
      (actor_email, actor_role, action, tenant_id, tenant_code, reason, detail)
    select a.staff_email, a.staff_role, 'platform.support_access_expired',
           a.tenant_id, t.code,
           case when v_member
                then 'The support window closed; the grant it carried was revoked, and the member''s own access was left as it was.'
                else 'The support window closed; the grant it carried was revoked.' end,
           jsonb_build_object('grants_revoked', v_gone,
                              'app_user_id', a.app_user_id,
                              'still_member', v_member)
      from erp.tenant t where t.id = a.tenant_id;

    v_total := v_total + 1;
  end loop;

  perform erp_meta.stop_acting_in_tenant();
  return v_total;
end;
$$;

comment on function erp.expire_support_access(uuid) is
  'Revokes the grants a lapsed support window gave, and disables the principal only '
  'when no member grant remains (20261003300000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Enter, for a member, is a switch
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_enter_tenant(p_tenant_id uuid, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v        erp_meta.platform_staff;
  v_t      erp.tenant;
  v_user   uuid;
  v_owner  uuid;
  v_status erp.principal_status;
  v_role   uuid;
  v_access jsonb;
begin
  v := erp_meta.require_platform('support');

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception
      'CLOVEERP_REASON_REQUIRED: entering a customer organisation needs a reason, '
      'not a word'
      using errcode = '22023',
      hint = '§17.1: say what you are looking at and for whom — the customer '
             'reads this on their own support-access screen. At least twenty '
             'characters.';
  end if;

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'CLOVEERP_UNKNOWN_TENANT: no organisation has that id'
      using errcode = '23503',
            hint = 'Choose the organisation from the console''s list.';
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id, u.status into v_user, v_status from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    select u.id, u.auth_user_id, u.status into v_user, v_owner, v_status
      from erp.app_user u
     where u.tenant_id = p_tenant_id
       and lower(u.email) = lower(v.email)
     limit 1;

    if v_user is not null and v_owner is not null then
      raise exception
        'CLOVEERP_EMAIL_TAKEN: a different account already holds % in this organisation', v.email
        using errcode = '22023',
              hint = 'Sign in with the account that holds that address, or ask the organisation''s administrator.';
    end if;
  end if;

  -- A member: the organisation's own principal for this person, which support
  -- has no business turning into a visitor. Bound if it was waiting for them,
  -- chosen, and nothing else.
  if v_user is not null and erp.holds_member_grant(p_tenant_id, v_user) then
    if v_status not in ('active'::erp.principal_status, 'invited'::erp.principal_status) then
      raise exception
        'CLOVEERP_MEMBER_DISABLED: you are a member of % and the organisation has disabled you', v_t.name
        using errcode = '42501',
              hint = 'Ask one of the organisation''s administrators to enable you again. Entering as support would not be you.';
    end if;

    update erp.app_user
       set auth_user_id = v.auth_user_id,
           status       = 'active'
     where id = v_user
       and (auth_user_id is null or status = 'invited'::erp.principal_status);

    insert into erp_meta.principal_preference (auth_user_id, active_tenant_id)
    values (v.auth_user_id, p_tenant_id)
    on conflict (auth_user_id)
      do update set active_tenant_id = excluded.active_tenant_id, chosen_at = now();

    perform erp_meta.platform_log(v, 'platform.tenant_entered_as_member', p_tenant_id,
                                  v_t.code, p_reason,
                                  jsonb_build_object('principal_id', v_user));

    return jsonb_build_object('tenant_id', p_tenant_id, 'code', v_t.code,
                              'principal_id', v_user, 'as_member', true,
                              'access_id', null, 'expires_at', null);
  end if;

  -- A visitor: the support window, as before.
  if v_user is null then
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name,
                              email, user_locale)
    values (p_tenant_id, v.auth_user_id, 'person', 'active',
            v.display_name || ' (Clove ERP ' || v.staff_role || ')',
            v.email, 'en')
    returning id into v_user;
  else
    update erp.app_user
       set auth_user_id = v.auth_user_id,
           status       = 'active'
     where id = v_user;
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

  v_access := erp.grant_support_access(p_tenant_id, p_reason, 4, true, null, null, v_user);

  perform erp.append_event(
    'support.access_granted', 'support_access',
    (v_access ->> 'access_id')::uuid,
    jsonb_build_object('staff_email', v.email, 'staff_role', v.staff_role,
                       'reason', p_reason,
                       'expires_at', v_access ->> 'expires_at'));

  perform erp_meta.platform_log(v, 'platform.tenant_entered', p_tenant_id,
                                v_t.code, p_reason,
                                jsonb_build_object('access_id', v_access ->> 'access_id',
                                                   'expires_at', v_access ->> 'expires_at'));

  return jsonb_build_object('tenant_id', p_tenant_id, 'code', v_t.code,
                            'principal_id', v_user, 'as_member', false,
                            'access_id', v_access ->> 'access_id',
                            'expires_at', v_access ->> 'expires_at');
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Leave ends support, not membership
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_leave_tenant(p_tenant_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v        erp_meta.platform_staff;
  v_user   uuid;
  v_gone   integer := 0;
  v_closed integer := 0;
  v_member boolean;
begin
  v := erp_meta.require_platform('support');

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    raise exception 'CLOVEERP_NOT_IN_TENANT: you hold no principal in this organisation'
      using errcode = '23503',
            hint = 'Only an organisation you entered from the console can be left.';
  end if;

  select count(*) into v_closed from erp.support_access sa
   where sa.tenant_id = p_tenant_id
     and sa.app_user_id = v_user
     and sa.expires_at > now();

  delete from erp.user_role ur
   where ur.tenant_id = p_tenant_id
     and ur.app_user_id = v_user
     and ur.grant_reason like 'Platform % support access:%';
  get diagnostics v_gone = row_count;

  v_member := erp.holds_member_grant(p_tenant_id, v_user);
  if not v_member then
    update erp.app_user set status = 'disabled'
     where tenant_id = p_tenant_id and id = v_user;

    delete from erp_meta.principal_preference
     where auth_user_id = v.auth_user_id and active_tenant_id = p_tenant_id;
  end if;

  perform erp_meta.platform_log(v, 'platform.tenant_left', p_tenant_id, null,
                                case when v_member
                                     then 'Support access ended; your membership is unchanged.'
                                     else 'Support access ended.' end,
                                jsonb_build_object('grants_revoked', v_gone,
                                                   'windows_closed', v_closed,
                                                   'still_member', v_member));

  return jsonb_build_object('tenant_id', p_tenant_id, 'left', not v_member,
                            'still_member', v_member,
                            'grants_revoked', v_gone,
                            'windows_closed', v_closed);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. The console says which organisations you belong to
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_my_tenancies()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'tenant_id', t.id, 'code', t.code, 'name', t.name,
             'status', t.status::text,
             'principal_status', u.status::text,
             'is_active', u.status = 'active',
             'is_member', erp.holds_member_grant(t.id, u.id),
             'holds_administrator', exists (
               select 1 from erp.user_role ur
                 join erp.role r on r.id = ur.role_id
                where ur.tenant_id = t.id and ur.app_user_id = u.id
                  and r.code = 'administrator'),
             'entered_at', u.created_at,
             'is_current', exists (
               select 1 from erp_meta.principal_preference pp
                where pp.auth_user_id = v.auth_user_id
                  and pp.active_tenant_id = t.id))
           order by t.code)
      from erp.app_user u
      join erp.tenant t on t.id = u.tenant_id
     where u.auth_user_id = v.auth_user_id), '[]'::jsonb);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. The repair
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.restore_members_taken_by_support(p_tenant_id uuid default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  a       record;
  v_role  uuid;
  v_total integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not restore principals', current_user
      using errcode = '42501',
            hint = 'This runs as the database owner, from a migration; nobody signed in restores another person''s access.';
  end if;

  -- The onboarding administrator, adopted by a support window: not made by the
  -- enter door (which creates its principal in the transaction that opens its
  -- first window, so the two share a timestamp), holding the address the
  -- organisation was onboarded for, and holding no administrator grant now.
  for a in
    select u.tenant_id, u.id as app_user_id, u.email, u.status::text as status_before,
           t.code as tenant_code, min(sa.granted_at) as first_window
      from erp.support_access sa
      join erp.app_user u on u.tenant_id = sa.tenant_id and u.id = sa.app_user_id
      join erp.tenant t on t.id = sa.tenant_id
     where (p_tenant_id is null or sa.tenant_id = p_tenant_id)
       and t.deleted_at is null
       and exists (select 1 from erp_meta.platform_audit pa
                    where pa.tenant_id = u.tenant_id
                      and pa.action = 'platform.company_onboarded'
                      and lower(pa.target) = lower(u.email))
       and not exists (select 1 from erp.user_role ur
                         join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                        where ur.tenant_id = u.tenant_id and ur.app_user_id = u.id
                          and r.code = 'administrator'
                          and coalesce(ur.grant_reason, '') not like 'Platform % support access:%')
     group by u.tenant_id, u.id, u.email, u.status, u.created_at, t.code
    having u.created_at is distinct from min(sa.granted_at)
  loop
    perform erp_meta.act_in_tenant(a.tenant_id);

    select r.id into v_role from erp.role r
     where r.tenant_id = a.tenant_id and r.code = 'administrator' and r.status = 'active';
    if v_role is null then
      continue;
    end if;

    -- The support grant a current window may carry gives way to the member's.
    delete from erp.user_role ur
     where ur.tenant_id = a.tenant_id and ur.app_user_id = a.app_user_id
       and ur.role_id = v_role
       and ur.grant_reason like 'Platform % support access:%';

    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (a.tenant_id, a.app_user_id, v_role,
            'Tenant administrator grant, restored: a support window had taken it (20261003300000)');

    update erp.app_user set status = 'active'
     where tenant_id = a.tenant_id and id = a.app_user_id;

    insert into erp_meta.platform_audit
      (actor_email, actor_role, action, tenant_id, tenant_code, reason, detail)
    values ('migration@cloveerp', 'owner', 'platform.member_restored', a.tenant_id, a.tenant_code,
            'The organisation''s onboarding administrator had been adopted by a support window, '
            'and its expiry revoked the administrator grant and disabled the principal. Restored.',
            jsonb_build_object('app_user_id', a.app_user_id,
                               'email', a.email,
                               'status_before', a.status_before,
                               'first_window', a.first_window));

    v_total := v_total + 1;
  end loop;

  perform erp_meta.stop_acting_in_tenant();
  return v_total;
end;
$$;

revoke all on function erp.restore_members_taken_by_support(uuid) from public, anon, authenticated;

comment on function erp.restore_members_taken_by_support(uuid) is
  'Re-enables an onboarding administrator a support window adopted, and restores the '
  'administrator grant its expiry took (20261003300000). Trusted sessions only.';

do $repair$
declare
  v_n integer;
begin
  v_n := erp.restore_members_taken_by_support();
  raise notice 'restore_members_taken_by_support: % principal(s) restored', v_n;
end
$repair$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.member_is_not_support_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  st      uuid := gen_random_uuid();
  v_email text;
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  rm record; rv record; rd record;
  v_answer jsonb;
  v_user uuid;
  v_role uuid;
  v_err  text;
  v_n    integer;
begin
  v_email := 'staff@zzmem-' || v_tag || '.test';
  begin
    -- A member of staff; an organisation onboarded with their own address
    -- (rm), one they only visit (rv), and one already damaged as production
    -- was (rd).
    perform set_config('request.jwt.claims', '', true);
    insert into auth.users (id, email) values (st, v_email);
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_email, st, 'Member Suite Staff', 'owner');
    select * into rm from erp.provision_tenant('zzmem-m-' || v_tag, 'Member Suite Own', v_email, 'Own Admin');
    select * into rv from erp.provision_tenant('zzmem-v-' || v_tag, 'Member Suite Visit', 'admin@zzmem-v-' || v_tag || '.test', 'Visit Admin');
    select * into rd from erp.provision_tenant('zzmem-d-' || v_tag, 'Member Suite Damaged', v_email, 'Damaged Admin');
    perform set_config('erp.job_tenant_id', '', true);

    -- 1. Enter on your own organisation is a switch, not a window.
    v_step := 'entering the organisation onboarded with your own address';
    perform set_config('request.jwt.claims', json_build_object('sub', st, 'role', 'authenticated')::text, true);
    v_answer := public.erp_platform_enter_tenant(rm.tenant_id, 'suite: this is my own company');
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'entering an organisation you are a member of switches to it and opens no window';
    passed := (v_answer ->> 'as_member')::boolean
          and not exists (select 1 from erp.support_access sa where sa.tenant_id = rm.tenant_id)
          and (select u.auth_user_id from erp.app_user u where u.id = rm.admin_user_id) = st
          and (select u.status from erp.app_user u where u.id = rm.admin_user_id) = 'active'
          and exists (select 1 from erp_meta.principal_preference pp
                       where pp.auth_user_id = st and pp.active_tenant_id = rm.tenant_id);
    detail := coalesce(v_answer::text, 'no answer');
    return next;

    -- 2. The member's own grant is untouched by it.
    v_cases := v_cases + 1;
    case_name := 'and the member''s own administrator grant is the only one it holds';
    passed := (select count(*) from erp.user_role ur where ur.tenant_id = rm.tenant_id
                 and ur.app_user_id = rm.admin_user_id
                 and ur.grant_reason like 'Platform % support access:%') = 0
          and erp.holds_member_grant(rm.tenant_id, rm.admin_user_id);
    detail := 'no support grant beside the member grant';
    return next;

    -- 3. A window that lapses on a member takes only what it gave.
    v_step := 'expiring a window opened on a member';
    perform set_config('erp.job_tenant_id', rm.tenant_id::text, true);
    select r.id into v_role from erp.role r where r.tenant_id = rm.tenant_id and r.code = 'administrator';
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason, entity_id)
    select rm.tenant_id, rm.admin_user_id, v_role, 'Platform owner support access: suite, a window from before',
           (select e.id from erp.entity e where e.tenant_id = rm.tenant_id limit 1);
    insert into erp.support_access (tenant_id, staff_email, staff_role, reason, is_write_access,
                                    granted_at, expires_at, app_user_id)
    values (rm.tenant_id, v_email, 'owner', 'suite: a window from before', true,
            now() - interval '5 hours', now() - interval '1 hour', rm.admin_user_id);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    perform erp.expire_support_access(rm.tenant_id);
    v_cases := v_cases + 1;
    case_name := 'a lapsed window on a member revokes its own grant and leaves the member enabled';
    passed := (select u.status from erp.app_user u where u.id = rm.admin_user_id) = 'active'
          and erp.holds_member_grant(rm.tenant_id, rm.admin_user_id)
          and not exists (select 1 from erp.user_role ur where ur.tenant_id = rm.tenant_id
                            and ur.app_user_id = rm.admin_user_id
                            and ur.grant_reason like 'Platform % support access:%');
    detail := format('status %s', (select u.status from erp.app_user u where u.id = rm.admin_user_id));
    return next;

    -- 4. And its lapsed window does not close the member's sign-in.
    v_cases := v_cases + 1;
    case_name := 'a lapsed window does not close a member''s own sign-in';
    passed := not erp.support_window_closed(rm.tenant_id, rm.admin_user_id);
    detail := 'support_window_closed is false while a member grant is held';
    return next;

    -- 5. A visitor still gets a window, and loses everything when it lapses.
    v_step := 'visiting an organisation';
    perform set_config('request.jwt.claims', json_build_object('sub', st, 'role', 'authenticated')::text, true);
    v_answer := public.erp_platform_enter_tenant(rv.tenant_id, 'suite: helping their administrator');
    perform set_config('erp.job_tenant_id', '', true);
    v_user := (v_answer ->> 'principal_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'a visitor still enters through a window, as support';
    passed := not (v_answer ->> 'as_member')::boolean
          and exists (select 1 from erp.support_access sa where sa.tenant_id = rv.tenant_id and sa.app_user_id = v_user)
          and not erp.holds_member_grant(rv.tenant_id, v_user);
    detail := coalesce(v_answer::text, 'no answer');
    return next;

    -- 6. Leave on a visit disables; Leave on your own organisation does not.
    v_step := 'leaving';
    v_answer := public.erp_platform_leave_tenant(rv.tenant_id);
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'leaving a visit ends it';
    passed := (v_answer ->> 'left')::boolean
          and (select u.status from erp.app_user u where u.id = v_user) = 'disabled';
    detail := coalesce(v_answer::text, 'no answer');
    return next;

    v_answer := public.erp_platform_leave_tenant(rm.tenant_id);
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'leaving your own organisation ends no membership';
    passed := (v_answer ->> 'still_member')::boolean
          and (select u.status from erp.app_user u where u.id = rm.admin_user_id) = 'active'
          and erp.holds_member_grant(rm.tenant_id, rm.admin_user_id);
    detail := coalesce(v_answer::text, 'no answer');
    return next;

    -- 7. The damage production met, repaired.
    v_step := 'repairing an organisation damaged as production was';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', rd.tenant_id::text, true);
    update erp.app_user set auth_user_id = st, status = 'disabled' where id = rd.admin_user_id;
    delete from erp.user_role ur where ur.tenant_id = rd.tenant_id and ur.app_user_id = rd.admin_user_id;
    insert into erp.support_access (tenant_id, staff_email, staff_role, reason, is_write_access,
                                    granted_at, expires_at, app_user_id)
    values (rd.tenant_id, v_email, 'owner', 'suite: the window that took it', true,
            now() - interval '5 hours', now() - interval '1 hour', rd.admin_user_id);
    insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, tenant_code, target, reason, detail)
    values (v_email, 'owner', 'platform.company_onboarded', rd.tenant_id, 'zzmem-d-' || v_tag, v_email, null,
            jsonb_build_object('code', 'zzmem-d-' || v_tag));
    perform set_config('erp.job_tenant_id', '', true);
    v_n := erp.restore_members_taken_by_support(rd.tenant_id);
    v_cases := v_cases + 1;
    case_name := 'the repair restores the onboarding administrator a window took, and nobody else';
    passed := v_n = 1
          and (select u.status from erp.app_user u where u.id = rd.admin_user_id) = 'active'
          and erp.holds_member_grant(rd.tenant_id, rd.admin_user_id)
          and not erp.support_window_closed(rd.tenant_id, rd.admin_user_id)
          and erp.restore_members_taken_by_support(rv.tenant_id) = 0
          and erp.restore_members_taken_by_support(rd.tenant_id) = 0;
    detail := format('%s restored', v_n);
    return next;

    -- 8. A member the organisation disabled is not let back in as support.
    v_err := null;
    perform set_config('erp.job_tenant_id', rm.tenant_id::text, true);
    update erp.app_user set status = 'disabled' where id = rm.admin_user_id;
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', st, 'role', 'authenticated')::text, true);
    begin
      perform public.erp_platform_enter_tenant(rm.tenant_id, 'suite: trying to get back in');
    exception when others then v_err := left(sqlerrm, 200); end;
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'a member the organisation disabled is refused, not re-entered as support';
    passed := v_err like 'CLOVEERP_MEMBER_DISABLED:%'
          and not exists (select 1 from erp.support_access sa
                           where sa.tenant_id = rm.tenant_id and sa.expires_at > now());
    detail := coalesce(v_err, 'it was entered');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_MEMBER_SUPPORT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code like 'zzmem-%-' || v_tag)
     or exists (select 1 from auth.users u where u.id = st) then
    raise exception 'CLOVEERP_MEMBER_SUPPORT_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.member_is_not_support_suite() from public, anon, authenticated;

create or replace function erp_test.assert_member_is_not_support_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.member_is_not_support_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_MEMBER_SUPPORT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Entering or leaving would turn a member into a visitor, or a lapsed window would take what it did not give. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_MEMBER_SUPPORT_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('member is not support: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_member_is_not_support_suite() from public, anon;

comment on function erp_test.assert_member_is_not_support_suite() is
  'A member who enters is not a visitor, and a lapsed window takes only what it gave (20261003300000).';

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
select erp.assert_authorising_doors_are_volatile();
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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
