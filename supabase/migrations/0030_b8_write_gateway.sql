-- =============================================================================
-- ERPWare — B8 (part 2/3): the write gateway and the message log
-- Spec 4.9 (Integration), Part 7 ("No direct writes to external systems outside
-- the gateway", "No unversioned rule, unaudited action or un-replayable
-- integration")
--
--   command — "an outbound intent through the write gateway: target, payload,
--              idempotency key, approval state, dry-run flag, lifecycle events"
--
-- The gateway is not a helper function that modules are encouraged to use. It
-- is the only thing that produces a row a worker can claim, and a worker can
-- send nothing it has not claimed. Everything else follows from that.
--
-- Seven things the gateway refuses, each because the alternative is a real
-- failure somebody has had:
--
--   1. A command with no idempotency key. Not nullable, unique per system.
--      A retry after a timeout is the single most common way to send a supplier
--      two purchase orders, and "the network was fine in testing" is not a
--      mitigation.
--
--   2. A payload that cannot satisfy the operation's request schema. Rejected
--      at submit, so a command that can never succeed never occupies a retry
--      slot or five minutes of an operator's morning.
--
--   3. An operation nobody enabled. Absence of an erp.external_system_operation
--      row means no, not yes. A connection that was configured for reading does
--      not silently acquire the ability to write.
--
--   4. Changing a command after it leaves 'drafted'. Payload, target, operation,
--      idempotency key and dry-run flag are all immutable from that point. The
--      thing approved is the thing sent.
--
--   5. A dry run that succeeds for real. A simulated command terminates at
--      'simulated' and can never reach 'succeeded'; a live one can never reach
--      'simulated'. Preview-then-approve is worthless if the flag can be flipped
--      between the two.
--
--   6. A status transition that is not in the legal table. The lifecycle is
--      product behaviour and deliberately NOT a tenant-configurable state
--      machine: a tenant able to define 'in_flight' → 'in_flight' would have
--      quietly disabled idempotency for themselves.
--
--   7. Mutating anything to replay it. erp.replay_command() creates a NEW
--      command linked to the old one. The original record of what was sent, and
--      what came back, survives the replay — which is the entire point of being
--      able to replay.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Lifecycle
-- -----------------------------------------------------------------------------

create type erp.command_status as enum (
  'drafted',           -- built, not yet gated
  'pending_approval',  -- waiting on the approval engine
  'rejected',          -- an approver said no; terminal
  'approved',          -- cleared to send, not yet queued
  'queued',            -- claimable by a dispatch worker
  'in_flight',         -- claimed, lease running
  'succeeded',         -- the counterpart accepted it; terminal
  'simulated',         -- a dry run completed; terminal, and never a real write
  'failed',            -- an attempt failed and a retry is due
  'dead',              -- out of attempts or refused permanently; terminal
  'cancelled'          -- withdrawn before dispatch; terminal
);

-- The legal transition table. Product behaviour, not configuration — see the
-- header. Every edge here exists because something has to be able to take it;
-- everything absent is refused by erp.check_command_transition().
create table erp_meta.command_transition (
  from_status erp.command_status not null,
  to_status   erp.command_status not null,
  note        text not null,
  primary key (from_status, to_status)
);

comment on table erp_meta.command_transition is
  'The write gateway''s lifecycle, held as data so it can be read and tested, '
  'but in erp_meta so no tenant can reach it. A tenant able to add '
  '''in_flight'' -> ''in_flight'' would have disabled their own idempotency.';

insert into erp_meta.command_transition (from_status, to_status, note) values
  ('drafted',          'pending_approval', 'a chain routes this command'),
  ('drafted',          'approved',         'nothing requires approval'),
  ('drafted',          'cancelled',        'withdrawn before gating'),
  ('pending_approval', 'approved',         'the approval engine cleared it'),
  ('pending_approval', 'rejected',         'an approver refused it'),
  ('pending_approval', 'cancelled',        'withdrawn while waiting'),
  ('approved',         'queued',           'released to the dispatch queue'),
  ('approved',         'cancelled',        'withdrawn after approval'),
  ('queued',           'in_flight',        'claimed by a worker'),
  ('queued',           'cancelled',        'withdrawn before a worker claimed it'),
  ('in_flight',        'succeeded',        'the counterpart accepted it'),
  ('in_flight',        'simulated',        'a dry run completed'),
  ('in_flight',        'failed',           'the attempt failed'),
  ('in_flight',        'queued',           'the lease expired; the worker is gone'),
  ('failed',           'queued',           'retry due'),
  ('failed',           'dead',             'out of attempts, or refused permanently'),
  ('failed',           'cancelled',        'withdrawn rather than retried'),
  -- The last failure is never followed by a retry that is due, so it cannot go
  -- through 'failed'. Routing it there would schedule a retry that never runs,
  -- which is a lie told to the monitoring screen.
  ('in_flight',        'dead',             'the final attempt failed, or the counterpart refused permanently');

-- -----------------------------------------------------------------------------
-- The command
-- -----------------------------------------------------------------------------

create table erp.command (
  id                 uuid not null default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  -- Dispatch order within a system. An identity column rather than a timestamp
  -- because two commands submitted in the same millisecond still have an order.
  global_seq         bigint generated always as identity,
  external_system_id uuid not null,
  operation_code     text not null,
  payload            jsonb not null default '{}'::jsonb,
  -- Never null. See refusal 1 in the header.
  idempotency_key    text not null check (length(idempotency_key) between 8 and 200),
  -- Commands sharing an ordering key are dispatched one at a time and in
  -- submission order. Three amendments to one order must not race each other.
  ordering_key       text,
  dry_run            boolean not null default false,
  status             erp.command_status not null default 'drafted',

  -- What caused this. Spec 4.10: nothing meaningful exists without provenance.
  source_object_type text,
  source_object_id   uuid,
  correlation_id     uuid,
  causation_event_id uuid,
  entity_id          uuid,
  site_id            uuid,

  -- The approval gate (B4).
  approval_request_id uuid,
  approval_required   boolean not null default false,

  -- Dispatch state. max_attempts is copied from the system at submit time so
  -- that editing the system's configuration does not retroactively change the
  -- retry budget of a command already in the queue.
  attempts           integer not null default 0 check (attempts >= 0),
  max_attempts       integer not null check (max_attempts between 1 and 50),
  next_attempt_at    timestamptz not null default now(),
  claimed_by         text,
  claimed_at         timestamptz,
  lease_expires_at   timestamptz,

  -- What came back.
  response           jsonb,
  response_at        timestamptz,
  last_error         text,

  -- Replay lineage. Set on the new command, never on the original.
  replay_of_command_id uuid,
  replay_reason      text,

  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,

  primary key (id),
  unique (tenant_id, id),
  -- Idempotency, structurally. Two intents with the same key against the same
  -- system are the same intent.
  unique (tenant_id, external_system_id, idempotency_key),
  foreign key (tenant_id, external_system_id)
    references erp.external_system (tenant_id, id) on delete restrict,
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, replay_of_command_id)
    references erp.command (tenant_id, id) on delete cascade,

  -- Refusal 5: the dry-run flag decides which terminal state is reachable.
  constraint command_dry_run_terminal
    check ((status <> 'succeeded' or not dry_run)
       and (status <> 'simulated' or dry_run)),
  -- A command in flight holds a lease, and one that is not does not.
  constraint command_lease_matches_status
    check ((status = 'in_flight') = (lease_expires_at is not null)),
  constraint command_replay_has_reason
    check (replay_of_command_id is null or replay_reason is not null)
);

comment on table erp.command is
  'Spec 4.9: an outbound intent through the write gateway. The only kind of row '
  'a dispatch worker can claim, and therefore the only route to an external '
  'write.';

comment on column erp.command.max_attempts is
  'Copied from the external system at submit time. Editing the system''s retry '
  'policy must not silently change the budget of a command already queued.';

create index on erp.command (tenant_id, external_system_id, status, next_attempt_at);
create index on erp.command (tenant_id, status) where status in ('failed', 'dead');
create index on erp.command (tenant_id, source_object_type, source_object_id);
create index on erp.command (tenant_id, ordering_key) where ordering_key is not null;
create index on erp.command (tenant_id, approval_request_id) where approval_request_id is not null;

-- The lifecycle log. Append-only, written by trigger, so it cannot drift from
-- the status column it describes.
create table erp.command_event (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  command_id   uuid not null,
  seq          integer not null,
  from_status  erp.command_status,
  to_status    erp.command_status not null,
  occurred_at  timestamptz not null default now(),
  actor_id     uuid,
  actor_label  text,
  detail       jsonb not null default '{}'::jsonb,
  unique (tenant_id, command_id, seq),
  foreign key (tenant_id, command_id)
    references erp.command (tenant_id, id) on delete cascade
);

comment on table erp.command_event is
  'Spec 4.9: the command''s lifecycle events. Written by trigger rather than by '
  'each caller, because a log the caller maintains is a log that disagrees with '
  'the row it describes.';

create index on erp.command_event (tenant_id, command_id, seq);

-- -----------------------------------------------------------------------------
-- The transition guard
-- -----------------------------------------------------------------------------

create or replace function erp.check_command_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_seq integer;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'drafted' then
      raise exception
        'ERPWARE_COMMAND_MUST_START_DRAFTED: a command enters the gateway at '
        '''drafted'', not at ''%''', new.status
        using errcode = '23514';
    end if;

    insert into erp.command_event (
      tenant_id, command_id, seq, from_status, to_status, actor_id, detail)
    values (new.tenant_id, new.id, 1, null, 'drafted', erp.current_principal_id(),
            jsonb_build_object('operation', new.operation_code,
                               'dry_run', new.dry_run,
                               'idempotency_key', new.idempotency_key));
    return new;
  end if;

  -- Refusal 4: the thing approved is the thing sent.
  if old.status <> 'drafted' then
    if new.external_system_id is distinct from old.external_system_id
       or new.operation_code is distinct from old.operation_code
       or new.payload is distinct from old.payload
       or new.idempotency_key is distinct from old.idempotency_key
    then
      raise exception
        'ERPWARE_COMMAND_IMMUTABLE: target, operation, payload and idempotency '
        'key are fixed once a command leaves ''drafted'' (status is %)', old.status
        using errcode = '42501';
    end if;
  end if;

  -- Refusal 5, the other half: the flag itself never moves, at any status.
  if new.dry_run is distinct from old.dry_run then
    raise exception
      'ERPWARE_DRY_RUN_IMMUTABLE: a command is a simulation or it is not; '
      'submit a separate command'
      using errcode = '42501';
  end if;

  if new.status = old.status then
    return new;
  end if;

  -- Refusal 6.
  if not exists (
    select 1 from erp_meta.command_transition t
     where t.from_status = old.status and t.to_status = new.status)
  then
    raise exception 'ERPWARE_ILLEGAL_COMMAND_TRANSITION: % -> % is not a legal '
      'step in the gateway lifecycle', old.status, new.status
      using errcode = '23514';
  end if;

  select coalesce(max(e.seq), 0) + 1 into v_seq
    from erp.command_event e
   where e.tenant_id = new.tenant_id and e.command_id = new.id;

  insert into erp.command_event (
    tenant_id, command_id, seq, from_status, to_status, actor_id, actor_label, detail)
  values (
    new.tenant_id, new.id, v_seq, old.status, new.status,
    erp.current_principal_id(), new.claimed_by,
    jsonb_strip_nulls(jsonb_build_object(
      'attempts', new.attempts,
      'error', new.last_error,
      'next_attempt_at', new.next_attempt_at,
      'approval_request_id', new.approval_request_id)));

  return new;
end;
$$;

-- AFTER, not BEFORE. The trigger never modifies NEW — it validates and it logs
-- — and the log has a foreign key onto erp.command, so writing the creation
-- event before the command row lands is refused by that key. Raising from an
-- AFTER trigger still aborts the statement, so every refusal keeps its force.
create trigger t_command_transition
  after insert or update on erp.command
  for each row execute function erp.check_command_transition();

-- -----------------------------------------------------------------------------
-- Submitting a command
-- -----------------------------------------------------------------------------

-- The default idempotency key. Derived from everything that makes this intent
-- what it is: the target, the verb, the payload and the object it is about.
-- Resubmitting the identical intent collides and returns the existing command;
-- a genuinely different intent differs in at least one input.
--
-- A caller that knows better — one holding a key issued by the counterpart —
-- passes their own, and should.
--
-- jsonb's text rendering is already key-ordered and whitespace-normalised, so
-- two equal documents hash equally. Named explicitly so the guarantee is stated
-- rather than assumed by whoever reads the hash next.
create or replace function erp.jsonb_canonical_form(p_document jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_document, '{}'::jsonb)::text
$$;

create or replace function erp.derive_idempotency_key(
  p_system_id    uuid,
  p_operation    text,
  p_payload      jsonb,
  p_object_type  text,
  p_object_id    uuid
) returns text
language sql
immutable
set search_path = ''
as $$
  select encode(
    pg_catalog.sha256(convert_to(
      coalesce(p_system_id::text, '') || '|' || coalesce(p_operation, '') || '|' ||
      coalesce(p_object_type, '') || '|' || coalesce(p_object_id::text, '') || '|' ||
      erp.jsonb_canonical_form(p_payload), 'UTF8')), 'hex')
$$;

create or replace function erp.submit_command(
  p_system_code      text,
  p_operation_code   text,
  p_payload          jsonb default '{}'::jsonb,
  p_dry_run          boolean default false,
  p_idempotency_key  text default null,
  p_ordering_key     text default null,
  p_source_object_type text default null,
  p_source_object_id uuid default null,
  p_entity_id        uuid default null,
  p_site_id          uuid default null,
  p_correlation_id   uuid default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_sys       erp.external_system%rowtype;
  v_op        erp_ref.adapter_operation%rowtype;
  v_adapter   erp_ref.adapter%rowtype;
  v_enabled   erp.external_system_operation%rowtype;
  v_key       text;
  v_existing  erp.command%rowtype;
  v_id        uuid;
  v_needs     boolean;
  v_cred      text;
  v_chain     uuid;
  v_ordering  text;
begin
  -- Every outbound write is an integration action, whatever business reason
  -- prompted it. The calling module has already authorised its own action; this
  -- authorises leaving the building.
  perform erp.authorise('administration.integrate', p_entity_id, p_site_id, null,
                        'command', null, p_correlation_id);

  select * into v_sys from erp.external_system s
   where s.tenant_id = v_tenant and s.code = p_system_code;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_EXTERNAL_SYSTEM: %', p_system_code
      using errcode = '23503';
  end if;

  -- A live send needs a live system. A dry run against a draft configuration is
  -- exactly how a configuration gets proven before it goes live, so that is
  -- allowed.
  if v_sys.status <> 'active' and not p_dry_run then
    raise exception
      'ERPWARE_SYSTEM_NOT_ACTIVE: % is %; only a dry run may target it',
      p_system_code, v_sys.status
      using errcode = '42501';
  end if;

  select * into v_adapter from erp_ref.adapter a
   where a.code = v_sys.adapter_code and a.version = v_sys.adapter_version;

  if v_adapter.direction = 'inbound' then
    raise exception
      'ERPWARE_ADAPTER_IS_INBOUND: % cannot carry an outbound command',
      v_sys.adapter_code
      using errcode = '42501';
  end if;

  select * into v_op from erp_ref.adapter_operation o
   where o.adapter_code = v_sys.adapter_code
     and o.adapter_version = v_sys.adapter_version
     and o.code = p_operation_code;

  if not found then
    raise exception
      'ERPWARE_UNKNOWN_OPERATION: % is not an operation of adapter %@%',
      p_operation_code, v_sys.adapter_code, v_sys.adapter_version
      using errcode = '23503';
  end if;

  -- Refusal 3: absence of an enablement row means no.
  select * into v_enabled from erp.external_system_operation eo
   where eo.tenant_id = v_tenant
     and eo.external_system_id = v_sys.id
     and eo.operation_code = p_operation_code;

  if not found or not v_enabled.is_enabled then
    raise exception
      'ERPWARE_OPERATION_NOT_ENABLED: % is not enabled on %',
      p_operation_code, p_system_code
      using errcode = '42501',
      detail = 'Enable it in erp.external_system_operation. Absence is a refusal.';
  end if;

  if p_dry_run and not (v_adapter.supports_dry_run and v_op.supports_dry_run) then
    raise exception
      'ERPWARE_DRY_RUN_UNSUPPORTED: % on % cannot be simulated',
      p_operation_code, p_system_code
      using errcode = '42501';
  end if;

  -- Refusal 2.
  if not extensions.jsonb_matches_schema(v_op.request_schema::json, p_payload) then
    raise exception
      'ERPWARE_INVALID_COMMAND_PAYLOAD: payload does not satisfy the request '
      'schema for %', p_operation_code
      using errcode = '22023', detail = p_payload::text;
  end if;

  -- Spec 4.9: no module holds credentials. That includes putting one in a
  -- payload so the far side will accept it.
  select string_agg(format('  %s — %s', f.path, f.finding), E'\n') into v_cred
    from erp.inline_credential_findings(p_payload) f;

  if v_cred is not null then
    raise exception
      'ERPWARE_INLINE_CREDENTIAL: a command payload must not carry a credential'
      using errcode = '42501', detail = v_cred;
  end if;

  v_key := coalesce(
    p_idempotency_key,
    erp.derive_idempotency_key(v_sys.id, p_operation_code, p_payload,
                               p_source_object_type, p_source_object_id));

  -- Idempotency at the gateway: the same key is the same intent. Returning the
  -- existing command is the correct answer to a caller retrying after a timeout
  -- it never saw the result of.
  select * into v_existing from erp.command c
   where c.tenant_id = v_tenant
     and c.external_system_id = v_sys.id
     and c.idempotency_key = v_key;

  if found then
    if v_existing.payload is distinct from p_payload then
      raise exception
        'ERPWARE_IDEMPOTENCY_CONFLICT: key % already names a different intent '
        'on %', v_key, p_system_code
        using errcode = '23505',
        detail = 'The same key must not be reused for a different payload.';
    end if;
    return v_existing.id;
  end if;

  v_ordering := coalesce(
    p_ordering_key,
    case
      when v_enabled.ordering_key_path is not null
        then p_payload #>> string_to_array(v_enabled.ordering_key_path, '.')
      when v_op.default_ordering_key_path is not null
        then p_payload #>> string_to_array(v_op.default_ordering_key_path, '.')
    end);

  insert into erp.command (
    tenant_id, external_system_id, operation_code, payload, idempotency_key,
    ordering_key, dry_run, source_object_type, source_object_id, correlation_id,
    entity_id, site_id, max_attempts, next_attempt_at)
  values (
    v_tenant, v_sys.id, p_operation_code, p_payload, v_key,
    v_ordering, p_dry_run, p_source_object_type, p_source_object_id,
    coalesce(p_correlation_id, erp.current_correlation_id()),
    p_entity_id, p_site_id, v_sys.max_attempts, now())
  returning id into v_id;

  -- The approval gate. A read never needs one. A simulation never needs one —
  -- that is what makes preview useful. Everything else is decided by the
  -- system, the operation, and whether a chain routes it.
  v_needs := v_op.is_mutating
             and not p_dry_run
             and (v_sys.requires_approval
                  or coalesce(v_enabled.requires_approval, false));

  if v_op.is_mutating and not p_dry_run and not v_needs then
    v_chain := erp.select_approval_chain(
      'integration.command',
      jsonb_build_object('system_code', p_system_code,
                         'operation_code', p_operation_code,
                         'payload', p_payload),
      p_entity_id, p_site_id);
    v_needs := v_chain is not null;
  end if;

  if v_needs then
    declare
      v_req uuid;
    begin
      v_req := erp.request_approval(
        'integration.command', v_id,
        jsonb_build_object('system_code', p_system_code,
                           'operation_code', p_operation_code,
                           'payload', p_payload),
        1, p_entity_id, p_site_id);

      update erp.command
         set approval_required = true,
             approval_request_id = v_req,
             status = 'pending_approval'
       where id = v_id;
    end;
  else
    -- Approved without a chain is still a recorded decision: the lifecycle log
    -- shows it went straight through, and why.
    update erp.command set status = 'approved' where id = v_id;
    perform erp.release_command(v_id);
  end if;

  return v_id;
end;
$$;

comment on function erp.submit_command is
  'Spec 4.9: the only way an outbound intent enters existence. Validates, '
  'gates, deduplicates and queues. Returns the existing command when the '
  'idempotency key has been seen, which is the right answer to a retry.';

-- -----------------------------------------------------------------------------
-- Release, approval synchronisation, cancellation
-- -----------------------------------------------------------------------------

create or replace function erp.release_command(p_command_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  update erp.command
     set status = 'queued', next_attempt_at = least(next_attempt_at, now())
   where tenant_id = v_tenant and id = p_command_id and status = 'approved';

  if not found then
    raise exception
      'ERPWARE_COMMAND_NOT_RELEASABLE: % is not in ''approved''', p_command_id
      using errcode = '23514';
  end if;
end;
$$;

-- Closes the loop between the approval engine and the gateway. Called by a
-- trigger on erp.approval_request, so a decision recorded in B4 moves the
-- command without anyone remembering to.
create or replace function erp.sync_command_approval(p_command_id uuid)
returns erp.command_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cmd    erp.command%rowtype;
  v_state  record;
begin
  select * into v_cmd from erp.command
   where tenant_id = v_tenant and id = p_command_id;

  if not found or v_cmd.status <> 'pending_approval' then
    return coalesce(v_cmd.status, 'cancelled');
  end if;

  select * into v_state
    from erp.approval_state('integration.command', p_command_id) limit 1;

  if v_state.status = 'approved' then
    update erp.command set status = 'approved' where id = p_command_id;
    perform erp.release_command(p_command_id);
    return 'queued';
  elsif v_state.status in ('rejected', 'cancelled') then
    update erp.command
       set status = case when v_state.status = 'rejected'
                         then 'rejected' else 'cancelled' end,
           last_error = format('approval %s', v_state.status)
     where id = p_command_id;
    return case when v_state.status = 'rejected' then 'rejected' else 'cancelled' end;
  end if;

  return 'pending_approval';
end;
$$;

create or replace function erp.propagate_command_approval()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.object_type = 'integration.command'
     and new.status is distinct from old.status
     and new.status in ('approved', 'rejected', 'cancelled')
  then
    perform erp.sync_command_approval(new.object_id);
  end if;
  return new;
end;
$$;

create trigger t_approval_propagates_to_command
  after update on erp.approval_request
  for each row execute function erp.propagate_command_approval();

create or replace function erp.cancel_command(p_command_id uuid, p_reason text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.integrate', null, null, null,
                        'command', p_command_id);

  update erp.command
     set status = 'cancelled', last_error = p_reason
   where tenant_id = v_tenant and id = p_command_id
     and status in ('drafted', 'pending_approval', 'approved', 'queued', 'failed');

  if not found then
    raise exception
      'ERPWARE_COMMAND_NOT_CANCELLABLE: % is either already terminal or in '
      'flight', p_command_id
      using errcode = '23514';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Dispatch: claim, complete, fail, reclaim
--
-- A worker's whole vocabulary. Nothing else moves a command toward the outside
-- world, and none of these can be reached without a command row.
-- -----------------------------------------------------------------------------

create or replace function erp.claim_command_batch(
  p_system_code text,
  p_batch_size  integer default 20,
  p_worker      text default null,
  p_lease       interval default interval '5 minutes'
) returns setof erp.command
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_sys      erp.external_system%rowtype;
  v_capacity integer;
  v_worker   text := coalesce(p_worker, current_user);
begin
  select * into v_sys from erp.external_system s
   where s.tenant_id = v_tenant and s.code = p_system_code;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_EXTERNAL_SYSTEM: %', p_system_code
      using errcode = '23503';
  end if;

  -- Spec Part 7 via B6: a kill switch on the integration stops dispatch without
  -- losing a single queued command. They wait; they are not discarded.
  if erp.is_killed('integration', p_system_code) then
    return;
  end if;

  if v_sys.status <> 'active' then
    return;
  end if;

  select greatest(v_sys.max_in_flight - count(*), 0) into v_capacity
    from erp.command c
   where c.tenant_id = v_tenant
     and c.external_system_id = v_sys.id
     and c.status = 'in_flight'
     and c.lease_expires_at > now();

  if v_capacity = 0 then
    return;
  end if;

  return query
  update erp.command c
     set status = 'in_flight',
         attempts = c.attempts + 1,
         claimed_by = v_worker,
         claimed_at = now(),
         lease_expires_at = now() + p_lease,
         last_error = null
   where c.id in (
     -- The lock is taken at this level, where erp.command is directly in FROM:
     -- SKIP LOCKED cannot be applied over a DISTINCT, so the head-of-queue
     -- selection happens in the inner sub-select and the locking outside it.
     select lockable.id
       from erp.command lockable
      where lockable.id in (
        -- One command per ordering key per claim, earliest first. A command
        -- without an ordering key forms its own group, so it is serialised
        -- against nothing.
        select distinct on (coalesce(q.ordering_key, q.id::text)) q.id
          from erp.command q
         where q.tenant_id = v_tenant
           and q.external_system_id = v_sys.id
           and q.status = 'queued'
           and q.next_attempt_at <= now()
           -- A per-operation kill switch stops one verb without stopping the
           -- whole connection.
           and not erp.is_killed('command_class', q.operation_code)
           -- An ordering key with something already in flight waits its turn.
           and (q.ordering_key is null
                or not exists (
                  select 1 from erp.command f
                   where f.tenant_id = v_tenant
                     and f.external_system_id = v_sys.id
                     and f.ordering_key = q.ordering_key
                     and f.status = 'in_flight'
                     and f.lease_expires_at > now()))
         order by coalesce(q.ordering_key, q.id::text), q.global_seq)
      order by lockable.global_seq
      limit least(greatest(p_batch_size, 1), v_capacity)
      for update skip locked)
  returning c.*;
end;
$$;

comment on function erp.claim_command_batch is
  'The dispatch worker''s only input. Honours the kill switches, the system''s '
  'in-flight ceiling and per-key ordering, and hands out a lease so a worker '
  'that dies does not strand a command forever.';

create or replace function erp.complete_command(
  p_command_id  uuid,
  p_response    jsonb default '{}'::jsonb,
  p_external_id text default null
) returns erp.command_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cmd    erp.command%rowtype;
  v_final  erp.command_status;
  v_op     erp_ref.adapter_operation%rowtype;
  v_sys    erp.external_system%rowtype;
begin
  select * into v_cmd from erp.command
   where tenant_id = v_tenant and id = p_command_id for update;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_COMMAND: %', p_command_id using errcode = '23503';
  end if;

  if v_cmd.status <> 'in_flight' then
    raise exception
      'ERPWARE_COMMAND_NOT_IN_FLIGHT: % is %; only a claimed command can be '
      'completed', p_command_id, v_cmd.status
      using errcode = '23514';
  end if;

  select * into v_sys from erp.external_system where id = v_cmd.external_system_id;
  select * into v_op from erp_ref.adapter_operation o
   where o.adapter_code = v_sys.adapter_code
     and o.adapter_version = v_sys.adapter_version
     and o.code = v_cmd.operation_code;

  if v_op.response_schema is not null
     and not extensions.jsonb_matches_schema(v_op.response_schema::json,
                                             coalesce(p_response, '{}'::jsonb))
  then
    raise exception
      'ERPWARE_INVALID_COMMAND_RESPONSE: response does not satisfy the schema '
      'for %', v_cmd.operation_code
      using errcode = '22023', detail = coalesce(p_response, '{}'::jsonb)::text;
  end if;

  -- Refusal 5, enforced here as well as by the CHECK, so the error names the
  -- reason rather than a constraint.
  v_final := case when v_cmd.dry_run then 'simulated' else 'succeeded' end;

  update erp.command
     set status = v_final,
         response = p_response,
         response_at = now(),
         claimed_by = null,
         claimed_at = null,
         lease_expires_at = null,
         last_error = null
   where id = p_command_id;

  -- A live command that told us the counterpart's identifier for our object is
  -- the natural moment to record the mapping. A dry run is not: nothing was
  -- created on the far side, and a mapping to a hypothetical record is a lie.
  if p_external_id is not null
     and not v_cmd.dry_run
     and v_cmd.source_object_type is not null
     and v_cmd.source_object_id is not null
  then
    perform erp.link_external_ref(
      v_sys.code, v_cmd.source_object_type, v_cmd.source_object_id, p_external_id);
  end if;

  return v_final;
end;
$$;

create or replace function erp.fail_command(
  p_command_id uuid,
  p_error      text,
  p_retryable  boolean default true
) returns erp.command_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_cmd     erp.command%rowtype;
  v_sys     erp.external_system%rowtype;
  v_final   erp.command_status;
  v_backoff interval;
begin
  select * into v_cmd from erp.command
   where tenant_id = v_tenant and id = p_command_id for update;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_COMMAND: %', p_command_id using errcode = '23503';
  end if;

  if v_cmd.status <> 'in_flight' then
    raise exception
      'ERPWARE_COMMAND_NOT_IN_FLIGHT: % is %', p_command_id, v_cmd.status
      using errcode = '23514';
  end if;

  select * into v_sys from erp.external_system where id = v_cmd.external_system_id;

  -- Exponential, capped at an hour. A counterpart that has been down for an
  -- hour will not be helped by being asked every thirty seconds.
  v_backoff := least(
    make_interval(secs => v_sys.retry_backoff_seconds * power(2, v_cmd.attempts - 1)),
    interval '1 hour');

  v_final := case
    when not p_retryable then 'dead'
    when v_cmd.attempts >= v_cmd.max_attempts then 'dead'
    else 'failed'
  end;

  update erp.command
     set status = v_final,
         last_error = p_error,
         claimed_by = null,
         claimed_at = null,
         lease_expires_at = null,
         next_attempt_at = case when v_final = 'failed' then now() + v_backoff
                                else next_attempt_at end
   where id = p_command_id;

  -- 'failed' is a state a command sits in until its backoff elapses; the
  -- transition back to 'queued' is what makes it claimable, and doing it here
  -- keeps the retry decision in one place rather than in every worker.
  if v_final = 'failed' then
    update erp.command set status = 'queued' where id = p_command_id;
  end if;

  return v_final;
end;
$$;

comment on function erp.fail_command is
  'Records a failed attempt and decides what happens next: back to the queue '
  'with an exponential backoff, or dead. A worker never decides that itself.';

-- A worker that dies mid-send leaves a command in flight with a lease nobody
-- will renew. Without this the command is stranded, and a stranded command in
-- an ordered key blocks everything behind it.
create or replace function erp.reclaim_expired_commands(p_system_code text default null)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_count  integer;
begin
  with expired as (
    select c.id
      from erp.command c
      join erp.external_system s
        on s.tenant_id = c.tenant_id and s.id = c.external_system_id
     where c.tenant_id = v_tenant
       and c.status = 'in_flight'
       and c.lease_expires_at < now()
       and (p_system_code is null or s.code = p_system_code)
     for update of c skip locked
  )
  update erp.command c
     set status = 'queued',
         claimed_by = null,
         claimed_at = null,
         lease_expires_at = null,
         last_error = format('lease expired at %s; worker %s did not report',
                             c.lease_expires_at, coalesce(c.claimed_by, 'unknown'))
    from expired e
   where c.id = e.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- Replay
--
-- Refusal 7: replay creates, it never mutates. The original command keeps what
-- it sent and what came back, which is the only reason the replay is
-- trustworthy.
-- -----------------------------------------------------------------------------

create or replace function erp.replay_command(
  p_command_id uuid,
  p_reason     text,
  p_dry_run    boolean default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cmd    erp.command%rowtype;
  v_sys    erp.external_system%rowtype;
  v_n      integer;
begin
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception
      'ERPWARE_REPLAY_NEEDS_REASON: a replay is an action somebody has to '
      'account for'
      using errcode = '23514';
  end if;

  select * into v_cmd from erp.command
   where tenant_id = v_tenant and id = p_command_id;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_COMMAND: %', p_command_id using errcode = '23503';
  end if;

  if v_cmd.status not in ('succeeded', 'simulated', 'dead', 'cancelled', 'rejected') then
    raise exception
      'ERPWARE_COMMAND_NOT_TERMINAL: % is %; replaying a command still in the '
      'queue would send it twice', p_command_id, v_cmd.status
      using errcode = '23514';
  end if;

  select * into v_sys from erp.external_system where id = v_cmd.external_system_id;

  select count(*) + 1 into v_n from erp.command
   where tenant_id = v_tenant and replay_of_command_id = p_command_id;

  return erp.submit_command(
    p_system_code        => v_sys.code,
    p_operation_code     => v_cmd.operation_code,
    p_payload            => v_cmd.payload,
    p_dry_run            => coalesce(p_dry_run, v_cmd.dry_run),
    -- A fresh key: this is deliberately a second send, and it must not collide
    -- with the first.
    p_idempotency_key    => left(v_cmd.idempotency_key, 180) || ':r' || v_n::text,
    p_ordering_key       => v_cmd.ordering_key,
    p_source_object_type => v_cmd.source_object_type,
    p_source_object_id   => v_cmd.source_object_id,
    p_entity_id          => v_cmd.entity_id,
    p_site_id            => v_cmd.site_id,
    p_correlation_id     => v_cmd.correlation_id);
end;
$$;

-- submit_command cannot set the lineage columns without a wider signature that
-- every caller would have to ignore, so the replay link is written after.
create or replace function erp.replay_command_linked(
  p_command_id uuid,
  p_reason     text,
  p_dry_run    boolean default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_new uuid;
begin
  v_new := erp.replay_command(p_command_id, p_reason, p_dry_run);

  update erp.command
     set replay_of_command_id = p_command_id,
         replay_reason = p_reason
   where id = v_new
     and tenant_id = erp.require_tenant_id();

  return v_new;
end;
$$;

comment on function erp.replay_command_linked is
  'Spec Part 7: no un-replayable integration. Creates a new command carrying '
  'the original''s payload, linked to it, with a fresh idempotency key so the '
  'second send is honestly a second send.';

-- -----------------------------------------------------------------------------
-- The message log
--
-- Spec 4.9: "inbound and outbound message log with status, retries and payload
-- reference". Distinct from erp.command: a command is an intent, a message is a
-- thing that crossed the wire. One command may produce several messages, and an
-- inbound message has no command at all.
-- -----------------------------------------------------------------------------

create type erp.message_direction as enum ('inbound', 'outbound');

create type erp.message_status as enum (
  'received', 'queued', 'processing', 'processed', 'failed', 'dead',
  'ignored', 'duplicate'
);

create table erp.integration_message (
  id                 bigint generated always as identity,
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  external_system_id uuid not null,
  direction          erp.message_direction not null,
  message_type       text not null,
  -- The counterpart's own identifier for this delivery. The basis of inbound
  -- deduplication: a webhook delivered three times is one message.
  external_message_id text,
  -- Small payloads inline; large or sensitive ones by reference to wherever the
  -- deployment keeps them. The hash is mandatory either way, because it is what
  -- makes a replay provably the same message rather than approximately it.
  payload            jsonb,
  payload_ref        text,
  payload_hash       text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  status             erp.message_status not null default 'received',
  attempts           integer not null default 0 check (attempts >= 0),
  replays            integer not null default 0 check (replays >= 0),
  next_attempt_at    timestamptz not null default now(),
  last_error         text,
  -- Set by erp.replay_message() and consumed by the attempt it causes, so the
  -- reason a replay was ordered lands on the attempt it produced rather than
  -- floating free of it.
  pending_replay_reason text,
  claimed_at         timestamptz,
  -- For outbound: the command this message carried.
  command_id         uuid,
  correlation_id     uuid,
  received_at        timestamptz not null default now(),
  processed_at       timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, external_system_id)
    references erp.external_system (tenant_id, id) on delete cascade,
  foreign key (tenant_id, command_id)
    references erp.command (tenant_id, id) on delete cascade,
  constraint integration_message_has_a_payload
    check (payload is not null or payload_ref is not null)
);

comment on table erp.integration_message is
  'Spec 4.9: the inbound and outbound message log. A message is a thing that '
  'crossed the wire; erp.command is an intent. One command can produce several '
  'messages, and an inbound message has no command at all.';

comment on column erp.integration_message.payload_hash is
  'Mandatory. What makes a replay provably the same message rather than '
  'approximately the same message.';

-- Inbound deduplication. The counterpart's identifier is unique per system, so
-- a redelivery lands on the existing row instead of producing a second effect.
create unique index integration_message_inbound_identity
  on erp.integration_message (tenant_id, external_system_id, external_message_id)
  where direction = 'inbound' and external_message_id is not null;

create index on erp.integration_message (tenant_id, external_system_id, status, next_attempt_at);
create index on erp.integration_message (tenant_id, command_id) where command_id is not null;
create index on erp.integration_message (tenant_id, received_at desc);

-- Every processing attempt, kept. A message that failed twice, was replayed and
-- then succeeded has a history worth reading; a status column alone loses it.
--
-- The row is written once, when the attempt finishes and its outcome is known.
-- Writing it at claim time and updating it later would mean an append-only
-- table that gets updated, which is not append-only, and the guard that
-- enforces append-only would have been quietly turned off to allow it.
create table erp.integration_message_attempt (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  message_id   bigint not null,
  attempt_no   integer not null check (attempt_no >= 1),
  is_replay    boolean not null default false,
  replay_reason text,
  started_at   timestamptz not null,
  finished_at  timestamptz not null default now(),
  outcome      erp.message_status not null,
  error        text,
  actor_id     uuid,
  unique (tenant_id, message_id, attempt_no),
  foreign key (tenant_id, message_id)
    references erp.integration_message (tenant_id, id) on delete cascade,
  constraint message_attempt_replay_has_reason
    check (not is_replay or replay_reason is not null)
);

comment on table erp.integration_message_attempt is
  'Every processing attempt on a message, including replays and why they were '
  'ordered. Insert-only: one row per finished attempt, written when the '
  'outcome is known.';

create or replace function erp.payload_hash(p_payload jsonb, p_ref text default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(pg_catalog.sha256(convert_to(
    coalesce(p_payload::text, '') || '|' || coalesce(p_ref, ''), 'UTF8')), 'hex')
$$;

create or replace function erp.record_inbound_message(
  p_system_code        text,
  p_message_type       text,
  p_payload            jsonb default null,
  p_external_message_id text default null,
  p_payload_ref        text default null,
  p_correlation_id     uuid default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_sys      erp.external_system%rowtype;
  v_existing erp.integration_message%rowtype;
  v_id       bigint;
begin
  select * into v_sys from erp.external_system s
   where s.tenant_id = v_tenant and s.code = p_system_code;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_EXTERNAL_SYSTEM: %', p_system_code
      using errcode = '23503';
  end if;

  if p_external_message_id is not null then
    select * into v_existing from erp.integration_message m
     where m.tenant_id = v_tenant
       and m.external_system_id = v_sys.id
       and m.direction = 'inbound'
       and m.external_message_id = p_external_message_id;

    -- A redelivery. Returning the original identifier — rather than inserting,
    -- or raising — is what makes an at-least-once counterpart safe to accept.
    if found then
      return v_existing.id;
    end if;
  end if;

  insert into erp.integration_message (
    tenant_id, external_system_id, direction, message_type, external_message_id,
    payload, payload_ref, payload_hash, status, correlation_id, created_by)
  values (
    v_tenant, v_sys.id, 'inbound', p_message_type, p_external_message_id,
    p_payload, p_payload_ref, erp.payload_hash(p_payload, p_payload_ref),
    'queued', coalesce(p_correlation_id, erp.current_correlation_id()),
    erp.current_principal_id())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.record_inbound_message is
  'Idempotent receipt. A counterpart that delivers the same webhook three times '
  'produces one message and one effect.';

create or replace function erp.record_outbound_message(
  p_command_id  uuid,
  p_payload     jsonb default null,
  p_payload_ref text default null
) returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cmd    erp.command%rowtype;
  v_id     bigint;
begin
  select * into v_cmd from erp.command
   where tenant_id = v_tenant and id = p_command_id;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_COMMAND: %', p_command_id using errcode = '23503';
  end if;

  insert into erp.integration_message (
    tenant_id, external_system_id, direction, message_type, payload, payload_ref,
    payload_hash, status, command_id, correlation_id, created_by)
  values (
    v_tenant, v_cmd.external_system_id, 'outbound', v_cmd.operation_code,
    coalesce(p_payload, v_cmd.payload), p_payload_ref,
    erp.payload_hash(coalesce(p_payload, v_cmd.payload), p_payload_ref),
    'processed', p_command_id, v_cmd.correlation_id, erp.current_principal_id())
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.claim_message_batch(
  p_system_code text,
  p_batch_size  integer default 50,
  p_worker      text default null
) returns setof erp.integration_message
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_sys    uuid;
begin
  select s.id into v_sys from erp.external_system s
   where s.tenant_id = v_tenant and s.code = p_system_code;

  if v_sys is null or erp.is_killed('integration', p_system_code) then
    return;
  end if;

  return query
  update erp.integration_message m
     set status = 'processing', attempts = m.attempts + 1, claimed_at = now()
   where m.id in (
     select c.id from erp.integration_message c
      where c.tenant_id = v_tenant
        and c.external_system_id = v_sys
        and c.direction = 'inbound'
        and c.status in ('queued', 'failed')
        and c.next_attempt_at <= now()
      order by c.id
      limit greatest(p_batch_size, 1)
      for update skip locked)
  returning m.*;
end;
$$;

-- Closes an attempt: one insert-only row recording what happened, and the
-- message's own status. Shared by the success and failure paths so the two
-- cannot record attempts differently.
create or replace function erp.close_message_attempt(
  p_message  erp.integration_message,
  p_outcome  erp.message_status,
  p_error    text default null
) returns void
language sql
security invoker
set search_path = ''
as $$
  insert into erp.integration_message_attempt (
    tenant_id, message_id, attempt_no, is_replay, replay_reason,
    started_at, finished_at, outcome, error, actor_id)
  values (
    p_message.tenant_id, p_message.id, p_message.attempts,
    p_message.pending_replay_reason is not null, p_message.pending_replay_reason,
    coalesce(p_message.claimed_at, now()), now(), p_outcome, p_error,
    erp.current_principal_id())
  on conflict (tenant_id, message_id, attempt_no) do nothing;
$$;

create or replace function erp.complete_message(p_message_id bigint)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_msg    erp.integration_message%rowtype;
begin
  select * into v_msg from erp.integration_message
   where tenant_id = v_tenant and id = p_message_id for update;

  if not found or v_msg.status <> 'processing' then
    raise exception
      'ERPWARE_MESSAGE_NOT_PROCESSING: % was not claimed', p_message_id
      using errcode = '23514';
  end if;

  perform erp.close_message_attempt(v_msg, 'processed');

  update erp.integration_message
     set status = 'processed', processed_at = now(), last_error = null,
         pending_replay_reason = null
   where id = p_message_id;
end;
$$;

create or replace function erp.fail_message(
  p_message_id bigint,
  p_error      text,
  p_retryable  boolean default true
) returns erp.message_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_msg    erp.integration_message%rowtype;
  v_sys    erp.external_system%rowtype;
  v_final  erp.message_status;
begin
  select * into v_msg from erp.integration_message
   where tenant_id = v_tenant and id = p_message_id for update;

  if not found or v_msg.status <> 'processing' then
    raise exception
      'ERPWARE_MESSAGE_NOT_PROCESSING: % was not claimed', p_message_id
      using errcode = '23514';
  end if;

  select * into v_sys from erp.external_system where id = v_msg.external_system_id;

  v_final := case
    when not p_retryable then 'dead'
    when v_msg.attempts >= v_sys.max_attempts then 'dead'
    else 'failed'
  end;

  perform erp.close_message_attempt(v_msg, v_final, p_error);

  update erp.integration_message
     set status = v_final,
         last_error = p_error,
         pending_replay_reason = null,
         next_attempt_at = now() + least(
           make_interval(secs => v_sys.retry_backoff_seconds * power(2, v_msg.attempts - 1)),
           interval '1 hour')
   where id = p_message_id;

  return v_final;
end;
$$;

-- Replaying an inbound message re-queues the same payload — verified by hash to
-- be the same payload — and records why. The message keeps its history.
create or replace function erp.replay_message(p_message_id bigint, p_reason text)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_msg    erp.integration_message%rowtype;
begin
  perform erp.authorise('administration.integrate', null, null, null,
                        'integration_message', null);

  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception 'ERPWARE_REPLAY_NEEDS_REASON: a replay is an action '
      'somebody has to account for'
      using errcode = '23514';
  end if;

  select * into v_msg from erp.integration_message
   where tenant_id = v_tenant and id = p_message_id for update;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_MESSAGE: %', p_message_id using errcode = '23503';
  end if;

  if v_msg.direction <> 'inbound' then
    raise exception
      'ERPWARE_NOT_REPLAYABLE_HERE: an outbound message is replayed by replaying '
      'its command, so the second send is gated like the first'
      using errcode = '23514';
  end if;

  if v_msg.status = 'processing' then
    raise exception
      'ERPWARE_MESSAGE_IN_FLIGHT: % is being processed', p_message_id
      using errcode = '23514';
  end if;

  -- The hash is what makes this honest: it proves the replay carries the
  -- message as received, not as someone has since edited it.
  if erp.payload_hash(v_msg.payload, v_msg.payload_ref) <> v_msg.payload_hash then
    raise exception
      'ERPWARE_MESSAGE_TAMPERED: % no longer hashes to what was received; it '
      'cannot be replayed', p_message_id
      using errcode = '23514';
  end if;

  -- The reason rides on the message until the attempt it causes closes, so it
  -- lands on that attempt's record rather than on a row with no outcome.
  update erp.integration_message
     set status = 'queued', replays = replays + 1, next_attempt_at = now(),
         last_error = null, pending_replay_reason = p_reason
   where id = p_message_id;

  return p_message_id;
end;
$$;

comment on function erp.replay_message is
  'Spec Part 7: no un-replayable integration. Re-queues an inbound message, '
  'refusing if its payload no longer hashes to what arrived.';

-- -----------------------------------------------------------------------------
-- Registration and gates
-- -----------------------------------------------------------------------------

select erp_meta.register_table('erp_meta', 'command_transition', 'platform_internal',
  'The gateway lifecycle. Product behaviour; deliberately out of tenant reach.');
select erp_meta.register_table('erp', 'command', 'tenant_scoped',
  'Spec 4.9: the outbound intent. The only route to an external write.');
select erp_meta.register_table('erp', 'command_event', 'tenant_scoped_append_only',
  'Lifecycle events, written by trigger.');
select erp_meta.register_table('erp', 'integration_message', 'tenant_scoped',
  'Spec 4.9: the inbound and outbound message log.');
select erp_meta.register_table('erp', 'integration_message_attempt', 'tenant_scoped_append_only',
  'Every processing attempt, including replays and the reason for each.');

insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'command_event', 'Append-only lifecycle log carrying its own actor and timestamp.'),
  ('erp', 'integration_message_attempt', 'Append-only attempt history carrying its own actor and outcome.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_isolation();
