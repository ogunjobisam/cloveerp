-- Assurance walks from the far end.
--
-- deploy.yml proves every release with erp.platform_assurance(), which runs
-- every registered assertion in one statement. Its function-level
-- statement_timeout is 55 seconds (20260902121206), and on live it took 37.0 s
-- (release 47712762, 14 September 03:32 UTC), then 40.0, 45.1, 46.0 and, after
-- 20260914062000 to 065000 were applied together, 63.3 s (release 4dbdc4c0,
-- 06:45). The deploy calls it from psql, which that timeout did not stop. The
-- platform console calls it through the data API.
--
-- The build's catalogue step prints a timestamp per line, so the cost of each
-- registered check on a built database could be read without one to hand.
-- Build-and-assert job 103882265615 (main at 2f4b891, the commit live took
-- 63.3 s on) ran the 81 platform-scoped registered assertions in 15.8 s, each
-- in its own psql session. Three of them were 10.7 s of that:
--
--   authorising_doors            4.95 s   erp.assert_authorising_doors_are_volatile
--   caller_reachable_internals   3.33 s   erp.assert_no_caller_reachable_internals
--   intelligence_boundary        2.39 s   erp.assert_intelligence_boundary
--
-- The next ten took 0.1 to 0.5 s each, and the other 68 took no longer than
-- the psql session that ran them. The same three led on the build of
-- 26975d8e (12.0 of 18.2 s), so the cost is theirs, not that day's. The
-- build's total held at 16 to 18 s while live went from 37 to 63 s, so live
-- multiplies whatever these do. Cutting what they do is the lever.
--
-- WHAT EACH ONE WAS DOING
--
--   authorising_doors. erp.authorising_door_report() matched every stable or
--   immutable public door against every function that reaches a writer, about
--   170 doors by 700 functions, each with a regular expression built from the
--   function's name. Seven hundred patterns go through a compiled-expression
--   cache of 32, so nearly every match compiled its pattern first. Then the
--   assertion did it again over all 625 doors, on the raw body, only to count
--   the doors for its sentence.
--
--   caller_reachable_internals. erp.caller_reachable_internal_report() started
--   at 560 doors, matched each against every invoker erp function, then matched
--   every one of those hops against every invoker erp function again, carrying
--   each body along, and only at the end asked which of them named a
--   platform-internal table.
--
--   intelligence_boundary. erp.intelligence_boundary_report() built the whole
--   call graph of erp, erp_ref, erp_ai and erp_meta, 1,100 functions squared
--   searches, walked it to depth 12 from every transaction-path function, and
--   then kept the walks that ended in erp_ai. Nothing outside erp_ai calls
--   erp_ai.
--
-- And one that is cheap here and is not for everybody. vocabulary_aligned
-- (0.13 s on that build) calls public.erp_resources() three times, and that
-- door called erp.current_tenant_id() once for every product row: about 23,000
-- calls, each running erp.principal_context(). With no one signed in, as in
-- the build and the deploy, that returns at once. For the console, which asks
-- as a signed-in member of staff, and for every screen that loads its words,
-- each call looks the principal up. It is the per-row trap RLS policies are
-- known for (20260913110000), met in a door.
--
-- WHAT THEY DO NOW, AND WHY THE ROWS ARE THE SAME
--
-- Every predicate below is the one it replaces, character for character: the
-- same regular expressions, the same LIKE patterns with their underscores
-- still wildcards, the same position() on the raw body. What changed is which
-- pairs get asked.
--
--   authorising_doors. A match of 'schema\.name\s*\(' is a dot, the name, any
--   whitespace and a bracket, so '\.(\w+)\s*\(' finds that name in the body
--   too; the names a door calls are read with one fixed expression, and only
--   the reaching functions carrying one of those names are tested with the
--   original pattern. A superset of the candidates, then the same test: the
--   same findings and the same count, from a few hundred matches instead of
--   half a million.
--
--   caller_reachable_internals. Walked back, as the routine report beside it
--   is (20260913090000): the invoker functions whose code names a
--   platform-internal table, the invoker erp functions that call one of those,
--   and only then the doors that call either.
--
--   intelligence_boundary. Walked back from erp_ai: the functions that can
--   reach it at any distance, the calls between those, and the depth-12 walk
--   over that small graph. Every step of a walk that ends in erp_ai calls
--   something that reaches erp_ai, so no walk the old graph held is missing
--   from the small one.
--
--   vocabulary_aligned. Each locale's bundle is asked for once. The door asks
--   for the organisation once per call rather than once per row.
--
-- The narrowing is only real if the planner cannot undo it. Each set of
-- candidates is materialized, or searched in a subquery kept from being
-- flattened, before the expensive test is asked of it. Written as plain joins
-- (20260914071000 on the build, never applied anywhere), the planner put the
-- pattern first: authorising_doors still took 4.8 s and intelligence_boundary
-- 4.4. And the build of 14800bc, the pull request that brought
-- 20260914065000, spent 154 s on the old caller_reachable_internals where
-- main spent 3.3: that is how far a plan can wander.
--
-- The suite below does not take that on trust. It keeps the old queries as
-- they were written and compares every row with the new ones, over the whole
-- catalogue with fixtures added that each report must find: a door that
-- gates directly, one hop away, through erp_meta.require_platform(), with
-- whitespace before the bracket and inside a longer word; a table read by the
-- door, one and two invoker hops away, and through a LIKE wildcard; a
-- transaction path that reaches erp_ai at depth 2 and round a cycle at every
-- even depth to 12. It runs in the build's catalogue and not at the end of
-- this file: the old walks it keeps are the cost this file takes out of live,
-- 25 s of them on the build, and a deploy has no business spending a minute or
-- two on live proving what the build proved of the same functions.
--
-- NOTHING MOVED TO THE BUILD ONLY
--
-- Some of these read only the catalogue, and a catalogue only changes by
-- migration, which the build has proved before the deploy applies it. They
-- still run live. Live is the database the Supabase GitHub integration applied
-- migrations to beside deploy.yml until 13 September, and the one the
-- connector built before replay existed; a structural check is how live is
-- shown to be what the build built. Made cheap, they can stay.
--
-- AND HOW LONG EACH TOOK
--
-- erp.run_diagnostic() now says, in elapsed_ms, how long a check and its
-- detail report took. deploy.yml prints the slowest from the proof it already
-- runs, and the build prints every one from a run of its own, so the next
-- deploy shows what live spends and where.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Doors that reach a writer: the names a door calls, then the pattern
-- ═════════════════════════════════════════════════════════════════════════════

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
  fn as materialized (
    select n.nspname || '.' || p.proname as qname, p.proname, n.nspname as sch,
           erp.prosrc_code(p.prosrc) as code, p.provolatile, p.oid
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ai', 'erp_meta', 'erp_ref', 'public')
  ),
  reaches as materialized (
    select w.qname, split_part(w.qname, '.', 2) as proname, w.what from writer w
    union
    select f.qname, f.proname, w.what
      from fn f join writer w on f.code ~ (replace(w.qname, '.', '\.') || '\s*\(')
  ),
  door as materialized (
    select f.qname, f.code, f.provolatile, f.oid
      from fn f
     where f.sch = 'public'
       and f.provolatile in ('s', 'i')
  ),
  -- Every name a door's code calls. A body matching 'schema\.name\s*\(' has
  -- '.name', whitespace and a bracket in it, which this reads with one
  -- expression; the per-name pattern below is then asked only of those names.
  called as materialized (
    select distinct d.oid, m[1] as proname
      from door d
     cross join lateral regexp_matches(d.code, '\.(\w+)\s*\(', 'g') m
  ),
  -- The pairs, before any pattern is asked. Materialized because otherwise the
  -- planner is free to match every door against every reaching function first
  -- and join the names afterwards, which is the old cost with extra steps: the
  -- first version of this file did exactly that on the build.
  candidate as materialized (
    select d.qname, d.code, d.provolatile, d.oid, r.qname as reach, r.what
      from called c
      join door d on d.oid = c.oid
      join reaches r on r.proname = c.proname
  )
  select k.qname || '(' || pg_get_function_identity_arguments(k.oid) || ')',
         case k.provolatile when 's' then 'stable' else 'immutable' end,
         'a public door reaches ' || k.reach || '(), which ' || k.what
           || ', but is declared '
           || case k.provolatile when 's' then 'stable' else 'immutable' end
           || ', so PostgREST runs it in a read-only transaction and the call fails'
    from candidate k
   where k.code ~ (replace(k.reach, '.', '\.') || '\s*\(')
   group by 1, 2, 3
   order by 1;
$$;

create or replace function erp.assert_authorising_doors_are_volatile()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
  v_doors    integer;
  v_reach    integer;
begin
  select count(*), string_agg(format('  %s [%s]', r.finding, r.door), E'\n' order by r.door)
    into v_count, v_findings
    from erp.authorising_door_report() r;
  if v_count > 0 then
    raise exception E'CLOVEERP_AUTHORISING_DOOR_NOT_VOLATILE: % finding(s)\n%', v_count, v_findings
      using errcode = 'P0001',
            hint = 'Declare the door volatile. Reaching erp.authorise() or '
                   'erp_meta.require_platform() means writing, and PostgREST honours a '
                   'stable declaration by opening a read-only transaction.';
  end if;

  select count(*) into v_doors
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'erp\_%';

  -- The count for the sentence, over the raw body as it always was: the names
  -- each public function calls first, then the pattern for those names only.
  with writer as (
    select * from (values ('erp.authorise'), ('erp_meta.require_platform')) as w(qname)
  ),
  fn as materialized (
    select n.nspname || '.' || p.proname as qname, p.proname, n.nspname as sch, p.prosrc, p.oid
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ai', 'erp_meta', 'erp_ref', 'public')
  ),
  reaches as materialized (
    select w.qname, split_part(w.qname, '.', 2) as proname from writer w
    union
    select f.qname, f.proname from fn f join writer w on f.prosrc ~ (replace(w.qname, '.', '\.') || '\s*\(')
  ),
  called as materialized (
    select distinct f.oid, m[1] as proname
      from fn f
     cross join lateral regexp_matches(f.prosrc, '\.(\w+)\s*\(', 'g') m
     where f.sch = 'public'
  ),
  candidate as materialized (
    select f.qname, f.prosrc, r.qname as reach
      from called c
      join fn f on f.oid = c.oid
      join reaches r on r.proname = c.proname
  )
  select count(distinct k.qname) into v_reach
    from candidate k
   where k.prosrc ~ (replace(k.reach, '.', '\.') || '\s*\(');

  return format('doors: %s public entry points, %s reach a writer within one call and every one of those is volatile',
                v_doors, v_reach);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Doors that read platform-internal data as the caller: from the table back
-- ═════════════════════════════════════════════════════════════════════════════

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
  invoker as materialized (
    select n.nspname as sch, p.proname as nm, erp.prosrc_code(p.prosrc) as code,
           n.nspname || '.' || p.proname as fqn
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public')
       and not p.prosecdef
       and p.prorettype <> 'pg_catalog.trigger'::regtype
  ),
  -- Every invoker function whose own code names a platform-internal table. A
  -- body that names one names erp_meta first, so only those are matched per table.
  reads as materialized (
    select i.sch, i.nm, i.fqn, t.table_name
      from invoker i
      join internal t on i.code like '%erp\_meta.' || t.table_name || '%'
     where i.code like '%erp\_meta.%'
  ),
  -- The invoker erp function a door calls to get there, and the one that reads:
  -- the reader itself (a door's first hop), or a function that calls the reader
  -- (the second).
  carrier as materialized (
    select r.fqn as callee, r.fqn as via, r.table_name
      from reads r
     where r.sch = 'erp'
    union
    select c.fqn, r.fqn, r.table_name
      from reads r
      join invoker c on c.sch = 'erp' and c.code like '%' || r.fqn || '(%'
     where r.sch = 'erp'
  ),
  -- Each door is asked once per function it might call, however many tables
  -- that function leads to.
  door_calls as (
    select d.nm, c.callee
      from (select distinct k.callee from carrier k) c
      join invoker d on d.sch = 'public' and d.nm like 'erp\_%'
                    and d.code like '%' || c.callee || '(%'
  )
  select r.nm, 'the door itself', 'erp_meta.' || r.table_name
    from reads r
   where r.sch = 'public' and r.nm like 'erp\_%'
  union
  select dc.nm, k.via, 'erp_meta.' || k.table_name
    from door_calls dc
    join carrier k on k.callee = dc.callee
  order by 1, 2, 3;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The intelligence boundary: from erp_ai back
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.intelligence_boundary_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with recursive fn as materialized (
    select p.oid,
           p.pronamespace::regnamespace::text as ns,
           p.proname,
           p.prosrc
      from pg_catalog.pg_proc p
     where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_ai', 'erp_meta')
  ),
  -- Everything that can reach the intelligence layer at any distance: erp_ai,
  -- then whatever names one of those, and so on. A caller is found once, when
  -- it is new.
  --
  -- The callers of one function at a time, in a subquery the planner may not
  -- flatten (offset 0): flattened, it is free to search every function's body
  -- for every function's name and filter to the set afterwards, which the first
  -- version of this file let it do on the build.
  upstream (oid) as (
    select f.oid from fn f where f.ns = 'erp_ai'
    union
    select c.caller
      from upstream u
     cross join lateral (
       select caller.oid as caller
         from fn callee
         join fn caller
           on caller.oid <> callee.oid
          and position(callee.ns || '.' || callee.proname || '(' in caller.prosrc) > 0
        where callee.oid = u.oid
       offset 0
     ) c
  ),
  -- The calls into that set. Every step of a walk that ends in erp_ai lands on
  -- something that reaches erp_ai, so these are all the edges such a walk uses.
  edge as materialized (
    select c.caller, u.oid as callee
      from upstream u
     cross join lateral (
       select caller.oid as caller
         from fn callee
         join fn caller
           on caller.oid <> callee.oid
          and position(callee.ns || '.' || callee.proname || '(' in caller.prosrc) > 0
        where callee.oid = u.oid
       offset 0
     ) c
  ),
  root as (
    select distinct f.oid, f.ns, f.proname
      from erp_meta.transaction_path_function t
      join fn f on f.ns = t.schema_name and f.proname = t.function_name
  ),
  -- How far each function is from each erp_ai function: every walk length up
  -- to 12, as the walk down from the roots counted it.
  towards (node, target, depth) as (
    select e.caller, e.callee, 1
      from edge e
      join fn t on t.oid = e.callee
     where t.ns = 'erp_ai'
    union
    select e.caller, w.target, w.depth + 1
      from towards w
      join edge e on e.callee = w.node
     where w.depth < 12
  )
  -- Promise 3: nothing in the transaction path may reach the intelligence layer.
  select 'a transaction-path function can reach the intelligence layer',
         format('%s.%s', r.ns, r.proname),
         format('reaches %s.%s at depth %s', c.ns, c.proname, w.depth)
    from root r
    join towards w on w.node = r.oid
    join fn c on c.oid = w.target
  union all
  -- A registered transaction-path function that does not exist is a boundary
  -- with a hole in it: nothing is being checked and nothing says so.
  select 'a registered transaction-path function does not exist',
         format('%s.%s', t.schema_name, t.function_name),
         'the boundary check silently covers nothing for this entry'
    from erp_meta.transaction_path_function t
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace::regnamespace::text = t.schema_name
        and p.proname = t.function_name)
  union all
  -- Promise 4, structurally: an intelligence table without a tenant column
  -- could hold something that belongs to everyone.
  select 'an erp_ai table is not tenant-scoped',
         format('erp_ai.%s', c.relname),
         'it has no tenant_id, so nothing confines it to one tenant'
    from pg_catalog.pg_class c
   where c.relnamespace = 'erp_ai'::regnamespace
     and c.relkind = 'r'
     and not exists (
       select 1 from pg_catalog.pg_attribute a
        where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
          and a.attname = 'tenant_id')
  union all
  -- Promise 1, as data: anything decided must have been decided by a person.
  select 'a proposal was decided without a named human',
         p.id::text,
         format('status %s with reviewer %s', p.status,
                coalesce(p.reviewed_by::text, 'none'))
    from erp_ai.proposal p
   where p.status in ('approved', 'rejected', 'applied')
     and not exists (
       select 1 from erp.app_user u
        where u.tenant_id = p.tenant_id and u.id = p.reviewed_by
          and u.kind = 'person')
  union all
  -- Promise 2, as data.
  select 'a proposal was applied without validation outside production',
         p.id::text,
         'spec 3.12 requires a test environment first'
    from erp_ai.proposal p
   where p.status = 'applied'
     and not exists (
       select 1 from erp.environment e
        where e.tenant_id = p.tenant_id
          and e.id = p.validated_in_environment_id
          and e.kind <> 'production')
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The words: the organisation once per bundle, each bundle once
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_resources(p_locale text default 'en')
returns jsonb
language sql
stable
set search_path = ''
as $$
  with recursive tenant as materialized (
      -- Once per call. Written into the lookups below it ran for every product
      -- row, and erp.current_tenant_id() runs erp.principal_context() each time.
      select erp.current_tenant_id() as id
  ),
  chain(code, parent_locale, depth) as (
      select l.code, l.parent_locale, 0
        from erp_ref.locale l
       where l.code = coalesce(p_locale, 'en')
      union all
      select l.code, l.parent_locale, chain.depth + 1
        from chain
        join erp_ref.locale l on l.code = chain.parent_locale
       where chain.depth < 4
  ),
  steps as (
      select code, depth from chain
      union all
      select 'en', 99
  ),
  resolved as (
      select r.key,
             coalesce(
               (select o.value from erp.resource_override o
                 where o.tenant_id = (select t.id from tenant t)
                   and o.key = r.key and o.locale = r.locale
                   and o.status = 'active'::erp.record_status limit 1),
               r.value) as value,
             s.depth
        from steps s
        join erp_ref.resource r on r.locale = s.code
      union all
      -- Tenant-defined terms: no product row to join, so they are their own
      -- source, at the depth of the locale they were written in.
      select o.key, o.value, s.depth
        from steps s
        cross join tenant t
        join erp.resource_override o
          on o.locale = s.code
         and o.tenant_id = t.id
         and o.status = 'active'::erp.record_status
         and o.key like 'custom.%'
         and o.entity_id is null
  ),
  ranked as (
      select key, value, row_number() over (partition by key order by depth) as rn
        from resolved
  )
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from ranked where rn = 1
$$;

create or replace function erp.assert_vocabulary_aligned()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_detail text := ''; v_count integer := 0; r record; n integer; v_us jsonb;
begin
  -- 1. No internal term on a screen.
  for r in
    select v.code as term_code, v.model_term, res.key, res.locale,
           left(res.value, 70) as value
      from erp_ref.vocabulary v
      join erp_ref.resource res
        on res.value ~* ('\m' || v.model_term || '\M')
     where v.surface = 'internal'
       -- The glossary is where these words are allowed to appear, because
       -- stating what a word means is the opposite of using it as if everybody
       -- knew.
       and res.key not like 'glossary.%'
     order by v.code, res.key
  loop
    v_detail := v_detail || format(
      E'  %s (%s) says %L, which is model vocabulary — %s\n',
      r.key, r.locale, r.value, r.term_code);
    v_count := v_count + 1;
  end loop;

  -- 2. Every product and ambiguous term has its glossary key, so a tenant can
  --    rename it. A term nobody can override is a term the product imposes.
  for r in
    select v.code from erp_ref.vocabulary v
     where v.surface in ('product', 'ambiguous') and v.product_term is not null
       and not exists (select 1 from erp_ref.resource res
                        where res.key = 'glossary.' || v.code and res.locale = 'en')
     order by v.code
  loop
    v_detail := v_detail || format(
      E'  %s has no glossary.%s key in the base locale — nothing can rename it\n',
      r.code, r.code);
    v_count := v_count + 1;
  end loop;

  -- 3. The fallback chain. This is the check §6.4 was really asking for: an
  --    en-US caller must get every string, not only the ones authored at en-US.
  --    Before public.erp_resources() walked erp_ref.locale.parent_locale it
  --    returned four rows out of 691, and nothing would have said so. The
  --    bundle is read once here and again in 4; this function is stable, so
  --    both statements see the same one.
  v_us := public.erp_resources('en-US');
  select count(*) into n
    from jsonb_object_keys(v_us) k;
  if n < (select count(*) from erp_ref.resource where locale = 'en') then
    v_detail := v_detail || format(
      E'  erp_resources(''en-US'') resolves %s keys but the base locale has %s — the fallback chain is not being walked\n',
      n, (select count(*) from erp_ref.resource where locale = 'en'));
    v_count := v_count + 1;
  end if;

  -- 4. And it has to actually differ, or the variant proves nothing.
  if (v_us ->> 'glossary.batch') is not distinct from
     (public.erp_resources('en') ->> 'glossary.batch') then
    v_detail := v_detail ||
      E'  en-US resolves glossary.batch to the same value as en — the variant is not overriding\n';
    v_count := v_count + 1;
  end if;

  -- 5. A us_term claimed in the register with no en-US row behind it is a
  --    promise the deployment does not keep.
  for r in
    select v.code, v.us_term from erp_ref.vocabulary v
     where v.us_term is not null
       and not exists (select 1 from erp_ref.resource res
                        where res.key = 'glossary.' || v.code and res.locale = 'en-US')
     order by v.code
  loop
    v_detail := v_detail || format(
      E'  %s claims the US term %L but no en-US glossary row carries it\n',
      r.code, r.us_term);
    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    raise exception E'CLOVEERP_VOCABULARY_MISALIGNED: % finding(s)\n%', v_count, v_detail
      using errcode = '23514';
  end if;

  return format('vocabulary: %s product terms, %s internal terms kept off the '
                'surface, %s ambiguous terms defined, %s en-US flips',
    (select count(*) from erp_ref.vocabulary where surface = 'product'),
    (select count(*) from erp_ref.vocabulary where surface = 'internal'),
    (select count(*) from erp_ref.vocabulary where surface = 'ambiguous'),
    (select count(*) from erp_ref.resource where locale = 'en-US'));
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. How long each check took
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.run_diagnostic(p_code text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c         erp_meta.diagnostic_check%rowtype;
  v_summary text;
  v_error   text;
  v_detail  jsonb;
  v_started timestamptz;
begin
  select * into c from erp_meta.diagnostic_check where code = p_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DIAGNOSTIC: % is not a registered check', p_code
      using errcode = '23503',
            hint = 'The register is the allow-list. A check that is not in it cannot be run.';
  end if;

  -- The wall clock, not the statement's: now() stands still for the whole of
  -- erp.platform_assurance(), which is one statement.
  v_started := pg_catalog.clock_timestamp();

  begin
    execute format('select %I.%I(%s)::text', c.schema_name, c.function_name, c.arguments)
      into v_summary;
    v_error := null;
  exception when others then
    v_summary := null;
    v_error := sqlerrm;
  end;

  -- The half that was missing. Every one of these assertions is backed by a
  -- report that lists what actually went wrong, and not one of those reports
  -- was reachable, so the screen could say isolation had failed and could not
  -- say which table.
  if v_error is not null and c.detail_function is not null then
    begin
      execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from %I.%I(%s) t',
                     c.schema_name, c.detail_function, c.detail_arguments)
        into v_detail;
    exception when others then
      v_detail := jsonb_build_array(
        jsonb_build_object('finding', 'the detail report itself failed',
                           'detail', sqlerrm));
    end;
  end if;

  return jsonb_build_object(
    -- 'check' and 'detail' keep the shape the assurance screen already reads,
    -- so this is additive rather than a rename with a screen change attached.
    'check',    c.schema_name || '.' || c.function_name,
    'detail',   v_error,
    'code',     c.code,
    'title',    c.title,
    'scope',    c.scope,
    'blurb',    c.blurb,
    'runs_in_ci', c.runs_in_ci,
    'ok',       v_error is null,
    'summary',  v_summary,
    'findings', coalesce(v_detail, '[]'::jsonb),
    -- The check and, when it failed, its report. deploy.yml prints the
    -- slowest, because 55 seconds is shared by all of them.
    'elapsed_ms', round((extract(epoch from pg_catalog.clock_timestamp() - v_started) * 1000)::numeric, 1));
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite: the old walks, kept as they were, against the new ones
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.assurance_walks_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_msg           text;
  v_ad_new        integer;
  v_ad_only_new   text;
  v_ad_only_old   text;
  v_ad_fixtures   text;
  v_reach_old     integer;
  v_reach_said    text;
  v_cr_new        integer;
  v_cr_only_new   text;
  v_cr_only_old   text;
  v_cr_fixtures   text;
  v_ib_new        integer;
  v_ib_only_new   text;
  v_ib_only_old   text;
  v_ib_fixtures   text;
  v_locale        text;
  v_bundle_new    jsonb;
  v_bundle_old    jsonb;
  v_bundles       text := '';
  v_bundles_same  boolean := true;
  v_run           jsonb;
begin
  begin
    -- ── Fixtures for the writer rule ────────────────────────────────────────
    execute $ddl$
      create function erp.zz_aw_gate() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.authorise(null);
      end $b$
    $ddl$;
    execute $ddl$
      create function erp.zz_aw_gate_in_a_comment() returns void
      language plpgsql set search_path = '' as $b$
      begin
        -- perform erp.authorise(null);
        perform 1;
      end $b$
    $ddl$;
    execute $ddl$
      create function erp.zz_aw_calls_gate() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.zz_aw_gate();
      end $b$
    $ddl$;
    -- Found: a writer directly, with a space before the bracket.
    execute $ddl$
      create function public.erp_zz_aw_stable_gate() returns void
      language plpgsql stable set search_path = '' as $b$
      begin
        perform erp.authorise (null);
      end $b$
    $ddl$;
    -- Found: one function away, with a line break before the bracket.
    execute $ddl$
      create function public.erp_zz_aw_stable_one_hop() returns void
      language plpgsql stable set search_path = '' as $b$
      begin
        perform erp.zz_aw_gate
          ();
      end $b$
    $ddl$;
    -- Found: the other writer, from an immutable door.
    execute $ddl$
      create function public.erp_zz_aw_immutable_platform() returns void
      language plpgsql immutable set search_path = '' as $b$
      begin
        perform erp_meta.require_platform('support');
      end $b$
    $ddl$;
    -- Found: the name at the end of a longer word, as the pattern has always
    -- matched it.
    execute $ddl$
      create function public.erp_zz_aw_stable_inside_a_word() returns void
      language plpgsql stable set search_path = '' as $b$
      begin
        perform 1 where 'xerp.zz_aw_gate(' <> '';
      end $b$
    $ddl$;
    -- Not found: two hops, volatile, a comment, a longer name.
    execute $ddl$
      create function public.erp_zz_aw_stable_two_hops() returns void
      language plpgsql stable set search_path = '' as $b$
      begin
        perform erp.zz_aw_calls_gate();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_aw_volatile_one_hop() returns void
      language plpgsql volatile set search_path = '' as $b$
      begin
        perform erp.zz_aw_gate();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_aw_stable_comment() returns void
      language plpgsql stable set search_path = '' as $b$
      begin
        /* perform erp.zz_aw_gate(); */
        perform 1;
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_aw_stable_longer_name() returns void
      language plpgsql stable set search_path = '' as $b$
      begin
        perform erp.zz_aw_gate_in_a_comment();
      end $b$
    $ddl$;

    -- ── Fixtures for platform-internal reads ────────────────────────────────
    execute $ddl$
      create function erp.zz_cw_reader() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return (select count(*) from erp_meta.diagnostic_check);
      end $b$
    $ddl$;
    execute $ddl$
      create function erp.zz_cw_calls_reader() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return erp.zz_cw_reader();
      end $b$
    $ddl$;
    execute $ddl$
      create function erp.zz_cw_calls_caller() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return erp.zz_cw_calls_reader();
      end $b$
    $ddl$;
    execute $ddl$
      create function erp.zz_cw_definer_reader() returns integer
      language plpgsql security definer set search_path = '' as $b$
      begin
        return (select count(*) from erp_meta.diagnostic_check);
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_cw_itself() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return (select count(*) from erp_meta.diagnostic_check);
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_cw_one_hop() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return erp.zz_cw_reader();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_cw_two_hops() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return erp.zz_cw_calls_reader();
      end $b$
    $ddl$;
    -- An underscore in a LIKE pattern matches any character, so a name with
    -- dashes where the underscores were is a call as far as the rule goes.
    execute $ddl$
      create function public.erp_zz_cw_like_wildcard() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return length('erp.zz-cw-reader()');
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_cw_three_hops() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return erp.zz_cw_calls_caller();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_cw_through_a_definer() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        return erp.zz_cw_definer_reader();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_cw_runs_as_owner() returns integer
      language plpgsql security definer set search_path = '' as $b$
      begin
        return (select count(*) from erp_meta.diagnostic_check);
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_cw_in_a_comment() returns integer
      language plpgsql set search_path = '' as $b$
      begin
        -- return (select count(*) from erp_meta.diagnostic_check);
        return 0;
      end $b$
    $ddl$;

    -- ── Fixtures for the intelligence boundary ──────────────────────────────
    execute $ddl$
      create function erp_ai.zz_ib_target() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform 1;
      end $b$
    $ddl$;
    execute $ddl$
      create function erp.zz_ib_root() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.zz_ib_middle();
      end $b$
    $ddl$;
    -- Reaches erp_ai, and calls back into the root: a cycle, so the root
    -- reaches erp_ai at 2, 4, 6, 8, 10 and 12.
    execute $ddl$
      create function erp.zz_ib_middle() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp_ai.zz_ib_target();
        perform erp.zz_ib_root();
      end $b$
    $ddl$;
    -- The rule reads the raw body, so a comment counts: depth 1.
    execute $ddl$
      create function erp.zz_ib_comment_root() returns void
      language plpgsql set search_path = '' as $b$
      begin
        -- perform erp_ai.zz_ib_target();
        perform 1;
      end $b$
    $ddl$;
    -- And it looks for the bracket straight after the name: not a call.
    execute $ddl$
      create function erp.zz_ib_spaced_root() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp_ai.zz_ib_target ();
      end $b$
    $ddl$;
    insert into erp_meta.transaction_path_function (schema_name, function_name, rationale) values
      ('erp', 'zz_ib_root', 'Suite fixture: reaches erp_ai round a cycle.'),
      ('erp', 'zz_ib_comment_root', 'Suite fixture: names erp_ai in a comment.'),
      ('erp', 'zz_ib_spaced_root', 'Suite fixture: a space before the bracket.');

    -- ── The writer rule, old and new ────────────────────────────────────────
    with old_rows as materialized (
      with writer as (
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
      select f.qname || '(' || pg_get_function_identity_arguments(f.oid) || ')' as door,
             case f.provolatile when 's' then 'stable' else 'immutable' end as volatility,
             'a public door reaches ' || r.qname || '(), which ' || r.what
               || ', but is declared '
               || case f.provolatile when 's' then 'stable' else 'immutable' end
               || ', so PostgREST runs it in a read-only transaction and the call fails' as finding
        from fn f
        join reaches r on f.code ~ (replace(r.qname, '.', '\.') || '\s*\(')
       where f.sch = 'public'
         and f.provolatile in ('s', 'i')
       group by 1, 2, 3
    ),
    new_rows as materialized (
      select r.door, r.volatility, r.finding from erp.authorising_door_report() r
    )
    select (select count(*) from new_rows),
           (select string_agg(x.door || ': ' || x.finding, '; ') from (select * from new_rows except all select * from old_rows) x),
           (select string_agg(x.door || ': ' || x.finding, '; ') from (select * from old_rows except all select * from new_rows) x),
           (select string_agg(n.door || ' ' || substring(n.finding from 'reaches (\S+)\(\)'), '; ' order by n.door, n.finding)
              from new_rows n where n.door like 'public.erp\_zz\_aw\_%')
      into v_ad_new, v_ad_only_new, v_ad_only_old, v_ad_fixtures;

    with writer as (
      select * from (values ('erp.authorise'), ('erp_meta.require_platform')) as w(qname)
    ),
    fn as (
      select n.nspname || '.' || p.proname as qname, n.nspname as sch, p.prosrc
        from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('erp', 'erp_ai', 'erp_meta', 'erp_ref', 'public')
    ),
    reaches as (
      select w.qname from writer w
      union
      select f.qname from fn f join writer w on f.prosrc ~ (replace(w.qname, '.', '\.') || '\s*\(')
    )
    select count(distinct f.qname) into v_reach_old
      from fn f join reaches r on f.prosrc ~ (replace(r.qname, '.', '\.') || '\s*\(')
     where f.sch = 'public';

    -- The findings make the assertion refuse, so its sentence is read from a
    -- catalogue without them: the fixture doors are volatile for the moment.
    execute 'alter function public.erp_zz_aw_stable_gate() volatile';
    execute 'alter function public.erp_zz_aw_stable_one_hop() volatile';
    execute 'alter function public.erp_zz_aw_immutable_platform() volatile';
    execute 'alter function public.erp_zz_aw_stable_inside_a_word() volatile';
    v_reach_said := substring(erp.assert_authorising_doors_are_volatile() from ', (\d+) reach ');

    -- ── Platform-internal reads, old and new ────────────────────────────────
    with old_rows as materialized (
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
      select distinct r.door, r.via, 'erp_meta.' || i.table_name as internal_table
        from reach r cross join internal i
       where r.code like '%erp\_meta.' || i.table_name || '%'
    ),
    new_rows as materialized (
      select r.door, r.via, r.internal_table from erp.caller_reachable_internal_report() r
    )
    select (select count(*) from new_rows),
           (select string_agg(format('%s via %s reads %s', x.door, x.via, x.internal_table), '; ')
              from (select * from new_rows except all select * from old_rows) x),
           (select string_agg(format('%s via %s reads %s', x.door, x.via, x.internal_table), '; ')
              from (select * from old_rows except all select * from new_rows) x),
           (select string_agg(distinct format('%s via %s', n.door, n.via), '; ' order by format('%s via %s', n.door, n.via))
              from new_rows n where n.door like 'erp\_zz\_cw\_%')
      into v_cr_new, v_cr_only_new, v_cr_only_old, v_cr_fixtures;

    -- ── The intelligence boundary, old and new ──────────────────────────────
    with old_rows as materialized (
      with recursive fn as (
        select p.oid,
               p.pronamespace::regnamespace::text as ns,
               p.proname,
               p.prosrc
          from pg_catalog.pg_proc p
         where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_ai', 'erp_meta')
      ),
      edge as (
        select caller.oid as caller, callee.oid as callee
          from fn caller
          join fn callee
            on caller.oid <> callee.oid
           and position(callee.ns || '.' || callee.proname || '(' in caller.prosrc) > 0
      ),
      root as (
        select f.oid, f.ns, f.proname
          from erp_meta.transaction_path_function t
          join fn f on f.ns = t.schema_name and f.proname = t.function_name
      ),
      reach as (
        select r.oid as root_oid, r.ns as root_ns, r.proname as root_name,
               e.callee, 1 as depth
          from root r join edge e on e.caller = r.oid
        union
        select x.root_oid, x.root_ns, x.root_name, e.callee, x.depth + 1
          from reach x join edge e on e.caller = x.callee
         where x.depth < 12
      )
      select 'a transaction-path function can reach the intelligence layer' as finding,
             format('%s.%s', x.root_ns, x.root_name) as reference,
             format('reaches %s.%s at depth %s', c.ns, c.proname, x.depth) as detail
        from reach x
        join fn c on c.oid = x.callee
       where c.ns = 'erp_ai'
      union all
      select 'a registered transaction-path function does not exist',
             format('%s.%s', t.schema_name, t.function_name),
             'the boundary check silently covers nothing for this entry'
        from erp_meta.transaction_path_function t
       where not exists (
         select 1 from pg_catalog.pg_proc p
          where p.pronamespace::regnamespace::text = t.schema_name
            and p.proname = t.function_name)
      union all
      select 'an erp_ai table is not tenant-scoped',
             format('erp_ai.%s', c.relname),
             'it has no tenant_id, so nothing confines it to one tenant'
        from pg_catalog.pg_class c
       where c.relnamespace = 'erp_ai'::regnamespace
         and c.relkind = 'r'
         and not exists (
           select 1 from pg_catalog.pg_attribute a
            where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
              and a.attname = 'tenant_id')
      union all
      select 'a proposal was decided without a named human',
             p.id::text,
             format('status %s with reviewer %s', p.status,
                    coalesce(p.reviewed_by::text, 'none'))
        from erp_ai.proposal p
       where p.status in ('approved', 'rejected', 'applied')
         and not exists (
           select 1 from erp.app_user u
            where u.tenant_id = p.tenant_id and u.id = p.reviewed_by
              and u.kind = 'person')
      union all
      select 'a proposal was applied without validation outside production',
             p.id::text,
             'spec 3.12 requires a test environment first'
        from erp_ai.proposal p
       where p.status = 'applied'
         and not exists (
           select 1 from erp.environment e
            where e.tenant_id = p.tenant_id
              and e.id = p.validated_in_environment_id
              and e.kind <> 'production')
    ),
    new_rows as materialized (
      select r.finding, r.reference, r.detail from erp.intelligence_boundary_report() r
    )
    select (select count(*) from new_rows),
           (select string_agg(x.reference || ' ' || x.detail, '; ') from (select * from new_rows except all select * from old_rows) x),
           (select string_agg(x.reference || ' ' || x.detail, '; ') from (select * from old_rows except all select * from new_rows) x),
           (select string_agg(n.reference || ' ' || n.detail, '; ' order by n.reference, n.detail)
              from new_rows n where n.reference like 'erp.zz\_ib\_%')
      into v_ib_new, v_ib_only_new, v_ib_only_old, v_ib_fixtures;

    -- ── The words, old and new ──────────────────────────────────────────────
    foreach v_locale in array array['en', 'en-US', 'de-AT'] loop
      v_bundle_new := public.erp_resources(v_locale);
      with recursive chain(code, parent_locale, depth) as (
          select l.code, l.parent_locale, 0
            from erp_ref.locale l
           where l.code = coalesce(v_locale, 'en')
          union all
          select l.code, l.parent_locale, chain.depth + 1
            from chain
            join erp_ref.locale l on l.code = chain.parent_locale
           where chain.depth < 4
      ),
      steps as (
          select code, depth from chain
          union all
          select 'en', 99
      ),
      resolved as (
          select r.key,
                 coalesce(
                   (select o.value from erp.resource_override o
                     where o.tenant_id = erp.current_tenant_id()
                       and o.key = r.key and o.locale = r.locale
                       and o.status = 'active'::erp.record_status limit 1),
                   r.value) as value,
                 s.depth
            from steps s
            join erp_ref.resource r on r.locale = s.code
          union all
          select o.key, o.value, s.depth
            from steps s
            join erp.resource_override o
              on o.locale = s.code
             and o.tenant_id = erp.current_tenant_id()
             and o.status = 'active'::erp.record_status
             and o.key like 'custom.%'
             and o.entity_id is null
      ),
      ranked as (
          select key, value, row_number() over (partition by key order by depth) as rn
            from resolved
      )
      select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_bundle_old
        from ranked where rn = 1;

      v_bundles_same := v_bundles_same and v_bundle_new = v_bundle_old;
      v_bundles := v_bundles || format('%s %s/%s keys; ', v_locale,
        (select count(*) from jsonb_object_keys(v_bundle_new)),
        (select count(*) from jsonb_object_keys(v_bundle_old)));
    end loop;

    v_run := erp.run_diagnostic('diagnostics_registered');

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := left(sqlerrm, 300); end if;
  end;

  -- 1
  case_name := 'the writer rule finds from the names a door calls exactly what it found from every pair';
  passed := v_msg is null and v_ad_only_new is null and v_ad_only_old is null;
  detail := coalesce(v_msg, format('%s finding(s) with fixtures; only new: %s; only old: %s',
                                   v_ad_new, coalesce(v_ad_only_new, 'none'), coalesce(v_ad_only_old, 'none')));
  return next;

  -- 2
  case_name := 'it reports a stable door that gates, one hop away, through require_platform and inside a word, and nothing further';
  passed := v_msg is null and v_ad_fixtures is not distinct from
    'public.erp_zz_aw_immutable_platform() erp_meta.require_platform; '
    'public.erp_zz_aw_stable_gate() erp.authorise; '
    'public.erp_zz_aw_stable_inside_a_word() erp.zz_aw_gate; '
    'public.erp_zz_aw_stable_one_hop() erp.zz_aw_gate';
  detail := coalesce(v_msg, v_ad_fixtures, 'no fixture door was reported');
  return next;

  -- 3
  case_name := 'the assertion counts the doors that reach a writer as the old count did';
  passed := v_msg is null and v_reach_said = v_reach_old::text;
  detail := coalesce(v_msg, format('the sentence says %s, the old count is %s', coalesce(v_reach_said, 'nothing'), v_reach_old));
  return next;

  -- 4
  case_name := 'the platform-internal rule walked back from the tables finds exactly what the walk from the doors found';
  passed := v_msg is null and v_cr_only_new is null and v_cr_only_old is null;
  detail := coalesce(v_msg, format('%s finding(s) with fixtures; only new: %s; only old: %s',
                                   v_cr_new, coalesce(v_cr_only_new, 'none'), coalesce(v_cr_only_old, 'none')));
  return next;

  -- 5
  case_name := 'it reports a read by the door, one and two invoker hops away and through a LIKE wildcard, and nothing further';
  passed := v_msg is null and v_cr_fixtures is not distinct from
    'erp_zz_cw_itself via the door itself; '
    'erp_zz_cw_like_wildcard via erp.zz_cw_reader; '
    'erp_zz_cw_one_hop via erp.zz_cw_reader; '
    'erp_zz_cw_two_hops via erp.zz_cw_reader';
  detail := coalesce(v_msg, v_cr_fixtures, 'no fixture door was reported');
  return next;

  -- 6
  case_name := 'the intelligence boundary walked back from erp_ai finds exactly what the walk from the roots found';
  passed := v_msg is null and v_ib_only_new is null and v_ib_only_old is null;
  detail := coalesce(v_msg, format('%s finding(s) with fixtures; only new: %s; only old: %s',
                                   v_ib_new, coalesce(v_ib_only_new, 'none'), coalesce(v_ib_only_old, 'none')));
  return next;

  -- 7
  case_name := 'it reports every depth round a cycle up to 12 and a name in a comment, and not a spaced bracket';
  passed := v_msg is null and v_ib_fixtures is not distinct from
    'erp.zz_ib_comment_root reaches erp_ai.zz_ib_target at depth 1; '
    'erp.zz_ib_root reaches erp_ai.zz_ib_target at depth 10; '
    'erp.zz_ib_root reaches erp_ai.zz_ib_target at depth 12; '
    'erp.zz_ib_root reaches erp_ai.zz_ib_target at depth 2; '
    'erp.zz_ib_root reaches erp_ai.zz_ib_target at depth 4; '
    'erp.zz_ib_root reaches erp_ai.zz_ib_target at depth 6; '
    'erp.zz_ib_root reaches erp_ai.zz_ib_target at depth 8';
  detail := coalesce(v_msg, v_ib_fixtures, 'no fixture root was reported');
  return next;

  -- 8
  case_name := 'a bundle that asks for the organisation once is the bundle that asked on every row';
  passed := v_msg is null and v_bundles_same;
  detail := coalesce(v_msg, v_bundles);
  return next;

  -- 9
  case_name := 'a check says how long it took';
  passed := v_msg is null
        and jsonb_typeof(v_run -> 'elapsed_ms') = 'number'
        and (v_run ->> 'elapsed_ms')::numeric >= 0;
  detail := coalesce(v_msg, format('diagnostics_registered: %s ms', v_run ->> 'elapsed_ms'));
  return next;

  -- 10
  case_name := 'the fixtures were undone';
  passed := not exists (
              select 1 from pg_catalog.pg_proc p
                join pg_catalog.pg_namespace n on n.oid = p.pronamespace
               where (n.nspname in ('erp', 'erp_ai') and p.proname like 'zz\_aw\_%')
                  or (n.nspname in ('erp', 'erp_ai') and p.proname like 'zz\_cw\_%')
                  or (n.nspname in ('erp', 'erp_ai') and p.proname like 'zz\_ib\_%')
                  or (n.nspname = 'public' and p.proname like 'erp\_zz\_aw\_%')
                  or (n.nspname = 'public' and p.proname like 'erp\_zz\_cw\_%'))
        and not exists (select 1 from erp_meta.transaction_path_function t
                         where t.function_name like 'zz\_ib\_%');
  detail := 'twenty-seven functions and three transaction-path rows rolled back';
  return next;
end;
$$;
revoke all on function erp_test.assurance_walks_suite() from public, anon, authenticated;

create or replace function erp_test.assert_assurance_walks_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from erp_test.assurance_walks_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ASSURANCE_WALKS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_ASSURANCE_WALKS_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('assurance walks: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_assurance_walks_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_authorising_doors_are_volatile();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_intelligence_boundary();
select erp.assert_vocabulary_aligned();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_no_missing_relations();
select erp.assert_linter_clean();
select erp_test.assert_caller_reachable_internal_suite();
select erp_test.assert_prosrc_code_suite();
