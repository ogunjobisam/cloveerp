-- ─────────────────────────────────────────────────────────────────────────────
-- A rule that reads comments is reading the wrong thing.
--
-- 20260904730000 removed the dead `documents.read` gate from
-- public.erp_document_approval_chain and, since the door no longer writes,
-- declared it STABLE. That is correct. CI then failed it:
--
--   ERPWARE_AUTHORISING_DOOR_NOT_VOLATILE: a public door reaches
--   erp.authorise() ... but is declared stable
--
-- The door does not call erp.authorise(). What it contains is a comment saying
-- so — "No erp.authorise() here, deliberately" — and the rule matches function
-- names as text against the whole of prosrc, comments included.
--
-- This is the exact failure 20260904680000 named when it rejected the full
-- transitive closure: "matches names inside comments, and a rule that cries
-- wolf gets switched off". I wrote that down, then wrote a comment naming the
-- function inside a door the rule governs. The lesson is not that the comment
-- was careless. It is that a rule which forbids explaining itself is a rule
-- people will work around, and the limitation I recorded as unavoidable was
-- only unavoidable because nothing had tried to remove it.
--
-- So both text rules now read code rather than prose. erp.prosrc_code() strips
-- line and block comments before matching, and the two reports that match
-- names against a body use it.
--
-- Its own limit, stated rather than discovered: it strips `--` and `/* */`
-- wherever they appear, including inside a string literal that contains them.
-- For matching a schema-qualified function or table name that is harmless — a
-- literal holding "--" is not a call site — and the alternative is a SQL lexer
-- in plpgsql, which would be a worse thing to maintain than the false positive
-- it prevents.
--
-- The second mistake this fixes is procedural. 20260904730000 changed a door's
-- volatility and did not re-run erp.assert_authorising_doors_are_volatile() at
-- its end, so the migration passed and only the CI sweep caught it. Every
-- assertion that governs what a migration touched belongs at the end of that
-- migration; this one ends with the full set.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.prosrc_code(p_prosrc text)
returns text
language sql
immutable
set search_path = ''
as $$
  -- Block comments first: a `--` inside one is not a line comment.
  select regexp_replace(
           regexp_replace(coalesce(p_prosrc, ''), '/\*.*?\*/', ' ', 'gs'),
           '--[^\n]*', ' ', 'g');
$$;

comment on function erp.prosrc_code(text) is
  'A function body with its comments removed, for rules that match names as '
  'text. A name in a comment is not a call, and a rule that cannot tell the '
  'difference forbids explaining the code it governs.';

revoke all on function erp.prosrc_code(text) from public, anon;
grant execute on function erp.prosrc_code(text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- The two reports, now reading code.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.authorising_door_report()
returns table (door text, volatility text, finding text)
language sql
stable
set search_path = ''
as $$
  with writer as (
    -- The functions a door can reach that write, and what the write is. Adding
    -- a third means adding a row here, not rewriting the rule.
    select * from (values
      ('erp.authorise', 'writes an access-log row'),
      ('erp_meta.require_platform', 'binds the staff identity on first sight')
    ) as w(qname, what)
  ),
  fn as (
    select n.nspname || '.' || p.proname as qname, n.nspname as sch,
           erp.prosrc_code(p.prosrc) as code, p.provolatile, p.oid
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ai', 'erp_meta', 'erp_ref', 'public')
  ),
  reaches as (
    select w.qname, w.what from writer w
    union
    select f.qname, w.what
      from fn f join writer w on f.code ~ (replace(w.qname, '.', '\.') || '\s*\(')
  )
  select f.qname || '(' || pg_get_function_identity_arguments(f.oid) || ')',
         case f.provolatile when 's' then 'stable' else 'immutable' end,
         'a public door reaches ' || r.qname || '(), which ' || r.what
           || ', but is declared '
           || case f.provolatile when 's' then 'stable' else 'immutable' end
           || ', so PostgREST runs it in a read-only transaction and the call fails'
    from fn f
    join reaches r on f.code ~ (replace(r.qname, '.', '\.') || '\s*\(')
   where f.sch = 'public'
     and f.provolatile in ('s', 'i')
   group by 1, 2, 3
   order by 1;
$$;

revoke all on function erp.authorising_door_report() from public, anon;
grant execute on function erp.authorising_door_report() to authenticated, service_role;

create or replace function erp.caller_reachable_internal_report()
returns table (door text, via text, internal_table text)
language sql
stable
set search_path = ''
as $$
  with internal as (
    select tp.table_name
      from erp_meta.table_policy tp
     where tp.schema_name = 'erp_meta' and tp.table_class = 'platform_internal'
  ),
  invoker as (
    select n.nspname as sch, p.proname as nm, erp.prosrc_code(p.prosrc) as code,
           n.nspname || '.' || p.proname as fqn
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public')
       and not p.prosecdef
       and p.prorettype <> 'pg_catalog.trigger'::regtype
  ),
  doors as (select i.nm as door, i.code from invoker i where i.sch = 'public' and i.nm like 'erp\_%'),
  lvl1 as (
    select d.door, c.fqn as via, c.code
      from doors d join invoker c on d.code like '%' || c.fqn || '(%'
     where c.sch = 'erp'
  ),
  lvl2 as (
    select l.door, c.fqn as via, c.code
      from lvl1 l join invoker c on l.code like '%' || c.fqn || '(%'
     where c.sch = 'erp'
  ),
  reach as (
    select d.door, 'the door itself' as via, d.code from doors d
    union all select l.door, l.via, l.code from lvl1 l
    union all select l.door, l.via, l.code from lvl2 l
  )
  select distinct r.door, r.via, 'erp_meta.' || i.table_name
    from reach r cross join internal i
   where r.code like '%erp\_meta.' || i.table_name || '%'
   order by 1, 2, 3;
$$;

revoke all on function erp.caller_reachable_internal_report() from public, anon;
grant execute on function erp.caller_reachable_internal_report() to authenticated, service_role;

-- The suite gains the case that would have caught this before CI did.
create or replace function erp_test.prosrc_code_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
as $$
begin
  return query select 'a line comment naming a function is not a call to it',
    erp.prosrc_code('begin -- calls erp.authorise() but does not' || chr(10) || 'end;')
      !~ 'erp\.authorise\s*\(',
    'the name survives in prosrc and is gone from the code';

  return query select 'a block comment naming a function is not a call to it',
    erp.prosrc_code('begin /* erp.authorise() */ end;') !~ 'erp\.authorise\s*\(',
    'block comments are stripped before line comments, so -- inside one is safe';

  return query select 'a real call still reads as a call',
    erp.prosrc_code('begin perform erp.authorise(''x''); end;') ~ 'erp\.authorise\s*\(',
    'stripping comments does not strip code';

  return query select 'the door whose comment failed CI is clean now',
    (select count(*) = 0 from erp.authorising_door_report() r
      where r.door like 'public.erp_document_approval_chain%'),
    'it says it does not authorise, and is believed';

  return query select 'and it is still stable, because it still does not write',
    (select p.provolatile = 's' from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'erp_document_approval_chain'),
    'the fix was to the rule, not to the door';
end;
$$;

create or replace function erp_test.assert_prosrc_code_suite()
returns text
language plpgsql
as $$
declare v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not s.passed), count(*),
         string_agg(format('  %s: %s', s.case_name, s.detail), E'\n') filter (where not s.passed)
    into v_failed, v_total, v_detail
    from erp_test.prosrc_code_suite() s;

  if v_failed > 0 then
    raise exception E'ERPWARE_PROSRC_CODE_SUITE: % of % case(s) failed\n%',
      v_failed, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('prosrc code: %s of %s cases pass', v_total, v_total);
end;
$$;

-- Every assertion that governs what this migration touched, at its end.
select erp.assert_authorising_doors_are_volatile();
select erp.assert_no_caller_reachable_internals();
select erp.assert_authorise_codes_exist();
select erp.assert_public_api_safe();
select erp_test.assert_prosrc_code_suite();
select erp_test.assert_caller_reachable_internal_suite();
select erp_test.assert_authorise_code_suite();
