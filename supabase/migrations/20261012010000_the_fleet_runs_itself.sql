set lock_timeout = '30s';

-- =============================================================================
-- 20261012010000  The fleet runs itself
-- -----------------------------------------------------------------------------
-- The control plane's register of client deployments (20261011020000) is
-- served by a sweep that runs every ten minutes, claims what the console asked
-- for, and starts the workflow that does it. Four things the register now does
-- so the sweep, the poll and the console can run the fleet without anybody
-- watching:
--
--   A. The sweep asks for the kinds it will start. A build runs for hours and
--      the fleet builds one client at a time, so a sweep that finds a build
--      already running must still be able to start a release queued behind
--      the next build. erp_meta.claim_fleet_request(run, kinds) claims the
--      oldest open request of the kinds asked for, in the shape the one-argument
--      claim has always returned; that claim stays as it was. A kind the console
--      never makes is refused rather than claiming nothing for ever.
--
--   B. A request wakes the sweep. The console's Provision, Retry, Start again
--      and Release now each write a request; the sweep found it within ten
--      minutes. Now a trigger on the request asks GitHub to start the sweep at
--      once, through pg_net, with a token the control plane keeps in its vault
--      as cloveerp_sweep_token, in the repository named by
--      erp_meta.set_fleet_dispatch(owner/name). Where there is no pg_net, no
--      vault, no token or no repository (the schema build, the demonstration,
--      a client) it does nothing, and nothing it meets ever refuses the
--      request: the schedule is still there behind it. The token is read from
--      the vault into the one call and written nowhere else.
--
--   C. A build is not retried beside itself. Retry was accepted for a
--      deployment being created or built, so a second build could be queued
--      behind one still replaying. It now refuses while the deployment is
--      creating or building and its newest step is under six hours old;
--      six hours is past the longest replay a Micro project takes, so a build
--      silent that long has stopped and may be retried.
--
--   D. Each deployment's health. The poll reads every built and live client
--      and records what it found with erp_meta.record_deployment_health(code,
--      readings): the release it runs, its assurance failures, its size, the
--      drain's last pass, open support windows, whether its staff match the
--      control plane's, its backups, and the errors met reading them. The Fleet
--      view carries the readings, when they were taken, and "silent" for a
--      built or live deployment not read for twenty-six hours.
--
--   E. The proof: erp_test.fleet_runs_itself_suite, eleven cases, with its
--      assertion. erp_test.register_house_suite counts the Fleet view's keys,
--      and counts twenty-nine now, the three above among them; its cases stay
--      thirteen.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No permission code and no organisation's screen. The one-argument claim, the
-- settle, Start again and every other door of the register are as they were.
-- Nothing here reaches a client's database; the token is the owner's to make
-- and put in the vault.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN',
  'Asking for the console''s requests of a kind the console never makes.',
  'The console asks the workflows for two things: a client deployment built, and a release. A sweep that asked '
  'for anything else would claim nothing and say nothing, and the request it meant would wait.',
  'Ask for builds, releases, or both.');

select erp.register_refusal(
  'CLOVEERP_FLEET_REPOSITORY_INVALID',
  'Naming the repository the sweep is started in as something other than an owner and a name.',
  'When the console asks for a build or a release, the control plane asks GitHub to start the sweep at once, in '
  'the repository named here. A name GitHub cannot read leaves every request waiting for the sweep''s schedule.',
  'Give the repository as its owner and its name with a slash between them, as its address on GitHub shows them.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_HEALTH_INVALID',
  'Recording what the poll read from a client deployment in a form the register does not keep.',
  'The Fleet view shows each deployment''s health from what the poll last recorded, and calls a deployment silent '
  'when it has not been read for a day. A reading the register cannot show would be kept and never read, or read '
  'wrongly.',
  'Send only the readings the register keeps, each in its own form: counts as whole numbers, times as times, and '
  'the errors as a list of sentences. Then record them again.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_RETRYABLE',
  'Retrying the build of a deployment that is built, live or retired, or whose build is still running.',
  'A build is carried on only while it has not finished and is not running: a deployment that is built or live is '
  'released into, not built again, a retired one is gone, and a second build started beside a running one would '
  'replay the same client''s database twice at once.',
  'If the deployment is live, release to it from the Fleet view instead. If its build is still running, wait for '
  'it to finish or fail; one with no new step for six hours has stopped and may be retried.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The sweep asks for the kinds it will start
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.claim_fleet_request(p_run_id text, p_kinds text[])
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  r     erp_meta.fleet_request;
  v_bad text;
begin
  -- Only what the console makes. A kind spelt wrong would claim nothing,
  -- quietly, for ever (20261012010000).
  select string_agg(coalesce(k, 'nothing'), ', ' order by k) into v_bad
    from unnest(coalesce(p_kinds, '{}'::text[])) k
   where k is null or k not in ('build', 'release');
  if v_bad is not null then
    raise exception 'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN: the console asks for builds and releases, not %', v_bad
      using errcode = '22023',
            hint = 'Ask for builds, releases, or both.';
  end if;

  update erp_meta.fleet_request x
     set status = 'claimed', run_id = nullif(btrim(coalesce(p_run_id, '')), ''), claimed_at = now()
   where x.id = (select y.id from erp_meta.fleet_request y
                  where y.status = 'requested'
                    and y.kind = any (p_kinds)
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

revoke all on function erp_meta.claim_fleet_request(text, text[]) from public, anon, authenticated, service_role;

comment on function erp_meta.claim_fleet_request(text, text[]) is
  'The oldest open request from the console of one of the kinds asked for (build, release), claimed by the sweep '
  'that will start its workflow run; null when there is none, or when no kind is asked for. The same shape as the '
  'one-argument claim, which takes any kind and stays as it was. Trusted build role only (20261012010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A request wakes the sweep
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.set_fleet_dispatch(p_repository text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_repo text := btrim(coalesce(p_repository, ''));
begin
  -- owner/name, as GitHub spells a repository: an owner of letters, digits
  -- and inner hyphens, a name of letters, digits, dots, hyphens and
  -- underscores, and nothing GitHub would read as a path (20261012010000).
  if v_repo !~ '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}$'
     or split_part(v_repo, '/', 2) in ('.', '..')
     or v_repo ~* '\.git$' then
    raise exception 'CLOVEERP_FLEET_REPOSITORY_INVALID: "%" is not a repository named as owner/name', coalesce(p_repository, 'nothing')
      using errcode = '22023',
            hint = 'Give the repository as its owner and its name with a slash between them, as its address on GitHub shows them.';
  end if;

  insert into erp_meta.platform_setting (key, value, reason, updated_at)
  values ('fleet.repository', to_jsonb(v_repo),
          'Written by the trusted build role: the repository whose sweep (fleet_sweep.yml) a request from the console '
          'starts at once, with the token the vault keeps as cloveerp_sweep_token (20261012010000).',
          now())
  on conflict (key) do update
     set value = excluded.value, reason = excluded.reason, updated_at = excluded.updated_at, updated_by = null;
end;
$$;

revoke all on function erp_meta.set_fleet_dispatch(text) from public, anon, authenticated, service_role;

comment on function erp_meta.set_fleet_dispatch(text) is
  'Names the repository (owner/name) whose sweep a request from the console starts at once, kept as the platform '
  'setting fleet.repository; refuses anything else with CLOVEERP_FLEET_REPOSITORY_INVALID. The token is not '
  'passed here: the owner keeps it in the vault as cloveerp_sweep_token. Trusted build role only (20261012010000).';

create or replace function erp_meta.wake_the_sweep()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_token_name constant text := 'cloveerp_sweep_token';
  v_repo   text;
  v_token  text;
  v_id     bigint;
  v_said   text;
begin
  -- Asks GitHub to start the sweep now rather than at its next tick, and says
  -- what it did. Every way it can fall short is answered, never raised: a
  -- request is made whether or not the sweep is woken (20261012010000).
  select s.value #>> '{}' into v_repo
    from erp_meta.platform_setting s
   where s.key = 'fleet.repository';
  if v_repo is null or v_repo !~ '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}$' then
    return 'not woken: no repository is named for the sweep here, so it starts on its schedule';
  end if;
  if not exists (select 1 from pg_catalog.pg_extension e where e.extname = 'pg_net') then
    return 'not woken: this database cannot call out (pg_net is not installed), so the sweep starts on its schedule';
  end if;
  if not exists (select 1 from pg_catalog.pg_extension e where e.extname = 'supabase_vault') then
    return 'not woken: this database has no vault to keep the sweep''s token in, so the sweep starts on its schedule';
  end if;

  begin
    execute 'select s.decrypted_secret from vault.decrypted_secrets s where s.name = $1 limit 1'
       into v_token
      using c_token_name;
    v_token := nullif(btrim(coalesce(v_token, '')), '');
    if v_token is null then
      return 'not woken: the vault holds no token for the sweep, so it starts on its schedule';
    end if;
    -- Queued, not sent: pg_net sends it once this transaction commits, and
    -- not at all if it rolls back.
    execute 'select net.http_post(url := $1, body := $2, headers := $3)'
       into v_id
      using format('https://api.github.com/repos/%s/actions/workflows/fleet_sweep.yml/dispatches', v_repo),
            jsonb_build_object('ref', 'main'),
            jsonb_build_object('Authorization', 'Bearer ' || v_token,
                               'Accept', 'application/vnd.github+json',
                               'X-GitHub-Api-Version', '2022-11-28',
                               'User-Agent', 'cloveerp-control-plane',
                               'Content-Type', 'application/json');
    return format('woken: call %s asks %s to start its sweep now', v_id, v_repo);
  exception when others then
    -- Said, not raised, and never with the token in it.
    v_said := left(sqlerrm, 300);
    if v_token is not null then
      v_said := replace(v_said, v_token, '[the token]');
    end if;
    raise notice 'the sweep was not woken: %', v_said;
    return 'not woken: ' || v_said;
  end;
end;
$$;

revoke all on function erp_meta.wake_the_sweep() from public, anon, authenticated, service_role;

comment on function erp_meta.wake_the_sweep() is
  'Asks GitHub to start the sweep (fleet_sweep.yml) now, through pg_net, with the token the vault keeps as '
  'cloveerp_sweep_token, in the repository erp_meta.set_fleet_dispatch named; returns what it did. Where there is '
  'no repository, no pg_net, no vault or no token it does nothing, and any error is swallowed. Called by the '
  'trigger on erp_meta.fleet_request (20261012010000).';

create or replace function erp_meta.fleet_request_wakes_the_sweep()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- A request is never refused because the wake failed: whatever happens
  -- here, the row stands and the schedule finds it (20261012010000).
  begin
    perform erp_meta.wake_the_sweep();
  exception when others then
    raise notice 'the sweep was not woken: %', left(sqlerrm, 300);
  end;
  return null;
end;
$$;

revoke all on function erp_meta.fleet_request_wakes_the_sweep() from public, anon, authenticated, service_role;

comment on function erp_meta.fleet_request_wakes_the_sweep() is
  'The trigger after a request from the console is made: wakes the sweep (erp_meta.wake_the_sweep), and never '
  'refuses the request whatever the wake meets. Runs as its owner, so what it calls is granted to no session role '
  '(erp.invoker_reach_report grants what a trigger running as the writer calls) (20261012010000).';

drop trigger if exists t_fleet_request_wakes_the_sweep on erp_meta.fleet_request;
create trigger t_fleet_request_wakes_the_sweep
  after insert on erp_meta.fleet_request
  for each row
  when (new.status = 'requested')
  execute function erp_meta.fleet_request_wakes_the_sweep();

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp_meta', 'wake_the_sweep',
   'Called by the trigger after a request from the console is inserted into erp_meta.fleet_request; no session role '
   'may execute it. Runs as its owner to read the sweep''s token from the vault and queue one call through pg_net '
   'asking GitHub to start fleet_sweep.yml now. It never asks who the caller is and decides nothing about the '
   'request: every failure is answered or swallowed, so a request is never refused because the wake failed.'),
  ('erp_meta', 'fleet_request_wakes_the_sweep',
   'The trigger function after a request from the console is inserted into erp_meta.fleet_request. Runs as its '
   'owner so that erp_meta.wake_the_sweep, which it calls, stays granted to no session role; it reads nothing of '
   'the row and never asks who the writer is, and swallows any error so the insert it follows always stands.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

comment on table erp_meta.fleet_request is
  'What the console asked the workflows for — a build of a client deployment, a release train — for the sweep '
  '(fleet_sweep.yml) to claim with the repository''s own token (20261011020000). Each open request made wakes the '
  'sweep at once where the control plane can call out (erp_meta.wake_the_sweep, 20261012010000); the schedule '
  'stays behind it. The console holds no token.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D (first, because C's Fleet view reads them). Where a deployment's health is kept
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_meta.deployment add column if not exists health jsonb;
alter table erp_meta.deployment add column if not exists health_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_health_is_readings') then
    alter table erp_meta.deployment
      add constraint deployment_health_is_readings check (health is null or jsonb_typeof(health) = 'object');
  end if;
end
$$;

comment on column erp_meta.deployment.health is
  'What the poll last read from the deployment itself, as erp_meta.record_deployment_health kept it: any of '
  'release_sha, assurance_failures, assurance_at, database_bytes, last_drain_pass_at, open_support_windows, '
  'staff_in_step, backups_latest_at, backups_count, errors, polled_at (20261012010000).';
comment on column erp_meta.deployment.health_at is
  'When the poll last recorded the deployment''s health. A built or live deployment unread for twenty-six hours is '
  'silent in the Fleet view (20261012010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A build is not retried beside itself
-- ─────────────────────────────────────────────────────────────────────────────

do $$
declare
  v_def text;
  v_src text;
  r     record;
begin
  for r in
    select * from (values
      ('public.erp_platform_retry_deployment(text,text)', '20f3175613dda1d8e943eabae8a503b4',
       E'  select * into d from erp_meta.deployment x where x.code = d.code for no key update;\n',
       E'  select * into d from erp_meta.deployment x where x.code = d.code for no key update;\n'
       '  -- A build that is running is not started beside itself: being created or\n'
       '  -- built, with a step under six hours old. Six hours is past the longest\n'
       '  -- replay a Micro project takes, so a build silent that long has stopped\n'
       '  -- (20261012010000).\n'
       '  if d.status in (''creating'', ''building'')\n'
       '     and exists (select 1 from erp_meta.deployment_event e\n'
       '                  where e.code = d.code and e.at > now() - interval ''6 hours'') then\n'
       '    raise exception ''CLOVEERP_DEPLOYMENT_NOT_RETRYABLE: % is %, and its build is running'', d.code, d.status\n'
       '      using errcode = ''55000'',\n'
       '            hint = ''Wait for its build to finish or fail; the Fleet view shows each step as it is recorded. A build with no new step for six hours has stopped and may be retried then.'';\n'
       '  end if;\n'),
      ('public.erp_platform_deployments()', '29a96834378a95bbec3d4be1510764a4',
       E'             ''restartable'', erp_meta.deployment_restart_refusal(d.code) is null,\n',
       E'             ''restartable'', erp_meta.deployment_restart_refusal(d.code) is null,\n'
       '             -- What the poll last read from the deployment itself, when, and\n'
       '             -- whether a built or live one has gone unread for more than a\n'
       '             -- day (20261012010000).\n'
       '             ''health'', d.health,\n'
       '             ''health_at'', d.health_at,\n'
       '             ''silent'', d.status in (''built'', ''live'')\n'
       '                       and (d.health_at is null or d.health_at < now() - interval ''26 hours''),\n'),
      -- The register's own suite counts the Fleet view's keys; three more now.
      ('erp_test.register_house_suite()', 'ef78538a6f380d90e8bf59c9726ce377',
       E'                 ''restartable'']) k)\n'
       '          and (select count(*) from jsonb_object_keys(v_row2)) = 26\n',
       E'                 ''restartable'',\n'
       '                 -- The health the poll read, and silence (20261012010000).\n'
       '                 ''health'', ''health_at'', ''silent'']) k)\n'
       '          and (select count(*) from jsonb_object_keys(v_row2)) = 29\n')
    ) as x(sig, anchor, old, new)
  loop
    v_src := (select p.prosrc from pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261012010000') > 0 or strpos(v_src, r.new) > 0 then
      raise notice '% already carries 20261012010000', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.anchor then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
    v_def := pg_get_functiondef(r.sig::regprocedure);
    if (length(v_def) - length(replace(v_def, r.old, ''))) / length(r.old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % does not hold its anchor exactly once', r.sig;
    end if;
    execute replace(v_def, r.old, r.new);
  end loop;
end
$$;

comment on function public.erp_platform_retry_deployment(text, text) is
  'Queues the build of a client deployment again after it failed or stalled, carrying on where it stopped when its '
  'project exists. Refuses while its build is running: creating or building with a step under six hours old. '
  'Platform owner, on the control plane, with a reason (20261011020000, 20261012010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Each deployment's health is recorded
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.record_deployment_health(p_code text, p_health jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  d       erp_meta.deployment := erp_meta.deployment_row(p_code);
  r       record;
  v_fault text;
  v_at    timestamptz;
begin
  -- Every reading is optional and may be null; one that is there is in its
  -- own form, and nothing else is kept (20261012010000).
  if p_health is null or jsonb_typeof(p_health) <> 'object' then
    v_fault := 'the readings are not a set of named values';
  elsif octet_length(p_health::text) > 65536 then
    v_fault := 'the readings are longer than sixty-four kilobytes';
  else
    for r in select e.key, e.value from jsonb_each(p_health) e order by e.key loop
      continue when jsonb_typeof(r.value) = 'null';
      if r.key = 'release_sha' then
        if jsonb_typeof(r.value) <> 'string' or length(r.value #>> '{}') > 64 then
          v_fault := format('%s is not the name of a release', r.key);
        end if;
      elsif r.key in ('assurance_failures', 'database_bytes', 'open_support_windows', 'backups_count') then
        if (case when jsonb_typeof(r.value) <> 'number' then true
                 else (r.value #>> '{}')::numeric < 0
                   or (r.value #>> '{}')::numeric <> trunc((r.value #>> '{}')::numeric)
            end) then
          v_fault := format('%s is not a whole number of none or more', r.key);
        end if;
      elsif r.key = 'staff_in_step' then
        if jsonb_typeof(r.value) <> 'boolean' then
          v_fault := format('%s is not true or false', r.key);
        end if;
      elsif r.key = 'errors' then
        if jsonb_typeof(r.value) <> 'array'
           or exists (select 1 from jsonb_array_elements(r.value) x where jsonb_typeof(x) <> 'string') then
          v_fault := format('%s is not a list of sentences', r.key);
        end if;
      elsif r.key in ('assurance_at', 'last_drain_pass_at', 'backups_latest_at', 'polled_at') then
        if jsonb_typeof(r.value) <> 'string' then
          v_fault := format('%s is not a time', r.key);
        else
          begin
            v_at := (r.value #>> '{}')::timestamptz;
          exception when others then
            v_fault := format('%s is not a time', r.key);
          end;
        end if;
      else
        v_fault := format('%s is not a reading the register keeps', r.key);
      end if;
      exit when v_fault is not null;
    end loop;
  end if;

  if v_fault is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_HEALTH_INVALID: the health read from % is not recorded: %', d.code, v_fault
      using errcode = '22023',
            hint = 'Send only the readings the register keeps, each in its own form: counts as whole numbers, times '
                   'as times, and the errors as a list of sentences. Then record them again.';
  end if;

  -- Not updated_at: that says when the register changed the row, and a poll
  -- every hour would make it say nothing.
  update erp_meta.deployment x
     set health = p_health, health_at = now()
   where x.code = d.code;
end;
$$;

revoke all on function erp_meta.record_deployment_health(text, jsonb) from public, anon, authenticated, service_role;

comment on function erp_meta.record_deployment_health(text, jsonb) is
  'What the poll read from a client deployment, kept on its row with the time it was recorded: any of '
  'release_sha (text), assurance_failures, database_bytes, open_support_windows and backups_count (whole numbers), '
  'staff_in_step (true or false), assurance_at, last_drain_pass_at, backups_latest_at and polled_at (times), and '
  'errors (a list of text), each optional or null. Refuses an unknown deployment and any other key or form. '
  'Trusted build role only (20261012010000).';

comment on function public.erp_platform_deployments() is
  'Every client deployment in the register, with its build''s last step, its newest build request and when it '
  'was made, claimed and settled, whether Start again would start it now, its last release, and its health as the '
  'poll last read it, when, and whether a built or live one has gone silent (unread for twenty-six hours), for the '
  'Fleet view. Platform support and above, on the control plane only (20261011020000, 20261011110000, '
  '20261012010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.fleet_runs_itself_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_uid     uuid := gen_random_uuid();
  v_has_net boolean := exists (select 1 from pg_catalog.pg_extension e where e.extname = 'pg_net');
  v_owner   text;
  v_code1   text;
  v_code2   text;
  v_code3   text;
  v_code4   text;
  v_code5   text;
  v_code6   text;
  v_b1      uuid;
  v_b2      uuid;
  v_r1      uuid;
  v_r2      uuid;
  v_claim   jsonb;
  v_claim2  jsonb;
  v_json    jsonb;
  v_health  jsonb;
  v_doc     jsonb;
  v_row     jsonb;
  v_row2    jsonb;
  v_row3    jsonb;
  v_row4    jsonb;
  v_bad     text;
  v_got     text;
  v_got2    text;
  v_got3    text;
  v_n       integer;
  v_n2      integer;
  v_step    text := 'standing up an owner on the control plane';
  v_state   text;
begin
  begin
    v_owner := 'owner@zzfleet-' || v_tag || '.test';
    v_code1 := 'zzflb-' || v_tag;
    v_code2 := 'zzflr-' || v_tag;
    v_code3 := 'zzflc-' || v_tag;
    v_code4 := 'zzflo-' || v_tag;
    v_code5 := 'zzflh-' || v_tag;
    v_code6 := 'zzfls-' || v_tag;
    insert into auth.users (id, email, email_confirmed_at) values (v_uid, v_owner, now());
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Fleet Runs Itself Suite Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'fleet.repository');
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'fleet_runs_itself_suite');
    -- Older open requests would be claimed first; they wait out the suite.
    update erp_meta.fleet_request x set status = 'cancelled', settled_at = now()
     where x.status in ('requested', 'claimed');

    -- Two builds and two releases, oldest first: a build, two releases, a build.
    v_step := 'asking for two builds and two releases';
    v_b1 := (public.erp_platform_request_deployment(v_code1, 'Fleet Build One Ltd', 'admin@' || v_code1 || '.test',
               'The fleet suite asks for a build first.') ->> 'request_id')::uuid;
    v_r1 := (public.erp_platform_request_release(array['control'],
               'The fleet suite asks for a release next.') ->> 'request_id')::uuid;
    v_r2 := (public.erp_platform_request_release(array['control'],
               'The fleet suite asks for another release.') ->> 'request_id')::uuid;
    v_b2 := (public.erp_platform_request_deployment(v_code2, 'Fleet Build Two Ltd', 'admin@' || v_code2 || '.test',
               'The fleet suite asks for a build last.') ->> 'request_id')::uuid;
    update erp_meta.fleet_request x
       set created_at = now() - case x.id when v_b1 then interval '4 minutes'
                                          when v_r1 then interval '3 minutes'
                                          when v_r2 then interval '2 minutes'
                                          else interval '1 minute' end
     where x.id in (v_b1, v_r1, v_r2, v_b2);

    -- ── 1. Releases alone ───────────────────────────────────────────────────
    v_step := 'claiming releases alone';
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-r', array['release']);
    v_cases := v_cases + 1;
    case_name := 'asked for releases alone, the sweep claims the oldest release past an older build, in the shape it always had';
    passed := v_claim ->> 'id' = v_r1::text
          and v_claim ->> 'kind' = 'release'
          and (select array_agg(k order by k) from jsonb_object_keys(v_claim) k)
              = array['created_at', 'id', 'kind', 'payload']
          and (select x.status || ' ' || x.run_id from erp_meta.fleet_request x where x.id = v_r1)
              = 'claimed run-' || v_tag || '-r'
          and (select x.status from erp_meta.fleet_request x where x.id = v_b1) = 'requested';
    detail := coalesce(v_claim ->> 'kind', 'nothing') || ' claimed; the older build is '
           || coalesce((select x.status from erp_meta.fleet_request x where x.id = v_b1), 'gone');
    return next;

    -- ── 2. The one-argument claim is as it was ──────────────────────────────
    v_step := 'claiming with the one-argument claim';
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-1');
    v_claim2 := erp_meta.claim_fleet_request('run-' || v_tag || '-1');
    v_cases := v_cases + 1;
    case_name := 'the one-argument claim is as it was: the oldest request of any kind, a build and then a release, and the build says so on its deployment';
    passed := v_claim ->> 'id' = v_b1::text
          and v_claim2 ->> 'id' = v_r2::text
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_code1 and e.phase = 'dispatch' and e.status = 'done'
                         and e.run_id = 'run-' || v_tag || '-1');
    detail := coalesce(v_claim ->> 'kind', 'nothing') || ' then ' || coalesce(v_claim2 ->> 'kind', 'nothing');
    return next;

    -- ── 3. Nothing, a kind never made, then both ────────────────────────────
    v_step := 'claiming nothing, a kind never made, then both kinds';
    v_got := coalesce(erp_meta.claim_fleet_request('run-' || v_tag || '-0', '{}'::text[])::text, 'nothing');
    v_got2 := coalesce(erp_meta.claim_fleet_request('run-' || v_tag || '-0', null::text[])::text, 'nothing');
    begin
      perform erp_meta.claim_fleet_request('run-' || v_tag || '-x', array['release', 'rebuild']);
      v_got3 := 'it was claimed';
    exception when others then
      v_got3 := sqlerrm;
    end;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-2', array['build', 'release']);
    v_claim2 := erp_meta.claim_fleet_request('run-' || v_tag || '-2', array['build', 'release']);
    v_cases := v_cases + 1;
    case_name := 'asking for no kind claims nothing, a kind the console never makes is refused, and both kinds take the last build';
    passed := v_got = 'nothing' and v_got2 = 'nothing'
          and v_got3 like 'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN%rebuild%'
          and v_claim ->> 'id' = v_b2::text
          and v_claim2 is null
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_code2 and e.phase = 'dispatch' and e.run_id = 'run-' || v_tag || '-2');
    detail := v_got || ' / ' || v_got2 || ' / ' || left(v_got3, 80) || ' / ' || coalesce(v_claim ->> 'kind', 'nothing');
    return next;

    -- ── 4. No repository named ──────────────────────────────────────────────
    v_step := 'asking for a release with no repository named';
    v_got := erp_meta.wake_the_sweep();
    v_json := public.erp_platform_request_release(array['control'], 'The fleet suite asks with no repository named.');
    v_cases := v_cases + 1;
    case_name := 'with no repository named the sweep is not woken, and the request is made all the same';
    passed := v_got like 'not woken:%no repository%'
          and exists (select 1 from erp_meta.fleet_request x
                       where x.id = (v_json ->> 'request_id')::uuid and x.status = 'requested');
    detail := v_got;
    return next;

    -- ── 5. The repository is named as owner/name ────────────────────────────
    v_step := 'naming the repository the sweep runs in';
    perform erp_meta.set_fleet_dispatch('  example-owner/fleet.stand_in-1  ');
    v_n := 0;
    foreach v_bad in array array['', 'no-slash-at-all', 'one/two/three', 'https://github.com/example-owner/fleet',
                                 '-dash-first/fleet', 'example-owner/..', 'example-owner/fleet.git',
                                 'example owner/fleet'] loop
      begin
        perform erp_meta.set_fleet_dispatch(v_bad);
      exception when others then
        if sqlerrm like 'CLOVEERP_FLEET_REPOSITORY_INVALID%' then
          v_n := v_n + 1;
        end if;
      end;
    end loop;
    begin
      perform erp_meta.set_fleet_dispatch(null);
    exception when others then
      if sqlerrm like 'CLOVEERP_FLEET_REPOSITORY_INVALID%' then
        v_n := v_n + 1;
      end if;
    end;
    v_got := (select s.value #>> '{}' from erp_meta.platform_setting s where s.key = 'fleet.repository');
    v_cases := v_cases + 1;
    case_name := 'the repository the sweep is woken in is kept as owner/name, nothing else is, and only the trusted build role names it';
    passed := v_got = 'example-owner/fleet.stand_in-1'
          and v_n = 9
          and not (select p.prosecdef from pg_catalog.pg_proc p where p.oid = 'erp_meta.set_fleet_dispatch(text)'::regprocedure)
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.set_fleet_dispatch(text)', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.set_fleet_dispatch(text)', 'execute')
          and not pg_catalog.has_function_privilege('anon', 'erp_meta.set_fleet_dispatch(text)', 'execute');
    detail := format('kept %s; %s of 9 refused', coalesce(v_got, 'nothing'), v_n);
    return next;

    -- ── 6. A stand-in repository and no way to call out ─────────────────────
    v_step := 'asking for a release with a stand-in repository';
    v_got := erp_meta.wake_the_sweep();
    v_json := public.erp_platform_request_release(array['control'], 'The fleet suite asks with a stand-in repository.');
    v_cases := v_cases + 1;
    case_name := 'with a stand-in repository and no way to call out, the request is made and nothing is queued';
    passed := exists (select 1 from erp_meta.fleet_request x
                       where x.id = (v_json ->> 'request_id')::uuid and x.status = 'requested')
          and case when v_has_net
                   -- A host that can call out answers either way; the case
                   -- that matters here is the one that cannot.
                   then v_got like 'woken:%' or v_got like 'not woken:%'
                   else v_got like 'not woken:%cannot call out%'
                        and pg_catalog.to_regclass('net.http_request_queue') is null
              end;
    detail := v_got;
    return next;

    -- ── 7. The wake's shape ─────────────────────────────────────────────────
    v_step := 'reading the wake and its trigger';
    v_cases := v_cases + 1;
    case_name := 'the wake runs as its owner for no session role, is on the allowance, follows only an open request, and swallows what it meets';
    select count(*) into v_n
      from pg_catalog.pg_proc p
     where p.oid in ('erp_meta.wake_the_sweep()'::regprocedure,
                     'erp_meta.fleet_request_wakes_the_sweep()'::regprocedure)
       and p.prosecdef
       and exists (select 1 from erp_meta.security_definer_allowance a
                    where a.schema_name = 'erp_meta' and a.function_name = p.proname)
       and not pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('service_role', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute');
    passed := v_n = 2
          and exists (select 1 from pg_catalog.pg_trigger t
                       where t.tgrelid = 'erp_meta.fleet_request'::regclass
                         and t.tgname = 't_fleet_request_wakes_the_sweep'
                         and t.tgenabled <> 'D'
                         and strpos(pg_catalog.pg_get_triggerdef(t.oid),
                                    'AFTER INSERT ON erp_meta.fleet_request FOR EACH ROW WHEN ((new.status = ''requested''::text)) '
                                    'EXECUTE FUNCTION erp_meta.fleet_request_wakes_the_sweep()') > 0)
          and strpos(pg_catalog.pg_get_functiondef('erp_meta.fleet_request_wakes_the_sweep()'::regprocedure),
                     'exception when others') > 0
          and strpos(pg_catalog.pg_get_functiondef('erp_meta.wake_the_sweep()'::regprocedure),
                     'exception when others') > 0;
    detail := format('%s of 2 run as their owner, allowed and sealed; the trigger %s', v_n,
                     case when passed then 'follows an open request and both swallow what they meet'
                          else 'or a swallow is missing' end);
    return next;

    -- ── 8. A running build is not retried ───────────────────────────────────
    v_step := 'retrying a build that is running';
    perform erp_meta.settle_fleet_request(v_b2, 'success: deployment_from_empty.yml started');
    perform erp_meta.record_deployment_event(v_code2, 'create', 'started', 'making the project', 'run-' || v_tag || '-2');
    perform erp_meta.record_deployment_event(v_code2, 'build', 'started', 'replaying every migration', 'run-' || v_tag || '-2');
    begin
      perform public.erp_platform_retry_deployment(v_code2, 'The fleet suite retries a build that is still running.');
      v_got := 'it was retried';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a build that recorded a step a moment ago is not retried beside itself';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETRYABLE%building%build is running%'
          and (select d.status from erp_meta.deployment d where d.code = v_code2) = 'building'
          and not exists (select 1 from erp_meta.fleet_request x
                           where x.kind = 'build' and x.payload ->> 'code' = v_code2
                             and x.status in ('requested', 'claimed'));
    detail := left(v_got, 120);
    return next;

    -- ── 9. Six hours from its newest step ───────────────────────────────────
    v_step := 'retrying builds whose newest step is five and seven hours old';
    insert into erp_meta.deployment (code, client_name, owner_email, status, created_at, updated_at) values
      (v_code3, 'Fleet Creating Ltd', 'admin@' || v_code3 || '.test', 'creating',
       now() - interval '8 hours', now() - interval '5 hours'),
      (v_code4, 'Fleet Stopped Ltd', 'admin@' || v_code4 || '.test', 'building',
       now() - interval '9 hours', now() - interval '7 hours');
    insert into erp_meta.deployment_event (code, phase, status, detail, run_id, at) values
      (v_code3, 'create', 'started', 'making the project', 'run-' || v_tag || '-c', now() - interval '5 hours'),
      (v_code4, 'create', 'started', 'making the project', 'run-' || v_tag || '-o', now() - interval '8 hours'),
      (v_code4, 'build', 'started', 'replaying every migration', 'run-' || v_tag || '-o', now() - interval '7 hours');
    begin
      perform public.erp_platform_retry_deployment(v_code3, 'The fleet suite retries a build five hours into its step.');
      v_got := 'it was retried';
    exception when others then
      v_got := sqlerrm;
    end;
    v_json := public.erp_platform_retry_deployment(v_code4, 'The fleet suite retries a build silent for seven hours.');
    v_cases := v_cases + 1;
    case_name := 'a build is held for six hours from its newest step: five hours on it still refuses, seven hours on it is retried';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_NOT_RETRYABLE%creating%build is running%'
          and (select d.status from erp_meta.deployment d where d.code = v_code3) = 'creating'
          and v_json ->> 'status' = 'requested'
          and (select d.status from erp_meta.deployment d where d.code = v_code4) = 'requested'
          and exists (select 1 from erp_meta.fleet_request x
                       where x.kind = 'build' and x.payload ->> 'code' = v_code4 and x.status = 'requested');
    detail := left(v_got, 80) || ' / ' || coalesce(v_json::text, 'no retry');
    return next;

    -- ── 10. Recording health ────────────────────────────────────────────────
    v_step := 'recording a deployment''s health';
    insert into erp_meta.deployment (code, client_name, owner_email, status, built_at) values
      (v_code5, 'Fleet Live Ltd', 'admin@' || v_code5 || '.test', 'live', now() - interval '2 days'),
      (v_code6, 'Fleet Built Ltd', 'admin@' || v_code6 || '.test', 'built', now() - interval '1 day');
    v_health := jsonb_build_object(
      'release_sha', '6f0bd91c0ffee0ddba11f00dfeedfacecafebabe',
      'assurance_failures', 0,
      'assurance_at', now() - interval '10 minutes',
      'database_bytes', 123456789012,
      'last_drain_pass_at', now() - interval '2 minutes',
      'open_support_windows', 1,
      'staff_in_step', true,
      'backups_latest_at', now() - interval '20 hours',
      'backups_count', 7,
      'errors', jsonb_build_array('The backups list answered slowly.'),
      'polled_at', now());
    v_n := 0;
    foreach v_doc in array array['[1]', '"fine"', '{"assurance_failures": "0"}', '{"assurance_failures": -1}',
                                 '{"backups_count": 1.5}', '{"staff_in_step": "yes"}', '{"errors": [1]}',
                                 '{"polled_at": "not a time"}', '{"temperature": 3}', null]::jsonb[] loop
      begin
        perform erp_meta.record_deployment_health(v_code5, v_doc);
      exception when others then
        if sqlerrm like 'CLOVEERP_DEPLOYMENT_HEALTH_INVALID%' then
          v_n := v_n + 1;
        end if;
      end;
    end loop;
    begin
      perform erp_meta.record_deployment_health('zznobody-' || v_tag, '{}'::jsonb);
      v_got := 'it was recorded';
    exception when others then
      v_got := sqlerrm;
    end;
    perform erp_meta.record_deployment_health(v_code5, v_health);
    perform erp_meta.record_deployment_health(v_code6, '{"assurance_failures": null}'::jsonb);
    v_cases := v_cases + 1;
    case_name := 'the poll''s readings are kept with their time, in their own forms only, for a deployment the register holds, by the trusted build role alone';
    passed := v_n = 10
          and v_got like 'CLOVEERP_DEPLOYMENT_UNKNOWN%'
          and (select d.health = v_health and d.health_at = now() from erp_meta.deployment d where d.code = v_code5)
          and (select d.health_at = now() from erp_meta.deployment d where d.code = v_code6)
          and not (select p.prosecdef from pg_catalog.pg_proc p
                    where p.oid = 'erp_meta.record_deployment_health(text,jsonb)'::regprocedure)
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.record_deployment_health(text,jsonb)', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.record_deployment_health(text,jsonb)', 'execute')
          and not pg_catalog.has_function_privilege('anon', 'erp_meta.record_deployment_health(text,jsonb)', 'execute');
    detail := format('%s of 10 malformed refused; unknown: %s', v_n, left(v_got, 60));
    return next;

    -- ── 11. The Fleet view ──────────────────────────────────────────────────
    v_step := 'reading the Fleet view';
    -- The built one was read too; unread, it is what silence looks like.
    update erp_meta.deployment x set health = null, health_at = null where x.code = v_code6;
    v_json := public.erp_platform_deployments();
    v_row := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_code5);
    v_row2 := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_code6);
    v_row3 := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_code4);
    update erp_meta.deployment x set health_at = now() - interval '27 hours' where x.code = v_code5;
    v_row4 := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_code5);
    v_cases := v_cases + 1;
    case_name := 'the Fleet view carries each deployment''s health and when it was read, and calls a built or live one silent when unread for a day';
    passed := v_row -> 'health' = v_health
          and (v_row ->> 'health_at')::timestamptz = now()
          and (v_row ->> 'silent')::boolean = false
          and jsonb_typeof(v_row2 -> 'health') = 'null'
          and jsonb_typeof(v_row2 -> 'health_at') = 'null'
          and (v_row2 ->> 'silent')::boolean = true
          and v_row3 ->> 'status' = 'requested'
          and (v_row3 ->> 'silent')::boolean = false
          and (v_row4 ->> 'silent')::boolean = true;
    detail := format('live and read: silent %s; built, never read: silent %s; requested: silent %s; read 27 hours ago: silent %s',
                     coalesce(v_row ->> 'silent', 'missing'), coalesce(v_row2 ->> 'silent', 'missing'),
                     coalesce(v_row3 ->> 'silent', 'missing'), coalesce(v_row4 ->> 'silent', 'missing'));
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_FLEET_RUNS_ITSELF_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_fleet_runs_itself_suite()
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
    from erp_test.fleet_runs_itself_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_FLEET_RUNS_ITSELF_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The sweep''s claim, its wake, the retry guard or the health register does not do what the Fleet relies on: read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_FLEET_RUNS_ITSELF_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('fleet runs itself: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.fleet_runs_itself_suite() from public, anon;
revoke all on function erp_test.assert_fleet_runs_itself_suite() from public, anon;

comment on function erp_test.assert_fleet_runs_itself_suite() is
  'The sweep claims only the kinds it asks for and the one-argument claim is as it was; a request wakes the sweep '
  'where it can and is never refused where it cannot; the repository is named as owner/name; a running build is '
  'not retried for six hours from its newest step; the poll''s health is kept in its own forms and the Fleet view '
  'calls a built or live deployment silent after twenty-six hours unread (20261012010000).';

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
