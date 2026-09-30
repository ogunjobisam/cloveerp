-- ═════════════════════════════════════════════════════════════════════════════
-- A legacy chart is mapped, not merged
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A customer moving from Xero brings a chart of accounts, a contact list, and
-- reports that name both by their Xero keys: the trial balance prints
-- "200 - Sales" or "Suspense", the aged ledgers print a contact's name. Clove
-- resolves accounts and parties by code. Three things here join the two.
--
--   1. erp.import_crosswalk: a legacy key, the Clove code it resolves to, and
--      the batch that said so. An entry counts only while its batch is loaded:
--      staged, it is a proposal; rolled back, it is deleted with the batch
--      (the trigger on erp.import_batch), so a refused or reversed import
--      never leaves a mapping behind. Contacts write theirs through
--      erp_stage_import_crosswalk, next to the party batch they stage; the
--      chart writes its own as it loads.
--
--   2. The account import object, registered in erp_ref.import_object. Each
--      row maps a Xero account to an existing Clove account, marks it as one
--      of the three control accounts the opening-balance domains load, or
--      creates a new account. It never changes an existing account.
--      erp.upsert_account() was the obvious tool and is the wrong one: it
--      authorises nothing and, when the code is taken, overwrites the name,
--      type and control kind of whatever holds it — a Xero chart sharing a
--      code with the Clove chart would have rewritten it. A code that is
--      taken is mapped or refused, never merged. Creating chart accounts is a
--      finance configuration change, so every step authorises
--      finance.configure as well as the import pipeline's own gate. Rolling
--      back deletes the accounts the batch created, and is refused once
--      anything refers to one.
--
--   3. erp.import_mapping: which heading of a legacy export is which column,
--      as a person confirmed it, per organisation and profile. It was kept in
--      one browser; the next person to import met the same questions again.
--
-- erp_accounts also says each account's control kind, so the mapping screen
-- can offer the receivable, payable and inventory accounts for Xero's three.
--
-- Proof: erp_test.import_crosswalk_suite() (12 cases).

set lock_timeout = '30s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The crosswalk
-- ─────────────────────────────────────────────────────────────────────────────

create table erp.import_crosswalk (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant (id) on delete cascade,
  import_batch_id uuid not null,
  source_system   text not null check (source_system in ('xero', 'unleashed')),
  object_type     text not null check (object_type in ('party', 'account')),
  legacy_key      text not null check (length(btrim(legacy_key)) between 1 and 200),
  legacy_name     text check (legacy_name is null or length(legacy_name) <= 200),
  clove_code      text not null check (length(btrim(clove_code)) between 1 and 60),
  resolution      text not null check (resolution in ('map', 'create', 'control')),
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, import_batch_id) references erp.import_batch (tenant_id, id) on delete cascade
);

create unique index import_crosswalk_one_key_per_batch
  on erp.import_crosswalk (tenant_id, import_batch_id, source_system, object_type, lower(btrim(legacy_key)));
create index import_crosswalk_lookup
  on erp.import_crosswalk (tenant_id, source_system, object_type, lower(btrim(legacy_key)));

select erp_meta.register_table('erp', 'import_crosswalk', 'tenant_scoped',
  'A legacy system''s key for a party or an account, and the Clove code it resolves to, as the import batch that loaded it said. Counts only while that batch is loaded.');

comment on table erp.import_crosswalk is
  'Legacy key → Clove code, per import batch. Read through erp_import_crosswalk, which '
  'answers only entries whose batch is loaded; deleted when the batch is rolled back '
  '(20261003600000).';

-- A batch rolled back takes its entries with it, whatever kind of batch it was.
create or replace function erp.forget_crosswalk_of_rolled_back_batch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  delete from erp.import_crosswalk x
   where x.tenant_id = new.tenant_id and x.import_batch_id = new.id;
  return new;
end;
$$;

revoke all on function erp.forget_crosswalk_of_rolled_back_batch() from public, anon, authenticated;

drop trigger if exists t_import_batch_forgets_crosswalk on erp.import_batch;
create trigger t_import_batch_forgets_crosswalk
  after update of status on erp.import_batch
  for each row
  when (new.status = 'rolled_back' and old.status is distinct from new.status)
  execute function erp.forget_crosswalk_of_rolled_back_batch();

-- Contacts: the legacy name of each party a batch stages, beside the batch.
-- Restaging replaces the batch's entries, so the screen can send them again.
create or replace function erp.stage_import_crosswalk(
  p_batch_id uuid, p_source_system text, p_object_type text, p_entries jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
  b        erp.import_batch%rowtype;
  v_bad    text;
  v_n      integer;
begin
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);
  v_tenant := erp.require_tenant_id();

  select * into b from erp.import_batch x
   where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  if not found or b.status not in ('received', 'validated', 'previewed') then
    raise exception 'CLOVEERP_CROSSWALK_BATCH_NOT_OPEN: the batch is %, and entries are staged beside a batch that has not loaded',
      coalesce(b.status::text, 'not in this organisation')
      using errcode = '23514',
            hint = 'Stage the file again; a loaded batch keeps the entries it loaded with.';
  end if;
  if p_object_type is distinct from 'party' or b.object_type <> 'party'
     or p_source_system is null or p_source_system not in ('xero', 'unleashed') then
    raise exception 'CLOVEERP_CROSSWALK_SHAPE: entries are staged for a party batch from xero or unleashed, not % from %',
      coalesce(p_object_type, 'nothing'), coalesce(p_source_system, 'nowhere')
      using errcode = '22023',
            hint = 'The chart writes its own entries as it loads; only contacts are staged here.';
  end if;
  if p_entries is null or jsonb_typeof(p_entries) <> 'array'
     or exists (select 1 from jsonb_array_elements(p_entries) e
                 where jsonb_typeof(e) <> 'object'
                    or coalesce(btrim(e ->> 'legacy_key'), '') = ''
                    or coalesce(btrim(e ->> 'clove_code'), '') = '') then
    raise exception 'CLOVEERP_CROSSWALK_SHAPE: entries are a list of {legacy_key, clove_code}, each with both'
      using errcode = '22023',
            hint = 'Send the names the contacts file staged, each with the code it staged under.';
  end if;

  select string_agg(distinct e ->> 'clove_code', ', ') into v_bad
    from jsonb_array_elements(p_entries) e
   where not exists (select 1 from erp.import_row r
                      where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id
                        and r.raw ->> 'code' = btrim(e ->> 'clove_code'));
  if v_bad is not null then
    raise exception 'CLOVEERP_CROSSWALK_NOT_IN_BATCH: % is not a code this batch stages', v_bad
      using errcode = '23503',
            hint = 'An entry names a party the same batch creates or updates; stage the contacts file and its entries together.';
  end if;

  delete from erp.import_crosswalk x where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id;
  insert into erp.import_crosswalk
    (tenant_id, import_batch_id, source_system, object_type, legacy_key, legacy_name, clove_code, resolution)
  select distinct on (lower(btrim(e ->> 'legacy_key')))
         v_tenant, p_batch_id, p_source_system, 'party', btrim(e ->> 'legacy_key'),
         btrim(e ->> 'legacy_key'), btrim(e ->> 'clove_code'), 'map'
    from jsonb_array_elements(p_entries) e
   order by lower(btrim(e ->> 'legacy_key'));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function erp.stage_import_crosswalk(uuid, text, text, jsonb) from public, anon;

comment on function erp.stage_import_crosswalk(uuid, text, text, jsonb) is
  'Stages legacy name → party code entries beside a party batch; they count once it loads (20261003600000).';

-- What a legacy key resolves to now: the most recently loaded batch's entry.
create or replace function erp.import_crosswalk(p_source_system text, p_object_type text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  perform erp.authorise('master_data.import');
  select coalesce(jsonb_agg(jsonb_build_object(
           'legacy_key', c.legacy_key, 'legacy_name', c.legacy_name,
           'clove_code', c.clove_code, 'resolution', c.resolution)
         order by lower(c.legacy_key)), '[]'::jsonb)
    into v_out
    from (select distinct on (lower(btrim(x.legacy_key))) x.*
            from erp.import_crosswalk x
            join erp.import_batch b on b.tenant_id = x.tenant_id and b.id = x.import_batch_id
           where x.tenant_id = erp.current_tenant_id()
             and x.source_system = p_source_system
             and x.object_type = p_object_type
             and b.status = 'loaded'
           order by lower(btrim(x.legacy_key)), b.loaded_at desc nulls last, x.created_at desc) c;
  return v_out;
end;
$$;

revoke all on function erp.import_crosswalk(text, text) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The account import object
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.import_object (object_type, name_key, module_code, validate_function, load_function, rollback_function, description, seq) values
  ('account', 'import_object.account.name', 'finance',
   'erp.validate_account_import', 'erp.load_account_import', 'erp.rollback_account_import',
   'A legacy chart of accounts: one row per legacy account, mapped to an existing account, marked as a control account, or created. An existing account is never changed.', 20)
on conflict (object_type) do update
  set name_key = excluded.name_key, module_code = excluded.module_code,
      validate_function = excluded.validate_function, load_function = excluded.load_function,
      rollback_function = excluded.rollback_function, description = excluded.description, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('import_object.account.name', 'en', 'Chart of accounts', 'finance'),
  ('import_object.account.name', 'de', 'Kontenplan', 'finance')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

create or replace function erp.validate_account_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_entity uuid;
  v_find   jsonb;
  v_errors integer := 0;
  v_key    text;
  v_action text;
  v_code   text;
  v_bad    text;
  acc      erp.account%rowtype;
  v_seen   text[] := '{}';
  v_made   text[] := '{}';
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('finance.configure', null, null, null, 'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'CLOVEERP_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514', hint = 'Stage a new batch; a loaded or rolled-back one is not validated again.';
  end if;

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  for r in select * from erp.import_row x where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id order by x.row_no loop
    v_find := '[]'::jsonb;
    v_action := r.raw ->> 'action';
    v_code := btrim(coalesce(r.raw ->> 'code', ''));
    v_key := lower(coalesce(nullif(btrim(r.raw ->> 'legacy_code'), ''), btrim(r.raw ->> 'legacy_name'), ''));

    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k not in ('source', 'legacy_code', 'legacy_name', 'action', 'code', 'name', 'account_type');
    if v_bad is not null then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('unknown field(s): %s', v_bad));
    end if;
    if coalesce(r.raw ->> 'source', '') not in ('xero', 'unleashed') then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'source is xero or unleashed');
    end if;
    if v_key = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'legacy_code or legacy_name names the legacy account, and both are missing');
    elsif v_key = any (v_seen) then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('the legacy account %s is on an earlier row', v_key));
    else
      v_seen := v_seen || v_key;
    end if;
    if v_code = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'code is the Clove account, and it is missing');
    end if;

    acc := null;
    if v_code <> '' then
      select * into acc from erp.account a
       where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_code;
    end if;

    if v_action = 'map' then
      if acc.id is null or acc.status <> 'active' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('no active account has the code %s to map to', v_code));
      elsif not acc.is_postable then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('%s is a heading, not a postable account', v_code));
      elsif acc.control_kind in ('receivable', 'payable', 'inventory') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is the %s control account; mark the legacy account as control rather than mapping balances to it', v_code, acc.control_kind));
      end if;
    elsif v_action = 'control' then
      if acc.id is null or acc.control_kind is null or acc.control_kind not in ('receivable', 'payable', 'inventory') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is not a receivable, payable or inventory control account', coalesce(nullif(v_code, ''), 'the code')));
      end if;
    elsif v_action = 'create' then
      if acc.id is not null then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('%s is already %s; map to it, or create under a code that is free', v_code, acc.name));
      elsif v_code = any (v_made) then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('%s is created by an earlier row', v_code));
      elsif v_code <> '' then
        v_made := v_made || v_code;
      end if;
      if coalesce(btrim(r.raw ->> 'name'), '') = '' then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'a new account needs a name');
      end if;
      if coalesce(r.raw ->> 'account_type', '') not in ('asset', 'liability', 'equity', 'income', 'expense') then
        v_find := v_find || jsonb_build_object('severity', 'error', 'message',
          format('account_type is asset, liability, equity, income or expense, not %s', coalesce(r.raw ->> 'account_type', 'nothing')));
      end if;
    else
      v_find := v_find || jsonb_build_object('severity', 'error', 'message',
        format('action is map, control or create, not %s', coalesce(v_action, 'nothing')));
    end if;

    update erp.import_row
       set findings = v_find, target_id = null,
           action = case when jsonb_array_length(v_find) > 0 then 'reject'
                         when v_action = 'create' then 'insert' else 'skip' end,
           updated_at = now()
     where id = r.id;
    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;
  return v_errors;
end;
$$;

revoke all on function erp.validate_account_import(uuid) from public, anon, authenticated;

create or replace function erp.load_account_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_entity uuid;
  v_id     uuid;
  v_n      integer := 0;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('finance.configure', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'previewed' then
    raise exception 'CLOVEERP_IMPORT_NOT_PREVIEWED: % is %, and a staged load happens after somebody has looked at it', b.code, b.status
      using errcode = '23514', hint = 'Validate, preview, then load.';
  end if;
  if b.error_count > 0 then
    raise exception 'CLOVEERP_IMPORT_HAS_ERRORS: % rows in % are rejected; fix the file rather than loading the good half', b.error_count, b.code
      using errcode = '23514', hint = 'The findings on each row say what is wrong.';
  end if;

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  for r in select * from erp.import_row x
            where x.tenant_id = v_tenant and x.import_batch_id = p_batch_id and x.action in ('insert', 'skip')
            order by x.row_no loop
    if r.action = 'insert' then
      insert into erp.account (tenant_id, entity_id, code, name, account_type, is_postable, currency)
      values (v_tenant, v_entity, btrim(r.raw ->> 'code'), btrim(r.raw ->> 'name'),
              (r.raw ->> 'account_type')::erp.account_type, true,
              (select e.base_currency from erp.entity e where e.id = v_entity))
      returning id into v_id;
    else
      select a.id into v_id from erp.account a
       where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = btrim(r.raw ->> 'code');
    end if;

    insert into erp.import_crosswalk
      (tenant_id, import_batch_id, source_system, object_type, legacy_key, legacy_name, clove_code, resolution)
    values (v_tenant, p_batch_id, r.raw ->> 'source', 'account',
            coalesce(nullif(btrim(r.raw ->> 'legacy_code'), ''), btrim(r.raw ->> 'legacy_name')),
            nullif(btrim(r.raw ->> 'legacy_name'), ''), btrim(r.raw ->> 'code'), r.raw ->> 'action');

    update erp.import_row
       set target_id = v_id, loaded = true, before_snapshot = null,
           loaded_ref = jsonb_build_object('account_id', v_id, 'created', r.action = 'insert'),
           updated_at = now()
     where id = r.id;
    v_n := v_n + 1;
  end loop;

  update erp.import_batch
     set status = 'loaded', loaded_at = now(), loaded_by = erp.current_principal_id(), updated_at = now()
   where id = p_batch_id;
  return v_n;
end;
$$;

revoke all on function erp.load_account_import(uuid) from public, anon, authenticated;

create or replace function erp.rollback_account_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_ids    uuid[];
  v_n      integer := 0;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  perform erp.authorise('finance.configure', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'loaded' then
    raise exception 'CLOVEERP_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514', hint = 'Only a loaded batch is rolled back.';
  end if;

  select coalesce(array_agg((r.loaded_ref ->> 'account_id')::uuid), '{}') into v_ids
    from erp.import_row r
   where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id
     and r.loaded and (r.loaded_ref ->> 'created')::boolean;

  begin
    delete from erp.account a where a.tenant_id = v_tenant and a.id = any (v_ids);
    get diagnostics v_n = row_count;
  exception when foreign_key_violation then
    raise exception 'CLOVEERP_ACCOUNT_IMPORT_IN_USE: an account % created is already used, so the batch stands', b.code
      using errcode = '23503',
            hint = 'Reverse what posted to or hangs from the account first, or leave the chart and map differently in a new batch.';
  end;

  update erp.import_row set loaded = false, target_id = null, updated_at = now()
   where tenant_id = v_tenant and import_batch_id = p_batch_id;
  update erp.import_batch set status = 'rolled_back', rolled_back_at = now(), updated_at = now()
   where id = p_batch_id;
  return v_n;
end;
$$;

revoke all on function erp.rollback_account_import(uuid) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Header mappings
-- ─────────────────────────────────────────────────────────────────────────────

create table erp.import_mapping (
  id          uuid not null default gen_random_uuid(),
  tenant_id   uuid not null references erp.tenant (id) on delete cascade,
  profile_id  text not null check (profile_id ~ '^[a-z0-9][a-z0-9-]{0,59}$'),
  mapping     jsonb not null check (jsonb_typeof(mapping) = 'object'),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, profile_id)
);

select erp_meta.register_table('erp', 'import_mapping', 'tenant_scoped',
  'Which heading of a legacy export is which column of an import profile, as a person confirmed it, so the next file from the same system maps itself.');

create or replace function erp.save_import_mapping(p_profile_id text, p_mapping jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('master_data.import');
  v_tenant := erp.require_tenant_id();

  if p_profile_id is null or p_profile_id !~ '^[a-z0-9][a-z0-9-]{0,59}$'
     or p_mapping is null or jsonb_typeof(p_mapping) <> 'object'
     or length(p_mapping::text) > 8000
     or exists (select 1 from jsonb_each(p_mapping) m
                 where m.key !~ '^[a-z0-9_]{1,60}$' or jsonb_typeof(m.value) <> 'string'
                    or length(m.value #>> '{}') > 200) then
    raise exception 'CLOVEERP_IMPORT_MAPPING_SHAPE: a mapping is a profile id and an object of column key to heading text'
      using errcode = '22023',
            hint = 'Send the headings the person confirmed, keyed by the profile''s column keys.';
  end if;

  insert into erp.import_mapping (tenant_id, profile_id, mapping)
  values (v_tenant, p_profile_id, p_mapping)
  on conflict (tenant_id, profile_id) do update set mapping = excluded.mapping, updated_at = now();
end;
$$;

revoke all on function erp.save_import_mapping(text, jsonb) from public, anon;

create or replace function erp.import_mappings()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  perform erp.authorise('master_data.import');
  select coalesce(jsonb_object_agg(m.profile_id, m.mapping), '{}'::jsonb) into v_out
    from erp.import_mapping m
   where m.tenant_id = erp.current_tenant_id();
  return v_out;
end;
$$;

revoke all on function erp.import_mappings() from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The doors
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_stage_import_crosswalk(
  p_batch_id uuid, p_source_system text, p_object_type text, p_entries jsonb)
returns integer
language sql
volatile
set search_path = ''
as $$ select erp.stage_import_crosswalk(p_batch_id, p_source_system, p_object_type, p_entries) $$;

create or replace function public.erp_import_crosswalk(p_source_system text, p_object_type text)
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.import_crosswalk(p_source_system, p_object_type) $$;

create or replace function public.erp_save_import_mapping(p_profile_id text, p_mapping jsonb)
returns void
language sql
volatile
set search_path = ''
as $$ select erp.save_import_mapping(p_profile_id, p_mapping) $$;

create or replace function public.erp_import_mappings()
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.import_mappings() $$;

-- The chart as the finance screens read it, now saying which accounts are
-- control accounts. Additive: every key it returned, it still returns.
create or replace function public.erp_accounts(p_postable_only boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'account_id', a.id, 'code', a.code, 'name', a.name,
      'account_type', a.account_type::text, 'is_postable', a.is_postable,
      'control_kind', a.control_kind::text,
      'entity_id', a.entity_id, 'status', a.status) as x
      from erp.account a
     where a.tenant_id = erp.current_tenant_id()
       and a.status = 'active'
       and (not p_postable_only or a.is_postable)
  ) s;
  return v_out;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_stage_import_crosswalk(uuid, text, text, jsonb)',
    'erp_import_crosswalk(text, text)',
    'erp_save_import_mapping(text, jsonb)',
    'erp_import_mappings()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

comment on function public.erp_stage_import_crosswalk(uuid, text, text, jsonb) is
  'Stages a contacts file''s legacy names beside the party batch it staged (20261003600000).';
comment on function public.erp_import_crosswalk(text, text) is
  'Legacy key → Clove code for one source and object, from loaded batches only (20261003600000).';
comment on function public.erp_save_import_mapping(text, jsonb) is
  'Keeps the heading a person confirmed for each column of an import profile (20261003600000).';
comment on function public.erp_import_mappings() is
  'Every import profile''s confirmed headings for this organisation (20261003600000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_stage_import_crosswalk', 'erp.stage_import_crosswalk',
   'Stages legacy name → party code entries beside a party import batch; authorises master_data.import. They count only once the batch loads, and go when it is rolled back.'),
  ('erp_save_import_mapping', 'erp.save_import_mapping',
   'Keeps the confirmed heading of each column of an import profile for the organisation; authorises master_data.import.'),
  ('erp_import_crosswalk', 'erp.import_crosswalk',
   'Reads only, but authorising master_data.import writes an access-decision row, so this is correctly VOLATILE and belongs on the register.'),
  ('erp_import_mappings', 'erp.import_mappings',
   'Reads only, but authorising master_data.import writes an access-decision row, so this is correctly VOLATILE and belongs on the register.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.import_crosswalk_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  ra record; rb record;
  v_entity uuid;
  v_recv   text;
  v_plain  erp.account%rowtype;
  v_party  text := 'ZZXW' || upper(v_tag);
  v_new    text := 'XW-' || upper(v_tag);
  v_pb     uuid; v_ab uuid; v_bad uuid;
  v_x      jsonb;
  v_err    text;
  v_n      integer;
begin
  begin
    v_step := 'two organisations, each with its administrator signed in';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant(
      'xwa-' || v_tag, 'Crosswalk Suite A', 'a@xw-' || v_tag || '.test', 'A Admin');
    select * into rb from erp.provision_tenant(
      'xwb-' || v_tag, 'Crosswalk Suite B', 'b@xw-' || v_tag || '.test', 'B Admin');
    update erp.environment set is_live = false where tenant_id in (ra.tenant_id, rb.tenant_id) and is_self;
    insert into auth.users (id, email) values
      (a1, 'a@xw-' || v_tag || '.test'), (a2, 'b@xw-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform erp.ensure_demo_configuration(ra.tenant_id, ra.admin_user_id);

    select e.id into v_entity from erp.entity e where e.tenant_id = ra.tenant_id order by e.code limit 1;
    select a.code into v_recv from erp.account a
     where a.tenant_id = ra.tenant_id and a.entity_id = v_entity and a.status = 'active'
       and a.control_kind = 'receivable'
     order by a.code limit 1;
    if v_recv is null then
      v_recv := 'XWR-' || upper(v_tag);
      insert into erp.account (tenant_id, entity_id, code, name, account_type, control_kind, is_postable)
      values (ra.tenant_id, v_entity, v_recv, 'Trade receivables', 'asset', 'receivable', true);
    end if;
    select a.* into v_plain from erp.account a
     where a.tenant_id = ra.tenant_id and a.entity_id = v_entity and a.status = 'active'
       and a.is_postable and a.control_kind is null
     order by a.code limit 1;

    -- 1. Contacts: entries naming a code the batch does not stage are refused.
    v_step := 'staging a contacts batch and its entries';
    v_pb := erp.stage_import('party', jsonb_build_array(
      jsonb_build_object('code', v_party, 'name', 'Crosswalk Party ' || v_tag)), 'XWP-' || v_tag, 'xero-contacts');
    v_err := null;
    begin
      perform erp.stage_import_crosswalk(v_pb, 'xero', 'party',
        jsonb_build_array(jsonb_build_object('legacy_key', 'Somebody Else', 'clove_code', 'NOTSTAGED')));
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'an entry naming a party the batch does not stage is refused';
    passed := v_err like 'CLOVEERP_CROSSWALK_NOT_IN_BATCH:%';
    detail := coalesce(v_err, 'it was staged');
    return next;

    -- 2. Staged entries do not resolve until the batch loads.
    v_n := erp.stage_import_crosswalk(v_pb, 'xero', 'party',
      jsonb_build_array(jsonb_build_object('legacy_key', 'Crosswalk Party ' || v_tag, 'clove_code', v_party)));
    v_x := erp.import_crosswalk('xero', 'party');
    v_cases := v_cases + 1;
    case_name := 'a staged entry is a proposal: nothing resolves before the batch loads';
    passed := v_n = 1 and v_x = '[]'::jsonb;
    detail := coalesce(v_x::text, 'no answer');
    return next;

    -- 3. Loaded, the name resolves to the code.
    v_step := 'loading the contacts batch';
    perform erp.validate_import(v_pb);
    perform erp.preview_import(v_pb);
    perform erp.load_import(v_pb);
    v_x := erp.import_crosswalk('xero', 'party');
    v_cases := v_cases + 1;
    case_name := 'once the batch loads, the legacy name resolves to the party code';
    passed := jsonb_array_length(v_x) = 1 and v_x -> 0 ->> 'clove_code' = v_party
          and v_x -> 0 ->> 'legacy_key' = 'Crosswalk Party ' || v_tag;
    detail := coalesce(v_x::text, 'no answer');
    return next;

    -- 4. Rolled back, the entries go with it.
    v_step := 'rolling the contacts batch back';
    perform erp.rollback_import(v_pb);
    v_cases := v_cases + 1;
    case_name := 'rolling a batch back deletes its entries';
    passed := erp.import_crosswalk('xero', 'party') = '[]'::jsonb
          and not exists (select 1 from erp.import_crosswalk x where x.import_batch_id = v_pb);
    detail := format('%s entr(ies) left', (select count(*) from erp.import_crosswalk x where x.import_batch_id = v_pb));
    return next;

    -- 5. A chart batch that maps, marks a control account and creates.
    v_step := 'staging and validating a chart';
    v_ab := erp.stage_import('account', jsonb_build_array(
      jsonb_build_object('source', 'xero', 'legacy_code', '200', 'legacy_name', 'Sales',
                         'action', 'map', 'code', v_plain.code),
      jsonb_build_object('source', 'xero', 'legacy_code', '610', 'legacy_name', 'Accounts Receivable',
                         'action', 'control', 'code', v_recv),
      jsonb_build_object('source', 'xero', 'legacy_name', 'Suspense',
                         'action', 'create', 'code', v_new, 'name', 'Xero suspense', 'account_type', 'liability')),
      'XWA-' || v_tag, 'xero-chart');
    v_n := erp.validate_import(v_ab);
    v_cases := v_cases + 1;
    case_name := 'a chart that maps, marks a control account and creates validates clean';
    passed := v_n = 0;
    detail := coalesce((select string_agg(r.findings::text, '; ') from erp.import_row r
                         where r.import_batch_id = v_ab and r.findings <> '[]'::jsonb), 'no findings');
    return next;

    -- 6. Every wrong row is refused, each for its own reason.
    v_step := 'validating a bad chart';
    v_bad := erp.stage_import('account', jsonb_build_array(
      jsonb_build_object('source', 'xero', 'legacy_code', '1', 'action', 'map', 'code', 'NOSUCH-' || v_tag),
      jsonb_build_object('source', 'xero', 'legacy_code', '2', 'action', 'map', 'code', v_recv),
      jsonb_build_object('source', 'xero', 'legacy_code', '3', 'action', 'control', 'code', v_plain.code),
      jsonb_build_object('source', 'xero', 'legacy_code', '4', 'action', 'create', 'code', v_plain.code,
                         'name', 'Taken', 'account_type', 'expense'),
      jsonb_build_object('source', 'xero', 'legacy_code', '5', 'action', 'create', 'code', 'XWN-' || v_tag,
                         'name', 'Odd', 'account_type', 'statistical'),
      jsonb_build_object('source', 'xero', 'legacy_code', '1', 'action', 'map', 'code', v_plain.code),
      jsonb_build_object('source', 'xero', 'legacy_code', '7', 'action', 'merge', 'code', v_plain.code)),
      'XWB-' || v_tag, 'xero-chart');
    v_n := erp.validate_import(v_bad);
    v_cases := v_cases + 1;
    case_name := 'a missing account, a control account mapped, a plain account marked control, a taken code created, a type the chart cannot hold, a repeated legacy account and an unknown action are each refused';
    passed := v_n = 7
          and (select bool_and(r.action = 'reject') from erp.import_row r where r.import_batch_id = v_bad)
          and (select r.findings -> 0 ->> 'message' from erp.import_row r where r.import_batch_id = v_bad and r.row_no = 4)
              like '% is already %';
    detail := coalesce((select string_agg(r.row_no || ': ' || (r.findings -> 0 ->> 'message'), '; ' order by r.row_no)
                          from erp.import_row r where r.import_batch_id = v_bad), 'no rows');
    return next;

    -- 7. Loading creates only what was to be created, and changes nothing mapped.
    v_step := 'loading the chart';
    perform erp.preview_import(v_ab);
    v_n := erp.load_import(v_ab);
    v_cases := v_cases + 1;
    case_name := 'loading creates the new account and leaves every mapped account exactly as it was';
    passed := v_n = 3
          and exists (select 1 from erp.account a where a.tenant_id = ra.tenant_id and a.code = v_new
                         and a.name = 'Xero suspense' and a.account_type = 'liability' and a.is_postable)
          and (select to_jsonb(a) - 'updated_at' - 'updated_by' from erp.account a where a.id = v_plain.id)
              = to_jsonb(v_plain) - 'updated_at' - 'updated_by';
    detail := format('%s row(s) loaded', v_n);
    return next;

    -- 8. The chart resolves by legacy code, and by name where there is no code.
    v_x := erp.import_crosswalk('xero', 'account');
    v_cases := v_cases + 1;
    case_name := 'the chart''s entries resolve each legacy account to its Clove code';
    passed := jsonb_array_length(v_x) = 3
          and exists (select 1 from jsonb_array_elements(v_x) e
                       where e ->> 'legacy_key' = '200' and e ->> 'clove_code' = v_plain.code and e ->> 'resolution' = 'map')
          and exists (select 1 from jsonb_array_elements(v_x) e
                       where e ->> 'legacy_key' = '610' and e ->> 'clove_code' = v_recv and e ->> 'resolution' = 'control')
          and exists (select 1 from jsonb_array_elements(v_x) e
                       where e ->> 'legacy_key' = 'Suspense' and e ->> 'clove_code' = v_new and e ->> 'resolution' = 'create');
    detail := coalesce(v_x::text, 'no answer');
    return next;

    -- 9. Another organisation, through the doors, sees none of it while this
    --    one has a loaded chart and a saved mapping.
    v_step := 'reading as the other organisation';
    perform erp.save_import_mapping('xero-contacts', jsonb_build_object('name', '*ContactName'));
    perform set_config('request.jwt.claims',
      json_build_object('sub', a2, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_x := jsonb_build_array(public.erp_import_crosswalk('xero', 'account'), public.erp_import_mappings());
    execute format('set local role %I', v_owner);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'another organisation reads none of this one''s entries or mappings';
    passed := v_x = jsonb_build_array('[]'::jsonb, '{}'::jsonb)
          and jsonb_array_length(erp.import_crosswalk('xero', 'account')) = 3;
    detail := v_x::text;
    return next;

    -- 10. A created account something hangs from keeps the batch standing.
    v_step := 'hanging an account from the created one';
    insert into erp.account (tenant_id, entity_id, code, name, account_type, parent_account_id, is_postable)
    values (ra.tenant_id, v_entity, v_new || '-1', 'Child', 'liability',
            (select a.id from erp.account a where a.tenant_id = ra.tenant_id and a.code = v_new), true);
    v_err := null;
    begin
      perform erp.rollback_import(v_ab);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a chart batch whose new account is already in use cannot be rolled back';
    passed := v_err like 'CLOVEERP_ACCOUNT_IMPORT_IN_USE:%'
          and (select b.status::text from erp.import_batch b where b.id = v_ab) = 'loaded';
    detail := coalesce(v_err, 'it rolled back');
    return next;

    -- 11. Once nothing hangs from it, rollback removes the account and the entries.
    v_step := 'rolling the chart back';
    delete from erp.account a where a.tenant_id = ra.tenant_id and a.code = v_new || '-1';
    perform erp.rollback_import(v_ab);
    v_cases := v_cases + 1;
    case_name := 'rolling a chart back deletes the accounts it created and its entries, and nothing else';
    passed := not exists (select 1 from erp.account a where a.tenant_id = ra.tenant_id and a.code = v_new)
          and exists (select 1 from erp.account a where a.id = v_plain.id)
          and erp.import_crosswalk('xero', 'account') = '[]'::jsonb;
    detail := format('batch is %s', (select b.status::text from erp.import_batch b where b.id = v_ab));
    return next;

    -- 12. Header mappings are kept, replaced by the next, and malformed ones refused.
    v_step := 'saving a header mapping';
    perform erp.save_import_mapping('xero-contacts', jsonb_build_object('name', 'Contact Name'));
    v_err := null;
    begin
      perform erp.save_import_mapping('Xero Contacts!', jsonb_build_object('name', 'x'));
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a confirmed mapping is kept, replaced by the next, and a malformed one refused';
    passed := erp.import_mappings() = jsonb_build_object('xero-contacts', jsonb_build_object('name', 'Contact Name'))
          and v_err like 'CLOVEERP_IMPORT_MAPPING_SHAPE:%';
    detail := coalesce(erp.import_mappings()::text, 'nothing') || ' / ' || coalesce(v_err, 'accepted');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_IMPORT_CROSSWALK_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in ('xwa-' || v_tag, 'xwb-' || v_tag))
     or exists (select 1 from auth.users u where u.id in (a1, a2)) then
    raise exception 'CLOVEERP_IMPORT_CROSSWALK_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.import_crosswalk_suite() from public, anon, authenticated;

create or replace function erp_test.assert_import_crosswalk_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.import_crosswalk_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_IMPORT_CROSSWALK_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A legacy key would resolve to the wrong record, outlive its batch, or an import would change an account it only maps. Read the case that failed.';
  end if;
  if v_total <> 12 then
    raise exception 'CLOVEERP_IMPORT_CROSSWALK_SUITE_SHRANK: % case(s), expected 12', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('import crosswalk: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_import_crosswalk_suite() from public, anon;

comment on function erp_test.assert_import_crosswalk_suite() is
  'A legacy chart is mapped, not merged, and a legacy key resolves only while its batch stands (20261003600000).';

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
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
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
select erp.assert_parameter_budget();
