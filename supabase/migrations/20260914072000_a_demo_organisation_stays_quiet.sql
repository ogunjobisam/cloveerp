-- A demonstration organisation stays quiet.
--
-- The desk was walked in a demonstration organisation on the morning of
-- 14 September. Each finding below was checked against the definitions the
-- database carries after every patch before this file, and each was true.
--
--   1. A demonstration emailed the platform owner. "Build a year of trading
--      history" submits and approves orders through the spine. Since
--      20260914062000 each order opens an approval task, and before go-live
--      the task goes to the one person there is: whoever is building. The
--      trigger 20260913121000 put on erp.approval_task announced every task,
--      the product route approval_task_assigned carried it by email, and the
--      dispatch drain sent it. Between sixty and a hundred "Approval requested"
--      emails went out about documents dated last year. Nothing anywhere knew
--      that an organisation is a demonstration: the only mark is the code
--      erp.seed_demo() gives it, demo- and eight hex digits, which the desk
--      already reads for the same purpose (the trading history panel, the demo
--      seed card, adoption). There is no kind or flag on erp.tenant.
--
--   2. The trading history timed out. The builder built five days per call,
--      measured in September at under two seconds with nothing else running.
--      Every order now also opens, decides and closes approval tasks, and every
--      delivery reads what is left to deliver (20260914064000), so a five-day
--      slice runs close to the eight seconds a signed-in caller has. Some
--      slices passed and some did not, which is why each retry advanced a few
--      weeks before failing again.
--
--   3. The seeded viewer, Dana, read "Invitation expired" the moment the demo
--      was made. erp.seed_demo() inserts her as invited with no invitation at
--      all, a state no product path produces: erp.invite_principal always
--      writes one. The directory (20260914020000) says 'none' for it and the
--      desk shows an invited person with no open invitation as expired, which
--      is right for everybody else.
--
--   4. The base pack's first approval band asked for its threshold "in minor
--      units, e.g. 500000 for £5,000". The Plan screen now asks in pounds and
--      sends pence, so the prompt stops saying otherwise.
--
-- What this file does, in order:
--
--   1. erp.tenant_is_demonstration(tenant): the code starts demo-.
--
--   2. A notification in a demonstration is delivered in the product only.
--      At the source: a BEFORE INSERT trigger on erp.notification writes every
--      row for a demonstration on the in_app channel, whatever the route asked
--      for and whatever the person chose, so every writer is covered (the
--      organisation's routes, the product's routes, digests, escalations, the
--      in-app copy of a failure) and one added later is too. At the queue:
--      erp.claim_email_batch() and erp.claim_webhook_batch() hand a sender
--      nothing for a demonstration, so a row queued before this release, or
--      moved there by a writer that forgot, never leaves. sms and push are
--      refused by name everywhere already (20260906144000). An invitation in a
--      demonstration is not emailed either: erp.claim_invitation_email()
--      answers no with the reason, and the invite function then shows the link
--      to copy, as it does whenever an email is not sent. The dispatch worker
--      and the dispatch function send only what those claims return, so the
--      database is the only gate and neither needs one of its own. Existing
--      demonstrations: email and webhook messages still waiting are moved to
--      in-app here.
--
--   3. Nobody is told about a task on an approval they asked for themselves.
--      Before go-live that is every task the demonstration builders open, and
--      every order a lone installer submits: they are the person acting, and
--      "Nobody needs an email about what they have just done" is already the
--      product routes' rule for a role. A task delegated or escalated to them
--      is still announced, because somebody else put it there. Once live a
--      document's requester is never asked (20260914062000), so there this
--      changes nothing for documents.
--
--   4. The trading history is built one day at a time. Each day is its own
--      slice, keyed DEMO-YYYYMMDD- as before and skipped when it exists. A call
--      builds at most five days, and under a statement timeout it starts no new
--      day once a quarter of that timeout has gone, so a signed-in call ends
--      after roughly two seconds plus one day, and says where the next call
--      starts. A build role with no timeout still builds five days per call,
--      which is what the suites and supabase/ci/seed_demo.sql ask for. Days
--      inside a five-day slice built before this release are skipped too: such
--      a slice holds an order dated after the day it is named by, which a
--      day's slice never does. The daily count of each kind of document is the
--      old weekly rate spread over days, drawn so that its average is the rate.
--      Each patch is a counted replacement of the body as it stands.
--
--   5. erp.seed_demo() gives Dana a pending invitation, open for thirty days.
--      Nobody can accept it; the People panel shows her invited, with the date
--      her link would expire. Existing demonstrations get one where she has
--      none.
--
--   6. The first band's prompt drops its minor units, and every new word the
--      desk shows has a row it can be renamed by.
--
-- Not changed: erp.seed_demo_operations() builds a handful of documents in one
-- call and is left as it is; its tasks are the requester's and go unannounced.
-- The outbox and commands are drained only for organisations an operator names
-- in CLOVEERP_TENANTS, and a demonstration is never named there.
--
-- Proof: erp_test.demo_stays_quiet_suite(), thirteen cases, pinned by its
-- wrapper; and, run here because they drive what changed, the demo history,
-- demo chart, notification product routes, email delivery and webhook
-- delivery suites. The build runs every other suite as it always does.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A demonstration is known by its code
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.tenant_is_demonstration(p_tenant_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  -- No fallback to the organisation in context: a caller names the one it
  -- means, and a trusted connection with no context still gets an answer.
  select exists (select 1 from erp.tenant t
                  where t.id = p_tenant_id
                    and t.code like 'demo-%');
$$;

revoke all on function erp.tenant_is_demonstration(uuid) from public, anon, authenticated;

comment on function erp.tenant_is_demonstration(uuid) is
  'Whether the organisation is a demonstration: its code begins demo-, which '
  'erp.seed_demo() gives every organisation it makes and nothing else does. The '
  'desk reads the same mark. A demonstration sends nothing outside the product.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A notification in a demonstration is delivered in the product only
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.keep_demonstration_notification_in_app()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  -- Whatever the route asked for and whatever the person chose: a
  -- demonstration's messages are read in the product, where in-app always
  -- works, and no email, text, push or webhook is ever queued for one.
  if new.channel_kind <> 'in_app' and erp.tenant_is_demonstration(new.tenant_id) then
    new.channel_kind := 'in_app';
    new.sender := null;
  end if;
  return new;
end;
$$;

revoke all on function erp.keep_demonstration_notification_in_app() from public, anon, authenticated;

comment on function erp.keep_demonstration_notification_in_app() is
  'Writes every notification for a demonstration organisation on the in_app '
  'channel, before it is inserted, so no writer can queue an external message '
  'for one. erp.claim_email_batch() and erp.claim_webhook_batch() refuse a '
  'demonstration as well.';

drop trigger if exists t_notification_demonstration_in_app on erp.notification;
create trigger t_notification_demonstration_in_app
  before insert on erp.notification
  for each row execute function erp.keep_demonstration_notification_in_app();

-- The email queue hands a sender nothing for a demonstration.
do $email$
declare
  v_sig text := 'erp.claim_email_batch(integer,text)';
  v_def text := pg_get_functiondef('erp.claim_email_batch(integer,text)'::regprocedure);
  v_old text := $o$  if erp.is_killed('integration', 'email') then
    return;
  end if;
$o$;
  v_new text := $r$  if erp.is_killed('integration', 'email') then
    return;
  end if;

  -- A demonstration sends nothing outside the product (20260914072000). Its
  -- notifications are written in-app; one queued before that, or moved here
  -- by a writer that forgot, is never handed to a sender.
  if erp.tenant_is_demonstration(v_tenant) then
    return;
  end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('tenant_is_demonstration' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260906112000 body this migration patches', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
  if position('erp.tenant_is_demonstration(v_tenant)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its demonstration refusal', v_sig;
  end if;
end
$email$;

-- And so does the webhook queue.
do $webhook$
declare
  v_sig text := 'erp.claim_webhook_batch(integer,text)';
  v_def text := pg_get_functiondef('erp.claim_webhook_batch(integer,text)'::regprocedure);
  v_old text := $o$  if erp.is_killed('integration', 'webhook') then
    return;
  end if;
$o$;
  v_new text := $r$  if erp.is_killed('integration', 'webhook') then
    return;
  end if;

  -- A demonstration sends nothing outside the product (20260914072000).
  if erp.tenant_is_demonstration(v_tenant) then
    return;
  end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('tenant_is_demonstration' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260906144000 body this migration patches', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
  if position('erp.tenant_is_demonstration(v_tenant)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its demonstration refusal', v_sig;
  end if;
end
$webhook$;

-- An invitation in a demonstration is not emailed. Asked once the organisation
-- is named (20260914011000), before any count is read or any row written, so
-- nothing is spent from the budget.
do $invitation$
declare
  v_sig text := 'erp.claim_invitation_email(uuid,text,uuid)';
  v_def text := pg_get_functiondef('erp.claim_invitation_email(uuid,text,uuid)'::regprocedure);
  v_old text := $o$  perform erp.set_job_tenant(v_tenant);
$o$;
  v_new text := $r$  perform erp.set_job_tenant(v_tenant);

  -- A demonstration sends nothing outside the product (20260914072000). The
  -- invitation stands and the person inviting copies its link.
  if erp.tenant_is_demonstration(v_tenant) then
    return query select false, 'A demonstration organisation sends no email'::text;
    return;
  end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('tenant_is_demonstration' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914011000 body this migration patches', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
  if position('erp.tenant_is_demonstration(v_tenant)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its demonstration refusal', v_sig;
  end if;
end
$invitation$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Nobody is told about a task on an approval they asked for themselves
-- ═════════════════════════════════════════════════════════════════════════════

do $announce$
declare
  v_sig text := 'erp.announce_approval_task()';
  v_def text := pg_get_functiondef('erp.announce_approval_task()'::regprocedure);
  v_old text := $o$  select * into q
    from erp.approval_request ar
   where ar.tenant_id = new.tenant_id and ar.id = new.approval_request_id;
$o$;
  v_new text := $r$  select * into q
    from erp.approval_request ar
   where ar.tenant_id = new.tenant_id and ar.id = new.approval_request_id;

  -- Nobody is told about a task on an approval they asked for themselves
  -- (20260914072000): they are the person acting. Before go-live that is every
  -- task a lone installer or a demonstration builder opens. A task somebody
  -- delegated or escalated to them is still announced.
  if new.delegated_from is null and new.escalated_from is null
     and new.assignee_user_id = coalesce(q.requested_by, q.created_by) then
    return null;
  end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('asked for themselves' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260913121000 body this migration patches', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
  if position('asked for themselves' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without the requester rule', v_sig;
  end if;
end
$announce$;

comment on function erp.announce_approval_task() is
  'Raises approval.task_assigned, or approval.task_escalated for a task opened by '
  'escalation, naming the assignee in recipient_ids, for every pending task with '
  'an assignee, except a task on an approval its assignee asked for themselves '
  'that nobody delegated or escalated to them. The product route that carries it '
  'emails the person who must act.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The seeded viewer holds an invitation
-- ═════════════════════════════════════════════════════════════════════════════

do $seed$
declare
  v_sig text := 'erp.seed_demo()';
  v_def text := pg_get_functiondef('erp.seed_demo()'::regprocedure);
  v_old text := $o$  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, null, 'person'::erp.principal_kind, 'invited'::erp.principal_status,
          'Dana Viewer', 'dana.viewer@example.invalid')
  returning id into v_viewer_id;
$o$;
  v_new text := $r$  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
  values (v_tenant_id, null, 'person'::erp.principal_kind, 'invited'::erp.principal_status,
          'Dana Viewer', 'dana.viewer@example.invalid')
  returning id into v_viewer_id;

  -- Invited people hold an invitation (20260914072000). Without one the People
  -- panel read "Invitation expired" the moment the demonstration was made. Its
  -- token is never returned, so nobody can accept it; thirty days, so the
  -- demonstration shows an invitation waiting rather than one that lapsed.
  insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
  values (v_tenant_id, v_viewer_id,
          encode(extensions.digest(encode(extensions.gen_random_bytes(32), 'hex'), 'sha256'), 'hex'),
          now() + interval '30 days');
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('erp.invitation' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260905010000 body this migration patches', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
  if position('insert into erp.invitation' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without the viewer''s invitation', v_sig;
  end if;
end
$seed$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Existing demonstrations: waiting messages stay in the product, and the
--    viewer holds an invitation
-- ═════════════════════════════════════════════════════════════════════════════

do $existing$
declare
  t          record;
  v_moved    integer;
  v_invited  integer;
  v_messages integer := 0;
  v_viewers  integer := 0;
begin
  for t in select tn.id, tn.code from erp.tenant tn where tn.code like 'demo-%' order by tn.code loop
    -- Each organisation's writes in its own context, as nobody.
    perform set_config('erp.job_tenant_id', t.id::text, true);
    perform set_config('erp.job_principal_id', '', true);

    -- Not what a worker holds now (sending): that one has already left. What
    -- waits is moved to in-app, where the next dispatch pass delivers it.
    update erp.notification n
       set channel_kind     = 'in_app',
           status           = case when n.status = 'queued' then 'pending' else n.status end,
           sender           = null,
           claimed_by       = null,
           claimed_at       = null,
           lease_expires_at = null
     where n.tenant_id = t.id
       and n.channel_kind <> 'in_app'
       and n.status in ('pending', 'held', 'queued');
    get diagnostics v_moved = row_count;
    v_messages := v_messages + v_moved;

    insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
    select t.id, u.id,
           encode(extensions.digest(encode(extensions.gen_random_bytes(32), 'hex'), 'sha256'), 'hex'),
           now() + interval '30 days'
      from erp.app_user u
     where u.tenant_id = t.id
       and u.kind = 'person' and u.status = 'invited' and u.auth_user_id is null
       and lower(u.email) = 'dana.viewer@example.invalid'
       and not exists (select 1 from erp.invitation i
                        where i.tenant_id = t.id and i.app_user_id = u.id
                          and i.claimed_at is null and i.revoked_at is null);
    get diagnostics v_invited = row_count;
    v_viewers := v_viewers + v_invited;
  end loop;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);

  raise notice 'demonstrations: % waiting message(s) moved to in-app, % seeded viewer(s) given an invitation',
    v_messages, v_viewers;
end
$existing$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Trading history, one day at a time
-- ═════════════════════════════════════════════════════════════════════════════

do $history$
declare
  v_sig   text := 'erp.seed_demo_history(date,date,numeric)';
  v_def   text := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  v_hits  integer;

  -- The day's variables.
  v_old1  text := $o1$  v_span     integer;
$o1$;
  v_new1  text := $r1$  v_span     integer;
  -- One day at a time (20260914072000)
  v_first      date;
  v_last       date;
  v_day        date;
  v_through    date;
  v_offset     integer;
  v_skipped    integer := 0;
  v_timeout_ms bigint;
$r1$;

  -- The slice becomes a loop over its days.
  v_old2  text := $o2$  -- Five days per call. Measured locally a peak-season week is 37 documents in
  -- under two seconds with nothing else running, and six with the check
  -- catalogue running beside it; a signed-in user has eight. Five days keeps
  -- the worst call under half of that.
  v_end := least(v_from + 4, v_to);
  v_span := v_end - v_from + 1;
  v_prefix := 'DEMO-' || to_char(v_from, 'YYYYMMDD') || '-';

  -- Idempotent by reference: a slice that has any of its documents has all of
  -- them, because a call is one transaction.
  if exists (select 1 from erp.document d
              where d.tenant_id = v_tenant and d.their_reference like v_prefix || '%') then
    return jsonb_build_object('done', v_end >= v_to, 'from', v_from, 'to', v_to,
                              'built_through', v_end,
                              'next_from', case when v_end >= v_to then null else v_end + 1 end,
                              'built', 0,
                              'notes', jsonb_build_array(format('The days from %s were already built; nothing was duplicated.',
                                                                to_char(v_from, 'DD Mon YYYY'))));
  end if;

  -- Deterministic for the slice: the same days asked twice give the same
  -- answer, which is what makes a refused or timed-out call safe to repeat.
  perform setseed((abs(hashtext(v_from::text)) % 100000) / 100000.0);
$o2$;
  v_new2  text := $r2$  -- One day at a time (20260914072000). Five days per call ran close to the
  -- eight seconds a signed-in caller has once every order asked for its
  -- approval, so each day is a slice of its own and a call builds at most five
  -- of them. Under a statement timeout no new day is started once a quarter of
  -- it has gone: the call ends after that plus one day, and says where the
  -- next call starts. A session with no timeout builds all five.
  v_first := v_from;
  v_last  := least(v_from + 4, v_to);
  select nullif(s.setting, '0')::bigint into v_timeout_ms
    from pg_catalog.pg_settings s
   where s.name = 'statement_timeout';

  <<days>>
  for v_offset in 0 .. (v_last - v_first) loop
    v_day := v_first + v_offset;

    exit days when v_offset > 0
               and v_timeout_ms is not null
               and clock_timestamp() - statement_timestamp() > make_interval(secs => v_timeout_ms / 4000.0);

    v_from    := v_day;
    v_end     := v_day;
    v_span    := 1;
    v_seq     := 0;
    v_prefix  := 'DEMO-' || to_char(v_day, 'YYYYMMDD') || '-';
    v_through := v_day;

    -- Idempotent by reference: a day that has any of its documents has all of
    -- them, because a call is one transaction. A five-day slice built before
    -- one day was the unit covers the four days after the one it is named by;
    -- it is told from a day's slice by an order dated after that day, which a
    -- day's slice never holds.
    if exists (select 1 from erp.document d
                where d.tenant_id = v_tenant and d.their_reference like v_prefix || '%')
       or exists (select 1
                    from generate_series(1, 4) k(n)
                    join erp.document d
                      on d.tenant_id = v_tenant
                     and d.their_reference like 'DEMO-' || to_char(v_day - k.n, 'YYYYMMDD') || '-%'
                     and d.document_date > v_day - k.n
                    join erp.document_type dt
                      on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                   where dt.code in ('purchase_order', 'sales_order', 'quotation', 'requisition')) then
      v_skipped := v_skipped + 1;
      continue days;
    end if;

  -- Deterministic for the day: the same day asked twice gives the same
  -- answer, which is what makes a refused or timed-out call safe to repeat.
  perform setseed((abs(hashtext(v_from::text)) % 100000) / 100000.0);
$r2$;

  -- Each kind of document at the old weekly rate, spread over the day: the
  -- whole part always, and one more as often as the fraction says.
  v_old3  text := $o3$  v_n := greatest(1, round(7.5 * v_season * v_span / 7.0)::integer);
$o3$;
  v_new3  text := $r3$  v_n := floor(7.5 * v_season * v_span / 7.0 + random()::numeric)::integer;
$r3$;
  v_old4  text := $o4$  v_n := greatest(1, round(2 * v_season * v_span / 7.0)::integer);
$o4$;
  v_new4  text := $r4$  v_n := floor(2 * v_season * v_span / 7.0 + random()::numeric)::integer;
$r4$;
  v_old5  text := $o5$  v_n := greatest(1, round(1 * v_scale * v_span / 7.0)::integer);
$o5$;
  v_new5  text := $r5$  v_n := floor(1 * v_scale * v_span / 7.0 + random()::numeric)::integer;
$r5$;

  -- The day ends, and the call says how far it got.
  v_old6  text := $o6$  return jsonb_build_object(
    'done', v_end >= v_to,
    'from', v_from,
    'to', v_to,
    'built_through', v_end,
    'next_from', case when v_end >= v_to then null else v_end + 1 end,
    'built', v_built,
    'notes', v_notes);
$o6$;
  v_new6  text := $r6$  end loop days;

  if v_skipped > 0 then
    v_notes := v_notes || to_jsonb(format(
      case when v_skipped = 1
           then 'One day from %1$s was already built; nothing was duplicated.'
           else '%2$s days from %1$s were already built; nothing was duplicated.' end,
      to_char(v_first, 'DD Mon YYYY'), v_skipped));
  end if;

  return jsonb_build_object(
    'done', v_through >= v_to,
    'from', v_first,
    'to', v_to,
    'built_through', v_through,
    'next_from', case when v_through >= v_to then null else v_through + 1 end,
    'built', v_built,
    'notes', v_notes);
$r6$;
begin
  if position('<<days>>' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already builds one day at a time', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % declares v_span % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % holds the five-day slice header % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % counts its sales orders % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old4, ''))) / length(v_old4);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % counts its quotations % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old5, ''))) / length(v_old5);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % counts its requisitions % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old6, ''))) / length(v_old6);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % ends with its slice''s answer % time(s), not once', v_sig, v_hits;
  end if;

  v_def := replace(v_def, v_old1, v_new1);
  v_def := replace(v_def, v_old2, v_new2);
  v_def := replace(v_def, v_old3, v_new3);
  v_def := replace(v_def, v_old4, v_new4);
  v_def := replace(v_def, v_old5, v_new5);
  v_def := replace(v_def, v_old6, v_new6);
  execute v_def;

  if position('<<days>>' in pg_get_functiondef(v_sig::regprocedure)) = 0
     or position('end loop days;' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its days', v_sig;
  end if;
end
$history$;

comment on function erp.seed_demo_history(date, date, numeric) is
  'Builds demonstration trading one day at a time through the spine — purchase '
  'orders and receipts, sales orders, despatches, invoices and cash, quotations '
  'and requisitions — at most five days per call, starting no new day once a '
  'quarter of the caller''s statement timeout has gone, and says where the next '
  'call should start. A day already built, or inside a five-day slice built '
  'before, is skipped; refused in a live environment; every journal and movement '
  'is raised by the same bridges a person''s document goes through.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Words
-- ═════════════════════════════════════════════════════════════════════════════

-- The Plan screen asks for a threshold in pounds and sends the pence the band
-- stores. The prompt edited in place at its version, as pack items are.
do $prompt$
declare
  v_n integer;
begin
  update erp_ref.pack_item
     set decision_prompt = 'Up to what value may a procurement manager approve a requisition alone?'
   where pack_code = 'base'
     and object_kind = 'approval_band'
     and object_key = 'PROC|requisition|1'
     and decision_prompt = 'Up to what value may a procurement manager approve a requisition alone? (in minor units, e.g. 500000 for £5,000)';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_PACK_UNRECOGNISED: % base pack band prompts asked for minor units, expected 1', v_n
      using hint = 'The prompt was set by 20260903150000. Point this migration at the words it carries now.';
  end if;
end
$prompt$;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    -- Notifications: the channels, the urgency and where a message has got to,
    -- in words rather than the database's codes.
    ('Inbox',
     'Notifications: the panel listing the person''s own messages, under the page heading.'),
    ('Text message',
     'Notifications: the sms channel.'),
    ('Push notification',
     'Notifications: the push channel.'),
    ('In app · always on',
     'Notifications: the in-app channel beside the switches, which cannot be switched off.'),
    ('Information',
     'Notifications: the info severity.'),
    ('Held for quiet hours',
     'Notifications: a message held until the person''s quiet hours end.'),
    ('In a digest',
     'Notifications: a message gathered into a digest.'),
    ('Queued',
     'Notifications: a message waiting for a sender.'),
    ('Sending',
     'Notifications: a message a sender has taken.'),
    ('Sent',
     'Notifications: a message the provider accepted.'),
    ('Delivered',
     'Notifications: a message delivered.'),
    ('Read',
     'Notifications: a message the person has read.'),
    ('Suppressed',
     'Notifications: a message not sent because the address is suppressed.'),
    -- Common data: a record that is no longer in use.
    ('Archived',
     'Common data: the archived record status.'),
    -- Product-suppliers: the empty state names the card the action is on.
    ('No product has a supplier yet, so purchasing cannot resolve where to buy anything. Set one under Supplier defaults above.',
     'Product-suppliers: the empty state, pointing at the Supplier defaults card.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two organisations: a demonstration made the way the console makes one,
-- through erp.seed_demo(), and an ordinary one provisioned live. Everything is
-- built inside one block that is rolled back at the end, the statement timeout
-- a case sets included, so the suite leaves nothing behind whatever happens.

create or replace function erp_test.demo_stays_quiet_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner    text := current_user;
  v_job_before     text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before  text := coalesce(current_setting('request.jwt.claims', true), '');
  v_timeout_before text := current_setting('statement_timeout');
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 8);
  a_demo     uuid := gen_random_uuid();
  a_org      uuid := gen_random_uuid();
  v_step     text := 'starting';
  v_state    text;
  v_seed     jsonb;
  r          record;
  v_demo     uuid;
  v_org      uuid;
  u_demo     uuid;
  u_org      uuid;
  u_dana     uuid;
  u_demo_approver uuid;
  u_org_approver  uuid;
  u_org_invitee   uuid;
  v_chain    uuid;
  v_ver      uuid;
  v_req      uuid;
  v_task     uuid;
  v_ev       uuid;
  v_note     uuid;
  v_n        integer;
  v_m        integer;
  v_docs     integer;
  v_seq      bigint;
  v_last     bigint;
  v_i        integer;
  v_dir      jsonb;
  v_entity   uuid;
  v_site     uuid;
  v_party    uuid;
  v_ccy      char(3);
  v_base     date := make_date(extract(year from current_date)::integer - 1, 3, 2);
  v_legacy   date := make_date(extract(year from current_date)::integer - 1, 3, 12);
  v_budget   date := make_date(extract(year from current_date)::integer - 1, 3, 22);
  v_res      jsonb;
  v_allowed  boolean;
  v_reason   text;

  ok_known   boolean; msg_known   text;
  ok_demo    boolean; msg_demo    text;
  ok_org     boolean; msg_org     text;
  ok_claim   boolean; msg_claim   text;
  ok_orgq    boolean; msg_orgq    text;
  ok_invite  boolean; msg_invite  text;
  ok_self    boolean; msg_self    text;
  ok_dana    boolean; msg_dana    text;
  ok_quiet   boolean; msg_quiet   text;
  ok_again   boolean; msg_again   text;
  ok_legacy  boolean; msg_legacy  text;
  ok_budget  boolean; msg_budget  text;
begin
  begin
    -- ── The two organisations ─────────────────────────────────────────────
    v_step := 'a demonstration is made';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    insert into auth.users (id, email)
    values (a_demo, 'staff@zzquiet-' || v_tag || '.test'),
           (a_org, 'admin@zzquiet-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a_demo)::text, true);
    v_seed := erp.seed_demo();
    v_demo := (v_seed ->> 'tenant_id')::uuid;
    u_demo := (v_seed ->> 'principal_id')::uuid;
    select u.id into u_dana from erp.app_user u
     where u.tenant_id = v_demo and u.email = 'dana.viewer@example.invalid';

    v_step := 'an ordinary organisation is provisioned';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant('zzquiet-' || v_tag, 'Demo Stays Quiet Suite',
                                              'admin@zzquiet-' || v_tag || '.test', 'Quiet Admin');
    v_org := r.tenant_id;
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a_org)::text, true);
    u_org := erp.claim_invitation(r.admin_token);

    -- ── 1. Which is which ─────────────────────────────────────────────────
    ok_known := erp.tenant_is_demonstration(v_demo)
            and not erp.tenant_is_demonstration(v_org)
            and not erp.tenant_is_demonstration(null);
    msg_known := format('%s is a demonstration; zzquiet-%s is not',
                        (select t.code from erp.tenant t where t.id = v_demo), v_tag);

    -- ── 2. An approval task in the demonstration ──────────────────────────
    v_step := 'an approval task is opened in the demonstration';
    perform set_config('request.jwt.claims', json_build_object('sub', a_demo)::text, true);
    perform erp.ensure_notification_services();
    insert into erp.app_user (tenant_id, kind, status, display_name, email, user_locale)
    values (v_demo, 'person', 'active', 'Quiet Approver', 'demo-approver@zzquiet-' || v_tag || '.test', 'en')
    returning id into u_demo_approver;
    insert into erp.approval_chain (tenant_id, code, name, object_type)
    values (v_demo, 'zz_quiet', 'Demo stays quiet suite', 'zz_quiet')
    returning id into v_chain;
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status)
    values (v_demo, v_chain, 1, 'draft')
    returning id into v_ver;
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, approver_kind, app_user_id)
    values (v_demo, v_ver, 1, 'named', 'The named approver', 'user', u_demo_approver);
    perform erp.activate_approval_chain_version(v_ver, current_date);
    v_req := erp.request_approval('zz_quiet', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_demo and t.approval_request_id = v_req and t.status = 'pending';
    select e.id into v_ev from erp.event e
     where e.tenant_id = v_demo and e.event_type = 'approval.task_assigned' and e.aggregate_id = v_task;
    perform erp.route_notifications();

    ok_demo := v_ev is not null
           and exists (select 1 from erp.notification n
                        where n.tenant_id = v_demo and n.event_id = v_ev
                          and n.app_user_id = u_demo_approver and n.channel_kind = 'in_app')
           and not exists (select 1 from erp.notification n
                            where n.tenant_id = v_demo and n.event_id = v_ev and n.channel_kind <> 'in_app');
    msg_demo := format('event %s; %s in-app, %s on any other channel',
                       coalesce(v_ev::text, 'not raised'),
                       (select count(*) from erp.notification n where n.event_id = v_ev and n.channel_kind = 'in_app'),
                       (select count(*) from erp.notification n where n.event_id = v_ev and n.channel_kind <> 'in_app'));

    -- ── 4. What was queued before the rule is never handed over ───────────
    v_step := 'a demonstration message is queued as if from before the rule';
    select n.id into v_note from erp.notification n
     where n.tenant_id = v_demo and n.event_id = v_ev and n.app_user_id = u_demo_approver
     limit 1;
    update erp.notification set channel_kind = 'email', status = 'queued' where id = v_note;
    select count(*) into v_n from erp.claim_email_batch(50, 'zz-demo-stays-quiet');
    perform erp.upsert_notification_channel('zz_quiet_hook', 'Quiet suite hook', 'webhook',
                                            '{"url": "https://example.invalid/hook"}'::jsonb, null, true);
    update erp.notification set channel_kind = 'webhook' where id = v_note;
    select count(*) into v_m from erp.claim_webhook_batch(50, 'zz-demo-stays-quiet');
    ok_claim := v_n = 0 and v_m = 0
            and (select n.status from erp.notification n where n.id = v_note) = 'queued';
    msg_claim := format('%s email and %s webhook message(s) claimed; the row is still %s',
                        v_n, v_m, (select n.status from erp.notification n where n.id = v_note));

    -- ── 7. A task on your own request is not announced ────────────────────
    v_step := 'a task goes to the person who asked';
    insert into erp.approval_chain (tenant_id, code, name, object_type)
    values (v_demo, 'zz_quiet_self', 'Demo stays quiet suite, own request', 'zz_quiet_self')
    returning id into v_chain;
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status)
    values (v_demo, v_chain, 1, 'draft')
    returning id into v_ver;
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, approver_kind, app_user_id)
    values (v_demo, v_ver, 1, 'self', 'The person asking', 'user', u_demo);
    perform erp.activate_approval_chain_version(v_ver, current_date);
    v_req := erp.request_approval('zz_quiet_self', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_demo and t.approval_request_id = v_req
       and t.status = 'pending' and t.assignee_user_id = u_demo;
    ok_self := v_task is not null
           and not exists (select 1 from erp.event e
                            where e.tenant_id = v_demo and e.aggregate_id = v_task
                              and e.event_type in ('approval.task_assigned', 'approval.task_escalated'));
    msg_self := format('task %s for the person who asked; %s announcement(s)',
                       coalesce(v_task::text, 'not opened'),
                       (select count(*) from erp.event e where e.aggregate_id = v_task));

    -- ── 8. The seeded viewer ──────────────────────────────────────────────
    v_step := 'the demonstration''s administrator reads the directory';
    perform set_config('request.jwt.claims',
                       json_build_object('sub', a_demo, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_dir := public.erp_permissions_directory();
    execute format('set local role %I', v_owner);
    ok_dana := u_dana is not null
           and exists (select 1 from jsonb_array_elements(v_dir -> 'principals') x(el)
                        where x.el ->> 'id' = u_dana::text
                          and x.el ->> 'status' = 'invited'
                          and x.el ->> 'invitation_state' = 'pending'
                          and (x.el ->> 'invitation_expires_at')::timestamptz > now() + interval '7 days');
    msg_dana := coalesce((select x.el::text from jsonb_array_elements(v_dir -> 'principals') x(el)
                           where x.el ->> 'id' = u_dana::text), 'Dana is not in the directory');

    -- ── 6. An invitation in the demonstration is not emailed ──────────────
    v_step := 'the demonstration''s invitation email is claimed from a bare connection';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select c.allowed, c.reason into v_allowed, v_reason
      from erp.claim_invitation_email(u_dana, 'invite', null) c;
    ok_invite := v_allowed is false
             and v_reason like '%demonstration%'
             and not exists (select 1 from erp.invitation_email_log l where l.app_user_id = u_dana);
    msg_invite := format('demonstration: allowed %s, %s', coalesce(v_allowed::text, 'none'), coalesce(v_reason, 'no reason'));

    v_step := 'an ordinary organisation''s invitation email is claimed from a bare connection';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a_org)::text, true);
    select i.app_user_id into u_org_invitee
      from erp.invite_principal('invitee@zzquiet-' || v_tag || '.test', 'Quiet Invitee') i;
    perform set_config('request.jwt.claims', '', true);
    select c.allowed, c.reason into v_allowed, v_reason
      from erp.claim_invitation_email(u_org_invitee, 'invite', null) c;
    ok_invite := ok_invite and v_allowed is true;
    msg_invite := msg_invite || format('; ordinary: allowed %s, %s',
                                       coalesce(v_allowed::text, 'none'), coalesce(v_reason, 'no reason'));

    -- ── 3. The same task in the ordinary organisation ─────────────────────
    v_step := 'an approval task is opened in the ordinary organisation';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a_org)::text, true);
    perform erp.ensure_notification_services();
    insert into erp.app_user (tenant_id, kind, status, display_name, email, user_locale)
    values (v_org, 'person', 'active', 'Ordinary Approver', 'approver@zzquiet-' || v_tag || '.test', 'en')
    returning id into u_org_approver;
    perform erp_test.reopen_bootstrap_window(v_org);
    insert into erp.approval_chain (tenant_id, code, name, object_type)
    values (v_org, 'zz_quiet', 'Demo stays quiet suite', 'zz_quiet')
    returning id into v_chain;
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status)
    values (v_org, v_chain, 1, 'draft')
    returning id into v_ver;
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, approver_kind, app_user_id)
    values (v_org, v_ver, 1, 'named', 'The named approver', 'user', u_org_approver);
    perform erp.activate_approval_chain_version(v_ver, current_date);
    perform erp_test.close_bootstrap_window(v_org);
    v_req := erp.request_approval('zz_quiet', gen_random_uuid(), '{}'::jsonb);
    select t.id into v_task from erp.approval_task t
     where t.tenant_id = v_org and t.approval_request_id = v_req and t.status = 'pending';
    select e.id into v_ev from erp.event e
     where e.tenant_id = v_org and e.event_type = 'approval.task_assigned' and e.aggregate_id = v_task;
    perform erp.route_notifications();
    select n.id into v_note from erp.notification n
     where n.tenant_id = v_org and n.event_id = v_ev
       and n.app_user_id = u_org_approver and n.channel_kind = 'email'
     limit 1;
    ok_org := v_ev is not null and v_note is not null;
    msg_org := format('event %s; email row %s', coalesce(v_ev::text, 'not raised'), coalesce(v_note::text, 'none'));

    -- ── 5. And its email is handed to a sender ────────────────────────────
    v_step := 'the ordinary organisation dispatches and a sender claims';
    perform erp.dispatch_notifications();
    select count(*) into v_n from erp.claim_email_batch(50, 'zz-demo-stays-quiet') c where c.id = v_note;
    ok_orgq := v_note is not null and v_n = 1;
    msg_orgq := format('%s of the ordinary organisation''s email claimed', v_n);

    -- ── 9-12. Trading history in the demonstration ────────────────────────
    v_step := 'the demonstration is configured to trade';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a_demo)::text, true);
    -- The build role has no statement timeout; neither do these cases, until
    -- case twelve gives itself one.
    perform set_config('statement_timeout', '0', true);
    perform erp.ensure_demo_configuration(v_demo, u_demo);

    select count(*) into v_n from erp.event e
     where e.tenant_id = v_demo and e.event_type in ('approval.task_assigned', 'approval.task_escalated');
    select count(*) into v_m from erp.notification n where n.tenant_id = v_demo;

    v_step := 'two days of trading are built';
    v_res := erp.seed_demo_history(v_base, v_base + 1, 1);
    -- Route everything the days raised, however many passes that takes.
    v_last := -1;
    for v_i in 1 .. 50 loop
      select x.last_seq into v_seq from erp.route_notifications() x;
      exit when v_seq is not distinct from v_last;
      v_last := v_seq;
    end loop;
    ok_quiet := (v_res ->> 'done')::boolean
            and (v_res ->> 'built_through')::date = v_base + 1
            and (v_res ->> 'built')::integer > 0
            and exists (select 1 from erp.document d where d.tenant_id = v_demo
                         and d.their_reference like 'DEMO-' || to_char(v_base, 'YYYYMMDD') || '-%')
            and exists (select 1 from erp.document d where d.tenant_id = v_demo
                         and d.their_reference like 'DEMO-' || to_char(v_base + 1, 'YYYYMMDD') || '-%')
            and (select count(*) from erp.event e
                  where e.tenant_id = v_demo
                    and e.event_type in ('approval.task_assigned', 'approval.task_escalated')) = v_n
            and (select count(*) from erp.notification n where n.tenant_id = v_demo) = v_m;
    msg_quiet := format('%s; %s approval task(s) opened on the history, %s announcement(s) and %s notification(s) added',
                        left(v_res::text, 120),
                        (select count(*) from erp.approval_task t
                           join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
                           join erp.document d on d.tenant_id = q.tenant_id and d.id = q.object_id
                          where t.tenant_id = v_demo and q.object_type = 'document'
                            and d.their_reference like 'DEMO-%'),
                        (select count(*) from erp.event e
                          where e.tenant_id = v_demo
                            and e.event_type in ('approval.task_assigned', 'approval.task_escalated')) - v_n,
                        (select count(*) from erp.notification n where n.tenant_id = v_demo) - v_m);

    v_step := 'the same two days are asked for again';
    select count(*) into v_docs from erp.document d where d.tenant_id = v_demo;
    v_res := erp.seed_demo_history(v_base, v_base + 1, 1);
    ok_again := (v_res ->> 'done')::boolean
            and (v_res ->> 'built')::integer = 0
            and (select count(*) from erp.document d where d.tenant_id = v_demo) = v_docs;
    msg_again := format('%s documents before, %s after; %s', v_docs,
                        (select count(*) from erp.document d where d.tenant_id = v_demo), left(v_res::text, 160));

    v_step := 'a five-day slice from before is found';
    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = v_demo and l.is_primary order by l.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_demo and s.entity_id = v_entity
       and s.site_type in ('warehouse'::erp.site_type, 'distribution'::erp.site_type)
       and s.status = 'active'::erp.record_status
     order by s.code limit 1;
    select p.id into v_party from erp.party p where p.tenant_id = v_demo and p.code = 'C-NORTH';
    -- What a five-day slice named for its first day left: an order two days in.
    perform erp.create_document('quotation', v_entity, v_site, v_party, v_legacy + 2, v_ccy,
                                'DEMO-' || to_char(v_legacy, 'YYYYMMDD') || '-001', '{}'::jsonb);
    select count(*) into v_docs from erp.document d where d.tenant_id = v_demo;
    v_res := erp.seed_demo_history(v_legacy, v_legacy + 4, 1);
    ok_legacy := (v_res ->> 'done')::boolean
             and (v_res ->> 'built')::integer = 0
             and (select count(*) from erp.document d where d.tenant_id = v_demo) = v_docs;
    msg_legacy := format('%s documents before, %s after; %s', v_docs,
                         (select count(*) from erp.document d where d.tenant_id = v_demo), left(v_res::text, 160));

    v_step := 'a caller with a statement timeout builds and resumes';
    perform set_config('statement_timeout', '1000', true);
    v_res := erp.seed_demo_history(v_budget, v_budget + 1, 1);
    perform set_config('statement_timeout', '0', true);
    ok_budget := not (v_res ->> 'done')::boolean
             and (v_res ->> 'built_through')::date = v_budget
             and (v_res ->> 'next_from')::date = v_budget + 1
             and (v_res ->> 'built')::integer > 0;
    msg_budget := 'under a one-second timeout: ' || left(v_res::text, 120);
    v_res := erp.seed_demo_history(v_budget + 1, v_budget + 1, 1);
    ok_budget := ok_budget
             and (v_res ->> 'done')::boolean
             and (v_res ->> 'built_through')::date = v_budget + 1
             and (v_res ->> 'built')::integer > 0;
    msg_budget := msg_budget || '; resumed: ' || left(v_res::text, 120);

    v_step := 'done';
    raise exception 'ZZ_DEMO_STAYS_QUIET_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_DEMO_STAYS_QUIET_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  case_name := 'a demonstration is known by the code erp.seed_demo gives it, and an ordinary organisation is not';
  passed := v_state is null and coalesce(ok_known, false);
  detail := coalesce(v_state, msg_known);
  return next;

  case_name := 'an approval task in a demonstration is told in the product and on no other channel';
  passed := v_state is null and coalesce(ok_demo, false);
  detail := coalesce(v_state, msg_demo);
  return next;

  case_name := 'the same task in an ordinary organisation is emailed';
  passed := v_state is null and coalesce(ok_org, false);
  detail := coalesce(v_state, msg_org);
  return next;

  case_name := 'email or a webhook queued in a demonstration is never handed to a sender';
  passed := v_state is null and coalesce(ok_claim, false);
  detail := coalesce(v_state, msg_claim);
  return next;

  case_name := 'an ordinary organisation''s queued email is still handed to a sender';
  passed := v_state is null and coalesce(ok_orgq, false);
  detail := coalesce(v_state, msg_orgq);
  return next;

  case_name := 'an invitation in a demonstration is not emailed, and one in an ordinary organisation is';
  passed := v_state is null and coalesce(ok_invite, false);
  detail := coalesce(v_state, msg_invite);
  return next;

  case_name := 'a task on an approval somebody asked for themselves is not announced to them';
  passed := v_state is null and coalesce(ok_self, false);
  detail := coalesce(v_state, msg_self);
  return next;

  case_name := 'a freshly seeded viewer holds a pending invitation, not an expired one';
  passed := v_state is null and coalesce(ok_dana, false);
  detail := coalesce(v_state, msg_dana);
  return next;

  case_name := 'trading history is built day by day and announces and notifies nothing';
  passed := v_state is null and coalesce(ok_quiet, false);
  detail := coalesce(v_state, msg_quiet);
  return next;

  case_name := 'days already built are skipped, not duplicated';
  passed := v_state is null and coalesce(ok_again, false);
  detail := coalesce(v_state, msg_again);
  return next;

  case_name := 'the days of a five-day slice built before are skipped too';
  passed := v_state is null and coalesce(ok_legacy, false);
  detail := coalesce(v_state, msg_legacy);
  return next;

  case_name := 'under a statement timeout a call stops starting days and says where the next begins';
  passed := v_state is null and coalesce(ok_budget, false);
  detail := coalesce(v_state, msg_budget);
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.id in (v_demo, v_org))
        and not exists (select 1 from auth.users au where au.id in (a_demo, a_org))
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before
        and current_setting('statement_timeout') = v_timeout_before;
  detail := format('both organisations, their people and their history went with the block; '
                   'statement timeout %s, as it was', current_setting('statement_timeout'));
  return next;
end;
$$;

revoke all on function erp_test.demo_stays_quiet_suite() from public, anon, authenticated;

create or replace function erp_test.assert_demo_stays_quiet_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 13;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _demo_stays_quiet on commit drop as
    select * from erp_test.demo_stays_quiet_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _demo_stays_quiet;
  drop table _demo_stays_quiet;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DEMO_STAYS_QUIET_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DEMO_STAYS_QUIET_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('a demonstration stays quiet: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_demo_stays_quiet_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_vocabulary_aligned();
select erp.assert_notification_routes_resolvable();

select erp_test.assert_demo_stays_quiet_suite();
select erp_test.assert_demo_history_suite();
select erp_test.assert_demo_chart_suite();
select erp_test.assert_notification_product_routes_suite();
select erp_test.assert_email_delivery_suite();
select erp_test.assert_webhook_delivery_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_triggers_reach_no_sealed_schema();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
