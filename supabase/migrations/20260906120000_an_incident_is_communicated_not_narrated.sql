-- =============================================================================
-- An incident is communicated, not narrated
--
-- Specification v1.6 §16.5 (v1.2 §17.3–17.4). Phase 7 of the outstanding-work
-- programme.
--
-- What Part 17 built (20260904320000 → 20260904580000) is an incident register
-- an operator can run an incident from: declare with three roles, post updates,
-- contain, name the organisations reached, put a security incident on the
-- disclosure path, resolve with the review. What it did not build is the
-- communication the specification describes. An update was one row that one
-- screen showed to the organisations named; nothing was on a timer, nothing
-- reached anybody's inbox, nothing was published outside the database, a
-- provider's outage was nobody's incident until somebody noticed, and the
-- history disappeared from the organisation's screen thirty days after
-- resolution.
--
-- This file makes one incident update the thing every channel carries:
--
--   * A platform component vocabulary (erp_ref.platform_component), so an
--     incident says which parts of the platform it touches, and scope
--     (everyone, named organisations, unknown) is stated at declaration rather
--     than only at containment. An incident declared as reaching everyone is
--     shown to everyone from that moment.
--   * The update timer is stored, not computed at report time:
--     erp_meta.incident.next_update_due_at is set from the severity's cadence
--     (or an earlier promise; a later one is refused). The platform sweep
--     records a prompt to the communications owner when it falls due,
--     escalates to the commander after the severity's response window and to
--     the owner role after two, and writes the audit row each time.
--   * The five-field update (affected, not affected, what is being done,
--     meanwhile, next update) is rendered once into the body every channel
--     reads. Identical content everywhere, by construction.
--   * The platform sweep delivers each update to every organisation it reached
--     — the in-app row and the email row, to the organisation's administrators
--     and to anybody who subscribed — and, in the platform's own organisation,
--     publishes it as a status.publish command to every status_page external
--     system through the integration gateway. The status page is therefore
--     outside this database (the reasoning of status_page_not_built holds) and
--     now exists (infra/status/).
--   * Third-party dependencies are rows with status feeds. A worker handler
--     polls them; a major or critical indicator declares a severity-3 incident
--     "below the platform" with the origin stated, and recovery resolves it.
--   * History stays visible: erp_incident_history() shows an organisation every
--     incident that reached it, with the timeline and the shared review, for
--     as long as the register holds it. Reviews are assembled from the updates;
--     actions are tracked; the open actions of incidents sharing a component
--     are shown when a new one is declared.
--
-- Two decisions enter the register: D35 (communication is on a timer) and
-- D36 (history stays visible). The rows the earlier registrations numbered
-- D35–D39 move to D37–D41, as specification v1.6 numbers them. The policy
-- decision status_page_not_built is superseded by
-- status_page_published_through_the_gateway.
--
-- Corrections the code forced on the plan: erp.append_event() needs a tenant
-- and erp.job.tenant_id is NOT NULL, so there is no "platform event" — the
-- update row is the event, and delivery runs per organisation inside the sweep
-- under that organisation's job context. erp.submit_command() authorises as a
-- principal the sweep does not carry, so publication inserts the command
-- itself (drafted → approved → released), validating the payload against the
-- operation's request schema exactly as submit_command would. The webhook
-- notification channel settles without a request (finding logged, not fixed
-- here): chat reaches people only through a status_page system whose endpoint
-- accepts the JSON.
--
-- Nothing here edits a pushed migration. Bodies that change are re-emitted
-- after asserting the deployed text; erp.run_due_jobs_all_tenants() is
-- patched by asserted needle.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Components and dependencies
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.platform_component (
  code          text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key      text not null,
  description   text not null,
  seq           integer not null,
  registered_at timestamptz not null default now()
);

comment on table erp_ref.platform_component is
  'Specification v1.6 §16.5: the parts of the platform an incident can name. '
  'Stable codes, so a status page and an organisation''s screen say the same '
  'thing about the same part.';

insert into erp_ref.platform_component (code, name_key, description, seq) values
  ('application',          'platform_component.application.name',          'The web application: signing in and every screen.', 10),
  ('authentication',       'platform_component.authentication.name',       'Sign-in, sessions and invitations.', 20),
  ('order_intake',         'platform_component.order_intake.name',         'Creating and issuing sales and purchase documents.', 30),
  ('allocation',           'platform_component.allocation.name',           'Reserving stock against orders.', 40),
  ('printing',             'platform_component.printing.name',             'Labels and documents sent to printers.', 50),
  ('output',               'platform_component.output.name',               'Rendered documents and report packs.', 60),
  ('devices',              'platform_component.devices.name',              'The scanner application and the device action queue.', 70),
  ('integration_dispatch', 'platform_component.integration_dispatch.name', 'Commands and messages to and from external systems.', 80),
  ('notifications',        'platform_component.notifications.name',        'In-app notices and email.', 90),
  ('scheduler',            'platform_component.scheduler.name',            'Scheduled jobs and the platform sweep.', 100),
  ('reporting',            'platform_component.reporting.name',            'Reports, extracts and the analytics contract.', 110),
  ('enquiry',              'platform_component.enquiry.name',              'The public contact form.', 120)
on conflict (code) do update set name_key = excluded.name_key, description = excluded.description, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('platform_component.application.name',          'en', 'Application',            'administration'),
  ('platform_component.application.name',          'de', 'Anwendung',              'administration'),
  ('platform_component.authentication.name',       'en', 'Sign-in',                'administration'),
  ('platform_component.authentication.name',       'de', 'Anmeldung',              'administration'),
  ('platform_component.order_intake.name',         'en', 'Order intake',           'administration'),
  ('platform_component.order_intake.name',         'de', 'Auftragserfassung',      'administration'),
  ('platform_component.allocation.name',           'en', 'Allocation',             'administration'),
  ('platform_component.allocation.name',           'de', 'Reservierung',           'administration'),
  ('platform_component.printing.name',             'en', 'Printing',               'administration'),
  ('platform_component.printing.name',             'de', 'Druck',                  'administration'),
  ('platform_component.output.name',               'en', 'Output',                 'administration'),
  ('platform_component.output.name',               'de', 'Ausgabe',                'administration'),
  ('platform_component.devices.name',              'en', 'Devices',                'administration'),
  ('platform_component.devices.name',              'de', 'Geräte',                 'administration'),
  ('platform_component.integration_dispatch.name', 'en', 'Integration dispatch',   'administration'),
  ('platform_component.integration_dispatch.name', 'de', 'Integrationsversand',    'administration'),
  ('platform_component.notifications.name',        'en', 'Notifications',          'administration'),
  ('platform_component.notifications.name',        'de', 'Benachrichtigungen',     'administration'),
  ('platform_component.scheduler.name',            'en', 'Scheduler',              'administration'),
  ('platform_component.scheduler.name',            'de', 'Zeitplaner',             'administration'),
  ('platform_component.reporting.name',            'en', 'Reporting',              'administration'),
  ('platform_component.reporting.name',            'de', 'Berichtswesen',          'administration'),
  ('platform_component.enquiry.name',              'en', 'Contact form',           'administration'),
  ('platform_component.enquiry.name',              'de', 'Kontaktformular',        'administration')
on conflict (key, locale) do update set value = excluded.value;

create table if not exists erp_meta.incident_component (
  incident_id    uuid not null references erp_meta.incident (id) on delete cascade,
  component_code text not null references erp_ref.platform_component (code),
  primary key (incident_id, component_code)
);

-- The third parties the platform stands on. A feed is a Statuspage v2
-- status.json where the provider publishes one; the worker handler reads it.
-- affects_service says whether the provider's outage is the platform's outage
-- — GitHub's is not: a deploy waits, nobody's goods stop moving.
create table if not exists erp_ref.platform_dependency (
  code            text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key        text not null,
  provider        text not null,
  status_url      text not null,
  feed_url        text,
  feed_kind       text not null default 'statuspage_v2' check (feed_kind in ('statuspage_v2', 'none')),
  affects_service boolean not null default true,
  component_codes text[] not null default '{}',
  seq             integer not null,
  registered_at   timestamptz not null default now(),
  constraint platform_dependency_feed_named check (feed_kind = 'none' or feed_url is not null)
);

comment on table erp_ref.platform_dependency is
  'Specification v1.6 §16.5: the providers below the platform, each with the '
  'status page it publishes and the feed the worker polls. An outage there is '
  'declared here as an incident with its origin stated, so the organisations '
  'are told by the platform and not left to guess from a page elsewhere.';

insert into erp_ref.platform_dependency (code, name_key, provider, status_url, feed_url, feed_kind, affects_service, component_codes, seq) values
  ('supabase',   'platform_dependency.supabase.name',   'Supabase',   'https://status.supabase.com',      'https://status.supabase.com/api/v2/status.json',      'statuspage_v2', true,
   array['application','authentication','order_intake','allocation','printing','output','devices','integration_dispatch','notifications','scheduler','reporting','enquiry'], 10),
  ('resend',     'platform_dependency.resend.name',     'Resend',     'https://resend-status.com',        'https://resend-status.com/api/v2/status.json',        'statuspage_v2', true,
   array['notifications','enquiry'], 20),
  ('cloudflare', 'platform_dependency.cloudflare.name', 'Cloudflare', 'https://www.cloudflarestatus.com', 'https://www.cloudflarestatus.com/api/v2/status.json', 'statuspage_v2', true,
   array['application','enquiry'], 30),
  ('lovable',    'platform_dependency.lovable.name',    'Lovable',    'https://status.lovable.dev',       'https://status.lovable.dev/api/v2/status.json',       'statuspage_v2', true,
   array['application'], 40),
  ('github',     'platform_dependency.github.name',     'GitHub',     'https://www.githubstatus.com',     'https://www.githubstatus.com/api/v2/status.json',     'statuspage_v2', false,
   array[]::text[], 50)
on conflict (code) do update
  set name_key = excluded.name_key, provider = excluded.provider, status_url = excluded.status_url,
      feed_url = excluded.feed_url, feed_kind = excluded.feed_kind, affects_service = excluded.affects_service,
      component_codes = excluded.component_codes, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('platform_dependency.supabase.name',   'en', 'Supabase (database, authentication, functions)', 'administration'),
  ('platform_dependency.supabase.name',   'de', 'Supabase (Datenbank, Anmeldung, Funktionen)',     'administration'),
  ('platform_dependency.resend.name',     'en', 'Resend (email delivery)',                         'administration'),
  ('platform_dependency.resend.name',     'de', 'Resend (E-Mail-Zustellung)',                      'administration'),
  ('platform_dependency.cloudflare.name', 'en', 'Cloudflare (application hosting, status page)',   'administration'),
  ('platform_dependency.cloudflare.name', 'de', 'Cloudflare (Anwendungshosting, Statusseite)',     'administration'),
  ('platform_dependency.lovable.name',    'en', 'Lovable (application publishing)',                'administration'),
  ('platform_dependency.lovable.name',    'de', 'Lovable (Anwendungsveröffentlichung)',            'administration'),
  ('platform_dependency.github.name',     'en', 'GitHub (source and deployment)',                  'administration'),
  ('platform_dependency.github.name',     'de', 'GitHub (Quellcode und Bereitstellung)',           'administration')
on conflict (key, locale) do update set value = excluded.value;

create table if not exists erp_meta.dependency_observation (
  id              bigint generated always as identity primary key,
  dependency_code text not null references erp_ref.platform_dependency (code),
  observed_at     timestamptz not null default now(),
  indicator       text not null check (indicator in ('none', 'minor', 'major', 'critical', 'unknown')),
  description     text,
  raw             jsonb not null default '{}'::jsonb,
  observed_by     text
);
create index if not exists dependency_observation_latest_idx
  on erp_meta.dependency_observation (dependency_code, observed_at desc);

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What the incident record gains
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.incident
  add column if not exists next_update_due_at     timestamptz,
  add column if not exists origin_dependency_code text references erp_ref.platform_dependency (code),
  add column if not exists declared_by            text;

alter table erp_meta.incident_update
  add column if not exists affected       text,
  add column if not exists not_affected   text,
  add column if not exists being_done     text,
  add column if not exists meanwhile      text,
  add column if not exists next_update_at timestamptz;

-- erp.service_notices() sub-selects the updates per incident and there was no
-- index to do it with.
create index if not exists incident_update_incident_idx
  on erp_meta.incident_update (incident_id, posted_at desc);

-- The timer's record: when an update fell due, who was prompted, and when.
create table if not exists erp_meta.incident_prompt (
  id          bigint generated always as identity primary key,
  incident_id uuid not null references erp_meta.incident (id) on delete cascade,
  due_at      timestamptz not null,
  level       text not null check (level in ('communications_owner', 'commander', 'owner')),
  prompted_at timestamptz not null default now(),
  named       text,
  notified    integer not null default 0,
  unique (incident_id, due_at, level)
);

-- Delivery, per organisation. A null update is the declaration itself.
create table if not exists erp_meta.incident_delivery (
  id                 bigint generated always as identity primary key,
  incident_id        uuid not null references erp_meta.incident (id) on delete cascade,
  incident_update_id uuid references erp_meta.incident_update (id) on delete cascade,
  tenant_id          uuid not null references erp.tenant (id) on delete cascade,
  delivered_at       timestamptz not null default now(),
  recipients         integer not null default 0,
  subject            text not null
);
create unique index if not exists incident_delivery_once
  on erp_meta.incident_delivery (tenant_id, incident_id, coalesce(incident_update_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- Publication, per status page system.
create table if not exists erp_meta.incident_publication (
  id                 bigint generated always as identity primary key,
  incident_id        uuid not null references erp_meta.incident (id) on delete cascade,
  incident_update_id uuid references erp_meta.incident_update (id) on delete cascade,
  external_system_id uuid not null,
  command_id         uuid not null,
  published_at       timestamptz not null default now()
);
create unique index if not exists incident_publication_once
  on erp_meta.incident_publication (external_system_id, incident_id, coalesce(incident_update_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table if not exists erp_meta.incident_review (
  incident_id  uuid primary key references erp_meta.incident (id) on delete cascade,
  assembled_at timestamptz not null default now(),
  assembled_by text not null,
  document     jsonb not null,
  is_shared    boolean not null default true
);

create table if not exists erp_meta.incident_action (
  id          uuid primary key default gen_random_uuid(),
  incident_id uuid not null references erp_meta.incident (id) on delete cascade,
  description text not null check (length(btrim(description)) >= 10),
  owner       text not null check (length(btrim(owner)) > 0),
  due_on      date,
  created_at  timestamptz not null default now(),
  created_by  text not null,
  done_at     timestamptz,
  done_note   text,
  constraint incident_action_done_says_how check (done_at is null or done_note is not null)
);

-- The organisation's side: who is told. Administrators by default; anybody
-- may subscribe themselves; an administrator may step out.
create table if not exists erp.incident_subscription (
  id            uuid not null default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant (id) on delete cascade,
  app_user_id   uuid not null,
  is_subscribed boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, app_user_id),
  foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade
);

select erp_meta.register_table('erp', 'incident_subscription', 'tenant_scoped',
  'v1.6 §16.5: who in this organisation is told when an incident reaches it, beyond the administrators told by default.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Writers
-- ═════════════════════════════════════════════════════════════════════════════

-- ── The five fields, rendered once ──────────────────────────────────────────

create or replace function erp.render_incident_update(p_body text,
                                                       p_affected text,
                                                       p_not_affected text,
                                                       p_being_done text,
                                                       p_meanwhile text,
                                                       p_next_update_at timestamptz)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(concat_ws(E'\n',
           nullif(btrim(p_body), ''),
           case when nullif(btrim(p_affected), '') is not null then 'Affected: ' || btrim(p_affected) end,
           case when nullif(btrim(p_not_affected), '') is not null then 'Not affected: ' || btrim(p_not_affected) end,
           case when nullif(btrim(p_being_done), '') is not null then 'What is being done: ' || btrim(p_being_done) end,
           case when nullif(btrim(p_meanwhile), '') is not null then 'Meanwhile: ' || btrim(p_meanwhile) end,
           case when p_next_update_at is not null
                then 'Next update: ' || to_char(p_next_update_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' end), '')
$$;
revoke all on function erp.render_incident_update(text, text, text, text, text, timestamptz) from public, anon, authenticated;

-- ── Declaration, with scope and components ───────────────────────────────────

drop function if exists erp.declare_incident(text, text, text, text, text, text, boolean, text, boolean);

create function erp.declare_incident(p_code text,
                                     p_severity_code text,
                                     p_title text,
                                     p_commander text,
                                     p_communications_owner text,
                                     p_scribe text,
                                     p_is_data_integrity boolean default false,
                                     p_scope text default null,
                                     p_affects_all_tenants boolean default null,
                                     p_components text[] default null,
                                     p_tenant_codes text[] default null,
                                     p_next_update_minutes integer default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff   erp_meta.platform_staff;
  v_sev     erp_ref.support_severity%rowtype;
  v_id      uuid;
  v_comp    text;
  v_minutes integer;
begin
  v_staff := erp_meta.require_platform('operator');

  select * into v_sev from erp_ref.support_severity s where s.code = p_severity_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SEVERITY: % is not a published severity', p_severity_code
      using errcode = '23503',
            hint = '§17.2: the scale is published, which is what stops it being '
                   'negotiated case by case while people are shouting.';
  end if;

  if coalesce(btrim(p_commander), '') = ''
     or coalesce(btrim(p_communications_owner), '') = ''
     or coalesce(btrim(p_scribe), '') = '' then
    raise exception
      'CLOVEERP_INCIDENT_ROLES_UNFILLED: an incident needs a commander, a '
      'communications owner and a scribe'
      using errcode = '23514',
            hint = 'One person may hold more than one, but the role must name '
                   'somebody. Deciding who is writing things down at three in '
                   'the morning is what this prevents.';
  end if;

  if p_components is not null then
    foreach v_comp in array p_components loop
      if not exists (select 1 from erp_ref.platform_component c where c.code = v_comp) then
        raise exception 'CLOVEERP_UNKNOWN_COMPONENT: % is not a platform component', v_comp
          using errcode = '23503',
                hint = 'Name a component from erp_ref.platform_component; the status page and every organisation''s screen use the same vocabulary.';
      end if;
    end loop;
  end if;

  -- The promise may be sooner than the cadence, never later: the cadence is
  -- what was published.
  v_minutes := least(coalesce(p_next_update_minutes, v_sev.update_every_minutes), v_sev.update_every_minutes);
  if p_next_update_minutes is not null and p_next_update_minutes > v_sev.update_every_minutes then
    raise exception 'CLOVEERP_UPDATE_PROMISED_TOO_LATE: % publishes an update every % minutes; % is later than that',
      p_severity_code, v_sev.update_every_minutes, p_next_update_minutes
      using errcode = '23514',
            hint = 'Promise the next update within the severity''s cadence, or leave it to the cadence.';
  end if;
  if p_next_update_minutes is not null and p_next_update_minutes < 1 then
    raise exception 'CLOVEERP_UPDATE_PROMISED_TOO_LATE: the next update is promised in whole minutes from now'
      using errcode = '23514', hint = 'Give a positive number of minutes.';
  end if;

  insert into erp_meta.incident
    (code, severity_code, title, commander, communications_owner, scribe,
     is_data_integrity, scope, affects_all_tenants, next_update_due_at, declared_by)
  values (p_code, p_severity_code, p_title, btrim(p_commander),
          btrim(p_communications_owner), btrim(p_scribe),
          coalesce(p_is_data_integrity, false), p_scope, p_affects_all_tenants,
          now() + make_interval(mins => v_minutes), v_staff.email)
  returning id into v_id;

  insert into erp_meta.incident_component (incident_id, component_code)
  select v_id, c from unnest(coalesce(p_components, '{}'::text[])) c
  on conflict do nothing;

  perform erp_meta.platform_log(
    v_staff, 'platform.incident_declared', null, p_code, p_title,
    jsonb_build_object('severity', p_severity_code,
                       'commander', p_commander,
                       'data_integrity', coalesce(p_is_data_integrity, false),
                       'components', to_jsonb(coalesce(p_components, '{}'::text[])),
                       'affects_all_tenants', p_affects_all_tenants,
                       'next_update_due_at', now() + make_interval(mins => v_minutes)));

  if coalesce(cardinality(p_tenant_codes), 0) > 0 then
    perform erp.name_affected_organisations(p_code, p_tenant_codes);
  end if;

  return v_id;
end;
$$;

comment on function erp.declare_incident is
  'Specification v1.6 §16.5 (v1.2 §17.3). Refuses an unpublished severity, an '
  'unfilled role and an unknown component. Scope is stated at declaration — '
  'everyone, the organisations named, or not yet known — and the first update '
  'is due from the moment of declaration, on the severity''s published cadence '
  'or sooner.';

-- ── The update, in five fields ───────────────────────────────────────────────

drop function if exists erp.post_incident_update(text, text, boolean);

create function erp.post_incident_update(p_code text,
                                         p_body text default null,
                                         p_is_no_change boolean default false,
                                         p_affected text default null,
                                         p_not_affected text default null,
                                         p_being_done text default null,
                                         p_meanwhile text default null,
                                         p_next_update_minutes integer default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff   erp_meta.platform_staff;
  v_inc     erp_meta.incident%rowtype;
  v_sev     erp_ref.support_severity%rowtype;
  v_id      uuid;
  v_minutes integer;
  v_next    timestamptz;
  v_body    text;
begin
  v_staff := erp_meta.require_platform('support');

  select * into v_inc from erp_meta.incident i where i.code = p_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INCIDENT: %', p_code using errcode = '23503';
  end if;

  if v_inc.resolved_at is not null then
    raise exception 'CLOVEERP_INCIDENT_RESOLVED: % was resolved at %',
      p_code, v_inc.resolved_at
      using errcode = '23514',
            hint = 'The record of a resolved incident is what the review reads. '
                   'Adding to it afterwards rewrites what people were told.';
  end if;

  select * into v_sev from erp_ref.support_severity s where s.code = v_inc.severity_code;

  if p_next_update_minutes is not null and (p_next_update_minutes < 1 or p_next_update_minutes > v_sev.update_every_minutes) then
    raise exception 'CLOVEERP_UPDATE_PROMISED_TOO_LATE: % publishes an update every % minutes; % is outside that',
      v_inc.severity_code, v_sev.update_every_minutes, p_next_update_minutes
      using errcode = '23514',
            hint = 'Promise the next update within the severity''s cadence, or leave it to the cadence.';
  end if;
  v_minutes := coalesce(p_next_update_minutes, v_sev.update_every_minutes);
  v_next := now() + make_interval(mins => v_minutes);

  -- The promise is rendered only when a person stated one; the cadence is
  -- published already, and "no change" stays the three words it is.
  v_body := erp.render_incident_update(p_body, p_affected, p_not_affected, p_being_done, p_meanwhile,
                                       case when p_next_update_minutes is not null then v_next end);
  if v_body is null then
    raise exception 'CLOVEERP_UPDATE_SAYS_NOTHING: an update carries a body or at least one of its five fields'
      using errcode = '23514',
            hint = 'Say what is affected, what is not, what is being done, what to do meanwhile, and when the next update comes — or write it in prose.';
  end if;

  -- §17.3's cadence is a promise to keep talking, and "no change" is a real
  -- update — it is the one people stop sending, which is how a channel goes
  -- quiet without anybody deciding to stop.
  insert into erp_meta.incident_update
    (incident_id, body, posted_by, is_no_change, affected, not_affected, being_done, meanwhile, next_update_at)
  values (v_inc.id, v_body, v_staff.email, coalesce(p_is_no_change, false),
          nullif(btrim(p_affected), ''), nullif(btrim(p_not_affected), ''),
          nullif(btrim(p_being_done), ''), nullif(btrim(p_meanwhile), ''), v_next)
  returning id into v_id;

  update erp_meta.incident set next_update_due_at = v_next where id = v_inc.id;

  perform erp_meta.platform_log(
    v_staff, 'platform.incident_updated', null, p_code, left(v_body, 200),
    jsonb_build_object('update_id', v_id, 'is_no_change', coalesce(p_is_no_change, false),
                       'next_update_due_at', v_next));

  return v_id;
end;
$$;

comment on function erp.post_incident_update is
  'Specification v1.6 §16.5, communication on a timer. The five fields are '
  'rendered once into the body; every channel — banner, email, status page, '
  'history — carries that text and no other. Posting resets the timer to the '
  'promised time, within the cadence.';

-- ── Resolution accepts an assembled review, and says goodbye ────────────────

do $$
declare v_src text := pg_get_functiondef('erp.resolve_incident(text, text)'::regprocedure);
begin
  if v_src not like '%if coalesce(v_review, false) and coalesce(btrim(p_review_url), '''') = '''' then%' then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.resolve_incident is not the 20260904380000 body';
  end if;
end $$;

create or replace function erp.resolve_incident(p_code text, p_review_url text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff     erp_meta.platform_staff;
  v_inc       erp_meta.incident%rowtype;
  v_review    boolean;
  v_assembled boolean;
begin
  v_staff := erp_meta.require_platform('operator');

  select * into v_inc from erp_meta.incident i where i.code = p_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INCIDENT: %', p_code using errcode = '23503';
  end if;

  select s.requires_review into v_review
    from erp_ref.support_severity s where s.code = v_inc.severity_code;
  v_assembled := exists (select 1 from erp_meta.incident_review r where r.incident_id = v_inc.id);

  -- §17.3: "A blameless post-incident review is written for every severity 1
  -- and 2." The review is a link to one written elsewhere or the one assembled
  -- here from the updates; either way it exists before the incident closes.
  if coalesce(v_review, false) and coalesce(btrim(p_review_url), '') = '' and not v_assembled then
    raise exception
      'CLOVEERP_REVIEW_REQUIRED: a % incident is resolved with its review, not before it',
      v_inc.severity_code
      using errcode = '23514',
            hint = 'Assemble the review from the updates (erp_platform_assemble_incident_review) '
                   'or give the link to one written elsewhere. It is blameless and it is not optional.';
  end if;

  if v_inc.resolved_at is null then
    -- The last thing the organisations hear is that it is over.
    insert into erp_meta.incident_update (incident_id, body, posted_by, is_no_change)
    values (v_inc.id, format('Resolved: %s. No further updates will be posted.', v_inc.title), v_staff.email, false);
  end if;

  update erp_meta.incident
     set resolved_at = coalesce(resolved_at, now()),
         next_update_due_at = null,
         review_url = coalesce(nullif(btrim(p_review_url), ''), review_url),
         review_completed_at = case
           when coalesce(btrim(p_review_url), '') <> '' or v_assembled then coalesce(review_completed_at, now())
           else review_completed_at end
   where id = v_inc.id;

  perform erp_meta.platform_log(
    v_staff, 'platform.incident_resolved', null, p_code, v_inc.title,
    jsonb_build_object('severity', v_inc.severity_code, 'review', p_review_url, 'review_assembled', v_assembled));
end;
$$;

-- ── Actions and the review ───────────────────────────────────────────────────

create or replace function erp.add_incident_action(p_code text, p_description text, p_owner text, p_due_on date default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
  v_id    uuid;
begin
  v_staff := erp_meta.require_platform('support');
  select * into v_inc from erp_meta.incident i where i.code = p_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INCIDENT: %', p_code using errcode = '23503';
  end if;
  if coalesce(btrim(p_owner), '') = '' or length(coalesce(btrim(p_description), '')) < 10 then
    raise exception 'CLOVEERP_ACTION_UNOWNED: an action says what is to be done and who will do it'
      using errcode = '23514',
            hint = 'Give a description of at least ten characters and name an owner; a due date is what makes it trackable.';
  end if;
  insert into erp_meta.incident_action (incident_id, description, owner, due_on, created_by)
  values (v_inc.id, btrim(p_description), btrim(p_owner), p_due_on, v_staff.email)
  returning id into v_id;
  perform erp_meta.platform_log(v_staff, 'platform.incident_action_added', null, p_code, left(p_description, 200),
                                jsonb_build_object('action_id', v_id, 'owner', p_owner, 'due_on', p_due_on));
  return v_id;
end;
$$;

create or replace function erp.complete_incident_action(p_action_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_code  text;
begin
  v_staff := erp_meta.require_platform('support');
  if length(coalesce(btrim(p_note), '')) < 5 then
    raise exception 'CLOVEERP_ACTION_DONE_SAYS_HOW: completing an action says what was done'
      using errcode = '23514', hint = 'A note of a few words: what changed, where.';
  end if;
  update erp_meta.incident_action a
     set done_at = coalesce(a.done_at, now()), done_note = btrim(p_note)
   where a.id = p_action_id
  returning (select i.code from erp_meta.incident i where i.id = a.incident_id) into v_code;
  if v_code is null then
    raise exception 'CLOVEERP_UNKNOWN_ACTION: %', p_action_id using errcode = '23503';
  end if;
  perform erp_meta.platform_log(v_staff, 'platform.incident_action_done', null, v_code, btrim(p_note),
                                jsonb_build_object('action_id', p_action_id));
end;
$$;

-- Open actions of other incidents that touched the same component: shown at
-- declaration, because the second incident on a component is usually the first
-- one's action that nobody did.
create or replace function erp.similar_incident_actions(p_code text)
returns table(incident_code text, action_id uuid, description text, owner text, due_on date, shared_component text)
language sql
stable
set search_path = ''
as $$
  select i.code, a.id, a.description, a.owner, a.due_on, c.component_code
    from erp_meta.incident me
    join erp_meta.incident_component mc on mc.incident_id = me.id
    join erp_meta.incident_component c on c.component_code = mc.component_code and c.incident_id <> me.id
    join erp_meta.incident i on i.id = c.incident_id
    join erp_meta.incident_action a on a.incident_id = i.id and a.done_at is null
   where me.code = p_code
   order by a.due_on nulls last, i.declared_at desc
$$;
revoke all on function erp.similar_incident_actions(text) from public, anon, authenticated;

create or replace function erp.assemble_incident_review(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
  v_doc   jsonb;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into v_inc from erp_meta.incident i where i.code = p_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INCIDENT: %', p_code using errcode = '23503';
  end if;

  v_doc := jsonb_build_object(
    'code', v_inc.code, 'title', v_inc.title, 'severity_code', v_inc.severity_code,
    'declared_at', v_inc.declared_at, 'contained_at', v_inc.contained_at, 'resolved_at', v_inc.resolved_at,
    'duration_minutes', case when v_inc.resolved_at is not null
                             then (extract(epoch from v_inc.resolved_at - v_inc.declared_at) / 60)::integer end,
    'scope', v_inc.scope, 'affects_all_tenants', v_inc.affects_all_tenants,
    'is_data_integrity', v_inc.is_data_integrity, 'is_security', v_inc.is_security,
    'origin', v_inc.origin_dependency_code,
    'roles', jsonb_build_object('commander', v_inc.commander, 'communications_owner', v_inc.communications_owner, 'scribe', v_inc.scribe),
    'components', coalesce((select jsonb_agg(c.component_code order by c.component_code)
                              from erp_meta.incident_component c where c.incident_id = v_inc.id), '[]'::jsonb),
    'organisations_reached', coalesce((select jsonb_agg(t.tenant_code order by t.tenant_code)
                                         from erp_meta.incident_tenant t where t.incident_id = v_inc.id), '[]'::jsonb),
    'timeline', coalesce((select jsonb_agg(jsonb_build_object(
                                   'posted_at', u.posted_at, 'body', u.body, 'is_no_change', u.is_no_change,
                                   'posted_by', u.posted_by, 'next_update_at', u.next_update_at)
                                 order by u.posted_at)
                            from erp_meta.incident_update u where u.incident_id = v_inc.id), '[]'::jsonb),
    'updates_promised', (select count(*) from erp_meta.incident_update u where u.incident_id = v_inc.id),
    'prompts', coalesce((select jsonb_agg(jsonb_build_object('due_at', p.due_at, 'level', p.level, 'prompted_at', p.prompted_at)
                                          order by p.due_at, p.prompted_at)
                           from erp_meta.incident_prompt p where p.incident_id = v_inc.id), '[]'::jsonb),
    'actions', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'description', a.description, 'owner', a.owner,
                                                             'due_on', a.due_on, 'done_at', a.done_at, 'done_note', a.done_note)
                                          order by a.created_at)
                           from erp_meta.incident_action a where a.incident_id = v_inc.id), '[]'::jsonb),
    'assembled_at', now(), 'assembled_by', v_staff.email);

  insert into erp_meta.incident_review (incident_id, assembled_by, document)
  values (v_inc.id, v_staff.email, v_doc)
  on conflict (incident_id) do update
    set assembled_at = now(), assembled_by = excluded.assembled_by, document = excluded.document;

  update erp_meta.incident set review_completed_at = coalesce(review_completed_at, now()) where id = v_inc.id;

  perform erp_meta.platform_log(v_staff, 'platform.incident_review_assembled', null, p_code, v_inc.title,
                                jsonb_build_object('updates', v_doc -> 'updates_promised', 'actions', jsonb_array_length(v_doc -> 'actions')));
  return v_doc;
end;
$$;

comment on function erp.assemble_incident_review is
  'Specification v1.6 §16.5: the blameless review, assembled from what was '
  'actually said and when — the timeline of updates, the prompts the timer '
  'recorded, the organisations reached and the actions tracked. Stored beside '
  'the incident and shared with the organisations it reached through '
  'erp_incident_history().';

-- ── Subscriptions ────────────────────────────────────────────────────────────

create or replace function erp.set_incident_subscription(p_subscribed boolean)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
begin
  perform erp.authorise('administration.read');
  if v_me is null then
    raise exception 'CLOVEERP_NOT_AUTHENTICATED' using errcode = '42501';
  end if;
  insert into erp.incident_subscription (tenant_id, app_user_id, is_subscribed)
  values (v_tenant, v_me, coalesce(p_subscribed, true))
  on conflict (tenant_id, app_user_id) do update set is_subscribed = excluded.is_subscribed;
  return erp.incident_subscription_state();
end;
$$;

create or replace function erp.incident_recipients(p_tenant_id uuid)
returns setof uuid
language sql
stable
set search_path = ''
as $$
  select u.id
    from erp.app_user u
   where u.tenant_id = p_tenant_id
     and u.status = 'active' and u.kind = 'person'
     and (exists (select 1 from erp.user_role ur
                    join erp.role r on r.id = ur.role_id
                   where ur.tenant_id = p_tenant_id and ur.app_user_id = u.id and r.code = 'administrator'
                     and coalesce(ur.valid_from, current_date) <= current_date
                     and (ur.valid_to is null or ur.valid_to >= current_date))
          or exists (select 1 from erp.incident_subscription s
                      where s.tenant_id = p_tenant_id and s.app_user_id = u.id and s.is_subscribed))
     and not exists (select 1 from erp.incident_subscription s
                      where s.tenant_id = p_tenant_id and s.app_user_id = u.id and not s.is_subscribed)
$$;
revoke all on function erp.incident_recipients(uuid) from public, anon, authenticated;

create or replace function erp.incident_subscription_state()
returns jsonb
language sql
stable
set search_path = ''
as $$
  with me as (select erp.require_tenant_id() as tenant_id, erp.current_principal_id() as user_id)
  select jsonb_build_object(
    'by_default', exists (select 1 from erp.user_role ur join erp.role r on r.id = ur.role_id, me
                           where ur.tenant_id = me.tenant_id and ur.app_user_id = me.user_id and r.code = 'administrator'),
    'chosen', (select s.is_subscribed from erp.incident_subscription s, me
                where s.tenant_id = me.tenant_id and s.app_user_id = me.user_id),
    'subscribed', exists (select 1 from me where me.user_id in (select erp.incident_recipients(me.tenant_id))),
    'recipients', (select count(*) from me, erp.incident_recipients(me.tenant_id)))
$$;
revoke all on function erp.incident_subscription_state() from public, anon, authenticated;

-- ── A provider's outage, recorded and declared ───────────────────────────────

create or replace function erp.record_dependency_status(p_code text, p_indicator text, p_description text default null,
                                                        p_raw jsonb default '{}'::jsonb, p_observed_by text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dep      erp_ref.platform_dependency%rowtype;
  v_sev      erp_ref.support_severity%rowtype;
  v_live     erp_meta.incident%rowtype;
  v_code     text;
  v_id       uuid;
  v_declared boolean := false;
  v_resolved boolean := false;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record a dependency''s status', current_user
      using errcode = '42501', hint = 'The worker records what the provider''s feed says; a person declares an incident through the console.';
  end if;
  select * into v_dep from erp_ref.platform_dependency d where d.code = p_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DEPENDENCY: % is not a registered dependency', p_code
      using errcode = '23503', hint = 'Register the provider in erp_ref.platform_dependency with its status feed.';
  end if;
  if p_indicator not in ('none', 'minor', 'major', 'critical', 'unknown') then
    raise exception 'CLOVEERP_UNKNOWN_INDICATOR: % is not a Statuspage indicator', p_indicator
      using errcode = '22023', hint = 'none, minor, major, critical, or unknown when the feed could not be read.';
  end if;

  insert into erp_meta.dependency_observation (dependency_code, indicator, description, raw, observed_by)
  values (p_code, p_indicator, left(p_description, 500), coalesce(p_raw, '{}'::jsonb), p_observed_by);

  select * into v_live from erp_meta.incident i
   where i.origin_dependency_code = p_code and i.resolved_at is null
   order by i.declared_at desc limit 1;

  if p_indicator in ('major', 'critical') and v_live.id is null then
    select * into v_sev from erp_ref.support_severity s where s.code = 'sev3';
    v_code := 'dep-' || p_code || '-' || to_char(now() at time zone 'UTC', 'YYYYMMDDHH24MI');
    insert into erp_meta.incident
      (code, severity_code, title, commander, communications_owner, scribe, is_data_integrity,
       scope, affects_all_tenants, next_update_due_at, origin_dependency_code, declared_by)
    values (v_code, 'sev3',
            format('Below the platform: %s reports %s', v_dep.provider, coalesce(nullif(btrim(p_description), ''), p_indicator || ' impact')),
            'platform (automatic)', 'platform (automatic)', 'platform (automatic)', false,
            format('%s, per its own status page (%s); the platform is affected where it depends on it', v_dep.provider, v_dep.status_url),
            v_dep.affects_service, now() + make_interval(mins => v_sev.update_every_minutes), p_code, 'dependency feed')
    returning id into v_id;
    insert into erp_meta.incident_component (incident_id, component_code)
    select v_id, c from unnest(v_dep.component_codes) c on conflict do nothing;
    insert into erp_meta.platform_audit (actor_email, actor_role, action, target, reason, detail)
    values ('system', 'platform', 'platform.incident_declared', v_code,
            format('%s reports %s', v_dep.provider, p_indicator),
            jsonb_build_object('severity', 'sev3', 'origin', p_code, 'affects_all_tenants', v_dep.affects_service,
                               'components', to_jsonb(v_dep.component_codes)));
    v_declared := true;
  elsif p_indicator = 'none' and v_live.id is not null then
    insert into erp_meta.incident_update (incident_id, body, posted_by, is_no_change)
    values (v_live.id, format('%s reports recovery on its status page. Resolved: %s.', v_dep.provider, v_live.title), 'dependency feed', false);
    update erp_meta.incident set resolved_at = now(), next_update_due_at = null where id = v_live.id;
    insert into erp_meta.platform_audit (actor_email, actor_role, action, target, reason, detail)
    values ('system', 'platform', 'platform.incident_resolved', v_live.code, format('%s reports recovery', v_dep.provider),
            jsonb_build_object('severity', v_live.severity_code, 'origin', p_code));
    v_resolved := true;
  end if;

  return jsonb_build_object('dependency', p_code, 'indicator', p_indicator,
                            'declared', case when v_declared then v_code end, 'resolved', case when v_resolved then v_live.code end);
end;
$$;

comment on function erp.record_dependency_status is
  'Specification v1.6 §16.5: an outage below the platform is the platform''s '
  'incident to communicate. A major or critical indicator on a provider''s '
  'feed declares a severity-3 incident with the origin, the components the '
  'provider carries and the scope the dependency row states; recovery on the '
  'feed posts the closing update and resolves it. Trusted sessions only — the '
  'worker''s job handler.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The timer and the delivery, in the platform sweep
-- ═════════════════════════════════════════════════════════════════════════════

-- The status page payload: one shape for every publisher.
create or replace function erp.status_payload(p_incident_id uuid, p_update_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'incident_code', i.code,
    'title', i.title,
    'severity', i.severity_code,
    'state', case when i.resolved_at is not null then 'resolved'
                  when i.contained_at is not null then 'contained' else 'live' end,
    'declared_at', i.declared_at,
    'contained_at', i.contained_at,
    'resolved_at', i.resolved_at,
    'scope', i.scope,
    'affects_everyone', coalesce(i.affects_all_tenants, false),
    'origin', i.origin_dependency_code,
    'components', coalesce((select jsonb_agg(c.component_code order by c.component_code)
                              from erp_meta.incident_component c where c.incident_id = i.id), '[]'::jsonb),
    'update_id', u.id,
    'posted_at', coalesce(u.posted_at, i.declared_at),
    'body', coalesce(u.body, format('Incident declared: %s.', i.title)),
    'is_no_change', coalesce(u.is_no_change, false),
    'affected', u.affected, 'not_affected', u.not_affected, 'being_done', u.being_done, 'meanwhile', u.meanwhile,
    'next_update_at', coalesce(u.next_update_at, i.next_update_due_at)))
    from erp_meta.incident i
    left join erp_meta.incident_update u on u.id = p_update_id and u.incident_id = i.id
   where i.id = p_incident_id
$$;
revoke all on function erp.status_payload(uuid, uuid) from public, anon, authenticated;

create or replace function erp.prompt_incident_updates()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r         record;
  v_level   text;
  v_levels  text[];
  v_named   text;
  v_n       integer := 0;
  v_told    integer := 0;
  v_plat    uuid;
  v_user    uuid;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not run the incident timer', current_user
      using errcode = '42501', hint = 'The platform sweep runs this; the console shows what it recorded.';
  end if;
  select po.tenant_id into v_plat from erp_meta.platform_organisation po;

  for r in
    select i.*, s.response_within_minutes as window_minutes
      from erp_meta.incident i
      join erp_ref.support_severity s on s.code = i.severity_code
     where i.resolved_at is null and i.next_update_due_at is not null and i.next_update_due_at < now()
  loop
    -- Due: the communications owner. Past the response window: the commander.
    -- Past two: the owner role. Each level once per due time.
    v_levels := array['communications_owner'];
    if now() > r.next_update_due_at + make_interval(mins => r.window_minutes) then
      v_levels := array_append(v_levels, 'commander');
    end if;
    if now() > r.next_update_due_at + make_interval(mins => 2 * r.window_minutes) then
      v_levels := array_append(v_levels, 'owner');
    end if;
    foreach v_level in array v_levels loop
      v_named := case v_level when 'communications_owner' then r.communications_owner
                              when 'commander' then r.commander
                              else 'platform owner' end;
      insert into erp_meta.incident_prompt (incident_id, due_at, level, named)
      values (r.id, r.next_update_due_at, v_level, v_named)
      on conflict (incident_id, due_at, level) do nothing;
      if not found then continue; end if;
      v_n := v_n + 1;

      insert into erp_meta.platform_audit (actor_email, actor_role, action, target, reason, detail)
      values ('system', 'platform',
              case v_level when 'communications_owner' then 'platform.incident_update_due' else 'platform.incident_update_escalated' end,
              r.code, format('an update was due at %s; %s is %s', to_char(r.next_update_due_at at time zone 'UTC', 'HH24:MI'), v_level, v_named),
              jsonb_build_object('due_at', r.next_update_due_at, 'level', v_level, 'severity', r.severity_code));

      -- The named person is told in the platform's own organisation, when there
      -- is one and they are a person in it. Otherwise the console shows it.
      v_user := null;
      if v_plat is not null then
        select u.id into v_user from erp.app_user u
         where u.tenant_id = v_plat and u.status = 'active' and u.kind = 'person'
           and (lower(u.email) = lower(v_named) or lower(u.display_name) = lower(v_named)
                or (v_level = 'owner' and exists (select 1 from erp_meta.platform_staff ps
                                                   where ps.staff_role = 'owner' and ps.revoked_at is null and lower(ps.email) = lower(u.email))))
         order by u.created_at limit 1;
      end if;
      if v_user is not null then
        insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, delivered_at)
        values (v_plat, (case when r.severity_code in ('sev1', 'sev2') then 'high' else 'medium' end)::erp.notification_severity, v_user, 'in_app',
                format('[%s] %s: an update is due', upper(r.severity_code), r.title),
                format('The update promised for %s UTC has not been posted. %s is %s. Post an update, even that nothing has changed.',
                       to_char(r.next_update_due_at at time zone 'UTC', 'HH24:MI'), initcap(replace(v_level, '_', ' ')), v_named),
                'delivered', now(), now());
        insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
        select v_plat, (case when r.severity_code in ('sev1', 'sev2') then 'high' else 'medium' end)::erp.notification_severity, v_user, 'email',
               format('[%s] %s: an update is due', upper(r.severity_code), r.title),
               format('The update promised for %s UTC has not been posted. %s is %s. Post an update, even that nothing has changed.',
                      to_char(r.next_update_due_at at time zone 'UTC', 'HH24:MI'), initcap(replace(v_level, '_', ' ')), v_named),
               'queued'
         where exists (select 1 from erp.app_user u where u.id = v_user and u.email is not null);
        update erp_meta.incident_prompt p set notified = 1
         where p.incident_id = r.id and p.due_at = r.next_update_due_at and p.level = v_level;
        v_told := v_told + 1;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('prompts', v_n, 'notified', v_told);
end;
$$;

comment on function erp.prompt_incident_updates is
  'Specification v1.6 §16.5: communication is on a timer, not on progress. '
  'Runs in the platform sweep; records who was prompted for an update that '
  'fell due and escalates through the roles the declaration named, with an '
  'audit row each time. Nothing here posts an update — a person does that.';

-- One organisation, every update it has not yet been given. Runs under that
-- organisation's job context, so the notification rows carry its tenant and
-- its audit stream records them.
create or replace function erp.communicate_incidents()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant   uuid;
  v_plat     boolean;
  r          record;
  s          record;
  u          uuid;
  v_subject  text;
  v_body     text;
  v_sevn     erp.notification_severity;
  v_n        integer;
  v_deliv    integer := 0;
  v_notified integer := 0;
  v_pub      integer := 0;
  v_op       erp_ref.adapter_operation%rowtype;
  v_payload  jsonb;
  v_key      text;
  v_cmd      uuid;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not deliver incident notices', current_user
      using errcode = '42501', hint = 'The platform sweep runs this per organisation.';
  end if;
  v_tenant := erp.require_tenant_id();
  v_plat := erp.is_platform_organisation(v_tenant);

  -- Declarations and updates this organisation has been reached by and not told.
  for r in
    with mine as (
      select i.* from erp_meta.incident i
       where exists (select 1 from erp_meta.incident_tenant t where t.incident_id = i.id and t.tenant_id = v_tenant)
          or coalesce(i.affects_all_tenants, false))
    select m.id as incident_id, null::uuid as update_id, m.code, m.title, m.severity_code, m.declared_at as at,
           format('Incident declared %s UTC. Severity %s. %s%s',
                  to_char(m.declared_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), m.severity_code,
                  coalesce(m.scope, 'Scope is being established.'),
                  coalesce(' Components: ' || (select string_agg(c.component_code, ', ' order by c.component_code)
                                                from erp_meta.incident_component c where c.incident_id = m.id) || '.', '')) as body,
           false as is_update
      from mine m
     where not exists (select 1 from erp_meta.incident_delivery d
                        where d.tenant_id = v_tenant and d.incident_id = m.id and d.incident_update_id is null)
    union all
    select m.id, up.id, m.code, m.title, m.severity_code, up.posted_at, up.body, true
      from mine m
      join erp_meta.incident_update up on up.incident_id = m.id
     where not exists (select 1 from erp_meta.incident_delivery d
                        where d.tenant_id = v_tenant and d.incident_id = m.id and d.incident_update_id = up.id)
     order by 6
  loop
    v_subject := format('[%s] %s%s', upper(r.severity_code), r.title, case when r.is_update then ' — update' else '' end);
    v_body := r.body;
    v_sevn := case when r.severity_code in ('sev1', 'sev2') then 'high' else 'medium' end;
    v_n := 0;
    for u in select * from erp.incident_recipients(v_tenant) loop
      insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, sent_at, delivered_at)
      values (v_tenant, v_sevn, u, 'in_app', v_subject, v_body, 'delivered', now(), now());
      insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
      select v_tenant, v_sevn, u, 'email', v_subject, v_body, 'queued'
       where exists (select 1 from erp.app_user au where au.id = u and au.email is not null);
      v_n := v_n + 1;
    end loop;
    insert into erp_meta.incident_delivery (incident_id, incident_update_id, tenant_id, recipients, subject)
    values (r.incident_id, r.update_id, v_tenant, v_n, v_subject);
    v_deliv := v_deliv + 1;
    v_notified := v_notified + v_n;
  end loop;

  -- The platform's own organisation publishes every incident, whoever it
  -- reached, to every status page it has registered.
  if v_plat then
    select * into v_op from erp_ref.adapter_operation o where o.adapter_code = 'status_page' and o.adapter_version = 1 and o.code = 'status.publish';
    for s in
      select es.* from erp.external_system es
       where es.tenant_id = v_tenant and es.adapter_code = 'status_page' and es.status = 'active'
         and exists (select 1 from erp.external_system_operation eo
                      where eo.tenant_id = v_tenant and eo.external_system_id = es.id
                        and eo.operation_code = 'status.publish' and eo.is_enabled)
    loop
      for r in
        select i.id as incident_id, null::uuid as update_id, i.code, i.declared_at as at
          from erp_meta.incident i
         where not exists (select 1 from erp_meta.incident_publication p
                            where p.external_system_id = s.id and p.incident_id = i.id and p.incident_update_id is null)
        union all
        select i.id, up.id, i.code, up.posted_at
          from erp_meta.incident i join erp_meta.incident_update up on up.incident_id = i.id
         where not exists (select 1 from erp_meta.incident_publication p
                            where p.external_system_id = s.id and p.incident_id = i.id and p.incident_update_id = up.id)
         order by 4
      loop
        v_payload := erp.status_payload(r.incident_id, r.update_id);
        if not erp.jsonb_matches_schema(v_op.request_schema::json, v_payload) then
          raise exception 'CLOVEERP_INVALID_COMMAND_PAYLOAD: the status payload for % does not match status.publish', r.code
            using errcode = '22023';
        end if;
        v_key := 'status-' || r.code || '-' || coalesce(r.update_id::text, 'declared');
        select c.id into v_cmd from erp.command c
         where c.tenant_id = v_tenant and c.external_system_id = s.id and c.idempotency_key = v_key;
        if v_cmd is null then
          -- The gateway's own path, without the principal submit_command
          -- authorises as: drafted, approved, released. The transition trigger
          -- checks each step; the payload was validated above.
          insert into erp.command (tenant_id, external_system_id, operation_code, payload, idempotency_key,
                                   ordering_key, dry_run, source_object_type, source_object_id, max_attempts, next_attempt_at)
          values (v_tenant, s.id, 'status.publish', v_payload, v_key, r.code, false, 'incident', r.incident_id, s.max_attempts, now())
          returning id into v_cmd;
          update erp.command set status = 'approved' where id = v_cmd;
          perform erp.release_command(v_cmd);
        end if;
        insert into erp_meta.incident_publication (incident_id, incident_update_id, external_system_id, command_id)
        values (r.incident_id, r.update_id, s.id, v_cmd);
        v_pub := v_pub + 1;
      end loop;
    end loop;
  end if;

  return jsonb_build_object('deliveries', v_deliv, 'notified', v_notified, 'published', v_pub);
end;
$$;

comment on function erp.communicate_incidents is
  'Specification v1.6 §16.5, one update on every channel. For the organisation '
  'the sweep is running as: every declaration and update that reached it and '
  'has not been delivered becomes one in-app row and one queued email per '
  'recipient, with the body the update was posted with. For the platform''s '
  'own organisation: every declaration and update becomes a status.publish '
  'command to each active status page system, through the gateway.';

-- ── The sweep runs both ──────────────────────────────────────────────────────

do $$
declare
  v_src text := pg_get_functiondef('erp.run_due_jobs_all_tenants(integer)'::regprocedure);
  v_new text;
begin
  if v_src not like '%  v_recl    jsonb;%'
     or v_src not like '%      v_recl := erp.reclaim_stranded_work();%'
     or v_src not like '%  for t in select tn.id, tn.code from erp.tenant tn where tn.status = ''active'' order by tn.code loop%'
     or v_src not like '%''reclaimed'', v_recl));%' then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_due_jobs_all_tenants is not the 20260906112000 body';
  end if;
  v_new := replace(v_src, '  v_recl    jsonb;',
                          E'  v_recl    jsonb;\n  v_comm    jsonb;\n  v_prompt  jsonb;');
  v_new := replace(v_new, '  for t in select tn.id, tn.code from erp.tenant tn where tn.status = ''active'' order by tn.code loop',
    E'  -- The incident timer first: an update that fell due is recorded before\n'
    '  -- any organisation is told anything.\n'
    '  begin\n'
    '    v_prompt := erp.prompt_incident_updates();\n'
    '  exception when others then\n'
    '    v_prompt := jsonb_build_object(''error'', left(sqlerrm, 200));\n'
    '  end;\n\n'
    '  for t in select tn.id, tn.code from erp.tenant tn where tn.status = ''active'' order by tn.code loop');
  v_new := replace(v_new, '      v_recl := erp.reclaim_stranded_work();',
    E'      v_recl := erp.reclaim_stranded_work();\n'
    '      -- Then what this organisation has not yet been told.\n'
    '      v_comm := erp.communicate_incidents();');
  v_new := replace(v_new, '''reclaimed'', v_recl));',
                          '''reclaimed'', v_recl, ''incidents'', v_comm));');
  v_new := replace(v_new, '''failed'', v_failed, ''detail'', v_out);',
                          '''failed'', v_failed, ''incident_timer'', v_prompt, ''detail'', v_out);');
  execute v_new;
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Readers
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.service_notices()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select erp.require_tenant_id() as tenant_id),
  windows as (
    select w.*
      from erp_meta.maintenance_window w, me
     where w.cancelled_at is null
       and w.ends_at >= now() - interval '30 days'
       and (w.affects_all_tenants
            or exists (select 1 from erp_meta.maintenance_window_tenant t
                        where t.window_id = w.id and t.tenant_id = me.tenant_id))),
  incidents as (
    -- Named as affected: told from the moment the platform names it. Declared
    -- or contained as reaching everyone: told from that moment, not only once
    -- containment repeated it.
    select i.*
      from erp_meta.incident i, me
     where (i.resolved_at is null or i.resolved_at >= now() - interval '30 days')
       and (exists (select 1 from erp_meta.incident_tenant t
                     where t.incident_id = i.id and t.tenant_id = me.tenant_id)
            or coalesce(i.affects_all_tenants, false)))
  select jsonb_build_object(
    'maintenance', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', w.code, 'title', w.title, 'detail', w.detail,
               'starts_at', w.starts_at, 'ends_at', w.ends_at,
               'announced_at', w.announced_at, 'is_emergency', w.is_emergency,
               'emergency_reason', w.emergency_reason,
               'state', case when w.ends_at < now() then 'past'
                             when w.starts_at <= now() then 'in_progress'
                             else 'planned' end)
             order by w.starts_at desc)
        from windows w), '[]'::jsonb),
    'incidents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', i.code, 'title', i.title, 'severity_code', i.severity_code,
               'state', case when i.resolved_at is not null then 'resolved'
                             when i.contained_at is not null then 'contained'
                             else 'live' end,
               'declared_at', i.declared_at, 'contained_at', i.contained_at,
               'resolved_at', i.resolved_at, 'scope', i.scope,
               'is_data_integrity', i.is_data_integrity, 'is_security', i.is_security,
               'affects_all_tenants', coalesce(i.affects_all_tenants, false),
               'next_update_due_at', i.next_update_due_at,
               'origin', (select erp.text(d.name_key) from erp_ref.platform_dependency d where d.code = i.origin_dependency_code),
               'components', coalesce((
                 select jsonb_agg(jsonb_build_object('code', c.component_code, 'name', erp.text(pc.name_key)) order by pc.seq)
                   from erp_meta.incident_component c
                   join erp_ref.platform_component pc on pc.code = c.component_code
                  where c.incident_id = i.id), '[]'::jsonb),
               'updates', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', u.id, 'posted_at', u.posted_at, 'body', u.body,
                          'is_no_change', u.is_no_change,
                          'affected', u.affected, 'not_affected', u.not_affected,
                          'being_done', u.being_done, 'meanwhile', u.meanwhile,
                          'next_update_at', u.next_update_at)
                        order by u.posted_at desc)
                   from erp_meta.incident_update u where u.incident_id = i.id), '[]'::jsonb),
               'obligations', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'obligation_code', n.code, 'title', n.title,
                          'obliged_party', n.obliged_party, 'basis', n.basis,
                          'due_at', d.due_at, 'notified_at', d.notified_at,
                          'overdue', d.notified_at is null and d.due_at < now())
                        order by n.seq)
                   from erp_meta.incident_disclosure d
                   join erp_ref.notice_period n on n.code = d.obligation_code
                  where d.incident_id = i.id), '[]'::jsonb))
             order by i.declared_at desc)
        from incidents i), '[]'::jsonb),
    'notice_periods', (
      select jsonb_agg(jsonb_build_object('code', n.code, 'title', n.title, 'hours', n.hours,
                                          'obliged_party', n.obliged_party, 'basis', n.basis)
                       order by n.seq)
        from erp_ref.notice_period n))
$$;

-- Every incident that ever reached this organisation, for as long as the
-- register holds it. D36.
create or replace function erp.incident_history()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select erp.require_tenant_id() as tenant_id),
  mine as (
    select i.*
      from erp_meta.incident i, me
     where exists (select 1 from erp_meta.incident_tenant t where t.incident_id = i.id and t.tenant_id = me.tenant_id)
        or coalesce(i.affects_all_tenants, false))
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', i.code, 'title', i.title, 'severity_code', i.severity_code,
           'state', case when i.resolved_at is not null then 'resolved'
                         when i.contained_at is not null then 'contained' else 'live' end,
           'declared_at', i.declared_at, 'contained_at', i.contained_at, 'resolved_at', i.resolved_at,
           'duration_minutes', case when i.resolved_at is not null
                                    then (extract(epoch from i.resolved_at - i.declared_at) / 60)::integer end,
           'scope', i.scope, 'affects_all_tenants', coalesce(i.affects_all_tenants, false),
           'is_data_integrity', i.is_data_integrity, 'is_security', i.is_security,
           'origin', (select erp.text(d.name_key) from erp_ref.platform_dependency d where d.code = i.origin_dependency_code),
           'components', coalesce((
             select jsonb_agg(erp.text(pc.name_key) order by pc.seq)
               from erp_meta.incident_component c join erp_ref.platform_component pc on pc.code = c.component_code
              where c.incident_id = i.id), '[]'::jsonb),
           'updates', coalesce((
             select jsonb_agg(jsonb_build_object('posted_at', u.posted_at, 'body', u.body, 'is_no_change', u.is_no_change)
                              order by u.posted_at)
               from erp_meta.incident_update u where u.incident_id = i.id), '[]'::jsonb),
           'told_at', (select min(d.delivered_at) from erp_meta.incident_delivery d, me
                        where d.incident_id = i.id and d.tenant_id = me.tenant_id),
           'review', (select case when r.is_shared then
                                jsonb_build_object('assembled_at', r.assembled_at,
                                                   'duration_minutes', r.document -> 'duration_minutes',
                                                   'updates', r.document -> 'updates_promised',
                                                   'timeline', r.document -> 'timeline',
                                                   'actions', (select coalesce(jsonb_agg(jsonb_build_object(
                                                                          'description', a ->> 'description',
                                                                          'done', (a ->> 'done_at') is not null)), '[]'::jsonb)
                                                                 from jsonb_array_elements(r.document -> 'actions') a))
                             end
                        from erp_meta.incident_review r where r.incident_id = i.id))
         order by i.declared_at desc), '[]'::jsonb)
    from mine i
$$;

comment on function erp.incident_history is
  'Specification v1.6 §16.5, D36: an organisation can read every incident that '
  'reached it, with the timeline it was given and the review the platform '
  'shared, for as long as the register holds it. Scoped by construction: '
  'named, or declared as reaching everyone.';

-- The console's view, with what the timer recorded.
drop function if exists erp.incident_report();
create function erp.incident_report()
returns table(code text, severity_code text, title text, state text,
              declared_at timestamptz, contained_at timestamptz, resolved_at timestamptz,
              commander text, communications_owner text, scribe text,
              scope text, affects_all_tenants boolean, is_data_integrity boolean, review_url text,
              updates integer, last_update_at timestamptz, minutes_since_update integer,
              cadence_minutes integer, overdue boolean,
              next_update_due_at timestamptz, timer_state text, components text[],
              organisations integer, origin_dependency_code text, review_assembled boolean,
              open_actions integer, deliveries integer, publications integer)
language sql
stable
set search_path = ''
as $$
  select i.code, i.severity_code, i.title,
         case when i.resolved_at is not null then 'resolved'
              when i.contained_at is not null then 'contained'
              else 'live' end,
         i.declared_at, i.contained_at, i.resolved_at,
         i.commander, i.communications_owner, i.scribe,
         i.scope, i.affects_all_tenants, i.is_data_integrity, i.review_url,
         (select count(*)::integer from erp_meta.incident_update u
           where u.incident_id = i.id),
         u.last_at,
         (extract(epoch from now() - coalesce(u.last_at, i.declared_at)) / 60)::integer,
         s.update_every_minutes,
         i.resolved_at is null
           and now() - coalesce(u.last_at, i.declared_at)
               > make_interval(mins => s.update_every_minutes),
         i.next_update_due_at,
         case when i.resolved_at is not null then 'closed'
              when i.next_update_due_at is null then 'none'
              when i.next_update_due_at >= now() then 'kept'
              else coalesce((select case p.level when 'owner' then 'escalated_owner'
                                                 when 'commander' then 'escalated_commander'
                                                 else 'prompted' end
                               from erp_meta.incident_prompt p
                              where p.incident_id = i.id and p.due_at = i.next_update_due_at
                              order by case p.level when 'owner' then 3 when 'commander' then 2 else 1 end desc
                              limit 1), 'due') end,
         coalesce((select array_agg(c.component_code order by c.component_code)
                     from erp_meta.incident_component c where c.incident_id = i.id), '{}'::text[]),
         (select count(*)::integer from erp_meta.incident_tenant t where t.incident_id = i.id),
         i.origin_dependency_code,
         exists (select 1 from erp_meta.incident_review r where r.incident_id = i.id),
         (select count(*)::integer from erp_meta.incident_action a where a.incident_id = i.id and a.done_at is null),
         (select count(*)::integer from erp_meta.incident_delivery d where d.incident_id = i.id),
         (select count(*)::integer from erp_meta.incident_publication p where p.incident_id = i.id)
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
    left join lateral (
      select max(u.posted_at) as last_at from erp_meta.incident_update u
       where u.incident_id = i.id) u on true
   order by i.declared_at desc
$$;
revoke all on function erp.incident_report() from public, anon, authenticated;

-- What was said to whom, and where it went.
create or replace function erp.incident_communication_report(p_code text default null)
returns table(incident_code text, kind text, at timestamptz, reference text, detail text)
language sql
stable
security definer
set search_path = ''
as $$
  select i.code, 'delivery', d.delivered_at, d.tenant_id::text,
         format('%s recipient(s): %s', d.recipients, d.subject)
    from erp_meta.incident_delivery d join erp_meta.incident i on i.id = d.incident_id
   where p_code is null or i.code = p_code
  union all
  select i.code, 'publication', p.published_at, p.command_id::text,
         format('%s to %s (%s)', case when p.incident_update_id is null then 'declaration' else 'update' end,
                coalesce((select es.code from erp.external_system es where es.id = p.external_system_id), p.external_system_id::text),
                coalesce((select c.status::text from erp.command c where c.id = p.command_id), 'gone'))
    from erp_meta.incident_publication p join erp_meta.incident i on i.id = p.incident_id
   where p_code is null or i.code = p_code
  union all
  select i.code, 'prompt', pr.prompted_at, pr.level,
         format('update due %s UTC; %s%s', to_char(pr.due_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'),
                coalesce(pr.named, '?'), case when pr.notified > 0 then ', notified' else '' end)
    from erp_meta.incident_prompt pr join erp_meta.incident i on i.id = pr.incident_id
   where p_code is null or i.code = p_code
  union all
  select i.code, 'action', a.created_at, a.id::text,
         format('%s — %s%s', a.owner, a.description,
                case when a.done_at is not null then ' (done: ' || a.done_note || ')'
                     when a.due_on is not null then ' (due ' || a.due_on || ')' else '' end)
    from erp_meta.incident_action a join erp_meta.incident i on i.id = a.incident_id
   where p_code is null or i.code = p_code
   order by 1, 3
$$;
revoke all on function erp.incident_communication_report(text) from public, anon, authenticated;

create or replace function erp.dependency_report()
returns table(code text, provider text, status_url text, affects_service boolean, components text[],
              last_observed_at timestamptz, indicator text, description text,
              live_incident_code text, observations_24h integer)
language sql
stable
security definer
set search_path = ''
as $$
  select d.code, d.provider, d.status_url, d.affects_service, d.component_codes,
         o.observed_at, o.indicator, o.description,
         (select i.code from erp_meta.incident i where i.origin_dependency_code = d.code and i.resolved_at is null
           order by i.declared_at desc limit 1),
         (select count(*)::integer from erp_meta.dependency_observation x
           where x.dependency_code = d.code and x.observed_at > now() - interval '24 hours')
    from erp_ref.platform_dependency d
    left join lateral (select * from erp_meta.dependency_observation x
                        where x.dependency_code = d.code order by x.observed_at desc limit 1) o on true
   order by d.seq
$$;
revoke all on function erp.dependency_report() from public, anon, authenticated;

-- ── Doors ────────────────────────────────────────────────────────────────────

drop function if exists public.erp_platform_declare_incident(text, text, text, text, text, text, boolean, text, boolean);
create function public.erp_platform_declare_incident(p_code text, p_severity_code text, p_title text,
                                                     p_commander text, p_communications_owner text, p_scribe text,
                                                     p_is_data_integrity boolean default false,
                                                     p_scope text default null,
                                                     p_affects_all_tenants boolean default null,
                                                     p_components text[] default null,
                                                     p_tenant_codes text[] default null,
                                                     p_next_update_minutes integer default null)
returns uuid
language sql
set search_path = ''
as $$
  select erp.declare_incident(p_code, p_severity_code, p_title, p_commander,
                              p_communications_owner, p_scribe,
                              p_is_data_integrity, p_scope, p_affects_all_tenants,
                              p_components, p_tenant_codes, p_next_update_minutes);
$$;

drop function if exists public.erp_platform_post_incident_update(text, text, boolean);
create function public.erp_platform_post_incident_update(p_code text, p_body text default null,
                                                         p_is_no_change boolean default false,
                                                         p_affected text default null,
                                                         p_not_affected text default null,
                                                         p_being_done text default null,
                                                         p_meanwhile text default null,
                                                         p_next_update_minutes integer default null)
returns uuid
language sql
set search_path = ''
as $$
  select erp.post_incident_update(p_code, p_body, p_is_no_change, p_affected, p_not_affected,
                                  p_being_done, p_meanwhile, p_next_update_minutes);
$$;

create or replace function public.erp_platform_add_incident_action(p_code text, p_description text, p_owner text, p_due_on date default null)
returns uuid language sql set search_path = '' as $$
  select erp.add_incident_action(p_code, p_description, p_owner, p_due_on);
$$;

create or replace function public.erp_platform_complete_incident_action(p_action_id uuid, p_note text)
returns void language sql set search_path = '' as $$
  select erp.complete_incident_action(p_action_id, p_note);
$$;

create or replace function public.erp_platform_assemble_incident_review(p_code text)
returns jsonb language sql set search_path = '' as $$
  select erp.assemble_incident_review(p_code);
$$;

create or replace function public.erp_platform_incident_communication(p_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.at)
                     from erp.incident_communication_report(p_code) r), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_incident_actions(p_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((select jsonb_agg(jsonb_build_object(
                            'id', a.id, 'incident_code', i.code, 'description', a.description, 'owner', a.owner,
                            'due_on', a.due_on, 'done_at', a.done_at, 'done_note', a.done_note, 'created_at', a.created_at)
                          order by a.done_at nulls first, a.due_on nulls last, a.created_at)
                     from erp_meta.incident_action a join erp_meta.incident i on i.id = a.incident_id
                    where p_code is null or i.code = p_code), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_similar_incident_actions(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((select jsonb_agg(to_jsonb(r)) from erp.similar_incident_actions(p_code) r), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_dependencies()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((select jsonb_agg(to_jsonb(r)) from erp.dependency_report() r), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_components()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', erp.text(c.name_key), 'description', c.description) order by c.seq), '[]'::jsonb)
    from erp_ref.platform_component c
$$;

create or replace function public.erp_incident_history()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select erp.incident_history();
$$;

create or replace function public.erp_incident_subscription()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select erp.incident_subscription_state();
$$;

create or replace function public.erp_set_incident_subscription(p_subscribed boolean default true)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.set_incident_subscription(p_subscribed);
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_platform_declare_incident(text, text, text, text, text, text, boolean, text, boolean, text[], text[], integer)',
    'erp_platform_post_incident_update(text, text, boolean, text, text, text, text, integer)',
    'erp_platform_add_incident_action(text, text, text, date)',
    'erp_platform_complete_incident_action(uuid, text)',
    'erp_platform_assemble_incident_review(text)',
    'erp_platform_incident_communication(text)',
    'erp_platform_incident_actions(text)',
    'erp_platform_similar_incident_actions(text)',
    'erp_platform_dependencies()',
    'erp_platform_components()',
    'erp_incident_history()',
    'erp_incident_subscription()',
    'erp_set_incident_subscription(boolean)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_declare_incident', 'erp.declare_incident',
   'Declares an incident with scope and components; erp.declare_incident requires the operator role.'),
  ('erp_platform_post_incident_update', 'erp.post_incident_update',
   'Posts the five-field update every channel carries; erp.post_incident_update requires the support role.'),
  ('erp_platform_add_incident_action', 'erp.add_incident_action',
   'Tracks a review action with an owner and a due date; requires the support role.'),
  ('erp_platform_complete_incident_action', 'erp.complete_incident_action',
   'Closes a review action with a note saying what was done; requires the support role.'),
  ('erp_platform_assemble_incident_review', 'erp.assemble_incident_review',
   'Assembles the blameless review from the updates, prompts and actions; requires the operator role.'),
  ('erp_platform_incident_communication', 'erp_meta.require_platform',
   'Reads what was delivered, published and prompted per incident; platform support and above.'),
  ('erp_platform_incident_actions', 'erp_meta.require_platform',
   'Reads the actions tracked against incidents; platform support and above.'),
  ('erp_platform_similar_incident_actions', 'erp_meta.require_platform',
   'Reads the open actions of other incidents on the same components; platform support and above.'),
  ('erp_platform_dependencies', 'erp_meta.require_platform',
   'Reads the providers below the platform and what their feeds last said; platform support and above.'),
  ('erp_set_incident_subscription', 'erp.set_incident_subscription',
   'A person subscribes to or steps out of incident notices for their own organisation; gated on administration.read.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'declare_incident', 'Writes erp_meta.incident, which is platform-internal; gated by erp_meta.require_platform(operator).'),
  ('erp', 'post_incident_update', 'Writes erp_meta.incident_update; gated by erp_meta.require_platform(support).'),
  ('erp', 'resolve_incident', 'Writes erp_meta.incident; gated by erp_meta.require_platform(operator).'),
  ('erp', 'add_incident_action', 'Writes erp_meta.incident_action; gated by erp_meta.require_platform(support).'),
  ('erp', 'complete_incident_action', 'Writes erp_meta.incident_action; gated by erp_meta.require_platform(support).'),
  ('erp', 'assemble_incident_review', 'Writes erp_meta.incident_review; gated by erp_meta.require_platform(operator).'),
  ('erp', 'record_dependency_status', 'Writes erp_meta.dependency_observation and declares incidents; trusted sessions only, checked in the body.'),
  ('erp', 'prompt_incident_updates', 'Reads platform-internal incidents and writes prompts and audit rows; trusted sessions only, checked in the body.'),
  ('erp', 'communicate_incidents', 'Reads platform-internal incidents and writes delivery, publication and notification rows; trusted sessions only, checked in the body.'),
  ('erp', 'service_notices', 'Reads platform-internal notices scoped to the caller''s organisation by construction.'),
  ('erp', 'incident_history', 'Reads platform-internal incidents scoped to the caller''s organisation by construction.'),
  ('erp', 'incident_communication_report', 'Reads platform-internal delivery evidence; reached only through a require_platform door.'),
  ('erp', 'dependency_report', 'Reads platform-internal observations; reached only through a require_platform door.'),
  ('public', 'erp_platform_incident_communication', 'Platform console read; erp_meta.require_platform(support) on line one.'),
  ('public', 'erp_platform_incident_actions', 'Platform console read; erp_meta.require_platform(support) on line one.'),
  ('public', 'erp_platform_similar_incident_actions', 'Platform console read; erp_meta.require_platform(support) on line one.'),
  ('public', 'erp_platform_dependencies', 'Platform console read; erp_meta.require_platform(support) on line one.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The status page is an external system
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.adapter (code, version, name_key, description, direction, transport, connection_schema,
                             credential_contract, honours_idempotency, supports_dry_run, is_current) values
  ('status_page', 1, 'adapter.status_page',
   'A status page or any endpoint that accepts one JSON document per incident update: the Cloudflare Worker in infra/status/, or an incoming chat webhook that takes a text field. Every update is one POST to base_url with the idempotency key, so a retry cannot publish twice.',
   'outbound', 'http',
   '{"type":"object","required":["base_url"],"properties":{"base_url":{"type":"string","format":"uri"},"timeout_ms":{"type":"integer","minimum":100}},"additionalProperties":false}'::jsonb,
   '{"kind":"bearer_token","note":"Resolved by the dispatch worker from credential_ref at send time and sent as Authorization: Bearer.","fields":["token"]}'::jsonb,
   true, true, true)
on conflict (code, version) do update
  set name_key = excluded.name_key, description = excluded.description, direction = excluded.direction,
      transport = excluded.transport, connection_schema = excluded.connection_schema,
      credential_contract = excluded.credential_contract, honours_idempotency = excluded.honours_idempotency,
      supports_dry_run = excluded.supports_dry_run, is_current = excluded.is_current;

insert into erp_ref.adapter_operation (adapter_code, adapter_version, code, name_key, description, is_mutating,
                                       request_schema, response_schema, supports_dry_run, default_ordering_key_path) values
  ('status_page', 1, 'status.publish', 'adapter.status_page.status_publish',
   'Publishes one incident update. The payload is erp.status_payload(): the incident, its state, components and scope, and the update body every other channel carries.',
   true,
   '{"type":"object","required":["incident_code","title","severity","state","posted_at","body","components"],
     "properties":{"incident_code":{"type":"string","minLength":1},"title":{"type":"string"},
                   "severity":{"type":"string","pattern":"^sev[1-4]$"},
                   "state":{"type":"string","enum":["live","contained","resolved"]},
                   "declared_at":{"type":"string"},"contained_at":{"type":"string"},"resolved_at":{"type":"string"},
                   "scope":{"type":"string"},"affects_everyone":{"type":"boolean"},"origin":{"type":"string"},
                   "components":{"type":"array","items":{"type":"string"}},
                   "update_id":{"type":"string"},"posted_at":{"type":"string"},"body":{"type":"string","minLength":1},
                   "is_no_change":{"type":"boolean"},"affected":{"type":"string"},"not_affected":{"type":"string"},
                   "being_done":{"type":"string"},"meanwhile":{"type":"string"},"next_update_at":{"type":"string"}},
     "additionalProperties":false}'::jsonb,
   '{"type":"object"}'::jsonb, true, 'incident_code')
on conflict (adapter_code, adapter_version, code) do update
  set name_key = excluded.name_key, description = excluded.description, is_mutating = excluded.is_mutating,
      request_schema = excluded.request_schema, response_schema = excluded.response_schema,
      supports_dry_run = excluded.supports_dry_run, default_ordering_key_path = excluded.default_ordering_key_path;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('adapter.status_page',                'en', 'Status page',              'administration'),
  ('adapter.status_page',                'de', 'Statusseite',              'administration'),
  ('adapter.status_page.status_publish', 'en', 'Publish incident update',  'administration'),
  ('adapter.status_page.status_publish', 'de', 'Vorfallsaktualisierung veröffentlichen', 'administration')
on conflict (key, locale) do update set value = excluded.value;

-- The worker handler that reads the providers' feeds. No SQL body: it makes
-- outbound calls, which SQL cannot; the worker registers it by code.
insert into erp_ref.job_handler
  (code, name_key, description, parameter_schema, default_timeout_seconds, forbids_overlap, sql_function, default_max_silence_seconds) values
  ('platform.poll_dependency_status', 'job_handler.poll_dependency_status.name',
   'Reads each provider''s status feed and records what it says; a major or critical indicator declares a severity-3 incident below the platform, recovery resolves it. feed_base_url replaces the feed URLs with <base>/<code>/status.json, for a rehearsal.',
   '{"type":"object","properties":{"feed_base_url":{"type":"string"}},"additionalProperties":false}'::jsonb,
   120, true, null, 3600)
on conflict (code) do update
  set name_key = excluded.name_key, description = excluded.description, parameter_schema = excluded.parameter_schema,
      default_timeout_seconds = excluded.default_timeout_seconds, forbids_overlap = excluded.forbids_overlap,
      sql_function = excluded.sql_function, default_max_silence_seconds = excluded.default_max_silence_seconds;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('job_handler.poll_dependency_status.name', 'en', 'Poll provider status feeds', 'administration'),
  ('job_handler.poll_dependency_status.name', 'de', 'Statusfeeds der Anbieter abfragen', 'administration')
on conflict (key, locale) do update set value = excluded.value;


-- ── The database engine leaves the worker's jobs to the worker ──────────────
--
-- erp.run_due_jobs() and the worker both claim through erp.claim_job_runs().
-- Phase 5 gave the database a body to run SQL handlers with, and left it
-- claiming ticks for handlers that have none — which it then failed, every
-- minute, "needs the worker". The poll job above is such a handler, so the
-- claim gains a flag: the database claims only what it can run; the worker
-- claims everything.

do $$
declare v_src text := pg_get_functiondef('erp.claim_job_runs(text, integer, interval)'::regprocedure);
begin
  if position('and job.next_run_at <= now()' in v_src) = 0 or position('order by job.next_run_at' in v_src) = 0
     or position('p_sql_only' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.claim_job_runs is not the 0035 body';
  end if;
end $$;

drop function erp.claim_job_runs(text, integer, interval);
create function erp.claim_job_runs(p_worker text default null, p_batch_size integer default 10, p_lease interval default null, p_sql_only boolean default false)
 RETURNS SETOF erp.job_run
 LANGUAGE plpgsql
 SET search_path TO ''
AS $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_worker  text := coalesce(p_worker, current_user);
  j         erp.job%rowtype;
  v_running integer;
  v_run     erp.job_run%rowtype;
  v_claimed integer := 0;
begin
  for j in
    select * from erp.job job
     where job.tenant_id = v_tenant
       and job.is_enabled
       and job.schedule_kind <> 'manual'
       and job.next_run_at is not null
       and job.next_run_at <= now()
       -- The database engine claims only what it can run. A handler with no
       -- SQL body is the worker's, and a tick the database claimed for it was
       -- a tick failed for nothing (Phase 5, finding 34).
       and (not p_sql_only or exists (select 1 from erp_ref.job_handler h
                                        where h.code = job.handler_code and h.sql_function is not null))
     order by job.next_run_at
     limit greatest(p_batch_size, 1) * 4
     for update skip locked
  loop
    exit when v_claimed >= greatest(p_batch_size, 1);

    -- Spec Part 7 via B6. A kill switch stops the job without losing its
    -- schedule: next_run_at is untouched, so clearing the switch resumes it.
    if erp.is_killed('job', j.code) then
      continue;
    end if;

    -- Spec 3.8: the planned-outage calendar suppresses the job. The tick is
    -- moved on rather than queued, because a maintenance window is not a
    -- backlog to work through the moment it ends.
    if erp.in_outage_window(j.code, now(), false) then
      insert into erp.job_run (
        tenant_id, job_id, scheduled_for, outcome, finished_at, skip_reason)
      values (v_tenant, j.id, j.next_run_at, 'skipped', now(),
              'suppressed by a planned outage window');

      update erp.job
         set next_run_at = erp.compute_next_run(
               j.schedule_kind, j.interval_seconds, j.at_time,
               j.days_of_week, j.day_of_month, j.timezone, now())
       where id = j.id;
      continue;
    end if;

    select count(*) into v_running
      from erp.job_run r
     where r.tenant_id = v_tenant and r.job_id = j.id and r.outcome = 'running';

    if v_running > 0 then
      -- Refusal 3: an overlapping tick is never dropped silently.
      if j.overlap_policy = 'skip' then
        insert into erp.job_run (
          tenant_id, job_id, scheduled_for, outcome, finished_at, skip_reason)
        values (v_tenant, j.id, j.next_run_at, 'skipped', now(),
                format('previous run still in progress (%s running)', v_running));

        update erp.job
           set next_run_at = erp.compute_next_run(
                 j.schedule_kind, j.interval_seconds, j.at_time,
                 j.days_of_week, j.day_of_month, j.timezone, now())
         where id = j.id;
        continue;

      elsif j.overlap_policy = 'queue' then
        -- Leave next_run_at where it is. The tick waits, and the next claim
        -- after the run finishes picks up exactly this slot.
        continue;

      elsif v_running >= j.max_concurrent_runs then
        -- 'allow', but at its ceiling. Same treatment as 'queue': wait rather
        -- than lose the tick.
        continue;
      end if;
    end if;

    insert into erp.job_run (
      tenant_id, job_id, scheduled_for, started_at, outcome, worker,
      lease_expires_at, attempt, correlation_id)
    values (
      v_tenant, j.id, j.next_run_at, now(), 'running', v_worker,
      now() + coalesce(p_lease, make_interval(secs => j.timeout_seconds)),
      j.consecutive_failures + 1, erp.current_correlation_id())
    returning * into v_run;

    -- Advanced at claim time, from the scheduled slot rather than from now, so
    -- a run that takes nineteen minutes does not push a twenty-minute schedule
    -- into drifting an hour a day.
    update erp.job
       set next_run_at = erp.compute_next_run(
             j.schedule_kind, j.interval_seconds, j.at_time,
             j.days_of_week, j.day_of_month, j.timezone, j.next_run_at)
     where id = j.id;

    v_claimed := v_claimed + 1;
    return next v_run;
  end loop;
end;
$$

;
revoke all on function erp.claim_job_runs(text, integer, interval, boolean) from public, anon, authenticated;

do $$
declare v_src text := pg_get_functiondef('erp.run_due_jobs(integer)'::regprocedure);
begin
  if position('for r in select * from erp.claim_job_runs(''database'', greatest(p_batch_size, 1)) loop' in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_due_jobs is not the 20260906100000 body';
  end if;
  if position(E'  return jsonb_build_object(\n    ''claimed'', v_claimed, ''succeeded'', v_ok, ''failed'', v_failed,' in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.run_due_jobs does not build the result 20260906100000 built';
  end if;
  v_src := replace(v_src,
    'for r in select * from erp.claim_job_runs(''database'', greatest(p_batch_size, 1)) loop',
    'for r in select * from erp.claim_job_runs(''database'', greatest(p_batch_size, 1), null, true) loop');
  -- Left for the worker, and said so: a due job whose handler has no SQL body
  -- is not claimed here and is counted rather than skipped in silence.
  v_src := replace(v_src,
    E'  return jsonb_build_object(\n    ''claimed'', v_claimed, ''succeeded'', v_ok, ''failed'', v_failed,',
    E'  select v_worker + count(*) into v_worker\n'
    '    from erp.job j join erp_ref.job_handler h on h.code = j.handler_code\n'
    '   where j.tenant_id = erp.current_tenant_id() and j.is_enabled and j.schedule_kind <> ''manual''\n'
    '     and j.next_run_at is not null and j.next_run_at <= now() and h.sql_function is null;\n'
    '  return jsonb_build_object(\n    ''claimed'', v_claimed, ''succeeded'', v_ok, ''failed'', v_failed,');
  execute v_src;
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The discipline report reads the timer
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare v_src text := pg_get_functiondef('erp.support_discipline_report()'::regprocedure);
begin
  if v_src not like '%a contained incident is scoped to some organisations and names none%'
     or v_src like '%past the update it promised%' then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.support_discipline_report is not the 20260904580000 body';
  end if;
end $$;

create or replace function erp.support_discipline_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $function$
  select 'a severity states no response or update cadence', s.code, s.name
    from erp_ref.support_severity s
   where s.response_within_minutes is null or s.update_every_minutes is null
  union all
  select 'a more severe level is answered more slowly than a less severe one',
         a.code || ' vs ' || b.code,
         format('%s responds in %s minutes, %s in %s',
                a.code, a.response_within_minutes, b.code, b.response_within_minutes)
    from erp_ref.support_severity a
    join erp_ref.support_severity b on b.seq > a.seq
   where a.response_within_minutes > b.response_within_minutes
  union all
  select 'a support access has no expiry within a week of its grant',
         a.id::text, format('granted %s, expires %s', a.granted_at, a.expires_at)
    from erp.support_access a
   where a.expires_at > a.granted_at + interval '7 days'
  union all
  select 'a support action was recorded against read-only access',
         act.id::text, act.action
    from erp.support_action act
    join erp.support_access acc
      on acc.tenant_id = act.tenant_id and acc.id = act.support_access_id
   where act.is_write and not acc.is_write_access
  union all
  select 'an incident names no commander, communications owner or scribe',
         i.code, i.title
    from erp_meta.incident i
   where coalesce(btrim(i.commander), '') = ''
      or coalesce(btrim(i.communications_owner), '') = ''
      or coalesce(btrim(i.scribe), '') = ''
  union all
  -- §17.3: a resolved severity 1 or 2 with no review — linked or assembled.
  select 'a resolved severity 1 or 2 incident has no post-incident review',
         i.code, i.severity_code
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
   where s.requires_review and i.resolved_at is not null
     and i.review_completed_at is null
     and not exists (select 1 from erp_meta.incident_review r where r.incident_id = i.id)
  union all
  select 'a live incident has gone longer than its cadence without an update',
         i.code,
         format('%s allows %s minutes between updates',
                i.severity_code, s.update_every_minutes)
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
   where i.resolved_at is null
     and now() - coalesce(
       (select max(u.posted_at) from erp_meta.incident_update u
         where u.incident_id = i.id), i.declared_at)
         > make_interval(mins => s.update_every_minutes)
  union all
  -- v1.6 §16.5, D35: the timer is a promise. Past it is a finding whether or
  -- not the cadence has also passed.
  select 'a live incident is past the update it promised',
         i.code, format('promised %s UTC', to_char(i.next_update_due_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'))
    from erp_meta.incident i
   where i.resolved_at is null and i.next_update_due_at < now()
  union all
  -- D35, the other half: the timer must actually run. An update ten minutes
  -- past due with nobody prompted means the sweep is not running, which on a
  -- live deployment is its own incident.
  select 'an update fell due and nobody was prompted',
         i.code, format('due %s UTC, no prompt recorded', to_char(i.next_update_due_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'))
    from erp_meta.incident i
   where i.resolved_at is null and i.next_update_due_at < now() - interval '10 minutes'
     and not exists (select 1 from erp_meta.incident_prompt p where p.incident_id = i.id and p.due_at = i.next_update_due_at)
  union all
  select 'a contained incident is scoped to some organisations and names none',
         i.code, i.scope
    from erp_meta.incident i
   where i.contained_at is not null
     and i.contained_at < now() - interval '1 hour'
     and i.affects_all_tenants is false
     and not exists (select 1 from erp_meta.incident_tenant t where t.incident_id = i.id)
  union all
  select 'a security incident has no disclosure obligations dated',
         i.code, i.title
    from erp_meta.incident i
   where i.is_security
     and not exists (select 1 from erp_meta.incident_disclosure d where d.incident_id = i.id)
  union all
  select 'the platform''s disclosure deadline passed unrecorded',
         i.code, format('%s was due %s', d.obligation_code, d.due_at)
    from erp_meta.incident_disclosure d
    join erp_meta.incident i on i.id = d.incident_id
    join erp_ref.notice_period n on n.code = d.obligation_code
   where n.obliged_party = 'platform' and d.notified_at is null and d.due_at < now()
  union all
  -- D36: a review owed to the organisations reached is shared with them.
  select 'a review of a severity 1 or 2 incident is withheld from the organisations it reached',
         i.code, i.severity_code
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
    join erp_meta.incident_review r on r.incident_id = i.id
   where s.requires_review and not r.is_shared
  union all
  -- D36: an organisation that was reached and never told. The sweep delivers
  -- within a minute on a scheduled host; an hour is not a grace, it is proof
  -- the sweep is not running.
  select 'an organisation an incident reached was never told',
         i.code, t.tenant_code
    from erp_meta.incident i
    join erp_meta.incident_tenant t on t.incident_id = i.id
   where t.named_at < now() - interval '1 hour'
     and not exists (select 1 from erp_meta.incident_delivery d
                      where d.incident_id = i.id and d.tenant_id = t.tenant_id and d.incident_update_id is null)
  order by 1, 2
$function$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('incident_communication', 'Incidents communicated', 'report', 'platform',
   'incident_communication_report', '', null, '',
   'What each incident said to whom: deliveries per organisation, publications to status pages, the prompts the timer recorded and the actions tracked. Empty is fine; a live incident with deliveries missing is not.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check)),
  ('platform_dependencies', 'Providers below the platform', 'report', 'platform',
   'dependency_report', '', null, '',
   'The providers the platform stands on, what their status feeds last said, and the incident any outage declared. A feed never observed means the poll job is not scheduled.',
   false, (select coalesce(max(seq), 0) + 2 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The decisions register: D35 and D36 enter; D35–D39 become D37–D41
-- ═════════════════════════════════════════════════════════════════════════════

do $$
declare
  r     record;
  v_new text;
  v_map jsonb := '{}'::jsonb;
begin
  if exists (select 1 from erp_ref.product_decision where code = 'D41') then
    return;  -- already renumbered
  end if;
  -- Highest first, so a moved code never collides with one not yet moved.
  for r in select * from erp_ref.product_decision where seq between 35 and 39 order by seq desc loop
    v_new := 'D' || (r.seq + 2)::text;
    v_map := v_map || jsonb_build_object(r.code, v_new);
    insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, supersedes, spec_reference)
    values (v_new, r.seq + 2, r.title, r.decision, r.rationale, r.cost, r.supersedes,
            regexp_replace(replace(r.spec_reference, 'v1.5', 'v1.6'), '\m' || r.code || '\M', v_new, 'g'));
    insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note)
    select v_new, c.schema_name, c.routine_name, regexp_replace(c.note, '\m' || r.code || '\M', v_new, 'g')
      from erp_ref.product_decision_check c where c.decision_code = r.code;
    delete from erp_ref.product_decision where code = r.code;
  end loop;
end $$;

insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, supersedes, spec_reference) values
  ('D35', 35, 'Incident communication is on a timer, not on progress',
   'Every live incident carries the time its next update is due, set from the severity''s published cadence or an earlier promise and never a later one. The platform sweep records who was prompted when it passes and escalates through the roles the declaration named. One update is one row that every channel carries unchanged: the in-app banner, the email to the organisations reached, the status page published through the gateway, and the history.',
   'Silence is what erodes trust during an outage. An update that says nothing has changed is still an update, and the only way to make one arrive on time is to make its absence somebody''s named failure before the cadence has passed.',
   'An operator is prompted, and then escalated, for an update that may genuinely have nothing to say.',
   null, 'v1.6 §16.5, Part 22 D35'),
  ('D36', 36, 'Incident history stays visible to the organisations it reached',
   'An organisation can read every incident that reached it — the timeline it was given and the review the platform shared — for as long as the register holds it, through erp_incident_history(). The thirty-day window applies to the notices screen, not to the record.',
   'A shared platform''s incident is part of the organisation''s own history: their auditor asks about it a year later, and the answer should be the record, not memory.',
   'The register grows and the organisation sees the platform''s failures in full.',
   null, 'v1.6 §16.5, Part 22 D36')
on conflict (code) do update
  set title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
      cost = excluded.cost, spec_reference = excluded.spec_reference;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D35', 'erp', 'assert_support_discipline',
   'D35: a live incident past the update it promised is a finding, and an update ten minutes past due with no prompt recorded is a finding — the sweep must be running.'),
  ('D35', 'erp_test', 'assert_incident_communication_suite',
   'D35: the timer is set from the cadence, a later promise is refused, the sweep prompts and escalates, and one update reaches the banner, the email queue and the status page with the same body.'),
  ('D36', 'erp', 'assert_support_discipline',
   'D36: a review of a severity 1 or 2 incident withheld from the organisations it reached is a finding, and an organisation reached and never told is a finding.'),
  ('D36', 'erp_test', 'assert_incident_communication_suite',
   'D36: a resolved incident is still in the organisation''s history with its timeline and the shared review; an organisation the incident did not reach sees nothing.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

-- The status page decision, re-recorded now that the page exists.
insert into erp_meta.policy_decision (code, title, spec_reference, decision, rationale, status, evidence) values
  ('status_page_published_through_the_gateway',
   'The status page is outside the product and published from it',
   'v1.6 §16.5',
   'The public status page stays outside this database, as status_page_not_built reasoned: a page served from the product''s own Postgres goes dark exactly when somebody needs it. It now exists: a Cloudflare Worker (infra/status/) that stores what it is sent and serves it, fed by the same incident register through the integration gateway. Every declaration and update becomes a status.publish command to each status_page external system registered in the platform''s own organisation; the worker delivers it with an idempotency key, so a retry cannot publish twice, and the command record is the evidence of what the page was told and when.',
   'A status page maintained by hand is a status page that is wrong during the incident. Publishing it from the register makes it say what the organisations were told, and the gateway''s own lifecycle — queued, in flight, ambiguous, succeeded — is what makes "did the page get it" a question with a recorded answer.',
   'accepted',
   'erp_ref.adapter status_page@1 with status.publish; erp.communicate_incidents() publishing in the platform organisation; erp_meta.incident_publication naming the command per update and system; infra/status/ serving the page from KV; supabase/ci/incident_rehearsal.sh receiving the publication on the stub; erp_test.incident_communication_suite() case 10.')
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

update erp_meta.policy_decision
   set status = 'superseded', superseded_by = 'status_page_published_through_the_gateway'
 where code = 'status_page_not_built';

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.incident_communication_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  ra record; rb record;
  ca text := 'zzica-' || substr(md5(random()::text), 1, 6);
  cb text := 'zzicb-' || substr(md5(random()::text), 1, 6);
  op uuid := gen_random_uuid();
  ow uuid := gen_random_uuid();
  aa uuid := gen_random_uuid();
  ab uuid := gen_random_uuid();
  ax uuid := gen_random_uuid();
  inc text := 'zzic-' || substr(md5(random()::text), 1, 6);
  v_ok boolean; v_msg text; res jsonb; v_n integer; v_up uuid; v_body text; v_sys uuid; v_cmd uuid;
  v_x uuid; v_action uuid; v_doc jsonb; v_dep text;
begin
  begin
    insert into auth.users (id, email) values
      (op, 'op@zzic.test'), (ow, 'owner@zzic.test'), (aa, 'a@zzic.test'), (ab, 'b@zzic.test'), (ax, 'x@zzic.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('op@zzic.test', op, 'Comms Owner', 'operator'),
           ('owner@zzic.test', ow, 'Platform Owner', 'owner');

    select * into ra from erp.provision_tenant(ca, 'Affected Org', 'a@zzic.test', 'A Admin');
    select * into rb from erp.provision_tenant(cb, 'Bystander Org', 'b@zzic.test', 'B Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
    perform erp.claim_invitation(rb.admin_token);

    -- A second person in the affected organisation, no role: told only if they subscribe.
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email)
    values (ra.tenant_id, ax, 'person', 'active', 'X Person', 'x@zzic.test') returning id into v_x;

    -- 1. Components are a vocabulary.
    return query select 'the platform names its components in both languages',
      (select count(*) from erp_ref.platform_component) = 12
      and not exists (select 1 from erp_ref.platform_component c
                       where not exists (select 1 from erp_ref.resource r where r.key = c.name_key and r.locale = 'de')),
      format('%s components', (select count(*) from erp_ref.platform_component));

    -- 2. Declared with scope and components, the named organisation is told at once.
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    perform erp.declare_incident(inc, 'sev2', 'Allocation is failing for one organisation',
                                 'A. Commander', 'Comms Owner', 'C. Scribe', false,
                                 'One organisation''s allocation', false, array['allocation', 'order_intake'], array[ca], 30);
    perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
    res := erp.service_notices();
    return query select 'declared with components and scope, the named organisation sees it at once',
      jsonb_array_length(res -> 'incidents') = 1
      and jsonb_array_length(res -> 'incidents' -> 0 -> 'components') = 2
      and (res -> 'incidents' -> 0 ->> 'next_update_due_at') is not null,
      res -> 'incidents' -> 0 -> 'components' -> 0 ->> 'name';

    -- 3. An unknown component and a promise later than the cadence are refused.
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    begin
      perform erp.declare_incident(inc || '-x', 'sev2', 'Bad component', 'A', 'B', 'C', false, null, null, array['teleporter']);
      v_ok := false; v_msg := 'an unknown component was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_UNKNOWN_COMPONENT%'; v_msg := left(sqlerrm, 60);
    end;
    return query select 'an unknown component is refused', v_ok, v_msg;
    begin
      perform erp.post_incident_update(inc, 'Looking at it.', false, null, null, null, null, 999);
      v_ok := false; v_msg := 'a promise later than the cadence was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_UPDATE_PROMISED_TOO_LATE%'; v_msg := left(sqlerrm, 70);
    end;
    return query select 'an update promised later than the cadence is refused', v_ok, v_msg;

    -- 4. The five fields render once, and the timer moves to the promise.
    v_up := erp.post_incident_update(inc, null, false,
              'Allocation for ' || ca, 'Every other organisation; receiving and despatch everywhere',
              'The allocation policy resolver is being rolled back', 'Allocate by hand from the order screen', 45);
    select u.body into v_body from erp_meta.incident_update u where u.id = v_up;
    return query select 'the five fields render into one body and the timer moves to the promise',
      v_body like 'Affected: Allocation for %' and v_body like '%Not affected: Every other%'
      and v_body like '%What is being done: The allocation%' and v_body like '%Meanwhile: Allocate by hand%'
      and v_body like '%Next update: %UTC'
      and (select i.next_update_due_at between now() + interval '44 minutes' and now() + interval '46 minutes'
             from erp_meta.incident i where i.code = inc),
      left(v_body, 80);
    begin
      perform erp.post_incident_update(inc, '   ', false);
      v_ok := false; v_msg := 'an empty update was accepted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_UPDATE_SAYS_NOTHING%'; v_msg := left(sqlerrm, 60);
    end;
    return query select 'an update that says nothing is refused', v_ok, v_msg;

    -- 5. Delivery: the affected organisation's administrator gets the declaration
    --    and the update, in-app and by email, with the body as posted.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', ra.tenant_id::text, true);
    res := erp.communicate_incidents();
    return query select 'the sweep delivers the declaration and the update to the organisation reached',
      (res ->> 'deliveries')::integer = 2
      and (select count(*) from erp.notification n where n.tenant_id = ra.tenant_id and n.app_user_id = ra.admin_user_id
             and n.channel_kind = 'in_app' and n.status = 'delivered' and n.subject like '[SEV2]%') = 2
      and (select count(*) from erp.notification n where n.tenant_id = ra.tenant_id and n.app_user_id = ra.admin_user_id
             and n.channel_kind = 'email' and n.status = 'queued' and n.body = v_body) = 1,
      res::text;
    res := erp.communicate_incidents();
    return query select 'and running it again delivers nothing twice', (res ->> 'deliveries')::integer = 0, res::text;

    -- 6. The bystander is told nothing.
    perform set_config('erp.job_tenant_id', rb.tenant_id::text, true);
    res := erp.communicate_incidents();
    return query select 'the organisation the incident did not reach is told nothing',
      (res ->> 'deliveries')::integer = 0
      and not exists (select 1 from erp.notification n where n.tenant_id = rb.tenant_id and n.subject like '[SEV2]%'),
      'never a broadcast that alarms the unaffected';

    -- 7. Subscriptions: a person with no role subscribes and is told; the
    --    administrator steps out and is not.
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
    res := erp.incident_subscription_state();
    return query select 'the administrator is a recipient by default',
      (res ->> 'by_default')::boolean and (res ->> 'subscribed')::boolean and (res ->> 'recipients')::integer = 1, res::text;
    perform erp.set_incident_subscription(false);
    perform set_config('request.jwt.claims', json_build_object('sub', ax)::text, true);
    -- x holds no permission; subscribing is gated on administration.read, so
    -- the row is written for them as the platform would from the profile
    -- screen once they hold it. Here: directly, as the organisation's own row.
    insert into erp.incident_subscription (tenant_id, app_user_id, is_subscribed) values (ra.tenant_id, v_x, true);
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    v_up := erp.post_incident_update(inc, 'No change since the last update.', true);
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', ra.tenant_id::text, true);
    res := erp.communicate_incidents();
    return query select 'a subscriber is told and an administrator who stepped out is not',
      (res ->> 'notified')::integer = 1
      and exists (select 1 from erp.notification n where n.tenant_id = ra.tenant_id and n.app_user_id = v_x and n.body = 'No change since the last update.')
      and not exists (select 1 from erp.notification n where n.tenant_id = ra.tenant_id and n.app_user_id = ra.admin_user_id and n.body = 'No change since the last update.'),
      res::text;

    -- 8. The timer: an update that fell due is prompted, then escalated.
    update erp_meta.incident set next_update_due_at = now() - interval '1 minute' where code = inc;
    res := erp.prompt_incident_updates();
    return query select 'an update that fell due prompts the communications owner, once',
      (res ->> 'prompts')::integer = 1
      and (select count(*) from erp_meta.incident_prompt p join erp_meta.incident i on i.id = p.incident_id
            where i.code = inc and p.level = 'communications_owner') = 1
      and exists (select 1 from erp_meta.platform_audit a where a.action = 'platform.incident_update_due' and a.target = inc)
      and (erp.prompt_incident_updates() ->> 'prompts')::integer = 0,
      res::text;
    return query select 'the discipline report says the promise was missed',
      exists (select 1 from erp.support_discipline_report() f
               where f.finding = 'a live incident is past the update it promised' and f.reference = inc),
      'found, not assumed';
    -- sev2 responds within 120 minutes: past that, the commander; past two, the owner.
    update erp_meta.incident set next_update_due_at = now() - interval '5 hours' where code = inc;
    res := erp.prompt_incident_updates();
    return query select 'past the response window the commander is told, past two the owner',
      (res ->> 'prompts')::integer = 3
      and (select array_agg(p.level order by p.level) from erp_meta.incident_prompt p join erp_meta.incident i on i.id = p.incident_id
            where i.code = inc and p.due_at = (select next_update_due_at from erp_meta.incident where code = inc))
          = array['commander', 'communications_owner', 'owner']
      and (select count(*) from erp_meta.platform_audit a where a.action = 'platform.incident_update_escalated' and a.target = inc) = 2,
      res::text;
    return query select 'the console reads the escalation',
      (select r.timer_state from erp.incident_report() r where r.code = inc) = 'escalated_owner', 'timer_state';
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    perform erp.post_incident_update(inc, 'Rollback complete; monitoring allocation.', false, null, null, null, null, 60);
    return query select 'posting clears it',
      (select r.timer_state from erp.incident_report() r where r.code = inc) = 'kept'
      and not exists (select 1 from erp.support_discipline_report() f where f.reference = inc),
      'kept';

    -- 9. The platform's own organisation publishes to a status page through
    --    the gateway.
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    perform erp.designate_platform_organisation(cb, 'the suite''s platform organisation');
    insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, status, max_attempts, retry_backoff_seconds)
    values (rb.tenant_id, 'zz_status', 'Suite status page', 'status_page', 1,
            jsonb_build_object('base_url', 'https://status.example.test/publish'), 'active', 3, 1)
    returning id into v_sys;
    insert into erp.external_system_operation (tenant_id, external_system_id, operation_code, is_enabled)
    values (rb.tenant_id, v_sys, 'status.publish', true);
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', rb.tenant_id::text, true);
    res := erp.communicate_incidents();
    select c.id into v_cmd from erp.command c where c.tenant_id = rb.tenant_id and c.external_system_id = v_sys
      and c.idempotency_key = 'status-' || inc || '-' || v_up::text;
    return query select 'the platform organisation publishes every declaration and update as a queued command',
      (res ->> 'published')::integer = 4
      and (select count(*) from erp.command c where c.tenant_id = rb.tenant_id and c.external_system_id = v_sys and c.status = 'queued') = 4
      and v_cmd is not null
      and (select c.payload ->> 'body' from erp.command c where c.id = v_cmd) = 'No change since the last update.'
      and (select c.ordering_key from erp.command c where c.id = v_cmd) = inc
      and (select jsonb_array_length(c.payload -> 'components') from erp.command c where c.id = v_cmd) = 2,
      res::text;
    res := erp.communicate_incidents();
    return query select 'and publishes nothing twice', (res ->> 'published')::integer = 0, res::text;
    return query select 'the payload matches the operation it is sent as',
      erp.jsonb_matches_schema((select o.request_schema::json from erp_ref.adapter_operation o where o.code = 'status.publish'),
                               (select c.payload from erp.command c where c.id = v_cmd)),
      'status.publish request_schema';
    perform set_config('erp.job_tenant_id', '', true);

    -- 10. A provider's outage declares an incident below the platform; recovery resolves it.
    res := erp.record_dependency_status('resend', 'major', 'Delivery delays', '{"status":{"indicator":"major"}}'::jsonb, 'suite');
    v_dep := res ->> 'declared';
    return query select 'a major indicator on a provider feed declares a severity-3 incident with its origin',
      v_dep is not null
      and (select i.severity_code = 'sev3' and i.origin_dependency_code = 'resend' and i.affects_all_tenants
             and i.next_update_due_at is not null
             from erp_meta.incident i where i.code = v_dep)
      and (select array_agg(c.component_code order by c.component_code) from erp_meta.incident_component c
             join erp_meta.incident i on i.id = c.incident_id where i.code = v_dep) = array['enquiry', 'notifications']
      and (erp.record_dependency_status('resend', 'major', 'Still', '{}'::jsonb, 'suite') ->> 'declared') is null,
      v_dep;
    perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
    res := erp.service_notices();
    return query select 'declared as reaching everyone, every organisation sees it before containment',
      exists (select 1 from jsonb_array_elements(res -> 'incidents') e where e ->> 'code' = v_dep and e ->> 'origin' is not null),
      'affects_all_tenants at declaration';
    perform set_config('request.jwt.claims', '', true);
    res := erp.record_dependency_status('resend', 'none', 'Operational', '{}'::jsonb, 'suite');
    return query select 'recovery on the feed posts the closing update and resolves it',
      res ->> 'resolved' = v_dep
      and (select i.resolved_at is not null from erp_meta.incident i where i.code = v_dep)
      and exists (select 1 from erp_meta.incident_update u join erp_meta.incident i on i.id = u.incident_id
                   where i.code = v_dep and u.body like 'Resend reports recovery%'),
      res::text;

    -- 11. Actions and the review; the open action surfaces on a similar declaration.
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    v_action := erp.add_incident_action(inc, 'Add a guard to the allocation policy resolver', 'D. Developer', current_date + 14);
    perform erp.declare_incident(inc || '-2', 'sev3', 'Allocation slow', 'A', 'B', 'C', false, null, null, array['allocation']);
    return query select 'the open action of an earlier incident on the same component surfaces at declaration',
      exists (select 1 from erp.similar_incident_actions(inc || '-2') s where s.action_id = v_action and s.shared_component = 'allocation'),
      'similar_incident_actions';
    begin
      perform erp.resolve_incident(inc);
      v_ok := false; v_msg := 'a sev2 resolved without a review';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_REVIEW_REQUIRED%'; v_msg := left(sqlerrm, 60);
    end;
    return query select 'a severity 2 incident does not resolve without its review', v_ok, v_msg;
    v_doc := erp.assemble_incident_review(inc);
    perform erp.resolve_incident(inc);
    return query select 'the review is assembled from the updates and the timer''s record, and the incident resolves on it',
      jsonb_array_length(v_doc -> 'timeline') = 3
      and jsonb_array_length(v_doc -> 'prompts') = 4
      and jsonb_array_length(v_doc -> 'actions') = 1
      and (select i.resolved_at is not null and i.review_completed_at is not null from erp_meta.incident i where i.code = inc)
      and exists (select 1 from erp_meta.incident_update u join erp_meta.incident i on i.id = u.incident_id
                   where i.code = inc and u.body like 'Resolved: %'),
      format('%s updates, %s prompts', jsonb_array_length(v_doc -> 'timeline'), jsonb_array_length(v_doc -> 'prompts'));
    perform erp.complete_incident_action(v_action, 'Guard added and deployed');
    return query select 'an action is closed with a note saying what was done',
      (select a.done_at is not null and a.done_note = 'Guard added and deployed' from erp_meta.incident_action a where a.id = v_action),
      'done';

    -- 12. History: resolved, past the notices window, still visible with the
    --     review — and only to the organisation reached.
    update erp_meta.incident set resolved_at = now() - interval '200 days', declared_at = now() - interval '201 days' where code = inc;
    perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
    res := erp.incident_history();
    return query select 'a resolved incident stays in the organisation''s history with its timeline and the shared review',
      exists (select 1 from jsonb_array_elements(res) e
               where e ->> 'code' = inc and e ->> 'state' = 'resolved'
                 and jsonb_array_length(e -> 'updates') = 4
                 and (e -> 'review' -> 'timeline') is not null
                 and (e ->> 'told_at') is not null)
      and not exists (select 1 from jsonb_array_elements(erp.service_notices() -> 'incidents') e where e ->> 'code' = inc),
      'history keeps it; notices let it go';
    perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
    res := erp.incident_history();
    return query select 'the organisation it did not reach has no history of it',
      not exists (select 1 from jsonb_array_elements(res) e where e ->> 'code' = inc), 'scoped by construction';

    -- 13. The decisions register.
    return query select 'D35 and D36 are registered, bound, and the register is dense to D41',
      (select count(*) from erp_ref.product_decision where code in ('D35', 'D36') and spec_reference like 'v1.6%') = 2
      and (select count(*) from erp_ref.product_decision_check where decision_code in ('D35', 'D36')) = 4
      and (select max(seq) from erp_ref.product_decision) = 41
      and (select count(*) from erp_ref.product_decision) = 41
      and (select spec_reference from erp_ref.product_decision where code = 'D37') like 'v1.6 §17.9%D37'
      and (select status from erp_meta.policy_decision where code = 'status_page_not_built') = 'superseded',
      format('%s decisions', (select count(*) from erp_ref.product_decision));

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  -- 14
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp_meta.incident i where i.code like 'zzic-%' or i.code like 'dep-resend-%')
        and not exists (select 1 from erp.tenant t where t.code like 'zzic%')
        and not exists (select 1 from erp_meta.platform_staff s where s.email like '%@zzic.test');
  detail := 'organisations, incidents and staff rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_incident_communication_suite()
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
  create temp table if not exists _incident_communication on commit drop as
    select * from erp_test.incident_communication_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _incident_communication;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INCIDENT_COMMUNICATION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_INCIDENT_COMMUNICATION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('incident communication: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_incident_communication_suite() from public, anon, authenticated;
revoke all on function erp_test.incident_communication_suite() from public, anon, authenticated;

-- The service-notice suite was the one suite in the family with no pinned
-- count. Its behaviour changed above (an incident declared as reaching
-- everyone is shown before containment), so it runs again here and is pinned.
do $$
declare v_src text := pg_get_functiondef('erp_test.assert_service_notice_suite()'::regprocedure);
begin
  if v_src not like '%if v_passed < v_total then%' or v_src like '%c_expected%' then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp_test.assert_service_notice_suite is not the 20260904550000 body';
  end if;
end $$;

create or replace function erp_test.assert_service_notice_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 21;
  v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _service_notice_result on commit drop as
    select * from erp_test.service_notice_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _service_notice_result;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SERVICE_NOTICE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_SERVICE_NOTICE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('service notices: %s/%s', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_service_notice_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Screen strings
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Service notice'),
    ('Every organisation'),
    ('Next update by'),
    ('Details'),
    ('Dismiss'),
    ('Components'),
    ('Origin'),
    ('Incident notices'),
    ('You are told in the application and by email when an incident reaches this organisation.'),
    ('You are not on the list. Administrators are told by default; anybody may subscribe.'),
    ('Subscribe'),
    ('Unsubscribe'),
    ('Incident history'),
    ('Every incident that reached this organisation, for as long as the platform holds the record. The thirty-day window above is for notices; this is the record.'),
    ('No incident has reached this organisation.'),
    ('Told'),
    ('Review shared'),
    ('Actions'),
    ('done'),
    ('Timeline'),
    ('recipients'),
    ('Add an action'),
    ('Assemble the review')
  ) as t(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 11. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_incident_communication_suite();
select erp_test.assert_service_notice_suite();
select erp_test.assert_incident_operations_suite();
select erp_test.assert_support_suite();
select erp_test.assert_policy_closure_suite();
select erp_test.assert_policy_register_suite();
select erp_test.assert_gateway_suite();
select erp.assert_support_discipline();
select erp.assert_gateway_integrity();
select erp.assert_resource_coverage();
select erp.assert_resource_coverage_de();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_no_dead_configuration();
select erp.assert_scheduler_integrity();
select erp.assert_job_handlers_resolvable();
select erp.assert_notification_routes_resolvable();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
