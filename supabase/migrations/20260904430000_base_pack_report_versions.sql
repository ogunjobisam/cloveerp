-- =============================================================================
-- The base pack's eighteen reports get their versions
--
-- Found while bringing report versions inside promotion (20260904340000) and
-- stated carefully there: erp_ref.pack_item holds eighteen object_kind =
-- 'report' rows in the base pack, and every payload carried only a code, a
-- name, a description, a module, its KPI codes and its audiences. No version,
-- so no governed view, no columns, no permission, no parameters. Promoting one
-- of them gave the receiving organisation a report row and nothing behind it,
-- which is exactly the shape erp.assert_reports_reproducible() refuses with its
-- first finding — "a report has no version". CI stayed green because the
-- acceptance suite installs the pack and never asks that assertion; every
-- organisation that installed the base pack on live holds eighteen such rows.
--
-- Three things close it, in the house pattern of register, generator and
-- assertion:
--
--   1. A register of the views the product ships for reporting,
--      erp_ref.module_governed_view, keyed by the module installer that brings
--      each one. Seven of the eighteen reports read a shape no relation had —
--      stock valued at cost, the open order book, fulfilment against promise,
--      purchase order status, goods received not invoiced, supplier delivery
--      performance, and debtor and creditor ageing — so those seven are
--      created here as security_invoker views over the tables and views that
--      already exist. The other eleven read a table the module already owns.
--
--   2. A generator, erp.register_module_governed_views(), which
--      erp.install_module_config() runs whenever a module is installed. A view
--      is a boundary, not a behaviour: §19.1 puts the scoping in the view so a
--      report cannot forget it, and a boundary is the product's to ship rather
--      than an organisation's to promote. So a governed view is registered at
--      install time whether or not the module's change set is later promoted,
--      and existing organisations are backfilled from their own change-set
--      history below. The settled decision of the task, then: governed views
--      are neither pack-installable nor promotable — the installers own them.
--
--   3. The eighteen version payloads themselves, each naming the view it
--      reads, its columns, its sort, its formats, the permission it needs and
--      the parameters it takes, and a build guard —
--      erp.assert_pack_report_versions_sound() — that fails the build when a
--      pack report has no version, names a column its view does not have,
--      takes a parameter that would widen scope, or reads a view the product
--      does not ship. The runner does not execute the column list, so nothing
--      short of this assertion would notice a misspelt column.
--
-- And a gate. §11.7 says a pack "contains only what is missing", and a report
-- whose view is not yet installed is not missing — it is early. So
-- erp.plan_content_pack() holds such a report back, erp.pack_conflicts() says
-- so in an advisory that names the module that brings the view, and the next
-- application after that module is installed plans exactly the reports held
-- back. Same additive rule as a capability switched on later.
--
-- Live already holds the eighteen versionless reports in every organisation
-- that applied the base pack. Re-applying the pack after this migration plans
-- all eighteen again — their manifest content lacks a version, so containment
-- fails — and promoting that change set gives each its version 1. That is the
-- reconciliation path, and it needs nothing this migration does not carry.
-- =============================================================================

-- ── 1. Seven views the reports needed and no relation offered ─────────────────
--
-- All security_invoker, so each runs as the caller and row-level security on
-- the tables beneath scopes it — erp.governed_view_safety_report() refuses a
-- view without it. Every one keeps tenant_id as its first column so a report
-- reading it carries the tenant through.

-- What is held, where, and what it is worth: each stock position priced at the
-- item's cost for its site, falling back to the item's cost with no site.
create or replace view erp.stock_valuation with (security_invoker = true) as
select sp.tenant_id, sp.site_id, sp.location_id, sp.item_id,
       it.code as item_code, it.name as item_name,
       sp.batch_id, sp.serial_id, sp.container_id, sp.stock_status, sp.quantity,
       ic.method, ic.unit_cost_minor, ic.currency,
       (sp.quantity * coalesce(ic.unit_cost_minor, 0))::bigint as value_minor
  from erp.stock_position sp
  join erp.item it on it.tenant_id = sp.tenant_id and it.id = sp.item_id
  left join lateral (
    select c.method, c.unit_cost_minor, c.currency
      from erp.item_cost c
     where c.tenant_id = sp.tenant_id and c.item_id = sp.item_id
       and (c.site_id = sp.site_id or c.site_id is null)
     order by (c.site_id is not null) desc, c.effective_from desc
     limit 1) ic on true;

comment on view erp.stock_valuation is
  'Every stock position with the cost that applies to it: the item''s cost at '
  'that site if one is held, otherwise its cost with no site. Behind the Stock '
  'on hand and valuation report.';

-- Sales orders confirmed and not yet finished with, by promised date.
create or replace view erp.open_order_book with (security_invoker = true) as
select v.tenant_id, v.id, v.entity_id, v.site_id, v.document_number,
       v.party_id, v.party_code, v.party_name, v.document_date, v.required_date,
       v.state, v.line_count, v.net_minor, v.gross_minor, v.currency,
       (current_date - v.document_date) as days_open,
       coalesce(v.required_date < current_date, false) as is_overdue
  from erp.document_view v
 where v.base_type = 'sales_order'
   and not coalesce(v.is_cancelled, false)
   and not coalesce(v.state_is_terminal, false);

comment on view erp.open_order_book is
  'Sales orders that are neither cancelled nor in a terminal state, with how '
  'long each has been open and whether its promised date has passed.';

-- On-time and in-full against the promise, one row per sales order.
create or replace view erp.order_fulfilment with (security_invoker = true) as
select d.tenant_id, d.id, d.entity_id, d.site_id, d.document_number,
       d.party_id, d.party_code, d.party_name, d.document_date, d.required_date,
       d.state, d.state_is_terminal,
       sum(l.quantity)                                as ordered_quantity,
       sum(coalesce(l.quantity_fulfilled, 0))         as fulfilled_quantity,
       sum(coalesce(l.quantity_invoiced, 0))          as invoiced_quantity,
       case when sum(l.quantity) > 0
            then round(100 * sum(coalesce(l.quantity_fulfilled, 0)) / sum(l.quantity), 1)
            end                                       as fulfilment_pct,
       count(*)                                       as line_count,
       count(*) filter (where coalesce(l.quantity_fulfilled, 0) >= l.quantity)
                                                      as fulfilled_lines,
       case when sum(coalesce(l.quantity_fulfilled, 0)) < sum(l.quantity)
             and d.required_date < current_date
            then current_date - d.required_date else 0 end as days_late
  from erp.document_view d
  join erp.document_line l
    on l.tenant_id = d.tenant_id and l.document_id = d.id
   and not coalesce(l.is_cancelled, false)
 where d.base_type = 'sales_order'
   and not coalesce(d.is_cancelled, false)
 group by d.tenant_id, d.id, d.entity_id, d.site_id, d.document_number,
          d.party_id, d.party_code, d.party_name, d.document_date, d.required_date,
          d.state, d.state_is_terminal;

comment on view erp.order_fulfilment is
  'Each sales order''s ordered, fulfilled and invoiced quantities across its '
  'lines, the share fulfilled, and how many days late it is if it is short and '
  'past its promised date. Behind the Order fulfilment performance report.';

-- Purchase orders by state, with what is still outstanding.
create or replace view erp.purchase_order_status with (security_invoker = true) as
select d.tenant_id, d.id, d.entity_id, d.site_id, d.document_number,
       d.party_id, d.party_code, d.party_name, d.document_date, d.required_date,
       d.state, d.state_is_terminal,
       sum(l.quantity)                                as ordered_quantity,
       sum(coalesce(l.quantity_fulfilled, 0))         as received_quantity,
       sum(coalesce(l.quantity_invoiced, 0))          as invoiced_quantity,
       case when sum(l.quantity) > 0
            then round(100 * sum(coalesce(l.quantity_fulfilled, 0)) / sum(l.quantity), 1)
            end                                       as receipt_pct,
       count(*)                                       as line_count,
       count(*) filter (where coalesce(l.quantity_fulfilled, 0) >= l.quantity)
                                                      as received_lines,
       (current_date - d.document_date)               as days_outstanding
  from erp.document_view d
  join erp.document_line l
    on l.tenant_id = d.tenant_id and l.document_id = d.id
   and not coalesce(l.is_cancelled, false)
 where d.base_type = 'purchase_order'
   and not coalesce(d.is_cancelled, false)
 group by d.tenant_id, d.id, d.entity_id, d.site_id, d.document_number,
          d.party_id, d.party_code, d.party_name, d.document_date, d.required_date,
          d.state, d.state_is_terminal;

comment on view erp.purchase_order_status is
  'Each purchase order''s ordered, received and invoiced quantities across its '
  'lines, the share received, and its age. Behind the Purchase order status '
  'report.';

-- Received and not yet invoiced, line by line, valued at the order price.
create or replace view erp.grni with (security_invoker = true) as
select l.tenant_id, d.id as document_id, l.id as line_id, d.entity_id, d.site_id,
       d.document_number, d.party_id, d.party_code, d.party_name,
       l.line_no, l.item_id, it.code as item_code, l.description,
       l.quantity                                     as ordered_quantity,
       coalesce(l.quantity_fulfilled, 0)              as received_quantity,
       coalesce(l.quantity_invoiced, 0)               as invoiced_quantity,
       coalesce(l.quantity_fulfilled, 0) - coalesce(l.quantity_invoiced, 0)
                                                      as quantity_uninvoiced,
       ((coalesce(l.quantity_fulfilled, 0) - coalesce(l.quantity_invoiced, 0))
          * coalesce(l.unit_price_minor, 0))::bigint  as uninvoiced_value_minor,
       l.currency, d.document_date,
       (current_date - d.document_date)               as days_outstanding
  from erp.document_line l
  join erp.document_view d on d.tenant_id = l.tenant_id and d.id = l.document_id
  left join erp.item it on it.tenant_id = l.tenant_id and it.id = l.item_id
 where d.base_type = 'purchase_order'
   and not coalesce(d.is_cancelled, false)
   and not coalesce(l.is_cancelled, false)
   and coalesce(l.quantity_fulfilled, 0) > coalesce(l.quantity_invoiced, 0);

comment on view erp.grni is
  'Purchase order lines received beyond what has been invoiced, with the '
  'uninvoiced quantity valued at the order price and the order''s age. Behind '
  'the Goods-received-not-invoiced report.';

-- Delivery performance by supplier, over every purchase order line.
create or replace view erp.supplier_performance with (security_invoker = true) as
select d.tenant_id, d.party_id, d.party_code, d.party_name, d.entity_id,
       count(distinct d.id)                           as orders,
       count(*)                                       as lines,
       sum(l.quantity)                                as ordered_quantity,
       sum(coalesce(l.quantity_fulfilled, 0))         as received_quantity,
       count(*) filter (where coalesce(l.quantity_fulfilled, 0) < l.quantity
                          and coalesce(l.required_date, d.required_date) < current_date)
                                                      as late_lines,
       count(*) filter (where coalesce(l.quantity_fulfilled, 0) >= l.quantity)
                                                      as fulfilled_lines,
       min(d.document_date)                           as first_order_date,
       max(d.document_date)                           as last_order_date
  from erp.document_view d
  join erp.document_line l
    on l.tenant_id = d.tenant_id and l.document_id = d.id
   and not coalesce(l.is_cancelled, false)
 where d.base_type = 'purchase_order'
   and not coalesce(d.is_cancelled, false)
   and d.party_id is not null
 group by d.tenant_id, d.party_id, d.party_code, d.party_name, d.entity_id;

comment on view erp.supplier_performance is
  'One row per supplier and entity: orders and lines placed, quantities ordered '
  'and received, lines short past their required date, and the span of orders. '
  'Behind the Supplier performance report.';

-- Sales ledger and purchase ledger by age bucket. Direction comes from the
-- role the document was raised against, so a customer''s invoice is a
-- receivable and a supplier''s is a payable without a second document model.
create or replace view erp.ageing with (security_invoker = true) as
select d.tenant_id, d.id, d.entity_id, d.site_id, d.document_number,
       d.document_type, d.base_type,
       case pr.role_kind
         when 'customer' then 'receivable'
         when 'supplier' then 'payable'
         else 'other' end                             as direction,
       d.party_id, d.party_code, d.party_name, d.document_date, d.due_date,
       d.currency, d.gross_minor,
       case when d.base_type = 'credit_reference' then -d.gross_minor
            else d.gross_minor end                    as signed_minor,
       greatest(0, current_date - coalesce(d.due_date, d.document_date))
                                                      as days_overdue,
       case
         when current_date <= coalesce(d.due_date, d.document_date) then 'current'
         when current_date - coalesce(d.due_date, d.document_date) <= 30 then '1-30'
         when current_date - coalesce(d.due_date, d.document_date) <= 60 then '31-60'
         when current_date - coalesce(d.due_date, d.document_date) <= 90 then '61-90'
         else '90+' end                               as bucket
  from erp.document_view d
  join erp.document doc on doc.tenant_id = d.tenant_id and doc.id = d.id
  left join erp.party_role pr
    on pr.tenant_id = d.tenant_id and pr.id = doc.party_role_id
 where d.base_type in ('invoice_reference', 'credit_reference')
   and not coalesce(d.is_cancelled, false)
   and not coalesce(d.state_is_terminal, false);

comment on view erp.ageing is
  'Open invoices and credits by direction and age bucket — receivable when '
  'raised against a customer, payable against a supplier — with credits '
  'carried as negative amounts. Behind the Receivables and payables ageing '
  'report.';

-- ── 2. The register: what the product ships for reporting, and which module
--       brings it ────────────────────────────────────────────────────────────

create table if not exists erp_ref.module_governed_view (
  install_code        text not null,
  code                text not null,
  module_code         text not null references erp_ref.module (code),
  name_key            text not null,
  name                text not null,
  description         text not null,
  source_schema       text not null default 'erp',
  source_name         text not null,
  required_permission text not null references erp_ref.permission (code),
  lineage_columns     text[] not null,
  data_classes        text[] not null default '{}',
  seq                 integer not null,
  primary key (install_code, code),
  constraint module_governed_view_code_unique unique (code),
  constraint module_governed_view_code_shape check (code ~ '^[a-z][a-z0-9_]*$'),
  constraint module_governed_view_has_lineage check (cardinality(lineage_columns) > 0)
);

comment on table erp_ref.module_governed_view is
  'The views the product ships for reporting, keyed by the module installer '
  'that brings each one. erp.install_module_config() registers a module''s '
  'rows into erp.governed_view for the organisation installing it; a pack '
  'report names one of these by code, and is held back until it exists. Product '
  'content: a view is a boundary the product owns, not a behaviour an '
  'organisation promotes.';

select erp_meta.register_table('erp_ref', 'module_governed_view', 'product_content',
  'Register of the reporting views each module installer brings; read by '
  'erp.register_module_governed_views() and by the pack planner''s hold-back.');

insert into erp_ref.module_governed_view
  (install_code, code, module_code, name_key, name, description,
   source_schema, source_name, required_permission, lineage_columns, seq)
values
  -- Inventory operations
  ('inventory-operations', 'stock_valuation', 'inventory',
   'reporting.view.stock_valuation', 'Stock valuation',
   'Every stock position with the cost that applies to it.',
   'erp', 'stock_valuation', 'inventory.read',
   '{item_id,site_id,location_id}', 10),
  ('inventory-operations', 'stock_movement', 'inventory',
   'reporting.view.stock_movement', 'Stock movements',
   'Every movement of stock, with its reason and the document behind it.',
   'erp', 'stock_movement', 'inventory.read',
   '{id,movement_uid,document_id}', 20),
  ('inventory-operations', 'batch', 'inventory',
   'reporting.view.batch', 'Batches',
   'Batches with their dates: manufactured, expiry, retest and best before.',
   'erp', 'batch', 'inventory.read',
   '{id,item_id}', 30),
  ('inventory-operations', 'count_task', 'inventory',
   'reporting.view.count_task', 'Stock counts',
   'Count tasks with expected and counted quantities and the variance between them.',
   'erp', 'count_task', 'inventory.read',
   '{id,count_programme_id}', 40),
  -- Quality
  ('quality', 'batch_genealogy', 'quality',
   'reporting.view.batch_genealogy', 'Batch genealogy',
   'What each batch was made from and what was made from it.',
   'erp', 'batch_genealogy', 'quality.read',
   '{id,parent_batch_id,child_batch_id,movement_id}', 50),
  ('quality', 'quality_event', 'quality',
   'reporting.view.quality_event', 'Quality events',
   'Quality events by state, severity, root cause and the actions taken.',
   'erp', 'quality_event', 'quality.read',
   '{id,reference}', 60),
  ('quality', 'recall_impact', 'quality',
   'reporting.view.recall_impact', 'Recall despatches',
   'Every despatch a recalled batch reached, captured when the recall was raised.',
   'erp', 'recall_impact', 'quality.read',
   '{id,recall_id,movement_id}', 70),
  -- Sales lifecycle
  ('sales-lifecycle', 'open_order_book', 'sales',
   'reporting.view.open_order_book', 'Open order book',
   'Sales orders not yet finished with, by promised date.',
   'erp', 'open_order_book', 'sales.read',
   '{id,document_number}', 80),
  ('sales-lifecycle', 'order_fulfilment', 'sales',
   'reporting.view.order_fulfilment', 'Order fulfilment',
   'Each sales order''s ordered, fulfilled and invoiced quantities against its promise.',
   'erp', 'order_fulfilment', 'sales.read',
   '{id,document_number}', 90),
  -- Procurement lifecycle
  ('procurement-lifecycle', 'purchase_order_status', 'procurement',
   'reporting.view.purchase_order_status', 'Purchase order status',
   'Each purchase order''s ordered, received and invoiced quantities and its age.',
   'erp', 'purchase_order_status', 'procurement.read',
   '{id,document_number}', 100),
  ('procurement-lifecycle', 'supplier_performance', 'procurement',
   'reporting.view.supplier_performance', 'Supplier performance',
   'Orders, quantities and late lines by supplier.',
   'erp', 'supplier_performance', 'procurement.read',
   '{party_id,entity_id}', 110),
  ('procurement-lifecycle', 'grni', 'procurement',
   'reporting.view.grni', 'Goods received not invoiced',
   'Purchase order lines received beyond what has been invoiced, valued at the order price.',
   'erp', 'grni', 'procurement.read',
   '{document_id,line_id}', 120),
  -- Procurement controls
  ('procurement-controls', 'match_exception', 'procurement',
   'reporting.view.match_exception', 'Match exceptions',
   'Invoices that did not match their order within tolerance, and how each was resolved.',
   'erp', 'match_exception', 'procurement.read',
   '{id,order_line_id,invoice_document_id}', 130),
  -- Planning
  ('planning', 'planning_exception', 'planning',
   'reporting.view.planning_exception', 'Planning exceptions',
   'What the planning run could not resolve, by kind and severity.',
   'erp', 'planning_exception', 'planning.read',
   '{id,item_id}', 140),
  -- Production
  ('production', 'works_order', 'production',
   'reporting.view.works_order', 'Works orders',
   'Works orders with planned and actual dates, quantities completed and scrapped, and standard against actual cost.',
   'erp', 'works_order', 'production.read',
   '{id,order_number}', 150),
  -- Finance posting
  ('finance-posting', 'account_balance', 'finance',
   'reporting.view.account_balance', 'Nominal balances',
   'Debits, credits and balance by account, ledger and period.',
   'erp', 'account_balance', 'finance.read',
   '{account_id,fiscal_period_id}', 160),
  ('finance-posting', 'journal_line', 'finance',
   'reporting.view.journal_line', 'Journal lines',
   'Every posted journal line with its account, amounts and analysis codes.',
   'erp', 'journal_line', 'finance.read',
   '{id,journal_id,source_event_id}', 170),
  -- Receivables
  ('receivables', 'ageing', 'finance',
   'reporting.view.ageing', 'Debtor and creditor ageing',
   'Open invoices and credits by direction and age bucket.',
   'erp', 'ageing', 'finance.read',
   '{id,document_number}', 180)
on conflict (install_code, code) do update set
  module_code = excluded.module_code, name_key = excluded.name_key,
  name = excluded.name, description = excluded.description,
  source_schema = excluded.source_schema, source_name = excluded.source_name,
  required_permission = excluded.required_permission,
  lineage_columns = excluded.lineage_columns, seq = excluded.seq;

-- The labels, so a tenant can rename a view the way it renames a screen.
insert into erp_ref.resource (key, locale, value, module_code, description)
select m.name_key, 'en', m.name, m.module_code,
       format('Label for the %s reporting view, which the %s module brings.',
              m.name, m.module_code)
  from erp_ref.module_governed_view m
on conflict (key, locale) do nothing;

-- And the coverage report now reads the register, so a view registered without
-- its label fails the build like a module or a permission would.
create or replace function erp.resource_coverage_report(p_locale text default 'en')
returns table (source_table text, key text, finding text)
language sql
stable
set search_path = ''
as $$
  with referenced as (
    select 'erp_ref.module'          as src, m.name_key  as k from erp_ref.module m
    union all
    select 'erp_ref.permission',      p.name_key from erp_ref.permission p
    union all
    select 'erp_ref.config_type',     c.name_key from erp_ref.config_type c
    union all
    select 'erp_ref.decision_point',  d.name_key from erp_ref.decision_point d
    union all
    select 'erp_ref.event_type',      e.name_key from erp_ref.event_type e
    union all
    select 'erp_ref.legislation_pack', lp.name_key from erp_ref.legislation_pack lp
    union all
    select 'erp_ref.statutory_output', so.name_key from erp_ref.statutory_output so
    union all
    select 'erp_ref.module_governed_view', gv.name_key from erp_ref.module_governed_view gv
  )
  select r.src, r.k,
         format('no %s resource exists for this key', p_locale)
    from referenced r
   where r.k is not null
     and not exists (
       select 1 from erp_ref.resource res
        where res.key = r.k and res.locale = p_locale)
   order by 1, 2
$$;

-- ── 3. The generator, and the installer that runs it ─────────────────────────

create or replace function erp.register_module_governed_views(p_install_code text)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_n      integer;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'governed_view', null);

  insert into erp.governed_view
    (tenant_id, code, name_key, name, description, module_code,
     source_schema, source_name, required_permission, data_classes, lineage_columns)
  select v_tenant, m.code, m.name_key, m.name, m.description, m.module_code,
         m.source_schema, m.source_name, m.required_permission, m.data_classes,
         m.lineage_columns
    from erp_ref.module_governed_view m
   where m.install_code = p_install_code
   order by m.seq
  on conflict (tenant_id, code) do update set
    name_key            = excluded.name_key,
    name                = excluded.name,
    description         = excluded.description,
    module_code         = excluded.module_code,
    source_schema       = excluded.source_schema,
    source_name         = excluded.source_name,
    required_permission = excluded.required_permission,
    data_classes        = excluded.data_classes,
    lineage_columns     = excluded.lineage_columns,
    updated_at          = now();

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function erp.register_module_governed_views is
  'Registers, for this organisation, every reporting view the named module '
  'installer brings — from erp_ref.module_governed_view into erp.governed_view. '
  'Idempotent: a re-install refreshes the registration. Returns how many rows '
  'were written.';

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

  perform erp.submit_change_set(v_cs);

  -- The module's reporting views, registered now rather than promoted later.
  -- A view is a boundary, not a behaviour: §19.1 puts the scoping in the view
  -- so a report cannot forget it, and a boundary is the product's to ship. It
  -- is registered whether or not the change set below is ever promoted,
  -- because the pack planner holds back any report whose view is absent, and a
  -- module installed but awaiting approval should not hide its reports.
  perform erp.register_module_governed_views(p_code);

  -- Submitted and deliberately not approved, once the tenant is live. B6
  -- refuses to let the author of a change set wave it through, and installing
  -- a module is exactly the kind of change that control exists for: these
  -- change sets set the thresholds above which a purchase needs finance and an
  -- order needs credit release.
  --
  -- Before go-live there is no second person for the control to find, and
  -- refusing here made a self-service tenant unconfigurable — which is a
  -- strange end for a product whose claim is that behaviour is configured.
  -- So during the window "install" means installed.
  if not erp.tenant_is_live() then
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
  end if;

  return v_cs;
end;
$$;

comment on function erp.install_module_config is
  'Authors a module''s lifecycle configuration as one B6 change set. Before a '
  'tenant declares itself live the set is approved and promoted in the same '
  'call, because there is nobody else to approve it; afterwards it is left '
  'submitted for a second administrator, which is the control the product '
  'wants once there is a product to control. The module''s reporting views '
  'are registered either way, because a view is the product''s boundary rather '
  'than the organisation''s behaviour.';

-- Backfill: every organisation that has already installed a module holds a
-- change set under that module's install code, whatever became of it. Give
-- each the views its modules bring. A no-op on a fresh build, where there are
-- no organisations; on live this is the statement to run forward-only.
insert into erp.governed_view
  (tenant_id, code, name_key, name, description, module_code,
   source_schema, source_name, required_permission, data_classes, lineage_columns)
select distinct on (cs.tenant_id, m.code)
       cs.tenant_id, m.code, m.name_key, m.name, m.description, m.module_code,
       m.source_schema, m.source_name, m.required_permission, m.data_classes,
       m.lineage_columns
  from erp.change_set cs
  join erp_ref.module_governed_view m on m.install_code = cs.code
  join erp.tenant t on t.id = cs.tenant_id
   and t.status not in ('deleting', 'deleted')
 order by cs.tenant_id, m.code
on conflict (tenant_id, code) do nothing;

-- ── 4. The gate: a report whose view is not installed is early, not missing ─

create or replace function erp.plan_content_pack(p_pack_code text)
returns table (object_kind text, object_key text, operation erp.change_operation,
               payload jsonb, effect text, is_decision boolean, seq integer)
language sql
stable
set search_path = ''
as $$
  with item as (
    select pi.*,
           case when pi.is_decision and d.answer is not null
                then pi.payload || d.answer
                else pi.payload end as effective_payload
      from erp_ref.pack_item pi
      left join erp.pack_decision d
        on d.tenant_id = erp.require_tenant_id()
       and d.pack_code = pi.pack_code
       and d.object_kind = pi.object_kind
       and d.object_key = pi.object_key
     where pi.pack_code = p_pack_code
       and (pi.requires_capability is null
            or erp.capability_enabled(pi.requires_capability))
       -- A report reads a governed view, and the view comes with a module
       -- installer, not with the pack. Until that module is installed the
       -- report is held back — the same additive rule as a capability that
       -- is off — and erp.pack_conflicts() says which module brings it.
       and (pi.object_kind <> 'report'
            or pi.payload -> 'version' ->> 'view' is null
            or exists (
              select 1 from erp.governed_view gv
               where gv.tenant_id = erp.require_tenant_id()
                 and gv.code = pi.payload -> 'version' ->> 'view'))
  ),
  -- What a pack it already applied gave this organisation. Needed because
  -- three of the eleven pack-installable kinds — uom, location, account — are
  -- deliberately absent from erp.configuration_manifest(): they are master
  -- data, and putting them in the manifest would put them in every rollback
  -- snapshot, which would make undoing a configuration change undo a
  -- warehouse's bins.
  already as (
    select csi.object_kind, csi.object_key, csi.payload
      from erp.change_set_item csi
      join erp.tenant_pack tp
        on tp.tenant_id = csi.tenant_id and tp.change_set_id = csi.change_set_id
     where csi.tenant_id = erp.require_tenant_id()
       and tp.status = 'applied'
  )
  select i.object_kind, i.object_key, i.operation, i.effective_payload,
         case when m.object_key is null then 'creates' else 'updates' end,
         i.is_decision, i.seq
    from item i
    left join erp.configuration_manifest() m
      on m.object_kind = i.object_kind and m.object_key = i.object_key
   -- §11.7: "the change set contains only what is missing". Containment, not
   -- equality: a pack payload is a subset of what the manifest emits, so
   -- comparing hashes would mark everything missing for ever.
   -- coalesced, not bare: m.content is NULL when the organisation holds
   -- nothing of that kind, NULL @> anything is NULL, and `not NULL` is NULL —
   -- so the first version of this line silently planned nothing at all for a
   -- brand new organisation, which is the one case that matters most.
   where not (coalesce(m.content, '{}'::jsonb) @> i.effective_payload)
     and not exists (
       select 1 from already a
        where a.object_kind = i.object_kind and a.object_key = i.object_key
          and a.payload = i.effective_payload)
   order by i.seq, i.object_kind, i.object_key
$$;

comment on function erp.plan_content_pack is
  'What applying this pack would add to this organisation, and nothing it '
  'already holds — by containment against the configuration manifest, and by '
  'the pack history for the master-data kinds the manifest deliberately omits. '
  'Capability-gated items are left out when their capability is off; a report '
  'is left out until the module that brings the view it reads is installed; a '
  'decision that has been answered carries the answer.';

create or replace function erp.pack_conflicts(p_pack_code text)
 RETURNS TABLE(severity text, conflict text, reference text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if not exists (select 1 from erp_ref.content_pack where code = p_pack_code) then
    raise exception 'ERPWARE_UNKNOWN_PACK: %', p_pack_code using errcode = '23503';
  end if;

  return query
  -- §11.3, first named conflict: "account ranges colliding with a legislation
  -- pack". §8.1 says that where a bound legislation pack defines a statutory
  -- structure, it wins — so a pack account whose code already exists with a
  -- different name is the collision, and the existing row is the winner.
  select 'blocking',
         format('account %s already exists as %L and the pack would call it %L',
                pi.payload ->> 'code', a.name, pi.payload ->> 'name'),
         p_pack_code || ' / ' || pi.object_key
    from erp_ref.pack_item pi
    join erp.account a
      on a.tenant_id = v_tenant and a.code = (pi.payload ->> 'code')
     and a.status = 'active'
   where pi.pack_code = p_pack_code and pi.object_kind = 'account'
     and a.name is distinct from (pi.payload ->> 'name')

  union all

  -- Second: duplicate codes. Two items in one pack claiming the same object
  -- differ only in which lands last, which is not a decision anybody made.
  --
  -- Stated as identical payloads under different keys, not as a shared code.
  -- The first version grouped by object_kind and payload->>'code', and the
  -- base pack refused to apply because of it: reason codes are unique per
  -- CATEGORY, so ORDERED_IN_ERROR exists under both return-to-supplier and
  -- customer return, and WRONG_QUANTITY, CUSTOMER_REQUEST and
  -- SYSTEM_CORRECTION likewise. Four false positives out of four findings. The
  -- object_key already carries the full identity — category|code here,
  -- kind|code for a posting class — and the primary key makes it unique, so
  -- the only duplicate left to find is the same row written twice under two
  -- names.
  select 'blocking',
         format('%s items in this pack write an identical %s payload under '
                'different keys, so all but one are dead',
                count(*), pi.object_kind),
         p_pack_code || ' / ' || string_agg(pi.object_key, ', ' order by pi.object_key)
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
   group by pi.object_kind, pi.payload
  having count(*) > 1

  union all

  -- And the authoring error that would silently break §11.7: an object_key
  -- that does not agree with the code in its own payload. The key is what
  -- erp.plan_content_pack() matches against the manifest, so a key naming one
  -- thing and a payload writing another makes the item permanently missing —
  -- it lands, and the next application plans it again for ever.
  select 'blocking',
         format('%s %s writes code %L, which its own key does not name',
                pi.object_kind, pi.object_key, pi.payload ->> 'code'),
         p_pack_code
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
     and pi.payload ? 'code'
     and position(upper(pi.payload ->> 'code') in upper(pi.object_key)) = 0

  union all

  -- Third: unmet capability dependencies. An item gated on a capability that
  -- is off is skipped rather than blocked — that is §2 working as intended —
  -- but a PACK gated on a capability that is off has nothing to say at all.
  select 'blocking',
         format('this pack needs the %s capability, which is off for this organisation',
                cp.requires_capability),
         p_pack_code
    from erp_ref.content_pack cp
   where cp.code = p_pack_code
     and cp.requires_capability is not null
     and not erp.capability_enabled(cp.requires_capability)

  union all

  -- And advisory: items this organisation will not receive because their own
  -- capability is off. Not a conflict — a consequence — but somebody reading
  -- a diff of forty items when the pack has ninety deserves to know why.
  select 'advisory',
         format('%s item(s) are held back because the %s capability is off',
                count(*), pi.requires_capability),
         p_pack_code
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
     and pi.requires_capability is not null
     and not erp.capability_enabled(pi.requires_capability)
   group by pi.requires_capability

  union all

  -- And the reports this organisation will not receive yet because the view
  -- each reads comes with a module it has not installed. Named per view, with
  -- the module that brings it, so the reader knows what to install rather
  -- than what to wait for. Reports already held back by a capability are not
  -- counted twice.
  select 'advisory',
         format('report(s) %s are held back because the %s view they read '
                'comes with the %s module, which is not installed',
                string_agg(pi.object_key, ', ' order by pi.object_key),
                mgv.code, mgv.install_code),
         p_pack_code
    from erp_ref.pack_item pi
    join erp_ref.module_governed_view mgv
      on mgv.code = pi.payload -> 'version' ->> 'view'
   where pi.pack_code = p_pack_code
     and pi.object_kind = 'report'
     and (pi.requires_capability is null
          or erp.capability_enabled(pi.requires_capability))
     and not exists (
       select 1 from erp.governed_view gv
        where gv.tenant_id = v_tenant and gv.code = mgv.code)
   group by mgv.code, mgv.install_code;
end;
$$;

-- ── 5. The eighteen versions ─────────────────────────────────────────────────
--
-- Each names the view it reads and only columns that view has — the assertion
-- in §6 checks both against pg_attribute, because erp.run_report() does not
-- execute the column list and nothing else would notice a misspelling. Every
-- parameter filters a column of the view and never a scoping one:
-- erp.upsert_report_version() refuses tenant_id, entity_id, site_id and
-- department_id, and §19.1 is why. Permission is the module's read permission;
-- budgets are Part 19's defaults except for the two that read a movement or
-- journal table, which are given room. Formats are always stated, because a
-- version promoted without them gets none rather than the default.

with v(object_key, version) as (values
  ('stock_on_hand', jsonb_build_object(
     'view', 'stock_valuation',
     'columns', '["item_code","item_name","site_id","location_id","batch_id","stock_status","quantity","method","unit_cost_minor","currency","value_minor"]'::jsonb,
     'default_sort', '["site_id","item_code"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'inventory.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"stock_status","data_type":"text","is_required":false,"filters_column":"stock_status"}]'::jsonb)),
  ('stock_movement', jsonb_build_object(
     'view', 'stock_movement',
     'columns', '["movement_uid","occurred_at","movement_type","item_id","batch_id","from_location_id","to_location_id","quantity","uom_id","unit_cost_minor","currency","document_id","reason_code"]'::jsonb,
     'default_sort', '["occurred_at"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'inventory.read',
     'time_budget_ms', 15000, 'row_cap', 50000,
     'parameters', '[{"code":"occurred_from","data_type":"timestamptz","is_required":true,"filters_column":"occurred_at"},{"code":"occurred_to","data_type":"timestamptz","is_required":true,"filters_column":"occurred_at"},{"code":"movement_type","data_type":"text","is_required":false,"filters_column":"movement_type"}]'::jsonb)),
  ('expiry_horizon', jsonb_build_object(
     'view', 'batch',
     'columns', '["batch_number","item_id","status","manufactured_on","expires_on","retest_on","best_before_on","supplier_lot","supplier_party_id"]'::jsonb,
     'default_sort', '["expires_on"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'inventory.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"expires_before","data_type":"date","is_required":true,"filters_column":"expires_on"},{"code":"status","data_type":"text","is_required":false,"filters_column":"status"}]'::jsonb)),
  ('batch_genealogy', jsonb_build_object(
     'view', 'batch_genealogy',
     'columns', '["parent_batch_id","child_batch_id","quantity","uom_id","movement_id","document_id","occurred_at"]'::jsonb,
     'default_sort', '["occurred_at"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'quality.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"parent_batch_id","data_type":"uuid","is_required":false,"filters_column":"parent_batch_id"},{"code":"child_batch_id","data_type":"uuid","is_required":false,"filters_column":"child_batch_id"}]'::jsonb)),
  ('open_order_book', jsonb_build_object(
     'view', 'open_order_book',
     'columns', '["document_number","party_code","party_name","document_date","required_date","state","line_count","net_minor","gross_minor","currency","days_open","is_overdue"]'::jsonb,
     'default_sort', '["required_date","document_number"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'sales.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"required_before","data_type":"date","is_required":false,"filters_column":"required_date"},{"code":"party_code","data_type":"text","is_required":false,"filters_column":"party_code"}]'::jsonb)),
  ('order_fulfilment', jsonb_build_object(
     'view', 'order_fulfilment',
     'columns', '["document_number","party_code","party_name","document_date","required_date","state","ordered_quantity","fulfilled_quantity","invoiced_quantity","fulfilment_pct","line_count","fulfilled_lines","days_late"]'::jsonb,
     'default_sort', '["document_date","document_number"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'sales.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"document_from","data_type":"date","is_required":false,"filters_column":"document_date"},{"code":"document_to","data_type":"date","is_required":false,"filters_column":"document_date"},{"code":"party_code","data_type":"text","is_required":false,"filters_column":"party_code"}]'::jsonb)),
  ('purchase_order_status', jsonb_build_object(
     'view', 'purchase_order_status',
     'columns', '["document_number","party_code","party_name","document_date","required_date","state","ordered_quantity","received_quantity","invoiced_quantity","receipt_pct","line_count","received_lines","days_outstanding"]'::jsonb,
     'default_sort', '["state","document_date"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'procurement.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"document_from","data_type":"date","is_required":false,"filters_column":"document_date"},{"code":"document_to","data_type":"date","is_required":false,"filters_column":"document_date"},{"code":"state","data_type":"text","is_required":false,"filters_column":"state"}]'::jsonb)),
  ('grni', jsonb_build_object(
     'view', 'grni',
     'columns', '["document_number","party_code","party_name","line_no","item_code","description","ordered_quantity","received_quantity","invoiced_quantity","quantity_uninvoiced","uninvoiced_value_minor","currency","document_date","days_outstanding"]'::jsonb,
     'default_sort', '["days_outstanding","document_number"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'finance.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"party_code","data_type":"text","is_required":false,"filters_column":"party_code"}]'::jsonb)),
  ('match_exceptions', jsonb_build_object(
     'view', 'match_exception',
     'columns', '["order_line_id","invoice_document_id","status","ordered_quantity","received_quantity","invoiced_quantity","ordered_price_minor","invoiced_price_minor","quantity_variance","price_variance_minor","resolved_at","resolution"]'::jsonb,
     'default_sort', '["status"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'procurement.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"status","data_type":"text","is_required":false,"filters_column":"status"}]'::jsonb)),
  ('supplier_performance', jsonb_build_object(
     'view', 'supplier_performance',
     'columns', '["party_code","party_name","orders","lines","ordered_quantity","received_quantity","late_lines","fulfilled_lines","first_order_date","last_order_date"]'::jsonb,
     'default_sort', '["party_code"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'procurement.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"party_code","data_type":"text","is_required":false,"filters_column":"party_code"}]'::jsonb)),
  ('planning_exceptions', jsonb_build_object(
     'view', 'planning_exception',
     'columns', '["item_id","exception_kind","severity","message","first_seen_at","last_seen_at","acknowledged_at","resolved_at","resolution"]'::jsonb,
     'default_sort', '["severity","first_seen_at"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'planning.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"severity","data_type":"text","is_required":false,"filters_column":"severity"},{"code":"exception_kind","data_type":"text","is_required":false,"filters_column":"exception_kind"}]'::jsonb)),
  ('production_variance', jsonb_build_object(
     'view', 'works_order',
     'columns', '["order_number","order_kind","item_id","quantity","quantity_completed","quantity_scrapped","uom_id","planned_start","planned_end","actual_start","actual_end","status","standard_cost_minor","actual_cost_minor"]'::jsonb,
     'default_sort', '["planned_start","order_number"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'production.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"planned_from","data_type":"date","is_required":false,"filters_column":"planned_start"},{"code":"planned_to","data_type":"date","is_required":false,"filters_column":"planned_start"},{"code":"status","data_type":"text","is_required":false,"filters_column":"status"}]'::jsonb)),
  ('count_accuracy', jsonb_build_object(
     'view', 'count_task',
     'columns', '["count_programme_id","location_id","item_id","batch_id","expected_quantity","counted_quantity","variance","within_tolerance","status","counted_at","posted_at"]'::jsonb,
     'default_sort', '["count_programme_id","location_id"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'inventory.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"count_programme_id","data_type":"uuid","is_required":false,"filters_column":"count_programme_id"}]'::jsonb)),
  ('quality_events', jsonb_build_object(
     'view', 'quality_event',
     'columns', '["reference","event_kind","severity","title","item_id","batch_id","party_id","occurred_at","detected_at","root_cause","due_at","closed_at","status"]'::jsonb,
     'default_sort', '["status","occurred_at"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'quality.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"status","data_type":"text","is_required":false,"filters_column":"status"},{"code":"event_kind","data_type":"text","is_required":false,"filters_column":"event_kind"},{"code":"occurred_from","data_type":"timestamptz","is_required":false,"filters_column":"occurred_at"},{"code":"occurred_to","data_type":"timestamptz","is_required":false,"filters_column":"occurred_at"}]'::jsonb)),
  ('recall_despatch_list', jsonb_build_object(
     'view', 'recall_impact',
     'columns', '["recall_id","captured_at","batch_id","item_id","party_id","quantity_despatched","uom_id","despatched_at","document_id"]'::jsonb,
     'default_sort', '["despatched_at"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'quality.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"recall_id","data_type":"uuid","is_required":true,"filters_column":"recall_id"}]'::jsonb)),
  ('trial_balance', jsonb_build_object(
     'view', 'account_balance',
     'columns', '["ledger_id","account_id","account_code","account_type","currency","fiscal_period_id","debit_minor","credit_minor","balance_minor"]'::jsonb,
     'default_sort', '["ledger_id","account_code"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'finance.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"fiscal_period_id","data_type":"uuid","is_required":true,"filters_column":"fiscal_period_id"}]'::jsonb)),
  ('dimensional_pl', jsonb_build_object(
     'view', 'journal_line',
     'columns', '["journal_id","line_no","account_id","debit_minor","credit_minor","currency","base_debit_minor","base_credit_minor","dimensions","description"]'::jsonb,
     'default_sort', '["journal_id","line_no"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'finance.read',
     'time_budget_ms', 15000, 'row_cap', 50000,
     'parameters', '[{"code":"account_id","data_type":"uuid","is_required":false,"filters_column":"account_id"}]'::jsonb)),
  ('ageing', jsonb_build_object(
     'view', 'ageing',
     'columns', '["document_number","document_type","direction","party_code","party_name","document_date","due_date","currency","gross_minor","signed_minor","days_overdue","bucket"]'::jsonb,
     'default_sort', '["direction","days_overdue"]'::jsonb,
     'output_formats', '["csv","pdf"]'::jsonb,
     'required_permission', 'finance.read',
     'time_budget_ms', 5000, 'row_cap', 10000,
     'parameters', '[{"code":"direction","data_type":"text","is_required":false,"filters_column":"direction"},{"code":"party_code","data_type":"text","is_required":false,"filters_column":"party_code"}]'::jsonb))
)
update erp_ref.pack_item pi
   set payload = pi.payload || jsonb_build_object('version', v.version)
  from v
 where pi.pack_code = 'base'
   and pi.object_kind = 'report'
   and pi.object_key = v.object_key;

-- ── 6. The build guard ───────────────────────────────────────────────────────

create or replace function erp.pack_report_version_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with rep as (
    select pi.pack_code, pi.object_key,
           pi.pack_code || ' / ' || pi.object_key as ref,
           pi.payload ? 'version' as has_version,
           pi.payload -> 'version' as v
      from erp_ref.pack_item pi
     where pi.object_kind = 'report'
  ),
  shipped as (
    select m.*,
           m.install_code || ' / ' || m.code as ref,
           pg_catalog.to_regclass(format('%I.%I', m.source_schema, m.source_name)) as rel
      from erp_ref.module_governed_view m
  ),
  -- Every column a version names, by the role it names it in.
  named as (
    select r.ref, r.v ->> 'view' as view_code, x.col, x.role
      from rep r
      cross join lateral (
        select value as col, 'columns' as role
          from pg_catalog.jsonb_array_elements_text(
                 case when pg_catalog.jsonb_typeof(r.v -> 'columns') = 'array'
                      then r.v -> 'columns' else '[]'::jsonb end)
        union all
        select value, 'group_by'
          from pg_catalog.jsonb_array_elements_text(
                 case when pg_catalog.jsonb_typeof(r.v -> 'group_by') = 'array'
                      then r.v -> 'group_by' else '[]'::jsonb end)
        union all
        select value, 'default_sort'
          from pg_catalog.jsonb_array_elements_text(
                 case when pg_catalog.jsonb_typeof(r.v -> 'default_sort') = 'array'
                      then r.v -> 'default_sort' else '[]'::jsonb end)
      ) x
     where r.has_version
  ),
  param as (
    select r.ref, r.v ->> 'view' as view_code, p.value as p
      from rep r
      cross join lateral pg_catalog.jsonb_array_elements(
        case when pg_catalog.jsonb_typeof(r.v -> 'parameters') = 'array'
             then r.v -> 'parameters' else '[]'::jsonb end) p
     where r.has_version
  )
  -- The finding this migration exists for.
  select 'a pack report has no version', r.ref,
         'promoting it fails erp.assert_reports_reproducible() in the receiving organisation'
    from rep r
   where not r.has_version
  union all
  select 'a pack report reads a view the product does not ship', r.ref,
         format('view %L is not in erp_ref.module_governed_view', r.v ->> 'view')
    from rep r
   where r.has_version
     and not exists (select 1 from erp_ref.module_governed_view m
                      where m.code = r.v ->> 'view')
  union all
  select 'a pack report declares no columns', r.ref,
         'erp.upsert_report_version() refuses a version with no columns'
    from rep r
   where r.has_version
     and (case when pg_catalog.jsonb_typeof(r.v -> 'columns') = 'array'
               then pg_catalog.jsonb_array_length(r.v -> 'columns') else 0 end) = 0
  union all
  -- The runner does not execute the column list, so this is the only place a
  -- misspelling is caught.
  select 'a pack report names a column its view does not have', n.ref,
         format('%s %s on %s.%s', n.role, n.col, s.source_schema, s.source_name)
    from named n
    join shipped s on s.code = n.view_code
   where s.rel is not null
     and not exists (
       select 1 from pg_catalog.pg_attribute a
        where a.attrelid = s.rel and a.attname = n.col
          and a.attnum > 0 and not a.attisdropped)
  union all
  select 'a pack report parameter filters a column its view does not have', p.ref,
         format('%s filters %s on %s.%s', p.p ->> 'code', p.p ->> 'filters_column',
                s.source_schema, s.source_name)
    from param p
    join shipped s on s.code = p.view_code
   where s.rel is not null
     and not exists (
       select 1 from pg_catalog.pg_attribute a
        where a.attrelid = s.rel and a.attname = p.p ->> 'filters_column'
          and a.attnum > 0 and not a.attisdropped)
  union all
  -- §19.1, checked in the content rather than left to the promoter's refusal.
  select 'a pack report parameter filters a scoping column', p.ref,
         format('%s filters %s', p.p ->> 'code', p.p ->> 'filters_column')
    from param p
   where p.p ->> 'filters_column' in ('tenant_id', 'entity_id', 'site_id', 'department_id')
  union all
  select 'a pack report parameter has an unknown data type', p.ref,
         format('%s is %L', p.p ->> 'code', p.p ->> 'data_type')
    from param p
   where coalesce(p.p ->> 'data_type', '')
         not in ('text', 'integer', 'numeric', 'date', 'timestamptz', 'boolean', 'uuid')
  union all
  select 'a pack report requires a permission that does not exist', r.ref,
         format('%L', r.v ->> 'required_permission')
    from rep r
   where r.has_version
     and not exists (select 1 from erp_ref.permission pm
                      where pm.code = r.v ->> 'required_permission')
  union all
  -- The promoter passes what the payload carries, and an absent array lands
  -- as no formats at all rather than the column default.
  select 'a pack report does not supply output formats', r.ref,
         'a version promoted without them can be run in no format'
    from rep r
   where r.has_version
     and (case when pg_catalog.jsonb_typeof(r.v -> 'output_formats') = 'array'
               then pg_catalog.jsonb_array_length(r.v -> 'output_formats') else 0 end) = 0
  union all
  -- And the register itself, held to what erp.check_governed_view_source()
  -- and erp.governed_view_safety_report() would say once a row reaches an
  -- organisation — said here, at build time, before one does.
  select 'a shipped view reads a relation that does not exist', s.ref,
         format('%s.%s', s.source_schema, s.source_name)
    from shipped s
   where s.rel is null
  union all
  select 'a shipped view declares a lineage column its source does not have', s.ref,
         format('%s on %s.%s', lc, s.source_schema, s.source_name)
    from shipped s
    cross join lateral pg_catalog.unnest(s.lineage_columns) lc
   where s.rel is not null
     and not exists (
       select 1 from pg_catalog.pg_attribute a
        where a.attrelid = s.rel and a.attname = lc
          and a.attnum > 0 and not a.attisdropped)
  union all
  select 'a shipped view reads a view that is not security_invoker', s.ref,
         'it would run as its owner, who bypasses row-level security'
    from shipped s
    join pg_catalog.pg_class c on c.oid = s.rel
   where c.relkind = 'v'
     and coalesce(
           (select option_value = 'true'
              from pg_catalog.pg_options_to_table(c.reloptions)
             where option_name = 'security_invoker'), false) = false
  union all
  select 'a shipped view reads a table with row-level security disabled', s.ref,
         'reporting through it would not be tenant-scoped'
    from shipped s
    join pg_catalog.pg_class c on c.oid = s.rel
   where c.relkind in ('r', 'p')
     and not c.relrowsecurity
  union all
  -- A row keyed by an install code no erp.configure_* function uses is a view
  -- nothing will ever register, and a report reading it is held back for ever.
  select 'a shipped view belongs to a module no installer installs', s.ref,
         format('no erp.configure_* function installs %L', s.install_code)
    from shipped s
   where not exists (
     select 1 from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'erp'
        and p.proname like 'configure\_%'
        and p.prosrc ~ ('install_module_config\(\s*''' || s.install_code || ''''))
$$;

comment on function erp.pack_report_version_report is
  'Findings against the pack reports and the register of views they read: a '
  'report with no version, a column or parameter its view does not have, a '
  'parameter that would widen scope, a view the product does not ship, and a '
  'shipped view that no installer brings or that would leak. Empty on a sound '
  'build.';

create or replace function erp.assert_pack_report_versions_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count   integer;
  v_detail  text;
  v_reports integer;
  v_views   integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.pack_report_version_report();

  if v_count > 0 then
    raise exception 'ERPWARE_PACK_REPORT_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  select count(*) into v_reports from erp_ref.pack_item where object_kind = 'report';
  select count(*) into v_views from erp_ref.module_governed_view;
  return format('pack reports: %s versioned over %s shipped views', v_reports, v_views);
end;
$$;

comment on function erp.assert_pack_report_versions_sound is
  'Fails the build when erp.pack_report_version_report() has anything to say. '
  'The guard that keeps a pack report from reaching an organisation without a '
  'version, or with one that names what its view does not have.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('pack_report_versions', 'Pack report versions sound', 'assertion', 'platform',
   'erp', 'assert_pack_report_versions_sound', '',
   'pack_report_version_report', '',
   'Every report a pack ships carries a version — the view it reads, columns '
   'that view has, parameters that cannot widen scope, a permission that '
   'exists — and every view the product ships for reporting is brought by a '
   'module installer and scopes by row-level security.',
   true, 61)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- ── 7. The acceptance suite, re-measured ─────────────────────────────────────
--
-- The hold-back changes what the suite counts, and the suite now does what the
-- task asked: installs the four modules whose views the base pack's last four
-- reports read, re-applies the pack, and asks erp.assert_reports_reproducible()
-- of the organisation it built — the assertion nothing had asked after a pack
-- install, which is how the gap stayed open.

CREATE OR REPLACE FUNCTION erp_test.starter_pack_acceptance_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  a1 uuid := gen_random_uuid();   -- the author
  a2 uuid := gen_random_uuid();   -- the approver, because B6 refuses self-approval
  r         record;
  c         record;
  res       jsonb;
  v_cs      uuid;
  v_tok     text;
  v_second  uuid;
  d         record;
  i         integer := 0;
  n         integer;
  n2        integer;
  v_ok      boolean; v_msg text;
  v_ready   integer;
begin
  select * into r from erp.provision_tenant(
    'zz13', 'Acceptance', 'admin@zz13.test', 'Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zz13.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- The modules. Installing one is not "further configuration" in §13's sense
  -- — it is what gives the product a procurement flow to configure at all —
  -- and the pack presupposes them: a requisition lifecycle comes from
  -- erp.configure_procurement(), not from erp_ref.pack_item.
  perform erp.configure_finance();
  perform erp.configure_procurement(1000000);
  perform erp.configure_sales();
  perform erp.configure_inventory();
  perform erp.configure_quality();
  perform erp.configure_logistics();
  perform erp.configure_period_close();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
    perform erp.approve_change_set(c.id);
    perform erp.promote_change_set(c.id);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- Installing a module registers the reporting views it brings, whether or
  -- not its change set is promoted — a view is the product's boundary, not the
  -- organisation's behaviour. Seven modules, fourteen views.
  select count(*) into n from erp.governed_view gv where gv.tenant_id = r.tenant_id;
  return query select 'installing a module registers the reporting views it brings',
    n = (select count(*) from erp_ref.module_governed_view m
          where m.install_code in ('finance-posting', 'procurement-lifecycle',
                                   'sales-lifecycle', 'inventory-operations',
                                   'quality', 'logistics', 'period-close')),
    format('%s views registered by seven installers', n);

  -- ── §2.1's route ────────────────────────────────────────────────────────

  res := erp.apply_preset('standard');
  return query select 'a live organisation switches capabilities through a change set',
    (res ->> 'route') = 'change_set' and (res ->> 'change_set_id') is not null,
    'erp.provision_tenant() marks the self environment live immediately, so '
    'the promotable-surface guard bites from the first day — and before this '
    'there was no promotion route to take instead, which left every '
    'organisation able to read the capability catalogue and none able to '
    'change it';

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) into n from erp.tenant_capability tc
   where tc.tenant_id = r.tenant_id and tc.is_enabled and tc.valid_to is null;
  return query select 'and promoting it switches on what the preset selects',
    n = 9, format('%s capabilities on after the Standard preset', n);

  -- ── §11, applied ────────────────────────────────────────────────────────

  res := erp.apply_content_pack('base');
  v_cs := (res ->> 'change_set_id')::uuid;
  return query select 'the base pack plans only what the capabilities allow',
    -- 340. It was 322 when §13's clause 5 was written, 326 after
    -- 20260904100000 added §9.1's four remaining scheduled jobs, 342 after
    -- 20260904170000 added §9.3's sixteen output templates, and 340 now that
    -- 20260904430000 holds back the two reports — match exceptions and
    -- ageing — whose views come with modules this organisation has not yet
    -- installed. The number is hardcoded on purpose — it is what makes a pack
    -- that grows by accident fail the build — so each deliberate growth
    -- updates it and says what moved it.
    (res ->> 'items')::integer = 340
      and jsonb_array_length(res -> 'advisories') = 8,
    format('%s of %s items, %s advisories naming the capabilities and modules that held the rest back',
           res ->> 'items',
           (select count(*) from erp_ref.pack_item where pack_code = 'base'),
           jsonb_array_length(res -> 'advisories'));

  -- The two advisories that are new: each names the report, the view and the
  -- module that brings it, so the reader knows what to install.
  return query select 'a report whose view is not installed is held back and named',
    -- The advisories are the conflict strings themselves, not objects.
    exists (select 1 from jsonb_array_elements_text(res -> 'advisories') a
             where a like 'report(s) match_exceptions are held back%'
               and a like '%procurement-controls module%')
    and exists (select 1 from jsonb_array_elements_text(res -> 'advisories') a
             where a like 'report(s) ageing are held back%'
               and a like '%receivables module%'),
    '§11.7: not missing, early — the same additive rule as a capability off';

  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'a pack promoted with twelve decisions unanswered';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_DECISIONS_OUTSTANDING%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'promotion refuses while a required decision remains', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  for d in select * from erp.pack_decisions('base') where not answered loop
    i := i + 1;
    perform erp.answer_pack_decision('base', d.object_kind, d.object_key,
      jsonb_build_object('upper_bound_minor', i * 500000));
  end loop;
  return query select 'and §3.4''s twelve approval bands are all of them',
    i = 12, format('%s decisions, every one an approval threshold', i);

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'the answer lands, not the pack''s placeholder',
    (select ab.upper_bound_minor from erp.approval_band ab
      join erp.department dp on dp.id = ab.department_id
     where ab.tenant_id = r.tenant_id and dp.code = 'PROC'
       and ab.object_type = 'requisition' and ab.seq = 1) is not null,
    'a band whose threshold is still null is a chain that approves everything';

  -- The gap this migration closes: every report the pack landed carries a
  -- version in force, reading a view the organisation holds.
  select count(*), count(*) filter (where exists (
           select 1 from erp.report_version rv
            where rv.tenant_id = rp.tenant_id and rv.report_id = rp.id
              and rv.status = 'active' and rv.effective_from <= current_date
              and (rv.effective_to is null or rv.effective_to > current_date)))
    into n, n2
    from erp.report rp where rp.tenant_id = r.tenant_id;
  return query select 'every report the pack landed has a version in force',
    -- 13: eighteen, less the three whose capability the Standard preset leaves
    -- off (planning exceptions, production variance, recall despatch list)
    -- and the two whose view waits for a module (match exceptions, ageing).
    n = 13 and n2 = n,
    format('%s reports, %s with a version — the thirteen the Standard preset '
           'and seven modules allow', n, n2);

  -- ── §13's seven clauses ─────────────────────────────────────────────────

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'four of §13''s seven clauses hold after Standard and the base pack',
    v_ready = 4,
    format('%s of 7 ready with nothing configured by hand', v_ready);

  return query select 'clauses 1, 2, 4 and 7 are the four',
    (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
      where clause in (1, 2, 4, 7)),
    'requisition to invoice; determination with no suspense fallback; count '
    'and variance; period close';

  -- The two clauses §13 describes after "having chosen the Standard preset"
  -- and §2.3 puts in Full. Settled as: §13 means Full. The report says which
  -- preset each clause needs, derived from erp_ref.preset_capability, so
  -- neither document had to be rewritten and neither is quoted at the reader.
  return query select 'clause 3 needs Full, and says so rather than reading as a fault',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 3) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 3)
      = 'Container identity is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 3), 'nothing missing');

  return query select 'clause 6 needs Full for the same reason, and nothing else',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 6) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 6)
      = 'Recall management is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 6), 'nothing missing');

  -- The invariant the whole change is for: nothing a preset can switch on is
  -- ever reported as something the pack failed to provide. §13's last sentence
  -- logs a pack gap against the product, and a preset nobody chose is not one.
  return query select 'no clause blames the pack for a capability a preset carries',
    not exists (
      select 1 from erp.pack_acceptance_report(r.tenant_id) ar
       where ar.missing is not null
         and ar.missing like '%is off%'
         and ar.missing not like '%preset)%'),
    'before this, two clauses answered a reader with a paragraph about §2.3 '
    'disagreeing with §13';

  return query select 'clause 5''s gap is a site''s, not the pack''s',
    (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 5)
      = 'no marshalling area configured for any site; ',
    'a marshalling area belongs to a site, and a site is an organisation''s own '
    '— §11 lists none in a pack for the same reason';

  -- ── The Full preset closes both, which is what names the cause ──────────

  res := erp.apply_preset('full');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.apply_content_pack('base');
  return query select 're-applying the base pack plans exactly what was held back',
    -- 11, not 13: planning exceptions and production variance now wait for
    -- the planning and production modules, whose views they read.
    (res ->> 'items')::integer = 11,
    format('%s items — §11.7''s "a tenant that skipped manufacturing at '
           'onboarding can add it later, and the change set contains only what '
           'is missing"', res ->> 'items');

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'the Full preset closes clauses 3 and 6 and nothing else changes',
    v_ready = 6
      and (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
            where clause in (3, 6)),
    format('%s of 7 ready; only clause 5 remains, and it wants a site', v_ready);

  return query select 'and a third application plans nothing at all',
    (select count(*) from erp.plan_content_pack('base')) = 0,
    'additive, per §11.7';

  -- ── The last four reports arrive with the modules that bring their views ─

  perform erp.configure_receivables();
  perform erp.configure_procurement_controls();
  perform erp.configure_planning();
  perform erp.configure_production();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
    perform erp.approve_change_set(c.id);
    perform erp.promote_change_set(c.id);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.apply_content_pack('base');
  return query select 'installing the modules that bring the views plans exactly the reports held back',
    (res ->> 'items')::integer = 4
      and (select string_agg(csi.object_key, ',' order by csi.object_key)
             from erp.change_set_item csi
            where csi.change_set_id = (res ->> 'change_set_id')::uuid)
          = 'ageing,match_exceptions,planning_exceptions,production_variance',
    format('%s items: %s', res ->> 'items',
           (select string_agg(csi.object_key, ', ' order by csi.object_key)
              from erp.change_set_item csi
             where csi.change_set_id = (res ->> 'change_set_id')::uuid));

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*), count(*) filter (where (
           select count(*) from erp.report_version rv
            where rv.tenant_id = rp.tenant_id and rv.report_id = rp.id
              and rv.status = 'active' and rv.effective_from <= current_date
              and (rv.effective_to is null or rv.effective_to > current_date)) = 1)
    into n, n2
    from erp.report rp where rp.tenant_id = r.tenant_id;
  return query select 'all eighteen base reports now hold exactly one version in force',
    n = 18 and n2 = 18,
    format('%s reports, %s with exactly one version in force', n, n2);

  -- The assertion this whole change is for, asked of the organisation the
  -- suite built. Before 20260904430000 it failed here with eighteen findings.
  begin
    perform erp.assert_reports_reproducible();
    v_ok := true; v_msg := 'erp.assert_reports_reproducible() passes over the pack-installed reports';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  return query select 'and the organisation''s reports are reproducible', v_ok, v_msg;

  -- ── §10, over the base ──────────────────────────────────────────────────

  begin
    perform erp.apply_content_pack('outsourced_logistics');
    v_ok := false; v_msg := 'a profile pack applied with its capability off';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_CONFLICT%'
        and sqlerrm like '%third_party_custody%';
    v_msg := left(sqlerrm, 58);
  end;
  return query select 'a profile pack whose capability is off is refused by name',
    v_ok, v_msg;

  res := erp.apply_content_pack('manufacturing');
  return query select 'and one whose capability is on applies over the base',
    -- 12, not 13: erp.configure_production() above already set
    -- production.issue_method to the value the pack carries, and §11.7 plans
    -- only what is missing.
    (res ->> 'items')::integer = 12, format('%s items', res ->> 'items');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select '§10''s five works order types all land',
    (select count(*) from erp.classification_value cv
       join erp.classification_axis ca on ca.id = cv.axis_id
      where cv.tenant_id = r.tenant_id and ca.code = 'WORKS_ORDER_TYPE'
        and cv.status = 'active') = 5,
    'production, assembly, kitting, rework, repack';

  return query select '§11.6: the organisation records which packs it holds, and at which version',
    (select count(*) from erp.tenant_pack tp
      where tp.tenant_id = r.tenant_id and tp.status = 'applied') = 4
    and (select bool_and(tp.version = '1.0.0') from erp.tenant_pack tp
          where tp.tenant_id = r.tenant_id and tp.status = 'applied'),
    'base three times and manufacturing once, each with its version';

  -- ── §12, checkable rather than trusted ──────────────────────────────────

  return query select 'every pack value states where it came from',
    not exists (select 1 from erp_ref.pack_item where length(provenance) <= 20)
    and not exists (select 1 from erp_ref.content_pack where length(provenance) <= 30),
    '§12: "every value carries a provenance note naming the standard or '
    'practice it derives from, so the review is checkable rather than trusted"';

  -- Cleanup, so the next suite starts from the schema rather than from this.
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'a suite that leaves an organisation makes the next one measure this one';
end;
$function$;

CREATE OR REPLACE FUNCTION erp_test.assert_starter_pack_acceptance()
 RETURNS text LANGUAGE plpgsql SET search_path TO '' AS $function$
declare
  v_pass integer; v_total integer; v_detail text;
  -- 27, not 21: 20260904430000 added the six cases that follow a report from
  -- the view its module registers to erp.assert_reports_reproducible() passing
  -- over the organisation the suite built.
  c_expected constant integer := 27;
begin
  create temporary table if not exists zz_acceptance_result (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_acceptance_result;
  insert into zz_acceptance_result select * from erp_test.starter_pack_acceptance_suite();
  select count(*) filter (where passed), count(*), string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_acceptance_result;
  if v_total <> c_expected then raise exception 'ERPWARE_ACCEPTANCE_SUITE_INCOMPLETE: % cases, expected %', v_total, c_expected using errcode = 'P0001'; end if;
  if v_pass < v_total then raise exception E'ERPWARE_ACCEPTANCE_SUITE_FAILED: %/%\n%', v_pass, v_total, v_detail using errcode = 'P0001'; end if;
  return format('starter pack acceptance: %s/%s', v_pass, v_total);
end $function$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_configuration_promotable();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_reports_reproducible();
select erp.assert_governed_views_are_safe();
select erp.assert_packs_installable();
select erp.assert_diagnostics_registered();
select erp.assert_product_decisions_enforced();
select erp.assert_pack_report_versions_sound();
select erp_test.assert_starter_pack_acceptance();
