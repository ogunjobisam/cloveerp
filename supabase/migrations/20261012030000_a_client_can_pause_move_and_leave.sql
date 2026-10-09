set lock_timeout = '30s';

-- =============================================================================
-- 20261012030000  A client can pause, move and leave
-- -----------------------------------------------------------------------------
-- The control plane's register of client deployments (20261011020000) could
-- build a client, release to it and retire it. Day to day a client is also
-- suspended and reinstated, moved to another address, and offboarded with a
-- copy of its data. This is the register's half of that; the workflows that
-- re-point a client's project, copy its database, keep backups off the
-- platform and bring each client's own organisation into line, and the Fleet
-- view's buttons, come in the same pull request.
--
--   A. A deployment has an address. Its code is its key for good: the steps
--      it has recorded (erp_meta.deployment_event) are kept as they were and
--      name it by its code, with no cascade, so the code never changes. What
--      a rename moves is the address it is served at, <address>.cloveerp.com,
--      which starts as its code. Every address a deployment is moved from is
--      kept in erp_meta.deployment_previous_address, held for that deployment
--      for good and given to no other deployment or organisation, and leads to
--      its current address for ninety days. Every address a rename of it was
--      ever asked for is held for it for good too, whether the rename
--      finished, failed or was cancelled: its project may answer there
--      already. erp.tenant_code_refusal refuses an address any deployment
--      holds now, held before, or was ever asked to be moved to.
--
--   B. Suspended. Supabase does not pause a project on a paid plan, so a
--      suspension is the register's: suspended_reason is set, and suspended_at
--      says since when. A deployment is suspended when its status is
--      suspended, or when it is being offboarded (retiring) with a reason set;
--      offboarding keeps a suspension, and one being offboarded may be
--      suspended. A suspended address answers that its service is suspended
--      and the application boots nothing for it, and the client's own
--      organisation follows: suspending and reinstating each ask for a status
--      sync (a fleet request of kind 'sync'), whose workflow calls
--      erp_meta.follow_deployment_status on the client, which lifts only the
--      suspension it made itself, at the moment it keeps. The project keeps
--      running and keeps receiving releases. Reinstating makes it live again
--      if a release to it ever succeeded, built if not. Owner, on the control
--      plane, with a reason.
--
--   C. Renamed. The console asks; a workflow re-points the client's own
--      project (its sign-in addresses, its functions, its identity, its one
--      organisation's address) and then tells the register, with
--      erp_meta.finish_deployment_rename. On the client,
--      erp_meta.rename_client_organisation renames its organisation once the
--      project knows its new address. A rename waits for the one before it,
--      unless its run has not settled it in three hours (fleet_rename.yml
--      gives up after 150 minutes), when it is let go. A deployment may be
--      moved back to its own code, to an address it held before, or to one a
--      rename of it was asked for before: that is how a mistaken rename is
--      walked back, and how one that stopped is asked for again.
--
--   D. Offboarded. Begin offboarding makes a deployment retiring, keeps when
--      it began, sets the day its project may be purged (thirty days after the
--      term of a contract in force for it ends, or thirty days from now), asks
--      for an export of its database if it ever had one, and cancels a build
--      still waiting, though not one the sweep started in the last ninety
--      minutes (a claim older than that never started, and is let go); one
--      never built has no database, so nothing is copied from it, nothing is
--      served for it, no release goes to it, and the poll does not miss it.
--      It may be cancelled, which puts the deployment back as it was. An
--      export can also be asked for at any time by an operator; the workflow
--      records what it wrote with erp_meta.record_deployment_export, with
--      when its dump began and whether the client's own organisation was
--      confirmed suspended first, and one its run left claimed for four hours
--      (fleet_export.yml gives up after three) is let go when another is
--      asked for. One claimed before the client's service stopped does not
--      stand for one asked for since: a new one is queued beside it. Retiring
--      now refuses while a contract in force names the deployment, whatever
--      its status, or while a release to it may still be running (two hours:
--      a release job runs for up to ninety-five minutes); retires one being
--      offboarded only on its purge date, and, if it ever had a database,
--      only once its service is suspended and a copy of its data is recorded
--      whose dump began since then, with its own organisation confirmed
--      stopped; fails what the control plane still owed it; and cancels its
--      renames, exports, status syncs and builds, waiting or claimed. Mail
--      owed under a retired deployment's contract is not sent.
--
--   E. The proof: erp_test.deployment_lifecycle_suite (thirty-eight cases)
--      and erp_test.deployment_rename_suite (sixteen), with their assertions.
--      erp_test.register_house_suite counts forty keys in the Fleet view now,
--      the eleven above among them.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No permission code and no organisation's screen. Nothing here reaches a
-- client's database by itself: the workflows do, through the trusted build
-- role. The control plane's own organisations are renamed as before.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE',
  'Suspending a client deployment that is not built, live or being offboarded, or that is suspended already.',
  'A suspension stops a client''s address from serving its service while its project keeps running. A deployment '
  'still being built, or being offboarded without ever having been built, has no service to stop; one suspended '
  'already is suspended; and one retired is gone.',
  'Suspend a deployment that is built, live, or being offboarded and not suspended yet. One already suspended is '
  'reinstated from the Fleet view.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_SUSPENDED',
  'Reinstating a client deployment that is not suspended.',
  'Reinstating gives a suspended client its service back at its address. A deployment that is not suspended, '
  'whether or not it is being offboarded, has nothing to be given back.',
  'Only a suspended deployment is reinstated, or one being offboarded while suspended. The Fleet view shows each '
  'deployment''s status and why it is suspended.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE',
  'Moving a client deployment to a new address while it cannot be moved.',
  'A rename re-points the client''s own project at its new address before the register moves it. A deployment '
  'still being built has no project to re-point, one being offboarded or retired is on its way out, two renames '
  'at once would re-point it twice, and an address it already has is no move at all.',
  'Rename a deployment that is built, live or suspended, to an address it does not have now, once any rename it '
  'is waiting for has finished; one its run left unsettled for three hours is let go. The Fleet view shows each '
  'one.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE',
  'Beginning the offboarding of a client deployment whose build is running, or that is offboarded already.',
  'Offboarding sets the day a client''s project is deleted and copies its data first if it has any. A deployment '
  'being created or built, or whose build has just been started, would go on building while it is offboarded; '
  'one being offboarded or retired is offboarded already.',
  'Wait for the build to finish or fail, then begin its offboarding. One being offboarded already is shown with '
  'its purge date in the Fleet view, where its offboarding may also be cancelled.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDING',
  'Cancelling the offboarding of a client deployment that is not being offboarded.',
  'Cancelling an offboarding takes back the purge date and puts the deployment back as it was. A deployment that is '
  'not being offboarded has no offboarding to take back, and one retired is gone.',
  'Cancel the offboarding of a deployment the Fleet view shows as being offboarded, before it is retired.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_EXPORTABLE',
  'Asking for a copy of the database of a client deployment that has none to copy.',
  'An export copies a client''s database from its own project. A deployment that was never built has no data, and '
  'one that is retired has no project left to copy from.',
  'Ask for an export of a deployment that was built and is built, live, suspended or being offboarded.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_HAS_A_CONTRACT',
  'Retiring a client deployment while a contract in force names it.',
  'Retiring forgets how to reach a client''s project, and its project is deleted next. While a contract is in force '
  'the client is still paying for it, whether or not its offboarding has begun.',
  'Begin its offboarding from the Fleet view if it has not begun: that copies its data and sets the day its project '
  'is deleted, thirty days after the contract''s term ends. Retire it on that day, once the contract has ended.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_COOLING_OFF',
  'Retiring a client deployment being offboarded before the day its project may be purged.',
  'Offboarding gives a client thirty days after its contract ends, or after the offboarding began, in which its '
  'service and its data are still there to be copied or taken back. Retiring before then would delete them early.',
  'Retire it on or after the purge date the Fleet view shows for it. If it should stay, cancel its offboarding '
  'instead.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_STILL_SERVED',
  'Retiring a client deployment being offboarded while its address still serves it.',
  'Retiring is followed by the deletion of the client''s project, and a client that had a database is given a copy '
  'of its data as it stood at the end. While its address still serves it, its people can still change its data, so '
  'a copy taken now would not be the last.',
  'Suspend it from the Fleet view, then ask for an export: the export makes sure the client''s own organisation is '
  'stopped before it copies anything. Wait for the export to be recorded, then retire it.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_EXPORTED',
  'Retiring a client deployment being offboarded before a copy of its data taken after its service stopped was recorded.',
  'Retiring is followed by the deletion of the client''s project. A client that had a database is given a copy of '
  'its data as it stood when its service stopped, so a copy whose dump began before it was suspended, before its '
  'own organisation was confirmed suspended, or before its offboarding began, is not enough, whenever it was '
  'recorded.',
  'Ask for an export from the Fleet view: the export makes sure the client''s own organisation is stopped before it '
  'copies anything. Wait for the export to be recorded, then retire it.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_EXPORT_INVALID',
  'Recording a copy of a client''s database that does not say where it went, how big it is, or what it holds.',
  'The Fleet view shows when each client''s data was last copied and where the copy is kept. A copy recorded without '
  'those would be shown as kept when nobody could find it or check it.',
  'Record the copy with the place it was written for that client, its size, and its fingerprint, as the export '
  'workflow reads them back.');

select erp.register_refusal(
  'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN',
  'Asking for the console''s requests of a kind the console never makes.',
  'The console asks the workflows for five things: a client deployment built, a release, a client moved to a new '
  'address, a copy of a client''s database, and a client''s own organisation brought into line with the register''s '
  'suspension. A sweep that asked for anything else would claim nothing and say nothing, and the request it meant '
  'would wait.',
  'Ask for builds, releases, renames, exports or syncs, or any of them together.');

select erp.register_refusal(
  'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT',
  'Bringing an organisation into line with the register''s suspension on a deployment that is not a client''s own.',
  'The register on the control plane says whether a client is suspended, and the client''s own deployment follows '
  'it. The control plane and the demonstration keep their organisations'' status themselves, so nothing from the '
  'register is followed there.',
  'Suspend or reinstate a client from the Fleet view on the platform console at cloveerp.com; its own deployment '
  'follows when the status sync next runs.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A deployment has an address
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_meta.deployment add column if not exists address text;
alter table erp_meta.deployment add column if not exists purge_due_at timestamptz;
alter table erp_meta.deployment add column if not exists offboarding_at timestamptz;
alter table erp_meta.deployment add column if not exists suspended_reason text;
alter table erp_meta.deployment add column if not exists suspended_at timestamptz;
alter table erp_meta.deployment add column if not exists last_export_at timestamptz;
alter table erp_meta.deployment add column if not exists last_export_object text;
alter table erp_meta.deployment add column if not exists last_export_taken_at timestamptz;
alter table erp_meta.deployment add column if not exists last_export_service_stopped boolean not null default false;

-- Every deployment so far is served at its code. One suspended or being
-- offboarded before the register kept why and when is given words for it, so
-- the rules below hold of every row.
update erp_meta.deployment x set address = x.code where x.address is null;
update erp_meta.deployment x
   set suspended_reason = 'Suspended before the register kept a reason (20261012030000).'
 where x.status = 'suspended' and x.suspended_reason is null;
-- Since when: the last time its row changed is the nearest the register knows.
update erp_meta.deployment x
   set suspended_at = coalesce(x.updated_at, now())
 where x.suspended_reason is not null and x.suspended_at is null;
update erp_meta.deployment x
   set offboarding_at = coalesce(x.offboarding_at, x.updated_at),
       purge_due_at = coalesce(x.purge_due_at, now() + interval '30 days')
 where x.status = 'retiring' and (x.offboarding_at is null or x.purge_due_at is null);

create or replace function erp_meta.deployment_address_starts_as_its_code()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- A deployment is first served at its code. A rename moves the address and
  -- never the code (20261012030000).
  new.address := coalesce(nullif(btrim(coalesce(new.address, '')), ''), new.code);
  return new;
end;
$$;

revoke all on function erp_meta.deployment_address_starts_as_its_code() from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_address_starts_as_its_code() is
  'The trigger before a client deployment is registered: it is served at its code until a rename moves it '
  '(20261012030000).';

drop trigger if exists t_deployment_address_starts_as_its_code on erp_meta.deployment;
create trigger t_deployment_address_starts_as_its_code
  before insert on erp_meta.deployment
  for each row
  execute function erp_meta.deployment_address_starts_as_its_code();

alter table erp_meta.deployment alter column address set not null;

do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_address_check') then
    alter table erp_meta.deployment
      add constraint deployment_address_check check (address ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$');
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_address_key') then
    alter table erp_meta.deployment add constraint deployment_address_key unique (address);
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_export_is_named') then
    alter table erp_meta.deployment
      add constraint deployment_export_is_named check ((last_export_at is null) = (last_export_object is null));
  end if;
  -- A copy recorded says when its dump began, which is never after it was
  -- recorded; with no copy, none was taken with the service stopped
  -- (20261012030000).
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_export_is_dated') then
    alter table erp_meta.deployment
      add constraint deployment_export_is_dated
      check ((last_export_at is null) = (last_export_taken_at is null)
             and (last_export_taken_at is null or last_export_taken_at <= last_export_at)
             and (last_export_at is not null or not last_export_service_stopped));
  end if;
  -- Suspension is the reason: a suspended deployment says why, and only one
  -- suspended or being offboarded has a reason (20261012030000).
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_suspension_has_a_reason') then
    alter table erp_meta.deployment
      add constraint deployment_suspension_has_a_reason
      check ((status <> 'suspended' or suspended_reason is not null)
             and (suspended_reason is null or status in ('suspended', 'retiring')));
  end if;
  -- And says since when: the two are set and cleared together
  -- (20261012030000).
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_suspension_is_dated') then
    alter table erp_meta.deployment
      add constraint deployment_suspension_is_dated
      check ((suspended_reason is null) = (suspended_at is null));
  end if;
  -- One being offboarded knows when its offboarding began and when its
  -- project may be purged (20261012030000).
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_offboarding_is_dated') then
    alter table erp_meta.deployment
      add constraint deployment_offboarding_is_dated
      check (status <> 'retiring' or (offboarding_at is not null and purge_due_at is not null));
  end if;
end
$$;

comment on column erp_meta.deployment.address is
  'Where the deployment is served: <address>.cloveerp.com. Starts as its code; a rename moves it, and never the '
  'code, which its recorded steps name for good. Held across the fleet as codes are; every address it is moved '
  'from is kept in erp_meta.deployment_previous_address (20261012030000).';
comment on column erp_meta.deployment.purge_due_at is
  'Set when offboarding begins: the day its project may be deleted and the deployment retired, thirty days after '
  'the term of a contract in force for it ends, or thirty days from the start. Cleared when the offboarding is '
  'cancelled (20261012030000).';
comment on column erp_meta.deployment.offboarding_at is
  'When its offboarding began; null when none is under way. An export recorded before it does not count towards '
  'retiring the deployment (20261012030000).';
comment on column erp_meta.deployment.suspended_reason is
  'Why the deployment is suspended, as the owner gave it. Set, it is suspended: its status is suspended, or it is '
  'being offboarded while suspended. Cleared when it is reinstated or retired (20261012030000).';
comment on column erp_meta.deployment.suspended_at is
  'Since when the deployment is suspended: set with suspended_reason and cleared with it. Offboarding and its '
  'cancelling keep it. One being offboarded that ever had a database is retired only with a copy of its data whose '
  'dump began at or after this and its offboarding''s start, once its own organisation was confirmed suspended, so '
  'the copy is of its data as it stood when its service stopped (20261012030000).';
comment on column erp_meta.deployment.last_export_at is
  'When the newest copy of the deployment''s database written off the platform was recorded (20261012030000).';
comment on column erp_meta.deployment.last_export_object is
  'Where that copy was written: exports/<code>/<time>.dump.age in the export bucket, encrypted (20261012030000).';
comment on column erp_meta.deployment.last_export_taken_at is
  'When that copy''s dump began, by the control plane''s clock: the moment its data is from. A copy recorded later '
  'whose dump began earlier does not replace it (20261012030000).';
comment on column erp_meta.deployment.last_export_service_stopped is
  'Whether that copy was taken after the client''s own organisation was confirmed suspended, so nobody could change '
  'its data while it was dumped. Only such a copy, begun since its service stopped and its offboarding began, lets '
  'one being offboarded be retired (20261012030000).';

-- Every address a deployment was moved from, held for it for good.
create table if not exists erp_meta.deployment_previous_address (
  address        text primary key check (address ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'),
  code           text not null references erp_meta.deployment (code) on update cascade,
  -- The clock, not the transaction's start: two moves in one transaction are
  -- still told apart by which came last.
  moved_at       timestamptz not null default clock_timestamp(),
  redirect_until timestamptz not null
);

create index if not exists deployment_previous_address_code
  on erp_meta.deployment_previous_address (code, moved_at desc);

comment on table erp_meta.deployment_previous_address is
  'Every address a client deployment was moved from, held for that deployment for good: erp.tenant_code_refusal '
  'gives it to no other deployment or organisation, and the deployment may be moved back to it. While '
  'redirect_until is to come, the directory answers there with where the deployment is served now. Written by '
  'erp_meta.finish_deployment_rename on the control plane; empty everywhere else (20261012030000).';
comment on column erp_meta.deployment_previous_address.moved_at is
  'When the deployment was last moved from this address.';
comment on column erp_meta.deployment_previous_address.redirect_until is
  'Until when this address leads to where the deployment is served now: ninety days from the move. After it, the '
  'address answers nothing and stays held.';

select erp_meta.register_table('erp_meta', 'deployment_previous_address', 'platform_internal',
  'Every address a client deployment was moved from, held for it for good and leading to its current address for '
  'ninety days. Written by the rename workflow through erp_meta.finish_deployment_rename.');

revoke all on table erp_meta.deployment_previous_address from public, anon, authenticated;

insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp_meta', 'deployment', 'address',
   'The web address a client deployment is served at, a subdomain of cloveerp.com. It names a project, not a person.'),
  ('erp_meta', 'deployment_previous_address', 'address',
   'A web address a client deployment was served at before a rename, a subdomain of cloveerp.com. It names a '
   'project, not a person.')
on conflict do nothing;

-- The steps a rename, an export, a suspension and a status sync record.
do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment_event'::regclass and c.conname = 'deployment_event_phase_check'
                    and pg_catalog.pg_get_constraintdef(c.oid) like '%suspend%') then
    alter table erp_meta.deployment_event drop constraint if exists deployment_event_phase_check;
    alter table erp_meta.deployment_event
      add constraint deployment_event_phase_check
      check (phase in ('request', 'dispatch', 'create', 'configure', 'build', 'identity', 'functions',
                       'prove', 'release', 'retry', 'checklist', 'note', 'rename', 'export', 'suspend', 'status'));
  end if;
end
$$;

-- What the console may ask the workflows for, and the shape each asks in.
do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.fleet_request'::regclass and c.conname = 'fleet_request_kind_check'
                    and pg_catalog.pg_get_constraintdef(c.oid) like '%sync%') then
    alter table erp_meta.fleet_request drop constraint if exists fleet_request_kind_check;
    alter table erp_meta.fleet_request
      add constraint fleet_request_kind_check check (kind in ('build', 'release', 'rename', 'export', 'sync'));
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.fleet_request'::regclass and c.conname = 'fleet_request_payload_shape') then
    alter table erp_meta.fleet_request
      add constraint fleet_request_payload_shape
      check ((kind <> 'rename' or (payload ? 'code' and payload ? 'from' and payload ? 'to'))
             and (kind not in ('export', 'sync') or payload ? 'code'));
  end if;
end
$$;

comment on table erp_meta.fleet_request is
  'What the console asked the workflows for — a build of a client deployment, a release train, a client moved to '
  'a new address ({code, from, to}), a copy of a client''s database ({code}), a client''s own organisation brought '
  'into line with the register''s suspension ({code}) — for the sweep (fleet_sweep.yml) to claim with the '
  'repository''s own token (20261011020000, 20261012030000). Each open request made wakes the sweep at once where '
  'the control plane can call out (erp_meta.wake_the_sweep, 20261012010000); the schedule stays behind it. The '
  'console holds no token.';

-- ─────────────────────────────────────────────────────────────────────────────
-- What the register already did, taught the address, the suspension, the
-- offboarding and the new requests
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
        -- An address held by a deployment now, before, or about to be.
        ('erp.tenant_code_refusal(text,uuid)', '24f40c65b5af58605e700fb8056183ba', 1,
$o$    when exists (select 1 from erp_meta.deployment d where d.code = p_code) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" is a client deployment''s address'
$o$,
$n$    when exists (select 1 from erp_meta.deployment d where d.code = p_code or d.address = p_code) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" is a client deployment''s address'
    -- Every address a rename moved a deployment from is held for that
    -- deployment for good: it leads to the new one for ninety days, and is
    -- given to no other deployment or organisation, ever. The address a
    -- rename is moving one to is held from the moment it is asked for, and
    -- stays held for it whatever became of the rename: one that failed or
    -- was let go may have left the client's project answering there, and
    -- asking for it again is how that is finished (20261012030000).
    when exists (select 1 from erp_meta.deployment_previous_address pa where pa.address = p_code) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" was a client deployment''s address and is kept for it'
    when exists (select 1 from erp_meta.fleet_request r
                  where r.kind = 'rename' and r.status in ('requested', 'claimed')
                    and r.payload ->> 'to' = p_code) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" is the address a client deployment is being moved to'
    when exists (select 1 from erp_meta.fleet_request r
                  where r.kind = 'rename' and r.payload ->> 'to' = p_code) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" was asked for as a client deployment''s address and is kept for it'
$n$),
        -- A suspended client is released into; one being offboarded is still up.
        ('erp_meta.begin_deployment_release(text,text)', '79aa71dcaf76797d3afe5c1b1ea214ce', 1,
$o$  if d.status not in ('built', 'live') then
$o$,
$n$  -- A suspended client keeps receiving releases, and one being offboarded is
  -- still up until it is retired; one being offboarded that was never built
  -- has no database to release into, and is said so in a word no release
  -- takes for a target (20261012030000).
  if d.status = 'retiring' and d.built_at is null then
    return 'retiring, never built';
  end if;
  if d.status not in ('built', 'live', 'suspended', 'retiring') then
$n$),
        ('public.erp_platform_request_release(text[],text)', 'ba7d11a7fc610b4fe7e548337a673dcf', 1,
$o$       and not exists (select 1 from erp_meta.deployment d where d.code = t and d.status in ('built', 'live')) then
$o$,
$n$       and not exists (select 1 from erp_meta.deployment d where d.code = t
                         -- A suspended client is released into, and one being
                         -- offboarded is still up if it was ever built
                         -- (20261012030000).
                         and (d.status in ('built', 'live', 'suspended')
                              or (d.status = 'retiring' and d.built_at is not null))) then
$n$),
        -- The sweep may ask for renames, exports and status syncs.
        ('erp_meta.claim_fleet_request(text,text[])', 'ceff161cb48fe6cad01334f165af7a30', 1,
$o$   where k is null or k not in ('build', 'release');
$o$,
$n$   where k is null or k not in ('build', 'release', 'rename', 'export', 'sync');
$n$),
        ('erp_meta.claim_fleet_request(text,text[])', 'ceff161cb48fe6cad01334f165af7a30', 2,
$o$    raise exception 'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN: the console asks for builds and releases, not %', v_bad
      using errcode = '22023',
            hint = 'Ask for builds, releases, or both.';
$o$,
$n$    -- Renames, exports and status syncs too, since 20261012030000.
    raise exception 'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN: the console asks for builds, releases, renames, exports and syncs, not %', v_bad
      using errcode = '22023',
            hint = 'Ask for builds, releases, renames, exports or syncs, or any of them together.';
$n$),
        -- The steps a rename, an export, a suspension and a status sync record.
        ('erp_meta.record_deployment_event(text,text,text,text,text)', '85bebe8fd3b04a90431a3bd1fd1edca5', 1,
$o$                     'prove', 'release', 'retry', 'checklist', 'note')
$o$,
$n$                     'prove', 'release', 'retry', 'checklist', 'note',
                     -- A client moved to a new address, a copy of its database
                     -- written, its service suspended, and its own
                     -- organisation brought into line (20261012030000).
                     'rename', 'export', 'suspend', 'status')
$n$),
        -- The Fleet view: where each deployment is served and was, its
        -- offboarding, its suspension and its last export.
        ('public.erp_platform_deployments()', 'e0253739c4208c62993d2c5b918e44e6', 1,
$o$             'origin', 'https://' || d.code || '.' || regexp_replace(erp.app_origin(), '^https://', ''),
$o$,
$n$             -- Where it is served, which a rename moves; the code it was
             -- registered under never changes. The newest address it was
             -- moved from that still leads here, and until when; the day its
             -- project may be purged and when its offboarding began; why it
             -- is suspended, and since when; and its last export, when its
             -- dump began and whether its service was stopped by then
             -- (20261012030000).
             'origin', 'https://' || d.address || '.' || regexp_replace(erp.app_origin(), '^https://', ''),
             'address', d.address,
             'previous_address', (select pa.address from erp_meta.deployment_previous_address pa
                                   where pa.code = d.code and pa.redirect_until > now()
                                   order by pa.moved_at desc, pa.address limit 1),
             'previous_address_until', (select pa.redirect_until from erp_meta.deployment_previous_address pa
                                         where pa.code = d.code and pa.redirect_until > now()
                                         order by pa.moved_at desc, pa.address limit 1),
             'purge_due_at', d.purge_due_at,
             'offboarding_at', d.offboarding_at,
             'suspended_reason', d.suspended_reason,
             'suspended_at', d.suspended_at,
             'last_export_at', d.last_export_at,
             'last_export_object', d.last_export_object,
             'last_export_taken_at', d.last_export_taken_at,
             'last_export_service_stopped', d.last_export_service_stopped,
$n$),
        ('public.erp_platform_deployments()', 'e0253739c4208c62993d2c5b918e44e6', 2,
$o$             'silent', d.status in ('built', 'live')
$o$,
$n$             'silent', (d.status in ('built', 'live', 'suspended')
                        or (d.status = 'retiring' and d.built_at is not null))
$n$),
        -- Retiring: nothing it is owed is left; what it was owed is failed,
        -- and its renames, exports, syncs and builds are cancelled.
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 1,
$o$  v_forgotten integer := 0;
$o$,
$n$  v_forgotten integer := 0;
  v_pushes    integer := 0;
  v_cancelled integer := 0;
  v_contract  erp_meta.contract;
$n$),
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 2,
$o$  update erp_meta.deployment x
     set status = c_retired, owner_email = null, updated_at = now()
   where x.code = d.code;
$o$,
$n$  -- Nothing the client is owed is left (20261012030000). No contract in
  -- force names it, whatever its status: retiring forgets how to reach the
  -- project the client still pays for.
  select c.* into v_contract
    from erp_meta.contract c
   where c.deployment_code = d.code
     and c.status in ('active', 'terminating')
   order by c.current_term_end desc
   limit 1;
  if v_contract.id is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_HAS_A_CONTRACT: % is not retired: its contract with % is in force until %',
      d.code, v_contract.customer_legal_name, to_char(v_contract.current_term_end, 'FMDD Mon YYYY')
      using errcode = '55000',
            hint = 'Begin its offboarding from the Fleet view if it has not begun: that copies its data and sets the '
                   'day its project is deleted, thirty days after the contract''s term ends. Retire it on that day, '
                   'once the contract has ended.';
  end if;
  -- One being offboarded has its thirty days: its service and its data are
  -- there until its purge date.
  if d.status = 'retiring' and d.purge_due_at > now() then
    raise exception 'CLOVEERP_DEPLOYMENT_COOLING_OFF: % is not retired: its offboarding runs until %, when its project may be purged',
      d.code, to_char(d.purge_due_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"')
      using errcode = '55000',
            hint = 'Retire it on or after the purge date the Fleet view shows for it. If it should stay, cancel its '
                   'offboarding instead.';
  end if;
  -- And one that ever had a database leaves with a copy of its data as it
  -- stood when its service stopped. While its address serves it its people
  -- can still change its data, so no copy is the last until it is
  -- suspended; then the copy must be one whose dump began since, and since
  -- its offboarding began, once its own organisation was confirmed
  -- suspended. When it was recorded says nothing: a dump begun while it was
  -- served is recorded only after it is sealed and written away.
  if d.status = 'retiring' and d.built_at is not null and d.suspended_reason is null then
    raise exception 'CLOVEERP_DEPLOYMENT_STILL_SERVED: % is not retired: its address still serves it, so its people can still change its data and a copy taken now would not be the last',
      d.code
      using errcode = '55000',
            hint = 'Suspend it from the Fleet view, then ask for an export: the export makes sure the client''s own '
                   'organisation is stopped before it copies anything. Wait for the export to be recorded, then retire '
                   'it.';
  end if;
  if d.status = 'retiring' and d.built_at is not null
     and not (d.last_export_service_stopped
              and d.last_export_taken_at >= greatest(coalesce(d.offboarding_at, '-infinity'::timestamptz),
                                                     coalesce(d.suspended_at, '-infinity'::timestamptz))) then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_EXPORTED: % is not retired: no copy of its data taken after its service stopped% has been recorded%',
      d.code,
      case when d.offboarding_at > d.suspended_at
           then format(' and its offboarding began on %s',
                       to_char(d.offboarding_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"'))
           else format(' on %s', to_char(coalesce(d.suspended_at, d.updated_at) at time zone 'UTC',
                                         'FMDD Mon YYYY HH24:MI "UTC"')) end,
      case when d.last_export_taken_at is null then ''
           when not d.last_export_service_stopped
             then format('; the last was taken on %s, without its own organisation confirmed suspended',
                         to_char(d.last_export_taken_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"'))
           else format('; the last was taken on %s',
                       to_char(d.last_export_taken_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"')) end
      using errcode = '55000',
            hint = 'Ask for an export from the Fleet view: the export makes sure the client''s own organisation is '
                   'stopped before it copies anything. Wait for the export to be recorded, then retire it.';
  end if;

  update erp_meta.deployment x
     set status = c_retired, owner_email = null, suspended_reason = null, suspended_at = null, updated_at = now()
   where x.code = d.code;
$n$),
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 3,
$o$  -- A build still waiting for the sweep would rebuild a deployment that is
  -- gone. A release waiting for it is left alone: it may name the control
  -- plane and other clients too, and the train itself releases nothing to a
  -- retired client (deploy.yml reads only built and live ones, and each
  -- client's release asks the register first) (20261011060000).
  update erp_meta.fleet_request r
     set status = 'cancelled', outcome = 'the deployment was retired', settled_at = now()
   where r.status = 'requested'
     and r.kind = 'build'
     and r.payload ->> 'code' = d.code;
$o$,
$n$  -- A build waiting for the sweep or claimed by it would rebuild a
  -- deployment that is gone, and a rename, an export or a status sync would
  -- reach a project about to be deleted, through credentials deleted below;
  -- a claimed one's late word is quiet (erp_meta.settle_fleet_request)
  -- (20261012030000). A release waiting for it is left alone: it may name the
  -- control plane and other clients too, and the train itself releases
  -- nothing to a retired client (deploy.yml reads only the deployments that
  -- are up, and each client's release asks the register first)
  -- (20261011060000).
  update erp_meta.fleet_request r
     set status = 'cancelled', outcome = 'the deployment was retired', settled_at = now()
   where r.status in ('requested', 'claimed')
     and r.kind in ('build', 'rename', 'export', 'sync')
     and r.payload ->> 'code' = d.code;
  get diagnostics v_cancelled = row_count;

  -- What the control plane still owed it is owed no more (20261012030000).
  update erp_meta.deployment_push p
     set status = 'failed', detail = 'the deployment was retired, so it is owed nothing more', settled_at = now()
   where p.code = d.code
     and p.status in ('pending', 'claimed');
  get diagnostics v_pushes = row_count;
$n$),
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 4,
$o$    jsonb_build_object('was', d.status, 'project_ref', d.project_ref, 'credentials_deleted', v_forgotten));
$o$,
$n$    jsonb_build_object('was', d.status, 'project_ref', d.project_ref, 'credentials_deleted', v_forgotten,
                       'pushes_failed', v_pushes, 'requests_cancelled', v_cancelled));
$n$),
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 5,
$o$                            'credentials_deleted', v_forgotten);
$o$,
$n$                            'credentials_deleted', v_forgotten, 'pushes_failed', v_pushes,
                            'requests_cancelled', v_cancelled);
$n$),
        -- A release is seen for as long as its job can run.
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 6,
$o$    when v_last.phase = 'release' and v_last.status = 'started' and v_last.at > now() - interval '90 minutes'
      then 'a release to it has started and not finished'
$o$,
$n$    -- A release records that it started as its job begins, and the job may
    -- then wait up to thirty-five minutes for a copy of the database to
    -- finish before it replays: release.yml gives it ninety-five minutes in
    -- all. A release started under two hours ago may still be running, so
    -- the deployment is not retired under it (20261012030000).
    when v_last.phase = 'release' and v_last.status = 'started' and v_last.at > now() - interval '2 hours'
      then 'a release to it has started and not finished'
$n$),
        -- Mail owed under a retired deployment's contract is not sent.
        ('erp.claim_commercial_email_batch(integer,text)', 'e0bd7b671d06bb932a328a8584363c45', 1,
$o$  r          record;
$o$,
$n$  r          record;
  -- The register's word for a deployment that is gone, named rather than
  -- written inline (erp.record_status_literal_report) (20261012030000).
  c_retired  constant text := 'retired';
$n$),
        ('erp.claim_commercial_email_batch(integer,text)', 'e0bd7b671d06bb932a328a8584363c45', 2,
$o$                and not exists (select 1 from erp.tenant t where t.id = ce.tenant_id))) as gone,
$o$,
$n$                and not exists (select 1 from erp.tenant t where t.id = ce.tenant_id))) as gone,
           -- A client deployment that is retired is owed no more of its
           -- contract's mail: it is gone, as a gone organisation is
           -- (20261012030000).
           exists (select 1
                     from erp_meta.contract_invoice ci
                     join erp_meta.contract c on c.id = ci.contract_id
                     join erp_meta.deployment d on d.code = c.deployment_code
                    where ci.id = ce.contract_invoice_id
                      and d.status = c_retired) as deployment_gone,
$n$),
        ('erp.claim_commercial_email_batch(integer,text)', 'e0bd7b671d06bb932a328a8584363c45', 3,
$o$                               else 'the document it would send no longer exists' end
    from judged j
   where ce.id = j.id
     and (j.demonstration or j.gone or j.suppressed);
$o$,
$n$                               when j.deployment_gone then 'the client deployment it is for is retired'
                               else 'the document it would send no longer exists' end
    from judged j
   where ce.id = j.id
     and (j.demonstration or j.gone or j.deployment_gone or j.suppressed);
$n$),
        -- The register's own suite counts the Fleet view's keys; eleven more now.
        ('erp_test.register_house_suite()', '94c05d1a27391c39ef955c4f5221166f', 1,
$o$                 'health', 'health_at', 'silent']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 29
$o$,
$n$                 'health', 'health_at', 'silent',
                 -- Where it is served and was, its offboarding, its
                 -- suspension and its last export, when that copy's dump
                 -- began and whether its service was stopped by then
                 -- (20261012030000).
                 'address', 'previous_address', 'previous_address_until', 'purge_due_at', 'offboarding_at',
                 'suspended_reason', 'suspended_at', 'last_export_at', 'last_export_object',
                 'last_export_taken_at', 'last_export_service_stopped']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 40
$n$),
        -- One address is taken at a time across the fleet: a deployment's code
        -- and an organisation's address are decided under the lock a rename
        -- takes, so neither is given what a rename is giving at that moment.
        ('public.erp_platform_request_deployment(text,text,text,text)', '2d2dab84eac27857c4cd9a12ca5ddb03', 1,
$o$  if exists (select 1 from erp_meta.deployment d where d.code = v_code) then
$o$,
$n$  -- One address is taken at a time across the fleet, under the lock a
  -- rename takes (20261012030000).
  perform pg_advisory_xact_lock(hashtext('erp_meta.deployment.address'));
  if exists (select 1 from erp_meta.deployment d where d.code = v_code) then
$n$),
        ('public.erp_platform_set_tenant_address(uuid,text,text)', 'd1732ee574856ed047ee362f7de05d7a', 1,
$o$  perform erp.refuse_unchosen_address(v_code, v_t.id);
$o$,
$n$  -- One address is taken at a time across the fleet, under the lock a
  -- client deployment's rename takes (20261012030000).
  perform pg_advisory_xact_lock(hashtext('erp_meta.deployment.address'));
  perform erp.refuse_unchosen_address(v_code, v_t.id);
$n$)
      ) as x(sig, anchor, ord, old, new)
     group by x.sig, x.anchor
     order by x.sig
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261012030000') > 0 then
      raise notice '% already carries 20261012030000', r.sig;
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

comment on function erp.tenant_code_refusal(text, uuid) is
  'Why a code may not be an organisation''s address, or null: its shape, a reserved word, another organisation''s '
  'address now or before, or a client deployment''s code, its address, any address it was moved from, or any '
  'address a rename of it was ever asked for, whatever became of the rename (each held for it for good) '
  '(20261011020000, 20261012030000).';

comment on function erp_meta.begin_deployment_release(text, text) is
  'Asked by each client''s release before it applies anything: the deployment''s status, and a release-started step '
  'recorded when it is a release target — built, live, suspended or being offboarded. One being offboarded that '
  'was never built answers ''retiring, never built'', which no release takes for a target. Trusted build role only '
  '(20261011050000, 20261012030000).';

comment on function public.erp_platform_deployments() is
  'Every client deployment in the register, with its build''s last step, its newest build request and when it '
  'was made, claimed and settled, whether Start again would start it now, its last release, its health as the poll '
  'last read it, when, and whether one that is up has gone silent (unread for twenty-six hours), where it is served '
  'and the newest address it was moved from that still leads there, when its offboarding began and the day it may '
  'be purged, why it is suspended and since when, and its last export, when that copy''s dump began and whether '
  'its service was stopped by then, for the Fleet view. Platform support and above, on the control plane only '
  '(20261011020000, 20261011110000, 20261012010000, 20261012030000).';

comment on function public.erp_platform_retire_deployment(text, text) is
  'Retires a client deployment: nothing runs for it again, its stored credentials are deleted, what was owed it is '
  'failed and its builds, renames, exports and status syncs, waiting or claimed, are cancelled. Refuses while a '
  'build or release runs for it (a release started under two hours ago may still be running); while a contract in '
  'force names it, whatever its status; and, for one being offboarded, before its purge date, and, when it ever had '
  'a database, while its address still serves it or before a copy of its data is recorded whose dump began after '
  'its service stopped and its offboarding began, with its own organisation confirmed suspended. Platform owner, on '
  'the control plane, with a reason (20261011040000, 20261012030000).';

comment on function erp_meta.claim_fleet_request(text, text[]) is
  'The oldest open request from the console of one of the kinds asked for (build, release, rename, export, sync), '
  'claimed by the sweep that will start its workflow run; null when there is none, or when no kind is asked for. '
  'The same shape as the one-argument claim, which takes any kind and stays as it was. Trusted build role only '
  '(20261012010000, 20261012030000).';

comment on function public.erp_platform_request_deployment(text, text, text, text) is
  'Requests a client deployment: a row in the register and a build request the sweep starts within ten minutes. '
  'Platform owner, on the control plane, with a reason; the code meets the rule an address meets, under the lock a '
  'rename takes, so it is never given an address a rename is giving at the same moment (20261011020000, '
  '20261012030000).';

comment on function public.erp_platform_set_tenant_address(uuid, text, text) is
  'Changes an organisation''s address from the platform console, for operators and above, with a reason; the old '
  'address keeps opening the new. The new one is decided under the lock a client deployment''s rename takes, so it '
  'is never given an address a rename is giving at the same moment (20261003510000, 20261012030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The directory finds a deployment by its address
-- ─────────────────────────────────────────────────────────────────────────────

do $$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'public.erp_deployment_for_host(text)'::regprocedure);
begin
  if strpos(v_src, '20261012030000') = 0 and md5(v_src) <> '004080e66e04688e4f0f0f38ca4acc3f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_deployment_for_host is not the body this migration was written against';
  end if;
end
$$;

create or replace function public.erp_deployment_for_host(p_host text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  -- The host, lower-cased, must be <address>.<apex>, where the apex is the
  -- host this control plane is served from. A deployment is found by its
  -- address, which a rename moves; its code never changes (20261012030000).
  -- Built, live, or being offboarded after it was built and not suspended,
  -- it answers with the project to boot. Suspended — its status, or being
  -- offboarded with a reason — it answers that it is suspended and with no
  -- project, so the application boots nothing for it. At an address it was
  -- moved from it answers where it went, for ninety days. Not yet built,
  -- failed, being offboarded without ever being built (a failed build may
  -- have registered a project it never finished), retired, or nobody:
  -- nothing.
  with asked as (
    select lower(btrim(coalesce(p_host, ''))) as host,
           regexp_replace(erp.app_origin(), '^https://', '') as apex),
  answers as (
    select 1 as rank,
           case when d.status = 'suspended' or (d.status = 'retiring' and d.suspended_reason is not null)
                then jsonb_build_object('code', d.code, 'client_name', d.client_name, 'suspended', true)
                else jsonb_build_object('code', d.code, 'client_name', d.client_name,
                                        'url', d.api_url, 'key', d.publishable_key)
           end as answer
      from asked a
      join erp_meta.deployment d
        on a.host = d.address || '.' || a.apex
     where d.status = 'suspended'
        or (d.status = 'retiring' and d.built_at is not null and d.suspended_reason is not null)
        or ((d.status in ('built', 'live') or (d.status = 'retiring' and d.built_at is not null))
            and d.suspended_reason is null
            and d.api_url is not null
            and d.publishable_key is not null)
    union all
    select 2,
           jsonb_build_object('code', d.code, 'client_name', d.client_name,
                              'moved_to', 'https://' || d.address || '.' || a.apex)
      from asked a
      join erp_meta.deployment_previous_address pa
        on a.host = pa.address || '.' || a.apex
      join erp_meta.deployment d
        on d.code = pa.code
     where pa.redirect_until > now()
       and (d.status in ('built', 'live', 'suspended')
            or (d.status = 'retiring' and d.built_at is not null)))
  select x.answer from answers x order by x.rank limit 1
$$;

revoke all on function public.erp_deployment_for_host(text) from public, anon, authenticated;
grant execute on function public.erp_deployment_for_host(text) to service_role;

comment on function public.erp_deployment_for_host(text) is
  'The directory: for <address>.<apex>, a built, live, or offboarding (built once) and unsuspended client '
  'deployment''s code, name, project URL and publishable key; a suspended one''s — suspended, or offboarding with a '
  'reason — code and name with suspended true and nothing to boot; at an address a deployment was moved from whose '
  'ninety days are still to run, its code, name and moved_to, the origin it is served at now; otherwise null, '
  'whatever project one being offboarded without ever being built registered. service_role only, for the '
  'application''s directory route (20261011020000, 20261012030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Suspended and reinstated
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_suspend_deployment(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  d      erp_meta.deployment;
  v_to   text;
  v_sync uuid;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: suspending a client deployment needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say why its service is suspended and what would bring it back; the Fleet view shows it on the '
                   'row, and it is kept in the platform''s activity log. At least twenty characters.';
  end if;

  select * into d from erp_meta.deployment x where x.code = d.code for update;
  -- Built or live; or being offboarded, built once, and not suspended yet
  -- (20261012030000).
  if not (d.status in ('built', 'live')
          or (d.status = 'retiring' and d.suspended_reason is null and d.built_at is not null)) then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE: % is not suspended: %', d.code,
      case when d.status = 'suspended' then 'it is suspended already'
           when d.status = 'retiring' and d.suspended_reason is not null then 'it is being offboarded, and suspended already'
           when d.status = 'retiring' then 'it is being offboarded and was never built, so it has no service to stop'
           else format('it is %s', d.status) end
      using errcode = '55000',
            hint = 'Suspend a deployment that is built, live, or being offboarded and not suspended yet. One already '
                   'suspended is reinstated from the Fleet view.';
  end if;

  -- The register's suspension: the address says the service is suspended and
  -- boots nothing, and the client's own organisation is suspended with it by
  -- the status sync. Supabase does not pause a project on a paid plan, so the
  -- project keeps running, and keeps receiving releases. One being offboarded
  -- stays so (20261012030000).
  v_to := case when d.status = 'retiring' then 'retiring' else 'suspended' end;
  -- Since when is kept with why: a copy of one being offboarded counts
  -- only if it was written since (20261012030000).
  update erp_meta.deployment x
     set status = v_to, suspended_reason = btrim(p_reason), suspended_at = now(), updated_at = now()
   where x.code = d.code;

  -- One status sync waiting is enough: it reads the register when it runs. It
  -- is held while this decides, so the sweep does not claim it in between.
  select r.id into v_sync
    from erp_meta.fleet_request r
   where r.kind = 'sync' and r.status = 'requested' and r.payload ->> 'code' = d.code
   order by r.created_at
   limit 1
   for update;
  if v_sync is null then
    insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
    values ('sync', jsonb_build_object('code', d.code), btrim(p_reason), v.id)
    returning id into v_sync;
  end if;

  perform erp_meta.record_deployment_event(d.code, 'suspend', 'done',
    format('suspended by %s (was %s): %s. Its address now says its service is suspended, and its organisation is '
           'suspended with it when the status sync runs; its project keeps running and keeps receiving releases.',
           v.email, d.status, rtrim(btrim(p_reason), '.')));
  perform erp_meta.platform_log(v, 'platform.deployment_suspended', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'status', v_to, 'sync_request_id', v_sync));

  return jsonb_build_object('code', d.code, 'status', v_to, 'was', d.status,
                            'suspended_reason', btrim(p_reason), 'sync_request_id', v_sync);
end;
$$;

revoke all on function public.erp_platform_suspend_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_suspend_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_suspend_deployment(text, text) is
  'Suspends a built or live client deployment, or one being offboarded that was built and is not suspended yet '
  '(which stays retiring): its reason is kept as suspended_reason and since when as suspended_at, its address '
  'answers that its service is suspended and the application boots nothing for it, and a status sync is asked for '
  'so its own organisation is suspended too. Its project keeps running and keeps receiving releases. Platform '
  'owner, on the control plane, with a reason (20261012030000).';

create or replace function public.erp_platform_reinstate_deployment(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  d      erp_meta.deployment;
  v_to   text;
  v_sync uuid;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: reinstating a client deployment needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say what changed so that its service comes back; it is kept in the platform''s activity log. At '
                   'least twenty characters.';
  end if;

  select * into d from erp_meta.deployment x where x.code = d.code for update;
  if not (d.status = 'suspended' or (d.status = 'retiring' and d.suspended_reason is not null)) then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDED: % is not reinstated: it is %, not suspended', d.code, d.status
      using errcode = '55000',
            hint = 'Only a suspended deployment is reinstated, or one being offboarded while suspended. The Fleet '
                   'view shows each deployment''s status and why it is suspended.';
  end if;

  -- Live again if a release to it ever succeeded, built if none has; one
  -- being offboarded stays so (20261012030000).
  v_to := case
    when d.status = 'retiring' then 'retiring'
    when exists (select 1 from erp_meta.deployment_event e
                  where e.code = d.code and e.phase = 'release' and e.status = 'done') then 'live'
    else 'built'
  end;
  update erp_meta.deployment x
     set status = v_to, suspended_reason = null, suspended_at = null, updated_at = now()
   where x.code = d.code;

  select r.id into v_sync
    from erp_meta.fleet_request r
   where r.kind = 'sync' and r.status = 'requested' and r.payload ->> 'code' = d.code
   order by r.created_at
   limit 1
   for update;
  if v_sync is null then
    insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
    values ('sync', jsonb_build_object('code', d.code), btrim(p_reason), v.id)
    returning id into v_sync;
  end if;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('reinstated by %s (now %s): %s. Its address serves it again, and its organisation is reinstated with it '
           'when the status sync runs; it had been suspended because: %s.',
           v.email, v_to, rtrim(btrim(p_reason), '.'),
           rtrim(coalesce(d.suspended_reason, 'no reason was kept'), '.')));
  perform erp_meta.platform_log(v, 'platform.deployment_reinstated', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'status', v_to, 'suspended_reason', d.suspended_reason,
                       'sync_request_id', v_sync));

  return jsonb_build_object('code', d.code, 'status', v_to, 'was', d.status, 'sync_request_id', v_sync);
end;
$$;

revoke all on function public.erp_platform_reinstate_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_reinstate_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_reinstate_deployment(text, text) is
  'Reinstates a suspended client deployment, or one being offboarded while suspended (which stays retiring): its '
  'reason for suspension and since when are cleared, it is served at its address again — live if a release to it '
  'ever succeeded, built if none has — and a status sync is asked for so its own organisation is reinstated too. '
  'Platform owner, on the control plane, with a reason (20261012030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Renamed
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_rename_deployment(p_code text, p_new_address text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  d       erp_meta.deployment;
  r       record;
  v_new   text := lower(btrim(coalesce(p_new_address, '')));
  v_busy  text;
  v_why   text;
  v_req   uuid;
  v_own   boolean;
  v_had   boolean;
  v_let   uuid[] := '{}'::uuid[];
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: moving a client deployment to a new address needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say who asked for the new address and why; it is kept in the platform''s activity log. At least '
                   'twenty characters.';
  end if;

  -- One address is taken at a time across the fleet, and this deployment's
  -- row is held while it is decided (20261012030000).
  perform pg_advisory_xact_lock(hashtext('erp_meta.deployment.address'));
  select * into d from erp_meta.deployment x where x.code = d.code for update;

  -- A rename the sweep claimed and whose run never settled it: fleet_rename.yml
  -- gives up after 150 minutes, so one claimed three hours ago has no run left
  -- to settle it, and is let go rather than holding the deployment for ever
  -- (20261012030000).
  for r in
    update erp_meta.fleet_request x
       set status = 'failed',
           outcome = format('claimed by the sweep%s at %s and never settled by its run; let go by %s when another '
                            'rename was asked for',
                            coalesce(' for run ' || x.run_id, ''),
                            to_char(coalesce(x.claimed_at, x.created_at) at time zone 'UTC',
                                    'FMDD Mon YYYY HH24:MI "UTC"'),
                            v.email),
           settled_at = now()
     where x.kind = 'rename' and x.status = 'claimed' and x.payload ->> 'code' = d.code
       and coalesce(x.claimed_at, x.created_at) < now() - interval '3 hours'
    returning x.id, x.payload ->> 'to' as to_address, coalesce(x.claimed_at, x.created_at) as claimed
  loop
    v_let := v_let || r.id;
    perform erp_meta.record_deployment_event(d.code, 'rename', 'note',
      format('a move to %s claimed by the sweep at %s was never settled by its run, and was let go by %s; it is '
             'served at %s', r.to_address, to_char(r.claimed at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"'),
             v.email, d.address));
  end loop;

  v_busy := case
    when d.status not in ('built', 'live', 'suspended')
      then format('it is %s, and only a built, live or suspended deployment is moved', d.status)
    when exists (select 1 from erp_meta.fleet_request x
                  where x.kind = 'rename' and x.status in ('requested', 'claimed')
                    and x.payload ->> 'code' = d.code)
      then 'a rename of it is already waiting or running'
    when v_new = d.address
      then format('it is served at %s already', v_new)
  end;
  if v_busy is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE: % is not moved: %', d.code, v_busy
      using errcode = '55000',
            hint = 'Rename a deployment that is built, live or suspended, to an address it does not have now, once '
                   'any rename it is waiting for has finished; one its run left unsettled for three hours is let '
                   'go. The Fleet view shows each one.';
  end if;

  -- Its own code, an address it was moved from, or one a rename of it was
  -- asked for before, whatever became of that rename, is its own to go to:
  -- held for it, so only its shape is asked about. That is how a mistaken
  -- rename is walked back, and how one that stopped part-way is asked for
  -- again. Anything else meets the rule an organisation's address and a new
  -- deployment's code meet: shape, reserved words, any organisation's
  -- address, and any deployment's code, address, earlier address, or an
  -- address a rename of one was asked for (20261012030000).
  v_had := v_new = d.code
           or exists (select 1 from erp_meta.deployment_previous_address pa
                       where pa.code = d.code and pa.address = v_new);
  v_own := v_had
           or exists (select 1 from erp_meta.fleet_request x
                       where x.kind = 'rename' and x.payload ->> 'code' = d.code and x.payload ->> 'to' = v_new);
  v_why := case
    when v_own and v_new !~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' then
      'CLOVEERP_ADDRESS_SHAPE: "' || v_new || '" is not an address: use three to 63 lower-case letters, digits and '
      || 'hyphens, starting and ending with a letter or digit'
    when v_own then null
    else erp.tenant_code_refusal(v_new, null)
  end;
  if v_why is not null then
    raise exception '%', v_why
      using errcode = '23514',
            hint = 'Choose another address: it becomes the client''s address, <address>.cloveerp.com, and an address '
                   'that is or was anybody else''s is not given again.';
  end if;

  insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
  values ('rename', jsonb_build_object('code', d.code, 'from', d.address, 'to', v_new), btrim(p_reason), v.id)
  returning id into v_req;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('a move from %s to %s%s asked for by %s: %s. The address moves once the client''s project is re-pointed; '
           'the old one then leads to the new one for ninety days and stays held for it.',
           d.address, v_new,
           case when v_had then ', an address it had,'
                when v_own then ', an address asked for it before,'
                else '' end,
           v.email, rtrim(btrim(p_reason), '.')));
  perform erp_meta.platform_log(v, 'platform.deployment_rename_requested', null, d.code, p_reason,
    jsonb_build_object('from', d.address, 'to', v_new, 'request_id', v_req, 'back_to_its_own', v_own,
                       'let_go_request_ids', to_jsonb(v_let)));

  return jsonb_build_object('code', d.code, 'status', d.status, 'address', d.address, 'to', v_new,
                            'request_id', v_req, 'let_go_request_ids', to_jsonb(v_let));
end;
$$;

revoke all on function public.erp_platform_rename_deployment(text, text, text) from public, anon;
grant execute on function public.erp_platform_rename_deployment(text, text, text) to authenticated, service_role;

comment on function public.erp_platform_rename_deployment(text, text, text) is
  'Asks for a built, live or suspended client deployment to be moved to a new address: queues a rename request '
  '{code, from, to} for the sweep, whose workflow re-points the client''s project and then moves the register''s '
  'address (erp_meta.finish_deployment_rename). The new address meets erp.tenant_code_refusal, which holds every '
  'address a deployment has, had, or was ever asked to be moved to — except the deployment''s own code, the '
  'addresses it was moved from and those a rename of it was asked for before, which are its own to go to. Refuses '
  'while a rename of it is waiting or running; one claimed three hours ago and never settled is let go first. '
  'Platform owner, on the control plane, with a reason (20261012030000).';

create or replace function erp_meta.finish_deployment_rename(p_code text, p_to text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d       erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_to    text := lower(btrim(coalesce(p_to, '')));
  v_apex  text := regexp_replace(erp.app_origin(), '^https://', '');
  v_until timestamptz := now() + interval '90 days';
  v_back  boolean;
begin
  perform pg_advisory_xact_lock(hashtext('erp_meta.deployment.address'));
  select * into d from erp_meta.deployment x where x.code = d.code for update;

  -- Run again after it finished, the workflow is told so and nothing moves.
  if d.address = v_to then
    return format('%s is served at %s already', d.code, v_to);
  end if;

  if d.status not in ('built', 'live', 'suspended', 'retiring') then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE: % is not moved: it is %', d.code, d.status
      using errcode = '55000',
            hint = 'Rename a deployment that is built, live or suspended, to an address it does not have now, once '
                   'any rename it is waiting for has finished; one its run left unsettled for three hours is let '
                   'go. The Fleet view shows each one.';
  end if;
  if v_to !~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' then
    raise exception 'CLOVEERP_ADDRESS_SHAPE: "%" is not an address: use three to 63 lower-case letters, digits and hyphens, starting and ending with a letter or digit', p_to
      using errcode = '22023',
            hint = 'Finish the rename with the address it was asked for, as the request names it.';
  end if;
  -- Another deployment's code or address, an address it was moved from, or
  -- one a rename of it was ever asked for, is held for it (20261012030000).
  if exists (select 1 from erp_meta.deployment x
              where x.code <> d.code and v_to in (x.code, x.address))
     or exists (select 1 from erp_meta.deployment_previous_address pa
                 where pa.address = v_to and pa.code <> d.code)
     or exists (select 1 from erp_meta.fleet_request r
                 where r.kind = 'rename' and r.payload ->> 'to' = v_to and r.payload ->> 'code' <> d.code)
     or exists (select 1 from erp.tenant t where t.code = v_to)
     or exists (select 1 from erp_meta.retired_tenant_code x where x.code = v_to) then
    raise exception 'CLOVEERP_ADDRESS_TAKEN: "%" is held by another deployment or organisation, so % is not moved to it', v_to, d.code
      using errcode = '23514',
            hint = 'Ask for another address from the Fleet view; the client''s project must be re-pointed to it again.';
  end if;

  -- Back at its own code or an address it was moved from, it is home again:
  -- that address is where it is served, not a way to it. The address it
  -- leaves is held for it for good and leads to the new one for ninety days;
  -- left again later, its ninety days start again (20261012030000).
  v_back := v_to = d.code
            or exists (select 1 from erp_meta.deployment_previous_address pa
                        where pa.address = v_to and pa.code = d.code);
  delete from erp_meta.deployment_previous_address pa
   where pa.address = v_to and pa.code = d.code;
  insert into erp_meta.deployment_previous_address as pa (address, code, moved_at, redirect_until)
  values (d.address, d.code, clock_timestamp(), v_until)
  on conflict (address) do update
     set moved_at = excluded.moved_at, redirect_until = excluded.redirect_until
   where pa.code = excluded.code;

  update erp_meta.deployment x
     set address = v_to, updated_at = now()
   where x.code = d.code;

  perform erp_meta.record_deployment_event(d.code, 'rename', 'done',
    format('moved from %s.%s to %s.%s%s; the old address leads to the new one until %s, and stays held for it',
           d.address, v_apex, v_to, v_apex, case when v_back then ', an address it had' else '' end,
           to_char(v_until at time zone 'UTC', 'FMDD Mon YYYY')));

  return format('%s moved from %s to %s', d.code, d.address, v_to);
end;
$$;

revoke all on function erp_meta.finish_deployment_rename(text, text) from public, anon, authenticated, service_role;

comment on function erp_meta.finish_deployment_rename(text, text) is
  'Called by the rename workflow once the client''s project answers at its new address: the register''s address '
  'moves to it, and the one it left is held for the deployment in erp_meta.deployment_previous_address, leading to '
  'the new one for ninety days (refreshed if it is left again); an address it moves back to is its own again and '
  'leaves that list. Says so and moves nothing when it is there already; refuses an address held by another '
  'deployment — its code, its address, one it was moved from, or one a rename of it was ever asked for — or by an '
  'organisation. Trusted build role only (20261012030000).';

create or replace function erp_meta.rename_client_organisation(p_to text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_to   text := lower(btrim(coalesce(p_to, '')));
  v_mine text;
  v_held text;
  v_n    integer;
  v_t    erp.tenant;
  v_why  text;
begin
  -- On a client's own deployment only, and only once it knows its new
  -- address: the rename workflow re-points its identity first
  -- (erp_meta.set_deployment_identity), so its organisation follows the
  -- address it is served at (20261012030000).
  if erp.deployment_kind() <> 'client' then
    raise exception 'CLOVEERP_CLIENT_ORGANISATION_CODE: this is the % deployment, not a client''s own, so its organisations are not renamed with a client', erp.deployment_kind()
      using errcode = '55000',
            hint = 'Rename a client from the Fleet view on the platform console at cloveerp.com: the rename re-points '
                   'the client''s own project first, then renames its organisation there.';
  end if;
  v_mine := erp.deployment_code();
  if v_mine is distinct from v_to then
    raise exception 'CLOVEERP_CLIENT_ORGANISATION_CODE: this deployment is served as %, so its organisation is not renamed %',
      coalesce(v_mine, 'an address it has not been told yet'), coalesce(nullif(v_to, ''), 'nothing')
      using errcode = '22023',
            hint = 'Re-point the deployment at its new address first, then rename its organisation to the part of '
                   'that address before the first dot.';
  end if;

  -- The lock an onboarding takes, so neither finds the other half done.
  perform pg_advisory_xact_lock(hashtext('erp.require_client_organisation'));
  select count(*), string_agg(t.code, ', ' order by t.code) into v_n, v_held
    from erp.tenant t
   where t.status not in ('deleting', 'deleted');
  if v_n = 0 then
    return jsonb_build_object('tenant_id', null, 'code', v_to, 'previous', null, 'changed', false);
  end if;
  if v_n > 1 then
    raise exception 'CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION: this deployment holds %, and a client''s own deployment holds one organisation', v_held
      using errcode = '55000',
            hint = 'Put the deployment back to its one organisation before it is renamed.';
  end if;
  select * into v_t from erp.tenant t where t.status not in ('deleting', 'deleted');
  if v_t.code = v_to then
    return jsonb_build_object('tenant_id', v_t.id, 'code', v_to, 'previous', null, 'changed', false);
  end if;

  v_why := erp.tenant_code_refusal(v_to, v_t.id);
  if v_why is not null then
    raise exception '%', v_why
      using errcode = '23514',
            hint = 'Choose another address for the client from the Fleet view; this one is held here already.';
  end if;

  -- The address it had is kept as its retired code by the trigger on the
  -- organisation, so nobody else here is given it.
  update erp.tenant t set code = v_to where t.id = v_t.id;

  insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, tenant_code, target, reason, detail)
  values ('system', 'platform', 'platform.tenant_address_changed', v_t.id, v_to, v_to,
          'Renamed with its deployment by the fleet''s rename.',
          jsonb_build_object('previous', v_t.code, 'code', v_to, 'by', 'the fleet''s rename'));

  return jsonb_build_object('tenant_id', v_t.id, 'code', v_to, 'previous', v_t.code, 'changed', true);
end;
$$;

revoke all on function erp_meta.rename_client_organisation(text) from public, anon, authenticated, service_role;

comment on function erp_meta.rename_client_organisation(text) is
  'On a client''s own deployment that already answers at the new address (erp.deployment_code() is p_to), renames '
  'its one organisation to it and records it in the platform log; nothing to do where it has no organisation yet '
  'or is named so already. Refuses anywhere else. Trusted build role only, called by the rename workflow '
  '(20261012030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The client's own organisation follows the register's suspension
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.follow_deployment_status(p_suspended boolean, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  -- Set while the organisation is suspended because the register says so,
  -- and only then: {"reason": why, "suspended_at": the moment the fleet
  -- suspended it}. A suspension somebody else made, before the fleet's or
  -- after it, is never lifted here: the organisation's suspended_at is then
  -- not the moment the marker keeps (20261012030000).
  c_marker constant text := 'deployment.suspended_by_fleet';
  v_reason text := coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'suspended in the register on the control plane');
  v_n      integer;
  v_held   text;
  v_t      erp.tenant;
  v_mark   jsonb;
  v_marked timestamptz;
  v_ours   boolean := false;
  v_at     timestamptz;
begin
  -- On a client's own deployment only: the control plane and the
  -- demonstration keep their organisations' status themselves
  -- (20261012030000).
  if erp.deployment_kind() <> 'client' then
    raise exception 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the % deployment, not a client''s own, so it does not follow the register''s suspension', erp.deployment_kind()
      using errcode = '55000',
            hint = 'Suspend or reinstate a client from the Fleet view on the platform console at cloveerp.com; its '
                   'own deployment follows when the status sync next runs.';
  end if;
  if p_suspended is null then
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: whether the client is suspended was not said, so its organisation is left as it is'
      using errcode = '22023',
            hint = 'Pass true when the register holds the client suspended, and false when it does not.';
  end if;

  -- The lock an onboarding takes, so the one organisation is the one found.
  perform pg_advisory_xact_lock(hashtext('erp.require_client_organisation'));
  select count(*), string_agg(t.code, ', ' order by t.code) into v_n, v_held
    from erp.tenant t
   where t.status not in ('deleting', 'deleted');
  if v_n > 1 then
    raise exception 'CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION: this deployment holds %, and a client''s own deployment holds one organisation', v_held
      using errcode = '55000',
            hint = 'Put the deployment back to its one organisation before its status is brought into line.';
  end if;
  select s.value into v_mark from erp_meta.platform_setting s where s.key = c_marker;
  if v_n = 0 then
    return jsonb_build_object('changed', false, 'status', null, 'by_fleet', v_mark is not null);
  end if;
  select * into v_t from erp.tenant t where t.status not in ('deleting', 'deleted') for update;

  -- The marker names the moment the fleet suspended it. An older one that
  -- keeps only a reason names no moment, and so matches no suspension.
  if jsonb_typeof(v_mark -> 'suspended_at') = 'string' then
    begin
      v_marked := (v_mark ->> 'suspended_at')::timestamptz;
    exception when data_exception then
      v_marked := null;
    end;
  end if;
  v_ours := v_t.status = 'suspended'::erp.tenant_status
            and v_marked is not null
            and v_t.suspended_at = v_marked;

  if p_suspended then
    if v_t.status = 'active'::erp.tenant_status then
      -- The clock, not the transaction's start, so a suspension made after
      -- this one is told apart from it even in the same transaction.
      v_at := clock_timestamp();
      update erp.tenant t
         set status = 'suspended'::erp.tenant_status, suspended_at = v_at, updated_at = now()
       where t.id = v_t.id;
      insert into erp_meta.platform_setting (key, value, reason, updated_at)
      values (c_marker, jsonb_build_object('reason', v_reason, 'suspended_at', v_at),
              'Written by the fleet''s status sync: the organisation is suspended because the register on the '
              'control plane holds the client suspended, and is reinstated when it no longer does, if the '
              'suspension is still the one made at suspended_at (20261012030000).',
              now())
      on conflict (key) do update
         set value = excluded.value, reason = excluded.reason, updated_at = excluded.updated_at, updated_by = null;
      insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, tenant_code, target, reason, detail)
      values ('system', 'platform', 'platform.tenant_status_changed', v_t.id, v_t.code, v_t.code, v_reason,
              jsonb_build_object('from', v_t.status::text, 'to', 'suspended', 'by', 'the fleet''s status sync'));
      return jsonb_build_object('changed', true, 'status', 'suspended', 'by_fleet', true);
    end if;
    -- Suspended by the fleet already: its reason may have changed, its
    -- moment has not.
    if v_ours then
      update erp_meta.platform_setting s
         set value = jsonb_set(s.value, '{reason}', to_jsonb(v_reason)), updated_at = now(), updated_by = null
       where s.key = c_marker;
      return jsonb_build_object('changed', false, 'status', v_t.status::text, 'by_fleet', true);
    end if;
    -- Suspended by somebody else, or not trading: left as it is, and a
    -- marker that no longer names its suspension is taken away.
    delete from erp_meta.platform_setting s where s.key = c_marker;
    return jsonb_build_object('changed', false, 'status', v_t.status::text, 'by_fleet', false);
  end if;

  -- Not suspended in the register: only the fleet's own suspension is lifted,
  -- and only while it is still the one the fleet made.
  if v_mark is null then
    return jsonb_build_object('changed', false, 'status', v_t.status::text, 'by_fleet', false);
  end if;
  delete from erp_meta.platform_setting s where s.key = c_marker;
  if v_ours then
    update erp.tenant t
       set status = 'active'::erp.tenant_status, suspended_at = null, updated_at = now()
     where t.id = v_t.id;
    insert into erp_meta.platform_audit (actor_email, actor_role, action, tenant_id, tenant_code, target, reason, detail)
    values ('system', 'platform', 'platform.tenant_status_changed', v_t.id, v_t.code, v_t.code,
            'reinstated in the register on the control plane',
            jsonb_build_object('from', 'suspended', 'to', 'active', 'by', 'the fleet''s status sync'));
    return jsonb_build_object('changed', true, 'status', 'active', 'by_fleet', false);
  end if;
  return jsonb_build_object('changed', false, 'status', v_t.status::text, 'by_fleet', false);
end;
$$;

revoke all on function erp_meta.follow_deployment_status(boolean, text) from public, anon, authenticated, service_role;

comment on function erp_meta.follow_deployment_status(boolean, text) is
  'On a client''s own deployment, brings its one organisation into line with the register on the control plane: '
  'suspended (p_suspended true), an active organisation is suspended and the platform setting '
  'deployment.suspended_by_fleet keeps the reason and the moment it was suspended; one suspended by anybody else is '
  'left alone. Not suspended, only a suspension that setting marks, and still at the moment it keeps, is lifted; '
  'one made by anybody else after it is left, and the setting removed. Returns {changed, status, by_fleet}; logged '
  'as the system. Refuses anywhere but a client with CLOVEERP_NOT_A_CLIENT_DEPLOYMENT. Trusted build role only, '
  'called by the status sync (fleet_sync.yml) (20261012030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Offboarded, and exported
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_begin_offboarding(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v        erp_meta.platform_staff;
  d        erp_meta.deployment;
  v_last   erp_meta.deployment_event;
  v_end    date;
  v_due    timestamptz;
  v_req    uuid;
  v_queued boolean := false;
  v_builds integer := 0;
  v_stale  integer := 0;
  v_let    uuid[] := '{}'::uuid[];
  v_before erp_meta.fleet_request;
  r        record;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: offboarding a client deployment needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say why the client is leaving and what was agreed about its data; it is kept in the platform''s '
                   'activity log. At least twenty characters.';
  end if;

  select * into d from erp_meta.deployment x where x.code = d.code for update;
  -- A build the sweep has started reads requested until its run begins: its
  -- request is claimed, and its newest step of a build is the dispatch done.
  -- A build only waiting in the queue has not started, whatever the sweep
  -- noted about why it waits, and is cancelled below. A claim counts as a
  -- start for ninety minutes, as the dispatch does: the sweep starts the run
  -- within minutes of claiming it, so a claim older than that is one the
  -- sweep died holding, and its build never started; it is let go below
  -- rather than holding the offboarding back for good (20261012030000).
  select * into v_last
    from erp_meta.deployment_event e
   where e.code = d.code and e.phase in ('dispatch', 'create', 'build')
     and not (e.phase = 'dispatch' and e.status = 'note')
   order by e.at desc, e.id desc
   limit 1;
  if d.status not in ('requested', 'failed', 'built', 'live', 'suspended')
     or (d.status = 'requested'
         and (exists (select 1 from erp_meta.fleet_request x
                       where x.kind = 'build' and x.status = 'claimed' and x.payload ->> 'code' = d.code
                         and coalesce(x.claimed_at, x.created_at) > now() - interval '90 minutes')
              or (v_last.phase = 'dispatch' and v_last.status = 'done'
                  and v_last.at > now() - interval '90 minutes'))) then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE: % is not offboarded: %', d.code,
      case when d.status in ('creating', 'building') then format('it is %s, and its build is running', d.status)
           when d.status = 'requested' then 'its build has been started and has not yet begun'
           when d.status = 'retiring' then 'it is being offboarded already'
           else format('it is %s', d.status) end
      using errcode = '55000',
            hint = 'Wait for the build to finish or fail, then begin its offboarding. One being offboarded already is '
                   'shown with its purge date in the Fleet view, where its offboarding may also be cancelled.';
  end if;

  -- Thirty days after the term of a contract in force for it ends, or thirty
  -- days from now when there is none or it has ended (20261012030000).
  select max(c.current_term_end) into v_end
    from erp_meta.contract c
   where c.deployment_code = d.code
     and c.status in ('active', 'terminating');
  v_due := greatest(now(), v_end::timestamptz) + interval '30 days';

  -- A suspension is kept: the client stays suspended while it is offboarded.
  update erp_meta.deployment x
     set status = 'retiring', offboarding_at = now(), purge_due_at = v_due, updated_at = now()
   where x.code = d.code;

  -- A build still waiting would build what is leaving.
  update erp_meta.fleet_request x
     set status = 'cancelled', outcome = 'the deployment''s offboarding began', settled_at = now()
   where x.status = 'requested'
     and x.kind = 'build'
     and x.payload ->> 'code' = d.code;
  get diagnostics v_builds = row_count;

  -- And a build the sweep claimed over ninety minutes ago and never started
  -- is let go: no run of it is coming, and nothing else would ever settle
  -- it (20261012030000).
  for r in
    update erp_meta.fleet_request x
       set status = 'failed',
           outcome = format('claimed by the sweep%s at %s and never started; let go by %s when the deployment''s '
                            'offboarding began',
                            coalesce(' for run ' || x.run_id, ''),
                            to_char(coalesce(x.claimed_at, x.created_at) at time zone 'UTC',
                                    'FMDD Mon YYYY HH24:MI "UTC"'),
                            v.email),
           settled_at = now()
     where x.kind = 'build' and x.status = 'claimed' and x.payload ->> 'code' = d.code
       and coalesce(x.claimed_at, x.created_at) <= now() - interval '90 minutes'
    returning x.id
  loop
    v_let := v_let || r.id;
    v_stale := v_stale + 1;
  end loop;

  -- An export the sweep claimed and whose run never settled it is let go:
  -- fleet_export.yml gives up after three hours, so one claimed four hours
  -- ago has no run left to settle it, and would otherwise stand for the copy
  -- this offboarding asks for (20261012030000).
  for r in
    update erp_meta.fleet_request x
       set status = 'failed',
           outcome = format('claimed by the sweep%s at %s and never settled by its run; let go by %s when the '
                            'deployment''s offboarding began',
                            coalesce(' for run ' || x.run_id, ''),
                            to_char(coalesce(x.claimed_at, x.created_at) at time zone 'UTC',
                                    'FMDD Mon YYYY HH24:MI "UTC"'),
                            v.email),
           settled_at = now()
     where x.kind = 'export' and x.status = 'claimed' and x.payload ->> 'code' = d.code
       and coalesce(x.claimed_at, x.created_at) < now() - interval '4 hours'
    returning x.id, coalesce(x.claimed_at, x.created_at) as claimed
  loop
    v_let := v_let || r.id;
    perform erp_meta.record_deployment_event(d.code, 'export', 'note',
      format('a copy of its database claimed by the sweep at %s was never settled by its run, and was let go by %s '
             'when its offboarding began', to_char(r.claimed at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"'),
             v.email));
  end loop;

  -- A copy of its database if it ever had one, unless one is already waiting.
  -- One a run is already writing was claimed before this offboarding began,
  -- so its copy can never be the last one (the retire door asks for a copy
  -- taken since offboarding began): it carries on and is recorded, and a new
  -- one is queued beside it (20261012030000).
  if d.built_at is not null then
    select x.id into v_req
      from erp_meta.fleet_request x
     where x.kind = 'export' and x.payload ->> 'code' = d.code
       and x.status = 'requested'
     order by x.created_at desc
     limit 1;
    if v_req is null then
      select * into v_before
        from erp_meta.fleet_request x
       where x.kind = 'export' and x.status = 'claimed' and x.payload ->> 'code' = d.code
       order by coalesce(x.claimed_at, x.created_at) desc
       limit 1;
      insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
      values ('export', jsonb_build_object('code', d.code), btrim(p_reason), v.id)
      returning id into v_req;
      v_queued := true;
    end if;
  end if;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('offboarding begun by %s (was %s%s): %s. Its project may be purged from %s, %s; %s%s.',
           v.email, d.status,
           case when d.suspended_reason is not null then ', and it stays suspended' else '' end,
           rtrim(btrim(p_reason), '.'),
           to_char(v_due at time zone 'UTC', 'FMDD Mon YYYY'),
           case when v_end is not null and v_end::timestamptz > now()
                then format('thirty days after its contract''s term ends on %s', to_char(v_end, 'FMDD Mon YYYY'))
                else 'thirty days from now' end,
           case when d.built_at is null then 'it was never built, so there is no database to copy'
                when v_queued and v_before.id is not null
                  then format('a copy of its database is asked for, beside the one claimed at %s before its '
                              'offboarding began, which carries on',
                              to_char(coalesce(v_before.claimed_at, v_before.created_at) at time zone 'UTC',
                                      'FMDD Mon YYYY HH24:MI "UTC"'))
                when v_queued then 'a copy of its database is asked for'
                else 'a copy of its database is already waiting or being written' end,
           case when v_builds > 0 then '; the build waiting for it is cancelled' else '' end
           || case when v_stale > 0 then '; the build the sweep claimed and never started is let go' else '' end));
  perform erp_meta.platform_log(v, 'platform.deployment_offboarding_begun', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'purge_due_at', v_due, 'contract_term_end', v_end,
                       'export_request_id', v_req, 'export_queued', v_queued, 'builds_cancelled', v_builds,
                       'builds_let_go', v_stale, 'suspended_reason', d.suspended_reason,
                       'let_go_request_ids', to_jsonb(v_let), 'export_beside_request_id', v_before.id));

  return jsonb_build_object('code', d.code, 'status', 'retiring', 'was', d.status, 'offboarding_at', now(),
                            'purge_due_at', v_due, 'contract_term_end', v_end,
                            'export_asked', d.built_at is not null, 'export_queued', v_queued,
                            'export_request_id', v_req, 'builds_cancelled', v_builds, 'builds_let_go', v_stale,
                            'suspended_reason', d.suspended_reason, 'let_go_request_ids', to_jsonb(v_let),
                            'export_beside_request_id', v_before.id);
end;
$$;

revoke all on function public.erp_platform_begin_offboarding(text, text) from public, anon;
grant execute on function public.erp_platform_begin_offboarding(text, text) to authenticated, service_role;

comment on function public.erp_platform_begin_offboarding(text, text) is
  'Begins the offboarding of a client deployment that is requested, failed, built, live or suspended, and whose '
  'build is not running or started (claimed or dispatched in the last ninety minutes; one only waiting in the queue '
  'is cancelled, and a claim older than that, whose build never started, is let go): it is retiring, and still '
  'served if it was built and is not suspended (a suspension is kept); when it began is kept; its purge is due thirty '
  'days after the term of a contract in force for it ends (or thirty days from now); an export claimed four hours '
  'ago and never settled by its run is let go; and, if it was ever built, an export of its database is asked for '
  'unless one is waiting, or was claimed while its service was not stopped or since it stopped (one claimed before '
  'its service stopped carries on beside the new one). Platform owner, on the control plane, with a reason '
  '(20261012030000).';

create or replace function public.erp_platform_cancel_offboarding(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v    erp_meta.platform_staff;
  d    erp_meta.deployment;
  v_to text;
begin
  v := erp_meta.require_platform('owner');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: cancelling a client deployment''s offboarding needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say why the client is staying and who agreed it; it is kept in the platform''s activity log. At '
                   'least twenty characters.';
  end if;

  select * into d from erp_meta.deployment x where x.code = d.code for update;
  if d.status <> 'retiring' then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDING: % is not taken back from offboarding: it is %, not being offboarded', d.code, d.status
      using errcode = '55000',
            hint = 'Cancel the offboarding of a deployment the Fleet view shows as being offboarded, before it is '
                   'retired.';
  end if;

  -- Back as it was: suspended if it is suspended; failed if it was never
  -- built; live if a release to it ever succeeded; built if none has
  -- (20261012030000).
  v_to := case
    when d.suspended_reason is not null then 'suspended'
    when d.built_at is null then 'failed'
    when exists (select 1 from erp_meta.deployment_event e
                  where e.code = d.code and e.phase = 'release' and e.status = 'done') then 'live'
    else 'built'
  end;
  update erp_meta.deployment x
     set status = v_to, purge_due_at = null, offboarding_at = null, updated_at = now()
   where x.code = d.code;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('offboarding cancelled by %s (now %s): %s. Its project is no longer due to be purged on %s%s.',
           v.email, v_to, rtrim(btrim(p_reason), '.'),
           to_char(d.purge_due_at at time zone 'UTC', 'FMDD Mon YYYY'),
           case v_to
             when 'suspended' then format('; it stays suspended because: %s', rtrim(d.suspended_reason, '.'))
             when 'failed' then '; it was never built, so retry its build from the Fleet view'
             else '' end));
  perform erp_meta.platform_log(v, 'platform.deployment_offboarding_cancelled', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'status', v_to, 'purge_due_at_was', d.purge_due_at,
                       'offboarding_at_was', d.offboarding_at));

  return jsonb_build_object('code', d.code, 'status', v_to, 'was', d.status,
                            'suspended_reason', d.suspended_reason, 'purge_due_at_was', d.purge_due_at);
end;
$$;

revoke all on function public.erp_platform_cancel_offboarding(text, text) from public, anon;
grant execute on function public.erp_platform_cancel_offboarding(text, text) to authenticated, service_role;

comment on function public.erp_platform_cancel_offboarding(text, text) is
  'Cancels a client deployment''s offboarding before it is retired: back to suspended if it is suspended, failed if '
  'it was never built, live if a release to it ever succeeded, built otherwise; its purge date and when its '
  'offboarding began are cleared. Platform owner, on the control plane, with a reason (20261012030000).';

create or replace function public.erp_platform_request_export(p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v        erp_meta.platform_staff;
  d        erp_meta.deployment;
  r        erp_meta.fleet_request;
  v_before erp_meta.fleet_request;
  rl       record;
  v_req    uuid;
  v_queued boolean := false;
  v_let    uuid[] := '{}'::uuid[];
begin
  v := erp_meta.require_platform('operator');
  perform erp.require_control_plane();
  d := erp_meta.deployment_row(p_code);

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: copying a client''s database needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say who asked for the copy and what it is for; it is kept in the platform''s activity log. At '
                   'least twenty characters.';
  end if;

  select * into d from erp_meta.deployment x where x.code = d.code for update;
  -- Up, and built once: one offboarded before its build finished has no
  -- database (20261012030000).
  if d.status not in ('built', 'live', 'suspended', 'retiring') or d.built_at is null then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_EXPORTABLE: % is not copied: %', d.code,
      case when d.status in ('built', 'live', 'suspended', 'retiring')
           then format('it is %s and was never built, so there is no database to copy', d.status)
           else format('it is %s', d.status) end
      using errcode = '55000',
            hint = 'Ask for an export of a deployment that was built and is built, live, suspended or being '
                   'offboarded.';
  end if;

  -- An export the sweep claimed and whose run never settled it is let go:
  -- fleet_export.yml gives up after three hours, so one claimed four hours
  -- ago has no run left to settle it, and would otherwise stand for this one
  -- for ever. Its late word is refused, as a let-go rename's is
  -- (erp_meta.settle_fleet_request) (20261012030000).
  for rl in
    update erp_meta.fleet_request x
       set status = 'failed',
           outcome = format('claimed by the sweep%s at %s and never settled by its run; let go by %s when another '
                            'export was asked for',
                            coalesce(' for run ' || x.run_id, ''),
                            to_char(coalesce(x.claimed_at, x.created_at) at time zone 'UTC',
                                    'FMDD Mon YYYY HH24:MI "UTC"'),
                            v.email),
           settled_at = now()
     where x.kind = 'export' and x.status = 'claimed' and x.payload ->> 'code' = d.code
       and coalesce(x.claimed_at, x.created_at) < now() - interval '4 hours'
    returning x.id, coalesce(x.claimed_at, x.created_at) as claimed
  loop
    v_let := v_let || rl.id;
    perform erp_meta.record_deployment_event(d.code, 'export', 'note',
      format('a copy of its database claimed by the sweep at %s was never settled by its run, and was let go by %s '
             'when another was asked for', to_char(rl.claimed at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"'),
             v.email));
  end loop;

  -- One waiting stands for this one, and so does one being written by a run
  -- the sweep claimed since the client's service stopped and its offboarding
  -- began, or while neither had happened. One claimed before either may have
  -- dumped its data while its people could still change it, or before the
  -- moment the retire door counts from, so it does not stand for a copy asked
  -- for now: it carries on and is recorded, and a new one is queued beside it
  -- (20261012030000).
  select * into r
    from erp_meta.fleet_request x
   where x.kind = 'export' and x.payload ->> 'code' = d.code
     and (x.status = 'requested'
          or (x.status = 'claimed'
              and coalesce(x.claimed_at, x.created_at)
                    >= coalesce(greatest(d.suspended_at, d.offboarding_at), '-infinity'::timestamptz)))
   order by x.created_at desc
   limit 1;
  if r.id is null then
    select * into v_before
      from erp_meta.fleet_request x
     where x.kind = 'export' and x.status = 'claimed' and x.payload ->> 'code' = d.code
     order by coalesce(x.claimed_at, x.created_at) desc
     limit 1;
    insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
    values ('export', jsonb_build_object('code', d.code), btrim(p_reason), v.id)
    returning id into v_req;
    v_queued := true;
  else
    v_req := r.id;
  end if;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('a copy of its database asked for by %s: %s. %s', v.email, rtrim(btrim(p_reason), '.'),
           case when v_queued and v_before.id is not null
                  then format('The export workflow writes it, encrypted, off the platform, beside the one claimed at '
                              '%s before its service stopped or its offboarding began, which carries on.',
                              to_char(coalesce(v_before.claimed_at, v_before.created_at) at time zone 'UTC',
                                      'FMDD Mon YYYY HH24:MI "UTC"'))
                when v_queued then 'The export workflow writes it, encrypted, off the platform.'
                else format('One asked for at %s is %s, so no other is.',
                            to_char(r.created_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"'),
                            case r.status when 'claimed' then 'being written' else 'still waiting' end) end));
  perform erp_meta.platform_log(v, 'platform.deployment_export_requested', null, d.code, p_reason,
    jsonb_build_object('request_id', v_req, 'queued', v_queued, 'let_go_request_ids', to_jsonb(v_let),
                       'beside_request_id', v_before.id));

  return jsonb_build_object('code', d.code, 'status', d.status, 'request_id', v_req, 'queued', v_queued,
                            'let_go_request_ids', to_jsonb(v_let), 'beside_request_id', v_before.id);
end;
$$;

revoke all on function public.erp_platform_request_export(text, text) from public, anon;
grant execute on function public.erp_platform_request_export(text, text) to authenticated, service_role;

comment on function public.erp_platform_request_export(text, text) is
  'Asks for a copy of the database of a client deployment that was built and is built, live, suspended or being '
  'offboarded, encrypted and written off the platform by the export workflow; returns the request waiting, or one '
  'claimed while its service was not stopped or since it stopped, instead of queueing a second, once one claimed '
  'four hours ago and never settled by its run is let go. One claimed before its service stopped carries on beside '
  'the new one (beside_request_id). Platform operator and above, on the control plane, with a reason '
  '(20261012030000).';

create or replace function erp_meta.record_deployment_export(p_code text, p_object text, p_bytes bigint,
                                                             p_sha256 text, p_taken_at timestamptz,
                                                             p_service_stopped boolean)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d        erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_object text := btrim(coalesce(p_object, ''));
  v_sha    text := lower(btrim(coalesce(p_sha256, '')));
  v_stop   boolean := coalesce(p_service_stopped, false);
  v_fault  text;
  v_newest boolean;
begin
  -- Where the copy went, for this client; how big it is; its fingerprint;
  -- and when its dump began, which is the moment its data is from: never
  -- after it is recorded (20261012030000).
  v_fault := case
    when length(v_object) > 300 or v_object !~ ('^exports/' || d.code || '/[A-Za-z0-9._:-]+\.dump\.age$')
      then format('"%s" is not a place this client''s copies are written', v_object)
    when p_bytes is null or p_bytes <= 0
      then 'its size is not a number of bytes above none'
    when v_sha !~ '^[0-9a-f]{64}$'
      then 'its fingerprint is not a sha256 in hexadecimal'
    when p_taken_at is null
      then 'it does not say when its dump began'
    when p_taken_at > now()
      then format('it says its dump began at %s, after it was recorded',
                  to_char(p_taken_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"'))
  end;
  if v_fault is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_EXPORT_INVALID: the copy of % is not recorded: %', d.code, v_fault
      using errcode = '22023',
            hint = 'Record the copy with the place it was written for that client, its size, its fingerprint, and '
                   'when its dump began by the control plane''s clock, as the export workflow reads them.';
  end if;

  -- The row keeps the newest copy: one recorded late whose dump began before
  -- the copy it holds does not replace it, so a copy begun while the client
  -- was served never stands for one begun after its service stopped. When it
  -- was recorded is kept as before; when it was taken, and whether the
  -- client's own organisation was confirmed suspended first, beside it.
  select (x.last_export_taken_at is null or p_taken_at >= x.last_export_taken_at) into v_newest
    from erp_meta.deployment x where x.code = d.code for update;
  if v_newest then
    update erp_meta.deployment x
       set last_export_at = now(), last_export_object = v_object, last_export_taken_at = p_taken_at,
           last_export_service_stopped = v_stop
     where x.code = d.code;
  end if;

  perform erp_meta.record_deployment_event(d.code, 'export', 'done',
    format('a copy of its database whose dump began at %s, %s, was written to %s: %s bytes, sha256 %s%s',
           to_char(p_taken_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"'),
           case when v_stop then 'with its own organisation confirmed suspended'
                else 'without its own organisation confirmed suspended' end,
           v_object, p_bytes, v_sha,
           case when v_newest then ''
                else '; a copy whose dump began later is recorded already, and stays its last' end));

  return format('%s: copy recorded at %s%s', d.code, v_object,
                case when v_newest then ''
                     else '; its dump began before that of the copy already recorded, which stays the last' end);
end;
$$;

revoke all on function erp_meta.record_deployment_export(text, text, bigint, text, timestamptz, boolean) from public, anon, authenticated, service_role;

comment on function erp_meta.record_deployment_export(text, text, bigint, text, timestamptz, boolean) is
  'Called by the export workflow once a copy of a client''s database is written off the platform: keeps on its row '
  'when it was recorded, where it went (exports/<code>/<time>.dump.age), when its dump began by the control plane''s '
  'clock (p_taken_at, never after now) and whether the client''s own organisation was confirmed suspended before '
  'it (p_service_stopped), unless the row already holds a copy whose dump began later; and records the step with '
  'its size and sha256. Refuses anything else with CLOVEERP_DEPLOYMENT_EXPORT_INVALID. Trusted build role only '
  '(20261012030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The doors' standing
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_suspend_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Marks one built, live or offboarding '
   'client deployment suspended with the reason given, queues a status sync, and writes the step and the platform '
   'audit row.'),
  ('public', 'erp_platform_reinstate_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Lifts one client deployment''s '
   'suspension, queues a status sync, and writes the step and the platform audit row.'),
  ('public', 'erp_platform_rename_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Queues one rename request for the '
   'sweep after erp.tenant_code_refusal, letting go of one its run left unsettled for three hours, and writes the '
   'step and the platform audit row; the address itself moves only when the trusted workflow finishes it.'),
  ('public', 'erp_platform_begin_offboarding',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Marks one client deployment retiring '
   'with its purge date, cancels its waiting build, lets go a build claim the sweep never started and an export its '
   'run left unsettled for four hours, queues an export request if it was built, and writes the step and the '
   'platform audit row.'),
  ('public', 'erp_platform_cancel_offboarding',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Puts one client deployment being '
   'offboarded back as it was and clears its purge date, and writes the step and the platform audit row.'),
  ('public', 'erp_platform_request_export',
   'Platform operator door, gated by erp_meta.require_platform(''operator'') and erp.require_control_plane() on its '
   'first lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Lets go an export its run left '
   'unsettled for four hours, queues one export request for the sweep unless one is waiting, or being written by a '
   'run claimed while the client''s service was not stopped or since it stopped, and writes the step and the '
   'platform audit row.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_suspend_deployment', 'erp_meta.require_platform',
   'Suspends a client deployment''s service at its address and asks for its organisation to follow; platform owner, '
   'with a reason kept in the activity log.'),
  ('erp_platform_reinstate_deployment', 'erp_meta.require_platform',
   'Gives a suspended client deployment its service back and asks for its organisation to follow; platform owner, '
   'with a reason kept in the activity log.'),
  ('erp_platform_rename_deployment', 'erp_meta.require_platform',
   'Asks for a client deployment to be moved to a new address; platform owner, with a reason kept in the activity log.'),
  ('erp_platform_begin_offboarding', 'erp_meta.require_platform',
   'Begins a client deployment''s offboarding, its purge date and its export; platform owner, with a reason kept in '
   'the activity log.'),
  ('erp_platform_cancel_offboarding', 'erp_meta.require_platform',
   'Cancels a client deployment''s offboarding and its purge date; platform owner, with a reason kept in the '
   'activity log.'),
  ('erp_platform_request_export', 'erp_meta.require_platform',
   'Asks for a copy of a client deployment''s database; platform operator and above, with a reason kept in the '
   'activity log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.platform_door_rank (schema_name, function_name, minimum_role, why) values
  ('public', 'erp_platform_suspend_deployment', 'owner',
   'Stops a paying client''s service at its address; whether to is the owner''s to judge.'),
  ('public', 'erp_platform_reinstate_deployment', 'owner',
   'Gives a suspended client its service back; the owner suspended it, and the owner decides it comes back.'),
  ('public', 'erp_platform_rename_deployment', 'owner',
   'Moves where a client and its people sign in, and re-points its project; the owner''s to decide.'),
  ('public', 'erp_platform_begin_offboarding', 'owner',
   'Starts the end of a client''s service and sets the day its data is deleted; the owner''s alone.'),
  ('public', 'erp_platform_cancel_offboarding', 'owner',
   'Takes back the end of a client''s service the owner began; the owner''s alone.')
on conflict (schema_name, function_name, minimum_role) do update set why = excluded.why;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.deployment_lifecycle_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 38;
  -- The register's own word, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired  constant text := 'retired';
  c_reason   constant text := 'The lifecycle suite asks for this, and undoes it.';
  c_marker   constant text := 'deployment.suspended_by_fleet';
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_uid      uuid := gen_random_uuid();
  v_role     text := current_user;
  v_owner    text;
  v_apex     text;
  v_live     text;
  v_built    text;
  v_req      text;
  v_bld      text;
  v_dsp      text;
  v_fail     text;
  v_con      text;
  v_bare     text;
  v_exp      text;
  v_wait     text;
  v_clm      text;
  v_stale    text;
  v_pcode    text;
  v_client   text;
  v_fly      text;
  v_opx      text;
  v_rel      text;
  v_rlo      text;
  v_mark     jsonb;
  v_dirf     jsonb;
  v_b2       uuid;
  v_b3       uuid;
  v_x1       uuid;
  v_x2       uuid;
  v_x3       uuid;
  v_f1       uuid;
  v_f2       uuid;
  v_o1       uuid;
  v_o2       uuid;
  v_platform uuid;
  v_ccon     uuid;
  v_cexp     uuid;
  v_cfail    uuid;
  v_tenant   uuid;
  v_end      date := current_date + 200;
  v_fend     date := current_date + 100;
  rp         record;
  v_json     jsonb;
  v_json2    jsonb;
  v_json3    jsonb;
  v_row      jsonb;
  v_row2     jsonb;
  v_row3     jsonb;
  v_claim    jsonb;
  v_got      text;
  v_got2     text;
  v_got3     text;
  v_bad      text;
  v_who      text[];
  v_sql      text[];
  v_want     text[];
  v_n        integer;
  v_n2       integer;
  v_n3       integer;
  v_b1       uuid;
  v_s1       uuid;
  v_s2       uuid;
  v_e1       uuid;
  v_e2       uuid;
  v_p1       uuid;
  v_p2       uuid;
  v_rn       uuid;
  v_i1       uuid;
  v_i2       uuid;
  v_m1       uuid;
  v_m2       uuid;
  v_step     text := 'standing up an owner on the control plane';
  v_state    text;
begin
  begin
    v_owner  := 'owner@zzlcy-' || v_tag || '.test';
    v_live   := 'zzlcl-' || v_tag;
    v_built  := 'zzlcb-' || v_tag;
    v_req    := 'zzlcq-' || v_tag;
    v_bld    := 'zzlcg-' || v_tag;
    v_dsp    := 'zzlcd-' || v_tag;
    v_fail   := 'zzlcf-' || v_tag;
    v_con    := 'zzlcc-' || v_tag;
    v_bare   := 'zzlcn-' || v_tag;
    v_exp    := 'zzlce-' || v_tag;
    v_wait   := 'zzlcw-' || v_tag;
    v_clm    := 'zzlcm-' || v_tag;
    v_stale  := 'zzlcs-' || v_tag;
    v_pcode  := 'zzlcp-' || v_tag;
    v_client := 'zzlck-' || v_tag;
    v_fly    := 'zzlct-' || v_tag;
    v_opx    := 'zzlca-' || v_tag;
    v_rel    := 'zzlcr-' || v_tag;
    v_rlo    := 'zzlco-' || v_tag;
    insert into auth.users (id, email, email_confirmed_at) values (v_uid, v_owner, now());
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Deployment Lifecycle Suite Owner', 'owner');
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin', c_marker);
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'deployment_lifecycle_suite');
    v_apex := regexp_replace(erp.app_origin(), '^https://', '');
    -- Older open requests would be claimed first; they wait out the suite.
    update erp_meta.fleet_request x set status = 'cancelled', settled_at = now()
     where x.status in ('requested', 'claimed');

    -- The platform's organisation, which the contracts and their mail are from.
    v_step := 'standing up the platform organisation';
    perform set_config('request.jwt.claims', '', true);
    select * into rp from erp.provision_tenant(v_pcode, 'Lifecycle Platform Ltd', 'admin@' || v_pcode || '.test', 'Platform Admin');
    v_platform := rp.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    perform erp.designate_platform_organisation(v_pcode, 'The lifecycle suite sells from its own organisation, and undoes it.');

    v_step := 'registering sixteen client deployments and three contracts';
    insert into erp_meta.deployment (code, client_name, status, owner_email, project_ref, api_url, publishable_key, built_at)
    select y.code, y.name, y.status, 'admin@' || y.code || '.test', substr(md5(y.code), 1, 20),
           'https://' || substr(md5(y.code), 1, 20) || '.supabase.co', 'sb_publishable_' || replace(y.code, '-', ''),
           now() - interval '3 days'
      from (values (v_live, 'Lifecycle Live Ltd', 'live'), (v_built, 'Lifecycle Built Ltd', 'built'),
                   (v_con, 'Lifecycle Contract Ltd', 'live'), (v_bare, 'Lifecycle Bare Ltd', 'live'),
                   (v_exp, 'Lifecycle Export Ltd', 'live'), (v_stale, 'Lifecycle Stale Ltd', 'live'),
                   (v_fly, 'Lifecycle Flight Ltd', 'live'), (v_opx, 'Lifecycle Operator Ltd', 'live'),
                   (v_rel, 'Lifecycle Release Ltd', 'live'), (v_rlo, 'Lifecycle Released Ltd', 'live'))
           as y(code, name, status);
    -- Never built: one waiting for its build, one being built, one whose
    -- build the sweep has just started, one whose build failed, one whose
    -- build waits behind another's, and one whose build the sweep claimed.
    insert into erp_meta.deployment (code, client_name, status, owner_email)
    select y.code, y.name, y.status, 'admin@' || y.code || '.test'
      from (values (v_req, 'Lifecycle Requested Ltd', 'requested'), (v_bld, 'Lifecycle Building Ltd', 'building'),
                   (v_dsp, 'Lifecycle Dispatched Ltd', 'requested'), (v_fail, 'Lifecycle Failed Ltd', 'failed'),
                   (v_wait, 'Lifecycle Waiting Ltd', 'requested'), (v_clm, 'Lifecycle Claimed Ltd', 'requested'))
           as y(code, name, status);
    -- The failed build got as far as registering its project, as a build
    -- does before it replays a single migration.
    update erp_meta.deployment x
       set project_ref = substr(md5(x.code), 1, 20), api_url = 'https://' || substr(md5(x.code), 1, 20) || '.supabase.co',
           publishable_key = 'sb_publishable_' || replace(x.code, '-', '')
     where x.code = v_fail;
    insert into erp_meta.fleet_request (kind, payload, reason)
    values ('build', jsonb_build_object('code', v_req), 'deployment_lifecycle_suite')
    returning id into v_b1;
    perform erp_meta.record_deployment_event(v_dsp, 'dispatch', 'done', 'claimed by the sweep', 'run-' || v_tag || '-d');
    insert into erp_meta.fleet_request (kind, payload, reason)
    values ('build', jsonb_build_object('code', v_wait), 'deployment_lifecycle_suite')
    returning id into v_b2;
    perform erp_meta.record_deployment_event(v_wait, 'dispatch', 'note',
      'waiting: another deployment is being built; this build starts at the first sweep after that one ends');
    insert into erp_meta.fleet_request (kind, payload, reason, status, run_id, claimed_at)
    values ('build', jsonb_build_object('code', v_clm), 'deployment_lifecycle_suite', 'claimed', 'run-' || v_tag || '-m',
            now() - interval '1 hour')
    returning id into v_b3;
    insert into erp_meta.contract (tenant_id, tenant_code, deployment_code, platform_tenant_id, quote_document_id,
      quote_number, quote_version, customer_legal_name, platform_legal_name, plan_code, term_kind, currency,
      commencement, initial_term_months, current_term_start, current_term_end, governing_law, status, signed_at,
      created_by)
    values (null, v_con, v_con, v_platform, gen_random_uuid(), 'QT-LCC-' || v_tag, 1, 'Lifecycle Contract Ltd',
            'Lifecycle Platform Ltd', 'standard', 'annual', 'GBP', current_date - 165, 12, current_date - 165, v_end,
            'England and Wales', 'active', now(), v_owner)
    returning id into v_ccon;
    insert into erp_meta.contract (tenant_id, tenant_code, deployment_code, platform_tenant_id, quote_document_id,
      quote_number, quote_version, customer_legal_name, platform_legal_name, plan_code, term_kind, currency,
      commencement, initial_term_months, current_term_start, current_term_end, governing_law, status, signed_at,
      created_by)
    values (null, v_exp, v_exp, v_platform, gen_random_uuid(), 'QT-LCE-' || v_tag, 1, 'Lifecycle Export Ltd',
            'Lifecycle Platform Ltd', 'standard', 'annual', 'GBP', current_date - 65, 12, current_date - 65,
            current_date + 300, 'England and Wales', 'active', now(), v_owner)
    returning id into v_cexp;
    insert into erp_meta.contract (tenant_id, tenant_code, deployment_code, platform_tenant_id, quote_document_id,
      quote_number, quote_version, customer_legal_name, platform_legal_name, plan_code, term_kind, currency,
      commencement, initial_term_months, current_term_start, current_term_end, governing_law, status, signed_at,
      created_by)
    values (null, v_fail, v_fail, v_platform, gen_random_uuid(), 'QT-LCF-' || v_tag, 1, 'Lifecycle Failed Ltd',
            'Lifecycle Platform Ltd', 'standard', 'annual', 'GBP', current_date - 265, 12, current_date - 265, v_fend,
            'England and Wales', 'active', now(), v_owner)
    returning id into v_cfail;

    -- ── 1. Who may ask, where, and how ──────────────────────────────────────
    v_step := 'asking off the control plane, below rank, without a reason, and for nobody';
    v_who := array['client', 'client', 'client', 'operator', 'operator', 'operator', 'operator', 'support',
                   'owner', 'owner', 'owner', 'owner', 'owner', 'owner', 'owner', 'owner'];
    v_sql := array[
      format('select public.erp_platform_suspend_deployment(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_request_export(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_cancel_offboarding(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_suspend_deployment(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_reinstate_deployment(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_begin_offboarding(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_cancel_offboarding(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_request_export(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_suspend_deployment(%L, %L)', v_live, 'unpaid'),
      format('select public.erp_platform_reinstate_deployment(%L, %L)', v_live, 'paid'),
      format('select public.erp_platform_begin_offboarding(%L, %L)', v_live, 'leaving'),
      format('select public.erp_platform_cancel_offboarding(%L, %L)', v_live, 'staying'),
      format('select public.erp_platform_request_export(%L, %L)', v_live, '   '),
      format('select public.erp_platform_suspend_deployment(%L, %L)', 'zznobody-' || v_tag, c_reason),
      format('select public.erp_platform_cancel_offboarding(%L, %L)', 'zznobody-' || v_tag, c_reason),
      format('select public.erp_platform_request_export(%L, %L)', 'zznobody-' || v_tag, c_reason)];
    v_want := array['CLOVEERP_NOT_THE_CONTROL_PLANE', 'CLOVEERP_NOT_THE_CONTROL_PLANE', 'CLOVEERP_NOT_THE_CONTROL_PLANE',
                    'CLOVEERP_PLATFORM_ROLE_TOO_LOW', 'CLOVEERP_PLATFORM_ROLE_TOO_LOW', 'CLOVEERP_PLATFORM_ROLE_TOO_LOW',
                    'CLOVEERP_PLATFORM_ROLE_TOO_LOW', 'CLOVEERP_PLATFORM_ROLE_TOO_LOW',
                    'CLOVEERP_REASON_REQUIRED', 'CLOVEERP_REASON_REQUIRED', 'CLOVEERP_REASON_REQUIRED',
                    'CLOVEERP_REASON_REQUIRED', 'CLOVEERP_REASON_REQUIRED',
                    'CLOVEERP_DEPLOYMENT_UNKNOWN', 'CLOVEERP_DEPLOYMENT_UNKNOWN', 'CLOVEERP_DEPLOYMENT_UNKNOWN'];
    v_n := 0;
    for i in 1 .. cardinality(v_sql) loop
      update erp_meta.platform_staff s
         set staff_role = case when v_who[i] = 'client' then 'owner' else v_who[i] end
       where s.auth_user_id = v_uid;
      delete from erp_meta.platform_setting where key = 'deployment.kind';
      insert into erp_meta.platform_setting (key, value, reason)
      values ('deployment.kind', to_jsonb(case when v_who[i] = 'client' then 'client' else 'production' end),
              'deployment_lifecycle_suite');
      begin
        execute v_sql[i];
        v_got := 'it was done';
      exception when others then
        v_got := sqlerrm;
      end;
      if v_got like v_want[i] || '%' then
        v_n := v_n + 1;
      else
        v_bad := coalesce(v_bad || ' / ', '') || i || ': ' || left(v_got, 80);
      end if;
    end loop;
    update erp_meta.platform_staff s set staff_role = 'owner' where s.auth_user_id = v_uid;
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'deployment_lifecycle_suite');
    v_cases := v_cases + 1;
    case_name := 'the lifecycle doors refuse off the control plane, below their rank, without a reason, and for a deployment the register does not hold';
    passed := v_n = 16
          and (select d.status from erp_meta.deployment d where d.code = v_live) = 'live'
          and not exists (select 1 from erp_meta.fleet_request r where r.payload ->> 'code' = v_live);
    detail := format('%s of 16 refused as they should be%s', v_n, coalesce('; ' || v_bad, ''));
    return next;

    -- ── 2. Suspended ────────────────────────────────────────────────────────
    v_step := 'suspending';
    begin
      perform public.erp_platform_suspend_deployment(v_req, c_reason);
      v_got := 'it was suspended';
    exception when others then
      v_got := sqlerrm;
    end;
    v_json := public.erp_platform_suspend_deployment(v_live, 'The client has not paid for two months; suspended until it does.');
    v_s1 := (v_json ->> 'sync_request_id')::uuid;
    begin
      perform public.erp_platform_suspend_deployment(v_live, c_reason);
      v_got2 := 'it was suspended twice';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a built or live deployment is suspended with its reason and since when, said in its steps and the platform log, and a status sync is asked for; nothing else is, and nothing twice';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE: ' || v_req || ' is not suspended: it is requested'
          and v_json ->> 'status' = 'suspended' and v_json ->> 'was' = 'live'
          and (select d.status || '|' || d.suspended_reason || '|' || (d.suspended_at = now())::text
                 from erp_meta.deployment d where d.code = v_live)
              = 'suspended|The client has not paid for two months; suspended until it does.|true'
          and v_got2 = 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE: ' || v_live || ' is not suspended: it is suspended already'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_live and e.phase = 'suspend' and e.status = 'done'
                         and e.detail like 'suspended by ' || v_owner || ' (was live): The client has not paid for two months; suspended until it does. Its address now says%')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_suspended' and a.target = v_live
                         and a.detail ->> 'was' = 'live' and a.detail ->> 'sync_request_id' = v_s1::text)
          and (select count(*) from erp_meta.fleet_request r where r.kind = 'sync' and r.payload ->> 'code' = v_live) = 1
          and exists (select 1 from erp_meta.fleet_request r
                       where r.id = v_s1 and r.kind = 'sync' and r.status = 'requested'
                         and r.payload = jsonb_build_object('code', v_live));
    detail := left(v_got, 80) || ' / ' || coalesce(v_json::text, 'no answer') || ' / ' || left(v_got2, 80);
    return next;

    -- ── 3. A suspended address ──────────────────────────────────────────────
    v_step := 'asking the directory for a suspended address';
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json := public.erp_deployment_for_host(v_live || '.' || v_apex);
    v_json2 := public.erp_deployment_for_host(upper(v_built) || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a suspended address answers that it is suspended and gives nothing to boot; a built one still answers with its project';
    passed := v_json = jsonb_build_object('code', v_live, 'client_name', 'Lifecycle Live Ltd', 'suspended', true)
          and v_json2 = jsonb_build_object('code', v_built, 'client_name', 'Lifecycle Built Ltd',
                                           'url', 'https://' || substr(md5(v_built), 1, 20) || '.supabase.co',
                                           'key', 'sb_publishable_' || replace(v_built, '-', ''));
    detail := coalesce(v_json::text, 'nothing') || ' / ' || coalesce(v_json2::text, 'nothing');
    return next;

    -- ── 4. Still released into ──────────────────────────────────────────────
    v_step := 'releasing into a suspended deployment';
    v_got := erp_meta.begin_deployment_release(v_live, 'run-' || v_tag || '-s');
    perform erp_meta.record_deployment_release(v_live, 'abc1234def5678', 'success', 'run-' || v_tag || '-s');
    v_json := public.erp_platform_request_release(array[v_live], 'The lifecycle suite releases into a suspended client.');
    v_cases := v_cases + 1;
    case_name := 'a suspended deployment is still released into: its release starts and may be asked for, and a success leaves it suspended';
    passed := v_got = 'suspended'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_live and e.phase = 'release' and e.status = 'started'
                         and e.run_id = 'run-' || v_tag || '-s')
          and (select d.status || '|' || d.last_release_outcome from erp_meta.deployment d where d.code = v_live)
              = 'suspended|success'
          and v_json -> 'targets' ? v_live;
    detail := v_got || ' / ' || coalesce(v_json::text, 'no request');
    return next;

    -- ── 5. Reinstated, live again ───────────────────────────────────────────
    v_step := 'reinstating';
    begin
      perform public.erp_platform_reinstate_deployment(v_built, c_reason);
      v_got := 'it was reinstated';
    exception when others then
      v_got := sqlerrm;
    end;
    v_json := public.erp_platform_reinstate_deployment(v_live, 'The client has paid what it owed, so it is reinstated.');
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json2 := public.erp_deployment_for_host(v_live || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'only a suspended deployment is reinstated: live again when a release to it succeeded, served at its address, why and since when it was suspended gone from its row, and the waiting status sync serves for both';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDED: ' || v_built || ' is not reinstated: it is built, not suspended'
          and v_json ->> 'status' = 'live' and v_json ->> 'was' = 'suspended'
          and (select d.status = 'live' and d.suspended_reason is null and d.suspended_at is null
                 from erp_meta.deployment d where d.code = v_live)
          and v_json2 ->> 'url' = 'https://' || substr(md5(v_live), 1, 20) || '.supabase.co'
          and not v_json2 ? 'suspended'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_live and e.phase = 'note'
                         and e.detail = 'reinstated by ' || v_owner || ' (now live): The client has paid what it owed, so '
                                        'it is reinstated. Its address serves it again, and its organisation is '
                                        'reinstated with it when the status sync runs; it had been suspended because: '
                                        'The client has not paid for two months; suspended until it does.')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_reinstated' and a.target = v_live)
          and v_json ->> 'sync_request_id' = v_s1::text
          and (select count(*) from erp_meta.fleet_request r where r.kind = 'sync' and r.payload ->> 'code' = v_live) = 1;
    detail := left(v_got, 80) || ' / ' || coalesce(v_json::text, 'no answer') || ' / ' || coalesce(v_json2::text, 'nothing');
    return next;

    -- ── 6. Reinstated, built when never released into ───────────────────────
    v_step := 'reinstating a client never released into';
    perform public.erp_platform_suspend_deployment(v_built, 'The lifecycle suite suspends a client never released into.');
    v_json := public.erp_platform_reinstate_deployment(v_built, 'The lifecycle suite reinstates a client never released into.');
    v_cases := v_cases + 1;
    case_name := 'a suspended deployment no release ever succeeded for is reinstated as built, not live';
    passed := v_json ->> 'status' = 'built' and v_json ->> 'was' = 'suspended'
          and (select d.status = 'built' and d.suspended_reason is null and d.suspended_at is null
                 from erp_meta.deployment d where d.code = v_built)
          and not exists (select 1 from erp_meta.deployment_event e
                           where e.code = v_built and e.phase = 'release' and e.status = 'done')
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_built and e.phase = 'note'
                         and e.detail like 'reinstated by ' || v_owner || ' (now built): %');
    detail := coalesce(v_json::text, 'no answer');
    return next;

    -- ── 7. Offboarded under a contract ──────────────────────────────────────
    v_step := 'offboarding a client under contract';
    v_json := public.erp_platform_begin_offboarding(v_con, 'The client gave notice; its contract runs to the end of its term.');
    v_e1 := (v_json ->> 'export_request_id')::uuid;
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json2 := public.erp_deployment_for_host(v_con || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_got := erp_meta.begin_deployment_release(v_con, 'run-' || v_tag || '-o');
    perform erp_meta.record_deployment_release(v_con, 'abc1234def5678', 'success', 'run-' || v_tag || '-o');
    v_cases := v_cases + 1;
    case_name := 'offboarding a client under contract makes it retiring and still served, keeps when it began, sets its purge thirty days after its term ends, and asks for an export';
    passed := v_json ->> 'status' = 'retiring' and v_json ->> 'was' = 'live'
          and (v_json ->> 'contract_term_end')::date = v_end
          and (v_json ->> 'export_asked')::boolean
          and (v_json ->> 'export_queued')::boolean
          and (v_json ->> 'builds_cancelled')::integer = 0
          and (v_json ->> 'offboarding_at')::timestamptz = now()
          and (select d.status = 'retiring' and d.purge_due_at = v_end::timestamptz + interval '30 days'
                      and d.offboarding_at = now() and d.suspended_reason is null
                 from erp_meta.deployment d where d.code = v_con)
          and (v_json ->> 'purge_due_at')::timestamptz = v_end::timestamptz + interval '30 days'
          and exists (select 1 from erp_meta.fleet_request r
                       where r.id = v_e1 and r.kind = 'export' and r.status = 'requested'
                         and r.payload = jsonb_build_object('code', v_con))
          and v_json2 ->> 'url' = 'https://' || substr(md5(v_con), 1, 20) || '.supabase.co'
          and v_got = 'retiring'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_con and e.phase = 'note'
                         and e.detail like 'offboarding begun by ' || v_owner || ' (was live): The client gave notice%'
                                           'thirty days after its contract''s term ends on%a copy of its database is asked for.')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_offboarding_begun' and a.target = v_con);
    detail := coalesce(v_json::text, 'no answer') || ' / release: ' || v_got;
    return next;

    -- ── 8. Offboarded without ever being built ──────────────────────────────
    v_step := 'offboarding clients never built';
    -- What the failed build's address answered before its offboarding.
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_dirf := public.erp_deployment_for_host(v_fail || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_json := public.erp_platform_begin_offboarding(v_req, 'The client never went live and has asked to leave.');
    v_json2 := public.erp_platform_begin_offboarding(v_fail, 'The build failed for good and the client went elsewhere.');
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json3 := public.erp_deployment_for_host(v_req || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    -- Nothing to release into, and nothing for the poll to miss.
    v_got := erp_meta.begin_deployment_release(v_fail, 'run-' || v_tag || '-f');
    begin
      perform public.erp_platform_request_release(array[v_fail], 'The lifecycle suite asks to release into a client never built.');
      v_got2 := 'it was asked for';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_fail);
    v_cases := v_cases + 1;
    case_name := 'a deployment never built, waiting or failed, is offboarded without an export, its waiting build cancelled, and is served, released into and missed nowhere';
    passed := v_json ->> 'status' = 'retiring' and v_json ->> 'was' = 'requested'
          and not (v_json ->> 'export_asked')::boolean
          and not (v_json ->> 'export_queued')::boolean
          and jsonb_typeof(v_json -> 'export_request_id') = 'null'
          and (v_json ->> 'builds_cancelled')::integer = 1
          and (select r.status || '|' || r.outcome from erp_meta.fleet_request r where r.id = v_b1)
              = 'cancelled|the deployment''s offboarding began'
          and (select d.status = 'retiring' and d.purge_due_at = now() + interval '30 days' and d.offboarding_at = now()
                 from erp_meta.deployment d where d.code = v_req)
          and v_json2 ->> 'was' = 'failed'
          and (v_json2 ->> 'contract_term_end')::date = v_fend
          and not (v_json2 ->> 'export_asked')::boolean
          and (select d.status = 'retiring' and d.purge_due_at = v_fend::timestamptz + interval '30 days'
                 from erp_meta.deployment d where d.code = v_fail)
          and not exists (select 1 from erp_meta.fleet_request r
                           where r.kind = 'export' and r.payload ->> 'code' in (v_req, v_fail))
          and v_json3 is null
          and v_got = 'retiring, never built'
          and not exists (select 1 from erp_meta.deployment_event e
                           where e.code = v_fail and e.phase = 'release')
          and v_got2 like 'CLOVEERP_RELEASE_TARGET_UNKNOWN: "' || v_fail || '" is not all, control, demonstration, or a built client%'
          and not (v_row ->> 'silent')::boolean
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_req and e.phase = 'note'
                         and e.detail like 'offboarding begun by ' || v_owner || ' (was requested): The client never went live%'
                                           'it was never built, so there is no database to copy; the build waiting for it is cancelled.');
    detail := coalesce(v_json::text, 'no answer') || ' / ' || coalesce(v_json2::text, 'no answer') || ' / '
           || coalesce(v_json3::text, 'nothing') || ' / release: ' || v_got || ' / ' || left(v_got2, 90)
           || ' / silent: ' || coalesce(v_row ->> 'silent', 'missing');
    return next;

    -- ── 9. Nothing served for one never built ───────────────────────────────
    v_step := 'asking the directory for a client being offboarded that was never built';
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json := public.erp_deployment_for_host(v_fail || '.' || v_apex);
    v_json2 := public.erp_deployment_for_host(v_con || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a client being offboarded that was never built answers nothing at its address, though its failed build registered a project; one built answers with its project';
    passed := v_dirf is null
          and v_json is null
          and (select d.status = 'retiring' and d.built_at is null and d.suspended_reason is null
                      and d.api_url is not null and d.publishable_key is not null
                 from erp_meta.deployment d where d.code = v_fail)
          and v_json2 ->> 'url' = 'https://' || substr(md5(v_con), 1, 20) || '.supabase.co';
    detail := 'failed: ' || coalesce(v_dirf::text, 'nothing') || ' / offboarded: ' || coalesce(v_json::text, 'nothing')
           || ' / built and offboarded: ' || coalesce(v_json2::text, 'nothing');
    return next;

    -- ── 10. Not while a build runs, and once ────────────────────────────────
    v_step := 'offboarding what cannot be offboarded';
    begin
      perform public.erp_platform_begin_offboarding(v_bld, c_reason);
      v_got := 'it was offboarded';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_begin_offboarding(v_dsp, c_reason);
      v_got2 := 'it was offboarded';
    exception when others then
      v_got2 := sqlerrm;
    end;
    begin
      perform public.erp_platform_begin_offboarding(v_con, c_reason);
      v_got3 := 'it was offboarded twice';
    exception when others then
      v_got3 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'offboarding does not begin while a build runs or has just been started, and begins once';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE: ' || v_bld || ' is not offboarded: it is building, and its build is running'
          and v_got2 = 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE: ' || v_dsp || ' is not offboarded: its build has been started and has not yet begun'
          and v_got3 = 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE: ' || v_con || ' is not offboarded: it is being offboarded already'
          and (select d.status from erp_meta.deployment d where d.code = v_bld) = 'building'
          and (select d.status from erp_meta.deployment d where d.code = v_dsp) = 'requested';
    detail := left(v_got, 90) || ' / ' || left(v_got2, 90) || ' / ' || left(v_got3, 90);
    return next;

    -- ── 11. A build only waiting has not started ────────────────────────────
    v_step := 'offboarding a client whose build waits, and one whose build was claimed';
    v_json := public.erp_platform_begin_offboarding(v_wait, 'The client pulled out while its build waited behind another.');
    begin
      perform public.erp_platform_begin_offboarding(v_clm, c_reason);
      v_got := 'it was offboarded';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a build only waiting behind another has not started, whatever the sweep noted: its offboarding begins and the waiting build is cancelled; one the sweep claimed in the last ninety minutes has started';
    passed := v_json ->> 'status' = 'retiring' and v_json ->> 'was' = 'requested'
          and (v_json ->> 'builds_cancelled')::integer = 1
          and (select r.status || '|' || r.outcome from erp_meta.fleet_request r where r.id = v_b2)
              = 'cancelled|the deployment''s offboarding began'
          and v_got = 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE: ' || v_clm || ' is not offboarded: its build has been started and has not yet begun'
          and (select d.status from erp_meta.deployment d where d.code = v_clm) = 'requested'
          and (select r.status from erp_meta.fleet_request r where r.id = v_b3) = 'claimed';
    detail := coalesce(v_json::text, 'no answer') || ' / ' || left(v_got, 110);
    return next;

    -- ── 12. A build claim the sweep never started is let go ─────────────────
    v_step := 'offboarding a client whose build the sweep claimed two days ago and never started';
    -- The sweep claimed it and said so two days ago, then died before it
    -- started the run or settled the request.
    update erp_meta.fleet_request x
       set created_at = now() - interval '2 days', claimed_at = now() - interval '2 days'
     where x.id = v_b3;
    insert into erp_meta.deployment_event (code, phase, status, detail, run_id, at)
    values (v_clm, 'dispatch', 'done', 'claimed by the sweep', 'run-' || v_tag || '-m', now() - interval '2 days');
    v_json := public.erp_platform_begin_offboarding(v_clm, 'The client pulled out before its build ever ran.');
    v_cases := v_cases + 1;
    case_name := 'a build the sweep claimed over ninety minutes ago and never started holds no offboarding back: the claim is let go, failed and said, and the offboarding begins';
    passed := v_json ->> 'status' = 'retiring' and v_json ->> 'was' = 'requested'
          and (v_json ->> 'builds_let_go')::integer = 1
          and (v_json ->> 'builds_cancelled')::integer = 0
          and v_json -> 'let_go_request_ids' = jsonb_build_array(v_b3)
          and not (v_json ->> 'export_asked')::boolean
          and (select r.status = 'failed' and r.settled_at = now()
                      and r.outcome = 'claimed by the sweep for run run-' || v_tag || '-m at '
                                      || to_char((now() - interval '2 days') at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"')
                                      || ' and never started; let go by ' || v_owner
                                      || ' when the deployment''s offboarding began'
                 from erp_meta.fleet_request r where r.id = v_b3)
          and (select d.status from erp_meta.deployment d where d.code = v_clm) = 'retiring'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_clm and e.phase = 'note'
                         and e.detail like 'offboarding begun by ' || v_owner || ' (was requested): The client pulled out%'
                                           'it was never built, so there is no database to copy; the build the sweep '
                                           'claimed and never started is let go.')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_offboarding_begun' and a.target = v_clm
                         and (a.detail ->> 'builds_let_go')::integer = 1);
    detail := coalesce(v_json::text, 'no answer') || ' / ' || coalesce((select r.status || ': ' || r.outcome
                                                                        from erp_meta.fleet_request r where r.id = v_b3), '-');
    return next;

    -- ── 13. Offboarding keeps a suspension ──────────────────────────────────
    v_step := 'offboarding a suspended client with no contract';
    perform public.erp_platform_suspend_deployment(v_bare, 'The lifecycle suite suspends a client before it leaves.');
    -- Suspended two days before its offboarding begins.
    update erp_meta.deployment x set suspended_at = now() - interval '2 days' where x.code = v_bare;
    v_json := public.erp_platform_begin_offboarding(v_bare, 'The client is leaving with no contract left to run.');
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json2 := public.erp_deployment_for_host(v_bare || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'offboarding a suspended client keeps it suspended at its address and since when, sets its purge thirty days from now with no contract, and asks for an export';
    passed := (select d.status = 'retiring'
                      and d.suspended_reason = 'The lifecycle suite suspends a client before it leaves.'
                      and d.suspended_at = now() - interval '2 days'
                      and d.purge_due_at = now() + interval '30 days'
                 from erp_meta.deployment d where d.code = v_bare)
          and v_json ->> 'was' = 'suspended'
          and v_json ->> 'suspended_reason' = 'The lifecycle suite suspends a client before it leaves.'
          and jsonb_typeof(v_json -> 'contract_term_end') = 'null'
          and (v_json ->> 'export_queued')::boolean
          and v_json2 = jsonb_build_object('code', v_bare, 'client_name', 'Lifecycle Bare Ltd', 'suspended', true)
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_bare and e.phase = 'note'
                         and e.detail like 'offboarding begun by ' || v_owner || ' (was suspended, and it stays suspended)%thirty days from now; a copy of its database is asked for.');
    detail := coalesce(v_json::text, 'no answer') || ' / ' || coalesce(v_json2::text, 'nothing');
    return next;

    -- ── 14. Suspended while offboarded, and reinstated ──────────────────────
    v_step := 'suspending and reinstating a client being offboarded';
    v_json := public.erp_platform_suspend_deployment(v_con, 'The client stopped paying during its notice period.');
    v_got3 := (select (d.suspended_at = now())::text from erp_meta.deployment d where d.code = v_con);
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json2 := public.erp_deployment_for_host(v_con || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    begin
      perform public.erp_platform_suspend_deployment(v_con, c_reason);
      v_got := 'it was suspended twice';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_suspend_deployment(v_req, c_reason);
      v_got2 := 'it was suspended';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_json3 := public.erp_platform_reinstate_deployment(v_con, 'The client paid what it owed during its notice.');
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_row := public.erp_deployment_for_host(v_con || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_s2 := (v_json ->> 'sync_request_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'a client being offboarded is suspended and reinstated and stays retiring, since when kept and cleared with why, its address following; one never built has nothing to suspend';
    passed := v_json ->> 'status' = 'retiring' and v_json ->> 'was' = 'retiring'
          and v_got3 = 'true'
          and v_json2 = jsonb_build_object('code', v_con, 'client_name', 'Lifecycle Contract Ltd', 'suspended', true)
          and v_got = 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE: ' || v_con || ' is not suspended: it is being offboarded, and suspended already'
          and v_got2 = 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE: ' || v_req || ' is not suspended: it is being offboarded and was never built, so it has no service to stop'
          and v_json3 ->> 'status' = 'retiring' and v_json3 ->> 'was' = 'retiring'
          and (select d.status = 'retiring' and d.suspended_reason is null and d.suspended_at is null
                      and d.purge_due_at = v_end::timestamptz + interval '30 days'
                 from erp_meta.deployment d where d.code = v_con)
          and v_row ->> 'url' = 'https://' || substr(md5(v_con), 1, 20) || '.supabase.co'
          and v_json3 ->> 'sync_request_id' = v_s2::text
          and exists (select 1 from erp_meta.fleet_request r
                       where r.id = v_s2 and r.kind = 'sync' and r.status = 'requested'
                         and r.payload = jsonb_build_object('code', v_con));
    detail := coalesce(v_json::text, 'no answer') || ' / ' || left(v_got, 90) || ' / ' || left(v_got2, 90) || ' / '
           || coalesce(v_json3::text, 'no answer');
    return next;

    -- ── 15. An offboarding cancelled ────────────────────────────────────────
    v_step := 'cancelling offboardings';
    begin
      perform public.erp_platform_cancel_offboarding(v_live, c_reason);
      v_got := 'it was taken back';
    exception when others then
      v_got := sqlerrm;
    end;
    v_json := public.erp_platform_cancel_offboarding(v_bare, 'The client settled its account and is staying with us.');
    v_json2 := public.erp_platform_cancel_offboarding(v_req, 'The client changed its mind and will be built after all.');
    perform public.erp_platform_begin_offboarding(v_built, 'The lifecycle suite offboards a client to take it back.');
    v_json3 := public.erp_platform_cancel_offboarding(v_built, 'The lifecycle suite takes back the offboarding it began.');
    perform public.erp_platform_begin_offboarding(v_live, 'The lifecycle suite offboards a released client to take it back.');
    v_row := public.erp_platform_cancel_offboarding(v_live, 'The lifecycle suite takes back a released client''s offboarding.');
    v_cases := v_cases + 1;
    case_name := 'an offboarding is cancelled back to suspended, failed, live or built as the deployment was, its purge date gone; one not being offboarded has none to cancel';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDING: ' || v_live || ' is not taken back from offboarding: it is live, not being offboarded'
          and v_json ->> 'status' = 'suspended' and v_json ->> 'was' = 'retiring'
          and v_json ->> 'suspended_reason' = 'The lifecycle suite suspends a client before it leaves.'
          and (v_json ->> 'purge_due_at_was')::timestamptz = now() + interval '30 days'
          and v_json2 ->> 'status' = 'failed'
          and v_json3 ->> 'status' = 'built'
          and v_row ->> 'status' = 'live'
          and (select d.status || '|' || coalesce(d.suspended_reason, '') || '|' || (d.suspended_at = now() - interval '2 days')::text
                 from erp_meta.deployment d where d.code = v_bare)
              = 'suspended|The lifecycle suite suspends a client before it leaves.|true'
          and (select d.status from erp_meta.deployment d where d.code = v_req) = 'failed'
          and (select d.status from erp_meta.deployment d where d.code = v_built) = 'built'
          and (select d.status from erp_meta.deployment d where d.code = v_live) = 'live'
          and (select bool_and(d.purge_due_at is null and d.offboarding_at is null)
                 from erp_meta.deployment d where d.code in (v_bare, v_req, v_built, v_live))
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_bare and e.phase = 'note'
                         and e.detail like 'offboarding cancelled by ' || v_owner || ' (now suspended): The client settled '
                                           'its account and is staying with us. Its project is no longer due to be purged '
                                           'on %; it stays suspended because: The lifecycle suite suspends a client '
                                           'before it leaves.')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_offboarding_cancelled' and a.target = v_bare
                         and a.detail ->> 'status' = 'suspended');
    detail := left(v_got, 90) || ' / ' || coalesce(v_json ->> 'status', '-') || ', ' || coalesce(v_json2 ->> 'status', '-')
           || ', ' || coalesce(v_json3 ->> 'status', '-') || ', ' || coalesce(v_row ->> 'status', '-');
    return next;

    -- ── 16. A suspension says since when ────────────────────────────────────
    v_step := 'keeping a suspension''s reason and its time together';
    v_n := 0;
    begin
      update erp_meta.deployment x set suspended_at = null where x.code = v_bare;
    exception when check_violation then
      v_n := v_n + 1;
    end;
    begin
      update erp_meta.deployment x
         set status = 'suspended', suspended_reason = 'The lifecycle suite suspends without saying since when.'
       where x.code = v_built;
    exception when check_violation then
      v_n := v_n + 1;
    end;
    begin
      update erp_meta.deployment x set suspended_at = now() where x.code = v_built;
    exception when check_violation then
      v_n := v_n + 1;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment''s suspension says since when: set with its reason by suspending, kept by offboarding and its cancelling, cleared with it by reinstating, and never one without the other';
    passed := v_n = 3
          and (select bool_and((d.suspended_reason is null) = (d.suspended_at is null))
                 from erp_meta.deployment d
                where d.code in (v_live, v_built, v_req, v_fail, v_con, v_bare, v_exp))
          and (select d.suspended_at = now() - interval '2 days' from erp_meta.deployment d where d.code = v_bare)
          and (select count(*) from erp_meta.deployment d
                where d.code in (v_live, v_built, v_con) and d.suspended_at is null) = 3;
    detail := format('%s of 3 refused', v_n);
    return next;

    -- ── 17. Exports asked for ───────────────────────────────────────────────
    v_step := 'asking for exports as an operator';
    update erp_meta.platform_staff s set staff_role = 'operator' where s.auth_user_id = v_uid;
    v_json := public.erp_platform_request_export(v_exp, 'The client asked for a copy of its data for its auditors.');
    v_json2 := public.erp_platform_request_export(v_exp, 'The client asked again for a copy of its data for its auditors.');
    v_row := public.erp_platform_request_export(v_con, 'The lifecycle suite asks for a copy while one is waiting.');
    begin
      perform public.erp_platform_request_export(v_req, c_reason);
      v_got := 'it was copied';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_request_export(v_fail, c_reason);
      v_got3 := 'it was copied';
    exception when others then
      v_got3 := sqlerrm;
    end;
    update erp_meta.platform_staff s set staff_role = 'support' where s.auth_user_id = v_uid;
    begin
      perform public.erp_platform_request_export(v_exp, c_reason);
      v_got2 := 'support asked';
    exception when others then
      v_got2 := sqlerrm;
    end;
    update erp_meta.platform_staff s set staff_role = 'owner' where s.auth_user_id = v_uid;
    v_cases := v_cases + 1;
    case_name := 'an operator asks for an export of a deployment that was built, and one waiting is not queued twice; none of one never built; support may not ask';
    passed := (v_json ->> 'queued')::boolean
          and not (v_json2 ->> 'queued')::boolean
          and v_json2 ->> 'request_id' = v_json ->> 'request_id'
          and (select count(*) from erp_meta.fleet_request r
                where r.kind = 'export' and r.payload ->> 'code' = v_exp and r.status in ('requested', 'claimed')) = 1
          and not (v_row ->> 'queued')::boolean
          and v_row ->> 'request_id' = v_e1::text
          and v_got = 'CLOVEERP_DEPLOYMENT_NOT_EXPORTABLE: ' || v_req || ' is not copied: it is failed'
          and v_got3 = 'CLOVEERP_DEPLOYMENT_NOT_EXPORTABLE: ' || v_fail || ' is not copied: it is retiring and was never built, so there is no database to copy'
          and v_got2 like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_exp and e.phase = 'note'
                         and e.detail like 'a copy of its database asked for by ' || v_owner || ': The client asked again%is still waiting, so no other is.')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_export_requested' and a.target = v_exp
                         and a.actor_role = 'operator');
    detail := coalesce(v_json::text, '-') || ' / ' || coalesce(v_json2::text, '-') || ' / ' || left(v_got, 70)
           || ' / ' || left(v_got3, 90) || ' / ' || left(v_got2, 50);
    return next;

    -- ── 18. The sweep claims exports and status syncs ───────────────────────
    v_step := 'claiming an export and a status sync';
    -- Oldest first: the export asked for by the offboarding, and the first
    -- client's status sync.
    update erp_meta.fleet_request x set created_at = now() - interval '5 minutes' where x.id = v_e1;
    update erp_meta.fleet_request x set created_at = now() - interval '5 minutes' where x.id = v_s1;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-e', array['export']);
    v_got := coalesce(erp_meta.claim_fleet_request('run-' || v_tag || '-n', array['rename'])::text, 'nothing');
    v_json := erp_meta.claim_fleet_request('run-' || v_tag || '-y', array['sync']);
    begin
      perform erp_meta.claim_fleet_request('run-' || v_tag || '-x', array['export', 'rebuild']);
      v_got2 := 'it was claimed';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_n := 0;
    foreach v_json2 in array array[jsonb_build_object('kind', 'export', 'payload', '{}'::jsonb),
                                   jsonb_build_object('kind', 'rename', 'payload', jsonb_build_object('code', v_exp, 'to', 'zzlcz-' || v_tag)),
                                   jsonb_build_object('kind', 'sync', 'payload', '{}'::jsonb),
                                   jsonb_build_object('kind', 'rebuild', 'payload', jsonb_build_object('code', v_exp))] loop
      begin
        insert into erp_meta.fleet_request (kind, payload) values (v_json2 ->> 'kind', v_json2 -> 'payload');
      exception when check_violation then
        v_n := v_n + 1;
      end;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'the sweep claims the oldest export or status sync when it asks for that kind, and the register keeps renames, exports and syncs only in their shapes';
    passed := v_claim ->> 'id' = v_e1::text
          and v_claim ->> 'kind' = 'export'
          and v_claim -> 'payload' ->> 'code' = v_con
          and (select r.status || ' ' || r.run_id from erp_meta.fleet_request r where r.id = v_e1) = 'claimed run-' || v_tag || '-e'
          and v_got = 'nothing'
          and v_json ->> 'id' = v_s1::text
          and v_json ->> 'kind' = 'sync'
          and v_json -> 'payload' = jsonb_build_object('code', v_live)
          and v_got2 = 'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN: the console asks for builds, releases, renames, exports and syncs, not rebuild'
          and v_n = 4;
    detail := coalesce(v_claim::text, 'nothing claimed') || ' / renames: ' || v_got || ' / ' || coalesce(v_json::text, 'no sync')
           || ' / ' || left(v_got2, 110) || format(' / %s of 4 malformed kept out', v_n);
    return next;

    -- ── 19. The export recorded ─────────────────────────────────────────────
    v_step := 'recording an export';
    v_sql := array[
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L, now(), true)', v_exp, 'exports/' || v_con || '/20261008T120000Z.dump.age', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L, now(), true)', v_exp, 'backups/' || v_exp || '/2026-10-08.dump.age', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L, now(), true)', v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 0, %L, now(), true)', v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump.age', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L, now(), true)', v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump.age', 'not-a-fingerprint'),
      format('select erp_meta.record_deployment_export(%L, null, 1000, %L, now(), true)', v_exp, repeat('a', 64)),
      -- When its dump began: said, and not after it is recorded.
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L, null, true)', v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump.age', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L, now() + interval ''1 second'', true)', v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump.age', repeat('a', 64))];
    v_n := 0;
    v_bad := null;
    for i in 1 .. cardinality(v_sql) loop
      begin
        execute v_sql[i];
        v_got := 'it was recorded';
      exception when others then
        v_got := sqlerrm;
      end;
      if v_got like 'CLOVEERP_DEPLOYMENT_EXPORT_INVALID: the copy of ' || v_exp || ' is not recorded: %' then
        v_n := v_n + 1;
      else
        v_bad := coalesce(v_bad || ' / ', '') || i || ': ' || left(v_got, 80);
      end if;
    end loop;
    begin
      perform erp_meta.record_deployment_export('zznobody-' || v_tag, 'exports/zznobody-' || v_tag || '/x.dump.age', 1000, repeat('a', 64), now(), true);
      v_got2 := 'it was recorded';
    exception when others then
      v_got2 := sqlerrm;
    end;
    -- Its dump began ten minutes ago, and the run could not say the client's
    -- organisation was suspended first.
    v_got := erp_meta.record_deployment_export(v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump.age', 123456789,
                                               repeat('AB', 32), now() - interval '10 minutes', null);
    v_cases := v_cases + 1;
    case_name := 'an export is recorded by the trusted build role alone, in its own form: where it went for that client, its size, its fingerprint, and when its dump began, never after it is recorded';
    passed := v_n = 8
          and v_got2 like 'CLOVEERP_DEPLOYMENT_UNKNOWN%'
          and v_got = v_exp || ': copy recorded at exports/' || v_exp || '/20261008T120000Z.dump.age'
          and (select d.last_export_at = now() and d.last_export_object = 'exports/' || v_exp || '/20261008T120000Z.dump.age'
                      and d.last_export_taken_at = now() - interval '10 minutes' and not d.last_export_service_stopped
                 from erp_meta.deployment d where d.code = v_exp)
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_exp and e.phase = 'export' and e.status = 'done'
                         and e.detail = 'a copy of its database whose dump began at '
                                        || to_char((now() - interval '10 minutes') at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"')
                                        || ', without its own organisation confirmed suspended, was written to exports/' || v_exp
                                        || '/20261008T120000Z.dump.age: 123456789 bytes, sha256 ' || repeat('ab', 32))
          and to_regprocedure('erp_meta.record_deployment_export(text,text,bigint,text)') is null
          and (select count(*) from pg_catalog.pg_proc p
                where p.proname = 'record_deployment_export' and p.pronamespace = 'erp_meta'::regnamespace) = 1
          and not (select p.prosecdef from pg_catalog.pg_proc p
                    where p.oid = 'erp_meta.record_deployment_export(text,text,bigint,text,timestamptz,boolean)'::regprocedure)
          and not pg_catalog.has_function_privilege('anon', 'erp_meta.record_deployment_export(text,text,bigint,text,timestamptz,boolean)', 'execute')
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.record_deployment_export(text,text,bigint,text,timestamptz,boolean)', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.record_deployment_export(text,text,bigint,text,timestamptz,boolean)', 'execute');
    detail := format('%s of 8 malformed refused%s; unknown: %s; %s', v_n, coalesce(' (' || v_bad || ')', ''),
                     left(v_got2, 50), left(v_got, 90));
    return next;

    -- ── 20. A copy is dated by when its dump began ──────────────────────────
    v_step := 'recording a copy whose dump began before the one recorded';
    -- A run claimed earlier finishes later: its dump began an hour ago.
    v_got := erp_meta.record_deployment_export(v_exp, 'exports/' || v_exp || '/20261008T110000Z.dump.age', 1000,
                                               repeat('b', 64), now() - interval '1 hour', true);
    v_cases := v_cases + 1;
    case_name := 'a copy recorded after another but whose dump began before it does not replace it: the row keeps the newest copy, and the step says so';
    passed := v_got = v_exp || ': copy recorded at exports/' || v_exp || '/20261008T110000Z.dump.age; its dump began '
                      'before that of the copy already recorded, which stays the last'
          and (select d.last_export_object = 'exports/' || v_exp || '/20261008T120000Z.dump.age'
                      and d.last_export_taken_at = now() - interval '10 minutes' and not d.last_export_service_stopped
                      and d.last_export_at = now()
                 from erp_meta.deployment d where d.code = v_exp)
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_exp and e.phase = 'export' and e.status = 'done'
                         and e.detail like 'a copy of its database whose dump began at %, with its own organisation '
                                           'confirmed suspended, was written to exports/' || v_exp || '/20261008T110000Z.dump.age: '
                                           '1000 bytes, sha256 % a copy whose dump began later is recorded already, and '
                                           'stays its last');
    detail := left(v_got, 120) || ' / ' || coalesce((select d.last_export_object || ' taken ' || d.last_export_taken_at
                                                      from erp_meta.deployment d where d.code = v_exp), '-');
    return next;

    -- ── 21. An export its run never settled is let go ───────────────────────
    v_step := 'asking again for an export whose run never settled it';
    v_json := public.erp_platform_request_export(v_stale, 'The client asked for a copy of its data for its auditors.');
    v_x1 := (v_json ->> 'request_id')::uuid;
    -- Claimed by the sweep, and its run still within its three hours.
    update erp_meta.fleet_request x
       set status = 'claimed', run_id = 'run-' || v_tag || '-x', claimed_at = now() - interval '3 hours 59 minutes'
     where x.id = v_x1;
    v_json2 := public.erp_platform_request_export(v_stale, 'The client asks again while its copy is being written.');
    -- Its run gave up long ago.
    update erp_meta.fleet_request x set claimed_at = now() - interval '4 hours 1 minute' where x.id = v_x1;
    v_json3 := public.erp_platform_request_export(v_stale, 'The client asks again: the first copy never came.');
    v_x2 := (v_json3 ->> 'request_id')::uuid;
    begin
      perform erp_meta.settle_fleet_request(v_x1, 'success: fleet_export.yml wrote the copy');
      v_got := 'its late word was taken';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'an export the sweep claimed four hours ago and its run never settled is let go when another is asked for, failed and said, and a new one queued; one claimed less long is not; a late word on it is refused';
    passed := (v_json ->> 'queued')::boolean
          and not (v_json2 ->> 'queued')::boolean
          and v_json2 ->> 'request_id' = v_x1::text
          and v_json2 -> 'let_go_request_ids' = '[]'::jsonb
          and (v_json3 ->> 'queued')::boolean
          and v_x2 is distinct from v_x1
          and v_json3 -> 'let_go_request_ids' = jsonb_build_array(v_x1)
          and (select r.status = 'failed' and r.settled_at = now()
                      and r.outcome like 'claimed by the sweep for run run-' || v_tag || '-x at % and never settled by its '
                                         'run; let go by ' || v_owner || ' when another export was asked for'
                 from erp_meta.fleet_request r where r.id = v_x1)
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_stale and e.phase = 'export' and e.status = 'note'
                         and e.detail like 'a copy of its database claimed by the sweep at % was never settled by its '
                                           'run, and was let go by ' || v_owner || ' when another was asked for')
          and exists (select 1 from erp_meta.fleet_request r
                       where r.id = v_x2 and r.kind = 'export' and r.status = 'requested')
          and v_got = 'CLOVEERP_DEPLOYMENT_STATE: request ' || v_x1 || ' is not claimed, so it is not settled'
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_export_requested' and a.target = v_stale
                         and a.detail -> 'let_go_request_ids' = jsonb_build_array(v_x1));
    detail := coalesce(v_json2::text, '-') || ' / ' || coalesce(v_json3::text, '-') || ' / late: ' || left(v_got, 90);
    return next;

    -- ── 22. Offboarding lets one go too ─────────────────────────────────────
    v_step := 'offboarding a client whose export its run never settled';
    update erp_meta.fleet_request x
       set status = 'claimed', run_id = 'run-' || v_tag || '-y', claimed_at = now() - interval '5 hours'
     where x.id = v_x2;
    v_json := public.erp_platform_begin_offboarding(v_stale, 'The client is leaving and wants its data on the way out.');
    v_x3 := (v_json ->> 'export_request_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'beginning an offboarding lets go an export the sweep claimed four hours ago and its run never settled, and asks for a new one';
    passed := v_json ->> 'status' = 'retiring'
          and (v_json ->> 'export_queued')::boolean
          and v_x3 is distinct from v_x2
          and v_json -> 'let_go_request_ids' = jsonb_build_array(v_x2)
          and (select r.status = 'failed'
                      and r.outcome like 'claimed by the sweep for run run-' || v_tag || '-y at % and never settled by its '
                                         'run; let go by ' || v_owner || ' when the deployment''s offboarding began'
                 from erp_meta.fleet_request r where r.id = v_x2)
          and exists (select 1 from erp_meta.fleet_request r
                       where r.id = v_x3 and r.kind = 'export' and r.status = 'requested')
          and (select count(*) from erp_meta.deployment_event e
                where e.code = v_stale and e.phase = 'export' and e.status = 'note') = 2;
    detail := coalesce(v_json::text, 'no answer');
    return next;

    -- ── 23. A copy claimed before the stop stands for no later ask ─────────
    v_step := 'asking for a copy after suspending a client whose copy was claimed while it was served';
    -- Offboarding a served client asks for a copy, and the sweep claims it
    -- twenty minutes before the owner suspends the client.
    v_json := public.erp_platform_begin_offboarding(v_fly, 'The client is leaving; no contract is left to run.');
    v_f1 := (v_json ->> 'export_request_id')::uuid;
    update erp_meta.fleet_request x
       set status = 'claimed', run_id = 'run-' || v_tag || '-t', created_at = now() - interval '25 minutes',
           claimed_at = now() - interval '20 minutes'
     where x.id = v_f1;
    perform public.erp_platform_suspend_deployment(v_fly, 'The client has left; its service stops so its last copy can be made.');
    v_json := public.erp_platform_request_export(v_fly, 'The service has stopped, so the last copy is made now.');
    v_f2 := (v_json ->> 'request_id')::uuid;
    v_json2 := public.erp_platform_request_export(v_fly, 'The owner asks again while the last copy waits.');
    -- The sweep claims the new one, after the stop.
    update erp_meta.fleet_request x
       set status = 'claimed', run_id = 'run-' || v_tag || '-u', claimed_at = now()
     where x.id = v_f2;
    v_json3 := public.erp_platform_request_export(v_fly, 'The owner asks again while the last copy is written.');
    -- An operator's copy of a served client is claimed; then the owner
    -- suspends the client and begins its offboarding.
    v_row := public.erp_platform_request_export(v_opx, 'Monthly copy the client asked for under its contract.');
    v_o1 := (v_row ->> 'request_id')::uuid;
    update erp_meta.fleet_request x
       set status = 'claimed', run_id = 'run-' || v_tag || '-v', created_at = now() - interval '20 minutes',
           claimed_at = now() - interval '20 minutes'
     where x.id = v_o1;
    perform public.erp_platform_suspend_deployment(v_opx, 'The client stopped paying; its service stops before it leaves.');
    v_row2 := public.erp_platform_begin_offboarding(v_opx, 'The client is leaving; its data is returned to it at the end.');
    v_o2 := (v_row2 ->> 'export_request_id')::uuid;
    v_got := (select r.status from erp_meta.fleet_request r where r.id = v_o2);
    -- A copy claimed after the stop but before the offboarding began cannot be
    -- the last one either: the retire door counts from the later of the two.
    update erp_meta.deployment x set suspended_at = now() - interval '10 minutes' where x.code = v_opx;
    update erp_meta.fleet_request x
       set status = 'claimed', run_id = 'run-' || v_tag || '-w', claimed_at = now() - interval '5 minutes'
     where x.id = v_o2;
    v_row3 := public.erp_platform_request_export(v_opx, 'The owner asks for the last copy now its offboarding has begun.');
    v_cases := v_cases + 1;
    case_name := 'a copy the sweep claimed before the client''s service stopped, or before its offboarding began, does not stand for one asked for since: a new one is queued beside it and the old one carries on, and one waiting or claimed since both is not queued twice';
    passed := (v_json ->> 'queued')::boolean
          and v_f2 is distinct from v_f1
          and v_json ->> 'beside_request_id' = v_f1::text
          and not (v_json2 ->> 'queued')::boolean and v_json2 ->> 'request_id' = v_f2::text
          and not (v_json3 ->> 'queued')::boolean and v_json3 ->> 'request_id' = v_f2::text
          and jsonb_typeof(v_json3 -> 'beside_request_id') = 'null'
          and (select r.status from erp_meta.fleet_request r where r.id = v_f1) = 'claimed'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_fly and e.phase = 'note'
                         and e.detail = 'a copy of its database asked for by ' || v_owner || ': The service has stopped, so '
                                        'the last copy is made now. The export workflow writes it, encrypted, off the '
                                        'platform, beside the one claimed at '
                                        || to_char((now() - interval '20 minutes') at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"')
                                        || ' before its service stopped or its offboarding began, which carries on.')
          and (v_row2 ->> 'export_queued')::boolean
          and v_o2 is distinct from v_o1
          and v_row2 ->> 'export_beside_request_id' = v_o1::text
          and (select r.status from erp_meta.fleet_request r where r.id = v_o1) = 'claimed'
          and v_got = 'requested'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_opx and e.phase = 'note'
                         and e.detail like 'offboarding begun by ' || v_owner || ' (was suspended, and it stays suspended)%'
                                           'a copy of its database is asked for, beside the one claimed at % before its '
                                           'offboarding began, which carries on.')
          and (v_row3 ->> 'queued')::boolean
          and v_row3 ->> 'beside_request_id' = v_o2::text
          and v_row3 ->> 'request_id' is distinct from v_o2::text
          and (select r.status from erp_meta.fleet_request r where r.id = v_o2) = 'claimed';
    detail := coalesce(v_json::text, '-') || ' / ' || coalesce(v_json2::text, '-') || ' / ' || coalesce(v_json3::text, '-')
           || ' / ' || coalesce(v_row2::text, '-') || ' / ' || coalesce(v_row3::text, '-');
    return next;

    -- ── 24. The Fleet view ──────────────────────────────────────────────────
    v_step := 'reading the Fleet view';
    v_json := public.erp_platform_deployments();
    v_row := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_bare);
    v_row2 := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_exp);
    v_row3 := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_con);
    v_cases := v_cases + 1;
    case_name := 'the Fleet view carries where a deployment is served and was, when its offboarding began and the day its purge is due, why it is suspended and since when, and its last export, when its dump began and whether its service was stopped by then';
    passed := v_row ->> 'status' = 'suspended'
          and v_row ->> 'suspended_reason' = 'The lifecycle suite suspends a client before it leaves.'
          and (v_row ->> 'suspended_at')::timestamptz = now() - interval '2 days'
          and jsonb_typeof(v_row2 -> 'suspended_at') = 'null'
          and v_row ->> 'address' = v_bare
          and v_row ->> 'origin' = 'https://' || v_bare || '.' || v_apex
          and jsonb_typeof(v_row -> 'previous_address') = 'null'
          and jsonb_typeof(v_row -> 'previous_address_until') = 'null'
          and jsonb_typeof(v_row -> 'purge_due_at') = 'null'
          and jsonb_typeof(v_row -> 'offboarding_at') = 'null'
          and (v_row ->> 'silent')::boolean
          and (select count(*) from jsonb_object_keys(v_row)) = 40
          and (v_row2 ->> 'last_export_at')::timestamptz = now()
          and v_row2 ->> 'last_export_object' = 'exports/' || v_exp || '/20261008T120000Z.dump.age'
          and (v_row2 ->> 'last_export_taken_at')::timestamptz = now() - interval '10 minutes'
          and v_row2 -> 'last_export_service_stopped' = 'false'::jsonb
          and jsonb_typeof(v_row -> 'last_export_taken_at') = 'null'
          and v_row -> 'last_export_service_stopped' = 'false'::jsonb
          and (v_row3 ->> 'purge_due_at')::timestamptz = v_end::timestamptz + interval '30 days'
          and (v_row3 ->> 'offboarding_at')::timestamptz = now()
          and v_row3 ->> 'status' = 'retiring';
    detail := format('suspended: %s; exported: %s; purge due: %s; keys: %s',
                     coalesce(v_row ->> 'suspended_reason', 'missing'), coalesce(v_row2 ->> 'last_export_object', 'missing'),
                     coalesce(v_row3 ->> 'purge_due_at', 'missing'),
                     (select count(*) from jsonb_object_keys(coalesce(v_row, '{}'::jsonb))));
    return next;

    -- ── 25. Not retired while a contract is in force ────────────────────────
    v_step := 'retiring clients under contract';
    begin
      perform public.erp_platform_retire_deployment(v_exp, 'The lifecycle suite retires a client under contract, which must refuse.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_retire_deployment(v_con, 'The lifecycle suite retires a client still under contract while offboarded.');
      v_got2 := 'it was retired';
    exception when others then
      v_got2 := sqlerrm;
    end;
    begin
      perform public.erp_platform_retire_deployment(v_fail, 'The lifecycle suite retires a failed client still under contract.');
      v_got3 := 'it was retired';
    exception when others then
      v_got3 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a deployment a contract in force names is not retired, whatever its status: live, being offboarded, or never built';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_HAS_A_CONTRACT: ' || v_exp || ' is not retired: its contract with Lifecycle Export Ltd is in force until %'
          and v_got2 = 'CLOVEERP_DEPLOYMENT_HAS_A_CONTRACT: ' || v_con || ' is not retired: its contract with Lifecycle Contract Ltd is in force until '
                       || to_char(v_end, 'FMDD Mon YYYY')
          and v_got3 like 'CLOVEERP_DEPLOYMENT_HAS_A_CONTRACT: ' || v_fail || ' is not retired: its contract with Lifecycle Failed Ltd is in force until %'
          and (select d.status from erp_meta.deployment d where d.code = v_exp) = 'live'
          and (select d.status from erp_meta.deployment d where d.code = v_con) = 'retiring'
          and (select d.status from erp_meta.deployment d where d.code = v_fail) = 'retiring';
    detail := left(v_got, 110) || ' / ' || left(v_got2, 110) || ' / ' || left(v_got3, 110);
    return next;

    -- ── 26. Not before its purge date, and not while it is served ───────────
    v_step := 'retiring a client being offboarded too soon';
    update erp_meta.contract c set status = 'expired' where c.id = v_ccon;
    begin
      perform public.erp_platform_retire_deployment(v_con, 'The lifecycle suite retires a client before its purge date.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    -- Its thirty days run out while its address still serves it, with a
    -- copy made the day its offboarding began.
    update erp_meta.deployment x
       set offboarding_at = now() - interval '40 days', purge_due_at = now() - interval '10 days',
           last_export_at = now() - interval '40 days',
           last_export_taken_at = now() - interval '40 days 10 minutes', last_export_service_stopped = false,
           last_export_object = 'exports/' || v_con || '/20260829T120000Z.dump.age'
     where x.code = v_con;
    begin
      perform public.erp_platform_retire_deployment(v_con, 'The lifecycle suite retires a client its address still serves.');
      v_got2 := 'it was retired';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a client being offboarded is not retired before its purge date, nor while its address still serves it, whatever copy it has';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_COOLING_OFF: ' || v_con || ' is not retired: its offboarding runs until '
                      || to_char((v_end::timestamptz + interval '30 days') at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"')
                      || ', when its project may be purged'
          and v_got2 = 'CLOVEERP_DEPLOYMENT_STILL_SERVED: ' || v_con || ' is not retired: its address still serves it, so its '
                       'people can still change its data and a copy taken now would not be the last'
          and (select d.status from erp_meta.deployment d where d.code = v_con) = 'retiring';
    detail := left(v_got, 140) || ' / ' || left(v_got2, 140);
    return next;

    -- ── 27. Not without a copy made since its service stopped ───────────────
    v_step := 'retiring clients whose copy is older than their suspension';
    -- Suspended now, with a copy made after its offboarding began but before.
    perform public.erp_platform_suspend_deployment(v_con, 'The client''s service stops so its last copy can be made.');
    update erp_meta.deployment x
       set last_export_at = now() - interval '5 days',
           last_export_taken_at = now() - interval '5 days 10 minutes', last_export_service_stopped = true,
           last_export_object = 'exports/' || v_con || '/20261003T120000Z.dump.age'
     where x.code = v_con;
    begin
      perform public.erp_platform_retire_deployment(v_con, 'The lifecycle suite retires a client with a copy older than its suspension.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    -- Suspended two days ago, offboarded now, copied in between.
    perform public.erp_platform_begin_offboarding(v_bare, 'The suspended client leaves after all, with nothing left to run.');
    update erp_meta.deployment x
       set purge_due_at = now() - interval '1 minute', last_export_at = now() - interval '1 day',
           last_export_taken_at = now() - interval '1 day 10 minutes', last_export_service_stopped = true,
           last_export_object = 'exports/' || v_bare || '/20261007T120000Z.dump.age'
     where x.code = v_bare;
    begin
      perform public.erp_platform_retire_deployment(v_bare, 'The lifecycle suite retires a client copied before its offboarding began.');
      v_got2 := 'it was retired';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a client being offboarded is not retired before a copy of its data is recorded whose dump began since its service stopped and its offboarding began';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_EXPORTED: ' || v_con || ' is not retired: no copy of its data taken after its service stopped on '
                      || to_char(now() at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"')
                      || ' has been recorded; the last was taken on '
                      || to_char((now() - interval '5 days 10 minutes') at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"')
          and v_got2 = 'CLOVEERP_DEPLOYMENT_NOT_EXPORTED: ' || v_bare || ' is not retired: no copy of its data taken after its service stopped and its offboarding began on '
                       || to_char(now() at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"')
                       || ' has been recorded; the last was taken on '
                       || to_char((now() - interval '1 day 10 minutes') at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"')
          and (select d.status = 'retiring' and d.suspended_at = now() from erp_meta.deployment d where d.code = v_con)
          and (select d.status = 'retiring' and d.suspended_at = now() - interval '2 days'
                 from erp_meta.deployment d where d.code = v_bare);
    detail := left(v_got, 140) || ' / ' || left(v_got2, 160);
    return next;

    -- ── 28. The last copy is one taken after its service stopped ────────────
    v_step := 'retiring a client whose copy was claimed before its service stopped and recorded after';
    -- Thirty days on from the offboarding of case 23. The run claimed before
    -- the stop dumped its data a minute before it, and records it now.
    update erp_meta.deployment x set purge_due_at = now() - interval '1 minute' where x.code = v_fly;
    perform erp_meta.record_deployment_export(v_fly, 'exports/' || v_fly || '/20261008T115900Z.dump.age', 1000,
                                              repeat('d', 64), now() - interval '1 minute', false);
    perform erp_meta.settle_fleet_request(v_f1, 'success: fleet_export.yml wrote the copy');
    begin
      perform public.erp_platform_retire_deployment(v_fly, 'The purge date has come and a copy is recorded since the stop.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    -- The run claimed after the stop dumps it now, but could not confirm its
    -- own organisation was suspended first.
    perform erp_meta.record_deployment_export(v_fly, 'exports/' || v_fly || '/20261008T120000Z.dump.age', 1000,
                                              repeat('e', 64), now(), false);
    begin
      perform public.erp_platform_retire_deployment(v_fly, 'The purge date has come and a later copy is recorded too.');
      v_got2 := 'it was retired';
    exception when others then
      v_got2 := sqlerrm;
    end;
    -- And once more, with its organisation confirmed suspended. Then a run
    -- whose dump began before the stop, still going, records its copy last:
    -- it is recorded, and the newer copy stays the last.
    perform erp_meta.record_deployment_export(v_fly, 'exports/' || v_fly || '/20261008T120001Z.dump.age', 1000,
                                              repeat('f', 64), now(), true);
    v_got3 := erp_meta.record_deployment_export(v_fly, 'exports/' || v_fly || '/20261008T115800Z.dump.age', 1000,
                                                repeat('0', 64), now() - interval '2 minutes', false);
    v_json := public.erp_platform_retire_deployment(v_fly, 'The purge date has come and its last copy is recorded.');
    v_cases := v_cases + 1;
    case_name := 'a copy whose dump began before the client''s service stopped does not let it be retired, though recorded after; nor one taken without its own organisation confirmed suspended; one taken after both does, and an older copy recorded after it does not replace it';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_EXPORTED: ' || v_fly || ' is not retired: no copy of its data taken after its service stopped on '
                      || to_char(now() at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"')
                      || ' has been recorded; the last was taken on '
                      || to_char((now() - interval '1 minute') at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"')
                      || ', without its own organisation confirmed suspended'
          and v_got3 = v_fly || ': copy recorded at exports/' || v_fly || '/20261008T115800Z.dump.age; its dump began '
                       'before that of the copy already recorded, which stays the last'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_fly and e.phase = 'export' and e.status = 'done'
                         and e.detail like '%/20261008T115800Z.dump.age: %; a copy whose dump began later is recorded '
                                           'already, and stays its last')
          and v_got2 = 'CLOVEERP_DEPLOYMENT_NOT_EXPORTED: ' || v_fly || ' is not retired: no copy of its data taken after its service stopped on '
                       || to_char(now() at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"')
                       || ' has been recorded; the last was taken on '
                       || to_char(now() at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"')
                       || ', without its own organisation confirmed suspended'
          and v_json ->> 'status' = c_retired and v_json ->> 'was' = 'retiring'
          and (select d.status = c_retired and d.last_export_service_stopped and d.last_export_taken_at = now()
                      and d.last_export_object = 'exports/' || v_fly || '/20261008T120001Z.dump.age'
                 from erp_meta.deployment d where d.code = v_fly);
    detail := left(v_got, 200) || ' / ' || left(v_got3, 160) || ' / ' || left(v_got2, 200) || ' / ' || coalesce(v_json::text, 'no answer');
    return next;

    -- ── 29. Retired once its offboarding has run its course ─────────────────
    v_step := 'retiring a client whose offboarding has run its course';
    perform erp_meta.record_deployment_export(v_con, 'exports/' || v_con || '/20261008T120000Z.dump.age', 1000, repeat('c', 64),
                                              now(), true);
    -- What the control plane owes it, and what waits for it or is claimed.
    insert into erp_meta.deployment_push (code, kind, payload, status) values (v_con, 'notice', '{"n": 1}', 'pending')
    returning id into v_p1;
    insert into erp_meta.deployment_push (code, kind, payload, status) values (v_con, 'notice', '{"n": 2}', 'claimed')
    returning id into v_p2;
    insert into erp_meta.deployment_push (code, kind, payload, status) values (v_con, 'notice', '{"n": 3}', 'applied');
    insert into erp_meta.fleet_request (kind, payload, reason)
    values ('rename', jsonb_build_object('code', v_con, 'from', v_con, 'to', 'zzlcz-' || v_tag), 'deployment_lifecycle_suite')
    returning id into v_rn;
    insert into erp_meta.fleet_request (kind, payload, reason)
    values ('export', jsonb_build_object('code', v_con), 'deployment_lifecycle_suite')
    returning id into v_e2;
    v_json := public.erp_platform_retire_deployment(v_con, 'The client''s term has ended and its data has been copied.');
    v_got := erp_meta.settle_fleet_request(v_e1, 'success: fleet_export.yml wrote the copy');
    v_cases := v_cases + 1;
    case_name := 'a client being offboarded is retired on its purge date once suspended and copied: what it was owed is failed, and its waiting and claimed requests are cancelled, a late word on one quiet';
    passed := v_json ->> 'status' = c_retired and v_json ->> 'was' = 'retiring'
          and (v_json ->> 'pushes_failed')::integer = 2
          and (v_json ->> 'requests_cancelled')::integer = 4
          and (select string_agg(p.status, ',' order by p.payload ->> 'n') from erp_meta.deployment_push p where p.code = v_con)
              = 'failed,failed,applied'
          and (select bool_and(p.detail = 'the deployment was retired, so it is owed nothing more' and p.settled_at = now())
                 from erp_meta.deployment_push p where p.id in (v_p1, v_p2))
          and (select string_agg(r.status || '|' || r.outcome, ',')
                 from erp_meta.fleet_request r where r.id in (v_rn, v_e2, v_e1, v_s2))
              = 'cancelled|the deployment was retired,cancelled|the deployment was retired,'
                'cancelled|the deployment was retired,cancelled|the deployment was retired'
          and v_got like 'request % was cancelled meanwhile (the deployment was retired); left as it is'
          and (select d.status = c_retired and d.suspended_reason is null and d.suspended_at is null
                      and d.owner_email is null
                 from erp_meta.deployment d where d.code = v_con);
    detail := coalesce(v_json::text, 'no answer') || ' / late settle: ' || left(v_got, 90);
    return next;

    -- ── 30. Never built, and never offboarded ───────────────────────────────
    v_step := 'retiring a client never built and one never offboarded';
    update erp_meta.contract c set status = 'expired' where c.id = v_cfail;
    update erp_meta.deployment x
       set offboarding_at = now() - interval '31 days', purge_due_at = now() - interval '1 day'
     where x.code = v_fail;
    v_json := public.erp_platform_retire_deployment(v_fail, 'The client never had a database and its offboarding has run its course.');
    v_json2 := public.erp_platform_retire_deployment(v_built, 'The lifecycle suite retires a built client with no contract directly.');
    v_cases := v_cases + 1;
    case_name := 'one being offboarded that was never built is retired on its purge date without a copy, and one under no contract and not being offboarded is retired directly';
    passed := v_json ->> 'status' = c_retired and v_json ->> 'was' = 'retiring'
          and (v_json ->> 'requests_cancelled')::integer = 0
          and v_json2 ->> 'status' = c_retired and v_json2 ->> 'was' = 'built'
          -- Its status sync, and the export its offboarding asked for before
          -- it was taken back.
          and (v_json2 ->> 'requests_cancelled')::integer = 2
          and (select count(*) from erp_meta.deployment d where d.code in (v_fail, v_built) and d.status = c_retired) = 2;
    detail := coalesce(v_json::text, 'no answer') || ' / ' || coalesce(v_json2::text, 'no answer');
    return next;

    -- ── 31. Not while a release may still run ───────────────────────────────
    v_step := 'retiring clients a release started for a hundred minutes and two hours ago';
    -- release.yml's job recorded its start and may then wait for a copy
    -- before it replays: it runs for up to ninety-five minutes.
    insert into erp_meta.deployment_event (code, phase, status, detail, run_id, at)
    values (v_rel, 'release', 'started', 'a release has started', 'run-' || v_tag || '-r1', now() - interval '100 minutes'),
           (v_rlo, 'release', 'started', 'a release has started', 'run-' || v_tag || '-r2', now() - interval '2 hours 1 minute');
    begin
      perform public.erp_platform_retire_deployment(v_rel, 'The lifecycle suite retires a client during a long release.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    v_json := public.erp_platform_retire_deployment(v_rlo, 'The lifecycle suite retires a client whose release has long ended.');
    v_cases := v_cases + 1;
    case_name := 'a deployment is not retired while a release to it may still be running, for two hours from its start, past the ninety-five minutes a release job may run';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_RETIRABLE: ' || v_rel || ' is not retired: a release to it has started and not finished'
          and (select d.status from erp_meta.deployment d where d.code = v_rel) = 'live'
          and v_json ->> 'status' = c_retired and v_json ->> 'was' = 'live';
    detail := left(v_got, 120) || ' / ' || coalesce(v_json::text, 'no answer');
    return next;

    -- ── 32. Its mail ────────────────────────────────────────────────────────
    v_step := 'claiming the mail a retired deployment''s contract still had queued';
    insert into erp_meta.contract_invoice (contract_id, tenant_id, tenant_code, seq, reference, period_start, period_end,
                                           due_on, currency, subscription_minor, total_minor, status, issued_at)
    values (v_ccon, null, v_con, 1, 'CI-LCC-' || v_tag, current_date - 165, v_end, current_date + 14, 'GBP', 120000, 120000,
            'issued', now())
    returning id into v_i1;
    insert into erp_meta.contract_invoice (contract_id, tenant_id, tenant_code, seq, reference, period_start, period_end,
                                           due_on, currency, subscription_minor, total_minor, status, issued_at)
    values (v_cexp, null, v_exp, 1, 'CI-LCE-' || v_tag, current_date - 65, current_date + 300, current_date + 14, 'GBP', 90000,
            90000, 'issued', now())
    returning id into v_i2;
    insert into erp_meta.commercial_email (kind, contract_invoice_id, tenant_code, send_number, to_address, to_name,
                                           recipient_source, requested_by, idempotency_key)
    values ('contract_invoice', v_i1, v_con, 1, 'billing@' || v_con || '.test', 'Billing', 'billing_contact', v_owner,
            'lifecycle-' || v_tag || '-con')
    returning id into v_m1;
    insert into erp_meta.commercial_email (kind, contract_invoice_id, tenant_code, send_number, to_address, to_name,
                                           recipient_source, requested_by, idempotency_key)
    values ('contract_invoice', v_i2, v_exp, 1, 'billing@' || v_exp || '.test', 'Billing', 'billing_contact', v_owner,
            'lifecycle-' || v_tag || '-exp')
    returning id into v_m2;
    select count(*) into v_n from erp.claim_commercial_email_batch(50, 'deployment_lifecycle_suite');
    v_cases := v_cases + 1;
    case_name := 'mail owed under a retired deployment''s contract is cancelled when the drain claims it, as a gone organisation''s is, and a served one''s is sent';
    passed := (select e.status || '|' || e.failure_reason from erp_meta.commercial_email e where e.id = v_m1)
              = 'cancelled|the client deployment it is for is retired'
          and (select e.status from erp_meta.commercial_email e where e.id = v_m2) = 'sending'
          and v_n >= 1;
    detail := format('retired: %s; served: %s; %s claimed',
                     coalesce((select e.status || ' (' || coalesce(e.failure_reason, 'no reason') || ')'
                                 from erp_meta.commercial_email e where e.id = v_m1), 'gone'),
                     coalesce((select e.status from erp_meta.commercial_email e where e.id = v_m2), 'gone'), v_n);
    return next;

    -- ── 33. The doors' standing ─────────────────────────────────────────────
    v_step := 'reading the doors';
    select count(*) into v_n
      from pg_catalog.pg_proc p
     where p.oid in ('public.erp_platform_suspend_deployment(text,text)'::regprocedure,
                     'public.erp_platform_reinstate_deployment(text,text)'::regprocedure,
                     'public.erp_platform_rename_deployment(text,text,text)'::regprocedure,
                     'public.erp_platform_begin_offboarding(text,text)'::regprocedure,
                     'public.erp_platform_cancel_offboarding(text,text)'::regprocedure,
                     'public.erp_platform_request_export(text,text)'::regprocedure)
       and p.prosecdef
       and p.provolatile = 'v'
       and pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and pg_catalog.has_function_privilege('service_role', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')
       and exists (select 1 from erp_meta.security_definer_allowance a
                    where a.schema_name = 'public' and a.function_name = p.proname)
       and exists (select 1 from erp_meta.public_write_allowance w where w.function_name = p.proname);
    select count(*) into v_n2
      from erp_meta.platform_door_rank r
     where r.schema_name = 'public' and r.minimum_role = 'owner'
       and r.function_name in ('erp_platform_suspend_deployment', 'erp_platform_reinstate_deployment',
                               'erp_platform_rename_deployment', 'erp_platform_begin_offboarding',
                               'erp_platform_cancel_offboarding');
    select count(*) into v_n3
      from pg_catalog.pg_proc p
     where p.oid in ('erp_meta.finish_deployment_rename(text,text)'::regprocedure,
                     'erp_meta.record_deployment_export(text,text,bigint,text,timestamptz,boolean)'::regprocedure,
                     'erp_meta.rename_client_organisation(text)'::regprocedure,
                     'erp_meta.follow_deployment_status(boolean,text)'::regprocedure,
                     'erp_meta.deployment_address_starts_as_its_code()'::regprocedure)
       and not p.prosecdef
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('service_role', p.oid, 'execute');
    v_cases := v_cases + 1;
    case_name := 'the six doors run as their owner for signed-in callers and not anon, on both allowances, the owner''s five ranked; the trusted routines reach no session role';
    passed := v_n = 6 and v_n2 = 5 and v_n3 = 5
          and not exists (select 1 from erp_meta.platform_door_rank r where r.function_name = 'erp_platform_request_export')
          and not exists (select 1 from pg_catalog.pg_class c
                           where c.oid = 'erp_meta.deployment_previous_address'::regclass
                             and (pg_catalog.has_table_privilege('anon', c.oid, 'select')
                                  or pg_catalog.has_table_privilege('authenticated', c.oid, 'select')));
    detail := format('%s of 6 doors, %s of 5 ranks, %s of 5 trusted routines', v_n, v_n2, v_n3);
    return next;

    -- ── 34. A client's own organisation follows: only on a client ───────────
    v_step := 'following the register off a client, and on one with no organisation';
    begin
      perform erp_meta.follow_deployment_status(true, c_reason);
      v_got := 'it followed on the control plane';
    exception when others then
      v_got := sqlerrm;
    end;
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason) values
      ('deployment.kind', '"client"'::jsonb, 'deployment_lifecycle_suite'),
      ('deployment.app_origin', to_jsonb('https://' || v_client || '.cloveerp.com'), 'deployment_lifecycle_suite');
    -- Whatever organisations this database holds are put out of the way for
    -- the rest of the suite: a client starts empty.
    update erp.tenant t set status = 'deleted' where t.status not in ('deleting', 'deleted');
    v_json := erp_meta.follow_deployment_status(true, 'The client has not paid for two months; suspended until it does.');
    v_cases := v_cases + 1;
    case_name := 'the register''s suspension is followed only on a client''s own deployment, and one with no organisation yet has nothing to follow';
    passed := v_got = 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the production deployment, not a client''s own, so it does not follow the register''s suspension'
          and v_json = jsonb_build_object('changed', false, 'status', null, 'by_fleet', false)
          and not exists (select 1 from erp_meta.platform_setting s where s.key = c_marker);
    detail := left(v_got, 120) || ' / ' || coalesce(v_json::text, 'no answer');
    return next;

    -- ── 35. Suspended by the fleet, and lifted ──────────────────────────────
    v_step := 'suspending and reinstating a client''s organisation from the register';
    v_json := public.erp_platform_onboard_company(v_client, 'Lifecycle Client Ltd', 'admin@' || v_client || '.test', 'Client Admin');
    v_tenant := (v_json ->> 'tenant_id')::uuid;
    update erp.tenant t set status = 'active' where t.id = v_tenant and t.status <> 'active';
    v_json := erp_meta.follow_deployment_status(true, 'The client has not paid for two months; suspended until it does.');
    v_mark := (select s.value from erp_meta.platform_setting s where s.key = c_marker);
    v_got := (select t.status::text || '|' || (t.suspended_at = (v_mark ->> 'suspended_at')::timestamptz)::text
                     || '|' || (t.suspended_at >= now())::text
                from erp.tenant t where t.id = v_tenant);
    v_got2 := v_mark ->> 'reason';
    v_json2 := erp_meta.follow_deployment_status(true, 'The client has still not paid; it stays suspended.');
    v_got3 := (select (s.value ->> 'reason') || '|' || (s.value -> 'suspended_at' = v_mark -> 'suspended_at')::text
                 from erp_meta.platform_setting s where s.key = c_marker);
    v_json3 := erp_meta.follow_deployment_status(false, null);
    v_row := erp_meta.follow_deployment_status(false, null);
    v_cases := v_cases + 1;
    case_name := 'the register''s suspension suspends a client''s active organisation and marks it the fleet''s with the moment it did, and lifting it reinstates only that, logged as the system';
    passed := v_json = jsonb_build_object('changed', true, 'status', 'suspended', 'by_fleet', true)
          and v_got = 'suspended|true|true'
          and v_got2 = 'The client has not paid for two months; suspended until it does.'
          and v_json2 = jsonb_build_object('changed', false, 'status', 'suspended', 'by_fleet', true)
          and v_got3 = 'The client has still not paid; it stays suspended.|true'
          and v_json3 = jsonb_build_object('changed', true, 'status', 'active', 'by_fleet', false)
          and v_row = jsonb_build_object('changed', false, 'status', 'active', 'by_fleet', false)
          and (select t.status::text = 'active' and t.suspended_at is null from erp.tenant t where t.id = v_tenant)
          and not exists (select 1 from erp_meta.platform_setting s where s.key = c_marker)
          and (select string_agg(a.detail ->> 'from' || '>' || (a.detail ->> 'to'), ',' order by a.occurred_at, a.detail ->> 'to' desc)
                 from erp_meta.platform_audit a
                where a.action = 'platform.tenant_status_changed' and a.tenant_id = v_tenant
                  and a.actor_email = 'system' and a.detail ->> 'by' = 'the fleet''s status sync')
              in ('active>suspended,suspended>active', 'suspended>active,active>suspended')
          and not (select p.prosecdef from pg_catalog.pg_proc p
                    where p.oid = 'erp_meta.follow_deployment_status(boolean,text)'::regprocedure);
    detail := coalesce(v_json::text, '-') || ' / ' || coalesce(v_got, '-') || ' / ' || coalesce(v_json2::text, '-')
           || ' / ' || coalesce(v_json3::text, '-') || ' / ' || coalesce(v_row::text, '-');
    return next;

    -- ── 36. A suspension made after the fleet's is not lifted ───────────────
    v_step := 'lifting the register''s suspension after the organisation was suspended again on the client';
    v_json := erp_meta.follow_deployment_status(true, 'The client has not paid again; suspended until it does.');
    -- Support on the client's own console reactivates it and suspends it
    -- again, for a reason of its own.
    perform public.erp_platform_set_tenant_status(v_tenant, 'active', null);
    perform public.erp_platform_set_tenant_status(v_tenant, 'suspended', 'Fraud investigation opened by support.');
    v_got := (select (s.value ->> 'reason') from erp_meta.platform_setting s where s.key = c_marker);
    v_json2 := erp_meta.follow_deployment_status(false, null);
    v_cases := v_cases + 1;
    case_name := 'a suspension made on the client after the fleet''s is not lifted when the register lifts its own: the marker no longer names it, and is taken away';
    passed := v_json = jsonb_build_object('changed', true, 'status', 'suspended', 'by_fleet', true)
          and v_got = 'The client has not paid again; suspended until it does.'
          and v_json2 = jsonb_build_object('changed', false, 'status', 'suspended', 'by_fleet', false)
          and (select t.status::text = 'suspended' and t.suspended_at = now() from erp.tenant t where t.id = v_tenant)
          and not exists (select 1 from erp_meta.platform_setting s where s.key = c_marker)
          -- The one reinstatement the system logged is the one before.
          and (select count(*) from erp_meta.platform_audit a
                where a.action = 'platform.tenant_status_changed' and a.tenant_id = v_tenant
                  and a.actor_email = 'system' and a.detail ->> 'to' = 'active') = 1;
    detail := coalesce(v_json::text, '-') || ' / ' || coalesce(v_json2::text, '-');
    return next;

    -- ── 37. An older marker names no suspension ─────────────────────────────
    v_step := 'following the register with a marker that keeps only a reason';
    insert into erp_meta.platform_setting (key, value, reason)
    values (c_marker, to_jsonb('The client has not paid for two months.'::text), 'deployment_lifecycle_suite');
    v_json := erp_meta.follow_deployment_status(true, 'The register still holds the client suspended.');
    v_got := coalesce((select s.value::text from erp_meta.platform_setting s where s.key = c_marker), 'gone');
    insert into erp_meta.platform_setting (key, value, reason)
    values (c_marker, to_jsonb('The client has not paid for two months.'::text), 'deployment_lifecycle_suite');
    v_json2 := erp_meta.follow_deployment_status(false, null);
    v_cases := v_cases + 1;
    case_name := 'a marker that keeps only a reason names no suspension: the register neither claims nor lifts the organisation''s, and the marker is taken away';
    passed := v_json = jsonb_build_object('changed', false, 'status', 'suspended', 'by_fleet', false)
          and v_got = 'gone'
          and v_json2 = jsonb_build_object('changed', false, 'status', 'suspended', 'by_fleet', false)
          and (select t.status::text = 'suspended' from erp.tenant t where t.id = v_tenant)
          and not exists (select 1 from erp_meta.platform_setting s where s.key = c_marker);
    detail := coalesce(v_json::text, '-') || ' / marker after: ' || v_got || ' / ' || coalesce(v_json2::text, '-');
    return next;

    -- ── 38. A suspension not the fleet's is left alone ──────────────────────
    v_step := 'following the register for an organisation suspended by somebody else';
    update erp.tenant t set status = 'suspended', suspended_at = now() - interval '1 day' where t.id = v_tenant;
    v_json := erp_meta.follow_deployment_status(true, 'The register holds the client suspended as well.');
    v_json2 := erp_meta.follow_deployment_status(false, null);
    v_cases := v_cases + 1;
    case_name := 'an organisation suspended by somebody else is neither marked the fleet''s nor lifted by the register';
    passed := v_json = jsonb_build_object('changed', false, 'status', 'suspended', 'by_fleet', false)
          and v_json2 = jsonb_build_object('changed', false, 'status', 'suspended', 'by_fleet', false)
          and (select t.status::text = 'suspended' and t.suspended_at = now() - interval '1 day'
                 from erp.tenant t where t.id = v_tenant)
          and not exists (select 1 from erp_meta.platform_setting s where s.key = c_marker);
    detail := coalesce(v_json::text, '-') || ' / ' || coalesce(v_json2::text, '-');
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
    raise exception 'CLOVEERP_DEPLOYMENT_LIFECYCLE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_deployment_lifecycle_suite()
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
    from erp_test.deployment_lifecycle_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEPLOYMENT_LIFECYCLE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Suspending, reinstating, offboarding, exporting or retiring a client deployment, or a client''s organisation following the register, does not do what the Fleet relies on: read the case that failed.';
  end if;
  if v_total <> 38 then
    raise exception 'CLOVEERP_DEPLOYMENT_LIFECYCLE_SUITE_SHRANK: % case(s), expected 38', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment lifecycle: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.deployment_lifecycle_suite() from public, anon;
revoke all on function erp_test.assert_deployment_lifecycle_suite() from public, anon;

comment on function erp_test.assert_deployment_lifecycle_suite() is
  'A client deployment is suspended and reinstated by the owner on the control plane with a reason — while it is '
  'built, live or being offboarded — since when kept with why, its address answering that it is suspended while it '
  'keeps receiving releases, a status sync asked for, and reinstated live or built as its releases say; offboarding '
  'makes it retiring with when it began, its purge date, its suspension kept and an export if it was built, cancels '
  'a build only waiting but not one started in the last ninety minutes, lets go a claim older than that, and may be '
  'cancelled; one never built is served nowhere; an operator asks for exports, recorded by the trusted build role in '
  'their own form with when their dump began and whether the client''s organisation was confirmed suspended, the '
  'newest kept, one its run left claimed for four hours let go, and one claimed before the service stopped standing '
  'for no ask since; the Fleet view carries it all; retiring refuses under a contract in force, while a release may '
  'still run, before the purge date, while its address still serves it and before a copy taken after its service '
  'stopped, and fails or cancels what was owed or asked; a retired deployment''s mail is not sent; and a client''s '
  'own organisation follows the register''s suspension, lifting only the one it made, at the moment it made it '
  '(20261012030000).';

create or replace function erp_test.deployment_rename_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 16;
  c_reason   constant text := 'The rename suite asks for this, and undoes it.';
  c_lock     constant text := 'pg_advisory_xact_lock(hashtext(''erp_meta.deployment.address''))';
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_uid      uuid := gen_random_uuid();
  v_role     text := current_user;
  v_owner    text;
  v_apex     text;
  v_a        text;
  v_b        text;
  v_r        text;
  v_s        text;
  v_x        text;
  v_y        text;
  v_z        text;
  v_w        text;
  v_u        text;
  v_c1       text;
  v_c2       text;
  v_reserved text;
  v_tenant   uuid;
  v_json     jsonb;
  v_json2    jsonb;
  v_json3    jsonb;
  v_row      jsonb;
  v_row2     jsonb;
  v_row3     jsonb;
  v_claim    jsonb;
  v_got      text;
  v_got2     text;
  v_got3     text;
  v_got4     text;
  v_bad      text;
  v_who      text[];
  v_sql      text[];
  v_want     text[];
  v_n        integer;
  v_q1       uuid;
  v_q2       uuid;
  v_q3       uuid;
  v_q4       uuid;
  v_step     text := 'standing up an owner on the control plane';
  v_state    text;
begin
  begin
    v_owner := 'owner@zzrno-' || v_tag || '.test';
    v_a := 'zzrna-' || v_tag;
    v_b := 'zzrnb-' || v_tag;
    v_r := 'zzrnr-' || v_tag;
    v_s := 'zzrns-' || v_tag;
    v_x := 'zzrnx-' || v_tag;
    v_y := 'zzrny-' || v_tag;
    v_z := 'zzrnz-' || v_tag;
    v_w := 'zzrnw-' || v_tag;
    v_u := 'zzrnu-' || v_tag;
    v_c1 := 'zzrnc-' || v_tag;
    v_c2 := 'zzrnd-' || v_tag;
    v_reserved := (select r.code from erp_meta.reserved_tenant_code r
                    where not r.platform_may_hold and r.code ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
                    order by r.code limit 1);
    insert into auth.users (id, email, email_confirmed_at) values (v_uid, v_owner, now());
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Deployment Rename Suite Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin', 'deployment.ref');
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'deployment_rename_suite');
    v_apex := regexp_replace(erp.app_origin(), '^https://', '');
    -- Older open requests would be claimed first; they wait out the suite.
    update erp_meta.fleet_request x set status = 'cancelled', settled_at = now()
     where x.status in ('requested', 'claimed');

    v_step := 'registering four client deployments';
    insert into erp_meta.deployment (code, client_name, status, owner_email, project_ref, api_url, publishable_key,
                                     built_at, suspended_reason, suspended_at)
    select y.code, y.name, y.status, 'admin@' || y.code || '.test', substr(md5(y.code), 1, 20),
           'https://' || substr(md5(y.code), 1, 20) || '.supabase.co', 'sb_publishable_' || replace(y.code, '-', ''),
           now() - interval '3 days', y.why, case when y.why is not null then now() - interval '1 day' end
      from (values (v_a, 'Rename Alpha Ltd', 'live', null), (v_b, 'Rename Beta Ltd', 'live', null),
                   (v_s, 'Rename Suspended Ltd', 'suspended', 'The rename suite holds this client suspended.'))
           as y(code, name, status, why);
    insert into erp_meta.deployment (code, client_name, status, owner_email)
    values (v_r, 'Rename Requested Ltd', 'requested', 'admin@' || v_r || '.test');

    -- ── 1. Who may ask, where, and for what ─────────────────────────────────
    v_step := 'asking off the control plane, below rank, without a reason, for nobody, and for a build';
    v_who := array['operator', 'client', 'owner', 'owner', 'owner'];
    v_sql := array[
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, v_x, c_reason),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, v_x, c_reason),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, v_x, 'moving'),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', 'zznobody-' || v_tag, v_x, c_reason),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_r, v_x, c_reason)];
    v_want := array['CLOVEERP_PLATFORM_ROLE_TOO_LOW', 'CLOVEERP_NOT_THE_CONTROL_PLANE', 'CLOVEERP_REASON_REQUIRED',
                    'CLOVEERP_DEPLOYMENT_UNKNOWN',
                    'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE: ' || v_r || ' is not moved: it is requested, and only a built, live or suspended deployment is moved'];
    v_n := 0;
    for i in 1 .. cardinality(v_sql) loop
      update erp_meta.platform_staff s
         set staff_role = case when v_who[i] = 'client' then 'owner' else v_who[i] end
       where s.auth_user_id = v_uid;
      delete from erp_meta.platform_setting where key = 'deployment.kind';
      insert into erp_meta.platform_setting (key, value, reason)
      values ('deployment.kind', to_jsonb(case when v_who[i] = 'client' then 'client' else 'production' end),
              'deployment_rename_suite');
      begin
        execute v_sql[i];
        v_got := 'it was asked for';
      exception when others then
        v_got := sqlerrm;
      end;
      if v_got like v_want[i] || '%' then
        v_n := v_n + 1;
      else
        v_bad := coalesce(v_bad || ' / ', '') || i || ': ' || left(v_got, 80);
      end if;
    end loop;
    update erp_meta.platform_staff s set staff_role = 'owner' where s.auth_user_id = v_uid;
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'deployment_rename_suite');
    v_cases := v_cases + 1;
    case_name := 'a rename is asked for by the owner on the control plane, with a reason, for a deployment that is built, live or suspended';
    passed := v_n = 5
          and not exists (select 1 from erp_meta.fleet_request r where r.kind = 'rename')
          and (select d.address from erp_meta.deployment d where d.code = v_a) = v_a;
    detail := format('%s of 5 refused as they should be%s', v_n, coalesce('; ' || v_bad, ''));
    return next;

    -- ── 2. Only to an address nobody has ────────────────────────────────────
    v_step := 'asking for addresses that cannot be given';
    v_want := array['CLOVEERP_ADDRESS_SHAPE', 'CLOVEERP_ADDRESS_RESERVED', 'CLOVEERP_ADDRESS_TAKEN: "' || v_b || '" is a client deployment''s address',
                    'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE: ' || v_a || ' is not moved: it is served at ' || v_a || ' already'];
    v_sql := array[
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, 'Not_An_Address', c_reason),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, v_reserved, c_reason),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, v_b, c_reason),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, upper(v_a), c_reason)];
    v_n := 0;
    v_bad := null;
    for i in 1 .. cardinality(v_sql) loop
      begin
        execute v_sql[i];
        v_got := 'it was asked for';
      exception when others then
        v_got := sqlerrm;
      end;
      if v_got like v_want[i] || '%' then
        v_n := v_n + 1;
      else
        v_bad := coalesce(v_bad || ' / ', '') || i || ': ' || left(v_got, 80);
      end if;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'a deployment is moved only to an address in the shape of one that is not reserved, not another''s, and not its own already';
    passed := v_n = 4 and v_reserved is not null
          and not exists (select 1 from erp_meta.fleet_request r where r.kind = 'rename');
    detail := format('%s of 4 refused (reserved word %s)%s', v_n, coalesce(v_reserved, 'none found'), coalesce('; ' || v_bad, ''));
    return next;

    -- ── 3. A rename asked for ───────────────────────────────────────────────
    v_step := 'asking for two renames';
    v_json := public.erp_platform_rename_deployment(v_a, '  ' || upper(v_x) || ' ', 'The client changed its trading name and asked for a new address.');
    v_q1 := (v_json ->> 'request_id')::uuid;
    v_json2 := public.erp_platform_rename_deployment(v_s, v_w, 'The suspended client asked for a new address before it returns.');
    v_q2 := (v_json2 ->> 'request_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'a rename of a live or suspended deployment queues a request from its address to the new one, and moves nothing yet';
    passed := v_json ->> 'address' = v_a and v_json ->> 'to' = v_x and v_json ->> 'status' = 'live'
          and v_json -> 'let_go_request_ids' = '[]'::jsonb
          and (select r.kind = 'rename' and r.status = 'requested'
                      and r.payload = jsonb_build_object('code', v_a, 'from', v_a, 'to', v_x)
                 from erp_meta.fleet_request r where r.id = v_q1)
          and (select r.payload ->> 'to' from erp_meta.fleet_request r where r.id = v_q2) = v_w
          and v_json2 ->> 'status' = 'suspended'
          and (select d.address from erp_meta.deployment d where d.code = v_a) = v_a
          and not exists (select 1 from erp_meta.deployment_previous_address pa where pa.code = v_a)
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_a and e.phase = 'note'
                         and e.detail like 'a move from ' || v_a || ' to ' || v_x || ' asked for by ' || v_owner || ': The client changed its trading name%')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_rename_requested' and a.target = v_a
                         and a.detail ->> 'to' = v_x and a.detail ->> 'request_id' = v_q1::text);
    detail := coalesce(v_json::text, 'no answer') || ' / ' || coalesce(v_json2::text, 'no answer');
    return next;

    -- ── 4. Held while it waits ──────────────────────────────────────────────
    v_step := 'asking again while a rename waits';
    begin
      perform public.erp_platform_rename_deployment(v_a, v_y, c_reason);
      v_got := 'it was asked for again';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_rename_deployment(v_b, v_x, c_reason);
      v_got2 := 'another took the same address';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_got3 := coalesce(erp.tenant_code_refusal(v_x, null), 'no refusal');
    begin
      perform public.erp_platform_request_deployment(v_x, 'Rename Taker Ltd', 'admin@' || v_x || '.test', c_reason);
      v_got4 := 'it was requested';
    exception when others then
      v_got4 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'while a rename waits the deployment is not renamed again, and the address it is moving to is held from every other deployment and organisation';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE: ' || v_a || ' is not moved: a rename of it is already waiting or running'
          and v_got2 = 'CLOVEERP_ADDRESS_TAKEN: "' || v_x || '" is the address a client deployment is being moved to'
          and v_got3 = v_got2
          and v_got4 = v_got2;
    detail := left(v_got, 90) || ' / ' || left(v_got2, 90) || ' / ' || left(v_got4, 60);
    return next;

    -- ── 5. The sweep claims it ──────────────────────────────────────────────
    v_step := 'claiming a rename';
    update erp_meta.fleet_request x set created_at = now() - interval '5 minutes' where x.id = v_q1;
    v_got := coalesce(erp_meta.claim_fleet_request('run-' || v_tag || '-b', array['build', 'release', 'export', 'sync'])::text, 'nothing');
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-r', array['rename']);
    begin
      insert into erp_meta.fleet_request (kind, payload) values ('rename', jsonb_build_object('code', v_b, 'to', v_y));
      v_got2 := 'it was kept';
    exception when check_violation then
      v_got2 := 'refused';
    end;
    v_cases := v_cases + 1;
    case_name := 'the sweep claims the oldest rename when it asks for renames, and no other kind takes it; a rename without where from is not kept';
    passed := v_got = 'nothing'
          and v_claim ->> 'id' = v_q1::text and v_claim ->> 'kind' = 'rename'
          and v_claim -> 'payload' = jsonb_build_object('code', v_a, 'from', v_a, 'to', v_x)
          and (select r.status || ' ' || r.run_id from erp_meta.fleet_request r where r.id = v_q1) = 'claimed run-' || v_tag || '-r'
          and v_got2 = 'refused';
    detail := 'other kinds: ' || v_got || ' / ' || coalesce(v_claim::text, 'nothing claimed') || ' / ' || v_got2;
    return next;

    -- ── 6. The register moves it ────────────────────────────────────────────
    v_step := 'finishing the rename';
    v_got := erp_meta.finish_deployment_rename(v_a, v_x);
    v_got2 := erp_meta.finish_deployment_rename(upper(v_a), ' ' || v_x);
    v_got3 := erp_meta.settle_fleet_request(v_q1, 'success: fleet_rename.yml re-pointed the project');
    v_cases := v_cases + 1;
    case_name := 'the rename is finished by the trusted build role alone: the address moves, the old one is held for it and leads to it for ninety days, and finishing again moves nothing';
    passed := v_got = v_a || ' moved from ' || v_a || ' to ' || v_x
          and v_got2 = v_a || ' is served at ' || v_x || ' already'
          and (select d.address from erp_meta.deployment d where d.code = v_a) = v_x
          and (select string_agg(pa.address || '|' || (pa.redirect_until = now() + interval '90 days')::text, ',')
                 from erp_meta.deployment_previous_address pa where pa.code = v_a) = v_a || '|true'
          and (select count(*) from erp_meta.deployment_event e where e.code = v_a and e.phase = 'rename') = 1
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_a and e.phase = 'rename' and e.status = 'done'
                         and e.detail like 'moved from ' || v_a || '.' || v_apex || ' to ' || v_x || '.' || v_apex
                                           || '; the old address leads to the new one until %, and stays held for it')
          and (select r.status from erp_meta.fleet_request r where r.id = v_q1) = 'done'
          and not (select p.prosecdef from pg_catalog.pg_proc p
                    where p.oid = 'erp_meta.finish_deployment_rename(text,text)'::regprocedure)
          and not pg_catalog.has_function_privilege('anon', 'erp_meta.finish_deployment_rename(text,text)', 'execute')
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.finish_deployment_rename(text,text)', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.finish_deployment_rename(text,text)', 'execute');
    detail := v_got || ' / ' || v_got2 || ' / ' || v_got3;
    return next;

    -- ── 7. Where it is found ────────────────────────────────────────────────
    v_step := 'asking the directory for the new address and the old one';
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json := public.erp_deployment_for_host(v_x || '.' || v_apex);
    v_json2 := public.erp_deployment_for_host(v_a || '.' || v_apex);
    execute format('set local role %I', v_role);
    update erp_meta.deployment_previous_address pa set redirect_until = now() - interval '1 minute' where pa.address = v_a;
    execute 'set local role service_role';
    v_json3 := public.erp_deployment_for_host(v_a || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_row2 := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_a);
    update erp_meta.deployment_previous_address pa set redirect_until = now() + interval '90 days' where pa.address = v_a;
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_a);
    v_cases := v_cases + 1;
    case_name := 'the new address answers with the project, the old one says where it went for ninety days and nothing after, and the Fleet view says both while it leads there';
    passed := v_json = jsonb_build_object('code', v_a, 'client_name', 'Rename Alpha Ltd',
                                          'url', 'https://' || substr(md5(v_a), 1, 20) || '.supabase.co',
                                          'key', 'sb_publishable_' || replace(v_a, '-', ''))
          and v_json2 = jsonb_build_object('code', v_a, 'client_name', 'Rename Alpha Ltd',
                                           'moved_to', 'https://' || v_x || '.' || v_apex)
          and v_json3 is null
          and jsonb_typeof(v_row2 -> 'previous_address') = 'null'
          and v_row ->> 'origin' = 'https://' || v_x || '.' || v_apex
          and v_row ->> 'address' = v_x
          and v_row ->> 'previous_address' = v_a
          and (v_row ->> 'previous_address_until')::timestamptz = now() + interval '90 days';
    detail := coalesce(v_json::text, 'nothing') || ' / ' || coalesce(v_json2::text, 'nothing') || ' / after: '
           || coalesce(v_json3::text, 'nothing');
    return next;

    -- ── 8. A second rename keeps the first one's way there ──────────────────
    v_step := 'moving it again and asking for what it had';
    v_json := public.erp_platform_rename_deployment(v_a, v_z, 'The client changed its mind and asked for another address.');
    -- As the sweep and the workflow would: claimed (before the suspended
    -- client's, which is younger), finished, settled.
    update erp_meta.fleet_request x set created_at = now() - interval '4 minutes'
     where x.id = (v_json ->> 'request_id')::uuid;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-r2', array['rename']);
    perform erp_meta.finish_deployment_rename(v_a, v_z);
    perform erp_meta.settle_fleet_request((v_claim ->> 'id')::uuid, 'success: fleet_rename.yml re-pointed the project');
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json2 := public.erp_deployment_for_host(v_a || '.' || v_apex);
    v_json3 := public.erp_deployment_for_host(v_x || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_a);
    v_got := coalesce(erp.tenant_code_refusal(v_x, null), 'no refusal');
    v_got2 := coalesce(erp.tenant_code_refusal(v_a, null), 'no refusal');
    v_got3 := coalesce(erp.tenant_code_refusal(v_z, null), 'no refusal');
    begin
      perform public.erp_platform_rename_deployment(v_b, v_x, c_reason);
      v_got4 := 'it was given';
    exception when others then
      v_got4 := sqlerrm;
    end;
    begin
      perform public.erp_platform_request_deployment(v_x, 'Rename Taker Ltd', 'admin@' || v_x || '.test', c_reason);
      v_bad := 'it was requested';
    exception when others then
      v_bad := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a second rename keeps the first one''s address leading to where it is now, the Fleet view names the newest, and every address it had stays held from the fleet';
    passed := (select d.address from erp_meta.deployment d where d.code = v_a) = v_z
          and (select string_agg(pa.address || '|' || (pa.redirect_until = now() + interval '90 days')::text, ',' order by pa.address)
                 from erp_meta.deployment_previous_address pa where pa.code = v_a) = v_a || '|true,' || v_x || '|true'
          and v_claim ->> 'id' = v_json ->> 'request_id'
          and (select r.status from erp_meta.fleet_request r where r.id = (v_json ->> 'request_id')::uuid) = 'done'
          and v_json2 = jsonb_build_object('code', v_a, 'client_name', 'Rename Alpha Ltd',
                                           'moved_to', 'https://' || v_z || '.' || v_apex)
          and v_json3 = v_json2
          and v_row ->> 'previous_address' = v_x
          and v_got = 'CLOVEERP_ADDRESS_TAKEN: "' || v_x || '" was a client deployment''s address and is kept for it'
          and v_got2 = 'CLOVEERP_ADDRESS_TAKEN: "' || v_a || '" is a client deployment''s address'
          and v_got3 = 'CLOVEERP_ADDRESS_TAKEN: "' || v_z || '" is a client deployment''s address'
          and v_got4 = v_got
          and v_bad = v_got;
    detail := coalesce(v_json2::text, 'nothing') || ' / ' || coalesce(v_json3::text, 'nothing') || ' / ' || left(v_got, 90)
           || ' / ' || left(v_got4, 70) || ' / ' || left(v_bad, 70);
    return next;

    -- ── 9. Held for good ────────────────────────────────────────────────────
    v_step := 'asking for an address whose ninety days are over';
    update erp_meta.deployment_previous_address pa set redirect_until = now() - interval '1 minute' where pa.address = v_x;
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json := public.erp_deployment_for_host(v_x || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_got := coalesce(erp.tenant_code_refusal(v_x, null), 'no refusal');
    begin
      perform public.erp_platform_rename_deployment(v_b, v_x, c_reason);
      v_got2 := 'it was given';
    exception when others then
      v_got2 := sqlerrm;
    end;
    begin
      perform erp_meta.finish_deployment_rename(v_b, v_x);
      v_got3 := 'it was finished';
    exception when others then
      v_got3 := sqlerrm;
    end;
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_a);
    v_cases := v_cases + 1;
    case_name := 'an address a deployment was moved from answers nothing once its ninety days are over, and is still given to no other deployment';
    passed := v_json is null
          and v_got = 'CLOVEERP_ADDRESS_TAKEN: "' || v_x || '" was a client deployment''s address and is kept for it'
          and v_got2 = v_got
          and v_got3 = 'CLOVEERP_ADDRESS_TAKEN: "' || v_x || '" is held by another deployment or organisation, so ' || v_b || ' is not moved to it'
          and v_row ->> 'previous_address' = v_a
          and exists (select 1 from erp_meta.deployment_previous_address pa where pa.address = v_x and pa.code = v_a)
          and (select d.address from erp_meta.deployment d where d.code = v_b) = v_b;
    detail := coalesce(v_json::text, 'nothing') || ' / ' || left(v_got2, 90) || ' / ' || left(v_got3, 90);
    return next;

    -- ── 10. Walked back ─────────────────────────────────────────────────────
    v_step := 'moving it back to an address it had, and to its own code';
    v_json := public.erp_platform_rename_deployment(v_a, v_x, 'The client asked to go back to the address before last.');
    update erp_meta.fleet_request x set created_at = now() - interval '3 minutes'
     where x.id = (v_json ->> 'request_id')::uuid;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-r3', array['rename']);
    perform erp_meta.finish_deployment_rename(v_a, v_x);
    perform erp_meta.settle_fleet_request((v_claim ->> 'id')::uuid, 'success: fleet_rename.yml re-pointed the project');
    v_got := (select string_agg(pa.address, ',' order by pa.address)
                from erp_meta.deployment_previous_address pa where pa.code = v_a);
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_json2 := public.erp_deployment_for_host(v_x || '.' || v_apex);
    v_json3 := public.erp_deployment_for_host(v_z || '.' || v_apex);
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_row := public.erp_platform_rename_deployment(v_a, v_a, 'The client asked to go back to the address it started with.');
    update erp_meta.fleet_request x set created_at = now() - interval '2 minutes'
     where x.id = (v_row ->> 'request_id')::uuid;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-r4', array['rename']);
    perform erp_meta.finish_deployment_rename(v_a, v_a);
    perform erp_meta.settle_fleet_request((v_claim ->> 'id')::uuid, 'success: fleet_rename.yml re-pointed the project');
    v_got2 := (select string_agg(pa.address, ',' order by pa.address)
                 from erp_meta.deployment_previous_address pa where pa.code = v_a);
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role service_role';
    v_row2 := public.erp_deployment_for_host(v_a || '.' || v_apex);
    v_row3 := public.erp_deployment_for_host(v_x || '.' || v_apex);
    v_got3 := public.erp_deployment_for_host(v_z || '.' || v_apex)::text;
    execute format('set local role %I', v_role);
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a deployment is moved back to an address it had and to its own code, each its own again, while every address it left leads to where it is';
    passed := v_json ->> 'address' = v_z and v_json ->> 'to' = v_x
          and v_got = v_a || ',' || v_z
          and v_json2 ->> 'url' = 'https://' || substr(md5(v_a), 1, 20) || '.supabase.co'
          and v_json3 = jsonb_build_object('code', v_a, 'client_name', 'Rename Alpha Ltd',
                                           'moved_to', 'https://' || v_x || '.' || v_apex)
          and v_row ->> 'address' = v_x and v_row ->> 'to' = v_a
          and (select d.address from erp_meta.deployment d where d.code = v_a) = v_a
          and v_got2 = v_x || ',' || v_z
          and v_row2 ->> 'url' = 'https://' || substr(md5(v_a), 1, 20) || '.supabase.co'
          and v_row3 = jsonb_build_object('code', v_a, 'client_name', 'Rename Alpha Ltd',
                                          'moved_to', 'https://' || v_a || '.' || v_apex)
          and v_got3::jsonb = v_row3
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_a and e.phase = 'note'
                         and e.detail like 'a move from ' || v_z || ' to ' || v_x || ', an address it had, asked for by %')
          and (select count(*) from erp_meta.deployment_event e
                where e.code = v_a and e.phase = 'rename' and e.status = 'done' and e.detail like '%, an address it had;%') = 2;
    detail := 'held after the first: ' || coalesce(v_got, 'none') || ' / after the second: ' || coalesce(v_got2, 'none')
           || ' / ' || coalesce(v_row3::text, 'nothing');
    return next;

    -- ── 11. A rename its run never settled is let go ────────────────────────
    v_step := 'asking again after a claimed rename was never settled';
    v_json := public.erp_platform_rename_deployment(v_b, v_y, 'The client asked for a new address for its new name.');
    v_q1 := (v_json ->> 'request_id')::uuid;
    update erp_meta.fleet_request x set created_at = now() - interval '6 minutes' where x.id = v_q1;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-st', array['rename']);
    begin
      perform public.erp_platform_rename_deployment(v_b, v_u, c_reason);
      v_got := 'it was asked for again';
    exception when others then
      v_got := sqlerrm;
    end;
    update erp_meta.fleet_request x set claimed_at = now() - interval '3 hours 1 minute' where x.id = v_q1;
    v_json2 := public.erp_platform_rename_deployment(v_b, v_u, 'The client asked again after the first move never finished.');
    v_q3 := (v_json2 ->> 'request_id')::uuid;
    v_got2 := coalesce(erp.tenant_code_refusal(v_y, null), 'no refusal');
    v_cases := v_cases + 1;
    case_name := 'a claimed rename holds the deployment while its run may still settle it, and is let go, failed and said, once three hours have passed, the address it was moving to still held for it';
    passed := v_claim ->> 'id' = v_q1::text
          and v_got = 'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE: ' || v_b || ' is not moved: a rename of it is already waiting or running'
          and v_json2 ->> 'to' = v_u
          and v_json2 -> 'let_go_request_ids' = jsonb_build_array(v_q1)
          and (select r.status = 'failed' and r.settled_at = now()
                      and r.outcome like 'claimed by the sweep for run run-' || v_tag || '-st at % and never settled by its run; let go by '
                                         || v_owner || ' when another rename was asked for'
                 from erp_meta.fleet_request r where r.id = v_q1)
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_b and e.phase = 'rename' and e.status = 'note'
                         and e.detail like 'a move to ' || v_y || ' claimed by the sweep at % was never settled by its run, and was let go by '
                                           || v_owner || '; it is served at ' || v_b)
          and exists (select 1 from erp_meta.fleet_request r
                       where r.id = (v_json2 ->> 'request_id')::uuid and r.status = 'requested'
                         and r.payload = jsonb_build_object('code', v_b, 'from', v_b, 'to', v_u))
          and v_got2 = 'CLOVEERP_ADDRESS_TAKEN: "' || v_y || '" was asked for as a client deployment''s address and is kept for it';
    detail := left(v_got, 90) || ' / ' || coalesce(v_json2::text, 'no answer') || ' / ' || left(v_got2, 60);
    return next;

    -- ── 12. Finishing what cannot be finished ───────────────────────────────
    v_step := 'finishing renames that cannot be finished';
    v_sql := array[
      format('select erp_meta.finish_deployment_rename(%L, %L)', 'zznobody-' || v_tag, v_y),
      format('select erp_meta.finish_deployment_rename(%L, %L)', v_b, v_z),
      format('select erp_meta.finish_deployment_rename(%L, %L)', v_r, v_y),
      format('select erp_meta.finish_deployment_rename(%L, %L)', v_b, 'not an address')];
    v_want := array['CLOVEERP_DEPLOYMENT_UNKNOWN',
                    'CLOVEERP_ADDRESS_TAKEN: "' || v_z || '" is held by another deployment or organisation, so ' || v_b || ' is not moved to it',
                    'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE: ' || v_r || ' is not moved: it is requested',
                    'CLOVEERP_ADDRESS_SHAPE'];
    v_n := 0;
    v_bad := null;
    for i in 1 .. cardinality(v_sql) loop
      begin
        execute v_sql[i];
        v_got := 'it was finished';
      exception when others then
        v_got := sqlerrm;
      end;
      if v_got like v_want[i] || '%' then
        v_n := v_n + 1;
      else
        v_bad := coalesce(v_bad || ' / ', '') || i || ': ' || left(v_got, 80);
      end if;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'a rename is not finished for nobody, onto an address held elsewhere, for a deployment not yet built, or to something that is not an address';
    passed := v_n = 4
          and (select d.address from erp_meta.deployment d where d.code = v_b) = v_b
          and (select d.address from erp_meta.deployment d where d.code = v_r) = v_r;
    detail := format('%s of 4 refused%s', v_n, coalesce('; ' || v_bad, ''));
    return next;

    -- ── 13. A rename that failed keeps its address held ─────────────────────
    v_step := 'failing a rename its run may have taken part of the way';
    -- As the sweep and the workflow would: claimed, then settled as failed
    -- when the run stopped after re-pointing the client's project.
    update erp_meta.fleet_request x set created_at = now() - interval '8 minutes' where x.id = v_q3;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-f', array['rename']);
    v_got := erp_meta.settle_fleet_request(v_q3, 'failure: the run stopped after re-pointing the client''s project; ask for the rename again');
    v_got2 := coalesce(erp.tenant_code_refusal(v_u, null), 'no refusal');
    v_sql := array[
      format('select public.erp_platform_request_deployment(%L, %L, %L, %L)', v_u, 'Rename Taker Ltd', 'admin@' || v_u || '.test', c_reason),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, v_u, c_reason),
      format('select public.erp_platform_rename_deployment(%L, %L, %L)', v_a, v_y, c_reason),
      format('select erp_meta.finish_deployment_rename(%L, %L)', v_a, v_u),
      format('select erp_meta.finish_deployment_rename(%L, %L)', v_a, v_y)];
    v_want := array[v_got2, v_got2,
                    'CLOVEERP_ADDRESS_TAKEN: "' || v_y || '" was asked for as a client deployment''s address and is kept for it',
                    'CLOVEERP_ADDRESS_TAKEN: "' || v_u || '" is held by another deployment or organisation, so ' || v_a || ' is not moved to it',
                    'CLOVEERP_ADDRESS_TAKEN: "' || v_y || '" is held by another deployment or organisation, so ' || v_a || ' is not moved to it'];
    v_n := 0;
    v_bad := null;
    for i in 1 .. cardinality(v_sql) loop
      begin
        execute v_sql[i];
        v_got3 := 'it was given';
      exception when others then
        v_got3 := sqlerrm;
      end;
      if v_got3 = v_want[i] then
        v_n := v_n + 1;
      else
        v_bad := coalesce(v_bad || ' / ', '') || i || ': ' || left(v_got3, 80);
      end if;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'the address a rename that failed was moving to stays held for that deployment, whatever its project answers to: no other deployment or organisation is given it, and no other rename finishes there';
    passed := v_claim ->> 'id' = v_q3::text
          and v_got = 'request ' || v_q3 || ' failed'
          and v_got2 = 'CLOVEERP_ADDRESS_TAKEN: "' || v_u || '" was asked for as a client deployment''s address and is kept for it'
          and v_n = 5
          and (select d.address from erp_meta.deployment d where d.code = v_a) = v_a
          and not exists (select 1 from erp_meta.deployment d where d.code = v_u);
    detail := left(v_got2, 100) || format(' / %s of 5 refused%s', v_n, coalesce('; ' || v_bad, ''));
    return next;

    -- ── 14. Asked for again, and finished ───────────────────────────────────
    v_step := 'asking for the same rename again';
    v_json := public.erp_platform_rename_deployment(v_b, v_u, 'The run stopped part-way, so the same move is asked for again.');
    v_q4 := (v_json ->> 'request_id')::uuid;
    update erp_meta.fleet_request x set created_at = now() - interval '9 minutes' where x.id = v_q4;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-g', array['rename']);
    v_got := erp_meta.finish_deployment_rename(v_b, v_u);
    v_got2 := erp_meta.settle_fleet_request(v_q4, 'success: fleet_rename.yml re-pointed the project');
    -- And the one let go before is still its own to ask for.
    v_json2 := public.erp_platform_rename_deployment(v_b, v_y, 'The client asks for the address it first wanted, after all.');
    v_cases := v_cases + 1;
    case_name := 'a deployment asks for the address a rename of it failed or was let go on again, as its own, and the rename finishes there';
    passed := v_json ->> 'address' = v_b and v_json ->> 'to' = v_u
          and v_claim ->> 'id' = v_q4::text
          and v_got = v_b || ' moved from ' || v_b || ' to ' || v_u
          and v_got2 = 'request ' || v_q4 || ' done'
          and (select d.address from erp_meta.deployment d where d.code = v_b) = v_u
          and exists (select 1 from erp_meta.deployment_previous_address pa where pa.address = v_b and pa.code = v_b)
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_b and e.phase = 'note'
                         and e.detail like 'a move from ' || v_b || ' to ' || v_u || ', an address asked for it before, asked for by %')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_rename_requested' and a.target = v_b
                         and a.detail ->> 'request_id' = v_q4::text and (a.detail ->> 'back_to_its_own')::boolean)
          and v_json2 ->> 'address' = v_u and v_json2 ->> 'to' = v_y
          and exists (select 1 from erp_meta.fleet_request r
                       where r.id = (v_json2 ->> 'request_id')::uuid and r.status = 'requested');
    detail := coalesce(v_json::text, 'no answer') || ' / ' || v_got || ' / ' || v_got2 || ' / ' || coalesce(v_json2::text, 'no answer');
    return next;

    -- ── 15. The client's own organisation follows ───────────────────────────
    v_step := 'renaming a client''s organisation';
    begin
      perform erp_meta.rename_client_organisation(v_c2);
      v_got := 'it was renamed on the control plane';
    exception when others then
      v_got := sqlerrm;
    end;
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason) values
      ('deployment.kind', '"client"'::jsonb, 'deployment_rename_suite'),
      ('deployment.app_origin', to_jsonb('https://' || v_c1 || '.cloveerp.com'), 'deployment_rename_suite');
    -- Whatever organisations this database holds are put out of the way for
    -- the length of the suite: a client starts empty.
    update erp.tenant t set status = 'deleted' where t.status not in ('deleting', 'deleted');
    v_json3 := erp_meta.rename_client_organisation(v_c1);
    v_json := public.erp_platform_onboard_company(v_c1, 'Rename Client Ltd', 'admin@' || v_c1 || '.test', 'Client Admin');
    v_tenant := (v_json ->> 'tenant_id')::uuid;
    begin
      perform erp_meta.rename_client_organisation(v_c2);
      v_got2 := 'it was renamed before the project knew its address';
    exception when others then
      v_got2 := sqlerrm;
    end;
    perform erp_meta.set_deployment_identity(substr(md5(v_c1), 1, 20), 'https://' || v_c2 || '.cloveerp.com');
    v_json := erp_meta.rename_client_organisation(' ' || upper(v_c2));
    v_json2 := erp_meta.rename_client_organisation(v_c2);
    v_cases := v_cases + 1;
    case_name := 'a client''s one organisation is renamed only on the client, once it answers at the new address; its old address is kept for it, and it is logged';
    passed := v_got like 'CLOVEERP_CLIENT_ORGANISATION_CODE: this is the production deployment, not a client''s own%'
          and v_json3 = jsonb_build_object('tenant_id', null, 'code', v_c1, 'previous', null, 'changed', false)
          and v_got2 = 'CLOVEERP_CLIENT_ORGANISATION_CODE: this deployment is served as ' || v_c1 || ', so its organisation is not renamed ' || v_c2
          and v_json = jsonb_build_object('tenant_id', v_tenant, 'code', v_c2, 'previous', v_c1, 'changed', true)
          and v_json2 = jsonb_build_object('tenant_id', v_tenant, 'code', v_c2, 'previous', null, 'changed', false)
          and (select t.code from erp.tenant t where t.id = v_tenant) = v_c2
          and exists (select 1 from erp_meta.retired_tenant_code x where x.code = v_c1 and x.owner_tenant_id = v_tenant)
          and (select count(*) from erp_meta.platform_audit a
                where a.action = 'platform.tenant_address_changed' and a.tenant_id = v_tenant and a.actor_email = 'system'
                  and a.detail ->> 'previous' = v_c1 and a.detail ->> 'code' = v_c2) = 1
          and not (select p.prosecdef from pg_catalog.pg_proc p
                    where p.oid = 'erp_meta.rename_client_organisation(text)'::regprocedure)
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.rename_client_organisation(text)', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.rename_client_organisation(text)', 'execute');
    detail := left(v_got, 80) || ' / ' || left(v_got2, 80) || ' / ' || coalesce(v_json::text, 'no answer');
    return next;

    -- ── 16. One address is taken at a time ──────────────────────────────────
    v_step := 'reading the routines that give an address';
    v_cases := v_cases + 1;
    case_name := 'a deployment''s code, an organisation''s address, a rename and its finish are each decided under the one lock on the fleet''s addresses';
    passed := strpos(pg_catalog.pg_get_functiondef('public.erp_platform_request_deployment(text,text,text,text)'::regprocedure), c_lock) > 0
          and strpos(pg_catalog.pg_get_functiondef('public.erp_platform_set_tenant_address(uuid,text,text)'::regprocedure), c_lock) > 0
          and strpos(pg_catalog.pg_get_functiondef('public.erp_platform_rename_deployment(text,text,text)'::regprocedure), c_lock) > 0
          and strpos(pg_catalog.pg_get_functiondef('erp_meta.finish_deployment_rename(text,text)'::regprocedure), c_lock) > 0;
    detail := case when passed then 'all four take it' else 'one of the four does not take it' end;
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
    raise exception 'CLOVEERP_DEPLOYMENT_RENAME_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_deployment_rename_suite()
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
    from erp_test.deployment_rename_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEPLOYMENT_RENAME_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Moving a client deployment to a new address does not do what the Fleet and the directory rely on: read the case that failed.';
  end if;
  if v_total <> 16 then
    raise exception 'CLOVEERP_DEPLOYMENT_RENAME_SUITE_SHRANK: % case(s), expected 16', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment rename: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.deployment_rename_suite() from public, anon;
revoke all on function erp_test.assert_deployment_rename_suite() from public, anon;

comment on function erp_test.assert_deployment_rename_suite() is
  'A rename is asked for by the owner for a built, live or suspended deployment, to an address nobody else has, had '
  'or was ever asked to be moved to, one at a time, a claim its run left for three hours let go; the sweep claims '
  'it; the trusted build role finishes it, every address the deployment leaves held for it for good and leading to '
  'where it is for ninety days; it may be moved back to its own code or an address it had; the address a rename that '
  'failed or was let go was moving to stays held for that deployment, which may ask for it again; a client''s one '
  'organisation follows once its project answers at the new address; and every address is given under one lock '
  '(20261012030000).';

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
