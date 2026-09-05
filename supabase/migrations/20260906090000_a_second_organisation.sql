-- A second organisation.
--
-- D23 says the foundation is finished when a second organisation can be
-- onboarded, configured and operated by someone who has never seen the first.
-- Every suite before this one drove the product from inside: erp.* functions
-- called with the schema in view. That proves the functions; it does not prove
-- the surface. This file is the acceptance harness the decision asks for:
-- Nordwind, an organisation shaped nothing like the demonstration — three
-- companies in three countries under three legislation packs, standard costing,
-- pallet-level identity, FIFO allocation, a third-party warehouse operated by a
-- provider, consignment inbound, a word of its own — onboarded and operated
-- through public doors alone. The harness's wrapper reads the harness's own
-- source and refuses the build if a single erp.* function is called.
--
-- Writing it found what the surface lacked. A second organisation could not,
-- through any door: open a document in its second company (the door took no
-- company), receive consigned stock (no door named a stock owner), name the
-- provider that operates a site, mark an item as carrying an expiry or as
-- quarantined on receipt, create a batch at all, put a receipt line into a
-- location or a handling unit, set a standard cost (the first receipt silently
-- became the standard), build a handling unit, or submit a change set (approve
-- and promote had doors; submit did not, so the onboarding interview's own
-- proposal could never be promoted from a screen). Each is added here, small,
-- gated on the permission its module already declares, and registered on the
-- write allow-list. None widens what an erp.* function could already do; each
-- gives the door the argument the function already took.
--
-- What the harness could not do, and records rather than works around: the
-- first company is called MAIN because onboarding names it and no door renames
-- a company; the interview asks for an identity level and an allocation method
-- for the whole organisation, not per product class or site, so Nordwind's
-- pallet identity and FIFO apply to everything; two receipts on one day are a
-- FIFO tie that the nearest pickable location resolves; an inspection is raised
-- by nothing in the product (only a suite calls erp.raise_inspection), so the
-- quarantine gate is the item flag and the qualified release, with no
-- inspection between them. These are deferred findings 25–28.
--
-- Isolation is proven through every entry point, not asserted from the policy
-- catalogue: erp_test.door_isolation_suite() builds two organisations through
-- the same doors, walks every zero-argument read door as each of them and
-- refuses if any identifier of the other appears, then presents the other's
-- documents to the write doors and refuses if one is accepted.
--
-- D23 is registered and bound to both suites. The register's completeness
-- clause still runs D1–D18; Phase 5 widens it when D19–D33 arrive.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The doors the second organisation needed
-- ═════════════════════════════════════════════════════════════════════════════

-- 1a. A document in a named company, in a currency, with a stock owner.
create or replace function erp.set_document_stock_owner(p_document_id uuid, p_party_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;
  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;
  perform erp.authorise(coalesce(dt.create_permission, bt.create_permission),
                        d.entity_id, d.site_id, null, 'document', p_document_id);

  if exists (select 1 from erp.object_state os join erp.state s on s.id = os.current_state_id
              where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_document_id
                and s.is_committed) then
    raise exception 'CLOVEERP_DOCUMENT_COMMITTED: % has committed and its stock owner is what it was', d.document_number
      using errcode = '23514', hint = 'Name the stock owner while the document is a draft.';
  end if;
  if not exists (select 1 from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id and p.status = 'active') then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: %', p_party_id
      using errcode = '23503', hint = 'The stock owner is a party of this organisation: a supplier consigning stock, or a company of the organisation.';
  end if;

  update erp.document set stock_owner_party_id = p_party_id, updated_at = now()
   where id = p_document_id;
end;
$$;
revoke all on function erp.set_document_stock_owner(uuid, uuid) from public, anon, authenticated;

drop function if exists public.erp_create_document(text, uuid, uuid, text, date);
create function public.erp_create_document(
  p_type_code text, p_party_id uuid default null, p_site_id uuid default null,
  p_their_ref text default null, p_required_date date default null,
  p_entity_id uuid default null, p_currency text default null, p_stock_owner_party_id uuid default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := erp.open_document(p_type_code, p_party_id, p_entity_id, p_site_id, p_their_ref, p_required_date,
                            case when p_currency is null then null else upper(p_currency)::character(3) end);
  if p_stock_owner_party_id is not null then
    perform erp.set_document_stock_owner(v_id, p_stock_owner_party_id);
  end if;
  return jsonb_build_object('document_id', v_id);
end;
$$;
revoke all on function public.erp_create_document(text, uuid, uuid, text, date, uuid, text, uuid) from public, anon;
grant execute on function public.erp_create_document(text, uuid, uuid, text, date, uuid, text, uuid) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_create_document', 'erp.open_document',
   'Opens a document of a type, optionally in a named company, currency and with a stock owner; erp.open_document authorises the type''s create permission and the stock owner setter re-authorises it.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 1b. A third-party site names its operator.
create or replace function erp.set_site_operator(p_site_id uuid, p_party_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        erp.site%rowtype;
begin
  perform erp.authorise('administration.configure', null, p_site_id, null, 'site', p_site_id);
  select * into s from erp.site where tenant_id = v_tenant and id = p_site_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503';
  end if;
  if s.site_type <> 'third_party' then
    raise exception 'CLOVEERP_SITE_NOT_THIRD_PARTY: % is a % site and is operated by the company itself', s.code, s.site_type
      using errcode = '23514', hint = 'Only a third_party site has an operator; stock held there is in the operator''s custody.';
  end if;
  if not exists (select 1 from erp.party p where p.tenant_id = v_tenant and p.id = p_party_id and p.status = 'active') then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: %', p_party_id using errcode = '23503';
  end if;
  update erp.site set operator_party_id = p_party_id, updated_at = now() where id = p_site_id;
end;
$$;
revoke all on function erp.set_site_operator(uuid, uuid) from public, anon, authenticated;

drop function if exists public.erp_create_site(text, text, text, uuid, text, text);
create function public.erp_create_site(
  p_code text, p_name text default null, p_site_type text default 'warehouse', p_entity_id uuid default null,
  p_country_code text default null, p_timezone text default null, p_operator_party_id uuid default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_id uuid;
begin
  v_id := erp.create_site(p_code, p_name, p_site_type, p_entity_id, p_country_code::character(2), p_timezone);
  if p_operator_party_id is not null then
    perform erp.set_site_operator(v_id, p_operator_party_id);
  end if;
  return jsonb_build_object('site_id', v_id);
end;
$$;
revoke all on function public.erp_create_site(text, text, text, uuid, text, text, uuid) from public, anon;
grant execute on function public.erp_create_site(text, text, text, uuid, text, text, uuid) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_create_site', 'erp.create_site',
   'Creates a site of a company, optionally naming the provider that operates it; gated on administration.configure in both functions.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 1c. An item's stock controls.
create or replace function erp.set_item_controls(
  p_item_id uuid,
  p_is_batch_controlled boolean default null,
  p_has_expiry boolean default null,
  p_shelf_life_days integer default null,
  p_min_remaining_shelf_life_days integer default null,
  p_quarantine_on_receipt boolean default null,
  p_is_serial_controlled boolean default null)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  i        erp.item%rowtype;
  v_batch  boolean;
  v_serial boolean;
begin
  perform erp.authorise('master_data.write', null, null, null, 'item', p_item_id);
  select * into i from erp.item where tenant_id = v_tenant and id = p_item_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_ITEM: %', p_item_id using errcode = '23503';
  end if;
  v_batch  := coalesce(p_is_batch_controlled, i.is_batch_controlled);
  v_serial := coalesce(p_is_serial_controlled, i.is_serial_controlled);
  if (v_batch <> i.is_batch_controlled or v_serial <> i.is_serial_controlled)
     and exists (select 1 from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = p_item_id and b.quantity <> 0) then
    raise exception 'CLOVEERP_ITEM_HAS_STOCK: % holds stock, so how it is identified cannot change', i.code
      using errcode = '23514', hint = 'Issue or write off the stock first; existing positions were recorded under the current identity.';
  end if;
  if coalesce(p_has_expiry, i.has_expiry) and not v_batch then
    raise exception 'CLOVEERP_EXPIRY_NEEDS_BATCH: % cannot carry an expiry without batch control', i.code
      using errcode = '23514', hint = 'An expiry date belongs to a batch; switch on batch control with it.';
  end if;
  update erp.item
     set is_batch_controlled = v_batch,
         is_serial_controlled = v_serial,
         has_expiry = coalesce(p_has_expiry, has_expiry),
         shelf_life_days = coalesce(p_shelf_life_days, shelf_life_days),
         min_remaining_shelf_life_days = coalesce(p_min_remaining_shelf_life_days, min_remaining_shelf_life_days),
         quarantine_on_receipt = coalesce(p_quarantine_on_receipt, quarantine_on_receipt),
         updated_at = now()
   where id = p_item_id;
end;
$$;
revoke all on function erp.set_item_controls(uuid, boolean, boolean, integer, integer, boolean, boolean) from public, anon, authenticated;

drop function if exists public.erp_set_item_controls(uuid, boolean, boolean, integer, integer, boolean, boolean);
create function public.erp_set_item_controls(
  p_item_id uuid, p_is_batch_controlled boolean default null, p_has_expiry boolean default null,
  p_shelf_life_days integer default null, p_min_remaining_shelf_life_days integer default null,
  p_quarantine_on_receipt boolean default null, p_is_serial_controlled boolean default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform erp.set_item_controls(p_item_id, p_is_batch_controlled, p_has_expiry, p_shelf_life_days,
                                p_min_remaining_shelf_life_days, p_quarantine_on_receipt, p_is_serial_controlled);
  return jsonb_build_object('item_id', p_item_id);
end;
$$;
revoke all on function public.erp_set_item_controls(uuid, boolean, boolean, integer, integer, boolean, boolean) from public, anon;
grant execute on function public.erp_set_item_controls(uuid, boolean, boolean, integer, integer, boolean, boolean) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_item_controls', 'erp.set_item_controls',
   'Sets how an item''s stock is identified and handled (batch, serial, expiry, shelf life, quarantine on receipt); gated on master_data.write.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 1d. A batch.
create or replace function erp.create_batch(
  p_item_id uuid, p_batch_number text, p_expires_on date default null,
  p_manufactured_on date default null, p_supplier_party_id uuid default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  i        erp.item%rowtype;
  v_id     uuid;
begin
  perform erp.authorise('inventory.move', null, null, null, 'batch', null);
  select * into i from erp.item where tenant_id = v_tenant and id = p_item_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_ITEM: %', p_item_id using errcode = '23503';
  end if;
  if not i.is_batch_controlled then
    raise exception 'CLOVEERP_ITEM_NOT_BATCH_CONTROLLED: % is not batch controlled', i.code
      using errcode = '23514', hint = 'Switch on batch control for the item (erp_set_item_controls) before creating a batch of it.';
  end if;
  if coalesce(btrim(p_batch_number), '') = '' then
    raise exception 'CLOVEERP_BATCH_NUMBER_REQUIRED: a batch needs a number' using errcode = '23514';
  end if;
  if i.has_expiry and p_expires_on is null then
    raise exception 'CLOVEERP_BATCH_NEEDS_EXPIRY: % carries an expiry and batch % names none', i.code, p_batch_number
      using errcode = '23514', hint = 'Give the batch its expiry date; FEFO allocation and the expiry horizon read it.';
  end if;
  if exists (select 1 from erp.batch b where b.tenant_id = v_tenant and b.item_id = p_item_id and b.batch_number = btrim(p_batch_number)) then
    raise exception 'CLOVEERP_BATCH_EXISTS: % already has a batch %', i.code, p_batch_number
      using errcode = '23505', hint = 'Receive against the existing batch, or number the new one differently.';
  end if;
  if p_supplier_party_id is not null
     and not exists (select 1 from erp.party p where p.tenant_id = v_tenant and p.id = p_supplier_party_id) then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: %', p_supplier_party_id using errcode = '23503';
  end if;

  insert into erp.batch (tenant_id, item_id, batch_number, status, expires_on, manufactured_on, supplier_party_id)
  values (v_tenant, p_item_id, btrim(p_batch_number),
          case when i.quarantine_on_receipt then 'quarantine'::erp.batch_status else 'unrestricted'::erp.batch_status end,
          p_expires_on, p_manufactured_on, p_supplier_party_id)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function erp.create_batch(uuid, text, date, date, uuid) from public, anon, authenticated;

drop function if exists public.erp_create_batch(uuid, text, date, date, uuid);
create function public.erp_create_batch(
  p_item_id uuid, p_batch_number text, p_expires_on date default null,
  p_manufactured_on date default null, p_supplier_party_id uuid default null)
returns uuid
language sql
volatile
set search_path = ''
as $$
  select erp.create_batch(p_item_id, p_batch_number, p_expires_on, p_manufactured_on, p_supplier_party_id)
$$;
revoke all on function public.erp_create_batch(uuid, text, date, date, uuid) from public, anon;
grant execute on function public.erp_create_batch(uuid, text, date, date, uuid) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_create_batch', 'erp.create_batch',
   'Creates a batch of a batch-controlled item with its expiry and origin; gated on inventory.move.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 1e. Where a line's stock is and what identifies it.
create or replace function erp.set_line_stock_identity(
  p_line_id uuid, p_batch_id uuid default null, p_location_id uuid default null, p_container_id uuid default null)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
begin
  select * into l from erp.document_line where tenant_id = v_tenant and id = p_line_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_LINE: %', p_line_id using errcode = '23503';
  end if;
  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;
  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;
  perform erp.authorise(coalesce(dt.create_permission, bt.create_permission),
                        d.entity_id, d.site_id, null, 'document', d.id);

  if exists (select 1 from erp.object_state os join erp.state s on s.id = os.current_state_id
              where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = d.id and s.is_committed) then
    raise exception 'CLOVEERP_DOCUMENT_COMMITTED: % has committed; its lines say where the stock went', d.document_number
      using errcode = '23514';
  end if;
  if p_batch_id is not null and not exists (
       select 1 from erp.batch b where b.tenant_id = v_tenant and b.id = p_batch_id and b.item_id = l.item_id) then
    raise exception 'CLOVEERP_BATCH_ITEM_MISMATCH: the batch is not a batch of the line''s item'
      using errcode = '23514', hint = 'Create a batch of this item (erp_create_batch) and name that.';
  end if;
  if p_location_id is not null and not exists (
       select 1 from erp.location loc where loc.tenant_id = v_tenant and loc.id = p_location_id and loc.site_id = d.site_id) then
    raise exception 'CLOVEERP_LOCATION_NOT_AT_SITE: the location is not at the document''s site'
      using errcode = '23514';
  end if;
  if p_container_id is not null and not exists (
       select 1 from erp.container c where c.tenant_id = v_tenant and c.id = p_container_id and c.site_id = d.site_id) then
    raise exception 'CLOVEERP_CONTAINER_NOT_AT_SITE: the handling unit is not at the document''s site'
      using errcode = '23514', hint = 'Build the unit at this site (erp_create_handling_unit) or name one that stands here.';
  end if;

  update erp.document_line
     set batch_id     = coalesce(p_batch_id, batch_id),
         location_id  = coalesce(p_location_id, location_id),
         container_id = coalesce(p_container_id, container_id),
         updated_at   = now()
   where id = p_line_id;
end;
$$;
revoke all on function erp.set_line_stock_identity(uuid, uuid, uuid, uuid) from public, anon, authenticated;

drop function if exists public.erp_set_line_stock_identity(uuid, uuid, uuid, uuid);
create function public.erp_set_line_stock_identity(
  p_line_id uuid, p_batch_id uuid default null, p_location_id uuid default null, p_container_id uuid default null)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform erp.set_line_stock_identity(p_line_id, p_batch_id, p_location_id, p_container_id);
  return jsonb_build_object('line_id', p_line_id);
end;
$$;
revoke all on function public.erp_set_line_stock_identity(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.erp_set_line_stock_identity(uuid, uuid, uuid, uuid) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_line_stock_identity', 'erp.set_line_stock_identity',
   'Names the batch, location and handling unit a draft document line''s stock is in; gated on the document type''s create permission.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 1f. A standard cost is set, not inherited from the first receipt.
create or replace function erp.set_standard_cost(
  p_item_id uuid, p_site_id uuid, p_unit_cost_minor bigint, p_currency character default null)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_method erp.costing_method;
  v_ccy    character(3);
  ic       erp.item_cost%rowtype;
  v_id     uuid;
begin
  perform erp.authorise('finance.configure', null, p_site_id, null, 'item_cost', null);
  if not exists (select 1 from erp.item i where i.tenant_id = v_tenant and i.id = p_item_id) then
    raise exception 'CLOVEERP_UNKNOWN_ITEM: %', p_item_id using errcode = '23503';
  end if;
  if p_site_id is not null and not exists (select 1 from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id) then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503';
  end if;
  v_method := erp.costing_method_for(p_item_id, p_site_id);
  if v_method <> 'standard' then
    raise exception 'CLOVEERP_NOT_STANDARD_COSTED: this item is costed by % here, so it has no standard to set', v_method
      using errcode = '23514', hint = 'Promote a costing policy with method standard for the item''s class or site, then set the standard.';
  end if;
  if coalesce(p_unit_cost_minor, 0) <= 0 then
    raise exception 'CLOVEERP_COST_NONPOSITIVE: a standard cost is a positive figure in minor units' using errcode = '23514';
  end if;
  v_ccy := coalesce(p_currency,
                    (select e.base_currency from erp.site s join erp.entity e on e.id = s.entity_id where s.id = p_site_id),
                    (select e.base_currency from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1));

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id and c.site_id is not distinct from p_site_id
     for update;
  if found then
    if ic.quantity_on_hand <> 0 then
      raise exception 'CLOVEERP_STANDARD_REVALUATION_NOT_BUILT: % unit(s) are on hand at the current standard; changing it would revalue stock without a journal', ic.quantity_on_hand
        using errcode = '23514', hint = 'Issue or write off the stock first. Revaluing held stock at a new standard, with the difference posted, is later work.';
    end if;
    update erp.item_cost
       set method = 'standard', unit_cost_minor = p_unit_cost_minor, currency = v_ccy, value_minor = 0, updated_at = now()
     where id = ic.id
     returning id into v_id;
  else
    insert into erp.item_cost (tenant_id, item_id, site_id, method, unit_cost_minor, currency, quantity_on_hand, value_minor)
    values (v_tenant, p_item_id, p_site_id, 'standard', p_unit_cost_minor, v_ccy, 0, 0)
    returning id into v_id;
  end if;
  return v_id;
end;
$$;
revoke all on function erp.set_standard_cost(uuid, uuid, bigint, character) from public, anon, authenticated;

drop function if exists public.erp_set_standard_cost(uuid, uuid, bigint, text);
create function public.erp_set_standard_cost(p_item_id uuid, p_site_id uuid, p_unit_cost_minor bigint, p_currency text default null)
returns uuid
language sql
volatile
set search_path = ''
as $$
  select erp.set_standard_cost(p_item_id, p_site_id, p_unit_cost_minor,
                               case when p_currency is null then null else upper(p_currency)::character(3) end)
$$;
revoke all on function public.erp_set_standard_cost(uuid, uuid, bigint, text) from public, anon;
grant execute on function public.erp_set_standard_cost(uuid, uuid, bigint, text) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_standard_cost', 'erp.set_standard_cost',
   'Sets the standard cost of a standard-costed item at a site while nothing is on hand; gated on finance.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 1g. A handling unit, from a screen as well as a scanner.
drop function if exists public.erp_create_handling_unit(uuid, uuid, text, uuid, text, uuid);
create function public.erp_create_handling_unit(
  p_site_id uuid, p_location_id uuid, p_container_type text,
  p_parent_container_id uuid default null, p_code text default null, p_item_id uuid default null)
returns uuid
language sql
volatile
set search_path = ''
as $$
  select erp.create_handling_unit(p_site_id, p_location_id, p_container_type, p_parent_container_id, p_code, p_item_id)
$$;
revoke all on function public.erp_create_handling_unit(uuid, uuid, text, uuid, text, uuid) from public, anon;
grant execute on function public.erp_create_handling_unit(uuid, uuid, text, uuid, text, uuid) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_create_handling_unit', 'erp.create_handling_unit',
   'Builds a handling unit at a site and location under the identity policy in force; gated on inventory.move inside erp.create_handling_unit.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 1h. A change set is submitted from a screen, as it is approved and promoted.
drop function if exists public.erp_submit_change_set(uuid);
create function public.erp_submit_change_set(p_change_set_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform erp.submit_change_set(p_change_set_id);
  return jsonb_build_object('change_set_id', p_change_set_id,
                            'status', (select cs.status::text from erp.change_set cs where cs.id = p_change_set_id));
end;
$$;
revoke all on function public.erp_submit_change_set(uuid) from public, anon;
grant execute on function public.erp_submit_change_set(uuid) to authenticated, service_role;
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_submit_change_set', 'erp.submit_change_set',
   'Submits a change set for approval, raising its approval request; gated on administration.configure inside erp.submit_change_set. Approve and promote had doors; submit did not.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- 1i. What the isolation walk found. Every door filters on the organisation
-- explicitly as well as under row security, so a door reached by a role that
-- bypasses row security still shows one organisation. erp_sites did not: it
-- read erp.site with no tenant clause and relied on the policy alone. The walk
-- below runs as the migration role, which row security does not bind, and it
-- showed the other organisation's sites. Filtered like its 111 siblings.
create or replace function public.erp_sites()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'site_id', s.id, 'code', s.code, 'name', s.name,
           'site_type', s.site_type, 'entity_id', s.entity_id,
           'entity_code', (select e.code from erp.entity e
                            where e.tenant_id = s.tenant_id and e.id = s.entity_id),
           'country_code', s.country_code, 'status', s.status)
           order by s.code), '[]'::jsonb)
    from erp.site s
   where s.tenant_id = erp.current_tenant_id()
$$;

-- 1j. The words on the terminology screen's two new panels (Phase 4c's file C
-- added the panels; the build refused the branch because five of their words
-- had no row a tenant could rename them by). Seeded in English and German.
insert into erp_ref.resource (key, locale, value)
select erp_ref.ui_key(v.en), 'en', v.en
  from (values ('Add a term'), ('Add term'), ('Apply translation'), ('Key (custom.…)'),
               ('Lower-case words, digits and underscores, separated by dots.')) v(en)
on conflict (key, locale) do nothing;
insert into erp_ref.resource (key, locale, value)
select erp_ref.ui_key(v.en), 'de', v.de
  from (values ('Add a term', 'Begriff hinzufügen'), ('Add term', 'Begriff hinzufügen'),
               ('Apply translation', 'Übersetzung anwenden'), ('Key (custom.…)', 'Schlüssel (custom.…)'),
               ('Lower-case words, digits and underscores, separated by dots.', 'Kleinbuchstaben, Ziffern und Unterstriche, durch Punkte getrennt.')) v(en, de)
on conflict (key, locale) do update set value = excluded.value;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The decision, registered
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, supersedes, spec_reference) values
  ('D23', 23, 'The foundation is finished when a second organisation can be onboarded by someone who has never seen the first',
   'A second organisation, shaped nothing like the first — its own companies, countries, legislation, costing, identity level, allocation method, sites and words — is onboarded, configured and operated through the public surface alone, and every entry point keeps the two apart.',
   'This is the acceptance test for the whole foundation, not a slogan: every other measure of completeness can be satisfied by a system shaped around one customer.',
   'A harness that must be kept honest. Every door the second organisation needs has to exist, and one it lacks fails the build; the harness''s own source is read to prove it called nothing but doors.',
   null, 'v1.2 Part 23 D23')
on conflict (code) do update
  set title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
      cost = excluded.cost, spec_reference = excluded.spec_reference;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Nordwind, through the doors
-- ═════════════════════════════════════════════════════════════════════════════

-- The fixture every case stands on. Every statement here is a public door, a
-- session setting, or a read of a table for an identifier the door returned by
-- code; the wrapper below refuses the build if an erp.* function is called.
create or replace function erp_test.nordwind_fixture(p_code text, p_auth_id uuid, p_email text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  res       jsonb;
  v_tenant  uuid; v_admin uuid;
  v_gb uuid; v_ie uuid; v_de uuid;
  v_s uuid; v_cs uuid;
  v_wh uuid; v_ie_wh uuid; v_3pl uuid;
  v_recv uuid; v_bulk_a uuid; v_bulk_b uuid; v_quar uuid; v_ie_bulk uuid;
  v_logi uuid; v_sup uuid; v_cons uuid; v_cust_gb uuid; v_cust_us uuid;
  v_ph uuid; v_hw uuid; v_fg uuid;
  v_buyer uuid; v_dept uuid;
begin
  insert into auth.users (id, email) values (p_auth_id, p_email);
  perform set_config('request.jwt.claims', json_build_object('sub', p_auth_id)::text, true);

  -- 1. Onboarded from the sign-up door.
  res := public.erp_onboard_tenant('Nordwind', p_code);
  v_tenant := (res ->> 'tenant_id')::uuid;
  v_admin  := (res ->> 'principal_id')::uuid;
  v_gb     := (res ->> 'entity_id')::uuid;

  -- 2. The organisation's shape, from the interview, promoted from the screen.
  v_s := (public.erp_start_interview(p_code || '-shape') ->> 'session_id')::uuid;
  perform public.erp_answer_interview(v_s, 'org.multi_company', 'true'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.companies',
    '[{"left":"NW-IE","right":"Nordwind Ireland"},{"left":"NW-DE","right":"Nordwind Deutschland"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.currencies',
    '[{"left":"NW-IE","right":"EUR"},{"left":"NW-DE","right":"EUR"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.countries',
    '[{"left":"NW-IE","right":"IE"},{"left":"NW-DE","right":"DE"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.locales',
    '[{"left":"NW-IE","right":"en-IE"},{"left":"NW-DE","right":"de"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.legislation',
    '[{"left":"MAIN","right":"gb_vat"},{"left":"NW-IE","right":"ie_vat"},{"left":"NW-DE","right":"de_ust"}]'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.costing_method', '"standard"'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.identity_level', '"pallet"'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.allocation_method', '"fifo"'::jsonb);
  perform public.erp_answer_interview(v_s, 'org.consignment', 'true'::jsonb);
  res := public.erp_propose_from_interview(v_s);
  select (x ->> 'change_set_id')::uuid into v_cs
    from jsonb_array_elements(res -> 'proposals') x where x ->> 'section' = 'B.7';
  perform public.erp_submit_change_set(v_cs);
  perform public.erp_approve_change_set(v_cs);
  perform public.erp_promote_change_set(v_cs);
  select e.id into v_ie from erp.entity e where e.tenant_id = v_tenant and e.code = 'NW-IE';
  select e.id into v_de from erp.entity e where e.tenant_id = v_tenant and e.code = 'NW-DE';

  -- 3. Modules, per company where the installer knows companies.
  perform public.erp_configure_finance(null::integer, null::character, null::uuid);
  perform public.erp_configure_finance(null::integer, 'EUR'::character(3), v_ie);
  perform public.erp_configure_finance(null::integer, 'EUR'::character(3), v_de);
  perform public.erp_configure_master_data('administrator');
  perform public.erp_configure_procurement(1000000);
  perform public.erp_configure_sales(15);
  perform public.erp_configure_inventory('standard', 'administrator');
  perform public.erp_configure_quality();
  perform public.erp_configure_logistics();

  -- 4. Parties, then sites (the provider has to exist before it operates one).
  v_logi    := (public.erp_create_party_with_roles('LOGI', 'Logistik GmbH', array['agent'], 'DE', 'Logistik GmbH') ->> 'party_id')::uuid;
  v_sup     := (public.erp_create_party_with_roles('SUP-UK', 'Midlands Components Ltd', array['supplier'], 'GB', null) ->> 'party_id')::uuid;
  v_cons    := (public.erp_create_party_with_roles('SUP-CONS', 'Consigning Pharma plc', array['supplier'], 'GB', null) ->> 'party_id')::uuid;
  v_cust_gb := (public.erp_create_party_with_roles('CUST-GB', 'Northern Retail Ltd', array['customer'], 'GB', null) ->> 'party_id')::uuid;
  v_cust_us := (public.erp_create_party_with_roles('CUST-US', 'Great Lakes Distribution Inc', array['customer'], 'US', null) ->> 'party_id')::uuid;

  v_wh    := (public.erp_create_site('NW-GB-WH', 'Nordwind warehouse', 'warehouse', v_gb, 'GB', 'Europe/London', null) ->> 'site_id')::uuid;
  v_recv   := public.erp_create_location(v_wh, 'RECV', 'Receiving', 'receiving');
  v_bulk_a := public.erp_create_location(v_wh, 'BULK-A', 'Bulk A', 'bulk');
  v_bulk_b := public.erp_create_location(v_wh, 'BULK-B', 'Bulk B', 'bulk');
  v_quar   := public.erp_create_location(v_wh, 'QUAR', 'Quarantine', 'quarantine');
  v_ie_wh  := (public.erp_create_site('NW-IE-WH', 'Dublin warehouse', 'warehouse', v_ie, 'IE', 'Europe/Dublin', null) ->> 'site_id')::uuid;
  v_ie_bulk := public.erp_create_location(v_ie_wh, 'BULK', 'Bulk', 'bulk');
  v_3pl   := (public.erp_create_site('NW-DE-3PL', 'Logistik provider warehouse', 'third_party', v_de, 'DE', 'Europe/Berlin', v_logi) ->> 'site_id')::uuid;

  -- 5. Products and how their stock is identified.
  v_ph := (public.erp_create_item('PH-001', 'Paracetamol 500 mg', 'PHARMA', true) ->> 'item_id')::uuid;
  perform public.erp_set_item_controls(v_ph, true, true, 365, 90, true, null);
  v_hw := (public.erp_create_item('HW-001', 'Hex bolt M8', 'HARDWARE', false) ->> 'item_id')::uuid;
  v_fg := (public.erp_create_item('FG-001', 'Assembled unit', 'FG', false) ->> 'item_id')::uuid;

  -- 6. Standards, before anything is received.
  perform public.erp_set_standard_cost(v_hw, v_wh, 1000, 'GBP');
  perform public.erp_set_standard_cost(v_ph, v_wh, 500, 'GBP');
  perform public.erp_set_standard_cost(v_fg, v_wh, 2500, 'GBP');
  perform public.erp_set_standard_cost(v_hw, v_3pl, 1200, 'EUR');

  -- 7. Words, rates, and who approves what.
  perform public.erp_set_resource_override('glossary.handling_unit', 'Cage', 'en', 'what the floor calls it');
  perform public.erp_set_resource_override('custom.cage_word', 'Cage', 'en', 'a word of Nordwind''s own');
  perform public.erp_set_exchange_rate('EUR', 'GBP', 0.85, current_date, 'spot', 'ECB euro reference rate, fixture');
  perform public.erp_set_exchange_rate('GBP', 'EUR', 1.18, current_date, 'spot', 'ECB euro reference rate, fixture');
  v_buyer := (public.erp_invite_principal('buyer@' || p_code || '.test', 'Nordwind Buyer') ->> 'app_user_id')::uuid;
  v_dept  := (public.erp_upsert_department('NW-BUY', 'Buying', v_buyer, null, null, null, null) ->> 'department_id')::uuid;
  perform public.erp_upsert_approval_band(v_dept, 'purchase_order', 1, null, 80000, v_buyer, null, false, 'GBP', false, true, null, 'hold_and_raise', null);
  perform public.erp_assign_department(v_admin, v_dept, true, null, null);

  return jsonb_build_object(
    'tenant_id', v_tenant, 'admin_id', v_admin, 'buyer_id', v_buyer, 'department_id', v_dept,
    'gb', v_gb, 'ie', v_ie, 'de', v_de,
    'wh', v_wh, 'ie_wh', v_ie_wh, 'tpl', v_3pl,
    'recv', v_recv, 'bulk_a', v_bulk_a, 'bulk_b', v_bulk_b, 'quar', v_quar, 'ie_bulk', v_ie_bulk,
    'logi', v_logi, 'sup', v_sup, 'cons', v_cons, 'cust_gb', v_cust_gb, 'cust_us', v_cust_us,
    'ph', v_ph, 'hw', v_hw, 'fg', v_fg,
    'shape_change_set', v_cs);
end;
$$;

create or replace function erp_test.second_organisation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  f        jsonb;
  v_tenant uuid; v_wh uuid; v_gb uuid; v_ie uuid; v_de uuid;
  res      jsonb;
  v_doc uuid; v_line uuid; v_doc2 uuid; v_line2 uuid; v_so uuid; v_po uuid; v_po_line uuid; v_grn uuid;
  v_b_soon uuid; v_b_late uuid; v_alloc uuid; v_alloc2 uuid; v_pallet uuid;
  v_n integer; v_m integer; v_q numeric; v_k integer;
  v_msg text; v_out text; v_ui_key text; v_ui_en text;
  v_owner uuid; v_keeper uuid;
  v_before bigint; v_after bigint;
begin
  begin
  f := erp_test.nordwind_fixture('nordwind', '00000000-0000-4000-8000-0000000000e1', 'admin@nordwind.test');
  v_tenant := (f ->> 'tenant_id')::uuid; v_wh := (f ->> 'wh')::uuid;
  v_gb := (f ->> 'gb')::uuid; v_ie := (f ->> 'ie')::uuid; v_de := (f ->> 'de')::uuid;

  -- 1. Onboarded from empty, through doors.
  v_cases := v_cases + 1;
  case_name := 'Nordwind is onboarded from nothing: three companies under three legislation packs, eight modules installed, standard costing, pallet identity, FIFO';
  passed := (select count(*) from erp.entity e where e.tenant_id = v_tenant and e.status = 'active') = 3
        and (select count(*) from erp.entity_legislation_binding b where b.tenant_id = v_tenant and b.status = 'active') = 3
        and exists (select 1 from erp.entity_legislation_binding b join erp.entity e on e.id = b.entity_id where e.id = v_de and b.pack_code = 'de_ust')
        and (select count(*) from erp.ledger l where l.tenant_id = v_tenant and l.code = 'GL') = 3
        and exists (select 1 from erp.costing_policy c where c.tenant_id = v_tenant and c.code = 'DEFAULT' and c.method = 'standard')
        and exists (select 1 from erp.container_identity_policy p where p.tenant_id = v_tenant and p.identity_level = 'pallet')
        and (select count(*) from erp.change_set cs where cs.tenant_id = v_tenant and cs.status = 'promoted') = 8
        and (select count(*) from erp.site s where s.tenant_id = v_tenant) = 3;
  detail := format('%s companies, %s bindings, %s general ledgers, %s promoted change sets, %s sites',
                   (select count(*) from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'),
                   (select count(*) from erp.entity_legislation_binding b where b.tenant_id = v_tenant and b.status = 'active'),
                   (select count(*) from erp.ledger l where l.tenant_id = v_tenant and l.code = 'GL'),
                   (select count(*) from erp.change_set cs where cs.tenant_id = v_tenant and cs.status = 'promoted'),
                   (select count(*) from erp.site s where s.tenant_id = v_tenant));
  return next;

  -- 2. Ownership split: consigned stock is held and counted, not owned or valued.
  v_cases := v_cases + 1;
  v_doc := (public.erp_create_document('goods_receipt', (f ->> 'cons')::uuid, v_wh, 'CONS-1', null, v_gb, null, (f ->> 'cons')::uuid) ->> 'document_id')::uuid;
  v_line := (public.erp_add_document_line(v_doc, (f ->> 'hw')::uuid, 40, 900, 'consigned bolts') ->> 'line_id')::uuid;
  perform public.erp_set_line_stock_identity(v_line, null, (f ->> 'bulk_b')::uuid, null);
  perform public.erp_transition_document(v_doc, 'post', 'harness');
  select m.owner_party_id, m.custody_party_id into v_owner, v_keeper
    from erp.stock_movement m where m.tenant_id = v_tenant and m.document_id = v_doc limit 1;
  v_n := (select count(*) from jsonb_array_elements(public.erp_stock_valuation()) v where v ->> 'item_code' = 'HW-001');
  v_k := public.erp_raise_count_tasks('cycle_a');
  case_name := 'consigned stock is held by Nordwind and owned by the consignor: unvalued, unposted, but counted';
  passed := v_owner = (f ->> 'cons')::uuid
        and v_keeper = (select e.party_id from erp.entity e where e.id = v_gb)
        and v_n = 0
        and not exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_doc)
        and exists (select 1 from erp.count_task ct where ct.tenant_id = v_tenant and ct.item_id = (f ->> 'hw')::uuid
                     and ct.owner_party_id = (f ->> 'cons')::uuid and ct.status = 'open');
  detail := format('owner is consignor: %s; keeper is Nordwind: %s; valuation rows for HW-001: %s (expected 0); journal: %s; %s count task(s) raised',
                   v_owner = (f ->> 'cons')::uuid, v_keeper = (select e.party_id from erp.entity e where e.id = v_gb), v_n,
                   exists (select 1 from erp.journal j where j.document_id = v_doc), v_k);
  return next;

  -- 3. Custody split: stock at the provider's warehouse is owned and valued, kept by the provider, not counted.
  v_cases := v_cases + 1;
  v_doc := (public.erp_create_document('goods_receipt', (f ->> 'sup')::uuid, (f ->> 'tpl')::uuid, '3PL-1', null, v_de, 'EUR', null) ->> 'document_id')::uuid;
  v_line := (public.erp_add_document_line(v_doc, (f ->> 'hw')::uuid, 25, 1200, 'at the provider') ->> 'line_id')::uuid;
  perform public.erp_transition_document(v_doc, 'post', 'harness');
  select m.owner_party_id, m.custody_party_id into v_owner, v_keeper
    from erp.stock_movement m where m.tenant_id = v_tenant and m.document_id = v_doc limit 1;
  v_n := (select count(*) from jsonb_array_elements(public.erp_stock_valuation()) v
           where v ->> 'item_code' = 'HW-001' and v ->> 'site_code' = 'NW-DE-3PL');
  v_k := public.erp_raise_count_tasks('cycle_a');
  case_name := 'stock at the third-party warehouse is owned and valued by Nordwind Deutschland, kept by the provider, and not counted by Nordwind';
  passed := v_owner = (select e.party_id from erp.entity e where e.id = v_de)
        and v_keeper = (f ->> 'logi')::uuid
        and v_n = 1
        and exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.document_id = v_doc and j.entity_id = v_de)
        and not exists (select 1 from erp.count_task ct where ct.tenant_id = v_tenant and ct.site_id = (f ->> 'tpl')::uuid and ct.status = 'open');
  detail := format('owner is NW-DE: %s; keeper is the provider: %s; valued at the 3PL: %s row(s); journal in NW-DE: %s; open count tasks at the 3PL: %s',
                   v_owner = (select e.party_id from erp.entity e where e.id = v_de), v_keeper = (f ->> 'logi')::uuid, v_n,
                   exists (select 1 from erp.journal j where j.document_id = v_doc),
                   (select count(*) from erp.count_task ct where ct.site_id = (f ->> 'tpl')::uuid and ct.status = 'open'));
  return next;

  -- 4. Quarantine gate: a pharmaceutical batch is held on receipt and released by a signed statement.
  v_cases := v_cases + 1;
  v_b_soon := public.erp_create_batch((f ->> 'ph')::uuid, 'PH-SOON', current_date + 30, current_date - 10, (f ->> 'sup')::uuid);
  v_b_late := public.erp_create_batch((f ->> 'ph')::uuid, 'PH-LATE', current_date + 300, current_date - 5, (f ->> 'sup')::uuid);
  v_doc := (public.erp_create_document('goods_receipt', (f ->> 'sup')::uuid, v_wh, 'PH-1', null, v_gb, null, null) ->> 'document_id')::uuid;
  v_line := (public.erp_add_document_line(v_doc, (f ->> 'ph')::uuid, 100, 480, 'soon batch') ->> 'line_id')::uuid;
  perform public.erp_set_line_stock_identity(v_line, v_b_soon, (f ->> 'bulk_a')::uuid, null);
  v_line2 := (public.erp_add_document_line(v_doc, (f ->> 'ph')::uuid, 100, 480, 'late batch') ->> 'line_id')::uuid;
  perform public.erp_set_line_stock_identity(v_line2, v_b_late, (f ->> 'bulk_a')::uuid, null);
  perform public.erp_transition_document(v_doc, 'post', 'harness');
  v_q := (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
           where b.tenant_id = v_tenant and b.item_id = (f ->> 'ph')::uuid and b.stock_status = 'quarantine');
  v_so := (public.erp_create_document('sales_order', (f ->> 'cust_gb')::uuid, v_wh, null, null, v_gb, null, null) ->> 'document_id')::uuid;
  v_line := (public.erp_add_document_line(v_so, (f ->> 'ph')::uuid, 30, 900, 'pharma line') ->> 'line_id')::uuid;
  v_alloc := public.erp_reserve_for_line(v_line, null);
  v_msg := (select format('%s unmet, cause %s', a.unmet_quantity::integer, a.unmet_cause) from erp.allocation a where a.id = v_alloc);
  perform public.erp_release_batch(v_b_soon, v_wh, 'Certificate of analysis reviewed, all characteristics within specification', 'Qualified Person: N. Ward', null);
  perform public.erp_release_batch(v_b_late, v_wh, 'Certificate of analysis reviewed, all characteristics within specification', 'Qualified Person: N. Ward', null);
  v_m := (select count(*) from erp.stock_balance b where b.tenant_id = v_tenant and b.item_id = (f ->> 'ph')::uuid and b.stock_status = 'available' and b.quantity > 0);
  case_name := 'a pharmaceutical receipt is quarantined, a sales order cannot take it, and a signed qualified release makes it available';
  -- The reservation reserves nothing. Its cause reads no_stock rather than
  -- held_in_a_non_available_status, because available-to-promise counts only
  -- available stock before the cause is classified (deferred finding 29).
  passed := v_q = 200 and v_msg like '30 unmet, cause %' and v_m = 2;
  detail := format('%s in quarantine after receipt (expected 200); reservation: %s; %s available position(s) after release (expected 2)', v_q, v_msg, v_m);
  return next;

  -- 5. FEFO and FIFO in one order.
  v_cases := v_cases + 1;
  v_doc2 := (public.erp_create_document('goods_receipt', (f ->> 'sup')::uuid, v_wh, 'HW-FIFO', null, v_gb, null, null) ->> 'document_id')::uuid;
  v_line2 := (public.erp_add_document_line(v_doc2, (f ->> 'hw')::uuid, 60, 1000, 'own bolts, bulk A') ->> 'line_id')::uuid;
  perform public.erp_set_line_stock_identity(v_line2, null, (f ->> 'bulk_a')::uuid, null);
  perform public.erp_transition_document(v_doc2, 'post', 'harness');
  v_line2 := (public.erp_add_document_line(v_so, (f ->> 'hw')::uuid, 20, 1500, 'hardware line') ->> 'line_id')::uuid;
  v_alloc2 := public.erp_reserve_for_line(v_line2, null);
  -- The pharma line reserved nothing while its stock was quarantined; reserve it again now it is released.
  v_line := (public.erp_add_document_line(v_so, (f ->> 'ph')::uuid, 30, 900, 'pharma line, released') ->> 'line_id')::uuid;
  v_alloc := public.erp_reserve_for_line(v_line, null);
  perform public.erp_commit_allocation(v_alloc, null, null);
  perform public.erp_commit_allocation(v_alloc2, null, null);
  case_name := 'one sales order allocates the pharmaceutical line FEFO (the batch expiring first) and the hardware line FIFO from Nordwind''s own stock, never the consignor''s';
  passed := (select count(distinct al.batch_id) from erp.allocation_line al where al.allocation_id = v_alloc) = 1
        and exists (select 1 from erp.allocation_line al where al.allocation_id = v_alloc and al.batch_id = v_b_soon)
        and (select a.policy_code from erp.allocation a where a.id = v_alloc) = 'fefo'
        and (select a.policy_code from erp.allocation a where a.id = v_alloc2) = 'fifo'
        and (select coalesce(sum(al.quantity), 0) from erp.allocation_line al where al.allocation_id = v_alloc2) = 20
        and exists (select 1 from erp.allocation_line al where al.allocation_id = v_alloc2 and al.location_id = (f ->> 'bulk_a')::uuid);
  detail := format('pharma: batch %s by %s; hardware: %s by %s from %s',
                   (select b.batch_number from erp.allocation_line al join erp.batch b on b.id = al.batch_id where al.allocation_id = v_alloc limit 1),
                   (select a.policy_code from erp.allocation a where a.id = v_alloc),
                   (select coalesce(sum(al.quantity), 0) from erp.allocation_line al where al.allocation_id = v_alloc2),
                   (select a.policy_code from erp.allocation a where a.id = v_alloc2),
                   (select string_agg(distinct l.code, ',') from erp.allocation_line al join erp.location l on l.id = al.location_id where al.allocation_id = v_alloc2));
  return next;

  -- 6. A euro order against a sterling band.
  v_cases := v_cases + 1;
  res := public.erp_preview_approval_chain('purchase_order', 100000, 'EUR', (f ->> 'department_id')::uuid, (f ->> 'admin_id')::uuid);
  case_name := 'a €1,000 purchase order is routed against the £800 band at the loaded rate: £850, one approver, the band currency recorded';
  passed := jsonb_array_length(res -> 'steps') = 1
        and res -> 'steps' -> 0 ->> 'band_currency' = 'GBP'
        and (res -> 'steps' -> 0 ->> 'value_in_band_currency_minor')::bigint = 85000
        and res -> 'steps' -> 0 ->> 'approver_user_id' = f ->> 'buyer_id';
  detail := format('%s step(s); value in band currency %s %s', jsonb_array_length(res -> 'steps'),
                   res -> 'steps' -> 0 ->> 'value_in_band_currency_minor', res -> 'steps' -> 0 ->> 'band_currency');
  return next;

  -- 7. Austrian German falls back to German, then English; the word Nordwind coined is theirs in every locale.
  v_cases := v_cases + 1;
  select r.key, r.value into v_ui_key, v_ui_en from erp_ref.resource r
   where r.locale = 'en' and r.key like 'ui.%'
     and not exists (select 1 from erp_ref.resource d where d.key = r.key and d.locale = 'de')
   order by r.key limit 1;
  res := public.erp_resources('de-AT');
  -- The tenant reworded the handling unit in English; a German reader gets
  -- the German product word, because the chain reaches de before en.
  case_name := 'a de-AT user reads German where it exists, English where it does not, Nordwind''s own word where only English has it, and Nordwind''s English rewording only in English';
  passed := res ->> 'glossary.batch' = 'Charge'
        and res ->> v_ui_key = v_ui_en
        and res ->> 'custom.cage_word' = 'Cage'
        and res ->> 'glossary.handling_unit' = 'Ladeeinheit'
        and public.erp_resources('en') ->> 'glossary.handling_unit' = 'Cage';
  detail := format('glossary.batch → %s; %s → English; custom.cage_word → %s; glossary.handling_unit → %s',
                   res ->> 'glossary.batch', v_ui_key, res ->> 'custom.cage_word', res ->> 'glossary.handling_unit');
  return next;

  -- 8. Pallet identity with a hybrid count.
  v_cases := v_cases + 1;
  v_pallet := public.erp_create_handling_unit(v_wh, (f ->> 'bulk_b')::uuid, 'pallet', null, 'NW-PAL-1', (f ->> 'fg')::uuid);
  v_msg := null;
  begin
    perform public.erp_create_handling_unit(v_wh, (f ->> 'bulk_b')::uuid, 'carton', null, 'NW-CTN-X', (f ->> 'fg')::uuid);
  exception when others then v_msg := sqlerrm;
  end;
  v_doc := (public.erp_create_document('goods_receipt', (f ->> 'sup')::uuid, v_wh, 'FG-1', null, v_gb, null, null) ->> 'document_id')::uuid;
  v_line := (public.erp_add_document_line(v_doc, (f ->> 'fg')::uuid, 24, 2500, 'on the pallet') ->> 'line_id')::uuid;
  perform public.erp_set_line_stock_identity(v_line, null, (f ->> 'bulk_b')::uuid, v_pallet);
  v_line := (public.erp_add_document_line(v_doc, (f ->> 'fg')::uuid, 6, 2500, 'loose') ->> 'line_id')::uuid;
  perform public.erp_set_line_stock_identity(v_line, null, (f ->> 'bulk_a')::uuid, null);
  perform public.erp_transition_document(v_doc, 'post', 'harness');
  v_k := public.erp_raise_count_tasks('cycle_a');
  select ct.expected_quantity into v_q from erp.count_task ct
   where ct.tenant_id = v_tenant and ct.container_id = v_pallet and ct.status = 'open' and ct.counts_container;
  case_name := 'a pallet is built under the pallet policy, a carton is refused as finer than the policy, and the count asks for the pallet as one thing';
  passed := v_pallet is not null
        and coalesce(v_msg like 'CLOVEERP_IDENTITY_LEVEL_NOT_POLICY:%', false)
        and v_q = 24
        and exists (select 1 from erp.count_task ct where ct.tenant_id = v_tenant and ct.item_id = (f ->> 'fg')::uuid
                     and ct.location_id = (f ->> 'bulk_a')::uuid and ct.container_id is null and ct.status = 'open');
  detail := format('pallet built; carton: %s; pallet task expects %s (expected 24); loose task present', left(coalesce(v_msg, 'no refusal'), 60), v_q);
  return next;

  -- 9. Cross-border intercompany pair.
  v_cases := v_cases + 1;
  v_doc := (public.erp_create_document('sales_order', (select e.party_id from erp.entity e where e.id = v_ie), v_wh, 'IC-1', null, v_gb, null, null) ->> 'document_id')::uuid;
  perform public.erp_add_document_line(v_doc, (f ->> 'hw')::uuid, 10, 1500, 'to Dublin');
  v_po := public.erp_raise_intercompany_order(v_doc, (f ->> 'ie_wh')::uuid);
  case_name := 'a sterling sales order from the British company to the Irish one is mirrored as a euro purchase order in Ireland at the loaded rate, linked as one event';
  passed := exists (select 1 from erp.document d where d.id = v_po and d.entity_id = v_ie and d.currency = 'EUR' and d.exchange_rate = 1.18
                       and d.party_id = (select e.party_id from erp.entity e where e.id = v_gb))
        and exists (select 1 from erp.document_line dl where dl.document_id = v_po and dl.unit_price_minor = 1770 and dl.quantity = 10)
        and exists (select 1 from erp.document_relation rel where rel.from_document_id = v_po and rel.to_document_id = v_doc and rel.relation_kind = 'mirrors')
        and exists (select 1 from erp.event ev where ev.tenant_id = v_tenant and ev.event_type = 'document.mirrored' and ev.aggregate_id = v_po);
  detail := (select format('%s in %s: %s EUR at %s, mirrors %s', d.document_number, e.code,
                           (select sum(dl.net_minor) from erp.document_line dl where dl.document_id = v_po), d.exchange_rate,
                           (select d2.document_number from erp.document d2 where d2.id = v_doc))
               from erp.document d join erp.entity e on e.id = d.entity_id where d.id = v_po);
  return next;

  -- 10. The word Nordwind coined is untranslated in German until somebody translates it.
  v_cases := v_cases + 1;
  v_n := (select count(*) from public.erp_untranslated('de') u where u.key = 'custom.cage_word' and u.is_tenant_term);
  perform public.erp_set_resource_override('custom.cage_word', 'Käfig', 'de', null);
  v_m := (select count(*) from public.erp_untranslated('de') u where u.key = 'custom.cage_word');
  case_name := 'Nordwind''s own word shows as served from English in German until it is translated there';
  passed := v_n = 1 and v_m = 0 and public.erp_resources('de') ->> 'custom.cage_word' = 'Käfig';
  detail := format('untranslated in de before: %s, after: %s; de now reads %s', v_n, v_m, public.erp_resources('de') ->> 'custom.cage_word');
  return next;

  -- 11. Standard cost variance posted to the variance account.
  v_cases := v_cases + 1;
  v_po := (public.erp_create_document('purchase_order', (f ->> 'sup')::uuid, v_wh, 'PPV-1', null, v_gb, null, null) ->> 'document_id')::uuid;
  v_po_line := (public.erp_add_document_line(v_po, (f ->> 'hw')::uuid, 10, 1100, 'bolts above standard') ->> 'line_id')::uuid;
  perform public.erp_transition_document(v_po, 'submit', 'harness');
  perform public.erp_transition_document(v_po, 'approve', 'harness');
  perform public.erp_transition_document(v_po, 'send', 'harness');
  v_grn := (public.erp_create_document('goods_receipt', (f ->> 'sup')::uuid, v_wh, 'PPV-1', null, v_gb, null, null) ->> 'document_id')::uuid;
  perform public.erp_receive_against(v_grn, v_po_line, 10, null);
  perform public.erp_transition_document(v_grn, 'post', 'harness');
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_before
    from erp.journal j join erp.journal_line jl on jl.journal_id = j.id join erp.account a on a.id = jl.account_id
   where j.tenant_id = v_tenant and j.document_id = v_grn and a.code = '9100';
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0) into v_after
    from erp.journal j join erp.journal_line jl on jl.journal_id = j.id join erp.account a on a.id = jl.account_id
   where j.tenant_id = v_tenant and j.document_id = v_grn and a.code = '1200';
  case_name := 'a receipt priced above the standard debits inventory at standard and the difference to purchase price variance';
  passed := v_after = 10000 and v_before = 1000
        and exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant and m.document_id = v_grn and m.unit_cost_minor = 1000);
  detail := format('inventory debited %s (expected 10000 at standard 1000); variance debited %s (expected 1000)', v_after, v_before);
  return next;

  -- 12. Every per-organisation rule in the register holds for Nordwind.
  v_cases := v_cases + 1;
  set constraints all immediate;
  v_n := 0; v_out := null;
  for res in select to_jsonb(d) from erp_meta.diagnostic_check d
              where d.kind = 'assertion' and d.scope = 'tenant' and d.function_name <> 'assert_whole_database_reconciles'
              order by d.seq
  loop
    begin
      execute format('select %I.%I(%s)', res ->> 'schema_name', res ->> 'function_name', coalesce(res ->> 'arguments', ''));
    exception when others then
      v_n := v_n + 1;
      v_out := coalesce(v_out || '; ', '') || (res ->> 'function_name') || ': ' || left(sqlerrm, 90);
    end;
  end loop;
  case_name := 'every per-organisation check in the register passes for Nordwind after a day''s work';
  passed := v_n = 0;
  detail := coalesce(v_out, 'all tenant-scoped assertions green');
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 13. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'nordwind')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000e1');
  detail := 'nordwind rolled back with its three companies';
  return next;

  if v_cases <> 13 then
    raise exception 'CLOVEERP_SUITE_SHRANK: second_organisation_suite ran % cases, expected 13', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_second_organisation_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
  v_src    text;
  v_calls  text;
begin
  -- The harness proves the surface only if it used nothing else. Every erp.*
  -- call in the fixture or the suite fails the build by name.
  select string_agg(p.prosrc, E'\n') into v_src
    from pg_catalog.pg_proc p
   where p.pronamespace = 'erp_test'::regnamespace
     and p.proname in ('nordwind_fixture', 'second_organisation_suite');
  select string_agg(distinct m[1], ', ') into v_calls
    from regexp_matches(v_src, '(\merp\.[a-z_]+)\s*\(', 'g') m;
  if v_calls is not null then
    raise exception 'CLOVEERP_HARNESS_NOT_THROUGH_DOORS: the second-organisation harness calls %', v_calls
      using errcode = '23514',
            hint = 'D23 is proven through public doors alone; give the door the argument the function takes, or record what the surface lacks.';
  end if;

  create temp table if not exists _second_org on commit drop as
    select * from erp_test.second_organisation_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _second_org;
  drop table _second_org;
  if v_fail > 0 then
    raise exception E'CLOVEERP_SECOND_ORGANISATION_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 13 then
    raise exception 'CLOVEERP_SUITE_SHRANK: second_organisation_suite ran % cases, expected 13', v_all;
  end if;
  return format('second organisation: %s/%s cases passed, through public doors alone', v_all, v_all);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Isolation through every entry point
-- ═════════════════════════════════════════════════════════════════════════════

-- Every identifier one organisation owns, as text, so a read door's output can
-- be searched for any of them.
create or replace function erp_test.organisation_identifiers(p_tenant_id uuid)
returns uuid[]
language sql
stable
set search_path = ''
as $$
  select array_agg(id) from (
    select p_tenant_id as id
    union all select e.id from erp.entity e where e.tenant_id = p_tenant_id
    union all select s.id from erp.site s where s.tenant_id = p_tenant_id
    union all select l.id from erp.location l where l.tenant_id = p_tenant_id
    union all select p.id from erp.party p where p.tenant_id = p_tenant_id
    union all select i.id from erp.item i where i.tenant_id = p_tenant_id
    union all select d.id from erp.document d where d.tenant_id = p_tenant_id
    union all select dl.id from erp.document_line dl where dl.tenant_id = p_tenant_id
    union all select b.id from erp.batch b where b.tenant_id = p_tenant_id
    union all select a.id from erp.allocation a where a.tenant_id = p_tenant_id
    union all select ct.id from erp.count_task ct where ct.tenant_id = p_tenant_id
    union all select u.id from erp.app_user u where u.tenant_id = p_tenant_id
    union all select j.id from erp.journal j where j.tenant_id = p_tenant_id
    union all select cs.id from erp.change_set cs where cs.tenant_id = p_tenant_id
  ) x
$$;

-- Walk every zero-argument read door as the current session and report which
-- of the other organisation's identifiers appeared.
create or replace function erp_test.walk_read_doors(p_other uuid[])
returns table(doors_walked integer, doors_refused integer, leaks text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  d        record;
  v_text   text;
  v_found  uuid[];
  v_leaks  text := null;
begin
  doors_walked := 0; doors_refused := 0;
  for d in
    select p.proname
      from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname like 'erp\_%'
       and p.provolatile <> 'v'
       and p.pronargs = p.pronargdefaults
       and p.prokind = 'f'
     order by p.proname
  loop
    begin
      execute format('select coalesce(string_agg(t::text, E''\n''), '''') from public.%I() t', d.proname) into v_text;
      doors_walked := doors_walked + 1;
      select array_agg(distinct m[1]::uuid) into v_found
        from regexp_matches(v_text, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'g') m
       where m[1]::uuid = any (p_other);
      if v_found is not null then
        v_leaks := coalesce(v_leaks || '; ', '') || format('%s exposed %s identifier(s)', d.proname, array_length(v_found, 1));
      end if;
    exception when others then
      -- A refusal is not a leak: platform doors refuse a tenant administrator,
      -- and some doors refuse without a context they need.
      doors_refused := doors_refused + 1;
    end;
  end loop;
  leaks := v_leaks;
  return next;
end;
$$;

create or replace function erp_test.door_isolation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases integer := 0;
  fa jsonb; fb jsonb;
  v_ta uuid; v_tb uuid;
  v_ids_a uuid[]; v_ids_b uuid[];
  w record;
  v_doc_b uuid; v_line_b uuid; v_item_b uuid; v_site_b uuid;
  v_refused integer := 0; v_tried integer := 0; v_out text := null;
  v_msg text;
begin
  begin
  fa := erp_test.nordwind_fixture('nordwind-a', '00000000-0000-4000-8000-0000000000e2', 'admin@nordwind-a.test');
  fb := erp_test.nordwind_fixture('nordwind-b', '00000000-0000-4000-8000-0000000000e3', 'admin@nordwind-b.test');
  v_ta := (fa ->> 'tenant_id')::uuid; v_tb := (fb ->> 'tenant_id')::uuid;

  -- B does a day's work so its doors have something to show.
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000e3')::text, true);
  v_doc_b := (public.erp_create_document('purchase_order', (fb ->> 'sup')::uuid, (fb ->> 'wh')::uuid, 'B-PO-1', null, (fb ->> 'gb')::uuid, null, null) ->> 'document_id')::uuid;
  v_line_b := (public.erp_add_document_line(v_doc_b, (fb ->> 'hw')::uuid, 5, 1000, 'B''s bolts') ->> 'line_id')::uuid;
  v_item_b := (fb ->> 'hw')::uuid; v_site_b := (fb ->> 'wh')::uuid;
  v_ids_a := erp_test.organisation_identifiers(v_ta);
  v_ids_b := erp_test.organisation_identifiers(v_tb);

  -- 1. As A, every read door shows nothing of B.
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000e2')::text, true);
  select * into w from erp_test.walk_read_doors(v_ids_b);
  case_name := 'as the first organisation, every zero-argument read door returns no identifier of the second';
  passed := w.leaks is null and w.doors_walked >= 90;
  detail := format('%s door(s) walked, %s refused, leaks: %s', w.doors_walked, w.doors_refused, coalesce(w.leaks, 'none'));
  return next;

  -- 2. As B, every read door shows nothing of A.
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000e3')::text, true);
  select * into w from erp_test.walk_read_doors(v_ids_a);
  case_name := 'as the second organisation, every zero-argument read door returns no identifier of the first';
  passed := w.leaks is null and w.doors_walked >= 90;
  detail := format('%s door(s) walked, %s refused, leaks: %s', w.doors_walked, w.doors_refused, coalesce(w.leaks, 'none'));
  return next;

  -- 3. As A, the write doors refuse B's things.
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000e2')::text, true);
  for v_msg in
    select unnest(array[
      format('select public.erp_transition_document(%L::uuid, ''submit'', ''isolation'')', v_doc_b),
      format('select public.erp_add_document_line(%L::uuid, %L::uuid, 1, 1, ''isolation'')', v_doc_b, v_item_b),
      format('select public.erp_set_line_stock_identity(%L::uuid, null, null, null)', v_line_b),
      format('select public.erp_stamp_document_approval(%L::uuid)', v_doc_b),
      format('select public.erp_create_document(''goods_receipt'', %L::uuid, %L::uuid, null, null, %L::uuid, null, null)', fb ->> 'sup', v_site_b, fb ->> 'gb'),
      format('select public.erp_create_batch(%L::uuid, ''X-1'', null, null, null)', v_item_b),
      format('select public.erp_set_standard_cost(%L::uuid, %L::uuid, 1, null)', v_item_b, v_site_b),
      format('select public.erp_create_location(%L::uuid, ''X'', ''X'', ''bulk'')', v_site_b),
      format('select public.erp_reserve_for_line(%L::uuid, null)', v_line_b),
      format('select public.erp_raise_intercompany_order(%L::uuid, %L::uuid)', v_doc_b, v_site_b)])
  loop
    v_tried := v_tried + 1;
    begin
      execute v_msg;
      v_out := coalesce(v_out || '; ', '') || left(v_msg, 60);
    exception when others then
      v_refused := v_refused + 1;
    end;
  end loop;
  case_name := 'as the first organisation, every write door presented with the second''s document, line, item or site refuses';
  passed := v_refused = v_tried and v_tried = 10
        and not exists (select 1 from erp.document_line dl where dl.document_id = v_doc_b and dl.description = 'isolation')
        and not exists (select 1 from erp.batch b where b.item_id = v_item_b and b.batch_number = 'X-1');
  detail := format('%s of %s refused%s', v_refused, v_tried, case when v_out is null then '' else '; accepted: ' || v_out end);
  return next;

  -- 4. Both organisations reconcile, side by side.
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', ''::text, true);
  v_out := erp.assert_whole_database_reconciles();
  case_name := 'with two organisations built through the doors, the whole database reconciles';
  passed := v_out like 'whole database: % organisation(s), % check(s), all reconcile';
  detail := v_out;
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 5. Undone.
  v_cases := v_cases + 1;
  case_name := 'the fixtures were undone';
  passed := not exists (select 1 from erp.tenant where code in ('nordwind-a', 'nordwind-b'))
        and not exists (select 1 from auth.users where id in ('00000000-0000-4000-8000-0000000000e2', '00000000-0000-4000-8000-0000000000e3'));
  detail := 'both organisations rolled back';
  return next;

  if v_cases <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: door_isolation_suite ran % cases, expected 5', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_door_isolation_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _door_isolation on commit drop as
    select * from erp_test.door_isolation_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _door_isolation;
  drop table _door_isolation;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DOOR_ISOLATION_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: door_isolation_suite ran % cases, expected 5', v_all;
  end if;
  return format('door isolation: %s/%s cases passed', v_all, v_all);
end;
$$;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D23', 'erp_test', 'assert_second_organisation_suite',
   'A second organisation, shaped nothing like the first, is onboarded, configured and operated through public doors alone; the wrapper reads the harness''s source and refuses any erp.* call.'),
  ('D23', 'erp_test', 'assert_door_isolation_suite',
   'Two organisations built through the doors; every zero-argument read door walked as each shows nothing of the other, and every write door presented with the other''s things refuses.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_second_organisation_suite();
select erp_test.assert_door_isolation_suite();
select erp_test.assert_companies_suite();
select erp_test.assert_ownership_suite();
select erp_test.assert_identity_policy_suite();
select erp_test.assert_allocation_policy_suite();
select erp_test.assert_procurement_suite();
select erp_test.assert_sales_suite();
select erp_test.assert_quality_logistics_suite();
select erp.assert_whole_database_reconciles();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_configuration_promotable();
select erp.assert_packs_installable();
select erp.assert_part5_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_resource_coverage();
select erp.assert_resource_coverage_de();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- And the whole console, green.
do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
