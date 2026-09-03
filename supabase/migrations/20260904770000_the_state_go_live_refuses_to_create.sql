-- ─────────────────────────────────────────────────────────────────────────────
-- An organisation the console creates cannot be configured, and the door that
-- would go and help it collides with itself.
--
-- Found by fingerprinting live against a from-empty build of main after the
-- last carry. 1,381 functions, six schemas, and exactly two disagreed:
-- erp.provision_tenant/9 and public.erp_platform_enter_tenant/2. The natural
-- reading is that live is behind. It was not. Both live bodies carry repairs
-- made against the database while something was broken in front of somebody,
-- and never brought back — the wording in them appears nowhere in this
-- project's history, on any branch. So main has been carrying two defects that
-- live has not had for weeks, and a deployment from empty would reintroduce
-- both. This brings them home, and brings a check with each.
--
-- ── One: a new organisation is born unable to be configured ─────────────────
--
-- public.erp_platform_onboard_company() — the "create an organisation" button
-- on the superadmin console — calls erp.provision_tenant(), which ends by
-- declaring the organisation live.
--
-- A live organisation is a governed one: erp.guard_live_configuration() refuses
-- direct edits to configuration tables, so every change goes through a change
-- set, and erp.approve_change_set() refuses the author of a change set — but
-- only once erp.tenant_is_live(). A freshly created organisation has exactly
-- one administrator. That administrator raises the change set that installs a
-- module, and is then the one person forbidden from approving it. Nothing can
-- be installed. Nothing can be configured. The organisation is born finished
-- and unusable, and the screen that created it reports it as ready.
--
-- erp.go_live() already refuses to create that state, in as many words:
--
--   -- After this call the author of a change set may no longer approve it, so
--   -- a tenant with one administrator would go live unable to change anything.
--   if v_admins < 2 then raise ERPWARE_SINGLE_ADMINISTRATOR ...
--
-- So the check existed, was right, and there was one route to that state which
-- did not pass through it.
--
-- The repair is not to stop erp.provision_tenant() declaring. Its contract is
-- to build a finished, governed organisation in one privileged call, fifteen
-- suites depend on that, and two of erp_test.provisioning_suite()'s cases
-- assert it directly. The two callers simply want different things: a fixture
-- wants an organisation that is finished, and the console is creating one for
-- somebody else to finish. So the console hands it over in the bootstrap
-- window — built, not yet governed — which is where erp.onboard_tenant() has
-- left self-service organisations since 20260829320000, and erp.go_live()
-- closes the window when there is a second administrator to close it over.
--
-- ── Two: the support door collides on the email it was given ────────────────
--
-- erp.app_user carries `app_user_email_per_tenant UNIQUE (tenant_id, email)`.
-- public.erp_platform_enter_tenant() looked for a row by auth_user_id and, not
-- finding one, inserted. The row it collides with is the one the console
-- created a moment earlier: erp_platform_onboard_company() takes an admin email
-- and provisions an invited administrator with it, and in early operation the
-- email staff type into that box is very often their own. Entering that
-- organisation to help then fails with 23505 on a unique index, which reads to
-- the person clicking as the product being broken rather than as a name
-- already being taken.
--
-- The invited row is the right row to use, so entering adopts it — binds the
-- staff auth_user_id to it and activates it — rather than making a second one.
-- The case that must not be adopted is an email already held by a *different*
-- account: that is somebody else, and silently taking their row would be far
-- worse than a refusal. It is refused by name.
--
-- ── What was actually missing, both times ───────────────────────────────────
--
-- erp_test.superadmin_suite() covers entering an organisation, twice. It
-- provisions with one email and enters as another, so it never meets the
-- collision. And nothing anywhere asked the question this migration is named
-- for: after the console creates an organisation, can that organisation be
-- configured? Every suite provisions directly and then writes as a privileged
-- session with a null principal, which is exactly the caller self-approval does
-- not refuse — so the deadlock was invisible to all of them, and to the console
-- door, which no suite had ever called. The tests were standing where the
-- defect could not be seen, which is the same shape as the last three faults on
-- this branch.
--
-- So the suite below asks it the way a person does: create an organisation from
-- the console, accept the invitation, install something, and see whether it
-- lands. And the assertion reports any organisation left standing in the state
-- erp.go_live() refuses, which is a condition that outlives this fix — the
-- second administrator of a live organisation can also be revoked, and the
-- result is the same deadlock with nothing to say so.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- Provisioning builds a governed organisation. The console hands one over.
--
-- The fix does not belong in erp.provision_tenant(). That function's contract
-- is "build a complete, governed organisation in one privileged call", and
-- erp_test.provisioning_suite() asserts exactly that in two of its eighteen
-- cases — the self environment exists and is live, and configuration cannot be
-- edited directly once it is. Fourteen other suites depend on it too, because
-- erp.install_module_config() finishes the install itself inside the bootstrap
-- window and leaves it for a second person to approve outside one. Taking the
-- liveness out of provisioning would delete a true property of the product and
-- break fifteen suites to do it.
--
-- The two callers want different things, and that is the whole of it. A fixture
-- or an operator calling erp.provision_tenant() directly wants an organisation
-- that is finished. The console is creating an organisation for somebody else
-- to finish, and the person it hands it to is, for a while, the only
-- administrator in it. So the console hands it over in the bootstrap window —
-- built, not yet governed — which is the state erp.onboard_tenant() has left
-- self-service organisations in since 20260829320000, and erp.go_live() closes
-- it when there is a second administrator to close it over.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.erp_platform_onboard_company(
  p_code text, p_name text, p_admin_email text, p_admin_display_name text,
  p_base_currency character DEFAULT 'GBP'::bpchar,
  p_country_code character DEFAULT 'GB'::bpchar,
  p_timezone text DEFAULT 'UTC'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v erp_meta.platform_staff;
  r record;
begin
  v := erp_meta.require_platform('operator');

  select * into r from erp.provision_tenant(
    lower(trim(p_code)), p_name, lower(trim(p_admin_email)), p_admin_display_name,
    p_base_currency, p_country_code, 'MAIN', p_timezone, interval '14 days');

  -- Handed over rather than handed down. erp.provision_tenant() finishes with a
  -- governed organisation, which is right for a fixture and wrong for a
  -- customer: the administrator it just created is the only one there is, and
  -- once the environment is live that person authors every change set and may
  -- approve none of them. Installing a module would be refused, and so would
  -- everything else on the Configuration screen, in an organisation this
  -- function had just reported as ready.
  --
  -- erp.go_live() already refuses to create that state — "a tenant with one
  -- administrator would go live unable to change anything" — and this was the
  -- one route to it that did not go through erp.go_live(). So it does now: the
  -- window is reopened here, erp.install_module_config() completes an install
  -- inside it, and the organisation declares itself finished when it has a
  -- second administrator to declare it over.
  update erp.environment e
     set is_live = false, updated_at = now()
   where e.tenant_id = r.tenant_id and e.is_self;

  insert into erp_meta.company_owner (tenant_id, staff_id, assigned_by)
  select r.tenant_id,
         case when v.staff_role = 'owner' then v.id
              else (select ps.id from erp_meta.platform_staff ps
                     where ps.staff_role = 'owner' and ps.revoked_at is null
                     order by ps.created_at limit 1) end,
         v.id
  on conflict (tenant_id) do nothing;

  perform erp_meta.platform_log(v, 'platform.company_onboarded', r.tenant_id,
                                p_admin_email, null,
                                jsonb_build_object('code', lower(trim(p_code)), 'name', p_name));

  return jsonb_build_object(
    'tenant_id', r.tenant_id, 'code', lower(trim(p_code)), 'name', p_name,
    'admin_user_id', r.admin_user_id, 'admin_token', r.admin_token,
    'admin_email', lower(trim(p_admin_email)),
    -- Said out loud, because the console should be able to tell somebody what
    -- state their new organisation is in rather than implying it is finished.
    'is_live', false);
end;
$function$;

comment on function public.erp_platform_onboard_company(text, text, text, text, character, character, text) is
  'Creates an organisation for a customer and hands it over in the bootstrap '
  'window. erp.provision_tenant() builds a governed one, which is right for a '
  'fixture and wrong for a customer whose only administrator would then be the '
  'one principal forbidden from approving their own first change.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Entering an organisation whose administrator is you.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.erp_platform_enter_tenant(p_tenant_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v       erp_meta.platform_staff;
  v_t     erp.tenant;
  v_user  uuid;
  v_owner uuid;
  v_role  uuid;
begin
  v := erp_meta.require_platform('support');

  if coalesce(trim(p_reason), '') = '' then
    raise exception 'ERPWARE_REASON_REQUIRED: entering a customer tenant needs a reason'
      using errcode = '22023';
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

  perform erp_meta.platform_log(v, 'platform.tenant_entered', p_tenant_id,
                                v_t.code, p_reason);

  return jsonb_build_object('tenant_id', p_tenant_id, 'code', v_t.code,
                            'principal_id', v_user);
end;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The condition, reported wherever it stands
--
-- Fixing provisioning stops the product manufacturing this state. It does not
-- stop it being reached: revoke the second administrator from a live
-- organisation and it is deadlocked again, with nothing to say so until the
-- next promotion is refused. The count below is erp.go_live()'s own predicate,
-- written once here so the gate and the report cannot drift apart.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.promoting_principal_count(p_tenant_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select count(distinct ur.app_user_id)::integer
    from erp.user_role ur
    join erp.role_permission rp
      on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
    join erp.app_user u
      on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
   where ur.tenant_id = p_tenant_id
     and rp.permission_code = 'administration.promote'
     and u.status in ('active', 'invited')
     and (ur.valid_to is null or ur.valid_to >= current_date);
$$;

comment on function erp.promoting_principal_count(uuid) is
  'How many principals in an organisation may approve a change set. Below two '
  'a live organisation cannot change its own configuration, because the author '
  'of a change set may not approve it.';

revoke all on function erp.promoting_principal_count(uuid) from public, anon;
grant execute on function erp.promoting_principal_count(uuid) to authenticated, service_role;

create or replace function erp.single_administrator_report()
returns table (tenant_code text, administrators integer, finding text)
language sql
stable
set search_path = ''
as $$
  select t.code, erp.promoting_principal_count(t.id),
         'this organisation is live and has '
           || erp.promoting_principal_count(t.id)
           || ' principal(s) holding administration.promote, so the author of a '
              'change set is the only one who could approve it and may not — '
              'its configuration cannot be changed by anybody in it'
    from erp.tenant t
   where t.status not in ('deleting', 'deleted')
     and exists (select 1 from erp.environment e
                  where e.tenant_id = t.id and e.is_self and e.is_live)
     and erp.promoting_principal_count(t.id) < 2
   order by 1;
$$;

comment on function erp.single_administrator_report() is
  'Live organisations that cannot change their own configuration. Reached by '
  'provisioning until 20260904770000, and reachable still by revoking the '
  'second administrator of one.';

revoke all on function erp.single_administrator_report() from public, anon;
grant execute on function erp.single_administrator_report() to authenticated, service_role;

create or replace function erp.assert_no_single_administrator_live_tenant()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s: %s', r.tenant_code, r.finding), E'\n')
    into v_count, v_detail
    from erp.single_administrator_report() r;

  if v_count > 0 then
    raise exception E'ERPWARE_SINGLE_ADMINISTRATOR_LIVE: % organisation(s)\n%',
      v_count, v_detail using errcode = 'P0001';
  end if;

  return format('administrators: %s live organisation(s), every one with a second '
                'principal who can approve a change set',
                (select count(*) from erp.tenant t
                  where t.status not in ('deleting', 'deleted')
                    and exists (select 1 from erp.environment e
                                 where e.tenant_id = t.id and e.is_self and e.is_live)));
end;
$$;

revoke all on function erp.assert_no_single_administrator_live_tenant() from public, anon;
grant execute on function erp.assert_no_single_administrator_live_tenant() to authenticated, service_role;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('single_administrator_live',
   'Every live organisation has somebody who can approve a change',
   'assertion', 'platform', 'erp',
   'assert_no_single_administrator_live_tenant', '{}',
   'single_administrator_report', '{}',
   'A live organisation with one administrator is deadlocked: that person '
   'authors every change set and may approve none of them, so nothing can be '
   'configured and nothing says why until the next promotion is refused.',
   true, 79)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ─────────────────────────────────────────────────────────────────────────────
-- The suite: can an organisation this product creates be configured?
--
-- Written as the person experiences it rather than as the schema sees it. Every
-- other suite provisions and then writes as a privileged session with a null
-- principal — which is exactly the caller erp.approve_change_set() does not
-- refuse, so the deadlock was invisible to all of them. These cases bind a real
-- principal first.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.provisioning_window_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  staff    uuid := gen_random_uuid();   -- the member of staff at the console
  au       uuid := gen_random_uuid();   -- the customer's administrator
  res      jsonb;
  v_tenant uuid;
  v_admin  uuid;
  v_role   uuid;
  admin2   uuid;
  v_cs     uuid;
  v_ok     boolean;
  v_msg    text;
  v_live   boolean;
begin
  insert into auth.users (id, email) values (staff, 'ops@zzwindow.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('ops@zzwindow.test', staff, 'Window Suite Operator', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', staff)::text, true);

  -- Through the door the console actually uses. No suite had ever called it,
  -- which is why what it produced went unexamined for as long as it did.
  res := public.erp_platform_onboard_company(
    'zzwindow', 'Provisioning Window', 'admin@zzwindow.test', 'Window Admin');
  v_tenant := (res ->> 'tenant_id')::uuid;
  v_admin  := (res ->> 'admin_user_id')::uuid;

  perform set_config('erp.job_tenant_id', v_tenant::text, true);

  select bool_or(e.is_live) into v_live
    from erp.environment e where e.tenant_id = v_tenant and e.is_self;
  return query select 'an organisation from the console is built, not yet governed',
    v_live is false,
    'it used to be handed over live, which is the one state erp.go_live() '
    'refuses to create';

  return query select 'and the console says so rather than implying it is ready',
    (res ->> 'is_live') = 'false',
    'the screen that creates an organisation should be able to say what state '
    'it is in';

  -- The other half of the claim, and the case that guards against somebody
  -- later "fixing" this by gutting the builder instead: called directly,
  -- erp.provision_tenant() still hands back a finished, governed organisation,
  -- which is what erp_test.provisioning_suite() asserts and what fourteen other
  -- suites are written against. The difference is the handover, not the build.
  declare d record;
  begin
    select * into d from erp.provision_tenant(
      'zzwindow-d', 'Direct', 'direct@zzwindow.test', 'Direct Admin');
    return query select 'erp.provision_tenant() itself still builds a governed one',
      (select e.is_live from erp.environment e where e.id = d.environment_id),
      'a fixture or an operator asking for a finished organisation still gets one';
    update erp.environment set is_live = false where tenant_id = d.tenant_id;
    perform erp.begin_tenant_purge(d.tenant_id);
    delete from erp.tenant where id = d.tenant_id;
    perform erp.end_tenant_purge();
  end;
  perform set_config('erp.job_tenant_id', v_tenant::text, true);

  -- The acceptance test, run as the administrator rather than as a null
  -- principal: raise a change set, approve it, promote it. erp.app_user is
  -- 'invited' with no account until somebody accepts, so this binds one, which
  -- is what claiming the invitation does. It matters that this is a real
  -- principal — a privileged session with a null principal is precisely the
  -- caller erp.approve_change_set() does not refuse, which is how every
  -- existing suite configured happily while nobody using the product could.
  insert into auth.users (id, email) values (au, 'admin@zzwindow.test');
  update erp.app_user set auth_user_id = au, status = 'active' where id = v_admin;
  perform set_config('request.jwt.claims', json_build_object('sub', au)::text, true);

  begin
    v_cs := erp.create_change_set('zzwindow-cs', 'A first configuration change',
                                  'One department, which is all it takes to prove it.');
    perform erp.add_change_set_item(v_cs, 'department', 'OPS', jsonb_build_object(
      'code', 'OPS', 'name', 'Operations', 'entity', 'MAIN'));
    perform erp.submit_change_set(v_cs);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    v_ok := exists (select 1 from erp.department d
                     where d.tenant_id = v_tenant and d.code = 'OPS');
    v_msg := 'the sole administrator raised, approved and promoted it';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 90);
  end;
  return query select 'its first administrator can actually configure it',
    v_ok, v_msg;

  -- And the guard is still load-bearing: going live is still refused over one
  -- administrator, which is the check the handover used to skip.
  begin
    perform erp.go_live();
    v_ok := false; v_msg := 'go_live() accepted a single administrator';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SINGLE_ADMINISTRATOR%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'going live still refuses over a single administrator',
    v_ok, v_msg || ' — the fix is that the handover stops skipping this check, '
                   'not that the check stops mattering';

  return query select 'and the assertion reports nobody, because nobody is live yet',
    not exists (select 1 from erp.single_administrator_report() s
                 where s.tenant_code = 'zzwindow'),
    'the report is about live organisations; a window that is open is not one';

  -- Two administrators, live, and the separation of duties the whole design is
  -- for comes on. This is the state the console used to hand over on day one.
  select r.id into v_role from erp.role r
   where r.tenant_id = v_tenant and r.code = 'administrator';
  insert into erp.app_user (tenant_id, kind, status, display_name, email, user_locale)
  values (v_tenant, 'person', 'active', 'Second Admin', 'admin2@zzwindow.test', 'en')
  returning id into admin2;
  insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
  values (v_tenant, admin2, v_role, 'Suite: somebody to separate from.');

  begin
    perform erp.go_live();
    select bool_or(e.is_live) into v_live
      from erp.environment e where e.tenant_id = v_tenant and e.is_self;
    v_msg := 'over configuration that is not already known to be wrong';
  exception when others then
    v_live := false; v_msg := left(sqlerrm, 80);
  end;
  return query select 'with a second administrator it goes live',
    v_live, v_msg;

  begin
    v_cs := erp.create_change_set('zzwindow-cs2', 'A governed change',
                                  'The same shape as the first, now that it is live.');
    perform erp.add_change_set_item(v_cs, 'department', 'FIN', jsonb_build_object(
      'code', 'FIN', 'name', 'Finance', 'entity', 'MAIN'));
    perform erp.submit_change_set(v_cs);
    perform erp.approve_change_set(v_cs);
    v_ok := false; v_msg := 'an author approved their own change set on a live tenant';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CHANGE_SET_SELF_APPROVAL%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and separation of duties comes on with it',
    v_ok, v_msg;

  return query select 'and the report stays quiet while there are two of them',
    not exists (select 1 from erp.single_administrator_report() s
                 where s.tenant_code = 'zzwindow'),
    format('%s promoting principal(s)', erp.promoting_principal_count(v_tenant));

  -- The condition this fix stops the product manufacturing is still reachable
  -- by taking the second administrator away, and nothing else would say so
  -- until the next promotion was refused. So the report has to find it, and
  -- this is the case that proves it can.
  delete from erp.user_role ur
   where ur.tenant_id = v_tenant and ur.app_user_id = admin2;
  return query select 'but revoking one deadlocks the organisation, and it says so',
    exists (select 1 from erp.single_administrator_report() s
             where s.tenant_code = 'zzwindow' and s.administrators = 1),
    'a live organisation with one administrator can no longer change its own '
    'configuration, however it got there';

  -- Tearing it down means deleting erp.role rows, and the guard this suite has
  -- just proved is working refuses that in a live environment. So stand the
  -- organisation back down first; erp.environment is not itself a promotable
  -- surface, which is why erp.go_live() can write to it at all.
  update erp.environment set is_live = false where tenant_id = v_tenant;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  -- Under its own purge rather than around it: this administrator authorised
  -- real calls, so erp.access_log has rows and the append-only guard refuses a
  -- plain DELETE.
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from erp_meta.company_owner where tenant_id = v_tenant;
  delete from erp_meta.platform_staff where email = 'ops@zzwindow.test';
  delete from erp_meta.principal_preference where auth_user_id in (staff, au);
  delete from auth.users where id in (staff, au);
end;
$$;

create or replace function erp_test.assert_provisioning_window_suite()
returns text
language plpgsql
as $$
declare v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not s.passed), count(*),
         string_agg(format('  %s: %s', s.case_name, s.detail), E'\n') filter (where not s.passed)
    into v_failed, v_total, v_detail
    from erp_test.provisioning_window_suite() s;

  if v_failed > 0 then
    raise exception E'ERPWARE_PROVISIONING_WINDOW_SUITE: % of % case(s) failed\n%',
      v_failed, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('provisioning window: %s of %s cases pass', v_total, v_total);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The support door, entered by the person whose email is already in there.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.support_entry_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path to ''
as $$
declare
  ow      uuid := gen_random_uuid();
  other   uuid := gen_random_uuid();
  r       record;
  r2      record;
  v_ok    boolean;
  v_msg   text;
  v_user  uuid;
  v_bound uuid;
begin
  insert into auth.users (id, email) values
    (ow, 'staff@zzentry.test'), (other, 'someone.else@zzentry.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('staff@zzentry.test', ow, 'Entry Suite Staff', 'owner');

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);

  -- The ordinary case first, so a regression in it is not hidden by the new
  -- one passing: an organisation whose administrator is somebody else.
  select * into r from erp.provision_tenant(
    'zzentry-a', 'Entry A', 'admin@zzentry.test', 'Entry Admin');
  perform set_config('erp.job_tenant_id', '', true);
  perform public.erp_platform_enter_tenant(r.tenant_id, 'suite: unrelated admin');
  return query select 'entering an organisation makes a principal for the staff member',
    exists (select 1 from erp.app_user u
             where u.tenant_id = r.tenant_id and u.auth_user_id = ow),
    'unchanged behaviour, checked so the new branch cannot quietly replace it';

  -- The one that failed in front of somebody: staff created the organisation
  -- with their own address, so the invited administrator already holds it.
  select * into r2 from erp.provision_tenant(
    'zzentry-b', 'Entry B', 'staff@zzentry.test', 'Entry Admin B');
  perform set_config('erp.job_tenant_id', '', true);
  begin
    perform public.erp_platform_enter_tenant(r2.tenant_id, 'suite: my own address');
    v_ok := true; v_msg := 'entered';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 90);
  end;
  return query select 'and entering one whose administrator is you does not collide',
    v_ok, v_msg || ' — erp.app_user is unique on (tenant_id, email) and this '
                    'used to insert over it';

  select u.id, u.auth_user_id into v_user, v_bound
    from erp.app_user u
   where u.tenant_id = r2.tenant_id and lower(u.email) = 'staff@zzentry.test';
  return query select 'it adopts the invited administrator rather than duplicating it',
    (select count(*) from erp.app_user u
      where u.tenant_id = r2.tenant_id and lower(u.email) = 'staff@zzentry.test') = 1
      and v_bound = ow and v_user = r2.admin_user_id,
    'the row the console created is the row to use, bound and activated';

  return query select 'and the administrator role is granted on it as usual',
    exists (select 1 from erp.user_role ur
             join erp.role ro on ro.id = ur.role_id
            where ur.tenant_id = r2.tenant_id and ur.app_user_id = v_user
              and ro.code = 'administrator'),
    'adoption must not skip the grant that support access is for';

  -- The case that must never be adopted: the address belongs to a different
  -- account. Taking that row would hand somebody else''s identity inside a
  -- customer''s organisation to a member of staff.
  select * into r from erp.provision_tenant(
    'zzentry-c', 'Entry C', 'staff@zzentry.test', 'Entry Admin C');
  perform set_config('erp.job_tenant_id', r.tenant_id::text, true);
  update erp.app_user set auth_user_id = other, status = 'active'
   where id = r.admin_user_id;
  perform set_config('erp.job_tenant_id', '', true);
  begin
    perform public.erp_platform_enter_tenant(r.tenant_id, 'suite: somebody else holds it');
    v_ok := false; v_msg := 'a row belonging to another account was adopted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_EMAIL_TAKEN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'but an address held by a different account is refused by name',
    v_ok, v_msg || ' — a refusal that says why beats silently entering as '
                    'somebody else';

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  for v_user in select t.id from erp.tenant t
                 where t.code in ('zzentry-a', 'zzentry-b', 'zzentry-c')
  loop
    perform erp.begin_tenant_purge(v_user);
    delete from erp.tenant where id = v_user;
  end loop;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email = 'staff@zzentry.test';
  delete from auth.users where id in (ow, other);
end;
$$;

create or replace function erp_test.assert_support_entry_suite()
returns text
language plpgsql
as $$
declare v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not s.passed), count(*),
         string_agg(format('  %s: %s', s.case_name, s.detail), E'\n') filter (where not s.passed)
    into v_failed, v_total, v_detail
    from erp_test.support_entry_suite() s;

  if v_failed > 0 then
    raise exception E'ERPWARE_SUPPORT_ENTRY_SUITE: % of % case(s) failed\n%',
      v_failed, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('support entry: %s of %s cases pass', v_total, v_total);
end;
$$;

-- Every assertion that governs what this migration touched, at its end.
select erp.assert_no_single_administrator_live_tenant();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp_test.assert_provisioning_window_suite();
select erp_test.assert_support_entry_suite();
