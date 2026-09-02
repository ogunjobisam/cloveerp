-- =============================================================================
-- Part 17: what the organisation is told, and when
--
-- The incident register can be run from (20260904380000) and the status page
-- stays outside the database by construction (status_page_not_built). Between
-- those two sits the half of Part 17 that is about the organisation rather than
-- the platform, and none of it had a row:
--
--   §17.3 "A shared platform means an incident affecting one tenant may or may
--   not affect others. The first question after containment is scope, and
--   communication is scoped accordingly — never a broadcast that alarms
--   unaffected organisations, never silence toward affected ones."
--
-- erp_meta.incident carried scope as a sentence and affects_all_tenants as a
-- flag, and nothing named WHICH organisations an incident reached. So there was
-- nothing to scope communication by, and nothing an organisation could read:
-- erp_meta is platform_internal, and a tenant session asking erp.incident_report()
-- got an empty list whether or not its postings were failing. That is silence
-- toward the affected, arrived at by there being no door.
--
--   §17.4 "Planned maintenance is announced against the windows in §9.2."
--
-- No register of windows, so nothing to announce against and no way to know
-- whether an announcement gave the notice §9.2's "published" implies.
--
--   §17.4 "Security incidents follow a disclosure path with stated timelines,
--   including regulatory notification obligations that fall on the organisation
--   as controller and the platform as processor."
--
-- Stated, not implied: the timelines are a register (erp_ref.notice_period),
-- an incident flagged as a security incident gets one dated obligation per
-- timeline from the moment it was declared, and the discipline report fails an
-- obligation that passes its deadline unrecorded.
--
-- What an organisation reads is one door, erp_service_notices(): the windows
-- that touch it, the incidents it was named in or that reached everyone once
-- containment said so, each with its updates, and its own obligations on a
-- security incident with the clock already running. Nothing about anybody else.
-- =============================================================================

-- ── §17.4 the timelines, published ───────────────────────────────────────────

create table if not exists erp_ref.notice_period (
  code           text primary key,
  title          text not null,
  hours          integer not null check (hours >= 0),
  obliged_party  text not null check (obliged_party in ('platform', 'organisation')),
  basis          text not null,
  seq            integer not null,
  registered_at  timestamptz not null default now()
);

comment on table erp_ref.notice_period is
  'Specification v1.2 §17.4 and §9.2: the stated timelines. How far ahead '
  'planned maintenance is announced, and how long each party has to disclose a '
  'security incident. Product content, the same for every organisation, so a '
  'timeline is published rather than negotiated during the incident.';

insert into erp_ref.notice_period (code, title, hours, obliged_party, basis, seq) values
  ('planned_maintenance', 'Planned maintenance is announced ahead', 48, 'platform',
   '§9.2 publishes maintenance windows per deployment and §17.4 announces planned maintenance against them. Two days'' notice, so a warehouse can plan a shift around it. Emergency maintenance is announced with its reason and no notice, and reads as such.', 10),
  ('security_disclosure_to_organisation', 'The platform tells the organisation', 24, 'platform',
   'UK GDPR Article 33(2): a processor notifies the controller of a personal data breach without undue delay. The platform states that as twenty-four hours from declaration, so "without undue delay" is a deadline rather than a sentiment.', 20),
  ('security_disclosure_to_authority', 'The organisation tells its supervisory authority', 72, 'organisation',
   'UK GDPR Article 33(1): the controller notifies the Information Commissioner within seventy-two hours of becoming aware, unless the breach is unlikely to result in a risk. The clock is shown to the organisation from the incident''s declaration so it is not discovered late.', 30),
  ('security_disclosure_to_individuals', 'The organisation tells the people affected', 72, 'organisation',
   'UK GDPR Article 34: where a breach is likely to result in a high risk to individuals, the controller tells them without undue delay. Tracked on the same clock as the authority so neither is forgotten while the other is done.', 40)
on conflict (code) do update set
  title = excluded.title, hours = excluded.hours, obliged_party = excluded.obliged_party,
  basis = excluded.basis, seq = excluded.seq;

-- ── §17.3 which organisations an incident reached ────────────────────────────

alter table erp_meta.incident add column if not exists is_security boolean not null default false;

comment on column erp_meta.incident.is_security is
  '§17.4: a security incident follows the disclosure path. Flagging it creates '
  'one dated obligation per published timeline.';

create table if not exists erp_meta.incident_tenant (
  incident_id  uuid not null references erp_meta.incident (id) on delete cascade,
  -- No foreign key to erp.tenant, for the same reason erp_meta.platform_audit
  -- has none: the record of an incident outlives an organisation that leaves.
  tenant_id    uuid not null,
  tenant_code  text not null,
  named_at     timestamptz not null default now(),
  named_by     text,
  primary key (incident_id, tenant_id)
);

comment on table erp_meta.incident_tenant is
  'Specification v1.2 §17.3: the organisations an incident reached, named by '
  'the platform. Communication is scoped by this table: a named organisation '
  'sees the incident and its updates; an unnamed one is not alarmed.';

create table if not exists erp_meta.incident_disclosure (
  id               uuid primary key default gen_random_uuid(),
  incident_id      uuid not null references erp_meta.incident (id) on delete cascade,
  obligation_code  text not null references erp_ref.notice_period (code),
  due_at           timestamptz not null,
  notified_at      timestamptz,
  notified_by      text,
  note             text,
  created_at       timestamptz not null default now(),
  constraint incident_disclosure_once unique (incident_id, obligation_code),
  constraint incident_disclosure_recorded_has_actor
    check (notified_at is null or coalesce(btrim(notified_by), '') <> '')
);

comment on table erp_meta.incident_disclosure is
  'Specification v1.2 §17.4: one row per published timeline for a security '
  'incident, dated from its declaration. The platform records its own; the '
  'organisation''s are shown to it with the clock running.';

-- ── §17.4 planned maintenance, against §9.2's windows ───────────────────────

create table if not exists erp_meta.maintenance_window (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique,
  title               text not null,
  detail              text,
  starts_at           timestamptz not null,
  ends_at             timestamptz not null,
  announced_at        timestamptz not null default now(),
  announced_by        text not null,
  is_emergency        boolean not null default false,
  emergency_reason    text,
  affects_all_tenants boolean not null,
  cancelled_at        timestamptz,
  cancel_reason       text,
  created_at          timestamptz not null default now(),
  constraint maintenance_window_ends_after_start check (ends_at > starts_at),
  constraint maintenance_window_emergency_has_reason
    check (not is_emergency or coalesce(btrim(emergency_reason), '') <> ''),
  constraint maintenance_window_cancel_has_reason
    check (cancelled_at is null or coalesce(btrim(cancel_reason), '') <> '')
);

comment on table erp_meta.maintenance_window is
  'Specification v1.2 §17.4 and §9.2: planned maintenance, announced. A window '
  'inside the published notice period is refused unless it is emergency '
  'maintenance with its reason, and an emergency reads as one to every '
  'organisation it touches.';

create table if not exists erp_meta.maintenance_window_tenant (
  window_id    uuid not null references erp_meta.maintenance_window (id) on delete cascade,
  tenant_id    uuid not null,
  tenant_code  text not null,
  primary key (window_id, tenant_id)
);

-- ── The writers ──────────────────────────────────────────────────────────────

create or replace function erp.name_affected_organisations(p_incident_code text, p_tenant_codes text[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
  v_code  text; v_n integer := 0; v_tenant erp.tenant%rowtype;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into v_inc from erp_meta.incident i where i.code = p_incident_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_INCIDENT: %', p_incident_code using errcode = '23503';
  end if;
  if coalesce(cardinality(p_tenant_codes), 0) = 0 then
    raise exception 'ERPWARE_NOBODY_NAMED: naming affected organisations needs at least one'
      using errcode = '23514';
  end if;
  foreach v_code in array p_tenant_codes loop
    select * into v_tenant from erp.tenant t where t.code = v_code;
    if not found then
      raise exception 'ERPWARE_UNKNOWN_TENANT: % is not an organisation on this deployment', v_code
        using errcode = '23503';
    end if;
    insert into erp_meta.incident_tenant (incident_id, tenant_id, tenant_code, named_by)
    values (v_inc.id, v_tenant.id, v_tenant.code, v_staff.email)
    on conflict do nothing;
    if found then v_n := v_n + 1; end if;
  end loop;
  perform erp_meta.platform_log(
    v_staff, 'platform.incident_scoped', null, p_incident_code,
    format('%s organisation(s) named as affected', v_n),
    jsonb_build_object('tenants', to_jsonb(p_tenant_codes)));
  return v_n;
end;
$$;

comment on function erp.name_affected_organisations is
  'Specification v1.2 §17.3: names the organisations an incident reached, which '
  'is what scopes what each is told. Operator, because saying who was affected '
  'is an operational claim.';

create or replace function erp.flag_security_incident(p_incident_code text)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
  v_n     integer;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into v_inc from erp_meta.incident i where i.code = p_incident_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_INCIDENT: %', p_incident_code using errcode = '23503';
  end if;
  update erp_meta.incident set is_security = true where id = v_inc.id;
  -- One dated obligation per published timeline, from the declaration and not
  -- from the moment somebody remembered to flag it: the clock in Article 33
  -- starts at awareness, and declaring is awareness.
  insert into erp_meta.incident_disclosure (incident_id, obligation_code, due_at)
  select v_inc.id, n.code, v_inc.declared_at + make_interval(hours => n.hours)
    from erp_ref.notice_period n
   where n.code like 'security_disclosure_%'
  on conflict (incident_id, obligation_code) do nothing;
  get diagnostics v_n = row_count;
  perform erp_meta.platform_log(
    v_staff, 'platform.incident_flagged_security', null, p_incident_code,
    format('%s disclosure obligation(s) dated from declaration', v_n), '{}'::jsonb);
  return v_n;
end;
$$;

comment on function erp.flag_security_incident is
  'Specification v1.2 §17.4: puts an incident on the disclosure path. Creates '
  'one obligation per published timeline, due from the declaration, for the '
  'platform as processor and the organisation as controller.';

create or replace function erp.record_disclosure(p_incident_code text, p_obligation_code text, p_note text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
  v_n     integer;
begin
  v_staff := erp_meta.require_platform('operator');
  select * into v_inc from erp_meta.incident i where i.code = p_incident_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_INCIDENT: %', p_incident_code using errcode = '23503';
  end if;
  if not v_inc.is_security then
    raise exception 'ERPWARE_NOT_A_SECURITY_INCIDENT: % has no disclosure path', p_incident_code
      using errcode = '23514', hint = 'Flag it as a security incident first.';
  end if;
  update erp_meta.incident_disclosure d
     set notified_at = coalesce(d.notified_at, now()),
         notified_by = coalesce(d.notified_by, v_staff.email),
         note = coalesce(nullif(btrim(p_note), ''), d.note)
   where d.incident_id = v_inc.id and d.obligation_code = p_obligation_code;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'ERPWARE_UNKNOWN_OBLIGATION: % is not a timeline on %', p_obligation_code, p_incident_code
      using errcode = '23503';
  end if;
  perform erp_meta.platform_log(
    v_staff, 'platform.disclosure_recorded', null, p_incident_code, p_obligation_code,
    jsonb_build_object('note', p_note));
end;
$$;

create or replace function erp.announce_maintenance(
  p_code text, p_title text, p_detail text,
  p_starts_at timestamptz, p_ends_at timestamptz,
  p_affects_all_tenants boolean,
  p_tenant_codes text[] default null,
  p_is_emergency boolean default false,
  p_emergency_reason text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_staff  erp_meta.platform_staff;
  v_hours  integer;
  v_id     uuid;
  v_code   text; v_tenant erp.tenant%rowtype;
begin
  v_staff := erp_meta.require_platform('operator');
  select n.hours into v_hours from erp_ref.notice_period n where n.code = 'planned_maintenance';

  -- §9.2 says the windows are published; §17.4 says maintenance is announced
  -- against them. An announcement inside the notice period is not an
  -- announcement, it is a surprise with a timestamp — unless it is an
  -- emergency, which says so and says why.
  if not coalesce(p_is_emergency, false)
     and p_starts_at < now() + make_interval(hours => v_hours) then
    raise exception
      'ERPWARE_MAINTENANCE_NOTICE_TOO_SHORT: planned maintenance is announced at least % hours ahead',
      v_hours
      using errcode = '23514',
            hint = 'Announce it as emergency maintenance with its reason, and it '
                   'reads as an emergency to every organisation it touches.';
  end if;
  if coalesce(p_is_emergency, false) and coalesce(btrim(p_emergency_reason), '') = '' then
    raise exception 'ERPWARE_EMERGENCY_HAS_NO_REASON: emergency maintenance states why'
      using errcode = '23514';
  end if;
  if not p_affects_all_tenants and coalesce(cardinality(p_tenant_codes), 0) = 0 then
    raise exception
      'ERPWARE_MAINTENANCE_AFFECTS_NOBODY: a window that is not for everyone names who it is for'
      using errcode = '23514';
  end if;

  insert into erp_meta.maintenance_window
    (code, title, detail, starts_at, ends_at, announced_by, is_emergency,
     emergency_reason, affects_all_tenants)
  values (p_code, p_title, p_detail, p_starts_at, p_ends_at, v_staff.email,
          coalesce(p_is_emergency, false), p_emergency_reason, p_affects_all_tenants)
  returning id into v_id;

  if not p_affects_all_tenants then
    foreach v_code in array p_tenant_codes loop
      select * into v_tenant from erp.tenant t where t.code = v_code;
      if not found then
        raise exception 'ERPWARE_UNKNOWN_TENANT: % is not an organisation on this deployment', v_code
          using errcode = '23503';
      end if;
      insert into erp_meta.maintenance_window_tenant (window_id, tenant_id, tenant_code)
      values (v_id, v_tenant.id, v_tenant.code);
    end loop;
  end if;

  perform erp_meta.platform_log(
    v_staff, 'platform.maintenance_announced', null, p_code, p_title,
    jsonb_build_object('starts_at', p_starts_at, 'ends_at', p_ends_at,
                       'emergency', coalesce(p_is_emergency, false),
                       'affects_all_tenants', p_affects_all_tenants,
                       'tenants', to_jsonb(coalesce(p_tenant_codes, '{}'))));
  return v_id;
end;
$$;

comment on function erp.announce_maintenance is
  'Specification v1.2 §17.4 against §9.2: announces a maintenance window. '
  'Refuses one inside the published notice period unless it is an emergency '
  'with a reason, and refuses one that is for nobody in particular.';

create or replace function erp.cancel_maintenance(p_code text, p_reason text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_staff erp_meta.platform_staff; v_n integer;
begin
  v_staff := erp_meta.require_platform('operator');
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'ERPWARE_CANCELLATION_HAS_NO_REASON: a cancelled window says why'
      using errcode = '23514';
  end if;
  update erp_meta.maintenance_window
     set cancelled_at = coalesce(cancelled_at, now()), cancel_reason = btrim(p_reason)
   where code = p_code;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'ERPWARE_UNKNOWN_MAINTENANCE_WINDOW: %', p_code using errcode = '23503';
  end if;
  perform erp_meta.platform_log(
    v_staff, 'platform.maintenance_cancelled', null, p_code, p_reason, '{}'::jsonb);
end;
$$;

-- ── What the console reads ───────────────────────────────────────────────────

create or replace function erp.maintenance_report()
returns table(code text, title text, detail text, starts_at timestamptz, ends_at timestamptz,
              announced_at timestamptz, announced_by text, is_emergency boolean,
              emergency_reason text, affects_all_tenants boolean, organisations text[],
              state text, notice_hours numeric, cancelled_at timestamptz, cancel_reason text)
language sql
stable
set search_path = ''
as $$
  select w.code, w.title, w.detail, w.starts_at, w.ends_at, w.announced_at, w.announced_by,
         w.is_emergency, w.emergency_reason, w.affects_all_tenants,
         coalesce((select array_agg(t.tenant_code order by t.tenant_code)
                     from erp_meta.maintenance_window_tenant t where t.window_id = w.id), '{}'),
         case when w.cancelled_at is not null then 'cancelled'
              when w.ends_at < now() then 'past'
              when w.starts_at <= now() then 'in_progress'
              else 'planned' end,
         round(extract(epoch from w.starts_at - w.announced_at) / 3600, 1),
         w.cancelled_at, w.cancel_reason
    from erp_meta.maintenance_window w
   order by w.starts_at desc
$$;

create or replace function erp.disclosure_report()
returns table(incident_code text, severity_code text, title text, is_security boolean,
              obligation_code text, obligation_title text, obliged_party text,
              due_at timestamptz, notified_at timestamptz, notified_by text, note text,
              overdue boolean, hours_left numeric)
language sql
stable
set search_path = ''
as $$
  select i.code, i.severity_code, i.title, i.is_security,
         n.code, n.title, n.obliged_party,
         d.due_at, d.notified_at, d.notified_by, d.note,
         d.notified_at is null and d.due_at < now(),
         round(extract(epoch from d.due_at - now()) / 3600, 1)
    from erp_meta.incident_disclosure d
    join erp_meta.incident i on i.id = d.incident_id
    join erp_ref.notice_period n on n.code = d.obligation_code
   order by i.declared_at desc, n.seq
$$;

-- ── What the organisation reads: its notices, and nobody else's ──────────────

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
    -- Named as affected: told from the moment the platform names it. Reaching
    -- everyone: told once containment said so, which is when scope is known.
    select i.*
      from erp_meta.incident i, me
     where (i.resolved_at is null or i.resolved_at >= now() - interval '30 days')
       and (exists (select 1 from erp_meta.incident_tenant t
                     where t.incident_id = i.id and t.tenant_id = me.tenant_id)
            or (i.contained_at is not null and coalesce(i.affects_all_tenants, false))))
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
               'updates', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'posted_at', u.posted_at, 'body', u.body,
                          'is_no_change', u.is_no_change)
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

comment on function erp.service_notices is
  'Specification v1.2 §17.3 and §17.4, from the organisation''s side: the '
  'maintenance windows that touch it, the incidents it was named in or that '
  'reached everyone once containment said so, with their updates, and its own '
  'disclosure obligations with the clock running. Security definer because '
  'erp_meta is platform-internal; scoped to the caller''s organisation by '
  'construction and returns nothing about any other.';

-- ── The discipline report, extended ─────────────────────────────────────────

create or replace function erp.support_discipline_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $function$
  -- §17.2: a severity with no stated response is a severity negotiated case by
  -- case, which is what "published" rules out.
  select 'a severity states no response or update cadence', s.code, s.name
    from erp_ref.support_severity s
   where s.response_within_minutes is null or s.update_every_minutes is null
  union all
  -- §17.2: the cadences must order with the severities. A severity 1 answered
  -- more slowly than a severity 3 is a scale that means nothing.
  select 'a more severe level is answered more slowly than a less severe one',
         a.code || ' vs ' || b.code,
         format('%s responds in %s minutes, %s in %s',
                a.code, a.response_within_minutes, b.code, b.response_within_minutes)
    from erp_ref.support_severity a
    join erp_ref.support_severity b on b.seq > a.seq
   where a.response_within_minutes > b.response_within_minutes
  union all
  -- §17.1: standing access does not exist. An unbounded grant is the shape it
  -- would take.
  select 'a support access has no expiry within a week of its grant',
         a.id::text, format('granted %s, expires %s', a.granted_at, a.expires_at)
    from erp.support_access a
   where a.expires_at > a.granted_at + interval '7 days'
  union all
  -- §17.1: a write performed under read-only access.
  select 'a support action was recorded against read-only access',
         act.id::text, act.action
    from erp.support_action act
    join erp.support_access acc
      on acc.tenant_id = act.tenant_id and acc.id = act.support_access_id
   where act.is_write and not acc.is_write_access
  union all
  -- §17.3: an incident declared without all three roles.
  select 'an incident names no commander, communications owner or scribe',
         i.code, i.title
    from erp_meta.incident i
   where coalesce(btrim(i.commander), '') = ''
      or coalesce(btrim(i.communications_owner), '') = ''
      or coalesce(btrim(i.scribe), '') = ''
  union all
  -- §17.3: a resolved severity 1 or 2 with no review.
  select 'a resolved severity 1 or 2 incident has no post-incident review',
         i.code, i.severity_code
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
   where s.requires_review and i.resolved_at is not null
     and (i.review_url is null or i.review_completed_at is null)
  union all
  -- §17.3: communication on a timer.
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
  -- §17.3: "never silence toward affected ones". An incident contained as
  -- reaching some organisations and not all, with none named, is scoped to
  -- nobody: the affected are told nothing and cannot know they are affected.
  select 'a contained incident is scoped to some organisations and names none',
         i.code, i.scope
    from erp_meta.incident i
   where i.contained_at is not null
     and i.affects_all_tenants is false
     and not exists (select 1 from erp_meta.incident_tenant t where t.incident_id = i.id)
  union all
  -- §17.4: a security incident on no disclosure path.
  select 'a security incident has no disclosure obligations dated',
         i.code, i.title
    from erp_meta.incident i
   where i.is_security
     and not exists (select 1 from erp_meta.incident_disclosure d where d.incident_id = i.id)
  union all
  -- §17.4: a stated timeline the platform let pass. The organisation's own
  -- obligations are shown to it rather than failed here; the platform cannot
  -- record what a controller told its regulator.
  select 'the platform''s disclosure deadline passed unrecorded',
         i.code, format('%s was due %s', d.obligation_code, d.due_at)
    from erp_meta.incident_disclosure d
    join erp_meta.incident i on i.id = d.incident_id
    join erp_ref.notice_period n on n.code = d.obligation_code
   where n.obliged_party = 'platform' and d.notified_at is null and d.due_at < now()
  order by 1, 2
$function$;

create or replace function erp.assert_support_discipline()
returns text
language plpgsql
stable
set search_path = ''
as $function$
declare
  v_count integer; v_detail text; v_sev integer; v_periods integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.support_discipline_report();
  if v_count > 0 then
    raise exception 'ERPWARE_SUPPORT_DISCIPLINE: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§17: a capability without a discipline is a liability.';
  end if;
  select count(*) into v_sev from erp_ref.support_severity;
  select count(*) into v_periods from erp_ref.notice_period;
  return format('support: %s severity level(s) and %s timeline(s) published, access time-bounded',
                v_sev, v_periods);
end;
$function$;

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_name_affected_organisations(p_incident_code text, p_tenant_codes text[])
returns integer language sql set search_path = '' as $$
  select erp.name_affected_organisations(p_incident_code, p_tenant_codes);
$$;

create or replace function public.erp_platform_flag_security_incident(p_incident_code text)
returns integer language sql set search_path = '' as $$
  select erp.flag_security_incident(p_incident_code);
$$;

create or replace function public.erp_platform_record_disclosure(p_incident_code text, p_obligation_code text, p_note text default null)
returns void language sql set search_path = '' as $$
  select erp.record_disclosure(p_incident_code, p_obligation_code, p_note);
$$;

create or replace function public.erp_platform_announce_maintenance(
  p_code text, p_title text, p_detail text, p_starts_at timestamptz, p_ends_at timestamptz,
  p_affects_all_tenants boolean, p_tenant_codes text[] default null,
  p_is_emergency boolean default false, p_emergency_reason text default null)
returns uuid language sql set search_path = '' as $$
  select erp.announce_maintenance(p_code, p_title, p_detail, p_starts_at, p_ends_at,
                                  p_affects_all_tenants, p_tenant_codes,
                                  p_is_emergency, p_emergency_reason);
$$;

create or replace function public.erp_platform_cancel_maintenance(p_code text, p_reason text)
returns void language sql set search_path = '' as $$
  select erp.cancel_maintenance(p_code, p_reason);
$$;

create or replace function public.erp_platform_maintenance_windows()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.starts_at desc), '[]'::jsonb)
    from erp.maintenance_report() r;
$$;

create or replace function public.erp_platform_disclosures()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from erp.disclosure_report() r;
$$;

create or replace function public.erp_platform_incident_organisations(p_incident_code text)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('tenant_code', t.tenant_code, 'named_at', t.named_at,
                                               'named_by', t.named_by)
                            order by t.tenant_code), '[]'::jsonb)
    from erp_meta.incident_tenant t
    join erp_meta.incident i on i.id = t.incident_id
   where i.code = p_incident_code;
$$;

create or replace function public.erp_service_notices()
returns jsonb language sql stable set search_path = '' as $$
  select erp.service_notices();
$$;

create or replace function public.erp_support_severities()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name, 'definition', s.definition,
                                               'response_within_minutes', s.response_within_minutes,
                                               'update_every_minutes', s.update_every_minutes,
                                               'requires_review', s.requires_review)
                            order by s.seq), '[]'::jsonb)
    from erp_ref.support_severity s;
$$;

create or replace function public.erp_notice_periods()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', n.code, 'title', n.title, 'hours', n.hours,
                                               'obliged_party', n.obliged_party, 'basis', n.basis)
                            order by n.seq), '[]'::jsonb)
    from erp_ref.notice_period n;
$$;

revoke all on function
  public.erp_platform_name_affected_organisations(text, text[]),
  public.erp_platform_flag_security_incident(text),
  public.erp_platform_record_disclosure(text, text, text),
  public.erp_platform_announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text),
  public.erp_platform_cancel_maintenance(text, text),
  public.erp_platform_maintenance_windows(),
  public.erp_platform_disclosures(),
  public.erp_platform_incident_organisations(text),
  public.erp_service_notices(),
  public.erp_notice_periods(),
  public.erp_support_severities()
  from public, anon;

grant execute on function
  public.erp_platform_name_affected_organisations(text, text[]),
  public.erp_platform_flag_security_incident(text),
  public.erp_platform_record_disclosure(text, text, text),
  public.erp_platform_announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text),
  public.erp_platform_cancel_maintenance(text, text),
  public.erp_platform_maintenance_windows(),
  public.erp_platform_disclosures(),
  public.erp_platform_incident_organisations(text),
  public.erp_service_notices(),
  public.erp_notice_periods(),
  public.erp_support_severities()
  to authenticated, service_role;

-- ── Registration ─────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_ref','notice_period','product_content',
   'Part 17 §17.4. The stated timelines: maintenance notice and disclosure deadlines, published.'),
  ('erp_meta','incident_tenant','platform_internal',
   'Part 17 §17.3. Which organisations an incident reached; what scopes communication.'),
  ('erp_meta','incident_disclosure','platform_internal',
   'Part 17 §17.4. One dated obligation per timeline for a security incident.'),
  ('erp_meta','maintenance_window','platform_internal',
   'Part 17 §17.4. Planned maintenance, announced against §9.2''s windows.'),
  ('erp_meta','maintenance_window_tenant','platform_internal',
   'Part 17 §17.4. Which organisations a window that is not for everyone is for.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_name_affected_organisations', 'erp.name_affected_organisations',
   'Names the organisations an incident reached. Gated by erp_meta.require_platform at operator; §17.3 scopes communication by it.'),
  ('erp_platform_flag_security_incident', 'erp.flag_security_incident',
   'Puts an incident on the disclosure path, dating every published timeline from its declaration. Operator.'),
  ('erp_platform_record_disclosure', 'erp.record_disclosure',
   'Records that the platform met one of its disclosure obligations. Operator; the record names who recorded it.'),
  ('erp_platform_announce_maintenance', 'erp.announce_maintenance',
   'Announces a maintenance window against the published notice period, refusing a short-notice one that is not an emergency with a reason. Operator.'),
  ('erp_platform_cancel_maintenance', 'erp.cancel_maintenance',
   'Cancels an announced window with a reason. Operator.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'service_notices',
   'Reads erp_meta.maintenance_window, erp_meta.incident and their scoping tables, all platform_internal and unreachable from a tenant session, and returns only what touches the caller''s own organisation: windows for it or for everyone, incidents it is named in or that reached everyone once contained, and its own obligations. §17.3 makes this a screen, not a request.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

update erp_meta.diagnostic_check set
  blurb = 'Part 17''s operating model: published severities whose cadences order with '
          'them, support access bounded within a week, no write under read-only '
          'access, incidents naming all three roles, no severity 1 or 2 resolved '
          'without a review, no contained incident scoped to nobody, and no '
          'platform disclosure deadline passed unrecorded.'
where code = 'support_discipline';

insert into erp_ref.resource (key, locale, value, description) values
('notice.maintenance_planned', 'en', 'Planned maintenance',
 '§17.4: planned maintenance announced against the published windows.'),
('notice.maintenance_emergency', 'en', 'Emergency maintenance',
 '§17.4: maintenance inside the notice period, announced with its reason.'),
('notice.incident_affects_you', 'en', 'This affects your organisation',
 '§17.3: communication scoped to the affected; an organisation is told because it was named.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Service notices'),
    ('Maintenance windows'),
    ('Nothing is planned. Maintenance is announced here at least two days ahead; an emergency says so and says why.'),
    ('Incidents affecting you'),
    ('No incident has been declared that reached this organisation. You are told here the moment the platform names you, never by a broadcast meant for somebody else.'),
    ('Your obligations'),
    ('Update'),
    ('No change'),
    ('Told'),
    ('Due'),
    ('Overdue'),
    ('Emergency'),
    ('Planned'),
    ('In progress'),
    ('Past'),
    ('Live'),
    ('Contained'),
    ('Resolved'),
    ('Security incident'),
    ('Data integrity'),
    ('Every organisation'),
    ('What the platform has promised about staying up, whether a drill has proved it, what has happened when it did not, and what you are being told about it.')
  ) t(text)
on conflict (key, locale) do nothing;

update erp_ref.help_topic set
  summary = 'What the platform has promised about staying up and getting back, what has happened when it did not, and what you are being told: maintenance windows that touch you, incidents you were named in with their updates, and your own disclosure obligations with the clock running.',
  steps = '["Read the notices first: a window announced ahead, an incident named against you, an obligation with a deadline.","A commitment reads as proved only when a drill actually restored and ran the assertions.","A live incident reads as overdue the moment it passes its severity''s update cadence.","Support access shows every occasion platform staff entered your data, by whom, when, for how long and why."]'
where screen_path = '/operations/continuity';

-- ── The decisions ────────────────────────────────────────────────────────────

update erp_meta.policy_decision set
  evidence = evidence || ' Scoped communication is built (20260904550000): erp_meta.incident_tenant '
             'names the organisations an incident reached, erp_service_notices() '
             'shows each organisation only what touches it, and the discipline '
             'report fails a contained incident scoped to nobody. The page '
             'outside would read the same register.'
where code = 'status_page_not_built';

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values
  ('disclosure_timelines_are_published',
   'Security disclosure follows stated timelines, from declaration',
   'v1.2 §17.4',
   'erp_ref.notice_period publishes the timelines: the platform tells an affected organisation within twenty-four hours as processor; the organisation as controller has seventy-two hours to its supervisory authority and tells affected individuals without undue delay where the risk is high. Flagging an incident as a security incident dates every one of them from the declaration, the platform records its own, and the organisation sees its own with the clock running.',
   '"Without undue delay" is a sentiment until somebody states a number, and Article 33(2) leaves the number to the processor. Stating twenty-four hours makes it a deadline the discipline report can fail. The controller''s obligations are the organisation''s and the platform cannot discharge them; what it can do is make sure the organisation is not the last to know the clock started, which is why the deadline is shown from the declaration and not from the moment the platform got round to telling them.',
   'accepted',
   'erp_ref.notice_period; erp.flag_security_incident(); erp.record_disclosure(); erp.support_discipline_report() fails a platform deadline passed unrecorded; erp_service_notices() shows the organisation its obligations; erp_test.service_notice_suite() proves the path.')
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.service_notice_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  ra record; rb record;
  ca text := 'zzsna-' || substr(md5(random()::text), 1, 6);
  cb text := 'zzsnb-' || substr(md5(random()::text), 1, 6);
  op uuid := gen_random_uuid();
  aa uuid := gen_random_uuid();
  ab uuid := gen_random_uuid();
  inc text := 'zzsn-inc';
  v_ok boolean; v_msg text; res jsonb; v_n integer;
begin
  insert into auth.users (id, email) values
    (op, 'op@zzsn.test'), (aa, 'a@zzsn.test'), (ab, 'b@zzsn.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('op@zzsn.test', op, 'Notice Operator', 'operator');

  select * into ra from erp.provision_tenant(ca, 'Affected Org', 'a@zzsn.test', 'A Admin');
  select * into rb from erp.provision_tenant(cb, 'Bystander Org', 'b@zzsn.test', 'B Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  perform erp.claim_invitation(ra.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  perform erp.claim_invitation(rb.admin_token);

  -- ── §17.3 scoped communication ────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.declare_incident(inc, 'sev2', 'Report runs failing for two organisations',
                               'A. Commander', 'B. Comms', 'C. Scribe');
  perform erp.post_incident_update(inc, 'We are looking at the report runner. Next update in two hours.');

  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'an incident nobody has been named in reaches no organisation',
    jsonb_array_length(res -> 'incidents') = 0, 'declared, not yet scoped: nobody alarmed';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  v_n := erp.name_affected_organisations(inc, array[ca]);
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'the organisation named as affected is told, with the updates',
    v_n = 1 and jsonb_array_length(res -> 'incidents') = 1
    and res -> 'incidents' -> 0 ->> 'code' = inc
    and jsonb_array_length(res -> 'incidents' -> 0 -> 'updates') = 1,
    res -> 'incidents' -> 0 ->> 'title';

  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  res := erp.service_notices();
  return query select 'and the bystander is not',
    jsonb_array_length(res -> 'incidents') = 0, 'never a broadcast that alarms the unaffected';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.name_affected_organisations(inc, array['no-such-org']);
    v_ok := false; v_msg := 'an organisation that does not exist was named';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_TENANT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'naming an organisation that does not exist is refused', v_ok, v_msg;

  perform erp.contain_incident(inc, 'The report runner, all organisations', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  res := erp.service_notices();
  return query select 'containment that reached everyone tells everyone',
    jsonb_array_length(res -> 'incidents') = 1
    and (res -> 'incidents' -> 0 ->> 'affects_all_tenants')::boolean,
    'scope is known after containment, and communication follows it';

  -- A second incident contained as partial with nobody named is the silence
  -- §17.3 forbids, and the discipline report says so.
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.declare_incident(inc || '-2', 'sev3', 'Slow label rendering at one site',
                               'A', 'B', 'C');
  perform erp.contain_incident(inc || '-2', 'One organisation''s label printer', false);
  return query select 'a contained incident scoped to some and naming none is a finding',
    exists (select 1 from erp.support_discipline_report() f
             where f.finding like 'a contained incident is scoped to some%' and f.reference = inc || '-2'),
    'silence toward the affected, found rather than assumed';
  perform erp.name_affected_organisations(inc || '-2', array[cb]);
  return query select 'and naming them clears it',
    not exists (select 1 from erp.support_discipline_report() f
                 where f.reference = inc || '-2'), 'named';

  -- ── §17.4 planned maintenance against the notice period ──────────────────

  begin
    perform erp.announce_maintenance('zzsn-win-short', 'Tonight', 'Database restart',
                                     now() + interval '2 hours', now() + interval '3 hours', true);
    v_ok := false; v_msg := 'a two-hour notice was accepted as planned maintenance';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_MAINTENANCE_NOTICE_TOO_SHORT%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'planned maintenance inside the notice period is refused', v_ok, v_msg;

  begin
    perform erp.announce_maintenance('zzsn-win-em', 'Now', 'Failing disk',
                                     now() + interval '10 minutes', now() + interval '40 minutes',
                                     true, null, true, null);
    v_ok := false; v_msg := 'an emergency with no reason was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_EMERGENCY_HAS_NO_REASON%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'emergency maintenance without a reason is refused', v_ok, v_msg;

  perform erp.announce_maintenance('zzsn-win-em', 'Storage replacement', 'Failing disk on the primary',
                                   now() + interval '10 minutes', now() + interval '40 minutes',
                                   true, null, true, 'A disk is failing and will not last the notice period.');
  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  res := erp.service_notices();
  return query select 'an emergency with its reason is announced and reads as one',
    exists (select 1 from jsonb_array_elements(res -> 'maintenance') w
             where w ->> 'code' = 'zzsn-win-em' and (w ->> 'is_emergency')::boolean),
    'emergency, with its reason, to everyone';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.announce_maintenance('zzsn-win-nobody', 'For nobody', null,
                                     now() + interval '3 days', now() + interval '3 days 1 hour', false);
    v_ok := false; v_msg := 'a window for nobody in particular was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_MAINTENANCE_AFFECTS_NOBODY%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a window that is not for everyone names who it is for', v_ok, v_msg;

  perform erp.announce_maintenance('zzsn-win-a', 'Index rebuild', 'Reporting slower for an hour',
                                   now() + interval '3 days', now() + interval '3 days 1 hour',
                                   false, array[ca]);
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  v_ok := exists (select 1 from jsonb_array_elements(res -> 'maintenance') w where w ->> 'code' = 'zzsn-win-a');
  perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
  res := erp.service_notices();
  return query select 'a window for one organisation is shown to it and not to another',
    v_ok and not exists (select 1 from jsonb_array_elements(res -> 'maintenance') w where w ->> 'code' = 'zzsn-win-a'),
    'scoped like an incident';

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.cancel_maintenance('zzsn-win-a', '  ');
    v_ok := false; v_msg := 'a cancellation with no reason was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CANCELLATION_HAS_NO_REASON%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a cancelled window says why', v_ok, v_msg;
  perform erp.cancel_maintenance('zzsn-win-a', 'Rebuilt online instead.');
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'and a cancelled window is no longer a notice',
    not exists (select 1 from jsonb_array_elements(res -> 'maintenance') w where w ->> 'code' = 'zzsn-win-a'),
    'cancelled';

  -- ── §17.4 the disclosure path ─────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform erp.record_disclosure(inc, 'security_disclosure_to_organisation', 'told');
    v_ok := false; v_msg := 'a disclosure was recorded on an incident with no path';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NOT_A_SECURITY_INCIDENT%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a disclosure cannot be recorded before the incident is on the path', v_ok, v_msg;

  v_n := erp.flag_security_incident(inc);
  return query select 'flagging a security incident dates every published timeline from its declaration',
    v_n = 3
    and (select count(*) from erp.disclosure_report() d where d.incident_code = inc
           and d.due_at = (select i.declared_at from erp_meta.incident i where i.code = inc)
                          + make_interval(hours => (select n.hours from erp_ref.notice_period n where n.code = d.obligation_code))) = 3,
    format('%s obligation(s)', v_n);

  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'the organisation sees its own obligations with the clock running',
    (select count(*) from jsonb_array_elements(res -> 'incidents' -> 0 -> 'obligations') o
      where o ->> 'obliged_party' = 'organisation') = 2
    and (res -> 'incidents' -> 0 ->> 'is_security')::boolean,
    'to the authority and to the people affected, both dated';

  -- The platform's deadline passes unrecorded: the report says so, then it is
  -- recorded and the finding clears.
  update erp_meta.incident_disclosure d set due_at = now() - interval '1 hour'
   where d.incident_id = (select i.id from erp_meta.incident i where i.code = inc)
     and d.obligation_code = 'security_disclosure_to_organisation';
  return query select 'a platform deadline passed unrecorded is a finding',
    exists (select 1 from erp.support_discipline_report() f
             where f.finding like 'the platform''s disclosure deadline%' and f.reference = inc),
    'stated timelines are failed, not remembered';
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.record_disclosure(inc, 'security_disclosure_to_organisation', 'Email to both administrators.');
  return query select 'and recording the disclosure clears it',
    not exists (select 1 from erp.support_discipline_report() f
                 where f.finding like 'the platform''s disclosure deadline%' and f.reference = inc)
    and (select d.notified_by from erp.disclosure_report() d
          where d.incident_code = inc and d.obligation_code = 'security_disclosure_to_organisation') = 'op@zzsn.test',
    'recorded, by whom';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.incident where code like 'zzsn-%';
  delete from erp_meta.maintenance_window where code like 'zzsn-%';
  perform erp.begin_tenant_purge(ra.tenant_id);
  delete from erp.tenant where id = ra.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(rb.tenant_id);
  delete from erp.tenant where id = rb.tenant_id;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzsn.test';
  delete from auth.users where id in (op, aa, ab);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id in (ra.tenant_id, rb.tenant_id))
    and not exists (select 1 from erp_meta.incident where code like 'zzsn-%')
    and not exists (select 1 from erp_meta.maintenance_window where code like 'zzsn-%')
    and not exists (select 1 from erp_meta.platform_staff where email like '%@zzsn.test'),
    'organisations, incidents, windows and staff gone';
end;
$$;

create or replace function erp_test.assert_service_notice_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _service_notice_result on commit drop as
    select * from erp_test.service_notice_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _service_notice_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_SERVICE_NOTICE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('service notices: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_service_notice_suite();

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
select erp.assert_no_dead_configuration();
select erp.assert_support_discipline();
select erp.assert_diagnostics_registered();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
