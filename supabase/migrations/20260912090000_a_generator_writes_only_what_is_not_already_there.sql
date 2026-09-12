-- =============================================================================
-- A generator writes only what is not already there
--
-- The build stands the schema up from an empty cluster on every change, and
-- that replay had grown to twenty minutes. Measured from the run that failed on
-- 12 September: 269 migrations, median 1.19s each, but thirty-nine of them at
-- ten seconds or more accounting for fifteen of the twenty minutes — and
-- eighty-seven per cent of the step's 108,887 log lines were generator output,
-- overwhelmingly `trigger "..." for relation "..." does not exist, skipping`.
--
-- The cause is not the migrations. Each one ends by re-running the generators,
-- which is right — a migration carries its own guarantees rather than assuming
-- someone else arranged them. But the generators rewrite EVERYTHING every time:
-- apply_audit_coverage drops and recreates a trigger on every registered table,
-- apply_append_only_guards on every append-only one, and apply_execute_grants
-- issues a grant for all eight hundred and fifty-eight routines the reach names
-- whether or not the grant is already held. Two hundred and sixty-nine times,
-- over a schema that grows all week.
--
-- So they become differential. Desired state is computed exactly as before;
-- what changes is that a trigger already correct is left alone and a grant
-- already held is not re-issued. The end state is identical — which is the
-- whole point, and is why this needs no new assertion to be trusted:
-- erp.assert_audit_coverage() reads erp.audit_coverage_report() and
-- erp.assert_execute_grants_match_reach() reads the register, both against the
-- catalogue rather than against what a generator claims it did. A generator
-- that skipped something it should not have fails the same build it always did,
-- in the same migration.
--
-- Deliberately NOT touched here: erp.apply_row_security() and
-- erp.apply_live_config_guards(). They may well have the same shape, but they
-- have not been read and measured, and a generator is not a thing to change on
-- a hunch.
--
-- Return values keep their meaning: how many tables are covered, how many
-- routines the reach names — not how many statements this call happened to
-- issue. A number in the build log that changes depending on what ran last is
-- worse than no number.
-- =============================================================================

set lock_timeout = '30s';

-- Audit coverage --------------------------------------------------------------
--
-- tgtype is a bitmask: ROW = 1, BEFORE = 2, INSERT = 4, DELETE = 8, UPDATE = 16.
-- `after insert or update or delete ... for each row` is therefore 1+4+8+16 = 29,
-- with the BEFORE bit clear. Comparing the mask and the function together is
-- what makes "already correct" mean correct, rather than merely present under
-- the right name.

create or replace function erp.apply_audit_coverage()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r         record;
  v_covered integer := 0;
begin
  perform erp_meta.register_unregistered_tables();

  for r in
    select tp.schema_name,
           tp.table_name,
           (tp.table_class <> 'tenant_scoped'
            or exists (select 1 from erp_meta.audit_exemption ae
                        where ae.schema_name = tp.schema_name
                          and ae.table_name = tp.table_name)) as exempt,
           exists (
             select 1
               from pg_catalog.pg_trigger t
              where t.tgrelid = c.oid
                and not t.tgisinternal
                and t.tgname = 't_' || tp.table_name || '_audit'
                and t.tgfoid = 'erp.audit_row_change'::regproc
                and t.tgtype = 29
           ) as correct,
           exists (
             select 1
               from pg_catalog.pg_trigger t
              where t.tgrelid = c.oid
                and not t.tgisinternal
                and t.tgname = 't_' || tp.table_name || '_audit'
           ) as present
      from erp_meta.table_policy tp
      join pg_catalog.pg_class c
        on c.relname = tp.table_name
       and c.relnamespace::regnamespace::text = tp.schema_name
       and c.relkind = 'r'
     order by tp.schema_name, tp.table_name
  loop
    if r.exempt then
      -- Exempt and carrying one anyway is the one case that still needs a drop.
      if r.present then
        execute format('drop trigger t_%s_audit on %I.%I',
                       r.table_name, r.schema_name, r.table_name);
      end if;
      continue;
    end if;

    v_covered := v_covered + 1;

    if r.correct then
      continue;
    end if;

    if r.present then
      execute format('drop trigger t_%s_audit on %I.%I',
                     r.table_name, r.schema_name, r.table_name);
    end if;

    execute format(
      'create trigger t_%s_audit after insert or update or delete on %I.%I
         for each row execute function erp.audit_row_change()',
      r.table_name, r.schema_name, r.table_name);
  end loop;

  return v_covered;
end;
$$;

comment on function erp.apply_audit_coverage() is
  'Every tenant-scoped table that is not exempt carries the audit trigger. '
  'Differential: a trigger already bound to erp.audit_row_change() with the '
  'right event mask is left where it is. Returns how many tables are covered, '
  'not how many statements this call issued.';

-- Append-only guards ----------------------------------------------------------
--
-- `before update or delete ... for each row` is ROW 1 + BEFORE 2 + DELETE 8 +
-- UPDATE 16 = 27.

create or replace function erp.apply_append_only_guards()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r         record;
  v_guarded integer := 0;
begin
  for r in
    select tp.schema_name,
           tp.table_name,
           exists (
             select 1
               from pg_catalog.pg_trigger t
              where t.tgrelid = c.oid
                and not t.tgisinternal
                and t.tgname = 't_' || tp.table_name || '_append_only'
                and t.tgfoid = 'erp.forbid_mutation'::regproc
                and t.tgtype = 27
           ) as correct,
           exists (
             select 1
               from pg_catalog.pg_trigger t
              where t.tgrelid = c.oid
                and not t.tgisinternal
                and t.tgname = 't_' || tp.table_name || '_append_only'
           ) as present
      from erp_meta.table_policy tp
      join pg_catalog.pg_class c
        on c.relname = tp.table_name
       and c.relnamespace::regnamespace::text = tp.schema_name
       and c.relkind = 'r'
     where tp.table_class = 'tenant_scoped_append_only'
     order by tp.schema_name, tp.table_name
  loop
    v_guarded := v_guarded + 1;

    if r.correct then
      continue;
    end if;

    if r.present then
      execute format('drop trigger t_%s_append_only on %I.%I',
                     r.table_name, r.schema_name, r.table_name);
    end if;

    execute format(
      'create trigger t_%s_append_only before update or delete on %I.%I
         for each row execute function erp.forbid_mutation()',
      r.table_name, r.schema_name, r.table_name);
  end loop;

  return v_guarded;
end;
$$;

comment on function erp.apply_append_only_guards() is
  'Every append-only table refuses update and delete. Differential: a guard '
  'already bound to erp.forbid_mutation() with the right event mask is left '
  'where it is. Returns how many tables are guarded.';

-- Execute grants --------------------------------------------------------------
--
-- The expensive one. The reach names eight hundred and fifty-eight routines and
-- every call granted all of them; now it grants the ones not already held. The
-- two sweeps that take privileges AWAY are unchanged in effect and already only
-- touch what they must, but the blanket revoke from PUBLIC is guarded so it
-- stops rewriting a catalogue that already says nothing.

create or replace function erp.apply_execute_grants()
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  r        record;
  v_reach  integer := 0;
begin
  -- PUBLIC holds nothing, anywhere in the product schemas.
  if exists (
    select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
       and has_function_privilege('public', p.oid, 'execute')
  ) then
    revoke execute on all routines in schema erp, erp_ref, erp_meta, erp_ai, erp_test, erp_ingress from public;
  end if;

  -- The reach, granted — where it is not granted already.
  create temp table _reach on commit drop as select * from erp.invoker_reach_report();

  select count(*) into v_reach from _reach;

  for r in
    select x.identity
      from _reach x
     where not (has_function_privilege('authenticated', x.oid, 'execute')
                and has_function_privilege('service_role', x.oid, 'execute'))
  loop
    execute format('grant execute on routine %s to authenticated, service_role', r.identity);
  end loop;

  -- Anything authenticated or service_role may execute that the reach does
  -- not name loses the grant: a privilege with no reason is a privilege with
  -- no owner.
  for r in
    select p.oid::regprocedure::text as identity
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'erp_ingress')
       and (has_function_privilege('authenticated', p.oid, 'execute')
            or has_function_privilege('service_role', p.oid, 'execute'))
       and not exists (select 1 from _reach x where x.oid = p.oid)
  loop
    execute format('revoke execute on routine %s from authenticated, service_role', r.identity);
  end loop;

  -- The enquiry role keeps its four definers, and nothing else.
  if exists (
    select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'erp_ingress'
       and not has_function_privilege('clove_enquiry', p.oid, 'execute')
  ) then
    grant execute on all functions in schema erp_ingress to clove_enquiry;
  end if;

  -- The register mirrors the grants.
  delete from erp_meta.invoker_reach ir
   where not exists (select 1 from _reach x where x.identity = ir.identity);
  insert into erp_meta.invoker_reach (identity, schema_name, function_name, reason)
  select x.identity, x.schema_name, x.function_name, x.reason from _reach x
  on conflict (identity) do update set reason = excluded.reason;

  drop table _reach;
  return v_reach;
end;
$$;

comment on function erp.apply_execute_grants() is
  'authenticated and service_role may execute exactly what erp.invoker_reach_report() '
  'names, and nothing else. Differential: a grant already held is not re-issued. '
  'Returns how many routines the reach names.';

-- The generators are the thing being changed, so they run, and the assertions
-- that read the catalogue rather than the generators decide whether they were
-- right.
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_execute_grants_match_reach();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
