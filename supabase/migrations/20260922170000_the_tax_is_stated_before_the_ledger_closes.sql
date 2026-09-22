set lock_timeout = '30s';

-- =============================================================================
-- 20260922170000  The tax is stated before the ledger closes on the bill
-- -----------------------------------------------------------------------------
-- erp.state_supplier_tax() (20260916410000:65-100) writes the tax a supplier
-- charged onto the bill's lines and raises the determinations
-- erp.tax_report() reads. It has no state guard: it will do that to a bill that
-- posted an hour ago.
--
-- The ledger takes its tax figure once, when the bill is registered:
-- erp.post_document_finance() resolves `document_tax` through
-- erp.document_tax_minor(), which sums erp.document_line.tax_minor. Whatever
-- that sums to at that moment is what reaches the tax control account, and
-- nothing revisits it.
--
-- So stating tax after registration produces a bill whose lines carry VAT, a
-- determination the return will report, and a journal that carries none. The
-- VAT return claims input tax the ledger has never seen. That is exactly the
-- first finding of erp.tax_outside_the_ledger_report() — "the tax on a posted
-- document is not the tax its journal carries" — and it is a finding about
-- money owed to or by a tax authority, on a report somebody files.
--
-- ── AND THE ONE-BUTTON ROUTE WALKED STRAIGHT INTO IT ─────────────────────────
--
-- erp.bill_from_receipt() builds the bill from what arrived and registers it in
-- the same call. It had no way to carry the supplier's tax, so the one route
-- the procurement screen offers for billing a receipt could only ever produce a
-- bill stating no tax — and the only way to correct that was to state the tax
-- afterwards, which is the defect above. The screen's own button led to it.
--
-- Both halves are fixed here, because either alone leaves the product worse
-- than it is: the guard without the parameter would make the one-button route
-- permanently unable to carry VAT, and the parameter without the guard would
-- leave the hole open for anybody who took the other route.
--
-- ── WHAT THE GUARD REFUSES, AND WHAT IT DOES NOT ─────────────────────────────
--
-- Refused: stating tax on a document a journal has already been written for.
-- Not refused: a draft, or a registered document that for whatever reason never
-- posted. The test is the journal, not the state, because the journal is the
-- thing that would disagree — a lifecycle that registers without posting has
-- nothing to contradict yet.
--
-- Nor is restating refused before posting. A supplier's figure typed wrongly
-- and corrected is an ordinary thing that happens before anybody files
-- anything; erp.state_supplier_tax() already replaces what it finds.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The guard
-- ═════════════════════════════════════════════════════════════════════════════
--
-- After the checks about what kind of document this is and what the figure is,
-- and before any of the work — so a person who has asked for something
-- impossible is told which of the impossibilities it was.

do $guard$
declare
  v_sig constant text := 'erp.state_supplier_tax(uuid, bigint, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  select coalesce(sum(l.net_minor), 0) into v_net\n'
    || E'    from erp.document_line l\n';
  v_new constant text :=
       E'  -- The ledger takes its tax figure once, when the document posts, from\n'
    || E'  -- erp.document_tax_minor() over the lines as they stand then\n'
    || E'  -- (20260922170000). Stating tax after that writes a figure the return\n'
    || E'  -- will report and the journal will never carry.\n'
    || E'  if exists (select 1 from erp.journal j\n'
    || E'              where j.tenant_id = v_tenant and j.document_id = p_document_id) then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_TAX_AFTER_THE_LEDGER: % has posted, and its journal carries % of tax'',\n'
    || E'      d.document_number, erp.document_tax_minor(p_document_id)\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''State the tax before the bill is registered — the one-button '' ||\n'
    || E'                   ''route takes it as you raise the bill. Where the bill has posted '' ||\n'
    || E'                   ''already, ask the supplier for a credit note and raise it again, '' ||\n'
    || E'                   ''so both figures are in the ledger and the trail shows why.'';\n'
    || E'  end if;\n'
    || E'\n'
    || E'  select coalesce(sum(l.net_minor), 0) into v_net\n'
    || E'    from erp.document_line l\n';
  v_hits integer;
begin
  if position('CLOVEERP_TAX_AFTER_THE_LEDGER' in v_def) > 0 then
    raise exception
      'CLOVEERP_TAX_DOOR_UNRECOGNISED: % already refuses a statement after the ledger', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TAX_DOOR_UNRECOGNISED: % sums its net % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$guard$;

select erp.register_refusal('CLOVEERP_TAX_AFTER_THE_LEDGER',
  'Stating the tax a supplier charged on a bill that has already posted.',
  'The ledger takes the tax figure once, when the bill is registered, and never looks again. Typing it afterwards puts the tax on the bill and on the VAT return while the journal still carries none — so the return would claim tax back that the accounts have no record of, and the two would disagree on a figure somebody files with a tax authority.',
  'State the tax as the bill is raised: the button that bills a goods receipt takes it, and a bill entered by hand takes it before it is registered. Where the bill has posted already, ask the supplier for a credit note and raise the bill again with the right figure, so both are in the ledger and the trail shows what happened.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the one-button route carries the figure
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two arguments, defaulted, so every existing call keeps its meaning: null tax
-- is "the supplier charged none, or it is stated separately before this bill is
-- registered", which is what those callers already meant.
--
-- The old five-argument function is dropped rather than left beside the new
-- one. Postgres cannot tell a five-argument call apart from a seven-argument
-- one with two defaults, and a door that sometimes refuses to resolve is worse
-- than either. Every caller passes five or fewer, so every caller binds to this
-- one unchanged.

drop function if exists erp.bill_from_receipt(uuid, text, date, date, boolean);

create or replace function erp.bill_from_receipt(
  p_receipt_id      uuid,
  p_their_reference text default null,
  p_invoice_date    date default null,
  p_due_date        date default null,
  p_register        boolean default true,
  p_tax_minor       bigint default null,
  p_tax_code        text default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  rd       erp.document%rowtype;
  v_inv    uuid;
  v_date   date := coalesce(p_invoice_date, current_date);
  v_lines  integer := 0;
  r        record;
begin
  select * into rd from erp.document
   where tenant_id = v_tenant and id = p_receipt_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_receipt_id using errcode = '23503';
  end if;

  if erp.object_current_state('document', p_receipt_id) <> 'posted' then
    raise exception 'CLOVEERP_RECEIPT_NOT_POSTED: % is %, and a bill is raised against what has arrived',
      rd.document_number, erp.object_current_state('document', p_receipt_id)
      using errcode = '23514',
      hint = 'Post the goods receipt first. Until it is posted nothing has been received.';
  end if;

  if exists (select 1 from erp.document_relation rel
               join erp.document i2 on i2.tenant_id = rel.tenant_id and i2.id = rel.from_document_id
               join erp.document_type it on it.tenant_id = i2.tenant_id and it.id = i2.document_type_id
              where rel.tenant_id = v_tenant and rel.to_document_id = p_receipt_id
                and rel.relation_kind = 'invoices'
                and it.code = 'purchase_invoice' and not i2.is_cancelled) then
    raise exception 'CLOVEERP_ALREADY_BILLED: % already has a supplier bill', rd.document_number
      using errcode = '23505',
      hint = 'Cancel the bill that exists before raising another against the same receipt.';
  end if;

  perform erp.authorise('procurement.match', rd.entity_id, rd.site_id, null,
                        'document', p_receipt_id);

  v_inv := erp.open_document('purchase_invoice', rd.party_id, rd.entity_id, rd.site_id,
                             p_their_reference, null, rd.currency);

  update erp.document
     set document_date = v_date,
         due_date = coalesce(p_due_date, v_date + 30),
         notes = coalesce(notes, format('Billed from %s', rd.document_number)),
         updated_at = now()
   where id = v_inv;

  -- What arrived, line by line, against the order line it arrived against — so
  -- three-way matching and the order's invoiced quantity work exactly as they
  -- do when somebody bills by hand.
  for r in
    select rel.to_line_id as order_line_id, sum(rel.quantity) as qty
      from erp.document_relation rel
     where rel.tenant_id = v_tenant
       and rel.from_document_id = p_receipt_id
       and rel.relation_kind = 'fulfils'
       and rel.to_line_id is not null
     group by rel.to_line_id
  loop
    perform erp.invoice_against(v_inv, r.order_line_id, r.qty, null);
    v_lines := v_lines + 1;
  end loop;

  if v_lines = 0 then
    raise exception 'CLOVEERP_RECEIPT_HAS_NO_ORDER_LINES: % was not received against an order', rd.document_number
      using errcode = '23514',
      hint = 'Receive against a purchase order line: erp_receive_against().';
  end if;

  insert into erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind)
  values (v_tenant, v_inv, p_receipt_id, 'invoices');

  -- Before the register, and that ordering is the whole of this node
  -- (20260922170000). The ledger reads erp.document_tax_minor() as it posts, so
  -- a figure stated after the register reaches the VAT return and never reaches
  -- the accounts. erp.state_supplier_tax() refuses it outright now; here it is
  -- simply done in the right order, so the one-button route can carry VAT at
  -- all.
  --
  -- Null is not zero. Null means the supplier's figure is not being stated on
  -- this call — either they charged none, or it is being stated separately
  -- before the bill is registered — and the lines keep whatever they carry.
  -- Zero means they charged nothing and says so, which is a statement the
  -- return should show.
  if p_tax_minor is not null then
    perform erp.state_supplier_tax(v_inv, p_tax_minor, p_tax_code,
                                   'billed from ' || rd.document_number);
  end if;

  if coalesce(p_register, true) then
    perform erp.transition_document(v_inv, 'register', 'billed from ' || rd.document_number);
  end if;

  return v_inv;
end;
$$;

comment on function erp.bill_from_receipt(uuid, text, date, date, boolean, bigint, text) is
  'Raises the supplier''s bill from a posted goods receipt, from what arrived '
  'rather than what somebody typed. Takes the tax the supplier charged and '
  'states it before registering, because the ledger reads the tax figure once, '
  'as it posts (20260922170000).';

-- The desk door, which had the same shape and the same gap.

drop function if exists public.erp_bill_from_receipt(uuid, text, date, date);

create or replace function public.erp_bill_from_receipt(
  p_receipt_id      uuid,
  p_their_reference text default null,
  p_invoice_date    date default null,
  p_due_date        date default null,
  p_tax_minor       bigint default null,
  p_tax_code        text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_id uuid;
begin
  v_id := erp.bill_from_receipt(p_receipt_id, p_their_reference, p_invoice_date,
                                p_due_date, true, p_tax_minor, p_tax_code);
  return (select jsonb_build_object(
                   'document_id', d.id, 'document_number', d.document_number,
                   'due_date', d.due_date,
                   'tax_minor', erp.document_tax_minor(d.id))
            from erp.document d where d.id = v_id);
end;
$$;

revoke all on function public.erp_bill_from_receipt(uuid, text, date, date, bigint, text)
  from public, anon;
grant execute on function public.erp_bill_from_receipt(uuid, text, date, date, bigint, text)
  to authenticated, service_role;

-- The write allowance and the help register key on the name, not the arguments,
-- so both still name this door. Restated rather than assumed, because a door
-- whose signature moved and whose rationale did not is a rationale describing
-- something else.
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_bill_from_receipt', 'erp.bill_from_receipt',
   'Raises the supplier''s bill from a posted goods receipt and states the tax they '
   'charged before registering it; authorises procurement.match, refuses an unposted '
   'receipt, and refuses to bill the same receipt twice.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Both halves against one fixture, because they are one claim: the tax a
-- supplier charged reaches the ledger, and there is no route by which it can be
-- written down after the ledger has stopped listening.
--
-- Its own fixture and not an extension of erp_test.supplier_tax_suite(), which
-- states tax on a bill raised by hand. The defect here is the one-button route,
-- so the fixture has to be an order, a receipt and the button.

create or replace function erp_test.input_tax_reaches_the_ledger_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  r        record; t record;
  v_cs     uuid;
  v_uom    uuid; v_site uuid; v_recv uuid; v_sup uuid; v_item uuid;
  v_po     uuid; v_pol uuid; v_pol2 uuid; v_grn uuid; v_grn2 uuid;
  v_bill   uuid; v_bill2 uuid;
  v_stated bigint; v_posted bigint; v_after bigint;
  v_state  text; v_refusal text; v_hint text;
  v_find   integer;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-itx-' || v_hex, 'Input tax suite',
    'admin@zz-itx-' || v_hex || '.test', 'Input Tax Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  v_cs := erp.configure_finance();            perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_inventory('average'); perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_procurement(1000000); perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_tax();                perform erp_test.promote_if_pending(v_cs);
  -- The purchase invoice lifecycle and the three-way match arrive with the
  -- procurement controls, and the bill this suite is about is a purchase invoice.
  v_cs := erp.configure_procurement_controls(); perform erp_test.promote_if_pending(v_cs);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (r.tenant_id, v_sup, 'supplier', 'active');
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'W', 'Widget', v_uom, 'active') returning id into v_item;

  -- Two order lines received separately, so the button can be pressed twice:
  -- once with the supplier's VAT and once without.
  v_po := erp.open_document('purchase_order', v_sup, null, v_site);
  v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'the line billed with VAT');
  v_pol2 := erp.add_document_line(v_po, v_item, 50, 1000, 'the line billed with none');
  perform erp.transition_document(v_po, 'submit', 'input tax suite');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po and tk.status = 'pending'
  loop perform erp.decide_approval_task(t.id, true, 'input tax suite'); end loop;
  if erp.object_current_state('document', v_po) = 'pending_approval' then
    perform erp.transition_document(v_po, 'approve', 'input tax suite');
  end if;
  perform erp.transition_document(v_po, 'send', 'input tax suite');

  v_grn := erp.open_document('goods_receipt', v_sup, r.entity_id, v_site);
  perform erp.receive_against(v_grn, v_pol, 100);
  perform erp.transition_document(v_grn, 'post', 'input tax suite');

  -- ── 1. The one-button route states the tax and the ledger carries it ──────
  v_cases := v_cases + 1;
  v_bill := erp.bill_from_receipt(v_grn, 'SUP-INV-1', current_date, current_date + 30,
                                  true, 20000, 'S');
  v_stated := erp.document_tax_minor(v_bill);
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_posted
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
   where j.tenant_id = r.tenant_id and j.document_id = v_bill and a.control_kind = 'tax';
  case_name := 'the button that bills a receipt carries the tax the supplier charged, and the ledger carries the same figure';
  passed := v_stated = 20000 and v_posted = 20000;
  detail := format('%s stated on the bill, %s debited to a tax control account', v_stated, v_posted);
  return next;

  -- ── 2. And the return and the ledger agree ────────────────────────────────
  -- The report that says otherwise, asked directly. Before this node the
  -- one-button route could not state tax at all, so the only way to get VAT
  -- onto the bill was after it had posted — which is precisely this finding.
  v_cases := v_cases + 1;
  select count(*) into v_find from erp.tax_outside_the_ledger_report() tl
   where tl.finding like 'the tax on a posted document%';
  case_name := 'and nothing is left outside the ledger: the return and the accounts say one figure';
  passed := v_find = 0;
  detail := format('%s finding(s) that a posted document''s tax is not its journal''s', v_find);
  return next;

  -- ── 3. And it cannot be restated once the bill has posted ─────────────────
  v_cases := v_cases + 1;
  v_refusal := null; v_hint := null;
  begin
    perform erp.state_supplier_tax(v_bill, 31000, 'S', 'they sent a second invoice');
  exception when others then
    v_refusal := sqlerrm;
    get stacked diagnostics v_hint = pg_exception_hint;
  end;
  case_name := 'stating the tax again once the bill has posted is refused, because the ledger has stopped listening';
  passed := v_refusal like 'CLOVEERP_TAX_AFTER_THE_LEDGER%'
        and v_hint is not null
        and exists (select 1 from erp_ref.refusal f
                     where f.code = 'CLOVEERP_TAX_AFTER_THE_LEDGER');
  detail := coalesce(left(v_refusal, 130), 'it was restated after posting');
  return next;

  -- ── 4. And the refusal left the figure alone ──────────────────────────────
  -- A guard that refuses and half-writes is worse than no guard: the bill would
  -- carry a figure nobody could account for.
  v_cases := v_cases + 1;
  v_after := erp.document_tax_minor(v_bill);
  case_name := 'and the refusal changed nothing: the bill still carries the figure the ledger has';
  passed := v_after = 20000;
  detail := format('the bill carries %s and the ledger %s', v_after, v_posted);
  return next;

  -- ── 5. A supplier who charged none is billed with none ────────────────────
  -- The other half of the claim. Passing null is not passing zero: it means the
  -- figure is not being stated here, and the lines keep what they carry, which
  -- for a bill raised from a receipt is nothing.
  v_cases := v_cases + 1;
  v_grn2 := erp.open_document('goods_receipt', v_sup, r.entity_id, v_site);
  perform erp.receive_against(v_grn2, v_pol2, 50);
  perform erp.transition_document(v_grn2, 'post', 'input tax suite');
  v_bill2 := erp.bill_from_receipt(v_grn2, 'SUP-INV-2', current_date, current_date + 30, true);
  v_state := erp.object_current_state('document', v_bill2);
  select count(*) into v_find from erp.tax_outside_the_ledger_report() tl
   where tl.finding like 'the tax on a posted document%';
  case_name := 'a bill raised without a tax figure carries none and still leaves the ledger and the return agreeing';
  passed := erp.document_tax_minor(v_bill2) = 0 and v_state in ('registered', 'disputed')
        and v_find = 0;
  detail := format('the second bill is %s carrying %s of tax, with %s finding(s)',
                   v_state, erp.document_tax_minor(v_bill2), v_find);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 6. Undone ─────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-itx-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its order, its receipts and its bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_INPUT_TAX_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_fixture, 'a case was added or lost');
  end if;
end;
$$;

create or replace function erp_test.assert_input_tax_reaches_the_ledger_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ')
           filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.input_tax_reaches_the_ledger_suite() s;

  if v_total <> 6 then
    raise exception 'CLOVEERP_INPUT_TAX_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_INPUT_TAX_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Input tax on the VAT return that the ledger has no record of is a figure somebody files.';
  end if;
end;
$$;

comment on function erp_test.input_tax_reaches_the_ledger_suite() is
  'The tax a supplier charged reaches the ledger on the one-button route, and cannot be written down after the ledger has stopped listening.';

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
