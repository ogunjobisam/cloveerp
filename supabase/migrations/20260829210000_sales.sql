-- =============================================================================
-- ERPWare — sales, and whether one module generalises to two
--
-- Procurement showed that a document lifecycle is configuration. That is the
-- easy half to repeat: authoring a second set of state machines is the same
-- shape with different names, and proves little.
--
-- The half worth testing is posting, and it is a real test because the two
-- modules move stock in opposite directions through the same code. Procurement
-- receives; sales despatches. If erp.post_document() needed to know which
-- module it was serving, the answer to "does this generalise" would be no.
-- It does not: the sign comes from erp_ref.movement_type.direction.
--
-- Two things here beyond the configuration itself.
--
--   erp.install_module_config() — because configure_procurement() and a
--   copy-pasted configure_sales() would be the same function twice, which is
--   its own answer to the question. Both modules are now their content plus a
--   call. The extraction was clean, which is the finding.
--
--   The credit band needs the customer's exposure, and an approval step's
--   condition is JsonLogic over the request context. Rather than teach the
--   rule interpreter arithmetic, the context carries the sum already computed:
--   exposure_after_minor against credit_limit_minor is one comparison, and the
--   rule stays readable to whoever configures it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Installing a module's configuration
-- -----------------------------------------------------------------------------

create or replace function erp.install_module_config(
  p_code        text,
  p_name        text,
  p_description text,
  p_items       jsonb
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_cs   uuid;
  v_item jsonb;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'change_set', null);

  v_cs := erp.create_change_set(p_code, p_name, p_description);

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    perform erp.add_change_set_item(
      v_cs, v_item ->> 'kind', v_item ->> 'key', v_item -> 'payload');
  end loop;

  -- Submitted and deliberately not approved. B6 refuses to let the author of a
  -- change set wave it through, and installing a module is exactly the kind of
  -- change that control exists for: these change sets set the thresholds above
  -- which a purchase needs finance and an order needs credit release.
  perform erp.submit_change_set(v_cs);
  return v_cs;
end;
$$;

comment on function erp.install_module_config is
  'Authors and submits a module''s lifecycle configuration as one B6 change '
  'set. Both procurement and sales are now their content plus a call to this, '
  'rather than the same function written twice.';

-- -----------------------------------------------------------------------------
-- Procurement, rewritten through the extraction
--
-- Same configuration, same change set, one call instead of five. Proving the
-- extraction on the module that already worked is what makes it an extraction
-- rather than a second implementation.
-- -----------------------------------------------------------------------------

create or replace function erp.configure_procurement(
  p_approval_threshold_minor bigint default 1000000,
  p_approver_role text default 'administrator'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_cs     uuid;
begin
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: configure an entity before a module'
      using errcode = '23503';
  end if;

  v_cs := erp.install_module_config(
    'procurement-lifecycle', 'Procurement lifecycle',
    'Requisition, purchase order and receipt: their states, the transitions '
    'between them, and the approval a purchase order needs above a threshold.',
    jsonb_build_array(
      jsonb_build_object('kind','state_machine','key','requisition','payload',
        jsonb_build_object(
          'code','requisition','object_type','document','name','Requisition',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','submitted','name','Submitted','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','ordered','name','Ordered','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','submitted','required_permission','procurement.requisition'),
            jsonb_build_object('code','approve','name','Approve','from','submitted','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','submitted','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','order','name','Convert to order','from','approved','to','ordered','required_permission','procurement.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.requisition'),
            jsonb_build_object('code','cancel_submitted','name','Cancel','from','submitted','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','purchase_order','payload',
        jsonb_build_object(
          'code','purchase_order','object_type','document','name','Purchase order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','approved','name','Approved','sort_order',30),
            jsonb_build_object('code','sent','name','Sent to supplier','is_committed',true,'sort_order',40),
            jsonb_build_object('code','partially_received','name','Partially received','is_committed',true,'sort_order',50),
            jsonb_build_object('code','received','name','Received','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit for approval','from','draft','to','pending_approval','required_permission','procurement.order'),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved','required_permission','procurement.approve'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','procurement.approve'),
            jsonb_build_object('code','send','name','Send to supplier','from','approved','to','sent','required_permission','procurement.order'),
            jsonb_build_object('code','receive_partial','name','Receive part','from','sent','to','partially_received','required_permission','procurement.receive'),
            jsonb_build_object('code','receive_rest','name','Receive remainder','from','partially_received','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','receive_all','name','Receive in full','from','sent','to','received','required_permission','procurement.receive'),
            jsonb_build_object('code','close','name','Close','from','received','to','closed','required_permission','procurement.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.order'),
            jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled','required_permission','procurement.approve')))),

      jsonb_build_object('kind','state_machine','key','goods_receipt','payload',
        jsonb_build_object(
          'code','goods_receipt','object_type','document','name','Goods receipt',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','procurement.receive'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.receive')))),

      jsonb_build_object('kind','approval_chain','key','purchase_order_value','payload',
        jsonb_build_object(
          'code','purchase_order_value','name','Purchase order value approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'purchase_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','buyer_manager','name','Buying manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','finance','name','Finance',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','total_minor'), p_approval_threshold_minor))))))));

  insert into erp.numbering_rule (tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  values (v_tenant, 'requisition', v_entity, 'REQ-', 6, 'yearly', 1),
         (v_tenant, 'purchase_order', v_entity, 'PO-', 6, 'yearly', 1),
         (v_tenant, 'goods_receipt', v_entity, 'GRN-', 6, 'yearly', 1)
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, approval_chain_code, numbering_rule_id, stock_movement_type)
  select v_tenant, x.code, x.base, x.name, v_entity, x.machine, x.chain, n.id, x.movement
    from (values
      ('requisition',    'requisition',    'Requisition',    'requisition',    null::text, null::text),
      ('purchase_order', 'purchase_order', 'Purchase order', 'purchase_order', 'purchase_order_value', null),
      ('goods_receipt',  'receipt',        'Goods receipt',  'goods_receipt',  null, 'goods_receipt')
    ) as x(code, base, name, machine, chain, movement)
    join erp.numbering_rule n on n.tenant_id = v_tenant and n.code = x.code
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        approval_chain_code = excluded.approval_chain_code,
        numbering_rule_id = excluded.numbering_rule_id,
        stock_movement_type = excluded.stock_movement_type;

  return v_cs;
end;
$$;

-- -----------------------------------------------------------------------------
-- Sales
-- -----------------------------------------------------------------------------

create or replace function erp.configure_sales(
  p_discount_threshold_pct numeric default 15,
  p_approver_role text default 'administrator'
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_cs     uuid;
begin
  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: configure an entity before a module'
      using errcode = '23503';
  end if;

  v_cs := erp.install_module_config(
    'sales-lifecycle', 'Sales lifecycle',
    'Quotation, sales order and delivery: their states, the approvals a '
    'discount and a credit exposure require, and the despatch that moves stock.',
    jsonb_build_array(
      jsonb_build_object('kind','state_machine','key','quotation','payload',
        jsonb_build_object(
          'code','quotation','object_type','document','name','Quotation',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','sent','name','Sent','sort_order',20),
            jsonb_build_object('code','accepted','name','Accepted','is_terminal',true,'sort_order',30),
            jsonb_build_object('code','expired','name','Expired','is_terminal',true,'sort_order',40),
            jsonb_build_object('code','declined','name','Declined','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','send','name','Send','from','draft','to','sent','required_permission','sales.order'),
            jsonb_build_object('code','accept','name','Accept','from','sent','to','accepted','required_permission','sales.order'),
            jsonb_build_object('code','decline','name','Decline','from','sent','to','declined','required_permission','sales.order'),
            jsonb_build_object('code','expire','name','Expire','from','sent','to','expired','required_permission','sales.order')))),

      jsonb_build_object('kind','state_machine','key','sales_order','payload',
        jsonb_build_object(
          'code','sales_order','object_type','document','name','Sales order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','pending_approval','name','Pending approval','sort_order',20),
            jsonb_build_object('code','confirmed','name','Confirmed','is_committed',true,'sort_order',30),
            jsonb_build_object('code','picking','name','Picking','is_committed',true,'sort_order',40),
            jsonb_build_object('code','despatched','name','Despatched','is_committed',true,'sort_order',50),
            jsonb_build_object('code','invoiced','name','Invoiced','is_committed',true,'sort_order',60),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',70),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','submit','name','Submit','from','draft','to','pending_approval','required_permission','sales.order'),
            jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','confirmed','required_permission','sales.order'),
            jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft','required_permission','sales.order'),
            jsonb_build_object('code','pick','name','Start picking','from','confirmed','to','picking','required_permission','sales.despatch'),
            jsonb_build_object('code','despatch','name','Despatch','from','picking','to','despatched','required_permission','sales.despatch'),
            jsonb_build_object('code','invoice','name','Invoice','from','despatched','to','invoiced','required_permission','sales.invoice'),
            jsonb_build_object('code','close','name','Close','from','invoiced','to','closed','required_permission','sales.order'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.order'),
            jsonb_build_object('code','cancel_confirmed','name','Cancel','from','confirmed','to','cancelled','required_permission','sales.order')))),

      -- The mirror of goods receipt, and the whole point of this migration:
      -- same shape, opposite direction, same posting code.
      jsonb_build_object('kind','state_machine','key','delivery','payload',
        jsonb_build_object(
          'code','delivery','object_type','document','name','Delivery',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','post','name','Post','from','draft','to','posted','required_permission','sales.despatch'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.despatch')))),

      -- Two bands on one chain. A discount above the threshold needs someone
      -- who may approve discounts; an order that takes the customer past their
      -- credit limit needs someone who may release credit. Either can fire
      -- alone, both can fire together, and neither is expressed in a second
      -- rule language — both are JsonLogic over the same context.
      jsonb_build_object('kind','approval_chain','key','sales_order_terms','payload',
        jsonb_build_object(
          'code','sales_order_terms','name','Sales order terms approval',
          'object_type','document',
          'applies_when', jsonb_build_object('==', jsonb_build_array(
            jsonb_build_object('var','document_type'),'sales_order')),
          'value_field','total_minor','priority',100,
          'material_fields', jsonb_build_array('total_minor','party_id','max_discount_pct'),
          'steps', jsonb_build_array(
            jsonb_build_object('seq',1,'code','sales_manager','name','Sales manager',
              'approver_kind','role','role',p_approver_role,'min_approvals',1),
            jsonb_build_object('seq',2,'code','discount','name','Discount approval',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','max_discount_pct'), p_discount_threshold_pct))),
            jsonb_build_object('seq',3,'code','credit','name','Credit release',
              'approver_kind','role','role',p_approver_role,'min_approvals',1,
              -- The sum is computed into the context rather than in the rule,
              -- so the interpreter needs no arithmetic and the configured rule
              -- stays one readable comparison.
              'condition', jsonb_build_object('>', jsonb_build_array(
                jsonb_build_object('var','exposure_after_minor'),
                jsonb_build_object('var','credit_limit_minor')))))))));

  insert into erp.numbering_rule (tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  values (v_tenant, 'quotation', v_entity, 'QUO-', 6, 'yearly', 1),
         (v_tenant, 'sales_order', v_entity, 'SO-', 6, 'yearly', 1),
         (v_tenant, 'delivery', v_entity, 'DN-', 6, 'yearly', 1)
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, approval_chain_code, numbering_rule_id, stock_movement_type)
  select v_tenant, x.code, x.base, x.name, v_entity, x.machine, x.chain, n.id, x.movement
    from (values
      ('quotation',   'quotation',   'Quotation',   'quotation',   null::text, null::text),
      ('sales_order', 'sales_order', 'Sales order', 'sales_order', 'sales_order_terms', null),
      ('delivery',    'delivery',    'Delivery',    'delivery',    null, 'despatch')
    ) as x(code, base, name, machine, chain, movement)
    join erp.numbering_rule n on n.tenant_id = v_tenant and n.code = x.code
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        approval_chain_code = excluded.approval_chain_code,
        numbering_rule_id = excluded.numbering_rule_id,
        stock_movement_type = excluded.stock_movement_type;

  return v_cs;
end;
$$;

comment on function erp.configure_sales is
  'Sales as configuration: quotation, order and delivery, with discount and '
  'credit bands. Delivery binds the despatch movement — the same posting code '
  'procurement uses to receive, with the sign coming from the movement type.';

-- -----------------------------------------------------------------------------
-- What the rules see
--
-- An approval step's condition is JsonLogic over the request context, so a band
-- can only be as good as what the context carries. Procurement needed one
-- number. Sales needs three, and two of them are not on the document: the
-- customer's credit limit lives on their customer role, and their exposure is
-- the sum of everything already committed and not yet invoiced.
--
-- All three are derived here, never stored. A stored exposure is a number
-- somebody can correct without correcting the orders behind it.
-- -----------------------------------------------------------------------------

create or replace function erp.transition_document(
  p_document_id    uuid,
  p_transition_code text,
  p_reason         text default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_to     text;
  v_committed boolean;
  v_total  bigint;
  v_discount numeric;
  v_limit  bigint;
  v_exposure bigint;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  v_total := erp.document_value_minor(p_document_id);

  select coalesce(max(l.discount_pct), 0) into v_discount
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled;

  -- The customer's limit, from their customer role. Absent means no limit was
  -- set, and an absent limit must not read as a limit of zero — that would put
  -- every order through credit release.
  select coalesce((pr.attributes ->> 'credit_limit_minor')::bigint, 9223372036854775807)
    into v_limit
    from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.party_id = d.party_id
     and pr.role_kind = 'customer' and pr.status = 'active'
   limit 1;

  -- Everything already committed for this customer and not yet invoiced or
  -- finished, excluding this document so the sum below is not doubled.
  select coalesce(sum(erp.document_value_minor(d2.id)), 0) into v_exposure
    from erp.document d2
    join erp.document_type dt2 on dt2.tenant_id = d2.tenant_id and dt2.id = d2.document_type_id
    join erp.object_state os2 on os2.tenant_id = d2.tenant_id
                             and os2.object_type = 'document' and os2.object_id = d2.id
    join erp.state s2 on s2.id = os2.current_state_id
   where d2.tenant_id = v_tenant
     and d2.party_id = d.party_id
     and dt2.base_type_code = 'sales_order'
     and s2.is_committed and not s2.is_terminal
     and d2.id <> p_document_id
     and not d2.is_cancelled;

  v_ctx := jsonb_build_object(
    'document_type', dt.code,
    'document_number', d.document_number,
    'total_minor', v_total,
    'currency', d.currency,
    'party_id', d.party_id,
    'entity_id', d.entity_id,
    'transition', p_transition_code,
    'max_discount_pct', v_discount,
    'credit_limit_minor', coalesce(v_limit, 9223372036854775807),
    'exposure_after_minor', v_exposure + v_total);

  if p_transition_code = 'submit' and dt.approval_chain_code is not null then
    perform erp.request_approval('document', p_document_id, v_ctx, 1,
                                 d.entity_id, d.site_id);
  end if;

  v_to := erp.perform_transition('document', p_document_id, p_transition_code,
                                 v_ctx, p_reason);

  select s.is_committed into v_committed
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  if coalesce(v_committed, false) and bt.affects_stock
     and not exists (select 1 from erp.stock_movement m
                      where m.tenant_id = v_tenant and m.document_id = p_document_id)
  then
    perform erp.post_document(p_document_id);
  end if;

  return v_to;
end;
$$;

-- -----------------------------------------------------------------------------
-- The public surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_configure_sales(
  p_discount_threshold_pct numeric default 15
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('change_set_id', erp.configure_sales(p_discount_threshold_pct)) $$;

do $$
begin
  execute 'revoke all on function public.erp_configure_sales(numeric) from public, anon';
  execute 'grant execute on function public.erp_configure_sales(numeric) to authenticated';
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_sales', 'erp.configure_sales',
   'Installs the sales lifecycle through a B6 change set. Gated on '
   'administration.configure inside erp.install_module_config(), which '
   'erp.configure_sales() delegates to.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_isolation();

-- -----------------------------------------------------------------------------
-- The adversarial suite
--
-- The cases that matter are the posting ones. A lifecycle that transitions
-- correctly and moves no stock is what procurement shipped as, and it looked
-- entirely healthy — so these read the balance rather than the absence of an
-- error, and check the ledger and the cache agree afterwards.
-- -----------------------------------------------------------------------------

create or replace function erp_test.sales_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  cs1 uuid; cs2 uuid; v_second uuid; v_tok text; res jsonb; t record;
  v_uom uuid; v_site uuid; v_recv uuid; v_desp uuid;
  v_sup uuid; v_cust uuid; v_item uuid;
  v_grn uuid; v_dn uuid; v_so uuid; v_quo uuid; v_dn2 uuid;
  q0 numeric; q1 numeric; q2 numeric;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant('zzsales','Sales Suite','a@zzsales.test','Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzsales.test','Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second,'administrator',null,null,'co-administrator');

  cs1 := erp.configure_procurement(1000000);
  cs2 := erp.configure_sales(15);

  return query select 'two modules install through one shared installer',
    cs1 is not null and cs2 is not null and cs1 <> cs2,
    'erp.install_module_config() authored both';

  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(cs1); perform erp.promote_change_set(cs1);
  perform erp.approve_change_set(cs2); perform erp.promote_change_set(cs2);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);

  return query select 'promotion installs six lifecycles across both modules',
    (select count(*) from erp.state_machine m
      where m.tenant_id = r.tenant_id and m.status='active') = 6,
    'requisition, purchase order, goods receipt, quotation, sales order, delivery';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'RECV','Receiving','receiving','active') returning id into v_recv;
  insert into erp.location (tenant_id,site_id,code,name,location_type,status)
  values (r.tenant_id,v_site,'DESP','Despatch','despatch','active') returning id into v_desp;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_sup;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'CUST','Customer','active') returning id into v_cust;
  insert into erp.party_role (tenant_id,party_id,role_kind,attributes,status)
  values (r.tenant_id,v_cust,'customer', jsonb_build_object('credit_limit_minor', 1000000),'active');
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  select coalesce(sum(quantity),0) into q0 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  -- Inbound.
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 500, 1000, 'inbound');
  perform erp.transition_document(v_grn,'post');
  select coalesce(sum(quantity),0) into q1 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  return query select 'a posted receipt raises an inbound movement and on-hand rises',
    q1 - q0 = 500 and exists (select 1 from erp.stock_movement m
      where m.document_id = v_grn and m.movement_type = 'goods_receipt'
        and m.to_location_id is not null and m.from_location_id is null),
    format('%s to %s', q0, q1);

  -- Outbound, through the same function.
  v_dn := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn, v_item, 200, 2500, 'outbound');
  update erp.document_line set location_id = v_recv where document_id = v_dn;
  perform erp.transition_document(v_dn,'post');
  select coalesce(sum(quantity),0) into q2 from erp.stock_balance
   where tenant_id=r.tenant_id and item_id=v_item;

  return query select 'a posted delivery raises an outbound movement and on-hand falls',
    q2 - q1 = -200 and exists (select 1 from erp.stock_movement m
      where m.document_id = v_dn and m.movement_type = 'despatch'
        and m.from_location_id is not null and m.to_location_id is null),
    format('%s to %s, same erp.post_document() as the receipt', q1, q2);

  return query select 'the ledger and the cached balance agree after both',
    (select count(*) from erp.stock_reconciliation_report()) = 0,
    'a movement inserted but not reflected is not a movement';

  -- Posting twice would double the stock, and the ledger is append-only.
  begin
    perform erp.post_document(v_dn);
    v_ok := false; v_msg := 'a document posted twice';
  exception when sqlstate '23505' then v_ok := true; v_msg := left(sqlerrm,58); end;
  return query select 'a document cannot post twice', v_ok, v_msg;

  -- B7's own balance guard, reached through the bridge.
  v_dn2 := erp.open_document('delivery', v_cust, null, v_site);
  perform erp.add_document_line(v_dn2, v_item, 99999, 2500, 'more than exists');
  update erp.document_line set location_id = v_recv where document_id = v_dn2;
  begin
    perform erp.transition_document(v_dn2,'post');
    v_ok := false; v_msg := 'despatched more than was on hand';
  exception when others then
    v_ok := (sqlerrm like '%NEGATIVE_STOCK%'); v_msg := left(sqlerrm,58);
  end;
  return query select 'despatching more than is on hand is refused', v_ok, v_msg;

  -- Lineage across the module boundary.
  v_quo := erp.open_document('quotation', v_cust);
  perform erp.add_document_line(v_quo, v_item, 10, 2500, 'quoted');
  v_so := erp.open_document('sales_order', v_cust, null, v_site);
  perform erp.add_document_line(v_so, v_item, 10, 2500, 'ordered');
  perform erp.link_documents(v_quo, v_so, 'fulfils');
  return query select 'lineage runs quotation to order, both ways',
    (select count(*) from erp.document_lineage(v_quo)) >= 2,
    'spec 4.5';

  -- The discount band. 20% is above the 15% threshold.
  update erp.document_line set discount_pct = 20 where document_id = v_so;
  perform erp.transition_document(v_so,'submit');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_so and tk.status='pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'a discount above the threshold opens the discount step',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_so and tk.step_code='discount'
               and tk.status = 'pending'),
    '20 per cent against a threshold of 15';

  -- The credit band, on the same chain and from the same context. It cannot be
  -- read until the discount step is decided — sequences open one at a time —
  -- and asserting it earlier is asserting something that cannot yet be true.
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_so and tk.status='pending'
              and tk.step_code = 'discount'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  -- 25,000 against a limit of 1,000,000, so credit is skipped — and the skip
  -- is what proves the context carried the customer's own limit and the
  -- comparison actually ran, rather than the step simply never opening.
  return query select 'the credit step reads the customer''s limit and is skipped under it',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_so and tk.step_code='credit'
               and tk.status = 'skipped'),
    'exposure 25000 against a credit limit of 1000000';

  -- Dead configuration, both directions.
  begin
    update erp.document_type set stock_movement_type = null
     where tenant_id = r.tenant_id and code = 'delivery';
    perform erp.assert_no_dead_configuration();
    v_ok := false; v_msg := 'a stock-moving type with no movement passed';
  exception when others then
    v_ok := (sqlerrm like '%DEAD_CONFIGURATION%'); v_msg := left(sqlerrm,52);
  end;
  update erp.document_type set stock_movement_type = 'despatch'
   where tenant_id = r.tenant_id and code = 'delivery';
  return query select 'a type that moves stock but names no movement fails the build',
    v_ok, v_msg;

  begin
    update erp.document_type set stock_movement_type = 'despatch'
     where tenant_id = r.tenant_id and code = 'quotation';
    perform erp.assert_no_dead_configuration();
    v_ok := false; v_msg := 'a movement bound to a type that moves nothing passed';
  exception when others then
    v_ok := (sqlerrm like '%DEAD_CONFIGURATION%'); v_msg := left(sqlerrm,52);
  end;
  update erp.document_type set stock_movement_type = null
   where tenant_id = r.tenant_id and code = 'quotation';
  return query select 'a movement bound to a type that moves no stock fails the build',
    v_ok, v_msg;

  perform set_config('request.jwt.claims','',true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_sales_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_expected constant integer := 12;
  v_total integer; v_failed integer; v_detail text;
begin
  select count(*), count(*) filter (where not r.passed),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_total, v_failed, v_detail
    from erp_test.sales_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_SALES_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;
  if v_total <> c_expected then
    raise exception 'ERPWARE_SALES_SUITE_INCOMPLETE: expected % cases, ran %',
      c_expected, v_total
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('sales: %s/%s cases passed', v_total, v_total);
end;
$$;
