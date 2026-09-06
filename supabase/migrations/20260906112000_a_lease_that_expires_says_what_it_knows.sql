-- A lease that expires says what it knows.
--
-- A worker claims a command, takes a lease, sends the request, and settles the
-- command with what came back. Kill the worker between the send and the
-- settle and the gateway knew nothing: the lease expired, the reclaimer put the
-- command back in the queue, and the next worker sent it again. The only thing
-- standing between that and a duplicate external write was the counterpart
-- honouring an idempotency key. D19 promised an explicit ambiguous state for
-- exactly this; 20260906111000 gave the enum the value; this file gives it the
-- behaviour.
--
-- The rule. A command records the moment its request left (erp.mark_command_sent,
-- a database write before the wire). When a lease expires the reclaimer reads
-- that mark: a request that had not left goes back to the queue with the same
-- backoff a failure gets, or dies when its attempts are spent; a request that
-- had left becomes `ambiguous` — not retried, not failed, waiting for a person
-- who can ask the counterpart. A worker that sent a request and got no answer
-- at all (a timeout, a reset) says so itself. An ambiguous command keeps its
-- ordering key blocked, so nothing overtakes a write whose outcome is unknown;
-- erp.reconcile_ambiguous_command() is how an operator settles it, with
-- evidence, as succeeded, dead, or back to the queue. And the ordering gate no
-- longer lets a successor past a predecessor that is merely waiting on a
-- backoff: an earlier command on the key that is queued, in flight or ambiguous
-- blocks; expiry is the reclaimer's job, not the gate's.
--
-- The same holds for the other two queues, which had no lease at all. A
-- message a worker claimed and never settled sat in `processing` for ever
-- (nothing could settle it: complete and fail both demand `processing` and
-- only a worker holding it would call them); an email claimed and never sent
-- sat in `sending`. Both now carry who claimed them and until when, and
-- erp.reclaim_stuck_messages() / erp.reclaim_stuck_email() return them the way
-- the command reclaimer does. erp.reclaim_stranded_work() runs all four
-- reclaimers for an organisation; the minute pass runs it before it runs jobs
-- and the worker runs it before it drains, so stranded work is reclaimed
-- wherever anything drains at all — the two existing reclaimers were
-- registered as handlers and scheduled by nothing.
--
-- erp.record_outbound_message() stays uncalled: the sent mark and the
-- command's own event log carry what a reconciliation needs.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What a command knows about its own request
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.command
  add column if not exists sent_at timestamptz,
  add column if not exists reconciled_at timestamptz,
  add column if not exists reconciliation_note text;
alter table erp.command drop constraint if exists command_ambiguous_was_sent;
alter table erp.command add constraint command_ambiguous_was_sent
  check (status <> 'ambiguous' or sent_at is not null);
create index if not exists command_ambiguous_idx
  on erp.command (tenant_id, external_system_id, ordering_key) where status = 'ambiguous';
comment on column erp.command.sent_at is
  'When the worker handed the request to the wire; written before the send, so an expired lease can tell a request that left from one that did not.';

insert into erp_meta.command_transition (from_status, to_status, note) values
  ('in_flight', 'ambiguous', 'the lease expired, or the worker got no answer, after the request was sent; the outcome is unknown'),
  ('ambiguous', 'succeeded', 'an operator confirmed the counterpart accepted it'),
  ('ambiguous', 'dead',      'an operator confirmed it did not happen and it is not to be sent again blindly'),
  ('ambiguous', 'queued',    'an operator confirmed it did not happen; it may be sent again')
on conflict do nothing;

create or replace function erp.mark_command_sent(p_command_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  update erp.command
     set sent_at = now()
   where tenant_id = v_tenant and id = p_command_id and status = 'in_flight' and sent_at is null;
  if not found then
    raise exception 'CLOVEERP_COMMAND_NOT_IN_FLIGHT: % is not a claimed, unsent command', p_command_id
      using errcode = '23514',
            hint = 'Mark a command sent once, after claiming it and before handing the request to the wire.';
  end if;
end;
$$;
revoke all on function erp.mark_command_sent(uuid) from public, anon, authenticated;

create or replace function erp.mark_command_ambiguous(p_command_id uuid, p_error text)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cmd    erp.command%rowtype;
begin
  select * into v_cmd from erp.command where tenant_id = v_tenant and id = p_command_id for update;
  if v_cmd.id is null or v_cmd.status <> 'in_flight' then
    raise exception 'CLOVEERP_COMMAND_NOT_IN_FLIGHT: % is %; only a claimed command can be ambiguous', p_command_id, coalesce(v_cmd.status::text, 'unknown')
      using errcode = '23514',
            hint = 'Only the worker holding the lease says the outcome is unknown.';
  end if;
  if v_cmd.sent_at is null then
    raise exception 'CLOVEERP_COMMAND_NOT_SENT: nothing was sent for %, so the outcome is known', p_command_id
      using errcode = '23514',
            hint = 'A request that never left has failed; call erp.fail_command().';
  end if;
  -- claimed_by stays: the transition log names the worker from it.
  update erp.command
     set status = 'ambiguous', lease_expires_at = null, claimed_at = null, last_error = p_error
   where id = p_command_id;
end;
$$;
revoke all on function erp.mark_command_ambiguous(uuid, text) from public, anon, authenticated;

-- The reclaimer, re-emitted over the mark. The deployed body is asserted first.
do $reclaim$
declare v_def text := pg_get_functiondef('erp.reclaim_expired_commands(text)'::regprocedure);
begin
  if position('last_error = format(''lease expired at %s; worker %s did not report'',' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.reclaim_expired_commands is not the body this migration re-emits';
  end if;
end
$reclaim$;

create or replace function erp.reclaim_expired_commands(p_system_code text default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_count  integer := 0;
begin
  for r in
    select c.id, c.sent_at, c.claimed_by, c.lease_expires_at, c.attempts, c.max_attempts,
           s.retry_backoff_seconds
      from erp.command c
      join erp.external_system s on s.tenant_id = c.tenant_id and s.id = c.external_system_id
     where c.tenant_id = v_tenant
       and c.status = 'in_flight'
       and c.lease_expires_at < now()
       and (p_system_code is null or s.code = p_system_code)
     for update of c skip locked
  loop
    if r.sent_at is not null then
      -- The request left. Nobody knows what the counterpart did with it, and
      -- sending it again would be a guess with a duplicate write on one side.
      update erp.command
         set status = 'ambiguous', lease_expires_at = null, claimed_at = null,
             last_error = format('the request was sent at %s and worker %s did not report by %s; outcome unknown',
                                 r.sent_at, coalesce(r.claimed_by, 'unknown'), r.lease_expires_at)
       where id = r.id;
    elsif r.attempts >= r.max_attempts then
      update erp.command
         set status = 'dead', claimed_by = null, claimed_at = null, lease_expires_at = null,
             last_error = format('lease expired at %s; worker %s did not report; out of attempts',
                                 r.lease_expires_at, coalesce(r.claimed_by, 'unknown'))
       where id = r.id;
    else
      -- Nothing left; the claim cost an attempt, so the retry waits the same
      -- backoff a failure would, rather than being claimable in the same second.
      update erp.command
         set status = 'queued', claimed_by = null, claimed_at = null, lease_expires_at = null,
             next_attempt_at = now() + least(
               make_interval(secs => r.retry_backoff_seconds * power(2, greatest(r.attempts, 1) - 1)),
               interval '1 hour'),
             last_error = format('lease expired at %s; worker %s did not report',
                                 r.lease_expires_at, coalesce(r.claimed_by, 'unknown'))
       where id = r.id;
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- The ordering gate: an earlier command on the key that is queued, in flight
-- or ambiguous blocks. Expiry is the reclaimer's, not the gate's.
do $gate$
declare
  v_def text := pg_get_functiondef('erp.claim_command_batch(text,integer,text,interval)'::regprocedure);
  v_n1  text := E'                     and f.status = ''in_flight''\n                     and f.lease_expires_at > now()))';
  v_n2  text := '           -- An ordering key with something already in flight waits its turn.';
  v_n3  text := E'         last_error = null\n   where c.id in (';
begin
  if position(v_n1 in v_def) = 0 or position(v_n2 in v_def) = 0 or position(v_n3 in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.claim_command_batch is not the body this migration patches';
  end if;
  -- A new claim is a new attempt, and a new attempt has not been sent.
  v_def := replace(v_def, v_n3, E'         last_error = null,\n         sent_at = null\n   where c.id in (');
  v_def := replace(v_def, v_n1,
    E'                     and f.global_seq < q.global_seq\n'
    || E'                     and f.status in (''queued'', ''in_flight'', ''ambiguous'')))');
  v_def := replace(v_def, v_n2,
    E'           -- An earlier command on the key that is queued, in flight or ambiguous\n'
    || E'           -- blocks; an expired lease is the reclaimer''s to settle, not the gate''s.');
  execute v_def;
end
$gate$;

create or replace function erp.reconcile_ambiguous_command(p_command_id uuid, p_outcome text, p_evidence text)
returns erp.command_status
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cmd    erp.command%rowtype;
  v_final  erp.command_status;
begin
  if coalesce(length(btrim(p_evidence)), 0) < 10 then
    raise exception 'CLOVEERP_RECONCILE_NEEDS_EVIDENCE: say what the counterpart showed'
      using errcode = '22023',
            hint = 'Quote the counterpart''s record, or its absence, in at least ten characters.';
  end if;
  select * into v_cmd from erp.command where tenant_id = v_tenant and id = p_command_id for update;
  if v_cmd.id is null then
    raise exception 'CLOVEERP_UNKNOWN_COMMAND: %', p_command_id using errcode = '23503',
      hint = 'Name a command of this organisation.';
  end if;
  if v_cmd.status <> 'ambiguous' then
    raise exception 'CLOVEERP_COMMAND_NOT_AMBIGUOUS: % is %; only an ambiguous command is reconciled', p_command_id, v_cmd.status
      using errcode = '23514',
            hint = 'A failed command is replayed with erp.replay_command_linked(); an in-flight one is settled by its worker.';
  end if;
  v_final := case p_outcome
               when 'succeeded' then 'succeeded'::erp.command_status
               when 'failed'    then 'dead'::erp.command_status
               when 'requeue'   then 'queued'::erp.command_status
             end;
  if v_final is null then
    raise exception 'CLOVEERP_RECONCILE_OUTCOME_UNKNOWN: % is not an outcome', coalesce(p_outcome, 'null')
      using errcode = '22023',
            hint = 'succeeded (the counterpart has it), failed (it did not happen and must not be sent blindly), or requeue (it did not happen; send it again).';
  end if;

  update erp.command
     set status = v_final,
         reconciled_at = now(),
         reconciliation_note = btrim(p_evidence),
         claimed_by = null,
         response_at = case when v_final = 'succeeded' then now() else response_at end,
         response = case when v_final = 'succeeded' then coalesce(response, '{}'::jsonb) else response end,
         sent_at = case when v_final = 'queued' then null else sent_at end,
         next_attempt_at = case when v_final = 'queued' then now() else next_attempt_at end,
         last_error = case when v_final = 'succeeded' then null else btrim(p_evidence) end
   where id = p_command_id;

  return v_final;
end;
$$;
revoke all on function erp.reconcile_ambiguous_command(uuid, text, text) from public, anon, authenticated;

drop function if exists public.erp_reconcile_ambiguous_command(uuid, text, text);
create function public.erp_reconcile_ambiguous_command(p_command_id uuid, p_outcome text, p_evidence text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare v_status erp.command_status;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'command', p_command_id);
  v_status := erp.reconcile_ambiguous_command(p_command_id, p_outcome, p_evidence);
  return jsonb_build_object('command_id', p_command_id, 'status', v_status);
end;
$$;
revoke all on function public.erp_reconcile_ambiguous_command(uuid, text, text) from public, anon;
grant execute on function public.erp_reconcile_ambiguous_command(uuid, text, text) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_reconcile_ambiguous_command', 'erp.authorise',
   'Settles a command whose outcome was unknown, with evidence from the counterpart; gated on administration.integrate.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The other two queues get a lease
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.integration_message
  add column if not exists claimed_by text,
  add column if not exists lease_expires_at timestamptz;
alter table erp.notification
  add column if not exists claimed_by text,
  add column if not exists claimed_at timestamptz,
  add column if not exists lease_expires_at timestamptz,
  add column if not exists send_attempts integer not null default 0;
alter table erp.notification drop constraint if exists notification_send_attempts_check;
alter table erp.notification add constraint notification_send_attempts_check check (send_attempts >= 0);

do $messages$
declare
  v_def text;
  v_n   text;
begin
  v_def := pg_get_functiondef('erp.claim_message_batch(text,integer,text)'::regprocedure);
  v_n := '     set status = ''processing'', attempts = m.attempts + 1, claimed_at = now()';
  if position(v_n in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.claim_message_batch is not the body this migration patches';
  end if;
  execute replace(v_def, v_n,
    E'     set status = ''processing'', attempts = m.attempts + 1, claimed_at = now(),\n'
    || E'         claimed_by = coalesce(p_worker, current_user), lease_expires_at = now() + interval ''5 minutes''');

  v_def := pg_get_functiondef('erp.complete_message(bigint)'::regprocedure);
  v_n := '     set status = ''processed'', processed_at = now(), last_error = null,';
  if position(v_n in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.complete_message is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_n || E'\n         claimed_by = null, lease_expires_at = null,');

  v_def := pg_get_functiondef('erp.fail_message(bigint,text,boolean)'::regprocedure);
  v_n := E'     set status = v_final,\n         last_error = p_error,';
  if position(v_n in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.fail_message is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, E'     set status = v_final, claimed_by = null, lease_expires_at = null,\n         last_error = p_error,');
end
$messages$;

create or replace function erp.reclaim_stuck_messages()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_msg    erp.integration_message%rowtype;
  v_final  erp.message_status;
  v_err    text;
  v_count  integer := 0;
begin
  for r in
    select m.id, s.max_attempts, s.retry_backoff_seconds
      from erp.integration_message m
      join erp.external_system s on s.tenant_id = m.tenant_id and s.id = m.external_system_id
     where m.tenant_id = v_tenant
       and m.status = 'processing'
       and coalesce(m.lease_expires_at, m.claimed_at + interval '5 minutes') < now()
     for update of m skip locked
  loop
    select * into v_msg from erp.integration_message where id = r.id;
    v_final := case when v_msg.attempts >= r.max_attempts then 'dead' else 'failed' end;
    v_err := format('claimed by %s at %s and never settled; lease expired at %s',
                    coalesce(v_msg.claimed_by, 'unknown'), v_msg.claimed_at,
                    coalesce(v_msg.lease_expires_at, v_msg.claimed_at + interval '5 minutes'));
    -- The attempt is closed the way a failure closes it, so the history says
    -- what happened rather than showing a gap.
    perform erp.close_message_attempt(v_msg, v_final, v_err);
    update erp.integration_message
       set status = v_final, last_error = v_err, claimed_by = null, lease_expires_at = null,
           next_attempt_at = now() + least(
             make_interval(secs => r.retry_backoff_seconds * power(2, greatest(v_msg.attempts, 1) - 1)),
             interval '1 hour')
     where id = r.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke all on function erp.reclaim_stuck_messages() from public, anon, authenticated;

-- The email claim gains the worker's name; a new signature, so the old one goes
-- first (an overload would make the worker's call ambiguous). The deployed body
-- is the Phase 5 patch, asserted before it is replaced.
do $email$
declare v_def text := pg_get_functiondef('erp.claim_email_batch(integer)'::regprocedure);
begin
  if position('erp.is_killed(''integration'', ''email'')' in v_def) = 0
     or position('m.severity::text' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.claim_email_batch is not the body this migration replaces';
  end if;
end
$email$;
drop function erp.claim_email_batch(integer);
create function erp.claim_email_batch(p_limit integer default 50, p_worker text default null)
returns table(id uuid, to_address text, subject text, body text, from_address text, reply_to text, severity text)
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if erp.is_killed('integration', 'email') then
    return;
  end if;

  -- The batch is marked 'sending' inside the claim, with who holds it and until
  -- when, so a worker that dies mid-flight leaves rows that are visibly stuck
  -- and reclaimable, rather than rows that look queued and get sent again.
  return query
  with claimed as (
    select n.id
      from erp.notification n
     where n.tenant_id = v_tenant
       and n.channel_kind = 'email'
       and n.status = 'queued'
     order by n.created_at
     limit greatest(p_limit, 1)
     for update skip locked
  ),
  marked as (
    update erp.notification n
       set status = 'sending',
           claimed_by = coalesce(p_worker, current_user),
           claimed_at = now(),
           lease_expires_at = now() + interval '5 minutes',
           send_attempts = n.send_attempts + 1
      from claimed c
     where n.id = c.id
     returning n.*
  )
  select m.id,
         u.email,
         m.subject,
         m.body,
         coalesce(m.sender, erp.sender_for('operational') ->> 'from_address'),
         erp.sender_for('operational') ->> 'reply_to',
         m.severity::text
    from marked m
    join erp.app_user u on u.id = m.app_user_id;
end;
$$;
revoke all on function erp.claim_email_batch(integer, text) from public, anon, authenticated;

do $settle$
declare
  v_def text;
  v_n   text;
begin
  v_def := pg_get_functiondef('erp.complete_email(uuid,text)'::regprocedure);
  v_n := '     set status = ''sent'', sent_at = now(), provider_message_id = p_provider_message_id,';
  if position(v_n in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.complete_email is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_n || E'\n         claimed_by = null, lease_expires_at = null,');

  v_def := pg_get_functiondef('erp.fail_email(uuid,text,boolean)'::regprocedure);
  if position('       set status = ''queued'', failure_reason = p_reason' in v_def) = 0
     or position('     set status = ''failed'', failure_reason = p_reason' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.fail_email is not the body this migration patches';
  end if;
  v_def := replace(v_def, '       set status = ''queued'', failure_reason = p_reason',
                          '       set status = ''queued'', failure_reason = p_reason, claimed_by = null, lease_expires_at = null');
  v_def := replace(v_def, '     set status = ''failed'', failure_reason = p_reason',
                          '     set status = ''failed'', failure_reason = p_reason, claimed_by = null, lease_expires_at = null');
  execute v_def;
end
$settle$;

create or replace function erp.reclaim_stuck_email()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
  v_count  integer := 0;
begin
  for r in
    select n.id, n.claimed_by, n.lease_expires_at, n.created_at, n.send_attempts
      from erp.notification n
     where n.tenant_id = v_tenant
       and n.channel_kind = 'email'
       and n.status = 'sending'
       and coalesce(n.lease_expires_at, n.created_at + interval '15 minutes') < now()
     for update skip locked
  loop
    -- Four abandonments go back to the queue; the fifth fails the message with
    -- its reason, and fail_email tells the person in-app, as it always has.
    perform erp.fail_email(r.id,
      format('claimed by %s and never settled; lease expired at %s',
             coalesce(r.claimed_by, 'unknown'),
             coalesce(r.lease_expires_at, r.created_at + interval '15 minutes')),
      r.send_attempts < 5);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke all on function erp.reclaim_stuck_email() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Stranded work is reclaimed wherever anything drains
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.reclaim_stranded_work()
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.require_tenant_id();
  return jsonb_build_object(
    'commands', erp.reclaim_expired_commands(),
    'runs',     erp.reclaim_timed_out_runs(),
    'messages', erp.reclaim_stuck_messages(),
    'email',    erp.reclaim_stuck_email());
end;
$$;
revoke all on function erp.reclaim_stranded_work() from public, anon, authenticated;
comment on function erp.reclaim_stranded_work is
  'Every reclaimer for one organisation: commands whose lease expired, runs that timed out, messages and email a worker abandoned.';

do $minute$
declare v_def text := pg_get_functiondef('erp.run_due_jobs_all_tenants(integer)'::regprocedure);
begin
  if position('perform set_config(''erp.job_principal_id'', '''', true);' in v_def) = 0
     or position('      v_res := erp.run_due_jobs(p_batch_size);' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.run_due_jobs_all_tenants is not the body this migration re-emits';
  end if;
end
$minute$;

create or replace function erp.run_due_jobs_all_tenants(p_batch_size integer default 25)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  t         record;
  v_res     jsonb;
  v_recl    jsonb;
  v_out     jsonb := '[]'::jsonb;
  v_tenants integer := 0;
  v_claimed integer := 0;
  v_ok      integer := 0;
  v_failed  integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not run every organisation''s jobs', current_user
      using errcode = '42501',
            hint = 'The scheduler runs this as the database owner; an organisation runs its own with erp.run_due_jobs().';
  end if;

  for t in select tn.id, tn.code from erp.tenant tn where tn.status = 'active' order by tn.code loop
    v_tenants := v_tenants + 1;
    perform set_config('erp.job_tenant_id', t.id::text, true);
    perform set_config('erp.job_principal_id', '', true);
    begin
      -- Stranded work first: a run or command a dead worker left behind is
      -- reclaimed before this pass claims anything new.
      v_recl := erp.reclaim_stranded_work();
      v_res := erp.run_due_jobs(p_batch_size);
      v_claimed := v_claimed + coalesce((v_res ->> 'claimed')::integer, 0);
      v_ok      := v_ok      + coalesce((v_res ->> 'succeeded')::integer, 0);
      v_failed  := v_failed  + coalesce((v_res ->> 'failed')::integer, 0);
      v_out := v_out || jsonb_build_array(jsonb_build_object('organisation', t.code, 'claimed', v_res -> 'claimed',
                                                             'succeeded', v_res -> 'succeeded', 'failed', v_res -> 'failed',
                                                             'reclaimed', v_recl));
    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object('organisation', t.code, 'error', left(sqlerrm, 200)));
    end;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);

  return jsonb_build_object('organisations', v_tenants, 'claimed', v_claimed, 'succeeded', v_ok,
                            'failed', v_failed, 'detail', v_out);
end;
$$;

insert into erp_ref.job_handler
  (code, name_key, description, parameter_schema, default_timeout_seconds, forbids_overlap, sql_function, default_max_silence_seconds) values
  ('platform.reclaim_stuck_messages', 'job_handler.reclaim_stuck_messages.name',
   'Returns inbound messages a worker claimed and never settled to retry, or to dead when their attempts are spent.',
   '{"type":"object","additionalProperties":false}'::jsonb, 300, true, 'reclaim_stuck_messages', 3600),
  ('platform.reclaim_stuck_email', 'job_handler.reclaim_stuck_email.name',
   'Returns email a worker claimed and never sent to the queue; the fifth abandonment fails it and tells the person in-app.',
   '{"type":"object","additionalProperties":false}'::jsonb, 300, true, 'reclaim_stuck_email', 3600),
  ('platform.reclaim_stranded_work', 'job_handler.reclaim_stranded_work.name',
   'Every reclaimer at once: expired command leases, timed-out runs, abandoned messages and email. The minute pass and the worker run it before they drain; this is for an operator who wants it on a schedule of its own.',
   '{"type":"object","additionalProperties":false}'::jsonb, 300, true, 'reclaim_stranded_work', 3600)
on conflict (code) do update
  set name_key = excluded.name_key, description = excluded.description, sql_function = excluded.sql_function,
      default_timeout_seconds = excluded.default_timeout_seconds, forbids_overlap = excluded.forbids_overlap,
      default_max_silence_seconds = excluded.default_max_silence_seconds;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('job_handler.reclaim_stuck_messages.name', 'en', 'Reclaim stuck messages', 'administration'),
  ('job_handler.reclaim_stuck_messages.name', 'de', 'Hängende Nachrichten zurückholen', 'administration'),
  ('job_handler.reclaim_stuck_email.name',    'en', 'Reclaim stuck email', 'administration'),
  ('job_handler.reclaim_stuck_email.name',    'de', 'Hängende E-Mails zurückholen', 'administration'),
  ('job_handler.reclaim_stranded_work.name',  'en', 'Reclaim stranded work', 'administration'),
  ('job_handler.reclaim_stranded_work.name',  'de', 'Liegengebliebene Arbeit zurückholen', 'administration')
on conflict (key, locale) do update set value = excluded.value;

-- Found on the way and recorded rather than redesigned here (finding 39 of
-- the programme's register): the worker's outbox pass delivers what
-- erp.claim_message_batch() hands it, and that function claims inbound
-- messages — so the "outbox" posts inbound webhooks back to the counterpart
-- that sent them. Nothing in the product has ever recorded an outbound
-- message. The pass gains a lease, a name and a key here; what it should
-- deliver is the gateway owner's question, and Phase 5 pinned the policy
-- register at no open decisions, so it is not opened as one.

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. What the reports say about it
-- ═════════════════════════════════════════════════════════════════════════════

do $reports$
declare
  v_def text;
  v_n   text;
begin
  v_def := pg_get_functiondef('erp.gateway_integrity_report()'::regprocedure);
  v_n := E'  select ''a command has been in flight for over a day'', c.id::text,\n'
      || E'         format(''claimed by %s at %s'', coalesce(c.claimed_by, ''unknown''), c.claimed_at)\n'
      || E'    from erp.command c\n'
      || E'   where c.status = ''in_flight'' and c.claimed_at < now() - interval ''1 day''';
  if position(v_n in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.gateway_integrity_report is not the body this migration patches';
  end if;
  execute replace(v_def, v_n,
       E'  select ''a command is an hour past its lease and nothing reclaimed it'', c.id::text,\n'
    || E'         format(''claimed by %s; lease expired at %s'', coalesce(c.claimed_by, ''unknown''), c.lease_expires_at)\n'
    || E'    from erp.command c\n'
    || E'   where c.status = ''in_flight'' and c.lease_expires_at < now() - interval ''1 hour''');

  v_def := pg_get_functiondef('erp.integration_backlog(integer)'::regprocedure);
  if position('           when ''in_flight'' then ''erp.reclaim_expired_commands() — the worker did not report''' in v_def) = 0
     or position('      or (c.status = ''in_flight'' and c.lease_expires_at < now())' in v_def) = 0
     or position('          or (m.status = ''processing'' and m.claimed_at < now() - interval ''1 hour''))' in v_def) = 0 then
    raise exception 'CLOVEERP_ENGINE_UNRECOGNISED: erp.integration_backlog is not the body this migration patches';
  end if;
  v_def := replace(v_def, '           when ''in_flight'' then ''erp.reclaim_expired_commands() — the worker did not report''',
       E'           when ''in_flight'' then ''erp.reclaim_expired_commands() — the worker did not report''\n'
    || E'           when ''ambiguous'' then ''erp.reconcile_ambiguous_command() — the request was sent and the outcome is unknown; ask the counterpart first''');
  v_def := replace(v_def, '      or (c.status = ''in_flight'' and c.lease_expires_at < now())',
       E'      or c.status = ''ambiguous''\n      or (c.status = ''in_flight'' and c.lease_expires_at < now())');
  v_def := replace(v_def, '          or (m.status = ''processing'' and m.claimed_at < now() - interval ''1 hour''))',
       '          or (m.status = ''processing'' and coalesce(m.lease_expires_at, m.claimed_at + interval ''1 hour'') < now()))');
  execute v_def;
end
$reports$;

create or replace function erp.stranded_work_report()
returns table(queue text, reference text, held_by text, since timestamptz, finding text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  select 'commands', c.id::text, c.claimed_by, c.lease_expires_at,
         'in flight past its lease; erp.reclaim_stranded_work() returns it'
    from erp.command c join t on t.tenant_id = c.tenant_id
   where c.status = 'in_flight' and c.lease_expires_at < now()
  union all
  select 'commands', c.id::text, c.claimed_by, c.sent_at,
         'ambiguous: the request was sent and the outcome is unknown; erp.reconcile_ambiguous_command() settles it'
    from erp.command c join t on t.tenant_id = c.tenant_id
   where c.status = 'ambiguous'
  union all
  select 'runs', r.id::text, r.worker, r.lease_expires_at,
         'running past its lease; erp.reclaim_stranded_work() times it out'
    from erp.job_run r join t on t.tenant_id = r.tenant_id
   where r.outcome = 'running' and r.lease_expires_at < now()
  union all
  select 'messages', m.id::text, m.claimed_by, coalesce(m.lease_expires_at, m.claimed_at + interval '5 minutes'),
         'processing past its lease; erp.reclaim_stranded_work() returns it to retry'
    from erp.integration_message m join t on t.tenant_id = m.tenant_id
   where m.status = 'processing' and coalesce(m.lease_expires_at, m.claimed_at + interval '5 minutes') < now()
  union all
  select 'email', n.id::text, n.claimed_by, coalesce(n.lease_expires_at, n.created_at + interval '15 minutes'),
         'sending past its lease; erp.reclaim_stranded_work() returns it to the queue'
    from erp.notification n join t on t.tenant_id = n.tenant_id
   where n.channel_kind = 'email' and n.status = 'sending'
     and coalesce(n.lease_expires_at, n.created_at + interval '15 minutes') < now()
   order by 4
$$;
revoke all on function erp.stranded_work_report() from public, anon, authenticated;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('stranded_work', 'Work a worker abandoned', 'report', 'tenant',
   'stranded_work_report', '', null, '',
   'Commands past their lease, commands whose outcome is unknown, runs that timed out, messages and email a worker claimed and never settled. Each names the call that settles it.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The gateway suite learns the new states
-- ═════════════════════════════════════════════════════════════════════════════

do $suite$
declare
  v_def text := pg_get_functiondef('erp_test.gateway_suite()'::regprocedure);
  v_decl text := '  r         erp.command%rowtype;';
  v_c31  text := E'  v_n := erp.reclaim_expired_commands(''counterpart'');\n'
              || E'  passed := (v_n > 0);\n'
              || E'  detail := format(''%s reclaimed'', v_n);';
  v_mark text := '  -- --- replay ---------------------------------------------------------------';
  v_new  text;
begin
  if position(v_decl in v_def) = 0 or position(v_c31 in v_def) = 0
     or (select count(*) from regexp_matches(v_def, '  -- --- replay -+', 'g')) <> 1 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.gateway_suite is not the body this migration patches';
  end if;

  v_def := replace(v_def, v_decl,
    v_decl || E'\n  v_amb uuid; v_amb2 uuid; v_succ uuid; v_dead uuid; v_dead2 uuid; v_rq1 uuid; v_rq2 uuid;');

  -- Case 31 says what a reclaim does, not only that it did something.
  v_def := replace(v_def, v_c31,
       E'  v_n := erp.reclaim_expired_commands(''counterpart'');\n'
    || E'  passed := (v_n > 0) and not exists (\n'
    || E'    select 1 from erp.command c where c.tenant_id = v_tenant and c.last_error like ''lease expired%''\n'
    || E'       and not ((c.status = ''queued'' and c.next_attempt_at > now() and c.claimed_by is null) or c.status = ''dead''));\n'
    || E'  detail := format(''%s reclaimed; each queued with a backoff or dead'', v_n);');

  v_new := $cases$
  -- --- an outcome that is unknown ------------------------------------------
  --
  -- Everything queued so far waits an hour, so the claims below pick the
  -- command each case just submitted.
  update erp.command set next_attempt_at = now() + interval '1 hour'
   where tenant_id = v_tenant and status = 'queued';

  case_name := 'a lease that expires after the request was sent leaves the command ambiguous, naming the worker';
  v_amb := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'AMB-1', 'lines', jsonb_build_array('a')));
  perform erp.claim_command_batch('counterpart', 1, 'worker-gone');
  perform erp.mark_command_sent(v_amb);
  update erp.command set lease_expires_at = now() - interval '1 minute' where id = v_amb;
  v_n := erp.reclaim_expired_commands('counterpart');
  select * into r from erp.command where id = v_amb;
  passed := (r.status = 'ambiguous' and r.sent_at is not null and r.lease_expires_at is null
             and r.claimed_by = 'worker-gone' and r.last_error like '%outcome unknown%'
             and exists (select 1 from erp.command_event e where e.command_id = v_amb
                          and e.to_status = 'ambiguous' and e.actor_label = 'worker-gone'));
  detail := format('status %s, sent %s, held by %s', r.status, r.sent_at is not null, coalesce(r.claimed_by, 'nobody'));
  return next;

  case_name := 'a successor on the same ordering key waits behind an ambiguous command';
  v_amb2 := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'AMB-1', 'lines', jsonb_build_array('b')));
  select count(*) into v_n from erp.claim_command_batch('counterpart', 1, 'worker-1');
  passed := (v_n = 0);
  detail := format('%s claimed while AMB-1 is ambiguous', v_n);
  return next;

  case_name := 'a worker that got no answer after sending marks the command ambiguous itself';
  v_succ := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'AMB-2', 'lines', jsonb_build_array('a')));
  perform erp.claim_command_batch('counterpart', 1, 'worker-1');
  perform erp.mark_command_sent(v_succ);
  perform erp.mark_command_ambiguous(v_succ, 'no answer within 30 s');
  select * into r from erp.command where id = v_succ;
  passed := (r.status = 'ambiguous' and r.last_error = 'no answer within 30 s' and r.claimed_by = 'worker-1');
  detail := format('status %s', r.status);
  return next;

  case_name := 'and may not when nothing was sent';
  v_dead := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'AMB-3', 'lines', jsonb_build_array('a')));
  perform erp.claim_command_batch('counterpart', 1, 'worker-1');
  begin
    perform erp.mark_command_ambiguous(v_dead, 'nothing left');
    passed := false; detail := 'an unsent command was marked ambiguous';
  exception when others then
    passed := (sqlerrm like '%COMMAND_NOT_SENT%'); detail := left(sqlerrm, 90);
  end;
  perform erp.fail_command(v_dead, 'nothing was sent', false);
  return next;

  case_name := 'reconciling as succeeded records the evidence and frees the key';
  v_status := erp.reconcile_ambiguous_command(v_amb, 'succeeded', 'the counterpart lists order AMB-1 as received');
  select * into r from erp.command where id = v_amb;
  select count(*) into v_n from erp.claim_command_batch('counterpart', 1, 'worker-1');
  passed := (v_status = 'succeeded' and r.status = 'succeeded' and r.reconciled_at is not null
             and r.reconciliation_note like 'the counterpart lists%' and v_n = 1);
  detail := format('reconciled to %s; %s successor claimed', r.status, v_n);
  perform erp.complete_command(v_amb2, '{}'::jsonb);
  return next;

  case_name := 'reconciliation is refused for a command that is not ambiguous';
  begin
    perform erp.reconcile_ambiguous_command(v_cmd, 'succeeded', 'it is already done');
    passed := false; detail := 'a settled command was reconciled';
  exception when others then
    passed := (sqlerrm like '%COMMAND_NOT_AMBIGUOUS%'); detail := left(sqlerrm, 90);
  end;
  return next;

  case_name := 'reconciling as requeue clears the sent mark and returns the command to the queue';
  v_status := erp.reconcile_ambiguous_command(v_succ, 'requeue', 'the counterpart has no record of AMB-2');
  select * into r from erp.command where id = v_succ;
  passed := (v_status = 'queued' and r.status = 'queued' and r.sent_at is null and r.attempts = 1
             and r.reconciliation_note like 'the counterpart has no record%');
  detail := format('status %s, sent %s, attempts %s', r.status, r.sent_at is not null, r.attempts);
  update erp.command set next_attempt_at = now() + interval '1 hour' where id = v_succ;
  return next;

  case_name := 'a lease that expires with attempts exhausted is dead';
  v_dead2 := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'DEAD-1', 'lines', jsonb_build_array('a')));
  update erp.command set attempts = 2 where id = v_dead2;
  perform erp.claim_command_batch('counterpart', 1, 'worker-gone');
  update erp.command set lease_expires_at = now() - interval '1 minute' where id = v_dead2;
  perform erp.reclaim_expired_commands('counterpart');
  select * into r from erp.command where id = v_dead2;
  passed := (r.status = 'dead' and r.attempts = 3 and r.last_error like '%out of attempts');
  detail := format('status %s after %s attempts', r.status, r.attempts);
  return next;

  case_name := 'a requeued predecessor still blocks its successor';
  v_rq1 := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'RQ-1', 'lines', jsonb_build_array('a')));
  v_rq2 := erp.submit_command('counterpart', 'order.create',
    jsonb_build_object('order_ref', 'RQ-1', 'lines', jsonb_build_array('b')));
  perform erp.claim_command_batch('counterpart', 1, 'worker-1');
  perform erp.fail_command(v_rq1, 'counterpart returned 503');
  select count(*) into v_n from erp.claim_command_batch('counterpart', 1, 'worker-1');
  select * into r from erp.command where id = v_rq1;
  passed := (v_n = 0 and r.status = 'queued' and r.next_attempt_at > now());
  detail := format('%s claimed while RQ-1 waits on its backoff', v_n);
  update erp.command set next_attempt_at = now() + interval '1 hour' where id in (v_rq1, v_rq2);
  return next;

$cases$;

  v_def := replace(v_def, v_mark, v_new || v_mark);
  execute v_def;
end
$suite$;

do $pin$
declare v_def text := pg_get_functiondef('erp_test.assert_gateway_suite()'::regprocedure);
begin
  if position('c_expected constant integer := 49;' in v_def) = 0
     or position('filter (where not coalesce(r.passed, false))' in v_def) = 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.assert_gateway_suite is not the null-strict wrapper this migration re-pins';
  end if;
  execute replace(v_def, 'c_expected constant integer := 49;', 'c_expected constant integer := 58;');
end
$pin$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The stranded-work suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.stranded_work_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_svc    uuid;
  v_person uuid;
  v_sys    uuid;
  v_msg    bigint;
  v_mail   uuid;
  v_n      integer;
  v_res    jsonb;
  m        erp.integration_message%rowtype;
  n        erp.notification%rowtype;
  i        integer;
begin
  insert into erp.tenant (code, name, status)
  values ('zz-sw-' || substr(gen_random_uuid()::text, 1, 8), 'Stranded work suite', 'active')
  returning id into v_tenant;
  perform erp.set_job_tenant(v_tenant);
  insert into erp.app_user (tenant_id, kind, status, display_name)
  values (v_tenant, 'service', 'active', 'Stranded worker') returning id into v_svc;
  insert into erp.app_user (tenant_id, kind, status, display_name, email)
  values (v_tenant, 'person', 'active', 'A person', 'person@zz-sw.test') returning id into v_person;
  perform erp.set_job_principal(v_svc);
  insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, status,
                                   max_in_flight, max_attempts, retry_backoff_seconds)
  values (v_tenant, 'stranded', 'Stranded', 'example_http', 1,
          jsonb_build_object('base_url', 'https://stranded.example.test'), 'active', 2, 2, 1)
  returning id into v_sys;

  -- 1
  v_msg := erp.record_inbound_message('stranded', 'order.updated',
             jsonb_build_object('order_ref', 'SW-1', 'state', 'shipped'), 'SW-DELIVERY-1');
  perform erp.claim_message_batch('stranded', 10, 'worker-gone');
  select * into m from erp.integration_message where id = v_msg;
  case_name := 'a claimed message says who holds it and until when';
  passed := (m.status = 'processing' and m.claimed_by = 'worker-gone' and m.lease_expires_at > now());
  detail := format('status %s, held by %s until %s', m.status, coalesce(m.claimed_by, 'nobody'), m.lease_expires_at);
  return next;

  -- 2
  update erp.integration_message set lease_expires_at = now() - interval '1 minute' where id = v_msg;
  v_n := erp.reclaim_stuck_messages();
  select * into m from erp.integration_message where id = v_msg;
  case_name := 'a message whose worker vanished goes back to retry with a backoff and its attempt recorded';
  passed := (v_n = 1 and m.status = 'failed' and m.next_attempt_at > now() and m.claimed_by is null
             and m.last_error like 'claimed by worker-gone%'
             and (select count(*) from erp.integration_message_attempt a where a.message_id = v_msg and a.outcome = 'failed') = 1);
  detail := format('%s reclaimed; status %s; %s attempt(s) recorded', v_n, m.status,
                   (select count(*) from erp.integration_message_attempt a where a.message_id = v_msg));
  return next;

  -- 3
  update erp.integration_message set next_attempt_at = now() where id = v_msg;
  perform erp.claim_message_batch('stranded', 10, 'worker-gone');
  update erp.integration_message set lease_expires_at = now() - interval '1 minute' where id = v_msg;
  v_n := erp.reclaim_stuck_messages();
  select * into m from erp.integration_message where id = v_msg;
  case_name := 'a message out of attempts is dead';
  passed := (v_n = 1 and m.status = 'dead' and m.attempts = 2);
  detail := format('status %s after %s attempts', m.status, m.attempts);
  return next;

  -- 4
  insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
  values (v_tenant, 'info', v_person, 'email', 'Stranded', 'A message a worker will abandon.', 'queued')
  returning id into v_mail;
  perform erp.claim_email_batch(50, 'worker-gone');
  select * into n from erp.notification where id = v_mail;
  case_name := 'a claimed email says who holds it';
  passed := (n.status = 'sending' and n.claimed_by = 'worker-gone' and n.lease_expires_at > now() and n.send_attempts = 1);
  detail := format('status %s, held by %s, attempt %s', n.status, coalesce(n.claimed_by, 'nobody'), n.send_attempts);
  return next;

  -- 5
  update erp.notification set lease_expires_at = now() - interval '1 minute' where id = v_mail;
  v_n := erp.reclaim_stuck_email();
  select * into n from erp.notification where id = v_mail;
  case_name := 'an email claimed and never settled returns to the queue';
  passed := (v_n = 1 and n.status = 'queued' and n.claimed_by is null and n.failure_reason like 'claimed by worker-gone and never settled%');
  detail := format('%s reclaimed; status %s; %s', v_n, n.status, left(coalesce(n.failure_reason, ''), 60));
  return next;

  -- 6
  for i in 1..4 loop
    perform erp.claim_email_batch(50, 'worker-gone');
    update erp.notification set lease_expires_at = now() - interval '1 minute' where id = v_mail;
    perform erp.reclaim_stuck_email();
  end loop;
  select * into n from erp.notification where id = v_mail;
  case_name := 'the fifth abandonment fails it with a reason and tells the person in-app';
  passed := (n.status = 'failed' and n.send_attempts = 5
             and exists (select 1 from erp.notification f where f.escalation_of = v_mail and f.channel_kind = 'in_app' and f.status = 'delivered'));
  detail := format('status %s after %s attempts; in-app fallback %s', n.status, n.send_attempts,
                   exists (select 1 from erp.notification f where f.escalation_of = v_mail));
  return next;

  -- 7
  v_res := erp.reclaim_stranded_work();
  case_name := 'reclaim_stranded_work answers for every queue';
  passed := (v_res ? 'commands' and v_res ? 'runs' and v_res ? 'messages' and v_res ? 'email');
  detail := v_res::text;
  return next;

  -- 8: read, not run — running the minute pass would visit every organisation.
  case_name := 'the minute pass reclaims before it runs jobs';
  passed := exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace ns on ns.oid = p.pronamespace
                     where ns.nspname = 'erp' and p.proname = 'run_due_jobs_all_tenants'
                       and position('erp.reclaim_stranded_work()' in p.prosrc) > 0
                       and position('erp.reclaim_stranded_work()' in p.prosrc) < position('erp.run_due_jobs(p_batch_size)' in p.prosrc));
  detail := 'erp.run_due_jobs_all_tenants calls erp.reclaim_stranded_work() before erp.run_due_jobs()';
  return next;

  -- 9
  perform erp.set_job_principal(null);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  perform set_config('erp.job_tenant_id', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.id = v_tenant);
  detail := 'organisation purged';
  return next;
end;
$$;
revoke all on function erp_test.stranded_work_suite() from public, anon, authenticated;

create or replace function erp_test.assert_stranded_work_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _stranded_work on commit drop as
    select * from erp_test.stranded_work_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _stranded_work;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_STRANDED_WORK_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_STRANDED_WORK_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('stranded work: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_stranded_work_suite() from public, anon, authenticated;

-- D19 is bound to what now exists.
update erp_ref.product_decision_check
   set note = 'The gateway suite exercises claim, complete, fail, dry run, approval, the ambiguous state a sent-then-lost request enters, and the reconciliation door that settles it.'
 where decision_code = 'D19' and schema_name = 'erp_test' and routine_name = 'assert_gateway_suite';
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note)
values ('D19', 'erp_test', 'assert_stranded_work_suite',
        'Messages and email a worker abandoned carry who held them and are reclaimed with a backoff, never re-sent in the same second, and the minute pass reclaims before it claims.')
on conflict do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_gateway_suite();
select erp_test.assert_stranded_work_suite();
select erp_test.assert_notification_chain_suite();
select erp_test.assert_email_delivery_suite();
select erp_test.assert_policy_register_suite();
select erp.assert_gateway_integrity();
select erp.assert_resource_coverage();
select erp.assert_resource_coverage_de();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_no_dead_configuration();
select erp.assert_scheduler_integrity();
select erp.assert_job_handlers_resolvable();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
