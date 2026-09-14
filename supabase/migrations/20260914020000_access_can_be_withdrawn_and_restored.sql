-- Access can be withdrawn and restored.
--
-- The owner asked to be able to revoke invitations and access. What was there
-- (20260910135355) was one door, public.erp_remove_principal(), behind a
-- one-click button, and three things it could not do:
--
--   * It could not withdraw an invitation without also saying the person had
--     been "removed", and it could not be undone: nothing set a principal back
--     to active.
--   * It would remove the last person in the organisation who can manage users,
--     leaving nobody able to invite, remove or restore anybody. Only platform
--     staff could get the organisation back.
--   * It could not end a grant made today. It ended every open grant by setting
--     valid_to to yesterday, and erp.user_role carries
--     check (valid_to is null or valid_to >= valid_from): a grant whose
--     valid_from is today (every role given today, and the first
--     administrator's grant on the day an organisation is provisioned) cannot
--     end yesterday, so the whole removal failed with a check violation.
--
-- Its refusals were CLOVEERP_VALIDATION with no hint, so the desk could only
-- show the sentence.
--
-- What this file does, in order:
--
--   1. Who manages users. erp.holds_user_management(tenant, person) is a grant
--      in force today, organisation-wide, of an active role carrying
--      administration.users. erp.is_support_principal(tenant, person) is a
--      principal a support window named, or one holding a platform support
--      grant (20260913110000 recognises them the same two ways).
--      erp.user_managers_remaining(tenant, excluding) counts the active people,
--      other than the one excluded, who manage users and are not platform
--      support. Support staff hold administrator while a window is open, and a
--      window closes on its own: they are never the organisation's way back in.
--   2. erp.end_principal_grants(tenant, person). A grant that began before
--      today ends yesterday and stays on file. A grant that begins today or
--      later cannot end before it begins, so it is deleted; the audit stream
--      keeps the row it deleted, as it does for erp_set_user_roles.
--   3. erp.remove_principal() returns what it did, and refuses by name: not in
--      this organisation, yourself, the last person who manages users. A person
--      already removed is not an error; nothing changes and the answer says so.
--      Removals in one organisation queue behind each other, so two people
--      cannot remove each other at the same moment and leave nobody.
--   4. erp.withdraw_invitation() withdraws an invitation nobody has claimed:
--      every open token is revoked with the reason, the person is disabled and
--      any grant already given to them ends. The record stays, so
--      erp.invite_principal() can invite the same address again to the same
--      person.
--   5. erp.restore_principal() gives a removed person their sign-in back and
--      nothing else. Their roles are not restored: whoever restores them gives
--      roles again, deliberately. Somebody who never joined has nothing to
--      restore and is invited again; a platform support principal comes back
--      only through the platform console, which opens a window the
--      organisation is told about.
--   6. Three public doors, SECURITY INVOKER like the one they join. Their
--      register rows name the erp function each delegates to as its gate, as
--      erp_remove_principal's row always has: erp.public_api_report() asks that
--      a door's own body call its declared gate, and the erp function is where
--      erp.authorise('administration.users') is called, once.
--   7. public.erp_permissions_directory() tells the desk, for each principal,
--      whether they have signed in, where their newest open invitation stands,
--      whether they manage users and whether they are platform support. It
--      stays SECURITY INVOKER, as 20260829180000 left it.
--   8. erp_test.access_withdrawal_suite() proves it through the doors, as a
--      signed-in caller.
--
-- Not changed: erp.invite_principal() still refuses somebody who has signed in
-- (restore is the way back for them now), and the rule about the last person
-- who manages users is kept by removal only; unticking a role is still
-- administration.roles' decision.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Who manages users
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.holds_user_management(p_tenant uuid, p_app_user_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  -- Organisation-wide only: a grant narrowed to a company or a site was made
  -- for that company or site, and the organisation's people are not its to
  -- keep.
  select exists (
    select 1
      from erp.user_role ur
      join erp.role r
        on r.tenant_id = ur.tenant_id and r.id = ur.role_id and r.status = 'active'
      join erp.role_permission rp
        on rp.tenant_id = r.tenant_id and rp.role_id = r.id
     where ur.tenant_id = p_tenant
       and ur.app_user_id = p_app_user_id
       and rp.permission_code = 'administration.users'
       and ur.entity_id is null
       and ur.site_id is null
       and ur.valid_from <= current_date
       and (ur.valid_to is null or ur.valid_to >= current_date))
$$;
revoke all on function erp.holds_user_management(uuid, uuid) from public, anon, authenticated;

comment on function erp.holds_user_management(uuid, uuid) is
  'True when the principal holds administration.users today through an '
  'organisation-wide grant of an active role. Says nothing about whether the '
  'principal is active or is platform support; erp.user_managers_remaining() '
  'asks both.';

create or replace function erp.is_support_principal(p_tenant uuid, p_app_user_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  -- Named on a support window, or carrying the grant the console has always
  -- written ('Platform <role> support access: <reason>'), window or not.
  select exists (select 1 from erp.support_access sa
                  where sa.tenant_id = p_tenant and sa.app_user_id = p_app_user_id)
      or exists (select 1 from erp.user_role ur
                  where ur.tenant_id = p_tenant and ur.app_user_id = p_app_user_id
                    and ur.grant_reason like 'Platform % support access:%')
$$;
revoke all on function erp.is_support_principal(uuid, uuid) from public, anon, authenticated;

comment on function erp.is_support_principal(uuid, uuid) is
  'True for a principal platform staff entered the organisation as: named on an '
  'erp.support_access row, or holding a platform support grant. The organisation '
  'does not count them among the people who manage its users, and cannot restore '
  'their access; the platform console opens a new window instead.';

create or replace function erp.user_managers_remaining(p_tenant uuid, p_excluding uuid)
returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  select count(*)::integer
    from erp.app_user u
   where u.tenant_id = p_tenant
     and u.id is distinct from p_excluding
     and u.kind = 'person'
     and u.status = 'active'
     and erp.holds_user_management(u.tenant_id, u.id)
     and not erp.is_support_principal(u.tenant_id, u.id)
$$;
revoke all on function erp.user_managers_remaining(uuid, uuid) from public, anon, authenticated;

comment on function erp.user_managers_remaining(uuid, uuid) is
  'The active people in the organisation, other than the one excluded (none when '
  'null), who hold administration.users organisation-wide today and are not '
  'platform support. erp.remove_principal() refuses to take this to zero.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A person's grants end now
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.end_principal_grants(p_tenant uuid, p_app_user_id uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_ended   integer := 0;
  v_dropped integer := 0;
begin
  -- Begun before today: it ends yesterday, and the record of who held what
  -- stays readable.
  update erp.user_role ur
     set valid_to = current_date - 1
   where ur.tenant_id = p_tenant
     and ur.app_user_id = p_app_user_id
     and ur.valid_from < current_date
     and (ur.valid_to is null or ur.valid_to >= current_date);
  get diagnostics v_ended = row_count;

  -- Begun today, or not begun yet: a grant cannot end before it begins
  -- (user_role_range), and leaving it to end today would leave it in force
  -- today. It goes; the audit stream keeps the row.
  delete from erp.user_role ur
   where ur.tenant_id = p_tenant
     and ur.app_user_id = p_app_user_id
     and ur.valid_from >= current_date;
  get diagnostics v_dropped = row_count;

  return v_ended + v_dropped;
end;
$$;
revoke all on function erp.end_principal_grants(uuid, uuid) from public, anon, authenticated;

comment on function erp.end_principal_grants(uuid, uuid) is
  'Ends every grant the principal holds or is due to hold, and returns how many. '
  'A grant begun before today ends yesterday and stays on file; one begun today '
  'or later is deleted, because a grant cannot end before it begins. Internal: '
  'the doors that call it authorise first.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Removing access
-- ═════════════════════════════════════════════════════════════════════════════

-- The return type changes from void to jsonb, which CREATE OR REPLACE cannot do.
drop function if exists erp.remove_principal(uuid, text);

create function erp.remove_principal(
  p_app_user_id uuid,
  p_reason      text default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_status    text;
  v_name      text;
  v_others    integer;
  v_ended     integer;
  v_withdrawn integer;
begin
  perform erp.authorise('administration.users', null, null, null, 'app_user',
                        p_app_user_id);

  -- One removal at a time in an organisation. Without it, two people who
  -- manage users could remove each other at once, each counting the other as
  -- the one who remains.
  perform pg_advisory_xact_lock(hashtext('erp.remove_principal ' || v_tenant::text));

  select u.status::text, coalesce(nullif(btrim(u.display_name), ''), u.email, 'That person')
    into v_status, v_name
    from erp.app_user u
   where u.tenant_id = v_tenant
     and u.id = p_app_user_id
     for update;

  if not found then
    raise exception 'CLOVEERP_PRINCIPAL_NOT_FOUND: that person is not in this organisation'
      using errcode = '23503',
            hint = 'Refresh the list of people. They may belong to another organisation, or the list you acted on is out of date.';
  end if;

  if p_app_user_id = erp.current_principal_id() then
    raise exception 'CLOVEERP_PRINCIPAL_SELF_REMOVAL: you cannot remove your own access'
      using errcode = '42501',
            hint = 'Ask another administrator who can manage users to remove you.';
  end if;

  if v_status = 'disabled' then
    return jsonb_build_object(
      'app_user_id', p_app_user_id, 'status', 'disabled', 'already_removed', true,
      'grants_ended', 0, 'invitations_withdrawn', 0);
  end if;

  -- They count, and nobody else would.
  v_others := erp.user_managers_remaining(v_tenant, p_app_user_id);
  if v_others = 0 and erp.user_managers_remaining(v_tenant, null) > 0 then
    raise exception 'CLOVEERP_LAST_USER_MANAGER: % is the last person here who can manage users, so their access cannot be removed', v_name
      using errcode = '23514',
            hint = 'Give somebody else a role with administration.users first, then remove this person.';
  end if;

  update erp.app_user u
     set status = 'disabled'
   where u.tenant_id = v_tenant
     and u.id = p_app_user_id;

  v_ended := erp.end_principal_grants(v_tenant, p_app_user_id);

  update erp.invitation i
     set revoked_at = now(),
         revoked_reason = coalesce(p_reason, 'the person was removed')
   where i.tenant_id = v_tenant
     and i.app_user_id = p_app_user_id
     and i.claimed_at is null
     and i.revoked_at is null;
  get diagnostics v_withdrawn = row_count;

  return jsonb_build_object(
    'app_user_id', p_app_user_id, 'status', 'disabled', 'already_removed', false,
    'grants_ended', v_ended, 'invitations_withdrawn', v_withdrawn);
end;
$$;
revoke all on function erp.remove_principal(uuid, text) from public, anon, authenticated;

comment on function erp.remove_principal(uuid, text) is
  'Ends a person''s access under administration.users: disables them, ends their '
  'grants (kept on file where they began before today) and revokes any open '
  'invitation. Refuses a person outside the organisation, the caller, and the last '
  'active person who manages users. A person already removed is reported, not '
  'refused. Returns app_user_id, status, already_removed, grants_ended and '
  'invitations_withdrawn.';

-- Same signature and return type as 20260910135355, so the grants stay.
create or replace function public.erp_remove_principal(
  p_app_user_id uuid,
  p_reason      text default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  return erp.remove_principal(p_app_user_id, p_reason);
end;
$$;

comment on function public.erp_remove_principal(uuid, text) is
  'Ends a person''s access without deleting them, so their history keeps pointing '
  'at one person and access can be restored later. Refuses yourself and the last '
  'person who manages users. Returns what it did.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Withdrawing an invitation
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.withdraw_invitation(
  p_app_user_id uuid,
  p_reason      text default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_kind      text;
  v_status    text;
  v_auth      uuid;
  v_name      text;
  v_withdrawn integer;
begin
  perform erp.authorise('administration.users', null, null, null, 'app_user',
                        p_app_user_id);

  select u.kind::text, u.status::text, u.auth_user_id,
         coalesce(nullif(btrim(u.display_name), ''), u.email, 'That person')
    into v_kind, v_status, v_auth, v_name
    from erp.app_user u
   where u.tenant_id = v_tenant
     and u.id = p_app_user_id
     for update;

  if not found then
    raise exception 'CLOVEERP_PRINCIPAL_NOT_FOUND: that person is not in this organisation'
      using errcode = '23503',
            hint = 'Refresh the list of people. They may belong to another organisation, or the list you acted on is out of date.';
  end if;

  if v_kind <> 'person' or v_status <> 'invited' or v_auth is not null then
    raise exception 'CLOVEERP_INVITATION_NOT_PENDING: % has no invitation waiting to be withdrawn', v_name
      using errcode = '23514',
            hint = 'Somebody who has joined is removed with Remove access. Somebody already removed can be invited again.';
  end if;

  -- Every token still open, expired or not: none of them may be claimed later.
  update erp.invitation i
     set revoked_at = now(),
         revoked_reason = coalesce(p_reason, 'the invitation was withdrawn')
   where i.tenant_id = v_tenant
     and i.app_user_id = p_app_user_id
     and i.claimed_at is null
     and i.revoked_at is null;
  get diagnostics v_withdrawn = row_count;

  update erp.app_user u
     set status = 'disabled'
   where u.tenant_id = v_tenant
     and u.id = p_app_user_id;

  -- A role given while they were invited would otherwise wait for them.
  perform erp.end_principal_grants(v_tenant, p_app_user_id);

  return jsonb_build_object(
    'app_user_id', p_app_user_id, 'status', 'disabled',
    'invitations_withdrawn', v_withdrawn);
end;
$$;
revoke all on function erp.withdraw_invitation(uuid, text) from public, anon, authenticated;

comment on function erp.withdraw_invitation(uuid, text) is
  'Withdraws the invitation of a person who has not joined, under '
  'administration.users: every open token is revoked with the reason, the person '
  'is disabled and any grant already given to them ends. The record stays, so '
  'erp.invite_principal() can invite the same address again. Returns app_user_id, '
  'status and invitations_withdrawn.';

create or replace function public.erp_withdraw_invitation(
  p_app_user_id uuid,
  p_reason      text default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  return erp.withdraw_invitation(p_app_user_id, p_reason);
end;
$$;

comment on function public.erp_withdraw_invitation(uuid, text) is
  'Withdraws an invitation nobody has claimed. The link stops working at once, and '
  'the same address can be invited again later.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Restoring access
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.restore_principal(
  p_app_user_id uuid,
  p_reason      text default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_status text;
  v_auth   uuid;
  v_name   text;
begin
  -- p_reason is taken so the three doors share one shape. Nothing on a
  -- principal records it; the status change is on the row's audit trail.
  perform erp.authorise('administration.users', null, null, null, 'app_user',
                        p_app_user_id);

  select u.status::text, u.auth_user_id,
         coalesce(nullif(btrim(u.display_name), ''), u.email, 'That person')
    into v_status, v_auth, v_name
    from erp.app_user u
   where u.tenant_id = v_tenant
     and u.id = p_app_user_id
     for update;

  if not found then
    raise exception 'CLOVEERP_PRINCIPAL_NOT_FOUND: that person is not in this organisation'
      using errcode = '23503',
            hint = 'Refresh the list of people. They may belong to another organisation, or the list you acted on is out of date.';
  end if;

  if v_status not in ('disabled', 'suspended') then
    raise exception 'CLOVEERP_PRINCIPAL_NOT_REMOVED: % has not had their access removed, so there is nothing to restore', v_name
      using errcode = '23514',
            hint = 'Only somebody whose access was removed or suspended can be restored. Refresh the list of people to see where they stand.';
  end if;

  if v_auth is null then
    raise exception 'CLOVEERP_PRINCIPAL_NEVER_JOINED: % never signed in, so there is no access to restore', v_name
      using errcode = '23514',
            hint = 'Invite them again. They join with the new link.';
  end if;

  if erp.is_support_principal(v_tenant, p_app_user_id) then
    raise exception 'CLOVEERP_SUPPORT_PRINCIPAL_NOT_RESTORABLE: % came in as platform support, and support access is not restored by the organisation', v_name
      using errcode = '42501',
            hint = 'Platform staff enter again from the platform console, which opens a new support window and tells the organisation.';
  end if;

  -- Access, and nothing else: no role comes back with it.
  update erp.app_user u
     set status = 'active'
   where u.tenant_id = v_tenant
     and u.id = p_app_user_id;

  return jsonb_build_object(
    'app_user_id', p_app_user_id, 'status', 'active', 'roles_restored', 0);
end;
$$;
revoke all on function erp.restore_principal(uuid, text) from public, anon, authenticated;

comment on function erp.restore_principal(uuid, text) is
  'Gives a removed or suspended person who had signed in their access back, under '
  'administration.users, with no roles: roles are given again deliberately. '
  'Refuses a person outside the organisation, one who still has access, one who '
  'never joined and a platform support principal. Returns app_user_id, status and '
  'roles_restored (always 0).';

create or replace function public.erp_restore_principal(
  p_app_user_id uuid,
  p_reason      text default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  return erp.restore_principal(p_app_user_id, p_reason);
end;
$$;

comment on function public.erp_restore_principal(uuid, text) is
  'Restores the sign-in of a person whose access was removed. Their roles are not '
  'restored; give them roles again on Permissions.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Grants, the write register and the screen's help
-- ═════════════════════════════════════════════════════════════════════════════

revoke all on function public.erp_remove_principal(uuid, text) from public, anon;
revoke all on function public.erp_withdraw_invitation(uuid, text) from public, anon;
revoke all on function public.erp_restore_principal(uuid, text) from public, anon;
grant execute on function public.erp_remove_principal(uuid, text) to authenticated, service_role;
grant execute on function public.erp_withdraw_invitation(uuid, text) to authenticated, service_role;
grant execute on function public.erp_restore_principal(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_remove_principal', 'erp.remove_principal',
   'Ends a person''s access: disables them, ends their grants and revokes open invitations. Gated on administration.users inside erp.remove_principal(); refuses the caller and the last active person who manages users.'),
  ('erp_withdraw_invitation', 'erp.withdraw_invitation',
   'Withdraws an unclaimed invitation: revokes its tokens, disables the invited person and ends any grant given to them. Gated on administration.users inside erp.withdraw_invitation().'),
  ('erp_restore_principal', 'erp.restore_principal',
   'Sets a removed person who had signed in back to active, with no roles. Gated on administration.users inside erp.restore_principal(); refuses platform support principals.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/administration/permissions',
  array['erp_remove_principal', 'erp_withdraw_invitation', 'erp_restore_principal']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The directory says where each person stands
-- ═════════════════════════════════════════════════════════════════════════════

-- Same signature and return type as 20260829180000, so the grants stay, and
-- the same SECURITY INVOKER: row security scopes what it reads.
create or replace function public.erp_permissions_directory()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  return jsonb_build_object(
    'principals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', u.id, 'display_name', u.display_name, 'email', u.email,
               'kind', u.kind, 'status', u.status, 'created_at', u.created_at,
               'has_signed_in', u.auth_user_id is not null,
               'invited_at', inv.created_at,
               'invitation_expires_at', inv.expires_at,
               'invitation_state', case
                                     when inv.id is null then 'none'
                                     when inv.expires_at > now() then 'pending'
                                     else 'expired'
                                   end,
               'manages_users', erp.holds_user_management(u.tenant_id, u.id),
               'is_support', erp.is_support_principal(u.tenant_id, u.id))
               order by u.display_name)
        from erp.app_user u
        left join lateral (
          -- The newest invitation nobody has claimed or withdrawn.
          select i.id, i.created_at, i.expires_at
            from erp.invitation i
           where i.tenant_id = u.tenant_id
             and i.app_user_id = u.id
             and i.claimed_at is null
             and i.revoked_at is null
           order by i.created_at desc
           limit 1) inv on true
       where u.tenant_id = v_tenant), '[]'::jsonb),
    'roles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'code', r.code, 'name', r.name,
               'description', r.description, 'status', r.status,
               'permissions', coalesce((
                 select jsonb_agg(rp.permission_code order by rp.permission_code)
                   from erp.role_permission rp
                  where rp.tenant_id = r.tenant_id and rp.role_id = r.id), '[]'::jsonb))
               order by r.code)
        from erp.role r where r.tenant_id = v_tenant), '[]'::jsonb),
    'grants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ur.id, 'app_user_id', ur.app_user_id, 'role_id', ur.role_id,
               'entity_id', ur.entity_id, 'site_id', ur.site_id,
               'valid_from', ur.valid_from, 'valid_to', ur.valid_to,
               'grant_reason', ur.grant_reason, 'created_at', ur.created_at)
               order by ur.created_at desc)
        from erp.user_role ur where ur.tenant_id = v_tenant), '[]'::jsonb),
    'permission_catalog', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', p.code, 'module_code', p.module_code,
               'action', p.action, 'is_mutating', p.is_mutating)
               order by p.code)
        from erp_ref.permission p), '[]'::jsonb)
  );
end;
$$;

comment on function public.erp_permissions_directory() is
  'The organisation''s principals, roles, grants and the permission catalogue, '
  'under administration.roles. Each principal carries has_signed_in, invited_at '
  'and invitation_expires_at of their newest open invitation, invitation_state '
  '(pending, expired or none), manages_users (administration.users '
  'organisation-wide today, whatever their status) and is_support.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two organisations. In A: an administrator who joins; a person invited and
-- given a role before joining; a colleague who joins holding one role from a
-- month ago and one from today; a second person who joins with no role; an
-- invitation that expired yesterday; and platform support, inside an open
-- window, holding administrator. B is only somebody else's organisation. Every
-- door is called as a signed-in caller, through erp_test.access_door_as(), so
-- the grants and row security a real caller meets are the ones proven.
-- Everything is undone.

create or replace function erp_test.access_door_as(p_subject uuid, p_door text, p_app_user_id uuid)
returns table (outcome jsonb, err_state text, err_message text, err_hint text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner text := current_user;
begin
  if p_door not in ('erp_remove_principal', 'erp_withdraw_invitation', 'erp_restore_principal') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not one of the three access doors', p_door
      using hint = 'Call erp_remove_principal, erp_withdraw_invitation or erp_restore_principal.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute format('select public.%I($1, null::text)', p_door) into outcome using p_app_user_id;
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text,
                            err_hint = pg_exception_hint;
  end;
  execute format('set local role %I', v_owner);
  return next;
end;
$$;
revoke all on function erp_test.access_door_as(uuid, text, uuid) from public, anon, authenticated;

comment on function erp_test.access_door_as(uuid, text, uuid) is
  'Suite helper: calls one of the three access doors as the given sign-in, in '
  'the authenticated role, and returns its answer or its refusal. Returns to the '
  'calling role before it returns.';

create or replace function erp_test.access_withdrawal_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner    text := current_user;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  ra record; rb record; d record;
  s_admin    uuid := gen_random_uuid();
  s_col      uuid := gen_random_uuid();
  s_second   uuid := gen_random_uuid();
  s_support  uuid := gen_random_uuid();
  s_stranger uuid := gen_random_uuid();
  u_admin    uuid; u_pending uuid; u_col uuid; u_second uuid; u_expired uuid; u_support uuid;
  u_again    uuid;
  t_pending  text; t_col text; t_second text; t_again text;
  v_step     text := 'provisioning';
  v_state    text;
  v_dir      jsonb;
  v_n        integer;
  v_resolves_before integer;
  v_resolves_after  integer;
  v_resolves_again  integer;
  v_before   text;
  v_after    text;
  c_reason   constant text := 'Customer raised INC-4410: checking the organisation cannot restore support access.';

  ok_dir     boolean; msg_dir     text;
  ok_withdraw boolean; msg_withdraw text;
  ok_dead    boolean; msg_dead    text;
  ok_joined  boolean; msg_joined  text;
  ok_again   boolean; msg_again   text;
  ok_remove  boolean; msg_remove  text;
  ok_signin  boolean; msg_signin  text;
  ok_self    boolean; msg_self    text;
  ok_last    boolean; msg_last    text;
  ok_second  boolean; msg_second  text;
  ok_already boolean; msg_already text;
  ok_restore boolean; msg_restore text;
  ok_never   boolean; msg_never   text;
  ok_active  boolean; msg_active  text;
  ok_support boolean; msg_support text;
  ok_denied  boolean; msg_denied  text;
  ok_foreign boolean; msg_foreign text;
begin
  begin
    -- ── The organisations and the people ─────────────────────────────────
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzawa-' || v_tag, 'Access Withdrawal Suite A',
                                               'admin@zzawa-' || v_tag || '.test', 'Withdrawal Admin');
    select * into rb from erp.provision_tenant('zzawb-' || v_tag, 'Access Withdrawal Suite B',
                                               'admin@zzawb-' || v_tag || '.test', 'Other Admin');
    perform set_config('erp.job_tenant_id', '', true);

    v_step := 'the administrator joins';
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    u_admin := erp.claim_invitation(ra.admin_token);

    v_step := 'people are invited';
    select i.app_user_id, i.token into u_pending, t_pending
      from erp.invite_principal('pending@zzawa-' || v_tag || '.test', 'Pending Person') i;
    perform erp.grant_role(u_pending, 'sales', null, null, 'Given before they joined.');

    select i.app_user_id, i.token into u_col, t_col
      from erp.invite_principal('colleague@zzawa-' || v_tag || '.test', 'Colleague Person') i;
    perform erp.grant_role(u_col, 'inventory', null, null, 'Held since a month before the suite.', current_date - 30);
    perform erp.grant_role(u_col, 'reporting', null, null, 'Given today.');

    select i.app_user_id, i.token into u_second, t_second
      from erp.invite_principal('second@zzawa-' || v_tag || '.test', 'Second Person') i;

    v_step := 'the colleague and the second person join';
    perform set_config('request.jwt.claims', json_build_object('sub', s_col)::text, true);
    perform erp.claim_invitation(t_col);
    perform set_config('request.jwt.claims', json_build_object('sub', s_second)::text, true);
    perform erp.claim_invitation(t_second);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);

    v_step := 'an invitation that expired, and platform support inside an open window';
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (ra.tenant_id, 'person', 'invited', 'Expired Person', 'expired@zzawa-' || v_tag || '.test')
    returning id into u_expired;
    -- now() is the transaction's start, so an expired row is minted in the past.
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at)
    values (ra.tenant_id, u_expired,
            encode(extensions.digest(encode(extensions.gen_random_bytes(32), 'hex'), 'sha256'), 'hex'),
            now() - interval '15 days', now() - interval '1 day');

    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (ra.tenant_id, s_support, 'person', 'active', 'Suite Staff (Clove ERP support)',
            'staff@zzawa-' || v_tag || '.test')
    returning id into u_support;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select ra.tenant_id, u_support, r.id, 'Platform support support access: ' || c_reason
      from erp.role r
     where r.tenant_id = ra.tenant_id and r.code = 'administrator' and r.status = 'active';
    insert into erp.support_access
      (tenant_id, staff_email, staff_role, reason, is_write_access, granted_at, expires_at, app_user_id)
    values (ra.tenant_id, 'staff@zzawa-' || v_tag || '.test', 'support', c_reason, true,
            now(), now() + interval '4 hours', u_support);

    -- ── The directory ────────────────────────────────────────────────────
    v_step := 'the administrator reads the directory';
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_dir := public.erp_permissions_directory();
    execute format('set local role %I', v_owner);

    ok_dir :=
      coalesce((select bool_and(x.el ?& array['id', 'display_name', 'email', 'kind', 'status', 'created_at',
                                            'has_signed_in', 'invited_at', 'invitation_expires_at',
                                            'invitation_state', 'manages_users', 'is_support'])
                  from jsonb_array_elements(v_dir -> 'principals') x(el)), false)
      and v_dir ?& array['principals', 'roles', 'grants', 'permission_catalog']
      and exists (
        select 1
          from jsonb_array_elements(v_dir -> 'principals') x(el),
               erp.invitation i
         where x.el ->> 'id' = u_pending::text
           and i.tenant_id = ra.tenant_id and i.app_user_id = u_pending
           and i.claimed_at is null and i.revoked_at is null
           and x.el -> 'has_signed_in' = 'false'::jsonb
           and x.el ->> 'invitation_state' = 'pending'
           and (x.el ->> 'invited_at')::timestamptz = i.created_at
           and (x.el ->> 'invitation_expires_at')::timestamptz = i.expires_at
           and x.el -> 'manages_users' = 'false'::jsonb
           and x.el -> 'is_support' = 'false'::jsonb)
      and exists (
        select 1 from jsonb_array_elements(v_dir -> 'principals') x(el)
         where x.el ->> 'id' = u_expired::text
           and x.el ->> 'invitation_state' = 'expired'
           and (x.el ->> 'invitation_expires_at')::timestamptz < now())
      and exists (
        select 1 from jsonb_array_elements(v_dir -> 'principals') x(el)
         where x.el ->> 'id' = u_admin::text
           and x.el -> 'has_signed_in' = 'true'::jsonb
           and x.el ->> 'invitation_state' = 'none'
           and x.el -> 'invited_at' = 'null'::jsonb
           and x.el -> 'invitation_expires_at' = 'null'::jsonb
           and x.el -> 'manages_users' = 'true'::jsonb
           and x.el -> 'is_support' = 'false'::jsonb)
      and exists (
        select 1 from jsonb_array_elements(v_dir -> 'principals') x(el)
         where x.el ->> 'id' = u_col::text
           and x.el -> 'has_signed_in' = 'true'::jsonb
           and x.el -> 'manages_users' = 'false'::jsonb
           and x.el -> 'is_support' = 'false'::jsonb)
      and exists (
        select 1 from jsonb_array_elements(v_dir -> 'principals') x(el)
         where x.el ->> 'id' = u_support::text
           and x.el -> 'is_support' = 'true'::jsonb
           and x.el -> 'manages_users' = 'true'::jsonb);
    msg_dir := left(format('%s principal(s); %s',
                           jsonb_array_length(v_dir -> 'principals'),
                           (select string_agg(x.el::text, ' | ')
                              from jsonb_array_elements(v_dir -> 'principals') x(el)
                             where x.el ->> 'id' in (u_pending::text, u_expired::text, u_admin::text, u_support::text))), 600);

    -- ── Somebody without administration.users, and somebody elsewhere ─────
    v_step := 'somebody without administration.users tries each door';
    select * into d from erp_test.access_door_as(s_col, 'erp_withdraw_invitation', u_pending);
    ok_denied := coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED%', false);
    msg_denied := 'withdraw: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.access_door_as(s_col, 'erp_remove_principal', u_second);
    ok_denied := ok_denied and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED%', false);
    msg_denied := msg_denied || '; remove: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.access_door_as(s_col, 'erp_restore_principal', u_col);
    ok_denied := ok_denied and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED%', false);
    msg_denied := msg_denied || '; restore: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    v_step := 'the administrator names a person in another organisation';
    select * into d from erp_test.access_door_as(s_admin, 'erp_withdraw_invitation', rb.admin_user_id);
    ok_foreign := coalesce(d.err_state = '23503' and d.err_message like 'CLOVEERP_PRINCIPAL_NOT_FOUND%' and d.err_hint <> '', false);
    msg_foreign := 'withdraw: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.access_door_as(s_admin, 'erp_remove_principal', rb.admin_user_id);
    ok_foreign := ok_foreign and coalesce(d.err_state = '23503' and d.err_message like 'CLOVEERP_PRINCIPAL_NOT_FOUND%' and d.err_hint <> '', false);
    msg_foreign := msg_foreign || '; remove: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.access_door_as(s_admin, 'erp_restore_principal', rb.admin_user_id);
    ok_foreign := ok_foreign and coalesce(d.err_state = '23503' and d.err_message like 'CLOVEERP_PRINCIPAL_NOT_FOUND%' and d.err_hint <> '', false);
    msg_foreign := msg_foreign || '; restore: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    ok_foreign := ok_foreign
      and (select u.status::text from erp.app_user u where u.tenant_id = rb.tenant_id and u.id = rb.admin_user_id) = 'invited';

    -- ── Withdrawing an invitation ────────────────────────────────────────
    v_step := 'the administrator withdraws a pending invitation';
    select * into d from erp_test.access_door_as(s_admin, 'erp_withdraw_invitation', u_pending);
    ok_withdraw := coalesce(
      d.err_state is null
      and d.outcome ->> 'app_user_id' = u_pending::text
      and d.outcome ->> 'status' = 'disabled'
      and (d.outcome ->> 'invitations_withdrawn')::integer = 1
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_pending) = 'disabled'
      and not exists (select 1 from erp.invitation i
                       where i.tenant_id = ra.tenant_id and i.app_user_id = u_pending
                         and i.claimed_at is null and i.revoked_at is null)
      and exists (select 1 from erp.invitation i
                   where i.tenant_id = ra.tenant_id and i.app_user_id = u_pending
                     and i.revoked_reason = 'the invitation was withdrawn')
      and not exists (select 1 from erp.user_role ur
                       where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_pending
                         and ur.valid_from <= current_date
                         and (ur.valid_to is null or ur.valid_to >= current_date)), false);
    msg_withdraw := coalesce(d.err_message, d.outcome::text, 'no answer')
      || format('; grants in force %s',
                (select count(*) from erp.user_role ur
                  where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_pending
                    and ur.valid_from <= current_date
                    and (ur.valid_to is null or ur.valid_to >= current_date)));

    v_step := 'the withdrawn link is presented';
    select count(*) into v_n from erp.invitation_for_resend(t_pending);
    perform set_config('request.jwt.claims', json_build_object('sub', s_stranger)::text, true);
    begin
      perform erp.claim_invitation(t_pending);
      msg_dead := 'the withdrawn link was redeemed';
      raise exception 'ZZ_ACCESS_SUITE_CLAIM_UNDO';
    exception when others then
      if sqlerrm <> 'ZZ_ACCESS_SUITE_CLAIM_UNDO' then
        ok_dead := sqlstate = '42501' and sqlerrm like '%INVITATION_NOT_OPEN%';
        msg_dead := left(sqlerrm, 120);
      end if;
    end;
    ok_dead := coalesce(ok_dead, false) and v_n = 0;
    msg_dead := format('%s resend row(s); claiming it: %s', v_n, coalesce(msg_dead, 'no answer'));

    v_step := 'the administrator withdraws the invitation of somebody who joined';
    select * into d from erp_test.access_door_as(s_admin, 'erp_withdraw_invitation', u_col);
    ok_joined := coalesce(d.err_state = '23514'
                          and d.err_message like 'CLOVEERP_INVITATION_NOT_PENDING%'
                          and d.err_hint like '%Remove access%', false)
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_col) = 'active';
    msg_joined := coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');

    v_step := 'the administrator invites the withdrawn address again';
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    select i.app_user_id, i.token into u_again, t_again
      from erp.invite_principal('pending@zzawa-' || v_tag || '.test', 'Pending Again') i;
    select count(*) into v_n from erp.invitation_for_resend(t_again);
    ok_again := coalesce(u_again = u_pending and v_n = 1
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_pending) = 'invited'
      and (select count(*) from erp.invitation_for_resend(t_pending)) = 0, false);
    msg_again := format('invited %s (the withdrawn record is %s); the new link finds %s invitation(s)',
                        u_again, u_pending, v_n);

    -- ── Removing access ──────────────────────────────────────────────────
    v_step := 'the colleague''s sign-in, before removal';
    perform set_config('request.jwt.claims', json_build_object('sub', s_col, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into v_resolves_before from erp.principal_context();
    execute format('set local role %I', v_owner);

    v_step := 'the administrator removes the colleague';
    select * into d from erp_test.access_door_as(s_admin, 'erp_remove_principal', u_col);
    ok_remove := coalesce(
      d.err_state is null
      and d.outcome ->> 'app_user_id' = u_col::text
      and d.outcome ->> 'status' = 'disabled'
      and d.outcome -> 'already_removed' = 'false'::jsonb
      and (d.outcome ->> 'grants_ended')::integer = 2
      and (d.outcome ->> 'invitations_withdrawn')::integer = 0
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_col) = 'disabled'
      and not exists (select 1 from erp.user_role ur
                       where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_col
                         and ur.valid_from <= current_date
                         and (ur.valid_to is null or ur.valid_to >= current_date))
      and exists (select 1 from erp.user_role ur
                    join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                   where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_col and r.code = 'inventory'
                     and ur.valid_from = current_date - 30 and ur.valid_to = current_date - 1)
      and not exists (select 1 from erp.user_role ur
                        join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                       where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_col and r.code = 'reporting'), false);
    msg_remove := coalesce(d.err_message, d.outcome::text, 'no answer')
      || format('; grants on file %s',
                (select string_agg(r.code || ' ' || ur.valid_from || '..' || coalesce(ur.valid_to::text, 'open'), ', ')
                   from erp.user_role ur join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                  where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_col));

    v_step := 'the colleague''s sign-in, after removal';
    perform set_config('request.jwt.claims', json_build_object('sub', s_col, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into v_resolves_after from erp.principal_context();
    execute format('set local role %I', v_owner);
    ok_signin := v_resolves_before = 1 and v_resolves_after = 0;
    msg_signin := format('the sign-in resolved to %s principal(s) before and %s after', v_resolves_before, v_resolves_after);

    v_step := 'the administrator removes themselves';
    select * into d from erp_test.access_door_as(s_admin, 'erp_remove_principal', u_admin);
    ok_self := coalesce(d.err_state = '42501'
                        and d.err_message like 'CLOVEERP_PRINCIPAL_SELF_REMOVAL%'
                        and d.err_hint like '%another administrator%', false)
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_admin) = 'active';
    msg_self := coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');

    v_step := 'the administrator removes the colleague again';
    select string_agg(t.v, ',' order by t.v) into v_before
      from (select 'u:' || u.xmin::text || ':' || u.status::text as v
              from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_col
            union all
            select 'g:' || ur.id::text || ':' || ur.xmin::text || ':' || coalesce(ur.valid_to::text, 'open')
              from erp.user_role ur where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_col
            union all
            select 'i:' || i.id::text || ':' || i.xmin::text || ':' || coalesce(i.revoked_at::text, 'open')
              from erp.invitation i where i.tenant_id = ra.tenant_id and i.app_user_id = u_col) t;
    select * into d from erp_test.access_door_as(s_admin, 'erp_remove_principal', u_col);
    select string_agg(t.v, ',' order by t.v) into v_after
      from (select 'u:' || u.xmin::text || ':' || u.status::text as v
              from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_col
            union all
            select 'g:' || ur.id::text || ':' || ur.xmin::text || ':' || coalesce(ur.valid_to::text, 'open')
              from erp.user_role ur where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_col
            union all
            select 'i:' || i.id::text || ':' || i.xmin::text || ':' || coalesce(i.revoked_at::text, 'open')
              from erp.invitation i where i.tenant_id = ra.tenant_id and i.app_user_id = u_col) t;
    ok_already := coalesce(
      d.err_state is null
      and d.outcome ->> 'status' = 'disabled'
      and d.outcome -> 'already_removed' = 'true'::jsonb
      and (d.outcome ->> 'grants_ended')::integer = 0
      and (d.outcome ->> 'invitations_withdrawn')::integer = 0
      and v_before = v_after, false);
    msg_already := coalesce(d.err_message, d.outcome::text, 'no answer')
      || case when v_before is not distinct from v_after then '; no row rewritten' else '; a row was rewritten' end;

    -- ── Restoring access ─────────────────────────────────────────────────
    v_step := 'the administrator restores the colleague';
    select * into d from erp_test.access_door_as(s_admin, 'erp_restore_principal', u_col);
    perform set_config('request.jwt.claims', json_build_object('sub', s_col, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into v_resolves_again from erp.principal_context();
    execute format('set local role %I', v_owner);
    ok_restore := coalesce(
      d.err_state is null
      and d.outcome ->> 'app_user_id' = u_col::text
      and d.outcome ->> 'status' = 'active'
      and (d.outcome ->> 'roles_restored')::integer = 0
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_col) = 'active'
      and not exists (select 1 from erp.user_role ur
                       where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_col
                         and ur.valid_from <= current_date
                         and (ur.valid_to is null or ur.valid_to >= current_date))
      and v_resolves_again = 1, false);
    msg_restore := coalesce(d.err_message, d.outcome::text, 'no answer')
      || format('; the sign-in resolves to %s principal(s)', v_resolves_again);

    v_step := 'the administrator withdraws the expired invitation, then restores that person';
    select * into d from erp_test.access_door_as(s_admin, 'erp_withdraw_invitation', u_expired);
    ok_never := coalesce(d.err_state is null and (d.outcome ->> 'invitations_withdrawn')::integer = 1, false);
    msg_never := 'withdraw: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.access_door_as(s_admin, 'erp_restore_principal', u_expired);
    ok_never := ok_never
      and coalesce(d.err_state = '23514'
                   and d.err_message like 'CLOVEERP_PRINCIPAL_NEVER_JOINED%'
                   and d.err_hint like '%nvite them again%', false)
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_expired) = 'disabled';
    msg_never := msg_never || '; restore: ' || coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');

    v_step := 'the administrator restores somebody who still has access';
    select * into d from erp_test.access_door_as(s_admin, 'erp_restore_principal', u_second);
    ok_active := coalesce(d.err_state = '23514'
                          and d.err_message like 'CLOVEERP_PRINCIPAL_NOT_REMOVED%'
                          and d.err_hint <> '', false);
    msg_active := coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');

    -- ── The last person who manages users ────────────────────────────────
    -- Platform support holds administrator, so it may ask; it does not count.
    v_step := 'platform support removes the only administrator';
    select * into d from erp_test.access_door_as(s_support, 'erp_remove_principal', u_admin);
    ok_last := coalesce(d.err_state = '23514'
                        and d.err_message like 'CLOVEERP_LAST_USER_MANAGER%'
                        and d.err_hint like '%administration.users%', false)
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_admin) = 'active'
      and erp.holds_user_management(ra.tenant_id, u_admin)
      and erp.holds_user_management(ra.tenant_id, u_support)
      and erp.user_managers_remaining(ra.tenant_id, null) = 1;
    msg_last := coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer')
      || format('; %s person(s) manage users, support not among them', erp.user_managers_remaining(ra.tenant_id, null));

    v_step := 'a second person is given administrator, and support removes the first again';
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    perform erp.grant_role(u_second, 'administrator', null, null, 'A second person who manages users.');
    select * into d from erp_test.access_door_as(s_support, 'erp_remove_principal', u_admin);
    ok_second := coalesce(
      d.err_state is null
      and d.outcome ->> 'app_user_id' = u_admin::text
      and d.outcome ->> 'status' = 'disabled'
      and d.outcome -> 'already_removed' = 'false'::jsonb
      and (d.outcome ->> 'grants_ended')::integer = 1
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_admin) = 'disabled'
      and erp.user_managers_remaining(ra.tenant_id, null) = 1
      and erp.holds_user_management(ra.tenant_id, u_second), false);
    msg_second := coalesce(d.err_message, d.outcome::text, 'no answer')
      || format('; %s person(s) manage users now', erp.user_managers_remaining(ra.tenant_id, null));

    -- ── Platform support is not the organisation's to restore ────────────
    v_step := 'the support window''s principal is disabled, and the second person restores it';
    perform set_config('request.jwt.claims', json_build_object('sub', s_second)::text, true);
    update erp.app_user u set status = 'disabled'
     where u.tenant_id = ra.tenant_id and u.id = u_support;
    select * into d from erp_test.access_door_as(s_second, 'erp_restore_principal', u_support);
    ok_support := coalesce(d.err_state = '42501'
                           and d.err_message like 'CLOVEERP_SUPPORT_PRINCIPAL_NOT_RESTORABLE%'
                           and d.err_hint like '%platform console%', false)
      and (select u.status::text from erp.app_user u where u.tenant_id = ra.tenant_id and u.id = u_support) = 'disabled';
    msg_support := coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_ACCESS_WITHDRAWAL_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_ACCESS_WITHDRAWAL_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 200));
    end if;
  end;

  case_name := 'the directory says who has signed in, where each invitation stands, who manages users and who is platform support';
  passed := v_state is null and coalesce(ok_dir, false);
  detail := coalesce(v_state, msg_dir, 'no answer');
  return next;

  case_name := 'withdrawing a pending invitation disables the person, revokes it with its reason and ends the role given before they joined';
  passed := v_state is null and coalesce(ok_withdraw, false);
  detail := coalesce(v_state, msg_withdraw, 'no answer');
  return next;

  case_name := 'a withdrawn link can neither be claimed nor sent again';
  passed := v_state is null and coalesce(ok_dead, false);
  detail := coalesce(v_state, msg_dead, 'no answer');
  return next;

  case_name := 'withdrawing the invitation of somebody who has joined is refused by name, and sends them to Remove access';
  passed := v_state is null and coalesce(ok_joined, false);
  detail := coalesce(v_state, msg_joined, 'no answer');
  return next;

  case_name := 'somebody whose invitation was withdrawn is invited again, to the same record';
  passed := v_state is null and coalesce(ok_again, false);
  detail := coalesce(v_state, msg_again, 'no answer');
  return next;

  case_name := 'removing an active person disables them, ends today''s role and ends yesterday the role held for a month, keeping it on file';
  passed := v_state is null and coalesce(ok_remove, false);
  detail := coalesce(v_state, msg_remove, 'no answer');
  return next;

  case_name := 'a removed person''s sign-in no longer resolves to a principal';
  passed := v_state is null and coalesce(ok_signin, false);
  detail := coalesce(v_state, msg_signin, 'no answer');
  return next;

  case_name := 'removing yourself is refused by name';
  passed := v_state is null and coalesce(ok_self, false);
  detail := coalesce(v_state, msg_self, 'no answer');
  return next;

  case_name := 'removing somebody already removed says so and rewrites nothing';
  passed := v_state is null and coalesce(ok_already, false);
  detail := coalesce(v_state, msg_already, 'no answer');
  return next;

  case_name := 'restoring a removed person who had signed in makes them active with no role in force, and their sign-in resolves again';
  passed := v_state is null and coalesce(ok_restore, false);
  detail := coalesce(v_state, msg_restore, 'no answer');
  return next;

  case_name := 'an expired invitation is withdrawn too, and restoring somebody who never joined is refused by name';
  passed := v_state is null and coalesce(ok_never, false);
  detail := coalesce(v_state, msg_never, 'no answer');
  return next;

  case_name := 'restoring somebody who still has access is refused by name';
  passed := v_state is null and coalesce(ok_active, false);
  detail := coalesce(v_state, msg_active, 'no answer');
  return next;

  case_name := 'removing the last person who manages users is refused by name, and platform support holding administrator does not count';
  passed := v_state is null and coalesce(ok_last, false);
  detail := coalesce(v_state, msg_last, 'no answer');
  return next;

  case_name := 'with a second person who manages users, the same removal goes through';
  passed := v_state is null and coalesce(ok_second, false);
  detail := coalesce(v_state, msg_second, 'no answer');
  return next;

  case_name := 'restoring a platform support principal is refused by name, and sends staff to the platform console';
  passed := v_state is null and coalesce(ok_support, false);
  detail := coalesce(v_state, msg_support, 'no answer');
  return next;

  case_name := 'somebody without administration.users is refused by all three doors';
  passed := v_state is null and coalesce(ok_denied, false);
  detail := coalesce(v_state, msg_denied, 'no answer');
  return next;

  case_name := 'a person in another organisation is not found by any of the three doors';
  passed := v_state is null and coalesce(ok_foreign, false);
  detail := coalesce(v_state, msg_foreign, 'no answer');
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in ('zzawa-' || v_tag, 'zzawb-' || v_tag));
  detail := 'two organisations, their people, grants, invitations and the support window rolled back';
  return next;
end;
$$;
revoke all on function erp_test.access_withdrawal_suite() from public, anon, authenticated;

create or replace function erp_test.assert_access_withdrawal_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 18;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.access_withdrawal_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ACCESS_WITHDRAWAL_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_ACCESS_WITHDRAWAL_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail;
  end if;
  return format('access withdrawal: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;
revoke all on function erp_test.assert_access_withdrawal_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_guidance_sound();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
select erp.assert_refusals_name_next_action();

select erp_test.assert_access_withdrawal_suite();
