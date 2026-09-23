set lock_timeout = '30s';

-- =============================================================================
-- 20260923500000  An invoice is issued in one press
-- -----------------------------------------------------------------------------
-- PR5, M2: node S6 of docs/spec/simplification-review.md.
--
-- Issuing one sales invoice took two presses, both labelled "issue", on two
-- paths that did not know about each other: the lifecycle's Issue, which
-- moved the invoice to Issued and posted it, and "Issue the invoice", which
-- numbered it and filed its PDF. Either could come first, so an invoice could
-- be numbered as a draft (its contract frozen before tax was determined at
-- commit) or posted with no number. And nobody could press the second at all:
-- it refuses an invoice with no tax point of its own, and nothing but a test
-- could record one.
--
-- Now:
--
--   * erp.set_invoice_tax_point() records the tax point, through a public
--     door, until the invoice carries a number.
--   * erp.issue_sales_invoice() makes the lifecycle's Issue move first when
--     the invoice is a draft, so tax is determined and the ledger posted
--     before the contract is frozen, then numbers it, in one transaction.
--     An invoice already Issued and never numbered is numbered as before.
--   * The screen's "Issue the invoice" is the one press: it records the tax
--     point it is given and issues. The bare lifecycle Issue is the door's.
--
-- The spec's third routine, erp.mark_document_issue_sent(), is not a
-- decision: it records that the filed PDF reached the customer, and belongs
-- to whatever delivers it. Nothing does yet; that is recorded as open, not
-- built here.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The tax point, recorded
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.set_invoice_tax_point(p_document_id uuid, p_tax_point date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_state  text;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;
  -- A sales invoice: an invoice_reference document on the sales invoice's
  -- own lifecycle, as erp.document_is_purchase_bill() tells a supplier's.
  select dt.base_type_code || '/' || coalesce(dt.state_machine_code, '') into v_base
    from erp.document_type dt where dt.tenant_id = v_tenant and dt.id = d.document_type_id;
  if v_base is distinct from 'invoice_reference/sales_invoice' then
    raise exception 'CLOVEERP_NOT_A_SALES_INVOICE: % is not a sales invoice', coalesce(d.document_number, p_document_id::text)
      using errcode = '23514',
            hint = 'A tax point is recorded on the sales invoice it belongs to.';
  end if;

  perform erp.authorise('document.issue', d.entity_id, d.site_id, null, 'document', p_document_id);

  if p_tax_point is null then
    raise exception 'CLOVEERP_INVOICE_TAX_POINT_MISSING: Tax point is missing on this invoice'
      using errcode = '23514',
            hint = 'State the date of supply, or the date of the invoice if it is issued within fourteen days of it.';
  end if;

  -- Not a day that has not happened (found on review), and not a day on the
  -- other side of a change in VAT registration from the invoice's own date:
  -- the contract reads registration on the tax point, and tax and posting
  -- read the invoice date, so the two must agree on whether VAT is charged.
  if p_tax_point > current_date then
    raise exception 'CLOVEERP_TAX_POINT_IN_FUTURE: % is after today', p_tax_point
      using errcode = '23514',
            hint = 'A tax point is the date of supply, or the invoice date when it is issued within fourteen days of it. Neither is in the future.';
  end if;
  if exists (
       select 1 from erp.entity_tax_registration g
        where g.tenant_id = v_tenant and g.entity_id = d.entity_id
          and upper(g.registration_type) like 'VAT%'
          and g.valid_from <= p_tax_point and (g.valid_to is null or g.valid_to >= p_tax_point))
     is distinct from exists (
       select 1 from erp.entity_tax_registration g
        where g.tenant_id = v_tenant and g.entity_id = d.entity_id
          and upper(g.registration_type) like 'VAT%'
          and g.valid_from <= coalesce(d.posting_date, d.document_date)
          and (g.valid_to is null or g.valid_to >= coalesce(d.posting_date, d.document_date))) then
    raise exception 'CLOVEERP_TAX_POINT_ACROSS_REGISTRATION: on % the company''s VAT registration is not what it is on the invoice date', p_tax_point
      using errcode = '23514',
            hint = 'Date the invoice within the same VAT registration as its tax point, or raise it again on the right date.';
  end if;

  -- Once the invoice carries a number its contract is frozen with the tax
  -- point in it; changing it is an amendment, and amending goes through the
  -- issue it changes.
  if exists (select 1 from erp.document_issue di
              where di.tenant_id = v_tenant and di.source_document_id = p_document_id
                and di.status in ('reserved', 'issued', 'sent')) then
    raise exception 'CLOVEERP_ALREADY_ISSUED: this invoice already carries an issued number'
      using errcode = '23505';
  end if;

  v_state := erp.object_current_state('document', p_document_id);
  if coalesce(v_state, 'draft') not in ('draft', 'issued') then
    raise exception 'CLOVEERP_INVOICE_NOT_ISSUABLE: % is %', coalesce(d.document_number, p_document_id::text), v_state
      using errcode = '23514',
            hint = 'Only an invoice being written, or issued and not yet numbered, is issued. A cancelled invoice issues nothing; raise a new one.';
  end if;

  update erp.document set tax_point = p_tax_point, updated_at = now()
   where tenant_id = v_tenant and id = p_document_id;

  return jsonb_build_object('document_id', p_document_id, 'tax_point', p_tax_point);
end $$;

comment on function erp.set_invoice_tax_point(uuid, date) is
  'Records a sales invoice''s own tax point (20260923500000), under document.issue, '
  'until the invoice carries a number. erp.validate_sales_invoice_issue() refuses '
  'to issue without one.';

create or replace function public.erp_set_invoice_tax_point(p_document_id uuid, p_tax_point date)
returns jsonb
language sql
set search_path = ''
as $$ select erp.set_invoice_tax_point(p_document_id, p_tax_point) $$;

revoke all on function public.erp_set_invoice_tax_point(uuid, date) from public, anon;
grant execute on function public.erp_set_invoice_tax_point(uuid, date) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_invoice_tax_point', 'erp.set_invoice_tax_point',
   'Records a sales invoice''s own tax point before it is issued; authorises document.issue at '
   'the invoice''s entity and site, refuses a document that is not a sales invoice, a date in the '
   'future or on the other side of a change in VAT registration from the invoice date, and any '
   'invoice that already carries a number.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. Issued, then numbered, in one transaction
-- ─────────────────────────────────────────────────────────────────────────────

do $issue$
declare
  v_sig constant text := 'erp.issue_sales_invoice(uuid,uuid,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_ver      integer;
begin
  perform erp.authorise('document.issue', null, null, null, 'document', p_document_id);
$o$;
  b1 constant text := $n$  v_ver      integer;
  v_state    text;
  v_number   text;
begin
  -- At the invoice's own entity and site, now that this is the one issue
  -- door (found on review): a null scope matched a grant anywhere.
  perform erp.authorise('document.issue',
    (select x.entity_id from erp.document x where x.tenant_id = v_tenant and x.id = p_document_id),
    (select x.site_id from erp.document x where x.tenant_id = v_tenant and x.id = p_document_id),
    null, 'document', p_document_id);

  -- One press (20260923500000). A draft makes the lifecycle's Issue move
  -- first, so its tax is determined and the ledger posted before the
  -- contract is frozen; an invoice already Issued and never numbered is
  -- numbered as it stands. An amendment replaces the issue of an invoice
  -- that has already moved, and moves nothing.
  if p_replaces_issue_id is null then
    if not exists (select 1 from erp.document x
                     join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
                    where x.tenant_id = v_tenant and x.id = p_document_id
                      and dt.base_type_code = 'invoice_reference'
                      and dt.state_machine_code = 'sales_invoice') then
      raise exception 'CLOVEERP_NOT_A_SALES_INVOICE: % is not a sales invoice', p_document_id
        using errcode = '23514',
              hint = 'Only a sales invoice is issued with a number here. A supplier''s bill is registered.';
    end if;
    v_state := erp.object_current_state('document', p_document_id);
    if coalesce(v_state, 'draft') = 'draft' then
      if exists (select 1 from erp.document_issue di
                  where di.tenant_id = v_tenant and di.source_document_id = p_document_id
                    and di.status in ('reserved', 'issued', 'sent')) then
        raise exception 'CLOVEERP_ALREADY_ISSUED: this invoice already carries an issued number'
          using errcode = '23505';
      end if;
      perform erp.transition_document(p_document_id, 'issue', 'Issued with its number');
    elsif v_state <> 'issued' then
      select x.document_number into v_number from erp.document x
       where x.tenant_id = v_tenant and x.id = p_document_id;
      raise exception 'CLOVEERP_INVOICE_NOT_ISSUABLE: % is %', coalesce(v_number, p_document_id::text), v_state
        using errcode = '23514',
              hint = 'Only an invoice being written, or issued and not yet numbered, is issued. A cancelled invoice issues nothing; raise a new one.';
    end if;
  end if;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, a1, ''))) / length(a1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % head anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, a1, b1);
end
$issue$;

select erp.register_refusal('CLOVEERP_INVOICE_NOT_ISSUABLE',
  'Issuing, or stating the tax point of, a sales invoice that is neither being written nor issued and waiting for its number.',
  'Issuing gives the invoice its permanent number and files what the customer receives. A cancelled, paid or credited invoice has nothing left to issue, and a number spent on it would stand beside nothing.',
  'Raise a new invoice for what is owed, or reprint the one already issued.');

select erp.register_refusal('CLOVEERP_TAX_POINT_IN_FUTURE',
  'Stating a sales invoice''s tax point as a day that has not happened.',
  'The tax point says when the supply was made, and it places the VAT in a return. A date to come would put it in a return not yet open, for a supply the invoice says has happened.',
  'State the date of supply, or the invoice date if it is issued within fourteen days of it.');
select erp.register_refusal('CLOVEERP_TAX_POINT_ACROSS_REGISTRATION',
  'Stating a tax point on which the company''s VAT registration is not what it is on the invoice''s own date.',
  'The invoice is drawn up as registered or not on its tax point, and its VAT is charged and posted on its own date. Across a change in registration the two disagree, and the customer''s invoice would not say what the ledger holds.',
  'Date the invoice within the same VAT registration as its tax point, or raise it again on the right date.');
select erp.register_refusal('CLOVEERP_NOT_A_SALES_INVOICE',
  'Issuing, or stating the tax point of, a document that is not a sales invoice.',
  'The number and the tax point are what a sales invoice tells the customer and the VAT return. Put on anything else, a supplier''s bill included, they would be read by neither.',
  'Issue the sales invoice it belongs to. A supplier''s bill is registered, not issued.');

-- The words the one press adds to the screen.
insert into erp_ref.resource (key, locale, value, description)
values (erp_ref.ui_key('Tax point'), 'en', 'Tax point',
        'A screen string, rendered through ui(). The date field "Issue the invoice" asks for when the invoice has no tax point of its own (20260923500000).')
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The register: the lifecycle's Issue is the door's
--
-- Restated whole, from 20260923400000, with the sales invoice's Issue given to
-- erp.issue_sales_invoice(), so the register the screens are checked against
-- (src/lib/stage-records.test.ts) is the one the database holds.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_driver_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      -- Ordered because an order was raised from all of it (20260922360000).
      -- The routine's move takes its authority from that fact, whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only a move made by hand.
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      -- Approved with its requisition, by the conversion that raises it and
      -- by nothing else (20260922380000).
      ('purchase_order',     'inherit_approval',       'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000). The
      -- bill's close takes its authority from erp.order_is_settled(), whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only the close by hand.
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'routine', 'erp.issue_sales_invoice(uuid,uuid,uuid)'),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'screen', ''),
      ('transfer_order',     'in_transit',             'screen', ''),
      ('transfer_order',     'received',               'screen', ''),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),

      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'screen', ''),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which the inventory installer
      -- now ships identically. None of them is left to a door, so the document
      -- page draws every move each one declares.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- B2a. A draft is not asked for the VAT its issue determines
--
-- A line's VAT is determined as the invoice is committed
-- (erp.determine_tax_on_commit), so a draft's lines carry none, and the
-- readiness check refused every draft of a VAT-registered company on it: the
-- one press could never be pressed. The issue now commits the draft first and
-- validates after, so the line VAT a draft is asked for is the VAT that
-- determination could not find, and that is refused at the press, by line.
-- ─────────────────────────────────────────────────────────────────────────────

do $draft$
declare
  v_sig constant text := 'erp.validate_sales_invoice_issue(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_vatreg boolean;
begin
  v_c := erp.sales_invoice_contract(p_document_id);
$o$;
  b1 constant text := $n$  v_vatreg boolean;
  v_draft  boolean;
begin
  v_c := erp.sales_invoice_contract(p_document_id);
  -- Its VAT is determined as it is issued (20260923500000).
  v_draft := coalesce(erp.object_current_state('document', p_document_id), 'draft') = 'draft';
$n$;
  a2 constant text := $o$      if v_line ->> 'net_minor' is null or v_line ->> 'tax_rate_pct' is null then$o$;
  b2 constant text := $n$      if v_line ->> 'net_minor' is null or (v_line ->> 'tax_rate_pct' is null and not v_draft) then$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a1, b1), a2, b2);
end
$draft$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B4. The proof: erp_test.document_issue_suite gains four cases
--
-- Case 4 is restated for B2a. The new cases go before the case that reads as another organisation, so the session is still
-- this one's administrator. Twenty-six cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig constant text := 'erp_test.document_issue_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a1 constant text := $o$  v_path text; v_path2 text; v_foreign text; v_prev jsonb;
begin
$o$;
  b1 constant text := $n$  v_path text; v_path2 text; v_foreign text; v_prev jsonb;
  v_inv2 uuid; v_inv3 uuid; v_inv4 uuid; v_st text; v_logs integer; v_tax bigint;
begin
$n$;
  a2 constant text := $o$    -- 22 -----------------------------------------------------------------
$o$;
  b2 constant text := $n$    -- 22a (20260923500000) -------------------------------------------------
    -- One press: the draft of case 7 was moved to Issued by the issue that
    -- numbered it, and posted once.
    select count(*) into v_logs from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_inv
       and l.transition_code = 'issue';
    return query select 'issuing a draft invoice moves it to issued and posts it once, in the press that numbers it',
      erp.object_current_state('document', v_inv) = 'issued' and v_logs = 1
        and (select count(*) from erp.journal j
              where j.tenant_id = r.tenant_id and j.document_id = v_inv) = 1,
      format('state %s, %s issue move(s), %s journal(s)', erp.object_current_state('document', v_inv), v_logs,
             (select count(*) from erp.journal j where j.tenant_id = r.tenant_id and j.document_id = v_inv));

    -- 22b ----------------------------------------------------------------
    -- The tax point is recorded through its door, and issued with it; once
    -- the invoice carries a number the door refuses.
    v_inv2 := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv2, v_item, 1, 5000, 'a widget');
    update erp.document_line set tax_code = 'S', tax_rate_pct = 20, tax_minor = 1000
     where tenant_id = r.tenant_id and document_id = v_inv2;
    begin
      perform public.erp_set_invoice_tax_point(v_inv2, current_date + 1);
      v_st := 'tomorrow was accepted';
    exception when others then v_st := left(sqlerrm, 80); end;
    perform public.erp_set_invoice_tax_point(v_inv2, current_date - 3);
    res := erp.issue_sales_invoice(v_inv2);
    select di.contract_snapshot into v_c from erp.document_issue di
     where di.id = (res ->> 'document_issue_id')::uuid;
    begin
      perform public.erp_set_invoice_tax_point(v_inv2, current_date);
      v_msg := 'the tax point changed after the number';
    exception when others then v_msg := left(sqlerrm, 80); end;
    return query select 'the tax point is recorded through its door, never as a day to come, issued with the invoice, and fixed once it is numbered',
      v_st like 'CLOVEERP_TAX_POINT_IN_FUTURE:%'
        and (v_c -> 'header' ->> 'tax_point')::date = current_date - 3
        and (v_c -> 'header' ->> 'tax_point_is_explicit')::boolean
        and v_msg like 'CLOVEERP_ALREADY_ISSUED:%',
      format('tomorrow: %s; frozen tax point %s; again: %s', v_st, v_c -> 'header' ->> 'tax_point', v_msg);

    -- 22c ----------------------------------------------------------------
    -- Issued by the bare move and never numbered, as invoices were before
    -- this: it is numbered without moving a second time.
    v_inv3 := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv3, v_item, 1, 5000, 'a widget');
    update erp.document_line set tax_code = 'S', tax_rate_pct = 20, tax_minor = 1000
     where tenant_id = r.tenant_id and document_id = v_inv3;
    perform erp.transition_document(v_inv3, 'issue', 'issued by hand');
    perform erp.set_invoice_tax_point(v_inv3, current_date);
    res := erp.issue_sales_invoice(v_inv3);
    select count(*) into v_logs from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_inv3
       and l.transition_code = 'issue';
    return query select 'an invoice issued and never numbered is numbered without moving again',
      res ->> 'issued_number' is not null and v_logs = 1
        and erp.object_current_state('document', v_inv3) = 'issued'
        and (select count(*) from erp.journal j
              where j.tenant_id = r.tenant_id and j.document_id = v_inv3) = 1,
      format('%s; %s issue move(s)', res ->> 'issued_number', v_logs);

    -- 22d ----------------------------------------------------------------
    -- A cancelled invoice issues nothing, and spends no number.
    v_inv4 := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv4, v_item, 1, 5000, 'a widget');
    perform erp.transition_document(v_inv4, 'cancel', 'raised in error');
    select s.next_number into v_n1 from erp.document_sequence s
     where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice';
    begin
      perform erp.issue_sales_invoice(v_inv4);
      v_msg := 'a cancelled invoice was issued';
    exception when others then v_msg := left(sqlerrm, 80); end;
    return query select 'a cancelled invoice is refused by name and spends no number',
      v_msg like 'CLOVEERP_INVOICE_NOT_ISSUABLE:%'
        and (select s.next_number from erp.document_sequence s
              where s.tenant_id = r.tenant_id and s.document_kind = 'sales_invoice') = v_n1,
      v_msg;

    -- 22 -----------------------------------------------------------------
$n$;
  a4 constant text := $o$    v_v := erp.validate_sales_invoice_issue(v_inv);
    return query select 'a VAT invoice with a line carrying no VAT rate is refused by line',
      (v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb,
      left(v_v -> 'missing' #>> '{}', 90);
$o$;
  -- A draft's VAT is determined as it is issued (B2a), so the case reads an
  -- invoice committed with a line whose VAT is gone, and the draft beside it.
  b4 constant text := $n$    v_v := erp.validate_sales_invoice_issue(v_inv);
    v_inv4 := erp.open_document('sales_invoice', v_cust, r.entity_id, v_site);
    perform erp.add_document_line(v_inv4, v_item, 1, 5000, 'a widget');
    perform erp.transition_document(v_inv4, 'issue', 'committed for the case');
    update erp.document_line set tax_code = null, tax_rate_pct = null, tax_minor = null
     where tenant_id = r.tenant_id and document_id = v_inv4;
    v_prev := erp.validate_sales_invoice_issue(v_inv4);
    return query select 'a VAT invoice with a line carrying no VAT rate is refused by line, and a draft is not asked for the VAT its issue determines',
      (v_prev -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb
        and not ((v_v -> 'missing') @> '[{"refusal":"CLOVEERP_INVOICE_LINE_TAX_MISSING"}]'::jsonb),
      left(v_prev -> 'missing' #>> '{}', 90);
    v_inv4 := null; v_prev := null;
$n$;
  v_wsig constant text := 'erp_test.assert_document_issue_suite()';
  v_wdef text := pg_get_functiondef(v_wsig::regprocedure);
  a3 constant text := $o$  c_expected constant integer := 22;$o$;
  b3 constant text := $n$  c_expected constant integer := 26;$n$;
  n integer;
begin
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a4, ''))) / length(a4),
      (length(v_wdef) - length(replace(v_wdef, a3, ''))) / length(a3)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: document issue suite anchor found % time(s)', n;
    end if;
  end loop;
  execute replace(replace(replace(v_def, a1, b1), a2, b2), a4, b4);
  execute replace(v_wdef, a3, b3);
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
