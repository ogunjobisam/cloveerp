-- =============================================================================
-- ERPWare — B1: SECURITY DEFINER is an allow-list, not a convenience
--
-- Why this exists
-- ---------------
-- erp.current_tenant_id() reads erp.app_user. erp.app_user's row-level security
-- policy calls erp.current_tenant_id(). Evaluating either one re-enters the
-- other until the stack runs out, so the lookup has to run with RLS bypassed —
-- which means SECURITY DEFINER (migration 0001, erp.principal_context).
--
-- That fix carries a trap. A SECURITY DEFINER function runs as its owner, and
-- the owner here holds BYPASSRLS, so anything inside that frame asking "is this
-- session trusted enough to declare its own tenant?" gets back *yes*, for every
-- caller. erp.current_tenant_id() falls back to a GUC for background jobs; had
-- the whole of it been made SECURITY DEFINER, any caller could have set that
-- GUC and been handed a tenant context they have no claim to. The same trap
-- caught erp.log_access_decision(), which was SECURITY DEFINER for no reason at
-- all — it is SECURITY INVOKER from migration 0003 onward.
--
-- So the privilege is split as narrowly as it will go: one definer function,
-- argument-free, single table, returning only the caller's own row; everything
-- else invoker, so erp.session_is_trusted() always evaluates against the real
-- caller.
--
-- A discipline is worth what its enforcement is worth. This migration records
-- the allow-list and teaches erp.isolation_report() to fail the build on any
-- SECURITY DEFINER function in the product schemas that is not on it — so the
-- next person who reaches for SECURITY DEFINER to make something work has to
-- write down why first.
-- =============================================================================

create table if not exists erp_meta.security_definer_allowance (
  schema_name   text not null,
  function_name text not null,
  rationale     text not null,
  primary key (schema_name, function_name)
);

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'principal_context',
        'Breaks the RLS recursion on erp.app_user. Argument-free, single table, '
        'returns only the caller''s own row, never consults the trust check.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

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
  -- A SECURITY DEFINER function runs as an owner that bypasses RLS. Inside such
  -- a frame the trust check answers yes for every caller, so each one is a
  -- potential escalation and has to be argued for explicitly.
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
  union all
  select * from function_findings
  order by 1, 2, 4
$$;

select erp.apply_row_security();
