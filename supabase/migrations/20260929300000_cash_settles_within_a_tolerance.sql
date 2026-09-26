set lock_timeout = '30s';

-- =============================================================================
-- 20260929300000  Cash settles within a tolerance, and what it overpays is kept
-- -----------------------------------------------------------------------------
-- PR12, M3 (docs/spec/simplification-review.md §7, node F3): a settlement
-- tolerance on all three cash routes, an account and a rule for the
-- difference it writes off, an overpayment that lands on the customer's
-- account instead of being refused or dropped, and cash in a currency the
-- customer owes nothing in refused. On top of M4 (20260929100000), whose
-- erp.settle_paid_document() already moves an invoice paid in part to
-- part_paid and one that owes nothing to paid. Decisions D6 to D10, D13 and
-- D14 as taken on 26 September.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- On a database built from main (PR12 scoping, E1 and E3):
--
--   * A receipt one penny short of an invoice left the invoice open for the
--     penny, for ever, and one penny over through the item route was refused
--     (CLOVEERP_CASH_EXCEEDS_OWING). Nothing anywhere wrote a difference off.
--   * erp.apply_cash(), the desk's Apply cash, banked only what the
--     customer's invoices owed and returned the rest as "remaining": no
--     journal, no credit. 999,999.99 received against 4,941.71 owed banked
--     4,941.71, and the bank then disagreed with the bank statement.
--   * The refusal's hint sent the rest "as unallocated cash through
--     erp_apply_cash()", which did not exist.
--   * Apply cash offered EUR and USD. EUR cash for a GBP customer returned
--     applied 0 and posted nothing, with no refusal.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * A setting, finance.settlement_tolerance, per organisation or company:
--     { "write_off_max_minor": n, "write_off_pct": p }. A difference inside
--     EITHER limit is inside (the C5 lesson). The percentage is of the item's
--     own amount for a short payment and of what the receipt applied for an
--     overpayment, rounded down to the penny, so it never rounds in anybody's
--     favour. The product default is 0 and 0, so an organisation configured
--     before this changes nothing (D6); finance's installer writes £1 (100
--     minor units, 0 %) for an organisation configured from now on.
--   * An account purpose, settlement_difference (7900 in both charts, an
--     expense, created by the installer; D13), and a posting rule of the same
--     name on event cash.settlement_difference_posted, shipped by finance-posting
--     version 3. An organisation already live takes both through Upgrade.
--     Until the rule is in force and the company holds the account the
--     tolerance reads nought whatever is set: nothing is written off to an
--     account that is not there.
--   * The three cash routes share four routines: erp.settlement_tolerance()
--     and erp.settlement_tolerance_minor() read the limit,
--     erp.post_settlement_difference() writes a difference off and
--     erp.post_cash_on_account() keeps an overpayment on the customer's
--     account. erp.company_bank_account() and
--     erp.require_cash_in_ledger_currency() are the checks each made alone.
--       - Short by no more than the tolerance: the receipt is posted, then a
--         second journal writes the residue off (Dr settlement difference,
--         Cr receivable; for a bill Dr payable, Cr settlement difference)
--         and settles the item, so erp.settle_paid_document() finds nothing
--         owed and the invoice reaches paid, not part_paid. At most once per
--         item: the write-off closes it.
--       - Over by no more than the tolerance: what is owed is applied and the
--         excess is credited to settlement difference (Dr bank).
--       - Over by more: what is owed is applied and the excess is kept on the
--         customer's account, Cr receivable with no document, the unallocated
--         credit erp.ageing_balance already ages (D7). The bank is debited
--         with the whole receipt.
--   * erp.apply_cash() banks the whole receipt (D8): oldest first as before,
--     the last item it touched takes the tolerance, and any remainder is a
--     difference or on account. Its last row still says what was left over
--     after the items, in remaining_minor; that amount is now banked.
--   * erp.apply_cash() refuses cash in a currency the customer owes nothing in
--     (CLOVEERP_CASH_CURRENCY_NOT_BOOKED, D9). It also refuses an amount that
--     is not positive, as the item route always did.
--   * erp.apply_cash_to_item() takes an overpayment instead of refusing it,
--     and refuses an item that owes nothing.
--   * erp.pay_payment_run() writes off a bill's residue inside the same
--     tolerance (D14). It still never pays more than a bill owes. Its answer
--     says what it wrote off.
--   * No FX (D10). Every route refuses cash whose currency is not the
--     ledger's (CLOVEERP_NO_TRANSLATION), so the day translation lands this
--     refuses rather than posting at a rate of one.
--   * The refusal a statement line meets when it is for more than its item
--     owes now points at erp_apply_cash(), which does keep the rest.
--   * The desk's Apply cash offers the ledger currency only.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * Cash for a customer who owes nothing at all is refused, not taken on
--     account: an on-account credit is anchored to the company, ledger and
--     control account of an item the customer holds, and a prepayment with
--     none has no company to be banked in. A prepayment is a door of its own.
--   * Nothing allocates an on-account credit to a later invoice. It ages as
--     unallocated, the customer's statement and the ageing carry it, and a
--     person clears it with a journal until allocation is built.
--   * Past remainders erp.apply_cash() dropped cannot be reconstructed: they
--     left no row to find (D8). The release note says so.
--   * The Apply cash result still counts rows; saying "£x on account" is the
--     screens milestone's (M5).
--   * No reason code for a write-off: nobody enters one, and a reason nothing
--     reads is refused by the dead configuration gate.
--   * The demonstration keeps finance-posting version 2 until an Upgrade, as
--     every organisation does: its tolerance is nought either way (D6).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The account
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.chart_account_purpose
  (purpose, name, account_type, control_kind, default_code, statutory_code, installer_creates, note, seq) values
  ('settlement_difference', 'Settlement differences', 'expense', null, '7900', '7900', true,
   'The small differences cash settles within the organisation''s settlement tolerance: a customer '
   'short by pennies, written off, and an overpayment too small to keep on account, credited. The '
   'cash routes post to it through the settlement_difference rule (20260929300000).', 145)
on conflict (purpose) do nothing;

do $purpose$
begin
  if (select count(*) from erp_ref.chart_account_purpose p
       where p.purpose = 'settlement_difference' and p.default_code = '7900'
         and p.statutory_code = '7900' and p.account_type = 'expense' and p.installer_creates) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: settlement_difference is declared already, and not as 20260929300000 declares it';
  end if;
end
$purpose$;

insert into erp_ref.pack_item (pack_code, object_kind, object_key, payload, provenance, seq) values
  ('chart_8_1', 'account', '7900',
   '{"code": "7900", "name": "Settlement differences", "is_postable": true, "account_type": "expense", "close_blocking": false, "reconciliation_required": false}'::jsonb,
   'The differences cash settles within tolerance, in §8.1''s operating expenses band (20260929300000).', 145),
  ('chart_8_1', 'account_determination', 'settlement_difference',
   '{"note": "Settlement differences", "account": "7900", "transaction_type": "settlement_difference"}'::jsonb,
   'The differences cash settles within tolerance, in §8.1''s operating expenses band (20260929300000).', 445)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('interview.account_purpose.settlement_difference', 'en', 'Settlement differences', 'finance',
   'The name of the account purpose for the differences cash settles within tolerance.'),
  ('interview.account_purpose.settlement_difference.note', 'en',
   'Pennies a customer was short, written off, and overpayments too small to keep on account.', 'finance',
   'What the settlement differences account holds.'),
  ('event.cash.settlement_difference_posted', 'en', 'Settlement difference written off', 'finance',
   'Event raised when cash settles an item within the settlement tolerance and the difference posts to the ledger.'),
  ('event.cash.settlement_difference_posted', 'de', 'Zahlungsdifferenz ausgebucht', 'finance',
   'Ereignis, wenn eine Zahlung einen Posten innerhalb der Toleranz ausgleicht und die Differenz gebucht wird.'),
  ('config.finance.settlement_tolerance', 'en', 'Settlement tolerance', 'finance',
   'The name of the finance.settlement_tolerance configuration type.'),
  ('config.finance.settlement_tolerance', 'de', 'Zahlungstoleranz', 'finance',
   'Der Name des Konfigurationstyps finance.settlement_tolerance.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('cash.settlement_difference_posted', 1, 'document', 'finance', 'event.cash.settlement_difference_posted',
        'Cash settled an item within the settlement tolerance, and the difference was written off or credited.',
        '{"type":"object","required":["reference","value_minor","currency"],
          "properties":{"reference":{"type":"string"},"value_minor":{"type":"integer"},
                        "currency":{"type":"string"},"posting_rule":{"type":"string"},
                        "direction":{"type":"string"},"subledger_item_id":{"type":"string"}}}'::jsonb,
        true)
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The refusals this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_CASH_CURRENCY_NOT_BOOKED',
  'Applying cash in a currency the customer owes nothing in.',
  'Cash is applied to what a customer owes, and nothing is owed in that currency, so there is nothing for it to settle and no company whose bank it belongs in. Taking it anyway used to post nothing and say nothing.',
  'Apply it in the currency the customer''s invoices are in: the receivables ageing says what is owed and in which currency. Money for a customer who owes nothing yet is not taken on account here.');

select erp.register_refusal('CLOVEERP_SETTLEMENT_DIFFERENCE_NOT_POSTABLE',
  'Writing a settlement difference off where it cannot be posted.',
  'A difference is written off only on an open receivable or payable, by the settlement difference rule, to the company''s settlement differences account; an overpayment is only ever a customer''s.',
  'Upgrade finance posting so the rule and the account are there, or apply the cash without a difference.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The setting, and what reads it
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value, consequence) values
  ('finance.settlement_tolerance', 'threshold', 'finance',
   'config.finance.settlement_tolerance',
   'How far cash may differ from what an item owes and still settle it: a receipt or a '
   'payment short by no more than this writes the rest off, and a receipt over by no more '
   'than this credits the excess, both to settlement differences. Inside either limit is '
   'inside. The percentage is of the item for a short payment and of what the receipt '
   'applied for an overpayment.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'write_off_max_minor', jsonb_build_object('type','integer','minimum',0),
       'write_off_pct', jsonb_build_object('type','number','minimum',0,'maximum',100))),
   'entity', true,
   jsonb_build_object('write_off_max_minor', 0, 'write_off_pct', 0),
   'a customer short by no more than the tolerance is settled and the difference written off to '
   'settlement differences, and a bill paid short by no more than it is paid; an overpayment '
   'inside it is credited there rather than kept on the customer''s account. Nought settles '
   'only what is paid to the penny.')
on conflict (code) do nothing;

do $config_type$
begin
  if (select ct.default_value from erp_ref.config_type ct where ct.code = 'finance.settlement_tolerance')
     is distinct from '{"write_off_max_minor": 0, "write_off_pct": 0}'::jsonb then
    raise exception 'CLOVEERP_ANCHOR_MOVED: finance.settlement_tolerance is declared already, and not as 20260929300000 declares it';
  end if;
end
$config_type$;

create or replace function erp.settlement_tolerance(p_entity_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The settlement tolerance in force at a company (20260929300000), layered
  -- key by key as the procurement policy is: the product's default, then
  -- what the organisation set, then the company. A key a narrower value
  -- leaves out reads as the broader one's.
  select coalesce(ct.default_value, '{}'::jsonb)
      || coalesce(erp.config_value('finance.settlement_tolerance', null, null, null, null), '{}'::jsonb)
      || case when p_entity_id is null then '{}'::jsonb
              else coalesce(erp.config_value('finance.settlement_tolerance', null, null, p_entity_id, null), '{}'::jsonb) end
    from erp_ref.config_type ct
   where ct.code = 'finance.settlement_tolerance'
$$;

revoke all on function erp.settlement_tolerance(uuid) from public, anon;

comment on function erp.settlement_tolerance(uuid) is
  'finance.settlement_tolerance at a company, over its defaults (20260929300000). Read by '
  'erp.settlement_tolerance_minor(), which the three cash routes ask.';

create or replace function erp.settlement_difference_account(p_entity_id uuid)
returns uuid
language sql
stable
set search_path = ''
as $$
  -- The company's settlement differences account (20260929300000), or null.
  select a.id from erp.account a
   where a.tenant_id = erp.current_tenant_id() and a.entity_id = p_entity_id
     and a.code = erp.chart_account_code('settlement_difference')
     and a.status = 'active' and a.is_postable
   order by a.code limit 1
$$;

revoke all on function erp.settlement_difference_account(uuid) from public, anon;

create or replace function erp.settlement_tolerance_minor(p_entity_id uuid, p_basis_minor bigint)
returns bigint
language plpgsql
stable
set search_path = ''
as $$
declare
  v     jsonb;
  v_abs numeric := 0;
  v_pct numeric := 0;
begin
  -- How far, in minor units, cash may differ from what an item owes at this
  -- company and still settle it (20260929300000): the larger of the absolute
  -- limit and the percentage of the basis, rounded down. Nought where the
  -- settlement difference rule is not in force or the company has no
  -- account for it, because a difference nothing can post is not written
  -- off; and nought for anything but a non-negative number, so a value
  -- outside the setting's shape fails closed.
  if not exists (select 1 from erp.posting_rule r
                  where r.tenant_id = erp.current_tenant_id()
                    and r.code = 'settlement_difference' and r.status = 'active'
                    and (r.entity_id is null or r.entity_id = p_entity_id))
     or erp.settlement_difference_account(p_entity_id) is null then
    return 0;
  end if;

  v := erp.settlement_tolerance(p_entity_id);
  if jsonb_typeof(v) is distinct from 'object' then
    return 0;
  end if;
  if jsonb_typeof(v -> 'write_off_max_minor') = 'number' then
    v_abs := greatest(0, (v ->> 'write_off_max_minor')::numeric);
  end if;
  if jsonb_typeof(v -> 'write_off_pct') = 'number' then
    v_pct := least(100, greatest(0, (v ->> 'write_off_pct')::numeric));
  end if;

  return greatest(floor(v_abs),
                  floor(abs(coalesce(p_basis_minor, 0))::numeric * v_pct / 100))::bigint;
end;
$$;

revoke all on function erp.settlement_tolerance_minor(uuid, bigint) from public, anon;

comment on function erp.settlement_tolerance_minor(uuid, bigint) is
  'The settlement tolerance at a company in minor units, for a basis (20260929300000): the larger '
  'of finance.settlement_tolerance''s absolute limit and its percentage of the basis, rounded down; '
  'nought until the settlement_difference rule is in force and the company holds its account.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The rule, from one helper
--
-- The installer names the account by the code today's chart gives each
-- purpose; the upgrade names the purpose, and the planner resolves it against
-- the organisation's own chart and plans the account the company lacks. The
-- lines describe the customer's write-off; the same rule names the line of
-- every settlement difference journal, whichever side the difference falls.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.settlement_difference_rule(p_by_purpose boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'code', 'settlement_difference', 'name', 'Settlement difference', 'ledger', 'GL',
    'event_type', 'cash.settlement_difference_posted',
    'posting_lines', jsonb_build_array(
      jsonb_build_object(
        'account', case when p_by_purpose then jsonb_build_object('purpose', 'settlement_difference')
                        else to_jsonb(erp.chart_account_code('settlement_difference')) end,
        'side', 'debit', 'rate', 1,
        'description', 'The difference written off, inside the settlement tolerance'),
      jsonb_build_object(
        'account', case when p_by_purpose then jsonb_build_object('purpose', 'trade_receivable')
                        else to_jsonb(erp.chart_account_code('trade_receivable')) end,
        'side', 'credit', 'rate', 1,
        'description', 'The receivable it closes')))
$$;

revoke all on function erp.settlement_difference_rule(boolean) from public, anon;

comment on function erp.settlement_difference_rule(boolean) is
  'The settlement_difference posting rule (20260929300000): by the account code today''s chart gives '
  'each purpose, or by purpose for an upgrade to resolve.';

-- Finance's installer ships the rule, and the tolerance a new organisation
-- starts with: £1, nothing by percentage (D6). An organisation configured
-- before takes the rule through Upgrade and keeps the product default of
-- nought, because the upgrade carries the rule and not the setting.
do $configure_finance$
declare
  v_sig constant text := 'erp.configure_finance(integer,character,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$                               'description','Committed to a customer'))))));$o$;
  v_new constant text := $n$                               'description','Committed to a customer')))),
      -- The difference cash settles within tolerance (20260929300000), and
      -- the tolerance an organisation configured from now on starts with.
      jsonb_build_object('kind','posting_rule','key','settlement_difference','payload',
        erp.settlement_difference_rule(false)),
      jsonb_build_object('kind','config','key','finance.settlement_tolerance','payload',
        jsonb_build_object(
          'config_type','finance.settlement_tolerance',
          'value', jsonb_build_object('write_off_max_minor', 100, 'write_off_pct', 0)))));$n$;
  n integer;
begin
  if position('erp.settlement_difference_rule(false)' in v_def) > 0 then
    raise notice '% already ships the settlement difference rule; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % rule list anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure_finance$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. Finance posting version 3: an installed organisation takes the rule and
--     the account as an upgrade
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 3,
       description = description
         || ' Version 3 (20260929300000): the settlement difference rule and its account, so cash '
         || 'can settle within the organisation''s settlement tolerance.'
 where install_code = 'finance-posting' and current_version = 2;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
values ('finance-posting', 3, 'posting_rule', 'settlement_difference',
        erp.settlement_difference_rule(true), 130)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

insert into erp_ref.module_upgrade_account (install_code, to_version, purpose)
values ('finance-posting', 3, 'settlement_difference')
on conflict do nothing;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'finance-posting') is distinct from 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the finance posting installer is not at version 3';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'finance-posting' and ui.to_version = 3
         and ui.object_kind = 'posting_rule' and ui.object_key = 'settlement_difference'
         and ui.payload = erp.settlement_difference_rule(true)) <> 1
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'finance-posting' and ui.to_version = 3) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 3 of finance posting is not the one rule it ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. What the three cash routes share
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
  -- owed, or that owes (20260929300000, from the three routes' own lookups).
  select a.id into v_bank from erp.account a
   where a.tenant_id = erp.current_tenant_id() and a.entity_id = p_entity_id
     and a.control_kind = 'bank' and a.status = 'active'
   order by a.code limit 1;
  if v_bank is null then
    raise exception 'CLOVEERP_NO_BANK_ACCOUNT: % has no bank account for this cash to land in or leave from',
      coalesce((select e.code from erp.entity e where e.id = p_entity_id), p_entity_id::text)
      using errcode = '23503',
            hint = 'Give the company a postable account with control kind bank; the finance installer creates one. Cash is not banked in another company''s name.';
  end if;
  return v_bank;
end;
$$;

revoke all on function erp.company_bank_account(uuid) from public, anon;

create or replace function erp.require_cash_in_ledger_currency(p_ledger_id uuid, p_currency char(3))
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  -- No FX (D10, 20260929300000). Every cash route posts at a rate of one, so
  -- cash in any currency but the ledger's is refused here rather than
  -- translated at one on the day foreign documents can post.
  if not exists (select 1 from erp.ledger l
                  where l.tenant_id = erp.current_tenant_id() and l.id = p_ledger_id
                    and l.currency = p_currency) then
    raise exception 'CLOVEERP_NO_TRANSLATION: cash in % meets ledger % reporting in %', p_currency,
      coalesce((select l.code from erp.ledger l where l.id = p_ledger_id), p_ledger_id::text),
      coalesce((select l.currency::text from erp.ledger l where l.id = p_ledger_id), 'nothing')
      using errcode = '22000',
            hint = 'Receive or pay it in the ledger''s currency. No rate source is configured, and a translated figure nobody can trace to a rate is worse than a refusal.';
  end if;
end;
$$;

revoke all on function erp.require_cash_in_ledger_currency(uuid, char) from public, anon;

create or replace function erp.post_settlement_difference(
  p_item_id uuid, p_difference_minor bigint, p_on date, p_reference text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  si        erp.subledger_item%rowtype;
  v_amount  bigint := abs(coalesce(p_difference_minor, 0));
  v_rule    uuid;
  v_version integer;
  v_account uuid;
  v_other   uuid;
  v_event   uuid;
  v_journal uuid;
  v_dr      uuid;
  v_cr      uuid;
  v_ref     text := coalesce(p_reference, 'cash received');
begin
  -- A settlement difference, posted by the settlement_difference rule
  -- (20260929300000). Positive: the item is short by that much, and it is
  -- written off and the item settled — for a receivable Dr settlement
  -- differences, Cr the receivable; for a payable Dr the payable, Cr
  -- settlement differences. Negative: a receipt was over by that much, and
  -- the excess is credited to settlement differences against the bank; only
  -- a receivable, because nothing pays a supplier more than it owes. The
  -- caller has authorised the cash and decided the difference is inside the
  -- tolerance; this posts it.
  if v_amount = 0 then
    return null;
  end if;

  select * into si from erp.subledger_item x
   where x.tenant_id = v_tenant and x.id = p_item_id for update;
  if not found or si.control_kind not in ('receivable', 'payable')
     or (p_difference_minor < 0 and si.control_kind <> 'receivable')
     or (p_difference_minor > 0 and v_amount > (case si.control_kind
                                                  when 'receivable' then si.debit_minor - si.credit_minor
                                                  else si.credit_minor - si.debit_minor end)
                                                - coalesce(si.settled_minor, 0)) then
    raise exception 'CLOVEERP_SETTLEMENT_DIFFERENCE_NOT_POSTABLE: % is not an item a difference of % can settle',
      p_item_id, p_difference_minor
      using errcode = '23514',
            hint = 'A shortfall is written off an open receivable or payable, no more than it owes; an overpayment only against a receivable.';
  end if;

  perform erp.authorise('finance.post', si.entity_id, null, null, 'party', si.party_id);
  perform erp.require_cash_in_ledger_currency(si.ledger_id, si.currency);

  select pr.id, pr.version into v_rule, v_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'settlement_difference' and pr.status = 'active'
     and (pr.entity_id is null or pr.entity_id = si.entity_id)
   order by pr.version desc limit 1;
  v_account := erp.settlement_difference_account(si.entity_id);
  if v_rule is null or v_account is null then
    raise exception 'CLOVEERP_SETTLEMENT_DIFFERENCE_NOT_POSTABLE: company % has no settlement difference rule or account',
      coalesce((select e.code from erp.entity e where e.id = si.entity_id), si.entity_id::text)
      using errcode = '23503',
            hint = 'Upgrade finance posting to version 3: it installs the settlement_difference rule and the 7900 account.';
  end if;

  v_other := case when p_difference_minor < 0 then erp.company_bank_account(si.entity_id)
                  else si.control_account_id end;
  if p_difference_minor < 0 or si.control_kind = 'payable' then
    v_dr := v_other; v_cr := v_account;
  else
    v_dr := v_account; v_cr := v_other;
  end if;

  v_event := erp.append_event(
    'cash.settlement_difference_posted', 'document', coalesce(si.document_id, si.party_id),
    jsonb_build_object('reference', v_ref, 'posting_rule', 'settlement_difference',
                       'value_minor', v_amount, 'currency', si.currency,
                       'direction', case when p_difference_minor < 0 then 'overpaid' else 'short' end,
                       'subledger_item_id', si.id),
    si.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, status)
  values (v_tenant, si.entity_id, si.ledger_id, 'cash.settlement_difference_posted', v_event, p_on,
          format('Settlement difference %s', v_ref), 'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, v_dr, v_amount, 0, si.currency, v_amount, 0, 1,
          v_rule, v_version, v_event,
          case when p_difference_minor < 0 then 'overpaid, inside the settlement tolerance'
               when si.control_kind = 'payable' then 'paid short, inside the settlement tolerance'
               else 'written off, inside the settlement tolerance' end),
         (v_tenant, v_journal, 2, v_cr, 0, v_amount, si.currency, 0, v_amount, 1,
          v_rule, v_version, v_event,
          case when p_difference_minor < 0 or si.control_kind = 'payable' then 'settlement difference'
               else 'the receivable it closes' end);

  if p_difference_minor < 0 then
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    values (v_tenant, si.entity_id, si.ledger_id, 'bank', v_other,
            null, null, v_journal, si.currency, v_amount, 0, p_on);
  else
    -- The write-off is a settlement of the item, as cash is: the row names
    -- the document and the item's settled_minor takes it, so the one
    -- computation of what is owed (erp.ageing_balance) reads nothing.
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    values (v_tenant, si.entity_id, si.ledger_id, si.control_kind, si.control_account_id,
            si.party_id, si.document_id, v_journal, si.currency,
            case when si.control_kind = 'payable' then v_amount else 0 end,
            case when si.control_kind = 'receivable' then v_amount else 0 end,
            p_on);
    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_amount, updated_at = now()
     where id = si.id;
  end if;

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  return v_journal;
end;
$$;

revoke all on function erp.post_settlement_difference(uuid, bigint, date, text) from public, anon;

comment on function erp.post_settlement_difference(uuid, bigint, date, text) is
  'Posts a settlement difference by the settlement_difference rule (20260929300000): a shortfall '
  'written off an item and settling it, or an overpayment credited against the bank. Called by '
  'erp.apply_cash(), erp.apply_cash_to_item() and erp.pay_payment_run() inside the tolerance.';

create or replace function erp.post_cash_on_account(
  p_item_id uuid, p_amount_minor bigint, p_on date, p_reference text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  si        erp.subledger_item%rowtype;
  v_rule    uuid;
  v_version integer;
  v_bank    uuid;
  v_event   uuid;
  v_journal uuid;
  v_ref     text := coalesce(p_reference, 'cash received');
begin
  -- An overpayment beyond the tolerance, kept on the customer's account
  -- (D7, D8, 20260929300000): Dr bank, Cr the receivable, on a row naming
  -- the customer and no document. That is the unallocated credit
  -- erp.ageing_balance's party arm already ages, so the ageing, the control
  -- account and the bank all carry it. In the company, ledger and currency of
  -- the item the receipt paid, by the cash application rule.
  if coalesce(p_amount_minor, 0) <= 0 then
    return null;
  end if;

  select * into si from erp.subledger_item x
   where x.tenant_id = v_tenant and x.id = p_item_id;
  if not found or si.control_kind <> 'receivable' or si.party_id is null then
    raise exception 'CLOVEERP_NOT_A_RECEIVABLE: % is not a customer''s receivable to keep cash against', p_item_id
      using errcode = '23503', hint = 'Cash is kept on account for the customer whose invoice it paid; erp_receivables_ageing() lists them.';
  end if;

  perform erp.authorise('finance.post', si.entity_id, null, null, 'party', si.party_id);
  perform erp.require_cash_in_ledger_currency(si.ledger_id, si.currency);
  v_bank := erp.company_bank_account(si.entity_id);

  select pr.id, pr.version into v_rule, v_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'cash_application' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_CASH_POSTING_RULE: cash application has no promoted rule'
      using errcode = '23503', hint = 'erp.configure_receivables() installs it.';
  end if;

  v_event := erp.append_event(
    'document.posted', 'document', si.party_id,
    jsonb_build_object('document_number', v_ref, 'posting_rule', 'cash_application',
                       'value_minor', p_amount_minor, 'currency', si.currency),
    si.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                           posting_date, description, status)
  values (v_tenant, si.entity_id, si.ledger_id, 'cash.on_account', v_event, p_on,
          format('Cash kept on account %s', v_ref), 'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, v_bank, p_amount_minor, 0, si.currency, p_amount_minor, 0, 1,
          v_rule, v_version, v_event, 'cash received'),
         (v_tenant, v_journal, 2, si.control_account_id, 0, p_amount_minor, si.currency, 0, p_amount_minor, 1,
          v_rule, v_version, v_event, 'kept on the customer''s account');

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
  values (v_tenant, si.entity_id, si.ledger_id, 'receivable', si.control_account_id,
          si.party_id, null, v_journal, si.currency, 0, p_amount_minor, p_on),
         (v_tenant, si.entity_id, si.ledger_id, 'bank', v_bank,
          null, null, v_journal, si.currency, p_amount_minor, 0, p_on);

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  return v_journal;
end;
$$;

revoke all on function erp.post_cash_on_account(uuid, bigint, date, text) from public, anon;

comment on function erp.post_cash_on_account(uuid, bigint, date, text) is
  'Keeps an overpayment beyond the settlement tolerance on the customer''s account, banked, as an '
  'unallocated credit the ageing carries (20260929300000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The item route: settlement statements
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_take   bigint;
  v_short  bigint;
  v_excess bigint;
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
  -- An item that owes nothing is not open (20260929300000): there is nothing
  -- for the receipt to settle, and a credit is not something cash pays.
  if v_owing <= 0 then
    raise exception 'CLOVEERP_NOT_A_RECEIVABLE: % owes nothing, so it is not an open receivable item', p_subledger_item_id
      using errcode = '23503', hint = 'Cash settles a receivable subledger item that still owes; erp_receivables_ageing() lists them.';
  end if;
  perform erp.require_cash_in_ledger_currency(si.ledger_id, si.currency);

  -- What the item owes is applied; what is left of it, or of the receipt,
  -- is the difference the tolerance decides (20260929300000). An overpayment
  -- is no longer refused: D7.
  v_take   := least(p_amount_minor, v_owing);
  v_short  := v_owing - v_take;
  v_excess := p_amount_minor - v_take;

  v_bank := erp.company_bank_account(si.entity_id);

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
                       'value_minor', v_take, 'currency', si.currency),
    si.entity_id, null);

  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id, posting_date, description, status)
  values (v_tenant, si.entity_id, si.ledger_id, 'cash.applied', v_event, p_received_on,
          format('Cash received %s', coalesce(p_reference, '')), 'draft')
  returning id into v_journal;

  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                base_debit_minor, base_credit_minor, exchange_rate,
                                posting_rule_id, posting_rule_version, source_event_id, description)
  values (v_tenant, v_journal, 1, v_bank, v_take, 0, si.currency, v_take, 0, 1,
          v_rule, v_rule_version, v_event, 'cash received'),
         (v_tenant, v_journal, 2, si.control_account_id, 0, v_take, si.currency, 0, v_take, 1,
          v_rule, v_rule_version, v_event, 'applied to receivable');

  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                  party_id, document_id, journal_id, currency, debit_minor, credit_minor, posting_date)
  values (v_tenant, si.entity_id, si.ledger_id, 'receivable', si.control_account_id,
          si.party_id, si.document_id, v_journal, si.currency, 0, v_take, p_received_on),
         (v_tenant, si.entity_id, si.ledger_id, 'bank', v_bank,
          null, null, v_journal, si.currency, v_take, 0, p_received_on);

  update erp.subledger_item
     set settled_minor = coalesce(settled_minor, 0) + v_take, updated_at = now()
   where id = si.id;

  update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where id = v_journal;

  -- The difference, inside the tolerance, is written off or credited; an
  -- overpayment beyond it is kept on the customer's account. Short beyond it,
  -- the item stays open for the rest.
  if v_short > 0
     and v_short <= erp.settlement_tolerance_minor(si.entity_id, si.debit_minor - si.credit_minor) then
    perform erp.post_settlement_difference(si.id, v_short, p_received_on, p_reference);
  elsif v_excess > 0 then
    if v_excess <= erp.settlement_tolerance_minor(si.entity_id, v_take) then
      perform erp.post_settlement_difference(si.id, -v_excess, p_received_on, p_reference);
    else
      perform erp.post_cash_on_account(si.id, v_excess, p_received_on, p_reference);
    end if;
  end if;

  -- This route names the document it settles, so there is one to ask
  -- about; a statement line matched to an item that carries no document
  -- settles nothing and says nothing, which is right.
  perform erp.settle_paid_document(
    si.document_id, format('settled by %s', coalesce(p_reference, 'cash received')));

  return v_journal;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The party route: the desk's Apply cash
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.apply_cash(p_party_id uuid, p_amount_minor bigint, p_currency character,
                                          p_reference text, p_received_on date)
returns table(subledger_item_id uuid, applied_minor bigint, remaining_minor bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_left   bigint := p_amount_minor;
  r        record;
  v_take   bigint;
  v_bank   uuid;
  v_journal uuid;
  v_event  uuid;
  v_rule   uuid;
  v_rule_version integer;
  v_no     integer;
  -- One journal per company owed, kept by company id. A receipt that settles
  -- two companies' invoices is two journals in two ledgers, because it is two
  -- companies' cash and each one's books have to stand alone.
  v_journals jsonb := '{}'::jsonb;
  v_banks    jsonb := '{}'::jsonb;
  v_events   jsonb := '{}'::jsonb;
  v_entity uuid;
  -- The documents this receipt touched, once each: a receipt that pays
  -- two invoices has two to settle, and one that pays an invoice twice
  -- has one.
  v_docs   uuid[] := '{}'::uuid[];
  v_doc    uuid;
  -- The last item the receipt reached, what it left owing on it and what the
  -- receipt applied in all (20260929300000): the tolerance is decided there.
  v_last        uuid;
  v_last_entity uuid;
  v_last_gross  bigint := 0;
  v_last_short  bigint := 0;
  v_applied     bigint := 0;
begin
  -- A receipt has a date, and it is not in the future. Cash that arrives
  -- tomorrow is a forecast, and a forecast in the bank subledger is a lie the
  -- reconciliation would then have to explain.
  if p_received_on is null or p_received_on > current_date then
    raise exception
      'CLOVEERP_CASH_DATE_INVALID: a receipt is dated the day it arrived, which '
      'is % and not after today', coalesce(p_received_on::text, 'null')
      using errcode = '22007',
      hint = 'Pass the date the money reached the bank, or omit it and today is used.';
  end if;

  -- And an amount, as the item route has always asked (20260929300000).
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'CLOVEERP_CASH_AMOUNT_INVALID: a receipt is a positive amount, not %', p_amount_minor
      using errcode = '22023', hint = 'Pass the amount received in minor units.';
  end if;

  perform erp.authorise('finance.post', null, null, null, 'party', p_party_id);

  select pr.id, pr.version into v_rule, v_rule_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'cash_application'
     and pr.status = 'active'
   order by pr.version desc limit 1;

  if v_rule is null then
    raise exception
      'CLOVEERP_NO_CASH_POSTING_RULE: cash application has no promoted rule'
      using errcode = '23503',
      hint = 'erp.configure_receivables() installs it. B7 refuses a journal '
             'line that cannot name the rule that produced it.';
  end if;

  -- Cash in a currency the customer owes nothing in has nothing to settle
  -- and no company to be banked in (D9, 20260929300000). It used to post
  -- nothing and say nothing.
  if not exists (
    select 1 from erp.subledger_item si
     where si.tenant_id = v_tenant and si.party_id = p_party_id
       and si.control_kind = 'receivable' and si.currency = p_currency
       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0)
  then
    raise exception 'CLOVEERP_CASH_CURRENCY_NOT_BOOKED: % owes nothing in %',
      coalesce((select p.code from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id),
               p_party_id::text),
      coalesce(p_currency::text, 'no currency')
      using errcode = '23514',
            hint = 'Apply it in the currency the customer''s invoices are in; erp_receivables_ageing() says what is owed and in which currency. Money for a customer who owes nothing yet is not taken on account here.';
  end if;

  -- Oldest first, which is the only allocation defensible without an
  -- instruction from the customer, and across every company the party owes:
  -- the oldest invoice is the oldest invoice whoever it was raised by.
  -- Settled amounts are excluded, so a second receipt sees only what is
  -- genuinely still owed.
  for r in
    select si.id, si.entity_id, si.ledger_id, si.document_id,
           si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) as owing,
           si.debit_minor - si.credit_minor as gross,
           si.control_account_id
      from erp.subledger_item si
     where si.tenant_id = v_tenant and si.party_id = p_party_id
       and si.control_kind = 'receivable' and si.currency = p_currency
       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0
     order by coalesce(si.due_date, si.posting_date), si.id
  loop
    exit when v_left <= 0;
    perform erp.require_cash_in_ledger_currency(r.ledger_id, p_currency);
    v_take := least(v_left, r.owing);
    v_entity := r.entity_id;
    if r.document_id is not null and not (r.document_id = any (v_docs)) then
      v_docs := v_docs || r.document_id;
    end if;

    -- The bank the money reached is the bank of the company that is owed.
    v_bank := nullif(v_banks ->> v_entity::text, '')::uuid;
    if v_bank is null then
      v_bank := erp.company_bank_account(v_entity);
      v_banks := v_banks || jsonb_build_object(v_entity::text, v_bank);
    end if;

    -- Each company's cash is authorised in that company.
    perform erp.authorise('finance.post', v_entity, null, null, 'party', p_party_id);

    v_journal := nullif(v_journals ->> v_entity::text, '')::uuid;
    if v_journal is null then
      v_event := erp.append_event(
        'document.posted', 'document', p_party_id,
        jsonb_build_object(
          'document_number', coalesce(p_reference, 'cash receipt'),
          'posting_rule', 'cash_application',
          'value_minor', p_amount_minor,
          'currency', p_currency,
          'entity_id', v_entity));

      insert into erp.journal (
        tenant_id, entity_id, ledger_id, source_code, source_event_id,
        posting_date, description, status)
      values (v_tenant, v_entity, r.ledger_id, 'cash.applied', v_event,
              p_received_on,
              format('Cash received from customer %s', coalesce(p_reference, '')),
              'draft')
      returning id into v_journal;

      v_journals := v_journals || jsonb_build_object(v_entity::text, v_journal);
      v_events   := v_events   || jsonb_build_object(v_entity::text, v_event);
    else
      v_event := (v_events ->> v_entity::text)::uuid;
    end if;

    select coalesce(max(jl.line_no), 0) into v_no
      from erp.journal_line jl where jl.journal_id = v_journal;

    insert into erp.journal_line (
      tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
      currency, base_debit_minor, base_credit_minor, exchange_rate,
      posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, v_no + 1, v_bank, v_take, 0, p_currency,
            v_take, 0, 1, v_rule, v_rule_version, v_event, 'cash received'),
           (v_tenant, v_journal, v_no + 2, r.control_account_id, 0, v_take,
            p_currency, 0, v_take, 1, v_rule, v_rule_version, v_event,
            'applied to receivable');

    insert into erp.subledger_item (
      tenant_id, entity_id, ledger_id, control_kind, control_account_id,
      party_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    values (v_tenant, v_entity, r.ledger_id, 'receivable', r.control_account_id,
            p_party_id, v_journal, p_currency, 0, v_take, p_received_on),
           (v_tenant, v_entity, r.ledger_id, 'bank', v_bank,
            null, v_journal, p_currency, v_take, 0, p_received_on);

    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_take,
           updated_at = now()
     where id = r.id;

    v_last := r.id;
    v_last_entity := v_entity;
    v_last_gross := r.gross;
    v_last_short := r.owing - v_take;
    v_applied := v_applied + v_take;

    subledger_item_id := r.id;
    applied_minor := v_take;
    v_left := v_left - v_take;
    remaining_minor := v_left;
    return next;
  end loop;

  update erp.journal
     set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
   where tenant_id = v_tenant
     and id in (select (jsonb_each_text(v_journals)).value::uuid);

  -- The whole receipt is banked (D8, 20260929300000). The last item the
  -- receipt reached takes the tolerance: short by no more than it, its
  -- residue is written off; a remainder after every item is credited to
  -- settlement differences inside it, and kept on the customer's account
  -- beyond it. Short beyond it, the item stays open for the rest.
  if v_left = 0 and v_last_short > 0
     and v_last_short <= erp.settlement_tolerance_minor(v_last_entity, v_last_gross) then
    perform erp.post_settlement_difference(v_last, v_last_short, p_received_on, p_reference);
  elsif v_left > 0 then
    if v_left <= erp.settlement_tolerance_minor(v_last_entity, v_applied) then
      perform erp.post_settlement_difference(v_last, -v_left, p_received_on, p_reference);
    else
      perform erp.post_cash_on_account(v_last, v_left, p_received_on, p_reference);
    end if;
  end if;

  -- And the documents the cash paid off say so. After the loop, because
  -- settled_minor is written inside it and what a document owes is the
  -- sum over all of its rows: asking halfway through would ask about a
  -- receipt that was not finished arriving.
  foreach v_doc in array v_docs loop
    perform erp.settle_paid_document(
      v_doc, format('settled by %s', coalesce(p_reference, 'cash received')));
  end loop;

  -- What was left over after every item, now banked: credited to settlement
  -- differences, or on the customer's account.
  if v_left > 0 then
    subledger_item_id := null;
    applied_minor := 0;
    remaining_minor := v_left;
    return next;
  end if;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B4. Supplier payments: the same tolerance (D14)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.pay_payment_run(p_proposal_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  pp        erp.payment_proposal%rowtype;
  v_bank    uuid;
  v_rule    uuid;
  v_rule_version integer;
  v_event   uuid;
  v_journal uuid;
  si        erp.subledger_item%rowtype;
  r         record;
  v_owing   bigint;
  v_amount  bigint;
  v_short   bigint;
  v_paid    bigint := 0;
  v_written bigint := 0;
  v_lines   integer := 0;
  v_docs    integer := 0;
begin
  select * into pp from erp.payment_proposal x
   where x.tenant_id = v_tenant and x.id = p_proposal_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_PAYMENT_PROPOSAL: no payment run %', p_proposal_id
      using errcode = '23503', hint = 'erp_payment_proposals() lists the runs.';
  end if;

  if pp.status = 'paid' then
    raise exception 'CLOVEERP_PAYMENT_ALREADY_PAID: % was paid already', pp.reference
      using errcode = '23505',
      hint = 'Propose a new run for whatever is still outstanding: erp_propose_payment_run().';
  end if;

  if pp.status <> 'approved' then
    raise exception 'CLOVEERP_PAYMENT_NOT_APPROVED: % is %', pp.reference, pp.status
      using errcode = '23514',
      hint = 'Somebody other than the proposer approves the run first: erp_approve_payment_run().';
  end if;

  perform erp.authorise('finance.post', pp.entity_id, null, null,
                        'payment_proposal', p_proposal_id);

  v_bank := erp.company_bank_account(pp.entity_id);

  select pr.id, pr.version into v_rule, v_rule_version
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = 'supplier_payment' and pr.status = 'active'
   order by pr.version desc limit 1;
  if v_rule is null then
    raise exception 'CLOVEERP_NO_PAYMENT_POSTING_RULE: paying a supplier has no promoted rule'
      using errcode = '23503',
      hint = 'Install procurement controls: erp_configure_procurement_controls().';
  end if;

  for r in
    select l.* from erp.payment_proposal_line l
     where l.tenant_id = v_tenant and l.payment_proposal_id = p_proposal_id
       and not l.is_held
     order by l.created_at, l.id
  loop
    select * into si from erp.subledger_item x
     where x.tenant_id = v_tenant and x.id = r.subledger_item_id for update;
    if not found or si.control_kind <> 'payable' then
      continue;
    end if;

    v_owing := si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0);
    v_amount := least(coalesce(r.amount_minor, 0), v_owing);
    if v_amount <= 0 then
      continue;
    end if;
    perform erp.require_cash_in_ledger_currency(si.ledger_id, si.currency);

    v_event := erp.append_event(
      'payment.made', 'posting', p_proposal_id,
      jsonb_build_object('reference', pp.reference, 'posting_rule', 'supplier_payment',
                         'value_minor', v_amount, 'currency', si.currency,
                         'party_id', si.party_id, 'document_id', si.document_id),
      pp.entity_id, null);

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                             posting_date, description, status)
    values (v_tenant, si.entity_id, si.ledger_id, 'payment.made', v_event,
            coalesce(pp.payment_date, current_date),
            format('Supplier payment %s', pp.reference), 'draft')
    returning id into v_journal;

    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, 1, si.control_account_id, v_amount, 0, si.currency, v_amount, 0, 1,
            v_rule, v_rule_version, v_event, 'paid to the supplier'),
           (v_tenant, v_journal, 2, v_bank, 0, v_amount, si.currency, 0, v_amount, 1,
            v_rule, v_rule_version, v_event, 'bank');

    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    party_id, document_id, journal_id, currency,
                                    debit_minor, credit_minor, posting_date)
    values (v_tenant, si.entity_id, si.ledger_id, 'payable', si.control_account_id,
            si.party_id, si.document_id, v_journal, si.currency, v_amount, 0,
            coalesce(pp.payment_date, current_date)),
           (v_tenant, si.entity_id, si.ledger_id, 'bank', v_bank,
            null, null, v_journal, si.currency, 0, v_amount,
            coalesce(pp.payment_date, current_date));

    update erp.subledger_item
       set settled_minor = coalesce(settled_minor, 0) + v_amount, updated_at = now()
     where id = si.id;

    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
     where id = v_journal;

    v_paid := v_paid + v_amount;
    v_lines := v_lines + 1;

    -- A bill paid short by no more than the organisation's settlement
    -- tolerance is paid, and the residue written off (D14, 20260929300000):
    -- Dr the payable, Cr settlement differences. Beyond it the bill stays
    -- open for the next run.
    v_short := v_owing - v_amount;
    if v_short > 0
       and v_short <= erp.settlement_tolerance_minor(si.entity_id, si.credit_minor - si.debit_minor) then
      perform erp.post_settlement_difference(si.id, v_short, coalesce(pp.payment_date, current_date), pp.reference);
      v_written := v_written + v_short;
    end if;

    -- A bill that owes nothing is paid, and says so. The state is what the
    -- screens and the supplier read, so leaving it registered would be the
    -- ledger and the document disagreeing.
    --
    -- What it owes is now asked of the one arithmetic. The sum this used to
    -- take counted a payment twice — once as the settling row it had just
    -- written and once again in settled_minor — so it reached nil at half the
    -- bill, and a bill paid in part was marked paid.
    if erp.settle_paid_document(si.document_id, 'paid on ' || pp.reference) then
      v_docs := v_docs + 1;
    end if;
  end loop;

  update erp.payment_proposal
     set status = 'paid', total_minor = v_paid, updated_at = now()
   where id = p_proposal_id;

  return jsonb_build_object(
    'proposal_id', p_proposal_id, 'reference', pp.reference,
    'currency', pp.currency, 'lines_paid', v_lines,
    'paid_minor', v_paid, 'written_off_minor', v_written, 'documents_settled', v_docs,
    'held', (select count(*) from erp.payment_proposal_line l
              where l.tenant_id = v_tenant and l.payment_proposal_id = p_proposal_id and l.is_held));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B5. The refusal a statement line meets now points where the rest is kept
-- ─────────────────────────────────────────────────────────────────────────────

do $match$
declare
  v_sig constant text := 'erp.match_settlement_line(uuid,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$hint = 'Match the line to the item it settles in full, or split the receipt through erp_apply_cash().';$o$;
  v_new constant text := $n$hint = 'Match the line to an item that owes at least as much, or apply the receipt to the customer through erp_apply_cash(), which banks all of it and keeps what no invoice owes on the customer''s account.';$n$;
  n integer;
begin
  if position('keeps what no invoice owes on the customer' in v_def) > 0 then
    raise notice '% already points at the customer''s account; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % hint anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$match$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The suite the tolerance changes the answer for
--
-- The cash settlement suite's organisation is a new one, so it would settle
-- within £1, and its penny-short invoice and penny-short bill would be paid.
-- Re-pinned deliberately: the suite sets the tolerance to nought, because
-- what it proves — a penny short is not settled, is not marked paid by hand,
-- and the penny settles it — is the product with no tolerance, which is every
-- organisation configured before 20260929300000 (D6). The tolerance is
-- erp_test.cash_tolerance_suite's. It keeps its cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $cash$
declare
  v_sig constant text := 'erp_test.cash_settlement_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
$o$;
  b0 constant text := $n$    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    -- Re-pinned by 20260929300000 (PR12 M3): a new organisation settles
    -- within £1. These cases prove settlement with no tolerance, as every
    -- organisation configured before it has; erp_test.cash_tolerance_suite
    -- proves the tolerance.
    perform erp.set_config_value('finance.settlement_tolerance',
      jsonb_build_object('write_off_max_minor', 0, 'write_off_pct', 0),
      null, null, null, null, 'the cash settlement suite proves settlement with no tolerance');
$n$;
  n integer;
begin
  if position('Re-pinned by 20260929300000' in v_def) > 0 then
    raise notice '% already settles with no tolerance; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, a0, ''))) / length(a0);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % re-pin anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, a0, b0);
end
$cash$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D1. The proof: erp_test.cash_tolerance_suite
--
-- One organisation, configured from now on, so it settles within £1. Each
-- case has a customer of its own, because the party route pays the oldest
-- invoice first. Every movement is measured on the accounts, as the change in
-- their posted balance across the case.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.cash_tolerance_account_movement(p_account_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- Debits less credits posted to one account (20260929300000).
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint
    from erp.journal_line jl
    join erp.journal j on j.id = jl.journal_id
   where jl.tenant_id = erp.current_tenant_id() and jl.account_id = p_account_id
     and j.status = 'posted'
$$;

revoke all on function erp_test.cash_tolerance_account_movement(uuid) from public, anon;

create or replace function erp_test.cash_tolerance_customer_invoice(
  p_entity uuid, p_site uuid, p_item uuid, p_ccy char(3), p_code text, p_price bigint)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cust   uuid;
  v_inv    uuid;
begin
  -- A customer of the case's own and one invoice to them, issued
  -- (20260929300000).
  insert into erp.party (tenant_id, code, name, status)
  values (v_tenant, p_code, 'Cash Tolerance ' || p_code, 'active') returning id into v_cust;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (v_tenant, v_cust, 'customer', 'active');
  v_inv := erp.create_document('sales_invoice', p_entity, p_site, v_cust,
                               current_date, p_ccy, p_code || '-INV', '{}'::jsonb);
  perform erp.add_document_line(v_inv, p_item, 1, p_price, 'a sale to ' || p_code);
  perform erp.transition_document(v_inv, 'issue', 'cash tolerance suite');
  return v_inv;
end;
$$;

revoke all on function erp_test.cash_tolerance_customer_invoice(uuid, uuid, uuid, char, text, bigint) from public, anon;

create or replace function erp_test.cash_tolerance_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 17;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_second uuid; v_tok2 text;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_loc uuid; v_uom uuid; v_ccy char(3);
  v_supp uuid; v_item uuid;
  v_diff uuid; v_bank uuid; v_ar uuid;
  v_inv uuid; v_inv2 uuid; v_cust uuid; v_item_row uuid;
  v_gross bigint; v_gross2 bigint;
  v_d0 bigint; v_b0 bigint; v_d1 bigint; v_b1 bigint;
  v_owed bigint; v_on bigint; v_n integer; v_n2 integer;
  v_tol jsonb; v_min bigint; v_min2 bigint; v_min3 bigint;
  v_s1 text; v_s2 text; v_log text;
  v_err text; v_hint text;
  v_rem bigint;
  v_po uuid; v_pol uuid; v_grn uuid; v_bill uuid; v_prop uuid; v_pay jsonb;
  v_t1 text; v_t2 text; v_t3 text;
begin
  begin
    v_step := 'an organisation configured from now on, that can invoice, bill, bank a receipt and pay a supplier';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzctl-' || v_tag, 'Cash Tolerance Suite',
      'admin@zzctl-' || v_tag || '.test', 'Cash Tolerance Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzctl-' || v_tag || '.test'),
           (a2, 'second@zzctl-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'a second administrator, because a payment run is not approved by its proposer';
    res := public.erp_invite_principal('second@zzctl-' || v_tag || '.test', 'Cash Tolerance Second');
    v_second := (res ->> 'app_user_id')::uuid;
    v_tok2 := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, unit, supplier and product';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    if v_site is null then
      insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
      values (rb.tenant_id, v_entity, 'ZCMAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    end if;
    select l.id into v_loc from erp.location l
     where l.tenant_id = rb.tenant_id and l.site_id = v_site
       and l.location_type = 'receiving' and l.status = 'active' order by l.code limit 1;
    if v_loc is null then
      insert into erp.location (tenant_id, site_id, code, name, location_type, status)
      values (rb.tenant_id, v_site, 'ZCRECV', 'Goods in', 'receiving', 'active') returning id into v_loc;
    end if;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZCEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZCSUP', 'Cash Tolerance Supplier', 'active') returning id into v_supp;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_supp, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCWID', 'Cash Tolerance Widget', v_uom, 'active') returning id into v_item;

    v_diff := erp.settlement_difference_account(v_entity);
    v_bank := erp.company_bank_account(v_entity);
    select a.id into v_ar from erp.account a
     where a.tenant_id = rb.tenant_id and a.entity_id = v_entity
       and a.control_kind = 'receivable' and a.status = 'active' order by a.code limit 1;

    -- ── 1. Declared, installed at £1, and read ──────────────────────────────
    v_step := 'the setting, the account and the rule';
    v_tol := erp.settlement_tolerance(v_entity);
    v_min := erp.settlement_tolerance_minor(v_entity, 0);
    v_cases := v_cases + 1;
    case_name := 'the tolerance is declared at nought, a new organisation is installed at £1 with the rule and the 7900 account, an upgrade carries the rule and never the setting, and nothing of it is dead configuration';
    passed := v_state is null
          and exists (select 1 from erp_ref.config_type ct
                       where ct.code = 'finance.settlement_tolerance' and ct.module_code = 'finance'
                         and ct.max_scope_level::text = 'entity' and ct.is_singleton
                         and ct.default_value = '{"write_off_max_minor": 0, "write_off_pct": 0}'::jsonb
                         and erp.jsonb_matches_schema(ct.value_schema::json, ct.default_value)
                         and ct.value_schema -> 'additionalProperties' = 'false'::jsonb)
          and v_tol = '{"write_off_max_minor": 100, "write_off_pct": 0}'::jsonb and v_min = 100
          and v_diff is not null
          and (select a.code from erp.account a where a.id = v_diff) = '7900'
          and exists (select 1 from erp.posting_rule r
                       where r.tenant_id = rb.tenant_id and r.code = 'settlement_difference'
                         and r.status = 'active' and r.event_type = 'cash.settlement_difference_posted')
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'finance-posting') = 3
          and not exists (select 1 from erp.plan_module_upgrade('finance-posting'))
          and not exists (select 1 from erp_ref.module_upgrade_item ui
                           where ui.install_code = 'finance-posting' and ui.object_kind = 'config')
          and not exists (select 1 from erp.dead_configuration_report() c
                           where c.reference in ('finance.settlement_tolerance', 'settlement_difference')
                              or c.reference like 'settlement_difference v%');
    detail := coalesce(v_state, format('tolerance %s, %s minor units; account %s', v_tol, v_min,
                                       coalesce((select a.code from erp.account a where a.id = v_diff), 'none')));
    return next;

    -- ── 2. A penny short settles, and the penny is written off ──────────────
    v_step := 'an invoice paid a penny short';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT2', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    perform erp.apply_cash(v_cust, v_gross - 1, v_ccy, 'ZCT2-RECEIPT', current_date);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l where l.tenant_id = rb.tenant_id and l.object_id = v_inv;
    v_cases := v_cases + 1;
    case_name := 'a penny short at £1 settles: the invoice is Paid by settle, never Part paid, the penny is a debit to 7900, the bank has what was received, and nothing is owed';
    passed := v_state is null
          and erp.object_current_state('document', v_inv) = 'paid' and v_log = 'issue,settle'
          and v_d1 - v_d0 = 1 and v_b1 - v_b0 = v_gross - 1
          and not exists (select 1 from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.party_id = v_cust);
    detail := coalesce(v_state, format('the invoice is %s by %s; 7900 moved %s, the bank %s of %s',
                                       erp.object_current_state('document', v_inv), v_log,
                                       v_d1 - v_d0, v_b1 - v_b0, v_gross - 1));
    return next;

    -- ── 3. Short by more than the tolerance stays open ──────────────────────
    v_step := 'an invoice paid £1.01 short';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT3', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    perform erp.apply_cash(v_cust, v_gross - 101, v_ccy, 'ZCT3-RECEIPT', current_date);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    select coalesce(sum(b.outstanding_minor), 0) into v_owed
      from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.document_id = v_inv;
    v_cases := v_cases + 1;
    case_name := 'short by £1.01 is outside £1: the invoice is Part paid, still owes the £1.01, and nothing is written off';
    passed := v_state is null
          and erp.object_current_state('document', v_inv) = 'part_paid'
          and v_owed = 101 and v_d1 = v_d0;
    detail := coalesce(v_state, format('the invoice is %s owing %s; 7900 moved %s',
                                       erp.object_current_state('document', v_inv), v_owed, v_d1 - v_d0));
    return next;

    -- ── 4. EUR for a GBP customer is refused ────────────────────────────────
    -- This customer owes £1.01, in the ledger's currency and nothing else.
    v_step := 'cash in a currency the customer owes nothing in';
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    v_err := null; v_hint := null;
    begin
      perform erp.apply_cash(v_cust, 10000, case when v_ccy = 'EUR' then 'USD' else 'EUR' end,
                             'ZCT4-RECEIPT', current_date);
    exception when others then
      v_err := sqlerrm;
      get stacked diagnostics v_hint = pg_exception_hint;
    end;
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    v_cases := v_cases + 1;
    case_name := 'cash in a currency the customer owes nothing in is refused by name, with a next action, and posts nothing, where it used to post nothing and say nothing';
    passed := v_state is null
          and v_err like 'CLOVEERP_CASH_CURRENCY_NOT_BOOKED%' and v_err like '%ZCT3%'
          and coalesce(v_hint, '') <> '' and v_b1 = v_b0;
    detail := coalesce(v_state, format('%s; the bank moved %s', left(coalesce(v_err, 'it was taken'), 100), v_b1 - v_b0));
    return next;

    -- ── 4a. An item in a currency not the ledger's is refused, not posted at one
    -- No document can post in a foreign currency today, so the item is
    -- written straight into the subledger, inside a block the refusal rolls
    -- back with it: it is the day translation lands that this guards.
    v_step := 'cash against an item in a currency its ledger does not report in';
    v_err := null; v_hint := null;
    begin
      insert into erp.party (tenant_id, code, name, status)
      values (rb.tenant_id, 'ZCT4A', 'Cash Tolerance ZCT4A', 'active') returning id into v_cust;
      insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                      party_id, currency, debit_minor, credit_minor, posting_date, due_date)
      select rb.tenant_id, v_entity, l.id, 'receivable', v_ar, v_cust,
             case when v_ccy = 'EUR' then 'USD' else 'EUR' end, 10000, 0, current_date, current_date
        from erp.ledger l where l.tenant_id = rb.tenant_id and l.entity_id = v_entity and l.is_primary;
      perform erp.apply_cash(v_cust, 10000, case when v_ccy = 'EUR' then 'USD' else 'EUR' end,
                             'ZCT4A-RECEIPT', current_date);
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      v_err := sqlerrm;
      get stacked diagnostics v_hint = pg_exception_hint;
    end;
    v_cases := v_cases + 1;
    case_name := 'cash against an item whose currency is not its ledger''s is refused, because every route posts at a rate of one and translation is not built';
    passed := v_state is null
          and v_err like 'CLOVEERP_NO_TRANSLATION%' and coalesce(v_hint, '') <> ''
          and not exists (select 1 from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'ZCT4A');
    detail := coalesce(v_state, left(coalesce(v_err, 'nothing refused'), 120));
    return next;

    -- ── 5. A penny over settles, and the penny is credited ──────────────────
    v_step := 'an invoice paid a penny over';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT5', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    perform erp.apply_cash(v_cust, v_gross + 1, v_ccy, 'ZCT5-RECEIPT', current_date);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    v_cases := v_cases + 1;
    case_name := 'a penny over at £1 settles: the invoice is Paid, the penny is a credit to 7900, the bank has the whole receipt, and nothing is kept on account';
    passed := v_state is null
          and erp.object_current_state('document', v_inv) = 'paid'
          and v_d1 - v_d0 = -1 and v_b1 - v_b0 = v_gross + 1
          and not exists (select 1 from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.party_id = v_cust);
    detail := coalesce(v_state, format('the invoice is %s; 7900 moved %s, the bank %s of %s',
                                       erp.object_current_state('document', v_inv), v_d1 - v_d0, v_b1 - v_b0, v_gross + 1));
    return next;

    -- ── 6. £100 over is kept on account ─────────────────────────────────────
    v_step := 'an invoice paid £100 over';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT6', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    select x.remaining_minor into v_rem
      from erp.apply_cash(v_cust, v_gross + 10000, v_ccy, 'ZCT6-RECEIPT', current_date) x
     where x.subledger_item_id is null;
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    select coalesce(sum(b.outstanding_minor), 0) into v_on
      from erp.ageing_balance b
     where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null;
    v_t1 := erp.assert_ageing_equals_control();
    v_cases := v_cases + 1;
    case_name := '£100 over: what was owed is applied and the invoice is Paid, £100 is kept on the customer''s account as an unallocated credit the ageing carries, the bank has the whole receipt, and the ageing equals the control';
    passed := v_state is null
          and erp.object_current_state('document', v_inv) = 'paid'
          and v_on = -10000 and v_rem = 10000
          and v_b1 - v_b0 = v_gross + 10000 and v_d1 = v_d0
          and coalesce(v_t1, '') <> '';
    detail := coalesce(v_state, format('the invoice is %s; on account %s, remaining %s; the bank moved %s of %s; 7900 moved %s',
                                       erp.object_current_state('document', v_inv), v_on, v_rem,
                                       v_b1 - v_b0, v_gross + 10000, v_d1 - v_d0));
    return next;

    -- ── 7. 999,999.99 is banked, all of it ──────────────────────────────────
    v_step := 'an invoice paid with 999,999.99';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT7', 411809);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    perform erp.apply_cash(v_cust, 99999999, v_ccy, 'ZCT7-RECEIPT', current_date);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    select coalesce(sum(b.outstanding_minor), 0) into v_on
      from erp.ageing_balance b
     where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null;
    v_cases := v_cases + 1;
    case_name := 'Apply cash of 999,999.99 against a smaller invoice banks all of it and keeps the rest on account, where it used to bank what was owed and drop the rest';
    passed := v_state is null
          and v_b1 - v_b0 = 99999999 and v_on = -(99999999 - v_gross)
          and erp.object_current_state('document', v_inv) = 'paid';
    detail := coalesce(v_state, format('the bank moved %s; on account %s of %s', v_b1 - v_b0, v_on, 99999999 - v_gross));
    return next;

    -- ── 8. The item route: short inside, over beyond ────────────────────────
    v_step := 'the item route, short inside the tolerance and then over beyond it';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT8', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    select si.id into v_item_row from erp.subledger_item si
     where si.tenant_id = rb.tenant_id and si.document_id = v_inv
       and si.control_kind = 'receivable' and si.debit_minor > 0;
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    perform erp.apply_cash_to_item(v_item_row, v_gross - 50, 'ZCT8-RECEIPT-1', current_date);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_s1 := erp.object_current_state('document', v_inv);
    v_err := null;
    begin
      perform erp.apply_cash_to_item(v_item_row, 100, 'ZCT8-RECEIPT-2', current_date);
    exception when others then v_err := sqlerrm; end;
    v_inv2 := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZCT8-INV-2', '{}'::jsonb);
    perform erp.add_document_line(v_inv2, v_item, 1, 50000, 'a second sale to ZCT8');
    perform erp.transition_document(v_inv2, 'issue', 'cash tolerance suite');
    select dv.gross_minor::bigint into v_gross2 from erp.document_view dv where dv.id = v_inv2;
    select si.id into v_item_row from erp.subledger_item si
     where si.tenant_id = rb.tenant_id and si.document_id = v_inv2
       and si.control_kind = 'receivable' and si.debit_minor > 0;
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    perform erp.apply_cash_to_item(v_item_row, v_gross2 + 5000, 'ZCT8-RECEIPT-3', current_date);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    select coalesce(sum(b.outstanding_minor), 0) into v_on
      from erp.ageing_balance b
     where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null;
    v_cases := v_cases + 1;
    case_name := 'a statement''s item route settles 50p short and writes it off, refuses more cash on an item that owes nothing, and takes £50 over onto the customer''s account where it used to refuse it';
    passed := v_state is null
          and v_s1 = 'paid' and v_d1 - v_d0 = 50
          and v_err like 'CLOVEERP_NOT_A_RECEIVABLE%'
          and erp.object_current_state('document', v_inv2) = 'paid'
          and v_b1 - v_b0 = v_gross2 + 5000 and v_on = -5000;
    detail := coalesce(v_state, format('50p short it was %s and 7900 moved %s; again: %s; £50 over it is %s, the bank moved %s, on account %s',
                                       v_s1, v_d1 - v_d0, left(coalesce(v_err, 'taken'), 60),
                                       erp.object_current_state('document', v_inv2), v_b1 - v_b0, v_on));
    return next;

    -- ── 9. Repeated shorts settle an invoice once, inside the tolerance ─────
    v_step := 'an invoice paid in two, the second leaving 50p';
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT9', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    perform erp.apply_cash(v_cust, v_gross - 1000, v_ccy, 'ZCT9-RECEIPT-1', current_date);
    v_s1 := erp.object_current_state('document', v_inv);
    perform erp.apply_cash(v_cust, 950, v_ccy, 'ZCT9-RECEIPT-2', current_date);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_err := null;
    begin
      perform erp.apply_cash(v_cust, 99, v_ccy, 'ZCT9-RECEIPT-3', current_date);
    exception when others then v_err := sqlerrm; end;
    select count(*) into v_n from erp.event e
     where e.tenant_id = rb.tenant_id and e.event_type = 'cash.settlement_difference_posted'
       and e.aggregate_id = v_inv;
    v_cases := v_cases + 1;
    case_name := 'a short beyond the tolerance writes nothing off, the receipt that leaves 50p writes the 50p off once and settles it, and a paid invoice cannot be shorted again';
    passed := v_state is null
          and v_s1 = 'part_paid' and erp.object_current_state('document', v_inv) = 'paid'
          and v_d1 - v_d0 = 50 and v_n = 1
          and v_err like 'CLOVEERP_CASH_CURRENCY_NOT_BOOKED%';
    detail := coalesce(v_state, format('after the first it was %s, after the second %s; 7900 moved %s in %s write-off(s); a third: %s',
                                       v_s1, erp.object_current_state('document', v_inv), v_d1 - v_d0, v_n,
                                       left(coalesce(v_err, 'taken'), 60)));
    return next;

    -- ── 10. The percentage widens the absolute limit ────────────────────────
    v_step := 'a tolerance of £1 or one per cent';
    perform erp.set_config_value('finance.settlement_tolerance',
      jsonb_build_object('write_off_max_minor', 100, 'write_off_pct', 1),
      null, null, null, null, 'the cash tolerance suite widens by percentage');
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT10', 100000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_min := erp.settlement_tolerance_minor(v_entity, v_gross);
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    perform erp.apply_cash(v_cust, v_gross - v_min, v_ccy, 'ZCT10-RECEIPT', current_date);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_s1 := erp.object_current_state('document', v_inv);
    v_inv2 := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT10B', 100000);
    select d.party_id into v_cust from erp.document d where d.id = v_inv2;
    perform erp.apply_cash(v_cust, v_gross - v_min - 1, v_ccy, 'ZCT10B-RECEIPT', current_date);
    v_s2 := erp.object_current_state('document', v_inv2);
    v_min2 := erp.settlement_tolerance_minor(v_entity, 199);
    v_min3 := erp.settlement_tolerance_minor(v_entity, 19999);
    v_cases := v_cases + 1;
    case_name := 'the percentage widens the absolute limit: one per cent of the invoice short settles it, a penny more does not, and the share is rounded down';
    passed := v_state is null
          and v_min = greatest(100, v_gross / 100) and v_min > 100
          and v_s1 = 'paid' and v_d1 - v_d0 = v_min
          and v_s2 = 'part_paid'
          and v_min2 = 100 and v_min3 = 199;
    detail := coalesce(v_state, format('tolerance %s on %s; short by it the invoice is %s and 7900 moved %s; a penny more it is %s; £1.99 gives %s and £199.99 gives %s',
                                       v_min, v_gross, v_s1, v_d1 - v_d0, v_s2, v_min2, v_min3));
    return next;

    -- ── 11. At nought nothing changes, as for an organisation before this ────
    v_step := 'a tolerance of nought, as every organisation configured before this has';
    update erp.config_object co set status = 'inactive', updated_at = now()
     where co.tenant_id = rb.tenant_id and co.config_type_code = 'finance.settlement_tolerance';
    v_tol := erp.settlement_tolerance(v_entity);
    v_min := erp.settlement_tolerance_minor(v_entity, 100000);
    v_inv := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT11', 50000);
    select dv.gross_minor::bigint, d.party_id into v_gross, v_cust
      from erp.document_view dv join erp.document d on d.id = dv.id where dv.id = v_inv;
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    perform erp.apply_cash(v_cust, v_gross - 1, v_ccy, 'ZCT11-RECEIPT', current_date);
    v_s1 := erp.object_current_state('document', v_inv);
    v_inv2 := erp_test.cash_tolerance_customer_invoice(v_entity, v_site, v_item, v_ccy, 'ZCT11B', 50000);
    select d.party_id into v_cust from erp.document d where d.id = v_inv2;
    perform erp.apply_cash(v_cust, v_gross + 1, v_ccy, 'ZCT11B-RECEIPT', current_date);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    select coalesce(sum(b.outstanding_minor), 0) into v_on
      from erp.ageing_balance b
     where b.tenant_id = rb.tenant_id and b.party_id = v_cust and b.document_id is null;
    v_cases := v_cases + 1;
    case_name := 'with the setting unset the product default of nought applies: a penny short is Part paid as it always was, a penny over is kept on account, and nothing reaches 7900';
    passed := v_state is null
          and v_tol = '{"write_off_max_minor": 0, "write_off_pct": 0}'::jsonb and v_min = 0
          and v_s1 = 'part_paid' and erp.object_current_state('document', v_inv2) = 'paid'
          and v_on = -1 and v_d1 = v_d0;
    detail := coalesce(v_state, format('tolerance %s (%s); a penny short it is %s; a penny over it is %s with %s on account; 7900 moved %s',
                                       v_tol, v_min, v_s1, erp.object_current_state('document', v_inv2), v_on, v_d1 - v_d0));
    return next;

    -- ── 12. And without the rule the tolerance is nought, whatever is set ────
    v_step := 'a tolerance set, and the rule not in force';
    perform erp.set_config_value('finance.settlement_tolerance',
      jsonb_build_object('write_off_max_minor', 100, 'write_off_pct', 0),
      null, null, null, null, 'the cash tolerance suite restores £1');
    v_min := erp.settlement_tolerance_minor(v_entity, 0);
    update erp.posting_rule set status = 'superseded'
     where tenant_id = rb.tenant_id and code = 'settlement_difference' and status = 'active';
    v_min2 := erp.settlement_tolerance_minor(v_entity, 0);
    update erp.posting_rule set status = 'active'
     where tenant_id = rb.tenant_id and code = 'settlement_difference' and status = 'superseded';
    v_min3 := erp.settlement_tolerance_minor(v_entity, 0);
    v_err := null;
    begin
      perform erp.post_settlement_difference(v_ar, -1, current_date, 'ZCT12');
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'until the settlement difference rule is in force the tolerance reads nought whatever is set, so an organisation configured before this writes nothing off before its upgrade; and a difference is refused where it cannot be posted';
    passed := v_state is null
          and v_min = 100 and v_min2 = 0 and v_min3 = 100
          and v_err like 'CLOVEERP_SETTLEMENT_DIFFERENCE_NOT_POSTABLE%';
    detail := coalesce(v_state, format('set %s, rule withdrawn %s, back %s; %s', v_min, v_min2, v_min3,
                                       left(coalesce(v_err, 'a difference was posted against an account'), 80)));
    return next;

    -- ── 13. A payment run within tolerance pays the bill ────────────────────
    v_step := 'a bill, and a run a penny short of it';
    v_po := erp.open_document('purchase_order', v_supp, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 10, 1000, 'widgets');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'cash tolerance suite');
    perform erp.transition_document(v_po, 'send', null);
    v_grn := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 10, null);
    perform erp.transition_document(v_grn, 'post', null);
    v_bill := erp.bill_from_receipt(v_grn, 'ZCT13-BILL', current_date, current_date + 30, true);
    select dv.gross_minor::bigint into v_gross from erp.document_view dv where dv.id = v_bill;
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    update erp.payment_proposal_line
       set amount_minor = amount_minor - 1
     where tenant_id = rb.tenant_id and payment_proposal_id = v_prop and not is_held;
    v_d0 := erp_test.cash_tolerance_account_movement(v_diff);
    v_b0 := erp_test.cash_tolerance_account_movement(v_bank);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_prop);
    v_pay := erp.pay_payment_run(v_prop);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_d1 := erp_test.cash_tolerance_account_movement(v_diff);
    v_b1 := erp_test.cash_tolerance_account_movement(v_bank);
    v_cases := v_cases + 1;
    case_name := 'a payment run a penny short of a bill pays it under the same tolerance: the bill is Paid, the penny is a credit to 7900, the bank paid what the run said, and the run says what it wrote off';
    passed := v_state is null
          and erp.object_current_state('document', v_bill) = 'paid'
          and (v_pay ->> 'paid_minor')::bigint = v_gross - 1
          and (v_pay ->> 'written_off_minor')::bigint = 1
          and (v_pay ->> 'documents_settled')::integer = 1
          and v_d1 - v_d0 = -1 and v_b1 - v_b0 = -(v_gross - 1)
          and not exists (select 1 from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.document_id = v_bill);
    detail := coalesce(v_state, format('the bill is %s; the run %s; 7900 moved %s, the bank %s',
                                       erp.object_current_state('document', v_bill), v_pay, v_d1 - v_d0, v_b1 - v_b0));
    return next;

    -- ── 14. Every write-off line names its rule ─────────────────────────────
    v_step := 'the settlement difference journals';
    select count(distinct j.id), count(*) filter (where jl.posting_rule_id is distinct from r.id
                                                    or jl.posting_rule_version is distinct from r.version
                                                    or jl.source_event_id is distinct from j.source_event_id)
      into v_n, v_n2
      from erp.journal j
      join erp.journal_line jl on jl.journal_id = j.id
      left join erp.posting_rule r on r.tenant_id = j.tenant_id and r.code = 'settlement_difference'
                                  and r.status = 'active'
     where j.tenant_id = rb.tenant_id and j.source_code = 'cash.settlement_difference_posted';
    v_cases := v_cases + 1;
    case_name := 'every settlement difference journal is posted, balanced, one per difference, and every line names the settlement_difference rule, its version and its event';
    passed := v_state is null
          and v_n = 6 and v_n2 = 0
          and (select count(*) from erp.event e where e.tenant_id = rb.tenant_id
                 and e.event_type = 'cash.settlement_difference_posted') = 6
          and not exists (select 1 from erp.journal j
                           where j.tenant_id = rb.tenant_id and j.source_code = 'cash.settlement_difference_posted'
                             and (j.status <> 'posted'
                                  or (select sum(jl.debit_minor) - sum(jl.credit_minor)
                                        from erp.journal_line jl where jl.journal_id = j.id) <> 0));
    detail := coalesce(v_state, format('%s journal(s), %s line(s) naming something else', v_n, v_n2));
    return next;

    -- ── 15. The ties hold with the differences and the credits in them ──────
    v_step := 'the ties';
    v_t1 := erp.assert_trial_balance_balances();
    v_t2 := erp.assert_subledger_reconciles();
    v_t3 := erp.assert_ageing_equals_control();
    v_cases := v_cases + 1;
    case_name := 'the trial balance, the subledgers and the ageing still tie, with the write-offs, the credits and the cash on account in them';
    passed := v_state is null
          and coalesce(v_t1, '') <> '' and coalesce(v_t2, '') <> '' and coalesce(v_t3, '') <> '';
    detail := coalesce(v_state, format('%s; %s; %s', left(coalesce(v_t1, 'nothing'), 60),
                                       left(coalesce(v_t2, 'nothing'), 60), left(coalesce(v_t3, 'nothing'), 60)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzctl-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2));
  detail := coalesce(v_state, 'zzctl rolled back with its invoices, its receipts, its bill and its payment run');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_CASH_TOLERANCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read the fixture''s step in the message and restore the case, or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.cash_tolerance_suite() from public, anon;

comment on function erp_test.cash_tolerance_suite() is
  'Cash settles within finance.settlement_tolerance on all three routes: short or over inside it the '
  'difference reaches 7900 and the invoice or bill is paid; over beyond it the rest is kept on the '
  'customer''s account and the bank has the whole receipt; the percentage widens the limit; at '
  'nought, or before the rule is in force, nothing changes; cash in a currency the customer owes '
  'nothing in is refused; the ties hold (20260929300000).';

create or replace function erp_test.assert_cash_tolerance_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 17;
  v_all integer; v_fail integer; v_detail text;
begin
  select count(*), count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n')
           filter (where not coalesce(s.passed, false))
    into v_all, v_fail, v_detail
    from erp_test.cash_tolerance_suite() s;
  if v_fail > 0 then
    raise exception E'CLOVEERP_CASH_TOLERANCE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using hint = 'Cash settled, wrote off, credited or kept on account other than the settlement tolerance says. Read the case that failed.';
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_CASH_TOLERANCE_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('cash tolerance: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_cash_tolerance_suite() from public, anon;

comment on function erp_test.assert_cash_tolerance_suite() is
  'Raises unless every case of erp_test.cash_tolerance_suite() passes (20260929300000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C2. The suites that count the chart
--
-- A company configured from now on has one account more, 7900 settlement
-- differences, from the finance installer or, under §8.1, from the pack. The
-- chart alternative suite (21 accounts and 21 determinations), the companies
-- suite (a second company's 16) and the demonstration chart suite (21) are
-- re-pinned deliberately to 22, 17 and 22. Each keeps its cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $counts$
declare
  r      record;
  v_def  text;
  v_pair text[];
  n      integer;
begin
  for r in
    select * from (values
      ('erp_test.chart_alternative_suite()', array[
         $o$(select count(*) from erp.account a where a.tenant_id = v_t) = 21,
    format('%s accounts, including$o$,
         $n$(select count(*) from erp.account a where a.tenant_id = v_t) = 22,  -- Re-pinned by 20260929300000: 7900.
    format('%s accounts, including$n$,
         $o$(select count(*) from erp.account a where a.tenant_id = v_t) = 21,
    format('still %s accounts$o$,
         $n$(select count(*) from erp.account a where a.tenant_id = v_t) = 22,  -- and here.
    format('still %s accounts$n$,
         $o$    n = 21,
    format('%s determinations$o$,
         $n$    n = 22,  -- and one determination more.
    format('%s determinations$n$]),
      ('erp_test.companies_suite()', array[
         $o$        and v_m = 16
$o$,
         $n$        and v_m = 17  -- Re-pinned by 20260929300000: 7900.
$n$,
         $o$%s account(s) (expected 16)$o$,
         $n$%s account(s) (expected 17)$n$]),
      ('erp_test.demo_chart_suite()', array[
         $o$where a.tenant_id = d.tenant_id) = 21
$o$,
         $n$where a.tenant_id = d.tenant_id) = 22  -- Re-pinned by 20260929300000: 7900.
$n$,
         $o$e.code = 'ACME') = 21$o$,
         $n$e.code = 'ACME') = 22$n$])
    ) v(sig, pairs)
  loop
    v_def := pg_get_functiondef(r.sig::regprocedure);
    if position('Re-pinned by 20260929300000' in v_def) > 0 then
      raise notice '% already counts 7900; left as it is', r.sig;
      continue;
    end if;
    for i in 1 .. array_length(r.pairs, 1) / 2 loop
      n := (length(v_def) - length(replace(v_def, r.pairs[2 * i - 1], ''))) / length(r.pairs[2 * i - 1]);
      if n <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor % found % time(s)', r.sig, i, n;
      end if;
      v_def := replace(v_def, r.pairs[2 * i - 1], r.pairs[2 * i]);
    end loop;
    execute v_def;
  end loop;
end
$counts$;

-- The finance suite counts the rules finance's installer promotes, and there
-- is one more, the settlement difference's. The determination coverage suite
-- retires an account some active rule names, whichever the database returns
-- first, and asks which document types would then refuse: 7900 is named only
-- by the settlement difference rule, which no document type posts by, so it
-- now picks an account a document type's rule names, as the case means. Both
-- re-pinned deliberately; each keeps its cases.
do $rules$
declare
  r      record;
  v_def  text;
  n      integer;
begin
  for r in
    select * from (values
      ('erp_test.finance_suite()',
       $o$  return query select 'promotion installs six posting rules',
    (select count(*) from erp.posting_rule pr
      where pr.tenant_id = r.tenant_id and pr.status = 'active') = 6,
    'receipt, delivery, invoice, a commitment rule for each order type, and the '
    'customer credit note that reverses the invoice (20260918170000)';$o$,
       $n$  -- Re-pinned by 20260929300000: and the settlement difference.
  return query select 'promotion installs seven posting rules',
    (select count(*) from erp.posting_rule pr
      where pr.tenant_id = r.tenant_id and pr.status = 'active') = 7,
    'receipt, delivery, invoice, a commitment rule for each order type, the '
    'customer credit note that reverses the invoice (20260918170000), and the '
    'settlement difference cash writes off (20260929300000)';$n$),
      ('erp_test.determination_coverage_suite()',
       $o$   where pr.tenant_id = v_t and pr.status = 'active'
     and (l.value ->> 'account') is not null
   limit 1;$o$,
       $n$   where pr.tenant_id = v_t and pr.status = 'active'
     and (l.value ->> 'account') is not null
     -- Re-pinned by 20260929300000: a rule some document type posts by.
     and exists (select 1 from erp.document_type dt
                  where dt.tenant_id = v_t and dt.posting_rule_code = pr.code)
   order by pr.code, l.value ->> 'account'
   limit 1;$n$)
    ) v(sig, a, b)
  loop
    v_def := pg_get_functiondef(r.sig::regprocedure);
    if position('Re-pinned by 20260929300000' in v_def) > 0 then
      raise notice '% already re-pinned; left as it is', r.sig;
      continue;
    end if;
    n := (length(v_def) - length(replace(v_def, r.a, ''))) / length(r.a);
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', r.sig, n;
    end if;
    execute replace(v_def, r.a, r.b);
  end loop;
end
$rules$;

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
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
