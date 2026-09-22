-- =============================================================================
-- An approval chain step cannot name a role that has been removed
--
-- 20260921140000 stops a role being removed while a chain step names it, as the
-- approver or as where the step escalates to. That closes the door a customer
-- walks through. Three things were left, and this closes two of them.
--
--   1. STEPS THAT ALREADY NAME A REMOVED ROLE. Nothing reports them, and there
--      is no way to know how many there are from inside the product.
--
--      Read on 21 September 2026, through the read-only route, before deciding:
--      three organisations, none with a removed role, none with a step naming
--      one, and no pending task assigned through one. The population today is
--      empty. That still does not make a refusing check safe, for a different
--      reason: erp.assert_whole_database_reconciles() runs every tenant-scoped
--      assertion against every organisation on live, so an assertion over this
--      data would fail the deploy's proof for one organisation's configuration.
--      And there is a route that writes such a step on purpose: a rollback to a
--      snapshot puts back what the snapshot held, and the snapshot may name a
--      role removed since. A check that fails because a rollback did what it was
--      asked would be a check nobody could keep.
--
--      So this is a REPORT, not an assertion. erp_meta.diagnostic_check already
--      has the kind: erp.platform_assurance() runs assertions and does not run
--      a report, so it costs the live proof nothing and cannot fail a release.
--      It is a query over a few small tables, and it is tenant-scoped like
--      stranded_work, so a platform operator reads it one organisation at a
--      time.
--
--   2. THE APPLIER. The approval_chain arm of erp.apply_change_set_item()
--      resolves role codes with no filter on status, so a chain promoted from a
--      starter pack or from another environment, which never passed the door
--      that asks, can write a step naming a removed role. Today that step is
--      written and does nothing useful. The arm now refuses, in the words the
--      chain's author can act on, before it writes the step. The refusal is on
--      a new write, so it cannot reach data that already exists, and it is the
--      same shape as the one 20260921140000 puts in the removal arm: the
--      promoter is the authority, because the door that proposed the change may
--      have run before the role was removed.
--
--      A rollback to a snapshot is not held up, as it is not by the last user
--      manager rule or by the removal refusal: restoring what an organisation
--      had is not the same as choosing something new.
--
--      Only a role that EXISTS and is not active is refused. A code that names
--      no role at all keeps the behaviour it had, so this does not change what
--      a pack that names a role its organisation never created does.
--
--   3. WHO A ROLE STEP ASKS. erp.step_approvers() resolves a role step's
--      approvers from erp.user_role and never asks whether the role is active,
--      while erp.effective_permission reads only active roles, so holders of a
--      removed role can still be routed approval tasks they hold nothing to
--      justify. NOT CHANGED HERE. What an approval does is the owner's to
--      decide, and the decision is put to them. What is already true, and does
--      not need deciding again, is that a step which resolves to nobody falls
--      to the organisation's administrators (20260916270000), and only an
--      organisation with no administrator at all is refused
--      (CLOVEERP_APPROVAL_STEP_UNSTAFFED).
--
-- Not covered, and said so rather than left to be found: a task that is already
-- pending on a removed role's holders, and the escalation function, which reads
-- erp.user_role by escalate_to_role_id the same way step_approvers does. Both
-- belong with decision 3.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What a promoted chain may not name
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Volatile, so that it sees what the promotion has already written in the same
-- transaction: a change set that removes a role and then promotes a chain naming
-- it has to be refused, and a stable function would read the state the calling
-- statement started with.

create or replace function erp.require_chain_roles_active(
  p_tenant uuid, p_chain_code text, p_steps jsonb, p_rolling_back boolean default false)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_chain text;
  v_said  text[];
  v_todo  text[];
begin
  if p_rolling_back then
    return;
  end if;

  v_chain := replace(coalesce(nullif(btrim(
               (select c.name from erp.approval_chain c
                 where c.tenant_id = p_tenant and c.code = p_chain_code)), ''),
             p_chain_code), '_', ' ');

  -- Names, never codes, and no underscore anywhere: the desk hides a hint that
  -- reads like an identifier.
  select coalesce(array_agg(f.said order by f.seq, f.used_as), '{}'::text[]),
         coalesce(array_agg(distinct f.step_name), '{}'::text[])
    into v_said, v_todo
    from (select (s.value ->> 'seq')::integer as seq,
                 x.used_as,
                 replace(coalesce(nullif(btrim(s.value ->> 'name'), ''), s.value ->> 'code'), '_', ' ')
                   as step_name,
                 format('step "%s" %s the role "%s"',
                        replace(coalesce(nullif(btrim(s.value ->> 'name'), ''), s.value ->> 'code'), '_', ' '),
                        case x.used_as when 'approver' then 'asks' else 'escalates to' end,
                        replace(coalesce(nullif(btrim(ro.name), ''), ro.code), '_', ' ')) as said
            from jsonb_array_elements(coalesce(p_steps, '[]'::jsonb)) s
            cross join lateral (values ('approver', s.value ->> 'role'),
                                       ('escalation', s.value ->> 'escalate_to_role')) x(used_as, role_code)
            join erp.role ro
              on ro.tenant_id = p_tenant and ro.code = x.role_code
           where ro.status <> 'active') f;

  if cardinality(v_said) = 0 then
    return;
  end if;

  raise exception 'CLOVEERP_APPROVAL_STEP_ROLE_RETIRED: the % approval chain names a role that has been removed: %',
    v_chain, erp.list_in_words(v_said)
    using errcode = '23503',
          hint = 'Change ' || erp.list_in_words(v_todo)
                 || ' so that it names a role this organisation still has, then promote the chain again.';
end;
$$;

revoke all on function erp.require_chain_roles_active(uuid, text, jsonb, boolean) from public, anon;

comment on function erp.require_chain_roles_active(uuid, text, jsonb, boolean) is
  'Refuses CLOVEERP_APPROVAL_STEP_ROLE_RETIRED when a chain being promoted has a '
  'step whose approver role, or whose escalation role, exists and is not active, '
  'and names the steps and the roles in the message and in the hint. A code that '
  'names no role is not this function''s business. Silent when the promotion is a '
  'rollback to a snapshot, which puts back what the organisation had. Called by '
  'the approval_chain arm of erp.apply_change_set_item() (20260922100000).';

select erp.register_refusal('CLOVEERP_APPROVAL_STEP_ROLE_RETIRED',
  'Promoting an approval chain with a step that names a role that has been removed.',
  'A step asks the people who hold its role, or sends the request on to them. A role that has been removed grants nothing, so the step would ask people who could not justify the decision, or nobody.',
  'Change the step so that it names a role this organisation still has, then promote the chain again.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The applier asks before it writes the step
-- ═════════════════════════════════════════════════════════════════════════════
--
-- By needle into the body the database carries, asserted to occur exactly once.
-- The step insert is written by 20260904920000 and widened by 20260916170000
-- and 20260916300000; the needle is the text those three leave. The check sits
-- immediately before it, so nothing is written for a chain that is refused, and
-- the refusal itself undoes the chain row and its version, which are written
-- just above.

do $applier$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n   constant text := $n$        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          approver_source,
$n$;
  v_r   constant text := $r$        -- A step may not name a role that has been removed (20260922100000).
        -- The door that proposed the chain asked, but it may have asked before
        -- the role was removed, and a chain from a starter pack or another
        -- environment never went through it. A rollback to a snapshot is let
        -- through, as it is by the removal refusal.
        declare
          v_chain_stack text;
        begin
          get diagnostics v_chain_stack = pg_context;
          perform erp.require_chain_roles_active(v_tenant, p ->> 'code', p -> 'steps',
            position('function erp.' || 'rollback_to_snapshot(' in v_chain_stack) > 0);
        end;

        insert into erp.approval_step (
          tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
          approver_source,
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_APPLIER_UNRECOGNISED: the approval step written by % is not the text this migration puts a check in front of', v_sig
      using hint = 'A later migration changed the approval_chain arm. Read pg_get_functiondef() of the applier and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('erp.require_chain_roles_active(' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_APPLIER_UNRECOGNISED: the applier did not take the refusal to write a step naming a removed role'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the applier.';
  end if;
end
$applier$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Steps that already name one
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The same reading of "in force" as the removal refusal: a version that is
-- active or being drafted, in a chain that is not itself retired. A superseded
-- version is history and cannot be edited, so it is not a finding.

create or replace function erp.retired_role_steps_report()
returns table(chain_code text, step_code text, role_code text, used_as text,
              version_status text, finding text)
language sql
stable
security invoker
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select c.code, st.code, ro.code, x.used_as, v.status::text,
         case x.used_as
           when 'approver' then 'the role that approves this step has been removed'
           else 'the role this step escalates to has been removed'
         end
    from t
    join erp.approval_step st on st.tenant_id = t.tenant_id
    join erp.approval_chain_version v
      on v.tenant_id = st.tenant_id and v.id = st.approval_chain_version_id
    join erp.approval_chain c
      on c.tenant_id = v.tenant_id and c.id = v.approval_chain_id
    cross join lateral (values ('approver', st.role_id),
                               ('escalation', st.escalate_to_role_id)) x(used_as, named_role_id)
    join erp.role ro
      on ro.tenant_id = st.tenant_id and ro.id = x.named_role_id
   where ro.status <> 'active'
     and v.status in ('draft', 'active')
     and c.status not in ('inactive', 'archived')
   order by c.code, st.seq, x.used_as
$$;

revoke all on function erp.retired_role_steps_report() from public, anon, authenticated;

comment on function erp.retired_role_steps_report() is
  'Approval chain steps, in a version that is in force or being drafted, whose '
  'approver role or escalation role has been removed. A report and not an '
  'assertion: a rollback to a snapshot can put such a step back on purpose, and '
  'an assertion over tenant data fails the deploy''s proof for the '
  'organisation''s configuration (20260922100000).';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('retired_role_steps', 'Approval steps naming a removed role', 'report', 'tenant',
   'retired_role_steps_report', '', null, '',
   'Steps of an approval chain in force, or being drafted, whose approver or escalation role has been removed.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

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
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_resource_coverage('en');
select erp.assert_diagnostics_registered();

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- One organisation, run in two halves, as the role removal suite is: before it
-- is live the door promotes what it proposes and roles can be written directly,
-- so the fixture is built then; afterwards a change set waits for a second
-- administrator, and that is where the applier is the authority, because a
-- chain proposed while its roles were active is promoted after they were
-- removed.

create or replace function erp_test.a_chain_step_cannot_name_a_removed_role_suite()
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
  a1        uuid := gen_random_uuid();   -- the first administrator
  a2        uuid := gen_random_uuid();   -- the second: B6 refuses self-approval once live
  v_second  uuid; v_tok text;
  v_cs_chain uuid; v_cs_a uuid; v_cs_b uuid; v_cs_ok uuid;
  v_ok      boolean; v_msg text; v_hint text;
  v_rows    integer; v_approver integer; v_escalation integer; v_other integer;
begin
  begin
  -- ── The organisation, before it is live ──────────────────────────────────
  v_step := 'provisioning the organisation';
  perform set_config('request.jwt.claims', '', true);
  select * into r from erp.provision_tenant(
    'zzcr-' || v_tag, 'Chain Roles',
    'admin@zzcr-' || v_tag || '.test', 'Chain Admin');
  update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

  insert into auth.users (id, email) values
    (a1, 'admin@zzcr-' || v_tag || '.test'),
    (a2, 'second@zzcr-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_step := 'the roles';
  perform public.erp_save_role(null, 'zz_keep', 'Kept role', 'Stays in use.', array['reporting.read']);
  perform public.erp_save_role(null, 'zz_appr', 'Approver role', 'Approves a step, then is removed.', array['reporting.read']);
  perform public.erp_save_role(null, 'zz_esc', 'Escalation role', 'A step escalates to it, then it is removed.', array['reporting.read']);
  perform public.erp_save_role(null, 'zz_hist', 'History role', 'Only a superseded version names it.', array['reporting.read']);
  perform public.erp_save_role(null, 'zz_race_a', 'Race role A', 'Active when a chain is proposed, removed before it is promoted.', array['reporting.read']);
  perform public.erp_save_role(null, 'zz_race_b', 'Race role B', 'The same, as an escalation point.', array['reporting.read']);

  v_step := 'three chains while every role is active';
  perform public.erp_propose_approval_chain(
    'zz_fine', 'Healthy chain', 'document',
    jsonb_build_array(jsonb_build_object(
      'seq', 1, 'code', 'sign_off', 'name', 'Sign off', 'role', 'zz_keep')));
  perform public.erp_propose_approval_chain(
    'zz_retired', 'Retired chain', 'document',
    jsonb_build_array(jsonb_build_object(
      'seq', 1, 'code', 'sign_off', 'name', 'Sign off', 'role', 'zz_appr',
      'escalate_after_hours', 24, 'escalate_to_role', 'zz_esc')));
  perform public.erp_propose_approval_chain(
    'zz_history', 'History chain', 'document',
    jsonb_build_array(jsonb_build_object(
      'seq', 1, 'code', 'old', 'name', 'Old step', 'role', 'zz_hist')));
  perform public.erp_propose_approval_chain(
    'zz_history', 'History chain', 'document',
    jsonb_build_array(jsonb_build_object(
      'seq', 1, 'code', 'new', 'name', 'New step', 'role', 'zz_keep')));

  -- ── 1. Nothing is reported while every role is in use ────────────────────
  v_step := 'reading the report of a healthy organisation';
  v_cases := v_cases + 1;
  select count(*)::integer into v_rows from erp.retired_role_steps_report();
  case_name := 'an organisation whose roles are all in use has nothing to report';
  passed := coalesce(v_rows = 0, false);
  detail := format('%s finding(s)', v_rows);
  return next;

  -- ── Three roles are removed, directly: the organisation is not live ──────
  v_step := 'removing three roles directly';
  update erp.role ro set status = 'inactive', updated_at = now()
   where ro.tenant_id = r.tenant_id and ro.code in ('zz_appr', 'zz_esc', 'zz_hist');

  -- ── 2. The report says which steps, and in which way ─────────────────────
  v_step := 'reading the report';
  v_cases := v_cases + 1;
  select count(*)::integer,
         count(*) filter (where f.chain_code = 'zz_retired' and f.used_as = 'approver'
                            and f.role_code = 'zz_appr' and f.step_code = 'sign_off'),
         count(*) filter (where f.chain_code = 'zz_retired' and f.used_as = 'escalation'
                            and f.role_code = 'zz_esc' and f.step_code = 'sign_off'),
         count(*) filter (where f.chain_code <> 'zz_retired')
    into v_rows, v_approver, v_escalation, v_other
    from erp.retired_role_steps_report() f;
  case_name := 'the report names a step whose approver was removed and one whose escalation was, and not a step only history names';
  passed := coalesce(v_rows = 2 and v_approver = 1 and v_escalation = 1 and v_other = 0, false);
  detail := format('%s finding(s): %s as approver, %s as escalation, %s about any other chain',
                   v_rows, v_approver, v_escalation, v_other);
  return next;

  -- ── 3. The check the applier makes, and the rollback it lets through ─────
  v_step := 'asking the check directly';
  v_cases := v_cases + 1;
  begin
    perform erp.require_chain_roles_active(r.tenant_id, 'zz_direct',
      jsonb_build_array(jsonb_build_object(
        'seq', 1, 'code', 'gate', 'name', 'Gate', 'role', 'zz_appr',
        'escalate_after_hours', 24, 'escalate_to_role', 'zz_esc')));
    v_ok := false; v_msg := 'it was accepted'; v_hint := null;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_STEP_ROLE_RETIRED%'; v_msg := sqlerrm;
  end;
  begin
    perform erp.require_chain_roles_active(r.tenant_id, 'zz_direct',
      jsonb_build_array(jsonb_build_object(
        'seq', 1, 'code', 'gate', 'name', 'Gate', 'role', 'zz_appr')), true);
    perform erp.require_chain_roles_active(r.tenant_id, 'zz_direct',
      jsonb_build_array(jsonb_build_object(
        'seq', 1, 'code', 'gate', 'name', 'Gate', 'role', 'zz_no_such_role')));
    res := jsonb_build_object('let_through', true);
  exception when others then
    res := jsonb_build_object('let_through', false, 'said', left(sqlerrm, 120));
  end;
  case_name := 'a step naming a removed role is refused with the step and both roles named, and a rollback, or a code naming no role, is let through';
  passed := coalesce(v_ok
                 and position('Approver role' in v_msg) > 0
                 and position('Escalation role' in v_msg) > 0
                 and position('Gate' in coalesce(v_hint, '')) > 0
                 and position('_' in coalesce(v_hint, '')) = 0
                 and (res ->> 'let_through')::boolean, false);
  detail := format('%s — hint: %s; rollback and unknown code: %s',
                   left(v_msg, 200), coalesce(left(v_hint, 160), 'none'), res::text);
  return next;

  -- ── The organisation goes live, with a second administrator ─────────────
  v_step := 'going live';
  select p.app_user_id, p.token into v_second, v_tok
    from erp.invite_principal('second@zzcr-' || v_tag || '.test', 'Second Admin') p;
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
  update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

  -- A chain proposed while both of its roles are active, and each role's
  -- removal proposed while nothing yet names it: the state a customer is in
  -- when two administrators are not looking at the same screen.
  v_step := 'proposing a chain, then removing the roles it names';
  res := public.erp_propose_approval_chain(
    'zz_race', 'Race chain', 'document',
    jsonb_build_array(jsonb_build_object(
      'seq', 1, 'code', 'gate', 'name', 'Gate', 'role', 'zz_race_a',
      'escalate_after_hours', 24, 'escalate_to_role', 'zz_race_b')));
  v_cs_chain := (res ->> 'change_set_id')::uuid;
  v_cs_a := (public.erp_propose_role_removal(
              (select ro.id from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'zz_race_a'))
              ->> 'change_set_id')::uuid;
  v_cs_b := (public.erp_propose_role_removal(
              (select ro.id from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'zz_race_b'))
              ->> 'change_set_id')::uuid;
  v_cs_ok := (public.erp_propose_approval_chain(
              'zz_live_fine', 'Live healthy chain', 'document',
              jsonb_build_array(jsonb_build_object(
                'seq', 1, 'code', 'sign_off', 'name', 'Sign off', 'role', 'zz_keep')))
              ->> 'change_set_id')::uuid;

  v_step := 'a second administrator removes the two roles';
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(v_cs_a);
  perform erp.promote_change_set(v_cs_a);
  perform erp.approve_change_set(v_cs_b);
  perform erp.promote_change_set(v_cs_b);

  -- ── 4. The applier is the authority ─────────────────────────────────────
  v_step := 'promoting the chain that names them';
  v_cases := v_cases + 1;
  begin
    perform erp.approve_change_set(v_cs_chain);
    perform erp.promote_change_set(v_cs_chain);
    v_ok := false; v_msg := 'it was promoted'; v_hint := null;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_ok := sqlerrm like '%CLOVEERP_APPROVAL_STEP_ROLE_RETIRED%'; v_msg := sqlerrm;
  end;
  case_name := 'a chain proposed while its roles were active is refused at promotion once they are removed, naming the chain, the step and both roles';
  passed := coalesce(v_ok
                 and position('Race chain' in v_msg) > 0
                 and position('Race role A' in v_msg) > 0
                 and position('Race role B' in v_msg) > 0, false);
  detail := left(v_msg, 260);
  return next;

  -- ── 5. And it wrote nothing ─────────────────────────────────────────────
  v_step := 'looking for what the refused promotion left';
  v_cases := v_cases + 1;
  case_name := 'the refused promotion left no chain behind, so no version or step either';
  passed := coalesce(not exists (select 1 from erp.approval_chain c
                                  where c.tenant_id = r.tenant_id and c.code = 'zz_race'), false);
  detail := format('chains named zz_race: %s',
                   (select count(*) from erp.approval_chain c where c.tenant_id = r.tenant_id and c.code = 'zz_race'));
  return next;

  -- ── 6. A chain naming roles that are in use still promotes ──────────────
  v_step := 'promoting a chain whose role is in use';
  v_cases := v_cases + 1;
  perform erp.approve_change_set(v_cs_ok);
  perform erp.promote_change_set(v_cs_ok);
  case_name := 'a chain naming a role that is in use is promoted, and is in force';
  passed := coalesce(exists (select 1
                               from erp.approval_chain c
                               join erp.approval_chain_version v
                                 on v.tenant_id = c.tenant_id and v.approval_chain_id = c.id
                               join erp.approval_step st
                                 on st.tenant_id = v.tenant_id and st.approval_chain_version_id = v.id
                              where c.tenant_id = r.tenant_id and c.code = 'zz_live_fine'
                                and v.status = 'active' and st.code = 'sign_off'), false);
  detail := format('versions in force: %s',
                   (select count(*) from erp.approval_chain c
                      join erp.approval_chain_version v
                        on v.tenant_id = c.tenant_id and v.approval_chain_id = c.id
                     where c.tenant_id = r.tenant_id and c.code = 'zz_live_fine' and v.status = 'active'));
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

  -- ── 7. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzcr-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2));
  detail := coalesce(v_state, 'the organisation, its roles and its chains all rolled back');
  return next;

  if v_cases <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: a_chain_step_cannot_name_a_removed_role_suite ran % case(s), expected 7; the fixture stopped %',
      v_cases, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.a_chain_step_cannot_name_a_removed_role_suite() from public, anon;

comment on function erp_test.a_chain_step_cannot_name_a_removed_role_suite() is
  'What a chain step may name. An organisation whose roles are all in use has '
  'nothing to report; the report names a step whose approver was removed and one '
  'whose escalation was, and not a step only a superseded version names; the '
  'check refuses a step naming a removed role with the step and the roles named, '
  'and lets a rollback and a code naming no role through; a chain proposed while '
  'its roles were active is refused at promotion once they are removed and leaves '
  'nothing behind; and a chain naming a role in use still promotes. Rolls back '
  'everything it made.';

create or replace function erp_test.assert_a_chain_step_cannot_name_a_removed_role_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _a_chain_step_cannot_name_a_removed_role on commit drop as
    select * from erp_test.a_chain_step_cannot_name_a_removed_role_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _a_chain_step_cannot_name_a_removed_role;
  drop table _a_chain_step_cannot_name_a_removed_role;
  if v_fail > 0 then
    raise exception E'CLOVEERP_A_CHAIN_STEP_CANNOT_NAME_A_REMOVED_ROLE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'Read the failed case. Either a step naming a removed role was written, one naming a role in use was refused, or the report missed or invented a finding.';
  end if;
  if v_all <> 7 then
    raise exception 'CLOVEERP_SUITE_SHRANK: a_chain_step_cannot_name_a_removed_role_suite ran % case(s), expected 7', v_all
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a chain step cannot name a removed role: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_a_chain_step_cannot_name_a_removed_role_suite() from public, anon;

select erp.apply_execute_grants();

select erp_test.assert_a_chain_step_cannot_name_a_removed_role_suite();

select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_isolation();
