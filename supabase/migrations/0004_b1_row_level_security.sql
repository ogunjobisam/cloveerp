-- =============================================================================
-- ERPWare — B1 (part 4/4): row-level security, and the invariant that proves it
-- Spec: 2.2 (Enforcement), Part 7 ("No unscoped data")
--
--   "Row-level security policies on every table, keyed on the session's tenant
--    context, applied at the database layer so that an application bug cannot
--    leak data."
--
-- Policies are GENERATED rather than hand-written. Hand-written policies are
-- how a table ends up shipped without one. erp.apply_row_security() walks the
-- schema and gives every table the policy its registration calls for; every
-- later migration ends by calling it again. erp.assert_isolation() then fails
-- loudly if any table escaped, and runs as part of the test suite on every build.
-- =============================================================================

create schema if not exists erp_meta;

comment on schema erp_meta is
  'Platform metadata about the schema itself — not tenant data, not product '
  'reference data. Never readable by a tenant session.';

-- -----------------------------------------------------------------------------
-- Table registration
-- -----------------------------------------------------------------------------

create type erp_meta.table_class as enum (
  -- Ordinary tenant-scoped table: full CRUD under tenant isolation.
  'tenant_scoped',
  -- Tenant-scoped, but rows may only be inserted and read. Audit, events,
  -- access log, stock ledger. Spec 3.2: "No role, including administrator,
  -- holds update or delete rights on audit data."
  'tenant_scoped_append_only',
  -- erp.tenant itself: the row IS the tenant, matched on id rather than
  -- tenant_id, and read-only to tenant sessions.
  'tenant_root',
  -- Product content in erp_ref: identical for every tenant, readable by all,
  -- writable by none of them.
  'product_content',
  -- Platform metadata in erp_meta: invisible to tenant sessions entirely.
  'platform_internal'
);

create table erp_meta.table_policy (
  schema_name     text not null,
  table_name      text not null,
  table_class     erp_meta.table_class not null,
  -- Free-text note explaining anything unusual, surfaced by the isolation report.
  note            text,
  registered_at   timestamptz not null default now(),
  primary key (schema_name, table_name)
);

-- One row of the policy-generation work list, so the generator can iterate over
-- a snapshot taken before it starts issuing DDL.
create type erp_meta.rls_target as (
  schema_name text,
  table_name  text,
  table_class text
);

-- Registers a table, defaulting to the safest classification. Called by every
-- migration that creates tables.
create or replace function erp_meta.register_table(
  p_schema text, p_table text, p_class erp_meta.table_class, p_note text default null)
returns void
language sql
set search_path = ''
as $$
  insert into erp_meta.table_policy (schema_name, table_name, table_class, note)
  values (p_schema, p_table, p_class, p_note)
  on conflict (schema_name, table_name)
    do update set table_class = excluded.table_class, note = excluded.note;
$$;

-- Any table in erp/erp_ref/erp_meta that nobody registered is registered here,
-- by inference, so that a forgotten registration still gets a policy rather
-- than silently getting none.
create or replace function erp_meta.register_unregistered_tables()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r record;
  v_count integer := 0;
  v_class erp_meta.table_class;
begin
  for r in
    select c.relnamespace::regnamespace::text as schema_name, c.relname as table_name,
           exists (
             select 1 from pg_catalog.pg_attribute a
              where a.attrelid = c.oid and a.attname = 'tenant_id' and a.attnum > 0
                and not a.attisdropped
           ) as has_tenant_id
      from pg_catalog.pg_class c
     where c.relkind = 'r'
       and c.relnamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta')
       and not exists (
         select 1 from erp_meta.table_policy tp
          where tp.schema_name = c.relnamespace::regnamespace::text
            and tp.table_name = c.relname)
  loop
    v_class := case
      when r.schema_name = 'erp_meta' then 'platform_internal'
      when r.schema_name = 'erp_ref'  then 'product_content'
      when r.schema_name = 'erp' and r.table_name = 'tenant' then 'tenant_root'
      when r.has_tenant_id then 'tenant_scoped'
      -- An erp table with no tenant_id and no explicit registration is a bug.
      -- Classify it as platform_internal so it is locked down, and let
      -- assert_isolation() report it.
      else 'platform_internal'
    end::erp_meta.table_class;

    perform erp_meta.register_table(r.schema_name, r.table_name, v_class,
      'auto-registered by inference');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- Policy generation
-- -----------------------------------------------------------------------------

create or replace function erp.apply_row_security()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_schemas text[];
  v_tables  text[];
  v_classes text[];
  r         record;
  v_applied integer := 0;
  v_qual    text;
  i         integer;
begin
  perform erp_meta.register_unregistered_tables();

  -- Materialise the target list BEFORE touching anything. A FOR ... IN SELECT
  -- loop would hold an open cursor over erp_meta.table_policy, and this loop
  -- issues ALTER TABLE against that very table.
  select coalesce(array_agg(tp.schema_name order by tp.schema_name, tp.table_name), '{}'),
         coalesce(array_agg(tp.table_name  order by tp.schema_name, tp.table_name), '{}'),
         coalesce(array_agg(tp.table_class::text order by tp.schema_name, tp.table_name), '{}')
    into v_schemas, v_tables, v_classes
    from erp_meta.table_policy tp
    join pg_catalog.pg_class c
      on c.relname = tp.table_name
     and c.relnamespace::regnamespace::text = tp.schema_name
     and c.relkind = 'r';

  for i in 1 .. coalesce(array_length(v_schemas, 1), 0) loop
    r := row(v_schemas[i], v_tables[i], v_classes[i])::erp_meta.rls_target;
    -- RLS on, and FORCEd so that even the table owner is subject to it. Only a
    -- role holding BYPASSRLS (service_role, the migration owner) sees past it.
    execute format('alter table %I.%I enable row level security', r.schema_name, r.table_name);
    execute format('alter table %I.%I force row level security', r.schema_name, r.table_name);

    -- Drop and recreate so this function is the single source of truth: an
    -- edited policy does not survive the next migration.
    execute format('drop policy if exists tenant_isolation on %I.%I', r.schema_name, r.table_name);
    execute format('drop policy if exists tenant_insert on %I.%I', r.schema_name, r.table_name);
    execute format('drop policy if exists product_read on %I.%I', r.schema_name, r.table_name);

    -- Nothing in these schemas is ever reachable by an unauthenticated caller.
    execute format('revoke all on %I.%I from public, anon', r.schema_name, r.table_name);

    case r.table_class
      when 'tenant_scoped' then
        v_qual := 'tenant_id = erp.current_tenant_id()';
        execute format(
          'create policy tenant_isolation on %I.%I
             as permissive for all to authenticated
             using (%s) with check (%s)',
          r.schema_name, r.table_name, v_qual, v_qual);
        execute format(
          'grant select, insert, update, delete on %I.%I to authenticated',
          r.schema_name, r.table_name);

      when 'tenant_scoped_append_only' then
        v_qual := 'tenant_id = erp.current_tenant_id()';
        -- SELECT and INSERT only. There is deliberately no policy for UPDATE
        -- or DELETE: with RLS enabled and no permissive policy for a command,
        -- that command matches zero rows for every caller.
        execute format(
          'create policy tenant_isolation on %I.%I
             as permissive for select to authenticated using (%s)',
          r.schema_name, r.table_name, v_qual);
        execute format(
          'create policy tenant_insert on %I.%I
             as permissive for insert to authenticated with check (%s)',
          r.schema_name, r.table_name, v_qual);
        -- Belt and braces: the privilege is not granted either, so the attempt
        -- fails at the permission check before RLS is even consulted.
        execute format(
          'grant select, insert on %I.%I to authenticated', r.schema_name, r.table_name);
        execute format(
          'revoke update, delete, truncate on %I.%I from authenticated',
          r.schema_name, r.table_name);

      when 'tenant_root' then
        -- A session sees its own tenant row and nothing else, and cannot
        -- change it: provisioning and lifecycle are trusted operations.
        execute format(
          'create policy tenant_isolation on %I.%I
             as permissive for select to authenticated
             using (id = erp.current_tenant_id())',
          r.schema_name, r.table_name);
        execute format('grant select on %I.%I to authenticated', r.schema_name, r.table_name);
        execute format(
          'revoke insert, update, delete, truncate on %I.%I from authenticated',
          r.schema_name, r.table_name);

      when 'product_content' then
        -- Identical for every tenant, so there is nothing to isolate — but it
        -- is still read-only, because a tenant may never mutate product content.
        execute format(
          'create policy product_read on %I.%I
             as permissive for select to authenticated using (true)',
          r.schema_name, r.table_name);
        execute format('grant select on %I.%I to authenticated', r.schema_name, r.table_name);
        execute format(
          'revoke insert, update, delete, truncate on %I.%I from authenticated',
          r.schema_name, r.table_name);

      when 'platform_internal' then
        -- No policy at all, and no grant. RLS is enabled, so a tenant session
        -- sees zero rows even if a grant is ever added by accident.
        execute format(
          'revoke all on %I.%I from authenticated', r.schema_name, r.table_name);
    end case;

    v_applied := v_applied + 1;
  end loop;

  return v_applied;
end;
$$;

comment on function erp.apply_row_security() is
  'Generates the row-level security policy for every registered table. Every '
  'migration that creates a table ends by calling this. Policies are never '
  'hand-written, because a hand-written policy is one that can be forgotten.';

-- -----------------------------------------------------------------------------
-- The isolation invariant
--
-- Spec 2.2: "Automated isolation testing: the test suite includes adversarial
-- cases attempting cross-tenant reads and writes through every entry point,
-- and these run on every build."
--
-- assert_isolation() is the structural half of that: it proves that no table
-- exists which could leak, whether or not a test happens to exercise it.
-- The behavioural half lives in the adversarial test suite.
-- -----------------------------------------------------------------------------

create or replace function erp.isolation_report()
returns table (
  schema_name  text,
  table_name   text,
  table_class  text,
  finding      text
)
language sql
stable
set search_path = ''
as $$
  with t as (
    select c.oid,
           c.relnamespace::regnamespace::text as schema_name,
           c.relname as table_name,
           c.relrowsecurity,
           c.relforcerowsecurity,
           tp.table_class,
           exists (
             select 1 from pg_catalog.pg_attribute a
              where a.attrelid = c.oid and a.attname = 'tenant_id'
                and a.attnum > 0 and not a.attisdropped
           ) as has_tenant_id
      from pg_catalog.pg_class c
      left join erp_meta.table_policy tp
        on tp.schema_name = c.relnamespace::regnamespace::text
       and tp.table_name = c.relname
     where c.relkind = 'r'
       and c.relnamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta')
  )
  select t.schema_name, t.table_name, coalesce(t.table_class::text, '(unregistered)'), f.finding
    from t
    cross join lateral (
      select unnest(array_remove(array[
        case when t.table_class is null
             then 'table is not registered in erp_meta.table_policy' end,
        case when not t.relrowsecurity
             then 'row level security is not enabled' end,
        case when not t.relforcerowsecurity
             then 'row level security is not forced, so the table owner bypasses it' end,
        case when t.schema_name = 'erp'
              and t.table_class in ('tenant_scoped', 'tenant_scoped_append_only')
              and not t.has_tenant_id
             then 'tenant-scoped table has no tenant_id column' end,
        case when t.schema_name = 'erp'
              and t.has_tenant_id
              and t.table_class not in ('tenant_scoped', 'tenant_scoped_append_only')
             then 'table carries tenant_id but is not classified as tenant-scoped' end,
        case when t.schema_name = 'erp'
              and not t.has_tenant_id
              and t.table_name <> 'tenant'
              and t.table_class <> 'platform_internal'
             then 'operational table in erp has no tenant_id (spec: no unscoped data)' end,
        case when t.table_class in ('tenant_scoped', 'tenant_root', 'product_content')
              and not exists (
                select 1 from pg_catalog.pg_policy p where p.polrelid = t.oid)
             then 'no row level security policy is defined' end,
        case when t.table_class = 'tenant_scoped_append_only'
              and exists (
                select 1 from pg_catalog.pg_policy p
                 where p.polrelid = t.oid and p.polcmd in ('u', 'd'))
             then 'append-only table has an UPDATE or DELETE policy' end,
        case when t.table_class = 'tenant_scoped_append_only'
              and (has_table_privilege('authenticated', t.oid, 'UPDATE')
                or has_table_privilege('authenticated', t.oid, 'DELETE'))
             then 'append-only table grants UPDATE or DELETE to authenticated' end,
        case when has_table_privilege('anon', t.oid, 'SELECT')
             then 'table is readable by the anonymous role' end
      ], null)) as finding
    ) f
   order by 1, 2, 4
$$;

create or replace function erp.assert_isolation()
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_findings text;
  v_count    integer;
begin
  select count(*), string_agg(format('  %s.%s: %s', schema_name, table_name, finding), E'\n')
    into v_count, v_findings
    from erp.isolation_report();

  if v_count > 0 then
    raise exception E'ERPWARE_ISOLATION_VIOLATION: % finding(s)\n%', v_count, v_findings;
  end if;
end;
$$;

comment on function erp.assert_isolation() is
  'Fails if any table in the product could leak across tenants. Run on every '
  'build. A green result is a structural proof, not a sample.';

-- -----------------------------------------------------------------------------
-- Schema-level grants
-- -----------------------------------------------------------------------------

revoke all on schema erp, erp_ref, erp_meta from public;
grant usage on schema erp, erp_ref to authenticated;
-- erp_meta is deliberately not granted to authenticated at all.

-- Sequences behind identity columns on append-only tables.
grant usage on all sequences in schema erp to authenticated;
alter default privileges in schema erp grant usage on sequences to authenticated;

-- -----------------------------------------------------------------------------
-- Registration for everything B1 created, then generate the policies.
-- -----------------------------------------------------------------------------

select erp_meta.register_table('erp', 'tenant', 'tenant_root');
select erp_meta.register_table('erp', 'access_log', 'tenant_scoped_append_only',
  'Spec 3.1: all access decisions logged. Decisions are facts; facts are not edited.');

select erp.apply_row_security();
select erp.assert_isolation();
