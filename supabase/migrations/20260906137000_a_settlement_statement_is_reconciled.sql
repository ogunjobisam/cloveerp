-- =============================================================================
-- 20260906137000  A settlement statement is reconciled
-- -----------------------------------------------------------------------------
-- Specification v1.6 §5.7, accounts receivable. The register said
-- 5.7.accounts_receivable was partial: cash application, ageing and dunning
-- are built, "settlement reconciliation for prepaid channels is not: it
-- needs a payment-service statement to reconcile against, which is an
-- integration this product does not have". The statement is a file the
-- provider gives its customer; the product has an import pipeline that
-- stages, validates, previews, loads and rolls back — for master data and
-- opening balances only, each dispatched by name inside the four bodies.
--
-- What changes:
--
--   * erp_ref.import_object — a register of the import objects that are
--     neither master data nor opening balances, each naming the functions
--     that validate, load and roll it back. The four pipeline bodies are
--     needled to dispatch through it, so the next such object is a row, not
--     four more branches.
--   * erp.settlement_statement and erp.settlement_statement_line — what the
--     provider says it paid out: gross, fees and net on the statement; a
--     reference, an amount, a fee and a date per line. Fees are recorded,
--     not posted: the product has no rule for a provider's charge and will
--     not invent one; the figure is on the statement for the person who
--     books it.
--   * erp.reconcile_settlement_statement — each line to an open receivable:
--     by the invoice number the line references, else by an amount only one
--     open item of the currency has. A line two items could be is left
--     unmatched; erp.match_settlement_line() is a person's match, with a
--     note.
--   * erp.apply_settlement_statement — refuses while a line is unmatched,
--     then settles each matched item through erp.apply_cash_to_item(): the
--     same posting erp.apply_cash() makes (bank against the receivable,
--     subledger rows, the item's settled figure) against the one item the
--     line named. erp.apply_cash() allocates oldest first, which is the only
--     defensible order without an instruction; a statement line is an
--     instruction.
--   * Doors: erp_settlement_statements, erp_settlement_statement,
--     erp_reconcile_settlement_statement, erp_match_settlement_line,
--     erp_apply_settlement_statement. Staging, validating, previewing,
--     loading and rolling back go through the import doors that exist.
--
-- Proof: erp_test.settlement_suite() (12 cases, wrapper pinned): a bad row
-- rejected at validation; the good statement loaded with its totals and
-- reconciled by reference and by unique amount, an ambiguous amount left
-- unmatched; applying refused while unmatched; a manual match with a note,
-- and one without refused; applying settles the three items and leaves the
-- fourth open; applying twice refused; an applied statement cannot be rolled
-- back, an unapplied one can; a duplicate statement refused at validation;
-- the doors; the register flipped; nothing left.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register of import objects
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.import_object (
  object_type       text primary key check (object_type ~ '^[a-z][a-z0-9_]*$'),
  name_key          text not null,
  module_code       text not null,
  validate_function text not null check (validate_function ~ '^erp\.[a-z_]+$'),
  load_function     text not null check (load_function ~ '^erp\.[a-z_]+$'),
  rollback_function text not null check (rollback_function ~ '^erp\.[a-z_]+$'),
  description       text not null,
  seq               smallint not null default 100
);

select erp_meta.register_table('erp_ref', 'import_object', 'product_content',
  'The import objects that are neither master data nor opening balances, each naming the functions the import pipeline dispatches to. A new object is a row here, not a branch in four bodies.');

comment on table erp_ref.import_object is
  'Specification v1.6 §5.1 and §5.7. erp.validate_import(), erp.load_import() '
  'and erp.rollback_import() dispatch to the functions named here for the '
  'object types listed; erp.stage_import() accepts them. Product content: '
  'the function names are checked by constraint and executed by name.';

insert into erp_ref.import_object (object_type, name_key, module_code, validate_function, load_function, rollback_function, description, seq) values
  ('settlement_statement', 'import_object.settlement_statement.name', 'finance',
   'erp.validate_settlement_import', 'erp.load_settlement_import', 'erp.rollback_settlement_import',
   'A payment provider''s settlement statement: one statement per batch, one row per payout line with the invoice reference, amount, fee and date.', 10)
on conflict (object_type) do update
  set name_key = excluded.name_key, module_code = excluded.module_code,
      validate_function = excluded.validate_function, load_function = excluded.load_function,
      rollback_function = excluded.rollback_function, description = excluded.description, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('import_object.settlement_statement.name', 'en', 'Settlement statement', 'finance'),
  ('import_object.settlement_statement.name', 'de', 'Abrechnungsaufstellung', 'finance')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current) values
  ('settlement.applied', 1, 'posting', 'finance', 'event.settlement.applied',
   'A payment provider''s settlement statement was applied: every matched line settled the receivable it named.',
   '{"type":"object","required":["provider","statement_ref","lines","amount_minor","currency"],
     "properties":{"provider":{"type":"string"},"statement_ref":{"type":"string"},"lines":{"type":"integer"},
                   "amount_minor":{"type":"integer"},"fee_minor":{"type":"integer"},"currency":{"type":"string"}}}', true)
on conflict (code, version) do update
  set description = excluded.description, payload_schema = excluded.payload_schema, is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, module_code) values
  ('event.settlement.applied', 'en', 'Settlement statement applied', 'finance'),
  ('event.settlement.applied', 'de', 'Abrechnungsaufstellung verbucht', 'finance')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The statement
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp.settlement_statement (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant (id) on delete cascade,
  entity_id       uuid not null,
  provider_code   text not null check (provider_code ~ '^[A-Za-z0-9_.-]{1,40}$'),
  statement_ref   text not null check (length(btrim(statement_ref)) between 1 and 80),
  statement_date  date not null,
  currency        char(3) not null,
  gross_minor     bigint not null check (gross_minor >= 0),
  fee_minor       bigint not null default 0 check (fee_minor >= 0),
  net_minor       bigint not null,
  status          text not null default 'imported' check (status in ('imported', 'reconciled', 'applied')),
  import_batch_id uuid,
  applied_at      timestamptz,
  applied_by      uuid,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, provider_code, statement_ref),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, import_batch_id) references erp.import_batch (tenant_id, id) on delete set null,
  constraint settlement_statement_net check (net_minor = gross_minor - fee_minor)
);

select erp_meta.register_table('erp', 'settlement_statement', 'tenant_scoped',
  'v1.6 §5.7: a payment provider''s statement of what it paid out, imported through the pipeline, reconciled line by line to open receivables and applied as cash. Fees are recorded on it, not posted.');

create table if not exists erp.settlement_statement_line (
  id                       uuid not null default gen_random_uuid(),
  tenant_id                uuid not null references erp.tenant (id) on delete cascade,
  statement_id             uuid not null,
  line_no                  integer not null check (line_no > 0),
  reference                text not null check (length(btrim(reference)) >= 1),
  party_code               text,
  amount_minor             bigint not null check (amount_minor > 0),
  fee_minor                bigint not null default 0 check (fee_minor >= 0),
  occurred_on              date not null,
  matched_subledger_item_id uuid,
  match_method             text check (match_method in ('reference', 'amount', 'manual')),
  match_note               text,
  status                   text not null default 'unmatched' check (status in ('unmatched', 'matched', 'applied')),
  applied_journal_id       uuid,
  created_at               timestamptz not null default now(),
  created_by               uuid,
  updated_at               timestamptz not null default now(),
  updated_by               uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, statement_id, line_no),
  foreign key (tenant_id, statement_id) references erp.settlement_statement (tenant_id, id) on delete cascade,
  foreign key (matched_subledger_item_id) references erp.subledger_item (id) on delete set null,
  foreign key (applied_journal_id) references erp.journal (id) on delete set null,
  constraint settlement_line_matched check (status = 'unmatched' or matched_subledger_item_id is not null),
  constraint settlement_line_method  check (matched_subledger_item_id is null or match_method is not null)
);

select erp_meta.register_table('erp', 'settlement_statement_line', 'tenant_scoped',
  'v1.6 §5.7: one payout line of a settlement statement, matched to the open receivable it settles by reference, by unique amount, or by a person with a note.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Cash against one item
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.apply_cash_to_item(p_subledger_item_id uuid, p_amount_minor bigint,
                                                  p_reference text, p_received_on date default current_date)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  si       erp.subledger_item%rowtype;
  v_owing  bigint;
  v_bank   uuid;
  v_rule   uuid;
  v_rule_version integer;
  v_event  uuid;
  v_journal uuid;
begin
  if p_received_on is null or p_received_on > current_date then
    raise exception 'CLOVEERP_CASH_DATE_INVALID: a receipt is dated the day it arrived, which is % and not after today',
      coalesce(p_received_on::text, 'null')
      using errcode = '22007', hint = 'Pass the date the money reached the bank.';
  end if;

  select * into si from erp.subledger_item x where x.tenant_id = v_tenant and x.id = p_subledger_item_id for update;
  if not found or si.control_kind <> 'receivable' then
    raise exception 'CLOVEERP_NOT_A_RECEIVABLE: % is not an open receivable item', p_subledger_item_id
      using errcode = '23503', hint = 'Cash settles a receivable subledger item; erp_receivables_ageing() lists them.';
  end if;

  perform erp.authorise('finance.post', si.entity_id, null, null, 'party', si.party_id);

  v_owing := si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0);
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'CLOVEERP_CASH_AMOUNT_INVALID: a receipt is a positive amount, not %', p_amount_minor
      using errcode = '22023', hint = 'Pass the amount received in minor units.';
  end if;
  if p_amount_minor > v_owing then
    raise exception 'CLOVEERP_CASH_EXCEEDS_OWING: % is owed on this item and % was received', v_owing, p_amount_minor
      using errcode = '23514',
            hint = 'Apply what the item owes here and the rest as unallocated cash through erp_apply_cash().';
  end if;

  select a.id into v_bank from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = si.entity_id
     and a.control_kind = 'bank' and a.status = 'active'
   order by a.code limit 1;
  if v_bank is null then
    raise exception 'CLOVEERP_NO_BANK_ACCOUNT: cash has nowhere to land'
      using errcode = '23503', hint = 'The finance installer creates the bank account; run it for this company.';
  end if;

  select pr.id, pr.version into v_rule, v_rule_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'cash_application' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_CASH_POSTING_RULE: cash application has no promoted rule'
      using errcode = '23503', hint = 'erp.configure_receivables() installs it.';
  end if;

  v_event := erp.append_event(
    'document.posted', 'document', coalesce(si.document_id, si.party_id),
    jsonb_build_object('document_number', coalesce(p_reference, 'cash receipt'),
                       'posting_rule', 'cash_application',
                       'value_minor', p_amount_minor, 'currency', si.currency),
    si.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id, posting_date, description, status)
  values (v_tenant, si.entity_id, si.ledger_id, 'cash.applied', v_event, p_received_on,
          format('Cash received %s', coalesce(p_reference, '')), 'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, v_bank, p_amount_minor, 0, si.currency, p_amount_minor, 0, 1,
          v_rule, v_rule_version, v_event, 'cash received'),
         (v_tenant, v_journal, 2, si.control_account_id, 0, p_amount_minor, si.currency, 0, p_amount_minor, 1,
          v_rule, v_rule_version, v_event, 'applied to receivable');

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
  values (v_tenant, si.entity_id, si.ledger_id, 'receivable', si.control_account_id,
          si.party_id, si.document_id, v_journal, si.currency, 0, p_amount_minor, p_received_on),
         (v_tenant, si.entity_id, si.ledger_id, 'bank', v_bank,
          null, null, v_journal, si.currency, p_amount_minor, 0, p_received_on);

  update erp.subledger_item
     set settled_minor = coalesce(settled_minor, 0) + p_amount_minor, updated_at = now()
   where id = si.id;

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  return v_journal;
end;
$$;
revoke all on function erp.apply_cash_to_item(uuid, bigint, text, date) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Reconciling and applying
-- ═════════════════════════════════════════════════════════════════════════════

-- The open receivable items a line could settle, in the statement's currency.
create or replace function erp.open_receivables(p_currency char(3))
returns table(subledger_item_id uuid, party_id uuid, party_code text, document_id uuid,
              document_number text, owing_minor bigint, due_date date, posting_date date)
language sql
stable
set search_path = ''
as $$
  select si.id, si.party_id, p.code, si.document_id, d.document_number,
         (si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0))::bigint,
         si.due_date, si.posting_date
    from erp.subledger_item si
    left join erp.party p on p.id = si.party_id
    left join erp.document d on d.id = si.document_id
   where si.tenant_id = erp.current_tenant_id()
     and si.control_kind = 'receivable' and si.currency = p_currency
     and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
$$;
revoke all on function erp.open_receivables(char) from public, anon, authenticated;

create or replace function erp.reconcile_settlement_statement(p_statement_id uuid)
returns table(matched integer, unmatched integer)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  st       erp.settlement_statement%rowtype;
  ln       record;
  v_item   uuid;
  v_n      integer;
  v_matched integer := 0;
  v_unmatched integer := 0;
begin
  select * into st from erp.settlement_statement s where s.tenant_id = v_tenant and s.id = p_statement_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SETTLEMENT_STATEMENT: %', p_statement_id
      using errcode = '23503', hint = 'erp_settlement_statements() lists the statements imported.';
  end if;
  perform erp.authorise('finance.post', st.entity_id, null, null, 'settlement_statement', st.id);
  if st.status = 'applied' then
    raise exception 'CLOVEERP_SETTLEMENT_ALREADY_APPLIED: % from % has been applied', st.statement_ref, st.provider_code
      using errcode = '23514', hint = 'An applied statement is history; import the next one.';
  end if;

  for ln in
    select l.* from erp.settlement_statement_line l
     where l.tenant_id = v_tenant and l.statement_id = st.id and l.status = 'unmatched'
     order by l.line_no
  loop
    v_item := null;

    -- By the invoice the line names.
    select o.subledger_item_id into v_item
      from erp.open_receivables(st.currency) o
     where upper(btrim(o.document_number)) = upper(btrim(ln.reference))
       and (ln.party_code is null or o.party_code = ln.party_code)
       and not exists (select 1 from erp.settlement_statement_line x
                        where x.tenant_id = v_tenant and x.matched_subledger_item_id = o.subledger_item_id
                          and x.status in ('matched', 'applied'))
     order by o.posting_date limit 1;

    if v_item is not null then
      update erp.settlement_statement_line
         set matched_subledger_item_id = v_item, match_method = 'reference', status = 'matched', updated_at = now()
       where id = ln.id;
      v_matched := v_matched + 1;
      continue;
    end if;

    -- By an amount only one open item has. Two candidates is a person's call.
    select count(*), min(o.subledger_item_id::text)::uuid into v_n, v_item
      from erp.open_receivables(st.currency) o
     where o.owing_minor = ln.amount_minor
       and (ln.party_code is null or o.party_code = ln.party_code)
       and not exists (select 1 from erp.settlement_statement_line x
                        where x.tenant_id = v_tenant and x.matched_subledger_item_id = o.subledger_item_id
                          and x.status in ('matched', 'applied'));

    if v_n = 1 then
      update erp.settlement_statement_line
         set matched_subledger_item_id = v_item, match_method = 'amount', status = 'matched', updated_at = now()
       where id = ln.id;
      v_matched := v_matched + 1;
    else
      v_unmatched := v_unmatched + 1;
    end if;
  end loop;

  update erp.settlement_statement
     set status = case when exists (select 1 from erp.settlement_statement_line l
                                     where l.tenant_id = v_tenant and l.statement_id = st.id and l.status = 'unmatched')
                       then 'imported' else 'reconciled' end,
         updated_at = now()
   where id = st.id;

  matched := v_matched;
  unmatched := v_unmatched;
  return next;
end;
$$;
revoke all on function erp.reconcile_settlement_statement(uuid) from public, anon, authenticated;

create or replace function erp.match_settlement_line(p_line_id uuid, p_subledger_item_id uuid, p_note text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  ln       erp.settlement_statement_line%rowtype;
  st       erp.settlement_statement%rowtype;
  v_owing  bigint;
begin
  select * into ln from erp.settlement_statement_line l where l.tenant_id = v_tenant and l.id = p_line_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SETTLEMENT_LINE: %', p_line_id
      using errcode = '23503', hint = 'erp_settlement_statement(statement) lists the lines.';
  end if;
  select * into st from erp.settlement_statement s where s.id = ln.statement_id;
  perform erp.authorise('finance.post', st.entity_id, null, null, 'settlement_statement', st.id);

  if ln.status = 'applied' then
    raise exception 'CLOVEERP_SETTLEMENT_LINE_APPLIED: line % has been applied and cannot be re-matched', ln.line_no
      using errcode = '23514', hint = 'Correct an applied line with a journal, not a match.';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 10 then
    raise exception 'CLOVEERP_MATCH_NEEDS_A_NOTE: say why line % settles this item', ln.line_no
      using errcode = '22023', hint = 'A person''s match is read later by someone who was not there; ten characters at least.';
  end if;

  select o.owing_minor into v_owing from erp.open_receivables(st.currency) o
   where o.subledger_item_id = p_subledger_item_id;
  if v_owing is null then
    raise exception 'CLOVEERP_NOT_A_RECEIVABLE: % is not an open receivable in %', p_subledger_item_id, st.currency
      using errcode = '23503', hint = 'Pick an open item from erp_settlement_statement()''s candidates.';
  end if;
  if v_owing < ln.amount_minor then
    raise exception 'CLOVEERP_CASH_EXCEEDS_OWING: % is owed on this item and line % is for %', v_owing, ln.line_no, ln.amount_minor
      using errcode = '23514', hint = 'Match the line to the item it settles in full, or split the receipt through erp_apply_cash().';
  end if;
  if exists (select 1 from erp.settlement_statement_line x
              where x.tenant_id = v_tenant and x.matched_subledger_item_id = p_subledger_item_id
                and x.status in ('matched', 'applied') and x.id <> ln.id) then
    raise exception 'CLOVEERP_ITEM_ALREADY_MATCHED: another statement line already settles this item'
      using errcode = '23505', hint = 'One line settles one item; unmatch the other line first.';
  end if;

  update erp.settlement_statement_line
     set matched_subledger_item_id = p_subledger_item_id, match_method = 'manual',
         match_note = btrim(p_note), status = 'matched', updated_at = now()
   where id = ln.id;

  update erp.settlement_statement
     set status = case when exists (select 1 from erp.settlement_statement_line l
                                     where l.tenant_id = v_tenant and l.statement_id = st.id and l.status = 'unmatched')
                       then 'imported' else 'reconciled' end,
         updated_at = now()
   where id = st.id;
end;
$$;
revoke all on function erp.match_settlement_line(uuid, uuid, text) from public, anon, authenticated;

create or replace function erp.apply_settlement_statement(p_statement_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  st       erp.settlement_statement%rowtype;
  ln       record;
  v_n      integer := 0;
  v_open   integer;
  v_journal uuid;
begin
  select * into st from erp.settlement_statement s where s.tenant_id = v_tenant and s.id = p_statement_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SETTLEMENT_STATEMENT: %', p_statement_id
      using errcode = '23503', hint = 'erp_settlement_statements() lists the statements imported.';
  end if;
  perform erp.authorise('finance.post', st.entity_id, null, null, 'settlement_statement', st.id);

  if st.status = 'applied' then
    raise exception 'CLOVEERP_SETTLEMENT_ALREADY_APPLIED: % from % has been applied', st.statement_ref, st.provider_code
      using errcode = '23514', hint = 'An applied statement is history; import the next one.';
  end if;

  select count(*) into v_open from erp.settlement_statement_line l
   where l.tenant_id = v_tenant and l.statement_id = st.id and l.status = 'unmatched';
  if v_open > 0 then
    raise exception 'CLOVEERP_SETTLEMENT_UNMATCHED: % line(s) of % are not matched to a receivable', v_open, st.statement_ref
      using errcode = '23514',
            hint = 'erp_reconcile_settlement_statement() matches by reference and unique amount; erp_match_settlement_line() is a person''s match.';
  end if;

  for ln in
    select l.* from erp.settlement_statement_line l
     where l.tenant_id = v_tenant and l.statement_id = st.id and l.status = 'matched'
     order by l.line_no
  loop
    v_journal := erp.apply_cash_to_item(ln.matched_subledger_item_id, ln.amount_minor,
                                        format('%s %s line %s', st.provider_code, st.statement_ref, ln.line_no),
                                        least(ln.occurred_on, current_date));
    update erp.settlement_statement_line
       set status = 'applied', applied_journal_id = v_journal, updated_at = now()
     where id = ln.id;
    v_n := v_n + 1;
  end loop;

  perform erp.append_event(
    'settlement.applied', 'posting', st.id,
    jsonb_build_object('provider', st.provider_code, 'statement_ref', st.statement_ref,
                       'lines', v_n, 'amount_minor', st.gross_minor, 'fee_minor', st.fee_minor,
                       'currency', st.currency),
    st.entity_id, null);

  update erp.settlement_statement
     set status = 'applied', applied_at = now(), applied_by = erp.current_principal_id(), updated_at = now()
   where id = st.id;

  return v_n;
end;
$$;
revoke all on function erp.apply_settlement_statement(uuid) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The import pipeline learns the object
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.validate_settlement_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_first  jsonb;
  v_find   jsonb;
  v_errors integer := 0;
  v_dup    boolean;
begin
  select * into b from erp.import_batch where tenant_id = v_tenant and id = p_batch_id for update;
  perform erp.authorise('finance.post', null, null, null, 'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'CLOVEERP_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514', hint = 'Stage a new batch; a loaded or rolled-back one is not validated again.';
  end if;

  select r0.raw into v_first from erp.import_row r0
   where r0.tenant_id = v_tenant and r0.import_batch_id = p_batch_id order by r0.row_no limit 1;

  v_dup := exists (select 1 from erp.settlement_statement s
                    where s.tenant_id = v_tenant
                      and s.provider_code = btrim(v_first ->> 'provider')
                      and s.statement_ref = btrim(v_first ->> 'statement_ref'));

  for r in select * from erp.import_row where tenant_id = v_tenant and import_batch_id = p_batch_id order by row_no loop
    v_find := '[]'::jsonb;
    if coalesce(btrim(r.raw ->> 'provider'), '') = '' or coalesce(btrim(r.raw ->> 'statement_ref'), '') = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'provider and statement_ref name the statement, and one is missing');
    end if;
    if coalesce(btrim(r.raw ->> 'reference'), '') = '' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'reference is what the line settles, and it is missing');
    end if;
    if (r.raw ->> 'amount_minor') !~ '^[0-9]+$' or (r.raw ->> 'amount_minor')::numeric <= 0 then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'amount_minor must be a whole number of minor units above zero');
    end if;
    if r.raw ? 'fee_minor' and (r.raw ->> 'fee_minor') !~ '^[0-9]+$' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'fee_minor must be a whole number of minor units, or absent');
    end if;
    if (r.raw ->> 'currency') !~ '^[A-Za-z]{3}$' then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'currency is a three-letter code');
    end if;
    begin
      perform (r.raw ->> 'statement_date')::date, (r.raw ->> 'occurred_on')::date;
      if (r.raw ->> 'statement_date') is null or (r.raw ->> 'occurred_on') is null then
        raise exception 'missing';
      end if;
    exception when others then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'statement_date and occurred_on are dates, YYYY-MM-DD');
    end;
    if r.raw ->> 'provider' is distinct from v_first ->> 'provider'
       or r.raw ->> 'statement_ref' is distinct from v_first ->> 'statement_ref'
       or upper(r.raw ->> 'currency') is distinct from upper(v_first ->> 'currency') then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', 'one statement per batch: this row names a different provider, statement or currency from the first');
    end if;
    if v_dup then
      v_find := v_find || jsonb_build_object('severity', 'error', 'message', format('statement %s from %s has already been imported', v_first ->> 'statement_ref', v_first ->> 'provider'));
    end if;

    update erp.import_row
       set findings = v_find, target_id = null,
           action = case when jsonb_array_length(v_find) > 0 then 'reject' else 'insert' end,
           updated_at = now()
     where id = r.id;
    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch
     set status = 'validated', error_count = v_errors, currency = upper(v_first ->> 'currency'),
         as_at = case when (v_first ->> 'statement_date') ~ '^\d{4}-\d{2}-\d{2}$' then (v_first ->> 'statement_date')::date end,
         updated_at = now()
   where id = p_batch_id;
  return v_errors;
end;
$$;
revoke all on function erp.validate_settlement_import(uuid) from public, anon, authenticated;

create or replace function erp.load_settlement_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  r        record;
  v_first  jsonb;
  v_entity uuid;
  v_st     uuid;
  v_line   uuid;
  v_n      integer := 0;
  v_gross  bigint := 0;
  v_fee    bigint := 0;
  rec      record;
begin
  select * into b from erp.import_batch where tenant_id = v_tenant and id = p_batch_id for update;
  perform erp.authorise('finance.post', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'previewed' then
    raise exception 'CLOVEERP_IMPORT_NOT_PREVIEWED: % is %, and a staged load happens after somebody has looked at it', b.code, b.status
      using errcode = '23514', hint = 'Validate, preview, then load.';
  end if;
  if b.error_count > 0 then
    raise exception 'CLOVEERP_IMPORT_HAS_ERRORS: % rows in % are rejected; fix the file rather than loading the good half', b.error_count, b.code
      using errcode = '23514', hint = 'The findings on each row say what is wrong.';
  end if;

  select r0.raw into v_first from erp.import_row r0
   where r0.tenant_id = v_tenant and r0.import_batch_id = p_batch_id order by r0.row_no limit 1;

  -- The company that banks it: the first, as cash application does.
  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

  select coalesce(sum((r0.raw ->> 'amount_minor')::bigint), 0), coalesce(sum(coalesce((r0.raw ->> 'fee_minor')::bigint, 0)), 0)
    into v_gross, v_fee
    from erp.import_row r0 where r0.tenant_id = v_tenant and r0.import_batch_id = p_batch_id and r0.action = 'insert';

  insert into erp.settlement_statement (
    tenant_id, entity_id, provider_code, statement_ref, statement_date, currency,
    gross_minor, fee_minor, net_minor, status, import_batch_id)
  values (v_tenant, v_entity, btrim(v_first ->> 'provider'), btrim(v_first ->> 'statement_ref'),
          (v_first ->> 'statement_date')::date, upper(v_first ->> 'currency'),
          v_gross, v_fee, v_gross - v_fee, 'imported', p_batch_id)
  returning id into v_st;

  for r in select * from erp.import_row where tenant_id = v_tenant and import_batch_id = p_batch_id and action = 'insert' order by row_no loop
    v_n := v_n + 1;
    insert into erp.settlement_statement_line (
      tenant_id, statement_id, line_no, reference, party_code, amount_minor, fee_minor, occurred_on)
    values (v_tenant, v_st, v_n, btrim(r.raw ->> 'reference'), nullif(btrim(r.raw ->> 'party_code'), ''),
            (r.raw ->> 'amount_minor')::bigint, coalesce((r.raw ->> 'fee_minor')::bigint, 0),
            (r.raw ->> 'occurred_on')::date)
    returning id into v_line;
    update erp.import_row set target_id = v_line, loaded = true, before_snapshot = null,
           loaded_ref = jsonb_build_object('statement_id', v_st, 'line_id', v_line), updated_at = now()
     where id = r.id;
  end loop;

  select * into rec from erp.reconcile_settlement_statement(v_st);

  update erp.import_batch
     set status = 'loaded', loaded_at = now(), loaded_by = erp.current_principal_id(),
         loaded_total_minor = v_gross, updated_at = now()
   where id = p_batch_id;
  return v_n;
end;
$$;
revoke all on function erp.load_settlement_import(uuid) from public, anon, authenticated;

create or replace function erp.rollback_settlement_import(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  st       erp.settlement_statement%rowtype;
  v_n      integer;
begin
  select * into b from erp.import_batch where tenant_id = v_tenant and id = p_batch_id for update;
  perform erp.authorise('finance.post', null, null, null, 'import_batch', p_batch_id);

  if b.status <> 'loaded' then
    raise exception 'CLOVEERP_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514', hint = 'Only a loaded batch is rolled back.';
  end if;

  select * into st from erp.settlement_statement s where s.tenant_id = v_tenant and s.import_batch_id = p_batch_id;
  if st.id is not null and st.status = 'applied' then
    raise exception 'CLOVEERP_SETTLEMENT_APPLIED_CANNOT_ROLL_BACK: % from % has been applied and its cash journals stand', st.statement_ref, st.provider_code
      using errcode = '23514',
            hint = 'Correct an applied statement with a journal against the receivable; the statement itself is history.';
  end if;

  select count(*) into v_n from erp.settlement_statement_line l where l.tenant_id = v_tenant and l.statement_id = st.id;
  delete from erp.settlement_statement s where s.tenant_id = v_tenant and s.id = st.id;
  update erp.import_row set loaded = false, target_id = null, updated_at = now()
   where tenant_id = v_tenant and import_batch_id = p_batch_id;
  update erp.import_batch set status = 'rolled_back', rolled_back_at = now(), updated_at = now()
   where id = p_batch_id;
  return coalesce(v_n, 0);
end;
$$;
revoke all on function erp.rollback_settlement_import(uuid) from public, anon, authenticated;

-- The four bodies, needled to dispatch through the register.
do $$
declare
  v_src    text;
  v_needle text;
begin
  -- stage: accept a registered object.
  v_src := pg_get_functiondef('erp.stage_import(text,jsonb,text,text)'::regprocedure);
  v_needle := E'  if not exists (select 1 from erp_ref.maintainable_field m\n                  where m.object_type = p_object_type) then';
  if position(v_needle in v_src) = 0 or position('import_object' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.stage_import is not the deployed body';
  end if;
  execute replace(v_src, v_needle,
    E'  if not exists (select 1 from erp_ref.maintainable_field m\n                  where m.object_type = p_object_type)\n'
    || E'     and not exists (select 1 from erp_ref.import_object io where io.object_type = p_object_type) then');

  -- validate.
  v_src := pg_get_functiondef('erp.validate_import(uuid)'::regprocedure);
  v_needle := E'  -- Part 20: opening balances validate against the register''s row shape and';
  if position(v_needle in v_src) = 0 or position('import_object' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.validate_import is not the deployed body';
  end if;
  execute replace(v_src, v_needle,
    E'  -- A registered import object validates through its own function.\n'
    || E'  if exists (select 1 from erp_ref.import_object io where io.object_type = b.object_type) then\n'
    || E'    execute format(''select %s($1)'', (select io.validate_function from erp_ref.import_object io where io.object_type = b.object_type))\n'
    || E'      into v_errors using p_batch_id;\n'
    || E'    return v_errors;\n'
    || E'  end if;\n\n' || v_needle);

  -- load.
  v_src := pg_get_functiondef('erp.load_import(uuid)'::regprocedure);
  v_needle := E'  -- Part 20: opening balances load through their domain''s loader.';
  if position(v_needle in v_src) = 0 or position('import_object' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.load_import is not the deployed body';
  end if;
  execute replace(v_src, v_needle,
    E'  -- A registered import object loads through its own function.\n'
    || E'  if exists (select 1 from erp_ref.import_object io where io.object_type = b.object_type) then\n'
    || E'    execute format(''select %s($1)'', (select io.load_function from erp_ref.import_object io where io.object_type = b.object_type))\n'
    || E'      into v_loaded using p_batch_id;\n'
    || E'    return v_loaded;\n'
    || E'  end if;\n\n' || v_needle);

  -- rollback.
  v_src := pg_get_functiondef('erp.rollback_import(uuid)'::regprocedure);
  v_needle := E'  -- Part 20: opening balances are reversed, not deleted, and the reversal';
  if position(v_needle in v_src) = 0 or position('import_object' in v_src) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.rollback_import is not the deployed body';
  end if;
  execute replace(v_src, v_needle,
    E'  -- A registered import object rolls back through its own function.\n'
    || E'  if exists (select 1 from erp_ref.import_object io where io.object_type = b.object_type) then\n'
    || E'    execute format(''select %s($1)'', (select io.rollback_function from erp_ref.import_object io where io.object_type = b.object_type))\n'
    || E'      into v_n using p_batch_id;\n'
    || E'    return v_n;\n'
    || E'  end if;\n\n' || v_needle);
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_settlement_statements(p_limit integer default 50)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'statement_id', s.id, 'provider', s.provider_code, 'statement_ref', s.statement_ref,
           'statement_date', s.statement_date, 'currency', s.currency,
           'gross_minor', s.gross_minor, 'fee_minor', s.fee_minor, 'net_minor', s.net_minor,
           'status', s.status, 'applied_at', s.applied_at,
           'lines', (select count(*) from erp.settlement_statement_line l where l.statement_id = s.id),
           'unmatched', (select count(*) from erp.settlement_statement_line l where l.statement_id = s.id and l.status = 'unmatched'))
         order by s.statement_date desc, s.created_at desc), '[]'::jsonb)
    from (select * from erp.settlement_statement x
           where x.tenant_id = erp.current_tenant_id()
           order by x.statement_date desc, x.created_at desc limit greatest(p_limit, 1)) s
$$;

create or replace function public.erp_settlement_statement(p_statement_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
           'statement_id', s.id, 'provider', s.provider_code, 'statement_ref', s.statement_ref,
           'statement_date', s.statement_date, 'currency', s.currency,
           'gross_minor', s.gross_minor, 'fee_minor', s.fee_minor, 'net_minor', s.net_minor,
           'status', s.status, 'applied_at', s.applied_at,
           'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                       'line_id', l.id, 'line_no', l.line_no, 'reference', l.reference, 'party_code', l.party_code,
                       'amount_minor', l.amount_minor, 'fee_minor', l.fee_minor, 'occurred_on', l.occurred_on,
                       'status', l.status, 'match_method', l.match_method, 'match_note', l.match_note,
                       'matched_subledger_item_id', l.matched_subledger_item_id,
                       'matched_document_number', (select d.document_number from erp.subledger_item si
                                                     join erp.document d on d.id = si.document_id
                                                    where si.id = l.matched_subledger_item_id),
                       'applied_journal_id', l.applied_journal_id,
                       -- What a person could match an unmatched line to.
                       'candidates', case when l.status = 'unmatched' then
                         (select coalesce(jsonb_agg(jsonb_build_object(
                                   'subledger_item_id', o.subledger_item_id, 'document_number', o.document_number,
                                   'party_code', o.party_code, 'owing_minor', o.owing_minor, 'due_date', o.due_date)
                                 order by o.owing_minor, o.posting_date), '[]'::jsonb)
                            from (select * from erp.open_receivables(s.currency) oo
                                   where oo.owing_minor >= l.amount_minor
                                     and (l.party_code is null or oo.party_code = l.party_code)
                                     and not exists (select 1 from erp.settlement_statement_line x
                                                      where x.tenant_id = s.tenant_id
                                                        and x.matched_subledger_item_id = oo.subledger_item_id
                                                        and x.status in ('matched', 'applied'))
                                   order by oo.owing_minor, oo.posting_date limit 20) o)
                         else '[]'::jsonb end)
                     order by l.line_no), '[]'::jsonb)
                       from erp.settlement_statement_line l where l.statement_id = s.id))
    from erp.settlement_statement s
   where s.tenant_id = erp.current_tenant_id() and s.id = p_statement_id
$$;

create or replace function public.erp_reconcile_settlement_statement(p_statement_id uuid)
returns jsonb
language sql
set search_path = ''
as $$
  select to_jsonb(r) from erp.reconcile_settlement_statement(p_statement_id) r
$$;

create or replace function public.erp_match_settlement_line(p_line_id uuid, p_subledger_item_id uuid, p_note text)
returns void
language sql
set search_path = ''
as $$
  select erp.match_settlement_line(p_line_id, p_subledger_item_id, p_note)
$$;

create or replace function public.erp_apply_settlement_statement(p_statement_id uuid)
returns integer
language sql
set search_path = ''
as $$
  select erp.apply_settlement_statement(p_statement_id)
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_settlement_statements(integer)',
    'erp_settlement_statement(uuid)',
    'erp_reconcile_settlement_statement(uuid)',
    'erp_match_settlement_line(uuid, uuid, text)',
    'erp_apply_settlement_statement(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_reconcile_settlement_statement', 'erp.reconcile_settlement_statement',
   'Matches a settlement statement''s lines to open receivables by reference and unique amount; authorises finance.post.'),
  ('erp_match_settlement_line', 'erp.match_settlement_line',
   'A person''s match of one statement line to one open receivable, with a note; authorises finance.post.'),
  ('erp_apply_settlement_statement', 'erp.apply_settlement_statement',
   'Settles every matched line''s receivable as cash through the cash application rule; authorises finance.post.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The register
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.part5_capability
   set status = 'built',
       gap = null,
       artefacts = array['erp.receivables_ageing(date)',
                         'erp.dunning_policy',
                         'erp.dunning_worklist(text)',
                         'erp.apply_cash(uuid,bigint,character,text)',
                         'erp.apply_cash_to_item(uuid,bigint,text,date)',
                         'erp_ref.import_object',
                         'erp.settlement_statement',
                         'erp.settlement_statement_line',
                         'erp.reconcile_settlement_statement(uuid)',
                         'erp.match_settlement_line(uuid,uuid,text)',
                         'erp.apply_settlement_statement(uuid)',
                         'erp.validate_settlement_import(uuid)',
                         'erp.load_settlement_import(uuid)',
                         'erp.rollback_settlement_import(uuid)']
 where code = '5.7.accounts_receivable';

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.settlement_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth uuid := gen_random_uuid();
  v_entity uuid; v_site uuid; v_gl uuid; v_recv uuid;
  v_cust uuid; v_cust2 uuid; v_cust2_code text;
  v_inv_a uuid; v_inv_b uuid; v_inv_c uuid; v_inv_d uuid;
  v_num_a text; v_num_b text; v_num_c text; v_num_d text;
  v_it_a uuid; v_it_b uuid; v_it_c uuid; v_it_d uuid;
  v_bad uuid; v_batch uuid; v_batch2 uuid; v_st uuid; v_st2 uuid; v_line uuid;
  v_x jsonb; rec record; v_ok boolean; v_msg text; v_n integer;
begin
  begin
    select x.tenant_id, x.admin_user_id, x.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzset', 'Settlement Suite', 'admin@zzset.test', 'Settlement Admin') x;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzset.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
    select l.id into v_gl from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_entity and l.is_primary;
    select a.id into v_recv from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_entity
      and a.code = erp.chart_account_code('trade_receivable');
    select pr.party_id into v_cust from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id limit 1;
    select pr.party_id into v_cust2 from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id offset 1 limit 1;
    select p.code into v_cust2_code from erp.party p where p.id = v_cust2;

    -- Four invoices open in the sales ledger: A 600, B 400, C 400 (the same
    -- as B), D 250 for the second customer.
    v_inv_a := erp.open_document('sales_invoice', v_cust, v_entity, v_site);
    v_inv_b := erp.open_document('sales_invoice', v_cust, v_entity, v_site);
    v_inv_c := erp.open_document('sales_invoice', v_cust, v_entity, v_site);
    v_inv_d := erp.open_document('sales_invoice', v_cust2, v_entity, v_site);
    select d.document_number into v_num_a from erp.document d where d.id = v_inv_a;
    select d.document_number into v_num_b from erp.document d where d.id = v_inv_b;
    select d.document_number into v_num_c from erp.document d where d.id = v_inv_c;
    select d.document_number into v_num_d from erp.document d where d.id = v_inv_d;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id, party_id, document_id, currency, debit_minor, credit_minor, posting_date, due_date)
    values (v_tenant, v_entity, v_gl, 'receivable', v_recv, v_cust,  v_inv_a, 'GBP', 600, 0, current_date - 30, current_date - 2)
    returning id into v_it_a;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id, party_id, document_id, currency, debit_minor, credit_minor, posting_date, due_date)
    values (v_tenant, v_entity, v_gl, 'receivable', v_recv, v_cust,  v_inv_b, 'GBP', 400, 0, current_date - 20, current_date + 8)
    returning id into v_it_b;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id, party_id, document_id, currency, debit_minor, credit_minor, posting_date, due_date)
    values (v_tenant, v_entity, v_gl, 'receivable', v_recv, v_cust,  v_inv_c, 'GBP', 400, 0, current_date - 10, current_date + 18)
    returning id into v_it_c;
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id, party_id, document_id, currency, debit_minor, credit_minor, posting_date, due_date)
    values (v_tenant, v_entity, v_gl, 'receivable', v_recv, v_cust2, v_inv_d, 'GBP', 250, 0, current_date - 10, current_date + 18)
    returning id into v_it_d;

    -- 1. A bad row.
    v_bad := erp.stage_import('settlement_statement', jsonb_build_array(
      jsonb_build_object('provider', 'stripe', 'statement_ref', 'ST-0', 'statement_date', current_date, 'currency', 'GBP',
                         'reference', v_num_a, 'amount_minor', 'six hundred', 'occurred_on', current_date - 1)), 'SET-BAD');
    v_n := erp.validate_import(v_bad);
    return query select 'a settlement row with a bad amount is rejected at validation, through the import pipeline',
      v_n = 1 and (select b.status::text from erp.import_batch b where b.id = v_bad) = 'validated'
      and (select r.findings -> 0 ->> 'message' from erp.import_row r where r.import_batch_id = v_bad) like 'amount_minor must be%',
      format('%s error(s); the row says why', v_n);

    -- 2. The statement: A by reference, D by unique amount, a 400 nobody can place.
    v_batch := erp.stage_import('settlement_statement', jsonb_build_array(
      jsonb_build_object('provider', 'stripe', 'statement_ref', 'ST-1', 'statement_date', current_date, 'currency', 'GBP',
                         'reference', v_num_a, 'amount_minor', 600, 'fee_minor', 12, 'occurred_on', current_date - 1),
      jsonb_build_object('provider', 'stripe', 'statement_ref', 'ST-1', 'statement_date', current_date, 'currency', 'GBP',
                         'reference', 'PAYOUT-77', 'amount_minor', 250, 'fee_minor', 5, 'occurred_on', current_date - 1),
      jsonb_build_object('provider', 'stripe', 'statement_ref', 'ST-1', 'statement_date', current_date, 'currency', 'GBP',
                         'reference', 'UNKNOWN-9', 'amount_minor', 400, 'fee_minor', 8, 'occurred_on', current_date - 1)), 'SET-1');
    v_n := erp.validate_import(v_batch);
    perform erp.preview_import(v_batch);
    v_n := erp.load_import(v_batch);
    select s.id into v_st from erp.settlement_statement s where s.tenant_id = v_tenant and s.statement_ref = 'ST-1';
    return query select 'the statement loads with its totals and reconciles by reference and by unique amount, leaving the ambiguous line',
      v_n = 3 and v_st is not null
      and (select s.gross_minor = 1250 and s.fee_minor = 25 and s.net_minor = 1225 and s.status = 'imported'
             from erp.settlement_statement s where s.id = v_st)
      and (select l.match_method from erp.settlement_statement_line l where l.statement_id = v_st and l.line_no = 1) = 'reference'
      and (select l.matched_subledger_item_id from erp.settlement_statement_line l where l.statement_id = v_st and l.line_no = 1) = v_it_a
      and (select l.match_method from erp.settlement_statement_line l where l.statement_id = v_st and l.line_no = 2) = 'amount'
      and (select l.matched_subledger_item_id from erp.settlement_statement_line l where l.statement_id = v_st and l.line_no = 2) = v_it_d
      and (select l.status from erp.settlement_statement_line l where l.statement_id = v_st and l.line_no = 3) = 'unmatched'
      and (select b.status::text from erp.import_batch b where b.id = v_batch) = 'loaded',
      'gross 1250, fees 25, net 1225; line 1 by reference, line 2 by amount, line 3 open';

    -- 3. Not while a line is open.
    begin
      perform erp.apply_settlement_statement(v_st);
      v_ok := false; v_msg := 'applied with an unmatched line';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SETTLEMENT_UNMATCHED: 1 line(s)%'; v_msg := left(sqlerrm, 100);
    end;
    return query select 'applying is refused while a line is unmatched', v_ok, v_msg;

    -- 4. A person's match, with a note.
    select l.id into v_line from erp.settlement_statement_line l where l.statement_id = v_st and l.line_no = 3;
    v_x := public.erp_settlement_statement(v_st);
    begin
      perform erp.match_settlement_line(v_line, v_it_b, 'ok');
      v_ok := false; v_msg := 'matched without a note';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_MATCH_NEEDS_A_NOTE:%'; v_msg := left(sqlerrm, 80);
    end;
    perform erp.match_settlement_line(v_line, v_it_b, 'the customer''s remittance names the earlier invoice');
    return query select 'a person matches the ambiguous line with a note, and cannot without one',
      v_ok
      and (select l.match_method = 'manual' and l.status = 'matched' and l.matched_subledger_item_id = v_it_b
             from erp.settlement_statement_line l where l.id = v_line)
      and (select s.status from erp.settlement_statement s where s.id = v_st) = 'reconciled'
      and jsonb_array_length(v_x -> 'lines' -> 2 -> 'candidates') = 2,
      format('%s; the door offered two candidates', v_msg);

    -- 5. Applied.
    v_n := erp.apply_settlement_statement(v_st);
    return query select 'applying settles the three items it named and leaves the fourth open',
      v_n = 3
      and (select coalesce(si.settled_minor, 0) from erp.subledger_item si where si.id = v_it_a) = 600
      and (select coalesce(si.settled_minor, 0) from erp.subledger_item si where si.id = v_it_b) = 400
      and (select coalesce(si.settled_minor, 0) from erp.subledger_item si where si.id = v_it_d) = 250
      and (select coalesce(si.settled_minor, 0) from erp.subledger_item si where si.id = v_it_c) = 0
      and (select count(*) from erp.journal j join erp.settlement_statement_line l on l.applied_journal_id = j.id
            where l.statement_id = v_st and j.status = 'posted' and j.source_code = 'cash.applied') = 3
      and (select s.status = 'applied' and s.applied_at is not null from erp.settlement_statement s where s.id = v_st)
      and exists (select 1 from erp.event ev where ev.tenant_id = v_tenant and ev.event_type = 'settlement.applied'
                   and (ev.payload ->> 'lines')::integer = 3),
      'A 600, B 400, D 250 settled through three cash journals; C still owes 400';

    -- 6. Not twice.
    begin
      perform erp.apply_settlement_statement(v_st);
      v_ok := false; v_msg := 'applied twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SETTLEMENT_ALREADY_APPLIED:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'an applied statement cannot be applied again', v_ok, v_msg;

    -- 7. Rollback: not an applied one; an unapplied one, yes.
    begin
      perform erp.rollback_import(v_batch);
      v_ok := false; v_msg := 'an applied statement was rolled back';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SETTLEMENT_APPLIED_CANNOT_ROLL_BACK:%'; v_msg := left(sqlerrm, 90);
    end;
    v_batch2 := erp.stage_import('settlement_statement', jsonb_build_array(
      jsonb_build_object('provider', 'stripe', 'statement_ref', 'ST-2', 'statement_date', current_date, 'currency', 'GBP',
                         'reference', 'NOTHING-1', 'amount_minor', 999, 'occurred_on', current_date)), 'SET-2');
    perform erp.validate_import(v_batch2);
    perform erp.preview_import(v_batch2);
    perform erp.load_import(v_batch2);
    select s.id into v_st2 from erp.settlement_statement s where s.tenant_id = v_tenant and s.statement_ref = 'ST-2';
    v_n := erp.rollback_import(v_batch2);
    return query select 'an applied statement cannot be rolled back; an unapplied one is removed with its batch marked',
      v_ok and v_st2 is not null and v_n = 1
      and not exists (select 1 from erp.settlement_statement s where s.id = v_st2)
      and (select b.status::text from erp.import_batch b where b.id = v_batch2) = 'rolled_back',
      v_msg;

    -- 8. The same statement again.
    v_batch2 := erp.stage_import('settlement_statement', jsonb_build_array(
      jsonb_build_object('provider', 'stripe', 'statement_ref', 'ST-1', 'statement_date', current_date, 'currency', 'GBP',
                         'reference', v_num_c, 'amount_minor', 400, 'occurred_on', current_date)), 'SET-1-AGAIN');
    v_n := erp.validate_import(v_batch2);
    return query select 'a statement already imported is refused at validation',
      v_n = 1 and (select r.findings @> '[{"severity": "error"}]'::jsonb and r.findings::text like '%already been imported%'
                     from erp.import_row r where r.import_batch_id = v_batch2),
      'ST-1 from stripe, again: rejected';

    -- 9. The doors.
    v_x := public.erp_settlement_statements(10);
    return query select 'the listing and the statement door read what happened',
      jsonb_array_length(v_x) = 1
      and v_x -> 0 ->> 'status' = 'applied' and (v_x -> 0 ->> 'unmatched')::integer = 0
      and (public.erp_settlement_statement(v_st) -> 'lines' -> 0 ->> 'matched_document_number') = v_num_a
      and (public.erp_settlement_statement(v_st) -> 'lines' -> 2 ->> 'match_note') like 'the customer%',
      'one statement, applied, nothing unmatched; line 1 names the invoice, line 3 carries the note';

    -- 10. A wrong item for a person's match.
    begin
      perform erp.match_settlement_line(v_line, v_it_c, 'trying to move an applied line');
      v_ok := false; v_msg := 'an applied line was re-matched';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SETTLEMENT_LINE_APPLIED:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'an applied line cannot be re-matched', v_ok, v_msg;

    -- 11. The register.
    return query select 'the register says accounts receivable is built, and the artefacts exist',
      (select c.status from erp_ref.part5_capability c where c.code = '5.7.accounts_receivable') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.7.accounts_receivable')
      and exists (select 1 from erp_ref.resource r where r.key = 'import_object.settlement_statement.name' and r.locale = 'de'),
      '5.7.accounts_receivable';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzset');
  detail := 'the organisation, its statements and its cash rolled back';
  return next;
end;
$$;

create or replace function erp_test.assert_settlement_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _settlement_suite on commit drop as
    select * from erp_test.settlement_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _settlement_suite;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_SETTLEMENT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_SETTLEMENT_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('settlement: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_settlement_suite() from public, anon, authenticated;
revoke all on function erp_test.settlement_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_settlement_suite();
select erp_test.assert_finance_depth_suite();
select erp_test.assert_master_data_suite();
select erp_test.assert_migration_cutover_suite();
select erp.assert_part5_coverage();
select erp.assert_vocabulary_aligned();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
