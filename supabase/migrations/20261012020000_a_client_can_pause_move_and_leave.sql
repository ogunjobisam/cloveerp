set lock_timeout = '30s';

-- =============================================================================
-- 20261012020000  A client can pause, move and leave
-- -----------------------------------------------------------------------------
-- The control plane's register of client deployments (20261011020000) could
-- build a client, release to it and retire it. Day to day a client is also
-- suspended and reinstated, moved to another address, and offboarded with a
-- copy of its data. This is the register's half of that; the workflows that
-- re-point a client's project, copy its database and keep backups off the
-- platform, and the Fleet view's buttons, come in the same pull request.
--
--   A. A deployment has an address. Its code is its key for good: the steps
--      it has recorded (erp_meta.deployment_event) are kept as they were and
--      name it by its code, with no cascade, so the code never changes. What
--      a rename moves is the address it is served at, <address>.cloveerp.com,
--      which starts as its code. The address it was moved from is kept as its
--      previous address, and leads to the new one for ninety days. Both are
--      held across the fleet as codes are: erp.tenant_code_refusal refuses an
--      address any deployment holds now, held before, or is being moved to.
--
--   B. Suspended. Supabase does not pause a project on a paid plan, so a
--      suspension is the register's: the deployment's address answers that its
--      service is suspended, and the application boots nothing for it. The
--      project keeps running and keeps receiving releases
--      (erp_meta.begin_deployment_release takes a suspended deployment, and
--      one being offboarded, as it takes a built or live one, and Release now
--      may name either). The poll reads them too, so the Fleet view calls one
--      silent when it goes unread, as it does a built or live one. Reinstating
--      makes it live again. Owner, on the control plane, with a reason.
--
--   C. Renamed. The console asks; a workflow re-points the client's own
--      project (its sign-in addresses, its functions, its identity, its one
--      organisation's address) and then tells the register, with
--      erp_meta.finish_deployment_rename. On the client,
--      erp_meta.rename_client_organisation renames its organisation once the
--      project knows its new address. A rename waits for the one before it,
--      and is recorded as a step of its own ('rename').
--
--   D. Offboarded. Begin offboarding makes a deployment retiring, sets the day
--      its project is purged (thirty days after the term of a contract in
--      force for it ends, or thirty days from now) and asks for an export of
--      its database. An export can also be asked for at any time by an
--      operator. The workflow records what it wrote with
--      erp_meta.record_deployment_export, a step of its own ('export').
--      Retiring a deployment still under a
--      contract now needs its offboarding begun first, and retiring fails what
--      the control plane still owed it and cancels its waiting renames and
--      exports. Mail owed under a retired deployment's contract is not sent.
--
--   E. The proof: erp_test.deployment_lifecycle_suite (fifteen cases) and
--      erp_test.deployment_rename_suite (ten), with their assertions.
--      erp_test.register_house_suite counts thirty-six keys in the Fleet view
--      now, the seven above among them.
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
  'Suspending a client deployment that is not built or live.',
  'A suspension stops a client''s address from serving its service while its project keeps running. A deployment '
  'still being built has no service to stop, one suspended already is suspended, and one being offboarded or '
  'retired is on its way out.',
  'Suspend a deployment that is built or live. One already suspended is reinstated from the Fleet view.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_SUSPENDED',
  'Reinstating a client deployment that is not suspended.',
  'Reinstating gives a suspended client its service back at its address. A deployment that is not suspended has '
  'nothing to be given back.',
  'Only a suspended deployment is reinstated. The Fleet view shows each deployment''s status.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE',
  'Moving a client deployment to a new address while it cannot be moved.',
  'A rename re-points the client''s own project at its new address before the register moves it. A deployment '
  'still being built has no project to re-point, one being offboarded or retired is on its way out, two renames '
  'at once would re-point it twice, and an address it already has is no move at all.',
  'Rename a deployment that is built, live or suspended, to an address it does not have yet, once any rename it is '
  'waiting for has finished. The Fleet view shows each one.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE',
  'Beginning the offboarding of a client deployment that is not built, live or suspended.',
  'Offboarding copies a client''s data and sets the day its project is deleted. A deployment still being built has '
  'no data to copy yet, and one being offboarded or retired is offboarded already.',
  'Begin offboarding for a deployment that is built, live or suspended. One that never finished its build is '
  'retired directly.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_NOT_EXPORTABLE',
  'Asking for a copy of the database of a client deployment that has none to copy.',
  'An export copies a client''s database from its own project. A deployment still being built has no data yet, and '
  'one that is retired has no project left to copy from.',
  'Ask for an export of a deployment that is built, live, suspended or being offboarded.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_HAS_A_CONTRACT',
  'Retiring a client deployment that is still under a contract in force, before its offboarding has begun.',
  'Retiring forgets how to reach a client''s project, and its project is deleted next. While a contract is in force '
  'the client is still paying for it, so its data is copied and the day it is deleted is set first.',
  'Begin its offboarding from the Fleet view first: that copies its data and sets the day its project is deleted, '
  'thirty days after the contract''s term ends. Retire it on that day.');

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
  'The console asks the workflows for four things: a client deployment built, a release, a client moved to a new '
  'address, and a copy of a client''s database. A sweep that asked for anything else would claim nothing and say '
  'nothing, and the request it meant would wait.',
  'Ask for builds, releases, renames or exports, or any of them together.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A deployment has an address
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_meta.deployment add column if not exists address text;
alter table erp_meta.deployment add column if not exists previous_address text;
alter table erp_meta.deployment add column if not exists previous_address_until timestamptz;
alter table erp_meta.deployment add column if not exists purge_due_at timestamptz;
alter table erp_meta.deployment add column if not exists suspended_reason text;
alter table erp_meta.deployment add column if not exists last_export_at timestamptz;
alter table erp_meta.deployment add column if not exists last_export_object text;

-- Every deployment so far is served at its code.
update erp_meta.deployment x set address = x.code where x.address is null;

create or replace function erp_meta.deployment_address_starts_as_its_code()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- A deployment is first served at its code. A rename moves the address and
  -- never the code (20261012020000).
  new.address := coalesce(nullif(btrim(coalesce(new.address, '')), ''), new.code);
  return new;
end;
$$;

revoke all on function erp_meta.deployment_address_starts_as_its_code() from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_address_starts_as_its_code() is
  'The trigger before a client deployment is registered: it is served at its code until a rename moves it '
  '(20261012020000).';

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
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_previous_address_check') then
    alter table erp_meta.deployment
      add constraint deployment_previous_address_check
      check (previous_address is null
             or (previous_address ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
                 and previous_address <> address
                 and previous_address_until is not null));
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment'::regclass and c.conname = 'deployment_export_is_named') then
    alter table erp_meta.deployment
      add constraint deployment_export_is_named check ((last_export_at is null) = (last_export_object is null));
  end if;
end
$$;

comment on column erp_meta.deployment.address is
  'Where the deployment is served: <address>.cloveerp.com. Starts as its code; a rename moves it, and never the '
  'code, which its recorded steps name for good. Held across the fleet as codes are (20261012020000).';
comment on column erp_meta.deployment.previous_address is
  'The address the last rename moved the deployment from. It leads to the new one until previous_address_until, '
  'and stays held so that nobody else is given it (20261012020000).';
comment on column erp_meta.deployment.previous_address_until is
  'Until when the previous address leads to the new one: ninety days from the rename (20261012020000).';
comment on column erp_meta.deployment.purge_due_at is
  'Set when offboarding begins: the day its project may be deleted and the deployment retired, thirty days after '
  'the term of a contract in force for it ends, or thirty days from the start (20261012020000).';
comment on column erp_meta.deployment.suspended_reason is
  'Why the deployment is suspended, as the owner gave it; cleared when it is reinstated or leaves suspension '
  '(20261012020000).';
comment on column erp_meta.deployment.last_export_at is
  'When a copy of the deployment''s database was last written off the platform (20261012020000).';
comment on column erp_meta.deployment.last_export_object is
  'Where that copy was written: exports/<code>/<time>.dump.age in the export bucket, encrypted (20261012020000).';

insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp_meta', 'deployment', 'address',
   'The web address a client deployment is served at, a subdomain of cloveerp.com. It names a project, not a person.'),
  ('erp_meta', 'deployment', 'previous_address',
   'The web address a client deployment was served at before a rename, a subdomain of cloveerp.com. It names a '
   'project, not a person.'),
  ('erp_meta', 'deployment', 'previous_address_until',
   'Until when a client deployment''s old web address leads to its new one: a time, not anybody''s address.')
on conflict do nothing;

-- The steps a rename and an export record.
do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.deployment_event'::regclass and c.conname = 'deployment_event_phase_check'
                    and pg_catalog.pg_get_constraintdef(c.oid) like '%rename%') then
    alter table erp_meta.deployment_event drop constraint if exists deployment_event_phase_check;
    alter table erp_meta.deployment_event
      add constraint deployment_event_phase_check
      check (phase in ('request', 'dispatch', 'create', 'configure', 'build', 'identity', 'functions',
                       'prove', 'release', 'retry', 'checklist', 'note', 'rename', 'export'));
  end if;
end
$$;

-- What the console may ask the workflows for, and the shape each asks in.
do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.fleet_request'::regclass and c.conname = 'fleet_request_kind_check'
                    and pg_catalog.pg_get_constraintdef(c.oid) like '%export%') then
    alter table erp_meta.fleet_request drop constraint if exists fleet_request_kind_check;
    alter table erp_meta.fleet_request
      add constraint fleet_request_kind_check check (kind in ('build', 'release', 'rename', 'export'));
  end if;
  if not exists (select 1 from pg_catalog.pg_constraint c
                  where c.conrelid = 'erp_meta.fleet_request'::regclass and c.conname = 'fleet_request_payload_shape') then
    alter table erp_meta.fleet_request
      add constraint fleet_request_payload_shape
      check ((kind <> 'rename' or (payload ? 'code' and payload ? 'from' and payload ? 'to'))
             and (kind <> 'export' or payload ? 'code'));
  end if;
end
$$;

comment on table erp_meta.fleet_request is
  'What the console asked the workflows for — a build of a client deployment, a release train, a client moved to '
  'a new address ({code, from, to}), a copy of a client''s database ({code}) — for the sweep (fleet_sweep.yml) to '
  'claim with the repository''s own token (20261011020000, 20261012020000). Each open request made wakes the sweep '
  'at once where the control plane can call out (erp_meta.wake_the_sweep, 20261012010000); the schedule stays '
  'behind it. The console holds no token.';

-- ─────────────────────────────────────────────────────────────────────────────
-- What the register already did, taught the address, the suspension and the
-- two new requests
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
    -- A rename moves a deployment's address and keeps the one it left, which
    -- leads to the new one for ninety days and is given to nobody else; the
    -- address a rename is moving it to is held from the moment it is asked
    -- for (20261012020000).
    when exists (select 1 from erp_meta.deployment d where d.previous_address = p_code) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" was a client deployment''s address and is kept for it'
    when exists (select 1 from erp_meta.fleet_request r
                  where r.kind = 'rename' and r.status in ('requested', 'claimed')
                    and r.payload ->> 'to' = p_code) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" is the address a client deployment is being moved to'
$n$),
        -- A suspended client is released into; one being offboarded is still up.
        ('erp_meta.begin_deployment_release(text,text)', '79aa71dcaf76797d3afe5c1b1ea214ce', 1,
$o$  if d.status not in ('built', 'live') then
$o$,
$n$  -- A suspended client keeps receiving releases, and one being offboarded is
  -- still up until it is retired (20261012020000).
  if d.status not in ('built', 'live', 'suspended', 'retiring') then
$n$),
        ('public.erp_platform_request_release(text[],text)', 'ba7d11a7fc610b4fe7e548337a673dcf', 1,
$o$       and not exists (select 1 from erp_meta.deployment d where d.code = t and d.status in ('built', 'live')) then
$o$,
$n$       and not exists (select 1 from erp_meta.deployment d where d.code = t
                         -- A suspended client is released into, and one being
                         -- offboarded is still up (20261012020000).
                         and d.status in ('built', 'live', 'suspended', 'retiring')) then
$n$),
        -- The sweep may ask for renames and exports.
        ('erp_meta.claim_fleet_request(text,text[])', 'ceff161cb48fe6cad01334f165af7a30', 1,
$o$   where k is null or k not in ('build', 'release');
$o$,
$n$   where k is null or k not in ('build', 'release', 'rename', 'export');
$n$),
        ('erp_meta.claim_fleet_request(text,text[])', 'ceff161cb48fe6cad01334f165af7a30', 2,
$o$    raise exception 'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN: the console asks for builds and releases, not %', v_bad
      using errcode = '22023',
            hint = 'Ask for builds, releases, or both.';
$o$,
$n$    -- Renames and exports too, since 20261012020000.
    raise exception 'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN: the console asks for builds, releases, renames and exports, not %', v_bad
      using errcode = '22023',
            hint = 'Ask for builds, releases, renames or exports, or any of them together.';
$n$),
        -- The steps a rename and an export record.
        ('erp_meta.record_deployment_event(text,text,text,text,text)', '85bebe8fd3b04a90431a3bd1fd1edca5', 1,
$o$                     'prove', 'release', 'retry', 'checklist', 'note')
$o$,
$n$                     'prove', 'release', 'retry', 'checklist', 'note',
                     -- A client moved to a new address, and a copy of its
                     -- database written (20261012020000).
                     'rename', 'export')
$n$),
        -- The Fleet view: where each deployment is served and was, its purge,
        -- its suspension and its last export.
        ('public.erp_platform_deployments()', 'e0253739c4208c62993d2c5b918e44e6', 1,
$o$             'origin', 'https://' || d.code || '.' || regexp_replace(erp.app_origin(), '^https://', ''),
$o$,
$n$             -- Where it is served, which a rename moves; the code it was
             -- registered under never changes. Where it was, and until when
             -- that leads here; the day its project may be purged; why it is
             -- suspended; and its last export (20261012020000).
             'origin', 'https://' || d.address || '.' || regexp_replace(erp.app_origin(), '^https://', ''),
             'address', d.address,
             'previous_address', d.previous_address,
             'previous_address_until', d.previous_address_until,
             'purge_due_at', d.purge_due_at,
             'suspended_reason', d.suspended_reason,
             'last_export_at', d.last_export_at,
             'last_export_object', d.last_export_object,
$n$),
        ('public.erp_platform_deployments()', 'e0253739c4208c62993d2c5b918e44e6', 2,
$o$             'silent', d.status in ('built', 'live')
$o$,
$n$             'silent', d.status in ('built', 'live', 'suspended', 'retiring')
$n$),
        -- Retiring: not under a contract unless offboarding has begun; what it
        -- was owed is failed, and its waiting renames and exports cancelled.
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 1,
$o$  v_forgotten integer := 0;
$o$,
$n$  v_forgotten integer := 0;
  v_pushes    integer := 0;
  v_contract  erp_meta.contract;
$n$),
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 2,
$o$  update erp_meta.deployment x
     set status = c_retired, owner_email = null, updated_at = now()
   where x.code = d.code;
$o$,
$n$  -- A client still under a contract is offboarded first: Begin offboarding
  -- copies its data and sets the day its project is purged. Retiring one
  -- that is not yet retiring while its contract is in force would delete
  -- what the client is still paying for (20261012020000).
  if d.status <> 'retiring' then
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
              hint = 'Begin its offboarding from the Fleet view first: that copies its data and sets the day its '
                     'project is deleted, thirty days after the contract''s term ends. Retire it on that day.';
    end if;
  end if;

  update erp_meta.deployment x
     set status = c_retired, owner_email = null, suspended_reason = null, updated_at = now()
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
$n$  -- A build still waiting for the sweep would rebuild a deployment that is
  -- gone, and a rename or an export still waiting would reach a project
  -- about to be deleted, through credentials deleted below (20261012020000).
  -- A release waiting for it is left alone: it may name the control plane
  -- and other clients too, and the train itself releases nothing to a
  -- retired client (deploy.yml reads only the deployments that are served,
  -- and each client's release asks the register first) (20261011060000).
  update erp_meta.fleet_request r
     set status = 'cancelled', outcome = 'the deployment was retired', settled_at = now()
   where r.status = 'requested'
     and r.kind in ('build', 'rename', 'export')
     and r.payload ->> 'code' = d.code;

  -- What the control plane still owed it is owed no more (20261012020000).
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
                       'pushes_failed', v_pushes));
$n$),
        ('public.erp_platform_retire_deployment(text,text)', '121271b6355454c63e74da98744f248d', 5,
$o$                            'credentials_deleted', v_forgotten);
$o$,
$n$                            'credentials_deleted', v_forgotten, 'pushes_failed', v_pushes);
$n$),
        -- Mail owed under a retired deployment's contract is not sent.
        ('erp.claim_commercial_email_batch(integer,text)', 'e0bd7b671d06bb932a328a8584363c45', 1,
$o$  r          record;
$o$,
$n$  r          record;
  -- The register's word for a deployment that is gone, named rather than
  -- written inline (erp.record_status_literal_report) (20261012020000).
  c_retired  constant text := 'retired';
$n$),
        ('erp.claim_commercial_email_batch(integer,text)', 'e0bd7b671d06bb932a328a8584363c45', 2,
$o$                and not exists (select 1 from erp.tenant t where t.id = ce.tenant_id))) as gone,
$o$,
$n$                and not exists (select 1 from erp.tenant t where t.id = ce.tenant_id))) as gone,
           -- A client deployment that is retired is owed no more of its
           -- contract's mail: it is gone, as a gone organisation is
           -- (20261012020000).
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
        -- The register's own suite counts the Fleet view's keys; seven more now.
        ('erp_test.register_house_suite()', '94c05d1a27391c39ef955c4f5221166f', 1,
$o$                 'health', 'health_at', 'silent']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 29
$o$,
$n$                 'health', 'health_at', 'silent',
                 -- Where it is served and was, its purge, its suspension and
                 -- its last export (20261012020000).
                 'address', 'previous_address', 'previous_address_until', 'purge_due_at',
                 'suspended_reason', 'last_export_at', 'last_export_object']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 36
$n$)
      ) as x(sig, anchor, ord, old, new)
     group by x.sig, x.anchor
     order by x.sig
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261012020000') > 0 then
      raise notice '% already carries 20261012020000', r.sig;
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
  'address now or before, or a client deployment''s code, address, previous address, or the address a rename is '
  'moving one to (20261011020000, 20261012020000).';

comment on function erp_meta.begin_deployment_release(text, text) is
  'Asked by each client''s release before it applies anything: the deployment''s status, and a release-started step '
  'recorded when it is a release target — built, live, suspended or being offboarded. Trusted build role only '
  '(20261011050000, 20261012020000).';

comment on function public.erp_platform_deployments() is
  'Every client deployment in the register, with its build''s last step, its newest build request and when it '
  'was made, claimed and settled, whether Start again would start it now, its last release, its health as the poll '
  'last read it, when, and whether one being served has gone silent (unread for twenty-six hours), where it is '
  'served and was, the day it may be purged, why it is suspended, and its last export, for the Fleet view. Platform '
  'support and above, on the control plane only (20261011020000, 20261011110000, 20261012010000, 20261012020000).';

comment on function public.erp_platform_retire_deployment(text, text) is
  'Retires a client deployment: nothing runs for it again, its stored credentials are deleted, what was owed it is '
  'failed and its waiting builds, renames and exports are cancelled. Refuses while a build or release runs for it, '
  'and while a contract is in force for it unless its offboarding has begun. Platform owner, on the control plane, '
  'with a reason (20261011040000, 20261012020000).';

comment on function erp_meta.claim_fleet_request(text, text[]) is
  'The oldest open request from the console of one of the kinds asked for (build, release, rename, export), claimed '
  'by the sweep that will start its workflow run; null when there is none, or when no kind is asked for. The same '
  'shape as the one-argument claim, which takes any kind and stays as it was. Trusted build role only '
  '(20261012010000, 20261012020000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The directory finds a deployment by its address
-- ─────────────────────────────────────────────────────────────────────────────

do $$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'public.erp_deployment_for_host(text)'::regprocedure);
begin
  if strpos(v_src, '20261012020000') = 0 and md5(v_src) <> '004080e66e04688e4f0f0f38ca4acc3f' then
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
  -- address, which a rename moves; its code never changes (20261012020000).
  -- Built, live or being offboarded, it answers with the project to boot.
  -- Suspended, it answers that it is suspended and with no project, so the
  -- application boots nothing for it. At the address it was moved from it
  -- answers where it went, for ninety days. Not yet built, failed, retired,
  -- or nobody: nothing.
  with asked as (
    select lower(btrim(coalesce(p_host, ''))) as host,
           regexp_replace(erp.app_origin(), '^https://', '') as apex),
  answers as (
    select 1 as rank,
           case when d.status = 'suspended'
                then jsonb_build_object('code', d.code, 'client_name', d.client_name, 'suspended', true)
                else jsonb_build_object('code', d.code, 'client_name', d.client_name,
                                        'url', d.api_url, 'key', d.publishable_key)
           end as answer
      from asked a
      join erp_meta.deployment d
        on a.host = d.address || '.' || a.apex
     where d.status = 'suspended'
        or (d.status in ('built', 'live', 'retiring')
            and d.api_url is not null
            and d.publishable_key is not null)
    union all
    select 2,
           jsonb_build_object('code', d.code, 'client_name', d.client_name,
                              'moved_to', 'https://' || d.address || '.' || a.apex)
      from asked a
      join erp_meta.deployment d
        on a.host = d.previous_address || '.' || a.apex
     where d.previous_address_until > now()
       and d.status in ('built', 'live', 'suspended', 'retiring'))
  select x.answer from answers x order by x.rank limit 1
$$;

revoke all on function public.erp_deployment_for_host(text) from public, anon, authenticated;
grant execute on function public.erp_deployment_for_host(text) to service_role;

comment on function public.erp_deployment_for_host(text) is
  'The directory: for <address>.<apex>, a built, live or offboarding client deployment''s code, name, project URL '
  'and publishable key; a suspended one''s code and name with suspended true and nothing to boot; at an address '
  'a deployment was moved from in the last ninety days, its code, name and moved_to, the origin it moved to; '
  'otherwise null. service_role only, for the application''s directory route (20261011020000, 20261012020000).';

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
  v erp_meta.platform_staff;
  d erp_meta.deployment;
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
  if d.status not in ('built', 'live') then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE: % is not suspended: it is %', d.code, d.status
      using errcode = '55000',
            hint = 'Suspend a deployment that is built or live. One already suspended is reinstated from the Fleet view.';
  end if;

  -- The register's suspension: the address says the service is suspended and
  -- boots nothing. Supabase does not pause a project on a paid plan, so the
  -- project keeps running, and keeps receiving releases (20261012020000).
  update erp_meta.deployment x
     set status = 'suspended', suspended_reason = btrim(p_reason), updated_at = now()
   where x.code = d.code;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('suspended by %s (was %s): %s. Its address now says its service is suspended; its project keeps running '
           'and keeps receiving releases.', v.email, d.status, rtrim(btrim(p_reason), '.')));
  perform erp_meta.platform_log(v, 'platform.deployment_suspended', null, d.code, p_reason,
    jsonb_build_object('was', d.status));

  return jsonb_build_object('code', d.code, 'status', 'suspended', 'was', d.status,
                            'suspended_reason', btrim(p_reason));
end;
$$;

revoke all on function public.erp_platform_suspend_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_suspend_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_suspend_deployment(text, text) is
  'Suspends a built or live client deployment: its address answers that its service is suspended and the '
  'application boots nothing for it, while its project keeps running and keeps receiving releases. Platform owner, '
  'on the control plane, with a reason kept as suspended_reason (20261012020000).';

create or replace function public.erp_platform_reinstate_deployment(p_code text, p_reason text)
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
  if d.status <> 'suspended' then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDED: % is not reinstated: it is %, not suspended', d.code, d.status
      using errcode = '55000',
            hint = 'Only a suspended deployment is reinstated. The Fleet view shows each deployment''s status.';
  end if;

  update erp_meta.deployment x
     set status = 'live', suspended_reason = null, updated_at = now()
   where x.code = d.code;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('reinstated by %s: %s. Its address serves it again; it had been suspended because: %s.',
           v.email, rtrim(btrim(p_reason), '.'), rtrim(coalesce(d.suspended_reason, 'no reason was kept'), '.')));
  perform erp_meta.platform_log(v, 'platform.deployment_reinstated', null, d.code, p_reason,
    jsonb_build_object('suspended_reason', d.suspended_reason));

  return jsonb_build_object('code', d.code, 'status', 'live', 'was', d.status);
end;
$$;

revoke all on function public.erp_platform_reinstate_deployment(text, text) from public, anon;
grant execute on function public.erp_platform_reinstate_deployment(text, text) to authenticated, service_role;

comment on function public.erp_platform_reinstate_deployment(text, text) is
  'Reinstates a suspended client deployment: live again, served at its address, its reason for suspension cleared. '
  'Platform owner, on the control plane, with a reason (20261012020000).';

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
  v      erp_meta.platform_staff;
  d      erp_meta.deployment;
  v_new  text := lower(btrim(coalesce(p_new_address, '')));
  v_busy text;
  v_why  text;
  v_req  uuid;
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
  -- row is held while it is decided (20261012020000).
  perform pg_advisory_xact_lock(hashtext('erp_meta.deployment.address'));
  select * into d from erp_meta.deployment x where x.code = d.code for update;

  v_busy := case
    when d.status not in ('built', 'live', 'suspended')
      then format('it is %s, and only a built, live or suspended deployment is moved', d.status)
    when exists (select 1 from erp_meta.fleet_request r
                  where r.kind = 'rename' and r.status in ('requested', 'claimed')
                    and r.payload ->> 'code' = d.code)
      then 'a rename of it is already waiting or running'
    when v_new = d.address
      then format('it is served at %s already', v_new)
  end;
  if v_busy is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_RENAMEABLE: % is not moved: %', d.code, v_busy
      using errcode = '55000',
            hint = 'Rename a deployment that is built, live or suspended, to an address it does not have yet, once '
                   'any rename it is waiting for has finished. The Fleet view shows each one.';
  end if;

  -- The rule an organisation's address and a new deployment's code meet:
  -- shape, reserved words, any organisation's address, and any deployment's
  -- code, address, previous address, or the address one is being moved to.
  v_why := erp.tenant_code_refusal(v_new, null);
  if v_why is not null then
    raise exception '%', v_why
      using errcode = '23514',
            hint = 'Choose another address: it becomes the client''s address, <address>.cloveerp.com, and an address '
                   'that is or was anybody''s is not given again.';
  end if;

  insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
  values ('rename', jsonb_build_object('code', d.code, 'from', d.address, 'to', v_new), btrim(p_reason), v.id)
  returning id into v_req;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('a move from %s to %s asked for by %s: %s. The address moves once the client''s project is re-pointed; '
           'the old one then leads to the new one for ninety days.',
           d.address, v_new, v.email, rtrim(btrim(p_reason), '.')));
  perform erp_meta.platform_log(v, 'platform.deployment_rename_requested', null, d.code, p_reason,
    jsonb_build_object('from', d.address, 'to', v_new, 'request_id', v_req));

  return jsonb_build_object('code', d.code, 'status', d.status, 'address', d.address, 'to', v_new,
                            'request_id', v_req);
end;
$$;

revoke all on function public.erp_platform_rename_deployment(text, text, text) from public, anon;
grant execute on function public.erp_platform_rename_deployment(text, text, text) to authenticated, service_role;

comment on function public.erp_platform_rename_deployment(text, text, text) is
  'Asks for a built, live or suspended client deployment to be moved to a new address: queues a rename request '
  '{code, from, to} for the sweep, whose workflow re-points the client''s project and then moves the register''s '
  'address (erp_meta.finish_deployment_rename). The new address meets erp.tenant_code_refusal, which holds every '
  'address a deployment has, had, or is being moved to. Refuses while a rename of it is waiting or running. '
  'Platform owner, on the control plane, with a reason (20261012020000).';

create or replace function erp_meta.finish_deployment_rename(p_code text, p_to text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d      erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_to   text := lower(btrim(coalesce(p_to, '')));
  v_apex text := regexp_replace(erp.app_origin(), '^https://', '');
  v_until timestamptz := now() + interval '90 days';
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
            hint = 'Rename a deployment that is built, live or suspended, to an address it does not have yet, once '
                   'any rename it is waiting for has finished. The Fleet view shows each one.';
  end if;
  if v_to !~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' then
    raise exception 'CLOVEERP_ADDRESS_SHAPE: "%" is not an address: use three to 63 lower-case letters, digits and hyphens, starting and ending with a letter or digit', p_to
      using errcode = '22023',
            hint = 'Finish the rename with the address it was asked for, as the request names it.';
  end if;
  if exists (select 1 from erp_meta.deployment x
              where x.code <> d.code and v_to in (x.code, x.address, x.previous_address))
     or exists (select 1 from erp.tenant t where t.code = v_to)
     or exists (select 1 from erp_meta.retired_tenant_code x where x.code = v_to) then
    raise exception 'CLOVEERP_ADDRESS_TAKEN: "%" is held by another deployment or organisation, so % is not moved to it', v_to, d.code
      using errcode = '23514',
            hint = 'Ask for another address from the Fleet view; the client''s project must be re-pointed to it again.';
  end if;

  update erp_meta.deployment x
     set previous_address = d.address,
         previous_address_until = v_until,
         address = v_to,
         updated_at = now()
   where x.code = d.code;

  perform erp_meta.record_deployment_event(d.code, 'rename', 'done',
    format('moved from %s.%s to %s.%s; the old address leads to the new one until %s',
           d.address, v_apex, v_to, v_apex, to_char(v_until at time zone 'UTC', 'FMDD Mon YYYY')));

  return format('%s moved from %s to %s', d.code, d.address, v_to);
end;
$$;

revoke all on function erp_meta.finish_deployment_rename(text, text) from public, anon, authenticated, service_role;

comment on function erp_meta.finish_deployment_rename(text, text) is
  'Called by the rename workflow once the client''s project answers at its new address: the register''s address '
  'moves to it, and the one it left becomes its previous address, leading to the new one for ninety days. Says so '
  'and moves nothing when it is there already; refuses an address held by another deployment or organisation. '
  'Trusted build role only (20261012020000).';

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
  -- address it is served at (20261012020000).
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
  '(20261012020000).';

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
  v_end    date;
  v_due    timestamptz;
  v_req    uuid;
  v_queued boolean := false;
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
  if d.status not in ('built', 'live', 'suspended') then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE: % is not offboarded: it is %', d.code, d.status
      using errcode = '55000',
            hint = 'Begin offboarding for a deployment that is built, live or suspended. One that never finished its '
                   'build is retired directly.';
  end if;

  -- Thirty days after the term of a contract in force for it ends, or thirty
  -- days from now when there is none or it has ended (20261012020000).
  select max(c.current_term_end) into v_end
    from erp_meta.contract c
   where c.deployment_code = d.code
     and c.status in ('active', 'terminating');
  v_due := greatest(now(), v_end::timestamptz) + interval '30 days';

  update erp_meta.deployment x
     set status = 'retiring', purge_due_at = v_due, suspended_reason = null, updated_at = now()
   where x.code = d.code;

  -- A copy of its database, unless one is already waiting or being written.
  select r.id into v_req
    from erp_meta.fleet_request r
   where r.kind = 'export' and r.status in ('requested', 'claimed') and r.payload ->> 'code' = d.code
   order by r.created_at desc
   limit 1;
  if v_req is null then
    insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
    values ('export', jsonb_build_object('code', d.code), btrim(p_reason), v.id)
    returning id into v_req;
    v_queued := true;
  end if;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('offboarding begun by %s (was %s): %s. Its project may be purged from %s, %s; a copy of its database is %s.',
           v.email, d.status, rtrim(btrim(p_reason), '.'),
           to_char(v_due at time zone 'UTC', 'FMDD Mon YYYY'),
           case when v_end is not null and v_end::timestamptz > now()
                then format('thirty days after its contract''s term ends on %s', to_char(v_end, 'FMDD Mon YYYY'))
                else 'thirty days from now' end,
           case when v_queued then 'asked for' else 'already waiting or being written' end));
  perform erp_meta.platform_log(v, 'platform.deployment_offboarding_begun', null, d.code, p_reason,
    jsonb_build_object('was', d.status, 'purge_due_at', v_due, 'contract_term_end', v_end,
                       'export_request_id', v_req, 'export_queued', v_queued));

  return jsonb_build_object('code', d.code, 'status', 'retiring', 'was', d.status, 'purge_due_at', v_due,
                            'contract_term_end', v_end, 'export_request_id', v_req, 'export_queued', v_queued);
end;
$$;

revoke all on function public.erp_platform_begin_offboarding(text, text) from public, anon;
grant execute on function public.erp_platform_begin_offboarding(text, text) to authenticated, service_role;

comment on function public.erp_platform_begin_offboarding(text, text) is
  'Begins the offboarding of a built, live or suspended client deployment: it is retiring and still served, its '
  'purge is due thirty days after the term of a contract in force for it ends (or thirty days from now), and an '
  'export of its database is asked for unless one is waiting. Platform owner, on the control plane, with a reason '
  '(20261012020000).';

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
  v_req    uuid;
  v_queued boolean := false;
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
  if d.status not in ('built', 'live', 'suspended', 'retiring') then
    raise exception 'CLOVEERP_DEPLOYMENT_NOT_EXPORTABLE: % is not copied: it is %', d.code, d.status
      using errcode = '55000',
            hint = 'Ask for an export of a deployment that is built, live, suspended or being offboarded.';
  end if;

  select * into r
    from erp_meta.fleet_request x
   where x.kind = 'export' and x.status in ('requested', 'claimed') and x.payload ->> 'code' = d.code
   order by x.created_at desc
   limit 1;
  if r.id is null then
    insert into erp_meta.fleet_request (kind, payload, reason, requested_by)
    values ('export', jsonb_build_object('code', d.code), btrim(p_reason), v.id)
    returning id into v_req;
    v_queued := true;
  else
    v_req := r.id;
  end if;

  perform erp_meta.record_deployment_event(d.code, 'note', 'done',
    format('a copy of its database asked for by %s: %s. %s', v.email, rtrim(btrim(p_reason), '.'),
           case when v_queued then 'The export workflow writes it, encrypted, off the platform.'
                else format('One asked for at %s is %s, so no other is.',
                            to_char(r.created_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI "UTC"'),
                            case r.status when 'claimed' then 'being written' else 'still waiting' end) end));
  perform erp_meta.platform_log(v, 'platform.deployment_export_requested', null, d.code, p_reason,
    jsonb_build_object('request_id', v_req, 'queued', v_queued));

  return jsonb_build_object('code', d.code, 'status', d.status, 'request_id', v_req, 'queued', v_queued);
end;
$$;

revoke all on function public.erp_platform_request_export(text, text) from public, anon;
grant execute on function public.erp_platform_request_export(text, text) to authenticated, service_role;

comment on function public.erp_platform_request_export(text, text) is
  'Asks for a copy of a built, live, suspended or offboarding client deployment''s database, encrypted and written '
  'off the platform by the export workflow; returns the waiting request instead of queueing a second. Platform '
  'operator and above, on the control plane, with a reason (20261012020000).';

create or replace function erp_meta.record_deployment_export(p_code text, p_object text, p_bytes bigint, p_sha256 text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d        erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_object text := btrim(coalesce(p_object, ''));
  v_sha    text := lower(btrim(coalesce(p_sha256, '')));
  v_fault  text;
begin
  -- Where the copy went, for this client; how big it is; and its
  -- fingerprint (20261012020000).
  v_fault := case
    when length(v_object) > 300 or v_object !~ ('^exports/' || d.code || '/[A-Za-z0-9._:-]+\.dump\.age$')
      then format('"%s" is not a place this client''s copies are written', v_object)
    when p_bytes is null or p_bytes <= 0
      then 'its size is not a number of bytes above none'
    when v_sha !~ '^[0-9a-f]{64}$'
      then 'its fingerprint is not a sha256 in hexadecimal'
  end;
  if v_fault is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_EXPORT_INVALID: the copy of % is not recorded: %', d.code, v_fault
      using errcode = '22023',
            hint = 'Record the copy with the place it was written for that client, its size, and its fingerprint, '
                   'as the export workflow reads them back.';
  end if;

  update erp_meta.deployment x
     set last_export_at = now(), last_export_object = v_object
   where x.code = d.code;

  perform erp_meta.record_deployment_event(d.code, 'export', 'done',
    format('a copy of its database was written to %s: %s bytes, sha256 %s', v_object, p_bytes, v_sha));

  return format('%s: copy recorded at %s', d.code, v_object);
end;
$$;

revoke all on function erp_meta.record_deployment_export(text, text, bigint, text) from public, anon, authenticated, service_role;

comment on function erp_meta.record_deployment_export(text, text, bigint, text) is
  'Called by the export workflow once a copy of a client''s database is written off the platform: keeps when and '
  'where (exports/<code>/<time>.dump.age) on its row and records the step with its size and sha256. Refuses '
  'anything else with CLOVEERP_DEPLOYMENT_EXPORT_INVALID. Trusted build role only (20261012020000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The doors' standing
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_suspend_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Marks one built or live client '
   'deployment suspended with the reason given, and writes the step and the platform audit row.'),
  ('public', 'erp_platform_reinstate_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Makes one suspended client deployment '
   'live again, and writes the step and the platform audit row.'),
  ('public', 'erp_platform_rename_deployment',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Queues one rename request for the '
   'sweep after erp.tenant_code_refusal, and writes the step and the platform audit row; the address itself moves '
   'only when the trusted workflow finishes it.'),
  ('public', 'erp_platform_begin_offboarding',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') and erp.require_control_plane() on its first '
   'lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Marks one client deployment retiring '
   'with its purge date, queues an export request, and writes the step and the platform audit row.'),
  ('public', 'erp_platform_request_export',
   'Platform operator door, gated by erp_meta.require_platform(''operator'') and erp.require_control_plane() on its '
   'first lines. Runs as its owner because erp_meta is sealed to a signed-in caller. Queues one export request for '
   'the sweep unless one is waiting, and writes the step and the platform audit row.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_suspend_deployment', 'erp_meta.require_platform',
   'Suspends a client deployment''s service at its address; platform owner, with a reason kept in the activity log.'),
  ('erp_platform_reinstate_deployment', 'erp_meta.require_platform',
   'Gives a suspended client deployment its service back; platform owner, with a reason kept in the activity log.'),
  ('erp_platform_rename_deployment', 'erp_meta.require_platform',
   'Asks for a client deployment to be moved to a new address; platform owner, with a reason kept in the activity log.'),
  ('erp_platform_begin_offboarding', 'erp_meta.require_platform',
   'Begins a client deployment''s offboarding, its purge date and its export; platform owner, with a reason kept in '
   'the activity log.'),
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
   'Starts the end of a client''s service and sets the day its data is deleted; the owner''s alone.')
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
  c_expected constant integer := 15;
  -- The register's own word, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired  constant text := 'retired';
  c_reason   constant text := 'The lifecycle suite asks for this, and undoes it.';
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_uid      uuid := gen_random_uuid();
  v_role     text := current_user;
  v_owner    text;
  v_apex     text;
  v_live     text;
  v_built    text;
  v_req      text;
  v_con      text;
  v_bare     text;
  v_exp      text;
  v_pcode    text;
  v_platform uuid;
  v_ccon     uuid;
  v_cexp     uuid;
  v_end      date := current_date + 200;
  rp         record;
  v_json     jsonb;
  v_json2    jsonb;
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
    v_owner := 'owner@zzlcy-' || v_tag || '.test';
    v_live  := 'zzlcl-' || v_tag;
    v_built := 'zzlcb-' || v_tag;
    v_req   := 'zzlcq-' || v_tag;
    v_con   := 'zzlcc-' || v_tag;
    v_bare  := 'zzlcn-' || v_tag;
    v_exp   := 'zzlce-' || v_tag;
    v_pcode := 'zzlcp-' || v_tag;
    insert into auth.users (id, email, email_confirmed_at) values (v_uid, v_owner, now());
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Deployment Lifecycle Suite Owner', 'owner');
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin');
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

    v_step := 'registering six client deployments and two contracts';
    insert into erp_meta.deployment (code, client_name, status, owner_email, project_ref, api_url, publishable_key, built_at)
    select y.code, y.name, y.status, 'admin@' || y.code || '.test', substr(md5(y.code), 1, 20),
           'https://' || substr(md5(y.code), 1, 20) || '.supabase.co', 'sb_publishable_' || replace(y.code, '-', ''),
           now() - interval '3 days'
      from (values (v_live, 'Lifecycle Live Ltd', 'live'), (v_built, 'Lifecycle Built Ltd', 'built'),
                   (v_con, 'Lifecycle Contract Ltd', 'live'), (v_bare, 'Lifecycle Bare Ltd', 'live'),
                   (v_exp, 'Lifecycle Export Ltd', 'live')) as y(code, name, status);
    insert into erp_meta.deployment (code, client_name, status, owner_email)
    values (v_req, 'Lifecycle Requested Ltd', 'requested', 'admin@' || v_req || '.test');
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

    -- ── 1. Who may ask, where, and how ──────────────────────────────────────
    v_step := 'asking off the control plane, below rank, without a reason, and for nobody';
    v_who := array['client', 'client', 'operator', 'operator', 'operator', 'support', 'owner', 'owner', 'owner',
                   'owner', 'owner', 'owner'];
    v_sql := array[
      format('select public.erp_platform_suspend_deployment(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_request_export(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_suspend_deployment(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_reinstate_deployment(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_begin_offboarding(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_request_export(%L, %L)', v_live, c_reason),
      format('select public.erp_platform_suspend_deployment(%L, %L)', v_live, 'unpaid'),
      format('select public.erp_platform_reinstate_deployment(%L, %L)', v_live, 'paid'),
      format('select public.erp_platform_begin_offboarding(%L, %L)', v_live, 'leaving'),
      format('select public.erp_platform_request_export(%L, %L)', v_live, '   '),
      format('select public.erp_platform_suspend_deployment(%L, %L)', 'zznobody-' || v_tag, c_reason),
      format('select public.erp_platform_request_export(%L, %L)', 'zznobody-' || v_tag, c_reason)];
    v_want := array['CLOVEERP_NOT_THE_CONTROL_PLANE', 'CLOVEERP_NOT_THE_CONTROL_PLANE',
                    'CLOVEERP_PLATFORM_ROLE_TOO_LOW', 'CLOVEERP_PLATFORM_ROLE_TOO_LOW', 'CLOVEERP_PLATFORM_ROLE_TOO_LOW',
                    'CLOVEERP_PLATFORM_ROLE_TOO_LOW', 'CLOVEERP_REASON_REQUIRED', 'CLOVEERP_REASON_REQUIRED',
                    'CLOVEERP_REASON_REQUIRED', 'CLOVEERP_REASON_REQUIRED', 'CLOVEERP_DEPLOYMENT_UNKNOWN',
                    'CLOVEERP_DEPLOYMENT_UNKNOWN'];
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
    passed := v_n = 12
          and (select d.status from erp_meta.deployment d where d.code = v_live) = 'live'
          and not exists (select 1 from erp_meta.fleet_request r where r.payload ->> 'code' = v_live);
    detail := format('%s of 12 refused as they should be%s', v_n, coalesce('; ' || v_bad, ''));
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
    begin
      perform public.erp_platform_suspend_deployment(v_live, c_reason);
      v_got2 := 'it was suspended twice';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a built or live deployment is suspended with its reason, said in its steps and the platform log; nothing else is, and nothing twice';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE: ' || v_req || ' is not suspended: it is requested'
          and v_json ->> 'status' = 'suspended' and v_json ->> 'was' = 'live'
          and (select d.status || '|' || d.suspended_reason from erp_meta.deployment d where d.code = v_live)
              = 'suspended|The client has not paid for two months; suspended until it does.'
          and v_got2 = 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDABLE: ' || v_live || ' is not suspended: it is suspended'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_live and e.phase = 'note' and e.status = 'done'
                         and e.detail like 'suspended by ' || v_owner || ' (was live): The client has not paid for two months; suspended until it does. Its address now says%')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_suspended' and a.target = v_live
                         and a.detail ->> 'was' = 'live');
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

    -- ── 5. Reinstated ───────────────────────────────────────────────────────
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
    case_name := 'only a suspended deployment is reinstated: live again, served at its address, and why it was suspended goes from its row';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_SUSPENDED: ' || v_built || ' is not reinstated: it is built, not suspended'
          and v_json ->> 'status' = 'live' and v_json ->> 'was' = 'suspended'
          and (select d.status = 'live' and d.suspended_reason is null from erp_meta.deployment d where d.code = v_live)
          and v_json2 ->> 'url' = 'https://' || substr(md5(v_live), 1, 20) || '.supabase.co'
          and not v_json2 ? 'suspended'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_live and e.phase = 'note'
                         and e.detail = 'reinstated by ' || v_owner || ': The client has paid what it owed, so it is '
                                        'reinstated. Its address serves it again; it had been suspended because: The '
                                        'client has not paid for two months; suspended until it does.')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_reinstated' and a.target = v_live);
    detail := left(v_got, 80) || ' / ' || coalesce(v_json::text, 'no answer') || ' / ' || coalesce(v_json2::text, 'nothing');
    return next;

    -- ── 6. Offboarded under a contract ──────────────────────────────────────
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
    case_name := 'offboarding a client under contract makes it retiring and still served, its purge due thirty days after its term ends, and asks for an export';
    passed := v_json ->> 'status' = 'retiring' and v_json ->> 'was' = 'live'
          and (v_json ->> 'contract_term_end')::date = v_end
          and (v_json ->> 'export_queued')::boolean
          and (select d.status = 'retiring' and d.purge_due_at = v_end::timestamptz + interval '30 days'
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

    -- ── 7. Offboarded once, and only once built ─────────────────────────────
    v_step := 'offboarding what cannot be offboarded';
    begin
      perform public.erp_platform_begin_offboarding(v_req, c_reason);
      v_got := 'it was offboarded';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_begin_offboarding(v_con, c_reason);
      v_got2 := 'it was offboarded twice';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'offboarding begins only for a deployment that is built, live or suspended, and once';
    passed := v_got = 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE: ' || v_req || ' is not offboarded: it is requested'
          and v_got2 = 'CLOVEERP_DEPLOYMENT_NOT_OFFBOARDABLE: ' || v_con || ' is not offboarded: it is retiring'
          and (select d.status from erp_meta.deployment d where d.code = v_req) = 'requested'
          and not exists (select 1 from erp_meta.fleet_request r where r.payload ->> 'code' = v_req);
    detail := left(v_got, 90) || ' / ' || left(v_got2, 90);
    return next;

    -- ── 8. Offboarded from a suspension, with no contract ───────────────────
    v_step := 'offboarding a suspended client with no contract';
    perform public.erp_platform_suspend_deployment(v_bare, 'The lifecycle suite suspends a client before it leaves.');
    v_json := public.erp_platform_begin_offboarding(v_bare, 'The client is leaving with no contract left to run.');
    v_cases := v_cases + 1;
    case_name := 'offboarding a suspended client with no contract sets its purge thirty days from now, serves it again, and asks for an export';
    passed := (select d.status = 'retiring' and d.suspended_reason is null
                      and d.purge_due_at = now() + interval '30 days'
                 from erp_meta.deployment d where d.code = v_bare)
          and v_json ->> 'was' = 'suspended'
          and jsonb_typeof(v_json -> 'contract_term_end') = 'null'
          and (v_json ->> 'export_queued')::boolean
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_bare and e.phase = 'note'
                         and e.detail like 'offboarding begun by ' || v_owner || ' (was suspended)%thirty days from now; a copy of its database is asked for.');
    detail := coalesce(v_json::text, 'no answer');
    return next;

    -- ── 9. Exports asked for ────────────────────────────────────────────────
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
    update erp_meta.platform_staff s set staff_role = 'support' where s.auth_user_id = v_uid;
    begin
      perform public.erp_platform_request_export(v_exp, c_reason);
      v_got2 := 'support asked';
    exception when others then
      v_got2 := sqlerrm;
    end;
    update erp_meta.platform_staff s set staff_role = 'owner' where s.auth_user_id = v_uid;
    v_cases := v_cases + 1;
    case_name := 'an operator asks for an export of a deployment that has data, and one waiting is not queued twice; support may not ask';
    passed := (v_json ->> 'queued')::boolean
          and not (v_json2 ->> 'queued')::boolean
          and v_json2 ->> 'request_id' = v_json ->> 'request_id'
          and (select count(*) from erp_meta.fleet_request r
                where r.kind = 'export' and r.payload ->> 'code' = v_exp and r.status in ('requested', 'claimed')) = 1
          and not (v_row ->> 'queued')::boolean
          and v_row ->> 'request_id' = v_e1::text
          and v_got = 'CLOVEERP_DEPLOYMENT_NOT_EXPORTABLE: ' || v_req || ' is not copied: it is requested'
          and v_got2 like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_exp and e.phase = 'note'
                         and e.detail like 'a copy of its database asked for by ' || v_owner || ': The client asked again%is still waiting, so no other is.')
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.deployment_export_requested' and a.target = v_exp
                         and a.actor_role = 'operator');
    detail := coalesce(v_json::text, '-') || ' / ' || coalesce(v_json2::text, '-') || ' / ' || left(v_got, 70)
           || ' / ' || left(v_got2, 50);
    return next;

    -- ── 10. The sweep claims exports ────────────────────────────────────────
    v_step := 'claiming an export';
    -- Oldest first: the one asked for by the offboarding.
    update erp_meta.fleet_request x set created_at = now() - interval '5 minutes' where x.id = v_e1;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-e', array['export']);
    v_got := coalesce(erp_meta.claim_fleet_request('run-' || v_tag || '-n', array['rename'])::text, 'nothing');
    begin
      perform erp_meta.claim_fleet_request('run-' || v_tag || '-x', array['export', 'rebuild']);
      v_got2 := 'it was claimed';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_n := 0;
    foreach v_json in array array[jsonb_build_object('kind', 'export', 'payload', '{}'::jsonb),
                                  jsonb_build_object('kind', 'rename', 'payload', jsonb_build_object('code', v_exp, 'to', 'zzlcz-' || v_tag)),
                                  jsonb_build_object('kind', 'rebuild', 'payload', jsonb_build_object('code', v_exp))] loop
      begin
        insert into erp_meta.fleet_request (kind, payload) values (v_json ->> 'kind', v_json -> 'payload');
      exception when check_violation then
        v_n := v_n + 1;
      end;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'the sweep claims the oldest export when it asks for exports, and the register keeps renames and exports only in their shapes';
    passed := v_claim ->> 'id' = v_e1::text
          and v_claim ->> 'kind' = 'export'
          and v_claim -> 'payload' ->> 'code' = v_con
          and (select r.status || ' ' || r.run_id from erp_meta.fleet_request r where r.id = v_e1) = 'claimed run-' || v_tag || '-e'
          and v_got = 'nothing'
          and v_got2 like 'CLOVEERP_FLEET_REQUEST_KIND_UNKNOWN: the console asks for builds, releases, renames and exports, not rebuild'
          and v_n = 3;
    detail := coalesce(v_claim::text, 'nothing claimed') || ' / renames: ' || v_got || ' / ' || left(v_got2, 90)
           || format(' / %s of 3 malformed kept out', v_n);
    return next;

    -- ── 11. The export recorded ─────────────────────────────────────────────
    v_step := 'recording an export';
    v_sql := array[
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L)', v_exp, 'exports/' || v_con || '/20261008T120000Z.dump.age', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L)', v_exp, 'backups/' || v_exp || '/2026-10-08.dump.age', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L)', v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 0, %L)', v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump.age', repeat('a', 64)),
      format('select erp_meta.record_deployment_export(%L, %L, 1000, %L)', v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump.age', 'not-a-fingerprint'),
      format('select erp_meta.record_deployment_export(%L, null, 1000, %L)', v_exp, repeat('a', 64))];
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
      perform erp_meta.record_deployment_export('zznobody-' || v_tag, 'exports/zznobody-' || v_tag || '/x.dump.age', 1000, repeat('a', 64));
      v_got2 := 'it was recorded';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_got := erp_meta.record_deployment_export(v_exp, 'exports/' || v_exp || '/20261008T120000Z.dump.age', 123456789, repeat('AB', 32));
    v_cases := v_cases + 1;
    case_name := 'an export is recorded by the trusted build role alone, in its own form: where it went for that client, its size, and its fingerprint';
    passed := v_n = 6
          and v_got2 like 'CLOVEERP_DEPLOYMENT_UNKNOWN%'
          and v_got = v_exp || ': copy recorded at exports/' || v_exp || '/20261008T120000Z.dump.age'
          and (select d.last_export_at = now() and d.last_export_object = 'exports/' || v_exp || '/20261008T120000Z.dump.age'
                 from erp_meta.deployment d where d.code = v_exp)
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_exp and e.phase = 'export' and e.status = 'done'
                         and e.detail = 'a copy of its database was written to exports/' || v_exp
                                        || '/20261008T120000Z.dump.age: 123456789 bytes, sha256 ' || repeat('ab', 32))
          and not (select p.prosecdef from pg_catalog.pg_proc p
                    where p.oid = 'erp_meta.record_deployment_export(text,text,bigint,text)'::regprocedure)
          and not pg_catalog.has_function_privilege('anon', 'erp_meta.record_deployment_export(text,text,bigint,text)', 'execute')
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.record_deployment_export(text,text,bigint,text)', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.record_deployment_export(text,text,bigint,text)', 'execute');
    detail := format('%s of 6 malformed refused%s; unknown: %s; %s', v_n, coalesce(' (' || v_bad || ')', ''),
                     left(v_got2, 50), left(v_got, 90));
    return next;

    -- ── 12. The Fleet view ──────────────────────────────────────────────────
    v_step := 'reading the Fleet view';
    perform public.erp_platform_suspend_deployment(v_built, 'The lifecycle suite suspends a built client to read the Fleet view.');
    v_json := public.erp_platform_deployments();
    v_row := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_built);
    v_row2 := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_exp);
    v_row3 := (select x from jsonb_array_elements(v_json) x where x ->> 'code' = v_con);
    v_cases := v_cases + 1;
    case_name := 'the Fleet view carries where a deployment is served and was, the day its purge is due, why it is suspended, and its last export';
    passed := v_row ->> 'status' = 'suspended'
          and v_row ->> 'suspended_reason' = 'The lifecycle suite suspends a built client to read the Fleet view.'
          and v_row ->> 'address' = v_built
          and v_row ->> 'origin' = 'https://' || v_built || '.' || v_apex
          and jsonb_typeof(v_row -> 'previous_address') = 'null'
          and jsonb_typeof(v_row -> 'previous_address_until') = 'null'
          and jsonb_typeof(v_row -> 'purge_due_at') = 'null'
          and (v_row ->> 'silent')::boolean
          and (select count(*) from jsonb_object_keys(v_row)) = 36
          and (v_row2 ->> 'last_export_at')::timestamptz = now()
          and v_row2 ->> 'last_export_object' = 'exports/' || v_exp || '/20261008T120000Z.dump.age'
          and (v_row3 ->> 'purge_due_at')::timestamptz = v_end::timestamptz + interval '30 days'
          and v_row3 ->> 'status' = 'retiring';
    detail := format('suspended: %s; exported: %s; purge due: %s; keys: %s',
                     coalesce(v_row ->> 'suspended_reason', 'missing'), coalesce(v_row2 ->> 'last_export_object', 'missing'),
                     coalesce(v_row3 ->> 'purge_due_at', 'missing'),
                     (select count(*) from jsonb_object_keys(coalesce(v_row, '{}'::jsonb))));
    return next;

    -- ── 13. Retired under a contract ────────────────────────────────────────
    v_step := 'retiring clients under contract';
    begin
      perform public.erp_platform_retire_deployment(v_exp, 'The lifecycle suite retires a client under contract, which must refuse.');
      v_got := 'it was retired';
    exception when others then
      v_got := sqlerrm;
    end;
    -- What the control plane owes the one being offboarded, and what waits for it.
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
    v_cases := v_cases + 1;
    case_name := 'a client under contract is retired only once its offboarding has begun; then what it was owed is failed, and its waiting rename and export cancelled';
    passed := v_got like 'CLOVEERP_DEPLOYMENT_HAS_A_CONTRACT: ' || v_exp || ' is not retired: its contract with Lifecycle Export Ltd is in force until %'
          and (select d.status from erp_meta.deployment d where d.code = v_exp) = 'live'
          and v_json ->> 'status' = c_retired and v_json ->> 'was' = 'retiring'
          and (v_json ->> 'pushes_failed')::integer = 2
          and (select string_agg(p.status, ',' order by p.payload ->> 'n') from erp_meta.deployment_push p where p.code = v_con)
              = 'failed,failed,applied'
          and (select bool_and(p.detail = 'the deployment was retired, so it is owed nothing more' and p.settled_at = now())
                 from erp_meta.deployment_push p where p.id in (v_p1, v_p2))
          and (select r.status from erp_meta.fleet_request r where r.id = v_rn) = 'cancelled'
          and (select r.status from erp_meta.fleet_request r where r.id = v_e2) = 'cancelled'
          and (select r.status from erp_meta.fleet_request r where r.id = v_e1) = 'claimed'
          and (select d.suspended_reason is null and d.owner_email is null from erp_meta.deployment d where d.code = v_con);
    detail := left(v_got, 120) || ' / ' || coalesce(v_json::text, 'no answer');
    return next;

    -- ── 14. Its mail ────────────────────────────────────────────────────────
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

    -- ── 15. The doors' standing ─────────────────────────────────────────────
    v_step := 'reading the doors';
    select count(*) into v_n
      from pg_catalog.pg_proc p
     where p.oid in ('public.erp_platform_suspend_deployment(text,text)'::regprocedure,
                     'public.erp_platform_reinstate_deployment(text,text)'::regprocedure,
                     'public.erp_platform_rename_deployment(text,text,text)'::regprocedure,
                     'public.erp_platform_begin_offboarding(text,text)'::regprocedure,
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
                               'erp_platform_rename_deployment', 'erp_platform_begin_offboarding');
    select count(*) into v_n3
      from pg_catalog.pg_proc p
     where p.oid in ('erp_meta.finish_deployment_rename(text,text)'::regprocedure,
                     'erp_meta.record_deployment_export(text,text,bigint,text)'::regprocedure,
                     'erp_meta.rename_client_organisation(text)'::regprocedure,
                     'erp_meta.deployment_address_starts_as_its_code()'::regprocedure)
       and not p.prosecdef
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('service_role', p.oid, 'execute');
    v_cases := v_cases + 1;
    case_name := 'the five doors run as their owner for signed-in callers and not anon, on both allowances, the owner''s four ranked; the trusted routines reach no session role';
    passed := v_n = 5 and v_n2 = 4 and v_n3 = 4
          and not exists (select 1 from erp_meta.platform_door_rank r where r.function_name = 'erp_platform_request_export');
    detail := format('%s of 5 doors, %s of 4 ranks, %s of 4 trusted routines', v_n, v_n2, v_n3);
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
      using hint = 'Suspending, reinstating, offboarding, exporting or retiring a client deployment does not do what the Fleet relies on: read the case that failed.';
  end if;
  if v_total <> 15 then
    raise exception 'CLOVEERP_DEPLOYMENT_LIFECYCLE_SUITE_SHRANK: % case(s), expected 15', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment lifecycle: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.deployment_lifecycle_suite() from public, anon;
revoke all on function erp_test.assert_deployment_lifecycle_suite() from public, anon;

comment on function erp_test.assert_deployment_lifecycle_suite() is
  'A client deployment is suspended and reinstated by the owner on the control plane with a reason, its address '
  'answering that it is suspended while it keeps receiving releases; offboarding makes it retiring with its purge '
  'date and an export; an operator asks for exports, recorded by the trusted build role in their own form; the '
  'Fleet view carries it all; retiring needs offboarding under a contract and fails what was owed; a retired '
  'deployment''s mail is not sent (20261012020000).';

create or replace function erp_test.deployment_rename_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  c_reason   constant text := 'The rename suite asks for this, and undoes it.';
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
  v_c1       text;
  v_c2       text;
  v_reserved text;
  v_tenant   uuid;
  v_json     jsonb;
  v_json2    jsonb;
  v_json3    jsonb;
  v_row      jsonb;
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
    insert into erp_meta.deployment (code, client_name, status, owner_email, project_ref, api_url, publishable_key, built_at)
    select y.code, y.name, y.status, 'admin@' || y.code || '.test', substr(md5(y.code), 1, 20),
           'https://' || substr(md5(y.code), 1, 20) || '.supabase.co', 'sb_publishable_' || replace(y.code, '-', ''),
           now() - interval '3 days'
      from (values (v_a, 'Rename Alpha Ltd', 'live'), (v_b, 'Rename Beta Ltd', 'live'),
                   (v_s, 'Rename Suspended Ltd', 'suspended')) as y(code, name, status);
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
          and (select r.kind = 'rename' and r.status = 'requested'
                      and r.payload = jsonb_build_object('code', v_a, 'from', v_a, 'to', v_x)
                 from erp_meta.fleet_request r where r.id = v_q1)
          and (select r.payload ->> 'to' from erp_meta.fleet_request r where r.id = v_q2) = v_w
          and v_json2 ->> 'status' = 'suspended'
          and (select d.address || '|' || coalesce(d.previous_address, 'none') from erp_meta.deployment d where d.code = v_a)
              = v_a || '|none'
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
    v_got := coalesce(erp_meta.claim_fleet_request('run-' || v_tag || '-b', array['build', 'release', 'export'])::text, 'nothing');
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
    case_name := 'the rename is finished by the trusted build role alone: the address moves, the old one leads to it for ninety days, and finishing again moves nothing';
    passed := v_got = v_a || ' moved from ' || v_a || ' to ' || v_x
          and v_got2 = v_a || ' is served at ' || v_x || ' already'
          and (select d.address = v_x and d.previous_address = v_a and d.previous_address_until = now() + interval '90 days'
                 from erp_meta.deployment d where d.code = v_a)
          and (select count(*) from erp_meta.deployment_event e where e.code = v_a and e.phase = 'rename') = 1
          and exists (select 1 from erp_meta.deployment_event e
                       where e.code = v_a and e.phase = 'rename' and e.status = 'done'
                         and e.detail like 'moved from ' || v_a || '.' || v_apex || ' to ' || v_x || '.' || v_apex
                                           || '; the old address leads to the new one until %')
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
    update erp_meta.deployment x set previous_address_until = now() - interval '1 minute' where x.code = v_a;
    execute 'set local role service_role';
    v_json3 := public.erp_deployment_for_host(v_a || '.' || v_apex);
    execute format('set local role %I', v_role);
    update erp_meta.deployment x set previous_address_until = now() + interval '90 days' where x.code = v_a;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_a);
    v_cases := v_cases + 1;
    case_name := 'the new address answers with the project, the old one says where it went for ninety days and nothing after, and the Fleet view says both';
    passed := v_json = jsonb_build_object('code', v_a, 'client_name', 'Rename Alpha Ltd',
                                          'url', 'https://' || substr(md5(v_a), 1, 20) || '.supabase.co',
                                          'key', 'sb_publishable_' || replace(v_a, '-', ''))
          and v_json2 = jsonb_build_object('code', v_a, 'client_name', 'Rename Alpha Ltd',
                                           'moved_to', 'https://' || v_x || '.' || v_apex)
          and v_json3 is null
          and v_row ->> 'origin' = 'https://' || v_x || '.' || v_apex
          and v_row ->> 'address' = v_x
          and v_row ->> 'previous_address' = v_a
          and (v_row ->> 'previous_address_until')::timestamptz = now() + interval '90 days';
    detail := coalesce(v_json::text, 'nothing') || ' / ' || coalesce(v_json2::text, 'nothing') || ' / after: '
           || coalesce(v_json3::text, 'nothing');
    return next;

    -- ── 8. Every address it had stays held ──────────────────────────────────
    v_step := 'moving it again and asking for what it had';
    v_json := public.erp_platform_rename_deployment(v_a, v_z, 'The client changed its mind and asked for another address.');
    -- As the sweep and the workflow would: claimed (before the suspended
    -- client's, which is younger), finished, settled.
    update erp_meta.fleet_request x set created_at = now() - interval '4 minutes'
     where x.id = (v_json ->> 'request_id')::uuid;
    v_claim := erp_meta.claim_fleet_request('run-' || v_tag || '-r2', array['rename']);
    perform erp_meta.finish_deployment_rename(v_a, v_z);
    perform erp_meta.settle_fleet_request((v_claim ->> 'id')::uuid, 'success: fleet_rename.yml re-pointed the project');
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
      perform public.erp_platform_request_deployment(v_a, 'Rename Taker Ltd', 'admin@' || v_a || '.test', c_reason);
      v_bad := 'it was requested';
    exception when others then
      v_bad := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'the code, the address and the address before stay held across the fleet: no deployment or organisation is given them';
    passed := (select d.address = v_z and d.previous_address = v_x from erp_meta.deployment d where d.code = v_a)
          and v_claim ->> 'id' = v_json ->> 'request_id'
          and (select r.status from erp_meta.fleet_request r where r.id = (v_json ->> 'request_id')::uuid) = 'done'
          and v_got = 'CLOVEERP_ADDRESS_TAKEN: "' || v_x || '" was a client deployment''s address and is kept for it'
          and v_got2 = 'CLOVEERP_ADDRESS_TAKEN: "' || v_a || '" is a client deployment''s address'
          and v_got3 = 'CLOVEERP_ADDRESS_TAKEN: "' || v_z || '" is a client deployment''s address'
          and v_got4 = v_got
          and v_bad like 'CLOVEERP_DEPLOYMENT_EXISTS%';
    detail := left(v_got, 90) || ' / ' || left(v_got2, 70) || ' / ' || left(v_got4, 70) || ' / ' || left(v_bad, 50);
    return next;

    -- ── 9. Finishing what cannot be finished ────────────────────────────────
    v_step := 'finishing renames that cannot be finished';
    v_sql := array[
      format('select erp_meta.finish_deployment_rename(%L, %L)', 'zznobody-' || v_tag, v_y),
      format('select erp_meta.finish_deployment_rename(%L, %L)', v_b, v_x),
      format('select erp_meta.finish_deployment_rename(%L, %L)', v_r, v_y),
      format('select erp_meta.finish_deployment_rename(%L, %L)', v_b, 'not an address')];
    v_want := array['CLOVEERP_DEPLOYMENT_UNKNOWN',
                    'CLOVEERP_ADDRESS_TAKEN: "' || v_x || '" is held by another deployment or organisation, so ' || v_b || ' is not moved to it',
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

    -- ── 10. The client's own organisation follows ───────────────────────────
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
  if v_total <> 10 then
    raise exception 'CLOVEERP_DEPLOYMENT_RENAME_SUITE_SHRANK: % case(s), expected 10', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('deployment rename: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.deployment_rename_suite() from public, anon;
revoke all on function erp_test.assert_deployment_rename_suite() from public, anon;

comment on function erp_test.assert_deployment_rename_suite() is
  'A rename is asked for by the owner for a built, live or suspended deployment, to an address nobody has, had or '
  'is being moved to, one at a time; the sweep claims it; the trusted build role finishes it, the old address '
  'leading to the new one for ninety days in the directory and staying held; a client''s one organisation follows '
  'once its project answers at the new address (20261012020000).';

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
