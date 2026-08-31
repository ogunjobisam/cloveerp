-- Who may raise a document, when two tenant types share one base type.
--
-- 20260829350000 moved the create permission out of a CASE in erp.open_document
-- and into erp_ref.document_type.create_permission, so a base type declares its
-- own module instead of eight of the thirteen falling through to
-- procurement.order. That was right, and it was not enough.
--
-- A base type is not fine-grained enough, because two tenant types can sit on
-- one base type and legitimately want different answers. Both of these are
-- installed by this product, on base type invoice_reference:
--
--   sales_invoice     (configure_sales / finance posting)  sales.invoice
--   purchase_invoice  (configure_procurement_controls)     procurement.match
--
-- The base carries sales.invoice, so purchase_invoice inherited it. Measured on
-- a tenant with every module installed, that is the only disagreement among
-- eight document types — and it is a real one:
--
--   document type  purchase_invoice  base invoice_reference  create sales.invoice
--   transition     register   procurement.match
--   transition     dispute    procurement.match
--   transition     resolve    procurement.match
--   transition     cancel     procurement.match
--   transition     pay        finance.post
--
-- So the account that registers a purchase invoice cannot raise one, and the
-- account that can raise one cannot do anything with it afterwards. Nothing
-- refuses at install time; it fails in the hands of whoever tries to use it.
--
-- The fix is a nullable override on the tenant's own document type, because the
-- tenant's type is the thing that knows. The base stays as the default and is
-- still NOT NULL, so nothing becomes ungoverned by omission.
--
-- Deriving the answer from the lifecycle instead was tempting and is wrong:
-- purchase_invoice has two transitions out of draft (register and cancel), so
-- "the initial transition" is not well defined, and picking one by sort order
-- would be a silently arbitrary answer to a security question.
--
-- Applied to live in order, so no separate repair is needed for the existing
-- purchase_invoice rows: the backfill below is part of this migration.

alter table erp.document_type
  add column if not exists create_permission text
    references erp_ref.permission (code);

comment on column erp.document_type.create_permission is
  'Overrides erp_ref.document_type.create_permission for this tenant type. '
  'Null means inherit the base type, which is the usual case; it is set when '
  'two tenant types share a base type and need different permissions.';

-- The one type that needs it today, for tenants that already have it.
update erp.document_type
   set create_permission = 'procurement.match'
 where base_type_code = 'invoice_reference'
   and code = 'purchase_invoice'
   and create_permission is distinct from 'procurement.match';

create or replace function erp.open_document(
  p_type_code text, p_party_id uuid default null, p_entity_id uuid default null,
  p_site_id uuid default null, p_their_ref text default null,
  p_required_date date default null, p_currency char default null)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $fn$
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

  -- The permission the base type declares. The comment here used to say
  -- "product content decides which that is" while the code decided it with a
  -- CASE that could only ever name a procurement permission — so eight of the
  -- thirteen base types authorised procurement.order, including stock
  -- adjustments, works orders and every sales document.
  --
  -- The old middle arm read dt.code rather than bt.code, so it keyed on the
  -- *tenant's* name for the type: a tenant type called 'requisition' got
  -- procurement.requisition whatever it inherited from, and a requisition
  -- called anything else did not.
  -- coalesce, not bt alone: the tenant's own type overrides the base when two
  -- types share one base and need different permissions. See purchase_invoice.
  perform erp.authorise(coalesce(dt.create_permission, bt.create_permission),
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
$fn$;

create or replace function erp.add_document_line(
  p_document_id uuid, p_item_id uuid, p_quantity numeric,
  p_unit_price_minor bigint default 0, p_description text default null,
  p_required_date date default null)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $fn$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_state  text;
  v_perm   text;
  v_line   integer;
  v_id     uuid;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  -- The same permission that raising this document required, read from the
  -- same place. A constant here meant a principal could be allowed to open a
  -- sales order and then refused a line on it.
  select coalesce(dt.create_permission, bt.create_permission) into v_perm
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  perform erp.authorise(v_perm, d.entity_id, d.site_id, null,
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
$fn$;

-- ── The public read was still answering from the CASE ───────────────────────
--
-- 20260829350000 replaced the hard-coded CASE in erp.open_document and left the
-- identical one in public.erp_document_types, which is my own miss. So the
-- engine enforced one permission and the read reported another:
--
--   case when bt.flow = 'inbound' then 'procurement.receive'
--        when dt.code = 'requisition' then 'procurement.requisition'
--        else 'procurement.order' end
--
-- Every sales document was reported as needing procurement.order. src/components
-- /erp/documents.tsx gates the New button on exactly this value, so on /sales it
-- was hidden from the people who may raise a quotation and offered to the people
-- the database would then refuse. The UI was not wrong; it was told wrong.
--
-- It now reports what open_document will actually demand, from the same
-- expression.

create or replace function public.erp_document_types(p_base_type_code text default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'document_type_id', dt.id,
           'code', dt.code,
           'name', dt.name,
           'base_type_code', dt.base_type_code,
           'requires_party', bt.requires_party,
           'requires_site', bt.requires_site,
           'create_permission',
             coalesce(dt.create_permission, bt.create_permission))
           order by dt.code), '[]'::jsonb)
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = erp.current_tenant_id()
     and dt.status = 'active'::erp.record_status
     and (p_base_type_code is null or dt.base_type_code = p_base_type_code)
$fn$;

revoke all on function public.erp_document_types(text) from public, anon;
grant execute on function public.erp_document_types(text) to authenticated;

-- ── And the installer, so a future install does not need this migration ─────

create or replace function erp.configure_procurement_controls(
  p_approver_role text default 'administrator',
  p_over_receipt_pct numeric default 5,
  p_price_variance_pct numeric default 2,
  p_price_variance_minor bigint default 100)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $fn$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'procurement-controls', 'Procurement controls',
    'What may be received against an order, what may be invoiced against a '
    'receipt, and who has to look when neither agrees.',
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
          -- Under-delivery is not an error: the rest is still outstanding, and
          -- that is what the outstanding quantity is for.
          'under_pct', 100,
          'over_action','accept')),

      jsonb_build_object('kind','match_tolerance','key','default','payload',
        jsonb_build_object(
          'code','default','name','Default match tolerance',
          'quantity_pct', 0,
          'price_pct', p_price_variance_pct,
          'price_absolute_minor', p_price_variance_minor,
          'approval_chain','match_exception')),

      -- The purchase invoice, which procurement has been missing since it was
      -- built. Without it there is no third document to match against and, more
      -- pointedly, nothing ever debits goods-received-not-invoiced: the finance
      -- bridge credits 2100 on every receipt and the balance grows for ever.
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

      -- Registering the invoice is what clears GRNI: the receipt credited it,
      -- and this debits it and credits the supplier instead.
      jsonb_build_object('kind','posting_rule','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','name','Purchase invoice','ledger','GL',
          'event_type','document.purchase_invoice.registered',
          'posting_lines', jsonb_build_array(
            jsonb_build_object('account','2100','side','debit','rate',1,
                               'description','Clearing goods received not invoiced'),
            jsonb_build_object('account','2000','side','credit','rate',1,
                               'description','Trade payable'))))));

  insert into erp.numbering_rule (
    tenant_id, code, entity_id, prefix, pad_to, reset_period, next_value)
  select v_tenant, 'purchase_invoice', e.id, 'PINV-', 6, 'yearly', 1
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'
    order by e.code limit 1
  on conflict (tenant_id, code) do nothing;

  insert into erp.document_type (
    tenant_id, code, base_type_code, name, entity_id,
    state_machine_code, numbering_rule_id, posting_rule_code, create_permission)
  select v_tenant, 'purchase_invoice', 'invoice_reference', 'Purchase invoice',
         n.entity_id, 'purchase_invoice', n.id, 'purchase_invoice',
         -- Base invoice_reference carries sales.invoice, which is right for
         -- sales_invoice and wrong here: every transition on this lifecycle
         -- wants procurement.match, so raising one must too.
         'procurement.match'
    from erp.numbering_rule n
   where n.tenant_id = v_tenant and n.code = 'purchase_invoice'
  on conflict (tenant_id, code) do update
    set state_machine_code = excluded.state_machine_code,
        numbering_rule_id = excluded.numbering_rule_id,
        posting_rule_code = excluded.posting_rule_code,
        create_permission = excluded.create_permission;

  return v_cs;
end;
$fn$;

-- ── The guard, so the next one fails the build instead of a user ────────────
--
-- The rule: whoever may raise a document must be able to do something with it.
-- Concretely, the effective create permission must be required by at least one
-- transition out of the lifecycle's initial state. A draft nobody can move is
-- not a document, it is a dead end, and this is exactly the shape of the
-- purchase_invoice bug.
--
-- This does not forbid segregation of duties. A type where the raiser submits
-- and somebody else approves still passes, because the raiser holds the
-- permission on the submit transition. It fires only when the create permission
-- appears on no transition the creator could take next — which means it was
-- inherited from somewhere that did not know about this type.
--
-- Checked against a tenant with every module installed: eight document types,
-- one finding, and that finding is the bug this migration fixes.

create or replace function erp.document_create_permission_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a document type may be raised by nobody who can then move it',
         format('%s.%s', t.code, dt.code),
         format('raising it needs %s, but every transition out of its initial '
                'state needs one of: %s',
                coalesce(dt.create_permission, bt.create_permission),
                coalesce((select string_agg(distinct tr.required_permission, ', ')
                            from erp.transition tr
                            join erp.state s on s.id = tr.from_state_id
                            join erp.state_machine_version v on v.id = tr.state_machine_version_id
                            join erp.state_machine m on m.id = v.state_machine_id
                           where m.tenant_id = dt.tenant_id
                             and m.code = dt.state_machine_code
                             and s.is_initial), '(none)'))
    from erp.document_type dt
    join erp.tenant t on t.id = dt.tenant_id
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.status = 'active'::erp.record_status
     and dt.state_machine_code is not null
     -- only judge a lifecycle that actually has transitions out of its initial
     -- state; one that has none is assert_no_dead_configuration()'s business
     and exists (
       select 1 from erp.transition tr
         join erp.state s on s.id = tr.from_state_id
         join erp.state_machine_version v on v.id = tr.state_machine_version_id
         join erp.state_machine m on m.id = v.state_machine_id
        where m.tenant_id = dt.tenant_id and m.code = dt.state_machine_code
          and s.is_initial)
     and not exists (
       select 1 from erp.transition tr
         join erp.state s on s.id = tr.from_state_id
         join erp.state_machine_version v on v.id = tr.state_machine_version_id
         join erp.state_machine m on m.id = v.state_machine_id
        where m.tenant_id = dt.tenant_id and m.code = dt.state_machine_code
          and s.is_initial
          and tr.required_permission
              = coalesce(dt.create_permission, bt.create_permission))
$$;

create or replace function erp.assert_document_create_permissions()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail from erp.document_create_permission_report();

  if v_count > 0 then
    raise exception 'ERPWARE_DOCUMENT_CREATE_PERMISSION: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = 'Set erp.document_type.create_permission on the tenant type, '
                   'or correct the transition that disagrees with it.';
  end if;

  return format('%s document type(s) can be raised by somebody who can move them',
    (select count(*) from erp.document_type
      where status = 'active'::erp.record_status and state_machine_code is not null));
end;
$$;

select erp.assert_document_create_permissions();
select erp.assert_public_api_safe();
select erp.assert_isolation();

-- ── The suite: the behaviour, not just the register ─────────────────────────
--
-- Four cases added, and one rationale corrected. The old case said the invoice
-- references were a justified exception because "the only authored invoice
-- transition uses sales.invoice". purchase_invoice is the counter-example that
-- was already in the product when that was written.

create or replace function erp_test.document_authorisation_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $suite$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  a3 uuid := gen_random_uuid();
  v_onboard jsonb; v_tenant uuid; v_entity uuid;
  v_clerk uuid; v_tok text; res jsonb;
  v_role uuid; v_doc uuid; v_uom uuid; v_item uuid; v_party uuid; v_site uuid;
  v_ok boolean; v_msg text; v_n integer;
begin
  insert into auth.users (id, email) values (a1, 'admin@zzdocauth.test');
  insert into auth.users (id, email) values (a2, 'clerk@zzdocauth.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_onboard := erp.onboard_tenant('Document Authorisation', 'zzdocauth');
  v_tenant := (v_onboard ->> 'tenant_id')::uuid;
  v_entity := (v_onboard ->> 'entity_id')::uuid;

  -- ---------------------------------------------------------------------
  -- What product content now declares
  -- ---------------------------------------------------------------------

  return query select 'every base document type names the permission to raise it',
    not exists (select 1 from erp_ref.document_type t where t.create_permission is null),
    'the column is not null, so a base type added later cannot forget';

  return query select 'and names one that exists',
    not exists (select 1 from erp_ref.document_type t
                 left join erp_ref.permission p on p.code = t.create_permission
                where p.code is null),
    'a foreign key, so this cannot drift';

  return query select 'a sales document no longer authorises procurement',
    not exists (select 1 from erp_ref.document_type t
                 where t.module_code = 'sales'
                   and t.create_permission like 'procurement.%'),
    'three of them did: quotation, sales_order and delivery';

  select count(*) into v_n from erp_ref.document_type t
   where split_part(t.create_permission, '.', 1) <> t.module_code;
  return query select 'and every type takes a permission from its own module',
    v_n = 2,
    'the two exceptions are the invoice and credit references, module_code '
    'finance. That was originally justified by "the only authored invoice '
    'transition uses sales.invoice", which was wrong: purchase_invoice sits on '
    'the same base and wants procurement.match. The base is now a default and '
    'the tenant type overrides it — see the cases below';

  -- ---------------------------------------------------------------------
  -- A principal who holds one module and nothing else
  -- ---------------------------------------------------------------------

  -- Finance first: configure_sales refuses with ERPWARE_NO_LEDGER otherwise,
  -- because a document that cannot be accounted for is not a document.
  perform erp.configure_finance();
  perform erp.configure_inventory();
  perform erp.configure_sales();
  perform erp.configure_procurement();
  -- purchase_invoice lives here, and it is the type that proved a base type is
  -- not fine-grained enough to say who may raise a document.
  perform erp.configure_procurement_controls();

  res := public.erp_save_role(null, 'sales_clerk', 'Sales clerk',
    'Holds the sales module and nothing else.',
    array(select p.code from erp_ref.permission p where p.module_code = 'sales'));
  v_role := (res ->> 'role_id')::uuid;

  res := public.erp_invite_principal('clerk@zzdocauth.test', 'Sales Clerk');
  v_clerk := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';
  perform erp.grant_role(v_clerk, 'sales_clerk', null, null, 'sales only');

  -- Master data the clerk will need, created by the administrator.
  -- purchase_order declares requires_site, so the refusals below have to be
  -- given a site or they would pass on the wrong error.
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (v_tenant, v_entity, 'MAIN', 'Main site', 'warehouse', 'active')
  returning id into v_site;

  v_uom := erp.create_uom('EA', 'Each', 'quantity'::erp.uom_class, 0::smallint, true);
  v_item := erp.create_item('WIDGET', 'Widget');
  v_party := erp.create_party('CUST', 'Customer Ltd', array['customer']::erp.party_role_kind[]);

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);

  return query select 'the clerk holds sales and only sales',
    (select count(*) from erp_ref.permission p where p.module_code = 'sales') > 0
      and not exists (
        select 1 from erp.effective_permission ep
         where ep.app_user_id = v_clerk and ep.permission_code not like 'sales.%'),
    'the first suite in this repository to act as anything but an administrator';

  -- ---------------------------------------------------------------------
  -- The case the whole migration exists for
  -- ---------------------------------------------------------------------

  begin
    v_doc := erp.open_document('quotation', v_party, v_entity);
    v_ok := v_doc is not null; v_msg := 'raised';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a sales principal can raise a quotation',
    v_ok, v_msg;

  begin
    perform erp.add_document_line(v_doc, v_item, 5, 1000);
    v_ok := true; v_msg := 'line added';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and add a line to it',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- And is still refused everything else
  -- ---------------------------------------------------------------------

  begin
    perform erp.open_document('purchase_order', v_party, v_entity, v_site);
    v_ok := false; v_msg := 'a sales principal raised a purchase order';
  exception when others then
    -- Assert on the permission specifically. Any-error would have passed on
    -- ERPWARE_DOCUMENT_SITE_REQUIRED, which is how this case first went green
    -- for the wrong reason.
    v_ok := sqlerrm like '%procurement.order%' or sqlerrm like 'ERPWARE_PERMISSION_DENIED%';
    v_msg := left(sqlerrm, 70);
  end;
  return query select 'but not a purchase order, and refused on the permission',
    v_ok, v_msg;

  begin
    perform erp.open_document('goods_receipt', v_party, v_entity);
    v_ok := false; v_msg := 'a sales principal raised a receipt';
  exception when others then
    -- Either the type does not exist in this tenant or the permission is
    -- refused; both are a refusal to receive stock, which is the point.
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor a goods receipt',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- The administrator, who holds everything, still can
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  begin
    perform erp.open_document('purchase_order', v_party, v_entity, v_site);
    v_ok := true; v_msg := 'raised';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 70);
  end;
  -- Without this case the two refusals above would pass just as well if the
  -- fix had broken purchase orders for everybody.
  return query select 'an administrator can still raise a purchase order',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- Two tenant types on one base type, wanting different permissions
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.set_active_tenant(v_tenant);

  return query select 'purchase_invoice overrides the base it inherits from',
    (select dt.create_permission from erp.document_type dt
      where dt.tenant_id = v_tenant and dt.code = 'purchase_invoice')
      = 'procurement.match',
    'its whole lifecycle is procurement.match, so raising one must be too';

  return query select 'and sales_invoice, on the same base, still inherits',
    (select coalesce(dt.create_permission, bt.create_permission)
       from erp.document_type dt
       join erp_ref.document_type bt on bt.code = dt.base_type_code
      where dt.tenant_id = v_tenant and dt.code = 'sales_invoice')
      is not distinct from 'sales.invoice',
    'the override is per type, so fixing one did not move the other';

  -- The behaviour, not just the register. A principal holding procurement and
  -- nothing else is the person who registers a purchase invoice; before the
  -- override they were refused sales.invoice when raising one.
  res := public.erp_save_role(null, 'buyer', 'Buyer',
    'Holds the procurement module and nothing else.',
    array(select p.code from erp_ref.permission p where p.module_code = 'procurement'));

  res := public.erp_invite_principal('buyer@zzdocauth.test', 'Buyer');
  v_tok := res ->> 'token';
  perform erp.grant_role((res ->> 'app_user_id')::uuid, 'buyer', null, null, 'procurement only');

  insert into auth.users (id, email) values (a3, 'buyer@zzdocauth.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.set_active_tenant(v_tenant);

  begin
    v_doc := erp.open_document('purchase_invoice', v_party, null, v_site);
    v_ok := true; v_msg := 'raised';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a principal holding only procurement can raise one',
    v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.set_active_tenant(v_tenant);
  begin
    perform erp.open_document('purchase_invoice', v_party, null, v_site);
    v_ok := false; v_msg := 'the sales clerk raised a purchase invoice';
  exception when others then
    v_ok := sqlerrm like '%procurement.match%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and a principal holding only sales cannot',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2, a3);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant)
      and not exists (select 1 from auth.users u where u.id in (a1, a2, a3)),
    'tenant and all three fabricated subjects';
end;
$suite$;

-- Eleven cases became fifteen: four added above.
create or replace function erp_test.assert_document_authorisation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 15;
begin
  create temporary table if not exists zz_docauth_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_docauth_result;
  insert into zz_docauth_result select * from erp_test.document_authorisation_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_docauth_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_DOCUMENT_AUTHORISATION_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_DOCUMENT_AUTHORISATION_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('document authorisation: %s/%s', v_pass, v_total);
end;
$$;
