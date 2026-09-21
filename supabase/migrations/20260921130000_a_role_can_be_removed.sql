set lock_timeout = '30s';

-- =============================================================================
-- 20260921130000  A role can be removed
-- -----------------------------------------------------------------------------
-- Nothing in the product could take a role out of use. erp.save_role edits and
-- creates; there is no door that removes; the permissions screen offered "New
-- role" and "Edit permissions" and nothing else. The one thing that retires a
-- role is a change-set item with operation = 'remove', which sets the role
-- inactive, and no screen or door authors one. So an organisation provisioned
-- with roles it did not choose could not get a clean list, and the two
-- ON DELETE RESTRICT keys that were always meant to refuse the removal of a
-- role somebody still depends on (erp.user_role and erp.approval_step) had no
-- product path that could reach them.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Read before writing, and where it changed the design
-- ─────────────────────────────────────────────────────────────────────────────
--
--   * erp.role and erp.role_permission are promotable surfaces (0017,
--     20260901130000). An organisation is live from the moment
--     erp.provision_tenant() finishes, and erp.guard_live_configuration()
--     refuses a direct insert, update or delete on either in a live
--     organisation. Only a change set may touch a role there. That is what
--     decided hard against soft: a hard DELETE would need a second mechanism
--     that walks round the guard.
--   * A hard delete would also be wrong on its merits. Four other tables point
--     at erp.role with ON DELETE CASCADE or SET NULL (notification routes,
--     report subscriptions, output channel rules, and the escalation of those
--     rules), so it would silently destroy configuration nobody was told
--     about; erp.approver_assignment names a role with no key at all, so it
--     would leave that dangling; and configuration here is effective-dated on
--     purpose — "a delete would take the history with it"
--     (20260901140000).
--   * erp.effective_permission already reads only roles that are active, so an
--     inactive role grants nothing. Soft removal is a complete removal for
--     everything that asks who may do what.
--   * erp.approval_step names a role in TWO columns, role_id and
--     escalate_to_role_id, and both are restrict keys.
--   * erp.grant_role() already refuses an inactive role
--     (CLOVEERP_UNKNOWN_ROLE), so a removed role cannot gain a holder later.
--   * The desk shows a registered refusal from its register — what was refused
--     and why — and the raise's HINT when it is written in plain words. It does
--     not show the raise's message. So which people and which approval steps are
--     holding a role has to be in the hint, or the customer is told "this role
--     is in use" and sent hunting, which is the failure this exists to avoid.
--
--   * The removal arm of the promoter could never have run. erp.apply_change_set_item()
--     declares a plpgsql variable called r, and the arm updated the role as
--     `update erp.role r ... where r.tenant_id = ...`, so the qualified column
--     resolved against the variable and not the table: "record r is not
--     assigned yet". It has been that way since the arm was written
--     (20260829280000); no suite ever removed a role, which is the same finding
--     as the unreachable restrict keys. The first version of this migration,
--     20260921120000, met it in its own suite and was never applied anywhere.
--     The arm is repaired here, before the suite that proves it.

-- ─────────────────────────────────────────────────────────────────────────────
-- What this does
-- ─────────────────────────────────────────────────────────────────────────────
--
-- 1. Removal is the existing soft path, and the door drives it. A new door,
--    public.erp_propose_role_removal(), authors one 'role' item with
--    operation = 'remove' in one change set and submits it, exactly as
--    public.erp_propose_approval_chain() does for a chain: promoted at once
--    while the organisation is being built, left for a second administrator
--    once it is live. It writes no role itself.
--
-- 2. The refusal the restrict keys were meant to make. erp.require_role_unheld()
--    refuses CLOVEERP_ROLE_IN_USE when somebody holds the role today (or from a
--    later date), or an approval step in a chain version that is in force or
--    being drafted names it as the approver or as where the step escalates. It
--    says which people, and which approval chain and which step, in the
--    message and in the hint. A grant that has ended, and a step in a version
--    that has been superseded, are history and do not hold a role.
--
--    It is called from the door, so the mistake is refused where it was made,
--    and from the promoter's remove arm, which is the authority: a change set
--    proposed while the role was free may be promoted after somebody was given
--    it, and a change set that arrives from another environment never passed
--    the door at all. A rollback to a snapshot is not held up, as it is not by
--    the last-person-who-manages-users rule beside it.
--
-- 3. A removed role stays removed. Applying a starter pack again used to bring
--    back a role the organisation had taken out of use, with the template's
--    grants and name, silently — the same defect 20260920630000 closed for an
--    edited role, arriving from the other side. A role that is inactive is now
--    named in the plan as "left alone, because this organisation has removed
--    it", and the applier skips it as it already skips one the organisation
--    changed. Nothing new is recorded: a role a template made and the
--    organisation took out of use IS the record.
--
-- 4. The directory says a removal is waiting, so a live organisation does not
--    propose the same removal twice while it waits for a second administrator.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does not do, and why
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The related finding — retiring a role silently orphans its approval steps — is
-- split, not folded in. Every route that retires a role is a 'remove' item, and
-- that item now refuses while a step names the role, so removal can no longer
-- orphan a step. What is left is not this change: steps that already name an
-- inactive role, a chain promoted from elsewhere whose steps name one (the
-- applier resolves role codes with no status filter), and erp.step_approvers(),
-- which resolves a role's holders without asking whether the role is active. A
-- standing report of those needs the three live organisations read before it
-- may refuse anything, and the last of them is a decision about what an
-- approval does, not about removing a role.
--
-- The role editor itself writes erp.role directly, so in a live organisation it
-- meets the same guard. That is not changed here either.
--
-- Proof: erp_test.a_role_can_be_removed_suite(), eleven cases, pinned at both
-- ends. Every case runs through the doors and the promoter.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Saying a list in words
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.list_in_words(p_items text[], p_total integer default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when coalesce(cardinality(p_items), 0) = 0 then ''
           when coalesce(p_total, cardinality(p_items)) > cardinality(p_items)
             then array_to_string(p_items, ', ') || ' and '
                  || (p_total - cardinality(p_items))::text || ' more'
           when cardinality(p_items) = 1 then p_items[1]
           else array_to_string(p_items[1:cardinality(p_items) - 1], ', ')
                || ' and ' || p_items[cardinality(p_items)]
         end
$$;

revoke all on function erp.list_in_words(text[], integer) from public, anon;

comment on function erp.list_in_words(text[], integer) is
  'A list as a person would say it: "a", "a and b", "a, b and c", and, when '
  'more exist than are named (p_total), "a, b and 3 more". Empty for nothing.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What still depends on a role
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Volatile, so that it counts what a promotion has already written in the same
-- transaction: a change set that gives a chain step this role and removes the
-- role in its next item has to be refused.

create or replace function erp.require_role_unheld(p_tenant uuid, p_role_code text)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_id        uuid;
  v_name      text;
  v_people    text[];
  v_n_people  integer;
  v_approves  text[];
  v_n_appr    integer;
  v_escalates text[];
  v_n_esc     integer;
  v_facts     text[] := '{}';
  v_todo      text[] := '{}';
begin
  select r.id, replace(coalesce(nullif(btrim(r.name), ''), r.code), '_', ' ')
    into v_id, v_name
    from erp.role r
   where r.tenant_id = p_tenant and r.code = p_role_code;
  if v_id is null then
    return;
  end if;

  -- Who holds it. A grant that has ended stays on file and holds nothing; one
  -- that begins later does, because removing the role would take it before it
  -- was ever used. Names, not ids, and never with an underscore in them: the
  -- desk hides a hint that reads like an identifier.
  select coalesce(array_agg(x.nm order by x.rn) filter (where x.rn <= 5), '{}'::text[]),
         count(*)::integer
    into v_people, v_n_people
    from (select p.nm, row_number() over (order by p.nm, p.id) as rn
            from (select distinct u.id,
                         replace(coalesce(nullif(btrim(u.display_name), ''),
                                          nullif(btrim(u.email), ''), 'somebody'),
                                 '_', ' ') as nm
                    from erp.user_role ur
                    join erp.app_user u
                      on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
                   where ur.tenant_id = p_tenant
                     and ur.role_id = v_id
                     and (ur.valid_to is null or ur.valid_to >= current_date)) p) x;

  -- The steps that ask it. Only a chain version that is in force or being
  -- drafted, in a chain that is not itself retired: a superseded version is
  -- history and cannot be edited, so it must not make a role unremovable.
  select coalesce(array_agg(x.said order by x.rn) filter (where x.rn <= 5), '{}'::text[]),
         count(*)::integer
    into v_approves, v_n_appr
    from (select s.said, row_number() over (order by s.said) as rn
            from (select distinct
                         format('step "%s" of the "%s" approval chain',
                                replace(coalesce(nullif(btrim(st.name), ''), st.code), '_', ' '),
                                replace(coalesce(nullif(btrim(c.name), ''), c.code), '_', ' ')) as said
                    from erp.approval_step st
                    join erp.approval_chain_version v
                      on v.tenant_id = st.tenant_id and v.id = st.approval_chain_version_id
                    join erp.approval_chain c
                      on c.tenant_id = v.tenant_id and c.id = v.approval_chain_id
                   where st.tenant_id = p_tenant
                     and st.role_id = v_id
                     and v.status in ('draft', 'active')
                     and c.status not in ('inactive', 'archived')) s) x;

  -- And the steps that escalate to it, which are a second restrict key.
  select coalesce(array_agg(x.said order by x.rn) filter (where x.rn <= 5), '{}'::text[]),
         count(*)::integer
    into v_escalates, v_n_esc
    from (select s.said, row_number() over (order by s.said) as rn
            from (select distinct
                         format('step "%s" of the "%s" approval chain',
                                replace(coalesce(nullif(btrim(st.name), ''), st.code), '_', ' '),
                                replace(coalesce(nullif(btrim(c.name), ''), c.code), '_', ' ')) as said
                    from erp.approval_step st
                    join erp.approval_chain_version v
                      on v.tenant_id = st.tenant_id and v.id = st.approval_chain_version_id
                    join erp.approval_chain c
                      on c.tenant_id = v.tenant_id and c.id = v.approval_chain_id
                   where st.tenant_id = p_tenant
                     and st.escalate_to_role_id = v_id
                     and v.status in ('draft', 'active')
                     and c.status not in ('inactive', 'archived')) s) x;

  if v_n_people = 0 and v_n_appr = 0 and v_n_esc = 0 then
    return;
  end if;

  if v_n_people > 0 then
    v_facts := v_facts || ('it is held by ' || erp.list_in_words(v_people, v_n_people));
    v_todo  := v_todo  || ('take the role from ' || erp.list_in_words(v_people, v_n_people)
                           || ' under People and permissions');
  end if;
  if v_n_appr > 0 then
    v_facts := v_facts || ('it is the approver in ' || erp.list_in_words(v_approves, v_n_appr));
    v_todo  := v_todo  || ('change ' || erp.list_in_words(v_approves, v_n_appr)
                           || ' so that it names another role');
  end if;
  if v_n_esc > 0 then
    v_facts := v_facts || ('it is the escalation point for ' || erp.list_in_words(v_escalates, v_n_esc));
    v_todo  := v_todo  || ('choose another escalation role for ' || erp.list_in_words(v_escalates, v_n_esc));
  end if;

  raise exception 'CLOVEERP_ROLE_IN_USE: the % role cannot be removed: %',
    v_name, array_to_string(v_facts, '; ')
    using errcode = '23503',
          hint = 'Before removing it, ' || erp.list_in_words(v_todo) || '.';
end;
$$;

revoke all on function erp.require_role_unheld(uuid, text) from public, anon;

comment on function erp.require_role_unheld(uuid, text) is
  'Refuses CLOVEERP_ROLE_IN_USE when a role is still depended on, and says by '
  'whom: the people who hold it (a grant that has ended holds nothing) and the '
  'approval chain steps that name it as their approver or as where they '
  'escalate to (a step in a superseded version holds nothing). The message and '
  'the hint both carry the names, because the desk shows the hint. Silent when '
  'nothing depends on the role or there is no such role. Called by the door '
  'that proposes a removal and by the promoter when a removal is promoted '
  '(20260921130000).';

select erp.register_refusal('CLOVEERP_ROLE_IN_USE',
  'Removing a role that people still hold or that an approval step still names.',
  'A role gives its holders what they may do, and a role an approval step names is who that step asks. Taking it out of use would strip those people and leave the step asking nobody, so the role stays until nothing depends on it.',
  'Take the role from the people who hold it under People and permissions, and change any approval chain step that names it to name another role. Then remove it again.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The promoter refuses it too
-- ═════════════════════════════════════════════════════════════════════════════
--
-- By needle into the body the database carries, asserted to occur exactly once.
-- 20260914074000 wrote this arm; nothing after it touches it. The refusal sits
-- inside the test that already skips a rollback, and before the check that
-- somebody can still manage users, because "held by these people" is the more
-- useful thing to be told first.

do $promoter$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n   constant text := $n$          if position('function erp.' || 'rollback_to_snapshot(' in v_managers_stack) = 0 then
            perform erp.require_user_managers_remain(v_tenant, v_managers_before,
              format('Taking the %s role out of use', p ->> 'code'));
$n$;
  -- The update itself. The alias is not r: this function declares a variable of
  -- that name for its own item loop, and a qualified column is resolved against
  -- the variable before the table, so the arm failed on its first row.
  v_n2  constant text := $n$          update erp.role r set status = 'inactive', updated_at = now()
           where r.tenant_id = v_tenant and r.code = (p ->> 'code');
$n$;
  v_r2  constant text := $r$          update erp.role ro set status = 'inactive', updated_at = now()
           where ro.tenant_id = v_tenant and ro.code = (p ->> 'code');
$r$;
  v_r   constant text := $r$          if position('function erp.' || 'rollback_to_snapshot(' in v_managers_stack) = 0 then
            -- Nobody holds it and no approval step names it (20260921130000).
            -- A change set proposed while the role was free may be promoted
            -- after somebody was given it, and one from another environment
            -- never passed the door that asks.
            perform erp.require_role_unheld(v_tenant, p ->> 'code');
            perform erp.require_user_managers_remain(v_tenant, v_managers_before,
              format('Taking the %s role out of use', p ->> 'code'));
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role removal arm of % is not the text this migration patches', v_sig
      using hint = 'A later migration changed the role arm. Read pg_get_functiondef() of the promoter and patch that body.';
  end if;
  if (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role update of the removal arm of % is not the text this migration repairs', v_sig
      using hint = 'A later migration changed the role arm. Read pg_get_functiondef() of the promoter and patch that body.';
  end if;
  execute replace(replace(v_def, v_n, v_r), v_n2, v_r2);

  if position('erp.require_role_unheld(' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position('update erp.role ro set status' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the promoter did not take the refusal to remove a role that is in use'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the promoter.';
  end if;
end
$promoter$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A removed role is left alone by a starter pack
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20260920630000 taught the planner to name a role the organisation changed as
-- "left alone" and taught the applier to skip whatever the plan says that
-- about. A role the organisation has taken out of use is the same case: it is
-- not in the configuration manifest (which lists roles that are active), so the
-- planner read it as missing and offered to create it, and the promoter's
-- upsert then set it active again and replaced its grants. Both needles are
-- from the text that migration wrote.

do $planner$
declare
  v_sig constant text := 'erp.plan_content_pack(text)';
  v_def text := pg_get_functiondef('erp.plan_content_pack(text)'::regprocedure);
  v_n1  constant text := $n$    left join erp.role held
      on i.object_kind = 'role'
     and held.tenant_id = erp.require_tenant_id()
     and held.code = i.object_key
     and held.status = 'active'
$n$;
  v_r1  constant text := $r$    left join erp.role held
      on i.object_kind = 'role'
     and held.tenant_id = erp.require_tenant_id()
     and held.code = i.object_key
     and held.status = 'active'
    -- A role this organisation has taken out of use (20260921130000). It is not
    -- in the manifest, which lists the roles that are active, so without this
    -- it reads as missing and a pack would put it back.
    left join erp.role removed
      on i.object_kind = 'role'
     and removed.tenant_id = erp.require_tenant_id()
     and removed.code = i.object_key
     and removed.status = 'inactive'
$r$;
  v_n2  constant text := $n$              when m.object_key is null then 'creates' else 'updates' end,$n$;
  v_r2  constant text := $r$              when i.object_kind = 'role' and removed.id is not null
              then 'left alone, because this organisation has removed it'
              when m.object_key is null then 'creates' else 'updates' end,$r$;
begin
  -- The word appears in a comment of the planner, so the test is for the alias
  -- being used as one, not for the word.
  if v_def ~ '\mremoved\.[a-z_]' then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: the pack planner already uses the name this migration adds to it'
      using hint = 'A later migration changed the planner. Read pg_get_functiondef() of it and patch that body.';
  end if;
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1 then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: the pack planner does not join the roles the organisation holds the way this migration patches'
      using hint = 'A later migration changed the planner. Read pg_get_functiondef() of it and patch that body.';
  end if;
  v_def := replace(v_def, v_n1, v_r1);

  if (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: the pack planner does not say what it will do with an item the way this migration patches'
      using hint = 'A later migration changed the planner. Read pg_get_functiondef() of it and patch that body.';
  end if;
  v_def := replace(v_def, v_n2, v_r2);

  execute v_def;

  if position('left alone, because this organisation has removed it'
              in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: the pack planner did not take the rule about a role that has been removed'
      using hint = 'The replacement did not land. Compare the needle with the definition the database carries.';
  end if;
end
$planner$;

comment on function erp.plan_content_pack is
  'What applying this pack would add to this organisation, and nothing it '
  'already holds — by containment against the configuration manifest, and by '
  'the pack history for the master-data kinds the manifest deliberately omits. '
  'Capability-gated items are left out when their capability is off; a '
  'decision that has been answered carries the answer. A role is offered '
  'against the name the organisation gave it, so renaming one never makes it '
  'look missing; a role the organisation has changed since a template wrote it '
  'is listed as left alone rather than dropped from the plan; and so is a role '
  'the organisation has removed, which a pack does not bring back '
  '(20260921130000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The directory says a removal is waiting
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Same signature and return type, so the grants stay. Needle into the text
-- 20260914020000 wrote, which nothing has changed since.

do $directory$
declare
  v_sig constant text := 'public.erp_permissions_directory()';
  v_def text := pg_get_functiondef('public.erp_permissions_directory()'::regprocedure);
  v_n   constant text := $n$'description', r.description, 'status', r.status,$n$;
  v_r   constant text := $r$'description', r.description, 'status', r.status,
               'removal_waiting', exists (
                 select 1
                   from erp.change_set_item csi
                   join erp.change_set cs
                     on cs.tenant_id = csi.tenant_id and cs.id = csi.change_set_id
                  where csi.tenant_id = r.tenant_id
                    and csi.object_kind = 'role'
                    and csi.object_key = r.code
                    and csi.operation = 'remove'
                    and cs.status in ('draft', 'ready', 'approved')),$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_DIRECTORY_UNRECOGNISED: the role list of % is not the text this migration patches', v_sig
      using hint = 'A later migration changed the directory. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('removal_waiting' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_DIRECTORY_UNRECOGNISED: the directory did not take the removal that is waiting'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the directory.';
  end if;
end
$directory$;

comment on function public.erp_permissions_directory() is
  'The organisation''s principals, roles, grants and the permission catalogue, '
  'under administration.roles. Each principal carries has_signed_in, invited_at '
  'and invitation_expires_at of their newest open invitation, invitation_state '
  '(pending, expired or none), manages_users (administration.users '
  'organisation-wide today, whatever their status) and is_support. Each role '
  'carries removal_waiting, true while a change that removes it has been '
  'proposed and not yet promoted (20260921130000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The door
-- ═════════════════════════════════════════════════════════════════════════════
--
-- It authors the change; it does not make it. The role is a promotable surface,
-- so a live organisation refuses a direct write, and the door writes none.

create or replace function public.erp_propose_role_removal(
  p_role_id uuid,
  p_note    text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid;
  v_role    erp.role%rowtype;
  v_name    text;
  v_note    text := nullif(btrim(coalesce(p_note, '')), '');
  v_cs      uuid;
  v_status  text;
  v_waiting boolean := false;
begin
  perform erp.authorise('administration.roles', null, null, null, 'role', p_role_id);
  -- Removing a role is a change of configuration, and the change set asks for
  -- this itself; asked here as well so the refusal comes before any work.
  perform erp.authorise('administration.configure', null, null, null,
                        'change_set', null);
  v_tenant := erp.require_tenant_id();

  select * into v_role
    from erp.role r
   where r.tenant_id = v_tenant and r.id = p_role_id;
  if not found then
    raise exception 'CLOVEERP_VALIDATION: role not found in this tenant'
      using errcode = '22023',
            hint = 'Refresh the list of roles. It may belong to another organisation.';
  end if;
  v_name := coalesce(nullif(btrim(v_role.name), ''), v_role.code);

  -- Already out of use: nothing to propose, and saying so is not a failure.
  if v_role.status = 'inactive' then
    return jsonb_build_object(
      'role_id', v_role.id, 'code', v_role.code, 'name', v_name,
      'change_set_id', null, 'status', 'promoted', 'removed', true,
      'already_waiting', false);
  end if;

  -- Refused here, where the mistake was made, rather than at a promotion the
  -- author has already walked away from. The promoter asks again.
  perform erp.require_role_unheld(v_tenant, v_role.code);

  -- A removal already proposed and not yet promoted is that removal, not a
  -- second one to approve.
  select cs.id into v_cs
    from erp.change_set cs
    join erp.change_set_item i
      on i.tenant_id = cs.tenant_id and i.change_set_id = cs.id
   where cs.tenant_id = v_tenant
     and cs.status in ('draft', 'ready', 'approved')
     and i.object_kind = 'role'
     and i.object_key = v_role.code
     and i.operation = 'remove'
   order by cs.created_at desc
   limit 1;

  if v_cs is not null then
    v_waiting := true;
  else
    -- One change set, one item, submitted. The code carries the clock because a
    -- role may be removed, brought back and removed again.
    v_cs := erp.create_change_set(
      format('remove-role-%s-%s', lower(v_role.code),
             to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')),
      format('Remove role: %s', v_name),
      coalesce(v_note,
               format('Take the %s role out of use. Nobody holds it and no approval step names it.',
                      v_name)));

    perform erp.add_change_set_item(
      v_cs, 'role', v_role.code,
      jsonb_build_object('code', v_role.code),
      'remove'::erp.change_operation, null::date, v_note);

    perform erp.submit_change_set(v_cs);

    -- erp.install_module_config()'s tail, and erp_propose_approval_chain()'s:
    -- before an organisation declares itself live there is no second person to
    -- ask; afterwards a second administrator approves it.
    if not erp.tenant_is_live() then
      perform erp.approve_change_set(v_cs);
      perform erp.promote_change_set(v_cs);
    end if;
  end if;

  select cs.status::text into v_status
    from erp.change_set cs
   where cs.tenant_id = v_tenant and cs.id = v_cs;

  return jsonb_build_object(
    'role_id', v_role.id,
    'code', v_role.code,
    'name', v_name,
    'change_set_id', v_cs,
    'status', v_status,
    'removed', v_status = 'promoted',
    'already_waiting', v_waiting);
end;
$$;

comment on function public.erp_propose_role_removal(uuid, text) is
  'Under administration.roles and administration.configure: takes a role out of '
  'use, by proposing the change-set item that does it (operation remove, which '
  'sets the role inactive and keeps its grants on file). Refused with '
  'CLOVEERP_ROLE_IN_USE, naming the people and the approval chain steps, while '
  'anybody holds the role or a step names it. Promoted at once while the '
  'organisation is being set up; left for a second administrator once it is '
  'live. A removal already waiting is returned, not proposed again. Writes no '
  'role itself: erp.role is a promotable surface (20260921130000).';

revoke all on function public.erp_propose_role_removal(uuid, text) from public, anon;
grant execute on function public.erp_propose_role_removal(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_propose_role_removal', 'erp.authorise',
   'Proposes taking a role out of use as one B6 change set under '
   'administration.roles and administration.configure, and submits it. It '
   'writes no promotable surface: erp.role is written by '
   'erp.apply_change_set_item() on promotion, which is the only route a live '
   'organisation accepts, and the promoter refuses a removal while the role is '
   'held or named (20260921130000).')
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

-- The two sentences the Roles panel adds, each with the row it is renamed by.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Removing a role takes it out of use: it stops appearing here, nobody can be given it again, and a starter pack will not bring it back. Whoever holds it, and any approval step that names it, has to be moved first.',
     'What the panel says before a role is removed.'),
    ('Removal proposed. This organisation is live, so a second administrator approves it on the Configuration screen before the role goes.',
     'Said after a removal is proposed in an organisation that is live.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.en), 'de', v.de,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Removing a role takes it out of use: it stops appearing here, nobody can be given it again, and a starter pack will not bring it back. Whoever holds it, and any approval step that names it, has to be moved first.',
     'Wird eine Rolle entfernt, ist sie außer Betrieb: Sie erscheint hier nicht mehr, niemand kann sie erneut erhalten, und ein Startpaket bringt sie nicht zurück. Wer sie innehat und welcher Genehmigungsschritt sie nennt, muss zuvor umgestellt werden.',
     'What the panel says before a role is removed.'),
    ('Removal proposed. This organisation is live, so a second administrator approves it on the Configuration screen before the role goes.',
     'Entfernung vorgeschlagen. Diese Organisation ist live; ein zweiter Administrator genehmigt sie auf dem Konfigurationsbildschirm, bevor die Rolle entfällt.',
     'Said after a removal is proposed in an organisation that is live.')
  ) as v(en, de, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.apply_execute_grants() is not optional: the door reaches two new routines
-- and the promoter one, and a routine a door reaches that was never granted
-- fails at runtime on a live database while a build from an empty cluster says
-- nothing at all.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_governed_views_are_safe();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_resource_coverage('en');

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- One organisation, run in two halves. Before it is live the door promotes what
-- it proposes and the roles can be written directly, so the fixture is built
-- then; afterwards the same door stops at submitted and only a second
-- administrator can promote, which is the half that matters. The pack is the
-- route a customer's removal has to survive, and it is walked the way
-- 20260920630000 walks it: applied, approved by a second person, promoted.

create or replace function erp_test.a_role_can_be_removed_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  v_cases   integer := 0;
  v_step    text := 'before the fixture started';
  v_state   text;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 8);
  r         record;
  res       jsonb;
  res2      jsonb;
  a1        uuid := gen_random_uuid();   -- the first administrator
  a2        uuid := gen_random_uuid();   -- the second: B6 refuses self-approval once live
  v_holder  uuid;
  v_second  uuid; v_tok text;
  v_free    uuid; v_held uuid; v_approver uuid; v_escalate uuid; v_history uuid;
  v_live    uuid; v_race uuid; v_tpl uuid;
  v_ok      boolean; v_msg text; v_hint text;
  v_cs      uuid;
  v_pack    text;
  v_effect  text;
  v_perms_before integer; v_perms_after integer;
  v_waiting boolean;
begin
  begin
  -- ── The organisation, before it is live ──────────────────────────────────
  v_step := 'provisioning the organisation';
  perform set_config('request.jwt.claims', '', true);
  select * into r from erp.provision_tenant(
    'zzrr-' || v_tag, 'Role Removal',
    'admin@zzrr-' || v_tag || '.test', 'Removal Admin');
  update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

  insert into auth.users (id, email) values
    (a1, 'admin@zzrr-' || v_tag || '.test'),
    (a2, 'second@zzrr-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_step := 'a person and the roles';
  select p.app_user_id into v_holder
    from erp.invite_principal('holder@zzrr-' || v_tag || '.test', 'Hattie Holder') p;

  v_free     := (public.erp_save_role(null, 'zz_free', 'Free role', 'Nobody holds it.',
                   array['reporting.read']) ->> 'role_id')::uuid;
  v_held     := (public.erp_save_role(null, 'zz_held', 'Held role', 'Somebody holds it.',
                   array['reporting.read']) ->> 'role_id')::uuid;
  v_approver := (public.erp_save_role(null, 'zz_approver', 'Approver role', 'An approval step names it.',
                   array['reporting.read']) ->> 'role_id')::uuid;
  v_escalate := (public.erp_save_role(null, 'zz_escalate', 'Escalation role', 'An approval step escalates to it.',
                   array['reporting.read']) ->> 'role_id')::uuid;
  v_history  := (public.erp_save_role(null, 'zz_history', 'History role', 'Only history names it.',
                   array['reporting.read']) ->> 'role_id')::uuid;
  perform public.erp_save_role(null, 'zz_history_next', 'History replacement', 'What the old step became.',
                   array['reporting.read']);
  v_live     := (public.erp_save_role(null, 'zz_live', 'Live role', 'Removed after go-live.',
                   array['reporting.read']) ->> 'role_id')::uuid;
  v_race     := (public.erp_save_role(null, 'zz_race', 'Race role', 'Free when proposed, held when promoted.',
                   array['reporting.read']) ->> 'role_id')::uuid;

  v_step := 'giving one role a holder and two an approval step';
  perform erp.grant_role(v_holder, 'zz_held', null, null, 'the suite');

  -- One step that asks a role and escalates to another.
  perform public.erp_propose_approval_chain(
    'zz_steps', 'Suite approvals', 'document',
    jsonb_build_array(jsonb_build_object(
      'seq', 1, 'code', 'sign_off', 'name', 'Sign off',
      'role', 'zz_approver', 'escalate_after_hours', 24,
      'escalate_to_role', 'zz_escalate')));

  -- History: a grant that ended yesterday, and a step in a version that was
  -- superseded by a second version the same day.
  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, valid_to, grant_reason)
  values (r.tenant_id, v_holder, v_history, current_date - 10, current_date - 1, 'ended for the suite');
  perform public.erp_propose_approval_chain(
    'zz_history', 'History chain', 'document',
    jsonb_build_array(jsonb_build_object(
      'seq', 1, 'code', 'old', 'name', 'Old step', 'role', 'zz_history')));
  perform public.erp_propose_approval_chain(
    'zz_history', 'History chain', 'document',
    jsonb_build_array(jsonb_build_object(
      'seq', 1, 'code', 'new', 'name', 'New step', 'role', 'zz_history_next')));

  -- ── 1. A role nobody holds and nothing names is removed ──────────────────
  v_step := 'removing a role nobody holds, before go-live';
  v_cases := v_cases + 1;
  res := public.erp_propose_role_removal(v_free);
  select count(*) into v_perms_after from erp.role_permission rp where rp.role_id = v_free;
  v_ok := false; v_msg := 'it was accepted';
  begin
    perform erp.grant_role(v_holder, 'zz_free', null, null, 'the suite');
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_UNKNOWN_ROLE%'; v_msg := left(sqlerrm, 90);
  end;
  case_name := 'a role nobody holds and no approval names is removed, keeps its grants on file, and cannot be given to anybody again';
  passed := coalesce((res ->> 'status') = 'promoted'
                 and (res ->> 'removed')::boolean
                 and (select ro.status::text from erp.role ro where ro.id = v_free) = 'inactive'
                 and v_perms_after = 1
                 and v_ok
                 and not exists (select 1 from jsonb_array_elements(public.erp_roles()) e
                                  where e.value ->> 'code' = 'zz_free'), false);
  detail := format('the change set is %s; the role is %s, still carries %s grant(s), and granting it says %s',
                   coalesce(res ->> 'status', 'missing'),
                   coalesce((select ro.status::text from erp.role ro where ro.id = v_free), 'gone'),
                   v_perms_after, v_msg);
  return next;

  -- ── 2. A role somebody holds is refused, and the person is named ─────────
  v_step := 'removing a role somebody holds';
  v_cases := v_cases + 1;
  begin
    perform public.erp_propose_role_removal(v_held);
    v_ok := false; v_msg := 'it was accepted'; v_hint := null;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_ok := sqlerrm like 'CLOVEERP_ROLE_IN_USE%'; v_msg := sqlerrm;
  end;
  case_name := 'a role somebody holds is refused, and the refusal names the person in its message and in its hint';
  passed := coalesce(v_ok
                 and position('Hattie Holder' in v_msg) > 0
                 and position('Hattie Holder' in coalesce(v_hint, '')) > 0
                 and (select ro.status::text from erp.role ro where ro.id = v_held) = 'active', false);
  detail := format('%s — hint: %s', left(v_msg, 200), coalesce(left(v_hint, 200), 'none'));
  return next;

  -- ── 3. A role an approval step names is refused, and the step is named ───
  v_step := 'removing a role an approval step names';
  v_cases := v_cases + 1;
  begin
    perform public.erp_propose_role_removal(v_approver);
    v_ok := false; v_msg := 'it was accepted'; v_hint := null;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_ok := sqlerrm like 'CLOVEERP_ROLE_IN_USE%'; v_msg := sqlerrm;
  end;
  case_name := 'a role an approval step names is refused, and the refusal says which chain and which step';
  passed := coalesce(v_ok
                 and position('Sign off' in v_msg) > 0
                 and position('Suite approvals' in v_msg) > 0
                 and position('Suite approvals' in coalesce(v_hint, '')) > 0, false);
  detail := format('%s — hint: %s', left(v_msg, 200), coalesce(left(v_hint, 200), 'none'));
  return next;

  -- ── 4. So is one a step escalates to ────────────────────────────────────
  v_step := 'removing a role a step escalates to';
  v_cases := v_cases + 1;
  begin
    perform public.erp_propose_role_removal(v_escalate);
    v_ok := false; v_msg := 'it was accepted'; v_hint := null;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_ok := sqlerrm like 'CLOVEERP_ROLE_IN_USE%'; v_msg := sqlerrm;
  end;
  case_name := 'a role an approval step escalates to is refused as well, and is said to be the escalation point';
  passed := coalesce(v_ok
                 and position('escalation point' in v_msg) > 0
                 and position('Sign off' in v_msg) > 0, false);
  detail := left(v_msg, 240);
  return next;

  -- ── 5. History does not hold a role ─────────────────────────────────────
  v_step := 'removing a role only history names';
  v_cases := v_cases + 1;
  res := public.erp_propose_role_removal(v_history);
  case_name := 'a grant that ended and a step in a superseded version are history, and a role only they name is removed';
  passed := coalesce((res ->> 'status') = 'promoted'
                 and (select ro.status::text from erp.role ro where ro.id = v_history) = 'inactive', false);
  detail := format('the change set is %s and the role is %s',
                   coalesce(res ->> 'status', 'missing'),
                   coalesce((select ro.status::text from erp.role ro where ro.id = v_history), 'gone'));
  return next;

  -- ── The organisation goes live, with a second administrator ─────────────
  v_step := 'going live';
  select p.app_user_id, p.token into v_second, v_tok
    from erp.invite_principal('second@zzrr-' || v_tag || '.test', 'Second Admin') p;
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
  update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

  -- ── 6. Live, the same door stops at submitted ───────────────────────────
  v_step := 'proposing a removal in a live organisation';
  v_cases := v_cases + 1;
  res := public.erp_propose_role_removal(v_live);
  v_cs := (res ->> 'change_set_id')::uuid;
  res2 := public.erp_propose_role_removal(v_live);
  select coalesce((e.value ->> 'removal_waiting')::boolean, false) into v_waiting
    from jsonb_array_elements(public.erp_permissions_directory() -> 'roles') e
   where e.value ->> 'code' = 'zz_live';
  case_name := 'in a live organisation a removal waits for a second administrator, changes nothing until then, and is not proposed twice';
  passed := coalesce((res ->> 'status') = 'ready'
                 and not (res ->> 'removed')::boolean
                 and (select ro.status::text from erp.role ro where ro.id = v_live) = 'active'
                 and (res2 ->> 'change_set_id')::uuid = v_cs
                 and (res2 ->> 'already_waiting')::boolean
                 and v_waiting, false);
  detail := format('the change set is %s, the role is still %s, the second ask returned the same change set: %s, and the directory says a removal is waiting: %s',
                   coalesce(res ->> 'status', 'missing'),
                   coalesce((select ro.status::text from erp.role ro where ro.id = v_live), 'gone'),
                   (res2 ->> 'change_set_id')::uuid = v_cs, v_waiting);
  return next;

  -- ── 7. And a second administrator takes it out of use ───────────────────
  v_step := 'a second administrator promotes the removal';
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  select coalesce((e.value ->> 'removal_waiting')::boolean, false) into v_waiting
    from jsonb_array_elements(public.erp_permissions_directory() -> 'roles') e
   where e.value ->> 'code' = 'zz_live';
  case_name := 'once a second administrator promotes it the role is out of use, and nothing is waiting any more';
  passed := coalesce((select ro.status::text from erp.role ro where ro.id = v_live) = 'inactive'
                 and not v_waiting, false);
  detail := format('the role is %s and a removal is waiting: %s',
                   coalesce((select ro.status::text from erp.role ro where ro.id = v_live), 'gone'), v_waiting);
  return next;

  -- ── 8. The promoter asks again, and is the authority ────────────────────
  v_step := 'a role is given away while its removal waits';
  v_cases := v_cases + 1;
  res := public.erp_propose_role_removal(v_race);
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.grant_role(v_holder, 'zz_race', null, null, 'given while the removal waits');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  begin
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'it was promoted'; v_hint := null;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_ok := sqlerrm like '%CLOVEERP_ROLE_IN_USE%'; v_msg := sqlerrm;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  case_name := 'a removal proposed while the role was free is refused at promotion once somebody holds it, naming them';
  passed := coalesce(v_ok
                 and position('Hattie Holder' in v_msg) > 0
                 and (select ro.status::text from erp.role ro where ro.id = v_race) = 'active', false);
  detail := left(v_msg, 240);
  return next;

  -- ── A starter pack with one role template ───────────────────────────────
  v_step := 'a starter pack carrying one role template';
  v_pack := 'zzpack_' || v_tag;
  insert into erp_ref.content_pack
    (code, name, description, kind, version, provenance, seq)
  values (v_pack, 'Suite template pack',
          'One role template, so that a suite can watch a pack meet a role that was removed.',
          'base', '1.0.0',
          'A fixture of erp_test.a_role_can_be_removed_suite(). Not shipped: it '
          'is created and rolled back inside the suite.', 900);
  insert into erp_ref.pack_item
    (pack_code, object_kind, object_key, payload, provenance, seq)
  values (v_pack, 'role', 'zz_tpl',
          jsonb_build_object('code', 'zz_tpl', 'name', 'Template role',
            'from_template', v_pack || '-1.0.0',
            'permissions', jsonb_build_array(
              jsonb_build_object('permission', 'inventory.read'),
              jsonb_build_object('permission', 'reporting.read'))),
          'A fixture of the role removal suite.', 10);

  res := erp.apply_content_pack(v_pack);
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_step := 'removing the role the template made';
  select ro.id into v_tpl from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'zz_tpl';
  select count(*) into v_perms_before from erp.role_permission rp where rp.role_id = v_tpl;
  res := public.erp_propose_role_removal(v_tpl);
  v_cs := (res ->> 'change_set_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- ── 9. The plan says the pack will leave it alone ───────────────────────
  v_step := 'planning the pack again';
  v_cases := v_cases + 1;
  select p.effect into v_effect from erp.plan_content_pack(v_pack) p
   where p.object_key = 'zz_tpl';
  case_name := 'a role the template made and the organisation removed is named in the plan as left alone';
  passed := coalesce((select ro.status::text from erp.role ro where ro.id = v_tpl) = 'inactive'
                 and v_effect = 'left alone, because this organisation has removed it', false);
  detail := format('the role is %s and the plan said "%s"',
                   coalesce((select ro.status::text from erp.role ro where ro.id = v_tpl), 'gone'),
                   coalesce(v_effect, 'nothing'));
  return next;

  -- ── 10. And applying the pack does not bring it back ────────────────────
  v_step := 'applying the pack again';
  v_cases := v_cases + 1;
  -- A role the pack has not installed yet, so it still has something to do: a
  -- change set with nothing in it is refused before it can be promoted, which
  -- would prove nothing about what the pack does to a role it must leave alone.
  insert into erp_ref.pack_item
    (pack_code, object_kind, object_key, payload, provenance, seq)
  values (v_pack, 'role', 'zz_extra',
          jsonb_build_object('code', 'zz_extra', 'name', 'Extra role',
            'from_template', v_pack || '-1.0.0',
            'permissions', jsonb_build_array(
              jsonb_build_object('permission', 'reporting.read'))),
          'A fixture of the role removal suite.', 20);
  res := erp.apply_content_pack(v_pack);
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  select count(*) into v_perms_after from erp.role_permission rp where rp.role_id = v_tpl;
  case_name := 'applying the pack again leaves a removed role out of use with its grants as they were, and still installs what is new';
  passed := coalesce((select ro.status::text from erp.role ro where ro.id = v_tpl) = 'inactive'
                 and v_perms_after = v_perms_before
                 and not exists (select 1 from erp.change_set_item i
                                  where i.change_set_id = v_cs and i.object_key = 'zz_tpl')
                 and exists (select 1 from erp.role ro
                              where ro.tenant_id = r.tenant_id and ro.code = 'zz_extra'
                                and ro.status = 'active'), false);
  detail := format('the role is %s and holds %s grant(s), as it did before (%s); the new role is %s',
                   coalesce((select ro.status::text from erp.role ro where ro.id = v_tpl), 'gone'),
                   v_perms_after, v_perms_before,
                   coalesce((select ro.status::text from erp.role ro
                              where ro.tenant_id = r.tenant_id and ro.code = 'zz_extra'), 'missing'));
  return next;

  perform set_config('request.jwt.claims', '', true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  -- ── 11. Undone ──────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzrr-' || v_tag)
        and not exists (select 1 from erp_ref.content_pack c where c.code = 'zzpack_' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2));
  detail := coalesce(v_state,
                     'the organisation, its roles, its chains and the fixture pack all rolled back');
  return next;

  if v_cases <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: a_role_can_be_removed_suite ran % case(s), expected 11; the fixture stopped %',
      v_cases, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.a_role_can_be_removed_suite() from public, anon;

comment on function erp_test.a_role_can_be_removed_suite() is
  'What removing a role does and refuses. Nobody holding it and no approval step '
  'naming it, as the approver or as where a step escalates, lets it go, and a '
  'grant that ended or a step in a superseded version does not hold it; a role '
  'that is held or named is refused with the people or the chain and step named '
  'in the message and in the hint; a live organisation''s removal waits for a '
  'second administrator, is not proposed twice, and is refused again at '
  'promotion if somebody was given the role in between; and a starter pack '
  'leaves a role the organisation removed out of use. Rolls back everything it '
  'made.';

create or replace function erp_test.assert_a_role_can_be_removed_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _a_role_can_be_removed on commit drop as
    select * from erp_test.a_role_can_be_removed_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _a_role_can_be_removed;
  drop table _a_role_can_be_removed;
  if v_fail > 0 then
    raise exception E'CLOVEERP_A_ROLE_CAN_BE_REMOVED_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'Read the failed case. Either a role that something depends on was let go, one nothing depends on was held, or a starter pack brought back a role an organisation removed.';
  end if;
  if v_all <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: a_role_can_be_removed_suite ran % case(s), expected 11', v_all
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a role can be removed: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_a_role_can_be_removed_suite() from public, anon;

select erp.apply_execute_grants();

select erp_test.assert_a_role_can_be_removed_suite();

select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_isolation();
