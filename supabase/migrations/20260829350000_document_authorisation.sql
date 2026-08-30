-- =============================================================================
-- A document authorises the module it belongs to
--
-- erp.open_document's own comment said "Product content decides which that is,
-- so a tenant cannot turn a receipt into something a buyer may raise." The code
-- underneath it decided with a CASE that could only ever name a procurement
-- permission:
--
--   case when bt.flow = 'inbound' then 'procurement.receive'
--        when dt.code = 'requisition' then 'procurement.requisition'
--        else 'procurement.order' end
--
-- Eight of the thirteen base types fell through to that else. Raising a
-- quotation, a sales order, a delivery, a stock adjustment, a stock count, a
-- transfer order, a works order or an invoice reference all required
-- procurement.order. So a principal holding every sales permission could not
-- raise a quotation — while the quotation lifecycle's own transitions
-- correctly require sales.order, which meant the permission to *create* a
-- document and the permission to *move* it disagreed.
--
-- The middle arm has a second bug: it reads dt.code, the tenant's name for its
-- own type, rather than bt.code. A tenant type called 'requisition' got
-- procurement.requisition whatever it inherited from, and a requisition called
-- anything else did not.
--
-- Why no suite caught it: every suite provisions a tenant and acts as its
-- administrator, who holds all sixty-seven permissions. A test that holds
-- everything cannot tell you which one was checked. The suite below is the
-- first in the repository to act as a principal holding one module's
-- permissions and nothing else.
--
-- The fix is not a better CASE. erp_ref.document_type already carries
-- module_code; it now also carries the permission raising that type requires,
-- so the comment above becomes true — product content really does decide, and
-- a base type added later cannot forget to say, because the column is not
-- null.
--
-- Mapping evidence, rather than taste: each base type takes the permission its
-- own authored lifecycle already uses for the equivalent act. The delivery
-- machine's transitions require sales.despatch, so raising a delivery does.
-- The sales order's require sales.order. The receipt's require
-- procurement.receive.
-- =============================================================================

alter table erp_ref.document_type
  add column if not exists create_permission text references erp_ref.permission(code);

update erp_ref.document_type set create_permission = v.perm from (values
  -- sales: the lifecycle transitions in 20260829210000_sales.sql name these
  ('quotation',          'sales.order'),
  ('sales_order',        'sales.order'),
  ('delivery',           'sales.despatch'),

  -- procurement: unchanged in effect — these three are what the old CASE
  -- already produced, which is why procurement was the one module that worked.
  ('purchase_order',     'procurement.order'),
  ('requisition',        'procurement.requisition'),
  ('receipt',            'procurement.receive'),
  ('return_to_supplier', 'procurement.order'),

  -- inventory: an adjustment is not a purchase order, and required one.
  ('adjustment',         'inventory.adjust'),
  ('count',              'inventory.count'),
  ('transfer_order',     'inventory.move'),

  ('works_order',        'production.order'),

  -- The two reference types carry module_code 'finance', but the only authored
  -- invoice transition in the product uses sales.invoice, and raising an
  -- invoice reference is that same act. finance.post is about posting a
  -- journal, which is a different question asked later.
  ('invoice_reference',  'sales.invoice'),
  ('credit_reference',   'sales.invoice')
) as v(code, perm)
where erp_ref.document_type.code = v.code;

alter table erp_ref.document_type
  alter column create_permission set not null;

comment on column erp_ref.document_type.create_permission is
  'The permission raising a document of this base type requires. Not null, so '
  'a base type added later cannot silently inherit somebody else''s module: '
  'the build fails instead.';

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
  perform erp.authorise(bt.create_permission,
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
  select bt.create_permission into v_perm
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
$$;

-- =============================================================================
-- The suite
--
-- Deliberately inside the bootstrap window. onboard_tenant leaves the tenant
-- not live, so module installs auto-promote and roles can be authored directly
-- — which keeps this suite about authorisation rather than about B6.
-- =============================================================================

create or replace function erp_test.document_authorisation_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
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
    'the two exceptions are the invoice and credit references: module_code '
    'finance, but the only authored invoice transition in the product uses '
    'sales.invoice, and raising an invoice reference is that same act';

  -- ---------------------------------------------------------------------
  -- A principal who holds one module and nothing else
  -- ---------------------------------------------------------------------

  -- Finance first: configure_sales refuses with ERPWARE_NO_LEDGER otherwise,
  -- because a document that cannot be accounted for is not a document.
  perform erp.configure_finance();
  perform erp.configure_inventory();
  perform erp.configure_sales();
  perform erp.configure_procurement();

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

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant)
      and not exists (select 1 from auth.users u where u.id in (a1, a2)),
    'tenant and both fabricated subjects';
end;
$$;

create or replace function erp_test.assert_document_authorisation_suite()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 11;
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

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_no_dead_configuration();
select erp.assert_public_api_safe();
select erp.assert_isolation();
