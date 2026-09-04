-- ─────────────────────────────────────────────────────────────────────────────
-- A refusal says Clove.
--
-- 20260904470000 renamed the product and said plainly what it was not renaming:
-- the ERPWARE_ prefix on every refusal code, because "those are identifiers, not
-- the product's name — six hundred refusal codes are matched by the client and
-- the suites". That reasoning was sound and it was also a decision taken on the
-- owner's behalf, for a task that said everywhere. Asked directly, the owner
-- said rename them.
--
-- One migration rather than two hundred, because migrations_immutable.sh means
-- the files that raise the old codes cannot be edited. They stay as written and
-- this repairs forward: a build from empty applies them, arrives here, and
-- rewrites what they left behind — the same shape as 20260904940000.
--
-- NOT renamed, so the next person does not have to rediscover why:
--
--   * The 'erpware:' prefix on vault secret names. That prefix IS the lookup key
--     for a company's encryption key, and three live tenants hold one. Renaming
--     it without re-keying each of them first makes their encrypted data
--     permanently unreadable. That is not a rename, it is a loss.
--   * 'erpware.tenant-export.v1'. Export files already produced carry it.
--   * The ~65 migration file headers, which is what immutability means.
--
-- The single biggest thing this does NOT touch: no function is NAMED
-- ERPWARE_anything. Every register keyed on a function name — the diagnostic
-- register, the job handlers, the promotable surfaces, the boundary allowlist —
-- is therefore unaffected, and none of them appears below.
--
-- Measured before writing, on both a fresh build and the live project: 581
-- function bodies, 2 comments, 2 check constraints, 55 refusal rows, 31 scope
-- rows, 165 resource keys and their descriptions, 2 policy-decision notes.
-- Nought in column defaults, row-security policies, views, trigger WHEN clauses
-- or index expressions — checked, not assumed.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The constraints have to come off first ───────────────────────────────────

alter table erp_ref.refusal       drop constraint if exists refusal_code_is_a_token;
alter table erp_ref.refusal_scope drop constraint if exists refusal_scope_is_a_prefix;

-- ── The registers, counted rather than hoped for ─────────────────────────────
--
-- erp_ref.refusal and erp_ref.refusal_scope both carry FORCE ROW LEVEL SECURITY,
-- which applies to the owner too. An UPDATE that the policy does not admit does
-- not fail — it reports nought rows and every check after it passes because
-- there is nothing left to find. So each update states how many rows it expected
-- and refuses to continue if it moved fewer. A silent no-op is the one outcome
-- this migration must not have.

do $registers$
declare v_moved integer; v_total integer;
begin
  select count(*) into v_total from erp_ref.refusal where code like 'ERPWARE\_%';
  update erp_ref.refusal set code = replace(code, 'ERPWARE_', 'CLOVEERP_')
   where code like 'ERPWARE\_%';
  get diagnostics v_moved = row_count;
  if v_moved <> v_total then
    raise exception 'CLOVEERP_RENAME_SHORT: moved % of % refusal codes', v_moved, v_total
      using hint = 'Row security refused the update, or something wrote between the count and the write.';
  end if;

  select count(*) into v_total from erp_ref.refusal_scope where token_prefix like 'ERPWARE\_%';
  update erp_ref.refusal_scope
     set token_prefix = replace(token_prefix, 'ERPWARE_', 'CLOVEERP_')
   where token_prefix like 'ERPWARE\_%';
  get diagnostics v_moved = row_count;
  if v_moved <> v_total then
    raise exception 'CLOVEERP_RENAME_SHORT: moved % of % refusal scopes', v_moved, v_total;
  end if;
end
$registers$;

-- ── The dictionary the registers mirror into ─────────────────────────────────
--
-- Two cases matter. The code is upper-case; erp_ref.refusal_key() lowers it when
-- mirroring, so the keys are lower-case. A single-case replace leaves half of
-- this behind — and the description is what the terminology screen shows an
-- administrator when it offers the key for renaming, so it is read by a person.

update erp_ref.resource
   set key = replace(key, 'refusal.erpware_', 'refusal.cloveerp_')
 where key like 'refusal.erpware\_%';

update erp_ref.resource
   set description = replace(description, 'ERPWARE_', 'CLOVEERP_')
 where description like '%ERPWARE\_%';

-- erp.resource_override is a promotable surface, so it carries
-- t_resource_override_live_guard, which refuses an edit outside a promotion on a
-- live organisation. There are nought rows today and the predicate makes this a
-- no-op — but this migration runs at some future moment, and the day one tenant
-- has written their own wording for a refusal is the day it would abort the
-- whole transaction. The guard comes off for one statement and goes straight
-- back, inside the same transaction.
alter table erp.resource_override disable trigger t_resource_override_live_guard;
update erp.resource_override
   set key = replace(key, 'refusal.erpware_', 'refusal.cloveerp_')
 where key like 'refusal.erpware\_%';
alter table erp.resource_override enable trigger t_resource_override_live_guard;

-- The decision register quotes refusal codes as the evidence for a decision.
-- Rewritten rather than left: evidence naming a code that no longer exists is a
-- dangling reference, and the point of the register is that somebody can go and
-- check what it says.
update erp_meta.policy_decision
   set evidence = replace(evidence, 'ERPWARE_', 'CLOVEERP_')
 where evidence like '%ERPWARE\_%';

-- ── The sweep ────────────────────────────────────────────────────────────────
--
-- Every routine body, rewritten from its own definition. pg_get_functiondef
-- reproduces the whole thing — volatility, STRICT, LEAKPROOF, PARALLEL, COST,
-- ROWS, SECURITY DEFINER and the SET clauses — and CREATE OR REPLACE keeps the
-- OID, so grants, ownership, comments, row-security policies and triggers that
-- reference the function all survive untouched. That is why this is safe to do
-- wholesale: the revokes and grants this codebase depends on are not re-issued,
-- they are simply not disturbed.
--
-- Three things the obvious loop gets wrong:
--
--   * The OIDs are materialised first. A FOR loop over pg_proc would mutate the
--     relation it is scanning.
--   * prokind in ('f','p'). pg_get_functiondef raises on an aggregate, and
--     erp_test.assert_context_not_leaked() is a PROCEDURE that carries the
--     token — so neither 'f' alone nor a missing filter is right.
--   * An extension's own function is not ours to rewrite.
--
-- erp.refusal_report() is swept here too. It scrapes prosrc for the prefix, so
-- afterwards it scrapes for the new one: the report and what it reports on move
-- together in one transaction, and there is no moment where one describes the
-- other wrongly.

do $sweep$
declare
  v_oids oid[];
  v_oid  oid;
  v_n    integer := 0;
begin
  select coalesce(array_agg(p.oid order by p.oid), '{}')
    into v_oids
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test', 'public')
     and p.prokind in ('f', 'p')
     and p.prosrc like '%ERPWARE\_%'
     and not exists (select 1 from pg_catalog.pg_depend d
                      where d.classid = 'pg_catalog.pg_proc'::regclass
                        and d.objid = p.oid and d.deptype = 'e');

  foreach v_oid in array v_oids loop
    execute replace(pg_catalog.pg_get_functiondef(v_oid), 'ERPWARE_', 'CLOVEERP_');
    v_n := v_n + 1;
  end loop;

  -- A sweep that swept almost nothing is not a no-op, it is a broken filter
  -- reporting success. 581 on both the live project and a fresh build when this
  -- was written.
  if v_n < 500 then
    raise exception 'CLOVEERP_SWEEP_TOO_SMALL: % routine(s) rewritten, expected the platform', v_n
      using hint = 'The filter stopped matching. Fix the filter; do not lower this number.';
  end if;
  raise notice 'refusal prefix: % routine(s) rewritten', v_n;
end
$sweep$;

-- ── The comments ─────────────────────────────────────────────────────────────
--
-- CREATE OR REPLACE keeps the OID, so pg_description survives the sweep intact —
-- which means every comment above a rewritten function still says the old thing.
-- Nothing was lost; it simply was never touched, and needs its own pass.
--
-- COMMENT ON ROUTINE covers functions and procedures with one statement.

do $comments$
declare r record; v_n integer := 0;
begin
  for r in
    select p.oid::regprocedure::text as sig, d.description
      from pg_catalog.pg_description d
      join pg_catalog.pg_proc p on p.oid = d.objoid
     where d.classoid = 'pg_catalog.pg_proc'::regclass
       and d.objsubid = 0
       and d.description like '%ERPWARE\_%'
  loop
    execute format('comment on routine %s is %L',
                   r.sig, replace(r.description, 'ERPWARE_', 'CLOVEERP_'));
    v_n := v_n + 1;
  end loop;

  for r in
    select c.oid::regclass::text as rel, d.objsubid, a.attname, c.relkind, d.description
      from pg_catalog.pg_description d
      join pg_catalog.pg_class c on c.oid = d.objoid
      left join pg_catalog.pg_attribute a
             on a.attrelid = c.oid and a.attnum = d.objsubid and d.objsubid > 0
     where d.classoid = 'pg_catalog.pg_class'::regclass
       and d.description like '%ERPWARE\_%'
  loop
    if r.objsubid = 0 then
      execute format('comment on %s %s is %L',
                     case r.relkind when 'v' then 'view'
                                    when 'm' then 'materialized view'
                                    else 'table' end,
                     r.rel, replace(r.description, 'ERPWARE_', 'CLOVEERP_'));
    else
      execute format('comment on column %s.%I is %L',
                     r.rel, r.attname, replace(r.description, 'ERPWARE_', 'CLOVEERP_'));
    end if;
    v_n := v_n + 1;
  end loop;

  -- A comment on a schema, a type or a constraint is reported rather than
  -- guessed at: a rewrite this pass did not anticipate is one it should not
  -- perform unattended.
  if exists (select 1 from pg_catalog.pg_description where description like '%ERPWARE\_%')
     or exists (select 1 from pg_catalog.pg_shdescription where description like '%ERPWARE\_%') then
    raise exception 'CLOVEERP_COMMENT_PASS_INCOMPLETE: a comment outside pg_proc and pg_class still names the retired prefix'
      using hint = 'Query pg_description and pg_shdescription and extend this pass.';
  end if;
  raise notice 'refusal prefix: % comment(s) rewritten', v_n;
end
$comments$;

-- ── The constraints go back, saying the new thing ────────────────────────────

alter table erp_ref.refusal
  add constraint refusal_code_is_a_token check (code ~ '^CLOVEERP_[A-Z0-9_]+%?$');

alter table erp_ref.refusal_scope
  add constraint refusal_scope_is_a_prefix check (token_prefix ~ '^CLOVEERP_[A-Z0-9_]+$');

-- ── One enum label, free today and not later ─────────────────────────────────
--
-- erp.sync_authority carries 'erpware' meaning "this side is the system of
-- record". erp.external_ref holds nought rows, so renaming costs nothing now and
-- would cost a data migration the first time anybody integrates anything.

alter type erp.sync_authority rename value 'erpware' to 'cloveerp';

-- ── The one the rename actually missed ───────────────────────────────────────
--
-- 20260830091046 seeded a platform owner as an INSERT, and 20260904470000
-- renamed by CREATE OR REPLACE — which reaches functions, not rows. So this name
-- sat on the platform console saying the old product name beside a domain the
-- product no longer owns. It is revoked, which is why nobody noticed; it is
-- still the first row a new administrator reads.

update erp_meta.platform_staff
   set display_name = 'Clove ERP Owner',
       email        = 'admin@cloveerp.com'
 where email = 'admin@erpware.dev';

-- ── The guard that stops it coming back ──────────────────────────────────────
--
-- Defined AFTER the sweep on purpose. Defined before it, the sweep would rewrite
-- this function's own search literal into the thing it is looking for, and the
-- guard would pass forever by looking for something that no longer exists.
--
-- For the same reason the needle is assembled rather than written: a function
-- whose job is "no routine body contains this string" must not contain that
-- string, or it is its own first finding. strpos rather than LIKE so there is no
-- escape to get wrong.
--
-- A shell script over the migration files would be the wrong shape here. All
-- ~190 historical migrations still raise the old prefix and cannot be edited, so
-- it would need an exception register naming almost every file — and a rule with
-- two hundred exceptions has stopped describing anything. The database is exact:
-- a build from empty applies the old migrations and then this one sweeps them,
-- so anything still carrying the prefix at the end of a build is genuinely new.

create or replace function erp.legacy_refusal_prefix_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path to ''
as $$
  -- 'ERP' || 'WARE_' so this function is not its own finding.
  select 'a routine still raises the retired prefix',
         n.nspname || '.' || p.proname,
         'rewrite it to CLOVEERP_; the product is Clove ERP'
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test', 'public')
     and p.prokind in ('f', 'p')
     and strpos(p.prosrc, 'ERP' || 'WARE_') > 0
  union all
  select 'a comment still names the retired prefix',
         d.classoid::regclass::text || ' oid ' || d.objoid::text, ''
    from pg_catalog.pg_description d
   where strpos(d.description, 'ERP' || 'WARE_') > 0
  union all
  select 'a registered refusal still carries it', r.code, ''
    from erp_ref.refusal r where strpos(r.code, 'ERP' || 'WARE_') > 0
  union all
  select 'a refusal scope still carries it', s.token_prefix, ''
    from erp_ref.refusal_scope s where strpos(s.token_prefix, 'ERP' || 'WARE_') > 0
  union all
  select 'a resource row still carries it', res.key, ''
    from erp_ref.resource res
   where strpos(res.key, 'refusal.erp' || 'ware_') > 0
      or strpos(coalesce(res.description, ''), 'ERP' || 'WARE_') > 0
  union all
  select 'an organisation''s own wording still carries it', o.key, ''
    from erp.resource_override o where strpos(o.key, 'refusal.erp' || 'ware_') > 0
$$;

revoke all on function erp.legacy_refusal_prefix_report() from public, anon;

comment on function erp.legacy_refusal_prefix_report() is
  'Everything still naming the retired refusal prefix. The environment variable '
  'names the worker and the Edge Functions read are deliberately not in scope: '
  'they are the names of secrets set on a host, not codes the client matches.';

create or replace function erp.assert_no_legacy_refusal_prefix()
returns text
language plpgsql
stable
set search_path to ''
as $$
declare v_count integer; v_detail text; v_current integer;
begin
  select count(*), string_agg(format('  %s — %s', r.finding, r.reference), E'\n')
    into v_count, v_detail
    from erp.legacy_refusal_prefix_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_RETIRED_REFUSAL_PREFIX: % finding(s)\n%', v_count, v_detail
      using errcode = '23514',
      hint = 'The client matches a refusal by its CLOVEERP_ token to find what was '
             'refused and the next action. A code under the retired prefix resolves '
             'to nothing, so the person who tripped it gets raw database text.';
  end if;

  -- And the check has to be able to find something, or it proves nothing. Every
  -- other check in this repository that could pass by seeing nothing carries a
  -- companion count, because a scraper that has quietly stopped matching reports
  -- a clean bill of health.
  select count(*) into v_current
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test', 'public')
     and p.prokind in ('f', 'p')
     and strpos(p.prosrc, 'CLOVEERP_') > 0;

  if v_current < 500 then
    raise exception 'CLOVEERP_REFUSAL_SCRAPER_BLIND: only % routine(s) raise a refusal at all', v_current
      using hint = 'This check passes by finding nothing. Finding nothing on both sides '
                   'means it has stopped looking. Fix the query, do not lower the floor.';
  end if;

  return format('refusal prefix: CLOVEERP_ throughout, %s registered code(s), %s routine(s) raising',
                (select count(*) from erp_ref.refusal), v_current);
end;
$$;

revoke all on function erp.assert_no_legacy_refusal_prefix() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('refusal_prefix_current', 'Every refusal code says Clove ERP',
   'assertion', 'platform', 'erp', 'assert_no_legacy_refusal_prefix', '',
   'legacy_refusal_prefix_report', '',
   'The client finds what was refused and the next action by matching the '
   'refusal''s CLOVEERP_ token. A code raised under the retired prefix matches '
   'nothing, so the person sees raw database text instead.', true,
   (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
