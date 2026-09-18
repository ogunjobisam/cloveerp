-- The tax point is the issue, not the payment.
--
-- 20260919200000 made cash settle the invoice it pays. That is the first thing
-- in the product ever to move a sales invoice into a second committed state:
-- issued is committed, paid is committed, and until now nothing drove the step
-- between them. The build found what had been waiting there.
--
-- ── What was waiting ─────────────────────────────────────────────────────────
--
-- erp.determine_tax_on_commit() is an after-update trigger on erp.object_state
-- (20260916030000). It fires on every entry into a committed state and calls
-- erp.determine_document_tax(), whose own comment says:
--
--     Once per line. A sales order passes through three committed states and an
--     invoice may reach more than one; the second visit finds every line
--     already determined and writes nothing.
--
-- That is true of a line that WAS determined. It is not true of a line that was
-- not. erp.determine_document_tax() determines every line with no determination
-- against it, and it gates on two conditions read at the time it runs:
--
--     erp.tax_rules_in_force(entity, document_date)
--     erp.entity_is_tax_registered(entity, document_date)   (20260916090000)
--
-- Both are dated registers, and both can come to cover a date after that date
-- has passed. A company registers for VAT and the registration is recorded with
-- a valid_from that reaches back; a legislation pack is bound with an effective
-- date behind it. An invoice issued before either was true carries no tax, its
-- journal carries no tax, and its receivable is the net the customer owes.
--
-- Then the customer pays it. Before 20260919200000 that was the end of it —
-- nothing moved the document, so the trigger never fired again. Now the
-- document settles, the trigger fires a second time, and this time the gates
-- open: the lines are determined, erp.tax_determination gains rows nobody
-- charged, and the tax return claims output tax against an invoice whose ledger
-- carries none and whose customer paid the net.
--
-- erp_test.tax_reaches_the_ledger_suite() caught it on the first build, through
-- erp.tax_outside_the_ledger_report(), which exists for exactly this: the
-- return and the ledger are two accounts of one tax and that report is what
-- holds them to each other. The suite was right. It is not edited here.
--
-- ── The decision ─────────────────────────────────────────────────────────────
--
-- A supply's tax point is when it is supplied, and for an invoice that is when
-- it is issued. The trigger's own comment has said so since the day it was
-- written — "a draft invoice is not a supply and an issued one is, and the tax
-- point is the issue" — and the body did not enforce it. It does now: the
-- determination is made on the FIRST entry into a committed state and on no
-- later one. The state before the move is read, exactly as
-- erp.transition_document() reads it to meter documents_posted once rather than
-- at every committed state after.
--
-- What that means where the gates were shut at the tax point: nothing. The
-- invoice was not taxed, is not taxed, and the customer owes what the invoice
-- says. If an organisation genuinely needs a back book determined after
-- registering, erp.determine_document_tax() is still there to be called
-- deliberately, by a person, on the documents they name — which is a different
-- act from a payment silently re-deciding what a supply was worth.
--
-- ── What this does not change ────────────────────────────────────────────────
--
-- A sales order passes through three committed states and determined nothing at
-- any of them: erp.determine_document_tax() returns 0 for every base type that
-- is not an invoice or a credit. A purchase invoice registered, disputed and
-- registered again still determines on the way back in, because disputed is not
-- a committed state and the return to registered is therefore a first
-- commitment again — and it determines nothing regardless, because the trade
-- side is a purchase. The only transition in the product this silences is the
-- one 20260919200000 introduced, which is the point.
--
-- No history is restated. Determinations already written stay written; this
-- stops new ones being made at a payment, and makes none retrospectively.
--
-- ── Collateral ───────────────────────────────────────────────────────────────
--
-- One migration, one suite, one catalogue check. No existing suite's figures
-- move: erp_test.tax_reaches_the_ledger_suite() goes back to 9/9 with the body
-- it already has, which is the evidence that this fixes the defect rather than
-- agreeing with it.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The live body this migration restates
-- ═════════════════════════════════════════════════════════════════════════════

do $anchor$
declare
  v_def  text := pg_catalog.pg_get_functiondef('erp.determine_tax_on_commit()'::regprocedure);
  v_hits integer;
  v_anchor text;
begin
  foreach v_anchor in array array[
    'perform erp.determine_document_tax(new.object_id);',
    'if not coalesce(v_committed, false) then',
    'from erp.state s where s.id = new.current_state_id;'
  ] loop
    v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_TAX_COMMIT_TRIGGER_UNRECOGNISED: erp.determine_tax_on_commit() carries "%" % time(s), not once', v_anchor, v_hits
        using hint = 'Read the live body with pg_get_functiondef and write the restatement against it under a new migration version.';
    end if;
  end loop;

  -- And it must not already read the state it came from, or this would be
  -- adding the same gate twice.
  if position('old.current_state_id' in v_def) > 0 then
    raise exception 'CLOVEERP_TAX_COMMIT_TRIGGER_UNRECOGNISED: erp.determine_tax_on_commit() already reads the state it came from'
      using hint = 'The first-commitment gate is already in the body; this migration would add it twice.';
  end if;
end
$anchor$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Determined once, at the first commitment
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.determine_tax_on_commit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_committed boolean;
  v_was       boolean;
begin
  select s.is_committed into v_committed
    from erp.state s where s.id = new.current_state_id;
  if not coalesce(v_committed, false) then
    return null;
  end if;

  -- The tax point is the first commitment and nothing after it. A document that
  -- was already committed has been supplied, and what it was taxed at was
  -- decided then: re-asking at a later committed state asks the dated registers
  -- again, and a registration or a rule set that has since come to cover the
  -- document's date would tax a supply nobody charged tax on. Read the same way
  -- erp.transition_document() reads it to meter a document once (20260919910000).
  select s.is_committed into v_was
    from erp.state s where s.id = old.current_state_id;
  if coalesce(v_was, false) then
    return null;
  end if;

  perform erp.determine_document_tax(new.object_id);
  return null;
end;
$$;

revoke all on function erp.determine_tax_on_commit() from public, anon, authenticated;

comment on function erp.determine_tax_on_commit is
  'Determines a document''s tax the moment it FIRST enters a committed state. A '
  'draft invoice is not a supply and an issued one is, and the tax point is the '
  'issue — not a payment that happens to move the document again. A line left '
  'undetermined at the tax point stays undetermined, because the registers the '
  'determination reads are dated and can come to cover a date that has passed '
  '(20260919910000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.tax_point_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_ccy char(3); v_item uuid;
  v_early uuid; v_late uuid;
  v_cust_a uuid; v_cust_b uuid;
  v_gross_a bigint; v_gross_b bigint;
  v_td_a integer; v_td_b integer; v_td_b2 integer;
  v_tax_cr bigint; v_owed bigint;
  v_s1 text; v_s2 text;
  v_findings integer;
begin
  begin
    v_step := 'an organisation that charges tax, with two customers of its own';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zztax-' || v_tag, 'Tax Point Suite',
      'admin@zztax-' || v_tag || '.test', 'Tax Point Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zztax-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select i.id into v_item from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active'::erp.record_status order by i.code limit 1;

    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZTPA', 'Tax Point Customer A', 'active') returning id into v_cust_a;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust_a, 'customer', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZTPB', 'Tax Point Customer B', 'active') returning id into v_cust_b;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust_b, 'customer', 'active');

    -- ── 1. An invoice issued before the registration charges nothing ────────
    v_step := 'an invoice issued while the company holds no tax registration';
    delete from erp.entity_tax_registration etr where etr.tenant_id = rb.tenant_id;
    v_early := erp.create_document('sales_invoice', v_entity, v_site, v_cust_a,
                                   current_date, v_ccy, 'ZTP-EARLY', '{}'::jsonb);
    perform erp.add_document_line(v_early, v_item, 1, 10000, 'a supply by a company that was not registered');
    perform erp.transition_document(v_early, 'issue', 'tax point suite');
    select dv.gross_minor::bigint into v_gross_a from erp.document_view dv where dv.id = v_early;
    select count(*) into v_td_a from erp.tax_determination td
     where td.tenant_id = rb.tenant_id and td.document_id = v_early;

    v_cases := v_cases + 1;
    case_name := 'an invoice issued before the company was registered charges no tax, and its receivable is the net';
    passed := v_state is null and v_td_a = 0 and v_gross_a = 10000
          and erp.document_tax_minor(v_early) = 0;
    detail := coalesce(v_state, format('%s determination(s), gross %s, tax %s',
                                       v_td_a, v_gross_a, erp.document_tax_minor(v_early)));
    return next;

    -- ── 2. The registration arrives, backdated, and the customer pays ───────
    -- This is the shape the defect needed: a dated register that comes to cover
    -- a date already passed. A company registering for VAT is recorded with a
    -- valid_from that reaches back, and every invoice issued before the record
    -- existed is then inside it.
    v_step := 'the registration recorded afterwards, reaching back past the invoice';
    insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction,
                                             registration_type, registration_number, valid_from)
    select rb.tenant_id, e.id, coalesce(e.country_code, 'GB'), 'VAT', 'GB987654321', current_date - 400
      from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active'::erp.record_status;

    perform erp.apply_cash(v_cust_a, v_gross_a, v_ccy, 'ZTP-RECEIPT-A', current_date);
    v_s1 := erp.object_current_state('document', v_early);
    select count(*) into v_td_a from erp.tax_determination td
     where td.tenant_id = rb.tenant_id and td.document_id = v_early;
    select coalesce(sum(b.outstanding_minor), 0) into v_owed
      from erp.ageing_balance b
     where b.tenant_id = rb.tenant_id and b.document_id = v_early;

    v_cases := v_cases + 1;
    case_name := 'paying it settles it and taxes nothing: the tax point was the issue, and a registration recorded afterwards does not reach back through a receipt';
    passed := v_state is null and v_s1 = 'paid' and v_td_a = 0 and v_owed = 0
          and erp.document_tax_minor(v_early) = 0;
    detail := coalesce(v_state, format('the invoice is %s with %s determination(s), tax %s, owing %s',
                                       v_s1, v_td_a, erp.document_tax_minor(v_early), v_owed));
    return next;

    -- ── 3. And the return still agrees with the ledger ──────────────────────
    select count(*) into v_findings
      from erp.tax_outside_the_ledger_report() tl
     where tl.finding like 'the tax on a posted document%';

    v_cases := v_cases + 1;
    case_name := 'and the return agrees with the ledger: no posted document carries determined tax its journal does not';
    passed := v_state is null and v_findings = 0;
    detail := coalesce(v_state, coalesce(
      (select string_agg(tl.reference || ': ' || tl.detail, '; ')
         from erp.tax_outside_the_ledger_report() tl
        where tl.finding like 'the tax on a posted document%'),
      'nothing outside the ledger'));
    return next;

    -- ── 4. An invoice issued while registered is taxed, once ────────────────
    v_step := 'an invoice issued while the company is registered';
    v_late := erp.create_document('sales_invoice', v_entity, v_site, v_cust_b,
                                  current_date, v_ccy, 'ZTP-LATE', '{}'::jsonb);
    perform erp.add_document_line(v_late, v_item, 1, 10000, 'a supply by a registered company');
    perform erp.transition_document(v_late, 'issue', 'tax point suite');
    select dv.gross_minor::bigint into v_gross_b from erp.document_view dv where dv.id = v_late;
    select count(*) into v_td_b from erp.tax_determination td
     where td.tenant_id = rb.tenant_id and td.document_id = v_late;
    select coalesce(sum(jl.credit_minor - jl.debit_minor), 0)::bigint into v_tax_cr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_late and a.control_kind = 'tax';

    v_cases := v_cases + 1;
    case_name := 'an invoice issued while the company is registered is taxed at the issue, and its journal carries what it determined';
    passed := v_state is null and v_td_b = 1 and v_gross_b > 10000
          and v_tax_cr = erp.document_tax_minor(v_late) and v_tax_cr > 0;
    detail := coalesce(v_state, format('%s determination(s), gross %s, %s on the tax control account',
                                       v_td_b, v_gross_b, v_tax_cr));
    return next;

    -- ── 5. And settling it does not determine it again ──────────────────────
    v_step := 'the receipt that settles the taxed invoice';
    perform erp.apply_cash(v_cust_b, v_gross_b, v_ccy, 'ZTP-RECEIPT-B', current_date);
    v_s2 := erp.object_current_state('document', v_late);
    select count(*) into v_td_b2 from erp.tax_determination td
     where td.tenant_id = rb.tenant_id and td.document_id = v_late;
    select count(*) into v_findings
      from erp.tax_outside_the_ledger_report() tl
     where tl.finding like 'the tax on a posted document%';

    v_cases := v_cases + 1;
    case_name := 'and settling it determines nothing a second time: one supply, one tax point, one determination';
    passed := v_state is null and v_s2 = 'paid' and v_td_b2 = v_td_b and v_findings = 0;
    detail := coalesce(v_state, format('the invoice is %s with %s determination(s), was %s; %s finding(s)',
                                       v_s2, v_td_b2, v_td_b, v_findings));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zztax-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zztax rolled back with its invoices, its registration and its receipts');
  return next;

  -- The count guard says what stopped the fixture. Without it the wrapper never
  -- sees a row, the message this suite caught into v_state never reaches the
  -- build log, and every break costs a run to find.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_TAX_POINT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.tax_point_suite() from public, anon;

create or replace function erp_test.assert_tax_point_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 6;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _tax_point on commit drop as
    select * from erp_test.tax_point_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _tax_point;
  drop table _tax_point;
  if v_fail > 0 then
    raise exception E'CLOVEERP_TAX_POINT_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_TAX_POINT_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('the tax point is the issue: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_tax_point_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the checks that read what changed
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
select erp.assert_no_dead_configuration();

select erp_test.assert_tax_point_suite();
-- The suite that caught this, with the body it already has: it goes back to
-- 9/9 because the defect is gone, not because the suite was changed.
select erp_test.assert_tax_reaches_the_ledger_suite();
-- And the two that carry tax through the ledger either side of it.
select erp_test.assert_invoice_tax_suite();
select erp_test.assert_supplier_tax_suite();
-- The change that exposed it, still holding.
select erp_test.assert_cash_settlement_suite();
