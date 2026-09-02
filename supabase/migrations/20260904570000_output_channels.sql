-- =============================================================================
-- Part 15: the channels — notifications routed, prints routed, senders verified,
-- labels composed
--
-- The common model of §15.1 landed in 20260904250000 and became promotable in
-- 20260904340000. What was missing is everything §15.4 to §15.7 say happens
-- AROUND it, and each was a sentence with no row:
--
--   §15.6 "Routing binds an event and a severity to an audience — a role, a
--   department, a named user, or the owner of the affected object — never to
--   a hard-coded address list."  →  erp.notification_route, and a router that
--   reads the event stream. B9 shipped channels, templates and quiet hours;
--   nothing ever produced a notification, so the quiet hours guarded silence.
--
--   §15.6 "Digest and escalation ... Quiet hours per user and per channel, with
--   an override severity that always breaks through. Per-user preferences
--   within the bounds the organisation permits ... Delivery is tracked: sent,
--   delivered, read where the channel supports it, and failed with reason.
--   In-app notification is the fallback that always works and never gets
--   suppressed, so no alert is lost because a channel was misconfigured."
--   →  erp.notification carries every state, and the dispatcher holds, digests,
--   escalates, and falls back to in-app on every failure and suppression.
--
--   §15.4 "Routing rules bind an event and an output type to a printer or
--   printer group, by site, workstation, packing line or user ... Queue health
--   is a first-class signal ... Reprint is self-serve within permission,
--   always audited, and always marked as a copy."  →  erp.print_route, the
--   most specific rule wins, the queue health report, and a reprint that is a
--   new render marked is_copy pointing at the original.
--
--   §15.5 "Sender identity — per organisation sending domain with SPF, DKIM and
--   DMARC alignment ... until then it sends from a platform domain with a
--   reply-to."  →  erp.sender_identity, verified record by record, and
--   erp.sender_for() that falls back to the platform's domain until it is.
--
--   §15.3 "ZPL as the primary label language ... the same template renders at
--   203 and 300 dots per inch without a second template."  →  erp.compose_zpl()
--   scales one resolved render to the printer's resolution. EPL and IPL are not
--   composed here and the decision says so.
--
--   §15.7 "Output volume, failure rates and queue depth are reported alongside
--   job health in the assurance surface."  →  erp.output_health_report().
--
-- What SQL cannot do is put bytes on a wire. A queued email or print is
-- consumed by the gateway (Phase 2's worker), which confirms or fails it back
-- through erp.confirm_delivery() and erp.fail_delivery(); that boundary is
-- recorded as a decision rather than implied by a status that never changes.
-- =============================================================================

-- ── §15.6 the route ──────────────────────────────────────────────────────────

create table if not exists erp.notification_route (
  id                       uuid primary key default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant (id) on delete cascade,
  code                     text not null,
  name                     text not null,
  event_pattern            text not null,
  severity                 erp.notification_severity not null default 'medium',
  audience_kind            text not null,
  role_id                  uuid,
  department_id            uuid references erp.department (id) on delete cascade,
  app_user_id              uuid,
  channel_kind             erp.notification_channel_kind not null default 'in_app',
  template_code            text,
  digest_minutes           integer,
  escalate_after_minutes   integer,
  escalate_to_role_id      uuid,
  is_mandatory             boolean not null default false,
  status                   text not null default 'active',
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  constraint notification_route_audience_known
    check (audience_kind in ('role', 'department', 'user', 'object_owner')),
  constraint notification_route_audience_named
    check ((audience_kind = 'role' and role_id is not null)
        or (audience_kind = 'department' and department_id is not null)
        or (audience_kind = 'user' and app_user_id is not null)
        or (audience_kind = 'object_owner')),
  constraint notification_route_digest_positive check (digest_minutes is null or digest_minutes > 0),
  constraint notification_route_escalation_named
    check (escalate_after_minutes is null or escalate_to_role_id is not null),
  constraint notification_route_status_known check (status in ('active', 'inactive')),
  constraint notification_route_unique_code unique (tenant_id, code),
  constraint notification_route_tenant_id_key unique (tenant_id, id),
  constraint notification_route_role_fk
    foreign key (tenant_id, role_id) references erp.role (tenant_id, id) on delete cascade,
  constraint notification_route_user_fk
    foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade,
  constraint notification_route_escalation_fk
    foreign key (tenant_id, escalate_to_role_id) references erp.role (tenant_id, id) on delete set null
);

comment on table erp.notification_route is
  'Specification v1.2 §15.6: "routing binds an event and a severity to an '
  'audience — a role, a department, a named user, or the owner of the affected '
  'object — never to a hard-coded address list". Carries the digest cadence, '
  'the escalation timer and whether a person may switch it off.';

create table if not exists erp.notification (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant (id) on delete cascade,
  route_id        uuid,
  event_id        uuid,
  severity        erp.notification_severity not null,
  app_user_id     uuid not null,
  channel_kind    erp.notification_channel_kind not null,
  subject         text not null,
  body            text not null,
  status          text not null default 'pending',
  held_until      timestamptz,
  digest_key      text,
  digest_of       integer not null default 0,
  escalation_of   uuid,
  escalated_at    timestamptz,
  sent_at         timestamptz,
  delivered_at    timestamptz,
  read_at         timestamptz,
  failure_reason  text,
  sender          text,
  created_at      timestamptz not null default now(),
  constraint notification_status_known
    check (status in ('pending', 'held', 'digested', 'sent', 'delivered', 'read', 'failed', 'suppressed')),
  constraint notification_failed_has_reason
    check (status not in ('failed', 'suppressed') or coalesce(btrim(failure_reason), '') <> ''),
  constraint notification_held_has_until check (status <> 'held' or held_until is not null),
  constraint notification_tenant_id_key unique (tenant_id, id),
  constraint notification_recipient_fk
    foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade,
  constraint notification_route_fk
    foreign key (tenant_id, route_id) references erp.notification_route (tenant_id, id) on delete set null
);

comment on table erp.notification is
  'Specification v1.2 §15.6: one message to one person on one channel, with '
  'delivery tracked — pending, held for quiet hours, digested into another, '
  'sent, delivered, read, failed with reason, or suppressed. Every failure and '
  'suppression on another channel has an in-app copy, the fallback that never '
  'gets suppressed.';

create table if not exists erp.notification_preference (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant (id) on delete cascade,
  app_user_id   uuid not null,
  channel_kind  erp.notification_channel_kind not null,
  is_enabled    boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  constraint notification_preference_once unique (tenant_id, app_user_id, channel_kind),
  constraint notification_preference_tenant_id_key unique (tenant_id, id),
  constraint notification_preference_user_fk
    foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade
);

comment on table erp.notification_preference is
  'Specification v1.2 §15.6: per-user preferences within the bounds the '
  'organisation permits. A person may switch a channel off; a mandatory route '
  'reaches them in-app regardless, so they cannot switch off an alert their '
  'role requires.';

create table if not exists erp.notification_watermark (
  tenant_id        uuid primary key references erp.tenant (id) on delete cascade,
  last_global_seq  bigint not null default 0,
  updated_at       timestamptz not null default now()
);

-- ── §15.4 print routing ──────────────────────────────────────────────────────

create table if not exists erp.print_route (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant (id) on delete cascade,
  code           text not null,
  output_kind    text not null,
  template_code  text,
  site_id        uuid,
  workstation    text,
  app_user_id    uuid,
  printer_id     uuid not null,
  priority       integer not null default 100,
  status         text not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  constraint print_route_kind_known check (output_kind in ('document', 'label')),
  constraint print_route_status_known check (status in ('active', 'inactive')),
  constraint print_route_unique_code unique (tenant_id, code),
  constraint print_route_tenant_id_key unique (tenant_id, id),
  constraint print_route_printer_fk
    foreign key (tenant_id, printer_id) references erp.printer (tenant_id, id) on delete cascade,
  constraint print_route_site_fk
    foreign key (tenant_id, site_id) references erp.site (tenant_id, id) on delete cascade,
  constraint print_route_user_fk
    foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade
);

comment on table erp.print_route is
  'Specification v1.2 §15.4: "routing rules bind an event and an output type '
  'to a printer ... by site, workstation, packing line or user". The most '
  'specific rule that matches wins, so a request from a packing bench goes to '
  'the printer beside it rather than to a default.';

-- ── §15.5 sender identity ────────────────────────────────────────────────────

create table if not exists erp.sender_identity (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant (id) on delete cascade,
  domain             text not null,
  category           text not null default 'transactional',
  from_local_part    text not null default 'no-reply',
  reply_to           text,
  spf_verified_at    timestamptz,
  dkim_verified_at   timestamptz,
  dmarc_verified_at  timestamptz,
  verified_at        timestamptz,
  status             text not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint sender_identity_category_known check (category in ('transactional', 'operational')),
  constraint sender_identity_domain_shape check (domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
  constraint sender_identity_verified_means_aligned
    check (verified_at is null
           or (spf_verified_at is not null and dkim_verified_at is not null and dmarc_verified_at is not null)),
  constraint sender_identity_status_known check (status in ('active', 'inactive')),
  constraint sender_identity_once unique (tenant_id, domain, category),
  constraint sender_identity_tenant_id_key unique (tenant_id, id)
);

comment on table erp.sender_identity is
  'Specification v1.2 §15.5: "per organisation sending domain with SPF, DKIM '
  'and DMARC alignment. A tenant sending as its own domain is verified before '
  'it can send; until then it sends from a platform domain with a reply-to." '
  'Transactional and operational are separate identities, so a bounced '
  'operational message cannot damage delivery of an invoice.';

-- ── §15.6 the writers ────────────────────────────────────────────────────────

create or replace function erp.upsert_notification_route(
  p_code text, p_name text, p_event_pattern text,
  p_severity erp.notification_severity default 'medium',
  p_audience_kind text default 'role',
  p_role_code text default null, p_department_code text default null, p_app_user_id uuid default null,
  p_channel_kind erp.notification_channel_kind default 'in_app',
  p_template_code text default null,
  p_digest_minutes integer default null,
  p_escalate_after_minutes integer default null, p_escalate_to_role_code text default null,
  p_is_mandatory boolean default false)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_role uuid; v_dept uuid; v_esc uuid; v_id uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'notification_route', null);
  if p_audience_kind = 'role' then
    select id into v_role from erp.role where tenant_id = v_tenant and code = p_role_code and status = 'active';
    if v_role is null then
      raise exception 'ERPWARE_UNKNOWN_ROLE: %', p_role_code using errcode = '23503';
    end if;
  elsif p_audience_kind = 'department' then
    select id into v_dept from erp.department where tenant_id = v_tenant and code = p_department_code and status = 'active';
    if v_dept is null then
      raise exception 'ERPWARE_UNKNOWN_DEPARTMENT: %', p_department_code using errcode = '23503';
    end if;
  elsif p_audience_kind = 'user' and p_app_user_id is null then
    raise exception 'ERPWARE_ROUTE_NAMES_NOBODY: a route to a person names the person' using errcode = '23514';
  end if;
  if p_escalate_after_minutes is not null then
    select id into v_esc from erp.role where tenant_id = v_tenant and code = p_escalate_to_role_code and status = 'active';
    if v_esc is null then
      raise exception 'ERPWARE_UNKNOWN_ROLE: escalation names % which is not an active role', p_escalate_to_role_code
        using errcode = '23503';
    end if;
  end if;
  -- A template names its channel; a route naming a template of another channel
  -- would render an email body into a push message.
  if p_template_code is not null and not exists (
       select 1 from erp.notification_template t
        where t.tenant_id = v_tenant and t.code = p_template_code and t.channel_kind = p_channel_kind) then
    raise exception 'ERPWARE_UNKNOWN_NOTIFICATION_TEMPLATE: % for channel %', p_template_code, p_channel_kind
      using errcode = '23503';
  end if;
  insert into erp.notification_route
    (tenant_id, code, name, event_pattern, severity, audience_kind, role_id, department_id, app_user_id,
     channel_kind, template_code, digest_minutes, escalate_after_minutes, escalate_to_role_id, is_mandatory)
  values (v_tenant, p_code, p_name, p_event_pattern, p_severity, p_audience_kind, v_role, v_dept,
          case when p_audience_kind = 'user' then p_app_user_id end,
          p_channel_kind, p_template_code, p_digest_minutes, p_escalate_after_minutes, v_esc,
          coalesce(p_is_mandatory, false))
  on conflict (tenant_id, code) do update set
    name = excluded.name, event_pattern = excluded.event_pattern, severity = excluded.severity,
    audience_kind = excluded.audience_kind, role_id = excluded.role_id, department_id = excluded.department_id,
    app_user_id = excluded.app_user_id, channel_kind = excluded.channel_kind,
    template_code = excluded.template_code, digest_minutes = excluded.digest_minutes,
    escalate_after_minutes = excluded.escalate_after_minutes, escalate_to_role_id = excluded.escalate_to_role_id,
    is_mandatory = excluded.is_mandatory, status = 'active', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.set_notification_route_status(p_code text, p_status text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_n integer;
begin
  perform erp.authorise('administration.configure', null, null, null, 'notification_route', null);
  update erp.notification_route set status = p_status, updated_at = now()
   where tenant_id = v_tenant and code = p_code;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'ERPWARE_UNKNOWN_NOTIFICATION_ROUTE: %', p_code using errcode = '23503';
  end if;
end;
$$;

-- The audience of one route for one event: the people it reaches today.
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
  else
    -- The owner of the affected object: whoever created it, where the aggregate
    -- is a table with attribution; otherwise the actor who raised the event.
    if exists (select 1 from information_schema.columns c
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
  v_user   uuid;
  v_chan   erp.notification_channel_kind;
  v_subj   text; v_body text; v_tpl erp.notification_template%rowtype;
  v_hold   timestamptz;
  n_routed integer := 0; n_held integer := 0;
begin
  insert into erp.notification_watermark (tenant_id) values (v_tenant) on conflict do nothing;
  select w.last_global_seq into v_from from erp.notification_watermark w where w.tenant_id = v_tenant;
  v_max := v_from;

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
  'if the route digests.';

create or replace function erp.dispatch_notifications()
returns table(released integer, digested integer, sent integer, delivered integer,
              suppressed integer, failed integer, escalated integer)
language plpgsql
set search_path = ''
as $$
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
    update erp.notification set status = 'sent', sent_at = now(), sender = v_sender where id = r.id;
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
$$;

comment on function erp.dispatch_notifications is
  'Specification v1.2 §15.6: releases what quiet hours held, folds digests, '
  'sends what is pending — in-app is delivered on the spot, an email is sent '
  'unless the address is suppressed or missing, another channel needs an '
  'enabled channel row — writes an in-app copy of every failure and '
  'suppression, and escalates what nobody acknowledged past the timer.';

create or replace function erp.mark_notification_read(p_notification_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_n integer;
begin
  update erp.notification set status = 'read', read_at = coalesce(read_at, now())
   where tenant_id = v_tenant and id = p_notification_id and app_user_id = erp.current_principal_id()
     and status in ('sent', 'delivered');
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'ERPWARE_NOT_YOUR_NOTIFICATION: % is not an unread notification of yours', p_notification_id
      using errcode = '42501';
  end if;
end;
$$;

create or replace function erp.set_notification_preference(p_channel_kind erp.notification_channel_kind, p_is_enabled boolean)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if p_channel_kind = 'in_app' and not p_is_enabled then
    raise exception 'ERPWARE_IN_APP_CANNOT_BE_SWITCHED_OFF: in-app is the fallback that always works'
      using errcode = '23514';
  end if;
  insert into erp.notification_preference (tenant_id, app_user_id, channel_kind, is_enabled)
  values (v_tenant, erp.current_principal_id(), p_channel_kind, p_is_enabled)
  on conflict (tenant_id, app_user_id, channel_kind) do update set
    is_enabled = excluded.is_enabled, updated_at = now();
end;
$$;

create or replace function erp.set_my_quiet_hours(
  p_days_of_week smallint[], p_starts_at time, p_ends_at time, p_timezone text,
  p_override_at_or_above erp.notification_severity default 'critical')
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_me uuid := erp.current_principal_id(); v_id uuid;
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_timezone) then
    raise exception 'ERPWARE_UNKNOWN_TIMEZONE: %', p_timezone using errcode = '22023';
  end if;
  delete from erp.quiet_hours where tenant_id = v_tenant and app_user_id = v_me;
  if p_days_of_week is null or cardinality(p_days_of_week) = 0 then
    return null;
  end if;
  insert into erp.quiet_hours
    (tenant_id, app_user_id, days_of_week, starts_at_time, ends_at_time, timezone, overridden_at_or_above)
  values (v_tenant, v_me, p_days_of_week, p_starts_at, p_ends_at, p_timezone, p_override_at_or_above)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.notification_health_report(p_days integer default 7)
returns table(channel_kind text, pending integer, held integer, sent integer, delivered integer,
              read integer, failed integer, suppressed integer, oldest_pending_minutes integer)
language sql
stable
set search_path = ''
as $$
  select n.channel_kind::text,
         count(*) filter (where n.status = 'pending')::integer,
         count(*) filter (where n.status = 'held')::integer,
         count(*) filter (where n.status = 'sent')::integer,
         count(*) filter (where n.status = 'delivered')::integer,
         count(*) filter (where n.status = 'read')::integer,
         count(*) filter (where n.status = 'failed')::integer,
         count(*) filter (where n.status = 'suppressed')::integer,
         (extract(epoch from now() - min(n.created_at) filter (where n.status = 'pending')) / 60)::integer
    from erp.notification n
   where n.tenant_id = erp.require_tenant_id()
     and n.created_at >= now() - make_interval(days => greatest(p_days, 1))
   group by n.channel_kind
   order by n.channel_kind
$$;

-- ── §15.5 sender identity ────────────────────────────────────────────────────

create or replace function erp.upsert_sender_identity(p_domain text, p_category text default 'transactional', p_from_local_part text default 'no-reply', p_reply_to text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_id uuid;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'sender_identity', null);
  insert into erp.sender_identity (tenant_id, domain, category, from_local_part, reply_to)
  values (v_tenant, lower(btrim(p_domain)), p_category, coalesce(nullif(btrim(p_from_local_part), ''), 'no-reply'), p_reply_to)
  on conflict (tenant_id, domain, category) do update set
    from_local_part = excluded.from_local_part, reply_to = excluded.reply_to, status = 'active', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.record_sender_verification(p_domain text, p_spf boolean, p_dkim boolean, p_dmarc boolean)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_n integer; v_verified boolean;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'sender_identity', null);
  update erp.sender_identity s
     set spf_verified_at   = case when p_spf then coalesce(s.spf_verified_at, now()) else null end,
         dkim_verified_at  = case when p_dkim then coalesce(s.dkim_verified_at, now()) else null end,
         dmarc_verified_at = case when p_dmarc then coalesce(s.dmarc_verified_at, now()) else null end,
         verified_at       = case when p_spf and p_dkim and p_dmarc then coalesce(s.verified_at, now()) else null end,
         updated_at = now()
   where s.tenant_id = v_tenant and s.domain = lower(btrim(p_domain));
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'ERPWARE_UNKNOWN_SENDER_DOMAIN: %', p_domain using errcode = '23503';
  end if;
  v_verified := p_spf and p_dkim and p_dmarc;
  return jsonb_build_object('domain', lower(btrim(p_domain)), 'verified', v_verified,
                            'spf', p_spf, 'dkim', p_dkim, 'dmarc', p_dmarc);
end;
$$;

create or replace function erp.sender_dns_checklist(p_domain text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- §15.8: the DNS records an organisation must publish, as a task with
  -- verification rather than as documentation.
  select jsonb_build_array(
    jsonb_build_object('record', 'SPF', 'type', 'TXT', 'name', lower(btrim(p_domain)),
      'value', 'v=spf1 include:' || split_part(coalesce(erp.text('email.platform_sender'), 'no-reply@cloveerp.com'), '@', 2) || ' ~all',
      'why', 'Names the platform as a permitted sender for your domain.'),
    jsonb_build_object('record', 'DKIM', 'type', 'CNAME', 'name', 'clove._domainkey.' || lower(btrim(p_domain)),
      'value', 'clove._domainkey.' || split_part(coalesce(erp.text('email.platform_sender'), 'no-reply@cloveerp.com'), '@', 2),
      'why', 'Lets receivers check the signature on every message the platform sends as you.'),
    jsonb_build_object('record', 'DMARC', 'type', 'TXT', 'name', '_dmarc.' || lower(btrim(p_domain)),
      'value', 'v=DMARC1; p=quarantine; rua=mailto:dmarc@' || lower(btrim(p_domain)),
      'why', 'Tells receivers what to do when SPF or DKIM fail, and where to report it.'))
$$;

create or replace function erp.sender_for(p_category text default 'transactional')
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A verified identity for the category sends as the organisation; until
  -- then the platform's domain with the organisation's reply-to, if it set one.
  select coalesce((
    select jsonb_build_object('from_address', s.from_local_part || '@' || s.domain,
                              'reply_to', s.reply_to, 'own_domain', true, 'category', s.category)
      from erp.sender_identity s
     where s.tenant_id = erp.require_tenant_id() and s.category = p_category
       and s.status = 'active' and s.verified_at is not null
     order by s.verified_at desc limit 1),
    jsonb_build_object('from_address', coalesce(erp.text('email.platform_sender'), 'no-reply@cloveerp.com'),
                       'reply_to', (select s.reply_to from erp.sender_identity s
                                     where s.tenant_id = erp.require_tenant_id() and s.category = p_category
                                       and s.status = 'active' and s.reply_to is not null
                                     order by s.updated_at desc limit 1),
                       'own_domain', false, 'category', p_category))
$$;

-- ── §15.4 print routing, reprint and queue health ────────────────────────────

create or replace function erp.upsert_print_route(
  p_code text, p_output_kind text, p_printer_code text,
  p_template_code text default null, p_site_id uuid default null,
  p_workstation text default null, p_app_user_id uuid default null, p_priority integer default 100)
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); pr erp.printer%rowtype; v_id uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'print_route', null);
  select * into pr from erp.printer p where p.tenant_id = v_tenant and p.code = p_printer_code and p.status = 'active';
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PRINTER: % is not an active printer', p_printer_code using errcode = '23503';
  end if;
  if p_site_id is not null and pr.site_id <> p_site_id then
    raise exception 'ERPWARE_PRINTER_NOT_AT_SITE: % stands at another site', p_printer_code using errcode = '23514';
  end if;
  if p_output_kind = 'label' and pr.printer_type <> 'label' then
    raise exception 'ERPWARE_PRINTER_KIND_MISMATCH: % is a document printer and cannot take labels', p_printer_code
      using errcode = '23514';
  end if;
  insert into erp.print_route (tenant_id, code, output_kind, template_code, site_id, workstation, app_user_id, printer_id, priority)
  values (v_tenant, p_code, p_output_kind, p_template_code, p_site_id, nullif(btrim(p_workstation), ''), p_app_user_id, pr.id, coalesce(p_priority, 100))
  on conflict (tenant_id, code) do update set
    output_kind = excluded.output_kind, template_code = excluded.template_code, site_id = excluded.site_id,
    workstation = excluded.workstation, app_user_id = excluded.app_user_id, printer_id = excluded.printer_id,
    priority = excluded.priority, status = 'active', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.route_print(p_render_id uuid, p_site_id uuid default null, p_workstation text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me uuid := erp.current_principal_id();
  rd erp.output_render%rowtype; t erp.output_template%rowtype; tv erp.output_template_version%rowtype;
  pr erp.printer%rowtype; rt erp.print_route%rowtype; v_delivery uuid;
begin
  select * into rd from erp.output_render r where r.tenant_id = v_tenant and r.id = p_render_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_OUTPUT_RENDER' using errcode = '23503';
  end if;
  select * into tv from erp.output_template_version v where v.tenant_id = v_tenant and v.id = rd.template_version_id;
  select * into t from erp.output_template x where x.tenant_id = v_tenant and x.id = tv.output_template_id;
  perform erp.authorise(tv.required_permission, null, null, null, 'output_template', t.id);

  -- §15.4: "the platform routes to the printer nearest that task rather than
  -- to a default". The most specific matching rule wins: user, then
  -- workstation, then site, then template, then the rest.
  select r.* into rt from erp.print_route r
    join erp.printer p on p.tenant_id = r.tenant_id and p.id = r.printer_id and p.status = 'active'
   where r.tenant_id = v_tenant and r.status = 'active' and r.output_kind = t.kind
     and (r.template_code is null or r.template_code = t.code)
     and (r.site_id is null or r.site_id = p_site_id)
     and (r.workstation is null or r.workstation = p_workstation)
     and (r.app_user_id is null or r.app_user_id = v_me)
   order by (r.app_user_id is not null)::int desc, (r.workstation is not null)::int desc,
            (r.site_id is not null)::int desc, (r.template_code is not null)::int desc,
            r.priority, r.code
   limit 1;
  if not found then
    raise exception 'ERPWARE_NO_PRINT_ROUTE: no print route matches a % from here', t.kind
      using errcode = '23503',
            hint = 'Add a print route for this kind at this site, workstation or person.';
  end if;
  select * into pr from erp.printer p where p.id = rt.printer_id;

  -- §15.4: "a queued, retried operation with a monitored backlog, not a request
  -- that succeeds or vanishes."
  insert into erp.output_delivery (tenant_id, output_render_id, destination, destination_kind, status, attempts)
  values (v_tenant, p_render_id, pr.queue_address, 'print', 'queued', 0)
  returning id into v_delivery;
  return jsonb_build_object('delivery_id', v_delivery, 'printer', pr.code, 'route', rt.code,
                            'queue_address', pr.queue_address);
end;
$$;

create or replace function erp.reprint_output(p_render_id uuid, p_printer_code text default null, p_site_id uuid default null, p_workstation text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  rd erp.output_render%rowtype; tv erp.output_template_version%rowtype; t erp.output_template%rowtype;
  pr erp.printer%rowtype; v_render uuid; v_delivery uuid; res jsonb;
begin
  select * into rd from erp.output_render r where r.tenant_id = v_tenant and r.id = p_render_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_OUTPUT_RENDER' using errcode = '23503';
  end if;
  select * into tv from erp.output_template_version v where v.tenant_id = v_tenant and v.id = rd.template_version_id;
  select * into t from erp.output_template x where x.tenant_id = v_tenant and x.id = tv.output_template_id;
  -- §15.4: self-serve within permission, always audited, always marked as a copy.
  perform erp.authorise(tv.required_permission, null, null, null, 'output_template', t.id);

  insert into erp.output_render
    (tenant_id, output_request_id, template_version_id, version, format, checksum, byte_size,
     data_snapshot, document_reference, is_copy, reissue_of, content)
  values (v_tenant, rd.output_request_id, rd.template_version_id, rd.version, rd.format, rd.checksum,
          rd.byte_size, rd.data_snapshot, rd.document_reference, true, coalesce(rd.reissue_of, rd.id), rd.content)
  returning id into v_render;

  if p_printer_code is not null then
    select * into pr from erp.printer p where p.tenant_id = v_tenant and p.code = p_printer_code and p.status = 'active';
    if not found then
      raise exception 'ERPWARE_UNKNOWN_PRINTER: %', p_printer_code using errcode = '23503';
    end if;
    insert into erp.output_delivery (tenant_id, output_render_id, destination, destination_kind, status, attempts)
    values (v_tenant, v_render, pr.queue_address, 'print', 'queued', 0) returning id into v_delivery;
    res := jsonb_build_object('delivery_id', v_delivery, 'printer', pr.code);
  else
    res := erp.route_print(v_render, p_site_id, p_workstation);
  end if;
  return res || jsonb_build_object('render_id', v_render, 'is_copy', true, 'reissue_of', coalesce(rd.reissue_of, rd.id));
end;
$$;

create or replace function erp.confirm_delivery(p_delivery_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_n integer;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'output_delivery', p_delivery_id);
  update erp.output_delivery
     set status = 'confirmed', confirmed_at = now(), attempts = attempts + 1, failure_reason = null, updated_at = now()
   where tenant_id = v_tenant and id = p_delivery_id and status in ('queued', 'sent', 'failed');
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'ERPWARE_UNKNOWN_DELIVERY: % is not an open delivery', p_delivery_id using errcode = '23503';
  end if;
end;
$$;

create or replace function erp.fail_delivery(p_delivery_id uuid, p_reason text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_n integer;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'output_delivery', p_delivery_id);
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'ERPWARE_FAILURE_HAS_NO_REASON' using errcode = '23514';
  end if;
  update erp.output_delivery
     set status = 'failed', failure_reason = btrim(p_reason), attempts = attempts + 1, updated_at = now()
   where tenant_id = v_tenant and id = p_delivery_id and status in ('queued', 'sent');
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'ERPWARE_UNKNOWN_DELIVERY: % is not an open delivery', p_delivery_id using errcode = '23503';
  end if;
end;
$$;

create or replace function erp.print_queue_health_report()
returns table(printer_code text, site_code text, queued integer, failed integer, oldest_queued_minutes integer,
              last_confirmed_at timestamptz, signal text)
language sql
stable
set search_path = ''
as $$
  with q as (
    select p.id, p.code, s.code as site_code,
           count(d.id) filter (where d.status = 'queued')::integer as queued,
           count(d.id) filter (where d.status = 'failed')::integer as failed,
           (extract(epoch from now() - min(d.created_at) filter (where d.status = 'queued')) / 60)::integer as oldest,
           max(d.confirmed_at) as last_ok,
           count(d.id) filter (where d.created_at >= now() - interval '24 hours')::integer as requested_24h
      from erp.printer p
      join erp.site s on s.tenant_id = p.tenant_id and s.id = p.site_id
      left join erp.output_delivery d
        on d.tenant_id = p.tenant_id and d.destination_kind = 'print' and d.destination = p.queue_address
     where p.tenant_id = erp.require_tenant_id() and p.status = 'active'
     group by p.id, p.code, s.code)
  -- §15.4: "printer offline, queue depth above threshold, no successful print
  -- in a window" — alerting before the operation notices.
  select q.code, q.site_code, q.queued, q.failed, q.oldest, q.last_ok,
         case when q.queued > 0 and q.oldest >= 30 then 'printer offline: queued prints and nothing confirmed in 30 minutes'
              when q.queued >= 25 then 'queue depth above threshold'
              when q.requested_24h > 0 and (q.last_ok is null or q.last_ok < now() - interval '24 hours')
                then 'no successful print in 24 hours while prints were requested'
              else null end
    from q
   order by q.code
$$;

-- ── §15.3 ZPL, scaled to the printer ─────────────────────────────────────────

create or replace function erp.compose_zpl(p_render jsonb, p_dpi integer default 203, p_page text default '100x150mm')
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_w_mm numeric := coalesce(nullif(split_part(regexp_replace(p_page, 'mm', ''), 'x', 1), '')::numeric, 100);
  v_h_mm numeric := coalesce(nullif(split_part(regexp_replace(p_page, 'mm', ''), 'x', 2), '')::numeric, 150);
  v_dpmm numeric := p_dpi / 25.4;
  v_w integer := round(v_w_mm * v_dpmm);
  v_h integer := round(v_h_mm * v_dpmm);
  v_scale numeric := p_dpi / 203.0;
  v_margin integer := round(3 * v_dpmm);
  v_y integer;
  v_line integer := round(24 * v_scale);
  v_big integer := round(40 * v_scale);
  v_out text;
  b jsonb; f jsonb; r jsonb; c jsonb;
  v_text text; v_value text;
begin
  v_y := v_margin;
  v_out := format('^XA^CI28^PW%s^LL%s^LH0,0', v_w, v_h);
  for b in select * from jsonb_array_elements(coalesce(p_render -> 'blocks', '[]'::jsonb)) loop
    case b ->> 'kind'
      when 'title' then
        v_text := coalesce((select string_agg(coalesce(x ->> 'value', ''), ' ')
                              from jsonb_array_elements(coalesce(b -> 'fields', '[]'::jsonb)) x), '');
        v_out := v_out || format('^FO%s,%s^A0N,%s,%s^FD%s^FS', v_margin, v_y, v_big, v_big,
                                 replace(replace(coalesce(nullif(v_text, ''), p_render ->> 'title', ''), '^', ' '), '~', ' '));
        v_y := v_y + v_big + round(4 * v_dpmm);
      when 'barcode' then
        v_value := coalesce((select x ->> 'value' from jsonb_array_elements(coalesce(b -> 'fields', '[]'::jsonb)) x
                              where x ->> 'value' is not null limit 1), '');
        -- Code 128, human-readable beneath, quiet zone kept by the margin.
        v_out := v_out || format('^FO%s,%s^BY%s,3,%s^BCN,%s,Y,N,N^FD%s^FS',
                                 v_margin, v_y, greatest(round(2 * v_scale), 2), round(60 * v_scale),
                                 round(60 * v_scale), replace(replace(v_value, '^', ''), '~', ''));
        v_y := v_y + round(60 * v_scale) + v_line + round(4 * v_dpmm);
      when 'qr' then
        v_value := coalesce((select x ->> 'value' from jsonb_array_elements(coalesce(b -> 'fields', '[]'::jsonb)) x
                              where x ->> 'value' is not null limit 1), '');
        v_out := v_out || format('^FO%s,%s^BQN,2,%s^FDQA,%s^FS', v_margin, v_y, greatest(round(4 * v_scale), 2),
                                 replace(replace(v_value, '^', ''), '~', ''));
        v_y := v_y + round(30 * v_dpmm);
      when 'lines' then
        for r in select * from jsonb_array_elements(coalesce(b -> 'rows', '[]'::jsonb)) loop
          v_text := (select string_agg(coalesce(r ->> (c ->> 'field'), ''), '  ')
                       from jsonb_array_elements(coalesce(b -> 'columns', '[]'::jsonb)) c);
          v_out := v_out || format('^FO%s,%s^A0N,%s,%s^FD%s^FS', v_margin, v_y, v_line, v_line,
                                   replace(replace(coalesce(v_text, ''), '^', ' '), '~', ' '));
          v_y := v_y + v_line + round(1 * v_dpmm);
        end loop;
      else
        for f in select * from jsonb_array_elements(coalesce(b -> 'fields', '[]'::jsonb)) loop
          v_text := coalesce(f ->> 'label', f ->> 'field') || ': ' || coalesce(f ->> 'value', '');
          v_out := v_out || format('^FO%s,%s^A0N,%s,%s^FD%s^FS', v_margin, v_y, v_line, v_line,
                                   replace(replace(v_text, '^', ' '), '~', ' '));
          v_y := v_y + v_line + round(1 * v_dpmm);
        end loop;
        if b ? 'label' and not (b ? 'fields') then
          v_out := v_out || format('^FO%s,%s^A0N,%s,%s^FD%s^FS', v_margin, v_y, v_line, v_line,
                                   replace(replace(coalesce(b ->> 'label', ''), '^', ' '), '~', ' '));
          v_y := v_y + v_line + round(1 * v_dpmm);
        end if;
    end case;
  end loop;
  return v_out || '^XZ';
end;
$$;

comment on function erp.compose_zpl is
  'Specification v1.2 §15.3: turns one resolved render into ZPL at the '
  'printer''s resolution. Positions, fonts and bar heights scale from the '
  '203 dpi baseline, so "the same template renders at 203 and 300 dots per '
  'inch without a second template". Code 128 with human-readable text beneath; '
  'a QR block for two-dimensional marking. Caret and tilde are stripped from '
  'values because they are ZPL''s own control characters.';

create or replace function erp.render_label(p_template_code text, p_printer_code text, p_document_id uuid default null, p_locale text default 'en')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t erp.output_template%rowtype; tv erp.output_template_version%rowtype; pr erp.printer%rowtype;
  v_render jsonb; v_zpl text; v_request uuid; v_render_id uuid; v_delivery uuid;
begin
  select * into t from erp.output_template x where x.tenant_id = v_tenant and x.code = p_template_code and x.status = 'active';
  if not found or t.kind <> 'label' then
    raise exception 'ERPWARE_NOT_A_LABEL_TEMPLATE: %', p_template_code using errcode = '23503';
  end if;
  select * into tv from erp.output_template_version v
   where v.tenant_id = v_tenant and v.output_template_id = t.id and v.status = 'active'
     and v.effective_from <= current_date and (v.effective_to is null or v.effective_to > current_date)
   order by v.version desc limit 1;
  if not found then
    raise exception 'ERPWARE_OUTPUT_TEMPLATE_NOT_IN_FORCE: %', p_template_code using errcode = '23503';
  end if;
  perform erp.authorise(tv.required_permission, null, null, null, 'output_template', t.id);
  select * into pr from erp.printer p where p.tenant_id = v_tenant and p.code = p_printer_code and p.status = 'active';
  if not found or pr.printer_type <> 'label' then
    raise exception 'ERPWARE_UNKNOWN_PRINTER: % is not an active label printer', p_printer_code using errcode = '23503';
  end if;
  if pr.language <> 'zpl' then
    raise exception 'ERPWARE_LABEL_LANGUAGE_NOT_COMPOSED: % speaks %, and only ZPL is composed here', p_printer_code, pr.language
      using errcode = '23514', hint = 'EPL and IPL estates print through the gateway''s translation; see the decision zpl_is_composed_here.';
  end if;

  v_render := erp.render_output_template(p_template_code, p_document_id, p_locale);
  v_zpl := erp.compose_zpl(v_render, pr.dots_per_inch, t.page);

  insert into erp.output_request
    (tenant_id, output_template_id, template_version_id, object_type, object_id, destination_kind,
     printer_id, locale, copies, triggering_event, requested_by)
  values (v_tenant, t.id, tv.id, coalesce(case when p_document_id is not null then 'document' end, 'label'),
          p_document_id, 'print', pr.id, p_locale, 1, 'label.rendered', erp.current_principal_id())
  returning id into v_request;
  insert into erp.output_render
    (tenant_id, output_request_id, template_version_id, version, format, checksum, byte_size,
     data_snapshot, document_reference, content)
  values (v_tenant, v_request, tv.id, tv.version, 'zpl', md5(v_zpl), octet_length(v_zpl),
          v_render, coalesce((select d.document_number from erp.document d where d.id = p_document_id), t.code), v_zpl)
  returning id into v_render_id;
  insert into erp.output_delivery (tenant_id, output_render_id, destination, destination_kind, status, attempts)
  values (v_tenant, v_render_id, pr.queue_address, 'print', 'queued', 0)
  returning id into v_delivery;

  return jsonb_build_object('render_id', v_render_id, 'delivery_id', v_delivery, 'printer', pr.code,
                            'dots_per_inch', pr.dots_per_inch, 'zpl', v_zpl, 'checksum', md5(v_zpl));
end;
$$;

-- ── §15.7 the assurance surface ──────────────────────────────────────────────

create or replace function erp.output_health_report()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'requests_24h', (select count(*) from erp.output_request r
                      where r.tenant_id = erp.require_tenant_id() and r.requested_at >= now() - interval '24 hours'),
    'requests_7d', (select count(*) from erp.output_request r
                     where r.tenant_id = erp.require_tenant_id() and r.requested_at >= now() - interval '7 days'),
    'deliveries_7d', (select coalesce(jsonb_object_agg(x.status, x.n), '{}'::jsonb)
                        from (select d.status, count(*) as n from erp.output_delivery d
                               where d.tenant_id = erp.require_tenant_id() and d.created_at >= now() - interval '7 days'
                               group by d.status) x),
    'failure_rate_7d', (select round(100.0 * count(*) filter (where d.status = 'failed') / greatest(count(*), 1), 1)
                          from erp.output_delivery d
                         where d.tenant_id = erp.require_tenant_id() and d.created_at >= now() - interval '7 days'),
    'print_queue_depth', (select count(*) from erp.output_delivery d
                           where d.tenant_id = erp.require_tenant_id() and d.destination_kind = 'print' and d.status = 'queued'),
    'printers', coalesce((select jsonb_agg(to_jsonb(q)) from erp.print_queue_health_report() q), '[]'::jsonb),
    'notifications', coalesce((select jsonb_agg(to_jsonb(n)) from erp.notification_health_report(7) n), '[]'::jsonb),
    'sender', erp.sender_for('transactional'))
$$;

create or replace function erp.output_channels_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- §15.6: a route naming a template the tenant does not have on that channel.
  select 'a notification route names a template its channel does not have', r.code,
         format('%s on %s', r.template_code, r.channel_kind)
    from erp.notification_route r
   where r.status = 'active' and r.template_code is not null
     and not exists (select 1 from erp.notification_template t
                      where t.tenant_id = r.tenant_id and t.code = r.template_code and t.channel_kind = r.channel_kind)
  union all
  select 'a notification route escalates to an inactive role', r.code, ro.code
    from erp.notification_route r
    join erp.role ro on ro.tenant_id = r.tenant_id and ro.id = r.escalate_to_role_id
   where r.status = 'active' and ro.status <> 'active'
  union all
  -- §15.6: the fallback that always works. A failure or suppression on another
  -- channel with no in-app copy is an alert that was lost.
  select 'a failed or suppressed notification has no in-app copy', n.id::text,
         format('%s: %s', n.channel_kind, n.failure_reason)
    from erp.notification n
   where n.status in ('failed', 'suppressed') and n.channel_kind <> 'in_app'
     and not exists (select 1 from erp.notification f
                      where f.tenant_id = n.tenant_id and f.escalation_of = n.id and f.channel_kind = 'in_app')
  union all
  -- §15.4: a print route to a printer that is inactive, or at another site.
  select 'a print route names a printer that is not active', r.code, p.code
    from erp.print_route r join erp.printer p on p.tenant_id = r.tenant_id and p.id = r.printer_id
   where r.status = 'active' and p.status <> 'active'
  union all
  select 'a print route scoped to a site names a printer at another site', r.code, p.code
    from erp.print_route r join erp.printer p on p.tenant_id = r.tenant_id and p.id = r.printer_id
   where r.status = 'active' and r.site_id is not null and p.site_id <> r.site_id
  union all
  -- §15.5: a domain marked verified with a record unverified is impossible by
  -- constraint; a record verified more than a year ago without re-check is
  -- worth a look.
  select 'a sending domain was verified more than a year ago and not since', s.domain, s.category
    from erp.sender_identity s
   where s.status = 'active' and s.verified_at is not null and s.verified_at < now() - interval '1 year'
  order by 1, 2
$$;

create or replace function erp.assert_output_channels_sound()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s — %s: %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.output_channels_report();
  if v_count > 0 then
    raise exception 'ERPWARE_OUTPUT_CHANNELS: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§15.6 routes to audiences and never loses an alert; §15.4 routes prints to a printer that exists where it says.';
  end if;
  return 'output channels: routes resolve, every lost alert has an in-app copy, prints route to live printers';
end;
$$;

-- ── The installer for the two jobs ───────────────────────────────────────────

create or replace function erp.configure_notifications()
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_cs uuid;
begin
  v_cs := erp.install_module_config(
    'notification-services', 'Notification services',
    'The two jobs that turn the event stream into notifications: routing to audiences, and dispatch with digests, quiet hours, escalation and delivery tracking.',
    jsonb_build_array(
      jsonb_build_object('kind', 'job', 'key', 'route_notifications', 'payload',
        jsonb_build_object('code', 'route_notifications', 'name', 'Route notifications',
                           'handler_code', 'notifications.route_events', 'schedule_kind', 'interval',
                           'interval_seconds', 120, 'timeout_seconds', 300, 'is_enabled', true)),
      jsonb_build_object('kind', 'job', 'key', 'dispatch_notifications', 'payload',
        jsonb_build_object('code', 'dispatch_notifications', 'name', 'Dispatch notifications',
                           'handler_code', 'notifications.dispatch', 'schedule_kind', 'interval',
                           'interval_seconds', 120, 'timeout_seconds', 300, 'is_enabled', true))));
  return v_cs;
end;
$$;

insert into erp_ref.job_handler
  (code, name_key, description, module_code, parameter_schema, default_timeout_seconds, forbids_overlap, is_current, sql_function)
values
  ('notifications.route_events', 'job_handler.route_notifications.name',
   'Reads the event stream past the watermark and writes one notification per person in each matching route''s audience. §15.6.',
   'administration', '{"type": "object", "additionalProperties": false}'::jsonb, 300, true, true, 'route_notifications'),
  ('notifications.dispatch', 'job_handler.dispatch_notifications.name',
   'Releases what quiet hours held, folds digests, sends what is pending with an in-app copy of every failure, and escalates what nobody acknowledged. §15.6.',
   'administration', '{"type": "object", "additionalProperties": false}'::jsonb, 300, true, true, 'dispatch_notifications')
on conflict (code) do update set
  description = excluded.description, sql_function = excluded.sql_function, is_current = excluded.is_current;

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_configure_notifications()
returns uuid language sql set search_path = '' as $$ select erp.configure_notifications(); $$;

create or replace function public.erp_upsert_notification_route(
  p_code text, p_name text, p_event_pattern text, p_severity text default 'medium',
  p_audience_kind text default 'role', p_role_code text default null, p_department_code text default null,
  p_app_user_id uuid default null, p_channel_kind text default 'in_app', p_template_code text default null,
  p_digest_minutes integer default null, p_escalate_after_minutes integer default null,
  p_escalate_to_role_code text default null, p_is_mandatory boolean default false)
returns uuid language sql set search_path = '' as $$
  select erp.upsert_notification_route(p_code, p_name, p_event_pattern, p_severity::erp.notification_severity,
    p_audience_kind, p_role_code, p_department_code, p_app_user_id, p_channel_kind::erp.notification_channel_kind,
    p_template_code, p_digest_minutes, p_escalate_after_minutes, p_escalate_to_role_code, p_is_mandatory);
$$;

create or replace function public.erp_set_notification_route_status(p_code text, p_status text)
returns void language sql set search_path = '' as $$ select erp.set_notification_route_status(p_code, p_status); $$;

create or replace function public.erp_notification_routes()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', r.code, 'name', r.name, 'event_pattern', r.event_pattern, 'severity', r.severity,
           'audience_kind', r.audience_kind,
           'audience', coalesce(ro.code, d.code, u.display_name, 'the object''s owner'),
           'channel_kind', r.channel_kind, 'template_code', r.template_code,
           'digest_minutes', r.digest_minutes, 'escalate_after_minutes', r.escalate_after_minutes,
           'escalate_to', er.code, 'is_mandatory', r.is_mandatory, 'status', r.status)
         order by r.code), '[]'::jsonb)
    from erp.notification_route r
    left join erp.role ro on ro.tenant_id = r.tenant_id and ro.id = r.role_id
    left join erp.department d on d.tenant_id = r.tenant_id and d.id = r.department_id
    left join erp.app_user u on u.tenant_id = r.tenant_id and u.id = r.app_user_id
    left join erp.role er on er.tenant_id = r.tenant_id and er.id = r.escalate_to_role_id
   where r.tenant_id = erp.require_tenant_id();
$$;

create or replace function public.erp_my_notifications(p_limit integer default 100)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id, 'severity', n.severity, 'channel_kind', n.channel_kind, 'subject', n.subject,
           'body', n.body, 'status', n.status, 'created_at', n.created_at, 'read_at', n.read_at,
           'digest_of', n.digest_of, 'is_escalation', n.escalation_of is not null and n.subject like 'Escalated:%',
           'failure_reason', n.failure_reason)
         order by n.created_at desc), '[]'::jsonb)
    from (select * from erp.notification x
           where x.tenant_id = erp.require_tenant_id() and x.app_user_id = erp.current_principal_id()
             and x.status <> 'digested'
           order by x.created_at desc limit greatest(p_limit, 1)) n;
$$;

create or replace function public.erp_mark_notification_read(p_notification_id uuid)
returns void language sql set search_path = '' as $$ select erp.mark_notification_read(p_notification_id); $$;

create or replace function public.erp_set_notification_preference(p_channel_kind text, p_is_enabled boolean)
returns void language sql set search_path = '' as $$
  select erp.set_notification_preference(p_channel_kind::erp.notification_channel_kind, p_is_enabled);
$$;

create or replace function public.erp_set_my_quiet_hours(p_days_of_week integer[], p_starts_at time, p_ends_at time, p_timezone text, p_override_at_or_above text default 'critical')
returns uuid language sql set search_path = '' as $$
  select erp.set_my_quiet_hours(p_days_of_week::smallint[], p_starts_at, p_ends_at, p_timezone, p_override_at_or_above::erp.notification_severity);
$$;

create or replace function public.erp_my_notification_settings()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'preferences', coalesce((
      select jsonb_agg(jsonb_build_object('channel_kind', p.channel_kind, 'is_enabled', p.is_enabled))
        from erp.notification_preference p
       where p.tenant_id = erp.require_tenant_id() and p.app_user_id = erp.current_principal_id()), '[]'::jsonb),
    'quiet_hours', coalesce((
      select jsonb_agg(jsonb_build_object('days_of_week', q.days_of_week, 'starts_at', q.starts_at_time,
                                          'ends_at', q.ends_at_time, 'timezone', q.timezone,
                                          'override_at_or_above', q.overridden_at_or_above))
        from erp.quiet_hours q
       where q.tenant_id = erp.require_tenant_id() and q.app_user_id = erp.current_principal_id()), '[]'::jsonb),
    'services_installed', exists (
      select 1 from erp.job j where j.tenant_id = erp.require_tenant_id() and j.handler_code = 'notifications.dispatch'),
    'unread', (select count(*) from erp.notification n
                where n.tenant_id = erp.require_tenant_id() and n.app_user_id = erp.current_principal_id()
                  and n.status in ('sent', 'delivered')));
$$;

create or replace function public.erp_notification_health()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(n)), '[]'::jsonb) from erp.notification_health_report(7) n;
$$;

create or replace function public.erp_upsert_print_route(
  p_code text, p_output_kind text, p_printer_code text, p_template_code text default null,
  p_site_id uuid default null, p_workstation text default null, p_app_user_id uuid default null, p_priority integer default 100)
returns uuid language sql set search_path = '' as $$
  select erp.upsert_print_route(p_code, p_output_kind, p_printer_code, p_template_code, p_site_id, p_workstation, p_app_user_id, p_priority);
$$;

create or replace function public.erp_print_routes()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', r.code, 'output_kind', r.output_kind, 'template_code', r.template_code,
           'site', s.code, 'workstation', r.workstation, 'person', u.display_name,
           'printer', p.code, 'priority', r.priority, 'status', r.status)
         order by r.code), '[]'::jsonb)
    from erp.print_route r
    join erp.printer p on p.tenant_id = r.tenant_id and p.id = r.printer_id
    left join erp.site s on s.tenant_id = r.tenant_id and s.id = r.site_id
    left join erp.app_user u on u.tenant_id = r.tenant_id and u.id = r.app_user_id
   where r.tenant_id = erp.require_tenant_id();
$$;

create or replace function public.erp_route_print(p_render_id uuid, p_site_id uuid default null, p_workstation text default null)
returns jsonb language sql set search_path = '' as $$ select erp.route_print(p_render_id, p_site_id, p_workstation); $$;

create or replace function public.erp_reprint_output(p_render_id uuid, p_printer_code text default null, p_site_id uuid default null, p_workstation text default null)
returns jsonb language sql set search_path = '' as $$ select erp.reprint_output(p_render_id, p_printer_code, p_site_id, p_workstation); $$;

create or replace function public.erp_confirm_delivery(p_delivery_id uuid)
returns void language sql set search_path = '' as $$ select erp.confirm_delivery(p_delivery_id); $$;

create or replace function public.erp_fail_delivery(p_delivery_id uuid, p_reason text)
returns void language sql set search_path = '' as $$ select erp.fail_delivery(p_delivery_id, p_reason); $$;

create or replace function public.erp_print_queue_health()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(q) order by q.printer_code), '[]'::jsonb) from erp.print_queue_health_report() q;
$$;

create or replace function public.erp_upsert_sender_identity(p_domain text, p_category text default 'transactional', p_from_local_part text default 'no-reply', p_reply_to text default null)
returns uuid language sql set search_path = '' as $$ select erp.upsert_sender_identity(p_domain, p_category, p_from_local_part, p_reply_to); $$;

create or replace function public.erp_record_sender_verification(p_domain text, p_spf boolean, p_dkim boolean, p_dmarc boolean)
returns jsonb language sql set search_path = '' as $$ select erp.record_sender_verification(p_domain, p_spf, p_dkim, p_dmarc); $$;

create or replace function public.erp_sender_identities()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'identities', coalesce((
      select jsonb_agg(jsonb_build_object(
               'domain', s.domain, 'category', s.category, 'from_address', s.from_local_part || '@' || s.domain,
               'reply_to', s.reply_to, 'spf_verified_at', s.spf_verified_at, 'dkim_verified_at', s.dkim_verified_at,
               'dmarc_verified_at', s.dmarc_verified_at, 'verified_at', s.verified_at, 'status', s.status,
               'checklist', erp.sender_dns_checklist(s.domain))
             order by s.domain, s.category)
        from erp.sender_identity s where s.tenant_id = erp.require_tenant_id()), '[]'::jsonb),
    'transactional', erp.sender_for('transactional'),
    'operational', erp.sender_for('operational'));
$$;

create or replace function public.erp_render_label(p_template_code text, p_printer_code text, p_document_id uuid default null, p_locale text default 'en')
returns jsonb language sql set search_path = '' as $$ select erp.render_label(p_template_code, p_printer_code, p_document_id, p_locale); $$;

create or replace function public.erp_output_health()
returns jsonb language sql stable set search_path = '' as $$ select erp.output_health_report(); $$;

revoke all on function
  public.erp_configure_notifications(),
  public.erp_upsert_notification_route(text, text, text, text, text, text, text, uuid, text, text, integer, integer, text, boolean),
  public.erp_set_notification_route_status(text, text),
  public.erp_notification_routes(),
  public.erp_my_notifications(integer),
  public.erp_mark_notification_read(uuid),
  public.erp_set_notification_preference(text, boolean),
  public.erp_set_my_quiet_hours(integer[], time, time, text, text),
  public.erp_my_notification_settings(),
  public.erp_notification_health(),
  public.erp_upsert_print_route(text, text, text, text, uuid, text, uuid, integer),
  public.erp_print_routes(),
  public.erp_route_print(uuid, uuid, text),
  public.erp_reprint_output(uuid, text, uuid, text),
  public.erp_confirm_delivery(uuid),
  public.erp_fail_delivery(uuid, text),
  public.erp_print_queue_health(),
  public.erp_upsert_sender_identity(text, text, text, text),
  public.erp_record_sender_verification(text, boolean, boolean, boolean),
  public.erp_sender_identities(),
  public.erp_render_label(text, text, uuid, text),
  public.erp_output_health()
  from public, anon;

grant execute on function
  public.erp_configure_notifications(),
  public.erp_upsert_notification_route(text, text, text, text, text, text, text, uuid, text, text, integer, integer, text, boolean),
  public.erp_set_notification_route_status(text, text),
  public.erp_notification_routes(),
  public.erp_my_notifications(integer),
  public.erp_mark_notification_read(uuid),
  public.erp_set_notification_preference(text, boolean),
  public.erp_set_my_quiet_hours(integer[], time, time, text, text),
  public.erp_my_notification_settings(),
  public.erp_notification_health(),
  public.erp_upsert_print_route(text, text, text, text, uuid, text, uuid, integer),
  public.erp_print_routes(),
  public.erp_route_print(uuid, uuid, text),
  public.erp_reprint_output(uuid, text, uuid, text),
  public.erp_confirm_delivery(uuid),
  public.erp_fail_delivery(uuid, text),
  public.erp_print_queue_health(),
  public.erp_upsert_sender_identity(text, text, text, text),
  public.erp_record_sender_verification(text, boolean, boolean, boolean),
  public.erp_sender_identities(),
  public.erp_render_label(text, text, uuid, text),
  public.erp_output_health()
  to authenticated, service_role;

-- ── Registration ─────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp','notification_route','tenant_scoped', 'Part 15 §15.6. Event and severity to audience, with digest, escalation and the mandatory flag.'),
  ('erp','notification','tenant_scoped', 'Part 15 §15.6. One message to one person on one channel, its delivery tracked; state moves, so not append-only.'),
  ('erp','notification_preference','tenant_scoped', 'Part 15 §15.6. A person''s channel choices within the organisation''s bounds.'),
  ('erp','notification_watermark','tenant_scoped', 'Part 15 §15.6. Where the router has read the event stream to.'),
  ('erp','print_route','tenant_scoped', 'Part 15 §15.4. Output kind to printer by site, workstation or person; the most specific wins.'),
  ('erp','sender_identity','tenant_scoped', 'Part 15 §15.5. The organisation''s sending domains and their SPF, DKIM and DMARC verification.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.attribution_exemption (schema_name, table_name, rationale) values
  ('erp', 'notification', 'Written by the router and the dispatcher on behalf of the event''s actor, for a person who did not act; carries created_at and the recipient, which is its attribution.'),
  ('erp', 'notification_watermark', 'One row per organisation, moved by the router; a position, not a record anybody authored.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_notifications', 'erp.configure_notifications', 'Installs the two notification jobs through a change set; administration.configure inside the installer.'),
  ('erp_upsert_notification_route', 'erp.upsert_notification_route', 'Defines a route from an event and severity to an audience. administration.configure.'),
  ('erp_set_notification_route_status', 'erp.set_notification_route_status', 'Switches a route on or off. administration.configure.'),
  ('erp_mark_notification_read', 'erp.mark_notification_read', 'Marks one of the caller''s own notifications read; the function refuses anybody else''s.'),
  ('erp_set_notification_preference', 'erp.set_notification_preference', 'The caller''s own channel preference; in-app cannot be switched off.'),
  ('erp_set_my_quiet_hours', 'erp.set_my_quiet_hours', 'The caller''s own quiet hours, replacing their previous ones.'),
  ('erp_upsert_print_route', 'erp.upsert_print_route', 'Binds an output kind to a printer by site, workstation or person. administration.configure.'),
  ('erp_route_print', 'erp.route_print', 'Queues a render to the printer the most specific route names. Gated by the template version''s own required permission.'),
  ('erp_reprint_output', 'erp.reprint_output', 'A new render marked as a copy of the original, queued to a printer. Gated by the template version''s own required permission; audited by the render row.'),
  ('erp_confirm_delivery', 'erp.confirm_delivery', 'The gateway confirms a delivery it made. administration.integrate.'),
  ('erp_fail_delivery', 'erp.fail_delivery', 'The gateway fails a delivery with the reason. administration.integrate.'),
  ('erp_upsert_sender_identity', 'erp.upsert_sender_identity', 'Registers a sending domain per category. administration.integrate.'),
  ('erp_record_sender_verification', 'erp.record_sender_verification', 'Records which of SPF, DKIM and DMARC verified; the domain sends as itself only when all three did. administration.integrate.'),
  ('erp_render_label', 'erp.render_label', 'Composes a label as ZPL at the printer''s resolution and queues it, archiving the render. Gated by the template version''s own required permission.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('output_channels', 'Output channels sound', 'assertion', 'platform',
   'erp', 'assert_output_channels_sound', '', 'output_channels_report', '',
   'Part 15''s channels: every notification route names a template its channel has and escalates to a live role, every failed or suppressed notification has its in-app copy, every print route names a live printer where it says, and a sending domain''s verification is not stale.',
   true, 69)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, function_name = excluded.function_name,
  detail_function = excluded.detail_function, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, description) values
('email.platform_sender', 'en', 'no-reply@cloveerp.com',
 '§15.5: the platform''s sending address, used with the organisation''s reply-to until its own domain is verified.'),
('job_handler.route_notifications.name', 'en', 'Route notifications', 'The scheduled job that turns events into notifications for their audiences.'),
('job_handler.dispatch_notifications.name', 'en', 'Dispatch notifications', 'The scheduled job that holds, digests, sends, falls back and escalates.'),
('nav.notifications', 'en', 'Notifications',
 'Navigation label for a person''s notifications, their channel preferences and quiet hours, and the routes an administrator defines.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Notifications'),
    ('What the product told you, what it held for your quiet hours, and what it could not deliver another way. In-app is the channel that always works; nothing addressed to you is lost because another channel failed.'),
    ('Notification services are not installed. Installing them is a configuration change, approved and promoted like a module: the two jobs that route events to audiences and dispatch what was routed.'),
    ('Install notification services'),
    ('Nothing has been sent to you.'),
    ('Mark as read'),
    ('Escalated'),
    ('Digest'),
    ('Your channels'),
    ('Switch a channel off and anything routed to it reaches you here instead; a route your role requires reaches you here regardless.'),
    ('Quiet hours'),
    ('Between these times on these days, notifications below the override severity wait until the window ends.'),
    ('Days'),
    ('From'),
    ('Until'),
    ('Breaks through at or above'),
    ('Save quiet hours'),
    ('Clear quiet hours'),
    ('Routes'),
    ('An event and a severity to an audience: a role, a department, a person, or whoever owns the affected object. A route may digest, escalate on a timer, and be mandatory.'),
    ('No route is defined, so no event reaches anybody.'),
    ('Delivery, last seven days'),
    ('Print routes'),
    ('Which printer a document or label goes to, by site, workstation or person. The most specific route that matches wins.'),
    ('No print route is defined; a print request has nowhere to go until one is.'),
    ('Print queues'),
    ('Queue depth, the oldest waiting print and the last confirmed one per printer, with the signal §15.4 names when something is wrong.'),
    ('No active printer is registered.'),
    ('Sending domains'),
    ('Until a domain verifies its SPF, DKIM and DMARC records the organisation sends from the platform''s address with its own reply-to. Each record to publish is listed with why.'),
    ('No sending domain is registered; messages go from the platform''s address.'),
    ('Sends as'),
    ('Output health'),
    ('Requests, deliveries by state, the failure rate and the print queue depth, alongside job health.'),
    ('Verified'),
    ('Not yet verified')
  ) t(text)
on conflict (key, locale) do nothing;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/notifications', 'nav.notifications', 'administration',
   'What the product told you and how it reaches you: your notifications with delivery tracked, your channel preferences within the organisation''s bounds, your quiet hours with the severity that breaks through, and, for an administrator, the routes from events to audiences.',
   '["Read and mark what was sent to you; an escalation says how long it went unacknowledged.","Switch a channel off if you prefer another; in-app always works and cannot be switched off.","Set quiet hours; anything below the override severity waits for the window to end.","An administrator installs notification services once and defines routes: which events, which severity, which audience, digested or escalated."]',
   'Set your quiet hours, or define a route if you administer the organisation.',
   '{erp_configure_notifications,erp_upsert_notification_route,erp_set_my_quiet_hours}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

update erp_ref.help_topic set
  summary = 'Output templates, printers and print routes, requests with their renders and deliveries, print queue health, the organisation''s sending domains and their verification, suppressed addresses, and output health alongside job health.',
  steps = '["Version a template; a label version ships with a decode check.","Register a printer, then a print route so a request knows where to go.","Register a sending domain and publish its three DNS records; until they verify, messages go from the platform''s address.","A reprint is a new render marked as a copy; every request records its render and delivery."]',
  actions = '{erp_upsert_printer,erp_upsert_print_route,erp_reprint_output,erp_render_label,erp_upsert_sender_identity,erp_record_sender_verification}'
where screen_path = '/operations/output';

insert into erp_ref.first_run_step (guide_code, seq, screen_path, permission_code, title, why) values
  ('administrator', 7, '/operations/output', 'administration.integrate',
   'Publish the DNS records for your sending domain',
   'Until SPF, DKIM and DMARC verify, invoices and reminders go from the platform''s address. The three records are listed on the screen with why each matters.')
on conflict (guide_code, seq) do update set
  screen_path = excluded.screen_path, permission_code = excluded.permission_code,
  title = excluded.title, why = excluded.why;

-- ── The decisions ────────────────────────────────────────────────────────────

insert into erp_meta.policy_decision (code, title, spec_reference, decision, rationale, status, evidence) values
  ('delivery_is_the_gateway',
   'The database queues; the gateway delivers',
   'v1.2 §15.4, §15.5, §15.6',
   'A queued print, email or channel message is a row in erp.output_delivery or erp.notification with status sent or queued. Putting bytes on a wire is done by the outbound gateway, which confirms or fails each one back through erp.confirm_delivery() and erp.fail_delivery(). The database tracks; it does not transmit.',
   'SQL cannot open a socket, and a status that claimed delivery without one would be the kind of green the assertions exist to refuse. The queue is the contract: a monitored backlog, retries counted, failures with reasons, and an in-app copy of every notification another channel could not carry.',
   'accepted',
   'erp.output_delivery status transitions queued → sent → confirmed or failed through erp.confirm_delivery() and erp.fail_delivery(); erp.print_queue_health_report() alerts before the operation notices; erp.dispatch_notifications() writes the in-app fallback.'),
  ('zpl_is_composed_here',
   'ZPL is composed in the database; EPL and IPL are translated by the gateway',
   'v1.2 §15.3',
   'erp.compose_zpl() turns a resolved render into ZPL at the printer''s resolution. A printer that speaks EPL or IPL is refused by erp.render_label() with the reason, and an estate that needs them prints through the gateway''s translation of the same ZPL.',
   '§15.3 names ZPL as primary and the others as supported for legacy estates. One composer kept correct is worth more than three kept approximately; the decode check on a label version proves the ZPL scans, and a translation is proved the same way at the printer.',
   'accepted',
   'erp.compose_zpl(); erp.render_label() refuses a non-ZPL printer with ERPWARE_LABEL_LANGUAGE_NOT_COMPOSED; erp_test.output_channels_suite() proves the 203 and 300 dpi renders differ only in scale.'),
  ('notification_routes_outside_promotion',
   'Notification and print routes are not yet promotable configuration',
   'v1.2 §15.7',
   'erp.notification_route and erp.print_route are tenant-scoped, audited and asserted, but are not on erp_meta.promotable_surface and carry no live-config guard, so they cannot yet move between an organisation''s environments through a change set.',
   'Each needs a branch in erp.apply_change_set_item and an arm in erp.configuration_manifest. Recorded open rather than registered without the branch, which would fail erp.assert_configuration_promotable(); the same shape as report_version_outside_promotion was before it was closed, and to be closed the same way.',
   'open',
   'erp_meta.promotable_surface holds neither table; erp.apply_change_set_item has no branch for either.')
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.output_channels_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  ad uuid := gen_random_uuid(); op uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzoc-' || substr(md5(random()::text), 1, 6);
  v_second uuid; v_tok text; v_entity uuid; v_site uuid; v_admin uuid;
  res jsonb; v_ok boolean; v_msg text; v_n integer; v_id uuid; v_render uuid; v_delivery uuid;
  v_zpl203 text; v_zpl300 text; v_notif uuid;
begin
  select * into r from erp.provision_tenant(v_code, 'Output Channels', 'admin@zzoc.test', 'Channels Admin');
  v_tenant := r.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzoc.test'), (op, 'op@zzoc.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);
  v_admin := erp.current_principal_id();
  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  -- The suite's own event types, registered so the payload validator has a
  -- schema to hold them to, and removed at the end.
  insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description)
  values ('zzoc.thing_happened', 1, 'tenant', 'administration', 'event.zzoc', 'suite'),
         ('zzoc.mail_requested', 1, 'tenant', 'administration', 'event.zzoc', 'suite'),
         ('zzoc.digest_one_posted', 1, 'tenant', 'administration', 'event.zzoc', 'suite'),
         ('zzoc.digest_two_posted', 1, 'tenant', 'administration', 'event.zzoc', 'suite'),
         ('zzoc.urgent_thing_raised', 1, 'tenant', 'administration', 'event.zzoc', 'suite');

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (v_tenant, v_entity, 'DC1', 'Distribution centre', 'warehouse', 'active') returning id into v_site;
  perform erp.upsert_notification_template('tpl_inapp', 'in_app', 'notify.body.generic', 'notify.subject.generic');
  perform erp.upsert_notification_template('tpl_email', 'email', 'notify.body.generic', 'notify.subject.generic');
  -- A label template with a version that decodes, and two printers at
  -- different resolutions.
  perform erp.upsert_output_template('bin_label_test', 'output.template.bin_label', 'label', null, '100x150mm',
    '[{"kind": "title", "fields": ["document_number"]}, {"kind": "barcode", "fields": ["document_number"]}]'::jsonb);
  perform erp.upsert_output_template_version('bin_label_test', 'zpl', '{}'::jsonb, '[]'::jsonb, 'inventory.read',
    'zpl', '^XA^BCN^FD123^FS^XZ', true, '123', current_date - 1, 'test');
  perform erp.upsert_printer('LBL203', 'DC1', 'Bench label printer', 'label', 'zpl', 203, 'Bench 1', '100x150', 'tcp://10.0.0.11:9100');
  perform erp.upsert_printer('LBL300', 'DC1', 'Fine label printer', 'label', 'zpl', 300, 'Bench 2', '100x150', 'tcp://10.0.0.12:9100');
  perform erp.upsert_printer('DOC1', 'DC1', 'Office printer', 'document', 'pdf', null, 'Office', 'A4', 'ipp://10.0.0.20');
  perform erp.configure_notifications();
  perform erp_test.close_bootstrap_window(v_tenant);

  -- A second person, an operator with the administrator role too, so a role
  -- audience has two members.
  res := public.erp_invite_principal('op@zzoc.test', 'Channel Operator');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'suite');
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.claim_invitation(v_tok);
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);

  return query select 'installing notification services is a change set carrying the two jobs',
    (select count(*) from erp.job j where j.tenant_id = v_tenant
      and j.handler_code in ('notifications.route_events', 'notifications.dispatch')) = 2,
    'routed and dispatched every two minutes';

  -- ── §15.6 routing to an audience ──────────────────────────────────────────

  begin
    perform erp.upsert_notification_route('bad', 'Bad', 'stock.%', 'medium', 'role', 'administrator', null, null, 'email', 'tpl_inapp');
    v_ok := false; v_msg := 'a route named a template of another channel';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_NOTIFICATION_TEMPLATE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a route cannot name a template of another channel', v_ok, v_msg;

  perform erp.upsert_notification_route('admins_inapp', 'Administrators, in app', 'zzoc.%', 'medium',
                                        'role', 'administrator', null, null, 'in_app', 'tpl_inapp');
  perform erp.append_event('zzoc.thing_happened', 'tenant', v_tenant, '{"n": 1}'::jsonb, p_event_version => 1);
  select routed into v_n from erp.route_notifications();
  return query select 'an event matching a route reaches every member of its audience',
    v_n = 2 and (select count(*) from erp.notification n where n.tenant_id = v_tenant and n.status = 'pending') = 2,
    format('%s notification(s) for two administrators', v_n);

  select delivered into v_n from erp.dispatch_notifications();
  return query select 'in-app is delivered on the spot',
    v_n = 2 and (select count(*) from erp.notification n where n.tenant_id = v_tenant and n.status = 'delivered') = 2,
    'delivered, not merely sent';

  select (x ->> 'id')::uuid into v_notif from jsonb_array_elements(public.erp_my_notifications(10)) x limit 1;
  perform erp.mark_notification_read(v_notif);
  return query select 'a person marks their own notification read',
    (select n.status = 'read' and n.read_at is not null from erp.notification n where n.id = v_notif), 'read';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.mark_notification_read(v_notif);
    v_ok := false; v_msg := 'somebody else marked it read';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_YOUR_NOTIFICATION%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and nobody else can', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);

  -- ── §15.6 preferences within bounds, and the fallback ─────────────────────

  perform erp.upsert_notification_route('admins_email', 'Administrators, by email', 'zzoc.mail%', 'high',
                                        'role', 'administrator', null, null, 'email', 'tpl_email');
  begin
    perform erp.set_notification_preference('in_app', false);
    v_ok := false; v_msg := 'in-app was switched off';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_IN_APP_CANNOT_BE_SWITCHED_OFF%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'in-app cannot be switched off', v_ok, v_msg;

  perform erp.set_notification_preference('email', false);
  perform erp.append_event('zzoc.mail_requested', 'tenant', v_tenant, '{}'::jsonb, p_event_version => 1);
  perform erp.route_notifications();
  return query select 'a person who switched email off is reached in-app instead',
    (select n.channel_kind = 'in_app' from erp.notification n
      where n.tenant_id = v_tenant and n.app_user_id = v_admin
        and n.route_id = (select id from erp.notification_route where tenant_id = v_tenant and code = 'admins_email')
      order by n.created_at desc limit 1),
    'preference honoured; nothing lost';
  perform erp.set_notification_preference('email', true);

  insert into erp.email_suppression (tenant_id, address, reason, is_permanent) values (v_tenant, 'op@zzoc.test', 'complaint', true);
  select suppressed into v_n from erp.dispatch_notifications();
  return query select 'a suppressed address is refused and the alert reaches the person in-app',
    v_n = 1 and exists (
      select 1 from erp.notification f
       where f.tenant_id = v_tenant and f.app_user_id = v_second and f.channel_kind = 'in_app'
         and f.escalation_of = (select n.id from erp.notification n
                                 where n.tenant_id = v_tenant and n.app_user_id = v_second and n.status = 'suppressed')),
    'suppressed on email, delivered in-app';
  delete from erp.email_suppression where tenant_id = v_tenant;

  return query select 'the assertion sees the fallback and passes',
    erp.assert_output_channels_sound() is not null, 'every lost alert has its copy';

  -- ── §15.6 quiet hours, digest, escalation ─────────────────────────────────

  perform erp.set_my_quiet_hours(array[1,2,3,4,5,6,7]::smallint[], '00:00', '23:59', 'UTC', 'critical');
  perform erp.append_event('zzoc.thing_happened', 'tenant', v_tenant, '{"n": 2}'::jsonb, p_event_version => 1);
  select held into v_n from erp.route_notifications();
  return query select 'a notification below the override severity is held during quiet hours',
    v_n = 1 and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.app_user_id = v_admin and n.status = 'held'),
    'held until the window ends';
  update erp.notification set held_until = now() - interval '1 minute' where tenant_id = v_tenant and status = 'held';
  select released into v_n from erp.dispatch_notifications();
  return query select 'and released when the window ends', v_n = 1, 'released and delivered';
  perform erp.set_my_quiet_hours(null, null, null, 'UTC');

  perform erp.upsert_notification_route('digest', 'Digested', 'zzoc.digest%', 'low',
                                        'user', null, null, v_admin, 'in_app', 'tpl_inapp', 30);
  perform erp.append_event('zzoc.digest_one_posted', 'tenant', v_tenant, '{}'::jsonb, p_event_version => 1);
  perform erp.append_event('zzoc.digest_two_posted', 'tenant', v_tenant, '{}'::jsonb, p_event_version => 1);
  perform erp.route_notifications();
  update erp.notification set created_at = now() - interval '31 minutes' where tenant_id = v_tenant and digest_key is not null;
  select digested into v_n from erp.dispatch_notifications();
  return query select 'two events on a digesting route become one message',
    v_n = 1 and exists (select 1 from erp.notification n where n.tenant_id = v_tenant and n.digest_of = 2 and n.status = 'delivered')
    and (select count(*) from erp.notification n where n.tenant_id = v_tenant and n.status = 'digested') = 2,
    'one digest of two, the originals folded';

  perform erp.upsert_notification_route('escalating', 'Escalates', 'zzoc.urgent%', 'high',
                                        'user', null, null, v_second, 'in_app', 'tpl_inapp', null, 15, 'administrator');
  perform erp.append_event('zzoc.urgent_thing_raised', 'tenant', v_tenant, '{}'::jsonb, p_event_version => 1);
  perform erp.route_notifications(); perform erp.dispatch_notifications();
  update erp.notification set created_at = now() - interval '16 minutes'
   where tenant_id = v_tenant and route_id = (select id from erp.notification_route where tenant_id = v_tenant and code = 'escalating');
  select escalated into v_n from erp.dispatch_notifications();
  return query select 'unacknowledged past the timer, it escalates to the role once',
    v_n = 2 and (select count(*) from erp.notification n where n.tenant_id = v_tenant and n.subject like 'Escalated:%') = 2
    and (select d.escalated from erp.dispatch_notifications() d) = 0,
    'two administrators told; not told again';

  -- ── §15.3 ZPL scales to the printer ───────────────────────────────────────

  res := erp.render_label('bin_label_test', 'LBL203');
  v_zpl203 := res ->> 'zpl'; v_render := (res ->> 'render_id')::uuid; v_delivery := (res ->> 'delivery_id')::uuid;
  res := erp.render_label('bin_label_test', 'LBL300');
  v_zpl300 := res ->> 'zpl';
  return query select 'one label template renders at 203 and 300 dpi without a second template',
    v_zpl203 like '^XA%^XZ' and v_zpl300 like '^XA%^XZ'
    and v_zpl203 like '%^PW799%' and v_zpl300 like '%^PW1181%'
    and v_zpl203 like '%^BCN%' and v_zpl203 <> v_zpl300,
    format('203: %s chars, 300: %s chars', length(v_zpl203), length(v_zpl300));

  return query select 'the render is archived with its ZPL and queued to the printer',
    (select o.content = v_zpl203 and o.checksum = md5(v_zpl203) from erp.output_render o where o.id = v_render)
    and (select d.status = 'queued' and d.destination = 'tcp://10.0.0.11:9100' from erp.output_delivery d where d.id = v_delivery),
    'archived, queued';

  begin
    perform erp.render_label('bin_label_test', 'DOC1');
    v_ok := false; v_msg := 'a label was rendered to a document printer';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_PRINTER%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a label cannot go to a document printer', v_ok, v_msg;

  -- ── §15.4 routing, reprint, queue health ──────────────────────────────────

  begin
    perform erp.route_print(v_render, v_site, null);
    v_ok := false; v_msg := 'a print was routed with no route';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_PRINT_ROUTE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'with no route a print has nowhere to go, and says so', v_ok, v_msg;

  perform erp.upsert_print_route('labels_dc1', 'label', 'LBL203', null, v_site);
  perform erp.upsert_print_route('labels_bench2', 'label', 'LBL300', null, v_site, 'BENCH-2');
  res := erp.route_print(v_render, v_site, 'BENCH-2');
  return query select 'the most specific route wins: the workstation''s printer over the site''s',
    res ->> 'printer' = 'LBL300' and res ->> 'route' = 'labels_bench2', res ->> 'printer';
  res := erp.route_print(v_render, v_site, null);
  return query select 'and the site''s printer when no workstation is given',
    res ->> 'printer' = 'LBL203', res ->> 'printer';

  begin
    perform erp.upsert_print_route('bad_kind', 'label', 'DOC1');
    v_ok := false; v_msg := 'labels were routed to a document printer';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PRINTER_KIND_MISMATCH%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a label route cannot name a document printer', v_ok, v_msg;

  res := erp.reprint_output(v_render, 'LBL203');
  return query select 'a reprint is a new render marked as a copy of the original',
    (res ->> 'is_copy')::boolean and (res ->> 'reissue_of')::uuid = v_render
    and (select o.is_copy and o.content = v_zpl203 from erp.output_render o where o.id = (res ->> 'render_id')::uuid),
    'copy, same bytes, new row';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.confirm_delivery(v_delivery);
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  return query select 'the gateway confirms a delivery it made',
    (select d.status = 'confirmed' and d.confirmed_at is not null and d.attempts = 1 from erp.output_delivery d where d.id = v_delivery),
    'confirmed';

  -- created_at is frozen by the attribution trigger, so an old queued print is
  -- written old rather than aged.
  insert into erp.output_delivery (tenant_id, output_render_id, destination, destination_kind, status, attempts, created_at)
  values (v_tenant, v_render, 'tcp://10.0.0.12:9100', 'print', 'queued', 0, now() - interval '40 minutes');
  return query select 'a printer with queued prints and nothing confirmed for thirty minutes reads as offline',
    exists (select 1 from erp.print_queue_health_report() q where q.printer_code = 'LBL300' and q.signal like 'printer offline%'),
    'alerting before the operation notices';

  -- ── §15.5 sender identity ─────────────────────────────────────────────────

  return query select 'with no verified domain the organisation sends from the platform''s address',
    not (erp.sender_for('transactional') ->> 'own_domain')::boolean
    and erp.sender_for('transactional') ->> 'from_address' like '%@%', erp.sender_for('transactional') ->> 'from_address';

  perform erp.upsert_sender_identity('example-org.test', 'transactional', 'invoices', 'accounts@example-org.test');
  res := erp.record_sender_verification('example-org.test', true, true, false);
  return query select 'two records of three is not verified, and the reply-to is used meanwhile',
    not (res ->> 'verified')::boolean
    and erp.sender_for('transactional') ->> 'reply_to' = 'accounts@example-org.test'
    and not (erp.sender_for('transactional') ->> 'own_domain')::boolean,
    'SPF and DKIM, no DMARC';

  res := erp.record_sender_verification('example-org.test', true, true, true);
  return query select 'all three verified and the organisation sends as itself',
    (res ->> 'verified')::boolean
    and erp.sender_for('transactional') ->> 'from_address' = 'invoices@example-org.test'
    and (erp.sender_for('transactional') ->> 'own_domain')::boolean
    and not (erp.sender_for('operational') ->> 'own_domain')::boolean,
    'transactional as itself; operational still from the platform';

  return query select 'the checklist names the three records to publish, with why',
    jsonb_array_length(erp.sender_dns_checklist('example-org.test')) = 3
    and exists (select 1 from jsonb_array_elements(erp.sender_dns_checklist('example-org.test')) x
                 where x ->> 'record' = 'DMARC' and x ->> 'name' = '_dmarc.example-org.test'),
    'SPF, DKIM, DMARC';

  return query select 'output health reports the queue and the sender alongside the counts',
    (erp.output_health_report() ->> 'print_queue_depth')::integer >= 1
    and (erp.output_health_report() -> 'sender' ->> 'own_domain')::boolean,
    erp.output_health_report() ->> 'print_queue_depth';

  return query select 'and the assertion passes over all of it',
    erp.assert_output_channels_sound() is not null, 'sound';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (ad, op);
  delete from erp_ref.event_type where code like 'zzoc.%';
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant)
    and not exists (select 1 from erp_ref.event_type where code like 'zzoc.%'), 'organisation and event types gone';
end;
$$;

create or replace function erp_test.assert_output_channels_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _output_channels_result on commit drop as
    select * from erp_test.output_channels_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _output_channels_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_OUTPUT_CHANNELS_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('output channels: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_output_channels_suite();

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_configuration_promotable();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_job_handlers_resolvable();
select erp.assert_output_integrity();
select erp.assert_output_channels_sound();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
