set lock_timeout = '30s';

-- =============================================================================
-- 20261010110000  The isolation sweep counts the append-only tables
-- -----------------------------------------------------------------------------
-- Definition of Done SEC-02: "Automated check: every table carrying an
-- organisation ID has row-level security enabled and a policy attached.
-- Expect: zero tables missing a policy. Run this as a test, not a manual
-- review." The v1 gate (7 October) held it as S2: erp.isolation_report()
-- required a policy of tenant_scoped, tenant_root and product_content
-- tables only. The append-only class — stock movements, the audit trail,
-- the event log, twenty-five tables in all — was checked for row security
-- being on and forced and for holding no UPDATE or DELETE policy, but never
-- for holding a policy at all. A table of that class with row security on
-- and no policy reads as empty to everyone, which fails closed; one with a
-- policy dropped by a later migration would not have been noticed either.
--
-- Read on main: every one of the twenty-five carries a tenant_isolation read
-- policy and a tenant_insert insert policy, so nothing is exposed today. The
-- gap is in what the sweep proves.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.isolation_report() requires a policy of append-only tables as of
--      every other tenant-holding class, and requires that the policy lets a
--      row be read, since an append-only table with only an insert policy
--      would hide its own history from the organisation that wrote it.
--   B. erp_test.isolation_sweep_suite proves the sweep bites: an append-only
--      table made inside the suite with row security and no policy is
--      reported, and given a policy it is not.
--
-- Production: one routine replaced. No table, policy or row changes; the
-- sweep runs at the end of every migration, and this one passes it.
--
-- Proof: erp_test.isolation_sweep_suite.
-- =============================================================================

do $isolation_report$
declare
  v_sig  constant text := 'erp.isolation_report()';
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$          case when t.table_class in ('tenant_scoped', 'tenant_root', 'product_content')
                and not exists (
                  select 1 from pg_catalog.pg_policy p where p.polrelid = t.oid)
               then 'no row level security policy is defined' end,
$o$;
  v_new  constant text := $n$          -- The append-only class too (20261010110000): stock movements, the
          -- audit trail and the event log hold an organisation's rows like
          -- any other, and a policy dropped there went unnoticed.
          case when t.table_class in ('tenant_scoped', 'tenant_root', 'product_content',
                                      'tenant_scoped_append_only')
                and not exists (
                  select 1 from pg_catalog.pg_policy p where p.polrelid = t.oid)
               then 'no row level security policy is defined' end,
          -- And it must let a row be read: an insert policy alone would hide
          -- an organisation's own history from it.
          case when t.table_class = 'tenant_scoped_append_only'
                and exists (select 1 from pg_catalog.pg_policy p where p.polrelid = t.oid)
                and not exists (
                  select 1 from pg_catalog.pg_policy p
                   where p.polrelid = t.oid and p.polcmd in ('r', '*'))
               then 'append-only table has no policy that lets its rows be read' end,
$n$;
  n integer;
begin
  if position('tenant_scoped_append_only'')' in v_def) > 0
     and position('no policy that lets its rows be read' in v_def) > 0 then
    raise notice '% already counts the append-only tables; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % policy rule found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$isolation_report$;

create or replace function erp_test.isolation_sweep_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_step   text := 'reading the schema';
  v_state  text;
  v_n integer; v_without integer; v_list text;
  v_found text;
begin
  begin
    -- ── 1. What the schema holds today ──────────────────────────────────────
    select count(*),
           count(*) filter (where not exists (
             select 1 from pg_catalog.pg_policy p
              where p.polrelid = format('%I.%I', tp.schema_name, tp.table_name)::regclass
                and p.polcmd in ('r', '*'))),
           string_agg(tp.schema_name || '.' || tp.table_name, ', ' order by tp.table_name)
             filter (where not exists (
               select 1 from pg_catalog.pg_policy p
                where p.polrelid = format('%I.%I', tp.schema_name, tp.table_name)::regclass
                  and p.polcmd in ('r', '*')))
      into v_n, v_without, v_list
      from erp_meta.table_policy tp
     where tp.table_class = 'tenant_scoped_append_only'
       and to_regclass(format('%I.%I', tp.schema_name, tp.table_name)) is not null;

    v_cases := v_cases + 1;
    case_name := 'every append-only table holds a policy that lets its organisation read its rows';
    passed := v_state is null and v_n > 0 and v_without = 0;
    detail := format('%s append-only table(s); without a read policy: %s', v_n, coalesce(v_list, 'none'));
    return next;

    select count(*) into v_n from erp.isolation_report();

    v_cases := v_cases + 1;
    case_name := 'the sweep finds nothing on the schema as built';
    passed := v_state is null and v_n = 0;
    detail := format('%s finding(s)', v_n);
    return next;

    -- ── 3–4. It bites ───────────────────────────────────────────────────────
    v_step := 'an append-only table with row security on and no policy';
    create table erp.zz_isolation_sweep_probe (
      id        uuid primary key default gen_random_uuid(),
      tenant_id uuid not null references erp.tenant (id) on delete cascade);
    alter table erp.zz_isolation_sweep_probe enable row level security;
    alter table erp.zz_isolation_sweep_probe force row level security;
    insert into erp_meta.table_policy (schema_name, table_name, table_class, note)
    values ('erp', 'zz_isolation_sweep_probe', 'tenant_scoped_append_only', 'isolation sweep suite probe');

    select string_agg(r.finding, '; ') into v_found
      from erp.isolation_report() r
     where r.schema_name = 'erp' and r.table_name = 'zz_isolation_sweep_probe';

    v_cases := v_cases + 1;
    case_name := 'an append-only table with no policy is reported by the sweep';
    passed := v_state is null and coalesce(v_found, '') like '%no row level security policy is defined%';
    detail := coalesce(v_found, 'nothing was reported');
    return next;

    v_step := 'the same table given an insert policy only, then a read policy';
    create policy tenant_insert on erp.zz_isolation_sweep_probe
      for insert with check (tenant_id = erp.current_tenant_id());
    select string_agg(r.finding, '; ') into v_found
      from erp.isolation_report() r
     where r.schema_name = 'erp' and r.table_name = 'zz_isolation_sweep_probe';

    create policy tenant_isolation on erp.zz_isolation_sweep_probe
      for select using (tenant_id = erp.current_tenant_id());
    select count(*) into v_n
      from erp.isolation_report() r
     where r.schema_name = 'erp' and r.table_name = 'zz_isolation_sweep_probe';

    v_cases := v_cases + 1;
    case_name := 'an insert policy alone is reported, and a read policy clears it';
    passed := v_state is null
          and coalesce(v_found, '') like '%no policy that lets its rows be read%'
          and v_n = 0;
    detail := format('with an insert policy only: %s; with a read policy: %s finding(s)',
                     coalesce(v_found, 'nothing reported'), v_n);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'the probe was undone';
  passed := v_state is null
        and to_regclass('erp.zz_isolation_sweep_probe') is null
        and not exists (select 1 from erp_meta.table_policy tp where tp.table_name = 'zz_isolation_sweep_probe');
  detail := coalesce(v_state, 'the probe table and its register row rolled back');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_ISOLATION_SWEEP_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_isolation_sweep_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _isolation_sweep on commit drop as
    select * from erp_test.isolation_sweep_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _isolation_sweep;
  drop table _isolation_sweep;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ISOLATION_SWEEP_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_ISOLATION_SWEEP_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('the isolation sweep counts the append-only tables: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.isolation_sweep_suite() from public, anon;
revoke all on function erp_test.assert_isolation_sweep_suite() from public, anon;

comment on function erp_test.isolation_sweep_suite() is
  'Definition of Done SEC-02 (20261010110000): every append-only table holds a read policy, the sweep finds nothing '
  'on the schema as built, and an append-only probe with no policy, or an insert policy only, is reported.';

comment on function erp_test.assert_isolation_sweep_suite() is
  'erp_test.isolation_sweep_suite(), five cases: SEC-02, the isolation sweep over the append-only tables.';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
