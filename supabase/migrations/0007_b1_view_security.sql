-- =============================================================================
-- ERPWare — B1: views are an entry point too
--
-- A PostgreSQL view runs, by default, with the permissions of the user who
-- OWNS it. Every view here is owned by the migration role, and that role holds
-- BYPASSRLS. So a view over tenant-scoped tables is, by default, a hole
-- straight through the isolation model: the base tables are policed, the view
-- reading them is not, and a tenant querying the view sees every tenant.
--
-- erp.effective_permission was exactly that. It is the view the authorisation
-- predicate reads, so the leak would have been in the security path itself.
--
-- Two changes:
--   1. apply_row_security() now also walks views, sets security_invoker on each
--      so the base-table policies apply to the *querying* user, and grants
--      accordingly.
--   2. isolation_report() fails the build on any view that lacks it.
--
-- Spec 2.2: "every query path ... runs inside a tenant context". A view is a
-- query path.
-- =============================================================================

create or replace function erp.apply_row_security()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_schemas text[];
  v_tables  text[];
  v_classes text[];
  r         erp_meta.rls_target;
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
    -- role holding BYPASSRLS sees past it.
    execute format('alter table %I.%I enable row level security', r.schema_name, r.table_name);
    execute format('alter table %I.%I force row level security', r.schema_name, r.table_name);

    -- Drop and recreate so this function is the single source of truth: an
    -- edited policy does not survive the next migration.
    execute format('drop policy if exists tenant_isolation on %I.%I', r.schema_name, r.table_name);
    execute format('drop policy if exists tenant_insert on %I.%I', r.schema_name, r.table_name);
    execute format('drop policy if exists product_read on %I.%I', r.schema_name, r.table_name);

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
        execute format(
          'grant select, insert on %I.%I to authenticated', r.schema_name, r.table_name);
        execute format(
          'revoke update, delete, truncate on %I.%I from authenticated',
          r.schema_name, r.table_name);

      when 'tenant_root' then
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
        execute format(
          'create policy product_read on %I.%I
             as permissive for select to authenticated using (true)',
          r.schema_name, r.table_name);
        execute format('grant select on %I.%I to authenticated', r.schema_name, r.table_name);
        execute format(
          'revoke insert, update, delete, truncate on %I.%I from authenticated',
          r.schema_name, r.table_name);

      when 'platform_internal' then
        execute format(
          'revoke all on %I.%I from authenticated', r.schema_name, r.table_name);
    end case;

    v_applied := v_applied + 1;
  end loop;

  -- ---------------------------------------------------------------------------
  -- Views. security_invoker makes the base tables' policies apply to whoever is
  -- querying, instead of to the view's owner — who bypasses them.
  -- ---------------------------------------------------------------------------
  select coalesce(array_agg(c.relnamespace::regnamespace::text
                            order by c.relnamespace::regnamespace::text, c.relname), '{}'),
         coalesce(array_agg(c.relname
                            order by c.relnamespace::regnamespace::text, c.relname), '{}')
    into v_schemas, v_tables
    from pg_catalog.pg_class c
   where c.relkind in ('v', 'm')
     and c.relnamespace::regnamespace::text in ('erp', 'erp_ref');

  for i in 1 .. coalesce(array_length(v_schemas, 1), 0) loop
    -- Materialised views cannot take security_invoker; they are pre-computed
    -- from the owner's vantage point and so must never be granted to a tenant
    -- role. Reporting snapshots belong behind a tenant-scoped table instead.
    if (select c.relkind
          from pg_catalog.pg_class c
         where c.relname = v_tables[i]
           and c.relnamespace::regnamespace::text = v_schemas[i]) = 'm' then
      execute format('revoke all on %I.%I from public, anon, authenticated',
                     v_schemas[i], v_tables[i]);
    else
      execute format('alter view %I.%I set (security_invoker = true)',
                     v_schemas[i], v_tables[i]);
      execute format('revoke all on %I.%I from public, anon', v_schemas[i], v_tables[i]);
      execute format('grant select on %I.%I to authenticated', v_schemas[i], v_tables[i]);
    end if;
    v_applied := v_applied + 1;
  end loop;

  return v_applied;
end;
$$;

comment on function erp.apply_row_security() is
  'Generates the row-level security policy for every registered table, and '
  'forces security_invoker on every view. Every migration that creates a table '
  'or a view ends by calling this. Policies are never hand-written, because a '
  'hand-written policy is one that can be forgotten.';

-- -----------------------------------------------------------------------------
-- Report on views as well as tables and functions.
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
  ),
  table_findings as (
    select t.schema_name, t.table_name,
           coalesce(t.table_class::text, '(unregistered)') as table_class,
           f.finding
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
  ),
  view_findings as (
    select c.relnamespace::regnamespace::text as schema_name,
           c.relname as table_name,
           case c.relkind when 'v' then '(view)' else '(materialised view)' end as table_class,
           f.finding
      from pg_catalog.pg_class c
      cross join lateral (
        select unnest(array_remove(array[
          -- The default is the opposite, and the default leaks.
          case when c.relkind = 'v'
                and not coalesce(
                      array_to_string(c.reloptions, ',') like '%security_invoker=true%', false)
               then 'view does not set security_invoker, so it runs with the owner''s '
                    'RLS bypass rather than the caller''s policies' end,
          case when c.relkind = 'm'
                and has_table_privilege('authenticated', c.oid, 'SELECT')
               then 'materialised view is readable by a tenant role but cannot enforce '
                    'row level security' end,
          case when has_table_privilege('anon', c.oid, 'SELECT')
               then 'view is readable by the anonymous role' end
        ], null)) as finding
      ) f
     where c.relkind in ('v', 'm')
       and c.relnamespace::regnamespace::text in ('erp', 'erp_ref')
  ),
  function_findings as (
    select p.pronamespace::regnamespace::text as schema_name,
           p.proname as table_name,
           '(function)' as table_class,
           'SECURITY DEFINER function is not in erp_meta.security_definer_allowance' as finding
      from pg_catalog.pg_proc p
     where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta')
       and p.prosecdef
       and not exists (
         select 1 from erp_meta.security_definer_allowance a
          where a.schema_name = p.pronamespace::regnamespace::text
            and a.function_name = p.proname)
  )
  select * from table_findings
  union all select * from view_findings
  union all select * from function_findings
  order by 1, 2, 4
$$;

select erp.apply_row_security();
