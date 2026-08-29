-- =============================================================================
-- ERPWare — bringing erp_ai inside the boundary checks
--
-- Found while reading B1 and B10 together rather than in sequence, which is
-- the only way this was ever going to surface.
--
-- Four of B1's safety nets name the schemas they cover literally, and all four
-- were written before erp_ai existed:
--
--   erp_meta.register_unregistered_tables()  infers a class for any table
--                                            nobody registered, so a forgotten
--                                            registration still gets a policy
--   erp.isolation_report(), table findings   RLS enabled, forced, policied,
--                                            not readable by anon
--   erp.isolation_report(), view findings    security_invoker views only
--   erp.isolation_report(), function findings SECURITY DEFINER allow-list
--
-- Each reads in ('erp', 'erp_ref', 'erp_meta'). B10 added erp_ai after all of
-- them, so the schema whose entire purpose is to be a boundary is the one
-- schema the boundary checks do not watch.
--
-- Nothing is wrong today, and that is precisely why this is worth fixing now
-- rather than after something is. B10 registers both its tables explicitly, so
-- erp.apply_row_security() — which is registry-driven and schema-agnostic —
-- does protect them; and erp_ai.apply_proposal() is SECURITY INVOKER. The
-- defect is not in what exists, it is in what would not be caught: a future
-- erp_ai table added without a register_table() call would get no policy, no
-- inference, and no failing assertion. A SECURITY DEFINER function added there
-- would bypass the allow-list that exists to enumerate exactly one.
--
-- The fix is the schema list, in four places. The two functions below are
-- otherwise unchanged from 0004 and 0007 — they are reproduced in full because
-- that is what CREATE OR REPLACE requires, not because anything else moved.
-- =============================================================================

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
       and c.relnamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
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
       and c.relnamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
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
       and c.relnamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_ai')
  ),
  function_findings as (
    select p.pronamespace::regnamespace::text as schema_name,
           p.proname as table_name,
           '(function)' as table_class,
           'SECURITY DEFINER function is not in erp_meta.security_definer_allowance' as finding
      from pg_catalog.pg_proc p
     where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
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

-- erp_ai's tables were registered explicitly by B10, so this changes nothing
-- today. It is here so that the next one is caught if it is not.
select erp_meta.register_unregistered_tables();

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_intelligence_boundary();
select erp.assert_isolation();
