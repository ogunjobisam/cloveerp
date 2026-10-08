set lock_timeout = '30s';

-- =============================================================================
-- 20261011110000  The register keeps its own house
-- -----------------------------------------------------------------------------
-- The control plane's register of client deployments (20261011020000) was
-- written before every client was served through one wildcard route, and
-- before a build had ever waited on a sweep that did not come back. Five
-- things it now does for itself:
--
--   A. The checklist holds the two steps a person still does by hand after a
--      build: Google sign-in, if the client wants it, and the email
--      provider's webhook. Since 8 October the application is a Worker that
--      serves every client's address through one route, so there is no
--      domain to add and no record to publish for a client. The door no
--      longer accepts those two steps, and its refusal, its hint and the
--      comments name only the two that remain. A row ticked before keeps
--      what it holds; the Fleet view reads only the two.
--
--   B. A deployment's history is kept as it was recorded.
--      erp_meta.deployment_event was append-only by habit: every writer
--      inserts and nothing updates or deletes, but nothing said so. Now its
--      own trigger function refuses an update, a delete or a truncate, with
--      a registered refusal. Not erp.forbid_mutation: that is the guard of
--      the organisations' append-only tables, reads a tenant this table does
--      not have, and erp.apply_append_only_guards places it on that class of
--      table alone. The table stays platform internal (reclassifying it
--      would give it tenant policies and grants it must not have), and its
--      two triggers are named so that generator never takes them for its own.
--
--   C. A build that waited too long can be started again. The console asks
--      for a build by writing a request the sweep claims within ten minutes,
--      and a build that has started records its first step within minutes
--      more. When neither happens (a sweep that died between claiming and
--      settling, a run that never started) the row sat at requested, with
--      Retry refused while the request was open, or offered at any age once
--      it was not, which could queue a second build behind the first.
--      public.erp_platform_restart_deployment(code, reason): platform owner,
--      on the control plane, with a reason; only while the deployment is
--      requested and its newest build request has been open for twenty
--      minutes, or was started by the sweep twenty minutes ago with no step
--      of the build since. It cancels the open request, queues a new one
--      with the same payload, and records the step and the platform log. The
--      rule lives in one function the door and the Fleet view both ask.
--
--   D. The sweep's late settle of a request cancelled meanwhile is let
--      through quietly instead of failing the sweep's run, so a slow sweep
--      never fails on a request the console has already replaced.
--
--   E. The Fleet view reads when the newest build request was made, claimed
--      and settled, and whether the database would start its build again
--      now, so the console offers Start again by the door's own rule.
--
-- erp_test.deployment_register_suite is re-created with its checklist case
-- ticking Google sign-in and refusing the two retired steps; its count stays
-- ten. erp_test.register_house_suite proves B to E in thirteen cases.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_CHECKLIST_ITEM_UNKNOWN',
  'Ticking a step of a deployment''s checklist that the checklist does not have.',
  'The checklist holds the two steps a person still does by hand after a build: Google sign-in, if the client '
  'wants it, and the email provider''s webhook.',
  'Tick one of the two steps the Fleet view lists: Google sign-in, or the email provider''s webhook.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_EVENT_KEPT',
  'Changing or removing a step already recorded in a client deployment''s history.',
  'The steps of a client deployment''s build and releases are its history. The Fleet view, and whoever later '
  'asks what happened to a client, read them as they were recorded, so a step is added and never changed or '
  'taken away.',
  'Leave the step as it is. If it was wrong, record another step that says so.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_STALE',
  'Starting a client deployment''s build again while it may still be on its way.',
  'A build that was asked for is started by the sweep within ten minutes, and a build that has started records '
  'its first step soon after. Starting it again before twenty minutes have passed without either would queue a '
  'second build of the same client behind the first. Only a build still waiting to start is started again.',
  'Wait until its build has waited twenty minutes with no new step in the Fleet view, then start it again. If '
  'its build failed or stopped, retry it instead.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The checklist names the two steps that remain
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_deployment_checklist(p_code text, p_item text, p_done boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  d      erp_meta.deployment;
  v_item text := lower(btrim(coalesce(p_item, '')));
  v_list jsonb;
begin
  v := erp_meta.require_platform('operator');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);
  -- Two steps since every client is served through one route: no domain and
  -- no record of its own to tick (20261011110000).
  if v_item not in ('google_sign_in', 'resend_webhook') then
    raise exception 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN: "%" is not a step of the checklist', p_item
      using errcode = '22023',
            hint = 'Tick one of the two steps the Fleet view lists: Google sign-in, or the email provider''s webhook.';
  end if;
  update erp_meta.deployment x
     set checklist = x.checklist || jsonb_build_object(v_item,
                       jsonb_build_object('done', coalesce(p_done, false), 'at', now(), 'by', v.email)),
         updated_at = now()
   where x.code = d.code
  returning x.checklist into v_list;
  perform erp_meta.record_deployment_event(d.code, 'checklist', 'note',
    format('%s %s by %s', v_item, case when coalesce(p_done, false) then 'done' else 'not done' end, v.email));
  perform erp_meta.platform_log(v, 'platform.deployment_checklist', null, d.code, null,
    jsonb_build_object('item', v_item, 'done', coalesce(p_done, false)));
  return jsonb_build_object('code', d.code, 'checklist', v_list);
end;
$$;

revoke all on function public.erp_platform_deployment_checklist(text, text, boolean) from public, anon;
grant execute on function public.erp_platform_deployment_checklist(text, text, boolean) to authenticated, service_role;

comment on function public.erp_platform_deployment_checklist(text, text, boolean) is
  'Ticks or unticks one of the two steps a person does by hand after a client deployment''s build: Google '
  'sign-in, if the client wants it, and the email provider''s webhook. Platform operator and above, on the '
  'control plane (20261011020000, 20261011110000).';

comment on column erp_meta.deployment.checklist is
  'The steps a person still does by hand after the build, ticked from the console: '
  '{"google_sign_in": {"done": true, "at": ..., "by": ...}, "resend_webhook": ...}. A row ticked before '
  '20261011110000 may also hold steps the checklist no longer has; nothing reads them.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A deployment's history is kept as it was recorded
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.forbid_deployment_event_change()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_what text := 'the history of client deployments';
begin
  -- The row trigger names the step; the statement trigger a truncate fires
  -- has no row to name (20261011110000).
  if tg_level = 'ROW' then
    v_what := format('step %s of %s', old.id, old.code);
  end if;
  raise exception 'CLOVEERP_DEPLOYMENT_EVENT_KEPT: % is kept as it was recorded and is not %', v_what,
    case tg_op when 'UPDATE' then 'changed' when 'DELETE' then 'removed' else 'emptied' end
    using errcode = '42501',
          hint = 'Leave the step as it is. If it was wrong, record another step that says so.';
end;
$$;

revoke all on function erp_meta.forbid_deployment_event_change() from public, anon, authenticated, service_role;

comment on function erp_meta.forbid_deployment_event_change() is
  'The trigger that keeps a client deployment''s history as it was recorded: an update, a delete or a truncate '
  'of erp_meta.deployment_event is refused, whoever asks. Its own function rather than erp.forbid_mutation, '
  'which guards the organisations'' append-only tables and reads a tenant this table does not have '
  '(20261011110000).';

-- Not t_deployment_event_append_only: erp.apply_append_only_guards manages
-- triggers of that name on the tables of its own class, and this table is not
-- one of them.
drop trigger if exists t_deployment_event_kept on erp_meta.deployment_event;
create trigger t_deployment_event_kept
  before update or delete on erp_meta.deployment_event
  for each row
  execute function erp_meta.forbid_deployment_event_change();

drop trigger if exists t_deployment_event_kept_whole on erp_meta.deployment_event;
create trigger t_deployment_event_kept_whole
  before truncate on erp_meta.deployment_event
  for each statement
  execute function erp_meta.forbid_deployment_event_change();

comment on table erp_meta.deployment_event is
  'What a client deployment''s build and releases did, step by step, as the workflows recorded it '
  '(20261011020000). The console shows a build''s progress from here. Kept as recorded: an update, a delete or '
  'a truncate is refused (20261011110000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A build that waited too long is started again
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.newest_build_request(p_code text)
returns erp_meta.fleet_request
language sql
stable
set search_path = ''
as $$
  -- The newest build request for a deployment. Two made in one transaction
  -- share a time; the open one is the later (a request is opened only once
  -- the one before it has settled), and then the id keeps the answer the same.
  select r.*
    from erp_meta.fleet_request r
   where r.kind = 'build'
     and r.payload ->> 'code' = p_code
   order by r.created_at desc, (r.status in ('requested', 'claimed')) desc, r.id
   limit 1
$$;

revoke all on function erp_meta.newest_build_request(text) from public, anon, authenticated, service_role;

comment on function erp_meta.newest_build_request(text) is
  'The newest build request for a client deployment, or null: what the Fleet view shows and what Start again '
  'reads (20261011110000).';

create or replace function erp_meta.deployment_restart_refusal(p_code text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  -- A sweep claims a request within ten minutes and settles it within
  -- seconds; a build it started records its first step within minutes.
  -- Twice the sweep's period with neither is a build that is not coming.
  c_wait   constant interval := interval '20 minutes';
  d        erp_meta.deployment;
  r        erp_meta.fleet_request;
  v_since  timestamptz;
  v_mins   integer;
begin
  select * into d from erp_meta.deployment x where x.code = lower(btrim(coalesce(p_code, '')));
  if d.code is null then
    return format('no client deployment is registered as "%s"', p_code);
  end if;
  if d.status <> 'requested' then
    return format('it is %s, and only a build still waiting to start is started again%s', d.status,
                  case when d.status = 'failed' then '; retry it instead' else '' end);
  end if;

  r := erp_meta.newest_build_request(d.code);
  if r.id is null then
    return 'no build of it was asked for; retry it instead';
  end if;

  if r.status in ('requested', 'claimed') then
    -- Open: waiting for the sweep, or claimed by a sweep that has not said
    -- what became of it. Its age is since it last moved.
    v_since := case when r.status = 'claimed' then coalesce(r.claimed_at, r.created_at) else r.created_at end;
    if v_since > now() - c_wait then
      v_mins := floor(extract(epoch from (now() - v_since)) / 60)::integer;
      return format('its build was %s %s minute(s) ago, and the sweep starts a build within ten minutes',
                    case when r.status = 'claimed' then 'claimed by the sweep' else 'asked for' end, v_mins);
    end if;
    return null;
  end if;

  if r.status = 'done' then
    -- Started by the sweep. A build that began says so: the run records its
    -- start, then the project and the replay. The sweep's own claim comes
    -- before it settles, so only a step after the settle counts.
    v_since := coalesce(r.settled_at, r.claimed_at, r.created_at);
    if exists (select 1 from erp_meta.deployment_event e
                where e.code = d.code
                  and e.phase in ('dispatch', 'create', 'build')
                  and e.at > v_since) then
      return 'its build has begun since the sweep started it';
    end if;
    if v_since > now() - c_wait then
      v_mins := floor(extract(epoch from (now() - v_since)) / 60)::integer;
      return format('the sweep started its build %s minute(s) ago, and a build says it has begun within minutes',
                    v_mins);
    end if;
    return null;
  end if;

  return format('its last build request %s; retry it instead',
                case when r.status = 'failed' then 'failed' else 'was cancelled' end);
end;
$$;

revoke all on function erp_meta.deployment_restart_refusal(text) from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_restart_refusal(text) is
  'Why a client deployment''s build is not started again now, or null when it is: the deployment is requested '
  'and its newest build request has been open twenty minutes, or was started by the sweep twenty minutes ago '
  'with no step of the build since. Asked by erp_platform_restart_deployment and shown by '
  'erp_platform_deployments (20261011110000).';

create or replace function public.erp_platform_restart_deployment(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  d       erp_meta.deployment;
  r       erp_meta.fleet_request;
  c_cancelled constant text := 'cancelled';
  v_why   text;
  v_mins  integer;
  v_req   uuid;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: starting a build again needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say what the build was waiting for and why it is started again. At least twenty characters.';
  end if;

  -- The row's lock, then its open build requests'. The sweep claims with
  -- skip locked, so it passes these by while this decides, and a request it
  -- claimed first is read here as claimed.
  select * into d from erp_meta.deployment x where x.code = d.code for update;
  perform 1 from erp_meta.fleet_request x
   where x.kind = 'build' and x.payload ->> 'code' = d.code and x.status in ('requested', 'claimed')
   for update;

  v_why := erp_meta.deployment_restart_refusal(d.code);
  if v_why is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_STALE: % is not started again: %', d.code, v_why
      using errcode = '55000',
            hint = 'Wait until its build has waited twenty minutes with no new step in the Fleet view, then start '
                   'it again. If its build failed or stopped, retry it instead.';
  end if;

  r := erp_meta.newest_build_request(d.code);
  v_mins := floor(extract(epoch from (now() - coalesce(r.settled_at, r.claimed_at, r.created_at))) / 60)::integer;

  -- What still waits for the sweep, or what a sweep claimed and left, is
  -- cancelled: the sweep passes a cancelled request by, and its late word
  -- on one it claimed is let through quietly (erp_meta.settle_fleet_request).
  update erp_meta.fleet_request x
     set status = c_cancelled,
         outcome = format('started again by %s after %s minutes without a start', v.email, v_mins),
         settled_at = now()
   where x.kind = 'build'
     and x.payload ->> 'code' = d.code
     and x.status in ('requested', 'claimed');

  insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
  values ('build', r.payload, btrim(p_reason), v.id)
  returning id into v_req;
  update erp_meta.deployment x set updated_at = now() where x.code = d.code;

  perform erp_meta.record_deployment_event(d.code, 'retry', 'done',
    format('started again by %s: its build request was %s and had waited %s minutes without a start. %s.',
           v.email, r.status, v_mins, rtrim(btrim(p_reason), '.')));
  perform erp_meta.platform_log(v, 'platform.deployment_restarted', null, d.code, p_reason,
    jsonb_build_object('previous_request_id', r.id, 'previous_status', r.status, 'waited_minutes', v_mins,
                       'request_id', v_req));

  return jsonb_build_object('code', d.code, 'status', 'requested', 'request_id', v_req,
                            'previous_request_id', r.id, 'previous_status', r.status);
end;
$$;

revoke all on function public.erp_platform_restart_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_restart_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_restart_deployment(text, text) is
  'Starts a client deployment''s build again when it waited twenty minutes without starting: its newest build '
  'request still open, or started by the sweep with no step of the build since. Cancels the open request and '
  'queues a new one with the same payload. Platform owner, on the control plane, with a reason '
  '(20261011110000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_restart_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its '
   'first lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Cancels one deployment''s '
   'stale build request, queues another with the same payload, and writes the step and the platform audit row; '
   'only when erp_meta.deployment_restart_refusal says the build is not coming.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_restart_deployment', 'erp_meta.require_platform',
   'Starts a client deployment''s build again when it waited twenty minutes without starting; platform owner, with a reason kept in the activity log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.platform_door_rank (schema_name, function_name, minimum_role, why) values
  ('public', 'erp_platform_restart_deployment', 'owner',
   'Starts a build against a client''s project again; whether the first one is coming is the owner''s to judge.')
on conflict (schema_name, function_name, minimum_role) do update set why = excluded.why;

-- Its screen is Start again on a row of the Fleet view, beside Retry. Until a
-- screen names it, it is registered as waiting for one; the row goes when the
-- screen comes (erp.assert_doors_have_a_home refuses a stale one).
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_platform_restart_deployment', 'pending_screen', '/platform',
   'Starts a client deployment''s build again when it waited twenty minutes without starting. Belongs as Start '
   'again on the row of the Fleet view (Customers, Client deployments), beside Retry, offered when the row says '
   'restartable.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The sweep's late word on a cancelled request
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.settle_fleet_request(p_id uuid, p_outcome text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_cancelled constant text := 'cancelled';
  r erp_meta.fleet_request;
begin
  update erp_meta.fleet_request x
     set status = case when lower(btrim(coalesce(p_outcome, ''))) like 'success%' or lower(btrim(coalesce(p_outcome, ''))) = 'done'
                       then 'done' else 'failed' end,
         outcome = nullif(btrim(coalesce(p_outcome, '')), ''),
         settled_at = now()
   where x.id = p_id and x.status = 'claimed'
  returning * into r;
  if r.id is null then
    -- Cancelled while the sweep held it, by Start again from the console: the
    -- cancellation stands, and the sweep's word on it comes too late to
    -- matter. Said rather than refused, so a slow sweep goes on to the next
    -- request instead of failing its run (20261011110000).
    select * into r from erp_meta.fleet_request x where x.id = p_id;
    if r.status = c_cancelled then
      return format('request %s was cancelled meanwhile (%s); left as it is', r.id, coalesce(r.outcome, 'no reason given'));
    end if;
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: request % is not claimed, so it is not settled', p_id
      using errcode = '55000',
            hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
  end if;
  return format('request %s %s', r.id, r.status);
end;
$$;

revoke all on function erp_meta.settle_fleet_request(uuid, text) from public, anon, authenticated, service_role;

comment on function erp_meta.settle_fleet_request(uuid, text) is
  'A claimed request settled by the sweep: done, or failed with why. One cancelled meanwhile stays cancelled '
  'and is reported, not refused. Trusted build role only (20261011020000, 20261011110000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The Fleet view reads the request's times and the door's rule
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_deployments()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('support');
  perform erp.require_control_plane();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', d.code,
             'client_name', d.client_name,
             'status', d.status,
             'owner_email', d.owner_email,
             'project_ref', d.project_ref,
             'api_url', d.api_url,
             'region', d.region,
             'instance_size', d.instance_size,
             'origin', 'https://' || d.code || '.' || regexp_replace(erp.app_origin(), '^https://', ''),
             'build_run_id', d.build_run_id,
             'built_at', d.built_at,
             'last_release_sha', d.last_release_sha,
             'last_release_at', d.last_release_at,
             'last_release_outcome', d.last_release_outcome,
             'last_release_run_id', d.last_release_run_id,
             'checklist', d.checklist,
             'note', d.note,
             'created_at', d.created_at,
             'updated_at', d.updated_at,
             -- The newest request for its build, if any: the console says
             -- "queued" or "starting" from its status, and how long it has
             -- waited from its times (20261011110000).
             'request_status', q.status,
             'request_run_id', q.run_id,
             'request_created_at', q.created_at,
             'request_claimed_at', q.claimed_at,
             'request_settled_at', q.settled_at,
             -- Whether Start again would start its build now: the door's
             -- own rule, asked rather than repeated in the browser.
             'restartable', erp_meta.deployment_restart_refusal(d.code) is null,
             'last_event', (select jsonb_build_object('phase', e.phase, 'status', e.status, 'detail', e.detail, 'at', e.at)
                              from erp_meta.deployment_event e
                             where e.code = d.code
                             order by e.at desc, e.id desc limit 1))
           order by d.created_at)
      from erp_meta.deployment d
      left join lateral erp_meta.newest_build_request(d.code) q on true), '[]'::jsonb);
end;
$$;

revoke all on function public.erp_platform_deployments() from public, anon;
grant execute on function public.erp_platform_deployments() to authenticated, service_role;

comment on function public.erp_platform_deployments() is
  'Every client deployment in the register, with its build''s last step, its newest build request and when it '
  'was made, claimed and settled, whether Start again would start it now, and its last release, for the Fleet '
  'view. Platform support and above, on the control plane only (20261011020000, 20261011110000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.deployment_register_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_code   text;
  v_uid    uuid := gen_random_uuid();
  v_owner  text;
  v_role   text := current_user;
  v_step   text := 'standing up an owner';
  v_state  text;
  v_got    text;
  v_got2   text;
  v_got3   text;
  v_json   jsonb;
  v_req    uuid;
  v_apex   text;
  rb       record;
begin
  begin
    v_code := 'zzreg-' || v_tag;
    v_owner := 'owner@zzreg-' || v_tag || '.test';
    -- A platform owner, bound by id, and the control plane's marker; both
    -- undone at the end with everything else.
    insert into auth.users (id, email) values (v_uid, v_owner);
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Deployment Register Suite Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.ref', 'deployment.app_origin');
    v_apex := regexp_replace(erp.app_origin(), '^https://', '');

    -- ── 1. Not on a client ──────────────────────────────────────────────────
    v_step := 'requesting on a client deployment';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"client"'::jsonb, 'deployment_register_suite');
    begin
      perform public.erp_platform_request_deployment(v_code, 'Register Suite Ltd', 'admin@' || v_code || '.test',
        'The register suite asks on a client deployment, which must refuse.');
      v_got := 'it was requested';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_deployments();
      v_got2 := 'it was read';
    exception when others then
      v_got2 := sqlerrm;
    end;
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'deployment_register_suite');
    v_cases := v_cases + 1;
    case_name := 'the register is the control plane''s: a client deployment neither keeps nor reads one';
    passed := v_got like 'CLOVEERP_NOT_THE_CONTROL_PLANE%' and v_got2 like 'CLOVEERP_NOT_THE_CONTROL_PLANE%';
    detail := left(v_got, 80) || ' / ' || left(v_got2, 80);
    return next;

    -- ── 2. Requested ────────────────────────────────────────────────────────
    v_step := 'requesting a deployment';
    v_json := public.erp_platform_request_deployment(v_code, 'Register Suite Ltd', 'admin@' || v_code || '.test',
      'A client signed on the register suite''s day, and wants its own project.');
    v_req := (v_json ->> 'request_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'an owner requests a deployment: a row requested, a build request open, an event, and the log';
    passed := v_json ->> 'status' = 'requested'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'requested'
          and (select r.kind || ' ' || r.status || ' ' || (r.payload ->> 'code') from erp_meta.fleet_request r where r.id = v_req)
              = 'build requested ' || v_code
          and exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.phase = 'request' and e.status = 'done')
          and exists (select 1 from erp_meta.platform_audit a where a.action = 'platform.deployment_requested' and a.target = v_code)
          and (select jsonb_array_length(public.erp_platform_deployments())) >= 1
          and exists (select 1 from jsonb_array_elements(public.erp_platform_deployments()) x
                       where x ->> 'code' = v_code and x ->> 'request_status' = 'requested'
                         and x ->> 'origin' = 'https://' || v_code || '.' || v_apex);
    detail := v_json::text;
    return next;

    -- ── 3. A code is held once across the fleet ─────────────────────────────
    v_step := 'taking a code twice';
    begin
      perform public.erp_platform_request_deployment(v_code, 'Register Suite Ltd', 'admin@' || v_code || '.test',
        'The register suite asks for the same code twice, which must refuse.');
      v_got := 'it was requested again';
    exception when others then
      v_got := sqlerrm;
    end;
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzregt-' || v_tag, 'Register Suite Organisation', 'admin@zzregt-' || v_tag || '.test', 'Register Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    begin
      perform public.erp_platform_request_deployment('zzregt-' || v_tag, 'Register Suite Ltd', 'admin@' || v_code || '.test',
        'The register suite asks for an organisation''s address, which must refuse.');
      v_got2 := 'it was requested';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_got3 := coalesce(erp.tenant_code_refusal(v_code, null), 'no refusal');
    v_cases := v_cases + 1;
    case_name := 'a code is held once across the fleet: not twice as a deployment, not as an organisation''s address, and no organisation may take a deployment''s';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_EXISTS%'
          and v_got2 like 'CLOVEERP_ADDRESS_TAKEN%'
          and v_got3 like 'CLOVEERP_ADDRESS_TAKEN%' and v_got3 like '%client deployment%';
    detail := left(v_got, 60) || ' / ' || left(v_got2, 60) || ' / ' || left(v_got3, 80);
    return next;

    -- ── 4. Support reads, and may not ask ───────────────────────────────────
    v_step := 'reading as support';
    update erp_meta.platform_staff set staff_role = 'support' where auth_user_id = v_uid;
    begin
      v_json := public.erp_platform_deployments();
      v_got := 'read ' || jsonb_array_length(v_json)::text;
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_request_deployment('zzregs-' || v_tag, 'Register Suite Ltd', 'admin@' || v_code || '.test',
        'The register suite asks as support, which must refuse.');
      v_got2 := 'it was requested';
    exception when others then
      v_got2 := sqlerrm;
    end;
    update erp_meta.platform_staff set staff_role = 'owner' where auth_user_id = v_uid;
    v_cases := v_cases + 1;
    case_name := 'support reads the register and may not request a deployment';
    passed := v_got like 'read %' and v_got2 like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%';
    detail := v_got || ' / ' || left(v_got2, 80);
    return next;

    -- ── 5. The sweep claims the request ─────────────────────────────────────
    v_step := 'claiming the request';
    v_json := erp_meta.claim_fleet_request('run-' || v_tag);
    v_got := coalesce(erp_meta.claim_fleet_request('run-' || v_tag || '-2')::text, 'nothing');
    v_cases := v_cases + 1;
    case_name := 'the sweep claims the oldest open request once; a second claim finds nothing';
    passed := (v_json ->> 'id')::uuid = v_req and v_json ->> 'kind' = 'build' and v_json -> 'payload' ->> 'code' = v_code
          and v_got = 'nothing'
          and (select r.status || ' ' || r.run_id from erp_meta.fleet_request r where r.id = v_req) = 'claimed run-' || v_tag
          and exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.phase = 'dispatch');
    detail := coalesce(v_json::text, 'no claim') || ' / then ' || v_got;
    return next;

    -- ── 6. The build moves the row ──────────────────────────────────────────
    v_step := 'recording the build';
    perform erp_meta.record_deployment_event(v_code, 'create', 'started', 'making the project', 'run-' || v_tag);
    v_got := (select d.status from erp_meta.deployment d where d.code = v_code);
    perform erp_meta.register_deployment_project(v_code, 'abcdefghijklmnopqrst', 'https://abcdefghijklmnopqrst.supabase.co',
      'sb_publishable_suite', 'eu-central-1', 'micro');
    perform erp_meta.record_deployment_event(v_code, 'build', 'started', 'replaying every migration', 'run-' || v_tag);
    v_got2 := (select d.status from erp_meta.deployment d where d.code = v_code);
    begin
      perform erp_meta.deployment_built('zznone-' || v_tag);
      v_got3 := 'an unknown deployment was built';
    exception when others then
      v_got3 := sqlerrm;
    end;
    perform erp_meta.deployment_built(v_code);
    perform erp_meta.settle_fleet_request(v_req, 'success');
    v_cases := v_cases + 1;
    case_name := 'the build moves the row: creating, then building with its project, then built; an unknown code is refused';
    passed := v_got = 'creating' and v_got2 = 'building'
          and (select d.status || ' ' || d.project_ref || ' ' || d.build_run_id from erp_meta.deployment d where d.code = v_code)
              = 'built abcdefghijklmnopqrst run-' || v_tag
          and v_got3 like 'CLOVEERP_DEPLOYMENT_UNKNOWN%'
          and (select r.status from erp_meta.fleet_request r where r.id = v_req) = 'done'
          and (select jsonb_array_length(public.erp_platform_deployment_events(v_code))) >= 5;
    detail := v_got || ' / ' || v_got2 || ' / ' || left(v_got3, 60);
    return next;

    -- ── 7. The directory answers the host, as service_role only ─────────────
    v_step := 'asking the directory';
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json := public.erp_deployment_for_host(v_code || '.' || v_apex);
    v_got := coalesce(public.erp_deployment_for_host('nobody-' || v_tag || '.' || v_apex)::text, 'nothing');
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'the directory answers a built deployment''s host with its project and nothing for an unknown host, to service_role alone';
    passed := v_json ->> 'code' = v_code and v_json ->> 'url' = 'https://abcdefghijklmnopqrst.supabase.co'
          and v_json ->> 'key' = 'sb_publishable_suite' and v_got = 'nothing'
          and not has_function_privilege('anon', 'public.erp_deployment_for_host(text)', 'execute')
          and not has_function_privilege('authenticated', 'public.erp_deployment_for_host(text)', 'execute')
          and has_function_privilege('service_role', 'public.erp_deployment_for_host(text)', 'execute');
    detail := coalesce(v_json::text, 'no answer') || ' / ' || v_got;
    return next;

    -- ── 8. A release makes it live, and is asked for ────────────────────────
    v_step := 'recording a release';
    perform erp_meta.record_deployment_release(v_code, 'abc1234def5678', 'success', 'run-' || v_tag || '-r');
    v_json := public.erp_platform_request_release(array['all'], 'The sprint''s work goes out, on the register suite''s day.');
    -- The sweep claims it, as it would, and settles it: the train's run is its own.
    v_got2 := coalesce(erp_meta.claim_fleet_request('run-' || v_tag || '-t') ->> 'kind', 'nothing');
    perform erp_meta.settle_fleet_request((v_json ->> 'request_id')::uuid, 'success: deploy.yml started');
    begin
      perform public.erp_platform_request_release(array['zznone-' || v_tag], 'The register suite names a deployment that is not built, which must refuse.');
      v_got := 'it was requested';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'the first successful release makes a built deployment live; a release train is asked for by name, claimed by the sweep, and an unknown target is refused';
    passed := (select d.status || ' ' || d.last_release_sha || ' ' || d.last_release_outcome from erp_meta.deployment d where d.code = v_code)
              = 'live abc1234def5678 success'
          and exists (select 1 from erp_meta.fleet_request r where r.id = (v_json ->> 'request_id')::uuid
                       and r.kind = 'release' and r.status = 'done' and r.payload -> 'targets' = '["all"]'::jsonb)
          and v_got2 = 'release'
          and v_got like 'CLOVEERP_RELEASE_TARGET_UNKNOWN%';
    detail := coalesce(v_json::text, 'no request') || ' / ' || v_got2 || ' / ' || left(v_got, 80);
    return next;

    -- ── 9. The checklist ────────────────────────────────────────────────────
    -- Two steps are done by hand since every client is served through one
    -- route: Google sign-in and the email provider's webhook. The domain and
    -- its records are no step of it any more (20261011110000).
    v_step := 'ticking the checklist';
    v_json := public.erp_platform_deployment_checklist(v_code, 'google_sign_in', true);
    begin
      perform public.erp_platform_deployment_checklist(v_code, 'lovable_domain', true);
      v_got := 'it was ticked';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_deployment_checklist(v_code, 'dns', true);
      v_got2 := 'it was ticked';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a step done by hand is ticked on the checklist; a step the checklist no longer has is refused';
    passed := (v_json -> 'checklist' -> 'google_sign_in' ->> 'done') = 'true'
          and (v_json -> 'checklist' -> 'google_sign_in' ->> 'by') = v_owner
          and v_got like 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN%'
          and v_got2 like 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN%'
          and (select not (d.checklist ? 'lovable_domain') and not (d.checklist ? 'dns')
                 from erp_meta.deployment d where d.code = v_code);
    detail := coalesce(v_json::text, 'no checklist') || ' / ' || left(v_got, 60) || ' / ' || left(v_got2, 40);
    return next;

    -- ── 10. A live deployment is not built again; a failed one is ───────────
    v_step := 'retrying';
    begin
      perform public.erp_platform_retry_deployment(v_code, 'The register suite retries a live deployment, which must refuse.');
      v_got := 'it was retried';
    exception when others then
      v_got := sqlerrm;
    end;
    perform public.erp_platform_request_deployment('zzregf-' || v_tag, 'Register Suite Failed Ltd', 'admin@' || v_code || '.test',
      'A second client, whose build the register suite will fail.');
    perform erp_meta.record_deployment_event('zzregf-' || v_tag, 'build', 'failed', 'the runner timed out');
    v_got2 := (select d.status from erp_meta.deployment d where d.code = 'zzregf-' || v_tag);
    -- Its open request is still open, so a retry is refused until the sweep
    -- has settled it; settle it as the sweep would.
    perform erp_meta.settle_fleet_request((erp_meta.claim_fleet_request('run-' || v_tag || '-f') ->> 'id')::uuid, 'failure');
    v_json := public.erp_platform_retry_deployment('zzregf-' || v_tag, 'The runner timed out; the project is up and the build carries on.');
    v_cases := v_cases + 1;
    case_name := 'a live deployment''s build is not retried; a failed one is queued again';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETRYABLE%'
          and v_got2 = 'failed'
          and v_json ->> 'status' = 'requested'
          and exists (select 1 from erp_meta.fleet_request r where r.id = (v_json ->> 'request_id')::uuid
                       and r.kind = 'build' and r.status = 'requested');
    detail := left(v_got, 60) || ' / ' || v_got2 || ' / ' || coalesce(v_json::text, 'no retry');
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DEPLOYMENT_REGISTER_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.deployment_register_suite() from public, anon;

comment on function erp_test.deployment_register_suite() is
  'The control plane''s register of client deployments (20261011020000, 20261011110000): kept on the control '
  'plane only; an owner requests one and a build request opens; a code is held once across the fleet; support '
  'reads and may not ask; the sweep claims a request once; the build moves the row to built; the directory '
  'answers a host to service_role alone; a release makes it live and a train is asked for by name; the '
  'checklist holds Google sign-in and the email provider''s webhook and nothing else; a live deployment is not '
  'built again and a failed one is.';

create or replace function erp_test.register_house_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected  constant integer := 13;
  c_cancelled constant text := 'cancelled';
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_code   text;
  v_code2  text;
  v_uid    uuid := gen_random_uuid();
  v_owner  text;
  v_staff  uuid;
  v_step   text := 'standing up an owner';
  v_state  text;
  v_got    text;
  v_got2   text;
  v_got3   text;
  v_json   jsonb;
  v_row    jsonb;
  v_row2   jsonb;
  v_id     bigint;
  v_n      integer;
  v_n2     integer;
  v_req    uuid;
  v_req2   uuid;
  r        erp_meta.fleet_request;
  r2       erp_meta.fleet_request;
begin
  begin
    v_code := 'zzhouse-' || v_tag;
    v_code2 := 'zzhousb-' || v_tag;
    v_owner := 'owner@zzhouse-' || v_tag || '.test';
    -- A platform owner, bound by id, and the control plane's marker; both
    -- undone at the end with everything else.
    insert into auth.users (id, email) values (v_uid, v_owner);
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Register House Suite Owner', 'owner')
    returning id into v_staff;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.ref', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'register_house_suite');

    v_step := 'requesting a client';
    v_json := public.erp_platform_request_deployment(v_code, 'Register House Ltd', 'admin@' || v_code || '.test',
      'A client the register house suite asks for, to keep its history and start its build again.');
    v_req := (v_json ->> 'request_id')::uuid;
    v_id := (select e.id from erp_meta.deployment_event e where e.code = v_code order by e.id desc limit 1);

    -- ── 1. A step is not changed ────────────────────────────────────────────
    v_step := 'changing a step';
    begin
      update erp_meta.deployment_event e set detail = 'rewritten by the register house suite' where e.id = v_id;
      v_got := 'it was changed';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a step of a deployment''s history is not changed, by anyone';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_EVENT_KEPT: step ' || v_id || ' of ' || v_code || ' %changed'
          and (select e.detail from erp_meta.deployment_event e where e.id = v_id) like 'requested by ' || v_owner || '%';
    detail := left(v_got, 140);
    return next;

    -- ── 2. Nor removed ──────────────────────────────────────────────────────
    v_step := 'removing a step';
    v_n := (select count(*) from erp_meta.deployment_event e where e.code = v_code);
    begin
      delete from erp_meta.deployment_event e where e.code = v_code;
      v_got := 'it was removed';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'nor removed';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_EVENT_KEPT%removed' and v_n >= 1
          and (select count(*) from erp_meta.deployment_event e where e.code = v_code) = v_n;
    detail := v_n || ' step(s) / ' || left(v_got, 120);
    return next;

    -- ── 3. Nor emptied ──────────────────────────────────────────────────────
    v_step := 'emptying the history';
    v_n2 := (select count(*) from erp_meta.deployment_event);
    begin
      truncate erp_meta.deployment_event;
      v_got := 'it was emptied';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'nor emptied';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_EVENT_KEPT: the history of client deployments %emptied'
          and (select count(*) from erp_meta.deployment_event) = v_n2;
    detail := v_n2 || ' step(s) in all / ' || left(v_got, 120);
    return next;

    -- ── 4. Steps are still added, and the guard is nobody else's ───────────
    v_step := 'recording a step and running the generator';
    v_id := erp_meta.record_deployment_event(v_code, 'note', 'note', 'the register house suite adds a step');
    perform erp.apply_append_only_guards();
    v_n := (select count(*) from pg_catalog.pg_trigger t
             where t.tgrelid = 'erp_meta.deployment_event'::regclass and not t.tgisinternal
               and t.tgfoid = 'erp_meta.forbid_deployment_event_change'::regproc
               and (t.tgname, t.tgtype) in (('t_deployment_event_kept', 27::smallint),
                                            ('t_deployment_event_kept_whole', 34::smallint)));
    -- The organisations' guard is not put on it: it would read a tenant the
    -- table does not have.
    v_n2 := (select count(*) from pg_catalog.pg_trigger t
              where t.tgrelid = 'erp_meta.deployment_event'::regclass and not t.tgisinternal
                and (t.tgfoid = 'erp.forbid_mutation'::regproc or t.tgname = 't_deployment_event_append_only'));
    v_cases := v_cases + 1;
    case_name := 'a step is still added through the writer, and the generators leave the history''s own guard as it is';
    passed := exists (select 1 from erp_meta.deployment_event e
                       where e.id = v_id and e.code = v_code and e.detail = 'the register house suite adds a step')
          and v_n = 2 and v_n2 = 0
          and (select tp.table_class::text from erp_meta.table_policy tp
                where tp.schema_name = 'erp_meta' and tp.table_name = 'deployment_event') = 'platform_internal';
    detail := format('step %s added; %s guard trigger(s) of its own, %s of the organisations''',
                     coalesce(v_id::text, 'none'), v_n, v_n2);
    return next;

    -- ── 5. Only an owner, with a reason, on the control plane ───────────────
    v_step := 'starting again as an operator, without a reason, and on a client';
    update erp_meta.platform_staff set staff_role = 'operator' where auth_user_id = v_uid;
    begin
      perform public.erp_platform_restart_deployment(v_code, 'The register house suite starts again as an operator, which must refuse.');
      v_got := 'it was started again';
    exception when others then
      v_got := sqlerrm;
    end;
    update erp_meta.platform_staff set staff_role = 'owner' where auth_user_id = v_uid;
    begin
      perform public.erp_platform_restart_deployment(v_code, 'stuck');
      v_got2 := 'it was started again';
    exception when others then
      v_got2 := sqlerrm;
    end;
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"client"'::jsonb, 'register_house_suite');
    begin
      perform public.erp_platform_restart_deployment(v_code, 'The register house suite starts again on a client, which must refuse.');
      v_got3 := 'it was started again';
    exception when others then
      v_got3 := sqlerrm;
    end;
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'register_house_suite');
    v_cases := v_cases + 1;
    case_name := 'only an owner starts a build again, only with a reason, and only on the control plane';
    passed := v_got like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'
          and v_got2 like 'CLOVEERP_REASON_REQUIRED%'
          and v_got3 like 'CLOVEERP_NOT_THE_CONTROL_PLANE%'
          and (select x.status from erp_meta.fleet_request x where x.id = v_req) = 'requested';
    detail := left(v_got, 60) || ' / ' || left(v_got2, 60) || ' / ' || left(v_got3, 60);
    return next;

    -- ── 6. Not while the build may still be on its way ──────────────────────
    v_step := 'starting again a build asked for just now';
    begin
      perform public.erp_platform_restart_deployment(v_code, 'The register house suite starts a fresh request again, which must refuse.');
      v_got := 'it was started again';
    exception when others then
      v_got := sqlerrm;
    end;
    -- And a minute short of the twenty: the wait is twenty minutes, not less.
    update erp_meta.fleet_request x set created_at = now() - interval '19 minutes' where x.id = v_req;
    begin
      perform public.erp_platform_restart_deployment(v_code, 'The register house suite starts a request of nineteen minutes again, which must refuse.');
      v_got2 := 'it was started again';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code);
    v_cases := v_cases + 1;
    case_name := 'a build asked for less than twenty minutes ago is not started again, and the Fleet view does not offer it';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_STALE: ' || v_code || ' is not started again: its build was asked for 0 minute(s) ago%'
          and v_got2 like 'CLOVEERP_DEPLOYMENT_NOT_STALE: ' || v_code || ' is not started again: its build was asked for 19 minute(s) ago%'
          and v_row ->> 'restartable' = 'false'
          and (select x.status from erp_meta.fleet_request x where x.id = v_req) = 'requested'
          and (select count(*) from erp_meta.fleet_request x where x.kind = 'build' and x.payload ->> 'code' = v_code) = 1;
    detail := left(v_got, 120) || ' / ' || left(v_got2, 120) || ' / restartable ' || coalesce(v_row ->> 'restartable', 'missing');
    return next;

    -- ── 7. A request still waiting after twenty minutes ─────────────────────
    v_step := 'starting again a build that waited for the sweep';
    update erp_meta.fleet_request x set created_at = now() - interval '25 minutes' where x.id = v_req;
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code);
    v_json := public.erp_platform_restart_deployment(v_code, 'The sweep never claimed it; the register house suite starts it again.');
    v_req2 := (v_json ->> 'request_id')::uuid;
    select * into r from erp_meta.fleet_request x where x.id = v_req;
    select * into r2 from erp_meta.fleet_request x where x.id = v_req2;
    v_cases := v_cases + 1;
    case_name := 'a build request still waiting after twenty minutes is cancelled and a new one queued with the same payload, recorded and logged';
    passed := v_row ->> 'restartable' = 'true'
          and v_json ->> 'status' = 'requested' and v_json ->> 'previous_status' = 'requested'
          and (v_json ->> 'previous_request_id')::uuid = v_req
          and r.status = c_cancelled and r.settled_at is not null
          and r.outcome like 'started again by ' || v_owner || ' after 25 minutes%'
          and r2.status = 'requested' and r2.kind = 'build' and r2.payload = r.payload
          and r2.requested_by = v_staff and r2.reason = 'The sweep never claimed it; the register house suite starts it again.'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'requested'
          and exists (select 1 from erp_meta.deployment_event e where e.code = v_code and e.phase = 'retry'
                       and e.status = 'done' and e.detail like 'started again by ' || v_owner || ': its build request was requested%')
          and exists (select 1 from erp_meta.platform_audit a where a.action = 'platform.deployment_restarted'
                       and a.target = v_code and (a.detail ->> 'request_id')::uuid = v_req2);
    detail := coalesce(v_json::text, 'no answer') || ' / was ' || coalesce(r.status, 'missing') || ': ' || coalesce(r.outcome, 'no outcome');
    return next;

    -- ── 8. A request the sweep claimed and left ─────────────────────────────
    v_step := 'starting again a build the sweep claimed and left';
    v_got := erp_meta.claim_fleet_request('run-' || v_tag) ->> 'id';
    begin
      perform public.erp_platform_restart_deployment(v_code, 'The register house suite starts a fresh claim again, which must refuse.');
      v_got2 := 'it was started again';
    exception when others then
      v_got2 := sqlerrm;
    end;
    -- Aged, and still newer than the request it replaced (twenty-five minutes).
    -- A claimed request's wait is counted from its claim: asked for long ago,
    -- claimed nineteen minutes ago, it is not started again yet.
    update erp_meta.fleet_request x
       set created_at = now() - interval '24 minutes', claimed_at = now() - interval '19 minutes'
     where x.id = v_req2;
    begin
      perform public.erp_platform_restart_deployment(v_code, 'The register house suite starts a claim of nineteen minutes again, which must refuse.');
      v_got2 := v_got2 || ' / it was started again';
    exception when others then
      v_got2 := v_got2 || ' / ' || sqlerrm;
    end;
    update erp_meta.fleet_request x set claimed_at = now() - interval '22 minutes' where x.id = v_req2;
    v_json := public.erp_platform_restart_deployment(v_code, 'The sweep claimed it and stopped; the register house suite starts it again.');
    v_req := (v_json ->> 'request_id')::uuid;
    -- The sweep comes back late and settles what it claimed.
    v_got3 := erp_meta.settle_fleet_request(v_req2, 'success: deployment_from_empty.yml started');
    select * into r from erp_meta.fleet_request x where x.id = v_req2;
    v_cases := v_cases + 1;
    case_name := 'a build request the sweep claimed and left for twenty minutes is cancelled too, and the sweep''s late settle of it is let through quietly';
    passed := v_got = v_req2::text
          and v_got2 like 'CLOVEERP_DEPLOYMENT_NOT_STALE%claimed by the sweep 0 minute(s) ago% / CLOVEERP_DEPLOYMENT_NOT_STALE%claimed by the sweep 19 minute(s) ago%'
          and v_json ->> 'previous_status' = 'claimed' and (v_json ->> 'previous_request_id')::uuid = v_req2
          and r.status = c_cancelled and r.outcome like 'started again by ' || v_owner || '%'
          and v_got3 like 'request ' || v_req2 || ' was cancelled meanwhile%'
          and (select x.status from erp_meta.fleet_request x where x.id = v_req) = 'requested';
    detail := coalesce(v_got, 'no claim') || ' / ' || left(v_got2, 240) || ' / ' || left(coalesce(v_got3, 'no settle'), 80);
    return next;

    -- ── 9. A settle the sweep has no claim to is still refused ──────────────
    v_step := 'settling what was never claimed';
    begin
      perform erp_meta.settle_fleet_request(gen_random_uuid(), 'success');
      v_got := 'it was settled';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.settle_fleet_request(v_req, 'success');
      v_got2 := 'it was settled';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a request nobody claimed is not settled: an unknown one and a waiting one are both refused';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_STATE%' and v_got2 like 'CLOVEERP_DEPLOYMENT_STATE%'
          and (select x.status from erp_meta.fleet_request x where x.id = v_req) = 'requested';
    detail := left(v_got, 80) || ' / ' || left(v_got2, 80);
    return next;

    -- ── 10. A build the sweep started that never began ──────────────────────
    -- As the sweep leaves one: claimed, the workflow started, settled done.
    -- Its claim's own step is written as of its claim, before the settle, as
    -- the sweep records it: through the writer it would carry this
    -- transaction's time and read as after.
    v_step := 'starting again a build the sweep started that never began';
    v_json := public.erp_platform_request_deployment(v_code2, 'Register House Second Ltd', 'admin@' || v_code2 || '.test',
      'A second client, whose build the sweep starts and which never begins.');
    v_req2 := (v_json ->> 'request_id')::uuid;
    update erp_meta.fleet_request x
       set status = 'done', run_id = 'run-' || v_tag || '-b', claimed_at = now(), settled_at = now(),
           outcome = 'success: deployment_from_empty.yml started'
     where x.id = v_req2;
    begin
      perform public.erp_platform_restart_deployment(v_code2, 'The register house suite starts a build started just now, which must refuse.');
      v_got := 'it was started again';
    exception when others then
      v_got := sqlerrm;
    end;
    update erp_meta.fleet_request x
       set created_at = now() - interval '21 minutes', claimed_at = now() - interval '20 minutes',
           settled_at = now() - interval '19 minutes'
     where x.id = v_req2;
    begin
      perform public.erp_platform_restart_deployment(v_code2, 'The register house suite starts a build started nineteen minutes ago, which must refuse.');
      v_got2 := 'it was started again';
    exception when others then
      v_got2 := sqlerrm;
    end;
    update erp_meta.fleet_request x
       set created_at = now() - interval '40 minutes', claimed_at = now() - interval '35 minutes',
           settled_at = now() - interval '30 minutes'
     where x.id = v_req2;
    insert into erp_meta.deployment_event (code, phase, status, detail, run_id, at)
    values (v_code2, 'dispatch', 'done', 'claimed by the sweep', 'run-' || v_tag || '-b', now() - interval '35 minutes');
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code2);
    v_json := public.erp_platform_restart_deployment(v_code2, 'The build was started and never began; the register house suite starts it again.');
    v_cases := v_cases + 1;
    case_name := 'a build the sweep started is started again once twenty minutes pass with no step of it, not before, and its settled request stays done';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_STALE%the sweep started its build 0 minute(s) ago%'
          and v_got2 like 'CLOVEERP_DEPLOYMENT_NOT_STALE%the sweep started its build 19 minute(s) ago%'
          and v_row ->> 'restartable' = 'true'
          and v_json ->> 'previous_status' = 'done' and (v_json ->> 'previous_request_id')::uuid = v_req2
          and (select x.status from erp_meta.fleet_request x where x.id = v_req2) = 'done'
          and exists (select 1 from erp_meta.fleet_request x
                       where x.id = (v_json ->> 'request_id')::uuid and x.status = 'requested'
                         and x.payload = (select y.payload from erp_meta.fleet_request y where y.id = v_req2));
    detail := left(v_got, 100) || ' / ' || left(v_got2, 100) || ' / ' || coalesce(v_json::text, 'no answer');
    return next;

    -- ── 11. A build that began is not started again ─────────────────────────
    v_step := 'starting again a build that began';
    v_req2 := (v_json ->> 'request_id')::uuid;
    update erp_meta.fleet_request x
       set status = 'done', run_id = 'run-' || v_tag || '-c', claimed_at = now() - interval '31 minutes',
           settled_at = now() - interval '30 minutes', outcome = 'success: deployment_from_empty.yml started'
     where x.id = v_req2;
    perform erp_meta.record_deployment_event(v_code2, 'dispatch', 'done', 'run 7 started', 'run-' || v_tag || '-7');
    begin
      perform public.erp_platform_restart_deployment(v_code2, 'The register house suite starts a build that began, which must refuse.');
      v_got := 'it was started again';
    exception when others then
      v_got := sqlerrm;
    end;
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code2);
    v_cases := v_cases + 1;
    case_name := 'a build that recorded a step since the sweep started it is not started again, however long ago that was';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_STALE%its build has begun%'
          and v_row ->> 'restartable' = 'false'
          and (select count(*) from erp_meta.fleet_request x where x.kind = 'build' and x.payload ->> 'code' = v_code2) = 2;
    detail := left(v_got, 140);
    return next;

    -- ── 12. Only a build still waiting to start ─────────────────────────────
    v_step := 'starting again a build that failed';
    perform erp_meta.record_deployment_event(v_code, 'build', 'failed', 'the runner timed out', 'run-' || v_tag);
    -- Its open request has waited long enough; the deployment's state is what refuses.
    update erp_meta.fleet_request x set created_at = now() - interval '21 minutes' where x.id = v_req;
    begin
      perform public.erp_platform_restart_deployment(v_code, 'The register house suite starts a failed build again, which must refuse.');
      v_got := 'it was started again';
    exception when others then
      v_got := sqlerrm;
    end;
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code);
    v_cases := v_cases + 1;
    case_name := 'a deployment that is not waiting for its build is not started again: a failed one is retried instead';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_STALE%it is failed%retry it instead'
          and v_row ->> 'restartable' = 'false'
          and (select d.status from erp_meta.deployment d where d.code = v_code) = 'failed'
          and (select x.status from erp_meta.fleet_request x where x.id = v_req) = 'requested';
    detail := left(v_got, 140);
    return next;

    -- ── 13. What the Fleet view reads ───────────────────────────────────────
    v_step := 'reading the Fleet view';
    v_row2 := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code2);
    r := erp_meta.newest_build_request(v_code2);
    v_cases := v_cases + 1;
    case_name := 'the Fleet view keeps every key it had and reads when the newest build request was made, claimed and settled';
    passed := (select bool_and(v_row2 ? k) from unnest(array[
                 'code', 'client_name', 'status', 'owner_email', 'project_ref', 'api_url', 'region', 'instance_size',
                 'origin', 'build_run_id', 'built_at', 'last_release_sha', 'last_release_at', 'last_release_outcome',
                 'last_release_run_id', 'checklist', 'note', 'created_at', 'updated_at', 'request_status',
                 'request_run_id', 'last_event', 'request_created_at', 'request_claimed_at', 'request_settled_at',
                 'restartable']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 26
          and r.id = v_req2
          and v_row2 ->> 'request_status' = 'done'
          and v_row2 ->> 'request_run_id' = 'run-' || v_tag || '-c'
          and v_row2 -> 'request_created_at' = to_jsonb(r.created_at)
          and v_row2 -> 'request_claimed_at' = to_jsonb(r.claimed_at)
          and v_row2 -> 'request_settled_at' = to_jsonb(r.settled_at)
          and r.settled_at < now() - interval '29 minutes'
          and v_row2 -> 'last_event' ->> 'detail' = 'run 7 started';
    detail := coalesce(jsonb_build_object('request_status', v_row2 -> 'request_status',
                                          'request_created_at', v_row2 -> 'request_created_at',
                                          'request_claimed_at', v_row2 -> 'request_claimed_at',
                                          'request_settled_at', v_row2 -> 'request_settled_at',
                                          'restartable', v_row2 -> 'restartable')::text, 'no row');
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_REGISTER_HOUSE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.register_house_suite() from public, anon;

comment on function erp_test.register_house_suite() is
  'The register keeps its own house (20261011110000): a deployment''s history is not changed, removed or '
  'emptied, steps are still added, and its guard is its own; a build is started again only by an owner, with a '
  'reason, on the control plane, and only when its request waited twenty minutes or the build the sweep started '
  'never began; the open request is cancelled and the sweep''s late settle of it is let through; a request '
  'nobody claimed is not settled; the Fleet view reads the request''s times and the door''s rule.';

create or replace function erp_test.assert_register_house_suite()
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
    from erp_test.register_house_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_REGISTER_HOUSE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The register of client deployments misbehaves: read the case that failed.';
  end if;
  if v_total <> 13 then
    raise exception 'CLOVEERP_REGISTER_HOUSE_SUITE_SHRANK: % case(s), expected 13', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('register house: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_register_house_suite() from public, anon;

comment on function erp_test.assert_register_house_suite() is
  'A client deployment''s history is kept as recorded, a build that waited too long is started again by the '
  'owner and by no one else, the sweep''s late settle of a cancelled request passes, and the Fleet view reads '
  'the newest request''s times (20261011110000).';

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
