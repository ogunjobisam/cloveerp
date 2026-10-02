set lock_timeout = '30s';

-- =============================================================================
-- 20261004970000  Landed cost comes from the bill
-- -----------------------------------------------------------------------------
-- Owner, 2 October 2026: landed cost (duty, brokerage, insurance, handling,
-- freight a forwarder bills) is capitalised from the bill that charges it, as
-- freight in already is (20261004955000), and what cannot be capitalised goes
-- to cost of sales. No new account.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- erp_allocate_landed_cost (20260829320000) added a charge to stock value
-- through erp.add_cost_to_stock() and posted nothing: stock would have risen
-- with no journal, and the stock-to-ledger tie would have broken the first time
-- anybody used it. Nobody could: no door wrote an erp.landed_cost row, so the
-- "Add delivery costs to the stock value" action offered on Procurement and in
-- the Finance module always listed nothing. Meanwhile landed cost is sold
-- (CAP-LANDED) and the product page names "landed cost and duty".
-- erp.add_cost_to_stock() also rounds per unit, so what it reported adding was
-- not always what it added.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. A landed cost bill: a document type on base type invoice_reference and
--      the supplier bill's own lifecycle (so the payment run, the dispute and
--      the VAT return read it as a supplier's bill), numbered LCB-, posting by
--      its own rule: the net to cost of sales, the tax to tax control, the
--      total to trade payable. Procurement controls version 8.
--   B. erp_bill_landed_cost(): a supplier's bill for a charge on a posted
--      receipt, raised and registered in one press (procurement.match). Its
--      erp.landed_cost row names the bill; a row with no bill is refused.
--   C. Registering it capitalises the charge onto the receipt's goods, by
--      value, through erp.add_freight_to_receipt_line(), which returns exactly
--      what the stock's value rose by. One journal, landed_cost.capitalised:
--      Dr inventory for exactly that, Cr cost of sales for the same. What
--      cannot land (goods already gone, standard cost, rounding) stays in cost
--      of sales, where the bill's rule put it. Once per bill.
--   D. The hand allocation is retired: erp_allocate_landed_cost and
--      erp.allocate_landed_cost are dropped, and the screens offer "Bill a
--      landed cost" in their place. erp_landed_costs lists the bills' charges,
--      what landed and what was expensed.
--
-- Proved by erp_test.landed_cost_suite; erp_test.procurement_controls_suite's
-- three landed cost cases now prove the hand route is gone.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The registers
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_LANDED_COST_RECEIPT_NOT_POSTED',
  'Billing a landed cost on something that is not a posted goods receipt.',
  'A landed cost is part of what goods cost, so it lands on goods that have been received and are on the books.',
  'Post the goods receipt first, then bill the charge against it.');

select erp.register_refusal('CLOVEERP_LANDED_COST_CHARGE_UNKNOWN',
  'Billing a landed cost of a kind the product does not know.',
  'Each kind is a cost of bringing goods in; anything else is an overhead and belongs on an ordinary bill.',
  'Choose duty, brokerage, insurance, handling, freight or other.');

select erp.register_refusal('CLOVEERP_LANDED_COST_AMOUNT_INVALID',
  'Billing a landed cost of nothing, or less than nothing.',
  'A charge that costs nothing adds nothing to the goods; a negative one is a credit note.',
  'Give the charge''s net amount before tax, or ask the supplier for a credit note.');

select erp.register_refusal('CLOVEERP_LANDED_COST_PARTY_NOT_A_SUPPLIER',
  'Billing a landed cost from a party the organisation does not buy from.',
  'A bill is owed to a supplier; the payment run, the VAT return and the ledger read it as a purchase only when the party is one.',
  'Give the broker, forwarder or customs authority a supplier role under Business partners, then bill the charge.');

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('document.landed_cost_bill', 'en', 'Landed cost bill', 'procurement', 'Document type name (20261004970000).'),
  ('document.landed_cost_bill', 'de', 'Rechnung für Bezugsnebenkosten', 'procurement', null),
  ('event.landed_cost.capitalised', 'en', 'Landed cost capitalised', 'finance',
   'Event raised when a supplier''s bill for a landed cost lands on the goods it was charged for.'),
  ('event.landed_cost.capitalised', 'de', 'Bezugsnebenkosten aktiviert', 'finance',
   'Ereignis, wenn die Rechnung eines Lieferanten für Bezugsnebenkosten auf die Waren gebucht wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('landed_cost.capitalised', 1, 'document', 'finance', 'event.landed_cost.capitalised',
        'A supplier''s bill for a landed cost landed on the goods it was charged for.',
        '{"type":"object","required":["reference","receipt","net_minor","capitalised_minor","expensed_minor"],"properties":{"reference":{"type":"string"},"receipt":{"type":"string"},"charge":{"type":"string"},"net_minor":{"type":"integer"},"capitalised_minor":{"type":"integer"},"expensed_minor":{"type":"integer"}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'landed_cost.capitalised' and et.is_current and et.version = 1
         and et.aggregate_type = 'document' and et.name_key = 'event.landed_cost.capitalised') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: landed_cost.capitalised is declared already, and not as 20261004970000 declares it';
  end if;
end
$event$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The landed cost bill, as configuration
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.landed_cost_bill_rule(p_by_purpose boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A supplier's bill for a landed cost (20261004970000): the net is a cost of
  -- the goods, the tax is input tax, the total is owed to the supplier. What of
  -- the net lands on goods still held moves to inventory as it registers
  -- (erp.capitalise_landed_cost); the rest stays a cost of sales. Named by
  -- purpose for the upgrade register, by the code in force for an install.
  select jsonb_build_object(
    'code', 'landed_cost_bill', 'name', 'Landed cost bill', 'ledger', 'GL',
    'event_type', 'document.landed_cost_bill.registered',
    'posting_lines', jsonb_build_array(
      jsonb_build_object(
        'account', case when p_by_purpose then jsonb_build_object('purpose', 'cost_of_sales')
                        else to_jsonb(erp.chart_account_code('cost_of_sales')) end,
        'side', 'debit', 'rate', 1, 'basis', 'document_value',
        'description', 'A cost of bringing the goods in, until it lands on them'),
      jsonb_build_object(
        'account', case when p_by_purpose then jsonb_build_object('purpose', 'tax_control')
                        else to_jsonb(erp.chart_account_code('tax_control')) end,
        'side', 'debit', 'rate', 1, 'basis', 'document_tax',
        'description', 'Tax the supplier charged'),
      jsonb_build_object(
        'account', case when p_by_purpose then jsonb_build_object('purpose', 'trade_payable')
                        else to_jsonb(erp.chart_account_code('trade_payable')) end,
        'side', 'credit', 'balancing', true,
        'description', 'Owed to the supplier')))
$$;

revoke all on function erp.landed_cost_bill_rule(boolean) from public, anon;

create or replace function erp.landed_cost_bill_pack_items(p_by_purpose boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What procurement controls version 8 adds (20261004970000), read by
  -- erp.configure_procurement_controls() for a new install and by the upgrade
  -- register for an organisation on version 7. The rule and the sequence
  -- before the type that names them, as the carrier bill's are.
  select jsonb_build_array(
    jsonb_build_object('kind', 'posting_rule', 'key', 'landed_cost_bill',
                       'payload', erp.landed_cost_bill_rule(p_by_purpose)),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'landed_cost_bill', 'payload',
      jsonb_build_object('code', 'landed_cost_bill', 'prefix', 'LCB-', 'pad_to', 6,
                         'next_value', 1, 'reset_period', 'never')),
    jsonb_build_object('kind', 'document_type', 'key', 'landed_cost_bill', 'payload',
      jsonb_build_object('code', 'landed_cost_bill', 'name', 'Landed cost bill',
                         'base_type', 'invoice_reference', 'state_machine', 'purchase_invoice',
                         'numbering_rule', 'landed_cost_bill', 'posting_rule', 'landed_cost_bill',
                         'create_permission', 'procurement.match')
      -- On an install, the company the supplier's bill belongs to: the
      -- supplier bill's own, as the carrier bill names it, or, where this pack
      -- is installing the supplier bill in the same press, the company its
      -- numbering is given (the first active one by code). A type with no
      -- company would bind every company, a gapless one included. The upgrade
      -- register cannot know a company.
      || case when p_by_purpose then '{}'::jsonb
              else coalesce((select jsonb_build_object('entity', e.code)
                               from erp.document_type dt
                               join erp.entity e on e.tenant_id = dt.tenant_id and e.id = dt.entity_id
                              where dt.tenant_id = erp.current_tenant_id()
                                and dt.code = 'purchase_invoice' and dt.status = 'active'
                              limit 1),
                            (select jsonb_build_object('entity', e.code) from erp.entity e
                              where e.tenant_id = erp.current_tenant_id() and e.status = 'active'
                              order by e.code limit 1),
                            '{}'::jsonb) end))
$$;

revoke all on function erp.landed_cost_bill_pack_items(boolean) from public, anon;

comment on function erp.landed_cost_bill_pack_items(boolean) is
  'The landed cost bill (20261004970000): its posting rule, numbering rule and document type, the items '
  'erp.configure_procurement_controls() and the procurement controls upgrade register both read.';

do $configure$
declare
  v_sig  constant text := 'erp.configure_procurement_controls(text,numeric,numeric,bigint)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      || erp.cash_payment_pack_items());$o$;
  v_new  constant text := $n$      || erp.cash_payment_pack_items()
      -- A supplier's bill for a landed cost, onto the goods (20261004970000).
      || erp.landed_cost_bill_pack_items());$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if strpos(v_def, 'landed_cost_bill_pack_items') > 0 then
    raise notice '% already installs the landed cost bill; left as it is', v_sig;
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % cash payment pack anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

update erp_ref.module_installer
   set current_version = 8,
       description = description
         || ' Version 8 (20261004970000): the landed cost bill, a supplier''s bill for duty, brokerage, '
         || 'insurance, handling or freight that lands on the goods it was charged for.'
 where install_code = 'procurement-controls' and current_version = 7;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'procurement-controls', 8, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       100 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.landed_cost_bill_pack_items(true)) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'procurement-controls') is distinct from 8 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the procurement controls installer is not at version 8';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'procurement-controls' and ui.to_version = 8) <> 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 8 of procurement controls is not the three items the landed cost bill ships';
  end if;
end
$register$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. A landed cost names its bill
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.landed_cost add column if not exists bill_document_id uuid;
alter table erp.landed_cost add column if not exists capitalised_minor bigint;

do $columns$
begin
  if not exists (select 1 from pg_constraint where conname = 'landed_cost_bill_fk') then
    alter table erp.landed_cost add constraint landed_cost_bill_fk
      foreign key (tenant_id, bill_document_id) references erp.document (tenant_id, id);
  end if;
  -- Not valid: a row written by the hand route before this keeps its place;
  -- every row from here on names the bill that charges it.
  if not exists (select 1 from pg_constraint where conname = 'landed_cost_names_its_bill') then
    alter table erp.landed_cost add constraint landed_cost_names_its_bill
      check (bill_document_id is not null) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'landed_cost_charge_known') then
    alter table erp.landed_cost add constraint landed_cost_charge_known
      check (charge_code in ('duty', 'brokerage', 'insurance', 'handling', 'freight', 'other')) not valid;
  end if;
end
$columns$;

create unique index if not exists landed_cost_one_per_bill on erp.landed_cost (tenant_id, bill_document_id)
  where bill_document_id is not null;

comment on column erp.landed_cost.bill_document_id is
  'The supplier''s bill that charges this landed cost; a landed cost comes from its bill (20261004970000).';
comment on column erp.landed_cost.capitalised_minor is
  'What of the charge landed on goods still held, exactly as the stock''s value rose; the rest stayed a '
  'cost of sales (20261004970000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. Registering the bill lands the charge on the goods
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.capitalise_landed_cost(p_bill uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  b         erp.document%rowtype;
  lc        erp.landed_cost%rowtype;
  v_grn     text;
  v_net     bigint;
  v_total   numeric;
  v_n       integer;
  v_i       integer := 0;
  r         record;
  v_share   bigint;
  v_spent   bigint := 0;
  v_applied bigint := 0;
  v_lines   jsonb := '[]'::jsonb;
  v_ledger  uuid;
  v_inv     uuid;
  v_cos     uuid;
  v_rule    uuid;
  v_version integer;
  v_event   uuid;
  v_journal uuid;
  v_date    date;
begin
  -- A supplier's bill for a landed cost, onto the goods it was charged for
  -- (20261004970000; owner: from the bill, the rest to cost of sales). Once
  -- per bill. The net its rule put in cost of sales moves to inventory by
  -- exactly what lands on goods still held.
  select x.* into b from erp.document x where x.tenant_id = v_tenant and x.id = p_bill;
  select x.* into lc from erp.landed_cost x where x.tenant_id = v_tenant and x.bill_document_id = p_bill
     for update;
  if b.id is null or lc.id is null or lc.allocated_at is not null then
    return null;
  end if;
  if exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = p_bill
                and j.source_code = 'landed_cost.capitalised') then
    return null;
  end if;

  v_net := erp.document_value_minor(p_bill);
  select x.document_number into v_grn from erp.document x where x.tenant_id = v_tenant and x.id = lc.receipt_document_id;
  v_date := coalesce(b.posting_date, b.document_date, current_date);

  -- The goods it was charged for: the receipt's lines, by value. The last line
  -- takes what rounding left, so the shares sum to the net.
  select coalesce(sum(l.quantity * l.unit_price_minor), 0), count(*) into v_total, v_n
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = lc.receipt_document_id and not l.is_cancelled
     and l.item_id is not null;
  if coalesce(v_net, 0) > 0 and coalesce(v_total, 0) > 0 then
    for r in
      select l.id, l.quantity * l.unit_price_minor as value
        from erp.document_line l
       where l.tenant_id = v_tenant and l.document_id = lc.receipt_document_id and not l.is_cancelled
         and l.item_id is not null
       order by l.line_no, l.id
    loop
      v_i := v_i + 1;
      v_share := case when v_i = v_n then v_net - v_spent else floor(v_net * r.value / v_total)::bigint end;
      v_spent := v_spent + v_share;
      v_lines := v_lines || jsonb_build_object('line_id', r.id, 'share_minor', v_share,
                                               'capitalised_minor', erp.add_freight_to_receipt_line(r.id, v_share));
    end loop;
    select coalesce(sum((x ->> 'capitalised_minor')::bigint), 0) into v_applied from jsonb_array_elements(v_lines) x;
  end if;

  v_event := erp.append_event('landed_cost.capitalised', 'document', p_bill,
    jsonb_build_object('reference', b.document_number, 'receipt', coalesce(v_grn, ''), 'charge', lc.charge_code,
                       'net_minor', coalesce(v_net, 0), 'capitalised_minor', v_applied,
                       'expensed_minor', coalesce(v_net, 0) - v_applied),
    b.entity_id, b.site_id);

  if v_applied > 0 then
    select lg.id into v_ledger from erp.ledger lg
     where lg.tenant_id = v_tenant and lg.entity_id = b.entity_id and lg.is_primary and lg.status = 'active';
    select a.id into v_inv from erp.account a where a.tenant_id = v_tenant and a.entity_id = b.entity_id
       and a.code = erp.chart_account_code('inventory') and a.status = 'active';
    select a.id into v_cos from erp.account a where a.tenant_id = v_tenant and a.entity_id = b.entity_id
       and a.code = erp.chart_account_code('cost_of_sales') and a.status = 'active';
    if v_ledger is null or v_inv is null or v_cos is null then
      raise exception 'CLOVEERP_ACCOUNT_NOT_ON_CHART: % lacks inventory or cost of sales to capitalise a landed cost',
        coalesce((select e.code from erp.entity e where e.id = b.entity_id), 'the company')
        using errcode = '23514',
              hint = 'Upgrade finance, which installs inventory and cost of sales.';
    end if;
    select pr.id, pr.version into v_rule, v_version from erp.posting_rule pr
     where pr.tenant_id = v_tenant and pr.code = 'landed_cost_bill' and pr.status = 'active'
     order by pr.version desc limit 1;

    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id, posting_date,
                             description, status, document_id)
    values (v_tenant, b.entity_id, v_ledger, 'landed_cost.capitalised', v_event, v_date,
            format('%s on %s, onto the goods it was charged for', initcap(lc.charge_code), coalesce(v_grn, 'a receipt')),
            'draft', p_bill)
    returning id into v_journal;

    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate,
                                  posting_rule_id, posting_rule_version, source_event_id, description)
    values (v_tenant, v_journal, 1, v_inv, v_applied, 0, b.currency, v_applied, 0, 1,
            v_rule, v_version, v_event, 'Landed cost, onto the stock it was charged for'),
           (v_tenant, v_journal, 2, v_cos, 0, v_applied, b.currency, 0, v_applied, 1,
            v_rule, v_version, v_event, 'Landed cost on stock still held is not yet a cost of sales');
    -- The inventory control carries its detail by item, as every stock posting does.
    insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,
                                    item_id, journal_id, currency, debit_minor, credit_minor, posting_date)
    select v_tenant, b.entity_id, v_ledger, a.control_kind, v_inv, l.item_id, v_journal, b.currency,
           sum((x ->> 'capitalised_minor')::bigint), 0, v_date
      from jsonb_array_elements(v_lines) x
      join erp.document_line l on l.id = (x ->> 'line_id')::uuid
      join erp.account a on a.id = v_inv
     where a.control_kind is not null and (x ->> 'capitalised_minor')::bigint > 0
     group by a.control_kind, l.item_id;

    update erp.journal set status = 'posted', posted_at = now(), posted_by = erp.current_principal_id()
     where id = v_journal;
  end if;

  update erp.landed_cost set allocated_at = now(), capitalised_minor = v_applied, updated_at = now()
   where id = lc.id;

  return jsonb_build_object('bill_id', p_bill, 'receipt', v_grn, 'charge', lc.charge_code,
                            'net_minor', coalesce(v_net, 0), 'capitalised_minor', v_applied,
                            'expensed_minor', coalesce(v_net, 0) - v_applied,
                            'journal_id', v_journal, 'lines', v_lines);
end;
$$;

revoke all on function erp.capitalise_landed_cost(uuid) from public, anon;

comment on function erp.capitalise_landed_cost(uuid) is
  'Moves a landed cost bill''s net from cost of sales onto the goods it was charged for: inventory for '
  'exactly what lands on stock still held, the rest left in cost of sales, once per bill (20261004970000).';

-- The hook, in erp.transition_document(), beside freight in's. Edited, not
-- rewritten: one anchor over the body 20261004955000 left (md5 6aa243f6…).

do $transition$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    perform erp.capitalise_inbound_freight(p_document_id);$o$;
  v_new  constant text := $n$    perform erp.capitalise_inbound_freight(p_document_id);
    -- And a supplier's bill for a landed cost, onto the goods it was charged
    -- for (20261004970000).
    perform erp.capitalise_landed_cost(p_document_id);$n$;
begin
  if strpos(v_src, '20261004970000') > 0 then
    raise notice '% already lands a landed cost; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6aa243f659a29e7582a9518b76f21de2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004970000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

-- ═════════════════════════════════════════════════════════════════════════════
-- E. Bill a landed cost
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.bill_landed_cost(
  p_receipt_id      uuid,
  p_party_id        uuid,
  p_charge          text,
  p_amount_minor    bigint,
  p_their_reference text   default null,
  p_tax_minor       bigint default null,
  p_tax_code        text   default null,
  p_invoice_date    date   default null,
  p_due_date        date   default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  rc       erp.document%rowtype;
  v_base   text;
  v_charge text := lower(btrim(coalesce(p_charge, '')));
  v_role   uuid;
  v_ccy    char(3);
  v_bill   uuid;
  v_date   date := coalesce(p_invoice_date, current_date);
  v_words  text;
begin
  -- A supplier's bill for a cost of bringing a receipt's goods in
  -- (20261004970000): raised against the receipt, in the company's own
  -- currency, and registered, which lands it on the goods.
  select x.* into rc from erp.document x where x.tenant_id = v_tenant and x.id = p_receipt_id;
  select dt.base_type_code into v_base from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = rc.document_type_id;
  perform erp.authorise('procurement.match', rc.entity_id, rc.site_id, null, 'document', rc.id);
  if rc.id is null or v_base is distinct from 'receipt' or coalesce(rc.is_cancelled, false)
     or not coalesce((select s.is_committed from erp.object_state os
                       join erp.state s on s.tenant_id = os.tenant_id and s.id = os.current_state_id
                      where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = rc.id), false) then
    raise exception 'CLOVEERP_LANDED_COST_RECEIPT_NOT_POSTED: % is not a posted goods receipt',
      coalesce(rc.document_number, coalesce(p_receipt_id::text, 'nothing'))
      using errcode = '23514', hint = 'Post the goods receipt first, then bill the charge against it.';
  end if;
  if v_charge not in ('duty', 'brokerage', 'insurance', 'handling', 'freight', 'other') then
    raise exception 'CLOVEERP_LANDED_COST_CHARGE_UNKNOWN: % is not a landed cost', coalesce(p_charge, 'nothing')
      using errcode = '22023', hint = 'Choose duty, brokerage, insurance, handling, freight or other.';
  end if;
  if coalesce(p_amount_minor, 0) <= 0 then
    raise exception 'CLOVEERP_LANDED_COST_AMOUNT_INVALID: a landed cost of % is not a charge', coalesce(p_amount_minor, 0)
      using errcode = '22023',
            hint = 'Give the charge''s net amount before tax, or ask the supplier for a credit note.';
  end if;
  select pr.id into v_role from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.party_id = p_party_id and pr.status = 'active'
     and pr.role_kind in ('supplier', 'carrier')
   order by (pr.role_kind = 'supplier') desc, pr.created_at
   limit 1;
  if v_role is null then
    raise exception 'CLOVEERP_LANDED_COST_PARTY_NOT_A_SUPPLIER: % is not a supplier of this organisation',
      coalesce((select p.name from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id), 'nobody')
      using errcode = '23514',
            hint = 'Give the broker, forwarder or customs authority a supplier role under Business partners, then bill the charge.';
  end if;

  select e.base_currency into v_ccy from erp.entity e where e.tenant_id = v_tenant and e.id = rc.entity_id;
  v_words := format('%s on %s', initcap(v_charge), rc.document_number);
  v_bill := erp.open_document('landed_cost_bill', p_party_id, rc.entity_id, rc.site_id,
                              p_their_reference, null, v_ccy);
  -- In the supplier's role, which is what makes it a purchase to
  -- erp.document_trade_side() and so to the tax and the VAT return.
  update erp.document
     set document_date = v_date,
         due_date = coalesce(p_due_date, v_date + 30),
         notes = coalesce(notes, v_words),
         party_role_id = v_role,
         updated_at = now()
   where id = v_bill;
  perform erp.add_document_line(v_bill, null, 1, p_amount_minor, v_words);

  insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
  values (v_tenant, v_bill, rc.id, 'invoices');

  if p_tax_minor is not null then
    perform erp.state_supplier_tax(v_bill, p_tax_minor, coalesce(p_tax_code, 'S'), lower(v_words));
  end if;

  insert into erp.landed_cost (tenant_id, receipt_document_id, charge_code, description, amount_minor,
                               currency, allocation_basis, supplier_party_id, bill_document_id)
  values (v_tenant, rc.id, v_charge, v_words, p_amount_minor, v_ccy, 'value', p_party_id, v_bill);

  perform erp.transition_document(v_bill, 'register', lower(v_words));
  return v_bill;
end;
$$;

revoke all on function erp.bill_landed_cost(uuid, uuid, text, bigint, text, bigint, text, date, date) from public, anon;

comment on function erp.bill_landed_cost(uuid, uuid, text, bigint, text, bigint, text, date, date) is
  'Bill a landed cost (20261004970000): a supplier''s bill for duty, brokerage, insurance, handling, freight '
  'or other on a posted goods receipt, raised in the company''s currency and registered, which lands it on '
  'the goods. Authorises procurement.match at the receipt''s site.';

create or replace function public.erp_bill_landed_cost(
  p_receipt_id      uuid,
  p_party_id        uuid,
  p_charge          text,
  p_amount_minor    bigint,
  p_their_reference text   default null,
  p_tax_minor       bigint default null,
  p_tax_code        text   default null,
  p_invoice_date    date   default null,
  p_due_date        date   default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.bill_landed_cost(p_receipt_id, p_party_id, p_charge, p_amount_minor, p_their_reference,
                                   p_tax_minor, p_tax_code, p_invoice_date, p_due_date) $$;

revoke all on function public.erp_bill_landed_cost(uuid, uuid, text, bigint, text, bigint, text, date, date) from public, anon;
grant execute on function public.erp_bill_landed_cost(uuid, uuid, text, bigint, text, bigint, text, date, date)
  to authenticated, service_role;

comment on function public.erp_bill_landed_cost(uuid, uuid, text, bigint, text, bigint, text, date, date) is
  'Bill a landed cost against a posted goods receipt (20261004970000). erp.bill_landed_cost() authorises '
  'procurement.match at the receipt''s site.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_bill_landed_cost', 'erp.bill_landed_cost',
   'Raises and registers a supplier''s bill for a landed cost on a posted goods receipt, which lands the '
   'charge on the goods; authorises procurement.match at the receipt''s site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/procurement', array['erp_bill_landed_cost']);

-- What landed, bill by bill.
create or replace function public.erp_landed_costs(p_limit integer default 100)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The landed costs, newest first (20261004970000): each one's bill, the
  -- receipt it was charged on, the charge, and what of it landed on the goods
  -- and what stayed a cost of sales.
  select coalesce(jsonb_agg(x order by x ->> 'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'landed_cost_id', lc.id, 'charge_code', lc.charge_code,
             'description', lc.description, 'amount_minor', lc.amount_minor,
             'currency', lc.currency, 'basis', lc.allocation_basis,
             'receipt', d.document_number, 'receipt_id', d.id,
             'bill', b.document_number, 'bill_id', b.id,
             'supplier', p.name,
             'capitalised_minor', lc.capitalised_minor,
             'expensed_minor', case when lc.capitalised_minor is null then null
                                    else lc.amount_minor - lc.capitalised_minor end,
             'allocated_at', lc.allocated_at, 'created_at', lc.created_at) as x
      from erp.landed_cost lc
      left join erp.document d on d.tenant_id = lc.tenant_id and d.id = lc.receipt_document_id
      left join erp.document b on b.tenant_id = lc.tenant_id and b.id = lc.bill_document_id
      left join erp.party p on p.tenant_id = lc.tenant_id and p.id = lc.supplier_party_id
     where lc.tenant_id = erp.current_tenant_id()
     order by lc.created_at desc
     limit greatest(p_limit, 1)) t;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The hand allocation is retired
-- ═════════════════════════════════════════════════════════════════════════════

delete from erp_meta.public_write_allowance where function_name = 'erp_allocate_landed_cost';
update erp_ref.help_topic set actions = array_remove(actions, 'erp_allocate_landed_cost')
 where 'erp_allocate_landed_cost' = any(actions);
drop function if exists public.erp_allocate_landed_cost(uuid);
drop function if exists erp.allocate_landed_cost(uuid);

-- procurement_controls_suite's three landed cost cases allocated a row the
-- suite wrote by hand: the defect itself. They now prove the hand route is
-- gone. Edited, not rewritten: one anchor over its body (md5 b5ed364c…), the
-- block from the hand insert to the second allocation.

do $suite$
declare
  v_sig   constant text := 'erp_test.procurement_controls_suite()';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_start constant text := $o$  insert into erp.landed_cost ($o$;
  v_end   constant text := $o$  return query select 'a charge cannot be allocated twice', v_ok, v_msg;$o$;
  v_new   constant text := $n$  -- A landed cost comes from the bill that charges it (20261004970000); the
  -- hand route this block used to prove is gone. erp_test.landed_cost_suite
  -- proves the bill.
  return query select 'no door allocates a landed cost by hand',
    to_regprocedure('public.erp_allocate_landed_cost(uuid)') is null
      and to_regprocedure('erp.allocate_landed_cost(uuid)') is null,
    'a landed cost lands on the goods from its bill, Bill a landed cost';

  select c.unit_cost_minor into v_cost from erp.item_cost c
   where c.tenant_id = r.tenant_id and c.item_id = v_item;
  return query select 'and the stock is worth what was paid for it until a bill says otherwise',
    v_cost = 1000,
    format('unit cost %s; nothing raised it without a bill', v_cost);

  begin
    insert into erp.landed_cost (
      tenant_id, receipt_document_id, charge_code, description,
      amount_minor, currency, allocation_basis)
    values (r.tenant_id, v_grn, 'freight', 'Sea freight', 100000, 'GBP', 'value');
    v_ok := false; v_msg := 'a landed cost with no bill was recorded';
  exception when check_violation then v_ok := true; v_msg := left(sqlerrm, 54); end;
  return query select 'a landed cost that no bill charges is refused', v_ok, v_msg;$n$;
  v_from  integer;
  v_to    integer;
begin
  if strpos(v_src, '20261004970000') > 0 then
    raise notice '% already proves the hand route is gone; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'b5ed364cc278b81a7f7dc89e35718bc6' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261004970000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_from := strpos(v_def, v_start);
  v_to := strpos(v_def, v_end);
  if v_from = 0 or v_to = 0 or v_to < v_from
     or (length(v_def) - length(replace(v_def, v_start, ''))) / length(v_start) <> 1
     or (length(v_def) - length(replace(v_def, v_end, ''))) / length(v_end) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % landed cost block not found once', v_sig;
  end if;
  execute substr(v_def, 1, v_from - 1) || v_new || substr(v_def, v_to + length(v_end));
end
$suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- G. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.landed_cost_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sa uuid; v_broker uuid; v_cust uuid;
  v_po uuid; v_grn uuid; v_open uuid; v_bill uuid; v_cap jsonb; v_row jsonb;
  v_val0 bigint; v_val1 bigint; v_cos0 bigint; v_cos1 bigint; v_tie text;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, with a supplier, a customs broker and a buyer who does not match bills';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzlnd-' || v_tag, 'Landed Cost Suite',
      'admin@zzlnd-' || v_tag || '.test', 'Landed Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzlnd-' || v_tag || '.test'), (s_buy, 'viewer@zzlnd-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('viewer@zzlnd-' || v_tag || '.test', 'Val Viewer');
    perform public.erp_save_role(null, 'looker', 'Looker', 'Reads purchasing', array['procurement.read']);
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'looker', null, null, 'reads');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZLCOAT', 'Imported Coat', v_uom, 'active') returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZLSCARF', 'Imported Scarf', v_uom, 'active') returning id into v_item2;
    v_sa := erp_test.cash_payment_supplier('ZLBRAND');
    v_broker := erp_test.cash_payment_supplier('ZLBROKER');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZLCUST', 'Only A Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust, 'customer', 'active');

    -- Ten coats at £90 and ten scarves at £10, ordered, received and posted;
    -- a second receipt left unposted.
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZLC1', false);
    perform erp.add_document_line(v_po, v_item2, 10, 1000, 'scarves');
    perform erp.transition_document(v_po, 'send', null);
    v_grn := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_grn, (select l.id from erp.document_line l where l.document_id = v_po and l.item_id = v_item), 10, null);
    perform erp.receive_against(v_grn, (select l.id from erp.document_line l where l.document_id = v_po and l.item_id = v_item2), 10, null);
    perform erp.transition_document(v_grn, 'post', null);
    v_open := erp.open_document('goods_receipt', v_sa, v_entity, v_site);

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the door, the refusals, the event, the bill type and the installer';
    v_cases := v_cases + 1;
    case_name := 'the door is on the allow-list under its gate and on the Procurement screen''s help, the four refusals are registered with a next action, landed_cost.capitalised is current in English and German, the bill type posts by its own rule, and procurement controls is at version 8 with the three items it ships';
    passed := v_state is null
          and exists (select 1 from erp_meta.public_write_allowance a
                       where a.function_name = 'erp_bill_landed_cost' and a.gate = 'erp.bill_landed_cost')
          and exists (select 1 from erp_ref.help_topic h where h.screen_path = '/procurement'
                         and h.actions @> array['erp_bill_landed_cost'])
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_LANDED_COST_RECEIPT_NOT_POSTED', 'CLOVEERP_LANDED_COST_CHARGE_UNKNOWN',
                                 'CLOVEERP_LANDED_COST_AMOUNT_INVALID', 'CLOVEERP_LANDED_COST_PARTY_NOT_A_SUPPLIER')
                  and coalesce(f.next_action, '') <> '') = 4
          and (select count(*) from erp_ref.resource x
                where x.key = 'event.landed_cost.capitalised' and x.locale in ('en', 'de')) = 2
          and exists (select 1 from erp.document_type dt
                       where dt.tenant_id = rb.tenant_id and dt.code = 'landed_cost_bill'
                         and dt.base_type_code = 'invoice_reference' and dt.state_machine_code = 'purchase_invoice')
          and exists (select 1 from erp.posting_rule pr
                       where pr.tenant_id = rb.tenant_id and pr.code = 'landed_cost_bill' and pr.status = 'active')
          and (select mi.current_version from erp_ref.module_installer mi where mi.install_code = 'procurement-controls') = 8
          and (select count(*) from erp_ref.module_upgrade_item ui
                where ui.install_code = 'procurement-controls' and ui.to_version = 8) = 3;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. What may not be billed ───────────────────────────────────────────
    v_step := 'an unposted receipt, a charge nobody knows, nothing, a customer, and a reader';
    begin
      perform public.erp_bill_landed_cost(v_open, v_broker, 'duty', 20000);
      v_err := 'billed';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_bill_landed_cost(v_grn, v_broker, 'marketing', 20000);
      v_err2 := 'billed';
    exception when others then v_err2 := sqlerrm; end;
    begin
      perform public.erp_bill_landed_cost(v_grn, v_broker, 'duty', 0);
      v_err3 := 'billed';
    exception when others then v_err3 := sqlerrm; end;
    begin
      perform public.erp_bill_landed_cost(v_grn, v_cust, 'duty', 20000);
      v_err4 := 'billed';
    exception when others then v_err4 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    begin
      perform public.erp_bill_landed_cost(v_grn, v_broker, 'duty', 20000);
      v_err5 := 'billed';
    exception when others then v_err5 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a receipt not yet posted, a charge that is not a landed cost, a charge of nothing, a party the organisation only sells to, and a reader without procurement.match are each refused by name, and nothing is recorded';
    passed := v_state is null
          and v_err like 'CLOVEERP_LANDED_COST_RECEIPT_NOT_POSTED:%'
          and v_err2 like 'CLOVEERP_LANDED_COST_CHARGE_UNKNOWN:%'
          and v_err3 like 'CLOVEERP_LANDED_COST_AMOUNT_INVALID:%'
          and v_err4 like 'CLOVEERP_LANDED_COST_PARTY_NOT_A_SUPPLIER:%'
          and v_err5 like 'CLOVEERP_PERMISSION_DENIED: procurement.match%'
          and not exists (select 1 from erp.landed_cost lc where lc.tenant_id = rb.tenant_id);
    detail := coalesce(v_state, left(format('%s | %s | %s | %s | %s', v_err, v_err2, v_err3, v_err4, v_err5), 700));
    return next;

    -- ── 3. Half the coats are sold, then the broker bills the duty ──────────
    v_step := 'five coats leave the stock, then the broker bills £200 of duty with £40 of VAT';
    perform erp.write_off_stock(v_item, v_site,
      (select m.to_location_id from erp.stock_movement m where m.document_id = v_grn and m.item_id = v_item limit 1),
      5, 'sold at the counter', null, null);
    select coalesce(sum(v.value_minor), 0) into v_val0 from erp.stock_valuation_report() v;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_cos0
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = erp.chart_account_code('cost_of_sales');
    v_bill := public.erp_bill_landed_cost(v_grn, v_broker, 'duty', 20000, 'C88-4471', 4000);
    select coalesce(sum(v.value_minor), 0) into v_val1 from erp.stock_valuation_report() v;
    select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_cos1
      from erp.journal_line jl join erp.journal j on j.id = jl.journal_id and j.status = 'posted'
      join erp.account a on a.id = jl.account_id
     where jl.tenant_id = rb.tenant_id and a.code = erp.chart_account_code('cost_of_sales');
    select to_jsonb(e.payload) into v_cap from erp.event e
     where e.tenant_id = rb.tenant_id and e.event_type = 'landed_cost.capitalised' and e.aggregate_id = v_bill;
    v_cases := v_cases + 1;
    case_name := 'the broker''s £200 duty bill registers and lands on the goods: the stock''s value rises by exactly what was capitalised, which is the duty on the coats and scarves still held, and the duty on the coats already gone stays a cost of sales';
    passed := v_state is null
          and erp.object_current_state('document', v_bill) = 'registered'
          and v_cap is not null
          and (v_cap ->> 'net_minor')::bigint = 20000
          and v_val1 - v_val0 = (v_cap ->> 'capitalised_minor')::bigint
          -- Coats are £900 of £1,000 of value: £180 of duty, half still held, so £90; scarves £20, all held.
          and (v_cap ->> 'capitalised_minor')::bigint = 11000
          and (v_cap ->> 'expensed_minor')::bigint = 9000
          and v_cos1 - v_cos0 = 9000;
    detail := coalesce(v_state, left(format('bill %s; cap %s; value +%s; cost of sales +%s',
      erp.object_current_state('document', v_bill), v_cap, v_val1 - v_val0, v_cos1 - v_cos0), 600));
    return next;

    -- ── 4. It is a supplier's bill like any other ───────────────────────────
    v_step := 'the bill as the payables read it';
    v_cases := v_cases + 1;
    case_name := 'the bill is a supplier''s bill: owed to the broker in full with its VAT, linked to the receipt it was charged on, and its landed cost names it with what landed';
    passed := v_state is null
          and erp.document_is_purchase_bill(v_bill)
          and erp.document_trade_side(v_bill) = 'purchase'
          and exists (select 1 from erp.journal j join erp.journal_line jl on jl.journal_id = j.id
                       join erp.account a on a.id = jl.account_id
                      where j.document_id = v_bill and j.status = 'posted'
                        and a.code = erp.chart_account_code('trade_payable') and jl.credit_minor = 24000)
          and exists (select 1 from erp.document_relation rel
                       where rel.from_document_id = v_bill and rel.to_document_id = v_grn and rel.relation_kind = 'invoices')
          and (select lc.capitalised_minor from erp.landed_cost lc where lc.bill_document_id = v_bill) = 11000
          and (select lc.allocated_at is not null from erp.landed_cost lc where lc.bill_document_id = v_bill);
    detail := coalesce(v_state, format('purchase bill %s', erp.document_is_purchase_bill(v_bill)));
    return next;

    -- ── 5. The ties hold ────────────────────────────────────────────────────
    v_step := 'the whole database reconciled';
    set constraints all immediate;
    begin
      perform erp.assert_whole_database_reconciles();
      v_tie := 'ties';
    exception when others then v_tie := left(sqlerrm, 300); end;
    v_cases := v_cases + 1;
    case_name := 'after the duty lands on the stock, the whole database reconciles: stock to the ledger, payables to the control, and the trial balance';
    passed := v_state is null and v_tie = 'ties';
    detail := coalesce(v_state, v_tie);
    return next;

    -- ── 6. Once ─────────────────────────────────────────────────────────────
    v_step := 'capitalising the same bill again';
    v_cases := v_cases + 1;
    case_name := 'a bill''s landed cost is capitalised once: asking again does nothing';
    passed := v_state is null
          and erp.capitalise_landed_cost(v_bill) is null
          and (select count(*) from erp.journal j where j.document_id = v_bill and j.source_code = 'landed_cost.capitalised') = 1;
    detail := coalesce(v_state, 'once');
    return next;

    -- ── 7. The list ─────────────────────────────────────────────────────────
    v_step := 'the landed costs read';
    select x into v_row from jsonb_array_elements(public.erp_landed_costs(10)) x where x ->> 'bill_id' = v_bill::text;
    v_cases := v_cases + 1;
    case_name := 'the landed costs list the bill, its receipt, the broker, the charge, and what landed and what was expensed';
    passed := v_state is null
          and v_row is not null
          and v_row ->> 'bill' = (select d.document_number from erp.document d where d.id = v_bill)
          and v_row ->> 'receipt' = (select d.document_number from erp.document d where d.id = v_grn)
          and v_row ->> 'charge_code' = 'duty'
          and (v_row ->> 'capitalised_minor')::bigint = 11000
          and (v_row ->> 'expensed_minor')::bigint = 9000;
    detail := coalesce(v_state, left(coalesce(v_row::text, 'not listed'), 400));
    return next;

    -- ── 8. No hand route ────────────────────────────────────────────────────
    v_step := 'a landed cost written by hand';
    begin
      insert into erp.landed_cost (tenant_id, receipt_document_id, charge_code, description, amount_minor, currency)
      values (rb.tenant_id, v_grn, 'duty', 'by hand', 5000, 'GBP');
      v_err := 'recorded';
    exception when check_violation then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a landed cost that no bill charges is refused, and no door allocates one by hand';
    passed := v_state is null
          and v_err like '%landed_cost_names_its_bill%'
          and to_regprocedure('public.erp_allocate_landed_cost(uuid)') is null
          and to_regprocedure('erp.allocate_landed_cost(uuid)') is null;
    detail := coalesce(v_state, left(v_err, 300));
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzlnd-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_buy))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzlnd rolled back with its receipts and bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_LANDED_COST_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.landed_cost_suite() from public, anon;

comment on function erp_test.landed_cost_suite() is
  'Landed cost comes from the bill (20261004970000): the door refuses by name; a duty bill registers as a '
  'supplier''s bill and lands on the goods still held by exactly what the stock rose by, the rest a cost of '
  'sales; the ties hold; once per bill; no hand route.';

create or replace function erp_test.assert_landed_cost_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.landed_cost_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_LANDED_COST_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A landed cost would raise the stock without the ledger, or land twice. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_LANDED_COST_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('landed cost: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_landed_cost_suite() from public, anon;

comment on function erp_test.assert_landed_cost_suite() is
  'A landed cost lands on the goods from the supplier''s bill that charges it, and the stock and the ledger '
  'move together (20261004970000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- H. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Billing a landed cost (20261004970000).'
  from (values
    ('Bill a landed cost'),
    ('A supplier''s bill for duty, brokerage, insurance, handling or freight on goods already received. It lands on the goods still held; the rest is a cost of sales.'),
    ('Goods receipt'),
    ('Supplier'),
    ('Charge'),
    ('Duty'),
    ('Brokerage'),
    ('Insurance'),
    ('Handling'),
    ('Freight'),
    ('Other'),
    ('Net amount'),
    ('Before tax, in the company''s own currency.'),
    ('Their reference'),
    ('C88-4471'),
    ('The supplier''s own invoice number.'),
    ('VAT'),
    ('Optional. Leave empty when the bill carries none.'),
    ('Invoice date'),
    ('Landed costs'),
    ('Duty, brokerage and other charges billed on goods received, and how much of each landed on the stock.'),
    ('Nothing billed yet. Bill a landed cost against a posted receipt and it lands here.'),
    ('Bill'),
    ('Receipt'),
    ('Landed'),
    ('Expensed')
  ) as v(text)
on conflict (key, locale) do nothing;

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
