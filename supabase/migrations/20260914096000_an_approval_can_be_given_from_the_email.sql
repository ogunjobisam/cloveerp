-- An approval can be given from the email.
--
-- 20260914094000 made an approval email say what is asked, and its button
-- opened the task on the approvals screen. The owner asked for more: the
-- decision itself, from the email. This file is the second of three steps.
--
-- The principle is the one /join already keeps. A link in an email is read by
-- mail scanners, forwarded, left in inboxes and pasted into chats, so it must
-- never be what decides. The token in the link only finds the task. The
-- decision is made by whoever is signed in, as themselves, by pressing a
-- button on the page the link opens, and every rule that governs a decision at
-- the desk governs this one, because it goes through the same function. The
-- token rides in the address's fragment, which no server, proxy or scanner
-- receives, and the page takes it out of the address bar as soon as it has
-- read it.
--
-- What this file does, in order:
--
--   1. erp.email_action_token: one row per link sent, holding the digest of
--      the token and never the token, who it was sent to (the person and their
--      sign-in), the task, a fingerprint of what was being approved, when it
--      stops working (seven days, or the day the decision is due if that comes
--      first, but never less than a day), and whether it was used or retired.
--      erp.approval_task gains decided_via, desk or email, as the record of
--      which way a decision came.
--
--   2. erp.claim_email_batch() mints the links. For each email it claims whose
--      context is an approval task still waiting on the person the email goes
--      to, it retires any link the same notification carried before, makes a
--      fresh token, stores its digest and returns the token once, in a new
--      column, action_token. A resend after a failure therefore sends a new
--      link and the old one stops working. A demonstration organisation is
--      still refused before anything is claimed, so it never gets a link, and
--      the kill switch still stops everything. Re-created from its latest body
--      (20260914094000), proven before it is dropped.
--
--   3. A task that stops waiting retires its links: an after-update trigger on
--      erp.approval_task, whatever decided, delegated, escalated, cancelled or
--      skipped it.
--
--   4. Two doors.
--        public.erp_email_action_peek(token) runs as its owner, because the
--          link may be for another organisation the person belongs to, and
--          answers only the person the link was sent to, signed in as
--          themselves: the organisation, what is being asked, and whether the
--          link can still be used. Anybody else is told only that the link is
--          not for them.
--        public.erp_decide_approval_from_email(token, approve, comment) runs as
--          the caller. erp.redeem_email_action() finds the link, refuses a link
--          that is not the caller's, is for another organisation than the one
--          they are working in, was used, was retired, is for a task or
--          request that has moved on or changed, or has run out, and refuses a
--          rejection without a reason. Then, in one transaction, it marks the
--          link used and calls erp.decide_approval_task(), so the assignee
--          rule, the rule that nobody approves what they asked for once live,
--          and the discount and credit permissions all apply. Any refusal rolls
--          the whole call back and the link stays usable.
--
--   5. The email's words for the two buttons, in English and German, and the
--      approval context carries them (a patch of the 20260914094000 body).
--
--   6. Six refusals, registered in plain words.
--
--   7. erp_test.email_action_suite(), run here, inside a block it rolls back.
--
-- What the reader sees is src/lib/email/notification-email.ts, which puts
-- Approve and Reject on an approval email whenever the claim returned a token,
-- and src/routes/act.tsx, the page they open.
--
-- Not changed: nothing in this file sends mail. Resend's click tracking is set
-- per sending domain, not per message; the token is in the fragment, which a
-- click-tracking redirect is not sent, but the domain setting should still be
-- off.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The record of a link, and of how a decision came
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp.email_action_token (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant (id) on delete cascade,
  notification_id     uuid not null,
  -- The person the email went to, and the sign-in they had when it was sent.
  app_user_id         uuid not null,
  auth_user_id        uuid not null,
  approval_task_id    uuid not null,
  -- What was being approved when the link was made. A link for a request that
  -- has changed since does not decide it.
  request_fingerprint text not null,
  -- The digest, never the token. The claim returns the only copy.
  token_digest        text not null unique,
  expires_at          timestamptz not null,
  consumed_at         timestamptz,
  consumed_decision   text,
  revoked_at          timestamptz,
  revoked_reason      text,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint email_action_token_tenant_id_key unique (tenant_id, id),
  constraint email_action_token_notification_fk
    foreign key (tenant_id, notification_id) references erp.notification (tenant_id, id) on delete cascade,
  constraint email_action_token_person_fk
    foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade,
  constraint email_action_token_task_fk
    foreign key (tenant_id, approval_task_id) references erp.approval_task (tenant_id, id) on delete cascade,
  constraint email_action_token_digest_shape check (token_digest ~ '^[0-9a-f]{64}$'),
  constraint email_action_token_decision_known
    check (consumed_decision is null or consumed_decision in ('approve', 'reject')),
  constraint email_action_token_used_says_how
    check ((consumed_at is null) = (consumed_decision is null)),
  -- A link is open, used, or retired. Never two of them.
  constraint email_action_token_not_used_and_retired
    check (consumed_at is null or revoked_at is null),
  constraint email_action_token_retired_says_why
    check (revoked_at is null or coalesce(btrim(revoked_reason), '') <> '')
);

create index if not exists email_action_token_task_open_idx
  on erp.email_action_token (tenant_id, approval_task_id)
  where consumed_at is null and revoked_at is null;
create index if not exists email_action_token_notification_idx
  on erp.email_action_token (tenant_id, notification_id);

comment on table erp.email_action_token is
  'One row per decision link an approval email carried (20260914096000): the digest '
  'of its token, who it was sent to, the task, a fingerprint of what was being '
  'approved, when it stops working, and whether it was used or retired. The token '
  'only finds the task; the person signed in decides.';

select erp_meta.register_table('erp', 'email_action_token', 'tenant_scoped',
  'Links in approval emails that open a decision page, by digest, with their use and retirement.');

alter table erp.approval_task
  add column if not exists decided_via text not null default 'desk';
alter table erp.approval_task drop constraint if exists approval_task_decided_via_known;
alter table erp.approval_task add constraint approval_task_decided_via_known
  check (decided_via in ('desk', 'email'));

comment on column erp.approval_task.decided_via is
  'How the decision on this task was made: at the desk, or from a link in an '
  'approval email through erp.redeem_email_action() (20260914096000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What a link is checked against
-- ═════════════════════════════════════════════════════════════════════════════

-- The request as the email described it: the request and its version, its
-- material fingerprint and value, the step and who it waits on, and for a
-- document its currency, partner and net value.
create or replace function erp.email_action_fingerprint(p_tenant_id uuid, p_task_id uuid)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select encode(extensions.digest(concat_ws('|',
           ar.id::text, ar.object_type, ar.object_id::text, ar.object_version::text,
           coalesce(ar.material_fingerprint, ''),
           coalesce(ar.value_at_approval::text, ''),
           t.step_code, coalesce(t.assignee_user_id::text, ''),
           coalesce(d.currency::text, ''), coalesce(d.party_id::text, ''),
           coalesce((select sum(l.net_minor)::text
                       from erp.document_line l
                      where l.tenant_id = d.tenant_id and l.document_id = d.id
                        and not l.is_cancelled), '')), 'sha256'), 'hex')
    from erp.approval_task t
    join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
    left join erp.document d
      on ar.object_type = 'document' and d.tenant_id = ar.tenant_id and d.id = ar.object_id
   where t.tenant_id = p_tenant_id and t.id = p_task_id
$$;

revoke all on function erp.email_action_fingerprint(uuid, uuid) from public, anon, authenticated;

comment on function erp.email_action_fingerprint(uuid, uuid) is
  'A digest of what an approval task asks as an email described it: the request, its '
  'version, material fingerprint and value, the step and assignee, and for a document '
  'its currency, partner and net value. A link made against another digest does not decide.';

-- The link a token names, for the person it was sent to and nobody else.
create or replace function erp.locate_email_action(p_token text)
returns setof erp.email_action_token
language sql
stable
security definer
set search_path = ''
as $$
  select tk.*
    from erp.email_action_token tk
   where (select auth.uid()) is not null
     and p_token ~ '^[0-9a-f]{64}$'
     and tk.token_digest = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and tk.auth_user_id = (select auth.uid())
$$;

revoke all on function erp.locate_email_action(text) from public, anon, authenticated;

comment on function erp.locate_email_action(text) is
  'The email action link a token names, only when the signed-in subject is the sign-in '
  'it was sent to. Runs as its owner so a link for another organisation the person '
  'belongs to can be recognised and named as such; returns nothing to anybody else.';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'locate_email_action',
   'Finds an email action link by the digest of its token across organisations, so a person '
   'working in one organisation can be told a link is for another of theirs. Bound to the '
   'caller: it returns a row only when auth.uid() is the sign-in the link was sent to, '
   'and nothing otherwise. It writes nothing and decides nothing.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A task that stops waiting retires its links
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.retire_email_actions_for_task()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.status = 'pending' and new.status is distinct from old.status then
    update erp.email_action_token tk
       set revoked_at = now(),
           revoked_reason = 'the task was ' || new.status::text || ' before the link was used',
           updated_at = now()
     where tk.tenant_id = new.tenant_id
       and tk.approval_task_id = new.id
       and tk.consumed_at is null
       and tk.revoked_at is null;
  end if;
  return null;
end;
$$;

revoke all on function erp.retire_email_actions_for_task() from public, anon, authenticated;

comment on function erp.retire_email_actions_for_task() is
  'Retires every open email action link for an approval task the moment the task stops '
  'waiting, whatever moved it: a decision at the desk, a delegation, an escalation, a '
  'cancellation or a skipped step (20260914096000).';

drop trigger if exists t_approval_task_retires_email_actions on erp.approval_task;
create trigger t_approval_task_retires_email_actions
  after update of status on erp.approval_task
  for each row execute function erp.retire_email_actions_for_task();

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The claim mints the links
-- ═════════════════════════════════════════════════════════════════════════════

do $claim$
declare
  v_def text := pg_get_functiondef('erp.claim_email_batch(integer,text)'::regprocedure);
begin
  if position($k$  if erp.is_killed('integration', 'email') then
    return;
  end if;$k$ in v_def) = 0
     or position($d$  if erp.tenant_is_demonstration(v_tenant) then
    return;
  end if;$d$ in v_def) = 0
     or position('erp.notification_email_names(m.tenant_id, m.context)' in v_def) = 0
     or position('lease_expires_at = now() + interval ''5 minutes''' in v_def) = 0
     or position('action_token' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.claim_email_batch(integer, text) is not the 20260914094000 body this migration re-creates'
      using hint = 'Read the live body with pg_get_functiondef and re-create the claim from it under a new migration version.';
  end if;
end
$claim$;

drop function erp.claim_email_batch(integer, text);

create function erp.claim_email_batch(p_limit integer default 50, p_worker text default null)
returns table(id uuid, to_address text, subject text, body text, from_address text, reply_to text,
              severity text, context jsonb, organisation_name text, recipient_name text,
              action_token text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_ids    uuid[];
  v_tokens jsonb := '{}'::jsonb;
begin
  if erp.is_killed('integration', 'email') then
    return;
  end if;

  -- A demonstration sends nothing outside the product (20260914072000). Its
  -- notifications are written in-app; one queued before that, or moved here
  -- by a writer that forgot, is never handed to a sender.
  if erp.tenant_is_demonstration(v_tenant) then
    return;
  end if;

  -- The batch is marked 'sending' inside the claim, with who holds it and until
  -- when, so a worker that dies mid-flight leaves rows that are visibly stuck
  -- and reclaimable, rather than rows that look queued and get sent again.
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
     returning n.id
  )
  select coalesce(array_agg(mk.id), '{}'::uuid[]) into v_ids from marked mk;

  if coalesce(cardinality(v_ids), 0) = 0 then
    return;
  end if;

  -- A link that decides, for each approval task still waiting on the person
  -- the email goes to (20260914096000). A notification claimed again, after a
  -- failure or a lease that ran out, gets a fresh link and the old one stops
  -- working, so only the email that actually left can decide.
  update erp.email_action_token tk
     set revoked_at = now(),
         revoked_reason = 'a newer email for the same notification replaced it',
         updated_at = now()
   where tk.tenant_id = v_tenant
     and tk.notification_id = any(v_ids)
     and tk.consumed_at is null
     and tk.revoked_at is null;

  with fresh as materialized (
    select n.id as note_id, n.app_user_id as person_id, u.auth_user_id as sign_in_id,
           t.id as task_id, t.due_at as task_due_at,
           encode(extensions.gen_random_bytes(32), 'hex') as raw_token
      from erp.notification n
      join erp.app_user u on u.tenant_id = n.tenant_id and u.id = n.app_user_id
      join erp.approval_task t
        on t.tenant_id = n.tenant_id
       and t.id = case when (n.context -> 'fields' ->> 'task_id')
                              ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                       then (n.context -> 'fields' ->> 'task_id')::uuid end
     where n.tenant_id = v_tenant
       and n.id = any(v_ids)
       and n.context ->> 'kind' = 'approval'
       and t.status = 'pending'
       and t.assignee_user_id = n.app_user_id
       and u.auth_user_id is not null
       and u.status = 'active'
  ),
  minted as (
    insert into erp.email_action_token
      (tenant_id, notification_id, app_user_id, auth_user_id, approval_task_id,
       request_fingerprint, token_digest, expires_at)
    select v_tenant, f.note_id, f.person_id, f.sign_in_id, f.task_id,
           erp.email_action_fingerprint(v_tenant, f.task_id),
           encode(extensions.digest(f.raw_token, 'sha256'), 'hex'),
           -- Seven days, or the day the decision is due if that is sooner; a
           -- task already past due still waits on them, so never under a day.
           least(now() + interval '7 days',
                 greatest(coalesce(f.task_due_at, 'infinity'::timestamptz), now() + interval '1 day'))
      from fresh f
    returning erp.email_action_token.notification_id as note_id
  )
  select coalesce(jsonb_object_agg(f.note_id::text, f.raw_token), '{}'::jsonb)
    into v_tokens
    from fresh f
   where f.note_id in (select mi.note_id from minted mi);

  return query
  select m.id,
         u.email,
         m.subject,
         m.body,
         coalesce(m.sender, erp.sender_for('operational') ->> 'from_address'),
         erp.sender_for('operational') ->> 'reply_to',
         m.severity::text,
         -- The context as it was written, with the names of the people it
         -- refers to read now (20260914094000).
         case when m.context is not null
              then m.context || jsonb_build_object('names', erp.notification_email_names(m.tenant_id, m.context))
         end,
         tn.name,
         u.display_name,
         -- The only copy of the token (20260914096000). Its digest is stored.
         v_tokens ->> m.id::text
    from erp.notification m
    join erp.app_user u on u.id = m.app_user_id
    join erp.tenant tn on tn.id = m.tenant_id
   where m.tenant_id = v_tenant
     and m.id = any(v_ids)
   order by m.created_at;
end;
$$;

revoke all on function erp.claim_email_batch(integer, text) from public, anon, authenticated;

comment on function erp.claim_email_batch(integer, text) is
  'Claims up to p_limit queued emails for the organisation in context, marking them '
  'sending under a five-minute lease held by p_worker. Nothing while the email kill '
  'switch is on, and nothing for a demonstration organisation. Returns each message '
  'with its context (names read now), the organisation''s name and the reader''s name, '
  'and for an approval task still waiting on the reader a fresh decision link token, '
  'returned once and stored only as a digest; a previous link for the same '
  'notification is retired. body is the plain fallback.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Deciding from a link
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.redeem_email_action(p_token text, p_approve boolean, p_comment text)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_found  erp.email_action_token%rowtype;
  v_tok    erp.email_action_token%rowtype;
  v_tenant uuid;
  v_actor  uuid;
  v_task   erp.approval_task%rowtype;
  v_req    erp.approval_request%rowtype;
  v_status erp.approval_status;
  v_reason text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  -- The link, for the person it was sent to. Anybody else learns nothing.
  select * into v_found from erp.locate_email_action(p_token) limit 1;
  if v_found.id is null then
    raise exception 'CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU: this link is not for the account signed in'
      using errcode = '42501',
            hint = 'Sign in as the person the email was sent to, or open the request from My approvals.';
  end if;

  -- A decision is recorded in the organisation the person is working in.
  v_tenant := erp.current_tenant_id();
  if v_tenant is distinct from v_found.tenant_id then
    raise exception 'CLOVEERP_EMAIL_ACTION_WRONG_ORGANISATION: this link is for another of your organisations'
      using errcode = '42501',
            hint = 'Switch to the organisation the page names, then press the button again.';
  end if;

  v_actor := erp.current_principal_id();
  select * into v_tok from erp.email_action_token tk
   where tk.tenant_id = v_tenant and tk.id = v_found.id
   for update;
  if v_tok.id is null or v_tok.app_user_id is distinct from v_actor then
    raise exception 'CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU: this link is not for the account signed in'
      using errcode = '42501',
            hint = 'Sign in as the person the email was sent to, or open the request from My approvals.';
  end if;

  if v_tok.consumed_at is not null then
    raise exception 'CLOVEERP_EMAIL_ACTION_USED: this link has already been used'
      using errcode = '23514',
            hint = 'Open the request from My approvals to see where it has got to.';
  end if;

  select * into v_task from erp.approval_task t
   where t.tenant_id = v_tenant and t.id = v_tok.approval_task_id;
  select * into v_req from erp.approval_request ar
   where ar.tenant_id = v_tenant and ar.id = v_task.approval_request_id;

  if v_tok.revoked_at is not null
     or v_task.id is null
     or v_task.status <> 'pending'
     or v_req.status <> 'pending'
     or erp.email_action_fingerprint(v_tenant, v_task.id) is distinct from v_tok.request_fingerprint then
    raise exception 'CLOVEERP_EMAIL_ACTION_SUPERSEDED: the request has changed or been decided since this link was sent'
      using errcode = '23514',
            hint = 'Open the request from My approvals, check what it says now, and decide it there if it is still waiting for you.';
  end if;

  if v_tok.expires_at <= now() then
    raise exception 'CLOVEERP_EMAIL_ACTION_EXPIRED: this link has run out'
      using errcode = '23514',
            hint = 'Open the request from My approvals and decide it there.';
  end if;

  if p_approve is null then
    raise exception 'CLOVEERP_EMAIL_ACTION_DECISION_MISSING: the page did not say whether to approve or reject'
      using errcode = '22023',
            hint = 'Press Approve or Reject on the page.';
  end if;

  if not p_approve and v_reason is null then
    raise exception 'CLOVEERP_EMAIL_ACTION_REASON_REQUIRED: a rejection needs a reason'
      using errcode = '23514',
            hint = 'Write a short reason, then press Reject again.';
  end if;

  -- Used, then decided, in this one transaction: a refusal from the decision
  -- takes the use back with it and the link still works.
  update erp.email_action_token tk
     set consumed_at = now(),
         consumed_decision = case when p_approve then 'approve' else 'reject' end,
         updated_at = now()
   where tk.tenant_id = v_tenant and tk.id = v_tok.id;

  v_status := erp.decide_approval_task(v_task.id, p_approve, v_reason);

  update erp.approval_task t
     set decided_via = 'email'
   where t.tenant_id = v_tenant and t.id = v_task.id and t.decided_by = v_actor;

  return jsonb_build_object(
    'status', v_status,
    'decision', case when p_approve then 'approve' else 'reject' end,
    'task_id', v_task.id,
    'document_id', case when v_req.object_type = 'document' then v_req.object_id end);
end;
$$;

revoke all on function erp.redeem_email_action(text, boolean, text) from public, anon, authenticated;

comment on function erp.redeem_email_action(text, boolean, text) is
  'Decides the approval task an email link names, for the person it was sent to, in '
  'the organisation they are working in, while the task waits and the request is as '
  'the email described it and the link is unused and in date. Marks the link used and '
  'calls erp.decide_approval_task() in one transaction, so every rule of a desk decision '
  'applies and a refusal leaves the link usable. A rejection needs a reason.';

create or replace function public.erp_decide_approval_from_email(
  p_token text, p_approve boolean, p_comment text default null)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.redeem_email_action(p_token, p_approve, p_comment)
$$;

comment on function public.erp_decide_approval_from_email(text, boolean, text) is
  'Approves or rejects the approval task a link in an email names, as the signed-in '
  'person. The link only finds the task; erp.decide_approval_task() decides it.';

create or replace function public.erp_email_action_peek(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  tk      erp.email_action_token%rowtype;
  r       record;
  v_state text;
begin
  -- Bound to the caller before anything else: nobody signed in, nobody told.
  if (select auth.uid()) is null then
    raise exception 'CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU: this link is not for the account signed in'
      using errcode = '42501',
            hint = 'Sign in as the person the email was sent to, or open the request from My approvals.';
  end if;

  select * into tk from erp.locate_email_action(p_token) limit 1;
  if tk.id is null then
    raise exception 'CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU: this link is not for the account signed in'
      using errcode = '42501',
            hint = 'Sign in as the person the email was sent to, or open the request from My approvals.';
  end if;

  select tn.name as tenant_name,
         t.status::text as task_status, t.step_code, t.due_at,
         coalesce(nullif(btrim(st.name), ''), t.step_code) as step,
         ar.status::text as request_status, ar.object_type, ar.requested_at,
         ru.display_name as requested_by,
         d.id as document_id, d.document_number,
         coalesce(nullif(btrim(dt.name), ''), dt.code) as document_type,
         pa.name as partner,
         case when d.id is not null then
           (select coalesce(sum(l.net_minor), 0) from erp.document_line l
             where l.tenant_id = d.tenant_id and l.document_id = d.id and not l.is_cancelled)
         end as value_minor,
         d.currency::text as currency,
         cu.minor_units
    into r
    from erp.approval_task t
    join erp.tenant tn on tn.id = t.tenant_id
    join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
    left join erp.approval_step st on st.tenant_id = t.tenant_id and st.id = t.approval_step_id
    left join erp.app_user ru on ru.tenant_id = ar.tenant_id and ru.id = coalesce(ar.requested_by, ar.created_by)
    left join erp.document d
      on ar.object_type = 'document' and d.tenant_id = ar.tenant_id and d.id = ar.object_id
    left join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    left join erp.party pa on pa.tenant_id = d.tenant_id and pa.id = d.party_id
    left join erp_ref.currency cu on cu.code = d.currency
   where t.tenant_id = tk.tenant_id and t.id = tk.approval_task_id;

  v_state := case
    when tk.consumed_at is not null then 'used'
    when tk.revoked_at is not null
      or r.task_status is distinct from 'pending'
      or r.request_status is distinct from 'pending'
      or erp.email_action_fingerprint(tk.tenant_id, tk.approval_task_id) is distinct from tk.request_fingerprint
      then 'superseded'
    when tk.expires_at <= now() then 'expired'
    else 'usable'
  end;

  return jsonb_build_object(
    'tenant_id', tk.tenant_id,
    'tenant_name', r.tenant_name,
    'in_active_organisation', tk.tenant_id is not distinct from erp.current_tenant_id(),
    'state', v_state,
    'decision', tk.consumed_decision,
    'expires_at', tk.expires_at,
    'task_id', tk.approval_task_id,
    'document_id', r.document_id,
    'summary', jsonb_strip_nulls(jsonb_build_object(
      'object_type', r.object_type,
      'document_type', r.document_type,
      'document_number', r.document_number,
      'partner', r.partner,
      'value_minor', r.value_minor,
      'currency', r.currency,
      'minor_units', case when r.document_id is not null then coalesce(r.minor_units, 2) end,
      'step', r.step,
      'requested_by', r.requested_by,
      'requested_at', r.requested_at,
      'due_at', r.due_at)));
end;
$$;

comment on function public.erp_email_action_peek(text) is
  'What an approval email''s link is for, told only to the person it was sent to, '
  'signed in as themselves: the organisation, the request, and whether the link can '
  'still be used. Anybody else is told the link is not for them, and nothing more.';

revoke all on function public.erp_decide_approval_from_email(text, boolean, text) from public, anon;
revoke all on function public.erp_email_action_peek(text) from public, anon;
grant execute on function public.erp_decide_approval_from_email(text, boolean, text) to authenticated, service_role;
grant execute on function public.erp_email_action_peek(text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_decide_approval_from_email', 'erp.redeem_email_action',
   'Approves or rejects the approval task an email link names. The link only finds the task: '
   'the caller must be the person it was sent to, working in its organisation, and '
   'erp.decide_approval_task() then refuses anybody but the assignee, self-approval once '
   'live, and the discount and credit steps without sales.discount_approve or '
   'sales.credit_release (20260914096000).')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale, ungated_because) values
  ('erp_email_action_peek', 'erp.locate_email_action',
   'Reads, for the person an approval email was sent to, what its link is for and whether '
   'it can still be used. Volatile so every press asks again; it writes nothing. Bound '
   'to the caller: a link is found only for the sign-in it was sent to (20260914096000).',
   'own_records')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale, ungated_because = excluded.ungated_because;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_email_action_peek',
   'UNGATED BY DESIGN: bound to the caller''s own identity. It refuses a caller with no '
   'sign-in on its first line, and erp.locate_email_action() finds a link only when '
   'auth.uid() is the sign-in the email was sent to; anybody else is refused with no '
   'detail. Runs as its owner because the link may be for another organisation the person '
   'belongs to, which row security would hide. It writes nothing and decides nothing; '
   'erp_test.email_action_suite proves it tells the wrong person nothing.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The words
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, module_code, description)
select w.key, l.locale, case l.locale when 'en' then w.en else w.de end, 'administration', w.description
  from (values
    ('email.approval.approve', 'Approve', 'Genehmigen',
     'Email: the button that opens the page to approve an approval task.'),
    ('email.approval.reject', 'Reject', 'Ablehnen',
     'Email: the button that opens the page to reject an approval task.'),
    ('email.approval.open_task', 'Review in Clove ERP', 'In Clove ERP prüfen',
     'Email: the plain link under the decision buttons that opens the task on the approvals screen.'),
    ('email.approval.note_actions',
     'Approve and Reject open Clove ERP, where you sign in and confirm. Nothing is decided by opening this email or the link. Each link works once, only for you, for up to seven days.',
     'Genehmigen und Ablehnen öffnen Clove ERP, wo Sie sich anmelden und bestätigen. Durch das Öffnen dieser E-Mail oder des Links wird nichts entschieden. Jeder Link funktioniert einmal, nur für Sie und höchstens sieben Tage lang.',
     'Email: under the decision buttons of an approval task.')
  ) as w(key, en, de, description)
  cross join (values ('en'), ('de')) as l(locale)
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code, description = excluded.description;

do $context$
declare
  v_sig text := 'erp.notification_email_context(erp.event,uuid,boolean)';
  v_def text := pg_get_functiondef('erp.notification_email_context(erp.event,uuid,boolean)'::regprocedure);
  v_old text := $o$        'note', w ->> 'note',
$o$;
  v_new text := $r$        'note', w ->> 'note',
        -- The decision buttons' words (20260914096000). The sender uses them
        -- when the claim returned a link; without one the email keeps Review.
        'approve', w ->> 'approve',
        'reject', w ->> 'reject',
        'open_task', w ->> 'open_task',
        'note_actions', w ->> 'note_actions',
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('note_actions' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914094000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
  if position('''note_actions'', w ->> ''note_actions''' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without the decision words', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needle above.';
  end if;
end
$context$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The refusals, in words a person can act on
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU',
  'Using a link from an approval email while signed in as somebody other than the person it was sent to.',
  'A link in an approval email only finds the request. The decision is made by the person signed in, and each link works only for the person it was sent to, so a forwarded link decides nothing.',
  'Sign in as the person the email was sent to, or ask them to decide. The request is also on My approvals in Clove ERP.');

select erp.register_refusal('CLOVEERP_EMAIL_ACTION_WRONG_ORGANISATION',
  'Using a link from an approval email while working in a different organisation from the one the request belongs to.',
  'A decision is recorded in the organisation you are working in, and this request belongs to another organisation you can sign in to.',
  'Switch to the organisation named on the page, then press the button again.');

select erp.register_refusal('CLOVEERP_EMAIL_ACTION_USED',
  'Using a link from an approval email that has already made a decision.',
  'Each link in an approval email works once. The decision it made is recorded against the request.',
  'Open the request from My approvals in Clove ERP to see where it has got to.');

select erp.register_refusal('CLOVEERP_EMAIL_ACTION_SUPERSEDED',
  'Using a link from an approval email for a request that has changed or been decided since the email was sent.',
  'The request was decided at the desk or by somebody else, what is being approved changed, or a newer email replaced this one, so the link no longer decides it.',
  'Open the request from My approvals in Clove ERP, check what it says now, and decide it there if it is still waiting for you.');

select erp.register_refusal('CLOVEERP_EMAIL_ACTION_EXPIRED',
  'Using a link from an approval email after it has run out.',
  'A link in an approval email works for seven days at most, and not past the day the decision is due, so an old email cannot decide a request that may have moved on.',
  'Open the request from My approvals in Clove ERP and decide it there.');

select erp.register_refusal('CLOVEERP_EMAIL_ACTION_REASON_REQUIRED',
  'Rejecting a request from an approval email without saying why.',
  'A rejection sends the request back to whoever asked for it, and they need to know what to change.',
  'Write a short reason, such as the figure that is wrong, then press Reject again.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two helpers, then the suite. Everything the suite builds is inside a block it
-- rolls back, so nothing it queues or mints is ever committed: no drain or
-- other session can see it, and every claim is scoped to its own organisation.

-- An approval email queued for a person and claimed the way the drain claims
-- it: the organisation in context, no principal, nobody signed in.
create or replace function erp_test.email_action_mint(p_tenant uuid, p_person uuid, p_task uuid,
                                                      p_kind text default 'approval')
returns table (minted_note uuid, minted_token text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_jobp   text := coalesce(current_setting('erp.job_principal_id', true), '');
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', p_tenant::text, true);
  perform set_config('erp.job_principal_id', '', true);

  insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, context)
  values (p_tenant, 'medium', p_person, 'email', 'Approval needed', 'The email action suite.', 'queued',
          jsonb_build_object('kind', p_kind, 'fields', jsonb_build_object('task_id', p_task)))
  returning erp.notification.id into minted_note;

  select c.action_token into minted_token
    from erp.claim_email_batch(50, 'zz-email-action') c
   where c.id = minted_note;

  perform set_config('erp.job_tenant_id', v_job, true);
  perform set_config('erp.job_principal_id', v_jobp, true);
  perform set_config('request.jwt.claims', v_claims, true);
  return next;
end;
$$;

revoke all on function erp_test.email_action_mint(uuid, uuid, uuid, text) from public, anon, authenticated;

-- A door called the way the data API calls it: as authenticated, with the
-- person's sign-in in the claims and no job context.
create or replace function erp_test.email_action_door_as(
  p_subject uuid, p_door text, p_token text, p_approve boolean default null,
  p_comment text default null, p_task uuid default null)
returns table (outcome jsonb, err_message text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner  text := current_user;
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_job    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_jobp   text := coalesce(current_setting('erp.job_principal_id', true), '');
begin
  if p_door not in ('erp_email_action_peek', 'erp_decide_approval_from_email', 'erp_decide_approval') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a door the email action suite calls', p_door
      using hint = 'Call one of the three doors the helper names.';
  end if;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    case p_door
      when 'erp_email_action_peek' then
        outcome := public.erp_email_action_peek(p_token);
      when 'erp_decide_approval_from_email' then
        outcome := public.erp_decide_approval_from_email(p_token, p_approve, p_comment);
      else
        outcome := public.erp_decide_approval(p_task, p_approve, p_comment);
    end case;
  exception when others then
    err_message := sqlerrm;
  end;
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', v_claims, true);
  perform set_config('erp.job_tenant_id', v_job, true);
  perform set_config('erp.job_principal_id', v_jobp, true);
  return next;
end;
$$;

revoke all on function erp_test.email_action_door_as(uuid, text, text, boolean, text, uuid) from public, anon, authenticated;

create or replace function erp_test.email_action_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job_before    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 8);
  a_admin    uuid := gen_random_uuid();
  a_appr     uuid := gen_random_uuid();
  a_other    uuid := gen_random_uuid();
  v_step     text := 'starting';
  v_state    text;
  r          record;
  g          record;
  v_tenant   uuid;
  v_second   uuid;
  v_org_name text := 'Email Action Suite Organisation';
  u_admin    uuid;
  u_appr     uuid;
  u_other    uuid;
  v_chain    uuid;
  v_ver      uuid;
  v_req      uuid;
  v_task     uuid;
  v_note     uuid;
  v_note2    uuid;
  v_tok      text;
  v_tok2     text;
  v_old      text;
  v_n        integer;
  v_row      erp.email_action_token%rowtype;

  ok_mint    boolean; msg_mint    text;
  ok_reissue boolean; msg_reissue text;
  ok_peek    boolean; msg_peek    text;
  ok_forward boolean; msg_forward text;
  ok_org     boolean; msg_org     text;
  ok_reason  boolean; msg_reason  text;
  ok_once    boolean; msg_once    text;
  ok_expired boolean; msg_expired text;
  ok_self    boolean; msg_self    text;
  ok_perm    boolean; msg_perm    text;
  ok_desk    boolean; msg_desk    text;
  ok_changed boolean; msg_changed text;
  ok_demo    boolean; msg_demo    text;
begin
  begin
    -- ── An organisation, live, and the people the cases need ───────────────
    v_step := 'an organisation is provisioned';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant('zzmailact-' || v_tag, v_org_name,
                                              'admin@zzmailact-' || v_tag || '.test', 'Action Admin');
    v_tenant := r.tenant_id;
    insert into auth.users (id, email)
    values (a_admin, 'admin@zzmailact-' || v_tag || '.test'),
           (a_appr, 'approver@zzmailact-' || v_tag || '.test'),
           (a_other, 'other@zzmailact-' || v_tag || '.test');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    u_admin := erp.claim_invitation(r.admin_token);

    v_step := 'an approver and a colleague join, holding no role';
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (v_tenant, a_appr, 'person', 'active', 'Action Approver', 'approver@zzmailact-' || v_tag || '.test', 'en')
    returning id into u_appr;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (v_tenant, a_other, 'person', 'active', 'Action Colleague', 'other@zzmailact-' || v_tag || '.test', 'en')
    returning id into u_other;

    v_step := 'two approval chains name the approver';
    perform erp_test.reopen_bootstrap_window(v_tenant);
    insert into erp.approval_chain (tenant_id, code, name, object_type)
    values (v_tenant, 'zz_email_action', 'Email action suite', 'zz_email_action')
    returning id into v_chain;
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status)
    values (v_tenant, v_chain, 1, 'draft') returning id into v_ver;
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, approver_kind, app_user_id)
    values (v_tenant, v_ver, 1, 'review', 'Suite review', 'user', u_appr);
    perform erp.activate_approval_chain_version(v_ver, current_date);

    -- For documents: the rule that whoever asked does not approve applies.
    insert into erp.approval_chain (tenant_id, code, name, object_type)
    values (v_tenant, 'zz_email_action_document', 'Email action suite, documents', 'document')
    returning id into v_chain;
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status)
    values (v_tenant, v_chain, 1, 'draft') returning id into v_ver;
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, approver_kind, app_user_id)
    values (v_tenant, v_ver, 1, 'review', 'Suite review', 'user', u_appr);
    perform erp.activate_approval_chain_version(v_ver, current_date);

    -- A sales order's terms: its discount step needs sales.discount_approve.
    insert into erp.approval_chain (tenant_id, code, name, object_type)
    values (v_tenant, 'sales_order_terms', 'Email action suite, terms', 'zz_email_terms')
    returning id into v_chain;
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status)
    values (v_tenant, v_chain, 1, 'draft') returning id into v_ver;
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, approver_kind, app_user_id)
    values (v_tenant, v_ver, 1, 'discount', 'Discount', 'user', u_appr);
    perform erp.activate_approval_chain_version(v_ver, current_date);
    perform erp_test.close_bootstrap_window(v_tenant);

    -- ── 1. The claim mints, with no principal in context ───────────────────
    v_step := 'a request waits on the approver and its email is claimed';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_req := erp.request_approval('zz_email_action', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = v_req and t.status = 'pending';
    select g1.minted_note, g1.minted_token into v_note, v_tok
      from erp_test.email_action_mint(v_tenant, u_appr, v_task) g1;
    select g1.minted_note, g1.minted_token into v_note2, v_tok2
      from erp_test.email_action_mint(v_tenant, u_appr, v_task, 'digest') g1;
    select * into v_row from erp.email_action_token tk where tk.tenant_id = v_tenant and tk.notification_id = v_note;
    ok_mint := v_tok ~ '^[0-9a-f]{64}$'
           and v_row.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex')
           and not exists (select 1 from erp.email_action_token tk where tk.token_digest = v_tok)
           and v_row.auth_user_id = a_appr and v_row.app_user_id = u_appr
           and v_row.approval_task_id = v_task
           and v_row.expires_at > now() + interval '6 days' and v_row.expires_at <= now() + interval '7 days'
           and v_tok2 is null
           and not exists (select 1 from erp.email_action_token tk where tk.notification_id = v_note2);
    msg_mint := format('token %s characters, digest stored %s, expires %s; digest email token %s',
                       coalesce(length(v_tok), 0), v_row.token_digest is not null, v_row.expires_at,
                       coalesce(v_tok2, 'none'));

    -- ── 2. Claimed again, a fresh link and the old one retired ──────────────
    v_step := 'the same notification is claimed again';
    v_old := v_tok;
    update erp.notification set status = 'queued' where id = v_note;
    perform set_config('erp.job_tenant_id', v_tenant::text, true);
    select c.action_token into v_tok from erp.claim_email_batch(50, 'zz-email-action') c where c.id = v_note;
    perform set_config('erp.job_tenant_id', '', true);
    ok_reissue := v_tok ~ '^[0-9a-f]{64}$' and v_tok <> v_old
              and (select tk.revoked_at is not null from erp.email_action_token tk
                    where tk.token_digest = encode(extensions.digest(v_old, 'sha256'), 'hex'))
              and (select count(*) from erp.email_action_token tk
                    where tk.notification_id = v_note and tk.consumed_at is null and tk.revoked_at is null) = 1;
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_old, true);
    ok_reissue := ok_reissue and g.err_message like 'CLOVEERP_EMAIL_ACTION_SUPERSEDED%';
    msg_reissue := format('old link: %s', coalesce(g.err_message, 'accepted'));

    -- ── 3. Peek: the person it was for, and nobody else ─────────────────────
    v_step := 'the link is looked at';
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_email_action_peek', v_tok);
    ok_peek := g.err_message is null
           and g.outcome ->> 'state' = 'usable'
           and g.outcome ->> 'tenant_name' = v_org_name
           and (g.outcome ->> 'in_active_organisation')::boolean
           and g.outcome ->> 'task_id' = v_task::text
           and g.outcome -> 'summary' ->> 'step' = 'Suite review'
           and g.outcome -> 'summary' ->> 'requested_by' = 'Action Admin';
    msg_peek := 'the approver: ' || left(coalesce(g.outcome::text, g.err_message), 200);
    select * into g from erp_test.email_action_door_as(a_other, 'erp_email_action_peek', v_tok);
    ok_peek := ok_peek and g.outcome is null
           and g.err_message like 'CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU%'
           and position(v_org_name in g.err_message) = 0
           and position('Suite review' in g.err_message) = 0;
    msg_peek := msg_peek || '; a colleague: ' || coalesce(g.err_message, left(g.outcome::text, 120));

    -- ── 4. A forwarded link ─────────────────────────────────────────────────
    v_step := 'a colleague presses the forwarded link';
    select * into g from erp_test.email_action_door_as(a_other, 'erp_decide_approval_from_email', v_tok, true);
    ok_forward := g.err_message like 'CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU%'
              and (select tk.consumed_at is null and tk.revoked_at is null from erp.email_action_token tk
                    where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'))
              and (select t.status = 'pending' from erp.approval_task t where t.id = v_task);
    msg_forward := coalesce(g.err_message, 'accepted: ' || g.outcome::text);

    -- ── 5. Working in another organisation ──────────────────────────────────
    v_step := 'the approver is working in a second organisation';
    perform set_config('request.jwt.claims', '', true);
    select t2.tenant_id into v_second
      from erp.provision_tenant('zzmailact2-' || v_tag, 'Email Action Suite Second',
                                'admin@zzmailact2-' || v_tag || '.test', 'Second Admin') t2;
    perform set_config('erp.job_tenant_id', v_second::text, true);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (v_second, a_appr, 'person', 'active', 'Action Approver', 'approver@zzmailact-' || v_tag || '.test', 'en');
    perform set_config('erp.job_tenant_id', '', true);
    insert into erp_meta.principal_preference (auth_user_id, active_tenant_id)
    values (a_appr, v_second)
    on conflict (auth_user_id) do update set active_tenant_id = excluded.active_tenant_id;
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_tok, true);
    ok_org := g.err_message like 'CLOVEERP_EMAIL_ACTION_WRONG_ORGANISATION%'
          and (select tk.consumed_at is null from erp.email_action_token tk
                where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'));
    msg_org := coalesce(g.err_message, 'accepted');
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_email_action_peek', v_tok);
    ok_org := ok_org and g.outcome ->> 'tenant_name' = v_org_name
          and not (g.outcome ->> 'in_active_organisation')::boolean;
    msg_org := msg_org || format('; peek says in the active organisation: %s', g.outcome ->> 'in_active_organisation');
    update erp_meta.principal_preference set active_tenant_id = v_tenant where auth_user_id = a_appr;
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);

    -- ── 6. A rejection needs a reason ───────────────────────────────────────
    v_step := 'the approver rejects without a reason';
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_tok, false, '  ');
    ok_reason := g.err_message like 'CLOVEERP_EMAIL_ACTION_REASON_REQUIRED%'
             and (select tk.consumed_at is null from erp.email_action_token tk
                   where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'));
    msg_reason := coalesce(g.err_message, 'accepted');

    -- ── 7. Decided once, and only once ──────────────────────────────────────
    v_step := 'the approver approves from the link';
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_tok, true);
    ok_once := g.err_message is null
           and g.outcome ->> 'status' = 'approved'
           and (select t.status = 'approved' and t.decided_by = u_appr and t.decided_via = 'email'
                  from erp.approval_task t where t.id = v_task)
           and (select tk.consumed_at is not null and tk.consumed_decision = 'approve'
                  from erp.email_action_token tk
                 where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'));
    msg_once := 'first press: ' || coalesce(g.outcome::text, g.err_message);
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_tok, true);
    ok_once := ok_once and g.err_message like 'CLOVEERP_EMAIL_ACTION_USED%';
    msg_once := msg_once || '; second press: ' || coalesce(g.err_message, 'accepted');
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_email_action_peek', v_tok);
    ok_once := ok_once and g.outcome ->> 'state' = 'used' and g.outcome ->> 'decision' = 'approve';

    -- ── 8. A link that has run out ──────────────────────────────────────────
    v_step := 'a link runs out';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_req := erp.request_approval('zz_email_action', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = v_req and t.status = 'pending';
    select g1.minted_token into v_tok from erp_test.email_action_mint(v_tenant, u_appr, v_task) g1;
    update erp.email_action_token tk set expires_at = now() - interval '1 minute'
     where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex');
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_tok, true);
    ok_expired := g.err_message like 'CLOVEERP_EMAIL_ACTION_EXPIRED%'
              and (select tk.consumed_at is null from erp.email_action_token tk
                    where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'))
              and (select t.status = 'pending' from erp.approval_task t where t.id = v_task);
    msg_expired := coalesce(g.err_message, 'accepted');
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_email_action_peek', v_tok);
    ok_expired := ok_expired and g.outcome ->> 'state' = 'expired';

    -- ── 9. Whoever asked still does not approve ─────────────────────────────
    v_step := 'a document''s task is delegated to the person who asked';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_req := erp.request_approval('document', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = v_req and t.status = 'pending';
    perform set_config('request.jwt.claims', json_build_object('sub', a_appr)::text, true);
    v_task := erp.delegate_approval_task(v_task, u_admin, 'the email action suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    select g1.minted_token into v_tok from erp_test.email_action_mint(v_tenant, u_admin, v_task) g1;
    select * into g from erp_test.email_action_door_as(a_admin, 'erp_decide_approval_from_email', v_tok, true);
    ok_self := v_tok is not null
           and g.err_message like 'CLOVEERP_DOCUMENT_SELF_APPROVAL%'
           and (select tk.consumed_at is null from erp.email_action_token tk
                 where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'))
           and (select t.status = 'pending' from erp.approval_task t where t.id = v_task);
    msg_self := coalesce(g.err_message, 'accepted: ' || coalesce(g.outcome::text, 'no token minted'));

    -- ── 10. The discount step still needs its permission ────────────────────
    v_step := 'a discount step waits on an approver without the permission';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_req := erp.request_approval('zz_email_terms', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = v_req and t.status = 'pending';
    select g1.minted_token into v_tok from erp_test.email_action_mint(v_tenant, u_appr, v_task) g1;
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_tok, true);
    ok_perm := v_tok is not null
           and g.err_message like 'CLOVEERP_PERMISSION_DENIED%'
           and (select tk.consumed_at is null from erp.email_action_token tk
                 where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'))
           and (select t.status = 'pending' from erp.approval_task t where t.id = v_task);
    msg_perm := coalesce(g.err_message, 'accepted');

    -- ── 11. Decided at the desk, the link is retired ────────────────────────
    v_step := 'a task with a link is decided at the desk';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_req := erp.request_approval('zz_email_action', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = v_req and t.status = 'pending';
    select g1.minted_token into v_tok from erp_test.email_action_mint(v_tenant, u_appr, v_task) g1;
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval', null, true, null, v_task);
    ok_desk := g.err_message is null
           and (select t.decided_via = 'desk' from erp.approval_task t where t.id = v_task)
           and (select tk.revoked_at is not null and tk.consumed_at is null from erp.email_action_token tk
                 where tk.token_digest = encode(extensions.digest(v_tok, 'sha256'), 'hex'));
    msg_desk := 'desk: ' || coalesce(g.outcome::text, g.err_message);
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_tok, true);
    ok_desk := ok_desk and g.err_message like 'CLOVEERP_EMAIL_ACTION_SUPERSEDED%';
    msg_desk := msg_desk || '; the link: ' || coalesce(g.err_message, 'accepted');
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_email_action_peek', v_tok);
    ok_desk := ok_desk and g.outcome ->> 'state' = 'superseded';

    -- ── 12. What is being approved changed ──────────────────────────────────
    v_step := 'the request changes after the email was sent';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_req := erp.request_approval('zz_email_action', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = v_req and t.status = 'pending';
    select g1.minted_token into v_tok from erp_test.email_action_mint(v_tenant, u_appr, v_task) g1;
    update erp.approval_request set material_fingerprint = 'changed by the email action suite' where id = v_req;
    select * into g from erp_test.email_action_door_as(a_appr, 'erp_decide_approval_from_email', v_tok, true);
    ok_changed := g.err_message like 'CLOVEERP_EMAIL_ACTION_SUPERSEDED%'
              and (select t.status = 'pending' from erp.approval_task t where t.id = v_task);
    msg_changed := coalesce(g.err_message, 'accepted');

    -- ── 13. A demonstration organisation gets no link ───────────────────────
    v_step := 'the organisation becomes a demonstration';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    v_req := erp.request_approval('zz_email_action', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = v_req and t.status = 'pending';
    -- Queued while the organisation was ordinary, so the claim is what refuses.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, context)
    values (v_tenant, 'medium', u_appr, 'email', 'Approval needed', 'The email action suite.', 'queued',
            jsonb_build_object('kind', 'approval', 'fields', jsonb_build_object('task_id', v_task)))
    returning id into v_note;
    update erp.tenant set code = 'demo-' || v_tag where id = v_tenant;
    perform set_config('erp.job_tenant_id', v_tenant::text, true);
    select count(*), max(c.action_token) into v_n, v_tok from erp.claim_email_batch(50, 'zz-email-action') c;
    perform set_config('erp.job_tenant_id', '', true);
    ok_demo := erp.tenant_is_demonstration(v_tenant) and v_n = 0 and v_tok is null
           and not exists (select 1 from erp.email_action_token tk where tk.notification_id = v_note)
           and (select n.status = 'queued' and n.channel_kind = 'email' from erp.notification n where n.id = v_note);
    select count(*) into v_n from erp.email_action_token tk where tk.notification_id = v_note;
    msg_demo := format('demonstration: token %s, %s link row(s), the email is still %s',
                       coalesce(v_tok, 'none'), v_n, (select n.status from erp.notification n where n.id = v_note));

    v_step := 'done';
    raise exception 'ZZ_EMAIL_ACTION_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_EMAIL_ACTION_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  case_name := 'a claim with no principal in context mints a link for an approval task, keeps only its digest, and none for any other email';
  passed := v_state is null and coalesce(ok_mint, false);
  detail := coalesce(v_state, msg_mint);
  return next;

  case_name := 'the same email claimed again gets a fresh link, and the old one no longer decides';
  passed := v_state is null and coalesce(ok_reissue, false);
  detail := coalesce(v_state, msg_reissue);
  return next;

  case_name := 'looking at a link tells the person it was sent to what is asked, and tells anybody else nothing';
  passed := v_state is null and coalesce(ok_peek, false);
  detail := coalesce(v_state, msg_peek);
  return next;

  case_name := 'a forwarded link pressed by somebody else is refused and stays unused';
  passed := v_state is null and coalesce(ok_forward, false);
  detail := coalesce(v_state, msg_forward);
  return next;

  case_name := 'working in another organisation, the link is refused, stays unused, and says which organisation it is for';
  passed := v_state is null and coalesce(ok_org, false);
  detail := coalesce(v_state, msg_org);
  return next;

  case_name := 'a rejection from a link needs a reason';
  passed := v_state is null and coalesce(ok_reason, false);
  detail := coalesce(v_state, msg_reason);
  return next;

  case_name := 'the person it was sent to decides once, recorded as from email, and a second press is refused';
  passed := v_state is null and coalesce(ok_once, false);
  detail := coalesce(v_state, msg_once);
  return next;

  case_name := 'a link that has run out is refused and stays unused';
  passed := v_state is null and coalesce(ok_expired, false);
  detail := coalesce(v_state, msg_expired);
  return next;

  case_name := 'whoever asked for a document''s approval still cannot approve it from a link, and the link stays usable';
  passed := v_state is null and coalesce(ok_self, false);
  detail := coalesce(v_state, msg_self);
  return next;

  case_name := 'a discount step still needs its permission from a link, and the link stays usable';
  passed := v_state is null and coalesce(ok_perm, false);
  detail := coalesce(v_state, msg_perm);
  return next;

  case_name := 'deciding at the desk retires the link';
  passed := v_state is null and coalesce(ok_desk, false);
  detail := coalesce(v_state, msg_desk);
  return next;

  case_name := 'a request that changed after the email was sent is not decided by its link';
  passed := v_state is null and coalesce(ok_changed, false);
  detail := coalesce(v_state, msg_changed);
  return next;

  case_name := 'a demonstration organisation never gets a link';
  passed := v_state is null and coalesce(ok_demo, false);
  detail := coalesce(v_state, msg_demo);
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t
                         where t.code in ('zzmailact-' || v_tag, 'zzmailact2-' || v_tag, 'demo-' || v_tag))
        and not exists (select 1 from auth.users au where au.id in (a_admin, a_appr, a_other))
        and not exists (select 1 from erp_meta.principal_preference p where p.auth_user_id = a_appr)
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before;
  detail := 'both organisations, their people, notifications and links went with the block';
  return next;
end;
$$;

revoke all on function erp_test.email_action_suite() from public, anon, authenticated;

create or replace function erp_test.assert_email_action_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _email_action on commit drop as
    select * from erp_test.email_action_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _email_action s;
  drop table _email_action;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_EMAIL_ACTION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_EMAIL_ACTION_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read each failed case''s detail above; the first names the step that raised.';
  end if;
  return format('email action: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_email_action_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_vocabulary_aligned();
select erp.assert_personal_data_register_sound();

select erp_test.assert_email_action_suite();
select erp_test.assert_notification_email_context_suite();
select erp_test.assert_email_delivery_suite();
select erp_test.assert_demo_stays_quiet_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
