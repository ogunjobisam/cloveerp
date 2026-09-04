-- ─────────────────────────────────────────────────────────────────────────────
-- The contact form stops running as postgres.
--
-- erp.record_enquiry() and the three routines around it were SECURITY INVOKER
-- with ACL postgres=X/postgres, and erp_meta.enquiry carries FORCE ROW LEVEL
-- SECURITY with no policy at all. Between them that means only a role with
-- BYPASSRLS can store an enquiry — so the Edge Function serving an
-- unauthenticated visitor on cloveerp.com held the most privileged connection
-- in the project. The boundary was the function's own code and nothing else.
--
-- The obvious repair does not work, and it is worth writing down why before
-- somebody tries it again:
--
--   * Making the four SECURITY DEFINER and granting them to a narrow role needs
--     that role to hold USAGE on schema erp.
--   * 731 of the 781 functions in erp have a NULL proacl, which in Postgres
--     means EXECUTE to PUBLIC. 139 of those are SECURITY DEFINER and run as
--     postgres.
--   * So granting USAGE on erp to any role hands it an escalation path to 139
--     definer frames. "Least privilege" would have been a decoration.
--
-- (That PUBLIC grant is latent rather than live — PostgREST exposes public, not
-- erp, and authenticated already holds USAGE on erp today. It is reported at the
-- end of this migration rather than repaired here: revoking PUBLIC across 731
-- functions on a live database is its own change with its own rehearsal.)
--
-- So the ingress gets its own doorway instead. erp_ingress is a schema with
-- exactly four functions in it and USAGE granted to exactly one role. The
-- wrappers are SECURITY DEFINER owned by postgres, which is what lets them
-- through the FORCE RLS the enquiry table carries; clove_enquiry can reach the
-- four and, having USAGE on nothing else, can reach nothing else at all.
--
-- What this is, precisely, so nobody over-reads it:
--
--   The function still CONNECTS as postgres, because SUPABASE_DB_URL is the
--   only connection the platform hands an Edge Function without somebody
--   copying a database password into a secret — and the last change removed
--   that step for good reasons. It then drops to clove_enquiry with SET LOCAL
--   ROLE inside every transaction, so the role doing the work is the narrow
--   one. That is privilege reduction the code enforces, not a boundary the
--   network enforces: code that ran RESET ROLE would climb back.
--
--   Making it a hard boundary is one step, and it is already wired: give
--   clove_enquiry LOGIN and a password, and set CLOVEERP_DATABASE_URL to its
--   connection string. The Edge Function needs no change — the override added
--   in the previous migration's companion commit exists for exactly this.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The role ─────────────────────────────────────────────────────────────────
--
-- NOLOGIN today: it is reached by SET LOCAL ROLE from a postgres session rather
-- than by connecting. Granting LOGIN and a password later needs no other change
-- here.

do $role$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'clove_enquiry') then
    create role clove_enquiry nologin nobypassrls noinherit;
  end if;
end
$role$;

comment on role clove_enquiry is
  'The contact form ingress. Holds USAGE on erp_ingress and EXECUTE on its four '
  'functions, and nothing else anywhere. Deliberately NOBYPASSRLS: the wrappers '
  'are SECURITY DEFINER, so this role never needs to see through row security '
  'itself.';

-- ── The doorway ──────────────────────────────────────────────────────────────

create schema if not exists erp_ingress;

comment on schema erp_ingress is
  'Everything an unauthenticated visitor can reach, and nothing else. One role '
  'holds USAGE here; erp itself grants USAGE to authenticated and EXECUTE to '
  'PUBLIC on most of its functions, which is why the ingress may not be pointed '
  'at erp directly.';

revoke all on schema erp_ingress from public;
grant usage on schema erp_ingress to clove_enquiry;

-- ── The four, and only the four ──────────────────────────────────────────────
--
-- Thin by design. Every refusal, every bound and the rate limit stay in
-- erp.record_enquiry(); a wrapper that grew a rule of its own would be a second
-- place to look when the form refuses something.

create or replace function erp_ingress.record_enquiry(
  p_full_name text, p_email text, p_message text, p_organisation text,
  p_source_page text, p_ip_hash text, p_user_agent text)
returns uuid
language sql
volatile
security definer
set search_path to ''
as $$
  select erp.record_enquiry(p_full_name, p_email, p_message, p_organisation,
                            p_source_page, p_ip_hash, p_user_agent)
$$;

create or replace function erp_ingress.enquiry_recipients()
returns table (email text, display_name text)
language sql
stable
security definer
set search_path to ''
as $$
  select r.email, r.display_name from erp.enquiry_recipients() r
$$;

create or replace function erp_ingress.complete_enquiry_notice(
  p_id uuid, p_provider_message_id text)
returns void
language sql
volatile
security definer
set search_path to ''
as $$
  select erp.complete_enquiry_notice(p_id, p_provider_message_id)
$$;

create or replace function erp_ingress.fail_enquiry_notice(p_id uuid, p_reason text)
returns void
language sql
volatile
security definer
set search_path to ''
as $$
  select erp.fail_enquiry_notice(p_id, p_reason)
$$;

-- A definer function created here would otherwise be EXECUTE-to-PUBLIC by
-- default, which is the very thing that made erp unusable as the doorway.
do $grants$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'erp_ingress'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to clove_enquiry', r.sig);
  end loop;
end
$grants$;

-- ── The guard has to be able to see the new schema ───────────────────────────
--
-- erp.isolation_report() reports any SECURITY DEFINER function not argued for
-- in erp_meta.security_definer_allowance, and it looked at erp, erp_ref,
-- erp_meta and erp_ai. A new schema holding four definer functions that the
-- register never sees is exactly the shape of hole this codebase keeps closing,
-- so the report learns the schema in the same migration that creates it.
--
-- The report is extended by rewriting the definition the database is actually
-- carrying, not by restating a body from memory. Restating it would silently
-- revert whatever later migrations taught it; twelve migrations have touched
-- this function and the next one will not know this file exists. The needle is
-- the schema list, it must appear exactly twice, and if it does not the
-- migration refuses rather than guessing.

do $extend$
declare
  v_definition text;
  v_needle     text := $needle$in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')$needle$;
  v_replaced   text := $replaced$in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_ingress')$replaced$;
  v_hits       integer;
begin
  v_definition := pg_get_functiondef('erp.isolation_report()'::regprocedure);

  v_hits := (length(v_definition) - length(replace(v_definition, v_needle, '')))
            / length(v_needle);

  if v_hits <> 2 then
    raise exception
      'CLOVEERP_ISOLATION_REPORT_UNRECOGNISED: expected the schema list twice in '
      'erp.isolation_report(), found %. The report has been rewritten since this '
      'migration was written and erp_ingress would not be covered.', v_hits;
  end if;

  execute replace(v_definition, v_needle, v_replaced);

  if position('erp_ingress' in
        pg_get_functiondef('erp.isolation_report()'::regprocedure)) = 0 then
    raise exception
      'CLOVEERP_ISOLATION_REPORT_UNRECOGNISED: erp.isolation_report() still does '
      'not mention erp_ingress after the rewrite.';
  end if;
end
$extend$;

-- ── Argued for, in the register that exists to be read ───────────────────────

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values
  ('erp_ingress', 'record_enquiry',
   'The contact form''s only way to store an enquiry. Definer because '
   'erp_meta.enquiry carries FORCE ROW LEVEL SECURITY with no policy, so a '
   'caller without BYPASSRLS cannot write it. Thin: every refusal, bound and the '
   'rate limit stay in erp.record_enquiry().'),
  ('erp_ingress', 'enquiry_recipients',
   'Reads erp_meta.platform_staff to find who to tell. Definer for the same FORCE '
   'RLS reason. Returns an address and a display name and nothing else.'),
  ('erp_ingress', 'complete_enquiry_notice',
   'Records the provider''s id for a message that was sent. Definer to write '
   'erp_meta.enquiry; refuses without an id, which is what stops a row claiming a '
   'delivery nothing produced.'),
  ('erp_ingress', 'fail_enquiry_notice',
   'Records why a send did not happen, so a stored lead is never silently '
   'unanswered. Definer for the same reason as the others.')
on conflict do nothing;

-- ── Prove it ─────────────────────────────────────────────────────────────────

do $prove$
declare v_n integer;
begin
  -- The role can reach the four.
  select count(*) into v_n
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp_ingress'
     and has_function_privilege('clove_enquiry', p.oid, 'EXECUTE');
  if v_n <> 4 then
    raise exception 'CLOVEERP_INGRESS_GRANTS_WRONG: clove_enquiry can execute % of 4', v_n;
  end if;

  -- And nothing else, anywhere. This is the whole claim of the change, so it is
  -- counted rather than assumed, and counted the way the server decides it: a
  -- function is reachable only if the caller holds USAGE on its schema AND
  -- EXECUTE on the function. Checking EXECUTE alone would answer yes for the
  -- 731 functions in erp whose ACL is null — EXECUTE to PUBLIC — none of which
  -- this role can name, because it holds USAGE on erp nowhere. Checking USAGE
  -- alone would miss public, where every role holds USAGE by default and the
  -- product's own door functions live.
  select count(*) into v_n
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname not in ('pg_catalog', 'information_schema', 'extensions')
     and has_schema_privilege('clove_enquiry', n.oid, 'USAGE')
     and has_function_privilege('clove_enquiry', p.oid, 'EXECUTE');
  if v_n <> 4 then
    raise exception
      'CLOVEERP_INGRESS_TOO_BROAD: clove_enquiry can reach % function(s), not 4', v_n
      using hint = 'The point of erp_ingress is that the ingress cannot name anything else.';
  end if;

  -- extensions is excluded above because the host, not this codebase, grants
  -- USAGE on it to PUBLIC: pgcrypto, btree_gist and pg_jsonschema come with the
  -- platform and every role in the cluster can already call them. What matters
  -- is that none of what the role can reach runs as somebody else, so the same
  -- question is asked again of SECURITY DEFINER functions with nothing excluded.
  select count(*) into v_n
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where p.prosecdef
     and n.nspname not in ('pg_catalog', 'information_schema')
     and has_schema_privilege('clove_enquiry', n.oid, 'USAGE')
     and has_function_privilege('clove_enquiry', p.oid, 'EXECUTE');
  if v_n <> 4 then
    raise exception
      'CLOVEERP_INGRESS_TOO_BROAD: clove_enquiry can reach % SECURITY DEFINER '
      'function(s), not 4', v_n;
  end if;

  -- No table, view or sequence at all: the four wrappers are the only way in,
  -- so a direct read of erp_meta.enquiry is not merely refused by row security,
  -- it is not expressible.
  select count(*) into v_n
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where c.relkind in ('r', 'p', 'v', 'm', 'f', 'S')
     and n.nspname not in ('pg_catalog', 'information_schema', 'extensions')
     and has_schema_privilege('clove_enquiry', n.oid, 'USAGE')
     and (has_table_privilege('clove_enquiry', c.oid, 'SELECT')
       or has_table_privilege('clove_enquiry', c.oid, 'INSERT')
       or has_table_privilege('clove_enquiry', c.oid, 'UPDATE')
       or has_table_privilege('clove_enquiry', c.oid, 'DELETE'));
  if v_n <> 0 then
    raise exception
      'CLOVEERP_INGRESS_TOO_BROAD: clove_enquiry can reach % relation(s), not 0', v_n;
  end if;

  -- It must not be able to see through row security on its own account.
  if exists (select 1 from pg_catalog.pg_roles
              where rolname = 'clove_enquiry' and (rolbypassrls or rolsuper or rolcreatedb
                 or rolcreaterole or rolcanlogin)) then
    raise exception 'CLOVEERP_INGRESS_TOO_STRONG: clove_enquiry has an attribute it does not need'
      using hint = 'Granting LOGIN is a deliberate later step and should also set a password '
                   'and CLOVEERP_DATABASE_URL; adjust this check when that happens.';
  end if;

  -- The migration runner can actually become it.
  --
  -- clove_enquiry has no LOGIN, so the only way anything runs as it is SET ROLE,
  -- and SET ROLE is checked against membership. postgres creates the role here
  -- and is granted admin over what it creates, so this holds — but if it ever
  -- stopped holding, the symptom would be every submission returning 500 while
  -- the migration reported success. That is precisely the class of failure this
  -- file exists to stop, so it is a refusal here instead.
  if not pg_catalog.pg_has_role(current_user, 'clove_enquiry', 'SET') then
    raise exception
      'CLOVEERP_INGRESS_UNASSUMABLE: % cannot SET ROLE clove_enquiry', current_user
      using hint = 'The contact form switches to this role before every '
                   'statement; without membership it cannot serve a submission.';
  end if;

  -- Nobody else got in by the default grant.
  select count(*) into v_n
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp_ingress'
     and (has_function_privilege('anon', p.oid, 'EXECUTE')
       or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  if v_n > 0 then
    raise exception 'CLOVEERP_INGRESS_PUBLICLY_CALLABLE: % function(s) reachable by anon or authenticated', v_n;
  end if;
end
$prove$;

-- ── The gate that would have caught it ───────────────────────────────────────
--
-- The privileges are proven above, from the catalogue. This proves the thing a
-- catalogue cannot: that the ingress still works when it runs as the role, and
-- that it stops working when it reaches past it. Both halves matter. A boundary
-- nothing exercises is a boundary somebody removes in six months because the
-- form broke and the quickest fix was to stop switching.
--
-- SECURITY INVOKER, alone among the suites in erp_test, because PostgreSQL
-- refuses SET ROLE inside a SECURITY DEFINER function — "cannot set parameter
-- role within security-definer function" — and a suite about which role the
-- statements run as has no way to ask the question without switching. It is
-- called by the migration runner and by CI, both of which are postgres; it is
-- revoked from everybody else, as the other suites are.

create or replace function erp_test.ingress_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_id    uuid;
  v_ok    boolean;
  v_msg   text;
  v_n     int;
  v_cases int := 0;
  c_msg constant text :=
    'We are a contract manufacturer and would like to see the planning module.';
begin
  -- ── It works as the role ──────────────────────────────────────────────────

  v_cases := v_cases + 1;
  set local role clove_enquiry;
  v_id := erp_ingress.record_enquiry('Ingress Suite', 'zzingress@zzing.test', c_msg,
                                     'Suite Ltd', '/contact', 'zzingress-1', 'suite/1.0');
  reset role;
  return query select 'the form stores an enquiry while running as clove_enquiry'::text,
    (select e.status = 'new' and e.organisation = 'Suite Ltd'
       from erp_meta.enquiry e where e.id = v_id),
    'the wrapper is definer, so erp_meta.enquiry''s forced row security is '
    'satisfied by the wrapper''s owner and not by the caller';

  -- ── And the wrapper is thin ───────────────────────────────────────────────

  v_cases := v_cases + 1;
  begin
    set local role clove_enquiry;
    perform erp_ingress.record_enquiry('Ingress Suite', 'zzingress2@zzing.test',
                                       'call me', null, null, 'zzingress-2', null);
    v_ok := false; v_msg := 'a two-word message was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_ENQUIRY_MESSAGE_TOO_SHORT%'; v_msg := left(sqlerrm, 70);
  end;
  reset role;
  return query select 'every refusal still arrives intact through it'::text, v_ok,
    v_msg || ' — the rules stayed in erp.record_enquiry(), where they were';

  v_cases := v_cases + 1;
  begin
    set local role clove_enquiry;
    perform erp_ingress.complete_enquiry_notice(v_id, '   ');
    v_ok := false; v_msg := 'notified with no provider id';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_ENQUIRY_NOTICE_UNIDENTIFIED%'; v_msg := left(sqlerrm, 70);
  end;
  reset role;
  return query select 'including the one that stops a row claiming a delivery'::text,
    v_ok, v_msg;

  -- ── It reaches nothing else ───────────────────────────────────────────────

  v_cases := v_cases + 1;
  begin
    set local role clove_enquiry;
    perform erp.record_enquiry('Ingress Suite', 'zzingress3@zzing.test', c_msg);
    v_ok := false; v_msg := 'erp.record_enquiry() was callable from the ingress';
  exception when others then
    v_ok := sqlerrm like 'permission denied for schema erp%'; v_msg := left(sqlerrm, 70);
  end;
  reset role;
  return query select 'the same routine one schema over is not merely refused'::text,
    v_ok, v_msg || ' — it cannot be named, which is a stronger thing than denied';

  v_cases := v_cases + 1;
  begin
    set local role clove_enquiry;
    select count(*) into v_n from erp_meta.enquiry;
    v_ok := false; v_msg := format('%s rows were readable', v_n);
  exception when others then
    v_ok := sqlerrm like 'permission denied for schema erp_meta%'; v_msg := left(sqlerrm, 70);
  end;
  reset role;
  return query select 'and the table behind the form cannot be read directly'::text,
    v_ok, v_msg;

  v_cases := v_cases + 1;
  begin
    set local role clove_enquiry;
    perform erp.assert_isolation();
    v_ok := false; v_msg := 'a platform assertion ran from the ingress';
  exception when others then
    v_ok := sqlerrm like 'permission denied for schema erp%'; v_msg := left(sqlerrm, 70);
  end;
  reset role;
  return query select 'nor anything else in erp, definer or not'::text, v_ok,
    v_msg || ' — 731 of those functions are EXECUTE to PUBLIC, and USAGE is '
             'what keeps every one of them out of reach';

  -- ── The role itself ───────────────────────────────────────────────────────

  v_cases := v_cases + 1;
  return query select 'the role has no attribute that would let it out'::text,
    exists (select 1 from pg_catalog.pg_roles r
             where r.rolname = 'clove_enquiry'
               and not r.rolbypassrls and not r.rolsuper and not r.rolcanlogin
               and not r.rolcreaterole and not r.rolcreatedb and not r.rolinherit),
    'no BYPASSRLS, so a definer wrapper is the only thing that satisfies '
    'forced row security; no LOGIN, so the switch is the only way in';

  -- ── Who gets told, through the doorway ────────────────────────────────────

  v_cases := v_cases + 1;
  insert into erp_meta.platform_staff (email, display_name, staff_role)
  values ('zzowner@zzing.test', 'Ingress Suite Owner', 'owner'),
         ('zzsupport@zzing.test', 'Ingress Suite Support', 'support');
  set local role clove_enquiry;
  select count(*) into v_n from erp_ingress.enquiry_recipients() r
   where r.email like '%@zzing.test';
  reset role;
  return query select 'the ingress can find who to tell, and only that'::text,
    v_n = 1,
    format('%s of the suite''s two staff rows — the wrapper returns an address '
           'and a display name, and nothing else about a person', v_n);

  -- ── The honest close ──────────────────────────────────────────────────────

  v_cases := v_cases + 1;
  set local role clove_enquiry;
  perform erp_ingress.fail_enquiry_notice(v_id, 'the suite: proving a failure is recorded');
  reset role;
  return query select 'and it can record that a send did not happen'::text,
    (select e.status = 'notification_failed' and e.failure_reason like 'the suite:%'
       from erp_meta.enquiry e where e.id = v_id),
    'a stored lead with no notification and no reason is what '
    'erp.assert_enquiries_answerable() refuses';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  delete from erp_meta.enquiry where email like '%@zzing.test';
  delete from erp_meta.platform_staff where email like '%@zzing.test';

  v_cases := v_cases + 1;
  return query select 'the suite leaves nothing behind'::text,
    not exists (select 1 from erp_meta.enquiry e where e.email like '%@zzing.test')
      and not exists (select 1 from erp_meta.platform_staff s
                       where s.email like '%@zzing.test'),
    'and the assertion is quiet again: ' || erp.assert_enquiries_answerable();

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: ingress_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.ingress_suite() from public, anon, authenticated;

create or replace function erp_test.assert_ingress_suite()
returns text
language plpgsql
security invoker
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _ingress on commit drop as
    select * from erp_test.ingress_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail from _ingress;
  if v_fail > 0 then
    raise exception E'CLOVEERP_INGRESS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001',
      hint = 'The contact form either cannot do its work as clove_enquiry, or '
             'can do work that is not its.';
  end if;
  return format('ingress: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_ingress_suite() from public, anon, authenticated;

-- Not registered in erp_meta.diagnostic_check: that register holds the checks
-- the platform console offers to run, and its kinds are 'assertion' and
-- 'report'. No suite is in it — erp_test.assert_enquiry_suite() is not either.
-- supabase/ci/run_checks.sh finds every zero-argument assert_* in erp and
-- erp_test from the catalogue, so this is picked up by being named like one,
-- and the workflow's explicit list names it as well.

select erp_test.assert_ingress_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_diagnostics_registered();
