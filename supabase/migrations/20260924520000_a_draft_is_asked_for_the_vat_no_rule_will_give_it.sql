set lock_timeout = '30s';

-- =============================================================================
-- 20260924520000  A draft is asked for the VAT no rule will give it
-- -----------------------------------------------------------------------------
-- Found on review of PR6 M4. A company registered for VAT, with no tax
-- configuration promoted, raises a draft sales invoice. Its readiness
-- (public.erp_sales_invoice_issue_readiness, over
-- erp.validate_sales_invoice_issue) lists the tax point and nothing else, so
-- the desk (src/lib/invoice-issue.ts, issuableInOnePress) draws the one-press
-- Issue. The press states the tax point, moves the draft to Issued, and
-- erp.issue_sales_invoice() refuses it: CLOVEERP_INVOICE_LINE_TAX_MISSING.
--
-- Why. 20260923500000 (PR5 M2, its B2a) stopped asking a draft for line VAT,
-- because a draft's lines carry none: the lifecycle's Issue determines it
-- (erp.determine_tax_on_commit, at the first commitment only since
-- 20260919910000), and the one press commits the draft before it validates.
-- That holds only where the determination has something to determine by.
-- erp.determine_document_tax() returns without a word when no tax rule is in
-- force on the invoice date, when the company is not registered on it, or
-- when the document cannot be told to be a sale; the lines stay without a
-- rate, and the validation after the commit refuses them. So the readiness
-- said yes to exactly the drafts the press would refuse. The suite said so
-- too: B2a's restatement of case 4 asserted it, in a fixture with no tax
-- configuration.
--
-- The decision. The issue already determines tax before it validates; that
-- is B2 of 20260923500000, and it stays. The refusal at the press is right:
-- nothing can give a line a rate that no rule gives it, and
-- erp.determine_tax() refuses to guess one. What was wrong is the readiness
-- answering for a determination it did not ask. Determining for real on a
-- draft to find out would write determinations before the tax point, which
-- 20260919910000 exists to prevent, and would make a read a writer. So:
--
--   * erp.document_tax_is_determinable() is the determination's own gates,
--     lifted out as 20260916090000 lifted erp.entity_is_tax_registered(), and
--     erp.determine_document_tax() now asks it rather than its own copy.
--   * erp.validate_sales_invoice_issue() asks it of a draft: a line with no
--     rate on a draft the determination will not reach is refused by line,
--     under the refusal the press raises for it.
--
-- One thing the readiness still cannot see: a rule set in force that no rule
-- in matches the supply. erp.determine_tax() refuses that at the press
-- (ERPWARE_TAX_UNDETERMINED). Both routes that install rules end in a
-- residual that matches everything (erp.configure_tax since 20260919840000,
-- and every legislation pack), so it is reached only by an organisation's own
-- rule set written without one.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. Whether the determination has anything to determine
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.document_tax_is_determinable(p_document_id uuid)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_on     date;
begin
  select * into d from erp.document
   where tenant_id = v_tenant and id = p_document_id;
  if not found or coalesce(d.is_cancelled, false) then
    return false;
  end if;

  select dt.base_type_code into v_base
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  -- A line is billable on an invoice or a credit, and nowhere earlier.
  if coalesce(v_base, '') not in ('invoice_reference', 'credit_reference') then
    return false;
  end if;

  -- Asked before the side, because an organisation that has configured no
  -- tax at all takes this exit on every transition. The date is
  -- erp.determine_tax()'s own, so the two cannot disagree.
  v_on := coalesce(d.document_date, current_date);

  if not erp.tax_rules_in_force(d.entity_id, v_on) then
    return false;
  end if;

  -- And registered to charge it. A rule set says what the rate would be;
  -- the registration says whether this company charges at all.
  if not erp.entity_is_tax_registered(d.entity_id, v_on) then
    return false;
  end if;

  -- Output tax only, until the report can tell output from input.
  if erp.document_trade_side(p_document_id) <> 'sale' then
    return false;
  end if;

  return true;
end $$;

revoke all on function erp.document_tax_is_determinable(uuid) from public, anon, authenticated;

comment on function erp.document_tax_is_determinable(uuid) is
  'Whether erp.determine_document_tax() determines a document at all: a sales '
  'invoice or credit, not cancelled, of a company with a tax rule in force and '
  'a VAT registration on the document date, that can be told to be a sale. '
  'The determination and the invoice''s readiness both ask it, so a draft is '
  'not called ready for VAT its issue will not find (20260924520000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The determination asks it
--
-- Needled, not re-emitted: 20260916090000 put the registration gate into the
-- body. Replaced whole, the three gates and the date they read, and the date
-- declared for them with it.
-- ─────────────────────────────────────────────────────────────────────────────

do $determine$
declare
  v_sig constant text := 'erp.determine_document_tax(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_on     date;
$o$;
  a2 constant text := $o$  -- Asked before the side, because today no organisation has configured tax at
  -- all and this is the early exit every transition takes.
  -- The date is erp.determine_tax()'s own, so the two cannot disagree.
  v_on := coalesce(d.document_date, current_date);

  if not erp.tax_rules_in_force(d.entity_id, v_on) then
    return 0;
  end if;

  -- And registered to charge it. A rule set says what the rate would be;
  -- the registration says whether this company charges at all.
  if not erp.entity_is_tax_registered(d.entity_id, v_on) then
    return 0;
  end if;

  -- Output tax only, until the report can tell output from input.
  if erp.document_trade_side(p_document_id) <> 'sale' then
    return 0;
  end if;
$o$;
  b2 constant text := $n$  -- Whether there is anything to determine by, on the document's date, for a
  -- company registered to charge it, on a sale. The invoice's readiness asks
  -- the same question, so the two cannot disagree about a draft
  -- (20260924520000).
  if not erp.document_tax_is_determinable(p_document_id) then
    return 0;
  end if;
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a1, ''), a2, b2);
end
$determine$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The readiness asks it of a draft
-- ─────────────────────────────────────────────────────────────────────────────

do $draft$
declare
  v_sig constant text := 'erp.validate_sales_invoice_issue(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_draft  boolean;
begin
$o$;
  b1 constant text := $n$  v_draft  boolean;
  v_found  boolean;
begin
$n$;
  a2 constant text := $o$  v_draft := coalesce(erp.object_current_state('document', p_document_id), 'draft') = 'draft';
$o$;
  b2 constant text := $n$  v_draft := coalesce(erp.object_current_state('document', p_document_id), 'draft') = 'draft';
  -- And only where its issue will find that VAT: the determination asks
  -- erp.document_tax_is_determinable() before it determines anything, and a
  -- line it leaves without a rate is refused at the press (20260924520000).
  v_found := v_draft and erp.document_tax_is_determinable(p_document_id);
$n$;
  a3 constant text := $o$      if v_line ->> 'net_minor' is null or (v_line ->> 'tax_rate_pct' is null and not v_draft) then
        v_bad := v_bad || jsonb_build_object(
          'field', format('Line %s net amount and VAT rate', v_line ->> 'line_no'),
          'refusal', 'CLOVEERP_INVOICE_LINE_TAX_MISSING');
      end if;
$o$;
  b3 constant text := $n$      if v_line ->> 'net_minor' is null or (v_line ->> 'tax_rate_pct' is null and not v_draft) then
        v_bad := v_bad || jsonb_build_object(
          'field', format('Line %s net amount and VAT rate', v_line ->> 'line_no'),
          'refusal', 'CLOVEERP_INVOICE_LINE_TAX_MISSING');
      elsif v_line ->> 'tax_rate_pct' is null and not v_found then
        v_bad := v_bad || jsonb_build_object(
          'field', format('Line %s VAT rate, which no tax rule in force gives it', v_line ->> 'line_no'),
          'refusal', 'CLOVEERP_INVOICE_LINE_TAX_MISSING');
      end if;
$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3);
end
$draft$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B4. The proof: erp_test.document_issue_suite
--
-- Case 4 is restated: in this fixture no tax rule is in force, so the draft
-- beside the committed invoice is asked for its line VAT as well. Two cases
-- go after 22d, before the case that reads as another organisation: the
-- review's draft, which readiness and the press now both refuse by line, and
-- the same draft once tax is set up, which both now let through. Twenty-eight
-- cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig constant text := 'erp_test.document_issue_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_inv2 uuid; v_inv3 uuid; v_inv4 uuid; v_st text; v_logs integer; v_tax bigint;
$o$;
  b1 constant text := $n$  v_inv2 uuid; v_inv3 uuid; v_inv4 uuid; v_st text; v_logs integer; v_tax bigint;
  v_inv5 uuid; cs3 uuid;
$n$;
  a2 constant text := $o$    return query select 'a VAT invoice with a line carrying no VAT rate is refused by line, and a draft is not asked for the VAT its issue determines',
      (v_prev -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb
        and not ((v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb),
      left(v_prev -> 'missing' #>> '{}', 90);
$o$;
  b2 constant text := $n$    -- The draft is asked too: no tax rule is in force in this fixture, so its
    -- issue would determine nothing and refuse it by line (20260924520000).
    -- Case 22f is a draft a rule covers.
    return query select 'a VAT invoice with a line carrying no VAT rate is refused by line, and so is a draft no tax rule in force will give one',
      (v_prev -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb
        and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb,
      format('committed: %s; draft: %s', left(v_prev -> 'missing' #>> '{}', 90), v_v -> 'missing' #>> '{}');
$n$;
  a3 constant text := $o$    -- 22 -----------------------------------------------------------------
$o$;
  b3 constant text := $n$    -- 22e (20260924520000) -------------------------------------------------
    -- The review of PR6 M4: a draft of a company registered for VAT, with no
    -- tax rule in force and its tax point stated. The readiness and the press
    -- refuse it by the same line, and no number is spent.
    v_inv5 := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv5, v_item, 1, 5000, 'a widget');
    perform erp.set_invoice_tax_point(v_inv5, current_date);
    v_v := erp.validate_sales_invoice_issue(v_inv5);
    select s.next_number into v_n1 from erp.document_sequence s
     where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice';
    begin
      perform erp.issue_sales_invoice(v_inv5);
      v_msg := 'a draft no tax rule covers was issued';
    exception when others then v_msg := left(sqlerrm, 80); end;
    return query select 'a draft that no tax rule in force covers is not ready, and the press refuses it by the same line',
      not (v_v ->> 'can_issue')::boolean
        and (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb
        and v_msg like 'CLOVEERP_INVOICE_LINE_TAX_MISSING:%'
        and coalesce(erp.object_current_state('document', v_inv5), 'draft') = 'draft'
        and (select s.next_number from erp.document_sequence s
              where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice') = v_n1,
      format('ready: %s; press: %s', v_v -> 'missing' #>> '{}', v_msg);

    -- 22f ----------------------------------------------------------------
    -- Tax set up and promoted: the same draft is ready, and the press
    -- determines its VAT as it issues it.
    cs3 := erp.configure_tax('GB', 20);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(cs3); perform erp.promote_change_set(cs3);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_v := erp.validate_sales_invoice_issue(v_inv5);
    begin
      res := erp.issue_sales_invoice(v_inv5);
      v_msg := res ->> 'issued_number';
    exception when others then res := null; v_msg := left(sqlerrm, 80); end;
    select l.tax_minor into v_tax from erp.document_line l
     where l.tenant_id = r.tenant_id and l.document_id = v_inv5 and l.tax_rate_pct = 20;
    return query select 'once a tax rule covers it, the same draft is ready and issues with the VAT its issue determines',
      (v_v ->> 'can_issue')::boolean
        and res ->> 'issued_number' is not null
        and v_tax = 1000
        and (select count(*) from erp.tax_determination td
              where td.tenant_id = r.tenant_id and td.document_id = v_inv5) = 1,
      format('ready: %s; press: %s; VAT %s', v_v -> 'missing' #>> '{}', v_msg, v_tax);

    -- 22 -----------------------------------------------------------------
$n$;
  v_wsig constant text := 'erp_test.assert_document_issue_suite()';
  v_wdef text := pg_get_functiondef(v_wsig::regprocedure);
  a4 constant text := $o$  c_expected constant integer := 26;$o$;
  b4 constant text := $n$  c_expected constant integer := 28;$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3),
      (length(v_wdef) - length(replace(v_wdef, a4, ''))) / length(a4)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: document issue suite anchor found % time(s)', n;
    end if;
  end loop;
  execute replace(replace(replace(v_def, a1, b1), a2, b2), a3, b3);
  execute replace(v_wdef, a4, b4);
end
$suite$;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
