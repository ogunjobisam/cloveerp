set lock_timeout = '30s';

-- =============================================================================
-- 20261004950000  A carrier books through its own systems
-- -----------------------------------------------------------------------------
-- The second half of inbound carriers (owner, 2 October 2026: both halves in
-- one change), on top of freight coming in on our account (20261004945000).
-- Through a multi-carrier aggregator, EasyPost first (owner), behind an
-- adapter of the integration gateway, so another provider is another adapter.
-- docs/spec/logistics-target-flow.md §10 had carrier integration out of
-- scope; the owner brought it in.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Booking a carrier was a row in our own database. Nothing told the carrier,
-- no label was printed, the tracking reference was typed by hand if at all,
-- and whether a parcel had arrived was whatever somebody recorded.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * Each organisation connects its own EasyPost account (owner):
--     erp_connect_carrier_account(p_provider, p_api_key, p_webhook_secret),
--     by an administrator (administration.integrate). The key and the
--     webhook's signing secret go to Supabase Vault and only references to
--     them are kept: an external system, easypost, on the adapter easypost,
--     its credential_ref vault://… and its connection naming the mode (test
--     or live, from the key) and the webhook secret's reference. Where the
--     database has no vault the door refuses by name; nothing is stored.
--   * Connecting is the administrator's standing authority for the one
--     operation it enables, shipment.buy: the gateway's rule that every
--     outbound command is authorised under administration.integrate
--     (erp.submit_command()) is met by the connection, not asked again of the
--     planner who books a shipment. erp.submit_command() takes a command on
--     standing authority only when the system names it immediately before
--     (erp.standing_command, as erp.deriving_move names a derived move) and
--     the operation is marked so on the system.
--   * A carrier is linked to its account at the provider
--     (erp_link_carrier_provider). Booking a shipment with a linked carrier,
--     either way, out or in, submits shipment.buy: the addresses, the parcel,
--     the carrier account and the service, keyed by the shipment.
--   * The dispatch worker buys the label (worker/src/core/carrier.ts and
--     src/lib/carriers/easypost.ts) and hands the answer back:
--     erp.apply_carrier_label() keeps the tracking code, the label and the
--     provider's shipment on the shipment.
--   * The carrier's tracking reaches the shipment
--     (supabase/functions/carrier_webhook, signed with the organisation's
--     webhook secret): erp.record_carrier_tracking() keeps the latest status,
--     never moving backwards. An outbound shipment the carrier reports
--     delivered is delivered, by the system (a derived move,
--     erp.shipment_delivered_by_carrier()). An inbound one still arrives with
--     its goods.
--   * A site has a postal address (erp_set_site_address, by an administrator,
--     administration.configure), kept in erp.site.address and read by
--     erp_sites: a carrier labels an outbound parcel from it and an inbound one
--     to it. Until now nothing wrote it.
--   * The demonstration's two sites have addresses: given when the
--     demonstration creates them, and to the demonstration organisations that
--     already exist. Illustrative addresses, in the United Kingdom only; a
--     real organisation's own sites are never given one.
--   * erp_carrier_account(): whether the organisation is connected, in which
--     mode, and the address its webhook posts to.
--   * Refusals, registered, and three events: carrier.connected,
--     shipment.labelled and shipment.tracked.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No live call has been made: the adapter is proved against a recorded
--     EasyPost exchange (src/lib/carriers/easypost.test.ts) until an
--     organisation's test key is connected.
--   * Customs forms, returns labels and pickups: follow-ups.
--   * Rates from the provider in place of the rate card: the booking still
--     prices from the rate card; the label's own rate is kept for comparison.
--
-- Proved by erp_test.carrier_integration_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The columns
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.carrier add column if not exists provider text;
alter table erp.carrier add column if not exists provider_account text;
alter table erp.shipment add column if not exists label_url text;
alter table erp.shipment add column if not exists carrier_shipment_ref text;
alter table erp.shipment add column if not exists label_rate_minor bigint;
alter table erp.shipment add column if not exists tracking_status text;
alter table erp.shipment add column if not exists tracking_status_at timestamptz;
alter table erp.shipment add column if not exists tracking_detail text;
alter table erp.external_system_operation add column if not exists standing_authority boolean not null default false;

do $cols$
begin
  if not exists (select 1 from pg_constraint where conname = 'carrier_provider_known') then
    alter table erp.carrier add constraint carrier_provider_known check (provider is null or provider in ('easypost'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'shipment_tracking_status_known') then
    alter table erp.shipment add constraint shipment_tracking_status_known check (tracking_status is null or tracking_status in
      ('unknown', 'pre_transit', 'in_transit', 'out_for_delivery', 'available_for_pickup', 'delivered',
       'return_to_sender', 'failure', 'cancelled', 'error'));
  end if;
end
$cols$;

comment on column erp.carrier.provider is 'The aggregator the carrier is booked through, where it is (20261004950000).';
comment on column erp.carrier.provider_account is 'The carrier''s account at the provider, as the provider names it (20261004950000).';
comment on column erp.shipment.label_url is 'The label the carrier''s system issued (20261004950000).';
comment on column erp.shipment.carrier_shipment_ref is 'The provider''s own identifier of the shipment (20261004950000).';
comment on column erp.shipment.label_rate_minor is 'What the provider charged for the label, beside the rate card''s price (20261004950000).';
comment on column erp.shipment.tracking_status is 'The latest status the carrier reported, never moving backwards (20261004950000).';
comment on column erp.external_system_operation.standing_authority is
  'The administrator who connected the system authorised this operation once, for every command the system raises of it (20261004950000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_SECRET_STORE_UNAVAILABLE',
  'Connecting an account whose secret this database has nowhere safe to keep.',
  'A key to somebody else''s system is kept in the vault and nowhere else; a database with no vault keeps nothing rather than keep it badly.',
  'Enable Supabase Vault for the project, then connect the account again.');

select erp.register_refusal('CLOVEERP_CARRIER_PROVIDER_UNKNOWN',
  'Connecting or linking a carrier provider the product has no adapter for.',
  'A carrier is booked through a provider the product can speak to; any other would accept the booking and never send it.',
  'Choose easypost.');

select erp.register_refusal('CLOVEERP_CARRIER_KEY_MALFORMED',
  'Connecting a carrier account with something that is not one of the provider''s API keys.',
  'An EasyPost key begins EZTK for a test key or EZAK for a live one; anything else would fail every booking, and might be a secret pasted into the wrong box.',
  'Copy the API key from the provider''s dashboard, test or live, and paste it whole.');

select erp.register_refusal('CLOVEERP_SITE_ADDRESS_INCOMPLETE',
  'Giving a site an address with no street, town, postcode or country.',
  'A carrier labels a parcel from the site''s address and delivers one to it; half an address is a parcel that goes nowhere.',
  'Give the first line, the town, the postcode and the two-letter country code.');

select erp.register_refusal('CLOVEERP_CARRIER_ACCOUNT_NOT_CONNECTED',
  'Linking a carrier to a provider the organisation has not connected.',
  'A carrier linked to a provider with no account would be booked with nobody.',
  'Connect the provider account under Integrations first.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.carrier.connected', 'en', 'Carrier account connected', 'logistics',
   'Event raised when an administrator connects the organisation''s account at a carrier provider.'),
  ('event.carrier.connected', 'de', 'Spediteurkonto verbunden', 'logistics',
   'Ereignis, wenn ein Administrator das Konto der Organisation bei einem Versanddienstleister verbindet.'),
  ('event.shipment.labelled', 'en', 'Shipment labelled', 'logistics',
   'Event raised when the carrier''s system issues a shipment''s label and tracking code.'),
  ('event.shipment.labelled', 'de', 'Sendung etikettiert', 'logistics',
   'Ereignis, wenn das System des Spediteurs Etikett und Sendungsnummer ausgibt.'),
  ('event.shipment.tracked', 'en', 'Shipment tracked', 'logistics',
   'Event raised when the carrier reports where a shipment is.'),
  ('event.shipment.tracked', 'de', 'Sendung verfolgt', 'logistics',
   'Ereignis, wenn der Spediteur meldet, wo sich eine Sendung befindet.'),
  ('adapter.easypost.name', 'en', 'EasyPost', 'logistics', 'The multi-carrier aggregator EasyPost.'),
  ('adapter.easypost.name', 'de', 'EasyPost', 'logistics', 'Der Versanddienst-Aggregator EasyPost.'),
  ('adapter.easypost.shipment.buy.name', 'en', 'Buy a label', 'logistics', 'Books a shipment with the carrier and buys its label.'),
  ('adapter.easypost.shipment.buy.name', 'de', 'Etikett kaufen', 'logistics', 'Bucht eine Sendung beim Spediteur und kauft ihr Etikett.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('carrier.connected', 1, 'external_system', 'logistics', 'event.carrier.connected',
   'An administrator connected the organisation''s account at a carrier provider.',
   '{"type":"object","required":["provider","mode"],"properties":{"provider":{"type":"string"},"mode":{"type":"string"}}}'::jsonb, true),
  ('shipment.labelled', 1, 'document', 'logistics', 'event.shipment.labelled',
   'The carrier''s system issued a shipment''s label and tracking code.',
   '{"type":"object","required":["reference","tracking_code"],"properties":{"reference":{"type":"string"},"tracking_code":{"type":"string"},"rate_minor":{"type":["integer","null"]}}}'::jsonb, true),
  ('shipment.tracked', 1, 'document', 'logistics', 'event.shipment.tracked',
   'The carrier reported where a shipment is.',
   '{"type":"object","required":["reference","status"],"properties":{"reference":{"type":"string"},"status":{"type":"string"},"event_id":{"type":"string"}}}'::jsonb, true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code in ('carrier.connected', 'shipment.labelled', 'shipment.tracked')
         and et.is_current and et.version = 1 and et.name_key = 'event.' || et.code) <> 3 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a carrier event is declared already, and not as 20261004950000 declares it';
  end if;
end
$event$;

-- The adapter: EasyPost, its one operation, shipment.buy.

insert into erp_ref.adapter (code, version, name_key, description, direction, transport, connection_schema,
                             credential_contract, honours_idempotency, supports_dry_run, is_current)
values ('easypost', 1, 'adapter.easypost.name',
        'EasyPost, a multi-carrier aggregator: books a shipment with the carrier and buys its label, and posts tracking back to the carrier webhook (20261004950000).',
        'bidirectional', 'http',
        '{"type":"object","required":["mode"],"properties":{"mode":{"type":"string","enum":["test","live"]},"webhook_secret_ref":{"type":"string"},"timeout_ms":{"type":"integer","minimum":100}},"additionalProperties":false}'::jsonb,
        '{"kind":"api_key","note":"The organisation''s EasyPost API key, kept in Supabase Vault and read by the dispatch worker at send time; sent as the Basic username.","fields":["api_key"]}'::jsonb,
        true, true, true)
on conflict do nothing;

insert into erp_ref.adapter_operation (adapter_code, adapter_version, code, name_key, description, is_mutating,
                                       request_schema, response_schema, supports_dry_run, default_ordering_key_path)
values ('easypost', 1, 'shipment.buy', 'adapter.easypost.shipment.buy.name',
        'Books a shipment with the carrier and buys its label: the addresses, the parcel, the carrier account and the service.',
        true,
        '{"type":"object","required":["shipment_id","reference","from_address","to_address","parcel"],"properties":{"shipment_id":{"type":"string"},"reference":{"type":"string"},"direction":{"type":"string"},"from_address":{"type":"object"},"to_address":{"type":"object"},"parcel":{"type":"object"},"carrier_account":{"type":["string","null"]},"service":{"type":["string","null"]}}}'::jsonb,
        '{"type":"object"}'::jsonb, true, 'shipment_id')
on conflict do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. Connecting the account
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.store_tenant_secret(p_label text, p_value text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  -- A secret of the organisation's, into Supabase Vault (20261004950000),
  -- named for the organisation, returned as the reference the external
  -- system keeps. Definer because only the vault's owner may write it; gated
  -- by the integration permission it serves. No vault, nothing kept.
  perform erp.authorise('administration.integrate', null, null, null, 'external_system', null);
  if not exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault') then
    raise exception 'CLOVEERP_SECRET_STORE_UNAVAILABLE: this database has no vault to keep the secret in'
      using errcode = '55000', hint = 'Enable Supabase Vault for the project, then connect the account again.';
  end if;
  execute 'select vault.create_secret($1, $2, $3)' into v_id
    using p_value, 'cloveerp:' || v_tenant::text || ':' || p_label || ':' || gen_random_uuid()::text,
          'A secret of organisation ' || v_tenant::text || ' (' || p_label || ').';
  return 'vault://' || v_id::text;
end;
$$;

revoke all on function erp.store_tenant_secret(text, text) from public, anon;

comment on function erp.store_tenant_secret(text, text) is
  'Keeps one of the organisation''s secrets in Supabase Vault and returns its reference; refuses where '
  'there is no vault (20261004950000). Definer, gated by administration.integrate.';

create or replace function erp.connect_carrier_account(p_provider text, p_api_key text, p_webhook_secret text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_provider text := lower(btrim(coalesce(p_provider, '')));
  v_key      text := btrim(coalesce(p_api_key, ''));
  v_mode     text;
  v_ref      text;
  v_hook     text;
  v_sys      uuid;
begin
  -- The organisation's own account at a carrier provider (20261004950000;
  -- owner: each organisation its own). The key and the webhook secret go to
  -- the vault; the external system keeps their references, and connecting
  -- gives shipment.buy its standing authority.
  perform erp.authorise('administration.integrate', null, null, null, 'external_system', null);
  if v_provider <> 'easypost' then
    raise exception 'CLOVEERP_CARRIER_PROVIDER_UNKNOWN: the product books carriers through easypost, not %', coalesce(p_provider, 'nothing')
      using errcode = '22023', hint = 'Choose easypost.';
  end if;
  if v_key !~ '^EZ[TA]K[A-Za-z0-9]{16,}$' then
    raise exception 'CLOVEERP_CARRIER_KEY_MALFORMED: that is not an EasyPost API key'
      using errcode = '22023', hint = 'Copy the API key from the provider''s dashboard, test or live, and paste it whole.';
  end if;
  v_mode := case when v_key like 'EZTK%' then 'test' else 'live' end;

  v_ref := erp.store_tenant_secret('easypost:api_key', v_key);
  if nullif(btrim(coalesce(p_webhook_secret, '')), '') is not null then
    v_hook := erp.store_tenant_secret('easypost:webhook_secret', btrim(p_webhook_secret));
  end if;

  insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, credential_ref,
                                   status, max_in_flight, max_attempts, retry_backoff_seconds, requires_approval)
  values (v_tenant, 'easypost', 'EasyPost', 'easypost', 1,
          jsonb_build_object('mode', v_mode) || case when v_hook is null then '{}'::jsonb
                                                     else jsonb_build_object('webhook_secret_ref', v_hook) end,
          v_ref, 'active', 4, 5, 60, false)
  on conflict (tenant_id, code) do update
     set connection = excluded.connection
                      || case when v_hook is null and erp.external_system.connection ? 'webhook_secret_ref'
                              then jsonb_build_object('webhook_secret_ref', erp.external_system.connection ->> 'webhook_secret_ref')
                              else '{}'::jsonb end,
         credential_ref = excluded.credential_ref, status = 'active', updated_at = now()
  returning id into v_sys;

  insert into erp.external_system_operation (tenant_id, external_system_id, operation_code, is_enabled,
                                             requires_approval, standing_authority)
  values (v_tenant, v_sys, 'shipment.buy', true, false, true)
  on conflict (tenant_id, external_system_id, operation_code) do update
     set is_enabled = true, requires_approval = false, standing_authority = true, updated_at = now();

  perform erp.append_event('carrier.connected', 'external_system', v_sys,
                           jsonb_build_object('provider', v_provider, 'mode', v_mode), null, null);
  return erp.carrier_account();
end;
$$;

revoke all on function erp.connect_carrier_account(text, text, text) from public, anon;

comment on function erp.connect_carrier_account(text, text, text) is
  'Connects the organisation''s account at a carrier provider: its key and webhook secret to the vault, '
  'an external system holding their references, and shipment.buy enabled with standing authority '
  '(20261004950000). Authorises administration.integrate.';

create or replace function public.erp_connect_carrier_account(p_provider text, p_api_key text, p_webhook_secret text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.connect_carrier_account(p_provider, p_api_key, p_webhook_secret) $$;

revoke all on function public.erp_connect_carrier_account(text, text, text) from public, anon;
grant execute on function public.erp_connect_carrier_account(text, text, text) to authenticated, service_role;

comment on function public.erp_connect_carrier_account(text, text, text) is
  'Connects the organisation''s own carrier provider account, its key kept in the vault (20261004950000).';

create or replace function erp.disconnect_carrier_account(p_provider text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  -- No more bookings through the provider (20261004950000): the system is
  -- inactive and its operation disabled. The vault keeps nothing it needs:
  -- connecting again stores a new key.
  perform erp.authorise('administration.integrate', null, null, null, 'external_system', null);
  update erp.external_system set status = 'inactive', updated_at = now()
   where tenant_id = v_tenant and code = lower(btrim(coalesce(p_provider, '')));
  update erp.external_system_operation eo set is_enabled = false, standing_authority = false, updated_at = now()
    from erp.external_system s
   where eo.tenant_id = v_tenant and s.id = eo.external_system_id and s.code = lower(btrim(coalesce(p_provider, '')));
  return erp.carrier_account();
end;
$$;

revoke all on function erp.disconnect_carrier_account(text) from public, anon;

create or replace function public.erp_disconnect_carrier_account(p_provider text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.disconnect_carrier_account(p_provider) $$;

revoke all on function public.erp_disconnect_carrier_account(text) from public, anon;
grant execute on function public.erp_disconnect_carrier_account(text) to authenticated, service_role;

comment on function public.erp_disconnect_carrier_account(text) is
  'Stops booking carriers through the provider (20261004950000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_connect_carrier_account', 'erp.connect_carrier_account',
   'Connects the organisation''s carrier provider account: its secrets to the vault, an external system and an enabled operation; authorises administration.integrate.'),
  ('erp_disconnect_carrier_account', 'erp.disconnect_carrier_account',
   'Deactivates the organisation''s carrier provider account and disables its operation; authorises administration.integrate.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

create or replace function erp.carrier_account()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Whether the organisation books carriers through a provider
  -- (20261004950000), in which mode, since when, whether tracking can reach
  -- it, the address its webhook posts to, and whether the reader may connect.
  -- Never a key.
  select jsonb_build_object(
           'provider', 'easypost',
           'connected', coalesce(s.status = 'active', false),
           'mode', s.connection ->> 'mode',
           'tracking', s.connection ? 'webhook_secret_ref',
           'connected_at', s.updated_at,
           'webhook_path', '/functions/v1/carrier_webhook?org=' ||
                           (select t.code from erp.tenant t where t.id = erp.current_tenant_id()),
           'may_connect', erp.has_permission('administration.integrate'))
    from (select 1) one
    left join erp.external_system s on s.tenant_id = erp.current_tenant_id() and s.code = 'easypost'
$$;

revoke all on function erp.carrier_account() from public, anon;

create or replace function public.erp_carrier_account()
returns jsonb
language sql
stable
set search_path = ''
as $$ select erp.carrier_account() $$;

revoke all on function public.erp_carrier_account() from public, anon;
grant execute on function public.erp_carrier_account() to authenticated, service_role;

comment on function public.erp_carrier_account() is
  'Whether the organisation books carriers through its own provider account, and how; never its key (20261004950000).';

create or replace function erp.link_carrier_provider(p_carrier_code text, p_provider text, p_provider_account text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_provider text := nullif(lower(btrim(coalesce(p_provider, ''))), '');
  v_id       uuid;
begin
  -- A carrier of the rate card, linked to its account at the provider
  -- (20261004950000), or unlinked with no provider.
  perform erp.authorise('administration.integrate', null, null, null, 'carrier', null);
  if v_provider is not null and v_provider <> 'easypost' then
    raise exception 'CLOVEERP_CARRIER_PROVIDER_UNKNOWN: the product books carriers through easypost, not %', p_provider
      using errcode = '22023', hint = 'Choose easypost.';
  end if;
  if v_provider is not null and not exists (select 1 from erp.external_system s
                                              where s.tenant_id = v_tenant and s.code = v_provider and s.status = 'active') then
    raise exception 'CLOVEERP_CARRIER_ACCOUNT_NOT_CONNECTED: % is not connected for this organisation', v_provider
      using errcode = '23514', hint = 'Connect the provider account under Integrations first.';
  end if;
  update erp.carrier
     set provider = v_provider, provider_account = case when v_provider is null then null else nullif(btrim(coalesce(p_provider_account, '')), '') end,
         updated_at = now()
   where tenant_id = v_tenant and code = p_carrier_code
  returning id into v_id;
  if v_id is null then
    raise exception 'CLOVEERP_UNKNOWN_CARRIER: %', p_carrier_code using errcode = '23503';
  end if;
  return jsonb_build_object('carrier_code', p_carrier_code, 'provider', v_provider,
                            'provider_account', (select c.provider_account from erp.carrier c where c.id = v_id));
end;
$$;

revoke all on function erp.link_carrier_provider(text, text, text) from public, anon;

create or replace function public.erp_link_carrier_provider(p_carrier_code text, p_provider text, p_provider_account text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.link_carrier_provider(p_carrier_code, p_provider, p_provider_account) $$;

revoke all on function public.erp_link_carrier_provider(text, text, text) from public, anon;
grant execute on function public.erp_link_carrier_provider(text, text, text) to authenticated, service_role;

comment on function public.erp_link_carrier_provider(text, text, text) is
  'Links a carrier to its account at the organisation''s provider (20261004950000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_link_carrier_provider', 'erp.link_carrier_provider',
   'Links or unlinks a carrier to its account at the organisation''s provider; authorises administration.integrate.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/operations/integrations',
  array['erp_connect_carrier_account', 'erp_disconnect_carrier_account', 'erp_link_carrier_provider']);

-- ═════════════════════════════════════════════════════════════════════════════
-- D. Standing authority at the gateway
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.command_has_standing_authority(p_system_code text, p_operation_code text)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Whether a command leaves on the authority its system was connected with
  -- (20261004950000): the system named it immediately before
  -- (erp.standing_command), and the operation is marked so, enabled, on an
  -- active system. In every other case the gateway asks the caller.
  select coalesce(current_setting('erp.standing_command', true), '') = p_system_code || ':' || p_operation_code
     and exists (select 1 from erp.external_system s
                   join erp.external_system_operation eo on eo.tenant_id = s.tenant_id and eo.external_system_id = s.id
                  where s.tenant_id = erp.current_tenant_id() and s.code = p_system_code and s.status = 'active'
                    and eo.operation_code = p_operation_code and eo.is_enabled and eo.standing_authority)
$$;

revoke all on function erp.command_has_standing_authority(text, text) from public, anon;

-- Edited, not rewritten: one anchor over erp.submit_command() (md5 ceb96ad9…).

do $submit$
declare
  v_sig  constant text := 'erp.submit_command(text,text,jsonb,boolean,text,text,text,uuid,uuid,uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  perform erp.authorise('administration.integrate', p_entity_id, p_site_id, null,
                        'command', null, p_correlation_id);$o$;
  v_new  constant text := $n$  --
  -- Or the administrator who connected the system authorised it once, for
  -- the one operation it named, and the system names it now
  -- (20261004950000).
  if not erp.command_has_standing_authority(p_system_code, p_operation_code) then
    perform erp.authorise('administration.integrate', p_entity_id, p_site_id, null,
                          'command', null, p_correlation_id);
  end if;$n$;
begin
  if strpos(v_src, '20261004950000') > 0 then
    raise notice '% already honours standing authority; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'ceb96ad9d0841d72777c5d40d50bd355' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004950000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$submit$;

-- ═════════════════════════════════════════════════════════════════════════════
-- E. Booking asks the carrier's system for the label
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.carrier_address_of_party(p_party uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A party's address as a carrier reads it (20261004950000): its default
  -- address, or its delivery one, or any, with its name.
  select jsonb_build_object(
           'name', p.name, 'company', coalesce(p.legal_name, p.name),
           'street1', a.lines[1], 'street2', a.lines[2], 'city', a.locality, 'state', a.region,
           'zip', a.postcode, 'country', coalesce(a.country_code, p.country_code))
    from erp.party p
    left join lateral (
      select pa.* from erp.party_address pa
       where pa.tenant_id = p.tenant_id and pa.party_id = p.id
         and (pa.valid_to is null or pa.valid_to > current_date)
       order by coalesce(pa.is_default, false) desc, (pa.address_kind::text = 'delivery') desc, pa.created_at
       limit 1) a on true
   where p.tenant_id = erp.current_tenant_id() and p.id = p_party
$$;

revoke all on function erp.carrier_address_of_party(uuid) from public, anon;

create or replace function erp.carrier_address_of_site(p_site uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A site's address as a carrier reads it (20261004950000), named for the
  -- company that runs it.
  select jsonb_build_object(
           'name', s.name, 'company', coalesce(e.legal_name, e.name),
           'street1', coalesce(s.address ->> 'line1', s.address #>> '{lines,0}'),
           'street2', coalesce(s.address ->> 'line2', s.address #>> '{lines,1}'),
           'city', coalesce(s.address ->> 'city', s.address ->> 'locality'),
           'state', s.address ->> 'region',
           'zip', coalesce(s.address ->> 'postcode', s.address ->> 'zip'),
           'country', coalesce(s.address ->> 'country_code', s.country_code, e.country_code))
    from erp.site s
    join erp.entity e on e.tenant_id = s.tenant_id and e.id = s.entity_id
   where s.tenant_id = erp.current_tenant_id() and s.id = p_site
$$;

revoke all on function erp.carrier_address_of_site(uuid) from public, anon;

create or replace function erp.request_carrier_label(p_shipment uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  sh       erp.shipment%rowtype;
  c        erp.carrier%rowtype;
  v_from   jsonb;
  v_to     jsonb;
  v_number text;
  v_cmd    uuid;
  v_prev   text;
begin
  -- A booked shipment with a carrier linked to the organisation's provider
  -- asks the carrier's system for its label (20261004950000): shipment.buy,
  -- on the standing authority the provider was connected with, keyed by the
  -- shipment so a second booking asks once. Out: from the site to the
  -- customer. In: from the supplier to the site. Anything else asks nothing.
  select x.* into sh from erp.shipment x where x.tenant_id = v_tenant and x.id = p_shipment;
  select x.* into c from erp.carrier x where x.tenant_id = v_tenant and x.id = sh.carrier_id;
  if sh.id is null or c.provider is null
     or not exists (select 1 from erp.external_system s
                     join erp.external_system_operation eo on eo.tenant_id = s.tenant_id and eo.external_system_id = s.id
                    where s.tenant_id = v_tenant and s.code = c.provider and s.status = 'active'
                      and eo.operation_code = 'shipment.buy' and eo.is_enabled and eo.standing_authority) then
    return null;
  end if;

  select d.document_number into v_number from erp.document d where d.tenant_id = v_tenant and d.id = sh.document_id;
  if sh.direction = 'inbound' then
    v_from := erp.carrier_address_of_party(sh.origin_party_id);
    v_to := erp.carrier_address_of_site(sh.site_id);
  else
    v_from := erp.carrier_address_of_site(sh.site_id);
    v_to := erp.carrier_address_of_party(sh.destination_party_id);
  end if;

  v_prev := coalesce(current_setting('erp.standing_command', true), '');
  perform set_config('erp.standing_command', c.provider || ':shipment.buy', true);
  v_cmd := erp.submit_command(
    c.provider, 'shipment.buy',
    jsonb_build_object(
      'shipment_id', sh.id, 'reference', coalesce(v_number, sh.reference), 'direction', sh.direction,
      'from_address', coalesce(v_from, '{}'::jsonb), 'to_address', coalesce(v_to, '{}'::jsonb),
      'parcel', jsonb_build_object('weight_g', coalesce(sh.total_weight_g, 0)),
      'carrier_account', c.provider_account, 'service', sh.service_code),
    false, 'label:' || sh.id::text, sh.id::text, 'shipment', sh.id, sh.entity_id, sh.site_id, null);
  perform set_config('erp.standing_command', v_prev, true);
  return v_cmd;
end;
$$;

revoke all on function erp.request_carrier_label(uuid) from public, anon;

comment on function erp.request_carrier_label(uuid) is
  'Asks the carrier''s system for a booked shipment''s label, when its carrier is linked to the '
  'organisation''s connected provider (20261004950000).';

-- Booking asks for it. Edited, not rewritten: one anchor over
-- erp.book_shipment() (md5 60370dc5…), after the document is booked.

do $book$
declare
  v_sig  constant text := 'erp.book_shipment(uuid,text,text,bigint)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    perform erp.transition_document(sh.document_id, 'book', 'booked with ' || p_carrier_code);
    perform erp.mirror_shipment_status(p_shipment_id);
  end if;$o$;
  v_new  constant text := $n$    perform erp.transition_document(sh.document_id, 'book', 'booked with ' || p_carrier_code);
    perform erp.mirror_shipment_status(p_shipment_id);
  end if;
  -- And the carrier's own system is asked for the label, where the carrier
  -- is booked through the organisation's provider (20261004950000).
  perform erp.request_carrier_label(p_shipment_id);$n$;
begin
  if strpos(v_src, '20261004950000') > 0 then
    raise notice '% already asks the carrier for a label; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '60370dc5508f8750d4e8c3d25ea3cb1c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004950000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$book$;

-- A site's postal address: where an outbound parcel is labelled from and an
-- inbound one is delivered to. erp.site.address has been a column since the
-- first site and nothing wrote it.

create or replace function erp.set_site_address(p_site_id uuid, p_line1 text, p_line2 text, p_city text,
                                                p_region text, p_postcode text, p_country_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_country text := upper(btrim(coalesce(p_country_code, '')));
  v_address jsonb;
  st        erp.site%rowtype;
begin
  -- The site's postal address (20261004950000), whole or not at all: the
  -- first line, the town, the postcode and the country. The site's country
  -- follows the address's.
  select x.* into st from erp.site x where x.tenant_id = v_tenant and x.id = p_site_id;
  if st.id is null then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', coalesce(p_site_id::text, 'nothing') using errcode = '23503';
  end if;
  perform erp.authorise('administration.configure', st.entity_id, st.id, null, 'site', st.id);
  if nullif(btrim(coalesce(p_line1, '')), '') is null or nullif(btrim(coalesce(p_city, '')), '') is null
     or nullif(btrim(coalesce(p_postcode, '')), '') is null or v_country !~ '^[A-Z]{2}$' then
    raise exception 'CLOVEERP_SITE_ADDRESS_INCOMPLETE: % needs a first line, a town, a postcode and a two-letter country', st.code
      using errcode = '23514', hint = 'Give the first line, the town, the postcode and the two-letter country code.';
  end if;
  v_address := jsonb_strip_nulls(jsonb_build_object(
    'line1', btrim(p_line1), 'line2', nullif(btrim(coalesce(p_line2, '')), ''),
    'city', btrim(p_city), 'region', nullif(btrim(coalesce(p_region, '')), ''),
    'postcode', upper(btrim(p_postcode)), 'country_code', v_country));
  update erp.site set address = v_address, country_code = v_country, updated_at = now()
   where tenant_id = v_tenant and id = st.id;
  return jsonb_build_object('site_id', st.id, 'code', st.code, 'address', v_address);
end;
$$;

revoke all on function erp.set_site_address(uuid, text, text, text, text, text, text) from public, anon;

comment on function erp.set_site_address(uuid, text, text, text, text, text, text) is
  'Gives a site its postal address, whole: first line, town, postcode and country (20261004950000). '
  'Authorises administration.configure at the site.';

create or replace function public.erp_set_site_address(p_site_id uuid, p_line1 text, p_line2 text default null,
                                                       p_city text default null, p_region text default null,
                                                       p_postcode text default null, p_country_code text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.set_site_address(p_site_id, p_line1, p_line2, p_city, p_region, p_postcode, p_country_code) $$;

revoke all on function public.erp_set_site_address(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.erp_set_site_address(uuid, text, text, text, text, text, text) to authenticated, service_role;

comment on function public.erp_set_site_address(uuid, text, text, text, text, text, text) is
  'Gives a site its postal address, which carriers label parcels from and deliver to (20261004950000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_site_address', 'erp.set_site_address',
   'Writes a site''s postal address and country; authorises administration.configure at the site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/administration/organisation', array['erp_set_site_address']);

-- The demonstration's sites, addressed (20261004950000). The addresses are
-- illustrative: an estate and a park named for the product, for a company in
-- the United Kingdom. Anywhere else the demonstration's sites stay without
-- one, rather than be given a British address abroad.

create or replace function erp.demo_site_address(p_site_code text, p_country_code text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when upper(coalesce(p_country_code, '')) <> 'GB' then null
              when p_site_code = 'MAIN-WH' then
                '{"line1": "Unit 1, Clove Trading Estate", "line2": "Dock Road", "city": "London", "postcode": "E16 1AA", "country_code": "GB"}'::jsonb
              when p_site_code = 'NORTH-DC' then
                '{"line1": "Unit 7, Clove Distribution Park", "line2": "Ring Road", "city": "Leeds", "postcode": "LS11 5AA", "country_code": "GB"}'::jsonb
         end
$$;

comment on function erp.demo_site_address(text, text) is
  'The illustrative address of a demonstration site, MAIN-WH or NORTH-DC, for a company in the '
  'United Kingdom; null otherwise (20261004950000).';

create or replace function erp.address_demo_sites(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer;
begin
  -- A demonstration organisation's two sites, given their addresses where they
  -- have none (20261004950000). Only an organisation whose code marks it as
  -- the product's own demonstration: a real one that seeded the demonstration
  -- into its own sites keeps whatever it wrote, or nothing.
  if not exists (select 1 from erp.tenant t where t.id = p_tenant_id and t.code like 'demo-%') then
    return 0;
  end if;
  update erp.site s
     set address = erp.demo_site_address(s.code, s.country_code), updated_at = now()
   where s.tenant_id = p_tenant_id and s.code in ('MAIN-WH', 'NORTH-DC')
     and s.address = '{}'::jsonb
     and erp.demo_site_address(s.code, s.country_code) is not null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function erp.address_demo_sites(uuid) from public, anon, authenticated;

comment on function erp.address_demo_sites(uuid) is
  'Gives a demo- organisation''s MAIN-WH and NORTH-DC their illustrative addresses where they have '
  'none; does nothing to any other organisation (20261004950000).';

-- When the demonstration makes a site, it is made with its address. Edited,
-- not rewritten: two anchors over erp.ensure_demo_configuration() (md5
-- 25c89eea…), each where the site has just been made.

do $demo$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$    v_did := v_did || '"site MAIN-WH"'::jsonb;$o$;
  v_new1 constant text := $n$    v_did := v_did || '"site MAIN-WH"'::jsonb;
    -- With its address, where it has one (20261004950000).
    update erp.site s set address = coalesce(erp.demo_site_address(s.code, s.country_code), s.address)
     where s.id = v_site;$n$;
  v_old2 constant text := $o$      v_did := v_did || '"site NORTH-DC"'::jsonb;$o$;
  v_new2 constant text := $n$      v_did := v_did || '"site NORTH-DC"'::jsonb;
      -- With its address, where it has one (20261004950000).
      update erp.site s set address = coalesce(erp.demo_site_address(s.code, s.country_code), s.address)
       where s.tenant_id = p_tenant_id and s.entity_id = v_entity and s.code = 'NORTH-DC';$n$;
begin
  if strpos(v_src, '20261004950000') > 0 then
    raise notice '% already addresses its sites; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '25c89eeafe80b352e7228c5e69a9d52e' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004950000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$demo$;

-- And the demonstration organisations there already are. None in a build from
-- empty; production's, each in its own context as nobody.
do $backfill$
declare
  t record;
begin
  for t in select tn.id, tn.code from erp.tenant tn where tn.code like 'demo-%' order by tn.code loop
    perform set_config('erp.job_tenant_id', t.id::text, true);
    perform set_config('erp.job_principal_id', '', true);
    perform erp.address_demo_sites(t.id);
  end loop;
  perform set_config('erp.job_tenant_id', '', true);
end
$backfill$;

-- The sites, now with their address. As 20260906090000 wrote it, and the address.
create or replace function public.erp_sites()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'site_id', s.id, 'code', s.code, 'name', s.name,
           'site_type', s.site_type, 'entity_id', s.entity_id,
           'entity_code', (select e.code from erp.entity e
                            where e.tenant_id = s.tenant_id and e.id = s.entity_id),
           'country_code', s.country_code, 'status', s.status,
           'address', s.address)
           order by s.code), '[]'::jsonb)
    from erp.site s
   where s.tenant_id = erp.current_tenant_id()
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. What comes back
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.carrier_api_key(p_system_code text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_ref    text;
  v_value  text;
begin
  -- The organisation's provider key, for the dispatch worker at send time
  -- (20261004950000). Trusted connections only, the organisation's own secret
  -- only (its vault name says whose it is), and never logged.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not read a carrier key', current_user
      using errcode = '42501', hint = 'The dispatch worker reads it over its own connection; nobody signed in does.';
  end if;
  select s.credential_ref into v_ref from erp.external_system s
   where s.tenant_id = v_tenant and s.code = p_system_code and s.status = 'active';
  if v_ref is null or v_ref !~ '^vault://[0-9a-f-]{36}$'
     or not exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault') then
    return null;
  end if;
  execute 'select s.decrypted_secret from vault.decrypted_secrets s where s.id = $1 and s.name like $2'
     into v_value using substr(v_ref, 9)::uuid, 'cloveerp:' || v_tenant::text || ':%';
  return v_value;
end;
$$;

revoke all on function erp.carrier_api_key(text) from public, anon, authenticated;

comment on function erp.carrier_api_key(text) is
  'The organisation''s carrier provider key, from the vault, for the dispatch worker over a trusted '
  'connection (20261004950000). UNGATED BY DESIGN for principals: it refuses every untrusted caller.';

create or replace function erp.apply_carrier_label(p_command_id uuid, p_result jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cmd      erp.command%rowtype;
  sh       erp.shipment%rowtype;
  v_number text;
  v_code   text := nullif(btrim(coalesce(p_result ->> 'tracking_code', '')), '');
begin
  -- What the carrier's system answered for a label (20261004950000): its
  -- tracking code, the label, its own shipment and its rate, onto the
  -- shipment the command named. Trusted connections only: the dispatch worker
  -- reports it.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record a carrier''s answer', current_user
      using errcode = '42501', hint = 'The dispatch worker reports it over its own connection; nobody signed in does.';
  end if;
  select x.* into cmd from erp.command x where x.tenant_id = v_tenant and x.id = p_command_id;
  if cmd.id is null or cmd.source_object_type <> 'shipment' or v_code is null then
    return null;
  end if;
  update erp.shipment x
     set tracking_reference = v_code,
         label_url = nullif(btrim(coalesce(p_result ->> 'label_url', '')), ''),
         carrier_shipment_ref = nullif(btrim(coalesce(p_result ->> 'carrier_shipment_id', '')), ''),
         label_rate_minor = nullif(p_result ->> 'rate_minor', '')::bigint,
         tracking_status = coalesce(x.tracking_status, 'pre_transit'),
         tracking_status_at = coalesce(x.tracking_status_at, now()),
         updated_at = now()
   where x.tenant_id = v_tenant and x.id = cmd.source_object_id
  returning * into sh;
  if sh.id is null then
    return null;
  end if;
  select d.document_number into v_number from erp.document d where d.tenant_id = v_tenant and d.id = sh.document_id;
  if sh.document_id is not null then
    perform erp.append_event('shipment.labelled', 'document', sh.document_id,
      jsonb_build_object('reference', coalesce(v_number, sh.reference), 'tracking_code', v_code,
                         'rate_minor', sh.label_rate_minor), sh.entity_id, sh.site_id);
  end if;
  return jsonb_build_object('shipment_id', sh.id, 'tracking_code', v_code, 'label_url', sh.label_url);
end;
$$;

revoke all on function erp.apply_carrier_label(uuid, jsonb) from public, anon;

comment on function erp.apply_carrier_label(uuid, jsonb) is
  'Keeps what the carrier''s system answered for a label on the shipment its command named: tracking '
  'code, label, provider shipment and rate (20261004950000). Trusted connections only.';

create or replace function erp.tracking_rank(p_status text)
returns integer
language sql
immutable
set search_path = ''
as $$
  -- How far along a carrier status is, so a late event never moves a
  -- shipment backwards (20261004950000).
  select case p_status
    when 'unknown' then 0 when 'pre_transit' then 10 when 'in_transit' then 20
    when 'available_for_pickup' then 25 when 'out_for_delivery' then 30 when 'delivered' then 40
    when 'return_to_sender' then 50 when 'failure' then 50 when 'cancelled' then 50 when 'error' then 50
    else -1 end
$$;

create or replace function erp.shipment_delivered_by_carrier(p_shipment_document uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- An outbound shipment its carrier reports delivered (20261004950000): the
  -- fact its delivery is derived from.
  select exists (select 1 from erp.shipment s
                  where s.tenant_id = erp.current_tenant_id() and s.document_id = p_shipment_document
                    and s.direction = 'outbound' and s.tracking_status = 'delivered')
$$;

revoke all on function erp.shipment_delivered_by_carrier(uuid) from public, anon;

create or replace function erp.record_carrier_tracking(p_tenant_code text, p_event_id text, p_tracking_code text,
                                                       p_status text, p_occurred_at timestamptz default null,
                                                       p_detail text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
  sh       erp.shipment%rowtype;
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_when   timestamptz := coalesce(p_occurred_at, now());
  v_number text;
  v_moved  boolean := false;
  v_delivered boolean := false;
begin
  -- Where the carrier says a shipment is (20261004950000), from the carrier
  -- webhook over its own connection: the organisation by its code, the
  -- shipment by its tracking code. The status only moves forward. An outbound
  -- shipment reported delivered is delivered, by the system; an inbound one
  -- still arrives with its goods. A replay changes nothing.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not record carrier tracking', current_user
      using errcode = '42501', hint = 'The carrier webhook records it over its own connection; nobody signed in does.';
  end if;
  select t.id into v_tenant from erp.tenant t where t.code = p_tenant_code;
  if v_tenant is null or erp.tracking_rank(v_status) < 0 or nullif(btrim(coalesce(p_tracking_code, '')), '') is null then
    return jsonb_build_object('recorded', false, 'reason', 'not an organisation, a status or a tracking code this product knows');
  end if;
  perform erp.set_job_tenant(v_tenant);

  select x.* into sh from erp.shipment x
   where x.tenant_id = v_tenant and x.tracking_reference = btrim(p_tracking_code)
   order by x.created_at desc limit 1
     for update;
  if sh.id is null then
    return jsonb_build_object('recorded', false, 'reason', 'no shipment of the organisation has that tracking code');
  end if;

  if erp.tracking_rank(v_status) > erp.tracking_rank(sh.tracking_status) then
    update erp.shipment
       set tracking_status = v_status, tracking_status_at = v_when,
           tracking_detail = left(nullif(btrim(coalesce(p_detail, '')), ''), 300), updated_at = now()
     where id = sh.id;
    v_moved := true;
    select d.document_number into v_number from erp.document d where d.tenant_id = v_tenant and d.id = sh.document_id;
    if sh.document_id is not null then
      perform erp.append_event('shipment.tracked', 'document', sh.document_id,
        jsonb_build_object('reference', coalesce(v_number, sh.reference), 'status', v_status,
                           'event_id', coalesce(p_event_id, '')), sh.entity_id, sh.site_id);
    end if;
    if v_status = 'delivered' and sh.direction = 'outbound' and sh.status = 'booked' and sh.document_id is not null then
      update erp.shipment
         set actual_arrival = v_when,
             proof_of_delivery = jsonb_build_object('at', v_when, 'by', 'the carrier', 'reference', sh.tracking_reference,
                                                    'because', 'the carrier''s tracking reported it delivered'),
             updated_at = now()
       where id = sh.id;
      perform set_config('erp.deriving_move', sh.document_id::text || ':deliver', true);
      perform erp.transition_document(sh.document_id, 'deliver', 'Delivered, as the carrier reported');
      perform set_config('erp.deriving_move', '', true);
      perform erp.mirror_shipment_status(sh.id);
      v_delivered := true;
    end if;
  end if;
  return jsonb_build_object('recorded', true, 'shipment_id', sh.id, 'moved', v_moved, 'delivered', v_delivered,
                            'status', (select x.tracking_status from erp.shipment x where x.id = sh.id));
end;
$$;

revoke all on function erp.record_carrier_tracking(text, text, text, text, timestamptz, text) from public, anon;

comment on function erp.record_carrier_tracking(text, text, text, text, timestamptz, text) is
  'Keeps where the carrier says a shipment is, never moving backwards, and delivers an outbound one '
  'reported delivered (20261004950000). Trusted connections only: the carrier webhook.';

create or replace function erp.carrier_webhook_secret(p_tenant_code text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_ref    text;
  v_value  text;
begin
  -- The signing secret an organisation's carrier webhook is verified with
  -- (20261004950000), from the vault, for the webhook over its own
  -- connection. UNGATED BY DESIGN for principals: it refuses every untrusted
  -- caller.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not read a webhook secret', current_user
      using errcode = '42501', hint = 'The carrier webhook reads it over its own connection; nobody signed in does.';
  end if;
  select t.id into v_tenant from erp.tenant t where t.code = p_tenant_code;
  select s.connection ->> 'webhook_secret_ref' into v_ref from erp.external_system s
   where s.tenant_id = v_tenant and s.code = 'easypost' and s.status = 'active';
  if v_ref is null or v_ref !~ '^vault://[0-9a-f-]{36}$'
     or not exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault') then
    return null;
  end if;
  execute 'select s.decrypted_secret from vault.decrypted_secrets s where s.id = $1 and s.name like $2'
     into v_value using substr(v_ref, 9)::uuid, 'cloveerp:' || v_tenant::text || ':%';
  return v_value;
end;
$$;

revoke all on function erp.carrier_webhook_secret(text) from public, anon, authenticated;

comment on function erp.carrier_webhook_secret(text) is
  'The organisation''s carrier webhook signing secret, from the vault, for the webhook over a trusted '
  'connection (20261004950000). UNGATED BY DESIGN for principals: it refuses every untrusted caller.';

-- The fact the delivery is derived from. Edited, not rewritten: one anchor
-- over erp.derived_move_fact() as 20261004945000 left it (md5 d35a7005…).

do $fact$
declare
  v_sig  constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$             then 'erp.inbound_shipment_is_received'
         end$o$;
  v_new  constant text := $n$             then 'erp.inbound_shipment_is_received'
           -- An outbound shipment's delivery, once its carrier reports it
           -- delivered (20261004950000), asked for by
           -- erp.record_carrier_tracking().
           when dt.base_type_code = 'shipment' and p_transition_code = 'deliver'
            and erp.object_current_state('document', p_object_id) = 'booked'
            and erp.shipment_delivered_by_carrier(p_object_id)
             then 'erp.shipment_delivered_by_carrier'
         end$n$;
begin
  if strpos(v_src, '20261004950000') > 0 then
    raise notice '% already derives a carrier''s delivery; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd35a700531df0d45a99d8d038b7f9419' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004950000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$fact$;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'store_tenant_secret',
   'Runs as its owner because only the vault''s owner may write a secret. Gated by '
   'administration.integrate before it touches the vault; names the secret for the caller''s '
   'own organisation and returns only its reference. erp_test.carrier_integration_suite proves '
   'it refuses without a vault and keeps nothing.'),
  ('erp', 'carrier_api_key',
   'UNGATED BY DESIGN for principals: refuses every untrusted caller and is executable by '
   'service_role alone, for the dispatch worker at send time. Runs as its owner to read '
   'vault.decrypted_secrets; reads only a secret named for the organisation the connection '
   'is set to.'),
  ('erp', 'carrier_webhook_secret',
   'UNGATED BY DESIGN for principals: refuses every untrusted caller and is executable by '
   'service_role alone, for the carrier webhook verifying a signature. Runs as its owner to '
   'read vault.decrypted_secrets; reads only a secret named for the organisation the code names.')
on conflict do nothing;

-- A shipment's carrier side, for its page.

create or replace function public.erp_shipment_tracking(p_shipment_document uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A shipment as the carrier's system knows it (20261004950000): its label,
  -- its tracking code and status, and whether its carrier is booked through
  -- the organisation's provider.
  select jsonb_build_object(
           'shipment_id', s.id, 'direction', s.direction,
           'tracking_reference', s.tracking_reference, 'tracking_status', s.tracking_status,
           'tracking_status_at', s.tracking_status_at, 'tracking_detail', s.tracking_detail,
           'label_url', s.label_url, 'label_rate_minor', s.label_rate_minor, 'currency', s.currency,
           'provider', c.provider,
           'label_command_status', (select cmd.status::text from erp.command cmd
                                     where cmd.tenant_id = s.tenant_id and cmd.source_object_type = 'shipment'
                                       and cmd.source_object_id = s.id order by cmd.created_at desc limit 1))
    from erp.shipment s
    left join erp.carrier c on c.tenant_id = s.tenant_id and c.id = s.carrier_id
   where s.tenant_id = erp.current_tenant_id() and s.document_id = p_shipment_document
$$;

revoke all on function public.erp_shipment_tracking(uuid) from public, anon;
grant execute on function public.erp_shipment_tracking(uuid) to authenticated, service_role;

comment on function public.erp_shipment_tracking(uuid) is
  'A shipment as the carrier''s system knows it: label, tracking code and status (20261004950000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- G. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.carrier_integration_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_item uuid; v_sa uuid; v_carrier text; v_sys uuid;
  v_po uuid; v_ship jsonb; v_cmd erp.command%rowtype; v_fx jsonb; v_out uuid; v_outdoc uuid;
  v_label jsonb; v_trk jsonb; v_trk2 jsonb; v_trk3 jsonb; v_acct jsonb; v_n integer;
  v_err text; v_err2 text; v_err3 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys and ships';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcar-' || v_tag, 'Carrier Integration Suite',
      'admin@zzcar-' || v_tag || '.test', 'Carrier Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzcar-' || v_tag || '.test'), (s_buy, 'buyer@zzcar-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('buyer@zzcar-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCBOOT', 'Carried Boot', (select u.id from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1), 'active')
    returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZCBRAND');
    insert into erp.party_address (tenant_id, party_id, address_kind, lines, locality, postcode, country_code, is_default)
    values (rb.tenant_id, v_sa, 'delivery', array['12 rue du Faubourg'], 'Paris', '75008', 'FR', true);
    select c.code into v_carrier from erp.carrier c where c.tenant_id = rb.tenant_id and c.status = 'active' order by c.code limit 1;

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the doors, the refusals, the events and the adapter';
    v_cases := v_cases + 1;
    case_name := 'the three write doors are on the allow-list under their gates and on the Integrations screen''s help, the four refusals are registered with a next action, the three events are current in English and German, EasyPost is an adapter with shipment.buy, and the demonstration''s two sites were made with their addresses while no other organisation''s are given one';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance a
                where (a.function_name, a.gate) in (('erp_connect_carrier_account', 'erp.connect_carrier_account'),
                                                    ('erp_disconnect_carrier_account', 'erp.disconnect_carrier_account'),
                                                    ('erp_link_carrier_provider', 'erp.link_carrier_provider'))) = 3
          and exists (select 1 from erp_ref.help_topic h where h.screen_path = '/operations/integrations'
                         and h.actions @> array['erp_connect_carrier_account', 'erp_link_carrier_provider'])
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_SECRET_STORE_UNAVAILABLE', 'CLOVEERP_CARRIER_PROVIDER_UNKNOWN',
                                 'CLOVEERP_CARRIER_KEY_MALFORMED', 'CLOVEERP_CARRIER_ACCOUNT_NOT_CONNECTED')
                  and coalesce(f.next_action, '') <> '') = 4
          and (select count(*) from erp_ref.resource x
                where x.key in ('event.carrier.connected', 'event.shipment.labelled', 'event.shipment.tracked')
                  and x.locale in ('en', 'de')) = 6
          and exists (select 1 from erp_ref.adapter_operation o where o.adapter_code = 'easypost' and o.code = 'shipment.buy')
          -- The demonstration made its sites with their addresses; an
          -- organisation that is not a demo- one is never addressed by the backfill.
          and (select x.address ->> 'line1' from erp.site x where x.tenant_id = rb.tenant_id and x.code = 'MAIN-WH')
              = 'Unit 1, Clove Trading Estate'
          and (select x.address ->> 'city' from erp.site x where x.tenant_id = rb.tenant_id and x.code = 'NORTH-DC') = 'Leeds'
          and erp.address_demo_sites(rb.tenant_id) = 0
          and erp.demo_site_address('MAIN-WH', 'FR') is null;
    detail := coalesce(v_state, format('registers read; MAIN-WH %s',
                       (select x.address from erp.site x where x.tenant_id = rb.tenant_id and x.code = 'MAIN-WH')));
    return next;

    -- ── 2. Connecting refuses what it must ──────────────────────────────────
    v_step := 'a provider nobody knows, a key that is not one, a buyer, and the vault';
    begin
      perform public.erp_connect_carrier_account('fedex', 'EZTK' || repeat('a', 24), null);
      v_err := 'connected';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_connect_carrier_account('easypost', 'sk_live_not_a_key', null);
      v_err2 := 'connected';
    exception when others then v_err2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin
      perform public.erp_connect_carrier_account('easypost', 'EZTK' || repeat('a', 24), null);
      v_err3 := 'connected';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      v_acct := public.erp_connect_carrier_account('easypost', 'EZTK' || repeat('a', 24), 'whsec');
      v_err := v_err || ' | vault: connected';
    exception when others then v_err := v_err || ' | vault: ' || sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a provider nobody knows, a key that is not one and a buyer without administration.integrate are refused by name; where the database has no vault, connecting is refused and nothing is kept, and where it has one the account connects in test mode';
    passed := v_state is null
          and v_err like 'CLOVEERP_CARRIER_PROVIDER_UNKNOWN:%'
          and v_err2 like 'CLOVEERP_CARRIER_KEY_MALFORMED:%'
          and v_err3 like 'CLOVEERP_PERMISSION_DENIED: administration.integrate%'
          and case when exists (select 1 from pg_namespace where nspname = 'vault')
                   then v_err like '%vault: connected' and v_acct ->> 'mode' = 'test' and (v_acct ->> 'connected')::boolean
                   else v_err like '%vault: CLOVEERP_SECRET_STORE_UNAVAILABLE:%'
                        and not exists (select 1 from erp.external_system s where s.tenant_id = rb.tenant_id and s.code = 'easypost')
              end;
    detail := coalesce(v_state, left(format('%s | %s | %s', v_err, v_err2, v_err3), 700));
    return next;

    -- The connection as a vault would leave it, for what follows: a reference,
    -- never a key.
    v_step := 'the organisation connected as the vault would leave it, and the carrier linked';
    insert into erp.external_system (tenant_id, code, name, adapter_code, adapter_version, connection, credential_ref,
                                     status, max_in_flight, max_attempts, retry_backoff_seconds, requires_approval)
    values (rb.tenant_id, 'easypost', 'EasyPost', 'easypost', 1, '{"mode":"test"}'::jsonb,
            'vault://' || gen_random_uuid()::text, 'active', 4, 5, 60, false)
    on conflict (tenant_id, code) do update set status = 'active'
    returning id into v_sys;
    insert into erp.external_system_operation (tenant_id, external_system_id, operation_code, is_enabled, requires_approval, standing_authority)
    values (rb.tenant_id, v_sys, 'shipment.buy', true, false, true)
    on conflict (tenant_id, external_system_id, operation_code) do update set is_enabled = true, standing_authority = true;
    perform public.erp_link_carrier_provider(v_carrier, 'easypost', 'ca_suite_123');

    -- ── 3. Booking asks the carrier for the label ───────────────────────────
    v_step := 'an order we collect, sent, and its collection booked by somebody without administration.integrate';
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 2, 5000, 'ZCAR3', false);
    perform public.erp_set_freight_terms(v_po, 'we_collect');
    perform erp.transition_document(v_po, 'send', null);
    perform public.erp_save_role(null, 'planner', 'Planner', 'Books carriers',
                                 array['logistics.read', 'logistics.plan']);
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'planner', null, null, 'books carriers');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_ship := public.erp_ship_inbound(v_po, v_carrier, 'standard', 8000, null, null, 2000);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select c.* into v_cmd from erp.command c
     where c.tenant_id = rb.tenant_id and c.source_object_type = 'shipment' and c.source_object_id = (v_ship ->> 'shipment_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'booking a collection with a linked carrier asks EasyPost for its label on the standing authority the account was connected with: one shipment.buy command, from the supplier''s address to the site, with the parcel as weighed, the carrier account, the service and the shipment''s number, even for a booker without administration.integrate';
    passed := v_state is null
          and v_cmd.id is not null
          and v_cmd.operation_code = 'shipment.buy'
          and v_cmd.status::text in ('approved', 'queued', 'pending')
          and v_cmd.payload ->> 'direction' = 'inbound'
          and v_cmd.payload #>> '{from_address,city}' = 'Paris'
          and v_cmd.payload #>> '{from_address,country}' = 'FR'
          and (v_cmd.payload #>> '{parcel,weight_g}')::numeric = 2000
          and v_cmd.payload ->> 'carrier_account' = 'ca_suite_123'
          and v_cmd.payload ->> 'service' = 'standard'
          and v_cmd.payload ->> 'reference' = v_ship ->> 'document_number'
          and v_cmd.idempotency_key = 'label:' || (v_ship ->> 'shipment_id');
    detail := coalesce(v_state, left(format('cmd %s %s %s', v_cmd.status, v_cmd.payload, v_ship), 700));
    return next;

    -- ── 4. Without standing authority, the gateway still asks ───────────────
    v_step := 'a command the system did not name, by somebody without administration.integrate';
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin
      perform erp.submit_command('easypost', 'shipment.buy', v_cmd.payload, false, 'by-hand-suite', null, 'shipment', null, null, null, null);
      v_err := 'submitted';
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a command the system did not name is asked administration.integrate as every command is: standing authority covers only what the connection raises';
    passed := v_state is null and v_err like 'CLOVEERP_PERMISSION_DENIED: administration.integrate%';
    detail := coalesce(v_state, left(v_err, 300));
    return next;

    -- ── 5. The label comes back ─────────────────────────────────────────────
    v_step := 'the worker reports EasyPost''s answer';
    v_label := erp.apply_carrier_label(v_cmd.id, jsonb_build_object(
      'tracking_code', 'EZ1000000001', 'label_url', 'https://easypost-files.example/label.png',
      'carrier_shipment_id', 'shp_123', 'rate_minor', 7650));
    v_cases := v_cases + 1;
    case_name := 'the carrier''s answer is kept on the shipment: its tracking code, its label, the provider''s shipment and the rate it charged, the shipment reads pre-transit, and shipment.labelled is raised';
    passed := v_state is null
          and (select s.tracking_reference from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid) = 'EZ1000000001'
          and (select s.label_url from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid) like 'https://%'
          and (select s.carrier_shipment_ref from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid) = 'shp_123'
          and (select s.label_rate_minor from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid) = 7650
          and (select s.tracking_status from erp.shipment s where s.id = (v_ship ->> 'shipment_id')::uuid) = 'pre_transit'
          and exists (select 1 from erp.event e where e.tenant_id = rb.tenant_id and e.event_type = 'shipment.labelled'
                         and e.aggregate_id = (v_ship ->> 'document_id')::uuid);
    detail := coalesce(v_state, left(coalesce(v_label::text, 'nothing'), 300));
    return next;

    -- ── 6. Tracking moves forward only ──────────────────────────────────────
    v_step := 'in transit, then a late pre-transit, then delivered, for the inbound collection';
    v_trk := erp.record_carrier_tracking('zzcar-' || v_tag, 'evt_1', 'EZ1000000001', 'in_transit', now(), 'Departed Paris');
    v_trk2 := erp.record_carrier_tracking('zzcar-' || v_tag, 'evt_0', 'EZ1000000001', 'pre_transit', now() - interval '1 day', null);
    v_trk3 := erp.record_carrier_tracking('zzcar-' || v_tag, 'evt_2', 'EZ1000000001', 'delivered', now(), 'Signed for');
    v_cases := v_cases + 1;
    case_name := 'tracking moves the collection forward and never back; reported delivered, an inbound shipment records it and still waits for its goods to be received';
    passed := v_state is null
          and (v_trk ->> 'moved')::boolean
          and not (v_trk2 ->> 'moved')::boolean
          and (v_trk3 ->> 'status') = 'delivered'
          and not (v_trk3 ->> 'delivered')::boolean
          and erp.object_current_state('document', (v_ship ->> 'document_id')::uuid) = 'booked';
    detail := coalesce(v_state, left(format('%s | %s | %s', v_trk, v_trk2, v_trk3), 600));
    return next;

    -- ── 7. A site has an address ────────────────────────────────────────────
    v_step := 'half an address, a buyer, and every site given a whole one';
    begin
      perform public.erp_set_site_address(v_site, '1 Dock Road', null, null, null, 'E16 1AA', 'GB');
      v_err := 'set';
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin
      perform public.erp_set_site_address(v_site, '1 Dock Road', null, 'London', null, 'E16 1AA', 'GB');
      v_err2 := 'set';
    exception when others then v_err2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform public.erp_set_site_address(x.id, '1 Dock Road', 'Unit 4', 'London', null, 'e16 1aa', 'gb')
       from erp.site x where x.tenant_id = rb.tenant_id;
    select x into v_acct from jsonb_array_elements(public.erp_sites()) x where (x ->> 'site_id')::uuid = v_site;
    v_cases := v_cases + 1;
    case_name := 'a site''s address is refused without its town, and to somebody without administration.configure; given whole, it is kept tidy, its country is the site''s, and the sites list reads it';
    passed := v_state is null
          and v_err like 'CLOVEERP_SITE_ADDRESS_INCOMPLETE:%'
          and v_err2 like 'CLOVEERP_PERMISSION_DENIED: administration.configure%'
          and v_acct #>> '{address,postcode}' = 'E16 1AA'
          and v_acct #>> '{address,country_code}' = 'GB'
          and v_acct ->> 'country_code' = 'GB'
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_set_site_address' and a.gate = 'erp.set_site_address');
    detail := coalesce(v_state, left(format('%s | %s | %s', v_err, v_err2, v_acct), 600));
    return next;

    -- ── 8. An outbound one is delivered by its carrier ──────────────────────
    v_step := 'deliveries shipped with the linked carrier, labelled, and reported delivered';
    v_fx := erp_test.despatch_fixture(rb.tenant_id, v_entity, v_tag, 1);
    -- The fixture's despatch site is its own; it is given its address as any site is.
    perform public.erp_set_site_address(x.id, '1 Dock Road', 'Unit 4', 'London', null, 'e16 1aa', 'gb')
       from erp.site x where x.tenant_id = rb.tenant_id and x.address is distinct from
            '{"line1": "1 Dock Road", "line2": "Unit 4", "city": "London", "postcode": "E16 1AA", "country_code": "GB"}'::jsonb;
    v_out := erp.ship_deliveries(array[(v_fx #>> '{deliveries,0}')::uuid], null, v_carrier, 'standard', 3000);
    select s.document_id into v_outdoc from erp.shipment s where s.id = v_out;
    select c.* into v_cmd from erp.command c
     where c.tenant_id = rb.tenant_id and c.source_object_type = 'shipment' and c.source_object_id = v_out;
    perform erp.apply_carrier_label(v_cmd.id, jsonb_build_object('tracking_code', 'EZ2000000002'));
    v_trk := erp.record_carrier_tracking('zzcar-' || v_tag, 'evt_9', 'EZ2000000002', 'delivered', now(), 'Left with neighbour');
    v_cases := v_cases + 1;
    case_name := 'an outbound shipment with a linked carrier asks for its label from the site''s own address to the customer, and reported delivered by the carrier it is delivered by the system, its proof the carrier''s';
    passed := v_state is null
          and v_cmd.payload ->> 'direction' = 'outbound'
          and v_cmd.payload #>> '{from_address,street1}' = '1 Dock Road'
          and v_cmd.payload #>> '{from_address,street2}' = 'Unit 4'
          and v_cmd.payload #>> '{from_address,city}' = 'London'
          and v_cmd.payload #>> '{from_address,zip}' = 'E16 1AA'
          and v_cmd.payload #>> '{from_address,country}' = 'GB'
          and (v_trk ->> 'delivered')::boolean
          and erp.object_current_state('document', v_outdoc) = 'delivered'
          and (select s.proof_of_delivery ->> 'by' from erp.shipment s where s.id = v_out) = 'the carrier';
    detail := coalesce(v_state, left(format('%s; %s; from %s', v_trk, erp.object_current_state('document', v_outdoc),
                                            v_cmd.payload -> 'from_address'), 500));
    return next;

    -- ── 9. What tracking ignores ────────────────────────────────────────────
    v_step := 'an organisation, a status and a tracking code nobody knows';
    v_trk := erp.record_carrier_tracking('zz-nobody', 'evt_x', 'EZ1000000001', 'in_transit', now(), null);
    v_trk2 := erp.record_carrier_tracking('zzcar-' || v_tag, 'evt_y', 'EZ1000000001', 'teleported', now(), null);
    v_trk3 := erp.record_carrier_tracking('zzcar-' || v_tag, 'evt_z', 'EZ9999999999', 'in_transit', now(), null);
    v_cases := v_cases + 1;
    case_name := 'tracking for an organisation, a status or a tracking code nobody knows records nothing, and says so';
    passed := v_state is null
          and not (v_trk ->> 'recorded')::boolean
          and not (v_trk2 ->> 'recorded')::boolean
          and not (v_trk3 ->> 'recorded')::boolean;
    detail := coalesce(v_state, left(format('%s | %s | %s', v_trk, v_trk2, v_trk3), 500));
    return next;

    -- ── 10. An unlinked carrier asks nothing; the account reads safely ───────
    v_step := 'the carrier unlinked, a collection booked, and the account read';
    perform public.erp_link_carrier_provider(v_carrier, null, null);
    select count(*) into v_n from erp.command c where c.tenant_id = rb.tenant_id;
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 1, 5000, 'ZCAR9', false);
    perform public.erp_set_freight_terms(v_po, 'we_collect');
    perform erp.transition_document(v_po, 'send', null);
    perform public.erp_ship_inbound(v_po, v_carrier, 'standard', 8000, null, null);
    v_acct := public.erp_carrier_account();
    v_cases := v_cases + 1;
    case_name := 'a carrier not linked to the provider books with no command, and the account read says connected, in which mode and where its webhook posts, and never carries a key';
    passed := v_state is null
          and (select count(*) from erp.command c where c.tenant_id = rb.tenant_id) = v_n
          and (v_acct ->> 'connected')::boolean
          and v_acct ->> 'mode' = 'test'
          and v_acct ->> 'webhook_path' like '%carrier_webhook?org=zzcar-%'
          and v_acct::text not like '%vault://%';
    detail := coalesce(v_state, left(v_acct::text, 400));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzcar-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_buy))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzcar rolled back with its account, commands and shipments');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CARRIER_INTEGRATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.carrier_integration_suite() from public, anon;

comment on function erp_test.carrier_integration_suite() is
  'A carrier books through its own systems (20261004950000): connecting refuses by name and keeps keys '
  'only in a vault; booking with a linked carrier raises shipment.buy on standing authority and nothing '
  'else does; the label comes back onto the shipment; tracking moves forward only and delivers an '
  'outbound shipment, not an inbound one; what nobody knows is ignored.';

create or replace function erp_test.assert_carrier_integration_suite()
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
    from erp_test.carrier_integration_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CARRIER_INTEGRATION_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A shipment would be booked with nobody, or a key would leave the vault. Read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_CARRIER_INTEGRATION_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('carrier integration: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_carrier_integration_suite() from public, anon;

comment on function erp_test.assert_carrier_integration_suite() is
  'Carriers are booked through the organisation''s own provider account, and tracking comes back, '
  'without a key leaving the vault (20261004950000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- H. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The carrier account and a shipment''s tracking (20261004950000).'
  from (values
    ('Carrier account'),
    ('Book carriers through your own EasyPost account: labels and tracking come from the carriers'' own systems. The key is kept in the vault, never on a screen.'),
    ('Connected'),
    ('Not connected'),
    ('Test mode'),
    ('Live'),
    ('Webhook address'),
    ('Add this address in EasyPost under Webhooks, with the signing secret you give here.'),
    ('Connect EasyPost'),
    ('Connect your EasyPost account'),
    ('Paste the API key from your EasyPost dashboard: a test key (EZTK…) to try it, a live key (EZAK…) to ship. It goes straight to the vault.'),
    ('API key'),
    ('Webhook signing secret'),
    ('Optional. The secret EasyPost shows for your webhook, so tracking can reach shipments.'),
    ('Connect'),
    ('Disconnect'),
    ('Link a carrier to EasyPost'),
    ('Books this carrier through your EasyPost account, using the carrier account EasyPost gave it.'),
    ('Carrier account at EasyPost'),
    ('ca_…'),
    ('Link'),
    ('Tracking status'),
    ('Label'),
    ('Open the label'),
    ('EZTK…'),
    ('No more bookings through EasyPost. Connecting again takes a new key.'),
    ('Label printed'),
    ('In transit'),
    ('Out for delivery'),
    ('Ready to collect'),
    ('Delivered'),
    ('Returning to sender'),
    ('Delivery failed'),
    ('Cancelled'),
    ('Not yet tracked'),
    ('Leave empty when the carrier is booked through EasyPost: its label brings one.'),
    ('Weight (g)'),
    ('12500'),
    ('The consignment as weighed. Leave empty to take the items'' own weights; a carrier booked through EasyPost needs one or the other.'),
    ('Set a site''s address'),
    ('The postal address carriers label parcels from and deliver to. A label cannot be bought for a site without one.'),
    ('First line'),
    ('1 Dock Road'),
    ('Second line'),
    ('Unit 4'),
    ('Optional.'),
    ('Town'),
    ('London'),
    ('County or state'),
    ('Greater London'),
    ('Optional, except where the country''s carriers need one.'),
    ('Postcode'),
    ('E16 1AA'),
    ('Country'),
    ('Address'),
    ('No address yet'),
    ('Incomplete')
  ) as v(text)
on conflict (key, locale) do nothing;

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
select erp.assert_every_transition_is_driven();
