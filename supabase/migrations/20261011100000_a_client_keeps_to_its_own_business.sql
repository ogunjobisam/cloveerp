set lock_timeout = '30s';

-- =============================================================================
-- 20261011100000  A client keeps to its own business
-- -----------------------------------------------------------------------------
-- Since 20261011010000 a database knows whether it is production (the control
-- plane, with Clove ERP Ltd and Clove Foods on it), the demonstration, or a
-- client's own project. A client's project was told, and nothing listened:
-- every door the platform console has was still open on it. The owner, signed
-- in to acme.cloveerp.com/platform, could designate a platform organisation
-- there, price, quote, contract, invoice and take enquiries, add staff whom the
-- control plane had never heard of, and onboard a second organisation, or one
-- under somebody else's address.
--
-- The owner's decisions of 8 October:
--
--   A. A client's deployment refuses the control plane's business. The gate is
--      a new routine, erp.require_not_client(), which refuses with the existing
--      CLOVEERP_NOT_THE_CONTROL_PLANE only where erp.deployment_kind() is
--      'client'. The demonstration and the schema build, which are marked
--      'demonstration', go on as they were, so every commercial suite still
--      runs. (erp.require_control_plane() refuses everywhere but production
--      and stays on the register's doors, where that is right.)
--
--      It is put into each routine by pattern, not by an md5 anchor: right
--      after the rank gate (erp_meta.require_platform), so "not staff" and
--      "rank too low" still come first, or after the platform organisation
--      check, or, where there is no gate at all, as the first statement. A
--      routine another migration has rewritten since main is gated all the
--      same, a routine already gated is left alone, and the block refuses if
--      any listed routine ends up without the gate. Incidents are not gated:
--      until notices are pushed into clients, declaring one on a client's own
--      console is the only way to put a banner in front of its people.
--
--   B. Staff are kept on the control plane only. On a client the three doors
--      that add, re-rank and remove staff refuse (a new refusal,
--      CLOVEERP_STAFF_KEPT_ON_THE_CONTROL_PLANE), after their rank gate. A
--      later workflow makes every client's staff list match the control
--      plane's through two trusted routines added here,
--      erp_meta.add_platform_staff_trusted() and
--      erp_meta.revoke_platform_staff_trusted(), which no session role can
--      execute. A member of staff added that way is bound to a confirmed
--      sign-in from the start, so no unbound row waits on a client to be
--      matched by whoever confirms the address.
--
--   C. A client's deployment holds one organisation, under the deployment's
--      own code. erp.deployment_code() reads that code from the address the
--      deployment is served at (https://<code>.cloveerp.com), on a client
--      only. Onboarding, from the console or through the self-service door,
--      refuses a second organisation (CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION)
--      and any other address (CLOVEERP_CLIENT_ORGANISATION_CODE); opening
--      self-service sign-up refuses there too. erp_platform_me() answers
--      'deployment_code' beside the kind and the origin.
--
--   D. The proof: erp_test.client_keeps_to_its_own_business_suite, eleven
--      cases, with its assertion.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Nothing on production or the demonstration: every new refusal tests for a
-- client first. No row is written. The fleet's doors keep
-- erp.require_control_plane(). Of everything that runs by itself — jobs,
-- sweeps, the dispatch worker, the assurance checks — only two paths reach a
-- gate: the chase of overdue invoices, a job only the platform organisation
-- has (a client has none, and that check comes first), and the enquiry form's
-- own door, which on a client now refuses, as it should.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_NOT_THE_CONTROL_PLANE',
  'Doing the control plane''s work on a demonstration or on a client''s deployment.',
  'Selling, the contracts, their invoices, the enquiries and the register of client deployments live on '
  'production, the control plane. A client''s database holds one customer and knows nothing of the others; '
  'the demonstration holds invented ones.',
  'Open the platform console at cloveerp.com and do it there.');

select erp.register_refusal(
  'CLOVEERP_STAFF_KEPT_ON_THE_CONTROL_PLANE',
  'Adding, re-ranking or removing platform staff on a client''s own deployment.',
  'The platform''s staff are kept in one list, on the control plane, and every client''s deployment is made to '
  'match it. A change made on one client alone would be undone by the next match, or would leave somebody there '
  'whom the list no longer names.',
  'Make the change in the platform console at cloveerp.com. Every client''s deployment then follows it.');

select erp.register_refusal(
  'CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION',
  'A second organisation on a client''s own deployment, or opening sign-up there so that anybody could make one.',
  'A client''s own deployment is one customer''s database, and it holds that customer''s organisation and no '
  'other. Another organisation needs a deployment of its own.',
  'Invite people into the organisation that is already here. For another organisation, request a deployment of '
  'its own from the platform console at cloveerp.com.');

select erp.register_refusal(
  'CLOVEERP_CLIENT_ORGANISATION_CODE',
  'Making the organisation on a client''s own deployment under an address that is not the deployment''s.',
  'A client''s own deployment is served at an address of its own, and the one organisation it holds takes that '
  'same address, so that the people who sign in there find it.',
  'Give the organisation the address the deployment is served at: the part of its web address before the first '
  'dot. If the deployment does not know its address yet, release it again first.');

select erp.register_refusal(
  'CLOVEERP_PLATFORM_STAFF_SIGN_IN_UNKNOWN',
  'Putting somebody on a deployment''s staff list against a sign-in that is not theirs.',
  'A member of staff kept from the control plane''s list is bound to one confirmed sign-in with the same address, '
  'so that nobody else who later confirms that address is taken for them.',
  'Make the person''s sign-in on that deployment first, with the same address and confirmed, and name that '
  'sign-in.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. What a client refuses
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.require_not_client()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if erp.deployment_kind() = 'client' then
    raise exception 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a client''s own deployment; selling, contracts, invoices and enquiries live on the control plane'
      using errcode = '42501',
            hint = 'Open the platform console at cloveerp.com and do it there.';
  end if;
end;
$$;

revoke all on function erp.require_not_client() from public, anon;

comment on function erp.require_not_client() is
  'Refuses with CLOVEERP_NOT_THE_CONTROL_PLANE on a client''s own deployment (erp.deployment_kind() = ''client'') '
  'and nowhere else, so the demonstration and the schema build go on as they were. Asked by every routine of the '
  'control plane''s business, selling, contracts, invoices and enquiries, right after its rank gate '
  '(20261011100000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C (first, because B and C both read it). Which client this is
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.deployment_code()
returns text
language sql
stable
set search_path = ''
as $$
  -- The first label of the address a client's deployment is served at
  -- (https://acme.cloveerp.com is acme), shaped as a deployment's code is. Null
  -- anywhere but a client, and on a client not yet told an address of its own:
  -- the apex a database falls back to names no client.
  select case
           when erp.deployment_kind() = 'client' then
             substring(lower(erp.app_origin())
                       from '^https://([a-z0-9][a-z0-9-]{1,61}[a-z0-9])\.[a-z0-9-]+(?:\.[a-z0-9-]+)+(?::[0-9]{1,5})?$')
         end
$$;

revoke all on function erp.deployment_code() from public, anon;

comment on function erp.deployment_code() is
  'On a client''s own deployment, its code: the first label of the address it is served at (erp.app_origin(), '
  'https://<code>.cloveerp.com). Null on production and the demonstration, and on a client not yet told its '
  'address. The one organisation a client holds takes this code (20261011100000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Staff are kept on the control plane
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.refuse_staff_change_on_a_client()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if erp.deployment_kind() = 'client' then
    raise exception 'CLOVEERP_STAFF_KEPT_ON_THE_CONTROL_PLANE: platform staff are added, re-ranked and removed on the control plane, and this is a client''s own deployment'
      using errcode = '42501',
            hint = 'Make the change in the platform console at cloveerp.com. Every client''s deployment then follows it.';
  end if;
end;
$$;

revoke all on function erp.refuse_staff_change_on_a_client() from public, anon;

comment on function erp.refuse_staff_change_on_a_client() is
  'Refuses with CLOVEERP_STAFF_KEPT_ON_THE_CONTROL_PLANE on a client''s own deployment: its staff list is made to '
  'match the control plane''s by a trusted workflow, not edited at its own console. Asked by the doors that add, '
  're-rank and remove staff, after their rank gate (20261011100000).';

create or replace function erp_meta.add_platform_staff_trusted(
  p_email text, p_display_name text, p_role text, p_auth_user_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_email   text := lower(btrim(coalesce(p_email, '')));
  v_role    text := lower(btrim(coalesce(p_role, '')));
  v_name    text := coalesce(nullif(btrim(coalesce(p_display_name, '')), ''), lower(btrim(coalesce(p_email, ''))));
  v_was     erp_meta.platform_staff;
  v_other   erp_meta.platform_staff;
  v_n       erp_meta.platform_staff;
begin
  if erp_meta.platform_rank(v_role) = 0 then
    raise exception 'CLOVEERP_UNKNOWN_PLATFORM_ROLE: % is not one of the four ranks: owner, administrator, operator or support', coalesce(p_role, 'nothing')
      using errcode = '22023',
            hint = 'Give the rank the person holds on the control plane: owner, administrator, operator or support.';
  end if;

  -- Bound from the start, to the confirmed sign-in with that very address: a
  -- row that names only an address is matched by whoever confirms it.
  if p_auth_user_id is null
     or not exists (select 1 from auth.users u
                     where u.id = p_auth_user_id
                       and lower(u.email) = v_email
                       and u.email_confirmed_at is not null) then
    raise exception 'CLOVEERP_PLATFORM_STAFF_SIGN_IN_UNKNOWN: % has no confirmed sign-in here by that name to be bound to', coalesce(nullif(v_email, ''), 'nobody')
      using errcode = '22023',
            hint = 'Make the person''s sign-in on this deployment first, with the same address and confirmed, and name that sign-in.';
  end if;

  -- One change to the list at a time, so two calls cannot both find an owner
  -- to spare.
  perform pg_advisory_xact_lock(hashtext('erp_meta.platform_staff'));

  select * into v_other
    from erp_meta.platform_staff s
   where s.auth_user_id = p_auth_user_id
     and lower(s.email) <> v_email;
  if v_other.id is not null then
    raise exception 'CLOVEERP_PLATFORM_STAFF_SIGN_IN_UNKNOWN: that sign-in is already bound to another member of staff, %', v_other.email
      using errcode = '23505',
            hint = 'Name the sign-in that belongs to this address, or remove the other member of staff first.';
  end if;

  select * into v_was from erp_meta.platform_staff s where lower(s.email) = v_email;

  -- Kept as the control plane's list says: nothing to write.
  if v_was.id is not null and v_was.revoked_at is null and v_was.staff_role = v_role
     and v_was.display_name = v_name and v_was.auth_user_id = p_auth_user_id then
    return jsonb_build_object('id', v_was.id, 'email', v_was.email, 'role', v_was.staff_role,
                              'bound', true, 'changed', false);
  end if;

  -- The platform is never left without an owner here, even for a moment.
  if v_was.id is not null and v_was.revoked_at is null and v_was.staff_role = 'owner' and v_role <> 'owner'
     and (select count(*) from erp_meta.platform_staff s
           where s.staff_role = 'owner' and s.revoked_at is null) <= 1 then
    raise exception 'CLOVEERP_LAST_OWNER: % is the only owner here, and would leave the platform without one', v_was.email
      using errcode = '23514',
            hint = 'Add the control plane''s other owner here first, then change this one.';
  end if;

  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values (v_email, p_auth_user_id, v_name, v_role)
  on conflict ((lower(email))) do update
     set staff_role = excluded.staff_role,
         display_name = excluded.display_name,
         auth_user_id = excluded.auth_user_id,
         revoked_at = null, revoked_reason = null, updated_at = now()
  returning * into v_n;

  -- The platform's own trail. Made by the workflow that keeps the list, so by
  -- nobody signed in: written as the purge sweep and the restore drill write.
  insert into erp_meta.platform_audit (actor_email, actor_role, action, target, reason, detail)
  values ('system', 'platform', 'platform.staff_kept', v_n.email,
          'Kept as the control plane''s staff list says (20261011100000).',
          jsonb_build_object('role', v_n.staff_role,
                             'was', case when v_was.id is null then 'absent'
                                         when v_was.revoked_at is not null then 'removed'
                                         else v_was.staff_role end,
                             'rebound', v_was.id is not null and v_was.auth_user_id is distinct from p_auth_user_id));

  return jsonb_build_object('id', v_n.id, 'email', v_n.email, 'role', v_n.staff_role,
                            'bound', true, 'changed', true);
end;
$$;

revoke all on function erp_meta.add_platform_staff_trusted(text, text, text, uuid)
  from public, anon, authenticated, service_role;

comment on function erp_meta.add_platform_staff_trusted(text, text, text, uuid) is
  'Puts a member of staff on this deployment''s list, or brings them back, at the rank the control plane''s list '
  'gives, bound to the confirmed sign-in with that address (p_auth_user_id). Refuses an unknown rank, a sign-in '
  'that is not theirs, and leaving the platform without an owner; repeating what is already so writes nothing. For '
  'the trusted build role only, from the workflow that makes every client''s staff match the control plane''s '
  '(20261011100000).';

create or replace function erp_meta.revoke_platform_staff_trusted(p_email text, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_reason text := coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Not on the control plane''s staff list.');
  v_t      erp_meta.platform_staff;
begin
  perform pg_advisory_xact_lock(hashtext('erp_meta.platform_staff'));

  select * into v_t
    from erp_meta.platform_staff s
   where lower(s.email) = v_email
     and s.revoked_at is null;

  -- Not on the list, or removed already: as the control plane's list says.
  if v_t.id is null then
    return jsonb_build_object('email', v_email, 'revoked', false, 'changed', false);
  end if;

  if v_t.staff_role = 'owner'
     and (select count(*) from erp_meta.platform_staff s
           where s.staff_role = 'owner' and s.revoked_at is null) <= 1 then
    raise exception 'CLOVEERP_LAST_OWNER: % is the only owner here, and the platform would have no owner', v_t.email
      using errcode = '23514',
            hint = 'Add the control plane''s other owner here first, then remove this one.';
  end if;

  -- Soft, as the console's own removal is: the row and its binding stay, so a
  -- person put back later is the same person.
  update erp_meta.platform_staff
     set revoked_at = now(), revoked_reason = v_reason, updated_at = now()
   where id = v_t.id;

  insert into erp_meta.platform_audit (actor_email, actor_role, action, target, reason, detail)
  values ('system', 'platform', 'platform.staff_revoked', v_t.email, v_reason,
          jsonb_build_object('role', v_t.staff_role, 'kept_from', 'the control plane''s staff list'));

  return jsonb_build_object('id', v_t.id, 'email', v_t.email, 'revoked', true, 'changed', true);
end;
$$;

revoke all on function erp_meta.revoke_platform_staff_trusted(text, text)
  from public, anon, authenticated, service_role;

comment on function erp_meta.revoke_platform_staff_trusted(text, text) is
  'Removes a member of staff from this deployment''s list, softly (the row and its binding stay), because the '
  'control plane''s list no longer names them. Never the last owner; someone not on the list, or removed already, '
  'is left as they are. For the trusted build role only, from the workflow that makes every client''s staff match '
  'the control plane''s (20261011100000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. One organisation, under the deployment's own code
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.require_client_organisation(p_code text)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_mine text;
  v_held text;
  v_code text := lower(btrim(coalesce(p_code, '')));
begin
  if erp.deployment_kind() <> 'client' then
    return;
  end if;

  -- Two onboardings started together must not both find the deployment empty.
  perform pg_advisory_xact_lock(hashtext('erp.require_client_organisation'));

  select string_agg(t.code, ', ' order by t.code) into v_held
    from erp.tenant t
   where t.status not in ('deleting', 'deleted');
  if v_held is not null then
    raise exception 'CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION: this deployment holds % already, and a client''s own deployment holds one organisation', v_held
      using errcode = '55000',
            hint = 'Invite people into the organisation that is already here. For another organisation, request a '
                   'deployment of its own from the platform console at cloveerp.com.';
  end if;

  v_mine := erp.deployment_code();
  if v_mine is null then
    raise exception 'CLOVEERP_CLIENT_ORGANISATION_CODE: this deployment has not been told the address it is served at, so it cannot yet say which organisation is its own'
      using errcode = '55000',
            hint = 'Release the deployment again so that it learns its address, then make its organisation.';
  end if;
  if v_code <> v_mine then
    raise exception 'CLOVEERP_CLIENT_ORGANISATION_CODE: this deployment is served as %, so its organisation''s address is %, not %', v_mine, v_mine, coalesce(nullif(v_code, ''), 'nothing')
      using errcode = '22023',
            hint = 'Give the organisation the address the deployment is served at: the part of its web address '
                   'before the first dot.';
  end if;
end;
$$;

revoke all on function erp.require_client_organisation(text) from public, anon;

comment on function erp.require_client_organisation(text) is
  'On a client''s own deployment, refuses an organisation when one is held already '
  '(CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION) or when its code is not the deployment''s own '
  '(CLOVEERP_CLIENT_ORGANISATION_CODE, erp.deployment_code()). Does nothing anywhere else. Asked by both ways an '
  'organisation is made, the console''s onboarding and the self-service door, inside their definer frames '
  '(20261011100000).';

create or replace function erp.refuse_open_sign_up_on_a_client(p_open boolean)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if coalesce(p_open, false) and erp.deployment_kind() = 'client' then
    raise exception 'CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION: a client''s own deployment holds one organisation, so the sign-up that lets anybody make one stays closed here'
      using errcode = '55000',
            hint = 'Invite people into the organisation that is here. For another organisation, request a deployment '
                   'of its own from the platform console at cloveerp.com.';
  end if;
end;
$$;

revoke all on function erp.refuse_open_sign_up_on_a_client(boolean) from public, anon;

comment on function erp.refuse_open_sign_up_on_a_client(boolean) is
  'Refuses to open self-service sign-up on a client''s own deployment, which holds one organisation; closing it is '
  'always allowed (20261011100000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- The gates, put in by pattern
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Where:
--   rank   right after the routine's erp_meta.require_platform(...) line, at
--          its indent, so the staff and rank refusals still come first;
--   after  right after the first "end if;" that follows a named needle;
--   first  the first statement after the routine's outer "begin".
-- Every overload of each name. A routine that already makes the call is left
-- as it is, so the block can run again and can follow another migration that
-- rewrote a body since main (no md5 anchor on purpose).

do $gate$
declare
  r       record;
  f       record;
  v_new   text;
  v_def   text;
  v_at    integer;
  v_end   integer;
  v_cut   integer;
  v_n     integer;
  v_done  integer := 0;
  v_bad   text;
begin
  create temp table _gate (ns text, fn text, place text, needle text, marker text, stmt text) on commit drop;
  insert into _gate values
    -- A. The control plane's business: selling, quotes (through the platform
    --    organisation's own check), contracts, renewals, invoices, enquiries.
    ('erp', 'require_platform_organisation', 'after', 'CLOVEERP_NOT_THE_PLATFORM_ORGANISATION',
     'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'designate_platform_organisation', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'create_contract_from_quote', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'sign_contract', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'amend_contract', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'sign_amendment', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'attach_contract_document', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'renew_contract', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'decline_renewal', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'issue_contract_invoice', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'record_invoice_paid', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_commercial_state', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_price_book', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_set_index_rate', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_contracts', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_contract', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_contract_document', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_set_billing_contact', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_commercial_emails', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_send_commercial_email', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_commercial_document', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_revenue', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_propose_renewals', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_invoices', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_generate_invoices', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_open_invoices', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_billing_details', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_set_billing_details', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_enquiries', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_enquiry_notify_to', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_set_enquiry_notify_to', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_mark_enquiry_handled', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('public', 'erp_platform_erase_enquiry', 'rank', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    ('erp', 'record_enquiry', 'first', null, 'erp.require_not_client()', 'perform erp.require_not_client();'),
    -- B. Staff are kept on the control plane.
    ('public', 'erp_platform_add_staff', 'rank', null,
     'erp.refuse_staff_change_on_a_client()', 'perform erp.refuse_staff_change_on_a_client();'),
    ('public', 'erp_platform_set_staff_role', 'rank', null,
     'erp.refuse_staff_change_on_a_client()', 'perform erp.refuse_staff_change_on_a_client();'),
    ('public', 'erp_platform_revoke_staff', 'rank', null,
     'erp.refuse_staff_change_on_a_client()', 'perform erp.refuse_staff_change_on_a_client();'),
    -- C. One organisation, under the deployment's own code; sign-up closed.
    ('public', 'erp_platform_onboard_company', 'rank', null,
     'erp.require_client_organisation(', 'perform erp.require_client_organisation(p_code);'),
    ('erp', 'onboard_tenant', 'after', 'CLOVEERP_VALIDATION: tenant name and code are required',
     'erp.require_client_organisation(', 'perform erp.require_client_organisation(p_code);'),
    ('public', 'erp_platform_set_self_service_organisations', 'rank', null,
     'erp.refuse_open_sign_up_on_a_client(', 'perform erp.refuse_open_sign_up_on_a_client(p_open);');

  for r in select * from _gate loop
    v_n := 0;
    for f in
      select p.oid, p.prosrc
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = r.ns and p.proname = r.fn
    loop
      v_n := v_n + 1;
      if strpos(f.prosrc, r.marker) > 0 then
        continue;
      end if;

      if r.place = 'rank' then
        v_new := regexp_replace(
          f.prosrc,
          '^([ \t]*)((?:[a-z_]+[ \t]*:=[ \t]*|perform[ \t]+)erp_meta\.require_platform\(''[a-z]+''\);[^\n]*)$',
          '\1\2' || E'\n' || '\1' || r.stmt,
          'n');
      elsif r.place = 'after' then
        v_at := strpos(f.prosrc, r.needle);
        v_end := case when v_at > 0 then strpos(substr(f.prosrc, v_at), 'end if;') else 0 end;
        if v_at = 0 or v_end = 0 then
          v_new := f.prosrc;
        else
          v_cut := v_at + v_end - 1 + length('end if;') - 1;
          v_new := substr(f.prosrc, 1, v_cut) || E'\n  ' || r.stmt || substr(f.prosrc, v_cut + 1);
        end if;
      elsif r.place = 'first' then
        v_new := regexp_replace(f.prosrc, '^(begin)[ \t]*$', '\1' || E'\n  ' || r.stmt, 'n');
      else
        raise exception 'CLOVEERP_ANCHOR_MOVED: no such place as "%" for %.%', r.place, r.ns, r.fn;
      end if;

      if v_new = f.prosrc then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % has nowhere 20261011100000 can put %', f.oid::regprocedure, r.stmt;
      end if;

      v_def := pg_catalog.pg_get_functiondef(f.oid);
      if (length(v_def) - length(replace(v_def, f.prosrc, ''))) / length(f.prosrc) <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % does not hold its own body once', f.oid::regprocedure;
      end if;
      execute replace(v_def, f.prosrc, v_new);
      v_done := v_done + 1;
    end loop;

    if v_n = 0 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: %.% does not exist, so 20261011100000 cannot gate it', r.ns, r.fn;
    end if;
  end loop;

  -- Every overload of every name carries its gate, and where the gate follows
  -- a rank gate or a check, it follows it.
  select string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
    into v_bad
    from _gate g
    join pg_catalog.pg_namespace n on n.nspname = g.ns
    join pg_catalog.pg_proc p on p.pronamespace = n.oid and p.proname = g.fn
   where strpos(p.prosrc, g.marker) = 0
      or (g.place = 'rank' and strpos(p.prosrc, g.marker) < strpos(p.prosrc, 'erp_meta.require_platform('))
      or (g.place = 'rank' and strpos(p.prosrc, 'erp_meta.require_platform(') = 0)
      or (g.place = 'after' and strpos(p.prosrc, g.marker) < strpos(p.prosrc, g.needle));
  if v_bad is not null then
    raise exception 'CLOVEERP_ANCHOR_MOVED: not gated as 20261011100000 means them to be: %', v_bad;
  end if;

  raise notice '20261011100000: % routine(s) gated, % gated already', v_done,
    (select count(*) from _gate g
       join pg_catalog.pg_namespace n on n.nspname = g.ns
       join pg_catalog.pg_proc p on p.pronamespace = n.oid and p.proname = g.fn) - v_done;
  drop table _gate;
end
$gate$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The console is told which client it is on
-- ─────────────────────────────────────────────────────────────────────────────

do $me$
declare
  v_sig  constant text := 'public.erp_platform_me()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$                              'origin', erp.app_origin(),
                              'project_ref', erp.deployment_ref());$o$;
  v_new1 constant text := $n$                              'origin', erp.app_origin(),
                              'project_ref', erp.deployment_ref(),
                              'deployment_code', erp.deployment_code());$n$;
  v_old2 constant text := $o$    'origin', erp.app_origin(),
    'project_ref', erp.deployment_ref());$o$;
  v_new2 constant text := $n$    'origin', erp.app_origin(),
    'project_ref', erp.deployment_ref(),
    -- On a client's own deployment, its code, which its one organisation
    -- takes (20261011100000); null elsewhere.
    'deployment_code', erp.deployment_code());$n$;
begin
  if strpos(v_src, 'deployment_code') > 0 then
    raise notice '% already answers the deployment''s code; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'dec5d77834ebbc40170f3a0d738c06f7' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261011100000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$me$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof: eleven cases
-- ─────────────────────────────────────────────────────────────────────────────

-- What each routine of the control plane's business answers when asked with
-- nothing, every overload, each in a subtransaction that is undone whatever it
-- did. Asked by the suite on a client, where every answer must be the gate's,
-- and on the demonstration and production, where none may be.
create or replace function erp_test.control_plane_business_answers()
returns table(routine text, answer text)
language plpgsql
set search_path = ''
as $$
declare
  c_names constant text[] := array[
    'erp.require_platform_organisation', 'erp.designate_platform_organisation', 'erp.create_contract_from_quote',
    'erp.sign_contract', 'erp.amend_contract', 'erp.sign_amendment', 'erp.attach_contract_document',
    'erp.renew_contract', 'erp.decline_renewal', 'erp.issue_contract_invoice', 'erp.record_invoice_paid',
    'public.erp_platform_commercial_state', 'public.erp_price_book', 'public.erp_platform_set_index_rate',
    'public.erp_platform_contracts', 'public.erp_platform_contract', 'public.erp_platform_contract_document',
    'public.erp_platform_set_billing_contact', 'public.erp_platform_commercial_emails',
    'public.erp_platform_send_commercial_email', 'public.erp_platform_commercial_document',
    'public.erp_platform_revenue', 'public.erp_platform_propose_renewals', 'public.erp_platform_invoices',
    'public.erp_platform_generate_invoices', 'public.erp_platform_open_invoices',
    'public.erp_platform_billing_details', 'public.erp_platform_set_billing_details',
    'public.erp_platform_enquiries', 'public.erp_platform_enquiry_notify_to',
    'public.erp_platform_set_enquiry_notify_to', 'public.erp_platform_mark_enquiry_handled',
    'public.erp_platform_erase_enquiry', 'erp.record_enquiry'];
  f record;
begin
  for f in
    select n.nspname, p.proname, p.pronargs, p.oid
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname || '.' || p.proname = any (c_names)
     order by n.nspname, p.proname, p.oid
  loop
    routine := f.oid::regprocedure::text;
    begin
      execute format('select %I.%I(%s)', f.nspname, f.proname,
                     coalesce((select string_agg('null', ', ') from generate_series(1, f.pronargs)), ''));
      raise exception 'CLOVEERP_SUITE_PROBE_ANSWERED';
    exception when others then
      answer := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

revoke all on function erp_test.control_plane_business_answers() from public, anon;

comment on function erp_test.control_plane_business_answers() is
  'For erp_test.client_keeps_to_its_own_business_suite: calls every overload of every routine of the control '
  'plane''s business with nothing, undoes whatever it did, and says what each answered (20261011100000).';

create or replace function erp_test.client_keeps_to_its_own_business_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  -- What 20261011100000 gates, by schema and name.
  c_gated constant text[] := array[
    'erp.require_platform_organisation', 'erp.designate_platform_organisation', 'erp.create_contract_from_quote',
    'erp.sign_contract', 'erp.amend_contract', 'erp.sign_amendment', 'erp.attach_contract_document',
    'erp.renew_contract', 'erp.decline_renewal', 'erp.issue_contract_invoice', 'erp.record_invoice_paid',
    'public.erp_platform_commercial_state', 'public.erp_price_book', 'public.erp_platform_set_index_rate',
    'public.erp_platform_contracts', 'public.erp_platform_contract', 'public.erp_platform_contract_document',
    'public.erp_platform_set_billing_contact', 'public.erp_platform_commercial_emails',
    'public.erp_platform_send_commercial_email', 'public.erp_platform_commercial_document',
    'public.erp_platform_revenue', 'public.erp_platform_propose_renewals', 'public.erp_platform_invoices',
    'public.erp_platform_generate_invoices', 'public.erp_platform_open_invoices',
    'public.erp_platform_billing_details', 'public.erp_platform_set_billing_details',
    'public.erp_platform_enquiries', 'public.erp_platform_enquiry_notify_to',
    'public.erp_platform_set_enquiry_notify_to', 'public.erp_platform_mark_enquiry_handled',
    'public.erp_platform_erase_enquiry', 'erp.record_enquiry'];
  -- Incidents are a client's own until notices are pushed into clients.
  c_incidents constant text[] := array[
    'public.erp_platform_declare_incident', 'public.erp_platform_post_incident_update',
    'public.erp_platform_contain_incident', 'public.erp_platform_resolve_incident',
    'public.erp_platform_announce_maintenance', 'public.erp_platform_cancel_maintenance',
    'public.erp_platform_record_disclosure', 'public.erp_platform_flag_security_incident',
    'public.erp_platform_name_affected_organisations', 'public.erp_platform_add_incident_action',
    'public.erp_platform_complete_incident_action', 'public.erp_platform_assemble_incident_review',
    'public.erp_platform_incidents',
    'erp.declare_incident', 'erp.post_incident_update', 'erp.contain_incident', 'erp.resolve_incident',
    'erp.announce_maintenance', 'erp.cancel_maintenance', 'erp.record_disclosure', 'erp.flag_security_incident',
    'erp.name_affected_organisations', 'erp.add_incident_action', 'erp.complete_incident_action',
    'erp.assemble_incident_review'];
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_code   text;
  v_origin text;
  v_uid    uuid := gen_random_uuid();
  v_uid2   uuid := gen_random_uuid();
  v_owner  text;
  v_ops    text;
  v_staff  uuid;
  v_tenant uuid;
  v_step   text := 'standing up an owner on a client';
  v_state  text;
  v_got    text;
  v_got2   text;
  v_got3   text;
  v_got4   text;
  v_bad    text;
  v_extra  text;
  v_n      integer;
  v_n2     integer;
  v_ok     boolean;
  v_soft   boolean;
  v_json   jsonb;
  v_json2  jsonb;
  v_json3  jsonb;
  v_me     jsonb;
  v_anon   jsonb;
  v_kind   text;
begin
  begin
    v_code := 'zzcli-' || v_tag;
    v_origin := 'https://' || v_code || '.cloveerp.com';
    v_owner := 'owner@' || v_code || '.test';
    v_ops := 'ops@' || v_code || '.test';
    -- A platform owner, bound to a confirmed sign-in, on a client served at
    -- its own address; all undone at the end with everything else.
    insert into auth.users (id, email, email_confirmed_at) values (v_uid, v_owner, now());
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values (v_owner, v_uid, 'Client Business Suite Owner', 'owner')
    returning id into v_staff;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason) values
      ('deployment.kind', '"client"'::jsonb, 'client_keeps_to_its_own_business_suite'),
      ('deployment.app_origin', to_jsonb(v_origin), 'client_keeps_to_its_own_business_suite');

    -- ── 1. The gate stands in every routine of the control plane's business ─
    v_step := 'reading where the gate stands';
    select string_agg(x.name, ', ' order by x.name) into v_bad
      from unnest(c_gated) as x(name)
     where not exists (select 1 from pg_catalog.pg_proc p
                         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                        where n.nspname || '.' || p.proname = x.name)
        or exists (select 1 from pg_catalog.pg_proc p
                     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                    where n.nspname || '.' || p.proname = x.name
                      -- Guarded: the filters above may be applied after this
                      -- one, and an aggregate has no definition to read.
                      and not (coalesce(strpos(case when p.prokind = 'f' then pg_catalog.pg_get_functiondef(p.oid) end,
                                               'perform erp.require_not_client();'), 0) > 0
                               and strpos(p.prosrc, 'erp.require_not_client()')
                                   > greatest(strpos(p.prosrc, 'erp_meta.require_platform('),
                                              strpos(p.prosrc, 'CLOVEERP_NOT_THE_PLATFORM_ORGANISATION'))
                               and (x.name <> 'erp.record_enquiry'
                                    or strpos(p.prosrc, 'erp.require_not_client()')
                                       < strpos(p.prosrc, 'CLOVEERP_ENQUIRY_NAME_REQUIRED'))));
    select string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname), count(*)
      into v_got, v_n
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname || '.' || p.proname = any (c_incidents)
       and strpos(p.prosrc, 'erp.require_not_client()') > 0;
    select count(*) into v_n2
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname || '.' || p.proname = any (c_incidents);
    select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname, p.proname) into v_extra
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_meta', 'public')
       and p.proname <> 'require_not_client'
       and strpos(p.prosrc, 'erp.require_not_client()') > 0
       and not (n.nspname || '.' || p.proname = any (c_gated));
    v_cases := v_cases + 1;
    case_name := 'every routine of selling, contracts, invoices and enquiries asks first whether this is a client, after its rank gate, and no incident door does';
    passed := v_bad is null and v_n = 0 and v_n2 = array_length(c_incidents, 1);
    detail := coalesce('not gated as meant: ' || v_bad || '; ', '')
              || coalesce('incidents gated: ' || v_got || '; ', '')
              || format('%s routine(s) listed, %s incident routine(s) found', array_length(c_gated, 1), v_n2)
              || coalesce('; also gated: ' || v_extra, '');
    return next;

    -- ── 2. A client knows its own code, and the console is told it ─────────
    v_step := 'asking which client this is';
    v_me := public.erp_platform_me();
    perform set_config('request.jwt.claims', '', true);
    v_anon := public.erp_platform_me();
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a client''s deployment knows its own code from the address it is served at, and erp_platform_me says so, signed in or not';
    passed := erp.deployment_code() = v_code
          and v_me ->> 'deployment_code' = v_code and (v_me ->> 'is_staff')::boolean
          and v_anon ->> 'deployment_code' = v_code and v_anon ->> 'deployment' = 'client';
    detail := coalesce(erp.deployment_code(), 'no code') || ' / ' || coalesce(v_me ->> 'deployment_code', 'none signed in')
              || ' / ' || coalesce(v_anon ->> 'deployment_code', 'none signed out');
    return next;

    -- ── 3. Not under another address ────────────────────────────────────────
    -- Whatever organisations this database holds are put out of the way for
    -- the length of the suite: a client starts empty.
    v_step := 'onboarding a client under another address';
    update erp.tenant t set status = 'deleted' where t.status not in ('deleting', 'deleted');
    begin
      perform public.erp_platform_onboard_company('zzoth-' || v_tag, 'Other Address Ltd',
                                                   'admin@zzoth-' || v_tag || '.test', 'Other Admin');
      v_got := 'it was onboarded';
    exception when others then
      v_got := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a client''s deployment makes no organisation under an address that is not its own';
    passed := v_got like 'CLOVEERP_CLIENT_ORGANISATION_CODE%'
          and not exists (select 1 from erp.tenant t where t.code = 'zzoth-' || v_tag);
    detail := left(v_got, 160);
    return next;

    -- ── 4. Its own, once ────────────────────────────────────────────────────
    v_step := 'onboarding a client under its own address';
    v_json := public.erp_platform_onboard_company(v_code, 'Client Business Ltd', 'admin@' || v_code || '.test',
                                                  'Client Admin');
    v_tenant := (v_json ->> 'tenant_id')::uuid;
    begin
      perform public.erp_platform_onboard_company(v_code, 'Client Business Again Ltd',
                                                   'again@' || v_code || '.test', 'Client Admin Again');
      v_got := 'it was onboarded again';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_onboard_tenant('Second Business Ltd', 'zzsec-' || v_tag);
      v_got2 := 'a second was made by the self-service door';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a client''s deployment makes its one organisation under its own address, and refuses a second through either door';
    passed := v_json ->> 'code' = v_code
          and exists (select 1 from erp.tenant t where t.id = v_tenant and t.code = v_code)
          and v_got like 'CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION%'
          and v_got2 like 'CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION%'
          and (select count(*) from erp.tenant t where t.status not in ('deleting', 'deleted')) = 1;
    detail := coalesce(v_json ->> 'code', 'nothing made') || ' / ' || left(v_got, 90) || ' / ' || left(v_got2, 90);
    return next;

    -- ── 5. Sign-up stays closed ─────────────────────────────────────────────
    v_step := 'opening sign-up on a client';
    begin
      perform public.erp_platform_set_self_service_organisations(true,
        'The suite tries to open sign-up on a client, which must refuse.');
      v_got := 'sign-up was opened';
    exception when others then
      v_got := sqlerrm;
    end;
    v_json := public.erp_platform_set_self_service_organisations(false, 'The suite closes sign-up on a client.');
    v_cases := v_cases + 1;
    case_name := 'a client''s deployment never opens the sign-up that lets anybody make an organisation, and may always close it';
    passed := v_got like 'CLOVEERP_CLIENT_HOLDS_ONE_ORGANISATION%'
          and not erp.self_service_organisations_open()
          and v_json ->> 'open' = 'false';
    detail := left(v_got, 140) || ' / closed: ' || coalesce(v_json ->> 'open', 'no answer');
    return next;

    -- ── 6. Every routine of the control plane's business refuses ───────────
    -- Even with a platform organisation already here, as if it had been
    -- designated before the deployment was marked a client.
    v_step := 'asking the control plane''s business of a client';
    -- There is only ever one; whichever this database names is set aside.
    delete from erp_meta.platform_organisation;
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_by, reason)
    values (v_tenant, v_code, v_staff, 'The suite makes the client''s organisation the platform''s, as if it had been.');
    perform set_config('erp.job_tenant_id', v_tenant::text, true);
    select count(*),
           string_agg(a.routine || ': ' || left(a.answer, 70), '; ' order by a.routine)
             filter (where a.answer not like 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a client%')
      into v_n, v_bad
      from erp_test.control_plane_business_answers() a;
    v_cases := v_cases + 1;
    case_name := 'on a client every routine of selling, contracts, invoices and enquiries refuses as the control plane''s, the platform organisation''s own check included';
    passed := v_bad is null and v_n >= array_length(c_gated, 1);
    detail := coalesce('answered otherwise: ' || v_bad, format('%s routine(s) asked, every one refused', v_n));
    return next;

    -- ── 7. Incidents are still a client's own ───────────────────────────────
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

    -- ── 8. Staff are not changed at a client's console ──────────────────────
    v_step := 'changing staff on a client';
    begin
      perform public.erp_platform_add_staff(v_ops, 'Client Ops', 'support');
      v_got := 'added';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform public.erp_platform_set_staff_role(v_staff, 'administrator');
      v_got2 := 're-ranked';
    exception when others then
      v_got2 := sqlerrm;
    end;
    begin
      perform public.erp_platform_revoke_staff(v_staff, 'The suite tries to remove staff on a client.');
      v_got3 := 'removed';
    exception when others then
      v_got3 := sqlerrm;
    end;
    -- The rank gate still comes first.
    update erp_meta.platform_staff set staff_role = 'operator' where id = v_staff;
    begin
      perform public.erp_platform_add_staff(v_ops, 'Client Ops', 'support');
      v_got4 := 'added by an operator';
    exception when others then
      v_got4 := sqlerrm;
    end;
    update erp_meta.platform_staff set staff_role = 'owner' where id = v_staff;
    v_cases := v_cases + 1;
    case_name := 'on a client staff are neither added, re-ranked nor removed at its console, and the rank gate still speaks first';
    passed := v_got like 'CLOVEERP_STAFF_KEPT_ON_THE_CONTROL_PLANE%'
          and v_got2 like 'CLOVEERP_STAFF_KEPT_ON_THE_CONTROL_PLANE%'
          and v_got3 like 'CLOVEERP_STAFF_KEPT_ON_THE_CONTROL_PLANE%'
          and v_got4 like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'
          and not exists (select 1 from erp_meta.platform_staff s where lower(s.email) = v_ops)
          and exists (select 1 from erp_meta.platform_staff s
                       where s.id = v_staff and s.staff_role = 'owner' and s.revoked_at is null);
    detail := left(v_got, 60) || ' / ' || left(v_got2, 60) || ' / ' || left(v_got3, 60) || ' / ' || left(v_got4, 60);
    return next;

    -- ── 9. The control plane's list is kept here, bound ─────────────────────
    v_step := 'keeping a member of staff as the control plane''s list says';
    insert into auth.users (id, email, email_confirmed_at) values (v_uid2, v_ops, now());
    v_json := erp_meta.add_platform_staff_trusted(upper(v_ops), 'Client Ops', 'operator', v_uid2);
    v_json2 := erp_meta.add_platform_staff_trusted(v_ops, 'Client Operations', 'support', v_uid2);
    v_json3 := erp_meta.add_platform_staff_trusted(v_ops, 'Client Operations', 'support', v_uid2);
    begin
      perform erp_meta.add_platform_staff_trusted(v_ops, 'Client Operations', 'king', v_uid2);
      v_got := 'an unknown rank was kept';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.add_platform_staff_trusted('nobody@' || v_code || '.test', 'Nobody', 'support', v_uid2);
      v_got2 := 'a sign-in that is not theirs was bound';
    exception when others then
      v_got2 := sqlerrm;
    end;
    -- Bound, so the person's own sign-in opens the console.
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid2)::text, true);
    begin
      perform public.erp_platform_staff();
      v_got3 := 'read';
    exception when others then
      v_got3 := sqlerrm;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a member of staff is kept on a client from the control plane''s list, bound to their confirmed sign-in, by a routine no signed-in caller reaches';
    passed := v_json ->> 'changed' = 'true' and v_json2 ->> 'changed' = 'true' and v_json3 ->> 'changed' = 'false'
          and (select count(*) from erp_meta.platform_staff s
                where lower(s.email) = v_ops and s.auth_user_id = v_uid2 and s.staff_role = 'support'
                  and s.display_name = 'Client Operations' and s.revoked_at is null) = 1
          and v_got like 'CLOVEERP_UNKNOWN_PLATFORM_ROLE%'
          and v_got2 like 'CLOVEERP_PLATFORM_STAFF_SIGN_IN_UNKNOWN%'
          and v_got3 = 'read'
          and (select count(*) from erp_meta.platform_audit a
                where a.action = 'platform.staff_kept' and a.target = v_ops) = 2
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.add_platform_staff_trusted(text,text,text,uuid)', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.add_platform_staff_trusted(text,text,text,uuid)', 'execute')
          and not pg_catalog.has_function_privilege('anon', 'erp_meta.add_platform_staff_trusted(text,text,text,uuid)', 'execute')
          and not pg_catalog.has_function_privilege('authenticated', 'erp_meta.revoke_platform_staff_trusted(text,text)', 'execute')
          and not pg_catalog.has_function_privilege('service_role', 'erp_meta.revoke_platform_staff_trusted(text,text)', 'execute')
          and not pg_catalog.has_function_privilege('anon', 'erp_meta.revoke_platform_staff_trusted(text,text)', 'execute');
    detail := coalesce(v_json2::text, 'nothing kept') || ' / ' || left(v_got, 50) || ' / ' || left(v_got2, 50)
              || ' / ' || left(v_got3, 50);
    return next;

    -- ── 10. And removed from it, softly, never the last owner ──────────────
    v_step := 'removing a member of staff as the control plane''s list says';
    v_json := erp_meta.revoke_platform_staff_trusted(v_ops, 'No longer on the control plane''s staff list.');
    v_json2 := erp_meta.revoke_platform_staff_trusted(v_ops, null);
    v_soft := exists (select 1 from erp_meta.platform_staff s
                       where lower(s.email) = v_ops and s.revoked_at is not null and s.auth_user_id = v_uid2);
    update erp_meta.platform_staff s
       set revoked_at = now(), revoked_reason = 'Put out of the way by the suite.'
     where s.staff_role = 'owner' and s.revoked_at is null and s.id <> v_staff;
    begin
      perform erp_meta.revoke_platform_staff_trusted(v_owner, 'The suite tries to remove the last owner.');
      v_got := 'the last owner was removed';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.add_platform_staff_trusted(v_owner, 'Client Business Suite Owner', 'operator', v_uid);
      v_got2 := 'the last owner was demoted';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_json3 := erp_meta.add_platform_staff_trusted(v_ops, 'Client Operations', 'support', v_uid2);
    v_cases := v_cases + 1;
    case_name := 'a member of staff the control plane no longer lists is removed softly, never the last owner, and put back as the same person';
    passed := v_json ->> 'revoked' = 'true' and v_json2 ->> 'changed' = 'false' and v_soft
          and v_got like 'CLOVEERP_LAST_OWNER%' and v_got2 like 'CLOVEERP_LAST_OWNER%'
          and v_json3 ->> 'changed' = 'true'
          and exists (select 1 from erp_meta.platform_staff s
                       where lower(s.email) = v_ops and s.revoked_at is null and s.auth_user_id = v_uid2)
          and exists (select 1 from erp_meta.platform_staff s
                       where s.id = v_staff and s.staff_role = 'owner' and s.revoked_at is null)
          and exists (select 1 from erp_meta.platform_audit a
                       where a.action = 'platform.staff_revoked' and a.target = v_ops and a.actor_email = 'system');
    detail := coalesce(v_json::text, 'nothing') || ' / ' || left(v_got, 60) || ' / ' || left(v_got2, 60);
    return next;

    -- ── 11. The demonstration and the control plane are as they were ───────
    v_step := 'asking the same of the demonstration and the control plane';
    v_ok := true;
    v_bad := null;
    foreach v_kind in array array['demonstration', 'production'] loop
      delete from erp_meta.platform_setting where key = 'deployment.kind';
      insert into erp_meta.platform_setting (key, value, reason)
      values ('deployment.kind', to_jsonb(v_kind), 'client_keeps_to_its_own_business_suite');
      select string_agg(a.routine || ': ' || left(a.answer, 60), '; ' order by a.routine) into v_got
        from erp_test.control_plane_business_answers() a
       where a.answer like 'CLOVEERP_NOT_THE_CONTROL_PLANE%';
      v_json := public.erp_platform_add_staff(v_kind || '@' || v_code || '.test', 'Not A Client', 'support');
      v_json2 := public.erp_platform_set_self_service_organisations(true, 'The suite opens sign-up where it may.');
      perform erp.require_client_organisation('zzany-' || v_tag);
      v_me := public.erp_platform_me();
      if v_got is not null
         or (v_json ->> 'role') is distinct from 'support'
         or (v_json2 ->> 'open') is distinct from 'true'
         or erp.deployment_code() is not null
         or not coalesce(v_me ? 'deployment_code', false)
         or (v_me ->> 'deployment_code') is not null then
        v_ok := false;
        v_bad := concat_ws('; ', v_bad, v_kind || ': ' || coalesce(v_got, 'staff ' || coalesce(v_json ->> 'role', 'none')
                 || ', sign-up ' || coalesce(v_json2 ->> 'open', 'none') || ', code ' || coalesce(erp.deployment_code(), 'none')));
      end if;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'on the demonstration and on the control plane nothing of this refuses: the same routines answer as they did, staff are added, sign-up opens, and no client code is told';
    passed := v_ok;
    detail := coalesce(v_bad, 'neither refused anything');
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
    raise exception 'CLOVEERP_CLIENT_BUSINESS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.client_keeps_to_its_own_business_suite() from public, anon;

comment on function erp_test.client_keeps_to_its_own_business_suite() is
  'A client''s own deployment refuses the control plane''s business (selling, contracts, invoices, enquiries) '
  'after each rank gate, keeps its incidents, changes no staff at its console but keeps the control plane''s list '
  'bound through the trusted routines, holds one organisation under its own code, and tells the console that '
  'code; the demonstration and the control plane are as they were (20261011100000).';

create or replace function erp_test.assert_client_keeps_to_its_own_business_suite()
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
    from erp_test.client_keeps_to_its_own_business_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CLIENT_BUSINESS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A client''s deployment does business that is not its own, or refuses its own: read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_CLIENT_BUSINESS_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('client keeps to its own business: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_client_keeps_to_its_own_business_suite() from public, anon;

comment on function erp_test.assert_client_keeps_to_its_own_business_suite() is
  'A client''s own deployment keeps to its own business: the control plane''s refused, staff kept from the control '
  'plane, one organisation under its own code (20261011100000).';

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
