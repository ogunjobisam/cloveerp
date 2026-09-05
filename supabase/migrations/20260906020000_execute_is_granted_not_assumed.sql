-- Execute is granted, not assumed.
--
-- 736 of the 791 functions in schema erp carry a NULL ACL, which in Postgres
-- means EXECUTE to PUBLIC: every role that exists or will exist may call them,
-- 139 of them SECURITY DEFINER and running as the owner. 20260905000000
-- reported this and called it latent, because PostgREST exposes public rather
-- than erp. It is not latent. 434 of the 490 public doors are SECURITY INVOKER:
-- the caller's own role runs the erp function behind the door, and it is the
-- PUBLIC grant that lets it. The grant is load-bearing, which is worse than
-- latent — it cannot be removed without saying what replaces it.
--
-- What replaces it is a register. erp.invoker_reach_report() computes, from
-- the catalogue, every routine an authenticated session can reach: the
-- functions the invoker doors call, transitively; the functions the triggers
-- on its tables call, because a trigger function runs as the caller and its
-- callees are checked against the caller too; the functions row-security
-- policies, check constraints and defaults evaluate; and the functions the
-- product dispatches by name from its registers — job handlers, device task
-- handlers, migration loaders, training completions, diagnostics — which no
-- text scan can see. erp.apply_execute_grants() grants EXECUTE on exactly that
-- set to authenticated and service_role, revokes it from anything outside the
-- set, revokes PUBLIC everywhere, and records the set in
-- erp_meta.invoker_reach with the reason each routine is in it. It is a
-- generator in the same sense as erp.apply_row_security(): the register says
-- what is protected, the generator makes it so, the build re-runs it and
-- checks nothing moved.
--
-- Two assertions keep it true. erp.assert_no_public_execute() fails the build
-- on any routine in the product schemas that PUBLIC may execute — a new
-- function left with the default ACL, which is how the 736 got there.
-- erp.assert_invoker_doors_executable() fails it when the computed reach and
-- the actual privileges differ in either direction: a reached routine
-- authenticated cannot execute (a door that will fail at runtime), or a
-- routine authenticated can execute that nothing reaches (a grant with no
-- reason). Default privileges on the schemas are changed so the default for a
-- new function is nothing; a migration that adds a door calls the generator.
--
-- Roles, for the record: anon holds nothing in any product schema — its only
-- route into the database is the enquiry function, which switches to
-- clove_enquiry and calls four definers in erp_ingress. The dispatch worker
-- and the dispatch function connect as the owner. service_role bypasses row
-- security but not EXECUTE, and the server-side client uses it, so it gets the
-- same reach as authenticated and no more.
--
-- The proof is not the assertions alone. erp_test.grant_suite() provisions an
-- organisation, becomes authenticated, and drives the demonstration builder
-- and a month of trading through the public doors. A grant the closure missed
-- fails there as "permission denied for function", with the name.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register of what authenticated may reach
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.invoker_reach (
  identity      text primary key,        -- schema.name(argtypes), from regprocedure
  schema_name   text not null,
  function_name text not null,
  reason        text not null,           -- how the reach was established
  granted_at    timestamptz not null default now()
);

comment on table erp_meta.invoker_reach is
  'Every routine an authenticated session may execute, with the reason: reached '
  'from an invoker door, from a trigger on a table it writes, from a policy or '
  'constraint expression, or named in a register the product dispatches from. '
  'Written by erp.apply_execute_grants(); the grants are derived from it and '
  'from nothing else.';

select erp_meta.register_table('erp_meta', 'invoker_reach', 'platform_internal',
  'What authenticated may execute, and why. Not tenant data.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The reach, computed from the catalogue
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.invoker_reach_report()
returns table(oid oid, schema_name text, function_name text, identity text, reason text)
language sql
stable
set search_path = ''
as $$
  with recursive fn as (
    select p.oid, n.nspname as ns, p.proname, p.prosrc
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
  ),
  -- Every schema.name( a body mentions, extracted once. A mention is an edge to
  -- every overload of that name. Over-inclusive by design, like
  -- erp.public_api_report(): a false edge grants a routine nothing calls, which
  -- the suite would still see as reachable; a missed edge fails a door at runtime.
  mention as (
    select f.oid as caller, m[1] as ns, m[2] as name
      from fn f, regexp_matches(f.prosrc, '(erp[a-z_]*)\.([a-z][a-z0-9_]*)\(', 'g') m
  ),
  edge as (
    select distinct m.caller, callee.oid as callee
      from mention m join fn callee on callee.ns = m.ns and callee.proname = m.name
     where m.caller <> callee.oid
  ),
  -- Root 1: the bodies of SECURITY INVOKER public doors.
  door_roots as (
    select f.oid, 'reached from an invoker door' as reason
      from pg_catalog.pg_proc d,
           regexp_matches(d.prosrc, '(erp[a-z_]*)\.([a-z][a-z0-9_]*)\(', 'g') m
      join fn f on f.ns = m[1] and f.proname = m[2]
     where d.pronamespace = 'public'::regnamespace
       and d.proname like 'erp\_%'
       and not d.prosecdef
  ),
  -- Root 2: what trigger functions call. The trigger function itself runs
  -- without an EXECUTE check on the caller; everything it calls is checked.
  trigger_roots as (
    select f.oid, 'called by a trigger function' as reason
      from pg_catalog.pg_trigger t
      join pg_catalog.pg_class c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace cn on cn.oid = c.relnamespace
      join pg_catalog.pg_proc tf on tf.oid = t.tgfoid
      cross join lateral regexp_matches(tf.prosrc, '(erp[a-z_]*)\.([a-z][a-z0-9_]*)\(', 'g') m
      join fn f on f.ns = m[1] and f.proname = m[2]
     where f.oid <> tf.oid
       and not t.tgisinternal
       and cn.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'public')
       and not tf.prosecdef
  ),
  -- Root 3: functions evaluated by expressions the caller's statements run —
  -- row-security policies, check constraints, column defaults, index
  -- expressions, security-invoker views.
  expr_text as (
    select coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' ' ||
           coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') as txt
      from pg_catalog.pg_policy p
    union all
    select pg_get_constraintdef(c.oid) from pg_catalog.pg_constraint c where c.contype = 'c'
    union all
    select pg_get_expr(d.adbin, d.adrelid) from pg_catalog.pg_attrdef d
    union all
    select pg_get_indexdef(i.indexrelid) from pg_catalog.pg_index i
    union all
    select v.definition from pg_catalog.pg_views v
     where v.schemaname in ('public', 'erp', 'erp_ref', 'erp_meta')
  ),
  expr_roots as (
    select f.oid, 'evaluated by a policy, constraint, default, index or view' as reason
      from expr_text e,
           regexp_matches(e.txt, '(erp[a-z_]*)\.([a-z][a-z0-9_]*)\(', 'g') m
      join fn f on f.ns = m[1] and f.proname = m[2]
  ),
  -- Root 4: registers the product dispatches from by name. A text scan cannot
  -- see execute format('select erp.%I(...)', h.sql_function).
  register_roots as (
    select f.oid, 'named in erp_ref.job_handler' from erp_ref.job_handler h
      join fn f on f.ns = 'erp' and f.proname = h.sql_function
    union all
    select f.oid, 'named in erp_ref.device_task_handler' from erp_ref.device_task_handler h
      join fn f on f.ns = 'erp' and f.proname = h.sql_function
    union all
    select f.oid, 'named in erp_ref.migration_domain' from erp_ref.migration_domain d
      join fn f on f.ns = 'erp' and f.proname in (d.loader_function, d.figure_function)
    union all
    select f.oid, 'named in erp_ref.scenario_completion' from erp_ref.scenario_completion c
      join fn f on f.ns = 'erp' and f.proname = c.sql_function
    union all
    select f.oid, 'named in erp_meta.diagnostic_check' from erp_meta.diagnostic_check d
      join fn f on f.ns = d.schema_name and f.proname in (d.function_name, d.detail_function)
  ),
  roots as (
    select * from door_roots
    union all select * from trigger_roots
    union all select * from expr_roots
    union all select * from register_roots
  ),
  -- Transitive: everything a reached routine's body mentions is reached too,
  -- with the reason of the first root that got there.
  reach as (
    select r.oid, r.reason from roots r
    union
    select e.callee, r.reason
      from reach r join edge e on e.caller = r.oid
  ),
  first_reason as (
    select r.oid, min(r.reason) as reason from reach r group by r.oid
  )
  select f.oid, f.ns, f.proname, f.oid::regprocedure::text, fr.reason
    from first_reason fr join fn f on f.oid = fr.oid
   order by f.ns, f.proname, f.oid;
$$;

comment on function erp.invoker_reach_report is
  'Every routine in the product schemas an authenticated session can reach, '
  'computed from the catalogue: invoker door bodies, trigger function bodies, '
  'policy and constraint expressions, dispatch registers, and everything those '
  'bodies mention in turn. The grants are derived from this and nothing else.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The generator: grant what is reached, revoke what is not
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.apply_execute_grants()
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  r        record;
  v_grants integer := 0;
begin
  -- PUBLIC holds nothing, anywhere in the product schemas.
  revoke execute on all routines in schema erp, erp_ref, erp_meta, erp_ai, erp_test, erp_ingress from public;

  -- The reach, granted.
  create temp table _reach on commit drop as select * from erp.invoker_reach_report();

  for r in select * from _reach loop
    execute format('grant execute on routine %s to authenticated, service_role', r.identity);
    v_grants := v_grants + 1;
  end loop;

  -- Anything authenticated or service_role may execute that the reach does
  -- not name loses the grant: a privilege with no reason is a privilege with
  -- no owner.
  for r in
    select p.oid::regprocedure::text as identity
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
       and (has_function_privilege('authenticated', p.oid, 'execute')
            or has_function_privilege('service_role', p.oid, 'execute'))
       and not exists (select 1 from _reach x where x.oid = p.oid)
  loop
    execute format('revoke execute on routine %s from authenticated, service_role', r.identity);
  end loop;

  -- The enquiry role keeps its four definers, and nothing else.
  grant execute on all functions in schema erp_ingress to clove_enquiry;

  -- The register mirrors the grants.
  delete from erp_meta.invoker_reach ir
   where not exists (select 1 from _reach x where x.identity = ir.identity);
  insert into erp_meta.invoker_reach (identity, schema_name, function_name, reason)
  select x.identity, x.schema_name, x.function_name, x.reason from _reach x
  on conflict (identity) do update set reason = excluded.reason;

  drop table _reach;
  return v_grants;
end;
$$;

comment on function erp.apply_execute_grants is
  'Grants EXECUTE to authenticated and service_role on exactly the routines '
  'erp.invoker_reach_report() names, revokes it from every other routine in the '
  'product schemas, revokes PUBLIC everywhere, and mirrors the result into '
  'erp_meta.invoker_reach. Idempotent; the build re-runs it and checks nothing moved.';

-- The default for a new routine is nothing. A migration that adds a door calls
-- the generator, and erp.assert_invoker_doors_executable() fails the build if
-- it forgot.
alter default privileges in schema erp        revoke execute on routines from public;
alter default privileges in schema erp_ref    revoke execute on routines from public;
alter default privileges in schema erp_meta   revoke execute on routines from public;
alter default privileges in schema erp_ai     revoke execute on routines from public;
alter default privileges in schema erp_test   revoke execute on routines from public;
alter default privileges in schema erp_ingress revoke execute on routines from public;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The assertions
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.execute_grant_report()
returns table(finding text, detail text)
language sql
stable
set search_path = ''
as $$
  with reach as materialized (select * from erp.invoker_reach_report())
  -- 1. PUBLIC may execute a routine. A NULL ACL is the default, and the
  --    default is PUBLIC.
  select 'PUBLIC may execute a routine in a product schema',
         format('%s — %s', p.oid::regprocedure::text,
                case when p.proacl is null then 'default ACL' else 'explicit PUBLIC grant' end)
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) a
                      where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
  union all
  -- 2. anon may execute a routine in a product schema. Its only route in is
  --    the enquiry role.
  select 'anon may execute a routine in a product schema', p.oid::regprocedure::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
     and p.proacl is not null
     and has_function_privilege('anon', p.oid, 'execute')
  union all
  -- 3. A reached routine authenticated cannot execute: a door that fails at
  --    runtime with "permission denied for function".
  select 'a routine an invoker door reaches is not executable by authenticated',
         format('%s (%s)', r.identity, r.reason)
    from reach r
   where not has_function_privilege('authenticated', r.oid, 'execute')
      or not has_function_privilege('service_role', r.oid, 'execute')
  union all
  -- 4. A routine authenticated may execute that nothing reaches: a grant with
  --    no reason.
  select 'authenticated may execute a routine nothing reaches', p.oid::regprocedure::text
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
     and p.proacl is not null
     and has_function_privilege('authenticated', p.oid, 'execute')
     and not exists (select 1 from reach r where r.oid = p.oid)
  union all
  -- 5. The register and the reach disagree.
  select 'erp_meta.invoker_reach does not match the computed reach',
         coalesce(r.identity, ir.identity)
    from reach r
    full join erp_meta.invoker_reach ir on ir.identity = r.identity
   where r.identity is null or ir.identity is null
  order by 1, 2;
$$;

create or replace function erp.assert_no_public_execute()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer;
  v_findings text;
begin
  select count(*), string_agg(format('  %s — %s', x.finding, x.detail), E'\n' order by x.detail)
    into v_count, v_findings
    from (
      select 'PUBLIC may execute a routine in a product schema' as finding,
             format('%s — %s', p.oid::regprocedure::text,
                    case when p.proacl is null then 'default ACL' else 'explicit PUBLIC grant' end) as detail
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
         and (p.proacl is null
              or exists (select 1 from aclexplode(p.proacl) a
                          where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
      union all
      select 'anon may execute a routine in a product schema', p.oid::regprocedure::text
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
         and p.proacl is not null
         and has_function_privilege('anon', p.oid, 'execute')
    ) x;
  if v_count > 0 then
    raise exception E'CLOVEERP_PUBLIC_EXECUTE: % finding(s)\n%', v_count, v_findings
      using errcode = '42501',
            hint = 'Run erp.apply_execute_grants() at the end of the migration that added the routine; the default for a new routine is nothing.';
  end if;
  return format('execute: no PUBLIC or anon grant on %s routine(s) in the product schemas',
    (select count(*) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')));
end;
$$;

comment on function erp.assert_no_public_execute is
  'No routine in erp, erp_ref, erp_meta, erp_ai, erp_test or erp_ingress is '
  'executable by PUBLIC or by anon. A NULL ACL is a finding: it is the default, '
  'and the default is PUBLIC.';

create or replace function erp.assert_invoker_doors_executable()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer;
  v_findings text;
begin
  select count(*), string_agg(format('  %s — %s', r.finding, r.detail), E'\n' order by r.finding, r.detail)
    into v_count, v_findings
    from erp.execute_grant_report() r
   where r.finding not in ('PUBLIC may execute a routine in a product schema',
                           'anon may execute a routine in a product schema');
  if v_count > 0 then
    raise exception E'CLOVEERP_EXECUTE_GRANTS_DRIFTED: % finding(s)\n%', v_count, v_findings
      using errcode = '42501',
            hint = 'The grants are derived from erp.invoker_reach_report(). Run erp.apply_execute_grants() and they match again.';
  end if;
  return format('execute: authenticated reaches %s routine(s), exactly as the register says',
    (select count(*) from erp_meta.invoker_reach));
end;
$$;

comment on function erp.assert_invoker_doors_executable is
  'Every routine an invoker door, trigger, expression or register reaches is '
  'executable by authenticated and service_role, nothing else is, and '
  'erp_meta.invoker_reach says the same. A new door whose callee was never '
  'granted fails here rather than at runtime.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('no_public_execute', 'No routine is executable by PUBLIC or anon', 'assertion', 'platform',
   'assert_no_public_execute', '', 'execute_grant_report', '',
   'Every routine in the product schemas has an explicit grant list; PUBLIC and anon are on none of them.', true, 55),
  ('execute_grants', 'Execute grants match the reach', 'assertion', 'platform',
   'assert_invoker_doors_executable', '', 'execute_grant_report', '',
   'authenticated and service_role may execute exactly the routines the doors, triggers, expressions and registers reach.', true, 56)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.grant_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_msg    text;
  v_n      integer;
  v_tenant uuid;
  v_admin  uuid;
  v_token  text;
  v_res    jsonb;
  v_docs   integer;
begin
  -- 1. PUBLIC holds nothing.
  v_cases := v_cases + 1;
  select count(*) into v_n
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'));
  case_name := 'PUBLIC may execute nothing in the product schemas';
  passed := v_n = 0;
  detail := format('%s routine(s) executable by PUBLIC', v_n);
  return next;

  -- 2. anon holds nothing.
  v_cases := v_cases + 1;
  select count(*) into v_n
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
     and has_function_privilege('anon', p.oid, 'execute');
  case_name := 'anon may execute nothing in the product schemas';
  passed := v_n = 0;
  detail := format('%s routine(s) executable by anon', v_n);
  return next;

  -- 3. authenticated holds exactly the reach.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.execute_grant_report()
   where finding not like 'PUBLIC%' and finding not like 'anon%';
  case_name := 'authenticated may execute the reach and nothing else';
  passed := v_n = 0;
  detail := format('%s drift finding(s); %s routine(s) in the register', v_n,
                   (select count(*) from erp_meta.invoker_reach));
  return next;

  -- 4. A suite body is outside the reach: nothing on the public API mentions
  --    erp_test, and the build is the only caller.
  v_cases := v_cases + 1;
  case_name := 'erp_test.isolation_suite is not executable by authenticated';
  passed := not has_function_privilege('authenticated', 'erp_test.isolation_suite()'::regprocedure, 'execute')
        and not has_function_privilege('service_role', 'erp_test.isolation_suite()'::regprocedure, 'execute');
  detail := 'the suites are the build''s, and no door reaches them';
  return next;

  -- 5. The doors work as authenticated. An organisation is provisioned; as
  --    the authenticated administrator, the demonstration is configured and a
  --    slice of history built through the history door, and then a purchase
  --    order is raised, approved, sent, received and posted through the
  --    SECURITY INVOKER doors — create, add line, transition, receive — which
  --    run erp.* as the caller. A callee the reach missed fails here as
  --    "permission denied for function", with the name.
  v_cases := v_cases + 1;
  v_msg := null;
  v_docs := 0;
  declare
    v_supplier uuid; v_site uuid; v_item uuid; v_po uuid; v_grn uuid; v_line uuid;
    v_journals integer := 0; v_moves integer := 0;
  begin
    select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zz-grant', 'Grant suite', 'admin@zz-grant.test', 'Grant Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    -- The authenticated subject is a real auth row: a person principal must
    -- have an email address, and the context reads it from auth.users.
    insert into auth.users (id, email)
    values ('00000000-0000-4000-8000-0000000000a1', 'admin@zz-grant.test');
    perform set_config('request.jwt.claims',
                       json_build_object('sub', '00000000-0000-4000-8000-0000000000a1')::text, true);
    perform erp.claim_invitation(v_token);

    execute 'set local role authenticated';
    begin
      -- Configures the organisation and builds five days of trading.
      v_res := public.erp_seed_demo_history((date_trunc('month', current_date) - interval '12 months')::date, null, 1);

      select pr.party_id into v_supplier from erp.party_role pr
       where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
      select s.id into v_site from erp.site s
       where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
      select i.id into v_item from erp.item i
       where i.tenant_id = v_tenant and i.attributes ? 'demo' order by i.code limit 1;

      v_po := (public.erp_create_document('purchase_order', v_supplier, v_site, 'GRANT-PO-1', current_date + 7) ->> 'document_id')::uuid;
      v_line := (public.erp_add_document_line(v_po, v_item, 10, 1250, 'Grant suite line') ->> 'line_id')::uuid;
      perform public.erp_transition_document(v_po, 'submit', 'grant suite');
      perform public.erp_transition_document(v_po, 'approve', 'grant suite');
      perform public.erp_transition_document(v_po, 'send', 'grant suite');
      v_grn := (public.erp_create_document('goods_receipt', v_supplier, v_site, 'GRANT-GRN-1', current_date) ->> 'document_id')::uuid;
      perform public.erp_receive_against(v_grn, v_line, 10, null);
      perform public.erp_transition_document(v_grn, 'post', 'grant suite');
      perform public.erp_transition_document(v_po, 'receive_all', 'grant suite');

      select count(*) into v_journals from erp.journal j where j.document_id = v_grn and j.status = 'posted';
      select count(*) into v_moves from erp.stock_movement m where m.document_id = v_grn;
    exception when others then
      v_msg := sqlerrm;
    end;
    execute 'reset role';

    select count(*) into v_docs from erp.document where tenant_id = v_tenant;
    if v_msg is null and (v_journals < 1 or v_moves < 1) then
      v_msg := format('the receipt posted %s journal(s) and %s movement(s)', v_journals, v_moves);
    end if;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'the spine runs through the invoker doors as authenticated';
  passed := v_msg is null and v_docs > 20;
  detail := coalesce(left(v_msg, 300), format('%s documents, a receipt posted to stock and ledger as authenticated, then undone', v_docs));
  return next;

  -- 6. A fresh routine with the default ACL is refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'create function erp.zz_default_acl() returns integer language sql as $f$ select 1 $f$';
    execute 'grant execute on function erp.zz_default_acl() to public';
    begin
      perform erp.assert_no_public_execute();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a routine PUBLIC may execute is refused';
  passed := v_msg like 'CLOVEERP_PUBLIC_EXECUTE:%' and v_msg like '%zz_default_acl%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 7. A grant nothing reaches is refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'grant execute on function erp_test.isolation_suite() to authenticated';
    begin
      perform erp.assert_invoker_doors_executable();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a grant nothing reaches is refused';
  passed := v_msg like 'CLOVEERP_EXECUTE_GRANTS_DRIFTED:%' and v_msg like '%isolation_suite%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 8. Everything undone.
  v_cases := v_cases + 1;
  case_name := 'every falsification was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-grant')
        and not exists (select 1 from pg_catalog.pg_proc where proname = 'zz_default_acl')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000a1')
        and not has_function_privilege('authenticated', 'erp_test.isolation_suite()'::regprocedure, 'execute');
  detail := 'no tenant, no auth row, no routine, no grant left behind';
  return next;

  if v_cases <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: grant_suite ran % cases, expected 8', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_grant_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _grant on commit drop as
    select * from erp_test.grant_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail
    from _grant;
  drop table _grant;
  if v_fail > 0 then
    raise exception E'CLOVEERP_GRANT_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: grant_suite ran % cases, expected 8', v_all;
  end if;
  return format('execute grants: %s/%s cases passed', v_all, v_all);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Apply, and prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

do $apply$
declare v_n integer;
begin
  v_n := erp.apply_execute_grants();
  if v_n < 400 then
    raise exception 'CLOVEERP_EXECUTE_REACH_UNRECOGNISED: the reach names % routine(s); a fresh build reaches about five hundred', v_n;
  end if;
  raise notice 'execute granted on % reached routine(s)', v_n;
end
$apply$;

select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp_test.assert_grant_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_legacy_refusal_prefix();

-- And the whole console, green.
do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
