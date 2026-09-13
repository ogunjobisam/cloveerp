-- A closed support window lets nobody back in.
--
-- Platform staff enter a customer organisation through
-- public.erp_platform_enter_tenant() (20260904930000). The door creates or
-- reactivates a principal for them inside that organisation, grants it the
-- administrator role, writes an erp.support_access row that expires four hours
-- later, raises support.access_granted and writes the platform log. The
-- principal is disabled and the grant revoked in two places only: when staff
-- click Leave (erp_platform_leave_tenant, 20260904880000), or when
-- erp.expire_support_access() runs.
--
-- A review on 13 September found three ways the window stays open after it
-- closes:
--
--   * erp.expire_support_access() is called from one place,
--     public.erp_platform_run_due_jobs(), which is the operator's manual drain
--     button. The minute sweep pg_cron runs, erp.run_due_jobs_all_tenants()
--     (20260906112000, patched by 20260906120000), never calls it. 20260904880000
--     says the expiry "runs on every platform housekeeping pass". It ran on
--     the passes somebody clicked.
--   * Principals created before 20260904880000 have no erp.support_access row,
--     so no expiry of any kind can find them. 20260904880000 measured one on
--     live: an operator holding administrator in northgate.
--   * Nothing refuses such a principal. erp.principal_context()
--     (20260829180000) falls back to the caller's newest active principal once
--     the preference row is gone, and public.erp_set_active_tenant() lets staff
--     choose an organisation they hold an active principal in. So a staff
--     member lands back in a customer's organisation as its administrator with
--     no new window, no event and no audit line, while
--     erp.support_access_is_live() tells the organisation nobody is inside.
--
-- This file closes all three:
--
--   1. The minute sweep expires support windows for every organisation before
--      it does anything else. It is patched the way 20260906120000 patched
--      it, by asserted needle, rather than given its own schedule entry: the
--      minute pass is already what the host runs, 20260906112000 and
--      20260906120000 both chose to extend it, and a second cron job is a
--      second thing that can be missing on a host.
--   2. The principals from before windows were recorded are found by the
--      grant 20260830091046 onwards has always written, 'Platform <role>
--      support access: <reason>', with no erp.support_access row naming them.
--      They are disabled, the grant is revoked, and each closure is written to
--      erp_meta.platform_audit. The windows already past are expired here as
--      well, so neither waits for the first minute after the deploy. The
--      migration then refuses to finish while any such principal remains.
--   3. erp.principal_context() and erp.set_active_tenant(), which
--      public.erp_set_active_tenant() calls, refuse a principal named on
--      support windows none of which is still open. The refusal is
--      CLOVEERP_SUPPORT_WINDOW_CLOSED and its hint sends staff to the platform
--      console, which opens a new window and tells the organisation.
--
-- Two choices the code forced:
--
--   * After (2) every support principal is named on an erp.support_access row,
--     and the entry door writes the grant and the row in one transaction, so
--     "named on a window, none open" is the whole test. It is one probe on an
--     index added here. erp.principal_context() runs under every row-security
--     policy through erp.current_tenant_id(), which carries a SET clause and
--     is never inlined, so that probe runs for every principal on every scan.
--     The grant-reason text match is used only for the one-off closure.
--   * The refusal applies only outside triggers. The attribution and audit
--     triggers resolve the acting principal to stamp a row, and the console's
--     own doors fire them while the closed window is still somebody's choice:
--     entering, leaving and the sweep all update the principal that is being
--     closed or replaced. A trigger stamping who did something is not
--     somebody arriving. The statement that fired it has already resolved the
--     principal outside a trigger: through row security, erp.authorise() or
--     erp.require_tenant_id(). A desk request is refused there. The console's
--     doors reach the principal only through triggers until they have opened
--     a window.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The minute sweep expires support windows for every organisation
-- ═════════════════════════════════════════════════════════════════════════════

do $sweep$
declare
  v_src    text := pg_catalog.pg_get_functiondef('erp.run_due_jobs_all_tenants(integer)'::regprocedure);
  v_new    text;
  v_needle text;
  n_decl   constant text := $n$  v_prompt  jsonb;$n$;
  n_timer  constant text := $n$  -- The incident timer first: an update that fell due is recorded before$n$;
  n_result constant text := $n$'incident_timer', v_prompt, 'detail', v_out);$n$;
begin
  foreach v_needle in array array[n_decl, n_timer, n_result] loop
    if (length(v_src) - length(replace(v_src, v_needle, ''))) / length(v_needle) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_due_jobs_all_tenants does not carry "%" exactly once, so it is not the 20260906120000 body', v_needle;
    end if;
  end loop;
  if position('expire_support_access' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_due_jobs_all_tenants already expires support access';
  end if;

  v_new := replace(v_src, n_decl, n_decl || E'\n  v_support jsonb;');
  v_new := replace(v_new, n_timer, $r$  -- Support windows before anything else, and for every organisation whatever
  -- its status: a window that has passed takes the administrator grant it
  -- carried with it. The grant belongs to platform staff rather than to an
  -- organisation's jobs, so this is one call, not one per organisation, and it
  -- comes first so that nothing further down the pass can keep it from running.
  begin
    v_support := jsonb_build_object('windows_expired', erp.expire_support_access());
  exception when others then
    v_support := jsonb_build_object('error', left(sqlerrm, 200));
  end;

  -- Then the incident timer: an update that fell due is recorded before$r$);
  v_new := replace(v_new, n_result, $r$'incident_timer', v_prompt, 'support_access', v_support, 'detail', v_out);$r$);
  execute v_new;

  if position('erp.expire_support_access()' in
              pg_catalog.pg_get_functiondef('erp.run_due_jobs_all_tenants(integer)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_due_jobs_all_tenants was re-emitted without the support expiry';
  end if;
end
$sweep$;

comment on function erp.run_due_jobs_all_tenants(integer) is
  'One pass over every organisation, from a trusted session: support windows '
  'that have passed are expired first, then the incident timer, then each '
  'organisation''s stranded work is reclaimed, its incidents communicated and '
  'its due SQL jobs run. What pg_cron calls every minute where the host has it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Whether a principal's support window has closed, in one probe
-- ═════════════════════════════════════════════════════════════════════════════

create index if not exists support_access_by_principal
  on erp.support_access (tenant_id, app_user_id, expires_at)
  where app_user_id is not null;

create or replace function erp.support_window_closed(p_tenant_id uuid, p_app_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- No row: not a support principal. A row still open: inside a window.
  -- Otherwise every window that named this principal has passed.
  select coalesce(max(sa.expires_at) <= now(), false)
    from erp.support_access sa
   where sa.tenant_id = p_tenant_id
     and sa.app_user_id = p_app_user_id
$$;
revoke all on function erp.support_window_closed(uuid, uuid) from public, anon, authenticated;

comment on function erp.support_window_closed(uuid, uuid) is
  'True when erp.support_access names this principal and every window naming '
  'it has passed. False for a principal no window names, which is every '
  'organisation''s own member. Read by erp.principal_context() and '
  'erp.set_active_tenant() to refuse a support principal whose window closed.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The principals from before windows were recorded
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.close_unrecorded_support_principals(p_tenant_id uuid default null)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  a       record;
  v_gone  integer := 0;
  v_total integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not close support principals', current_user
      using errcode = '42501',
            hint = 'This runs as the database owner, from a migration; nobody signed in closes another person''s access.';
  end if;

  -- Every grant erp_platform_enter_tenant() has made carries this reason, and
  -- since 20260904880000 the same transaction names the principal on an
  -- erp.support_access row. A support grant on a principal no row names is
  -- from before that, and nothing has ever been able to expire it.
  for a in
    select u.tenant_id, u.id as app_user_id, u.email, u.status::text as status_before,
           t.code as tenant_code,
           array_agg(ur.grant_reason order by ur.created_at) as reasons
      from erp.user_role ur
      join erp.app_user u on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
      join erp.tenant t on t.id = ur.tenant_id
     where ur.grant_reason like 'Platform % support access:%'
       and (p_tenant_id is null or ur.tenant_id = p_tenant_id)
       and not exists (select 1 from erp.support_access sa
                        where sa.tenant_id = ur.tenant_id
                          and sa.app_user_id = ur.app_user_id)
     group by u.tenant_id, u.id, u.email, u.status, t.code
  loop
    perform set_config('erp.job_tenant_id', a.tenant_id::text, true);

    -- The grants the support session carried, and only those: a role the
    -- organisation gave this principal for its own reasons is the
    -- organisation's to take back, and disabling the principal ends it anyway.
    delete from erp.user_role ur
     where ur.tenant_id = a.tenant_id
       and ur.app_user_id = a.app_user_id
       and ur.grant_reason like 'Platform % support access:%';
    get diagnostics v_gone = row_count;

    update erp.app_user set status = 'disabled'
     where tenant_id = a.tenant_id and id = a.app_user_id;

    insert into erp_meta.platform_audit
      (actor_email, actor_role, action, tenant_id, tenant_code, reason, detail)
    values (a.email,
            substring(a.reasons[1] from '^Platform (\S+) support access:'),
            'platform.support_access_closed', a.tenant_id, a.tenant_code,
            'Support access with no window on record; the principal was disabled '
            'and the grant it carried was revoked.',
            jsonb_build_object('app_user_id', a.app_user_id,
                               'grants_revoked', v_gone,
                               'status_before', a.status_before,
                               'grant_reasons', to_jsonb(a.reasons)));

    v_total := v_total + 1;
  end loop;

  perform set_config('erp.job_tenant_id', '', true);
  return v_total;
end;
$$;
revoke all on function erp.close_unrecorded_support_principals(uuid) from public, anon, authenticated;

comment on function erp.close_unrecorded_support_principals(uuid) is
  'Disables every principal holding a platform support grant that no '
  'erp.support_access row names, revokes that grant and writes '
  'platform.support_access_closed to the platform audit. Those principals date '
  'from before 20260904880000, when entering an organisation recorded no '
  'window, so no expiry could ever find them. Safe to call at any time.';

-- Close them, and the windows already past, now rather than a minute from now.
select erp.close_unrecorded_support_principals();
select erp.expire_support_access();

do $none_left$
declare
  v_left text;
begin
  select string_agg(distinct t.code || ' / ' || coalesce(u.email, u.id::text), ', ')
    into v_left
    from erp.user_role ur
    join erp.app_user u on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
    join erp.tenant t on t.id = ur.tenant_id
   where ur.grant_reason like 'Platform % support access:%'
     and not exists (select 1 from erp.support_access sa
                      where sa.tenant_id = ur.tenant_id
                        and sa.app_user_id = ur.app_user_id);
  if v_left is not null then
    raise exception 'CLOVEERP_UNRECORDED_SUPPORT_ACCESS_REMAINS: %', v_left
      using hint = 'erp.close_unrecorded_support_principals() left a support grant with no window on record. '
                   'erp.principal_context() only refuses principals a window names, so this must be empty.';
  end if;
end
$none_left$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A closed window is not a way back in
-- ═════════════════════════════════════════════════════════════════════════════

do $recognise$
declare
  v_src  text;
  v_lang text;
begin
  select p.prosrc, l.lanname into v_src, v_lang
    from pg_catalog.pg_proc p
    join pg_catalog.pg_language l on l.oid = p.prolang
   where p.oid = 'erp.principal_context()'::regprocedure;
  if v_lang <> 'sql'
     or position('order by (p.active_tenant_id is not null and p.active_tenant_id = u.tenant_id) desc' in v_src) = 0
     or position('u.created_at desc' in v_src) = 0
     or position('limit 1' in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.principal_context is not the 20260829180000 body this migration re-emits';
  end if;
end
$recognise$;

-- The same resolution as 20260829180000, in plpgsql so that it can refuse.
create or replace function erp.principal_context()
returns table (principal_id uuid, tenant_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_principal uuid;
  v_tenant    uuid;
begin
  select u.id, u.tenant_id
    into v_principal, v_tenant
    from erp.app_user u
    left join erp_meta.principal_preference p
      on p.auth_user_id = u.auth_user_id
   where u.auth_user_id = (select auth.uid())
     and u.status = 'active'::erp.principal_status
   order by (p.active_tenant_id is not null and p.active_tenant_id = u.tenant_id) desc,
            u.created_at desc
   limit 1;

  if v_principal is null then
    return;
  end if;

  -- A support principal is in the organisation while a window is open, and
  -- not otherwise, whether it was chosen or reached by the newest-principal
  -- fallback. Outside triggers only: a trigger stamping who changed a row is
  -- not somebody arriving, and the console's own doors fire those triggers on
  -- the very principal they are closing or replacing.
  if pg_catalog.pg_trigger_depth() = 0
     and erp.support_window_closed(v_tenant, v_principal) then
    raise exception 'CLOVEERP_SUPPORT_WINDOW_CLOSED: the support window that let this sign-in into the organisation has closed'
      using errcode = '42501',
            hint = 'Enter the organisation again from the platform console, which opens a new support window and tells the organisation.';
  end if;

  principal_id := v_principal;
  tenant_id    := v_tenant;
  return next;
end;
$$;

comment on function erp.principal_context() is
  'The identity boundary. Resolves the authenticated subject to a principal, '
  'preferring the organisation that subject has chosen, falling back to the '
  'newest only when none has been chosen. Refuses a support principal whose '
  'windows have all closed, except inside a trigger, where the row being '
  'stamped was reached by a statement that has already been through here.';

update erp_meta.security_definer_allowance
   set rationale =
     'Breaks the RLS recursion on erp.app_user. Argument-free, returns only the '
     'caller''s own principal, never consults the trust check. Reads the '
     'windows erp.support_access records for the principal it resolves, and '
     'refuses one whose windows have all closed.'
 where schema_name = 'erp' and function_name = 'principal_context';

do $switch$
declare
  v_src    text := pg_catalog.pg_get_functiondef('erp.set_active_tenant(uuid)'::regprocedure);
  n_member constant text := $n$  -- The check that matters: a person may only choose a tenant they already$n$;
begin
  if (length(v_src) - length(replace(v_src, n_member, ''))) / length(n_member) <> 1
     or position('CLOVEERP_NOT_A_MEMBER' in v_src) = 0
     or position('support_window_closed' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.set_active_tenant is not the 20260829180000 body this migration patches';
  end if;

  execute replace(v_src, n_member, $r$  -- A support principal is chosen only while its window is open. Its status is
  -- not asked: once the sweep has disabled it, the membership test below
  -- would refuse it as a stranger, and the useful answer is where to go.
  if exists (
    select 1 from erp.app_user u
     where u.auth_user_id = v_subject
       and u.tenant_id = p_tenant_id
       and erp.support_window_closed(u.tenant_id, u.id))
  then
    raise exception
      'CLOVEERP_SUPPORT_WINDOW_CLOSED: the support window in that organisation has closed'
      using errcode = '42501',
            hint = 'Enter the organisation again from the platform console, which opens a new support window and tells the organisation.';
  end if;

$r$ || n_member);

  if position('erp.support_window_closed(' in
              pg_catalog.pg_get_functiondef('erp.set_active_tenant(uuid)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.set_active_tenant was re-emitted without the window check';
  end if;
end
$switch$;

update erp_meta.security_definer_allowance
   set rationale =
     'Writes the caller''s own tenant choice, which is keyed on auth.uid() and '
     'therefore belongs to no tenant, so there is no context to run it under. '
     'Refuses any tenant the caller does not already hold an active principal '
     'in, and any where the caller is a support principal whose windows have '
     'all closed.'
 where schema_name = 'erp' and function_name = 'set_active_tenant';

select erp.register_refusal('CLOVEERP_SUPPORT_WINDOW_CLOSED',
  'Working in an organisation through a support window that has closed.',
  'Platform staff are inside a customer organisation only while a support window, recorded on that organisation''s own screen, is open. When it closes, the rights it carried go with it.',
  'Enter the organisation again from the platform console. That opens a new window and tells the organisation.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two organisations. In A the staff member enters through the console, so the
-- window is live. In B they hold administrator under a window that passed an
-- hour ago, built directly as erp_test.support_visibility_suite builds it:
-- erp.support_access is append-only and the door always grants four hours. B
-- also holds a former operator's principal from before windows were recorded,
-- and an administrator of the organisation's own. Everything is undone.

create or replace function erp_test.support_window_closure_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_owner  text := current_user;
  v_tag    text := substr(md5(random()::text), 1, 6);
  ra record; rb record;
  v_staff  uuid := gen_random_uuid();
  v_former uuid := gen_random_uuid();
  v_email  text;
  v_role   uuid;
  v_closed uuid;
  v_legacy uuid;
  v_own    uuid;
  v_live   uuid;
  v_res    jsonb;
  v_now    uuid;
  v_n      integer;
  v_msg    text;
  v_hint   text;
  c_reason constant text := 'Customer raised INC-9107: checking a support window that closed stays closed.';

  v_sweep_ok    boolean; v_sweep_msg    text;
  v_fallback_ok boolean; v_fallback_msg text;
  v_enter_ok    boolean; v_enter_msg    text;
  v_switch_ok   boolean; v_switch_msg   text;
  v_chosen_ok   boolean; v_chosen_msg   text;
  v_expire_ok   boolean; v_expire_msg   text;
  v_legacy_ok   boolean; v_legacy_msg   text;
begin
  -- 1. Read, not run: running the minute pass would visit every organisation.
  select position('erp.expire_support_access()' in p.prosrc) > 0
         and position('erp.expire_support_access()' in p.prosrc) < position('for t in select tn.id' in p.prosrc),
         format('erp.expire_support_access() at %s, the organisation loop at %s',
                position('erp.expire_support_access()' in p.prosrc), position('for t in select tn.id' in p.prosrc))
    into v_sweep_ok, v_sweep_msg
    from pg_catalog.pg_proc p
   where p.oid = 'erp.run_due_jobs_all_tenants(integer)'::regprocedure;

  begin
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzswa-' || v_tag, 'Support Window Suite A', 'a@zzsw-' || v_tag || '.test', 'A Admin');
    select * into rb from erp.provision_tenant('zzswb-' || v_tag, 'Support Window Suite B', 'b@zzsw-' || v_tag || '.test', 'B Admin');

    v_email := 'staff@zzsw-' || v_tag || '.test';
    insert into auth.users (id, email) values
      (v_staff, v_email),
      (v_former, 'former@zzsw-' || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_email, v_staff, 'Support Window Suite Staff', 'support');

    perform set_config('erp.job_tenant_id', rb.tenant_id::text, true);
    select r.id into v_role from erp.role r
     where r.tenant_id = rb.tenant_id and r.code = 'administrator' and r.status = 'active';

    -- The visit nobody closed.
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (rb.tenant_id, v_staff, 'person', 'active', 'Support Window Suite Staff (Clove ERP support)', v_email)
    returning id into v_closed;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (rb.tenant_id, v_closed, v_role, 'Platform support support access: ' || c_reason);
    insert into erp.support_access
      (tenant_id, staff_email, staff_role, reason, is_write_access, granted_at, expires_at, app_user_id)
    values (rb.tenant_id, v_email, 'support', c_reason, true,
            now() - interval '5 hours', now() - interval '1 hour', v_closed);

    -- A visit from before windows were recorded.
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (rb.tenant_id, v_former, 'person', 'active', 'Former Operator (Clove ERP operator)', 'former@zzsw-' || v_tag || '.test')
    returning id into v_legacy;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (rb.tenant_id, v_legacy, v_role, 'Platform operator support access: ' || c_reason);

    -- And the organisation's own administrator.
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (rb.tenant_id, 'person', 'active', 'B Finance Lead', 'lead@zzsw-' || v_tag || '.test')
    returning id into v_own;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (rb.tenant_id, v_own, v_role, 'Appointed by the organisation to run its settings.');

    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_staff, 'role', 'authenticated')::text, true);

    -- 2. No choice has been made, so the fallback lands on B.
    v_msg := null; v_hint := null; v_now := null;
    execute 'set local role authenticated';
    begin
      v_now := erp.current_tenant_id();
    exception when others then
      get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
    end;
    execute format('set local role %I', v_owner);
    v_fallback_ok := v_now is null
                     and v_msg like 'CLOVEERP_SUPPORT_WINDOW_CLOSED%'
                     and v_hint like '%platform console%';
    v_fallback_msg := coalesce(left(v_msg, 120) || coalesce(' / ' || v_hint, ' / no hint'),
                               format('the session resolved to %s', v_now));

    -- 3. Entering A from the console while B is still the fallback.
    v_msg := null; v_res := null; v_now := null;
    begin
      v_res := public.erp_platform_enter_tenant(ra.tenant_id, c_reason);
    exception when others then
      v_msg := left(sqlerrm, 200);
    end;
    v_live := (v_res ->> 'principal_id')::uuid;
    if v_msg is null then
      execute 'set local role authenticated';
      begin
        v_now := erp.current_tenant_id();
      exception when others then
        v_msg := left(sqlerrm, 200);
      end;
      execute format('set local role %I', v_owner);
    end if;
    v_enter_ok := v_msg is null and v_live is not null and v_now = ra.tenant_id
                  and erp.support_access_is_live(ra.tenant_id, true);
    v_enter_msg := coalesce(v_msg, format('entered as %s; the session resolves to %s', v_live, v_now));

    -- 4. Switching into B.
    v_msg := null; v_hint := null;
    begin
      perform public.erp_set_active_tenant(rb.tenant_id);
      v_switch_ok := false;
      v_msg := 'the organisation whose support window closed was accepted';
    exception when others then
      get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
      v_switch_ok := v_msg like 'CLOVEERP_SUPPORT_WINDOW_CLOSED%' and v_hint like '%platform console%';
    end;
    v_switch_ok := v_switch_ok
                   and (select pp.active_tenant_id from erp_meta.principal_preference pp
                         where pp.auth_user_id = v_staff) = ra.tenant_id;
    v_switch_msg := left(v_msg, 160);

    -- 5. B chosen while its window was open, now closed, beside a live A.
    update erp_meta.principal_preference set active_tenant_id = rb.tenant_id
     where auth_user_id = v_staff;
    v_msg := null; v_now := null;
    execute 'set local role authenticated';
    begin
      v_now := erp.current_tenant_id();
    exception when others then
      v_msg := left(sqlerrm, 160);
    end;
    execute format('set local role %I', v_owner);
    v_chosen_ok := v_now is null and v_msg like 'CLOVEERP_SUPPORT_WINDOW_CLOSED%';
    v_chosen_msg := coalesce(v_msg, format('the session resolved to %s', v_now));

    -- 6. The sweep's call, with B still chosen and the staff member signed in,
    --    which is the operator's drain from inside their own closed window.
    v_msg := null; v_n := null; v_now := null;
    begin
      v_n := erp.expire_support_access();
    exception when others then
      v_msg := left(sqlerrm, 200);
    end;
    if v_msg is null then
      execute 'set local role authenticated';
      begin
        v_now := erp.current_tenant_id();
      exception when others then
        v_msg := left(sqlerrm, 200);
      end;
      execute format('set local role %I', v_owner);
    end if;
    v_expire_ok := v_msg is null and v_n >= 1
      and (select u.status::text from erp.app_user u where u.tenant_id = rb.tenant_id and u.id = v_closed) = 'disabled'
      and not exists (select 1 from erp.user_role ur where ur.tenant_id = rb.tenant_id and ur.app_user_id = v_closed)
      and exists (select 1 from erp_meta.platform_audit pa
                   where pa.action = 'platform.support_access_expired' and pa.tenant_id = rb.tenant_id
                     and pa.detail ->> 'app_user_id' = v_closed::text)
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = v_live) = 'active'
      and exists (select 1 from erp.user_role ur
                    join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
                   where ur.tenant_id = ra.tenant_id and ur.app_user_id = v_live and ro.code = 'administrator')
      and v_now = ra.tenant_id;
    v_expire_msg := coalesce(v_msg, format('%s window(s) expired; B''s principal %s; the session now resolves to %s',
      v_n, (select u.status::text from erp.app_user u where u.tenant_id = rb.tenant_id and u.id = v_closed), v_now));

    -- 7. The principal from before windows were recorded.
    v_msg := null; v_n := null;
    begin
      v_n := erp.close_unrecorded_support_principals();
    exception when others then
      v_msg := left(sqlerrm, 200);
    end;
    v_legacy_ok := v_msg is null and v_n >= 1
      and (select u.status::text from erp.app_user u where u.tenant_id = rb.tenant_id and u.id = v_legacy) = 'disabled'
      and not exists (select 1 from erp.user_role ur where ur.tenant_id = rb.tenant_id and ur.app_user_id = v_legacy)
      and exists (select 1 from erp_meta.platform_audit pa
                   where pa.action = 'platform.support_access_closed' and pa.tenant_id = rb.tenant_id
                     and pa.actor_role = 'operator'
                     and pa.detail ->> 'app_user_id' = v_legacy::text)
      and (select u.status::text from erp.app_user u where u.tenant_id = rb.tenant_id and u.id = v_own) = 'active'
      and exists (select 1 from erp.user_role ur where ur.tenant_id = rb.tenant_id and ur.app_user_id = v_own)
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = v_live) = 'active';
    v_legacy_msg := coalesce(v_msg, format('%s principal(s) closed; the former operator''s is %s, the organisation''s own administrator''s %s',
      v_n,
      (select u.status::text from erp.app_user u where u.tenant_id = rb.tenant_id and u.id = v_legacy),
      (select u.status::text from erp.app_user u where u.tenant_id = rb.tenant_id and u.id = v_own)));

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  return query select 'the minute sweep expires support windows for every organisation before it visits any',
    coalesce(v_sweep_ok, false), v_sweep_msg;
  return query select 'a session that falls back to a principal whose window has closed is refused, and told to use the platform console',
    coalesce(v_fallback_ok, false), v_fallback_msg;
  return query select 'entering another organisation from the console still works while the closed one is the fallback, and its live window resolves',
    coalesce(v_enter_ok, false), v_enter_msg;
  return query select 'switching into the organisation whose window has closed is refused, and the choice stands',
    coalesce(v_switch_ok, false), v_switch_msg;
  return query select 'a session that chose that organisation is refused too, beside a live window elsewhere',
    coalesce(v_chosen_ok, false), v_chosen_msg;
  return query select 'the sweep''s call closes the expired window while it is the choice, and leaves the live one alone',
    coalesce(v_expire_ok, false), v_expire_msg;
  return query select 'a support principal from before windows were recorded is closed, and the organisation''s own administrator is not',
    coalesce(v_legacy_ok, false), v_legacy_msg;
  return query select 'the fixtures were undone',
    not exists (select 1 from erp.tenant t where t.code in ('zzswa-' || v_tag, 'zzswb-' || v_tag))
      and not exists (select 1 from erp_meta.platform_staff s where s.email = 'staff@zzsw-' || v_tag || '.test')
      and not exists (select 1 from auth.users u where u.id in (v_staff, v_former)),
    'two organisations, two sign-ins, a staff row and every grant rolled back';
end;
$$;
revoke all on function erp_test.support_window_closure_suite() from public, anon, authenticated;

create or replace function erp_test.assert_support_window_closure_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.support_window_closure_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SUPPORT_WINDOW_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_SUPPORT_WINDOW_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail;
  end if;
  return format('support window closure: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;
revoke all on function erp_test.assert_support_window_closure_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_support_window_closure_suite();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internals();
select erp.assert_refusals_name_next_action();
select erp.assert_scheduler_integrity();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
