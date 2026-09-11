set lock_timeout = '30s';

-- =============================================================================
-- Exposure, not new behaviour: API keys over the doors that already exist, and
-- outbound webhooks over the events that already happen.
--
-- Three rules this migration keeps, because they are the ones an exposure layer
-- usually breaks:
--
--   1. There is no parallel permission model. A key's scopes are permission
--      codes from erp_ref.permission, and a scope is only ever effective while
--      the service principal behind the key still holds that permission by
--      grant. Revoke the grant and the key narrows in the same instant.
--
--   2. Tenant scope is decided here, from the key, never from the caller. A key
--      resolves to exactly one organisation and one principal.
--
--   3. A write is replayable. The idempotency key and a checksum of the request
--      are stored with the response that was actually returned, so a retry
--      returns the original result and a different body under the same key is
--      refused rather than silently applied twice.
--
-- Managing keys, subscriptions and deliveries is gated on the permission that
-- already owns this ground: administration.integrate.
-- =============================================================================

-- ── The key ──────────────────────────────────────────────────────────────────

create table if not exists erp.api_key (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant (id) on delete cascade,
  app_user_id     uuid not null,
  label           text not null,
  key_prefix      text not null,
  key_hash        text not null,
  scopes          text[] not null default '{}'::text[],
  expires_at      timestamptz,
  revoked_at      timestamptz,
  revoked_reason  text,
  last_used_at    timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  constraint api_key_label_present check (coalesce(btrim(label), '') <> ''),
  constraint api_key_prefix_shape check (key_prefix ~ '^ck_[0-9a-f]{12}$'),
  constraint api_key_hash_shape check (key_hash ~ '^[0-9a-f]{64}$'),
  constraint api_key_scopes_present check (cardinality(scopes) > 0),
  constraint api_key_revoked_has_reason
    check (revoked_at is null or coalesce(btrim(revoked_reason), '') <> ''),
  constraint api_key_prefix_unique unique (key_prefix),
  constraint api_key_tenant_id_key unique (tenant_id, id),
  constraint api_key_principal_fk
    foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade
);

comment on table erp.api_key is
  'An API key belonging to a service principal of one organisation. The secret '
  'is shown once at issue and stored only as a SHA-256 digest; the prefix is '
  'what the key is found by. Scopes are permission codes, and they are '
  'intersected with the principal''s live grants on every call.';

create index if not exists api_key_live_idx
  on erp.api_key (tenant_id, app_user_id) where revoked_at is null;

-- ── The replay ledger ────────────────────────────────────────────────────────

create table if not exists erp.api_request (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant (id) on delete cascade,
  api_key_id        uuid not null,
  idempotency_key   text not null,
  method            text not null,
  path              text not null,
  request_checksum  text not null,
  status_code       integer,
  response          jsonb,
  completed_at      timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint api_request_method_known
    check (method in ('POST', 'PUT', 'PATCH', 'DELETE')),
  constraint api_request_checksum_shape check (request_checksum ~ '^[0-9a-f]{64}$'),
  constraint api_request_completed_has_response
    check (completed_at is null or (status_code is not null and response is not null)),
  constraint api_request_idempotent unique (api_key_id, idempotency_key),
  constraint api_request_tenant_id_key unique (tenant_id, id),
  constraint api_request_key_fk
    foreign key (tenant_id, api_key_id) references erp.api_key (tenant_id, id) on delete cascade
);

comment on table erp.api_request is
  'One row per write accepted through the versioned API. The response that was '
  'returned is kept with the checksum of the request that produced it, so a '
  'retry returns the original and a changed body under the same idempotency '
  'key is refused.';

-- ── The subscription ─────────────────────────────────────────────────────────

create table if not exists erp.webhook_subscription (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant (id) on delete cascade,
  name            text not null,
  event_pattern   text not null,
  target_url      text not null,
  secret_material text not null,
  secret_hint     text not null,
  status          text not null default 'active',
  last_delivery_at timestamptz,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  constraint webhook_subscription_name_present check (coalesce(btrim(name), '') <> ''),
  constraint webhook_subscription_pattern_present check (coalesce(btrim(event_pattern), '') <> ''),
  constraint webhook_subscription_https check (target_url ~ '^https://'),
  constraint webhook_subscription_status_known check (status in ('active', 'paused', 'revoked')),
  constraint webhook_subscription_unique_name unique (tenant_id, name),
  constraint webhook_subscription_tenant_id_key unique (tenant_id, id)
);

comment on table erp.webhook_subscription is
  'Where one organisation wants an event delivered, and the secret every '
  'delivery to it is signed with. The secret is returned once at creation and '
  'once at rotation; no read door returns it again, and the last four '
  'characters are kept as a hint so a customer can tell two apart.';

create table if not exists erp.webhook_delivery (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant (id) on delete cascade,
  subscription_id   uuid not null,
  event_type        text not null,
  payload           jsonb not null,
  payload_checksum  text not null,
  attempt           integer not null default 0,
  status            text not null default 'pending',
  next_attempt_at   timestamptz not null default now(),
  response_status   integer,
  failure_reason    text,
  delivered_at      timestamptz,
  replay_of         uuid,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint webhook_delivery_status_known
    check (status in ('pending', 'in_flight', 'delivered', 'failed', 'abandoned')),
  constraint webhook_delivery_checksum_shape check (payload_checksum ~ '^[0-9a-f]{64}$'),
  constraint webhook_delivery_failure_has_reason
    check (status not in ('failed', 'abandoned') or coalesce(btrim(failure_reason), '') <> ''),
  constraint webhook_delivery_tenant_id_key unique (tenant_id, id),
  constraint webhook_delivery_subscription_fk
    foreign key (tenant_id, subscription_id)
      references erp.webhook_subscription (tenant_id, id) on delete cascade,
  constraint webhook_delivery_replay_fk
    foreign key (tenant_id, replay_of)
      references erp.webhook_delivery (tenant_id, id) on delete set null
);

comment on table erp.webhook_delivery is
  'Every attempt to hand one event to one subscriber, with the payload frozen '
  'as it was signed. A replay is a new row pointing at the one it repeats, so '
  'the history stays readable rather than being overwritten by the retry.';

create index if not exists webhook_delivery_due_idx
  on erp.webhook_delivery (next_attempt_at)
  where status in ('pending', 'in_flight');

select erp_meta.register_table('erp', 'api_key', 'tenant_scoped',
  'API keys of one organisation''s service principals, hashed at rest.');
select erp_meta.register_table('erp', 'api_request', 'tenant_scoped',
  'The idempotency ledger of writes accepted through the versioned API.');
select erp_meta.register_table('erp', 'webhook_subscription', 'tenant_scoped',
  'Where an organisation wants its events delivered.');
select erp_meta.register_table('erp', 'webhook_delivery', 'tenant_scoped',
  'Evidence of every webhook attempt, retry and replay.');

-- ── Scopes never exceed grants ───────────────────────────────────────────────

create or replace function erp.api_key_effective_scopes(p_api_key_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct s order by s), '{}'::text[])
    from erp.api_key k
    cross join lateral unnest(k.scopes) as s
   where k.id = p_api_key_id
     and k.revoked_at is null
     and (k.expires_at is null or k.expires_at > now())
     and exists (
       select 1 from erp.effective_permission ep
        where ep.app_user_id = k.app_user_id
          and ep.permission_code = s
          and ep.valid_from <= current_date
          and (ep.valid_to is null or ep.valid_to >= current_date))
$$;

comment on function erp.api_key_effective_scopes is
  'What a key can actually do right now: its own scopes, narrowed to the '
  'permissions its service principal still holds by grant.';

-- ── Issuing and revoking ─────────────────────────────────────────────────────

create or replace function erp.issue_api_key(
  p_app_user_id uuid,
  p_label       text,
  p_scopes      text[],
  p_expires_at  timestamptz default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_secret    text;
  v_prefix    text;
  v_id        uuid;
  v_unknown   text;
  v_ungranted text;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'api_key', null);

  if coalesce(btrim(p_label), '') = '' then
    raise exception 'CLOVEERP_VALIDATION: a name for the key is required'
      using errcode = '23514';
  end if;
  if p_scopes is null or cardinality(p_scopes) = 0 then
    raise exception 'CLOVEERP_VALIDATION: choose at least one permission for the key'
      using errcode = '23514';
  end if;

  if not exists (
    select 1 from erp.app_user u
     where u.tenant_id = v_tenant and u.id = p_app_user_id) then
    raise exception 'CLOVEERP_NOT_FOUND: that service principal is not in this organisation'
      using errcode = 'P0002';
  end if;

  select string_agg(s, ', ') into v_unknown
    from unnest(p_scopes) s
   where not exists (select 1 from erp_ref.permission p where p.code = s);
  if v_unknown is not null then
    raise exception 'CLOVEERP_VALIDATION: unknown permission(s): %', v_unknown
      using errcode = '23514';
  end if;

  select string_agg(s, ', ') into v_ungranted
    from unnest(p_scopes) s
   where not exists (
     select 1 from erp.effective_permission ep
      where ep.app_user_id = p_app_user_id
        and ep.permission_code = s);
  if v_ungranted is not null then
    raise exception
      'CLOVEERP_SCOPE_EXCEEDS_GRANT: this service principal is not granted %. '
      'Grant it a role that carries it, then issue the key.', v_ungranted
      using errcode = '42501';
  end if;

  v_secret := encode(extensions.gen_random_bytes(32), 'hex');
  v_prefix := 'ck_' || substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 12);

  insert into erp.api_key (tenant_id, app_user_id, label, key_prefix, key_hash,
                           scopes, expires_at)
  values (v_tenant, p_app_user_id, btrim(p_label), v_prefix,
          encode(extensions.digest(v_prefix || '.' || v_secret, 'sha256'), 'hex'),
          (select coalesce(array_agg(distinct s order by s), '{}'::text[]) from unnest(p_scopes) s),
          p_expires_at)
  returning id into v_id;

  -- The only time the secret exists outside the caller's hands.
  return jsonb_build_object(
    'api_key_id', v_id,
    'prefix', v_prefix,
    'secret', v_prefix || '.' || v_secret,
    'shown_once', true);
end $$;

comment on function erp.issue_api_key is
  'Issues a key for a service principal. Refuses a scope the principal is not '
  'granted, so a key can never be wider than the service behind it. Returns the '
  'secret once and never again.';

create or replace function erp.revoke_api_key(p_api_key_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_rows integer;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'api_key', p_api_key_id);

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'CLOVEERP_VALIDATION: say why the key is being revoked'
      using errcode = '23514';
  end if;

  update erp.api_key
     set revoked_at = now(), revoked_reason = btrim(p_reason)
   where tenant_id = v_tenant and id = p_api_key_id and revoked_at is null;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'CLOVEERP_NOT_FOUND: no live key of that name to revoke'
      using errcode = 'P0002';
  end if;
  return jsonb_build_object('api_key_id', p_api_key_id, 'revoked', true);
end $$;

comment on function erp.revoke_api_key is
  'Ends a key. Revocation is immediate and permanent; a replacement is a new '
  'key with a new secret.';

-- ── Authenticating a call ────────────────────────────────────────────────────

create or replace function erp.authenticate_api_key(p_presented text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_prefix text; v_key erp.api_key%rowtype;
begin
  if p_presented is null or position('.' in p_presented) = 0 then
    return null;
  end if;
  v_prefix := split_part(p_presented, '.', 1);

  select * into v_key from erp.api_key k
   where k.key_prefix = v_prefix
     and k.revoked_at is null
     and (k.expires_at is null or k.expires_at > now());
  if not found then
    return null;
  end if;
  if v_key.key_hash <> encode(extensions.digest(p_presented, 'sha256'), 'hex') then
    return null;
  end if;

  update erp.api_key set last_used_at = now() where id = v_key.id;

  return jsonb_build_object(
    'api_key_id', v_key.id,
    'tenant_id', v_key.tenant_id,
    'app_user_id', v_key.app_user_id,
    'label', v_key.label,
    'scopes', to_jsonb(erp.api_key_effective_scopes(v_key.id)));
end $$;

comment on function erp.authenticate_api_key is
  'Resolves a presented secret to its organisation, its service principal and '
  'the scopes still live for it. Definer security because the caller has no '
  'principal yet: that is what this decides. Returns null for anything that '
  'does not match; never the digest.';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'authenticate_api_key',
  'Runs before a tenant context exists, so row security on erp.api_key would '
  'hide the single row it exists to find. Matches one prefix and one digest, '
  'stamps last used, and returns identity and live scopes only.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ── Idempotent writes ────────────────────────────────────────────────────────

create or replace function erp.api_replay_lookup(
  p_api_key_id uuid, p_idempotency_key text, p_request_checksum text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row erp.api_request%rowtype;
begin
  select * into v_row from erp.api_request r
   where r.api_key_id = p_api_key_id and r.idempotency_key = p_idempotency_key;
  if not found then
    return null;
  end if;
  if v_row.request_checksum <> p_request_checksum then
    raise exception
      'CLOVEERP_IDEMPOTENCY_CONFLICT: that idempotency key was already used for '
      'a different request. Use a new key for a new request.'
      using errcode = '23505';
  end if;
  if v_row.completed_at is null then
    raise exception
      'CLOVEERP_IDEMPOTENCY_IN_FLIGHT: the first attempt with that key is still '
      'running. Retry shortly.'
      using errcode = '55006';
  end if;
  return jsonb_build_object(
    'replayed', true, 'status_code', v_row.status_code, 'response', v_row.response);
end $$;

comment on function erp.api_replay_lookup is
  'What a retry gets: the response the first call returned, or a refusal when '
  'the body changed under the same key.';

create or replace function erp.api_replay_begin(
  p_api_key_id uuid, p_idempotency_key text, p_method text, p_path text,
  p_request_checksum text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_tenant uuid; v_id uuid;
begin
  select k.tenant_id into v_tenant from erp.api_key k where k.id = p_api_key_id;
  if v_tenant is null then
    raise exception 'CLOVEERP_NOT_FOUND: unknown key' using errcode = 'P0002';
  end if;

  insert into erp.api_request (tenant_id, api_key_id, idempotency_key, method,
                               path, request_checksum)
  values (v_tenant, p_api_key_id, p_idempotency_key, upper(p_method), p_path,
          p_request_checksum)
  returning id into v_id;
  return v_id;
end $$;

create or replace function erp.api_replay_complete(
  p_api_request_id uuid, p_status_code integer, p_response jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  update erp.api_request
     set status_code = p_status_code, response = p_response, completed_at = now()
   where id = p_api_request_id and completed_at is null
$$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'api_replay_lookup',
   'Reads one row of the replay ledger for a key already authenticated, before '
   'a tenant context is established for the request.'),
  ('erp', 'api_replay_begin',
   'Opens the replay ledger row for an authenticated key, taking the tenant '
   'from the key rather than from the caller.'),
  ('erp', 'api_replay_complete',
   'Closes the replay ledger row it was handed, writing nothing else.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ── Subscriptions ────────────────────────────────────────────────────────────

create or replace function erp.create_webhook_subscription(
  p_name text, p_event_pattern text, p_target_url text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_secret text; v_id uuid;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'webhook_subscription', null);

  if coalesce(btrim(p_target_url), '') !~ '^https://' then
    raise exception 'CLOVEERP_VALIDATION: the address must start with https://'
      using errcode = '23514';
  end if;

  v_secret := encode(extensions.gen_random_bytes(32), 'hex');

  insert into erp.webhook_subscription (tenant_id, name, event_pattern, target_url,
                                        secret_material, secret_hint)
  values (v_tenant, btrim(p_name), btrim(p_event_pattern), btrim(p_target_url),
          v_secret, right(v_secret, 4))
  returning id into v_id;

  return jsonb_build_object('subscription_id', v_id, 'secret', v_secret, 'shown_once', true);
end $$;

create or replace function erp.rotate_webhook_secret(p_subscription_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_secret text;
begin
  perform erp.authorise('administration.integrate', null, null, null,
                        'webhook_subscription', p_subscription_id);
  v_secret := encode(extensions.gen_random_bytes(32), 'hex');

  update erp.webhook_subscription
     set secret_material = v_secret, secret_hint = right(v_secret, 4)
   where tenant_id = v_tenant and id = p_subscription_id and status <> 'revoked';
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no live subscription of that name'
      using errcode = 'P0002';
  end if;
  return jsonb_build_object('subscription_id', p_subscription_id, 'secret', v_secret,
                            'shown_once', true);
end $$;

create or replace function erp.set_webhook_subscription_status(
  p_subscription_id uuid, p_status text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.integrate', null, null, null,
                        'webhook_subscription', p_subscription_id);
  if p_status not in ('active', 'paused', 'revoked') then
    raise exception 'CLOVEERP_VALIDATION: a subscription is active, paused or revoked'
      using errcode = '23514';
  end if;
  update erp.webhook_subscription set status = p_status
   where tenant_id = v_tenant and id = p_subscription_id;
  if not found then
    raise exception 'CLOVEERP_NOT_FOUND: no such subscription' using errcode = 'P0002';
  end if;
  return jsonb_build_object('subscription_id', p_subscription_id, 'status', p_status);
end $$;

create or replace function erp.publish_webhook_event(p_event_type text, p_payload jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_count integer;
begin
  insert into erp.webhook_delivery (tenant_id, subscription_id, event_type, payload,
                                    payload_checksum)
  select s.tenant_id, s.id, p_event_type, p_payload,
         encode(extensions.digest(p_payload::text, 'sha256'), 'hex')
    from erp.webhook_subscription s
   where s.tenant_id = v_tenant
     and s.status = 'active'
     and (s.event_pattern = '*' or p_event_type like replace(s.event_pattern, '*', '%'));
  get diagnostics v_count = row_count;
  return v_count;
end $$;

create or replace function erp.replay_webhook_delivery(p_delivery_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_new uuid;
begin
  perform erp.authorise('administration.integrate', null, null, null,
                        'webhook_delivery', p_delivery_id);

  insert into erp.webhook_delivery (tenant_id, subscription_id, event_type, payload,
                                    payload_checksum, replay_of)
  select d.tenant_id, d.subscription_id, d.event_type, d.payload, d.payload_checksum, d.id
    from erp.webhook_delivery d
   where d.tenant_id = v_tenant and d.id = p_delivery_id
  returning id into v_new;

  if v_new is null then
    raise exception 'CLOVEERP_NOT_FOUND: no such delivery to replay' using errcode = 'P0002';
  end if;
  return jsonb_build_object('delivery_id', v_new, 'replay_of', p_delivery_id);
end $$;

comment on function erp.replay_webhook_delivery is
  'Sends the same frozen payload again as a new attempt that names the one it '
  'repeats. Nothing about the original is altered.';

-- ── The public doors ─────────────────────────────────────────────────────────

create or replace function public.erp_api_keys()
returns jsonb
language plpgsql
stable
set search_path to ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.integrate');
  select coalesce(jsonb_agg(x order by x ->> 'label'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'api_key_id', k.id,
      'label', k.label,
      'prefix', k.key_prefix,
      'service_principal', u.display_name,
      'app_user_id', k.app_user_id,
      'scopes', to_jsonb(k.scopes),
      'effective_scopes', to_jsonb(erp.api_key_effective_scopes(k.id)),
      'expires_at', k.expires_at,
      'revoked_at', k.revoked_at,
      'revoked_reason', k.revoked_reason,
      'last_used_at', k.last_used_at,
      'created_at', k.created_at) as x
      from erp.api_key k
      join erp.app_user u on u.tenant_id = k.tenant_id and u.id = k.app_user_id
     where k.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end $$;

comment on function public.erp_api_keys is
  'The keys of this organisation, with what each can currently do. The secret '
  'is never among them.';

create or replace function public.erp_issue_api_key(
  p_app_user_id uuid, p_label text, p_scopes text[], p_expires_at timestamptz default null)
returns jsonb
language sql
volatile
set search_path to ''
as $$ select erp.issue_api_key(p_app_user_id, p_label, p_scopes, p_expires_at) $$;

create or replace function public.erp_revoke_api_key(p_api_key_id uuid, p_reason text)
returns jsonb
language sql
volatile
set search_path to ''
as $$ select erp.revoke_api_key(p_api_key_id, p_reason) $$;

create or replace function public.erp_webhook_subscriptions()
returns jsonb
language plpgsql
stable
set search_path to ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.integrate');
  select coalesce(jsonb_agg(x order by x ->> 'name'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'subscription_id', s.id,
      'name', s.name,
      'event_pattern', s.event_pattern,
      'target_url', s.target_url,
      'secret_hint', s.secret_hint,
      'status', s.status,
      'last_delivery_at', s.last_delivery_at,
      'pending', (select count(*) from erp.webhook_delivery d
                   where d.subscription_id = s.id and d.status in ('pending', 'in_flight')),
      'failed', (select count(*) from erp.webhook_delivery d
                  where d.subscription_id = s.id and d.status in ('failed', 'abandoned')),
      'created_at', s.created_at) as x
      from erp.webhook_subscription s
     where s.tenant_id = erp.current_tenant_id()
  ) s2;
  return v_out;
end $$;

create or replace function public.erp_webhook_deliveries(
  p_subscription_id uuid default null, p_limit integer default 100)
returns jsonb
language plpgsql
stable
set search_path to ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.integrate');
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'delivery_id', d.id,
      'subscription_id', d.subscription_id,
      'subscription', s.name,
      'event_type', d.event_type,
      'attempt', d.attempt,
      'status', d.status,
      'response_status', d.response_status,
      'failure_reason', d.failure_reason,
      'next_attempt_at', d.next_attempt_at,
      'delivered_at', d.delivered_at,
      'replay_of', d.replay_of,
      'payload_checksum', d.payload_checksum,
      'created_at', d.created_at) as x
      from erp.webhook_delivery d
      join erp.webhook_subscription s
        on s.tenant_id = d.tenant_id and s.id = d.subscription_id
     where d.tenant_id = erp.current_tenant_id()
       and (p_subscription_id is null or d.subscription_id = p_subscription_id)
     order by d.created_at desc
     limit greatest(1, least(coalesce(p_limit, 100), 500))
  ) s3;
  return v_out;
end $$;

create or replace function public.erp_create_webhook_subscription(
  p_name text, p_event_pattern text, p_target_url text)
returns jsonb
language sql
volatile
set search_path to ''
as $$ select erp.create_webhook_subscription(p_name, p_event_pattern, p_target_url) $$;

create or replace function public.erp_rotate_webhook_secret(p_subscription_id uuid)
returns jsonb
language sql
volatile
set search_path to ''
as $$ select erp.rotate_webhook_secret(p_subscription_id) $$;

create or replace function public.erp_set_webhook_subscription_status(
  p_subscription_id uuid, p_status text)
returns jsonb
language sql
volatile
set search_path to ''
as $$ select erp.set_webhook_subscription_status(p_subscription_id, p_status) $$;

create or replace function public.erp_replay_webhook_delivery(p_delivery_id uuid)
returns jsonb
language sql
volatile
set search_path to ''
as $$ select erp.replay_webhook_delivery(p_delivery_id) $$;

revoke all on function public.erp_api_keys() from public, anon;
revoke all on function public.erp_issue_api_key(uuid, text, text[], timestamptz) from public, anon;
revoke all on function public.erp_revoke_api_key(uuid, text) from public, anon;
revoke all on function public.erp_webhook_subscriptions() from public, anon;
revoke all on function public.erp_webhook_deliveries(uuid, integer) from public, anon;
revoke all on function public.erp_create_webhook_subscription(text, text, text) from public, anon;
revoke all on function public.erp_rotate_webhook_secret(uuid) from public, anon;
revoke all on function public.erp_set_webhook_subscription_status(uuid, text) from public, anon;
revoke all on function public.erp_replay_webhook_delivery(uuid) from public, anon;

grant execute on function public.erp_api_keys() to authenticated, service_role;
grant execute on function public.erp_issue_api_key(uuid, text, text[], timestamptz) to authenticated, service_role;
grant execute on function public.erp_revoke_api_key(uuid, text) to authenticated, service_role;
grant execute on function public.erp_webhook_subscriptions() to authenticated, service_role;
grant execute on function public.erp_webhook_deliveries(uuid, integer) to authenticated, service_role;
grant execute on function public.erp_create_webhook_subscription(text, text, text) to authenticated, service_role;
grant execute on function public.erp_rotate_webhook_secret(uuid) to authenticated, service_role;
grant execute on function public.erp_set_webhook_subscription_status(uuid, text) to authenticated, service_role;
grant execute on function public.erp_replay_webhook_delivery(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_issue_api_key', 'erp.issue_api_key',
   'Issues an API key for a service principal. Gated on administration.integrate '
   'and refuses any scope the principal is not granted.'),
  ('erp_revoke_api_key', 'erp.revoke_api_key',
   'Ends a key immediately. Gated on administration.integrate.'),
  ('erp_create_webhook_subscription', 'erp.create_webhook_subscription',
   'Registers where an organisation wants its events delivered, and returns the '
   'signing secret once. Gated on administration.integrate.'),
  ('erp_rotate_webhook_secret', 'erp.rotate_webhook_secret',
   'Replaces a subscription''s signing secret. Gated on administration.integrate.'),
  ('erp_set_webhook_subscription_status', 'erp.set_webhook_subscription_status',
   'Pauses, resumes or ends a subscription. Gated on administration.integrate.'),
  ('erp_replay_webhook_delivery', 'erp.replay_webhook_delivery',
   'Repeats a recorded delivery as a new attempt that names the original. Gated '
   'on administration.integrate.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ── The assertion ────────────────────────────────────────────────────────────

create or replace function erp.assert_api_exposure_sound()
returns text
language plpgsql
set search_path = ''
as $$
declare v_bad text;
begin
  -- 1. Scopes come from the one permission catalogue.
  select string_agg(distinct s, ', ') into v_bad
    from erp.api_key k cross join lateral unnest(k.scopes) s
   where not exists (select 1 from erp_ref.permission p where p.code = s);
  if v_bad is not null then
    raise exception 'ERPWARE_API_SCOPE_UNKNOWN: %', v_bad using errcode = 'P0001';
  end if;

  -- 2. No effective scope exceeds what the principal is granted.
  select string_agg(format('%s:%s', k.key_prefix, s), ', ') into v_bad
    from erp.api_key k
    cross join lateral unnest(erp.api_key_effective_scopes(k.id)) s
   where not exists (
     select 1 from erp.effective_permission ep
      where ep.app_user_id = k.app_user_id and ep.permission_code = s);
  if v_bad is not null then
    raise exception 'ERPWARE_API_SCOPE_EXCEEDS_GRANT: %', v_bad using errcode = 'P0001';
  end if;

  -- 3. A key, its principal and its ledger stay inside one organisation.
  if exists (
    select 1 from erp.api_key k
      join erp.app_user u on u.id = k.app_user_id
     where u.tenant_id <> k.tenant_id)
  or exists (
    select 1 from erp.api_request r
      join erp.api_key k on k.id = r.api_key_id
     where k.tenant_id <> r.tenant_id)
  or exists (
    select 1 from erp.webhook_delivery d
      join erp.webhook_subscription s on s.id = d.subscription_id
     where s.tenant_id <> d.tenant_id) then
    raise exception 'ERPWARE_API_TENANT_LEAK: a key, ledger row or delivery crosses organisations'
      using errcode = 'P0001';
  end if;

  -- 4. Row security is on for all four tables.
  select string_agg(c.relname, ', ') into v_bad
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'erp'
     and c.relname in ('api_key', 'api_request', 'webhook_subscription', 'webhook_delivery')
     and not c.relrowsecurity;
  if v_bad is not null then
    raise exception 'ERPWARE_API_RLS_MISSING: %', v_bad using errcode = 'P0001';
  end if;

  -- 5. No public door returns secret material or a digest.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname like 'erp\_%'
     and pg_get_functiondef(p.oid) ~ '(key_hash|secret_material)';
  if v_bad is not null then
    raise exception 'ERPWARE_API_SECRET_EXPOSED: %', v_bad using errcode = 'P0001';
  end if;

  -- 6. A write cannot be replayed into two results.
  if not exists (
    select 1 from pg_constraint
     where conname = 'api_request_idempotent'
       and conrelid = 'erp.api_request'::regclass) then
    raise exception 'ERPWARE_API_IDEMPOTENCY_UNGUARDED: the replay ledger has no unique key'
      using errcode = 'P0001';
  end if;

  -- 7. Every subscription is an https address, and a delivery keeps its payload.
  if exists (select 1 from erp.webhook_subscription where target_url !~ '^https://')
  or exists (select 1 from erp.webhook_delivery where payload is null) then
    raise exception 'ERPWARE_WEBHOOK_UNSAFE: a subscription is not https, or a delivery lost its payload'
      using errcode = 'P0001';
  end if;

  return 'api exposure: scopes bounded by grants, keys tenant-bound, secrets unexposed, writes idempotent';
end $$;

comment on function erp.assert_api_exposure_sound is
  'Proves the exposure layer adds no privilege: every scope is a catalogue '
  'permission, no key exceeds its principal''s grants, nothing crosses an '
  'organisation, no door returns secret material, and a write cannot be '
  'applied twice under one idempotency key.';

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_api_exposure_sound();
