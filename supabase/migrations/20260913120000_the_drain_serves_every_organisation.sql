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
-- Nine things, one file:
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
--      answers with the person's id, which the claim in 5 is asked about.
--      Beside it, erp.auth_identity_is_bound(account) says whether a sign-in
--      account is already somebody's — a member of any organisation, or
--      platform staff — so the function knows whether a password on it may have
--      been planted by somebody else and must be replaced before a link to it is
--      sent.
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
--   5. How often an invitation may be emailed, and how many organisations one
--      sign-in may make. Every invitation email is one row in
--      erp.invitation_email_log, written by erp.claim_invitation_email() in the
--      same statement that decided it may go, under one lock, before any sign-in
--      link is made. The limits are counted from those rows: an address gets at
--      most one in ten minutes and three a day from every organisation together;
--      an organisation five an hour and ten a day, or twenty and fifty once it
--      has been live for more than a week; a person sending is held to the same
--      numbers across every organisation they belong to; an invitation gets five
--      emails; and new organisations together send two hundred a day. A limit
--      kept per organisation alone is multiplied by making organisations, so
--      erp.onboard_tenant() refuses a sign-in that made one in the last day or
--      already holds two that are not live.
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
--   8. Email queued while nothing drained is not sent days late. Whenever no
--      drain pass has ever been recorded,
--      erp.retire_undrained_notifications_everywhere() suppresses, in every
--      organisation, the email and webhook messages queued, pending or held for
--      more than an hour, with the reason
--      CLOVEERP_EMAIL_NOT_SENT, and each person is shown the message in the
--      product instead, as a failed send has always left it. This file calls it
--      once; deploy.yml calls it again right before it schedules the drain, and
--      the worker on its first pass, because the first pass can come long after
--      the migration. And an organisation is never sent an incident notice
--      posted before it existed, nor anything about an incident resolved before
--      then: erp.communicate_incidents() used to give a new organisation every
--      old notice on its first minute.
--
--   9. The channel form's hint names a credential under the prefix, and the
--      dictionary holds its words.
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

-- Whether a sign-in account is already somebody's. The invite function makes a
-- sign-in link for the address an invitation names, and when that address
-- already has an account the link signs into it. An account nobody has joined
-- with may carry a password somebody else chose before the invitation was
-- sent, so the function replaces that password before it sends the link. An
-- account a person already signs in with, as a member of an organisation or as
-- platform staff, is theirs, and its password is left alone.
create or replace function erp.auth_identity_is_bound(p_auth_user_id uuid)
returns boolean
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not ask whether a sign-in account is in use', current_user
      using errcode = '42501',
            hint = 'The invite function asks over its own database connection. A signed-in session never asks about another account.';
  end if;

  if p_auth_user_id is null then
    return false;
  end if;

  -- A membership counts whatever its status: an account suspended from one
  -- organisation is still a person's own. Staff count once they have signed
  -- in, which is when the staff row takes the account's id; a staff row still
  -- waiting for its first sign-in names an address, not an account.
  return exists (select 1 from erp.app_user u where u.auth_user_id = p_auth_user_id)
      or exists (select 1 from erp_meta.platform_staff s where s.auth_user_id = p_auth_user_id);
end;
$$;
revoke all on function erp.auth_identity_is_bound(uuid) from public, anon, authenticated;

comment on function erp.auth_identity_is_bound(uuid) is
  'Whether a Supabase Auth account is already in use: some organisation has a '
  'member signed in with it, or a platform staff row carries it. False for an '
  'account nobody has joined with, and for null. Trusted sessions only: the '
  'invite function asks before it sends a sign-in link into an existing account, '
  'and replaces the password of one that is not in use.';

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
-- 5. How often an invitation may be emailed, and how many organisations one
--    sign-in may make
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Every invitation email the invite function sends is one row in
-- erp.invitation_email_log, written before the sign-in link is made by the same
-- statement that decided the email may go. Every limit is counted from those
-- rows, under one lock, so any number of copies of the function asking at once
-- cannot between them send more than the rows allow. A limit kept per
-- organisation alone is multiplied by making organisations, so the limits are
-- also kept per address, per person sending across every organisation they
-- belong to, and across every new organisation together; and one sign-in may
-- not make organisations one after another.

-- An earlier draft of this file, never released, counted on the invitation
-- itself, asked before sending and recorded after. A database that ran it loses
-- both here.
drop function if exists erp_test.assert_invitation_send_allowance_suite();
drop function if exists erp_test.invitation_send_allowance_suite();
drop function if exists erp.invitation_send_allowance(uuid, text);
drop function if exists erp.note_invitation_link_sent(uuid);
alter table erp.invitation drop constraint if exists invitation_links_sent_check;
alter table erp.invitation drop column if exists link_sent_at;
alter table erp.invitation drop column if exists links_sent;

create table if not exists erp.invitation_email_log (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references erp.tenant (id) on delete cascade,
  -- The invitation the email was for. Not a foreign key: the row is counted
  -- after the invitation is superseded, claimed or gone.
  invitation_id        uuid,
  app_user_id          uuid not null,
  -- The address, folded, as it is counted across every organisation.
  email_lower          text not null,
  -- The Supabase Auth account of the person who sent it. Null for a fresh
  -- sign-in link asked for with an invitation link, which nobody signed in sends.
  sent_by_auth_user_id uuid,
  kind                 text not null check (kind in ('invite', 'resend')),
  created_at           timestamptz not null default now(),
  created_by           uuid,
  constraint invitation_email_log_address_folded
    check (email_lower = lower(btrim(email_lower)) and email_lower <> '')
);

create index if not exists invitation_email_log_tenant_idx
  on erp.invitation_email_log (tenant_id, created_at);
create index if not exists invitation_email_log_address_idx
  on erp.invitation_email_log (email_lower, created_at);
create index if not exists invitation_email_log_sender_idx
  on erp.invitation_email_log (sent_by_auth_user_id, created_at);
create index if not exists invitation_email_log_invitation_idx
  on erp.invitation_email_log (invitation_id) where invitation_id is not null;

comment on table erp.invitation_email_log is
  'Every invitation email and fresh sign-in link the invite function was allowed '
  'to send, one row each, written by erp.claim_invitation_email() before the link '
  'is made. The sending limits are counted from these rows. Append-only.';

select erp_meta.register_table('erp', 'invitation_email_log', 'tenant_scoped_append_only',
  'Invitation emails sent, one row each, counted for the sending limits.');

-- The address is kept after the person it was for is erased: it is what stops
-- one address being sent invitation emails from every organisation at once,
-- and erp.execute_erasure() reaches a principal inside one organisation while
-- this is counted across all of them.
insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp', 'invitation_email_log', 'email_lower',
   'The address an invitation email went to, kept as the minimum record that it '
   'was written to, so the sending limits can count every organisation''s email to '
   'one address together. Erasing it would reset the limit that protects that '
   'address, as erasing a suppression would resume the writing it stopped.')
on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

create or replace function erp.claim_invitation_email(p_app_user_id uuid, p_kind text, p_auth_user_id uuid)
returns table (allowed boolean, reason text)
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  c_address_day   constant integer := 3;
  c_new_hour      constant integer := 5;
  c_new_day       constant integer := 10;
  c_trusted_hour  constant integer := 20;
  c_trusted_day   constant integer := 50;
  c_emails        constant integer := 5;
  c_new_together  constant integer := 200;
  v_tenant        uuid;
  v_email         text;
  v_pending       uuid;
  v_trusted       boolean;
  v_hour_cap      integer;
  v_day_cap       integer;
  v_recent        integer;
  v_hour          integer;
  v_day           integer;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not claim an invitation email', current_user
      using errcode = '42501',
            hint = 'The invite function claims over its own database connection. A signed-in session invites through the door, and the function decides whether the email goes.';
  end if;

  if p_kind is null or p_kind not in ('invite', 'resend') then
    raise exception 'CLOVEERP_INVITATION_EMAIL_KIND_UNKNOWN: % is not a kind of invitation email', coalesce(p_kind, 'null')
      using errcode = '22023',
            hint = 'Claim with invite once the door has made the invitation, or with resend before a fresh sign-in link is made.';
  end if;

  -- One claim at a time, everywhere. The counts below and the row that ends
  -- the claim are read and written under this lock, and it is held until the
  -- claim's transaction ends, so a claim waiting for it counts the row the
  -- claim before it wrote.
  perform pg_advisory_xact_lock(hashtext('erp.claim_invitation_email'));

  select u.tenant_id, lower(btrim(u.email))
    into v_tenant, v_email
    from erp.app_user u
   where u.id = p_app_user_id;

  -- The invitation the email would be for: the newest one this person could
  -- still redeem. None, or nowhere to send it, and there is nothing to email.
  if v_tenant is not null and coalesce(v_email, '') <> '' then
    select i.id into v_pending
      from erp.invitation i
     where i.tenant_id = v_tenant
       and i.app_user_id = p_app_user_id
       and i.claimed_at is null
       and i.revoked_at is null
       and i.expires_at > now()
     order by i.created_at desc, i.id desc
     limit 1;
  end if;
  if v_pending is null then
    return query select false, 'no such invitation'::text;
    return;
  end if;

  -- Every count below includes the email being claimed: the rows already on
  -- file, and one.

  -- 1. One invitation, five emails, whoever asks for them.
  select count(*) into v_day
    from erp.invitation_email_log l
   where l.invitation_id = v_pending;
  if v_day + 1 > c_emails then
    return query select false, 'Too many sign-in links have been sent for this invitation.'::text;
    return;
  end if;

  -- 2. One address, from every organisation together: ten minutes apart, and
  --    three a day.
  select count(*) filter (where l.created_at > now() - interval '10 minutes'),
         count(*)
    into v_recent, v_day
    from erp.invitation_email_log l
   where l.email_lower = v_email
     and l.created_at > now() - interval '24 hours';
  if v_recent + 1 > 1 then
    return query select false, 'This address was sent an invitation email less than ten minutes ago.'::text;
    return;
  end if;
  if v_day + 1 > c_address_day then
    return query select false, 'This address has already had three invitation emails today.'::text;
    return;
  end if;

  -- 3. The organisation. One that has been live for more than a week has shown
  --    it is one; anything newer, or never live, sends little until it has.
  select coalesce(erp.tenant_is_live(t.id) and t.created_at < now() - interval '7 days', false)
    into v_trusted
    from erp.tenant t
   where t.id = v_tenant;
  v_trusted := coalesce(v_trusted, false);
  v_hour_cap := case when v_trusted then c_trusted_hour else c_new_hour end;
  v_day_cap  := case when v_trusted then c_trusted_day  else c_new_day  end;

  select count(*) filter (where l.created_at > now() - interval '1 hour'),
         count(*)
    into v_hour, v_day
    from erp.invitation_email_log l
   where l.tenant_id = v_tenant
     and l.created_at > now() - interval '24 hours';
  if v_hour + 1 > v_hour_cap then
    return query select false, 'Too many invitations have been sent from this organisation in the last hour.'::text;
    return;
  end if;
  if v_day + 1 > v_day_cap then
    return query select false, 'Too many invitations have been sent from this organisation today.'::text;
    return;
  end if;

  -- 4. The person sending, across every organisation they are an active member
  --    of: the same numbers, over all of those organisations' email together,
  --    and the smaller numbers if any of them has not yet earned the larger. A
  --    second organisation adds nothing to spend.
  if p_auth_user_id is not null then
    select coalesce(bool_and(coalesce(erp.tenant_is_live(t.id) and t.created_at < now() - interval '7 days', false)), true)
      into v_trusted
      from erp.tenant t
     where t.id in (select u.tenant_id from erp.app_user u
                     where u.auth_user_id = p_auth_user_id and u.status = 'active');
    v_hour_cap := case when v_trusted then c_trusted_hour else c_new_hour end;
    v_day_cap  := case when v_trusted then c_trusted_day  else c_new_day  end;

    select count(*) filter (where l.created_at > now() - interval '1 hour'),
           count(*)
      into v_hour, v_day
      from erp.invitation_email_log l
     where l.tenant_id in (select u.tenant_id from erp.app_user u
                            where u.auth_user_id = p_auth_user_id and u.status = 'active')
       and l.created_at > now() - interval '24 hours';
    if v_hour + 1 > v_hour_cap then
      return query select false, 'You have sent too many invitations in the last hour.'::text;
      return;
    end if;
    if v_day + 1 > v_day_cap then
      return query select false, 'You have sent too many invitations today.'::text;
      return;
    end if;
  end if;

  -- 5. Every organisation that has not yet earned the larger numbers, together.
  --    However many there are, and however many people made them, they share
  --    one day's email.
  select coalesce(erp.tenant_is_live(t.id) and t.created_at < now() - interval '7 days', false)
    into v_trusted
    from erp.tenant t
   where t.id = v_tenant;
  if not coalesce(v_trusted, false) then
    select coalesce(sum(x.n), 0)::integer
      into v_day
      from (select l.tenant_id, count(*) as n
              from erp.invitation_email_log l
             where l.created_at > now() - interval '24 hours'
             group by l.tenant_id) x
      join erp.tenant t on t.id = x.tenant_id
     where not coalesce(erp.tenant_is_live(t.id) and t.created_at < now() - interval '7 days', false);
    if v_day + 1 > c_new_together then
      return query select false, 'New organisations have sent as many invitation emails as they may today. Try again tomorrow.'::text;
      return;
    end if;
  end if;

  insert into erp.invitation_email_log
    (tenant_id, invitation_id, app_user_id, email_lower, sent_by_auth_user_id, kind)
  values
    (v_tenant, v_pending, p_app_user_id, v_email, p_auth_user_id, p_kind);

  return query select true, null::text;
end;
$$;
revoke all on function erp.claim_invitation_email(uuid, text, uuid) from public, anon, authenticated;

comment on function erp.claim_invitation_email(uuid, text, uuid) is
  'Claims one invitation email for this person''s newest pending invitation, or '
  'says why not. Counted from erp.invitation_email_log under one lock, the '
  'email included: five per invitation; per address across every organisation, '
  'one in ten minutes and three a day; per organisation, five an hour and ten a '
  'day, or twenty and fifty once live for more than a week; per person sending '
  '(the Supabase Auth account, when given), the same over every organisation '
  'they are an active member of, at the smaller numbers if any is not yet '
  'trusted; and two hundred a day across every organisation not yet trusted. '
  'When every limit holds it writes the row and answers yes. No rather than an '
  'error for a person with nothing pending. invite is claimed once the door has '
  'made the invitation, resend before a fresh sign-in link is made. Trusted '
  'sessions only; SECURITY INVOKER so the trust test sees the role that connected.';

-- One sign-in, one new organisation at a time. Every organisation can email
-- invitations, so a sign-in that could make organisations one after another
-- could email without limit. erp.onboard_tenant() is the door a signed-in person
-- makes an organisation through; the platform's own onboarding goes through
-- erp.provision_tenant() and is not touched.
do $onboarding$
declare
  v_sig text := 'erp.onboard_tenant(text,text)';
  v_def text := pg_get_functiondef('erp.onboard_tenant(text,text)'::regprocedure);
  v_n   text := $n$  insert into erp.tenant (code, name, status, provisioned_at)
$n$;
  v_r   text := $r$  -- Each organisation can email invitations, so a sign-in that could make
  -- organisations one after another could email without limit. Nobody who
  -- made an organisation in the last day makes another, nor anybody who
  -- already holds two that are not live. The lock keeps two requests from the
  -- same sign-in from both passing before either has made its organisation.
  perform pg_advisory_xact_lock(hashtext('erp.onboard_tenant'), hashtext(v_auth_id::text));
  if exists (select 1
               from erp.app_user u
               join erp.tenant t on t.id = u.tenant_id
              where u.auth_user_id = v_auth_id
                and u.status = 'active'
                and t.created_at > now() - interval '24 hours')
     or (select count(*)
           from erp.app_user u
          where u.auth_user_id = v_auth_id
            and u.status = 'active'
            and not erp.tenant_is_live(u.tenant_id)) >= 2 then
    raise exception 'CLOVEERP_ONBOARDING_LIMIT: this sign-in made an organisation in the last day, or already has two that are not live, so it cannot make another'
      using errcode = '42501',
            hint = 'Contact Clove ERP to add another organisation.';
  end if;

$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_ONBOARDING_UNRECOGNISED: erp.onboard_tenant() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r || v_n);

  if position('CLOVEERP_ONBOARDING_LIMIT' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_ONBOARDING_UNRECOGNISED: erp.onboard_tenant() did not take the limit';
  end if;
end
$onboarding$;

select erp.register_refusal('CLOVEERP_ONBOARDING_LIMIT',
  'Making another organisation from a sign-in that made one in the last day, or that already has two that are not live.',
  'Every organisation can send invitation emails, so organisations made one after another would let one sign-in send email without any limit.',
  'Contact Clove ERP to add another organisation.');

-- The privilege's written reason gains the read the limit makes.
do $onboarding_allowance$
declare v_moved integer;
begin
  update erp_meta.security_definer_allowance
     set rationale = 'Creates a tenant for a caller who has no principal and therefore no tenant '
                     'context, so row-level security has nothing to scope to. Writes only rows '
                     'belonging to the tenant it is creating, and binds it to auth.uid(). Before it '
                     'writes, it reads only the organisations auth.uid() is already an active member '
                     'of, when each was made and whether it is live, to refuse a caller who made one '
                     'in the last day or holds two that are not live.'
   where schema_name = 'erp' and function_name = 'onboard_tenant';
  get diagnostics v_moved = row_count;
  if v_moved <> 1 then
    raise exception 'CLOVEERP_ALLOWANCE_NOT_MOVED: % row(s) updated for erp.onboard_tenant, expected 1', v_moved;
  end if;
end
$onboarding_allowance$;

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
-- it stands in for). Anything younger goes out as normal. And an organisation
-- made after an incident was declared is not sent that incident's history.

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
  'leaves. Returns how many. Called for every organisation by '
  'erp.retire_undrained_notifications_everywhere() while no drain pass has been '
  'recorded. Trusted sessions only.';

-- The migration is not the moment draining starts. A deploy can stop between
-- them, the drain can fail to start for hours, and meanwhile the minute pass
-- keeps queueing: job failures, approval tasks, incident notices. So the
-- retirement is a function anybody about to start the drain calls — this file
-- once, deploy.yml right before it schedules the drain, and the worker on its
-- first pass — and it does nothing at all once a drain pass is on record.
create or replace function erp.retire_undrained_notifications_everywhere()
returns table (tenant_code text, retired integer)
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  t           record;
  v_claims    text := coalesce(current_setting('request.jwt.claims', true), '');
  v_tenant    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_principal text := coalesce(current_setting('erp.job_principal_id', true), '');
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not retire queued messages', current_user
      using errcode = '42501',
            hint = 'The release, deploy.yml and the dispatch worker retire what waited for the first drain. A signed-in session never does.';
  end if;

  -- Once anything has drained, whatever is queued is the drain's to send.
  if exists (select 1 from erp_meta.drain_pass) then
    return;
  end if;

  for t in
    select tn.id, tn.code
      from erp.tenant tn
     order by tn.code
  loop
    -- Each organisation for this transaction only, as nobody in it.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('erp.job_tenant_id', t.id::text, true);
    tenant_code := t.code;
    retired := erp.retire_undrained_notifications();
    return next;
  end loop;

  -- And the caller's own context back as it was.
  perform set_config('request.jwt.claims', v_claims, true);
  perform set_config('erp.job_tenant_id', v_tenant, true);
  perform set_config('erp.job_principal_id', v_principal, true);
end;
$$;
revoke all on function erp.retire_undrained_notifications_everywhere() from public, anon, authenticated;

comment on function erp.retire_undrained_notifications_everywhere() is
  'While no drain pass has been recorded, retires in every organisation the '
  'email and webhook messages that waited more than an hour for a drain, '
  'through erp.retire_undrained_notifications(), and answers each organisation''s '
  'code with how many. No rows, and nothing touched, once any drain pass is on '
  'record. The release that brings the drain calls it, deploy.yml calls it right '
  'before scheduling the drain, and the worker calls it on its first pass. '
  'Trusted sessions only; the caller''s own context is restored.';

do $backlog$
declare
  r        record;
  v_orgs   integer := 0;
  v_total  integer := 0;
begin
  if exists (select 1 from erp_meta.drain_pass) then
    raise notice 'queued messages: a drain pass has run here, so nothing waited for nobody';
    return;
  end if;

  for r in select e.tenant_code, e.retired from erp.retire_undrained_notifications_everywhere() e loop
    v_orgs := v_orgs + 1;
    v_total := v_total + r.retired;
    if r.retired > 0 then
      raise notice '%: % message(s) queued before email could leave are shown in the product instead', r.tenant_code, r.retired;
    end if;
  end loop;

  raise notice 'queued messages: % retired across % organisation(s)', v_total, v_orgs;
end
$backlog$;

-- An organisation is told what happened while it existed. The sweep delivered
-- every declaration and update it had no delivery row for, and nothing writes
-- those rows when an organisation is made, so a new organisation's first minute
-- queued an email for every notice ever posted to all organisations, resolved
-- incidents included. Now a declaration or an update posted before the
-- organisation was made is not sent to it, nor anything about an incident
-- resolved before then; one still open is followed from its next update.
do $incidents$
declare
  v_sig text := 'erp.communicate_incidents()';
  v_def text := pg_get_functiondef('erp.communicate_incidents()'::regprocedure);
  v_new text;
  n1 text := $n$  v_cmd      uuid;
begin
$n$;
  r1 text := $r$  v_cmd      uuid;
  v_created  timestamptz;
begin
$r$;
  n2 text := $n$  v_plat := erp.is_platform_organisation(v_tenant);
$n$;
  r2 text := $r$  v_plat := erp.is_platform_organisation(v_tenant);
  -- When this organisation was made. Nothing posted before it is its news.
  select t.created_at into v_created from erp.tenant t where t.id = v_tenant;
$r$;
  n3 text := $n$       where exists (select 1 from erp_meta.incident_tenant t where t.incident_id = i.id and t.tenant_id = v_tenant)
          or coalesce(i.affects_all_tenants, false))
$n$;
  r3 text := $r$       where (exists (select 1 from erp_meta.incident_tenant t where t.incident_id = i.id and t.tenant_id = v_tenant)
              or coalesce(i.affects_all_tenants, false))
         -- Nothing about an incident resolved before this organisation existed.
         and (i.resolved_at is null or i.resolved_at >= v_created))
$r$;
  n4 text := $n$                        where d.tenant_id = v_tenant and d.incident_id = m.id and d.incident_update_id is null)
$n$;
  r4 text := $r$                        where d.tenant_id = v_tenant and d.incident_id = m.id and d.incident_update_id is null)
       and m.declared_at >= v_created
       and m.created_at >= v_created
$r$;
  n5 text := $n$                        where d.tenant_id = v_tenant and d.incident_id = m.id and d.incident_update_id = up.id)
$n$;
  r5 text := $r$                        where d.tenant_id = v_tenant and d.incident_id = m.id and d.incident_update_id = up.id)
       and up.posted_at >= v_created
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1
     or (length(v_def) - length(replace(v_def, n2, ''))) / length(n2) <> 1
     or (length(v_def) - length(replace(v_def, n3, ''))) / length(n3) <> 1
     or (length(v_def) - length(replace(v_def, n4, ''))) / length(n4) <> 1
     or (length(v_def) - length(replace(v_def, n5, ''))) / length(n5) <> 1 then
    raise exception 'CLOVEERP_INCIDENT_SWEEP_UNRECOGNISED: erp.communicate_incidents() is not the body this migration patches';
  end if;
  v_new := replace(replace(replace(replace(replace(v_def, n1, r1), n2, r2), n3, r3), n4, r4), n5, r5);
  execute v_new;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('i.resolved_at >= v_created' in v_def) = 0
     or position('m.declared_at >= v_created' in v_def) = 0
     or position('up.posted_at >= v_created' in v_def) = 0 then
    raise exception 'CLOVEERP_INCIDENT_SWEEP_UNRECOGNISED: erp.communicate_incidents() did not take the organisation''s own start';
  end if;
end
$incidents$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The words the channel form says
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The form's hint suggested env://OPS_CHAT_TOKEN, which section 6 now refuses.
-- It names a variable under the prefix, and the dictionary holds the words so
-- an organisation can rename them.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). The channel form''s hint for a credential reference, naming a variable the worker resolves.'
  from (values
  ('A pointer into a secret store, such as env://CLOVEERP_CREDENTIAL_OPS_CHAT. Never the secret.')
) as v(text)
on conflict (key, locale) do update set value = excluded.value;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The suites
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
  v_staff      uuid := gen_random_uuid();
  v_bound_before boolean;
  v_bound_after  boolean;
  v_bound_staff  boolean;
  v_bound_nobody boolean;
  v_bound_null   boolean;
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

  -- 4. Whether an account is in use is refused to a signed-in session too.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.auth_identity_is_bound(uuid) to authenticated';
    execute 'set local role authenticated';
    perform erp.auth_identity_is_bound(gen_random_uuid());
    v_msg := 'with execute granted, a signed-in session was told whether an account is in use';
    raise exception 'ZZ_RESEND_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_RESEND_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, the account check still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 5.
  select not p.prosecdef into v_ok
    from pg_catalog.pg_proc p where p.oid = 'erp.auth_identity_is_bound(uuid)'::regprocedure;
  case_name := 'the account check''s trust test runs in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 6-10 mint, age, claim and supersede invitations through the real doors, ask
  -- whether accounts are in use, and undo all of it.
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

    -- A claimed one: the administrator signs in and redeems it. The account
    -- they signed in with is nobody's before, and theirs after.
    v_bound_before := erp.auth_identity_is_bound(v_subject);
    perform set_config('request.jwt.claims', json_build_object('sub', v_subject)::text, true);
    perform erp.claim_invitation(r.admin_token);
    select count(*) into v_claimed_n from erp.invitation_for_resend(r.admin_token);
    v_bound_after := erp.auth_identity_is_bound(v_subject);

    -- Platform staff who have signed in; an account nobody has; and none.
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('staff-' || v_code || '@zz-resend.test', v_staff, 'Resend suite staff', 'support');
    v_bound_staff := erp.auth_identity_is_bound(v_staff);
    v_bound_nobody := erp.auth_identity_is_bound(gen_random_uuid());
    v_bound_null := erp.auth_identity_is_bound(null);

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

  case_name := 'an account nobody joined with is not in use; one a member signs in with, or platform staff, is';
  passed := v_state is null
            and v_bound_before is false and v_bound_after is true and v_bound_staff is true
            and v_bound_nobody is false and v_bound_null is false;
  detail := coalesce(v_state, format('before joining %s, after %s; staff %s; nobody''s %s; none %s',
                                     coalesce(v_bound_before::text, 'no answer'), coalesce(v_bound_after::text, 'no answer'),
                                     coalesce(v_bound_staff::text, 'no answer'), coalesce(v_bound_nobody::text, 'no answer'),
                                     coalesce(v_bound_null::text, 'no answer')));
  return next;

  -- 11. Garbage is zero rows, never an error.
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
  c_expected constant integer := 11;
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

-- Fixtures for the invitation email suite. Rows are written directly so their
-- times can be set: the attribution trigger keeps a created_at it is given.

create or replace function erp_test.invitation_email_organisation(p_code text, p_created_at timestamptz, p_live boolean)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into erp.tenant (code, name, status, created_at)
  values (p_code, 'Invitation email suite', 'active', p_created_at)
  returning id into v_id;
  perform erp.set_job_tenant(v_id);
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self)
  values (v_id, 'production', 'Production', 'production', p_live, true);
  return v_id;
end;
$$;
revoke all on function erp_test.invitation_email_organisation(text, timestamptz, boolean) from public, anon, authenticated;

create or replace function erp_test.invitation_email_person(p_tenant uuid, p_email text, p_invited_at timestamptz default now())
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform erp.set_job_tenant(p_tenant);
  insert into erp.app_user (tenant_id, kind, status, display_name, email)
  values (p_tenant, 'person', 'invited', 'Invited person', p_email)
  returning id into v_id;
  insert into erp.invitation (tenant_id, app_user_id, token_digest, created_at, expires_at)
  values (p_tenant, v_id, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
          p_invited_at, p_invited_at + interval '7 days');
  return v_id;
end;
$$;
revoke all on function erp_test.invitation_email_person(uuid, text, timestamptz) from public, anon, authenticated;

create or replace function erp_test.invitation_email_sent(p_tenant uuid, p_count integer, p_ago interval,
                                                         p_email text default null, p_invitation uuid default null)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  insert into erp.invitation_email_log (tenant_id, invitation_id, app_user_id, email_lower, kind, created_at)
  select p_tenant, p_invitation, gen_random_uuid(),
         coalesce(lower(p_email), 'sent-' || g || '-' || replace(gen_random_uuid()::text, '-', '') || '@zz-mail.test'),
         case when p_invitation is null then 'invite' else 'resend' end,
         now() - p_ago
    from generate_series(1, p_count) g;
end;
$$;
revoke all on function erp_test.invitation_email_sent(uuid, integer, interval, text, uuid) from public, anon, authenticated;

-- The claim's answer as one line: 'true: -', or 'false: ' and the reason.
create or replace function erp_test.invitation_email_answer(p_app_user_id uuid, p_kind text, p_auth_user_id uuid)
returns text
language sql
volatile
security invoker
set search_path = ''
as $$
  select format('%s: %s', a.allowed::text, coalesce(a.reason, '-'))
    from erp.claim_invitation_email(p_app_user_id, p_kind, p_auth_user_id) a
$$;
revoke all on function erp_test.invitation_email_answer(uuid, text, uuid) from public, anon, authenticated;

create or replace function erp_test.invitation_email_budget_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_yes          constant text := 'true: -';
  c_none         constant text := 'false: no such invitation';
  c_links        constant text := 'false: Too many sign-in links have been sent for this invitation.';
  c_gap          constant text := 'false: This address was sent an invitation email less than ten minutes ago.';
  c_address      constant text := 'false: This address has already had three invitation emails today.';
  c_org_hour     constant text := 'false: Too many invitations have been sent from this organisation in the last hour.';
  c_org_day      constant text := 'false: Too many invitations have been sent from this organisation today.';
  c_you_hour     constant text := 'false: You have sent too many invitations in the last hour.';
  c_you_day      constant text := 'false: You have sent too many invitations today.';
  c_together     constant text := 'false: New organisations have sent as many invitation emails as they may today. Try again tomorrow.';
  v_tag          text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  v_inviter      uuid := gen_random_uuid();
  v_s1           uuid := gen_random_uuid();
  v_s2           uuid := gen_random_uuid();
  v_s3           uuid := gen_random_uuid();
  v_s4           uuid := gen_random_uuid();
  v_s5           uuid := gen_random_uuid();
  v_first_sub    uuid := gen_random_uuid();
  v_two_sub      uuid := gen_random_uuid();
  v_one_sub      uuid := gen_random_uuid();
  v_ok           boolean;
  v_msg          text;
  v_hint         text;
  v_state        text;
  v_onboard_state text;
  v_unknown      text;
  v_org          uuid;
  v_other        uuid;
  v_new          uuid;
  v_trusted      uuid;
  v_fill         uuid;
  v_p            uuid;
  v_q            uuid;
  v_inv          uuid;
  v_base         integer;
  v_first        text;
  v_logged       integer;
  v_logged_ok    boolean;
  v_again_invite text;
  v_again_resend text;
  v_claimed      text;
  v_claimed_resend text;
  v_refused_rows integer;
  v_gap_nine     text;
  v_gap_eleven   text;
  v_shared_one   text;
  v_shared_two   text;
  v_third        text;
  v_fourth       text;
  v_links_fifth  text;
  v_links_sixth  text;
  v_hour_fifth   text;
  v_hour_sixth   text;
  v_parked_sixth text;
  v_day_tenth    text;
  v_day_eleventh text;
  v_t_twentieth  text;
  v_t_next_hour  text;
  v_t_fiftieth   text;
  v_t_next_day   text;
  v_you_fifth    text;
  v_you_sixth    text;
  v_second_org   text;
  v_you_tenth    text;
  v_you_eleventh text;
  v_mixed        text;
  v_all_trusted  text;
  v_together_last text;
  v_together_over text;
  v_together_trusted text;
  v_update_msg   text;
  v_delete_msg   text;
  v_reasons      text;
  v_onboarded    jsonb;
  v_second_msg   text;
  v_second_made  integer;
  v_two_msg      text;
  v_one_made     jsonb;
begin
  -- 1. Refused without EXECUTE.
  begin
    execute 'set local role authenticated';
    perform 1 from erp.claim_invitation_email(gen_random_uuid(), 'invite', null);
    execute 'reset role';
    v_ok := false; v_msg := 'a signed-in session claimed an invitation email';
  exception when others then
    execute 'reset role';
    v_ok := sqlstate = '42501'; v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a signed-in session cannot claim an invitation email';
  passed := v_ok; detail := v_msg;
  return next;

  -- 2. Refused by the function itself, should a grant ever reach it.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.claim_invitation_email(uuid, text, uuid) to authenticated';
    execute 'set local role authenticated';
    perform 1 from erp.claim_invitation_email(gen_random_uuid(), 'invite', null);
    v_msg := 'with execute granted, a signed-in session was answered';
    raise exception 'ZZ_BUDGET_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_BUDGET_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, the claim still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 3.
  select not p.prosecdef into v_ok
    from pg_catalog.pg_proc p where p.oid = 'erp.claim_invitation_email(uuid,text,uuid)'::regprocedure;
  case_name := 'the claim''s trust test runs in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 4.
  v_ok := true; v_msg := null;
  foreach v_unknown in array array['remind', ''] loop
    begin
      perform 1 from erp.claim_invitation_email(gen_random_uuid(), v_unknown, null);
      v_ok := false; v_msg := concat_ws('; ', v_msg, format('%L was answered', v_unknown));
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      if not (sqlstate = '22023' and sqlerrm like 'CLOVEERP_INVITATION_EMAIL_KIND_UNKNOWN:%' and coalesce(v_hint, '') <> '') then
        v_ok := false; v_msg := concat_ws('; ', v_msg, left(sqlerrm, 80));
      end if;
    end;
  end loop;
  begin
    perform 1 from erp.claim_invitation_email(gen_random_uuid(), null, null);
    v_ok := false; v_msg := concat_ws('; ', v_msg, 'no kind was answered');
  exception when others then
    if sqlstate <> '22023' then v_ok := false; v_msg := concat_ws('; ', v_msg, left(sqlerrm, 80)); end if;
  end;
  case_name := 'a kind that is neither invite nor resend is refused by name, with the next action';
  passed := v_ok; detail := coalesce(v_msg, 'remind, blank and no kind refused');
  return next;

  -- 5.
  begin
    select concat_ws(' | ',
             coalesce(erp_test.invitation_email_answer(gen_random_uuid(), 'invite', gen_random_uuid()), 'no row'),
             coalesce(erp_test.invitation_email_answer(gen_random_uuid(), 'resend', null), 'no row'),
             coalesce(erp_test.invitation_email_answer(null, 'invite', null), 'no row'))
      into v_unknown;
    v_msg := null;
  exception when others then
    v_msg := 'raised: ' || left(sqlerrm, 120);
  end;
  case_name := 'a person nobody invited is answered no, never an error';
  passed := v_msg is null and v_unknown = concat_ws(' | ', c_none, c_none, c_none);
  detail := coalesce(v_msg, v_unknown);
  return next;

  -- 6-25 build organisations, people and email already sent, claim, and undo
  -- all of it.
  begin
    -- Nobody signed in: every row below is written for the organisation named.
    perform set_config('request.jwt.claims', '', true);

    -- A new organisation, already live; and one live for a month.
    v_new := erp_test.invitation_email_organisation('zz-mail-new-' || v_tag, now(), true);
    v_trusted := erp_test.invitation_email_organisation('zz-mail-trusted-' || v_tag, now() - interval '30 days', true);

    -- ── One invitation, emailed; made again; asked for again ───────────────────
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_new, v_inviter, 'person', 'active', 'Inviter', 'inviter@' || v_tag || '.test');
    v_p := erp_test.invitation_email_person(v_new, 'first@' || v_tag || '.test');
    select i.id into v_inv from erp.invitation i where i.tenant_id = v_new and i.app_user_id = v_p;
    v_first := erp_test.invitation_email_answer(v_p, 'invite', v_inviter);
    select count(*),
           coalesce(bool_and(l.tenant_id = v_new and l.invitation_id = v_inv and l.app_user_id = v_p
                             and l.email_lower = 'first@' || v_tag || '.test'
                             and l.sent_by_auth_user_id = v_inviter and l.kind = 'invite'
                             and l.created_at = now()), false)
      into v_logged, v_logged_ok
      from erp.invitation_email_log l
     where l.app_user_id = v_p;

    -- The door invites the same person again: the first invitation is
    -- superseded and a new one made. Then a fresh link is asked for with it.
    perform erp.set_job_tenant(v_new);
    update erp.invitation i set revoked_at = now(), revoked_reason = 'superseded by a new invitation'
     where i.tenant_id = v_new and i.app_user_id = v_p and i.revoked_at is null;
    insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
    values (v_new, v_p, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now() + interval '7 days');
    v_again_invite := erp_test.invitation_email_answer(v_p, 'invite', v_inviter);
    v_again_resend := erp_test.invitation_email_answer(v_p, 'resend', null);

    -- An invitation already redeemed.
    v_q := erp_test.invitation_email_person(v_new, 'claimed@' || v_tag || '.test');
    update erp.invitation i set claimed_at = now(), claimed_by = gen_random_uuid()
     where i.tenant_id = v_new and i.app_user_id = v_q;
    v_claimed := erp_test.invitation_email_answer(v_q, 'invite', v_inviter);
    v_claimed_resend := erp_test.invitation_email_answer(v_q, 'resend', null);
    select count(*) into v_refused_rows
      from erp.invitation_email_log l
     where l.app_user_id = v_q
        or (l.app_user_id = v_p and l.invitation_id <> v_inv);

    -- ── One address ───────────────────────────────────────────────────────────
    -- Emailed nine minutes ago, and eleven minutes ago.
    v_q := erp_test.invitation_email_person(v_trusted, 'gap-nine@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_trusted, 1, interval '9 minutes', 'gap-nine@' || v_tag || '.test');
    v_gap_nine := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_trusted, 'gap-eleven@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_trusted, 1, interval '11 minutes', 'gap-eleven@' || v_tag || '.test');
    v_gap_eleven := erp_test.invitation_email_answer(v_q, 'invite', null);

    -- The same address in two organisations, written differently.
    v_q := erp_test.invitation_email_person(v_trusted, 'Shared@' || v_tag || '.test');
    v_shared_one := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_new, 'shared@' || v_tag || '.test');
    v_shared_two := erp_test.invitation_email_answer(v_q, 'invite', null);

    -- Two emails earlier today, then three.
    v_q := erp_test.invitation_email_person(v_trusted, 'third@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_trusted, 2, interval '2 hours', 'third@' || v_tag || '.test');
    v_third := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_trusted, 'fourth@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_trusted, 3, interval '2 hours', 'fourth@' || v_tag || '.test');
    v_fourth := erp_test.invitation_email_answer(v_q, 'invite', null);

    -- ── One invitation ────────────────────────────────────────────────────────
    -- Invited three days ago; four links went two days ago, then five.
    v_q := erp_test.invitation_email_person(v_trusted, 'links-four@' || v_tag || '.test', now() - interval '3 days');
    select i.id into v_inv from erp.invitation i where i.tenant_id = v_trusted and i.app_user_id = v_q;
    perform erp_test.invitation_email_sent(v_trusted, 4, interval '2 days', 'links-four@' || v_tag || '.test', v_inv);
    v_links_fifth := erp_test.invitation_email_answer(v_q, 'resend', null);
    v_q := erp_test.invitation_email_person(v_trusted, 'links-five@' || v_tag || '.test', now() - interval '3 days');
    select i.id into v_inv from erp.invitation i where i.tenant_id = v_trusted and i.app_user_id = v_q;
    perform erp_test.invitation_email_sent(v_trusted, 5, interval '2 days', 'links-five@' || v_tag || '.test', v_inv);
    v_links_sixth := erp_test.invitation_email_answer(v_q, 'resend', null);

    -- ── One organisation ──────────────────────────────────────────────────────
    -- New and live: four this hour, then five.
    v_org := erp_test.invitation_email_organisation('zz-mail-hour-' || v_tag, now(), true);
    perform erp_test.invitation_email_sent(v_org, 4, interval '20 minutes');
    v_q := erp_test.invitation_email_person(v_org, 'hour-fifth@' || v_tag || '.test');
    v_hour_fifth := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_org, 'hour-sixth@' || v_tag || '.test');
    v_hour_sixth := erp_test.invitation_email_answer(v_q, 'invite', null);
    select v_refused_rows + count(*) into v_refused_rows
      from erp.invitation_email_log l where l.app_user_id = v_q;

    -- A month old and never live: five this hour.
    v_org := erp_test.invitation_email_organisation('zz-mail-parked-' || v_tag, now() - interval '30 days', false);
    perform erp_test.invitation_email_sent(v_org, 5, interval '20 minutes');
    v_q := erp_test.invitation_email_person(v_org, 'parked-sixth@' || v_tag || '.test');
    v_parked_sixth := erp_test.invitation_email_answer(v_q, 'invite', null);

    -- New and not live: nine earlier today, then ten.
    v_org := erp_test.invitation_email_organisation('zz-mail-day-' || v_tag, now(), false);
    perform erp_test.invitation_email_sent(v_org, 9, interval '3 hours');
    v_q := erp_test.invitation_email_person(v_org, 'day-tenth@' || v_tag || '.test');
    v_day_tenth := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_org, 'day-eleventh@' || v_tag || '.test');
    v_day_eleventh := erp_test.invitation_email_answer(v_q, 'invite', null);

    -- Live for a month: nineteen this hour, then twenty.
    v_org := erp_test.invitation_email_organisation('zz-mail-thour-' || v_tag, now() - interval '30 days', true);
    perform erp_test.invitation_email_sent(v_org, 19, interval '20 minutes');
    v_q := erp_test.invitation_email_person(v_org, 'thour-twentieth@' || v_tag || '.test');
    v_t_twentieth := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_org, 'thour-next@' || v_tag || '.test');
    v_t_next_hour := erp_test.invitation_email_answer(v_q, 'invite', null);

    -- Live for a month: forty-nine earlier today, then fifty.
    v_org := erp_test.invitation_email_organisation('zz-mail-tday-' || v_tag, now() - interval '30 days', true);
    perform erp_test.invitation_email_sent(v_org, 49, interval '3 hours');
    v_q := erp_test.invitation_email_person(v_org, 'tday-fiftieth@' || v_tag || '.test');
    v_t_fiftieth := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_org, 'tday-next@' || v_tag || '.test');
    v_t_next_day := erp_test.invitation_email_answer(v_q, 'invite', null);

    -- ── One person sending, across their organisations ────────────────────────
    -- A member of two new organisations: three this hour from one and one from
    -- the other, then four and two.
    v_org := erp_test.invitation_email_organisation('zz-mail-c1a-' || v_tag, now(), false);
    v_other := erp_test.invitation_email_organisation('zz-mail-c1b-' || v_tag, now(), false);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_org, v_s1, 'person', 'active', 'Sender one', 'sender-one@' || v_tag || '.test'),
           (v_other, v_s1, 'person', 'active', 'Sender one', 'sender-one@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_org, 3, interval '20 minutes');
    perform erp_test.invitation_email_sent(v_other, 1, interval '20 minutes');
    v_q := erp_test.invitation_email_person(v_other, 'you-fifth@' || v_tag || '.test');
    v_you_fifth := erp_test.invitation_email_answer(v_q, 'invite', v_s1);
    v_q := erp_test.invitation_email_person(v_other, 'you-sixth@' || v_tag || '.test');
    v_you_sixth := erp_test.invitation_email_answer(v_q, 'invite', v_s1);

    -- Five this hour from one organisation, and then the same sign-in is a
    -- member of a second, new one that has sent nothing.
    v_org := erp_test.invitation_email_organisation('zz-mail-c2a-' || v_tag, now(), false);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_org, v_s2, 'person', 'active', 'Sender two', 'sender-two@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_org, 5, interval '20 minutes');
    v_other := erp_test.invitation_email_organisation('zz-mail-c2b-' || v_tag, now(), false);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_other, v_s2, 'person', 'active', 'Sender two', 'sender-two@' || v_tag || '.test');
    v_q := erp_test.invitation_email_person(v_other, 'fresh-org@' || v_tag || '.test');
    v_second_org := erp_test.invitation_email_answer(v_q, 'invite', v_s2);

    -- Six earlier today from one and three from the other, then ten.
    v_org := erp_test.invitation_email_organisation('zz-mail-c3a-' || v_tag, now(), false);
    v_other := erp_test.invitation_email_organisation('zz-mail-c3b-' || v_tag, now(), false);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_org, v_s3, 'person', 'active', 'Sender three', 'sender-three@' || v_tag || '.test'),
           (v_other, v_s3, 'person', 'active', 'Sender three', 'sender-three@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_org, 6, interval '3 hours');
    perform erp_test.invitation_email_sent(v_other, 3, interval '3 hours');
    v_q := erp_test.invitation_email_person(v_other, 'you-tenth@' || v_tag || '.test');
    v_you_tenth := erp_test.invitation_email_answer(v_q, 'invite', v_s3);
    v_q := erp_test.invitation_email_person(v_other, 'you-eleventh@' || v_tag || '.test');
    v_you_eleventh := erp_test.invitation_email_answer(v_q, 'invite', v_s3);

    -- Sending from an organisation live for a month, five this hour, while also a
    -- member of a new one.
    v_org := erp_test.invitation_email_organisation('zz-mail-c4a-' || v_tag, now() - interval '30 days', true);
    v_other := erp_test.invitation_email_organisation('zz-mail-c4b-' || v_tag, now(), false);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_org, v_s4, 'person', 'active', 'Sender four', 'sender-four@' || v_tag || '.test'),
           (v_other, v_s4, 'person', 'active', 'Sender four', 'sender-four@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_org, 5, interval '20 minutes');
    v_q := erp_test.invitation_email_person(v_org, 'mixed@' || v_tag || '.test');
    v_mixed := erp_test.invitation_email_answer(v_q, 'invite', v_s4);

    -- A member only of an organisation live for a month: six this hour.
    v_org := erp_test.invitation_email_organisation('zz-mail-c5-' || v_tag, now() - interval '30 days', true);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_org, v_s5, 'person', 'active', 'Sender five', 'sender-five@' || v_tag || '.test');
    perform erp_test.invitation_email_sent(v_org, 6, interval '20 minutes');
    v_q := erp_test.invitation_email_person(v_org, 'all-trusted@' || v_tag || '.test');
    v_all_trusted := erp_test.invitation_email_answer(v_q, 'invite', v_s5);

    -- ── Every new organisation together ───────────────────────────────────────
    -- Whatever new organisations have sent today, made up to 199 by one of them;
    -- then another new organisation sends the two hundredth, and the next.
    select coalesce(sum(x.n), 0)::integer
      into v_base
      from (select l.tenant_id, count(*) as n
              from erp.invitation_email_log l
             where l.created_at > now() - interval '24 hours'
             group by l.tenant_id) x
      join erp.tenant t on t.id = x.tenant_id
     where not coalesce(erp.tenant_is_live(t.id) and t.created_at < now() - interval '7 days', false);
    v_fill := erp_test.invitation_email_organisation('zz-mail-fill-' || v_tag, now(), false);
    if v_base < 199 then
      perform erp_test.invitation_email_sent(v_fill, 199 - v_base, interval '2 hours');
    end if;
    v_org := erp_test.invitation_email_organisation('zz-mail-together-' || v_tag, now(), false);
    v_q := erp_test.invitation_email_person(v_org, 'together-last@' || v_tag || '.test');
    v_together_last := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_org, 'together-over@' || v_tag || '.test');
    v_together_over := erp_test.invitation_email_answer(v_q, 'invite', null);
    v_q := erp_test.invitation_email_person(v_trusted, 'together-trusted@' || v_tag || '.test');
    v_together_trusted := erp_test.invitation_email_answer(v_q, 'invite', null);

    -- ── The record stays as written ───────────────────────────────────────────
    begin
      update erp.invitation_email_log l set kind = 'resend' where l.app_user_id = v_p;
      v_update_msg := 'a sent email was rewritten';
    exception when others then
      v_update_msg := case when sqlerrm like '%APPEND_ONLY%' then null else left(sqlerrm, 120) end;
    end;
    begin
      delete from erp.invitation_email_log l where l.app_user_id = v_p;
      v_delete_msg := 'a sent email was removed';
    exception when others then
      v_delete_msg := case when sqlerrm like '%APPEND_ONLY%' then null else left(sqlerrm, 120) end;
    end;

    raise exception 'ZZ_BUDGET_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_BUDGET_SUITE_UNDO' then v_state := left(sqlerrm, 200); end if;
  end;

  case_name := 'an invitation the door has just made may be emailed, and exactly that email is recorded';
  passed := v_state is null and v_first = c_yes and v_logged = 1 and coalesce(v_logged_ok, false);
  detail := coalesce(v_state, format('%s; %s row(s) recorded, as claimed: %s',
                                     coalesce(v_first, 'no answer'), v_logged, coalesce(v_logged_ok::text, 'unknown')));
  return next;

  case_name := 'an invitation already redeemed is nothing to email, and a refused claim records nothing';
  passed := v_state is null and v_claimed = c_none and v_claimed_resend = c_none and v_refused_rows = 0;
  detail := coalesce(v_state, format('invite: %s; resend: %s; %s row(s) for refused claims',
                                     coalesce(v_claimed, 'no answer'), coalesce(v_claimed_resend, 'no answer'), v_refused_rows));
  return next;

  case_name := 'inviting the same person again and asking for a fresh link does not get round the ten minutes';
  passed := v_state is null and v_again_invite = c_gap and v_again_resend = c_gap;
  detail := coalesce(v_state, format('invited again: %s; fresh link: %s',
                                     coalesce(v_again_invite, 'no answer'), coalesce(v_again_resend, 'no answer')));
  return next;

  case_name := 'an address waits ten minutes: nine minutes after the last email is refused, eleven is allowed';
  passed := v_state is null and v_gap_nine = c_gap and v_gap_eleven = c_yes;
  detail := coalesce(v_state, format('nine: %s; eleven: %s', coalesce(v_gap_nine, 'no answer'), coalesce(v_gap_eleven, 'no answer')));
  return next;

  case_name := 'the same address invited from a second organisation is refused, however it is written';
  passed := v_state is null and v_shared_one = c_yes and v_shared_two = c_gap;
  detail := coalesce(v_state, format('first organisation: %s; second: %s',
                                     coalesce(v_shared_one, 'no answer'), coalesce(v_shared_two, 'no answer')));
  return next;

  case_name := 'an address has three invitation emails a day: the third goes, the fourth does not';
  passed := v_state is null and v_third = c_yes and v_fourth = c_address;
  detail := coalesce(v_state, format('third: %s; fourth: %s', coalesce(v_third, 'no answer'), coalesce(v_fourth, 'no answer')));
  return next;

  case_name := 'an invitation has five emails: the fifth goes, the sixth does not';
  passed := v_state is null and v_links_fifth = c_yes and v_links_sixth = c_links;
  detail := coalesce(v_state, format('fifth: %s; sixth: %s', coalesce(v_links_fifth, 'no answer'), coalesce(v_links_sixth, 'no answer')));
  return next;

  case_name := 'a new organisation may email five an hour: the fifth goes, the sixth does not';
  passed := v_state is null and v_hour_fifth = c_yes and v_hour_sixth = c_org_hour;
  detail := coalesce(v_state, format('fifth: %s; sixth: %s', coalesce(v_hour_fifth, 'no answer'), coalesce(v_hour_sixth, 'no answer')));
  return next;

  case_name := 'an organisation that has never gone live is held to five an hour however old it is';
  passed := v_state is null and v_parked_sixth = c_org_hour;
  detail := coalesce(v_state, format('sixth: %s', coalesce(v_parked_sixth, 'no answer')));
  return next;

  case_name := 'a new organisation may email ten a day: the tenth goes, the eleventh does not';
  passed := v_state is null and v_day_tenth = c_yes and v_day_eleventh = c_org_day;
  detail := coalesce(v_state, format('tenth: %s; eleventh: %s', coalesce(v_day_tenth, 'no answer'), coalesce(v_day_eleventh, 'no answer')));
  return next;

  case_name := 'an organisation live for more than a week may email twenty an hour: the twentieth goes, the next does not';
  passed := v_state is null and v_t_twentieth = c_yes and v_t_next_hour = c_org_hour;
  detail := coalesce(v_state, format('twentieth: %s; next: %s', coalesce(v_t_twentieth, 'no answer'), coalesce(v_t_next_hour, 'no answer')));
  return next;

  case_name := 'and fifty a day: the fiftieth goes, the next does not';
  passed := v_state is null and v_t_fiftieth = c_yes and v_t_next_day = c_org_day;
  detail := coalesce(v_state, format('fiftieth: %s; next: %s', coalesce(v_t_fiftieth, 'no answer'), coalesce(v_t_next_day, 'no answer')));
  return next;

  case_name := 'a person sending from two organisations is counted across both: the fifth this hour goes, the sixth does not';
  passed := v_state is null and v_you_fifth = c_yes and v_you_sixth = c_you_hour;
  detail := coalesce(v_state, format('fifth: %s; sixth: %s', coalesce(v_you_fifth, 'no answer'), coalesce(v_you_sixth, 'no answer')));
  return next;

  case_name := 'a second organisation for the same sign-in does not start the count again';
  passed := v_state is null and v_second_org = c_you_hour;
  detail := coalesce(v_state, format('first email from the second organisation: %s', coalesce(v_second_org, 'no answer')));
  return next;

  case_name := 'and ten a day across both: the tenth goes, the eleventh does not';
  passed := v_state is null and v_you_tenth = c_yes and v_you_eleventh = c_you_day;
  detail := coalesce(v_state, format('tenth: %s; eleventh: %s', coalesce(v_you_tenth, 'no answer'), coalesce(v_you_eleventh, 'no answer')));
  return next;

  case_name := 'a person also belonging to a new organisation is held to the smaller numbers where they send from an established one';
  passed := v_state is null and v_mixed = c_you_hour;
  detail := coalesce(v_state, format('sixth this hour: %s', coalesce(v_mixed, 'no answer')));
  return next;

  case_name := 'a person whose organisations are all established is held to the larger numbers';
  passed := v_state is null and v_all_trusted = c_yes;
  detail := coalesce(v_state, format('seventh this hour: %s', coalesce(v_all_trusted, 'no answer')));
  return next;

  case_name := 'new organisations together may email two hundred a day: the two hundredth goes, the next does not, and an established organisation still may';
  passed := v_state is null and v_base <= 199
            and v_together_last = c_yes and v_together_over = c_together and v_together_trusted = c_yes;
  detail := coalesce(v_state, format('%s already today; two hundredth: %s; next: %s; established: %s', v_base,
                                     coalesce(v_together_last, 'no answer'), coalesce(v_together_over, 'no answer'),
                                     coalesce(v_together_trusted, 'no answer')));
  return next;

  case_name := 'a recorded email cannot be rewritten or removed';
  passed := v_state is null and v_update_msg is null and v_delete_msg is null;
  detail := coalesce(v_state, concat_ws('; ', v_update_msg, v_delete_msg), 'update and delete refused');
  return next;

  -- What the inviter is shown is a plain sentence.
  v_reasons := concat_ws(' | ', substr(c_links, 8), substr(c_gap, 8), substr(c_address, 8), substr(c_org_hour, 8),
                         substr(c_org_day, 8), substr(c_you_hour, 8), substr(c_you_day, 8), substr(c_together, 8));
  case_name := 'every reason is a plain sentence with no internal words';
  passed := v_reasons !~* '(CLOVEERP|_|tenant|app user|principal|digest|token|null|claim)'
            and not exists (select 1 from unnest(array[c_links, c_gap, c_address, c_org_hour, c_org_day,
                                                        c_you_hour, c_you_day, c_together]) x
                             where substr(x, 8) !~ '^[A-Z].*\.$');
  detail := v_reasons;
  return next;

  -- 26-29 onboard as three sign-ins, and undo all of it.
  begin
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    insert into auth.users (id, email) values
      (v_first_sub, 'first-' || v_tag || '@zz-onboard.test'),
      (v_two_sub, 'two-' || v_tag || '@zz-onboard.test'),
      (v_one_sub, 'one-' || v_tag || '@zz-onboard.test');

    -- A sign-in with no organisation makes one, and a moment later asks again.
    perform set_config('request.jwt.claims', json_build_object('sub', v_first_sub)::text, true);
    v_onboarded := erp.onboard_tenant('Onboarding limit, first', 'zz-onboard-first-' || v_tag);
    begin
      perform erp.onboard_tenant('Onboarding limit, second', 'zz-onboard-second-' || v_tag);
      v_second_msg := 'a second organisation was made within the day';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      if sqlstate = '42501' and sqlerrm like 'CLOVEERP_ONBOARDING_LIMIT:%' and v_hint like 'Contact Clove ERP%' then
        v_second_msg := null;
      else
        v_second_msg := left(sqlerrm, 120);
      end if;
    end;
    select count(*) into v_second_made from erp.tenant t where t.code = 'zz-onboard-second-' || v_tag;

    -- A sign-in already in two organisations made days ago, neither live.
    perform set_config('request.jwt.claims', '', true);
    v_org := erp_test.invitation_email_organisation('zz-onboard-nl1-' || v_tag, now() - interval '3 days', false);
    v_other := erp_test.invitation_email_organisation('zz-onboard-nl2-' || v_tag, now() - interval '3 days', false);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_org, v_two_sub, 'person', 'active', 'Two organisations', 'two-' || v_tag || '@zz-onboard.test'),
           (v_other, v_two_sub, 'person', 'active', 'Two organisations', 'two-' || v_tag || '@zz-onboard.test');

    -- And one in a single organisation made days ago, not live.
    v_org := erp_test.invitation_email_organisation('zz-onboard-nl3-' || v_tag, now() - interval '3 days', false);
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (v_org, v_one_sub, 'person', 'active', 'One organisation', 'one-' || v_tag || '@zz-onboard.test');
    perform set_config('erp.job_tenant_id', '', true);

    perform set_config('request.jwt.claims', json_build_object('sub', v_two_sub)::text, true);
    begin
      perform erp.onboard_tenant('Onboarding limit, third', 'zz-onboard-third-' || v_tag);
      v_two_msg := 'a sign-in in two organisations that are not live made a third';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      if sqlstate = '42501' and sqlerrm like 'CLOVEERP_ONBOARDING_LIMIT:%' and v_hint like 'Contact Clove ERP%' then
        v_two_msg := null;
      else
        v_two_msg := left(sqlerrm, 120);
      end if;
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', v_one_sub)::text, true);
    v_one_made := erp.onboard_tenant('Onboarding limit, fourth', 'zz-onboard-fourth-' || v_tag);

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_BUDGET_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_BUDGET_SUITE_UNDO' then v_onboard_state := left(sqlerrm, 200); end if;
  end;

  case_name := 'a sign-in with no organisation still makes one';
  passed := v_onboard_state is null and (v_onboarded ->> 'tenant_id') is not null;
  detail := coalesce(v_onboard_state, coalesce(v_onboarded::text, 'nothing made'));
  return next;

  case_name := 'a sign-in that made an organisation in the last day cannot make another, and is told to contact Clove ERP';
  passed := v_onboard_state is null and v_second_msg is null and v_second_made = 0;
  detail := coalesce(v_onboard_state, v_second_msg, format('refused; %s organisation(s) made', v_second_made));
  return next;

  case_name := 'a sign-in in two organisations that are not live cannot make a third';
  passed := v_onboard_state is null and v_two_msg is null;
  detail := coalesce(v_onboard_state, v_two_msg, 'refused');
  return next;

  case_name := 'a sign-in in one older organisation that is not live may make another';
  passed := v_onboard_state is null and (v_one_made ->> 'tenant_id') is not null;
  detail := coalesce(v_onboard_state, coalesce(v_one_made::text, 'nothing made'));
  return next;

  case_name := 'the onboarding refusal is registered with its next action';
  passed := exists (select 1 from erp_ref.refusal f
                     where f.code = 'CLOVEERP_ONBOARDING_LIMIT'
                       and f.next_action = 'Contact Clove ERP to add another organisation.')
            and exists (select 1 from erp_ref.resource r
                         where r.locale = 'en'
                           and r.key = erp_ref.refusal_key('CLOVEERP_ONBOARDING_LIMIT', 'next_action'));
  detail := 'CLOVEERP_ONBOARDING_LIMIT';
  return next;
end;
$$;
revoke all on function erp_test.invitation_email_budget_suite() from public, anon, authenticated;

create or replace function erp_test.assert_invitation_email_budget_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 30;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _invitation_email_budget on commit drop as
    select * from erp_test.invitation_email_budget_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _invitation_email_budget;
  drop table _invitation_email_budget;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INVITATION_EMAIL_BUDGET_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_INVITATION_EMAIL_BUDGET_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('invitation email budget: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_invitation_email_budget_suite() from public, anon, authenticated;

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
  v_n8           uuid;
  v_with_pass    integer;
  v_with_pass_status text;
  v_rows         integer;
  v_orgs         integer;
  v_mine         integer;
  v_tenants      integer;
  v_waited_status text;
  v_ctx_before   text;
  v_ctx_after    text;
  v_inc_before   uuid;
  v_inc_resolved uuid;
  v_inc_now      uuid;
  v_up_after     uuid;
  v_told_update  integer;
  v_told_declared integer;
  v_told_total   integer;
  v_told         jsonb;
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

  -- 3. So does retiring in every organisation.
  v_ok := false; v_msg := null;
  begin
    execute 'grant execute on function erp.retire_undrained_notifications_everywhere() to authenticated';
    execute 'set local role authenticated';
    perform 1 from erp.retire_undrained_notifications_everywhere();
    v_msg := 'with execute granted, a signed-in session retired queued messages in every organisation';
    raise exception 'ZZ_BOUNDARY_SUITE_UNDO';
  exception when others then
    execute 'reset role';
    if sqlerrm <> 'ZZ_BOUNDARY_SUITE_UNDO' then
      v_ok := sqlstate = '42501' and sqlerrm like 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION:%';
      v_msg := left(sqlerrm, 120);
    end if;
  end;
  case_name := 'granted execute by mistake, retiring in every organisation still refuses a signed-in session itself';
  passed := v_ok; detail := v_msg;
  return next;

  -- 4.
  select bool_and(not p.prosecdef) into v_ok
    from pg_catalog.pg_proc p
   where p.oid in ('erp.retire_undrained_notifications()'::regprocedure,
                   'erp.retire_undrained_notifications_everywhere()'::regprocedure);
  case_name := 'both retirements'' trust tests run in the caller''s frame';
  passed := coalesce(v_ok, false);
  detail := case when v_ok then 'security invoker' else 'security definer: the test would see the owner' end;
  return next;

  -- 5-21 build an organisation, act in it, and undo all of it.
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

    -- ── Retiring whenever draining first starts ───────────────────────────────
    -- A message that waited three hours. With a drain pass on record, retiring
    -- everywhere does nothing; with none, it retires it, names every
    -- organisation once, and leaves the session's own context as it was.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, created_at)
    values (r.tenant_id, 'high', r.admin_user_id, 'email', 'Boundary: waited', 'Queued while nothing drained.', 'queued', now() - interval '3 hours')
    returning id into v_n8;
    perform erp.record_drain_pass('zz-boundary-suite', now(), '{}'::jsonb);
    select count(*) into v_with_pass from erp.retire_undrained_notifications_everywhere();
    select n.status into v_with_pass_status from erp.notification n where n.id = v_n8;

    delete from erp_meta.drain_pass;
    v_ctx_before := concat_ws('|', current_setting('erp.job_tenant_id', true), current_setting('request.jwt.claims', true));
    select count(*), count(distinct e.tenant_code), coalesce(max(e.retired) filter (where e.tenant_code = v_code), -1)
      into v_rows, v_orgs, v_mine
      from erp.retire_undrained_notifications_everywhere() e;
    v_ctx_after := concat_ws('|', current_setting('erp.job_tenant_id', true), current_setting('request.jwt.claims', true));
    select count(*) into v_tenants from erp.tenant;
    select n.status into v_waited_status from erp.notification n where n.id = v_n8;

    -- ── Incident notices from before the organisation existed ─────────────────
    -- This organisation was made at the start of this transaction. An incident
    -- declared two days ago and still open, with an update from yesterday and
    -- one from now; one declared three days ago and resolved yesterday, with a
    -- note from now; and one declared now.
    insert into erp_meta.incident (code, severity_code, title, commander, communications_owner, scribe,
                                   scope, affects_all_tenants, declared_at, created_at)
    values ('zz-bound-open-' || v_code, 'sev2', 'Boundary: declared before', 'A. Commander', 'Comms Owner', 'C. Scribe',
            'Every organisation', true, now() - interval '2 days', now() - interval '2 days')
    returning id into v_inc_before;
    insert into erp_meta.incident_update (incident_id, posted_at, body, posted_by)
    values (v_inc_before, now() - interval '1 day', 'Boundary: posted before the organisation existed.', 'Comms Owner');
    insert into erp_meta.incident_update (incident_id, posted_at, body, posted_by)
    values (v_inc_before, now(), 'Boundary: posted once the organisation existed.', 'Comms Owner')
    returning id into v_up_after;
    insert into erp_meta.incident (code, severity_code, title, commander, communications_owner, scribe,
                                   scope, affects_all_tenants, declared_at, created_at, resolved_at)
    values ('zz-bound-resolved-' || v_code, 'sev3', 'Boundary: resolved before', 'A. Commander', 'Comms Owner', 'C. Scribe',
            'Every organisation', true, now() - interval '3 days', now() - interval '3 days', now() - interval '1 day')
    returning id into v_inc_resolved;
    insert into erp_meta.incident_update (incident_id, posted_at, body, posted_by)
    values (v_inc_resolved, now(), 'Boundary: a note on an incident resolved before the organisation existed.', 'Comms Owner');
    insert into erp_meta.incident (code, severity_code, title, commander, communications_owner, scribe,
                                   scope, affects_all_tenants, declared_at, created_at)
    values ('zz-bound-now-' || v_code, 'sev2', 'Boundary: declared now', 'A. Commander', 'Comms Owner', 'C. Scribe',
            'Every organisation', true, now(), now())
    returning id into v_inc_now;

    perform set_config('request.jwt.claims', '', true);
    perform erp.set_job_tenant(r.tenant_id);
    v_told := erp.communicate_incidents();
    select count(*) filter (where d.incident_id = v_inc_before and d.incident_update_id = v_up_after),
           count(*) filter (where d.incident_id = v_inc_now and d.incident_update_id is null),
           count(*)
      into v_told_update, v_told_declared, v_told_total
      from erp_meta.incident_delivery d
     where d.tenant_id = r.tenant_id
       and d.incident_id in (v_inc_before, v_inc_resolved, v_inc_now);

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
  detail := coalesce(v_state, format('zzreclaim on file: %s', coalesce(v_sql_job::text, 'unknown')));
  return next;

  case_name := 'a job acting for an organisation that is not the platform''s cannot record a provider''s feed';
  passed := v_state is null and v_feed_msg is null and v_feed_rows = 0;
  detail := coalesce(v_state, v_feed_msg, format('refused; %s observation(s)', v_feed_rows));
  return next;

  case_name := 'the platform''s organisation schedules the feed and records it, and so does the sweep that acts for none';
  passed := v_state is null and coalesce(v_platform_job, false) and v_platform_obs = 1 and v_sweep_obs = 2;
  detail := coalesce(v_state, format('job on file %s; observations %s then %s', coalesce(v_platform_job::text, 'unknown'), v_platform_obs, v_sweep_obs));
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

  case_name := 'once a drain pass is on record, retiring in every organisation does nothing and names none';
  passed := v_state is null and v_with_pass = 0 and v_with_pass_status = 'queued';
  detail := coalesce(v_state, format('%s organisation(s) named; the waiting message is %s', v_with_pass, coalesce(v_with_pass_status, 'gone')));
  return next;

  case_name := 'with no drain pass on record, it names every organisation once, retires what waited, and leaves the session as it was';
  passed := v_state is null
            and v_rows = v_tenants and v_orgs = v_tenants and v_mine = 1
            and v_waited_status = 'suppressed'
            and v_ctx_after is not distinct from v_ctx_before;
  detail := coalesce(v_state, format('%s row(s) for %s organisation(s) (%s distinct); this one retired %s; the waiting message is %s; context %s',
                                     v_rows, v_tenants, v_orgs, v_mine, coalesce(v_waited_status, 'gone'),
                                     case when v_ctx_after is not distinct from v_ctx_before then 'kept' else 'changed' end));
  return next;

  case_name := 'an organisation is told only what was posted after it existed, and nothing about an incident resolved before then';
  passed := v_state is null and v_told_update = 1 and v_told_declared = 1 and v_told_total = 2;
  detail := coalesce(v_state, format('update after it existed %s, declaration after %s, %s notice(s) in all: %s',
                                     v_told_update, v_told_declared, v_told_total, coalesce(v_told::text, 'no answer')));
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
  c_expected constant integer := 21;
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
-- 11. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- The channel form's words, and the refusal the onboarding door gained.
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();

select erp_test.assert_dispatch_bindings_suite();
select erp_test.assert_invitation_for_resend_suite();
select erp_test.assert_invitation_email_budget_suite();
select erp_test.assert_drain_boundaries_suite();
-- Restated here, or reading what changed under them: the webhook suite's
-- credential, the superadmin suite's worker-only job, and the incident sweep
-- and the dependency feed the incident suite records.
select erp_test.assert_webhook_delivery_suite();
select erp_test.assert_queued_run_suite();
select erp_test.assert_superadmin_suite();
select erp_test.assert_incident_communication_suite();

-- The new log is a tenant table like every other: attributed, isolated, and its
-- address said out loud in the personal-data register.
select erp.assert_attribution_coverage();
select erp.assert_personal_data_register_sound();
select erp.assert_isolation();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_session_context_hygiene();
-- No public function is created here; the allowance row a public door is judged
-- by changed wording, and the doors that reach erp.upsert_job(),
-- erp.upsert_notification_channel() and erp.onboard_tenant() reach new
-- refusals, so the judge reads them again.
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
