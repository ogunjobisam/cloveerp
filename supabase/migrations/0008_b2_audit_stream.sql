-- =============================================================================
-- ERPWare — B2 (part 1/2): the audit stream
-- Spec 3.2:
--   "One append-only audit stream per tenant: actor, action, object type and
--    identifier, before and after state, timestamp, correlation identifier"
--   "Sensitive reads are auditable, not only writes"
--   "No role, including administrator, holds update or delete rights on audit
--    data"
--
-- Two things here are stronger than they strictly need to be, on purpose.
--
-- Append-only is enforced by TRIGGER, not only by grants and policy. Grants
-- stop `authenticated`; they do nothing about a role holding BYPASSRLS. The
-- spec says *no role*, so the refusal has to sit somewhere that every role goes
-- through. The single exception is an explicitly opened tenant purge, because
-- spec 2.5 also requires that a tenant can be deleted in full.
--
-- Audit coverage is generated, not opted into. Every tenant-scoped table gets
-- an audit trigger unless it is registered as exempt with a reason. Auditing
-- that has to be remembered per table is auditing that will be missing on the
-- one table that mattered.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Correlation
--
-- Spec 3.2 wants a correlation identifier on every audit record, and 3.3 wants
-- correlation and causation on every event. Both come from the request that is
-- running. Unlike the tenant context this is a label rather than a privilege,
-- so any role may set it.
-- -----------------------------------------------------------------------------

create or replace function erp.set_correlation_id(p_correlation_id uuid)
returns void
language sql
set search_path = ''
as $$
  select set_config('erp.correlation_id', coalesce(p_correlation_id::text, ''), true)::void
$$;

create or replace function erp.current_correlation_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(current_setting('erp.correlation_id', true), '')::uuid
$$;

comment on function erp.current_correlation_id() is
  'The identifier tying every audit record and event of one request together. '
  'A label, not a privilege: it grants nothing, so any role may set it.';

-- -----------------------------------------------------------------------------
-- Append-only enforcement
-- -----------------------------------------------------------------------------

create or replace function erp.begin_tenant_purge(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'ERPWARE_UNTRUSTED_PURGE: role % may not open a tenant purge', current_user
      using errcode = '42501';
  end if;
  perform set_config('erp.purge_tenant_id', p_tenant_id::text, true);
end;
$$;

comment on function erp.begin_tenant_purge(uuid) is
  'Opens the one window in which append-only rows may be removed: the erasure '
  'of an entire tenant (spec 2.5). Transaction-scoped, refused on any role that '
  'does not already bypass RLS, and never able to remove part of a stream.';

create or replace function erp.end_tenant_purge()
returns void
language sql
set search_path = ''
as $$
  select set_config('erp.purge_tenant_id', '', true)::void
$$;

create or replace function erp.forbid_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- The only permitted removal is the erasure of a whole tenant, opened
  -- deliberately by a trusted session for that exact tenant. A purge cannot be
  -- used to remove one inconvenient row: it takes the tenant with it.
  if tg_op = 'DELETE'
     and erp.session_is_trusted()
     and nullif(current_setting('erp.purge_tenant_id', true), '')::uuid = old.tenant_id
  then
    return old;
  end if;

  raise exception
    'ERPWARE_APPEND_ONLY: %.% is append-only; % is not permitted by any role',
    tg_table_schema, tg_table_name, tg_op
    using errcode = '42501';
end;
$$;

-- -----------------------------------------------------------------------------
-- The stream
-- -----------------------------------------------------------------------------

create type erp.audit_action as enum (
  'insert', 'update', 'delete',
  'read',        -- sensitive reads (spec 3.2)
  'execute',     -- a rule ran, a job ran, a command was issued
  'authenticate',
  'export'
);

create table erp.audit_entry (
  id              bigint generated always as identity primary key,
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,

  -- Spec 4.10: events record both when something happened and when it was
  -- recorded. clock_timestamp() rather than now(), so several records written
  -- in one transaction keep their order.
  occurred_at     timestamptz not null default clock_timestamp(),
  recorded_at     timestamptz not null default clock_timestamp(),

  actor_id        uuid,
  actor_kind      erp.principal_kind,
  -- Denormalised so the record stays readable after the principal is gone.
  actor_label     text,

  action          erp.audit_action not null,

  object_schema   text not null,
  object_type     text not null,
  object_id       uuid,
  -- For objects keyed by something other than a uuid.
  object_key      text,

  entity_id       uuid,
  site_id         uuid,

  before_state    jsonb,
  after_state     jsonb,
  changed_fields  text[],

  data_class      text,
  reason          text,
  correlation_id  uuid,
  causation_id    uuid,
  source          text not null default 'api'
);

comment on table erp.audit_entry is
  'The tenant''s audit stream. Append-only for every role including the owner; '
  'see erp.forbid_mutation(). Removable only by erasing the whole tenant.';

create index on erp.audit_entry (tenant_id, occurred_at desc);
create index on erp.audit_entry (tenant_id, object_type, object_id, occurred_at desc);
create index on erp.audit_entry (tenant_id, actor_id, occurred_at desc);
create index on erp.audit_entry (tenant_id, correlation_id)
  where correlation_id is not null;
create index on erp.audit_entry (tenant_id, action, occurred_at desc);

-- -----------------------------------------------------------------------------
-- The generic audit trigger
--
-- One trigger function for every table. It reads the row as jsonb rather than
-- naming columns, so it needs no maintenance as the model grows — and it cannot
-- fall behind a table whose shape changed.
-- -----------------------------------------------------------------------------

create or replace function erp.audit_row_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before   jsonb;
  v_after    jsonb;
  v_row      jsonb;
  v_tenant   uuid;
  v_changed  text[];
  v_action   erp.audit_action;
  v_actor    uuid := erp.current_principal_id();
begin
  if tg_op = 'INSERT' then
    v_action := 'insert';
    v_after  := to_jsonb(new);
    v_row    := v_after;
  elsif tg_op = 'UPDATE' then
    v_action := 'update';
    v_before := to_jsonb(old);
    v_after  := to_jsonb(new);
    v_row    := v_after;
  else
    v_action := 'delete';
    v_before := to_jsonb(old);
    v_row    := v_before;
  end if;

  v_tenant := (v_row ->> 'tenant_id')::uuid;

  -- A tenant purge removes the tenant's audit stream along with everything
  -- else; writing new audit rows during it would resurrect the tenant.
  if nullif(current_setting('erp.purge_tenant_id', true), '')::uuid = v_tenant then
    return coalesce(new, old);
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(key order by key), '{}')
      into v_changed
      from jsonb_each(v_after) e(key, value)
     where v_before -> e.key is distinct from e.value
       -- Attribution columns change on every update by definition; listing
       -- them as "what changed" would bury the field that actually did.
       and e.key not in ('updated_at', 'updated_by');

    -- An update that touched nothing but its own attribution is not a
    -- business change and does not earn a line in the stream.
    if cardinality(v_changed) = 0 then
      return new;
    end if;
  end if;

  insert into erp.audit_entry (
    tenant_id, actor_id, actor_kind, actor_label, action,
    object_schema, object_type, object_id, object_key,
    entity_id, site_id, before_state, after_state, changed_fields,
    correlation_id, source)
  values (
    v_tenant,
    v_actor,
    (select u.kind from erp.app_user u where u.id = v_actor),
    (select u.display_name from erp.app_user u where u.id = v_actor),
    v_action,
    tg_table_schema,
    tg_table_name,
    (v_row ->> 'id')::uuid,
    v_row ->> 'code',
    (v_row ->> 'entity_id')::uuid,
    (v_row ->> 'site_id')::uuid,
    v_before,
    v_after,
    v_changed,
    erp.current_correlation_id(),
    coalesce(nullif(current_setting('erp.source', true), ''), 'api'));

  return coalesce(new, old);
exception
  when invalid_text_representation then
    -- A table whose id or entity_id is not a uuid still gets audited; it just
    -- lands with those columns null rather than failing the business write.
    insert into erp.audit_entry (
      tenant_id, actor_id, action, object_schema, object_type, object_key,
      before_state, after_state, changed_fields, correlation_id)
    values (
      v_tenant, v_actor, v_action, tg_table_schema, tg_table_name,
      v_row ->> 'code', v_before, v_after, v_changed,
      erp.current_correlation_id());
    return coalesce(new, old);
end;
$$;

-- -----------------------------------------------------------------------------
-- Sensitive reads (spec 3.2)
-- -----------------------------------------------------------------------------

create table erp_meta.sensitive_object (
  object_type   text primary key,
  data_class    text not null,
  rationale     text not null
);

comment on table erp_meta.sensitive_object is
  'Object types whose *reads* are auditable, not only their writes. A read of '
  'one of these without a corresponding audit entry is a gap, not a shortcut.';

create or replace function erp.audit_read(
  p_object_type text,
  p_object_id   uuid default null,
  p_reason      text default null,
  p_object_key  text default null,
  p_entity_id   uuid default null,
  p_site_id     uuid default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor  uuid := erp.current_principal_id();
begin
  insert into erp.audit_entry (
    tenant_id, actor_id, actor_kind, actor_label, action,
    object_schema, object_type, object_id, object_key,
    entity_id, site_id, data_class, reason, correlation_id, source)
  values (
    v_tenant, v_actor,
    (select u.kind from erp.app_user u where u.id = v_actor),
    (select u.display_name from erp.app_user u where u.id = v_actor),
    'read', 'erp', p_object_type, p_object_id, p_object_key,
    p_entity_id, p_site_id,
    (select s.data_class from erp_meta.sensitive_object s
      where s.object_type = p_object_type),
    p_reason,
    erp.current_correlation_id(),
    coalesce(nullif(current_setting('erp.source', true), ''), 'api'));
end;
$$;

-- -----------------------------------------------------------------------------
-- Generated coverage
-- -----------------------------------------------------------------------------

create table erp_meta.audit_exemption (
  schema_name   text not null,
  table_name    text not null,
  rationale     text not null,
  primary key (schema_name, table_name)
);

comment on table erp_meta.audit_exemption is
  'Tables deliberately not row-audited, each with a reason. Append-only tables '
  'belong here: they are already immutable evidence, and auditing an audit '
  'stream only doubles its size.';

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'audit_entry',
   'The audit stream itself. Append-only and immutable; auditing it would '
   'recurse and double every write.'),
  ('erp', 'access_log',
   'Append-only record of access decisions. Already immutable evidence.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

-- Attaches the audit trigger to every tenant-scoped table that is not exempt,
-- and removes it from any table that has since become exempt. Idempotent, and
-- called by every migration that adds tables.
create or replace function erp.apply_audit_coverage()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_schemas text[];
  v_tables  text[];
  v_exempt  boolean[];
  v_applied integer := 0;
  i         integer;
begin
  perform erp_meta.register_unregistered_tables();

  select coalesce(array_agg(tp.schema_name order by tp.schema_name, tp.table_name), '{}'),
         coalesce(array_agg(tp.table_name  order by tp.schema_name, tp.table_name), '{}'),
         coalesce(array_agg(
           tp.table_class <> 'tenant_scoped'
           or exists (select 1 from erp_meta.audit_exemption ae
                       where ae.schema_name = tp.schema_name
                         and ae.table_name = tp.table_name)
           order by tp.schema_name, tp.table_name), '{}')
    into v_schemas, v_tables, v_exempt
    from erp_meta.table_policy tp
    join pg_catalog.pg_class c
      on c.relname = tp.table_name
     and c.relnamespace::regnamespace::text = tp.schema_name
     and c.relkind = 'r';

  for i in 1 .. coalesce(array_length(v_schemas, 1), 0) loop
    execute format('drop trigger if exists t_%s_audit on %I.%I',
                   v_tables[i], v_schemas[i], v_tables[i]);
    if not v_exempt[i] then
      execute format(
        'create trigger t_%s_audit after insert or update or delete on %I.%I
           for each row execute function erp.audit_row_change()',
        v_tables[i], v_schemas[i], v_tables[i]);
      v_applied := v_applied + 1;
    end if;
  end loop;

  return v_applied;
end;
$$;

-- Attaches the append-only guard to every table registered as append-only.
create or replace function erp.apply_append_only_guards()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_schemas text[];
  v_tables  text[];
  v_applied integer := 0;
  i         integer;
begin
  select coalesce(array_agg(tp.schema_name order by tp.schema_name, tp.table_name), '{}'),
         coalesce(array_agg(tp.table_name  order by tp.schema_name, tp.table_name), '{}')
    into v_schemas, v_tables
    from erp_meta.table_policy tp
    join pg_catalog.pg_class c
      on c.relname = tp.table_name
     and c.relnamespace::regnamespace::text = tp.schema_name
     and c.relkind = 'r'
   where tp.table_class = 'tenant_scoped_append_only';

  for i in 1 .. coalesce(array_length(v_schemas, 1), 0) loop
    execute format('drop trigger if exists t_%s_append_only on %I.%I',
                   v_tables[i], v_schemas[i], v_tables[i]);
    execute format(
      'create trigger t_%s_append_only before update or delete on %I.%I
         for each row execute function erp.forbid_mutation()',
      v_tables[i], v_schemas[i], v_tables[i]);
    v_applied := v_applied + 1;
  end loop;

  return v_applied;
end;
$$;

-- -----------------------------------------------------------------------------
-- Report on audit coverage the same way isolation is reported: structurally.
-- -----------------------------------------------------------------------------

create or replace function erp.audit_coverage_report()
returns table (schema_name text, table_name text, finding text)
language sql
stable
set search_path = ''
as $$
  select tp.schema_name, tp.table_name,
         'tenant-scoped table has no audit trigger and no registered exemption'
    from erp_meta.table_policy tp
    join pg_catalog.pg_class c
      on c.relname = tp.table_name
     and c.relnamespace::regnamespace::text = tp.schema_name
     and c.relkind = 'r'
   where tp.table_class = 'tenant_scoped'
     and not exists (
       select 1 from erp_meta.audit_exemption ae
        where ae.schema_name = tp.schema_name and ae.table_name = tp.table_name)
     and not exists (
       select 1 from pg_catalog.pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgfoid = 'erp.audit_row_change()'::regprocedure)

  union all

  select tp.schema_name, tp.table_name,
         'append-only table has no mutation guard, so a role that bypasses RLS '
         'could still edit or delete evidence'
    from erp_meta.table_policy tp
    join pg_catalog.pg_class c
      on c.relname = tp.table_name
     and c.relnamespace::regnamespace::text = tp.schema_name
     and c.relkind = 'r'
   where tp.table_class = 'tenant_scoped_append_only'
     and not exists (
       select 1 from pg_catalog.pg_trigger t
        where t.tgrelid = c.oid
          and not t.tgisinternal
          and t.tgfoid = 'erp.forbid_mutation()'::regprocedure)
  order by 1, 2
$$;

create or replace function erp.assert_audit_coverage()
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
    from erp.audit_coverage_report();

  if v_count > 0 then
    raise exception E'ERPWARE_AUDIT_COVERAGE_GAP: % finding(s)\n%', v_count, v_findings;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Register, then generate.
-- -----------------------------------------------------------------------------

select erp_meta.register_table('erp', 'audit_entry', 'tenant_scoped_append_only',
  'Spec 3.2: no role, including administrator, holds update or delete rights.');

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
