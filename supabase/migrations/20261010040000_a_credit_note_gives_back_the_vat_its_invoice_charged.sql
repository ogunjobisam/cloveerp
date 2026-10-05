set lock_timeout = '30s';

-- =============================================================================
-- 20261010040000  A credit note gives back the VAT its invoice charged
-- -----------------------------------------------------------------------------
-- Found reading the demonstration's Q3 2026 VAT return, 5 October: box 1 was
-- -£324.80. Five credit notes to customers in Great Britain (CN-000012 to
-- CN-000015 and CN-000022) gave back 20% VAT against invoices whose journals
-- carried none: the quarter's invoices posted net (fixed by 20261002300000,
-- and their determinations withdrawn), and every Friday the builder credited
-- a quarter of one line through erp.raise_customer_credit_note().
--
-- The cause is general and not the demonstration's. A customer's credit note
-- had its VAT determined afresh: erp.determine_document_tax() ran
-- erp.determine_tax() over the note's own lines, by the rule set and the
-- registration in force on the note's date, and never looked at what the
-- invoice it credits charged. A credit note adjusts the VAT that was charged,
-- at the rate it was charged at (VAT Notice 700, section 18.2), so any of
--   an invoice issued before the company registered, credited after;
--   a rate, a rule set or a product's tax class changed in between;
--   an invoice whose ledger carried no tax;
-- gave back a figure nobody charged, and the return took it off box 1. The
-- purchase side has refused the mirror case since 20261001400000
-- (CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED: a supplier gives back VAT only on
-- what they billed). The sales side had no such rule.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.determine_document_tax(): each line of a customer's credit note
--      that reverses an invoice line (credit line -> returns -> despatch line
--      <- invoices <- invoice line; the invoice the note names by "credits"
--      first) takes that invoice line's VAT, as the purchase side takes the
--      supplier's:
--        - the invoice line's code, rate, treatment, jurisdiction and
--          legislation pack, recorded as rule 'follows_invoice' with the
--          invoice, its line and both quantities in determination_inputs;
--        - its tax pro rata on the quantity (one of four gives back a quarter),
--          never more than is left of it after earlier notes that followed
--          the same invoice line;
--        - nothing, and no determination, where the invoice line has none,
--          or determined tax its posted journals did not carry (they moved
--          tax control by nothing). The line then carries no VAT.
--      It follows the invoice whatever the note's own date would say: the
--      note adjusts what was charged then. A credit note with no invoice
--      behind it (raised from a despatch nobody invoiced, or opened by hand)
--      is determined afresh exactly as before, and an invoice exactly as
--      before. Supplier credit notes are not touched: their VAT is stated.
--   B. erp_test.vat_return_suite gains two cases (23):
--        - an invoice issued the day before the company registered for VAT,
--          one of four credited once it had: no VAT given back, box 1 does
--          not move, nothing blocks;
--        - an invoice at 20%, its product then reclassed as zero-rated, one
--          of four credited: the note keeps 20% and gives back a quarter of
--          the invoice's VAT, and the ledger carries the same.
--   C. erp_test.demonstration_vat_returns_suite gains a case (11): every
--      credit the builder raised gives back the VAT of the invoice line it
--      credits, pro rata, at its rate and treatment.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No posted document, determination or journal is touched: a credit note is
-- determined once, as it is first committed, and those already issued keep
-- what they posted. The demonstration's Q3 stays as it is; the owner decides
-- it. No door, permission, refusal or screen string is added or removed.
--
-- On production: one function is replaced, two suites and their assertions
-- are replaced. No table is altered and no row of any organisation is
-- touched. Credit notes issued from now on follow their invoices.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A customer's credit note follows the invoice it credits
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'erp.determine_document_tax(uuid)'::regprocedure);
begin
  if strpos(v_src, '20261010040000') > 0 then
    raise notice 'erp.determine_document_tax already follows the invoice; replaced with the same body';
  elsif md5(v_src) <> '9d9767badfd13c043d180f98e620565f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.determine_document_tax(uuid) is not the body 20261010040000 expects (md5 %)', md5(v_src);
  end if;
end
$guard$;

create or replace function erp.determine_document_tax(p_document_id uuid)
returns integer
language plpgsql
set search_path to ''
as $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_n      integer := 0;
  v_credit boolean := false;
  v_fresh  boolean;
  v_follow boolean;
  v_posted boolean;
  v_ledger bigint;
  v_given  bigint;
  v_tax    bigint;
  r        record;
  f        record;
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

  -- A customer's credit note gives back the VAT the invoice it credits
  -- charged, at that invoice's rate and treatment, and nothing it did not
  -- charge (20261010040000). It adjusts what was charged then, so the note's
  -- own date is not asked about the lines that reverse an invoice. A
  -- supplier's credit note states its VAT (erp.state_supplier_tax()).
  v_credit := v_base = 'credit_reference'
              and erp.document_trade_side(p_document_id) = 'sale';

  -- Whether there is anything to determine afresh by, on the document's date,
  -- for a company registered to charge it, on a sale. The invoice's readiness
  -- asks the same question, so the two cannot disagree about a draft
  -- (20260924520000).
  v_fresh := erp.document_tax_is_determinable(p_document_id);
  if not v_fresh and not v_credit then
    return 0;
  end if;

  -- Once per line. A sales order passes through three committed states and an
  -- invoice may reach more than one; the second visit finds every line already
  -- determined and writes nothing.
  for r in
    select l.id, l.quantity, l.net_minor, l.currency
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
    v_follow := false;
    if v_credit then
      -- The invoice line this line reverses: through the despatch line it
      -- brings back, to the invoice line that billed it. The invoice the note
      -- says it credits first, then the earliest.
      select il.id as invoice_line_id, il.quantity as invoiced,
             iv.id as invoice_id, iv.document_number as invoice_number,
             rr.to_line_id as goods_line_id,
             td.id as determination_id, td.tax_code, td.rate_pct, td.tax_minor,
             td.treatment, td.jurisdiction, td.rule_code,
             td.legislation_pack_code, td.legislation_pack_version
        into f
        from erp.document_relation rr
        join erp.document_relation ir
          on ir.tenant_id = rr.tenant_id and ir.to_line_id = rr.to_line_id
         and ir.relation_kind = 'invoices'
        join erp.document_line il
          on il.tenant_id = ir.tenant_id and il.id = ir.from_line_id
         and not coalesce(il.is_cancelled, false)
        join erp.document iv
          on iv.tenant_id = il.tenant_id and iv.id = il.document_id
         and not coalesce(iv.is_cancelled, false)
        join erp.document_type it
          on it.tenant_id = iv.tenant_id and it.id = iv.document_type_id
         and it.base_type_code = 'invoice_reference'
        left join erp.tax_determination td
          on td.tenant_id = il.tenant_id and td.document_id = il.document_id
         and td.document_line_id = il.id
       where rr.tenant_id = v_tenant
         and rr.from_line_id = r.id
         and rr.relation_kind = 'returns'
       order by exists (select 1 from erp.document_relation cr
                         where cr.tenant_id = v_tenant
                           and cr.from_document_id = p_document_id
                           and cr.to_document_id = iv.id
                           and cr.relation_kind = 'credits') desc,
                iv.document_date, il.line_no, td.determined_at
       limit 1;
      v_follow := found;
    end if;

    -- Nothing to follow: determined afresh, as before.
    if not v_follow then
      if v_fresh then
        perform erp.determine_tax(r.id);
        v_n := v_n + 1;
      end if;
      continue;
    end if;

    -- What the invoice charged. A line nothing determined charged nothing,
    -- and so did a determination its posted journals never carried.
    v_posted := false;
    v_ledger := 0;
    if f.determination_id is not null and coalesce(f.tax_minor, 0) <> 0 then
      select exists (select 1 from erp.journal j
                       join erp.ledger lg on lg.tenant_id = j.tenant_id and lg.id = j.ledger_id
                                         and lg.ledger_kind = 'statutory'
                      where j.tenant_id = v_tenant and j.document_id = f.invoice_id
                        and j.status = 'posted' and j.source_code like 'document.%'),
             coalesce((select sum(jl.base_credit_minor - jl.base_debit_minor)
                         from erp.journal j
                         join erp.ledger lg on lg.tenant_id = j.tenant_id and lg.id = j.ledger_id
                                           and lg.ledger_kind = 'statutory'
                         join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                         join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                                           and a.control_kind = 'tax'
                        where j.tenant_id = v_tenant and j.document_id = f.invoice_id
                          and j.status = 'posted' and j.source_code like 'document.%'), 0)
        into v_posted, v_ledger;
    end if;

    if f.determination_id is null
       or (coalesce(f.tax_minor, 0) <> 0 and v_posted and v_ledger <= 0) then
      update erp.document_line
         set tax_code = null, tax_rate_pct = null, tax_minor = 0, updated_at = now()
       where tenant_id = v_tenant and id = r.id;
      continue;
    end if;

    -- Pro rata on the quantity, and never more than is left of the invoice
    -- line's VAT after the notes that followed it before.
    select coalesce(sum(td2.tax_minor), 0) into v_given
      from erp.document_relation rr2
      join erp.document cd
        on cd.tenant_id = rr2.tenant_id and cd.id = rr2.from_document_id
       and not coalesce(cd.is_cancelled, false)
      join erp.tax_determination td2
        on td2.tenant_id = rr2.tenant_id and td2.document_id = rr2.from_document_id
       and td2.document_line_id = rr2.from_line_id
     where rr2.tenant_id = v_tenant
       and rr2.to_line_id = f.goods_line_id
       and rr2.relation_kind = 'returns'
       and rr2.from_line_id <> r.id
       and td2.rule_code = 'follows_invoice'
       and td2.determination_inputs ->> 'invoice_line_id' = f.invoice_line_id::text;

    v_tax := case when coalesce(f.invoiced, 0) > 0
                  then round(coalesce(f.tax_minor, 0)::numeric * r.quantity / f.invoiced)::bigint
                  else 0 end;
    v_tax := greatest(0, least(v_tax, coalesce(f.tax_minor, 0) - v_given));

    insert into erp.tax_determination (
      tenant_id, entity_id, document_id, document_line_id, tax_code, rate_pct,
      taxable_minor, tax_minor, currency, jurisdiction, rule_code,
      legislation_pack_code, legislation_pack_version, treatment,
      determination_inputs, rule_evaluation_id, determined_at)
    values (v_tenant, d.entity_id, p_document_id, r.id, f.tax_code, f.rate_pct,
            r.net_minor, v_tax, coalesce(r.currency, d.currency), f.jurisdiction,
            'follows_invoice', f.legislation_pack_code, f.legislation_pack_version,
            f.treatment,
            jsonb_build_object('invoice_id', f.invoice_id,
                               'invoice_number', f.invoice_number,
                               'invoice_line_id', f.invoice_line_id,
                               'invoice_rule_code', f.rule_code,
                               'invoice_tax_minor', f.tax_minor,
                               'invoiced_quantity', f.invoiced,
                               'credited_quantity', r.quantity,
                               'given_back_before_minor', v_given),
            null, now());

    update erp.document_line
       set tax_code = f.tax_code, tax_rate_pct = f.rate_pct, tax_minor = v_tax,
           updated_at = now()
     where tenant_id = v_tenant and id = r.id;

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$function$;

revoke all on function erp.determine_document_tax(uuid) from public, anon;

comment on function erp.determine_document_tax(uuid) is
  'Determines tax for every undetermined line of a sales invoice or credit, through erp.determine_tax() and therefore '
  'through B3''s decision point. Idempotent per line, silent where no rule is in force, and untouched by anything that '
  'is not a supply. A customer''s credit note line that reverses an invoice line takes that line''s code, rate and '
  'treatment and its VAT pro rata on the quantity, never more than is left of it, and nothing where the invoice '
  'charged none (20261010040000); a credit with no invoice behind it is determined afresh.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The VAT return suite: a credit gives back what its invoice charged
-- ─────────────────────────────────────────────────────────────────────────────

do $vat_return$
declare
  v_sig  constant text := 'erp_test.vat_return_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  c_expected constant integer := 21;
$o$;
  v_new1 constant text := $n$  -- Twenty-three since a credit note follows its invoice (20261010040000).
  c_expected constant integer := 23;
$n$;
  v_old2 constant text := $o$  v_po3 uuid; v_pol3 uuid; v_grn3 uuid; v_rl3 uuid; v_scn3 uuid;
begin
$o$;
  v_new2 constant text := $n$  v_po3 uuid; v_pol3 uuid; v_grn3 uuid; v_rl3 uuid; v_scn3 uuid;
  v_reg_from date; v_class text; v_dn6 uuid; v_inv6 uuid; v_cn6 uuid; v_inv7 uuid; v_cn7 uuid;
begin
$n$;
  v_old3 constant text := $o$    -- ── 20. The whole organisation agrees ───────────────────────────────────
$o$;
  v_new3 constant text := $n$    -- ── 19a. A credit for an invoice that charged no VAT (20261010040000) ─
    -- The demonstration's Q3 met it: invoices that carried no VAT, credited at
    -- 20% because the note was determined afresh on its own date.
    v_step := 'four sold and invoiced the day before the company registered for VAT, one credited once it had';
    select g.valid_from into v_reg_from from erp.entity_tax_registration g
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%'
     order by g.valid_from desc limit 1;
    update erp.entity_tax_registration g set valid_from = v_today + 1
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';
    v_so := erp.open_document('sales_order', v_cust, v_entity, v_site);
    perform erp.add_document_line(v_so, v_item, 4, 10000, 'sold before registering');
    perform erp.transition_document(v_so, 'submit', 'vat return suite');
    perform erp_test.approve_document(v_so, 'vat return suite');
    v_dn6 := (erp.create_delivery_from_order(v_so) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn6, 'post', 'vat return suite');
    v_inv6 := erp.invoice_from_delivery(v_dn6, true);
    perform erp.transition_document(v_inv6, 'issue', 'vat return suite');
    update erp.entity_tax_registration g set valid_from = v_reg_from
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';
    select l.id into v_invline from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_inv6 and not coalesce(l.is_cancelled, false)
     order by l.line_no limit 1;
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_cn6 := erp.raise_customer_credit_note(v_inv6, 'damaged', 'one of four, sold before registering',
                                            jsonb_build_array(jsonb_build_object('line_id', v_invline, 'quantity', 1)));
    perform erp.transition_document(v_cn6, 'issue', 'vat return suite');
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0) into v_x
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_cn6 and a.control_kind = 'tax';
    v_cases := v_cases + 1;
    case_name := 'a credit note against an invoice issued before the company registered for VAT gives back no VAT, takes nothing out of box 1, and nothing blocks';
    passed := v_state is null
          and not exists (select 1 from erp.tax_determination td where td.document_id = v_inv6)
          and erp.document_tax_minor(v_inv6) = 0
          and erp.document_tax_minor(v_cn6) = 0
          and not exists (select 1 from erp.tax_determination td where td.document_id = v_cn6)
          and v_x = 0
          and b1.box1_minor = b0.box1_minor
          and b1.box6_pounds - b0.box6_pounds = -100
          and b1.ledger_disagreements = 0
          and not exists (select 1 from erp.vat_exceptions(v_entity, v_wide_from, v_today) x where x.blocks);
    detail := coalesce(v_state, format('the invoice carries %s, the credit note %s; tax control debited %s; box 1 moved %s, box 6 %s; %s blocking finding(s)',
                                       erp.document_tax_minor(v_inv6), erp.document_tax_minor(v_cn6), v_x,
                                       b1.box1_minor - b0.box1_minor, b1.box6_pounds - b0.box6_pounds,
                                       (select count(*) from erp.vat_exceptions(v_entity, v_wide_from, v_today) x where x.blocks)));
    return next;

    -- ── 19b. A credit keeps the invoice's rate (20261010040000) ─────────────
    v_step := 'four sold at 20%, the product then reclassed as zero-rated, one credited';
    select i.tax_class into v_class from erp.item i where i.id = v_item;
    v_so := erp.open_document('sales_order', v_cust, v_entity, v_site);
    perform erp.add_document_line(v_so, v_item, 4, 10000, 'sold at the standard rate');
    perform erp.transition_document(v_so, 'submit', 'vat return suite');
    perform erp_test.approve_document(v_so, 'vat return suite');
    v_dn := (erp.create_delivery_from_order(v_so) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'vat return suite');
    v_inv7 := erp.invoice_from_delivery(v_dn, true);
    perform erp.transition_document(v_inv7, 'issue', 'vat return suite');
    update erp.item set tax_class = 'zero_rated' where id = v_item;
    select l.id into v_invline from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_inv7 and not coalesce(l.is_cancelled, false)
     order by l.line_no limit 1;
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_cn7 := erp.raise_customer_credit_note(v_inv7, 'damaged', 'one of four, after the product was reclassed',
                                            jsonb_build_array(jsonb_build_object('line_id', v_invline, 'quantity', 1)));
    perform erp.transition_document(v_cn7, 'issue', 'vat return suite');
    update erp.item set tax_class = v_class where id = v_item;
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0) into v_x
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_cn7 and a.control_kind = 'tax';
    v_cases := v_cases + 1;
    case_name := 'a credit note for one of four, raised after the product was reclassed as zero-rated, keeps the invoice''s 20% and gives back a quarter of its VAT, and the ledger and box 1 say the same';
    passed := v_state is null
          and erp.document_tax_minor(v_inv7) = 8000
          and erp.document_tax_minor(v_cn7) = 2000
          and v_x = 2000
          and b1.box1_minor - b0.box1_minor = -2000
          and b1.ledger_disagreements = 0
          and exists (select 1 from erp.tax_determination td
                        join erp.tax_determination itd
                          on itd.tenant_id = td.tenant_id and itd.document_line_id = v_invline
                       where td.tenant_id = rb.tenant_id and td.document_id = v_cn7
                         and td.rule_code = 'follows_invoice'
                         and (td.determination_inputs ->> 'invoice_line_id')::uuid = v_invline
                         and td.rate_pct = itd.rate_pct and td.rate_pct = 20
                         and td.tax_code is not distinct from itd.tax_code
                         and td.treatment is not distinct from itd.treatment
                         and td.tax_minor = 2000)
          and exists (select 1 from erp.vat_entries(v_entity, v_wide_from, v_today) e
                       where e.document_id = v_cn7 and e.tax_minor = -2000 and e.determined_tax_minor = -2000)
          and not exists (select 1 from erp.vat_exceptions(v_entity, v_wide_from, v_today) x where x.blocks);
    detail := coalesce(v_state, format('the invoice carries %s, the credit note %s at %s%%; tax control debited %s; box 1 moved %s',
                                       erp.document_tax_minor(v_inv7), erp.document_tax_minor(v_cn7),
                                       (select max(td.rate_pct) from erp.tax_determination td where td.document_id = v_cn7),
                                       v_x, b1.box1_minor - b0.box1_minor));
    return next;

    -- ── 20. The whole organisation agrees ───────────────────────────────────
$n$;
begin
  if strpos(v_src, '20261010040000') > 0 then
    raise notice '% already credits what its invoice charged; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '126971b677bea9d3f0221a176dbdb1cb' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010040000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$vat_return$;

do $vat_return_assert$
declare
  v_sig  constant text := 'erp_test.assert_vat_return_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 21 then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_SHRANK: % case(s), expected 21', v_total
$o$;
  v_new  constant text := $n$  -- Twenty-three since a credit note follows its invoice (20261010040000).
  if v_total <> 23 then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_SHRANK: % case(s), expected 23', v_total
$n$;
begin
  if strpos(v_src, '20261010040000') > 0 then
    raise notice '% already expects twenty-three cases; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd58c2fdc20a4d822ee241e0747af5034' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010040000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$vat_return_assert$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The demonstration's credits give back what their invoices charged
-- ─────────────────────────────────────────────────────────────────────────────

do $demo_vat$
declare
  v_sig  constant text := 'erp_test.demonstration_vat_returns_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  c_expected constant integer := 10;
$o$;
  v_new1 constant text := $n$  -- Eleven since a credit note follows its invoice (20261010040000).
  c_expected constant integer := 11;
$n$;
  v_old2 constant text := $o$    -- ── A demonstration still on tax version 1 ──────────────────────────────
$o$;
  v_new2 constant text := $n$    -- ── 3a. The builder's credits give back what was charged (20261010040000)
    -- Every Friday the builder credits a quarter of one invoice line. Each
    -- credit line takes that invoice line's rate, treatment and VAT, pro rata.
    v_step := 'the week''s credit notes beside the invoice lines they credit';
    select count(*),
           count(*) filter (where td.rule_code = 'follows_invoice'
                              and (td.determination_inputs ->> 'invoice_line_id')::uuid = il.id
                              and td.rate_pct = itd.rate_pct
                              and td.tax_code is not distinct from itd.tax_code
                              and td.treatment is not distinct from itd.treatment
                              and td.tax_minor = round(itd.tax_minor::numeric * cl.quantity / il.quantity)::bigint
                              and cl.tax_minor = td.tax_minor)
      into v_n, v_n2
      from erp.document cd
      join erp.document_type ct
        on ct.tenant_id = cd.tenant_id and ct.id = cd.document_type_id and ct.code = 'sales_credit_note'
      join erp.document_line cl
        on cl.tenant_id = cd.tenant_id and cl.document_id = cd.id and not coalesce(cl.is_cancelled, false)
      join erp.document_relation rr
        on rr.tenant_id = cl.tenant_id and rr.from_line_id = cl.id and rr.relation_kind = 'returns'
      join erp.document_relation ir
        on ir.tenant_id = rr.tenant_id and ir.to_line_id = rr.to_line_id and ir.relation_kind = 'invoices'
      join erp.document_line il on il.tenant_id = ir.tenant_id and il.id = ir.from_line_id
      join erp.tax_determination itd on itd.tenant_id = il.tenant_id and itd.document_line_id = il.id
      left join erp.tax_determination td on td.tenant_id = cl.tenant_id and td.document_line_id = cl.id
     where cd.tenant_id = v_ta
       and cd.their_reference like 'DEMO-%'
       and exists (select 1 from erp.journal j where j.tenant_id = cd.tenant_id and j.document_id = cd.id
                      and j.status = 'posted');
    v_cases := v_cases + 1;
    case_name := 'every credit note the builder issued gives back the VAT of the invoice line it credits, pro rata, at that line''s rate and treatment';
    passed := v_state is null and v_n > 0 and v_n2 = v_n;
    detail := coalesce(v_state, format('%s credit line(s) against an invoice line with VAT determined, %s following it', v_n, v_n2));
    return next;

    -- ── A demonstration still on tax version 1 ──────────────────────────────
$n$;
begin
  if strpos(v_src, '20261010040000') > 0 then
    raise notice '% already compares the builder''s credits with their invoices; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6268cf958d311e3d85bdeab5d4b52c71' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010040000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$demo_vat$;

do $demo_vat_assert$
declare
  v_sig  constant text := 'erp_test.assert_demonstration_vat_returns_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- Ten since a demonstration's Dutch company (20261006031000).
  if v_total <> 10 then
    raise exception 'CLOVEERP_DEMONSTRATION_VAT_RETURNS_SUITE_SHRANK: % case(s), expected 10', v_total
$o$;
  v_new  constant text := $n$  -- Ten since a demonstration's Dutch company (20261006031000), eleven since
  -- a credit note follows its invoice (20261010040000).
  if v_total <> 11 then
    raise exception 'CLOVEERP_DEMONSTRATION_VAT_RETURNS_SUITE_SHRANK: % case(s), expected 11', v_total
$n$;
begin
  if strpos(v_src, '20261010040000') > 0 then
    raise notice '% already expects eleven cases; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e9f40ea8be6cd89b1df9a1748ea38faa' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010040000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$demo_vat_assert$;

revoke all on function erp_test.vat_return_suite() from public, anon;
revoke all on function erp_test.assert_vat_return_suite() from public, anon;
revoke all on function erp_test.demonstration_vat_returns_suite() from public, anon;
revoke all on function erp_test.assert_demonstration_vat_returns_suite() from public, anon;

comment on function erp_test.vat_return_suite() is
  'The nine VAT boxes and the tax report (20261001000000): the one-button bill in box 4 and in the ledger alike, a sale '
  'in boxes 1 and 6, a credit note and a reversal subtracting on their own dates, zero-rated and exempt in box 6 and '
  'outside the scope not, an untaxed bill in box 7, the form''s arithmetic, whole pounds, the tax point''s quarter, a '
  'manual journal listed and in no box, the report equal to boxes 1 and 4, a disagreement refused, and finance.read at '
  'both doors. A customer''s credit note gives back what its invoice charged: nothing against an invoice issued before '
  'the company registered, and the invoice''s 20% after the product was reclassed (20261010040000).';

comment on function erp_test.assert_vat_return_suite() is
  'The nine VAT boxes are computed from the posted journals and agree with the ledger, the tax report subtracts credit '
  'notes and reversals (20261001000000), and a credit note gives back the VAT its invoice charged, at its rate, and '
  'no more (20261010040000).';

comment on function erp_test.demonstration_vat_returns_suite() is
  'The demonstration''s VAT returns (20261001300000, D12): the builder finalises each quarter its trading reaches, but '
  'the latest to have ended; the return is the ledger''s and nothing in it blocks; every credit it raised gives back '
  'the VAT of the invoice line it credits (20261010040000); nothing more on a rebuild; nothing on tax version 1, until '
  'the catch-up upgrades tax and finalises what it may, once; the books still tie; and a quarter never traded is not '
  'returned empty.';

comment on function erp_test.assert_demonstration_vat_returns_suite() is
  'erp_test.demonstration_vat_returns_suite(), eleven cases: a demonstration''s Dutch company is given no British '
  'number (20261006031000), and the builder''s credit notes give back what their invoices charged (20261010040000).';

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
select erp.assert_personal_data_register_sound();
