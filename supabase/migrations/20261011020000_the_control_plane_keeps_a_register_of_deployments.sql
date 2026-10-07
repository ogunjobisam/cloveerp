set lock_timeout = '30s';

-- =============================================================================
-- 20261011020000  The control plane keeps a register of deployments
-- -----------------------------------------------------------------------------
-- One Supabase project per client, one subdomain each (20261011010000, the
-- owner's decision of 7 October). Somebody has to know which clients there
-- are, which project each runs in, where each is served from, how far its
-- build has got and what the last release did to it. That somebody is
-- production, the control plane, and this is the register.
--
-- Three tables, all platform-internal, all empty on every database but the
-- control plane:
--
--   erp_meta.deployment        one row per client deployment: its code (which
--                              is its address, <code>.cloveerp.com), its
--                              name, its status from requested through built
--                              and live to retired, its project's ref and
--                              public keys, the last release, and a checklist
--                              of the steps a person still does by hand. NO
--                              CREDENTIAL: the connection string and the
--                              secret key live in the control plane's vault,
--                              named by the project's ref
--                              (cloveerp:deployment:<ref>:db_url,
--                              cloveerp:deployment:<ref>:service_key), and
--                              are read by the workflows alone.
--   erp_meta.deployment_event  what the build and the releases did, step by
--                              step, so the console can show a build's
--                              progress and a release's outcome without a
--                              run log.
--   erp_meta.fleet_request     what the console asked for — a build, a
--                              release — for the workflow sweep to claim.
--                              The console never holds a token for GitHub;
--                              it writes a row, and a scheduled workflow
--                              reads the row with the repository's own
--                              token and starts the run. Ten minutes at most.
--
-- Who writes what:
--
--   the console   erp_platform_request_deployment (owner), which also
--                 queues the build; erp_platform_request_release (owner);
--                 erp_platform_retry_deployment (owner);
--                 erp_platform_deployment_checklist (operator and above).
--                 Reads: erp_platform_deployments, erp_platform_deployment_
--                 events (support and above). Every one of them asks
--                 erp.require_control_plane() first: a client's own console
--                 has no register and knows nothing of the others.
--   the workflows trusted routines in erp_meta, executable by the build role
--                 alone, as erp_meta.mark_deployment is: register_deployment_
--                 project, record_deployment_event, deployment_built, record_
--                 deployment_release, claim_fleet_request, settle_fleet_
--                 request.
--   the browser   public.erp_deployment_for_host, executable by service_role
--                 alone, from the directory the application asks at
--                 /api/directory/<host> before it talks to any project: the
--                 project a host belongs to, or nothing. The pattern of
--                 erp_tenant_by_address (20261003200000).
--
-- And one rule across the fleet: a code is held once. erp.tenant_code_refusal
-- learns that a client deployment's code is an address another organisation
-- cannot take, on the control plane or anywhere, and the request door asks
-- the same function, so a deployment cannot take an organisation's address
-- either.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No permission code and no organisation's screen. The contracts a client
-- signs still live on the control plane; the next migration lets one name a
-- deployment. Nothing here reaches a client's database.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_UNKNOWN',
  'Naming a client deployment the register does not hold.',
  'The register on the control plane is the only list of client deployments; a code that is not in it is '
  'nobody''s.',
  'Choose the deployment from the Fleet view, or request it first.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_EXISTS',
  'Requesting a client deployment under a code the register already holds.',
  'A code is held once across the fleet: it is the client''s address, and two deployments at one address is '
  'nobody''s address.',
  'Open the deployment''s row in the Fleet view; retry its build from there if it failed.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_OWNER_EMAIL_INVALID',
  'Requesting a client deployment without an email address for its first administrator.',
  'The build invites nobody; the administrator is onboarded from the client''s own console once it is live. '
  'Their address is kept here so that console''s first act is known before the build starts.',
  'Give the administrator''s email address.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_RETRYABLE',
  'Retrying the build of a deployment that is built, live or retired.',
  'A build is carried on only while it has not finished: a deployment that is built or live is released into, '
  'not built again, and a retired one is gone.',
  'If the deployment is live, release to it from the Fleet view instead.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_STATE',
  'Recording a step of a deployment''s build or release that its state does not allow.',
  'The register moves a deployment from requested through creating and building to built, live and retired, '
  'and a step recorded out of that order would describe a build that did not happen that way.',
  'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.');

select erp.register_refusal(
  'CLOVEERP_CHECKLIST_ITEM_UNKNOWN',
  'Ticking a step of a deployment''s checklist that the checklist does not have.',
  'The checklist holds the steps a person still does by hand after a build: the Lovable domain, the DNS '
  'records, Google sign-in if the client wants it, and the email provider''s webhook.',
  'Tick one of: lovable_domain, dns, google_sign_in, resend_webhook.');

select erp.register_refusal(
  'CLOVEERP_RELEASE_TARGET_UNKNOWN',
  'Asking for a release to something that is not a deployment.',
  'A release goes to all, to the control plane, to the demonstration, or to a client deployment that is built '
  'or live.',
  'Name all, control, demonstration, or a built client''s code.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The register
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp_meta.deployment (
  code                 text primary key
                         check (code ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'),
  client_name          text not null check (length(btrim(client_name)) between 2 and 120),
  status               text not null default 'requested'
                         check (status in ('requested', 'creating', 'building', 'built', 'live',
                                           'suspended', 'retiring', 'retired', 'failed')),
  owner_email          text not null
                         check (owner_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  project_ref          text unique check (project_ref ~ '^[a-z0-9]{20}$'),
  api_url              text check (api_url ~ '^https://[a-z0-9.-]+$'),
  publishable_key      text,
  region               text not null default 'eu-central-1',
  instance_size        text not null default 'micro',
  build_run_id         text,
  built_at             timestamptz,
  last_release_sha     text,
  last_release_at      timestamptz,
  last_release_outcome text check (last_release_outcome in ('success', 'failure', 'cancelled')),
  last_release_run_id  text,
  checklist            jsonb not null default '{}'::jsonb,
  requested_by         uuid,
  note                 text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table erp_meta.deployment is
  'The control plane''s register of client deployments (20261011020000): one Supabase project per client, '
  'served at <code>.cloveerp.com. Holds no credential: the connection string and the secret key are in the '
  'control plane''s vault, named cloveerp:deployment:<ref>:db_url and cloveerp:deployment:<ref>:service_key. '
  'Empty on every database but the control plane.';

comment on column erp_meta.deployment.code is
  'The client''s code, which is its address: <code>.cloveerp.com. Held once across the fleet '
  '(erp.tenant_code_refusal).';
comment on column erp_meta.deployment.owner_email is
  'The client''s first administrator, onboarded from the client''s own console once it is live. The build '
  'invites nobody.';
comment on column erp_meta.deployment.publishable_key is
  'The project''s publishable key, public by design: the browser receives it from the directory.';
comment on column erp_meta.deployment.checklist is
  'The steps a person still does by hand after the build, ticked from the console: '
  '{"lovable_domain": {"done": true, "at": ..., "by": ...}, "dns": ..., "google_sign_in": ..., "resend_webhook": ...}.';

create table if not exists erp_meta.deployment_event (
  id       bigint generated always as identity primary key,
  code     text not null references erp_meta.deployment (code),
  phase    text not null
             check (phase in ('request', 'dispatch', 'create', 'configure', 'build', 'identity', 'functions',
                              'prove', 'release', 'retry', 'checklist', 'note')),
  status   text not null check (status in ('started', 'done', 'failed', 'note')),
  detail   text,
  run_id   text,
  at       timestamptz not null default now()
);

comment on table erp_meta.deployment_event is
  'What a client deployment''s build and releases did, step by step, as the workflows recorded it '
  '(20261011020000). The console shows a build''s progress from here.';

create index if not exists deployment_event_code_at on erp_meta.deployment_event (code, at desc);

create table if not exists erp_meta.fleet_request (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('build', 'release')),
  payload      jsonb not null default '{}'::jsonb,
  status       text not null default 'requested'
                 check (status in ('requested', 'claimed', 'done', 'failed', 'cancelled')),
  reason       text,
  requested_by uuid,
  run_id       text,
  outcome      text,
  created_at   timestamptz not null default now(),
  claimed_at   timestamptz,
  settled_at   timestamptz
);

comment on table erp_meta.fleet_request is
  'What the console asked the workflows for — a build of a client deployment, a release train — for the '
  'scheduled sweep (fleet_sweep.yml) to claim with the repository''s own token (20261011020000). The console '
  'holds no token.';

create index if not exists fleet_request_open on erp_meta.fleet_request (created_at) where status = 'requested';

select erp_meta.register_table('erp_meta', 'deployment', 'platform_internal',
  'The control plane''s register of client deployments. Reachable only through SECURITY DEFINER doors for '
  'platform staff and the trusted build role; holds no credential.');
select erp_meta.register_table('erp_meta', 'deployment_event', 'platform_internal',
  'What a client deployment''s build and releases did, step by step.');
select erp_meta.register_table('erp_meta', 'fleet_request', 'platform_internal',
  'What the console asked the workflows for, claimed by the scheduled sweep.');

revoke all on table erp_meta.deployment, erp_meta.deployment_event, erp_meta.fleet_request
  from public, anon, authenticated;

-- The client's first administrator is a person, and their erasure is the
-- platform owner's process rather than an organisation's: the subject is in no
-- tenant on this database, so erp.execute_erasure() cannot reach them, as with
-- erp_meta.enquiry (20260904950000). Retiring the deployment clears the column.
insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp_meta', 'deployment', 'owner_email',
   'A client deployment''s first administrator is nobody''s tenant subject on the control plane: they belong '
   'to an organisation on another database. Kept until the deployment is retired, when the register clears it; '
   'erp.execute_erasure() resolves subjects inside one organisation and cannot reach a row that is in none.')
on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A code is held once across the fleet
-- ─────────────────────────────────────────────────────────────────────────────

do $code$
declare
  v_sig  constant text := 'erp.tenant_code_refusal(text,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" was another organisation''s address and still opens theirs'
$o$;
  v_new  constant text := $n$      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" was another organisation''s address and still opens theirs'
    -- A client deployment's code is its address, <code>.cloveerp.com, held
    -- once across the fleet (20261011020000).
    when exists (select 1 from erp_meta.deployment d where d.code = p_code) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" is a client deployment''s address'
$n$;
begin
  if strpos(v_src, '20261011020000') > 0 then
    raise notice '% already refuses a deployment''s code; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '4597990603dcec74a372a362dc14d46c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261011020000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$code$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. What the workflows write
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.deployment_row(p_code text)
returns erp_meta.deployment
language plpgsql
stable
set search_path = ''
as $$
declare
  d erp_meta.deployment;
begin
  select * into d from erp_meta.deployment x where x.code = lower(btrim(coalesce(p_code, '')));
  if d.code is null then
    raise exception 'CLOVEERP_DEPLOYMENT_UNKNOWN: no client deployment is registered as "%"', p_code
      using errcode = '23503',
            hint = 'Choose the deployment from the Fleet view, or request it first.';
  end if;
  return d;
end;
$$;

revoke all on function erp_meta.deployment_row(text) from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_row(text) is
  'The register''s row for a code, or CLOVEERP_DEPLOYMENT_UNKNOWN (20261011020000).';

create or replace function erp_meta.record_deployment_event(
  p_code text, p_phase text, p_status text, p_detail text default null, p_run_id text default null)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  d     erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_id  bigint;
  v_to  text;
begin
  if p_phase not in ('request', 'dispatch', 'create', 'configure', 'build', 'identity', 'functions',
                     'prove', 'release', 'retry', 'checklist', 'note')
     or p_status not in ('started', 'done', 'failed', 'note') then
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: "% %" is not a step of a build or a release', p_phase, p_status
      using errcode = '22023',
            hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
  end if;
  insert into erp_meta.deployment_event (code, phase, status, detail, run_id)
  values (d.code, p_phase, p_status, nullif(btrim(coalesce(p_detail, '')), ''), nullif(btrim(coalesce(p_run_id, '')), ''))
  returning id into v_id;

  -- The step moves the status where the step says so; a retired or live
  -- deployment is not moved back into a build by a late event.
  v_to := case
            when p_status = 'failed' and d.status in ('requested', 'creating', 'building') then 'failed'
            when p_phase = 'create' and p_status = 'started' and d.status in ('requested', 'failed') then 'creating'
            when p_phase = 'build' and p_status = 'started' and d.status in ('requested', 'creating', 'failed') then 'building'
            else null
          end;
  if v_to is not null then
    update erp_meta.deployment x
       set status = v_to,
           build_run_id = coalesce(nullif(btrim(coalesce(p_run_id, '')), ''), x.build_run_id),
           updated_at = now()
     where x.code = d.code;
  end if;
  return v_id;
end;
$$;

revoke all on function erp_meta.record_deployment_event(text, text, text, text, text)
  from public, anon, authenticated, service_role;

comment on function erp_meta.record_deployment_event(text, text, text, text, text) is
  'One step of a client deployment''s build or release, as a workflow records it, moving the status where the '
  'step says so (create started: creating; build started: building; anything failed while building: failed). '
  'Trusted build role only (20261011020000).';

create or replace function erp_meta.register_deployment_project(
  p_code text, p_ref text, p_api_url text, p_publishable_key text,
  p_region text default null, p_instance_size text default null)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d erp_meta.deployment := erp_meta.deployment_row(p_code);
begin
  if p_ref !~ '^[a-z0-9]{20}$' then
    raise exception 'CLOVEERP_DEPLOYMENT_REF_INVALID: "%" is not a Supabase project ref', p_ref
      using errcode = '22023',
            hint = 'Pass the project ref the connection string names.';
  end if;
  if d.project_ref is not null and d.project_ref <> p_ref then
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: % already runs in project %, not %', d.code, d.project_ref, p_ref
      using errcode = '55000',
            hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
  end if;
  if d.status not in ('requested', 'creating', 'building', 'failed') then
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: % is %, and its project is not registered again', d.code, d.status
      using errcode = '55000',
            hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
  end if;
  update erp_meta.deployment x
     set project_ref = p_ref,
         api_url = coalesce(nullif(btrim(coalesce(p_api_url, '')), ''), x.api_url),
         publishable_key = coalesce(nullif(btrim(coalesce(p_publishable_key, '')), ''), x.publishable_key),
         region = coalesce(nullif(btrim(coalesce(p_region, '')), ''), x.region),
         instance_size = coalesce(nullif(btrim(coalesce(p_instance_size, '')), ''), x.instance_size),
         status = case when x.status = 'requested' then 'creating' else x.status end,
         updated_at = now()
   where x.code = d.code;
  perform erp_meta.record_deployment_event(d.code, 'create', 'done', format('project %s in %s', p_ref, coalesce(p_region, d.region)));
  return format('%s runs in project %s', d.code, p_ref);
end;
$$;

revoke all on function erp_meta.register_deployment_project(text, text, text, text, text, text)
  from public, anon, authenticated, service_role;

comment on function erp_meta.register_deployment_project(text, text, text, text, text, text) is
  'The project a client deployment runs in, as the build from empty made it: its ref, API URL and publishable '
  'key. Trusted build role only (20261011020000).';

create or replace function erp_meta.deployment_built(p_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d erp_meta.deployment := erp_meta.deployment_row(p_code);
begin
  if d.project_ref is null or d.status not in ('building', 'creating') then
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: % is %, and only a deployment being built is marked built',
      d.code, d.status || case when d.project_ref is null then ' with no project' else '' end
      using errcode = '55000',
            hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
  end if;
  update erp_meta.deployment x set status = 'built', built_at = now(), updated_at = now() where x.code = d.code;
  perform erp_meta.record_deployment_event(d.code, 'build', 'done', 'built from empty and proved');
  return format('%s built', d.code);
end;
$$;

revoke all on function erp_meta.deployment_built(text) from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_built(text) is
  'A client deployment''s build from empty finished and proved itself. Trusted build role only (20261011020000).';

create or replace function erp_meta.record_deployment_release(
  p_code text, p_sha text, p_outcome text, p_run_id text default null, p_detail text default null)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d         erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_outcome text := lower(btrim(coalesce(p_outcome, '')));
begin
  if v_outcome not in ('success', 'failure', 'cancelled') then
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: "%" is not a release outcome', p_outcome
      using errcode = '22023',
            hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
  end if;
  update erp_meta.deployment x
     set last_release_sha = p_sha,
         last_release_at = now(),
         last_release_outcome = v_outcome,
         last_release_run_id = nullif(btrim(coalesce(p_run_id, '')), ''),
         status = case when v_outcome = 'success' and x.status = 'built' then 'live' else x.status end,
         updated_at = now()
   where x.code = d.code;
  perform erp_meta.record_deployment_event(d.code, 'release',
    case v_outcome when 'success' then 'done' else 'failed' end,
    coalesce(nullif(btrim(coalesce(p_detail, '')), ''), format('release of %s: %s', left(coalesce(p_sha, ''), 12), v_outcome)),
    p_run_id);
  return format('%s: release of %s %s', d.code, left(coalesce(p_sha, ''), 12), v_outcome);
end;
$$;

revoke all on function erp_meta.record_deployment_release(text, text, text, text, text)
  from public, anon, authenticated, service_role;

comment on function erp_meta.record_deployment_release(text, text, text, text, text) is
  'What a release did to a client deployment, as release.yml records it at the end whatever happened: the sha, '
  'the outcome, the run. The first success makes a built deployment live. Trusted build role only (20261011020000).';

create or replace function erp_meta.claim_fleet_request(p_run_id text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  r erp_meta.fleet_request;
begin
  update erp_meta.fleet_request x
     set status = 'claimed', run_id = nullif(btrim(coalesce(p_run_id, '')), ''), claimed_at = now()
   where x.id = (select y.id from erp_meta.fleet_request y
                  where y.status = 'requested'
                  order by y.created_at
                  limit 1
                  for update skip locked)
  returning * into r;
  if r.id is null then
    return null;
  end if;
  if r.kind = 'build' and (r.payload ->> 'code') is not null then
    perform erp_meta.record_deployment_event(r.payload ->> 'code', 'dispatch', 'done',
      'claimed by the sweep', p_run_id);
  end if;
  return jsonb_build_object('id', r.id, 'kind', r.kind, 'payload', r.payload, 'created_at', r.created_at);
end;
$$;

revoke all on function erp_meta.claim_fleet_request(text) from public, anon, authenticated, service_role;

comment on function erp_meta.claim_fleet_request(text) is
  'The oldest open request from the console, claimed by the sweep that will start its workflow run; null when '
  'there is none. Trusted build role only (20261011020000).';

create or replace function erp_meta.settle_fleet_request(p_id uuid, p_outcome text)
returns text
language plpgsql
set search_path = ''
as $$
declare
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
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: request % is not claimed, so it is not settled', p_id
      using errcode = '55000',
            hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
  end if;
  return format('request %s %s', r.id, r.status);
end;
$$;

revoke all on function erp_meta.settle_fleet_request(uuid, text) from public, anon, authenticated, service_role;

comment on function erp_meta.settle_fleet_request(uuid, text) is
  'A claimed request settled by the sweep: done, or failed with why. Trusted build role only (20261011020000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. What the console reads and asks
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
             -- The open or running request for its build, if any: the console
             -- says "queued" or "running" from this rather than guessing.
             'request_status', (select r.status from erp_meta.fleet_request r
                                 where r.kind = 'build' and r.payload ->> 'code' = d.code
                                 order by r.created_at desc limit 1),
             'request_run_id', (select r.run_id from erp_meta.fleet_request r
                                 where r.kind = 'build' and r.payload ->> 'code' = d.code
                                 order by r.created_at desc limit 1),
             'last_event', (select jsonb_build_object('phase', e.phase, 'status', e.status, 'detail', e.detail, 'at', e.at)
                              from erp_meta.deployment_event e
                             where e.code = d.code
                             order by e.at desc, e.id desc limit 1))
           order by d.created_at)
      from erp_meta.deployment d), '[]'::jsonb);
end;
$$;

revoke all on function public.erp_platform_deployments() from public, anon;
grant execute on function public.erp_platform_deployments() to authenticated, service_role;

comment on function public.erp_platform_deployments() is
  'Every client deployment in the register, with its build''s last step and its last release, for the Fleet '
  'view. Platform support and above, on the control plane only (20261011020000).';

create or replace function public.erp_platform_deployment_events(p_code text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
  d erp_meta.deployment;
begin
  v := erp_meta.require_platform('support');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'phase', e.phase, 'status', e.status, 'detail', e.detail,
                                        'run_id', e.run_id, 'at', e.at)
                     order by e.at desc, e.id desc)
      from (select * from erp_meta.deployment_event x where x.code = d.code order by x.at desc, x.id desc limit 200) e),
    '[]'::jsonb);
end;
$$;

revoke all on function public.erp_platform_deployment_events(text) from public, anon;
grant execute on function public.erp_platform_deployment_events(text) to authenticated, service_role;

comment on function public.erp_platform_deployment_events(text) is
  'A client deployment''s build and release steps, newest first, for the Fleet view. Platform support and '
  'above, on the control plane only (20261011020000).';

create or replace function public.erp_platform_request_deployment(
  p_code text, p_client_name text, p_owner_email text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  v_code  text := lower(btrim(coalesce(p_code, '')));
  v_email text := lower(btrim(coalesce(p_owner_email, '')));
  v_why   text;
  v_req   uuid;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: requesting a client deployment needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say which client this is for and what was agreed; it is kept with the deployment and in the platform''s activity log. At least twenty characters.';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'CLOVEERP_DEPLOYMENT_OWNER_EMAIL_INVALID: "%" is not an email address', p_owner_email
      using errcode = '22023',
            hint = 'Give the administrator''s email address.';
  end if;
  if length(btrim(coalesce(p_client_name, ''))) < 2 then
    raise exception 'CLOVEERP_REASON_REQUIRED: a client deployment needs the client''s name'
      using errcode = '22023',
            hint = 'Give the client''s name as it will appear in the console.';
  end if;
  if exists (select 1 from erp_meta.deployment d where d.code = v_code) then
    raise exception 'CLOVEERP_DEPLOYMENT_EXISTS: % is already a client deployment', v_code
      using errcode = '23505',
            hint = 'Open the deployment''s row in the Fleet view; retry its build from there if it failed.';
  end if;
  -- The same rule an organisation's address meets: shape, reserved words,
  -- another organisation's address here, a retired one — and now another
  -- deployment's.
  v_why := erp.tenant_code_refusal(v_code, null);
  if v_why is not null then
    raise exception '%', v_why
      using errcode = '23514',
            hint = 'Choose another code: it becomes the client''s address, <code>.cloveerp.com.';
  end if;

  insert into erp_meta.deployment (code, client_name, owner_email, requested_by, note)
  values (v_code, btrim(p_client_name), v_email, v.id, btrim(p_reason));
  insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
  values ('build', jsonb_build_object('code', v_code), btrim(p_reason), v.id)
  returning id into v_req;
  perform erp_meta.record_deployment_event(v_code, 'request', 'done',
    format('requested by %s; the build starts within ten minutes', v.email));

  perform erp_meta.platform_log(v, 'platform.deployment_requested', null, v_code, p_reason,
    jsonb_build_object('client_name', btrim(p_client_name), 'owner_email', v_email, 'request_id', v_req));

  return jsonb_build_object('code', v_code, 'status', 'requested', 'request_id', v_req);
end;
$$;

revoke all on function public.erp_platform_request_deployment(text, text, text, text) from public, anon;
grant execute on function public.erp_platform_request_deployment(text, text, text, text) to authenticated, service_role;

comment on function public.erp_platform_request_deployment(text, text, text, text) is
  'Requests a client deployment: a row in the register and a build request the sweep starts within ten '
  'minutes. Platform owner, on the control plane, with a reason; the code meets the rule an address meets '
  '(20261011020000).';

create or replace function public.erp_platform_retry_deployment(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v     erp_meta.platform_staff;
  d     erp_meta.deployment;
  v_req uuid;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);
  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: retrying a build needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say what stopped the build and what was done about it. At least twenty characters.';
  end if;
  if d.status not in ('requested', 'creating', 'building', 'failed') then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_RETRYABLE: % is %, and its build is not retried', d.code, d.status
      using errcode = '55000',
            hint = 'If the deployment is live, release to it from the Fleet view instead.';
  end if;
  if exists (select 1 from erp_meta.fleet_request r
              where r.kind = 'build' and r.payload ->> 'code' = d.code and r.status in ('requested', 'claimed')) then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_RETRYABLE: % already has a build request open', d.code
      using errcode = '55000',
            hint = 'If the deployment is live, release to it from the Fleet view instead.';
  end if;
  insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
  values ('build', jsonb_build_object('code', d.code, 'resume', d.project_ref is not null), btrim(p_reason), v.id)
  returning id into v_req;
  update erp_meta.deployment x set status = 'requested', updated_at = now() where x.code = d.code;
  perform erp_meta.record_deployment_event(d.code, 'retry', 'done',
    format('retried by %s%s: %s', v.email, case when d.project_ref is not null then ', carrying on' else '' end, btrim(p_reason)));
  perform erp_meta.platform_log(v, 'platform.deployment_retried', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'resume', d.project_ref is not null, 'request_id', v_req));
  return jsonb_build_object('code', d.code, 'status', 'requested', 'request_id', v_req);
end;
$$;

revoke all on function public.erp_platform_retry_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_retry_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_retry_deployment(text, text) is
  'Queues the build of a client deployment again after it failed or stalled, carrying on where it stopped '
  'when its project exists. Platform owner, on the control plane, with a reason (20261011020000).';

create or replace function public.erp_platform_request_release(p_targets text[], p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v         erp_meta.platform_staff;
  v_targets text[] := (select array_agg(distinct lower(btrim(t)) order by lower(btrim(t)))
                         from unnest(coalesce(p_targets, '{}'::text[])) t
                        where btrim(t) <> '');
  t         text;
  v_req     uuid;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: asking for a release needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say what is being released and why now; it is kept in the platform''s activity log. At least twenty characters.';
  end if;
  if v_targets is null or cardinality(v_targets) = 0 then
    raise exception 'CLOVEERP_RELEASE_TARGET_UNKNOWN: no target was named'
      using errcode = '22023',
            hint = 'Name all, control, demonstration, or a built client''s code.';
  end if;
  foreach t in array v_targets loop
    if t not in ('all', 'control', 'demonstration')
       and not exists (select 1 from erp_meta.deployment d where d.code = t and d.status in ('built', 'live')) then
      raise exception 'CLOVEERP_RELEASE_TARGET_UNKNOWN: "%" is not all, control, demonstration, or a built client', t
        using errcode = '22023',
              hint = 'Name all, control, demonstration, or a built client''s code.';
    end if;
  end loop;
  insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
  values ('release', jsonb_build_object('targets', to_jsonb(v_targets)), btrim(p_reason), v.id)
  returning id into v_req;
  perform erp_meta.platform_log(v, 'platform.release_requested', null, array_to_string(v_targets, ','), p_reason,
    jsonb_build_object('targets', to_jsonb(v_targets), 'request_id', v_req));
  return jsonb_build_object('request_id', v_req, 'targets', to_jsonb(v_targets));
end;
$$;

revoke all on function public.erp_platform_request_release(text[], text) from public, anon;
grant execute on function public.erp_platform_request_release(text[], text) to authenticated, service_role;

comment on function public.erp_platform_request_release(text[], text) is
  'Asks for a release train — to all, the control plane, the demonstration, or named built clients — which '
  'the sweep starts within ten minutes. Platform owner, on the control plane, with a reason (20261011020000).';

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
  if v_item not in ('lovable_domain', 'dns', 'google_sign_in', 'resend_webhook') then
    raise exception 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN: "%" is not a step of the checklist', p_item
      using errcode = '22023',
            hint = 'Tick one of: lovable_domain, dns, google_sign_in, resend_webhook.';
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
  'Ticks or unticks one of the steps a person does by hand after a client deployment''s build: the Lovable '
  'domain, the DNS records, Google sign-in, the email provider''s webhook. Platform operator and above, on the '
  'control plane (20261011020000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- F. What the browser asks: which project a host belongs to
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_deployment_for_host(p_host text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  -- The host, lower-cased and without a port, must be <code>.<apex>, where
  -- the apex is the host this control plane is served from. A deployment that
  -- is not yet built, that failed, or that is retired has no address; one
  -- suspended or retiring keeps it, so its people reach its own refusal.
  with asked as (
    select lower(btrim(coalesce(p_host, ''))) as host,
           regexp_replace(erp.app_origin(), '^https://', '') as apex)
  select jsonb_build_object('code', d.code, 'client_name', d.client_name, 'url', d.api_url, 'key', d.publishable_key)
    from asked a
    join erp_meta.deployment d
      on a.host = d.code || '.' || a.apex
   where d.status in ('built', 'live', 'suspended', 'retiring')
     and d.api_url is not null
     and d.publishable_key is not null
   limit 1
$$;

revoke all on function public.erp_deployment_for_host(text) from public, anon, authenticated;
grant execute on function public.erp_deployment_for_host(text) to service_role;

comment on function public.erp_deployment_for_host(text) is
  'The client deployment a host names: its code, name, API URL and publishable key, or null. Executed by '
  'service_role only, from the directory the application asks at /api/directory/<host> before it talks to '
  'any project; answers nothing else (20261011020000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_deployment_for_host',
   'UNGATED BY DESIGN: a browser opened at <code>.cloveerp.com has no session yet and must learn which '
   'project to sign in to. Executable by service_role alone, from src/routes/api/directory/$host.ts; no '
   'session role reaches it. Runs as its owner because erp_meta.deployment is closed. It answers a host with '
   'that deployment''s code, name, API URL and publishable key — all public by design — and nothing else. '
   'erp_test.deployment_register_suite proves what it answers.'),
  ('erp_meta', 'deployment_row',
   'Reads the register of client deployments, which no organisation owns. Called only by the register''s own '
   'doors and trusted writers; not executable by any session role.'),
  ('public', 'erp_platform_deployments',
   'Platform door, gated by erp_meta.require_platform(''support'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Reads the register of client '
   'deployments and nothing of any organisation.'),
  ('public', 'erp_platform_deployment_events',
   'Platform door, gated by erp_meta.require_platform(''support'') and erp.require_control_plane() on its first '
   'lines. Reads one deployment''s build and release steps.'),
  ('public', 'erp_platform_request_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its '
   'first lines. Writes one register row, one build request and the platform audit row; the code meets the '
   'rule an organisation''s address meets.'),
  ('public', 'erp_platform_retry_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its '
   'first lines. Queues a failed or stalled build again and writes the platform audit row.'),
  ('public', 'erp_platform_request_release',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its '
   'first lines. Writes one release request and the platform audit row.'),
  ('public', 'erp_platform_deployment_checklist',
   'Platform door, gated by erp_meta.require_platform(''operator'') and erp.require_control_plane() on its '
   'first lines. Ticks one step of a deployment''s checklist and writes the platform audit row.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_deployments', 'erp_meta.require_platform',
   'Reads the register of client deployments for the Fleet view; platform support and above, binding the sign-in on first use.'),
  ('erp_platform_deployment_events', 'erp_meta.require_platform',
   'Reads one client deployment''s build and release steps; platform support and above, binding the sign-in on first use.'),
  ('erp_platform_request_deployment', 'erp_meta.require_platform',
   'Requests a client deployment and queues its build; platform owner, with a reason kept in the activity log.'),
  ('erp_platform_retry_deployment', 'erp_meta.require_platform',
   'Queues a client deployment''s build again; platform owner, with a reason kept in the activity log.'),
  ('erp_platform_request_release', 'erp_meta.require_platform',
   'Asks for a release train; platform owner, with a reason kept in the activity log.'),
  ('erp_platform_deployment_checklist', 'erp_meta.require_platform',
   'Ticks a step of a client deployment''s checklist; platform operator and above, recorded in the activity log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.platform_door_rank (schema_name, function_name, minimum_role, why) values
  ('public', 'erp_platform_request_deployment', 'owner',
   'Makes a Supabase project the owner pays for, under a code that becomes a client''s address.'),
  ('public', 'erp_platform_retry_deployment', 'owner',
   'Starts a build against a client''s project again; what it carries on is the owner''s to judge.'),
  ('public', 'erp_platform_request_release', 'owner',
   'Starts a release train across every client; the owner decides when a sprint''s work goes out.')
on conflict (schema_name, function_name, minimum_role) do update set why = excluded.why;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The proof
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
    v_step := 'ticking the checklist';
    v_json := public.erp_platform_deployment_checklist(v_code, 'lovable_domain', true);
    begin
      perform public.erp_platform_deployment_checklist(v_code, 'coffee', true);
      v_got := 'it was ticked';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a step done by hand is ticked on the checklist; a step the checklist does not have is refused';
    passed := (v_json -> 'checklist' -> 'lovable_domain' ->> 'done') = 'true'
          and (v_json -> 'checklist' -> 'lovable_domain' ->> 'by') = v_owner
          and v_got like 'CLOVEERP_CHECKLIST_ITEM_UNKNOWN%';
    detail := coalesce(v_json::text, 'no checklist') || ' / ' || left(v_got, 60);
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
  'The control plane''s register of client deployments (20261011020000): kept on the control plane only; an '
  'owner requests one and a build request opens; a code is held once across the fleet; support reads and may '
  'not ask; the sweep claims a request once; the build moves the row to built; the directory answers a host to '
  'service_role alone; a release makes it live and a train is asked for by name; the checklist; a live '
  'deployment is not built again and a failed one is.';

create or replace function erp_test.assert_deployment_register_suite()
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
    from erp_test.deployment_register_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEPLOYMENT_REGISTER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The register of client deployments misbehaves: read the case that failed.';
  end if;
  if v_total <> 10 then
    raise exception 'CLOVEERP_DEPLOYMENT_REGISTER_SUITE_SHRANK: % case(s), expected 10', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment register: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_deployment_register_suite() from public, anon;

comment on function erp_test.assert_deployment_register_suite() is
  'The control plane keeps the register of client deployments, moves each from requested to live as the '
  'workflows record it, and answers the directory to service_role alone (20261011020000).';

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
