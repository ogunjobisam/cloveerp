-- =============================================================================
-- Owner-to-owner transfer of a company
--
-- Ownership of a company is a platform fact, not a tenant one, so it lives in
-- erp_meta beside the staff list. A transfer is two-sided on purpose: an owner
-- offers, the receiving owner accepts. Nothing is ever overwritten in place --
-- the offer row keeps its whole life, and every step also writes the platform
-- audit trail, so the chain of custody survives the transfer.
-- =============================================================================

create table erp_meta.company_owner (
  tenant_id    uuid primary key,
  staff_id     uuid not null references erp_meta.platform_staff(id),
  since        timestamptz not null default now(),
  assigned_by  uuid references erp_meta.platform_staff(id),
  updated_at   timestamptz not null default now()
);

comment on table erp_meta.company_owner is
  'Which platform owner is accountable for each company. Current state only; '
  'the history of how it got there is in erp_meta.ownership_transfer and the '
  'platform audit trail.';

alter table erp_meta.company_owner enable row level security;

create table erp_meta.ownership_transfer (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  from_staff_id  uuid not null references erp_meta.platform_staff(id),
  to_staff_id    uuid not null references erp_meta.platform_staff(id),
  status         text not null default 'pending'
                 check (status in ('pending','accepted','declined','cancelled','expired')),
  reason         text,
  response_note  text,
  expires_at     timestamptz not null default now() + interval '7 days',
  created_at     timestamptz not null default now(),
  settled_at     timestamptz,
  settled_by     uuid references erp_meta.platform_staff(id)
);

comment on table erp_meta.ownership_transfer is
  'Every ownership offer ever made, in whatever state it ended. Rows are never '
  'deleted: a declined or cancelled offer is part of the record.';

create unique index ownership_transfer_one_open
  on erp_meta.ownership_transfer (tenant_id) where status = 'pending';
create index on erp_meta.ownership_transfer (to_staff_id, status);

alter table erp_meta.ownership_transfer enable row level security;

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_meta', 'company_owner', 'platform_internal',
   'Names a platform staff member, not a tenant principal; reachable only through definer functions.'),
  ('erp_meta', 'ownership_transfer', 'platform_internal',
   'Offers between platform staff; spans the platform rather than any one tenant.')
on conflict do nothing;

insert into erp_meta.attribution_exemption (schema_name, table_name, rationale) values
  ('erp_meta', 'company_owner',
   'Carries assigned_by; principal attribution is tenant-scoped and this row is not.'),
  ('erp_meta', 'ownership_transfer',
   'Carries from/to/settled_by staff columns; the actors are platform staff, not tenant principals.')
on conflict do nothing;

-- Existing companies belong to the earliest platform owner, so nothing is
-- ownerless the moment this ships.
insert into erp_meta.company_owner (tenant_id, staff_id, assigned_by)
select t.id, s.id, s.id
  from erp.tenant t
  cross join lateral (
    select ps.id from erp_meta.platform_staff ps
     where ps.staff_role = 'owner' and ps.revoked_at is null
     order by ps.created_at limit 1) s
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Expiry: an offer nobody answered is not an open offer forever.
-- -----------------------------------------------------------------------------

create or replace function erp_meta.expire_ownership_offers()
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  update erp_meta.ownership_transfer
     set status = 'expired', settled_at = now()
   where status = 'pending' and expires_at <= now()
$$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp_meta', 'expire_ownership_offers',
   'Lapses stale platform ownership offers. The table belongs to no tenant.')
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- The public API
-- -----------------------------------------------------------------------------

create or replace function public.erp_platform_offer_ownership(
  p_tenant_id uuid, p_to_staff_id uuid, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  v_to    erp_meta.platform_staff;
  v_t     erp.tenant;
  v_owner uuid;
  v_id    uuid;
begin
  v := erp_meta.require_platform('owner');
  perform erp_meta.expire_ownership_offers();

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  select * into v_to from erp_meta.platform_staff where id = p_to_staff_id;
  if v_to.id is null or v_to.revoked_at is not null then
    raise exception 'ERPWARE_UNKNOWN_STAFF: that person is not active platform staff'
      using errcode = '23503';
  end if;
  if v_to.staff_role <> 'owner' then
    raise exception
      'ERPWARE_NOT_AN_OWNER: a company can only be handed to another platform owner; % holds %',
      v_to.email, v_to.staff_role
      using errcode = '42501',
      hint = 'Raise them to owner in Platform, Staff first.';
  end if;
  if v_to.id = v.id then
    raise exception 'ERPWARE_SELF_TRANSFER: you already hold this company'
      using errcode = '22023';
  end if;

  select co.staff_id into v_owner from erp_meta.company_owner co where co.tenant_id = p_tenant_id;

  -- The holder offers. An owner with no holder on record may claim the handover
  -- of an unowned company, which is how legacy rows get an accountable name.
  if v_owner is not null and v_owner <> v.id then
    raise exception
      'ERPWARE_NOT_THE_HOLDER: only the owner who holds this company may transfer it'
      using errcode = '42501';
  end if;

  insert into erp_meta.ownership_transfer (tenant_id, from_staff_id, to_staff_id, reason)
  values (p_tenant_id, coalesce(v_owner, v.id), p_to_staff_id, p_reason)
  returning id into v_id;

  perform erp_meta.platform_log(v, 'platform.ownership_offered', p_tenant_id, v_to.email, p_reason,
    jsonb_build_object('transfer_id', v_id, 'from', v.email, 'to', v_to.email));

  return jsonb_build_object('transfer_id', v_id, 'status', 'pending', 'to_email', v_to.email);
end;
$$;

create or replace function public.erp_platform_cancel_ownership_transfer(
  p_transfer_id uuid, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v  erp_meta.platform_staff;
  tr erp_meta.ownership_transfer;
begin
  v := erp_meta.require_platform('owner');

  select * into tr from erp_meta.ownership_transfer where id = p_transfer_id;
  if tr.id is null then
    raise exception 'ERPWARE_UNKNOWN_TRANSFER' using errcode = '23503';
  end if;
  if tr.status <> 'pending' then
    raise exception 'ERPWARE_TRANSFER_SETTLED: this offer is already %', tr.status
      using errcode = '22023';
  end if;
  if tr.from_staff_id <> v.id then
    raise exception 'ERPWARE_NOT_THE_OFFERER: only the owner who made the offer may withdraw it'
      using errcode = '42501';
  end if;

  update erp_meta.ownership_transfer
     set status = 'cancelled', settled_at = now(), settled_by = v.id, response_note = p_reason
   where id = p_transfer_id;

  perform erp_meta.platform_log(v, 'platform.ownership_cancelled', tr.tenant_id, null, p_reason,
    jsonb_build_object('transfer_id', p_transfer_id));

  return jsonb_build_object('transfer_id', p_transfer_id, 'status', 'cancelled');
end;
$$;

create or replace function public.erp_platform_respond_ownership_transfer(
  p_transfer_id uuid, p_accept boolean, p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v       erp_meta.platform_staff;
  tr      erp_meta.ownership_transfer;
  v_from  erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('owner');
  perform erp_meta.expire_ownership_offers();

  select * into tr from erp_meta.ownership_transfer where id = p_transfer_id;
  if tr.id is null then
    raise exception 'ERPWARE_UNKNOWN_TRANSFER' using errcode = '23503';
  end if;
  if tr.status <> 'pending' then
    raise exception 'ERPWARE_TRANSFER_SETTLED: this offer is already %', tr.status
      using errcode = '22023';
  end if;
  if tr.to_staff_id <> v.id then
    raise exception 'ERPWARE_NOT_THE_RECIPIENT: only the owner the company was offered to may answer'
      using errcode = '42501';
  end if;

  select * into v_from from erp_meta.platform_staff where id = tr.from_staff_id;

  update erp_meta.ownership_transfer
     set status = case when p_accept then 'accepted' else 'declined' end,
         settled_at = now(), settled_by = v.id, response_note = p_note
   where id = p_transfer_id;

  if p_accept then
    insert into erp_meta.company_owner (tenant_id, staff_id, assigned_by)
    values (tr.tenant_id, v.id, tr.from_staff_id)
    on conflict (tenant_id) do update
      set staff_id = excluded.staff_id, assigned_by = excluded.assigned_by,
          since = now(), updated_at = now();
  end if;

  perform erp_meta.platform_log(v,
    case when p_accept then 'platform.ownership_accepted' else 'platform.ownership_declined' end,
    tr.tenant_id, v_from.email, p_note,
    jsonb_build_object('transfer_id', p_transfer_id, 'from', v_from.email, 'to', v.email));

  return jsonb_build_object('transfer_id', p_transfer_id,
                            'status', case when p_accept then 'accepted' else 'declined' end);
end;
$$;

create or replace function public.erp_platform_ownership_transfers(
  p_tenant_id uuid default null, p_limit integer default 200)
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
  perform erp_meta.expire_ownership_offers();

  return coalesce((
    select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object(
        'id', tr.id, 'tenant_id', tr.tenant_id,
        'tenant_code', t.code, 'tenant_name', t.name,
        'from_email', f.email, 'from_name', f.display_name,
        'to_email', g.email, 'to_name', g.display_name,
        'to_staff_id', tr.to_staff_id, 'from_staff_id', tr.from_staff_id,
        'status', tr.status, 'reason', tr.reason, 'response_note', tr.response_note,
        'expires_at', tr.expires_at, 'created_at', tr.created_at,
        'settled_at', tr.settled_at,
        'is_mine_to_answer', (tr.status = 'pending' and tr.to_staff_id = v.id),
        'is_mine_to_withdraw', (tr.status = 'pending' and tr.from_staff_id = v.id)) as x
        from erp_meta.ownership_transfer tr
        left join erp.tenant t on t.id = tr.tenant_id
        left join erp_meta.platform_staff f on f.id = tr.from_staff_id
        left join erp_meta.platform_staff g on g.id = tr.to_staff_id
       where (p_tenant_id is null or tr.tenant_id = p_tenant_id)
       order by tr.created_at desc
       limit greatest(1, least(coalesce(p_limit, 200), 1000))) s), '[]'::jsonb);
end;
$$;

-- The company list gains the one fact the console now needs: who holds it.
create or replace function public.erp_platform_tenants()
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
  perform erp_meta.expire_ownership_offers();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'code', t.code, 'name', t.name,
             'status', t.status::text,
             'created_at', t.created_at,
             'provisioned_at', t.provisioned_at,
             'suspended_at', t.suspended_at,
             'owner_staff_id', co.staff_id,
             'owner_email', os.email,
             'owner_name', os.display_name,
             'owned_by_me', co.staff_id = v.id,
             'owner_since', co.since,
             'pending_transfer_to', (select g.email
                                       from erp_meta.ownership_transfer tr
                                       join erp_meta.platform_staff g on g.id = tr.to_staff_id
                                      where tr.tenant_id = t.id and tr.status = 'pending'
                                      limit 1),
             'principals', (select count(*) from erp.app_user u where u.tenant_id = t.id),
             'entities', (select count(*) from erp.entity e where e.tenant_id = t.id),
             'sites', (select count(*) from erp.site s where s.tenant_id = t.id),
             'open_invitations', (select count(*) from erp.invitation i
                                   where i.tenant_id = t.id
                                     and i.claimed_at is null and i.revoked_at is null
                                     and i.expires_at > now()))
             order by t.created_at desc)
      from erp.tenant t
      left join erp_meta.company_owner co on co.tenant_id = t.id
      left join erp_meta.platform_staff os on os.id = co.staff_id), '[]'::jsonb);
end;
$$;

-- A company onboarded by an owner is held by that owner from the outset.
create or replace function public.erp_platform_onboard_company(
  p_code               text,
  p_name               text,
  p_admin_email        text,
  p_admin_display_name text,
  p_base_currency      char(3) default 'GBP',
  p_country_code       char(2) default 'GB',
  p_timezone           text default 'UTC'
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v erp_meta.platform_staff;
  r record;
begin
  v := erp_meta.require_platform('operator');

  select * into r from erp.provision_tenant(
    lower(trim(p_code)), p_name, lower(trim(p_admin_email)), p_admin_display_name,
    p_base_currency, p_country_code, 'MAIN', p_timezone, interval '14 days');

  insert into erp_meta.company_owner (tenant_id, staff_id, assigned_by)
  select r.tenant_id,
         case when v.staff_role = 'owner' then v.id
              else (select ps.id from erp_meta.platform_staff ps
                     where ps.staff_role = 'owner' and ps.revoked_at is null
                     order by ps.created_at limit 1) end,
         v.id
  on conflict (tenant_id) do nothing;

  perform erp_meta.platform_log(v, 'platform.company_onboarded', r.tenant_id,
                                p_admin_email, null,
                                jsonb_build_object('code', lower(trim(p_code)), 'name', p_name));

  return jsonb_build_object(
    'tenant_id', r.tenant_id, 'code', lower(trim(p_code)), 'name', p_name,
    'admin_user_id', r.admin_user_id, 'admin_email', lower(trim(p_admin_email)),
    'admin_token', r.admin_token);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_platform_offer_ownership(uuid, uuid, text)',
    'public.erp_platform_cancel_ownership_transfer(uuid, text)',
    'public.erp_platform_respond_ownership_transfer(uuid, boolean, text)',
    'public.erp_platform_ownership_transfers(uuid, integer)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
select 'public', fn,
       'Platform-level operation above every tenant, gated on '
       'erp_meta.require_platform() and audited in erp_meta.platform_audit.'
  from unnest(array[
    'erp_platform_offer_ownership','erp_platform_cancel_ownership_transfer',
    'erp_platform_respond_ownership_transfer','erp_platform_ownership_transfers']) fn
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
select fn, 'erp_meta.require_platform',
       'Platform staff action, gated on the platform staff list rather than on '
       'erp.authorise(), because it is performed above every tenant.'
  from unnest(array[
    'erp_platform_offer_ownership','erp_platform_cancel_ownership_transfer',
    'erp_platform_respond_ownership_transfer','erp_platform_ownership_transfers']) fn
on conflict do nothing;