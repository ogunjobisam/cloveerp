-- =============================================================================
-- ERPWare — B8 (part 3/3): monitoring, replay surfaces and the invariant suite
-- Spec 5.11 ("integration monitoring with replay"), 4.9, Part 7
--
-- Two kinds of thing here, and it is worth being clear which is which.
--
-- The monitoring functions answer an operator's questions at three in the
-- morning: is anything stuck, how long has it been stuck, what did this command
-- actually do, and what do I press. They are read-only and they do not judge.
--
-- The invariant functions answer a different question, asked by the build:
-- could the gateway have been bypassed, weakened or told a lie? Each one
-- corresponds to a promise made in migration 0030's header, and each fails the
-- build rather than reporting a warning nobody reads.
--
-- The suite at the end is the part that matters. Every previous build step
-- found its real defects by writing adversarial cases rather than by reading
-- code, and there is no reason to expect this one to be different.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Monitoring (spec 5.11)
-- -----------------------------------------------------------------------------

create or replace function erp.integration_health()
returns table (
  system_code      text,
  system_status    erp.external_system_status,
  is_killed        boolean,
  queued           bigint,
  in_flight        bigint,
  leases_expired   bigint,
  failed_waiting   bigint,
  dead             bigint,
  awaiting_approval bigint,
  oldest_queued_age interval,
  last_success_at  timestamptz,
  last_failure_at  timestamptz,
  inbound_backlog  bigint,
  inbound_dead     bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    s.code,
    s.status,
    erp.is_killed('integration', s.code),
    count(*) filter (where c.status = 'queued'),
    count(*) filter (where c.status = 'in_flight'),
    -- A command whose worker never came back. Distinguished from healthy
    -- in-flight work because the two need completely different responses.
    count(*) filter (where c.status = 'in_flight' and c.lease_expires_at < now()),
    count(*) filter (where c.status = 'failed'),
    count(*) filter (where c.status = 'dead'),
    count(*) filter (where c.status = 'pending_approval'),
    max(now() - c.created_at) filter (where c.status = 'queued'),
    max(c.response_at) filter (where c.status = 'succeeded'),
    max(c.updated_at) filter (where c.status in ('failed', 'dead')),
    (select count(*) from erp.integration_message m
      where m.tenant_id = s.tenant_id and m.external_system_id = s.id
        and m.direction = 'inbound' and m.status in ('queued', 'failed', 'processing')),
    (select count(*) from erp.integration_message m
      where m.tenant_id = s.tenant_id and m.external_system_id = s.id
        and m.direction = 'inbound' and m.status = 'dead')
    from erp.external_system s
    left join erp.command c
      on c.tenant_id = s.tenant_id and c.external_system_id = s.id
   where s.tenant_id = erp.require_tenant_id()
   group by s.tenant_id, s.id, s.code, s.status
   order by s.code
$$;

comment on function erp.integration_health() is
  'Spec 5.11: integration monitoring. One row per configured system, with the '
  'numbers an operator needs before deciding whether to do anything.';

-- What needs a human, ranked by how long it has needed one.
create or replace function erp.integration_backlog(p_limit integer default 100)
returns table (
  kind           text,
  reference      text,
  system_code    text,
  operation      text,
  status         text,
  waiting_for    interval,
  attempts       integer,
  last_error     text,
  suggested_action text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select 'command', c.id::text, s.code, c.operation_code, c.status::text,
         now() - c.updated_at, c.attempts, c.last_error,
         case c.status
           when 'dead' then 'investigate, then erp.replay_command_linked() once fixed'
           when 'pending_approval' then 'an approver must decide'
           when 'in_flight' then 'erp.reclaim_expired_commands() — the worker did not report'
           else 'waiting on its backoff'
         end
    from erp.command c
    join t on t.tenant_id = c.tenant_id
    join erp.external_system s
      on s.tenant_id = c.tenant_id and s.id = c.external_system_id
   where c.status = 'dead'
      or c.status = 'pending_approval'
      or (c.status = 'in_flight' and c.lease_expires_at < now())
      or (c.status = 'failed' and c.next_attempt_at < now() - interval '15 minutes')
  union all
  select 'message', m.id::text, s.code, m.message_type, m.status::text,
         now() - coalesce(m.processed_at, m.received_at), m.attempts, m.last_error,
         case m.status
           when 'dead' then 'investigate, then erp.replay_message() once fixed'
           else 'waiting on its backoff'
         end
    from erp.integration_message m
    join t on t.tenant_id = m.tenant_id
    join erp.external_system s
      on s.tenant_id = m.tenant_id and s.id = m.external_system_id
   where m.direction = 'inbound'
     and (m.status = 'dead'
          or (m.status = 'failed' and m.next_attempt_at < now() - interval '15 minutes')
          or (m.status = 'processing' and m.claimed_at < now() - interval '1 hour'))
   order by 6 desc nulls last
   limit greatest(p_limit, 1)
$$;

comment on function erp.integration_backlog(integer) is
  'Everything an operator has to decide about, oldest first, each with the '
  'action that would resolve it.';

-- Everything that ever happened to one command, in one place: its lifecycle,
-- the messages it produced, the approval that gated it, and its replay lineage.
create or replace function erp.command_timeline(p_command_id uuid)
returns table (at timestamptz, source text, entry text, detail jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select e.occurred_at, 'lifecycle',
         format('%s -> %s', coalesce(e.from_status::text, 'created'), e.to_status),
         e.detail
    from erp.command_event e join t on t.tenant_id = e.tenant_id
   where e.command_id = p_command_id
  union all
  select m.received_at, 'message',
         format('%s %s', m.direction, m.message_type),
         jsonb_build_object('message_id', m.id, 'status', m.status,
                            'payload_hash', m.payload_hash)
    from erp.integration_message m join t on t.tenant_id = m.tenant_id
   where m.command_id = p_command_id
  union all
  select a.decided_at, 'approval',
         format('approval %s', a.status),
         jsonb_build_object('request_id', a.id, 'chain', a.approval_chain_id)
    from erp.approval_request a join t on t.tenant_id = a.tenant_id
   where a.object_type = 'integration.command'
     and a.object_id = p_command_id
     and a.decided_at is not null
  union all
  select r.created_at, 'replay',
         format('replayed as %s', r.id),
         jsonb_build_object('reason', r.replay_reason)
    from erp.command r join t on t.tenant_id = r.tenant_id
   where r.replay_of_command_id = p_command_id
   order by 1
$$;

comment on function erp.command_timeline(uuid) is
  'Spec 4.9 and 5.11: the whole story of one outbound intent — lifecycle, '
  'messages, approval and replays — without needing to know which four tables '
  'to join.';

-- -----------------------------------------------------------------------------
-- The invariants
--
-- One check per promise in migration 0030's header, plus the two credential
-- promises from 0028. Anything reported here is a defect, not a warning.
-- -----------------------------------------------------------------------------

create or replace function erp.gateway_integrity_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Structural: could the gateway be bypassed?
  --
  -- Every route to the outside world starts with an erp.command row, so a
  -- second table holding an outbound intent would be a second gateway. This
  -- catches the case where someone adds one.
  select 'a table other than erp.command holds dispatchable outbound intent',
         format('%s.%s', c.relnamespace::regnamespace::text, c.relname),
         'if this is an outbound queue it must go through erp.command'
    from pg_catalog.pg_class c
   where c.relkind = 'r'
     and c.relnamespace::regnamespace::text = 'erp'
     and c.relname <> 'command'
     and exists (select 1 from pg_catalog.pg_attribute a
                  where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                    and a.attname = 'idempotency_key')
  union all
  -- Structural: is the lifecycle guard still attached?
  select 'erp.command has no transition guard', 'erp.command',
         'the lifecycle would be whatever any UPDATE says it is'
   where not exists (
     select 1 from pg_catalog.pg_trigger tg
      where tg.tgrelid = 'erp.command'::regclass and not tg.tgisinternal
        and tg.tgfoid = 'erp.check_command_transition()'::regprocedure)
  union all
  -- Structural: is the credential guard still attached?
  select 'erp.external_system has no inline-credential guard', 'erp.external_system',
         'a connection document could carry a secret'
   where not exists (
     select 1 from pg_catalog.pg_trigger tg
      where tg.tgrelid = 'erp.external_system'::regclass and not tg.tgisinternal
        and tg.tgfoid = 'erp.reject_inline_credentials()'::regprocedure)
  union all
  -- Data: a dry run that reached a real terminal state, or the reverse.
  select 'a simulated command reached a live terminal state', c.id::text,
         format('dry_run = %s, status = %s', c.dry_run, c.status)
    from erp.command c
   where (c.dry_run and c.status = 'succeeded')
      or (not c.dry_run and c.status = 'simulated')
  union all
  -- Data: a credential in a stored connection or payload.
  select 'a stored connection contains a credential', s.code, f.path || ' — ' || f.finding
    from erp.external_system s
    cross join lateral erp.inline_credential_findings(s.connection) f
  union all
  select 'a command payload contains a credential', c.id::text, f.path || ' — ' || f.finding
    from erp.command c
    cross join lateral erp.inline_credential_findings(c.payload) f
  union all
  select 'a credential is stored where the reference should be', s.code, 'credential_ref'
    from erp.external_system s
   where s.credential_ref is not null
     and erp_ref.looks_like_secret(s.credential_ref)
  union all
  -- Data: a message that no longer hashes to what arrived.
  select 'a logged message no longer matches its hash', m.id::text,
         'the payload has been altered since receipt; it cannot be replayed'
    from erp.integration_message m
   where erp.payload_hash(m.payload, m.payload_ref) <> m.payload_hash
  union all
  -- Data: an external reference pointing at a system that no longer enables it.
  select 'an external reference is in conflict without detail', r.id::text,
         'sync_state is conflict but conflict_detail is null'
    from erp.external_ref r
   where r.sync_state = 'conflict' and r.conflict_detail is null
  union all
  -- Data: a command in flight for longer than any plausible lease.
  select 'a command has been in flight for over a day', c.id::text,
         format('claimed by %s at %s', coalesce(c.claimed_by, 'unknown'), c.claimed_at)
    from erp.command c
   where c.status = 'in_flight' and c.claimed_at < now() - interval '1 day'
$$;

comment on function erp.gateway_integrity_report() is
  'One check per promise the write gateway makes. Structural checks catch the '
  'guard being removed; data checks catch it having been wrong.';

create or replace function erp.assert_gateway_integrity()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.gateway_integrity_report();

  if v_count > 0 then
    raise exception 'ERPWARE_GATEWAY_INTEGRITY: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  return '';
end;
$$;

-- -----------------------------------------------------------------------------
-- Illustrative product content
--
-- Spec 6.3: "The product's own documentation uses neutral illustrative examples
-- only." This adapter talks to nothing. It exists so the gateway has something
-- to be tested against and so an integration author has a worked example of
-- what a contract looks like, in the same spirit as the example_vat legislation
-- pack in B5.
-- -----------------------------------------------------------------------------

insert into erp_ref.adapter (
  code, version, name_key, description, direction, transport,
  connection_schema, credential_contract, honours_idempotency, supports_dry_run)
values (
  'example_http', 1, 'adapter.example_http',
  'A neutral illustrative adapter. Talks to nothing; exists as a worked '
  'example of the contract and as the fixture the gateway suite runs against.',
  'bidirectional', 'http',
  jsonb_build_object(
    'type', 'object',
    'required', jsonb_build_array('base_url'),
    'additionalProperties', false,
    'properties', jsonb_build_object(
      'base_url', jsonb_build_object('type', 'string', 'format', 'uri'),
      'timeout_ms', jsonb_build_object('type', 'integer', 'minimum', 100),
      'tenant_header', jsonb_build_object('type', 'string'))),
  jsonb_build_object(
    'kind', 'oauth2_client_credentials',
    'fields', jsonb_build_array('client_id', 'client_secret'),
    'note', 'Resolved by the dispatch worker from credential_ref at send time.'),
  true, true)
on conflict (code, version) do nothing;

insert into erp_ref.adapter_operation (
  adapter_code, adapter_version, code, name_key, description, is_mutating,
  request_schema, response_schema, supports_dry_run, default_ordering_key_path)
values
  ('example_http', 1, 'order.create', 'adapter.example_http.order_create',
   'Creates an order on the counterpart. Mutating, simulatable, ordered by '
   'the order reference so amendments cannot overtake the creation.',
   true,
   jsonb_build_object(
     'type', 'object',
     'required', jsonb_build_array('order_ref', 'lines'),
     'properties', jsonb_build_object(
       'order_ref', jsonb_build_object('type', 'string', 'minLength', 1),
       'lines', jsonb_build_object('type', 'array', 'minItems', 1))),
   jsonb_build_object('type', 'object'),
   true, 'order_ref'),
  ('example_http', 1, 'order.read', 'adapter.example_http.order_read',
   'Reads an order. Not mutating, so it never needs approval.',
   false,
   jsonb_build_object(
     'type', 'object',
     'required', jsonb_build_array('order_ref'),
     'properties', jsonb_build_object(
       'order_ref', jsonb_build_object('type', 'string'))),
   jsonb_build_object('type', 'object'),
   false, null),
  ('example_http', 1, 'payment.instruct', 'adapter.example_http.payment_instruct',
   'Instructs a payment. Mutating and deliberately not simulatable: an adapter '
   'may support dry run for one operation and not for another, and this is the '
   'kind of operation where a convincing simulation is worse than none.',
   true,
   jsonb_build_object(
     'type', 'object',
     'required', jsonb_build_array('payee_ref', 'amount_minor', 'currency'),
     'properties', jsonb_build_object(
       'payee_ref', jsonb_build_object('type', 'string'),
       'amount_minor', jsonb_build_object('type', 'integer', 'minimum', 1),
       'currency', jsonb_build_object('type', 'string', 'pattern', '^[A-Z]{3}$'))),
   jsonb_build_object('type', 'object'),
   false, null)
on conflict (adapter_code, adapter_version, code) do nothing;

insert into erp_ref.resource (key, locale, value) values
  ('adapter.example_http', 'en', 'Illustrative HTTP adapter'),
  ('adapter.example_http.order_create', 'en', 'Create order'),
  ('adapter.example_http.order_read', 'en', 'Read order'),
  ('adapter.example_http.payment_instruct', 'en', 'Instruct payment')
on conflict (key, locale) do nothing;

-- -----------------------------------------------------------------------------
-- The suite
-- -----------------------------------------------------------------------------

create or replace function erp_test.gateway_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid;
  v_other   uuid;
  v_svc     uuid;
  v_person  uuid;
  v_other_svc uuid;
  v_sys     uuid;
  v_draft   uuid;
  v_cmd     uuid;
  v_cmd2    uuid;
  v_replay  uuid;
  v_msg     bigint;
  v_msg2    bigint;
  v_status  erp.command_status;
  v_n       bigint;
  v_txt     text;
  v_auth    uuid := gen_random_uuid();
  r         erp.command%rowtype;
begin
  insert into erp.tenant (code, name, status)
  values ('zz-gw-' || substr(gen_random_uuid()::text, 1, 8), 'Gateway suite', 'active')
  returning id into v_tenant;
  insert into erp.tenant (code, name, status)
  values ('zz-gw2-' || substr(gen_random_uuid()::text, 1, 8), 'Gateway neighbour', 'active')
  returning id into v_other;

  perform erp.set_job_tenant(v_tenant);

  insert into erp.app_user (tenant_id, kind, status, display_name)
  values (v_tenant, 'service', 'active', 'Dispatch worker') returning id into v_svc;
  insert into erp.app_user (tenant_id, kind, status, display_name, email)
  values (v_tenant, 'person', 'active', 'A person', 'person@example.test')
  returning id into v_person;
  insert into erp.app_user (tenant_id, kind, status, display_name)
  values (v_other, 'service', 'active', 'Neighbour worker') returning id into v_other_svc;

  -- --- service principal context --------------------------------------------

  case_name := 'a trusted job session can act as a service principal';
  perform erp.set_job_principal(v_svc);
  passed := (erp.current_principal_id() = v_svc);
  detail := format('principal is %s', coalesce(erp.current_principal_id()::text, 'null'));
  return next;

  case_name := 'a job session cannot adopt a person';
  begin
    perform erp.set_job_principal(v_person);
    passed := false; detail := 'a job became a named human';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'a job session cannot adopt a principal of another tenant';
  begin
    perform erp.set_job_principal(v_other_svc);
    passed := false; detail := 'a job crossed the tenant boundary';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'a disabled service principal stops being usable at read time';
  perform erp.set_job_principal(v_svc);
  update erp.app_user set status = 'disabled' where id = v_svc;
  passed := (erp.current_principal_id() is null);
  detail := format('principal is %s', coalesce(erp.current_principal_id()::text, 'null'));
  update erp.app_user set status = 'active' where id = v_svc;
  return next;

  -- Grant the worker what it needs for the rest of the suite.
  insert into erp.role (tenant_id, code, name) values (v_tenant, 'integrator', 'Integrator');
  insert into erp.role_permission (tenant_id, role_id, permission_code)
  select v_tenant, r2.id, p.code
    from erp.role r2
    cross join (values ('administration.integrate'), ('administration.configure')) p(code)
   where r2.tenant_id = v_tenant and r2.code = 'integrator';
  insert into erp.user_role (tenant_id, app_user_id, role_id)
  select v_tenant, v_svc, r2.id from erp.role r2
   where r2.tenant_id = v_tenant and r2.code = 'integrator';

  -- --- the registry refuses credentials -------------------------------------

  case_name := 'a connection carrying a credential is refused';
  begin
    insert into erp.external_system (
      tenant_id, code, name, adapter_code, adapter_version, connection, status)
    values (v_tenant, 'bad', 'Bad', 'example_http', 1,
            jsonb_build_object('base_url', 'https://example.test',
                               'client_secret', 'hunter2-and-then-some'), 'active');
    passed := false; detail := 'a secret was stored in a connection';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'a secret pasted into credential_ref is refused';
  begin
    insert into erp.external_system (
      tenant_id, code, name, adapter_code, adapter_version, connection,
      credential_ref, status)
    values (v_tenant, 'bad2', 'Bad', 'example_http', 1,
            jsonb_build_object('base_url', 'https://example.test'),
            'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345', 'active');
    passed := false; detail := 'a secret was stored as a reference';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  case_name := 'a connection that does not satisfy the adapter schema is refused';
  begin
    insert into erp.external_system (
      tenant_id, code, name, adapter_code, adapter_version, connection, status)
    values (v_tenant, 'bad3', 'Bad', 'example_http', 1,
            jsonb_build_object('nonsense', true), 'active');
    passed := false; detail := 'an invalid connection was accepted';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  insert into erp.external_system (
    tenant_id, code, name, adapter_code, adapter_version, connection,
    credential_ref, status, max_in_flight, max_attempts, retry_backoff_seconds)
  values (v_tenant, 'counterpart', 'Counterpart', 'example_http', 1,
          jsonb_build_object('base_url', 'https://counterpart.example.test',
                             'timeout_ms', 5000),
          'vault://erpware/counterpart', 'active', 2, 3, 1)
  returning id into v_sys;

  -- --- the gateway refuses what it should -----------------------------------

  case_name := 'an operation nobody enabled is refused';
  begin
    perform erp.submit_command('counterpart', 'order.create',
      jsonb_build_object('order_ref', 'A1', 'lines', jsonb_build_array('x')));
    passed := false; detail := 'an un-enabled operation went through';
  exception when others then
    passed := (sqlerrm like '%OPERATION_NOT_ENABLED%'); detail := sqlerrm;
  end;
  return next;

  insert into erp.external_system_operation (
    tenant_id, external_system_id, operation_code, is_enabled)
  values (v_tenant, v_sys, 'order.create', true),
         (v_tenant, v_sys, 'order.read', true),
         (v_tenant, v_sys, 'payment.instruct', true);

  case_name := 'a payload that fails the request schema is refused';
  begin
    perform erp.submit_command('counterpart', 'order.create',
      jsonb_build_object('lines', jsonb_build_array('x')));
    passed := false; detail := 'an invalid payload was queued';
  exception when others then
    passed := (sqlerrm like '%INVALID_COMMAND_PAYLOAD%'); detail := sqlerrm;
  end;
  return next;

  case_name := 'a payload carrying a credential is refused';
  begin
    perform erp.submit_command('counterpart', 'order.create',
      jsonb_build_object('order_ref', 'A1', 'lines', jsonb_build_array('x'),
                         'api_key', 'some-live-looking-key'));
    passed := false; detail := 'a credential left in a payload';
  exception when others then
    passed := (sqlerrm like '%INLINE_CREDENTIAL%'); detail := sqlerrm;
  end;
  return next;

  case_name := 'an operation that cannot be simulated refuses a dry run';
  begin
    perform erp.submit_command('counterpart', 'payment.instruct',
      jsonb_build_object('payee_ref', 'P1', 'amount_minor', 100, 'currency', 'GBP'),
      true);
    passed := false; detail := 'a payment was "simulated"';
  exception when others then
    passed := (sqlerrm like '%DRY_RUN_UNSUPPORTED%'); detail := sqlerrm;
  end;
  return next;

  case_name := 'a system requiring approval with no chain fails closed';
  update erp.external_system set requires_approval = true where id = v_sys;
  begin
    perform erp.submit_command('counterpart', 'order.create',
      jsonb_build_object('order_ref', 'GATED', 'lines', jsonb_build_array('a')));
    passed := false;
    detail := 'a command that should have needed approval was sent unapproved';
  exception when others then
    passed := (sqlerrm like '%NO_APPROVAL_CHAIN%'); detail := sqlerrm;
  end;
  update erp.external_system set requires_approval = false where id = v_sys;
  return next;

  case_name := 'an operation may not opt out of an approval the system requires';
  update erp.external_system set requires_approval = true where id = v_sys;
  begin
    update erp.external_system_operation set requires_approval = false
     where external_system_id = v_sys and operation_code = 'order.create';
    passed := false; detail := 'a control was loosened at the narrower scope';
  exception when others then
    passed := (sqlerrm like '%CANNOT_WEAKEN_APPROVAL%'); detail := sqlerrm;
  end;
  update erp.external_system set requires_approval = false where id = v_sys;
  return next;

  -- --- the happy path -------------------------------------------------------

  case_name := 'a valid command is queued and takes its ordering key from the payload';
  v_cmd := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'SO-1', 'lines', jsonb_build_array('a')),
    false, null, null, 'document', gen_random_uuid());
  select * into r from erp.command where id = v_cmd;
  passed := (r.status = 'queued' and r.ordering_key = 'SO-1' and length(r.idempotency_key) = 64);
  detail := format('status %s, ordering key %s', r.status, coalesce(r.ordering_key, 'null'));
  return next;

  case_name := 'the same intent submitted twice is one command';
  v_cmd2 := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'SO-1', 'lines', jsonb_build_array('a')),
    false, r.idempotency_key);
  passed := (v_cmd2 = v_cmd);
  detail := case when v_cmd2 = v_cmd then 'deduplicated'
                 else format('two commands: %s and %s', v_cmd, v_cmd2) end;
  return next;

  case_name := 'reusing a key for a different payload is refused';
  begin
    perform erp.submit_command('counterpart', 'order.create',
      jsonb_build_object('order_ref', 'SO-1', 'lines', jsonb_build_array('a', 'b')),
      false, r.idempotency_key);
    passed := false; detail := 'a key was reused for a different intent';
  exception when others then
    passed := (sqlerrm like '%IDEMPOTENCY_CONFLICT%'); detail := sqlerrm;
  end;
  return next;

  case_name := 'the lifecycle is logged without anyone writing to the log';
  select count(*) into v_n from erp.command_event where command_id = v_cmd;
  passed := (v_n >= 3);
  detail := format('%s lifecycle events', v_n);
  return next;

  -- --- the gateway refuses to be edited -------------------------------------

  case_name := 'a queued command cannot have its payload changed';
  begin
    update erp.command set payload = jsonb_build_object('order_ref', 'SO-999',
                                                        'lines', jsonb_build_array('z'))
     where id = v_cmd;
    passed := false; detail := 'the payload was swapped after approval';
  exception when others then
    passed := (sqlerrm like '%COMMAND_IMMUTABLE%'); detail := sqlerrm;
  end;
  return next;

  case_name := 'a command cannot be turned into a dry run, or out of one';
  begin
    update erp.command set dry_run = true where id = v_cmd;
    passed := false; detail := 'the dry-run flag moved';
  exception when others then
    passed := (sqlerrm like '%DRY_RUN_IMMUTABLE%'); detail := sqlerrm;
  end;
  return next;

  case_name := 'an illegal status transition is refused';
  begin
    update erp.command set status = 'succeeded' where id = v_cmd;
    passed := false; detail := 'a queued command declared itself successful';
  exception when others then
    passed := (sqlerrm like '%ILLEGAL_COMMAND_TRANSITION%'); detail := sqlerrm;
  end;
  return next;

  -- --- dispatch -------------------------------------------------------------

  case_name := 'a worker claims the command and gets a lease';
  select count(*) into v_n from erp.claim_command_batch('counterpart', 10, 'worker-1');
  select * into r from erp.command where id = v_cmd;
  passed := (v_n = 1 and r.status = 'in_flight' and r.lease_expires_at > now()
             and r.attempts = 1);
  detail := format('claimed %s, status %s, attempts %s', v_n, r.status, r.attempts);
  return next;

  case_name := 'a second command on the same ordering key waits its turn';
  perform erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'SO-1', 'lines', jsonb_build_array('b')));
  select count(*) into v_n from erp.claim_command_batch('counterpart', 10, 'worker-2');
  passed := (v_n = 0);
  detail := format('%s claimed while SO-1 is in flight', v_n);
  return next;

  case_name := 'completing the command records the response and links the external id';
  v_status := erp.complete_command(v_cmd, jsonb_build_object('id', 'EXT-1'), 'EXT-1');
  select * into r from erp.command where id = v_cmd;
  passed := (v_status = 'succeeded' and r.lease_expires_at is null
             and erp.external_id_for('counterpart', 'document', r.source_object_id) = 'EXT-1');
  detail := format('status %s, external id %s', v_status,
                   coalesce(erp.external_id_for('counterpart', 'document', r.source_object_id), 'none'));
  return next;

  case_name := 'the queue behind the ordering key moves once the first is done';
  select count(*) into v_n from erp.claim_command_batch('counterpart', 10, 'worker-1');
  passed := (v_n = 1);
  detail := format('%s claimed', v_n);
  return next;

  -- --- failure, backoff and death -------------------------------------------

  case_name := 'a failure goes back to the queue with a backoff, not to the wire';
  select c.id into v_cmd2 from erp.command c
   where c.tenant_id = v_tenant and c.status = 'in_flight' limit 1;
  v_status := erp.fail_command(v_cmd2, 'counterpart returned 503');
  select * into r from erp.command where id = v_cmd2;
  passed := (v_status = 'failed' and r.status = 'queued' and r.next_attempt_at > now());
  detail := format('returned %s, now %s, next attempt in %s',
                   v_status, r.status, r.next_attempt_at - now());
  return next;

  case_name := 'a command out of attempts is dead, not retried forever';
  update erp.command set next_attempt_at = now() where id = v_cmd2;
  perform erp.claim_command_batch('counterpart', 10, 'worker-1');
  perform erp.fail_command(v_cmd2, 'still 503');
  update erp.command set next_attempt_at = now() where id = v_cmd2;
  perform erp.claim_command_batch('counterpart', 10, 'worker-1');
  v_status := erp.fail_command(v_cmd2, 'still 503');
  passed := (v_status = 'dead');
  detail := format('after 3 attempts: %s', v_status);
  return next;

  -- --- dry run --------------------------------------------------------------

  case_name := 'a dry run terminates at simulated and never at succeeded';
  v_draft := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'SIM-1', 'lines', jsonb_build_array('a')), true);
  update erp.command set next_attempt_at = now() where id = v_draft;
  perform erp.claim_command_batch('counterpart', 10, 'worker-1');
  v_status := erp.complete_command(v_draft, jsonb_build_object('would_create', true));
  passed := (v_status = 'simulated');
  detail := format('status %s', v_status);
  return next;

  case_name := 'a simulated command cannot be forced to succeeded';
  begin
    update erp.command set status = 'succeeded' where id = v_draft;
    passed := false; detail := 'a simulation became a real send';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- --- the kill switch ------------------------------------------------------

  case_name := 'a kill switch stops dispatch without discarding anything';
  perform erp.submit_command('counterpart', 'order.read',
    jsonb_build_object('order_ref', 'SO-2'));
  perform erp.set_kill_switch('integration', 'counterpart', 'suite');
  select count(*) into v_n from erp.claim_command_batch('counterpart', 10, 'worker-1');
  select count(*) into v_msg from erp.command
   where tenant_id = v_tenant and status = 'queued';
  passed := (v_n = 0 and v_msg > 0);
  detail := format('%s claimed, %s still queued and waiting', v_n, v_msg);
  perform erp.clear_kill_switch('integration', 'counterpart');
  return next;

  case_name := 'a per-operation kill switch stops one verb, not the connection';
  perform erp.set_kill_switch('command_class', 'order.read', 'suite');
  select count(*) into v_n from erp.claim_command_batch('counterpart', 10, 'worker-1');
  passed := (v_n = 0);
  detail := format('%s claimed while order.read is killed', v_n);
  perform erp.clear_kill_switch('command_class', 'order.read');
  return next;

  -- --- the lease ------------------------------------------------------------

  case_name := 'an expired lease returns the command to the queue';
  perform erp.claim_command_batch('counterpart', 10, 'worker-gone');
  update erp.command set lease_expires_at = now() - interval '1 minute'
   where tenant_id = v_tenant and status = 'in_flight';
  v_n := erp.reclaim_expired_commands('counterpart');
  passed := (v_n > 0);
  detail := format('%s reclaimed', v_n);
  return next;

  -- --- replay ---------------------------------------------------------------

  case_name := 'a replay needs a reason';
  begin
    perform erp.replay_command_linked(v_cmd, 'x');
    passed := false; detail := 'a replay went through unexplained';
  exception when others then
    passed := (sqlerrm like '%REPLAY_NEEDS_REASON%'); detail := sqlerrm;
  end;
  return next;

  case_name := 'a command still in the queue cannot be replayed';
  select c.id into v_cmd2 from erp.command c
   where c.tenant_id = v_tenant and c.status = 'queued' limit 1;
  begin
    perform erp.replay_command_linked(v_cmd2, 'testing the refusal');
    passed := false; detail := 'a queued command was replayed, so it will send twice';
  exception when others then
    passed := (sqlerrm like '%COMMAND_NOT_TERMINAL%'); detail := sqlerrm;
  end;
  return next;

  case_name := 'a replay creates a new command and leaves the original intact';
  v_replay := erp.replay_command_linked(v_cmd, 'counterpart lost the order');
  select * into r from erp.command where id = v_replay;
  passed := (v_replay <> v_cmd
             and r.replay_of_command_id = v_cmd
             and r.payload = (select payload from erp.command where id = v_cmd)
             and r.idempotency_key <> (select idempotency_key from erp.command where id = v_cmd)
             and (select status from erp.command where id = v_cmd) = 'succeeded');
  detail := format('replay %s of %s, original still %s', v_replay, v_cmd,
                   (select status from erp.command where id = v_cmd));
  return next;

  -- --- inbound messages -----------------------------------------------------

  case_name := 'the same webhook delivered twice is one message';
  v_msg := erp.record_inbound_message('counterpart', 'order.updated',
    jsonb_build_object('order_ref', 'SO-1', 'state', 'shipped'), 'DELIVERY-1');
  v_msg2 := erp.record_inbound_message('counterpart', 'order.updated',
    jsonb_build_object('order_ref', 'SO-1', 'state', 'shipped'), 'DELIVERY-1');
  passed := (v_msg = v_msg2);
  detail := case when v_msg = v_msg2 then 'deduplicated'
                 else format('two messages: %s and %s', v_msg, v_msg2) end;
  return next;

  case_name := 'an inbound message is claimed, fails, and keeps its attempt history';
  perform erp.claim_message_batch('counterpart', 10, 'worker-1');
  perform erp.fail_message(v_msg, 'could not resolve the order');
  select count(*) into v_n from erp.integration_message_attempt
   where message_id = v_msg;
  passed := (v_n = 1);
  detail := format('%s attempt recorded', v_n);
  return next;

  case_name := 'a replay records why, and the reason lands on the attempt it caused';
  update erp.integration_message set next_attempt_at = now() where id = v_msg;
  perform erp.replay_message(v_msg, 'the order exists now');
  perform erp.claim_message_batch('counterpart', 10, 'worker-1');
  perform erp.complete_message(v_msg);
  select a.replay_reason into v_txt from erp.integration_message_attempt a
   where a.message_id = v_msg and a.is_replay;
  passed := (v_txt = 'the order exists now');
  detail := format('replay reason on the attempt: %s', coalesce(v_txt, 'none'));
  return next;

  case_name := 'a message whose payload was altered cannot be replayed';
  update erp.integration_message
     set payload = jsonb_build_object('order_ref', 'SO-1', 'state', 'tampered')
   where id = v_msg;
  begin
    perform erp.replay_message(v_msg, 'trying to replay altered content');
    passed := false; detail := 'altered content was replayed as if authentic';
  exception when others then
    passed := (sqlerrm like '%MESSAGE_TAMPERED%'); detail := sqlerrm;
  end;
  -- Put it back so the integrity assertion at the end of the migration is
  -- reporting on the product rather than on the suite's own vandalism.
  update erp.integration_message
     set payload = jsonb_build_object('order_ref', 'SO-1', 'state', 'shipped')
   where id = v_msg;
  return next;

  case_name := 'an outbound message is not replayable on its own';
  v_msg2 := erp.record_outbound_message(v_cmd);
  begin
    perform erp.replay_message(v_msg2, 'trying the wrong route');
    passed := false; detail := 'an outbound send was repeated without the gateway';
  exception when others then
    passed := (sqlerrm like '%NOT_REPLAYABLE_HERE%'); detail := sqlerrm;
  end;
  return next;

  -- --- monitoring and integrity ---------------------------------------------

  case_name := 'the health view reports this system';
  select h.queued + h.dead + h.in_flight into v_n
    from erp.integration_health() h where h.system_code = 'counterpart';
  passed := (v_n is not null);
  detail := format('%s commands in non-terminal or dead states', coalesce(v_n, -1));
  return next;

  case_name := 'the timeline of a replayed command shows its whole story';
  select count(*) into v_n from erp.command_timeline(v_cmd);
  passed := (v_n >= 4);
  detail := format('%s timeline entries', v_n);
  return next;

  case_name := 'the gateway integrity assertion holds';
  begin
    perform erp.assert_gateway_integrity();
    passed := true; detail := 'no findings';
  exception when others then
    passed := false; detail := sqlerrm;
  end;
  return next;

  -- --- isolation ------------------------------------------------------------

  case_name := 'a command cannot be submitted against another tenant''s system';
  begin
    perform erp.set_job_tenant(v_other);
    perform erp.set_job_principal(null);
    perform erp.submit_command('counterpart', 'order.read',
      jsonb_build_object('order_ref', 'SO-1'));
    passed := false; detail := 'a neighbour reached this tenant''s counterpart';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  perform erp.set_job_tenant(v_tenant);
  perform erp.set_job_principal(v_svc);
  return next;

  -- Everything above runs as the migration owner, which holds BYPASSRLS, so it
  -- proves the gateway's own refusals and nothing whatever about row-level
  -- security. The first draft of this suite ended with a cross-tenant count
  -- taken in that privileged session; it reported five visible commands and was
  -- right to, because RLS was never in the path.
  --
  -- To test isolation the session has to stop being privileged. Become the
  -- neighbour, for real: the authenticated role, with a JWT subject that
  -- resolves through erp.app_user to the neighbouring tenant and nothing else.
  insert into erp.app_user (tenant_id, auth_user_id, kind, status,
                            display_name, email)
  values (v_other, v_auth, 'person', 'active', 'Neighbour',
          'neighbour@example.test');

  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', v_auth, 'role', 'authenticated')::text);
  set local role authenticated;

  case_name := 'a real neighbouring session resolves to its own tenant';
  passed := (erp.current_tenant_id() = v_other);
  detail := format('resolved to %s', coalesce(erp.current_tenant_id()::text, 'null'));
  return next;

  case_name := 'a real neighbouring session sees none of these commands';
  select count(*) into v_n from erp.command;
  passed := (v_n = 0);
  detail := format('neighbour sees %s commands', v_n);
  return next;

  case_name := 'a real neighbouring session sees none of these external systems';
  select count(*) into v_n from erp.external_system;
  passed := (v_n = 0);
  detail := format('neighbour sees %s systems', v_n);
  return next;

  case_name := 'a real neighbouring session sees none of these messages';
  select count(*) into v_n from erp.integration_message;
  passed := (v_n = 0);
  detail := format('neighbour sees %s messages', v_n);
  return next;

  case_name := 'a real neighbouring session cannot submit through this gateway';
  begin
    perform erp.submit_command('counterpart', 'order.read',
      jsonb_build_object('order_ref', 'SO-1'));
    passed := false; detail := 'a neighbour reached the counterpart';
  exception when others then
    passed := true; detail := sqlerrm;
  end;
  return next;

  -- Positive control. If the cases above passed because the session could see
  -- nothing at all, they would prove nothing.
  case_name := 'positive control: the neighbour can see its own principal row';
  select count(*) into v_n from erp.app_user where auth_user_id = v_auth;
  passed := (v_n = 1);
  detail := format('%s row(s) of its own visible', v_n);
  return next;

  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  -- --- cleanup --------------------------------------------------------------
  --
  -- One tenant at a time: erp.begin_tenant_purge() takes the tenant it is
  -- opening the window for, deliberately, so a purge can never span two.

  perform erp.set_job_principal(null);

  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();

  perform erp.begin_tenant_purge(v_other);
  delete from erp.tenant where id = v_other;
  perform erp.end_tenant_purge();

  perform set_config('erp.job_tenant_id', '', true);
end;
$$;

comment on function erp_test.gateway_suite() is
  'Adversarial cases against the write gateway. Every refusal in migration '
  '0030''s header has a case here that tries to get past it.';

create or replace function erp_test.assert_gateway_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where not r.passed),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_total, v_failed, v_detail
    from erp_test.gateway_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_GATEWAY_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;

  return format('write gateway: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.gateway_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_gateway_suite() from public, anon, authenticated;

select erp.assert_resource_coverage();
select erp.assert_gateway_integrity();

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_isolation();
