-- =============================================================================
-- ERPWare — attribution coverage
-- Spec 4.10: "Every business object carries created and modified attribution"
--
-- A gap, found by reading rather than by a failing test, which is the wrong way
-- round and the reason this migration also ships the assertion that would have
-- caught it.
--
-- B1 wired erp.touch_attribution() and erp.freeze_tenant_id() onto its tables by
-- hand, with a DO block listing them by name. Every migration after B1 added
-- tables and did not repeat the incantation, so from B2 onward created_by and
-- updated_at were whatever the caller happened to pass — usually nothing. The
-- columns were there. Nothing filled them.
--
-- Hand-written per-table triggers are how that happens, in exactly the way
-- hand-written RLS policies would have been. So attribution joins row security,
-- append-only guards and audit coverage as something GENERATED from the table
-- registry and asserted on every build:
--
--   erp.apply_attribution_triggers()   gives every qualifying table its triggers
--   erp.assert_attribution_coverage()  fails the build if one escaped
--
-- The tenant_id freeze matters more than the timestamps. Without it an UPDATE
-- can walk a row across the isolation boundary, and row-level security will let
-- it, because the row satisfies the policy both before and after.
--
-- Three shapes are legitimate, and the first run of the assertion turned up an
-- example of each:
--
--   full        created_at, created_by, updated_at, updated_by
--               A business object that can be amended. Gets touch_attribution().
--   creation    created_at, created_by
--               An immutable link row — erp.document_relation, the pegs on a
--               planned order. It is created or it is removed; there is no such
--               thing as amending it, and two null columns pretending otherwise
--               would be worse than honest.
--   exempt      anything else, and only with a written rationale
--               erp.event_outbox is a queue no principal creates; erp.stock_balance
--               is a derived cache no principal writes. Attributing either to a
--               user would be a lie told by a trigger.
--
-- Anything not one of those three fails the build.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Exemptions, in writing
-- -----------------------------------------------------------------------------

create table erp_meta.attribution_exemption (
  schema_name  text not null,
  table_name   text not null,
  rationale    text not null check (length(rationale) > 20),
  registered_at timestamptz not null default now(),
  primary key (schema_name, table_name)
);

comment on table erp_meta.attribution_exemption is
  'Tables that legitimately carry no principal attribution, each with the '
  'reason. A rationale is mandatory and length-checked so that "n/a" is not '
  'an available answer.';

-- The creation-only counterpart to erp.touch_attribution(). Fills the pair on
-- insert and leaves them alone thereafter, because a row of this shape is never
-- meaningfully updated.
create or replace function erp.touch_created_attribution()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.created_by := coalesce(new.created_by, erp.current_principal_id());
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- The report
-- -----------------------------------------------------------------------------

create or replace function erp.attribution_coverage_report()
returns table (schema_name text, table_name text, finding text)
language sql
stable
set search_path = ''
as $$
  with candidate as (
    select tp.schema_name, tp.table_name, c.oid as reloid,
           (select count(*) from pg_catalog.pg_attribute a
             where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
               and a.attname in ('created_at', 'created_by', 'updated_at', 'updated_by')
           ) as attribution_columns,
           (select count(*) from pg_catalog.pg_attribute a
             where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
               and a.attname in ('created_at', 'created_by')
           ) as creation_columns,
           exists (select 1 from pg_catalog.pg_attribute a
                    where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                      and a.attname = 'tenant_id') as has_tenant_id,
           exists (select 1 from erp_meta.attribution_exemption ax
                    where ax.schema_name = tp.schema_name
                      and ax.table_name = tp.table_name) as is_exempt
      from erp_meta.table_policy tp
      join pg_catalog.pg_class c
        on c.relname = tp.table_name
       and c.relnamespace = tp.schema_name::regnamespace
       and c.relkind = 'r'
     where tp.schema_name = 'erp'
       and tp.table_class in ('tenant_scoped', 'tenant_scoped_append_only')
  )
  -- Full attribution without the trigger that fills it.
  select cd.schema_name, cd.table_name,
         'carries all four attribution columns but no erp.touch_attribution() trigger'
    from candidate cd
   where cd.attribution_columns = 4
     and not exists (
       select 1 from pg_catalog.pg_trigger tg
        where tg.tgrelid = cd.reloid and not tg.tgisinternal
          and tg.tgfoid = 'erp.touch_attribution()'::regprocedure)
  union all
  -- Creation-only attribution without the trigger that fills it.
  select cd.schema_name, cd.table_name,
         'carries creation attribution but no erp.touch_created_attribution() trigger'
    from candidate cd
   where cd.attribution_columns = 2
     and cd.creation_columns = 2
     and not exists (
       select 1 from pg_catalog.pg_trigger tg
        where tg.tgrelid = cd.reloid and not tg.tgisinternal
          and tg.tgfoid = 'erp.touch_created_attribution()'::regprocedure)
  union all
  -- The isolation half, which applies to every tenant-scoped table regardless
  -- of how it is attributed.
  select cd.schema_name, cd.table_name,
         'is tenant-scoped but no erp.freeze_tenant_id() trigger stops a row '
         'being moved to another tenant by UPDATE'
    from candidate cd
   where cd.has_tenant_id
     and not exists (
       select 1 from pg_catalog.pg_trigger tg
        where tg.tgrelid = cd.reloid and not tg.tgisinternal
          and tg.tgfoid = 'erp.freeze_tenant_id()'::regprocedure)
  union all
  -- A shape that is neither full nor creation-only nor written down as an
  -- exception. Half-attributed is worse than unattributed: it looks like it has
  -- provenance and does not.
  select cd.schema_name, cd.table_name,
         format('attribution columns are %s, which is neither the full set nor '
                'the creation-only pair; complete them or register an exemption '
                'in erp_meta.attribution_exemption',
                (select coalesce(string_agg(a.attname, ', ' order by a.attname), 'none')
                   from pg_catalog.pg_attribute a
                  where a.attrelid = cd.reloid and a.attnum > 0 and not a.attisdropped
                    and a.attname in ('created_at','created_by','updated_at','updated_by')))
    from candidate cd
   where not cd.is_exempt
     and cd.attribution_columns not in (0, 4)
     and not (cd.attribution_columns = 2 and cd.creation_columns = 2)
   order by 1, 2, 3
$$;

comment on function erp.attribution_coverage_report() is
  'Spec 4.10. Every tenant-scoped table must fill its attribution by trigger '
  'rather than by hoping the caller does, and must refuse to have its '
  'tenant_id changed.';

-- -----------------------------------------------------------------------------
-- The generator
-- -----------------------------------------------------------------------------

create or replace function erp.apply_attribution_triggers()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r       record;
  v_count integer := 0;
begin
  perform erp_meta.register_unregistered_tables();

  for r in
    select tp.schema_name, tp.table_name, c.oid as reloid,
           (select count(*) from pg_catalog.pg_attribute a
             where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
               and a.attname in ('created_at', 'created_by', 'updated_at', 'updated_by')
           ) as attribution_columns,
           (select count(*) from pg_catalog.pg_attribute a
             where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
               and a.attname in ('created_at', 'created_by')
           ) as creation_columns,
           exists (select 1 from pg_catalog.pg_attribute a
                    where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                      and a.attname = 'tenant_id') as has_tenant_id
      from erp_meta.table_policy tp
      join pg_catalog.pg_class c
        on c.relname = tp.table_name
       and c.relnamespace = tp.schema_name::regnamespace
       and c.relkind = 'r'
     where tp.schema_name = 'erp'
       and tp.table_class in ('tenant_scoped', 'tenant_scoped_append_only')
     order by tp.schema_name, tp.table_name
  loop
    if r.attribution_columns = 4
       and not exists (
         select 1 from pg_catalog.pg_trigger tg
          where tg.tgrelid = r.reloid and not tg.tgisinternal
            and tg.tgfoid = 'erp.touch_attribution()'::regprocedure)
    then
      execute format(
        'create trigger t_%s_attribution before insert or update on %I.%I '
        'for each row execute function erp.touch_attribution()',
        r.table_name, r.schema_name, r.table_name);
      v_count := v_count + 1;
    end if;

    if r.attribution_columns = 2 and r.creation_columns = 2
       and not exists (
         select 1 from pg_catalog.pg_trigger tg
          where tg.tgrelid = r.reloid and not tg.tgisinternal
            and tg.tgfoid = 'erp.touch_created_attribution()'::regprocedure)
    then
      execute format(
        'create trigger t_%s_attribution before insert or update on %I.%I '
        'for each row execute function erp.touch_created_attribution()',
        r.table_name, r.schema_name, r.table_name);
      v_count := v_count + 1;
    end if;

    if r.has_tenant_id
       and not exists (
         select 1 from pg_catalog.pg_trigger tg
          where tg.tgrelid = r.reloid and not tg.tgisinternal
            and tg.tgfoid = 'erp.freeze_tenant_id()'::regprocedure)
    then
      execute format(
        'create trigger t_%s_freeze before update on %I.%I '
        'for each row execute function erp.freeze_tenant_id()',
        r.table_name, r.schema_name, r.table_name);
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

comment on function erp.apply_attribution_triggers() is
  'Generates the attribution and tenant-freeze triggers for every registered '
  'tenant-scoped table. Called at the end of every migration, like '
  'erp.apply_row_security(). Idempotent.';

create or replace function erp.assert_attribution_coverage()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s.%s — %s', schema_name, table_name, finding), E'\n')
    into v_count, v_detail
    from erp.attribution_coverage_report();

  if v_count > 0 then
    raise exception 'ERPWARE_ATTRIBUTION_GAP: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  return '';
end;
$$;

-- -----------------------------------------------------------------------------
-- The two tables that genuinely have no principal behind them
-- -----------------------------------------------------------------------------

insert into erp_meta.attribution_exemption (schema_name, table_name, rationale) values
  ('erp', 'event_outbox',
   'Infrastructure queue. Rows are written by erp.append_event() as a '
   'consequence of an event that already carries its own actor, and are '
   'consumed by workers. Attributing a queue entry to a user would be a '
   'fiction maintained by a trigger.'),
  ('erp', 'stock_balance',
   'Derived cache, maintained solely by the stock ledger trigger and guarded '
   'against direct writes by erp.guard_stock_balance(). Its provenance is the '
   'movement that produced it, which carries full attribution of its own.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp_meta.register_table('erp_meta', 'attribution_exemption', 'platform_internal',
  'Written justifications for tables that carry no principal attribution.');

select erp.apply_attribution_triggers();
select erp.assert_attribution_coverage();

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
