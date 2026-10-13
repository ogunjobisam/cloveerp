-- A bank statement is imported.
--
-- Bank reconciliation, pull request 2 of 5 (owner, 13 October 2026). A bank
-- account (20261013010000) receives its statements: read in the browser from
-- the bank's CSV (Barclays, Lloyds, NatWest, HSBC, Starling, Monzo, Tide, or
-- any other mapped once) or OFX, and checked again here before a line is kept.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.bank_statement and erp.bank_statement_line: a statement of one bank
--      account, its period, opening and closing balances and the file it came
--      from; each line's date, signed amount (in positive, out negative),
--      description, reference, the bank's own id where OFX gives one, and a
--      fingerprint. A line is unmatched until matching (pull request 3) says
--      otherwise.
--   B. public.erp_import_bank_statement, under finance.post, refuses by name:
--        the same file twice (its SHA-256 per bank account);
--        a line already imported on another statement (its fingerprint: the
--          bank's id, or the date, amount, description and how many times that
--          same line occurs that day);
--        a statement whose opening balance is not the last one's closing;
--        lines that do not add up from the opening to the closing balance;
--        an empty statement, or a line without a date, an amount or words.
--      The first statement of an account needs its opening balance said; a
--      later one takes the last one's closing when none is given.
--   C. public.erp_withdraw_bank_statement: the latest statement of an account,
--      imported in error and nothing done with it yet, is taken out again, with
--      a reason kept in the audit trail.
--   D. public.erp_bank_statements and public.erp_bank_statement_lines list them.
--   E. erp_test.bank_statement_import_suite proves B and C.

create table if not exists erp.bank_statement (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  bank_account_id   uuid not null,
  format            text not null,
  source            text not null,
  file_sha256       text not null,
  starts_on         date not null,
  ends_on           date not null,
  opening_minor     bigint not null,
  closing_minor     bigint not null,
  line_count        integer not null,
  status            text not null default 'imported',
  reconciled_at     timestamptz,
  reconciled_by     uuid,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint bank_statement_tenant_id_id_key unique (tenant_id, id),
  constraint bank_statement_file_once unique (tenant_id, bank_account_id, file_sha256),
  constraint bank_statement_account_fk foreign key (tenant_id, bank_account_id) references erp.bank_account(tenant_id, id) on delete restrict,
  constraint bank_statement_format_known check (format in ('csv', 'ofx')),
  constraint bank_statement_status_known check (status in ('imported', 'reconciled')),
  constraint bank_statement_period_in_order check (ends_on >= starts_on),
  constraint bank_statement_sha_shape check (file_sha256 ~ '^[0-9a-f]{64}$'),
  constraint bank_statement_has_lines check (line_count > 0)
);
create index if not exists bank_statement_account on erp.bank_statement (tenant_id, bank_account_id, ends_on);

create table if not exists erp.bank_statement_line (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  statement_id      uuid not null,
  bank_account_id   uuid not null,
  line_no           integer not null,
  booked_on         date not null,
  amount_minor      bigint not null,
  description       text not null,
  reference         text,
  fitid             text,
  balance_minor     bigint,
  fingerprint       text not null,
  status            text not null default 'unmatched',
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint bank_statement_line_tenant_id_id_key unique (tenant_id, id),
  constraint bank_statement_line_once unique (tenant_id, bank_account_id, fingerprint),
  constraint bank_statement_line_no_once unique (tenant_id, statement_id, line_no),
  constraint bank_statement_line_statement_fk foreign key (tenant_id, statement_id) references erp.bank_statement(tenant_id, id) on delete cascade,
  constraint bank_statement_line_account_fk foreign key (tenant_id, bank_account_id) references erp.bank_account(tenant_id, id) on delete restrict,
  constraint bank_statement_line_amount_nonzero check (amount_minor <> 0),
  constraint bank_statement_line_described check (btrim(description) <> ''),
  constraint bank_statement_line_status_known check (status in ('unmatched', 'matched', 'posted'))
);
create index if not exists bank_statement_line_open on erp.bank_statement_line (tenant_id, bank_account_id, booked_on)
  where status = 'unmatched';

comment on table erp.bank_statement is
  'A statement of one bank account (20261013020000): its period, opening and closing balances, the file it came from '
  'by SHA-256, and whether it is reconciled.';
comment on table erp.bank_statement_line is
  'A line of a bank statement (20261013020000): date, signed amount (in positive, out negative), words, reference, '
  'the bank''s id where OFX gives one, and the fingerprint that refuses importing it twice.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'bank_statement', 'tenant_scoped', 'A bank statement; imported, then reconciled, or withdrawn while nothing has been done with it.'),
  ('erp', 'bank_statement_line', 'tenant_scoped', 'A line of a bank statement; its status moves as it is matched or posted.')
on conflict (schema_name, table_name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Importing
-- ─────────────────────────────────────────────────────────────────────────────

-- The words of a line as the fingerprint reads them: case and spacing do not
-- make two lines different.
create or replace function erp.bank_line_words(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$ select lower(regexp_replace(btrim(coalesce(p_text, '')), '\s+', ' ', 'g')) $$;
revoke all on function erp.bank_line_words(text) from public, anon;

create or replace function erp.import_bank_statement(
  p_bank_account_id uuid,
  p_format          text,
  p_source          text,
  p_file_sha256     text,
  p_closing_minor   bigint,
  p_lines           jsonb,
  p_opening_minor   bigint default null,
  p_starts_on       date   default null,
  p_ends_on         date   default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  b          erp.bank_account%rowtype;
  prev       erp.bank_statement%rowtype;
  v_opening  bigint;
  v_total    bigint;
  v_starts   date;
  v_ends     date;
  v_count    integer;
  v_bad      text;
  v_dupes    integer;
  v_first    date;
  v_id       uuid;
begin
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = p_bank_account_id;
  perform erp.authorise('finance.post', b.entity_id, null, null, 'bank_statement', null, null);
  if b.id is null or b.status <> 'open' then
    raise exception 'CLOVEERP_BANK_ACCOUNT_NOT_OPEN: that bank account is not open in this organisation'
      using errcode = '23514', hint = 'Choose an open bank account; a closed one is reopened by defining it again.';
  end if;
  if coalesce(p_format, '') not in ('csv', 'ofx') or coalesce(btrim(p_source), '') = ''
     or coalesce(p_file_sha256, '') !~ '^[0-9a-f]{64}$' then
    raise exception 'CLOVEERP_BANK_STATEMENT_INVALID: a statement needs its format, the layout it was read with, and its file''s SHA-256'
      using errcode = '22023', hint = 'Import the bank''s file from the Bank screen, which reads all three from it.';
  end if;
  if jsonb_typeof(coalesce(p_lines, 'null'::jsonb)) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'CLOVEERP_BANK_STATEMENT_INVALID: the statement has no lines'
      using errcode = '22023', hint = 'A statement with nothing on it has nothing to reconcile; import one that has lines.';
  end if;

  -- Every line has a date, a non-zero amount in whole minor units, and words.
  select string_agg(format('line %s', e.n), ', ' order by e.n) into v_bad
    from jsonb_array_elements(p_lines) with ordinality as e(l, n)
   where not coalesce(pg_catalog.pg_input_is_valid(e.l ->> 'booked_on', 'date'), false)
      or not coalesce(pg_catalog.pg_input_is_valid(e.l ->> 'amount_minor', 'bigint'), false)
      or coalesce((e.l ->> 'amount_minor')::numeric, 0) = 0
      or coalesce(btrim(e.l ->> 'description'), '') = ''
      or (e.l ->> 'balance_minor' is not null and not pg_catalog.pg_input_is_valid(e.l ->> 'balance_minor', 'bigint'));
  if v_bad is not null then
    raise exception 'CLOVEERP_BANK_STATEMENT_INVALID: % of the statement lack a date, an amount or words', v_bad
      using errcode = '22023', hint = 'Every line needs its date, a non-zero amount in pence and a description. Check the column mapping.';
  end if;

  if exists (select 1 from erp.bank_statement s
              where s.tenant_id = v_tenant and s.bank_account_id = b.id and s.file_sha256 = p_file_sha256) then
    raise exception 'CLOVEERP_BANK_STATEMENT_ALREADY_IMPORTED: this file has already been imported into %', b.name
      using errcode = '23505', hint = 'Nothing new to import. Export the next period from the bank to continue.';
  end if;

  select count(*)::integer, sum((e.l ->> 'amount_minor')::bigint), min((e.l ->> 'booked_on')::date), max((e.l ->> 'booked_on')::date)
    into v_count, v_total, v_starts, v_ends
    from jsonb_array_elements(p_lines) e(l);
  v_starts := coalesce(p_starts_on, v_starts);
  v_ends := coalesce(p_ends_on, v_ends);
  if v_ends < v_starts or v_starts > (select min((e.l ->> 'booked_on')::date) from jsonb_array_elements(p_lines) e(l))
     or v_ends < (select max((e.l ->> 'booked_on')::date) from jsonb_array_elements(p_lines) e(l)) then
    raise exception 'CLOVEERP_BANK_STATEMENT_INVALID: the statement''s period does not hold all its lines'
      using errcode = '22023', hint = 'Leave the period empty to take it from the lines, or widen it to hold them all.';
  end if;

  -- The balances run on from the last statement, and add up.
  select s.* into prev from erp.bank_statement s
   where s.tenant_id = v_tenant and s.bank_account_id = b.id
   order by s.ends_on desc, s.created_at desc limit 1;
  v_opening := coalesce(p_opening_minor, prev.closing_minor);
  if v_opening is null then
    raise exception 'CLOVEERP_BANK_STATEMENT_OPENING_NEEDED: the first statement of % needs its opening balance', b.name
      using errcode = '22023', hint = 'Give the opening balance the bank prints at the top of this statement. Later statements take it from the one before.';
  end if;
  if prev.id is not null and v_opening <> prev.closing_minor then
    raise exception 'CLOVEERP_BANK_STATEMENT_BREAK: this statement opens at %, and the last one closed at %',
      to_char(v_opening / 100.0, 'FM999,999,999,990.00'), to_char(prev.closing_minor / 100.0, 'FM999,999,999,990.00')
      using errcode = '23514', hint = 'Import the statements in order, with nothing missing between them. A gap means a statement has not been imported yet.';
  end if;
  if v_opening + v_total <> p_closing_minor then
    raise exception 'CLOVEERP_BANK_STATEMENT_DOES_NOT_ADD_UP: the lines take % to %, not the closing balance %',
      to_char(v_opening / 100.0, 'FM999,999,999,990.00'), to_char((v_opening + v_total) / 100.0, 'FM999,999,999,990.00'),
      to_char(p_closing_minor / 100.0, 'FM999,999,999,990.00')
      using errcode = '23514', hint = 'A line is missing or doubled, or a balance was typed wrong. Export the whole period again.';
  end if;

  insert into erp.bank_statement (tenant_id, bank_account_id, format, source, file_sha256, starts_on, ends_on,
                                  opening_minor, closing_minor, line_count)
  values (v_tenant, b.id, p_format, btrim(p_source), p_file_sha256, v_starts, v_ends, v_opening, p_closing_minor, v_count)
  returning id into v_id;

  -- A line's fingerprint: the bank's own id where it gives one; otherwise its
  -- date, amount and words, and how many times that same line has occurred
  -- that day on the statement, so two identical lines on one day stay two.
  create temp table if not exists _bank_lines (
    n integer, booked_on date, amount_minor bigint, description text, reference text,
    fitid text, balance_minor bigint, fingerprint text) on commit drop;
  truncate _bank_lines;
  insert into _bank_lines
  select e.n, (e.l ->> 'booked_on')::date, (e.l ->> 'amount_minor')::bigint, btrim(e.l ->> 'description'),
         nullif(btrim(coalesce(e.l ->> 'reference', '')), ''), nullif(btrim(coalesce(e.l ->> 'fitid', '')), ''),
         (e.l ->> 'balance_minor')::bigint,
         case when nullif(btrim(coalesce(e.l ->> 'fitid', '')), '') is not null
              then 'fitid:' || btrim(e.l ->> 'fitid')
              else md5(concat_ws('|', e.l ->> 'booked_on', e.l ->> 'amount_minor', erp.bank_line_words(e.l ->> 'description'),
                                 row_number() over (partition by e.l ->> 'booked_on', e.l ->> 'amount_minor',
                                                                 erp.bank_line_words(e.l ->> 'description')
                                                    order by e.n))) end
    from jsonb_array_elements(p_lines) with ordinality as e(l, n);

  select count(*), min(t.booked_on) into v_dupes, v_first
    from _bank_lines t
   where exists (select 1 from erp.bank_statement_line x
                  where x.tenant_id = v_tenant and x.bank_account_id = b.id and x.fingerprint = t.fingerprint);
  if v_dupes > 0 then
    raise exception 'CLOVEERP_BANK_STATEMENT_LINES_ALREADY_IMPORTED: % line(s) from % on are already on another statement of %', v_dupes, v_first, b.name
      using errcode = '23505', hint = 'Export the bank''s statement from the day after the last one imported, so no line is imported twice.';
  end if;

  insert into erp.bank_statement_line (tenant_id, statement_id, bank_account_id, line_no, booked_on, amount_minor,
                                       description, reference, fitid, balance_minor, fingerprint)
  select v_tenant, v_id, b.id, t.n, t.booked_on, t.amount_minor, t.description, t.reference, t.fitid, t.balance_minor, t.fingerprint
    from _bank_lines t order by t.n;

  return jsonb_build_object('statement_id', v_id, 'bank_account', b.name, 'lines', v_count,
                            'starts_on', v_starts, 'ends_on', v_ends,
                            'opening_minor', v_opening, 'closing_minor', p_closing_minor);
end;
$$;
revoke all on function erp.import_bank_statement(uuid, text, text, text, bigint, jsonb, bigint, date, date) from public, anon;

create or replace function public.erp_import_bank_statement(
  p_bank_account_id uuid, p_format text, p_source text, p_file_sha256 text, p_closing_minor bigint, p_lines jsonb,
  p_opening_minor bigint default null, p_starts_on date default null, p_ends_on date default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.import_bank_statement(p_bank_account_id, p_format, p_source, p_file_sha256, p_closing_minor, p_lines,
                                       p_opening_minor, p_starts_on, p_ends_on) $$;
revoke all on function public.erp_import_bank_statement(uuid, text, text, text, bigint, jsonb, bigint, date, date) from public, anon;
grant execute on function public.erp_import_bank_statement(uuid, text, text, text, bigint, jsonb, bigint, date, date) to authenticated, service_role;
comment on function public.erp_import_bank_statement(uuid, text, text, text, bigint, jsonb, bigint, date, date) is
  'Imports a bank statement''s lines into a bank account, refusing a file or a line imported before and balances that '
  'do not run on or add up (20261013020000). Authorises finance.post.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Withdrawing one imported in error
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.withdraw_bank_statement(p_statement_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.bank_statement%rowtype;
  b        erp.bank_account%rowtype;
begin
  select x.* into s from erp.bank_statement x where x.tenant_id = v_tenant and x.id = p_statement_id for update;
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = s.bank_account_id;
  perform erp.authorise('finance.post', b.entity_id, null, null, 'bank_statement', p_statement_id, null);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_REASON_REQUIRED: withdrawing a bank statement needs a reason'
      using errcode = '23514', hint = 'Say why the statement is taken out, so the auditor can read it.';
  end if;
  if s.id is null or s.status <> 'imported'
     or exists (select 1 from erp.bank_statement_line l where l.tenant_id = v_tenant and l.statement_id = s.id and l.status <> 'unmatched')
     or exists (select 1 from erp.bank_statement later
                 where later.tenant_id = v_tenant and later.bank_account_id = s.bank_account_id and later.id <> s.id
                   and (later.ends_on > s.ends_on or (later.ends_on = s.ends_on and later.created_at > s.created_at))) then
    raise exception 'CLOVEERP_BANK_STATEMENT_CANNOT_WITHDRAW: only the latest statement of an account, with nothing matched or reconciled on it, is withdrawn'
      using errcode = '23514', hint = 'Withdraw the later statements first, and unmatch any line of this one.';
  end if;

  -- The deletion is audited row by row by the audit trigger; the reason, which
  -- no row carries, is the event's.
  perform erp.append_event('bank_statement.withdrawn', 'bank_statement', s.id,
                           jsonb_build_object('bank_account', b.name, 'starts_on', s.starts_on, 'ends_on', s.ends_on,
                                              'lines', s.line_count, 'reason', btrim(p_reason)),
                           b.entity_id);
  delete from erp.bank_statement where tenant_id = v_tenant and id = s.id;
  return jsonb_build_object('statement_id', s.id, 'withdrawn', true, 'lines', s.line_count);
end;
$$;
revoke all on function erp.withdraw_bank_statement(uuid, text) from public, anon;

create or replace function public.erp_withdraw_bank_statement(p_statement_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.withdraw_bank_statement(p_statement_id, p_reason) $$;
revoke all on function public.erp_withdraw_bank_statement(uuid, text) from public, anon;
grant execute on function public.erp_withdraw_bank_statement(uuid, text) to authenticated, service_role;
comment on function public.erp_withdraw_bank_statement(uuid, text) is
  'Takes out the latest statement of a bank account, imported in error and nothing done with it, with a reason (20261013020000). Authorises finance.post.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Reading them
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_bank_statements(p_bank_account_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The statements of the organisation's bank accounts, newest first, with how
  -- many of their lines are still unmatched (20261013020000).
  select coalesce(jsonb_agg(x order by x->>'ends_on' desc, x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'statement_id', s.id, 'bank_account_id', s.bank_account_id, 'bank_account', b.name,
      'format', s.format, 'source', s.source, 'starts_on', s.starts_on, 'ends_on', s.ends_on,
      'opening_minor', s.opening_minor, 'closing_minor', s.closing_minor, 'currency', b.currency,
      'line_count', s.line_count, 'status', s.status, 'created_at', s.created_at,
      'unmatched', (select count(*) from erp.bank_statement_line l
                     where l.tenant_id = s.tenant_id and l.statement_id = s.id and l.status = 'unmatched')) as x
      from erp.bank_statement s
      join erp.bank_account b on b.tenant_id = s.tenant_id and b.id = s.bank_account_id
     where s.tenant_id = erp.current_tenant_id()
       and (p_bank_account_id is null or s.bank_account_id = p_bank_account_id)) t
$$;
revoke all on function public.erp_bank_statements(uuid) from public, anon;
grant execute on function public.erp_bank_statements(uuid) to authenticated, service_role;
comment on function public.erp_bank_statements(uuid) is
  'The organisation''s bank statements, newest first, with their unmatched lines counted (20261013020000). Reads only.';

create or replace function public.erp_bank_statement_lines(p_statement_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_id', l.id, 'line_no', l.line_no, 'booked_on', l.booked_on, 'amount_minor', l.amount_minor,
           'description', l.description, 'reference', l.reference, 'balance_minor', l.balance_minor,
           'status', l.status) order by l.line_no), '[]'::jsonb)
    from erp.bank_statement_line l
   where l.tenant_id = erp.current_tenant_id() and l.statement_id = p_statement_id
$$;
revoke all on function public.erp_bank_statement_lines(uuid) from public, anon;
grant execute on function public.erp_bank_statement_lines(uuid) to authenticated, service_role;
comment on function public.erp_bank_statement_lines(uuid) is
  'The lines of one bank statement, in the bank''s order (20261013020000). Reads only.';

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('bank_statement.withdrawn', 1, 'bank_statement', 'finance', 'event.bank_statement.withdrawn',
   'A bank statement imported in error was taken out again, with nothing done with it.',
   '{"type":"object","required":["bank_account","lines","reason"],"properties":{"bank_account":{"type":"string"},"starts_on":{"type":"string"},"ends_on":{"type":"string"},"lines":{"type":"integer"},"reason":{"type":"string"}}}'::jsonb, true)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.bank_statement.withdrawn', 'en', 'Bank statement withdrawn', 'finance',
   'Event raised when a bank statement imported in error is taken out again.'),
  ('event.bank_statement.withdrawn', 'de', 'Kontoauszug zurückgenommen', 'finance',
   'Ereignis, wenn ein irrtümlich importierter Kontoauszug wieder entfernt wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_import_bank_statement', 'erp.import_bank_statement',
   'Imports a bank statement into a bank account, refusing duplicates and balances that do not run on or add up; authorises finance.post.'),
  ('erp_withdraw_bank_statement', 'erp.withdraw_bank_statement',
   'Takes out the latest statement of an account, imported in error, with a reason; authorises finance.post.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_BANK_STATEMENT_INVALID',
  'Importing a statement with no lines, a line without a date, amount or words, or a period that does not hold its lines.',
  'A line without its date or amount cannot be matched, and an empty statement has nothing to reconcile.',
  'Import the bank''s file from the Bank screen, and check the column mapping if the file was mapped by hand.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_ALREADY_IMPORTED',
  'Importing the same statement file into a bank account twice.',
  'Every line of it is already on a statement; importing it again would double the bank.',
  'Nothing new to import. Export the next period from the bank to continue.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_LINES_ALREADY_IMPORTED',
  'Importing a statement whose lines overlap a statement already imported.',
  'A line on two statements would be matched twice and reconciled twice.',
  'Export the bank''s statement from the day after the last one imported, so no line is imported twice.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_OPENING_NEEDED',
  'Importing the first statement of a bank account without its opening balance.',
  'The first statement is where the account''s running balance starts; later ones take it from the one before.',
  'Give the opening balance the bank prints at the top of this statement.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_BREAK',
  'Importing a statement whose opening balance is not the closing balance of the one before.',
  'A gap or an overlap between statements means a line has been missed or doubled, and the reconciliation would be wrong.',
  'Import the statements in order, with nothing missing between them.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_DOES_NOT_ADD_UP',
  'Importing a statement whose lines do not add up from its opening balance to its closing balance.',
  'A statement that does not add up is missing a line or carries one twice.',
  'Export the whole period again; check the balances typed against the bank''s statement.');
select erp.register_refusal('CLOVEERP_BANK_STATEMENT_CANNOT_WITHDRAW',
  'Withdrawing a statement that is not the latest of its account, or has lines matched or reconciled.',
  'Taking out an earlier statement would break the running balance of the later ones, and a matched line has already been relied on.',
  'Withdraw the later statements first, and unmatch any line of this one.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Importing a bank statement (20261013020000).'
  from (values
    ('1010'),
    ('1234'),
    ('20-00-00'),
    ('A CSV from Barclays, Lloyds, NatWest, HSBC, Starling, Monzo or Tide is read as it comes; any other CSV is mapped once. OFX is read from any bank.'),
    ('A bank account posts to a ledger account of its own. Give a new ledger code to open one, or the code of an existing bank ledger account.'),
    ('A closed bank account takes no cash and no statement. Defining it again reopens it.'),
    ('A new code opens a bank ledger account beside the company''s existing bank.'),
    ('Account ending'),
    ('Amount'),
    ('Amount (money in positive, out negative)'),
    ('Balance'),
    ('Bank account'),
    ('Bank accounts'),
    ('Change its name, sort code or last four digits, or make it the default. A box left empty keeps what is there.'),
    ('Change this bank account'),
    ('Close the account'),
    ('Close this bank account'),
    ('Closed'),
    ('Closing balance'),
    ('Company'),
    ('Currency'),
    ('Date'),
    ('Default'),
    ('Description'),
    ('From the last statement'),
    ('Give the closing balance the bank prints on this statement.'),
    ('Hide the lines'),
    ('Import a statement'),
    ('Import the statement'),
    ('Imported into the wrong account'),
    ('Importing…'),
    ('In'),
    ('Kept with the account for the auditor.'),
    ('Kept with the withdrawal for the auditor.'),
    ('Last four digits of the account number'),
    ('Ledger code'),
    ('Line'),
    ('Lines'),
    ('Make it the default'),
    ('Mapped by hand'),
    ('Matched'),
    ('Name'),
    ('No bank account yet. Installing finance opens the company''s first.'),
    ('No statement imported yet.'),
    ('Not in this file'),
    ('Only the last four digits are kept, never the full number.'),
    ('Open a bank account'),
    ('Open the account'),
    ('Opening balance'),
    ('Out'),
    ('Paid in'),
    ('Paid out'),
    ('Period'),
    ('Read the file with this mapping'),
    ('Reading the bank accounts…'),
    ('Reading the statements…'),
    ('Receipts and payments land in the default bank account. Statements are imported into a bank account and reconciled against it. The default cannot be closed until another account takes its place.'),
    ('Receipts and payments land in the default.'),
    ('Reference'),
    ('Reserve account'),
    ('Save'),
    ('Show the lines'),
    ('Sort code'),
    ('Start again'),
    ('State'),
    ('Statement file'),
    ('Statements'),
    ('Takes out the latest statement of an account, imported in error and nothing done with it yet. Its lines can then be imported again.'),
    ('The company no longer banks here'),
    ('The opening balance is not an amount.'),
    ('This file''s layout is not one Clove knows. Say which column holds what.'),
    ('Unmatched'),
    ('Why it is closed'),
    ('Why it is withdrawn'),
    ('Withdraw it'),
    ('Withdraw this statement'),
    ('and'),
    ('description'),
    ('lines'),
    ('more')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.bank_statement_import_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid;
  v_bank   uuid;
  v_s1     uuid; v_s2 uuid;
  x        jsonb;
  v_ok     boolean; v_msg text;
  v_sha1   text := md5('one') || md5('one-b');
  v_sha2   text := md5('two') || md5('two-b');
  v_sha3   text := md5('three') || md5('three-b');
  v_lines1 jsonb := '[{"booked_on":"2026-09-01","amount_minor":50000,"description":"ACME LTD INV-000412"},
                      {"booked_on":"2026-09-02","amount_minor":-1250,"description":"HSBC CHARGES"},
                      {"booked_on":"2026-09-02","amount_minor":-1250,"description":"HSBC CHARGES"}]'::jsonb;
  v_lines2 jsonb := '[{"booked_on":"2026-09-03","amount_minor":-20000,"description":"RENT","fitid":"F-9"}]'::jsonb;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzbsi' || v_tag, 'Bank Statement Suite',
      'admin@demo-zzbsi' || v_tag || '.test', 'Statement Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzbsi' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_ent from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select b.id into v_bank from erp.bank_account b where b.tenant_id = v_tenant and b.entity_id = v_ent and b.is_default;

    -- ── 1. The first statement needs its opening ────────────────────────────
    v_step := 'a first statement without its opening balance';
    begin
      perform public.erp_import_bank_statement(v_bank, 'csv', 'lloyds', v_sha1, 147500, v_lines1);
      v_ok := false; v_msg := 'taken without an opening balance';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_STATEMENT_OPENING_NEEDED%'; v_msg := left(sqlerrm, 100);
    end;
    v_cases := v_cases + 1;
    case_name := 'the first statement of an account needs its opening balance';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 2. It must add up ───────────────────────────────────────────────────
    begin
      perform public.erp_import_bank_statement(v_bank, 'csv', 'lloyds', v_sha1, 999999, v_lines1, 100000);
      v_ok := false; v_msg := 'taken although it does not add up';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_STATEMENT_DOES_NOT_ADD_UP%'; v_msg := left(sqlerrm, 120);
    end;
    v_cases := v_cases + 1;
    case_name := 'a statement whose lines do not add up from opening to closing is refused, saying where they take it';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 3. Imported, two identical charges stay two ─────────────────────────
    v_step := 'importing the first statement';
    x := public.erp_import_bank_statement(v_bank, 'csv', 'lloyds', v_sha1, 147500, v_lines1, 100000);
    v_s1 := (x ->> 'statement_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'imported, its period comes from its lines, and two identical charges on one day stay two lines';
    passed := v_state is null
          and (select s.starts_on = '2026-09-01' and s.ends_on = '2026-09-02' and s.line_count = 3
                 from erp.bank_statement s where s.id = v_s1)
          and (select count(distinct l.fingerprint) from erp.bank_statement_line l where l.statement_id = v_s1) = 3
          and (select count(*) from erp.bank_statement_line l where l.statement_id = v_s1 and l.status = 'unmatched') = 3;
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 4. The same file, or the same lines, again ──────────────────────────
    v_step := 'importing again';
    begin
      perform public.erp_import_bank_statement(v_bank, 'csv', 'lloyds', v_sha1, 195000, v_lines1);
      v_ok := false; v_msg := 'the same file was taken twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_STATEMENT_ALREADY_IMPORTED%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform public.erp_import_bank_statement(v_bank, 'csv', 'lloyds', v_sha3, 195000, v_lines1);
      v_ok := false; v_msg := v_msg || '; the same lines in another file were taken';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_STATEMENT_LINES_ALREADY_IMPORTED%'; v_msg := v_msg || ' / ' || left(sqlerrm, 90);
    end;
    v_cases := v_cases + 1;
    case_name := 'the same file is refused by its hash, and the same lines in another file by their fingerprints';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 5. The next statement runs on, or is refused ────────────────────────
    v_step := 'the next statement';
    begin
      perform public.erp_import_bank_statement(v_bank, 'ofx', 'ofx', v_sha2, 117500, v_lines2, 137500);
      v_ok := false; v_msg := 'a statement that does not run on was taken';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_STATEMENT_BREAK%'; v_msg := left(sqlerrm, 100);
    end;
    x := public.erp_import_bank_statement(v_bank, 'ofx', 'ofx', v_sha2, 127500, v_lines2);
    v_s2 := (x ->> 'statement_id')::uuid;
    v_cases := v_cases + 1;
    case_name := 'the next statement takes the last closing balance as its opening, and one that does not run on is refused';
    passed := v_state is null and v_ok
          and (select s.opening_minor = 147500 and s.closing_minor = 127500 from erp.bank_statement s where s.id = v_s2)
          and exists (select 1 from erp.bank_statement_line l where l.statement_id = v_s2 and l.fingerprint = 'fitid:F-9');
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 6. Only the latest is withdrawn ─────────────────────────────────────
    v_step := 'withdrawing';
    begin
      perform public.erp_withdraw_bank_statement(v_s1, 'wrong account');
      v_ok := false; v_msg := 'an earlier statement was withdrawn';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_STATEMENT_CANNOT_WITHDRAW%'; v_msg := left(sqlerrm, 90);
    end;
    perform public.erp_withdraw_bank_statement(v_s2, 'imported into the wrong account');
    v_cases := v_cases + 1;
    case_name := 'only the latest statement is withdrawn, and then its lines can be imported again';
    passed := v_state is null and v_ok
          and not exists (select 1 from erp.bank_statement s where s.id = v_s2)
          and (public.erp_import_bank_statement(v_bank, 'ofx', 'ofx', v_sha2, 127500, v_lines2) ->> 'lines')::integer = 1;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 7. The lists ────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the statements are listed newest first with their unmatched lines, and a statement''s lines in order';
    passed := v_state is null
          and (public.erp_bank_statements(v_bank) -> 0 ->> 'ends_on') = '2026-09-03'
          and (public.erp_bank_statements(v_bank) -> 1 ->> 'unmatched')::integer = 3
          and (select array_agg(r ->> 'description' order by (r ->> 'line_no')::integer)
                 from jsonb_array_elements(public.erp_bank_statement_lines(v_s1)) r) = array['ACME LTD INV-000412', 'HSBC CHARGES', 'HSBC CHARGES'];
    detail := coalesce(v_state, public.erp_bank_statements(v_bank)::text);
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
    raise exception 'CLOVEERP_BANK_STATEMENT_IMPORT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.bank_statement_import_suite() from public, anon, authenticated;

create or replace function erp_test.assert_bank_statement_import_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _bank_statement_import on commit drop as
    select * from erp_test.bank_statement_import_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _bank_statement_import;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_BANK_STATEMENT_IMPORT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_BANK_STATEMENT_IMPORT_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('bank statement import: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_bank_statement_import_suite() from public, anon, authenticated;

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
