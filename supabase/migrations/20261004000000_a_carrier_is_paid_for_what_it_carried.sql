set lock_timeout = '30s';

-- =============================================================================
-- 20261004000000  A carrier is paid for what it carried
-- -----------------------------------------------------------------------------
-- LPR4 of docs/spec/logistics-target-flow.md: node L9, settlement option A,
-- chosen on 29 September.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A shipment was booked at a cost and nothing ever met the carrier's bill:
-- the product had no door for a bill without a goods receipt, so expected
-- freight was recorded and actual freight was not, and a carrier who charged
-- double was paid double by whoever typed the bill in somewhere else.
--
-- Two things the spec did not know, found by the spike (1 October):
--
--   * Neither chart had an account for carriage outwards. The default chart
--     has no general expense account at all, and §8.1's 6500 is freight
--     variance inside cost of sales, for freight in. The owner chose a new
--     purpose, carriage_outwards, 7200, an operating expense, in both charts.
--   * The match exception C7 built belonged to a purchase-order line: its
--     order_line_id was required, and its workbench and Accept door read the
--     line. A shipment has none. The owner chose to widen it, so every bill
--     that does not match, goods or carriage, is cleared on one workbench by
--     the same approval and the same maker and checker.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   A. 7200 Carriage outwards: a purpose the finance installer creates, a
--      §8.1 pack account, and an account the logistics upgrade adds to any
--      company that lacks it.
--   B. A carrier bill: a document type on base type invoice_reference and the
--      supplier bill's own lifecycle (so erp.document_is_purchase_bill(), the
--      payment run, the dispute and the VAT return read it as a supplier's
--      bill), numbered CB-, posting by its own rule: the net to 7200, the tax
--      to tax control, the total to trade payable. Logistics version 4.
--   C. erp.match_exception carries a shipment or an order line, exactly one.
--      The workbench lists both; Accept reads either.
--   D. Bill from shipment: erp_bill_from_shipment(), born from a delivered
--      shipment, pre-filled with its booked cost. Inside the shipping
--      policy's cost tolerance it registers; outside it, the exception is
--      raised under the match tolerance's approval chain and the bill
--      registers disputed, as a goods bill that does not match does.
--   E. Despatch is three presses: Bill from shipment is the strip's third
--      step, and the walk takes it.
--
-- Proof: erp_test.freight_settlement_suite (9 cases), and case 15 of
-- erp_test.step_budget_suite walked at three.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. 7200 Carriage outwards
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.chart_account_purpose
  (purpose, name, account_type, control_kind, default_code, statutory_code, installer_creates, note, seq) values
  ('carriage_outwards', 'Carriage outwards', 'expense', null, '7200', '7200', true,
   'What carriers charge to take goods to customers: a distribution cost, not cost of sales. A carrier''s '
   'bill born from a delivered shipment posts its net here through the carrier_bill rule (20261004000000).', 146)
on conflict (purpose) do nothing;

do $purpose$
begin
  if (select count(*) from erp_ref.chart_account_purpose p
       where p.purpose = 'carriage_outwards' and p.default_code = '7200'
         and p.statutory_code = '7200' and p.account_type = 'expense' and p.installer_creates) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: carriage_outwards is declared already, and not as 20261004000000 declares it';
  end if;
end
$purpose$;

insert into erp_ref.pack_item (pack_code, object_kind, object_key, payload, provenance, seq) values
  ('chart_8_1', 'account', '7200',
   '{"code": "7200", "name": "Carriage outwards", "is_postable": true, "account_type": "expense", "close_blocking": false, "reconciliation_required": false}'::jsonb,
   'What carriers charge to take goods to customers, in §8.1''s operating expenses band (20261004000000).', 146)
on conflict do nothing;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('interview.account_purpose.carriage_outwards', 'en', 'Carriage outwards', 'finance',
   'The name of the account purpose for what carriers charge to take goods to customers.'),
  ('interview.account_purpose.carriage_outwards.note', 'en',
   'What carriers charge to take goods to customers, from their bills for the shipments they carried.', 'finance',
   'What the carriage outwards account holds.'),
  ('document.carrier_bill', 'en', 'Carrier bill', 'logistics', 'Document type name (20261004000000).'),
  ('document.carrier_bill', 'de', 'Frachtrechnung', 'logistics', null)
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The carrier bill, as configuration
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.carrier_bill_rule(p_by_purpose boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- A carrier's bill (20261004000000): the net is carriage outwards, the tax
  -- the carrier charged is input tax, and the total is owed to the carrier.
  -- Named by purpose for the upgrade register, which adds the account to a
  -- company that lacks it, and by the code in force for an install.
  select jsonb_build_object(
    'code', 'carrier_bill', 'name', 'Carrier bill', 'ledger', 'GL',
    'event_type', 'document.carrier_bill.registered',
    'posting_lines', jsonb_build_array(
      jsonb_build_object(
        'account', case when p_by_purpose then jsonb_build_object('purpose', 'carriage_outwards')
                        else to_jsonb(erp.chart_account_code('carriage_outwards')) end,
        'side', 'debit', 'rate', 1, 'basis', 'document_value',
        'description', 'Carriage outwards, what the carrier charged to take the goods'),
      jsonb_build_object(
        'account', case when p_by_purpose then jsonb_build_object('purpose', 'tax_control')
                        else to_jsonb(erp.chart_account_code('tax_control')) end,
        'side', 'debit', 'rate', 1, 'basis', 'document_tax',
        'description', 'Tax the carrier charged'),
      jsonb_build_object(
        'account', case when p_by_purpose then jsonb_build_object('purpose', 'trade_payable')
                        else to_jsonb(erp.chart_account_code('trade_payable')) end,
        'side', 'credit', 'balancing', true,
        'description', 'Owed to the carrier')))
$$;

revoke all on function erp.carrier_bill_rule(boolean) from public, anon;

create or replace function erp.carrier_bill_pack_items(p_by_purpose boolean default false)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What logistics version 4 adds (20261004000000), read by
  -- erp.configure_logistics() for a new install and by the upgrade register
  -- for an organisation on version 3. The rule and the sequence before the
  -- type that names them.
  select jsonb_build_array(
    jsonb_build_object('kind', 'posting_rule', 'key', 'carrier_bill',
                       'payload', erp.carrier_bill_rule(p_by_purpose)),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'carrier_bill', 'payload',
      jsonb_build_object('code', 'carrier_bill', 'prefix', 'CB-', 'pad_to', 6,
                         'next_value', 1, 'reset_period', 'never')),
    jsonb_build_object('kind', 'document_type', 'key', 'carrier_bill', 'payload',
      jsonb_build_object('code', 'carrier_bill', 'name', 'Carrier bill',
                         'base_type', 'invoice_reference', 'state_machine', 'purchase_invoice',
                         'numbering_rule', 'carrier_bill', 'posting_rule', 'carrier_bill',
                         'create_permission', 'procurement.match')
      -- On an install, the company the supplier's bill belongs to: a company
      -- with no books cannot post one, and a type it could raise would be a
      -- way for a posting to fail there. The upgrade register cannot know a
      -- company, so an upgrade installs it for the organisation.
      || case when p_by_purpose then '{}'::jsonb
              else coalesce((select jsonb_build_object('entity', e.code)
                               from erp.document_type dt
                               join erp.entity e on e.tenant_id = dt.tenant_id and e.id = dt.entity_id
                              where dt.tenant_id = erp.current_tenant_id()
                                and dt.code = 'purchase_invoice' and dt.status = 'active'
                              limit 1), '{}'::jsonb) end))
$$;

revoke all on function erp.carrier_bill_pack_items(boolean) from public, anon;

comment on function erp.carrier_bill_pack_items(boolean) is
  'The carrier bill (20261004000000): its posting rule, numbering rule and document type, the items '
  'erp.configure_logistics() and the logistics upgrade register both read.';

do $configure$
declare
  v_sig  constant text := 'erp.configure_logistics()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      || erp.despatch_pack_items());$o$;
  v_new  constant text := $n$      || erp.despatch_pack_items()
      -- The carrier's bill, settled against the shipment (20261004000000).
      || erp.carrier_bill_pack_items());$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % despatch pack anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

update erp_ref.module_installer
   set current_version = 4,
       description = description
         || ' Version 4 (20261004000000): the carrier bill, born from a delivered shipment and posted to '
         || 'carriage outwards.'
 where install_code = 'logistics' and current_version = 3;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'logistics', 4, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       100 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.carrier_bill_pack_items(true)) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

insert into erp_ref.module_upgrade_account (install_code, to_version, purpose)
values ('logistics', 4, 'carriage_outwards')
on conflict do nothing;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'logistics') is distinct from 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the logistics installer is not at version 4';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'logistics' and ui.to_version = 4) <> 3 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 4 of logistics is not the three items the carrier bill ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A match exception carries a shipment or an order line
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.match_exception alter column order_line_id drop not null;
alter table erp.match_exception add column if not exists shipment_id uuid;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'match_exception_tenant_id_shipment_id_fkey') then
    alter table erp.match_exception
      add constraint match_exception_tenant_id_shipment_id_fkey
      foreign key (tenant_id, shipment_id) references erp.shipment (tenant_id, id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'match_exception_one_subject') then
    alter table erp.match_exception
      add constraint match_exception_one_subject
      check (num_nonnulls(order_line_id, shipment_id) = 1);
  end if;
end
$fk$;

create index if not exists match_exception_shipment_idx
  on erp.match_exception (tenant_id, shipment_id) where shipment_id is not null;

comment on column erp.match_exception.shipment_id is
  'The shipment a carrier''s bill does not match, where the exception is about carriage rather than an order '
  'line; exactly one of order_line_id and shipment_id is set (20261004000000).';

create or replace function erp.match_exception_workbench()
returns table(exception_id uuid, order_number text, line_no integer, item_code text, party_name text,
              status erp.match_status, quantity_variance numeric, price_variance_minor bigint,
              value_at_risk_minor bigint, age_days integer)
language sql
stable
set search_path = ''
as $$
  -- Every bill that does not match, goods or carriage (20261004000000). A
  -- carrier's names its shipment where a goods bill names its order, has no
  -- line or product, and names the carrier as its party.
  select e.id, coalesce(d.document_number, sd.document_number, sh.reference), ol.line_no, i.code,
         coalesce(p.name, cp.name), e.status,
         e.quantity_variance, e.price_variance_minor,
         -- What the difference is worth, which is how a workbench is ordered
         -- by anybody who has to work it.
         (abs(coalesce(e.quantity_variance, 0)) * coalesce(e.ordered_price_minor, 0)
          + abs(coalesce(e.price_variance_minor, 0))
            * coalesce(e.invoiced_quantity, 0))::bigint,
         (current_date - e.created_at::date)::integer
    from erp.match_exception e
    left join erp.document_line ol on ol.id = e.order_line_id
    left join erp.document d on d.id = ol.document_id
    left join erp.item i on i.id = ol.item_id
    left join erp.party p on p.id = d.party_id
    left join erp.shipment sh on sh.tenant_id = e.tenant_id and sh.id = e.shipment_id
    left join erp.document sd on sd.tenant_id = sh.tenant_id and sd.id = sh.document_id
    left join erp.carrier c on c.tenant_id = sh.tenant_id and c.id = sh.carrier_id
    left join erp.party cp on cp.tenant_id = c.tenant_id and cp.id = c.party_id
   where e.tenant_id = erp.current_tenant_id()
     and e.resolved_at is null
   order by 9 desc, 10 desc
$$;

-- Accept reads a shipment's exception as it reads a line's: the number and
-- the place it is authorised at come from the shipment, and a later exception
-- on the same shipment is resolved with it as one on the same line is.
do $accept$
declare
  v_sig  constant text := 'erp.accept_match_exception(uuid,text)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$   where ol.tenant_id = v_tenant and ol.id = e.order_line_id;
$o$,
    $n$   where ol.tenant_id = v_tenant and ol.id = e.order_line_id;

  -- Or the shipment a carrier's bill does not match (20261004000000).
  if e.shipment_id is not null then
    select coalesce(sd.document_number, sh.reference), sh.entity_id, sh.site_id
      into v_order, v_entity, v_site
      from erp.shipment sh
      left join erp.document sd on sd.tenant_id = sh.tenant_id and sd.id = sh.document_id
     where sh.tenant_id = v_tenant and sh.id = e.shipment_id;
  end if;
$n$,
    $o$     and x.order_line_id = e.order_line_id
$o$,
    $n$     and (x.order_line_id = e.order_line_id or x.shipment_id = e.shipment_id)
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$accept$;

-- A carrier is someone the organisation buys from (20261004000000): a
-- document in a carrier's role is a purchase, so its tax is input tax.
do $side$
declare
  v_sig  constant text := 'erp.document_trade_side(uuid)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$                       when 'supplier' then 'purchase'
$o$;
  v_new  constant text := $n$                       when 'supplier' then 'purchase'
                       when 'carrier'  then 'purchase'
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % supplier anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$side$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Bill from shipment
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_SHIPMENT_NOT_DELIVERED',
  'Billing a shipment that has not been delivered.',
  'A carrier bills for carrying the goods, and until the shipment is delivered they have not been carried.',
  'Record the proof of delivery first, then bill the shipment.');

select erp.register_refusal('CLOVEERP_SHIPMENT_ALREADY_BILLED',
  'Billing a shipment its carrier has already billed.',
  'One shipment, one carrier''s bill: a second would pay for the same carriage twice.',
  'Cancel the bill that exists before entering another, or ask the carrier for a credit note.');

select erp.register_refusal('CLOVEERP_SHIPMENT_HAS_NO_CARRIER_PARTY',
  'Billing a shipment whose carrier is not a party the organisation can owe.',
  'A bill is owed to a party, and this carrier has none to owe it to.',
  'Give the carrier its party under Despatch''s carriers, then bill the shipment.');

create or replace function erp.bill_from_shipment(
  p_shipment_id     uuid,
  p_their_reference text   default null,
  p_amount_minor    bigint default null,
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
  sh       erp.shipment%rowtype;
  v_number text;
  v_party  uuid;
  v_inv    uuid;
  v_amount bigint;
  v_date   date := coalesce(p_invoice_date, current_date);
  v_pct    numeric;
  v_chain  text;
  v_req    uuid;
begin
  select * into sh from erp.shipment
   where tenant_id = v_tenant and id = p_shipment_id
     for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SHIPMENT: %', p_shipment_id using errcode = '23503';
  end if;
  select coalesce(d.document_number, sh.reference) into v_number
    from erp.document d where d.tenant_id = v_tenant and d.id = sh.document_id;
  v_number := coalesce(v_number, sh.reference);

  perform erp.authorise('procurement.match', sh.entity_id, sh.site_id, null,
                        'shipment', p_shipment_id);

  if sh.status <> 'delivered' then
    raise exception 'CLOVEERP_SHIPMENT_NOT_DELIVERED: % is %, and a carrier bills for what it has carried',
      v_number, sh.status
      using errcode = '23514',
            hint = 'Record the proof of delivery first, then bill the shipment.';
  end if;

  if exists (select 1 from erp.document_relation rel
               join erp.document b on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
               join erp.document_type bt on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
              where rel.tenant_id = v_tenant and rel.to_document_id = sh.document_id
                and rel.relation_kind = 'invoices'
                and bt.code = 'carrier_bill' and not b.is_cancelled) then
    raise exception 'CLOVEERP_SHIPMENT_ALREADY_BILLED: % already has its carrier''s bill', v_number
      using errcode = '23505',
            hint = 'Cancel the bill that exists before entering another, or ask the carrier for a credit note.';
  end if;

  select c.party_id into v_party from erp.carrier c
   where c.tenant_id = v_tenant and c.id = sh.carrier_id;
  if v_party is null then
    raise exception 'CLOVEERP_SHIPMENT_HAS_NO_CARRIER_PARTY: % has no carrier the organisation can owe', v_number
      using errcode = '23514',
            hint = 'Give the carrier its party under Despatch''s carriers, then bill the shipment.';
  end if;

  -- Born from the shipment (doctrine 2): its carrier, its company and site,
  -- its currency, and what it was booked at unless the bill says otherwise.
  v_amount := coalesce(p_amount_minor, sh.freight_cost_minor);
  v_inv := erp.open_document('carrier_bill', v_party, sh.entity_id, sh.site_id,
                             p_their_reference, null, sh.currency);
  -- In the carrier's role, which is what makes it a purchase to
  -- erp.document_trade_side() and so to the tax and the VAT return.
  update erp.document
     set document_date = v_date,
         due_date = coalesce(p_due_date, v_date + 30),
         notes = coalesce(notes, format('Carriage on %s', v_number)),
         party_role_id = (select pr.id from erp.party_role pr
                           where pr.tenant_id = v_tenant and pr.party_id = v_party
                             and pr.role_kind = 'carrier' and pr.status = 'active'
                           order by pr.created_at limit 1),
         updated_at = now()
   where id = v_inv;
  perform erp.add_document_line(v_inv, null, 1, v_amount, format('Carriage on %s', v_number));

  insert into erp.document_relation (tenant_id, from_document_id, to_document_id, relation_kind)
  values (v_tenant, v_inv, sh.document_id, 'invoices');

  if p_tax_minor is not null then
    -- Standard rated unless the bill says otherwise, as erp.state_supplier_tax() defaults.
    perform erp.state_supplier_tax(v_inv, p_tax_minor, coalesce(p_tax_code, 'S'), 'carriage on ' || v_number);
  end if;

  -- Against what it was booked at, under the shipping policy's tolerance
  -- (20261003900000). Outside it, the difference is an exception under the
  -- match tolerance's approval chain, raised while the bill is a draft as a
  -- goods bill's is, so registering it lands it disputed.
  v_pct := coalesce((erp.shipping_policy(sh.entity_id, sh.site_id) ->> 'cost_override_tolerance_pct')::numeric, 10);
  if sh.freight_cost_minor is not null
     and abs(v_amount - sh.freight_cost_minor) * 100.0 > sh.freight_cost_minor * v_pct then
    select mt.approval_chain_code into v_chain
      from erp.match_tolerance mt
     where mt.tenant_id = v_tenant and mt.status = 'active'
       and (mt.party_id = v_party or mt.party_id is null)
       and mt.item_class is null
     order by (mt.party_id is null), mt.code
     limit 1;
    if v_chain is not null then
      v_req := erp.request_approval(
        'match_exception', p_shipment_id,
        jsonb_build_object('status', 'price_variance',
                           'price_variance_minor', v_amount - sh.freight_cost_minor,
                           'party_id', v_party, 'shipment', v_number),
        1, sh.entity_id, sh.site_id);
    end if;
    insert into erp.match_exception (
      tenant_id, shipment_id, invoice_document_id, status,
      ordered_quantity, received_quantity, invoiced_quantity,
      ordered_price_minor, invoiced_price_minor,
      quantity_variance, price_variance_minor, approval_request_id)
    values (v_tenant, p_shipment_id, v_inv, 'price_variance',
            1, 1, 1, sh.freight_cost_minor, v_amount, 0, v_amount - sh.freight_cost_minor, v_req);
  end if;

  perform erp.transition_document(v_inv, 'register', 'carriage on ' || v_number);
  return v_inv;
end;
$$;

comment on function erp.bill_from_shipment(uuid, text, bigint, bigint, text, date, date) is
  'Bill from shipment (20261004000000): the carrier''s bill for a delivered shipment, born from it at its '
  'booked cost unless the bill says otherwise; registered, or registered disputed where it is above or '
  'below the booked cost by more than the shipping policy allows. Authorises procurement.match.';

create or replace function public.erp_bill_from_shipment(
  p_shipment_id     uuid,
  p_their_reference text   default null,
  p_amount_minor    bigint default null,
  p_tax_minor       bigint default null,
  p_tax_code        text   default null,
  p_invoice_date    date   default null,
  p_due_date        date   default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.bill_from_shipment(p_shipment_id, p_their_reference, p_amount_minor, p_tax_minor,
                                     p_tax_code, p_invoice_date, p_due_date) $$;

comment on function public.erp_bill_from_shipment(uuid, text, bigint, bigint, text, date, date) is
  'Bill from shipment (20261004000000): the Despatch strip''s third press. erp.bill_from_shipment() '
  'authorises procurement.match at the shipment''s site.';

revoke all on function public.erp_bill_from_shipment(uuid, text, bigint, bigint, text, date, date) from public, anon;
grant execute on function public.erp_bill_from_shipment(uuid, text, bigint, bigint, text, date, date) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_bill_from_shipment', 'erp.bill_from_shipment',
   'Raises and registers the carrier''s bill for a delivered shipment, at its booked cost unless told '
   'otherwise, raising a match exception where the difference is outside the shipping policy''s '
   'tolerance; authorises procurement.match at the shipment''s site.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

create or replace function public.erp_shipments_to_bill()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Delivered shipments no carrier's bill has met yet (20261004000000): the
  -- Despatch strip's third step, and what Bill from shipment offers.
  select coalesce(jsonb_agg(x order by x ->> 'actual_arrival' desc nulls last, x ->> 'number'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'shipment_id', sh.id, 'number', coalesce(sd.document_number, sh.reference),
               'status', sh.status, 'carrier', c.name, 'destination', p.name,
               'actual_arrival', sh.actual_arrival, 'freight_cost_minor', sh.freight_cost_minor,
               'currency', sh.currency) as x
        from erp.shipment sh
        join erp.document sd on sd.tenant_id = sh.tenant_id and sd.id = sh.document_id
        left join erp.carrier c on c.tenant_id = sh.tenant_id and c.id = sh.carrier_id
        left join erp.party p on p.tenant_id = sh.tenant_id and p.id = sh.destination_party_id
       where sh.tenant_id = erp.current_tenant_id()
         and sh.status = 'delivered'
         and not exists (
               select 1 from erp.document_relation rel
                 join erp.document b on b.tenant_id = rel.tenant_id and b.id = rel.from_document_id
                 join erp.document_type bt on bt.tenant_id = b.tenant_id and bt.id = b.document_type_id
                where rel.tenant_id = sh.tenant_id and rel.to_document_id = sh.document_id
                  and rel.relation_kind = 'invoices'
                  and bt.code = 'carrier_bill' and not b.is_cancelled)) t
$$;

revoke all on function public.erp_shipments_to_bill() from public, anon;
grant execute on function public.erp_shipments_to_bill() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Despatch is three presses
-- ─────────────────────────────────────────────────────────────────────────────

update erp_meta.flow_budget
   set budget = 3, decision_steps = 3, stages = 3, stages_without_a_list = 0,
       rationale = 'Three presses from posted deliveries to a carrier paid for what it carried: Ship these '
                || 'deliveries, which opens the shipment and books the carrier the rate card recommends '
                || '(20261002500000); Record proof of delivery; and Bill from shipment, the carrier''s bill '
                || 'met against the booked cost (20261004000000). Walked by erp_test.despatch_walk().'
 where flow_code = 'despatch';

create or replace function erp_test.despatch_walk()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  c_undo   constant text := 'CLOVEERP_DESPATCH_WALK_UNDO';
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code   text;
  a1       uuid := gen_random_uuid();   -- the administrator, who sets up
  s_plan   uuid := gen_random_uuid();   -- the planner, who ships
  s_drive  uuid := gen_random_uuid();   -- the driver, who proves delivery
  s_bill   uuid := gen_random_uuid();   -- the clerk, who enters the carrier's bill
  p_plan   uuid; p_drive uuid; p_bill uuid;
  r        record;
  res      jsonb;
  v_r1     jsonb; v_r2 jsonb; v_r3 jsonb;
  v_fx     jsonb;
  v_ids    uuid[];
  v_ship   uuid;
  v_doc    uuid;
  v_bill   uuid;
  v_booked text;
  v_need   integer;
  v_offer  boolean;
  v_offer3 boolean;
  v_steps  jsonb := '[]'::jsonb;
  v_subs   uuid[] := '{}';
  v_block  text;
  v_out    jsonb;
begin
  -- Despatch walked by pressing (20261003900000), to the carrier's bill
  -- (20261004000000): an organisation configured as the demonstration is; a
  -- planner who ships, a driver who proves delivery and a clerk who enters the
  -- carrier's bill, none an administrator, each holding only what their press
  -- needs. Three presses, from posted deliveries to a carrier paid for what
  -- it carried.
  begin
    v_code := 'zzdesw-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'Despatch walk', 'admin@' || v_code || '.test', 'Walk Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@' || v_code || '.test'), (s_plan, 'planner@' || v_code || '.test'),
           (s_drive, 'driver@' || v_code || '.test'), (s_bill, 'clerk@' || v_code || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    v_fx := erp_test.despatch_fixture(r.tenant_id, r.entity_id, v_hex, 2);
    select array_agg(x::uuid) into v_ids from jsonb_array_elements_text(v_fx -> 'deliveries') x;

    v_r1 := public.erp_save_role(null, 'planner', 'Planner', 'Ships what is posted',
                                 array['logistics.read', 'logistics.plan']);
    v_r2 := public.erp_save_role(null, 'driver', 'Driver', 'Delivers and records proof',
                                 array['logistics.read', 'logistics.despatch']);
    v_r3 := public.erp_save_role(null, 'freight_clerk', 'Freight clerk', 'Enters carriers'' bills',
                                 array['logistics.read', 'procurement.match', 'finance.post']);
    res := public.erp_invite_principal('planner@' || v_code || '.test', 'Pat Planner');
    p_plan := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_plan, 'planner', null, null, 'ships');
    perform set_config('request.jwt.claims', json_build_object('sub', s_plan)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('driver@' || v_code || '.test', 'Dee Driver');
    p_drive := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_drive, 'driver', null, null, 'delivers');
    perform set_config('request.jwt.claims', json_build_object('sub', s_drive)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('clerk@' || v_code || '.test', 'Cal Clerk');
    p_bill := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_bill, 'freight_clerk', null, null, 'bills');
    perform set_config('request.jwt.claims', json_build_object('sub', s_bill)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

    -- ─────────────────────────────────────────────────────────────────────
    -- The cycle: Ship these deliveries, Record proof of delivery, Bill from
    -- shipment.
    -- ─────────────────────────────────────────────────────────────────────
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', s_plan)::text, true);
      v_ship := public.erp_ship_deliveries(v_ids, null, null, null, null);
      v_steps := v_steps || jsonb_build_object('door', 'erp_ship_deliveries', 'person', 'planner');
      v_subs := v_subs || s_plan;
      select sh.status::text, sh.document_id into v_booked, v_doc from erp.shipment sh where sh.id = v_ship;
      v_need := jsonb_array_length(public.erp_shipment_exceptions());

      perform set_config('request.jwt.claims', json_build_object('sub', s_drive)::text, true);
      v_offer := exists (select 1 from jsonb_array_elements(public.erp_shipments(200)) s
                          where (s ->> 'shipment_id')::uuid = v_ship and s ->> 'status' = 'booked');
      perform public.erp_record_proof_of_delivery(v_ship, now(), 'A. Customer', null);
      v_steps := v_steps || jsonb_build_object('door', 'erp_record_proof_of_delivery', 'person', 'driver');
      v_subs := v_subs || s_drive;

      perform set_config('request.jwt.claims', json_build_object('sub', s_bill)::text, true);
      v_offer3 := exists (select 1 from jsonb_array_elements(public.erp_shipments_to_bill()) s
                           where (s ->> 'shipment_id')::uuid = v_ship);
      v_bill := public.erp_bill_from_shipment(v_ship, 'CARRIER-INV-1', null, null, null, null, null);
      v_steps := v_steps || jsonb_build_object('door', 'erp_bill_from_shipment', 'person', 'clerk');
      v_subs := v_subs || s_bill;
    exception when others then
      v_block := format('press %s: %s', jsonb_array_length(v_steps) + 1, left(sqlerrm, 300));
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_out := jsonb_build_object(
      'roles_in_force', coalesce((v_r1 ->> 'in_force')::boolean and (v_r2 ->> 'in_force')::boolean
                                 and (v_r3 ->> 'in_force')::boolean, false),
      'live', erp.tenant_is_live(r.tenant_id),
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'administrators_pressing', (select count(*) from erp.organisation_administrators() a
                                   where a.app_user_id in (p_plan, p_drive, p_bill)),
      'booked_in_one', v_booked = 'booked',
      'needs_a_person', v_need,
      'offered_to_the_driver', coalesce(v_offer, false),
      'offered_to_the_clerk', coalesce(v_offer3, false),
      'state', erp.object_current_state('document', v_doc),
      'status_after', (select sh.status::text from erp.shipment sh where sh.id = v_ship),
      'bill_state', erp.object_current_state('document', v_bill),
      'blocked', v_block,
      'steps', v_steps);

    raise exception using message = c_undo;
  exception when others then
    if sqlerrm <> c_undo then
      v_out := jsonb_build_object('presses', 0, 'people', 0, 'blocked',
                 'setting up: ' || left(sqlerrm, 300), 'steps', v_steps);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$$;

revoke all on function erp_test.despatch_walk() from public, anon, authenticated;

-- The LPR3 suite pinned logistics at version 3, the version it shipped; it
-- reads the installer's current version now.
do $pin$
declare
  v_sig  constant text := 'erp_test.despatch_exceptions_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$                where i.tenant_id = r.tenant_id and i.install_code = 'logistics') = 3;
$o$;
  v_new  constant text := $n$                where i.tenant_id = r.tenant_id and i.install_code = 'logistics')
              = (select mi.current_version from erp_ref.module_installer mi where mi.install_code = 'logistics');
$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$pin$;

do $walk$
declare
  v_sig  constant text := 'erp_test.step_budget_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  case_name := 'despatch is two presses by a planner and a driver who are not administrators, ship and prove, booked in the first and needing nobody else';
$o$,
    $n$  case_name := 'despatch is three presses by a planner, a driver and a clerk who are not administrators, ship, prove and bill, booked in the first and needing nobody else';
$n$,
    $o$            and (v_desp ->> 'presses')::integer = 2
            and (v_desp ->> 'people')::integer = 2
$o$,
    $n$            and (v_desp ->> 'presses')::integer = 3
            and (v_desp ->> 'people')::integer = 3
            and (v_desp ->> 'offered_to_the_clerk')::boolean
            and v_desp ->> 'bill_state' = 'registered'
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$walk$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E2. The suites that count the chart
--
-- A company configured from now on has one account more, 7200 carriage
-- outwards, from the finance installer or, under §8.1, from the pack. The
-- chart alternative suite (22 accounts), the companies suite (a second
-- company's 17) and the demonstration chart suite (22) are re-pinned
-- deliberately to 23, 18 and 23, as 20260929300000 re-pinned them for 7900.
-- Each keeps its cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $counts$
declare
  r      record;
  v_def  text;
  n      integer;
begin
  for r in
    select * from (values
      ('erp_test.chart_alternative_suite()', array[
         $o$(select count(*) from erp.account a where a.tenant_id = v_t) = 22,  -- Re-pinned by 20260929300000: 7900.$o$,
         $n$(select count(*) from erp.account a where a.tenant_id = v_t) = 23,  -- Re-pinned by 20261004000000: 7200.$n$,
         $o$(select count(*) from erp.account a where a.tenant_id = v_t) = 22,  -- and here.$o$,
         $n$(select count(*) from erp.account a where a.tenant_id = v_t) = 23,  -- and here.$n$]),
      ('erp_test.companies_suite()', array[
         $o$        and v_m = 17  -- Re-pinned by 20260929300000: 7900.
$o$,
         $n$        and v_m = 18  -- Re-pinned by 20261004000000: 7200.
$n$,
         $o$%s account(s) (expected 17)$o$,
         $n$%s account(s) (expected 18)$n$]),
      ('erp_test.demo_chart_suite()', array[
         $o$where a.tenant_id = d.tenant_id) = 22  -- Re-pinned by 20260929300000: 7900.
$o$,
         $n$where a.tenant_id = d.tenant_id) = 23  -- Re-pinned by 20261004000000: 7200.
$n$,
         $o$e.code = 'ACME') = 22$o$,
         $n$e.code = 'ACME') = 23$n$])
    ) v(sig, pairs)
  loop
    v_def := pg_get_functiondef(r.sig::regprocedure);
    if position('Re-pinned by 20261004000000' in v_def) > 0 then
      raise notice '% already counts 7200; left as it is', r.sig;
      continue;
    end if;
    for i in 1 .. array_length(r.pairs, 1) / 2 loop
      n := (length(v_def) - length(replace(v_def, r.pairs[2 * i - 1], ''))) / length(r.pairs[2 * i - 1]);
      if n <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % count anchor % found % time(s)', r.sig, i, n;
      end if;
      v_def := replace(v_def, r.pairs[2 * i - 1], r.pairs[2 * i]);
    end loop;
    execute v_def;
  end loop;
end
$counts$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof: erp_test.freight_settlement_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.freight_settlement_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  r       record;
  v_fx    jsonb;
  v_dn    uuid[];
  v_s1 uuid; v_s2 uuid; v_s3 uuid;
  v_b1 uuid; v_b2 uuid;
  v_err   text;
  v_cost  bigint;
  v_ok    boolean;
  v_x     uuid;
  v_task  uuid;
  v_n     integer;
  v_carrier_party uuid;
begin
  begin
    v_step := 'an organisation configured as the demonstration is, with three delivered shipments';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zzfs-' || v_tag, 'Freight settlement suite', 'admin@zzfs-' || v_tag || '.test', 'Freight Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzfs-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    v_fx := erp_test.despatch_fixture(r.tenant_id, r.entity_id, v_tag, 4);
    select array_agg(x::uuid order by o) into v_dn
      from jsonb_array_elements_text(v_fx -> 'deliveries') with ordinality as t(x, o);
    v_s1 := erp.ship_deliveries(array[v_dn[1]]);
    v_s2 := erp.ship_deliveries(array[v_dn[2]]);
    v_s3 := erp.ship_deliveries(array[v_dn[3]]);
    perform erp.record_proof_of_delivery(v_s1, now(), 'A. Customer', null);
    perform erp.record_proof_of_delivery(v_s2, now(), 'A. Customer', null);
    select c.party_id into v_carrier_party
      from erp.shipment sh join erp.carrier c on c.id = sh.carrier_id where sh.id = v_s1;

    -- ── 1. The account, in both charts and by upgrade ──────────────────────
    v_cases := v_cases + 1;
    case_name := 'carriage outwards is 7200 in both charts, created by finance and added by the logistics upgrade to a company that lacks it';
    passed := exists (select 1 from erp.account a
                       where a.tenant_id = r.tenant_id and a.code = '7200' and a.account_type = 'expense')
          and exists (select 1 from erp_ref.pack_item pi
                       where pi.pack_code = 'chart_8_1' and pi.object_kind = 'account' and pi.object_key = '7200')
          and exists (select 1 from erp_ref.module_upgrade_account ua
                       where ua.install_code = 'logistics' and ua.to_version = 4 and ua.purpose = 'carriage_outwards')
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = r.tenant_id and i.install_code = 'logistics') = 4;
    detail := 'account, pack item, upgrade account, installer at 4';
    return next;

    -- ── 2. Inside tolerance it registers and posts ─────────────────────────
    v_step := 'billing a delivered shipment at its booked cost';
    v_cost := (select sh.freight_cost_minor from erp.shipment sh where sh.id = v_s1);
    v_b1 := erp.bill_from_shipment(v_s1, 'ROAD-0001', null, 470, null, null, null);
    v_cases := v_cases + 1;
    case_name := 'a carrier''s bill at the booked cost registers and posts the net to 7200, the tax to tax control and the total to trade payable';
    passed := erp.object_current_state('document', v_b1) = 'registered'
          and erp.document_is_purchase_bill(v_b1)
          and (select d.party_id from erp.document d where d.id = v_b1) = v_carrier_party
          and (select coalesce(sum(jl.debit_minor), 0) from erp.journal_line jl
                 join erp.journal j on j.id = jl.journal_id
                 join erp.account a on a.id = jl.account_id
                where j.document_id = v_b1 and a.code = '7200') = v_cost
          and (select coalesce(sum(jl.debit_minor), 0) from erp.journal_line jl
                 join erp.journal j on j.id = jl.journal_id
                 join erp.account a on a.id = jl.account_id
                where j.document_id = v_b1 and a.code = erp.chart_account_code('tax_control')) = 470
          and (select coalesce(sum(jl.credit_minor), 0) from erp.journal_line jl
                 join erp.journal j on j.id = jl.journal_id
                 join erp.account a on a.id = jl.account_id
                where j.document_id = v_b1 and a.code = erp.chart_account_code('trade_payable')) = v_cost + 470;
    detail := format('%s, booked at %s', erp.object_current_state('document', v_b1), v_cost);
    return next;

    -- ── 3. Once ────────────────────────────────────────────────────────────
    v_step := 'billing the same shipment again';
    v_err := null;
    begin perform erp.bill_from_shipment(v_s1, 'ROAD-0001B', null, null, null, null, null);
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a shipment is billed once, and leaves the list of shipments to bill when it is';
    passed := v_err like 'CLOVEERP_SHIPMENT_ALREADY_BILLED:%'
          and not exists (select 1 from jsonb_array_elements(public.erp_shipments_to_bill()) s
                           where (s ->> 'shipment_id')::uuid = v_s1)
          and exists (select 1 from jsonb_array_elements(public.erp_shipments_to_bill()) s
                       where (s ->> 'shipment_id')::uuid = v_s2);
    detail := coalesce(left(v_err, 200), 'billed twice');
    return next;

    -- ── 4. Not before it is delivered ──────────────────────────────────────
    v_step := 'billing a shipment still booked';
    v_err := null;
    begin perform erp.bill_from_shipment(v_s3, 'ROAD-0003', null, null, null, null, null);
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a shipment not yet delivered cannot be billed';
    passed := v_err like 'CLOVEERP_SHIPMENT_NOT_DELIVERED:%';
    detail := coalesce(left(v_err, 200), 'billed');
    return next;

    -- ── 5. Outside tolerance it lands disputed ─────────────────────────────
    v_step := 'billing a shipment well above its booked cost';
    v_b2 := erp.bill_from_shipment(v_s2, 'ROAD-0002', 999999, null, null, null, null);
    select x.id into v_x from erp.match_exception x
     where x.tenant_id = r.tenant_id and x.invoice_document_id = v_b2 and x.resolved_at is null;
    v_cases := v_cases + 1;
    case_name := 'a bill above the booked cost by more than the tolerance registers disputed, with a match exception naming the shipment on the workbench';
    passed := erp.object_current_state('document', v_b2) = 'disputed'
          and (select x.shipment_id from erp.match_exception x where x.id = v_x) = v_s2
          and (select x.order_line_id from erp.match_exception x where x.id = v_x) is null
          and exists (select 1 from erp.match_exception_workbench() w
                       where w.exception_id = v_x
                         and w.order_number = (select d.document_number from erp.document d
                                                 join erp.shipment sh on sh.document_id = d.id
                                                where sh.id = v_s2));
    detail := format('%s, exception %s', erp.object_current_state('document', v_b2), v_x);
    return next;

    -- ── 6. Accepted after approval, it is payable ──────────────────────────
    v_step := 'approving and accepting the difference';
    select t.id into v_task from erp.approval_task t
      join erp.match_exception x on x.approval_request_id = t.approval_request_id
     where x.id = v_x and t.status = 'pending'
     order by t.created_at limit 1;
    if v_task is not null then
      perform erp.decide_approval_task(v_task, true, 'the carrier added a waiting charge');
    end if;
    perform erp.accept_match_exception(v_x, 'waiting charge agreed');
    v_cases := v_cases + 1;
    case_name := 'accepted after its approval on the same workbench, the carrier''s bill returns to registered';
    passed := v_task is not null
          and erp.object_current_state('document', v_b2) = 'registered'
          and (select x.resolved_at is not null from erp.match_exception x where x.id = v_x);
    detail := format('task %s; the bill %s', v_task, erp.object_current_state('document', v_b2));
    return next;

    -- ── 7. The VAT return reads it ─────────────────────────────────────────
    v_step := 'reading the VAT entries';
    v_cases := v_cases + 1;
    case_name := 'the tax on a carrier''s bill is input tax on the VAT return';
    passed := exists (select 1 from erp.vat_entries(r.entity_id, current_date - 1, current_date + 1) v
                       where v.document_id = v_b1 and v.side = 'purchase' and v.tax_minor = 470);
    detail := 'box 4 carries it';
    return next;

    -- ── 8. A payment run pays it ───────────────────────────────────────────
    v_step := 'proposing a payment run';
    v_cases := v_cases + 1;
    case_name := 'a payment run proposes the carrier''s bills like any supplier''s';
    v_x := erp.propose_payment_run(current_date, null, interval '60 days');
    passed := exists (select 1 from erp.payment_proposal_line l
                       where l.tenant_id = r.tenant_id and l.payment_proposal_id = v_x and l.document_id = v_b1);
    detail := format('proposal %s', v_x);
    return next;

    -- ── 9. Despatch is three presses ───────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'despatch is declared at three presses, Bill from shipment the third';
    select b.budget into v_n from erp_meta.flow_budget b where b.flow_code = 'despatch';
    passed := v_n = 3
          and exists (select 1 from erp.flow_step_budget_report(null) f
                       where f.flow_code = 'despatch' and f.verdict = 'within');
    detail := format('budget %s', v_n);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_FREIGHT_SETTLEMENT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzfs-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_FREIGHT_SETTLEMENT_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.freight_settlement_suite() from public, anon, authenticated;

create or replace function erp_test.assert_freight_settlement_suite()
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
    from erp_test.freight_settlement_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_FREIGHT_SETTLEMENT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A carrier''s bill posts somewhere other than carriage outwards, pays twice, or a difference outside the tolerance is not disputed. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_FREIGHT_SETTLEMENT_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('freight settlement: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_freight_settlement_suite() from public, anon;

comment on function erp_test.assert_freight_settlement_suite() is
  'A carrier''s bill is born from a delivered shipment, posts to carriage outwards, is billed once, and '
  'a difference outside the shipping policy''s tolerance is disputed and cleared on the match workbench '
  '(20261004000000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The words the Despatch screen adds
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, module_code, description)
select erp_ref.ui_key(v.text), 'en', v.text, 'logistics',
       'A screen string of the Despatch screen (20261004000000).'
  from (values
    ('Carrier''s bill'),
    ('Delivered shipments the carrier has not billed yet. Bill from shipment meets their bill against what the shipment was booked at.'),
    ('Shipments appear here once they are delivered.'),
    ('Bill from shipment'),
    ('Enter the carrier''s bill for a delivered shipment. It is met against what the shipment was booked at; a bill outside the shipping policy''s tolerance lands disputed on the match workbench.'),
    ('Their reference'),
    ('The carrier''s own invoice number.'),
    ('Amount'),
    ('Leave empty when the bill is for what the shipment was booked at.'),
    ('VAT'),
    ('The VAT on the carrier''s bill, if they charged it.'),
    ('Bill date')
  ) as v(text)
on conflict do nothing;

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
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
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
select erp.assert_parameter_budget();
