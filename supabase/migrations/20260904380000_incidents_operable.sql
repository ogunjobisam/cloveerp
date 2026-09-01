-- =============================================================================
-- An incident register somebody can actually run an incident from
--
-- The open decision status_page_not_built says §17.4's public status page is
-- not built, and gives the right reason: "A status page is read by people who
-- cannot reach the product, which is the one moment a page served from it is
-- worthless. It belongs outside this database by construction."
--
-- That is correct and stands. A status page served from the product's own
-- Postgres goes dark exactly when somebody needs it, and nothing in this
-- migration changes that.
--
-- The sentence after it is the problem. "The incident register here is what
-- would feed it, so building the page later needs no schema change." The
-- register cannot be fed. erp_meta.incident and erp_meta.incident_update are
-- touched by exactly two functions in the whole database:
-- erp.support_discipline_report(), which checks the tables against themselves,
-- and the Part 17 suite, which INSERTs into them directly. Nothing declares an
-- incident, posts an update, contains one or resolves one.
--
-- erp.support_action is the same shape one level along. §17.1 makes support
-- access "time-bounded, reasoned, and logged"; erp.grant_support_access()
-- builds the bound and the reason, and nothing writes the log. The discipline
-- report already has a finding for "a support action was recorded against
-- read-only access" — a finding about rows that no code path could create.
--
-- And none of Part 16 or Part 17 was reachable from the platform console.
-- Twenty-seven erp_platform_* doors, and not one for a continuity commitment,
-- a restore drill, an incident or a support grant.
--
-- So: the page stays outside, and the register it would read becomes something
-- an operator can run an incident from. The writers refuse at declaration time
-- what erp.support_discipline_report() would otherwise report afterwards,
-- because during an incident is the wrong moment to discover that the record of
-- it is malformed.
-- =============================================================================

-- ── §17.3 declaring, and the three roles that make it a response ────────────

create or replace function erp.declare_incident(p_code text,
                                                 p_severity_code text,
                                                 p_title text,
                                                 p_commander text,
                                                 p_communications_owner text,
                                                 p_scribe text,
                                                 p_is_data_integrity boolean default false,
                                                 p_scope text default null,
                                                 p_affects_all_tenants boolean default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_id    uuid;
begin
  v_staff := erp_meta.require_platform('operator');

  if not exists (select 1 from erp_ref.support_severity s where s.code = p_severity_code) then
    raise exception 'ERPWARE_UNKNOWN_SEVERITY: % is not a published severity', p_severity_code
      using errcode = '23503',
            hint = '§17.2: the scale is published, which is what stops it being '
                   'negotiated case by case while people are shouting.';
  end if;

  -- §17.3 names three roles, and the report fails an incident missing any of
  -- them. A blank string satisfies NOT NULL and is not a person.
  if coalesce(btrim(p_commander), '') = ''
     or coalesce(btrim(p_communications_owner), '') = ''
     or coalesce(btrim(p_scribe), '') = '' then
    raise exception
      'ERPWARE_INCIDENT_ROLES_UNFILLED: an incident needs a commander, a '
      'communications owner and a scribe'
      using errcode = '23514',
            hint = 'One person may hold more than one, but the role must name '
                   'somebody. Deciding who is writing things down at three in '
                   'the morning is what this prevents.';
  end if;

  insert into erp_meta.incident
    (code, severity_code, title, commander, communications_owner, scribe,
     is_data_integrity, scope, affects_all_tenants)
  values (p_code, p_severity_code, p_title, btrim(p_commander),
          btrim(p_communications_owner), btrim(p_scribe),
          coalesce(p_is_data_integrity, false), p_scope, p_affects_all_tenants)
  returning id into v_id;

  perform erp_meta.platform_log(
    v_staff, 'platform.incident_declared', null, p_code, p_title,
    jsonb_build_object('severity', p_severity_code,
                       'commander', p_commander,
                       'data_integrity', coalesce(p_is_data_integrity, false)));

  return v_id;
end;
$$;

comment on function erp.declare_incident is
  'Specification v1.2 §17.3. Refuses an unpublished severity and an unfilled '
  'role, both of which erp.support_discipline_report() would otherwise report '
  'after the fact — and after the fact, during an incident, is when nobody is '
  'reading reports.';

create or replace function erp.post_incident_update(p_code text,
                                                     p_body text,
                                                     p_is_no_change boolean default false)
returns uuid
language plpgsql
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
    raise exception 'ERPWARE_UNKNOWN_INCIDENT: %', p_code using errcode = '23503';
  end if;

  if v_inc.resolved_at is not null then
    raise exception 'ERPWARE_INCIDENT_RESOLVED: % was resolved at %',
      p_code, v_inc.resolved_at
      using errcode = '23514',
            hint = 'The record of a resolved incident is what the review reads. '
                   'Adding to it afterwards rewrites what people were told.';
  end if;

  -- §17.3's cadence is a promise to keep talking, and "no change" is a real
  -- update — it is the one people stop sending, which is how a channel goes
  -- quiet without anybody deciding to stop.
  insert into erp_meta.incident_update (incident_id, body, posted_by, is_no_change)
  values (v_inc.id, p_body, v_staff.email, coalesce(p_is_no_change, false))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.post_incident_update is
  'Specification v1.2 §17.3, communication on a timer. Refuses an update to a '
  'resolved incident, because the record is what the post-incident review reads '
  'and appending to it afterwards rewrites what people were told at the time.';

create or replace function erp.contain_incident(p_code text,
                                                 p_scope text,
                                                 p_affects_all_tenants boolean)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
begin
  v_staff := erp_meta.require_platform('operator');

  select * into v_inc from erp_meta.incident i where i.code = p_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_INCIDENT: %', p_code using errcode = '23503';
  end if;

  -- The table already refuses containment without a scope. Saying so here
  -- names the thing that is missing rather than the constraint that noticed.
  if coalesce(btrim(p_scope), '') = '' or p_affects_all_tenants is null then
    raise exception
      'ERPWARE_CONTAINMENT_HAS_NO_SCOPE: containment states who was affected'
      using errcode = '23514',
            hint = 'Declaring an incident contained without saying what it '
                   'reached is the shape of a containment nobody can verify.';
  end if;

  update erp_meta.incident
     set contained_at = coalesce(contained_at, now()),
         scope = p_scope, affects_all_tenants = p_affects_all_tenants
   where id = v_inc.id;

  perform erp_meta.platform_log(
    v_staff, 'platform.incident_contained', null, p_code, p_scope,
    jsonb_build_object('affects_all_tenants', p_affects_all_tenants));
end;
$$;

comment on function erp.contain_incident is
  'Specification v1.2 §17.3. Containment that does not say who was affected is '
  'a claim nobody can check, so scope and reach are the price of the timestamp.';

create or replace function erp.resolve_incident(p_code text,
                                                 p_review_url text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_staff  erp_meta.platform_staff;
  v_inc    erp_meta.incident%rowtype;
  v_review boolean;
begin
  v_staff := erp_meta.require_platform('operator');

  select * into v_inc from erp_meta.incident i where i.code = p_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_INCIDENT: %', p_code using errcode = '23503';
  end if;

  select s.requires_review into v_review
    from erp_ref.support_severity s where s.code = v_inc.severity_code;

  -- §17.3: "A blameless post-incident review is written for every severity 1
  -- and 2." Requiring the link at resolution is the difference between a review
  -- that is owed and a review that exists; the report would only tell us
  -- afterwards, once the incident was over and the urgency with it.
  if coalesce(v_review, false) and coalesce(btrim(p_review_url), '') = '' then
    raise exception
      'ERPWARE_REVIEW_REQUIRED: a % incident is resolved with its review, not before it',
      v_inc.severity_code
      using errcode = '23514',
            hint = 'The review is blameless and it is not optional. An incident '
                   'closed without one is the action that quietly stops being '
                   'tracked.';
  end if;

  update erp_meta.incident
     set resolved_at = coalesce(resolved_at, now()),
         review_url = coalesce(nullif(btrim(p_review_url), ''), review_url),
         review_completed_at = case
           when coalesce(btrim(p_review_url), '') <> '' then now()
           else review_completed_at end
   where id = v_inc.id;

  perform erp_meta.platform_log(
    v_staff, 'platform.incident_resolved', null, p_code, v_inc.title,
    jsonb_build_object('severity', v_inc.severity_code, 'review', p_review_url));
end;
$$;

comment on function erp.resolve_incident is
  'Specification v1.2 §17.3. A severity that requires a blameless review cannot '
  'be resolved without one, because a review owed after the urgency has passed '
  'is a review that does not get written.';

-- ── §17.1 the half of "logged" that had no writer ───────────────────────────

-- erp.support_action had no way to say whether an action LOOKED or CHANGED, so
-- erp.support_discipline_report() could only forbid every action under a
-- read-only grant. Correct in intent — §17.1 forbids a write under read-only
-- access — and wrong in practice, because it also forbade recording a read,
-- which is most of what support does and exactly what §17.1 wants logged.
--
-- The column defaults to true, so an action that says nothing about itself is
-- treated as a write and still fails the report under a read-only grant.
-- Omitting it cannot get a write past; claiming false for one is a lie with the
-- actor's name on it, in an append-only table.
alter table erp.support_action
  add column if not exists is_write boolean not null default true;

comment on column erp.support_action.is_write is
  'Whether this action changed anything. Defaults to true so silence is treated '
  'as a write: the read-only violation check must fail safe.';


-- Adding a parameter to an existing function OVERLOADS it rather than
-- replacing it: two candidates, a call matching both and resolving to neither.
-- A no-op on a build from empty, and the difference between a clean apply and
-- "function name is not unique" anywhere the earlier shape already landed.
drop function if exists erp.record_support_action(uuid, text, text, text, uuid);

create or replace function erp.record_support_action(p_access_id uuid,
                                                      p_action text,
                                                      p_reason text,
                                                      p_object_type text default null,
                                                      p_object_id uuid default null,
                                                      p_is_write boolean default true)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_staff  erp_meta.platform_staff;
  v_access erp.support_access%rowtype;
  v_id     uuid;
begin
  v_staff := erp_meta.require_platform('support');

  perform set_config('erp.job_tenant_id', null, true);

  select * into v_access from erp.support_access a where a.id = p_access_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_SUPPORT_ACCESS: %', p_access_id
      using errcode = '23503';
  end if;

  -- §17.1: access is time-bounded. An action recorded after the window closed
  -- is either a clock problem or work done without a grant, and both are worth
  -- refusing rather than filing.
  if now() > v_access.expires_at then
    raise exception
      'ERPWARE_SUPPORT_ACCESS_EXPIRED: that grant expired at %', v_access.expires_at
      using errcode = '42501',
            hint = 'Extension is a fresh act, recorded — erp.grant_support_access() '
                   'takes the prior grant as extension_of.';
  end if;

  if v_access.staff_email is distinct from v_staff.email then
    raise exception
      'ERPWARE_SUPPORT_ACCESS_NOT_YOURS: that grant belongs to %', v_access.staff_email
      using errcode = '42501',
            hint = 'An action recorded against somebody else''s grant attributes '
                   'the work to the wrong person, which is the one thing the log '
                   'exists to get right.';
  end if;

  -- §17.1: read-only means read-only. Refused here rather than left for
  -- erp.support_discipline_report() to find, because by then the write has
  -- happened and the log is a record of it rather than a control on it.
  if coalesce(p_is_write, true) and not v_access.is_write_access then
    raise exception
      'ERPWARE_SUPPORT_ACCESS_IS_READ_ONLY: that grant does not permit changing anything'
      using errcode = '42501',
            hint = 'Record a read with p_is_write => false, or ask for a write '
                   'grant — which is a fresh act with its own reason.';
  end if;

  perform set_config('erp.job_tenant_id', v_access.tenant_id::text, true);

  insert into erp.support_action
    (tenant_id, support_access_id, action, object_type, object_id, reason, is_write)
  values (v_access.tenant_id, p_access_id, p_action, p_object_type, p_object_id,
          p_reason, coalesce(p_is_write, true))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.record_support_action is
  'Specification v1.2 §17.1: support access is "time-bounded, reasoned, and '
  'logged". erp.grant_support_access() built the bound and the reason. This is '
  'the log, which had no writer — so erp.support_discipline_report()''s finding '
  'about actions under read-only access described rows nothing could create.';

-- ── What the console reads ──────────────────────────────────────────────────

create or replace function erp.incident_report()
returns table(code text, severity_code text, title text, state text,
              declared_at timestamptz, contained_at timestamptz,
              resolved_at timestamptz, commander text,
              communications_owner text, scribe text,
              scope text, affects_all_tenants boolean,
              is_data_integrity boolean, review_url text,
              updates integer, last_update_at timestamptz,
              minutes_since_update integer, cadence_minutes integer,
              overdue boolean)
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
               > make_interval(mins => s.update_every_minutes)
    from erp_meta.incident i
    join erp_ref.support_severity s on s.code = i.severity_code
    left join lateral (
      select max(u.posted_at) as last_at from erp_meta.incident_update u
       where u.incident_id = i.id) u on true
   order by i.declared_at desc
$$;

comment on function erp.incident_report is
  'Specification v1.2 §17.3, read by the platform console. Carries whether a '
  'live incident is overdue an update against its own severity''s cadence, '
  'because a channel that has gone quiet is the failure §17.3 names and it is '
  'invisible from the incident row alone.';

-- ── The platform doors ──────────────────────────────────────────────────────
--
-- Twenty-seven erp_platform_* doors existed and not one reached Part 16 or
-- Part 17, so the console could not see a commitment, a drill, an incident or a
-- support grant.

create or replace function public.erp_platform_incidents()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.declared_at desc), '[]'::jsonb)
    from erp.incident_report() r;
$$;

create or replace function public.erp_platform_continuity()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.commitment_code), '[]'::jsonb)
    from erp.continuity_report() r;
$$;

create or replace function public.erp_platform_support_access()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.granted_at desc), '[]'::jsonb)
    from erp.support_access_report() r;
$$;

create or replace function public.erp_platform_declare_incident(p_code text,
                                                                 p_severity_code text,
                                                                 p_title text,
                                                                 p_commander text,
                                                                 p_communications_owner text,
                                                                 p_scribe text,
                                                                 p_is_data_integrity boolean default false,
                                                                 p_scope text default null,
                                                                 p_affects_all_tenants boolean default null)
returns uuid
language sql
set search_path = ''
as $$
  select erp.declare_incident(p_code, p_severity_code, p_title, p_commander,
                              p_communications_owner, p_scribe,
                              p_is_data_integrity, p_scope, p_affects_all_tenants);
$$;

create or replace function public.erp_platform_post_incident_update(p_code text,
                                                                     p_body text,
                                                                     p_is_no_change boolean default false)
returns uuid
language sql
set search_path = ''
as $$
  select erp.post_incident_update(p_code, p_body, p_is_no_change);
$$;

create or replace function public.erp_platform_contain_incident(p_code text,
                                                                 p_scope text,
                                                                 p_affects_all_tenants boolean)
returns void
language sql
set search_path = ''
as $$
  select erp.contain_incident(p_code, p_scope, p_affects_all_tenants);
$$;

create or replace function public.erp_platform_resolve_incident(p_code text,
                                                                 p_review_url text default null)
returns void
language sql
set search_path = ''
as $$
  select erp.resolve_incident(p_code, p_review_url);
$$;

drop function if exists public.erp_platform_record_support_action(uuid, text, text, text, uuid);

create or replace function public.erp_platform_record_support_action(p_access_id uuid,
                                                                      p_action text,
                                                                      p_reason text,
                                                                      p_object_type text default null,
                                                                      p_object_id uuid default null,
                                                                      p_is_write boolean default true)
returns uuid
language sql
set search_path = ''
as $$
  select erp.record_support_action(p_access_id, p_action, p_reason,
                                   p_object_type, p_object_id, p_is_write);
$$;

-- Supabase grants EXECUTE to anon on every newly created public function.
revoke all on function
  public.erp_platform_incidents(),
  public.erp_platform_continuity(),
  public.erp_platform_support_access(),
  public.erp_platform_declare_incident(text, text, text, text, text, text, boolean, text, boolean),
  public.erp_platform_post_incident_update(text, text, boolean),
  public.erp_platform_contain_incident(text, text, boolean),
  public.erp_platform_resolve_incident(text, text),
  public.erp_platform_record_support_action(uuid, text, text, text, uuid, boolean)
  from public, anon;

grant execute on function
  public.erp_platform_incidents(),
  public.erp_platform_continuity(),
  public.erp_platform_support_access(),
  public.erp_platform_declare_incident(text, text, text, text, text, text, boolean, text, boolean),
  public.erp_platform_post_incident_update(text, text, boolean),
  public.erp_platform_contain_incident(text, text, boolean),
  public.erp_platform_resolve_incident(text, text),
  public.erp_platform_record_support_action(uuid, text, text, text, uuid, boolean)
  to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_declare_incident', 'erp.declare_incident',
   'Declares an incident on the platform register. Gated by erp_meta.require_platform at operator, because declaring one commits the response roles §17.3 names.'),
  ('erp_platform_post_incident_update', 'erp.post_incident_update',
   'Posts an update against a live incident. Support may post, because keeping the channel warm on §17.3''s cadence is the job support is doing during one.'),
  ('erp_platform_contain_incident', 'erp.contain_incident',
   'Records containment with the scope it reached. Operator, because a containment claim is an operational judgement rather than a message.'),
  ('erp_platform_resolve_incident', 'erp.resolve_incident',
   'Resolves an incident, refusing to close a severity that owes a blameless review without one. Operator, for the same reason containment is.'),
  ('erp_platform_record_support_action', 'erp.record_support_action',
   'Records what was actually done under a support grant. §17.1 makes access logged, and this is the log; it refuses an expired grant and somebody else''s grant.')
on conflict (function_name) do nothing;

-- ── The clause that could not tell looking from changing ───────────────────

CREATE OR REPLACE FUNCTION erp.support_discipline_report()
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
  --
  -- This clause read "any action under a read-only grant" until
  -- erp.support_action carried is_write, because nothing distinguished looking
  -- from changing. That made the finding correct in intent and wrong in
  -- practice: it forbade logging a READ under read-only access, which is most
  -- of what support does and exactly what §17.1 wants recorded. The column
  -- defaults to true, so an action that says nothing about itself is treated
  -- as a write and still fails here — omitting it cannot get a write past.
  select 'a support action was recorded against read-only access',
         act.id::text, act.action
    from erp.support_action act
    join erp.support_access acc
      on acc.tenant_id = act.tenant_id and acc.id = act.support_access_id
   where act.is_write and not acc.is_write_access

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
$function$;

-- ── §16.2: an ungoverned entry point must not survive its own transaction ───

select erp.assert_public_api_safe();
select erp.assert_support_discipline();
select erp.assert_release_integrity();
select erp.assert_isolation();
select erp.assert_audit_coverage();

-- ── The decision this settles ───────────────────────────────────────────────

update erp_meta.policy_decision set
  status = 'accepted',
  decision = 'The public status page stays outside this database, unchanged and by construction. The incident register it would read becomes something an operator can actually run an incident from: declare, post an update, contain, resolve — and record what was done under a support grant.',
  rationale = 'A status page served from the product''s own Postgres goes dark exactly when somebody needs it, so serving it from here would be worse than not having one. That reasoning was right and is untouched. What it concealed is the sentence after it: "the incident register here is what would feed it" was not true, because nothing could feed the register. erp_meta.incident and erp_meta.incident_update were written by no function at all — only by the Part 17 suite, inserting directly. The same held for erp.support_action: §17.1 makes access time-bounded, reasoned AND logged, and the log had no writer, which is why the discipline report carried a finding about rows no code path could create.',
  evidence = 'erp.declare_incident(), post_incident_update(), contain_incident(), resolve_incident() and record_support_action(), each refusing at write time what erp.support_discipline_report() would otherwise report afterwards; erp.incident_report() carrying whether a live incident is overdue an update against its own severity''s cadence; eight erp_platform_* doors so the console can reach Part 16 and Part 17 at all; and erp_test.incident_operations_suite().',
  decided_at = now()
 where code = 'status_page_not_built';
