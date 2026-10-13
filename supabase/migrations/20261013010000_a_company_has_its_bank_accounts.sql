-- A company has its bank accounts.
--
-- The first of five pull requests that build bank reconciliation (the owner's
-- choice of 13 October 2026, after v1). A statement is imported into a bank
-- account, so the bank account has to exist as a thing of its own first.
--
-- Until now a bank was any ledger account with control kind bank, and
-- erp.company_bank_account(entity) took the active one with the lowest code.
-- Every route that moves money used it (Apply cash, the payment run,
-- prepayments, the demonstration), so a company that opened a second bank
-- account had every receipt and payment land in the lowest-coded one, with
-- nothing to say which was meant.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.bank_account: a company's bank account, on one ledger account of
--      control kind bank, with its name, sort code and the last four digits
--      of its number (never the full number), its currency, whether it is the
--      company's default, and whether it is open. One default per company.
--      Foreign-currency bank accounts are refused for now, as the cash routes
--      already refuse foreign cash (CLOVEERP_NO_TRANSLATION).
--   B. Every existing bank ledger account becomes a bank account, and the
--      lowest-coded one in each company its default, so nothing changes for
--      any organisation on the day this lands. A bank ledger account made
--      later (the finance installer's, for a new organisation) becomes one as
--      it is made, by a trigger on erp.account.
--   C. erp.company_bank_account(entity) answers the company's default bank
--      account, and only where a company has none recorded the lowest-coded
--      bank ledger account, as before.
--   D. Doors under finance.configure: erp_define_bank_account opens one (and
--      its ledger account, when the code is new), erp_update_bank_account
--      changes its details or makes it the default, erp_close_bank_account
--      closes one that is not the default. erp_bank_accounts lists them.
--   E. erp_test.bank_account_suite proves it.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The table
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.bank_account (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  entity_id     uuid not null,
  account_id    uuid not null,
  name          text not null,
  sort_code     text,
  account_last4 text,
  currency      char(3) not null,
  is_default    boolean not null default false,
  status        text not null default 'open',
  closed_reason text,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  constraint bank_account_tenant_id_id_key unique (tenant_id, id),
  constraint bank_account_ledger_once unique (tenant_id, account_id),
  constraint bank_account_entity_fk foreign key (tenant_id, entity_id) references erp.entity(tenant_id, id) on delete restrict,
  constraint bank_account_account_fk foreign key (tenant_id, account_id) references erp.account(tenant_id, id) on delete restrict,
  constraint bank_account_status_known check (status in ('open', 'closed')),
  constraint bank_account_name_given check (btrim(name) <> ''),
  constraint bank_account_sort_code_shape check (sort_code is null or sort_code ~ '^[0-9]{2}-[0-9]{2}-[0-9]{2}$'),
  constraint bank_account_last4_shape check (account_last4 is null or account_last4 ~ '^[0-9]{4}$'),
  constraint bank_account_closed_says_why check (status <> 'closed' or coalesce(btrim(closed_reason), '') <> ''),
  constraint bank_account_closed_not_default check (status <> 'closed' or not is_default)
);

create unique index if not exists bank_account_one_default
  on erp.bank_account (tenant_id, entity_id) where is_default;

comment on table erp.bank_account is
  'A company''s bank account (20261013010000): the ledger account of control kind bank it posts to, its name, '
  'sort code and the last four digits of its number, its currency, and whether it is the company''s default.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'bank_account', 'tenant_scoped', 'A company''s bank account; its details and default move, and it is closed rather than deleted.')
on conflict (schema_name, table_name) do nothing;

-- A bank account is on a bank ledger account of its own company, in the
-- company's own currency.
create or replace function erp.bank_account_is_sound()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  a erp.account%rowtype;
  v_base char(3);
begin
  select x.* into a from erp.account x where x.tenant_id = new.tenant_id and x.id = new.account_id;
  if a.id is null or a.control_kind is distinct from 'bank' or a.entity_id is distinct from new.entity_id then
    raise exception 'CLOVEERP_BANK_ACCOUNT_NOT_A_BANK: % is not a bank ledger account of this company', coalesce(a.code, 'the account')
      using errcode = '23514',
            hint = 'Choose an account code that is new, or one already of control kind bank in the same company.';
  end if;
  select e.base_currency into v_base from erp.entity e where e.tenant_id = new.tenant_id and e.id = new.entity_id;
  if new.currency is distinct from v_base then
    raise exception 'CLOVEERP_BANK_ACCOUNT_CURRENCY: a bank account in % is not supported; this company keeps its books in %', new.currency, v_base
      using errcode = '0A000',
            hint = 'Open the bank account in the company''s own currency. Foreign-currency bank accounts are not supported yet.';
  end if;
  return new;
end;
$$;
revoke all on function erp.bank_account_is_sound() from public, anon, authenticated;

drop trigger if exists t_bank_account_is_sound on erp.bank_account;
create trigger t_bank_account_is_sound
  before insert or update of account_id, entity_id, currency on erp.bank_account
  for each row execute function erp.bank_account_is_sound();

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Every existing bank ledger account is a bank account
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp.bank_account (tenant_id, entity_id, account_id, name, currency, is_default)
select a.tenant_id, a.entity_id, a.id, a.name, e.base_currency,
       a.id = (select a2.id from erp.account a2
                where a2.tenant_id = a.tenant_id and a2.entity_id = a.entity_id
                  and a2.control_kind = 'bank' and a2.status = 'active'
                order by a2.code limit 1)
  from erp.account a
  join erp.entity e on e.tenant_id = a.tenant_id and e.id = a.entity_id
 where a.control_kind = 'bank' and a.status = 'active'
   and coalesce(a.currency, e.base_currency) = e.base_currency
on conflict (tenant_id, account_id) do nothing;

-- And one made later becomes one as it is made: the default where the company
-- has none. One in another currency is left alone, as the backfill leaves it.
create or replace function erp.bank_ledger_account_is_a_bank_account()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_base char(3);
begin
  if new.control_kind is distinct from 'bank' or new.status <> 'active' then
    return new;
  end if;
  select e.base_currency into v_base from erp.entity e where e.tenant_id = new.tenant_id and e.id = new.entity_id;
  if coalesce(new.currency, v_base) is distinct from v_base then
    return new;
  end if;
  insert into erp.bank_account (tenant_id, entity_id, account_id, name, currency, is_default)
  values (new.tenant_id, new.entity_id, new.id, new.name, v_base,
          not exists (select 1 from erp.bank_account b
                       where b.tenant_id = new.tenant_id and b.entity_id = new.entity_id and b.is_default))
  on conflict (tenant_id, account_id) do nothing;
  return new;
end;
$$;
revoke all on function erp.bank_ledger_account_is_a_bank_account() from public, anon, authenticated;

drop trigger if exists t_account_bank_account on erp.account;
create trigger t_account_bank_account
  after insert or update of control_kind, status on erp.account
  for each row execute function erp.bank_ledger_account_is_a_bank_account();

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The company's bank is its default bank account
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.company_bank_account(p_entity_id uuid)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_bank uuid;
begin
  -- The bank the money reaches, or leaves, is the bank of the company that is
  -- owed, or that owes (20260929300000): its default bank account
  -- (20261013010000), or, where it has recorded none, its lowest-coded bank
  -- ledger account, as before.
  select b.account_id into v_bank
    from erp.bank_account b
    join erp.account a on a.tenant_id = b.tenant_id and a.id = b.account_id and a.status = 'active'
   where b.tenant_id = erp.current_tenant_id() and b.entity_id = p_entity_id
     and b.is_default and b.status = 'open';
  if v_bank is null then
    select a.id into v_bank from erp.account a
     where a.tenant_id = erp.current_tenant_id() and a.entity_id = p_entity_id
       and a.control_kind = 'bank' and a.status = 'active'
     order by a.code limit 1;
  end if;
  if v_bank is null then
    raise exception 'CLOVEERP_NO_BANK_ACCOUNT: % has no bank account for this cash to land in or leave from',
      coalesce((select e.code from erp.entity e where e.id = p_entity_id), p_entity_id::text)
      using errcode = '23503',
            hint = 'Give the company a postable account with control kind bank; the finance installer creates one. Cash is not banked in another company''s name.';
  end if;
  return v_bank;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The doors
-- ─────────────────────────────────────────────────────────────────────────────

-- A sort code as the bank prints it, or null; refused when it is not six digits.
create or replace function erp.bank_sort_code(p_sort_code text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := regexp_replace(coalesce(p_sort_code, ''), '[\s-]', '', 'g');
begin
  if v = '' then
    return null;
  end if;
  if v !~ '^[0-9]{6}$' then
    raise exception 'CLOVEERP_BANK_ACCOUNT_DETAILS: % is not a sort code', p_sort_code
      using errcode = '22023', hint = 'A sort code is six digits, such as 20-00-00.';
  end if;
  return substr(v, 1, 2) || '-' || substr(v, 3, 2) || '-' || substr(v, 5, 2);
end;
$$;
revoke all on function erp.bank_sort_code(text) from public, anon;

create or replace function erp.bank_account_last4(p_last4 text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := regexp_replace(coalesce(p_last4, ''), '\s', '', 'g');
begin
  if v = '' then
    return null;
  end if;
  if v !~ '^[0-9]{4}$' then
    raise exception 'CLOVEERP_BANK_ACCOUNT_DETAILS: % is not the last four digits of an account number', p_last4
      using errcode = '22023', hint = 'Give only the last four digits of the account number; the full number is never kept.';
  end if;
  return v;
end;
$$;
revoke all on function erp.bank_account_last4(text) from public, anon;

-- Makes one bank account the company's default, and no other.
create or replace function erp.make_default_bank_account(p_bank_account_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  b erp.bank_account%rowtype;
begin
  select x.* into b from erp.bank_account x where x.tenant_id = erp.require_tenant_id() and x.id = p_bank_account_id;
  update erp.bank_account set is_default = false, updated_at = now()
   where tenant_id = b.tenant_id and entity_id = b.entity_id and is_default and id <> b.id;
  update erp.bank_account set is_default = true, updated_at = now()
   where tenant_id = b.tenant_id and id = b.id and not is_default;
end;
$$;
revoke all on function erp.make_default_bank_account(uuid) from public, anon, authenticated;

create or replace function erp.define_bank_account(
  p_entity_id     uuid,
  p_account_code  text,
  p_name          text,
  p_sort_code     text    default null,
  p_account_last4 text    default null,
  p_make_default  boolean default false)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  e        erp.entity%rowtype;
  a        erp.account%rowtype;
  v_code   text := btrim(coalesce(p_account_code, ''));
  v_name   text := btrim(coalesce(p_name, ''));
  v_parent text;
  v_id     uuid;
begin
  select x.* into e from erp.entity x where x.tenant_id = v_tenant and x.id = p_entity_id;
  perform erp.authorise('finance.configure', p_entity_id, null, null, 'bank_account', null, null);
  if e.id is null then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: no such company in this organisation'
      using errcode = '23503', hint = 'Choose one of this organisation''s companies.';
  end if;
  if v_code = '' or v_name = '' then
    raise exception 'CLOVEERP_BANK_ACCOUNT_DETAILS: a bank account needs a ledger account code and a name'
      using errcode = '22023', hint = 'Give the ledger code it posts to, such as 1010, and the name the bank gives it.';
  end if;

  select x.* into a from erp.account x where x.tenant_id = v_tenant and x.entity_id = e.id and x.code = v_code;
  if a.id is null then
    -- A new ledger account beside the company's existing bank, in its group.
    select x.code into v_parent from erp.account x
     where x.tenant_id = v_tenant and x.entity_id = e.id
       and x.id = (select b.parent_account_id from erp.account b
                    where b.tenant_id = v_tenant and b.entity_id = e.id and b.control_kind = 'bank'
                    order by b.code limit 1);
    v_id := erp.upsert_account(e.code, v_code, v_name, 'asset'::erp.account_type, 'bank'::erp.control_account_kind,
                               (select b.group_code from erp.account b
                                 where b.tenant_id = v_tenant and b.entity_id = e.id and b.control_kind = 'bank'
                                 order by b.code limit 1),
                               true, '{}'::text[], e.base_currency, v_parent, false, false);
  elsif a.control_kind is distinct from 'bank' then
    raise exception 'CLOVEERP_BANK_ACCOUNT_NOT_A_BANK: % is not a bank ledger account of this company', v_code
      using errcode = '23514',
            hint = 'Choose an account code that is new, or one already of control kind bank in the same company.';
  else
    v_id := a.id;
  end if;

  insert into erp.bank_account (tenant_id, entity_id, account_id, name, sort_code, account_last4, currency, is_default)
  values (v_tenant, e.id, v_id, v_name, erp.bank_sort_code(p_sort_code), erp.bank_account_last4(p_account_last4),
          e.base_currency, false)
  on conflict (tenant_id, account_id) do update
     set name = excluded.name, sort_code = excluded.sort_code, account_last4 = excluded.account_last4,
         status = 'open', closed_reason = null, updated_at = now()
  returning id into v_id;

  if coalesce(p_make_default, false)
     or not exists (select 1 from erp.bank_account b
                     where b.tenant_id = v_tenant and b.entity_id = e.id and b.is_default) then
    perform erp.make_default_bank_account(v_id);
  end if;

  return jsonb_build_object('bank_account_id', v_id, 'name', v_name, 'account_code', v_code,
                            'is_default', (select b.is_default from erp.bank_account b where b.id = v_id));
end;
$$;
revoke all on function erp.define_bank_account(uuid, text, text, text, text, boolean) from public, anon;

create or replace function erp.update_bank_account(
  p_bank_account_id uuid,
  p_name            text    default null,
  p_sort_code       text    default null,
  p_account_last4   text    default null,
  p_make_default    boolean default false)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.bank_account%rowtype;
begin
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = p_bank_account_id for update;
  perform erp.authorise('finance.configure', b.entity_id, null, null, 'bank_account', p_bank_account_id, null);
  if b.id is null or b.status <> 'open' then
    raise exception 'CLOVEERP_BANK_ACCOUNT_NOT_OPEN: that bank account is not open in this organisation'
      using errcode = '23514', hint = 'Choose an open bank account; a closed one is reopened by defining it again.';
  end if;

  update erp.bank_account
     set name = coalesce(nullif(btrim(coalesce(p_name, '')), ''), name),
         sort_code = case when p_sort_code is null then sort_code else erp.bank_sort_code(p_sort_code) end,
         account_last4 = case when p_account_last4 is null then account_last4 else erp.bank_account_last4(p_account_last4) end,
         updated_at = now()
   where tenant_id = v_tenant and id = b.id;
  if coalesce(p_make_default, false) then
    perform erp.make_default_bank_account(b.id);
  end if;

  return (select jsonb_build_object('bank_account_id', x.id, 'name', x.name, 'is_default', x.is_default)
            from erp.bank_account x where x.id = b.id);
end;
$$;
revoke all on function erp.update_bank_account(uuid, text, text, text, boolean) from public, anon;

create or replace function erp.close_bank_account(p_bank_account_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.bank_account%rowtype;
begin
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = p_bank_account_id for update;
  perform erp.authorise('finance.configure', b.entity_id, null, null, 'bank_account', p_bank_account_id, null);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_REASON_REQUIRED: closing a bank account needs a reason'
      using errcode = '23514', hint = 'Say why the bank account is closed, so the auditor can read it.';
  end if;
  if b.id is null or b.status <> 'open' then
    raise exception 'CLOVEERP_BANK_ACCOUNT_NOT_OPEN: that bank account is not open in this organisation'
      using errcode = '23514', hint = 'Choose an open bank account; a closed one is reopened by defining it again.';
  end if;
  if b.is_default then
    raise exception 'CLOVEERP_BANK_ACCOUNT_IS_DEFAULT: % is the company''s default bank account', b.name
      using errcode = '23514', hint = 'Make another bank account the default first, then close this one.';
  end if;

  update erp.bank_account set status = 'closed', closed_reason = btrim(p_reason), updated_at = now()
   where tenant_id = v_tenant and id = b.id;
  return jsonb_build_object('bank_account_id', b.id, 'name', b.name, 'status', 'closed');
end;
$$;
revoke all on function erp.close_bank_account(uuid, text) from public, anon;

create or replace function public.erp_define_bank_account(
  p_entity_id uuid, p_account_code text, p_name text,
  p_sort_code text default null, p_account_last4 text default null, p_make_default boolean default false)
returns jsonb
language sql
set search_path = ''
as $$ select erp.define_bank_account(p_entity_id, p_account_code, p_name, p_sort_code, p_account_last4, p_make_default) $$;
revoke all on function public.erp_define_bank_account(uuid, text, text, text, text, boolean) from public, anon;
grant execute on function public.erp_define_bank_account(uuid, text, text, text, text, boolean) to authenticated, service_role;
comment on function public.erp_define_bank_account(uuid, text, text, text, text, boolean) is
  'Opens a bank account for a company on a ledger account of control kind bank, new or existing (20261013010000). Authorises finance.configure.';

create or replace function public.erp_update_bank_account(
  p_bank_account_id uuid, p_name text default null, p_sort_code text default null,
  p_account_last4 text default null, p_make_default boolean default false)
returns jsonb
language sql
set search_path = ''
as $$ select erp.update_bank_account(p_bank_account_id, p_name, p_sort_code, p_account_last4, p_make_default) $$;
revoke all on function public.erp_update_bank_account(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.erp_update_bank_account(uuid, text, text, text, boolean) to authenticated, service_role;
comment on function public.erp_update_bank_account(uuid, text, text, text, boolean) is
  'Changes a bank account''s name, sort code or last four digits, or makes it the company''s default (20261013010000). Authorises finance.configure.';

create or replace function public.erp_close_bank_account(p_bank_account_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.close_bank_account(p_bank_account_id, p_reason) $$;
revoke all on function public.erp_close_bank_account(uuid, text) from public, anon;
grant execute on function public.erp_close_bank_account(uuid, text) to authenticated, service_role;
comment on function public.erp_close_bank_account(uuid, text) is
  'Closes a bank account that is not the company''s default, with a reason (20261013010000). Authorises finance.configure.';

create or replace function public.erp_bank_accounts()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The organisation's bank accounts, by company and code: each one's ledger
  -- account, details, currency and whether it is the default (20261013010000).
  select coalesce(jsonb_agg(x order by x->>'entity', x->>'account_code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'bank_account_id', b.id, 'entity_id', b.entity_id, 'entity', e.code,
      'account_id', b.account_id, 'account_code', a.code, 'name', b.name,
      'sort_code', b.sort_code, 'account_last4', b.account_last4, 'currency', b.currency,
      'is_default', b.is_default, 'status', b.status, 'closed_reason', b.closed_reason) as x
      from erp.bank_account b
      join erp.entity e on e.tenant_id = b.tenant_id and e.id = b.entity_id
      join erp.account a on a.tenant_id = b.tenant_id and a.id = b.account_id
     where b.tenant_id = erp.current_tenant_id()) t
$$;
revoke all on function public.erp_bank_accounts() from public, anon;
grant execute on function public.erp_bank_accounts() to authenticated, service_role;
comment on function public.erp_bank_accounts() is
  'The organisation''s bank accounts, by company and ledger code (20261013010000). Reads under row security as the caller.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_define_bank_account', 'erp.define_bank_account',
   'Opens a bank account on a bank ledger account, new or existing; authorises finance.configure.'),
  ('erp_update_bank_account', 'erp.update_bank_account',
   'Changes a bank account''s details or makes it the default; authorises finance.configure.'),
  ('erp_close_bank_account', 'erp.close_bank_account',
   'Closes a bank account that is not the default, with a reason; authorises finance.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_BANK_ACCOUNT_NOT_A_BANK',
  'Opening a bank account on a ledger account that is not a bank account of the same company.',
  'A bank account posts to a ledger account of control kind bank; putting it on a sales or stock account would post cash where no cash is.',
  'Choose an account code that is new, or one already of control kind bank in the same company.');
select erp.register_refusal('CLOVEERP_BANK_ACCOUNT_CURRENCY',
  'Opening a bank account in a currency other than the company''s own.',
  'The cash routes refuse foreign cash, so a foreign-currency bank account would hold money nothing can post.',
  'Open the bank account in the company''s own currency. Foreign-currency bank accounts are not supported yet.');
select erp.register_refusal('CLOVEERP_BANK_ACCOUNT_DETAILS',
  'Giving a bank account a sort code, last four digits or name that is not one.',
  'A statement is matched to its bank account by these details, and the full account number is never kept.',
  'Give a six-digit sort code, only the last four digits of the account number, and a name.');
select erp.register_refusal('CLOVEERP_BANK_ACCOUNT_NOT_OPEN',
  'Changing or closing a bank account that is closed or not in this organisation.',
  'A closed bank account takes no cash and no statement.',
  'Choose an open bank account; a closed one is reopened by defining it again.');
select erp.register_refusal('CLOVEERP_BANK_ACCOUNT_IS_DEFAULT',
  'Closing the company''s default bank account.',
  'The default is where receipts and payments land; closing it would leave cash with nowhere to go.',
  'Make another bank account the default first, then close this one.');

-- The screen, and its help.
insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.finance_bank', 'en', 'Bank', 'finance', 'The bank accounts screen (20261013010000).'),
  ('nav.finance_bank', 'de', 'Bank', 'finance', 'Bankkonten (20261013010000).')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/finance/bank', 'nav.finance_bank', 'finance',
   'The company''s bank accounts: which ledger account each posts to, its sort code and the last four digits of its number, and which is the default that receipts and payments use. Statements are imported into a bank account and reconciled against it.',
   '["Check the default: receipts and payments land in it.","Open another bank account with a new ledger code, or on an existing bank ledger account.","Make a different account the default when the company moves its banking.","Close an account the company no longer uses, with a reason; the default cannot be closed until another takes its place."]',
   'Check which bank account is the default; open another if the company banks in more than one.',
   '{erp_bank_accounts,erp_define_bank_account,erp_update_bank_account,erp_close_bank_account}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The bank accounts screen (20261013010000).'
  from (values
    ('1010'),
    ('1234'),
    ('20-00-00'),
    ('A bank account posts to a ledger account of its own. Give a new ledger code to open one, or the code of an existing bank ledger account.'),
    ('A closed bank account takes no cash and no statement. Defining it again reopens it.'),
    ('A new code opens a bank ledger account beside the company''s existing bank.'),
    ('Account ending'),
    ('Bank accounts'),
    ('Change its name, sort code or last four digits, or make it the default. A box left empty keeps what is there.'),
    ('Change this bank account'),
    ('Close the account'),
    ('Close this bank account'),
    ('Closed'),
    ('Company'),
    ('Currency'),
    ('Default'),
    ('Kept with the account for the auditor.'),
    ('Last four digits of the account number'),
    ('Ledger code'),
    ('Make it the default'),
    ('Name'),
    ('No bank account yet. Installing finance opens the company''s first.'),
    ('Only the last four digits are kept, never the full number.'),
    ('Open a bank account'),
    ('Open the account'),
    ('Reading the bank accounts…'),
    ('Receipts and payments land in the default bank account. Statements are imported into a bank account and reconciled against it. The default cannot be closed until another account takes its place.'),
    ('Receipts and payments land in the default.'),
    ('Reserve account'),
    ('Save'),
    ('Sort code'),
    ('The company no longer banks here'),
    ('The company''s bank accounts, and which one receipts and payments use.'),
    ('Why it is closed')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.bank_account_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid;
  v_first  uuid; v_second uuid; v_bank uuid;
  x        jsonb;
  v_ok     boolean; v_msg text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzbac' || v_tag, 'Bank Account Suite',
      'admin@demo-zzbac' || v_tag || '.test', 'Bank Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzbac' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_ent from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    -- The company's bank, as the finance installer made it, became a bank
    -- account as it was made.
    select b.id into v_first from erp.bank_account b where b.tenant_id = v_tenant and b.entity_id = v_ent and b.is_default;

    -- ── 1. The installed bank is the default ────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the bank the finance installer made is a bank account and the default as it is made, and cash still lands in it';
    passed := v_state is null and v_first is not null
          and erp.company_bank_account(v_ent) = (select b.account_id from erp.bank_account b where b.id = v_first);
    detail := coalesce(v_state, coalesce(v_first::text, 'no default'));
    return next;

    -- ── 2. A second account, with a new ledger code ─────────────────────────
    v_step := 'a second bank account';
    x := public.erp_define_bank_account(v_ent, '1010', 'Reserve account', '40 47 84', '1234', false);
    v_second := (x ->> 'bank_account_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'a second bank account opens its own bank ledger account, keeps only the last four digits, and is not the default';
    passed := v_state is null
          and (select a.control_kind = 'bank' and a.code = '1010' from erp.bank_account b
                 join erp.account a on a.id = b.account_id where b.id = v_second)
          and (select b.sort_code = '40-47-84' and b.account_last4 = '1234' and not b.is_default
                 from erp.bank_account b where b.id = v_second)
          and erp.company_bank_account(v_ent) = (select b.account_id from erp.bank_account b where b.id = v_first);
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 3. Moving the default moves the cash ────────────────────────────────
    v_step := 'making the second account the default';
    perform public.erp_update_bank_account(v_second, null, null, null, true);
    v_cases := v_cases + 1;
    case_name := 'made the default, the second account is where cash lands, and the company has one default';
    passed := v_state is null
          and erp.company_bank_account(v_ent) = (select b.account_id from erp.bank_account b where b.id = v_second)
          and (select count(*) from erp.bank_account b where b.tenant_id = v_tenant and b.entity_id = v_ent and b.is_default) = 1;
    detail := coalesce(v_state, (select string_agg(b.name || case when b.is_default then ' (default)' else '' end, ', ')
                                   from erp.bank_account b where b.tenant_id = v_tenant));
    return next;

    -- ── 4. What is not a bank, or not in pounds, is refused ─────────────────
    v_step := 'refusals';
    begin
      perform public.erp_define_bank_account(v_ent, (select a.code from erp.account a
                                                      where a.tenant_id = v_tenant and a.entity_id = v_ent
                                                        and a.control_kind is null and a.is_postable
                                                      order by a.code limit 1), 'Not a bank', null, null, false);
      v_ok := false; v_msg := 'a non-bank ledger account was taken';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_ACCOUNT_NOT_A_BANK%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform public.erp_define_bank_account(v_ent, '1020', 'Bad sort code', '12-34', null, false);
      v_ok := false; v_msg := v_msg || '; a short sort code was taken';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_ACCOUNT_DETAILS%'; v_msg := v_msg || ' / ' || left(sqlerrm, 70);
    end;
    begin
      insert into erp.bank_account (tenant_id, entity_id, account_id, name, currency)
      select v_tenant, v_ent, b.account_id, 'Euro account', 'EUR' from erp.bank_account b where b.id = v_first
      on conflict (tenant_id, account_id) do update set currency = 'EUR';
      v_ok := false; v_msg := v_msg || '; a euro bank account was taken';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_ACCOUNT_CURRENCY%'; v_msg := v_msg || ' / ' || left(sqlerrm, 70);
    end;
    v_cases := v_cases + 1;
    case_name := 'a ledger account that is not a bank, a sort code that is not six digits and a foreign currency are refused by name';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 5. The default cannot be closed; another can ────────────────────────
    v_step := 'closing';
    begin
      perform public.erp_close_bank_account(v_second, 'moved banks');
      v_ok := false; v_msg := 'the default was closed';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_ACCOUNT_IS_DEFAULT%'; v_msg := left(sqlerrm, 90);
    end;
    perform public.erp_close_bank_account(v_first, 'the old current account is closed');
    v_cases := v_cases + 1;
    case_name := 'the default bank account cannot be closed, and another closes with its reason';
    passed := v_state is null and v_ok
          and (select b.status = 'closed' and b.closed_reason is not null from erp.bank_account b where b.id = v_first);
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 6. The list ─────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the list names each account by company and code, with its details and state';
    passed := v_state is null
          and (select count(*) from jsonb_array_elements(public.erp_bank_accounts()) r) = 2
          and exists (select 1 from jsonb_array_elements(public.erp_bank_accounts()) r
                       where r ->> 'account_code' = '1010' and (r ->> 'is_default')::boolean and r ->> 'sort_code' = '40-47-84')
          and exists (select 1 from jsonb_array_elements(public.erp_bank_accounts()) r where r ->> 'status' = 'closed');
    detail := coalesce(v_state, public.erp_bank_accounts()::text);
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
    raise exception 'CLOVEERP_BANK_ACCOUNT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.bank_account_suite() from public, anon, authenticated;

create or replace function erp_test.assert_bank_account_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _bank_account on commit drop as
    select * from erp_test.bank_account_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _bank_account;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_BANK_ACCOUNT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_BANK_ACCOUNT_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('bank account: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_bank_account_suite() from public, anon, authenticated;

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
