set lock_timeout = '30s';

-- =============================================================================
-- 20261012060000  Incidents and maintenance reach every client
-- -----------------------------------------------------------------------------
-- An incident or a maintenance window declared on the control plane reached
-- only the organisations on that database. A client on its own project got no
-- banner and no email, and for a security incident never saw the clock on the
-- report it owes as data controller. This is the database's half of taking
-- them there; the job in fleet_sweep.yml that carries them
-- (supabase/ci/fleet_incident_sync.sh) and the console's columns come in the
-- same pull request.
--
--   A. Who an incident reaches. Declaring, containing and announcing take
--      p_every_client, last: every client deployment that is up. Declaring,
--      naming, containing and announcing take one list of names, each read in
--      order as an organisation here, else a client deployment in the register
--      that is not retired, by its code or the address it is served at now; a
--      window for every organisation here reads no names, as before. A
--      deployment named, and every one an "every client" incident or window
--      is handed out to, is a row of erp_meta.incident_deployment or
--      erp_meta.maintenance_window_deployment from that moment, and stays
--      one: an incident that reached a client keeps reaching it until it is
--      resolved, whatever became of the answer. A provider's outage that
--      reaches every organisation reaches every client too
--      (erp.record_dependency_status). A client deployment named, or every
--      client, is somebody named: a containment that says so is no finding.
--      The old signatures are dropped, so each door has one.
--
--   B. What is carried. erp_meta.incident_pushes_due gives, for one client,
--      each incident that reaches it, open or resolved in the last thirty
--      days, whose digest differs from the one the client last answered; and
--      each window, upcoming, in progress, or ended or cancelled in the last
--      thirty days, cancellations included; and once a day, check_held. An
--      incident is carried whole: its updates, components, disclosures
--      without their note, and a shared review as the four parts an
--      organisation's history reads and nothing else, its timeline naming
--      the updates it read by their ids so their words are carried once. No
--      staff address is carried: who posted, recorded or announced is "the
--      platform". erp_meta.settle_incident_pushes records what the client
--      answered, when the client says its people were told, client_told_at,
--      and, from what the client says it holds, carries again whatever it no
--      longer holds as it was carried, as after a restore to an earlier point.
--      Displayed, never asserted: a client that is down never blocks the
--      control plane's release.
--
--   C. What a client does with it. erp_meta.apply_pushed_incidents keeps a
--      received copy by the control plane's ids, with received_at and
--      received_digest: a copy held already is a replay; one naming a
--      severity, component, provider or timeline this database does not know
--      yet waits for its release; one whose code this database holds for an
--      incident or window of its own is refused (CLOVEERP_PUSHED_CODE_HELD),
--      and settled failed with the reason. Nothing received is deleted, so
--      the record of who was told stays. On the client a received copy
--      reaches its one organisation (affects_all_tenants, no organisation
--      named), and its banner and history say it was received rather than
--      that it reached every organisation. Its answer always says what it
--      holds, and when its people were told, from a delivery that reached
--      somebody.
--
--   D. A client's own console. Declaring, announcing, naming and flagging
--      refuse on a client's deployment, after the rank gate: the control plane
--      declares, and when it is down the status page is the channel. Updating,
--      containing and resolving an incident of the client's own stay allowed,
--      and its containment may name its own organisation. Every write to a
--      received copy refuses (CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE). The
--      timer skips received copies, and the discipline report leaves them out
--      of the rules that are the control plane's duties (cadence, promise,
--      prompt, containment scope, security obligations, the platform's
--      deadline, the reviews and telling), so a late update there never turns
--      a client's release red. The banner's "This service" is a screen string
--      a tenant can rename.
--
--   E. Waking. Every change to an incident or window a client deployment is
--      reached by wakes the sweep (erp_meta.wake_the_sweep(), once a
--      transaction), which carries it within minutes; the sweep's ten-minute
--      schedule carries it if not. The wake is a trigger on the tables the
--      doors write, as a fleet request's is, so every writer is covered and
--      the wake stays out of every session role's reach.
--
--   F. The proof: erp_test.incidents_reach_every_client_suite (twenty-eight
--      cases) and its assertion; erp_test.client_keeps_to_its_own_business_suite
--      (eleven), erp_test.service_notice_suite (twenty-two, one more: a window
--      for every client) and erp_test.incident_communication_suite (thirty)
--      taught the above. erp_test.incident_operations_suite (twenty-eight)
--      still counts eight doors: each changed door keeps one signature.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No permission code and no fleet request kind. affects_all_tenants keeps its
-- meaning, every organisation on this database, and the status page reads it
-- as before. Nothing is carried to the demonstration. Actions, prompts, the
-- review link, the organisations named and the staff's addresses stay on the
-- control plane.
-- erp.incident_report() keeps its columns; the console's door adds who was
-- reached beyond this database beside them.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE',
  'Changing, on a client''s own deployment, an incident or maintenance window it received from the control plane.',
  'The control plane declared it and keeps it, and this deployment holds a copy that is replaced whenever the '
  'control plane''s changes. An update, containment, resolution, disclosure, action, review or cancellation made '
  'here would be overwritten by the next push, and told to nobody who needs to hear it.',
  'Do it on the platform console at cloveerp.com; this deployment takes the change when the fleet''s push next '
  'runs, within minutes.');

select erp.register_refusal(
  'CLOVEERP_PUSHED_CODE_HELD',
  'Taking an incident or maintenance window from the control plane under a code a client''s own deployment holds '
  'for one of its own.',
  'They are different incidents or windows: taking the control plane''s under the same code would put its updates '
  'beside the wrong one, and tell people the wrong thing.',
  'Nothing was changed on the client, and the control plane records the push as failed with this reason. Declare or '
  'announce it again on the control plane under a code no client holds, and resolve or cancel the first.');

-- The register's suspension and a contract were the first things a client
-- took from the control plane; its incidents and maintenance are the next,
-- and the same words refuse them all off a client.
select erp.register_refusal(
  'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT',
  'Applying, on a deployment that is not a client''s own, what only a client''s own deployment takes from the '
  'control plane: the register''s suspension, its contract''s position and notices, or the incidents and '
  'maintenance that reach it.',
  'The register on the control plane says whether a client is suspended, what its contract holds and which '
  'incidents and windows reach it, and the client''s own deployment follows it. The control plane and the '
  'demonstration keep their organisations'' status, contracts and incidents themselves, so nothing from the '
  'register is followed there.',
  'Suspend or reinstate a client, change its contract, or declare an incident or window for it, on the platform '
  'console at cloveerp.com; its own deployment follows when the fleet''s sync or push next runs.');

select erp.register_refusal(
  'CLOVEERP_PUSH_MALFORMED',
  'Applying a contract position, notices, incidents or maintenance windows pushed from the control plane that do '
  'not read as one.',
  'A client holds the plan, the term, and the bands and add-ons its contract sold, and the incidents and windows '
  'that reach it, exactly as the control plane computed them. A position missing any of them, a date that is not a '
  'date, a notice that names no push, or an incident with no code would hold something nobody declared or sold, or '
  'be told twice.',
  'Nothing was changed. The push stays on the control plane and is counted; read its detail in the Fleet view or '
  'on the incident, mend what computed it there, and the next run carries it.');

select erp.register_refusal(
  'CLOVEERP_PUSH_SETTLE_UNREADABLE',
  'Recording what a client answered to the control plane''s pushes in a form the register cannot read.',
  'Each push is settled by what the client said of it: applied, held already, older, waiting or refused, and for '
  'an incident when its people were told. An answer that names no push, no run, or none of those words would '
  'settle nothing, or the wrong push.',
  'Settle with the run''s name and the client''s answers as its deployment returned them, each naming the push or '
  'the incident or window it answers and what the client said of it.');

select erp.register_refusal(
  'CLOVEERP_UNKNOWN_TENANT',
  'Naming an organisation that nothing here holds.',
  'Each organisation is known by its code on the deployment that holds it. On the control plane a contract may also '
  'name a client deployment from the register, and an incident or maintenance window may name one that is not '
  'retired, by its code or the address it is served at. A code that is neither belongs to nobody here.',
  'Choose the organisation from the list, or, for a contract, an incident or a maintenance window, the client '
  'deployment from the Fleet view.');

select erp.register_refusal(
  'CLOVEERP_NOT_THE_CONTROL_PLANE',
  'Doing the control plane''s work on a demonstration or on a client''s deployment.',
  'Selling, the contracts, their invoices, the enquiries, the register of client deployments, and declaring the '
  'incidents and maintenance clients are told of live on production, the control plane. A client''s database holds '
  'one customer and knows nothing of the others; the demonstration holds invented ones.',
  'Open the platform console at cloveerp.com and do it there.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Who an incident or window reaches, and what a client holds of it
-- ─────────────────────────────────────────────────────────────────────────────

-- "Every client" is its own flag: affects_all_tenants keeps meaning every
-- organisation on this database, which the status page and the banners read.
alter table erp_meta.incident
  add column if not exists every_client boolean not null default false,
  add column if not exists received_at timestamptz,
  add column if not exists received_digest text;
alter table erp_meta.maintenance_window
  add column if not exists every_client boolean not null default false,
  add column if not exists received_at timestamptz,
  add column if not exists received_digest text;

alter table erp_meta.incident drop constraint if exists incident_received_is_whole;
alter table erp_meta.incident add constraint incident_received_is_whole
  check ((received_at is null) = (received_digest is null) and (received_at is null or not every_client));
alter table erp_meta.maintenance_window drop constraint if exists maintenance_window_received_is_whole;
alter table erp_meta.maintenance_window add constraint maintenance_window_received_is_whole
  check ((received_at is null) = (received_digest is null) and (received_at is null or not every_client));

comment on column erp_meta.incident.every_client is
  'On the control plane: the incident reaches every client deployment that is up, each from the first time it is '
  'carried there (erp_meta.incident_deployment). Not affects_all_tenants, which is every organisation on this '
  'database (20261012060000).';
comment on column erp_meta.incident.received_at is
  'On a client''s own deployment: when this copy was last taken from the control plane, by the control plane''s '
  'id. Null for an incident declared here. A received copy refuses every local write (20261012060000).';
comment on column erp_meta.incident.received_digest is
  'The digest of what the control plane last carried of this copy; the same digest again is a replay '
  '(20261012060000).';
comment on column erp_meta.maintenance_window.every_client is
  'On the control plane: the window reaches every client deployment that is up, each from the first time it is '
  'carried there (erp_meta.maintenance_window_deployment) (20261012060000).';
comment on column erp_meta.maintenance_window.received_at is
  'On a client''s own deployment: when this copy was last taken from the control plane. Null for a window '
  'announced here. A received copy refuses every local write (20261012060000).';
comment on column erp_meta.maintenance_window.received_digest is
  'The digest of what the control plane last carried of this copy (20261012060000).';

-- On the control plane: each client deployment an incident reached, named or
-- as "every client", and what the push last did there. Never removed while
-- the incident lives: it keeps reaching a deployment until it is resolved.
create table if not exists erp_meta.incident_deployment (
  incident_id    uuid not null references erp_meta.incident (id) on delete cascade,
  code           text not null references erp_meta.deployment (code) on update cascade,
  reach          text not null check (reach in ('named', 'every_client')),
  named_at       timestamptz not null default now(),
  named_by       text,
  last_pushed_at timestamptz,
  last_digest    text,
  outcome        text check (outcome in ('applied', 'replay', 'waiting', 'failed')),
  detail         text,
  run_id         text,
  settled_at     timestamptz,
  client_told_at timestamptz,
  primary key (incident_id, code),
  constraint incident_deployment_settled_whole check ((outcome is null) = (settled_at is null))
);

create table if not exists erp_meta.maintenance_window_deployment (
  window_id      uuid not null references erp_meta.maintenance_window (id) on delete cascade,
  code           text not null references erp_meta.deployment (code) on update cascade,
  reach          text not null check (reach in ('named', 'every_client')),
  named_at       timestamptz not null default now(),
  named_by       text,
  last_pushed_at timestamptz,
  last_digest    text,
  outcome        text check (outcome in ('applied', 'replay', 'waiting', 'failed')),
  detail         text,
  run_id         text,
  settled_at     timestamptz,
  primary key (window_id, code),
  constraint maintenance_window_deployment_settled_whole check ((outcome is null) = (settled_at is null))
);

create index if not exists incident_deployment_code on erp_meta.incident_deployment (code);
create index if not exists maintenance_window_deployment_code on erp_meta.maintenance_window_deployment (code);

comment on table erp_meta.incident_deployment is
  'On the control plane: each client deployment an incident reached, named (reach named, with who named it) or as '
  'every client (reach every_client, from the first time it was carried there); what the push last did there '
  '(outcome applied, replay, waiting or failed, its detail, run and when), the digest the client last answered, '
  'when it last held it, and when the client said its people were first told (client_told_at, display only). Kept '
  'while the incident lives (20261012060000).';
comment on table erp_meta.maintenance_window_deployment is
  'On the control plane: each client deployment a maintenance window reached, named or as every client, and what '
  'the push last did there. Cancellations are carried too (20261012060000).';

select erp_meta.register_table('erp_meta', 'incident_deployment', 'platform_internal',
  'The client deployments an incident reached, and what the fleet''s push last did at each.');
select erp_meta.register_table('erp_meta', 'maintenance_window_deployment', 'platform_internal',
  'The client deployments a maintenance window reached, and what the fleet''s push last did at each.');

revoke all on table erp_meta.incident_deployment from public, anon, authenticated;
revoke all on table erp_meta.maintenance_window_deployment from public, anon, authenticated;

-- On the control plane: when each client deployment last said what it holds of
-- the incidents and windows carried to it. A client restored to an earlier
-- point holds less than its ledger says; once a day at least the push asks,
-- and what it no longer holds as it was carried is carried again.
create table if not exists erp_meta.incident_held_check (
  code       text primary key references erp_meta.deployment (code) on update cascade,
  checked_at timestamptz not null,
  run_id     text not null,
  held       integer not null check (held >= 0),
  cleared    integer not null check (cleared >= 0)
);

comment on table erp_meta.incident_held_check is
  'On the control plane: when each client deployment last answered what it holds of the incidents and windows '
  'carried to it (checked_at, the run), how many it held, and how many it no longer held as they were carried and '
  'are carried again (cleared). erp_meta.incident_pushes_due asks again (check_held) when the last answer is a day '
  'old or there is none (20261012060000).';

select erp_meta.register_table('erp_meta', 'incident_held_check', 'platform_internal',
  'When each client deployment last said what it holds of the incidents and windows carried to it.');

revoke all on table erp_meta.incident_held_check from public, anon, authenticated;

-- What reaches a client wakes the sweep: one of these is true for the
-- incident or window, and some client deployment is up.
create or replace function erp_meta.incident_reaches_a_client(p_incident_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- An incident declared here (never a received copy) that some client
  -- deployment that is up is reached by: named, carried there already, or
  -- every client (20261012060000).
  select exists (
    select 1
      from erp_meta.incident i
      join erp_meta.deployment d
        on d.status in ('built', 'live', 'suspended') or (d.status = 'retiring' and d.built_at is not null)
     where i.id = p_incident_id and i.received_at is null
       and (i.every_client
            or exists (select 1 from erp_meta.incident_deployment x where x.incident_id = i.id and x.code = d.code)))
$$;

create or replace function erp_meta.window_reaches_a_client(p_window_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from erp_meta.maintenance_window w
      join erp_meta.deployment d
        on d.status in ('built', 'live', 'suspended') or (d.status = 'retiring' and d.built_at is not null)
     where w.id = p_window_id and w.received_at is null
       and (w.every_client
            or exists (select 1 from erp_meta.maintenance_window_deployment x
                        where x.window_id = w.id and x.code = d.code)))
$$;

revoke all on function erp_meta.incident_reaches_a_client(uuid) from public, anon, authenticated, service_role;
revoke all on function erp_meta.window_reaches_a_client(uuid) from public, anon, authenticated, service_role;

comment on function erp_meta.incident_reaches_a_client(uuid) is
  'Whether an incident declared here reaches a client deployment that is up (built, live, suspended, or being '
  'offboarded after it was built): every client, or a row of erp_meta.incident_deployment. A change to it wakes the '
  'sweep when it does. Plain; called by erp_meta.wake_the_sweep_for, which the trigger that runs as its owner calls '
  '(20261012060000).';
comment on function erp_meta.window_reaches_a_client(uuid) is
  'Whether a maintenance window announced here reaches a client deployment that is up: every client, or a row of '
  'erp_meta.maintenance_window_deployment. Plain; called by erp_meta.wake_the_sweep_for (20261012060000).';

-- One name read as the doors read it: an organisation here, else a client
-- deployment that is not retired, by its code or its address now.
create or replace function erp_meta.affected_name(p_name text)
returns table(tenant_id uuid, tenant_code text, deployment_code text)
language plpgsql
stable
set search_path = ''
as $$
declare
  -- The register's own word, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired constant text := 'retired';
  v_name    text := btrim(coalesce(p_name, ''));
begin
  select t.id, t.code into tenant_id, tenant_code from erp.tenant t where t.code = v_name;
  if tenant_id is not null then
    return next;
    return;
  end if;
  select d.code into deployment_code
    from erp_meta.deployment d
   where (d.code = lower(v_name) or d.address = lower(v_name))
     and d.status <> c_retired
   order by (d.code = lower(v_name)) desc
   limit 1;
  if deployment_code is not null then
    return next;
    return;
  end if;
  raise exception 'CLOVEERP_UNKNOWN_TENANT: % is not an organisation on this deployment, nor a client deployment in the register that is not retired', v_name
    using errcode = '23503',
          hint = 'Choose the organisation from the list, or the client deployment from the Fleet view, by its code or '
                 'the address it is served at.';
end;
$$;

revoke all on function erp_meta.affected_name(text) from public, anon, authenticated, service_role;

comment on function erp_meta.affected_name(text) is
  'Reads one name given to an incident or maintenance window: an organisation on this deployment by its code, '
  'else a client deployment in the register that is not retired, by its code or the address it is served at now. '
  'Refuses CLOVEERP_UNKNOWN_TENANT for neither. Plain; called only by the doors that name (20261012060000).';

-- The names given to an incident, kept: each organisation here and each client
-- deployment, by whom, and what was named said in the platform's log. The
-- doors call it after their own gates: naming at the console
-- (erp.name_affected_organisations) refuses on a client, while a client's
-- containment of its own incident may still name its own organisation.
create or replace function erp_meta.name_who_an_incident_reached(p_staff erp_meta.platform_staff,
                                                                  p_incident_id uuid, p_names text[])
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_code  text;
  v_name  text;
  v_n     integer := 0;
  r       record;
  v_orgs  text[] := '{}';
  v_deps  text[] := '{}';
begin
  select i.code into v_code from erp_meta.incident i where i.id = p_incident_id;
  -- Each an organisation here, else a client deployment that is not retired,
  -- by its code or the address it is served at now (20261012060000).
  foreach v_name in array coalesce(p_names, '{}'::text[]) loop
    select * into r from erp_meta.affected_name(v_name) a;
    if r.tenant_id is not null then
      insert into erp_meta.incident_tenant (incident_id, tenant_id, tenant_code, named_by)
      values (p_incident_id, r.tenant_id, r.tenant_code, p_staff.email)
      on conflict do nothing;
      if found then
        v_n := v_n + 1;
        v_orgs := v_orgs || r.tenant_code;
      end if;
    else
      insert into erp_meta.incident_deployment (incident_id, code, reach, named_by)
      values (p_incident_id, r.deployment_code, 'named', p_staff.email)
      on conflict do nothing;
      if found then
        v_n := v_n + 1;
        v_deps := v_deps || r.deployment_code;
      end if;
    end if;
  end loop;
  perform erp_meta.platform_log(
    p_staff, 'platform.incident_scoped', null, v_code,
    format('%s organisation(s) and client deployment(s) named as affected', v_n),
    jsonb_build_object('tenants', to_jsonb(coalesce(p_names, '{}'::text[])), 'organisations', to_jsonb(v_orgs),
                       'deployments', to_jsonb(v_deps)));
  return v_n;
end;
$$;

revoke all on function erp_meta.name_who_an_incident_reached(erp_meta.platform_staff, uuid, text[])
  from public, anon, authenticated, service_role;

comment on function erp_meta.name_who_an_incident_reached(erp_meta.platform_staff, uuid, text[]) is
  'Keeps the names given to an incident, each read by erp_meta.affected_name: an organisation here '
  '(erp_meta.incident_tenant) or a client deployment (erp_meta.incident_deployment, reach named), by the staff '
  'member given, and logs platform.incident_scoped; answers how many were new. Plain and ungated: the doors that call '
  'it gate first, erp.name_affected_organisations off a client, erp.contain_incident on any deployment for its own '
  'incident (20261012060000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The doors this migration was written against
-- ─────────────────────────────────────────────────────────────────────────────

-- Each is rewritten whole below; three change their signature and are
-- dropped first, so each door keeps one.
do $$
declare
  r record;
  v_oid oid;
begin
  for r in
    select x.sig, x.anchor
      from (values
        ('erp.require_not_client()', '0144b627b57d95af9854d539c8172fed'),
        ('erp.declare_incident(text,text,text,text,text,text,boolean,text,boolean,text[],text[],integer)', '7ecbe4bb2d370159bc249713e9318d4f'),
        ('public.erp_platform_declare_incident(text,text,text,text,text,text,boolean,text,boolean,text[],text[],integer)', 'ae514dcb1c88b0356b2dacf1677d9d2e'),
        ('erp.contain_incident(text,text,boolean)', '489c017421675800f01f6a2c0af246ee'),
        ('public.erp_platform_contain_incident(text,text,boolean)', 'df309bafce8d0d7a2eb94fc787cad868'),
        ('erp.announce_maintenance(text,text,text,timestamptz,timestamptz,boolean,text[],boolean,text)', '3f1a84e4ebfa25a8d696f0c230ec5b63'),
        ('public.erp_platform_announce_maintenance(text,text,text,timestamptz,timestamptz,boolean,text[],boolean,text)', 'a63f7736e106ffa000c14e82f61a442c'),
        ('erp.name_affected_organisations(text,text[])', '020fecb3ba6ff7d113032a087aee936c'),
        ('erp.flag_security_incident(text)', '6308e5c4f4570b35aaaf2151d80b374e'),
        ('erp.post_incident_update(text,text,boolean,text,text,text,text,integer)', '7228eb902dcd09097bc4b2aac2d2b82e'),
        ('erp.resolve_incident(text,text)', '6c960196d565f7849ea1fb79cbce2e35'),
        ('erp.record_disclosure(text,text,text)', '32fafd8310b44227cec22a3bf0612e12'),
        ('erp.add_incident_action(text,text,text,date)', 'c9e7f2024903cbdbd8cec02d7abb827e'),
        ('erp.complete_incident_action(uuid,text)', 'ac5c781bc54db0d4503ca2c34e1b1e8d'),
        ('erp.assemble_incident_review(text)', 'd1aa5bf4eea342328332fec0afaad7d2'),
        ('erp.cancel_maintenance(text,text)', '8982443cb900185ee04421f626f43251'),
        ('public.erp_platform_incidents()', '3f702e4240b1d0ba0dcfcff37603c81b'),
        ('public.erp_platform_maintenance_windows()', 'b5d7fbe9a72139d56c4d46fa4c22f7cc'),
        ('public.erp_platform_incident_organisations(text)', 'f057d82872af76721598b509adff0482')
      ) as x(sig, anchor)
  loop
    v_oid := to_regprocedure(r.sig);
    -- A signature this migration drops is gone once it has run.
    continue when v_oid is null;
    if (select strpos(p.prosrc, '20261012060000') = 0 and md5(p.prosrc) <> r.anchor
          from pg_catalog.pg_proc p where p.oid = v_oid) then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
  end loop;
end
$$;

-- The console's three doors that change their signature, and the routines
-- behind them. Each is created again below with p_every_client last, so a
-- call by position or by name that the old door answered is answered the
-- same.
drop function if exists public.erp_platform_declare_incident(text, text, text, text, text, text, boolean, text, boolean, text[], text[], integer);
drop function if exists public.erp_platform_contain_incident(text, text, boolean);
drop function if exists public.erp_platform_announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text);
drop function if exists erp.declare_incident(text, text, text, text, text, text, boolean, text, boolean, text[], text[], integer);
drop function if exists erp.contain_incident(text, text, boolean);
drop function if exists erp.announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text);

-- ─────────────────────────────────────────────────────────────────────────────
-- D. A client's own console: the gate, and received copies refused
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.require_not_client()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  -- Incidents and maintenance are declared on the control plane too, and
  -- reach a client by the fleet's push (20261012060000).
  if erp.deployment_kind() = 'client' then
    raise exception 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a client''s own deployment; selling, contracts, invoices, enquiries, and declaring incidents and maintenance live on the control plane'
      using errcode = '42501',
            hint = 'Open the platform console at cloveerp.com and do it there.';
  end if;
end;
$$;

comment on function erp.require_not_client() is
  'Refuses with CLOVEERP_NOT_THE_CONTROL_PLANE on a client''s own deployment (erp.deployment_kind() = ''client'') '
  'and nowhere else, so the demonstration and the schema build go on as they were. Asked by every routine of the '
  'control plane''s business, selling, contracts, invoices and enquiries, and by declaring, announcing, naming and '
  'flagging an incident, right after its rank gate (20261011100000, 20261012060000).';

create function erp.declare_incident(p_code text, p_severity_code text, p_title text, p_commander text,
                                     p_communications_owner text, p_scribe text,
                                     p_is_data_integrity boolean default false, p_scope text default null,
                                     p_affects_all_tenants boolean default null, p_components text[] default null,
                                     p_tenant_codes text[] default null, p_next_update_minutes integer default null,
                                     p_every_client boolean default false)
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
  -- The control plane declares; a client is told by the fleet's push, and when
  -- the control plane is down the status page is the channel (20261012060000).
  perform erp.require_not_client();

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
     is_data_integrity, scope, affects_all_tenants, next_update_due_at, declared_by, every_client)
  values (p_code, p_severity_code, p_title, btrim(p_commander),
          btrim(p_communications_owner), btrim(p_scribe),
          coalesce(p_is_data_integrity, false), p_scope, p_affects_all_tenants,
          now() + make_interval(mins => v_minutes), v_staff.email, coalesce(p_every_client, false))
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
                       'every_client', coalesce(p_every_client, false),
                       'next_update_due_at', now() + make_interval(mins => v_minutes)));

  -- Organisations here and client deployments, one list (20261012060000).
  if coalesce(cardinality(p_tenant_codes), 0) > 0 then
    perform erp.name_affected_organisations(p_code, p_tenant_codes);
  end if;

  return v_id;
end;
$$;

comment on function erp.declare_incident(text, text, text, text, text, text, boolean, text, boolean, text[], text[], integer, boolean) is
  'Specification v1.6 §16.5 (v1.2 §17.3). Refuses an unpublished severity, an unfilled role and an unknown '
  'component, and refuses on a client''s own deployment, where the control plane''s incidents arrive by the '
  'fleet''s push. Scope is stated at declaration — everyone here, every client deployment (p_every_client), the '
  'organisations and client deployments named, or not yet known — and the first update is due from the moment of '
  'declaration, on the severity''s published cadence or sooner (20261012060000).';

create function erp.contain_incident(p_code text, p_scope text, p_affects_all_tenants boolean,
                                     p_tenant_codes text[] default null, p_every_client boolean default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
begin
  v_staff := erp_meta.require_platform('operator');

  select * into v_inc from erp_meta.incident i where i.code = p_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INCIDENT: %', p_code using errcode = '23503';
  end if;
  -- A copy the control plane carried here is contained there (20261012060000).
  if v_inc.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and is contained there', p_code
      using errcode = '42501',
            hint = 'Contain it on the platform console at cloveerp.com; this deployment takes the change when the '
                   'fleet''s push next runs.';
  end if;

  -- The table already refuses containment without a scope. Saying so here
  -- names the thing that is missing rather than the constraint that noticed.
  if coalesce(btrim(p_scope), '') = '' or p_affects_all_tenants is null then
    raise exception
      'CLOVEERP_CONTAINMENT_HAS_NO_SCOPE: containment states who was affected'
      using errcode = '23514',
            hint = 'Declaring an incident contained without saying what it '
                   'reached is the shape of a containment nobody can verify.';
  end if;

  -- Every client may be said now, or left as it was declared. A client
  -- deployment it reached already keeps being reached until it is resolved
  -- (20261012060000).
  update erp_meta.incident
     set contained_at = coalesce(contained_at, now()),
         scope = p_scope, affects_all_tenants = p_affects_all_tenants,
         every_client = coalesce(p_every_client, every_client)
   where id = v_inc.id;

  perform erp_meta.platform_log(
    v_staff, 'platform.incident_contained', null, p_code, p_scope,
    jsonb_build_object('affects_all_tenants', p_affects_all_tenants,
                       'every_client', coalesce(p_every_client, v_inc.every_client),
                       'named', to_jsonb(coalesce(p_tenant_codes, '{}'::text[]))));

  -- Named past the naming door's gate, which refuses on a client: a client
  -- containing an incident of its own may name its own organisation
  -- (20261012060000).
  if coalesce(cardinality(p_tenant_codes), 0) > 0 then
    perform erp_meta.name_who_an_incident_reached(v_staff, v_inc.id, p_tenant_codes);
  end if;
end;
$$;

comment on function erp.contain_incident(text, text, boolean, text[], boolean) is
  'Specification v1.2 §17.3. Containment that does not say who was affected is a claim nobody can check, so scope '
  'and reach are the price of the timestamp. It may name more organisations and client deployments, and say every '
  'client; a client deployment reached already stays reached. On a client''s own deployment it may name its own '
  'organisation for an incident of its own. Refuses a copy received from the control plane (20261012060000).';

create function erp.announce_maintenance(p_code text, p_title text, p_detail text, p_starts_at timestamptz,
                                         p_ends_at timestamptz, p_affects_all_tenants boolean,
                                         p_tenant_codes text[] default null, p_is_emergency boolean default false,
                                         p_emergency_reason text default null, p_every_client boolean default false)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff  erp_meta.platform_staff;
  v_hours  integer;
  v_id     uuid;
  v_code   text;
  r        record;
  v_orgs   text[] := '{}';
  v_deps   text[] := '{}';
begin
  v_staff := erp_meta.require_platform('operator');
  -- Announced on the control plane, and carried to a client by the fleet's
  -- push (20261012060000).
  perform erp.require_not_client();
  select n.hours into v_hours from erp_ref.notice_period n where n.code = 'planned_maintenance';

  -- §9.2 says the windows are published; §17.4 says maintenance is announced
  -- against them. An announcement inside the notice period is not an
  -- announcement, it is a surprise with a timestamp — unless it is an
  -- emergency, which says so and says why.
  if not coalesce(p_is_emergency, false)
     and p_starts_at < now() + make_interval(hours => v_hours) then
    raise exception
      'CLOVEERP_MAINTENANCE_NOTICE_TOO_SHORT: planned maintenance is announced at least % hours ahead',
      v_hours
      using errcode = '23514',
            hint = 'Announce it as emergency maintenance with its reason, and it '
                   'reads as an emergency to every organisation it touches.';
  end if;
  if coalesce(p_is_emergency, false) and coalesce(btrim(p_emergency_reason), '') = '' then
    raise exception 'CLOVEERP_EMERGENCY_HAS_NO_REASON: emergency maintenance states why'
      using errcode = '23514';
  end if;
  -- Every client is somebody (20261012060000).
  if not p_affects_all_tenants and not coalesce(p_every_client, false)
     and coalesce(cardinality(p_tenant_codes), 0) = 0 then
    raise exception
      'CLOVEERP_MAINTENANCE_AFFECTS_NOBODY: a window that is not for everyone names who it is for'
      using errcode = '23514';
  end if;

  insert into erp_meta.maintenance_window
    (code, title, detail, starts_at, ends_at, announced_by, is_emergency,
     emergency_reason, affects_all_tenants, every_client)
  values (p_code, p_title, p_detail, p_starts_at, p_ends_at, v_staff.email,
          coalesce(p_is_emergency, false), p_emergency_reason, p_affects_all_tenants,
          coalesce(p_every_client, false))
  returning id into v_id;

  -- A window for every organisation here reads no names, as it never did.
  -- Otherwise each name is an organisation here, else a client deployment that
  -- is not retired (20261012060000).
  if not p_affects_all_tenants then
    foreach v_code in array coalesce(p_tenant_codes, '{}'::text[]) loop
      select * into r from erp_meta.affected_name(v_code) a;
      if r.tenant_id is not null then
        insert into erp_meta.maintenance_window_tenant (window_id, tenant_id, tenant_code)
        values (v_id, r.tenant_id, r.tenant_code)
        on conflict do nothing;
        v_orgs := v_orgs || r.tenant_code;
      else
        insert into erp_meta.maintenance_window_deployment (window_id, code, reach, named_by)
        values (v_id, r.deployment_code, 'named', v_staff.email)
        on conflict do nothing;
        v_deps := v_deps || r.deployment_code;
      end if;
    end loop;
  end if;

  perform erp_meta.platform_log(
    v_staff, 'platform.maintenance_announced', null, p_code, p_title,
    jsonb_build_object('starts_at', p_starts_at, 'ends_at', p_ends_at,
                       'emergency', coalesce(p_is_emergency, false),
                       'affects_all_tenants', p_affects_all_tenants,
                       'every_client', coalesce(p_every_client, false),
                       'tenants', to_jsonb(v_orgs),
                       'deployments', to_jsonb(v_deps)));

  return v_id;
end;
$$;

comment on function erp.announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text, boolean) is
  'Specification v1.2 §17.4 against §9.2: announces a maintenance window. Refuses one inside the published notice '
  'period unless it is an emergency with a reason, one that is for nobody in particular, and any on a client''s own '
  'deployment. It may be for every organisation here, every client deployment (p_every_client), or the '
  'organisations and client deployments named; names are read only for a window that is not for every '
  'organisation here (20261012060000).';

create or replace function erp.name_affected_organisations(p_incident_code text, p_tenant_codes text[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
begin
  v_staff := erp_meta.require_platform('operator');
  -- Who an incident reached is said on the control plane (20261012060000).
  perform erp.require_not_client();
  select * into v_inc from erp_meta.incident i where i.code = p_incident_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INCIDENT: %', p_incident_code using errcode = '23503';
  end if;
  if v_inc.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and who it reached is said there', p_incident_code
      using errcode = '42501',
            hint = 'Name who it reached on the platform console at cloveerp.com.';
  end if;
  if coalesce(cardinality(p_tenant_codes), 0) = 0 then
    raise exception 'CLOVEERP_NOBODY_NAMED: naming affected organisations needs at least one'
      using errcode = '23514';
  end if;
  -- Each an organisation here, else a client deployment that is not retired,
  -- by its code or the address it is served at now (20261012060000).
  return erp_meta.name_who_an_incident_reached(v_staff, v_inc.id, p_tenant_codes);
end;
$$;

comment on function erp.name_affected_organisations(text, text[]) is
  'Specification v1.2 §17.3: names the organisations an incident reached, which is what scopes what each is told, '
  'and the client deployments it reached, each by its code or the address it is served at, which the fleet''s push '
  'carries it to (erp_meta.name_who_an_incident_reached). Operator, because saying who was affected is an '
  'operational claim; on the control plane or the demonstration, never a client''s own deployment: the gate is this '
  'door''s, not the routine''s, so a client''s containment of its own incident may name its own organisation '
  '(20261012060000).';

create or replace function erp.flag_security_incident(p_incident_code text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_inc   erp_meta.incident%rowtype;
  v_n     integer;
begin
  v_staff := erp_meta.require_platform('operator');
  -- Put on the disclosure path on the control plane; its obligations reach a
  -- client with the incident (20261012060000).
  perform erp.require_not_client();
  select * into v_inc from erp_meta.incident i where i.code = p_incident_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INCIDENT: %', p_incident_code using errcode = '23503';
  end if;
  if v_inc.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and is put on the disclosure path there', p_incident_code
      using errcode = '42501',
            hint = 'Flag it on the platform console at cloveerp.com.';
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

comment on function erp.flag_security_incident(text) is
  'Specification v1.2 §17.4: puts an incident on the disclosure path. Creates one obligation per published '
  'timeline, due from the declaration, for the platform as processor and the organisation as controller; a client '
  'deployment the incident reached is carried them. Refuses on a client''s own deployment (20261012060000).';

create or replace function erp.post_incident_update(p_code text, p_body text default null,
                                                    p_is_no_change boolean default false,
                                                    p_affected text default null, p_not_affected text default null,
                                                    p_being_done text default null, p_meanwhile text default null,
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
  -- The control plane posts the updates of what it carried here
  -- (20261012060000).
  if v_inc.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and its updates are posted there', p_code
      using errcode = '42501',
            hint = 'Post the update on the platform console at cloveerp.com; this deployment takes it when the '
                   'fleet''s push next runs.';
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

comment on function erp.post_incident_update(text, text, boolean, text, text, text, text, integer) is
  'Specification v1.6 §16.5, communication on a timer. The five fields are rendered once into the body; every '
  'channel — banner, email, status page, history, and a client deployment the incident reached — carries that text '
  'and no other. Posting resets the timer to the promised time, within the cadence. Refuses a copy received from '
  'the control plane (20261012060000).';

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
  -- Resolved where it was declared (20261012060000).
  if v_inc.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and is resolved there', p_code
      using errcode = '42501',
            hint = 'Resolve it on the platform console at cloveerp.com; this deployment takes the change when the '
                   'fleet''s push next runs.';
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

comment on function erp.resolve_incident(text, text) is
  'Specification v1.2 §17.3. A severity that requires a blameless review cannot be resolved without one, because a '
  'review owed after the urgency has passed is a review that does not get written. Refuses a copy received from the '
  'control plane (20261012060000).';

create or replace function erp.record_disclosure(p_incident_code text, p_obligation_code text, p_note text default null)
returns void
language plpgsql
security definer
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
    raise exception 'CLOVEERP_UNKNOWN_INCIDENT: %', p_incident_code using errcode = '23503';
  end if;
  -- The platform's disclosures are recorded where its incident is
  -- (20261012060000).
  if v_inc.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and its disclosures are recorded there', p_incident_code
      using errcode = '42501',
            hint = 'Record the disclosure on the platform console at cloveerp.com.';
  end if;
  if not v_inc.is_security then
    raise exception 'CLOVEERP_NOT_A_SECURITY_INCIDENT: % has no disclosure path', p_incident_code
      using errcode = '23514', hint = 'Flag it as a security incident first.';
  end if;
  update erp_meta.incident_disclosure d
     set notified_at = coalesce(d.notified_at, now()),
         notified_by = coalesce(d.notified_by, v_staff.email),
         note = coalesce(nullif(btrim(p_note), ''), d.note)
   where d.incident_id = v_inc.id and d.obligation_code = p_obligation_code;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'CLOVEERP_UNKNOWN_OBLIGATION: % is not a timeline on %', p_obligation_code, p_incident_code
      using errcode = '23503';
  end if;
  perform erp_meta.platform_log(
    v_staff, 'platform.disclosure_recorded', null, p_incident_code, p_obligation_code,
    jsonb_build_object('note', p_note));
end;
$$;

comment on function erp.record_disclosure(text, text, text) is
  'Records that one of an incident''s disclosure obligations was met, by whom, with a note that stays on the '
  'control plane. Operator. Refuses a copy received from the control plane (20261012060000).';

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
  -- Actions are tracked where the incident is (20261012060000).
  if v_inc.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and its actions are tracked there', p_code
      using errcode = '42501',
            hint = 'Add the action on the platform console at cloveerp.com.';
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

comment on function erp.add_incident_action(text, text, text, date) is
  'Tracks a review action against an incident with an owner and a due date. Platform support and above. Refuses a '
  'copy received from the control plane (20261012060000).';

create or replace function erp.complete_incident_action(p_action_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_code  text;
  v_recv  timestamptz;
begin
  v_staff := erp_meta.require_platform('support');
  if length(coalesce(btrim(p_note), '')) < 5 then
    raise exception 'CLOVEERP_ACTION_DONE_SAYS_HOW: completing an action says what was done'
      using errcode = '23514', hint = 'A note of a few words: what changed, where.';
  end if;
  -- Actions are tracked where the incident is (20261012060000).
  select i.code, i.received_at into v_code, v_recv
    from erp_meta.incident_action a join erp_meta.incident i on i.id = a.incident_id
   where a.id = p_action_id;
  if v_recv is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and its actions are tracked there', v_code
      using errcode = '42501',
            hint = 'Complete the action on the platform console at cloveerp.com.';
  end if;
  v_code := null;
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

comment on function erp.complete_incident_action(uuid, text) is
  'Closes a review action with a note saying what was done. Platform support and above. Refuses an action of a copy '
  'received from the control plane (20261012060000).';

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
  -- The review is assembled where the incident is, and a shared one reaches
  -- a client with it (20261012060000).
  if v_inc.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and its review is assembled there', p_code
      using errcode = '42501',
            hint = 'Assemble the review on the platform console at cloveerp.com; a shared review reaches this '
                   'deployment when the fleet''s push next runs.';
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
    -- The client deployments it reached, named or as every client
    -- (20261012060000).
    'every_client', v_inc.every_client,
    'deployments_reached', coalesce((select jsonb_agg(x.code order by x.code)
                                       from erp_meta.incident_deployment x where x.incident_id = v_inc.id), '[]'::jsonb),
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

comment on function erp.assemble_incident_review(text) is
  'Specification v1.6 §16.5: the blameless review, assembled from what was actually said and when — the timeline '
  'of updates, the prompts the timer recorded, the organisations and client deployments reached and the actions '
  'tracked. Stored beside the incident and shared with the organisations it reached through '
  'erp_incident_history(); a client deployment it reached is carried only the parts that history reads. Refuses a '
  'copy received from the control plane (20261012060000).';

create or replace function erp.cancel_maintenance(p_code text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff erp_meta.platform_staff;
  v_win   erp_meta.maintenance_window%rowtype;
begin
  v_staff := erp_meta.require_platform('operator');
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'CLOVEERP_CANCELLATION_HAS_NO_REASON: a cancelled window says why'
      using errcode = '23514';
  end if;
  select * into v_win from erp_meta.maintenance_window w where w.code = p_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_MAINTENANCE_WINDOW: %', p_code using errcode = '23503';
  end if;
  -- Cancelled where it was announced, and the cancellation carried to every
  -- client it reached (20261012060000).
  if v_win.received_at is not null then
    raise exception 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and is cancelled there', p_code
      using errcode = '42501',
            hint = 'Cancel it on the platform console at cloveerp.com; this deployment takes the cancellation when '
                   'the fleet''s push next runs.';
  end if;
  update erp_meta.maintenance_window
     set cancelled_at = coalesce(cancelled_at, now()), cancel_reason = btrim(p_reason)
   where id = v_win.id;
  perform erp_meta.platform_log(
    v_staff, 'platform.maintenance_cancelled', null, p_code, p_reason, '{}'::jsonb);
end;
$$;

comment on function erp.cancel_maintenance(text, text) is
  'Cancels an announced maintenance window with a reason; the cancellation is carried to every client deployment the '
  'window reached. Operator. Refuses a copy received from the control plane (20261012060000).';

-- The console's doors, each with one signature.
create function public.erp_platform_declare_incident(p_code text, p_severity_code text, p_title text, p_commander text,
                                                     p_communications_owner text, p_scribe text,
                                                     p_is_data_integrity boolean default false,
                                                     p_scope text default null,
                                                     p_affects_all_tenants boolean default null,
                                                     p_components text[] default null,
                                                     p_tenant_codes text[] default null,
                                                     p_next_update_minutes integer default null,
                                                     p_every_client boolean default false)
returns uuid
language sql
set search_path = ''
as $$
  select erp.declare_incident(p_code, p_severity_code, p_title, p_commander,
                              p_communications_owner, p_scribe,
                              p_is_data_integrity, p_scope, p_affects_all_tenants,
                              p_components, p_tenant_codes, p_next_update_minutes, p_every_client);
$$;

create function public.erp_platform_contain_incident(p_code text, p_scope text, p_affects_all_tenants boolean,
                                                     p_tenant_codes text[] default null,
                                                     p_every_client boolean default null)
returns void
language sql
set search_path = ''
as $$
  select erp.contain_incident(p_code, p_scope, p_affects_all_tenants, p_tenant_codes, p_every_client);
$$;

create function public.erp_platform_announce_maintenance(p_code text, p_title text, p_detail text,
                                                         p_starts_at timestamptz, p_ends_at timestamptz,
                                                         p_affects_all_tenants boolean,
                                                         p_tenant_codes text[] default null,
                                                         p_is_emergency boolean default false,
                                                         p_emergency_reason text default null,
                                                         p_every_client boolean default false)
returns uuid
language sql
set search_path = ''
as $$
  select erp.announce_maintenance(p_code, p_title, p_detail, p_starts_at, p_ends_at, p_affects_all_tenants,
                                  p_tenant_codes, p_is_emergency, p_emergency_reason, p_every_client);
$$;

revoke all on function public.erp_platform_declare_incident(text, text, text, text, text, text, boolean, text, boolean, text[], text[], integer, boolean) from public, anon;
grant execute on function public.erp_platform_declare_incident(text, text, text, text, text, text, boolean, text, boolean, text[], text[], integer, boolean) to authenticated, service_role;
revoke all on function public.erp_platform_contain_incident(text, text, boolean, text[], boolean) from public, anon;
grant execute on function public.erp_platform_contain_incident(text, text, boolean, text[], boolean) to authenticated, service_role;
revoke all on function public.erp_platform_announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text, boolean) from public, anon;
grant execute on function public.erp_platform_announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text, boolean) to authenticated, service_role;

comment on function public.erp_platform_declare_incident(text, text, text, text, text, text, boolean, text, boolean, text[], text[], integer, boolean) is
  'The console''s door to erp.declare_incident: everyone here, every client deployment (p_every_client), or the '
  'organisations and client deployments named. Operator; refuses on a client''s own deployment (20261012060000).';
comment on function public.erp_platform_contain_incident(text, text, boolean, text[], boolean) is
  'The console''s door to erp.contain_incident: the scope, everyone here or not, more organisations and client '
  'deployments named, and every client or as declared (p_every_client null). Operator (20261012060000).';
comment on function public.erp_platform_announce_maintenance(text, text, text, timestamptz, timestamptz, boolean, text[], boolean, text, boolean) is
  'The console''s door to erp.announce_maintenance: everyone here, every client deployment (p_every_client), or the '
  'organisations and client deployments named. Operator; refuses on a client''s own deployment (20261012060000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The timer, the discipline report and what an organisation reads, taught
--    received copies; a provider's outage reaches every client
-- ─────────────────────────────────────────────────────────────────────────────

do $do$
declare
  r      record;
  v_src  text;
  v_def  text;
begin
  for r in
    select x.sig, x.anchor,
           array_agg(x.old order by x.ord) as olds,
           array_agg(x.new order by x.ord) as news
      from (values
        -- The timer prompts the control plane's people for what it declared;
        -- a client holds a copy, and nobody there posts its updates.
        ('erp.prompt_incident_updates()', 'b3bcaf534433aefc0fd9c448c7ba2b7e', 1,
$o$     where i.resolved_at is null and i.next_update_due_at is not null and i.next_update_due_at < now()
$o$,
$n$     where i.resolved_at is null and i.next_update_due_at is not null and i.next_update_due_at < now()
       -- A copy received from the control plane is prompted there, where
       -- its people are (20261012060000).
       and i.received_at is null
$n$),
        -- The discipline report: the rules that are the control plane's
        -- duties leave received copies out, so a late update there never
        -- turns a client's release red (20261012060000).
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 1,
$o$   where s.requires_review and i.resolved_at is not null
     and i.review_completed_at is null
$o$,
$n$   where s.requires_review and i.resolved_at is not null
     and i.review_completed_at is null
     -- The control plane keeps the review of what it carried
     -- (20261012060000).
     and i.received_at is null
$n$),
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 2,
$o$   where i.resolved_at is null
     and now() - coalesce(
$o$,
$n$   where i.resolved_at is null
     and i.received_at is null
     and now() - coalesce(
$n$),
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 3,
$o$   where i.resolved_at is null and i.next_update_due_at < now()
  union all
$o$,
$n$   where i.resolved_at is null and i.next_update_due_at < now()
     and i.received_at is null
  union all
$n$),
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 4,
$o$   where i.resolved_at is null and i.next_update_due_at < now() - interval '10 minutes'
$o$,
$n$   where i.resolved_at is null and i.next_update_due_at < now() - interval '10 minutes'
     and i.received_at is null
$n$),
        -- A client deployment named, or every client, is somebody named: a
        -- containment for clients only names them there (20261012060000).
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 5,
$o$     and i.affects_all_tenants is false
$o$,
$n$     and i.affects_all_tenants is false
     and i.received_at is null
     and not i.every_client
     and not exists (select 1 from erp_meta.incident_deployment x where x.incident_id = i.id)
$n$),
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 6,
$o$   where i.is_security
$o$,
$n$   where i.is_security and i.received_at is null
$n$),
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 7,
$o$   where n.obliged_party = 'platform' and d.notified_at is null and d.due_at < now()
$o$,
$n$   where n.obliged_party = 'platform' and d.notified_at is null and d.due_at < now()
     and i.received_at is null
$n$),
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 8,
$o$   where s.requires_review and not r.is_shared
$o$,
$n$   where s.requires_review and not r.is_shared
     and i.received_at is null
$n$),
        ('erp.support_discipline_report()', 'a6b1d21b4cccd46aece158ac79d9d769', 9,
$o$   where t.named_at < now() - interval '1 hour'
$o$,
$n$   where t.named_at < now() - interval '1 hour'
     and i.received_at is null
$n$),
        -- A provider's outage: the copy a client received is not the live
        -- one here, and one that reaches every organisation here reaches
        -- every client too (20261012060000).
        ('erp.record_dependency_status(text,text,text,jsonb,text)', 'f024e1615be134fcc8e0f15d4388884d', 1,
$o$   where i.origin_dependency_code = p_code and i.resolved_at is null
$o$,
$n$   where i.origin_dependency_code = p_code and i.resolved_at is null
     and i.received_at is null
$n$),
        ('erp.record_dependency_status(text,text,text,jsonb,text)', 'f024e1615be134fcc8e0f15d4388884d', 2,
$o$       scope, affects_all_tenants, next_update_due_at, origin_dependency_code, declared_by)
$o$,
$n$       scope, affects_all_tenants, next_update_due_at, origin_dependency_code, declared_by, every_client)
$n$),
        ('erp.record_dependency_status(text,text,text,jsonb,text)', 'f024e1615be134fcc8e0f15d4388884d', 3,
$o$            v_dep.affects_service, now() + make_interval(mins => v_sev.update_every_minutes), p_code, 'dependency feed')
$o$,
$n$            v_dep.affects_service, now() + make_interval(mins => v_sev.update_every_minutes), p_code, 'dependency feed',
            -- Below the platform for every organisation here is below it for
            -- every client (20261012060000).
            coalesce(v_dep.affects_service, false) and erp.deployment_kind() <> 'client')
$n$),
        -- What an organisation reads: a received copy reached this service,
        -- not every organisation, and says it was received.
        ('erp.service_notices()', '12090b434dc3dc30e0a31e711d2f8db8', 1,
$o$               'emergency_reason', w.emergency_reason,
$o$,
$n$               'emergency_reason', w.emergency_reason,
               -- Announced on the control plane and received here
               -- (20261012060000).
               'received', w.received_at is not null,
$n$),
        ('erp.service_notices()', '12090b434dc3dc30e0a31e711d2f8db8', 2,
$o$               'affects_all_tenants', coalesce(i.affects_all_tenants, false),
$o$,
$n$               -- A copy received from the control plane reaches this service,
               -- not every organisation (20261012060000).
               'affects_all_tenants', coalesce(i.affects_all_tenants, false) and i.received_at is null,
               'received', i.received_at is not null,
$n$),
        ('erp.incident_history()', 'ef941b773f303b8e159ee345733d2dcd', 1,
$o$           'scope', i.scope, 'affects_all_tenants', coalesce(i.affects_all_tenants, false),
$o$,
$n$           -- A copy received from the control plane reached this service,
           -- not every organisation (20261012060000).
           'scope', i.scope, 'affects_all_tenants', coalesce(i.affects_all_tenants, false) and i.received_at is null,
           'received', i.received_at is not null,
$n$),
        -- What reached each client deployment, beside what was delivered,
        -- published and prompted here.
        ('erp.incident_communication_report(text)', 'cd24f49dc20a700c188ca1298ded2d70', 1,
$o$   order by 1, 3
$o$,
$n$  union all
  -- What the fleet's push did at each client deployment the incident
  -- reached, and when the client said its people were first told
  -- (20261012060000).
  select i.code, 'push', coalesce(x.settled_at, x.named_at), x.code,
         format('%s%s%s', coalesce(x.outcome, 'no answer yet'), coalesce(': ' || x.detail, ''),
                case when x.client_told_at is not null
                     then format('; its people told %s UTC',
                                 to_char(x.client_told_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'))
                     else '' end)
    from erp_meta.incident_deployment x join erp_meta.incident i on i.id = x.incident_id
   where p_code is null or i.code = p_code
   order by 1, 3
$n$)
      ) as x(sig, anchor, ord, old, new)
     group by x.sig, x.anchor
     order by x.sig
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261012060000') > 0 then
      raise notice '% already carries 20261012060000', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.anchor then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    for i in 1 .. cardinality(r.olds) loop
      if (length(v_def) - length(replace(v_def, r.olds[i], ''))) / length(r.olds[i]) <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % does not hold its anchor % exactly once', r.sig, i;
      end if;
      v_def := replace(v_def, r.olds[i], r.news[i]);
    end loop;
    execute v_def;
  end loop;
end
$do$;

comment on function erp.support_discipline_report() is
  'Specification v1.2 Part 17. Read by erp.assert_support_discipline(). A copy received from the control plane is '
  'left out of the rules that are the control plane''s duties — the review, the cadence, the promise and its prompt, '
  'the containment scope, the security obligations, the platform''s deadline, the review shared and the telling — '
  'and kept in the one that names its roles. A containment scoped to some organisations names somebody when it '
  'names a client deployment or reaches every client (20261012060000).';
comment on function erp.prompt_incident_updates() is
  'Specification v1.6 §16.5: communication is on a timer, not on progress. Runs in the platform sweep; records who '
  'was prompted for an update that fell due and escalates through the roles the declaration named, with an audit '
  'row each time. Nothing here posts an update — a person does that. A copy received from the control plane is '
  'prompted there, not here (20261012060000).';
comment on function erp.record_dependency_status(text, text, text, jsonb, text) is
  'Specification v1.6 §16.5: an outage below the platform is the platform''s incident to communicate. A major or '
  'critical indicator on a provider''s feed declares a severity-3 incident with the origin, the components the '
  'provider carries and the scope the dependency row states, reaching every client deployment too when it reaches '
  'every organisation here; recovery on the feed posts the closing update and resolves it. Either wakes the sweep '
  'when a client is reached. Trusted sessions only — the worker''s job handler (20261012060000).';
comment on function erp.service_notices() is
  'Specification v1.2 §17.3 and §17.4, from the organisation''s side: the maintenance windows that touch it, the '
  'incidents it was named in or that reached everyone once containment said so, with their updates, and its own '
  'disclosure obligations with the clock running. On a client''s own deployment what the control plane carried '
  'says received, and reached this service rather than every organisation. Security definer because erp_meta is '
  'platform-internal; scoped to the caller''s organisation by construction and returns nothing about any other '
  '(20261012060000).';
comment on function erp.incident_history() is
  'Specification v1.6 §16.5, D36: an organisation can read every incident that reached it, with the timeline it was '
  'given and the review the platform shared, for as long as the register holds it. Scoped by construction: named, '
  'or declared as reaching everyone. On a client''s own deployment what the control plane carried says received '
  '(20261012060000).';
comment on function erp.incident_communication_report(text) is
  'Per incident, what was delivered to each organisation, published to each status page, prompted by the timer and '
  'tracked as an action, and what the fleet''s push did at each client deployment it reached with when the client '
  'said its people were told (kind push). Reached only through a platform door (20261012060000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The console reads who an incident or window reached beyond this database
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_incidents()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  -- Each incident, with whether it reaches every client, when this copy was
  -- received from the control plane (on a client's own deployment), and the
  -- client deployments it reached with what the push last did at each and
  -- when the client said its people were told (20261012060000).
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
                            'every_client', i.every_client,
                            'received_at', i.received_at,
                            'deployments', coalesce((
                              select jsonb_agg(jsonb_build_object(
                                       'code', x.code, 'address', d.address, 'status', d.status,
                                       'reach', x.reach, 'named_at', x.named_at, 'named_by', x.named_by,
                                       'outcome', x.outcome, 'detail', x.detail, 'run_id', x.run_id, 'settled_at', x.settled_at,
                                       'last_pushed_at', x.last_pushed_at, 'client_told_at', x.client_told_at)
                                     order by x.code)
                                from erp_meta.incident_deployment x
                                join erp_meta.deployment d on d.code = x.code
                               where x.incident_id = i.id), '[]'::jsonb))
                          order by r.declared_at desc)
                     from erp.incident_report() r
                     join erp_meta.incident i on i.code = r.code), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_maintenance_windows()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  -- Each window, with whether it reaches every client, when this copy was
  -- received from the control plane, and the client deployments it reached
  -- with what the push last did at each (20261012060000).
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
                            'every_client', w.every_client,
                            'received_at', w.received_at,
                            'deployments', coalesce((
                              select jsonb_agg(jsonb_build_object(
                                       'code', x.code, 'address', d.address, 'status', d.status,
                                       'reach', x.reach, 'named_at', x.named_at, 'named_by', x.named_by,
                                       'outcome', x.outcome, 'detail', x.detail, 'run_id', x.run_id, 'settled_at', x.settled_at,
                                       'last_pushed_at', x.last_pushed_at)
                                     order by x.code)
                                from erp_meta.maintenance_window_deployment x
                                join erp_meta.deployment d on d.code = x.code
                               where x.window_id = w.id), '[]'::jsonb))
                          order by r.starts_at desc)
                     from erp.maintenance_report() r
                     join erp_meta.maintenance_window w on w.code = r.code), '[]'::jsonb);
end;
$$;

create or replace function public.erp_platform_incident_organisations(p_incident_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  -- The organisations named, then the client deployments reached, each
  -- saying which it is (20261012060000).
  return coalesce((
    select jsonb_agg(e.entry order by e.ord, e.code)
      from (select 1 as ord, t.tenant_code as code,
                   jsonb_build_object('kind', 'organisation', 'tenant_code', t.tenant_code,
                                      'named_at', t.named_at, 'named_by', t.named_by) as entry
              from erp_meta.incident_tenant t
              join erp_meta.incident i on i.id = t.incident_id
             where i.code = p_incident_code
            union all
            select 2, x.code,
                   jsonb_build_object('kind', 'deployment', 'deployment_code', x.code, 'address', d.address,
                                      'reach', x.reach, 'named_at', x.named_at, 'named_by', x.named_by,
                                      'outcome', x.outcome, 'detail', x.detail, 'run_id', x.run_id, 'settled_at', x.settled_at,
                                      'last_pushed_at', x.last_pushed_at, 'client_told_at', x.client_told_at)
              from erp_meta.incident_deployment x
              join erp_meta.incident i on i.id = x.incident_id
              join erp_meta.deployment d on d.code = x.code
             where i.code = p_incident_code) e), '[]'::jsonb);
end;
$$;

comment on function public.erp_platform_incidents() is
  'The incident register for the console: each incident as erp.incident_report() reads it, whether it reaches every '
  'client, when it was received from the control plane (on a client''s own deployment), and the client deployments '
  'it reached with what the push last did at each and when the client said its people were told. Platform support '
  'and above (20261012060000).';
comment on function public.erp_platform_maintenance_windows() is
  'The maintenance windows for the console: each as erp.maintenance_report() reads it, whether it reaches every '
  'client, when it was received from the control plane, and the client deployments it reached with what the push '
  'last did at each. Platform support and above (20261012060000).';
comment on function public.erp_platform_incident_organisations(text) is
  'Who an incident reached: the organisations named here (kind organisation, tenant_code), then the client '
  'deployments named or reached as every client (kind deployment, deployment_code), with what the push last did at '
  'each and when the client said its people were told. Platform support and above (20261012060000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What is carried, and the control plane handing it out
-- ─────────────────────────────────────────────────────────────────────────────

-- What a client is carried of one incident. Times in UTC, so the digest of
-- the same incident is the same whatever the session's zone.
create or replace function erp_meta.incident_push_payload(p_incident_id uuid)
returns jsonb
language sql
stable
set search_path = ''
set timezone to 'UTC'
as $$
  -- The incident whole, as the client keeps it: its times, its three roles,
  -- its updates, its components, its disclosures without their note, and a
  -- shared review as the four parts an organisation's history reads: the
  -- duration, the updates promised, the timeline, and the actions without
  -- their owner or note. The timeline names each update it read by its id,
  -- which the client reads back from the updates carried beside it, so a long
  -- incident's words are carried once; an entry that is no update of this
  -- incident is carried as it reads, without who posted it. No staff address:
  -- who posted an update or recorded a disclosure is "the platform". Not its
  -- organisations, prompts, actions, review link or who declared it
  -- (20261012060000).
  select jsonb_build_object(
           'id', i.id, 'code', i.code, 'severity_code', i.severity_code, 'title', i.title,
           'declared_at', i.declared_at, 'created_at', i.created_at,
           'contained_at', i.contained_at, 'resolved_at', i.resolved_at,
           'commander', i.commander, 'communications_owner', i.communications_owner, 'scribe', i.scribe,
           'scope', i.scope, 'is_data_integrity', i.is_data_integrity, 'is_security', i.is_security,
           'next_update_due_at', i.next_update_due_at, 'review_completed_at', i.review_completed_at,
           'origin_dependency_code', i.origin_dependency_code,
           'components', coalesce((select jsonb_agg(c.component_code order by c.component_code)
                                     from erp_meta.incident_component c where c.incident_id = i.id), '[]'::jsonb),
           'updates', coalesce((select jsonb_agg(jsonb_build_object(
                                         'id', u.id, 'posted_at', u.posted_at, 'body', u.body,
                                         'posted_by', 'the platform', 'is_no_change', u.is_no_change,
                                         'affected', u.affected, 'not_affected', u.not_affected,
                                         'being_done', u.being_done, 'meanwhile', u.meanwhile,
                                         'next_update_at', u.next_update_at)
                                       order by u.posted_at, u.id)
                                  from erp_meta.incident_update u where u.incident_id = i.id), '[]'::jsonb),
           'disclosures', coalesce((select jsonb_agg(jsonb_build_object(
                                             'id', d.id, 'obligation_code', d.obligation_code, 'due_at', d.due_at,
                                             'notified_at', d.notified_at,
                                             'notified_by', case when d.notified_by is not null then 'the platform' end,
                                             'created_at', d.created_at)
                                           order by d.obligation_code)
                                      from erp_meta.incident_disclosure d where d.incident_id = i.id), '[]'::jsonb),
           'review', (select jsonb_build_object(
                               'assembled_at', r.assembled_at,
                               'document', jsonb_build_object(
                                 'duration_minutes', r.document -> 'duration_minutes',
                                 'updates_promised', r.document -> 'updates_promised',
                                 'timeline', coalesce((select jsonb_agg(
                                                                case when m.id is not null
                                                                     then jsonb_build_object('update_id', m.id)
                                                                     else jsonb_build_object(
                                                                            'posted_at', t.x -> 'posted_at',
                                                                            'body', t.x -> 'body',
                                                                            'is_no_change', t.x -> 'is_no_change',
                                                                            'next_update_at', t.x -> 'next_update_at') end
                                                              order by t.o)
                                                         from jsonb_array_elements(
                                                                case when jsonb_typeof(r.document -> 'timeline') = 'array'
                                                                     then r.document -> 'timeline' else '[]'::jsonb end)
                                                              with ordinality t(x, o)
                                                         left join lateral (
                                                                select u.id
                                                                  from erp_meta.incident_update u
                                                                 where u.incident_id = i.id
                                                                   and jsonb_typeof(t.x) = 'object'
                                                                   and u.body = t.x ->> 'body'
                                                                   and pg_catalog.pg_input_is_valid(t.x ->> 'posted_at', 'timestamptz')
                                                                   and u.posted_at = case
                                                                         when pg_catalog.pg_input_is_valid(t.x ->> 'posted_at', 'timestamptz')
                                                                         then (t.x ->> 'posted_at')::timestamptz end
                                                                   and t.x -> 'is_no_change' = to_jsonb(u.is_no_change)
                                                                 order by u.id
                                                                 limit 1) m on true), '[]'::jsonb),
                                 'actions', coalesce((select jsonb_agg(jsonb_build_object(
                                                               'description', a.x -> 'description',
                                                               'done_at', a.x -> 'done_at')
                                                             order by a.o)
                                                        from jsonb_array_elements(
                                                               case when jsonb_typeof(r.document -> 'actions') = 'array'
                                                                    then r.document -> 'actions' else '[]'::jsonb end)
                                                             with ordinality a(x, o)), '[]'::jsonb)))
                        from erp_meta.incident_review r
                       where r.incident_id = i.id and r.is_shared))
    from erp_meta.incident i
   where i.id = p_incident_id
$$;

create or replace function erp_meta.maintenance_push_payload(p_window_id uuid)
returns jsonb
language sql
stable
set search_path = ''
set timezone to 'UTC'
as $$
  -- The window whole, cancellation included; not who it names here, nor the
  -- address of who announced it, which is "the platform" (20261012060000).
  select jsonb_build_object(
           'id', w.id, 'code', w.code, 'title', w.title, 'detail', w.detail,
           'starts_at', w.starts_at, 'ends_at', w.ends_at, 'announced_at', w.announced_at,
           'announced_by', 'the platform', 'is_emergency', w.is_emergency, 'emergency_reason', w.emergency_reason,
           'cancelled_at', w.cancelled_at, 'cancel_reason', w.cancel_reason, 'created_at', w.created_at)
    from erp_meta.maintenance_window w
   where w.id = p_window_id
$$;

revoke all on function erp_meta.incident_push_payload(uuid) from public, anon, authenticated, service_role;
revoke all on function erp_meta.maintenance_push_payload(uuid) from public, anon, authenticated, service_role;

comment on function erp_meta.incident_push_payload(uuid) is
  'What a client deployment is carried of one incident: its times (UTC), severity, title, three roles, scope, '
  'flags, timer and review date, origin, components, updates, disclosures without their note, and a shared review '
  'as duration_minutes, updates_promised, the timeline (each update it read as {update_id}, read back from the '
  'updates carried; anything else as it reads, without who posted it), and the actions without owner or note. Who '
  'posted an update or recorded a disclosure is "the platform". Never its organisations, prompts, actions, review '
  'link, who declared it or any staff address. Plain (20261012060000).';
comment on function erp_meta.maintenance_push_payload(uuid) is
  'What a client deployment is carried of one maintenance window, its cancellation included, without who it names '
  'here; announced_by is "the platform". Plain (20261012060000).';

create or replace function erp_meta.incident_pushes_due(p_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  d           erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_up        boolean;
  v_incidents jsonb;
  v_windows   jsonb;
  v_told_of   jsonb;
  v_check     boolean;
begin
  v_up := d.status in ('built', 'live', 'suspended') or (d.status = 'retiring' and d.built_at is not null);
  if not v_up then
    return jsonb_build_object('code', d.code, 'up', false, 'incidents', '[]'::jsonb, 'windows', '[]'::jsonb,
                              'told_of', '[]'::jsonb, 'check_held', false);
  end if;
  -- What reaches it and changed since the client last answered: an incident
  -- named for it, or carried there already, or every client's (not resolved
  -- before it was registered), open or resolved in the last thirty days; a
  -- window likewise, upcoming, in progress, or ended or cancelled in the
  -- last thirty days, and one for every client never carried there only
  -- while it is not cancelled. Oldest first, fifty of each at most; the rest
  -- wait for the next run (20261012060000).
  v_incidents := coalesce((
    select jsonb_agg(jsonb_build_object('id', y.id, 'digest', y.digest, 'payload', y.payload) order by y.at, y.id)
      from (select x.id, x.at, x.digest, x.payload
              from (select c.id, c.at, c.payload, md5(c.payload::text) as digest, c.last_digest
                      from (select i.id, i.declared_at as at, l.last_digest,
                                   erp_meta.incident_push_payload(i.id) as payload
                              from erp_meta.incident i
                              left join erp_meta.incident_deployment l on l.incident_id = i.id and l.code = d.code
                             where i.received_at is null
                               and (l.incident_id is not null
                                    or (i.every_client and (i.resolved_at is null or i.resolved_at >= d.created_at)))
                               and (i.resolved_at is null or i.resolved_at >= now() - interval '30 days')) c) x
             where x.digest is distinct from x.last_digest
             order by x.at, x.id
             limit 50) y), '[]'::jsonb);
  v_windows := coalesce((
    select jsonb_agg(jsonb_build_object('id', y.id, 'digest', y.digest, 'payload', y.payload) order by y.at, y.id)
      from (select x.id, x.at, x.digest, x.payload
              from (select c.id, c.at, c.payload, md5(c.payload::text) as digest, c.last_digest
                      from (select w.id, w.starts_at as at, l.last_digest,
                                   erp_meta.maintenance_push_payload(w.id) as payload
                              from erp_meta.maintenance_window w
                              left join erp_meta.maintenance_window_deployment l
                                on l.window_id = w.id and l.code = d.code
                             where w.received_at is null
                               and (l.window_id is not null
                                    or (w.every_client and w.cancelled_at is null and w.ends_at >= d.created_at))
                               and (w.ends_at >= now() - interval '30 days'
                                    or w.cancelled_at >= now() - interval '30 days')) c) x
             where x.digest is distinct from x.last_digest
             order by x.at, x.id
             limit 50) y), '[]'::jsonb);

  -- What is handed out as every client's reaches this deployment from now:
  -- a row of the ledger before any answer, so a change after it is owed here
  -- whatever becomes of the answer, and a lost settle loses nothing. A row
  -- named already stays as it was (20261012060000).
  insert into erp_meta.incident_deployment (incident_id, code, reach, named_at)
  select (x ->> 'id')::uuid, d.code, 'every_client', now()
    from jsonb_array_elements(v_incidents) x
  on conflict (incident_id, code) do nothing;
  insert into erp_meta.maintenance_window_deployment (window_id, code, reach, named_at)
  select (x ->> 'id')::uuid, d.code, 'every_client', now()
    from jsonb_array_elements(v_windows) x
  on conflict (window_id, code) do nothing;

  -- The incidents it holds whose telling it has not reported yet.
  v_told_of := coalesce((
    select jsonb_agg(l.incident_id order by l.incident_id)
      from erp_meta.incident_deployment l
      join erp_meta.incident i on i.id = l.incident_id
     where l.code = d.code and l.client_told_at is null and l.last_pushed_at is not null
       and (i.resolved_at is null or i.resolved_at >= now() - interval '30 days')), '[]'::jsonb);

  -- Once a day at least the client says what it holds, nothing else owed or
  -- not: a client restored to an earlier point holds less than this ledger
  -- says, and only its answer shows it (20261012060000).
  v_check := not exists (select 1 from erp_meta.incident_held_check h
                          where h.code = d.code and h.checked_at >= now() - interval '24 hours');

  return jsonb_build_object('code', d.code, 'up', true, 'incidents', v_incidents, 'windows', v_windows,
                            'told_of', v_told_of, 'check_held', v_check);
end;
$$;

revoke all on function erp_meta.incident_pushes_due(text) from public, anon, authenticated, service_role;

comment on function erp_meta.incident_pushes_due(text) is
  'What one client deployment is owed of incidents and maintenance, for the fleet''s push: {code, up, incidents, '
  'windows, told_of, check_held}. incidents and windows are each [{id, digest, payload}], those reaching it (named, '
  'carried there already, or every client''s) whose digest differs from the one the client last answered, in the '
  'thirty days the notices show, oldest first, fifty of each at most; told_of the incidents it holds whose telling '
  'it has not reported; check_held true when the client has not said what it holds for a day, so the push asks '
  'even with nothing else owed. Each every-client incident or window handed out becomes a row of the ledger '
  '(reach every_client) as it is handed out, so a change to it is owed there whatever becomes of the answer. A '
  'deployment that is not up is owed nothing. Pass the whole answer to erp_meta.apply_pushed_incidents on the '
  'client. Trusted build role only (20261012060000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. What a client does with it
-- ─────────────────────────────────────────────────────────────────────────────

-- One value of a pushed record in the form it must have.
create or replace function erp_meta.pushed_value_is(p_value jsonb, p_kind text, p_nullable boolean default false)
returns boolean
language sql
stable
set search_path = ''
as $$
  select case
           when p_value is null or jsonb_typeof(p_value) = 'null' then p_nullable
           when p_kind = 'text' then jsonb_typeof(p_value) = 'string'
           when p_kind = 'words' then jsonb_typeof(p_value) = 'string' and btrim(p_value #>> '{}') <> ''
           when p_kind = 'uuid' then jsonb_typeof(p_value) = 'string'
                                     and pg_catalog.pg_input_is_valid(p_value #>> '{}', 'uuid')
           when p_kind = 'instant' then jsonb_typeof(p_value) = 'string'
                                        and pg_catalog.pg_input_is_valid(p_value #>> '{}', 'timestamptz')
           when p_kind = 'boolean' then jsonb_typeof(p_value) = 'boolean'
           when p_kind = 'list' then jsonb_typeof(p_value) = 'array'
           when p_kind = 'object' then jsonb_typeof(p_value) = 'object'
           else false
         end
$$;

revoke all on function erp_meta.pushed_value_is(jsonb, text, boolean) from public, anon, authenticated, service_role;

comment on function erp_meta.pushed_value_is(jsonb, text, boolean) is
  'Whether one value of an incident or window pushed from the control plane has its form: text, words (not blank), '
  'uuid, instant, boolean, list or object, or null where that is allowed. Plain (20261012060000).';

create or replace function erp_meta.apply_pushed_incidents(p_push jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_items    jsonb;
  v_windows  jsonb;
  v_told_of  jsonb;
  v_inc_out  jsonb := '[]'::jsonb;
  v_win_out  jsonb := '[]'::jsonb;
  v_told     jsonb;
  v_held_out jsonb;
  v_fault    text;
  v_wait     text;
  v_id       uuid;
  v_p        jsonb;
  v_digest   text;
  v_held     erp_meta.incident%rowtype;
  v_wheld    erp_meta.maintenance_window%rowtype;
  v_other    text;
  v_outcome  text;
  v_detail   text;
  r          record;
begin
  -- On a client's own deployment only (20261012060000).
  if erp.deployment_kind() <> 'client' then
    raise exception 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the % deployment, not a client''s own, so it takes no incidents or maintenance from the register', erp.deployment_kind()
      using errcode = '55000',
            hint = 'Declare an incident or announce a window for a client on the platform console at cloveerp.com; '
                   'its own deployment takes it when the fleet''s push next runs.';
  end if;

  -- What was pushed, in its form; a fault is named by its place, never its
  -- value: the refusal reaches a public workflow log.
  if p_push is null or jsonb_typeof(p_push) <> 'object' then
    v_fault := 'it is not a set of named values';
  else
    v_items := coalesce(p_push -> 'incidents', '[]'::jsonb);
    v_windows := coalesce(p_push -> 'windows', '[]'::jsonb);
    v_told_of := coalesce(p_push -> 'told_of', '[]'::jsonb);
    if jsonb_typeof(v_items) <> 'array' then
      v_fault := 'incidents is not a list';
    elsif jsonb_typeof(v_windows) <> 'array' then
      v_fault := 'windows is not a list';
    elsif jsonb_typeof(v_told_of) <> 'array' then
      v_fault := 'told_of is not a list';
    elsif exists (select 1 from jsonb_array_elements(v_items || v_windows) x
                   where jsonb_typeof(x) <> 'object' or not erp_meta.pushed_value_is(x -> 'id', 'uuid')
                      or jsonb_typeof(x -> 'payload') is distinct from 'object') then
      v_fault := 'an incident or window names no id, or carries no payload';
    elsif exists (select 1 from jsonb_array_elements(v_told_of) x where not erp_meta.pushed_value_is(x, 'uuid')) then
      v_fault := 'told_of names something that is not an incident''s id';
    end if;
  end if;
  if v_fault is not null then
    raise exception 'CLOVEERP_PUSH_MALFORMED: the incidents and windows pushed are not applied: %', v_fault
      using errcode = '22023',
            hint = 'Nothing was changed. Pass erp_meta.incident_pushes_due''s answer as it came: {incidents, windows, '
                   'told_of}, each incident and window {id, digest, payload}.';
  end if;

  -- One push at a time on this deployment.
  perform pg_advisory_xact_lock(hashtext('erp_meta.apply_pushed_incidents'));

  -- ── The incidents ─────────────────────────────────────────────────────────
  for r in select x as item, o from jsonb_array_elements(v_items) with ordinality a(x, o) order by o loop
    v_id := (r.item ->> 'id')::uuid;
    v_p := r.item -> 'payload';
    v_digest := md5(v_p::text);
    v_outcome := null;
    v_detail := null;
    begin
      -- Its form, each part named by its place.
      select string_agg(f.k, ', ' order by f.ord) into v_fault
        from (values ('id', 'uuid', false, 1), ('code', 'words', false, 2), ('severity_code', 'words', false, 3),
                     ('title', 'words', false, 4), ('declared_at', 'instant', false, 5),
                     ('created_at', 'instant', false, 6), ('contained_at', 'instant', true, 7),
                     ('resolved_at', 'instant', true, 8), ('commander', 'words', false, 9),
                     ('communications_owner', 'words', false, 10), ('scribe', 'words', false, 11),
                     ('scope', 'text', true, 12), ('is_data_integrity', 'boolean', false, 13),
                     ('is_security', 'boolean', false, 14), ('next_update_due_at', 'instant', true, 15),
                     ('review_completed_at', 'instant', true, 16), ('origin_dependency_code', 'words', true, 17),
                     ('components', 'list', false, 18), ('updates', 'list', false, 19),
                     ('disclosures', 'list', false, 20), ('review', 'object', true, 21)) f(k, kind, nullable, ord)
       where not erp_meta.pushed_value_is(v_p -> f.k, f.kind, f.nullable);
      if v_fault is null and (v_p ->> 'id')::uuid <> v_id then
        v_fault := 'id is not the id it was pushed under';
      end if;
      if v_fault is null then
        select string_agg(format('components[%s]', c.o), ', ' order by c.o) into v_fault
          from jsonb_array_elements(v_p -> 'components') with ordinality c(x, o)
         where not erp_meta.pushed_value_is(c.x, 'words');
      end if;
      if v_fault is null then
        select string_agg(format('updates[%s].%s', u.o, f.k), ', ' order by u.o, f.ord) into v_fault
          from jsonb_array_elements(v_p -> 'updates') with ordinality u(x, o)
          cross join (values ('id', 'uuid', false, 1), ('posted_at', 'instant', false, 2),
                             ('body', 'words', false, 3), ('posted_by', 'words', false, 4),
                             ('is_no_change', 'boolean', false, 5), ('affected', 'text', true, 6),
                             ('not_affected', 'text', true, 7), ('being_done', 'text', true, 8),
                             ('meanwhile', 'text', true, 9), ('next_update_at', 'instant', true, 10)) f(k, kind, nullable, ord)
         where not erp_meta.pushed_value_is(u.x -> f.k, f.kind, f.nullable);
      end if;
      if v_fault is null then
        select string_agg(format('disclosures[%s].%s', s.o, f.k), ', ' order by s.o, f.ord) into v_fault
          from jsonb_array_elements(v_p -> 'disclosures') with ordinality s(x, o)
          cross join (values ('id', 'uuid', false, 1), ('obligation_code', 'words', false, 2),
                             ('due_at', 'instant', false, 3), ('notified_at', 'instant', true, 4),
                             ('notified_by', 'text', true, 5), ('created_at', 'instant', false, 6)) f(k, kind, nullable, ord)
         where not erp_meta.pushed_value_is(s.x -> f.k, f.kind, f.nullable);
      end if;
      if v_fault is null and jsonb_typeof(v_p -> 'review') = 'object'
         and (not erp_meta.pushed_value_is(v_p -> 'review' -> 'assembled_at', 'instant')
              or not erp_meta.pushed_value_is(v_p -> 'review' -> 'document', 'object')
              or not erp_meta.pushed_value_is(v_p -> 'review' -> 'document' -> 'timeline', 'list')) then
        v_fault := 'review';
      end if;
      -- The review's timeline names an update carried beside it, by its id,
      -- or reads as an update does (20261012060000).
      if v_fault is null and jsonb_typeof(v_p -> 'review') = 'object' then
        select string_agg(format('review.timeline[%s]', t.o), ', ' order by t.o) into v_fault
          from jsonb_array_elements(v_p -> 'review' -> 'document' -> 'timeline') with ordinality t(x, o)
         where case
                 when jsonb_typeof(t.x) <> 'object' then true
                 when t.x ? 'update_id' then
                   not exists (select 1 from jsonb_array_elements(v_p -> 'updates') u
                                where lower(u ->> 'id') = lower(t.x ->> 'update_id'))
                 else not erp_meta.pushed_value_is(t.x -> 'posted_at', 'instant')
                      or not erp_meta.pushed_value_is(t.x -> 'body', 'words')
               end;
      end if;
      if v_fault is not null then
        raise exception 'CLOVEERP_PUSH_MALFORMED: the incident pushed as % is not applied: % not in its form', v_id, v_fault
          using errcode = '22023',
                hint = 'Nothing was changed. The control plane records the push as failed; mend what computed it '
                       'there, and the next run carries it.';
      end if;

      -- Its own, or another of this deployment's under its code.
      select * into v_held from erp_meta.incident i where i.id = v_id;
      if v_held.id is not null and v_held.received_at is null then
        raise exception 'CLOVEERP_PUSHED_CODE_HELD: this deployment holds the incident % as its own, so the control plane''s is not taken', v_id
          using errcode = '23505',
                hint = 'Nothing was changed on the client. Declare it again on the control plane under a code no '
                       'client holds.';
      end if;
      select i.code into v_other from erp_meta.incident i where i.code = v_p ->> 'code' and i.id <> v_id;
      if v_other is not null then
        raise exception 'CLOVEERP_PUSHED_CODE_HELD: this deployment holds % for an incident of its own, so the control plane''s is not taken', v_other
          using errcode = '23505',
                hint = 'Nothing was changed on the client. Declare it again on the control plane under a code no '
                       'client holds, and resolve the first.';
      end if;

      if v_held.received_digest = v_digest then
        v_outcome := 'replay';
        v_detail := format('held already, since %s',
                           to_char(v_held.received_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"'));
      else
        -- A severity, component, provider or timeline this database does not
        -- know yet: it is behind on its release, and holds what it held.
        select string_agg(u.what, ', ' order by u.what) into v_wait
          from (select 'severity ' || (v_p ->> 'severity_code') as what
                 where not exists (select 1 from erp_ref.support_severity s where s.code = v_p ->> 'severity_code')
                union
                select 'component ' || (c #>> '{}')
                  from jsonb_array_elements(v_p -> 'components') c
                 where not exists (select 1 from erp_ref.platform_component pc where pc.code = c #>> '{}')
                union
                select 'provider ' || (v_p ->> 'origin_dependency_code')
                 where v_p ->> 'origin_dependency_code' is not null
                   and not exists (select 1 from erp_ref.platform_dependency pd
                                    where pd.code = v_p ->> 'origin_dependency_code')
                union
                select 'timeline ' || (s ->> 'obligation_code')
                  from jsonb_array_elements(v_p -> 'disclosures') s
                 where not exists (select 1 from erp_ref.notice_period n where n.code = s ->> 'obligation_code')) u;
        if v_wait is not null then
          v_outcome := 'waiting';
          v_detail := format('this deployment does not know %s yet: it is behind on its release, and holds what it '
                             'held', v_wait);
        else
          -- Kept by the control plane's id; it reaches this deployment's one
          -- organisation, and names nobody.
          insert into erp_meta.incident as i
            (id, code, severity_code, title, declared_at, created_at, contained_at, resolved_at,
             commander, communications_owner, scribe, scope, affects_all_tenants, is_data_integrity, is_security,
             next_update_due_at, review_completed_at, origin_dependency_code, declared_by, every_client,
             received_at, received_digest)
          values (v_id, v_p ->> 'code', v_p ->> 'severity_code', v_p ->> 'title',
                  (v_p ->> 'declared_at')::timestamptz, (v_p ->> 'created_at')::timestamptz,
                  (v_p ->> 'contained_at')::timestamptz, (v_p ->> 'resolved_at')::timestamptz,
                  v_p ->> 'commander', v_p ->> 'communications_owner', v_p ->> 'scribe', v_p ->> 'scope', true,
                  (v_p ->> 'is_data_integrity')::boolean, (v_p ->> 'is_security')::boolean,
                  (v_p ->> 'next_update_due_at')::timestamptz, (v_p ->> 'review_completed_at')::timestamptz,
                  v_p ->> 'origin_dependency_code', null, false, clock_timestamp(), v_digest)
          on conflict (id) do update
             set code = excluded.code, severity_code = excluded.severity_code, title = excluded.title,
                 declared_at = excluded.declared_at, created_at = excluded.created_at,
                 contained_at = excluded.contained_at, resolved_at = excluded.resolved_at,
                 commander = excluded.commander, communications_owner = excluded.communications_owner,
                 scribe = excluded.scribe, scope = excluded.scope, affects_all_tenants = true,
                 is_data_integrity = excluded.is_data_integrity, is_security = excluded.is_security,
                 next_update_due_at = excluded.next_update_due_at,
                 review_completed_at = excluded.review_completed_at,
                 origin_dependency_code = excluded.origin_dependency_code,
                 received_at = excluded.received_at, received_digest = excluded.received_digest;

          -- Components may be replaced; nothing else received is deleted.
          delete from erp_meta.incident_component c
           where c.incident_id = v_id
             and not exists (select 1 from jsonb_array_elements_text(v_p -> 'components') x where x = c.component_code);
          insert into erp_meta.incident_component (incident_id, component_code)
          select v_id, x from jsonb_array_elements_text(v_p -> 'components') x
          on conflict do nothing;

          -- Updates by their id, never deleted: who was told of each is kept
          -- against it (erp_meta.incident_delivery).
          insert into erp_meta.incident_update as u
            (id, incident_id, posted_at, body, posted_by, is_no_change, affected, not_affected, being_done,
             meanwhile, next_update_at)
          select (x ->> 'id')::uuid, v_id, (x ->> 'posted_at')::timestamptz, x ->> 'body', x ->> 'posted_by',
                 (x ->> 'is_no_change')::boolean, x ->> 'affected', x ->> 'not_affected', x ->> 'being_done',
                 x ->> 'meanwhile', (x ->> 'next_update_at')::timestamptz
            from jsonb_array_elements(v_p -> 'updates') x
          on conflict (id) do update
             set posted_at = excluded.posted_at, body = excluded.body, posted_by = excluded.posted_by,
                 is_no_change = excluded.is_no_change, affected = excluded.affected,
                 not_affected = excluded.not_affected, being_done = excluded.being_done,
                 meanwhile = excluded.meanwhile, next_update_at = excluded.next_update_at
           where u.incident_id = excluded.incident_id;

          -- Disclosures as the control plane dates them, without their note.
          delete from erp_meta.incident_disclosure s
           where s.incident_id = v_id
             and not exists (select 1 from jsonb_array_elements(v_p -> 'disclosures') x
                              where (x ->> 'id')::uuid = s.id);
          insert into erp_meta.incident_disclosure as s
            (id, incident_id, obligation_code, due_at, notified_at, notified_by, created_at)
          select (x ->> 'id')::uuid, v_id, x ->> 'obligation_code', (x ->> 'due_at')::timestamptz,
                 (x ->> 'notified_at')::timestamptz, x ->> 'notified_by', (x ->> 'created_at')::timestamptz
            from jsonb_array_elements(v_p -> 'disclosures') x
          on conflict (id) do update
             set obligation_code = excluded.obligation_code, due_at = excluded.due_at,
                 notified_at = excluded.notified_at, notified_by = excluded.notified_by,
                 created_at = excluded.created_at
           where s.incident_id = excluded.incident_id;

          -- The review it shared, or none. Its timeline is read back whole
          -- from the updates carried beside it, each named by its id, so it
          -- reads here as it did there (20261012060000).
          if jsonb_typeof(v_p -> 'review') = 'object' then
            insert into erp_meta.incident_review as rv (incident_id, assembled_at, assembled_by, document, is_shared)
            values (v_id, (v_p -> 'review' ->> 'assembled_at')::timestamptz, 'the platform',
                    (v_p -> 'review' -> 'document')
                    || jsonb_build_object('timeline', coalesce((
                         select jsonb_agg(case
                                            when t.x ? 'update_id' then
                                              (select jsonb_build_object('posted_at', u -> 'posted_at',
                                                                         'body', u -> 'body',
                                                                         'is_no_change', u -> 'is_no_change',
                                                                         'next_update_at', u -> 'next_update_at')
                                                 from jsonb_array_elements(v_p -> 'updates') u
                                                where lower(u ->> 'id') = lower(t.x ->> 'update_id')
                                                limit 1)
                                            else t.x end
                                          order by t.o)
                           from jsonb_array_elements(v_p -> 'review' -> 'document' -> 'timeline')
                                with ordinality t(x, o)), '[]'::jsonb)),
                    true)
            on conflict (incident_id) do update
               set assembled_at = excluded.assembled_at, assembled_by = excluded.assembled_by,
                   document = excluded.document, is_shared = true;
          else
            delete from erp_meta.incident_review rv where rv.incident_id = v_id;
          end if;

          v_outcome := 'applied';
          v_detail := format('holds %s as the control plane carried it, with %s update(s)', v_p ->> 'code',
                             jsonb_array_length(v_p -> 'updates'));
        end if;
      end if;
    exception when others then
      -- Refused for good what this deployment will never take as it is; any
      -- other failure waits for the next run. The message only: the payload
      -- is in the detail, which goes nowhere.
      if sqlerrm like 'CLOVEERP_%' or sqlstate like '22%' or sqlstate like '23%' then
        v_outcome := 'refused';
      else
        v_outcome := 'waiting';
      end if;
      v_detail := left(sqlerrm, 500);
    end;
    v_inc_out := v_inc_out || jsonb_build_array(jsonb_build_object('id', v_id, 'outcome', v_outcome,
                                                                   'detail', v_detail, 'digest', v_digest));
  end loop;

  -- ── The windows ───────────────────────────────────────────────────────────
  for r in select x as item, o from jsonb_array_elements(v_windows) with ordinality a(x, o) order by o loop
    v_id := (r.item ->> 'id')::uuid;
    v_p := r.item -> 'payload';
    v_digest := md5(v_p::text);
    v_outcome := null;
    v_detail := null;
    begin
      select string_agg(f.k, ', ' order by f.ord) into v_fault
        from (values ('id', 'uuid', false, 1), ('code', 'words', false, 2), ('title', 'words', false, 3),
                     ('detail', 'text', true, 4), ('starts_at', 'instant', false, 5),
                     ('ends_at', 'instant', false, 6), ('announced_at', 'instant', false, 7),
                     ('announced_by', 'words', false, 8), ('is_emergency', 'boolean', false, 9),
                     ('emergency_reason', 'text', true, 10), ('cancelled_at', 'instant', true, 11),
                     ('cancel_reason', 'text', true, 12), ('created_at', 'instant', false, 13)) f(k, kind, nullable, ord)
       where not erp_meta.pushed_value_is(v_p -> f.k, f.kind, f.nullable);
      if v_fault is null and (v_p ->> 'id')::uuid <> v_id then
        v_fault := 'id is not the id it was pushed under';
      end if;
      if v_fault is not null then
        raise exception 'CLOVEERP_PUSH_MALFORMED: the maintenance window pushed as % is not applied: % not in its form', v_id, v_fault
          using errcode = '22023',
                hint = 'Nothing was changed. The control plane records the push as failed; mend what computed it '
                       'there, and the next run carries it.';
      end if;

      select * into v_wheld from erp_meta.maintenance_window w where w.id = v_id;
      if v_wheld.id is not null and v_wheld.received_at is null then
        raise exception 'CLOVEERP_PUSHED_CODE_HELD: this deployment holds the maintenance window % as its own, so the control plane''s is not taken', v_id
          using errcode = '23505',
                hint = 'Nothing was changed on the client. Announce it again on the control plane under a code no '
                       'client holds.';
      end if;
      v_other := null;
      select w.code into v_other from erp_meta.maintenance_window w where w.code = v_p ->> 'code' and w.id <> v_id;
      if v_other is not null then
        raise exception 'CLOVEERP_PUSHED_CODE_HELD: this deployment holds % for a maintenance window of its own, so the control plane''s is not taken', v_other
          using errcode = '23505',
                hint = 'Nothing was changed on the client. Announce it again on the control plane under a code no '
                       'client holds, and cancel the first.';
      end if;

      if v_wheld.received_digest = v_digest then
        v_outcome := 'replay';
        v_detail := format('held already, since %s',
                           to_char(v_wheld.received_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"'));
      else
        insert into erp_meta.maintenance_window as w
          (id, code, title, detail, starts_at, ends_at, announced_at, announced_by, is_emergency, emergency_reason,
           affects_all_tenants, cancelled_at, cancel_reason, created_at, every_client, received_at, received_digest)
        values (v_id, v_p ->> 'code', v_p ->> 'title', v_p ->> 'detail', (v_p ->> 'starts_at')::timestamptz,
                (v_p ->> 'ends_at')::timestamptz, (v_p ->> 'announced_at')::timestamptz, v_p ->> 'announced_by',
                (v_p ->> 'is_emergency')::boolean, v_p ->> 'emergency_reason', true,
                (v_p ->> 'cancelled_at')::timestamptz, v_p ->> 'cancel_reason', (v_p ->> 'created_at')::timestamptz,
                false, clock_timestamp(), v_digest)
        on conflict (id) do update
           set code = excluded.code, title = excluded.title, detail = excluded.detail,
               starts_at = excluded.starts_at, ends_at = excluded.ends_at, announced_at = excluded.announced_at,
               announced_by = excluded.announced_by, is_emergency = excluded.is_emergency,
               emergency_reason = excluded.emergency_reason, affects_all_tenants = true,
               cancelled_at = excluded.cancelled_at, cancel_reason = excluded.cancel_reason,
               created_at = excluded.created_at, received_at = excluded.received_at,
               received_digest = excluded.received_digest;
        v_outcome := 'applied';
        v_detail := format('holds %s as the control plane carried it%s', v_p ->> 'code',
                           case when v_p ->> 'cancelled_at' is not null then ', cancelled' else '' end);
      end if;
    exception when others then
      if sqlerrm like 'CLOVEERP_%' or sqlstate like '22%' or sqlstate like '23%' then
        v_outcome := 'refused';
      else
        v_outcome := 'waiting';
      end if;
      v_detail := left(sqlerrm, 500);
    end;
    v_win_out := v_win_out || jsonb_build_array(jsonb_build_object('id', v_id, 'outcome', v_outcome,
                                                                   'detail', v_detail, 'digest', v_digest));
  end loop;

  -- When this deployment's people were first told of each incident it holds
  -- that the control plane asked about or just carried: the first delivery
  -- here that reached somebody, or null while none has. A delivery to an
  -- organisation nobody has joined yet told nobody (20261012060000).
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id,
                                               'told_at', (select min(d.delivered_at) from erp_meta.incident_delivery d
                                                            where d.incident_id = t.id and d.recipients > 0))
                            order by t.id), '[]'::jsonb)
    into v_told
    from (select distinct (x #>> '{}')::uuid as id from jsonb_array_elements(v_told_of) x
          union
          select (a ->> 'id')::uuid from jsonb_array_elements(v_inc_out) a
           where a ->> 'outcome' in ('applied', 'replay')) t
   where exists (select 1 from erp_meta.incident i where i.id = t.id and i.received_at is not null);

  -- What this deployment holds, every time: each received copy within a day
  -- more than the thirty the control plane carries, by its kind, id and the
  -- digest it was taken at. The control plane carries again whatever it
  -- carried that is not here as it was, as after a restore to an earlier
  -- point (20261012060000).
  select coalesce(jsonb_agg(h.e order by h.k, h.id), '[]'::jsonb)
    into v_held_out
    from (select 1 as k, i.id, jsonb_build_object('kind', 'incident', 'id', i.id, 'digest', i.received_digest) as e
            from erp_meta.incident i
           where i.received_at is not null
             and (i.resolved_at is null or i.resolved_at >= now() - interval '31 days')
          union all
          select 2, w.id, jsonb_build_object('kind', 'window', 'id', w.id, 'digest', w.received_digest)
            from erp_meta.maintenance_window w
           where w.received_at is not null
             and (w.ends_at >= now() - interval '31 days' or w.cancelled_at >= now() - interval '31 days')) h;

  return jsonb_build_object('incidents', v_inc_out, 'windows', v_win_out, 'told', v_told, 'held', v_held_out);
end;
$$;

revoke all on function erp_meta.apply_pushed_incidents(jsonb) from public, anon, authenticated, service_role;

comment on function erp_meta.apply_pushed_incidents(jsonb) is
  'Called by the fleet''s push on a client''s own deployment with erp_meta.incident_pushes_due''s answer, '
  '{incidents, windows, told_of}: keeps each incident and window by the control plane''s id with received_at and '
  'received_digest, reaching its one organisation (affects_all_tenants, nobody named); replaces components and the '
  'shared review (its timeline read back from the updates carried, by id), upserts updates and disclosures, and '
  'deletes nothing else. Answers {incidents: [{id, outcome, detail, digest}], windows: [the same], told: [{id, '
  'told_at}], held: [{kind, id, digest}]}: applied, replay (the same digest held already), waiting (a severity, '
  'component, provider or timeline not known here yet, or a failure that may pass), or refused '
  '(CLOVEERP_PUSHED_CODE_HELD when this deployment holds the code for one of its own, CLOVEERP_PUSH_MALFORMED for '
  'one not in its form); told_at is the first delivery here that reached somebody; held, always, every received '
  'copy here (kind incident or window) open or ended within thirty-one days with the digest it was taken at. Refuses '
  'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT anywhere but a client, and CLOVEERP_PUSH_MALFORMED for a push that is not a list '
  'of them. Trusted build role only (20261012060000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The control plane settles what the client answered
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.settle_incident_pushes(p_code text, p_run text, p_results jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  d          erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_run      text := btrim(coalesce(p_run, ''));
  v_fault    text;
  v_items    jsonb;
  v_windows  jsonb;
  v_told     jsonb;
  v_held     jsonb;
  r          record;
  v_reach    boolean;
  v_applied  integer := 0;
  v_waiting  integer := 0;
  v_failed   integer := 0;
  v_left     integer := 0;
  v_told_n   integer := 0;
  v_cleared  integer := 0;
  v_n        integer;
begin
  -- Refused only for what it cannot read (20261012060000).
  if v_run = '' or length(v_run) > 200 then
    v_fault := 'it names no run';
  elsif p_results is null or jsonb_typeof(p_results) <> 'object' then
    v_fault := 'the answers are not a set of named values';
  else
    v_items := coalesce(p_results -> 'incidents', '[]'::jsonb);
    v_windows := coalesce(p_results -> 'windows', '[]'::jsonb);
    v_told := coalesce(p_results -> 'told', '[]'::jsonb);
    -- What the client holds; absent from an answer that is not apply's whole,
    -- which then says nothing of it (20261012060000).
    v_held := nullif(p_results -> 'held', 'null'::jsonb);
    if jsonb_typeof(v_items) <> 'array' or jsonb_typeof(v_windows) <> 'array' or jsonb_typeof(v_told) <> 'array' then
      v_fault := 'incidents, windows and told are not each a list';
    elsif v_held is not null and jsonb_typeof(v_held) <> 'array' then
      v_fault := 'held is not a list';
    elsif v_held is not null
          and exists (select 1 from jsonb_array_elements(v_held) h(x)
                       where jsonb_typeof(h.x) <> 'object'
                          or coalesce(h.x ->> 'kind', '') not in ('incident', 'window')
                          or not erp_meta.pushed_value_is(h.x -> 'id', 'uuid')
                          or not erp_meta.pushed_value_is(h.x -> 'digest', 'text', true)) then
      v_fault := 'held names something that is not an incident or window it holds, with its digest';
    else
      select format('%s answer %s %s', y.kind, y.o, y.fault) into v_fault
        from (select x.kind, x.o, case
                       when jsonb_typeof(x.a) <> 'object' then 'is not a set of named values'
                       when not erp_meta.pushed_value_is(x.a -> 'id', 'uuid') then 'names no incident or window'
                       when coalesce(x.a ->> 'outcome', '') not in ('applied', 'replay', 'waiting', 'refused')
                         then 'says none of applied, replay, waiting or refused'
                       when not erp_meta.pushed_value_is(x.a -> 'detail', 'text', true) then 'has a detail that is not words'
                       when not erp_meta.pushed_value_is(x.a -> 'digest', 'text', true) then 'has a digest that is not words'
                     end as fault
                from (select 'incident' as kind, t.a, t.o
                        from jsonb_array_elements(v_items) with ordinality t(a, o)
                      union all
                      select 'window', t.a, t.o
                        from jsonb_array_elements(v_windows) with ordinality t(a, o)) x) y
       where y.fault is not null
       order by y.kind, y.o
       limit 1;
      if v_fault is null then
        select format('told %s names no incident, or a time that is not one', t.o) into v_fault
          from jsonb_array_elements(v_told) with ordinality t(a, o)
         where jsonb_typeof(t.a) <> 'object' or not erp_meta.pushed_value_is(t.a -> 'id', 'uuid')
            or not erp_meta.pushed_value_is(t.a -> 'told_at', 'instant', true)
         order by t.o
         limit 1;
      end if;
    end if;
  end if;
  if v_fault is not null then
    raise exception 'CLOVEERP_PUSH_SETTLE_UNREADABLE: what % answered of its incidents and windows is not settled: %', d.code, v_fault
      using errcode = '22023',
            hint = 'Settle with the run''s id and erp_meta.apply_pushed_incidents''s answer as the client returned it: '
                   '{incidents, windows, told}.';
  end if;

  -- Each incident answered. One reached only as every client is a row from
  -- the moment it was handed out (erp_meta.incident_pushes_due), and stays
  -- one; one answered without a row becomes one here: so does one the client
  -- took or held while every client was being said no more, which it holds
  -- now and is kept told of until it is resolved. One that reaches this
  -- deployment no way at all is left as it is.
  for r in
    select (x.a ->> 'id')::uuid as id, x.a ->> 'outcome' as outcome,
           left(coalesce(btrim(x.a ->> 'detail'), ''), 2000) as said, x.a ->> 'digest' as digest
      from jsonb_array_elements(v_items) with ordinality x(a, o)
     order by x.o
  loop
    select exists (select 1 from erp_meta.incident_deployment l where l.incident_id = r.id and l.code = d.code)
      into v_reach;
    if not v_reach then
      insert into erp_meta.incident_deployment (incident_id, code, reach, named_at)
      select i.id, d.code, 'every_client', now()
        from erp_meta.incident i
       where i.id = r.id and i.received_at is null
         and (i.every_client or r.outcome in ('applied', 'replay'))
      on conflict do nothing;
      if not found then
        v_left := v_left + 1;
        continue;
      end if;
    end if;
    update erp_meta.incident_deployment l
       set outcome = case r.outcome when 'refused' then 'failed' else r.outcome end,
           detail = coalesce(nullif(r.said, ''),
                             case r.outcome when 'applied' then 'taken by the client'
                                            when 'replay' then 'the client holds it already'
                                            when 'waiting' then 'the client is not ready for it yet'
                                            else 'refused by the client' end),
           run_id = v_run, settled_at = clock_timestamp(),
           -- What the client answered for good is not carried again until it
           -- changes; what waits is carried again next run.
           last_digest = case when r.outcome = 'waiting' then l.last_digest else coalesce(r.digest, l.last_digest) end,
           last_pushed_at = case when r.outcome in ('applied', 'replay') then clock_timestamp() else l.last_pushed_at end
     where l.incident_id = r.id and l.code = d.code;
    case r.outcome
      when 'applied', 'replay' then v_applied := v_applied + 1;
      when 'waiting' then v_waiting := v_waiting + 1;
      else v_failed := v_failed + 1;
    end case;
  end loop;

  for r in
    select (x.a ->> 'id')::uuid as id, x.a ->> 'outcome' as outcome,
           left(coalesce(btrim(x.a ->> 'detail'), ''), 2000) as said, x.a ->> 'digest' as digest
      from jsonb_array_elements(v_windows) with ordinality x(a, o)
     order by x.o
  loop
    select exists (select 1 from erp_meta.maintenance_window_deployment l where l.window_id = r.id and l.code = d.code)
      into v_reach;
    if not v_reach then
      insert into erp_meta.maintenance_window_deployment (window_id, code, reach, named_at)
      select w.id, d.code, 'every_client', now()
        from erp_meta.maintenance_window w
       where w.id = r.id and w.received_at is null
         and (w.every_client or r.outcome in ('applied', 'replay'))
      on conflict do nothing;
      if not found then
        v_left := v_left + 1;
        continue;
      end if;
    end if;
    update erp_meta.maintenance_window_deployment l
       set outcome = case r.outcome when 'refused' then 'failed' else r.outcome end,
           detail = coalesce(nullif(r.said, ''),
                             case r.outcome when 'applied' then 'taken by the client'
                                            when 'replay' then 'the client holds it already'
                                            when 'waiting' then 'the client is not ready for it yet'
                                            else 'refused by the client' end),
           run_id = v_run, settled_at = clock_timestamp(),
           last_digest = case when r.outcome = 'waiting' then l.last_digest else coalesce(r.digest, l.last_digest) end,
           last_pushed_at = case when r.outcome in ('applied', 'replay') then clock_timestamp() else l.last_pushed_at end
     where l.window_id = r.id and l.code = d.code;
    case r.outcome
      when 'applied', 'replay' then v_applied := v_applied + 1;
      when 'waiting' then v_waiting := v_waiting + 1;
      else v_failed := v_failed + 1;
    end case;
  end loop;

  -- When the client says its people were first told: kept once, never moved.
  update erp_meta.incident_deployment l
     set client_told_at = (t.a ->> 'told_at')::timestamptz
    from jsonb_array_elements(v_told) t(a)
   where l.code = d.code and l.incident_id = (t.a ->> 'id')::uuid
     and l.client_told_at is null and t.a ->> 'told_at' is not null;
  get diagnostics v_told_n = row_count;

  -- What the client holds. Each incident or window carried there, in the
  -- thirty days the push carries, that it does not hold at the digest it last
  -- answered is carried again: a client restored to an earlier point, or one
  -- whose answer was lost. One it refused is not: it never held it, and is
  -- not carried again until it changes (20261012060000).
  if v_held is not null then
    update erp_meta.incident_deployment l
       set last_digest = null, outcome = 'waiting',
           detail = 'the client does not hold it as it was carried; it is carried again next run',
           run_id = v_run, settled_at = clock_timestamp()
      from erp_meta.incident i
     where i.id = l.incident_id and l.code = d.code and i.received_at is null
       and l.last_digest is not null and l.outcome is distinct from 'failed'
       and (i.resolved_at is null or i.resolved_at >= now() - interval '30 days')
       and not exists (select 1 from jsonb_array_elements(v_held) h(x)
                        where h.x ->> 'kind' = 'incident' and lower(h.x ->> 'id') = l.incident_id::text
                          and h.x ->> 'digest' = l.last_digest);
    get diagnostics v_cleared = row_count;
    update erp_meta.maintenance_window_deployment l
       set last_digest = null, outcome = 'waiting',
           detail = 'the client does not hold it as it was carried; it is carried again next run',
           run_id = v_run, settled_at = clock_timestamp()
      from erp_meta.maintenance_window w
     where w.id = l.window_id and l.code = d.code and w.received_at is null
       and l.last_digest is not null and l.outcome is distinct from 'failed'
       and (w.ends_at >= now() - interval '30 days' or w.cancelled_at >= now() - interval '30 days')
       and not exists (select 1 from jsonb_array_elements(v_held) h(x)
                        where h.x ->> 'kind' = 'window' and lower(h.x ->> 'id') = l.window_id::text
                          and h.x ->> 'digest' = l.last_digest);
    get diagnostics v_n = row_count;
    v_cleared := v_cleared + v_n;
    insert into erp_meta.incident_held_check (code, checked_at, run_id, held, cleared)
    values (d.code, clock_timestamp(), v_run, jsonb_array_length(v_held), v_cleared)
    on conflict (code) do update
      set checked_at = excluded.checked_at, run_id = excluded.run_id, held = excluded.held,
          cleared = excluded.cleared;
  end if;

  return jsonb_build_object('code', d.code, 'run', v_run, 'applied', v_applied, 'waiting', v_waiting,
                            'failed', v_failed, 'left', v_left, 'told', v_told_n,
                            'held_checked', v_held is not null, 'cleared', v_cleared);
end;
$$;

revoke all on function erp_meta.settle_incident_pushes(text, text, jsonb) from public, anon, authenticated, service_role;

comment on function erp_meta.settle_incident_pushes(text, text, jsonb) is
  'Records on the control plane what a client deployment answered to its incidents and windows, '
  'erp_meta.apply_pushed_incidents''s answer as returned, with the run that carried them: each incident or window '
  'reached as every client is a row of erp_meta.incident_deployment or maintenance_window_deployment from when it was '
  'handed out, and one taken or held by the client without a row becomes one, and stays one; applied and replay '
  'record the digest '
  'and when it was held, refused is failed with the client''s words and not carried again until it changes, waiting '
  'is carried again next run; and the first time the client says its people were told is kept as client_told_at. '
  'One that reaches the deployment no way is left. Given held, what the client holds [{kind, id, digest}]: each row '
  'of this deployment in the thirty days carried, not failed, whose digest the client does not hold is cleared and '
  'carried again next run (waiting), and the check is kept in erp_meta.incident_held_check. Answers {code, run, '
  'applied, waiting, failed, left, told, held_checked, cleared}; refuses CLOVEERP_PUSH_SETTLE_UNREADABLE only for '
  'answers it cannot read. Trusted build role only (20261012060000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. What changes for a client wakes the sweep
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.wake_the_sweep_for(p_incident_id uuid, p_window_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_tx text := pg_catalog.pg_current_xact_id()::text;
begin
  -- Only for what a client deployment that is up is reached by, and once in a
  -- transaction however many rows a door writes. Never raises: a sweep not
  -- woken starts on its ten-minute schedule (20261012060000).
  if not (erp_meta.incident_reaches_a_client(p_incident_id) or erp_meta.window_reaches_a_client(p_window_id)) then
    return 'not woken: it reaches no client deployment that is up';
  end if;
  if coalesce(current_setting('erp.incident_sweep_woken', true), '') = v_tx then
    return 'woken already in this transaction';
  end if;
  perform set_config('erp.incident_sweep_woken', v_tx, true);
  return erp_meta.wake_the_sweep();
exception when others then
  return 'not woken: ' || left(sqlerrm, 300);
end;
$$;

revoke all on function erp_meta.wake_the_sweep_for(uuid, uuid) from public, anon, authenticated, service_role;

comment on function erp_meta.wake_the_sweep_for(uuid, uuid) is
  'Called after a change to an incident or maintenance window (erp_meta.incident_change_wakes_the_sweep): when it '
  'reaches a client deployment that is up, wakes the sweep (erp_meta.wake_the_sweep()), once in a transaction, so '
  'the fleet''s push carries it within minutes. Says what it did and never raises. Plain; called only by that '
  'trigger, which runs as its owner (20261012060000).';

-- On the tables the doors write, not in the doors: every writer is covered,
-- a provider's feed and the console alike, and the wake is reached by no
-- session role (a door's callees are granted to the signed-in caller,
-- erp.invoker_reach_report(); a trigger function that runs as its owner is
-- not), as erp_meta.fleet_request_wakes_the_sweep is (20261012060000).
create or replace function erp_meta.incident_change_wakes_the_sweep()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb := to_jsonb(new);
begin
  perform erp_meta.wake_the_sweep_for(
    case when tg_table_name = 'incident' then (v_row ->> 'id')::uuid else (v_row ->> 'incident_id')::uuid end,
    case when tg_table_name = 'maintenance_window' then (v_row ->> 'id')::uuid else (v_row ->> 'window_id')::uuid end);
  return null;
exception when others then
  -- Never the reason a change is refused: the sweep's schedule carries it.
  raise notice 'the sweep was not woken for %: %', tg_table_name, left(sqlerrm, 300);
  return null;
end;
$$;

revoke all on function erp_meta.incident_change_wakes_the_sweep() from public, anon, authenticated, service_role;

comment on function erp_meta.incident_change_wakes_the_sweep() is
  'After a change to an incident, its updates, disclosures or review, a maintenance window, or a client deployment '
  'named for either, wakes the sweep through erp_meta.wake_the_sweep_for when a client deployment that is up is '
  'reached, so the fleet''s push carries it within minutes. Runs as its owner, so the wake is reached by no session '
  'role; never raises (20261012060000).';

drop trigger if exists t_incident_wakes_the_sweep on erp_meta.incident;
create trigger t_incident_wakes_the_sweep
  after insert or update on erp_meta.incident
  for each row when (new.received_at is null)
  execute function erp_meta.incident_change_wakes_the_sweep();

drop trigger if exists t_incident_update_wakes_the_sweep on erp_meta.incident_update;
create trigger t_incident_update_wakes_the_sweep
  after insert or update on erp_meta.incident_update
  for each row execute function erp_meta.incident_change_wakes_the_sweep();

drop trigger if exists t_incident_disclosure_wakes_the_sweep on erp_meta.incident_disclosure;
create trigger t_incident_disclosure_wakes_the_sweep
  after insert or update on erp_meta.incident_disclosure
  for each row execute function erp_meta.incident_change_wakes_the_sweep();

drop trigger if exists t_incident_review_wakes_the_sweep on erp_meta.incident_review;
create trigger t_incident_review_wakes_the_sweep
  after insert or update on erp_meta.incident_review
  for each row execute function erp_meta.incident_change_wakes_the_sweep();

-- Named, not reached as every client: the push's own settle never wakes the
-- sweep it runs in.
drop trigger if exists t_incident_deployment_wakes_the_sweep on erp_meta.incident_deployment;
create trigger t_incident_deployment_wakes_the_sweep
  after insert on erp_meta.incident_deployment
  for each row when (new.reach = 'named')
  execute function erp_meta.incident_change_wakes_the_sweep();

drop trigger if exists t_maintenance_window_wakes_the_sweep on erp_meta.maintenance_window;
create trigger t_maintenance_window_wakes_the_sweep
  after insert or update on erp_meta.maintenance_window
  for each row when (new.received_at is null)
  execute function erp_meta.incident_change_wakes_the_sweep();

drop trigger if exists t_maintenance_window_deployment_wakes_the_sweep on erp_meta.maintenance_window_deployment;
create trigger t_maintenance_window_deployment_wakes_the_sweep
  after insert on erp_meta.maintenance_window_deployment
  for each row when (new.reach = 'named')
  execute function erp_meta.incident_change_wakes_the_sweep();

-- ─────────────────────────────────────────────────────────────────────────────
-- The routines' standing
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp_meta', 'incident_change_wakes_the_sweep',
   'Trigger function on erp_meta.incident, incident_update, incident_disclosure, incident_review, '
   'incident_deployment, maintenance_window and maintenance_window_deployment. Runs as its owner so that '
   'erp_meta.wake_the_sweep, which reads the vault''s token, is reached by no session role; asks only whether the '
   'row reaches a client deployment that is up, wakes the sweep once a transaction, and never raises.'),
  ('erp', 'declare_incident',
   'Writes erp_meta.incident, which is platform-internal; gated by erp_meta.require_platform(operator), then '
   'erp.require_not_client(): the control plane declares, and a client is carried the incident.'),
  ('erp', 'announce_maintenance',
   'Writes erp_meta.maintenance_window on behalf of platform staff; gated by erp_meta.require_platform(operator) on '
   'its first line, then erp.require_not_client(). Made DEFINER by 20260902121003.'),
  ('erp', 'name_affected_organisations',
   'Writes erp_meta.incident_tenant and erp_meta.incident_deployment on behalf of platform staff, through '
   'erp_meta.name_who_an_incident_reached; gated by erp_meta.require_platform(operator) on its first line, then '
   'erp.require_not_client(). Made DEFINER by 20260902121003.'),
  ('erp', 'flag_security_incident',
   'Writes erp_meta.incident on behalf of platform staff; gated by erp_meta.require_platform(operator) on its first '
   'line, then erp.require_not_client(). Made DEFINER by 20260902121003.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- The words
-- ─────────────────────────────────────────────────────────────────────────────

-- The banner says a copy received from the control plane affects this
-- service, not every organisation; a tenant can rename it as any other.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.en), v.locale, v.value,
       'A screen string, rendered through ui(). Who a received incident affects on the service banner '
       '(20261012060000).'
  from (values
    ('This service', 'en', 'This service'),
    ('This service', 'de', 'Dieser Dienst')
  ) as v(en, locale, value)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

-- One database plays both sides: the control plane names and hands out, its
-- rows are put aside while the same database, marked a client, takes what was
-- handed out, and they are put back for the control plane to settle what the
-- client answered.
create or replace function erp_test.incidents_reach_every_client_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 28;
  -- The register's own word, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired  constant text := 'retired';
  c_suite    constant text := 'incidents_reach_every_client_suite';
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_step     text := 'marking the control plane';
  v_state    text;
  v_kind     text := erp.deployment_kind();
  v_origin   jsonb := (select s.value from erp_meta.platform_setting s where s.key = 'deployment.app_origin');
  op         uuid := gen_random_uuid();
  su         uuid := gen_random_uuid();
  ad         uuid := gen_random_uuid();
  v_op       text;
  v_su       text;
  v_dA       text;
  v_dB       text;
  v_dR       text;
  v_dN       text;
  v_dC       text;
  v_bAddr    text;
  v_ocode    text;
  v_kcode    text;
  v_i1       text;
  v_i2       text;
  v_i3       text;
  v_i4       text;
  v_l1       text;
  v_l2       text;
  v_i5       text;
  v_i6       text;
  v_i7       text;
  v_i8       text;
  v_i9       text;
  v_w1       text;
  v_w2       text;
  v_w3       text;
  v_w4       text;
  v_dep      text;
  v_id1      uuid;
  v_id2      uuid;
  v_id3      uuid;
  v_id4      uuid;
  v_depid    uuid;
  v_lid      uuid;
  v_lid2     uuid;
  v_id5      uuid;
  v_sid      uuid;
  v_wid4     uuid;
  v_wid1     uuid;
  v_wid2     uuid;
  v_wid3     uuid;
  v_ids      uuid[];
  v_wids     uuid[];
  v_org      uuid;
  v_client   uuid;
  rk         record;
  ro         record;
  v_saved    jsonb;
  v_dueA     jsonb;
  v_dueB     jsonb;
  v_dueN     jsonb;
  v_dueA2    jsonb;
  v_dueA3    jsonb;
  v_dueB3    jsonb;
  v_dueA4    jsonb;
  v_dueB5    jsonb;
  v_dueC     jsonb;
  v_dueC5    jsonb;
  v_dueX     jsonb;
  v_dueY     jsonb;
  v_dueZ     jsonb;
  v_push3    jsonb;
  v_push4    jsonb;
  v_p1       jsonb;
  v_ans      jsonb;
  v_ans1     jsonb;
  v_ans1b    jsonb;
  v_ans2     jsonb;
  v_ans3     jsonb;
  v_ans4     jsonb;
  v_ans5     jsonb;
  v_ans6     jsonb;
  v_ans7     jsonb;
  v_ans8     jsonb;
  v_ansH     jsonb;
  v_ansH2    jsonb;
  v_res      jsonb;
  v_res2     jsonb;
  v_res3     jsonb;
  v_res4     jsonb;
  v_json     jsonb;
  v_json2    jsonb;
  v_json3    jsonb;
  v_at1      timestamptz;
  v_recv     timestamptz;
  v_got      text;
  v_got2     text;
  v_got3     text;
  v_got4     text;
  v_bad      text;
  v_n        integer;
  v_n2       integer;
  v_n3       integer;
  v_n4       integer;
  v_n5       integer;
  v_n6       integer;
begin
  begin
    v_op := 'op@zzirc-' || v_tag || '.test';
    v_su := 'su@zzirc-' || v_tag || '.test';
    v_dA := 'zzira-' || v_tag;
    v_dB := 'zzirb-' || v_tag;
    v_dR := 'zzirr-' || v_tag;
    v_dN := 'zzirn-' || v_tag;
    v_dC := 'zzird-' || v_tag;
    v_bAddr := 'zzirx-' || v_tag;
    v_ocode := 'zziro-' || v_tag;
    v_kcode := 'zzirk-' || v_tag;
    v_i1 := 'zziri1-' || v_tag;
    v_i2 := 'zziri2-' || v_tag;
    v_i3 := 'zziri3-' || v_tag;
    v_i4 := 'zziri4-' || v_tag;
    v_l1 := 'zzirl1-' || v_tag;
    v_l2 := 'zzirl2-' || v_tag;
    v_i5 := 'zziri5e-' || v_tag;
    v_i6 := 'zziri6n-' || v_tag;
    v_i7 := 'zziri7e-' || v_tag;
    v_i8 := 'zziri8x-' || v_tag;
    v_i9 := 'zziri9s-' || v_tag;
    v_w1 := 'zzirw1-' || v_tag;
    v_w2 := 'zzirw2-' || v_tag;
    v_w3 := 'zzirw3-' || v_tag;
    v_w4 := 'zzirw4-' || v_tag;

    -- The control plane's marker, undone at the end with everything else.
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, c_suite);

    -- Staff, an organisation here, the organisation a client holds, and four
    -- client deployments: one live, one built and moved to another address,
    -- one retired, one still being built.
    v_step := 'standing up the control plane';
    insert into auth.users (id, email) values (op, v_op), (su, v_su), (ad, 'admin@' || v_kcode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_op, op, 'Reach Suite Operator', 'operator'), (v_su, su, 'Reach Suite Support', 'support');
    select * into ro from erp.provision_tenant(v_ocode, 'Omicron Foods Ltd', 'admin@' || v_ocode || '.test', 'Omicron Admin');
    v_org := ro.tenant_id;
    select * into rk from erp.provision_tenant(v_kcode, 'Kappa Client Ltd', 'admin@' || v_kcode || '.test', 'Kappa Admin');
    v_client := rk.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    perform erp.claim_invitation(rk.admin_token);
    insert into erp_meta.deployment (code, client_name, status, note) values
      (v_dA, 'Alpha Client Ltd', 'live', c_suite),
      (v_dB, 'Beta Client Ltd', 'built', c_suite),
      (v_dR, 'Gone Client Ltd', c_retired, c_suite),
      (v_dN, 'New Client Ltd', 'building', c_suite);
    update erp_meta.deployment d set address = v_bAddr where d.code = v_dB;
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);

    -- ── 1. One list names organisations here and client deployments ───────
    v_step := 'naming who an incident reached';
    v_id1 := public.erp_platform_declare_incident(v_i1, 'sev2', 'Allocation failing for some clients',
               'A. Commander', 'B. Comms', 'C. Scribe', false, 'Allocation, for those named', false,
               array['allocation'], array[v_ocode, v_dA, v_bAddr], 30);
    begin
      perform erp.name_affected_organisations(v_i1, array[v_dR]);
      v_got := 'a retired deployment was named';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp.name_affected_organisations(v_i1, array['zzirz-' || v_tag]);
      v_got2 := 'a name nothing holds was named';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_n := erp.name_affected_organisations(v_i1, array[v_dA, v_ocode]);
    v_json := public.erp_platform_incident_organisations(v_i1);
    v_cases := v_cases + 1;
    case_name := 'one list names an organisation here, else a client deployment by its code or its address now, never a retired one, and the console shows both';
    passed := v_got like 'CLOVEERP_UNKNOWN_TENANT: ' || v_dR || ' is not an organisation on this deployment, nor a client deployment in the register that is not retired'
          and v_got2 like 'CLOVEERP_UNKNOWN_TENANT: zzirz-%'
          and v_n = 0
          and (select count(*) from erp_meta.incident_tenant t where t.incident_id = v_id1 and t.tenant_id = v_org) = 1
          and (select array_agg(x.code order by x.code) from erp_meta.incident_deployment x where x.incident_id = v_id1)
              = array[v_dA, v_dB]
          and not exists (select 1 from erp_meta.incident_deployment x
                           where x.incident_id = v_id1 and (x.reach <> 'named' or x.named_by <> v_op or x.outcome is not null))
          and jsonb_array_length(v_json) = 3
          and v_json -> 0 ->> 'kind' = 'organisation' and v_json -> 0 ->> 'tenant_code' = v_ocode
          and v_json -> 1 ->> 'kind' = 'deployment' and v_json -> 1 ->> 'deployment_code' = v_dA
          and v_json -> 2 ->> 'deployment_code' = v_dB and v_json -> 2 ->> 'address' = v_bAddr
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.incident_scoped' and a.target = v_i1
                         and a.detail -> 'deployments' = jsonb_build_array(v_dA, v_dB)
                         and a.detail -> 'organisations' = jsonb_build_array(v_ocode));
    detail := left(v_got, 70) || ' / ' || left(v_got2, 50) || ' / ' || left(v_json::text, 120);
    return next;

    -- ── 2. Every client, and a provider's outage ─────────────────────────────
    v_step := 'reaching every client';
    v_id2 := public.erp_platform_declare_incident(v_i2, 'sev3', 'Order intake slow for every client',
               'A. Commander', 'B. Comms', 'C. Scribe', false, null, null, array['order_intake'], null, null, true);
    v_wid1 := public.erp_platform_announce_maintenance(v_w1, 'Database upgrade', 'Read-only for an hour',
                now() + interval '3 days', now() + interval '3 days 1 hour', false, null, false, null, true);
    v_wid2 := public.erp_platform_announce_maintenance(v_w2, 'Index rebuild for one client', null,
                now() + interval '4 days', now() + interval '4 days 1 hour', false, array[v_dA]);
    begin
      perform public.erp_platform_announce_maintenance('zzirw0-' || v_tag, 'For nobody', null,
                now() + interval '3 days', now() + interval '3 days 1 hour', false, null, false, null, false);
      v_got := 'a window for nobody was announced';
    exception when others then
      v_got := sqlerrm;
    end;
    -- The provider's feed is read by the sweep, which acts for no organisation.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    v_res := erp.record_dependency_status('resend', 'major', 'Delivery delays', '{}'::jsonb, c_suite);
    v_dep := v_res ->> 'declared';
    v_depid := (select i.id from erp_meta.incident i where i.code = v_dep);
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    v_cases := v_cases + 1;
    case_name := 'every client is its own flag at declaring and announcing, a window for every client names nobody here, and a provider''s outage that reaches every organisation reaches every client';
    passed := (select i.every_client and i.affects_all_tenants is null from erp_meta.incident i where i.id = v_id2)
          and not exists (select 1 from erp_meta.incident_deployment x where x.incident_id = v_id2)
          and (select w.every_client and not w.affects_all_tenants from erp_meta.maintenance_window w where w.id = v_wid1)
          and not exists (select 1 from erp_meta.maintenance_window_tenant t where t.window_id in (v_wid1, v_wid2))
          and (select array_agg(x.code) from erp_meta.maintenance_window_deployment x where x.window_id = v_wid2)
              = array[v_dA]
          and v_got like 'CLOVEERP_MAINTENANCE_AFFECTS_NOBODY%'
          and (select i.every_client and i.affects_all_tenants and i.origin_dependency_code = 'resend'
                 from erp_meta.incident i where i.id = v_depid)
          and erp_meta.incident_reaches_a_client(v_id2) and erp_meta.incident_reaches_a_client(v_depid)
          and erp_meta.window_reaches_a_client(v_wid1)
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.incident_declared' and a.target = v_i2
                         and (a.detail ->> 'every_client')::boolean)
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.maintenance_announced' and a.target = v_w2
                         and a.detail -> 'deployments' = jsonb_build_array(v_dA));
    detail := coalesce(v_dep, 'no provider incident') || ' / ' || left(v_got, 70);
    return next;

    -- ── 3. A window for every organisation here reads no names ──────────────
    v_step := 'announcing for every organisation here, with names';
    v_wid4 := public.erp_platform_announce_maintenance(v_w4, 'Certificate renewal', null,
                now() + interval '6 days', now() + interval '6 days 1 hour', true,
                array['zzirz-' || v_tag, v_dA, v_ocode]);
    v_cases := v_cases + 1;
    case_name := 'a window for every organisation here reads no names, as it never did: one nothing holds is not refused, and it names neither an organisation nor a client deployment';
    passed := (select w.affects_all_tenants and not w.every_client from erp_meta.maintenance_window w where w.id = v_wid4)
          and not exists (select 1 from erp_meta.maintenance_window_tenant t where t.window_id = v_wid4)
          and not exists (select 1 from erp_meta.maintenance_window_deployment x where x.window_id = v_wid4)
          and not erp_meta.window_reaches_a_client(v_wid4);
    detail := coalesce('announced ' || v_w4, 'not announced');
    return next;

    -- ── 4. What each client is owed ──────────────────────────────────────────
    v_step := 'handing out what each client is owed';
    perform erp.flag_security_incident(v_i1);
    perform erp.record_disclosure(v_i1, 'security_disclosure_to_organisation',
                                  'This note stays on the control plane: ' || v_tag);
    perform erp.post_incident_update(v_i1, 'Rolling back the allocation resolver now.');
    perform erp.add_incident_action(v_i1, 'Add a guard to the allocation resolver', 'D. Developer', current_date + 7);
    perform erp.assemble_incident_review(v_i1);
    v_dueA := erp_meta.incident_pushes_due(v_dA);
    v_dueB := erp_meta.incident_pushes_due(v_dB);
    v_dueN := erp_meta.incident_pushes_due(v_dN);
    v_p1 := (select x -> 'payload' from jsonb_array_elements(v_dueA -> 'incidents') x where x ->> 'id' = v_id1::text);
    -- What was handed out as every client's, before any answer: for case 9.
    v_n5 := (select count(*) from erp_meta.incident_deployment x
              where x.code in (v_dA, v_dB) and x.incident_id in (v_id2, v_depid)
                and x.reach = 'every_client' and x.named_by is null and x.outcome is null
                and x.last_digest is null and x.last_pushed_at is null)
          + (select count(*) from erp_meta.maintenance_window_deployment x
              where x.code in (v_dA, v_dB) and x.window_id = v_wid1
                and x.reach = 'every_client' and x.outcome is null and x.last_digest is null);
    v_cases := v_cases + 1;
    case_name := 'each client is owed what reaches it, a client not up nothing, and an incident is carried with its disclosures but not their note, and its shared review as the four parts history reads; a client never asked what it holds is asked';
    passed := (select array_agg(x ->> 'id' order by x ->> 'id') from jsonb_array_elements(v_dueA -> 'incidents') x)
              = (select array_agg(u::text order by u::text) from unnest(array[v_id1, v_id2, v_depid]) u)
          and (select array_agg(x ->> 'id' order by x ->> 'id') from jsonb_array_elements(v_dueA -> 'windows') x)
              = (select array_agg(u::text order by u::text) from unnest(array[v_wid1, v_wid2]) u)
          and (select array_agg(x ->> 'id' order by x ->> 'id') from jsonb_array_elements(v_dueB -> 'incidents') x)
              = (select array_agg(u::text order by u::text) from unnest(array[v_id1, v_id2, v_depid]) u)
          and (select array_agg(x ->> 'id') from jsonb_array_elements(v_dueB -> 'windows') x) = array[v_wid1::text]
          and not (v_dueN ->> 'up')::boolean
          and jsonb_array_length(v_dueN -> 'incidents') = 0 and jsonb_array_length(v_dueN -> 'windows') = 0
          and not exists (select 1 from jsonb_array_elements((v_dueA -> 'incidents') || (v_dueA -> 'windows')) x
                           where x ->> 'digest' <> md5((x -> 'payload')::text))
          and not (v_p1 ? 'declared_by') and not (v_p1 ? 'review_url') and not (v_p1 ? 'organisations')
          and jsonb_array_length(v_p1 -> 'components') = 1 and jsonb_array_length(v_p1 -> 'updates') = 1
          and jsonb_array_length(v_p1 -> 'disclosures') = 3
          and not exists (select 1 from jsonb_array_elements(v_p1 -> 'disclosures') s where s ? 'note')
          and exists (select 1 from jsonb_array_elements(v_p1 -> 'disclosures') s
                       where s ->> 'obligation_code' = 'security_disclosure_to_organisation'
                         and s ->> 'notified_by' = 'the platform' and s ->> 'notified_at' is not null)
          and (select array_agg(k order by k) from jsonb_object_keys(v_p1 -> 'review' -> 'document') k)
              = array['actions', 'duration_minutes', 'timeline', 'updates_promised']
          and jsonb_array_length(v_p1 -> 'review' -> 'document' -> 'timeline') = 1
          and not exists (select 1 from jsonb_array_elements(v_p1 -> 'review' -> 'document' -> 'timeline') t
                           where t ? 'posted_by')
          and (select array_agg(k order by k)
                 from jsonb_array_elements(v_p1 -> 'review' -> 'document' -> 'actions') a, jsonb_object_keys(a) k)
              = array['description', 'done_at']
          and strpos(v_dueA::text, 'This note stays on the control plane') = 0
          and strpos(v_dueA::text, v_ocode) = 0
          and jsonb_array_length(v_dueA -> 'told_of') = 0
          and (v_dueA ->> 'check_held')::boolean and (v_dueB ->> 'check_held')::boolean
          and not (v_dueN ->> 'check_held')::boolean;
    detail := format('%s owed %s incident(s) and %s window(s); %s owed %s and %s; %s up: %s',
                     v_dA, jsonb_array_length(v_dueA -> 'incidents'), jsonb_array_length(v_dueA -> 'windows'),
                     v_dB, jsonb_array_length(v_dueB -> 'incidents'), jsonb_array_length(v_dueB -> 'windows'),
                     v_dN, v_dueN ->> 'up');
    return next;

    -- ── 5. No staff address is carried ───────────────────────────────────────
    v_step := 'reading who is named in what is carried';
    v_cases := v_cases + 1;
    case_name := 'no staff address is carried to a client: who posted an update, recorded a disclosure or announced a window is the platform, while the control plane keeps who it was';
    passed := strpos(v_dueA::text, v_op) = 0 and strpos(v_dueB::text, v_op) = 0
          and strpos(v_dueA::text, '@zzirc-') = 0
          and not exists (select 1
                            from jsonb_array_elements(v_dueA -> 'incidents') x,
                                 jsonb_array_elements(x -> 'payload' -> 'updates') u
                           where u ->> 'posted_by' is distinct from 'the platform')
          and (select count(*) from jsonb_array_elements(v_p1 -> 'updates') u where u ->> 'posted_by' = 'the platform') = 1
          and (select count(*) from jsonb_array_elements(v_p1 -> 'disclosures') s
                where s ->> 'notified_by' = 'the platform') = 1
          and not exists (select 1 from jsonb_array_elements(v_p1 -> 'disclosures') s
                           where s ->> 'notified_at' is null and jsonb_typeof(s -> 'notified_by') <> 'null')
          and not exists (select 1 from jsonb_array_elements(v_dueA -> 'windows') x
                           where x -> 'payload' ->> 'announced_by' is distinct from 'the platform')
          and (select u.posted_by from erp_meta.incident_update u where u.incident_id = v_id1) = v_op
          and (select w.announced_by from erp_meta.maintenance_window w where w.id = v_wid1) = v_op;
    detail := format('%s staff address(es) in what %s is owed',
                     (length(v_dueA::text) - length(replace(v_dueA::text, v_op, ''))) / length(v_op), v_dA);
    return next;

    -- ── 6. A shared review's timeline is carried once ────────────────────────
    v_step := 'reading the review carried';
    -- An entry the review read that is no update of the incident is carried
    -- as it reads, without who posted it; put back after.
    begin
      update erp_meta.incident_review r
         set document = jsonb_set(r.document, '{timeline}',
                          (r.document -> 'timeline') || jsonb_build_array(jsonb_build_object(
                            'posted_at', now() - interval '1 hour', 'body', 'A note the review read from elsewhere.',
                            'is_no_change', false, 'posted_by', v_op, 'next_update_at', null)))
       where r.incident_id = v_id1;
      v_json3 := erp_meta.incident_push_payload(v_id1);
      raise exception 'CLOVEERP_SUITE_PUT_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_PUT_BACK' then
        raise;
      end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a shared review''s timeline names each update it read by its id, so an incident''s words are carried once however long it runs, and an entry that is no update is carried as it reads, without who posted it';
    passed := v_p1 -> 'review' -> 'document' -> 'timeline'
              = jsonb_build_array(jsonb_build_object('update_id',
                  (select u.id from erp_meta.incident_update u where u.incident_id = v_id1)))
          and (length(v_p1::text) - length(replace(v_p1::text, 'Rolling back the allocation resolver now.', '')))
              / length('Rolling back the allocation resolver now.') = 1
          and jsonb_array_length(v_json3 -> 'review' -> 'document' -> 'timeline') = 2
          and v_json3 -> 'review' -> 'document' -> 'timeline' -> 0 = v_p1 -> 'review' -> 'document' -> 'timeline' -> 0
          and v_json3 -> 'review' -> 'document' -> 'timeline' -> 1 ->> 'body' = 'A note the review read from elsewhere.'
          and not (v_json3 -> 'review' -> 'document' -> 'timeline' -> 1 ? 'posted_by')
          and strpos(v_json3::text, v_op) = 0;
    detail := left((v_p1 -> 'review' -> 'document' -> 'timeline')::text, 120) || ' / '
              || left((v_json3 -> 'review' -> 'document' -> 'timeline' -> 1)::text, 120);
    return next;

    -- ── 7. Settling what a client answered ───────────────────────────────────
    v_step := 'settling what a client answered';
    v_at1 := now() - interval '1 minute';
    v_ans := jsonb_build_object(
      'incidents', (select jsonb_agg(jsonb_build_object('id', x -> 'id', 'outcome', 'applied', 'detail', 'held as carried',
                                                        'digest', x -> 'digest'))
                      from jsonb_array_elements(v_dueA -> 'incidents') x),
      'windows', (select jsonb_agg(jsonb_build_object('id', x -> 'id', 'outcome', 'applied', 'digest', x -> 'digest'))
                    from jsonb_array_elements(v_dueA -> 'windows') x),
      'told', jsonb_build_array(jsonb_build_object('id', v_id1, 'told_at', v_at1)));
    v_res := erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag, v_ans);
    v_res2 := erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag || '-2',
                jsonb_build_object('told', jsonb_build_array(jsonb_build_object('id', v_id1, 'told_at', now()))));
    -- One it was never carried and does not hold, and one that is no
    -- incident here.
    v_res3 := erp_meta.settle_incident_pushes(v_dN, 'run-' || v_tag,
                jsonb_build_object('incidents', jsonb_build_array(
                  jsonb_build_object('id', v_id1, 'outcome', 'waiting', 'digest', 'not reached'),
                  jsonb_build_object('id', gen_random_uuid(), 'outcome', 'applied', 'digest', 'nothing here'))));
    begin
      perform erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag,
                jsonb_build_object('incidents', jsonb_build_array(jsonb_build_object('id', v_id1, 'outcome', 'maybe'))));
      v_got := 'settled';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.settle_incident_pushes(v_dA, '  ', '{}'::jsonb);
      v_got2 := 'settled';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_dueA2 := erp_meta.incident_pushes_due(v_dA);
    v_cases := v_cases + 1;
    case_name := 'settling records each answer, makes a client reached as every client a row at its first push, keeps when its people were told once, leaves what does not reach it, and refuses what it cannot read';
    passed := v_res ->> 'applied' = '5' and v_res ->> 'left' = '0' and v_res ->> 'told' = '1'
          and v_res2 ->> 'told' = '0' and v_res3 ->> 'left' = '2'
          and (select count(*) from erp_meta.incident_deployment x where x.code = v_dA) = 3
          and (select x.reach = 'every_client' and x.named_by is null and x.outcome = 'applied'
                 from erp_meta.incident_deployment x where x.incident_id = v_id2 and x.code = v_dA)
          and (select x.outcome = 'applied' and x.detail = 'held as carried' and x.run_id = 'run-' || v_tag
                      and x.last_pushed_at is not null and x.client_told_at = v_at1
                      and x.last_digest = (select y ->> 'digest' from jsonb_array_elements(v_dueA -> 'incidents') y
                                            where y ->> 'id' = v_id1::text)
                 from erp_meta.incident_deployment x where x.incident_id = v_id1 and x.code = v_dA)
          and (select count(*) from erp_meta.maintenance_window_deployment x where x.code = v_dA) = 2
          and (select x.reach = 'every_client' and x.detail = 'taken by the client'
                 from erp_meta.maintenance_window_deployment x where x.window_id = v_wid1 and x.code = v_dA)
          and not exists (select 1 from erp_meta.incident_deployment x where x.code = v_dN)
          and jsonb_array_length(v_dueA2 -> 'incidents') = 0 and jsonb_array_length(v_dueA2 -> 'windows') = 0
          and (select array_agg(x #>> '{}' order by x #>> '{}') from jsonb_array_elements(v_dueA2 -> 'told_of') x)
              = (select array_agg(u::text order by u::text) from unnest(array[v_id2, v_depid]) u)
          and v_got = 'CLOVEERP_PUSH_SETTLE_UNREADABLE: what ' || v_dA || ' answered of its incidents and windows is not settled: incident answer 1 says none of applied, replay, waiting or refused'
          and v_got2 like 'CLOVEERP_PUSH_SETTLE_UNREADABLE: % it names no run'
          -- An answer that does not say what the client holds is no check.
          and not (v_res ->> 'held_checked')::boolean and v_res ->> 'cleared' = '0'
          and (v_dueA2 ->> 'check_held')::boolean;
    detail := format('%s / %s / %s / ', v_res, v_res2, v_res3) || left(v_got, 60);
    return next;

    -- ── 8. What changed is carried again ─────────────────────────────────────
    v_step := 'carrying what changed';
    perform erp.post_incident_update(v_i1, 'Rollback complete; allocation is recovering.');
    perform erp.contain_incident(v_i1, 'Allocation, for those named', false, array[v_dB], null);
    perform erp.cancel_maintenance(v_w1, 'The upgrade moves to next month.');
    v_dueA3 := erp_meta.incident_pushes_due(v_dA);
    v_res := erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag || '-3', jsonb_build_object(
               'incidents', (select jsonb_agg(jsonb_build_object('id', x -> 'id', 'outcome', 'waiting',
                                                                 'detail', 'not ready', 'digest', x -> 'digest'))
                               from jsonb_array_elements(v_dueA3 -> 'incidents') x),
               'windows', (select jsonb_agg(jsonb_build_object('id', x -> 'id', 'outcome', 'refused',
                                                               'detail', 'the client refused it', 'digest', x -> 'digest'))
                             from jsonb_array_elements(v_dueA3 -> 'windows') x)));
    v_dueA4 := erp_meta.incident_pushes_due(v_dA);
    -- Every client said no more while the second client was taking it: it
    -- holds it, so it is kept told of it, and the change is carried there.
    perform erp.contain_incident(v_i2, 'Order intake, for some clients', false, null, false);
    v_res2 := erp_meta.settle_incident_pushes(v_dB, 'run-' || v_tag || '-3', jsonb_build_object(
                'incidents', jsonb_build_array(jsonb_build_object(
                  'id', v_id2, 'outcome', 'applied',
                  'digest', (select x ->> 'digest' from jsonb_array_elements(v_dueB -> 'incidents') x
                              where x ->> 'id' = v_id2::text)))));
    v_dueB3 := erp_meta.incident_pushes_due(v_dB);
    -- A client registered after the cancellation and the withdrawal was handed
    -- neither out, and is carried neither.
    insert into erp_meta.deployment (code, client_name, status, note) values (v_dC, 'Gamma Client Ltd', 'built', c_suite);
    v_dueC := erp_meta.incident_pushes_due(v_dC);
    v_cases := v_cases + 1;
    case_name := 'a change is carried again to the clients it reached, a cancellation too, one never handed out to a client is not carried cancelled or withdrawn, what waits is carried again, what was refused is failed with its reason until it changes, and a client that took it as every client keeps it when every client is said no more';
    passed := (select array_agg(x ->> 'id') from jsonb_array_elements(v_dueA3 -> 'incidents') x) = array[v_id1::text]
          and (select array_agg(x ->> 'id') from jsonb_array_elements(v_dueA3 -> 'windows') x) = array[v_wid1::text]
          and (select x -> 'payload' ->> 'cancelled_at' from jsonb_array_elements(v_dueA3 -> 'windows') x) is not null
          and (select x -> 'payload' ->> 'contained_at' from jsonb_array_elements(v_dueA3 -> 'incidents') x) is not null
          and (select jsonb_array_length(x -> 'payload' -> 'updates') from jsonb_array_elements(v_dueA3 -> 'incidents') x) = 2
          and (select array_agg(x ->> 'id') from jsonb_array_elements(v_dueB3 -> 'windows') x) = array[v_wid1::text]
          and (select x -> 'payload' ->> 'cancelled_at' from jsonb_array_elements(v_dueB3 -> 'windows') x) is not null
          and jsonb_array_length(v_dueC -> 'windows') = 0
          and (select array_agg(x ->> 'id') from jsonb_array_elements(v_dueC -> 'incidents') x) = array[v_depid::text]
          and v_res ->> 'waiting' = '1' and v_res ->> 'failed' = '1'
          and (select array_agg(x ->> 'id') from jsonb_array_elements(v_dueA4 -> 'incidents') x) = array[v_id1::text]
          and jsonb_array_length(v_dueA4 -> 'windows') = 0
          and (select x.outcome = 'failed' and x.detail = 'the client refused it'
                 from erp_meta.maintenance_window_deployment x where x.window_id = v_wid1 and x.code = v_dA)
          and (select x.outcome = 'waiting' and x.client_told_at = v_at1
                 from erp_meta.incident_deployment x where x.incident_id = v_id1 and x.code = v_dA)
          and exists (select 1 from erp.incident_communication_report(v_i1) r
                       where r.kind = 'push' and r.reference = v_dA and r.detail like 'waiting: not ready; its people told %')
          and v_res2 ->> 'applied' = '1'
          and (select x.reach = 'every_client' and x.outcome = 'applied'
                 from erp_meta.incident_deployment x where x.incident_id = v_id2 and x.code = v_dB)
          and not (select i.every_client from erp_meta.incident i where i.id = v_id2)
          and exists (select 1 from jsonb_array_elements(v_dueB3 -> 'incidents') x where x ->> 'id' = v_id2::text);
    detail := format('%s / %s / %s incident(s) and %s window(s) owed after', v_res, v_res2,
                     jsonb_array_length(v_dueA4 -> 'incidents'), jsonb_array_length(v_dueA4 -> 'windows'));
    return next;

    -- ── 9. What is handed out as every client's is owed whatever the answer ──
    v_step := 'handing out for every client, the answer lost';
    -- Handed to two clients, never answered, then changed and every client
    -- said no more: both are still owed it; a client never handed it is not.
    v_id5 := public.erp_platform_declare_incident(v_i5, 'sev3', 'Exports slow for every client',
               'A. Commander', 'B. Comms', 'C. Scribe', false, null, null, array['order_intake'], null, null, true);
    v_dueB5 := erp_meta.incident_pushes_due(v_dB);
    v_json := (select to_jsonb(x) from erp_meta.incident_deployment x where x.incident_id = v_id5 and x.code = v_dB);
    perform erp.post_incident_update(v_i5, 'Only exports to one carrier are slow.');
    perform erp.contain_incident(v_i5, 'One carrier''s exports', false, null, false);
    v_dueB3 := erp_meta.incident_pushes_due(v_dB);
    v_dueC5 := erp_meta.incident_pushes_due(v_dC);
    v_cases := v_cases + 1;
    case_name := 'an incident or window handed out as every client''s is a row of the ledger from that moment, before any answer, so a change after it is owed there though the answer was lost, and a client never handed it is not owed it once every client is said no more';
    passed := v_n5 = 6
          and exists (select 1 from jsonb_array_elements(v_dueB5 -> 'incidents') x where x ->> 'id' = v_id5::text)
          and v_json ->> 'reach' = 'every_client' and v_json ->> 'outcome' is null and v_json ->> 'named_by' is null
          and v_json ->> 'last_digest' is null and v_json ->> 'named_at' is not null
          and (select x ->> 'digest' from jsonb_array_elements(v_dueB3 -> 'incidents') x where x ->> 'id' = v_id5::text)
              is distinct from (select x ->> 'digest' from jsonb_array_elements(v_dueB5 -> 'incidents') x
                                 where x ->> 'id' = v_id5::text)
          and exists (select 1 from jsonb_array_elements(v_dueB3 -> 'incidents') x where x ->> 'id' = v_id5::text)
          and not exists (select 1 from jsonb_array_elements(v_dueC5 -> 'incidents') x where x ->> 'id' = v_id5::text)
          and not exists (select 1 from erp_meta.incident_deployment x where x.incident_id = v_id5 and x.code = v_dC)
          and (select x.outcome is null from erp_meta.maintenance_window_deployment x
                where x.window_id = v_wid1 and x.code = v_dB);
    detail := format('%s handed out before any answer; %s owed %s incident(s) after', v_n5, v_dB,
                     jsonb_array_length(v_dueB3 -> 'incidents'));
    return next;

    -- ── 10. The sweep is woken for what reaches a client ─────────────────────
    v_step := 'waking the sweep';
    v_id4 := public.erp_platform_declare_incident(v_i4, 'sev4', 'A matter for this database alone',
               'A. Commander', 'B. Comms', 'C. Scribe');
    v_got := erp_meta.wake_the_sweep_for(v_id1, null);
    v_got2 := erp_meta.wake_the_sweep_for(v_id4, null);
    v_cases := v_cases + 1;
    case_name := 'what reaches a client wakes the sweep once a transaction, through triggers on the tables the doors write, and what reaches none does not';
    passed := v_got = 'woken already in this transaction'
          and v_got2 = 'not woken: it reaches no client deployment that is up'
          and current_setting('erp.incident_sweep_woken', true) = pg_catalog.pg_current_xact_id()::text
          and (select count(*) from pg_catalog.pg_trigger t
                where t.tgfoid = 'erp_meta.incident_change_wakes_the_sweep()'::regprocedure and t.tgenabled <> 'D') = 7
          and (select p.prosecdef from pg_catalog.pg_proc p
                where p.oid = 'erp_meta.incident_change_wakes_the_sweep()'::regprocedure)
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.wake_the_sweep()', 'execute');
    detail := v_got || ' / ' || v_got2;
    return next;

    -- ── 11. A containment for clients only names them ────────────────────────
    v_step := 'containing for client deployments only';
    -- Contained two hours ago for some, still watched: one naming a client
    -- deployment only, one for every client, and one naming nobody at all.
    -- Put back after.
    v_got := null;
    begin
      perform public.erp_platform_declare_incident(v_i6, 'sev3', 'Printing slow for one client only',
                'A. Commander', 'B. Comms', 'C. Scribe', false, null, false, array['printing'], array[v_dA]);
      perform public.erp_platform_declare_incident(v_i7, 'sev3', 'Intake slow for every client',
                'A. Commander', 'B. Comms', 'C. Scribe', false, null, false, array['order_intake'], null, null, true);
      perform public.erp_platform_declare_incident(v_i8, 'sev3', 'Slow for somebody unsaid',
                'A. Commander', 'B. Comms', 'C. Scribe', false, null, false, array['order_intake']);
      perform erp.contain_incident(v_i6, 'One client only, contained', false, null, null);
      perform erp.contain_incident(v_i7, 'Clients only, contained', false, null, null);
      perform erp.contain_incident(v_i8, 'Somebody, contained', false, null, null);
      update erp_meta.incident i
         set contained_at = now() - interval '2 hours', next_update_due_at = now() + interval '1 hour'
       where i.code in (v_i6, v_i7, v_i8);
      select string_agg(f.reference || ': ' || f.finding, '; ' order by f.reference, f.finding) into v_got
        from erp.support_discipline_report() f
       where f.reference in (v_i6, v_i7, v_i8);
      raise exception 'CLOVEERP_SUITE_PUT_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_PUT_BACK' then
        raise;
      end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a containment scoped to some names somebody when it names a client deployment, or reaches every client: no finding an hour on, while one naming nobody at all still is';
    passed := v_got = v_i8 || ': a contained incident is scoped to some organisations and names none';
    detail := coalesce(v_got, 'no finding at all');
    return next;

    -- Two more that a client will hold under codes of its own: an incident
    -- and a window named for it.
    v_step := 'declaring what a client already holds the codes of';
    v_id3 := public.erp_platform_declare_incident(v_i3, 'sev3', 'Printing slow for one client',
               'A. Commander', 'B. Comms', 'C. Scribe', false, null, false, array['printing'], array[v_dA]);
    v_wid3 := public.erp_platform_announce_maintenance(v_w3, 'Printer driver update', null,
                now() + interval '5 days', now() + interval '5 days 1 hour', false, array[v_dA]);
    v_dueX := erp_meta.incident_pushes_due(v_dA);
    v_push3 := jsonb_build_object(
      'incidents', (select jsonb_agg(x) from jsonb_array_elements(v_dueX -> 'incidents') x where x ->> 'id' = v_id3::text),
      'windows', (select jsonb_agg(x) from jsonb_array_elements(v_dueX -> 'windows') x where x ->> 'id' = v_wid3::text));
    -- One naming a component and a severity no release has brought yet.
    v_push4 := jsonb_build_object('incidents', jsonb_build_array(jsonb_build_object(
                 'id', '00000000-0000-4000-8000-' || lpad(v_tag, 12, '0'),
                 'payload', (v_p1 - 'review')
                            || jsonb_build_object('id', '00000000-0000-4000-8000-' || lpad(v_tag, 12, '0'),
                                                  'code', 'zziri5-' || v_tag, 'severity_code', 'zzsev-' || v_tag,
                                                  'components', jsonb_build_array('zzcomp-' || v_tag),
                                                  'updates', '[]'::jsonb, 'disclosures', '[]'::jsonb))));

    -- ── 12. Off a client, and in a form it does not read ─────────────────────
    v_step := 'applying off a client';
    begin
      perform erp_meta.apply_pushed_incidents(v_dueA);
      v_got := 'applied on the control plane';
    exception when others then
      v_got := sqlerrm;
    end;
    update erp_meta.platform_setting s set value = '"demonstration"'::jsonb where s.key = 'deployment.kind';
    begin
      perform erp_meta.apply_pushed_incidents(v_dueA);
      v_got2 := 'applied on the demonstration';
    exception when others then
      v_got2 := sqlerrm;
    end;

    -- The control plane's rows are put aside: from here the same database is
    -- the client's own, and holds none of them until it takes them.
    v_step := 'putting the control plane''s rows aside';
    v_ids := array[v_id1, v_id2, v_id3, v_id4, v_depid, v_id5];
    v_wids := array[v_wid1, v_wid2, v_wid3, v_wid4];
    v_saved := jsonb_build_object(
      'incident', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.incident x where x.id = any (v_ids)),
      'incident_component', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.incident_component x
                              where x.incident_id = any (v_ids)),
      'incident_update', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.incident_update x
                           where x.incident_id = any (v_ids)),
      'incident_disclosure', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.incident_disclosure x
                               where x.incident_id = any (v_ids)),
      'incident_review', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.incident_review x
                           where x.incident_id = any (v_ids)),
      'incident_tenant', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.incident_tenant x
                           where x.incident_id = any (v_ids)),
      'incident_action', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.incident_action x
                           where x.incident_id = any (v_ids)),
      'incident_deployment', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.incident_deployment x
                               where x.incident_id = any (v_ids)),
      'maintenance_window', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from erp_meta.maintenance_window x
                              where x.id = any (v_wids)),
      'maintenance_window_deployment', (select coalesce(jsonb_agg(to_jsonb(x)), '[]')
                                          from erp_meta.maintenance_window_deployment x where x.window_id = any (v_wids)));
    delete from erp_meta.incident x where x.id = any (v_ids);
    delete from erp_meta.maintenance_window x where x.id = any (v_wids);
    update erp_meta.platform_setting s set value = '"client"'::jsonb where s.key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.app_origin', to_jsonb('https://' || v_dA || '.cloveerp.com'), c_suite);

    v_step := 'applying the first push';
    begin
      perform erp_meta.apply_pushed_incidents('[]'::jsonb);
      v_got3 := 'a list was applied';
    exception when others then
      v_got3 := sqlerrm;
    end;
    begin
      perform erp_meta.apply_pushed_incidents(jsonb_build_object('incidents', jsonb_build_array(jsonb_build_object('id', 'x'))));
      v_got4 := 'an incident with no id was applied';
    exception when others then
      v_got4 := sqlerrm;
    end;
    v_ans1 := erp_meta.apply_pushed_incidents(v_dueA);
    v_cases := v_cases + 1;
    case_name := 'off a client nothing is taken and a push not in its form is refused; on a client each incident and window is kept by the control plane''s id as a received copy that reaches its organisation and names nobody, its review''s timeline read back from the updates carried, and posted by the platform';
    passed := v_got like 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the production deployment, not a client''s own%'
          and v_got2 like 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the demonstration deployment, not a client''s own%'
          and v_got3 = 'CLOVEERP_PUSH_MALFORMED: the incidents and windows pushed are not applied: it is not a set of named values'
          and v_got4 = 'CLOVEERP_PUSH_MALFORMED: the incidents and windows pushed are not applied: an incident or window names no id, or carries no payload'
          and (select count(*) from jsonb_array_elements(v_ans1 -> 'incidents') x where x ->> 'outcome' = 'applied') = 3
          and (select count(*) from jsonb_array_elements(v_ans1 -> 'windows') x where x ->> 'outcome' = 'applied') = 2
          and (select count(*) from erp_meta.incident i
                where i.id in (v_id1, v_id2, v_depid) and i.received_at is not null and i.received_digest is not null
                  and i.affects_all_tenants and not i.every_client and i.declared_by is null) = 3
          and (select i.code = v_i1 and i.is_security and i.severity_code = 'sev2' and i.commander = 'A. Commander'
                      and i.next_update_due_at is not null and i.review_completed_at is not null
                 from erp_meta.incident i where i.id = v_id1)
          and not exists (select 1 from erp_meta.incident_tenant t where t.incident_id in (v_id1, v_id2, v_depid))
          and (select count(*) from erp_meta.incident_update u where u.incident_id = v_id1) = 1
          and (select count(*) from erp_meta.incident_component c where c.incident_id = v_id1) = 1
          and (select count(*) from erp_meta.incident_disclosure d where d.incident_id = v_id1 and d.note is null) = 3
          and (select r.assembled_by = 'the platform' and r.is_shared
                      and (select count(*) from jsonb_object_keys(r.document)) = 4
                      and jsonb_array_length(r.document -> 'timeline') = 1
                      and r.document -> 'timeline' -> 0 ->> 'body' = 'Rolling back the allocation resolver now.'
                      and (r.document -> 'timeline' -> 0 ->> 'posted_at')::timestamptz
                          = (select u.posted_at from erp_meta.incident_update u where u.incident_id = v_id1)
                      and not (r.document -> 'timeline' -> 0 ? 'update_id')
                 from erp_meta.incident_review r where r.incident_id = v_id1)
          and (select u.posted_by from erp_meta.incident_update u where u.incident_id = v_id1) = 'the platform'
          and (select count(*) from erp_meta.incident_disclosure d
                where d.incident_id = v_id1 and d.notified_by = 'the platform') = 1
          and (select w.announced_by from erp_meta.maintenance_window w where w.id = v_wid1) = 'the platform'
          and (select count(*) from erp_meta.maintenance_window w
                where w.id in (v_wid1, v_wid2) and w.received_at is not null and w.affects_all_tenants
                  and not w.every_client and w.cancelled_at is null) = 2
          and not exists (select 1 from erp_meta.maintenance_window_tenant t where t.window_id in (v_wid1, v_wid2))
          and (select array_agg(t ->> 'id') from jsonb_array_elements(v_ans1 -> 'told') t
                where jsonb_typeof(t -> 'told_at') = 'null') is not null;
    detail := left(v_got, 60) || ' / ' || left(v_got3, 50) || ' / ' || left(v_ans1::text, 200);
    return next;

    -- ── 13. Held already ─────────────────────────────────────────────────────
    v_step := 'applying the first push again';
    v_recv := (select i.received_at from erp_meta.incident i where i.id = v_id1);
    v_ans1b := erp_meta.apply_pushed_incidents(v_dueA);
    v_cases := v_cases + 1;
    case_name := 'the same push again is a replay of each, and changes nothing';
    passed := (select count(*) from jsonb_array_elements((v_ans1b -> 'incidents') || (v_ans1b -> 'windows')) x
                where x ->> 'outcome' = 'replay' and x ->> 'detail' like 'held already, since %') = 5
          and (select i.received_at from erp_meta.incident i where i.id = v_id1) = v_recv
          and not exists (select 1 from jsonb_array_elements(v_ans1b -> 'incidents') x
                           where x ->> 'digest' <> (select y ->> 'digest' from jsonb_array_elements(v_dueA -> 'incidents') y
                                                     where y ->> 'id' = x ->> 'id'));
    detail := left(v_ans1b::text, 200);
    return next;

    -- ── 14. What the client holds, said every time ───────────────────────────
    v_step := 'saying what the client holds';
    v_ansH := erp_meta.apply_pushed_incidents('{}'::jsonb);
    -- One resolved longer ago than the push carries is not said; put back
    -- after.
    begin
      update erp_meta.incident i
         set declared_at = now() - interval '41 days', created_at = now() - interval '41 days',
             resolved_at = now() - interval '40 days'
       where i.id = v_depid;
      v_ansH2 := erp_meta.apply_pushed_incidents('{}'::jsonb);
      raise exception 'CLOVEERP_SUITE_PUT_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_PUT_BACK' then
        raise;
      end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a client says what it holds in every answer, nothing pushed or not: each received incident and window by its kind, id and the digest it took, and none ended longer ago than the push carries';
    passed := (select array_agg(h.e order by h.e)
                 from (select format('%s %s %s', x ->> 'kind', x ->> 'id', x ->> 'digest') as e
                         from jsonb_array_elements(v_ansH -> 'held') x) h)
              = (select array_agg(x.e order by x.e)
                   from (select format('%s %s %s', 'incident', i.id, i.received_digest) as e
                           from erp_meta.incident i where i.received_at is not null
                         union all
                         select format('%s %s %s', 'window', w.id, w.received_digest)
                           from erp_meta.maintenance_window w where w.received_at is not null) x)
          and jsonb_array_length(v_ansH -> 'held') = 5
          and v_ans1 -> 'held' = v_ansH -> 'held' and v_ans1b -> 'held' = v_ansH -> 'held'
          and (select count(*) from jsonb_array_elements(v_ansH -> 'held') h where h ->> 'kind' = 'window') = 2
          and jsonb_array_length(v_ansH -> 'incidents') = 0 and jsonb_array_length(v_ansH -> 'windows') = 0
          and jsonb_array_length(v_ansH -> 'told') = 0
          and jsonb_array_length(v_ansH2 -> 'held') = 4
          and not exists (select 1 from jsonb_array_elements(v_ansH2 -> 'held') h where h ->> 'id' = v_depid::text);
    detail := left((v_ansH -> 'held')::text, 200);
    return next;

    -- ── 15. A change, after its people were told ─────────────────────────────
    v_step := 'telling the client''s people, then applying what changed';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', v_client::text, true);
    v_res := erp.communicate_incidents();
    v_n := (select count(*) from erp_meta.incident_delivery d where d.incident_id = v_id1 and d.tenant_id = v_client);
    v_ans2 := erp_meta.apply_pushed_incidents(v_dueA3);
    v_n2 := (select count(*) from erp_meta.incident_delivery d where d.incident_id = v_id1 and d.tenant_id = v_client);
    v_res2 := erp.communicate_incidents();
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    v_json := erp.service_notices();
    v_cases := v_cases + 1;
    case_name := 'a newer digest is applied over the copy without losing who was told, its people hear only what is new, and a cancellation carried takes the window off the notices';
    passed := (v_res ->> 'deliveries')::integer >= 4
          and v_n = 2
          and (select x ->> 'outcome' from jsonb_array_elements(v_ans2 -> 'incidents') x where x ->> 'id' = v_id1::text) = 'applied'
          and (select x ->> 'outcome' from jsonb_array_elements(v_ans2 -> 'windows') x where x ->> 'id' = v_wid1::text) = 'applied'
          and v_n2 = v_n
          and (v_res2 ->> 'deliveries')::integer = 1
          and (select count(*) from erp_meta.incident_update u where u.incident_id = v_id1) = 2
          and (select i.contained_at is not null and i.affects_all_tenants from erp_meta.incident i where i.id = v_id1)
          and (select w.cancelled_at is not null from erp_meta.maintenance_window w where w.id = v_wid1)
          and not exists (select 1 from jsonb_array_elements(v_json -> 'maintenance') w where w ->> 'code' = v_w1)
          and exists (select 1 from jsonb_array_elements(v_json -> 'maintenance') w
                       where w ->> 'code' = v_w2 and (w ->> 'received')::boolean);
    detail := format('%s then %s / %s deliveries, %s after', v_res, v_res2, v_n, v_n2);
    return next;

    -- ── 16. A code held for one of its own ───────────────────────────────────
    v_step := 'applying under codes the client holds';
    insert into erp_meta.incident (code, severity_code, title, commander, communications_owner, scribe,
                                   next_update_due_at, declared_by)
    values (v_i3, 'sev3', 'The client''s own incident under the same code', 'A', 'B', 'C', now() + interval '1 day',
            'a client''s own console, before 20261012060000')
    returning id into v_lid;
    insert into erp_meta.maintenance_window (code, title, starts_at, ends_at, announced_by, affects_all_tenants)
    values (v_w3, 'The client''s own window under the same code', now() + interval '5 days',
            now() + interval '5 days 1 hour', 'a client''s own console', true);
    v_ans3 := erp_meta.apply_pushed_incidents(v_push3);
    v_cases := v_cases + 1;
    case_name := 'an incident or window whose code this client holds for one of its own is refused, and its own is untouched';
    passed := (select x ->> 'outcome' = 'refused'
                      and x ->> 'detail' = 'CLOVEERP_PUSHED_CODE_HELD: this deployment holds ' || v_i3 || ' for an incident of its own, so the control plane''s is not taken'
                 from jsonb_array_elements(v_ans3 -> 'incidents') x)
          and (select x ->> 'outcome' = 'refused' and x ->> 'detail' like 'CLOVEERP_PUSHED_CODE_HELD: this deployment holds ' || v_w3 || ' for a maintenance window of its own%'
                 from jsonb_array_elements(v_ans3 -> 'windows') x)
          and not exists (select 1 from erp_meta.incident i where i.id = v_id3)
          and not exists (select 1 from erp_meta.maintenance_window w where w.id = v_wid3)
          and (select i.received_at is null and i.title = 'The client''s own incident under the same code'
                 from erp_meta.incident i where i.id = v_lid);
    detail := left(v_ans3::text, 240);
    return next;

    -- ── 17. Codes this database does not know yet ────────────────────────────
    v_step := 'applying what names codes not known here';
    v_ans4 := erp_meta.apply_pushed_incidents(v_push4);
    v_cases := v_cases + 1;
    case_name := 'an incident naming a severity or component this database does not know yet waits, and nothing of it is kept';
    passed := (select x ->> 'outcome' = 'waiting'
                      and x ->> 'detail' = format('this deployment does not know component zzcomp-%s, severity zzsev-%s yet: it is behind on its release, and holds what it held', v_tag, v_tag)
                 from jsonb_array_elements(v_ans4 -> 'incidents') x)
          and not exists (select 1 from erp_meta.incident i where i.code = 'zziri5-' || v_tag);
    detail := left(v_ans4::text, 240);
    return next;

    -- ── 18. A received copy refuses every write ──────────────────────────────
    v_step := 'writing to received copies';
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    insert into erp_meta.incident_action (incident_id, description, owner, created_by)
    values (v_id1, 'An action nobody here should have tracked', 'Nobody', 'the suite');
    v_bad := null;
    v_n := 0;
    for v_got in
      select x.call from unnest(array[
        format('select erp.post_incident_update(%L, %L)', v_i1, 'An update posted on the client.'),
        format('select erp.contain_incident(%L, %L, true)', v_i2, 'Contained on the client'),
        format('select erp.resolve_incident(%L, %L)', v_i2, 'https://reviews.example/client'),
        format('select erp.record_disclosure(%L, %L, %L)', v_i1, 'security_disclosure_to_authority', 'told'),
        format('select erp.add_incident_action(%L, %L, %L)', v_i1, 'Track something on the client', 'Somebody'),
        format('select erp.complete_incident_action(%L::uuid, %L)',
               (select a.id from erp_meta.incident_action a where a.incident_id = v_id1 limit 1), 'Done on the client'),
        format('select erp.assemble_incident_review(%L)', v_i1),
        format('select erp.cancel_maintenance(%L, %L)', v_w2, 'Cancelled on the client')]) as x(call)
    loop
      begin
        execute v_got;
        v_bad := concat_ws('; ', v_bad, v_got || ' was done');
      exception when others then
        if sqlerrm like 'CLOVEERP_RECEIVED_FROM_THE_CONTROL_PLANE: % was received from the control plane, and %' then
          v_n := v_n + 1;
        else
          v_bad := concat_ws('; ', v_bad, left(sqlerrm, 80));
        end if;
      end;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'every write to a received copy refuses: an update, containment, resolution, disclosure, action added or completed, review, and a window''s cancellation';
    passed := v_n = 8 and v_bad is null
          and (select count(*) from erp_meta.incident_update u where u.incident_id = v_id1) = 2
          and (select i.contained_at is null and i.resolved_at is null from erp_meta.incident i where i.id = v_id2)
          and (select w.cancelled_at is null from erp_meta.maintenance_window w where w.id = v_wid2);
    detail := format('%s of 8 refused', v_n) || coalesce('; ' || v_bad, '');
    return next;

    -- ── 19. A client's own console ───────────────────────────────────────────
    v_step := 'declaring, announcing, naming and flagging on a client';
    v_bad := null;
    v_n := 0;
    for v_got in
      select x.call from unnest(array[
        format('select erp.declare_incident(%L, %L, %L, %L, %L, %L)', 'zziri6-' || v_tag, 'sev3', 'On the client', 'A', 'B', 'C'),
        format('select erp.announce_maintenance(%L, %L, null, now() + interval ''3 days'', now() + interval ''3 days 1 hour'', true)',
               'zzirw6-' || v_tag, 'On the client'),
        format('select erp.name_affected_organisations(%L, array[%L])', v_i3, v_kcode),
        format('select erp.flag_security_incident(%L)', v_i3)]) as x(call)
    loop
      begin
        execute v_got;
        v_bad := concat_ws('; ', v_bad, v_got || ' was done');
      exception when others then
        if sqlerrm like 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a client''s own deployment;%declaring incidents and maintenance%' then
          v_n := v_n + 1;
        else
          v_bad := concat_ws('; ', v_bad, left(sqlerrm, 80));
        end if;
      end;
    end loop;
    -- The rank gate speaks first.
    perform set_config('request.jwt.claims', json_build_object('sub', su)::text, true);
    begin
      perform erp.declare_incident('zziri7-' || v_tag, 'sev3', 'Support declares', 'A', 'B', 'C');
      v_got2 := 'support declared';
    exception when others then
      v_got2 := sqlerrm;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    -- Its own, declared before this migration, is still updated, contained
    -- and resolved here.
    perform erp.post_incident_update(v_i3, 'The client''s own update on its own incident.');
    perform erp.contain_incident(v_i3, 'This client alone', true);
    perform erp.resolve_incident(v_i3);
    v_cases := v_cases + 1;
    case_name := 'on a client declaring, announcing, naming and flagging refuse after the rank gate, and an incident of its own is still updated, contained and resolved';
    passed := v_n = 4 and v_bad is null
          and v_got2 like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'
          and (select i.resolved_at is not null and i.contained_at is not null and i.received_at is null
                 from erp_meta.incident i where i.id = v_lid)
          and (select count(*) from erp_meta.incident_update u where u.incident_id = v_lid) = 2;
    detail := format('%s of 4 refused', v_n) || coalesce('; ' || v_bad, '') || ' / ' || left(v_got2, 60);
    return next;

    -- ── 20. A client's containment of its own names its own organisation ────
    v_step := 'containing an incident of the client''s own, naming its organisation';
    insert into erp_meta.incident (code, severity_code, title, commander, communications_owner, scribe,
                                   next_update_due_at, declared_by)
    values (v_l2, 'sev3', 'The client''s own incident, for its organisation', 'A', 'B', 'C',
            now() + interval '1 day', 'a client''s own console, before 20261012060000')
    returning id into v_lid2;
    begin
      perform erp.name_affected_organisations(v_l2, array[v_kcode]);
      v_got := 'named at the naming door on a client';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp.contain_incident(v_l2, 'Kappa alone', false, array['zzirz-' || v_tag]);
      v_got2 := 'a name nothing holds was named';
    exception when others then
      v_got2 := sqlerrm;
    end;
    perform erp.contain_incident(v_l2, 'Kappa alone', false, array[v_kcode]);
    v_cases := v_cases + 1;
    case_name := 'on a client the naming door still refuses, while containing an incident of its own may name its own organisation, and a name nothing holds is still refused';
    passed := v_got like 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a client''s own deployment%'
          and v_got2 like 'CLOVEERP_UNKNOWN_TENANT: zzirz-%'
          and (select i.contained_at is not null and not i.affects_all_tenants and i.scope = 'Kappa alone'
                 from erp_meta.incident i where i.id = v_lid2)
          and (select array_agg(t.tenant_code) from erp_meta.incident_tenant t where t.incident_id = v_lid2)
              = array[v_kcode]
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.incident_scoped' and a.target = v_l2
                         and a.detail -> 'organisations' = jsonb_build_array(v_kcode))
          and strpos((select p.prosrc from pg_catalog.pg_proc p
                       where p.oid = 'erp_meta.name_who_an_incident_reached(erp_meta.platform_staff,uuid,text[])'::regprocedure),
                     'require_not_client') = 0;
    detail := left(v_got, 70) || ' / ' || left(v_got2, 60);
    return next;

    -- ── 21. The discipline and the timer leave received copies alone ─────────
    v_step := 'reading the discipline report on a client';
    -- As the control plane might have left them, each against a rule that is
    -- the control plane's duty: the first resolved with its review withheld
    -- and the platform's deadline passed unrecorded; the second quiet for
    -- three days and past its promise with nobody prompted; the provider's a
    -- security incident with no obligations dated, contained two hours ago
    -- for some and naming none.
    update erp_meta.incident i set resolved_at = now(), next_update_due_at = null where i.id = v_id1;
    update erp_meta.incident_review r set is_shared = false where r.incident_id = v_id1;
    update erp_meta.incident_disclosure d set due_at = now() - interval '1 hour', notified_at = null, notified_by = null
     where d.incident_id = v_id1;
    update erp_meta.incident i
       set declared_at = now() - interval '3 days', created_at = now() - interval '3 days',
           next_update_due_at = now() - interval '3 hours'
     where i.id = v_id2;
    update erp_meta.incident i
       set is_security = true, contained_at = now() - interval '2 hours', scope = 'Some organisations',
           affects_all_tenants = false
     where i.id = v_depid;
    insert into erp_meta.incident (code, severity_code, title, commander, communications_owner, scribe,
                                   next_update_due_at, declared_at, created_at, declared_by)
    values (v_l1, 'sev1', 'The client''s own incident, gone quiet', 'A', 'B', 'C', now() - interval '3 hours',
            now() - interval '4 hours', now() - interval '4 hours', 'a client''s own console, before 20261012060000');
    select string_agg(distinct f.finding, '; ') filter (where f.reference in (v_i1, v_i2, v_dep)),
           count(*) filter (where f.reference = v_l1)
      into v_bad, v_n
      from erp.support_discipline_report() f;
    -- The same three, were they this database's own, are seven findings: the
    -- rules are met, and only what they are leaves them out.
    begin
      update erp_meta.incident i set received_at = null, received_digest = null
       where i.id in (v_id1, v_id2, v_depid);
      select count(distinct f.finding) into v_n4
        from erp.support_discipline_report() f where f.reference in (v_i1, v_i2, v_dep);
      raise exception 'CLOVEERP_SUITE_PUT_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_PUT_BACK' then
        raise;
      end if;
    end;
    v_res := erp.prompt_incident_updates();
    v_n2 := (select count(*) from erp_meta.incident_prompt p where p.incident_id in (v_id1, v_id2, v_depid));
    v_n3 := (select count(*) from erp_meta.incident_prompt p join erp_meta.incident i on i.id = p.incident_id
              where i.code = v_l1);
    -- The client's own posts its update, and the client is green.
    perform erp.post_incident_update(v_l1, 'Still looking; the client''s own update.');
    begin
      v_got := erp.assert_support_discipline();
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'on a client a received copy late on its cadence, its promise, its prompt, its disclosures or its review is no finding and is never prompted, while one of its own still is, and the client stays green';
    passed := v_bad is null and v_n4 = 7 and v_n >= 3 and v_n2 = 0 and v_n3 >= 1
          and v_got like 'support: % severity level(s)%';
    detail := format('%s finding(s) were they its own; %s finding(s) on its own, %s prompt(s) for received copies, %s for its own / ',
                     v_n4, v_n, v_n2, v_n3)
              || coalesce(v_bad, 'none on received copies') || ' / ' || left(v_got, 60);
    return next;

    -- ── 22. What its people see, and when they were told ─────────────────────
    v_step := 'reading the banner and history on a client';
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    v_json := erp.service_notices();
    v_json2 := erp.incident_history();
    perform set_config('request.jwt.claims', '', true);
    v_ans5 := erp_meta.apply_pushed_incidents(jsonb_build_object('told_of', jsonb_build_array(v_id1, v_id2, v_lid)));
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    v_cases := v_cases + 1;
    case_name := 'its people see a received incident as received and reaching this service, not every organisation, in the banner and the history, and the client says when they were first told';
    passed := exists (select 1 from jsonb_array_elements(v_json -> 'incidents') e
                       where e ->> 'code' = v_i1 and (e ->> 'received')::boolean
                         and not (e ->> 'affects_all_tenants')::boolean and e ->> 'state' = 'resolved')
          and exists (select 1 from jsonb_array_elements(v_json -> 'incidents') e
                       where e ->> 'code' = v_i2 and (e ->> 'received')::boolean
                         and not (e ->> 'affects_all_tenants')::boolean and e ->> 'next_update_due_at' is not null)
          and exists (select 1 from jsonb_array_elements(v_json -> 'incidents') e
                       where e ->> 'code' = v_i3 and not (e ->> 'received')::boolean
                         and (e ->> 'affects_all_tenants')::boolean)
          and exists (select 1 from jsonb_array_elements(v_json2) e
                       where e ->> 'code' = v_i1 and (e ->> 'received')::boolean
                         and not (e ->> 'affects_all_tenants')::boolean and e ->> 'told_at' is not null)
          and (select count(*) from jsonb_array_elements(v_ans5 -> 'told') t
                where t ->> 'id' in (v_id1::text, v_id2::text) and t ->> 'told_at' is not null) = 2
          and not exists (select 1 from jsonb_array_elements(v_ans5 -> 'told') t where t ->> 'id' = v_lid::text)
          and jsonb_array_length(v_ans5 -> 'incidents') = 0;
    detail := left(v_ans5::text, 200);
    return next;

    -- ── 23. Told is a delivery that reached somebody ─────────────────────────
    v_step := 'telling an organisation nobody has joined';
    -- One more received copy; the organisation here that nobody has joined
    -- is delivered it first, to nobody, then the client's own people are.
    v_sid := ('00000000-0000-4000-8000-' || lpad(v_tag, 12, '9'))::uuid;
    v_ans6 := erp_meta.apply_pushed_incidents(jsonb_build_object('incidents', jsonb_build_array(jsonb_build_object(
                'id', v_sid,
                'payload', (v_p1 - 'review')
                           || jsonb_build_object('id', v_sid, 'code', v_i9, 'is_security', false,
                                                 'updates', '[]'::jsonb, 'disclosures', '[]'::jsonb)))));
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', v_org::text, true);
    v_res := erp.communicate_incidents();
    perform set_config('erp.job_tenant_id', '', true);
    v_ans7 := erp_meta.apply_pushed_incidents(jsonb_build_object('told_of', jsonb_build_array(v_sid)));
    perform set_config('erp.job_tenant_id', v_client::text, true);
    v_res2 := erp.communicate_incidents();
    perform set_config('erp.job_tenant_id', '', true);
    v_ans8 := erp_meta.apply_pushed_incidents(jsonb_build_object('told_of', jsonb_build_array(v_sid)));
    perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
    v_cases := v_cases + 1;
    case_name := 'the client says its people were told only from a delivery that reached somebody: one to an organisation nobody has joined told nobody';
    passed := v_ans6 -> 'incidents' -> 0 ->> 'outcome' = 'applied'
          and exists (select 1 from erp_meta.incident_delivery d
                       where d.incident_id = v_sid and d.tenant_id = v_org and d.recipients = 0)
          and not exists (select 1 from erp_meta.incident_delivery d
                           where d.incident_id = v_sid and d.tenant_id = v_org and d.recipients > 0)
          and (select jsonb_typeof(t -> 'told_at') from jsonb_array_elements(v_ans7 -> 'told') t
                where t ->> 'id' = v_sid::text) = 'null'
          and exists (select 1 from erp_meta.incident_delivery d
                       where d.incident_id = v_sid and d.tenant_id = v_client and d.recipients > 0)
          and (select (t ->> 'told_at')::timestamptz from jsonb_array_elements(v_ans8 -> 'told') t
                where t ->> 'id' = v_sid::text)
              = (select min(d.delivered_at) from erp_meta.incident_delivery d
                  where d.incident_id = v_sid and d.recipients > 0);
    detail := format('%s / %s / %s', v_res, left((v_ans7 -> 'told')::text, 80), left((v_ans8 -> 'told')::text, 80));
    return next;

    -- ── 24. Back on the control plane: the client's own answers settled ─────
    v_step := 'settling the client''s own answers on the control plane';
    delete from erp_meta.incident x where x.code in (v_i1, v_i2, v_i3, v_i4, v_dep, v_l1, v_l2, v_i9);
    delete from erp_meta.maintenance_window x where x.code in (v_w1, v_w2, v_w3);
    delete from erp_meta.platform_setting where key = 'deployment.app_origin';
    update erp_meta.platform_setting s set value = '"production"'::jsonb where s.key = 'deployment.kind';
    insert into erp_meta.incident select * from jsonb_populate_recordset(null::erp_meta.incident, v_saved -> 'incident');
    insert into erp_meta.maintenance_window
    select * from jsonb_populate_recordset(null::erp_meta.maintenance_window, v_saved -> 'maintenance_window');
    insert into erp_meta.incident_component
    select * from jsonb_populate_recordset(null::erp_meta.incident_component, v_saved -> 'incident_component');
    insert into erp_meta.incident_update
    select * from jsonb_populate_recordset(null::erp_meta.incident_update, v_saved -> 'incident_update');
    insert into erp_meta.incident_disclosure
    select * from jsonb_populate_recordset(null::erp_meta.incident_disclosure, v_saved -> 'incident_disclosure');
    insert into erp_meta.incident_review
    select * from jsonb_populate_recordset(null::erp_meta.incident_review, v_saved -> 'incident_review');
    insert into erp_meta.incident_tenant
    select * from jsonb_populate_recordset(null::erp_meta.incident_tenant, v_saved -> 'incident_tenant');
    insert into erp_meta.incident_action
    select * from jsonb_populate_recordset(null::erp_meta.incident_action, v_saved -> 'incident_action');
    insert into erp_meta.incident_deployment
    select * from jsonb_populate_recordset(null::erp_meta.incident_deployment, v_saved -> 'incident_deployment');
    insert into erp_meta.maintenance_window_deployment
    select * from jsonb_populate_recordset(null::erp_meta.maintenance_window_deployment,
                                           v_saved -> 'maintenance_window_deployment');
    v_res := erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag || '-4', v_ans3);
    v_res2 := erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag || '-5',
                jsonb_build_object('told', v_ans5 -> 'told'));
    v_dueX := erp_meta.incident_pushes_due(v_dA);
    begin
      v_got := erp.assert_support_discipline();
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'the control plane settles what the client answered: a code it holds is failed with the client''s words and not carried again until it changes, when its people were told is kept, and the control plane is green';
    passed := v_res ->> 'failed' = '2'
          and (select x.outcome = 'failed' and x.detail like 'CLOVEERP_PUSHED_CODE_HELD: this deployment holds ' || v_i3 || '%'
                 from erp_meta.incident_deployment x where x.incident_id = v_id3 and x.code = v_dA)
          and (select x.outcome = 'failed' and x.detail like 'CLOVEERP_PUSHED_CODE_HELD:%'
                 from erp_meta.maintenance_window_deployment x where x.window_id = v_wid3 and x.code = v_dA)
          and not exists (select 1 from jsonb_array_elements(v_dueX -> 'incidents') x where x ->> 'id' = v_id3::text)
          and not exists (select 1 from jsonb_array_elements(v_dueX -> 'windows') x where x ->> 'id' = v_wid3::text)
          and v_res2 ->> 'told' = '1'
          and (select x.client_told_at is not null from erp_meta.incident_deployment x
                where x.incident_id = v_id2 and x.code = v_dA)
          and (select x.client_told_at = v_at1 from erp_meta.incident_deployment x
                where x.incident_id = v_id1 and x.code = v_dA)
          and v_got like 'support: % severity level(s)%'
          and (select not (x ->> 'every_client')::boolean and jsonb_array_length(x -> 'deployments') = 2
                      and x -> 'deployments' -> 0 ->> 'code' = v_dA
                      and x -> 'deployments' -> 0 ->> 'client_told_at' is not null
                      and x -> 'deployments' -> 1 ->> 'reach' = 'every_client'
                 from jsonb_array_elements(public.erp_platform_incidents()) x where x ->> 'code' = v_i2);
    detail := format('%s / %s / ', v_res, v_res2) || left(v_got, 80);
    return next;

    -- ── 25. What a client no longer holds is carried again ──────────────────
    v_step := 'reading what a client says it holds';
    -- The answer just settled said what the client held: it was asked today.
    v_dueY := erp_meta.incident_pushes_due(v_dA);
    -- As a client restored to an earlier point answers: it holds the window
    -- named for it as it was carried, the provider's incident at an earlier
    -- digest, and neither the second incident nor anything else.
    v_res3 := erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag || '-6', jsonb_build_object(
                'incidents', '[]'::jsonb, 'windows', '[]'::jsonb, 'told', '[]'::jsonb,
                'held', jsonb_build_array(
                  jsonb_build_object('kind', 'window', 'id', v_wid2,
                                     'digest', (select x.last_digest from erp_meta.maintenance_window_deployment x
                                                 where x.window_id = v_wid2 and x.code = v_dA)),
                  jsonb_build_object('kind', 'incident', 'id', v_depid, 'digest', 'an earlier digest'))));
    v_dueX := erp_meta.incident_pushes_due(v_dA);
    -- A day on, an answer that says nothing of what it holds is no check.
    update erp_meta.incident_held_check h set checked_at = now() - interval '25 hours' where h.code = v_dA;
    v_res4 := erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag || '-7', jsonb_build_object('told', '[]'::jsonb));
    v_dueZ := erp_meta.incident_pushes_due(v_dA);
    begin
      perform erp_meta.settle_incident_pushes(v_dA, 'run-' || v_tag || '-8', jsonb_build_object(
                'held', jsonb_build_array(jsonb_build_object('kind', 'trouble', 'id', v_id2))));
      v_got := 'settled';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a client is asked what it holds once a day, and what it does not hold as it was carried, as after a restore, is carried again next run, while one it refused is not, and an answer that says nothing of what it holds clears nothing';
    passed := (v_res ->> 'held_checked')::boolean
          and not (v_dueY ->> 'check_held')::boolean
          and (v_res3 ->> 'held_checked')::boolean and v_res3 ->> 'cleared' = '2'
          and (select x.last_digest is null and x.outcome = 'waiting' and x.run_id = 'run-' || v_tag || '-6'
                      and x.detail = 'the client does not hold it as it was carried; it is carried again next run'
                 from erp_meta.incident_deployment x where x.incident_id = v_depid and x.code = v_dA)
          and (select x.last_digest is null and x.outcome = 'waiting'
                 from erp_meta.incident_deployment x where x.incident_id = v_id2 and x.code = v_dA)
          and (select x.last_digest is not null and x.outcome is distinct from 'waiting'
                 from erp_meta.maintenance_window_deployment x where x.window_id = v_wid2 and x.code = v_dA)
          and exists (select 1 from jsonb_array_elements(v_dueX -> 'incidents') x where x ->> 'id' = v_depid::text)
          and exists (select 1 from jsonb_array_elements(v_dueX -> 'incidents') x where x ->> 'id' = v_id2::text)
          and not exists (select 1 from jsonb_array_elements(v_dueX -> 'incidents') x where x ->> 'id' = v_id3::text)
          and jsonb_array_length(v_dueX -> 'windows') = 0
          and not (v_dueX ->> 'check_held')::boolean
          and (select h.held = 2 and h.cleared = 2 and h.run_id = 'run-' || v_tag || '-6'
                 from erp_meta.incident_held_check h where h.code = v_dA)
          and not (v_res4 ->> 'held_checked')::boolean and v_res4 ->> 'cleared' = '0'
          and (v_dueZ ->> 'check_held')::boolean
          and v_got like 'CLOVEERP_PUSH_SETTLE_UNREADABLE: what ' || v_dA || ' answered of its incidents and windows is not settled: held names %';
    detail := format('%s / %s / ', v_res3, v_res4) || left(v_got, 80);
    return next;

    -- ── 26. Standing ─────────────────────────────────────────────────────────
    v_step := 'reading the routines'' standing';
    select count(*) into v_n
      from pg_catalog.pg_proc p
     where p.oid in ('erp_meta.incident_pushes_due(text)'::regprocedure,
                     'erp_meta.apply_pushed_incidents(jsonb)'::regprocedure,
                     'erp_meta.settle_incident_pushes(text,text,jsonb)'::regprocedure,
                     'erp_meta.incident_push_payload(uuid)'::regprocedure,
                     'erp_meta.maintenance_push_payload(uuid)'::regprocedure,
                     'erp_meta.pushed_value_is(jsonb,text,boolean)'::regprocedure,
                     'erp_meta.wake_the_sweep_for(uuid,uuid)'::regprocedure,
                     'erp_meta.incident_reaches_a_client(uuid)'::regprocedure,
                     'erp_meta.window_reaches_a_client(uuid)'::regprocedure)
       and not p.prosecdef
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('service_role', p.oid, 'execute');
    select count(*) into v_n2
      from pg_catalog.pg_class c
     where c.oid in ('erp_meta.incident_deployment'::regclass, 'erp_meta.maintenance_window_deployment'::regclass,
                     'erp_meta.incident_held_check'::regclass)
       and c.relrowsecurity and c.relforcerowsecurity
       and not pg_catalog.has_table_privilege('anon', c.oid, 'select')
       and not pg_catalog.has_table_privilege('authenticated', c.oid, 'select')
       and exists (select 1 from erp_meta.table_policy t
                    where t.schema_name = 'erp_meta' and t.table_name = c.relname
                      and t.table_class = 'platform_internal');
    select count(*) into v_n3
      from pg_catalog.pg_proc p
     where p.proname in ('erp_platform_declare_incident', 'erp_platform_contain_incident',
                         'erp_platform_announce_maintenance', 'declare_incident', 'contain_incident',
                         'announce_maintenance')
       and p.pronamespace in ('public'::regnamespace, 'erp'::regnamespace)
       and p.proargnames[cardinality(p.proargnames)] = 'p_every_client';
    v_cases := v_cases + 1;
    case_name := 'the push''s routines run as their caller and reach no session role, its three tables are sealed, the wake''s trigger runs as its owner on the allowance, and each door that changed keeps one signature, p_every_client last';
    passed := v_n = 9 and v_n2 = 3 and v_n3 = 6
          and (select count(*) from pg_catalog.pg_proc p
                where p.proname in ('erp_platform_declare_incident', 'erp_platform_contain_incident',
                                    'erp_platform_announce_maintenance', 'declare_incident', 'contain_incident',
                                    'announce_maintenance')
                  and p.pronamespace in ('public'::regnamespace, 'erp'::regnamespace)) = 6
          and exists (select 1 from erp_meta.security_definer_allowance a
                       where a.schema_name = 'erp_meta' and a.function_name = 'incident_change_wakes_the_sweep')
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.incident_change_wakes_the_sweep()', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.incident_change_wakes_the_sweep()', 'execute')
          and not (select p.prosecdef from pg_catalog.pg_proc p
                    where p.oid = 'erp_meta.name_who_an_incident_reached(erp_meta.platform_staff,uuid,text[])'::regprocedure);
    detail := format('%s of 9 trusted, %s of 3 tables, %s of 6 doors with p_every_client last', v_n, v_n2, v_n3);
    return next;

    -- ── 27. The banner's words ───────────────────────────────────────────────
    v_step := 'reading the banner''s words';
    v_cases := v_cases + 1;
    case_name := 'the banner''s words for a received incident, This service, are a screen string in English and German a tenant can rename';
    passed := (select count(*) from erp_ref.resource r
                where r.key = erp_ref.ui_key('This service') and r.locale in ('en', 'de')
                  and btrim(r.value) <> '') = 2;
    detail := coalesce((select string_agg(r.locale || ': ' || r.value, ', ' order by r.locale) from erp_ref.resource r
                         where r.key = erp_ref.ui_key('This service')), 'no row');
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── 28. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the suite leaves nothing behind: no deployment, incident, window, organisation, staff or row of who was reached of its own, and the deployment as it was';
  passed := not exists (select 1 from erp_meta.deployment d where d.code in (v_dA, v_dB, v_dR, v_dN, v_dC))
        and not exists (select 1 from erp_meta.incident i where i.code like 'zziri%-' || v_tag or i.code like 'zzirl%-' || v_tag)
        and not exists (select 1 from erp_meta.maintenance_window w where w.code like 'zzirw%-' || v_tag)
        and not exists (select 1 from erp_meta.incident_deployment x where x.code in (v_dA, v_dB, v_dR, v_dN, v_dC))
        and not exists (select 1 from erp_meta.incident_held_check h where h.code in (v_dA, v_dB, v_dR, v_dN, v_dC))
        and not exists (select 1 from erp.tenant t where t.code in (v_ocode, v_kcode))
        and not exists (select 1 from erp_meta.platform_staff s where s.email in (v_op, v_su))
        and erp.deployment_kind() = v_kind
        and (select s.value from erp_meta.platform_setting s where s.key = 'deployment.app_origin') is not distinct from v_origin;
  detail := format('deployment kind %s, as before', erp.deployment_kind());
  return next;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_INCIDENTS_REACH_EVERY_CLIENT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_incidents_reach_every_client_suite()
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
    from erp_test.incidents_reach_every_client_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_INCIDENTS_REACH_EVERY_CLIENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An incident or maintenance window does not reach the client deployments it should, as it should, or a client does not keep, refuse or show what it received as it should: read the case that failed.';
  end if;
  if v_total <> 28 then
    raise exception 'CLOVEERP_INCIDENTS_REACH_EVERY_CLIENT_SUITE_SHRANK: % case(s), expected 28', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('incidents reach every client: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.incidents_reach_every_client_suite() from public, anon;
revoke all on function erp_test.assert_incidents_reach_every_client_suite() from public, anon;

comment on function erp_test.assert_incidents_reach_every_client_suite() is
  'One list names organisations here and client deployments by code or address, never a retired one, and a window '
  'for every organisation here reads no names; every client is its own flag, and a provider''s outage reaching '
  'every organisation reaches every client; each client is owed what reaches it and changed, with disclosures but '
  'not their note, no staff address, and a shared review as the four parts history reads, its timeline naming the '
  'updates by id; every-client rows are made as they are handed out, so a lost answer loses nothing; settling '
  'records each answer, keeps when people were told, carries changes and cancellations again, retries what waits, '
  'fails what was refused until it changes, and carries again what the client says it no longer holds, asked once a '
  'day; a containment naming client deployments or every client is no finding; what reaches a client wakes the '
  'sweep once a transaction; on a client the copy is kept by id, replayed, updated without losing who was told, '
  'refused under a code the client holds, waits for codes not known yet, refuses every write, is left out of the '
  'discipline and the timer, and reads as received in the banner and history, and every answer says what it holds '
  'and when its people were told by a delivery that reached somebody; declaring, announcing, naming and flagging '
  'refuse there after the rank gate, while containing its own may name its own organisation; the banner''s words '
  'are renameable; and nothing is left behind (20261012060000).';

-- The suites that read the doors, taught them.
do $do$
declare
  r      record;
  v_src  text;
  v_def  text;
begin
  for r in
    select x.sig, x.anchor,
           array_agg(x.old order by x.ord) as olds,
           array_agg(x.new order by x.ord) as news
      from (values
        -- On a client, declaring, announcing, naming and flagging now ask
        -- whether this is a client, after their rank gate; the other doors
        -- stay open to its own incidents.
        ('erp_test.client_keeps_to_its_own_business_suite()', '96389156b6d3aecb112968a76740fa13', 1,
$o$  -- Incidents are a client's own until notices are pushed into clients.
  c_incidents constant text[] := array[
$o$,
$n$  -- The incident doors. Since incidents are pushed into clients, four ask
  -- whether this is a client, after their rank gate; the rest stay open to a
  -- client's own incidents (20261012060000).
  c_incidents_gated constant text[] := array[
    'erp.declare_incident', 'erp.announce_maintenance', 'erp.name_affected_organisations',
    'erp.flag_security_incident'];
  c_incidents constant text[] := array[
$n$),
        ('erp_test.client_keeps_to_its_own_business_suite()', '96389156b6d3aecb112968a76740fa13', 2,
$o$     where n.nspname || '.' || p.proname = any (c_incidents)
       and strpos(p.prosrc, 'erp.require_not_client()') > 0;
$o$,
$n$     where n.nspname || '.' || p.proname = any (c_incidents)
       and not (n.nspname || '.' || p.proname = any (c_incidents_gated))
       and strpos(p.prosrc, 'erp.require_not_client()') > 0;
    select string_agg(x.name, ', ' order by x.name) into v_got2
      from unnest(c_incidents_gated) as x(name)
     where not exists (select 1 from pg_catalog.pg_proc p
                         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                        where n.nspname || '.' || p.proname = x.name
                          and strpos(p.prosrc, 'perform erp.require_not_client();') > 0
                          and strpos(p.prosrc, 'erp.require_not_client()')
                              > strpos(p.prosrc, 'erp_meta.require_platform('));
$n$),
        ('erp_test.client_keeps_to_its_own_business_suite()', '96389156b6d3aecb112968a76740fa13', 3,
$o$       and not (n.nspname || '.' || p.proname = any (c_gated));
    v_cases := v_cases + 1;
    case_name := 'every routine of selling, contracts, invoices and enquiries asks first whether this is a client, after its rank gate, and no incident door does';
    passed := v_bad is null and v_n = 0 and v_n2 = array_length(c_incidents, 1);
    detail := coalesce('not gated as meant: ' || v_bad || '; ', '')
              || coalesce('incidents gated: ' || v_got || '; ', '')
$o$,
$n$       and not (n.nspname || '.' || p.proname = any (c_gated))
       and not (n.nspname || '.' || p.proname = any (c_incidents_gated));
    v_cases := v_cases + 1;
    case_name := 'every routine of selling, contracts, invoices and enquiries asks first whether this is a client, after its rank gate, and of the incident doors only declaring, announcing, naming and flagging do';
    passed := v_bad is null and v_n = 0 and v_n2 = array_length(c_incidents, 1) and v_got2 is null;
    detail := coalesce('not gated as meant: ' || v_bad || '; ', '')
              || coalesce('incidents gated: ' || v_got || '; ', '')
              || coalesce('incident doors not gated after their rank gate: ' || v_got2 || '; ', '')
$n$),
        ('erp_test.client_keeps_to_its_own_business_suite()', '96389156b6d3aecb112968a76740fa13', 4,
$o$    -- ── 7. Incidents are still a client's own ───────────────────────────────
    v_step := 'declaring an incident on a client';
    perform public.erp_platform_declare_incident('zzcli-inc-' || v_tag, 'sev3', 'A client''s own incident',
                                                 'A. Commander', 'B. Comms', 'C. Scribe');
    v_json := public.erp_platform_incidents();
    v_cases := v_cases + 1;
    case_name := 'on a client an incident is still declared and read at its own console';
    passed := exists (select 1 from erp_meta.incident i where i.code = 'zzcli-inc-' || v_tag)
          and strpos(v_json::text, 'zzcli-inc-' || v_tag) > 0;
    detail := case when strpos(v_json::text, 'zzcli-inc-' || v_tag) > 0 then 'declared and listed' else 'not listed' end;
    return next;
$o$,
$n$    -- ── 7. Incidents are declared on the control plane ──────────────────────
    -- And reach a client by the fleet's push. One of its own from before
    -- (20261011100000 left the doors open) is still updated and read at its
    -- own console (20261012060000).
    v_step := 'declaring an incident on a client';
    begin
      perform public.erp_platform_declare_incident('zzcli-inc-' || v_tag, 'sev3', 'A client''s own incident',
                                                   'A. Commander', 'B. Comms', 'C. Scribe');
      v_got := 'declared';
    exception when others then
      v_got := sqlerrm;
    end;
    insert into erp_meta.incident (code, severity_code, title, commander, communications_owner, scribe,
                                   next_update_due_at, declared_by)
    values ('zzcli-own-' || v_tag, 'sev3', 'A client''s own incident from before', 'A. Commander', 'B. Comms',
            'C. Scribe', now() + interval '1 day', v_owner);
    perform public.erp_platform_post_incident_update('zzcli-own-' || v_tag, 'Still the client''s own to update.');
    v_json := public.erp_platform_incidents();
    v_cases := v_cases + 1;
    case_name := 'on a client an incident is declared on the control plane and not here, and one of its own from before is still updated and read at its own console';
    passed := v_got like 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a client''s own deployment%'
          and not exists (select 1 from erp_meta.incident i where i.code = 'zzcli-inc-' || v_tag)
          and (select count(*) from erp_meta.incident_update u join erp_meta.incident i on i.id = u.incident_id
                where i.code = 'zzcli-own-' || v_tag) = 1
          and strpos(v_json::text, 'zzcli-own-' || v_tag) > 0;
    detail := left(v_got, 80) || ' / '
              || case when strpos(v_json::text, 'zzcli-own-' || v_tag) > 0 then 'its own listed' else 'its own not listed' end;
    return next;
$n$),
        -- A window for every client is a window for nobody here.
        ('erp_test.service_notice_suite()', 'f1e3331579d4ad751d9585b90cb8d352', 1,
$o$  return query select 'a window that is not for everyone names who it is for', v_ok, v_msg;
$o$,
$n$  return query select 'a window that is not for everyone names who it is for', v_ok, v_msg;

  -- Every client deployment is somebody, and nobody here (20261012060000).
  perform erp.announce_maintenance('zzsn-win-clients', 'For every client', 'Read-only for an hour',
                                   now() + interval '3 days', now() + interval '3 days 1 hour', false,
                                   null, false, null, true);
  perform set_config('request.jwt.claims', json_build_object('sub', aa)::text, true);
  res := erp.service_notices();
  return query select 'a window for every client deployment names nobody here, and no organisation here is shown it',
    not exists (select 1 from jsonb_array_elements(res -> 'maintenance') w where w ->> 'code' = 'zzsn-win-clients')
    and (select w.every_client and not w.affects_all_tenants from erp_meta.maintenance_window w
          where w.code = 'zzsn-win-clients')
    and not exists (select 1 from erp_meta.maintenance_window_tenant t
                      join erp_meta.maintenance_window w on w.id = t.window_id
                     where w.code = 'zzsn-win-clients'),
    'every client is not every organisation';
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
$n$),
        ('erp_test.assert_service_notice_suite()', '839074aa75eec6a97a1855b37aa85ad2', 1,
$o$  c_expected constant integer := 21;
$o$,
$n$  -- Twenty-two with the window for every client (20261012060000).
  c_expected constant integer := 22;
$n$),
        -- A provider's outage reaches every client too.
        ('erp_test.incident_communication_suite()', '11d7ffffad3754c14f113f27383e3d51', 1,
$o$    return query select 'a major indicator on a provider feed declares a severity-3 incident with its origin',
$o$,
$n$    return query select 'a major indicator on a provider feed declares a severity-3 incident with its origin, reaching every client deployment too',
$n$),
        ('erp_test.incident_communication_suite()', '11d7ffffad3754c14f113f27383e3d51', 2,
$o$      and (select i.severity_code = 'sev3' and i.origin_dependency_code = 'resend' and i.affects_all_tenants
$o$,
$n$      -- Every client deployment too (20261012060000).
      and (select i.severity_code = 'sev3' and i.origin_dependency_code = 'resend' and i.affects_all_tenants
             and i.every_client
$n$)
      ) as x(sig, anchor, ord, old, new)
     group by x.sig, x.anchor
     order by x.sig
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261012060000') > 0 then
      raise notice '% already carries 20261012060000', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.anchor then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    for i in 1 .. cardinality(r.olds) loop
      if (length(v_def) - length(replace(v_def, r.olds[i], ''))) / length(r.olds[i]) <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % does not hold its anchor % exactly once', r.sig, i;
      end if;
      v_def := replace(v_def, r.olds[i], r.news[i]);
    end loop;
    execute v_def;
  end loop;
end
$do$;

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
