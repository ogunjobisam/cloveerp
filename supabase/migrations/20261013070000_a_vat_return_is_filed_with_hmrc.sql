-- A VAT return is filed with HMRC.
--
-- HMRC MTD, theme 2 of the post-v1 programme (owner, 13 October 2026). A
-- finalised VAT return was exported for bridging software and the filing
-- reference typed into its notes. Now a company is connected to HMRC, its
-- obligations are read from HMRC, and its finalised return is submitted from
-- the VAT screen, with HMRC's receipt kept.
--
-- ── DECISIONS (mine, under the standing approval of 13 October) ─────────────
--
--   * HMRC is called by an Edge Function, supabase/functions/hmrc, in each
--     client's own project: it holds HMRC's client id and secret as function
--     secrets and this project's service key. Never the browser, never the
--     application's Worker. Sandbox unless HMRC_ENVIRONMENT says production.
--   * The person's own signed-in call opens a single-use ticket here, so the
--     database decides who may connect, read obligations and submit: whoever
--     may close the books (finance.close_period), as for finalising. The
--     function then acts only within that ticket, through doors service_role
--     alone may execute.
--   * Tokens are kept per company, a VAT number being a company's, in Supabase
--     Vault: never a table, never a log. A refresh token works once, so every
--     refresh keeps the new one.
--   * A return is submitted against the obligation HMRC holds for the same
--     dates, with HMRC's legal declaration ticked; HMRC's receipt is kept,
--     append-only, beside the return.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.hmrc_connection, erp.hmrc_ticket, erp.hmrc_obligation and
--      erp.vat_submission.
--   B. For the person: public.erp_hmrc_open_ticket, erp_hmrc_status,
--      erp_hmrc_disconnect.
--   C. For the function alone: public.erp_hmrc_ticket, erp_hmrc_store_tokens,
--      erp_hmrc_record_obligations, erp_hmrc_record_submission,
--      erp_hmrc_close_ticket.
--   D. /hmrc is reserved, as the relay HMRC returns to.
--   E. erp_test.hmrc_suite proves A to C.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The tables
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.hmrc_connection (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references erp.tenant(id) on delete cascade,
  entity_id            uuid not null references erp.entity(id) on delete cascade,
  vrn                  text not null,
  environment          text not null,
  access_ref           text,
  refresh_ref          text,
  access_expires_at    timestamptz,
  refresh_expires_at   timestamptz,
  scope                text,
  status               text not null default 'connected',
  connected_by         uuid,
  connected_at         timestamptz not null default now(),
  refreshed_at         timestamptz,
  disconnected_by      uuid,
  disconnected_at      timestamptz,
  disconnected_reason  text,
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  constraint hmrc_connection_tenant_id_id_key unique (tenant_id, id),
  constraint hmrc_connection_vrn_shape check (vrn ~ '^\d{9}$'),
  constraint hmrc_connection_environment_known check (environment in ('sandbox', 'production')),
  constraint hmrc_connection_status_known check (status in ('connected', 'disconnected')),
  constraint hmrc_connection_refs_are_vault check (coalesce(access_ref, 'vault://') like 'vault://%'
                                                   and coalesce(refresh_ref, 'vault://') like 'vault://%')
);
create unique index if not exists hmrc_connection_one_per_company
  on erp.hmrc_connection (tenant_id, entity_id) where status = 'connected';

create table if not exists erp.hmrc_ticket (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  entity_id         uuid not null references erp.entity(id) on delete cascade,
  principal_id      uuid not null,
  purpose           text not null,
  vrn               text not null,
  document_id       uuid,
  return_host       text,
  body              jsonb,
  period_start      date,
  period_end        date,
  declared_at       timestamptz,
  expires_at        timestamptz not null default now() + interval '10 minutes',
  used_at           timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint hmrc_ticket_tenant_id_id_key unique (tenant_id, id),
  constraint hmrc_ticket_purpose_known check (purpose in ('connect', 'obligations', 'submit')),
  constraint hmrc_ticket_submit_is_declared check (purpose <> 'submit'
                                                    or (document_id is not null and body is not null and declared_at is not null))
);

create table if not exists erp.hmrc_obligation (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  entity_id     uuid not null references erp.entity(id) on delete cascade,
  vrn           text not null,
  period_key    text not null,
  starts_on     date not null,
  ends_on       date not null,
  due_on        date not null,
  status        text not null,
  received_on   date,
  read_at       timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  constraint hmrc_obligation_tenant_id_id_key unique (tenant_id, id),
  constraint hmrc_obligation_once unique (tenant_id, entity_id, period_key),
  constraint hmrc_obligation_status_known check (status in ('O', 'F'))
);

create table if not exists erp.vat_submission (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant(id) on delete cascade,
  entity_id           uuid not null references erp.entity(id) on delete cascade,
  document_id         uuid not null,
  vrn                 text not null,
  period_key          text not null,
  environment         text not null,
  body                jsonb not null,
  declaration         text not null,
  declared_by         uuid not null,
  declared_at         timestamptz not null,
  outcome             text not null,
  processing_date     text,
  form_bundle_number  text,
  payment_indicator   text,
  charge_ref_number   text,
  receipt_id          text,
  receipt_timestamp   text,
  correlation_id      text,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint vat_submission_tenant_id_id_key unique (tenant_id, id),
  constraint vat_submission_once unique (tenant_id, document_id),
  constraint vat_submission_outcome_known check (outcome in ('accepted', 'already_held')),
  constraint vat_submission_accepted_has_receipt check (outcome <> 'accepted' or form_bundle_number is not null)
);

comment on table erp.hmrc_connection is
  'A company connected to HMRC for Making Tax Digital for VAT (20261013070000): its VAT number, sandbox or production, '
  'and Vault references to its tokens; never the tokens themselves.';
comment on table erp.hmrc_ticket is
  'A single-use ticket a person''s own call opens for the HMRC function to act within (20261013070000): connect, read '
  'obligations, or submit one finalised return with the declaration ticked. Ten minutes.';
comment on table erp.hmrc_obligation is
  'A VAT obligation as HMRC holds it, with the period key a return is submitted against (20261013070000).';
comment on table erp.vat_submission is
  'A VAT return submitted to HMRC (20261013070000): what was sent, who declared it, and HMRC''s receipt. Append-only.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'hmrc_connection', 'tenant_scoped', 'A company''s connection to HMRC; tokens in Vault by reference only.'),
  ('erp', 'hmrc_ticket', 'tenant_scoped', 'A single-use ticket for the HMRC function, opened by a person''s own call.'),
  ('erp', 'hmrc_obligation', 'tenant_scoped', 'A VAT obligation as HMRC holds it, refreshed when read again.'),
  ('erp', 'vat_submission', 'tenant_scoped_append_only', 'A VAT return as submitted to HMRC, with its receipt; never changed.')
on conflict (schema_name, table_name) do nothing;

-- The company's VAT number as HMRC takes it, from its registration in force.
create or replace function erp.company_vrn(p_entity_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(regexp_replace(regexp_replace(upper(g.registration_number), '^GB', ''), '\s', '', 'g'), '')
    from erp.entity_tax_registration g
   where g.tenant_id = erp.require_tenant_id() and g.entity_id = p_entity_id
     and upper(g.registration_type) like 'VAT%'
     and g.valid_from <= current_date and (g.valid_to is null or g.valid_to >= current_date)
   order by g.valid_from desc, g.created_at desc
   limit 1
$$;
revoke all on function erp.company_vrn(uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. For the person
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.hmrc_open_ticket(p_purpose text, p_entity_id uuid default null,
                                                p_document_id uuid default null, p_return_host text default null,
                                                p_declaration boolean default false)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid := p_entity_id;
  v_vrn    text;
  d        erp.document%rowtype;
  r        jsonb;
  v_export jsonb;
  v_id     uuid;
begin
  if p_purpose = 'submit' then
    select doc.* into d from erp.document doc
      join erp.document_type dt on dt.tenant_id = doc.tenant_id and dt.id = doc.document_type_id
     where doc.tenant_id = v_tenant and doc.id = p_document_id and dt.base_type_code = 'vat_return';
    v_entity := d.entity_id;
  end if;
  perform erp.authorise('finance.close_period', v_entity, null, null, 'hmrc', p_document_id, null);

  if coalesce(p_purpose, '') not in ('connect', 'obligations', 'submit') then
    raise exception 'CLOVEERP_HMRC_PURPOSE_UNKNOWN: HMRC is connected, read or submitted to, not %', p_purpose
      using errcode = '22023', hint = 'Use Connect to HMRC, Read obligations from HMRC or Submit to HMRC on the VAT screen.';
  end if;
  if not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.id = v_entity) then
    raise exception 'CLOVEERP_HMRC_COMPANY_UNKNOWN: there is no such company, or no such VAT return'
      using errcode = '23503', hint = 'Choose a company, or a finalised return, from the VAT screen.';
  end if;

  v_vrn := erp.company_vrn(v_entity);
  if v_vrn is null or v_vrn !~ '^\d{9}$' then
    raise exception 'CLOVEERP_HMRC_NO_VAT_NUMBER: the company has no nine-digit VAT registration number in force'
      using errcode = '23514', hint = 'Give the company its VAT registration number on its record, then connect it to HMRC.';
  end if;

  if p_purpose in ('obligations', 'submit')
     and not exists (select 1 from erp.hmrc_connection c
                      where c.tenant_id = v_tenant and c.entity_id = v_entity and c.status = 'connected') then
    raise exception 'CLOVEERP_HMRC_NOT_CONNECTED: the company is not connected to HMRC'
      using errcode = '23514', hint = 'Press Connect to HMRC on the VAT screen and sign in with the business''s HMRC account.';
  end if;

  if p_purpose = 'connect' then
    if p_return_host is null or lower(p_return_host) !~ '^[a-z0-9.-]+$' then
      raise exception 'CLOVEERP_HMRC_PURPOSE_UNKNOWN: connecting needs the address to come back to'
        using errcode = '22023', hint = 'Connect from the VAT screen, which names its own address.';
    end if;
  end if;

  if p_purpose = 'submit' then
    if exists (select 1 from erp.vat_submission s where s.tenant_id = v_tenant and s.document_id = d.id) then
      raise exception 'CLOVEERP_HMRC_ALREADY_SUBMITTED: % has been submitted to HMRC', d.document_number
        using errcode = '23505', hint = 'Its receipt is on the VAT screen. Correct an error by posting the correction, which the next return takes.';
    end if;
    if not coalesce(p_declaration, false) then
      raise exception 'CLOVEERP_HMRC_DECLARATION_NEEDED: a return is submitted only with HMRC''s declaration agreed'
        using errcode = '23514', hint = 'Read the declaration and tick it, then submit.';
    end if;
    -- The MTD body of the finalised return, as its export writes it; the
    -- export refuses a return that is not finalised or whose records changed.
    v_export := erp.vat_return_export(d.id, 'json');
    r := d.attributes -> 'vat_return';
  end if;

  insert into erp.hmrc_ticket (tenant_id, entity_id, principal_id, purpose, vrn, document_id, return_host,
                               body, period_start, period_end, declared_at)
  values (v_tenant, v_entity, erp.current_principal_id(), p_purpose, v_vrn,
          case when p_purpose = 'submit' then d.id end,
          case when p_purpose = 'connect' then lower(p_return_host) end,
          case when p_purpose = 'submit' then (v_export ->> 'body')::jsonb end,
          case when p_purpose = 'submit' then (r ->> 'period_start')::date end,
          case when p_purpose = 'submit' then (r ->> 'period_end')::date end,
          case when p_purpose = 'submit' then clock_timestamp() end)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function erp.hmrc_open_ticket(text, uuid, uuid, text, boolean) from public, anon;

create or replace function public.erp_hmrc_open_ticket(p_purpose text, p_entity_id uuid default null,
                                                       p_document_id uuid default null, p_return_host text default null,
                                                       p_declaration boolean default false)
returns uuid
language sql
set search_path = ''
as $$ select erp.hmrc_open_ticket(p_purpose, p_entity_id, p_document_id, p_return_host, p_declaration) $$;
revoke all on function public.erp_hmrc_open_ticket(text, uuid, uuid, text, boolean) from public, anon;
grant execute on function public.erp_hmrc_open_ticket(text, uuid, uuid, text, boolean) to authenticated, service_role;
comment on function public.erp_hmrc_open_ticket(text, uuid, uuid, text, boolean) is
  'Opens a single-use ticket for the HMRC function to connect a company, read its obligations, or submit one finalised '
  'return with HMRC''s declaration agreed (20261013070000). Authorises finance.close_period.';

create or replace function public.erp_hmrc_status()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Each company: whether it is connected to HMRC and since when, the
  -- obligations HMRC holds as last read, and the returns submitted, with
  -- HMRC's receipt (20261013070000). No token, nor any reference to one.
  select coalesce(jsonb_agg(jsonb_build_object(
           'entity_id', e.id, 'company', e.code || ' ' || e.name, 'vrn', erp.company_vrn(e.id),
           'connection', (select jsonb_build_object('environment', c.environment, 'connected_at', c.connected_at,
                                                    'connected_by', (select u.display_name from erp.app_user u where u.id = c.connected_by),
                                                    'refreshed_at', c.refreshed_at)
                            from erp.hmrc_connection c
                           where c.tenant_id = e.tenant_id and c.entity_id = e.id and c.status = 'connected'),
           'obligations', coalesce((select jsonb_agg(jsonb_build_object(
                                             'period_key', o.period_key, 'starts_on', o.starts_on, 'ends_on', o.ends_on,
                                             'due_on', o.due_on, 'status', o.status, 'received_on', o.received_on,
                                             'read_at', o.read_at) order by o.ends_on desc)
                                      from erp.hmrc_obligation o
                                     where o.tenant_id = e.tenant_id and o.entity_id = e.id), '[]'::jsonb),
           'submissions', coalesce((select jsonb_agg(jsonb_build_object(
                                             'document_id', s.document_id,
                                             'document_number', (select d.document_number from erp.document d where d.id = s.document_id),
                                             'period_key', s.period_key, 'environment', s.environment,
                                             'outcome', s.outcome, 'processing_date', s.processing_date,
                                             'form_bundle_number', s.form_bundle_number,
                                             'payment_indicator', s.payment_indicator,
                                             'charge_ref_number', s.charge_ref_number,
                                             'declared_at', s.declared_at,
                                             'declared_by', (select u.display_name from erp.app_user u where u.id = s.declared_by))
                                             order by s.declared_at desc)
                                      from erp.vat_submission s
                                     where s.tenant_id = e.tenant_id and s.entity_id = e.id), '[]'::jsonb))
         order by e.code), '[]'::jsonb)
    from erp.entity e
   where e.tenant_id = erp.current_tenant_id() and e.status = 'active'
$$;
revoke all on function public.erp_hmrc_status() from public, anon;
grant execute on function public.erp_hmrc_status() to authenticated, service_role;
comment on function public.erp_hmrc_status() is
  'Each company''s connection to HMRC, the obligations HMRC holds as last read, and the returns submitted with HMRC''s '
  'receipt (20261013070000). Reads only; no token.';

-- Disconnecting forgets the tokens: definer, because only the vault's owner
-- may delete a secret; gated like connecting.
create or replace function erp.hmrc_disconnect(p_entity_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  c        erp.hmrc_connection%rowtype;
begin
  perform erp.authorise('finance.close_period', p_entity_id, null, null, 'hmrc', null, null);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_HMRC_DISCONNECT_NEEDS_A_REASON: disconnecting from HMRC needs a reason'
      using errcode = '23514', hint = 'Say why the company is disconnected, so the next person knows.';
  end if;
  select x.* into c from erp.hmrc_connection x
   where x.tenant_id = v_tenant and x.entity_id = p_entity_id and x.status = 'connected' for update;
  if c.id is null then
    raise exception 'CLOVEERP_HMRC_NOT_CONNECTED: the company is not connected to HMRC'
      using errcode = '23514', hint = 'Nothing to disconnect; Connect to HMRC on the VAT screen when it is needed.';
  end if;
  perform erp.forget_hmrc_secret(c.access_ref);
  perform erp.forget_hmrc_secret(c.refresh_ref);
  update erp.hmrc_connection x
     set status = 'disconnected', access_ref = null, refresh_ref = null,
         disconnected_by = erp.current_principal_id(), disconnected_at = now(),
         disconnected_reason = btrim(p_reason), updated_at = now()
   where x.tenant_id = v_tenant and x.id = c.id;
  perform erp.append_event('hmrc.disconnected', 'hmrc_connection', c.id,
                           jsonb_build_object('vrn', c.vrn, 'environment', c.environment, 'reason', btrim(p_reason)),
                           p_entity_id);
  return jsonb_build_object('entity_id', p_entity_id, 'disconnected', true);
end;
$$;
revoke all on function erp.hmrc_disconnect(uuid, text) from public, anon;

create or replace function public.erp_hmrc_disconnect(p_entity_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.hmrc_disconnect(p_entity_id, p_reason) $$;
revoke all on function public.erp_hmrc_disconnect(uuid, text) from public, anon;
grant execute on function public.erp_hmrc_disconnect(uuid, text) to authenticated, service_role;
comment on function public.erp_hmrc_disconnect(uuid, text) is
  'Disconnects a company from HMRC with a reason, forgetting its tokens (20261013070000). Authorises finance.close_period.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. For the function alone
-- ─────────────────────────────────────────────────────────────────────────────

-- A secret into Vault, and out of it, by reference; no vault, nothing kept.
create or replace function erp.keep_hmrc_secret(p_tenant uuid, p_label text, p_value text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault') then
    raise exception 'CLOVEERP_SECRET_STORE_UNAVAILABLE: this database has no vault to keep the secret in'
      using errcode = '55000', hint = 'Enable Supabase Vault for the project, then connect the company to HMRC again.';
  end if;
  execute 'select vault.create_secret($1, $2, $3)' into v_id
    using p_value, 'cloveerp:' || p_tenant::text || ':hmrc:' || p_label || ':' || gen_random_uuid()::text,
          'An HMRC token of organisation ' || p_tenant::text || ' (' || p_label || ').';
  return 'vault://' || v_id::text;
end;
$$;
revoke all on function erp.keep_hmrc_secret(uuid, text, text) from public, anon, authenticated;

create or replace function erp.read_hmrc_secret(p_ref text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_value text;
begin
  if p_ref is null or p_ref not like 'vault://%'
     or not exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault') then
    return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where id = $1 and name like $2'
    into v_value using substr(p_ref, 9)::uuid, 'cloveerp:%:hmrc:%';
  return v_value;
end;
$$;
revoke all on function erp.read_hmrc_secret(text) from public, anon, authenticated;

create or replace function erp.forget_hmrc_secret(p_ref text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_ref is null or p_ref not like 'vault://%'
     or not exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault') then
    return;
  end if;
  execute 'delete from vault.secrets where id = $1 and name like $2' using substr(p_ref, 9)::uuid, 'cloveerp:%:hmrc:%';
end;
$$;
revoke all on function erp.forget_hmrc_secret(text) from public, anon, authenticated;

-- The ticket the function was handed: refused unless it is open and within
-- its ten minutes. Sets the job tenant, so what follows is in its
-- organisation.
create or replace function erp.hmrc_ticket_in_force(p_ticket uuid)
returns erp.hmrc_ticket
language plpgsql
set search_path = ''
as $$
declare
  t erp.hmrc_ticket%rowtype;
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not act on an HMRC ticket', current_user
      using errcode = '42501';
  end if;
  select x.* into t from erp.hmrc_ticket x where x.id = p_ticket for update;
  if t.id is null or t.used_at is not null or t.expires_at < now() then
    raise exception 'CLOVEERP_HMRC_TICKET_NOT_IN_FORCE: the request to HMRC has expired or was already used'
      using errcode = '23514', hint = 'Press the button on the VAT screen again.';
  end if;
  perform erp.set_job_tenant(t.tenant_id);
  return t;
end;
$$;
revoke all on function erp.hmrc_ticket_in_force(uuid) from public, anon, authenticated;

create or replace function public.erp_hmrc_ticket(p_ticket uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t erp.hmrc_ticket%rowtype;
  c erp.hmrc_connection%rowtype;
begin
  t := erp.hmrc_ticket_in_force(p_ticket);
  select x.* into c from erp.hmrc_connection x
   where x.tenant_id = t.tenant_id and x.entity_id = t.entity_id and x.status = 'connected';
  return jsonb_build_object(
    'ticket', t.id, 'purpose', t.purpose, 'tenant_id', t.tenant_id, 'entity_id', t.entity_id, 'vrn', t.vrn,
    'auth_user_id', (select u.auth_user_id from erp.app_user u where u.id = t.principal_id),
    'user_email', (select u.email from erp.app_user u where u.id = t.principal_id),
    'return_host', t.return_host, 'document_id', t.document_id, 'body', t.body,
    'period_start', t.period_start, 'period_end', t.period_end,
    'environment', c.environment,
    'access_token', erp.read_hmrc_secret(c.access_ref),
    'refresh_token', erp.read_hmrc_secret(c.refresh_ref),
    'access_expires_at', c.access_expires_at, 'refresh_expires_at', c.refresh_expires_at);
end;
$$;
revoke all on function public.erp_hmrc_ticket(uuid) from public, anon, authenticated;
grant execute on function public.erp_hmrc_ticket(uuid) to service_role;
comment on function public.erp_hmrc_ticket(uuid) is
  'What the HMRC function may do under a ticket a person''s own call opened, with the company''s tokens '
  '(20261013070000). Executed by service_role alone, from supabase/functions/hmrc.';

create or replace function public.erp_hmrc_store_tokens(p_ticket uuid, p_access_token text, p_refresh_token text,
                                                        p_expires_in integer, p_refresh_expires_in integer,
                                                        p_scope text, p_environment text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t      erp.hmrc_ticket%rowtype;
  c      erp.hmrc_connection%rowtype;
  v_acc  text;
  v_ref  text;
begin
  t := erp.hmrc_ticket_in_force(p_ticket);
  if nullif(p_access_token, '') is null or nullif(p_refresh_token, '') is null
     or coalesce(p_environment, '') not in ('sandbox', 'production') then
    raise exception 'CLOVEERP_HMRC_TOKENS_INVALID: HMRC''s answer carried no tokens to keep'
      using errcode = '22023', hint = 'Connect the company to HMRC again.';
  end if;
  v_acc := erp.keep_hmrc_secret(t.tenant_id, 'access', p_access_token);
  v_ref := erp.keep_hmrc_secret(t.tenant_id, 'refresh', p_refresh_token);

  select x.* into c from erp.hmrc_connection x
   where x.tenant_id = t.tenant_id and x.entity_id = t.entity_id and x.status = 'connected' for update;
  if c.id is null then
    if t.purpose <> 'connect' then
      raise exception 'CLOVEERP_HMRC_NOT_CONNECTED: the company is not connected to HMRC'
        using errcode = '23514', hint = 'Press Connect to HMRC on the VAT screen.';
    end if;
    insert into erp.hmrc_connection (tenant_id, entity_id, vrn, environment, access_ref, refresh_ref,
                                     access_expires_at, refresh_expires_at, scope, connected_by)
    values (t.tenant_id, t.entity_id, t.vrn, p_environment, v_acc, v_ref,
            now() + make_interval(secs => coalesce(p_expires_in, 14400)),
            now() + make_interval(secs => coalesce(p_refresh_expires_in, 47304000)),
            p_scope, t.principal_id)
    returning * into c;
    perform erp.append_event('hmrc.connected', 'hmrc_connection', c.id,
                             jsonb_build_object('vrn', c.vrn, 'environment', c.environment), t.entity_id);
  else
    perform erp.forget_hmrc_secret(c.access_ref);
    perform erp.forget_hmrc_secret(c.refresh_ref);
    update erp.hmrc_connection x
       set access_ref = v_acc, refresh_ref = v_ref,
           access_expires_at = now() + make_interval(secs => coalesce(p_expires_in, 14400)),
           refresh_expires_at = case when t.purpose = 'connect'
                                     then now() + make_interval(secs => coalesce(p_refresh_expires_in, 47304000))
                                     else x.refresh_expires_at end,
           scope = coalesce(p_scope, x.scope), environment = p_environment,
           refreshed_at = now(), updated_at = now()
     where x.id = c.id;
  end if;
  if t.purpose = 'connect' then
    update erp.hmrc_ticket set used_at = now(), updated_at = now() where id = t.id;
  end if;
  return jsonb_build_object('entity_id', t.entity_id, 'vrn', t.vrn, 'connected', true);
end;
$$;
revoke all on function public.erp_hmrc_store_tokens(uuid, text, text, integer, integer, text, text) from public, anon, authenticated;
grant execute on function public.erp_hmrc_store_tokens(uuid, text, text, integer, integer, text, text) to service_role;
comment on function public.erp_hmrc_store_tokens(uuid, text, text, integer, integer, text, text) is
  'Keeps the tokens HMRC gave a company, in Vault, connecting it or refreshing its connection (20261013070000). '
  'Executed by service_role alone, from supabase/functions/hmrc.';

create or replace function public.erp_hmrc_record_obligations(p_ticket uuid, p_obligations jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  t   erp.hmrc_ticket%rowtype;
  o   jsonb;
  v_n integer := 0;
begin
  t := erp.hmrc_ticket_in_force(p_ticket);
  if jsonb_typeof(p_obligations) is distinct from 'array' then
    raise exception 'CLOVEERP_HMRC_OBLIGATIONS_INVALID: HMRC''s answer listed no obligations'
      using errcode = '22023', hint = 'Read the obligations from HMRC again.';
  end if;
  for o in select * from jsonb_array_elements(p_obligations) loop
    insert into erp.hmrc_obligation (tenant_id, entity_id, vrn, period_key, starts_on, ends_on, due_on, status, received_on)
    values (t.tenant_id, t.entity_id, t.vrn, o ->> 'periodKey', (o ->> 'start')::date, (o ->> 'end')::date,
            (o ->> 'due')::date, o ->> 'status', nullif(o ->> 'received', '')::date)
    on conflict (tenant_id, entity_id, period_key) do update
      set starts_on = excluded.starts_on, ends_on = excluded.ends_on, due_on = excluded.due_on,
          status = excluded.status, received_on = excluded.received_on, read_at = now(), updated_at = now();
    v_n := v_n + 1;
  end loop;
  if t.purpose = 'obligations' then
    update erp.hmrc_ticket set used_at = now(), updated_at = now() where id = t.id;
  end if;
  return v_n;
end;
$$;
revoke all on function public.erp_hmrc_record_obligations(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.erp_hmrc_record_obligations(uuid, jsonb) to service_role;
comment on function public.erp_hmrc_record_obligations(uuid, jsonb) is
  'Records the VAT obligations HMRC holds for a company, with their period keys (20261013070000). Executed by '
  'service_role alone, from supabase/functions/hmrc.';

create or replace function public.erp_hmrc_record_submission(p_ticket uuid, p_period_key text, p_body jsonb,
                                                             p_receipt jsonb, p_outcome text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t     erp.hmrc_ticket%rowtype;
  c     erp.hmrc_connection%rowtype;
  v_id  uuid;
begin
  t := erp.hmrc_ticket_in_force(p_ticket);
  if t.purpose <> 'submit' or coalesce(p_outcome, '') not in ('accepted', 'already_held')
     or nullif(p_period_key, '') is null then
    raise exception 'CLOVEERP_HMRC_SUBMISSION_INVALID: there is no submission to record under this ticket'
      using errcode = '22023', hint = 'Submit the return again from the VAT screen.';
  end if;
  select x.* into c from erp.hmrc_connection x
   where x.tenant_id = t.tenant_id and x.entity_id = t.entity_id and x.status = 'connected';
  insert into erp.vat_submission (tenant_id, entity_id, document_id, vrn, period_key, environment, body,
                                  declaration, declared_by, declared_at, outcome, processing_date,
                                  form_bundle_number, payment_indicator, charge_ref_number, receipt_id,
                                  receipt_timestamp, correlation_id)
  values (t.tenant_id, t.entity_id, t.document_id, t.vrn, p_period_key, coalesce(c.environment, 'sandbox'),
          coalesce(p_body, t.body),
          'When you submit this VAT information you are making a legal declaration that the information is true and complete. A false declaration can result in prosecution.',
          t.principal_id, t.declared_at, p_outcome,
          p_receipt ->> 'processingDate', p_receipt ->> 'formBundleNumber', p_receipt ->> 'paymentIndicator',
          p_receipt ->> 'chargeRefNumber', p_receipt ->> 'receiptId', p_receipt ->> 'receiptTimestamp',
          p_receipt ->> 'correlationId')
  returning id into v_id;
  update erp.hmrc_ticket set used_at = now(), updated_at = now() where id = t.id;
  perform erp.append_event('vat_return.submitted', 'document', t.document_id,
                           jsonb_strip_nulls(jsonb_build_object(
                             'period_key', p_period_key, 'outcome', p_outcome, 'environment', coalesce(c.environment, 'sandbox'),
                             'form_bundle_number', p_receipt ->> 'formBundleNumber',
                             'processing_date', p_receipt ->> 'processingDate')),
                           t.entity_id);
  return jsonb_build_object('submission_id', v_id, 'outcome', p_outcome,
                            'form_bundle_number', p_receipt ->> 'formBundleNumber');
end;
$$;
revoke all on function public.erp_hmrc_record_submission(uuid, text, jsonb, jsonb, text) from public, anon, authenticated;
grant execute on function public.erp_hmrc_record_submission(uuid, text, jsonb, jsonb, text) to service_role;
comment on function public.erp_hmrc_record_submission(uuid, text, jsonb, jsonb, text) is
  'Records a VAT return submitted to HMRC under its ticket, with HMRC''s receipt (20261013070000). Executed by '
  'service_role alone, from supabase/functions/hmrc.';

create or replace function public.erp_hmrc_close_ticket(p_ticket uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  t erp.hmrc_ticket%rowtype;
begin
  t := erp.hmrc_ticket_in_force(p_ticket);
  update erp.hmrc_ticket set used_at = now(), updated_at = now() where id = t.id;
end;
$$;
revoke all on function public.erp_hmrc_close_ticket(uuid) from public, anon, authenticated;
grant execute on function public.erp_hmrc_close_ticket(uuid) to service_role;
comment on function public.erp_hmrc_close_ticket(uuid) is
  'Closes an HMRC ticket the function is done with, so it cannot be used again (20261013070000). Executed by '
  'service_role alone, from supabase/functions/hmrc.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Governance
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'hmrc_disconnect',
   'Runs as its owner only to delete the company''s HMRC secrets from Vault, which only the vault''s owner may do; '
   'authorises finance.close_period first.'),
  ('erp', 'keep_hmrc_secret',
   'UNGATED BY DESIGN: executable by nobody but its owner and the HMRC doors below; writes one HMRC token into Vault '
   'named for its organisation.'),
  ('erp', 'read_hmrc_secret',
   'UNGATED BY DESIGN: executable by nobody but its owner and the HMRC doors below; reads only secrets named as HMRC '
   'tokens.'),
  ('erp', 'forget_hmrc_secret',
   'UNGATED BY DESIGN: executable by nobody but its owner and the HMRC doors; deletes only secrets named as HMRC tokens.'),
  ('public', 'erp_hmrc_ticket',
   'UNGATED BY DESIGN: the ticket is the authority, opened by the person''s own call to erp_hmrc_open_ticket, which '
   'authorises finance.close_period. Executable by service_role alone, from supabase/functions/hmrc; single-use and '
   'ten minutes. erp_test.hmrc_suite proves it.'),
  ('public', 'erp_hmrc_store_tokens',
   'UNGATED BY DESIGN: as erp_hmrc_ticket, the ticket is the authority. Executable by service_role alone.'),
  ('public', 'erp_hmrc_record_obligations',
   'UNGATED BY DESIGN: as erp_hmrc_ticket, the ticket is the authority. Executable by service_role alone.'),
  ('public', 'erp_hmrc_record_submission',
   'UNGATED BY DESIGN: as erp_hmrc_ticket, the ticket is the authority, and a submit ticket carries the declaration '
   'its person agreed. Executable by service_role alone.'),
  ('public', 'erp_hmrc_close_ticket',
   'UNGATED BY DESIGN: as erp_hmrc_ticket, the ticket is the authority. Executable by service_role alone.')
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale, ungated_because) values
  ('erp_hmrc_open_ticket', 'erp.hmrc_open_ticket',
   'Opens a single-use ticket for the HMRC function to connect a company, read its obligations or submit a finalised return; authorises finance.close_period.',
   null),
  ('erp_hmrc_disconnect', 'erp.hmrc_disconnect',
   'Disconnects a company from HMRC with a reason, forgetting its tokens; authorises finance.close_period.', null),
  ('erp_hmrc_ticket', 'erp.hmrc_ticket_in_force',
   'Reads what the HMRC function may do under a ticket its person opened, locking the ticket and naming its organisation; service_role only.',
   'bearer_token'),
  ('erp_hmrc_store_tokens', 'erp.hmrc_ticket_in_force',
   'Keeps the tokens HMRC gave a company, under a ticket its person opened; service_role only, from supabase/functions/hmrc.',
   'bearer_token'),
  ('erp_hmrc_record_obligations', 'erp.hmrc_ticket_in_force',
   'Records the obligations HMRC holds, under a ticket its person opened; service_role only, from supabase/functions/hmrc.',
   'bearer_token'),
  ('erp_hmrc_record_submission', 'erp.hmrc_ticket_in_force',
   'Records a return submitted to HMRC with its receipt, under the declared ticket its person opened; service_role only.',
   'bearer_token'),
  ('erp_hmrc_close_ticket', 'erp.hmrc_ticket_in_force',
   'Closes an HMRC ticket the function is done with; service_role only, from supabase/functions/hmrc.',
   'bearer_token')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale,
  ungated_because = excluded.ungated_because;

insert into erp_meta.reserved_tenant_code (code, reason, platform_may_hold) values
  ('hmrc', 'The relay HMRC returns to after a company is connected (/hmrc/callback, 20261013070000).', false)
on conflict do nothing;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('hmrc.connected', 1, 'hmrc_connection', 'finance', 'event.hmrc.connected',
   'A company was connected to HMRC for Making Tax Digital for VAT.',
   '{"type":"object","required":["vrn","environment"],"properties":{"vrn":{"type":"string"},"environment":{"type":"string"}}}'::jsonb, true),
  ('hmrc.disconnected', 1, 'hmrc_connection', 'finance', 'event.hmrc.disconnected',
   'A company was disconnected from HMRC, with a reason, and its tokens forgotten.',
   '{"type":"object","required":["vrn","environment","reason"],"properties":{"vrn":{"type":"string"},"environment":{"type":"string"},"reason":{"type":"string"}}}'::jsonb, true),
  ('vat_return.submitted', 1, 'document', 'finance', 'event.vat_return.submitted',
   'A finalised VAT return was submitted to HMRC, or HMRC was found to hold it already.',
   '{"type":"object","required":["period_key","outcome","environment"],"properties":{"period_key":{"type":"string"},"outcome":{"type":"string"},"environment":{"type":"string"},"form_bundle_number":{"type":"string"},"processing_date":{"type":"string"}}}'::jsonb, true)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.hmrc.connected', 'en', 'Connected to HMRC', 'finance', 'Event raised when a company is connected to HMRC.'),
  ('event.hmrc.connected', 'de', 'Mit HMRC verbunden', 'finance', 'Ereignis, wenn ein Unternehmen mit HMRC verbunden wird.'),
  ('event.hmrc.disconnected', 'en', 'Disconnected from HMRC', 'finance', 'Event raised when a company is disconnected from HMRC.'),
  ('event.hmrc.disconnected', 'de', 'Von HMRC getrennt', 'finance', 'Ereignis, wenn ein Unternehmen von HMRC getrennt wird.'),
  ('event.vat_return.submitted', 'en', 'VAT return submitted to HMRC', 'finance', 'Event raised when a VAT return is submitted to HMRC.'),
  ('event.vat_return.submitted', 'de', 'Umsatzsteuererklärung an HMRC übermittelt', 'finance', 'Ereignis, wenn eine Umsatzsteuererklärung an HMRC übermittelt wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

select erp.register_refusal('CLOVEERP_HMRC_PURPOSE_UNKNOWN',
  'Asking the HMRC connection for something it does not do, or connecting without an address to come back to.',
  'The connection does three things: connects a company, reads its obligations, submits a finalised return.',
  'Use Connect to HMRC, Read obligations from HMRC or Submit to HMRC on the VAT screen.');
select erp.register_refusal('CLOVEERP_HMRC_COMPANY_UNKNOWN',
  'Asking HMRC about a company or a VAT return this organisation does not have.',
  'A connection belongs to one of the organisation''s companies, and a submission to one of its returns.',
  'Choose a company, or a finalised return, from the VAT screen.');
select erp.register_refusal('CLOVEERP_HMRC_NO_VAT_NUMBER',
  'Connecting a company to HMRC that has no nine-digit VAT registration number in force.',
  'HMRC files VAT by the company''s registration number; without one there is nothing to connect.',
  'Give the company its VAT registration number on its record, then connect it.');
select erp.register_refusal('CLOVEERP_HMRC_NOT_CONNECTED',
  'Reading obligations, submitting or disconnecting for a company that is not connected to HMRC.',
  'Only a company connected with its HMRC account can be read or filed for.',
  'Press Connect to HMRC on the VAT screen and sign in with the business''s HMRC account.');
select erp.register_refusal('CLOVEERP_HMRC_ALREADY_SUBMITTED',
  'Submitting a VAT return that has been submitted to HMRC already.',
  'A period is returned once; a second submission would be refused by HMRC and confuse the record.',
  'Read the receipt on the VAT screen. Correct an error by posting the correction, which the next return takes.');
select erp.register_refusal('CLOVEERP_HMRC_DECLARATION_NEEDED',
  'Submitting a VAT return without agreeing HMRC''s declaration.',
  'HMRC requires the person filing to declare the return true and complete.',
  'Read the declaration and tick it, then submit.');
select erp.register_refusal('CLOVEERP_HMRC_DISCONNECT_NEEDS_A_REASON',
  'Disconnecting a company from HMRC without a reason.',
  'Disconnecting stops the company''s VAT being filed from here; the next person needs to know why.',
  'Say why the company is disconnected.');
select erp.register_refusal('CLOVEERP_HMRC_TICKET_NOT_IN_FORCE',
  'Acting on a request to HMRC that has expired or was already used.',
  'Each press opens one request, good for ten minutes, so a stale or replayed one does nothing.',
  'Press the button on the VAT screen again.');
select erp.register_refusal('CLOVEERP_HMRC_TOKENS_INVALID',
  'Keeping an answer from HMRC that carried no tokens.',
  'Without tokens nothing can be read from HMRC or filed with it.',
  'Connect the company to HMRC again.');
select erp.register_refusal('CLOVEERP_HMRC_OBLIGATIONS_INVALID',
  'Recording an answer from HMRC that listed no obligations.',
  'The obligations are what a return is submitted against.',
  'Read the obligations from HMRC again.');
select erp.register_refusal('CLOVEERP_HMRC_SUBMISSION_INVALID',
  'Recording a submission under a request that was not for one, or without HMRC''s period key or outcome.',
  'A submission is recorded once, for the return its person declared.',
  'Submit the return again from the VAT screen.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Filing VAT with HMRC on the VAT returns screen (20261013070000).'
  from (values
    ('A return takes every VAT entry dated up to its period''s end that no earlier return took, so something posted late into a finalised quarter is in the next return. Boxes 1 and 4 are the tax the ledger carries; boxes 6 and 7 are the net of the same documents, in whole pounds. Finalising freezes the boxes, and an error in a finalised return is corrected by posting the correction, which the next return takes. A company connected to HMRC submits its finalised return from here, against the period HMRC holds for the same dates, with HMRC''s declaration agreed and its receipt kept. A company that is not connected exports the return for bridging software instead: most read a spreadsheet of the nine boxes, some the MTD return body as JSON, so check which yours reads.'),
    ('Connect each company to HMRC once, with the business''s own HMRC sign-in. A finalised return is then submitted from here, against the period HMRC holds for the same dates, and HMRC''s receipt is kept with it.'),
    ('Connect the company to HMRC to submit this return.'),
    ('Connect to HMRC'),
    ('Connected to HMRC'),
    ('Connected to HMRC''s sandbox'),
    ('Declared by'),
    ('Disconnect from HMRC'),
    ('Filed with HMRC'),
    ('Finishing the connection to HMRC…'),
    ('Form bundle'),
    ('Fulfilled'),
    ('HMRC already held a return for this period.'),
    ('HMRC did not connect the company:'),
    ('HMRC period'),
    ('I agree, and this return is true and complete.'),
    ('Kept with the change for the next person.'),
    ('Not now'),
    ('Read obligations from HMRC'),
    ('Submit to HMRC'),
    ('Submitted to HMRC'),
    ('The company''s HMRC tokens are forgotten and nothing more is read or filed for it until it is connected again.'),
    ('Why it is disconnected'),
    ('When you submit this VAT information you are making a legal declaration that the information is true and complete. A false declaration can result in prosecution.')) v(text)
on conflict do nothing;

select erp_meta.add_help_actions('/finance/vat', array['erp_hmrc_open_ticket', 'erp_hmrc_disconnect']);

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.hmrc_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid;
  v_ticket uuid;
  v_t2     uuid;
  x        jsonb;
  v_ok     boolean;
  v_msg    text;
  v_vault  boolean := exists (select 1 from pg_catalog.pg_namespace where nspname = 'vault');
  v_pq_from date := (date_trunc('quarter', current_date) - interval '3 months')::date;
  v_pq_to  date := date_trunc('quarter', current_date)::date - 1;
  v_ccy    character(3);
  v_site   uuid;
  v_item   uuid;
  v_cust   uuid;
  v_inv    uuid;
  v_ret    uuid;
  v_t3     uuid;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzhmr' || v_tag, 'HMRC Suite',
      'admin@demo-zzhmr' || v_tag || '.test', 'HMRC Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzhmr' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_ent from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

    -- ── 1. A company needs its VAT number ───────────────────────────────────
    v_step := 'no VAT number';
    delete from erp.entity_tax_registration g where g.tenant_id = v_tenant and g.entity_id = v_ent;
    begin
      perform public.erp_hmrc_open_ticket('connect', v_ent, null, 'acme.cloveerp.com');
      v_ok := false; v_msg := 'connected with no VAT number';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_HMRC_NO_VAT_NUMBER%'; v_msg := left(sqlerrm, 90);
    end;
    insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction, registration_type, registration_number, valid_from)
    values (v_tenant, v_ent, 'GB', 'VAT', 'GB 123 4567 89', v_pq_from);
    v_cases := v_cases + 1;
    case_name := 'a company with no VAT number in force is not connected, and its number is read as HMRC takes it';
    passed := v_state is null and v_ok and erp.company_vrn(v_ent) = '123456789';
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. A ticket to connect ──────────────────────────────────────────────
    v_step := 'a ticket to connect';
    v_ticket := public.erp_hmrc_open_ticket('connect', v_ent, null, 'Acme.CloveERP.com');
    begin
      perform public.erp_hmrc_open_ticket('obligations', v_ent);
      v_ok := false; v_msg := 'obligations read before connecting';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_HMRC_NOT_CONNECTED%'; v_msg := left(sqlerrm, 90);
    end;
    v_cases := v_cases + 1;
    case_name := 'a ticket to connect names the company, its number and the address to come back to; nothing is read before it connects';
    passed := v_state is null and v_ok
          and exists (select 1 from erp.hmrc_ticket t
                       where t.id = v_ticket and t.purpose = 'connect' and t.vrn = '123456789'
                         and t.return_host = 'acme.cloveerp.com' and t.expires_at > now() and t.used_at is null);
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 3. The function alone keeps the tokens ──────────────────────────────
    v_step := 'tokens';
    perform set_config('request.jwt.claims', '', true);
    x := public.erp_hmrc_ticket(v_ticket);
    if v_vault then
      perform public.erp_hmrc_store_tokens(v_ticket, 'access-1', 'refresh-1', 14400, 47304000, 'read:vat write:vat', 'sandbox');
    else
      begin
        perform public.erp_hmrc_store_tokens(v_ticket, 'access-1', 'refresh-1', 14400, 47304000, 'read:vat write:vat', 'sandbox');
        v_ok := false;
      exception when others then
        v_ok := sqlerrm like 'CLOVEERP_SECRET_STORE_UNAVAILABLE%';
      end;
      -- With no vault here, the connection is written as the doors would.
      insert into erp.hmrc_connection (tenant_id, entity_id, vrn, environment, access_ref, refresh_ref, connected_by)
      values (v_tenant, v_ent, '123456789', 'sandbox', 'vault://' || gen_random_uuid(), 'vault://' || gen_random_uuid(), rb.admin_user_id);
      update erp.hmrc_ticket set used_at = now() where id = v_ticket;
    end if;
    v_cases := v_cases + 1;
    case_name := 'the function reads its ticket and keeps the tokens in Vault, refused where there is no vault, never in a column';
    passed := v_state is null
          and x ->> 'purpose' = 'connect' and x ->> 'vrn' = '123456789'
          and (x ->> 'auth_user_id')::uuid = a1
          and (v_vault or v_ok)
          and exists (select 1 from erp.hmrc_connection c where c.tenant_id = v_tenant and c.entity_id = v_ent
                         and c.status = 'connected' and c.access_ref like 'vault://%' and c.access_ref not like '%access-1%');
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 4. A ticket works once ──────────────────────────────────────────────
    v_step := 'a used ticket';
    begin
      perform public.erp_hmrc_ticket(v_ticket);
      v_ok := false; v_msg := 'a used ticket read again';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_HMRC_TICKET_NOT_IN_FORCE%'; v_msg := left(sqlerrm, 90);
    end;
    v_cases := v_cases + 1;
    case_name := 'a ticket is good once, and for ten minutes';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 5. Obligations as HMRC holds them ───────────────────────────────────
    v_step := 'obligations';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_t2 := public.erp_hmrc_open_ticket('obligations', v_ent);
    perform set_config('request.jwt.claims', '', true);
    perform public.erp_hmrc_record_obligations(v_t2, '[{"start":"2017-01-01","end":"2017-03-31","due":"2017-05-07","status":"F","periodKey":"18A1","received":"2017-05-06"},{"start":"2017-04-01","end":"2017-06-30","due":"2017-08-07","status":"O","periodKey":"18A2"}]'::jsonb);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    x := public.erp_hmrc_status();
    v_cases := v_cases + 1;
    case_name := 'the obligations HMRC holds are kept with their period keys, and the status names the connection without a token';
    passed := v_state is null
          and (select count(*) from erp.hmrc_obligation o where o.tenant_id = v_tenant and o.entity_id = v_ent) = 2
          and exists (select 1 from jsonb_array_elements(x) e
                       where e ->> 'entity_id' = v_ent::text and e -> 'connection' ->> 'environment' = 'sandbox'
                         and jsonb_array_length(e -> 'obligations') = 2)
          and position('vault://' in x::text) = 0;
    detail := coalesce(v_state, left(x::text, 200));
    return next;

    -- ── 6. Submitting asks for the declaration and a finalised return ───────
    v_step := 'submitting';
    begin
      perform public.erp_hmrc_open_ticket('submit', null, gen_random_uuid(), null, true);
      v_ok := false; v_msg := 'a return that is not one was ticketed';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_HMRC_COMPANY_UNKNOWN%' or sqlerrm like 'CLOVEERP_PERMISSION%';
      v_msg := left(sqlerrm, 90);
    end;
    v_cases := v_cases + 1;
    case_name := 'a submission is ticketed only for one of the organisation''s VAT returns';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 7. A finalised return, submitted with the declaration ───────────────
    v_step := 'a finalised return of last quarter';
    select l.currency into v_ccy from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_ent and l.is_primary;
    select st.id into v_site from erp.site st where st.tenant_id = v_tenant order by st.code limit 1;
    select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (v_tenant, 'ZZHMCUST', 'HMRC suite customer', 'GB', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (v_tenant, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    v_inv := erp.create_document('sales_invoice', v_ent, v_site, v_cust, current_date, v_ccy, 'ZZHM-A', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_item, 1, 50000, 'supplied last quarter');
    perform erp.set_invoice_tax_point(v_inv, v_pq_to);
    perform erp.transition_document(v_inv, 'issue', 'hmrc suite');
    v_ret := (public.erp_finalise_vat_return(v_ent, v_pq_to) ->> 'document_id')::uuid;
    begin
      perform public.erp_hmrc_open_ticket('submit', null, v_ret, null, false);
      v_ok := false; v_msg := 'submitted without the declaration';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_HMRC_DECLARATION_NEEDED%'; v_msg := left(sqlerrm, 90);
    end;
    v_t3 := public.erp_hmrc_open_ticket('submit', null, v_ret, null, true);
    perform set_config('request.jwt.claims', '', true);
    x := public.erp_hmrc_ticket(v_t3);
    perform public.erp_hmrc_record_submission(v_t3, '18A2', null,
      '{"processingDate":"2018-01-16T08:20:27.895+0000","formBundleNumber":"256660290587","paymentIndicator":"BANK","receiptId":"2dd537bc-4244-4ebf-bac9-96321be13cdc"}'::jsonb,
      'accepted');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a finalised return is submitted only with the declaration, its ticket carries its MTD body, and HMRC''s receipt is kept';
    passed := v_state is null and v_ok
          and x ->> 'purpose' = 'submit' and (x ->> 'period_end')::date = v_pq_to
          and (x -> 'body' ->> 'vatDueSales') is not null and (x -> 'body' ->> 'finalised')::boolean
          and exists (select 1 from erp.vat_submission su
                       where su.document_id = v_ret and su.outcome = 'accepted' and su.form_bundle_number = '256660290587'
                         and su.declared_by = rb.admin_user_id and su.period_key = '18A2')
          and exists (select 1 from erp.event ev where ev.tenant_id = v_tenant and ev.event_type = 'vat_return.submitted'
                         and ev.aggregate_id = v_ret);
    detail := coalesce(v_state, v_msg || ' | ' || left(coalesce(x::text, ''), 120));
    return next;

    -- ── 8. Once ─────────────────────────────────────────────────────────────
    v_step := 'submitted again';
    begin
      perform public.erp_hmrc_open_ticket('submit', null, v_ret, null, true);
      v_ok := false; v_msg := 'submitted twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_HMRC_ALREADY_SUBMITTED%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      update erp.vat_submission set form_bundle_number = 'changed' where document_id = v_ret;
      v_ok := false; v_msg := v_msg || ' | a receipt changed';
    exception when others then
      v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    v_cases := v_cases + 1;
    case_name := 'a return is submitted once, and its receipt is never changed';
    passed := v_state is null and v_ok
          and (select su.form_bundle_number from erp.vat_submission su where su.document_id = v_ret) = '256660290587';
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 9. The function alone may act ───────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the doors the function uses are executable by service_role alone, and the person''s doors by a signed-in person';
    passed := v_state is null
          and not has_function_privilege('authenticated', 'public.erp_hmrc_ticket(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'public.erp_hmrc_store_tokens(uuid,text,text,integer,integer,text,text)', 'execute')
          and not has_function_privilege('authenticated', 'public.erp_hmrc_record_submission(uuid,text,jsonb,jsonb,text)', 'execute')
          and has_function_privilege('service_role', 'public.erp_hmrc_record_submission(uuid,text,jsonb,jsonb,text)', 'execute')
          and has_function_privilege('authenticated', 'public.erp_hmrc_open_ticket(text,uuid,uuid,text,boolean)', 'execute')
          and not has_function_privilege('anon', 'public.erp_hmrc_status()', 'execute');
    detail := coalesce(v_state, 'privileges as designed');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_HMRC_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.hmrc_suite() from public, anon, authenticated;

create or replace function erp_test.assert_hmrc_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _hmrc on commit drop as
    select * from erp_test.hmrc_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _hmrc;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_HMRC_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_HMRC_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('hmrc: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_hmrc_suite() from public, anon, authenticated;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
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
select erp.assert_write_only_columns();
