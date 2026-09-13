-- The drain serves every organisation.
--
-- The dispatch worker served only the organisations named in CLOVEERP_TENANTS,
-- each as a service principal named in CLOVEERP_PRINCIPALS. An organisation
-- nobody listed had its email queued by the minute pass and sent by nothing,
-- and on live nobody was listed. The minute pass has never needed a list:
-- erp.run_due_jobs_all_tenants() visits every active organisation from a
-- trusted session, with a tenant context and no principal, and every claim and
-- settle the worker calls asks for exactly that — a tenant, never a principal.
-- So the worker is given the same list, from the database, by the same rule.
--
-- Eight things, one file:
--
--   1. erp.dispatch_bindings() — the active organisations, in code order, for a
--      trusted session only. The worker binds each with a tenant and no
--      principal, as the minute pass does. The suite proves the refusal, the
--      list, and that a tenant with no principal claims and settles an email.
--
--   2. erp.invitation_for_resend(token) — the invite function's second mode.
--      Somebody holding an invitation link whose sign-in part has expired asks
--      for a fresh one; the function looks the token up here over the database
--      connection it is given, and emails a new sign-in link to the address on
--      file, never to one the caller names. It hashes the token as
--      erp.invite_principal, erp.provision_tenant and the platform's admin
--      invitation mint it (SHA-256, hex), and answers only for an invitation
--      erp.claim_invitation would still redeem: unclaimed, unrevoked (a
--      superseded invitation is a revoked one), unexpired, for a person who does
--      not yet sign in. Anything else is no rows, never an error, so a caller
--      probing tokens learns nothing a wrong guess would not tell them. It
--      answers with the person's id, which the allowance in 5 is asked about.
--
--   3. The scheduled dispatch request waits 55 seconds. pg_net gives up after
--      its default of a few seconds; a drain pass over every organisation takes
--      longer than that. The schedule records the new command the next time
--      deploy.yml asks for it with a URL.
--
--   4. erp.dispatch_evidence() stops printing the last pass's report. Every
--      organisation's administrator reads that row, and a pass over every
--      organisation counts every organisation's email. The row keeps the worker
--      and the timestamps; the counts stay in erp_meta.drain_pass for the
--      platform.
--
--   5. How often an invitation may be emailed. The invite function asks
--      erp.invitation_send_allowance() before it makes a sign-in link. A person
--      invited twice in ten minutes gets no second email. An organisation emails
--      at most five invitations an hour and ten a day, or twenty and fifty once
--      it has been live for more than a week. A fresh link for a pending
--      invitation waits ten minutes after the last, stops after five, and counts
--      against the same day. erp.note_invitation_link_sent() records each link
--      that left on the invitation itself (link_sent_at, links_sent), so every
--      copy of the function reads the same count.
--
--   6. A credential reference names a variable under CLOVEERP_CREDENTIAL_, or a
--      store other than env://. The worker reads env:// from the environment the
--      dispatch function runs in, which also holds the platform's own keys; a
--      webhook that named one would have had it posted to its URL. The channel
--      writer refuses such a name, and both tables that hold references carry
--      the rule as a constraint for every other writer.
--
--   7. A handler with no database body belongs to the platform's organisation.
--      The dispatch worker runs such handlers; the one there is reads the
--      providers' status feeds from a URL a job names and declares incidents
--      every organisation is emailed. erp.upsert_job() refuses one anywhere
--      else, erp.record_dependency_status() refuses a call made for another
--      organisation, and a job of that kind already switched on elsewhere is
--      switched off.
--
--   8. Email queued while nothing drained is not sent days late. On a database
--      no drain pass has served, email and webhook messages queued, pending or
--      held for more than an hour are suppressed with the reason
--      CLOVEERP_EMAIL_NOT_SENT, and each person is shown the message in the
--      product instead, as a failed send has always left it.
--
-- Two suites that were already on file follow the new rules: the webhook
-- delivery suite's credential names a variable under the prefix, and the
-- superadmin suite makes its worker-only job before it takes the handler's body
-- away, not after.
--
-- Every new function is SECURITY INVOKER on purpose. erp.session_is_trusted()
-- asks which role is running; inside a SECURITY DEFINER frame that is the owner,
-- and the test admits everybody (20260913070000 met it in propose_renewals).

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The organisations the drain serves
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.dispatch_bindings()
returns table (tenant_id uuid, tenant_code text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not list the organisations the drain serves', current_user
      using errcode = '42501',
            hint = 'The dispatch worker and the dispatch function connect as the database owner. A signed-in session never lists organisations.';
  end if;

  -- The minute pass's own predicate. Widening it (grace, restricted) changes
  -- both together or neither.
  return query
    select t.id, t.code
      from erp.tenant t
     where t.status = 'active'
     order by t.code;
end;
$$;
revoke all on function erp.dispatch_bindings() from public, anon, authenticated;

comment on function erp.dispatch_bindings() is
  'Every organisation the dispatch drain serves when no list is configured: the '
  'active ones, the set the minute pass visits, in code order. Trusted sessions '
  'only, and SECURITY INVOKER so the trust test sees the role that connected. '
  'The drain binds each with a tenant context and no principal, as the minute pass does.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. An invitation looked up by its token, for a fresh sign-in link
-- ═════════════════════════════════════════════════════════════════════════════

-- The return shape changed while this file was unreleased; a database that ran
-- the earlier shape cannot have it replaced in place.
drop function if exists erp.invitation_for_resend(text);

create or replace function erp.invitation_for_resend(p_token text)
returns table (app_user_id uuid, email text, display_name text, tenant_name text, expires_at timestamptz)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not look an invitation up by its token', current_user
      using errcode = '42501',
            hint = 'The invite function asks over its own database connection. A signed-in session redeems an invitation, it does not read one.';
  end if;

  -- The floor the claim sets. Nothing shorter was ever minted, so nothing
  -- shorter can be open.
  if p_token is null or length(p_token) < 32 then
    return;
  end if;

  -- Exactly the rows the claim would redeem: the digest matches, nobody has
  -- claimed it, it was not revoked (a superseded invitation is revoked), it has
  -- not expired, and the person it waits for does not already sign in.
  return query
    select u.id, u.email, u.display_name, t.name, i.expires_at
      from erp.invitation i
      join erp.app_user u on u.tenant_id = i.tenant_id and u.id = i.app_user_id
      join erp.tenant t on t.id = i.tenant_id
     where i.token_digest = encode(extensions.digest(p_token, 'sha256'), 'hex')
       and i.claimed_at is null
       and i.revoked_at is null
       and i.expires_at > now()
       and u.auth_user_id is null
       and u.email is not null
       and btrim(u.email) <> '';
end;
$$;
revoke all on function erp.invitation_for_resend(text) from public, anon, authenticated;

comment on function erp.invitation_for_resend(text) is
  'The person, address, name, organisation and expiry of an invitation that could '
  'still be redeemed, found by the SHA-256 digest of its token. No rows for a token '
  'that is unknown, claimed, revoked, superseded or expired, and never an error '
  'for one. Trusted sessions only: the invite function uses it to email a fresh '
  'sign-in link to the address on file.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The scheduled dispatch request waits for the drain
-- ═════════════════════════════════════════════════════════════════════════════

do $schedule$
declare
  v_def text := pg_get_functiondef('erp.ensure_platform_schedule(text,text)'::regprocedure);
  v_n   text := $n$body := ''{}''::jsonb)',$n$;
  v_r   text := $r$body := ''{}''::jsonb, timeout_milliseconds := 55000)',$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_SCHEDULE_UNRECOGNISED: erp.ensure_platform_schedule() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('timeout_milliseconds := 55000' in pg_get_functiondef('erp.ensure_platform_schedule(text,text)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_SCHEDULE_UNRECOGNISED: the dispatch command did not take its timeout';
  end if;
end
$schedule$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The evidence an organisation reads stops carrying the platform's counts
-- ═════════════════════════════════════════════════════════════════════════════

do $evidence$
declare
  v_def text := pg_get_functiondef('erp.dispatch_evidence()'::regprocedure);
  v_n   text := $n$format('last pass %s ago: %s', date_trunc('second', now() - p.finished_at), p.report::text)$n$;
  v_r   text := $r$format('last pass %s ago', date_trunc('second', now() - p.finished_at))$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_EVIDENCE_UNRECOGNISED: erp.dispatch_evidence() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('p.report' in pg_get_functiondef('erp.dispatch_evidence()'::regprocedure)) > 0 then
    raise exception 'CLOVEERP_EVIDENCE_UNRECOGNISED: erp.dispatch_evidence() still reads the pass report';
  end if;
end
$evidence$;

-- The door's allowance promised counts. It shows none now, and says why.
do $allowance$
declare v_moved integer;
begin
  update erp_meta.security_definer_allowance
     set rationale = 'Reads erp_meta.drain_pass, which is platform-internal and unreachable by a tenant session; gated on erp.authorise(administration.jobs). Of the last pass it returns only the worker and the timestamps, never the report, which counts every organisation''s work since the drain serves them all; every tenant row it reads is filtered on the caller''s tenant.'
   where schema_name = 'public' and function_name = 'erp_dispatch_evidence';
  get diagnostics v_moved = row_count;
  if v_moved <> 1 then
    raise exception 'CLOVEERP_ALLOWANCE_NOT_MOVED: % row(s) updated for public.erp_dispatch_evidence, expected 1', v_moved;
  end if;
end
$allowance$;

comment on table erp_meta.drain_pass is
  'One row per pass of the dispatch worker: who drained, when, and what it claimed '
  'and settled across every organisation it served. The console shows an '
  'organisation who and when; the counts are the platform''s and stay here.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. How often an invitation may be emailed
-- ═════════════════════════════════════════════════════════════════════════════

-- Each link the invite function emails is recorded on the invitation it was for:
-- when the latest left, and how many have. Every copy of the function reads the
-- same two columns; a count kept in one copy's memory was that copy's alone.
alter table erp.invitation
  add column if not exists link_sent_at timestamptz,
  add column if not exists links_sent integer not null default 0;

alter table erp.invitation drop constraint if exists invitation_links_sent_check;
alter table erp.invitation add constraint invitation_links_sent_check check (links_sent >= 0);

comment on column erp.invitation.link_sent_at is
  'When a sign-in link for this invitation was last emailed. Null until one is.';
comment on column erp.invitation.links_sent is
  'How many sign-in links have been emailed for this invitation, the first included.';

create or replace function erp.invitation_send_allowance(p_app_user_id uuid, p_kind text)
returns table (allowed boolean, reason text)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid;
  v_pending  erp.invitation%rowtype;
  v_generous boolean;
  v_hour_cap integer;
  v_day_cap  integer;
  v_person   integer;
  v_hour     integer;
  v_day      integer;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not ask whether an invitation may be emailed', current_user
      using errcode = '42501',
            hint = 'The invite function asks over its own database connection. A signed-in session invites through the door, and the function decides whether the email goes.';
  end if;

  if p_kind is null or p_kind not in ('invite', 'resend') then
    raise exception 'CLOVEERP_INVITATION_SEND_KIND_UNKNOWN: % is not a kind of invitation email', coalesce(p_kind, 'null')
      using errcode = '22023',
            hint = 'Ask with invite once the door has made the invitation, or with resend before a fresh sign-in link is emailed.';
  end if;

  select u.tenant_id into v_tenant from erp.app_user u where u.id = p_app_user_id;

  -- The invitation the email would be for: the newest one this person could
  -- still redeem. None, and there is nothing to email.
  if v_tenant is not null then
    select i.* into v_pending
      from erp.invitation i
     where i.tenant_id = v_tenant
       and i.app_user_id = p_app_user_id
       and i.claimed_at is null
       and i.revoked_at is null
       and i.expires_at > now()
     order by i.created_at desc, i.id desc
     limit 1;
  end if;
  if v_pending.id is null then
    return query select false, 'no such invitation'::text;
    return;
  end if;

  -- An organisation that has been live for more than a week has shown it is
  -- one. Anything newer, or not yet live, sends little until it has.
  select coalesce(erp.tenant_is_live(t.id) and t.created_at < now() - interval '7 days', false)
    into v_generous
    from erp.tenant t
   where t.id = v_tenant;
  v_hour_cap := case when v_generous then 20 else 5 end;
  v_day_cap  := case when v_generous then 50 else 10 end;

  if p_kind = 'invite' then
    -- Asked after the door made the invitation, so every count includes it.
    select count(*) into v_person
      from erp.invitation i
     where i.tenant_id = v_tenant
       and i.app_user_id = p_app_user_id
       and i.created_at > now() - interval '10 minutes';
    if v_person > 1 then
      return query select false, 'This person was invited less than ten minutes ago, so no second email was sent.'::text;
      return;
    end if;

    select count(*) filter (where i.created_at > now() - interval '1 hour'),
           count(*)
      into v_hour, v_day
      from erp.invitation i
     where i.tenant_id = v_tenant
       and i.created_at > now() - interval '1 day';
    if v_hour > v_hour_cap then
      return query select false, 'Too many invitations have been sent from this organisation in the last hour.'::text;
      return;
    end if;
    if v_day > v_day_cap then
      return query select false, 'Too many invitations have been sent from this organisation today.'::text;
      return;
    end if;

    return query select true, null::text;
    return;
  end if;

  -- resend: asked before the link is made, so the counts are of what has gone.
  if v_pending.link_sent_at is not null and v_pending.link_sent_at > now() - interval '10 minutes' then
    return query select false, 'A sign-in link for this invitation was sent less than ten minutes ago.'::text;
    return;
  end if;
  if v_pending.links_sent >= 5 then
    return query select false, 'Too many sign-in links have been sent for this invitation.'::text;
    return;
  end if;

  -- The day's email: every invitation made today, and every link re-sent. An
  -- invitation keeps its count and the time of its latest link, not a line per
  -- link, so an invitation whose latest link left today counts every link it
  -- has had beyond the one its making already counted. That can count a
  -- yesterday's link today; it cannot miss one of today's.
  select count(*) filter (where i.created_at > now() - interval '1 day')
         + coalesce(sum(case when i.created_at > now() - interval '1 day'
                             then greatest(i.links_sent - 1, 0)
                             else i.links_sent end)
                      filter (where i.link_sent_at > now() - interval '1 day'), 0)
    into v_day
    from erp.invitation i
   where i.tenant_id = v_tenant
     and (i.created_at > now() - interval '1 day' or i.link_sent_at > now() - interval '1 day');
  if v_day >= v_day_cap then
    return query select false, 'Too many invitations have been sent from this organisation today.'::text;
    return;
  end if;

  return query select true, null::text;
end;
$$;
revoke all on function erp.invitation_send_allowance(uuid, text) from public, anon, authenticated;

comment on function erp.invitation_send_allowance(uuid, text) is
  'Whether one more invitation email may go for this person. invite, asked once '
  'the door has made the invitation: no when they were invited twice in ten '
  'minutes, or the organisation is over five an hour or ten a day (twenty and '
  'fifty once it has been live for more than a week). resend, asked before a '
  'fresh sign-in link: no within ten minutes of the last link, after five, or '
  'when the day''s invitations and re-sent links reach the day''s limit. No '
  'rather than an error for a person with no pending invitation. Trusted '
  'sessions only; SECURITY INVOKER so the trust test sees the role that connected.';

create or replace function erp.note_invitation_link_sent(p_app_user_id uuid)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record that an invitation link was emailed', current_user
      using errcode = '42501',
            hint = 'The invite function records the link it sent over its own database connection. A signed-in session does not.';
  end if;

  -- The invitation the link was for: the newest this person could still redeem.
  update erp.invitation i
     set link_sent_at = now(),
         links_sent   = i.links_sent + 1
   where i.id = (select p.id
                   from erp.invitation p
                   join erp.app_user u on u.tenant_id = p.tenant_id and u.id = p.app_user_id
                  where u.id = p_app_user_id
                    and p.claimed_at is null
                    and p.revoked_at is null
                    and p.expires_at > now()
                  order by p.created_at desc, p.id desc
                  limit 1);
end;
$$;
revoke all on function erp.note_invitation_link_sent(uuid) from public, anon, authenticated;

comment on function erp.note_invitation_link_sent(uuid) is
  'Records that a sign-in link was emailed for this person''s newest pending '
  'invitation: the time, and one more to its count. Nothing for a person with '
  'none. Trusted sessions only; the invite function calls it after every send.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. A credential is a name under the platform's prefix
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The worker resolves env://NAME from the environment it runs in, and the
-- dispatch function's environment also holds the platform's own keys. So an
-- env:// reference names a variable under CLOVEERP_CREDENTIAL_ and nothing
-- else; a reference into any other store keeps the rule it had.

do $channel$
declare
  v_sig text := 'erp.upsert_notification_channel(text,text,erp.notification_channel_kind,jsonb,text,boolean)';
  v_def text := pg_get_functiondef('erp.upsert_notification_channel(text,text,erp.notification_channel_kind,jsonb,text,boolean)'::regprocedure);
  v_n   text := $n$  insert into erp.notification_channel (tenant_id, code, name, kind, settings, credential_ref, is_enabled)
$n$;
  v_r   text := $r$  -- The worker looks a reference up in its own environment, where the
  -- platform's keys also are. Only a name under CLOVEERP_CREDENTIAL_ is ever
  -- looked up, so only such a name is stored.
  if p_credential_ref ~ '^env://' and p_credential_ref !~ '^env://CLOVEERP_CREDENTIAL_[A-Z0-9_]{1,100}$' then
    raise exception 'CLOVEERP_CREDENTIAL_NAME_NOT_ALLOWED: an env:// credential names a variable that starts with CLOVEERP_CREDENTIAL_'
      using errcode = '23514',
            hint = 'Set the secret where the worker runs as CLOVEERP_CREDENTIAL_ followed by capital letters, digits or underscores, and reference it as env://CLOVEERP_CREDENTIAL_<NAME>.';
  end if;

$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_CHANNEL_WRITER_UNRECOGNISED: erp.upsert_notification_channel() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r || v_n);

  if position('CLOVEERP_CREDENTIAL_NAME_NOT_ALLOWED' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_CHANNEL_WRITER_UNRECOGNISED: erp.upsert_notification_channel() did not take the credential rule';
  end if;
end
$channel$;

-- Every other writer, and there is no function for erp.external_system at all.
-- NOT VALID: a row already on file is not re-checked here, because the worker
-- refuses it at send time and a deploy should not stop on it.
alter table erp.notification_channel drop constraint if exists notification_channel_credential_env_name;
alter table erp.notification_channel add constraint notification_channel_credential_env_name
  check (credential_ref is null
         or credential_ref !~ '^env://'
         or credential_ref ~ '^env://CLOVEERP_CREDENTIAL_[A-Z0-9_]{1,100}$') not valid;

alter table erp.external_system drop constraint if exists external_system_credential_env_name;
alter table erp.external_system add constraint external_system_credential_env_name
  check (credential_ref is null
         or credential_ref !~ '^env://'
         or credential_ref ~ '^env://CLOVEERP_CREDENTIAL_[A-Z0-9_]{1,100}$') not valid;

comment on constraint notification_channel_credential_env_name on erp.notification_channel is
  'An env:// credential names a variable under CLOVEERP_CREDENTIAL_, the only names the worker resolves.';
comment on constraint external_system_credential_env_name on erp.external_system is
  'An env:// credential names a variable under CLOVEERP_CREDENTIAL_, the only names the worker resolves.';

-- The webhook suite's fixture named a variable outside the prefix.
do $webhook_suite$
declare
  v_def text := pg_get_functiondef('erp_test.webhook_delivery_suite()'::regprocedure);
  v_n   text := 'env://ZZ_HOOK_TOKEN';
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 3 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.webhook_delivery_suite() does not name env://ZZ_HOOK_TOKEN three times';
  end if;
  execute replace(v_def, v_n, 'env://CLOVEERP_CREDENTIAL_ZZ_HOOK_TOKEN');
end
$webhook_suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. A handler only the worker runs belongs to the platform's organisation
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A handler with no database body is run by the dispatch worker, on its own
-- trusted connection, for whichever organisation it is serving. The one there
-- is reads the providers' status feeds, from a URL a job can name, and declares
-- incidents below the platform that every organisation is then emailed. That is
-- the platform's work. Scheduling it, and recording what a feed says, stay in
-- the platform's own organisation.

do $jobs$
declare
  v_sig text := 'erp.upsert_job(text,text,text,text,integer,time,text,integer,text,jsonb,integer,integer,boolean)';
  v_def text := pg_get_functiondef('erp.upsert_job(text,text,text,text,integer,time,text,integer,text,jsonb,integer,integer,boolean)'::regprocedure);
  v_n   text := $n$  if jsonb_typeof(coalesce(p_parameters, '{}'::jsonb)) <> 'object' then
$n$;
  v_r   text := $r$  -- A handler with no database body runs on the dispatch worker, for the
  -- platform: scheduling one belongs to the platform's own organisation.
  if h.sql_function is null and not erp.is_platform_organisation(v_tenant) then
    raise exception 'CLOVEERP_JOB_HANDLER_PLATFORM_ONLY: % runs only in the platform''s own organisation', p_handler_code
      using errcode = '42501',
            hint = 'Choose a handler that runs in the database. The platform runs this one for every organisation and tells each what it finds.';
  end if;

$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_JOB_WRITER_UNRECOGNISED: erp.upsert_job() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r || v_n);

  if position('CLOVEERP_JOB_HANDLER_PLATFORM_ONLY' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_JOB_WRITER_UNRECOGNISED: erp.upsert_job() did not take the platform handler rule';
  end if;
end
$jobs$;

do $dependency$
declare
  v_sig text := 'erp.record_dependency_status(text,text,text,jsonb,text)';
  v_def text := pg_get_functiondef('erp.record_dependency_status(text,text,text,jsonb,text)'::regprocedure);
  v_n   text := $n$a person declares an incident through the console.';
  end if;
$n$;
  v_r   text := $r$  -- What a provider's feed says is the platform's to record. A session acting
  -- for any other organisation, or a job it scheduled, is refused; the
  -- platform's sweep, which acts for no organisation, is not.
  if erp.current_tenant_id() is not null and not erp.is_platform_organisation(erp.current_tenant_id()) then
    raise exception 'CLOVEERP_DEPENDENCY_STATUS_OUTSIDE_PLATFORM: only the platform''s own organisation records what a provider''s status feed says'
      using errcode = '42501',
            hint = 'Schedule the provider status job in the platform organisation. It declares an incident below the platform and every organisation is told.';
  end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_DEPENDENCY_STATUS_UNRECOGNISED: erp.record_dependency_status() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_n || v_r);

  if position('CLOVEERP_DEPENDENCY_STATUS_OUTSIDE_PLATFORM' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_DEPENDENCY_STATUS_UNRECOGNISED: erp.record_dependency_status() did not take the platform rule';
  end if;
end
$dependency$;

-- A job of that kind already switched on elsewhere is switched off. It is left
-- on file, so the organisation sees what it had; the refusal above says why it
-- cannot be switched back on.
do $platform_jobs$
declare
  t       record;
  v_n     integer;
  v_total integer := 0;
begin
  for t in
    select distinct j.tenant_id, tn.code
      from erp.job j
      join erp_ref.job_handler h on h.code = j.handler_code
      join erp.tenant tn on tn.id = j.tenant_id
     where h.sql_function is null
       and j.is_enabled
       and not erp.is_platform_organisation(j.tenant_id)
     order by tn.code
  loop
    perform set_config('erp.job_tenant_id', t.tenant_id::text, true);
    perform set_config('erp.job_principal_id', '', true);
    update erp.job j
       set is_enabled = false
      from erp_ref.job_handler h
     where j.tenant_id = t.tenant_id
       and h.code = j.handler_code
       and h.sql_function is null
       and j.is_enabled;
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
    raise warning '%: % job(s) on a handler only the platform organisation runs were switched off', t.code, v_n;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  raise notice 'platform handlers: % job(s) outside the platform organisation switched off', v_total;
end
$platform_jobs$;

-- The superadmin suite's honesty case made a job on a handler whose body it had
-- just taken away, which is now refused outside the platform organisation. It
-- makes the job first and takes the body away after; the case is the same one.
do $superadmin_suite$
declare
  v_def text := pg_get_functiondef('erp_test.superadmin_suite()'::regprocedure);
  v_n   text := $n$  update erp_ref.job_handler set sql_function = null
   where code = 'platform.reclaim_timed_out_runs';
  perform erp.upsert_job('zzworker', 'Needs the worker',
                         'platform.reclaim_timed_out_runs', 'interval', 60);
$n$;
  v_r   text := $r$  perform erp.upsert_job('zzworker', 'Needs the worker',
                         'platform.reclaim_timed_out_runs', 'interval', 60);
  update erp_ref.job_handler set sql_function = null
   where code = 'platform.reclaim_timed_out_runs';
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: erp_test.superadmin_suite() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$superadmin_suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Email queued for nobody is shown in the product, not sent days late
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Until now nothing drained. Whatever email or webhook message was queued,
-- pending or held in that time would leave on the first pass, however old. On
-- a database no drain pass has served, a message more than an hour old is
-- suppressed with its reason and the person is shown it in the product, the
-- in-app copy a failed send has always left (escalation_of names the message
-- it stands in for). Anything younger goes out as normal.

create or replace function erp.retire_undrained_notifications()
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_count  integer;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not retire queued messages', current_user
      using errcode = '42501',
            hint = 'The release that first drains email retires what waited for it. A signed-in session never does.';
  end if;

  v_tenant := erp.require_tenant_id();

  with retired as (
    update erp.notification n
       set status           = 'suppressed',
           failure_reason   = 'CLOVEERP_EMAIL_NOT_SENT: queued before this platform could send it, so it is shown in the product instead',
           held_until       = null,
           claimed_by       = null,
           lease_expires_at = null
     where n.tenant_id = v_tenant
       and n.channel_kind in ('email', 'webhook')
       and n.status in ('queued', 'pending', 'held')
       and n.created_at < now() - interval '1 hour'
    returning n.id, n.tenant_id, n.route_id, n.event_id, n.severity, n.app_user_id,
              n.channel_kind, n.subject, n.body
  )
  insert into erp.notification
    (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
     status, sent_at, delivered_at, escalation_of)
  select r.tenant_id, r.route_id, r.event_id, r.severity, r.app_user_id, 'in_app'::erp.notification_channel_kind,
         r.subject, r.body || E'\n(' || r.channel_kind::text || ' not sent: it was queued before this platform could send it)',
         'delivered', now(), now(), r.id
    from retired r;
  get diagnostics v_count = row_count;

  return v_count;
end;
$$;
revoke all on function erp.retire_undrained_notifications() from public, anon, authenticated;

comment on function erp.retire_undrained_notifications() is
  'Suppresses the organisation''s email and webhook messages that have been '
  'queued, pending or held for more than an hour, with the reason '
  'CLOVEERP_EMAIL_NOT_SENT, and gives each person the in-app copy a failed send '
  'leaves. Returns how many. Run once, by the release that first drains email, '
  'on a database no drain pass has served. Trusted sessions only.';

do $backlog$
declare
  t       record;
  v_n     integer;
  v_total integer := 0;
begin
  if exists (select 1 from erp_meta.drain_pass) then
    raise notice 'queued messages: a drain pass has run here, so nothing waited for nobody';
    return;
  end if;

  for t in
    select tn.id, tn.code
      from erp.tenant tn
     where exists (select 1 from erp.notification n
                    where n.tenant_id = tn.id
                      and n.channel_kind in ('email', 'webhook')
                      and n.status in ('queued', 'pending', 'held')
                      and n.created_at < now() - interval '1 hour')
     order by tn.code
  loop
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', t.id::text, true);
    perform set_config('erp.job_principal_id', '', true);
    v_n := erp.retire_undrained_notifications();
    v_total := v_total + v_n;
    raise notice '%: % message(s) queued before email could leave are shown in the product instead', t.code, v_n;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);

  raise notice 'queued messages: % retired', v_total;
end
$backlog$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suites
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.dispatch_bindings_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r          record;
  v_code     text := 'zz-drain-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_parked   text := 'zz-drain-parked-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_ok       boolean;
  v_msg      text;
  v_state    text;
  v_missing  integer;
  v_extra    integer;
  v_in_order boolean;
  v_parked_n integer;
  v_mail     uuid;
  v_claimed  integer;
  v_status   text;
  v_actor    uuid;
  v_worker   text;
  v_latest   text;
  v_evidence text;
begin
  -- 1. Refused without EXECUTE.
  begin
    execute 'set local role authenticated';
    perform 1 from erp.dispatch_bindings();
    execute 'reset role';
    v_ok := false; v_msg := 'a signed-in session listed every organisation';
  exception when others then
    execute 'reset role';
    v_ok := sqlstate = '42501'; v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a signed-in session cannot list the organisations the drain serves';
  passed := v_ok; detail := v_msg;
  return next;

  -- 2. Refused by the function itself, should a grant ever reach it.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.dispatch_bindings() to authenticated';
    execute 'set local role authenticated';
    perform 1 from erp.dispatch_bindings();
    v_msg := 'with execute granted, a signed-in session listed every organisation';
    raise exception 'ZZ_DRAIN_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_DRAIN_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, the function still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 3.
  select not p.prosecdef into v_ok
    from pg_catalog.pg_proc p where p.oid = 'erp.dispatch_bindings()'::regprocedure;
  case_name := 'the trust test runs in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 4-7 build an organisation, read and drain it, and undo all of it.
  begin
    -- Inserted before any tenant context exists, as an organisation that is
    -- being suspended would already be on file.
    insert into erp.tenant (code, name, status) values (v_parked, 'Drain suite, suspended', 'suspended');

    select * into r from erp.provision_tenant(v_code, 'Drain suite', 'admin@' || v_code || '.test', 'Drain Admin');

    select count(*) into v_missing
      from erp.tenant t
     where t.status = 'active'
       and not exists (select 1 from erp.dispatch_bindings() b where b.tenant_id = t.id);
    select count(*) into v_extra
      from erp.dispatch_bindings() b
     where not exists (select 1 from erp.tenant t where t.id = b.tenant_id and t.status = 'active');
    select (select array_agg(b.tenant_code) from erp.dispatch_bindings() b)
           is not distinct from
           (select array_agg(t.code order by t.code) from erp.tenant t where t.status = 'active')
      into v_in_order;
    select count(*) into v_parked_n from erp.dispatch_bindings() b where b.tenant_code = v_parked;

    -- The binding the drain makes: this organisation, and nobody acting in it.
    perform erp.set_job_tenant(r.tenant_id);
    perform erp.set_job_principal(null);
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (r.tenant_id, 'info', r.admin_user_id, 'email', 'Drain suite', 'Claimed with a tenant and no principal.', 'queued')
    returning id into v_mail;
    select count(*) filter (where c.id = v_mail) into v_claimed
      from erp.claim_email_batch(50, 'zz-drain-suite') c;
    perform erp.complete_email(v_mail, 'zz-drain-provider-1');
    select n.status into v_status from erp.notification n where n.id = v_mail;
    v_actor := erp.current_principal_id();

    -- A pass whose report counts other organisations' email.
    perform erp.record_drain_pass('zz-drain-suite', now(),
                                  jsonb_build_object('organisations', 3, 'emailClaimed', 7, 'emailSent', 7));
    -- One statement, one snapshot: the evidence and the register are read at
    -- the same moment, whatever else is draining.
    select e.worker, e.detail,
           (select p.worker from erp_meta.drain_pass p order by p.finished_at desc limit 1)
      into v_worker, v_evidence, v_latest
      from erp.dispatch_evidence() e where e.queue = 'platform';

    raise exception 'ZZ_DRAIN_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_DRAIN_SUITE_UNDO' then v_state := left(sqlerrm, 160); end if;
  end;

  case_name := 'every active organisation is listed, once, in code order, and nothing else';
  passed := v_state is null and v_missing = 0 and v_extra = 0 and coalesce(v_in_order, false);
  detail := coalesce(v_state, format('%s active not listed, %s listed not active, in code order: %s',
                                     v_missing, v_extra, coalesce(v_in_order::text, 'unknown')));
  return next;

  case_name := 'an organisation that is not active is not served';
  passed := v_state is null and v_parked_n = 0;
  detail := coalesce(v_state, format('suspended organisation listed %s time(s)', v_parked_n));
  return next;

  case_name := 'a tenant context with no principal claims and settles an email';
  passed := v_state is null and v_claimed = 1 and v_status = 'sent' and v_actor is null;
  detail := coalesce(v_state, format('claimed %s, status %s, acting principal %s',
                                     v_claimed, v_status, coalesce(v_actor::text, 'none')));
  return next;

  case_name := 'an organisation reads who drained and when, never the pass report';
  passed := v_state is null
            and v_worker is not distinct from v_latest
            and v_evidence like 'last pass %'
            and position('{' in coalesce(v_evidence, '{')) = 0
            and position('emailSent' in coalesce(v_evidence, '')) = 0;
  detail := coalesce(v_state, format('worker %s (last pass by %s): %s',
                                     coalesce(v_worker, 'none'), coalesce(v_latest, 'none'), coalesce(v_evidence, 'no detail')));
  return next;
end;
$$;
revoke all on function erp_test.dispatch_bindings_suite() from public, anon, authenticated;

create or replace function erp_test.assert_dispatch_bindings_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _dispatch_bindings on commit drop as
    select * from erp_test.dispatch_bindings_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _dispatch_bindings;
  drop table _dispatch_bindings;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DISPATCH_BINDINGS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DISPATCH_BINDINGS_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('dispatch bindings: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_dispatch_bindings_suite() from public, anon, authenticated;

create or replace function erp_test.invitation_for_resend_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r            record;
  v_code       text := 'zz-resend-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_subject    uuid := gen_random_uuid();
  v_expired    text := encode(extensions.gen_random_bytes(32), 'hex');
  v_ok         boolean;
  v_msg        text;
  v_state      text;
  v_fresh_n    integer;
  v_fresh_ok   boolean;
  v_fresh      text;
  v_expired_n  integer;
  v_claimed_n  integer;
  v_first      text;
  v_second     text;
  v_first_n    integer;
  v_second_n   integer;
  v_superseded boolean;
  v_garbage_n  integer;
begin
  -- 1. Refused without EXECUTE.
  begin
    execute 'set local role authenticated';
    perform 1 from erp.invitation_for_resend(repeat('a', 64));
    execute 'reset role';
    v_ok := false; v_msg := 'a signed-in session looked an invitation up by its token';
  exception when others then
    execute 'reset role';
    v_ok := sqlstate = '42501'; v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a signed-in session cannot look an invitation up by its token';
  passed := v_ok; detail := v_msg;
  return next;

  -- 2. Refused by the function itself, should a grant ever reach it.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.invitation_for_resend(text) to authenticated';
    execute 'set local role authenticated';
    perform 1 from erp.invitation_for_resend(repeat('a', 64));
    v_msg := 'with execute granted, a signed-in session was answered';
    raise exception 'ZZ_RESEND_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_RESEND_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, the lookup still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 3.
  select not p.prosecdef into v_ok
    from pg_catalog.pg_proc p where p.oid = 'erp.invitation_for_resend(text)'::regprocedure;
  case_name := 'the lookup''s trust test runs in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 4-7 mint, age, claim and supersede invitations through the real doors, and
  -- undo all of it.
  begin
    select * into r from erp.provision_tenant(v_code, 'Resend suite', 'admin@' || v_code || '.test', 'Resend Admin');

    -- A fresh invitation: the one provisioning minted.
    select count(*),
           coalesce(bool_and(f.app_user_id = r.admin_user_id
                             and f.email = 'admin@' || v_code || '.test'
                             and f.display_name = 'Resend Admin'
                             and f.tenant_name = 'Resend suite'
                             and f.expires_at = (select i.expires_at from erp.invitation i
                                                  where i.tenant_id = r.tenant_id and i.app_user_id = r.admin_user_id)), false),
           max(format('%s, %s, %s, %s, %s', f.app_user_id, f.email, f.display_name, f.tenant_name, f.expires_at))
      into v_fresh_n, v_fresh_ok, v_fresh
      from erp.invitation_for_resend(r.admin_token) f;

    -- An expired one. now() is the transaction's start, so only a row minted in
    -- the past can be expired; both timestamps go back, as the claim's own
    -- suite ages one (0044).
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at)
    values (r.tenant_id, r.admin_user_id, encode(extensions.digest(v_expired, 'sha256'), 'hex'),
            now() - interval '15 days', now() - interval '1 day');
    select count(*) into v_expired_n from erp.invitation_for_resend(v_expired);

    -- A claimed one: the administrator signs in and redeems it.
    perform set_config('request.jwt.claims', json_build_object('sub', v_subject)::text, true);
    perform erp.claim_invitation(r.admin_token);
    select count(*) into v_claimed_n from erp.invitation_for_resend(r.admin_token);

    -- A superseded one: the administrator invites a colleague, then invites
    -- them again, which withdraws the first token.
    select i.token into v_first from erp.invite_principal('colleague@' || v_code || '.test', 'A Colleague') i;
    select i.token into v_second from erp.invite_principal('colleague@' || v_code || '.test', 'A Colleague') i;
    select count(*) into v_first_n from erp.invitation_for_resend(v_first);
    select count(*) into v_second_n from erp.invitation_for_resend(v_second);
    select exists (select 1 from erp.invitation i
                    where i.token_digest = encode(extensions.digest(v_first, 'sha256'), 'hex')
                      and i.revoked_at is not null and i.revoked_reason like 'superseded%')
      into v_superseded;

    raise exception 'ZZ_RESEND_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_RESEND_SUITE_UNDO' then v_state := left(sqlerrm, 160); end if;
  end;

  case_name := 'a fresh invitation is found, with the person, address, name, organisation and expiry it was minted with';
  passed := v_state is null and v_fresh_n = 1 and v_fresh_ok;
  detail := coalesce(v_state, format('%s row(s): %s', v_fresh_n, coalesce(v_fresh, 'none')));
  return next;

  case_name := 'an expired invitation is not found';
  passed := v_state is null and v_expired_n = 0;
  detail := coalesce(v_state, format('%s row(s) for a token that expired yesterday', v_expired_n));
  return next;

  case_name := 'a claimed invitation is not found';
  passed := v_state is null and v_claimed_n = 0;
  detail := coalesce(v_state, format('%s row(s) for a token already redeemed', v_claimed_n));
  return next;

  case_name := 'a superseded invitation is not found, and the one that replaced it is';
  passed := v_state is null and coalesce(v_superseded, false) and v_first_n = 0 and v_second_n = 1;
  detail := coalesce(v_state, format('first token %s row(s), superseded %s; second token %s row(s)',
                                     v_first_n, coalesce(v_superseded::text, 'unknown'), v_second_n));
  return next;

  -- 8. Garbage is zero rows, never an error.
  begin
    select count(*) into v_garbage_n
      from (select 1 from erp.invitation_for_resend(null)
            union all select 1 from erp.invitation_for_resend('')
            union all select 1 from erp.invitation_for_resend('not an invitation')
            union all select 1 from erp.invitation_for_resend(repeat('0', 64))
            union all select 1 from erp.invitation_for_resend(encode(extensions.gen_random_bytes(32), 'hex'))) g;
    v_ok := v_garbage_n = 0;
    v_msg := format('%s row(s) for five tokens nobody minted', v_garbage_n);
  exception when others then
    v_ok := false; v_msg := 'raised: ' || left(sqlerrm, 120);
  end;
  case_name := 'a token nobody minted returns no rows and raises nothing';
  passed := v_ok; detail := v_msg;
  return next;
end;
$$;
revoke all on function erp_test.invitation_for_resend_suite() from public, anon, authenticated;

create or replace function erp_test.assert_invitation_for_resend_suite()
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
  create temp table if not exists _invitation_for_resend on commit drop as
    select * from erp_test.invitation_for_resend_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _invitation_for_resend;
  drop table _invitation_for_resend;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INVITATION_RESEND_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_INVITATION_RESEND_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('invitation resend: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_invitation_for_resend_suite() from public, anon, authenticated;

create or replace function erp_test.invitation_send_allowance_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tag            text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_young          uuid;
  v_old            uuid;
  v_parked         uuid;
  v_daily          uuid;
  v_p              uuid;
  v_q              uuid;
  v_i              integer;
  v_ok             boolean;
  v_msg            text;
  v_hint           text;
  v_state          text;
  v_unknown_invite text;
  v_unknown_resend text;
  v_first_ok       boolean;
  v_first_reason   text;
  v_again_ok       boolean;
  v_again_reason   text;
  v_young_fifth    boolean;
  v_young_sixth    boolean;
  v_young_reason   text;
  v_old_sixth      boolean;
  v_old_last       boolean;
  v_old_reason     text;
  v_parked_sixth   boolean;
  v_tenth          boolean;
  v_eleventh       boolean;
  v_daily_reason   text;
  v_recent_ok      boolean;
  v_recent_reason  text;
  v_later_ok       boolean;
  v_worn_ok        boolean;
  v_worn_reason    text;
  v_resend_ninth   boolean;
  v_resend_tenth   boolean;
  v_resend_reason  text;
  v_claimed_invite text;
  v_claimed_resend text;
  v_noted_at       timestamptz;
  v_noted_n        integer;
  v_other_n        integer;
  v_noted_raised   text;
  v_noted_ok       boolean;
  v_noted_reason   text;
  v_reasons        text;
begin
  -- 1. The allowance refuses a signed-in session itself, should a grant ever reach it.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.invitation_send_allowance(uuid, text) to authenticated';
    execute 'set local role authenticated';
    perform 1 from erp.invitation_send_allowance(gen_random_uuid(), 'invite');
    v_msg := 'with execute granted, a signed-in session was answered';
    raise exception 'ZZ_ALLOWANCE_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_ALLOWANCE_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, the allowance still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 2. So does the record of a sent link.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.note_invitation_link_sent(uuid) to authenticated';
    execute 'set local role authenticated';
    perform erp.note_invitation_link_sent(gen_random_uuid());
    v_msg := 'with execute granted, a signed-in session recorded a sent link';
    raise exception 'ZZ_ALLOWANCE_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_ALLOWANCE_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, recording a sent link still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 3.
  select bool_and(not p.prosecdef) into v_ok
    from pg_catalog.pg_proc p
   where p.oid in ('erp.invitation_send_allowance(uuid,text)'::regprocedure,
                   'erp.note_invitation_link_sent(uuid)'::regprocedure);
  case_name := 'both trust tests run in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 4.
  v_ok := false; v_msg := null; v_hint := null;
  begin
    perform 1 from erp.invitation_send_allowance(gen_random_uuid(), 'remind');
    v_msg := 'a kind that is neither invite nor resend was answered';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint;
    v_ok := sqlstate = '22023' and sqlerrm like 'CLOVEERP_INVITATION_SEND_KIND_UNKNOWN:%' and coalesce(v_hint, '') <> '';
    v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a kind that is neither invite nor resend is refused by name, with the next action';
  passed := v_ok; detail := v_msg;
  return next;

  -- 5.
  begin
    select coalesce(format('%s, %s', a.allowed, a.reason), 'no row') into v_unknown_invite
      from erp.invitation_send_allowance(gen_random_uuid(), 'invite') a;
    select coalesce(format('%s, %s', a.allowed, a.reason), 'no row') into v_unknown_resend
      from erp.invitation_send_allowance(gen_random_uuid(), 'resend') a;
    v_msg := null;
  exception when others then
    v_msg := 'raised: ' || left(sqlerrm, 120);
  end;
  case_name := 'a person nobody invited is answered no, never an error';
  passed := v_msg is null
            and v_unknown_invite = 'false, no such invitation'
            and v_unknown_resend = 'false, no such invitation';
  detail := coalesce(v_msg, format('invite: %s; resend: %s', v_unknown_invite, v_unknown_resend));
  return next;

  -- 6-18 build four organisations and their invitations by hand, ask, and undo
  -- all of it. The rows are written directly so their times can be set: the
  -- attribution trigger keeps a created_at from being moved later.
  begin
    -- Nobody signed in: every row below is written for the organisation named.
    perform set_config('request.jwt.claims', '', true);

    -- A new organisation, already live.
    insert into erp.tenant (code, name, status)
    values ('zz-allow-new-' || v_tag, 'Allowance suite, new', 'active') returning id into v_young;
    -- Live for a month.
    insert into erp.tenant (code, name, status, created_at)
    values ('zz-allow-old-' || v_tag, 'Allowance suite, established', 'active', now() - interval '30 days') returning id into v_old;
    -- A month old, and never live.
    insert into erp.tenant (code, name, status, created_at)
    values ('zz-allow-built-' || v_tag, 'Allowance suite, not live', 'active', now() - interval '30 days') returning id into v_parked;
    -- New and not live, for the day's limits.
    insert into erp.tenant (code, name, status)
    values ('zz-allow-day-' || v_tag, 'Allowance suite, daily', 'active') returning id into v_daily;

    perform erp.set_job_tenant(v_young);
    insert into erp.environment (tenant_id, code, name, kind, is_live, is_self)
    values (v_young, 'production', 'Production', 'production', true, true);
    perform erp.set_job_tenant(v_old);
    insert into erp.environment (tenant_id, code, name, kind, is_live, is_self)
    values (v_old, 'production', 'Production', 'production', true, true);
    perform erp.set_job_tenant(v_parked);
    insert into erp.environment (tenant_id, code, name, kind, is_live, is_self)
    values (v_parked, 'production', 'Production', 'production', false, true);
    perform erp.set_job_tenant(v_daily);
    insert into erp.environment (tenant_id, code, name, kind, is_live, is_self)
    values (v_daily, 'production', 'Production', 'production', false, true);

    -- ── The new organisation: one person, invited, then invited again ─────────
    perform erp.set_job_tenant(v_young);
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_young, 'person', 'invited', 'First Person', 'first@' || v_tag || '.test') returning id into v_p;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
    values (v_young, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now() + interval '7 days');
    select a.allowed, a.reason into v_first_ok, v_first_reason
      from erp.invitation_send_allowance(v_p, 'invite') a;

    update erp.invitation i set revoked_at = now(), revoked_reason = 'superseded by a new invitation'
     where i.tenant_id = v_young and i.app_user_id = v_p and i.revoked_at is null;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
    values (v_young, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now() + interval '7 days');
    select a.allowed, a.reason into v_again_ok, v_again_reason
      from erp.invitation_send_allowance(v_p, 'invite') a;

    -- Three more people make five invitations this hour; a fourth makes six.
    for v_i in 1..3 loop
      insert into erp.app_user (tenant_id, kind, status, display_name, email)
      values (v_young, 'person', 'invited', 'Person ' || v_i, 'new' || v_i || '@' || v_tag || '.test') returning id into v_q;
      insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
      values (v_young, v_q, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now() + interval '7 days');
    end loop;
    select a.allowed into v_young_fifth from erp.invitation_send_allowance(v_q, 'invite') a;
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_young, 'person', 'invited', 'Person 4', 'new4@' || v_tag || '.test') returning id into v_q;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
    values (v_young, v_q, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now() + interval '7 days');
    select a.allowed, a.reason into v_young_sixth, v_young_reason
      from erp.invitation_send_allowance(v_q, 'invite') a;

    -- ── The established organisation: six this hour, then twenty-one ─────────
    perform erp.set_job_tenant(v_old);
    for v_i in 1..21 loop
      insert into erp.app_user (tenant_id, kind, status, display_name, email)
      values (v_old, 'person', 'invited', 'Person ' || v_i, 'old' || v_i || '@' || v_tag || '.test') returning id into v_q;
      insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
      values (v_old, v_q, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now() + interval '7 days');
      if v_i = 6 then
        select a.allowed into v_old_sixth from erp.invitation_send_allowance(v_q, 'invite') a;
      end if;
    end loop;
    select a.allowed, a.reason into v_old_last, v_old_reason
      from erp.invitation_send_allowance(v_q, 'invite') a;

    -- ── Old but never live: six this hour ────────────────────────────────────
    perform erp.set_job_tenant(v_parked);
    for v_i in 1..6 loop
      insert into erp.app_user (tenant_id, kind, status, display_name, email)
      values (v_parked, 'person', 'invited', 'Person ' || v_i, 'built' || v_i || '@' || v_tag || '.test') returning id into v_q;
      insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
      values (v_parked, v_q, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now() + interval '7 days');
    end loop;
    select a.allowed into v_parked_sixth from erp.invitation_send_allowance(v_q, 'invite') a;

    -- ── The day: nine made this morning, then a tenth and an eleventh now ───
    perform erp.set_job_tenant(v_daily);
    for v_i in 1..11 loop
      insert into erp.app_user (tenant_id, kind, status, display_name, email)
      values (v_daily, 'person', 'invited', 'Person ' || v_i, 'day' || v_i || '@' || v_tag || '.test') returning id into v_q;
      insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at)
      values (v_daily, v_q, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
              case when v_i <= 9 then now() - interval '3 hours' else now() end, now() + interval '7 days');
      if v_i = 10 then
        select a.allowed into v_tenth from erp.invitation_send_allowance(v_q, 'invite') a;
      end if;
    end loop;
    select a.allowed, a.reason into v_eleventh, v_daily_reason
      from erp.invitation_send_allowance(v_q, 'invite') a;

    -- ── Resending, in the established organisation ───────────────────────────
    -- Invitations made two days ago, so only their links count today.
    perform erp.set_job_tenant(v_old);
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_old, 'person', 'invited', 'Recent Link', 'recent@' || v_tag || '.test') returning id into v_p;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at, link_sent_at, links_sent)
    values (v_old, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            now() - interval '2 days', now() + interval '5 days', now() - interval '5 minutes', 1);
    select a.allowed, a.reason into v_recent_ok, v_recent_reason
      from erp.invitation_send_allowance(v_p, 'resend') a;

    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_old, 'person', 'invited', 'Older Link', 'older@' || v_tag || '.test') returning id into v_p;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at, link_sent_at, links_sent)
    values (v_old, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            now() - interval '2 days', now() + interval '5 days', now() - interval '11 minutes', 1);
    select a.allowed into v_later_ok from erp.invitation_send_allowance(v_p, 'resend') a;

    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_old, 'person', 'invited', 'Worn Link', 'worn@' || v_tag || '.test') returning id into v_p;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at, link_sent_at, links_sent)
    values (v_old, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            now() - interval '2 days', now() + interval '5 days', now() - interval '2 hours', 5);
    select a.allowed, a.reason into v_worn_ok, v_worn_reason
      from erp.invitation_send_allowance(v_p, 'resend') a;

    -- A claimed invitation is nothing to email, either way.
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_old, 'person', 'invited', 'Claimed', 'claimed@' || v_tag || '.test') returning id into v_p;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at, claimed_at, claimed_by)
    values (v_old, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            now() + interval '7 days', now(), gen_random_uuid());
    select coalesce(format('%s, %s', a.allowed, a.reason), 'no row') into v_claimed_invite
      from erp.invitation_send_allowance(v_p, 'invite') a;
    select coalesce(format('%s, %s', a.allowed, a.reason), 'no row') into v_claimed_resend
      from erp.invitation_send_allowance(v_p, 'resend') a;

    -- ── Resending against the day, in the organisation that was never live ──
    -- Six made this hour, and a person whose invitation is two days old and has
    -- had three links, the latest twenty minutes ago: nine today. Then one more
    -- invitation makes ten.
    perform erp.set_job_tenant(v_parked);
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_parked, 'person', 'invited', 'Resent', 'resent@' || v_tag || '.test') returning id into v_p;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at, link_sent_at, links_sent)
    values (v_parked, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            now() - interval '2 days', now() + interval '5 days', now() - interval '20 minutes', 3);
    select a.allowed into v_resend_ninth from erp.invitation_send_allowance(v_p, 'resend') a;
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_parked, 'person', 'invited', 'Person 7', 'built7@' || v_tag || '.test') returning id into v_q;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
    values (v_parked, v_q, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now() + interval '7 days');
    select a.allowed, a.reason into v_resend_tenth, v_resend_reason
      from erp.invitation_send_allowance(v_p, 'resend') a;

    -- ── The record of a sent link ─────────────────────────────────────────────
    -- A superseded invitation from three days ago and the pending one that
    -- replaced it: the link is for the pending one.
    perform erp.set_job_tenant(v_old);
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (v_old, 'person', 'invited', 'Noted', 'noted@' || v_tag || '.test') returning id into v_p;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at, revoked_at, revoked_reason)
    values (v_old, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            now() - interval '3 days', now() + interval '4 days', now() - interval '2 days', 'superseded by a new invitation');
    insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at)
    values (v_old, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
            now() - interval '2 days', now() + interval '5 days');
    perform erp.note_invitation_link_sent(v_p);
    perform erp.note_invitation_link_sent(v_p);
    select i.link_sent_at, i.links_sent into v_noted_at, v_noted_n
      from erp.invitation i
     where i.tenant_id = v_old and i.app_user_id = v_p and i.revoked_at is null;
    select coalesce(sum(i.links_sent), 0) into v_other_n
      from erp.invitation i
     where i.tenant_id = v_old and i.app_user_id = v_p and i.revoked_at is not null;
    begin
      perform erp.note_invitation_link_sent(gen_random_uuid());
    exception when others then
      v_noted_raised := left(sqlerrm, 120);
    end;
    select a.allowed, a.reason into v_noted_ok, v_noted_reason
      from erp.invitation_send_allowance(v_p, 'resend') a;

    raise exception 'ZZ_ALLOWANCE_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_ALLOWANCE_SUITE_UNDO' then v_state := left(sqlerrm, 200); end if;
  end;

  case_name := 'an invitation the door has just made may be emailed';
  passed := v_state is null and coalesce(v_first_ok, false) and v_first_reason is null;
  detail := coalesce(v_state, format('allowed %s, reason %s', v_first_ok, coalesce(v_first_reason, 'none')));
  return next;

  case_name := 'the same person invited again within ten minutes gets no second email';
  passed := v_state is null and v_again_ok is false and coalesce(v_again_reason, '') <> '';
  detail := coalesce(v_state, format('allowed %s: %s', v_again_ok, coalesce(v_again_reason, 'no reason')));
  return next;

  case_name := 'a new organisation may email five invitations an hour, and not a sixth';
  passed := v_state is null and coalesce(v_young_fifth, false) and v_young_sixth is false
            and v_young_reason = 'Too many invitations have been sent from this organisation in the last hour.';
  detail := coalesce(v_state, format('fifth %s; sixth %s: %s', v_young_fifth, v_young_sixth, coalesce(v_young_reason, 'no reason')));
  return next;

  case_name := 'an organisation live for more than a week may email twenty an hour: the sixth goes, the twenty-first does not';
  passed := v_state is null and coalesce(v_old_sixth, false) and v_old_last is false
            and v_old_reason = 'Too many invitations have been sent from this organisation in the last hour.';
  detail := coalesce(v_state, format('sixth %s; twenty-first %s: %s', v_old_sixth, v_old_last, coalesce(v_old_reason, 'no reason')));
  return next;

  case_name := 'an organisation that has never gone live is held to five an hour however old it is';
  passed := v_state is null and v_parked_sixth is false;
  detail := coalesce(v_state, format('sixth %s', v_parked_sixth));
  return next;

  case_name := 'a new organisation may email ten invitations a day, and not an eleventh';
  passed := v_state is null and coalesce(v_tenth, false) and v_eleventh is false
            and v_daily_reason = 'Too many invitations have been sent from this organisation today.';
  detail := coalesce(v_state, format('tenth %s; eleventh %s: %s', v_tenth, v_eleventh, coalesce(v_daily_reason, 'no reason')));
  return next;

  case_name := 'a fresh sign-in link waits ten minutes after the last one';
  passed := v_state is null and v_recent_ok is false and coalesce(v_recent_reason, '') <> '' and coalesce(v_later_ok, false);
  detail := coalesce(v_state, format('five minutes after: %s (%s); eleven minutes after: %s',
                                     v_recent_ok, coalesce(v_recent_reason, 'no reason'), v_later_ok));
  return next;

  case_name := 'an invitation that has had five sign-in links gets no sixth';
  passed := v_state is null and v_worn_ok is false and coalesce(v_worn_reason, '') <> '';
  detail := coalesce(v_state, format('allowed %s: %s', v_worn_ok, coalesce(v_worn_reason, 'no reason')));
  return next;

  case_name := 'a re-sent link counts against the organisation''s day with the invitations made';
  passed := v_state is null and coalesce(v_resend_ninth, false) and v_resend_tenth is false
            and v_resend_reason = 'Too many invitations have been sent from this organisation today.';
  detail := coalesce(v_state, format('with nine today %s; with ten %s: %s', v_resend_ninth, v_resend_tenth, coalesce(v_resend_reason, 'no reason')));
  return next;

  case_name := 'an invitation already redeemed is nothing to email';
  passed := v_state is null
            and v_claimed_invite = 'false, no such invitation'
            and v_claimed_resend = 'false, no such invitation';
  detail := coalesce(v_state, format('invite: %s; resend: %s', v_claimed_invite, v_claimed_resend));
  return next;

  case_name := 'a sent link is recorded on the pending invitation only, and counted each time';
  passed := v_state is null and v_noted_at = now() and v_noted_n = 2 and v_other_n = 0 and v_noted_raised is null;
  detail := coalesce(v_state, format('pending: %s link(s), last at %s; superseded: %s; unknown person: %s',
                                     v_noted_n, v_noted_at, v_other_n, coalesce(v_noted_raised, 'nothing raised')));
  return next;

  case_name := 'once a link is recorded, the next one waits';
  passed := v_state is null and v_noted_ok is false
            and v_noted_reason = 'A sign-in link for this invitation was sent less than ten minutes ago.';
  detail := coalesce(v_state, format('allowed %s: %s', v_noted_ok, coalesce(v_noted_reason, 'no reason')));
  return next;

  -- 18. What the inviter is shown is a plain sentence.
  v_reasons := concat_ws(' | ', v_again_reason, v_young_reason, v_old_reason, v_daily_reason,
                         v_recent_reason, v_worn_reason, v_resend_reason, v_noted_reason);
  case_name := 'every reason is a plain sentence with no internal words';
  passed := v_state is null
            and v_reasons is not null
            and v_reasons !~* '(CLOVEERP|_|tenant|app user|digest|token|null)'
            and not exists (select 1 from unnest(array[v_again_reason, v_young_reason, v_old_reason, v_daily_reason,
                                                      v_recent_reason, v_worn_reason, v_resend_reason, v_noted_reason]) x
                             where x is null or x !~ '^[A-Z].*\.$');
  detail := coalesce(v_state, v_reasons);
  return next;
end;
$$;
revoke all on function erp_test.invitation_send_allowance_suite() from public, anon, authenticated;

create or replace function erp_test.assert_invitation_send_allowance_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 18;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _invitation_send_allowance on commit drop as
    select * from erp_test.invitation_send_allowance_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _invitation_send_allowance;
  drop table _invitation_send_allowance;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INVITATION_ALLOWANCE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_INVITATION_ALLOWANCE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('invitation send allowance: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_invitation_send_allowance_suite() from public, anon, authenticated;

create or replace function erp_test.drain_boundaries_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r              record;
  v_code         text := 'zz-bound-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_subject      uuid := gen_random_uuid();
  v_ok           boolean;
  v_msg          text;
  v_hint         text;
  v_state        text;
  v_ref          text;
  v_n            integer;
  v_leak         text;
  v_leak_rows    integer;
  v_lookalikes   text;
  v_kept         text;
  v_table_msg    text;
  v_system_msg   text;
  v_system_kept  integer;
  v_job_msg      text;
  v_job_rows     integer;
  v_sql_job      boolean;
  v_feed_msg     text;
  v_feed_rows    integer;
  v_platform_job boolean;
  v_platform_obs integer;
  v_sweep_obs    integer;
  v_left_on      integer;
  v_n1 uuid; v_n2 uuid; v_n3 uuid; v_n4 uuid; v_n5 uuid; v_n6 uuid; v_n7 uuid;
  v_retired      integer;
  v_again        integer;
  v_suppressed   integer;
  v_copies       integer;
  v_untouched    text;
  v_findings     integer;
begin
  -- 1. Nothing already on file runs a worker-only handler outside the platform
  --    organisation: the release switched any such job off, and the writer
  --    refuses a new one.
  select count(*) into v_left_on
    from erp.job j
    join erp_ref.job_handler h on h.code = j.handler_code
   where h.sql_function is null
     and j.is_enabled
     and not erp.is_platform_organisation(j.tenant_id);
  case_name := 'no job on a handler only the worker runs is switched on outside the platform organisation';
  passed := v_left_on = 0;
  detail := format('%s such job(s) switched on', v_left_on);
  return next;

  -- 2. The retirement refuses a signed-in session itself, should a grant reach it.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.retire_undrained_notifications() to authenticated';
    execute 'set local role authenticated';
    perform erp.retire_undrained_notifications();
    v_msg := 'with execute granted, a signed-in session retired queued messages';
    raise exception 'ZZ_BOUNDARY_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_BOUNDARY_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, retiring queued messages still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 3.
  select not p.prosecdef into v_ok
    from pg_catalog.pg_proc p where p.oid = 'erp.retire_undrained_notifications()'::regprocedure;
  case_name := 'the retirement''s trust test runs in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 4-17 build an organisation, act in it, and undo all of it.
  begin
    select * into r from erp.provision_tenant(v_code, 'Boundary suite', 'admin@' || v_code || '.test', 'Boundary Admin');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_subject)::text, true);
    perform erp.claim_invitation(r.admin_token);

    -- ── Credentials ───────────────────────────────────────────────────────────
    begin
      perform erp.upsert_notification_channel('zz_leak', 'Leak', 'webhook',
                jsonb_build_object('url', 'https://hooks.example.test/leak'), 'env://SUPABASE_SERVICE_ROLE_KEY', true);
      v_leak := 'a channel naming the service key was saved';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      if sqlstate = '23514' and sqlerrm like 'CLOVEERP_CREDENTIAL_NAME_NOT_ALLOWED:%' and coalesce(v_hint, '') <> '' then
        v_leak := null;
      else
        v_leak := left(sqlerrm, 120);
      end if;
    end;
    select count(*) into v_leak_rows from erp.notification_channel c where c.tenant_id = r.tenant_id and c.code = 'zz_leak';

    foreach v_ref in array array['env://SUPABASE_DB_URL', 'env://RESEND_API_KEY', 'env://CLOVEERP_DISPATCH_SECRET',
                                 'env://CLOVEERP_CREDENTIAL_', 'env://CLOVEERP_CREDENTIAL_lower', 'env://CLOVEERP_CREDENTIALS_X'] loop
      begin
        perform erp.upsert_notification_channel('zz_lookalike', 'Lookalike', 'webhook',
                  jsonb_build_object('url', 'https://hooks.example.test/lookalike'), v_ref, true);
        v_lookalikes := concat_ws(', ', v_lookalikes, v_ref || ' saved');
      exception when others then
        if sqlerrm not like 'CLOVEERP_CREDENTIAL_NAME_NOT_ALLOWED:%' then
          v_lookalikes := concat_ws(', ', v_lookalikes, v_ref || ': ' || left(sqlerrm, 60));
        end if;
      end;
    end loop;

    perform erp.upsert_notification_channel('zz_named', 'Named', 'webhook',
              jsonb_build_object('url', 'https://hooks.example.test/named'), 'env://CLOVEERP_CREDENTIAL_OPS_CHAT', true);
    perform erp.upsert_notification_channel('zz_vault', 'Vaulted', 'webhook',
              jsonb_build_object('url', 'https://hooks.example.test/vault'), 'vault://ops/chat', true);
    select string_agg(c.code || '=' || c.credential_ref, ', ' order by c.code) into v_kept
      from erp.notification_channel c where c.tenant_id = r.tenant_id and c.code in ('zz_named', 'zz_vault');

    -- Around the writer, straight at each table.
    begin
      insert into erp.notification_channel (tenant_id, code, name, kind, settings, credential_ref)
      values (r.tenant_id, 'zz_direct', 'Direct', 'webhook',
              jsonb_build_object('url', 'https://hooks.example.test/direct'), 'env://SUPABASE_DB_URL');
      v_table_msg := 'a channel row naming the database URL was written';
    exception when others then
      if sqlstate = '23514' and sqlerrm like '%notification_channel_credential_env_name%' then
        v_table_msg := null;
      else
        v_table_msg := left(sqlerrm, 120);
      end if;
    end;

    begin
      insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, credential_ref, status)
      values (r.tenant_id, 'zz_leaky', 'Leaky', 'example_http', 1,
              jsonb_build_object('base_url', 'https://leaky.example.test'), 'env://SUPABASE_SERVICE_ROLE_KEY', 'draft');
      v_system_msg := 'a counterpart naming the service key was written';
    exception when others then
      if sqlstate = '23514' and sqlerrm like '%external_system_credential_env_name%' then
        v_system_msg := null;
      else
        v_system_msg := left(sqlerrm, 120);
      end if;
    end;
    insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, credential_ref, status)
    values (r.tenant_id, 'zz_named_sys', 'Named', 'example_http', 1,
            jsonb_build_object('base_url', 'https://named.example.test'), 'env://CLOVEERP_CREDENTIAL_STATUS_TOKEN', 'draft'),
           (r.tenant_id, 'zz_vault_sys', 'Vaulted', 'example_http', 1,
            jsonb_build_object('base_url', 'https://vaulted.example.test'), 'vault://zzbound/key', 'draft');
    select count(*) into v_system_kept
      from erp.external_system s where s.tenant_id = r.tenant_id and s.code in ('zz_named_sys', 'zz_vault_sys');

    -- ── Handlers only the worker runs ─────────────────────────────────────────
    -- Nobody designated this organisation, so it is not the platform's.
    begin
      perform erp.upsert_job('zzpoll', 'Poll provider status feeds', 'platform.poll_dependency_status', 'manual');
      v_job_msg := 'an organisation that is not the platform''s scheduled the status feed job';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      if sqlstate = '42501' and sqlerrm like 'CLOVEERP_JOB_HANDLER_PLATFORM_ONLY:%' and coalesce(v_hint, '') <> '' then
        v_job_msg := null;
      else
        v_job_msg := left(sqlerrm, 120);
      end if;
    end;
    select count(*) into v_job_rows from erp.job j where j.tenant_id = r.tenant_id and j.code = 'zzpoll';
    perform erp.upsert_job('zzreclaim', 'Reclaim stranded work', 'platform.reclaim_stranded_work', 'manual');
    select exists (select 1 from erp.job j where j.tenant_id = r.tenant_id and j.code = 'zzreclaim') into v_sql_job;

    -- The feed, recorded by a job acting for this organisation.
    perform set_config('request.jwt.claims', '', true);
    perform erp.set_job_tenant(r.tenant_id);
    begin
      perform erp.record_dependency_status('resend', 'minor', 'Boundary suite', '{}'::jsonb, 'zz-boundary-suite');
      v_feed_msg := 'a job acting for an organisation that is not the platform''s recorded a provider''s feed';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      if sqlstate = '42501' and sqlerrm like 'CLOVEERP_DEPENDENCY_STATUS_OUTSIDE_PLATFORM:%' and coalesce(v_hint, '') <> '' then
        v_feed_msg := null;
      else
        v_feed_msg := left(sqlerrm, 120);
      end if;
    end;
    select count(*) into v_feed_rows from erp_meta.dependency_observation o where o.observed_by = 'zz-boundary-suite';

    -- Now it is the platform's organisation.
    delete from erp_meta.platform_organisation;
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_by, reason)
    values (r.tenant_id, v_code, 'drain boundaries suite', 'the suite''s platform organisation');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', v_subject)::text, true);
    perform erp.upsert_job('zzpoll', 'Poll provider status feeds', 'platform.poll_dependency_status', 'manual');
    select exists (select 1 from erp.job j where j.tenant_id = r.tenant_id and j.code = 'zzpoll') into v_platform_job;
    perform set_config('request.jwt.claims', '', true);
    perform erp.set_job_tenant(r.tenant_id);
    perform erp.record_dependency_status('resend', 'minor', 'Boundary suite', '{}'::jsonb, 'zz-boundary-suite');
    select count(*) into v_platform_obs from erp_meta.dependency_observation o where o.observed_by = 'zz-boundary-suite';
    -- And the sweep, which acts for no organisation.
    perform set_config('erp.job_tenant_id', '', true);
    perform erp.record_dependency_status('resend', 'minor', 'Boundary suite', '{}'::jsonb, 'zz-boundary-suite');
    select count(*) into v_sweep_obs from erp_meta.dependency_observation o where o.observed_by = 'zz-boundary-suite';

    -- ── Messages queued for nobody ────────────────────────────────────────────
    perform erp.set_job_tenant(r.tenant_id);
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, created_at)
    values (r.tenant_id, 'high', r.admin_user_id, 'email', 'Boundary: queued', 'Queued for nobody.', 'queued', now() - interval '2 hours')
    returning id into v_n1;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, created_at)
    values (r.tenant_id, 'medium', r.admin_user_id, 'webhook', 'Boundary: pending', 'A post nobody made.', 'pending', now() - interval '2 hours')
    returning id into v_n2;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, held_until, created_at)
    values (r.tenant_id, 'low', r.admin_user_id, 'email', 'Boundary: held', 'Held for quiet hours.', 'held', now() + interval '1 hour', now() - interval '2 hours')
    returning id into v_n3;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, claimed_by, claimed_at, lease_expires_at, send_attempts, created_at)
    values (r.tenant_id, 'high', r.admin_user_id, 'email', 'Boundary: sending', 'In a worker''s hands.', 'sending', 'zz-boundary-worker', now(), now() + interval '5 minutes', 1, now() - interval '2 hours')
    returning id into v_n4;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (r.tenant_id, 'high', r.admin_user_id, 'email', 'Boundary: recent', 'Queued a moment ago.', 'queued')
    returning id into v_n5;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, created_at)
    values (r.tenant_id, 'info', r.admin_user_id, 'in_app', 'Boundary: in-app', 'Read in the product.', 'pending', now() - interval '2 hours')
    returning id into v_n6;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, provider_message_id, created_at)
    values (r.tenant_id, 'high', r.admin_user_id, 'email', 'Boundary: sent', 'Already left.', 'sent', now() - interval '1 hour', 'zz-provider-1', now() - interval '2 hours')
    returning id into v_n7;

    v_retired := erp.retire_undrained_notifications();

    select count(*) into v_suppressed
      from erp.notification n
     where n.id in (v_n1, v_n2, v_n3)
       and n.status = 'suppressed'
       and n.failure_reason like 'CLOVEERP_EMAIL_NOT_SENT:%'
       and n.held_until is null and n.claimed_by is null and n.lease_expires_at is null;

    select count(*) into v_copies
      from erp.notification o
      join erp.notification c on c.tenant_id = o.tenant_id and c.escalation_of = o.id
     where o.id in (v_n1, v_n2, v_n3)
       and c.channel_kind = 'in_app'
       and c.status = 'delivered' and c.delivered_at is not null
       and c.app_user_id = o.app_user_id
       and c.subject = o.subject
       and c.body like o.body || E'\n(' || o.channel_kind::text || ' not sent:%';

    select string_agg(format('%s %s', n.subject, n.status), ', ' order by n.subject) into v_untouched
      from erp.notification n
     where n.id in (v_n4, v_n5, v_n6, v_n7);

    select count(*) into v_findings
      from erp.output_channels_report() f
     where f.reference in (v_n1::text, v_n2::text, v_n3::text);

    v_again := erp.retire_undrained_notifications();

    raise exception 'ZZ_BOUNDARY_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_BOUNDARY_SUITE_UNDO' then v_state := left(sqlerrm, 200); end if;
  end;

  case_name := 'a channel naming a variable outside CLOVEERP_CREDENTIAL_ is refused by name, with the next action, and not saved';
  passed := v_state is null and v_leak is null and v_leak_rows = 0;
  detail := coalesce(v_state, v_leak, format('refused; %s row(s) saved', v_leak_rows));
  return next;

  case_name := 'the platform''s own variables, and names that only resemble the prefix, are refused too';
  passed := v_state is null and v_lookalikes is null;
  detail := coalesce(v_state, v_lookalikes, 'six names refused');
  return next;

  case_name := 'a name under the prefix, and a reference into another store, are saved as given';
  passed := v_state is null
            and v_kept = 'zz_named=env://CLOVEERP_CREDENTIAL_OPS_CHAT, zz_vault=vault://ops/chat';
  detail := coalesce(v_state, coalesce(v_kept, 'nothing saved'));
  return next;

  case_name := 'the channel table refuses the name whoever writes the row';
  passed := v_state is null and v_table_msg is null;
  detail := coalesce(v_state, v_table_msg, 'notification_channel_credential_env_name');
  return next;

  case_name := 'the counterpart table refuses it too, and keeps a name under the prefix and a vault reference';
  passed := v_state is null and v_system_msg is null and v_system_kept = 2;
  detail := coalesce(v_state, v_system_msg, format('refused; %s allowed row(s) written', v_system_kept));
  return next;

  case_name := 'an organisation that is not the platform''s cannot schedule a handler only the worker runs';
  passed := v_state is null and v_job_msg is null and v_job_rows = 0;
  detail := coalesce(v_state, v_job_msg, format('refused; %s job row(s)', v_job_rows));
  return next;

  case_name := 'a handler the database runs is scheduled there as before';
  passed := v_state is null and coalesce(v_sql_job, false);
  detail := coalesce(v_state, format('zzreclaim on file: %s', v_sql_job));
  return next;

  case_name := 'a job acting for an organisation that is not the platform''s cannot record a provider''s feed';
  passed := v_state is null and v_feed_msg is null and v_feed_rows = 0;
  detail := coalesce(v_state, v_feed_msg, format('refused; %s observation(s)', v_feed_rows));
  return next;

  case_name := 'the platform''s organisation schedules the feed and records it, and so does the sweep that acts for none';
  passed := v_state is null and coalesce(v_platform_job, false) and v_platform_obs = 1 and v_sweep_obs = 2;
  detail := coalesce(v_state, format('job on file %s; observations %s then %s', v_platform_job, v_platform_obs, v_sweep_obs));
  return next;

  case_name := 'email and webhook messages queued, pending or held for over an hour are suppressed with the reason';
  passed := v_state is null and v_retired = 3 and v_suppressed = 3;
  detail := coalesce(v_state, format('%s retired, %s suppressed with the reason and their claim cleared', v_retired, v_suppressed));
  return next;

  case_name := 'each is shown in the product instead: one delivered in-app copy standing in for it';
  passed := v_state is null and v_copies = 3;
  detail := coalesce(v_state, format('%s in-app cop(ies) for three messages', v_copies));
  return next;

  case_name := 'a message that is recent, in a worker''s hands, already sent, or in-app is left as it was';
  passed := v_state is null
            and v_untouched = 'Boundary: in-app pending, Boundary: recent queued, Boundary: sending sending, Boundary: sent sent';
  detail := coalesce(v_state, coalesce(v_untouched, 'none found'));
  return next;

  case_name := 'the channels report finds no lost alert among them, and a second pass retires nothing';
  passed := v_state is null and v_findings = 0 and v_again = 0;
  detail := coalesce(v_state, format('%s finding(s); second pass retired %s', v_findings, v_again));
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = v_code);
  detail := v_code || ' is gone';
  return next;
end;
$$;
revoke all on function erp_test.drain_boundaries_suite() from public, anon, authenticated;

create or replace function erp_test.assert_drain_boundaries_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 17;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _drain_boundaries on commit drop as
    select * from erp_test.drain_boundaries_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _drain_boundaries;
  drop table _drain_boundaries;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DRAIN_BOUNDARIES_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DRAIN_BOUNDARIES_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('drain boundaries: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_drain_boundaries_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_dispatch_bindings_suite();
select erp_test.assert_invitation_for_resend_suite();
select erp_test.assert_invitation_send_allowance_suite();
select erp_test.assert_drain_boundaries_suite();
-- Restated here, or reading what changed under them: the webhook suite's
-- credential, the superadmin suite's worker-only job, and the dependency feed
-- the incident suite records.
select erp_test.assert_webhook_delivery_suite();
select erp_test.assert_queued_run_suite();
select erp_test.assert_superadmin_suite();
select erp_test.assert_incident_communication_suite();

select erp.assert_isolation();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_session_context_hygiene();
-- No public function is created here; the allowance row a public door is judged
-- by changed wording, and the doors that reach erp.upsert_job() and
-- erp.upsert_notification_channel() reach new refusals, so the judge reads them again.
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
