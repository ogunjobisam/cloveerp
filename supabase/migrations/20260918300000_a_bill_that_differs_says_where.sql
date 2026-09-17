-- =============================================================================
-- A bill that differs from the order says where the difference went
--
-- Definition of Done P2P-04: "PO at £10 per unit, supplier invoices at £10.50.
-- Expect: variance posts to a purchase price variance account. Stock is not
-- silently revalued and the difference is not absorbed into GRNI."
--
-- The difference went into GRNI. That is the defect.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Where fifty pence went before
--
-- A receipt credits goods received not invoiced with what arrived, at the
-- agreed price: a hundred widgets on a ten-pound order credit it a thousand
-- pounds. The supplier's bill then debits the same account — and the rule
-- installed on 20260916410000 measured that debit on `document_value`, which
-- is the bill. Billed at ten pounds fifty, the invoice debited a thousand and
-- fifty against a credit of a thousand, and goods received not invoiced was
-- left fifty pounds the wrong way.
--
-- Nothing failed. The journal balanced, because the payable took the gross and
-- the two sides of the bill agreed with each other. What did not agree was the
-- account with itself: erp.grni_report() takes the open balance out at the
-- ORDERED price — (received − invoiced) × the order line's unit price — so an
-- order received and billed in full leaves nothing open, while the ledger
-- balance still carried fifty pence a unit. The residue never cleared, because
-- nothing else ever touches that account for a closed order. Twelve months of
-- ordinary price drift is a control account that looks reconciled from a
-- distance and reconciles to nothing at all.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Where it goes now
--
-- Receipt, unchanged:  DR inventory 1,000 / CR goods received not invoiced 1,000.
-- Bill at 1,050:       DR goods received not invoiced 1,000
--                      DR purchase price variance        50
--                      DR tax control            (what they charged)
--                      CR trade payable          (balancing: the gross owed)
--
-- The goods-received-not-invoiced line stops being measured on the bill and is
-- measured on the receipts the bill matches; a new measure carries the
-- difference to the variance account. Stock is not touched — that is the
-- Definition of Done's own instruction, and it is also what average costing
-- already decided at the receipt: the unit cost is what the goods cost when
-- they arrived, and a bill that disagrees is a profit-and-loss event, not a
-- restatement of the shelf.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What "the receipts this bill matches" actually is, line by line
--
-- It is NOT "invoice net minus something" taken over the document. The match is
-- per line and it is per relation: erp.invoice_against() writes one invoice
-- line and one erp.document_relation from that line to the ORDER line, carrying
-- the quantity billed. So each invoice line splits in two:
--
--   a line matched to an order line  → clears at sum(relation quantity ×
--                                      the ORDER line's unit price)
--   a line matched to nothing        → clears at its own net
--
-- The first is the same arithmetic erp.grni_report() uses to take the open
-- balance out, which is why the ledger and the open receipts now meet at nil
-- rather than near it. The second keeps every bill that has no order behind it
-- — a direct invoice, a freight line added to a matched bill — posting exactly
-- as it did before today: all of it to goods received not invoiced, and no
-- variance. Absorbing an unmatched line into the variance account would put a
-- whole bill through a profit-and-loss account on the strength of a missing
-- relation, which is a worse wrong number than the one this fixes.
--
-- The variance is then the remainder, erp.document_value_minor() minus the
-- matched value, so the two measures sum to the document value by construction
-- and the payable — the balancing line — is exactly what it was before.
--
-- It is SIGNED. A bill cheaper than the order is a favourable variance and has
-- to post the other way, and erp.journal_line refuses a negative debit (0026,
-- `check (debit_minor >= 0)`). So the bridge learns that a measure which comes
-- out negative says the other side: the amount is taken positive and the line's
-- side is flipped. No measure the bridge knew before today can be negative, so
-- nothing else changes behaviour. A bill that agrees exactly measures zero, and
-- the zero-line skip 20260910165931 put into the bridge drops the line: an
-- invoice that matches raises no variance line at all.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- This is not the match exception, and the two thresholds are different
--
-- erp.match_three_way() has raised a `price_variance` exception since
-- 20260829250000, with the agreed price, the invoiced price and what the
-- difference is worth — and it has never posted anything. That is the right
-- division and it stays: the exception register decides WHO HAS TO LOOK, on a
-- tolerance an organisation sets, and the ledger decides WHERE THE MONEY WENT,
-- which is not a matter of opinion. The default tolerance is two per cent or a
-- pound, whichever is larger, so the Definition of Done's own case — fifty
-- pence on a ten-pound line — raises no exception at all and nobody is asked
-- to look. The fifty pence still has to go somewhere, and until today it went
-- into a control account nobody was reconciling. A difference small enough to
-- ignore is exactly the difference that accumulates unseen.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- And the one check that would have noticed, which could not
--
-- erp.grni_reconciliation() hard-coded account '2100' and had never been
-- touched since 20260829250000. Under the §8.1 statutory chart goods received
-- not invoiced is 3200, so on such an organisation the reconciliation returned
-- no row at all — not a difference of zero, no row — and the one report that
-- would have shown the residue showed nothing. It now asks
-- erp.tenant_account_code(), the way erp.resolve_account_purposes() was fixed
-- on 20260916090000, so it finds the account whatever the chart numbers it.
--
-- While it is open: its ledger side counted every journal line on the account,
-- posted or not, because `left join erp.journal j on … and j.status = 'posted'`
-- filters the join and not the rows. A draft journal is not a ledger balance.
-- The status is now tested inside the aggregate, which leaves the account's row
-- present when it has no posted lines — the point of the §8.1 fix — rather than
-- dropping it, as a WHERE clause would.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- This is a change with a date, and posted journals are not restated
--
-- A posting rule is versioned in place: erp.apply_change_set_item() supersedes
-- the version in force with effective_to = the promotion date and writes a new
-- version effective from it, and a journal line records the rule version that
-- produced it. Bills registered before an organisation takes this change keep
-- the journals they have, explained by the rule that was in force when they
-- were posted. Nothing is recomputed, and the residue already in a GRNI account
-- is a balance somebody clears with a journal, not something a migration moves
-- behind their back. The same reasoning as the tax determinations on
-- 20260916090000 and 20260916410000.
--
-- Existing organisations take it through the module upgrade register:
-- procurement-controls goes to version 4, and erp.plan_module_upgrade()
-- compares posting_lines rather than the rule code (20260916090000), so a
-- REVISED rule is planned rather than read as already held. The variance
-- account is planned beside it from erp_ref.module_upgrade_account, because
-- erp.determination_coverage_report() — snapshotted either side of every
-- promotion — refuses a rule naming an account a company does not have, and an
-- organisation configured before the purpose register existed may not have one.
--
-- Proof: erp_test.price_variance_suite() (16 cases, wrapper pinned), which
-- bills a £1,000 order at £1,050, at £950 and at £1,000, and asserts
-- erp.grni_reconciliation() comes back to nil after all three.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The two measures a supplier's bill splits into
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.document_matched_receipt_minor(p_document_id uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  -- What this bill clears, line by line. A line matched to an order line clears
  -- at the agreed price — the relation carries the quantity billed and the
  -- order line carries the price, which is the same arithmetic
  -- erp.grni_report() takes the open balance out at. A line matched to nothing
  -- clears at its own net, which is what every line did before today.
  select coalesce(sum(coalesce(m.matched_minor, l.net_minor)), 0)::bigint
    from erp.document_line l
    left join lateral (
      select round(sum(rel.quantity * ol.unit_price_minor))::bigint as matched_minor
        from erp.document_relation rel
        join erp.document_line ol
          on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
       where rel.tenant_id = l.tenant_id
         and rel.from_line_id = l.id
         and rel.to_line_id is not null
    ) m on true
   where l.tenant_id = erp.current_tenant_id()
     and l.document_id = p_document_id
     and not coalesce(l.is_cancelled, false)
$$;

revoke all on function erp.document_matched_receipt_minor(uuid)
  from public, anon, authenticated;

comment on function erp.document_matched_receipt_minor(uuid) is
  'The value of the receipts a supplier''s bill matches, at the price that was '
  'agreed: per invoice line, the quantity billed against each order line times '
  'that order line''s unit price, and a line matched to no order at its own net. '
  'The measure a posting line names as basis matched_receipt_value, so goods '
  'received not invoiced is debited with what the receipt credited rather than '
  'with what the supplier billed.';

create or replace function erp.document_price_variance_minor(p_document_id uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  -- The remainder, and signed. Positive is billed above the agreed price and
  -- debits the variance; negative is billed below and credits it. Taken as the
  -- remainder rather than summed again so the two measures add to the document
  -- value by construction, which is what leaves the payable untouched.
  select (erp.document_value_minor(p_document_id)
          - erp.document_matched_receipt_minor(p_document_id))::bigint
$$;

revoke all on function erp.document_price_variance_minor(uuid)
  from public, anon, authenticated;

comment on function erp.document_price_variance_minor(uuid) is
  'What a supplier billed above — or below — the price that was agreed for the '
  'receipts this bill matches. The measure a posting line names as basis '
  'price_variance. Signed: a bill cheaper than the order is a favourable '
  'variance and posts the other way, and one that agrees measures nothing and '
  'raises no line.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The bridge learns both measures, and that one of them has a sign
-- ═════════════════════════════════════════════════════════════════════════════

-- erp.post_document_finance() has been patched by 20260906060000, 20260906080000,
-- 20260906100000, 20260906131000, 20260906135000, 20260910165931, 20260916090000
-- and 20260917010000 since the file that last defines it in full, and the
-- refusal sweep of 20260904980000 rewrote its prefixes in place. It is needled
-- on the deployed text, and the patches it already carries are asserted still
-- present afterwards.
do $bridge$
declare
  v_sig    constant text := 'erp.post_document_finance(uuid)';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_basis  constant text := E'          when ''document_tax'' then erp.document_tax_minor(p_document_id)\n';
  v_side   constant text := E'      v_side := v_line ->> ''side'';\n';
  v_new    text;
begin
  if (length(v_def) - length(replace(v_def, v_basis, ''))) / length(v_basis) <> 1 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the basis of an amount in % does not carry the tax measure 20260916090000 added exactly once', v_sig;
  end if;

  if (length(v_def) - length(replace(v_def, v_side, ''))) / length(v_side) <> 1 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the side of a non-balancing line in % is not the one this migration adds to', v_sig;
  end if;

  v_new := replace(v_def, v_basis, v_basis
    || E'          when ''matched_receipt_value'' then erp.document_matched_receipt_minor(p_document_id)\n'
    || E'          when ''price_variance'' then erp.document_price_variance_minor(p_document_id)\n');

  v_new := replace(v_new, v_side, v_side
    || E'\n'
    || E'      -- A measure that can come out negative is saying the other side.\n'
    || E'      -- A bill cheaper than the order is a favourable price variance, and\n'
    || E'      -- erp.journal_line refuses a negative debit, so the amount is taken\n'
    || E'      -- positive and the side is flipped. No measure that existed before\n'
    || E'      -- 20260918300000 can be negative, so nothing else moves.\n'
    || E'      if v_amount < 0 then\n'
    || E'        v_amount := - v_amount;\n'
    || E'        v_side := case when v_side = ''debit'' then ''credit'' else ''debit'' end;\n'
    || E'      end if;\n');

  -- Every patch the deployed body already had, still there afterwards. A
  -- re-emission from a file would have dropped all of these silently.
  if position('erp.document_matched_receipt_minor(p_document_id)' in v_new) = 0
     or position('erp.document_price_variance_minor(p_document_id)' in v_new) = 0
     or position(E'        v_side := case when v_side = ''debit'' then ''credit'' else ''debit'' end;\n' in v_new) = 0
     or position('erp.derive_dimensions(p_document_id, acc.code, v_line,' in v_new) = 0
     or position('led.id),' in v_new) = 0
     or position('erp.posting_line_account_code(v_line, p_document_id, led.id)' in v_new) = 0
     or position('erp.document_tax_minor(p_document_id)' in v_new) = 0
     or position('d.order_behaviour_code = ''blanket''' in v_new) = 0
     or position('d.stock_owner_party_id is not null' in v_new) = 0
     or position('CLOVEERP_NO_PRICE_TO_POST' in v_new) = 0
     or position(E'    if v_amount = 0 then\n      v_no := v_no - 1;' in v_new) = 0 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the patched body of % has lost a patch it carried', v_sig;
  end if;

  execute v_new;
end
$bridge$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A basis the bridge does not know is still a wrong number, quietly
-- ═════════════════════════════════════════════════════════════════════════════

-- 20260916090000 wrote the whitelist because the bridge reads an unrecognised
-- basis as the document value — a plausible wrong number, for ever, with
-- nothing saying so. Two measures joining it have to join the list, or
-- promotion refuses the very rule this migration ships. Needled rather than
-- re-emitted so nothing else in that body is disturbed.
do $whitelist$
declare
  v_sig     constant text := 'erp.assert_posting_rule_balances(text, integer)';
  v_def     text := pg_get_functiondef(v_sig::regprocedure);
  v_list    constant text :=
    E'     and l.value ->> ''basis'' not in (''document_value'', ''stock_cost'', ''document_tax'');';
  v_hint    constant text :=
    E'      hint = ''A line is measured on the document value, the stock cost or the tax on the document.'';';
  v_comment constant text :=
       E'  -- And every basis one of three. The bridge reads an unrecognised basis as the\n'
    || E'  -- document value, so a rule that named one would post a plausible wrong\n'
    || E'  -- number for ever without anything saying so.\n';
  v_new     text;
begin
  if (length(v_def) - length(replace(v_def, v_list, ''))) / length(v_list) <> 1 then
    raise exception 'CLOVEERP_WHITELIST_UNRECOGNISED: the basis whitelist in % is not the one 20260916090000 wrote', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_hint, ''))) / length(v_hint) <> 1 then
    raise exception 'CLOVEERP_WHITELIST_UNRECOGNISED: the whitelist hint in % is not the one 20260916090000 wrote', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_comment, ''))) / length(v_comment) <> 1 then
    raise exception 'CLOVEERP_WHITELIST_UNRECOGNISED: the whitelist comment in % is not the one 20260916090000 wrote', v_sig;
  end if;

  v_new := replace(v_def, v_list,
       E'     and l.value ->> ''basis'' not in (''document_value'', ''stock_cost'', ''document_tax'',\n'
    || E'                                      ''matched_receipt_value'', ''price_variance'');');

  v_new := replace(v_new, v_hint,
       E'      hint = ''A line is measured on the document value, the stock cost, the tax on the document, the receipts a supplier''''s bill matches, or the difference between the two.'';');

  v_new := replace(v_new, v_comment,
       E'  -- And every basis one the bridge measures. The bridge reads an unrecognised\n'
    || E'  -- basis as the document value, so a rule that named one would post a plausible\n'
    || E'  -- wrong number for ever without anything saying so. 20260918300000 added the\n'
    || E'  -- two a supplier''s bill splits into.\n');

  if position('matched_receipt_value' in v_new) = 0
     or position('price_variance' in v_new) = 0
     or position('CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION' in v_new) = 0
     or position('erp.posting_rule_raises_nothing(v_lines)' in v_new) = 0
     or position('CLOVEERP_POSTING_RULE_SIDE' in v_new) = 0
     or position('erp.posting_rule_imbalance(v_lines)' in v_new) = 0 then
    raise exception 'CLOVEERP_WHITELIST_UNRECOGNISED: the patched body of % has lost something it carried', v_sig;
  end if;

  execute v_new;
end
$whitelist$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The reconciliation finds the account wherever the chart puts it
-- ═════════════════════════════════════════════════════════════════════════════

-- Guarded before it is replaced, because a body that has moved on since
-- 20260829250000 is one this replacement would silently undo.
do $recon$
declare
  v_def  text := pg_get_functiondef('erp.grni_reconciliation()'::regprocedure);
  v_code constant text := E'     and a.code = ''2100''\n';
begin
  if (length(v_def) - length(replace(v_def, v_code, ''))) / length(v_code) <> 1 then
    raise exception 'CLOVEERP_RECONCILIATION_UNRECOGNISED: erp.grni_reconciliation() does not name account 2100 exactly once; it is no longer the body 20260829250000 wrote';
  end if;
  if position('erp.grni_report()' in v_def) = 0 then
    raise exception 'CLOVEERP_RECONCILIATION_UNRECOGNISED: erp.grni_reconciliation() no longer reads erp.grni_report()';
  end if;
end
$recon$;

create or replace function erp.grni_reconciliation()
returns table (account_code text, ledger_minor bigint,
               open_receipts_minor bigint, difference_minor bigint)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_code   text;
begin
  -- No organisation in context reconciles nothing, which is what this answered
  -- before. erp.tenant_account_code() refuses rather than returning nothing
  -- when there is no organisation, and a report is not where anybody should
  -- learn that, so the question is not asked.
  if v_tenant is null then
    return;
  end if;

  -- The account is asked for by purpose, not by number: 2100 is goods received
  -- not invoiced under the default chart and the BANK under §8.1, where goods
  -- received not invoiced is 3200. Hard-coded since 20260829250000, this
  -- returned no row at all on a §8.1 organisation — not a difference of zero,
  -- nothing — so the one report that would have shown a polluted balance
  -- showed an empty result.
  v_code := erp.tenant_account_code('goods_received_not_invoiced');

  -- The ledger balance on that account against the receipts that are actually
  -- open. Two independent derivations of the same figure, which is the only
  -- kind of reconciliation worth running.
  --
  -- And only posted journals are a ledger balance. `left join … and status =
  -- 'posted'` filtered the join rather than the rows, so a draft journal
  -- counted; the status is tested inside the aggregate instead, which keeps the
  -- account's row when it has no posted lines rather than dropping it the way a
  -- WHERE clause would.
  return query
    select a.code,
           coalesce(sum(case when j.status = 'posted'
                             then l.credit_minor - l.debit_minor else 0 end), 0)::bigint,
           coalesce((select sum(g.open_value_minor) from erp.grni_report() g), 0)::bigint,
           coalesce(sum(case when j.status = 'posted'
                             then l.credit_minor - l.debit_minor else 0 end), 0)::bigint
             - coalesce((select sum(g.open_value_minor) from erp.grni_report() g), 0)::bigint
      from erp.account a
      left join erp.journal_line l on l.account_id = a.id
      left join erp.journal j on j.id = l.journal_id
     where a.tenant_id = v_tenant
       and a.code = v_code
     group by a.code;
end;
$$;

comment on function erp.grni_reconciliation() is
  'Spec 5.3: the goods-received-not-invoiced account against the receipts that '
  'are open, as two independent derivations of one figure. The account is found '
  'by purpose rather than by number, so it reconciles under either chart, and '
  'only posted journals count as a ledger balance.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The rule an organisation is given from now on
-- ═════════════════════════════════════════════════════════════════════════════

do $installer$
declare
  v_sig constant text := 'erp.configure_procurement_controls(text, numeric, numeric, bigint)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
       E'            jsonb_build_object(''account'', v_grni,''side'',''debit'',\n'
    || E'                               ''basis'',''document_value'',''rate'',1,\n'
    || E'                               ''description'',''Clearing goods received not invoiced''),\n';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_PROCUREMENT_INSTALLER_UNRECOGNISED: the goods-received-not-invoiced line in % is not the one 20260916410000 left. It reads: %',
      v_sig, substr(v_def, greatest(position('purchase_invoice' in v_def), 1), 600);
  end if;

  v_new := replace(v_def, v_needle,
       E'            jsonb_build_object(''account'', v_grni,''side'',''debit'',\n'
    || E'                               ''basis'',''matched_receipt_value'',''rate'',1,\n'
    || E'                               ''description'',''Clearing goods received not invoiced, at what the receipt credited''),\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''purchase_price_variance''),''side'',''debit'',\n'
    || E'                               ''basis'',''price_variance'',''rate'',1,\n'
    || E'                               ''description'',''Purchase price variance''),\n');

  if position('''basis'',''matched_receipt_value''' in v_new) = 0
     or position('''basis'',''price_variance''' in v_new) = 0
     or position('''basis'',''document_tax''' in v_new) = 0
     or position('''balancing'',true' in v_new) = 0
     or position('erp.tenant_account_code(''tax_control'')' in v_new) = 0 then
    raise exception 'CLOVEERP_PROCUREMENT_INSTALLER_UNRECOGNISED: the patched body of % has lost a line it carried', v_sig;
  end if;

  execute v_new;
end
$installer$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. And the organisations already configured are offered it
-- ═════════════════════════════════════════════════════════════════════════════

update erp_ref.module_installer
   set current_version = 4,
       description = 'The supplier bill, the payment rule and the match tolerances. '
                     'Version 2 (20260916410000) debits the tax a supplier charged to '
                     'the tax control account and makes the payable the gross owed; '
                     'version 3 (20260918170000) adds the supplier credit note; '
                     'version 4 (20260918300000) debits goods received not invoiced '
                     'with what the receipt credited and posts the difference to '
                     'purchase price variance, so a bill above or below the agreed '
                     'price no longer leaves a residue nothing clears.'
 where install_code = 'procurement-controls';

-- The rule, in the shape erp.plan_module_upgrade() compares: it resolves
-- {"purpose": …} through erp.tenant_account_code() and compares the resolved
-- posting_lines with the rule the organisation holds, so this has to correspond
-- line for line and key for key with what the installer above writes, or the
-- upgrade would be offered for ever.
insert into erp_ref.module_upgrade_item
  (install_code, to_version, object_kind, object_key, payload, seq)
values
  ('procurement-controls', 4, 'posting_rule', 'purchase_invoice',
   jsonb_build_object(
     'code', 'purchase_invoice', 'name', 'Purchase invoice', 'ledger', 'GL',
     'event_type', 'document.purchase_invoice.registered',
     'posting_lines', jsonb_build_array(
       jsonb_build_object('account', jsonb_build_object('purpose', 'goods_received_not_invoiced'),
                          'side', 'debit', 'basis', 'matched_receipt_value', 'rate', 1,
                          'description', 'Clearing goods received not invoiced, at what the receipt credited'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'purchase_price_variance'),
                          'side', 'debit', 'basis', 'price_variance', 'rate', 1,
                          'description', 'Purchase price variance'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'tax_control'),
                          'side', 'debit', 'basis', 'document_tax', 'rate', 1,
                          'description', 'Tax the supplier charged'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'trade_payable'),
                          'side', 'credit', 'balancing', true,
                          'description', 'Trade payable'))),
   120)
on conflict (install_code, to_version, object_kind, object_key) do update
  set payload = excluded.payload, seq = excluded.seq;

-- And the account the rule now names, for the companies that lack it. An
-- account is master data rather than configuration, which is why the register
-- carries it separately; erp.plan_module_upgrade() plans one per active company
-- and orders it ahead of the rule. Without this,
-- erp.determination_coverage_report() would find a posting rule naming an
-- account a company does not have, and the promotion that brought the rule
-- would be refused with it — which is the correct refusal and a bad morning.
insert into erp_ref.module_upgrade_account (install_code, to_version, purpose)
values ('procurement-controls', 4, 'purchase_price_variance')
on conflict do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.price_variance_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 16;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_pinv uuid;
  v_po2 uuid; v_pol2 uuid; v_grn2 uuid; v_pinv2 uuid;
  v_po3 uuid; v_pol3 uuid; v_grn3 uuid; v_pinv3 uuid;
  v_pinv4 uuid;
  v_grni text; v_ppv text; v_inv_acc text; v_ap text; v_tax_acc text;
  v_lines jsonb;
  v_dr bigint; v_cr bigint; v_ppv_dr bigint; v_ppv_cr bigint;
  v_tax_dr bigint; v_ap_cr bigint;
  v_inv_bal bigint; v_unit bigint; v_n integer;
  g record;
begin
  begin
    v_step := 'an organisation with finance, procurement, sales, inventory and controls';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzppv-' || v_tag, 'Price Variance Suite',
      'admin@zzppv-' || v_tag || '.test', 'Price Variance Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzppv-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();

    v_grni    := erp.tenant_account_code('goods_received_not_invoiced');
    v_ppv     := erp.tenant_account_code('purchase_price_variance');
    v_inv_acc := erp.tenant_account_code('inventory');
    v_ap      := erp.tenant_account_code('trade_payable');
    v_tax_acc := erp.tenant_account_code('tax_control');

    v_step := 'its own unit, site, places, supplier and product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZPEA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZPSITE', 'Price variance suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZP-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZP-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZPSUP', 'Price Variance Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPWID', 'Price Variance Suite Widget', v_uom, 'active')
    returning id into v_item;

    -- ── 1. The rule a new organisation is given ─────────────────────────────
    v_step := 'the supplier bill rule a new organisation holds';
    select r.posting_lines into v_lines
      from erp.posting_rule r
     where r.tenant_id = rb.tenant_id and r.code = 'purchase_invoice'
       and r.status = 'active'
     order by r.version desc limit 1;

    v_cases := v_cases + 1;
    case_name := 'a supplier bill clears the receipt, carries the difference, and owes the gross';
    passed := v_state is null
          and jsonb_array_length(coalesce(v_lines, '[]'::jsonb)) = 4
          and exists (select 1 from jsonb_array_elements(v_lines) l
                       where l.value ->> 'account' = v_grni
                         and l.value ->> 'side' = 'debit'
                         and l.value ->> 'basis' = 'matched_receipt_value')
          and exists (select 1 from jsonb_array_elements(v_lines) l
                       where l.value ->> 'account' = v_ppv
                         and l.value ->> 'side' = 'debit'
                         and l.value ->> 'basis' = 'price_variance')
          and exists (select 1 from jsonb_array_elements(v_lines) l
                       where l.value ->> 'account' = v_tax_acc
                         and l.value ->> 'basis' = 'document_tax')
          and (select count(*) from jsonb_array_elements(v_lines) l
                where coalesce((l.value ->> 'balancing')::boolean, false)) = 1;
    detail := format('%s line(s): %s debited on what was received, %s on the difference, %s on the tax, %s balancing',
                     jsonb_array_length(coalesce(v_lines, '[]'::jsonb)),
                     v_grni, v_ppv, v_tax_acc, v_ap);
    return next;

    -- ── 2. Four lines, one balancing, and it still balances ─────────────────
    v_step := 'the rule balances at promotion';
    v_cases := v_cases + 1;
    case_name := 'four lines with one balancing line balance, on measures the bridge knows';
    begin
      perform erp.assert_posting_rule_balances('purchase_invoice',
        (select max(r.version) from erp.posting_rule r
          where r.tenant_id = rb.tenant_id and r.code = 'purchase_invoice'));
      passed := v_state is null;
      detail := 'erp.posting_rule_imbalance() takes a balancing line as absorbing whatever is left';
    exception when others then
      passed := false; detail := left(sqlerrm, 200);
    end;
    return next;

    -- ── 3. A hundred widgets arrive on a ten-pound order ────────────────────
    v_step := 'a hundred widgets are ordered at ten pounds and arrive';
    v_po := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets at ten pounds');
    perform erp.transition_document(v_po, 'submit', 'price variance suite');
    perform erp_test.approve_document(v_po, 'price variance suite');
    perform erp.transition_document(v_po, 'send', 'price variance suite');
    v_grn := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'price variance suite');

    select coalesce(sum(jl.credit_minor), 0) into v_cr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_grn and a.code = v_grni;
    select coalesce(sum(jl.debit_minor), 0) into v_dr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_grn and a.code = v_inv_acc;

    v_cases := v_cases + 1;
    case_name := 'the receipt credits goods received not invoiced with what was ordered';
    passed := v_state is null and v_cr = 100000 and v_dr = 100000;
    detail := format('%s credited to %s, %s debited to %s', v_cr, v_grni, v_dr, v_inv_acc);
    return next;

    -- ── 4, 5, 6, 7. Billed at ten pounds fifty ──────────────────────────────
    v_step := 'the supplier bills the same hundred at ten pounds fifty';
    v_pinv := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.invoice_against(v_pinv, v_pol, 100, 1050);
    perform erp.state_supplier_tax(v_pinv, 21000, 'S', 'price variance suite: what the bill says');
    perform erp.transition_document(v_pinv, 'register', 'price variance suite');

    select coalesce(sum(jl.debit_minor) filter (where a.code = v_grni), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_ppv), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_ppv), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_tax_acc), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_ap), 0)
      into v_dr, v_ppv_dr, v_ppv_cr, v_tax_dr, v_ap_cr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_pinv;

    v_cases := v_cases + 1;
    case_name := 'the bill debits goods received not invoiced with what the receipt credited, not with what was billed';
    passed := v_state is null and v_dr = 100000;
    detail := format('%s debited to %s against a bill of %s',
                     v_dr, v_grni, erp.document_value_minor(v_pinv));
    return next;

    v_cases := v_cases + 1;
    case_name := 'and the fifty pence a unit is a purchase price variance';
    passed := v_state is null and v_ppv_dr = 5000 and v_ppv_cr = 0;
    detail := format('%s debited to %s, %s credited', v_ppv_dr, v_ppv, v_ppv_cr);
    return next;

    v_cases := v_cases + 1;
    case_name := 'the supplier is owed the gross they billed, and the tax they charged is reclaimable';
    passed := v_state is null and v_ap_cr = 126000 and v_tax_dr = 21000;
    detail := format('%s owed on %s to %s, %s of tax debited to %s',
                     v_ap_cr, v_ap, v_sup, v_tax_dr, v_tax_acc);
    return next;

    select coalesce(sum(jl.debit_minor), 0), coalesce(sum(jl.credit_minor), 0), count(*)
      into v_dr, v_cr, v_n
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
     where j.tenant_id = rb.tenant_id and j.document_id = v_pinv;

    v_cases := v_cases + 1;
    case_name := 'and the journal balances on four lines';
    passed := v_state is null and v_n = 4 and v_dr = v_cr and v_dr = 126000;
    detail := format('%s line(s), %s debited against %s credited', v_n, v_dr, v_cr);
    return next;

    -- ── 8. Stock is not revalued ────────────────────────────────────────────
    select c.unit_cost_minor into v_unit from erp.item_cost c
     where c.tenant_id = rb.tenant_id and c.item_id = v_item;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_inv_bal
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.status = 'posted' and a.code = v_inv_acc;

    v_cases := v_cases + 1;
    case_name := 'stock is not silently revalued by a bill that disagrees with the order';
    passed := v_state is null and v_unit = 1000 and v_inv_bal = 100000;
    detail := format('unit cost %s, inventory %s — what the goods cost when they arrived',
                     v_unit, v_inv_bal);
    return next;

    -- ── 9. And the account reconciles ───────────────────────────────────────
    select * into g from erp.grni_reconciliation();
    v_cases := v_cases + 1;
    case_name := 'goods received not invoiced comes back to nil after the bill';
    passed := v_state is null and g.account_code = v_grni and g.difference_minor = 0;
    detail := format('%s: ledger %s against open receipts %s, difference %s',
                     g.account_code, g.ledger_minor, g.open_receipts_minor, g.difference_minor);
    return next;

    -- ── 10, 11. The favourable direction ────────────────────────────────────
    v_step := 'a second hundred, billed at nine pounds fifty';
    v_po2 := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol2 := erp.add_document_line(v_po2, v_item, 100, 1000, 'another hundred at ten pounds');
    perform erp.transition_document(v_po2, 'submit', 'price variance suite');
    perform erp_test.approve_document(v_po2, 'price variance suite');
    perform erp.transition_document(v_po2, 'send', 'price variance suite');
    v_grn2 := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn2, v_pol2, 100, null);
    perform erp.transition_document(v_grn2, 'post', 'price variance suite');
    v_pinv2 := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.invoice_against(v_pinv2, v_pol2, 100, 950);
    perform erp.transition_document(v_pinv2, 'register', 'price variance suite');

    select coalesce(sum(jl.debit_minor) filter (where a.code = v_grni), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_ppv), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_ppv), 0),
           coalesce(sum(jl.credit_minor) filter (where a.code = v_ap), 0)
      into v_dr, v_ppv_dr, v_ppv_cr, v_ap_cr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_pinv2;

    v_cases := v_cases + 1;
    case_name := 'a bill below the agreed price credits the variance instead of debiting it';
    passed := v_state is null and v_ppv_cr = 5000 and v_ppv_dr = 0;
    detail := format('%s credited to %s, %s debited', v_ppv_cr, v_ppv, v_ppv_dr);
    return next;

    v_cases := v_cases + 1;
    case_name := 'and it still debits goods received not invoiced with what the receipt credited';
    passed := v_state is null and v_dr = 100000 and v_ap_cr = 95000;
    detail := format('%s debited to %s, %s owed on %s', v_dr, v_grni, v_ap_cr, v_ap);
    return next;

    -- ── 12. A bill that agrees raises no variance line at all ───────────────
    v_step := 'a third hundred, billed at exactly what was agreed';
    v_po3 := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol3 := erp.add_document_line(v_po3, v_item, 100, 1000, 'a third hundred at ten pounds');
    perform erp.transition_document(v_po3, 'submit', 'price variance suite');
    perform erp_test.approve_document(v_po3, 'price variance suite');
    perform erp.transition_document(v_po3, 'send', 'price variance suite');
    v_grn3 := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn3, v_pol3, 100, null);
    perform erp.transition_document(v_grn3, 'post', 'price variance suite');
    v_pinv3 := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.invoice_against(v_pinv3, v_pol3, 100, 1000);
    perform erp.transition_document(v_pinv3, 'register', 'price variance suite');

    select count(*) into v_n
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
     where j.tenant_id = rb.tenant_id and j.document_id = v_pinv3;

    v_cases := v_cases + 1;
    case_name := 'a bill that agrees with the order raises no variance line at all';
    passed := v_state is null and v_n = 2
          and not exists (
            select 1 from erp.journal j
              join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
              join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
             where j.tenant_id = rb.tenant_id and j.document_id = v_pinv3 and a.code = v_ppv);
    detail := format('%s line(s): the difference is nothing, and a zero line says nothing', v_n);
    return next;

    -- ── 13. Nil after all three ─────────────────────────────────────────────
    select * into g from erp.grni_reconciliation();
    v_cases := v_cases + 1;
    case_name := 'and after three hundred widgets billed three different ways, the account is still nil';
    passed := v_state is null and g.difference_minor = 0 and g.ledger_minor = 0;
    detail := format('ledger %s against open receipts %s, difference %s',
                     g.ledger_minor, g.open_receipts_minor, g.difference_minor);
    return next;

    -- ── 14. A bill with no order behind it is not a variance ────────────────
    v_step := 'a bill with no order behind it at all';
    v_pinv4 := erp.open_document('purchase_invoice', v_sup, rb.entity_id, v_site);
    perform erp.add_document_line(v_pinv4, v_item, 1, 4000, 'billed with no order behind it');
    perform erp.transition_document(v_pinv4, 'register', 'price variance suite');

    select coalesce(sum(jl.debit_minor) filter (where a.code = v_grni), 0),
           coalesce(sum(jl.debit_minor) filter (where a.code = v_ppv), 0)
             + coalesce(sum(jl.credit_minor) filter (where a.code = v_ppv), 0),
           count(*)
      into v_dr, v_ppv_dr, v_n
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_pinv4;

    v_cases := v_cases + 1;
    case_name := 'a bill with no order behind it clears in full, exactly as it did before';
    passed := v_state is null and v_dr = 4000 and v_ppv_dr = 0 and v_n = 2;
    detail := format('%s line(s): %s to %s and nothing to %s — a missing relation is not a variance',
                     v_n, v_dr, v_grni, v_ppv);
    return next;

    -- ── 15. Wherever the chart puts it ──────────────────────────────────────
    --
    -- Renumbered to §8.1's code for goods received not invoiced. Before today
    -- the reconciliation asked for 2100 and came back with NO ROW on such an
    -- organisation, so the direct bill's four pounds — a real open difference —
    -- was reported as nothing at all. Done last, because the posting rule still
    -- names the old code and nothing may post after it.
    v_step := 'the account renumbered the way the §8.1 chart numbers it';
    update erp.account a
       set code = '3200', updated_at = now()
     where a.tenant_id = rb.tenant_id and a.code = v_grni;

    select * into g from erp.grni_reconciliation();
    v_cases := v_cases + 1;
    case_name := 'the reconciliation finds goods received not invoiced wherever the chart numbers it, and says what is out';
    passed := v_state is null and g.account_code = '3200'
          and g.ledger_minor = -4000 and g.difference_minor = -4000;
    detail := format('renumbered from %s to %s: ledger %s against open receipts %s, out by %s',
                     v_grni, coalesce(g.account_code, 'no row at all'),
                     g.ledger_minor, g.open_receipts_minor, g.difference_minor);
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzppv-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzppv rolled back with its orders, its receipts and its bills');
  return next;

  -- The count guard says what stopped the fixture. Without this the wrapper
  -- never sees a row, so the message this suite caught into v_state — and the
  -- step that produced it — never reaches the build log, and every break costs
  -- a run to find.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PRICE_VARIANCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.price_variance_suite() from public, anon;

create or replace function erp_test.assert_price_variance_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 16;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _price_variance on commit drop as
    select * from erp_test.price_variance_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _price_variance;
  drop table _price_variance;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PRICE_VARIANCE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_PRICE_VARIANCE_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a bill that differs says where: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_price_variance_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();

select erp_test.assert_price_variance_suite();
-- The two suites that register a supplier bill against an order, proved here
-- rather than left to the catalogue: erp_test.finance_depth_suite() bills one
-- at the agreed price and one at half as much again, and its own
-- goods-received-not-invoiced reconciliation case is the one this migration
-- exists to make true. erp_test.procurement_controls_suite() is where the
-- price variance has been detected — and never posted — since 20260829250000.
select erp_test.assert_finance_depth_suite();
select erp_test.assert_procurement_controls_suite();
