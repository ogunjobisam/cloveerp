set lock_timeout = '30s';

-- =============================================================================
-- 20261007120000  A notice links to what it is about
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-132, J-134). The
-- Inbox said "A document is waiting for your approval." and, on the next line,
-- a bare address to the approvals screen: not which document, and no way to
-- open it. public.erp_my_notifications answered each message's subject and
-- body and nothing of what it was about, although an approval notice's event
-- names its task and the task its document, and an email's own context
-- already carries the links. Unread notices sank below read ones, newest
-- first, and the only way to clear the Inbox was one press a message: ninety
-- nine stale approval notices in the demonstration meant ninety nine presses.
-- And when goods arrived different from their shipping notice,
-- erp.receive_notice_lines told the buyer only how many lines differed
-- ("2 line(s) of order ... arrived short, over or not notified"), although it
-- held each line's number, what was notified and what was received, and
-- named neither the order nor the receipt as somewhere to go.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_my_notifications answers 'links' for each message: the
--      links its own context names (an email's, or a notice that carries
--      them), and otherwise the links its event leads to: an approval task's
--      approvals screen and the document it is about, a configuration change,
--      the jobs screen, the support session. Each link is named in the
--      reader's language with the words the product's emails already use, and
--      a document link carries the document's number. A body's last line
--      that is only the desk's address is dropped where a link replaces it.
--      Unread messages come first, then newest first, and the limit is taken
--      in that order, so an old unread message is never cut off by read ones.
--   B. erp.mark_all_notifications_read() and its door
--      public.erp_mark_all_notifications_read: every unread message of the
--      caller's own marked read in one press. Like the single one it needs no
--      permission, because it reaches only the caller's own rows: the update
--      is keyed to the session's organisation and erp.current_principal_id(),
--      never a parameter. With nothing unread it marks nothing and says so.
--   C. erp.receive_notice_lines tells the buyer each difference by its line
--      ("Line 1: 4 notified, 3 received"; "Line 2: not on the notice,
--      2 received") and gives the notice the order and the receipt as links.
--   D. The door's write allowance, its place in the Notifications screen's
--      help, and the words of its button.
--   E. erp_test.notice_links_suite.
--
-- The screen's half is in src/routes/notifications.tsx: the Inbox draws the
-- links and a Mark all as read button.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No message is marked read here: the stale notices in the demonstration go
-- with one press of the new button, or with the migration that clears the
-- testers' records. What a message says and to whom it goes are unchanged;
-- the email a notice sends is unchanged.
--
-- On production: two routines are edited where they answer and write, and a
-- routine, its door and their registrations are added. No table is altered
-- and no row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The Inbox answers what each message is about, unread first
-- ─────────────────────────────────────────────────────────────────────────────

do $mine$
declare
  v_sig constant text := 'public.erp_my_notifications(integer)';
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261007120000') > 0 then
    raise notice '% already answers its links; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '54d7aba63c936b8a55dc0a1e5abace0f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007120000 expects (md5 %)', v_sig, md5(v_src);
  end if;
end
$mine$;

create or replace function public.erp_my_notifications(p_limit integer default 100)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The caller's own messages, unread first and then newest first, each with
  -- the links to what it is about (20261007120000, J-132). The limit is taken
  -- in that order, so read messages never push an unread one off the list.
  with me as (
    select erp.require_tenant_id() as tenant_id, erp.current_principal_id() as user_id
  ), reader as (
    select me.tenant_id, me.user_id,
           coalesce((select nullif(u.user_locale, '') from erp.app_user u
                      where u.tenant_id = me.tenant_id and u.id = me.user_id), 'en') as locale,
           -- The desk's address, as erp.route_notifications writes it into a body.
           coalesce((select r.value from erp_ref.resource r
                      where r.key = 'app.base_url' and r.locale = 'en'), 'https://cloveerp.com') as base
      from me
  ), mine as (
    select x.*
      from reader rd
      join erp.notification x on x.tenant_id = rd.tenant_id and x.app_user_id = rd.user_id
     where x.status <> 'digested'
     order by (x.status in ('sent', 'delivered')) desc, x.created_at desc
     limit greatest(p_limit, 1)
  ), linked as (
    select n.*, rd.base,
           coalesce(
             -- What the message names itself: an email's context, or a notice
             -- that carries its own. Each link is named by the words the
             -- context holds for it, and a document link by its number. The
             -- link back to this screen is left out.
             (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                       'path', l.value #>> '{}',
                       'label', nullif(n.context -> 'words' ->> l.key, ''),
                       'reference', nullif(n.context -> 'fields' ->> case l.key when 'secondary' then 'document_number'
                                                                              else l.key || '_number' end, '')))
                     order by array_position(array['primary', 'secondary', 'order', 'receipt'], l.key) nulls last, l.key)
                from jsonb_each(case when jsonb_typeof(n.context -> 'links') = 'object' then n.context -> 'links' end) l
               where jsonb_typeof(l.value) = 'string'
                 and left(l.value #>> '{}', 1) = '/'
                 and split_part(l.value #>> '{}', '?', 1) <> '/notifications'),
             -- Otherwise where its event leads, named as the product's emails
             -- name the same links, in the reader's language.
             (select case
                       when ev.event_type in ('approval.task_assigned', 'approval.task_escalated') then
                         (select jsonb_build_array(jsonb_build_object(
                                   'path', '/governance?task=' || tk.id::text,
                                   'label', erp.text('email.approval.primary', rd.locale)))
                                 || case when d.id is null then '[]'::jsonb
                                         else jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                                                'path', '/documents/' || d.id::text,
                                                'label', erp.text('email.approval.secondary', rd.locale),
                                                'reference', d.document_number))) end
                            from erp.approval_task tk
                            join erp.approval_request ar
                              on ar.tenant_id = tk.tenant_id and ar.id = tk.approval_request_id
                            left join erp.document d
                              on ar.object_type = 'document' and d.tenant_id = ar.tenant_id and d.id = ar.object_id
                           where tk.tenant_id = ev.tenant_id and tk.id = ev.aggregate_id)
                       when ev.event_type = 'change_set.submitted' then
                         jsonb_build_array(jsonb_build_object(
                           'path', '/administration/configuration?change=' || ev.aggregate_id::text,
                           'label', erp.text('email.change_set.primary', rd.locale)))
                       when ev.event_type in ('job.failed', 'job.silenced') then
                         jsonb_build_array(jsonb_build_object(
                           'path', '/operations/jobs',
                           'label', erp.text('email.job_failed.primary', rd.locale)))
                       when ev.event_type = 'support.access_granted' then
                         jsonb_build_array(jsonb_build_object(
                           'path', '/operations/continuity',
                           'label', erp.text('email.support_access.primary', rd.locale)))
                       when ev.aggregate_type = 'document' then
                         (select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                                   'path', '/documents/' || d.id::text,
                                   'label', erp.text('email.approval.secondary', rd.locale),
                                   'reference', d.document_number)))
                            from erp.document d
                           where d.tenant_id = ev.tenant_id and d.id = ev.aggregate_id)
                     end
                from erp.event ev
               where ev.tenant_id = n.tenant_id and ev.id = n.event_id),
             '[]'::jsonb) as links
      from mine n
     cross join reader rd
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id, 'severity', n.severity, 'channel_kind', n.channel_kind, 'subject', n.subject,
           -- A line that is only the desk's address says less than the link
           -- that now stands for it, so it goes where there is a link.
           'body', case when jsonb_array_length(n.links) = 0 then n.body
                        else coalesce(rtrim((select string_agg(t.ln, E'\n' order by t.i)
                                               from unnest(string_to_array(n.body, E'\n')) with ordinality as t(ln, i)
                                              where not (left(t.ln, length(n.base) + 1) = n.base || '/'
                                                         and t.ln !~ '\s')), E'\n'), '') end,
           'status', n.status, 'created_at', n.created_at, 'read_at', n.read_at,
           'digest_of', n.digest_of, 'is_escalation', n.escalation_of is not null and n.subject like 'Escalated:%',
           'failure_reason', n.failure_reason,
           'links', n.links)
         order by (n.status in ('sent', 'delivered')) desc, n.created_at desc), '[]'::jsonb)
    from linked n;
$$;

comment on function public.erp_my_notifications(integer) is
  'The caller''s own messages, unread first and then newest first, each with links to what it is about, named in the '
  'reader''s language, a document link with its number (20261007120000, J-132). Keyed to the session''s organisation '
  'and erp.current_principal_id(); it authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Every unread message marked read in one press
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.mark_all_notifications_read()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  v_n      integer;
begin
  -- The caller's own unread messages, and nobody else's (20261007120000,
  -- J-132): keyed to the session's organisation and principal, as
  -- erp.mark_notification_read is. With nothing unread it marks nothing.
  update erp.notification
     set status = 'read', read_at = coalesce(read_at, now())
   where tenant_id = v_tenant and app_user_id = v_me
     and status in ('sent', 'delivered');
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function erp.mark_all_notifications_read() from public, anon;

comment on function erp.mark_all_notifications_read() is
  'Marks read every unread message addressed to the caller, keyed to the session''s organisation and '
  'erp.current_principal_id(), and answers how many (20261007120000, J-132). Nobody else''s rows are reachable.';

create or replace function public.erp_mark_all_notifications_read()
returns integer
language sql
set search_path = ''
as $$ select erp.mark_all_notifications_read() $$;

revoke all on function public.erp_mark_all_notifications_read() from public, anon;
grant execute on function public.erp_mark_all_notifications_read() to authenticated, service_role;

comment on function public.erp_mark_all_notifications_read() is
  'Marks read every unread message of the caller''s own, and answers how many (20261007120000). '
  'Needs no permission: it reaches only the caller''s own rows.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A notice that differs says how, line by line, and links its order and
--    its receipt
-- ─────────────────────────────────────────────────────────────────────────────

do $notice$
declare
  v_sig  constant text := 'erp.receive_notice_lines(uuid,jsonb,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if jsonb_array_length(v_diff) > 0 and d.created_by is not null then
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, delivered_at)
    values (v_tenant, 'medium'::erp.notification_severity, d.created_by, 'in_app',
            format('%s arrived different from its notice', n.notice_number),
            format('%s line(s) of order %s arrived short, over or not notified; %s holds what came. The order stays open for the rest.',
                   jsonb_array_length(v_diff), d.document_number, v_number),
            'delivered', now(), now());
  end if;$o$;
  v_new  constant text := $n$  if jsonb_array_length(v_diff) > 0 and d.created_by is not null then
    -- Each difference by its line, and the order and the receipt as links
    -- (20261007120000, J-134). The Inbox draws the links.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, delivered_at,
                                  context)
    values (v_tenant, 'medium'::erp.notification_severity, d.created_by, 'in_app',
            format('%s arrived different from its notice', n.notice_number),
            format('%s holds what came of order %s. The order stays open for the rest.', v_number, d.document_number)
              || coalesce(E'\n' || (
                   select string_agg(
                            case when df ->> 'kind' = 'not_notified'
                                 then format('Line %s: not on the notice, %s received',
                                             coalesce(df ->> 'line_no', '?'), trim_scale((df ->> 'received')::numeric))
                                 else format('Line %s: %s notified, %s received',
                                             coalesce(df ->> 'line_no', '?'), trim_scale((df ->> 'notified')::numeric),
                                             trim_scale((df ->> 'received')::numeric)) end,
                            E'\n' order by (df ->> 'line_no')::integer nulls last)
                     from jsonb_array_elements(v_diff) df), ''),
            'delivered', now(), now(),
            jsonb_build_object(
              'version', 1, 'kind', 'notice_received',
              'links', jsonb_build_object('order', '/documents/' || d.id::text, 'receipt', '/documents/' || v_grn::text),
              'fields', jsonb_strip_nulls(jsonb_build_object(
                'order_number', d.document_number, 'receipt_number', v_number,
                'notice_number', n.notice_number, 'differences', v_diff))));
  end if;$n$;
begin
  if strpos(v_src, '20261007120000') > 0 then
    raise notice '% already lists its differences; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'eec2a513923b71881d750256f9b29b13' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007120000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$notice$;

comment on function erp.receive_notice_lines(uuid, jsonb, uuid) is
  'What arrived of a shipping notice, received against its order in one posted receipt (20261005000000). Where it '
  'differs, the buyer is told each line''s difference, with the order and the receipt as links (20261007120000, J-134). '
  'erp.receive_against authorises each line.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Its registrations and its words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale, ungated_because) values
  ('erp_mark_all_notifications_read', 'erp.mark_all_notifications_read',
   'Marks read only the notifications addressed to the caller: the update is keyed to the session''s organisation and erp.current_principal_id(), never a parameter, and reaches nobody else''s rows.',
   'own_records')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale, ungated_because = excluded.ungated_because;

select erp_meta.add_help_actions('/notifications', array['erp_mark_all_notifications_read']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Marking every unread notice read (20261007120000).'
  from (values
    ('Mark all as read')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.notice_links_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  v_owner  text := current_user;
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sa uuid;
  v_po uuid; v_po_no text; v_l1 uuid; v_l2 uuid; v_ln1 integer; v_ln2 integer;
  v_task uuid; v_ev uuid; v_other uuid;
  v_base text;
  v_mail uuid; v_inapp uuid; v_read uuid; v_old uuid; v_theirs uuid;
  v_list jsonb; v_signed jsonb; v_row jsonb;
  v_n1 jsonb; v_r jsonb; v_grn_no text;
  v_marked integer; v_again integer;
  v_body text; v_ctx jsonb;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, with an order waiting for approval';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zznlk-' || v_tag, 'Notice Links Suite',
      'admin@zznlk-' || v_tag || '.test', 'Links Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zznlk-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZNLCOAT', 'Linked Coat', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZNLSCARF', 'Linked Scarf', v_uom, 'active') returning id into v_item2;
    v_sa := erp_test.cash_payment_supplier('ZNLSUP');
    v_po := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    v_l1 := erp.add_document_line(v_po, v_item, 10, 9000, 'coats');
    v_l2 := erp.add_document_line(v_po, v_item2, 10, 1000, 'scarves');
    perform erp.transition_document(v_po, 'submit', null);
    select d.document_number into v_po_no from erp.document d where d.id = v_po;
    select t.id into v_task
      from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
     where ar.tenant_id = rb.tenant_id and ar.object_type = 'document' and ar.object_id = v_po
       and t.status = 'pending'
     order by t.id limit 1;
    v_base := coalesce((select r.value from erp_ref.resource r where r.key = 'app.base_url' and r.locale = 'en'),
                       'https://cloveerp.com');

    -- The task was the administrator's own request, so nobody was told
    -- (erp.announce_approval_task). Announced as it is for a task somebody
    -- else raised, and routed by the product's own route.
    v_step := 'the task announced and routed';
    v_ev := erp.append_event('approval.task_assigned', 'approval_task', v_task,
              (select jsonb_strip_nulls(jsonb_build_object(
                        'recipient_ids', jsonb_build_array(rb.admin_user_id),
                        'approval_request_id', t.approval_request_id,
                        'object_type', 'document', 'object_id', v_po,
                        'step_code', t.step_code, 'due_at', t.due_at))
                 from erp.approval_task t where t.id = v_task),
              v_entity, v_site);
    perform erp.route_notifications();
    select n.id into v_mail from erp.notification n
     where n.tenant_id = rb.tenant_id and n.event_id = (select e.id from erp.event e where e.id = v_ev)
       and n.app_user_id = rb.admin_user_id
     order by n.created_at limit 1;
    update erp.notification set status = 'delivered', sent_at = now(), delivered_at = now(),
           provider_message_id = 'zznlk-' || v_tag
     where id = v_mail;

    -- ── 1. Its registers ────────────────────────────────────────────────────
    v_step := 'reading the registers';
    v_cases := v_cases + 1;
    case_name := 'the mark-all door is allowed to write the caller''s own rows only, is in the Notifications screen''s help, and its button''s words are registered';
    passed := v_state is null
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_mark_all_notifications_read'
                         and a.gate = 'erp.mark_all_notifications_read' and a.ungated_because = 'own_records')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/notifications' and 'erp_mark_all_notifications_read' = any (h.actions))
          and exists (select 1 from erp_ref.resource x
                       where x.locale = 'en' and x.key = erp_ref.ui_key('Mark all as read'));
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. An approval email's notice links the task and the document ───────
    v_step := 'reading the Inbox with an approval notice';
    v_list := public.erp_my_notifications(20);
    select x into v_row from jsonb_array_elements(v_list) x where x ->> 'id' = v_mail::text;
    v_cases := v_cases + 1;
    case_name := 'an approval notice links its task, named as the email names it, and its document by number, and its body no longer ends in the desk''s address';
    passed := v_state is null
          and v_mail is not null
          and jsonb_array_length(v_row -> 'links') = 2
          and v_row #>> '{links,0,path}' = '/governance?task=' || v_task::text
          and v_row #>> '{links,0,label}' = erp.text('email.approval.primary', 'en')
          and v_row #>> '{links,1,path}' = '/documents/' || v_po::text
          and v_row #>> '{links,1,reference}' = v_po_no
          and v_row ->> 'body' = erp.text('notify.approval_requested.body', 'en')
          and (select n.body from erp.notification n where n.id = v_mail) like '%' || v_base || '/governance';
    detail := coalesce(v_state, left(coalesce(v_row::text, 'no row for the notice'), 600));
    return next;

    -- ── 3. A notice with no context is linked through its event ─────────────
    -- As a demonstration's in-app notice is, and every one routed before the
    -- emails carried a context.
    v_step := 'an in-app notice with no context';
    insert into erp.notification (tenant_id, event_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (rb.tenant_id, v_ev, 'medium', rb.admin_user_id, 'in_app', 'Approval requested',
            erp.text('notify.approval_requested.body', 'en') || E'\n\n' || v_base || '/governance',
            'delivered', now(), now())
    returning id into v_inapp;
    v_list := public.erp_my_notifications(20);
    select x into v_row from jsonb_array_elements(v_list) x where x ->> 'id' = v_inapp::text;
    set local role authenticated;
    v_signed := public.erp_my_notifications(20);
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'an in-app notice with no context of its own is linked through its event to the same task and document, read alike signed in';
    passed := v_state is null
          and jsonb_array_length(v_row -> 'links') = 2
          and v_row #>> '{links,0,path}' = '/governance?task=' || v_task::text
          and v_row #>> '{links,0,label}' = erp.text('email.approval.primary', 'en')
          and v_row #>> '{links,1,path}' = '/documents/' || v_po::text
          and v_row #>> '{links,1,label}' = erp.text('email.approval.secondary', 'en')
          and v_row #>> '{links,1,reference}' = v_po_no
          and v_row ->> 'body' = erp.text('notify.approval_requested.body', 'en')
          and v_signed = v_list;
    detail := coalesce(v_state, left(coalesce(v_row::text, 'no row for the notice'), 600));
    return next;

    -- ── 4. Unread first ─────────────────────────────────────────────────────
    v_step := 'an old unread notice and a newer read one';
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at, read_at)
    values (rb.tenant_id, 'low', rb.admin_user_id, 'in_app', 'Already read', 'Read this morning.',
            'read', now(), now(), now())
    returning id into v_read;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (rb.tenant_id, 'low', rb.admin_user_id, 'in_app', 'Still unread', 'Sent last week.',
            'delivered', now(), now())
    returning id into v_old;
    update erp.notification set created_at = now() - interval '7 days' where id = v_old;
    v_list := public.erp_my_notifications(20);
    v_cases := v_cases + 1;
    case_name := 'unread messages come before read ones, however old, and a limit of one keeps the unread one';
    passed := v_state is null
          and (select max(x.i) from jsonb_array_elements(v_list) with ordinality x(v, i)
                where x.v ->> 'status' in ('sent', 'delivered'))
              < (select min(x.i) from jsonb_array_elements(v_list) with ordinality x(v, i)
                  where x.v ->> 'status' = 'read')
          and exists (select 1 from jsonb_array_elements(v_list) x where x ->> 'id' = v_old::text)
          and public.erp_my_notifications(1) -> 0 ->> 'status' in ('sent', 'delivered')
          and (select jsonb_array_length(x -> 'links') from jsonb_array_elements(v_list) x
                where x ->> 'id' = v_read::text) = 0;
    detail := coalesce(v_state, (select string_agg(x ->> 'subject' || ' ' || (x ->> 'status'), ', ')
                                   from jsonb_array_elements(v_list) x));
    return next;

    -- ── 5. A notice that differs says each line and links both documents ────
    v_step := 'the order approved, notified and received different';
    perform erp_test.approve_document(v_po, 'notice links suite');
    perform erp.transition_document(v_po, 'send', null);
    select l.line_no into v_ln1 from erp.document_line l where l.id = v_l1;
    select l.line_no into v_ln2 from erp.document_line l where l.id = v_l2;
    v_n1 := public.erp_record_shipping_notice(v_po, jsonb_build_object('expected_arrival', (current_date + 2)::text,
              'lines', jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 4))));
    v_r := public.erp_receive_as_notified((v_n1 ->> 'notice_id')::uuid,
              jsonb_build_array(jsonb_build_object('order_line_id', v_l1, 'quantity', 3),
                                jsonb_build_object('order_line_id', v_l2, 'quantity', 2)));
    v_grn_no := v_r ->> 'receipt';
    select n.body, n.context into v_body, v_ctx from erp.notification n
     where n.tenant_id = rb.tenant_id and n.subject = (v_n1 ->> 'notice') || ' arrived different from its notice';
    v_cases := v_cases + 1;
    case_name := 'goods that arrive different from their notice tell the buyer each line''s difference, and the notice carries the order and the receipt as links';
    passed := v_state is null
          and jsonb_array_length(v_r -> 'differences') = 2
          and v_body = format('%s holds what came of order %s. The order stays open for the rest.', v_grn_no, v_po_no)
                       || E'\n' || format('Line %s: 4 notified, 3 received', v_ln1)
                       || E'\n' || format('Line %s: not on the notice, 2 received', v_ln2)
          and v_ctx #>> '{links,order}' = '/documents/' || v_po::text
          and v_ctx #>> '{links,receipt}' = '/documents/' || (v_r ->> 'receipt_id')
          and v_ctx #>> '{fields,order_number}' = v_po_no
          and v_ctx #>> '{fields,receipt_number}' = v_grn_no;
    detail := coalesce(v_state, left(coalesce(v_body, 'no notice') || ' | ' || coalesce(v_ctx::text, 'no context'), 600));
    return next;

    -- ── 6. The Inbox draws them ─────────────────────────────────────────────
    v_step := 'reading the Inbox with the notice';
    select x into v_row from jsonb_array_elements(public.erp_my_notifications(20)) x
     where x ->> 'subject' = (v_n1 ->> 'notice') || ' arrived different from its notice';
    v_cases := v_cases + 1;
    case_name := 'the Inbox answers the notice with its order and its receipt as links, each by number, and its body as written';
    passed := v_state is null
          and jsonb_array_length(v_row -> 'links') = 2
          and v_row #>> '{links,0,path}' = '/documents/' || v_po::text
          and v_row #>> '{links,0,reference}' = v_po_no
          and v_row #>> '{links,1,path}' = '/documents/' || (v_r ->> 'receipt_id')
          and v_row #>> '{links,1,reference}' = v_grn_no
          and v_row ->> 'body' = v_body;
    detail := coalesce(v_state, left(coalesce(v_row::text, 'no row for the notice'), 600));
    return next;

    -- ── 7. Mark all as read, one's own only ─────────────────────────────────
    v_step := 'somebody else''s unread notice, then mark all as read';
    insert into erp.app_user (tenant_id, kind, status, display_name, email, user_locale)
    values (rb.tenant_id, 'person', 'active', 'Somebody Else', 'else@zznlk-' || v_tag || '.test', 'en')
    returning id into v_other;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (rb.tenant_id, 'low', v_other, 'in_app', 'Not yours', 'For somebody else.', 'delivered', now(), now())
    returning id into v_theirs;
    set local role authenticated;
    v_marked := public.erp_mark_all_notifications_read();
    v_again := public.erp_mark_all_notifications_read();
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'mark all as read marks every unread message of the caller''s and nobody else''s, signed in, and a second press marks nothing';
    passed := v_state is null
          and v_marked >= 4
          and v_again = 0
          and not exists (select 1 from erp.notification n
                           where n.tenant_id = rb.tenant_id and n.app_user_id = rb.admin_user_id
                             and n.status in ('sent', 'delivered'))
          and (select n.status from erp.notification n where n.id = v_theirs) = 'delivered'
          and (select n.read_at from erp.notification n where n.id = v_old) is not null;
    detail := coalesce(v_state, format('%s marked, then %s; theirs is %s', v_marked, v_again,
                (select n.status from erp.notification n where n.id = v_theirs)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_NOTICE_LINKS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zznlk-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_NOTICE_LINKS_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.notice_links_suite() from public, anon;

comment on function erp_test.notice_links_suite() is
  'A notice links to what it is about (20261007120000, J-132, J-134): an approval notice links its task and its '
  'document, by its context or through its event, signed in too; unread messages come first; a receipt that differs '
  'from its notice names each line and links the order and the receipt; mark all as read reaches only the caller''s own.';

create or replace function erp_test.assert_notice_links_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.notice_links_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_NOTICE_LINKS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A notice would not lead to what it is about, or marking all read would reach the wrong rows. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_NOTICE_LINKS_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('notice links: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_notice_links_suite() from public, anon;

comment on function erp_test.assert_notice_links_suite() is
  'A notice links its task, document, order or receipt, unread notices come first, and mark all as read reaches only '
  'the caller''s own (20261007120000).';

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
select erp.assert_invoker_doors_executable();
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
