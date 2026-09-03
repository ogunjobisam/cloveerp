-- ─────────────────────────────────────────────────────────────────────────────
-- Email that actually leaves.
--
-- erp.dispatch_notifications() ended an email by writing status = 'sent' and a
-- from-address. Nothing sent it. Postgres cannot make an HTTP request, there is
-- no sender anywhere in the product, and the row sat at 'sent' having never
-- left the database — a delivery recorded that had not happened and never
-- would. Three separate gaps produced "no emails are going out", and this is
-- the one in the code:
--
--   1. dispatch marks email 'sent' and stops.        <- here
--   2. no notification route exists, so no event becomes a notification.
--   3. no sender identity is verified, so there is no from-address to use.
--
-- Two and three are configuration and are seeded separately per organisation;
-- this migration is the machinery all three need.
--
-- Email now has the shape the outbox already uses for every other external
-- delivery: claim a batch, hand it to something that can speak HTTP, and let
-- that report back what happened. dispatch queues; the sender settles.
--
--   pending -> queued -> sending -> sent (with the provider's id)
--                               \-> failed (with the reason, and the in-app
--                                   fallback §15.6 promises)
--
-- 'sent' now means a provider accepted it and told us its id. That is the
-- strongest claim the product can honestly make from here: 'delivered' belongs
-- to the provider's webhook, which is what erp.record_email_delivery() and
-- erp.suppress_address() below are for.
--
-- Every other channel still settles inside dispatch, because for them that call
-- is the whole delivery.
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.notification
  add column if not exists provider_message_id text;

comment on column erp.notification.provider_message_id is
  'What the sending provider called this message. Present exactly when a '
  'provider accepted it, which is what separates sent from queued.';

-- 'queued' and 'sending' are new: the states between dispatch deciding to send
-- and a provider having taken it. Without them the row had nowhere truthful to
-- sit and was parked in 'sent'.
alter table erp.notification drop constraint if exists notification_status_check;
alter table erp.notification add constraint notification_status_check
  check (status = any (array['pending','held','digested','queued','sending',
                             'sent','delivered','read','failed','suppressed']));

-- A row cannot claim a provider accepted it without saying which message the
-- provider called it. This is the constraint that makes the status mean
-- something rather than describe an intention.
alter table erp.notification drop constraint if exists notification_sent_email_has_provider_id;
alter table erp.notification add constraint notification_sent_email_has_provider_id
  check (not (channel_kind = 'email' and status in ('sent','delivered','read')
              and provider_message_id is null));

CREATE OR REPLACE FUNCTION erp.dispatch_notifications()
 RETURNS TABLE(released integer, digested integer, sent integer, delivered integer, suppressed integer, failed integer, escalated integer)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  r record; d record; e record;
  n_rel integer := 0; n_dig integer := 0; n_sent integer := 0; n_del integer := 0;
  n_sup integer := 0; n_fail integer := 0; n_esc integer := 0;
  v_email text; v_sender text; v_reason text; v_id uuid; v_body text; v_count integer;
  v_user uuid;
begin
  -- 1. Quiet hours over: held becomes pending.
  update erp.notification set status = 'pending', held_until = null
   where tenant_id = v_tenant and status = 'held' and held_until <= now();
  get diagnostics n_rel = row_count;

  -- 2. Digests: a route's pending messages to one person, once the oldest has
  --    waited the cadence, become one message.
  for d in
    select n.digest_key, n.app_user_id, n.route_id, n.channel_kind, min(n.created_at) as oldest,
           max(n.severity) as severity, count(*) as cnt, rt.digest_minutes, rt.name
      from erp.notification n
      join erp.notification_route rt on rt.tenant_id = n.tenant_id and rt.id = n.route_id
     where n.tenant_id = v_tenant and n.status = 'pending' and n.digest_key is not null
     group by n.digest_key, n.app_user_id, n.route_id, n.channel_kind, rt.digest_minutes, rt.name
    having min(n.created_at) <= now() - make_interval(mins => rt.digest_minutes)
  loop
    select string_agg('• ' || n.body, E'\n' order by n.created_at) into v_body
      from erp.notification n
     where n.tenant_id = v_tenant and n.status = 'pending' and n.digest_key = d.digest_key;
    insert into erp.notification
      (tenant_id, route_id, severity, app_user_id, channel_kind, subject, body, status, digest_of)
    values (v_tenant, d.route_id, d.severity, d.app_user_id, d.channel_kind,
            format('%s: %s update(s)', d.name, d.cnt), v_body, 'pending', d.cnt);
    update erp.notification set status = 'digested'
     where tenant_id = v_tenant and status = 'pending' and digest_key = d.digest_key;
    n_dig := n_dig + 1;
  end loop;

  -- 3. Send what is pending and not waiting for a digest.
  for r in
    select n.* from erp.notification n
     where n.tenant_id = v_tenant and n.status = 'pending'
       and (n.digest_key is null or n.digest_of > 0)
     order by n.created_at limit 500
  loop
    if r.channel_kind = 'in_app' then
      update erp.notification set status = 'delivered', sent_at = now(), delivered_at = now() where id = r.id;
      n_del := n_del + 1;
      continue;
    end if;

    v_reason := null;
    if r.channel_kind = 'email' then
      select u.email into v_email from erp.app_user u where u.id = r.app_user_id;
      if v_email is null then
        v_reason := 'the person has no email address';
      elsif exists (select 1 from erp.email_suppression s
                     where s.tenant_id = v_tenant and lower(s.address) = lower(v_email)) then
        v_reason := 'ERPWARE_ADDRESS_SUPPRESSED: ' || v_email;
      end if;
    elsif not exists (select 1 from erp.notification_channel c
                       where c.tenant_id = v_tenant and c.kind = r.channel_kind and c.is_enabled) then
      v_reason := format('no enabled %s channel is configured', r.channel_kind);
    end if;

    if v_reason is not null then
      update erp.notification
         set status = case when v_reason like 'ERPWARE_ADDRESS_SUPPRESSED%' then 'suppressed' else 'failed' end,
             failure_reason = v_reason
       where id = r.id;
      if v_reason like 'ERPWARE_ADDRESS_SUPPRESSED%' then n_sup := n_sup + 1; else n_fail := n_fail + 1; end if;
      -- §15.6: the fallback that always works and never gets suppressed.
      insert into erp.notification
        (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
         status, sent_at, delivered_at, escalation_of)
      values (v_tenant, r.route_id, r.event_id, r.severity, r.app_user_id, 'in_app',
              r.subject, r.body || E'\n(' || r.channel_kind || ' not delivered: ' || v_reason || ')',
              'delivered', now(), now(), r.id);
      n_del := n_del + 1;
      continue;
    end if;

    v_sender := case when r.channel_kind = 'email' then erp.sender_for('operational') ->> 'from_address' end;
    -- Email is queued, not sent. Nothing in the database can make an HTTP
    -- request, so marking a row 'sent' here recorded a delivery that had not
    -- happened and never would: erp.claim_email_batch() is what picks it up and
    -- the provider is what says whether it left. Every other channel still
    -- settles here, because for them this call is the whole delivery.
    update erp.notification
       set status = case when r.channel_kind = 'email' then 'queued' else 'sent' end,
           sent_at = case when r.channel_kind = 'email' then null else now() end,
           sender = v_sender
     where id = r.id;
    n_sent := n_sent + 1;
  end loop;

  -- 4. Escalation: unacknowledged past the route's timer goes to the
  --    escalation role, once.
  for e in
    select n.*, rt.escalate_after_minutes, rt.escalate_to_role_id, rt.name as route_name
      from erp.notification n
      join erp.notification_route rt on rt.tenant_id = n.tenant_id and rt.id = n.route_id
     where n.tenant_id = v_tenant and n.status in ('sent', 'delivered')
       and n.escalated_at is null and n.read_at is null and n.escalation_of is null
       and rt.escalate_after_minutes is not null
       and n.created_at <= now() - make_interval(mins => rt.escalate_after_minutes)
     limit 200
  loop
    v_count := 0;
    for v_user in
      select distinct ur.app_user_id from erp.user_role ur
       join erp.app_user u on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
      where ur.tenant_id = v_tenant and ur.role_id = e.escalate_to_role_id
        and ur.valid_from <= current_date and (ur.valid_to is null or ur.valid_to >= current_date)
        and u.status = 'active' and u.kind = 'person'
    loop
      insert into erp.notification
        (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
         status, sent_at, delivered_at, escalation_of)
      values (v_tenant, e.route_id, e.event_id, e.severity, v_user, 'in_app',
              'Escalated: ' || e.subject,
              e.body || E'\n(unacknowledged for ' || e.escalate_after_minutes || ' minutes)',
              'delivered', now(), now(), e.id);
      v_count := v_count + 1;
    end loop;
    update erp.notification set escalated_at = now() where id = e.id;
    n_esc := n_esc + v_count;
  end loop;

  released := n_rel; digested := n_dig; sent := n_sent; delivered := n_del;
  suppressed := n_sup; failed := n_fail; escalated := n_esc;
  return next;
end;
$function$

;

-- ─────────────────────────────────────────────────────────────────────────────
-- The claim/settle pair, shaped like erp.claim_message_batch and its siblings.
--
-- for update skip locked, so two workers draining at once never send the same
-- message twice. The batch is marked 'sending' inside the claim, so a worker
-- that dies mid-flight leaves rows that are visibly stuck rather than rows that
-- look queued and get sent again.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.claim_email_batch(p_limit integer default 50)
returns table (
  id uuid, to_address text, subject text, body text,
  from_address text, reply_to text, severity text
)
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if erp.is_killed('notifications', 'email') then
    return;
  end if;

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
       set status = 'sending'
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
         m.severity
    from marked m
    join erp.app_user u on u.id = m.app_user_id;
end;
$$;

comment on function erp.claim_email_batch(integer) is
  'Queued email, claimed for one worker and marked sending. A worker that dies '
  'leaves rows visibly stuck rather than rows that look queued and go twice.';

create or replace function erp.complete_email(p_id uuid, p_provider_message_id text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if coalesce(trim(p_provider_message_id), '') = '' then
    raise exception 'ERPWARE_EMAIL_NEEDS_PROVIDER_ID: a message is only sent once a provider names it'
      using errcode = 'P0001',
            hint = 'Pass the id the provider returned. Without it the row cannot honestly say sent.';
  end if;

  update erp.notification
     set status = 'sent', sent_at = now(), provider_message_id = p_provider_message_id,
         failure_reason = null
   where tenant_id = v_tenant and id = p_id and status = 'sending';
end;
$$;

create or replace function erp.fail_email(p_id uuid, p_reason text, p_retry boolean default true)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); r record;
begin
  if p_retry then
    -- Back to the queue. The provider said "not now", not "never".
    update erp.notification
       set status = 'queued', failure_reason = p_reason
     where tenant_id = v_tenant and id = p_id and status = 'sending';
    return;
  end if;

  update erp.notification
     set status = 'failed', failure_reason = p_reason
   where tenant_id = v_tenant and id = p_id and status = 'sending'
  returning * into r;

  if r.id is null then
    return;
  end if;

  -- §15.6: the fallback that always works and never gets suppressed. The same
  -- promise dispatch makes when it cannot even attempt a send — a person who
  -- was going to be told something is still told it.
  insert into erp.notification
    (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
     status, sent_at, delivered_at, escalation_of)
  values (v_tenant, r.route_id, r.event_id, r.severity, r.app_user_id, 'in_app',
          r.subject, r.body || E'\n(email not delivered: ' || p_reason || ')',
          'delivered', now(), now(), r.id);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- What the provider tells us afterwards.
--
-- A send is not a delivery. The provider's webhook is the only thing that knows
-- whether the message arrived, bounced, or was complained about, so these two
-- are the entry points for it. Suppression already exists and dispatch already
-- honours it; nothing was writing to it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.record_email_delivery(p_provider_message_id text, p_delivered_at timestamptz default now())
returns void
language plpgsql
set search_path = ''
as $$
begin
  update erp.notification
     set status = 'delivered', delivered_at = p_delivered_at
   where tenant_id = erp.require_tenant_id()
     and provider_message_id = p_provider_message_id
     and status = 'sent';
end;
$$;

create or replace function erp.suppress_address(p_address text, p_reason text, p_permanent boolean default true, p_note text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  insert into erp.email_suppression (tenant_id, address, reason, is_permanent, note)
  values (v_tenant, lower(trim(p_address)), p_reason, p_permanent, p_note)
  on conflict (tenant_id, address) do update
    set reason = excluded.reason,
        is_permanent = erp.email_suppression.is_permanent or excluded.is_permanent,
        note = coalesce(excluded.note, erp.email_suppression.note);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- What is stuck, and why nothing is going out.
--
-- The three gaps that produce "no emails" are not the same gap and want
-- different answers, so the report names which one an organisation is in
-- rather than reporting a count of nothing.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.email_readiness_report()
returns table (finding text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'no notification route is defined',
         'no event becomes a notification at all, so nothing reaches the queue'
   where not exists (select 1 from erp.notification_route rt
                      where rt.tenant_id = erp.current_tenant_id() and rt.status = 'active')
  union all
  select 'no verified sender identity',
         'mail would go from the platform address rather than this organisation''s domain'
   where not exists (select 1 from erp.sender_identity s
                      where s.tenant_id = erp.current_tenant_id()
                        and s.status = 'active' and s.verified_at is not null)
  union all
  select 'email stuck in sending',
         count(*) || ' message(s) were claimed by a worker that never reported back'
    from erp.notification n
   where n.tenant_id = erp.current_tenant_id()
     and n.channel_kind = 'email' and n.status = 'sending'
     and n.created_at < now() - interval '15 minutes'
  having count(*) > 0
  union all
  select 'email queued and not moving',
         count(*) || ' message(s) have been queued for over an hour, so no sender is draining'
    from erp.notification n
   where n.tenant_id = erp.current_tenant_id()
     and n.channel_kind = 'email' and n.status = 'queued'
     and n.created_at < now() - interval '1 hour'
  having count(*) > 0;
$$;

revoke all on function erp.email_readiness_report() from public, anon;
grant execute on function erp.email_readiness_report() to authenticated, service_role;

create or replace function public.erp_email_readiness()
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform erp.authorise('administration.read');
  return coalesce((select jsonb_agg(jsonb_build_object('finding', r.finding, 'detail', r.detail))
                     from erp.email_readiness_report() r), '[]'::jsonb);
end;
$$;

revoke all on function public.erp_email_readiness() from public, anon;
grant execute on function public.erp_email_readiness() to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
  values ('erp_email_readiness', 'erp.authorise',
          'Reads why email is or is not going out. The gate writes an access-log row, which is why the door is volatile.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- The suite.
--
-- Every case here is about the one property that was wrong: a row may not say
-- an email was sent unless something sent it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.email_delivery_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
as $$
declare v_ok boolean; v_msg text;
begin
  return query select 'dispatch queues email rather than calling it sent',
    (select p.prosrc like '%then ''queued''%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'dispatch_notifications'),
    'the email branch writes queued; every other channel still settles there';

  return query select 'a sent email must name the provider''s message',
    exists (select 1 from pg_constraint
             where conrelid = 'erp.notification'::regclass
               and conname = 'notification_sent_email_has_provider_id'),
    'the constraint is what makes the status mean something';

  return query select 'completing without a provider id is refused',
    (select not exists (
       select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'erp' and p.proname = 'complete_email'
          and p.prosrc not like '%ERPWARE_EMAIL_NEEDS_PROVIDER_ID%')),
    'complete_email raises rather than recording a delivery it cannot evidence';

  return query select 'a permanent failure still tells the person, in app',
    (select p.prosrc like '%email not delivered%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'fail_email'),
    'the §15.6 fallback that never gets suppressed';

  return query select 'a transient failure goes back to the queue, not to failed',
    (select p.prosrc like '%set status = ''queued''%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'fail_email'),
    'the provider said not now, not never';

  return query select 'the claim marks sending, so a dead worker leaves stuck rows not double sends',
    (select p.prosrc like '%for update skip locked%' and p.prosrc like '%''sending''%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp' and p.proname = 'claim_email_batch'),
    'skip locked for concurrency, sending for visibility';

  return query select 'the readiness report separates the three reasons nothing sends',
    (select count(*) >= 3 from (
       select regexp_matches(p.prosrc, 'no notification route|no verified sender|stuck in sending|queued and not moving', 'g')
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'erp' and p.proname = 'email_readiness_report') x),
    'no route, no sender, and a sender that is not draining are different faults';
end;
$$;

create or replace function erp_test.assert_email_delivery_suite()
returns text
language plpgsql
as $$
declare v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not s.passed), count(*),
         string_agg(format('  %s: %s', s.case_name, s.detail), E'\n') filter (where not s.passed)
    into v_failed, v_total, v_detail
    from erp_test.email_delivery_suite() s;

  if v_failed > 0 then
    raise exception E'ERPWARE_EMAIL_DELIVERY_SUITE: % of % case(s) failed\n%',
      v_failed, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('email delivery: %s of %s cases pass', v_total, v_total);
end;
$$;

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_no_caller_reachable_internals();
select erp.assert_authorise_codes_exist();
select erp_test.assert_email_delivery_suite();

notify pgrst, 'reload schema';
