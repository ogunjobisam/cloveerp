set lock_timeout = '30s';

-- =============================================================================
-- 20260922110000  A role is proposed, not saved
-- -----------------------------------------------------------------------------
-- The Roles panel's "New role" and "Edit permissions" call public.erp_save_role,
-- and erp_save_role wrote erp.role and erp.role_permission directly: an insert,
-- an update, and a delete of every permission the role held. Both tables are
-- promotable surfaces (erp_meta.promotable_surface, 20260901130000), so
-- erp.guard_live_configuration() refuses every one of those writes once the
-- organisation's own environment is live, unless a promotion window is open,
-- and a window is opened only by the promoter. An organisation is live from the
-- moment erp.provision_tenant() finishes (20260904800000) and a self-service
-- one from erp.go_live(). So in every organisation a customer actually uses, the
-- role editor answered CLOVEERP_LIVE_CONFIG_EDIT and could neither create a role
-- nor change one.
--
-- Nothing had noticed because nothing ran it there. The one suite that calls the
-- door (20260901140000) builds its role before go-live and says why: "erp.role
-- has carried the live-edit guard since 0017, so afterwards even this is a
-- change set". 20260914065000 says it again where it restated the door: "the
-- role editor writes only before go-live (the live guard refuses erp.role after
-- it)". Both wrote the limitation down and neither made the door meet it.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does
-- ─────────────────────────────────────────────────────────────────────────────
--
-- 1. The door stops writing and proposes. public.erp_save_role() keeps its
--    signature and its answer's role_id, and authors one 'role' change-set item
--    and submits it, as public.erp_propose_approval_chain() does for a chain:
--    before the organisation is live it approves and promotes at once, because
--    there is nobody else to ask; afterwards it stops at submitted, and the
--    change is approved on the Configuration screen: by a second person, or by
--    its author where the organisation lets administrators approve their own
--    changes, which it does unless it has switched that off (20260914098000).
--    The screen therefore says the change waits for approval, not who gives it.
--    The door writes no role itself, so there is no route round the guard to
--    keep in step with it.
--
--    Replaced, not kept beside a proposing door. Kept as it was, it would be a
--    second writer of the same rows that the promoter also writes, and the two
--    would drift (the grant set, the description, the data classes); a door that
--    works only before go-live and refuses everywhere else is exactly the defect
--    being repaired. The name stays because a suite, the operator's scripts and
--    the screen call it, and because none of them needs to know the difference:
--    what they get back says whether the change is in force.
--
-- 2. What the editor settled before it settles now, where the change lands.
--    The last-person-who-manages-users rule (erp.require_user_managers_remain)
--    and the separation-of-duties settling (erp.role_duties_before,
--    erp.settle_role_duties) sit inside the promoter's role arm since
--    20260914065000 and 20260914074000, and the door now reaches that arm on
--    every save, so they apply to the role editor exactly as they apply to a
--    pack or a promotion. Before go-live that is at once, in the same
--    transaction, and a refusal leaves no change set behind. Once live it is
--    when the change is promoted, so a proposal that would take the
--    last person's user management away, or give a holder both sides of a
--    prohibited pairing, is accepted and then refused at promotion. That is
--    later than the door could say it; saying it at the door needs the change
--    applied to know what it does, which is the promoter's job, and is not
--    duplicated here.
--
-- 3. The promoter's role arm writes a role's description. It never did: the
--    editor wrote it directly, and a pack's role carries none. It now sets it
--    when the item names one and leaves it alone when the item does not, so a
--    pack meeting a role an organisation described does not blank it.
--
-- 4. Three things the direct writes did that the door now does deliberately:
--
--    * A code that already exists is refused, removed roles included. The
--      promoter's arm is an upsert, so without this a new role whose code was a
--      removed role's would quietly bring it back with the new grants.
--    * A role that has been removed cannot be edited. The arm sets status active,
--      so an edit would have reopened it.
--    * An edit keeps the data classes a permission is already narrowed to. The
--      direct write deleted every grant and reinserted each with none, and
--      "empty means every data class" (0003): saving a role for its name widened
--      a narrowed grant to all of them. Nothing said so. The change set carries
--      the classes, and a permission that stays keeps its own.
--
--    An edit that changes nothing proposes nothing, so an approver is not asked
--    to wave through a change that is not one.
--
-- 5. The directory says a change is waiting (change_waiting), beside
--    removal_waiting where that exists, so a live organisation can see a
--    proposal is on its way instead of proposing it twice. It does not refuse a
--    second proposal for the same role: a change set cannot be withdrawn, only
--    approved, so refusing would leave a wrong proposal in the way of its
--    correction.
--
-- What this does not do: a proposal for a NEW role is not in the directory until
-- it is promoted, because it is not a role until then; the screen says so when it
-- is proposed and the Configuration screen lists it. And a role change set is the
-- whole role, replaced wholesale on promotion, so two proposals for one role
-- approved out of order leave the earlier one standing. That is how every
-- 'upsert' item behaves and is the change-set model's to fix, not this door's.
--
-- Proof: erp_test.a_role_is_proposed_suite(), twelve cases, the door called
-- before and after go-live, the promoter reached through it both times.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The promoter's role arm writes a description
-- ═════════════════════════════════════════════════════════════════════════════
--
-- By counted replacement into the body the database carries. The arm is the one
-- 20260914061500 wrote and nothing after it touches these lines; the needle is
-- asserted to occur exactly once. The target is aliased so the update can name
-- the row it is replacing.

do $promoter$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n   constant text := $n$          insert into erp.role (tenant_id, code, name, name_key, from_template)
          values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'from_template')
          on conflict (tenant_id, code) do update
            set name = excluded.name, name_key = excluded.name_key,
                status = 'active', updated_at = now()
          returning id into v_obj;
$n$;
  v_r   constant text := $r$          -- A role the item describes carries its description when the item says
          -- one and keeps the one it has when it does not (20260922110000): a
          -- pack's role names none, and must not blank what somebody wrote.
          insert into erp.role as rl (tenant_id, code, name, name_key, description, from_template)
          values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'name_key', p ->> 'description', p ->> 'from_template')
          on conflict (tenant_id, code) do update
            set name = excluded.name, name_key = excluded.name_key,
                description = case when p ? 'description' then excluded.description else rl.description end,
                status = 'active', updated_at = now()
          returning id into v_obj;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role arm of % is not the text this migration patches', v_sig
      using hint = 'A later migration changed the role arm. Read pg_get_functiondef() of the promoter and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('rl.description' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the promoter did not take the role description'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the promoter.';
  end if;
end
$promoter$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The directory says a change is waiting
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Same signature and return type, so the grants stay. The needle is the one
-- 20260914020000 wrote and the replacement keeps it as its own first line, so
-- this and a change that patches the same line compose in either order. The
-- comment is appended to rather than rewritten for the same reason.

do $directory$
declare
  v_sig constant text := 'public.erp_permissions_directory()';
  v_def text := pg_get_functiondef('public.erp_permissions_directory()'::regprocedure);
  v_n   constant text := $n$'description', r.description, 'status', r.status,$n$;
  v_r   constant text := $r$'description', r.description, 'status', r.status,
               'change_waiting', exists (
                 select 1
                   from erp.change_set_item csi
                   join erp.change_set cs
                     on cs.tenant_id = csi.tenant_id and cs.id = csi.change_set_id
                  where csi.tenant_id = r.tenant_id
                    and csi.object_kind = 'role'
                    and csi.object_key = r.code
                    and csi.operation = 'upsert'
                    and cs.status in ('draft', 'ready', 'approved')),$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_DIRECTORY_UNRECOGNISED: the role list of % is not the text this migration patches', v_sig
      using hint = 'A later migration changed the directory. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('change_waiting' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_DIRECTORY_UNRECOGNISED: the directory did not take the change that is waiting'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the directory.';
  end if;

  execute format('comment on function public.erp_permissions_directory() is %L',
    coalesce(obj_description(v_sig::regprocedure, 'pg_proc'), '')
    || ' Each role carries change_waiting, true while a change that creates or '
    || 'alters it has been proposed and not yet promoted (20260922110000).');
end
$directory$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The door
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Same signature and return type as 20260914074000, so the grants stay. It
-- authors the change; it does not make it.

create or replace function public.erp_save_role(p_role_id uuid, p_code text, p_name text, p_description text, p_permissions text[])
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid;
  v_role    erp.role%rowtype;
  v_code    text;
  v_name    text := btrim(coalesce(p_name, ''));
  v_desc    text := nullif(btrim(coalesce(p_description, '')), '');
  v_wanted  text[];
  v_current text[] := '{}';
  v_added   text[] := '{}';
  v_dropped text[] := '{}';
  v_key     text;
  v_items   jsonb;
  v_summary text;
  v_cs      uuid;
  v_status  text;
  v_id      uuid;
begin
  perform erp.authorise('administration.roles');
  -- The change set asks for this itself; asked here as well so the refusal
  -- comes before any work.
  perform erp.authorise('administration.configure', null, null, null,
                        'change_set', null);
  v_tenant := erp.require_tenant_id();

  if v_name = '' then
    raise exception 'CLOVEERP_VALIDATION: role name is required'
      using hint = 'Give the role a name people will recognise.';
  end if;

  select coalesce(array_agg(distinct perm order by perm), '{}'::text[])
    into v_wanted
    from unnest(coalesce(p_permissions, '{}'::text[])) perm;

  if exists (select 1
               from unnest(v_wanted) perm
              where not exists (select 1 from erp_ref.permission p where p.code = perm)) then
    raise exception 'CLOVEERP_VALIDATION: unknown permission code'
      using hint = 'Choose permissions from the list the screen offers.';
  end if;

  if p_role_id is null then
    v_code := btrim(coalesce(p_code, ''));
    if v_code = '' then
      raise exception 'CLOVEERP_VALIDATION: role code is required'
        using hint = 'Give the role a short code, such as stock-clerk.';
    end if;
    -- The promoter's arm is an upsert: a code already here, removed or not,
    -- would be overwritten rather than refused.
    if exists (select 1 from erp.role r where r.tenant_id = v_tenant and r.code = v_code) then
      raise exception 'CLOVEERP_VALIDATION: a role with this code already exists'
        using hint = 'Choose a different code. A role that was removed keeps its code, so that code cannot be used again.';
    end if;
    v_key := 'role.' || replace(v_code, '-', '_') || '.name';
    v_summary := format('Create the %s role (%s), holding %s.', v_name, v_code,
                        case when cardinality(v_wanted) = 0 then 'no permissions'
                             else array_to_string(v_wanted, ', ') end);
  else
    select * into v_role
      from erp.role r
     where r.tenant_id = v_tenant and r.id = p_role_id;
    if not found then
      raise exception 'CLOVEERP_VALIDATION: role not found in this tenant'
        using hint = 'Refresh the list of roles. It may belong to another organisation.';
    end if;
    -- The promoter sets a role it describes active, so an edit would reopen it.
    if v_role.status <> 'active' then
      raise exception 'CLOVEERP_VALIDATION: this role has been removed'
        using hint = 'A removed role cannot be changed. Create a new role with a different code instead.';
    end if;

    v_code := v_role.code;
    v_key  := v_role.name_key;

    select coalesce(array_agg(rp.permission_code order by rp.permission_code), '{}'::text[])
      into v_current
      from erp.role_permission rp
     where rp.tenant_id = v_tenant and rp.role_id = v_role.id;
    v_added   := coalesce((select array_agg(w order by w)
                             from unnest(v_wanted) w where w <> all (v_current)), '{}'::text[]);
    v_dropped := coalesce((select array_agg(c order by c)
                             from unnest(v_current) c where c <> all (v_wanted)), '{}'::text[]);

    -- Nothing to approve.
    if btrim(coalesce(v_role.name, '')) = v_name
       and nullif(btrim(coalesce(v_role.description, '')), '') is not distinct from v_desc
       and cardinality(v_added) = 0 and cardinality(v_dropped) = 0 then
      return jsonb_build_object(
        'role_id', v_role.id, 'code', v_code, 'name', v_name,
        'change_set_id', null, 'status', 'promoted',
        'in_force', true, 'unchanged', true);
    end if;

    v_summary := concat_ws(' ',
      format('Change the %s role.', coalesce(nullif(btrim(v_role.name), ''), v_code)),
      case when btrim(coalesce(v_role.name, '')) <> v_name
           then format('It is renamed %s.', v_name) end,
      case when nullif(btrim(coalesce(v_role.description, '')), '') is distinct from v_desc
           then 'Its description changes.' end,
      case when cardinality(v_added) > 0
           then format('It gains %s.', array_to_string(v_added, ', ')) end,
      case when cardinality(v_dropped) > 0
           then format('It loses %s.', array_to_string(v_dropped, ', ')) end);
  end if;

  -- The grant set the role will hold. A permission it holds already keeps the
  -- data classes it is narrowed to; empty means every class, so writing none
  -- would widen it.
  select coalesce(jsonb_agg(jsonb_build_object(
           'permission', w,
           'data_classes', to_jsonb(coalesce(
             (select rp.data_classes
                from erp.role_permission rp
               where rp.tenant_id = v_tenant
                 and rp.role_id = v_role.id
                 and rp.permission_code = w), '{}'::text[]))) order by w), '[]'::jsonb)
    into v_items
    from unnest(v_wanted) w;

  -- One change set, one item, submitted. The code carries the clock because a
  -- role is amended as often as the organisation changes.
  v_cs := erp.create_change_set(
    format('role-%s-%s', lower(v_code),
           to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS')),
    case when p_role_id is null then format('New role: %s', v_name)
         else format('Change role: %s', v_name) end,
    v_summary);

  perform erp.add_change_set_item(
    v_cs, 'role', v_code,
    jsonb_build_object(
      'code', v_code,
      'name', v_name,
      'name_key', v_key,
      'description', v_desc,
      'permissions', v_items),
    'upsert'::erp.change_operation, null::date, null::text);

  perform erp.submit_change_set(v_cs);

  -- erp.install_module_config()'s tail, and erp_propose_approval_chain()'s:
  -- before an organisation declares itself live there is no second person for
  -- the control to find. Afterwards the set is left submitted, because who may
  -- do what is precisely the change that should be seen before it is in force.
  -- The promoter's role arm settles the last person who manages users and the
  -- separation of duties of everybody holding the role, both ways.
  if not erp.tenant_is_live() then
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
  end if;

  select cs.status::text into v_status
    from erp.change_set cs
   where cs.tenant_id = v_tenant and cs.id = v_cs;

  select r.id into v_id
    from erp.role r
   where r.tenant_id = v_tenant and r.code = v_code;

  return jsonb_build_object(
    'role_id', v_id,
    'code', v_code,
    'name', v_name,
    'change_set_id', v_cs,
    'status', v_status,
    'in_force', v_status = 'promoted',
    'unchanged', false);
end;
$$;

comment on function public.erp_save_role(uuid, text, text, text, text[]) is
  'Under administration.roles and administration.configure: creates a role or '
  'changes an existing one''s name, description and permissions, by proposing '
  'the one change-set item that does it. Promoted at once while the '
  'organisation is being set up; left submitted once it is live, for approval on '
  'the Configuration screen. Returns role_id (null while a new role is only proposed), change_set_id, '
  'status, in_force and unchanged. A code that exists, removed or not, and a '
  'removed role are refused; a permission a role already holds keeps the data '
  'classes it is narrowed to. Writes no role itself: erp.role and '
  'erp.role_permission are promotable surfaces, and the promoter''s role arm '
  'keeps somebody able to manage users and settles the duties of everybody '
  'holding the role (20260922110000).';

update erp_meta.public_write_allowance a
   set gate = 'erp.authorise',
       rationale = 'Proposes a role, or a change to one, as one B6 change set under '
                   'administration.roles and administration.configure, and submits it. '
                   'It writes no promotable surface: erp.role and erp.role_permission are '
                   'written by erp.apply_change_set_item() on promotion, which is the '
                   'only route a live organisation accepts (20260922110000).'
 where a.function_name = 'erp_save_role';
do $allowance$
declare
  v_n integer;
begin
  select count(*) into v_n from erp_meta.public_write_allowance a where a.function_name = 'erp_save_role';
  if v_n <> 1 then
    raise exception 'CLOVEERP_WRITE_ALLOWANCE_NOT_UPDATED: erp_save_role has % write allowance row(s), expected 1', v_n
      using hint = 'The row is written by 20260829180000 and reworded by 20260914065000. If row security refused the update, the migration role has lost its bypass.';
  end if;
end
$allowance$;

-- The sentence the Roles panel adds, with the row it is renamed by.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Role change proposed. This organisation is live, so the change takes effect once it has been approved on the Configuration screen.',
     'Said after a role is created or changed in an organisation that is live.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.en), 'de', v.de,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Role change proposed. This organisation is live, so the change takes effect once it has been approved on the Configuration screen.',
     'Rollenänderung vorgeschlagen. Diese Organisation ist live; die Änderung wird wirksam, sobald sie auf dem Konfigurationsbildschirm genehmigt wurde.',
     'Said after a role is created or changed in an organisation that is live.')
  ) as v(en, de, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- No new routine, so nothing new to grant; run anyway, as every migration does,
-- because a generator that is idempotent costs nothing and one that was skipped
-- costs a live deploy.

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
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_resource_coverage('en');

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- One organisation, run in two halves. Before it is live the door promotes what
-- it proposes, so the fixture is built then; afterwards the same door stops at
-- submitted and a change waits to be approved, which is the half that was
-- broken. The organisation is one that wants two-person sign-off, as the suites
-- that prove an approval do (erp_test.administrator_approval_off), because
-- otherwise its administrator approves their own change and nothing is left to
-- refuse. The two rules the editor used to settle by itself are proved where
-- they now live, through the door and the promoter, in both halves.


create or replace function erp_test.a_role_is_proposed_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  v_cases    integer := 0;
  v_step     text := 'before the fixture started';
  v_state    text;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 8);
  r          record;
  res        jsonb;
  a1         uuid := gen_random_uuid();   -- the first administrator
  a2         uuid := gen_random_uuid();   -- the second: B6 refuses self-approval once live
  v_second   uuid; v_tok text;
  v_holder   uuid;
  v_new      uuid; v_gone uuid; v_admin_role uuid; v_poster uuid;
  v_cs_new   uuid; v_cs_edit uuid; v_cs_admin uuid; v_cs_poster uuid;
  v_perms    text[];          -- the administrator role's permissions, less user management
  v_edit_perms text[];
  v_poster_perms text[];
  v_classes_kept text; v_classes_added text;
  v_admin_name text; v_admin_desc text;
  v_ok       boolean; v_msg text;
  ok_a boolean; ok_b boolean; ok_c boolean; ok_d boolean; ok_e boolean;
  msg_a text; msg_b text; msg_c text; msg_d text; msg_e text;
  v_n1       integer; v_n2 integer;
  v_waiting  boolean;
begin
  begin
  -- ── The organisation, before it is live ──────────────────────────────────
  v_step := 'provisioning the organisation';
  perform set_config('request.jwt.claims', '', true);
  select * into r from erp.provision_tenant(
    'zzrp-' || v_tag, 'Role Proposal',
    'admin@zzrp-' || v_tag || '.test', 'Proposal Admin');
  perform set_config('erp.job_tenant_id', '', true);
  perform erp_test.reopen_bootstrap_window(r.tenant_id);

  insert into auth.users (id, email) values
    (a1, 'admin@zzrp-' || v_tag || '.test'),
    (a2, 'second@zzrp-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  -- Two-person approval is what this organisation proves (20260914098000).
  perform erp_test.administrator_approval_off(r.tenant_id);

  v_step := 'a second administrator, the base pack''s duty rules and four narrow roles';
  select i.app_user_id, i.token into v_second, v_tok
    from erp.invite_principal('second@zzrp-' || v_tag || '.test', 'Second Admin') i;
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  perform erp_test.duties_rules_and_roles(r.tenant_id);
  select i.app_user_id into v_holder
    from erp.invite_principal('pete@zzrp-' || v_tag || '.test', 'Pete Poster') i;
  perform erp.grant_role(v_holder, 'zz_poster', null, null, 'posts journals');
  select ro.id into v_poster
    from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'zz_poster';
  select ro.id, ro.name, ro.description into v_admin_role, v_admin_name, v_admin_desc
    from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'administrator';
  select array_agg(rp.permission_code order by rp.permission_code) into v_perms
    from erp.role_permission rp
   where rp.role_id = v_admin_role and rp.permission_code <> 'administration.users';

  -- ── 1. A role is in force at once before go-live ─────────────────────────
  v_step := 'creating a role, before go-live';
  v_cases := v_cases + 1;
  res := public.erp_save_role(null, 'zz_new', 'New role', 'What it is for.',
                              array['reporting.read', 'inventory.read']);
  v_new := (res ->> 'role_id')::uuid;
  select count(*) into v_n1 from erp.role_permission rp where rp.role_id = v_new;
  case_name := 'before go-live a new role is in force at once, with the description and permissions it was given, through a change set that was promoted';
  passed := coalesce((res ->> 'status') = 'promoted'
                 and (res ->> 'in_force')::boolean
                 and v_new is not null
                 and (select ro.description from erp.role ro where ro.id = v_new) = 'What it is for.'
                 and (select ro.name_key from erp.role ro where ro.id = v_new) = 'role.zz_new.name'
                 and v_n1 = 2
                 and exists (select 1
                               from erp.change_set cs
                               join erp.change_set_item i on i.change_set_id = cs.id
                              where cs.tenant_id = r.tenant_id
                                and cs.code like 'role-zz_new-%'
                                and cs.status::text = 'promoted'
                                and i.object_kind = 'role' and i.object_key = 'zz_new'), false);
  detail := format('the change set is %s, the role %s, it holds %s permission(s) and its description is "%s"',
                   coalesce(res ->> 'status', 'missing'),
                   case when v_new is null then 'does not exist' else 'exists' end, v_n1,
                   coalesce((select ro.description from erp.role ro where ro.id = v_new), 'missing'));
  return next;

  -- ── 2. An edit keeps the classes a permission is narrowed to ─────────────
  v_step := 'editing a role, before go-live';
  v_cases := v_cases + 1;
  update erp.role_permission set data_classes = array['cost']
   where role_id = v_new and permission_code = 'inventory.read';
  res := public.erp_save_role(v_new, 'ignored', 'Renamed role', 'What it is now for.',
                              array['inventory.read', 'sales.read']);
  select array_agg(rp.permission_code order by rp.permission_code),
         max(case when rp.permission_code = 'inventory.read' then array_to_string(rp.data_classes, ',') end),
         max(case when rp.permission_code = 'sales.read' then array_to_string(rp.data_classes, ',') end)
    into v_edit_perms, v_classes_kept, v_classes_added
    from erp.role_permission rp
   where rp.role_id = v_new;
  case_name := 'an edit before go-live replaces the permissions and the name, leaves the code alone, and a permission that stays keeps the data classes it is narrowed to';
  passed := coalesce((res ->> 'status') = 'promoted'
                 and (res ->> 'in_force')::boolean
                 and v_edit_perms = array['inventory.read', 'sales.read']
                 and v_classes_kept = 'cost'
                 and coalesce(v_classes_added, '') = ''
                 and (select ro.name from erp.role ro where ro.id = v_new) = 'Renamed role'
                 and (select ro.description from erp.role ro where ro.id = v_new) = 'What it is now for.'
                 and (select ro.code from erp.role ro where ro.id = v_new) = 'zz_new'
                 and (select ro.name_key from erp.role ro where ro.id = v_new) = 'role.zz_new.name', false);
  detail := format('it now holds %s; inventory.read is still narrowed to "%s" and sales.read to "%s"',
                   coalesce(array_to_string(v_edit_perms, ', '), 'nothing'),
                   coalesce(v_classes_kept, 'missing'), coalesce(v_classes_added, 'missing'));
  return next;

  -- ── 3. What the door refuses ─────────────────────────────────────────────
  v_step := 'the refusals';
  v_cases := v_cases + 1;
  res := public.erp_save_role(null, 'zz_gone', 'Gone role', null, array['reporting.read']);
  v_gone := (res ->> 'role_id')::uuid;
  update erp.role set status = 'inactive' where id = v_gone;

  begin
    perform public.erp_save_role(null, 'zz_bad', 'Bad', null, array['no.such_permission']);
    ok_a := false; msg_a := 'it was accepted';
  exception when others then
    ok_a := sqlerrm like 'CLOVEERP_VALIDATION%unknown permission%'; msg_a := left(sqlerrm, 80);
  end;
  begin
    perform public.erp_save_role(null, 'zz_bad', '  ', null, array['reporting.read']);
    ok_b := false; msg_b := 'it was accepted';
  exception when others then
    ok_b := sqlerrm like 'CLOVEERP_VALIDATION%role name is required%'; msg_b := left(sqlerrm, 80);
  end;
  begin
    perform public.erp_save_role(null, 'zz_new', 'Twice', null, array['reporting.read']);
    ok_c := false; msg_c := 'it was accepted';
  exception when others then
    ok_c := sqlerrm like 'CLOVEERP_VALIDATION%already exists%'; msg_c := left(sqlerrm, 80);
  end;
  begin
    perform public.erp_save_role(null, 'zz_gone', 'Brought back', null, array['reporting.read']);
    ok_d := false; msg_d := 'it was accepted';
  exception when others then
    ok_d := sqlerrm like 'CLOVEERP_VALIDATION%already exists%'; msg_d := left(sqlerrm, 80);
  end;
  begin
    perform public.erp_save_role(v_gone, null, 'Gone role', null, array['reporting.read', 'sales.read']);
    ok_e := false; msg_e := 'it was accepted';
  exception when others then
    ok_e := sqlerrm like 'CLOVEERP_VALIDATION%has been removed%'; msg_e := left(sqlerrm, 80);
  end;
  case_name := 'the door refuses an unknown permission, a blank name, a code that is taken, the code of a removed role, and an edit to a removed role, and proposes nothing for any of them';
  passed := coalesce(ok_a and ok_b and ok_c and ok_d and ok_e
                 and (select ro.status::text from erp.role ro where ro.id = v_gone) = 'inactive'
                 and (select count(*) from erp.role_permission rp where rp.role_id = v_gone) = 1
                 and not exists (select 1 from erp.change_set cs
                                  where cs.tenant_id = r.tenant_id and cs.code like 'role-zz_bad-%')
                 and (select count(*) from erp.change_set cs
                       where cs.tenant_id = r.tenant_id and cs.code like 'role-zz_gone-%') = 1, false);
  detail := format('unknown permission: %s | blank name: %s | taken code: %s | removed role''s code: %s | edit to a removed role: %s',
                   msg_a, msg_b, msg_c, msg_d, msg_e);
  return next;

  -- ── 4. An edit that changes nothing proposes nothing ─────────────────────
  v_step := 'saving a role as it already is';
  v_cases := v_cases + 1;
  select count(*) into v_n1 from erp.change_set cs where cs.tenant_id = r.tenant_id;
  res := public.erp_save_role(v_new, null, 'Renamed role', 'What it is now for.',
                              array['sales.read', 'inventory.read']);
  select count(*) into v_n2 from erp.change_set cs where cs.tenant_id = r.tenant_id;
  case_name := 'saving a role as it already is proposes nothing, and says so';
  passed := coalesce((res ->> 'unchanged')::boolean
                 and (res ->> 'in_force')::boolean
                 and (res ->> 'change_set_id') is null
                 and v_n1 = v_n2, false);
  detail := format('the answer said unchanged: %s; the organisation held %s change set(s) before and %s after',
                   coalesce(res ->> 'unchanged', 'missing'), v_n1, v_n2);
  return next;

  -- ── 5. Nobody is left unable to manage users, before go-live ─────────────
  v_step := 'taking user management from the administrator role, before go-live';
  v_cases := v_cases + 1;
  select count(*) into v_n1 from erp.role_permission rp where rp.role_id = v_admin_role;
  select count(*) into v_n2 from erp.change_set cs where cs.tenant_id = r.tenant_id;
  begin
    perform public.erp_save_role(v_admin_role, null, v_admin_name, v_admin_desc, v_perms);
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := sqlerrm like '%CLOVEERP_LAST_USER_MANAGER%'; v_msg := left(sqlerrm, 160);
  end;
  case_name := 'before go-live a change that would leave nobody able to manage users is refused, and leaves the role and the change sets as they were';
  passed := coalesce(v_ok
                 and 'administration.users' <> all (v_perms)
                 and (select count(*) from erp.role_permission rp where rp.role_id = v_admin_role) = v_n1
                 and (select count(*) from erp.change_set cs where cs.tenant_id = r.tenant_id) = v_n2, false);
  detail := v_msg;
  return next;

  -- ── The organisation goes live ───────────────────────────────────────────
  v_step := 'going live';
  perform erp_test.close_bootstrap_window(r.tenant_id);

  -- ── 6. Live, a new role is proposed and not written ──────────────────────
  v_step := 'proposing a new role in a live organisation';
  v_cases := v_cases + 1;
  res := public.erp_save_role(null, 'zz_live_new', 'Live new role', 'Proposed live.',
                              array['reporting.read']);
  v_cs_new := (res ->> 'change_set_id')::uuid;
  begin
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_direct', 'Direct', 'active');
    v_ok := false; v_msg := 'accepted, so the guard is not what this suite believes it is';
  exception when others then
    v_ok := sqlerrm like '%LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 80);
  end;
  case_name := 'in a live organisation a new role is proposed, not written: the door does not meet the guard, the role does not exist yet, and a direct write still does';
  passed := coalesce((res ->> 'status') = 'ready'
                 and not (res ->> 'in_force')::boolean
                 and (res ->> 'role_id') is null
                 and not exists (select 1 from erp.role ro
                                  where ro.tenant_id = r.tenant_id and ro.code = 'zz_live_new')
                 and exists (select 1 from erp.change_set_item i
                              where i.change_set_id = v_cs_new and i.object_kind = 'role'
                                and i.object_key = 'zz_live_new' and i.operation::text = 'upsert')
                 and v_ok, false);
  detail := format('the change set is %s and the role %s; a direct insert: %s',
                   coalesce(res ->> 'status', 'missing'),
                   case when exists (select 1 from erp.role ro
                                      where ro.tenant_id = r.tenant_id and ro.code = 'zz_live_new')
                        then 'exists' else 'does not exist yet' end,
                   v_msg);
  return next;

  -- ── 7. Live, an edit waits and changes nothing ───────────────────────────
  v_step := 'proposing an edit in a live organisation';
  v_cases := v_cases + 1;
  res := public.erp_save_role(v_new, null, 'Live renamed', 'Live description.',
                              array['inventory.read', 'reporting.read']);
  v_cs_edit := (res ->> 'change_set_id')::uuid;
  select coalesce((e.value ->> 'change_waiting')::boolean, false) into v_waiting
    from jsonb_array_elements(public.erp_permissions_directory() -> 'roles') e
   where e.value ->> 'code' = 'zz_new';
  select array_agg(rp.permission_code order by rp.permission_code) into v_edit_perms
    from erp.role_permission rp where rp.role_id = v_new;
  case_name := 'in a live organisation an edit waits for approval, changes nothing until then, and the directory says a change is waiting';
  passed := coalesce((res ->> 'status') = 'ready'
                 and not (res ->> 'in_force')::boolean
                 and (select ro.name from erp.role ro where ro.id = v_new) = 'Renamed role'
                 and v_edit_perms = array['inventory.read', 'sales.read']
                 and v_waiting, false);
  detail := format('the change set is %s, the role is still "%s" holding %s, and the directory says a change is waiting: %s',
                   coalesce(res ->> 'status', 'missing'),
                   coalesce((select ro.name from erp.role ro where ro.id = v_new), 'gone'),
                   coalesce(array_to_string(v_edit_perms, ', '), 'nothing'), v_waiting);
  return next;

  -- ── 8. The author may not approve it; a second administrator does ────────
  v_step := 'the author and then the second administrator act on the edit';
  v_cases := v_cases + 1;
  begin
    perform erp.approve_change_set(v_cs_edit);
    v_ok := false; v_msg := 'the author approved their own change';
  exception when others then
    v_ok := sqlerrm like '%SELF_APPROVAL%'; v_msg := left(sqlerrm, 100);
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs_edit);
  perform erp.promote_change_set(v_cs_edit);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  select array_agg(rp.permission_code order by rp.permission_code),
         max(case when rp.permission_code = 'inventory.read' then array_to_string(rp.data_classes, ',') end)
    into v_edit_perms, v_classes_kept
    from erp.role_permission rp where rp.role_id = v_new;
  select coalesce((e.value ->> 'change_waiting')::boolean, false) into v_waiting
    from jsonb_array_elements(public.erp_permissions_directory() -> 'roles') e
   where e.value ->> 'code' = 'zz_new';
  case_name := 'where two-person sign-off is wanted the author cannot approve their own proposal; once a second administrator promotes it the role is what was asked, keeps the classes it was narrowed to, and nothing is waiting';
  passed := coalesce(v_ok
                 and (select ro.name from erp.role ro where ro.id = v_new) = 'Live renamed'
                 and (select ro.description from erp.role ro where ro.id = v_new) = 'Live description.'
                 and v_edit_perms = array['inventory.read', 'reporting.read']
                 and v_classes_kept = 'cost'
                 and not v_waiting, false);
  detail := format('self-approval: %s; the role is now "%s" holding %s, inventory.read narrowed to "%s"; a change is waiting: %s',
                   v_msg,
                   coalesce((select ro.name from erp.role ro where ro.id = v_new), 'gone'),
                   coalesce(array_to_string(v_edit_perms, ', '), 'nothing'),
                   coalesce(v_classes_kept, 'missing'), v_waiting);
  return next;

  -- ── 9. And the proposed role comes into being ────────────────────────────
  v_step := 'the second administrator promotes the new role';
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs_new);
  perform erp.promote_change_set(v_cs_new);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  case_name := 'once a second administrator promotes it the proposed role exists, active, with its description and its permission';
  passed := coalesce((select ro.status::text from erp.role ro
                       where ro.tenant_id = r.tenant_id and ro.code = 'zz_live_new') = 'active'
                 and (select ro.description from erp.role ro
                       where ro.tenant_id = r.tenant_id and ro.code = 'zz_live_new') = 'Proposed live.'
                 and (select count(*) from erp.role_permission rp
                        join erp.role ro on ro.id = rp.role_id
                       where ro.tenant_id = r.tenant_id and ro.code = 'zz_live_new') = 1, false);
  detail := format('the role is %s',
                   coalesce((select ro.status::text from erp.role ro
                              where ro.tenant_id = r.tenant_id and ro.code = 'zz_live_new'), 'missing'));
  return next;

  -- ── 10. The promoter is still the authority on user management ───────────
  v_step := 'a live change that would take user management from everybody';
  v_cases := v_cases + 1;
  select count(*) into v_n1 from erp.role_permission rp where rp.role_id = v_admin_role;
  res := public.erp_save_role(v_admin_role, null, v_admin_name, v_admin_desc, v_perms);
  v_cs_admin := (res ->> 'change_set_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs_admin);
  begin
    perform erp.promote_change_set(v_cs_admin);
    v_ok := false; v_msg := 'it was promoted';
  exception when others then
    v_ok := sqlerrm like '%CLOVEERP_LAST_USER_MANAGER%'; v_msg := left(sqlerrm, 160);
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  case_name := 'a live proposal that would leave nobody able to manage users is accepted as a proposal and refused when it is promoted, and the role is as it was';
  passed := coalesce((res ->> 'status') = 'ready'
                 and v_ok
                 and (select count(*) from erp.role_permission rp where rp.role_id = v_admin_role) = v_n1, false);
  detail := format('the proposal was %s and promotion said: %s', coalesce(res ->> 'status', 'missing'), v_msg);
  return next;

  -- ── 11. So is it on a prohibited pairing ─────────────────────────────────
  v_step := 'a live change that would give a holder both sides of a prohibited rule';
  v_cases := v_cases + 1;
  select array_agg(rp.permission_code order by rp.permission_code) into v_poster_perms
    from erp.role_permission rp where rp.role_id = v_poster;
  res := public.erp_save_role(v_poster, null, 'Suite poster', null,
                              v_poster_perms || 'finance.close_period'::text);
  v_cs_poster := (res ->> 'change_set_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs_poster);
  begin
    perform erp.promote_change_set(v_cs_poster);
    v_ok := false; v_msg := 'it was promoted';
  exception when others then
    v_ok := sqlerrm like '%CLOVEERP_SOD_PROHIBITED%'; v_msg := left(sqlerrm, 160);
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  case_name := 'a live proposal that would give somebody holding the role both sides of a prohibited pairing is refused when it is promoted, and the role is as it was';
  passed := coalesce((res ->> 'status') = 'ready'
                 and v_ok
                 and (select count(*) from erp.role_permission rp where rp.role_id = v_poster)
                       = cardinality(v_poster_perms)
                 and not exists (select 1 from erp.role_permission rp
                                  where rp.role_id = v_poster and rp.permission_code = 'finance.close_period'), false);
  detail := format('the proposal was %s and promotion said: %s', coalesce(res ->> 'status', 'missing'), v_msg);
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

  -- ── 12. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzrp-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2));
  detail := coalesce(v_state,
                     'the organisation, its roles, its change sets and its people all rolled back');
  return next;

  if v_cases <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: a_role_is_proposed_suite ran % case(s), expected 12; the fixture stopped %',
      v_cases, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.a_role_is_proposed_suite() from public, anon;

comment on function erp_test.a_role_is_proposed_suite() is
  'What the role editor does in both halves of an organisation''s life. Before '
  'go-live a role is created and changed at once, an edit keeps the data classes '
  'a permission is narrowed to, and a change that would leave nobody able to '
  'manage users is refused with nothing left behind; the door refuses an unknown '
  'permission, a blank name, a code that is taken, a removed role''s code and an '
  'edit to a removed role, and proposes nothing when nothing changes. Once live '
  'the same door does not meet the live-edit guard: it proposes, the role is '
  'untouched until the change is promoted, where two-person sign-off is wanted '
  'the author cannot approve their own change, and the promoter still refuses a '
  'change that leaves nobody able to manage users or gives a holder both sides '
  'of a prohibited pairing. '
  'Rolls back everything it made.';

create or replace function erp_test.assert_a_role_is_proposed_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _a_role_is_proposed on commit drop as
    select * from erp_test.a_role_is_proposed_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _a_role_is_proposed;
  drop table _a_role_is_proposed;
  if v_fail > 0 then
    raise exception E'CLOVEERP_A_ROLE_IS_PROPOSED_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'Read the failed case. Either the role editor met the live-edit guard again, a change reached the promoter without the rules it applies to a role, or a role that was removed was brought back.';
  end if;
  if v_all <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: a_role_is_proposed_suite ran % case(s), expected 12', v_all
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a role is proposed: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_a_role_is_proposed_suite() from public, anon;

select erp.apply_execute_grants();

-- The suite is not run from here. It provisions an organisation and promotes a
-- dozen change sets, which costs what its fixture costs rather than what the
-- schema is, and a deploy replays this file against a database that has real
-- organisations in it (20260920310000, 20260921120000). The build runs it:
-- erp.ci_check_catalogue() picks up erp_test.assert_a_role_is_proposed_suite()
-- by name, and these two say so if it ever stops doing that.
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
