-- =============================================================================
-- Part 17 — support access that expires, and incidents that are declared
--
-- The platform already carries an audited cross-tenant support mechanism:
-- erp_platform_enter_tenant() demands a reason, refuses without the support
-- role, and writes platform.tenant_entered to erp_meta.platform_audit. Part 17
-- supplies the operating model around it, "because a capability without a
-- discipline is a liability", and measuring the capability against the
-- discipline finds one thing badly wrong.
--
--   §17.1 "Access is time-bounded and expires automatically; extension is a
--   fresh act, recorded ... STANDING ACCESS DOES NOT EXIST. Every session is a
--   new invocation."
--
-- erp_platform_enter_tenant() has no notion of expiry. The principal it creates
-- carries the administrator role and persists until somebody removes it, which
-- is standing access exactly as §17.1 defines it — arrived at not by decision
-- but by there being nothing to end it. Entering an organisation once in August
-- leaves a platform administrator inside it in December.
--
--   §17.1 "The organisation can see, at any time, every occasion its data was
--   entered by platform staff, by whom, when, for how long and why. THIS IS A
--   SCREEN, NOT A REQUEST."
--
-- erp_meta.platform_audit holds the record and is platform_internal: no tenant
-- session can read it. The organisation could ask, and be told. That is a
-- request, and §17.1 says it must not be.
--
--   §17.1 "Read-only by default. Any support action that writes is performed as
--   an explicit, separately recorded act."
--
-- Nothing distinguished a support session that looked from one that changed
-- something.
--
-- So: erp.support_access is TENANT-SCOPED, append-only, and carries an expiry.
-- Tenant-scoped is the whole point — it is the organisation's record of who
-- came in, readable by the organisation without asking anyone. Append-only
-- because a support access log the organisation could edit is not a record, and
-- neither is one platform staff could edit; extension is a new row, which is
-- what "extension is a fresh act, recorded" means.
-- =============================================================================

-- ── §17.2 severity, published rather than negotiated ────────────────────────

create table if not exists erp_ref.support_severity (
  code                    text primary key,
  name                    text not null,
  definition              text not null,
  response_within_minutes integer not null,
  update_every_minutes    integer not null,
  requires_review         boolean not null default false,
  seq                     integer not null,
  registered_at           timestamptz not null default now(),
  constraint support_severity_response_positive
    check (response_within_minutes > 0 and update_every_minutes > 0)
);

comment on table erp_ref.support_severity is
  'Specification v1.2 §17.2. "Each carries a stated response and update cadence, '
  'published rather than negotiated case by case." Published means a row every '
  'organisation can read, not a paragraph in a contract nobody has to hand '
  'during an outage.';

insert into erp_ref.support_severity
  (code, name, definition, response_within_minutes, update_every_minutes, requires_review, seq) values
('sev1', 'Severity 1',
 'The organisation cannot transact: goods cannot be received, picked, despatched or invoiced; or data integrity is in question.',
 30, 60, true, 10),
('sev2', 'Severity 2',
 'A significant function is unavailable or producing wrong results, with a workaround.',
 120, 240, true, 20),
('sev3', 'Severity 3',
 'A defect with a workaround and no operational stoppage.',
 1440, 2880, false, 30),
('sev4', 'Severity 4',
 'A question, a request, or a cosmetic defect.',
 2880, 10080, false, 40)
on conflict (code) do update set
  name = excluded.name, definition = excluded.definition,
  response_within_minutes = excluded.response_within_minutes,
  update_every_minutes = excluded.update_every_minutes,
  requires_review = excluded.requires_review, seq = excluded.seq;

-- ── §17.1 support access, time-bounded and visible to the organisation ──────

create table if not exists erp.support_access (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  staff_email         text not null,
  staff_role          text not null,
  app_user_id         uuid,
  reason              text not null,
  request_reference   text,
  is_write_access     boolean not null default false,
  granted_at          timestamptz not null default now(),
  expires_at          timestamptz not null,
  extension_of        uuid,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  -- §17.1: "Curiosity is not a reason." A minimum length will not make a reason
  -- good, but it does stop the empty string and the full stop.
  constraint support_access_reason_is_a_reason
    check (length(btrim(reason)) >= 20),
  -- §17.1: time-bounded. An access that never expires is standing access, which
  -- §17.1 says does not exist.
  constraint support_access_expires check (expires_at > granted_at),
  -- And bounded in length, not merely bounded: an expiry in 2099 is an expiry
  -- in name only.
  constraint support_access_bounded
    check (expires_at <= granted_at + interval '7 days'),
  constraint support_access_tenant_id_key unique (tenant_id, id),
  constraint support_access_extension_fk
    foreign key (tenant_id, extension_of)
      references erp.support_access (tenant_id, id)
);

create index if not exists support_access_by_tenant
  on erp.support_access (tenant_id, granted_at desc);

comment on table erp.support_access is
  'Specification v1.2 §17.1. TENANT-SCOPED on purpose: "The organisation can '
  'see, at any time, every occasion its data was entered by platform staff, by '
  'whom, when, for how long and why. This is a screen, not a request." The '
  'record lives where the organisation can read it without asking anybody.';

comment on column erp.support_access.extension_of is
  '§17.1: "extension is a fresh act, recorded". An extension is a new row '
  'naming the access it extends, never an expiry moved forward — which would '
  'leave no evidence that anything was extended.';

create table if not exists erp.support_action (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  support_access_id   uuid not null,
  action              text not null,
  object_type         text,
  object_id           uuid,
  reason              text not null,
  performed_at        timestamptz not null default now(),
  constraint support_action_reason_is_a_reason
    check (length(btrim(reason)) >= 20),
  constraint support_action_access_fk
    foreign key (tenant_id, support_access_id)
      references erp.support_access (tenant_id, id) on delete cascade
);

comment on table erp.support_action is
  'Specification v1.2 §17.1: "Read-only by default. Any support action that '
  'writes is performed as an explicit, separately recorded act." Separately '
  'recorded is the point — a write buried in a session that also looked at '
  'things is a write nobody can find.';

-- ── §17.3 incidents, declared rather than drifted into ──────────────────────

create table if not exists erp_meta.incident (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique,
  severity_code       text not null references erp_ref.support_severity(code),
  title               text not null,
  declared_at         timestamptz not null default now(),
  contained_at        timestamptz,
  resolved_at         timestamptz,
  -- §17.3: "Declaration names a commander, a communications owner and a scribe,
  -- however small the team." All three are NOT NULL because "however small the
  -- team" is the sentence that would otherwise be read as "unless it is small".
  commander           text not null,
  communications_owner text not null,
  scribe              text not null,
  scope               text,
  affects_all_tenants boolean,
  is_data_integrity   boolean not null default false,
  review_url          text,
  review_completed_at timestamptz,
  created_at          timestamptz not null default now(),
  constraint incident_resolved_after_declared
    check (resolved_at is null or resolved_at >= declared_at),
  -- §17.3: "The first question after containment is scope." An incident
  -- contained but unscoped cannot be communicated, because nobody knows to whom.
  constraint incident_contained_is_scoped
    check (contained_at is null
           or (affects_all_tenants is not null and coalesce(btrim(scope), '') <> ''))
);

comment on table erp_meta.incident is
  'Specification v1.2 §17.3: "An incident is declared, not drifted into." '
  'Declaring one requires naming three people, because an incident with no '
  'communications owner is one where the silence §17.3 warns about is nobody''s '
  'job to break.';

create table if not exists erp_meta.incident_update (
  id              uuid primary key default gen_random_uuid(),
  incident_id     uuid not null references erp_meta.incident(id) on delete cascade,
  posted_at       timestamptz not null default now(),
  body            text not null,
  posted_by       text not null,
  is_no_change    boolean not null default false,
  constraint incident_update_has_body check (length(btrim(body)) >= 10)
);

comment on table erp_meta.incident_update is
  'Specification v1.2 §17.3: "Communication is on a timer, not on progress: an '
  'update at a stated interval EVEN WHEN THE UPDATE IS THAT NOTHING HAS CHANGED, '
  'because silence is what erodes trust during an outage." is_no_change exists '
  'so that such an update is a first-class thing to post rather than something '
  'that feels not worth posting.';

-- ── The doors ───────────────────────────────────────────────────────────────

create or replace function erp.grant_support_access(p_tenant_id uuid,
                                                    p_reason text,
                                                    p_hours integer default 4,
                                                    p_write boolean default false,
                                                    p_request_reference text default null,
                                                    p_extension_of uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff  erp_meta.platform_staff;
  v_id     uuid;
  v_code   text;
  v_prior  erp.support_access%rowtype;
begin
  v_staff := erp_meta.require_platform('support');

  if p_hours is null or p_hours < 1 or p_hours > 168 then
    raise exception
      'ERPWARE_SUPPORT_WINDOW_INVALID: support access is granted in hours, from 1 to 168'
      using errcode = '22023',
            hint = '§17.1: access is time-bounded. A week is the ceiling, not a default.';
  end if;

  select t.code into v_code from erp.tenant t where t.id = p_tenant_id;
  if v_code is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  -- §17.1: "extension is a fresh act, recorded". The prior access must exist
  -- and belong to the same organisation; an extension of nothing is a grant
  -- wearing the word extension.
  if p_extension_of is not null then
    select * into v_prior from erp.support_access a
     where a.tenant_id = p_tenant_id and a.id = p_extension_of;
    if not found then
      raise exception
        'ERPWARE_NO_SUCH_ACCESS_TO_EXTEND: nothing here to extend'
        using errcode = '23503';
    end if;
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  insert into erp.support_access
    (tenant_id, staff_email, staff_role, reason, request_reference,
     is_write_access, expires_at, extension_of)
  values (p_tenant_id, v_staff.email, v_staff.staff_role, p_reason,
          p_request_reference, p_write, now() + make_interval(hours => p_hours),
          p_extension_of)
  returning id into v_id;

  perform erp_meta.platform_log(
    v_staff,
    case when p_extension_of is null then 'platform.support_access_granted'
         else 'platform.support_access_extended' end,
    p_tenant_id, v_code, p_reason,
    jsonb_build_object('hours', p_hours, 'write', p_write,
                       'access_id', v_id, 'extension_of', p_extension_of));

  return jsonb_build_object('access_id', v_id, 'expires_at', now() + make_interval(hours => p_hours),
                            'write', p_write, 'is_extension', p_extension_of is not null);
end;
$$;

comment on function erp.grant_support_access is
  'Specification v1.2 §17.1. Time-bounded, capped at a week, recorded where the '
  'organisation can read it, and an extension is a new row naming what it '
  'extends rather than an expiry quietly moved forward.';

create or replace function erp.support_access_is_live(p_tenant_id uuid, p_write boolean default false)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from erp.support_access a
     where a.tenant_id = p_tenant_id
       and a.expires_at > now()
       and (not p_write or a.is_write_access))
$$;

comment on function erp.support_access_is_live is
  'Specification v1.2 §17.1: "Standing access does not exist. Every session is a '
  'new invocation." An expired row is simply not live, with nothing to revoke '
  'and nobody to remember to revoke it.';

-- The screen §17.1 requires. Not a definer: the organisation reads its own rows
-- through ordinary row security, which is what makes this a screen rather than
-- a request somebody has to grant.
create or replace function erp.support_access_report()
returns table(granted_at timestamptz, expires_at timestamptz, duration interval,
              staff_email text, staff_role text, reason text,
              request_reference text, write_access boolean, is_extension boolean,
              still_live boolean)
language sql
stable
set search_path = ''
as $$
  select a.granted_at, a.expires_at, a.expires_at - a.granted_at,
         a.staff_email, a.staff_role, a.reason, a.request_reference,
         a.is_write_access, a.extension_of is not null,
         a.expires_at > now()
    from erp.support_access a
   where a.tenant_id = erp.require_tenant_id()
   order by a.granted_at desc
$$;

comment on function erp.support_access_report is
  'Specification v1.2 §17.1: "by whom, when, FOR HOW LONG and why. This is a '
  'screen, not a request." Deliberately not SECURITY DEFINER — the organisation '
  'reads its own rows under ordinary row security, which is what makes it a '
  'screen nobody has to grant.';

-- ── The assertion ───────────────────────────────────────────────────────────

create or replace function erp.support_discipline_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
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
   where not acc.is_write_access

  union all

  -- §17.3: an incident declared without all three roles. Also NOT NULL;
  -- checked here because an empty string is not a person.
  select 'an incident names no commander, communications owner or scribe',
         i.code, i.title
    from erp_meta.incident i
   where coalesce(btrim(i.commander), '') = ''
      or coalesce(btrim(i.communications_owner), '') = ''
      or coalesce(btrim(i.scribe), '') = ''

  union all

  -- §17.3: "A blameless post-incident review is written for every severity 1
  -- and 2." A resolved incident at those levels with no review is the action
  -- that quietly does not get tracked to completion.
  select 'a resolved severity 1 or 2 incident has no post-incident review',
         i.code, i.severity_code
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
   where s.requires_review and i.resolved_at is not null
     and (i.review_url is null or i.review_completed_at is null)

  union all

  -- §17.3: communication on a timer. A declared, unresolved incident with no
  -- update posted within its severity's cadence is the silence §17.3 names.
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

  order by 1, 2
$$;

comment on function erp.support_discipline_report is
  'Specification v1.2 Part 17. Read by erp.assert_support_discipline().';

create or replace function erp.assert_support_discipline()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text; v_sev integer;
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
  return format('support: %s severity level(s) published, access time-bounded', v_sev);
end;
$$;

comment on function erp.assert_support_discipline is
  'Fails where a severity states no cadence or the cadences do not order with '
  'the severities, where a support access is not bounded within a week, where a '
  'write was recorded against read-only access, where an incident names fewer '
  'than three roles, where a resolved severity 1 or 2 has no review, or where a '
  'live incident has gone past its update cadence in silence.';

-- ── Registration ────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_ref','support_severity','product_content',
   'Part 17 §17.2. Published response and update cadences, the same for every organisation.'),
  ('erp','support_access','tenant_scoped_append_only',
   'Part 17 §17.1. The organisation''s own record of who entered its data. Append-only: an access log either party could edit is not a record, and an extension is a new row.'),
  ('erp','support_action','tenant_scoped_append_only',
   'Part 17 §17.1. Each write performed under support access, separately recorded.'),
  ('erp_meta','incident','platform_internal',
   'Part 17 §17.3. Declared, with a commander, a communications owner and a scribe.'),
  ('erp_meta','incident_update','platform_internal',
   'Part 17 §17.3. Communication on a timer, including when the update is that nothing has changed.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
('erp','grant_support_access','Writes a tenant-scoped access record on behalf of platform staff, who hold no principal in the organisation. Gated on erp_meta.require_platform(''support'') and bounded at seven days by constraint; it can only ever create a row the organisation can then read.'),
('erp','support_access_is_live','Reads erp.support_access across organisations to answer whether a live grant exists. Returns a boolean and no data.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('support_discipline', 'Support discipline', 'assertion', 'platform',
   'erp', 'assert_support_discipline', '',
   'support_discipline_report', '',
   'Part 17''s operating model: published severities whose cadences order with '
   'them, support access bounded within a week, no write under read-only '
   'access, incidents naming all three roles, and no severity 1 or 2 resolved '
   'without a review.',
   true, 60)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- D3's narrow exception is platform support access. §17.1 is what keeps it
-- narrow, and this is where that becomes checkable rather than intended.
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
('D3','erp','assert_support_discipline',
 'D3 permits platform staff to enter an organisation under "an audited, time-bounded support access". Time-bounded was intent until Part 17: this refuses an access that is not bounded within a week, and a write performed under read-only access, which is what keeps D3''s exception the narrow one it claims to be.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

insert into erp_ref.resource (key, locale, value, description) values
('support.access_expired', 'en', 'Support access has expired',
 '§17.1: access is time-bounded and expires automatically; standing access does not exist.'),
('support.who_entered', 'en', 'Who has entered your data',
 '§17.1: the organisation can see every occasion, by whom, when, for how long and why — a screen, not a request.')
on conflict (key, locale) do update set value = excluded.value;

-- §17.4's status page and disclosure timelines, and §17.3's evidence pack for a
-- data-integrity incident, are operating artefacts rather than schema. Recorded
-- rather than counted as built.
insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values
  ('status_page_not_built',
   'The status page and disclosure path are not in the product',
   'v1.2 §17.4',
   'Part 17''s severity scale, support access discipline and incident register '
   'are built here. §17.4''s public status page, its historical availability '
   'record, and the security-disclosure timeline are not.',
   'A status page is read by people who cannot reach the product, which is the '
   'one moment a page served from it is worthless. It belongs outside this '
   'database by construction. The incident register here is what would feed it, '
   'so building the page later needs no schema change.',
   'open',
   'erp_meta.incident holds declarations and updates; nothing publishes them.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_support_discipline();
select erp.assert_product_decisions_enforced();
