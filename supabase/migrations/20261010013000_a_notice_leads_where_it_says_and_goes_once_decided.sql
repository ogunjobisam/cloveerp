set lock_timeout = '30s';

-- =============================================================================
-- 20261010013000  A notice leads where it says, and goes once decided
-- -----------------------------------------------------------------------------
-- Found in the live re-test of 5 October (B3, B5), in the demonstration's
-- Inbox.
--
--   B3. "ASN-PO-000141-2 arrived different from its notice" and its twin,
--       both of 4 October, had no link at all, though their own words name
--       the order and the receipt (GRN-000138 holds what came of order
--       PO-000141). 20261007120000 gave erp.receive_notice_lines' notices
--       their links from then on; one written before, and every notice whose
--       routine still writes none (a shipment on its way or overdue, an order
--       not confirmed or declined, samples due back, an email that did not
--       reach its reader), carries neither links nor an event to find them
--       by, so public.erp_my_notifications answered none.
--   B5. About a hundred unread "Approval requested" notices of 14 September
--       sat in the Inbox for approvals decided long ago. Deciding a task
--       retired its email links (erp.retire_email_actions_for_task) and left
--       its notice unread; only the reader could put it away.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_my_notifications: a notice with no links of its own and no
--      event that leads anywhere leads to the documents its subject and body
--      name, by number, in the order they are named, in the reader's
--      organisation only. A word that is no document's number leads nowhere.
--   B. erp.put_away_task_notices(), on erp.approval_task: once a task is no
--      longer waiting (approved, rejected, delegated, escalated, skipped or
--      cancelled), the in-app notice that asked for it is marked read, for
--      whoever it was addressed to. Its email is not touched.
--   C. erp.put_away_decided_task_notices(): in the organisation it runs in,
--      the in-app notices still unread for tasks already decided are marked
--      read. Run here in each demonstration (code 'demo-%') only.
--   D. An index on erp.notification (tenant_id, event_id), which the trigger
--      and the Inbox read the notice of a task by.
--   E. erp_test.notice_leads_suite, six cases. erp_test.notice_links_suite
--      approves its order and then marks what is left unread: it now counts
--      one notice fewer, the approval's, which the decision put away.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- What a notice says and to whom it goes are unchanged, and no notice is
-- deleted. A notice that names its own links keeps exactly those. A task
-- still waiting keeps its notice unread. Outside a demonstration no existing
-- notice is marked read: from now on a decided task's notice is put away as it
-- is decided, and what an organisation already holds is its readers' to clear
-- (Mark all as read).
--
-- On production: one routine and one suite are edited, two routines are
-- added, a trigger is created on erp.approval_task and an index on
-- erp.notification. In each demonstration, the unread in-app notices of
-- decided tasks are marked read; no other row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A notice leads to the documents it names
-- ─────────────────────────────────────────────────────────────────────────────

do $inbox$
declare
  v_sig  constant text := 'public.erp_my_notifications(integer)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$             '[]'::jsonb) as links
      from mine n
$o$;
  v_new  constant text := $n$             -- Otherwise the documents its own words name, in the order it names
             -- them (20261010013000, B3): a notice written with no links and
             -- no event, before 20261007120000 or by a routine that writes
             -- none, still says which order and which receipt it is about.
             -- Only this organisation's documents; a word that is no
             -- document's number leads nowhere.
             (select jsonb_agg(jsonb_build_object(
                       'path', '/documents/' || w.document_id::text,
                       'label', erp.text('email.approval.secondary', rd.locale),
                       'reference', w.document_number) order by w.pos)
                from (select distinct on (d.id) d.id as document_id, d.document_number, m.pos
                        from regexp_matches(coalesce(n.subject, '') || E'\n' || coalesce(n.body, ''),
                                            '[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+', 'g')
                               with ordinality as m(word, pos)
                        join erp.document d
                          on d.tenant_id = n.tenant_id and d.document_number = m.word[1]
                       order by d.id, m.pos) w),
             '[]'::jsonb) as links
      from mine n
$n$;
begin
  if strpos(v_src, '20261010013000') > 0 then
    raise notice '% already reads the documents a notice names; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c5ebc312209adad386aac7271d84f1f5' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010013000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$inbox$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The notice of a task, found by its event
-- ─────────────────────────────────────────────────────────────────────────────

create index if not exists notification_tenant_event_idx
  on erp.notification (tenant_id, event_id) where event_id is not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A decided task's notice is put away
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.put_away_task_notices()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Once a task is no longer waiting, the in-app notice that asked for it is
  -- read (20261010013000, B5), whoever it was addressed to: the decision is
  -- made, by them or by somebody who may make it for them, and a notice asking
  -- for it says nothing true any more. Its email links are retired by
  -- erp.retire_email_actions_for_task, beside this.
  if old.status = 'pending' and new.status is distinct from old.status then
    update erp.notification n
       set status = 'read', read_at = coalesce(n.read_at, now())
     where n.tenant_id = new.tenant_id
       and n.channel_kind = 'in_app'
       and n.status in ('sent', 'delivered')
       and n.event_id in (
             select ev.id from erp.event ev
              where ev.tenant_id = new.tenant_id
                and ev.aggregate_type = 'approval_task' and ev.aggregate_id = new.id
                and ev.event_type in ('approval.task_assigned', 'approval.task_escalated'));
  end if;
  return null;
end;
$$;

revoke all on function erp.put_away_task_notices() from public, anon;

comment on function erp.put_away_task_notices() is
  'On erp.approval_task: once a task is no longer waiting, the in-app notice that asked for it is marked read, '
  'whoever it was addressed to (20261010013000).';

drop trigger if exists t_approval_task_puts_away_notices on erp.approval_task;
create trigger t_approval_task_puts_away_notices
  after update of status on erp.approval_task
  for each row execute function erp.put_away_task_notices();

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The notices of tasks decided already
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.put_away_decided_task_notices()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_n      integer;
begin
  -- The in-app notices still unread, in the organisation the session acts
  -- for, of tasks already decided (20261010013000, B5): what
  -- erp.put_away_task_notices does as a task is decided, for the tasks
  -- decided before it did. Asked again, nothing.
  update erp.notification n
     set status = 'read', read_at = coalesce(n.read_at, now())
    from erp.event ev
    join erp.approval_task t
      on t.tenant_id = ev.tenant_id and t.id = ev.aggregate_id
   where n.tenant_id = v_tenant
     and n.channel_kind = 'in_app'
     and n.status in ('sent', 'delivered')
     and ev.tenant_id = v_tenant and ev.id = n.event_id
     and ev.aggregate_type = 'approval_task'
     and ev.event_type in ('approval.task_assigned', 'approval.task_escalated')
     and t.status <> 'pending';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function erp.put_away_decided_task_notices() from public, anon;

comment on function erp.put_away_decided_task_notices() is
  'Marks read, in the organisation the session acts for, the unread in-app notices of approval tasks already '
  'decided (20261010013000). Run once in each demonstration; asked again it marks nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

-- erp_test.notice_links_suite approves its order in its fifth case and then,
-- in its seventh, marks everything left unread: the approval's in-app notice
-- is now put away by the decision, so one fewer is left to mark, and the case
-- says why.
do $links_suite$
declare
  v_sig  constant text := 'erp_test.notice_links_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$          and v_marked >= 4
$o$;
  v_new  constant text := $n$          -- The approval's in-app notice was put away when its task was decided
          -- in the fifth case (20261010013000), so one fewer is left to mark.
          and v_marked >= 3
          and (select n.status from erp.notification n where n.id = v_inapp) = 'read'
$n$;
begin
  if strpos(v_src, '20261010013000') > 0 then
    raise notice '% already counts the notice put away; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '509993f46a2440081d2835a209da42d3' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010013000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$links_suite$;

create or replace function erp_test.notice_leads_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_me     uuid;
  v_ent    uuid; v_site uuid; i_fg uuid; p_sup uuid;
  v_po     uuid; v_po2 uuid; v_po3 uuid; v_grn uuid;
  v_po_no  text; v_grn_no text;
  x        jsonb;
  v_n1     uuid; v_n2 uuid; v_n3 uuid; v_t1 uuid; v_t2 uuid; v_t3 uuid;
  v_e1     uuid; v_e2 uuid; v_e3 uuid;
  v_links  jsonb;
  v_c1     integer; v_c2 integer;
begin
  begin
    -- ── The fixture: an organisation with an order received ─────────────────
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zznld-' || v_tag, 'Notice Leads Suite',
      'admin@zznld-' || v_tag || '.test', 'Notice Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zznld-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    v_me := erp.current_principal_id();
    select e.id into v_ent from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select i.id into i_fg from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
    select pt.id into p_sup from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'S-FAST';

    v_step := 'an order received';
    v_po := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po, i_fg, 5, 4000, 'stock');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'fixture');
    perform erp.transition_document(v_po, 'send', null);
    x := erp.create_receipt_from_order(v_po, null, 'post');
    v_grn := (x ->> 'document_id')::uuid;
    select d.document_number into v_po_no from erp.document d where d.id = v_po;
    select d.document_number into v_grn_no from erp.document d where d.id = v_grn;

    -- Notices as the routines that write no links write them.
    v_step := 'notices written without links';
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (v_tenant, 'medium', v_me, 'in_app',
            format('ASN-%s-2 arrived different from its notice', v_po_no),
            format('1 line(s) of order %s arrived short, over or not notified; %s holds what came. The order stays open for the rest.',
                   v_po_no, v_grn_no),
            'delivered', now(), now())
    returning id into v_n1;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at)
    values (v_tenant, 'low', v_me, 'in_app', 'ASN-PO-999999-1 has not arrived',
            'The shipment was due yesterday. Chase the supplier.', 'delivered', now(), now())
    returning id into v_n2;
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at, context)
    values (v_tenant, 'low', v_me, 'in_app', format('About %s', v_grn_no), 'See the order.',
            'delivered', now(), now(),
            jsonb_build_object('version', 1, 'links', jsonb_build_object('order', '/documents/' || v_po::text),
                               'fields', jsonb_build_object('order_number', v_po_no)))
    returning id into v_n3;

    -- ── 1. A notice with no links leads to the documents it names ───────────
    select e -> 'links' into v_links
      from jsonb_array_elements(public.erp_my_notifications(100)) e where e ->> 'id' = v_n1::text;
    v_cases := v_cases + 1;
    case_name := 'a notice written with no links leads to the order and the receipt its words name, in that order';
    passed := v_state is null and jsonb_array_length(v_links) = 2
          and v_links -> 0 ->> 'reference' = v_po_no and v_links -> 0 ->> 'path' = '/documents/' || v_po::text
          and v_links -> 1 ->> 'reference' = v_grn_no and v_links -> 1 ->> 'path' = '/documents/' || v_grn::text;
    detail := coalesce(v_state, v_links::text);
    return next;

    -- ── 2. A word that is no document's number leads nowhere ────────────────
    select e -> 'links' into v_links
      from jsonb_array_elements(public.erp_my_notifications(100)) e where e ->> 'id' = v_n2::text;
    v_cases := v_cases + 1;
    case_name := 'a notice whose words name no document of the organisation has no link';
    passed := v_state is null and v_links = '[]'::jsonb;
    detail := coalesce(v_state, v_links::text);
    return next;

    -- ── 3. A notice with its own links keeps exactly them ───────────────────
    select e -> 'links' into v_links
      from jsonb_array_elements(public.erp_my_notifications(100)) e where e ->> 'id' = v_n3::text;
    v_cases := v_cases + 1;
    case_name := 'a notice that carries its own links keeps exactly those, whatever its words name';
    passed := v_state is null and jsonb_array_length(v_links) = 1
          and v_links -> 0 ->> 'path' = '/documents/' || v_po::text;
    detail := coalesce(v_state, v_links::text);
    return next;

    -- ── 4. Deciding a task puts its notice away ─────────────────────────────
    v_step := 'two orders waiting for approval, each with its notice';
    v_po2 := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po2, i_fg, 1, 4000, 'one');
    perform erp.transition_document(v_po2, 'submit', null);
    v_po3 := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po3, i_fg, 1, 4000, 'two');
    perform erp.transition_document(v_po3, 'submit', null);
    select t.id into v_t2 from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
     where t.tenant_id = v_tenant and ar.object_id = v_po2 and t.status = 'pending' order by t.seq limit 1;
    select t.id into v_t3 from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
     where t.tenant_id = v_tenant and ar.object_id = v_po3 and t.status = 'pending' order by t.seq limit 1;
    if v_t2 is null or v_t3 is null then
      raise exception 'the fixture''s orders raised no approval task';
    end if;
    v_e2 := erp.append_event('approval.task_assigned', 'approval_task', v_t2,
                             jsonb_build_object('recipient_ids', jsonb_build_array(v_me),
                               'approval_request_id', (select t.approval_request_id from erp.approval_task t where t.id = v_t2)),
                             v_ent, null);
    v_e3 := erp.append_event('approval.task_assigned', 'approval_task', v_t3,
                             jsonb_build_object('recipient_ids', jsonb_build_array(v_me),
                               'approval_request_id', (select t.approval_request_id from erp.approval_task t where t.id = v_t3)),
                             v_ent, null);
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at, event_id)
    values (v_tenant, 'medium', v_me, 'in_app', 'Approval requested', 'A document is waiting for your approval.',
            'delivered', now(), now(), v_e2),
           (v_tenant, 'medium', v_me, 'in_app', 'Approval requested', 'A document is waiting for your approval.',
            'delivered', now(), now(), v_e3);
    -- And its email, which is not the Inbox's to put away.
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at, event_id, provider_message_id)
    values (v_tenant, 'medium', v_me, 'email', 'Approval requested', 'A document is waiting for your approval.',
            'delivered', now(), now(), v_e2, 'suite-' || v_tag);
    v_step := 'the first order approved';
    perform erp_test.approve_document(v_po2, 'fixture');
    v_cases := v_cases + 1;
    case_name := 'deciding a task marks the notice that asked for it read, and leaves its email and a task still waiting alone';
    passed := v_state is null
          and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.event_id = v_e2
                         and n.channel_kind = 'in_app' and n.status = 'read' and n.read_at is not null)
          and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.event_id = v_e2
                         and n.channel_kind = 'email' and n.status = 'delivered')
          and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.event_id = v_e3
                         and n.channel_kind = 'in_app' and n.status = 'delivered');
    detail := coalesce(v_state, (select string_agg(n.channel_kind::text || ' ' || n.status, ', ')
                                   from erp.notification n where n.tenant_id = v_tenant and n.event_id in (v_e2, v_e3)));
    return next;

    -- ── 5. The notices of tasks decided before are put away once ────────────
    v_step := 'a notice for a task decided before';
    select t.id into v_t1 from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
     where t.tenant_id = v_tenant and ar.object_id = v_po and t.status <> 'pending' order by t.seq limit 1;
    v_e1 := erp.append_event('approval.task_assigned', 'approval_task', v_t1,
                             jsonb_build_object('recipient_ids', jsonb_build_array(v_me),
                               'approval_request_id', (select t.approval_request_id from erp.approval_task t where t.id = v_t1)),
                             v_ent, null);
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body,
                                  status, sent_at, delivered_at, event_id)
    values (v_tenant, 'medium', v_me, 'in_app', 'Approval requested', 'A document is waiting for your approval.',
            'delivered', now(), now(), v_e1);
    v_c1 := erp.put_away_decided_task_notices();
    v_c2 := erp.put_away_decided_task_notices();
    v_cases := v_cases + 1;
    case_name := 'a notice still unread for a task decided before is put away once, and a task still waiting keeps its notice';
    passed := v_state is null and v_t1 is not null and v_c1 = 1 and v_c2 = 0
          and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.event_id = v_e1
                         and n.status = 'read')
          and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.event_id = v_e3
                         and n.channel_kind = 'in_app' and n.status = 'delivered');
    detail := coalesce(v_state, format('first %s, again %s', v_c1, v_c2));
    return next;

    -- ── 6. The Inbox still leads a task's notice to its task ────────────────
    select e -> 'links' into v_links
      from jsonb_array_elements(public.erp_my_notifications(100)) e
     where e ->> 'id' = (select n.id::text from erp.notification n
                          where n.tenant_id = v_tenant and n.event_id = v_e3 and n.channel_kind = 'in_app');
    v_cases := v_cases + 1;
    case_name := 'a task''s notice still leads to its task and its document, as its event says';
    passed := v_state is null and v_links -> 0 ->> 'path' = '/governance?task=' || v_t3::text
          and v_links -> 1 ->> 'path' = '/documents/' || v_po3::text;
    detail := coalesce(v_state, v_links::text);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_NOTICE_LEADS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.notice_leads_suite() from public, anon;

comment on function erp_test.notice_leads_suite() is
  'A notice leads where it says, and goes once decided (20261010013000): a notice with no links leads to the '
  'documents its words name, one with its own keeps them, deciding a task puts its notice away, and a demonstration''s '
  'notices of tasks decided before are put away once.';

create or replace function erp_test.assert_notice_leads_suite()
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
    from erp_test.notice_leads_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_NOTICE_LEADS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A notice leads nowhere it names, or stays unread after its task was decided. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_NOTICE_LEADS_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('notice leads: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_notice_leads_suite() from public, anon;

comment on function erp_test.assert_notice_leads_suite() is
  'A notice leads to what it names, and a decided task''s notice is put away (20261010013000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Each demonstration's notices of tasks decided already, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $put_away$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.put_away_decided_task_notices();
    -- The checks the writes left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the tables.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'notices of decided tasks: % put away in %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$put_away$;

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
