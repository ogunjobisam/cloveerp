-- The linter is a register.
--
-- The host runs a security linter over this database and reports what it
-- finds on a dashboard nobody's build reads. One finding has been acted on in
-- the product's history (20260830072141 pinned a search path "the linter
-- flagged"); no finding has ever been recorded, and nothing says whether the
-- rest were fixed, accepted or never looked at. A finding that is neither
-- fixed nor registered with a reason is a finding that will be rediscovered
-- by the next person, who will not know whether it was ever seen.
--
-- So the lints the linter runs that can be decided from the catalogue are
-- decided here, on every build, and the register says what is accepted and
-- why. erp.linter_report() reproduces them: a routine without a pinned search
-- path; a view that is not SECURITY INVOKER; a table in public without row
-- security, or with a policy and row security off; row security with no
-- policy; auth.users reached from public; an extension installed in public;
-- more than one permissive policy for one role and action; a table without a
-- primary key; two indexes on the same columns; a public function anon may
-- execute. erp_meta.linter_finding_allowance names the findings that are
-- accepted, by lint and object pattern, with a rationale of at least forty
-- characters; erp.assert_linter_clean() fails the build on a finding that is
-- not allowed and on an allowance that matches nothing, so the register cannot
-- go stale in either direction.
--
-- What a fresh build finds, and what this migration does about it:
--
--   * Eleven erp_test functions and one procedure without a pinned search
--     path. The functions are pinned here. The procedure,
--     erp_test.assert_context_not_leaked, cannot be: a procedure that commits
--     may not carry a SET clause, and erp.assert_transaction_control_routines()
--     already fails the build if one does. It is allowed, with that reason.
--   * Thirty-seven erp_meta tables with row security on and no policy. That is
--     the platform_internal class by construction — deny everything, reach
--     the data through a definer that checks platform staff — and
--     erp.assert_isolation() enforces it. Allowed as a class, with that reason.
--   * Eight pairs of indexes on identical columns, each a unique constraint's
--     index beside a plain index created by hand on the same key. The plain
--     eight are dropped; the constraints stay.
--
-- What the linter sees that this cannot — auth, storage and the host's own
-- schemas, leaked-password protection, MFA settings — is read from the host
-- when the connector is authorised, and each such finding is fixed or added
-- to the same register. The register is the record either way.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.linter_finding_allowance (
  lint           text not null,
  object_pattern text not null,     -- LIKE pattern over schema.object
  rationale      text not null,
  registered_at  timestamptz not null default now(),
  primary key (lint, object_pattern),
  constraint linter_allowance_explains check (length(btrim(rationale)) >= 40)
);

comment on table erp_meta.linter_finding_allowance is
  'Linter findings that are accepted, by lint and object pattern, each with a '
  'reason. erp.assert_linter_clean() refuses a finding that is not here and an '
  'allowance that matches no finding, so the register can go stale in neither '
  'direction.';

select erp_meta.register_table('erp_meta', 'linter_finding_allowance', 'platform_internal',
  'Accepted linter findings with their reasons. Not tenant data.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The lints, decided from the catalogue
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.linter_report()
returns table(lint text, level text, object text, detail text, allowed boolean)
language sql
stable
set search_path = ''
as $$
  with product as (
    select unnest(array['public', 'erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress']) as ns
  ),
  findings as (
    -- A routine whose search path is not pinned resolves names through
    -- whatever the caller set, which is how a function is hijacked.
    select 'function_search_path_mutable' as lint, 'WARN' as level,
           n.nspname || '.' || p.proname as object,
           'no search_path in the routine''s configuration' as detail
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      join product on product.ns = n.nspname
     where p.prokind in ('f', 'p')
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
    union all
    -- A view that is not SECURITY INVOKER runs as its owner and bypasses the
    -- row security of the tables it reads.
    select 'security_definer_view', 'ERROR', v.schemaname || '.' || v.viewname,
           'view without security_invoker = true'
      from pg_catalog.pg_views v
      join pg_catalog.pg_class c on c.relname = v.viewname
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace and n.nspname = v.schemaname
      join product on product.ns = v.schemaname
     where not coalesce((select o.option_value::boolean
                           from pg_catalog.pg_options_to_table(c.reloptions) o
                          where o.option_name = 'security_invoker'), false)
    union all
    select 'rls_disabled_in_public', 'ERROR', n.nspname || '.' || c.relname,
           'table in public without row security'
      from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
    union all
    select 'policy_exists_rls_disabled', 'ERROR', n.nspname || '.' || c.relname,
           'a policy exists but row security is off, so it does nothing'
      from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      join product on product.ns = n.nspname
     where c.relkind = 'r' and not c.relrowsecurity
       and exists (select 1 from pg_catalog.pg_policy p where p.polrelid = c.oid)
    union all
    select 'rls_enabled_no_policy', 'INFO', n.nspname || '.' || c.relname,
           'row security is on and no policy exists: nothing but a bypassing role can read it'
      from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      join product on product.ns = n.nspname
     where c.relkind = 'r' and c.relrowsecurity
       and not exists (select 1 from pg_catalog.pg_policy p where p.polrelid = c.oid)
    union all
    select 'auth_users_exposed', 'ERROR', v.schemaname || '.' || v.viewname,
           'a view in public reads auth.users'
      from pg_catalog.pg_views v
     where v.schemaname = 'public' and v.definition ilike '%auth.users%'
    union all
    select 'extension_in_public', 'WARN', 'public.' || e.extname,
           'extension installed in the public schema'
      from pg_catalog.pg_extension e join pg_catalog.pg_namespace n on n.oid = e.extnamespace
     where n.nspname = 'public'
    union all
    select 'multiple_permissive_policies', 'WARN',
           x.relid::regclass::text || ' [' || x.polcmd::text || ' for ' || x.rolename || ']',
           format('%s permissive policies for one role and action', x.n)
      from (select p.polrelid as relid, p.polcmd,
                   case when r = 0 then 'public' else r::regrole::text end as rolename, count(*) as n
              from pg_catalog.pg_policy p
              join pg_catalog.pg_class c on c.oid = p.polrelid
              join pg_catalog.pg_namespace n on n.oid = c.relnamespace
              join product on product.ns = n.nspname,
                   unnest(p.polroles) r
             where p.polpermissive
             group by 1, 2, 3 having count(*) > 1) x
    union all
    select 'no_primary_key', 'INFO', n.nspname || '.' || c.relname, 'table without a primary key'
      from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      join product on product.ns = n.nspname
     where c.relkind = 'r'
       and not exists (select 1 from pg_catalog.pg_constraint k where k.conrelid = c.oid and k.contype = 'p')
    union all
    select 'duplicate_index', 'WARN', x.rel::regclass::text,
           'indexes on identical columns: ' || x.names
      from (select i.indrelid as rel,
                   string_agg(i.indexrelid::regclass::text, ' + ' order by i.indexrelid::regclass::text) as names
              from pg_catalog.pg_index i
              join pg_catalog.pg_class c on c.oid = i.indrelid
              join pg_catalog.pg_namespace n on n.oid = c.relnamespace
              join product on product.ns = n.nspname
             group by i.indrelid, i.indkey::text, i.indclass::text,
                      coalesce(pg_get_expr(i.indexprs, i.indrelid), ''),
                      coalesce(pg_get_expr(i.indpred, i.indrelid), '')
            having count(*) > 1) x
    union all
    select 'anon_executable_function', 'ERROR', p.oid::regprocedure::text,
           'a public function anon may execute'
      from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and has_function_privilege('anon', p.oid, 'execute')
  )
  select f.lint, f.level, f.object, f.detail,
         exists (select 1 from erp_meta.linter_finding_allowance a
                  where a.lint = f.lint and f.object like a.object_pattern) as allowed
    from findings f
   order by f.level, f.lint, f.object;
$$;

comment on function erp.linter_report is
  'The host''s security lints that can be decided from the catalogue, run on '
  'every build, each marked allowed when erp_meta.linter_finding_allowance '
  'accepts it with a reason.';

create or replace function erp.assert_linter_clean()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_open  integer;
  v_stale integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s %s: %s — %s', r.level, r.lint, r.object, r.detail), E'\n' order by r.level, r.lint, r.object)
    into v_open, v_detail
    from erp.linter_report() r
   where not r.allowed;
  if v_open > 0 then
    raise exception E'CLOVEERP_LINTER_FINDINGS: % finding(s) neither fixed nor registered\n%', v_open, v_detail
      using errcode = '23514',
            hint = 'Fix the finding in a migration, or register it in erp_meta.linter_finding_allowance with the reason it is accepted.';
  end if;

  select count(*), string_agg(format('  %s %s', a.lint, a.object_pattern), E'\n')
    into v_stale, v_detail
    from erp_meta.linter_finding_allowance a
   where not exists (select 1 from erp.linter_report() r where r.lint = a.lint and r.object like a.object_pattern);
  if v_stale > 0 then
    raise exception E'CLOVEERP_LINTER_ALLOWANCE_STALE: % allowance(s) match no finding\n%', v_stale, v_detail
      using errcode = '23514',
            hint = 'The finding it excused is gone; delete the allowance so the register says only what is true.';
  end if;

  return format('linter: %s finding(s), all registered with a reason; %s allowance(s)',
    (select count(*) from erp.linter_report()),
    (select count(*) from erp_meta.linter_finding_allowance));
end;
$$;

comment on function erp.assert_linter_clean is
  'Every linter finding the catalogue can decide is fixed or registered with a '
  'reason, and every registered allowance still excuses a real finding.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('linter_clean', 'Linter findings are fixed or registered', 'assertion', 'platform',
   'assert_linter_clean', '', 'linter_report', '',
   'The host''s security lints decided from the catalogue: every finding is fixed or accepted with a written reason.', true, 57)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. What a fresh build finds, fixed or registered
-- ═════════════════════════════════════════════════════════════════════════════

-- Pin the search path on every routine in the product schemas that lacks one,
-- except a procedure: a procedure that commits may not carry a SET clause.
do $pin$
declare
  r record;
  v_n integer := 0;
begin
  for r in
    select p.oid, p.oid::regprocedure::text as identity
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
       and p.prokind = 'f'
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    execute format('alter function %s set search_path = ''''', r.identity);
    v_n := v_n + 1;
  end loop;
  raise notice 'search_path pinned on % routine(s)', v_n;
end
$pin$;

-- Drop the plain index of every duplicated pair, keeping the constraint's. In
-- the product's schemas only: the host has schemas of its own (storage, auth,
-- realtime) with duplicates of their own, which are not ours to drop and
-- which the migration role does not own.
do $dup$
declare
  r record;
  v_n integer := 0;
begin
  for r in
    select i.indexrelid
      from pg_catalog.pg_index i
      join pg_catalog.pg_class t on t.oid = i.indrelid
      join pg_catalog.pg_namespace n on n.oid = t.relnamespace
      join (select indrelid, indkey::text as k, indclass::text as c,
                   coalesce(pg_get_expr(indexprs, indrelid), '') as e,
                   coalesce(pg_get_expr(indpred, indrelid), '') as p
              from pg_catalog.pg_index
             group by 1, 2, 3, 4, 5 having count(*) > 1) d
        on d.indrelid = i.indrelid and d.k = i.indkey::text and d.c = i.indclass::text
       and d.e = coalesce(pg_get_expr(i.indexprs, i.indrelid), '')
       and d.p = coalesce(pg_get_expr(i.indpred, i.indrelid), '')
     where n.nspname in ('public', 'erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
       and not exists (select 1 from pg_catalog.pg_constraint k where k.conindid = i.indexrelid)
  loop
    execute format('drop index %s', r.indexrelid::regclass);
    v_n := v_n + 1;
  end loop;
  if v_n <> 8 then
    raise exception 'CLOVEERP_DUPLICATE_INDEXES_UNRECOGNISED: expected to drop 8 plain duplicate indexes, dropped %', v_n;
  end if;
end
$dup$;

insert into erp_meta.linter_finding_allowance (lint, object_pattern, rationale) values
  ('function_search_path_mutable', 'erp_test.assert_context_not_leaked',
   'A procedure that commits may not carry a SET clause; erp.assert_transaction_control_routines() '
   'fails the build if one does. It runs only from the build, as the owner, with the build''s own search path.'),
  ('rls_enabled_no_policy', 'erp_meta.%',
   'The platform_internal class by construction: row security on, no policy, so no session role reads '
   'the table and the only route to it is a SECURITY DEFINER that checks platform staff. '
   'erp.assert_isolation() enforces the class; a policy here would be a hole, not a fix.')
on conflict (lint, object_pattern) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.linter_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases integer := 0;
  v_msg   text;
  v_n     integer;
begin
  -- 1. Clean.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.linter_report() where not allowed;
  case_name := 'every finding is fixed or registered';
  passed := v_n = 0;
  detail := format('%s unregistered finding(s)', v_n);
  return next;

  -- 2. A routine without a search path is found and refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'create function erp.zz_unpinned() returns integer language sql as $f$ select 1 $f$';
    begin
      perform erp.assert_linter_clean();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a routine with no pinned search path is refused';
  passed := v_msg like 'CLOVEERP_LINTER_FINDINGS:%' and v_msg like '%function_search_path_mutable: erp.zz_unpinned%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 3. A duplicate index is found and refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'create index zz_dup_idx on erp.journal (tenant_id, id)';
    begin
      perform erp.assert_linter_clean();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an index duplicating a constraint''s is refused';
  passed := v_msg like 'CLOVEERP_LINTER_FINDINGS:%' and v_msg like '%duplicate_index: erp.journal%zz_dup_idx%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 4. A policy on a table with row security off is refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    execute 'alter table erp_meta.linter_finding_allowance disable row level security';
    execute 'create policy zz_dead on erp_meta.linter_finding_allowance for select using (true)';
    begin
      perform erp.assert_linter_clean();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a policy on a table whose row security is off is refused';
  passed := v_msg like 'CLOVEERP_LINTER_FINDINGS:%' and v_msg like '%policy_exists_rls_disabled: erp_meta.linter_finding_allowance%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 5. An allowance that excuses nothing is refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    insert into erp_meta.linter_finding_allowance (lint, object_pattern, rationale)
    values ('duplicate_index', 'erp.zz_nothing', 'An allowance for a finding that does not exist, to prove the register cannot go stale.');
    begin
      perform erp.assert_linter_clean();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'an allowance that matches no finding is refused';
  passed := v_msg like 'CLOVEERP_LINTER_ALLOWANCE_STALE:%' and v_msg like '%erp.zz_nothing%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 6. Undone.
  v_cases := v_cases + 1;
  case_name := 'every falsification was undone';
  passed := not exists (select 1 from pg_catalog.pg_proc where proname = 'zz_unpinned')
        and not exists (select 1 from pg_catalog.pg_class where relname = 'zz_dup_idx')
        and not exists (select 1 from pg_catalog.pg_policy where polname = 'zz_dead')
        and (select relrowsecurity from pg_catalog.pg_class where oid = 'erp_meta.linter_finding_allowance'::regclass)
        and not exists (select 1 from erp_meta.linter_finding_allowance where object_pattern = 'erp.zz_nothing');
  detail := 'no routine, index, policy or allowance left behind; row security back on';
  return next;

  if v_cases <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: linter_suite ran % cases, expected 6', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_linter_suite()
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
  create temp table if not exists _linter on commit drop as
    select * from erp_test.linter_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail
    from _linter;
  drop table _linter;
  if v_fail > 0 then
    raise exception E'CLOVEERP_LINTER_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: linter_suite ran % cases, expected 6', v_all;
  end if;
  return format('linter: %s/%s cases passed', v_all, v_all);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_execute_grants();

select erp.assert_linter_clean();
select erp_test.assert_linter_suite();

-- The suites whose search path was pinned still run.
select erp_test.assert_authorise_code_suite();
select erp_test.assert_caller_reachable_internal_suite();
select erp_test.assert_email_delivery_suite();
select erp_test.assert_prosrc_code_suite();
select erp_test.assert_provisioning_window_suite();
select erp_test.assert_support_entry_suite();
select erp_test.assert_authorising_doors_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_transaction_control_routines();
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
