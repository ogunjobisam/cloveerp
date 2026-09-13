-- An action that needs a person tells them.
--
-- Email could reach nobody for the things that wait on somebody. Four gaps,
-- each found by reading the chain from the thing that happened to the inbox:
--
--   * Nothing was raised when an approval task was opened for a person, when
--     one was delegated to them, or when an overdue one moved to its
--     escalation target. erp.approval_task had three writers and none of them
--     appended an event, so no route could have matched.
--   * A configuration change submitted on a live organisation waits for
--     somebody other than its author. Nothing said so to anybody.
--   * No audience could name the person an event is about. A route reached a
--     role, a department, a fixed person or the owner of the object; the
--     assignee of a task is none of those.
--   * Every route was organisation configuration, installed only by applying
--     and promoting the base pack, and routing itself ran only where somebody
--     had pressed "Install notification services". Nothing installed them.
--
-- What this adds, in order:
--
--   1. Three events: approval.task_assigned and approval.task_escalated, raised
--      by one trigger on erp.approval_task so every writer is covered, and
--      change_set.submitted, raised by the submit on a live organisation. Each
--      carries recipient_ids: the people who must act.
--   2. An audience kind, recipients, that reads recipient_ids from the event,
--      bounded to the route's organisation and to active people.
--   3. Product routes every organisation has, in erp_ref.notification_route_default.
--      An organisation route with the same code replaces one, so an organisation
--      switches a product route off with an inactive route of that code. The
--      job_failed and support_access_granted codes are the base pack's own, so
--      an organisation that promoted those routes is not told twice. A product
--      route email is the body, a blank line, and the address of the screen
--      where the person acts; never an event type or an identifier. A role
--      route leaves out whoever raised the event.
--   4. erp.ensure_notification_services(), run for every organisation by the
--      minute pass. It installs the routing and dispatch jobs only where they
--      are absent, so a job an organisation switched off stays off, and when it
--      installs for an organisation that has never routed it starts that
--      organisation's watermark at its latest event, so nothing already
--      recorded is emailed. Existing organisations are backfilled here.
--   5. Two repairs the scouting found on the way: the base pack's
--      approval_escalated route goes to the object owner, and for an approval
--      that is the person who asked for it, which the audience could not find;
--      and the readiness report said "no notification route is defined" to an
--      organisation that now has five.
--
-- Not changed: the approval_ageing and integration_backlog_alert jobs still ship
-- disabled, so escalations happen where an organisation enables ageing. The
-- routes screen door lists organisation routes only. Invitations are emailed by
-- the invite Edge Function, not by a route.
--
-- Proof: erp_test.notification_product_routes_suite() (22), and the chain,
-- output channels, email delivery, walkthrough and stranded work suites.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The words, and the events
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('app.base_url', 'en', 'https://cloveerp.com', 'administration',
   'The address of the desk. A product email ends with this and the path of the screen where the person acts.'),
  ('app.base_url', 'de', 'https://cloveerp.com', 'administration',
   'The address of the desk. A product email ends with this and the path of the screen where the person acts.'),
  ('notify.change_set_awaiting_approval.subject', 'en',
   'A configuration change is waiting for your approval', 'administration',
   'Subject when a configuration change is submitted on a live organisation.'),
  ('notify.change_set_awaiting_approval.subject', 'de',
   'Eine Konfigurationsänderung wartet auf Ihre Genehmigung', 'administration',
   'Subject when a configuration change is submitted on a live organisation.'),
  ('notify.change_set_awaiting_approval.body', 'en',
   'A configuration change has been submitted and needs somebody other than its author to approve it. Open Configuration to review it, approve it and put it in force.',
   'administration', 'Body when a configuration change is submitted on a live organisation.'),
  ('notify.change_set_awaiting_approval.body', 'de',
   'Eine Konfigurationsänderung wurde eingereicht und muss von jemand anderem als ihrem Verfasser genehmigt werden. Öffnen Sie die Konfiguration, um sie zu prüfen, zu genehmigen und in Kraft zu setzen.',
   'administration', 'Body when a configuration change is submitted on a live organisation.'),
  ('event.approval.task_assigned', 'en', 'Approval task assigned', 'administration',
   'The event raised when an approval task is opened for a person.'),
  ('event.approval.task_assigned', 'de', 'Genehmigungsaufgabe zugewiesen', 'administration',
   'The event raised when an approval task is opened for a person.'),
  ('event.approval.task_escalated', 'en', 'Approval task escalated', 'administration',
   'The event raised when an overdue approval task moves to its escalation target.'),
  ('event.approval.task_escalated', 'de', 'Genehmigungsaufgabe eskaliert', 'administration',
   'The event raised when an overdue approval task moves to its escalation target.'),
  ('event.change_set.submitted', 'en', 'Configuration change submitted', 'administration',
   'The event raised when a configuration change is submitted on a live organisation.'),
  ('event.change_set.submitted', 'de', 'Konfigurationsänderung eingereicht', 'administration',
   'The event raised when a configuration change is submitted on a live organisation.')
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code, description = excluded.description;

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('approval.task_assigned', 1, 'approval_task', 'administration', 'event.approval.task_assigned',
   'An approval task was opened for a named person: a step reached them, or '
   'somebody delegated theirs to them. recipient_ids is that person.',
   '{"type": "object", "required": ["recipient_ids", "approval_request_id"],
     "properties": {"recipient_ids": {"type": "array", "items": {"type": "string"}},
                    "approval_request_id": {"type": "string"}}}'::jsonb, true),
  ('approval.task_escalated', 1, 'approval_task', 'administration', 'event.approval.task_escalated',
   'An approval task aged past its due time and a task was opened for its '
   'escalation target. recipient_ids is that person.',
   '{"type": "object", "required": ["recipient_ids", "approval_request_id"],
     "properties": {"recipient_ids": {"type": "array", "items": {"type": "string"}},
                    "approval_request_id": {"type": "string"}}}'::jsonb, true),
  ('change_set.submitted', 1, 'change_set', 'administration', 'event.change_set.submitted',
   'A configuration change was submitted on a live organisation and waits for '
   'somebody other than its author. recipient_ids is everybody else who can '
   'approve it at the moment it was submitted.',
   '{"type": "object", "required": ["recipient_ids"],
     "properties": {"recipient_ids": {"type": "array", "items": {"type": "string"}}}}'::jsonb, true)
on conflict (code, version) do update set
  aggregate_type = excluded.aggregate_type, module_code = excluded.module_code,
  name_key = excluded.name_key, description = excluded.description,
  payload_schema = excluded.payload_schema, is_current = excluded.is_current;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. An approval task announces the person it waits on
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A trigger rather than three patched bodies: the step opener, delegation and
-- escalation all insert the task, and a fourth writer added later is covered
-- without anybody remembering. Only a pending task with an assignee is
-- announced; a skipped step and a role task nobody holds are not people.

create or replace function erp.announce_approval_task()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  q erp.approval_request%rowtype;
begin
  if new.status <> 'pending' or new.assignee_user_id is null then
    return null;
  end if;

  -- The event store stamps the organisation the session acts for. Every
  -- writer inserts for that organisation; a row for any other is not
  -- announced rather than recorded against the wrong one.
  if new.tenant_id is distinct from erp.current_tenant_id() then
    return null;
  end if;

  select * into q
    from erp.approval_request ar
   where ar.tenant_id = new.tenant_id and ar.id = new.approval_request_id;

  perform erp.append_event(
    case when new.escalated_from is null then 'approval.task_assigned'
         else 'approval.task_escalated' end,
    'approval_task', new.id,
    jsonb_strip_nulls(jsonb_build_object(
      'recipient_ids', jsonb_build_array(new.assignee_user_id),
      'approval_request_id', new.approval_request_id,
      'object_type', q.object_type,
      'object_id', q.object_id,
      'step_code', new.step_code,
      'due_at', new.due_at,
      'delegated_from', new.delegated_from,
      'escalated_from', new.escalated_from)),
    q.entity_id, q.site_id);

  return null;
end;
$$;

revoke all on function erp.announce_approval_task() from public, anon, authenticated;

comment on function erp.announce_approval_task() is
  'Raises approval.task_assigned, or approval.task_escalated for a task opened by '
  'escalation, naming the assignee in recipient_ids, for every pending task with '
  'an assignee. The product route that carries it emails the person who must act.';

drop trigger if exists t_approval_task_announced on erp.approval_task;
create trigger t_approval_task_announced
  after insert on erp.approval_task
  for each row execute function erp.announce_approval_task();

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A change submitted on a live organisation names who can approve it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Only the path with no approval chain: a chain opens approval tasks, and the
-- trigger above announces those. Before go-live the installer approves its own
-- changes, so nothing is raised. The event is appended after the status moves,
-- so any refusal the update meets is the one the caller sees.

do $submit$
declare
  v_def text := pg_get_functiondef('erp.submit_change_set(uuid)'::regprocedure);
  v_n   text := $n$  update erp.change_set set status = 'ready', updated_at = now()
   where tenant_id = v_tenant and id = p_change_set_id;
  return 'ready';
$n$;
  v_r   text := $n$  update erp.change_set set status = 'ready', updated_at = now()
   where tenant_id = v_tenant and id = p_change_set_id;

  -- On a live organisation the author may not approve their own change, so it
  -- waits for somebody else. The event names everybody else who can approve it
  -- now: active people holding administration.promote, less its author and
  -- whoever submitted it.
  if erp.tenant_is_live(v_tenant) then
    perform erp.append_event('change_set.submitted', 'change_set', p_change_set_id,
      jsonb_build_object(
        'item_count', v_items,
        'recipient_ids', coalesce((
          select jsonb_agg(distinct ep.app_user_id)
            from erp.effective_permission ep
            join erp.app_user u on u.tenant_id = ep.tenant_id and u.id = ep.app_user_id
           where ep.tenant_id = v_tenant
             and ep.permission_code = 'administration.promote'
             and ep.valid_from <= current_date
             and (ep.valid_to is null or ep.valid_to >= current_date)
             and u.status = 'active' and u.kind = 'person'
             and u.id is distinct from (select c.created_by from erp.change_set c
                                         where c.tenant_id = v_tenant and c.id = p_change_set_id)
             and u.id is distinct from erp.current_principal_id()),
          '[]'::jsonb)));
  end if;

  return 'ready';
$n$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_SUBMIT_UNRECOGNISED: erp.submit_change_set() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$submit$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. An audience the event names
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.notification_route drop constraint if exists notification_route_audience_known;
alter table erp.notification_route add constraint notification_route_audience_known
  check (audience_kind in ('role', 'department', 'user', 'object_owner', 'recipients'));

alter table erp.notification_route drop constraint if exists notification_route_audience_named;
alter table erp.notification_route add constraint notification_route_audience_named
  check ((audience_kind = 'role' and role_id is not null)
      or (audience_kind = 'department' and department_id is not null)
      or (audience_kind = 'user' and app_user_id is not null)
      or (audience_kind in ('object_owner', 'recipients')));

do $audience$
declare
  v_def text := pg_get_functiondef('erp.notification_audience(erp.notification_route,erp.event)'::regprocedure);
begin
  if position('elsif p_route.audience_kind = ''department'' then' in v_def) = 0
     or position('-- The owner of the affected object: whoever created it, where the aggregate' in v_def) = 0
     or position('recipients' in v_def) > 0 then
    raise exception 'CLOVEERP_AUDIENCE_UNRECOGNISED: erp.notification_audience() is not the 20260904570000 body this migration re-emits';
  end if;
end
$audience$;

create or replace function erp.notification_audience(p_route erp.notification_route, p_event erp.event)
returns setof uuid
language plpgsql
stable
set search_path = ''
as $$
declare v_owner uuid; v_sql text;
begin
  if p_route.audience_kind = 'user' then
    return query select u.id from erp.app_user u
                  where u.tenant_id = p_route.tenant_id and u.id = p_route.app_user_id and u.status = 'active';
  elsif p_route.audience_kind = 'role' then
    return query select distinct ur.app_user_id from erp.user_role ur
                  join erp.app_user u on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
                 where ur.tenant_id = p_route.tenant_id and ur.role_id = p_route.role_id
                   and ur.valid_from <= current_date and (ur.valid_to is null or ur.valid_to >= current_date)
                   and u.status = 'active' and u.kind = 'person';
  elsif p_route.audience_kind = 'department' then
    return query select distinct pd.app_user_id from erp.principal_department pd
                  join erp.app_user u on u.tenant_id = pd.tenant_id and u.id = pd.app_user_id
                 where pd.tenant_id = p_route.tenant_id and pd.department_id = p_route.department_id
                   and pd.status = 'active'
                   and pd.valid_from <= current_date and (pd.valid_to is null or pd.valid_to >= current_date)
                   and u.status = 'active' and u.kind = 'person';
  elsif p_route.audience_kind = 'recipients' then
    -- The people the event itself names in recipient_ids: the assignee of a
    -- task, the approvers of a change. Bounded to the route's organisation, to
    -- an event of that organisation and to active people, so a payload can
    -- never widen an audience beyond who could already be reached.
    return query select u.id from erp.app_user u
                  where u.tenant_id = p_route.tenant_id
                    and p_event.tenant_id = p_route.tenant_id
                    and u.status = 'active' and u.kind = 'person'
                    and u.id in (
                      select x.value::uuid
                        from jsonb_array_elements_text(
                               case when jsonb_typeof(p_event.payload -> 'recipient_ids') = 'array'
                                    then p_event.payload -> 'recipient_ids'
                                    else '[]'::jsonb end) x
                       where x.value ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
  else
    -- The owner of the affected object: whoever created it, where the aggregate
    -- is a table with attribution; otherwise the actor who raised the event.
    -- An approval event hangs off its request, and there is no approval table,
    -- so the owner of an approval is the person who asked for it. Without this
    -- an escalation, raised by a job with nobody signed in, reached nobody.
    if p_event.aggregate_type = 'approval' then
      select coalesce(ar.requested_by, ar.created_by) into v_owner
        from erp.approval_request ar
       where ar.tenant_id = p_route.tenant_id and ar.id = p_event.aggregate_id;
    elsif exists (select 1 from information_schema.columns c
                   where c.table_schema = 'erp' and c.table_name = p_event.aggregate_type
                     and c.column_name = 'created_by') then
      v_sql := format('select created_by from erp.%I where id = $1', p_event.aggregate_type);
      execute v_sql into v_owner using p_event.aggregate_id;
    end if;
    v_owner := coalesce(v_owner, p_event.actor_id);
    return query select u.id from erp.app_user u
                  where u.tenant_id = p_route.tenant_id and u.id = v_owner and u.status = 'active' and u.kind = 'person';
  end if;
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Routes every organisation has
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.notification_route_default (
  code           text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  event_pattern  text not null check (length(btrim(event_pattern)) > 0),
  severity       erp.notification_severity not null default 'medium',
  audience_kind  text not null check (audience_kind in ('role', 'recipients')),
  role_code      text,
  channel_kind   erp.notification_channel_kind not null default 'email',
  subject_key    text not null,
  body_key       text not null,
  -- The screen where the person acts. The email ends with the desk's address
  -- and this, so a person goes straight to the thing waiting for them.
  link_path      text not null references erp_ref.help_topic (screen_path),
  -- A mandatory route ignores a person's switched-off channel. A task
  -- waiting on somebody is not: they may choose to hear about it in the
  -- product only.
  is_mandatory   boolean not null default false,
  constraint notification_route_default_role_named
    check ((audience_kind = 'role') = (role_code is not null)),
  constraint notification_route_default_channel_known
    check (channel_kind in ('email', 'in_app'))
);

comment on table erp_ref.notification_route_default is
  '§15.6. Routes every organisation has without configuring one. An organisation '
  'route with the same code replaces the product route, active or not, so an '
  'organisation switches one off with an inactive route of that code.';

select erp_meta.register_table('erp_ref', 'notification_route_default', 'product_content',
  '§15.6. Routes every organisation has without configuring one; an organisation route of the same code replaces it.');

insert into erp_ref.notification_route_default
  (code, event_pattern, severity, audience_kind, role_code, channel_kind,
   subject_key, body_key, link_path, is_mandatory)
values
  ('approval_task_assigned', 'approval.task_assigned', 'medium', 'recipients', null, 'email',
   'notify.approval_requested.subject', 'notify.approval_requested.body', '/governance', false),
  ('approval_task_escalated', 'approval.task_escalated', 'high', 'recipients', null, 'email',
   'notify.approval_escalated.subject', 'notify.approval_escalated.body', '/governance', false),
  ('change_set_awaiting_approval', 'change_set.submitted', 'medium', 'recipients', null, 'email',
   'notify.change_set_awaiting_approval.subject', 'notify.change_set_awaiting_approval.body',
   '/administration/configuration', false),
  ('job_failed', 'job.failed', 'high', 'role', 'administrator', 'email',
   'notify.job_failed.subject', 'notify.job_failed.body', '/operations/jobs', true),
  ('support_access_granted', 'support.access_granted', 'high', 'role', 'administrator', 'email',
   'notify.support_access_granted.subject', 'notify.support_access_granted.body',
   '/operations/continuity', true)
on conflict (code) do update set
  event_pattern = excluded.event_pattern, severity = excluded.severity,
  audience_kind = excluded.audience_kind, role_code = excluded.role_code,
  channel_kind = excluded.channel_kind, subject_key = excluded.subject_key,
  body_key = excluded.body_key, link_path = excluded.link_path,
  is_mandatory = excluded.is_mandatory;

do $router$
declare
  v_def text := pg_get_functiondef('erp.route_notifications()'::regprocedure);
begin
  if position('insert into erp.notification_watermark (tenant_id) values (v_tenant) on conflict do nothing;' in v_def) = 0
     or position('v_body := coalesce(nullif(erp.text(v_tpl.body_key), v_tpl.body_key), rt.name)' in v_def) = 0
     or position('notification_route_default' in v_def) > 0 then
    raise exception 'CLOVEERP_ROUTER_UNRECOGNISED: erp.route_notifications() is not the 20260904570000 body this migration re-emits';
  end if;
end
$router$;

create or replace function erp.route_notifications()
returns table(routed integer, held integer, last_seq bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from   bigint;
  v_max    bigint;
  ev       erp.event%rowtype;
  rt       erp.notification_route%rowtype;
  pr       erp_ref.notification_route_default%rowtype;
  prt      erp.notification_route%rowtype;
  v_blank  erp.notification_route%rowtype;
  v_user   uuid;
  v_locale text;
  v_base   text;
  v_chan   erp.notification_channel_kind;
  v_subj   text; v_body text; v_tpl erp.notification_template%rowtype;
  v_hold   timestamptz;
  n_routed integer := 0; n_held integer := 0;
begin
  insert into erp.notification_watermark (tenant_id) values (v_tenant) on conflict do nothing;
  select w.last_global_seq into v_from from erp.notification_watermark w where w.tenant_id = v_tenant;
  v_max := v_from;

  -- The desk's address, as the product ships it. Read from the product string
  -- rather than through an organisation's wording, so the link in an email the
  -- platform sends always leads to the platform.
  v_base := coalesce((select r.value from erp_ref.resource r
                       where r.key = 'app.base_url' and r.locale = 'en'),
                     'https://cloveerp.com');

  for ev in
    select * from erp.event e
     where e.tenant_id = v_tenant and e.global_seq > v_from
     order by e.global_seq limit 500
  loop
    v_max := greatest(v_max, ev.global_seq);
    for rt in
      select * from erp.notification_route r
       where r.tenant_id = v_tenant and r.status = 'active' and ev.event_type like r.event_pattern
    loop
      select * into v_tpl from erp.notification_template t
       where t.tenant_id = v_tenant and t.code = rt.template_code;
      v_subj := coalesce(nullif(erp.text(v_tpl.subject_key), v_tpl.subject_key), rt.name);
      v_body := coalesce(nullif(erp.text(v_tpl.body_key), v_tpl.body_key), rt.name)
                || ' — ' || ev.event_type || ' · ' || ev.aggregate_type || ' ' || ev.aggregate_id::text;

      for v_user in select * from erp.notification_audience(rt, ev) loop
        -- §15.6: preferences within bounds. A switched-off channel becomes
        -- in-app unless the route is mandatory; nothing is lost either way.
        v_chan := rt.channel_kind;
        if v_chan <> 'in_app' and not rt.is_mandatory and exists (
             select 1 from erp.notification_preference p
              where p.tenant_id = v_tenant and p.app_user_id = v_user
                and p.channel_kind = rt.channel_kind and not p.is_enabled) then
          v_chan := 'in_app';
        end if;
        -- Quiet hours hold; the override severity breaks through inside
        -- erp.in_quiet_hours() itself.
        v_hold := null;
        if erp.in_quiet_hours(v_user, rt.severity) then
          v_hold := erp.quiet_hours_end(v_user, rt.severity);
        end if;
        insert into erp.notification
          (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
           status, held_until, digest_key)
        values (v_tenant, rt.id, ev.id, rt.severity, v_user, v_chan, v_subj, v_body,
                case when v_hold is not null then 'held' else 'pending' end, v_hold,
                case when rt.digest_minutes is not null then rt.code || ':' || v_user::text end);
        n_routed := n_routed + 1;
        if v_hold is not null then n_held := n_held + 1; end if;
      end loop;
    end loop;

    -- The product's own routes, where the organisation has no route of the
    -- same code. Words in the recipient's language, then a blank line and the
    -- screen where they act: no event type and no identifier.
    for pr in
      select d.* from erp_ref.notification_route_default d
       where ev.event_type like d.event_pattern
         and not exists (select 1 from erp.notification_route r
                          where r.tenant_id = v_tenant and r.code = d.code)
       order by d.code
    loop
      prt := v_blank;
      prt.tenant_id     := v_tenant;
      prt.code          := pr.code;
      prt.name          := pr.code;
      prt.event_pattern := pr.event_pattern;
      prt.severity      := pr.severity;
      prt.audience_kind := pr.audience_kind;
      prt.channel_kind  := pr.channel_kind;
      prt.is_mandatory  := pr.is_mandatory;
      prt.status        := 'active';
      if pr.audience_kind = 'role' then
        select ro.id into prt.role_id from erp.role ro
         where ro.tenant_id = v_tenant and ro.code = pr.role_code and ro.status = 'active';
        continue when prt.role_id is null;
      end if;

      for v_user, v_locale in
        select a.app_user_id, u.user_locale
          from erp.notification_audience(prt, ev) as a(app_user_id)
          join erp.app_user u on u.tenant_id = v_tenant and u.id = a.app_user_id
         -- Nobody needs an email about what they have just done.
         where pr.audience_kind <> 'role' or ev.actor_id is null or a.app_user_id <> ev.actor_id
      loop
        v_chan := pr.channel_kind;
        if v_chan <> 'in_app' and not pr.is_mandatory and exists (
             select 1 from erp.notification_preference p
              where p.tenant_id = v_tenant and p.app_user_id = v_user
                and p.channel_kind = pr.channel_kind and not p.is_enabled) then
          v_chan := 'in_app';
        end if;
        v_subj := erp.text(pr.subject_key, v_locale);
        v_body := erp.text(pr.body_key, v_locale) || E'\n\n' || v_base || pr.link_path;
        v_hold := null;
        if erp.in_quiet_hours(v_user, pr.severity) then
          v_hold := erp.quiet_hours_end(v_user, pr.severity);
        end if;
        insert into erp.notification
          (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
           status, held_until)
        values (v_tenant, null, ev.id, pr.severity, v_user, v_chan, v_subj, v_body,
                case when v_hold is not null then 'held' else 'pending' end, v_hold);
        n_routed := n_routed + 1;
        if v_hold is not null then n_held := n_held + 1; end if;
      end loop;
    end loop;
  end loop;

  update erp.notification_watermark set last_global_seq = v_max, updated_at = now()
   where tenant_id = v_tenant;
  routed := n_routed; held := n_held; last_seq := v_max;
  return next;
end;
$$;

comment on function erp.route_notifications is
  'Specification v1.2 §15.6: reads the event stream past the watermark and, '
  'for every active route the event matches, writes one notification per '
  'person in the audience — on their preferred channel within the '
  'organisation''s bounds, held if they are in quiet hours, keyed for a digest '
  'if the route digests. Then the product''s own routes, where the organisation '
  'has no route of the same code, each ending with the screen where the person acts.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Notification services install themselves
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.ensure_notification_services()
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_made   integer := 0;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not install notification services', current_user
      using errcode = '42501',
            hint = 'The platform''s minute pass installs them for every organisation. An administrator switches either job off on the jobs screen.';
  end if;

  v_tenant := erp.require_tenant_id();

  -- Absent, not disabled: a job the organisation switched off is a decision,
  -- and installing over it would reverse the decision every minute.
  if not exists (select 1 from erp.job j
                  where j.tenant_id = v_tenant
                    and (j.handler_code = 'notifications.route_events' or j.code = 'route_notifications')) then
    perform erp.upsert_job('route_notifications', 'Route notifications', 'notifications.route_events',
                           'interval', 120, null, null, null, 'UTC', '{}'::jsonb, 300, null, true);
    v_made := v_made + 1;
  end if;

  if not exists (select 1 from erp.job j
                  where j.tenant_id = v_tenant
                    and (j.handler_code = 'notifications.dispatch' or j.code = 'dispatch_notifications')) then
    perform erp.upsert_job('dispatch_notifications', 'Dispatch notifications', 'notifications.dispatch',
                           'interval', 120, null, null, null, 'UTC', '{}'::jsonb, 300, null, true);
    v_made := v_made + 1;
  end if;

  -- An organisation that has never routed would otherwise start from its first
  -- event, and every job that ever failed would arrive in somebody's inbox at
  -- once. Routing starts from now.
  if v_made > 0 then
    insert into erp.notification_watermark (tenant_id, last_global_seq)
    values (v_tenant, coalesce((select max(e.global_seq) from erp.event e where e.tenant_id = v_tenant), 0))
    on conflict (tenant_id) do nothing;
  end if;

  return v_made;
end;
$$;

revoke all on function erp.ensure_notification_services() from public, anon, authenticated;

comment on function erp.ensure_notification_services() is
  '§15.6. Installs the routing and dispatch jobs for the organisation the '
  'session acts for, where either is absent, and starts a never-routed '
  'organisation''s watermark at its latest event. A disabled job stays '
  'disabled. Returns how many jobs it installed. Run by the minute pass.';

-- Existing organisations start routing from now, not from their first event.
-- Every organisation, not only the active ones: a row that already exists is
-- left exactly where routing had got to.
insert into erp.notification_watermark (tenant_id, last_global_seq)
select t.id, coalesce((select max(e.global_seq) from erp.event e where e.tenant_id = t.id), 0)
  from erp.tenant t
on conflict (tenant_id) do nothing;

-- And they have the services from this release, rather than from the next
-- minute. An organisation the install fails for is named, not fatal: the
-- minute pass tries again and reports the reason beside that organisation.
do $install$
declare
  t        record;
  v_made   integer;
  v_total  integer := 0;
  v_failed text;
begin
  for t in select tn.id, tn.code from erp.tenant tn where tn.status = 'active' order by tn.code loop
    perform set_config('erp.job_tenant_id', t.id::text, true);
    perform set_config('erp.job_principal_id', '', true);
    begin
      v_made := erp.ensure_notification_services();
      v_total := v_total + v_made;
    exception when others then
      v_failed := concat_ws('; ', v_failed, t.code || ': ' || left(sqlerrm, 200));
    end;
  end loop;
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);

  if v_failed is not null then
    raise warning 'notification services were not installed for: %', v_failed;
  end if;
  raise notice 'notification services: % job(s) installed', v_total;
end
$install$;

-- The minute pass keeps it so. Inside the organisation's own block, after the
-- incident step, in a block of its own so an install that fails costs that
-- minute's install and never that organisation's jobs; the reason is reported
-- beside the organisation in the pass's result.
do $sweep$
declare
  v_def  text := pg_get_functiondef('erp.run_due_jobs_all_tenants(integer)'::regprocedure);
  v_decl text := $n$  v_comm    jsonb;
$n$;
  v_call text := $n$      v_comm := erp.communicate_incidents();
$n$;
  v_out  text := $n$'reclaimed', v_recl, 'incidents', v_comm));$n$;
begin
  if (length(v_def) - length(replace(v_def, v_decl, ''))) / length(v_decl) <> 1
     or (length(v_def) - length(replace(v_def, v_call, ''))) / length(v_call) <> 1
     or (length(v_def) - length(replace(v_def, v_out, ''))) / length(v_out) <> 1
     or position('ensure_notification_services' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_due_jobs_all_tenants() is not the 20260906120000 body this migration patches';
  end if;

  v_def := replace(v_def, v_decl, v_decl || $n$  v_notify  jsonb;
$n$);
  v_def := replace(v_def, v_call, v_call || $n$      -- Then notification services, where this organisation has none. Only an
      -- absent job is installed, so one the organisation switched off stays off.
      begin
        v_notify := to_jsonb(erp.ensure_notification_services());
      exception when others then
        v_notify := jsonb_build_object('error', left(sqlerrm, 200));
      end;
$n$);
  v_def := replace(v_def, v_out, $n$'reclaimed', v_recl, 'incidents', v_comm, 'notification_services', v_notify));$n$);
  execute v_def;
end
$sweep$;

-- The walkthrough's "recurring tasks" step is about the tasks an organisation
-- sets up. The platform installing notification services is not that, and
-- would otherwise tick the step for everybody.
do $evidence$
declare
  v_def text := pg_get_functiondef('erp.setup_evidence()'::regprocedure);
  v_n   text := $n$(select count(*) from erp.job j, t where j.tenant_id = t.id)$n$;
  v_r   text := $n$(select count(*) from erp.job j, t where j.tenant_id = t.id and j.handler_code not like 'notifications.%')$n$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_EVIDENCE_UNRECOGNISED: erp.setup_evidence() is not the 20260913022000 body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$evidence$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The reports know about the product's routes
-- ═════════════════════════════════════════════════════════════════════════════

do $readiness$
declare
  v_def text := pg_get_functiondef('erp.email_readiness_report()'::regprocedure);
begin
  if position('no notification route is defined' in v_def) = 0
     or position('notification_route_default' in v_def) > 0 then
    raise exception 'CLOVEERP_READINESS_UNRECOGNISED: erp.email_readiness_report() is not the 20260904750000 body this migration re-emits';
  end if;
end
$readiness$;

create or replace function erp.email_readiness_report()
returns table (finding text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Every organisation has the product's own routes now, so this finding is
  -- only true of a build that ships none.
  select 'no notification route is defined',
         'no event becomes a notification at all, so nothing reaches the queue'
   where not exists (select 1 from erp.notification_route rt
                      where rt.tenant_id = erp.current_tenant_id() and rt.status = 'active')
     and not exists (select 1 from erp_ref.notification_route_default d)
  union all
  select 'notification services are not running',
         'routing or dispatch is switched off or missing, so events do not become email'
   where (select count(distinct j.handler_code) from erp.job j
           where j.tenant_id = erp.current_tenant_id() and j.is_enabled
             and j.handler_code in ('notifications.route_events', 'notifications.dispatch')) < 2
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

do $chain$
declare
  v_def text := pg_get_functiondef('erp.notification_chain_report()'::regprocedure);
begin
  if position('the route waits on an unregistered event type' in v_def) = 0
     or position('notification_route_default' in v_def) > 0 then
    raise exception 'CLOVEERP_CHAIN_REPORT_UNRECOGNISED: erp.notification_chain_report() is not the 20260904920000 body this migration re-emits';
  end if;
end
$chain$;

create or replace function erp.notification_chain_report()
returns table (template_code text, finding text, detail text)
language sql
stable
set search_path to ''
as $$
  -- A template with no route says nothing to anybody. A route naming a
  -- template that does not exist renders nothing. A route waiting on an event
  -- type the product does not register waits for ever. All three are the same
  -- fault seen from different ends, so they are reported together.
  select pi.object_key, 'no route carries this template',
         'the base pack ships it and nothing routes it, so it renders to nobody'
    from erp_ref.pack_item pi
   where pi.object_kind = 'notification_template'
     and not exists (
       select 1 from erp_ref.pack_item r
        where r.object_kind = 'notification_route'
          and r.payload ->> 'template_code' = pi.object_key)

  union all

  select r.payload ->> 'template_code', 'the route names a template no pack ships',
         'route ' || r.object_key
    from erp_ref.pack_item r
   where r.object_kind = 'notification_route'
     and not exists (
       select 1 from erp_ref.pack_item t
        where t.object_kind = 'notification_template'
          and t.object_key = r.payload ->> 'template_code')

  union all

  select r.payload ->> 'template_code', 'the route waits on an unregistered event type',
         'route ' || r.object_key || ' waits on ' || (r.payload ->> 'event_pattern')
    from erp_ref.pack_item r
   where r.object_kind = 'notification_route'
     and not exists (
       select 1 from erp_ref.event_type e
        where e.is_current and r.payload ->> 'event_pattern' like e.code)

  union all

  -- The product's own routes are held to the same standard, and to two more:
  -- they speak in every language the product ships, and they go to a role that
  -- exists in every organisation, because nobody configured them.
  select d.code, 'the product route waits on an unregistered event type',
         'product route ' || d.code || ' waits on ' || d.event_pattern
    from erp_ref.notification_route_default d
   where not exists (
       select 1 from erp_ref.event_type e
        where e.is_current and e.code like d.event_pattern)

  union all

  select d.code, 'the product route names words that do not exist',
         format('product route %s has no %s string for %s', d.code, l.locale, w.key)
    from erp_ref.notification_route_default d
    cross join lateral (values (d.subject_key), (d.body_key), ('app.base_url')) as w(key)
    cross join (values ('en'), ('de')) as l(locale)
   where not exists (
       select 1 from erp_ref.resource res
        where res.key = w.key and res.locale = l.locale)

  union all

  select d.code, 'the product route goes to a role an organisation may not have',
         format('product route %s goes to %s; only administrator exists in every organisation from the day it is provisioned',
                d.code, d.role_code)
    from erp_ref.notification_route_default d
   where d.audience_kind = 'role' and d.role_code is distinct from 'administrator'

  order by 2, 1
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.notification_product_routes_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r           record;
  v_tenant    uuid;
  a_admin     uuid := gen_random_uuid();
  a_second    uuid := gen_random_uuid();
  a_approver  uuid := gen_random_uuid();
  u_admin     uuid;
  u_second    uuid;
  u_approver  uuid;
  u_target    uuid;
  u_invited   uuid;
  v_chain     uuid;
  v_ver       uuid;
  v_req       uuid;
  v_first_req uuid;
  v_task      uuid;
  v_old       uuid;
  v_event     uuid;
  v_ev        erp.event%rowtype;
  v_route     erp.notification_route%rowtype;
  v_org_route uuid;
  v_cs        uuid;
  v_n         integer;
  v_body      text;
  v_base      text;
begin
  -- ── An organisation, live from provisioning, with the people the cases need
  select * into r from erp.provision_tenant(
    'zzprodroute', 'Product Routes Suite', 'admin@zzprodroute.test', 'Product Routes Admin');
  v_tenant := r.tenant_id;

  insert into auth.users (id, email)
  values (a_admin, 'admin@zzprodroute.test'),
         (a_second, 'second@zzprodroute.test'),
         (a_approver, 'approver@zzprodroute.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', a_admin, 'role', 'authenticated')::text, true);
  u_admin := erp.claim_invitation(r.admin_token);

  -- A second administrator, who can approve what the first submits.
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
  values (v_tenant, a_second, 'person', 'active', 'Product Routes Second', 'second@zzprodroute.test', 'en')
  returning id into u_second;
  insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
  select v_tenant, u_second, ro.id, 'the suite needs somebody other than the author who can approve a change'
    from erp.role ro
   where ro.tenant_id = v_tenant and ro.code = 'administrator' and ro.status = 'active';

  -- An approver named on a step, holding no role at all.
  insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
  values (v_tenant, a_approver, 'person', 'active', 'Product Routes Approver', 'approver@zzprodroute.test', 'en')
  returning id into u_approver;

  -- The person an overdue task escalates to.
  insert into erp.app_user (tenant_id, kind, status, display_name, email, user_locale)
  values (v_tenant, 'person', 'active', 'Product Routes Escalation', 'escalation@zzprodroute.test', 'en')
  returning id into u_target;

  -- Somebody invited who has not yet joined.
  insert into erp.app_user (tenant_id, kind, status, display_name, email, user_locale)
  values (v_tenant, 'person', 'invited', 'Product Routes Invitee', 'invited@zzprodroute.test', 'en')
  returning id into u_invited;

  -- One approval chain: a step naming the approver, escalating after an hour
  -- to the escalation target. Built with the window open, as configuration is.
  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.approval_chain (tenant_id, code, name, object_type)
  values (v_tenant, 'zz_product_routes', 'Product routes suite', 'zz_product_route')
  returning id into v_chain;
  insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status)
  values (v_tenant, v_chain, 1, 'draft')
  returning id into v_ver;
  insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
                                 app_user_id, escalate_after, escalate_to_user_id)
  values (v_tenant, v_ver, 1, 'named', 'The named approver', 'user', u_approver,
          interval '1 hour', u_target);
  perform erp.activate_approval_chain_version(v_ver, current_date);
  perform erp_test.close_bootstrap_window(v_tenant);

  v_base := erp.text('app.base_url');

  -- A failure recorded before notification services existed.
  v_old := erp.append_event('job.failed', 'job', gen_random_uuid(), '{}'::jsonb);

  -- ── 1-5. Notification services install themselves ──────────────────────────
  v_n := erp.ensure_notification_services();
  case_name := 'notification services are installed where an organisation has none';
  passed := v_n = 2
        and (select count(*) from erp.job j
              where j.tenant_id = v_tenant and j.is_enabled
                and j.handler_code in ('notifications.route_events', 'notifications.dispatch')) = 2;
  detail := format('%s job(s) installed: routing and dispatch', v_n);
  return next;

  case_name := 'and routing starts from now, so what was already recorded is never emailed';
  passed := coalesce((select w.last_global_seq from erp.notification_watermark w where w.tenant_id = v_tenant)
                     >= (select e.global_seq from erp.event e where e.id = v_old), false);
  detail := 'the watermark starts at the organisation''s latest event, past the failure recorded before';
  return next;

  v_n := erp.ensure_notification_services();
  case_name := 'a second pass installs nothing';
  passed := v_n = 0
        and (select count(*) from erp.job j
              where j.tenant_id = v_tenant and j.handler_code like 'notifications.%') = 2;
  detail := format('%s job(s) installed the second time', v_n);
  return next;

  update erp.job set is_enabled = false
   where tenant_id = v_tenant and handler_code = 'notifications.route_events';
  v_n := erp.ensure_notification_services();
  case_name := 'a job the organisation switched off stays off';
  passed := v_n = 0
        and not coalesce((select j.is_enabled from erp.job j
                           where j.tenant_id = v_tenant and j.handler_code = 'notifications.route_events'), true);
  detail := 'only an absent job is installed';
  return next;

  case_name := 'the walkthrough does not count notification services as a recurring task somebody set up';
  passed := coalesce((select not se.satisfied from erp.setup_evidence() se where se.step_code = 'jobs.define'), false);
  detail := coalesce((select se.evidence from erp.setup_evidence() se where se.step_code = 'jobs.define'), 'no evidence row');
  return next;

  -- ── 6-9. An approval task reaches the person who must act ───────────────────
  v_first_req := erp.request_approval('zz_product_route', gen_random_uuid(), '{}'::jsonb);
  select t.id into v_task from erp.approval_task t
   where t.tenant_id = v_tenant and t.approval_request_id = v_first_req and t.status = 'pending';
  select * into v_ev from erp.event e
   where e.tenant_id = v_tenant and e.event_type = 'approval.task_assigned' and e.aggregate_id = v_task;
  case_name := 'an approval step naming a person raises approval.task_assigned for them';
  passed := v_ev.id is not null
        and coalesce(v_ev.payload -> 'recipient_ids' = jsonb_build_array(u_approver), false);
  detail := coalesce(v_ev.payload::text, 'no event');
  return next;

  perform erp.route_notifications();
  case_name := 'routing emails the approver once and the requester not at all';
  passed := (select count(*) from erp.notification n
              where n.tenant_id = v_tenant and n.event_id = v_ev.id and n.app_user_id = u_approver
                and n.channel_kind = 'email' and n.route_id is null) = 1
        and not exists (select 1 from erp.notification n
                         where n.tenant_id = v_tenant and n.event_id = v_ev.id and n.app_user_id = u_admin);
  detail := 'no organisation route is configured; the product route carries it';
  return next;

  select n.body into v_body from erp.notification n
   where n.tenant_id = v_tenant and n.event_id = v_ev.id and n.app_user_id = u_approver
   limit 1;
  case_name := 'the email says what is waiting and where to act, and carries no identifier';
  passed := coalesce(v_body = erp.text('notify.approval_requested.body') || E'\n\n' || v_base || '/governance', false)
        and position(v_task::text in coalesce(v_body, '')) = 0
        and position(v_first_req::text in coalesce(v_body, '')) = 0
        and position('approval.task_assigned' in coalesce(v_body, '')) = 0;
  detail := coalesce(v_body, 'no body');
  return next;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', a_approver, 'role', 'authenticated')::text, true);
  perform erp.set_notification_preference('email', false);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', a_admin, 'role', 'authenticated')::text, true);
  v_req := erp.request_approval('zz_product_route', gen_random_uuid(), '{}'::jsonb);
  select e.* into v_ev from erp.event e
    join erp.approval_task t on t.tenant_id = e.tenant_id and t.id = e.aggregate_id
   where e.tenant_id = v_tenant and e.event_type = 'approval.task_assigned' and t.approval_request_id = v_req;
  perform erp.route_notifications();
  case_name := 'a person who switched email off is told in the product instead';
  passed := v_ev.id is not null
        and exists (select 1 from erp.notification n
                     where n.event_id = v_ev.id and n.app_user_id = u_approver and n.channel_kind = 'in_app')
        and not exists (select 1 from erp.notification n
                         where n.event_id = v_ev.id and n.channel_kind = 'email');
  detail := 'the product route is not mandatory, so the person''s own choice holds';
  return next;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', a_approver, 'role', 'authenticated')::text, true);
  perform erp.set_notification_preference('email', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', a_admin, 'role', 'authenticated')::text, true);

  -- ── 10-12. An overdue task escalates, and each side is told ─────────────────
  -- Escalated by the second administrator, so the person who asked for the
  -- approval and the person who ran the escalation are different people.
  update erp.approval_task set due_at = now() - interval '1 minute' where id = v_task;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', a_second, 'role', 'authenticated')::text, true);
  perform erp.escalate_overdue_approvals();
  perform set_config('request.jwt.claims',
                     json_build_object('sub', a_admin, 'role', 'authenticated')::text, true);
  select * into v_ev from erp.event e
   where e.tenant_id = v_tenant and e.event_type = 'approval.task_escalated'
     and e.payload ->> 'escalated_from' = v_task::text;
  case_name := 'an overdue task escalated to a named person raises approval.task_escalated for them';
  passed := v_ev.id is not null
        and coalesce(v_ev.payload -> 'recipient_ids' = jsonb_build_array(u_target), false);
  detail := coalesce(v_ev.payload::text, 'no event');
  return next;

  perform erp.route_notifications();
  select n.body into v_body from erp.notification n
   where n.event_id = v_ev.id and n.app_user_id = u_target and n.channel_kind = 'email' and n.route_id is null
   limit 1;
  case_name := 'and the person it escalated to is emailed';
  passed := coalesce(v_body = erp.text('notify.approval_escalated.body') || E'\n\n' || v_base || '/governance', false);
  detail := coalesce(v_body, 'no email');
  return next;

  select * into v_ev from erp.event e
   where e.tenant_id = v_tenant and e.event_type = 'approval.escalated'
     and e.payload ->> 'task_id' = v_task::text;
  v_route.tenant_id := v_tenant;
  v_route.audience_kind := 'object_owner';
  case_name := 'the owner of an escalated approval is whoever asked for it';
  passed := v_ev.id is not null
        and v_ev.actor_id = u_second
        and array(select a.x from erp.notification_audience(v_route, v_ev) as a(x)) = array[u_admin];
  detail := 'the base pack''s approval_escalated route goes to the object owner, and there is no approval table to find one in';
  return next;

  -- ── 13-14. Who a route does not reach ───────────────────────────────────────
  v_event := erp.append_event('approval.task_escalated', 'approval_task', gen_random_uuid(),
    jsonb_build_object('recipient_ids', jsonb_build_array(u_invited, u_target),
                       'approval_request_id', v_first_req));
  perform erp.route_notifications();
  case_name := 'a named recipient who has not yet joined is not reached';
  passed := not exists (select 1 from erp.notification n where n.event_id = v_event and n.app_user_id = u_invited)
        and exists (select 1 from erp.notification n where n.event_id = v_event and n.app_user_id = u_target);
  detail := 'the event named two people; the one still invited is left out';
  return next;

  v_event := erp.append_event('job.failed', 'job', gen_random_uuid(), '{}'::jsonb);
  perform erp.route_notifications();
  case_name := 'a product route to a role reaches its members but not whoever raised the event';
  passed := exists (select 1 from erp.notification n
                     where n.event_id = v_event and n.app_user_id = u_second and n.channel_kind = 'email')
        and not exists (select 1 from erp.notification n where n.event_id = v_event and n.app_user_id = u_admin)
        and not exists (select 1 from erp.notification n where n.event_id = v_old);
  detail := 'job_failed goes to administrators: the second is told, the first raised it, and the failure recorded before routing began is never sent';
  return next;

  -- ── 15-17. A change waiting for somebody else ───────────────────────────────
  v_cs := erp.create_change_set('zzprodroute-live', 'Suite change',
                                'A configuration change the suite submits on a live organisation', null);
  perform erp.add_change_set_item(v_cs, 'terminology', 'zzprodroute.words',
    jsonb_build_object('key', 'nav.home', 'locale', 'en', 'value', 'Start'),
    'upsert'::erp.change_operation, current_date, 'the product routes suite');
  perform erp.submit_change_set(v_cs);
  select * into v_ev from erp.event e
   where e.tenant_id = v_tenant and e.event_type = 'change_set.submitted' and e.aggregate_id = v_cs;
  case_name := 'a change submitted on a live organisation names the other people who can approve it';
  passed := v_ev.id is not null
        and coalesce(v_ev.payload -> 'recipient_ids' = jsonb_build_array(u_second), false);
  detail := coalesce(v_ev.payload::text, 'no event');
  return next;

  perform erp.route_notifications();
  select n.body into v_body from erp.notification n
   where n.event_id = v_ev.id and n.app_user_id = u_second and n.channel_kind = 'email' and n.route_id is null
   limit 1;
  case_name := 'and they are emailed a link to Configuration, and its author is not';
  passed := coalesce(v_body = erp.text('notify.change_set_awaiting_approval.body') || E'\n\n' || v_base
                              || '/administration/configuration', false)
        and not exists (select 1 from erp.notification n where n.event_id = v_ev.id and n.app_user_id = u_admin);
  detail := coalesce(v_body, 'no email');
  return next;

  perform erp_test.reopen_bootstrap_window(v_tenant);
  v_cs := erp.create_change_set('zzprodroute-building', 'Suite change before go-live',
                                'A configuration change the suite submits while the organisation is being built', null);
  perform erp.add_change_set_item(v_cs, 'terminology', 'zzprodroute.words',
    jsonb_build_object('key', 'nav.home', 'locale', 'en', 'value', 'Start'),
    'upsert'::erp.change_operation, current_date, 'the product routes suite');
  perform erp.submit_change_set(v_cs);
  perform erp_test.close_bootstrap_window(v_tenant);
  case_name := 'before go-live a submitted change raises nothing, because its author approves it';
  passed := not exists (select 1 from erp.event e
                         where e.tenant_id = v_tenant and e.event_type = 'change_set.submitted'
                           and e.aggregate_id = v_cs);
  detail := 'nobody else is waited on while an organisation is being built';
  return next;

  -- ── 18-19. An organisation route of the same code decides ───────────────────
  perform erp_test.reopen_bootstrap_window(v_tenant);
  v_org_route := erp.upsert_notification_route('approval_task_assigned', 'Approval tasks, in the product only',
    'approval.task_assigned', 'medium', 'recipients', null, null, null, 'in_app', null);
  perform erp_test.close_bootstrap_window(v_tenant);
  v_req := erp.request_approval('zz_product_route', gen_random_uuid(), '{}'::jsonb);
  select e.* into v_ev from erp.event e
    join erp.approval_task t on t.tenant_id = e.tenant_id and t.id = e.aggregate_id
   where e.tenant_id = v_tenant and e.event_type = 'approval.task_assigned' and t.approval_request_id = v_req;
  perform erp.route_notifications();
  case_name := 'an organisation route of the same code replaces the product route, and a recipients audience reads the event';
  passed := v_ev.id is not null
        and exists (select 1 from erp.notification n
                     where n.event_id = v_ev.id and n.route_id = v_org_route
                       and n.app_user_id = u_approver and n.channel_kind = 'in_app')
        and not exists (select 1 from erp.notification n where n.event_id = v_ev.id and n.route_id is null);
  detail := 'the organisation chose in-app for approval tasks; nobody is emailed as well';
  return next;

  perform erp_test.reopen_bootstrap_window(v_tenant);
  perform erp.set_notification_route_status('approval_task_assigned', 'inactive');
  perform erp_test.close_bootstrap_window(v_tenant);
  v_req := erp.request_approval('zz_product_route', gen_random_uuid(), '{}'::jsonb);
  select e.* into v_ev from erp.event e
    join erp.approval_task t on t.tenant_id = e.tenant_id and t.id = e.aggregate_id
   where e.tenant_id = v_tenant and e.event_type = 'approval.task_assigned' and t.approval_request_id = v_req;
  perform erp.route_notifications();
  case_name := 'and switched off, it silences the product route too';
  passed := v_ev.id is not null
        and not exists (select 1 from erp.notification n where n.event_id = v_ev.id);
  detail := 'an inactive route of the same code is how an organisation turns a product route off';
  return next;

  -- ── 20-21. The reports ──────────────────────────────────────────────────────
  case_name := 'the readiness report counts the product''s own routes, and says when routing is switched off';
  passed := not exists (select 1 from erp.email_readiness_report() x where x.finding = 'no notification route is defined')
        and exists (select 1 from erp.email_readiness_report() x where x.finding = 'notification services are not running');
  detail := 'routing was switched off in case four';
  return next;

  case_name := 'every product route waits on a registered event, has words in both languages and goes to a role every organisation has';
  passed := not exists (select 1 from erp.notification_chain_report() x where x.finding like 'the product route%');
  detail := (select count(*) || ' product route(s)' from erp_ref.notification_route_default);
  return next;

  -- ── 22. Clean up ────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp_meta.platform_audit where tenant_id = v_tenant;
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a_admin, a_second, a_approver);
  -- Provisioning declared the organisation as the session's job context; the
  -- suites that run after this one in the same transaction must not inherit it.
  perform set_config('erp.job_tenant_id', '', true);

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zzprodroute')
        and not exists (select 1 from auth.users au where au.id in (a_admin, a_second, a_approver));
  detail := 'the organisation, its jobs, events and notifications went together';
  return next;
end;
$$;

revoke all on function erp_test.notification_product_routes_suite() from public, anon, authenticated;

create or replace function erp_test.assert_notification_product_routes_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 22;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  create temp table if not exists _notification_product_routes on commit drop as
    select * from erp_test.notification_product_routes_suite();
  select count(*), count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from _notification_product_routes s;
  drop table _notification_product_routes;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_NOTIFICATION_PRODUCT_ROUTES_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_NOTIFICATION_PRODUCT_ROUTES_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail;
  end if;
  return format('notification product routes: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.assert_notification_product_routes_suite() from public, anon, authenticated;

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
select erp.assert_setup_walkthrough_actionable();

-- The walkthrough suite first: one of its cases asks for no organisation in
-- context, and the suites after it provision their own.
select erp_test.assert_setup_walkthrough_suite();
select erp_test.assert_email_delivery_suite();
select erp_test.assert_stranded_work_suite();
select erp_test.assert_notification_product_routes_suite();
select erp_test.assert_notification_chain_suite();
select erp_test.assert_output_channels_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
