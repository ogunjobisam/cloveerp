set lock_timeout = '30s';

-- =============================================================================
-- 20261010041000  A credit that gives back VAT never charged blocks the return
-- -----------------------------------------------------------------------------
-- Found with 20261010040000, reading the demonstration's Q3 2026 VAT return
-- (box 1 -£324.80). Five credit notes to customers in Great Britain gave back
-- 20% VAT, £324.80 in all, against invoices whose journals carried none. The
-- determinations on the notes equal what their journals carried, so the
-- return's gate, "the tax determined is not the tax the ledger carries", saw
-- nothing, and erp.vat_exceptions() had no finding for a credit giving back
-- more than its invoice charged. The return would have been finalised with it.
--
-- 20261010040000 stops new notes doing it. Notes already posted keep what
-- they posted, and a note's VAT can still be put on it by hand. This makes
-- either visible before anybody files.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.vat_exceptions() gains a blocking finding (g), "a credit gives back
--      VAT the invoice it credits did not charge": a customer's credit note
--      in the period whose posted journals took more VAT off tax control than
--      the posted journals of the invoices it credits put on. The invoices
--      are the one the note names ("credits") and every invoice that billed a
--      despatch line it brings back, in whichever period they fell. A note
--      with no invoice behind it is not judged here: there is nothing to
--      compare it with. Finalising a return refuses while a finding blocks,
--      so a return holding such a note cannot be finalised until the note is
--      put right (reversed, or answered with a correcting document).
--   B. erp.assert_vat_agrees_with_ledger() leaves (g) out. That assertion is
--      the agreement of the return with the ledger, and (g) is not a
--      disagreement: the note's determination and its journal agree. It is
--      run for every organisation by the whole-database reconciliation, on
--      every deploy; counting (g) there would fail the deploy's proof on the
--      demonstration's Q3 notes, which the owner has chosen to leave as they
--      are. The gate that matters for (g) is finalising, which reads every
--      blocking finding and still does.
--   C. erp_test.vat_return_suite gains a case (24): two of the four sold before
--      the company registered are credited from the despatch, with 20% VAT put
--      on the note by hand. The note is a blocking finding naming the note,
--      what it gives back and the invoice it credits; the honest notes are
--      not; the ledger agreement does not count it.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No posted document, determination or journal is touched. On production the
-- demonstration's Q3 2026 return (the five notes above) gains five blocking
-- findings and cannot be finalised until the owner decides what to do with
-- them; the builder and the catch-up already catch a refused finalise and say
-- so in their notes, and carry on building. No door, permission, refusal or
-- screen string is added; the finding's words are data, as the other
-- findings' are.
--
-- On production: two functions are replaced, a suite and its assertion are
-- replaced. No table is altered and no row of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The finding
-- ─────────────────────────────────────────────────────────────────────────────

do $exceptions$
declare
  v_sig  constant text := 'erp.vat_exceptions(uuid,date,date)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$   where x.side = 'sale'
   group by x.entity_id, x.document_number, x.sign, x.journal_id
$o$;
  v_new  constant text := $n$   where x.side = 'sale'
   group by x.entity_id, x.document_number, x.sign, x.journal_id
  union all
  -- (g) Blocks: a credit gives back VAT the invoice it credits did not charge
  --     (20261010041000). A credit note adjusts the VAT that was charged; one
  --     that takes more off box 1 than its invoices put on gives back tax
  --     nobody paid. Read from the ledger on both sides, whatever period the
  --     invoices fell in: the note's posted journals against theirs.
  select c.entity_id, 'a credit gives back VAT the invoice it credits did not charge', true,
         c.document_number,
         format('%s gives back %s %s of VAT, and %s, which it credits, charged %s %s',
                c.document_number, to_char(b.given_back / 100.0, 'FM999,999,999,990.00'), c.currency,
                g.invoices, to_char(m.charged / 100.0, 'FM999,999,999,990.00'), c.currency)
    from (select distinct x.entity_id, x.document_id, x.document_number, x.currency
            from x
           where x.side = 'sale' and x.base_type_code = 'credit_reference'
             and not x.is_reversal and x.tax_minor < 0) c
    join t on true
   cross join lateral (
     select string_agg(iv.document_number, ', ' order by iv.document_number) as invoices,
            array_agg(iv.id) as ids
       from erp.document iv
       join erp.document_type it
         on it.tenant_id = iv.tenant_id and it.id = iv.document_type_id
        and it.base_type_code = 'invoice_reference'
      where iv.tenant_id = t.tenant_id
        and iv.id in (select r.to_document_id
                        from erp.document_relation r
                       where r.tenant_id = t.tenant_id and r.from_document_id = c.document_id
                         and r.relation_kind = 'credits'
                      union
                      select il.document_id
                        from erp.document_relation rr
                        join erp.document_relation ir
                          on ir.tenant_id = rr.tenant_id and ir.to_line_id = rr.to_line_id
                         and ir.relation_kind = 'invoices'
                        join erp.document_line il
                          on il.tenant_id = ir.tenant_id and il.id = ir.from_line_id
                       where rr.tenant_id = t.tenant_id and rr.from_document_id = c.document_id
                         and rr.relation_kind = 'returns' and rr.to_line_id is not null)) g
   cross join lateral (
     select coalesce(sum(jl.base_credit_minor - jl.base_debit_minor), 0)::bigint as charged
       from erp.journal j
       join erp.ledger l on l.tenant_id = j.tenant_id and l.id = j.ledger_id and l.ledger_kind = 'statutory'
       join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
       join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id and a.control_kind = 'tax'
      where j.tenant_id = t.tenant_id and j.document_id = any(g.ids)
        and j.status = 'posted' and j.source_code like 'document.%') m
   cross join lateral (
     select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0)::bigint as given_back
       from erp.journal j
       join erp.ledger l on l.tenant_id = j.tenant_id and l.id = j.ledger_id and l.ledger_kind = 'statutory'
       join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
       join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id and a.control_kind = 'tax'
      where j.tenant_id = t.tenant_id and j.document_id = c.document_id
        and j.status = 'posted' and j.source_code like 'document.%') b
   where g.invoices is not null
     and b.given_back > m.charged
$n$;
begin
  if strpos(v_src, '20261010041000') > 0 then
    raise notice '% already finds a credit that gives back VAT never charged; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e13ee57cd111a152eff3101cc632ffd7' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010041000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$exceptions$;

revoke all on function erp.vat_exceptions(uuid, date, date) from public, anon;

comment on function erp.vat_exceptions(uuid, date, date) is
  'What a person checks before filing a VAT return (20261001000000). Blocking: an entry whose side cannot be told, one '
  'not in the company''s currency, one whose determinations and ledger disagree, tax control moved by a journal a '
  'document raised that is not an entry, and a customer''s credit note that gives back more VAT than the invoices it '
  'credits charged (20261010041000). For information: tax control moved by a journal naming no document. Flagged: a '
  'purchase from abroad stating no tax, and an exempt supply.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The ledger agreement is the agreement, and (g) is not a disagreement
-- ─────────────────────────────────────────────────────────────────────────────

do $agrees$
declare
  v_sig  constant text := 'erp.assert_vat_agrees_with_ledger()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    from erp.vat_exceptions(null, null, null) x
   where x.blocks;
$o$;
  v_new  constant text := $n$    from erp.vat_exceptions(null, null, null) x
   where x.blocks
     -- A credit giving back VAT its invoice never charged agrees with its own
     -- journal; it blocks finalising the return, not the ledger's agreement
     -- (20261010041000).
     and x.finding <> 'a credit gives back VAT the invoice it credits did not charge';
$n$;
begin
  if strpos(v_src, '20261010041000') > 0 then
    raise notice '% already leaves out a credit that gives back VAT never charged; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '4ec5899246e43df3530683fa7f8f8631' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010041000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$agrees$;

revoke all on function erp.assert_vat_agrees_with_ledger() from public, anon;

comment on function erp.assert_vat_agrees_with_ledger() is
  'Every VAT entry of the organisation agrees with the ledger, and nothing a document raised moves tax control outside '
  'one (20261001000000). Run for every organisation by the whole-database reconciliation. A credit note giving back VAT '
  'its invoice never charged agrees with its own journal and is left to the finalise gate (20261010041000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The VAT return suite: the finding, by hand
-- ─────────────────────────────────────────────────────────────────────────────

do $vat_return$
declare
  v_sig  constant text := 'erp_test.vat_return_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  -- Twenty-three since a credit note follows its invoice (20261010040000).
  c_expected constant integer := 23;
$o$;
  v_new1 constant text := $n$  -- Twenty-three since a credit note follows its invoice (20261010040000),
  -- twenty-four since a credit giving back VAT never charged blocks (20261010041000).
  c_expected constant integer := 24;
$n$;
  v_old2 constant text := $o$  v_reg_from date; v_class text; v_dn6 uuid; v_inv6 uuid; v_cn6 uuid; v_inv7 uuid; v_cn7 uuid;
begin
$o$;
  v_new2 constant text := $n$  v_reg_from date; v_class text; v_dn6 uuid; v_inv6 uuid; v_cn6 uuid; v_inv7 uuid; v_cn7 uuid;
  v_dl6 uuid; v_cn8 uuid; v_cl8 uuid; v_find integer; v_find_detail text; v_honest integer;
begin
$n$;
  v_old3 constant text := $o$    -- ── 20. The whole organisation agrees ───────────────────────────────────
$o$;
  v_new3 constant text := $n$    -- ── 19c. A credit giving back VAT never charged blocks (20261010041000) ──
    -- Done and undone inside a block of its own, so the organisation the last
    -- case reads holds only the honest notes.
    v_step := 'two more of the four sold before registering credited from the despatch, 20% VAT put on the note by hand';
    v_find := null; v_find_detail := null; v_honest := null; v_msg := null; v_msg2 := null;
    begin
      select l.id into v_dl6 from erp.document_line l
       where l.tenant_id = rb.tenant_id and l.document_id = v_dn6 and not coalesce(l.is_cancelled, false)
       order by l.line_no limit 1;
      v_cn8 := erp.raise_customer_credit_note(v_dn6, 'damaged', 'two more, VAT put on by hand',
                                              jsonb_build_array(jsonb_build_object('line_id', v_dl6, 'quantity', 2)));
      select l.id into v_cl8 from erp.document_line l
       where l.tenant_id = rb.tenant_id and l.document_id = v_cn8 and not coalesce(l.is_cancelled, false)
       order by l.line_no limit 1;
      insert into erp.tax_determination
        (tenant_id, entity_id, document_id, document_line_id, tax_code, rate_pct,
         taxable_minor, tax_minor, currency, jurisdiction, rule_code)
      values (rb.tenant_id, v_entity, v_cn8, v_cl8, 'S', 20, 20000, 4000, v_ccy, 'GB', 'by_hand');
      update erp.document_line set tax_code = 'S', tax_rate_pct = 20, tax_minor = 4000
       where tenant_id = rb.tenant_id and id = v_cl8;
      perform erp.transition_document(v_cn8, 'issue', 'vat return suite');
      select count(*), min(x.detail) into v_find, v_find_detail
        from erp.vat_exceptions(v_entity, v_wide_from, v_today) x
       where x.blocks and x.finding = 'a credit gives back VAT the invoice it credits did not charge'
         and x.reference = (select d.document_number from erp.document d where d.id = v_cn8);
      select count(*) into v_honest
        from erp.vat_exceptions(v_entity, v_wide_from, v_today) x
       where x.reference in (select d.document_number from erp.document d where d.id in (v_cn6, v_cn7, v_cn));
      begin
        v_msg := erp.assert_vat_agrees_with_ledger();
      exception when others then v_msg2 := sqlerrm; end;
      raise exception 'CLOVEERP_BY_HAND_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_BY_HAND_UNDO' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a credit note that gives back VAT the invoice it credits never charged is a finding that blocks the return, naming the note, what it gives back and the invoice; the notes that gave back what was charged are not, and the ledger agreement does not count it';
    passed := v_state is null
          and v_find = 1
          and v_find_detail like '% gives back 40.00 GBP of VAT, and %'
          and v_find_detail like '%' || (select d.document_number from erp.document d where d.id = v_inv6) || ', which it credits, charged 0.00 GBP'
          and v_honest = 0
          and v_msg like 'vat: %' and v_msg2 is null;
    detail := coalesce(v_state, format('%s finding(s): %s; %s about the honest notes; the ledger agreement: %s',
                                       v_find, coalesce(v_find_detail, 'none'), v_honest,
                                       coalesce(left(v_msg2, 160), v_msg)));
    return next;

    -- ── 20. The whole organisation agrees ───────────────────────────────────
$n$;
begin
  if strpos(v_src, '20261010041000') > 0 then
    raise notice '% already puts VAT on a credit by hand; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'da9230495175b52365b8321ef7893ab0' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010041000 expects (md5 %)', v_sig, md5(v_src);
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
  v_old  constant text := $o$  -- Twenty-three since a credit note follows its invoice (20261010040000).
  if v_total <> 23 then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_SHRANK: % case(s), expected 23', v_total
$o$;
  v_new  constant text := $n$  -- Twenty-three since a credit note follows its invoice (20261010040000),
  -- twenty-four since a credit giving back VAT never charged blocks (20261010041000).
  if v_total <> 24 then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_SHRANK: % case(s), expected 24', v_total
$n$;
begin
  if strpos(v_src, '20261010041000') > 0 then
    raise notice '% already expects twenty-four cases; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e97d116066fde296b9e8abdc3db761a8' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010041000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$vat_return_assert$;

revoke all on function erp_test.vat_return_suite() from public, anon;
revoke all on function erp_test.assert_vat_return_suite() from public, anon;

comment on function erp_test.vat_return_suite() is
  'The nine VAT boxes and the tax report (20261001000000): the one-button bill in box 4 and in the ledger alike, a sale '
  'in boxes 1 and 6, a credit note and a reversal subtracting on their own dates, zero-rated and exempt in box 6 and '
  'outside the scope not, an untaxed bill in box 7, the form''s arithmetic, whole pounds, the tax point''s quarter, a '
  'manual journal listed and in no box, the report equal to boxes 1 and 4, a disagreement refused, and finance.read at '
  'both doors. A customer''s credit note gives back what its invoice charged: nothing against an invoice issued before '
  'the company registered, and the invoice''s 20% after the product was reclassed (20261010040000); one that gives '
  'back VAT never charged blocks the return (20261010041000).';

comment on function erp_test.assert_vat_return_suite() is
  'The nine VAT boxes are computed from the posted journals and agree with the ledger, the tax report subtracts credit '
  'notes and reversals (20261001000000), a credit note gives back the VAT its invoice charged, at its rate, and no '
  'more (20261010040000), and one that gives back VAT never charged blocks the return (20261010041000).';

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
