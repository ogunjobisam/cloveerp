-- =============================================================================
-- Addendum B, phase 2: posting classes and account determination
--
-- Determination returns the account AND the dimension set, from one rule. An
-- unmatched posting is refused: there is no suspense account to absorb a
-- configuration gap, because an absorbed gap is a gap nobody ever fixes.
-- =============================================================================

create type erp.posting_class_kind as enum ('item', 'party');

create table erp.posting_class (
  id           uuid not null default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  kind         erp.posting_class_kind not null,
  code         text not null check (code ~ '^[A-Z0-9][A-Z0-9_-]*$'),
  name         text not null,
  name_key     text,
  description  text,
  valid_from   date not null default current_date,
  valid_to     date,
  status       erp.record_status not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (id),
  unique (tenant_id, kind, code),
  check (valid_to is null or valid_to > valid_from)
);

create index on erp.posting_class (tenant_id, kind, status);

comment on table erp.posting_class is
  'Addendum B 2: the accounting vocabulary. Items and parties carry a class; '
  'determination rules are written against the class, never against the item.';

-- -----------------------------------------------------------------------------
-- Assignment, effective-dated, exactly one in force
-- -----------------------------------------------------------------------------

create table erp.item_posting_class (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  item_id          uuid not null,
  posting_class_id uuid not null,
  reason           text,
  valid_from       date not null default current_date,
  valid_to         date,
  status           erp.record_status not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  primary key (id),
  check (valid_to is null or valid_to > valid_from)
);

create unique index item_posting_class_one_current
  on erp.item_posting_class (tenant_id, item_id)
  where status = 'active' and valid_to is null;

create index on erp.item_posting_class (tenant_id, posting_class_id);

create table erp.party_posting_class (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  party_id         uuid not null,
  posting_class_id uuid not null,
  reason           text,
  valid_from       date not null default current_date,
  valid_to         date,
  status           erp.record_status not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  primary key (id),
  check (valid_to is null or valid_to > valid_from)
);

create unique index party_posting_class_one_current
  on erp.party_posting_class (tenant_id, party_id)
  where status = 'active' and valid_to is null;

-- -----------------------------------------------------------------------------
-- The determination matrix
--
-- Every dimension of the key is nullable and null means "any". Specificity is
-- computed, not typed, so two rules can never disagree about which is narrower.
-- -----------------------------------------------------------------------------

create table erp.account_determination (
  id                     uuid not null default gen_random_uuid(),
  tenant_id              uuid not null references erp.tenant(id) on delete cascade,
  transaction_type       text not null,
  item_class_id          uuid,
  party_class_id         uuid,
  site_id                uuid,
  entity_id              uuid,
  ledger_id              uuid,
  legislation_pack_code  text,
  reason_code            text,
  account_id             uuid not null,
  dimensions             jsonb not null default '{}'::jsonb,
  note                   text,
  version                integer not null default 1,
  valid_from             date not null default current_date,
  valid_to               date,
  status                 erp.record_status not null default 'active',
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  updated_by             uuid,
  primary key (id),
  check (valid_to is null or valid_to > valid_from),
  check (jsonb_typeof(dimensions) = 'object')
);

create index on erp.account_determination (tenant_id, transaction_type, status);
create unique index account_determination_key
  on erp.account_determination (
    tenant_id, transaction_type,
    coalesce(item_class_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(party_class_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(site_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(entity_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(ledger_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(legislation_pack_code, ''), coalesce(reason_code, ''), valid_from)
  where status = 'active';

comment on table erp.account_determination is
  'Addendum B 2: transaction type x posting classes x place -> account and '
  'dimensions. No suspense row is possible: an unmatched posting is refused.';

-- -----------------------------------------------------------------------------
-- Explicit, reasoned document-level override
-- -----------------------------------------------------------------------------

create table erp.posting_account_override (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  object_type      text not null,
  object_id        uuid not null,
  line_ref         text,
  transaction_type text,
  account_id       uuid not null,
  dimensions       jsonb not null default '{}'::jsonb,
  reason           text not null,
  applied_by       uuid,
  applied_at       timestamptz not null default now(),
  primary key (id)
);

create index on erp.posting_account_override (tenant_id, object_type, object_id);

comment on table erp.posting_account_override is
  'Addendum B 2: append-only record of a deliberate departure from the matrix.';

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, is_current)
values
  ('posting.rule_resolved', 1, 'posting', 'finance', 'event.posting.rule_resolved',
   'A determination rule chose an account and dimension set.', true),
  ('posting.determination_failed', 1, 'posting', 'finance', 'event.posting.determination_failed',
   'No rule matched, so the posting was refused.', true),
  ('posting.class_changed', 1, 'posting', 'finance', 'event.posting.class_changed',
   'An item or party moved to a different posting class.', true),
  ('posting.account_recorded', 1, 'posting', 'finance', 'event.posting.account_recorded',
   'A posting account was set explicitly against the matrix.', true)
on conflict (code, version) do nothing;

-- -----------------------------------------------------------------------------
-- Resolution
-- -----------------------------------------------------------------------------

create or replace function erp.determine_account(
  p_transaction_type text,
  p_item_id          uuid default null,
  p_party_id         uuid default null,
  p_site_id          uuid default null,
  p_entity_id        uuid default null,
  p_ledger_id        uuid default null,
  p_reason_code      text default null,
  p_on               date default null,
  p_raise            boolean default true
) returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant     uuid := erp.require_tenant_id();
  v_on         date := coalesce(p_on, current_date);
  v_item_class uuid;
  v_party_class uuid;
  v_pack       text;
  r            record;
begin
  select ipc.posting_class_id into v_item_class
    from erp.item_posting_class ipc
   where ipc.tenant_id = v_tenant and ipc.item_id = p_item_id
     and ipc.status = 'active'
     and daterange(ipc.valid_from, ipc.valid_to, '[)') @> v_on
   limit 1;

  select ppc.posting_class_id into v_party_class
    from erp.party_posting_class ppc
   where ppc.tenant_id = v_tenant and ppc.party_id = p_party_id
     and ppc.status = 'active'
     and daterange(ppc.valid_from, ppc.valid_to, '[)') @> v_on
   limit 1;

  if p_item_id is not null and v_item_class is null then
    if p_raise then
      raise exception
        'ERPWARE_POSTING_CLASS_MISSING: the item has no posting class in force on %', v_on
        using errcode = '23502';
    end if;
    return jsonb_build_object('matched', false, 'why', 'item_posting_class_missing');
  end if;

  select e.legislation_pack_code into v_pack
    from erp.entity_legislation e
   where e.tenant_id = v_tenant and e.entity_id = p_entity_id
   limit 1;

  select ad.* into r
    from erp.account_determination ad
   where ad.tenant_id = v_tenant
     and ad.transaction_type = p_transaction_type
     and ad.status = 'active'
     and daterange(ad.valid_from, ad.valid_to, '[)') @> v_on
     and (ad.item_class_id is null or ad.item_class_id = v_item_class)
     and (ad.party_class_id is null or ad.party_class_id = v_party_class)
     and (ad.site_id is null or ad.site_id = p_site_id)
     and (ad.entity_id is null or ad.entity_id = p_entity_id)
     and (ad.ledger_id is null or ad.ledger_id = p_ledger_id)
     and (ad.reason_code is null or ad.reason_code = p_reason_code)
     and (ad.legislation_pack_code is null
          or v_pack is null
          or ad.legislation_pack_code = v_pack)
   order by
     (ad.item_class_id is not null)::int + (ad.party_class_id is not null)::int
   + (ad.site_id is not null)::int + (ad.entity_id is not null)::int
   + (ad.ledger_id is not null)::int + (ad.reason_code is not null)::int
   + (ad.legislation_pack_code is not null)::int desc,
     ad.valid_from desc
   limit 1;

  if r.id is null then
    if p_raise then
      raise exception
        'ERPWARE_DETERMINATION_FAILED: no account rule matches % for this item, party and place',
        p_transaction_type
        using errcode = '23503';
    end if;
    return jsonb_build_object(
      'matched', false, 'why', 'no_rule',
      'transaction_type', p_transaction_type,
      'item_class_id', v_item_class, 'party_class_id', v_party_class);
  end if;

  return jsonb_build_object(
    'matched', true,
    'rule_id', r.id, 'rule_version', r.version,
    'transaction_type', p_transaction_type,
    'account_id', r.account_id,
    'account_code', (select a.code from erp.account a
                      where a.tenant_id = v_tenant and a.id = r.account_id),
    'account_name', (select a.name from erp.account a
                      where a.tenant_id = v_tenant and a.id = r.account_id),
    'dimensions', r.dimensions,
    'item_class_id', v_item_class, 'party_class_id', v_party_class,
    'resolved_on', v_on);
end;
$$;

comment on function erp.determine_account(text,uuid,uuid,uuid,uuid,uuid,text,date,boolean) is
  'Addendum B 2: the account and its dimensions, from the narrowest matching '
  'rule. Refuses rather than defaulting to a suspense account.';

-- -----------------------------------------------------------------------------
-- Coverage: every combination that can occur, and whether a rule covers it
-- -----------------------------------------------------------------------------

create or replace function erp.determination_coverage()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_gaps   jsonb;
  v_total  integer;
begin
  with combos as (
    select tt.transaction_type, ic.id as item_class_id, ic.code as item_class_code,
           e.id as entity_id, e.code as entity_code
      from (select distinct ad.transaction_type
              from erp.account_determination ad
             where ad.tenant_id = v_tenant) tt
      cross join (select pc.id, pc.code from erp.posting_class pc
                   where pc.tenant_id = v_tenant and pc.kind = 'item'
                     and pc.status = 'active') ic
      cross join (select en.id, en.code from erp.entity en
                   where en.tenant_id = v_tenant and en.status = 'active') e
  ),
  covered as (
    select c.*,
           exists (
             select 1 from erp.account_determination ad
              where ad.tenant_id = v_tenant
                and ad.status = 'active'
                and ad.transaction_type = c.transaction_type
                and (ad.item_class_id is null or ad.item_class_id = c.item_class_id)
                and (ad.entity_id is null or ad.entity_id = c.entity_id)
                and (ad.valid_to is null or ad.valid_to > current_date)) as ok
      from combos c
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'transaction_type', transaction_type,
           'item_class_code', item_class_code,
           'entity_code', entity_code) order by transaction_type, item_class_code),
         '[]'::jsonb),
         count(*)::int
    into v_gaps, v_total
    from covered where not ok;

  select count(*)::int into v_total from combos;

  return jsonb_build_object(
    'combinations', v_total,
    'gap_count', jsonb_array_length(v_gaps),
    'gaps', v_gaps,
    'complete', jsonb_array_length(v_gaps) = 0);
end;
$$;

-- -----------------------------------------------------------------------------
-- Public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_posting_classes(p_kind text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'kind', x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'posting_class_id', pc.id, 'kind', pc.kind::text, 'code', pc.code,
      'name', pc.name, 'description', pc.description,
      'valid_from', pc.valid_from, 'valid_to', pc.valid_to, 'status', pc.status,
      'label', pc.kind::text || ' · ' || pc.code || ' — ' || pc.name,
      'member_count', case when pc.kind = 'item'
        then (select count(*) from erp.item_posting_class i
               where i.tenant_id = pc.tenant_id and i.posting_class_id = pc.id
                 and i.status = 'active')
        else (select count(*) from erp.party_posting_class p
               where p.tenant_id = pc.tenant_id and p.posting_class_id = pc.id
                 and p.status = 'active') end) as x
      from erp.posting_class pc
     where pc.tenant_id = erp.current_tenant_id()
       and (p_kind is null or pc.kind::text = p_kind)
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_upsert_posting_class(
  p_kind        text,
  p_code        text,
  p_name        text,
  p_description text default null,
  p_valid_from  date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  perform erp.authorise('finance.configure');

  select pc.id into v_id from erp.posting_class pc
   where pc.tenant_id = v_tenant and pc.kind::text = p_kind and pc.code = upper(p_code);

  if v_id is null then
    insert into erp.posting_class (tenant_id, kind, code, name, description, valid_from)
    values (v_tenant, p_kind::erp.posting_class_kind, upper(p_code), p_name, p_description,
            coalesce(p_valid_from, current_date))
    returning id into v_id;
  else
    update erp.posting_class
       set name = p_name, description = coalesce(p_description, description),
           status = 'active', updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('posting_class_id', v_id, 'code', upper(p_code), 'kind', p_kind);
end;
$$;

create or replace function public.erp_retire_posting_class(p_posting_class_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_used integer;
begin
  perform erp.authorise('finance.configure');

  select count(*) into v_used from erp.account_determination ad
   where ad.tenant_id = v_tenant and ad.status = 'active'
     and (ad.item_class_id = p_posting_class_id or ad.party_class_id = p_posting_class_id);

  if v_used > 0 then
    raise exception
      'ERPWARE_CLASS_IN_USE: % determination rules still name this class', v_used
      using errcode = '23503';
  end if;

  update erp.posting_class
     set status = 'retired', valid_to = current_date, updated_at = now()
   where tenant_id = v_tenant and id = p_posting_class_id;

  return jsonb_build_object('posting_class_id', p_posting_class_id, 'status', 'retired');
end;
$$;

create or replace function public.erp_item_posting_classes(p_limit integer default 200)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'item_code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'item_id', i.id, 'item_code', i.code, 'item_name', i.name,
      'item_class', i.item_class,
      'posting_class_id', pc.id, 'posting_class_code', pc.code,
      'posting_class_name', pc.name,
      'valid_from', ipc.valid_from, 'reason', ipc.reason) as x
      from erp.item i
      left join erp.item_posting_class ipc
        on ipc.tenant_id = i.tenant_id and ipc.item_id = i.id
       and ipc.status = 'active'
       and daterange(ipc.valid_from, ipc.valid_to, '[)') @> current_date
      left join erp.posting_class pc
        on pc.tenant_id = i.tenant_id and pc.id = ipc.posting_class_id
     where i.tenant_id = erp.current_tenant_id()
       and i.status = 'active'
     order by (ipc.id is null) desc, i.code
     limit least(greatest(coalesce(p_limit, 200), 1), 1000)
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_party_posting_classes(p_limit integer default 200)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'party_code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'party_id', p.id, 'party_code', p.code, 'party_name', p.name,
      'posting_class_id', pc.id, 'posting_class_code', pc.code,
      'posting_class_name', pc.name,
      'valid_from', ppc.valid_from, 'reason', ppc.reason) as x
      from erp.party p
      left join erp.party_posting_class ppc
        on ppc.tenant_id = p.tenant_id and ppc.party_id = p.id
       and ppc.status = 'active'
       and daterange(ppc.valid_from, ppc.valid_to, '[)') @> current_date
      left join erp.posting_class pc
        on pc.tenant_id = p.tenant_id and pc.id = ppc.posting_class_id
     where p.tenant_id = erp.current_tenant_id()
       and p.status = 'active'
     order by (ppc.id is null) desc, p.code
     limit least(greatest(coalesce(p_limit, 200), 1), 1000)
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_set_item_posting_class(
  p_item_id          uuid,
  p_posting_class_id uuid,
  p_reason           text default null,
  p_valid_from       date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from date := coalesce(p_valid_from, current_date);
  v_old uuid;
  v_id uuid;
begin
  perform erp.authorise('finance.configure');

  if not exists (select 1 from erp.posting_class pc
                  where pc.tenant_id = v_tenant and pc.id = p_posting_class_id
                    and pc.kind = 'item' and pc.status = 'active') then
    raise exception 'ERPWARE_CLASS_UNKNOWN: that is not an active item posting class'
      using errcode = '23503';
  end if;

  select ipc.posting_class_id into v_old
    from erp.item_posting_class ipc
   where ipc.tenant_id = v_tenant and ipc.item_id = p_item_id
     and ipc.status = 'active' and ipc.valid_to is null;

  update erp.item_posting_class
     set valid_to = greatest(v_from, valid_from + 1), status = 'retired', updated_at = now()
   where tenant_id = v_tenant and item_id = p_item_id
     and status = 'active' and valid_to is null;

  insert into erp.item_posting_class (tenant_id, item_id, posting_class_id, reason, valid_from)
  values (v_tenant, p_item_id, p_posting_class_id, p_reason, v_from)
  returning id into v_id;

  perform erp.append_event('posting.class_changed', 'item', p_item_id,
    jsonb_build_object('from', v_old, 'to', p_posting_class_id,
                       'reason', p_reason, 'valid_from', v_from));

  return jsonb_build_object('assignment_id', v_id, 'item_id', p_item_id,
                            'posting_class_id', p_posting_class_id);
end;
$$;

create or replace function public.erp_set_party_posting_class(
  p_party_id         uuid,
  p_posting_class_id uuid,
  p_reason           text default null,
  p_valid_from       date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from date := coalesce(p_valid_from, current_date);
  v_old uuid;
  v_id uuid;
begin
  perform erp.authorise('finance.configure');

  if not exists (select 1 from erp.posting_class pc
                  where pc.tenant_id = v_tenant and pc.id = p_posting_class_id
                    and pc.kind = 'party' and pc.status = 'active') then
    raise exception 'ERPWARE_CLASS_UNKNOWN: that is not an active party posting class'
      using errcode = '23503';
  end if;

  select ppc.posting_class_id into v_old
    from erp.party_posting_class ppc
   where ppc.tenant_id = v_tenant and ppc.party_id = p_party_id
     and ppc.status = 'active' and ppc.valid_to is null;

  update erp.party_posting_class
     set valid_to = greatest(v_from, valid_from + 1), status = 'retired', updated_at = now()
   where tenant_id = v_tenant and party_id = p_party_id
     and status = 'active' and valid_to is null;

  insert into erp.party_posting_class (tenant_id, party_id, posting_class_id, reason, valid_from)
  values (v_tenant, p_party_id, p_posting_class_id, p_reason, v_from)
  returning id into v_id;

  perform erp.append_event('posting.class_changed', 'party', p_party_id,
    jsonb_build_object('from', v_old, 'to', p_posting_class_id,
                       'reason', p_reason, 'valid_from', v_from));

  return jsonb_build_object('assignment_id', v_id, 'party_id', p_party_id,
                            'posting_class_id', p_posting_class_id);
end;
$$;

create or replace function public.erp_account_determination_rules(
  p_transaction_type text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'transaction_type', x->>'account_code'), '[]'::jsonb)
    into v_out from (
    select jsonb_build_object(
      'rule_id', ad.id, 'transaction_type', ad.transaction_type,
      'item_class_code', ic.code, 'party_class_code', pcl.code,
      'site_code', s.code, 'entity_code', e.code, 'ledger_code', l.code,
      'legislation_pack_code', ad.legislation_pack_code,
      'reason_code', ad.reason_code,
      'account_id', ad.account_id, 'account_code', a.code, 'account_name', a.name,
      'dimensions', ad.dimensions, 'note', ad.note,
      'version', ad.version, 'valid_from', ad.valid_from, 'valid_to', ad.valid_to,
      'status', ad.status,
      'specificity',
        (ad.item_class_id is not null)::int + (ad.party_class_id is not null)::int
      + (ad.site_id is not null)::int + (ad.entity_id is not null)::int
      + (ad.ledger_id is not null)::int + (ad.reason_code is not null)::int) as x
      from erp.account_determination ad
      left join erp.posting_class ic on ic.tenant_id = ad.tenant_id and ic.id = ad.item_class_id
      left join erp.posting_class pcl on pcl.tenant_id = ad.tenant_id and pcl.id = ad.party_class_id
      left join erp.site s on s.tenant_id = ad.tenant_id and s.id = ad.site_id
      left join erp.entity e on e.tenant_id = ad.tenant_id and e.id = ad.entity_id
      left join erp.ledger l on l.tenant_id = ad.tenant_id and l.id = ad.ledger_id
      join erp.account a on a.tenant_id = ad.tenant_id and a.id = ad.account_id
     where ad.tenant_id = erp.current_tenant_id()
       and (p_transaction_type is null or ad.transaction_type = p_transaction_type)
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_upsert_account_determination(
  p_transaction_type      text,
  p_account_id            uuid,
  p_item_class_id         uuid default null,
  p_party_class_id        uuid default null,
  p_site_id               uuid default null,
  p_entity_id             uuid default null,
  p_ledger_id             uuid default null,
  p_reason_code           text default null,
  p_legislation_pack_code text default null,
  p_dimensions            jsonb default null,
  p_note                  text default null,
  p_valid_from            date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from date := coalesce(p_valid_from, current_date);
  v_id uuid;
begin
  perform erp.authorise('finance.configure');

  if not exists (select 1 from erp.account a
                  where a.tenant_id = v_tenant and a.id = p_account_id and a.is_postable) then
    raise exception 'ERPWARE_ACCOUNT_NOT_POSTABLE: that account cannot take a posting'
      using errcode = '23514';
  end if;

  select ad.id into v_id from erp.account_determination ad
   where ad.tenant_id = v_tenant
     and ad.transaction_type = p_transaction_type
     and ad.status = 'active'
     and ad.item_class_id is not distinct from p_item_class_id
     and ad.party_class_id is not distinct from p_party_class_id
     and ad.site_id is not distinct from p_site_id
     and ad.entity_id is not distinct from p_entity_id
     and ad.ledger_id is not distinct from p_ledger_id
     and ad.reason_code is not distinct from p_reason_code
     and ad.legislation_pack_code is not distinct from p_legislation_pack_code
     and ad.valid_from = v_from;

  if v_id is null then
    insert into erp.account_determination (
      tenant_id, transaction_type, item_class_id, party_class_id, site_id, entity_id,
      ledger_id, legislation_pack_code, reason_code, account_id, dimensions, note, valid_from)
    values (v_tenant, p_transaction_type, p_item_class_id, p_party_class_id, p_site_id,
            p_entity_id, p_ledger_id, p_legislation_pack_code, p_reason_code, p_account_id,
            coalesce(p_dimensions, '{}'::jsonb), p_note, v_from)
    returning id into v_id;
  else
    update erp.account_determination
       set account_id = p_account_id,
           dimensions = coalesce(p_dimensions, dimensions),
           note = coalesce(p_note, note),
           version = version + 1,
           updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('rule_id', v_id, 'transaction_type', p_transaction_type);
end;
$$;

create or replace function public.erp_retire_account_determination(p_rule_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('finance.configure');
  update erp.account_determination
     set status = 'retired', valid_to = current_date, updated_at = now()
   where tenant_id = v_tenant and id = p_rule_id;
  return jsonb_build_object('rule_id', p_rule_id, 'status', 'retired');
end;
$$;

create or replace function public.erp_determine_account(
  p_transaction_type text,
  p_item_id          uuid default null,
  p_party_id         uuid default null,
  p_site_id          uuid default null,
  p_entity_id        uuid default null,
  p_ledger_id        uuid default null,
  p_reason_code      text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  perform erp.authorise('finance.read');
  v_out := erp.determine_account(p_transaction_type, p_item_id, p_party_id, p_site_id,
                                 p_entity_id, p_ledger_id, p_reason_code, current_date, false);

  if coalesce((v_out->>'matched')::boolean, false) then
    perform erp.append_event('posting.rule_resolved', 'posting',
      nullif(v_out->>'rule_id','')::uuid, v_out);
  else
    perform erp.append_event('posting.determination_failed', 'posting', null,
      v_out || jsonb_build_object('item_id', p_item_id, 'party_id', p_party_id));
  end if;

  return v_out;
end;
$$;

create or replace function public.erp_determination_coverage()
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('finance.read');
  return erp.determination_coverage();
end;
$$;

create or replace function public.erp_override_posting_account(
  p_object_type text,
  p_object_id   uuid,
  p_account_id  uuid,
  p_reason      text,
  p_line_ref    text default null,
  p_dimensions  jsonb default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  perform erp.authorise('finance.post');

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'ERPWARE_REASON_REQUIRED: an override has to say why'
      using errcode = '23514';
  end if;

  insert into erp.posting_account_override (
    tenant_id, object_type, object_id, line_ref, account_id, dimensions, reason, applied_by)
  values (v_tenant, p_object_type, p_object_id, p_line_ref, p_account_id,
          coalesce(p_dimensions, '{}'::jsonb), p_reason, erp.current_principal_id())
  returning id into v_id;

  perform erp.append_event('posting.account_recorded', 'posting', p_object_id,
    jsonb_build_object('object_type', p_object_type, 'account_id', p_account_id,
                       'line_ref', p_line_ref, 'reason', p_reason));

  return jsonb_build_object('override_id', v_id);
end;
$$;

create or replace function public.erp_posting_overrides(p_limit integer default 100)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'applied_at' desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'override_id', o.id, 'object_type', o.object_type, 'object_id', o.object_id,
      'line_ref', o.line_ref, 'account_code', a.code, 'account_name', a.name,
      'reason', o.reason, 'applied_at', o.applied_at, 'applied_by', u.display_name) as x
      from erp.posting_account_override o
      left join erp.account a on a.tenant_id = o.tenant_id and a.id = o.account_id
      left join erp.app_user u on u.tenant_id = o.tenant_id and u.id = o.applied_by
     where o.tenant_id = erp.current_tenant_id()
     order by o.applied_at desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500)
  ) s;
  return v_out;
end;
$$;

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
      'entity_id', a.entity_id, 'status', a.status) as x
      from erp.account a
     where a.tenant_id = erp.current_tenant_id()
       and a.status = 'active'
       and (not p_postable_only or a.is_postable)
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_entities()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'entity_id', e.id, 'code', e.code, 'name', e.name,
      'base_currency', e.base_currency, 'country_code', e.country_code) as x
      from erp.entity e
     where e.tenant_id = erp.current_tenant_id() and e.status = 'active'
  ) s;
  return v_out;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_posting_classes(text)',
    'public.erp_upsert_posting_class(text,text,text,text,date)',
    'public.erp_retire_posting_class(uuid)',
    'public.erp_item_posting_classes(integer)',
    'public.erp_party_posting_classes(integer)',
    'public.erp_set_item_posting_class(uuid,uuid,text,date)',
    'public.erp_set_party_posting_class(uuid,uuid,text,date)',
    'public.erp_account_determination_rules(text)',
    'public.erp_upsert_account_determination(text,uuid,uuid,uuid,uuid,uuid,uuid,text,text,jsonb,text,date)',
    'public.erp_retire_account_determination(uuid)',
    'public.erp_determine_account(text,uuid,uuid,uuid,uuid,uuid,text)',
    'public.erp_determination_coverage()',
    'public.erp_override_posting_account(text,uuid,uuid,text,text,jsonb)',
    'public.erp_posting_overrides(integer)',
    'public.erp_accounts(boolean)',
    'public.erp_entities()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;

select erp.apply_row_security();