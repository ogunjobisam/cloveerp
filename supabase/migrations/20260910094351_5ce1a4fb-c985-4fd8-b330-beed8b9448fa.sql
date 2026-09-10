-- ═════════════════════════════════════════════════════════════════════════════
-- A posting rule names the chart this organisation actually has
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.chart_account_code() answers from the purpose register: the code an
-- account would wear in a chart installed today. Organisations configured
-- before that register existed wear different numbers — on the demonstration
-- company 2100 is the bank, not goods-received-not-invoiced — so a rule built
-- from the register alone would have debited a supplier's bill to the bank.
-- Nothing would have failed; the accounts would simply have been wrong, which
-- is the worse of the two outcomes.

create or replace function erp.tenant_account_code(p_purpose text)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_kind   text;
  v_name   text;
  v_code   text;
begin
  select cap.control_kind::text, cap.name into v_kind, v_name
    from erp_ref.chart_account_purpose cap where cap.purpose = p_purpose;
  if v_name is null then
    raise exception 'CLOVEERP_UNKNOWN_ACCOUNT_PURPOSE: %', p_purpose using errcode = '23503',
      hint = 'The purposes are listed in erp_ref.chart_account_purpose.';
  end if;

  -- A control account is identified by what it controls, whatever it is
  -- numbered.
  if v_kind is not null then
    select a.code into v_code from erp.account a
     where a.tenant_id = v_tenant and a.control_kind::text = v_kind
       and a.status = 'active' and a.is_postable
     order by a.code limit 1;
    if v_code is not null then return v_code; end if;
  end if;

  -- Goods-received-not-invoiced controls nothing, so it is found by its name
  -- before falling back to the number a chart installed today would use.
  select a.code into v_code from erp.account a
   where a.tenant_id = v_tenant and a.status = 'active' and a.is_postable
     and lower(a.name) = lower(v_name)
   order by a.code limit 1;

  return coalesce(v_code, erp.chart_account_code(p_purpose));
end;
$$;

comment on function erp.tenant_account_code(text) is
  'The code an account wears in THIS organisation''s chart, found by what it '
  'controls and then by its name, falling back to the purpose register. Used '
  'by installers so a promoted rule names accounts that exist here.';

create or replace function erp.configure_procurement_controls(
  p_approver_role text default 'administrator',
  p_over_receipt_pct numeric default 5,
  p_price_variance_pct numeric default 2,
  p_price_variance_minor bigint default 100
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
  v_grni   text := erp.tenant_account_code('goods_received_not_invoiced');
  v_ap     text := erp.tenant_account_code('trade_payable');
  v_bank   text := erp.tenant_account_code('bank');
begin
  v_cs := erp.install_module_config(
    'procurement-controls', 'Procurement controls',
    'What may be received against an order, what may be invoiced against a '
    'receipt, who has to look when neither agrees, and how the supplier is paid.',
    jsonb_build_array(
      jsonb_build_object('kind','approval_chain','key','match_exception','payload',
        jsonb_build_object(
          'code','match_exception','name','Invoice match exception',
          'object_type','match_exception',
          'applies_when','true'::jsonb, 'priority',100,
          'material_fields', jsonb_build_array('quantity_variance','price_variance_minor'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer','name','Buyer',
              'approver_kind','role','role',p_approver_role,'min_approvals',1)))),

      jsonb_build_object('kind','receipt_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default receipt tolerance',
          'over_pct', p_over_receipt_pct,
          'under_pct', 100,
          'over_action','accept')),

      jsonb_build_object('kind','match_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default match tolerance',
          'quantity_pct', 0,
          'price_pct', p_price_variance_pct,
          'price_absolute_minor', p_price_variance_minor,
          'approval_chain','match_exception')),

      jsonb_build_object('kind','state_machine','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','object_type','document','name','Purchase invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','registered','name','Registered','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','disputed','name','Disputed','sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','register','name','Register','from','draft','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','dispute','name','Dispute','from','registered','to','disputed','required_permission','procurement.match'),
            jsonb_build_object('code','resolve','name','Resolve','from','disputed','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','pay','name','Record payment','from','registered','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.match')))),

      jsonb_build_object('kind','posting_rule','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','name','Purchase invoice','ledger','GL',
          'event_type','document.purchase_invoice.registered',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', v_grni,'side','debit','rate',1,
                               'description','Clearing goods received not invoiced'),
            jsonb_build_object('account', v_ap,'side','credit','rate',1,
                               'description','Trade payable')))),

      jsonb_build_object('kind','posting_rule','key','supplier_payment','payload',
        jsonb_build_object(
          'code','supplier_payment','name','Supplier payment','ledger','GL',
          'event_type','payment.made',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account', v_ap,'side','debit','rate',1,
                               'description','Paid to the supplier'),
            jsonb_build_object('account', v_bank,'side','credit','rate',1,
                               'description','Bank'))))));

  insert into erp.numbering_rule (
    tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  select v_tenant, 'purchase_invoice', e.id, 'PINV-', 6, 'yearly', 1
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
    order by e.code limit 1
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, numbering_rule_id, posting_rule_code)
  select v_tenant, 'purchase_invoice', 'invoice_reference', 'Purchase invoice',
         n.entity_id, 'purchase_invoice', n.id, 'purchase_invoice'
    from erp.numbering_rule n
   where n.tenant_id = v_tenant and n.code = 'purchase_invoice'
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        numbering_rule_id = excluded.numbering_rule_id,
        posting_rule_code = excluded.posting_rule_code;

  return v_cs;
end;
$$;

select erp.apply_execute_grants();

select erp_test.assert_supplier_bill_suite();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
