-- =============================================================================
-- 20260906144000  A channel queues, and a triggered run waits
-- -----------------------------------------------------------------------------
-- Specification v1.6 §3.9, §9.1. Phase 9 of the outstanding-work programme,
-- the fifth of seven files; closes deferred findings 49 and 50.
--
-- Finding 49. erp.dispatch_notifications() settled a webhook notification as
-- 'sent' in the database, where nothing can make an HTTP request: the row
-- recorded a delivery that had not happened. The email queue was corrected in
-- 20260904750000; the webhook channel is corrected here the same way. Dispatch
-- queues a webhook message; erp.claim_webhook_batch() hands it to the worker
-- under a lease; erp.complete_webhook() refuses to call it sent without a
-- receipt from the other end; erp.fail_webhook() retries or falls back to the
-- in-app copy; erp.reclaim_stuck_webhook() returns what a dead worker held.
-- The two kinds nobody built, sms and push, now refuse by name at the route,
-- at the channel, and at dispatch, rather than settling as sent. A channel
-- has a writer at last: erp.upsert_notification_channel() (there was none;
-- a webhook channel could only ever be inserted by hand).
--
-- Finding 50. erp.trigger_job() recorded a run as 'running' with no worker,
-- and the engines claim schedules, never runs: a triggered run sat until its
-- lease expired and read as timed out. The vocabulary gained 'queued' in
-- 20260906140000; here the trigger writes it — no worker, no lease, no start
-- — and erp.claim_job_runs() claims queued runs before it looks at the
-- schedule, in both engines: the database's erp.run_due_jobs() picks up a
-- queued run of a SQL handler, the worker picks up the rest.
--
-- Deployed bodies are corrected by asserted needle; the two reclaim readers
-- are re-emitted whole after their deployed text is checked.
--
-- Proof: erp_test.webhook_delivery_suite() (15) and erp_test.queued_run_suite()
-- (8); stranded work, email delivery, notification chain, superadmin, service
-- notice, incident communication and gateway suites unchanged; the console.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A channel has a writer, and two kinds refuse by name
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.upsert_notification_channel(
  p_code text, p_name text, p_kind erp.notification_channel_kind,
  p_settings jsonb default '{}'::jsonb, p_credential_ref text default null,
  p_is_enabled boolean default true)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_url    text;
  v_id     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'notification_channel', null);

  if p_kind in ('sms', 'push') then
    raise exception 'CLOVEERP_CHANNEL_NOT_IMPLEMENTED: the product has no % channel', p_kind
      using errcode = '0A000',
            hint = 'Route to in_app, email or webhook. A webhook channel can reach a messaging service that accepts a JSON post.';
  end if;
  if p_kind = 'in_app' then
    raise exception 'CLOVEERP_CHANNEL_NEEDS_NO_ROW: in-app delivery needs no channel; it always works'
      using errcode = '23514',
            hint = 'Configure a channel only for email or webhook.';
  end if;
  if coalesce(p_code, '') !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'CLOVEERP_VALIDATION: a channel code is lower-case letters, digits and underscores'
      using errcode = '23514', hint = 'Give the channel a code such as ops_chat.';
  end if;

  if p_kind = 'webhook' then
    v_url := coalesce(p_settings ->> 'url', p_settings ->> 'endpoint');
    if v_url is null or v_url !~ '^https?://[^[:space:]]+$' then
      raise exception 'CLOVEERP_WEBHOOK_NEEDS_URL: a webhook channel names where the post goes'
        using errcode = '23514',
              hint = 'Put the endpoint in settings as {"url": "https://..."}; a credential goes in credential_ref as a reference, never in the URL.';
    end if;
  end if;

  insert into erp.notification_channel (tenant_id, code, name, kind, settings, credential_ref, is_enabled)
  values (v_tenant, p_code, p_name, p_kind, coalesce(p_settings, '{}'::jsonb), p_credential_ref, coalesce(p_is_enabled, true))
  on conflict (tenant_id, code) do update
    set name = excluded.name, kind = excluded.kind, settings = excluded.settings,
        credential_ref = excluded.credential_ref, is_enabled = excluded.is_enabled,
        updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function erp.upsert_notification_channel(text, text, erp.notification_channel_kind, jsonb, text, boolean) from public, anon;

comment on function erp.upsert_notification_channel(text, text, erp.notification_channel_kind, jsonb, text, boolean) is
  'Creates or replaces a notification channel: email, or a webhook with its '
  'URL in settings and its credential as a reference. sms and push refuse by '
  'name because the product has no such channel; in_app needs no row.';

create or replace function erp.notification_channels()
returns table(id uuid, code text, name text, kind text, settings jsonb, credential_ref text,
              is_enabled boolean, updated_at timestamptz)
language sql
stable
set search_path = ''
as $$
  select c.id, c.code, c.name, c.kind::text, c.settings, c.credential_ref, c.is_enabled, c.updated_at
    from erp.notification_channel c
   where c.tenant_id = erp.require_tenant_id()
   order by c.code
$$;

revoke all on function erp.notification_channels() from public, anon;

-- A route to a kind nobody built refuses at the route.
do $route$
declare
  v_def text;
  v_n   text := E'  perform erp.authorise(''administration.configure'', null, null, null, ''notification_route'', null);\n';
  v_r   text := E'  perform erp.authorise(''administration.configure'', null, null, null, ''notification_route'', null);\n'
             || E'  if p_channel_kind in (''sms'', ''push'') then\n'
             || E'    raise exception ''CLOVEERP_CHANNEL_NOT_IMPLEMENTED: the product has no % channel'', p_channel_kind\n'
             || E'      using errcode = ''0A000'',\n'
             || E'            hint = ''Route to in_app, email or webhook; a webhook channel can reach a messaging service that accepts a JSON post.'';\n'
             || E'  end if;\n';
begin
  v_def := pg_get_functiondef('erp.upsert_notification_route(text,text,text,erp.notification_severity,text,text,text,uuid,erp.notification_channel_kind,text,integer,integer,text,boolean)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_ROUTE_UPSERT_UNRECOGNISED: erp.upsert_notification_route() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$route$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Dispatch queues a webhook and refuses sms and push by name
-- ═════════════════════════════════════════════════════════════════════════════

-- A sent webhook names its receipt, as a sent email names its provider id.
-- Same constraint name: the email delivery suite looks for it.
alter table erp.notification drop constraint if exists notification_sent_email_has_provider_id;
alter table erp.notification add constraint notification_sent_email_has_provider_id
  check (not (channel_kind in ('email', 'webhook')
              and status in ('sent', 'delivered', 'read')
              and provider_message_id is null));

do $dispatch$
declare
  v_def text;
  v_n1  text := E'    elsif not exists (select 1 from erp.notification_channel c\n'
             || E'                       where c.tenant_id = v_tenant and c.kind = r.channel_kind and c.is_enabled) then\n'
             || E'      v_reason := format(''no enabled %s channel is configured'', r.channel_kind);\n'
             || E'    end if;\n';
  v_r1  text := E'    elsif r.channel_kind in (''sms'', ''push'') then\n'
             || E'      v_reason := format(''CLOVEERP_CHANNEL_NOT_IMPLEMENTED: the product has no %s channel'', r.channel_kind);\n'
             || E'    elsif not exists (select 1 from erp.notification_channel c\n'
             || E'                       where c.tenant_id = v_tenant and c.kind = r.channel_kind and c.is_enabled) then\n'
             || E'      v_reason := format(''no enabled %s channel is configured'', r.channel_kind);\n'
             || E'    end if;\n';
  v_n2  text := E'       set status = case when r.channel_kind = ''email'' then ''queued'' else ''sent'' end,\n'
             || E'           sent_at = case when r.channel_kind = ''email'' then null else now() end,\n';
  v_r2  text := E'       set status = case when r.channel_kind in (''email'', ''webhook'') then ''queued'' else ''sent'' end,\n'
             || E'           sent_at = case when r.channel_kind in (''email'', ''webhook'') then null else now() end,\n';
begin
  v_def := pg_get_functiondef('erp.dispatch_notifications()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_DISPATCH_UNRECOGNISED: erp.dispatch_notifications() is not the body this migration patches';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$dispatch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The webhook queue: claim, complete, fail, reclaim
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.claim_webhook_batch(p_limit integer default 50, p_worker text default null)
returns table(id uuid, url text, credential_ref text, channel_code text, payload jsonb, severity text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  ch       erp.notification_channel%rowtype;
begin
  if erp.is_killed('integration', 'webhook') then
    return;
  end if;

  -- A route names a kind, not a channel: the organisation's enabled webhook
  -- channel receives everything routed to webhook. With none enabled the
  -- rows stay queued, and dispatch has already refused the newer ones.
  select * into ch from erp.notification_channel c
   where c.tenant_id = v_tenant and c.kind = 'webhook' and c.is_enabled
   order by c.code limit 1;
  if ch.id is null then
    return;
  end if;

  return query
  with claimed as (
    select n.id
      from erp.notification n
     where n.tenant_id = v_tenant
       and n.channel_kind = 'webhook'
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
         coalesce(ch.settings ->> 'url', ch.settings ->> 'endpoint'),
         ch.credential_ref,
         ch.code,
         jsonb_build_object(
           'id', m.id,
           'organisation', t.code,
           'subject', m.subject,
           'body', m.body,
           'severity', m.severity::text,
           'event_id', m.event_id,
           'recipient', u.display_name,
           'created_at', m.created_at),
         m.severity::text
    from marked m
    join erp.tenant t on t.id = m.tenant_id
    join erp.app_user u on u.id = m.app_user_id;
end;
$$;

revoke all on function erp.claim_webhook_batch(integer, text) from public, anon;

comment on function erp.claim_webhook_batch(integer, text) is
  'The worker''s claim on queued webhook notifications: marks them sending '
  'under a five-minute lease with the worker''s name and hands back the '
  'channel''s URL, its credential reference and the JSON to post.';

create or replace function erp.complete_webhook(p_id uuid, p_receipt text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if coalesce(trim(p_receipt), '') = '' then
    raise exception 'CLOVEERP_WEBHOOK_NEEDS_RECEIPT: a post is only sent once the other end has answered'
      using errcode = 'P0001',
            hint = 'Pass what the endpoint answered: its message id, or the status it returned. Without it the row cannot honestly say sent.';
  end if;

  update erp.notification
     set status = 'sent', sent_at = now(), provider_message_id = p_receipt,
         claimed_by = null, lease_expires_at = null,
         failure_reason = null
   where tenant_id = v_tenant and id = p_id and status = 'sending' and channel_kind = 'webhook';
end;
$$;

revoke all on function erp.complete_webhook(uuid, text) from public, anon;

create or replace function erp.fail_webhook(p_id uuid, p_reason text, p_retry boolean default true)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); r record;
begin
  if p_retry then
    -- Back to the queue. The endpoint said "not now", not "never".
    update erp.notification
       set status = 'queued', failure_reason = p_reason, claimed_by = null, lease_expires_at = null
     where tenant_id = v_tenant and id = p_id and status = 'sending' and channel_kind = 'webhook';
    return;
  end if;

  update erp.notification
     set status = 'failed', failure_reason = p_reason, claimed_by = null, lease_expires_at = null
   where tenant_id = v_tenant and id = p_id and status = 'sending' and channel_kind = 'webhook'
  returning * into r;

  if r.id is null then
    return;
  end if;

  -- §15.6: the fallback that always works and never gets suppressed.
  insert into erp.notification
    (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
     status, sent_at, delivered_at, escalation_of)
  values (v_tenant, r.route_id, r.event_id, r.severity, r.app_user_id, 'in_app',
          r.subject, r.body || E'\n(webhook not delivered: ' || p_reason || ')',
          'delivered', now(), now(), r.id);
end;
$$;

revoke all on function erp.fail_webhook(uuid, text, boolean) from public, anon;

create or replace function erp.reclaim_stuck_webhook()
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
       and n.channel_kind = 'webhook'
       and n.status = 'sending'
       and coalesce(n.lease_expires_at, n.created_at + interval '15 minutes') < now()
     for update skip locked
  loop
    -- Four abandonments go back to the queue; the fifth fails the message with
    -- its reason, and fail_webhook tells the person in-app.
    perform erp.fail_webhook(r.id,
      format('claimed by %s and never settled; lease expired at %s',
             coalesce(r.claimed_by, 'unknown'),
             coalesce(r.lease_expires_at, r.created_at + interval '15 minutes')),
      r.send_attempts < 5);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function erp.reclaim_stuck_webhook() from public, anon;

-- The one reclaimer answers for the new queue too.
do $reclaim$
declare v_def text := pg_get_functiondef('erp.reclaim_stranded_work()'::regprocedure);
begin
  if position(E'''email'',    erp.reclaim_stuck_email());' in v_def) = 0 then
    raise exception 'CLOVEERP_RECLAIM_UNRECOGNISED: erp.reclaim_stranded_work() is not the body this migration restates';
  end if;
end
$reclaim$;

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
    'email',    erp.reclaim_stuck_email(),
    'webhook',  erp.reclaim_stuck_webhook());
end;
$$;

-- The stranded-work report names a stuck webhook and a run nothing claims.
do $report$
declare v_def text := pg_get_functiondef('erp.stranded_work_report()'::regprocedure);
begin
  if position(E'   where n.channel_kind = ''email'' and n.status = ''sending''' in v_def) = 0
     or position(E'   where r.outcome = ''running'' and r.lease_expires_at < now()' in v_def) = 0 then
    raise exception 'CLOVEERP_STRANDED_REPORT_UNRECOGNISED: erp.stranded_work_report() is not the body this migration restates';
  end if;
end
$report$;

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
  select 'runs', r.id::text, null, r.scheduled_for,
         'queued for over an hour and no engine has claimed it; an engine must be running for a triggered run to happen'
    from erp.job_run r join t on t.tenant_id = r.tenant_id
   where r.outcome = 'queued' and r.scheduled_for < now() - interval '1 hour'
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
  union all
  select 'webhook', n.id::text, n.claimed_by, coalesce(n.lease_expires_at, n.created_at + interval '15 minutes'),
         'sending past its lease; erp.reclaim_stranded_work() returns it to the queue'
    from erp.notification n join t on t.tenant_id = n.tenant_id
   where n.channel_kind = 'webhook' and n.status = 'sending'
     and coalesce(n.lease_expires_at, n.created_at + interval '15 minutes') < now()
   order by 4
$$;

-- The evidence panel shows the webhook queue beside the email queue.
do $evidence$
declare
  v_def text;
  v_n   text := E'  union all\n  select ''platform'',\n';
  v_r   text := E'  union all\n'
             || E'  select ''webhook'',\n'
             || E'         (select max(n.claimed_at) from erp.notification n where n.tenant_id = t.tenant_id and n.channel_kind = ''webhook''),\n'
             || E'         (select max(n.sent_at) from erp.notification n where n.tenant_id = t.tenant_id and n.channel_kind = ''webhook''),\n'
             || E'         (select n.claimed_by from erp.notification n where n.tenant_id = t.tenant_id and n.channel_kind = ''webhook'' and n.claimed_at is not null order by n.claimed_at desc limit 1),\n'
             || E'         (select string_agg(format(''%s %s'', x.n, x.s), '', '' order by x.s)\n'
             || E'            from (select n.status::text as s, count(*) as n from erp.notification n where n.tenant_id = t.tenant_id and n.channel_kind = ''webhook'' group by n.status) x)\n'
             || E'    from t\n'
             || E'  union all\n  select ''platform'',\n';
begin
  v_def := pg_get_functiondef('erp.dispatch_evidence()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_EVIDENCE_UNRECOGNISED: erp.dispatch_evidence() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$evidence$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A triggered run is queued, and an engine claims it first
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.job_run drop constraint if exists job_run_terminal_has_finish;
alter table erp.job_run add constraint job_run_terminal_has_finish
  check ((outcome in ('running', 'queued')) = (finished_at is null));

create index if not exists job_run_tenant_id_queued_idx
  on erp.job_run (tenant_id, scheduled_for) where outcome = 'queued';

-- A queued run is open: it may be claimed, and nothing else about it moves.
do $guard$
declare
  v_def text;
  v_n   text := E'  if old.outcome <> ''running'' then\n';
  v_r   text := E'  if old.outcome not in (''running'', ''queued'') then\n';
begin
  v_def := pg_get_functiondef('erp.guard_finished_job_run()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_RUN_GUARD_UNRECOGNISED: erp.guard_finished_job_run() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$guard$;

-- The trigger asks; it does not pretend to run.
do $trigger$
declare
  v_def text;
  v_n1  text := E'  values (\n    v_tenant, j.id, now(), ''running'',\n    now() + make_interval(secs => j.timeout_seconds), null, now(),\n';
  v_r1  text := E'  values (\n    v_tenant, j.id, now(), ''queued'',\n    null, null, null,\n';
  v_n2  text := E'      ''rather than working around it'', p_job_code\n      using errcode = ''42501'';\n';
  v_r2  text := E'      ''rather than working around it'', p_job_code\n      using errcode = ''42501'',\n'
             || E'            hint = ''erp_clear_kill_switch(''''job'''', code) lifts the switch; the run is not queued behind it.'';\n';
begin
  v_def := pg_get_functiondef('erp.trigger_job(text,text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_TRIGGER_UNRECOGNISED: erp.trigger_job() is not the body this migration patches';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$trigger$;

comment on function erp.trigger_job(text, text) is
  'Asks for a run of a job now. The run is queued — no worker, no lease, no '
  'start — and the next engine pass claims it before the schedule: the '
  'database engine when the handler is SQL, the worker otherwise.';

-- Both engines claim queued runs before the schedule.
do $claim$
declare
  v_def text;
  v_n   text := E'begin\n  for j in\n    select * from erp.job job\n';
  v_r   text := E'begin\n'
             || E'  -- A run somebody asked for waits for nobody''s schedule: queued runs\n'
             || E'  -- are claimed first, under the same kill switch and overlap rules.\n'
             || E'  for v_run in\n'
             || E'    select r.* from erp.job_run r\n'
             || E'      join erp.job job on job.id = r.job_id\n'
             || E'     where r.tenant_id = v_tenant\n'
             || E'       and r.outcome = ''queued''\n'
             || E'       and (not p_sql_only or exists (select 1 from erp_ref.job_handler h\n'
             || E'                                        where h.code = job.handler_code and h.sql_function is not null))\n'
             || E'     order by r.scheduled_for\n'
             || E'     limit greatest(p_batch_size, 1)\n'
             || E'     for update of r skip locked\n'
             || E'  loop\n'
             || E'    select * into j from erp.job where id = v_run.job_id;\n'
             || E'    if erp.is_killed(''job'', j.code) then\n'
             || E'      continue;\n'
             || E'    end if;\n'
             || E'    select count(*) into v_running\n'
             || E'      from erp.job_run r\n'
             || E'     where r.tenant_id = v_tenant and r.job_id = j.id and r.outcome = ''running'';\n'
             || E'    if v_running > 0 and (j.overlap_policy <> ''allow'' or v_running >= j.max_concurrent_runs) then\n'
             || E'      continue;\n'
             || E'    end if;\n'
             || E'    update erp.job_run r\n'
             || E'       set outcome = ''running'', started_at = now(), worker = v_worker,\n'
             || E'           lease_expires_at = now() + coalesce(p_lease, make_interval(secs => j.timeout_seconds))\n'
             || E'     where r.id = v_run.id\n'
             || E'    returning r.* into v_run;\n'
             || E'    v_claimed := v_claimed + 1;\n'
             || E'    return next v_run;\n'
             || E'  end loop;\n\n'
             || E'  for j in\n    select * from erp.job job\n';
begin
  v_def := pg_get_functiondef('erp.claim_job_runs(text,integer,interval,boolean)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_CLAIM_UNRECOGNISED: erp.claim_job_runs() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$claim$;

-- A run waiting for an engine is visible as waiting. `last_outcome` is the last
-- run that finished, and a queued run has not; without a count of its own a
-- job somebody triggered by hand read exactly like a job nobody had touched,
-- which is the half of finding 50 an operator would have noticed. Dropped and
-- recreated rather than replaced, because the column list changes and this
-- product does not carry two functions of one name.
drop function if exists public.erp_job_health();
drop function if exists erp.job_health();

create function erp.job_health()
returns table(job_code text, is_enabled boolean, is_failing boolean, is_killed boolean,
              in_outage boolean, next_run_at timestamptz, running bigint, queued bigint,
              last_outcome erp.job_run_outcome, last_finished_at timestamptz,
              last_success_at timestamptz, runs_24h bigint, failures_24h bigint, skips_24h bigint)
language sql
stable
set search_path = ''
as $$
  select j.code, j.is_enabled, j.is_failing,
         erp.is_killed('job', j.code),
         erp.in_outage_window(j.code, now(), false),
         j.next_run_at,
         count(*) filter (where r.outcome = 'running'),
         count(*) filter (where r.outcome = 'queued'),
         (select r2.outcome from erp.job_run r2
           where r2.tenant_id = j.tenant_id and r2.job_id = j.id
             and r2.finished_at is not null
           order by r2.finished_at desc limit 1),
         max(r.finished_at),
         max(r.finished_at) filter (where r.outcome = 'succeeded'),
         count(*) filter (where r.scheduled_for > now() - interval '24 hours'),
         count(*) filter (where r.scheduled_for > now() - interval '24 hours'
                            and r.outcome in ('failed', 'timed_out')),
         count(*) filter (where r.scheduled_for > now() - interval '24 hours'
                            and r.outcome = 'skipped')
    from erp.job j
    left join erp.job_run r
      on r.tenant_id = j.tenant_id and r.job_id = j.id
   where j.tenant_id = erp.require_tenant_id()
   group by j.tenant_id, j.id, j.code, j.is_enabled, j.is_failing, j.next_run_at
   order by j.code
$$;

revoke all on function erp.job_health() from public, anon;

create function public.erp_job_health()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(h) order by h.job_code), '[]'::jsonb)
    from erp.job_health() h
$$;

revoke all on function public.erp_job_health() from public, anon;
grant execute on function public.erp_job_health() to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_upsert_notification_channel(
  p_code text, p_name text, p_kind text,
  p_settings jsonb default '{}'::jsonb, p_credential_ref text default null,
  p_is_enabled boolean default true)
returns uuid
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.upsert_notification_channel(p_code, p_name, p_kind::erp.notification_channel_kind,
                                         p_settings, p_credential_ref, p_is_enabled)
$$;

create or replace function public.erp_notification_channels()
returns table(id uuid, code text, name text, kind text, settings jsonb, credential_ref text,
              is_enabled boolean, updated_at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from erp.notification_channels()
$$;

revoke all on function public.erp_upsert_notification_channel(text, text, text, jsonb, text, boolean) from public, anon;
revoke all on function public.erp_notification_channels() from public, anon;
grant execute on function public.erp_upsert_notification_channel(text, text, text, jsonb, text, boolean) to authenticated, service_role;
grant execute on function public.erp_notification_channels() to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_upsert_notification_channel', 'erp.upsert_notification_channel',
   'Creates or replaces an email or webhook channel under administration.configure; sms and push refuse by name because the product has no such channel.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/notifications',
  array['erp_upsert_notification_channel', 'erp_notification_channels']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.webhook_delivery_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_ok boolean; v_msg text; v_hint text;
  v_ch uuid; v_n1 uuid; v_n2 uuid; v_n3 uuid; v_n4 uuid;
  r record; d record; v_res jsonb; v_cnt integer;
begin
  begin
    select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzhook', 'Webhook suite', 'admin@zzhook.test', 'Hook Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f4', 'admin@zzhook.test');
    perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000f4')::text, true);
    perform erp.claim_invitation(v_token);

    -- 1 and 2. The kinds nobody built refuse by name, at the channel and at the route.
    begin
      perform erp.upsert_notification_channel('zz_sms', 'Texts', 'sms');
      v_ok := false; v_msg := 'an sms channel was created';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_ok := sqlerrm like 'CLOVEERP_CHANNEL_NOT_IMPLEMENTED%' and coalesce(v_hint, '') <> ''; v_msg := left(sqlerrm, 90);
    end;
    return query select 'an sms channel is refused by name with the next action', v_ok, v_msg;

    begin
      perform erp.upsert_notification_route('zz_push', 'Push it', 'document.*', 'medium', 'role', 'administrator', null, null, 'push');
      v_ok := false; v_msg := 'a push route was created';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_CHANNEL_NOT_IMPLEMENTED%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a route to push is refused by name', v_ok, v_msg;

    -- 3 and 4. A webhook channel names its URL, and the reader lists it.
    begin
      perform erp.upsert_notification_channel('zz_hook', 'Ops chat', 'webhook', '{}'::jsonb);
      v_ok := false; v_msg := 'a webhook with no URL was created';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_WEBHOOK_NEEDS_URL%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a webhook channel without a URL is refused by name', v_ok, v_msg;

    v_ch := erp.upsert_notification_channel('zz_hook', 'Ops chat', 'webhook',
              jsonb_build_object('url', 'https://hooks.example.test/clove'), 'env://ZZ_HOOK_TOKEN', false);
    return query select 'a webhook channel is created through the writer and listed by the reader',
      exists (select 1 from erp.notification_channels() c where c.id = v_ch and c.kind = 'webhook'
               and c.settings ->> 'url' = 'https://hooks.example.test/clove' and not c.is_enabled),
      'zz_hook, disabled for now, URL kept in settings, credential as a reference';

    -- 5. With no enabled channel, dispatch fails the message and tells the person in-app.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (v_tenant, 'high', v_admin, 'webhook', 'Nobody listening', 'A post with nowhere to go.', 'pending')
    returning id into v_n1;
    select * into d from erp.dispatch_notifications();
    return query select 'a webhook message with no enabled channel fails with its reason and falls back in-app',
      (select n.status = 'failed' and n.failure_reason like 'no enabled webhook channel%' from erp.notification n where n.id = v_n1)
      and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.escalation_of = v_n1
                   and n.channel_kind = 'in_app' and n.status = 'delivered' and n.body like '%(webhook not delivered: no enabled webhook channel%'),
      (select format('%s: %s', n.status, n.failure_reason) from erp.notification n where n.id = v_n1);

    -- 6. With the channel enabled, dispatch queues rather than settling.
    perform erp.upsert_notification_channel('zz_hook', 'Ops chat', 'webhook',
              jsonb_build_object('url', 'https://hooks.example.test/clove'), 'env://ZZ_HOOK_TOKEN', true);
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (v_tenant, 'high', v_admin, 'webhook', 'Order held', 'Order SO-1 is on credit hold.', 'pending')
    returning id into v_n2;
    select * into d from erp.dispatch_notifications();
    return query select 'dispatch queues a webhook message rather than calling it sent',
      (select n.status = 'queued' and n.sent_at is null from erp.notification n where n.id = v_n2) and d.sent = 1,
      (select format('status %s, sent_at %s, dispatch counted %s sent', n.status, n.sent_at, d.sent) from erp.notification n where n.id = v_n2);

    -- 7. The claim marks it sending under a lease and hands over the URL and the JSON.
    select * into r from erp.claim_webhook_batch(10, 'zz-worker');
    return query select 'the claim marks the message sending with the worker and a lease, and carries the URL and the payload',
      r.id = v_n2 and r.url = 'https://hooks.example.test/clove' and r.credential_ref = 'env://ZZ_HOOK_TOKEN'
      and r.payload ->> 'subject' = 'Order held' and r.payload ->> 'severity' = 'high' and r.payload ->> 'organisation' = 'zzhook'
      and (select n.status = 'sending' and n.claimed_by = 'zz-worker' and n.lease_expires_at > now() and n.send_attempts = 1
             from erp.notification n where n.id = v_n2),
      format('url %s, payload subject %s, status %s', r.url, r.payload ->> 'subject',
             (select n.status from erp.notification n where n.id = v_n2));

    -- 8. Sent means answered: no receipt, no sent.
    begin
      perform erp.complete_webhook(v_n2, '  ');
      v_ok := false; v_msg := 'a blank receipt was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_WEBHOOK_NEEDS_RECEIPT%'; v_msg := left(sqlerrm, 90);
    end;
    perform erp.complete_webhook(v_n2, 'http 200 hook_77');
    return query select 'completing without a receipt is refused, and with one the message is sent and names it',
      v_ok and (select n.status = 'sent' and n.provider_message_id = 'http 200 hook_77' and n.sent_at is not null and n.claimed_by is null
                  from erp.notification n where n.id = v_n2),
      v_msg || '; then sent with receipt http 200 hook_77';

    -- 9. Not now goes back to the queue; never fails with the in-app copy.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (v_tenant, 'medium', v_admin, 'webhook', 'Flaky', 'A post the other end drops.', 'queued')
    returning id into v_n3;
    perform erp.claim_webhook_batch(10, 'zz-worker');
    perform erp.fail_webhook(v_n3, 'endpoint responded 503', true);
    v_ok := (select n.status = 'queued' and n.claimed_by is null from erp.notification n where n.id = v_n3);
    perform erp.claim_webhook_batch(10, 'zz-worker');
    perform erp.fail_webhook(v_n3, 'endpoint responded 410: gone', false);
    return query select 'a transient failure returns to the queue; a permanent one fails and the person is told in-app',
      v_ok and (select n.status = 'failed' and n.failure_reason like '%410%' and n.send_attempts = 2 from erp.notification n where n.id = v_n3)
      and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.escalation_of = v_n3
                   and n.channel_kind = 'in_app' and n.body like '%(webhook not delivered: endpoint responded 410%'),
      format('after 503: queued %s; after 410: %s', v_ok, (select n.status from erp.notification n where n.id = v_n3));

    -- 10. A dead worker's claim is reported and reclaimed.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (v_tenant, 'medium', v_admin, 'webhook', 'Abandoned', 'A post a worker died holding.', 'queued')
    returning id into v_n4;
    perform erp.claim_webhook_batch(10, 'zz-dead-worker');
    update erp.notification set lease_expires_at = now() - interval '1 minute' where id = v_n4;
    v_ok := exists (select 1 from erp.stranded_work_report() s where s.queue = 'webhook' and s.reference = v_n4::text and s.held_by = 'zz-dead-worker');
    v_res := erp.reclaim_stranded_work();
    return query select 'a webhook held past its lease is reported under its queue and reclaimed to queued',
      v_ok and (v_res ->> 'webhook')::integer = 1
      and (select n.status = 'queued' and n.claimed_by is null and n.failure_reason like 'claimed by zz-dead-worker%' from erp.notification n where n.id = v_n4),
      format('reported %s; reclaimed %s; status %s', v_ok, v_res ->> 'webhook', (select n.status from erp.notification n where n.id = v_n4));

    -- 11. The kill switch stops the claim.
    perform erp.set_kill_switch('integration', 'webhook', 'webhook suite');
    select count(*) into v_cnt from erp.claim_webhook_batch(10, 'zz-worker');
    perform erp.clear_kill_switch('integration', 'webhook');
    return query select 'the integration/webhook kill switch stops the claim and leaves the queue as it is',
      v_cnt = 0 and (select n.status = 'queued' from erp.notification n where n.id = v_n4),
      format('%s claimed under the switch', v_cnt);

    -- 12. A text message dispatched fails by name, and the person still hears in-app.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (v_tenant, 'low', v_admin, 'sms', 'A text', 'Nobody built texts.', 'pending')
    returning id into v_n1;
    select * into d from erp.dispatch_notifications();
    return query select 'an sms message dispatched fails by name and the person is told in-app',
      (select n.status = 'failed' and n.failure_reason like 'CLOVEERP_CHANNEL_NOT_IMPLEMENTED%' from erp.notification n where n.id = v_n1)
      and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.escalation_of = v_n1 and n.channel_kind = 'in_app'),
      (select n.failure_reason from erp.notification n where n.id = v_n1);

    -- 13. The evidence panel has a row for the queue.
    --
    -- The worker is named only while somebody is holding a message: settling
    -- clears claimed_by, as it does for email, and this queue has no event log
    -- to read the last holder back from the way the commands arm does. The
    -- counts are the evidence; who held it is a live fact, not a historical one.
    return query select 'the dispatch evidence shows the webhook queue, its last claim and what it holds',
      exists (select 1 from erp.dispatch_evidence() e
               where e.queue = 'webhook' and e.last_claimed_at is not null
                 and e.last_settled_at is not null and e.detail like '%sent%'),
      (select format('claimed %s, settled %s: %s', e.last_claimed_at is not null, e.last_settled_at is not null, e.detail)
         from erp.dispatch_evidence() e where e.queue = 'webhook');

    -- 14. A sent webhook names its receipt, by constraint.
    begin
      update erp.notification set status = 'sent', provider_message_id = null where id = v_n2;
      v_ok := false; v_msg := 'a sent webhook without a receipt was accepted';
    exception when others then
      v_ok := sqlerrm like '%notification_sent_email_has_provider_id%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a sent webhook without a receipt is refused by the same constraint that guards email', v_ok, v_msg;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 15. Undone.
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zzhook'),
    'zzhook is gone';
end;
$$;

create or replace function erp_test.assert_webhook_delivery_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 15;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _webhook_delivery on commit drop as
    select * from erp_test.webhook_delivery_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _webhook_delivery;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_WEBHOOK_DELIVERY_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_WEBHOOK_DELIVERY_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('webhook delivery: %s/%s cases passed', v_passed, v_total);
end;
$$;

create or replace function erp_test.queued_run_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_r1 bigint; v_r2 bigint; v_r3 bigint;
  v_ok boolean; v_msg text; v_hint text;
  r record; v_res jsonb; v_cnt integer;
begin
  begin
    select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzqueue', 'Queued run suite', 'admin@zzqueue.test', 'Queue Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f5', 'admin@zzqueue.test');
    perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000f5')::text, true);
    perform erp.claim_invitation(v_token);

    -- A job that is only ever run by hand, with a SQL handler.
    perform erp.upsert_job('zzqueued', 'Queued by hand', 'platform.reclaim_stranded_work', 'manual');

    -- 1. The trigger asks; the run waits.
    v_r1 := erp.trigger_job('zzqueued', 'queued run suite');
    select * into r from erp.job_run where id = v_r1;
    return query select 'a triggered run is queued with no worker, no lease and no start, naming who asked',
      r.outcome = 'queued' and r.worker is null and r.lease_expires_at is null and r.started_at is null
      and r.finished_at is null and r.triggered_by = erp.current_principal_id() and r.summary ->> 'reason' = 'queued run suite',
      format('outcome %s, worker %s, lease %s, started %s', r.outcome, r.worker, r.lease_expires_at, r.started_at);

    -- 2. Nothing times it out, nothing calls it stranded yet, and the job reads queued.
    v_cnt := erp.reclaim_timed_out_runs();
    return query select 'a queued run is not timed out, and the job shows it waiting rather than as an outcome',
      v_cnt = 0 and (select r2.outcome = 'queued' from erp.job_run r2 where r2.id = v_r1)
      and not exists (select 1 from erp.stranded_work_report() s where s.queue = 'runs' and s.reference = v_r1::text)
      and (select h.queued = 1 and h.running = 0 and h.last_outcome is null
             from erp.job_health() h where h.job_code = 'zzqueued'),
      format('%s reclaimed; the job reads %s queued and %s running, and nothing has finished',
             v_cnt,
             (select h.queued from erp.job_health() h where h.job_code = 'zzqueued'),
             (select h.running from erp.job_health() h where h.job_code = 'zzqueued'));

    -- 3. The engine claims it before the schedule, though the job has none.
    select count(*) into v_cnt from erp.claim_job_runs('zz-engine', 10);
    select * into r from erp.job_run where id = v_r1;
    return query select 'an engine claims the queued run first: running, with the worker, a lease and a start',
      v_cnt = 1 and r.outcome = 'running' and r.worker = 'zz-engine' and r.lease_expires_at > now() and r.started_at is not null,
      format('%s claimed; outcome %s by %s', v_cnt, r.outcome, r.worker);

    -- 4. It settles like any run, and is then evidence.
    perform erp.complete_job_run(v_r1, '{"did": "the thing"}'::jsonb);
    begin
      update erp.job_run set worker = 'someone else' where id = v_r1;
      v_ok := false; v_msg := 'a finished run was edited';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_JOB_RUN_FINISHED%'; v_msg := left(sqlerrm, 80);
    end;
    return query select 'the claimed run settles as succeeded and is then immutable',
      (select r2.outcome = 'succeeded' and r2.finished_at is not null from erp.job_run r2 where r2.id = v_r1) and v_ok,
      v_msg;

    -- 5. A queued run waits while another of the same job runs (overlap policy skip).
    v_r2 := erp.trigger_job('zzqueued', 'first');
    perform erp.claim_job_runs('zz-engine', 10);
    v_r3 := erp.trigger_job('zzqueued', 'second');
    select count(*) into v_cnt from erp.claim_job_runs('zz-engine', 10);
    v_ok := v_cnt = 0 and (select r2.outcome = 'queued' from erp.job_run r2 where r2.id = v_r3);
    perform erp.complete_job_run(v_r2, '{}'::jsonb);
    select count(*) into v_cnt from erp.claim_job_runs('zz-engine', 10);
    return query select 'a second queued run waits while the first runs, and is claimed once it finishes',
      v_ok and v_cnt = 1 and (select r2.outcome = 'running' from erp.job_run r2 where r2.id = v_r3),
      format('held while running: %s; claimed after: %s', v_ok, v_cnt);
    perform erp.complete_job_run(v_r3, '{}'::jsonb);

    -- 6. The database engine runs a queued run of a SQL handler itself.
    v_r1 := erp.trigger_job('zzqueued', 'for the database engine');
    v_res := erp.run_due_jobs(10);
    select * into r from erp.job_run where id = v_r1;
    return query select 'the database engine picks up a queued run of a SQL handler and runs it',
      (v_res ->> 'claimed')::integer = 1 and (v_res ->> 'succeeded')::integer = 1
      and r.outcome = 'succeeded' and r.worker = 'database' and r.summary ? 'result',
      format('claimed %s, succeeded %s; run %s by %s', v_res ->> 'claimed', v_res ->> 'succeeded', r.outcome, r.worker);

    -- 7. A killed job refuses the trigger, and says what lifts the switch.
    perform erp.set_kill_switch('job', 'zzqueued', 'queued run suite');
    begin
      perform erp.trigger_job('zzqueued', 'under the switch');
      v_ok := false; v_msg := 'a killed job was triggered';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_ok := sqlerrm like 'CLOVEERP_JOB_KILLED%' and coalesce(v_hint, '') like '%erp_clear_kill_switch%'; v_msg := left(sqlerrm, 80);
    end;
    perform erp.clear_kill_switch('job', 'zzqueued');
    return query select 'a killed job refuses the trigger by name and the hint names what lifts the switch', v_ok, v_msg;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 8. Undone.
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zzqueue'),
    'zzqueue is gone';
end;
$$;

create or replace function erp_test.assert_queued_run_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _queued_run on commit drop as
    select * from erp_test.queued_run_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _queued_run;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_QUEUED_RUN_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_QUEUED_RUN_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('queued runs: %s/%s cases passed', v_passed, v_total);
end;
$$;

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

select erp_test.assert_webhook_delivery_suite();
select erp_test.assert_queued_run_suite();
select erp_test.assert_stranded_work_suite();
select erp_test.assert_email_delivery_suite();
select erp_test.assert_notification_chain_suite();
select erp_test.assert_superadmin_suite();
select erp_test.assert_service_notice_suite();
select erp_test.assert_incident_communication_suite();
select erp_test.assert_gateway_suite();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

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
