-- ─────────────────────────────────────────────────────────────────────────────
-- An enquiry that reaches somebody.
--
-- cloveerp.com has had a marketing site and one way to start a conversation: an
-- address in the footer. A mailto: is not a contact form, and the difference is
-- not politeness — it is that nothing records the enquiry, so nobody can say
-- how many arrived, which were answered, or whether the last one was lost in a
-- spam folder.
--
-- Three properties this has to hold, and each is a way the obvious
-- implementation gets it wrong:
--
--  1. A lead is not tenant data. It arrives before there is an organisation,
--     from somebody who is not a principal of anything, so it cannot live in a
--     tenant-scoped table without inventing a tenant to hold it. It belongs to
--     the platform, beside erp_meta.platform_staff and erp_meta.platform_audit,
--     and it is registered platform_internal so row security denies it to
--     everybody the way it denies those.
--
--  2. The visitor is not authenticated, and must not become a way in.
--     erp.assert_public_api_safe() refuses any public.erp_* function executable
--     by anon, absolutely and with no exemption register — "an unauthenticated
--     caller should not reach the product surface at all". That refusal is
--     right and this does not weaken it. The form posts to an Edge Function,
--     which is the boundary; the function holds the service role and calls
--     erp.record_enquiry() from behind it. The product surface stays shut.
--
--  3. "We have received your enquiry" must not be a screen saying so while
--     nothing was sent. This is the fault this codebase keeps finding — a row
--     recording an outcome nothing produced — so the honesty is a constraint
--     rather than a convention: an enquiry may not say it was notified without
--     a provider message id, and may not say notification failed without a
--     reason. erp.assert_enquiries_answerable() then refuses an enquiry that
--     was stored, never notified, and offers no reason why.
--
-- Why the mail is sent directly rather than through §9.2's notification chain,
-- which 20260904920000 has just made work: measured on live, erp.notification
-- holds nought rows and has since it was created, erp.job_run holds nought, and
-- erp_meta.platform_organisation holds nought. Nothing drains that queue there.
-- Routing a lead into it would store the lead and never send it — property 3,
-- broken on the first day. When there is a platform organisation and something
-- draining its queue, this becomes a route like any other; until then the send
-- is direct and says whether it worked.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The record ───────────────────────────────────────────────────────────────

create table if not exists erp_meta.enquiry (
  id                  uuid primary key default gen_random_uuid(),
  submitted_at        timestamptz not null default now(),
  full_name           text not null,
  email               text not null,
  organisation        text,
  message             text not null,
  -- Which page it came from, so a form that starts appearing on a new page is
  -- visible in the leads rather than only in a router diff.
  source_page         text,
  -- A salted digest, never the address. An IP is personal data and the only
  -- thing this needs it for is "has this same visitor just sent forty", which
  -- a digest answers exactly as well.
  ip_hash             text,
  user_agent          text,
  status              text not null default 'new',
  notified_at         timestamptz,
  provider_message_id text,
  failure_reason      text,
  erased_at           timestamptz,

  constraint enquiry_status_check
    check (status in ('new', 'notified', 'notification_failed', 'erased')),

  -- Property 3, in the schema rather than in a comment. 'notified' is a claim
  -- about the outside world, so it may only be made with the provider's own id
  -- for the message; 'notification_failed' is a claim that something went
  -- wrong, so it must say what.
  constraint enquiry_notified_has_provider_id
    check (status <> 'notified'
           or (notified_at is not null and provider_message_id is not null)),
  constraint enquiry_failure_has_reason
    check (status <> 'notification_failed'
           or coalesce(btrim(failure_reason), '') <> ''),
  constraint enquiry_erased_has_timestamp
    check (status <> 'erased' or erased_at is not null),

  -- Bounds, so a form post cannot become a way to fill the disk. Checked here
  -- as well as in erp.record_enquiry() because the door is not the only way in:
  -- the service role can write this table directly.
  constraint enquiry_name_length    check (length(full_name) between 2 and 120),
  constraint enquiry_email_length   check (length(email) between 6 and 254),
  constraint enquiry_message_length check (length(message) between 20 and 4000),
  constraint enquiry_org_length     check (organisation is null or length(organisation) <= 160),
  constraint enquiry_source_length  check (source_page is null or length(source_page) <= 200),
  constraint enquiry_agent_length   check (user_agent is null or length(user_agent) <= 300)
);

comment on table erp_meta.enquiry is
  'An enquiry from the marketing site. Platform data, not tenant data: it '
  'arrives before there is an organisation and from somebody who is not a '
  'principal of one. The status columns are constrained so that a row cannot '
  'claim it was notified without the provider''s id for the message.';

create index if not exists enquiry_submitted_idx
  on erp_meta.enquiry (submitted_at desc);
create index if not exists enquiry_unnotified_idx
  on erp_meta.enquiry (submitted_at) where status = 'new';

select erp_meta.register_table('erp_meta', 'enquiry', 'platform_internal',
  'Enquiries from cloveerp.com. Not tenant data — a lead exists before any '
  'organisation does. Read through the platform console.');

-- Registering a table is not securing it; the generator is what turns the
-- register into row security.
select erp.apply_platform_internal_security();

-- ── The personal data in it, said out loud ───────────────────────────────────
--
-- full_name and email are a person's, so erp.assert_personal_data_register_sound()
-- refuses a schema that holds them without saying how they are erased. They go
-- in the exemption register rather than erp_ref.personal_data_field, and the
-- reason is mechanical rather than a judgement about how personal they are:
-- erp.execute_erasure() resolves a subject to erp.app_user or erp.party_contact
-- inside one tenant, and an enquirer is neither and is in no tenant. Registering
-- these columns there would name an erasure route that cannot reach them —
-- exactly the "records an outcome nothing produced" fault this table's own
-- constraints exist to prevent, one level up.
--
-- The route that does reach them is erp.erase_enquiry(), beside
-- erp_meta.platform_staff, whose columns are exempt for the same reason: these
-- are the platform owner's subjects, and their erasure is the platform owner's
-- process rather than an organisation's.
insert into erp_ref.personal_data_exemption
  (schema_name, table_name, column_name, rationale)
values
  ('erp_meta', 'enquiry', 'full_name',
   'A marketing-site enquirer is nobody''s tenant subject — they have no '
   'organisation and no principal — so erp.execute_erasure() cannot reach '
   'this row. Erased by erp.erase_enquiry(), which redacts in place and sets '
   'status = ''erased'', beside erp_meta.platform_staff.'),
  ('erp_meta', 'enquiry', 'email',
   'The address the enquiry is answered at, and the only way to reply to '
   'somebody who has no account. Erased with the rest of the enquiry by '
   'erp.erase_enquiry(); outside any organisation''s erasure process for the '
   'same reason as erp_meta.platform_staff.email.')
on conflict (schema_name, table_name, column_name) do update
  set rationale = excluded.rationale;

select erp.assert_personal_data_register_sound();

-- ── What may change after the fact, and what may not ─────────────────────────
--
-- An enquiry is somebody's own words. The pipeline has to move status,
-- notified_at, provider_message_id and failure_reason as the mail is attempted,
-- and it has no business editing what was written — an enquiry that can be
-- rewritten is not evidence of anything. Erasure is the one exception and it
-- announces itself: erp.erase_enquiry() opens a window the way a tenant purge
-- does, so a redaction is deliberate rather than an UPDATE that happened to
-- match.

create or replace function erp.guard_enquiry_content()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if nullif(current_setting('erp.erasing_enquiry_id', true), '')::uuid = old.id then
    return new;
  end if;

  if new.full_name is distinct from old.full_name
     or new.email is distinct from old.email
     or new.organisation is distinct from old.organisation
     or new.message is distinct from old.message
     or new.submitted_at is distinct from old.submitted_at then
    raise exception
      'ERPWARE_ENQUIRY_CONTENT_IMMUTABLE: an enquiry is what somebody wrote, not a draft'
      using errcode = '42501',
      hint = 'Move status, notified_at, provider_message_id or failure_reason. '
             'To remove the personal data, call erp.erase_enquiry(), which '
             'redacts it and records that it did.';
  end if;
  return new;
end;
$$;

comment on function erp.guard_enquiry_content() is
  'Refuses an edit to what an enquirer actually wrote. Erasure goes through '
  'erp.erase_enquiry(), which opens a window this reads — the same shape as a '
  'tenant purge, and for the same reason: the exception is announced.';

drop trigger if exists t_enquiry_content_immutable on erp_meta.enquiry;
create trigger t_enquiry_content_immutable
  before update on erp_meta.enquiry
  for each row execute function erp.guard_enquiry_content();

-- ── Taking one in ────────────────────────────────────────────────────────────

create or replace function erp.record_enquiry(
  p_full_name    text,
  p_email        text,
  p_message      text,
  p_organisation text default null,
  p_source_page  text default null,
  p_ip_hash      text default null,
  p_user_agent   text default null)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_id     uuid;
  v_recent integer;
begin
  -- Refusals by name, so the form can say which field to fix rather than
  -- showing somebody a constraint violation.
  if coalesce(btrim(p_full_name), '') = '' or length(btrim(p_full_name)) < 2 then
    raise exception 'ERPWARE_ENQUIRY_NAME_REQUIRED: an enquiry needs a name to reply to'
      using errcode = '22023';
  end if;

  -- Deliberately a shape check and not an attempt at RFC 5322. What makes an
  -- address real is that a message reaches it, which is what the provider's
  -- response tells us; this only refuses what obviously cannot be one.
  if p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$' then
    raise exception 'ERPWARE_ENQUIRY_EMAIL_INVALID: that does not look like an email address'
      using errcode = '22023';
  end if;

  if length(coalesce(btrim(p_message), '')) < 20 then
    raise exception
      'ERPWARE_ENQUIRY_MESSAGE_TOO_SHORT: say a little about what you need, so somebody can answer usefully'
      using errcode = '22023';
  end if;

  -- One visitor, one hour, five enquiries. Not a defence against a determined
  -- flood — that belongs at the edge — but enough that an accidental double
  -- submit or a bored script does not fill the table, and it refuses rather
  -- than silently discarding, so the caller can say what happened.
  if p_ip_hash is not null then
    select count(*) into v_recent
      from erp_meta.enquiry e
     where e.ip_hash = p_ip_hash
       and e.submitted_at > now() - interval '1 hour';
    if v_recent >= 5 then
      raise exception
        'ERPWARE_ENQUIRY_RATE_LIMITED: several enquiries have come from here in the last hour'
        using errcode = '53400',
        hint = 'Reply to the last one rather than sending another, or write to '
               'the address in the footer.';
    end if;
  end if;

  insert into erp_meta.enquiry
    (full_name, email, organisation, message, source_page, ip_hash, user_agent)
  values (btrim(p_full_name), lower(btrim(p_email)),
          nullif(btrim(coalesce(p_organisation, '')), ''),
          btrim(p_message),
          nullif(btrim(coalesce(p_source_page, '')), ''),
          p_ip_hash,
          left(nullif(btrim(coalesce(p_user_agent, '')), ''), 300))
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function erp.record_enquiry(text, text, text, text, text, text, text)
  from public, anon;

comment on function erp.record_enquiry(text, text, text, text, text, text, text) is
  'Stores one enquiry from the marketing site and returns its id. Called by the '
  'enquiry Edge Function behind the service role — never by anon, which is why '
  'no public.erp_* door wraps it.';

-- ── Who hears about it ───────────────────────────────────────────────────────
--
-- Read from the register rather than written into the code. An address in a
-- function body is one that stays right until somebody leaves.

create or replace function erp.enquiry_recipients()
returns table (email text, display_name text)
language sql
stable
set search_path to ''
as $$
  -- Owners first, because a lead is a commercial matter and an owner is who
  -- answers for one. If nobody holds owner — which would itself be a finding —
  -- every unrevoked staff member is told rather than nobody.
  select s.email, s.display_name
    from erp_meta.platform_staff s
   where s.revoked_at is null
     and (s.staff_role = 'owner'
          or not exists (select 1 from erp_meta.platform_staff o
                          where o.revoked_at is null and o.staff_role = 'owner'))
   order by s.email
$$;

revoke all on function erp.enquiry_recipients() from public, anon;

comment on function erp.enquiry_recipients() is
  'Who is told about a new enquiry, from erp_meta.platform_staff. A list in a '
  'function body is a list that stays right until somebody leaves.';

-- ── Saying what happened to the message ──────────────────────────────────────

create or replace function erp.complete_enquiry_notice(
  p_id uuid, p_provider_message_id text)
returns void
language plpgsql
set search_path to ''
as $$
begin
  if coalesce(btrim(p_provider_message_id), '') = '' then
    raise exception
      'ERPWARE_ENQUIRY_NOTICE_UNIDENTIFIED: an enquiry is not notified until a provider names the message'
      using errcode = '22023',
      hint = 'This is the same rule erp.complete_email() holds: "sent" must '
             'mean somebody accepted it, not that we meant to send it.';
  end if;

  update erp_meta.enquiry
     set status = 'notified', notified_at = now(),
         provider_message_id = btrim(p_provider_message_id),
         failure_reason = null
   where id = p_id;

  if not found then
    raise exception 'ERPWARE_ENQUIRY_NOT_FOUND: no enquiry %', p_id
      using errcode = '23503';
  end if;
end;
$$;

revoke all on function erp.complete_enquiry_notice(uuid, text) from public, anon;

create or replace function erp.fail_enquiry_notice(p_id uuid, p_reason text)
returns void
language plpgsql
set search_path to ''
as $$
begin
  update erp_meta.enquiry
     set status = 'notification_failed',
         -- Bounded, and never the request headers: a reason is read on a
         -- screen, so it must not be a place a credential can land.
         failure_reason = left(coalesce(nullif(btrim(p_reason), ''), 'unknown'), 500)
   where id = p_id;

  if not found then
    raise exception 'ERPWARE_ENQUIRY_NOT_FOUND: no enquiry %', p_id
      using errcode = '23503';
  end if;
end;
$$;

revoke all on function erp.fail_enquiry_notice(uuid, text) from public, anon;

-- ── Erasure ──────────────────────────────────────────────────────────────────

create or replace function erp.erase_enquiry(p_id uuid, p_reason text)
returns void
language plpgsql
set search_path to ''
as $$
begin
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'ERPWARE_REASON_REQUIRED: say why this enquiry is being erased'
      using errcode = '22023';
  end if;

  perform set_config('erp.erasing_enquiry_id', p_id::text, true);

  -- Redacted in place rather than deleted. The row is what says an enquiry
  -- arrived on that day and was answered or was not; removing it would make
  -- the record of what the platform received depend on who asked to be
  -- forgotten.
  update erp_meta.enquiry
     set full_name = '(erased)', email = '(erased)', organisation = null,
         message = '(erased at the enquirer''s request: ' || left(btrim(p_reason), 200) || ')',
         ip_hash = null, user_agent = null,
         status = 'erased', erased_at = now()
   where id = p_id and status <> 'erased';

  if not found then
    raise exception
      'ERPWARE_ENQUIRY_NOT_FOUND: no enquiry % that has not already been erased', p_id
      using errcode = '23503';
  end if;

  perform set_config('erp.erasing_enquiry_id', '', true);
end;
$$;

revoke all on function erp.erase_enquiry(uuid, text) from public, anon;

-- ── What is on the screen, and what nobody has answered ──────────────────────

create or replace function erp.enquiry_report(p_limit integer default 200)
returns table (
  id uuid, submitted_at timestamptz, full_name text, email text,
  organisation text, message text, source_page text,
  status text, notified_at timestamptz, failure_reason text)
language sql
stable
set search_path to ''
as $$
  select e.id, e.submitted_at, e.full_name, e.email, e.organisation, e.message,
         e.source_page, e.status, e.notified_at, e.failure_reason
    from erp_meta.enquiry e
   order by e.submitted_at desc
   limit greatest(coalesce(p_limit, 200), 1)
$$;

revoke all on function erp.enquiry_report(integer) from public, anon;

create or replace function erp.unanswered_enquiry_report()
returns table (id uuid, submitted_at timestamptz, email text, detail text)
language sql
stable
set search_path to ''
as $$
  -- An enquiry that was stored, was never notified, and says no reason why.
  -- Fifteen minutes because the send is attempted in the same request that
  -- stores it: anything still here after that is a pipeline that stopped,
  -- not one that is busy.
  select e.id, e.submitted_at, e.email,
         'stored ' || age(now(), e.submitted_at)::text ||
         ' ago, never notified, and nothing says why'
    from erp_meta.enquiry e
   where e.status = 'new'
     and e.submitted_at < now() - interval '15 minutes'
   order by e.submitted_at
$$;

revoke all on function erp.unanswered_enquiry_report() from public, anon;

create or replace function erp.assert_enquiries_answerable()
returns text
language plpgsql
stable
set search_path to ''
as $$
declare v_count int; v_detail text;
begin
  select count(*), string_agg(format('  %s (%s) — %s', r.id, r.email, r.detail), E'\n')
    into v_count, v_detail
    from erp.unanswered_enquiry_report() r;

  if v_count > 0 then
    raise exception E'ERPWARE_ENQUIRY_UNANSWERED: % enquir(ies) reached nobody\n%',
      v_count, v_detail
      using errcode = 'P0001',
      hint = 'The enquiry function stores and then sends, and records either a '
             'provider message id or a reason. A row still saying ''new'' means '
             'the send was never attempted — the function died between the two, '
             'or something wrote this table directly.';
  end if;

  return format('enquiries: %s stored, %s notified, %s failed with a reason given',
                (select count(*) from erp_meta.enquiry),
                (select count(*) from erp_meta.enquiry where status = 'notified'),
                (select count(*) from erp_meta.enquiry where status = 'notification_failed'));
end;
$$;

revoke all on function erp.assert_enquiries_answerable() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('enquiries_answerable', 'Every enquiry reached somebody, or says why not',
   'assertion', 'platform', 'erp', 'assert_enquiries_answerable', '',
   'unanswered_enquiry_report', '',
   'A contact form that stores a lead and tells nobody is worse than no form: '
   'the sender believes they have been heard. This refuses an enquiry left '
   'with no notification and no reason.', true,
   (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;

-- ── The doors the platform console reads them through ────────────────────────

create or replace function public.erp_platform_enquiries(p_limit integer default 200)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'submitted_at', r.submitted_at,
             'full_name', r.full_name, 'email', r.email,
             'organisation', r.organisation, 'message', r.message,
             'source_page', r.source_page, 'status', r.status,
             'notified_at', r.notified_at, 'failure_reason', r.failure_reason)
           order by r.submitted_at desc)
      from erp.enquiry_report(p_limit) r), '[]'::jsonb);
end;
$$;

revoke all on function public.erp_platform_enquiries(integer) from public, anon;
grant execute on function public.erp_platform_enquiries(integer) to authenticated, service_role;

create or replace function public.erp_platform_erase_enquiry(p_id uuid, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('owner');
  perform erp.erase_enquiry(p_id, p_reason);
  perform erp_meta.platform_log(v, 'platform.enquiry_erased', null, null, p_reason,
                                jsonb_build_object('enquiry_id', p_id));
  return jsonb_build_object('enquiry_id', p_id, 'erased', true);
end;
$$;

revoke all on function public.erp_platform_erase_enquiry(uuid, text) from public, anon;
grant execute on function public.erp_platform_erase_enquiry(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_platform_enquiries', 'erp_meta.require_platform',
   'Reads the enquiries the marketing site has taken. Platform staff only, and '
   'volatile because the gate binds the staff identity on first use.'),
  ('erp_platform_erase_enquiry', 'erp_meta.require_platform',
   'Redacts one enquiry at the enquirer''s request. Owner only, and recorded in '
   'erp_meta.platform_audit, because erasing somebody''s words is an act that '
   'must leave a trace of who did it and why.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values
  ('public', 'erp_platform_enquiries',
   'erp_meta.enquiry is platform_internal, which row security denies to every '
   'role including authenticated. Platform staff reach it through this door, '
   'which gates on erp_meta.require_platform before it reads a single row.'),
  ('public', 'erp_platform_erase_enquiry',
   'Same reason, and a narrower gate: owner rather than support, because a '
   'redaction cannot be undone.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_enquiries_answerable();
select erp.assert_diagnostics_registered();

-- ── The suite ────────────────────────────────────────────────────────────────
--
-- Every case here is about a way this could record something that did not
-- happen, because that is the failure a contact form makes worst: the sender
-- has already been told their message was received.

create or replace function erp_test.enquiry_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id     uuid;
  v_stale  uuid;
  v_ok     boolean;
  v_msg    text;
  v_n      int;
  v_cases  int := 0;
  c_msg constant text :=
    'We run three sites and need stock, purchasing and the ledger in one place.';
begin
  -- ── It refuses what it cannot answer ──────────────────────────────────────

  v_cases := v_cases + 1;
  begin
    perform erp.record_enquiry('A', 'someone@example.test', c_msg);
    v_ok := false; v_msg := 'a one-character name was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ENQUIRY_NAME_REQUIRED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an enquiry with no real name is refused by name'::text, v_ok, v_msg;

  v_cases := v_cases + 1;
  begin
    perform erp.record_enquiry('Dana Okafor', 'dana at example', c_msg);
    v_ok := false; v_msg := 'an address with no @ was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ENQUIRY_EMAIL_INVALID%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and one with nowhere to reply to'::text, v_ok, v_msg;

  v_cases := v_cases + 1;
  begin
    perform erp.record_enquiry('Dana Okafor', 'dana@example.test', 'call me');
    v_ok := false; v_msg := 'a two-word message was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ENQUIRY_MESSAGE_TOO_SHORT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and one nobody could answer usefully'::text, v_ok, v_msg;

  -- ── It stores one ─────────────────────────────────────────────────────────

  v_cases := v_cases + 1;
  v_id := erp.record_enquiry('Dana Okafor', 'DANA@Example.TEST', c_msg,
                             'Okafor Foods', '/contact', 'zzhash-1', 'suite/1.0');
  return query select 'an enquiry is stored, and starts owing somebody a reply'::text,
    (select e.status = 'new' and e.email = 'dana@example.test'
              and e.organisation = 'Okafor Foods' and e.notified_at is null
       from erp_meta.enquiry e where e.id = v_id),
    'lower-cased on the way in, so the same person twice is the same address';

  -- ── It cannot claim a delivery it did not get ─────────────────────────────

  v_cases := v_cases + 1;
  begin
    perform erp.complete_enquiry_notice(v_id, '  ');
    v_ok := false; v_msg := 'notified with no provider id';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ENQUIRY_NOTICE_UNIDENTIFIED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'it cannot be marked notified without the provider naming the message'::text,
    v_ok, v_msg;

  v_cases := v_cases + 1;
  begin
    update erp_meta.enquiry set status = 'notified', notified_at = now()
     where id = v_id;
    v_ok := false; v_msg := 'the constraint let a bare status through';
  exception when others then
    v_ok := sqlerrm like '%enquiry_notified_has_provider_id%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and not by writing the column directly either'::text, v_ok, v_msg;

  v_cases := v_cases + 1;
  begin
    update erp_meta.enquiry set status = 'notification_failed' where id = v_id;
    v_ok := false; v_msg := 'a failure with no reason was accepted';
  exception when others then
    v_ok := sqlerrm like '%enquiry_failure_has_reason%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a failure that does not say why is not a failure report'::text,
    v_ok, v_msg;

  -- ── What somebody wrote stays what they wrote ─────────────────────────────

  v_cases := v_cases + 1;
  begin
    update erp_meta.enquiry set message = 'something else entirely' where id = v_id;
    v_ok := false; v_msg := 'the message was rewritten';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ENQUIRY_CONTENT_IMMUTABLE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an enquiry''s own words cannot be edited afterwards'::text,
    v_ok, v_msg;

  -- ── The two honest outcomes ───────────────────────────────────────────────

  v_cases := v_cases + 1;
  perform erp.complete_enquiry_notice(v_id, 'resend-zz-0001');
  return query select 'with a provider id it is notified, and says when'::text,
    (select e.status = 'notified' and e.notified_at is not null
              and e.provider_message_id = 'resend-zz-0001'
       from erp_meta.enquiry e where e.id = v_id),
    'the id is what lets a later bounce be matched back to this enquiry';

  v_cases := v_cases + 1;
  perform erp.fail_enquiry_notice(v_id, 'resend responded 403: domain not verified');
  return query select 'and a send that failed says so, with the reason'::text,
    (select e.status = 'notification_failed'
              and e.failure_reason like 'resend responded 403%'
       from erp_meta.enquiry e where e.id = v_id),
    'a lead nobody was told about is still a lead somebody must answer';

  -- ── The assertion is not vacuous ──────────────────────────────────────────
  --
  -- Built directly and backdated, because the point is a row the pipeline
  -- never finished with: erp.record_enquiry() stores and the caller sends in
  -- the same request, so the only way to have one is for that caller to die.

  v_cases := v_cases + 1;
  insert into erp_meta.enquiry (full_name, email, message, submitted_at)
  values ('Stale Enquirer', 'stale@example.test', c_msg, now() - interval '2 hours')
  returning id into v_stale;

  begin
    perform erp.assert_enquiries_answerable();
    v_ok := false; v_msg := 'an enquiry that reached nobody passed the assertion';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ENQUIRY_UNANSWERED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an enquiry stored two hours ago and never sent is a finding'::text,
    v_ok, v_msg;

  v_cases := v_cases + 1;
  perform erp.fail_enquiry_notice(v_stale, 'the suite: proving the assertion clears');
  return query select 'and saying why clears it'::text,
    erp.assert_enquiries_answerable() like 'enquiries:%',
    'the assertion is about silence, not about failure — a failure that is '
    'recorded is a lead somebody can still act on';

  -- ── Erasure ───────────────────────────────────────────────────────────────

  v_cases := v_cases + 1;
  begin
    perform erp.erase_enquiry(v_id, '   ');
    v_ok := false; v_msg := 'erased with no reason';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REASON_REQUIRED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an erasure has to say why'::text, v_ok, v_msg;

  v_cases := v_cases + 1;
  perform erp.erase_enquiry(v_id, 'the enquirer asked us to remove their details');
  return query select 'and it redacts the person while keeping that an enquiry arrived'::text,
    (select e.full_name = '(erased)' and e.email = '(erased)'
              and e.ip_hash is null and e.status = 'erased'
              and e.erased_at is not null and e.submitted_at is not null
       from erp_meta.enquiry e where e.id = v_id),
    'deleting the row would make the record of what arrived depend on who '
    'asked to be forgotten';

  -- ── Who gets told ─────────────────────────────────────────────────────────

  v_cases := v_cases + 1;
  insert into erp_meta.platform_staff (email, display_name, staff_role)
  values ('zzowner@zzenq.test', 'Enquiry Suite Owner', 'owner'),
         ('zzsupport@zzenq.test', 'Enquiry Suite Support', 'support');
  select count(*) into v_n from erp.enquiry_recipients() r
   where r.email like '%@zzenq.test';
  return query select 'an owner is told and a support account is not'::text,
    v_n = 1 and exists (select 1 from erp.enquiry_recipients() r
                         where r.email = 'zzowner@zzenq.test'),
    format('%s of the suite''s two staff rows are recipients — a lead is a '
           'commercial matter and an owner answers for one', v_n);

  -- ── The rate limit ────────────────────────────────────────────────────────

  v_cases := v_cases + 1;
  for v_n in 1..5 loop
    perform erp.record_enquiry(format('Repeat %s', v_n),
                               format('repeat%s@example.test', v_n),
                               c_msg, null, '/contact', 'zzhash-flood');
  end loop;
  begin
    perform erp.record_enquiry('Repeat 6', 'repeat6@example.test', c_msg,
                               null, '/contact', 'zzhash-flood');
    v_ok := false; v_msg := 'a sixth enquiry in the hour was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ENQUIRY_RATE_LIMITED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a sixth enquiry from one visitor in an hour is refused, not discarded'::text,
    v_ok, v_msg || ' — refusing tells the sender; discarding tells nobody';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  delete from erp_meta.enquiry
   where email like '%@example.test' or email = '(erased)'
      or ip_hash in ('zzhash-1', 'zzhash-flood');
  delete from erp_meta.platform_staff where email like '%@zzenq.test';

  v_cases := v_cases + 1;
  return query select 'the suite leaves nothing behind'::text,
    not exists (select 1 from erp_meta.enquiry e where e.ip_hash = 'zzhash-flood')
      and not exists (select 1 from erp_meta.platform_staff s
                       where s.email like '%@zzenq.test'),
    'and the assertion is quiet again: ' || erp.assert_enquiries_answerable();

  if v_cases <> 17 then
    raise exception 'ERPWARE_SUITE_SHRANK: enquiry_suite ran % cases, expected 17', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.enquiry_suite() from public, anon;

create or replace function erp_test.assert_enquiry_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _enq on commit drop as
    select * from erp_test.enquiry_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail from _enq;
  if v_fail > 0 then
    raise exception E'ERPWARE_ENQUIRY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001',
      hint = 'The contact form records an outcome it did not produce, or refuses '
             'one it should have taken.';
  end if;
  return format('enquiries: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_enquiry_suite() from public, anon;

select erp_test.assert_enquiry_suite();
