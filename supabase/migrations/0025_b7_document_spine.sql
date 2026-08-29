-- =============================================================================
-- ERPWare — B7 (part 4/5): the document spine
-- Spec 4.5 (Documents)
--
--   "Document types are configuration on the spine: requisition, purchase
--    order, receipt, return to supplier, quotation, sales order, delivery,
--    invoice reference, credit reference, transfer order, works order,
--    adjustment, count"
--   "Each type binds to a state machine definition, an approval configuration
--    and a numbering rule"
--   Invariants: "lineage is navigable in both directions; a document's state
--   history is complete; no document may be deleted, only cancelled or
--   reversed with reason"
--
-- One spine, thirteen types. The alternative — a purchase_order table, a
-- sales_order table, a delivery table — is how an ERP acquires thirteen
-- slightly different implementations of numbering, approval, cancellation and
-- lineage, twelve of which have a bug the thirteenth does not.
--
-- Two things are deliberately NOT columns on the document:
--
--   state    lives in erp.object_state, where the B4 engine put it. Copying it
--            here would create a second answer to "what state is this in", and
--            the copy is the one that goes stale.
--
--   totals   are derived from the lines by erp.document_total. A stored total
--            is a number someone can correct without correcting the lines.
--
-- Tenant-defined document types are permitted (spec 6.1, level 2) but must
-- name a base type from the product catalogue, so they inherit behaviour that
-- already exists rather than inventing some.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The product catalogue of document types
-- -----------------------------------------------------------------------------

create type erp.document_flow as enum ('inbound', 'outbound', 'internal', 'none');

create table erp_ref.document_type (
  code               text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name_key           text not null,
  module_code        text references erp_ref.module(code),
  flow               erp.document_flow not null,
  -- What the type is capable of. A tenant may not turn a quotation into
  -- something that moves stock by configuration alone.
  affects_stock      boolean not null default false,
  affects_finance    boolean not null default false,
  requires_party     boolean not null default true,
  requires_site      boolean not null default false,
  description        text
);

comment on table erp_ref.document_type is
  'Product content. The thirteen document types of spec 4.5, each declaring '
  'what it is capable of. Tenant-defined types inherit from one of these.';

insert into erp_ref.document_type
  (code, name_key, module_code, flow, affects_stock, affects_finance, requires_party, requires_site, description) values
  ('requisition',       'document.requisition',       'procurement','internal', false, false, false, false, 'An internal request to buy.'),
  ('purchase_order',    'document.purchase_order',    'procurement','inbound',  false, true,  true,  true,  'A commitment to a supplier.'),
  ('receipt',           'document.receipt',           'procurement','inbound',  true,  true,  true,  true,  'Goods arriving.'),
  ('return_to_supplier','document.return_to_supplier','procurement','outbound', true,  true,  true,  true,  'Goods going back.'),
  ('quotation',         'document.quotation',         'sales',      'outbound', false, false, true,  false, 'An offer, before it is an order.'),
  ('sales_order',       'document.sales_order',       'sales',      'outbound', false, true,  true,  true,  'A commitment to a customer.'),
  ('delivery',          'document.delivery',          'sales',      'outbound', true,  true,  true,  true,  'Goods leaving.'),
  ('invoice_reference', 'document.invoice_reference', 'finance',    'none',     false, true,  true,  false, 'The operational side of an invoice; the posting is a journal.'),
  ('credit_reference',  'document.credit_reference',  'finance',    'none',     false, true,  true,  false, 'The operational side of a credit.'),
  ('transfer_order',    'document.transfer_order',    'inventory',  'internal', true,  false, false, true,  'Stock moving between sites or locations.'),
  ('works_order',       'document.works_order',       'production', 'internal', true,  true,  false, true,  'Making, assembling, repacking or reworking.'),
  ('adjustment',        'document.adjustment',        'inventory',  'internal', true,  true,  false, true,  'A deliberate change to stock, with a reason.'),
  ('count',             'document.count',             'inventory',  'internal', true,  true,  false, true,  'A physical count and what it found.')
on conflict (code) do nothing;

insert into erp_ref.resource (key, locale, value) values
  ('document.requisition','en','Requisition'),
  ('document.purchase_order','en','Purchase order'),
  ('document.receipt','en','Goods receipt'),
  ('document.return_to_supplier','en','Return to supplier'),
  ('document.quotation','en','Quotation'),
  ('document.sales_order','en','Sales order'),
  ('document.delivery','en','Delivery note'),
  ('document.invoice_reference','en','Invoice'),
  ('document.credit_reference','en','Credit note'),
  ('document.transfer_order','en','Transfer order'),
  ('document.works_order','en','Works order'),
  ('document.adjustment','en','Stock adjustment'),
  ('document.count','en','Stock count')
on conflict (key, locale) do nothing;

-- -----------------------------------------------------------------------------
-- Numbering rules
--
-- Human-facing numbers come from configured sequences (spec 4.10). The
-- surrogate key is opaque and never shown; the number is what people quote
-- down a telephone, so its shape is the tenant's business.
-- -----------------------------------------------------------------------------

create type erp.number_reset as enum ('never', 'yearly', 'monthly', 'daily');

create table erp.numbering_rule (
  id             uuid not null default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  code           text not null,
  entity_id      uuid,
  site_id        uuid,
  prefix         text not null default '',
  suffix         text not null default '',
  pad_to         smallint not null default 6 check (pad_to between 1 and 20),
  -- Included in the key so a yearly reset does not collide with last year.
  reset_period   erp.number_reset not null default 'yearly',
  next_value     bigint not null default 1 check (next_value >= 1),
  current_period text not null default '',
  status         erp.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete cascade
);

create or replace function erp.next_document_number(p_numbering_rule_id uuid)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        erp.numbering_rule%rowtype;
  v_period text;
  v_value  bigint;
begin
  -- Locked, not read-then-written: two orders taken in the same second must
  -- not receive the same number.
  select * into r from erp.numbering_rule
   where tenant_id = v_tenant and id = p_numbering_rule_id for update;

  if not found then
    raise exception 'ERPWARE_NUMBERING_RULE_NOT_FOUND: %', p_numbering_rule_id
      using errcode = '23503';
  end if;

  v_period := case r.reset_period
    when 'never'   then ''
    when 'yearly'  then to_char(current_date, 'YYYY')
    when 'monthly' then to_char(current_date, 'YYYYMM')
    when 'daily'   then to_char(current_date, 'YYYYMMDD')
  end;

  if v_period is distinct from r.current_period then
    v_value := 1;
    update erp.numbering_rule
       set current_period = v_period, next_value = 2, updated_at = now()
     where id = r.id;
  else
    v_value := r.next_value;
    update erp.numbering_rule
       set next_value = r.next_value + 1, updated_at = now()
     where id = r.id;
  end if;

  return r.prefix
       || case when v_period = '' then '' else v_period || '-' end
       || lpad(v_value::text, r.pad_to, '0')
       || r.suffix;
end;
$$;

-- -----------------------------------------------------------------------------
-- Tenant document types, and their bindings
-- -----------------------------------------------------------------------------

create table erp.document_type (
  id                 uuid not null default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant(id) on delete cascade,
  code               text not null,
  -- Spec 6.1 level 2: a tenant-defined type is bound to existing behaviour.
  base_type_code     text not null references erp_ref.document_type(code),
  name               text,
  name_key           text,
  entity_id          uuid,
  site_id            uuid,
  -- Spec 4.5: each type binds to a state machine, an approval configuration
  -- and a numbering rule.
  state_machine_code text,
  approval_chain_code text,
  numbering_rule_id  uuid,
  status             erp.record_status not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete cascade,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete cascade,
  foreign key (tenant_id, numbering_rule_id)
    references erp.numbering_rule (tenant_id, id) on delete restrict
);

create index on erp.document_type (tenant_id, base_type_code) where status = 'active';

-- -----------------------------------------------------------------------------
-- The spine
-- -----------------------------------------------------------------------------

create table erp.document (
  id                uuid not null default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant(id) on delete cascade,
  entity_id         uuid not null,
  site_id           uuid,
  document_type_id  uuid not null,
  document_number   text not null,

  party_id          uuid,
  party_role_id     uuid,
  -- Where the goods or the invoice actually go, captured at the time: an
  -- address that changes later must not silently rewrite an old delivery note.
  address_snapshot  jsonb,

  document_date     date not null default current_date,
  required_date     date,
  due_date          date,
  posting_date      date,

  currency          char(3) references erp_ref.currency(code),
  -- Rate to the entity's base currency, fixed at the document's date.
  exchange_rate     numeric(20,10),

  our_reference     text,
  their_reference   text,
  notes             text,
  attributes        jsonb not null default '{}'::jsonb,

  -- No document may be deleted, only cancelled or reversed with reason.
  is_cancelled      boolean not null default false,
  cancelled_at      timestamptz,
  cancelled_by      uuid,
  cancellation_reason text,
  reverses_document_id uuid,

  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, document_type_id, document_number),
  foreign key (tenant_id, entity_id) references erp.entity (tenant_id, id) on delete restrict,
  foreign key (tenant_id, site_id)   references erp.site (tenant_id, id) on delete restrict,
  foreign key (tenant_id, document_type_id)
    references erp.document_type (tenant_id, id) on delete restrict,
  foreign key (tenant_id, party_id)  references erp.party (tenant_id, id) on delete restrict,
  foreign key (tenant_id, party_role_id)
    references erp.party_role (tenant_id, id) on delete restrict,
  foreign key (tenant_id, reverses_document_id)
    references erp.document (tenant_id, id) on delete restrict,
  constraint document_cancelled_has_reason
    check (not is_cancelled or cancellation_reason is not null)
);

create index on erp.document (tenant_id, document_type_id, document_date desc);
create index on erp.document (tenant_id, party_id) where party_id is not null;
create index on erp.document (tenant_id, site_id, document_date desc);
create index on erp.document (tenant_id, document_number);

create table erp.document_line (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  document_id      uuid not null,
  line_no          integer not null,

  item_id          uuid,
  description      text,

  quantity         numeric(20,6) not null default 0,
  uom_id           uuid,
  -- Progress against the line, so a part-delivered order is answerable
  -- without recomputing from the whole lineage on every read.
  quantity_fulfilled numeric(20,6) not null default 0,
  quantity_invoiced  numeric(20,6) not null default 0,

  unit_price_minor bigint,
  discount_pct     numeric(9,4) not null default 0,
  net_minor        bigint,
  tax_code         text,
  tax_rate_pct     numeric(9,4),
  tax_minor        bigint,
  currency         char(3) references erp_ref.currency(code),

  -- Analytical dimensions (spec 4.7), carried from the operational line into
  -- the posting so finance does not have to guess them.
  dimensions       jsonb not null default '{}'::jsonb,

  -- Batch and location commitments (spec 4.5).
  batch_id         uuid,
  location_id      uuid,
  container_id     uuid,
  serial_id        uuid,

  required_date    date,
  line_state       text not null default 'open',
  is_cancelled     boolean not null default false,
  notes            text,

  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, document_id, line_no),
  foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id)     references erp.item (tenant_id, id) on delete restrict,
  foreign key (tenant_id, uom_id)      references erp.uom (tenant_id, id) on delete restrict,
  foreign key (tenant_id, batch_id)    references erp.batch (tenant_id, id) on delete restrict,
  foreign key (tenant_id, location_id) references erp.location (tenant_id, id) on delete restrict,
  foreign key (tenant_id, container_id) references erp.container (tenant_id, id) on delete restrict,
  foreign key (tenant_id, serial_id)   references erp.serial (tenant_id, id) on delete restrict
);

create index on erp.document_line (tenant_id, document_id, line_no);
create index on erp.document_line (tenant_id, item_id) where item_id is not null;
create index on erp.document_line (tenant_id, batch_id) where batch_id is not null;

-- -----------------------------------------------------------------------------
-- Lineage
--
-- Invariant: navigable in both directions. One row, read either way — because
-- two rows per link is how a lineage graph ends up asymmetric.
-- -----------------------------------------------------------------------------

create type erp.document_relation_kind as enum (
  'fulfils',      -- delivery fulfils order
  'invoices',     -- invoice invoices delivery
  'credits',      -- credit reverses invoice
  'converts',     -- requisition converts to purchase order
  'returns',      -- return relates to the receipt it goes back on
  'consumes',     -- works order consumes a transfer
  'corrects',     -- reversal of an earlier document
  'consolidates'  -- one delivery covering several orders
);

create table erp.document_relation (
  id               uuid not null default gen_random_uuid(),
  tenant_id        uuid not null references erp.tenant(id) on delete cascade,
  from_document_id uuid not null,
  to_document_id   uuid not null,
  relation_kind    erp.document_relation_kind not null,
  from_line_id     uuid,
  to_line_id       uuid,
  quantity         numeric(20,6),
  created_at       timestamptz not null default now(),
  created_by       uuid,
  primary key (id),
  foreign key (tenant_id, from_document_id) references erp.document (tenant_id, id) on delete cascade,
  foreign key (tenant_id, to_document_id)   references erp.document (tenant_id, id) on delete cascade,
  foreign key (tenant_id, from_line_id) references erp.document_line (tenant_id, id) on delete cascade,
  foreign key (tenant_id, to_line_id)   references erp.document_line (tenant_id, id) on delete cascade,
  constraint document_relation_distinct check (from_document_id <> to_document_id)
);

-- An expression index rather than a constraint, because the nullable line
-- references must collapse: two document-level links of the same kind are the
-- same link, even though SQL considers their NULL line ids unequal.
create unique index document_relation_identity
  on erp.document_relation (
    tenant_id, from_document_id, to_document_id, relation_kind,
    coalesce(from_line_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(to_line_id,   '00000000-0000-0000-0000-000000000000'::uuid));

create index on erp.document_relation (tenant_id, from_document_id);
create index on erp.document_relation (tenant_id, to_document_id);

-- Both directions from one call, to whatever depth. "Show me everything this
-- invoice came from" and "show me everything that came of this order" are the
-- same question asked from opposite ends.
create or replace function erp.document_lineage(
  p_document_id uuid, p_direction text default 'both', p_max_depth integer default 20)
returns table (depth integer, direction text, document_id uuid,
               document_number text, base_type text, relation_kind text)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive back as (
    select 0 as depth, d.id as document_id, null::erp.document_relation_kind as rel
      from erp.document d
     where d.tenant_id = erp.require_tenant_id() and d.id = p_document_id
    union
    select b.depth + 1, r.from_document_id, r.relation_kind
      from back b
      join erp.document_relation r
        on r.tenant_id = erp.current_tenant_id() and r.to_document_id = b.document_id
     where b.depth < p_max_depth
  ),
  fwd as (
    select 0 as depth, d.id as document_id, null::erp.document_relation_kind as rel
      from erp.document d
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
    union
    select f.depth + 1, r.to_document_id, r.relation_kind
      from fwd f
      join erp.document_relation r
        on r.tenant_id = erp.current_tenant_id() and r.from_document_id = f.document_id
     where f.depth < p_max_depth
  ),
  combined as (
    select depth, 'upstream' as direction, document_id, rel from back where depth > 0
    union all
    select depth, 'downstream', document_id, rel from fwd where depth > 0
    union all
    select 0, 'self', p_document_id, null::erp.document_relation_kind
  )
  select c.depth, c.direction, c.document_id, d.document_number,
         dt.base_type_code, c.rel::text
    from combined c
    join erp.document d on d.id = c.document_id
    join erp.document_type dt on dt.id = d.document_type_id
   where p_direction = 'both' or c.direction in ('self', p_direction)
   order by c.direction, c.depth
$$;

comment on function erp.document_lineage is
  'Spec 4.5: lineage is navigable in both directions. One relation row read '
  'from either end, rather than two rows that can disagree.';

-- -----------------------------------------------------------------------------
-- Documents are cancelled or reversed, never deleted
-- -----------------------------------------------------------------------------

create or replace function erp.forbid_document_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if nullif(current_setting('erp.purge_tenant_id', true), '')::uuid = old.tenant_id then
    return old;
  end if;

  raise exception
    'ERPWARE_DOCUMENT_NOT_DELETABLE: a document is cancelled or reversed with a reason, never removed'
    using errcode = '42501',
          hint = 'Set is_cancelled with a cancellation_reason, or raise a reversing document.';
end;
$$;

create trigger t_document_no_delete
  before delete on erp.document
  for each row execute function erp.forbid_document_delete();

-- A cancelled document is closed. Its lines are history from that moment.
create or replace function erp.protect_cancelled_document()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_cancelled boolean;
begin
  select d.is_cancelled into v_cancelled
    from erp.document d where d.id = coalesce(new.document_id, old.document_id);

  if coalesce(v_cancelled, false)
     and nullif(current_setting('erp.purge_tenant_id', true), '') is null then
    raise exception
      'ERPWARE_DOCUMENT_CANCELLED: the lines of a cancelled document cannot be changed'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger t_document_line_protect
  before insert or update or delete on erp.document_line
  for each row execute function erp.protect_cancelled_document();

-- -----------------------------------------------------------------------------
-- Derived reads
-- -----------------------------------------------------------------------------

-- Totals from the lines. Not stored, so a total cannot be corrected without
-- correcting what it is the total of.
create view erp.document_total as
select
  l.tenant_id,
  l.document_id,
  count(*) filter (where not l.is_cancelled)         as line_count,
  sum(l.net_minor) filter (where not l.is_cancelled) as net_minor,
  sum(l.tax_minor) filter (where not l.is_cancelled) as tax_minor,
  sum(coalesce(l.net_minor, 0) + coalesce(l.tax_minor, 0))
    filter (where not l.is_cancelled)                as gross_minor,
  min(l.currency)                                    as currency
from erp.document_line l
group by l.tenant_id, l.document_id;

-- The document as people read it: spine, type, party, totals and the state the
-- B4 engine holds for it.
create view erp.document_view as
select
  d.tenant_id, d.id, d.document_number, d.entity_id, d.site_id,
  dt.code            as document_type,
  dt.base_type_code  as base_type,
  d.party_id, p.code as party_code, p.name as party_name,
  d.document_date, d.required_date, d.due_date, d.posting_date,
  d.currency, d.exchange_rate,
  d.our_reference, d.their_reference,
  d.is_cancelled, d.cancellation_reason,
  s.code             as state,
  s.is_terminal      as state_is_terminal,
  s.is_committed     as state_is_committed,
  t.line_count, t.net_minor, t.tax_minor, t.gross_minor,
  d.created_at, d.created_by, d.updated_at
from erp.document d
join erp.document_type dt
  on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
left join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
left join erp.object_state os
  on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
left join erp.state s on s.id = os.current_state_id
left join erp.document_total t on t.tenant_id = d.tenant_id and t.document_id = d.id;

comment on view erp.document_view is
  'The document as people read it. State comes from erp.object_state and totals '
  'from the lines, so neither can be edited into disagreeing with its source.';

-- -----------------------------------------------------------------------------
-- Raising a document
-- -----------------------------------------------------------------------------

create or replace function erp.create_document(
  p_document_type_code text,
  p_entity_id          uuid,
  p_site_id            uuid default null,
  p_party_id           uuid default null,
  p_document_date      date default null,
  p_currency           char(3) default null,
  p_their_reference    text default null,
  p_attributes         jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
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
  perform erp.start_lifecycle('document', v_id, p_entity_id, p_site_id);

  return v_id;
end;
$$;

create or replace function erp.cancel_document(p_document_id uuid, p_reason text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  if coalesce(p_reason, '') = '' then
    raise exception 'ERPWARE_CANCELLATION_NEEDS_REASON: a document is not cancelled without one'
      using errcode = '23514';
  end if;

  update erp.document
     set is_cancelled = true, cancelled_at = now(),
         cancelled_by = erp.current_principal_id(),
         cancellation_reason = p_reason, updated_at = now()
   where tenant_id = v_tenant and id = p_document_id and not is_cancelled;

  if not found then
    raise exception 'ERPWARE_DOCUMENT_NOT_OPEN: % is missing or already cancelled', p_document_id
      using errcode = '23514';
  end if;
end;
$$;

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_isolation();
select erp.assert_resource_coverage('en');
