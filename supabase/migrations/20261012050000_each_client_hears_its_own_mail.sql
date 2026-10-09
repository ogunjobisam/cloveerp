set lock_timeout = '30s';

-- =============================================================================
-- 20261012050000  Each client hears its own mail
-- -----------------------------------------------------------------------------
-- The email provider tells a database what became of each message it sent
-- (delivered, delayed, opened, bounced, complained about) by posting to a
-- webhook endpoint: the resend_webhook function of that database's own
-- project, which hands the one event to erp.record_email_delivery_event().
-- From this pull request every client's project, the demonstration's and the
-- control plane's each get an endpoint of their own, made and proved by the
-- build (supabase/ci/provision_project.sh resend-webhook, the build from
-- empty, and fleet_secrets.yml for the deployments already running) once the
-- workflows hold the provider's admin key. The provider tells every endpoint
-- of an account about every message the account sent, so each endpoint hears
-- the whole fleet's mail. This is the database's half, and it ships first: on
-- its own it stops one client keeping another's recipients.
--
--   A. A database keeps only its own mail. erp.record_email_delivery_event
--      now records nothing about a message this database did not send. An
--      event that matches no commercial email, notification, organisation's
--      document email, invitation email or enquiry notice of its own answers
--      {recorded: false, matched: 'nothing', reason} and writes no event, no
--      suppression and no audit row, so the address it names is kept
--      nowhere. Until now such
--      an event was kept with its recipient's address, and a permanent bounce
--      or a complaint about another's message also stopped the platform
--      writing to that address and was audited. A permanent bounce or a
--      complaint now stops an address only when it is about a message this
--      database sent. What a matched event does is unchanged, and so is the
--      answer to an event told twice.
--
--      Two kinds of this database's own mail kept no id until now, and would
--      have read as another's. An invitation email (the invite function)
--      takes its place in the sending limits before it goes, and its row in
--      erp.invitation_email_log is append-only, so the provider's id is kept
--      beside it: erp.invitation_email_message, one row per log row, written
--      once by erp.record_invitation_email_sent() over the invite function's
--      own connection right after the provider took the message. An event
--      about it is matched as 'invitation', and a permanent bounce or a
--      complaint suppresses the address in the organisation that invited.
--      An enquiry notice that reached some of the staff and then failed kept
--      no id either: erp.fail_enquiry_notice() now keeps the ids of the
--      messages that were taken, as erp.complete_enquiry_notice() keeps all
--      of them. Each id is stored a moment after the provider took the
--      message, so an event the provider sends in that moment (a "sent",
--      seconds after) finds nothing yet and is not kept. That is accepted:
--      the window is seconds wide, and the delivery, bounce or complaint that
--      matters comes later.
--
--   B. The build ticks what it did. The checklist of a client deployment
--      (20261011020000) holds the steps set up on its own project after its
--      build, and the email provider's webhook is now set up by the build.
--      erp_meta.deployment_checklist_by_build(code, item, done) marks the
--      webhook done by "the build", with the time, and records the step in
--      the deployment's events; told again it changes nothing. The build
--      ticks only the webhook, only on the control plane, and only for a
--      deployment that has a project and is not failed, being offboarded or
--      retired. Told done = false it unticks the step, as "the build", once
--      it has deleted the endpoint or left none, in any state: deleting a
--      leaving client's endpoint is when that happens most. A person can
--      still untick it from the Fleet view, and the next run of the build or
--      of the fleet's secrets workflow that finds the endpoint ticks it
--      again. The Fleet view reads the checklist as it is, so the step reads
--      {done: true, at, by: 'the build'} there, and the console says "set by
--      the build". Trusted build role only.
--
--   C. The fleet's workflows name three targets of their own beside a
--      client's code: all, control and demonstration. No client deployment
--      or organisation may take one as its code from here. No deployment
--      this was written against holds one, and this migration stops, saying
--      which, if a client deployment does; an organisation that holds one
--      keeps it, as with every reserved word.
--
--   D. The proof: erp_test.email_tracking_suite has fifteen cases now, six of
--      them new (another database's mail of every type is not kept; a
--      permanent bounce or a complaint about it stops nothing here, even for
--      an address this database writes to; an enquiry notice's event is still
--      kept; so is one from a notice that failed part-way, which keeps the
--      ids of the messages taken; the invite function records the provider's
--      id for the email it sent and nothing else; an invitation's permanent
--      bounce and complaint are kept and suppress the address in the
--      organisation that invited), and
--      erp_test.deployment_checklist_by_build_suite (nine cases) proves B and
--      C, each with its assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No permission code and no public door's signature. One table is added
-- (erp.invitation_email_message), and the contact form's
-- erp_ingress.fail_enquiry_notice takes a third argument that may be left
-- out, so the enquiry function deployed before this release calls it as it
-- always did. The events, suppressions and audit rows already kept are left
-- as they are: which of them came from another database's mail is for the
-- owner to decide, not for a migration to guess. Sign-in emails sent by the
-- project's own mail (Supabase Auth over SMTP) have no message of ours behind
-- them, so their bounces are not kept either: that is the price of each
-- database keeping only its own mail. Nothing here talks to the email
-- provider: the endpoints, their signing secrets and the vault are the
-- scripts' and the workflows'.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The refusal the build may meet
-- ─────────────────────────────────────────────────────────────────────────────

-- The checklist's refusal said both steps were a person's; the webhook is the
-- build's now, so its reason says who ticks what, and the build is refused a
-- step it does not set up in the same words.
select erp.register_refusal(
  'CLOVEERP_CHECKLIST_ITEM_UNKNOWN',
  'Ticking a step of a deployment''s checklist that the checklist does not have, or that the build does not set up.',
  'The checklist holds the two steps set up on a client''s own project after its build: Google sign-in, if the '
  'client wants it, which a person sets up and ticks, and the email provider''s webhook, which the build sets up '
  'and ticks itself when it holds the provider''s admin key. A person ticks what they did, and the build ticks '
  'only the webhook.',
  'Tick one of the two steps the Fleet view lists: Google sign-in, or the email provider''s webhook.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A database keeps only its own mail
-- ─────────────────────────────────────────────────────────────────────────────

-- The bodies this migration was written against. The two fail_enquiry_notice
-- routines of two arguments are replaced by ones of three, so a database this
-- migration has run on has neither, and there is nothing left to compare.
do $$
declare
  r record;
begin
  for r in
    select x.sig, x.anchor, x.replaced
      from (values
        ('erp.record_email_delivery_event(text,text,text,text,timestamptz,text,text,text)',
         '4ddecdda4785308869e2fc56062ea340', false),
        ('erp_test.email_tracking_suite()', '8b2e0f9c0a87aba2cc2d467a06f68e56', false),
        ('erp_test.assert_email_tracking_suite()', 'a29c1b5d872332ac84718461c0bbd20a', false),
        ('erp.fail_enquiry_notice(uuid,text)', 'ecd002ce278ff8d80669bbae1519a8dd', true),
        ('erp_ingress.fail_enquiry_notice(uuid,text)', 'd368c6377ac20432940b06c412013a37', true)
      ) as x(sig, anchor, replaced)
  loop
    if r.replaced and pg_catalog.to_regprocedure(r.sig) is null then
      continue;
    end if;
    if (select strpos(p.prosrc, '20261012050000') = 0 and md5(p.prosrc) <> r.anchor
          from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure) then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
  end loop;
end
$$;

-- An invitation email is this database's mail. Its row in
-- erp.invitation_email_log is written when the email is allowed, before it
-- goes (erp.claim_invitation_email, 20260913120000), and the sending limits
-- are counted from those rows, so the table is append-only and no role may
-- change a row of it. The provider's id for the message is known only once
-- the provider took it, so it is kept beside the row it belongs to, once.
create table if not exists erp.invitation_email_message (
  -- The invitation email the message is. One message each.
  log_id              uuid primary key references erp.invitation_email_log (id) on delete cascade,
  tenant_id           uuid not null references erp.tenant (id) on delete cascade,
  -- What the provider called the message: what its events name.
  provider_message_id text not null,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  constraint invitation_email_message_once unique (provider_message_id),
  constraint invitation_email_message_named
    check (provider_message_id = btrim(provider_message_id) and provider_message_id <> ''
           and length(provider_message_id) <= 200)
);

create index if not exists invitation_email_message_tenant_idx
  on erp.invitation_email_message (tenant_id, created_at);

comment on table erp.invitation_email_message is
  'The email provider''s id for each invitation email it took, beside the row of erp.invitation_email_log that '
  'allowed the email: written once by erp.record_invitation_email_sent() right after the provider took it, so an '
  'event about the message is matched to the organisation that invited (20261012050000). Append-only.';

select erp_meta.register_table('erp', 'invitation_email_message', 'tenant_scoped_append_only',
  'The email provider''s id for each invitation email it took, one row per invitation email.');

-- The invite function records what the provider called the message, over its
-- own connection, right after the provider took it.
create or replace function erp.record_invitation_email_sent(p_app_user_id uuid, p_kind text,
                                                            p_provider_message_id text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_message text := nullif(btrim(coalesce(p_provider_message_id, '')), '');
  v_log     erp.invitation_email_log;
  v_kept    integer;
begin
  -- Nobody signed in tells the product what the provider called a message.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record an invitation email''s message', current_user
      using errcode = '42501',
            hint = 'The invite function records it over its own database connection once the provider has taken the message; nobody signed in does.';
  end if;
  if p_kind is null or p_kind not in ('invite', 'resend') then
    raise exception 'CLOVEERP_INVITATION_EMAIL_KIND_UNKNOWN: % is not a kind of invitation email', coalesce(p_kind, 'null')
      using errcode = '22023',
            hint = 'Record the message with the kind its email was claimed with: invite, or resend.';
  end if;
  if v_message is null then
    return jsonb_build_object('recorded', false, 'reason', 'the provider named no message');
  end if;

  -- The email the claim allowed: this person's newest invitation email of
  -- that kind that has no message yet. The claim and the send are seconds
  -- apart, so one claimed more than an hour ago is a send that never
  -- happened, and is left alone.
  select l.* into v_log
    from erp.invitation_email_log l
   where l.app_user_id = p_app_user_id
     and l.kind = p_kind
     and l.created_at > now() - interval '1 hour'
     and not exists (select 1 from erp.invitation_email_message m where m.log_id = l.id)
   order by l.created_at desc, l.id desc
   limit 1;
  if not found then
    return jsonb_build_object('recorded', false,
                              'reason', 'no invitation email of that kind is waiting for its message');
  end if;

  -- The organisation that invited is the one the row is written in.
  perform erp.set_job_tenant(v_log.tenant_id);
  insert into erp.invitation_email_message (log_id, tenant_id, provider_message_id)
  values (v_log.id, v_log.tenant_id, v_message)
  on conflict do nothing;
  get diagnostics v_kept = row_count;
  if v_kept = 0 then
    return jsonb_build_object('recorded', false, 'reason', 'that message was recorded already');
  end if;
  return jsonb_build_object('recorded', true, 'kind', v_log.kind, 'claimed_at', v_log.created_at);
end;
$$;

revoke all on function erp.record_invitation_email_sent(uuid, text, text)
  from public, anon, authenticated, service_role;

comment on function erp.record_invitation_email_sent(uuid, text, text) is
  'Called by the invite function, over its own connection, right after the email provider took an invitation email '
  'or a fresh sign-in link: keeps the provider''s id for it beside the newest row of erp.invitation_email_log for that '
  'person and kind, claimed within the hour, that has none, so an event about the message is this database''s. '
  'Answers {recorded: true} or {recorded: false, reason} and never refuses for want of a row: the invitation stands '
  'either way. Trusted sessions only (20261012050000).';

-- An event names the queue it was matched to; an invitation email is one now.
alter table erp_meta.email_delivery_event drop constraint if exists email_delivery_event_matched_known;
alter table erp_meta.email_delivery_event add constraint email_delivery_event_matched_known
  check (matched in ('nothing', 'commercial_email', 'notification', 'enquiry', 'document_email', 'invitation'));

create or replace function erp.record_email_delivery_event(p_event_id text, p_event_type text, p_state text,
                                                           p_provider_message_id text,
                                                           p_occurred_at timestamptz default null,
                                                           p_recipient text default null,
                                                           p_bounce_kind text default null,
                                                           p_detail text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_event    text := nullif(btrim(coalesce(p_event_id, '')), '');
  v_message  text := nullif(btrim(coalesce(p_provider_message_id, '')), '');
  v_state    text := nullif(lower(btrim(coalesce(p_state, ''))), '');
  v_when     timestamptz := coalesce(p_occurred_at, now());
  v_address  text := lower(nullif(btrim(coalesce(p_recipient, '')), ''));
  v_detail   text := left(nullif(btrim(concat_ws(': ', nullif(btrim(coalesce(p_bounce_kind, '')), ''),
                                                 nullif(btrim(coalesce(p_detail, '')), ''))), ''), 300);
  v_platform uuid;
  v_ce       erp_meta.commercial_email;
  v_note     erp.notification;
  -- A document an organisation sent (20261004920000).
  v_doc      erp.document_email;
  v_matched  text := 'nothing';
  v_tenant   uuid;
  v_moved    boolean := false;
  v_suppress text;
  v_suppressed boolean := false;
  v_id       uuid;
begin
  -- The webhook endpoint calls this over the drain's own connection. Nobody
  -- signed in tells the product that a message was delivered.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record delivery events', current_user
      using errcode = '42501', hint = 'The webhook endpoint records these over its own connection; nobody signed in does.';
  end if;
  if v_event is null or nullif(btrim(coalesce(p_event_type, '')), '') is null then
    raise exception 'CLOVEERP_EMAIL_EVENT_UNIDENTIFIED: an event with no id and type is not an event'
      using errcode = '22023', hint = 'The provider sends both; a request without them is refused before it reaches here.';
  end if;

  select po.tenant_id into v_platform from erp_meta.platform_organisation po;

  -- Which message it is about. The provider's id is what we stored when the
  -- message left, on whichever queue sent it.
  if v_message is not null then
    select * into v_ce from erp_meta.commercial_email ce
     where ce.provider_message_id = v_message
     order by ce.sent_at desc nulls last limit 1;
    if found then
      v_matched := 'commercial_email';
      v_tenant := v_ce.tenant_id;
    else
      select * into v_note from erp.notification n
       where n.provider_message_id = v_message
       order by n.sent_at desc nulls last limit 1;
      if found then
        v_matched := 'notification';
        v_tenant := v_note.tenant_id;
      else
        select * into v_doc from erp.document_email m
         where m.provider_message_id = v_message
         order by m.sent_at desc nulls last limit 1;
        if found then
          v_matched := 'document_email';
          v_tenant := v_doc.tenant_id;
        else
          -- An invitation email the invite function sent, whose id it kept
          -- beside the row that allowed it. Nothing on it moves; the event
          -- is the record, in the organisation that invited (20261012050000).
          select m.tenant_id into v_tenant from erp.invitation_email_message m
           where m.provider_message_id = v_message;
          if found then
            v_matched := 'invitation';
          end if;
        end if;
      end if;
      if v_matched <> 'nothing' then
        null;
      elsif exists (select 1 from erp_meta.enquiry e
                     where v_message = any (string_to_array(coalesce(e.provider_message_id, ''), ','))) then
        -- An enquiry notice goes to staff, and its row records the ids of every
        -- message it sent, or of every one that was taken before it failed
        -- (20261012050000). Nothing on it moves; the event is the record.
        v_matched := 'enquiry';
      end if;
    end if;
  end if;

  -- Every endpoint of the provider's account is told of every message the
  -- account sent, and each client's project, the demonstration's and the
  -- control plane's has an endpoint of its own, so most of what reaches this
  -- one is another database's mail. An event about no message this database
  -- sent is not this database's to keep: no event, no suppression and no
  -- audit, and the address it names is written nowhere. Answered, not
  -- refused: the provider is not to send it again (20261012050000).
  if v_matched = 'nothing' then
    return jsonb_build_object('recorded', false, 'matched', v_matched,
                              'reason', 'that event is about no message this database sent');
  end if;

  -- Recorded once. A replay changes nothing and is not an error: the provider
  -- retries what it is not sure we heard.
  insert into erp_meta.email_delivery_event
    (event_id, event_type, state, provider_message_id, occurred_at, to_address, bounce_kind, detail,
     matched, commercial_email_id, notification_id, tenant_id)
  values (v_event, left(btrim(p_event_type), 100), v_state, v_message, v_when, v_address,
          nullif(btrim(coalesce(p_bounce_kind, '')), ''), left(nullif(btrim(coalesce(p_detail, '')), ''), 500),
          v_matched, v_ce.id, v_note.id, v_tenant)
  on conflict on constraint email_delivery_event_once do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('recorded', false, 'reason', 'that event was recorded already',
                              'matched', v_matched);
  end if;

  -- The message's own state, when this event moves it forward.
  if v_state is not null and v_matched = 'commercial_email' then
    update erp_meta.commercial_email ce
       set delivery_state = v_state, delivery_state_at = v_when,
           delivery_detail = coalesce(v_detail, ce.delivery_detail)
     where ce.id = v_ce.id
       and erp.email_delivery_rank(v_state) > erp.email_delivery_rank(ce.delivery_state);
    v_moved := found;
  elsif v_state is not null and v_matched = 'document_email' then
    update erp.document_email m
       set delivery_state = v_state, delivery_state_at = v_when,
           delivery_detail = coalesce(v_detail, m.delivery_detail), updated_at = now()
     where m.id = v_doc.id
       and erp.email_delivery_rank(v_state) > erp.email_delivery_rank(m.delivery_state);
    v_moved := found;
  elsif v_state is not null and v_matched = 'notification' then
    update erp.notification n
       set delivery_state = v_state, delivery_state_at = v_when,
           -- The tenant's own screens read status and delivered_at, and have
           -- since before there was a webhook to write them.
           delivered_at = case when v_state in ('delivered', 'opened') then coalesce(n.delivered_at, v_when)
                               else n.delivered_at end,
           status = case when v_state in ('delivered', 'opened') and n.status = 'sent' then 'delivered'
                         when v_state in ('bounced', 'complained') and n.status in ('sent', 'delivered') then 'failed'
                         else n.status end,
           failure_reason = case when v_state in ('bounced', 'complained')
                                 then left(concat_ws(': ', 'the provider could not deliver it', v_detail), 500)
                                 else n.failure_reason end
     where n.id = v_note.id
       and erp.email_delivery_rank(v_state) > erp.email_delivery_rank(n.delivery_state);
    v_moved := found;
  end if;

  -- A permanent bounce or a complaint stops this address being written to
  -- again, by the organisation that wrote to it. A temporary bounce does not:
  -- the mailbox may be full today and empty tomorrow. Only a message this
  -- database sent reaches here (20261012050000).
  if v_address is not null and v_state in ('bounced', 'complained')
     and (v_state = 'complained' or erp.email_bounce_is_permanent(p_bounce_kind)) then
    v_suppress := case when v_state = 'complained' then 'complaint' else 'hard_bounce' end;
    -- The organisation that wrote to it stops writing to it: for an
    -- invitation, the organisation that invited (20261012050000).
    v_tenant := case when v_matched in ('notification', 'document_email', 'invitation') then v_tenant
                     else v_platform end;
    if v_tenant is not null then
      insert into erp.email_suppression (tenant_id, address, reason, is_permanent, note)
      values (v_tenant, v_address, v_suppress, true,
              left(concat_ws(': ', 'the provider reported a ' || v_suppress, v_detail), 500))
      on conflict (tenant_id, address) do update
        set reason = excluded.reason, is_permanent = true,
            note = coalesce(excluded.note, erp.email_suppression.note);
      v_suppressed := true;
      -- The event says what it did, so the console can show the bounce and the
      -- fact that it stopped the address in one line.
      update erp_meta.email_delivery_event ev set suppressed = true where ev.id = v_id;
    end if;
  end if;

  -- What a person must see: a message that did not arrive, and an address the
  -- product has stopped writing to. The whole history is the event table.
  if v_state in ('bounced', 'complained') then
    insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, target, reason, detail)
    values ('the email provider', 'system', 'platform.email_' || v_state, v_tenant, v_message,
            coalesce(v_detail, p_event_type),
            jsonb_build_object('event_id', v_event, 'matched', v_matched, 'address', v_address,
                               'suppressed', v_suppressed));
  end if;

  return jsonb_build_object('recorded', true, 'matched', v_matched, 'state', v_state,
                            'moved', v_moved, 'suppressed', v_suppressed);
end;
$$;

revoke all on function erp.record_email_delivery_event(text, text, text, text, timestamptz, text, text, text)
  from public, anon, authenticated, service_role;

comment on function erp.record_email_delivery_event(text, text, text, text, timestamptz, text, text, text) is
  'Records one delivery event from the email provider about a message this database sent: once per event id, '
  'matched to the commercial email, notification, organisation''s document email, invitation email or enquiry '
  'notice it names, moving that message''s delivery state forward only. A permanent bounce or a complaint '
  'suppresses the address for the organisation that wrote to it (for an invitation, the organisation that invited), '
  'and is audited. An event about no message this database sent (every endpoint hears the whole account''s mail) '
  'answers {recorded: false, matched: nothing, reason} and writes no event, no suppression and no audit. Trusted '
  'sessions only: the webhook endpoint calls it (20260915070000, 20261004920000, 20261012050000).';

-- An enquiry notice that reached some of the staff and then failed keeps the
-- ids of the messages that were taken, as a completed one keeps all of them,
-- so the events about them are this database's. The third argument may be
-- left out: the enquiry function deployed before this release calls the
-- wrapper with two, and is answered as before.
drop function if exists erp_ingress.fail_enquiry_notice(uuid, text);
drop function if exists erp.fail_enquiry_notice(uuid, text);

create or replace function erp.fail_enquiry_notice(p_id uuid, p_reason text, p_provider_message_id text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update erp_meta.enquiry
     set status = 'notification_failed',
         -- Bounded, and never the request headers: a reason is read on a
         -- screen, so it must not be a place a credential can land.
         failure_reason = left(coalesce(nullif(btrim(p_reason), ''), 'unknown'), 500),
         -- The messages that were taken before the send failed, as the
         -- provider named them, comma-separated as complete_enquiry_notice
         -- keeps them; none, and whatever it held stays (20261012050000).
         provider_message_id = coalesce(nullif(btrim(coalesce(p_provider_message_id, '')), ''),
                                        provider_message_id)
   where id = p_id;

  if not found then
    raise exception 'CLOVEERP_ENQUIRY_NOT_FOUND: no enquiry %', p_id
      using errcode = '23503',
            hint = 'The enquiry function records what became of the enquiry it has just stored; an id it did not store names nothing.';
  end if;
end;
$$;

revoke all on function erp.fail_enquiry_notice(uuid, text, text) from public, anon, authenticated, service_role;

create or replace function erp_ingress.fail_enquiry_notice(p_id uuid, p_reason text, p_provider_message_id text default null)
returns void
language sql
volatile
security definer
set search_path to ''
as $$
  select erp.fail_enquiry_notice(p_id, p_reason, p_provider_message_id)
$$;

-- A definer function is EXECUTE to PUBLIC unless taken back; the contact
-- form's role is the one that calls it (20260905000000).
revoke all on function erp_ingress.fail_enquiry_notice(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function erp_ingress.fail_enquiry_notice(uuid, text, text) to clove_enquiry;

comment on function erp.fail_enquiry_notice(uuid, text, text) is
  'Records that an enquiry notice did not reach every member of staff it was for, with the reason, and the '
  'provider''s ids for the messages that were taken before it failed, if any, so the events about them are '
  'matched to the enquiry (20260904950000, 20261012050000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The build ticks what it did
-- ─────────────────────────────────────────────────────────────────────────────

-- A draft of this migration, never released, made the routine with two
-- arguments. A database a rehearsal applied that draft to loses it here, so a
-- call with two arguments is not ambiguous between the two.
drop function if exists erp_meta.deployment_checklist_by_build(text, text);

create or replace function erp_meta.deployment_checklist_by_build(p_code text, p_item text, p_done boolean default true)
returns text
language plpgsql
set search_path = ''
as $$
declare
  -- The register's own words, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired  constant text := 'retired';
  c_retiring constant text := 'retiring';
  c_failed   constant text := 'failed';
  -- Who the Fleet view says ticked it: the console says "set by the build".
  c_by       constant text := 'the build';
  -- The one step the build sets up.
  c_webhook  constant text := 'resend_webhook';
  d          erp_meta.deployment;
  v_item     text := lower(btrim(coalesce(p_item, '')));
  -- Not said is not done, as the console's door reads it.
  v_done     boolean := coalesce(p_done, false);
  v_was      jsonb;
begin
  -- The register of deployments is the control plane's.
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);
  -- The build sets up the email provider's webhook and nothing else on the
  -- checklist: Google sign-in is a person's to set up and to tick.
  if v_item is distinct from c_webhook then
    raise exception 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN: % is not a step the build sets up',
      coalesce('"' || p_item || '"', 'nothing')
      using errcode = '22023',
            hint = 'The build ticks only the email provider''s webhook (resend_webhook). Google sign-in is ticked '
                   'by a person, in the Fleet view.';
  end if;

  -- The row as it is, held until the step is written.
  select x.* into d from erp_meta.deployment x where x.code = d.code for update;
  v_was := d.checklist -> v_item;

  if v_done then
    -- The webhook is made on the client's own project, for a client being
    -- built or served, so the build has done it for none with no project
    -- yet, none whose build failed and none being offboarded or retired
    -- (20261012050000).
    if d.project_ref is null or d.status in (c_failed, c_retiring, c_retired) then
      raise exception 'CLOVEERP_DEPLOYMENT_STATE: % is %, and the build ticks a step of a deployment''s checklist only while it has a project and is neither failed, being offboarded nor retired',
        d.code, d.status || case when d.project_ref is null then ' with no project' else '' end
        using errcode = '55000',
              hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
    end if;

    -- Told again, it changes nothing: a build carried on, or a fleet run
    -- that verifies the step, is not a second tick. A step a person ticked
    -- or unticked is the build's once the build has done it.
    if v_was ->> 'done' = 'true' and v_was ->> 'by' = c_by then
      return format('%s: %s was done by the build already', d.code, v_item);
    end if;

    update erp_meta.deployment x
       set checklist = x.checklist || jsonb_build_object(v_item,
                         jsonb_build_object('done', true, 'at', now(), 'by', c_by)),
           updated_at = now()
     where x.code = d.code;
    perform erp_meta.record_deployment_event(d.code, 'checklist', 'done', format('%s done by the build', v_item));
    return format('%s: %s done by the build', d.code, v_item);
  end if;

  -- Not done: the build deleted the endpoint, or left none. Said in any
  -- state, because deleting a leaving client's endpoint is when it is said
  -- most. A step not done is left as it is, whoever wrote it last.
  if coalesce(v_was ->> 'done', 'false') <> 'true' then
    return format('%s: %s was not done, and is left as it was', d.code, v_item);
  end if;

  update erp_meta.deployment x
     set checklist = x.checklist || jsonb_build_object(v_item,
                       jsonb_build_object('done', false, 'at', now(), 'by', c_by)),
         updated_at = now()
   where x.code = d.code;
  perform erp_meta.record_deployment_event(d.code, 'checklist', 'note', format('%s undone by the build', v_item));
  return format('%s: %s undone by the build', d.code, v_item);
end;
$$;

revoke all on function erp_meta.deployment_checklist_by_build(text, text, boolean)
  from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_checklist_by_build(text, text, boolean) is
  'Called on the control plane by the build and the fleet''s secrets workflow about the one step of a client '
  'deployment''s checklist they set up, the email provider''s webhook (resend_webhook). Done (the default): once '
  'they have made and proved it, marks it {done: true, at, by: ''the build''}, which the Fleet view reads as it is, '
  'and records the step in the deployment''s events; one done by the build already is left as it is and said so, '
  'and one a person ticked or unticked becomes the build''s. Not done: once they have deleted the endpoint or left '
  'none, marks it {done: false, at, by: ''the build''} and records it, in any state; one not done is left as it '
  'is. Refuses CLOVEERP_NOT_THE_CONTROL_PLANE, CLOVEERP_DEPLOYMENT_UNKNOWN, CLOVEERP_CHECKLIST_ITEM_UNKNOWN for any '
  'step but the webhook, and CLOVEERP_DEPLOYMENT_STATE for ticking a deployment with no project, failed, being '
  'offboarded or retired. Trusted build role only (20261012050000).';

comment on function public.erp_platform_deployment_checklist(text, text, boolean) is
  'Ticks or unticks, by hand, one of the two steps of a client deployment''s checklist: Google sign-in, if the '
  'client wants it, and the email provider''s webhook, which the build sets up and ticks itself when it holds the '
  'provider''s admin key (erp_meta.deployment_checklist_by_build). Platform operator and above, on the control '
  'plane (20261011020000, 20261011110000, 20261012050000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The fleet's own targets are nobody's code
-- ─────────────────────────────────────────────────────────────────────────────

-- The fleet's workflows (fleet_secrets.yml among them) take a client's code,
-- or all, control (the control plane) or demonstration, and read those three
-- before any code. A client deployment whose code is one could never be named
-- on its own, and one coded all would be every client at once. None is, on
-- any database this was written against; this stops, and says which, if one
-- is, since a deployment's code never changes. An address that is one, or an
-- organisation holding one, keeps it: a reserved word never takes an address
-- away (the trigger on erp.tenant reads a code only when it changes), and the
-- workflows name neither.
do $$
declare
  v_held text;
begin
  select string_agg(format('client deployment "%s"', d.code), ', ' order by d.code)
    into v_held
    from erp_meta.deployment d
   where d.code in ('all', 'control', 'demonstration');
  if v_held is not null then
    raise exception 'CLOVEERP_ADDRESS_RESERVED: % has a code the fleet''s workflows read as a target of their own', v_held
      using hint = 'A deployment''s code never changes, and the workflows cannot name this one: ask the owner what '
                   'becomes of it before this migration is applied.';
  end if;
end
$$;

insert into erp_meta.reserved_tenant_code (code, reason)
values ('all', 'a target of the fleet''s workflows: every client deployment (20261012050000)'),
       ('control', 'a target of the fleet''s workflows: the control plane (20261012050000)'),
       ('demonstration', 'a target of the fleet''s workflows: the demonstration (20261012050000)')
on conflict (code) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.email_tracking_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  -- Fifteen since a database keeps only its own mail, invitations and
  -- enquiry notices that failed part-way among it (20261012050000).
  c_expected  constant integer := 15;
  c_not_ours  constant text := 'that event is about no message this database sent';
  v_cases     integer := 0;
  v_job_before    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_role_before   name := current_user;
  v_tag       text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_pcode     text;
  v_ccode     text;
  a_admin     uuid := gen_random_uuid();
  a_owner     uuid := gen_random_uuid();
  a_support   uuid := gen_random_uuid();
  a_customer  uuid := gen_random_uuid();
  v_step      text := 'starting';
  v_state     text;
  rp          record;
  rc          record;
  rx          record;
  v_platform  uuid;
  v_customer  uuid;
  v_person    uuid;
  v_contract  uuid;
  v_invoice   uuid;
  v_enquiry   uuid;
  v_enquiry2  uuid;
  -- Somebody the customer invited, and the invitation emails they were sent.
  v_invitee   uuid := gen_random_uuid();
  v_invited   text;
  l_old       uuid;
  l_mid       uuid;
  l_new       uuid;
  l_resend    uuid;
  r1          jsonb;
  r2          jsonb;
  r3          jsonb;
  r4          jsonb;
  r5          jsonb;
  r6          jsonb;
  e_bounce    jsonb;
  e_complaint jsonb;
  e_delivered jsonb;
  v_reason1   text;
  v_refused   text;
  ce_sent     uuid;
  ce_queued   uuid;
  ce_bounce   uuid;
  ce_soft     uuid;
  v_note      uuid;
  v_address   text;
  v_gone      text;
  v_soft      text;
  v_stranger  text;
  v_told      integer := 0;
  v_kept      integer := 0;
  v_n_ev      bigint;
  v_n_sup     bigint;
  v_n_aud     bigint;
  res         jsonb;
  res2        jsonb;
  n           erp.notification;
  e           erp_meta.commercial_email;

  ok_once     boolean; msg_once     text;
  ok_order    boolean; msg_order    text;
  ok_bounce   boolean; msg_bounce   text;
  ok_soft     boolean; msg_soft     text;
  ok_elsewhere boolean; msg_elsewhere text;
  ok_stop     boolean; msg_stop     text;
  ok_clear    boolean; msg_clear    text;
  ok_note     boolean; msg_note     text;
  ok_nothing  boolean; msg_nothing  text;
  ok_enquiry  boolean; msg_enquiry  text;
  ok_partway  boolean; msg_partway  text;
  ok_invited  boolean; msg_invited  text;
  ok_inv_bounce boolean; msg_inv_bounce text;
  ok_console  boolean; msg_console  text;
begin
  begin
    v_pcode := 'zzetp-' || v_tag;
    v_ccode := 'zzetc-' || v_tag;
    v_address := 'accounts@' || v_ccode || '.test';
    v_gone := 'gone@' || v_ccode || '.test';
    v_soft := 'full@' || v_ccode || '.test';
    -- Somebody another database wrote to.
    v_stranger := 'somebody@' || v_ccode || '.test';
    -- Somebody the customer invited.
    v_invited := 'invitee@' || v_ccode || '.test';

    v_step := 'the organisations, the staff and one sent invoice email';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Tracking', 'admin@' || v_pcode || '.test', 'Platform Admin');
    v_platform := rp.tenant_id;
    select * into rc from erp.provision_tenant(v_ccode, 'Tracking Customer Ltd', 'admin@' || v_ccode || '.test', 'Customer Admin');
    v_customer := rc.tenant_id;
    insert into auth.users (id, email) values
      (a_admin, 'admin@' || v_pcode || '.test'),
      (a_owner, 'owner@' || v_pcode || '.test'),
      (a_support, 'support@' || v_pcode || '.test'),
      (a_customer, 'admin@' || v_ccode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role) values
      ('owner@' || v_pcode || '.test', a_owner, 'Tracking Owner', 'owner'),
      ('support@' || v_pcode || '.test', a_support, 'Tracking Support', 'support');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.claim_invitation(rp.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    perform erp.designate_platform_organisation(v_pcode, 'the email tracking suite');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp_test.reopen_bootstrap_window(v_platform);
    perform erp.set_up_selling();
    perform erp_test.close_bootstrap_window(v_platform);
    perform set_config('request.jwt.claims', '', true);

    -- A contract and an invoice, written directly: what is proved here is what
    -- becomes of the email, not how the invoice came to exist.
    insert into erp_meta.contract
      (tenant_id, tenant_code, platform_tenant_id, quote_document_id, quote_number, quote_version,
       customer_legal_name, platform_legal_name, plan_code, term_kind, currency, annual_value_minor,
       commencement, initial_term_months, current_term_start, current_term_end, governing_law, status,
       created_by)
    values (v_customer, v_ccode, v_platform, gen_random_uuid(), 'ZZTRACK-1', 1,
            'Tracking Customer Ltd', 'Clove ERP Ltd', (select p.code from erp_meta.plan p order by p.code limit 1),
            'annual', 'GBP', 1200000, current_date, 12, current_date, current_date + 365,
            'England and Wales', 'active',
            -- A contract says who wrote it, and this one was written by a suite.
            'owner@' || v_pcode || '.test')
    returning id into v_contract;
    insert into erp_meta.contract_invoice
      (contract_id, tenant_id, tenant_code, seq, reference, period_start, period_end, due_on,
       currency, subscription_minor, total_minor, status, issued_at)
    values (v_contract, v_customer, v_ccode, 1, 'ZZTRACK-INV-' || v_tag, current_date, current_date + 30,
            current_date + 14, 'GBP', 100000, 100000, 'issued', now())
    returning id into v_invoice;

    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number, to_address, to_name,
       recipient_source, status, provider_message_id, sent_at, requested_by, idempotency_key)
    values ('contract_invoice', v_invoice, v_customer, v_ccode, 1, v_address, 'Accounts Team',
            'billing_contact', 'sent', 'zz-msg-' || v_tag, now(), 'owner@' || v_pcode || '.test',
            'zz-key-sent-' || v_tag)
    returning id into ce_sent;
    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number, to_address, to_name,
       recipient_source, status, requested_by, idempotency_key)
    values ('contract_invoice', v_invoice, v_customer, v_ccode, 2, v_address, 'Accounts Team',
            'billing_contact', 'queued', 'owner@' || v_pcode || '.test', 'zz-key-queued-' || v_tag)
    returning id into ce_queued;
    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number, to_address, to_name,
       recipient_source, status, provider_message_id, sent_at, requested_by, idempotency_key)
    values ('contract_invoice', v_invoice, v_customer, v_ccode, 3, v_gone, 'Somebody Gone',
            'administrator', 'sent', 'zz-bounce-' || v_tag, now(), 'owner@' || v_pcode || '.test',
            'zz-key-bounce-' || v_tag)
    returning id into ce_bounce;
    insert into erp_meta.commercial_email
      (kind, contract_invoice_id, tenant_id, tenant_code, send_number, to_address, to_name,
       recipient_source, status, provider_message_id, sent_at, requested_by, idempotency_key)
    values ('contract_invoice', v_invoice, v_customer, v_ccode, 4, v_soft, 'Full Mailbox',
            'administrator', 'sent', 'zz-soft-' || v_tag, now(), 'owner@' || v_pcode || '.test',
            'zz-key-soft-' || v_tag)
    returning id into ce_soft;

    select u.id into v_person from erp.app_user u
     where u.tenant_id = v_customer and u.auth_user_id = a_customer;
    -- The customer's own organisation is the context its notification is written in.
    perform erp.set_job_tenant(v_customer);
    insert into erp.notification
      (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, provider_message_id)
    values (v_customer, 'info', v_person, 'email', 'Something happened', 'A message the provider took.',
            'sent', now(), 'zz-note-' || v_tag)
    returning id into v_note;
    perform set_config('erp.job_tenant_id', '', true);

    -- ── One event, recorded once ────────────────────────────────────────────
    v_step := 'the provider says the invoice email was delivered, twice';
    res := erp.record_email_delivery_event('evt-delivered-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    select * into e from erp_meta.commercial_email where id = ce_sent;
    ok_once := (res ->> 'recorded')::boolean
           and res ->> 'matched' = 'commercial_email'
           and (res ->> 'moved')::boolean
           and e.delivery_state = 'delivered' and e.delivery_state_at is not null
           and e.status = 'sent';
    res := erp.record_email_delivery_event('evt-delivered-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    ok_once := ok_once and not (res ->> 'recorded')::boolean
           and res ->> 'reason' = 'that event was recorded already'
           and (select count(*) from erp_meta.email_delivery_event ev
                 where ev.event_id = 'evt-delivered-' || v_tag) = 1;
    msg_once := format('delivered, recorded %s time(s)',
                       (select count(*) from erp_meta.email_delivery_event ev
                         where ev.event_id = 'evt-delivered-' || v_tag));

    -- ── A state never goes backwards ────────────────────────────────────────
    v_step := 'a late "sent" arrives after the delivery, and then an "opened"';
    res := erp.record_email_delivery_event('evt-late-sent-' || v_tag, 'email.sent', 'sent',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    select * into e from erp_meta.commercial_email where id = ce_sent;
    ok_order := (res ->> 'recorded')::boolean and not (res ->> 'moved')::boolean
            and e.delivery_state = 'delivered';
    res := erp.record_email_delivery_event('evt-opened-' || v_tag, 'email.opened', 'opened',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    select * into e from erp_meta.commercial_email where id = ce_sent;
    ok_order := ok_order and (res ->> 'moved')::boolean and e.delivery_state = 'opened';
    msg_order := 'a late send changed nothing; an open moved it on';

    -- ── A permanent bounce ──────────────────────────────────────────────────
    v_step := 'an address bounces permanently';
    res := erp.record_email_delivery_event('evt-bounce-' || v_tag, 'email.bounced', 'bounced',
                                           'zz-bounce-' || v_tag, now(), v_gone, 'Permanent/Suppressed',
                                           'The recipient does not exist.');
    select * into e from erp_meta.commercial_email where id = ce_bounce;
    ok_bounce := e.delivery_state = 'bounced'
             and e.delivery_detail like 'Permanent/Suppressed%'
             and (res ->> 'suppressed')::boolean
             and exists (select 1 from erp.email_suppression s
                          where s.tenant_id = v_platform and s.address = v_gone
                            and s.reason = 'hard_bounce' and s.is_permanent)
             and exists (select 1 from erp_meta.platform_audit a
                          where a.action = 'platform.email_bounced' and a.target = 'zz-bounce-' || v_tag);
    msg_bounce := 'bounced, suppressed and audited';

    -- ── A temporary one is not a fact about the address ─────────────────────
    v_step := 'a mailbox is full today';
    res := erp.record_email_delivery_event('evt-soft-' || v_tag, 'email.bounced', 'bounced',
                                           'zz-soft-' || v_tag, now(), v_soft, 'Transient/MailboxFull',
                                           'The mailbox is full.');
    ok_soft := not (res ->> 'suppressed')::boolean
           and not exists (select 1 from erp.email_suppression s
                            where s.tenant_id = v_platform and s.address = v_soft)
           and (select ce.delivery_state from erp_meta.commercial_email ce where ce.id = ce_soft) = 'bounced';
    msg_soft := 'a temporary bounce is recorded and suppresses nothing';

    -- ── Another database's bounce of an address this one writes to ──────────
    -- Every endpoint hears the whole account's mail. The mailbox this
    -- database found full may be gone for good in another database's message,
    -- and the customer's administrator may complain of another's: neither is
    -- this database's to act on (20261012050000).
    v_step := 'an address this database writes to bounces for good, and complains, in messages another database sent';
    res := erp.record_email_delivery_event('evt-elsewhere-bounce-' || v_tag, 'email.bounced', 'bounced',
                                           'zz-elsewhere-' || v_tag, now(), v_soft, 'Permanent/Suppressed',
                                           'The recipient does not exist.');
    res2 := erp.record_email_delivery_event('evt-elsewhere-complaint-' || v_tag, 'email.complained', 'complained',
                                            'zz-elsewhere-' || v_tag, now(), 'admin@' || v_ccode || '.test',
                                            null, null);
    ok_elsewhere := not (res ->> 'recorded')::boolean and res ->> 'reason' = c_not_ours
                and not (res2 ->> 'recorded')::boolean and res2 ->> 'reason' = c_not_ours
                and not exists (select 1 from erp.email_suppression s
                                 where s.address in (v_soft, 'admin@' || v_ccode || '.test'))
                and not exists (select 1 from erp_meta.platform_audit a where a.target = 'zz-elsewhere-' || v_tag)
                and not exists (select 1 from erp_meta.email_delivery_event ev
                                 where ev.event_id like 'evt-elsewhere-%' || v_tag)
                and (select ce.delivery_state from erp_meta.commercial_email ce where ce.id = ce_soft) = 'bounced'
                and (select count(*) from erp_meta.email_delivery_event ev where ev.to_address = v_soft) = 1;
    msg_elsewhere := format('%s / %s', res, res2);

    -- ── A complaint stops the next one ──────────────────────────────────────
    v_step := 'the customer marks it as spam, and the drain claims what is queued';
    res := erp.record_email_delivery_event('evt-complaint-' || v_tag, 'email.complained', 'complained',
                                           'zz-msg-' || v_tag, now(), v_address, null, null);
    ok_stop := (res ->> 'suppressed')::boolean
           and exists (select 1 from erp.email_suppression s
                        where s.tenant_id = v_platform and s.address = v_address
                          and s.reason = 'complaint' and s.is_permanent);
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform erp.claim_commercial_email_batch(500, 'zz-email-tracking');
    perform set_config('erp.job_tenant_id', '', true);
    select * into e from erp_meta.commercial_email where id = ce_queued;
    ok_stop := ok_stop and e.status = 'cancelled'
           and e.failure_reason like 'the provider reported this address as undeliverable%';
    msg_stop := format('the queued message was %s: %s', e.status, left(coalesce(e.failure_reason, ''), 60));

    -- ── An operator decides otherwise ───────────────────────────────────────
    v_step := 'an operator clears the suppression, and a customer tries to';
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    res := public.erp_platform_clear_email_suppression(v_address, 'the customer asked us to write again');
    ok_clear := (res ->> 'cleared')::boolean and res ->> 'was' = 'complaint'
            and not exists (select 1 from erp.email_suppression s
                             where s.tenant_id = v_platform and s.address = v_address)
            and exists (select 1 from erp_meta.platform_audit a
                         where a.action = 'platform.email_suppression_cleared' and a.target = v_address);
    -- Each step says what went wrong in it, and nothing after writes over
    -- that: only the end of a case that held says it held.
    msg_clear := case when ok_clear then null else 'the operator''s clearing was not recorded as it should be: '
                                                   || left(res::text, 120) end;
    begin
      perform public.erp_platform_clear_email_suppression(v_address, null);
      ok_clear := false;
      msg_clear := coalesce(msg_clear, 'clearing a suppression that does not exist said it did');
    exception when others then
      if sqlerrm not like 'CLOVEERP_EMAIL_SUPPRESSION_NOT_FOUND%' then
        ok_clear := false;
        msg_clear := coalesce(msg_clear, 'clearing it again met ' || left(sqlerrm, 120));
      end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    begin
      perform public.erp_platform_clear_email_suppression(v_gone, null);
      ok_clear := false;
      msg_clear := coalesce(msg_clear, 'a customer cleared a suppression');
    exception when others then
      if sqlerrm not like 'CLOVEERP_NOT_PLATFORM_STAFF%' then
        ok_clear := false;
        msg_clear := coalesce(msg_clear, 'a customer met ' || left(sqlerrm, 120) || ', not the refusal of somebody who is not staff');
      end if;
    end;
    msg_clear := coalesce(msg_clear, 'the operator cleared it; nobody else can');

    -- ── The other queue ─────────────────────────────────────────────────────
    v_step := 'the provider answers about a notification';
    res := erp.record_email_delivery_event('evt-note-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-note-' || v_tag, now(), 'admin@' || v_ccode || '.test', null, null);
    select * into n from erp.notification where id = v_note;
    ok_note := res ->> 'matched' = 'notification'
           and n.status = 'delivered' and n.delivered_at is not null
           and n.delivery_state = 'delivered';
    msg_note := 'the notification was delivered';

    -- ── Another database's mail, of every kind ──────────────────────────────
    -- An event about no message this database sent, of every type the
    -- endpoint hands on and one it keeps no state for, one naming no message
    -- at all, and one told twice: none is kept, and nothing is written
    -- anywhere (20261012050000).
    v_step := 'the provider tells this database about messages another database sent';
    select count(*) into v_n_ev from erp_meta.email_delivery_event;
    select count(*) into v_n_sup from erp.email_suppression;
    select count(*) into v_n_aud from erp_meta.platform_audit;
    ok_nothing := true;
    for rx in
      select x.o, x.t, x.s, x.k, x.m
        from (values
          (1, 'email.sent', 'sent', null::text, 'zz-nobody-'),
          (2, 'email.delivery_delayed', 'delayed', null, 'zz-nobody-'),
          (3, 'email.delivered', 'delivered', null, 'zz-nobody-'),
          (4, 'email.opened', 'opened', null, 'zz-nobody-'),
          (5, 'email.bounced', 'bounced', 'Permanent/General', 'zz-nobody-'),
          (6, 'email.complained', 'complained', null, 'zz-nobody-'),
          (7, 'email.clicked', null, null, 'zz-nobody-'),
          (8, 'email.bounced', 'bounced', 'Permanent/General', null),
          (3, 'email.delivered', 'delivered', null, 'zz-nobody-')
        ) as x(o, t, s, k, m)
    loop
      res := erp.record_email_delivery_event('evt-stranger-' || rx.o || '-' || v_tag, rx.t, rx.s,
                                             rx.m || v_tag, now(), v_stranger, rx.k, 'Not this database''s.');
      v_told := v_told + 1;
      if (res ->> 'recorded')::boolean is distinct from false or res ->> 'matched' is distinct from 'nothing'
         or res ->> 'reason' is distinct from c_not_ours then
        ok_nothing := false;
        msg_nothing := coalesce(msg_nothing, format('%s answered %s', rx.t, res));
      end if;
    end loop;
    select count(*) into v_kept from erp_meta.email_delivery_event ev
     where ev.event_id like 'evt-stranger-%' || v_tag or ev.to_address = v_stranger;
    ok_nothing := ok_nothing and v_told = 9 and v_kept = 0
              and (select count(*) from erp_meta.email_delivery_event) = v_n_ev
              and (select count(*) from erp.email_suppression) = v_n_sup
              and (select count(*) from erp_meta.platform_audit) = v_n_aud
              and not exists (select 1 from erp.email_suppression s where s.address = v_stranger)
              and not exists (select 1 from erp_meta.platform_audit a
                               where a.target = 'zz-nobody-' || v_tag or a.detail ->> 'address' = v_stranger);
    msg_nothing := coalesce(msg_nothing, format(
      '%s event(s) about another database''s mail: %s kept; %s event(s), %s suppression(s), %s audit row(s) more',
      v_told, v_kept, (select count(*) from erp_meta.email_delivery_event) - v_n_ev,
      (select count(*) from erp.email_suppression) - v_n_sup, (select count(*) from erp_meta.platform_audit) - v_n_aud));

    -- ── An enquiry notice is this database's mail ───────────────────────────
    v_step := 'the provider answers about an enquiry notice';
    insert into erp_meta.enquiry (full_name, email, message, status, notified_at, provider_message_id)
    values ('Tracking Enquirer', 'enquirer@' || v_ccode || '.test',
            'The email tracking suite would like to hear more, please.', 'notified', now(),
            'zz-enq-a-' || v_tag || ',zz-enq-b-' || v_tag)
    returning id into v_enquiry;
    res := erp.record_email_delivery_event('evt-enquiry-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-enq-b-' || v_tag, now(), 'support@' || v_pcode || '.test', null, null);
    ok_enquiry := (res ->> 'recorded')::boolean and res ->> 'matched' = 'enquiry'
              and not (res ->> 'moved')::boolean
              and exists (select 1 from erp_meta.email_delivery_event ev
                           where ev.event_id = 'evt-enquiry-' || v_tag and ev.matched = 'enquiry'
                             and ev.provider_message_id = 'zz-enq-b-' || v_tag);
    msg_enquiry := res::text;

    -- ── An enquiry notice that failed part-way ──────────────────────────────
    -- The provider took the message to the first member of staff and refused
    -- the next. The contact form's own role records the failure with the id
    -- of the one that was taken, and that message's events are this
    -- database's. Told again without ids, as the function deployed before
    -- this release tells it, the ids stay (20261012050000).
    v_step := 'an enquiry notice reaches one member of staff and fails for the next';
    insert into erp_meta.enquiry (full_name, email, message, status)
    values ('Tracking Enquirer Two', 'enquirer2@' || v_ccode || '.test',
            'The email tracking suite would like to hear more again, please.', 'new')
    returning id into v_enquiry2;
    set local role clove_enquiry;
    perform erp_ingress.fail_enquiry_notice(v_enquiry2, 'transient failure for the next member of staff: the suite',
                                            ' zz-enq-c-' || v_tag || ' ');
    reset role;
    res := erp.record_email_delivery_event('evt-enquiry-partway-' || v_tag, 'email.delivered', 'delivered',
                                           'zz-enq-c-' || v_tag, now(), 'owner@' || v_pcode || '.test', null, null);
    perform erp.fail_enquiry_notice(v_enquiry2, 'told again without ids: the suite');
    ok_partway := (res ->> 'recorded')::boolean and res ->> 'matched' = 'enquiry'
              and exists (select 1 from erp_meta.email_delivery_event ev
                           where ev.event_id = 'evt-enquiry-partway-' || v_tag and ev.matched = 'enquiry')
              and exists (select 1 from erp_meta.enquiry q
                           where q.id = v_enquiry2 and q.status = 'notification_failed'
                             and q.provider_message_id = 'zz-enq-c-' || v_tag
                             and q.failure_reason = 'told again without ids: the suite');
    msg_partway := res::text;

    -- ── The invite function records the message it sent ─────────────────────
    -- The customer invited somebody three times (two hours ago, twenty minutes
    -- ago and two minutes ago), and a minute ago a fresh sign-in link was
    -- asked for; each email's row was written when it was allowed, and the
    -- newest is the link's, so an invitation's message kept beside it would
    -- show. Each message the provider took is kept beside the newest row of
    -- its kind that has none, claimed within the hour, and nothing else is
    -- (20261012050000).
    v_step := 'the customer invites somebody, and the provider takes the emails';
    perform erp.set_job_tenant(v_customer);
    insert into erp.invitation_email_log (tenant_id, app_user_id, email_lower, sent_by_auth_user_id, kind, created_at)
    values (v_customer, v_invitee, v_invited, a_customer, 'invite', now() - interval '2 hours')
    returning id into l_old;
    insert into erp.invitation_email_log (tenant_id, app_user_id, email_lower, sent_by_auth_user_id, kind, created_at)
    values (v_customer, v_invitee, v_invited, a_customer, 'invite', now() - interval '20 minutes')
    returning id into l_mid;
    insert into erp.invitation_email_log (tenant_id, app_user_id, email_lower, sent_by_auth_user_id, kind, created_at)
    values (v_customer, v_invitee, v_invited, a_customer, 'invite', now() - interval '2 minutes')
    returning id into l_new;
    insert into erp.invitation_email_log (tenant_id, app_user_id, email_lower, sent_by_auth_user_id, kind, created_at)
    values (v_customer, v_invitee, v_invited, null, 'resend', now() - interval '1 minute')
    returning id into l_resend;
    perform set_config('erp.job_tenant_id', '', true);
    r1 := erp.record_invitation_email_sent(v_invitee, 'invite', 'zz-inv-1-' || v_tag);
    r2 := erp.record_invitation_email_sent(v_invitee, 'invite', 'zz-inv-1-' || v_tag);
    r3 := erp.record_invitation_email_sent(v_invitee, 'resend', ' zz-inv-2-' || v_tag || ' ');
    r4 := erp.record_invitation_email_sent(v_invitee, 'invite', 'zz-inv-3-' || v_tag);
    r5 := erp.record_invitation_email_sent(v_invitee, 'invite', 'zz-inv-4-' || v_tag);
    r6 := erp.record_invitation_email_sent(v_invitee, 'invite', '  ');
    begin
      perform erp.record_invitation_email_sent(v_invitee, 'reminder', 'zz-inv-5-' || v_tag);
      v_refused := 'a kind of email that does not exist was recorded';
    exception when others then
      v_refused := sqlerrm;
    end;
    perform set_config('erp.job_tenant_id', '', true);
    ok_invited := (r1 ->> 'recorded')::boolean and r1 ->> 'kind' = 'invite'
              and not (r2 ->> 'recorded')::boolean and r2 ->> 'reason' = 'that message was recorded already'
              and (r3 ->> 'recorded')::boolean and r3 ->> 'kind' = 'resend'
              and (r4 ->> 'recorded')::boolean
              and not (r5 ->> 'recorded')::boolean
              and r5 ->> 'reason' = 'no invitation email of that kind is waiting for its message'
              and not (r6 ->> 'recorded')::boolean and r6 ->> 'reason' = 'the provider named no message'
              and v_refused like 'CLOVEERP_INVITATION_EMAIL_KIND_UNKNOWN: reminder is not a kind of invitation email%'
              and (select m.provider_message_id from erp.invitation_email_message m where m.log_id = l_new)
                  = 'zz-inv-1-' || v_tag
              and (select m.provider_message_id from erp.invitation_email_message m where m.log_id = l_resend)
                  = 'zz-inv-2-' || v_tag
              and (select m.provider_message_id from erp.invitation_email_message m where m.log_id = l_mid)
                  = 'zz-inv-3-' || v_tag
              and not exists (select 1 from erp.invitation_email_message m where m.log_id = l_old)
              and (select count(*) from erp.invitation_email_message m where m.tenant_id = v_customer) = 3
              and not pg_catalog.has_function_privilege('anon', 'erp.record_invitation_email_sent(uuid,text,text)', 'execute')
              and not pg_catalog.has_function_privilege('authenticated', 'erp.record_invitation_email_sent(uuid,text,text)', 'execute')
              and not pg_catalog.has_function_privilege('service_role', 'erp.record_invitation_email_sent(uuid,text,text)', 'execute');
    msg_invited := concat_ws(' / ', r1, r2, r3, r4, r5, r6, left(v_refused, 80));

    -- ── An invitation's bounce is this database's ───────────────────────────
    -- The first invitation bounced for good, the fresh link was complained of,
    -- and the latest was delivered. Each is kept, and the bounce and the
    -- complaint stop the address in the organisation that invited, not in the
    -- platform's (20261012050000).
    v_step := 'the provider answers about the invitation emails';
    e_bounce := erp.record_email_delivery_event('evt-inv-bounce-' || v_tag, 'email.bounced', 'bounced',
                                                'zz-inv-1-' || v_tag, now(), v_invited, 'Permanent/General',
                                                'No such mailbox.');
    v_reason1 := (select s.reason from erp.email_suppression s where s.tenant_id = v_customer and s.address = v_invited);
    e_complaint := erp.record_email_delivery_event('evt-inv-complaint-' || v_tag, 'email.complained', 'complained',
                                                   'zz-inv-2-' || v_tag, now(), v_invited, null, null);
    e_delivered := erp.record_email_delivery_event('evt-inv-delivered-' || v_tag, 'email.delivered', 'delivered',
                                                   'zz-inv-3-' || v_tag, now(), v_invited, null, null);
    ok_inv_bounce := (e_bounce ->> 'recorded')::boolean and e_bounce ->> 'matched' = 'invitation'
                 and (e_bounce ->> 'suppressed')::boolean
                 and v_reason1 = 'hard_bounce'
                 and (e_complaint ->> 'recorded')::boolean and e_complaint ->> 'matched' = 'invitation'
                 and (e_complaint ->> 'suppressed')::boolean
                 and (e_delivered ->> 'recorded')::boolean and e_delivered ->> 'matched' = 'invitation'
                 and not (e_delivered ->> 'moved')::boolean and not (e_delivered ->> 'suppressed')::boolean
                 and exists (select 1 from erp.email_suppression s
                              where s.tenant_id = v_customer and s.address = v_invited
                                and s.reason = 'complaint' and s.is_permanent)
                 and not exists (select 1 from erp.email_suppression s
                                  where s.tenant_id = v_platform and s.address = v_invited)
                 and (select count(*) from erp_meta.email_delivery_event ev
                       where ev.event_id like 'evt-inv-%' || v_tag
                         and ev.matched = 'invitation' and ev.tenant_id = v_customer) = 3
                 and exists (select 1 from erp_meta.platform_audit a
                              where a.action = 'platform.email_bounced' and a.target = 'zz-inv-1-' || v_tag
                                and a.tenant_id = v_customer);
    msg_inv_bounce := format('%s / %s / %s', e_bounce, e_complaint, e_delivered);

    -- ── What the console reads ──────────────────────────────────────────────
    v_step := 'support reads what the provider has said, and a customer asks to';
    perform set_config('request.jwt.claims', json_build_object('sub', a_support)::text, true);
    res := public.erp_platform_email_delivery(50);
    ok_console := exists (select 1 from jsonb_array_elements(res -> 'trouble') x
                           where x ->> 'to_address' = v_gone and x ->> 'state' = 'bounced'
                             and (x ->> 'suppressed')::boolean)
              and exists (select 1 from jsonb_array_elements(res -> 'suppressed') x
                           where x ->> 'address' = v_gone and x ->> 'reason' = 'hard_bounce')
              -- Nothing of another database's mail.
              and not exists (select 1 from jsonb_array_elements(res -> 'trouble') x
                               where x ->> 'to_address' = v_stranger
                                  or x ->> 'event_id' like 'evt-elsewhere-%' || v_tag)
              and not exists (select 1 from jsonb_array_elements(res -> 'suppressed') x
                               where x ->> 'address' in (v_stranger, v_soft))
              and (res -> 'recent' ->> 'delivered')::integer >= 1;
    -- What support read is said before the customer's turn, so a refusal
    -- that follows cannot write over a read that was wrong.
    msg_console := case when ok_console
                        then 'support reads the bounces and the suppressed list, and nothing of another''s mail'
                        else 'support''s read lacked the bounce, the suppression or a delivery, or showed another''s mail: '
                             || left(res::text, 200) end;
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    begin
      perform public.erp_platform_email_delivery(50);
      ok_console := false; msg_console := 'a customer read the platform''s delivery log';
    exception when others then
      if sqlerrm like 'CLOVEERP_NOT_PLATFORM_STAFF%' then
        msg_console := msg_console || '; a customer is refused';
      else
        ok_console := false;
        msg_console := msg_console || '; a customer met ' || left(sqlerrm, 120) || ', not the refusal of somebody who is not staff';
      end if;
    end;

    v_step := 'done';
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'a delivery is recorded once, and says so the second time';
  passed := v_state is null and coalesce(ok_once, false);
  detail := coalesce(v_state, msg_once);
  return next;

  v_cases := v_cases + 1;
  case_name := 'an event that arrives late cannot move a message backwards';
  passed := v_state is null and coalesce(ok_order, false);
  detail := coalesce(v_state, msg_order);
  return next;

  v_cases := v_cases + 1;
  case_name := 'a permanent bounce is recorded, suppresses the address and is audited';
  passed := v_state is null and coalesce(ok_bounce, false);
  detail := coalesce(v_state, msg_bounce);
  return next;

  v_cases := v_cases + 1;
  case_name := 'a temporary bounce suppresses nothing';
  passed := v_state is null and coalesce(ok_soft, false);
  detail := coalesce(v_state, msg_soft);
  return next;

  v_cases := v_cases + 1;
  case_name := 'a permanent bounce or a complaint in another database''s message stops nothing here, even for an address this database writes to';
  passed := v_state is null and coalesce(ok_elsewhere, false);
  detail := coalesce(v_state, msg_elsewhere);
  return next;

  v_cases := v_cases + 1;
  case_name := 'a complaint stops the next message to that address, with a reason a person can read';
  passed := v_state is null and coalesce(ok_stop, false);
  detail := coalesce(v_state, msg_stop);
  return next;

  v_cases := v_cases + 1;
  case_name := 'an operator clears a suppression and it is recorded; a customer cannot';
  passed := v_state is null and coalesce(ok_clear, false);
  detail := coalesce(v_state, msg_clear);
  return next;

  v_cases := v_cases + 1;
  case_name := 'a notification is tracked too';
  passed := v_state is null and coalesce(ok_note, false);
  detail := coalesce(v_state, msg_note);
  return next;

  v_cases := v_cases + 1;
  case_name := 'an event about a message this database did not send is not kept, whatever its type, and says so: no event, no suppression, no audit';
  passed := v_state is null and coalesce(ok_nothing, false);
  detail := coalesce(v_state, msg_nothing);
  return next;

  v_cases := v_cases + 1;
  case_name := 'an enquiry notice''s event is still kept, about any message the notice sent';
  passed := v_state is null and coalesce(ok_enquiry, false);
  detail := coalesce(v_state, msg_enquiry);
  return next;

  v_cases := v_cases + 1;
  case_name := 'an enquiry notice that failed part-way keeps the ids of the messages that were taken, and their events are kept';
  passed := v_state is null and coalesce(ok_partway, false);
  detail := coalesce(v_state, msg_partway);
  return next;

  v_cases := v_cases + 1;
  case_name := 'the invite function keeps the provider''s id beside the newest invitation email of its kind that has none, claimed within the hour, and nothing else';
  passed := v_state is null and coalesce(ok_invited, false);
  detail := coalesce(v_state, msg_invited);
  return next;

  v_cases := v_cases + 1;
  case_name := 'an invitation email''s events are kept, and its permanent bounce or complaint stops the address in the organisation that invited';
  passed := v_state is null and coalesce(ok_inv_bounce, false);
  detail := coalesce(v_state, msg_inv_bounce);
  return next;

  v_cases := v_cases + 1;
  case_name := 'platform staff read the bounces and the suppressed addresses, and nothing of another''s mail; a customer is refused';
  passed := v_state is null and coalesce(ok_console, false);
  detail := coalesce(v_state, msg_console);
  return next;

  v_cases := v_cases + 1;
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in (v_pcode, v_ccode))
        and not exists (select 1 from auth.users au where au.id in (a_admin, a_owner, a_support, a_customer))
        and not exists (select 1 from erp_meta.email_delivery_event ev where ev.event_id like '%' || v_tag)
        and not exists (select 1 from erp.email_suppression s where s.address like '%' || v_ccode || '.test')
        and not exists (select 1 from erp_meta.enquiry q where q.email like '%' || v_ccode || '.test')
        and not exists (select 1 from erp.invitation_email_log l where l.email_lower = v_invited)
        and not exists (select 1 from erp.invitation_email_message m where m.provider_message_id like 'zz-inv-%' || v_tag)
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before
        and current_user = v_role_before;
  detail := 'the organisations, people, staff, messages, enquiries, invitation emails, events, suppressions, the role '
            'and every setting went with the block';
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_EMAIL_TRACKING_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_email_tracking_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  -- Fifteen since a database keeps only its own mail, invitations and
  -- enquiry notices that failed part-way among it (20261012050000).
  c_expected constant integer := 15;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _email_tracking_result on commit drop as
    select * from erp_test.email_tracking_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _email_tracking_result s;
  drop table _email_tracking_result;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_EMAIL_TRACKING_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_EMAIL_TRACKING_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read each failed case''s detail above; the first names the step that raised.';
  end if;
  return format('email tracking: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.email_tracking_suite() from public, anon;
revoke all on function erp_test.assert_email_tracking_suite() from public, anon;

comment on function erp_test.assert_email_tracking_suite() is
  'A delivery is recorded once and never moves a message backwards; a permanent bounce suppresses and is audited, '
  'a temporary one suppresses nothing, and a complaint stops the next message until an operator clears it; a '
  'notification and an enquiry notice are tracked too, and one that failed part-way keeps the ids of the messages '
  'taken; the invite function keeps the provider''s id for the email it sent and nothing else, and an invitation''s '
  'permanent bounce or complaint stops the address in the organisation that invited; an event about a message this '
  'database did not send is not kept, whatever its type, and a permanent bounce or a complaint in one stops nothing '
  'here, even for an address this database writes to; the console shows the bounces and nothing of another''s mail; '
  'and nothing is left behind (20260915070000, 20261012050000).';

create or replace function erp_test.deployment_checklist_by_build_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  -- The register's own words, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired  constant text := 'retired';
  c_retiring constant text := 'retiring';
  c_failed   constant text := 'failed';
  c_by       constant text := 'the build';
  c_before   constant text := '2026-01-01T00:00:00+00:00';
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_step     text := 'standing up an owner';
  v_state    text;
  v_kind     text := erp.deployment_kind();
  v_uid      uuid := gen_random_uuid();
  v_owner    text;
  v_code     text;
  v_live     text;
  v_bare     text;
  v_gone     text;
  v_leaving  text;
  v_broken   text;
  v_got      text;
  v_got2     text;
  v_got3     text;
  v_got4     text;
  v_got5     text;
  v_got6     text;
  v_got7     text;
  v_got8     text;
  v_res      text;
  v_res2     text;
  v_res3     text;
  v_res4     text;
  v_res5     text;
  v_json     jsonb;
  v_json2    jsonb;
  v_row      jsonb;
  v_n        integer;
  v_n2       integer;
  v_n3       integer;
begin
  begin
    v_code := 'zzcbb-' || v_tag;
    v_live := 'zzcbl-' || v_tag;
    v_bare := 'zzcbn-' || v_tag;
    v_gone := 'zzcbr-' || v_tag;
    v_leaving := 'zzcbo-' || v_tag;
    v_broken := 'zzcbf-' || v_tag;
    v_owner := 'owner@zzcb-' || v_tag || '.test';

    -- A platform owner, bound by id, and the control plane's marker; both
    -- undone at the end with everything else.
    insert into auth.users (id, email) values (v_uid, v_owner);
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Checklist By Build Suite Owner', 'owner');
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'deployment_checklist_by_build_suite');

    -- Six client deployments: one being built, one live, one requested with
    -- no project yet, one retired, one being offboarded and one whose build
    -- failed.
    v_step := 'registering six client deployments';
    insert into erp_meta.deployment (code, client_name, status, project_ref, owner_email, note)
    values (v_code, 'Being Built Ltd', 'building', 'zzcb' || substr(md5(v_tag || 'b'), 1, 16),
            'admin@' || v_code || '.test', 'deployment_checklist_by_build_suite'),
           (v_live, 'Live Client Ltd', 'live', 'zzcb' || substr(md5(v_tag || 'l'), 1, 16),
            'admin@' || v_live || '.test', 'deployment_checklist_by_build_suite'),
           (v_bare, 'Requested Client Ltd', 'requested', null, null, 'deployment_checklist_by_build_suite'),
           (v_gone, 'Gone Client Ltd', c_retired, 'zzcb' || substr(md5(v_tag || 'r'), 1, 16), null,
            'deployment_checklist_by_build_suite'),
           (v_broken, 'Broken Build Ltd', c_failed, 'zzcb' || substr(md5(v_tag || 'f'), 1, 16), null,
            'deployment_checklist_by_build_suite');
    insert into erp_meta.deployment (code, client_name, status, project_ref, owner_email, note,
                                     offboarding_at, purge_due_at)
    values (v_leaving, 'Leaving Client Ltd', c_retiring, 'zzcb' || substr(md5(v_tag || 'o'), 1, 16), null,
            'deployment_checklist_by_build_suite', now(), now() + interval '30 days');

    -- ── 1. The build ticks what it did ──────────────────────────────────────
    v_step := 'the build ticks the webhook of a client being built';
    v_res := erp_meta.deployment_checklist_by_build(v_code, 'resend_webhook');
    select d.checklist -> 'resend_webhook' into v_json from erp_meta.deployment d where d.code = v_code;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    select x into v_row from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code;
    perform set_config('request.jwt.claims', '', true);
    v_cases := v_cases + 1;
    case_name := 'the build ticks the email provider''s webhook of a client being built: done, by the build, when, and a step in its events, and the Fleet view reads it so';
    passed := v_res = v_code || ': resend_webhook done by the build'
          and v_json ->> 'done' = 'true' and v_json ->> 'by' = c_by
          and (v_json ->> 'at')::timestamptz = now()
          and (select count(*) from erp_meta.deployment_event e
                where e.code = v_code and e.phase = 'checklist' and e.status = 'done'
                  and e.detail = 'resend_webhook done by the build') = 1
          and v_row -> 'checklist' -> 'resend_webhook' ->> 'by' = c_by
          and (v_row -> 'checklist' -> 'resend_webhook' ->> 'done')::boolean
          and not (v_row -> 'checklist' ? 'google_sign_in')
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'building';
    detail := v_res || ' / ' || coalesce(v_json::text, 'nothing ticked') || ' / '
              || coalesce((v_row -> 'checklist')::text, 'no Fleet row');
    return next;

    -- ── 2. Told again ───────────────────────────────────────────────────────
    -- Its time set back, so a second tick would show.
    v_step := 'the build ticks it again, as a build carried on would';
    update erp_meta.deployment d
       set checklist = jsonb_set(d.checklist, '{resend_webhook,at}', to_jsonb(c_before))
     where d.code = v_code;
    v_res := erp_meta.deployment_checklist_by_build(' ' || upper(v_code) || ' ', ' Resend_Webhook ', true);
    select d.checklist -> 'resend_webhook' into v_json from erp_meta.deployment d where d.code = v_code;
    v_cases := v_cases + 1;
    case_name := 'told again, the build changes nothing and says so: the same time, and no second step';
    passed := v_res = v_code || ': resend_webhook was done by the build already'
          and v_json ->> 'at' = c_before and v_json ->> 'by' = c_by and v_json ->> 'done' = 'true'
          and (select count(*) from erp_meta.deployment_event e
                where e.code = v_code and e.phase = 'checklist') = 1;
    detail := v_res || ' / ' || coalesce(v_json::text, 'nothing ticked');
    return next;

    -- ── 3. A person's tick, and the build's ─────────────────────────────────
    v_step := 'a person ticks the webhook of a live client by hand, then the build sets it up';
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    perform public.erp_platform_deployment_checklist(v_live, 'resend_webhook', true);
    perform set_config('request.jwt.claims', '', true);
    update erp_meta.deployment d
       set checklist = jsonb_set(d.checklist, '{resend_webhook,at}', to_jsonb(c_before))
     where d.code = v_live;
    v_got := (select (d.checklist -> 'resend_webhook' ->> 'done') || ' by ' || (d.checklist -> 'resend_webhook' ->> 'by')
                from erp_meta.deployment d where d.code = v_live);
    v_res := erp_meta.deployment_checklist_by_build(v_live, 'resend_webhook');
    v_got2 := (select (d.checklist -> 'resend_webhook' ->> 'done') || ' by ' || (d.checklist -> 'resend_webhook' ->> 'by')
                      || case when (d.checklist -> 'resend_webhook' ->> 'at')::timestamptz = now() then ' now'
                              else ' at ' || (d.checklist -> 'resend_webhook' ->> 'at') end
                 from erp_meta.deployment d where d.code = v_live);
    v_step := 'a person unticks it, and the build''s next run sets it up again; Google sign-in is not the build''s';
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    perform public.erp_platform_deployment_checklist(v_live, 'resend_webhook', false);
    perform set_config('request.jwt.claims', '', true);
    v_got3 := (select (d.checklist -> 'resend_webhook' ->> 'done') || ' by ' || (d.checklist -> 'resend_webhook' ->> 'by')
                 from erp_meta.deployment d where d.code = v_live);
    v_res2 := erp_meta.deployment_checklist_by_build(v_live, 'resend_webhook');
    begin
      perform erp_meta.deployment_checklist_by_build(v_live, 'google_sign_in');
      v_res3 := 'the build ticked Google sign-in';
    exception when others then
      v_res3 := sqlerrm;
    end;
    select d.checklist into v_json from erp_meta.deployment d where d.code = v_live;
    v_cases := v_cases + 1;
    case_name := 'a step a person ticked or unticked is the build''s once the build has done it, a person can still untick it, and Google sign-in is never the build''s to tick';
    passed := v_got = 'true by ' || v_owner
          and v_res = v_live || ': resend_webhook done by the build'
          and v_got2 = 'true by ' || c_by || ' now'
          and v_got3 = 'false by ' || v_owner
          and v_res2 = v_live || ': resend_webhook done by the build'
          and v_res3 like 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN: "google_sign_in" is not a step the build sets up%'
          and v_json -> 'resend_webhook' ->> 'done' = 'true' and v_json -> 'resend_webhook' ->> 'by' = c_by
          and not (v_json ? 'google_sign_in')
          and (select count(*) from erp_meta.deployment_event e
                where e.code = v_live and e.phase = 'checklist' and e.status = 'done'
                  and e.detail like '% done by the build') = 2
          and (select d.status from erp_meta.deployment d where d.code = v_live) = 'live';
    detail := concat_ws(' / ', v_got, v_res, v_got2, v_got3, v_res2, left(v_res3, 90), v_json::text);
    return next;

    -- ── 4. The build unticks what it no longer has ──────────────────────────
    -- The webhook of the client being built is deleted (its proof failed);
    -- told again, with its time set back so a second untick would show; a
    -- failed client never had one; a client being offboarded had one a person
    -- ticked, and one retired had one too, and the fleet's
    -- resend_webhook_delete removes both.
    v_step := 'the build deletes the webhook of a client being built, and says so twice';
    v_res := erp_meta.deployment_checklist_by_build(v_code, 'resend_webhook', false);
    select d.checklist -> 'resend_webhook' into v_json from erp_meta.deployment d where d.code = v_code;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    select x into v_row from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code;
    perform set_config('request.jwt.claims', '', true);
    update erp_meta.deployment d
       set checklist = jsonb_set(d.checklist, '{resend_webhook,at}', to_jsonb(c_before))
     where d.code = v_code;
    v_res2 := erp_meta.deployment_checklist_by_build(v_code, 'resend_webhook', false);
    v_got := (select d.checklist -> 'resend_webhook' ->> 'at' from erp_meta.deployment d where d.code = v_code);
    v_step := 'the build unticks a failed client''s webhook it never made';
    v_res3 := erp_meta.deployment_checklist_by_build(v_broken, 'resend_webhook', false);
    v_step := 'the build deletes the webhooks of a client being offboarded and of one retired';
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    perform public.erp_platform_deployment_checklist(v_leaving, 'resend_webhook', true);
    perform set_config('request.jwt.claims', '', true);
    update erp_meta.deployment d
       set checklist = jsonb_build_object('resend_webhook',
                         jsonb_build_object('done', true, 'at', c_before, 'by', c_by))
     where d.code = v_gone;
    v_res4 := erp_meta.deployment_checklist_by_build(v_leaving, 'resend_webhook', false);
    v_res5 := erp_meta.deployment_checklist_by_build(v_gone, 'resend_webhook', false);
    select jsonb_object_agg(d.code, d.checklist -> 'resend_webhook') into v_json2
      from erp_meta.deployment d where d.code in (v_leaving, v_gone);
    v_cases := v_cases + 1;
    case_name := 'the build unticks the webhook once it has deleted it or left none, in any state, a client being offboarded or retired among them; one not done is left as it is and says so';
    passed := v_res = v_code || ': resend_webhook undone by the build'
          and v_json ->> 'done' = 'false' and v_json ->> 'by' = c_by
          and (v_json ->> 'at')::timestamptz = now()
          and v_row -> 'checklist' -> 'resend_webhook' ->> 'done' = 'false'
          and v_row -> 'checklist' -> 'resend_webhook' ->> 'by' = c_by
          and v_res2 = v_code || ': resend_webhook was not done, and is left as it was'
          and v_got = c_before
          and (select count(*) from erp_meta.deployment_event e
                where e.code = v_code and e.phase = 'checklist' and e.status = 'note'
                  and e.detail = 'resend_webhook undone by the build') = 1
          and v_res3 = v_broken || ': resend_webhook was not done, and is left as it was'
          and (select d.checklist from erp_meta.deployment d where d.code = v_broken) = '{}'::jsonb
          and not exists (select 1 from erp_meta.deployment_event e where e.code = v_broken)
          and v_res4 = v_leaving || ': resend_webhook undone by the build'
          and v_res5 = v_gone || ': resend_webhook undone by the build'
          and v_json2 -> v_leaving ->> 'done' = 'false' and v_json2 -> v_leaving ->> 'by' = c_by
          and v_json2 -> v_gone ->> 'done' = 'false' and v_json2 -> v_gone ->> 'by' = c_by
          and (select d.status from erp_meta.deployment d where d.code = v_leaving) = c_retiring
          and (select d.status from erp_meta.deployment d where d.code = v_gone) = c_retired;
    detail := concat_ws(' / ', v_res, v_json::text, v_res2, v_got, v_res3, v_res4, v_res5, v_json2::text);
    return next;

    -- ── 5. What the build cannot have done ──────────────────────────────────
    v_step := 'asking the build to tick what it cannot have done';
    select count(*) into v_n from erp_meta.deployment_event e
     where e.code in (v_code, v_bare, v_gone, v_leaving, v_broken);
    select jsonb_object_agg(d.code, d.checklist) into v_json from erp_meta.deployment d
     where d.code in (v_code, v_bare, v_gone, v_leaving, v_broken);
    begin
      perform erp_meta.deployment_checklist_by_build('zzcbx-' || v_tag, 'resend_webhook');
      v_got := 'an unknown deployment was ticked';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.deployment_checklist_by_build(v_code, 'dns');
      v_got2 := 'a step the checklist does not have was ticked';
    exception when others then
      v_got2 := sqlerrm;
    end;
    begin
      perform erp_meta.deployment_checklist_by_build(v_code, null);
      v_got3 := 'no step was ticked';
    exception when others then
      v_got3 := sqlerrm;
    end;
    begin
      perform erp_meta.deployment_checklist_by_build(v_bare, 'resend_webhook');
      v_got4 := 'a deployment with no project was ticked';
    exception when others then
      v_got4 := sqlerrm;
    end;
    begin
      perform erp_meta.deployment_checklist_by_build(v_gone, 'resend_webhook');
      v_got5 := 'a retired deployment was ticked';
    exception when others then
      v_got5 := sqlerrm;
    end;
    begin
      perform erp_meta.deployment_checklist_by_build(v_leaving, 'resend_webhook', true);
      v_got6 := 'a deployment being offboarded was ticked';
    exception when others then
      v_got6 := sqlerrm;
    end;
    begin
      perform erp_meta.deployment_checklist_by_build(v_broken, 'resend_webhook');
      v_got7 := 'a deployment whose build failed was ticked';
    exception when others then
      v_got7 := sqlerrm;
    end;
    begin
      perform erp_meta.deployment_checklist_by_build(v_code, 'google_sign_in', false);
      v_got8 := 'the build unticked Google sign-in';
    exception when others then
      v_got8 := sqlerrm;
    end;
    select count(*) into v_n2 from erp_meta.deployment_event e
     where e.code in (v_code, v_bare, v_gone, v_leaving, v_broken);
    v_cases := v_cases + 1;
    case_name := 'the build ticks nothing it cannot have done: an unknown deployment, a step the checklist does not have or the build does not set up, a deployment with no project yet, one retired, one being offboarded or one whose build failed, and nothing changes';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_UNKNOWN%'
          and v_got2 like 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN: "dns" is not a step the build sets up%'
          and v_got3 like 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN: nothing is not a step the build sets up%'
          and v_got4 like 'CLOVEERP_DEPLOYMENT_STATE: ' || v_bare || ' is requested with no project, %'
          and v_got5 like 'CLOVEERP_DEPLOYMENT_STATE: ' || v_gone || ' is retired, %'
          and v_got6 like 'CLOVEERP_DEPLOYMENT_STATE: ' || v_leaving || ' is retiring, %'
          and v_got7 like 'CLOVEERP_DEPLOYMENT_STATE: ' || v_broken || ' is failed, %'
          and v_got8 like 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN: "google_sign_in" is not a step the build sets up%'
          and v_n2 = v_n
          and (select jsonb_object_agg(d.code, d.checklist) from erp_meta.deployment d
                where d.code in (v_code, v_bare, v_gone, v_leaving, v_broken)) = v_json;
    detail := concat_ws(' / ', left(v_got, 60), left(v_got2, 70), left(v_got3, 60), left(v_got4, 90),
                        left(v_got5, 90), left(v_got6, 90), left(v_got7, 90), left(v_got8, 80));
    return next;

    -- ── 6. Only on the control plane ────────────────────────────────────────
    -- The register lives on the control plane; asked anywhere else the build
    -- ticks and unticks nothing.
    v_step := 'asking a client''s own database to tick the webhook';
    update erp_meta.platform_setting set value = '"client"'::jsonb where key = 'deployment.kind';
    select count(*) into v_n from erp_meta.deployment_event e where e.code = v_live;
    select d.checklist into v_json from erp_meta.deployment d where d.code = v_live;
    begin
      perform erp_meta.deployment_checklist_by_build(v_live, 'resend_webhook', true);
      v_got := 'a client''s own database ticked a step of the register';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.deployment_checklist_by_build(v_live, 'resend_webhook', false);
      v_got2 := 'a client''s own database unticked a step of the register';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_got3 := erp.deployment_kind();
    update erp_meta.platform_setting set value = '"production"'::jsonb where key = 'deployment.kind';
    v_cases := v_cases + 1;
    case_name := 'only the control plane keeps the register: on any other database the build ticks and unticks nothing';
    passed := v_got3 = 'client'
          and v_got like 'CLOVEERP_NOT_THE_CONTROL_PLANE%'
          and v_got2 like 'CLOVEERP_NOT_THE_CONTROL_PLANE%'
          and (select count(*) from erp_meta.deployment_event e where e.code = v_live) = v_n
          and (select d.checklist from erp_meta.deployment d where d.code = v_live) = v_json;
    detail := concat_ws(' / ', v_got3, left(v_got, 90), left(v_got2, 90));
    return next;

    -- ── 7. The fleet's own targets are nobody's code ────────────────────────
    v_step := 'asking for all, control and demonstration as a code';
    select count(*) into v_n
      from unnest(array['all', 'control', 'demonstration']) w(word)
     where erp.tenant_code_refusal(w.word, null) like 'CLOVEERP_ADDRESS_RESERVED: "' || w.word || '" is reserved%'
       and erp.tenant_code_refusal(w.word, (select po.tenant_id from erp_meta.platform_organisation po))
           like 'CLOVEERP_ADDRESS_RESERVED%';
    select count(*) into v_n2
      from erp_meta.reserved_tenant_code r
     where r.code in ('all', 'control', 'demonstration') and not r.platform_may_hold;
    select count(*) into v_n3 from erp_meta.deployment d where d.code in ('all', 'control', 'demonstration');
    v_cases := v_cases + 1;
    case_name := 'the fleet''s own targets, all, control and demonstration, are no client deployment''s or organisation''s code, the platform''s own included, and none holds one';
    passed := v_n = 3 and v_n2 = 3 and v_n3 = 0;
    detail := format('%s of 3 refused, %s of 3 reserved for everybody, %s held by a deployment', v_n, v_n2, v_n3);
    return next;

    -- ── 8. Standing ─────────────────────────────────────────────────────────
    v_step := 'reading the routines'' standing';
    select count(*) into v_n
      from pg_catalog.pg_proc p
     where p.oid = pg_catalog.to_regprocedure('erp_meta.deployment_checklist_by_build(text,text,boolean)')
       and pg_catalog.pg_get_function_arguments(p.oid) like '%p_done boolean DEFAULT true'
       and not p.prosecdef and p.provolatile = 'v'
       and p.proacl is not null
       and not exists (select 1 from pg_catalog.aclexplode(p.proacl) a
                        where a.grantee = 0 and a.privilege_type = 'EXECUTE')
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('service_role', p.oid, 'execute');
    select count(*) into v_n2
      from pg_catalog.pg_proc p
     where p.oid in ('erp.record_email_delivery_event(text,text,text,text,timestamptz,text,text,text)'::regprocedure,
                     'erp.record_invitation_email_sent(uuid,text,text)'::regprocedure)
       and not p.prosecdef
       and p.proacl is not null
       and not exists (select 1 from pg_catalog.aclexplode(p.proacl) a
                        where a.grantee = 0 and a.privilege_type = 'EXECUTE')
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('service_role', p.oid, 'execute');
    v_cases := v_cases + 1;
    case_name := 'the build''s routine (three arguments, the last done by default) and the email routines run as their caller and reach no session role, and the draft of two arguments is gone';
    passed := v_n = 1 and v_n2 = 2
          and pg_catalog.to_regprocedure('erp_meta.deployment_checklist_by_build(text,text)') is null;
    detail := format('%s of 1 trusted routine, %s of 2 email routines', v_n, v_n2);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 9. Undone ──────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the suite leaves nothing behind: no deployment, step, staff or person of its own, and the deployment as it was';
  passed := not exists (select 1 from erp_meta.deployment d
                         where d.code in (v_code, v_live, v_bare, v_gone, v_leaving, v_broken))
        and not exists (select 1 from erp_meta.deployment_event e
                         where e.code in (v_code, v_live, v_bare, v_gone, v_leaving, v_broken))
        and not exists (select 1 from erp_meta.platform_staff s where s.email = v_owner)
        and not exists (select 1 from auth.users u where u.id = v_uid)
        and erp.deployment_kind() = v_kind;
  detail := format('deployment kind %s, as before', erp.deployment_kind());
  return next;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DEPLOYMENT_CHECKLIST_BY_BUILD_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_deployment_checklist_by_build_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.deployment_checklist_by_build_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEPLOYMENT_CHECKLIST_BY_BUILD_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The build does not tick a client deployment''s checklist as the Fleet view reads it, or ticks what it cannot have done: read the case that failed.';
  end if;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DEPLOYMENT_CHECKLIST_BY_BUILD_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment checklist by the build: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.deployment_checklist_by_build_suite() from public, anon;
revoke all on function erp_test.assert_deployment_checklist_by_build_suite() from public, anon;

comment on function erp_test.assert_deployment_checklist_by_build_suite() is
  'The build ticks the email provider''s webhook of a client deployment as done by the build, with its time and a '
  'step in its events, and the Fleet view reads it so; told again it changes nothing; a step a person ticked or '
  'unticked is the build''s once the build has done it, a person can still untick it, and Google sign-in is never '
  'the build''s; the build unticks the webhook once it has deleted it, in any state, and leaves one not done as it '
  'is; an unknown deployment, a step the build does not set up, and ticking a deployment with no project, retired, '
  'being offboarded or failed are refused and nothing changes; only the control plane answers; all, control and '
  'demonstration are nobody''s code; the routines run as their caller and reach no session role; and nothing is '
  'left behind (20261012050000).';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
