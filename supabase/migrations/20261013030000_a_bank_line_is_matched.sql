-- A bank line is matched.
--
-- Bank reconciliation, pull request 3 of 5 (owner, 13 October 2026). A line of
-- an imported statement (20261013020000) is matched to what the books already
-- say went through that bank account: a receipt, a supplier payment, a payment
-- run. Nothing is posted here; a line the books do not yet carry is for bank
-- entries (pull request 4).
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.bank_match, erp.bank_match_line and erp.bank_match_item: one match
--      ties one or more statement lines to one or more bank items of the
--      ledger (erp.subledger_item, control kind bank) whose amounts agree to
--      the penny. A line and an item are each matched at most once.
--   B. erp.bank_book_entries: what the books hold for a bank account and no
--      line has matched yet, gathered as a person reads it — a receipt or a
--      payment whole, however many invoices or bills it paid, and a payment
--      run whole, as the bank shows one BACS line for it — with the numbers a
--      bank line may quote: the document's, the invoices' and bills' it paid,
--      the customer's and our references, the run's.
--   C. public.erp_auto_match_bank_statement, under finance.post, matches what
--      it is sure of, in three passes, each taking only a pairing that is the
--      one candidate on both sides:
--        reference    the same amount, within seven days, and the line quotes
--                     one of the entry's numbers;
--        payment_run  the same amount as a supplier payment or a whole run,
--                     within five days (BACS takes three working days);
--        amount_date  the same amount, within three days.
--      Two lines of one amount against two receipts of it are left for a
--      person.
--   D. public.erp_match_bank_lines matches lines to entries by hand, with a
--      note; public.erp_unmatch_bank_line undoes a match, with a reason; both
--      under finance.post and refused once the statement is reconciled.
--      public.erp_bank_match_candidates lists what a line could be matched to,
--      the same amount first; public.erp_bank_statement_lines says what each
--      matched line was matched to.
--   E. erp_test.bank_matching_suite proves C and D.

create table if not exists erp.bank_match (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  bank_account_id   uuid not null,
  method            text not null,
  note              text,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint bank_match_tenant_id_id_key unique (tenant_id, id),
  constraint bank_match_account_fk foreign key (tenant_id, bank_account_id) references erp.bank_account(tenant_id, id) on delete restrict,
  constraint bank_match_method_known check (method in ('reference', 'payment_run', 'amount_date', 'manual')),
  constraint bank_match_manual_noted check (method <> 'manual' or btrim(coalesce(note, '')) <> '')
);

create table if not exists erp.bank_match_line (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  match_id          uuid not null,
  line_id           uuid not null,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint bank_match_line_tenant_id_id_key unique (tenant_id, id),
  constraint bank_match_line_once unique (tenant_id, line_id),
  constraint bank_match_line_match_fk foreign key (tenant_id, match_id) references erp.bank_match(tenant_id, id) on delete cascade,
  constraint bank_match_line_line_fk foreign key (tenant_id, line_id) references erp.bank_statement_line(tenant_id, id) on delete restrict
);
create index if not exists bank_match_line_match on erp.bank_match_line (tenant_id, match_id);

create table if not exists erp.bank_match_item (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  match_id          uuid not null,
  subledger_item_id uuid not null references erp.subledger_item(id) on delete restrict,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint bank_match_item_tenant_id_id_key unique (tenant_id, id),
  constraint bank_match_item_once unique (tenant_id, subledger_item_id),
  constraint bank_match_item_match_fk foreign key (tenant_id, match_id) references erp.bank_match(tenant_id, id) on delete cascade
);
create index if not exists bank_match_item_match on erp.bank_match_item (tenant_id, match_id);

comment on table erp.bank_match is
  'A match of bank statement lines to the bank items of the ledger whose amounts agree (20261013030000): how it was '
  'made, and the note a person gave when they made it by hand.';
comment on table erp.bank_match_line is
  'A statement line of a bank match (20261013030000); a line is matched at most once.';
comment on table erp.bank_match_item is
  'A bank item of the ledger in a bank match (20261013030000); an item is matched at most once.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'bank_match', 'tenant_scoped', 'A match of bank statement lines to ledger bank items; undone with a reason until the statement is reconciled.'),
  ('erp', 'bank_match_line', 'tenant_scoped', 'A statement line of a bank match.'),
  ('erp', 'bank_match_item', 'tenant_scoped', 'A ledger bank item of a bank match.')
on conflict (schema_name, table_name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What the books hold
-- ─────────────────────────────────────────────────────────────────────────────

-- Words and numbers as a bank prints them: upper case, anything else a space.
create or replace function erp.bank_text_words(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$ select btrim(regexp_replace(upper(coalesce(p_text, '')), '[^A-Z0-9]+', ' ', 'g')) $$;
revoke all on function erp.bank_text_words(text) from public, anon;

-- Whether a bank line's words quote a number: as a word of its own, or, for a
-- number of six characters or more, run together the way a bank drops the
-- hyphen from INV-000412.
create or replace function erp.bank_text_quotes(p_text text, p_number text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select length(erp.bank_text_words(p_number)) >= 4
     and (position(' ' || erp.bank_text_words(p_number) || ' ' in ' ' || erp.bank_text_words(p_text) || ' ') > 0
          or (length(replace(erp.bank_text_words(p_number), ' ', '')) >= 6
              and position(replace(erp.bank_text_words(p_number), ' ', '') in replace(erp.bank_text_words(p_text), ' ', '')) > 0))
$$;
revoke all on function erp.bank_text_quotes(text, text) from public, anon;

create or replace function erp.bank_book_entries(p_bank_account_id uuid)
returns table(entry_key text, kind text, item_ids uuid[], amount_minor bigint, posted_on date,
              numbers text[], label text)
language sql
stable
set search_path = ''
as $$
  -- The bank items of the account's ledger account no line has matched, of
  -- posted journals not reversed (20261013030000). Money in is a debit of the
  -- bank, as it is a positive line of the bank's statement.
  with b as (
    select x.* from erp.bank_account x
     where x.tenant_id = erp.current_tenant_id() and x.id = p_bank_account_id
  ), items as (
    select s.id, s.debit_minor - s.credit_minor as net, s.posting_date, s.journal_id,
           j.document_id, j.description, j.reference as journal_reference,
           d.document_number, d.our_reference, d.their_reference, d.party_id,
           nullif(d.attributes ->> 'payment_proposal_id', '') as run_key
      from b
      join erp.subledger_item s
        on s.tenant_id = b.tenant_id and s.entity_id = b.entity_id and s.control_kind = 'bank'
       and s.control_account_id = b.account_id and s.currency = b.currency
      join erp.journal j on j.tenant_id = s.tenant_id and j.id = s.journal_id and j.status = 'posted'
                        and j.reverses_journal_id is null
      left join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
     where not exists (select 1 from erp.bank_match_item m where m.tenant_id = s.tenant_id and m.subledger_item_id = s.id)
       and not exists (select 1 from erp.journal r where r.tenant_id = j.tenant_id and r.reverses_journal_id = j.id)
  ), paid as (
    -- The invoices and bills each journal paid: the other side of its bank item.
    select o.journal_id, array_agg(distinct n) as numbers
      from (select distinct i.journal_id from items i) ij
      join erp.subledger_item o on o.tenant_id = erp.current_tenant_id() and o.journal_id = ij.journal_id
                               and o.control_kind <> 'bank'
      join erp.document pd on pd.tenant_id = o.tenant_id and pd.id = o.document_id
      cross join lateral unnest(array[pd.document_number, pd.their_reference, pd.our_reference]) n
     where n is not null
     group by o.journal_id
  ), entries as (
    select coalesce('document:' || i.document_id::text, 'journal:' || i.journal_id::text) as entry_key,
           case when i.run_key is not null then 'payment'
                when i.document_id is not null then 'document' else 'journal' end as kind,
           array_agg(i.id order by i.id) as item_ids,
           sum(i.net)::bigint as amount_minor,
           max(i.posting_date) as posted_on,
           array_remove(array_agg(distinct i.document_number) || array_agg(distinct i.our_reference)
                        || array_agg(distinct i.their_reference) || array_agg(distinct i.journal_reference), null)
             || coalesce((select array_agg(distinct pn) from paid p, unnest(p.numbers) pn
                           where p.journal_id = any (array_agg(i.journal_id))), '{}'::text[]) as numbers,
           max(i.party_id::text) as party_id,
           min(i.description) as description
      from items i
     group by 1, 2
    union all
    -- A run that paid more than one supplier, whole, as the bank shows it.
    select 'run:' || i.run_key, 'payment_run',
           array_agg(i.id order by i.id), sum(i.net)::bigint, max(i.posting_date),
           array_remove(array_agg(distinct i.document_number)
                        || array[(select pp.reference from erp.payment_proposal pp
                                   where pp.tenant_id = erp.current_tenant_id() and pp.id::text = i.run_key)], null),
           null, min(i.description)
      from items i
     where i.run_key is not null
     group by i.run_key
    having count(distinct i.document_id) > 1
  )
  select e.entry_key, e.kind, e.item_ids, e.amount_minor, e.posted_on, e.numbers,
         concat_ws(' · ', (select pt.name from erp.party pt
                            where pt.tenant_id = erp.current_tenant_id() and pt.id::text = e.party_id),
                   e.description)
    from entries e
   where e.amount_minor <> 0
$$;
revoke all on function erp.bank_book_entries(uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- C and D. Matching
-- ─────────────────────────────────────────────────────────────────────────────

-- One match, checked: the lines unmatched lines of one account's statements
-- not yet reconciled, the items unmatched bank items of that account's ledger
-- account, and the two adding to the same amount. The caller has authorised.
create or replace function erp.make_bank_match(p_bank_account_id uuid, p_line_ids uuid[], p_item_ids uuid[],
                                               p_method text, p_note text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.bank_account%rowtype;
  v_lines  bigint;
  v_items  bigint;
  v_id     uuid;
begin
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = p_bank_account_id;
  if b.id is null or coalesce(cardinality(p_line_ids), 0) = 0 or coalesce(cardinality(p_item_ids), 0) = 0
     or (select count(distinct l) from unnest(p_line_ids) l) <> cardinality(p_line_ids)
     or (select count(distinct i) from unnest(p_item_ids) i) <> cardinality(p_item_ids)
     or (select count(*) from erp.bank_statement_line l
           join erp.bank_statement s on s.tenant_id = l.tenant_id and s.id = l.statement_id
          where l.tenant_id = v_tenant and l.id = any (p_line_ids) and l.bank_account_id = b.id
            and l.status = 'unmatched' and s.status = 'imported') <> cardinality(p_line_ids)
     or (select count(*) from erp.subledger_item si
           join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id and j.status = 'posted'
          where si.tenant_id = v_tenant and si.id = any (p_item_ids) and si.control_kind = 'bank'
            and si.entity_id = b.entity_id and si.control_account_id = b.account_id and si.currency = b.currency
            and not exists (select 1 from erp.bank_match_item m where m.tenant_id = v_tenant and m.subledger_item_id = si.id))
        <> cardinality(p_item_ids) then
    raise exception 'CLOVEERP_BANK_MATCH_INVALID: only unmatched lines of this account''s statements, not yet reconciled, are matched, and only to unmatched bank items of its ledger account'
      using errcode = '23514', hint = 'Refresh the statement and choose again from what it offers.';
  end if;

  select sum(l.amount_minor) into v_lines from erp.bank_statement_line l
   where l.tenant_id = v_tenant and l.id = any (p_line_ids);
  select sum(si.debit_minor - si.credit_minor) into v_items from erp.subledger_item si
   where si.tenant_id = v_tenant and si.id = any (p_item_ids);
  if v_lines <> v_items then
    raise exception 'CLOVEERP_BANK_MATCH_DOES_NOT_AGREE: the lines come to %, what was chosen in the books to %', v_lines, v_items
      using errcode = '23514', hint = 'Choose entries that come to the lines'' amount; a difference such as a bank fee is a bank entry of its own.';
  end if;

  insert into erp.bank_match (tenant_id, bank_account_id, method, note)
  values (v_tenant, b.id, p_method, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;
  insert into erp.bank_match_line (tenant_id, match_id, line_id)
  select v_tenant, v_id, l from unnest(p_line_ids) l;
  insert into erp.bank_match_item (tenant_id, match_id, subledger_item_id)
  select v_tenant, v_id, i from unnest(p_item_ids) i;
  update erp.bank_statement_line l set status = 'matched', updated_at = now()
   where l.tenant_id = v_tenant and l.id = any (p_line_ids);
  return v_id;
end;
$$;
revoke all on function erp.make_bank_match(uuid, uuid[], uuid[], text, text) from public, anon;

create or replace function erp.auto_match_bank_statement(p_statement_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.bank_statement%rowtype;
  b        erp.bank_account%rowtype;
  v_pass   text;
  r        record;
  v_counts jsonb := '{"reference":0,"payment_run":0,"amount_date":0}'::jsonb;
begin
  select x.* into s from erp.bank_statement x where x.tenant_id = v_tenant and x.id = p_statement_id for update;
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = s.bank_account_id;
  perform erp.authorise('finance.post', b.entity_id, null, null, 'bank_statement', p_statement_id, null);
  if s.id is null then
    raise exception 'CLOVEERP_BANK_MATCH_INVALID: there is no such statement'
      using errcode = '23514', hint = 'Refresh the statement and choose again from what it offers.';
  end if;
  if s.status <> 'imported' then
    raise exception 'CLOVEERP_BANK_MATCH_RECONCILED: the statement is reconciled, and its matches stand'
      using errcode = '23514', hint = 'A reconciled statement is not matched again; correct a mistake with a bank entry on the next one.';
  end if;

  drop table if exists _bank_entries;
  create temp table _bank_entries on commit drop as
    select * from erp.bank_book_entries(b.id);

  foreach v_pass in array array['reference', 'payment_run', 'amount_date'] loop
    for r in
      with lines as (
        select l.id, l.line_no, l.booked_on, l.amount_minor, concat_ws(' ', l.description, l.reference) as words
          from erp.bank_statement_line l
         where l.tenant_id = v_tenant and l.statement_id = s.id and l.status = 'unmatched'
      ), entries as (
        select e.* from _bank_entries e
         where not exists (select 1 from erp.bank_match_item m
                            where m.tenant_id = v_tenant and m.subledger_item_id = any (e.item_ids))
      ), pairs as (
        select l.id as line_id, l.line_no, e.entry_key, e.item_ids
          from lines l
          join entries e on e.amount_minor = l.amount_minor
         where case v_pass
                 when 'reference' then abs(e.posted_on - l.booked_on) <= 7
                                       and exists (select 1 from unnest(e.numbers) n where erp.bank_text_quotes(l.words, n))
                 when 'payment_run' then e.kind in ('payment', 'payment_run') and abs(e.posted_on - l.booked_on) <= 5
                 else abs(e.posted_on - l.booked_on) <= 3
               end
      ), sure as (
        select p.*, count(*) over (partition by p.line_id) as for_line,
                    count(*) over (partition by p.entry_key) as for_entry
          from pairs p
      )
      select x.line_id, x.item_ids from sure x where x.for_line = 1 and x.for_entry = 1 order by x.line_no
    loop
      -- A run and one of its supplier payments are both candidates; whichever
      -- is taken first, the other's items are then spoken for.
      if not exists (select 1 from erp.bank_match_item m where m.tenant_id = v_tenant and m.subledger_item_id = any (r.item_ids))
         and exists (select 1 from erp.bank_statement_line l where l.tenant_id = v_tenant and l.id = r.line_id and l.status = 'unmatched') then
        perform erp.make_bank_match(b.id, array[r.line_id], r.item_ids, v_pass, null);
        v_counts := jsonb_set(v_counts, array[v_pass], to_jsonb((v_counts ->> v_pass)::integer + 1));
      end if;
    end loop;
  end loop;

  return v_counts || jsonb_build_object(
    'statement_id', s.id,
    'unmatched', (select count(*) from erp.bank_statement_line l
                   where l.tenant_id = v_tenant and l.statement_id = s.id and l.status = 'unmatched'));
end;
$$;
revoke all on function erp.auto_match_bank_statement(uuid) from public, anon;

create or replace function public.erp_auto_match_bank_statement(p_statement_id uuid)
returns jsonb
language sql
set search_path = ''
as $$ select erp.auto_match_bank_statement(p_statement_id) $$;
revoke all on function public.erp_auto_match_bank_statement(uuid) from public, anon;
grant execute on function public.erp_auto_match_bank_statement(uuid) to authenticated, service_role;
comment on function public.erp_auto_match_bank_statement(uuid) is
  'Matches the lines of a bank statement it is sure of to what the books hold: by a number the line quotes, a payment '
  'run, or an amount and date no other line or entry shares (20261013030000). Authorises finance.post.';

create or replace function erp.match_bank_lines(p_line_id uuid, p_entry_keys text[], p_note text,
                                                p_other_line_ids uuid[] default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_account uuid;
  v_entity  uuid;
  v_lines   uuid[] := array[p_line_id] || coalesce(p_other_line_ids, '{}'::uuid[]);
  v_items   uuid[];
  v_keys    integer;
  v_id      uuid;
begin
  select l.bank_account_id, b.entity_id into v_account, v_entity
    from erp.bank_statement_line l
    join erp.bank_account b on b.tenant_id = l.tenant_id and b.id = l.bank_account_id
   where l.tenant_id = v_tenant and l.id = p_line_id;
  perform erp.authorise('finance.post', v_entity, null, null, 'bank_statement_line', p_line_id, null);
  if nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'CLOVEERP_BANK_MATCH_NEEDS_A_NOTE: a match made by hand needs a note'
      using errcode = '23514', hint = 'Say why these go together, so the reviewer can read it.';
  end if;
  if exists (select 1 from erp.bank_statement_line l
              join erp.bank_statement s on s.tenant_id = l.tenant_id and s.id = l.statement_id
             where l.tenant_id = v_tenant and l.id = any (v_lines) and s.status <> 'imported') then
    raise exception 'CLOVEERP_BANK_MATCH_RECONCILED: the statement is reconciled, and its matches stand'
      using errcode = '23514', hint = 'A reconciled statement is not matched again; correct a mistake with a bank entry on the next one.';
  end if;

  -- The entries chosen, as the candidates named them, each whole: a receipt
  -- is matched with every invoice it paid, never half of it. An entry no
  -- longer waiting (matched meanwhile) resolves to nothing and is refused.
  select count(distinct e.entry_key), array_agg(distinct i)
    into v_keys, v_items
    from erp.bank_book_entries(v_account) e
    cross join lateral unnest(e.item_ids) i
   where e.entry_key = any (p_entry_keys);
  if v_account is null or coalesce(v_keys, 0) = 0
     or v_keys <> (select count(distinct k) from unnest(p_entry_keys) k) then
    raise exception 'CLOVEERP_BANK_MATCH_INVALID: only unmatched lines of this account''s statements, not yet reconciled, are matched, and only to entries still waiting in its books'
      using errcode = '23514', hint = 'Refresh the statement and choose again from what it offers.';
  end if;
  v_id := erp.make_bank_match(v_account, v_lines, v_items, 'manual', p_note);
  return jsonb_build_object('match_id', v_id, 'lines', cardinality(v_lines), 'entries', v_keys);
end;
$$;
revoke all on function erp.match_bank_lines(uuid, text[], text, uuid[]) from public, anon;

create or replace function public.erp_match_bank_lines(p_line_id uuid, p_entry_keys text[], p_note text,
                                                       p_other_line_ids uuid[] default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.match_bank_lines(p_line_id, p_entry_keys, p_note, p_other_line_ids) $$;
revoke all on function public.erp_match_bank_lines(uuid, text[], text, uuid[]) from public, anon;
grant execute on function public.erp_match_bank_lines(uuid, text[], text, uuid[]) to authenticated, service_role;
comment on function public.erp_match_bank_lines(uuid, text[], text, uuid[]) is
  'Matches a bank statement line, and any other lines of the same account named, by hand to entries of the books '
  'that come to the same amount, with a note (20261013030000). Authorises finance.post.';

create or replace function erp.unmatch_bank_line(p_line_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  m        erp.bank_match%rowtype;
  b        erp.bank_account%rowtype;
  v_lines  uuid[];
begin
  select x.* into m from erp.bank_match x
   where x.tenant_id = v_tenant
     and x.id = (select ml.match_id from erp.bank_match_line ml where ml.tenant_id = v_tenant and ml.line_id = p_line_id)
   for update;
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = m.bank_account_id;
  perform erp.authorise('finance.post', b.entity_id, null, null, 'bank_statement_line', p_line_id, null);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_BANK_UNMATCH_NEEDS_A_REASON: undoing a match needs a reason'
      using errcode = '23514', hint = 'Say why the match was wrong, so the reviewer can read it.';
  end if;
  if m.id is null then
    raise exception 'CLOVEERP_BANK_MATCH_INVALID: the line is not matched'
      using errcode = '23514', hint = 'Refresh the statement and choose again from what it offers.';
  end if;
  select array_agg(ml.line_id) into v_lines from erp.bank_match_line ml
   where ml.tenant_id = v_tenant and ml.match_id = m.id;
  if exists (select 1 from erp.bank_statement_line l
              join erp.bank_statement s on s.tenant_id = l.tenant_id and s.id = l.statement_id
             where l.tenant_id = v_tenant and l.id = any (v_lines) and (s.status <> 'imported' or l.status <> 'matched')) then
    raise exception 'CLOVEERP_BANK_MATCH_RECONCILED: the statement is reconciled, and its matches stand'
      using errcode = '23514', hint = 'A reconciled statement is not matched again; correct a mistake with a bank entry on the next one.';
  end if;

  -- The rows' removal is audited by the audit trigger; the reason, which no
  -- row carries, is the event's.
  perform erp.append_event('bank_match.unmatched', 'bank_match', m.id,
                           jsonb_build_object('bank_account', b.name, 'method', m.method,
                                              'lines', cardinality(v_lines), 'reason', btrim(p_reason)),
                           b.entity_id);
  delete from erp.bank_match where tenant_id = v_tenant and id = m.id;
  update erp.bank_statement_line l set status = 'unmatched', updated_at = now()
   where l.tenant_id = v_tenant and l.id = any (v_lines);
  return jsonb_build_object('match_id', m.id, 'lines', cardinality(v_lines), 'undone', true);
end;
$$;
revoke all on function erp.unmatch_bank_line(uuid, text) from public, anon;

create or replace function public.erp_unmatch_bank_line(p_line_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.unmatch_bank_line(p_line_id, p_reason) $$;
revoke all on function public.erp_unmatch_bank_line(uuid, text) from public, anon;
grant execute on function public.erp_unmatch_bank_line(uuid, text) to authenticated, service_role;
comment on function public.erp_unmatch_bank_line(uuid, text) is
  'Undoes the match a bank statement line is in, with a reason, while its statement is not reconciled '
  '(20261013030000). Authorises finance.post.';

-- What a line could be matched to: entries of its sign, the same amount
-- first, then the nearest amount and date.
create or replace function public.erp_bank_match_candidates(p_line_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with l as (
    select x.* from erp.bank_statement_line x
     where x.tenant_id = erp.current_tenant_id() and x.id = p_line_id
  )
  select coalesce(jsonb_agg(c order by (c ->> 'rank')::integer), '[]'::jsonb) from (
    select jsonb_build_object(
             'entry_key', e.entry_key, 'kind', e.kind, 'item_ids', to_jsonb(e.item_ids),
             'amount_minor', e.amount_minor, 'posted_on', e.posted_on, 'label', e.label,
             'numbers', to_jsonb(e.numbers), 'same_amount', e.amount_minor = l.amount_minor,
             'quoted', exists (select 1 from unnest(e.numbers) n
                                where erp.bank_text_quotes(concat_ws(' ', l.description, l.reference), n)),
             'rank', row_number() over (order by (e.amount_minor = l.amount_minor) desc,
                                                 abs(e.amount_minor - l.amount_minor),
                                                 abs(e.posted_on - l.booked_on), e.entry_key)) as c
      from l
      cross join lateral erp.bank_book_entries(l.bank_account_id) e
     where sign(e.amount_minor) = sign(l.amount_minor)
     order by (e.amount_minor = l.amount_minor) desc, abs(e.amount_minor - l.amount_minor),
              abs(e.posted_on - l.booked_on), e.entry_key
     limit 40) t
$$;
revoke all on function public.erp_bank_match_candidates(uuid) from public, anon;
grant execute on function public.erp_bank_match_candidates(uuid) to authenticated, service_role;
comment on function public.erp_bank_match_candidates(uuid) is
  'What the books hold that a bank statement line could be matched to, of its sign, the same amount first '
  '(20261013030000). Reads only.';

-- The lines of a statement, now with what each matched line was matched to.
create or replace function public.erp_bank_statement_lines(p_statement_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_id', l.id, 'line_no', l.line_no, 'booked_on', l.booked_on, 'amount_minor', l.amount_minor,
           'description', l.description, 'reference', l.reference, 'balance_minor', l.balance_minor,
           'status', l.status,
           'match', (select jsonb_build_object(
                              'match_id', m.id, 'method', m.method, 'note', m.note, 'matched_at', m.created_at,
                              'lines', (select count(*) from erp.bank_match_line o
                                         where o.tenant_id = m.tenant_id and o.match_id = m.id),
                              'entries', (select coalesce(jsonb_agg(distinct coalesce(d.document_number, j.journal_number, j.description)), '[]'::jsonb)
                                            from erp.bank_match_item mi
                                            join erp.subledger_item si on si.id = mi.subledger_item_id
                                            join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
                                            left join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
                                           where mi.tenant_id = m.tenant_id and mi.match_id = m.id))
                       from erp.bank_match_line ml
                       join erp.bank_match m on m.tenant_id = ml.tenant_id and m.id = ml.match_id
                      where ml.tenant_id = l.tenant_id and ml.line_id = l.id)) order by l.line_no), '[]'::jsonb)
    from erp.bank_statement_line l
   where l.tenant_id = erp.current_tenant_id() and l.statement_id = p_statement_id
$$;
revoke all on function public.erp_bank_statement_lines(uuid) from public, anon;
grant execute on function public.erp_bank_statement_lines(uuid) to authenticated, service_role;
comment on function public.erp_bank_statement_lines(uuid) is
  'The lines of one bank statement, in the bank''s order, with what each matched line was matched to '
  '(20261013020000, 20261013030000). Reads only.';

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('bank_match.unmatched', 1, 'bank_match', 'finance', 'event.bank_match.unmatched',
   'A match of bank statement lines to the books was undone, with a reason, before the statement was reconciled.',
   '{"type":"object","required":["bank_account","method","lines","reason"],"properties":{"bank_account":{"type":"string"},"method":{"type":"string"},"lines":{"type":"integer"},"reason":{"type":"string"}}}'::jsonb, true)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.bank_match.unmatched', 'en', 'Bank match unmatched', 'finance',
   'Event raised when a match of bank statement lines to the books is undone.'),
  ('event.bank_match.unmatched', 'de', 'Bankabgleich aufgehoben', 'finance',
   'Ereignis, wenn ein Abgleich von Kontoauszugszeilen mit der Buchhaltung aufgehoben wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_auto_match_bank_statement', 'erp.auto_match_bank_statement',
   'Matches the lines of a bank statement it is sure of to what the books hold; posts nothing; authorises finance.post.'),
  ('erp_match_bank_lines', 'erp.match_bank_lines',
   'Matches bank statement lines by hand to entries of the books that come to the same amount, with a note; authorises finance.post.'),
  ('erp_unmatch_bank_line', 'erp.unmatch_bank_line',
   'Undoes a bank match, with a reason, while the statement is not reconciled; authorises finance.post.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_BANK_MATCH_INVALID',
  'Matching a line already matched, of another account, or of a reconciled statement, or to a bank item already matched or of another ledger account.',
  'A line or a bank item matched twice would be counted twice in the reconciliation.',
  'Refresh the statement and choose again from what it offers.');
select erp.register_refusal('CLOVEERP_BANK_MATCH_DOES_NOT_AGREE',
  'Matching bank lines to entries in the books that do not come to the same amount.',
  'A match says the bank and the books agree; a difference left inside one would never be reconciled.',
  'Choose entries that come to the lines'' amount; post a difference such as a bank fee as a bank entry of its own.');
select erp.register_refusal('CLOVEERP_BANK_MATCH_RECONCILED',
  'Matching or unmatching a line of a statement already reconciled.',
  'A reconciled statement is what the period was closed on; changing its matches would change a closed reconciliation.',
  'Correct a mistake with a bank entry on the next statement.');
select erp.register_refusal('CLOVEERP_BANK_MATCH_NEEDS_A_NOTE',
  'Matching bank lines by hand without a note.',
  'A match made by hand is a judgement; the reviewer needs to read why.',
  'Say why these lines and entries go together.');
select erp.register_refusal('CLOVEERP_BANK_UNMATCH_NEEDS_A_REASON',
  'Undoing a bank match without a reason.',
  'Undoing a match changes what the reconciliation relies on; the reviewer needs to read why.',
  'Say why the match was wrong.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Matching a bank line (20261013030000).'
  from (values
    ('Match automatically'),
    ('Matched'),
    ('Unmatched'),
    ('Match'),
    ('Unmatch'),
    ('Match this line'),
    ('Undo this match'),
    ('Why do these go together?'),
    ('Why was the match wrong?'),
    ('Choose what the books hold for this line. What you choose must come to the line''s amount.'),
    ('Nothing in the books is waiting to be matched to a line of this sign.'),
    ('Same amount'),
    ('Quoted on the line'),
    ('By reference'),
    ('Payment run'),
    ('By amount and date'),
    ('By hand'),
    ('Matched to'),
    ('Lines matched automatically'),
    ('No line could be matched with certainty.'),
    ('Other lines in this match'),
    ('When the bank shows in several lines what the books hold as one, or the other way round.'),
    ('Kept with the match for the reviewer.'),
    ('Kept with the change for the reviewer.'),
    ('The line, and any other line in the same match, is unmatched again, and what it was matched to waits in the books once more.')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.bank_matching_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid;
  v_ccy    character(3);
  v_site   uuid;
  v_item   uuid;
  v_uom    uuid;
  v_cust   uuid;
  v_bank   uuid;
  v_inv    uuid[] := '{}';
  v_rcpt   uuid[] := '{}';
  v_inv_no text;
  i_fg     uuid;
  p_sup    uuid;
  v_po     uuid;
  v_bill   uuid;
  v_pay    jsonb;
  v_run    bigint;
  v_st     uuid;
  v_ln     uuid[];
  x        jsonb;
  v_ok     boolean;
  v_msg    text;
  n        integer;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzbmt' || v_tag, 'Bank Matching Suite',
      'admin@demo-zzbmt' || v_tag || '.test', 'Matching Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@demo-zzbmt' || v_tag || '.test'), (a2, 'second@demo-zzbmt' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('second@demo-zzbmt' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_tenant := rb.tenant_id;

    v_step := 'a company, its bank account, a product and a customer';
    select e.id, e.base_currency into v_ent, v_ccy from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select b.id into v_bank from erp.bank_account b where b.tenant_id = v_tenant and b.entity_id = v_ent and b.is_default;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZBMWID', 'Bank Matching Widget', v_uom, 'active') returning id into v_item;

    v_step := 'four customers, an invoice each, and a receipt for each: 200.00, 150.00, and two of 100.00';
    for n in 1..4 loop
      v_inv := v_inv || erp_test.cash_tolerance_customer_invoice(v_ent, v_site, v_item, v_ccy, 'ZBM' || n || v_tag, 50000);
      select d.party_id into v_cust from erp.document d where d.id = v_inv[n];
      v_rcpt := v_rcpt || (select r.document_id
                             from public.erp_apply_cash(v_cust, (array[20000, 15000, 10000, 10000])[n]::bigint, v_ccy,
                                                        'ZBM-R' || n, array[v_inv[n]]) r
                            where r.document_id is not null limit 1);
    end loop;
    select d.document_number into v_inv_no from erp.document d where d.id = v_inv[1];

    v_step := 'a supplier''s bill paid by a run';
    select i.id into i_fg from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
    select pt.id into p_sup from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'S-FAST';
    v_po := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po, i_fg, 5, 4000, 'stock');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'fixture');
    perform erp.transition_document(v_po, 'send', null);
    x := erp.create_receipt_from_order(v_po, null, 'post');
    v_bill := erp.bill_from_receipt((x ->> 'document_id')::uuid, 'ZBM-BILL-1', current_date, current_date, true);
    v_pay := erp_test.cash_payment_run(array[v_bill], a1, a2);
    select sum(si.credit_minor - si.debit_minor)::bigint into v_run
      from erp.subledger_item si join erp.journal j on j.id = si.journal_id
     where si.tenant_id = v_tenant and si.control_kind = 'bank'
       and j.document_id = (v_pay #>> '{payments,0,document_id}')::uuid;

    v_step := 'the statement: a line quoting the invoice, one by amount, two alike, a run, and a bank fee';
    x := public.erp_import_bank_statement(v_bank, 'csv', 'barclays', md5('m1' || v_tag) || md5('m1b' || v_tag),
           20000 + 15000 + 10000 + 10000 - v_run - 1250,
           jsonb_build_array(
             jsonb_build_object('booked_on', current_date, 'amount_minor', 20000, 'description', 'ACME LTD ' || replace(v_inv_no, '-', '')),
             jsonb_build_object('booked_on', current_date + 1, 'amount_minor', 15000, 'description', 'FASTER PAYMENT'),
             jsonb_build_object('booked_on', current_date, 'amount_minor', 10000, 'description', 'TRANSFER A'),
             jsonb_build_object('booked_on', current_date, 'amount_minor', 10000, 'description', 'TRANSFER B'),
             jsonb_build_object('booked_on', current_date + 2, 'amount_minor', -v_run, 'description', 'BACS PAYMENTS'),
             jsonb_build_object('booked_on', current_date + 2, 'amount_minor', -1250, 'description', 'ACCOUNT FEE')),
           0);
    v_st := (x ->> 'statement_id')::uuid;
    select array_agg(l.id order by l.line_no) into v_ln from erp.bank_statement_line l where l.statement_id = v_st;

    -- ── 1. Matched automatically, each by its own pass ──────────────────────
    v_step := 'matching automatically';
    x := public.erp_auto_match_bank_statement(v_st);
    v_cases := v_cases + 1;
    case_name := 'a line quoting its invoice, a run''s BACS line and a line alone at its amount are matched, each by its pass';
    passed := v_state is null
          and (x ->> 'reference')::integer = 1 and (x ->> 'payment_run')::integer = 1 and (x ->> 'amount_date')::integer = 1
          and (select m.method from erp.bank_match_line ml join erp.bank_match m on m.id = ml.match_id where ml.line_id = v_ln[1]) = 'reference'
          and (select m.method from erp.bank_match_line ml join erp.bank_match m on m.id = ml.match_id where ml.line_id = v_ln[2]) = 'amount_date'
          and (select m.method from erp.bank_match_line ml join erp.bank_match m on m.id = ml.match_id where ml.line_id = v_ln[5]) = 'payment_run'
          and exists (select 1 from erp.bank_match_line ml join erp.bank_match_item mi on mi.match_id = ml.match_id
                        join erp.subledger_item si on si.id = mi.subledger_item_id join erp.journal j on j.id = si.journal_id
                       where ml.line_id = v_ln[1] and j.document_id = v_rcpt[1]);
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 2. What is not sure is left ─────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'two lines alike against two receipts alike, and a fee the books do not hold, are left for a person';
    passed := v_state is null and (x ->> 'unmatched')::integer = 3
          and (select array_agg(l.status order by l.line_no) from erp.bank_statement_line l where l.statement_id = v_st)
              = array['matched', 'matched', 'unmatched', 'unmatched', 'matched', 'unmatched']
          and (public.erp_auto_match_bank_statement(v_st) ->> 'unmatched')::integer = 3;
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 3. The candidates ───────────────────────────────────────────────────
    v_cases := v_cases + 1;
    x := public.erp_bank_match_candidates(v_ln[3]);
    case_name := 'a line''s candidates are of its sign, the same amount first, and matched entries are not among them';
    passed := v_state is null
          and (x -> 0 ->> 'same_amount')::boolean and (x -> 1 ->> 'same_amount')::boolean
          and (x -> 2) is null
          and (select count(*) from jsonb_array_elements(public.erp_bank_match_candidates(v_ln[6]))) = 0;
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 4. By hand: a note, and amounts that agree ──────────────────────────
    v_step := 'matching by hand';
    begin
      perform public.erp_match_bank_lines(v_ln[3], array[x -> 0 ->> 'entry_key'], ' ');
      v_ok := false; v_msg := 'matched without a note';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_MATCH_NEEDS_A_NOTE%'; v_msg := left(sqlerrm, 100);
    end;
    begin
      perform public.erp_match_bank_lines(v_ln[3], array[x -> 0 ->> 'entry_key', x -> 1 ->> 'entry_key'], 'both receipts');
      v_ok := false; v_msg := 'matched 100.00 to 200.00';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_MATCH_DOES_NOT_AGREE%'; v_msg := v_msg || ' | ' || left(sqlerrm, 100);
    end;
    res := public.erp_match_bank_lines(v_ln[3], array[x -> 0 ->> 'entry_key', x -> 1 ->> 'entry_key'],
      'the customer paid the two invoices in two transfers', array[v_ln[4]]);
    v_cases := v_cases + 1;
    case_name := 'a match by hand needs a note and amounts that agree, and may take two lines to two receipts';
    passed := v_state is null and v_ok and (res ->> 'lines')::integer = 2
          and (select m.method from erp.bank_match m where m.id = (res ->> 'match_id')::uuid) = 'manual'
          and (select count(*) from erp.bank_statement_line l where l.statement_id = v_st and l.status = 'unmatched') = 1;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 5. Nothing is matched twice ─────────────────────────────────────────
    v_step := 'matching twice';
    begin
      perform public.erp_match_bank_lines(v_ln[6], array[x -> 0 ->> 'entry_key'], 'again');
      v_ok := false; v_msg := 'an item matched twice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_MATCH_INVALID%'; v_msg := left(sqlerrm, 100);
    end;
    v_cases := v_cases + 1;
    case_name := 'an entry already matched is not matched again';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 6. Undone with a reason ─────────────────────────────────────────────
    v_step := 'undoing a match';
    begin
      perform public.erp_unmatch_bank_line(v_ln[1], '');
      v_ok := false; v_msg := 'undone without a reason';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_UNMATCH_NEEDS_A_REASON%'; v_msg := left(sqlerrm, 100);
    end;
    begin
      perform public.erp_withdraw_bank_statement(v_st, 'wrong account');
      v_ok := false; v_msg := v_msg || ' | withdrawn while matched';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_STATEMENT_CANNOT_WITHDRAW%';
    end;
    perform public.erp_unmatch_bank_line(v_ln[3], 'the transfers were for other invoices');
    v_cases := v_cases + 1;
    case_name := 'a match is undone only with a reason, both its lines come back, and the statement is not withdrawn while matched';
    passed := v_state is null and v_ok
          and (select array_agg(l.status order by l.line_no) from erp.bank_statement_line l where l.statement_id = v_st)
              = array['matched', 'matched', 'unmatched', 'unmatched', 'matched', 'unmatched']
          and (select count(*) from jsonb_array_elements(public.erp_bank_match_candidates(v_ln[3])) c
                where (c ->> 'same_amount')::boolean) = 2
          and exists (select 1 from erp.event ev where ev.tenant_id = v_tenant and ev.event_type = 'bank_match.unmatched'
                         and ev.payload ->> 'reason' = 'the transfers were for other invoices');
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 7. The lines say what they matched ──────────────────────────────────
    v_cases := v_cases + 1;
    x := public.erp_bank_statement_lines(v_st);
    case_name := 'a matched line names what it was matched to and how';
    passed := v_state is null
          and x -> 0 -> 'match' ->> 'method' = 'reference'
          and (x -> 0 -> 'match' -> 'entries') ? (select d.document_number from erp.document d where d.id = v_rcpt[1])
          and x -> 2 -> 'match' = 'null'::jsonb;
    detail := coalesce(v_state, x::text);
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
    raise exception 'CLOVEERP_BANK_MATCHING_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.bank_matching_suite() from public, anon, authenticated;

create or replace function erp_test.assert_bank_matching_suite()
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
  create temp table if not exists _bank_matching on commit drop as
    select * from erp_test.bank_matching_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _bank_matching;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_BANK_MATCHING_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_BANK_MATCHING_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('bank matching: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_bank_matching_suite() from public, anon, authenticated;

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
