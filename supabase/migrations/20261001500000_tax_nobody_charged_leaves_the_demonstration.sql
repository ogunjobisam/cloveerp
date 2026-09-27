set lock_timeout = '30s';

-- =============================================================================
-- 20261001500000  Tax nobody charged leaves the demonstration
-- -----------------------------------------------------------------------------
-- Every deploy since PR14 M1 (20261001000000) has applied and then failed its
-- proof on live:
--
--   CLOVEERP_DATABASE_DOES_NOT_RECONCILE: 1/63 check(s) failed across 3 organisation(s)
--     demo-cbb10384: erp.assert_vat_agrees_with_ledger() — CLOVEERP_VAT_DISAGREES_WITH_LEDGER: 92 finding(s)
--     the tax determined is not the tax the ledger carries [INV-000256] INV-000256
--       determined 32670 and journal GL-2026-000410 moved tax control by 0
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- Residue of the defect 20260919910000 named and fixed. An invoice issued
-- while its company was not yet registered for VAT (the demonstration's
-- registration arrived with 20260916090000) determined nothing and posted
-- net: its journal moves tax control by nothing, and the customer owes the
-- net. Between 20260919200000 and 20260919910000 a payment re-ran the
-- determination as the invoice settled, and by then the gates were open, so
-- it wrote determinations nobody charged. 20260919910000 stopped that from
-- happening again ("the determination is made on the FIRST entry into a
-- committed state and on no later one") and said so of the rows it had
-- already written: not edited there. Nothing held them to the ledger until
-- erp.assert_vat_agrees_with_ledger() (20261001000000), which is right to
-- refuse them: the return and the ledger are two accounts of one tax.
--
-- The ledger is the right one. The journal is what the customer was charged
-- and owes; the determination is a later reading of what they might have been.
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--
--   * erp.withdraw_tax_nobody_charged(): in the organisation it is called in,
--     the documents whose every VAT entry moved tax control by nothing while
--     their determinations say tax: their determinations are withdrawn, so
--     the return reads what the ledger does. Nothing else is touched: a
--     document whose ledger carries any tax, and every figure in the ledger.
--     A document a VAT return names is refused by name, and nothing is
--     withdrawn: a filed return is not changed from underneath (20261001100000).
--     Nothing is done in a live organisation, which never met the defect's
--     window with a registration behind it; the deploy's own check says so
--     for the two live ones today.
--   * This migration calls it in every organisation that is not live and
--     says what it withdrew, so the deploy's log is the record.
--
-- Proof: erp_test.tax_nobody_charged_suite (4 cases).
-- =============================================================================

select erp.register_refusal('CLOVEERP_TAX_NOBODY_CHARGED_WAS_FILED',
  'Withdrawing tax nobody charged from a document a VAT return names.',
  'A VAT return keeps the journals it took and what they said; withdrawing tax from one of them would change a return that was filed.',
  'Leave the document as it is and correct it on the next return, with a credit note or a reversal.');

create or replace function erp.withdraw_tax_nobody_charged()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_docs   uuid[];
  v_filed  text;
begin
  -- The residue of the determination 20260919910000 stopped (20261001500000).
  -- Not in a live organisation.
  if erp.environment_is_live() then
    return 0;
  end if;

  -- The documents every VAT entry of which moved tax control by nothing while
  -- their determinations say tax. erp.vat_entries() is the reading the return
  -- and the ledger agreement both take.
  select array_agg(x.document_id) into v_docs
    from (select e.document_id
            from erp.vat_entries(null, null, null) e
           group by e.document_id
          having bool_and(e.tax_minor = 0) and bool_or(e.determined_tax_minor <> 0)) x;
  if v_docs is null then
    return 0;
  end if;

  -- A filed return is not changed from underneath.
  select string_agg(distinct rd.document_number, ', ') into v_filed
    from erp.document rd
    join erp.document_type dt on dt.tenant_id = rd.tenant_id and dt.id = rd.document_type_id
     and dt.base_type_code = 'vat_return'
   cross join lateral jsonb_array_elements_text(coalesce(rd.attributes #> '{vat_return,journal_ids}', '[]'::jsonb)) j
    join erp.journal jj on jj.tenant_id = rd.tenant_id and jj.id = j.value::uuid
   where rd.tenant_id = v_tenant and not rd.is_cancelled
     and jj.document_id = any(v_docs);
  if v_filed is not null then
    raise exception 'CLOVEERP_TAX_NOBODY_CHARGED_WAS_FILED: % names a document whose determinations its ledger never carried', v_filed
      using errcode = '23514',
            hint = 'Leave the document as it is and correct it on the next return, with a credit note or a reversal.';
  end if;

  delete from erp.tax_determination td
   where td.tenant_id = v_tenant and td.document_id = any(v_docs);

  return coalesce(array_length(v_docs, 1), 0);
end;
$$;

revoke all on function erp.withdraw_tax_nobody_charged() from public, anon, authenticated;

comment on function erp.withdraw_tax_nobody_charged() is
  'Withdraws the determinations of documents whose every VAT entry moved tax control by nothing, in the '
  'organisation it is called in: the residue of the late determination 20260919910000 stopped '
  '(20261001500000). Refuses a document a VAT return names; does nothing in a live organisation. '
  'Returns the documents it cleared.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Every organisation that is not live, from this trusted session.
-- ─────────────────────────────────────────────────────────────────────────────

do $withdraw$
declare
  r       record;
  v_n     integer;
  v_total integer := 0;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.withdraw_tax_nobody_charged();
    if v_n > 0 then
      raise warning 'tax nobody charged: % document(s) in % had their determinations withdrawn', v_n, r.code;
      v_total := v_total + v_n;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
  raise warning 'tax nobody charged: % document(s) in all', v_total;
end
$withdraw$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.tax_nobody_charged_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  rb       record;
  v_entity uuid; v_ccy char(3); v_site uuid; v_item uuid; v_cust uuid; v_line uuid;
  v_net uuid; v_taxed uuid; v_journal uuid; v_ret uuid;
  v_n integer; v_m integer; v_k integer; v_blocks integer;
  v_err text; v_msg text;
begin
  begin
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zztn-' || v_tag, 'Tax Nobody Charged Suite',
      'admin@zztn-' || v_tag || '.test', 'Tax Nobody Charged Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zztn-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select i.id into v_item from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active'::erp.record_status order by i.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZZTNCUST', 'Tax nobody charged customer', 'GB', 'active')
    returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');

    -- ── The defect, as the demonstration met it ─────────────────────────────
    v_step := 'an invoice issued before the company registered, so posted net';
    delete from erp.entity_tax_registration r where r.tenant_id = rb.tenant_id and r.entity_id = v_entity;
    v_net := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZZTN-NET', '{}'::jsonb);
    v_line := erp.add_document_line(v_net, v_item, 1, 10000, 'sold before registering');
    perform erp.set_invoice_tax_point(v_net, current_date);
    perform erp.transition_document(v_net, 'issue', 'tax nobody charged suite');

    v_step := 'the company registered, and an invoice issued with its tax';
    insert into erp.entity_tax_registration
      (tenant_id, entity_id, jurisdiction, registration_type, registration_number, valid_from)
    values (rb.tenant_id, v_entity, 'GB', 'VAT', 'GB999999973', current_date - 400);
    v_taxed := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZZTN-TAXED', '{}'::jsonb);
    perform erp.add_document_line(v_taxed, v_item, 1, 10000, 'sold registered');
    perform erp.set_invoice_tax_point(v_taxed, current_date);
    perform erp.transition_document(v_taxed, 'issue', 'tax nobody charged suite');

    v_step := 'a determination written on the net invoice after it posted, as its payment once did';
    insert into erp.tax_determination
      (tenant_id, entity_id, document_id, document_line_id, tax_code, rate_pct,
       taxable_minor, tax_minor, currency, jurisdiction)
    values (rb.tenant_id, v_entity, v_net, v_line, 'S', 20, 10000, 2000, v_ccy, 'GB');

    -- ── 1. Withdrawn, and the return reads the ledger ───────────────────────
    v_step := 'the residue withdrawn';
    select count(*) into v_blocks from erp.vat_exceptions(v_entity, null, null) x
     where x.blocks and x.finding like 'the tax determined is not%';
    select count(*) into v_k from erp.tax_determination td where td.document_id = v_taxed;
    v_n := erp.withdraw_tax_nobody_charged();
    v_err := null;
    begin
      v_msg := erp.assert_vat_agrees_with_ledger();
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'determinations on an invoice whose ledger carried no tax are withdrawn, the ledger agreement passes, and an invoice taxed in its ledger keeps its own';
    passed := v_state is null
          and v_blocks = 1 and v_n = 1
          and not exists (select 1 from erp.tax_determination td where td.document_id = v_net)
          and v_k > 0
          and (select count(*) from erp.tax_determination td where td.document_id = v_taxed) = v_k
          and v_err is null
          and not exists (select 1 from erp.vat_exceptions(v_entity, null, null) x where x.blocks);
    detail := coalesce(v_state, format('%s finding(s) before; %s document(s) cleared; the taxed invoice kept %s; %s',
                                       v_blocks, v_n, v_k, coalesce(v_err, v_msg)));
    return next;

    -- ── 2. Not in a live organisation ───────────────────────────────────────
    v_step := 'the same residue in an organisation that is live';
    v_n := null; v_m := null;
    begin
      insert into erp.tax_determination
        (tenant_id, entity_id, document_id, document_line_id, tax_code, rate_pct,
         taxable_minor, tax_minor, currency, jurisdiction)
      values (rb.tenant_id, v_entity, v_net, v_line, 'S', 20, 10000, 2000, v_ccy, 'GB');
      update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
      v_n := erp.withdraw_tax_nobody_charged();
      select count(*) into v_m from erp.tax_determination td where td.document_id = v_net;
      raise exception 'CLOVEERP_LIVE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_LIVE_UNDO' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'nothing is withdrawn in a live organisation';
    passed := v_state is null and v_n = 0 and v_m = 1;
    detail := coalesce(v_state, format('%s cleared; %s determination(s) left', v_n, v_m));
    return next;

    -- ── 3. Not from under a VAT return ──────────────────────────────────────
    v_step := 'the same residue, on a journal a VAT return names';
    v_err := null; v_m := null;
    begin
      insert into erp.tax_determination
        (tenant_id, entity_id, document_id, document_line_id, tax_code, rate_pct,
         taxable_minor, tax_minor, currency, jurisdiction)
      values (rb.tenant_id, v_entity, v_net, v_line, 'S', 20, 10000, 2000, v_ccy, 'GB');
      select j.id into v_journal from erp.journal j
       where j.tenant_id = rb.tenant_id and j.document_id = v_net and j.source_code like 'document.%'
       order by j.posted_at limit 1;
      v_ret := erp.open_document('vat_return', null, v_entity, null, null, null, v_ccy);
      update erp.document d
         set attributes = d.attributes || jsonb_build_object('vat_return',
               jsonb_build_object('journal_ids', jsonb_build_array(v_journal)))
       where d.id = v_ret;
      begin
        perform erp.withdraw_tax_nobody_charged();
        v_err := 'withdrawn';
      exception when others then v_err := left(sqlerrm, 200); end;
      select count(*) into v_m from erp.tax_determination td where td.document_id = v_net;
      raise exception 'CLOVEERP_FILED_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_FILED_UNDO' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a document a VAT return names is refused by name, and nothing is withdrawn';
    passed := v_state is null
          and v_err like 'CLOVEERP_TAX_NOBODY_CHARGED_WAS_FILED:%'
          and v_m = 1;
    detail := coalesce(v_state, format('%s; %s determination(s) left', v_err, v_m));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 4. Undone ──────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zztn-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zztn rolled back with its invoices');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_TAX_NOBODY_CHARGED_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.tax_nobody_charged_suite() from public, anon;

comment on function erp_test.tax_nobody_charged_suite() is
  'Determinations a ledger never carried are withdrawn from an organisation that is not live, and '
  'nowhere a VAT return names them (20261001500000).';

create or replace function erp_test.assert_tax_nobody_charged_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.tax_nobody_charged_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_TAX_NOBODY_CHARGED_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Tax the ledger never carried would stay on the return, or be taken from somewhere it should not. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_TAX_NOBODY_CHARGED_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('tax nobody charged: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_tax_nobody_charged_suite() from public, anon;

comment on function erp_test.assert_tax_nobody_charged_suite() is
  'The residue of the late determination is withdrawn where it may be, and nowhere else (20261001500000).';

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
select erp.assert_every_transition_is_driven();
