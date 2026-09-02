-- =============================================================================
-- §9.4: personal data in an immutable store
--
-- The specification states the position rather than discovering it: tenant
-- deletion is key destruction; erasure of an individual inside a live tenant
-- is in tension with an append-only store, so "events carry references,
-- never personal data; the reference remains and the referent is destroyed,
-- leaving the ledger arithmetically intact and the individual unidentifiable".
--
-- What existed: tenant deletion (Tenancy Part 1) and nothing per subject. What
-- this adds, in the house shape:
--
--   a register, erp_ref.personal_data_field — every column that holds a
--   person's identifying data, which subject it belongs to, how a row is tied
--   to that subject, and what erasure does to it: overwrite with a
--   placeholder, set null, or redact a copy. A second register,
--   erp_ref.personal_data_exemption, names the columns that look personal
--   and are not erased, each with the reason. The build sweeps the catalogue
--   for a column that looks personal and is in neither, so a new column
--   cannot quietly hold a name nobody can erase;
--
--   a request, erp.erasure_request — who is to be erased, why, who asked, and
--   the certificate of what was done. Executed by a second person, never the
--   one who asked;
--
--   the referent destroyed. The subject's own rows are overwritten from the
--   register. The copies the ledger holds — the actor label an audit entry
--   and an event carry, the before and after states of the subject's own
--   rows, the payload of the subject's events — are redacted in place, and
--   that is the one mutation the append-only guard permits: only during an
--   executed erasure, only through the SECURITY DEFINER sweep, and only to
--   columns the register names as copies. A row's ids, amounts, dates and
--   every other column stay as they were, so the ledger still adds up and
--   still says who, by reference, did what.
--
-- What is honestly not here: a separately keyed store the mutable columns
-- live in. The register is the store's index and the placeholder overwrite is
-- its erasure; moving the columns themselves behind a per-subject key is a
-- change to every table that holds a name and is not this migration.
-- =============================================================================

-- ── The registers ────────────────────────────────────────────────────────────

create table if not exists erp_ref.personal_data_field (
  schema_name    text not null,
  table_name     text not null,
  column_name    text not null,
  -- Whose data: a principal (erp.app_user), a business partner's contact
  -- (erp.party_contact), or any subject for a column that copies both.
  subject_kind   text not null check (subject_kind in ('principal', 'contact', 'any')),
  -- The column on the row that names the subject: the row's own id on the
  -- subject's table, actor_id on a ledger row, object_id on an audit entry.
  subject_column text not null,
  erasure        text not null check (erasure in ('placeholder', 'null', 'redact_copy')),
  -- For placeholder: a template with {id} for the subject's id, so a unique
  -- column stays unique and a not-null column stays not null.
  placeholder    text,
  note           text not null,
  primary key (schema_name, table_name, column_name),
  check (erasure <> 'placeholder' or placeholder is not null)
);

comment on table erp_ref.personal_data_field is
  'Specification v1.2 §9.4. Every column that holds a person''s identifying '
  'data, which subject it belongs to, and what erasure does to it. The '
  'subject''s own rows are overwritten; copies in append-only tables are '
  'redacted by erp.erase_subject_copies(), the one mutation '
  'erp.forbid_mutation() permits. Checked against the catalogue by '
  'erp.assert_personal_data_register_sound().';

create table if not exists erp_ref.personal_data_exemption (
  schema_name text not null,
  table_name  text not null,
  column_name text not null,
  rationale   text not null,
  primary key (schema_name, table_name, column_name)
);

comment on table erp_ref.personal_data_exemption is
  '§9.4. Columns whose names look personal and are not erased per subject, '
  'each with the reason: a site''s address, a suppression record that must '
  'outlive the address it suppresses, platform staff records that are the '
  'platform owner''s to erase.';

select erp_meta.register_table('erp_ref', 'personal_data_field', 'product_content',
  '§9.4. Which columns hold personal data and how erasure treats each.');
select erp_meta.register_table('erp_ref', 'personal_data_exemption', 'product_content',
  '§9.4. Columns that look personal and are deliberately not erased per subject.');

-- ── The request ──────────────────────────────────────────────────────────────

create table if not exists erp.erasure_request (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant (id) on delete cascade,
  subject_kind   text not null check (subject_kind in ('principal', 'contact')),
  subject_id     uuid not null,
  -- How the subject was known when the request was made. Overwritten by the
  -- erasure itself, so the request does not outlive the name it erased.
  subject_label  text not null,
  reason         text not null,
  status         text not null default 'requested'
    check (status in ('requested', 'executed', 'refused')),
  requested_by   uuid,
  executed_by    uuid,
  executed_at    timestamptz,
  refused_reason text,
  -- What was done: per column, how many rows; per copy, how many redacted.
  certificate    jsonb,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  unique (tenant_id, id)
);

comment on table erp.erasure_request is
  '§9.4. A request to erase one data subject, executed by a second person, '
  'with the certificate of what was overwritten and what was redacted.';

select erp_meta.register_table('erp', 'erasure_request', 'tenant_scoped',
  '§9.4. Per-subject erasure requests and their certificates.');

insert into erp_ref.personal_data_field
  (schema_name, table_name, column_name, subject_kind, subject_column, erasure, placeholder, note)
values
  -- The subject's own rows.
  ('erp', 'app_user', 'display_name', 'principal', 'id', 'placeholder', 'Erased principal {id}',
   'The name shown wherever the principal acted. Placeholder keeps the row and its references.'),
  ('erp', 'app_user', 'email', 'principal', 'id', 'placeholder', 'erased-{id}@erased.invalid',
   'Unique per organisation and required for a person, so a placeholder that carries the id rather than null.'),
  ('erp', 'party_contact', 'name', 'contact', 'id', 'placeholder', 'Erased contact {id}',
   'A named person at a business partner.'),
  ('erp', 'party_contact', 'email', 'contact', 'id', 'null', null, 'Optional; nulled.'),
  ('erp', 'party_contact', 'phone', 'contact', 'id', 'null', null, 'Optional; nulled.'),
  ('erp', 'party_contact', 'role_title', 'contact', 'id', 'null', null,
   'A job title identifies a person at a small organisation; nulled.'),
  ('erp', 'party_contact', 'notes', 'contact', 'id', 'null', null,
   'Free text about a person; nulled.'),
  ('erp', 'erasure_request', 'subject_label', 'any', 'subject_id', 'placeholder', 'Erased {id}',
   'The name as it was when the request was made, overwritten when the request executes.'),
  -- Copies the ledger holds. Redacted in place by the sweep; the row stays.
  ('erp', 'audit_entry', 'actor_label', 'principal', 'actor_id', 'redact_copy', null,
   'The actor''s display name copied onto every audit entry; actor_id remains.'),
  ('erp', 'audit_entry', 'before_state', 'any', 'object_id', 'redact_copy', null,
   'The subject''s own row as it was: the registered columns are redacted inside the document.'),
  ('erp', 'audit_entry', 'after_state', 'any', 'object_id', 'redact_copy', null,
   'The subject''s own row as it became: the registered columns are redacted inside the document.'),
  ('erp', 'event', 'actor_label', 'principal', 'actor_id', 'redact_copy', null,
   'The actor''s display name copied onto every event; actor_id remains.'),
  ('erp', 'event', 'payload', 'any', 'aggregate_id', 'redact_copy', null,
   'Events about the subject: name, email and phone keys are removed from the payload; the reference remains.'),
  ('erp', 'command_event', 'actor_label', 'principal', 'actor_id', 'redact_copy', null,
   'The actor''s display name copied onto a command''s history; actor_id remains.')
on conflict (schema_name, table_name, column_name) do update set
  subject_kind = excluded.subject_kind, subject_column = excluded.subject_column,
  erasure = excluded.erasure, placeholder = excluded.placeholder, note = excluded.note;

insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp', 'site', 'address', 'A site''s postal address is the organisation''s, not a person''s.'),
  ('erp', 'party_address', 'address_kind', 'A kind of address (billing, delivery), not an address.'),
  ('erp', 'printer', 'queue_address', 'A device queue name.'),
  ('erp', 'document', 'address_snapshot', 'The address a business document was issued to, kept for the document''s legal life; it belongs to the business partner, whose records are retained.'),
  ('erp', 'email_suppression', 'address', 'The record that an address must not be written to. Erasing it would resume the writing the person asked to stop; it is kept as the minimum needed to honour the request.'),
  ('erp', 'identity_provider', 'email_domains', 'Domains, not addresses.'),
  ('erp', 'support_access', 'staff_email', 'Platform staff entering an organisation; an audited access record the organisation is entitled to keep, and the staff member is the platform owner''s subject, not the organisation''s.'),
  ('erp_meta', 'platform_staff', 'display_name', 'Platform staff are the platform owner''s data subjects; their erasure is the platform owner''s process, outside any organisation.'),
  ('erp_meta', 'platform_staff', 'email', 'Platform staff are the platform owner''s data subjects; their erasure is the platform owner''s process, outside any organisation.'),
  ('erp_meta', 'platform_audit', 'actor_email', 'The platform''s own audit of its staff; the platform owner''s to erase.')
on conflict (schema_name, table_name, column_name) do update set rationale = excluded.rationale;

-- The event an erasure leaves behind: a reference, never a name.
insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('subject.erased', 1, 'erasure_request', 'administration', 'event.subject.erased',
   'A data subject was erased: the reference remains, the referent is gone.',
   '{"type": "object"}', true)
on conflict (code, version) do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.subject.erased', 'en', 'Data subject erased', null,
   'Name of the event recorded when a person''s data is erased from an organisation.'),
  ('nav.administration_erasure', 'en', 'Personal data and erasure', null,
   'Navigation label for the administration screen showing the personal-data register, erasure requests and their certificates.')
on conflict (key, locale) do nothing;

-- ── The register agrees with the catalogue ────────────────────────────────────

create or replace function erp.personal_data_register_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A registered column that does not exist.
  select 'registered column does not exist', format('%s.%s.%s', f.schema_name, f.table_name, f.column_name), f.note
    from erp_ref.personal_data_field f
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = f.schema_name and c.table_name = f.table_name
                        and c.column_name = f.column_name)
  union all
  select 'registered subject column does not exist', format('%s.%s.%s', f.schema_name, f.table_name, f.subject_column), f.column_name
    from erp_ref.personal_data_field f
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = f.schema_name and c.table_name = f.table_name
                        and c.column_name = f.subject_column)
  union all
  select 'exempted column does not exist', format('%s.%s.%s', x.schema_name, x.table_name, x.column_name), x.rationale
    from erp_ref.personal_data_exemption x
   where not exists (select 1 from information_schema.columns c
                      where c.table_schema = x.schema_name and c.table_name = x.table_name
                        and c.column_name = x.column_name)
  union all
  select 'a column is both registered and exempt', format('%s.%s.%s', f.schema_name, f.table_name, f.column_name), ''
    from erp_ref.personal_data_field f
    join erp_ref.personal_data_exemption x using (schema_name, table_name, column_name)
  union all
  -- The sweep: a column that looks personal and is in neither register.
  select 'a column looks personal and is neither registered nor exempt',
         format('%s.%s.%s', c.table_schema, c.table_name, c.column_name),
         'add it to erp_ref.personal_data_field with how erasure treats it, or to erp_ref.personal_data_exemption with why it stays'
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
   where c.table_schema in ('erp', 'erp_meta')
     and c.column_name ~ '(email|phone|mobile|display_name|first_name|last_name|full_name|address|date_of_birth|passport|national_id|actor_label)'
     and not exists (select 1 from erp_ref.personal_data_field f
                      where f.schema_name = c.table_schema and f.table_name = c.table_name
                        and f.column_name = c.column_name)
     and not exists (select 1 from erp_ref.personal_data_exemption x
                      where x.schema_name = c.table_schema and x.table_name = c.table_name
                        and x.column_name = c.column_name)
  union all
  -- A copy registered on a table the append-only guard does not protect is
  -- not a copy; and a redaction on a table it does protect must be one the
  -- guard can recognise.
  select 'a redact_copy column is on a table that is not append-only',
         format('%s.%s.%s', f.schema_name, f.table_name, f.column_name), ''
    from erp_ref.personal_data_field f
   where f.erasure = 'redact_copy'
     and not exists (select 1 from erp_meta.table_policy tp
                      where tp.schema_name = f.schema_name and tp.table_name = f.table_name
                        and tp.table_class = 'tenant_scoped_append_only')
  union all
  select 'the erasure event is not registered', 'subject.erased', ''
   where not exists (select 1 from erp_ref.event_type e where e.code = 'subject.erased' and e.is_current)
  union all
  select 'the append-only guard does not know about erasure', 'erp.forbid_mutation',
         'the guard must permit only the redaction of registered copies during an executed erasure'
   where not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'erp'::regnamespace and p.proname = 'forbid_mutation'
                        and p.prosrc like '%erp.erasure_request_id%')
$$;

comment on function erp.personal_data_register_report is
  '§9.4. Fails where the personal-data register names a column the catalogue '
  'does not have, where a column that looks personal is in neither register, '
  'where a copy is registered on a table that is not append-only, or where the '
  'append-only guard would refuse the sweep.';

create or replace function erp.assert_personal_data_register_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_count integer; v_detail text; v_fields integer; v_copies integer; v_exempt integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.personal_data_register_report();

  if v_count > 0 then
    raise exception 'ERPWARE_PERSONAL_DATA_REGISTER_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  select count(*) filter (where erasure <> 'redact_copy'), count(*) filter (where erasure = 'redact_copy')
    into v_fields, v_copies from erp_ref.personal_data_field;
  select count(*) into v_exempt from erp_ref.personal_data_exemption;
  return format('personal data: %s field(s) overwritten on erasure, %s ledger copies redacted, %s exempt with a reason',
                v_fields, v_copies, v_exempt);
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('personal_data_register', 'Personal-data register sound', 'assertion', 'platform',
   'erp', 'assert_personal_data_register_sound', '', 'personal_data_register_report', '',
   'Every column that looks personal is either registered with how erasure treats it or exempt with a reason, and the append-only guard admits only the registered redactions.',
   true, 65)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- ── The append-only guard learns the one mutation it permits ─────────────────
--
-- Re-emitted from 0008 with one branch added. An UPDATE is permitted when the
-- session is trusted (the sweep is SECURITY DEFINER and runs as the owner),
-- an erasure request is named in the transaction, and every column that
-- changed is registered as a copy on this table. Anything else is the
-- refusal it always was.

create or replace function erp.forbid_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_bad text;
begin
  -- The only permitted removal is the erasure of a whole tenant, opened
  -- deliberately by a trusted session for that exact tenant. A purge cannot be
  -- used to remove one inconvenient row: it takes the tenant with it.
  if tg_op = 'DELETE'
     and erp.session_is_trusted()
     and nullif(current_setting('erp.purge_tenant_id', true), '')::uuid = old.tenant_id
  then
    return old;
  end if;

  -- §9.4: the only permitted change is the redaction of a registered copy of
  -- a person's data, during an erasure, by the sweep. The columns that changed
  -- are checked one by one against the register; a change to anything else
  -- in the same statement refuses the whole statement.
  if tg_op = 'UPDATE'
     and erp.session_is_trusted()
     and nullif(current_setting('erp.erasure_request_id', true), '') is not null
  then
    select string_agg(n.k, ', ') into v_bad
      from jsonb_each(to_jsonb(new)) n(k, v)
     where to_jsonb(old) -> n.k is distinct from n.v
       and not exists (select 1 from erp_ref.personal_data_field f
                        where f.schema_name = tg_table_schema and f.table_name = tg_table_name
                          and f.column_name = n.k and f.erasure = 'redact_copy');
    if v_bad is null then
      return new;
    end if;
    raise exception
      'ERPWARE_APPEND_ONLY: an erasure may redact only the registered personal-data '
      'copies on %.%; % is not one', tg_table_schema, tg_table_name, v_bad
      using errcode = '42501';
  end if;

  raise exception
    'ERPWARE_APPEND_ONLY: %.% is append-only; % is not permitted by any role',
    tg_table_schema, tg_table_name, tg_op
    using errcode = '42501';
end;
$$;

-- ── Requesting ────────────────────────────────────────────────────────────────

create or replace function erp.request_erasure(p_subject_kind text, p_subject_id uuid, p_reason text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  v_label  text;
  v_id     uuid;
begin
  perform erp.authorise('administration.users', null, null, null, 'erasure_request', null);

  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_ERASURE_NEEDS_REASON: a person is not erased without a reason on record'
      using errcode = '23514';
  end if;

  if p_subject_kind = 'principal' then
    select u.display_name into v_label from erp.app_user u
     where u.tenant_id = v_tenant and u.id = p_subject_id and u.kind = 'person';
  elsif p_subject_kind = 'contact' then
    select c.name into v_label from erp.party_contact c
     where c.tenant_id = v_tenant and c.id = p_subject_id;
  else
    raise exception 'ERPWARE_UNKNOWN_SUBJECT_KIND: % is not principal or contact', p_subject_kind
      using errcode = '23503';
  end if;

  if v_label is null and not found then
    raise exception 'ERPWARE_UNKNOWN_SUBJECT: no % % in this organisation', p_subject_kind, p_subject_id
      using errcode = '23503';
  end if;

  if p_subject_kind = 'principal' and p_subject_id = v_me then
    raise exception
      'ERPWARE_ERASURE_SELF: a principal does not erase themself; ask another administrator'
      using errcode = '23514';
  end if;

  if exists (select 1 from erp.erasure_request r
              where r.tenant_id = v_tenant and r.subject_kind = p_subject_kind
                and r.subject_id = p_subject_id and r.status = 'requested') then
    raise exception 'ERPWARE_ERASURE_PENDING: a request for this subject is already open'
      using errcode = '23505';
  end if;

  if exists (select 1 from erp.erasure_request r
              where r.tenant_id = v_tenant and r.subject_kind = p_subject_kind
                and r.subject_id = p_subject_id and r.status = 'executed') then
    raise exception 'ERPWARE_ALREADY_ERASED: this subject was erased; there is nothing left to erase'
      using errcode = '23514';
  end if;

  insert into erp.erasure_request (
    tenant_id, subject_kind, subject_id, subject_label, reason, requested_by)
  values (v_tenant, p_subject_kind, p_subject_id, coalesce(v_label, p_subject_id::text),
          p_reason, v_me)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.refuse_erasure(p_request_id uuid, p_reason text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.users', null, null, null, 'erasure_request', p_request_id);
  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_ERASURE_NEEDS_REASON: a refusal carries its reason'
      using errcode = '23514';
  end if;
  update erp.erasure_request
     set status = 'refused', refused_reason = p_reason, updated_at = now()
   where tenant_id = v_tenant and id = p_request_id and status = 'requested';
  if not found then
    raise exception 'ERPWARE_ERASURE_NOT_OPEN: % is not an open request', p_request_id
      using errcode = '23514';
  end if;
end;
$$;

-- ── The sweep over the ledger's copies ────────────────────────────────────────
--
-- SECURITY DEFINER because the tables it touches grant nobody UPDATE, which
-- is the whole point of them. It is registered as such, authorises before it
-- reads anything, names the request in the transaction so the guard can see
-- it, and changes only the columns the register calls copies. It returns what
-- it did, for the certificate.

create or replace function erp.erase_subject_copies(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  req      erp.erasure_request%rowtype;
  v_table  text;
  v_cols   text[];
  v_n      integer;
  v_done   jsonb := '{}'::jsonb;
begin
  perform erp.authorise('administration.users', null, null, null, 'erasure_request', p_request_id);

  select * into req from erp.erasure_request r
   where r.tenant_id = v_tenant and r.id = p_request_id and r.status = 'requested';
  if not found then
    raise exception 'ERPWARE_ERASURE_NOT_OPEN: % is not an open request', p_request_id
      using errcode = '23514';
  end if;

  perform set_config('erp.erasure_request_id', p_request_id::text, true);

  v_table := case req.subject_kind when 'principal' then 'app_user' else 'party_contact' end;
  select coalesce(array_agg(f.column_name), '{}') into v_cols
    from erp_ref.personal_data_field f
   where f.schema_name = 'erp' and f.table_name = v_table and f.erasure <> 'redact_copy';

  -- The subject's own rows, as the audit stream remembers them.
  update erp.audit_entry a
     set before_state = case when a.before_state is null then null
                             else a.before_state || coalesce((select jsonb_object_agg(k, to_jsonb('[erased]'::text))
                                                                 from jsonb_object_keys(a.before_state) k
                                                                where k = any (v_cols)), '{}'::jsonb) end,
         after_state  = case when a.after_state is null then null
                             else a.after_state || coalesce((select jsonb_object_agg(k, to_jsonb('[erased]'::text))
                                                                from jsonb_object_keys(a.after_state) k
                                                               where k = any (v_cols)), '{}'::jsonb) end
   where a.tenant_id = v_tenant and a.object_schema = 'erp' and a.object_type = v_table
     and a.object_id = req.subject_id;
  get diagnostics v_n = row_count;
  v_done := v_done || jsonb_build_object('erp.audit_entry.before_state/after_state', v_n);

  if req.subject_kind = 'principal' then
    update erp.audit_entry set actor_label = '[erased]'
     where tenant_id = v_tenant and actor_id = req.subject_id and actor_label is distinct from '[erased]';
    get diagnostics v_n = row_count;
    v_done := v_done || jsonb_build_object('erp.audit_entry.actor_label', v_n);

    update erp.event set actor_label = '[erased]'
     where tenant_id = v_tenant and actor_id = req.subject_id and actor_label is distinct from '[erased]';
    get diagnostics v_n = row_count;
    v_done := v_done || jsonb_build_object('erp.event.actor_label', v_n);

    update erp.command_event set actor_label = '[erased]'
     where tenant_id = v_tenant and actor_id = req.subject_id and actor_label is distinct from '[erased]';
    get diagnostics v_n = row_count;
    v_done := v_done || jsonb_build_object('erp.command_event.actor_label', v_n);
  end if;

  -- Events about the subject keep their reference and lose the words.
  update erp.event e
     set payload = e.payload - array['email', 'display_name', 'name', 'phone', 'mobile', 'full_name']
   where e.tenant_id = v_tenant and e.aggregate_id = req.subject_id
     and e.payload ?| array['email', 'display_name', 'name', 'phone', 'mobile', 'full_name'];
  get diagnostics v_n = row_count;
  v_done := v_done || jsonb_build_object('erp.event.payload', v_n);

  perform set_config('erp.erasure_request_id', '', true);
  return v_done;
end;
$$;

comment on function erp.erase_subject_copies is
  '§9.4. Redacts the copies of a subject''s data the append-only tables hold '
  '— actor labels, the subject''s own before/after states, event payload '
  'words — leaving every reference, id, amount and date as it was. The one '
  'mutation erp.forbid_mutation() permits, and only while this runs.';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'erase_subject_copies',
   '§9.4. The append-only tables grant nobody UPDATE; redacting a subject''s copies in them needs the owner. Authorises administration.users first, acts only on an open request in the caller''s organisation, names the request in the transaction, and the guard refuses any column that is not a registered copy.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ── Executing ─────────────────────────────────────────────────────────────────

create or replace function erp.execute_erasure(p_request_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  req      erp.erasure_request%rowtype;
  v_table  text;
  f        record;
  v_sets   text := '';
  v_n      integer;
  v_fields jsonb := '[]'::jsonb;
  v_copies jsonb;
  v_cert   jsonb;
begin
  perform erp.authorise('administration.users', null, null, null, 'erasure_request', p_request_id);

  select * into req from erp.erasure_request r
   where r.tenant_id = v_tenant and r.id = p_request_id for update;
  if not found or req.status <> 'requested' then
    raise exception 'ERPWARE_ERASURE_NOT_OPEN: % is not an open request', p_request_id
      using errcode = '23514';
  end if;

  -- Two people: the one who asked and the one who does it.
  if req.requested_by = v_me then
    raise exception
      'ERPWARE_ERASURE_NEEDS_SECOND_PRINCIPAL: the person who requested an erasure '
      'does not execute it; another administrator does'
      using errcode = '42501';
  end if;

  v_table := case req.subject_kind when 'principal' then 'app_user' else 'party_contact' end;

  -- The referent, overwritten from the register.
  for f in select * from erp_ref.personal_data_field x
            where x.schema_name = 'erp' and x.table_name = v_table and x.erasure <> 'redact_copy'
            order by x.column_name
  loop
    v_sets := v_sets || case when v_sets = '' then '' else ', ' end
              || case f.erasure
                   when 'null' then format('%I = null', f.column_name)
                   else format('%I = %L', f.column_name, replace(f.placeholder, '{id}', left(req.subject_id::text, 8)))
                 end;
    v_fields := v_fields || jsonb_build_object('column', format('erp.%s.%s', v_table, f.column_name),
                                               'erasure', f.erasure);
  end loop;

  execute format('update erp.%I set %s, updated_at = now(), updated_by = $2 where tenant_id = $1 and id = $3',
                 v_table, v_sets)
    using v_tenant, v_me, req.subject_id;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'ERPWARE_UNKNOWN_SUBJECT: no % % in this organisation', req.subject_kind, req.subject_id
      using errcode = '23503';
  end if;

  -- A person erased cannot come back as themself: the identity link is cut
  -- and the principal disabled. Their roles stay recorded against the id.
  if req.subject_kind = 'principal' then
    update erp.app_user set status = 'disabled', auth_user_id = null
     where tenant_id = v_tenant and id = req.subject_id;
  end if;

  -- The copies.
  v_copies := erp.erase_subject_copies(p_request_id);

  -- The request's own copy of the name, last.
  v_cert := jsonb_build_object(
    'request_id', req.id, 'subject_kind', req.subject_kind, 'subject_id', req.subject_id,
    'requested_by', req.requested_by, 'executed_by', v_me, 'executed_at', now(),
    'fields', v_fields, 'copies', v_copies);

  update erp.erasure_request
     set status = 'executed', executed_by = v_me, executed_at = now(),
         subject_label = replace('Erased {id}', '{id}', left(req.subject_id::text, 8)),
         certificate = v_cert, updated_at = now()
   where id = p_request_id;

  perform erp.append_event('subject.erased', 'erasure_request', p_request_id,
    jsonb_build_object('subject_kind', req.subject_kind, 'subject_id', req.subject_id));

  return v_cert;
end;
$$;

comment on function erp.execute_erasure is
  '§9.4: the reference remains and the referent is destroyed. Overwrites the '
  'subject''s registered fields, cuts a principal''s identity link, redacts '
  'the ledger''s copies through the sweep, and records a certificate of what '
  'was done. Executed by somebody other than the person who asked.';

-- ── Doors ─────────────────────────────────────────────────────────────────────

create or replace function public.erp_personal_data_register()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.authorise('administration.read');
  return jsonb_build_object(
    'fields', coalesce((select jsonb_agg(jsonb_build_object(
        'schema_name', f.schema_name, 'table_name', f.table_name, 'column_name', f.column_name,
        'subject_kind', f.subject_kind, 'subject_column', f.subject_column,
        'erasure', f.erasure, 'placeholder', f.placeholder, 'note', f.note)
        order by f.erasure = 'redact_copy', f.table_name, f.column_name)
        from erp_ref.personal_data_field f), '[]'::jsonb),
    'exemptions', coalesce((select jsonb_agg(jsonb_build_object(
        'schema_name', x.schema_name, 'table_name', x.table_name, 'column_name', x.column_name,
        'rationale', x.rationale) order by x.schema_name, x.table_name, x.column_name)
        from erp_ref.personal_data_exemption x), '[]'::jsonb));
end;
$$;

create or replace function public.erp_erasure_subjects()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  perform erp.authorise('administration.users');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(x order by x ->> 'kind', x ->> 'label') from (
      select jsonb_build_object('subject_id', u.id, 'kind', 'principal',
               'label', u.display_name || ' — ' || u.email, 'status', u.status::text) as x
        from erp.app_user u
       where u.tenant_id = v_tenant and u.kind = 'person'
         and not exists (select 1 from erp.erasure_request r
                          where r.tenant_id = v_tenant and r.subject_kind = 'principal'
                            and r.subject_id = u.id and r.status = 'executed')
      union all
      select jsonb_build_object('subject_id', c.id, 'kind', 'contact',
               'label', coalesce(c.name, '(unnamed)') || ' — ' || p.code, 'status', 'contact')
        from erp.party_contact c join erp.party p on p.id = c.party_id
       where c.tenant_id = v_tenant
         and not exists (select 1 from erp.erasure_request r
                          where r.tenant_id = v_tenant and r.subject_kind = 'contact'
                            and r.subject_id = c.id and r.status = 'executed')) t),
    '[]'::jsonb);
end;
$$;

create or replace function public.erp_erasure_requests()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  perform erp.authorise('administration.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'request_id', r.id, 'subject_kind', r.subject_kind, 'subject_id', r.subject_id,
      'subject_label', r.subject_label, 'reason', r.reason, 'status', r.status,
      'requested_by', (select u.display_name from erp.app_user u where u.id = r.requested_by),
      'executed_by', (select u.display_name from erp.app_user u where u.id = r.executed_by),
      'executed_at', r.executed_at, 'refused_reason', r.refused_reason,
      'certificate', r.certificate, 'created_at', r.created_at) order by r.created_at desc)
      from erp.erasure_request r where r.tenant_id = v_tenant), '[]'::jsonb);
end;
$$;

create or replace function public.erp_request_erasure(p_subject_kind text, p_subject_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object('request_id', erp.request_erasure(p_subject_kind, p_subject_id, p_reason))
$$;

create or replace function public.erp_execute_erasure(p_request_id uuid)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.execute_erasure(p_request_id)
$$;

create or replace function public.erp_refuse_erasure(p_request_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.refuse_erasure(p_request_id, p_reason);
  return jsonb_build_object('refused', true);
end;
$$;

revoke all on function
  public.erp_personal_data_register(),
  public.erp_erasure_subjects(),
  public.erp_erasure_requests(),
  public.erp_request_erasure(text, uuid, text),
  public.erp_execute_erasure(uuid),
  public.erp_refuse_erasure(uuid, text)
  from public, anon;

grant execute on function
  public.erp_personal_data_register(),
  public.erp_erasure_subjects(),
  public.erp_erasure_requests(),
  public.erp_request_erasure(text, uuid, text),
  public.erp_execute_erasure(uuid),
  public.erp_refuse_erasure(uuid, text)
  to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_request_erasure', 'erp.request_erasure',
   '§9.4. Opens an erasure request for one principal or contact with a reason. Gates on administration.users; refuses self and a subject already requested or erased.'),
  ('erp_execute_erasure', 'erp.execute_erasure',
   '§9.4. Executes an open erasure request: overwrites the registered fields, redacts the ledger''s copies, records the certificate. Gates on administration.users and refuses the person who requested it.'),
  ('erp_refuse_erasure', 'erp.refuse_erasure',
   '§9.4. Refuses an open erasure request with a reason. Gates on administration.users.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.erasure_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r   record;
  a1 uuid := gen_random_uuid();   -- the administrator who asks
  a2 uuid := gen_random_uuid();   -- the administrator who executes
  a3 uuid := gen_random_uuid();   -- the person erased
  op uuid := gen_random_uuid();   -- no rights
  v_second uuid; v_third uuid; v_op uuid; v_tok text; res jsonb;
  v_party uuid; v_contact uuid; v_req uuid; v_req2 uuid;
  v_ok boolean; v_msg text; v_n integer;
  v_audit_before integer; v_events integer;
begin
  select * into r from erp.provision_tenant(
    'zzera', 'Erasure', 'admin@zzera.test', 'Erasure Admin');
  insert into auth.users (id, email) values
    (a1, 'admin@zzera.test'), (a2, 'second@zzera.test'), (a3, 'third@zzera.test'), (op, 'op@zzera.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzera.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  res := public.erp_invite_principal('third@zzera.test', 'Theresa Third');
  v_third := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_third, 'administrator', null, null, 'she works here');
  perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
  perform erp.claim_invitation(v_tok);
  -- Theresa acts, so the ledger carries her name as an actor label.
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'ACME', 'Acme', 'active') returning id into v_party;
  insert into erp.party_contact (tenant_id, party_id, contact_kind, name, email, phone, role_title, is_default)
  values (r.tenant_id, v_party, 'buyer', 'Bob Buyer', 'bob@acme.test', '01234', 'Buyer', true)
  returning id into v_contact;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- ── The register ──────────────────────────────────────────────────────────

  begin
    v_msg := erp.assert_personal_data_register_sound(); v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 160);
  end;
  return query select 'every column that looks personal is registered or exempt with a reason',
    v_ok and v_msg like 'personal data: % field(s) overwritten on erasure, % ledger copies redacted, % exempt%', v_msg;

  alter table erp.party add column zz_contact_email text;
  return query select 'a new column that looks personal fails the build until it is registered or exempt',
    exists (select 1 from erp.personal_data_register_report() x
             where x.reference = 'erp.party.zz_contact_email'
               and x.finding like 'a column looks personal%'),
    'erp.party.zz_contact_email is in neither register';
  alter table erp.party drop column zz_contact_email;

  -- ── Requesting ────────────────────────────────────────────────────────────

  begin
    perform erp.request_erasure('principal', (select u.id from erp.app_user u where u.auth_user_id = a1), 'testing');
    v_ok := false; v_msg := 'erased oneself';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ERASURE_SELF%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a principal does not erase themself', v_ok, v_msg;

  begin
    perform erp.request_erasure('principal', v_third, '');
    v_ok := false; v_msg := 'requested without a reason';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ERASURE_NEEDS_REASON%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'a request needs a reason', v_ok, v_msg;

  v_req := erp.request_erasure('principal', v_third, 'left the company; subject access request');
  return query select 'a request records the subject as known at the time',
    (select q.subject_label from erp.erasure_request q where q.id = v_req) = 'Theresa Third'
    and (select q.status from erp.erasure_request q where q.id = v_req) = 'requested',
    'Theresa Third, requested';

  begin
    perform erp.request_erasure('principal', v_third, 'again');
    v_ok := false; v_msg := 'opened a second request';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ERASURE_PENDING%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'one open request per subject', v_ok, v_msg;

  -- ── Two people ────────────────────────────────────────────────────────────

  begin
    perform erp.execute_erasure(v_req);
    v_ok := false; v_msg := 'the requester executed their own request';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ERASURE_NEEDS_SECOND_PRINCIPAL%'; v_msg := left(sqlerrm, 90);
  end;
  return query select 'the person who asked does not execute', v_ok, v_msg;

  -- ── The guard, before the erasure ─────────────────────────────────────────

  select count(*) into v_audit_before from erp.audit_entry a
   where a.tenant_id = r.tenant_id and a.actor_id = v_third;
  begin
    update erp.audit_entry set actor_label = 'x' where tenant_id = r.tenant_id and actor_id = v_third;
    v_ok := false; v_msg := 'an audit entry was edited outside an erasure';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_APPEND_ONLY%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'outside an erasure the audit stream is as append-only as ever', v_ok and v_audit_before > 0,
    format('%s entries by the subject; %s', v_audit_before, v_msg);

  perform set_config('erp.erasure_request_id', v_req::text, true);
  begin
    update erp.audit_entry set action = 'delete' where tenant_id = r.tenant_id and actor_id = v_third;
    v_ok := false; v_msg := 'a non-copy column was changed under an erasure';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_APPEND_ONLY: an erasure may redact only%action is not one%'; v_msg := left(sqlerrm, 120);
  end;
  perform set_config('erp.erasure_request_id', '', true);
  return query select 'and under an erasure only a registered copy may change, named column by column', v_ok, v_msg;

  -- ── Executing ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  res := erp.execute_erasure(v_req);
  return query select 'the referent is destroyed: name and email overwritten, identity cut, principal disabled',
    (select u.display_name from erp.app_user u where u.id = v_third) like 'Erased principal %'
    and (select u.email from erp.app_user u where u.id = v_third) like 'erased-%@erased.invalid'
    and (select u.status::text from erp.app_user u where u.id = v_third) = 'disabled'
    and (select u.auth_user_id from erp.app_user u where u.id = v_third) is null,
    (select u.display_name || ' / ' || u.email from erp.app_user u where u.id = v_third);

  return query select 'the reference remains: her audit entries stay, with the label redacted',
    (select count(*) from erp.audit_entry a where a.tenant_id = r.tenant_id and a.actor_id = v_third) = v_audit_before
    and not exists (select 1 from erp.audit_entry a where a.tenant_id = r.tenant_id and a.actor_id = v_third
                     and a.actor_label is distinct from '[erased]')
    and (res -> 'copies' ->> 'erp.audit_entry.actor_label')::integer = v_audit_before,
    format('%s entries kept, %s labels redacted', v_audit_before, res -> 'copies' ->> 'erp.audit_entry.actor_label');

  return query select 'the audit stream''s copies of her own row no longer say who she was',
    not exists (select 1 from erp.audit_entry a
                 where a.tenant_id = r.tenant_id and a.object_type = 'app_user' and a.object_id = v_third
                   and (a.after_state ->> 'email' like '%zzera.test%' or a.after_state ->> 'display_name' = 'Theresa Third'
                        or a.before_state ->> 'email' like '%zzera.test%' or a.before_state ->> 'display_name' = 'Theresa Third'))
    and exists (select 1 from erp.audit_entry a
                 where a.tenant_id = r.tenant_id and a.object_type = 'app_user' and a.object_id = v_third
                   and a.after_state ->> 'email' = '[erased]'),
    'before_state and after_state carry [erased] where the name and email were';

  return query select 'the ledger is otherwise untouched and an event records the erasure by reference only',
    exists (select 1 from erp.event e where e.tenant_id = r.tenant_id and e.event_type = 'subject.erased'
             and e.aggregate_id = v_req and e.payload ->> 'subject_id' = v_third::text
             and e.payload::text not like '%Theresa%')
    and (select q.status from erp.erasure_request q where q.id = v_req) = 'executed'
    and (select q.subject_label from erp.erasure_request q where q.id = v_req) like 'Erased %'
    and (select q.certificate -> 'fields' from erp.erasure_request q where q.id = v_req) @> '[{"column":"erp.app_user.email"}]'::jsonb,
    'subject.erased carries the id; the certificate lists the fields';

  begin
    perform erp.request_erasure('principal', v_third, 'again');
    v_ok := false; v_msg := 'requested an erased subject';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ALREADY_ERASED%'; v_msg := left(sqlerrm, 80);
  end;
  return query select 'an erased subject is not requested again', v_ok, v_msg;

  -- ── A contact ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v_req2 := erp.request_erasure('contact', v_contact, 'asked to be forgotten');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  res := erp.execute_erasure(v_req2);
  return query select 'a business partner''s contact is erased and the business partner is not',
    (select c.name from erp.party_contact c where c.id = v_contact) like 'Erased contact %'
    and (select c.email from erp.party_contact c where c.id = v_contact) is null
    and (select c.phone from erp.party_contact c where c.id = v_contact) is null
    and (select p.name from erp.party p where p.id = v_party) = 'Acme'
    and not exists (select 1 from erp.audit_entry a
                     where a.tenant_id = r.tenant_id and a.object_type = 'party_contact' and a.object_id = v_contact
                       and a.after_state ->> 'email' = 'bob@acme.test'),
    (select c.name from erp.party_contact c where c.id = v_contact);

  -- ── Refusing, and who may ask ─────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v_req := erp.request_erasure('principal', v_second, 'mistaken request');
  perform erp.refuse_erasure(v_req, 'still employed');
  return query select 'a request is refused with a reason',
    (select q.status from erp.erasure_request q where q.id = v_req) = 'refused'
    and (select q.refused_reason from erp.erasure_request q where q.id = v_req) = 'still employed'
    and (select u.display_name from erp.app_user u where u.id = v_second) = 'Second Admin',
    'refused; nothing overwritten';

  res := public.erp_invite_principal('op@zzera.test', 'No rights');
  v_op := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.claim_invitation(v_tok);
  begin
    perform public.erp_request_erasure('principal', v_second, 'malice');
    v_ok := false; v_msg := 'somebody with no rights requested an erasure';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a person without administration.users may not request one', v_ok, v_msg;
  begin
    perform erp.erase_subject_copies(v_req);
    v_ok := false; v_msg := 'somebody with no rights ran the sweep';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PERMISSION_DENIED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor run the sweep directly, definer or not', v_ok, v_msg;

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2, a3, op);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id)
    and not exists (select 1 from auth.users u where u.id in (a1, a2, a3, op))
    and not exists (select 1 from erp.erasure_request q where q.tenant_id = r.tenant_id),
    'requests go with the organisation';
end;
$$;

comment on function erp_test.erasure_suite is
  'Specification v1.2 §9.4, proven adversarially: a principal who acted is '
  'erased by a second administrator; her name and email are overwritten, her '
  'identity link cut, every audit entry she made kept with its label '
  'redacted, the audit copies of her own row redacted, the event of the '
  'erasure carries only her id; outside an erasure the stream is as '
  'append-only as ever and under one only registered copies may change; a '
  'contact is erased without touching the business partner; nobody erases '
  'themself; the person who asked does not execute.';

create or replace function erp_test.assert_erasure_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _erasure_result on commit drop as
    select * from erp_test.erasure_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _erasure_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_ERASURE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('erasure: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_configuration_promotable();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_personal_data_register_sound();
select erp_test.assert_erasure_suite();
