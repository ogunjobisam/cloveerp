-- =============================================================================
-- 20260914015000  A live guard reads its register as its owner
-- -----------------------------------------------------------------------------
-- Live, 14 September 2026, 00:41 UTC. An administrator of Clove Foods, which
-- had just gone live, raised a goods receipt from the desk and was refused with
-- "permission denied for schema erp_meta". The context:
--
--   erp.guard_live_configuration() line 38
--   update erp.numbering_rule set next_value = a.value + 1, ...
--   erp.next_document_number(uuid) line 33
--   erp.create_document(...) <- erp.open_document(...)
--   <- erp.create_document_full(...) <- public.erp_create_document_full
--
-- erp.guard_live_configuration() is the trigger on every promotable surface.
-- 20260904150000 taught its UPDATE branch to let state columns through, such
-- as numbering_rule.next_value, by reading erp_meta.live_mutable_column. The
-- trigger runs as the writer. A signed-in caller has no USAGE on erp_meta
-- (20260830024837 took back the grant 20260830024657 made minutes earlier),
-- so the read fails for the trigger itself. Every document number in every live
-- organisation fails for everyone signed in.
--
-- The history of the body, read rather than assumed. 0017 defined it.
-- 20260901130000 changed the generator that attaches it (register-driven
-- instead of an array), not the body. 20260904150000 redefined it with the
-- erp_meta read. 20260904980000's sweep renamed its refusal to
-- CLOVEERP_LIVE_CONFIG_EDIT. 20260906141000 text-patched it so a promotion id
-- set by hand no longer opens the window, via erp.promotion_window_is_open(),
-- which is a definer. Nothing caught it because the guard returns early until
-- an organisation is live. The suites that number documents in a live
-- organisation run as the owner, and
-- erp.assert_no_caller_reachable_internal_routines() (20260913090000) walks
-- doors, never triggers.
--
-- The fix is the one 20260913081000 gave erp_set_active_tenant: the function
-- runs as its owner with the empty search path it already had. Running as the
-- owner changes nothing the guard answers:
--
--   * Every row it reads is chosen by its own predicates. erp.environment is
--     filtered by the tenant of the row being written, and that row has
--     already passed the writer's row security. erp_meta.live_mutable_column
--     is product data, not tenant data. erp.promotion_window_is_open() is
--     filtered by that same tenant and by the current transaction.
--   * The settings it reads (erp.promotion_id, erp.purge_tenant_id) are
--     session settings, which a definer frame sees unchanged.
--   * It does not read current_user, session_user, erp.session_is_trusted()
--     or the tenant and principal resolvers, which are the only things a
--     definer frame answers differently. Section 1 refuses to apply if the
--     body has changed so that it does.
--
-- The same flaw, looked for rather than guessed at. The migrations were
-- replayed outside a database, because none was to hand. Every CREATE, ALTER
-- and DROP FUNCTION was applied in order, and the migrations that rewrite
-- trigger bodies with execute replace(...) were read by hand. That gives 56
-- trigger functions, 55 of them in erp, none a definer. Three name erp_meta in
-- code, directly or through an invoker erp function they call by name:
--
--   * erp.guard_live_configuration(): erp_meta.live_mutable_column. Fixed
--     here.
--   * erp.check_command_transition() (0030): erp_meta.command_transition, on
--     every status change of erp.command. public.erp_cancel_command,
--     public.erp_submit_command and public.erp_reconcile_ambiguous_command
--     are invoker doors that move a command's status through invoker erp
--     functions, so a signed-in caller fires it, and the read has refused
--     every such caller for as long as the gateway has existed. Fixed here
--     the same way. It
--     also calls erp.current_principal_id(), whose job-principal fallback a
--     definer frame would honour. That fallback cannot be reached through
--     this trigger by a session that could not already reach it:
--     erp.command's row security admits only a writer whose own frame
--     resolved a tenant, so a signed-in writer is resolved by its JWT subject
--     first, and a trusted writer was already trusted.
--   * erp.guard_enquiry_content() (20260904950000) mentions erp.erase_enquiry(),
--     an invoker function that writes erp_meta.enquiry, but only inside its
--     hint text. It is attached only to erp_meta.enquiry. A writer that can
--     reach that table can already use the schema, so it cannot fire for a
--     signed-in caller. Left as it is, and the assertion's rule says why.
--
-- erp.audit_row_change() does not name erp_meta. Its latest body
-- (20260904910000) reads only erp tables. The erp_meta.audit_attribution_epoch
-- and erp_meta.register_table mentions in that file belong to the assertion
-- beside it. Nothing reaches erp_meta at two invoker hops that one hop misses.
--
-- The rule, so the next one is caught before it ships:
-- erp.assert_triggers_reach_no_sealed_schema() fails on any trigger function
-- in erp that is SECURITY INVOKER, attached by a non-internal trigger to at
-- least one relation outside erp_meta, and whose code (erp.prosrc_code, so
-- comments do not count) names erp_meta, either itself or through an invoker
-- erp function it names as erp.<name>(. A trigger function attached to
-- nothing is left out, and so is one attached only to erp_meta tables, for
-- the reason above. It is textual: a name built in dynamic SQL is not seen,
-- and a name in a string literal is. It stops at one hop, and it names
-- erp_meta only.
--
-- Proof: erp_test.live_guard_as_signed_in_suite() (7 cases, pinned). It
-- provisions an organisation, gives it a numbering rule, declares it live, and
-- numbers a document as its signed-in administrator through the real role.
-- It then checks that the same administrator's direct change to the rule's
-- prefix is still refused by name.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The bodies are the ones read, and neither asks a definer's question
-- ═════════════════════════════════════════════════════════════════════════════

do $bodies$
declare
  v_guard   text;
  v_command text;
begin
  select erp.prosrc_code(p.prosrc) into v_guard
    from pg_catalog.pg_proc p where p.oid = 'erp.guard_live_configuration()'::regprocedure;
  select erp.prosrc_code(p.prosrc) into v_command
    from pg_catalog.pg_proc p where p.oid = 'erp.check_command_transition()'::regprocedure;

  if position('erp_meta.live_mutable_column' in v_guard) = 0
     or position('erp.promotion_window_is_open(' in v_guard) = 0
     or position('CLOVEERP_LIVE_CONFIG_EDIT' in v_guard) = 0 then
    raise exception 'CLOVEERP_TRIGGER_BODY_UNRECOGNISED: erp.guard_live_configuration() is not the body this migration makes run as its owner'
      using hint = 'Read the live body with pg_get_functiondef and decide again whether it is safe as a definer before changing this check.';
  end if;
  if position('erp_meta.command_transition' in v_command) = 0
     or position('CLOVEERP_ILLEGAL_COMMAND_TRANSITION' in v_command) = 0 then
    raise exception 'CLOVEERP_TRIGGER_BODY_UNRECOGNISED: erp.check_command_transition() is not the body this migration makes run as its owner'
      using hint = 'Read the live body with pg_get_functiondef and decide again whether it is safe as a definer before changing this check.';
  end if;

  -- The questions a definer frame answers as the owner rather than the writer.
  if v_guard ~* '\m(current_user|session_user|session_is_trusted|current_tenant_id|require_tenant_id|current_principal_id)\M' then
    raise exception 'CLOVEERP_TRIGGER_READS_CALLER_FRAME: erp.guard_live_configuration() asks who is calling, which a definer would answer as its owner'
      using hint = 'Move that question out of the guard, or into a helper that runs as the caller, before the guard runs as its owner.';
  end if;
  if v_command ~* '\m(current_user|session_user|session_is_trusted|current_tenant_id|require_tenant_id)\M' then
    raise exception 'CLOVEERP_TRIGGER_READS_CALLER_FRAME: erp.check_command_transition() asks who is calling, which a definer would answer as its owner'
      using hint = 'Move that question out of the transition check, or into a helper that runs as the caller, before it runs as its owner.';
  end if;
end
$bodies$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Both run as their owner
-- ═════════════════════════════════════════════════════════════════════════════

alter function erp.guard_live_configuration() security definer set search_path = '';
alter function erp.check_command_transition() security definer set search_path = '';

comment on function erp.guard_live_configuration() is
  'Refuses a direct configuration edit on a live organisation. An update that '
  'changes only columns registered in erp_meta.live_mutable_column is allowed '
  'through: a sequence advancing its counter is the product operating rather '
  'than somebody configuring. The message names the columns that were refused. '
  'Runs as its owner (20260914015000), because the register is in erp_meta, '
  'which a signed-in writer cannot use; every row it reads is chosen by the '
  'tenant of the row being written.';

comment on function erp.check_command_transition() is
  'The write gateway''s lifecycle guard on erp.command: a command starts '
  'drafted, what was approved is what is sent, the dry-run flag never moves, '
  'and a status change must be an edge in erp_meta.command_transition. Each '
  'step is appended to erp.command_event for the command''s own organisation. '
  'Runs as its owner (20260914015000), because the transition table is in '
  'erp_meta, which a signed-in writer cannot use.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The allowances say why
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'guard_live_configuration',
   'A trigger that must read the live-mutable-column register, erp_meta.live_mutable_column, sealed from signed-in callers; it decides only whether the row write it guards may proceed. Every row it reads is chosen by the tenant of the row being written, which already passed the writer''s row security; the settings it reads are session settings; it never asks who the caller is. Without it every document number in a live organisation failed for a signed-in person (20260914015000).'),
  ('erp', 'check_command_transition',
   'A trigger that must read the gateway''s legal-transition table, erp_meta.command_transition, sealed from signed-in callers; it decides only whether the status change it guards may proceed, and appends that step to erp.command_event for the command''s own organisation. Its actor is erp.current_principal_id(), which for a signed-in writer is their JWT subject''s principal; a writer with no principal cannot pass erp.command''s row security to fire it (20260914015000).')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- The window's own allowance said the guard runs as the writer. It no longer
-- does; the helper stays a definer so the one question about a window is
-- answered in one place whoever asks it.
do $window$
declare
  v_moved integer;
begin
  update erp_meta.security_definer_allowance
     set rationale = 'Reads erp_meta.promotion_window for the live-configuration guard; answers only whether the named promotion of the named organisation was opened in the current transaction. Written as a definer when the guard ran as the writer (20260906141000); the guard runs as its owner since 20260914015000, and this remains the one place a window is judged.'
   where schema_name = 'erp' and function_name = 'promotion_window_is_open';
  get diagnostics v_moved = row_count;
  if v_moved <> 1 then
    raise exception 'CLOVEERP_DEFINER_ALLOWANCE_NOT_UPDATED: % allowance row(s) for erp.promotion_window_is_open were rewritten, expected 1', v_moved
      using hint = 'The row is written by 20260906141000. If row security refused the update, the migration role has lost its bypass.';
  end if;
end
$window$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The rule: a trigger that runs as the writer names nothing in erp_meta
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.trigger_sealed_schema_reach_report()
returns table (trigger_function text, attached_to text, via text, sealed_name text)
language sql
stable
set search_path = ''
as $$
  with trigger_fn as materialized (
    select p.oid, 'erp.' || p.proname as fqn, erp.prosrc_code(p.prosrc) as code
      from pg_catalog.pg_proc p
     where p.pronamespace = 'erp'::regnamespace
       and p.prorettype = 'pg_catalog.trigger'::regtype
       and not p.prosecdef
  ),
  -- Where each one fires as the writer. A relation in erp_meta is left out:
  -- a writer that can reach it can already use the schema.
  attached as materialized (
    select a.oid,
           case when count(*) = 1 then min(a.rel)
                else format('%s relations, among them %s', count(*), min(a.rel)) end as relations
      from (select distinct t.tgfoid as oid, n.nspname || '.' || c.relname as rel
              from pg_catalog.pg_trigger t
              join pg_catalog.pg_class c on c.oid = t.tgrelid
              join pg_catalog.pg_namespace n on n.oid = c.relnamespace
             where not t.tgisinternal
               and n.nspname <> 'erp_meta') a
     where a.oid in (select f.oid from trigger_fn f)
     group by a.oid
  ),
  -- Invoker erp functions whose own code names something in erp_meta.
  carrier as materialized (
    select distinct 'erp.' || p.proname as fqn, m[1] as sealed_name
      from pg_catalog.pg_proc p
      cross join lateral regexp_matches(erp.prosrc_code(p.prosrc),
                                        '(erp_meta\.[A-Za-z_][A-Za-z0-9_]*)', 'g') m
     where p.pronamespace = 'erp'::regnamespace
       and not p.prosecdef
       and p.prorettype <> 'pg_catalog.trigger'::regtype
       and strpos(p.prosrc, 'erp_meta.') > 0
  ),
  reach as (
    select f.oid, f.fqn, 'the trigger function itself'::text as via, m[1] as sealed_name
      from trigger_fn f
      cross join lateral regexp_matches(f.code, '(erp_meta\.[A-Za-z_][A-Za-z0-9_]*)', 'g') m
    union
    select f.oid, f.fqn, k.fqn, k.sealed_name
      from trigger_fn f
      join carrier k on strpos(f.code, k.fqn || '(') > 0
  )
  select r.fqn, a.relations, r.via, r.sealed_name
    from reach r
    join attached a on a.oid = r.oid
   order by 1, 3, 4;
$$;

comment on function erp.trigger_sealed_schema_reach_report() is
  'Trigger functions in erp that run as the writer, fire on a relation outside '
  'erp_meta, and name something in erp_meta in code, themselves or through an '
  'invoker erp function they call by name. A signed-in writer has no USAGE on '
  'erp_meta, so each is refused for every such write, and green in every test '
  'that writes as the owner.';

revoke all on function erp.trigger_sealed_schema_reach_report() from public, anon;

create or replace function erp.assert_triggers_reach_no_sealed_schema()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count   integer;
  v_detail  text;
  v_invoker integer;
  v_definer integer;
begin
  select count(*),
         string_agg(format('%s (on %s) via %s names %s', r.trigger_function, r.attached_to, r.via, r.sealed_name),
                    E'\n  ' order by r.trigger_function, r.via, r.sealed_name)
    into v_count, v_detail
    from erp.trigger_sealed_schema_reach_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_TRIGGER_REACHES_SEALED_SCHEMA: % finding(s): a trigger function runs as whoever wrote the row and names erp_meta, a schema a signed-in caller cannot use, so every signed-in write that fires it is refused:\n  %',
      v_count, v_detail
      using errcode = 'P0001',
            hint = 'Make the trigger function SECURITY DEFINER with an empty search path and a row in '
                   'erp_meta.security_definer_allowance saying what it reads and that it decides only whether '
                   'the write it guards may proceed, after checking it never asks who the caller is '
                   '(20260914015000). Granting USAGE on erp_meta to authenticated is not the fix: it is sealed on purpose.';
  end if;

  select count(distinct p.oid) filter (where not p.prosecdef),
         count(distinct p.oid) filter (where p.prosecdef)
    into v_invoker, v_definer
    from pg_catalog.pg_proc p
    join pg_catalog.pg_trigger t on t.tgfoid = p.oid and not t.tgisinternal
    join pg_catalog.pg_class c on c.oid = t.tgrelid
   where p.pronamespace = 'erp'::regnamespace
     and p.prorettype = 'pg_catalog.trigger'::regtype
     and c.relnamespace <> 'erp_meta'::regnamespace;

  if coalesce(v_invoker, 0) = 0 then
    raise exception 'CLOVEERP_TRIGGER_REACH_BLIND: no trigger function in erp that runs as the writer is attached outside erp_meta, so this check looked at nothing'
      using errcode = 'P0001',
            hint = 'The catalogue filter has stopped matching; the product attaches dozens. Fix the query rather than accept a pass over nothing.';
  end if;

  return format('trigger functions: none of %s in erp that run as the writer outside erp_meta names erp_meta; %s run as their owner',
                v_invoker, v_definer);
end;
$$;

comment on function erp.assert_triggers_reach_no_sealed_schema() is
  'Fails when erp.trigger_sealed_schema_reach_report() finds a trigger function '
  'that runs as the writer and names erp_meta. Written after live document '
  'numbering failed for signed-in people in a live organisation (20260914015000).';

revoke all on function erp.assert_triggers_reach_no_sealed_schema() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('triggers_reach_no_sealed_schema', 'Triggers that run as the writer call nothing in erp_meta',
   'assertion', 'platform', 'erp', 'assert_triggers_reach_no_sealed_schema', '',
   'trigger_sealed_schema_reach_report', '',
   'A SECURITY INVOKER trigger function that names erp_meta, itself or through an invoker erp function it calls, is refused at the schema for every signed-in write that fires it, and passes every test that writes as the owner. The live guard did this to every document number in a live organisation.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb, runs_in_ci = excluded.runs_in_ci;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite: a live organisation numbers a document for a signed-in person
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.live_guard_as_signed_in_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_owner         text := current_user;
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_tag           text := substr(md5(random()::text), 1, 6);
  v_code          text;
  v_subject       uuid := gen_random_uuid();
  r               record;
  v_rule          uuid;
  v_live          boolean;
  v_executable    boolean;
  v_before        bigint;
  v_after         bigint;
  v_prefix        text;
  v_period        text;
  v_number        text;
  v_number_state  text;
  v_number_error  text;
  v_edit_state    text;
  v_edit_error    text;
  v_role_number   text;
  v_role_edit     text;
  v_owners        boolean;
  v_owners_detail text;
  v_msg           text;
begin
  v_code := 'zzlg-' || v_tag;

  begin
    -- An organisation, and its administrator signed in.
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(v_code, 'Live Guard Suite', 'admin@' || v_code || '.test', 'Live Guard Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', v_subject, 'role', 'authenticated')::text, true);
    perform erp.claim_invitation(r.admin_token);

    -- A numbering rule, written by the promoter's own upsert while the
    -- organisation is being built, and then the organisation declared live.
    -- Provisioning declares it live already, so the window is reopened for
    -- the rule and closed again.
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    v_rule := erp.upsert_numbering_rule('zz_live_guard', 'LG-', null, null, null, 6::smallint, 'yearly'::erp.number_reset, 1, false);
    perform erp_test.close_bootstrap_window(r.tenant_id);

    select e.is_live into v_live from erp.environment e where e.tenant_id = r.tenant_id and e.is_self;
    select nr.next_value into v_before from erp.numbering_rule nr where nr.tenant_id = r.tenant_id and nr.id = v_rule;
    v_executable := pg_catalog.has_function_privilege('authenticated', 'erp.next_document_number(uuid)', 'execute');

    -- Signed in: a document number, the statement that failed on live.
    execute 'set local role authenticated';
    begin
      v_number := erp.next_document_number(v_rule);
    exception when others then
      v_number_state := sqlstate;
      v_number_error := left(sqlerrm, 300);
    end;
    execute format('set local role %I', v_owner);
    v_role_number := current_user;

    -- Signed in: a change to what the rule is, which the guard must still refuse.
    execute 'set local role authenticated';
    begin
      update erp.numbering_rule set prefix = 'XX-'
       where tenant_id = r.tenant_id and id = v_rule;
      v_edit_error := 'the prefix of a rule in a live organisation was changed directly';
    exception when others then
      v_edit_state := sqlstate;
      v_edit_error := left(sqlerrm, 300);
    end;
    execute format('set local role %I', v_owner);
    v_role_edit := current_user;

    select nr.next_value, nr.prefix, nr.current_period
      into v_after, v_prefix, v_period
      from erp.numbering_rule nr
     where nr.tenant_id = r.tenant_id and nr.id = v_rule;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := left(sqlerrm, 300); end if;
    -- Whatever failed, and wherever, the rest of the suite runs as its owner.
    execute format('set local role %I', v_owner);
  end;

  select coalesce(bool_and(p.prosecdef and p.proconfig = array['search_path=""']), false) and count(*) = 2,
         string_agg(format('%s: prosecdef %s, proconfig %s', p.oid::regprocedure, p.prosecdef, p.proconfig), '; '
                    order by p.proname)
    into v_owners, v_owners_detail
    from pg_catalog.pg_proc p
   where p.oid in ('erp.guard_live_configuration()'::regprocedure, 'erp.check_command_transition()'::regprocedure);

  -- 1
  case_name := 'the organisation is live, so the guard does not stand down for it';
  passed := v_msg is null and coalesce(v_live, false);
  detail := coalesce(v_msg, format('self environment live: %s', coalesce(v_live::text, 'no self environment')));
  return next;

  -- 2
  case_name := 'a signed-in administrator of a live organisation is given a document number';
  passed := coalesce(v_msg is null and v_number_state is null
                     and v_number like 'LG-%' || lpad(v_before::text, 6, '0'), false);
  detail := coalesce(v_msg,
                     case when v_number_state is null then format('issued %s', coalesce(v_number, 'nothing'))
                          else format('%s: %s', v_number_state, v_number_error) end)
            || format(' (authenticated may execute erp.next_document_number: %s)', coalesce(v_executable::text, 'unknown'));
  return next;

  -- 3
  case_name := 'the number moved the rule''s counter and nothing a person configures';
  passed := coalesce(v_msg is null and v_after = v_before + 1 and v_prefix = 'LG-'
                     and v_period = to_char(current_date, 'YYYY'), false);
  detail := coalesce(v_msg, format('counter %s then %s; prefix %s; period %s', v_before, v_after, v_prefix, v_period));
  return next;

  -- 4
  case_name := 'a signed-in change to a configuration column of the live rule is still refused by the live-configuration guard';
  passed := coalesce(v_msg is null and v_edit_state = '42501'
                     and v_edit_error like 'CLOVEERP_LIVE_CONFIG_EDIT:%prefix%', false);
  detail := coalesce(v_msg, format('%s: %s', coalesce(v_edit_state, 'no error'), v_edit_error));
  return next;

  -- 5
  case_name := 'the live-configuration guard and the gateway''s transition check run as their owner, with an empty search path';
  passed := coalesce(v_owners, false);
  detail := coalesce(v_owners_detail, 'neither function was found');
  return next;

  -- 6
  case_name := 'each signed-in statement handed the session back to its owner';
  passed := coalesce(v_msg is null and v_role_number = v_owner and v_role_edit = v_owner
                     and current_user::text = v_owner, false);
  detail := coalesce(v_msg, format('after the number %s, after the edit %s, now %s; owner %s',
                                   v_role_number, v_role_edit, current_user, v_owner));
  return next;

  -- 7
  case_name := 'the fixtures were undone';
  passed := not exists (select 1 from erp.tenant t where t.code = v_code)
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before;
  detail := 'the organisation, its administrator''s sign-in and its numbering rule rolled back, and the claims restored';
  return next;
end;
$$;

comment on function erp_test.live_guard_as_signed_in_suite() is
  'Numbers a document in a live organisation as its signed-in administrator '
  'through the authenticated role, and has the same administrator try to '
  'change the rule''s prefix directly. The first failed on live with '
  '"permission denied for schema erp_meta" until 20260914015000; the second '
  'must still be refused by the live-configuration guard.';

revoke all on function erp_test.live_guard_as_signed_in_suite() from public, anon, authenticated;

create or replace function erp_test.assert_live_guard_as_signed_in_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.live_guard_as_signed_in_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_LIVE_GUARD_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_LIVE_GUARD_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'A signed-in person in a live organisation cannot number a document, or can change configuration directly. Read the failed case before the guard.';
  end if;
  return format('live guard as a signed-in caller: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.assert_live_guard_as_signed_in_suite() from public, anon, authenticated;

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

select erp.assert_triggers_reach_no_sealed_schema();
select erp_test.assert_live_guard_as_signed_in_suite();

-- Two new definers need their allowance rows; the grants follow a reach that
-- no longer runs through the guard; the register gained a check.
select erp.assert_isolation();
select erp.assert_invoker_doors_executable();
select erp.assert_diagnostics_registered();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
