-- A bank line is posted.
--
-- Bank reconciliation, pull request 4 of 5 (owner, 13 October 2026). A line of
-- a statement that the books do not yet hold is posted from the Bank screen:
-- by a rule, by hand, as a receipt; and a card provider's payout, which the
-- bank shows net of its fees, finds the receipts it paid with the fees posted.
--
-- ── DECISIONS ────────────────────────────────────────────────────────────────
--
--   The owner's: an entry a rule makes posts when the reconciler presses; an
--   entry made by hand needs a second person with finance.close_period; card
--   settlement fees are posted, which reverses D14 (fees recorded, never
--   posted, the bank debited with the gross).
--
--   Mine, under the standing approval of 13 October:
--   * A bank entry is a manual journal. A hand-made one is submitted for
--     approval and approved on the Journals screen by erp_approve_journal,
--     which already asks for finance.close_period and a second person once
--     the organisation is live, and lets an administrator approve their own
--     where the organisation allows it (20260914098000). A rule-made one is
--     posted at once by whoever pressed. Either is reversed on the Journals
--     screen like any journal, the reversal approved like any journal.
--   * A bank entry carries no VAT. VAT is reclaimed from a VAT invoice, and
--     the return reads documents (erp.vat_entries); a bank line with VAT on it
--     is a supplier's bill and its payment. The contra account may be any
--     postable account in use that no subledger keeps.
--   * Card fees post to the company's settlement differences account (7900)
--     under the settlement_difference rule, which already posts against the
--     bank, on the statement's date. An organisation that wants them
--     elsewhere moves them with a journal; a fee account of their own is a
--     chart change for another day.
--   * Receiving cash from a line lands in the default bank account, as every
--     receipt does (erp.company_bank_account); a line of another account is
--     refused rather than banked where the statement does not say.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.bank_rule: words a line quotes, money in or out or either, the
--      account it posts to, an order. public.erp_define_bank_rule,
--      erp_retire_bank_rule (finance.configure) and erp_bank_rules.
--   B. erp.bank_entry ties a statement line to the manual journal that posts
--      it. erp.journal_require_sound lets that journal, and its reversal,
--      carry the bank account's line, which every other journal is refused
--      (CLOVEERP_JOURNAL_CONTROL_ACCOUNT). When either is posted, a trigger
--      writes the bank's subledger item and matches the line (method entry),
--      or for a reversal takes the match back and frees the line.
--   C. public.erp_post_bank_line_by_rule and erp_apply_bank_rules post at
--      once; public.erp_propose_bank_entry submits one made by hand.
--   D. public.erp_receive_bank_line applies a money-in line as cash from a
--      customer, dated the day the bank booked it, and matches it to the
--      receipt (method receipt).
--   E. erp.apply_settlement_statement posts the statement's fees: Dr 7900, Cr
--      bank. erp.bank_book_entries offers the statement's receipts and fees
--      whole, which come to the payout, and auto-matching takes a payout line
--      that is the one candidate at that amount within seven days (method
--      settlement).
--   F. A posted line is not unmatched: its journal is reversed. A line with an
--      entry waiting is matched by nothing else. The lines door says what
--      posted or waits on each line, and which rule would post it.
--   G. erp_test.bank_entry_suite proves it.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Rules
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.bank_rule (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  entity_id         uuid not null,
  bank_account_id   uuid,
  name              text not null,
  words             text not null,
  direction         text not null default 'either',
  account_id        uuid not null references erp.account(id) on delete restrict,
  priority          integer not null default 100,
  status            text not null default 'active',
  retired_reason    text,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint bank_rule_tenant_id_id_key unique (tenant_id, id),
  constraint bank_rule_account_fk foreign key (tenant_id, bank_account_id) references erp.bank_account(tenant_id, id) on delete restrict,
  constraint bank_rule_direction_known check (direction in ('in', 'out', 'either')),
  constraint bank_rule_status_known check (status in ('active', 'inactive')),
  constraint bank_rule_named check (btrim(name) <> '' and btrim(words) <> ''),
  constraint bank_rule_retired_said check (status = 'active' or btrim(coalesce(retired_reason, '')) <> '')
);
create unique index if not exists bank_rule_name_once on erp.bank_rule (tenant_id, entity_id, lower(name)) where status = 'active';

comment on table erp.bank_rule is
  'A bank rule (20261013040000): a statement line that quotes these words, money in or out, posts to this account '
  'when the reconciler presses. The lowest priority applies first.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'bank_rule', 'tenant_scoped', 'A bank rule: the words a statement line quotes and the account it posts to; retired with a reason.')
on conflict (schema_name, table_name) do nothing;

-- The account a bank entry may post to: a postable account in use of the
-- company, that no subledger keeps and that is not statistical.
create or replace function erp.require_bank_entry_account(p_entity_id uuid, p_account_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  a erp.account%rowtype;
begin
  select x.* into a from erp.account x where x.tenant_id = erp.require_tenant_id() and x.id = p_account_id;
  if a.id is null or a.entity_id is distinct from p_entity_id or a.status <> 'active' or not a.is_postable
     or a.control_kind is not null or a.account_type::text = 'statistical' then
    raise exception 'CLOVEERP_BANK_ENTRY_ACCOUNT: % is not an account a bank entry posts to',
      coalesce(a.code || ' ' || a.name, 'that account')
      using errcode = '23514',
            hint = 'Choose a postable account in use of the bank account''s company that no ledger keeps: an expense, income, asset, liability or equity account, not the bank, debtors, creditors or VAT.';
  end if;
end;
$$;
revoke all on function erp.require_bank_entry_account(uuid, uuid) from public, anon;

create or replace function erp.define_bank_rule(p_name text, p_words text, p_account_id uuid,
                                                p_direction text default 'either',
                                                p_bank_account_id uuid default null,
                                                p_priority integer default 100)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_id     uuid;
begin
  select a.entity_id into v_entity from erp.account a where a.tenant_id = v_tenant and a.id = p_account_id;
  perform erp.authorise('finance.configure', v_entity, null, null, 'bank_rule', null, null);
  if nullif(btrim(coalesce(p_name, '')), '') is null or length(erp.bank_text_words(p_words)) < 3
     or coalesce(p_direction, 'either') not in ('in', 'out', 'either') or coalesce(p_priority, 100) < 0 then
    raise exception 'CLOVEERP_BANK_RULE_INVALID: a rule needs a name, words of at least three letters or digits a line quotes, and money in, out or either'
      using errcode = '23514', hint = 'Give the rule a name and the words the bank prints on the line, such as ACCOUNT FEE.';
  end if;
  perform erp.require_bank_entry_account(v_entity, p_account_id);
  if p_bank_account_id is not null and not exists (
       select 1 from erp.bank_account b
        where b.tenant_id = v_tenant and b.id = p_bank_account_id and b.entity_id = v_entity and b.status = 'open') then
    raise exception 'CLOVEERP_BANK_RULE_INVALID: the bank account is not an open account of the company the posting account belongs to'
      using errcode = '23514', hint = 'Choose an open bank account of the same company, or none for every one of its accounts.';
  end if;
  insert into erp.bank_rule (tenant_id, entity_id, bank_account_id, name, words, direction, account_id, priority)
  values (v_tenant, v_entity, p_bank_account_id, btrim(p_name), btrim(p_words), coalesce(p_direction, 'either'),
          p_account_id, coalesce(p_priority, 100))
  returning id into v_id;
  return jsonb_build_object('rule_id', v_id, 'name', btrim(p_name));
end;
$$;
revoke all on function erp.define_bank_rule(text, text, uuid, text, uuid, integer) from public, anon;

create or replace function public.erp_define_bank_rule(p_name text, p_words text, p_account_id uuid,
                                                       p_direction text default 'either',
                                                       p_bank_account_id uuid default null,
                                                       p_priority integer default 100)
returns jsonb
language sql
set search_path = ''
as $$ select erp.define_bank_rule(p_name, p_words, p_account_id, p_direction, p_bank_account_id, p_priority) $$;
revoke all on function public.erp_define_bank_rule(text, text, uuid, text, uuid, integer) from public, anon;
grant execute on function public.erp_define_bank_rule(text, text, uuid, text, uuid, integer) to authenticated, service_role;
comment on function public.erp_define_bank_rule(text, text, uuid, text, uuid, integer) is
  'Defines a bank rule: a statement line quoting these words, money in, out or either, posts to this account when the '
  'reconciler presses (20261013040000). Authorises finance.configure.';

create or replace function erp.retire_bank_rule(p_rule_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        erp.bank_rule%rowtype;
begin
  select x.* into r from erp.bank_rule x where x.tenant_id = v_tenant and x.id = p_rule_id for update;
  perform erp.authorise('finance.configure', r.entity_id, null, null, 'bank_rule', p_rule_id, null);
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_BANK_RULE_RETIRE_NEEDS_A_REASON: retiring a bank rule needs a reason'
      using errcode = '23514', hint = 'Say why the rule no longer applies, so the next reader knows.';
  end if;
  if r.id is null or r.status <> 'active' then
    raise exception 'CLOVEERP_BANK_RULE_INVALID: there is no such rule in use'
      using errcode = '23514', hint = 'Refresh the rules and choose again.';
  end if;
  update erp.bank_rule set status = 'inactive', retired_reason = btrim(p_reason), updated_at = now()
   where tenant_id = v_tenant and id = r.id;
  return jsonb_build_object('rule_id', r.id, 'retired', true);
end;
$$;
revoke all on function erp.retire_bank_rule(uuid, text) from public, anon;

create or replace function public.erp_retire_bank_rule(p_rule_id uuid, p_reason text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.retire_bank_rule(p_rule_id, p_reason) $$;
revoke all on function public.erp_retire_bank_rule(uuid, text) from public, anon;
grant execute on function public.erp_retire_bank_rule(uuid, text) to authenticated, service_role;
comment on function public.erp_retire_bank_rule(uuid, text) is
  'Retires a bank rule, with a reason; entries it posted stand (20261013040000). Authorises finance.configure.';

create or replace function public.erp_bank_rules()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'rule_id', r.id, 'name', r.name, 'words', r.words, 'direction', r.direction,
           'account_id', r.account_id, 'account', a.code || ' ' || a.name,
           'bank_account_id', r.bank_account_id, 'bank_account', b.name,
           'priority', r.priority, 'status', r.status, 'retired_reason', r.retired_reason)
         order by r.status, r.priority, r.name), '[]'::jsonb)
    from erp.bank_rule r
    join erp.account a on a.id = r.account_id
    left join erp.bank_account b on b.tenant_id = r.tenant_id and b.id = r.bank_account_id
   where r.tenant_id = erp.current_tenant_id()
$$;
revoke all on function public.erp_bank_rules() from public, anon;
grant execute on function public.erp_bank_rules() to authenticated, service_role;
comment on function public.erp_bank_rules() is
  'The organisation''s bank rules, those in use first, in the order they apply (20261013040000). Reads only.';

-- The rule that would post a line: in use, of the line's company and of its
-- bank account or of every one, the direction of its money, the words quoted;
-- the lowest priority first.
create or replace function erp.bank_rule_for_line(p_line_id uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  select r.id
    from erp.bank_statement_line l
    join erp.bank_account b on b.tenant_id = l.tenant_id and b.id = l.bank_account_id
    join erp.bank_rule r on r.tenant_id = l.tenant_id and r.entity_id = b.entity_id and r.status = 'active'
                        and (r.bank_account_id is null or r.bank_account_id = b.id)
   where l.tenant_id = erp.current_tenant_id() and l.id = p_line_id
     and (r.direction = 'either' or (r.direction = 'in') = (l.amount_minor > 0))
     and position(' ' || erp.bank_text_words(r.words) || ' '
                  in ' ' || erp.bank_text_words(concat_ws(' ', l.description, l.reference)) || ' ') > 0
   order by r.priority, lower(r.name)
   limit 1
$$;
revoke all on function erp.bank_rule_for_line(uuid) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A bank entry is a journal
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.bank_entry (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  bank_account_id   uuid not null,
  line_id           uuid not null,
  journal_id        uuid not null references erp.journal(id) on delete cascade,
  origin            text not null,
  rule_id           uuid,
  reversed_at       timestamptz,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint bank_entry_tenant_id_id_key unique (tenant_id, id),
  constraint bank_entry_journal_once unique (journal_id),
  constraint bank_entry_account_fk foreign key (tenant_id, bank_account_id) references erp.bank_account(tenant_id, id) on delete restrict,
  constraint bank_entry_line_fk foreign key (tenant_id, line_id) references erp.bank_statement_line(tenant_id, id) on delete restrict,
  constraint bank_entry_rule_fk foreign key (tenant_id, rule_id) references erp.bank_rule(tenant_id, id) on delete restrict,
  constraint bank_entry_origin_known check (origin in ('rule', 'hand')),
  constraint bank_entry_rule_named check ((origin = 'rule') = (rule_id is not null))
);
-- One entry in force for a line; a reversed one leaves the line free again.
create unique index if not exists bank_entry_line_in_force on erp.bank_entry (tenant_id, line_id) where reversed_at is null;

comment on table erp.bank_entry is
  'A bank entry (20261013040000): the manual journal that posts a statement line the books did not hold, made by a '
  'rule or by hand, and when its reversal freed the line again.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'bank_entry', 'tenant_scoped', 'Ties a statement line to the manual journal that posts it; reversed with the journal.')
on conflict (schema_name, table_name) do nothing;

-- Whether a journal line on this account is a bank entry's bank line: the
-- journal, or the journal it reverses, posts a statement line of the bank
-- account whose ledger account this is.
create or replace function erp.is_bank_entry_bank_line(p_journal_id uuid, p_account_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from erp.journal j
      join erp.bank_entry be on be.tenant_id = j.tenant_id and be.journal_id in (j.id, j.reverses_journal_id)
      join erp.bank_account b on b.tenant_id = be.tenant_id and b.id = be.bank_account_id
     where j.tenant_id = erp.require_tenant_id() and j.id = p_journal_id and b.account_id = p_account_id)
$$;
revoke all on function erp.is_bank_entry_bank_line(uuid, uuid) from public, anon;

do $sound$
declare
  v_sig  constant text := 'erp.journal_require_sound(uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    perform erp.journal_require_account(j.entity_id, l.account_id, l.line_no);$o$;
  v_new  constant text := $n$    -- A bank entry's bank line is the cash book's, written with its
    -- subledger item when the journal posts (20261013040000).
    if not erp.is_bank_entry_bank_line(p_journal_id, l.account_id) then
      perform erp.journal_require_account(j.entity_id, l.account_id, l.line_no);
    end if;$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('is_bank_entry_bank_line' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % account anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$sound$;

-- When a bank entry's journal posts: the bank's subledger item, and the line
-- matched to it. When its reversal posts: the reversing item, the match taken
-- back, the line free again.
create or replace function erp.bank_entry_follows_journal()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  be         erp.bank_entry%rowtype;
  b          erp.bank_account%rowtype;
  l          erp.bank_statement_line%rowtype;
  v_reversal boolean := false;
  v_net      bigint;
  v_item     uuid;
begin
  select x.* into be from erp.bank_entry x where x.tenant_id = new.tenant_id and x.journal_id = new.id;
  if be.id is null and new.reverses_journal_id is not null then
    select x.* into be from erp.bank_entry x
     where x.tenant_id = new.tenant_id and x.journal_id = new.reverses_journal_id and x.reversed_at is null;
    v_reversal := be.id is not null;
  end if;
  if be.id is null then
    return null;
  end if;

  select x.* into b from erp.bank_account x where x.tenant_id = be.tenant_id and x.id = be.bank_account_id;
  select x.* into l from erp.bank_statement_line x where x.tenant_id = be.tenant_id and x.id = be.line_id for update;
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_net
    from erp.journal_line jl where jl.tenant_id = new.tenant_id and jl.journal_id = new.id and jl.account_id = b.account_id;

  if v_net <> (case when v_reversal then -l.amount_minor else l.amount_minor end) then
    raise exception 'CLOVEERP_BANK_ENTRY_CHANGED: the journal moves the bank by %, and the statement line by %',
      v_net, case when v_reversal then -l.amount_minor else l.amount_minor end
      using errcode = '23514', hint = 'Discard the journal and post the line again from the Bank screen.';
  end if;

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
  values (new.tenant_id, new.entity_id, new.ledger_id, 'bank', b.account_id,
          null, null, new.id, b.currency, greatest(v_net, 0), greatest(-v_net, 0), new.posting_date)
  returning id into v_item;

  if not v_reversal then
    perform erp.make_bank_match(b.id, array[l.id], array[v_item], 'entry', null);
    update erp.bank_statement_line x set status = 'posted', updated_at = now()
     where x.tenant_id = l.tenant_id and x.id = l.id;
  else
    delete from erp.bank_match m
     where m.tenant_id = l.tenant_id
       and m.id = (select ml.match_id from erp.bank_match_line ml where ml.tenant_id = l.tenant_id and ml.line_id = l.id);
    update erp.bank_statement_line x set status = 'unmatched', updated_at = now()
     where x.tenant_id = l.tenant_id and x.id = l.id;
    update erp.bank_entry x set reversed_at = now(), updated_at = now()
     where x.tenant_id = be.tenant_id and x.id = be.id;
  end if;
  return null;
end;
$$;
revoke all on function erp.bank_entry_follows_journal() from public, anon;

drop trigger if exists t_journal_bank_entry on erp.journal;
create trigger t_journal_bank_entry
  after update of status on erp.journal
  for each row
  when (new.status = 'posted' and old.status is distinct from 'posted' and new.source_code = 'manual')
  execute function erp.bank_entry_follows_journal();

-- A line with an entry in force is matched by that entry and nothing else;
-- the match methods gain the entry, the receipt and the card settlement.
alter table erp.bank_match drop constraint if exists bank_match_method_known;
alter table erp.bank_match add constraint bank_match_method_known
  check (method in ('reference', 'payment_run', 'amount_date', 'manual', 'entry', 'receipt', 'settlement'));

do $match$
declare
  v_sig  constant text := 'erp.make_bank_match(uuid,uuid[],uuid[],text,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$            and l.status = 'unmatched' and s.status = 'imported') <> cardinality(p_line_ids)$o$;
  v_new  constant text := $n$            and l.status = 'unmatched' and s.status = 'imported'
            -- A line an entry posts, or waits to post, is that entry's
            -- (20261013040000).
            and (p_method = 'entry'
                 or not exists (select 1 from erp.bank_entry be
                                 where be.tenant_id = l.tenant_id and be.line_id = l.id and be.reversed_at is null))) <> cardinality(p_line_ids)$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('20261013040000' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % line anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$match$;

-- A posted line's match is the entry's journal: it is reversed, not unmatched.
do $unmatch$
declare
  v_sig  constant text := 'erp.unmatch_bank_line(uuid,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  select array_agg(ml.line_id) into v_lines from erp.bank_match_line ml$o$;
  v_new  constant text := $n$  if m.method = 'entry' then
    raise exception 'CLOVEERP_BANK_ENTRY_POSTED: the line is posted by a bank entry, which is a journal'
      using errcode = '23514', hint = 'Reverse the entry''s journal on the Journals screen; once the reversal is approved the line is free again.';
  end if;
  select array_agg(ml.line_id) into v_lines from erp.bank_match_line ml$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('CLOVEERP_BANK_ENTRY_POSTED' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % lines anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$unmatch$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Posting a line
-- ─────────────────────────────────────────────────────────────────────────────

-- The journal for a line, raised as a draft manual journal on the day the
-- bank booked it: the bank account's line and the contra. The caller has
-- authorised.
create or replace function erp.raise_bank_entry(p_line_id uuid, p_account_id uuid, p_narrative text,
                                                p_origin text, p_rule_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_me      uuid := erp.current_principal_id();
  l         erp.bank_statement_line%rowtype;
  b         erp.bank_account%rowtype;
  v_ledger  uuid;
  v_journal uuid;
  v_amount  bigint;
begin
  select x.* into l from erp.bank_statement_line x where x.tenant_id = v_tenant and x.id = p_line_id for update;
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = l.bank_account_id;
  if l.id is null or l.status <> 'unmatched'
     or not exists (select 1 from erp.bank_statement s where s.tenant_id = v_tenant and s.id = l.statement_id and s.status = 'imported')
     or exists (select 1 from erp.bank_entry be where be.tenant_id = v_tenant and be.line_id = l.id and be.reversed_at is null) then
    raise exception 'CLOVEERP_BANK_ENTRY_NOT_OPEN: only an unmatched line of a statement not yet reconciled, with no entry waiting, is posted'
      using errcode = '23514', hint = 'Refresh the statement: the line may be matched, posted, or waiting for its entry''s approval.';
  end if;
  perform erp.require_bank_entry_account(b.entity_id, p_account_id);

  select lg.id into v_ledger from erp.ledger lg
   where lg.tenant_id = v_tenant and lg.entity_id = b.entity_id and lg.is_primary and lg.status = 'active';
  v_amount := abs(l.amount_minor);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description,
                           status, manual_reason, reference, prepared_by, created_by)
  values (v_tenant, b.entity_id, v_ledger, 'manual', l.booked_on, btrim(p_narrative),
          'draft', btrim(p_narrative), left(l.description, 80), v_me, v_me)
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate, description)
  values (v_tenant, v_journal, 1, b.account_id,
          case when l.amount_minor > 0 then v_amount else 0 end, case when l.amount_minor < 0 then v_amount else 0 end,
          b.currency,
          case when l.amount_minor > 0 then v_amount else 0 end, case when l.amount_minor < 0 then v_amount else 0 end,
          1, left(l.description, 120)),
         (v_tenant, v_journal, 2, p_account_id,
          case when l.amount_minor < 0 then v_amount else 0 end, case when l.amount_minor > 0 then v_amount else 0 end,
          b.currency,
          case when l.amount_minor < 0 then v_amount else 0 end, case when l.amount_minor > 0 then v_amount else 0 end,
          1, btrim(p_narrative));

  insert into erp.bank_entry (tenant_id, bank_account_id, line_id, journal_id, origin, rule_id)
  values (v_tenant, b.id, l.id, v_journal, p_origin, p_rule_id);
  return v_journal;
end;
$$;
revoke all on function erp.raise_bank_entry(uuid, uuid, text, text, uuid) from public, anon;

-- A line posted by the rule that fits it, at once. The caller has authorised.
create or replace function erp.post_bank_line_by_rule_unchecked(p_line_id uuid, p_rule_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_me      uuid := erp.current_principal_id();
  r         erp.bank_rule%rowtype;
  v_journal uuid;
begin
  select x.* into r from erp.bank_rule x where x.tenant_id = v_tenant and x.id = p_rule_id;
  v_journal := erp.raise_bank_entry(p_line_id, r.account_id, format('Bank rule: %s', r.name), 'rule', r.id);
  perform erp.journal_require_sound(v_journal);
  update erp.journal x
     set submitted_at = clock_timestamp(), submitted_by = v_me,
         status = 'posted', posted_at = clock_timestamp(), posted_by = v_me, updated_at = now()
   where x.tenant_id = v_tenant and x.id = v_journal;
  return v_journal;
end;
$$;
revoke all on function erp.post_bank_line_by_rule_unchecked(uuid, uuid) from public, anon;

create or replace function erp.post_bank_line_by_rule(p_line_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_entity  uuid;
  v_rule    uuid;
  v_journal uuid;
begin
  select b.entity_id into v_entity
    from erp.bank_statement_line l join erp.bank_account b on b.tenant_id = l.tenant_id and b.id = l.bank_account_id
   where l.tenant_id = v_tenant and l.id = p_line_id;
  perform erp.authorise('finance.post', v_entity, null, null, 'bank_statement_line', p_line_id, null);
  v_rule := erp.bank_rule_for_line(p_line_id);
  if v_rule is null then
    raise exception 'CLOVEERP_BANK_RULE_NONE: no bank rule in use fits this line'
      using errcode = '23514', hint = 'Match the line, post it by hand for approval, or define a rule for the words the bank prints on it.';
  end if;
  v_journal := erp.post_bank_line_by_rule_unchecked(p_line_id, v_rule);
  return jsonb_build_object('journal_id', v_journal,
                            'rule', (select r.name from erp.bank_rule r where r.id = v_rule));
end;
$$;
revoke all on function erp.post_bank_line_by_rule(uuid) from public, anon;

create or replace function public.erp_post_bank_line_by_rule(p_line_id uuid)
returns jsonb
language sql
set search_path = ''
as $$ select erp.post_bank_line_by_rule(p_line_id) $$;
revoke all on function public.erp_post_bank_line_by_rule(uuid) from public, anon;
grant execute on function public.erp_post_bank_line_by_rule(uuid) to authenticated, service_role;
comment on function public.erp_post_bank_line_by_rule(uuid) is
  'Posts a statement line by the bank rule that fits it, at once, as a journal against the bank (20261013040000). '
  'Authorises finance.post.';

create or replace function erp.apply_bank_rules(p_statement_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.bank_statement%rowtype;
  v_entity uuid;
  r        record;
  v_n      integer := 0;
begin
  select x.* into s from erp.bank_statement x where x.tenant_id = v_tenant and x.id = p_statement_id for update;
  select b.entity_id into v_entity from erp.bank_account b where b.tenant_id = v_tenant and b.id = s.bank_account_id;
  perform erp.authorise('finance.post', v_entity, null, null, 'bank_statement', p_statement_id, null);
  if s.id is null or s.status <> 'imported' then
    raise exception 'CLOVEERP_BANK_ENTRY_NOT_OPEN: only a statement not yet reconciled has its lines posted'
      using errcode = '23514', hint = 'Refresh the statements and choose again.';
  end if;
  for r in
    select l.id, erp.bank_rule_for_line(l.id) as rule_id
      from erp.bank_statement_line l
     where l.tenant_id = v_tenant and l.statement_id = s.id and l.status = 'unmatched'
       and not exists (select 1 from erp.bank_entry be where be.tenant_id = v_tenant and be.line_id = l.id and be.reversed_at is null)
     order by l.line_no
  loop
    if r.rule_id is not null then
      perform erp.post_bank_line_by_rule_unchecked(r.id, r.rule_id);
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('statement_id', s.id, 'posted', v_n,
    'unmatched', (select count(*) from erp.bank_statement_line l
                   where l.tenant_id = v_tenant and l.statement_id = s.id and l.status = 'unmatched'));
end;
$$;
revoke all on function erp.apply_bank_rules(uuid) from public, anon;

create or replace function public.erp_apply_bank_rules(p_statement_id uuid)
returns jsonb
language sql
set search_path = ''
as $$ select erp.apply_bank_rules(p_statement_id) $$;
revoke all on function public.erp_apply_bank_rules(uuid) from public, anon;
grant execute on function public.erp_apply_bank_rules(uuid) to authenticated, service_role;
comment on function public.erp_apply_bank_rules(uuid) is
  'Posts every unmatched line of a statement a bank rule fits, at once, each as a journal against the bank '
  '(20261013040000). Authorises finance.post.';

create or replace function erp.propose_bank_entry(p_line_id uuid, p_account_id uuid, p_narrative text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_entity  uuid;
  v_journal uuid;
begin
  select b.entity_id into v_entity
    from erp.bank_statement_line l join erp.bank_account b on b.tenant_id = l.tenant_id and b.id = l.bank_account_id
   where l.tenant_id = v_tenant and l.id = p_line_id;
  perform erp.authorise('finance.post', v_entity, null, null, 'bank_statement_line', p_line_id, null);
  if nullif(btrim(coalesce(p_narrative, '')), '') is null then
    raise exception 'CLOVEERP_BANK_ENTRY_NEEDS_A_NARRATIVE: an entry made by hand needs a narrative'
      using errcode = '23514', hint = 'Say what the money was, so whoever approves it can judge it.';
  end if;
  v_journal := erp.raise_bank_entry(p_line_id, p_account_id, p_narrative, 'hand', null);
  perform erp.submit_journal(v_journal);
  return jsonb_build_object('journal_id', v_journal, 'waiting', true);
end;
$$;
revoke all on function erp.propose_bank_entry(uuid, uuid, text) from public, anon;

create or replace function public.erp_propose_bank_entry(p_line_id uuid, p_account_id uuid, p_narrative text)
returns jsonb
language sql
set search_path = ''
as $$ select erp.propose_bank_entry(p_line_id, p_account_id, p_narrative) $$;
revoke all on function public.erp_propose_bank_entry(uuid, uuid, text) from public, anon;
grant execute on function public.erp_propose_bank_entry(uuid, uuid, text) to authenticated, service_role;
comment on function public.erp_propose_bank_entry(uuid, uuid, text) is
  'Raises and submits the journal that posts a statement line by hand, to be approved on the Journals screen by '
  'somebody else who may approve journals (20261013040000). Authorises finance.post.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Receiving cash from a line
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.receive_bank_line(p_line_id uuid, p_party_id uuid, p_invoice_ids uuid[],
                                                 p_amounts_minor bigint[] default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.bank_statement_line%rowtype;
  b        erp.bank_account%rowtype;
  v_docs   uuid[];
  v_items  uuid[];
  v_id     uuid;
begin
  select x.* into l from erp.bank_statement_line x where x.tenant_id = v_tenant and x.id = p_line_id for update;
  select x.* into b from erp.bank_account x where x.tenant_id = v_tenant and x.id = l.bank_account_id;
  perform erp.authorise('finance.post', b.entity_id, null, null, 'bank_statement_line', p_line_id, null);
  if l.id is null or l.amount_minor <= 0 or b.account_id is distinct from erp.company_bank_account(b.entity_id) then
    raise exception 'CLOVEERP_BANK_RECEIPT_INVALID: only money in, on the bank account receipts land in, is received from a line'
      using errcode = '23514', hint = 'Receipts are banked in the company''s default bank account. Match a line of another account to a receipt there, or make that account the default.';
  end if;
  if l.status <> 'unmatched'
     or exists (select 1 from erp.bank_entry be where be.tenant_id = v_tenant and be.line_id = l.id and be.reversed_at is null) then
    raise exception 'CLOVEERP_BANK_ENTRY_NOT_OPEN: only an unmatched line of a statement not yet reconciled, with no entry waiting, is posted'
      using errcode = '23514', hint = 'Refresh the statement: the line may be matched, posted, or waiting for its entry''s approval.';
  end if;

  -- The cash, dated the day the bank booked it, with the bank's words as the
  -- customer's reference; what the invoices chosen do not take stays on the
  -- customer's account, banked all the same.
  select array_agg(distinct c.document_id) into v_docs
    from erp.apply_cash(p_party_id, l.amount_minor, b.currency,
                        left(concat_ws(' ', l.description, l.reference), 80), l.booked_on,
                        p_invoice_ids, p_amounts_minor) c
   where c.document_id is not null;
  select array_agg(si.id) into v_items
    from erp.subledger_item si
    join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
   where si.tenant_id = v_tenant and si.control_kind = 'bank' and si.control_account_id = b.account_id
     and j.document_id = any (v_docs)
     and not exists (select 1 from erp.bank_match_item m where m.tenant_id = v_tenant and m.subledger_item_id = si.id);
  v_id := erp.make_bank_match(b.id, array[l.id], v_items, 'receipt', null);
  return jsonb_build_object('match_id', v_id,
                            'receipts', (select jsonb_agg(d.document_number order by d.document_number)
                                           from erp.document d where d.tenant_id = v_tenant and d.id = any (v_docs)));
end;
$$;
revoke all on function erp.receive_bank_line(uuid, uuid, uuid[], bigint[]) from public, anon;

create or replace function public.erp_receive_bank_line(p_line_id uuid, p_party_id uuid, p_invoice_ids uuid[],
                                                        p_amounts_minor bigint[] default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.receive_bank_line(p_line_id, p_party_id, p_invoice_ids, p_amounts_minor) $$;
revoke all on function public.erp_receive_bank_line(uuid, uuid, uuid[], bigint[]) from public, anon;
grant execute on function public.erp_receive_bank_line(uuid, uuid, uuid[], bigint[]) to authenticated, service_role;
comment on function public.erp_receive_bank_line(uuid, uuid, uuid[], bigint[]) is
  'Receives a money-in statement line as cash from a customer against the invoices chosen, dated the day the bank '
  'booked it, and matches the line to the receipt (20261013040000). Authorises finance.post.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Card fees, and the payout matched whole
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.settlement_statement add column if not exists fee_journal_id uuid references erp.journal(id) on delete restrict;
comment on column erp.settlement_statement.fee_journal_id is
  'The journal that posted the statement''s fees against the bank when it was applied (20261013040000).';

create or replace function erp.post_settlement_fees(p_statement_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  st        erp.settlement_statement%rowtype;
  v_ledger  erp.ledger%rowtype;
  v_rule    uuid;
  v_version integer;
  v_account uuid;
  v_bank    uuid;
  v_event   uuid;
  v_journal uuid;
  v_on      date;
begin
  -- The provider's fees on a statement being applied (20261013040000):
  -- Dr settlement differences, Cr bank, so the bank holds what the provider
  -- paid out and not the gross. The caller has authorised.
  select x.* into st from erp.settlement_statement x where x.tenant_id = v_tenant and x.id = p_statement_id;
  if coalesce(st.fee_minor, 0) <= 0 or st.fee_journal_id is not null then
    return st.fee_journal_id;
  end if;

  select lg.* into v_ledger from erp.ledger lg
   where lg.tenant_id = v_tenant and lg.entity_id = st.entity_id and lg.is_primary and lg.status = 'active';
  select pr.id, pr.version into v_rule, v_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'settlement_difference' and pr.status = 'active'
     and (pr.entity_id is null or pr.entity_id = st.entity_id)
   order by pr.version desc limit 1;
  v_account := erp.settlement_difference_account(st.entity_id);
  v_bank := erp.company_bank_account(st.entity_id);
  if v_ledger.id is null or v_rule is null or v_account is null or v_bank is null then
    raise exception 'CLOVEERP_SETTLEMENT_FEES_NOT_POSTABLE: the company has no settlement difference rule, account or bank account to post the fees to'
      using errcode = '23503',
            hint = 'Upgrade finance posting to version 3: it installs the settlement_difference rule and the 7900 account.';
  end if;
  perform erp.require_cash_in_ledger_currency(v_ledger.id, st.currency);
  v_on := least(st.statement_date, current_date);

  v_event := erp.append_event(
    'settlement.fees_posted', 'posting', st.id,
    jsonb_build_object('provider', st.provider_code, 'statement_ref', st.statement_ref,
                       'posting_rule', 'settlement_difference', 'value_minor', st.fee_minor, 'currency', st.currency),
    st.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, reference, status)
  values (v_tenant, st.entity_id, v_ledger.id, 'settlement.fees_posted', v_event, v_on,
          format('Card fees %s %s', st.provider_code, st.statement_ref), st.statement_ref, 'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, v_account, st.fee_minor, 0, st.currency, st.fee_minor, 0, 1,
          v_rule, v_version, v_event, 'card fees the provider kept'),
         (v_tenant, v_journal, 2, v_bank, 0, st.fee_minor, st.currency, 0, st.fee_minor, 1,
          v_rule, v_version, v_event, 'bank');

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
  values (v_tenant, st.entity_id, v_ledger.id, 'bank', v_bank, null, null, v_journal, st.currency, 0, st.fee_minor, v_on);

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;
  update erp.settlement_statement set fee_journal_id = v_journal, updated_at = now()
   where tenant_id = v_tenant and id = st.id;
  return v_journal;
end;
$$;
revoke all on function erp.post_settlement_fees(uuid) from public, anon;

do $apply$
declare
  v_sig  constant text := 'erp.apply_settlement_statement(uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  update erp.settlement_statement
     set status = 'applied', applied_at = now(), applied_by = erp.current_principal_id(), updated_at = now()$o$;
  v_new  constant text := $n$  -- The provider's fees, posted against the bank, which then holds what it
  -- paid out (20261013040000; this reverses D14, which recorded the fees and
  -- posted none).
  perform erp.post_settlement_fees(st.id);

  update erp.settlement_statement
     set status = 'applied', applied_at = now(), applied_by = erp.current_principal_id(), updated_at = now()$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position('post_settlement_fees' in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % applied anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$apply$;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('settlement.fees_posted', 1, 'posting', 'finance', 'event.settlement.fees_posted',
   'A card provider''s fees on a settlement statement were posted against the bank as the statement was applied.',
   '{"type":"object","required":["provider","statement_ref","value_minor","currency"],"properties":{"provider":{"type":"string"},"statement_ref":{"type":"string"},"posting_rule":{"type":"string"},"value_minor":{"type":"integer"},"currency":{"type":"string"}}}'::jsonb, true)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('event.settlement.fees_posted', 'en', 'Card fees posted', 'finance',
   'Event raised when a card provider''s fees are posted against the bank as its settlement statement is applied.'),
  ('event.settlement.fees_posted', 'de', 'Kartengebühren gebucht', 'finance',
   'Ereignis, wenn die Gebühren eines Kartenanbieters bei der Anwendung seiner Abrechnung gegen die Bank gebucht werden.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- What the books hold, now with a card provider's statement whole: its
-- receipts less its fees, the payout the bank shows.
create or replace function erp.bank_book_entries(p_bank_account_id uuid)
returns table(entry_key text, kind text, item_ids uuid[], amount_minor bigint, posted_on date,
              numbers text[], label text)
language sql
stable
set search_path = ''
as $$
  -- The bank items of the account's ledger account no line has matched, of
  -- posted journals not reversed (20261013030000). Money in is a debit of the
  -- bank, as it is a positive line of the bank's statement. A card provider's
  -- statement gathers its receipts and its fees (20261013040000).
  with b as (
    select x.* from erp.bank_account x
     where x.tenant_id = erp.current_tenant_id() and x.id = p_bank_account_id
  ), items as (
    select s.id, s.debit_minor - s.credit_minor as net, s.posting_date, s.journal_id,
           j.document_id, j.description, j.reference as journal_reference,
           d.document_number, d.our_reference, d.their_reference, d.party_id,
           nullif(d.attributes ->> 'payment_proposal_id', '') as run_key,
           coalesce(nullif(d.attributes ->> 'settlement_statement_id', ''),
                    (select ss.id::text from erp.settlement_statement ss
                      where ss.tenant_id = j.tenant_id and ss.fee_journal_id = j.id)) as settlement_key
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
    union all
    -- A card provider's statement whole: its receipts and its fees.
    select 'settlement:' || i.settlement_key, 'settlement',
           array_agg(i.id order by i.id), sum(i.net)::bigint, max(i.posting_date),
           array_remove(array[(select ss.statement_ref from erp.settlement_statement ss
                                where ss.tenant_id = erp.current_tenant_id() and ss.id::text = i.settlement_key),
                              (select ss.provider_code from erp.settlement_statement ss
                                where ss.tenant_id = erp.current_tenant_id() and ss.id::text = i.settlement_key)], null),
           null,
           (select format('%s %s', ss.provider_code, ss.statement_ref) from erp.settlement_statement ss
             where ss.tenant_id = erp.current_tenant_id() and ss.id::text = i.settlement_key)
      from items i
     where i.settlement_key is not null
     group by i.settlement_key
    having count(*) > 1
  )
  select e.entry_key, e.kind, e.item_ids, e.amount_minor, e.posted_on, e.numbers,
         concat_ws(' · ', (select pt.name from erp.party pt
                            where pt.tenant_id = erp.current_tenant_id() and pt.id::text = e.party_id),
                   e.description)
    from entries e
   where e.amount_minor <> 0
$$;
revoke all on function erp.bank_book_entries(uuid) from public, anon;

-- Auto-matching takes a card provider's payout too: the one candidate at its
-- amount within seven days.
do $auto$
declare
  v_sig  constant text := 'erp.auto_match_bank_statement(uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$                 when 'payment_run' then e.kind in ('payment', 'payment_run') and abs(e.posted_on - l.booked_on) <= 5$o$;
  v_new1 constant text := $n$                 when 'payment_run' then (e.kind in ('payment', 'payment_run') and abs(e.posted_on - l.booked_on) <= 5)
                                       -- A card provider's payout (20261013040000).
                                       or (e.kind = 'settlement' and abs(e.posted_on - l.booked_on) <= 7)$n$;
  v_old2 constant text := $o$        select p.*, count(*) over (partition by p.line_id) as for_line,$o$;
  v_new2 constant text := $n$        select p.*, (select e.kind from _bank_entries e where e.entry_key = p.entry_key limit 1) as kind,
               count(*) over (partition by p.line_id) as for_line,$n$;
  v_old3 constant text := $o$      select x.line_id, x.item_ids from sure x where x.for_line = 1 and x.for_entry = 1 order by x.line_no$o$;
  v_new3 constant text := $n$      select x.line_id, x.item_ids, x.kind from sure x where x.for_line = 1 and x.for_entry = 1 order by x.line_no$n$;
  v_old4 constant text := $o$        perform erp.make_bank_match(b.id, array[r.line_id], r.item_ids, v_pass, null);
        v_counts := jsonb_set(v_counts, array[v_pass], to_jsonb((v_counts ->> v_pass)::integer + 1));$o$;
  v_new4 constant text := $n$        perform erp.make_bank_match(b.id, array[r.line_id], r.item_ids,
                                    case when r.kind = 'settlement' then 'settlement' else v_pass end, null);
        v_counts := jsonb_set(v_counts, array[case when r.kind = 'settlement' then 'settlement' else v_pass end],
                              to_jsonb(coalesce((v_counts ->> case when r.kind = 'settlement' then 'settlement' else v_pass end)::integer, 0) + 1));$n$;
  v_old5 constant text := $o$  v_counts jsonb := '{"reference":0,"payment_run":0,"amount_date":0}'::jsonb;$o$;
  v_new5 constant text := $n$  v_counts jsonb := '{"reference":0,"payment_run":0,"settlement":0,"amount_date":0}'::jsonb;$n$;
  v_old  text;
  i      integer;
begin
  if position('20261013040000' in v_def) > 0 then
    return;
  end if;
  for i in 1..5 loop
    v_old := (array[v_old1, v_old2, v_old3, v_old4, v_old5])[i];
    if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, i,
        (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    end if;
    v_def := replace(v_def, v_old, (array[v_new1, v_new2, v_new3, v_new4, v_new5])[i]);
  end loop;
  execute v_def;
end
$auto$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. What each line says
-- ─────────────────────────────────────────────────────────────────────────────

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
                      where ml.tenant_id = l.tenant_id and ml.line_id = l.id),
           -- The entry that posts the line, or waits to (20261013040000).
           'entry', (select jsonb_build_object(
                              'journal_id', j.id, 'journal_number', j.journal_number, 'origin', be.origin,
                              'state', erp.journal_state(j.id), 'narrative', j.description,
                              'rule', (select r.name from erp.bank_rule r where r.id = be.rule_id))
                       from erp.bank_entry be
                       join erp.journal j on j.id = be.journal_id
                      where be.tenant_id = l.tenant_id and be.line_id = l.id and be.reversed_at is null),
           -- The rule that would post it, while it waits for something.
           'rule', case when l.status = 'unmatched'
                         and not exists (select 1 from erp.bank_entry be
                                          where be.tenant_id = l.tenant_id and be.line_id = l.id and be.reversed_at is null)
                        then (select r.name from erp.bank_rule r where r.id = erp.bank_rule_for_line(l.id)) end
         ) order by l.line_no), '[]'::jsonb)
    from erp.bank_statement_line l
   where l.tenant_id = erp.current_tenant_id() and l.statement_id = p_statement_id
$$;
revoke all on function public.erp_bank_statement_lines(uuid) from public, anon;
grant execute on function public.erp_bank_statement_lines(uuid) to authenticated, service_role;
comment on function public.erp_bank_statement_lines(uuid) is
  'The lines of one bank statement, in the bank''s order, with what each was matched to, the entry that posts it or '
  'waits to, and the rule that would post it (20261013020000, 20261013030000, 20261013040000). Reads only.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Governance
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_define_bank_rule', 'erp.define_bank_rule',
   'Defines a bank rule: the words a statement line quotes and the account it posts to; authorises finance.configure.'),
  ('erp_retire_bank_rule', 'erp.retire_bank_rule',
   'Retires a bank rule with a reason; authorises finance.configure.'),
  ('erp_post_bank_line_by_rule', 'erp.post_bank_line_by_rule',
   'Posts a statement line by the bank rule that fits it, as a journal against the bank; authorises finance.post.'),
  ('erp_apply_bank_rules', 'erp.apply_bank_rules',
   'Posts every unmatched line of a statement a bank rule fits; authorises finance.post.'),
  ('erp_propose_bank_entry', 'erp.propose_bank_entry',
   'Raises and submits the journal posting a statement line by hand, for somebody else to approve; authorises finance.post.'),
  ('erp_receive_bank_line', 'erp.receive_bank_line',
   'Receives a money-in statement line as cash from a customer and matches it to the receipt; authorises finance.post.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_BANK_ENTRY_ACCOUNT',
  'Posting a bank line, or defining a rule, to an account a bank entry does not post to.',
  'The bank, debtors, creditors and VAT are kept by their own ledgers; a summary, statistical or retired account takes no posting.',
  'Choose a postable account in use of the company that no ledger keeps.');
select erp.register_refusal('CLOVEERP_BANK_ENTRY_NOT_OPEN',
  'Posting a line that is matched, posted, waiting for its entry''s approval, or on a reconciled statement.',
  'A line is posted once; a second entry would put the money in the books twice.',
  'Refresh the statement and act on what it shows for the line.');
select erp.register_refusal('CLOVEERP_BANK_ENTRY_NEEDS_A_NARRATIVE',
  'Posting a bank line by hand without saying what the money was.',
  'Whoever approves the entry judges it by its narrative.',
  'Say what the money was.');
select erp.register_refusal('CLOVEERP_BANK_ENTRY_CHANGED',
  'Posting a bank entry''s journal whose bank line no longer moves the bank by the statement line''s amount.',
  'The entry says the books now hold the line; a different amount would leave the bank and the books apart.',
  'Discard the journal and post the line again from the Bank screen.');
select erp.register_refusal('CLOVEERP_BANK_ENTRY_POSTED',
  'Unmatching a line a bank entry posted.',
  'The match is the entry''s journal; taking it away would leave a journal posting a line that is no longer there.',
  'Reverse the entry''s journal on the Journals screen; the line is free again once the reversal is approved.');
select erp.register_refusal('CLOVEERP_BANK_RULE_NONE',
  'Posting a line by rule when no rule in use fits it.',
  'A rule posts a line only on the words it quotes and the direction of its money.',
  'Match the line, post it by hand for approval, or define a rule for its words.');
select erp.register_refusal('CLOVEERP_BANK_RULE_INVALID',
  'Defining a bank rule without a name, words a line can quote or a direction, or for a bank account of another company; retiring one not in use.',
  'A rule nobody can read, or that fits nothing it could post, is a rule that posts the wrong line.',
  'Give the rule a name, the words the bank prints, money in, out or either, and an open bank account of the same company or none.');
select erp.register_refusal('CLOVEERP_BANK_RULE_RETIRE_NEEDS_A_REASON',
  'Retiring a bank rule without a reason.',
  'The next reader of the rules needs to know why one stopped applying.',
  'Say why the rule no longer applies.');
select erp.register_refusal('CLOVEERP_BANK_RECEIPT_INVALID',
  'Receiving cash from a money-out line, or from a line of a bank account receipts do not land in.',
  'A receipt is banked in the company''s default bank account; recording it against another would put the money in the wrong account.',
  'Match the line to a receipt in the default account, or make its account the default.');
select erp.register_refusal('CLOVEERP_SETTLEMENT_FEES_NOT_POSTABLE',
  'Applying a card settlement statement with fees in a company with no settlement difference rule, account or bank account.',
  'The fees are posted against the bank so it holds what the provider paid out; without an account for them the bank would hold the gross.',
  'Upgrade finance posting to version 3, which installs the settlement_difference rule and the 7900 account.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Posting a bank line (20261013040000).'
  from (values
    ('Bank rules'),
    ('A line that quotes a rule''s words posts to its account when you press Apply the rules, or Post by rule on the line. The lowest priority applies first.'),
    ('No bank rule yet.'),
    ('Define a rule'),
    ('Define a bank rule'),
    ('Rule name'),
    ('Shown on the line and on the journal it posts.'),
    ('Account fee'),
    ('Words on the line'),
    ('ACCOUNT FEE'),
    ('The words the bank prints on the line, as a whole word or words. Case and punctuation do not matter.'),
    ('Posts to'),
    ('Money'),
    ('In'),
    ('Out'),
    ('Either'),
    ('Only on this bank account'),
    ('Leave empty for every bank account of the company.'),
    ('Priority'),
    ('The lowest applies first when two rules fit a line.'),
    ('Retire'),
    ('Retire this rule'),
    ('Entries it posted stand. Lines it would have posted wait for a person or another rule.'),
    ('Why it is retired'),
    ('The bank stopped charging this fee'),
    ('Kept with the rule.'),
    ('Apply the rules'),
    ('Lines posted by rule'),
    ('No line fits a rule.'),
    ('Post by rule'),
    ('Receive cash'),
    ('Receive cash from this line'),
    ('The line is applied as cash from the customer against the invoices you tick, dated the day the bank booked it. What they do not take stays on the customer''s account.'),
    ('Customer'),
    ('Invoices'),
    ('Tick the invoices this money pays.'),
    ('This customer owes nothing in this currency.'),
    ('Post by hand'),
    ('Post this line by hand'),
    ('The line is posted against the account you choose once somebody else who may approve journals approves it on the Journals screen. A bank entry carries no VAT: a line with VAT on it is a supplier''s bill and its payment.'),
    ('Post to'),
    ('What was the money?'),
    ('Interest paid by the bank for September'),
    ('Whoever approves it reads this.'),
    ('Submit for approval'),
    ('Rule'),
    ('Entry'),
    ('Waiting for approval'),
    ('Posted'),
    ('Sent back'),
    ('Card settlement')) v(text)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.bank_entry_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
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
  v_bank   uuid;
  v_bank_acct uuid;
  v_fees   uuid;
  v_income uuid;
  v_ctrl   uuid;
  v_inv    uuid;
  v_cust   uuid;
  v_inv2   uuid;
  v_st     uuid;
  v_ln     uuid[];
  v_j1     uuid;
  v_j2     uuid;
  v_rev    uuid;
  v_batch  uuid;
  v_set    uuid;
  v_net    bigint;
  x        jsonb;
  v_ok     boolean;
  v_msg    text;
  v_gl0    bigint;
  n        integer;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzbet' || v_tag, 'Bank Entry Suite',
      'admin@demo-zzbet' || v_tag || '.test', 'Entry Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@demo-zzbet' || v_tag || '.test'), (a2, 'second@demo-zzbet' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('second@demo-zzbet' || v_tag || '.test', 'Second Admin');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_tenant := rb.tenant_id;

    v_step := 'the company, its bank, and accounts to post to';
    select e.id, e.base_currency into v_ent, v_ccy from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select b.id, b.account_id into v_bank, v_bank_acct from erp.bank_account b
     where b.tenant_id = v_tenant and b.entity_id = v_ent and b.is_default;
    v_fees := erp.settlement_difference_account(v_ent);
    select a.id into v_income from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_ent and a.account_type::text = 'income'
       and a.is_postable and a.control_kind is null and a.status = 'active' order by a.code limit 1;
    select a.id into v_ctrl from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_ent and a.control_kind::text = 'receivable' order by a.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = v_tenant order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (v_tenant, 'ZBEWID', 'Bank Entry Widget', v_uom, 'active') returning id into v_item;
    v_inv := erp_test.cash_tolerance_customer_invoice(v_ent, v_site, v_item, v_ccy, 'ZBE1' || v_tag, 50000);
    select d.party_id into v_cust from erp.document d where d.id = v_inv;

    v_step := 'a statement: a fee, interest, a customer''s payment, a card payout, and a fee of another kind';
    x := public.erp_import_bank_statement(v_bank, 'csv', 'natwest', md5('e1' || v_tag) || md5('e1b' || v_tag),
           -1250 + 300 + 20000 - 999,
           jsonb_build_array(
             jsonb_build_object('booked_on', current_date, 'amount_minor', -1250, 'description', 'MONTHLY ACCOUNT FEE'),
             jsonb_build_object('booked_on', current_date, 'amount_minor', 300, 'description', 'GROSS INTEREST'),
             jsonb_build_object('booked_on', current_date, 'amount_minor', 20000, 'description', 'ACME PAYMENT'),
             jsonb_build_object('booked_on', current_date, 'amount_minor', -999, 'description', 'UNKNOWN DEBIT')),
           0);
    v_st := (x ->> 'statement_id')::uuid;
    select array_agg(l.id order by l.line_no) into v_ln from erp.bank_statement_line l where l.statement_id = v_st;

    -- ── 1. A rule posts at once ─────────────────────────────────────────────
    v_step := 'a rule for the fee, applied';
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_gl0
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id
     where jl.tenant_id = v_tenant and jl.account_id = v_bank_acct and j.status = 'posted';
    perform public.erp_define_bank_rule('Account fee', 'account fee', v_fees, 'out');
    x := public.erp_apply_bank_rules(v_st);
    select be.journal_id into v_j1 from erp.bank_entry be where be.line_id = v_ln[1];
    v_cases := v_cases + 1;
    case_name := 'a rule posts the line it fits at once: the journal, the bank''s item, and the line posted';
    passed := v_state is null and (x ->> 'posted')::integer = 1
          and erp.journal_state(v_j1) = 'posted'
          and (select l.status from erp.bank_statement_line l where l.id = v_ln[1]) = 'posted'
          and exists (select 1 from erp.subledger_item si where si.journal_id = v_j1 and si.control_kind = 'bank' and si.credit_minor = 1250)
          and (select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) from erp.journal_line jl join erp.journal j on j.id = jl.journal_id
                where jl.tenant_id = v_tenant and jl.account_id = v_bank_acct and j.status = 'posted') = v_gl0 - 1250;
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 2. What a rule and an entry refuse ──────────────────────────────────
    v_step := 'rules refused';
    begin
      perform public.erp_define_bank_rule('Debtors', 'acme', v_ctrl, 'in');
      v_ok := false; v_msg := 'a rule to debtors';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_BANK_ENTRY_ACCOUNT%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform public.erp_post_bank_line_by_rule(v_ln[4]);
      v_ok := false; v_msg := v_msg || ' | posted with no rule';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_RULE_NONE%'; v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    begin
      perform public.erp_unmatch_bank_line(v_ln[1], 'wrong');
      v_ok := false; v_msg := v_msg || ' | a posted line unmatched';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_ENTRY_POSTED%'; v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    v_cases := v_cases + 1;
    case_name := 'a rule to a ledger''s control account, a line no rule fits, and unmatching a posted line are refused';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 3. By hand: waits for somebody else ─────────────────────────────────
    v_step := 'interest posted by hand, once the organisation is live';
    perform erp.set_config_value('approval.administrator_override', '{"allowed": false}'::jsonb,
                                 null, current_date, null, null, 'bank entry suite: an entry needs a second person');
    update erp.environment set is_live = true where tenant_id = v_tenant and is_self;
    x := public.erp_propose_bank_entry(v_ln[2], v_income, 'Interest paid by the bank');
    v_j2 := (x ->> 'journal_id')::uuid;
    begin
      perform public.erp_approve_journal(v_j2);
      v_ok := false; v_msg := 'approved by its own author';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_JOURNAL_SELF_APPROVAL%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      perform public.erp_receive_bank_line(v_ln[2], v_cust, array[v_inv]);
      v_ok := false; v_msg := v_msg || ' | received while waiting';
    exception when others then
      v_ok := v_ok and sqlerrm like 'CLOVEERP_BANK_ENTRY_NOT_OPEN%'; v_msg := v_msg || ' | ' || left(sqlerrm, 60);
    end;
    v_cases := v_cases + 1;
    case_name := 'an entry made by hand waits, its line unmatched and matched by nothing else, and its author cannot approve it';
    passed := v_state is null and v_ok and erp.journal_state(v_j2) = 'submitted'
          and (select l.status from erp.bank_statement_line l where l.id = v_ln[2]) = 'unmatched'
          and (public.erp_bank_statement_lines(v_st) -> 1 -> 'entry' ->> 'state') = 'submitted';
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 4. Approved by the second person ────────────────────────────────────
    v_step := 'approved by the second person';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform public.erp_approve_journal(v_j2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'approved by somebody else, the entry posts and the line with it';
    passed := v_state is null and erp.journal_state(v_j2) = 'posted'
          and (select l.status from erp.bank_statement_line l where l.id = v_ln[2]) = 'posted'
          and exists (select 1 from erp.subledger_item si where si.journal_id = v_j2 and si.control_kind = 'bank' and si.debit_minor = 300);
    detail := coalesce(v_state, erp.journal_state(v_j2));
    return next;

    -- ── 5. Reversed: the line is free again ─────────────────────────────────
    v_step := 'the interest entry reversed';
    x := public.erp_reverse_journal(v_j2, 'posted to the wrong account', current_date);
    select j.id into v_rev from erp.journal j where j.tenant_id = v_tenant and j.reverses_journal_id = v_j2;
    if erp.journal_state(v_rev) = 'draft' then
      perform erp.submit_journal(v_rev);
    end if;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform public.erp_approve_journal(v_rev);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'reversing the entry''s journal frees the line, and neither journal is offered to match';
    passed := v_state is null
          and (select l.status from erp.bank_statement_line l where l.id = v_ln[2]) = 'unmatched'
          and (select be.reversed_at is not null from erp.bank_entry be where be.journal_id = v_j2)
          and not exists (select 1 from erp.bank_match_line ml where ml.line_id = v_ln[2])
          and (select count(*) from erp.bank_book_entries(v_bank) e
                where e.entry_key in ('journal:' || v_j2, 'journal:' || v_rev)) = 0
          and exists (select 1 from erp.subledger_item si where si.journal_id = v_rev and si.control_kind = 'bank' and si.credit_minor = 300);
    detail := coalesce(v_state, coalesce(erp.journal_state(v_rev), 'no reversal'));
    return next;

    -- ── 6. Cash received from a line ────────────────────────────────────────
    v_step := 'the customer''s payment received from its line';
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    x := public.erp_receive_bank_line(v_ln[3], v_cust, array[v_inv]);
    v_cases := v_cases + 1;
    case_name := 'a money-in line received as cash against the invoice is matched to the receipt, dated as the bank booked it';
    passed := v_state is null
          and (select m.method from erp.bank_match_line ml join erp.bank_match m on m.id = ml.match_id where ml.line_id = v_ln[3]) = 'receipt'
          and jsonb_array_length(x -> 'receipts') = 1
          and exists (select 1 from erp.subledger_item si
                       where si.tenant_id = v_tenant and si.document_id = v_inv and si.control_kind = 'receivable'
                         and si.credit_minor = 20000 and si.posting_date = current_date);
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 7. A card payout: fees posted, the statement matched whole ──────────
    v_step := 'a card settlement statement with fees, applied';
    v_inv2 := erp.create_document('sales_invoice', v_ent, v_site, v_cust, current_date, v_ccy, 'ZBE-CARD', '{}'::jsonb);
    perform erp.add_document_line(v_inv2, v_item, 1, 10000, 'a card sale');
    perform erp.transition_document(v_inv2, 'issue', 'bank entry suite');
    v_batch := erp.stage_import('settlement_statement', jsonb_build_array(
      jsonb_build_object('provider', 'stripe', 'statement_ref', 'ZBE-ST-' || v_tag, 'statement_date', current_date, 'currency', v_ccy,
                         'reference', (select d.document_number from erp.document d where d.id = v_inv2),
                         'amount_minor', 9000, 'fee_minor', 180, 'occurred_on', current_date)), 'ZBE-SET');
    perform erp.validate_import(v_batch);
    perform erp.preview_import(v_batch);
    perform erp.load_import(v_batch);
    select s.id into v_set from erp.settlement_statement s where s.tenant_id = v_tenant and s.statement_ref = 'ZBE-ST-' || v_tag;
    perform public.erp_reconcile_settlement_statement(v_set);
    perform public.erp_apply_settlement_statement(v_set);
    x := public.erp_import_bank_statement(v_bank, 'csv', 'natwest', md5('e2' || v_tag) || md5('e2b' || v_tag),
           -1250 + 300 + 20000 - 999 + 8820,
           jsonb_build_array(jsonb_build_object('booked_on', current_date, 'amount_minor', 8820, 'description', 'STRIPE PAYOUT')));
    x := public.erp_auto_match_bank_statement((x ->> 'statement_id')::uuid);
    v_cases := v_cases + 1;
    case_name := 'a card statement''s fees post against the bank, and its payout matches the statement whole';
    passed := v_state is null
          and (select s.fee_journal_id is not null from erp.settlement_statement s where s.id = v_set)
          and exists (select 1 from erp.subledger_item si join erp.settlement_statement s on s.fee_journal_id = si.journal_id
                       where s.id = v_set and si.control_kind = 'bank' and si.credit_minor = 180)
          and exists (select 1 from erp.journal_line jl join erp.settlement_statement s on s.fee_journal_id = jl.journal_id
                       where s.id = v_set and jl.account_id = v_fees and jl.debit_minor = 180)
          and (x ->> 'settlement')::integer = 1;
    detail := coalesce(v_state, x::text);
    return next;

    -- ── 8. The lines say it ─────────────────────────────────────────────────
    v_cases := v_cases + 1;
    x := public.erp_bank_statement_lines(v_st);
    case_name := 'the lines say which entry posted each, by which rule, and which rule would post a line still waiting';
    passed := v_state is null
          and x -> 0 -> 'entry' ->> 'rule' = 'Account fee' and x -> 0 -> 'entry' ->> 'state' = 'posted'
          and x -> 1 -> 'entry' = 'null'::jsonb and x -> 1 ->> 'rule' is null
          and x -> 3 ->> 'rule' is null
          and (select count(*) from jsonb_array_elements(public.erp_bank_rules()) r where r ->> 'name' = 'Account fee') = 1;
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
    raise exception 'CLOVEERP_BANK_ENTRY_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.bank_entry_suite() from public, anon, authenticated;

create or replace function erp_test.assert_bank_entry_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _bank_entry on commit drop as
    select * from erp_test.bank_entry_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _bank_entry;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_BANK_ENTRY_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_BANK_ENTRY_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('bank entries: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_bank_entry_suite() from public, anon, authenticated;

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
