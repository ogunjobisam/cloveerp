-- An invoice says its tax.
--
-- erp.determine_tax() has existed since 20260829300000 and erp.tax_determination
-- since B7. Three packs of real legislation arrived in 20260906081000, with the
-- statute behind every rate. erp.tax_report() has been on the Finance screens
-- throughout, and 20260914086000 repaired the panel that was asking it for a
-- column it does not answer.
--
-- Nothing has ever called erp.determine_tax() outside a suite. Two suites call
-- it — the finance-depth suite of 20260829300000 and the legislation suite of
-- 20260906081000 — and no part of the document lifecycle does. So every invoice
-- this product has ever raised carries tax_code null, tax_rate_pct null and
-- tax_minor null; erp.tax_determination has never held a row outside a rolled
-- back fixture; and erp.tax_report() cannot return anything, for any period, in
-- any organisation. The demonstration organisation has a year of trading and
-- eighty-five customer invoices, and its Tax report is empty for every period
-- anybody asks for. The product sells to British manufacturers and distributors.
--
-- This connects the chain that already existed:
--
--   a line becomes billable  →  erp.determine_tax()  →  erp.tax_determination
--                            →  the line's own tax_code, rate and tax
--                            →  erp.sales_invoice_contract() and the PDF
--                            →  erp.tax_report()
--
-- Where the determination happens. At the moment the document commits — the
-- same moment, and by the same mechanism, that 20260906081000 chose for
-- allocating a gapless invoice number: an after-update trigger on
-- erp.object_state watching current_state_id, guarded on the new state being
-- committed. A draft invoice is not a supply; an issued one is. Putting it in
-- a trigger rather than in erp.transition_document() means every route into a
-- committed state reaches it, including the ones a later migration adds.
--
-- What is NOT determined, and why each:
--
--   * Anything that is not an invoice or a credit. A quotation and an order are
--     offers, not supplies, and the tax point is the invoice. A tenant who wants
--     VAT shown on an order form is asking for a quotation of the tax, which is
--     a different thing from a determination and should not write one.
--
--   * A purchase invoice. erp.tax_report() groups by jurisdiction, code and
--     rate and carries no direction, so an input-tax determination would be
--     added to output tax in the same row and the return would be wrong by
--     twice the purchase. Direction on the report is the first thing the
--     purchase side needs; it is not built here.
--
--   * An invoice whose direction the product cannot tell. erp.document has a
--     party_role_id column and erp.create_document() has never set it — which
--     is also why erp.ageing, the view behind the Receivables and payables
--     ageing report, reads 'other' for the direction of every document this
--     product raises. So the side is taken from the party's roles: a party
--     holding a customer role and no supplier role is a sale. A party holding
--     both is ambiguous, nothing is determined, and erp.tax_outside_the_ledger_report()
--     names the document rather than guessing.
--
--   * An invoice already issued. A determination is made when the invoice is
--     raised. Backfilling one onto an invoice that has already gone to a
--     customer would change what the screen says about a document whose issued
--     PDF says something else, and erp.sales_invoice_contract() froze that PDF
--     on purpose. The demonstration's existing year of trading therefore stays
--     tax-free; a demonstration organisation seeded after this trades with VAT
--     from its first slice.
--
--   * The ledger. See below; it is the one thing here that needs a decision.
--
-- An organisation with no tax rules determines nothing rather than failing.
-- erp.determine_tax() refuses when no rule covers a supply, correctly — "a
-- guessed rate is a filing error with a number on it" — but an organisation
-- that has never configured tax has no rule to cover anything, and a product
-- that could not raise an invoice until somebody configured VAT would be worse
-- than one that raises it without. So erp.tax_rules_in_force() asks first,
-- reading the same two layers erp.evaluate_rules() reads: the legislation packs
-- bound to the company, then the tenant's own promoted rule set. No rules, no
-- determination, no refusal. Rules and no matching rule is still a refusal,
-- because that is a supply somebody configured tax for and did not cover.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does not do: the ledger
--
-- A determined invoice for £100 net now says £20 VAT and £120 gross on the
-- document, in the contract and on the PDF. The journal still debits trade
-- receivables £100 and credits revenue £100, because that is what the promoted
-- sales_invoice posting rule says and it is not changed here. So for as long as
-- this stands alone, the invoice and the receivable disagree by the tax.
--
-- The reason is not the missing account. There is a tax control account: the
-- finance installer creates 2200 Tax payable with control_kind 'tax', and
-- erp_ref.chart_account_purpose has carried the 'tax_control' purpose since
-- 20260904160000 — close-blocking, reconciliation-required, 2200 under the
-- default chart and 3300 under the §8.1 statutory one, reachable by name
-- through erp.chart_account_code('tax_control'). It has simply never been
-- posted to, which is why it does not appear on a trial balance.
--
-- The reasons are two, and both are decisions rather than code:
--
--   1. erp.post_document_finance() apportions one number — either
--      erp.document_value_minor(), which is the sum of the lines' net, or the
--      stock cost — across the posting rule's lines by a rate. A VAT posting
--      needs three lines on two different bases: the receivable on gross, the
--      revenue on net, the tax control on tax. That is a change to the posting
--      bridge and a third line on the promoted sales_invoice rule in every
--      organisation that already has one, and erp.guard_live_configuration()
--      means a live organisation's posting rule changes only by promotion.
--      A branch is changing the posting configuration as this is written.
--
--   2. Making the receivable gross changes what every organisation's ledger
--      says the moment tax is configured, and the credit limit, the approval
--      bands and the cash application all read erp.document_value_minor().
--      Whether that is the day's work or the quarter's is the owner's call.
--
-- Until it is taken, erp.tax_outside_the_ledger_report() names every document
-- whose determined tax reached no tax account, per organisation, on the
-- diagnostics screen. It is a report and not an assertion deliberately: the
-- gap is known, it is named, and it should be visible without failing a build
-- that is correct about everything it claims.
-- ─────────────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Which side of the trade a document is on
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.document_trade_side(p_document_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_party  uuid;
  v_role   uuid;
  v_kind   text;
  v_cust   boolean;
  v_supp   boolean;
begin
  select d.party_id, d.party_role_id into v_party, v_role
    from erp.document d
   where d.tenant_id = v_tenant and d.id = p_document_id;
  if v_party is null then
    return 'unknown';
  end if;

  -- The document named a role: that is the answer, whatever else the party is.
  if v_role is not null then
    select pr.role_kind::text into v_kind
      from erp.party_role pr
     where pr.tenant_id = v_tenant and pr.id = v_role;
    return case v_kind when 'customer' then 'sale'
                       when 'supplier' then 'purchase'
                       else 'unknown' end;
  end if;

  -- It did not, because erp.create_document() has never set the column. Fall
  -- back to the party's roles, and say 'unknown' rather than pick when a party
  -- both buys and sells.
  select exists (select 1 from erp.party_role pr
                  where pr.tenant_id = v_tenant and pr.party_id = v_party
                    and pr.role_kind = 'customer' and pr.status = 'active'),
         exists (select 1 from erp.party_role pr
                  where pr.tenant_id = v_tenant and pr.party_id = v_party
                    and pr.role_kind = 'supplier' and pr.status = 'active')
    into v_cust, v_supp;

  return case when v_cust and not v_supp then 'sale'
              when v_supp and not v_cust then 'purchase'
              else 'unknown' end;
end;
$$;
revoke all on function erp.document_trade_side(uuid) from public, anon, authenticated;

comment on function erp.document_trade_side(uuid) is
  'Whether a document is a sale, a purchase, or something the product cannot '
  'tell. Reads the role the document named; falls back to the party''s own '
  'roles because erp.create_document() has never set party_role_id, and '
  'refuses to guess for a party that both buys and sells.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Whether there is any tax rule to determine by
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.tax_rules_in_force(
  p_entity_id uuid, p_on date default null)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- The two layers erp.evaluate_rules() consults for tax.determination, asked
  -- in the same order and on the same date, so "there is something to
  -- determine by" and "the determination will find a rule set" cannot drift.
  select exists (
    select 1
      from erp.bound_legislation_packs(p_entity_id, coalesce(p_on, current_date)) b
      join erp_ref.legislation_rule lr
        on lr.pack_code = b.pack_code
       and lr.pack_version = b.pack_version
       and lr.decision_point_code = 'tax.determination')
      or exists (
    select 1
      from erp.rule_set rs
      join erp.rule_set_version rsv
        on rsv.tenant_id = rs.tenant_id
       and rsv.rule_set_id = rs.id
       and rsv.status = 'active'
       and daterange(rsv.effective_from, rsv.effective_to, '[)')
             @> coalesce(p_on, current_date)
      join erp.rule ru
        on ru.tenant_id = rs.tenant_id
       and ru.rule_set_version_id = rsv.id
       and ru.is_active
     where rs.tenant_id = erp.require_tenant_id()
       and rs.decision_point_code = 'tax.determination'
       and rs.status = 'active'
       and (rs.entity_id is null or rs.entity_id = p_entity_id))
$$;
revoke all on function erp.tax_rules_in_force(uuid, date) from public, anon, authenticated;

comment on function erp.tax_rules_in_force(uuid, date) is
  'Whether a company has anything to determine tax by on a date: a bound '
  'legislation pack with rules on tax.determination, or the organisation''s own '
  'promoted rule set. Asked before determining, so an organisation that has '
  'never configured tax raises its invoice instead of being refused one.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Determining a document's tax
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.determine_document_tax(p_document_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_on     date;
  v_n      integer := 0;
  r        record;
begin
  select * into d from erp.document
   where tenant_id = v_tenant and id = p_document_id;
  if not found or coalesce(d.is_cancelled, false) then
    return 0;
  end if;

  select dt.base_type_code into v_base
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  -- A line is billable on an invoice or a credit, and nowhere earlier.
  if coalesce(v_base, '') not in ('invoice_reference', 'credit_reference') then
    return 0;
  end if;

  -- Asked before the side, because today no organisation has configured tax at
  -- all and this is the early exit every transition takes.
  -- The date is erp.determine_tax()'s own, so the two cannot disagree.
  v_on := coalesce(d.document_date, current_date);

  if not erp.tax_rules_in_force(d.entity_id, v_on) then
    return 0;
  end if;

  -- Output tax only, until the report can tell output from input.
  if erp.document_trade_side(p_document_id) <> 'sale' then
    return 0;
  end if;

  -- Once per line. A sales order passes through three committed states and an
  -- invoice may reach more than one; the second visit finds every line already
  -- determined and writes nothing.
  for r in
    select l.id
      from erp.document_line l
     where l.tenant_id = v_tenant
       and l.document_id = p_document_id
       and not coalesce(l.is_cancelled, false)
       -- A line with no net is not a supply with a rate on it, and the
       -- decision point's input schema would refuse the null anyway. Skipping
       -- it here is the difference between an invoice that issues without tax
       -- on one line and an invoice that cannot be issued at all.
       and l.net_minor is not null
       and not exists (select 1 from erp.tax_determination td
                        where td.tenant_id = v_tenant
                          and td.document_line_id = l.id)
     order by l.line_no
  loop
    perform erp.determine_tax(r.id);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;
revoke all on function erp.determine_document_tax(uuid) from public, anon, authenticated;

comment on function erp.determine_document_tax(uuid) is
  'Determines tax for every undetermined line of a sales invoice or credit, '
  'through erp.determine_tax() and therefore through B3''s decision point. '
  'Idempotent per line, silent where no rule is in force, and untouched by '
  'anything that is not a supply.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The lifecycle calls it, when the document commits
--
-- The same shape as t_object_state_document_number from 20260906081000, and
-- for the same reason: a committed state is what the outside world believes,
-- and every route into one goes through this row. The two triggers are
-- independent — numbering sorts before tax by name, so a determination is
-- never made against a number that is about to change.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.determine_tax_on_commit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_committed boolean;
begin
  select s.is_committed into v_committed
    from erp.state s where s.id = new.current_state_id;
  if not coalesce(v_committed, false) then
    return null;
  end if;
  perform erp.determine_document_tax(new.object_id);
  return null;
end;
$$;
revoke all on function erp.determine_tax_on_commit() from public, anon, authenticated;

comment on function erp.determine_tax_on_commit is
  'Determines a document''s tax the moment it enters a committed state. A '
  'draft invoice is not a supply and an issued one is, and the tax point is '
  'the issue.';

drop trigger if exists t_object_state_document_tax on erp.object_state;
create trigger t_object_state_document_tax
  after update of current_state_id on erp.object_state
  for each row
  when (new.object_type = 'document'
        and new.current_state_id is distinct from old.current_state_id)
  execute function erp.determine_tax_on_commit();

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The product says what it has not done
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.tax_outside_the_ledger_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id)
  -- 1. Tax that was determined and reached no tax account. Every row here is
  --    an invoice whose gross the customer owes and whose receivable is net.
  select 'tax was determined on a posted document and no tax account was posted',
         doc.document_number,
         format('%s of tax on %s, and journal %s has no line on a tax control account',
                sum(td.tax_minor), doc.document_number,
                (select j.journal_number from erp.journal j
                  where j.tenant_id = t.tenant_id and j.document_id = doc.id
                  order by j.posting_date limit 1))
    from t
    join erp.tax_determination td on td.tenant_id = t.tenant_id
    join erp.document doc on doc.tenant_id = t.tenant_id and doc.id = td.document_id
   where td.tax_minor <> 0
     and exists (select 1 from erp.journal j
                  where j.tenant_id = t.tenant_id and j.document_id = doc.id)
     and not exists (
       select 1 from erp.journal j
         join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
         join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
        where j.tenant_id = t.tenant_id and j.document_id = doc.id
          and a.control_kind = 'tax')
   group by t.tenant_id, doc.id, doc.document_number
  union all
  -- 2. An invoice the product cannot tell the direction of, so it determined
  --    nothing. erp.create_document() never sets party_role_id, so this is a
  --    party that both buys and sells.
  select 'an invoice was left undetermined because the product cannot tell a sale from a purchase',
         doc.document_number,
         format('%s is raised against %s, which holds both a customer and a supplier role, and the document names neither',
                doc.document_number, p.code)
    from t
    join erp.document doc on doc.tenant_id = t.tenant_id
    join erp.document_type dt on dt.tenant_id = t.tenant_id and dt.id = doc.document_type_id
    join erp.party p on p.tenant_id = t.tenant_id and p.id = doc.party_id
    join erp.object_state os on os.tenant_id = doc.tenant_id
     and os.object_type = 'document' and os.object_id = doc.id
    join erp.state s on s.id = os.current_state_id
   where dt.base_type_code in ('invoice_reference', 'credit_reference')
     and s.is_committed
     and not coalesce(doc.is_cancelled, false)
     and doc.party_role_id is null
     -- Both roles, and nothing on the document to break the tie. Written out
     -- rather than through erp.document_trade_side() so the planner filters
     -- before it calls anything, per row, over every invoice.
     and exists (select 1 from erp.party_role pr
                  where pr.tenant_id = t.tenant_id and pr.party_id = doc.party_id
                    and pr.role_kind = 'customer' and pr.status = 'active')
     and exists (select 1 from erp.party_role pr
                  where pr.tenant_id = t.tenant_id and pr.party_id = doc.party_id
                    and pr.role_kind = 'supplier' and pr.status = 'active')
     and erp.tax_rules_in_force(doc.entity_id, coalesce(doc.document_date, current_date))
$$;
revoke all on function erp.tax_outside_the_ledger_report() from public, anon, authenticated;

comment on function erp.tax_outside_the_ledger_report is
  'Every document whose determined tax never reached a tax control account, '
  'and every invoice left undetermined because the product could not tell a '
  'sale from a purchase. A report and not an assertion: the posting of tax is '
  'a decision nobody has taken yet, and a known gap should be visible without '
  'failing a build that is correct about everything it claims.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq) values
  ('tax_outside_the_ledger', 'Tax that has not reached the ledger', 'report', 'tenant',
   'tax_outside_the_ledger_report', '', null, '',
   'Tax is determined on a sales invoice when it is issued, and shown on the document and in the tax report. It does not yet reach a tax control account, so a determined invoice''s receivable is its net rather than its gross. Every document in that position is listed here, with the invoice whose direction the product could not tell.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name,
      blurb = excluded.blurb;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The demonstration trades with tax
--
-- Two needle patches to erp.ensure_demo_configuration(), counted before they
-- are made, for the reason 20260912190000 gives: the function is six hundred
-- lines, two of them change, and a restatement is the other five hundred and
-- ninety-eight to keep in step.
--
-- The tax rules go in through erp.configure_tax(), which is the product's own
-- door — it is on the Administration configuration screen and it authors a B6
-- change set, which erp.install_module_config() approves and promotes because a
-- demonstration organisation is not live. Twenty per cent, home country GB: the
-- demonstration's customers are in Britain, the Netherlands, France, Norway,
-- Ireland and Germany, so it raises standard-rated domestic invoices and
-- zero-rated exports side by side, which is the whole of what the Tax report
-- is for.
--
-- A rule set is in force from the day it is promoted, which is today, and the
-- demonstration's history is dated two years back. The same sentence was
-- already true of the posting rules, and the builder already back-dates those;
-- the rule set version joins them.
-- ═════════════════════════════════════════════════════════════════════════════

do $demo_tax$
declare
  v_def text := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  v_n1  text :=
$old$  -- Receivables is where cash application's posting rule lives.
  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'receivables') then
    perform erp.configure_receivables(7, 45, 90);
    v_did := v_did || '"receivables"'::jsonb;
  end if;$old$;
  v_n2  text :=
$old$  update erp.posting_rule
     set effective_from = least(effective_from, make_date(v_year - 2, 1, 1))
   where tenant_id = p_tenant_id and status = 'active'
     and effective_from > make_date(v_year - 2, 1, 1);$old$;
  v_hit1 integer;
  v_hit2 integer;
begin
  -- Applied already. A replay that met a migration halfway through is how the
  -- 8 September deploy lost twenty-three minutes; a patch that can be applied
  -- twice is how it would lose them silently.
  if position('erp.configure_tax(' in v_def) > 0
     or position('erp.rule_set_version' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_ALREADY_CONFIGURES_TAX: erp.ensure_demo_configuration() already installs tax rules; this migration would install them twice';
  end if;

  select count(*) into v_hit1 from regexp_matches(v_def, 'configure_receivables\(7, 45, 90\)', 'g');
  select count(*) into v_hit2 from regexp_matches(v_def, 'update erp\.posting_rule\n     set effective_from = least', 'g');
  if v_hit1 <> 1 or v_hit2 <> 1 or position(v_n1 in v_def) = 0 or position(v_n2 in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: erp.ensure_demo_configuration() is not the body this migration patches (% receivables, % posting-rule back-dates)',
      v_hit1, v_hit2;
  end if;

  v_def := replace(v_def, v_n1, v_n1 ||
$new$

  -- Tax, so the demonstration's invoices carry VAT and the Tax report has
  -- something in it. Twenty per cent at home; the customers outside Britain
  -- are exports and zero-rated by the same rule set's first rule.
  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'tax') then
    perform erp.configure_tax('GB', 20);
    v_did := v_did || '"tax"'::jsonb;
  end if;$new$);

  v_def := replace(v_def, v_n2, v_n2 ||
$new$

  -- And a rule set is in force from the day it was promoted, which is today,
  -- for exactly the reason the posting rules above are back-dated: the history
  -- is two years old and a rate that was not in force on the day of the supply
  -- does not decide it.
  update erp.rule_set_version rsv
     set effective_from = least(rsv.effective_from, make_date(v_year - 2, 1, 1))
    from erp.rule_set rs
   where rs.tenant_id = p_tenant_id and rs.id = rsv.rule_set_id
     and rs.decision_point_code = 'tax.determination'
     and rsv.tenant_id = p_tenant_id and rsv.status = 'active'
     and rsv.effective_from > make_date(v_year - 2, 1, 1);$new$);

  execute v_def;

  -- Re-emitted without what it was re-emitted for is the failure this catches.
  v_def := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  if position('erp.configure_tax(''GB'', 20)' in v_def) = 0
     or position('erp.rule_set_version rsv' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_LOST_ITS_TAX: erp.ensure_demo_configuration() was re-emitted without its tax rules or without back-dating them';
  end if;
end
$demo_tax$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The document screen says the tax, where there is any
--
-- public.erp_document() answered total_minor — erp.document_value_minor(), the
-- sum of the lines' net — and the lines' net, and nothing about tax. It is the
-- read behind the document panel on every process screen, so an invoice with
-- twenty per cent on it would have shown its net as its total and said nothing
-- about the rest.
--
-- total_minor keeps its meaning, because it is the figure the approval bands
-- and the credit check are about and renaming what a number means is how a
-- screen starts lying. The tax and the gross are added beside it, and only
-- where there is tax: a document with none looks exactly as it does today.
--
-- The sales invoice PDF already renders a tax summary and a VAT total —
-- src/lib/pdf/invoice-pdf.ts has since it was written, from the frozen
-- erp.sales_invoice_contract(), which has carried each line's tax code, rate
-- and tax and the summary by code throughout. It has been rendering zeroes
-- because nothing determined any. Nothing there changes.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_document(p_document_id uuid)
returns jsonb
language sql
stable
set search_path to ''
as $$
  select jsonb_build_object(
    'document', (
      select jsonb_build_object(
        'document_id', d.id, 'document_number', d.document_number,
        'document_type', dt.code, 'document_date', d.document_date,
        'currency', d.currency, 'party', p.name,
        'their_reference', d.their_reference,
        'total_minor', erp.document_value_minor(d.id),
        'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed)
        -- The tax and the gross, only where the document carries tax. A key
        -- that is not there is a field the panel does not draw.
        || coalesce((
             select case when sum(coalesce(l.tax_minor, 0)) <> 0
                         then jsonb_build_object(
                                'tax_minor', sum(coalesce(l.tax_minor, 0)),
                                'gross_minor', sum(coalesce(l.net_minor, 0))
                                             + sum(coalesce(l.tax_minor, 0)))
                    end
               from erp.document_line l
              where l.tenant_id = d.tenant_id and l.document_id = d.id
                and not coalesce(l.is_cancelled, false)), '{}'::jsonb)
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
        left join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        left join erp.state s on s.id = os.current_state_id
       where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'line_id', l.id, 'line_no', l.line_no, 'description', l.description,
        'quantity', l.quantity, 'unit_price_minor', l.unit_price_minor,
        'net_minor', l.net_minor, 'item', i.code,
        'tax_code', l.tax_code, 'tax_rate_pct', l.tax_rate_pct,
        'tax_minor', l.tax_minor) order by l.line_no)
        from erp.document_line l
        left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
       where l.tenant_id = erp.current_tenant_id() and l.document_id = p_document_id), '[]'::jsonb),
    'lineage', coalesce((
      select jsonb_agg(jsonb_build_object(
        'depth', depth, 'direction', direction, 'document_id', document_id,
        'document_number', document_number, 'base_type', base_type,
        'relation', relation_kind) order by depth)
        from erp.document_lineage(p_document_id)), '[]'::jsonb),
    'available_transitions', public.erp_available_transitions(p_document_id))
$$;

revoke all on function public.erp_document(uuid) from public, anon;
grant execute on function public.erp_document(uuid) to authenticated, service_role;

-- Two words the panel now says, and a word on a screen is one an organisation
-- can rename.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Tax', 'The document panel''s label for the tax on a document that carries any, and the word beside a line''s own tax.'),
    ('Total with tax', 'The document panel''s label for a document''s net and tax together.')
) as v(text, why)
on conflict (key, locale) do nothing;

do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values ('Tax'), ('Total with tax')) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_WORDS_MISSING: % have no en row', v_missing;
  end if;
end
$words$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.invoice_tax_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_ccy char(3);
  v_gb uuid; v_export uuid; v_supplier uuid;
  v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_pinv uuid;
  v_from date;
  v_n integer; v_i integer;
  v_net bigint; v_tax bigint;
  v_rules boolean;
  v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-invoice-tax', 'Invoice tax suite',
                              'admin@zz-invoice-tax.test', 'Invoice Tax Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000e7', 'admin@zz-invoice-tax.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000e7')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
  select p.id into v_gb from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'customer'
   where p.tenant_id = v_tenant and p.country_code = 'GB' order by p.code limit 1;
  select p.id into v_export from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'customer'
   where p.tenant_id = v_tenant and p.country_code <> 'GB' order by p.code limit 1;
  select p.id into v_supplier from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id and pr.role_kind = 'supplier'
   where p.tenant_id = v_tenant and p.country_code = 'GB' order by p.code limit 1;

  -- ── 1. The demonstration's own configuration puts tax in force ────────────
  v_cases := v_cases + 1;
  v_rules := erp.tax_rules_in_force(v_entity, (current_date - interval '11 months')::date);
  case_name := 'the demonstration is configured with tax rules in force across the history it trades in';
  passed := v_rules;
  detail := format('tax rules in force eleven months ago: %s', v_rules);
  return next;

  -- ── 2. No rules in force: the invoice is still raised ─────────────────────
  -- The rule set goes inactive for this case and comes straight back, because
  -- an organisation that has never configured tax is exactly this state.
  v_cases := v_cases + 1;
  update erp.rule_set set status = 'inactive'::erp.record_status
   where tenant_id = v_tenant and decision_point_code = 'tax.determination';
  v_msg := null;
  begin
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_gb,
                                 current_date, v_ccy, 'ZZTAX-NORULE', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_item, 2, 50000, 'no rules in force');
    perform erp.transition_document(v_inv, 'issue', 'invoice tax suite');
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'an organisation with no tax rule in force raises and issues its invoice, and determines nothing';
  passed := v_msg is null
        and erp.object_current_state('document', v_inv) = 'issued'
        and not exists (select 1 from erp.tax_determination td where td.document_id = v_inv)
        and (select count(*) from erp.document_line l
              where l.document_id = v_inv and l.tax_minor is not null) = 0;
  detail := coalesce('refused: ' || left(v_msg, 120),
                     format('issued, %s determination(s)',
                            (select count(*) from erp.tax_determination td where td.document_id = v_inv)));
  return next;

  update erp.rule_set set status = 'active'::erp.record_status
   where tenant_id = v_tenant and decision_point_code = 'tax.determination';

  -- ── 3. A domestic invoice is determined at the standard rate ──────────────
  v_cases := v_cases + 1;
  v_inv2 := erp.create_document('sales_invoice', v_entity, v_site, v_gb,
                                current_date, v_ccy, 'ZZTAX-DOMESTIC', '{}'::jsonb);
  perform erp.add_document_line(v_inv2, v_item, 2, 50000, 'domestic supply, line one');
  perform erp.add_document_line(v_inv2, v_item, 1, 30000, 'domestic supply, line two');
  perform erp.transition_document(v_inv2, 'issue', 'invoice tax suite');
  select coalesce(sum(l.net_minor), 0), coalesce(sum(l.tax_minor), 0)
    into v_net, v_tax
    from erp.document_line l where l.document_id = v_inv2 and not l.is_cancelled;
  case_name := 'every line of a newly issued invoice gets a determination, and the line carries the code, the rate and the tax';
  passed := (select count(*) from erp.tax_determination td where td.document_id = v_inv2) = 2
        and v_net = 130000 and v_tax = 26000
        and (select count(*) from erp.document_line l
              where l.document_id = v_inv2 and l.tax_code = 'S' and l.tax_rate_pct = 20) = 2
        and (select count(*) from erp.tax_determination td
              where td.document_id = v_inv2 and td.rule_code = 'domestic_standard'
                and td.jurisdiction = 'GB') = 2;
  detail := format('net %s, tax %s, %s determination(s)', v_net, v_tax,
                   (select count(*) from erp.tax_determination td where td.document_id = v_inv2));
  return next;

  -- ── 4. The tax report answers for the period the invoice sits in ──────────
  v_cases := v_cases + 1;
  case_name := 'the tax report returns rows for the period that invoice sits in, and they add up to the tax on it';
  passed := exists (select 1 from erp.tax_report(current_date - 1, current_date + 1) r
                     where r.tax_code = 'S' and r.rate_pct = 20 and r.tax_minor >= 26000)
        and (select coalesce(sum(r.tax_minor), 0)
               from erp.tax_report(current_date - 1, current_date + 1) r) >= 26000;
  detail := format('%s row(s), %s of tax in the window',
                   (select count(*) from erp.tax_report(current_date - 1, current_date + 1)),
                   (select coalesce(sum(r.tax_minor), 0)
                      from erp.tax_report(current_date - 1, current_date + 1) r));
  return next;

  -- ── 5. An export is zero-rated by the same rule set ───────────────────────
  v_cases := v_cases + 1;
  v_inv3 := erp.create_document('sales_invoice', v_entity, v_site, v_export,
                                current_date, v_ccy, 'ZZTAX-EXPORT', '{}'::jsonb);
  perform erp.add_document_line(v_inv3, v_item, 1, 40000, 'shipped outside the country');
  perform erp.transition_document(v_inv3, 'issue', 'invoice tax suite');
  case_name := 'a sale shipped outside the country is zero-rated by the same rule set, not left undetermined';
  passed := (select count(*) from erp.tax_determination td
              where td.document_id = v_inv3 and td.rule_code = 'export_zero'
                and td.rate_pct = 0 and td.tax_minor = 0) = 1;
  detail := (select format('rule %s at %s%%, tax %s', td.rule_code, td.rate_pct, td.tax_minor)
               from erp.tax_determination td where td.document_id = v_inv3);
  return next;

  -- ── 6. Determined once ────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_n := erp.determine_document_tax(v_inv2);
  case_name := 'a document asked twice is determined once: the second visit writes nothing';
  passed := v_n = 0
        and (select count(*) from erp.tax_determination td where td.document_id = v_inv2) = 2;
  detail := format('second pass determined %s line(s); %s determination(s) on the document', v_n,
                   (select count(*) from erp.tax_determination td where td.document_id = v_inv2));
  return next;

  -- ── 7. A purchase invoice is left alone ───────────────────────────────────
  v_cases := v_cases + 1;
  v_pinv := erp.create_document('purchase_invoice', v_entity, v_site, v_supplier,
                                current_date, v_ccy, 'ZZTAX-PURCHASE', '{}'::jsonb);
  perform erp.add_document_line(v_pinv, v_item, 1, 20000, 'input tax is not output tax');
  v_n := erp.determine_document_tax(v_pinv);
  case_name := 'nothing determines tax on an invoice raised against a supplier, because the tax report cannot tell input from output';
  passed := erp.document_trade_side(v_inv2) = 'sale'
        and erp.document_trade_side(v_pinv) = 'purchase'
        and v_n = 0
        and not exists (select 1 from erp.tax_determination td where td.document_id = v_pinv);
  detail := format('the sales invoice reads %s and the purchase invoice reads %s; %s line(s) determined on the purchase',
                   erp.document_trade_side(v_inv2), erp.document_trade_side(v_pinv), v_n);
  return next;

  -- ── 8. The demonstration's report is not empty ────────────────────────────
  -- One slice of demonstration trading, and another if the first happened to
  -- despatch nothing. Bounded, because a suite runs on production at deploy.
  v_cases := v_cases + 1;
  v_from := (date_trunc('month', current_date) - interval '12 months')::date;
  for v_i in 0 .. 2 loop
    perform erp.seed_demo_history((v_from + v_i * 5)::date, null, 1);
    exit when exists (
      select 1 from erp.tax_determination td
        join erp.document d on d.tenant_id = td.tenant_id and d.id = td.document_id
       where td.tenant_id = v_tenant and d.their_reference like 'DEMO-%'
         and td.tax_code = 'S' and td.tax_minor > 0);
  end loop;
  case_name := 'a slice of demonstration trading leaves the tax report with content a prospect can read';
  passed := exists (
      select 1 from erp.tax_report(v_from, (v_from + 20)::date) r where r.tax_minor > 0)
    and exists (
      select 1 from erp.tax_determination td
        join erp.document d on d.tenant_id = td.tenant_id and d.id = td.document_id
       where td.tenant_id = v_tenant and d.their_reference like 'DEMO-%' and td.tax_code = 'S');
  detail := format('%s determination(s) on demonstration documents, %s of tax across the slice',
                   (select count(*) from erp.tax_determination td
                      join erp.document d on d.tenant_id = td.tenant_id and d.id = td.document_id
                     where td.tenant_id = v_tenant and d.their_reference like 'DEMO-%'),
                   (select coalesce(sum(r.tax_minor), 0)
                      from erp.tax_report(v_from, (v_from + 20)::date) r));
  return next;

  -- ── 9. And the product says the tax has not reached the ledger ────────────
  v_cases := v_cases + 1;
  case_name := 'the product names every document whose determined tax reached no tax account, rather than hiding it';
  passed := exists (select 1 from erp.tax_outside_the_ledger_report() r
                     where r.finding like 'tax was determined on a posted document%'
                       and r.reference = (select d.document_number from erp.document d where d.id = v_inv2));
  detail := format('%s finding(s) in the report', (select count(*) from erp.tax_outside_the_ledger_report()));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 10. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-invoice-tax')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000e7');
  detail := 'zz-invoice-tax rolled back with its invoices, determinations and demonstration slice';
  return next;

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: invoice_tax_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_invoice_tax_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _invoice_tax on commit drop as
    select * from erp_test.invoice_tax_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _invoice_tax;
  drop table _invoice_tax;
  if v_fail > 0 then
    raise exception E'CLOVEERP_INVOICE_TAX_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: invoice_tax_suite ran % cases, expected 10', v_all;
  end if;
  return format('invoice tax: %s/%s cases passed', v_all, v_all);
end;
$$;

select erp.apply_execute_grants();

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The assertions this migration must pass
-- ═════════════════════════════════════════════════════════════════════════════

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_diagnostics_registered();
select erp.assert_suite_verdicts_strict();
select erp_test.assert_invoice_tax_suite();
