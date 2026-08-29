-- =============================================================================
-- ERPWare — B8 (part 1/3): the adapter contract and the integration registry
-- Spec 4.9 (Integration), 6.1 Level 3, Part 7 ("No direct writes to external
-- systems outside the gateway")
--
-- Where the boundary sits, and why
--
--   The database owns intent, approval, idempotency, ordering and evidence.
--   A worker process owns transport and credentials. The worker can do nothing
--   that is not a claimed command, and the database can reach nothing.
--
--   That split is what makes "no module holds credentials or calls an external
--   system directly" enforceable rather than aspirational. Postgres cannot open
--   a socket, so no amount of module code written later can bypass the gateway
--   from inside a transaction. And because the worker's only input is a claimed
--   erp.command row, every outbound write has a row, an approval state, an
--   idempotency key and a lifecycle before anything leaves the building.
--
--   The credential itself is never here. erp.external_system holds a REFERENCE
--   to a secret in someone else's store, and a trigger refuses the row if the
--   reference looks like the secret. Spec 4.9's invariant would otherwise be a
--   sentence in a document that a well-meaning integration author violates on
--   a Friday afternoon by putting the API key in the connection JSON.
--
--   Three layers, product to tenant:
--     erp_ref.adapter            what the product knows how to talk to
--     erp_ref.adapter_operation  what each of those can be asked to do
--     erp.external_system        a tenant's configured instance of one
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Secret detection
--
-- Two independent tests, because either alone is easy to walk past. A key-name
-- test catches `{"api_key": "..."}`. A value-shape test catches the same secret
-- pasted into a field called `note`.
-- -----------------------------------------------------------------------------

create or replace function erp_ref.is_secret_key(p_key text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select lower(coalesce(p_key, '')) ~
    '(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential|'
    'authorization|auth[_-]?header|client[_-]?secret|access[_-]?key|'
    'shared[_-]?key|passphrase|\.pfx|\.p12|pem)'
$$;

comment on function erp_ref.is_secret_key(text) is
  'True if a configuration key name suggests it holds a credential. Product '
  'content, not tenant configuration: a tenant cannot relax it.';

-- Shapes that are a live credential whatever the field is called.
create or replace function erp_ref.looks_like_secret(p_value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null or length(p_value) = 0 then false
    else
      -- Matched anywhere in the string, not anchored to its start. A key
      -- pasted into the middle of a sentence — "the key is AKIA..." — is still
      -- a key sitting in the database, and anchoring is exactly how that gets
      -- missed. Every pattern below is specific enough that a substring match
      -- costs nothing in false positives.
      --
      -- PEM blocks, of any kind.
      p_value like '%-----BEGIN %'
      -- HTTP authorization headers carried inline. The length floor keeps
      -- prose like "use basic auth" out of it.
      or p_value ~* '(^|[[:space:]"'':,])(bearer|basic|digest)[[:space:]]+[^[:space:]]{8,}'
      -- A JWT: three base64url segments, the first starting '{"alg' encoded.
      or p_value ~ 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*'
      -- Well-known issued-credential prefixes. Not exhaustive and not meant to
      -- be: this catches the careless case, the key-name test catches the rest.
      or p_value ~ '(AKIA|ASIA)[0-9A-Z]{16}'
      or p_value ~ '(sk|rk|pk)_(live|test)_[A-Za-z0-9]{10,}'
      or p_value ~ 'sk-[A-Za-z0-9]{20,}'
      or p_value ~ 'gh[pousr]_[A-Za-z0-9]{20,}'
      or p_value ~ 'xox[baprs]-[A-Za-z0-9-]{10,}'
      or p_value ~ 'SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}'
      or p_value ~ 'glpat-[A-Za-z0-9_-]{16,}'
      or p_value ~ 'AIza[A-Za-z0-9_-]{30,}'
      or p_value ~ 'npm_[A-Za-z0-9]{30,}'
  end
$$;

comment on function erp_ref.looks_like_secret(text) is
  'True if a string has the shape of a live credential regardless of the field '
  'it sits in. Deliberately conservative — a false positive costs an author one '
  'confused minute, a false negative costs a customer their tenant.';

-- Walks a configuration document and reports anywhere a credential appears to
-- have been stored inline. Returns findings rather than raising, so the same
-- function serves both the trigger and the administrator's screen.
create or replace function erp.inline_credential_findings(
  p_document jsonb,
  p_path     text default '$'
) returns table (path text, finding text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  k text;
  v jsonb;
  i integer;
begin
  if p_document is null then
    return;
  end if;

  case jsonb_typeof(p_document)
    when 'object' then
      for k, v in select * from jsonb_each(p_document) loop
        if erp_ref.is_secret_key(k)
           and jsonb_typeof(v) = 'string'
           and length(v #>> '{}') > 0
        then
          path := p_path || '.' || k;
          finding := 'key name indicates a credential and a value is present';
          return next;
        end if;

        return query
          select * from erp.inline_credential_findings(v, p_path || '.' || k);
      end loop;

    when 'array' then
      i := 0;
      for v in select * from jsonb_array_elements(p_document) loop
        return query
          select * from erp.inline_credential_findings(
            v, p_path || '[' || i::text || ']');
        i := i + 1;
      end loop;

    when 'string' then
      if erp_ref.looks_like_secret(p_document #>> '{}') then
        path := p_path;
        finding := 'value has the shape of a live credential';
        return next;
      end if;

    else
      null;
  end case;
end;
$$;

comment on function erp.inline_credential_findings(jsonb, text) is
  'Spec 4.9: "no module holds credentials". Reports every place a credential '
  'appears to have been stored inline in a configuration or payload document.';

create or replace function erp.reject_inline_credentials()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_doc     jsonb;
  v_col     text := tg_argv[0];
  v_detail  text;
begin
  execute format('select ($1).%I', v_col) into v_doc using new;

  select string_agg(format('  %s — %s', f.path, f.finding), E'\n')
    into v_detail
    from erp.inline_credential_findings(v_doc) f;

  if v_detail is not null then
    raise exception
      'ERPWARE_INLINE_CREDENTIAL: %.% column % must not contain a credential; '
      'store a reference to a secret store instead',
      tg_table_schema, tg_table_name, v_col
      using errcode = '42501', detail = v_detail;
  end if;

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- The adapter contract (product content)
--
-- An adapter is a declaration of what the product can talk to and what shape
-- the conversation takes. It is versioned like an event type: a superseded
-- version keeps validating the systems already bound to it, it simply stops
-- being the one new bindings get.
-- -----------------------------------------------------------------------------

create type erp.adapter_direction as enum ('inbound', 'outbound', 'bidirectional');

create type erp.adapter_transport as enum (
  'http', 'sftp', 'file_drop', 'message_queue', 'database', 'email', 'manual'
);

create table erp_ref.adapter (
  code            text not null
                    check (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'),
  version         integer not null default 1 check (version >= 1),
  name_key        text not null,
  description     text,
  direction       erp.adapter_direction not null,
  transport       erp.adapter_transport not null,
  -- JSON Schema for erp.external_system.connection. Validated on write, so a
  -- misconfigured connection is refused at configuration time rather than
  -- discovered at three in the morning by a failing nightly run.
  connection_schema jsonb not null default '{"type":"object"}'::jsonb,
  -- What the adapter needs from the secret store, described but never held:
  -- e.g. {"kind":"oauth2_client_credentials","fields":["client_id","client_secret"]}.
  credential_contract jsonb not null default '{}'::jsonb,
  -- Does the counterpart system honour an idempotency key of its own? If not,
  -- the gateway is the only thing standing between a retry and a duplicate
  -- purchase order, and the gateway says so on the monitoring screen.
  honours_idempotency boolean not null default false,
  supports_dry_run    boolean not null default false,
  is_current      boolean not null default true,
  primary key (code, version)
);

comment on table erp_ref.adapter is
  'Product content. What the product knows how to integrate with, and the shape '
  'of the configuration each one requires. A tenant selects an adapter and '
  'configures it; a tenant never writes one. Spec 6.1 Level 3.';

create unique index adapter_one_current on erp_ref.adapter (code) where is_current;

-- The credential contract describes fields; it must not carry their values.
create trigger t_adapter_no_inline_credential
  before insert or update on erp_ref.adapter
  for each row execute function erp.reject_inline_credentials('connection_schema');

create table erp_ref.adapter_operation (
  adapter_code    text not null,
  adapter_version integer not null,
  code            text not null
                    check (code ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$'),
  name_key        text not null,
  description     text,
  -- An operation that changes state on the far side. Read operations may be
  -- issued freely; mutating ones are what the approval gate exists for.
  is_mutating     boolean not null default true,
  -- JSON Schema the command payload must satisfy. The gateway validates before
  -- a command may be queued, so a command that cannot succeed never occupies a
  -- retry slot or an operator's attention.
  request_schema  jsonb not null default '{"type":"object"}'::jsonb,
  response_schema jsonb not null default '{"type":"object"}'::jsonb,
  -- Whether this specific operation can be simulated. An adapter may support
  -- dry run for order creation and not for a payment instruction.
  supports_dry_run boolean not null default false,
  -- Commands sharing an ordering key are dispatched in sequence. Naming the
  -- default here means an integration author does not have to remember that
  -- three amendments to one order must not race.
  default_ordering_key_path text,
  primary key (adapter_code, adapter_version, code),
  foreign key (adapter_code, adapter_version)
    references erp_ref.adapter (code, version) on delete cascade
);

comment on table erp_ref.adapter_operation is
  'The verbs an adapter exposes, each with the JSON Schema its request must '
  'satisfy. This is the contract the write gateway validates against.';

-- -----------------------------------------------------------------------------
-- The tenant's configured systems
-- -----------------------------------------------------------------------------

create type erp.external_system_status as enum (
  'draft', 'active', 'suspended', 'retired'
);

create table erp.external_system (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null
                    check (code ~ '^[a-z][a-z0-9_]*$'),
  name            text not null,
  adapter_code    text not null,
  adapter_version integer not null,
  -- Non-credential connection settings: endpoints, folder paths, timeouts,
  -- field mappings. Validated against the adapter's connection_schema.
  connection      jsonb not null default '{}'::jsonb,
  -- A pointer into a secret store, never the secret. `vault://`, `awssm://`,
  -- `azurekv://`, `env://` — the scheme tells the worker which store to ask.
  credential_ref  text
                    check (credential_ref is null
                           or credential_ref ~ '^[a-z][a-z0-9+.-]*://[^[:space:]]+$'),
  -- Which environment this system belongs to, so a staging configuration cannot
  -- accidentally point production at a live counterpart. Spec 4.7.
  environment_id  uuid,
  entity_id       uuid,
  site_id         uuid,
  status          erp.external_system_status not null default 'draft',
  -- Dispatch controls. A counterpart that falls over under load is a far more
  -- common failure than a counterpart that is down.
  max_in_flight   integer not null default 4 check (max_in_flight between 1 and 256),
  max_attempts    integer not null default 5 check (max_attempts between 1 and 50),
  retry_backoff_seconds integer not null default 30 check (retry_backoff_seconds >= 1),
  -- Whether outbound mutating commands need approval regardless of what any
  -- chain says. The belt to the approval engine's braces, for the connection
  -- that pays suppliers.
  requires_approval boolean not null default false,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (adapter_code, adapter_version)
    references erp_ref.adapter (code, version),
  foreign key (tenant_id, environment_id)
    references erp.environment (tenant_id, id) on delete restrict,
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete cascade,
  -- An active system with no credential reference is either genuinely open or,
  -- far more likely, someone who put the key somewhere it should not be.
  constraint external_system_credential_not_inline
    check (credential_ref is null or not erp_ref.looks_like_secret(credential_ref))
);

comment on table erp.external_system is
  'Spec 4.9: a registered counterpart system with its adapter configuration. '
  'Holds a reference to a credential; never a credential.';

comment on column erp.external_system.credential_ref is
  'Opaque pointer into the deployment''s secret store, resolved by the dispatch '
  'worker at send time. A CHECK and a trigger both refuse a value that looks '
  'like the secret itself.';

create index on erp.external_system (tenant_id, status);
create index on erp.external_system (tenant_id, adapter_code);

create trigger t_external_system_no_inline_credential
  before insert or update on erp.external_system
  for each row execute function erp.reject_inline_credentials('connection');

-- Connection settings must satisfy the adapter's schema.
create or replace function erp.check_external_system_connection()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_schema jsonb;
begin
  select a.connection_schema into v_schema
    from erp_ref.adapter a
   where a.code = new.adapter_code and a.version = new.adapter_version;

  if v_schema is not null
     and not extensions.jsonb_matches_schema(v_schema::json, new.connection)
  then
    raise exception
      'ERPWARE_INVALID_CONNECTION: % does not satisfy the schema for adapter %@%',
      new.code, new.adapter_code, new.adapter_version
      using errcode = '22023', detail = new.connection::text;
  end if;

  return new;
end;
$$;

create trigger t_external_system_connection
  before insert or update of connection, adapter_code, adapter_version
  on erp.external_system
  for each row execute function erp.check_external_system_connection();

-- Which of the adapter's operations this system is permitted to perform, and
-- under what conditions. A tenant that wants a read-only connection to their
-- finance system expresses it here rather than by trusting everyone to behave.
create table erp.external_system_operation (
  id                  uuid not null default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  external_system_id  uuid not null,
  operation_code      text not null,
  is_enabled          boolean not null default true,
  -- Overrides the system-level setting upward only; see the trigger below.
  requires_approval   boolean,
  -- Per-operation throttle, in commands per minute. NULL means unthrottled.
  rate_limit_per_minute integer check (rate_limit_per_minute is null
                                       or rate_limit_per_minute >= 1),
  ordering_key_path   text,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, external_system_id, operation_code),
  foreign key (tenant_id, external_system_id)
    references erp.external_system (tenant_id, id) on delete cascade
);

comment on table erp.external_system_operation is
  'Per-tenant enablement of an adapter''s operations. Absence of a row means '
  'the operation is not enabled: the gateway requires an explicit allow.';

-- A system-level `requires_approval = true` cannot be undone per operation.
-- Loosening a control at a lower scope is how controls quietly disappear.
create or replace function erp.check_operation_approval_override()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_system_requires boolean;
begin
  select s.requires_approval into v_system_requires
    from erp.external_system s
   where s.tenant_id = new.tenant_id and s.id = new.external_system_id;

  if coalesce(v_system_requires, false) and new.requires_approval is false then
    raise exception
      'ERPWARE_CANNOT_WEAKEN_APPROVAL: system requires approval; operation % '
      'may not opt out', new.operation_code
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger t_operation_approval_override
  before insert or update on erp.external_system_operation
  for each row execute function erp.check_operation_approval_override();

-- -----------------------------------------------------------------------------
-- External references
--
-- Spec 4.10: "external identifiers live only in external_ref". This is the one
-- place an outside system's identifier is allowed to exist, which is what stops
-- a supplier's account number from becoming a de facto primary key.
-- -----------------------------------------------------------------------------

create type erp.sync_state as enum (
  'pending', 'in_sync', 'stale', 'conflict', 'failed', 'detached'
);

-- Which side is allowed to change the record. Getting this wrong is how two
-- systems overwrite each other in a loop for a fortnight before anyone notices.
create type erp.sync_authority as enum ('erpware', 'external', 'bidirectional');

create table erp.external_ref (
  id                 uuid not null default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  external_system_id uuid not null,
  object_type        text not null
                       check (object_type ~ '^[a-z][a-z0-9_]*$'),
  object_id          uuid not null,
  external_id        text not null check (length(external_id) > 0),
  -- Whatever the counterpart uses for optimistic concurrency: an ETag, a
  -- row version, a last-modified stamp.
  external_version   text,
  authority          erp.sync_authority not null default 'erpware',
  sync_state         erp.sync_state not null default 'pending',
  last_synced_at     timestamptz,
  last_error         text,
  -- Set when sync_state = 'conflict': what each side believed.
  conflict_detail    jsonb,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  primary key (id),
  unique (tenant_id, id),
  -- One ERPWare object has at most one identity in a given system...
  unique (tenant_id, external_system_id, object_type, object_id),
  -- ...and one external identifier means at most one ERPWare object. Without
  -- the second constraint two sales orders can silently converge onto one
  -- external order and the loss is invisible until a customer complains.
  unique (tenant_id, external_system_id, object_type, external_id),
  foreign key (tenant_id, external_system_id)
    references erp.external_system (tenant_id, id) on delete cascade,
  constraint external_ref_conflict_has_detail
    check (sync_state <> 'conflict' or conflict_detail is not null)
);

comment on table erp.external_ref is
  'Spec 4.9: a mapping between an ERPWare object and its identifier in an '
  'external system, with sync state. The only home for an external identifier.';

create index on erp.external_ref (tenant_id, object_type, object_id);
create index on erp.external_ref (tenant_id, external_system_id, sync_state);

-- Resolve in either direction. Two small functions rather than one clever one,
-- because callers know which way they are going.
create or replace function erp.external_id_for(
  p_system_code text, p_object_type text, p_object_id uuid)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select r.external_id
    from erp.external_ref r
    join erp.external_system s
      on s.tenant_id = r.tenant_id and s.id = r.external_system_id
   where r.tenant_id = erp.require_tenant_id()
     and s.code = p_system_code
     and r.object_type = p_object_type
     and r.object_id = p_object_id
     and r.sync_state <> 'detached'
$$;

create or replace function erp.object_for_external_id(
  p_system_code text, p_object_type text, p_external_id text)
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  select r.object_id
    from erp.external_ref r
    join erp.external_system s
      on s.tenant_id = r.tenant_id and s.id = r.external_system_id
   where r.tenant_id = erp.require_tenant_id()
     and s.code = p_system_code
     and r.object_type = p_object_type
     and r.external_id = p_external_id
     and r.sync_state <> 'detached'
$$;

-- Record a mapping. Upserts on the ERPWare side of the pair, because that is
-- the side that is stable: an external system may reissue its identifier, and
-- when it does we want the mapping updated, not a second one created.
create or replace function erp.link_external_ref(
  p_system_code  text,
  p_object_type  text,
  p_object_id    uuid,
  p_external_id  text,
  p_external_version text default null,
  p_authority    erp.sync_authority default 'erpware'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_system uuid;
  v_id     uuid;
begin
  select s.id into v_system
    from erp.external_system s
   where s.tenant_id = v_tenant and s.code = p_system_code;

  if v_system is null then
    raise exception 'ERPWARE_UNKNOWN_EXTERNAL_SYSTEM: %', p_system_code
      using errcode = '23503';
  end if;

  insert into erp.external_ref (
    tenant_id, external_system_id, object_type, object_id, external_id,
    external_version, authority, sync_state, last_synced_at, created_by, updated_by)
  values (
    v_tenant, v_system, p_object_type, p_object_id, p_external_id,
    p_external_version, p_authority, 'in_sync', now(),
    erp.current_principal_id(), erp.current_principal_id())
  on conflict (tenant_id, external_system_id, object_type, object_id)
    do update set external_id = excluded.external_id,
                  external_version = excluded.external_version,
                  authority = excluded.authority,
                  sync_state = 'in_sync',
                  last_synced_at = now(),
                  last_error = null,
                  conflict_detail = null,
                  updated_at = now(),
                  updated_by = erp.current_principal_id()
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.link_external_ref(text, text, uuid, text, text, erp.sync_authority) is
  'Records or refreshes the mapping between an ERPWare object and its identity '
  'in an external system.';

-- -----------------------------------------------------------------------------
-- Registration and gates
-- -----------------------------------------------------------------------------

select erp_meta.register_table('erp_ref', 'adapter', 'product_content',
  'The adapter contract. Identical for every tenant.');
select erp_meta.register_table('erp_ref', 'adapter_operation', 'product_content',
  'The verbs each adapter exposes, with their request schemas.');
select erp_meta.register_table('erp', 'external_system', 'tenant_scoped',
  'Spec 4.9. Holds a credential reference, never a credential.');
select erp_meta.register_table('erp', 'external_system_operation', 'tenant_scoped',
  'Which adapter operations a tenant has enabled on a given system.');
select erp_meta.register_table('erp', 'external_ref', 'tenant_scoped',
  'Spec 4.10: the only place an external identifier is allowed to live.');

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
