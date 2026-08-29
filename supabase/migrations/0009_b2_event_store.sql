-- =============================================================================
-- ERPWare — B2 (part 2/2): the event store, outbox, cursors and replay
-- Spec 3.3:
--   "Append-only event store per tenant, with an outbox per module for reliable
--    publication"
--   "Event envelope: identifier, versioned type, occurred-at, recorded-at,
--    tenant, entity, site, aggregate type and identifier, actor, correlation
--    and causation identifiers, schema-validated payload, source"
--   "Consumers hold their own cursors; replay from any point is a supported
--    operation"
--   "Events are past-tense facts, never commands, and are immutable once
--    recorded"
--
-- Three of those four clauses are enforced here rather than described:
--
--   schema-validated  pg_jsonschema validates every payload against the schema
--                     registered for that event type and version. An event
--                     whose payload does not match is refused, not stored and
--                     discovered later.
--
--   past-tense facts  the type registry refuses a code whose verb is not past
--                     tense. "Commands, never events" is the single most common
--                     way an event store rots into a job queue, and a naming
--                     rule catches it at the point of definition.
--
--   immutable         erp.event is registered append-only, so it inherits the
--                     B2 mutation guard that refuses UPDATE and DELETE to every
--                     role.
--
-- The fourth, replay, is the subtle one. See the note on the read watermark.
-- =============================================================================

create extension if not exists pg_jsonschema with schema extensions;

-- -----------------------------------------------------------------------------
-- The event type registry (product content)
--
-- Event types ship with the release: two tenants running the same binary emit
-- the same events. What differs per tenant is which of them are subscribed to,
-- and what the rules do in response.
-- -----------------------------------------------------------------------------

-- Past tense, checked. Not a style preference: an event store that accepts
-- "order.approve" alongside "order.approved" has become a command queue, and
-- everything downstream that assumed facts is now wrong.
create or replace function erp_ref.is_past_tense(p_code text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_code !~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$' then false
    when split_part(p_code, '.', 2) like '%ed' then true
    else split_part(p_code, '.', 2) in (
      -- Irregular past forms and past participles that do not end in -ed.
      'sent', 'built', 'split', 'lost', 'found', 'begun', 'withdrawn',
      'written', 'taken', 'given', 'made', 'met', 'held', 'put', 'set',
      'shut', 'cut', 'read', 'left', 'kept', 'drawn', 'shown', 'known',
      'grown', 'thrown', 'broken', 'chosen', 'frozen', 'risen', 'fallen',
      'run', 'spent', 'paid', 'sold', 'bought', 'brought', 'caught',
      'taught', 'thought', 'told', 'won', 'gone', 'done', 'seen', 'become')
  end
$$;

comment on function erp_ref.is_past_tense(text) is
  'Guards the event registry against command-shaped names. Events are facts '
  'about what happened; a name in the imperative is a job queue wearing an '
  'event store''s clothes.';

create table erp_ref.event_type (
  code            text not null
                    check (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  version         integer not null default 1 check (version >= 1),
  aggregate_type  text not null,
  module_code     text references erp_ref.module(code),
  name_key        text not null,
  description     text,
  -- JSON Schema. Every payload of this type and version is validated against it
  -- before the event is allowed into the store.
  payload_schema  jsonb not null default '{"type":"object"}'::jsonb,
  -- A superseded version still validates its own historical events; it simply
  -- stops being the default for new ones.
  is_current      boolean not null default true,
  primary key (code, version),
  constraint event_type_is_past_tense check (erp_ref.is_past_tense(code))
);

comment on table erp_ref.event_type is
  'Product content. The vocabulary of facts the product can record, versioned, '
  'each with the JSON Schema its payload must satisfy.';

create unique index event_type_one_current
  on erp_ref.event_type (code) where is_current;

-- -----------------------------------------------------------------------------
-- The store
-- -----------------------------------------------------------------------------

create table erp.event (
  -- Envelope: identifier
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,

  -- Total order for replay. See the watermark note below for why a bare
  -- sequence is not, on its own, a safe thing to page through.
  global_seq        bigint generated always as identity,
  xact_id           xid8 not null default pg_current_xact_id(),

  -- Envelope: versioned type
  event_type        text not null,
  event_version     integer not null,

  -- Envelope: occurred-at and recorded-at (spec 4.10 — when it happened, and
  -- when we learned of it; they are not the same and backdating is legitimate)
  occurred_at       timestamptz not null default clock_timestamp(),
  recorded_at       timestamptz not null default clock_timestamp(),

  -- Envelope: entity and site
  entity_id         uuid,
  site_id           uuid,

  -- Envelope: aggregate type and identifier
  aggregate_type    text not null,
  aggregate_id      uuid not null,
  aggregate_version integer not null check (aggregate_version >= 1),

  -- Envelope: actor
  actor_id          uuid,
  actor_kind        erp.principal_kind,
  actor_label       text,

  -- Envelope: correlation and causation
  correlation_id    uuid,
  causation_id      uuid,

  -- Envelope: payload (schema-validated by trigger) and source
  payload           jsonb not null default '{}'::jsonb,
  source            text not null default 'api',

  foreign key (event_type, event_version)
    references erp_ref.event_type (code, version),

  -- One version per aggregate: gives optimistic concurrency for free, and makes
  -- a gap in an aggregate's history detectable rather than invisible.
  constraint event_aggregate_version_unique
    unique (tenant_id, aggregate_type, aggregate_id, aggregate_version)
);

comment on table erp.event is
  'The tenant''s event store. Append-only for every role; events are facts and '
  'facts are not edited. A correction is a further event, never an update.';

create index on erp.event (tenant_id, global_seq);
create index on erp.event (tenant_id, aggregate_type, aggregate_id, aggregate_version);
create index on erp.event (tenant_id, event_type, occurred_at desc);
create index on erp.event (tenant_id, correlation_id) where correlation_id is not null;
create index on erp.event (tenant_id, occurred_at desc);
create index on erp.event using gin (payload jsonb_path_ops);

-- -----------------------------------------------------------------------------
-- Payload validation
-- -----------------------------------------------------------------------------

create or replace function erp.validate_event_payload()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_schema jsonb;
  v_aggregate text;
begin
  select et.payload_schema, et.aggregate_type
    into v_schema, v_aggregate
    from erp_ref.event_type et
   where et.code = new.event_type and et.version = new.event_version;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_EVENT_TYPE: % v%', new.event_type, new.event_version
      using errcode = '23503';
  end if;

  if new.aggregate_type is distinct from v_aggregate then
    raise exception
      'ERPWARE_EVENT_AGGREGATE_MISMATCH: % v% is declared against aggregate %, not %',
      new.event_type, new.event_version, v_aggregate, new.aggregate_type
      using errcode = '23514';
  end if;

  -- pg_jsonschema takes the schema as `json`, the instance as `jsonb`.
  if not extensions.jsonb_matches_schema(v_schema::json, new.payload) then
    raise exception
      'ERPWARE_EVENT_PAYLOAD_INVALID: payload does not satisfy the schema for % v%',
      new.event_type, new.event_version
      using errcode = '23514',
            detail = new.payload::text;
  end if;

  return new;
end;
$$;

create trigger t_event_validate
  before insert on erp.event
  for each row execute function erp.validate_event_payload();

-- -----------------------------------------------------------------------------
-- Appending
--
-- The single write path. Resolves the current type version, assigns the next
-- aggregate version, and stamps the envelope from session context so that a
-- caller cannot forge an actor or a tenant.
-- -----------------------------------------------------------------------------

create or replace function erp.append_event(
  p_event_type       text,
  p_aggregate_type   text,
  p_aggregate_id     uuid,
  p_payload          jsonb default '{}'::jsonb,
  p_entity_id        uuid default null,
  p_site_id          uuid default null,
  p_occurred_at      timestamptz default null,
  p_expected_version integer default null,
  p_event_version    integer default null,
  p_causation_id     uuid default null,
  p_source           text default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_actor    uuid := erp.current_principal_id();
  v_version  integer;
  v_next     integer;
  v_current  integer;
  v_id       uuid;
begin
  v_version := coalesce(
    p_event_version,
    (select et.version from erp_ref.event_type et
      where et.code = p_event_type and et.is_current));

  if v_version is null then
    raise exception 'ERPWARE_UNKNOWN_EVENT_TYPE: % has no current version', p_event_type
      using errcode = '23503';
  end if;

  -- Serialise appends to this aggregate. Without it two concurrent writers
  -- both read version N and both try to write N+1; one gets a unique
  -- violation, which is safe but useless as a concurrency story.
  perform pg_advisory_xact_lock(
    hashtext(v_tenant::text || ':' || p_aggregate_type || ':' || p_aggregate_id::text));

  select coalesce(max(e.aggregate_version), 0)
    into v_current
    from erp.event e
   where e.tenant_id = v_tenant
     and e.aggregate_type = p_aggregate_type
     and e.aggregate_id = p_aggregate_id;

  -- Optimistic concurrency: the caller states the version it read, and the
  -- append is refused if the world moved under it.
  if p_expected_version is not null and p_expected_version <> v_current then
    raise exception
      'ERPWARE_EVENT_CONCURRENCY: % % is at version %, caller expected %',
      p_aggregate_type, p_aggregate_id, v_current, p_expected_version
      using errcode = '40001';
  end if;

  v_next := v_current + 1;

  insert into erp.event (
    tenant_id, event_type, event_version, occurred_at, recorded_at,
    entity_id, site_id, aggregate_type, aggregate_id, aggregate_version,
    actor_id, actor_kind, actor_label, correlation_id, causation_id,
    payload, source)
  values (
    v_tenant, p_event_type, v_version,
    coalesce(p_occurred_at, clock_timestamp()), clock_timestamp(),
    p_entity_id, p_site_id, p_aggregate_type, p_aggregate_id, v_next,
    v_actor,
    (select u.kind from erp.app_user u where u.id = v_actor),
    (select u.display_name from erp.app_user u where u.id = v_actor),
    erp.current_correlation_id(), p_causation_id,
    p_payload,
    coalesce(p_source, nullif(current_setting('erp.source', true), ''), 'api'))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.append_event is
  'The single write path into the event store. Stamps tenant and actor from '
  'session context rather than from arguments, so neither can be forged.';

-- -----------------------------------------------------------------------------
-- Subscriptions and the outbox
--
-- Spec 3.3 asks for "an outbox per module for reliable publication". The outbox
-- row is written in the same transaction as the event, so a published event
-- that never happened is impossible, and an event that happened but was never
-- queued is impossible. Delivery is then a separate, retryable concern.
-- -----------------------------------------------------------------------------

create table erp.event_subscription (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  consumer_code   text not null,
  -- SQL LIKE pattern over the event type, e.g. 'stock.%' or 'order.approved'.
  event_pattern   text not null default '%',
  module_code     text references erp_ref.module(code),
  description     text,
  max_attempts    smallint not null default 8 check (max_attempts between 1 and 64),
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, consumer_code, event_pattern)
);

create type erp.outbox_status as enum (
  'pending', 'in_flight', 'published', 'failed', 'dead'
);

create table erp.event_outbox (
  id              bigint generated always as identity primary key,
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  event_id        uuid not null references erp.event(id) on delete cascade,
  consumer_code   text not null,
  status          erp.outbox_status not null default 'pending',
  attempts        smallint not null default 0,
  max_attempts    smallint not null default 8,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  locked_by       text,
  last_error      text,
  published_at    timestamptz,
  created_at      timestamptz not null default now(),
  unique (tenant_id, event_id, consumer_code)
);

create index on erp.event_outbox (tenant_id, consumer_code, status, next_attempt_at)
  where status in ('pending', 'failed');
create index on erp.event_outbox (tenant_id, status) where status = 'dead';

-- Fan out in the same transaction as the append.
create or replace function erp.enqueue_event_outbox()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into erp.event_outbox (
    tenant_id, event_id, consumer_code, max_attempts)
  select new.tenant_id, new.id, s.consumer_code, s.max_attempts
    from erp.event_subscription s
   where s.tenant_id = new.tenant_id
     and s.status = 'active'
     and new.event_type like s.event_pattern
  on conflict (tenant_id, event_id, consumer_code) do nothing;
  return new;
end;
$$;

create trigger t_event_enqueue_outbox
  after insert on erp.event
  for each row execute function erp.enqueue_event_outbox();

-- --- Worker protocol ---------------------------------------------------------

create or replace function erp.claim_outbox_batch(
  p_consumer_code text,
  p_batch_size    integer default 100,
  p_worker        text default null
) returns setof erp.event_outbox
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  return query
  update erp.event_outbox o
     set status = 'in_flight',
         attempts = o.attempts + 1,
         locked_at = now(),
         locked_by = coalesce(p_worker, current_user)
   where o.id in (
     select c.id
       from erp.event_outbox c
      where c.tenant_id = v_tenant
        and c.consumer_code = p_consumer_code
        and c.status in ('pending', 'failed')
        and c.next_attempt_at <= now()
      order by c.id
      limit greatest(p_batch_size, 1)
      -- SKIP LOCKED so several workers can drain one consumer's queue without
      -- blocking each other or handing the same event to two of them.
      for update skip locked)
  returning o.*;
end;
$$;

create or replace function erp.complete_outbox(p_outbox_id bigint)
returns void
language sql
security invoker
set search_path = ''
as $$
  update erp.event_outbox
     set status = 'published', published_at = now(), locked_at = null,
         locked_by = null, last_error = null
   where id = p_outbox_id
     and tenant_id = erp.require_tenant_id();
$$;

create or replace function erp.fail_outbox(p_outbox_id bigint, p_error text)
returns void
language sql
security invoker
set search_path = ''
as $$
  update erp.event_outbox
     set status = (case when attempts >= max_attempts then 'dead' else 'failed' end)::erp.outbox_status,
         last_error = p_error,
         locked_at = null,
         locked_by = null,
         -- Exponential backoff, capped, so a broken consumer does not spin.
         next_attempt_at = now() + least(power(2, attempts) * interval '1 second',
                                         interval '1 hour')
   where id = p_outbox_id
     and tenant_id = erp.require_tenant_id();
$$;

comment on function erp.fail_outbox(bigint, text) is
  'Records a delivery failure and backs off. Once attempts reach the '
  'subscription''s limit the row goes to dead rather than retrying for ever — '
  'a dead-letter row is visible and actionable; an infinite retry is neither.';

-- -----------------------------------------------------------------------------
-- Cursors and replay
--
-- Spec 3.3: "Consumers hold their own cursors; replay from any point is a
-- supported operation."
--
-- The watermark. global_seq is assigned when a row is inserted, but rows become
-- visible when their transaction COMMITS, and those two orders are not the
-- same. A consumer paging on "global_seq > my cursor" will therefore skip any
-- event whose sequence was allocated before the cursor moved but whose
-- transaction committed after — silently, and only under concurrency.
--
-- So every event records the transaction that wrote it, and reads stop at the
-- oldest transaction still in flight. Events below that line can never again be
-- joined by a late commit.
-- -----------------------------------------------------------------------------

create table erp.event_cursor (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  consumer_code   text not null,
  position        bigint not null default 0,
  last_event_id   uuid,
  last_moved_at   timestamptz,
  status          erp.record_status not null default 'active',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, consumer_code)
);

comment on table erp.event_cursor is
  'Each consumer''s own position in the stream. Held here rather than inside '
  'the consumer so replay is an operation on the platform, not a redeployment.';

create or replace function erp.event_read_watermark()
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(max(e.global_seq), 0)
    from erp.event e
   where e.tenant_id = erp.current_tenant_id()
     and e.xact_id < pg_snapshot_xmin(pg_current_snapshot())
$$;

comment on function erp.event_read_watermark() is
  'The highest sequence that is safe to read: every event at or below it was '
  'written by a transaction that has finished, so no later commit can insert '
  'itself behind a cursor that has already passed.';

create or replace function erp.read_event_stream(
  p_from_position bigint default 0,
  p_limit         integer default 500,
  p_event_types   text[] default null,
  p_aggregate_type text default null,
  p_aggregate_id  uuid default null
) returns setof erp.event
language sql
stable
security invoker
set search_path = ''
as $$
  select e.*
    from erp.event e
   where e.tenant_id = erp.require_tenant_id()
     and e.global_seq > p_from_position
     and e.xact_id < pg_snapshot_xmin(pg_current_snapshot())
     and (p_event_types is null or e.event_type = any (p_event_types))
     and (p_aggregate_type is null or e.aggregate_type = p_aggregate_type)
     and (p_aggregate_id is null or e.aggregate_id = p_aggregate_id)
   order by e.global_seq
   limit greatest(p_limit, 1)
$$;

create or replace function erp.advance_cursor(
  p_consumer_code text,
  p_position      bigint,
  p_last_event_id uuid default null
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  insert into erp.event_cursor (tenant_id, consumer_code, position, last_event_id, last_moved_at)
  values (v_tenant, p_consumer_code, p_position, p_last_event_id, now())
  on conflict (tenant_id, consumer_code) do update
    set position = greatest(erp.event_cursor.position, excluded.position),
        last_event_id = coalesce(excluded.last_event_id, erp.event_cursor.last_event_id),
        last_moved_at = now();
end;
$$;

-- Replay is deliberately a first-class, recorded operation rather than a
-- manual UPDATE on a cursor: rewinding a consumer re-delivers real events with
-- real side effects, and that should leave a trace.
create or replace function erp.replay_consumer(
  p_consumer_code  text,
  p_from_position  bigint default 0,
  p_requeue_outbox boolean default true,
  p_reason         text default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_requeued bigint := 0;
begin
  update erp.event_cursor
     set position = p_from_position, last_moved_at = now()
   where tenant_id = v_tenant and consumer_code = p_consumer_code;

  if not found then
    insert into erp.event_cursor (tenant_id, consumer_code, position, last_moved_at)
    values (v_tenant, p_consumer_code, p_from_position, now());
  end if;

  if p_requeue_outbox then
    with rewound as (
      update erp.event_outbox o
         set status = 'pending', attempts = 0, next_attempt_at = now(),
             locked_at = null, locked_by = null, last_error = null
        from erp.event e
       where o.tenant_id = v_tenant
         and o.consumer_code = p_consumer_code
         and e.id = o.event_id
         and e.global_seq > p_from_position
      returning 1)
    select count(*) into v_requeued from rewound;
  end if;

  insert into erp.audit_entry (
    tenant_id, actor_id, action, object_schema, object_type, object_key,
    after_state, reason, correlation_id)
  values (
    v_tenant, erp.current_principal_id(), 'execute', 'erp', 'event_cursor',
    p_consumer_code,
    jsonb_build_object('from_position', p_from_position,
                       'requeued', v_requeued),
    coalesce(p_reason, 'replay requested'),
    erp.current_correlation_id());

  return v_requeued;
end;
$$;

-- -----------------------------------------------------------------------------
-- Register, then generate policies, guards and audit coverage.
-- -----------------------------------------------------------------------------

select erp_meta.register_table('erp', 'event', 'tenant_scoped_append_only',
  'Spec 3.3: events are immutable once recorded. A correction is a further event.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'event',
   'Append-only and immutable by construction. Row-auditing an event store '
   'would store every fact twice.'),
  ('erp', 'event_outbox',
   'Delivery bookkeeping, not business state. Its rows change constantly by '
   'design and carry no information the event itself does not already hold.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
