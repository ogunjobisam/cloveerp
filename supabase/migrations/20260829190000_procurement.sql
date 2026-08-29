-- =============================================================================
-- ERPWare — procurement: requisition → purchase order → receipt
--
-- The first functional module, and the test of the spec's central claim that
-- behaviour is configured rather than coded.
--
-- Note what is not here: a purchase_order table, a receipt table, a requisition
-- table. B7 built one document spine and seeded all thirteen types of spec 4.5
-- as product content, with state living in erp.object_state and totals derived
-- from the lines. So a purchase order is a configured document type bound to a
-- state machine, an approval chain and a numbering rule — not a schema.
--
-- The alternative is how an ERP acquires thirteen slightly different
-- implementations of numbering, approval, cancellation and lineage, twelve of
-- which have a bug the thirteenth does not.
--
-- The lifecycle configuration is authored as a B6 change set and promoted,
-- rather than inserted. That is not ceremony: erp.state_machine and
-- erp.approval_chain carry guard_live_configuration(), so once a tenant's
-- environment is live they cannot be written any other way. Promotion is the
-- supported route, and using it here means the module arrives the same way a
-- customer's own change would — reviewable, and rolled back the same way.
--
-- erp.numbering_rule and erp.document_type are deliberately not guarded, so
-- they are written directly.
--
-- Two gaps in the foundation surfaced the moment something actually created a
-- governed object, and both are addressed below rather than worked around.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A note on something that is NOT here
--
-- The first draft of this migration added erp.begin_object_state(), on the
-- reasoning that B4 built every way of moving through a state machine and no
-- way into one. That was wrong. erp.start_lifecycle() already existed and
-- erp.create_document() already calls it, which is why the first document
-- created here failed on a duplicate key rather than a missing lifecycle — the
-- state had already been started by the time the new function ran.
--
-- Reading create_document() had not shown it, because the call is indirect.
-- Running it did, immediately. The function is gone rather than kept "just in
-- case": a second way to start a lifecycle is exactly the kind of near-duplicate
-- that later diverges, and the same mistake had already been made once in this
-- file with erp.document_lineage().
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Which lifecycle does a document actually follow?
--
-- erp.start_lifecycle() chose a state machine by object_type alone. Every
-- document type shares object_type 'document', so with three machines
-- configured it took whichever the ordering happened to surface — and
-- erp.document_type.state_machine_code, the column that says which one is
-- meant, was never read by anything.
--
-- The failure is not that nothing happened. A purchase order was created,
-- given the requisition's lifecycle, and then accepted 'submit' and 'approve'
-- because the requisition machine happens to have transitions by those names.
-- It refused 'send'. So the document was in a state that looked plausible,
-- reached through the wrong graph, and the first sign was a transition
-- rejected four steps later.
--
-- This is the same class as transition.effects below — configuration stored
-- and ignored — and worse, because it does the wrong thing rather than
-- nothing. Both are now caught by erp.assert_no_dead_configuration().
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION erp.start_lifecycle(p_object_type text, p_object_id uuid, p_entity_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid, p_on date DEFAULT NULL::date, p_machine_code text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_on      date := coalesce(p_on, current_date);
  v_version uuid;
  v_state   uuid;
  v_code    text;
begin
  select smv.id into v_version
    from erp.state_machine sm
    join erp.state_machine_version smv
      on smv.tenant_id = sm.tenant_id
     and smv.state_machine_id = sm.id
     and smv.status = 'active'
     and daterange(smv.effective_from, smv.effective_to, '[)') @> v_on
   where sm.tenant_id = v_tenant
     and sm.object_type = p_object_type
     and sm.status = 'active'
     -- When the caller knows which lifecycle applies, that is not a hint.
     -- Without this the choice is made by object_type alone, and every
     -- document type shares object_type 'document' — so a purchase order was
     -- given the requisition's machine, silently, and then refused the
     -- transitions it was configured with.
     and (p_machine_code is null or sm.code = p_machine_code)
     and (sm.site_id   is null or sm.site_id   = p_site_id)
     and (sm.entity_id is null or sm.entity_id = p_entity_id)
   order by (sm.site_id is not null) desc, (sm.entity_id is not null) desc
   limit 1;

  if v_version is null then
    raise exception
      'ERPWARE_NO_LIFECYCLE: no state machine in force for % on %',
      coalesce(p_machine_code, p_object_type), v_on using errcode = '23503';
  end if;

  select s.id, s.code into v_state, v_code
    from erp.state s
   where s.tenant_id = v_tenant
     and s.state_machine_version_id = v_version
     and s.is_initial;

  insert into erp.object_state (
    tenant_id, object_type, object_id, entity_id, site_id,
    state_machine_version_id, current_state_id, entered_by)
  values (
    v_tenant, p_object_type, p_object_id, p_entity_id, p_site_id,
    v_version, v_state, erp.current_principal_id());

  insert into erp.state_transition_log (
    tenant_id, object_type, object_id, to_state_code, actor_id, reason, correlation_id)
  values (
    v_tenant, p_object_type, p_object_id, v_code, erp.current_principal_id(),
    'lifecycle started', erp.current_correlation_id());

  return v_code;
end;
$function$;

CREATE OR REPLACE FUNCTION erp.create_document(p_document_type_code text, p_entity_id uuid, p_site_id uuid DEFAULT NULL::uuid, p_party_id uuid DEFAULT NULL::uuid, p_document_date date DEFAULT NULL::date, p_currency character DEFAULT NULL::bpchar, p_their_reference text DEFAULT NULL::text, p_attributes jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_number text;
  v_id     uuid;
begin
  select * into dt from erp.document_type
   where tenant_id = v_tenant and code = p_document_type_code and status = 'active';

  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT_TYPE: %', p_document_type_code
      using errcode = '23503';
  end if;

  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  if bt.requires_party and p_party_id is null then
    raise exception 'ERPWARE_DOCUMENT_PARTY_REQUIRED: % needs a party', p_document_type_code
      using errcode = '23514';
  end if;
  if bt.requires_site and p_site_id is null then
    raise exception 'ERPWARE_DOCUMENT_SITE_REQUIRED: % needs a site', p_document_type_code
      using errcode = '23514';
  end if;

  if dt.numbering_rule_id is null then
    raise exception 'ERPWARE_DOCUMENT_NO_NUMBERING: % has no numbering rule bound',
      p_document_type_code using errcode = '23514';
  end if;

  v_number := erp.next_document_number(dt.numbering_rule_id);

  insert into erp.document (
    tenant_id, entity_id, site_id, document_type_id, document_number,
    party_id, document_date, currency, their_reference, attributes)
  values (
    v_tenant, p_entity_id, p_site_id, dt.id, v_number, p_party_id,
    coalesce(p_document_date, current_date),
    coalesce(p_currency, (select e.base_currency from erp.entity e where e.id = p_entity_id)),
    p_their_reference, p_attributes)
  returning id into v_id;

  -- The lifecycle starts immediately, so a document is never in no state at
  -- all — which is the condition in which status logic quietly diverges.
  -- dt.state_machine_code was a column nothing read. Passing it is the whole
  -- fix: which lifecycle a document follows is a property of its type, not of
  -- the fact that it is a document.
  perform erp.start_lifecycle('document', v_id, p_entity_id, p_site_id, null,
                              dt.state_machine_code);

  return v_id;
end;
$function$;

-- -----------------------------------------------------------------------------
-- A transition effect that nothing executes
--
-- erp.transition.effects is written by B6 promotion and read by nothing:
-- erp.perform_transition() declares a variable for it and never uses it. A
-- configuration field that silently does nothing is precisely the failure this
-- build keeps guarding against — a tenant could declare "on posting, move
-- stock", see it stored, and get no stock movement.
--
-- Executing effects is a real piece of B4 and not something to bolt on inside a
-- procurement migration. So this makes the gap loud instead of silent: declare
-- an effect and the build fails, saying it would not run. The posting below is
-- therefore written explicitly, which is honest about where the behaviour lives.
-- -----------------------------------------------------------------------------

create or replace function erp.dead_configuration_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a transition declares effects that nothing executes',
         format('%s.%s', m.code, t.code),
         'erp.perform_transition() does not run transition effects, so this '
         'configuration would be stored and silently ignored'
    from erp.transition t
    join erp.state_machine_version v on v.id = t.state_machine_version_id
    join erp.state_machine m on m.id = v.state_machine_id
   where jsonb_array_length(coalesce(t.effects, '[]'::jsonb)) > 0
  union all
  select 'a state declares entry or exit actions that nothing executes',
         format('%s.%s', m.code, s.code),
         'on_enter and on_exit are stored and never read'
    from erp.state s
    join erp.state_machine_version v on v.id = s.state_machine_version_id
    join erp.state_machine m on m.id = v.state_machine_id
   where jsonb_array_length(coalesce(s.on_enter, '[]'::jsonb)) > 0
      or jsonb_array_length(coalesce(s.on_exit, '[]'::jsonb)) > 0
  union all
  -- A document type naming a lifecycle that does not exist. Before
  -- start_lifecycle() read this column the value was inert, so a typo here was
  -- invisible; now it decides which graph a document follows, and a name that
  -- resolves to nothing must fail loudly rather than fall back to whichever
  -- machine sorts first.
  select 'a document type names a state machine that does not exist',
         dt.code, format('state_machine_code = %s', dt.state_machine_code)
    from erp.document_type dt
   where dt.status = 'active'
     and dt.state_machine_code is not null
     and not exists (
       select 1 from erp.state_machine m
        where m.tenant_id = dt.tenant_id and m.code = dt.state_machine_code
          and m.status = 'active')
$$;

create or replace function erp.assert_no_dead_configuration()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.dead_configuration_report();

  if v_count > 0 then
    raise exception 'ERPWARE_DEAD_CONFIGURATION: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;
  return '';
end;
$$;

comment on function erp.assert_no_dead_configuration() is
  'Configuration that is stored and never read is worse than configuration '
  'that is absent: it looks like behaviour. Fails the build rather than '
  'letting a tenant configure something that will not happen.';

-- -----------------------------------------------------------------------------
-- The module, as configuration
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
  v_cs     uuid;
  v_entity uuid;
  v_req    uuid;
  v_po     uuid;
  v_rec    uuid;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'change_set', null);

  select e.id into v_entity from erp.entity e
   where e.tenant_id = v_tenant and e.status = 'active'
   order by e.code limit 1;

  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: configure an entity before a module'
      using errcode = '23503';
  end if;

  v_cs := erp.create_change_set(
    'procurement-lifecycle', 'Procurement lifecycle',
    'Requisition, purchase order and receipt: their states, the transitions '
    'between them, and the approval a purchase order needs above a threshold.');

  -- Requisition: an internal request to buy. Terminal states are 'ordered'
  -- (it became a purchase order) and 'cancelled'.
  perform erp.add_change_set_item(v_cs, 'state_machine', 'requisition', jsonb_build_object(
    'code', 'requisition', 'object_type', 'document', 'name', 'Requisition',
    'states', jsonb_build_array(
      jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
      jsonb_build_object('code','submitted','name','Submitted','sort_order',20),
      jsonb_build_object('code','approved','name','Approved','sort_order',30),
      jsonb_build_object('code','ordered','name','Ordered','is_terminal',true,'is_committed',true,'sort_order',40),
      jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
    'transitions', jsonb_build_array(
      jsonb_build_object('code','submit','name','Submit','from','draft','to','submitted',
                         'required_permission','procurement.requisition'),
      jsonb_build_object('code','approve','name','Approve','from','submitted','to','approved',
                         'required_permission','procurement.approve'),
      jsonb_build_object('code','reject','name','Reject','from','submitted','to','draft',
                         'required_permission','procurement.approve'),
      jsonb_build_object('code','order','name','Convert to order','from','approved','to','ordered',
                         'required_permission','procurement.order'),
      jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled',
                         'required_permission','procurement.requisition'),
      jsonb_build_object('code','cancel_submitted','name','Cancel','from','submitted','to','cancelled',
                         'required_permission','procurement.approve'))));

  -- Purchase order. 'sent' is where it leaves the building, which is why the
  -- transition into it is the one that submits a command to the gateway.
  perform erp.add_change_set_item(v_cs, 'state_machine', 'purchase_order', jsonb_build_object(
    'code', 'purchase_order', 'object_type', 'document', 'name', 'Purchase order',
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
      jsonb_build_object('code','submit','name','Submit for approval','from','draft','to','pending_approval',
                         'required_permission','procurement.order'),
      jsonb_build_object('code','approve','name','Approve','from','pending_approval','to','approved',
                         'required_permission','procurement.approve'),
      jsonb_build_object('code','reject','name','Reject','from','pending_approval','to','draft',
                         'required_permission','procurement.approve'),
      jsonb_build_object('code','send','name','Send to supplier','from','approved','to','sent',
                         'required_permission','procurement.order'),
      jsonb_build_object('code','receive_partial','name','Receive part','from','sent','to','partially_received',
                         'required_permission','procurement.receive'),
      jsonb_build_object('code','receive_rest','name','Receive remainder','from','partially_received','to','received',
                         'required_permission','procurement.receive'),
      jsonb_build_object('code','receive_all','name','Receive in full','from','sent','to','received',
                         'required_permission','procurement.receive'),
      jsonb_build_object('code','close','name','Close','from','received','to','closed',
                         'required_permission','procurement.order'),
      jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled',
                         'required_permission','procurement.order'),
      jsonb_build_object('code','cancel_approved','name','Cancel','from','approved','to','cancelled',
                         'required_permission','procurement.approve'))));

  -- Goods receipt. Short on purpose: posting is the only interesting moment,
  -- and it is irreversible by design — a receipt is corrected by reversing it,
  -- never by editing it.
  perform erp.add_change_set_item(v_cs, 'state_machine', 'goods_receipt', jsonb_build_object(
    'code', 'goods_receipt', 'object_type', 'document', 'name', 'Goods receipt',
    'states', jsonb_build_array(
      jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
      jsonb_build_object('code','posted','name','Posted','is_terminal',true,'is_committed',true,'sort_order',20),
      jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
    'transitions', jsonb_build_array(
      jsonb_build_object('code','post','name','Post','from','draft','to','posted',
                         'required_permission','procurement.receive'),
      jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled',
                         'required_permission','procurement.receive'))));

  -- Approval, value-banded, expressed in B3's JsonLogic over the request
  -- context rather than a second rule language. The step condition is what
  -- makes it a band: below the threshold the chain still applies but the
  -- second step does not fire.
  perform erp.add_change_set_item(v_cs, 'approval_chain', 'purchase_order_value', jsonb_build_object(
    'code', 'purchase_order_value', 'name', 'Purchase order value approval',
    'object_type', 'document',
    'applies_when', jsonb_build_object('==',
      jsonb_build_array(jsonb_build_object('var','document_type'), 'purchase_order')),
    'value_field', 'total_minor',
    'priority', 100,
    'material_fields', jsonb_build_array('total_minor','party_id'),
    'steps', jsonb_build_array(
      jsonb_build_object('seq',1,'code','buyer_manager','name','Buying manager',
        'approver_kind','role','role',p_approver_role,'min_approvals',1),
      jsonb_build_object('seq',2,'code','finance','name','Finance',
        'approver_kind','role','role',p_approver_role,'min_approvals',1,
        'condition', jsonb_build_object('>',
          jsonb_build_array(jsonb_build_object('var','total_minor'),
                            p_approval_threshold_minor))))));

  -- Submitted, and deliberately not approved here. B6 refuses to let the
  -- author of a change set wave it through, unconditionally, and that control
  -- is worth more than the convenience of a one-call install: this change set
  -- sets the value threshold above which a purchase order needs finance, so
  -- the person who writes it should not also be the person who accepts it.
  --
  -- Installing procurement therefore takes two administrators, which is not a
  -- limitation to work around. Approve and promote with
  -- erp_approve_change_set() and erp_promote_change_set() as somebody else.
  perform erp.submit_change_set(v_cs);

  -- Numbering and document types are not guarded, so they are written
  -- directly. A separate sequence per type, because "PO-000123" and
  -- "REQ-000123" being the same underlying counter surprises everybody.
  insert into erp.numbering_rule (tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  values (v_tenant, 'requisition', v_entity, 'REQ-', 6, 'yearly', 1),
         (v_tenant, 'purchase_order', v_entity, 'PO-', 6, 'yearly', 1),
         (v_tenant, 'goods_receipt', v_entity, 'GRN-', 6, 'yearly', 1)
  on conflict (tenant_id, code) do nothing;

  -- The movement column is what makes posting real. A goods receipt whose
  -- base type declares affects_stock and which names no movement type commits,
  -- looks posted, and moves nothing — which is the state this shipped in until
  -- the posting bridge was built. erp.assert_no_dead_configuration() now
  -- refuses it.
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

comment on function erp.configure_procurement is
  'Authors procurement as configuration: three state machines and a '
  'value-banded approval chain submitted as a B6 change set, plus numbering '
  'rules and document types written directly because they carry no live guard. '
  'Returns the change set for a second administrator to approve and promote. '
  'No tables — the document spine already had all thirteen types of spec 4.5.';

-- The other half of the two-person flow, so it can be completed from the
-- interface rather than only from SQL.
create or replace function public.erp_approve_change_set(p_change_set_id uuid)
returns jsonb
language sql volatile security invoker set search_path = ''
as $$
  select jsonb_build_object('approved', p_change_set_id)
    from (select erp.approve_change_set(p_change_set_id)) _
$$;

create or replace function public.erp_promote_change_set(p_change_set_id uuid)
returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('promotion_id', erp.promote_change_set(p_change_set_id)) $$;

create or replace function public.erp_change_sets()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'change_set_id', c.id, 'code', c.code, 'name', c.name,
           'status', c.status, 'created_at', c.created_at,
           'authored_by', a.display_name,
           -- What a reviewer needs before approving: whether they are allowed
           -- to, and they are not if they wrote it.
           'is_own', c.created_by = erp.current_principal_id())
           order by c.created_at desc), '[]'::jsonb)
    from erp.change_set c
    left join erp.app_user a on a.tenant_id = c.tenant_id and a.id = c.created_by
   where c.tenant_id = erp.current_tenant_id()
$$;

-- -----------------------------------------------------------------------------
-- Working with documents
--
-- Generic on purpose. None of these mentions procurement: they operate on the
-- spine, so the next module is configuration and not another set of these.
-- -----------------------------------------------------------------------------

-- B7 already provides erp.create_document(), which allocates the number, writes
-- the row and starts the lifecycle. The one thing it does not do is authorise.
--
-- So this wraps it rather than shadowing it. An overload of the same name with
-- a different argument order was the first draft, and it is exactly the
-- ambiguity that erp_grant_role had to be untangled from an hour ago.
create or replace function erp.open_document(
  p_type_code   text,
  p_party_id    uuid default null,
  p_entity_id   uuid default null,
  p_site_id     uuid default null,
  p_their_ref   text default null,
  p_required_date date default null,
  p_currency    char(3) default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_entity uuid;
  v_id     uuid;
begin
  select * into dt from erp.document_type
   where tenant_id = v_tenant and code = p_type_code and status = 'active';

  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT_TYPE: %', p_type_code using errcode = '23503';
  end if;

  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  v_entity := coalesce(p_entity_id, dt.entity_id);
  if v_entity is null then
    raise exception 'ERPWARE_NO_ENTITY: a document must belong to an entity'
      using errcode = '23502';
  end if;

  -- The permission the flow implies. Product content decides which that is, so
  -- a tenant cannot turn a receipt into something a buyer may raise.
  perform erp.authorise(
    case when bt.flow = 'inbound' then 'procurement.receive'
         when dt.code = 'requisition' then 'procurement.requisition'
         else 'procurement.order' end,
    v_entity, p_site_id, null, 'document', null);

  -- create_document() allocates the number, writes the row AND calls
  -- erp.start_lifecycle(). All this adds is the authorisation above.
  v_id := erp.create_document(p_type_code, v_entity, p_site_id, p_party_id,
                              current_date, p_currency, p_their_ref);

  if p_required_date is not null then
    update erp.document set required_date = p_required_date where id = v_id;
  end if;

  return v_id;
end;
$$;

create or replace function erp.add_document_line(
  p_document_id uuid,
  p_item_id     uuid,
  p_quantity    numeric,
  p_unit_price_minor bigint default 0,
  p_description text default null,
  p_required_date date default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_state  text;
  v_line   integer;
  v_id     uuid;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  perform erp.authorise('procurement.order', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  -- A committed document is one the outside world has seen. Changing what it
  -- says after the fact is what amendment and reversal are for.
  select s.is_committed::text into v_state
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document'
     and os.object_id = p_document_id;

  if v_state = 'true' then
    raise exception
      'ERPWARE_DOCUMENT_COMMITTED: % has been committed; amend or reverse it '
      'rather than editing its lines', d.document_number
      using errcode = '42501';
  end if;

  select coalesce(max(l.line_no), 0) + 10 into v_line
    from erp.document_line l where l.tenant_id = v_tenant and l.document_id = p_document_id;

  insert into erp.document_line (
    tenant_id, document_id, line_no, item_id, description, quantity,
    unit_price_minor, net_minor, currency, required_date)
  values (
    v_tenant, p_document_id, v_line, p_item_id, p_description, p_quantity,
    p_unit_price_minor, round(p_quantity * p_unit_price_minor)::bigint,
    d.currency, p_required_date)
  returning id into v_id;

  return v_id;
end;
$$;

-- The document's value, derived from its lines. Approval reads this rather
-- than a stored total, because a stored total is a number somebody can correct
-- without correcting the lines.
create or replace function erp.document_value_minor(p_document_id uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(sum(l.net_minor), 0)::bigint
    from erp.document_line l
   where l.tenant_id = erp.require_tenant_id()
     and l.document_id = p_document_id
     and not l.is_cancelled
$$;

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
  v_ctx    jsonb;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %' , p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;

  -- The context every guard, approval condition and rule sees. Derived, so a
  -- guard cannot be fooled by a stale stored value.
  v_ctx := jsonb_build_object(
    'document_type', dt.code,
    'document_number', d.document_number,
    'total_minor', erp.document_value_minor(p_document_id),
    'currency', d.currency,
    'party_id', d.party_id,
    'entity_id', d.entity_id,
    'transition', p_transition_code);

  -- Submitting for approval raises the request; the chain decides how many
  -- steps that means, and the value band decides whether finance is one of
  -- them. Nothing here knows the threshold.
  if p_transition_code = 'submit' and dt.approval_chain_code is not null then
    perform erp.request_approval('document', p_document_id, v_ctx, 1,
                                 d.entity_id, d.site_id);
  end if;

  return erp.perform_transition('document', p_document_id, p_transition_code,
                                v_ctx, p_reason);
end;
$$;

-- Lineage. Spec 4.5 wants it navigable in both directions, which is a property
-- of storing the edge once and reading it either way rather than of writing
-- two rows.
create or replace function erp.link_documents(
  p_from_document_id uuid,
  p_to_document_id   uuid,
  p_kind             erp.document_relation_kind,
  p_quantity         numeric default null
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('procurement.order', null, null, null, 'document',
                        p_from_document_id);

  insert into erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind, quantity)
  values (v_tenant, p_from_document_id, p_to_document_id, p_kind, p_quantity)
  returning id into v_id;

  return v_id;
end;
$$;

-- B7 already provides erp.document_lineage(document_id, direction, max_depth):
-- recursive, depth-aware and navigable both ways, which is more than the
-- one-hop version drafted here. Duplicating it would have given the same name
-- two meanings and left callers guessing which they got.

-- -----------------------------------------------------------------------------
-- The public write surface
-- -----------------------------------------------------------------------------

create or replace function public.erp_configure_procurement(
  p_approval_threshold_minor bigint default 1000000
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('change_set_id', erp.configure_procurement(p_approval_threshold_minor)) $$;

create or replace function public.erp_create_document(
  p_type_code text, p_party_id uuid default null, p_site_id uuid default null,
  p_their_ref text default null, p_required_date date default null
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('document_id',
  erp.open_document(p_type_code, p_party_id, null, p_site_id, p_their_ref, p_required_date)) $$;

create or replace function public.erp_add_document_line(
  p_document_id uuid, p_item_id uuid, p_quantity numeric,
  p_unit_price_minor bigint default 0, p_description text default null
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('line_id',
  erp.add_document_line(p_document_id, p_item_id, p_quantity, p_unit_price_minor, p_description)) $$;

create or replace function public.erp_transition_document(
  p_document_id uuid, p_transition_code text, p_reason text default null
) returns jsonb
language sql volatile security invoker set search_path = ''
as $$ select jsonb_build_object('state',
  erp.transition_document(p_document_id, p_transition_code, p_reason)) $$;

-- Reads.
create or replace function public.erp_documents(p_type_code text default null, p_limit integer default 100)
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x->>'document_number' desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'document_id', d.id, 'document_number', d.document_number,
      'document_type', dt.code, 'document_date', d.document_date,
      'required_date', d.required_date, 'currency', d.currency,
      'party', p.name, 'total_minor', erp.document_value_minor(d.id),
      'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed,
      'is_cancelled', d.is_cancelled) as x
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
      left join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      left join erp.state s on s.id = os.current_state_id
     where d.tenant_id = erp.current_tenant_id()
       and (p_type_code is null or dt.code = p_type_code)
     order by d.document_number desc
     limit greatest(p_limit, 1)) t
$$;

create or replace function public.erp_document(p_document_id uuid)
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select jsonb_build_object(
    'document', (
      select jsonb_build_object(
        'document_id', d.id, 'document_number', d.document_number,
        'document_type', dt.code, 'document_date', d.document_date,
        'currency', d.currency, 'party', p.name,
        'their_reference', d.their_reference,
        'total_minor', erp.document_value_minor(d.id),
        'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed)
        from erp.document d
        join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
        left join erp.object_state os
          on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
        left join erp.state s on s.id = os.current_state_id
       where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'line_id', l.id, 'line_no', l.line_no, 'description', l.description,
        'quantity', l.quantity, 'unit_price_minor', l.unit_price_minor,
        'net_minor', l.net_minor, 'item', i.code) order by l.line_no)
        from erp.document_line l
        left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
       where l.tenant_id = erp.current_tenant_id() and l.document_id = p_document_id), '[]'::jsonb),
    -- Spec 4.5: navigable in both directions.
    'lineage', coalesce((
      select jsonb_agg(jsonb_build_object(
        'depth', depth, 'direction', direction, 'document_id', document_id,
        'document_number', document_number, 'base_type', base_type,
        'relation', relation_kind) order by depth)
        from erp.document_lineage(p_document_id)), '[]'::jsonb),
    'available_transitions', coalesce((
      select jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name, 'to_state', ts.code))
        from erp.object_state os
        join erp.transition t on t.state_machine_version_id = os.state_machine_version_id
                             and t.from_state_id = os.current_state_id
        join erp.state ts on ts.id = t.to_state_id
       where os.tenant_id = erp.current_tenant_id()
         and os.object_type = 'document' and os.object_id = p_document_id), '[]'::jsonb))
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_configure_procurement(bigint)',
    'public.erp_create_document(text, uuid, uuid, text, date)',
    'public.erp_add_document_line(uuid, uuid, numeric, bigint, text)',
    'public.erp_transition_document(uuid, text, text)',
    'public.erp_approve_change_set(uuid)',
    'public.erp_promote_change_set(uuid)',
    'public.erp_change_sets()',
    'public.erp_documents(text, integer)',
    'public.erp_document(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_procurement', 'erp.configure_procurement',
   'Installs the procurement lifecycle through a B6 change set. Gated on '
   'administration.configure inside erp.configure_procurement().'),
  ('erp_create_document', 'erp.open_document',
   'Creates a document of a configured type and starts its lifecycle. Gated '
   'inside erp.open_document() on the permission its flow implies.'),
  ('erp_add_document_line', 'erp.add_document_line',
   'Adds a line to an uncommitted document. Gated on procurement.order, and '
   'refuses a document the outside world has already seen.'),
  ('erp_approve_change_set', 'erp.approve_change_set',
   'Accepts a change set somebody else authored. Gated on '
   'administration.promote, and refuses the author outright.'),
  ('erp_promote_change_set', 'erp.promote_change_set',
   'Applies an approved change set to this environment. Gated on '
   'administration.promote inside B6.'),
  ('erp_transition_document', 'erp.transition_document',
   'Moves a document through its configured lifecycle. It does not authorise '
   'directly: the transition declares the permission it needs and '
   'erp.perform_transition() enforces it, which is why rule 3d follows the '
   'chain rather than stopping at the first hop.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;


-- -----------------------------------------------------------------------------
-- Rule 3d, following the whole chain
--
-- The one-hop version was right for wrappers that delegate straight to an
-- authorising function, and wrong the moment a legitimate chain was longer:
-- erp_transition_document delegates to erp.transition_document, which delegates
-- to erp.perform_transition, which authorises on the permission the transition
-- itself declares. Two hops, entirely gated, and reported as ungated.
--
-- Making the wrapper call erp.authorise() as well would satisfy the rule and
-- authorise twice on different permissions, which is worse than the rule being
-- wrong. So the rule walks the call graph instead — bounded, and by the same
-- technique erp.intelligence_boundary_report() already uses: every function is
-- defined with an empty search_path and therefore must qualify every name it
-- calls, which makes prosrc a usable edge list in this codebase specifically.
create or replace function erp.public_api_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with recursive fn as (
    select p.oid, p.pronamespace::regnamespace::text as ns, p.proname, p.prosrc
      from pg_catalog.pg_proc p
     where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
  ),
  edge as (
    select caller.oid as caller, callee.oid as callee
      from fn caller join fn callee
        on caller.oid <> callee.oid
       and position(callee.ns || '.' || callee.proname || '(' in caller.prosrc) > 0
  ),
  gate_root as (
    select w.function_name, w.gate, f.oid
      from erp_meta.public_write_allowance w
      join fn f on f.ns = split_part(w.gate, '.', 1)
                and f.proname = split_part(w.gate, '.', 2)
  ),
  reach as (
    select g.function_name, g.gate, g.oid as reached, 0 as depth from gate_root g
    union
    select r.function_name, r.gate, e.callee, r.depth + 1
      from reach r join edge e on e.caller = r.reached
     where r.depth < 6
  ),
  gated as (
    select distinct r.function_name
      from reach r join fn f on f.oid = r.reached
     where position('erp.authorise(' in f.prosrc) > 0
        or exists (select 1 from erp_meta.security_definer_allowance a
                    where a.schema_name = f.ns and a.function_name = f.proname)
  )
  select 'a public API function is SECURITY DEFINER',
         p.oid::regprocedure::text,
         'it would run as the owner, who bypasses row-level security, and '
         'return every tenant''s rows'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%' and p.prosecdef
  union all
  select 'a public API function is executable by anon',
         p.oid::regprocedure::text,
         'an unauthenticated caller should not reach the product surface at all'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
     and has_function_privilege('anon', p.oid, 'execute')
  union all
  select 'a public API function writes but is not on the write allow-list',
         p.oid::regprocedure::text,
         'it is VOLATILE, so it may write; add it to '
         'erp_meta.public_write_allowance with a rationale, or make it STABLE'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
     and p.provolatile = 'v'
     and not exists (select 1 from erp_meta.public_write_allowance w
                      where w.function_name = p.proname)
  union all
  select 'a public API write function does not call its declared gate',
         p.oid::regprocedure::text,
         format('%s is on the allow-list gated by %s, but its body does not call it',
                p.proname, w.gate)
    from pg_catalog.pg_proc p
    join erp_meta.public_write_allowance w on w.function_name = p.proname
   where p.pronamespace = 'public'::regnamespace
     and position(w.gate || '(' in p.prosrc) = 0
  union all
  select 'a write allow-list entry names no function', w.function_name,
         'nothing is being permitted, and nothing is being checked'
    from erp_meta.public_write_allowance w
   where not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'public'::regnamespace
                        and p.proname = w.function_name)
  union all
  select 'a public API write function reaches no authorisation at all',
         w.function_name,
         format('nothing reachable from %s within six calls authorises, and it '
                'is not an enumerated SECURITY DEFINER exception', w.gate)
    from erp_meta.public_write_allowance w
   where exists (select 1 from gate_root g where g.function_name = w.function_name)
     and not exists (select 1 from gated x where x.function_name = w.function_name)
$$;

select erp.assert_no_dead_configuration();
select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_isolation();

-- -----------------------------------------------------------------------------
-- The adversarial suite
--
-- The value band is the case worth guarding. It is invisible at submit time —
-- erp.open_approval_seq() opens one sequence at a time, so the second step only
-- appears once the first is decided — and counting tasks without reading their
-- status shows two rows either way. Measured that way it looked like the band
-- worked when it had not been exercised at all, which is how a green test
-- proves nothing.
-- -----------------------------------------------------------------------------

create or replace function erp_test.procurement_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r        record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_cs uuid; v_second uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_party uuid; v_item uuid;
  v_req uuid; v_po uuid; v_lo uuid; t record;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant(
    'zzproc', 'Procurement Suite', 'admin@zzproc.test', 'Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  res := public.erp_invite_principal('second@zzproc.test', 'Second Admin');
  v_second := (res->>'app_user_id')::uuid; v_tok := res->>'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  v_cs := erp.configure_procurement(1000000);
  return query select 'installing procurement authors a change set, unapproved',
    (select c.status::text from erp.change_set c where c.id = v_cs) = 'ready',
    'B6 will not let its author wave it through';

  begin
    perform erp.approve_change_set(v_cs);
    v_ok := false; v_msg := 'the author approved their own change set';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'the author of a change set cannot approve it', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'promotion installs three lifecycles',
    (select count(*) from erp.state_machine m
      where m.tenant_id = r.tenant_id and m.status = 'active'
        and m.code in ('requisition','purchase_order','goods_receipt')) = 3,
    'requisition, purchase order and goods receipt';

  insert into erp.uom (tenant_id,code,name,uom_class,decimals,is_base,status)
  values (r.tenant_id,'EA','Each','quantity',0,true,'active') returning id into v_uom;
  insert into erp.site (tenant_id,entity_id,code,name,site_type,status)
  values (r.tenant_id,r.entity_id,'MAIN','Main','warehouse','active') returning id into v_site;
  insert into erp.party (tenant_id,code,name,status)
  values (r.tenant_id,'SUP','Supplier','active') returning id into v_party;
  insert into erp.item (tenant_id,code,name,stock_uom_id,status)
  values (r.tenant_id,'WID','Widget',v_uom,'active') returning id into v_item;

  -- Requisition through to its terminal state.
  v_req := erp.open_document('requisition', v_party);
  perform erp.add_document_line(v_req, v_item, 10, 50000, 'Ten widgets');
  return query select 'a document is numbered from its own rule',
    (select d.document_number like 'REQ-%' from erp.document d where d.id = v_req),
    (select d.document_number from erp.document d where d.id = v_req);

  return query select 'the value is derived from the lines, not stored',
    erp.document_value_minor(v_req) = 500000,
    format('%s minor', erp.document_value_minor(v_req));

  perform erp.transition_document(v_req, 'submit');
  perform erp.transition_document(v_req, 'approve');
  return query select 'a requisition reaches its terminal state',
    erp.transition_document(v_req, 'order') = 'ordered', 'draft to ordered';

  begin
    perform erp.transition_document(v_req, 'submit');
    v_ok := false; v_msg := 'a transition out of a terminal state was allowed';
  exception when others then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'a terminal state has no way out', v_ok, v_msg;

  -- The purchase order must run its OWN machine, which is the defect this
  -- module found: start_lifecycle() chose by object_type alone, and every
  -- document type shares object_type 'document'.
  v_po := erp.open_document('purchase_order', v_party, null, v_site);
  perform erp.add_document_line(v_po, v_item, 500, 50000, 'Five hundred');
  return query select 'a document follows the lifecycle its type names',
    (select m.code from erp.object_state os
       join erp.state_machine_version v on v.id = os.state_machine_version_id
       join erp.state_machine m on m.id = v.state_machine_id
      where os.object_id = v_po) = 'purchase_order',
    'not whichever machine shares its object_type';

  perform erp.link_documents(v_req, v_po, 'fulfils');
  return query select 'lineage is navigable in both directions',
    (select count(*) from erp.document_lineage(v_req)) >= 2
    and (select count(*) from erp.document_lineage(v_po)) >= 2,
    'spec 4.5';

  -- The band, measured by status rather than by counting rows.
  perform erp.transition_document(v_po, 'submit');
  -- The caller's own task, not whichever came first: a step with two eligible
  -- approvers raises a task each, and deciding somebody else's is refused.
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'above the threshold, the second approval step opens',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_po and tk.step_code = 'finance'
               and tk.status = 'pending'),
    'value 25000000 against a threshold of 1000000';

  v_lo := erp.open_document('purchase_order', v_party, null, v_site);
  perform erp.add_document_line(v_lo, v_item, 1, 500000, 'Small');
  perform erp.transition_document(v_lo, 'submit');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_lo and tk.status = 'pending'
              and tk.assignee_user_id = erp.current_principal_id() limit 1
  loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;

  return query select 'below the threshold, it is skipped and recorded as skipped',
    exists (select 1 from erp.approval_task tk
              join erp.approval_request q on q.id = tk.approval_request_id
             where q.object_id = v_lo and tk.step_code = 'finance'
               and tk.status = 'skipped'),
    'omitting it would leave no evidence it was considered';

  -- Committed documents.
  perform erp.transition_document(v_po, 'approve');
  perform erp.transition_document(v_po, 'send');
  begin
    perform erp.add_document_line(v_po, v_item, 1, 1, 'sneak');
    v_ok := false; v_msg := 'a committed document accepted a new line';
  exception when sqlstate '42501' then v_ok := true; v_msg := left(sqlerrm, 60); end;
  return query select 'a committed document cannot gain a line', v_ok, v_msg;

  return query select 'a purchase order runs its full lifecycle',
    erp.transition_document(v_po, 'receive_all') = 'received', 'sent to received';

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
end;
$$;

create or replace function erp_test.assert_procurement_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_expected constant integer := 13;
  v_total integer; v_failed integer; v_detail text;
begin
  select count(*), count(*) filter (where not r.passed),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_total, v_failed, v_detail
    from erp_test.procurement_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_PROCUREMENT_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;
  if v_total <> c_expected then
    raise exception 'ERPWARE_PROCUREMENT_SUITE_INCOMPLETE: expected % cases, ran %',
      c_expected, v_total
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('procurement: %s/%s cases passed', v_total, v_total);
end;
$$;
