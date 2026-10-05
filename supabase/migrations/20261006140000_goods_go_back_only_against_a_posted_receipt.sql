set lock_timeout = '30s';

-- =============================================================================
-- 20261006140000  Goods go back only against a posted receipt, and never as samples
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October, and in the design that
-- followed the owner's decision that a draft goods receipt receives nothing
-- (20261006131000):
--
--   (a) erp.raise_supplier_credit_note() asked only that the document be a
--       goods receipt. A receipt still in draft could be sent back: the
--       page hides Send back on a draft, but the door did not refuse it, and
--       the note's issue then takes off the shelf and out of goods received
--       not invoiced what the draft never put there. Since a draft receives
--       nothing, received-not-billed would also go below nothing for its line.
--   (b) J-69. A receipt of a supplier's samples (20261004930000) is posted
--       and the supplier owns its goods. The receipt page drew Send back on
--       it as on any other posted receipt, and neither the door nor
--       erp.return_to_supplier() asked whether it was samples, so a credit
--       note could be raised for goods nobody paid for, at no price, taking
--       the supplier's own stock off the shelf.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.raise_supplier_credit_note(), which erp.return_to_supplier() and
--      public.erp_raise_supplier_credit_note reach, refuses a receipt that is
--      not committed (posted) with CLOVEERP_RECEIPT_NOT_POSTED, the code
--      erp.bill_from_receipt() already raises for the same reason, with a
--      hint; and refuses a receipt of samples with a new refusal,
--      CLOVEERP_SAMPLES_ARE_NOT_CREDITED, whose next action is to settle them
--      from Samples on the Purchasing page. Committed, not the state code
--      'posted', because that is how erp.receivable_lines() and
--      erp.refresh_order_line_progress() decide "received".
--   B. The new refusal is registered: what was refused, why, and what to do.
--   C. public.erp_document says whether a receipt is samples (is_sample), so
--      the page does not draw Send back on one.
--   D. erp_test.supplier_return_suite proves (a) both ways, and
--      erp_test.supplier_samples_suite proves (b) and (C).
--
-- ── WHAT STAYS AS IT WAS ─────────────────────────────────────────────────────
--
-- A posted receipt is sent back exactly as before. Samples still go back,
-- are kept or are bought from Samples on the Purchasing page
-- (public.erp_settle_samples). Nothing on the bill side changes.
--
-- Production: one routine and one door are replaced and one refusal is
-- registered. No table is altered and no row is changed: a credit note
-- already raised is left as it is, and only a new one is refused.
--
-- Proof: erp_test.supplier_return_suite, erp_test.supplier_samples_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. Only what arrived, and not what was lent
-- ═════════════════════════════════════════════════════════════════════════════

do $credit$
declare
  v_sig  constant text := 'erp.raise_supplier_credit_note(uuid,text,text,jsonb,bigint,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$  ln       record;
begin
$o$,
$o$      'against the receipt that brought them in', d.document_number, v_base
      using errcode = '23514';
  end if;
$o$];
  v_new  text[] := array[
$n$  ln       record;
  v_rstate text;
  v_posted boolean;
begin
$n$,
$n$      'against the receipt that brought them in', d.document_number, v_base
      using errcode = '23514';
  end if;

  -- Goods go back against what has arrived (20261006140000). A receipt in
  -- draft received nothing: it put nothing on the shelf and accrued nothing,
  -- so a note's issue would take off both what was never there. Committed,
  -- as erp.receivable_lines() and erp.refresh_order_line_progress() decide
  -- received; a cancelled receipt is not.
  select s.code, coalesce(s.is_committed, false) and not coalesce(d.is_cancelled, false)
    into v_rstate, v_posted
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_document_id;

  if not coalesce(v_posted, false) then
    raise exception 'CLOVEERP_RECEIPT_NOT_POSTED: % is %, and goods go back against what has arrived',
      d.document_number, coalesce(v_rstate, 'in no state')
      using errcode = '23514',
            hint = 'Post the goods receipt first, or cancel it if the goods were turned away.';
  end if;

  -- A supplier's samples are theirs, lent and not bought (20261004930000):
  -- nothing was owed for them, so there is nothing to credit, and a note
  -- would take their stock off the shelf at a price nobody paid. They go
  -- back, are kept or are bought from Samples (20261006140000, J-69).
  if erp.is_sample_receipt(p_document_id) then
    raise exception 'CLOVEERP_SAMPLES_ARE_NOT_CREDITED: % received samples the supplier lent, and there is nothing to credit for them',
      d.document_number
      using errcode = '23514',
            hint = 'Settle them from Samples on the Purchasing page: return, keep or buy.';
  end if;
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261006140000') > 0 then
    raise notice '% already sends back only what arrived; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e82bfd3cff64f875b3f305181d8327ca' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006140000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$credit$;

comment on function erp.raise_supplier_credit_note(uuid,text,text,jsonb,bigint,text) is
  'Raises a draft supplier credit note against a posted goods receipt, line by line, no more than is still '
  'here. A receipt in draft or cancelled is refused (CLOVEERP_RECEIPT_NOT_POSTED), and so is a receipt of '
  'samples, which are settled from Samples instead (CLOVEERP_SAMPLES_ARE_NOT_CREDITED; 20261006140000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The refusal
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal(
  'CLOVEERP_SAMPLES_ARE_NOT_CREDITED',
  'Sending a supplier''s samples back on a credit note.',
  'Samples are lent by the supplier and stay theirs until they are returned, kept or bought. Nothing was paid for them, so there is nothing to credit, and a credit note would take their stock off the shelf at a price nobody paid.',
  'Open Samples on the Purchasing page and settle the line: return it, keep it free, or buy it.');

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The page knows a receipt of samples
-- ═════════════════════════════════════════════════════════════════════════════

do $document$
declare
  v_sig  constant text := 'public.erp_document(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$        'lines_open', erp.document_lines_open(d.id))
$o$;
  v_new  constant text := $n$        'lines_open', erp.document_lines_open(d.id),
        -- Whether it is a receipt of samples the supplier lent
        -- (20261006140000, J-69): they are settled from Samples, so the page
        -- does not offer to send them back on a credit note.
        'is_sample', erp.is_sample_receipt(d.id))
$n$;
begin
  if strpos(v_src, '20261006140000') > 0 then
    raise notice '% already says whether a receipt is samples; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '9a77bc3349059e3903b99b19f8ec8703' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006140000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$document$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The suites
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.supplier_return_suite: five more arrive on a receipt left in
-- draft. A credit note against it is refused by name, directly and through
-- the door, and nothing is raised; once it is posted the same note is.
do $return$
declare
  v_sig  constant text := 'erp_test.supplier_return_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$  c_expected constant integer := 14;
$o$,
$o$  v_unit_b bigint;
$o$,
$o$    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$o$];
  v_new  text[] := array[
$n$  -- Fourteen until 20261006140000, which added that goods go back only
  -- against a posted receipt.
  c_expected constant integer := 15;
$n$,
$n$  v_unit_b bigint;
  v_po_d uuid; v_pol_d uuid; v_grn_d uuid; v_scn_d uuid;
  v_err text; v_err2 text; v_hint text; v_notes integer;
$n$,
$n$    -- ── 14. Not against a receipt still in draft (20261006140000) ─────────
    v_step := 'five more of the first product arrive on a receipt left in draft';
    v_po_d := erp.open_document('purchase_order', v_sup, rb.entity_id, v_site);
    v_pol_d := erp.add_document_line(v_po_d, v_item_a, 5, 1000, 'five more at ten pounds');
    perform erp.transition_document(v_po_d, 'submit', 'supplier return suite');
    perform erp_test.approve_document(v_po_d, 'supplier return suite');
    perform erp.transition_document(v_po_d, 'send', 'supplier return suite');
    v_grn_d := erp.open_document('goods_receipt', v_sup, rb.entity_id, v_site);
    perform erp.receive_against(v_grn_d, v_pol_d, 5, null);
    v_notes := (select count(*) from erp.document cn
                  join erp.document_type cdt on cdt.tenant_id = cn.tenant_id and cdt.id = cn.document_type_id
                 where cn.tenant_id = rb.tenant_id and cdt.code = 'purchase_credit_note');

    v_step := 'a credit note against the draft, directly and through the door';
    begin
      perform erp.raise_supplier_credit_note(v_grn_d, 'DAMAGED_ARRIVAL', 'Sent back before it was counted in');
      v_err := 'raised';
    exception when others then
      v_err := sqlerrm;
      get stacked diagnostics v_hint = pg_exception_hint;
    end;
    begin
      perform public.erp_raise_supplier_credit_note(v_grn_d, 'DAMAGED_ARRIVAL', 'Sent back before it was counted in');
      v_err2 := 'raised';
    exception when others then
      v_err2 := sqlerrm;
    end;

    v_step := 'the draft posted, and the same note raised';
    perform erp.transition_document(v_grn_d, 'post', 'supplier return suite');
    v_scn_d := erp.raise_supplier_credit_note(v_grn_d, 'DAMAGED_ARRIVAL', 'Sent back once it was counted in');

    v_cases := v_cases + 1;
    case_name := 'a credit note against a goods receipt still in draft is refused, directly and through the door, and nothing is raised; once the receipt is posted the same note is';
    passed := v_state is null
          and v_err like 'CLOVEERP_RECEIPT_NOT_POSTED:%'
          and v_err2 like 'CLOVEERP_RECEIPT_NOT_POSTED:%'
          and coalesce(v_hint, '') <> ''
          and v_scn_d is not null
          and (select count(*) from erp.document cn
                 join erp.document_type cdt on cdt.tenant_id = cn.tenant_id and cdt.id = cn.document_type_id
                where cn.tenant_id = rb.tenant_id and cdt.code = 'purchase_credit_note') = v_notes + 1;
    detail := coalesce(v_state, left(format('%s | %s | hint: %s | after posting: %s',
                                            v_err, v_err2, v_hint, coalesce(v_scn_d::text, 'nothing')), 600));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261006140000') > 0 then
    raise notice '% already refuses a draft receipt; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'a1bd2919b0cd0c4dd175e8579956ff82' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006140000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$return$;

do $return_count$
declare
  v_sig  constant text := 'erp_test.assert_supplier_return_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  c_expected constant integer := 14;
$o$;
  v_new  constant text := $n$  -- Fourteen until 20261006140000, which added that goods go back only
  -- against a posted receipt.
  c_expected constant integer := 15;
$n$;
begin
  if strpos(v_src, '20261006140000') > 0 then
    raise notice '% already counts 15; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'bb3196b6d294dedee8c76931befff0ba' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006140000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$return_count$;

-- erp_test.supplier_samples_suite: a credit note against the samples
-- receipt is refused by name, directly and through the door, the page is
-- told the receipt is samples, and the bag it holds is still held.
do $samples$
declare
  v_sig  constant text := 'erp_test.supplier_samples_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$  c_expected constant integer := 10;
$o$,
$o$    v_step := 'the daily check, twice';
$o$];
  v_new  text[] := array[
$n$  -- Ten until 20261006140000, which added that samples are not sent back on
  -- a credit note.
  c_expected constant integer := 11;
$n$,
$n$    -- ── 8b. Not sent back on a credit note (20261006140000, J-69) ─────────
    v_step := 'a credit note against the samples receipt, directly and through the door';
    begin
      perform erp.raise_supplier_credit_note(v_grn, 'DAMAGED_ARRIVAL', 'the bag came scuffed');
      v_err := 'raised';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_raise_supplier_credit_note(v_grn, 'DAMAGED_ARRIVAL', 'the bag came scuffed');
      v_err2 := 'raised';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'samples are not sent back on a credit note: refused by name, directly and through the door, with the refusal registered; the receipt page is told the receipt is samples, and the bag is still held';
    passed := v_state is null
          and v_err like 'CLOVEERP_SAMPLES_ARE_NOT_CREDITED:%'
          and v_err2 like 'CLOVEERP_SAMPLES_ARE_NOT_CREDITED:%'
          and exists (select 1 from erp_ref.refusal f
                       where f.code = 'CLOVEERP_SAMPLES_ARE_NOT_CREDITED'
                         and coalesce(f.next_action, '') <> '')
          and coalesce((public.erp_document(v_grn) -> 'document' ->> 'is_sample')::boolean, false)
          and erp.sample_line_held(v_line2) = 1
          and not exists (select 1 from erp.document cn
                            join erp.document_type cdt
                              on cdt.tenant_id = cn.tenant_id and cdt.id = cn.document_type_id
                           where cn.tenant_id = rb.tenant_id and cdt.code = 'purchase_credit_note');
    detail := coalesce(v_state, left(format('%s | %s | is_sample %s', v_err, v_err2,
                                            public.erp_document(v_grn) -> 'document' ->> 'is_sample'), 700));
    return next;

    v_step := 'the daily check, twice';
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261006140000') > 0 then
    raise notice '% already refuses a credit note against samples; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'cf7feb640bfe8e79bb4172112ac834d7' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006140000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$samples$;

do $samples_count$
declare
  v_sig  constant text := 'erp_test.assert_supplier_samples_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 10 then
    raise exception 'CLOVEERP_SUPPLIER_SAMPLES_SUITE_SHRANK: % case(s), expected 10', v_total
$o$;
  v_new  constant text := $n$  -- Ten until 20261006140000, which added that samples are not sent back on
  -- a credit note.
  if v_total <> 11 then
    raise exception 'CLOVEERP_SUPPLIER_SAMPLES_SUITE_SHRANK: % case(s), expected 11', v_total
$n$;
begin
  if strpos(v_src, '20261006140000') > 0 then
    raise notice '% already counts 11; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '70ab96a820a1c56ff4e84926642779e6' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006140000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$samples_count$;

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
