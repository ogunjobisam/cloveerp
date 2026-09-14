-- Finance can journal and close.
--
-- A static walk through every persona (14 September) found three things a
-- company meets in its first month of finance that the product could not do,
-- or did dishonestly. Each finding was checked against the definitions the
-- database carries after every patch before this file was written, and each
-- was true:
--
--   1. Nobody can type a journal. erp.journal and erp.journal_line (0026) have
--      carried a draft status, a manual source that must give its reason, and a
--      reversal link since the ledger was built, and every reading of the
--      ledger (erp.statement_lines, the trial balance, the account balance
--      view) sums posted journals only. But no public door raises, submits,
--      approves or reverses a journal: the only writers are document posting,
--      opening balances and group eliminations. There is no journal document
--      type, no finance.approve_* code beyond finance.approve_payment, and no
--      journal screen; the user guide says so.
--
--   2. Closing a period is one click. erp.close_period (20260829300000) refuses
--      only close tasks that exist and are open, so a period with no checklist
--      closes at once. A period closed again after a reopening is not closed:
--      erp.check_period_open() lets a posting in while any reopening has no
--      reclosed_at, erp.period_reopening is append-only, and nothing sets
--      reclosed_at. Nothing sets permanently_closed, and erp.reopen_period
--      records a reopening of a permanently closed period that can never be
--      used.
--
--   3. A legal invoice cannot be issued from the desk. The numbered issue path
--      exists (erp.issue_sales_invoice under document.issue, the reprint under
--      document.reprint, and src/lib/document-output.functions.ts, which
--      reserves the number, renders, files and completes), but nothing in the
--      application imports that server function. document.issue and
--      document.reprint were given to every role holding sales.invoice on
--      11 September (20260911090027) and to the finance and sales module roles
--      (20260911113637), and never to the base pack's finance_clerk or
--      sales_administrator templates, so a role made from either since then
--      raises invoices it cannot issue.
--
-- What this file does, in order:
--
--   1. A journal carries its maker and its checker. erp.journal gains reference,
--      prepared_by (who last wrote its lines), submitted_at and submitted_by,
--      and returned_at, returned_by and return_note. A manual journal is an
--      erp.journal row from the first keystroke: a draft may be lopsided, which
--      is what the table's own balance trigger says a draft is, and nothing
--      reads a draft as the ledger.
--
--   2. The journal doors, each run as the caller:
--        public.erp_raise_journal     finance.post   a draft, or a draft changed
--        public.erp_submit_journal    finance.post   asks for approval
--        public.erp_approve_journal   finance.close_period   approves and posts
--        public.erp_return_journal    finance.close_period   sends back, with a note
--        public.erp_reverse_journal   finance.post   raises the reversing journal
--        public.erp_discard_journal   finance.post   removes a draft
--        public.erp_journals          finance.read   lists journals by state
--      Refused by name: an incomplete journal, a date no open period holds, an
--      account of another company, an account not in use, a control account
--      whose balance its own ledger keeps (receivables, payables, stock, bank,
--      tax, assets: 0026 says a control account is not posted to directly, and
--      the close's subledger check holds it to its detail), and a
--      journal whose debits and credits differ, at submission and again at
--      approval. Once the organisation is live nobody approves a journal they
--      raised or submitted (CLOVEERP_JOURNAL_SELF_APPROVAL); before go-live one
--      person may, as 20260914062000 lets a document's author.
--
--      Approving is finance.close_period. The finance manager template holds
--      it and the finance clerk template does not; the base pack's POST_CLOSE
--      rule prohibits one person holding it with finance.post, and 065000
--      enforces that once live, so the person who types a journal and the
--      person who posts it are two people by the organisation's own rules as
--      well as by the door. finance.approve_payment was the other candidate and
--      was not taken: the finance module role holds it with finance.post, and
--      approving a payment is not reviewing the ledger. An organisation on
--      module roles has its administrator approve, as it closes periods.
--
--      A posted journal is never changed. Reversing it raises a new journal, the
--      mirror of every line, naming what it reverses, submitted for approval
--      like any other. The original stays posted and untouched; every reading
--      sums posted journals, so the two net to nothing. A journal is reversed
--      once, a reversal is not reversed, and only journals raised here are
--      reversed here: opening balances are undone where they were loaded.
--
--   3. Closing is honest. erp.close_period refuses a period with no close tasks
--      (CLOVEERP_CLOSE_NO_TASKS) and names the tasks still open
--      (CLOVEERP_CLOSE_TASKS_OPEN), refuses a permanently closed period, and
--      stamps the moment it closed. erp.check_period_open() counts a reopening
--      only when it was made after the period last closed, by counted
--      replacement, so closing again closes. erp.reopen_period refuses a
--      permanently closed period.
--
--   4. Year end. public.erp_close_fiscal_year, under finance.close_period, is
--      given the last period of a fiscal year, refuses while any period of that
--      year still accepts postings, and marks every period of the year
--      permanently closed. Financials offers it on its Close step, beside
--      opening a period close, closing and reopening.
--
--   5. The base pack's finance_clerk and sales_administrator templates hold
--      document.issue and document.reprint, edited in place as 20260914061500
--      edited its templates. No segregation rule in any pack names either code.
--      No organisation's roles are rewritten: re-applying the base pack plans
--      the two roles as updates. A sales invoice's page issues it through the
--      numbered path and reprints what was filed, so
--      erp_sales_invoice_issue_readiness leaves the register of doors waiting
--      for a screen.
--
--   6. The words: eighteen refusals registered, the Journals screen's name and
--      help, and every string the Journals screen, the Close step and the
--      invoice's Issue panel show.
--
-- Proof: erp_test.journal_and_close_suite(), sixteen cases, pinned by its
-- wrapper.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A journal carries its maker and its checker
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.journal add column if not exists reference    text;
alter table erp.journal add column if not exists prepared_by  uuid;
alter table erp.journal add column if not exists submitted_at timestamptz;
alter table erp.journal add column if not exists submitted_by uuid;
alter table erp.journal add column if not exists returned_at  timestamptz;
alter table erp.journal add column if not exists returned_by  uuid;
alter table erp.journal add column if not exists return_note  text;

comment on column erp.journal.reference is
  'The journal''s own reference, typed by whoever raised it (an accrual code, a '
  'supplier''s letter). Not its number, which the ledger allocates on posting.';
comment on column erp.journal.prepared_by is
  'Who last wrote this manual journal''s lines. Set only by the journal doors, so '
  'a journal carrying it was raised on the Journals screen (20260914071000).';
comment on column erp.journal.submitted_at is
  'When the journal was submitted for approval. A draft with it set is waiting '
  'for approval; sending it back clears it.';
comment on column erp.journal.submitted_by is
  'Who submitted the journal for approval. Once live, neither they, nor whoever '
  'raised or last changed it, approves it.';
comment on column erp.journal.returned_at is 'When the journal was last sent back.';
comment on column erp.journal.returned_by is 'Who last sent the journal back.';
comment on column erp.journal.return_note is 'Why the journal was last sent back, for whoever raised it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What a journal may post into
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.period_accepts_postings(p_fiscal_period_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select case
           when fp.status = 'permanently_closed' then false
           when fp.status = 'closed' then exists (
             select 1
               from erp.period_reopening r
              where r.tenant_id = fp.tenant_id
                and r.fiscal_period_id = fp.id
                and r.reclosed_at is null
                and r.reopened_at > coalesce(fp.closed_at, '-infinity'::timestamptz))
           else true
         end
    from erp.fiscal_period fp
   where fp.tenant_id = erp.require_tenant_id()
     and fp.id = p_fiscal_period_id
$$;
revoke all on function erp.period_accepts_postings(uuid) from public, anon, authenticated;

comment on function erp.period_accepts_postings(uuid) is
  'Whether a period of this organisation takes postings: never when permanently '
  'closed; when closed, only while a reopening made after its latest close '
  'stands; otherwise yes. Null for a period that is not this organisation''s. '
  'The rule erp.check_period_open() applies (20260914071000).';

create or replace function erp.journal_amount_text(p_minor bigint, p_currency char(3))
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select format('%s %s', p_currency,
                round(coalesce(p_minor, 0)::numeric / (10::numeric ^ coalesce(c.minor_units, 2)),
                      coalesce(c.minor_units, 2)::integer)::text)
    from (select 1) one
    left join erp_ref.currency c on c.code = p_currency
$$;
revoke all on function erp.journal_amount_text(bigint, char) from public, anon, authenticated;

comment on function erp.journal_amount_text(bigint, char) is
  'An amount in minor units as a person reads it, in its currency''s own decimal '
  'places, for the words of a refusal.';

create or replace function erp.journal_period(p_ledger_id uuid, p_on date)
returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  p        erp.fiscal_period%rowtype;
begin
  select fp.* into p
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.ledger_id = p_ledger_id
     and p_on between fp.starts_on and fp.ends_on;

  if not found then
    raise exception 'CLOVEERP_JOURNAL_NO_PERIOD: no accounting period of the company''s general ledger holds %', p_on
      using errcode = '23514',
            hint = 'Date the journal inside the company''s fiscal calendar, which Periods on Financials lists.';
  end if;

  if p.status = 'permanently_closed' then
    raise exception 'CLOVEERP_JOURNAL_PERIOD_CLOSED: % was closed for good at the end of its year', p.code
      using errcode = '23514',
            hint = format('Nothing more is posted into %s. Date the journal in an open period: an adjustment to a closed year is posted in the current one.', p.code);
  end if;

  if not coalesce(erp.period_accepts_postings(p.id), false) then
    raise exception 'CLOVEERP_JOURNAL_PERIOD_CLOSED: % is closed', p.code
      using errcode = '23514',
            hint = format('Date the journal in an open period, or ask somebody who may reopen periods to reopen %s with the reason for posting into it.', p.code);
  end if;

  return p.id;
end;
$$;
revoke all on function erp.journal_period(uuid, date) from public, anon, authenticated;

comment on function erp.journal_period(uuid, date) is
  'The period of a ledger a journal dated p_on posts into, refusing a date no '
  'period holds (CLOVEERP_JOURNAL_NO_PERIOD) and a period that takes no postings '
  '(CLOVEERP_JOURNAL_PERIOD_CLOSED). Internal: callers authorise first.';

create or replace function erp.journal_require_account(p_entity_id uuid, p_account_id uuid, p_line_no integer)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  a        erp.account%rowtype;
begin
  select x.* into a
    from erp.account x
   where x.tenant_id = v_tenant
     and x.id = p_account_id;

  if not found or a.entity_id is distinct from p_entity_id then
    raise exception 'CLOVEERP_JOURNAL_ACCOUNT_UNKNOWN: line % names an account that is not in the chart of the journal''s company', p_line_no
      using errcode = '23503',
            hint = 'Choose the account from the chart of the company the journal is for. Each company keeps its own chart.';
  end if;

  if a.status <> 'active' then
    raise exception 'CLOVEERP_JOURNAL_ACCOUNT_INACTIVE: line % posts to %, which is not in use', p_line_no, a.code || ' ' || a.name
      using errcode = '23514',
            hint = format('Choose an account in use instead of %s, or ask whoever keeps the chart of accounts to bring it back into use.', a.code);
  end if;

  -- A control account is the total of the detail a subledger keeps, and
  -- erp.assert_subledger_reconciles(), a blocking close task, holds the two
  -- equal. A line typed straight onto one would part them (0026).
  if a.control_kind is not null then
    raise exception 'CLOVEERP_JOURNAL_CONTROL_ACCOUNT: line % posts to %, whose balance is the total of its own ledger', p_line_no, a.code || ' ' || a.name
      using errcode = '23514',
            hint = format('%s is kept by the %s, which holds the detail behind it. Record the invoice, bill, payment, cash, stock movement or asset there, and the account follows.',
                          a.code,
                          case a.control_kind
                            when 'receivable' then 'sales ledger'
                            when 'payable' then 'purchase ledger'
                            when 'bank' then 'cash book'
                            when 'tax' then 'tax ledger'
                            when 'fixed_asset' then 'asset register'
                            else 'stock ledger'
                          end);
  end if;
end;
$$;
revoke all on function erp.journal_require_account(uuid, uuid, integer) from public, anon, authenticated;

comment on function erp.journal_require_account(uuid, uuid, integer) is
  'Refuses a journal line''s account that is not in the company''s chart '
  '(CLOVEERP_JOURNAL_ACCOUNT_UNKNOWN), not in use (CLOVEERP_JOURNAL_ACCOUNT_INACTIVE), '
  'or a control account whose balance a subledger keeps (CLOVEERP_JOURNAL_CONTROL_ACCOUNT). '
  'Internal: callers authorise first.';

create or replace function erp.journal_require_sound(p_journal_id uuid)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  j        erp.journal%rowtype;
  l        record;
  v_lines  integer;
  v_dr     bigint;
  v_cr     bigint;
  v_ccy    char(3);
begin
  select x.* into j
    from erp.journal x
   where x.tenant_id = v_tenant
     and x.id = p_journal_id;

  perform erp.journal_period(j.ledger_id, j.posting_date);

  for l in
    select jl.line_no, jl.account_id
      from erp.journal_line jl
     where jl.tenant_id = v_tenant
       and jl.journal_id = p_journal_id
     order by jl.line_no
  loop
    perform erp.journal_require_account(j.entity_id, l.account_id, l.line_no);
  end loop;

  select count(*)::integer, coalesce(sum(jl.debit_minor), 0), coalesce(sum(jl.credit_minor), 0)
    into v_lines, v_dr, v_cr
    from erp.journal_line jl
   where jl.tenant_id = v_tenant
     and jl.journal_id = p_journal_id;

  select lg.currency into v_ccy
    from erp.ledger lg
   where lg.tenant_id = v_tenant
     and lg.id = j.ledger_id;

  if v_lines < 2 or v_dr <> v_cr then
    raise exception 'CLOVEERP_JOURNAL_NOT_BALANCED: %',
      case when v_lines < 2
           then format('a journal needs at least two lines, and this one has %s', v_lines)
           else format('debits come to %s and credits to %s',
                       erp.journal_amount_text(v_dr, v_ccy), erp.journal_amount_text(v_cr, v_ccy))
      end
      using errcode = '23514',
            hint = case when v_lines < 2
                        then 'Add the other side of the entry: every debit is matched by a credit.'
                        else format('The two sides differ by %s. Correct a line so that the debits equal the credits, then submit the journal again.',
                                    erp.journal_amount_text(abs(v_dr - v_cr), v_ccy))
                   end;
  end if;
end;
$$;
revoke all on function erp.journal_require_sound(uuid) from public, anon, authenticated;

comment on function erp.journal_require_sound(uuid) is
  'What a journal must be to be submitted and to be posted: dated in a period '
  'that takes postings, every line on an account of its company that is in use '
  'and kept by no subledger, at least two lines, and debits equal to credits '
  '(CLOVEERP_JOURNAL_NOT_BALANCED). Internal: callers authorise first.';

create or replace function erp.journal_state(p_journal_id uuid)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select case
           when j.status = 'reversed' then 'reversed'
           when j.status = 'posted'
                and exists (select 1 from erp.journal r
                             where r.tenant_id = j.tenant_id
                               and r.reverses_journal_id = j.id
                               and r.status = 'posted') then 'reversed'
           when j.status = 'posted' then 'posted'
           when j.submitted_at is not null then 'submitted'
           when j.returned_at is not null then 'returned'
           else 'draft'
         end
    from erp.journal j
   where j.tenant_id = erp.require_tenant_id()
     and j.id = p_journal_id
$$;
revoke all on function erp.journal_state(uuid) from public, anon, authenticated;

comment on function erp.journal_state(uuid) is
  'A journal''s state as the Journals screen lists it: draft, returned (a draft '
  'sent back), submitted (waiting for approval), posted, or reversed (posted, '
  'with a posted reversal).';

create or replace function erp.journal_state_words(p_state text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_state
           when 'draft' then 'a draft'
           when 'returned' then 'sent back'
           when 'submitted' then 'waiting for approval'
           when 'posted' then 'posted'
           when 'reversed' then 'reversed'
           else coalesce(p_state, 'not known')
         end
$$;
revoke all on function erp.journal_state_words(text) from public, anon, authenticated;

create or replace function erp.journal_outcome(p_journal_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
           'journal_id', j.id,
           'journal_number', j.journal_number,
           'reference', j.reference,
           'posting_date', j.posting_date,
           'state', erp.journal_state(j.id),
           'reverses_journal_id', j.reverses_journal_id,
           'lines', (select count(*) from erp.journal_line l
                      where l.tenant_id = j.tenant_id and l.journal_id = j.id),
           'debit_minor', (select coalesce(sum(l.debit_minor), 0) from erp.journal_line l
                            where l.tenant_id = j.tenant_id and l.journal_id = j.id),
           'credit_minor', (select coalesce(sum(l.credit_minor), 0) from erp.journal_line l
                             where l.tenant_id = j.tenant_id and l.journal_id = j.id))
    from erp.journal j
   where j.tenant_id = erp.require_tenant_id()
     and j.id = p_journal_id
$$;
revoke all on function erp.journal_outcome(uuid) from public, anon, authenticated;

create or replace function erp.submit_journal(p_journal_id uuid)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  j        erp.journal%rowtype;
begin
  select x.* into j
    from erp.journal x
   where x.tenant_id = v_tenant
     and x.id = p_journal_id
     for update;

  if j.status <> 'draft' or j.submitted_at is not null then
    raise exception 'CLOVEERP_JOURNAL_WRONG_STATE: this journal is %, and only a draft or a journal sent back is submitted',
      erp.journal_state_words(erp.journal_state(p_journal_id))
      using errcode = '23514',
            hint = 'Refresh the list of journals: somebody may already have submitted, approved or reversed it.';
  end if;

  perform erp.journal_require_sound(p_journal_id);

  update erp.journal x
     set submitted_at = clock_timestamp(),
         submitted_by = erp.current_principal_id(),
         updated_at = now()
   where x.tenant_id = v_tenant
     and x.id = p_journal_id;
end;
$$;
revoke all on function erp.submit_journal(uuid) from public, anon, authenticated;

comment on function erp.submit_journal(uuid) is
  'Submits a draft or sent-back journal for approval once it is sound '
  '(erp.journal_require_sound). Internal: callers authorise finance.post first.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The journal doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_raise_journal(
  p_entity_id    uuid,
  p_posting_date date,
  p_narrative    text,
  p_lines        jsonb,
  p_reference    text    default null,
  p_journal_id   uuid    default null,
  p_submit       boolean default false
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant    uuid;
  v_me        uuid;
  v_narrative text := nullif(btrim(coalesce(p_narrative, '')), '');
  v_reference text := nullif(btrim(coalesce(p_reference, '')), '');
  v_company   text;
  v_ledger    erp.ledger%rowtype;
  v_journal   uuid := p_journal_id;
  j           erp.journal%rowtype;
  e           record;
  v_account   uuid;
  v_dr        bigint;
  v_cr        bigint;
begin
  perform erp.authorise('finance.post', p_entity_id, null, null, 'journal', p_journal_id);
  v_tenant := erp.require_tenant_id();
  v_me := erp.current_principal_id();

  if p_entity_id is null or p_posting_date is null or v_narrative is null then
    raise exception 'CLOVEERP_JOURNAL_INCOMPLETE: %',
      case when p_entity_id is null then 'a journal needs the company it is for'
           when p_posting_date is null then 'a journal needs the date it posts on'
           else 'a journal needs a narrative'
      end
      using errcode = '23514',
            hint = 'Give the journal its company, its date and a narrative saying why it is posted. The narrative is what somebody reviewing the ledger reads.';
  end if;

  select c.code into v_company
    from erp.entity c
   where c.tenant_id = v_tenant
     and c.id = p_entity_id
     and c.status = 'active';
  if v_company is null then
    raise exception 'CLOVEERP_JOURNAL_INCOMPLETE: the journal names a company this organisation does not have'
      using errcode = '23503',
            hint = 'Choose one of the organisation''s companies and raise the journal again.';
  end if;

  select lg.* into v_ledger
    from erp.ledger lg
   where lg.tenant_id = v_tenant
     and lg.entity_id = p_entity_id
     and lg.is_primary
     and lg.status = 'active';
  if not found then
    raise exception 'CLOVEERP_JOURNAL_NO_PERIOD: company % keeps no general ledger yet', v_company
      using errcode = '23514',
            hint = 'Install Financials for the company under Configuration. It creates the general ledger and the fiscal calendar a journal posts into.';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'CLOVEERP_JOURNAL_INCOMPLETE: a journal needs its lines'
      using errcode = '23514',
            hint = 'Add a line for each account the journal posts to, with its debit or its credit.';
  end if;

  if jsonb_array_length(p_lines) > 500 then
    raise exception 'CLOVEERP_JOURNAL_INCOMPLETE: a journal carries at most 500 lines, and this one has %', jsonb_array_length(p_lines)
      using errcode = '22023',
            hint = 'Split the entry into several journals, each of which balances.';
  end if;

  perform erp.journal_period(v_ledger.id, p_posting_date);

  for e in
    select x.value, x.ord::integer as ord
      from jsonb_array_elements(p_lines) with ordinality as x(value, ord)
  loop
    if jsonb_typeof(e.value) <> 'object' then
      raise exception 'CLOVEERP_JOURNAL_INCOMPLETE: line % is not a line', e.ord
        using errcode = '22023',
              hint = 'Send each line as its account, its debit or its credit in minor units, and an optional description and analysis.';
    end if;

    v_account := nullif(e.value ->> 'account_id', '')::uuid;
    v_dr := coalesce(nullif(e.value ->> 'debit_minor', '')::bigint, 0);
    v_cr := coalesce(nullif(e.value ->> 'credit_minor', '')::bigint, 0);

    if v_account is null or v_dr < 0 or v_cr < 0 or (v_dr > 0) = (v_cr > 0) then
      raise exception 'CLOVEERP_JOURNAL_INCOMPLETE: line % needs an account and an amount on one side, debit or credit', e.ord
        using errcode = '23514',
              hint = 'Give every line its account and put its amount in the debit or the credit, not both. Remove a line with nothing on it.';
    end if;

    if e.value ? 'dimensions' and jsonb_typeof(e.value -> 'dimensions') not in ('object', 'null') then
      raise exception 'CLOVEERP_JOURNAL_INCOMPLETE: line % carries its analysis in a shape the ledger does not read', e.ord
        using errcode = '22023',
              hint = 'Send a line''s analysis as each dimension''s code with the value chosen for it, such as a cost centre.';
    end if;

    perform erp.journal_require_account(p_entity_id, v_account, e.ord);
  end loop;

  if v_journal is not null then
    select x.* into j
      from erp.journal x
     where x.tenant_id = v_tenant
       and x.id = v_journal
       and x.source_code = 'manual'
       and x.prepared_by is not null
       for update;
    if not found then
      raise exception 'CLOVEERP_JOURNAL_UNKNOWN: no journal raised on the Journals screen has that identifier'
        using errcode = 'P0002',
              hint = 'Refresh the list of journals and choose again. It may have been discarded.';
    end if;

    if j.status <> 'draft' or j.submitted_at is not null then
      raise exception 'CLOVEERP_JOURNAL_WRONG_STATE: this journal is %, and only a draft or a journal sent back is changed',
        erp.journal_state_words(erp.journal_state(v_journal))
        using errcode = '23514',
              hint = 'A journal waiting for approval is sent back before it is changed. A posted journal is never changed: reverse it and raise the right one.';
    end if;

    if j.reverses_journal_id is not null then
      raise exception 'CLOVEERP_JOURNAL_WRONG_STATE: a reversal is the mirror of the journal it reverses, and is not changed'
        using errcode = '23514',
              hint = 'Discard the reversal and reverse the journal again, or raise a new journal for a different entry.';
    end if;

    update erp.journal x
       set entity_id = p_entity_id,
           ledger_id = v_ledger.id,
           posting_date = p_posting_date,
           description = v_narrative,
           manual_reason = v_narrative,
           reference = v_reference,
           prepared_by = v_me,
           updated_at = now()
     where x.tenant_id = v_tenant
       and x.id = v_journal;

    delete from erp.journal_line l
     where l.tenant_id = v_tenant
       and l.journal_id = v_journal;
  else
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason, reference, prepared_by, created_by)
    values (v_tenant, p_entity_id, v_ledger.id, 'manual', p_posting_date,
            v_narrative, 'draft', v_narrative, v_reference, v_me, v_me)
    returning id into v_journal;
  end if;

  -- In the ledger's own currency, so the base amounts every statement reads
  -- are the amounts typed.
  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                currency, base_debit_minor, base_credit_minor, exchange_rate,
                                dimensions, description)
  select v_tenant, v_journal, x.ord::integer, (x.value ->> 'account_id')::uuid,
         coalesce(nullif(x.value ->> 'debit_minor', '')::bigint, 0),
         coalesce(nullif(x.value ->> 'credit_minor', '')::bigint, 0),
         v_ledger.currency,
         coalesce(nullif(x.value ->> 'debit_minor', '')::bigint, 0),
         coalesce(nullif(x.value ->> 'credit_minor', '')::bigint, 0),
         1,
         coalesce((select jsonb_object_agg(d.key, d.value)
                     from jsonb_each(case when jsonb_typeof(x.value -> 'dimensions') = 'object'
                                          then x.value -> 'dimensions'
                                          else '{}'::jsonb end) d
                    where d.value not in ('null'::jsonb, '""'::jsonb)),
                  '{}'::jsonb),
         coalesce(nullif(btrim(x.value ->> 'description'), ''), v_narrative)
    from jsonb_array_elements(p_lines) with ordinality as x(value, ord);

  if coalesce(p_submit, false) then
    perform erp.submit_journal(v_journal);
  end if;

  return erp.journal_outcome(v_journal);
end;
$$;

comment on function public.erp_raise_journal(uuid, date, text, jsonb, text, uuid, boolean) is
  'Under finance.post: a manual journal for a company, dated, with a narrative, '
  'an optional reference and its lines (account_id, debit_minor or credit_minor, '
  'optional description and dimensions), in the company''s general ledger. With '
  'p_journal_id, replaces a draft or sent-back journal''s header and lines. With '
  'p_submit, submits it too, refusing an unbalanced journal. Refuses a date no '
  'open period holds and an account not of the company, not in use or kept by a '
  'subledger. Returns the journal''s id, state, line count and totals.';

revoke all on function public.erp_raise_journal(uuid, date, text, jsonb, text, uuid, boolean) from public, anon;
grant execute on function public.erp_raise_journal(uuid, date, text, jsonb, text, uuid, boolean) to authenticated, service_role;

create or replace function public.erp_submit_journal(p_journal_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_entity uuid;
  v_found  boolean;
begin
  select x.entity_id into v_entity
    from erp.journal x
   where x.tenant_id = erp.current_tenant_id()
     and x.id = p_journal_id
     and x.source_code = 'manual'
     and x.prepared_by is not null;
  v_found := found;

  perform erp.authorise('finance.post', v_entity, null, null, 'journal', p_journal_id);

  if not v_found then
    raise exception 'CLOVEERP_JOURNAL_UNKNOWN: no journal raised on the Journals screen has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of journals and choose again. It may have been discarded.';
  end if;

  perform erp.submit_journal(p_journal_id);
  return erp.journal_outcome(p_journal_id);
end;
$$;

comment on function public.erp_submit_journal(uuid) is
  'Under finance.post: submits a draft or sent-back journal for approval, refusing '
  'one that does not balance, is dated where no open period holds it, or posts to '
  'an account not of its company, not in use or kept by a subledger.';

revoke all on function public.erp_submit_journal(uuid) from public, anon;
grant execute on function public.erp_submit_journal(uuid) to authenticated, service_role;

create or replace function public.erp_approve_journal(p_journal_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_me     uuid;
  j        erp.journal%rowtype;
  v_found  boolean;
begin
  select x.* into j
    from erp.journal x
   where x.tenant_id = erp.current_tenant_id()
     and x.id = p_journal_id
     and x.source_code = 'manual'
     and x.prepared_by is not null;
  v_found := found;

  perform erp.authorise('finance.close_period', j.entity_id, null, null, 'journal', p_journal_id);
  v_tenant := erp.require_tenant_id();
  v_me := erp.current_principal_id();

  if not v_found then
    raise exception 'CLOVEERP_JOURNAL_UNKNOWN: no journal raised on the Journals screen has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of journals and choose again. It may have been discarded.';
  end if;

  select x.* into j
    from erp.journal x
   where x.tenant_id = v_tenant
     and x.id = p_journal_id
     for update;

  if j.status <> 'draft' or j.submitted_at is null then
    raise exception 'CLOVEERP_JOURNAL_WRONG_STATE: this journal is %, and only a journal waiting for approval is approved',
      erp.journal_state_words(erp.journal_state(p_journal_id))
      using errcode = '23514',
            hint = 'Refresh the list of journals. A draft is submitted by whoever raised it; a posted journal is changed only by reversing it.';
  end if;

  -- Maker and checker, once live (20260914071000). Before go-live one person
  -- sets the organisation up, as a document's author may approve their own
  -- (20260914062000).
  if erp.tenant_is_live(v_tenant)
     and v_me = any (array_remove(array[j.created_by, j.prepared_by, j.submitted_by], null)) then
    raise exception 'CLOVEERP_JOURNAL_SELF_APPROVAL: you raised or submitted this journal, so somebody else approves it'
      using errcode = '42501',
            hint = 'Ask another person who may approve journals to approve and post it. Once the organisation is live, every journal typed by hand has a second person behind it.';
  end if;

  perform erp.journal_require_sound(p_journal_id);

  update erp.journal x
     set status = 'posted',
         posted_at = clock_timestamp(),
         posted_by = v_me,
         updated_at = now()
   where x.tenant_id = v_tenant
     and x.id = p_journal_id;

  return erp.journal_outcome(p_journal_id);
end;
$$;

comment on function public.erp_approve_journal(uuid) is
  'Under finance.close_period: approves a journal waiting for approval and posts '
  'it. Once live, refuses whoever raised, last changed or submitted it '
  '(CLOVEERP_JOURNAL_SELF_APPROVAL). Checks it again as submission did: an open '
  'period, accounts in use, debits equal to credits. The ledger numbers it when '
  'the posting commits.';

revoke all on function public.erp_approve_journal(uuid) from public, anon;
grant execute on function public.erp_approve_journal(uuid) to authenticated, service_role;

create or replace function public.erp_return_journal(p_journal_id uuid, p_note text)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  j        erp.journal%rowtype;
  v_found  boolean;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select x.* into j
    from erp.journal x
   where x.tenant_id = erp.current_tenant_id()
     and x.id = p_journal_id
     and x.source_code = 'manual'
     and x.prepared_by is not null;
  v_found := found;

  perform erp.authorise('finance.close_period', j.entity_id, null, null, 'journal', p_journal_id);
  v_tenant := erp.require_tenant_id();

  if not v_found then
    raise exception 'CLOVEERP_JOURNAL_UNKNOWN: no journal raised on the Journals screen has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of journals and choose again. It may have been discarded.';
  end if;

  if v_note is null then
    raise exception 'CLOVEERP_JOURNAL_RETURN_NEEDS_NOTE: a journal is sent back with the reason'
      using errcode = '23514',
            hint = 'Say what has to change: the account, the amount, the date or the narrative. Whoever raised the journal reads the note beside it.';
  end if;

  select x.* into j
    from erp.journal x
   where x.tenant_id = v_tenant
     and x.id = p_journal_id
     for update;

  if j.status <> 'draft' or j.submitted_at is null then
    raise exception 'CLOVEERP_JOURNAL_WRONG_STATE: this journal is %, and only a journal waiting for approval is sent back',
      erp.journal_state_words(erp.journal_state(p_journal_id))
      using errcode = '23514',
            hint = 'Refresh the list of journals: it may already have been approved, or sent back by somebody else.';
  end if;

  update erp.journal x
     set submitted_at = null,
         submitted_by = null,
         returned_at = clock_timestamp(),
         returned_by = erp.current_principal_id(),
         return_note = v_note,
         updated_at = now()
   where x.tenant_id = v_tenant
     and x.id = p_journal_id;

  return erp.journal_outcome(p_journal_id) || jsonb_build_object('return_note', v_note);
end;
$$;

comment on function public.erp_return_journal(uuid, text) is
  'Under finance.close_period: sends a journal waiting for approval back to whoever '
  'raised it, with the note saying what has to change '
  '(CLOVEERP_JOURNAL_RETURN_NEEDS_NOTE without one). It becomes a draft again.';

revoke all on function public.erp_return_journal(uuid, text) from public, anon;
grant execute on function public.erp_return_journal(uuid, text) to authenticated, service_role;

create or replace function public.erp_reverse_journal(
  p_journal_id   uuid,
  p_reason       text,
  p_posting_date date default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid;
  v_me       uuid;
  j          erp.journal%rowtype;
  v_found    boolean;
  v_reason   text := nullif(btrim(coalesce(p_reason, '')), '');
  v_on       date := coalesce(p_posting_date, current_date);
  v_existing text;
  v_label    text;
  v_rev      uuid;
begin
  select x.* into j
    from erp.journal x
   where x.tenant_id = erp.current_tenant_id()
     and x.id = p_journal_id
     and x.source_code = 'manual';
  v_found := found;

  perform erp.authorise('finance.post', j.entity_id, null, null, 'journal', p_journal_id);
  v_tenant := erp.require_tenant_id();
  v_me := erp.current_principal_id();

  if not v_found then
    raise exception 'CLOVEERP_JOURNAL_UNKNOWN: no journal typed by hand has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of journals and choose again. A document''s postings are reversed by the document that made them.';
  end if;

  if j.prepared_by is null then
    raise exception 'CLOVEERP_JOURNAL_NOT_REVERSIBLE: this journal was not raised on the Journals screen'
      using errcode = '23514',
            hint = 'A journal that came from loading opening balances is undone where it was loaded. Raise a new journal for a correction.';
  end if;

  if j.reverses_journal_id is not null then
    raise exception 'CLOVEERP_JOURNAL_NOT_REVERSIBLE: this journal is itself a reversal'
      using errcode = '23514',
            hint = 'To post the original entry again, raise a new journal for it.';
  end if;

  if j.status <> 'posted' then
    raise exception 'CLOVEERP_JOURNAL_NOT_REVERSIBLE: this journal is %, and only a posted journal is reversed',
      erp.journal_state_words(erp.journal_state(p_journal_id))
      using errcode = '23514',
            hint = 'A draft or a journal sent back is changed or discarded instead, and one waiting for approval is sent back first.';
  end if;

  select case when r.status = 'posted' then 'posted' else 'waiting for approval' end
    into v_existing
    from erp.journal r
   where r.tenant_id = v_tenant
     and r.reverses_journal_id = j.id
     and r.status in ('draft', 'posted')
   order by (r.status = 'posted') desc
   limit 1;
  if v_existing is not null then
    raise exception 'CLOVEERP_JOURNAL_NOT_REVERSIBLE: this journal already has a reversal, %', v_existing
      using errcode = '23514',
            hint = 'A journal is reversed once. Refresh the list of journals to see its reversal; one sent back is discarded before the journal is reversed again.';
  end if;

  if v_reason is null then
    raise exception 'CLOVEERP_JOURNAL_INCOMPLETE: a reversal needs its reason'
      using errcode = '23514',
            hint = 'Say why the journal is reversed. The reason is kept with the reversal for whoever reviews the ledger.';
  end if;

  perform erp.journal_period(j.ledger_id, v_on);

  -- For a posted journal, which carries its number once the posting commits.
  v_label := coalesce(j.journal_number, j.reference, to_char(j.posting_date, 'YYYY-MM-DD'));

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description,
                           status, manual_reason, reference, reverses_journal_id, prepared_by, created_by)
  values (v_tenant, j.entity_id, j.ledger_id, 'manual', v_on, format('Reversal of %s: %s', v_label, v_reason),
          'draft', v_reason, coalesce(j.journal_number, j.reference), j.id, v_me, v_me)
  returning id into v_rev;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                currency, base_debit_minor, base_credit_minor, exchange_rate,
                                dimensions, description)
  select v_tenant, v_rev, l.line_no, l.account_id, l.credit_minor, l.debit_minor,
         l.currency, l.base_credit_minor, l.base_debit_minor, l.exchange_rate,
         l.dimensions, l.description
    from erp.journal_line l
   where l.tenant_id = v_tenant
     and l.journal_id = j.id;

  perform erp.submit_journal(v_rev);
  return erp.journal_outcome(v_rev);
end;
$$;

comment on function public.erp_reverse_journal(uuid, text, date) is
  'Under finance.post: raises the reversal of a posted journal raised on the '
  'Journals screen, dated p_posting_date (today by default) with its reason, every '
  'line mirrored, and submits it for approval. The original is never changed. '
  'Refuses a journal not posted, a reversal, and one already reversed or with a '
  'reversal waiting (CLOVEERP_JOURNAL_NOT_REVERSIBLE).';

revoke all on function public.erp_reverse_journal(uuid, text, date) from public, anon;
grant execute on function public.erp_reverse_journal(uuid, text, date) to authenticated, service_role;

create or replace function public.erp_discard_journal(p_journal_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  j        erp.journal%rowtype;
  v_found  boolean;
begin
  select x.* into j
    from erp.journal x
   where x.tenant_id = erp.current_tenant_id()
     and x.id = p_journal_id
     and x.source_code = 'manual'
     and x.prepared_by is not null;
  v_found := found;

  perform erp.authorise('finance.post', j.entity_id, null, null, 'journal', p_journal_id);
  v_tenant := erp.require_tenant_id();

  if not v_found then
    raise exception 'CLOVEERP_JOURNAL_UNKNOWN: no journal raised on the Journals screen has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of journals and choose again. It may have been discarded already.';
  end if;

  select x.* into j
    from erp.journal x
   where x.tenant_id = v_tenant
     and x.id = p_journal_id
     for update;

  if j.status <> 'draft' or j.submitted_at is not null then
    raise exception 'CLOVEERP_JOURNAL_WRONG_STATE: this journal is %, and only a draft or a journal sent back is discarded',
      erp.journal_state_words(erp.journal_state(p_journal_id))
      using errcode = '23514',
            hint = 'A journal waiting for approval is sent back first. A posted journal stays in the ledger and is reversed instead.';
  end if;

  delete from erp.journal x
   where x.tenant_id = v_tenant
     and x.id = p_journal_id;

  return jsonb_build_object('journal_id', p_journal_id, 'discarded', true);
end;
$$;

comment on function public.erp_discard_journal(uuid) is
  'Under finance.post: removes a draft or sent-back journal and its lines. The '
  'audit trail keeps what it held. Refuses a journal waiting for approval or posted.';

revoke all on function public.erp_discard_journal(uuid) from public, anon;
grant execute on function public.erp_discard_journal(uuid) to authenticated, service_role;

create or replace function public.erp_journals(p_state text default null, p_limit integer default 200)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_me     uuid;
  v_live   boolean;
  v_out    jsonb;
begin
  perform erp.authorise('finance.read', null, null, null, 'journal', null);
  v_tenant := erp.require_tenant_id();
  v_me := erp.current_principal_id();
  v_live := erp.tenant_is_live(v_tenant);

  if p_state is not null and p_state not in ('draft', 'returned', 'submitted', 'posted', 'reversed') then
    raise exception 'CLOVEERP_JOURNAL_WRONG_STATE: % is not a state a journal is in', p_state
      using errcode = '22023',
            hint = 'Ask for draft, returned, submitted, posted or reversed journals, or for all of them by naming none.';
  end if;

  select coalesce(jsonb_agg(x.doc order by x.sort_at desc), '[]'::jsonb)
    into v_out
    from (
      select jsonb_build_object(
               'journal_id', j.id,
               'journal_number', j.journal_number,
               'reference', j.reference,
               'narrative', j.description,
               'entity_id', j.entity_id,
               'company', e.code,
               'ledger', lg.code,
               'currency', lg.currency,
               'posting_date', j.posting_date,
               'period', (select fp.code from erp.fiscal_period fp
                           where fp.tenant_id = j.tenant_id and fp.ledger_id = j.ledger_id
                             and j.posting_date between fp.starts_on and fp.ends_on),
               'state', s.state,
               'debit_minor', t.debit_minor,
               'credit_minor', t.credit_minor,
               'line_count', t.line_count,
               'raised_by', (select coalesce(nullif(btrim(u.display_name), ''), u.email) from erp.app_user u
                              where u.tenant_id = j.tenant_id and u.id = coalesce(j.prepared_by, j.created_by)),
               'submitted_by', (select coalesce(nullif(btrim(u.display_name), ''), u.email) from erp.app_user u
                                 where u.tenant_id = j.tenant_id and u.id = j.submitted_by),
               'submitted_at', j.submitted_at,
               'returned_by', (select coalesce(nullif(btrim(u.display_name), ''), u.email) from erp.app_user u
                                where u.tenant_id = j.tenant_id and u.id = j.returned_by),
               'returned_at', j.returned_at,
               'return_note', j.return_note,
               'posted_by', (select coalesce(nullif(btrim(u.display_name), ''), u.email) from erp.app_user u
                              where u.tenant_id = j.tenant_id and u.id = j.posted_by),
               'posted_at', j.posted_at,
               'reverses_journal_id', j.reverses_journal_id,
               'reverses_number', (select coalesce(r.journal_number, r.reference) from erp.journal r
                                    where r.tenant_id = j.tenant_id and r.id = j.reverses_journal_id),
               'reversal', (select jsonb_build_object('journal_id', r.id,
                                                      'journal_number', r.journal_number,
                                                      'state', case when r.status = 'posted' then 'posted'
                                                                    when r.submitted_at is not null then 'submitted'
                                                                    when r.returned_at is not null then 'returned'
                                                                    else 'draft' end)
                              from erp.journal r
                             where r.tenant_id = j.tenant_id and r.reverses_journal_id = j.id
                               and r.status in ('draft', 'posted')
                             order by (r.status = 'posted') desc, r.created_at desc
                             limit 1),
               'raised_here', j.prepared_by is not null,
               'you_raised', coalesce(v_me = any (array_remove(array[j.created_by, j.prepared_by, j.submitted_by], null)), false),
               'you_may_approve', s.state = 'submitted'
                                  and (not v_live
                                       or not coalesce(v_me = any (array_remove(array[j.created_by, j.prepared_by, j.submitted_by], null)), false)),
               'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                                   'line_no', l.line_no,
                                   'account_id', l.account_id,
                                   'account_code', a.code,
                                   'account_name', a.name,
                                   'debit_minor', l.debit_minor,
                                   'credit_minor', l.credit_minor,
                                   'description', l.description,
                                   'dimensions', l.dimensions) order by l.line_no), '[]'::jsonb)
                           from erp.journal_line l
                           join erp.account a on a.tenant_id = l.tenant_id and a.id = l.account_id
                          where l.tenant_id = j.tenant_id and l.journal_id = j.id)
             ) as doc,
             coalesce(j.posted_at, j.submitted_at, j.returned_at, j.updated_at) as sort_at
        from erp.journal j
        join erp.entity e on e.tenant_id = j.tenant_id and e.id = j.entity_id
        join erp.ledger lg on lg.tenant_id = j.tenant_id and lg.id = j.ledger_id
        cross join lateral (select erp.journal_state(j.id) as state) s
        cross join lateral (
          select coalesce(sum(l.debit_minor), 0) as debit_minor,
                 coalesce(sum(l.credit_minor), 0) as credit_minor,
                 count(*) as line_count
            from erp.journal_line l
           where l.tenant_id = j.tenant_id and l.journal_id = j.id) t
       where j.tenant_id = v_tenant
         and j.source_code = 'manual'
         and (p_state is null or s.state = p_state)
       order by coalesce(j.posted_at, j.submitted_at, j.returned_at, j.updated_at) desc
       limit greatest(1, least(coalesce(p_limit, 200), 500))
    ) x;

  return v_out;
end;
$$;

comment on function public.erp_journals(text, integer) is
  'Under finance.read: journals typed by hand, newest first, each with its state '
  '(draft, returned, submitted, posted, reversed), company, ledger, period, totals, '
  'who raised, submitted, sent back and posted it, its reversal or what it '
  'reverses, whether the caller raised it and may approve it, and its lines. '
  'Volatile because erp.authorise() records the access decision; writes nothing else.';

revoke all on function public.erp_journals(text, integer) from public, anon;
grant execute on function public.erp_journals(text, integer) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Closing is honest
-- ═════════════════════════════════════════════════════════════════════════════

-- Same signature and return type as 20260829300000, so the grants stay.
create or replace function erp.close_period(p_fiscal_period_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  p        erp.fiscal_period%rowtype;
  v_open   text;
begin
  perform erp.authorise('finance.close_period', null, null, null,
                        'fiscal_period', p_fiscal_period_id);

  select fp.* into p
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.id = p_fiscal_period_id
     for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_FISCAL_PERIOD: no period of this organisation has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of periods and choose again.';
  end if;

  if p.status = 'permanently_closed' then
    raise exception 'CLOVEERP_PERIOD_PERMANENTLY_CLOSED: % was closed for good at the end of its year', p.code
      using errcode = '23514',
            hint = 'A period of a closed year is neither closed again nor reopened. Post an adjustment in the current year.';
  end if;

  -- A period with no checklist has nothing saying it is ready to close.
  if not exists (select 1 from erp.close_task t
                  where t.tenant_id = v_tenant and t.fiscal_period_id = p.id) then
    raise exception 'CLOVEERP_CLOSE_NO_TASKS: % has no close tasks, so nothing says it is ready to close', p.code
      using errcode = '23514',
            hint = format('Open a period close for %s first: it raises the tasks that are done before the period shuts. If there are no tasks to raise, install Period close under Configuration.', p.code);
  end if;

  select string_agg(t.name, ', ' order by t.seq, t.code) into v_open
    from erp.close_task t
   where t.tenant_id = v_tenant
     and t.fiscal_period_id = p.id
     and t.status not in ('complete', 'waived');

  if v_open is not null then
    raise exception 'CLOVEERP_CLOSE_TASKS_OPEN: % still has close tasks open: %', p.code, v_open
      using errcode = '23514',
            hint = format('Complete %s, or waive a task with the reason it is passed, then close %s.', v_open, p.code);
  end if;

  -- The moment of closing rather than the start of the transaction: a reopening
  -- recorded before it no longer opens the period (erp.period_accepts_postings).
  update erp.fiscal_period fp
     set status = 'closed',
         closed_at = clock_timestamp(),
         closed_by = erp.current_principal_id(),
         updated_at = now()
   where fp.tenant_id = v_tenant
     and fp.id = p.id;
end;
$$;

comment on function erp.close_period(uuid) is
  'Closes a fiscal period under finance.close_period once its close tasks exist and '
  'are all complete or waived. Refuses a period with no close tasks '
  '(CLOVEERP_CLOSE_NO_TASKS), one with tasks open, named (CLOVEERP_CLOSE_TASKS_OPEN), '
  'and a permanently closed one. Closing again after a reopening closes it '
  '(20260914071000).';

-- Same signature and return type as 0026, so the grants stay.
create or replace function erp.reopen_period(p_fiscal_period_id uuid, p_reason text)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     bigint;
  p        erp.fiscal_period%rowtype;
begin
  perform erp.authorise('finance.reopen_period', null, null, null,
                        'fiscal_period', p_fiscal_period_id);

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'CLOVEERP_REOPENING_NEEDS_REASON: a period is not reopened without one'
      using errcode = '23514',
            hint = 'Say why the period is reopened and what is to be posted into it. The reason is kept with the reopening.';
  end if;

  select fp.* into p
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.id = p_fiscal_period_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_FISCAL_PERIOD: no period of this organisation has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of periods and choose again.';
  end if;

  if p.status = 'permanently_closed' then
    raise exception 'CLOVEERP_PERIOD_PERMANENTLY_CLOSED: % was closed for good at the end of its year', p.code
      using errcode = '23514',
            hint = 'A period of a closed year is not reopened. Post the adjustment in the current year.';
  end if;

  insert into erp.period_reopening (tenant_id, fiscal_period_id, reopened_by, reason)
  values (v_tenant, p_fiscal_period_id, erp.current_principal_id(), p_reason)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function erp.reopen_period(uuid, text) is
  'Records a reopening of a closed period under finance.reopen_period, with its '
  'reason. It lets postings in until the period is closed again. Refuses a '
  'permanently closed period (20260914071000).';

-- A reopening counts only when it was made after the period last closed, so
-- closing again closes. Patched by counted replacement of the one line that
-- reads a reopening, from the body 0026 wrote and 20260906030000 extended.
do $period$
declare
  v_sig text := 'erp.check_period_open()';
  v_def text := pg_get_functiondef('erp.check_period_open()'::regprocedure);
  v_n   text := $n$         and r.reclosed_at is null
$n$;
  v_r   text := $r$         and r.reclosed_at is null
         -- Made after the period last closed: a reopening before a later
         -- close no longer opens it (20260914071000).
         and r.reopened_at > coalesce(v_period.closed_at, '-infinity'::timestamptz)
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PERIOD_GUARD_UNRECOGNISED: erp.check_period_open() does not read a reopening the way this migration patches'
      using hint = 'A later migration changed the period guard. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('coalesce(v_period.closed_at' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PERIOD_GUARD_UNRECOGNISED: the period guard did not take the rule'
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the guard.';
  end if;
end
$period$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Year end
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_close_fiscal_year(p_fiscal_period_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  p        erp.fiscal_period%rowtype;
  v_last   erp.fiscal_period%rowtype;
  v_open   text;
  v_n      integer;
  v_ledger text;
begin
  perform erp.authorise('finance.close_period', null, null, null, 'fiscal_period', p_fiscal_period_id);
  v_tenant := erp.require_tenant_id();

  select fp.* into p
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.id = p_fiscal_period_id
     for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_FISCAL_PERIOD: no period of this organisation has that identifier'
      using errcode = 'P0002',
            hint = 'Refresh the list of periods and choose again.';
  end if;

  if p.status = 'permanently_closed' then
    raise exception 'CLOVEERP_PERIOD_PERMANENTLY_CLOSED: fiscal year % of this ledger is already closed for good', p.fiscal_year
      using errcode = '23514',
            hint = 'Nothing more is done to a closed year. Post an adjustment to it in the current year.';
  end if;

  select fp.* into v_last
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.ledger_id = p.ledger_id
     and fp.fiscal_year = p.fiscal_year
   order by fp.period_number desc
   limit 1;

  if v_last.id <> p.id then
    raise exception 'CLOVEERP_YEAR_END_NOT_LAST_PERIOD: % is not the last period of fiscal year %', p.code, p.fiscal_year
      using errcode = '23514',
            hint = format('A year is closed from its last period. Choose %s.', v_last.code);
  end if;

  select string_agg(fp.code, ', ' order by fp.period_number) into v_open
    from erp.fiscal_period fp
   where fp.tenant_id = v_tenant
     and fp.ledger_id = p.ledger_id
     and fp.fiscal_year = p.fiscal_year
     and coalesce(erp.period_accepts_postings(fp.id), true);

  if v_open is not null then
    raise exception 'CLOVEERP_YEAR_END_PERIODS_OPEN: fiscal year % still has periods taking postings: %', p.fiscal_year, v_open
      using errcode = '23514',
            hint = format('Close %s first, each once its close tasks are done, then close the year. A period reopened since it closed counts as open.', v_open);
  end if;

  update erp.fiscal_period fp
     set status = 'permanently_closed',
         updated_at = now()
   where fp.tenant_id = v_tenant
     and fp.ledger_id = p.ledger_id
     and fp.fiscal_year = p.fiscal_year;
  get diagnostics v_n = row_count;

  select lg.code into v_ledger
    from erp.ledger lg
   where lg.tenant_id = v_tenant
     and lg.id = p.ledger_id;

  return jsonb_build_object('ledger', v_ledger, 'fiscal_year', p.fiscal_year,
                            'periods', v_n, 'status', 'permanently_closed');
end;
$$;

comment on function public.erp_close_fiscal_year(uuid) is
  'Year end under finance.close_period: given the last period of a fiscal year, '
  'marks every period of that year in its ledger permanently closed, so nothing is '
  'posted into, closed again in or reopened in that year. Refuses a period that is '
  'not the year''s last (CLOVEERP_YEAR_END_NOT_LAST_PERIOD) and a year with any '
  'period still taking postings (CLOVEERP_YEAR_END_PERIODS_OPEN).';

revoke all on function public.erp_close_fiscal_year(uuid) from public, anon;
grant execute on function public.erp_close_fiscal_year(uuid) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Whoever raises an invoice issues and reprints it
-- ═════════════════════════════════════════════════════════════════════════════

do $templates$
declare
  v_n     integer;
  v_rules text;
begin
  -- No segregation rule in any pack names either code, so adding them to a
  -- template cannot put a prohibited pairing in anybody's hands.
  select string_agg(pi.pack_code || '/' || pi.object_key, ', ') into v_rules
    from erp_ref.pack_item pi
   where pi.object_kind = 'sod_rule'
     and (pi.payload ->> 'permissions_a' ~ 'document\.(issue|reprint)'
          or pi.payload ->> 'permissions_b' ~ 'document\.(issue|reprint)');
  if v_rules is not null then
    raise exception 'CLOVEERP_PACK_TEMPLATE_CONFLICT: segregation rules name issuing or reprinting: %', v_rules
      using hint = 'A later migration added a rule on document.issue or document.reprint. Read it against the finance clerk and sales administrator templates before giving them either.';
  end if;

  update erp_ref.pack_item pi
     set payload = jsonb_set(pi.payload, '{permissions}',
                     (pi.payload -> 'permissions')
                     || jsonb_build_array(jsonb_build_object('permission', 'document.issue'),
                                          jsonb_build_object('permission', 'document.reprint'))),
         provenance = v.why
    from (values
      ('finance_clerk',
       'Starter Content Packs §3.2. Posts and matches, raises the journals a '
       'manager approves, and issues and reprints the invoices it raises; approves '
       'nothing (20260914071000).'),
      ('sales_administrator',
       'Starter Content Packs §3.2. Takes orders, and raises, issues and reprints '
       'invoices; the discount and the credit release are the manager''s '
       '(20260914071000).')
    ) as v(role_code, why)
   where pi.pack_code = 'base'
     and pi.object_kind = 'role'
     and pi.object_key = v.role_code
     and not (pi.payload -> 'permissions' @> '[{"permission": "document.issue"}]'::jsonb)
     and not (pi.payload -> 'permissions' @> '[{"permission": "document.reprint"}]'::jsonb);
  get diagnostics v_n = row_count;
  if v_n <> 2 then
    raise exception 'CLOVEERP_PACK_TEMPLATE_MISSING: % of 2 base pack role templates took issuing and reprinting', v_n
      using hint = 'The templates are registered by 20260903150000; a code changed name, or a template already holds document.issue or document.reprint.';
  end if;
end
$templates$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Registers
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_raise_journal', 'erp.authorise',
   'Raises or changes a draft manual journal and its lines under finance.post, in the company''s general ledger, refusing a date no open period holds and an account not of the company, not in use or kept by a subledger; submits it when asked (20260914071000).'),
  ('erp_submit_journal', 'erp.authorise',
   'Submits a draft or sent-back journal for approval under finance.post, once it balances and posts into an open period (20260914071000).'),
  ('erp_approve_journal', 'erp.authorise',
   'Approves and posts a journal waiting for approval under finance.close_period. Once live, refuses whoever raised, changed or submitted it (20260914071000).'),
  ('erp_return_journal', 'erp.authorise',
   'Sends a journal waiting for approval back to draft under finance.close_period, with the note saying what has to change (20260914071000).'),
  ('erp_reverse_journal', 'erp.authorise',
   'Raises and submits the mirror of a posted manual journal under finance.post. The original is never changed; the reversal is approved like any journal (20260914071000).'),
  ('erp_discard_journal', 'erp.authorise',
   'Removes a draft or sent-back manual journal and its lines under finance.post; the audit trail keeps them (20260914071000).'),
  ('erp_journals', 'erp.authorise',
   'A read of manual journals, their states and lines. Volatile because erp.authorise() records the access decision; writes nothing else. finance.read.'),
  ('erp_close_fiscal_year', 'erp.authorise',
   'Year end under finance.close_period: marks every period of a fiscal year permanently closed once each is closed (20260914071000).')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

do $allowances$
declare
  v_n integer;
begin
  update erp_meta.public_write_allowance a
     set rationale = v.rationale
    from (values
      ('erp_close_period',
       'Closes a fiscal period under finance.close_period once its close tasks, opened by erp_open_period_close, are all complete or waived. Refuses a period with no close tasks, with tasks open, or closed for good (20260914071000).'),
      ('erp_reopen_period',
       'Reopens a closed fiscal period under finance.reopen_period, which is its own permission because reopening is not the inverse of closing. Refuses a period closed for good at year end (20260914071000).')
    ) as v(function_name, rationale)
   where a.function_name = v.function_name;
  get diagnostics v_n = row_count;
  if v_n <> 2 then
    raise exception 'CLOVEERP_WRITE_ALLOWANCE_NOT_UPDATED: % of 2 write allowance rows were reworded', v_n
      using hint = 'The rows are written by 20260829320000. If row security refused the update, the migration role has lost its bypass.';
  end if;
end
$allowances$;

update erp_ref.part5_capability
   set artefacts = artefacts || array['public.erp_close_fiscal_year(uuid)',
                                      'erp.period_accepts_postings(uuid)']
 where code = '5.7.period_close'
   and not ('public.erp_close_fiscal_year(uuid)' = any (artefacts));

-- The document page reads a sales invoice's readiness before its Issue button
-- is pressed, so the door has found the screen 20260912270000 registered it as
-- waiting for, and a row for a door a screen names is stale.
do $home$
declare
  v_n integer;
begin
  delete from erp_meta.api_only_door
   where function_name = 'erp_sales_invoice_issue_readiness'
     and caller = 'pending_screen';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_API_ONLY_DOOR_MISSING: % pending row(s) for erp_sales_invoice_issue_readiness, expected 1', v_n
      using hint = 'The row is registered by 20260912270000. A later migration moved or removed it; read erp_meta.api_only_door before changing this.';
  end if;
end
$home$;

select erp.register_refusal('CLOVEERP_JOURNAL_UNKNOWN',
  'Acting on a journal that is not there.',
  'The journal named is not one raised on the Journals screen in this organisation: it may have been discarded, or belong to somebody else.',
  'Refresh the list of journals and choose again.');

select erp.register_refusal('CLOVEERP_JOURNAL_INCOMPLETE',
  'A journal without what it needs.',
  'A journal says which company it is for, the date it posts on and why, and every line names an account with an amount on one side. A reversal says why.',
  'Fill in what is missing and try again.');

select erp.register_refusal('CLOVEERP_JOURNAL_NO_PERIOD',
  'A journal dated where the company has no accounting period.',
  'A journal posts into a period of the company''s general ledger, and there is no ledger, or no period holds that date.',
  'Date the journal inside the company''s fiscal calendar, or install Financials for the company first.');

select erp.register_refusal('CLOVEERP_JOURNAL_PERIOD_CLOSED',
  'A journal dated in a closed period.',
  'A closed period''s figures have been reported, and a period closed at year end is closed for good.',
  'Date the journal in an open period, or ask somebody who may reopen periods to reopen it with the reason.');

select erp.register_refusal('CLOVEERP_JOURNAL_ACCOUNT_UNKNOWN',
  'A journal line on an account of another company.',
  'Each company keeps its own chart of accounts, and a journal posts to the chart of the company it is for.',
  'Choose the account from that company''s chart.');

select erp.register_refusal('CLOVEERP_JOURNAL_ACCOUNT_INACTIVE',
  'A journal line on an account that is not in use.',
  'An account taken out of use takes no new postings, so its balance stays what was reported.',
  'Choose an account in use, or ask whoever keeps the chart of accounts to bring it back into use.');

select erp.register_refusal('CLOVEERP_JOURNAL_CONTROL_ACCOUNT',
  'A journal line on an account its own ledger keeps.',
  'Receivables, payables, stock, bank, tax and asset accounts are the totals of the detail behind them. A journal typed straight onto one would leave the account and its detail disagreeing, which the period close checks.',
  'Record the invoice, bill, payment, cash, stock movement or asset that belongs there, and the account follows, or post to an account no ledger keeps.');

select erp.register_refusal('CLOVEERP_JOURNAL_NOT_BALANCED',
  'A journal whose debits and credits differ.',
  'Every entry has two sides. A journal that does not balance would leave the ledger out by the difference.',
  'Correct the lines so that the debits equal the credits, then submit the journal again.');

select erp.register_refusal('CLOVEERP_JOURNAL_WRONG_STATE',
  'Doing something to a journal that its state does not allow.',
  'A draft is changed, submitted or discarded; a journal waiting for approval is approved or sent back; a posted journal is only reversed.',
  'Refresh the list of journals and act on the journal as it now stands.');

select erp.register_refusal('CLOVEERP_JOURNAL_SELF_APPROVAL',
  'Approving a journal you raised or submitted yourself.',
  'Once the organisation is live, a journal typed by hand is posted only when a second person agrees with it.',
  'Ask another person who may approve journals to approve and post it.');

select erp.register_refusal('CLOVEERP_JOURNAL_RETURN_NEEDS_NOTE',
  'Sending a journal back without saying why.',
  'Whoever raised the journal changes it from the note, and without one they cannot tell what is wrong.',
  'Say what has to change, then send the journal back.');

select erp.register_refusal('CLOVEERP_JOURNAL_NOT_REVERSIBLE',
  'Reversing a journal that cannot be reversed here.',
  'Only a posted journal raised on the Journals screen is reversed, and only once. A reversal is not reversed, and opening balances are undone where they were loaded.',
  'Refresh the list of journals. To post an entry again, raise a new journal for it.');

select erp.register_refusal('CLOVEERP_CLOSE_NO_TASKS',
  'Closing a period that has no close tasks.',
  'The close tasks are what say a period is ready to close: reconciliations done, reviews signed. A period closed without them was closed on nobody''s word.',
  'Open a period close for the period, work through its tasks, then close it. If there are no tasks to raise, install Period close under Configuration.');

select erp.register_refusal('CLOVEERP_CLOSE_TASKS_OPEN',
  'Closing a period while close tasks are still open.',
  'A period closes once everything its close needs is done, or passed over with a reason somebody will read.',
  'Complete each open close task, or waive it with the reason, then close the period.');

select erp.register_refusal('CLOVEERP_PERIOD_PERMANENTLY_CLOSED',
  'Posting into, closing or reopening a period of a year closed for good.',
  'A year closed at year end has been reported on, so nothing in it changes.',
  'Post the adjustment in the current year.');

select erp.register_refusal('CLOVEERP_YEAR_END_NOT_LAST_PERIOD',
  'Closing a year from a period that is not its last.',
  'A year is closed from its final period, once every period before it has closed.',
  'Choose the last period of the fiscal year.');

select erp.register_refusal('CLOVEERP_YEAR_END_PERIODS_OPEN',
  'Closing a year while some of its periods still take postings.',
  'Closing a year closes every period of it for good, so each one is closed first.',
  'Close each period still open, once its close tasks are done, then close the year.');

select erp.register_refusal('CLOVEERP_UNKNOWN_FISCAL_PERIOD',
  'Acting on an accounting period that is not there.',
  'The period named is not one of this organisation''s.',
  'Refresh the list of periods and choose again.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, module_code) values
  ('nav.finance_journals', 'en', 'Journals', 'finance'),
  ('nav.finance_journals', 'de', 'Journalbuchungen', 'finance')
on conflict (key, locale) do update set value = excluded.value, module_code = excluded.module_code;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/finance/journals', 'nav.finance_journals', 'finance',
   'Journals typed by hand: accruals, prepayments, corrections and reclassifications. One person raises a journal and submits it; a second person approves it, which posts it. A posted journal is never changed: reversing it raises its mirror, which is approved the same way.',
   '["Press New journal, choose the company and the date, and say in the narrative why the journal is posted.","Add a line for each account with its debit or its credit, in pounds and pence. The totals show whether it balances, and Submit for approval waits until it does.","Somebody who may approve journals opens Waiting for approval and presses Approve and post, or Send back with a note saying what to change.","Change a journal that was sent back and submit it again, or discard it.","To undo a posted journal, press Reverse, give the date and the reason, and have the reversal approved."]',
   'Raise the month''s accruals as journals, have them approved, then close the period.',
   '{erp_journals,erp_raise_journal,erp_submit_journal,erp_approve_journal,erp_return_journal,erp_reverse_journal,erp_discard_journal}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;

select erp_meta.add_help_actions('/finance', array['erp_close_fiscal_year']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    -- Financials: the Journals step, the Close step, year end and the tile.
    ('Journals',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    ('Accruals and corrections typed by hand: raised by one person, approved and posted by another.',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    ('Open journals',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    ('Open a period''s close, work through its tasks, close the period, and at the end of the year close the year for good.',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    ('Closes the period once its close has been opened and every task is complete or waived. Nothing more is posted into it unless it is reopened.',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    ('Close the fiscal year',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    ('Year end, once every period of the year is closed: each period of it is closed for good, and nothing is posted into, closed or reopened in that year again.',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    ('Last period of the year',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    ('Accruals, prepayments and corrections typed by hand: raised by one person, approved and posted by another, reversed rather than changed.',
     'Financials: the Journals and Close steps, year end and the Journals tile (20260914071000).'),
    -- The Journals screen.
    ('A journal needs its company, its date and a narrative.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Accruals, prepayments and corrections typed by hand. One person raises and submits a journal; somebody else who may approve journals posts it. A posted journal is never changed, only reversed.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('An amount is never negative: put it on the other side instead.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Approve and post',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Approved and posted.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Balanced',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Change the journal',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Choose the account.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Choose the company first: each company keeps its own accounts.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Date',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Date of the reversal',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Debits',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Discard',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Give the line an amount, debit or credit.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('It becomes a draft again, with your note beside it for whoever raised it.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Journals typed by hand',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Kept with the reversal for whoever reviews the ledger.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Narrative',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('New journal',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Newest first. Open a journal to see its lines and what can be done with it.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('No journals here. A journal raised with New journal appears here as a draft.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('None',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Optional. Your own reference.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Posted',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Posted by',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Put the amount in the debit or the credit, not both.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Raised by',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Raises the mirror of every line for somebody else to approve. The journal itself is never changed.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Reversal',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Reverse the journal',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Reversed',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Reverses',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Save as a draft',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Saved as a draft.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Send the journal back',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Sent back',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Sent back by',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Show journals',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Submit for approval waits until every line has an account and one amount, and the debits equal the credits.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Submitted by',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Submitted for approval.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('That amount cannot be read as money.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('The currency list could not be loaded, so an amount cannot be converted safely. Nothing has been submitted.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('The day it posts on. It has to fall in an open period.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('The narrative, unless you say otherwise',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Today when left empty. It has to fall in an open period.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('What has to change',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('What is missing?',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Whoever raised the journal reads this beside it.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Why it is reversed',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('Why the journal is posted. It is what somebody reviewing the ledger reads.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    ('You raised or submitted this journal, so somebody else approves it.',
     'The Journals screen, where manual journals are raised, approved, sent back and reversed (20260914071000).'),
    -- A sales invoice's Issue panel.
    ('Legal invoice',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).'),
    ('Issuing gives the invoice its permanent number and files the PDF the customer receives. A reprint hands back the same file; nothing is rendered again.',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).'),
    ('Issued as',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).'),
    ('The number is held, but the PDF was not filed. Nothing has been sent.',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).'),
    ('Issue the invoice',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).'),
    ('Before it is issued, this invoice needs:',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).'),
    ('Not issued yet.',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).'),
    ('Open the PDF',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).'),
    ('The link lasts five minutes.',
     'A sales invoice''s Issue panel, where its legal number and PDF are issued and reprinted (20260914071000).')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Organisation A is live: two administrators, the base pack's segregation
-- rules, and three people holding roles made from the base pack's finance
-- clerk and finance manager templates and a read-only one, given by the first
-- administrator. Its general ledger has last year's calendar, closed but for
-- one period, and this year's, open but for one. Organisation B is not yet
-- live, with one administrator. Every door is called as a signed-in caller
-- through erp_test.journal_door_as(). Both organisations are undone.

create or replace function erp_test.journal_door_as(
  p_subject uuid,
  p_door    text,
  p_args    jsonb default '{}'::jsonb
) returns table (outcome jsonb, err_state text, err_message text, err_hint text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner text := current_user;
  a       jsonb := coalesce(p_args, '{}'::jsonb);
begin
  if p_door not in ('erp_raise_journal', 'erp_submit_journal', 'erp_approve_journal', 'erp_return_journal',
                    'erp_reverse_journal', 'erp_discard_journal', 'erp_journals', 'erp_close_fiscal_year',
                    'erp_close_period', 'erp_open_period_close', 'erp_complete_close_task', 'erp_reopen_period') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a door erp_test.journal_and_close_suite calls', p_door
      using hint = 'Call one of the journal doors, erp_close_fiscal_year, erp_close_period, erp_open_period_close, erp_complete_close_task or erp_reopen_period.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    if p_door = 'erp_raise_journal' then
      outcome := public.erp_raise_journal((a ->> 'entity_id')::uuid, (a ->> 'posting_date')::date,
                                          a ->> 'narrative', a -> 'lines', a ->> 'reference',
                                          (a ->> 'journal_id')::uuid, coalesce((a ->> 'submit')::boolean, false));
    elsif p_door = 'erp_submit_journal' then
      outcome := public.erp_submit_journal((a ->> 'journal_id')::uuid);
    elsif p_door = 'erp_approve_journal' then
      outcome := public.erp_approve_journal((a ->> 'journal_id')::uuid);
    elsif p_door = 'erp_return_journal' then
      outcome := public.erp_return_journal((a ->> 'journal_id')::uuid, a ->> 'note');
    elsif p_door = 'erp_reverse_journal' then
      outcome := public.erp_reverse_journal((a ->> 'journal_id')::uuid, a ->> 'reason', (a ->> 'posting_date')::date);
    elsif p_door = 'erp_discard_journal' then
      outcome := public.erp_discard_journal((a ->> 'journal_id')::uuid);
    elsif p_door = 'erp_journals' then
      outcome := public.erp_journals(a ->> 'state', coalesce((a ->> 'limit')::integer, 200));
    elsif p_door = 'erp_close_fiscal_year' then
      outcome := public.erp_close_fiscal_year((a ->> 'fiscal_period_id')::uuid);
    elsif p_door = 'erp_close_period' then
      perform public.erp_close_period((a ->> 'fiscal_period_id')::uuid);
      outcome := to_jsonb('closed'::text);
    elsif p_door = 'erp_open_period_close' then
      outcome := to_jsonb(public.erp_open_period_close((a ->> 'fiscal_period_id')::uuid));
    elsif p_door = 'erp_complete_close_task' then
      outcome := to_jsonb(public.erp_complete_close_task((a ->> 'task_id')::uuid, a ->> 'waiver_reason'));
    else
      outcome := to_jsonb(public.erp_reopen_period((a ->> 'fiscal_period_id')::uuid, a ->> 'reason'));
    end if;
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text,
                            err_hint = pg_exception_hint;
  end;
  execute format('set local role %I', v_owner);
  return next;
end;
$$;
revoke all on function erp_test.journal_door_as(uuid, text, jsonb) from public, anon, authenticated;

comment on function erp_test.journal_door_as(uuid, text, jsonb) is
  'Suite helper: calls one journal or period-close door with its arguments as '
  'jsonb, as the given sign-in, in the authenticated role, and returns its answer '
  'or its refusal with the hint. Returns to the calling role before it returns.';

create or replace function erp_test.journal_and_close_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tag       text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_year      integer := extract(year from current_date)::integer;
  v_month     integer := extract(month from current_date)::integer;
  -- A period of this year to be found closed, and one to close through the
  -- doors, neither of them the current one.
  v_closed_no integer := case when extract(month from current_date)::integer = 1 then 2 else 1 end;
  v_close_no  integer := case when extract(month from current_date)::integer = 12 then 11 else 12 end;
  ra record; rb record; d record;
  -- Organisation A, live.
  s_admin    uuid := gen_random_uuid();
  s_second   uuid := gen_random_uuid();
  s_clerk    uuid := gen_random_uuid();
  s_manager  uuid := gen_random_uuid();
  s_viewer   uuid := gen_random_uuid();
  u_admin    uuid; u_second uuid; u_clerk uuid; u_manager uuid; u_viewer uuid;
  t_tok      text;
  v_ledger   uuid;
  v_exp      uuid; v_acc uuid; v_old uuid; v_rec uuid;
  v_p_now    uuid; v_p_closed uuid; v_p_close uuid;
  v_p_prior_last uuid; v_p_prior_mid uuid; v_p_prior_open uuid;
  v_prior_last_code text; v_prior_open_code text;
  v_lines    jsonb;
  v_small    jsonb;
  v_unbalanced jsonb;
  v_j1 uuid; v_j2 uuid; v_j3 uuid; v_j4 uuid; v_j5 uuid; v_j6 uuid; v_rev uuid;
  v_j1_xmin  text; v_j1_lines jsonb;
  v_task_bank uuid; v_task_review uuid;
  v_fixture  text;
  v_list     jsonb;
  v_step     text := 'reading the pack';
  v_state_a  text;
  -- Organisation B, not yet live.
  s_badmin   uuid := gen_random_uuid();
  u_badmin   uuid;
  v_bledger  uuid; v_bexp uuid; v_bacc uuid; v_bj uuid;
  v_state_b  text;
  -- The doors and the pack.
  v_doors_bad text;
  v_fc text[]; v_fm text[]; v_sa text[];
  v_breaks text;

  ok_roles    boolean; msg_roles    text;
  ok_post     boolean; msg_post     text;
  ok_unbal    boolean; msg_unbal    text;
  ok_closed   boolean; msg_closed   text;
  ok_account  boolean; msg_account  text;
  ok_self     boolean; msg_self     text;
  ok_prelive  boolean; msg_prelive  text;
  ok_return   boolean; msg_return   text;
  ok_reverse  boolean; msg_reverse  text;
  ok_signed   boolean; msg_signed   text;
  ok_notasks  boolean; msg_notasks  text;
  ok_open     boolean; msg_open     text;
  ok_closes   boolean; msg_closes   text;
  ok_yearend  boolean; msg_yearend  text;
begin
  -- ── The doors as the catalogue holds them ──────────────────────────────
  select string_agg(format('%s: %s function(s), definer %s, volatility %s, executable %s',
                           w.door, coalesce(f.n, 0), f.sd, f.vol, f.ex), '; ' order by w.door)
           filter (where coalesce(f.n, 0) <> 1 or coalesce(f.sd, true) or coalesce(f.vol, '') <> 'v'
                         or not coalesce(f.ex, false))
    into v_doors_bad
    from unnest(array['erp_raise_journal', 'erp_submit_journal', 'erp_approve_journal', 'erp_return_journal',
                      'erp_reverse_journal', 'erp_discard_journal', 'erp_journals', 'erp_close_fiscal_year']) as w(door)
    left join lateral (
      select count(*)::integer as n, bool_or(p.prosecdef) as sd, min(p.provolatile::text) as vol,
             bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                      and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')) as ex
        from pg_catalog.pg_proc p
       where p.pronamespace = 'public'::regnamespace
         and p.proname = w.door) f on true;

  -- ── The templates ──────────────────────────────────────────────────────
  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'finance_clerk') into v_fc;
  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'finance_manager') into v_fm;
  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'sales_administrator') into v_sa;

  select string_agg(format('%s holds both sides of %s', h.holder, s.object_key), '; ' order by h.holder, s.object_key)
    into v_breaks
    from (select 'finance_clerk'::text as holder, v_fc as perms
          union all select 'finance_manager', v_fm
          union all select 'sales_administrator', v_sa) h
    cross join erp_ref.pack_item s
   where s.object_kind = 'sod_rule'
     and s.payload ->> 'severity' = 'prohibited'
     and h.perms && string_to_array(s.payload ->> 'permissions_a', ',')
     and h.perms && string_to_array(s.payload ->> 'permissions_b', ',');

  -- ───────────────────────────────────────────────────────────────────────────
  -- Organisation A, live
  -- ───────────────────────────────────────────────────────────────────────────
  begin
    v_step := 'organisation A is provisioned and its two administrators join';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzjnla-' || v_tag, 'Journal Suite A',
                                               'admin@zzjnla-' || v_tag || '.test', 'Journal Admin');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    u_admin := erp.claim_invitation(ra.admin_token);
    select i.app_user_id, i.token into u_second, t_tok
      from erp.invite_principal('second@zzjnla-' || v_tag || '.test', 'Second Admin') i;
    perform erp.grant_role(u_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', s_second)::text, true);
    perform erp.claim_invitation(t_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);

    v_step := 'the base pack''s rules and roles from its finance templates, while the organisation is opened for it';
    perform erp_test.reopen_bootstrap_window(ra.tenant_id);
    perform erp.upsert_sod_rule(
              pi.payload ->> 'code', pi.payload ->> 'name',
              string_to_array(pi.payload ->> 'permissions_a', ','),
              string_to_array(pi.payload ->> 'permissions_b', ','),
              coalesce(pi.payload ->> 'severity', 'material')::erp.sod_severity,
              pi.payload ->> 'description', pi.payload ->> 'mitigation')
       from erp_ref.pack_item pi
      where pi.pack_code = 'base' and pi.object_kind = 'sod_rule';
    insert into erp.role (tenant_id, code, name, status) values
      (ra.tenant_id, 'zz_finance_clerk',   'Suite finance clerk',   'active'),
      (ra.tenant_id, 'zz_finance_manager', 'Suite finance manager', 'active'),
      (ra.tenant_id, 'zz_finance_viewer',  'Suite finance viewer',  'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select ra.tenant_id, ro.id, x.perm
      from (select distinct 'zz_finance_clerk'::text as role_code, c as perm from unnest(v_fc) c
            union select distinct 'zz_finance_manager', c from unnest(v_fm) c
            union select 'zz_finance_viewer', 'finance.read') x
      join erp.role ro on ro.tenant_id = ra.tenant_id and ro.code = x.role_code;

    v_step := 'a general ledger with last year''s calendar and this year''s, four accounts and a close checklist';
    insert into erp.ledger (tenant_id, entity_id, code, name, ledger_kind, currency, is_primary, status)
    values (ra.tenant_id, ra.entity_id, 'GL', 'General ledger', 'statutory', 'GBP', true, 'active')
    returning id into v_ledger;
    insert into erp.fiscal_period (tenant_id, ledger_id, code, fiscal_year, period_number,
                                   starts_on, ends_on, status, closed_at)
    select ra.tenant_id, v_ledger, format('%s-%s', y.fy, lpad(m.n::text, 2, '0')), y.fy, m.n::smallint,
           make_date(y.fy, m.n, 1), (make_date(y.fy, m.n, 1) + interval '1 month - 1 day')::date,
           (case when y.fy = v_year - 1 and m.n <> 11 then 'closed'
                 when y.fy = v_year and m.n = v_closed_no then 'closed'
                 else 'open' end)::erp.period_status,
           case when (y.fy = v_year - 1 and m.n <> 11) or (y.fy = v_year and m.n = v_closed_no)
                then clock_timestamp() - interval '1 day' end
      from (values (v_year - 1), (v_year)) as y(fy)
     cross join generate_series(1, 12) as m(n);
    select fp.id into v_p_now from erp.fiscal_period fp
     where fp.tenant_id = ra.tenant_id and fp.ledger_id = v_ledger and fp.fiscal_year = v_year and fp.period_number = v_month;
    select fp.id into v_p_closed from erp.fiscal_period fp
     where fp.tenant_id = ra.tenant_id and fp.ledger_id = v_ledger and fp.fiscal_year = v_year and fp.period_number = v_closed_no;
    select fp.id into v_p_close from erp.fiscal_period fp
     where fp.tenant_id = ra.tenant_id and fp.ledger_id = v_ledger and fp.fiscal_year = v_year and fp.period_number = v_close_no;
    select fp.id, fp.code into v_p_prior_last, v_prior_last_code from erp.fiscal_period fp
     where fp.tenant_id = ra.tenant_id and fp.ledger_id = v_ledger and fp.fiscal_year = v_year - 1 and fp.period_number = 12;
    select fp.id into v_p_prior_mid from erp.fiscal_period fp
     where fp.tenant_id = ra.tenant_id and fp.ledger_id = v_ledger and fp.fiscal_year = v_year - 1 and fp.period_number = 5;
    select fp.id, fp.code into v_p_prior_open, v_prior_open_code from erp.fiscal_period fp
     where fp.tenant_id = ra.tenant_id and fp.ledger_id = v_ledger and fp.fiscal_year = v_year - 1 and fp.period_number = 11;

    insert into erp.account (tenant_id, entity_id, code, name, account_type, control_kind, is_postable, currency, status) values
      (ra.tenant_id, ra.entity_id, 'ZZ7100', 'Suite light and heat',       'expense',   null,         true, 'GBP', 'active'),
      (ra.tenant_id, ra.entity_id, 'ZZ2300', 'Suite accruals',             'liability', null,         true, 'GBP', 'active'),
      (ra.tenant_id, ra.entity_id, 'ZZ7900', 'Suite retired expenses',     'expense',   null,         true, 'GBP', 'inactive'),
      (ra.tenant_id, ra.entity_id, 'ZZ1100', 'Suite trade receivables',    'asset',     'receivable', true, 'GBP', 'active');
    select a.id into v_exp from erp.account a where a.tenant_id = ra.tenant_id and a.code = 'ZZ7100';
    select a.id into v_acc from erp.account a where a.tenant_id = ra.tenant_id and a.code = 'ZZ2300';
    select a.id into v_old from erp.account a where a.tenant_id = ra.tenant_id and a.code = 'ZZ7900';
    select a.id into v_rec from erp.account a where a.tenant_id = ra.tenant_id and a.code = 'ZZ1100';

    insert into erp.close_task_template (tenant_id, code, name, seq, depends_on, blocking_check, status) values
      (ra.tenant_id, 'zz_bank',   'Suite bank reconciled',   10, '{}'::text[],          null, 'active'),
      (ra.tenant_id, 'zz_review', 'Suite journals reviewed', 20, array['zz_bank']::text[], null, 'active');
    perform erp_test.close_bootstrap_window(ra.tenant_id);

    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', v_exp, 'debit_minor', 12500,
                         'description', 'September electricity, estimated', 'dimensions', jsonb_build_object()),
      jsonb_build_object('account_id', v_acc, 'credit_minor', 12500));
    v_small := jsonb_build_array(
      jsonb_build_object('account_id', v_exp, 'debit_minor', 5000),
      jsonb_build_object('account_id', v_acc, 'credit_minor', 5000));
    v_unbalanced := jsonb_build_array(
      jsonb_build_object('account_id', v_exp, 'debit_minor', 12500),
      jsonb_build_object('account_id', v_acc, 'credit_minor', 12000));

    v_step := 'the finance people join and the first administrator gives them their roles';
    select i.app_user_id, i.token into u_clerk, t_tok
      from erp.invite_principal('clerk@zzjnla-' || v_tag || '.test', 'Cara Clerk') i;
    perform erp.grant_role(u_clerk, 'zz_finance_clerk', null, null, 'raises journals');
    perform set_config('request.jwt.claims', json_build_object('sub', s_clerk)::text, true);
    perform erp.claim_invitation(t_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    select i.app_user_id, i.token into u_manager, t_tok
      from erp.invite_principal('manager@zzjnla-' || v_tag || '.test', 'Mo Manager') i;
    perform erp.grant_role(u_manager, 'zz_finance_manager', null, null, 'approves journals and closes periods');
    perform set_config('request.jwt.claims', json_build_object('sub', s_manager)::text, true);
    perform erp.claim_invitation(t_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    select i.app_user_id, i.token into u_viewer, t_tok
      from erp.invite_principal('viewer@zzjnla-' || v_tag || '.test', 'Val Viewer') i;
    perform erp.grant_role(u_viewer, 'zz_finance_viewer', null, null, 'reads the ledger');
    perform set_config('request.jwt.claims', json_build_object('sub', s_viewer)::text, true);
    perform erp.claim_invitation(t_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);

    ok_roles := erp.tenant_is_live(ra.tenant_id)
      and erp.has_permission('finance.post', null, null, null, u_clerk)
      and not erp.has_permission('finance.close_period', null, null, null, u_clerk)
      and erp.has_permission('document.issue', null, null, null, u_clerk)
      and erp.has_permission('finance.close_period', null, null, null, u_manager)
      and not erp.has_permission('finance.post', null, null, null, u_manager)
      and not exists (select 1 from erp.duty_conflicts(ra.tenant_id, null) dc
                       where dc.app_user_id in (u_clerk, u_manager, u_viewer))
      and (select count(*) from erp.sod_rule sr where sr.tenant_id = ra.tenant_id and sr.status = 'active')
          = (select count(*) from erp_ref.pack_item pi where pi.pack_code = 'base' and pi.object_kind = 'sod_rule');
    msg_roles := format('conflicts for the finance people: %s',
                        coalesce((select string_agg(dc.rule_code, ', ') from erp.duty_conflicts(ra.tenant_id, null) dc
                                   where dc.app_user_id in (u_clerk, u_manager, u_viewer)), 'none'));

    -- ── A balanced journal, raised by one and posted by another ──────────
    v_step := 'the clerk raises a balanced journal and submits it';
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'reference', 'ACC-ELEC',
      'narrative', 'Accrue this month''s electricity', 'lines', v_lines));
    v_j1 := (d.outcome ->> 'journal_id')::uuid;
    ok_post := coalesce(d.err_state is null and d.outcome ->> 'state' = 'draft'
                        and (d.outcome ->> 'lines')::integer = 2, false);
    msg_post := 'raise: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_submit_journal', jsonb_build_object('journal_id', v_j1));
    ok_post := ok_post and coalesce(d.err_state is null and d.outcome ->> 'state' = 'submitted', false);
    msg_post := msg_post || '; submit: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    v_step := 'the manager approves and posts it';
    select * into d from erp_test.journal_door_as(s_manager, 'erp_approve_journal', jsonb_build_object('journal_id', v_j1));
    ok_post := ok_post and coalesce(
      d.err_state is null
      and d.outcome ->> 'state' = 'posted'
      and exists (select 1 from erp.journal j
                   where j.id = v_j1 and j.tenant_id = ra.tenant_id and j.status = 'posted'
                     and j.source_code = 'manual' and j.posted_by = u_manager and j.prepared_by = u_clerk
                     and j.submitted_by = u_clerk and j.created_by = u_clerk
                     and j.fiscal_period_id = v_p_now and j.ledger_id = v_ledger
                     and j.reference = 'ACC-ELEC' and j.manual_reason = 'Accrue this month''s electricity')
      and (select count(*) from erp.journal_line l where l.journal_id = v_j1) = 2
      and exists (select 1 from erp.journal_line l
                   where l.journal_id = v_j1 and l.account_id = v_exp and l.debit_minor = 12500
                     and l.base_debit_minor = 12500 and l.currency = 'GBP' and l.dimensions = '{}'::jsonb
                     and l.description = 'September electricity, estimated')
      and exists (select 1 from erp.journal_line l
                   where l.journal_id = v_j1 and l.account_id = v_acc and l.credit_minor = 12500
                     and l.description = 'Accrue this month''s electricity')
      and (select sum(ab.balance_minor) from erp.account_balance ab
            where ab.tenant_id = ra.tenant_id and ab.account_id = v_exp) = 12500
      and (select sum(ab.balance_minor) from erp.account_balance ab
            where ab.tenant_id = ra.tenant_id and ab.account_id = v_acc) = -12500, false);
    msg_post := msg_post || '; approve: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select j.xmin::text into v_j1_xmin from erp.journal j where j.id = v_j1;
    select jsonb_agg(to_jsonb(l) order by l.line_no) into v_j1_lines from erp.journal_line l where l.journal_id = v_j1;

    -- ── An unbalanced journal ────────────────────────────────────────────
    v_step := 'the clerk raises and submits an unbalanced journal in one press, then saves one as a draft and submits it';
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'Lopsided in one press',
      'lines', v_unbalanced, 'submit', true));
    ok_unbal := coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_NOT_BALANCED%'
      and d.err_message like '%GBP 125.00%' and d.err_message like '%GBP 120.00%'
      and d.err_hint like '%GBP 5.00%'
      and not exists (select 1 from erp.journal j where j.tenant_id = ra.tenant_id and j.description = 'Lopsided in one press'), false);
    msg_unbal := 'in one press: ' || coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'Lopsided draft', 'lines', v_unbalanced));
    v_j2 := (d.outcome ->> 'journal_id')::uuid;
    ok_unbal := ok_unbal and coalesce(d.err_state is null and d.outcome ->> 'state' = 'draft', false);
    msg_unbal := msg_unbal || '; as a draft: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_submit_journal', jsonb_build_object('journal_id', v_j2));
    ok_unbal := ok_unbal and coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_NOT_BALANCED%'
      and exists (select 1 from erp.journal j where j.id = v_j2 and j.status = 'draft' and j.submitted_at is null), false);
    msg_unbal := msg_unbal || '; submitted: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'One-sided',
      'lines', jsonb_build_array(jsonb_build_object('account_id', v_exp, 'debit_minor', 100, 'credit_minor', 100))));
    ok_unbal := ok_unbal and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_INCOMPLETE: line 1 %', false);
    msg_unbal := msg_unbal || '; both sides on one line: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── Closed periods ───────────────────────────────────────────────────
    v_step := 'the clerk raises a journal into a closed period, and the manager approves one whose period closed after it was submitted';
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', make_date(v_year, v_closed_no, 15),
      'narrative', 'Into a closed period', 'lines', v_small));
    ok_closed := coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_PERIOD_CLOSED%'
      and d.err_message like ('%' || format('%s-%s', v_year, lpad(v_closed_no::text, 2, '0')) || '%')
      and d.err_hint like '%reopen%'
      and not exists (select 1 from erp.journal j where j.tenant_id = ra.tenant_id and j.description = 'Into a closed period'), false);
    msg_closed := 'raise: ' || coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', make_date(v_year, v_close_no, 10),
      'narrative', 'Submitted before the close', 'lines', v_small, 'submit', true));
    v_j3 := (d.outcome ->> 'journal_id')::uuid;
    update erp.fiscal_period set status = 'closed', closed_at = clock_timestamp() where id = v_p_close;
    select * into d from erp_test.journal_door_as(s_manager, 'erp_approve_journal', jsonb_build_object('journal_id', v_j3));
    ok_closed := ok_closed and v_j3 is not null and coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_PERIOD_CLOSED%'
      and exists (select 1 from erp.journal j where j.id = v_j3 and j.status = 'draft' and j.submitted_at is not null), false);
    msg_closed := msg_closed || '; approve: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    update erp.fiscal_period set status = 'open', closed_at = null where id = v_p_close;
    select * into d from erp_test.journal_door_as(s_manager, 'erp_return_journal', jsonb_build_object(
      'journal_id', v_j3, 'note', 'Not needed after all'));
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_discard_journal', jsonb_build_object('journal_id', v_j3));
    ok_closed := ok_closed and coalesce(d.err_state is null and not exists (select 1 from erp.journal j where j.id = v_j3), false);
    msg_closed := msg_closed || '; tidied: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── Accounts ─────────────────────────────────────────────────────────
    v_step := 'the clerk posts to an account out of use, to receivables, and to another company''s account';
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'To a retired account',
      'lines', jsonb_build_array(jsonb_build_object('account_id', v_old, 'debit_minor', 5000),
                                 jsonb_build_object('account_id', v_acc, 'credit_minor', 5000))));
    ok_account := coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_ACCOUNT_INACTIVE: line 1 %ZZ7900%'
                           and d.err_hint like '%ZZ7900%', false);
    msg_account := 'retired: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'To receivables',
      'lines', jsonb_build_array(jsonb_build_object('account_id', v_acc, 'debit_minor', 5000),
                                 jsonb_build_object('account_id', v_rec, 'credit_minor', 5000))));
    ok_account := ok_account and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_CONTROL_ACCOUNT: line 2 %ZZ1100%'
                                          and d.err_hint like '%sales ledger%', false);
    msg_account := msg_account || '; receivables: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'To nobody''s account',
      'lines', jsonb_build_array(jsonb_build_object('account_id', gen_random_uuid(), 'debit_minor', 5000),
                                 jsonb_build_object('account_id', v_acc, 'credit_minor', 5000))));
    ok_account := ok_account
      and coalesce(d.err_state = '23503' and d.err_message like 'CLOVEERP_JOURNAL_ACCOUNT_UNKNOWN: line 1 %', false)
      and not exists (select 1 from erp.journal j where j.tenant_id = ra.tenant_id
                       and j.description in ('To a retired account', 'To receivables', 'To nobody''s account'));
    msg_account := msg_account || '; unknown: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── Maker and checker, live ──────────────────────────────────────────
    v_step := 'the administrator raises and submits a journal, reads the list, and approves it; then the manager does';
    select * into d from erp_test.journal_door_as(s_admin, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'Raised by the administrator',
      'lines', v_small, 'submit', true));
    v_j4 := (d.outcome ->> 'journal_id')::uuid;
    select * into d from erp_test.journal_door_as(s_admin, 'erp_journals', jsonb_build_object('state', 'submitted'));
    ok_self := v_j4 is not null and coalesce(
      d.err_state is null
      and exists (select 1 from jsonb_array_elements(d.outcome) x(el)
                   where x.el ->> 'journal_id' = v_j4::text and x.el ->> 'state' = 'submitted'
                     and (x.el -> 'you_raised') = 'true'::jsonb and (x.el -> 'you_may_approve') = 'false'::jsonb)
      and not exists (select 1 from jsonb_array_elements(d.outcome) x(el) where x.el ->> 'state' <> 'submitted'), false);
    msg_self := 'list: ' || left(coalesce(d.err_message, d.outcome::text, 'no answer'), 300);
    select * into d from erp_test.journal_door_as(s_admin, 'erp_approve_journal', jsonb_build_object('journal_id', v_j4));
    ok_self := ok_self and coalesce(
      d.err_state = '42501' and d.err_message like 'CLOVEERP_JOURNAL_SELF_APPROVAL%' and d.err_hint <> ''
      and exists (select 1 from erp.journal j where j.id = v_j4 and j.status = 'draft' and j.submitted_at is not null), false);
    msg_self := msg_self || '; the administrator approves: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_approve_journal', jsonb_build_object('journal_id', v_j4));
    ok_self := ok_self and coalesce(
      d.err_state is null
      and exists (select 1 from erp.journal j where j.id = v_j4 and j.status = 'posted'
                   and j.posted_by = u_manager and j.prepared_by = u_admin), false);
    msg_self := msg_self || '; the manager approves: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── Sent back, changed, submitted again; discarded ───────────────────
    v_step := 'the manager sends a journal back, the clerk changes and submits it, and a draft is discarded';
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'Prepaid insurance',
      'lines', v_small, 'submit', true));
    v_j5 := (d.outcome ->> 'journal_id')::uuid;
    select * into d from erp_test.journal_door_as(s_manager, 'erp_return_journal', jsonb_build_object(
      'journal_id', v_j5, 'note', '   '));
    ok_return := v_j5 is not null and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_RETURN_NEEDS_NOTE%', false);
    msg_return := 'no note: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_return_journal', jsonb_build_object(
      'journal_id', v_j5, 'note', 'Twelve months, not six: halve the amount'));
    ok_return := ok_return and coalesce(
      d.err_state is null and d.outcome ->> 'state' = 'returned'
      and exists (select 1 from erp.journal j where j.id = v_j5 and j.status = 'draft' and j.submitted_at is null
                   and j.submitted_by is null and j.returned_by = u_manager
                   and j.return_note = 'Twelve months, not six: halve the amount'), false);
    msg_return := msg_return || '; with a note: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'journal_id', v_j5, 'entity_id', ra.entity_id, 'posting_date', current_date,
      'narrative', 'Prepaid insurance, twelve months', 'reference', 'INS-12',
      'lines', jsonb_build_array(jsonb_build_object('account_id', v_exp, 'debit_minor', 2500),
                                 jsonb_build_object('account_id', v_acc, 'credit_minor', 2500)),
      'submit', true));
    ok_return := ok_return and coalesce(
      d.err_state is null and d.outcome ->> 'state' = 'submitted' and (d.outcome ->> 'journal_id')::uuid = v_j5
      and (d.outcome ->> 'debit_minor')::bigint = 2500
      and (select count(*) from erp.journal_line l where l.journal_id = v_j5) = 2
      and exists (select 1 from erp.journal j where j.id = v_j5 and j.reference = 'INS-12'
                   and j.description = 'Prepaid insurance, twelve months' and j.submitted_by = u_clerk), false);
    msg_return := msg_return || '; changed and submitted: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_discard_journal', jsonb_build_object('journal_id', v_j5));
    ok_return := ok_return and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_WRONG_STATE%waiting for approval%', false);
    msg_return := msg_return || '; discard while waiting: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_discard_journal', jsonb_build_object('journal_id', v_j2));
    ok_return := ok_return and coalesce(
      d.err_state is null and (d.outcome -> 'discarded') = 'true'::jsonb
      and not exists (select 1 from erp.journal j where j.id = v_j2)
      and not exists (select 1 from erp.journal_line l where l.journal_id = v_j2), false);
    msg_return := msg_return || '; discard a draft: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_approve_journal', jsonb_build_object('journal_id', v_j5));
    ok_return := ok_return and coalesce(d.err_state is null and d.outcome ->> 'state' = 'posted', false);
    msg_return := msg_return || '; approved: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── Reversal ─────────────────────────────────────────────────────────
    v_step := 'the clerk reverses the posted journal and the manager approves the reversal';
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_reverse_journal', jsonb_build_object('journal_id', v_j1));
    ok_reverse := coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_INCOMPLETE: a reversal needs its reason%', false);
    msg_reverse := 'no reason: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_reverse_journal', jsonb_build_object(
      'journal_id', v_j1, 'reason', 'Accrued twice: the bill arrived', 'posting_date', current_date));
    v_rev := (d.outcome ->> 'journal_id')::uuid;
    ok_reverse := ok_reverse and coalesce(
      d.err_state is null and d.outcome ->> 'state' = 'submitted'
      and (d.outcome ->> 'reverses_journal_id')::uuid = v_j1
      and exists (select 1 from erp.journal j where j.id = v_rev and j.status = 'draft' and j.reverses_journal_id = v_j1
                   and j.source_code = 'manual' and j.manual_reason = 'Accrued twice: the bill arrived'
                   and j.prepared_by = u_clerk and j.submitted_by = u_clerk)
      and (select count(*) from erp.journal_line l where l.journal_id = v_rev) = 2
      and not exists (select 1 from erp.journal_line o join erp.journal_line r on r.line_no = o.line_no
                       where o.journal_id = v_j1 and r.journal_id = v_rev
                         and not (r.account_id = o.account_id and r.debit_minor = o.credit_minor
                                  and r.credit_minor = o.debit_minor)), false);
    msg_reverse := msg_reverse || '; reverse: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_reverse_journal', jsonb_build_object(
      'journal_id', v_j1, 'reason', 'Once more'));
    ok_reverse := ok_reverse and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_NOT_REVERSIBLE%waiting for approval%', false);
    msg_reverse := msg_reverse || '; again while waiting: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_approve_journal', jsonb_build_object('journal_id', v_rev));
    ok_reverse := ok_reverse and coalesce(
      d.err_state is null and d.outcome ->> 'state' = 'posted'
      and erp.journal_state(v_j1) = 'reversed'
      and (select coalesce(sum(l.debit_minor - l.credit_minor), 0) from erp.journal_line l
            where l.journal_id in (v_j1, v_rev) and l.account_id = v_exp) = 0
      and (select coalesce(sum(l.debit_minor - l.credit_minor), 0) from erp.journal_line l
            where l.journal_id in (v_j1, v_rev) and l.account_id = v_acc) = 0
      and (select sum(ab.balance_minor) from erp.account_balance ab
            where ab.tenant_id = ra.tenant_id and ab.account_id = v_exp) = 5000 + 2500
      and (select j.xmin::text from erp.journal j where j.id = v_j1) = v_j1_xmin
      and exists (select 1 from erp.journal j where j.id = v_j1 and j.status = 'posted')
      and (select jsonb_agg(to_jsonb(l) order by l.line_no) from erp.journal_line l where l.journal_id = v_j1) = v_j1_lines, false);
    msg_reverse := msg_reverse || '; approved: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_reverse_journal', jsonb_build_object(
      'journal_id', v_j1, 'reason', 'Once more'));
    ok_reverse := ok_reverse and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_NOT_REVERSIBLE%already has a reversal, posted%', false);
    msg_reverse := msg_reverse || '; again: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_reverse_journal', jsonb_build_object(
      'journal_id', v_rev, 'reason', 'Reversing the reversal'));
    ok_reverse := ok_reverse and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_NOT_REVERSIBLE%itself a reversal%', false);
    msg_reverse := msg_reverse || '; the reversal: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── Signed in, each person meets their own permissions ───────────────
    v_step := 'each person tries the doors their role does not give them, and the viewer reads the list';
    select * into d from erp_test.journal_door_as(s_manager, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'The manager types one', 'lines', v_small));
    ok_signed := coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: finance.post%', false);
    msg_signed := 'manager raises: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', current_date, 'narrative', 'The clerk approves one',
      'lines', v_small, 'submit', true));
    v_j6 := (d.outcome ->> 'journal_id')::uuid;
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_approve_journal', jsonb_build_object('journal_id', v_j6));
    ok_signed := ok_signed and v_j6 is not null
      and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%', false);
    msg_signed := msg_signed || '; clerk approves: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_return_journal', jsonb_build_object(
      'journal_id', v_j6, 'note', 'Sending my own back'));
    ok_signed := ok_signed and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%', false);
    msg_signed := msg_signed || '; clerk sends back: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_viewer, 'erp_reverse_journal', jsonb_build_object(
      'journal_id', v_j4, 'reason', 'The viewer reverses one'));
    ok_signed := ok_signed and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: finance.post%', false);
    msg_signed := msg_signed || '; viewer reverses: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_viewer, 'erp_journals', '{}'::jsonb);
    v_list := d.outcome;
    ok_signed := ok_signed and coalesce(
      d.err_state is null
      and exists (select 1 from jsonb_array_elements(v_list) x(el)
                   where x.el ->> 'journal_id' = v_j1::text and x.el ->> 'state' = 'reversed'
                     and x.el ->> 'raised_by' = 'Cara Clerk' and x.el ->> 'posted_by' = 'Mo Manager'
                     and x.el ->> 'company' is not null and x.el ->> 'ledger' = 'GL'
                     and (x.el ->> 'debit_minor')::bigint = 12500 and (x.el ->> 'credit_minor')::bigint = 12500
                     and x.el -> 'reversal' ->> 'journal_id' = v_rev::text
                     and x.el -> 'reversal' ->> 'state' = 'posted'
                     and jsonb_array_length(x.el -> 'lines') = 2
                     and (x.el -> 'you_raised') = 'false'::jsonb)
      and exists (select 1 from jsonb_array_elements(v_list) x(el)
                   where x.el ->> 'journal_id' = v_rev::text and x.el ->> 'state' = 'posted'
                     and x.el ->> 'reverses_journal_id' = v_j1::text)
      and exists (select 1 from jsonb_array_elements(v_list) x(el)
                   where x.el ->> 'journal_id' = v_j6::text and x.el ->> 'state' = 'submitted'
                     and (x.el -> 'you_may_approve') = 'true'::jsonb), false);
    msg_signed := msg_signed || '; viewer lists: ' || left(coalesce(d.err_message, v_list::text, 'no answer'), 300);
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_close_fiscal_year', jsonb_build_object('fiscal_period_id', v_p_prior_last));
    ok_signed := ok_signed and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%', false);
    msg_signed := msg_signed || '; clerk closes the year: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── Closing a period ─────────────────────────────────────────────────
    v_step := 'the manager closes a period that has no close tasks';
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_period', jsonb_build_object('fiscal_period_id', v_p_close));
    ok_notasks := coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_CLOSE_NO_TASKS%'
      and d.err_hint like '%Open a period close%'
      and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p_close) = 'open', false);
    msg_notasks := coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');

    v_step := 'the manager opens the period close and closes with its tasks open';
    select * into d from erp_test.journal_door_as(s_manager, 'erp_open_period_close', jsonb_build_object('fiscal_period_id', v_p_close));
    ok_open := coalesce(d.err_state is null and (d.outcome #>> '{}')::integer = 2
                        and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p_close) = 'closing', false);
    msg_open := 'open the close: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select t.id into v_task_bank from erp.close_task t where t.fiscal_period_id = v_p_close and t.code = 'zz_bank';
    select t.id into v_task_review from erp.close_task t where t.fiscal_period_id = v_p_close and t.code = 'zz_review';
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_period', jsonb_build_object('fiscal_period_id', v_p_close));
    ok_open := ok_open and coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_CLOSE_TASKS_OPEN%Suite bank reconciled, Suite journals reviewed%'
      and d.err_hint like '%Suite bank reconciled%', false);
    msg_open := msg_open || '; close: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_complete_close_task', jsonb_build_object('task_id', v_task_bank));
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_period', jsonb_build_object('fiscal_period_id', v_p_close));
    ok_open := ok_open and coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_CLOSE_TASKS_OPEN%'
      and d.err_message like '%Suite journals reviewed' and d.err_message not like '%Suite bank reconciled%'
      and (select fp.status::text from erp.fiscal_period fp where fp.id = v_p_close) = 'closing', false);
    msg_open := msg_open || '; one done, close: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    v_step := 'the last task is waived, the period closes, is reopened, and closes again';
    select * into d from erp_test.journal_door_as(s_manager, 'erp_complete_close_task', jsonb_build_object(
      'task_id', v_task_review, 'waiver_reason', 'Reviewed with the journals list instead'));
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_period', jsonb_build_object('fiscal_period_id', v_p_close));
    ok_closes := coalesce(
      d.err_state is null
      and exists (select 1 from erp.fiscal_period fp where fp.id = v_p_close and fp.status = 'closed'
                   and fp.closed_by = u_manager and fp.closed_at is not null)
      and exists (select 1 from erp.close_task t where t.id = v_task_review and t.status = 'waived'), false);
    msg_closes := 'close: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', make_date(v_year, v_close_no, 20),
      'narrative', 'After the close', 'lines', v_small));
    ok_closes := ok_closes and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_PERIOD_CLOSED%', false);
    msg_closes := msg_closes || '; raise into it: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_admin, 'erp_reopen_period', jsonb_build_object(
      'fiscal_period_id', v_p_close, 'reason', 'A late supplier credit'));
    ok_closes := ok_closes and coalesce(d.err_state is null, false);
    msg_closes := msg_closes || '; reopen: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', make_date(v_year, v_close_no, 20),
      'narrative', 'While reopened', 'lines', v_small));
    v_j6 := (d.outcome ->> 'journal_id')::uuid;
    ok_closes := ok_closes and coalesce(d.err_state is null and d.outcome ->> 'state' = 'draft', false);
    msg_closes := msg_closes || '; raise while reopened: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_period', jsonb_build_object('fiscal_period_id', v_p_close));
    ok_closes := ok_closes and coalesce(d.err_state is null, false);
    msg_closes := msg_closes || '; close again: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_submit_journal', jsonb_build_object('journal_id', v_j6));
    ok_closes := ok_closes and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_PERIOD_CLOSED%', false);
    msg_closes := msg_closes || '; submit after it closed again: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    -- The ledger's own guard, below every door.
    begin
      update erp.journal set status = 'posted', posted_at = now() where id = v_j6;
      v_fixture := 'posted';
    exception when others then
      v_fixture := sqlerrm;
    end;
    ok_closes := ok_closes and coalesce(v_fixture like 'CLOVEERP_PERIOD_CLOSED%', false);
    msg_closes := msg_closes || '; the ledger''s guard: ' || coalesce(v_fixture, 'no answer');

    -- ── Year end ─────────────────────────────────────────────────────────
    v_step := 'the manager closes last year from a middle period, then with a period open, then as it should be';
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_fiscal_year', jsonb_build_object('fiscal_period_id', v_p_prior_mid));
    ok_yearend := coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_YEAR_END_NOT_LAST_PERIOD%'
                           and d.err_hint like ('%' || v_prior_last_code || '%'), false);
    msg_yearend := 'a middle period: ' || coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_fiscal_year', jsonb_build_object('fiscal_period_id', v_p_prior_last));
    ok_yearend := ok_yearend and coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_YEAR_END_PERIODS_OPEN%'
      and d.err_message like ('%' || v_prior_open_code)
      and not exists (select 1 from erp.fiscal_period fp where fp.ledger_id = v_ledger and fp.status = 'permanently_closed'), false);
    msg_yearend := msg_yearend || '; a period open: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    update erp.fiscal_period set status = 'closed', closed_at = clock_timestamp() where id = v_p_prior_open;
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_fiscal_year', jsonb_build_object('fiscal_period_id', v_p_prior_last));
    ok_yearend := ok_yearend and coalesce(
      d.err_state is null and (d.outcome ->> 'periods')::integer = 12 and (d.outcome ->> 'fiscal_year')::integer = v_year - 1
      and (select count(*) from erp.fiscal_period fp
            where fp.ledger_id = v_ledger and fp.fiscal_year = v_year - 1 and fp.status = 'permanently_closed') = 12
      and not exists (select 1 from erp.fiscal_period fp
                       where fp.ledger_id = v_ledger and fp.fiscal_year = v_year and fp.status = 'permanently_closed'), false);
    msg_yearend := msg_yearend || '; closed: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_clerk, 'erp_raise_journal', jsonb_build_object(
      'entity_id', ra.entity_id, 'posting_date', make_date(v_year - 1, 6, 30),
      'narrative', 'Into last year', 'lines', v_small));
    ok_yearend := ok_yearend and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_JOURNAL_PERIOD_CLOSED%closed for good%', false);
    msg_yearend := msg_yearend || '; raise into it: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_admin, 'erp_reopen_period', jsonb_build_object(
      'fiscal_period_id', v_p_prior_mid, 'reason', 'A correction to last year'));
    ok_yearend := ok_yearend and coalesce(
      d.err_state = '23514' and d.err_message like 'CLOVEERP_PERIOD_PERMANENTLY_CLOSED%'
      and not exists (select 1 from erp.period_reopening r where r.fiscal_period_id = v_p_prior_mid), false);
    msg_yearend := msg_yearend || '; reopen: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_period', jsonb_build_object('fiscal_period_id', v_p_prior_last));
    ok_yearend := ok_yearend and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_PERIOD_PERMANENTLY_CLOSED%', false);
    msg_yearend := msg_yearend || '; close a period of it: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_manager, 'erp_close_fiscal_year', jsonb_build_object('fiscal_period_id', v_p_prior_last));
    ok_yearend := ok_yearend and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_PERIOD_PERMANENTLY_CLOSED%', false);
    msg_yearend := msg_yearend || '; close it again: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_JOURNAL_SUITE_A_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_JOURNAL_SUITE_A_UNDO' then
      v_state_a := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Organisation B, not yet live
  -- ───────────────────────────────────────────────────────────────────────────
  begin
    v_step := 'organisation B is provisioned and opened for setting up';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('zzjnlb-' || v_tag, 'Journal Suite B',
                                               'admin@zzjnlb-' || v_tag || '.test', 'Setup Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', s_badmin)::text, true);
    u_badmin := erp.claim_invitation(rb.admin_token);

    v_step := 'a general ledger with this month open and two accounts';
    insert into erp.ledger (tenant_id, entity_id, code, name, ledger_kind, currency, is_primary, status)
    values (rb.tenant_id, rb.entity_id, 'GL', 'General ledger', 'statutory', 'GBP', true, 'active')
    returning id into v_bledger;
    insert into erp.fiscal_period (tenant_id, ledger_id, code, fiscal_year, period_number, starts_on, ends_on, status)
    values (rb.tenant_id, v_bledger, format('%s-%s', v_year, lpad(v_month::text, 2, '0')), v_year, v_month::smallint,
            date_trunc('month', current_date)::date,
            (date_trunc('month', current_date) + interval '1 month - 1 day')::date, 'open');
    insert into erp.account (tenant_id, entity_id, code, name, account_type, is_postable, currency, status) values
      (rb.tenant_id, rb.entity_id, 'ZZ7100', 'Setup light and heat', 'expense',   true, 'GBP', 'active'),
      (rb.tenant_id, rb.entity_id, 'ZZ2300', 'Setup accruals',       'liability', true, 'GBP', 'active');
    select a.id into v_bexp from erp.account a where a.tenant_id = rb.tenant_id and a.code = 'ZZ7100';
    select a.id into v_bacc from erp.account a where a.tenant_id = rb.tenant_id and a.code = 'ZZ2300';

    v_step := 'before go-live, the administrator raises, submits and approves their own journal';
    select * into d from erp_test.journal_door_as(s_badmin, 'erp_raise_journal', jsonb_build_object(
      'entity_id', rb.entity_id, 'posting_date', current_date, 'narrative', 'Opening accrual while setting up',
      'lines', jsonb_build_array(jsonb_build_object('account_id', v_bexp, 'debit_minor', 9900),
                                 jsonb_build_object('account_id', v_bacc, 'credit_minor', 9900)),
      'submit', true));
    v_bj := (d.outcome ->> 'journal_id')::uuid;
    msg_prelive := 'raise: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.journal_door_as(s_badmin, 'erp_approve_journal', jsonb_build_object('journal_id', v_bj));
    ok_prelive := v_bj is not null and not erp.tenant_is_live(rb.tenant_id) and coalesce(
      d.err_state is null and d.outcome ->> 'state' = 'posted'
      and exists (select 1 from erp.journal j where j.id = v_bj and j.status = 'posted'
                   and j.posted_by = u_badmin and j.prepared_by = u_badmin and j.submitted_by = u_badmin), false);
    msg_prelive := msg_prelive || '; approve: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_JOURNAL_SUITE_B_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_JOURNAL_SUITE_B_UNDO' then
      v_state_b := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── The verdicts ─────────────────────────────────────────────────────────

  case_name := 'the journal doors and the year-end door are one function each, run as the caller, volatile, and executable when signed in only';
  passed := v_doors_bad is null;
  detail := coalesce(v_doors_bad, 'eight doors as expected');
  return next;

  case_name := 'the finance clerk and sales administrator templates issue and reprint, the manager approves and does not post, no template holds a prohibited pairing, and people given those roles in a live organisation meet no rule';
  passed := v_state_a is null and coalesce(
            v_fc @> array['finance.post', 'document.issue', 'document.reprint']
            and not (v_fc && array['finance.close_period'])
            and v_sa @> array['sales.invoice', 'document.issue', 'document.reprint']
            and v_fm @> array['finance.read', 'finance.close_period'] and not (v_fm @> array['finance.post'])
            and v_breaks is null
            and ok_roles, false);
  detail := coalesce(v_state_a, v_breaks, msg_roles, 'no answer')
            || format('; finance clerk: %s; sales administrator: %s; finance manager: %s',
                      array_to_string(v_fc, ', '), array_to_string(v_sa, ', '), array_to_string(v_fm, ', '));
  return next;

  case_name := 'in a live organisation a balanced journal raised and submitted by the clerk is approved and posted by the manager, with its lines in the ledger';
  passed := v_state_a is null and coalesce(ok_post, false);
  detail := coalesce(v_state_a, msg_post, 'no answer');
  return next;

  case_name := 'an unbalanced journal is refused by name at submission, in one press or from a draft, and a line with both sides is refused';
  passed := v_state_a is null and coalesce(ok_unbal, false);
  detail := coalesce(v_state_a, msg_unbal, 'no answer');
  return next;

  case_name := 'a journal dated in a closed period is refused when raised, and when approved after its period closed';
  passed := v_state_a is null and coalesce(ok_closed, false);
  detail := coalesce(v_state_a, msg_closed, 'no answer');
  return next;

  case_name := 'a line on an account out of use, on receivables, or on an account not in the company''s chart is refused by name';
  passed := v_state_a is null and coalesce(ok_account, false);
  detail := coalesce(v_state_a, msg_account, 'no answer');
  return next;

  case_name := 'once live, whoever raised and submitted a journal cannot approve it, the list says so, and a second person posts it';
  passed := v_state_a is null and coalesce(ok_self, false);
  detail := coalesce(v_state_a, msg_self, 'no answer');
  return next;

  case_name := 'before go-live, one person raises, submits, approves and posts their own journal';
  passed := v_state_b is null and coalesce(ok_prelive, false);
  detail := coalesce(v_state_b, msg_prelive, 'no answer');
  return next;

  case_name := 'a journal is sent back only with a note, is changed and submitted again, and only a draft is discarded';
  passed := v_state_a is null and coalesce(ok_return, false);
  detail := coalesce(v_state_a, msg_return, 'no answer');
  return next;

  case_name := 'reversing a posted journal raises its mirror for approval, never changes the original, nets to nothing once posted, and happens once';
  passed := v_state_a is null and coalesce(ok_reverse, false);
  detail := coalesce(v_state_a, msg_reverse, 'no answer');
  return next;

  case_name := 'signed in, the manager cannot raise, the clerk cannot approve, send back or close a year, the viewer cannot reverse, and the viewer reads journals by state with their lines';
  passed := v_state_a is null and coalesce(ok_signed, false);
  detail := coalesce(v_state_a, msg_signed, 'no answer');
  return next;

  case_name := 'a period with no close tasks is refused closing by name, with the way to open its close';
  passed := v_state_a is null and coalesce(ok_notasks, false);
  detail := coalesce(v_state_a, msg_notasks, 'no answer');
  return next;

  case_name := 'a period with close tasks open is refused closing, naming the tasks still open';
  passed := v_state_a is null and coalesce(ok_open, false);
  detail := coalesce(v_state_a, msg_open, 'no answer');
  return next;

  case_name := 'once its tasks are complete or waived the period closes; reopened it takes a journal, and closed again it takes none, at the door and in the ledger''s own guard';
  passed := v_state_a is null and coalesce(ok_closes, false);
  detail := coalesce(v_state_a, msg_closes, 'no answer');
  return next;

  case_name := 'year end is taken from the last period once every period is closed, and leaves the year permanently closed to postings, closing and reopening';
  passed := v_state_a is null and coalesce(ok_yearend, false);
  detail := coalesce(v_state_a, msg_yearend, 'no answer');
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in ('zzjnla-' || v_tag, 'zzjnlb-' || v_tag));
  detail := 'two organisations, their people, ledgers, periods, journals and close tasks rolled back';
  return next;
end;
$$;
revoke all on function erp_test.journal_and_close_suite() from public, anon, authenticated;

comment on function erp_test.journal_and_close_suite() is
  'Manual journals and period close through the doors as a signed-in caller: in a '
  'live organisation with the base pack''s rules, a clerk raises and a manager '
  'posts, unbalanced journals, closed periods and unusable accounts are refused, '
  'nobody approves their own, a journal is sent back, changed, discarded and '
  'reversed, and each person meets only their own permissions; a period does not '
  'close without its tasks, closes again after a reopening, and a year closes for '
  'good; before go-live one person may post their own. Rolls back everything it made.';

create or replace function erp_test.assert_journal_and_close_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 16;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.journal_and_close_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_JOURNAL_AND_CLOSE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_JOURNAL_AND_CLOSE_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case before the door: a journal or a close that should be refused went through, or one that should go through was refused.';
  end if;
  return format('journals and close: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;
revoke all on function erp_test.assert_journal_and_close_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_packs_installable();
select erp.assert_part5_coverage();
select erp.assert_guidance_sound();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_isolation();

select erp_test.assert_journal_and_close_suite();
select erp_test.assert_duties_separated_suite();
