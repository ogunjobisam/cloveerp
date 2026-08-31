-- Bring a database that has the generated work but none of this session's to
-- the state main describes.
--
-- WHY THIS FILE EXISTS RATHER THAN A REPLAY
--
-- The production project has 139 migrations applied, newest 20260830134027. It
-- has every migration written by the Lovable integration and none of the eight
-- written in this session. Five of those eight are numbered *earlier* than work
-- already applied there, so the repository's filename order and production's
-- actual history disagree.
--
-- Replaying the eight in filename order was tried against a local copy of that
-- state. All eight fail and none applies:
--
--   20260829330000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
--   20260829340000  ERPWARE_PUBLIC_API_UNSAFE: 114 finding(s)
--   20260829350000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
--   20260829360000  column bt.create_permission does not exist
--   20260829370000  ERPWARE_PUBLIC_API_UNSAFE: 112 finding(s)
--   20260830140000  function erp.create_party(...) does not exist
--   20260830150000  function public.erp_create_party_with_roles(...) does not exist
--   20260831130000  column bt.create_permission does not exist
--
-- The cause is worth stating because it is structural rather than accidental.
-- Each of the Aug-29 migrations ends by calling erp.assert_public_api_safe(),
-- which on that database is still the blanket ban on public SECURITY DEFINER.
-- The platform-owner layer added later violates it 27 times. The migration that
-- turns that ban into a registered one is 20260830140000 — which sorts after
-- them, and which itself then fails because the migration it depends on rolled
-- back. Every migration is atomic, so each failure leaves nothing behind and
-- the next fails on the gap.
--
-- So this file is generated from the target rather than replayed toward it.
-- Every function body below came from pg_get_functiondef() against a build of
-- main from empty; nothing was retyped. The order is dependency order, not
-- filename order: the column first, then erp, then the public wrappers that
-- read them, then the registers, then the generators, then the assertions.
--
-- It is a no-op on a database already carrying main: every statement is either
-- CREATE OR REPLACE, ON CONFLICT, IF EXISTS, or a generator that is idempotent
-- by construction. That is asserted at the tail, and checked in CI by the same
-- build-from-empty this repository has always used.
-- ── 1. Columns ──────────────────────────────────────────────────────────────

alter table erp_ref.document_type
  add column if not exists create_permission text;

alter table erp.document_type
  add column if not exists create_permission text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'erp.document_type'::regclass
       and conname = 'document_type_create_permission_fkey')
  then
    alter table erp.document_type
      add constraint document_type_create_permission_fkey
      foreign key (create_permission) references erp_ref.permission (code);
  end if;
end $$;

-- ── 2. Base-type create permissions, then NOT NULL ──────────────────────────

update erp_ref.document_type set create_permission = v.perm
  from (values
    ('adjustment', 'inventory.adjust'),
    ('count', 'inventory.count'),
    ('credit_reference', 'sales.invoice'),
    ('delivery', 'sales.despatch'),
    ('invoice_reference', 'sales.invoice'),
    ('purchase_order', 'procurement.order'),
    ('quotation', 'sales.order'),
    ('receipt', 'procurement.receive'),
    ('requisition', 'procurement.requisition'),
    ('return_to_supplier', 'procurement.order'),
    ('sales_order', 'sales.order'),
    ('transfer_order', 'inventory.move'),
    ('works_order', 'production.order')
  ) as v(code, perm)
 where erp_ref.document_type.code = v.code
   and erp_ref.document_type.create_permission is distinct from v.perm;

alter table erp_ref.document_type
  alter column create_permission set not null;

comment on column erp_ref.document_type.create_permission is
  'The permission raising a document of this base type requires. Not null, so '
  'a base type added later cannot silently inherit somebody else''s module: '
  'the build fails instead.';

comment on column erp.document_type.create_permission is
  'Overrides erp_ref.document_type.create_permission for this tenant type. '
  'Null means inherit the base type, which is the usual case; it is set when '
  'two tenant types share a base type and need different permissions.';

-- ── 3. erp functions ────────────────────────────────────────────────────────
--
-- erp.public_api_report() is in this set and matters most: it is the relaxed,
-- registered form of the SECURITY DEFINER rule. It has to be in place before
-- any assertion runs at the tail, which is exactly what filename order could
-- not arrange.

CREATE OR REPLACE FUNCTION erp.add_document_line(p_document_id uuid, p_item_id uuid, p_quantity numeric, p_unit_price_minor bigint DEFAULT 0, p_description text DEFAULT NULL::text, p_required_date date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION erp.assert_document_create_permissions()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION erp.assert_transaction_control_routines()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %I.%I carries %s', n.nspname, p.proname,
                                     array_to_string(p.proconfig, ', ')), E'\n')
    into v_count, v_detail
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test')
     and p.prokind = 'p'
     and p.proconfig is not null
     and p.prosrc ~* '\mcommit\M';

  if v_count > 0 then
    raise exception
      'ERPWARE_TRANSACTION_CONTROL_BLOCKED: % procedure(s) commit but carry a '
      'SET clause, which PostgreSQL refuses at run time', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = 'Schema-qualify the body and RESET the setting; a routine '
                   'that must COMMIT cannot carry one.';
  end if;

  return format('%s procedures perform transaction control, none blocked',
    (select count(*) from pg_catalog.pg_proc p2
      join pg_catalog.pg_namespace n2 on n2.oid = p2.pronamespace
     where n2.nspname like 'erp%' and p2.prokind = 'p'
       and p2.prosrc ~* '\mcommit\M'));
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.configure_procurement_controls(p_approver_role text DEFAULT 'administrator'::text, p_over_receipt_pct numeric DEFAULT 5, p_price_variance_pct numeric DEFAULT 2, p_price_variance_minor bigint DEFAULT 100)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION erp.create_item(p_code text, p_name text, p_stock_uom_id uuid DEFAULT NULL::uuid, p_item_class text DEFAULT NULL::text, p_values jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_uom    uuid := p_stock_uom_id;
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'item', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_ITEM_CODE_REQUIRED: an item needs a code'
      using errcode = '23514';
  end if;

  -- Same resolution erp.load_import does, so an item created either way holds
  -- the same unit.
  if v_uom is null then
    select u.id into v_uom
      from erp.uom u
     where u.tenant_id = v_tenant and u.is_base and u.status = 'active'
     order by u.code
     limit 1;
  end if;

  if v_uom is null then
    raise exception
      'ERPWARE_NO_BASE_UOM: this tenant has no base unit of measure, and an '
      'item is stocked in one'
      using errcode = '23502',
            hint = 'erp_create_uom(''EA'', ''Each'', ''quantity'', 0, true) '
                   'creates one. Every item in the tenant will be stocked in '
                   'it unless given another.';
  end if;

  if not exists (select 1 from erp.uom u
                  where u.tenant_id = v_tenant and u.id = v_uom) then
    raise exception 'ERPWARE_UNKNOWN_UOM: % is not a unit in this tenant', v_uom
      using errcode = '23503';
  end if;

  insert into erp.item (tenant_id, code, name, item_class, stock_uom_id,
                        lifecycle, status)
  values (v_tenant, trim(p_code), coalesce(nullif(trim(p_name), ''), trim(p_code)),
          nullif(trim(coalesce(p_item_class, '')), ''), v_uom, 'active', 'active')
  returning id into v_id;

  if p_values <> '{}'::jsonb then
    perform erp.write_master_fields('item', v_id, p_values - 'code');
  end if;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.create_party(p_code text, p_name text, p_role_kinds erp.party_role_kind[] DEFAULT '{}'::erp.party_role_kind[], p_country_code character DEFAULT NULL::bpchar, p_legal_name text DEFAULT NULL::text, p_values jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_kind   erp.party_role_kind;
begin
  perform erp.authorise('master_data.write', null, null, null, 'party', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_PARTY_CODE_REQUIRED: a party needs a code'
      using errcode = '23514';
  end if;

  -- The same four columns load_import's insert branch writes, plus the two a
  -- person typing a form would obviously supply.
  insert into erp.party (tenant_id, code, name, legal_name, country_code, status)
  values (v_tenant, trim(p_code), coalesce(nullif(trim(p_name), ''), trim(p_code)),
          nullif(trim(coalesce(p_legal_name, '')), ''), p_country_code, 'active')
  returning id into v_id;

  foreach v_kind in array coalesce(p_role_kinds, '{}'::erp.party_role_kind[])
  loop
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (v_tenant, v_id, v_kind, 'active')
    on conflict do nothing;
  end loop;

  -- Everything beyond the mandatory columns goes through the same function the
  -- import uses, so there is one definition of what may be written and one
  -- place the field-approval rules apply.
  if p_values <> '{}'::jsonb then
    perform erp.write_master_fields('party', v_id, p_values - 'code');
  end if;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.create_uom(p_code text, p_name text, p_uom_class erp.uom_class DEFAULT 'quantity'::erp.uom_class, p_decimals smallint DEFAULT 0, p_is_base boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  perform erp.authorise('master_data.write', null, null, null, 'uom', null);

  if coalesce(trim(p_code), '') = '' then
    raise exception 'ERPWARE_UOM_CODE_REQUIRED: a unit of measure needs a code'
      using errcode = '23514';
  end if;

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (v_tenant, upper(trim(p_code)), coalesce(nullif(trim(p_name), ''), upper(trim(p_code))),
          p_uom_class, greatest(p_decimals, 0::smallint), p_is_base, 'active')
  returning id into v_id;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.document_create_permission_report()
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION erp.document_transition_context(p_document_id uuid, p_transition_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
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

  return v_ctx;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.ensure_base_uom(p_tenant_id uuid, p_principal uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_id uuid;
begin
  select u.id into v_id from erp.uom u
   where u.tenant_id = p_tenant_id
     and u.is_base
     and u.uom_class = 'quantity'::erp.uom_class
     and u.status = 'active'::erp.record_status
   order by u.code limit 1;
  if v_id is not null then return v_id; end if;

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status, created_by)
  values (p_tenant_id, 'EA', 'Each', 'quantity'::erp.uom_class, 0, true,
          'active'::erp.record_status, p_principal)
  on conflict (tenant_id, code) do update set is_base = true
  returning id into v_id;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.open_document(p_type_code text, p_party_id uuid DEFAULT NULL::uuid, p_entity_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid, p_their_ref text DEFAULT NULL::text, p_required_date date DEFAULT NULL::date, p_currency character DEFAULT NULL::bpchar)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION erp.preview_import(p_batch_id uuid)
 RETURNS TABLE(row_no integer, action text, code text, target_id uuid, changes jsonb, findings jsonb)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- The gate this pipeline never had. Staging and loading both authorise
  -- master_data.import; validating and previewing did not, which left two
  -- of the four steps open to any principal who could reach the wrapper.
  perform erp.authorise('master_data.import', null, null, null,
                        'import_batch', p_batch_id);

  if b.status = 'received' then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATED: validate % before previewing it', b.code
      using errcode = '23514';
  end if;

  update erp.import_batch set status = 'previewed', updated_at = now()
   where id = p_batch_id and status = 'validated';

  return query
    select r.row_no, r.action, r.raw ->> 'code', r.target_id,
           case when r.target_id is null then r.raw
                else (select jsonb_object_agg(k.key, jsonb_build_object(
                               'from', erp.master_record(b.object_type, r.target_id) -> k.key,
                               'to',   k.value))
                        from jsonb_each(r.raw - 'code') k
                       where erp.master_record(b.object_type, r.target_id) -> k.key
                             is distinct from k.value)
           end,
           r.findings
      from erp.import_row r
     where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id
     order by r.row_no;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.public_api_report()
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
  ),
  -- Everything in erp/erp_meta that authorises, and everything that reaches
  -- something that authorises within six hops. Used to judge whether a public
  -- DEFINER function gates, whether it does so itself or through the erp
  -- function it delegates to.
  authorising as (
    select f.oid, f.ns, f.proname from fn f
     where position('erp.authorise(' in f.prosrc) > 0
        or position('erp_meta.require_platform(' in f.prosrc) > 0
  ),
  reaches_gate as (
    select a.oid as reached, 0 as depth from authorising a
    union
    select e.caller, r.depth + 1
      from reaches_gate r join edge e on e.callee = r.reached
     where r.depth < 6
  ),
  secdef_ok as (
    select p.oid
      from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
       and (
         position('erp.authorise(' in p.prosrc) > 0
         or position('erp_meta.require_platform(' in p.prosrc) > 0
         or exists (
           select 1 from fn f join reaches_gate g on g.reached = f.oid
            where position(f.ns || '.' || f.proname || '(' in p.prosrc) > 0)
       )
  )
  select 'a public API function is SECURITY DEFINER and is not registered',
         p.oid::regprocedure::text,
         'it runs as the owner, who bypasses row-level security; add it to '
         'erp_meta.security_definer_allowance under schema_name ''public'' '
         'with a rationale, or make it SECURITY INVOKER'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%' and p.prosecdef
     and not exists (select 1 from erp_meta.security_definer_allowance a
                      where a.schema_name = 'public' and a.function_name = p.proname)
  union all
  select 'a registered SECURITY DEFINER function reaches no authorisation',
         p.oid::regprocedure::text,
         'it is exempt from the blanket ban but still never asks whether the '
         'caller may; registration excuses the bypass, not the gate'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%' and p.prosecdef
     and exists (select 1 from erp_meta.security_definer_allowance a
                  where a.schema_name = 'public' and a.function_name = p.proname
                    and a.rationale not like 'UNGATED BY DESIGN:%')
     and not exists (select 1 from secdef_ok s where s.oid = p.oid)
  union all
  -- Three names carried two functions each before this migration, and every
  -- one of them was a live breakage: a call matching both candidates and
  -- neither, raising "is not unique" rather than failing a case. CREATE OR
  -- REPLACE silently overloads when the argument list differs, so this is what
  -- editing a public function through a slightly different signature looks
  -- like, and nothing was watching for it.
  --
  -- The register is keyed on function_name alone, so it cannot describe two
  -- functions sharing a name even when both are reachable. One name, one
  -- function.
  select 'two functions share a public API name',
         'public.' || p.proname,
         format('%s overloads: %s. A caller relying on defaults matches both '
                'and resolves to neither', count(*),
                string_agg(pg_catalog.pg_get_function_arguments(p.oid), ' | '))
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
   group by p.proname
  having count(*) > 1
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
$function$
;

CREATE OR REPLACE FUNCTION erp.transition_document(p_document_id uuid, p_transition_code text, p_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
  v_ctx    jsonb;
  v_to     text;
  v_committed boolean;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;

  -- The context the guards are evaluated against, from the one function that
  -- knows how to build it. It was assembled here and nowhere else, which meant
  -- erp.available_transitions() — the function a screen asks "what may I do
  -- next?" — could only be called with '{}', and reported every value-banded
  -- transition as blocked. The menu and the enforcement now read one
  -- definition.
  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);

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

  -- Committed means the outside world now believes this, and both ledgers have
  -- to agree at that moment.
  --
  -- Each half is asked separately, because a sales order passes through three
  -- committed states and only the first of them should raise anything. Asking
  -- "has this already posted?" of each ledger is what makes the second and
  -- third transitions quiet instead of a duplicate-posting error.
  if coalesce(v_committed, false) then
    if bt.affects_stock
       and not exists (select 1 from erp.stock_movement m
                        where m.tenant_id = v_tenant and m.document_id = p_document_id)
    then
      perform erp.post_document_stock(p_document_id);
    end if;

    if bt.affects_finance
       and not exists (select 1 from erp.journal j
                        where j.tenant_id = v_tenant and j.document_id = p_document_id)
    then
      perform erp.post_document_finance(p_document_id);
    end if;
  end if;

  return v_to;
end;
$function$
;

CREATE OR REPLACE FUNCTION erp.validate_import(p_batch_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_table  text;
  r        record;
  v_find   jsonb;
  v_target uuid;
  v_bad    text;
  v_errors integer := 0;
begin
  select * into b from erp.import_batch
   where tenant_id = v_tenant and id = p_batch_id for update;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_IMPORT: %', p_batch_id using errcode = '23503';
  end if;

  -- The gate this pipeline never had. Staging and loading both authorise
  -- master_data.import; validating and previewing did not, which left two
  -- of the four steps open to any principal who could reach the wrapper.
  perform erp.authorise('master_data.import', null, null, null,
                        'import_batch', p_batch_id);

  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'ERPWARE_IMPORT_NOT_VALIDATABLE: % is %', b.code, b.status
      using errcode = '23514';
  end if;

  select distinct m.table_name into v_table
    from erp_meta.maintainable_field m where m.object_type = b.object_type;

  for r in select * from erp.import_row
            where tenant_id = v_tenant and import_batch_id = p_batch_id
            order by row_no
  loop
    v_find := '[]'::jsonb;
    v_target := null;

    -- Every row must name the record it is about.
    if coalesce(r.raw ->> 'code', '') = '' then
      v_find := v_find || jsonb_build_object(
        'severity','error','message','no code, so this row names no record');
    else
      execute format('select t.id from erp.%I t where t.tenant_id = $1 and t.code = $2',
                     v_table)
        into v_target using v_tenant, r.raw ->> 'code';
    end if;

    -- Every other key must be a field this product agreed may be written.
    select string_agg(k, ', ') into v_bad
      from jsonb_object_keys(r.raw) k
     where k <> 'code'
       and not exists (select 1 from erp_meta.maintainable_field m
                        where m.object_type = b.object_type and m.column_name = k);

    if v_bad is not null then
      v_find := v_find || jsonb_build_object(
        'severity','error','message', format('unknown or protected field(s): %s', v_bad));
    end if;

    update erp.import_row
       set findings = v_find,
           target_id = v_target,
           action = case
                      when jsonb_array_length(v_find) > 0 then 'reject'
                      when v_target is not null then 'update'
                      else 'insert' end,
           updated_at = now()
     where id = r.id;

    if jsonb_array_length(v_find) > 0 then v_errors := v_errors + 1; end if;
  end loop;

  update erp.import_batch
     set status = 'validated', error_count = v_errors, updated_at = now()
   where id = p_batch_id;

  return v_errors;
end;
$function$
;

-- ── 4. Two public overloads give way to wider ones ──────────────────────────
--
-- The surviving versions add p_limit with a default of 200, so a caller passing
-- only the old arguments still resolves. Dropped rather than left in place
-- because two functions sharing a public name make every defaulted call
-- ambiguous, and the register is keyed on name alone.

drop function if exists public.erp_parties(text, text);
drop function if exists public.erp_items(text);

-- ── 5. public wrappers ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.erp_create_party_with_roles(p_code text, p_name text, p_role_kinds text[] DEFAULT '{}'::text[], p_country_code text DEFAULT NULL::text, p_legal_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  select jsonb_build_object('party_id',
    erp.create_party(p_code, p_name, p_role_kinds::erp.party_role_kind[],
                     p_country_code::char(2), p_legal_name))
$function$
;

CREATE OR REPLACE FUNCTION public.erp_create_uom(p_code text, p_name text, p_uom_class text DEFAULT 'quantity'::text, p_decimals integer DEFAULT 0, p_is_base boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select jsonb_build_object('uom_id',
  erp.create_uom(p_code, p_name, p_uom_class::erp.uom_class,
                 p_decimals::smallint, p_is_base)) $function$
;

CREATE OR REPLACE FUNCTION public.erp_document_types(p_base_type_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.erp_items(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'item_id', i.id, 'code', i.code, 'name', i.name,
      'item_class', i.item_class, 'item_group', i.item_group,
      'lifecycle', i.lifecycle, 'status', i.status,
      'stock_uom_id', i.stock_uom_id,
      'stock_uom_code', u.code,
      'is_batch_controlled', i.is_batch_controlled,
      'is_serial_controlled', i.is_serial_controlled,
      'has_expiry', i.has_expiry) as x
      from erp.item i
      left join erp.uom u on u.tenant_id = i.tenant_id and u.id = i.stock_uom_id
     where i.tenant_id = erp.current_tenant_id()
       and i.status <> 'archived'
       and (p_search is null or i.code ilike '%' || p_search || '%'
                             or i.name ilike '%' || p_search || '%')
     order by i.code
     limit greatest(coalesce(p_limit, 200), 1)
  ) s
$function$
;

CREATE OR REPLACE FUNCTION public.erp_parties(p_role_kind text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) from (
    select jsonb_build_object(
      'party_id', p.id, 'code', p.code, 'name', p.name,
      'legal_name', p.legal_name, 'country_code', p.country_code,
      'status', p.status,
      'roles', coalesce((select jsonb_agg(distinct pr.role_kind::text)
                           from erp.party_role pr
                          where pr.tenant_id = p.tenant_id
                            and pr.party_id = p.id
                            and pr.status = 'active'), '[]'::jsonb)) as x
      from erp.party p
     where p.tenant_id = erp.current_tenant_id()
       -- A merged party still resolves for old references, but offering it in
       -- a picker would invite creating new ones against a dead record.
       and p.merged_into_id is null
       and p.status <> 'archived'
       and (p_role_kind is null
            or exists (select 1 from erp.party_role pr2
                        where pr2.tenant_id = p.tenant_id and pr2.party_id = p.id
                          and pr2.role_kind::text = p_role_kind
                          and pr2.status = 'active'))
       and (p_search is null or p.code ilike '%' || p_search || '%'
                             or p.name ilike '%' || p_search || '%')
     order by p.code
     limit greatest(coalesce(p_limit, 200), 1)
  ) s
$function$
;

CREATE OR REPLACE FUNCTION public.erp_tenant_state()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
    'is_live', erp.tenant_is_live(),
    'environment', (select jsonb_build_object('environment_id', e.id, 'code', e.code,
                                              'name', e.name, 'is_live', e.is_live)
                      from erp.environment e
                     where e.tenant_id = erp.current_tenant_id() and e.is_self),
    -- erp.go_live() refuses below two, so a screen can say why before the
    -- button fails rather than after.
    'administrators', (select count(distinct ur.app_user_id)
                         from erp.user_role ur
                         join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                        where ur.tenant_id = erp.current_tenant_id()
                          and r.code = 'administrator'),
    'dead_configuration', coalesce((
      select jsonb_agg(jsonb_build_object('finding', d.finding, 'detail', d.detail))
        from erp.dead_configuration_report() d), '[]'::jsonb))
$function$
;

CREATE OR REPLACE FUNCTION public.erp_uoms()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'uom_id', u.id, 'code', u.code, 'name', u.name,
           'uom_class', u.uom_class, 'decimals', u.decimals, 'is_base', u.is_base)
           order by u.code), '[]'::jsonb)
    from erp.uom u
   where u.tenant_id = erp.current_tenant_id() and u.status = 'active'
$function$
;

-- ── 6. Grants ───────────────────────────────────────────────────────────────
--
-- `from public, anon` on every one. Revoking from PUBLIC alone leaves the
-- execute grant Supabase's default privileges give anon, which is how a
-- party-creation door was briefly reachable unauthenticated.

revoke all on function erp_create_party_with_roles(text,text,text[],text,text) from public, anon;
grant execute on function erp_create_party_with_roles(text,text,text[],text,text) to authenticated;
revoke all on function erp_create_uom(text,text,text,integer,boolean) from public, anon;
grant execute on function erp_create_uom(text,text,text,integer,boolean) to authenticated;
revoke all on function erp_document_types(text) from public, anon;
grant execute on function erp_document_types(text) to authenticated;
revoke all on function erp_items(text,integer) from public, anon;
grant execute on function erp_items(text,integer) to authenticated;
revoke all on function erp_parties(text,text,integer) from public, anon;
grant execute on function erp_parties(text,text,integer) to authenticated;
revoke all on function erp_tenant_state() from public, anon;
grant execute on function erp_tenant_state() to authenticated;
revoke all on function erp_uoms() from public, anon;
grant execute on function erp_uoms() to authenticated;

-- ── 7. The write register ───────────────────────────────────────────────────
--
-- Every public function that is VOLATILE must be enumerated here with the gate
-- it calls. The whole set is asserted rather than only the difference, so this
-- file states the register it expects rather than assuming what is already
-- there.

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_account_determination_rules', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_accounts', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_add_document_line', 'erp.add_document_line', 'Adds a line to an uncommitted document. Gated on procurement.order, and refuses a document the outside world has already seen.'),
  ('erp_add_party_role', 'erp.authorise', 'Adds a trading role to a party under master_data.write; roles are additive and never remove history.'),
  ('erp_add_wave_line', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_age_back_release_area', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_allocate_landed_cost', 'erp.allocate_landed_cost', 'Spreads a landed-cost document over the receipts it belongs to. Authorises procurement.match and writes only valuation rows against receipts the caller can already see.'),
  ('erp_allocate_release_wave', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_amend_batch', 'erp.amend_batch', 'Amends a batch attribute under inventory.adjust, and records the reason on the batch record rather than overwriting history.'),
  ('erp_amend_document_line', 'erp.amend_document_line', 'Changes a line quantity under sales.order. Refuses once the document has left the states its type allows amendment in.'),
  ('erp_apply_calculated_policy', 'erp.apply_calculated_policy', 'Writes the calculated reorder policy back onto the item and site under planning.run, which is the whole point of calculating it.'),
  ('erp_apply_cash', 'erp.apply_cash', 'Applies a receipt across open subledger items under finance.post. Allocation only; it creates no ledger entry the posting rules did not already define.'),
  ('erp_apply_change_request', 'erp.apply_change_request', 'Applies an approved master-data change under master_data.approve, and refuses a request that has not cleared approval.'),
  ('erp_apply_mass_change', 'erp.apply_mass_change', 'Executes a mass change that was opened, previewed and approved first. Authorises master_data.write and is reversible through erp_reverse_mass_change.'),
  ('erp_approval_audit', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_approval_bands', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_approval_delegations', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_approval_routing_stamps', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_approve_change_set', 'erp.approve_change_set', 'Accepts a change set somebody else authored. Gated on administration.promote, and refuses the author outright.'),
  ('erp_approve_payment_run', 'erp.approve_payment_run', 'Approves a proposed payment run under finance.approve_payment, which is a distinct permission from finance.post precisely so the two can be held by different people.'),
  ('erp_approver_assignments', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_assign_department', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_assign_named_approver', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_audit_log', 'erp.authorise', 'Read wrapper for erp.audit_entry, gated on administration.audit_read inside erp.authorise(), which writes an access-decision audit row. That audited write is the only write and the reason the function is volatile.'),
  ('erp_book_operation_time', 'erp.book_operation_time', 'Books labour and output against a works order operation under production.execute. Shop-floor reporting is the highest-frequency write in the product and needs a first-class door.'),
  ('erp_book_shipment', 'erp.book_shipment', 'Records the carrier, service and cost against a planned shipment under logistics.plan.'),
  ('erp_cancel_command', 'erp.cancel_command', 'Cancels a queued outbound command under administration.integrate. Cancelling is the safe direction: the message is never sent.'),
  ('erp_change_requests', 'erp.change_request_governance', 'Lists governed change requests for the tenant; it writes only the authorisation audit entry every gated read records.'),
  ('erp_claim_invitation', 'erp.claim_invitation', 'Runs before the caller has a principal, so erp.authorise() has nothing to scope to. Its gate is possession of a single-use token, checked inside erp.claim_invitation(), which is itself on the SECURITY DEFINER allow-list.'),
  ('erp_classification_axes', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_classification_gaps', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_classification_values', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_classify_item', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_clear_kill_switch', 'erp.clear_kill_switch', 'Restores a target a kill switch disabled. Authorises administration.configure and is the only way back from erp_set_kill_switch.'),
  ('erp_close_period', 'erp.close_period', 'Closes a fiscal period under finance.close_period, after the checklist opened by erp_open_period_close is complete.'),
  ('erp_close_quality_event', 'erp.close_quality_event', 'Closes a quality event with its root cause and actions under quality.disposition. The three narrative fields are required by the function, not by the caller.'),
  ('erp_close_works_order', 'erp.close_works_order', 'Closes a works order and settles its variances under production.release, returning the settlement so the caller can show it.'),
  ('erp_code_divergences', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_code_templates', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_commit_allocation', 'erp.commit_allocation', 'Turns a soft allocation into a committed one under sales.despatch, against stock the balance guard has already agreed exists.'),
  ('erp_complete_close_task', 'erp.complete_close_task', 'Marks one period-close checklist task complete under finance.close_period, recording a waiver reason when the task is being skipped rather than done.'),
  ('erp_complete_warehouse_task', 'erp.complete_warehouse_task', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_configuration_columns', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_configure_finance', 'erp.configure_finance', 'Installs a tenant''s ledgers, calendar, chart of accounts and posting rules. Authorises finance.configure, and the rules themselves are submitted as a B6 change set that the caller cannot approve.'),
  ('erp_configure_inventory', 'erp.configure_inventory', 'Submits the costing policy, count programme and revised posting rules as a B6 change set the caller cannot approve; authorises through the installer.'),
  ('erp_configure_logistics', 'erp.configure_logistics', 'Submits the carrier tariffs as a B6 change set the caller cannot approve; a tariff anybody can edit makes the cheapest carrier whoever last touched it.'),
  ('erp_configure_master_data', 'erp.configure_master_data', 'Submits the quality and field-approval rules as a B6 change set the caller cannot approve; the installer authorises administration.configure.'),
  ('erp_configure_period_close', 'erp.configure_period_close', 'Submits the close task template as a B6 change set the caller cannot approve; a checklist the people being checked can shorten is not a control.'),
  ('erp_configure_planning', 'erp.configure_planning', 'Submits the planning policies as a B6 change set the caller cannot approve; the installer authorises administration.configure.'),
  ('erp_configure_procurement', 'erp.configure_procurement', 'Installs the procurement lifecycle through a B6 change set. Gated on administration.configure inside erp.configure_procurement().'),
  ('erp_configure_procurement_controls', 'erp.configure_procurement_controls', 'Submits the receipt and match tolerances as a B6 change set the caller cannot approve; the installer authorises administration.configure.'),
  ('erp_configure_production', 'erp.configure_production', 'Installs works order numbering and the variance accounts, and submits the issue method as a B6 change set the caller cannot approve.'),
  ('erp_configure_quality', 'erp.configure_quality', 'Installs the regulatory clock and submits the inspection plan as a B6 change set the caller cannot approve; authorises administration.configure.'),
  ('erp_configure_receivables', 'erp.configure_receivables', 'Submits the dunning policy as a B6 change set the caller cannot approve; the point at which an account is stopped is a commercial decision.'),
  ('erp_configure_sales', 'erp.configure_sales', 'Installs the sales lifecycle through a B6 change set. Gated on administration.configure inside erp.install_module_config(), which erp.configure_sales() delegates to.'),
  ('erp_configure_sales_controls', 'erp.configure_sales_controls', 'Submits the margin policy and its exception chain as a B6 change set the caller cannot approve; the installer authorises administration.configure.'),
  ('erp_configure_tax', 'erp.configure_tax', 'Submits the tax configuration as a B6 change set through the module installer, which authorises administration.configure. Nothing takes effect until the set is approved and promoted.'),
  ('erp_create_classified_item', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_create_document', 'erp.open_document', 'Creates a document of a configured type and starts its lifecycle. Gated inside erp.open_document() on the permission its flow implies.'),
  ('erp_create_item', 'erp.authorise', 'Creates an item. Authorises on master_data.write before it writes; the surviving overload of two, the other having made the name ambiguous.'),
  ('erp_create_party', 'erp.authorise', 'Creates a party and its first role. Authorises on master_data.write before it writes.'),
  ('erp_create_party_with_roles', 'erp.create_party', 'Creates a party holding several roles at once, which the single-role signature cannot express. Delegates to erp.create_party(), which authorises on master_data.write before it writes anything.'),
  ('erp_create_service_principal', 'erp.create_service_principal', 'Creates the non-human principal a worker runs as. Gated on administration.users inside erp.create_service_principal().'),
  ('erp_create_uom', 'erp.create_uom', 'Creates a unit of measure under master_data.write. Nothing else in the product could create one, and erp.item.stock_uom_id is not null, so without this a tenant can hold no items at all.'),
  ('erp_decide_approval', 'erp.decide_approval_task', 'Records an approve or reject decision on a task assigned to the caller; the decision itself is the audited write.'),
  ('erp_delegate_approval', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_department_members', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_departments', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_determination_coverage', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_determine_account', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_dimension_rules', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_dimensions', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_disposition_inspection', 'erp.disposition_inspection', 'Records the disposition of an inspection under quality.disposition. Accepting or rejecting material is a decision a person makes, so it needs a call they can make.'),
  ('erp_document_approval_chain', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_end_approval_delegation', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_end_approver_assignment', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_end_department_membership', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_end_item_supplier', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_entities', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_export_configuration', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_export_tenant', 'erp.authorise', 'Produces the tenant portability export under administration.export, and records the export as an audited event.'),
  ('erp_go_live', 'erp.go_live', 'Closes the tenant''s bootstrap window under administration.configure. It only ever tightens: after it, configuration changes through a promoted change set and an author may not approve their own.'),
  ('erp_grant_role', 'erp.authorise', 'Grants a role to a principal within the caller''s tenant. Gated on administration.roles.'),
  ('erp_import_batches', 'erp.authorise', 'Lists the caller''s import batches; it writes only the authorisation audit entry every gated read records.'),
  ('erp_import_configuration', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_invite_principal', 'erp.invite_principal', 'Creates a principal and returns its one-time token. Gated on administration.users inside erp.invite_principal().'),
  ('erp_invoice_against', 'erp.invoice_against', 'Matches an invoice line to an order line under procurement.match and returns the resulting match status, so a mismatch is visible at the moment it is created.'),
  ('erp_invoice_from_delivery', 'erp.invoice_from_delivery', 'Raises an invoice from a posted delivery under sales.invoice. Self-billing is opt-in through an explicit argument rather than a default.'),
  ('erp_issue_to_works_order', 'erp.issue_to_works_order', 'Issues components to a works order under production.execute, through the same stock movement bridge every other issue uses.'),
  ('erp_item_classification', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_item_code_assignments', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_item_posting_classes', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_item_suppliers', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_link_documents', 'erp.link_documents', 'Records a lineage relation between two documents under procurement.order. Lineage is read constantly and has to be writable through the API that reads it.'),
  ('erp_load_import', 'erp.load_import', 'Commits a validated import batch under master_data.import. Refuses a batch that has not passed erp_validate_import, and is undone by erp_rollback_import.'),
  ('erp_log_recall_action', 'erp.log_recall_action', 'Records one action taken during a recall under quality.recall. A recall whose actions cannot be logged is a recall with no evidence it happened.'),
  ('erp_merge_batches', 'erp.merge_batches', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_merge_master_record', 'erp.merge_master_record', 'Merges a duplicate into a survivor under master_data.approve, keeping the duplicate as a redirect rather than deleting it.'),
  ('erp_onboard_tenant', 'erp.onboard_tenant', 'Creates a tenant for a caller who has none. Its gate is that it can only ever bind the new tenant to auth.uid(); there is no tenant to authorise against, which is why erp.onboard_tenant() is on the definer allow-list.'),
  ('erp_open_change_request', 'erp.open_change_request', 'Opens a draft change request. Authorises master_data.write, and refuses any field not enumerated in erp_meta.maintainable_field; applying it needs approval it cannot grant itself.'),
  ('erp_open_mass_change', 'erp.open_mass_change', 'Opens a mass change for preview under master_data.write. Opening changes nothing: erp_apply_mass_change is the write.'),
  ('erp_open_period_close', 'erp.open_period_close', 'Raises the period-close checklist under finance.close_period and returns how many tasks it created.'),
  ('erp_open_release_wave', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_override_posting_account', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_party_posting_classes', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_permissions_directory', 'erp.authorise', 'Reads the tenant''s principals, roles and grants for the administration screen. Gated on administration.roles, and now INVOKER so row-level security scopes it rather than an explicit filter being trusted to.'),
  ('erp_plan_shipment', 'erp.plan_shipment', 'Groups deliveries into a shipment under logistics.plan, before anything is booked with a carrier.'),
  ('erp_platform_add_staff', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_audit', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_cancel_ownership_transfer', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_claim_ownership', 'erp_meta.platform_log', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_enter_tenant', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_invite_admin', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_leave_tenant', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_me', 'erp_meta.platform_actor', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_offer_ownership', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_onboard_company', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_ownership_transfers', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_respond_ownership_transfer', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_revoke_staff', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_set_staff_role', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_set_tenant_status', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_staff', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_platform_tenants', 'erp_meta.require_platform', 'Platform staff action, gated on the platform staff list rather than on erp.authorise(), because it is performed above every tenant.'),
  ('erp_post_count', 'erp.post_count', 'Posts a completed stock count under inventory.adjust and returns the variance, which is the number the count exists to produce.'),
  ('erp_posting_classes', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_posting_overrides', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_preview_approval_chain', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_preview_import', 'erp.preview_import', 'Previews a staged import batch; it writes only the preview verdict rows against the caller''s own batch.'),
  ('erp_preview_item_code', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_price_document_line', 'erp.price_document_line', 'Reprices a line through the promoted pricing policies under sales.price. The price comes from configuration; this call only asks for it to be applied.'),
  ('erp_principals', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_print_release_wave', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_promote_change_set', 'erp.promote_change_set', 'Applies an approved change set to this environment. Gated on administration.promote inside B6.'),
  ('erp_propose_payment_run', 'erp.propose_payment_run', 'Proposes a payment run under finance.approve_payment. Proposing pays nobody; erp_approve_payment_run does.'),
  ('erp_protected_values', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_put_protected_value', 'erp.put_tenant_secret', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_qualify_supplier', 'erp.qualify_supplier', 'Records a supplier qualification with an expiry under master_data.approve, which is what the procurement controls later check against.'),
  ('erp_raise_count_tasks', 'erp.raise_count_tasks', 'Raises the count tasks a counting programme is due under inventory.count.'),
  ('erp_raise_customer_return', 'erp.raise_customer_return', 'Raises a return against an original document under sales.order, with the reason and intended outcome recorded on it.'),
  ('erp_raise_putaway_tasks', 'erp.raise_putaway_tasks', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_raise_quality_event', 'erp.raise_quality_event', 'Raises a quality event under quality.disposition. A non-conformance nobody can record is a non-conformance that does not exist.'),
  ('erp_raise_recall', 'erp.raise_recall', 'Raises a recall over a set of batches under quality.recall, starting the regulatory clock the configuration defines.'),
  ('erp_raise_replenishment_tasks', 'erp.raise_replenishment_tasks', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_raise_works_order', 'erp.raise_works_order', 'Raises a works order under production.order, which is where every production movement afterwards hangs from.'),
  ('erp_read_protected_value', 'erp.get_tenant_secret', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_receive_against', 'erp.receive_against', 'Receives quantity against a purchase order line under procurement.receive, posting the inbound movement through the shared bridge.'),
  ('erp_receive_works_order_output', 'erp.receive_works_order_output', 'Receives finished output from a works order under production.execute, creating the batch when the item is batch-tracked.'),
  ('erp_record_count', 'erp.record_count', 'Records a counted quantity against a count task under inventory.count and returns whether the variance needs a recount.'),
  ('erp_record_inspection_result', 'erp.record_inspection_result', 'Records one measured characteristic under quality.inspect and returns whether it is within specification.'),
  ('erp_record_proof_of_delivery', 'erp.record_proof_of_delivery', 'Records proof of delivery against a shipment under logistics.despatch.'),
  ('erp_release_area_locations', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_release_areas', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_release_batch', 'erp.release_batch', 'Releases a batch for sale under quality.release_batch, which is a permission deliberately separate from quality.inspect.'),
  ('erp_release_credit_hold', 'erp.release_credit_hold', 'Releases an order from credit hold under sales.credit_release, with the reason recorded against the release.'),
  ('erp_release_wave_lines', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_release_waves', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_release_works_order', 'erp.release_works_order', 'Releases a works order to the floor under production.release, refusing on component shortage unless the caller says otherwise explicitly.'),
  ('erp_reopen_period', 'erp.reopen_period', 'Reopens a closed fiscal period under finance.reopen_period, which is its own permission because reopening is not the inverse of closing in any governance model worth the name.'),
  ('erp_replay_message', 'erp.replay_message', 'Replays a failed outbound message under administration.integrate, through the gateway rather than around it.'),
  ('erp_request_tenant_deletion', 'erp.authorise', 'Opens a tenant deletion request under administration.configure; deletion itself remains a separate, confirmed step.'),
  ('erp_reserve_for_line', 'erp.reserve_for_line', 'Reserves stock for an order line under sales.order, using the promoted allocation policy rather than an argument.'),
  ('erp_resolve_item_supplier', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_retire_account_determination', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_retire_approval_band', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_retire_posting_class', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_reverse_mass_change', 'erp.reverse_mass_change', 'Reverses an applied mass change under master_data.write. This is the undo the preview promises.'),
  ('erp_revoke_role', 'erp.authorise', 'Ends a grant. Gated on administration.roles.'),
  ('erp_rollback_import', 'erp.rollback_import', 'Rolls back a loaded import batch under master_data.import, which is the only reason loading one is safe.'),
  ('erp_rollback_to_snapshot', 'erp.rollback_to_snapshot', 'Restores configuration to a snapshot under administration.promote, which is B6 one-action rollback and has to be reachable to be worth having.'),
  ('erp_rotate_tenant_key', 'erp.rotate_tenant_key', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_run_forecast', 'erp.run_forecast', 'Runs a forecast under planning.forecast, producing a version nobody has signed off yet.'),
  ('erp_run_planning', 'erp.run_planning', 'Runs the planning engine, which authorises planning.run for the site and writes only suggested orders — nothing it produces reaches a supplier without erp.firm_planned_order() and a document afterwards.'),
  ('erp_save_role', 'erp.authorise', 'Creates or edits a role and its permission set. Gated on administration.roles.'),
  ('erp_seed_demo', 'erp.seed_demo', 'Builds a demonstration tenant for a caller who has none, on the same terms as onboarding and with the same reason for holding the privilege.'),
  ('erp_seed_demo_configuration', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_seed_demo_operations', 'erp.seed_demo_operations', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_set_account_dimension_requirements', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_set_active_tenant', 'erp.set_active_tenant', 'Records which of the caller''s own tenants is active. Its gate is membership: erp.set_active_tenant() refuses any tenant the caller holds no active principal in.'),
  ('erp_set_item_posting_class', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_set_item_supplier', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_set_kill_switch', 'erp.set_kill_switch', 'Disables a configuration target without editing it, under administration.configure. This is the emergency route the live-configuration guard names in its own hint.'),
  ('erp_set_party_posting_class', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_set_resource_override', 'erp.authorise', 'Records a tenant terminology override under administration.configure; product resource text itself is never changed.'),
  ('erp_sign_off_forecast', 'erp.sign_off_forecast', 'Signs off a forecast version under planning.forecast, which is what makes it the one planning consumes.'),
  ('erp_split_batch', 'erp.split_batch', 'Splits a batch under inventory.adjust, keeping both halves traceable to the original.'),
  ('erp_stage_import', 'erp.stage_import', 'Stages import rows under master_data.import. Staging writes nothing to master data: preview, validate and load are separate calls on purpose.'),
  ('erp_stamp_approval_routing', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_stamp_document_approval', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_submit_change_request', 'erp.submit_change_request', 'Submits a drafted master-data change for approval under master_data.write; it proposes, it does not apply.'),
  ('erp_submit_command', 'erp.submit_command', 'Queues an outbound command through the B8 gateway, which authorises, validates the payload against the operation schema, and records it.'),
  ('erp_tenant_keys', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_transition_document', 'erp.transition_document', 'Moves a document through its configured lifecycle. It does not authorise directly: the transition declares the permission it needs and erp.perform_transition() enforces it, which is why rule 3d follows the chain rather than stopping at the first hop.'),
  ('erp_trigger_job', 'erp.trigger_job', 'Runs a scheduled job out of band. Gated on administration.jobs inside erp.trigger_job(), which also refuses a job stopped by a kill switch.'),
  ('erp_upsert_account_determination', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_approval_band', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_classification_axis', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_classification_value', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_code_template', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_department', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_dimension_rule', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_posting_class', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_release_area', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_validate_import', 'erp.validate_import', 'Validates a staged import batch and writes row-level validation findings against the caller''s own batch.'),
  ('erp_wave_print_readiness', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_write_off_stock', 'erp.write_off_stock', 'Writes stock off under inventory.write_off, which is its own permission because a write-off is a loss rather than an adjustment.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;


-- ── 8. The SECURITY DEFINER register ────────────────────────────────────────
--
-- Rows under schema_name 'public' are the exemptions the relaxed rule reads. A
-- registered function is still required to reach an authorisation gate; the two
-- that genuinely cannot say so under an UNGATED BY DESIGN prefix.

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'claim_invitation', 'Runs before the caller has a principal, so row security on erp.app_user and erp.invitation would hide the rows it exists to find. Scoped to a single unclaimed, unexpired, unrevoked token digest; binds auth.uid() to one waiting row and can do nothing else.'),
  ('erp', 'complete_warehouse_task', 'Completes one warehouse task and posts the stock movement it represents. Loads the task by (tenant_id, id) first and refuses a task belonging to anyone else; authorises on inventory.adjust for that task''s own site.'),
  ('erp', 'data_quality_report', 'Reads erp_meta.maintainable_field, which the product role cannot read directly, and returns only rows for the caller''s own tenant.'),
  ('erp', 'data_quality_score', 'Scores a single master record against erp_meta.maintainable_field within the caller''s tenant scope.'),
  ('erp', 'destroy_tenant_keys', 'Crypto-shredding on deletion; internal only.'),
  ('erp', 'ensure_tenant_key', 'Creates key material in the platform key store, which tenants cannot reach directly.'),
  ('erp', 'get_tenant_secret', 'Decrypts under the tenant key; authorises administration.configure first.'),
  ('erp', 'merge_batches', 'Merges one batch into another and moves the balances across. Loads both batches within the caller''s tenant, refuses a self-merge, refuses batches of different items, demands a stated reason, and gates on inventory.adjust.'),
  ('erp', 'onboard_tenant', 'Creates a tenant for a caller who has no principal and therefore no tenant context, so row-level security has nothing to scope to. Writes only rows belonging to the tenant it is creating, and binds it to auth.uid().'),
  ('erp', 'platform_assurance', 'Runs the platform self-checks, which read the product rule catalogue in erp_meta rather than any tenant data, and returns only pass or fail per check.'),
  ('erp', 'principal_context', 'Breaks the RLS recursion on erp.app_user. Argument-free, single table, returns only the caller''s own row, never consults the trust check.'),
  ('erp', 'put_tenant_secret', 'Encrypts under the tenant key; authorises administration.configure first.'),
  ('erp', 'raise_putaway_tasks', 'Reads stock standing in receiving locations and raises a putaway task for each. Scoped to erp.require_tenant_id() throughout and gated on inventory.adjust for the site before it writes anything.'),
  ('erp', 'raise_replenishment_tasks', 'Compares pick-location cover against its minimum and raises replenishment tasks. Same tenant scope and the same inventory.adjust gate as putaway.'),
  ('erp', 'rotate_tenant_key', 'Re-protects ciphertext and destroys the superseded key; authorises administration.configure first.'),
  ('erp', 'score_master_record', 'Shared scoring helper for data quality; reads catalogue metadata only and never crosses tenant scope.'),
  ('erp', 'seed_demo', 'Same as onboard_tenant: builds a demonstration tenant for a caller who has none yet, so there is no context to run under. Reachable only by an authenticated caller who resolves to no principal.'),
  ('erp', 'seed_demo_billing', 'Demonstration billing history; internal only, called by the seeded operations builder.'),
  ('erp', 'seed_demo_bom', 'Builds a demonstration bill of materials inside the caller''s own tenant. Scoped to erp.require_tenant_id() and reachable only from the demo seeder, which is itself gated.'),
  ('erp', 'seed_demo_master_data', 'Creates demonstration master data inside the caller''s own tenant through the same governed writers a user would use.'),
  ('erp', 'seed_demo_operations', 'Builds demonstration warehouse operations inside the caller''s own tenant through the same writers a user would use. Gated on master_data.write.'),
  ('erp', 'set_active_tenant', 'Writes the caller''s own tenant choice, which is keyed on auth.uid() and therefore belongs to no tenant, so there is no context to run it under. Refuses any tenant the caller does not already hold an active principal in.'),
  ('erp', 'tenant_key_material', 'Reads key material; internal only, never granted to a session role.'),
  ('erp_meta', 'expire_ownership_offers', 'Lapses stale platform ownership offers. The table belongs to no tenant.'),
  ('erp_meta', 'platform_actor', 'Reads the platform staff list and the account address for the authenticated subject. Both are outside every tenant, so no tenant context can scope it.'),
  ('erp_meta', 'platform_log', 'Appends to the platform audit trail, which belongs to no tenant.'),
  ('erp_meta', 'require_platform', 'The platform authorisation gate. Must read the staff list, which no tenant owns.'),
  ('public', 'erp_complete_warehouse_task', 'Writes stock movements and task completion under erp.authorise(inventory.move); definer is required because erp tables are unreachable by the authenticated role.'),
  ('public', 'erp_merge_batches', 'Traceability merge across batch and movement tables; gated by erp.authorise(inventory.adjust) and audited.'),
  ('public', 'erp_platform_add_staff', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_audit', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_cancel_ownership_transfer', 'Platform-level operation above every tenant, gated on erp_meta.require_platform() and audited in erp_meta.platform_audit.'),
  ('public', 'erp_platform_claim_ownership', 'UNGATED BY DESIGN: claims the first platform owner, so by definition there is no platform staff yet to authorise against. Refuses outright once any un-revoked staff row exists, which makes it a one-time bootstrap rather than a standing door. NOTE: on a database where nobody has claimed it, the first authenticated caller becomes platform owner.'),
  ('public', 'erp_platform_enter_tenant', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_invite_admin', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_leave_tenant', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_me', 'UNGATED BY DESIGN: reports who the caller is to the platform, including the answer "nobody". A gate here would have to know the answer first. Returns only the caller''s own staff row, never anybody else''s.'),
  ('public', 'erp_platform_offer_ownership', 'Platform-level operation above every tenant, gated on erp_meta.require_platform() and audited in erp_meta.platform_audit.'),
  ('public', 'erp_platform_onboard_company', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_ownership_transfers', 'Platform-level operation above every tenant, gated on erp_meta.require_platform() and audited in erp_meta.platform_audit.'),
  ('public', 'erp_platform_respond_ownership_transfer', 'Platform-level operation above every tenant, gated on erp_meta.require_platform() and audited in erp_meta.platform_audit.'),
  ('public', 'erp_platform_revoke_staff', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_set_staff_role', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_set_tenant_status', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_staff', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_platform_tenants', 'Platform-level operation. It exists precisely to act above tenants, so no tenant context can scope it; it is gated on erp_meta.require_platform() and writes erp_meta.platform_audit.'),
  ('public', 'erp_protected_values', 'Protected value register, gated on administration.configure.'),
  ('public', 'erp_put_protected_value', 'Protected value write, gated on administration.configure.'),
  ('public', 'erp_raise_putaway_tasks', 'Creates warehouse tasks from receipt balances; gated by erp.authorise(inventory.move).'),
  ('public', 'erp_raise_replenishment_tasks', 'Creates replenishment tasks from stocking policy; gated by erp.authorise(inventory.move).'),
  ('public', 'erp_read_protected_value', 'Protected value read, gated on administration.configure.'),
  ('public', 'erp_rotate_tenant_key', 'Rotation entry point, gated on administration.configure.'),
  ('public', 'erp_seed_demo_operations', 'Demonstration data builder; gated by erp.authorise(administration.configure) and confined to the calling tenant.'),
  ('public', 'erp_set_active_tenant', 'Company selection for the signed-in principal; refuses unless the caller is platform staff.'),
  ('public', 'erp_tenant_keys', 'Key register for the tenant, gated on administration.configure.')
on conflict (schema_name, function_name) do update
  set rationale = excluded.rationale;

-- ── 9. English strings for the event types that had none ────────────────────

insert into erp_ref.resource (key, locale, value) values
  ('event.approval.chain_resolved', 'en', 'Approval chain resolved'),
  ('event.approval.cover_applied', 'en', 'Cover applied to an approval'),
  ('event.approval.cover_ended', 'en', 'Cover ended'),
  ('event.approval.cover_started', 'en', 'Cover started'),
  ('event.approval.escalated', 'en', 'Approval escalated'),
  ('event.approval.reapproval_triggered', 'en', 'Re-approval triggered'),
  ('event.item.classified', 'en', 'Item classified'),
  ('event.item.code_assigned', 'en', 'Item code assigned'),
  ('event.item.code_diverged', 'en', 'Item code diverged from its template'),
  ('event.posting.account_recorded', 'en', 'Posting account recorded'),
  ('event.posting.class_changed', 'en', 'Posting class changed'),
  ('event.posting.determination_failed', 'en', 'Account determination failed'),
  ('event.posting.rule_resolved', 'en', 'Posting rule resolved'),
  ('event.release.allocation_completed', 'en', 'Release wave allocated'),
  ('event.release.printed', 'en', 'Release wave printed'),
  ('event.release.wave_opened', 'en', 'Release wave opened'),
  ('event.replenishment.stock_returned', 'en', 'Stock returned to its home location'),
  ('event.replenishment.task_raised', 'en', 'Replenishment task raised'),
  ('event.sourcing.default_recorded', 'en', 'Default supplier recorded'),
  ('event.tenant.key_created', 'en', 'Tenant key created'),
  ('event.tenant.key_destroyed', 'en', 'Tenant key destroyed'),
  ('event.tenant.key_rotated', 'en', 'Tenant key rotated')
on conflict (key, locale) do update set value = excluded.value;

-- ── 10. The Part 5 register names functions with their argument lists ───────
--
-- The coverage check reads an artefact containing brackets as a function and
-- anything else as a relation, so a function written without its arguments was
-- looked up as a table and not found.

update erp_ref.part5_capability set artefacts = '{"erp.amend_batch(uuid,text,text,text)","erp.split_batch(uuid,text,numeric,uuid,text)",erp.batch_amendment,"erp.merge_batches(uuid,uuid,text)","public.erp_merge_batches(uuid,uuid,text)"}'::text[] where code = '5.2.batch_amendment';
update erp_ref.part5_capability set artefacts = '{erp.post_document_stock(uuid),"erp.receive_against(uuid,uuid,numeric,uuid)","erp.commit_allocation(uuid,uuid,uuid)",erp.customer_return,erp.warehouse_task,erp.raise_putaway_tasks(uuid),erp.raise_replenishment_tasks(uuid),"erp.complete_warehouse_task(uuid,numeric)"}'::text[] where code = '5.2.warehouse_operations';
update erp_ref.part5_capability set artefacts = '{erp.check_release_to_fulfilment(uuid),"public.erp_release_sequence(uuid,integer)"}'::text[] where code = '5.6.release_sequencing';
update erp_ref.part5_capability set artefacts = '{erp.post_document_finance(uuid),erp.grni_report(),erp.works_order_variance(uuid),erp.revaluation_report(date),public.erp_stock_provision()}'::text[] where code = '5.7.inventory_accounting';

-- ── 11. Tenant document types that override their base ─────────────────────
--
-- purchase_invoice and sales_invoice both sit on invoice_reference and want
-- different permissions; the base carries sales.invoice, which is right for one
-- and wrong for the other.

update erp.document_type
   set create_permission = 'procurement.match'
 where base_type_code = 'invoice_reference'
   and code = 'purchase_invoice'
   and create_permission is distinct from 'procurement.match';

-- ── 11a. The test schema ────────────────────────────────────────────────────
--
-- Not reachable by the application — erp_test is revoked from every role — but
-- main and production should not disagree about it either, and the suites are
-- what prove the engine still behaves. Ten routines: four suites added in this
-- session with their count assertions, and the bootstrap suite, which now
-- purges the tenant it creates instead of leaving it behind.

CREATE OR REPLACE FUNCTION erp_test.assert_bootstrap_window_suite()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Twenty-one, plus the case that the cleanup happened.
  c_expected constant integer := 22;
begin
  create temporary table if not exists zz_boot_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_boot_result;
  insert into zz_boot_result select * from erp_test.bootstrap_window_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_boot_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_BOOTSTRAP_WINDOW_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_BOOTSTRAP_WINDOW_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('bootstrap window: %s/%s', v_pass, v_total);
end;
$function$
;

CREATE OR REPLACE FUNCTION erp_test.assert_document_authorisation_suite()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION erp_test.assert_master_data_doors_suite()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Seventeen: eight on the doors, three on the completed pipeline, five
  -- refusals, and the purge.
  c_expected constant integer := 17;
begin
  create temporary table if not exists zz_doors_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_doors_result;
  insert into zz_doors_result select * from erp_test.master_data_doors_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_doors_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_MASTER_DATA_DOORS_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_MASTER_DATA_DOORS_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('master data doors: %s/%s', v_pass, v_total);
end;
$function$
;

CREATE OR REPLACE FUNCTION erp_test.assert_reference_reads_suite()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_pass integer; v_total integer; v_detail text;
  -- Thirteen: one proving the other tenant's fixtures exist, eleven reads,
  -- and the purge.
  c_expected constant integer := 13;
begin
  create temporary table if not exists zz_reads_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_reads_result;
  insert into zz_reads_result select * from erp_test.reference_reads_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_reads_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_REFERENCE_READS_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_REFERENCE_READS_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('reference reads: %s/%s', v_pass, v_total);
end;
$function$
;

CREATE OR REPLACE FUNCTION erp_test.assert_transition_menu_suite()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 9;
begin
  create temporary table if not exists zz_tmenu_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_tmenu_result;
  insert into zz_tmenu_result select * from erp_test.transition_menu_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_tmenu_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_TRANSITION_MENU_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_TRANSITION_MENU_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('transition menu: %s/%s', v_pass, v_total);
end;
$function$
;

CREATE OR REPLACE FUNCTION erp_test.bootstrap_window_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_onboard jsonb; v_tenant uuid; v_env uuid; v_second uuid; v_tok text;
  res jsonb; v_cs uuid; v_ok boolean; v_msg text; v_promo uuid;
  v_before integer;
begin
  -- ---------------------------------------------------------------------
  -- The self-service door
  -- ---------------------------------------------------------------------

  -- onboard_tenant() reads auth.uid() and then looks the subject up, because
  -- erp.app_user requires an email of every person. So the suite has to put one
  -- there: the self-service door starts at the platform's identity table, and a
  -- test that skipped it would be testing a different function.
  insert into auth.users (id, email) values (a1, 'solo@zzboot.test');
  insert into auth.users (id, email) values (a2, 'second@zzboot.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_onboard := erp.onboard_tenant('Bootstrap Window', 'zzboot');
  v_tenant := (v_onboard ->> 'tenant_id')::uuid;
  v_env    := (v_onboard ->> 'environment_id')::uuid;

  return query select 'the self-service door creates the is_self environment',
    v_env is not null
      and exists (select 1 from erp.environment e
                   where e.id = v_env and e.tenant_id = v_tenant and e.is_self),
    'without it every guard that asks answers "still being built", for ever';

  return query select 'and creates it not yet live',
    not (select e.is_live from erp.environment e where e.id = v_env),
    'a tenant has to be built before it can be governed';

  return query select 'erp.tenant_is_live() agrees',
    not erp.tenant_is_live(v_tenant),
    'the guard and the installer must answer this question the same way';

  -- ---------------------------------------------------------------------
  -- Inside the window
  -- ---------------------------------------------------------------------

  return query select 'and a root entity, so the tenant has a chart of accounts',
    (v_onboard ->> 'entity_id') is not null,
    'without one erp.configure_finance() refuses, and nothing that posts can '
    'be installed at all';

  v_cs := erp.configure_finance();
  perform erp.configure_inventory('average');

  return query select 'a solo administrator can install a module',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'promoted',
    'B6 refuses self-approval; before go-live there is no second person for '
    'it to find, which made a self-service tenant unconfigurable';

  return query select 'and the configuration it promoted is really there',
    (select count(*) from erp.posting_rule pr
      where pr.tenant_id = v_tenant and pr.status = 'active')
      = (select count(*) from erp.change_set_item i
          where i.change_set_id = v_cs and i.object_kind = 'posting_rule'),
    'promoted is a status on a row; every posting rule the set named has to '
    'be in erp.posting_rule for that status to mean anything';

  return query select 'the promotion records which environment it happened in',
    (select p.environment_id from erp.promotion p
      where p.tenant_id = v_tenant order by p.started_at desc limit 1) = v_env,
    'the column was nullable and the subquery returned null for this tenant, '
    'so promotion half-worked rather than refusing';

  -- ---------------------------------------------------------------------
  -- Closing it
  -- ---------------------------------------------------------------------

  begin
    perform erp.go_live();
    v_ok := false; v_msg := 'go_live() succeeded with one administrator';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_SINGLE_ADMINISTRATOR%'; v_msg := sqlerrm;
  end;
  return query select 'go-live refuses a tenant with one administrator',
    v_ok, v_msg;

  res := public.erp_invite_principal('second@zzboot.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  return query select 'go-live succeeds once there are two',
    (erp.go_live() ->> 'is_live')::boolean,
    'the second principal is what makes separation of duties possible at all';

  return query select 'and the tenant is live afterwards',
    erp.tenant_is_live(v_tenant),
    'the window is closed by a row, not by a session setting';

  begin
    perform erp.go_live();
    v_ok := false; v_msg := 'go_live() succeeded twice';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ALREADY_LIVE%'; v_msg := sqlerrm;
  end;
  return query select 'going live twice is refused',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- After it — nothing is looser than it was
  -- ---------------------------------------------------------------------

  v_cs := erp.configure_sales(15);

  return query select 'after go-live the installer stops at submitted',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'ready',
    'this is the control the product wants once there is a product to control';

  begin
    perform erp.approve_change_set(v_cs);
    v_ok := false; v_msg := 'the author approved their own change set';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_CHANGE_SET_SELF_APPROVAL%'; v_msg := sqlerrm;
  end;
  return query select 'and the author may not approve it',
    v_ok, v_msg;

  begin
    insert into erp.rule_set (tenant_id, code, name, status)
    values (v_tenant, 'zzboot-direct', 'Direct edit', 'active');
    v_ok := false; v_msg := 'a live tenant accepted a direct configuration edit';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_LIVE_CONFIG_EDIT%'; v_msg := sqlerrm;
  end;
  return query select 'the live-configuration guard is now on',
    v_ok, v_msg;

  -- The second administrator can, which is the point of having one.
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(v_cs);
  v_promo := erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'a second administrator can approve and promote',
    (select cs.status from erp.change_set cs where cs.id = v_cs) = 'promoted',
    'separation of duties has to be satisfiable or it is only an outage';

  return query select 'that promotion also names the environment',
    (select p.environment_id from erp.promotion p where p.id = v_promo) = v_env,
    'erp.promotion.environment_id is not null now, so this cannot regress '
    'quietly';

  -- ---------------------------------------------------------------------
  -- The refusals the new column and helper are for
  -- ---------------------------------------------------------------------

  begin
    perform erp.self_environment_id(gen_random_uuid());
    v_ok := false; v_msg := 'self_environment_id() returned for an unknown tenant';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_SELF_ENVIRONMENT%'; v_msg := sqlerrm;
  end;
  return query select 'a tenant with no self environment is refused, not defaulted',
    v_ok, v_msg;

  return query select 'the promotion environment cannot be null',
    (select a.attnotnull from pg_attribute a
      where a.attrelid = 'erp.promotion'::regclass and a.attname = 'environment_id'),
    'a promotion whose history cannot say where it happened is not a record';

  -- ---------------------------------------------------------------------
  -- The finding that would have caught the original defect
  -- ---------------------------------------------------------------------

  select count(*) into v_before from erp.dead_configuration_report()
   where finding = 'a tenant has no environment marked is_self';

  -- Cleared rather than deleted: erp.change_set.source_environment_id points at
  -- this row now, which is itself part of the fix.
  update erp.environment set is_self = false where id = v_env;

  return query select 'a tenant with no is_self environment is dead configuration',
    (select count(*) from erp.dead_configuration_report()
      where finding = 'a tenant has no environment marked is_self') = v_before + 1,
    'this is the finding that would have made the original hole a build '
    'failure rather than a live tenant nobody governed';

  -- Put it back: the assertions at the end of this migration run over every
  -- tenant, this one included.
  update erp.environment set is_self = true where id = v_env;

  -- ---------------------------------------------------------------------
  -- The operational surface
  -- ---------------------------------------------------------------------

  return query select 'every operational wrapper is on the write allow-list',
    not exists (
      select 1 from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname like 'erp\_%'
         and p.provolatile = 'v'
         and not exists (select 1 from erp_meta.public_write_allowance w
                          where w.function_name = p.proname)),
    'the allow-list is the review; a wrapper missing from it is a write '
    'nobody wrote a reason for';

  return query select 'the operational surface reaches the shop floor',
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('erp_receive_against', 'erp_record_count',
                          'erp_book_operation_time', 'erp_record_inspection_result',
                          'erp_close_period', 'erp_configure_tax')) = 6,
    'a product whose configuration screens work and whose operations do not '
    'is a configuration editor';

  perform set_config('request.jwt.claims', '', true);

  -- Every other suite ends here, and this one did not.
  --
  -- This tenant is live by now, which no other suite's is. The purge window is
  -- what makes that survivable: erp.guard_live_configuration() refuses a
  -- direct write to a live tenant's configuration and exempts exactly one
  -- caller — a trusted session that has opened a purge for this tenant.
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();

  -- The two subjects live outside the tenant and there is no foreign key from
  -- erp.app_user.auth_user_id to auth.users, so nothing cascaded to them. They
  -- have to go by name.
  delete from auth.users where id in (a1, a2);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant)
      and not exists (select 1 from auth.users u where u.id in (a1, a2)),
    'a suite that is only correct on an empty database is only correct on CI';
end;
$function$
;

CREATE OR REPLACE FUNCTION erp_test.document_authorisation_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION erp_test.master_data_doors_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$

declare
  r record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_uom uuid; v_item uuid; v_party uuid; v_batch uuid;
  v_second uuid; v_tok text; res jsonb;
  v_ok boolean; v_msg text; v_err integer; v_loaded integer; v_prev jsonb;
begin
  select * into r from erp.provision_tenant(
    'zzdoors', 'Doors Suite', 'admin@zzdoors.test', 'Doors Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- A principal with no role at all: a member of the tenant holding nothing.
  -- The cleanest negative control there is, because it needs no role authored
  -- to be restrictive.
  res := public.erp_invite_principal('nobody@zzdoors.test', 'No Permissions');
  v_second := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';

  -- ---------------------------------------------------------------------
  -- The refusal that used to be a constraint violation
  -- ---------------------------------------------------------------------

  begin
    perform erp.create_item('WIDGET', 'Widget');
    v_ok := false; v_msg := 'an item was created with no base unit';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_BASE_UOM%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an item before any unit is refused by name',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- The doors
  -- ---------------------------------------------------------------------

  v_uom := (public.erp_create_uom('ea', 'Each', 'quantity', 0, true) ->> 'uom_id')::uuid;

  return query select 'a unit of measure can be created at all',
    exists (select 1 from erp.uom u
             where u.id = v_uom and u.tenant_id = r.tenant_id
               and u.code = 'EA' and u.is_base and u.status = 'active'),
    'nothing in the product could create one before this migration';

  v_item := (public.erp_create_item('WIDGET', 'Widget') ->> 'item_id')::uuid;

  return query select 'an item resolves the tenant base unit',
    (select i.stock_uom_id from erp.item i where i.id = v_item) = v_uom,
    'the same resolution erp.load_import does, so both paths agree';

  return query select 'and is created active rather than draft',
    (select i.lifecycle from erp.item i where i.id = v_item) = 'active',
    'the import stages as draft because nobody has looked; a typed record has '
    'been looked at';

  begin
    perform erp.create_item('OTHER', 'Other', gen_random_uuid());
    v_ok := false; v_msg := 'an unknown unit was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_UOM%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a unit from another tenant is refused',
    v_ok, v_msg;

  v_party := (public.erp_create_party_with_roles('ACME', 'Acme Ltd',
                array['customer', 'supplier'], 'GB') ->> 'party_id')::uuid;

  return query select 'a party can be created at all',
    exists (select 1 from erp.party p
             where p.id = v_party and p.tenant_id = r.tenant_id
               and p.status = 'active'),
    'one party across every role, so a receivable can net against a payable';

  return query select 'and holds the roles it was created with',
    (select count(*) from erp.party_role pr
      where pr.party_id = v_party and pr.status = 'active') = 2,
    'a party with no role is a name nobody can trade with';

  begin
    perform erp.create_party('', 'No code');
    v_ok := false; v_msg := 'a party with no code was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PARTY_CODE_REQUIRED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a party with no code is refused',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- The pipeline, end to end, through the public surface only
  -- ---------------------------------------------------------------------

  v_batch := erp.stage_import('party',
    jsonb_build_array(jsonb_build_object('code', 'IMPORTED', 'name', 'Imported Co')),
    'zzdoors-batch');

  -- 20260830014600 renamed this key from 'error_count' to 'errors'. It still
  -- carries the integer erp.validate_import() returns, not a list.
  v_err  := (public.erp_validate_import(v_batch) ->> 'errors')::integer;
  v_prev := public.erp_preview_import(v_batch);
  v_loaded := erp.load_import(v_batch);

  return query select 'validate is reachable from the public surface',
    v_err = 0, format('%s errors', v_err);

  return query select 'preview is reachable, and returns the rows',
    jsonb_array_length(v_prev) = 1, format('%s rows previewed', jsonb_array_length(v_prev));

  return query select 'and load then accepts the batch',
    v_loaded = 1
      and exists (select 1 from erp.party p
                   where p.tenant_id = r.tenant_id and p.code = 'IMPORTED'),
    'load refuses anything not previewed, and only preview sets that status — '
    'so before this migration the pipeline could not complete';

  -- ---------------------------------------------------------------------
  -- The negative controls: the doors are gated
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);

  begin
    perform erp.create_party('SNEAK', 'Sneak Ltd');
    v_ok := false; v_msg := 'a principal with no permissions created a party';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a principal without master_data.write cannot create a party',
    v_ok, v_msg;

  begin
    perform erp.create_item('SNEAK', 'Sneak item');
    v_ok := false; v_msg := 'a principal with no permissions created an item';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor an item',
    v_ok, v_msg;

  begin
    perform erp.create_uom('SNEAK', 'Sneak unit');
    v_ok := false; v_msg := 'a principal with no permissions created a unit';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor a unit of measure',
    v_ok, v_msg;

  begin
    perform erp.validate_import(v_batch);
    v_ok := false; v_msg := 'validate ran for a principal holding nothing';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and validate_import now authorises, which it never did',
    v_ok, v_msg;

  begin
    perform erp.preview_import(v_batch);
    v_ok := false; v_msg := 'preview ran for a principal holding nothing';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'as does preview_import',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'every other suite purges; this one does too';
end;
$function$
;

CREATE OR REPLACE FUNCTION erp_test.reference_reads_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  ra record; rb record;
  a1 uuid := gen_random_uuid();
  b1 uuid := gen_random_uuid();
  v_owner text := current_user;
  v_uom_a uuid; v_uom_b uuid;
  v_json jsonb; v_n integer;
begin
  select * into ra from erp.provision_tenant(
    'zzreads-a', 'Reads A', 'a@zzreads.test', 'Reads A Admin');
  select * into rb from erp.provision_tenant(
    'zzreads-b', 'Reads B', 'b@zzreads.test', 'Reads B Admin');

  insert into auth.users (id, email) values (a1, 'a@zzreads.test');
  insert into auth.users (id, email) values (b1, 'b@zzreads.test');

  -- Claim both invitations rather than patching auth_user_id onto the row: a
  -- provisioned administrator is 'invited' until they claim, and
  -- erp.principal_context() resolves only an active principal. Setting the
  -- column alone leaves the subject resolving to nothing, which surfaces much
  -- later as ERPWARE_NO_TENANT_CONTEXT from require_tenant_id().
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(ra.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', b1)::text, true);
  perform erp.claim_invitation(rb.admin_token);
  perform set_config('request.jwt.claims', '', true);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (ra.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom_a;
  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (rb.tenant_id, 'BOX', 'Box', 'quantity', 0, true, 'active') returning id into v_uom_b;

  insert into erp.party (tenant_id, code, name, status)
  values (ra.tenant_id, 'CUST-A', 'Customer A', 'active');
  insert into erp.party (tenant_id, code, name, status)
  values (rb.tenant_id, 'CUST-B', 'Customer B', 'active');

  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  select ra.tenant_id, p.id, 'customer', 'active' from erp.party p
   where p.tenant_id = ra.tenant_id and p.code = 'CUST-A';

  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (ra.tenant_id, 'ITEM-A', 'Item A', v_uom_a, 'active');
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (rb.tenant_id, 'ITEM-B', 'Item B', v_uom_b, 'active');

  -- Every isolation case below asserts tenant B's rows are ABSENT, which would
  -- pass just as well if the fixture had never written them. So assert they
  -- exist first, as the owner, while both are still visible.
  select count(*) into v_n
    from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'CUST-B';
  return query select 'the other tenant''s fixtures really exist',
    v_n = 1
      and exists (select 1 from erp.item i
                   where i.tenant_id = rb.tenant_id and i.code = 'ITEM-B')
      and exists (select 1 from erp.uom u
                   where u.tenant_id = rb.tenant_id and u.code = 'BOX'),
    'without this the isolation cases below could pass by writing nothing';

  -- ---------------------------------------------------------------------
  -- Become tenant A for real, so RLS is actually in force.
  -- ---------------------------------------------------------------------
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', a1, 'role', 'authenticated')::text);
  set local role authenticated;

  v_json := public.erp_parties();
  return query select 'erp_parties returns this tenant and not the other',
    v_json @> '[{"code":"CUST-A"}]'::jsonb and not (v_json @> '[{"code":"CUST-B"}]'::jsonb),
    format('%s parties', jsonb_array_length(v_json));

  return query select 'and filters by role server-side',
    jsonb_array_length(public.erp_parties('customer')) = 1
      and jsonb_array_length(public.erp_parties('carrier')) = 0,
    'a picker truncated by p_limit cannot be filtered afterwards';

  v_json := public.erp_items();
  return query select 'erp_items returns this tenant and not the other',
    v_json @> '[{"code":"ITEM-A"}]'::jsonb and not (v_json @> '[{"code":"ITEM-B"}]'::jsonb),
    format('%s items', jsonb_array_length(v_json));

  return query select 'and resolves the stock unit code, not just its id',
    public.erp_items() @> '[{"stock_uom_code":"EA"}]'::jsonb,
    'a picker showing a uuid is not a picker';

  v_json := public.erp_uoms();
  return query select 'erp_uoms returns this tenant and not the other',
    v_json @> '[{"code":"EA"}]'::jsonb and not (v_json @> '[{"code":"BOX"}]'::jsonb),
    format('%s units', jsonb_array_length(v_json));

  return query select 'erp_locations is scoped to the tenant',
    public.erp_locations() = '[]'::jsonb,
    'tenant A has no locations; tenant B''s must not leak in';

  v_json := public.erp_currencies();
  return query select 'erp_currencies is product content, shared on purpose',
    jsonb_array_length(v_json) > 0 and v_json @> '[{"code":"GBP"}]'::jsonb,
    'identical for every tenant, and deliberately not scoped';

  return query select 'and carries minor_units, which is the point of it',
    v_json @> '[{"code":"JPY","minor_units":0}]'::jsonb
      and v_json @> '[{"code":"GBP","minor_units":2}]'::jsonb,
    'the app divides by 100 unconditionally, which is wrong for JPY by a '
    'factor of a hundred';

  v_json := public.erp_tenant_state();
  return query select 'erp_tenant_state reports the bootstrap window',
    (v_json ->> 'is_live') is not null
      and (v_json -> 'environment' ->> 'environment_id') is not null,
    format('is_live=%s', v_json ->> 'is_live');

  return query select 'and counts the administrators go-live requires',
    (v_json ->> 'administrators')::integer >= 1,
    'erp.go_live() refuses below two, so a screen can say why beforehand';

  return query select 'erp_document_types carries the permission to raise one',
    not exists (
      select 1 from jsonb_array_elements(public.erp_document_types()) e
       where e ->> 'create_permission' is null),
    'so a screen can offer an action only where the caller holds what the '
    'database will check';

  -- ---------------------------------------------------------------------
  -- Back to the owner to clean up.
  -- ---------------------------------------------------------------------
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  perform erp.begin_tenant_purge(ra.tenant_id);
  delete from erp.tenant where id = ra.tenant_id;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(rb.tenant_id);
  delete from erp.tenant where id = rb.tenant_id;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, b1);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t
                 where t.id in (ra.tenant_id, rb.tenant_id)),
    'both tenants and both fabricated subjects';
end;
$function$
;

CREATE OR REPLACE FUNCTION erp_test.transition_menu_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  ob jsonb; v_tenant uuid; v_entity uuid; v_site uuid;
  v_uom uuid; v_item uuid; v_party uuid; v_doc uuid;
  res jsonb; v_clerk uuid; v_tok text;
  v_admin jsonb; v_theirs jsonb; v_ctx jsonb;
begin
  insert into auth.users (id, email) values (a1, 'admin@zztmenu.test');
  insert into auth.users (id, email) values (a2, 'clerk@zztmenu.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  ob := erp.onboard_tenant('Transition Menu', 'zztmenu');
  v_tenant := (ob ->> 'tenant_id')::uuid;
  v_entity := (ob ->> 'entity_id')::uuid;

  perform erp.configure_finance();
  perform erp.configure_inventory();
  perform erp.configure_sales();

  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (v_tenant, v_entity, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;

  v_uom   := erp.create_uom('EA', 'Each', 'quantity'::erp.uom_class, 0::smallint, true);
  v_item  := erp.create_item('WIDGET', 'Widget');
  v_party := erp.create_party('CUST', 'Customer',
               array['customer']::erp.party_role_kind[]);

  -- Holds sales.order, not sales.despatch.
  res := public.erp_save_role(null, 'order_taker', 'Order taker',
    'Raises orders. Does not despatch them.',
    array['sales.read', 'sales.order']);
  res := public.erp_invite_principal('clerk@zztmenu.test', 'Order Taker');
  v_clerk := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';
  perform erp.grant_role(v_clerk, 'order_taker', null, null, 'no despatch');

  v_doc := erp.open_document('delivery', v_party, v_entity, v_site);
  perform erp.add_document_line(v_doc, v_item, 3, 1000);

  -- ---------------------------------------------------------------------
  -- What the menu now carries at all
  -- ---------------------------------------------------------------------

  v_admin := public.erp_available_transitions(v_doc);

  return query select 'the menu reports whether the caller may act',
    jsonb_array_length(v_admin) > 0
      and not exists (select 1 from jsonb_array_elements(v_admin) e
                       where e ->> 'permitted' is null
                          or e ->> 'guard_passes' is null),
    'the raw join it replaces returned neither field';

  return query select 'and erp_document carries the same answer',
    (public.erp_document(v_doc) -> 'available_transitions') = v_admin,
    'one definition, so a detail screen and a list cannot disagree';

  return query select 'an administrator may post this delivery',
    v_admin @> '[{"code":"post","permitted":true}]'::jsonb,
    'holds sales.despatch, which the delivery machine requires';

  -- ---------------------------------------------------------------------
  -- The contrast, which is the whole point
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);

  v_theirs := public.erp_available_transitions(v_doc);

  return query select 'an order taker is offered the same transitions',
    jsonb_array_length(v_theirs) = jsonb_array_length(v_admin),
    'the state machine does not change per principal; the answer about it does';

  return query select 'but may not post, and the menu says so',
    v_theirs @> '[{"code":"post","permitted":false}]'::jsonb,
    'before this, a screen would have offered it and the database refused';

  return query select 'and the database agrees when asked directly',
    (select not a.permitted from erp.available_transitions('document', v_doc,
       erp.document_transition_context(v_doc)) a where a.transition_code = 'post'),
    'the menu is a report of the rule, not a second copy of it';

  -- ---------------------------------------------------------------------
  -- The context both sides share
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v_ctx := erp.document_transition_context(v_doc, 'post');

  return query select 'the shared context carries the document''s real value',
    (v_ctx ->> 'total_minor')::bigint = erp.document_value_minor(v_doc)
      and (v_ctx ->> 'total_minor')::bigint > 0,
    format('total_minor=%s', v_ctx ->> 'total_minor');

  return query select 'and the fields a value band would be judged on',
    v_ctx ? 'max_discount_pct' and v_ctx ? 'credit_limit_minor'
      and v_ctx ? 'exposure_after_minor',
    'no transition in the product carries a guard yet, so this changes no '
    'answer today — it means the first one authored is judged on the real '
    'numbers from both sides rather than only from transition_document';

  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant),
    'tenant and both fabricated subjects';
end;
$function$
;


-- The one routine in this repository that must not carry a SET clause.
-- PostgreSQL refuses transaction control inside a routine that has one, and
-- this procedure exists to prove tenant context does not survive a COMMIT on a
-- pooled connection — which it can only do by committing. A linter fix added
-- the clause and silently disabled the check; erp.assert_transaction_control_
-- routines() at the tail is what now stops that happening again.

alter procedure erp_test.assert_context_not_leaked() reset search_path;

-- ── 12. Run the generators ──────────────────────────────────────────────────
--
-- The largest single correction, and the one that has nothing to do with this
-- session's migrations. Twenty-one tables are registered in
-- erp_meta.table_policy and never had their triggers emitted, because nothing
-- re-ran the generators after they were created: 18 audit, 8 tenant-freeze,
-- 6 attribution and 2 append-only guards, 34 in all.
--
-- Until this runs, changes to those tables do not reach the audit stream, a row
-- can be moved to another tenant by UPDATE, and approval_routing_stamp and
-- item_code_assignment can be edited or deleted despite being append-only.

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

-- ── 13. Prove it, in the transaction that did it ───────────────────────────

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_session_context_hygiene();
select erp.assert_gateway_integrity();
select erp.assert_scheduler_integrity();
select erp.assert_governed_views_are_safe();
select erp.assert_intelligence_boundary();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_master_data_sane();
select erp.assert_inventory_sane();
select erp.assert_procurement_controls_sane();
select erp.assert_planning_sane();
select erp.assert_production_sane();
select erp.assert_sales_controls_sane();
select erp.assert_quality_logistics_sane();
select erp.assert_finance_depth_sane();
select erp.assert_part5_coverage();
select erp.assert_transaction_control_routines();
select erp.assert_document_create_permissions();
select erp.assert_resource_coverage('en');
