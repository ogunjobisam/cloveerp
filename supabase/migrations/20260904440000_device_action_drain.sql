-- =============================================================================
-- Part 14: the queue is drained
--
-- The open decision device_action_queue_is_not_drained said, honestly, that
-- erp.device_action rows were recorded and read back and that no function ever
-- moved one to applied or conflicted. §14.5's "never posts silently or silently
-- disappears" held by never posting at all.
--
-- Its rationale was that draining means deciding, for each of the twenty-two
-- tasks in erp_ref.device_task, which module function performs the work and
-- what makes an action no longer valid — per-module design, not plumbing, and
-- a single generic applier would be wrong for most of them. That is right, and
-- it is why the answer is a register rather than a CASE:
--
--   erp_ref.device_task_handler names, for every task, the erp function that
--   applies it and how the action's payload maps onto that function's
--   arguments — or says, in a sentence, why nothing applies it yet. A task
--   with neither is a build failure.
--
--   erp.drain_device_actions() walks the queue in the order the actions were
--   captured and calls the function the register names. The module function
--   decides what "no longer valid" means — a putaway task already done, a
--   count task not open, an allocation not reserved — and its refusal becomes
--   the conflict reason the operator sees. Nothing here second-guesses a
--   module about its own objects.
--
-- Two things the drain will not do, and both are §14.6:
--
--   An action captured with no session open is never applied. The session is
--   what attributes an action to a person, and applying it anyway would post
--   stock movements to the device.
--
--   An action is applied only by the operator whose session captured it. A
--   queue drained by somebody else holds their actions until they reconnect,
--   because the module functions attribute to whoever calls them and
--   "attributes to the user who performed it" is not satisfied by a supervisor
--   pressing a button.
--
-- Seventeen tasks apply through a module function. One, stock enquiry, writes
-- nothing by §14.3's own definition. Four — goods-in booking, handling unit
-- build, short pick and pack — have no function yet, and the register says so
-- in words; an action for one of them conflicts with that sentence rather than
-- waiting silently in a queue nothing reads.
-- =============================================================================

-- ── What an applied action leaves behind ───────────────────────────────────

alter table erp.device_action add column if not exists applied_result text;

-- ── What the suite for this found on its way out ────────────────────────────
--
-- erp.warehouse_task was the one tenant-scoped table with no foreign key to
-- erp.tenant at all: it referenced site, location, item and batch, none of
-- them cascading, and nothing tied it to the organisation. Deleting a tenant
-- that had ever raised a putaway task failed on the site's foreign key — which
-- is to say Tenancy Part 1's "a deletion that deletes" did not, for any
-- organisation that had used the warehouse. Found because the drain suite is
-- the first to raise a putaway task and then delete the organisation it built.
-- Fixed here, and erp.isolation_report() below now fails the build on the
-- next table that does the same.

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint k
     where k.conrelid = 'erp.warehouse_task'::regclass
       and k.contype = 'f' and k.confrelid = 'erp.tenant'::regclass) then
    alter table erp.warehouse_task
      add constraint warehouse_task_tenant_id_fkey
      foreign key (tenant_id) references erp.tenant(id) on delete cascade;
  end if;
end $$;

create or replace function erp.isolation_report()
returns table(schema_name text, table_name text, table_class text, finding text)
language sql
stable
set search_path = ''
as $$
  with t as (
    select c.oid,
           c.relnamespace::regnamespace::text as schema_name,
           c.relname as table_name,
           c.relrowsecurity,
           c.relforcerowsecurity,
           tp.table_class,
           exists (
             select 1 from pg_catalog.pg_attribute a
              where a.attrelid = c.oid and a.attname = 'tenant_id'
                and a.attnum > 0 and not a.attisdropped
           ) as has_tenant_id,
           exists (
             select 1 from pg_catalog.pg_constraint k
              where k.conrelid = c.oid and k.contype = 'f'
                and k.confrelid = 'erp.tenant'::regclass
                and k.confdeltype = 'c'
           ) as cascades_from_tenant
      from pg_catalog.pg_class c
      left join erp_meta.table_policy tp
        on tp.schema_name = c.relnamespace::regnamespace::text
       and tp.table_name = c.relname
     where c.relkind = 'r'
       and c.relnamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
  ),
  table_findings as (
    select t.schema_name, t.table_name,
           coalesce(t.table_class::text, '(unregistered)') as table_class,
           f.finding
      from t
      cross join lateral (
        select unnest(array_remove(array[
          case when t.table_class is null
               then 'table is not registered in erp_meta.table_policy' end,
          case when not t.relrowsecurity
               then 'row level security is not enabled' end,
          case when not t.relforcerowsecurity
               then 'row level security is not forced, so the table owner bypasses it' end,
          case when t.schema_name = 'erp'
                and t.table_class in ('tenant_scoped', 'tenant_scoped_append_only')
                and not t.has_tenant_id
               then 'tenant-scoped table has no tenant_id column' end,
          -- Tenancy Part 1: a deletion that deletes. A tenant-scoped table
          -- whose rows do not go with the organisation is one the purge
          -- trips over, and the organisation is then neither deleted nor
          -- restorable.
          case when t.schema_name = 'erp'
                and t.table_class in ('tenant_scoped', 'tenant_scoped_append_only')
                and t.has_tenant_id
                and not t.cascades_from_tenant
               then 'tenant-scoped table does not cascade from erp.tenant, so deleting '
                    'the organisation would fail on it' end,
          case when t.schema_name = 'erp'
                and t.has_tenant_id
                and t.table_class not in ('tenant_scoped', 'tenant_scoped_append_only')
               then 'table carries tenant_id but is not classified as tenant-scoped' end,
          case when t.schema_name = 'erp'
                and not t.has_tenant_id
                and t.table_name <> 'tenant'
                and t.table_class <> 'platform_internal'
               then 'operational table in erp has no tenant_id (spec: no unscoped data)' end,
          case when t.table_class in ('tenant_scoped', 'tenant_root', 'product_content')
                and not exists (
                  select 1 from pg_catalog.pg_policy p where p.polrelid = t.oid)
               then 'no row level security policy is defined' end,
          case when t.table_class = 'tenant_scoped_append_only'
                and exists (
                  select 1 from pg_catalog.pg_policy p
                   where p.polrelid = t.oid and p.polcmd in ('u', 'd'))
               then 'append-only table has an UPDATE or DELETE policy' end,
          case when t.table_class = 'tenant_scoped_append_only'
                and (has_table_privilege('authenticated', t.oid, 'UPDATE')
                  or has_table_privilege('authenticated', t.oid, 'DELETE'))
               then 'append-only table grants UPDATE or DELETE to authenticated' end,
          case when has_table_privilege('anon', t.oid, 'SELECT')
               then 'table is readable by the anonymous role' end
        ], null)) as finding
      ) f
  ),
  view_findings as (
    select c.relnamespace::regnamespace::text as schema_name,
           c.relname as table_name,
           case c.relkind when 'v' then '(view)' else '(materialised view)' end as table_class,
           f.finding
      from pg_catalog.pg_class c
      cross join lateral (
        select unnest(array_remove(array[
          -- The default is the opposite, and the default leaks.
          case when c.relkind = 'v'
                and not coalesce(
                      array_to_string(c.reloptions, ',') like '%security_invoker=true%', false)
               then 'view does not set security_invoker, so it runs with the owner''s '
                    'RLS bypass rather than the caller''s policies' end,
          case when c.relkind = 'm'
                and has_table_privilege('authenticated', c.oid, 'SELECT')
               then 'materialised view is readable by a tenant role but cannot enforce '
                    'row level security' end,
          case when has_table_privilege('anon', c.oid, 'SELECT')
               then 'view is readable by the anonymous role' end
        ], null)) as finding
      ) f
     where c.relkind in ('v', 'm')
       and c.relnamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_ai')
  ),
  function_findings as (
    select p.pronamespace::regnamespace::text as schema_name,
           p.proname as table_name,
           '(function)' as table_class,
           'SECURITY DEFINER function is not in erp_meta.security_definer_allowance' as finding
      from pg_catalog.pg_proc p
     where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
       and p.prosecdef
       and not exists (
         select 1 from erp_meta.security_definer_allowance a
          where a.schema_name = p.pronamespace::regnamespace::text
            and a.function_name = p.proname)
  )
  select * from table_findings
  union all select * from view_findings
  union all select * from function_findings
  order by 1, 2, 4
$$;

comment on column erp.device_action.applied_result is
  'What the module function returned when the action was applied — a task '
  'status, a movement id, a document id — so an applied action can be followed '
  'to the record it made.';

-- ── And the second thing it found ───────────────────────────────────────────
--
-- erp.complete_warehouse_task() wrote its stock movement with movement_type
-- 'transfer'. erp_ref.movement_type has never had a row of that code — it has
-- 'putaway' and 'replenishment', which are exactly the two kinds a warehouse
-- task can be — so once the foreign key on erp.stock_movement.movement_type
-- landed, every putaway and every replenishment confirmation failed on it.
-- Nothing called the function from a suite, so nothing noticed. The drain's
-- first applied action is the first call it has ever had, and it surfaced as
-- a conflict reason. The movement now carries the task's own kind.

create or replace function erp.complete_warehouse_task(p_task_id uuid, p_quantity numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor uuid := erp.current_principal_id();
  t erp.warehouse_task%rowtype;
  v_qty numeric;
  v_uom uuid;
  v_entity uuid;
begin
  select * into t from erp.warehouse_task where tenant_id = v_tenant and id = p_task_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_TASK: that warehouse task does not exist here';
  end if;

  perform erp.authorise('inventory.adjust', null, t.site_id, null, 'warehouse_task', t.id);

  if t.status <> 'open' then
    raise exception 'ERPWARE_TASK_NOT_OPEN: that task has already been %', t.status;
  end if;

  v_qty := coalesce(p_quantity, t.quantity);
  if v_qty <= 0 or v_qty > t.quantity then
    raise exception 'ERPWARE_TASK_QUANTITY: the quantity must be above zero and no more than %', t.quantity;
  end if;

  select i.stock_uom_id into v_uom from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id;
  select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = t.site_id;

  -- The movement is the task's kind: putaway or replenishment, both registered
  -- in erp_ref.movement_type as transfers within the site.
  insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, batch_id,
    from_location_id, from_status, to_location_id, to_status, quantity, uom_id, reason_code, actor_id)
  values (v_tenant, v_entity, t.site_id, t.kind, t.item_id, t.batch_id,
    t.from_location_id, t.stock_status, t.to_location_id, t.stock_status, v_qty, v_uom, t.kind, v_actor);

  update erp.warehouse_task
     set quantity_done = quantity_done + v_qty,
         status = case when quantity_done + v_qty >= quantity then 'done' else 'open' end,
         completed_at = case when quantity_done + v_qty >= quantity then now() else null end,
         completed_by = case when quantity_done + v_qty >= quantity then v_actor else null end,
         updated_at = now(), updated_by = v_actor
   where id = t.id;

  return jsonb_build_object('task_id', t.id, 'moved', v_qty);
end $$;

comment on function erp.complete_warehouse_task is
  'Spec 5.2: confirms a putaway or replenishment task, in part or in full, '
  'writing the movement as the task''s own kind. A task not open or a quantity '
  'beyond what the task was raised for is refused by name.';

-- ── §14.3 × §14.5: the register ────────────────────────────────────────────

create table if not exists erp_ref.device_task_handler (
  device_task_code    text primary key references erp_ref.device_task(code),
  module_code         text references erp_ref.module(code),
  -- The erp function that applies the action, by name. Null means nothing
  -- applies it yet, and not_handled_reason must then say why.
  sql_function        text,
  -- Ordered. Each element is {"arg", "type"} plus either {"key", "required"}
  -- to read the payload or {"const"} to pass a fixed value. Position, name
  -- and type are checked against pg_proc by the build.
  arguments           jsonb not null default '[]',
  -- §14.3 names one task that writes nothing: an enquiry. Queueing one is a
  -- client mistake, and the drain says so rather than pretending to apply it.
  writes_nothing      boolean not null default false,
  not_handled_reason  text,
  note                text not null,
  registered_at       timestamptz not null default now(),
  constraint device_task_handler_arguments_are_a_list
    check (jsonb_typeof(arguments) = 'array'),
  constraint device_task_handler_applies_or_says_why
    check (sql_function is not null or writes_nothing
           or coalesce(btrim(not_handled_reason), '') <> ''),
  constraint device_task_handler_read_only_applies_nothing
    check (not writes_nothing or sql_function is null),
  constraint device_task_handler_handled_names_module
    check (sql_function is null or module_code is not null)
);

comment on table erp_ref.device_task_handler is
  'Specification v1.2 §14.5. For each task in erp_ref.device_task, the module '
  'function that applies a queued action and how the payload maps onto its '
  'arguments — or a sentence saying why nothing applies it yet. Read by '
  'erp.drain_device_actions(); checked against pg_proc by '
  'erp.assert_device_task_handlers_sound().';

select erp_meta.register_table('erp_ref', 'device_task_handler', 'product_content',
  'Part 14 §14.5. Which module function applies each device task, or why none does yet.');

insert into erp_ref.device_task_handler
  (device_task_code, module_code, sql_function, arguments, writes_nothing, not_handled_reason, note)
values
-- inbound
('goods_in_booking', null, null, '[]', false,
 'nothing yet records a vehicle arriving against an expected receipt; the receipt itself is the first thing the product records, so a booking captured on a device waits for that function',
 'Inbound. Would confirm an arrival against an expected receipt.'),
('receipt', 'procurement', 'receive_against', '[
   {"arg":"p_receipt_id",    "type":"uuid",    "key":"receipt_id",    "required":true},
   {"arg":"p_order_line_id", "type":"uuid",    "key":"order_line_id", "required":true},
   {"arg":"p_quantity",      "type":"numeric", "key":"quantity",      "required":true},
   {"arg":"p_batch_id",      "type":"uuid",    "key":"batch_id"}]', false, null,
 'Inbound. One line received against the order; the function refuses a line that is not on the order and a receipt that is not open.'),
('receiving_discrepancy', 'quality', 'raise_quality_event', '[
   {"arg":"p_kind",        "type":"erp.quality_event_kind", "const":"non_conformance"},
   {"arg":"p_title",       "type":"text", "key":"reason",   "required":true},
   {"arg":"p_severity",    "type":"text", "key":"severity", "required":true},
   {"arg":"p_site_id",     "type":"uuid", "key":"site_id"},
   {"arg":"p_item_id",     "type":"uuid", "key":"item_id"},
   {"arg":"p_batch_id",    "type":"uuid", "key":"batch_id"},
   {"arg":"p_document_id", "type":"uuid", "key":"document_id"},
   {"arg":"p_party_id",    "type":"uuid", "key":"party_id"}]', false, null,
 'Inbound. Short, over, damaged, wrong product or a temperature excursion is a non-conformance against the receipt, raised with its reason. The photograph travels with the payload.'),
('handling_unit_build', null, null, '[]', false,
 'no function builds a handling unit yet: erp.container is written when stock is received and moved by erp.move_container(), and closing a new unit with contents and an identity applied has no door of its own',
 'Inbound. Would close a new unit with contents and identity.'),
('putaway', 'inventory', 'complete_warehouse_task', '[
   {"arg":"p_task_id",  "type":"uuid",    "key":"task_id", "required":true},
   {"arg":"p_quantity", "type":"numeric", "key":"quantity"}]', false, null,
 'Inbound. Confirms the destination scan against the putaway task erp.raise_putaway_tasks() raised; a task already done or cancelled is refused by name.'),
-- stock
('stock_enquiry', 'inventory', null, '[]', true,
 'a stock enquiry shows a position and writes nothing; §14.3 says so, and a device that queues one has mistaken a read for a write',
 'Stock. Reads only.'),
('internal_move', 'inventory', 'move_container', '[
   {"arg":"p_container_id",   "type":"uuid", "key":"container_id",   "required":true},
   {"arg":"p_to_location_id", "type":"uuid", "key":"to_location_id", "required":true},
   {"arg":"p_reason",         "type":"text", "key":"reason"}]', false, null,
 'Stock. A handling unit scanned at source and again at destination, with everything nested inside it. Loose stock has no move function of its own yet, so a loose move is captured as an adjustment out and in.'),
('replenishment', 'inventory', 'complete_warehouse_task', '[
   {"arg":"p_task_id",  "type":"uuid",    "key":"task_id", "required":true},
   {"arg":"p_quantity", "type":"numeric", "key":"quantity"}]', false, null,
 'Stock. Confirms the destination scan against the task erp.raise_replenishment_tasks() raised.'),
('count', 'inventory', 'record_count', '[
   {"arg":"p_task_id",  "type":"uuid",    "key":"task_id",  "required":true},
   {"arg":"p_quantity", "type":"numeric", "key":"quantity", "required":true}]', false, null,
 'Stock. Records the counted quantity against the count task; the programme''s tolerances decide whether it approves itself or routes to an approver.'),
('adjustment', 'inventory', 'write_off_stock', '[
   {"arg":"p_item_id",     "type":"uuid",    "key":"item_id",     "required":true},
   {"arg":"p_site_id",     "type":"uuid",    "key":"site_id",     "required":true},
   {"arg":"p_location_id", "type":"uuid",    "key":"location_id", "required":true},
   {"arg":"p_quantity",    "type":"numeric", "key":"quantity",    "required":true},
   {"arg":"p_reason",      "type":"text",    "key":"reason",      "required":true},
   {"arg":"p_batch_id",    "type":"uuid",    "key":"batch_id"}]', false, null,
 'Stock. A write-off with its reason; above the threshold the function routes approval itself.'),
('batch_action', 'inventory', 'amend_batch', '[
   {"arg":"p_batch_id", "type":"uuid", "key":"batch_id", "required":true},
   {"arg":"p_field",    "type":"text", "const":"status"},
   {"arg":"p_value",    "type":"text", "key":"status",   "required":true},
   {"arg":"p_reason",   "type":"text", "key":"reason",   "required":true}]', false, null,
 'Stock. Quarantine and block are a status amendment under a reason, which is D10''s evented amendment. Split, merge and release each have their own function and their own screen.'),
-- outbound
('pick', 'sales', 'commit_allocation', '[
   {"arg":"p_allocation_id", "type":"uuid", "key":"allocation_id", "required":true},
   {"arg":"p_location_id",   "type":"uuid", "key":"location_id"},
   {"arg":"p_batch_id",      "type":"uuid", "key":"batch_id"}]', false, null,
 'Outbound. Location then product then quantity: the scanned location and batch narrow the allocation to the stock actually taken. An allocation no longer reserved is refused by name.'),
('short_pick', null, null, '[]', false,
 'a short pick raises an exception against the pick line and triggers replenishment where stock exists elsewhere; erp.raise_replenishment_tasks() exists, and nothing yet records the shortage against the line it was short on',
 'Outbound. Would record the shortage and trigger replenishment.'),
('pack', null, null, '[]', false,
 'packing has no record of its own yet: a shipment is planned from deliveries by erp.plan_shipment(), and scan-verifying contents against the order, capturing carton and weight, and printing the label are captured on the device and wait for a function to land them',
 'Outbound. Would verify contents and capture carton and weight.'),
('marshalling', 'logistics', 'move_container', '[
   {"arg":"p_container_id",   "type":"uuid", "key":"container_id",   "required":true},
   {"arg":"p_to_location_id", "type":"uuid", "key":"to_location_id", "required":true},
   {"arg":"p_reason",         "type":"text", "const":"marshalling"}]', false, null,
 'Outbound. The completed unit scanned into the marshalling area.'),
('despatch', 'logistics', 'book_shipment', '[
   {"arg":"p_shipment_id",  "type":"uuid",   "key":"shipment_id",  "required":true},
   {"arg":"p_carrier_code", "type":"text",   "key":"carrier_code", "required":true},
   {"arg":"p_service_code", "type":"text",   "key":"service_code", "required":true},
   {"arg":"p_cost_minor",   "type":"bigint", "key":"cost_minor"}]', false, null,
 'Outbound. Carrier and service captured against the shipment as the load closes.'),
('returns_receipt', 'sales', 'raise_customer_return', '[
   {"arg":"p_original_document_id", "type":"uuid", "key":"original_document_id", "required":true},
   {"arg":"p_reason_code",          "type":"text", "key":"reason_code",          "required":true},
   {"arg":"p_reason",               "type":"text", "key":"reason",               "required":true},
   {"arg":"p_outcome",              "type":"text", "key":"outcome"}]', false, null,
 'Outbound. The return raised against the document it came from, with condition and the disposition it is routed to.'),
-- production
('component_issue', 'production', 'issue_to_works_order', '[
   {"arg":"p_works_order_id",    "type":"uuid",    "key":"works_order_id",    "required":true},
   {"arg":"p_component_item_id", "type":"uuid",    "key":"component_item_id", "required":true},
   {"arg":"p_quantity",          "type":"numeric", "key":"quantity",          "required":true},
   {"arg":"p_batch_id",          "type":"uuid",    "key":"batch_id"},
   {"arg":"p_location_id",       "type":"uuid",    "key":"location_id"}]', false, null,
 'Production. The scanned batch issued against the works order.'),
('operation_booking', 'production', 'book_operation_time', '[
   {"arg":"p_works_order_id", "type":"uuid",    "key":"works_order_id", "required":true},
   {"arg":"p_operation_seq",  "type":"integer", "key":"operation_seq",  "required":true},
   {"arg":"p_minutes",        "type":"numeric", "key":"minutes",        "required":true},
   {"arg":"p_completed",      "type":"numeric", "key":"completed"},
   {"arg":"p_scrapped",       "type":"numeric", "key":"scrapped"}]', false, null,
 'Production. Quantity completed, quantity scrapped and time against the operation.'),
('finished_goods_receipt', 'production', 'receive_works_order_output', '[
   {"arg":"p_works_order_id", "type":"uuid",    "key":"works_order_id", "required":true},
   {"arg":"p_quantity",       "type":"numeric", "key":"quantity",       "required":true},
   {"arg":"p_batch_number",   "type":"text",    "key":"batch_number"},
   {"arg":"p_location_id",    "type":"uuid",    "key":"location_id"}]', false, null,
 'Production. The declared output received as a batch; the label is an output request the client raises separately.'),
-- quality
('inspection', 'quality', 'record_inspection_result', '[
   {"arg":"p_inspection_id",  "type":"uuid",    "key":"inspection_id",  "required":true},
   {"arg":"p_characteristic", "type":"text",    "key":"characteristic", "required":true},
   {"arg":"p_numeric_value",  "type":"numeric", "key":"numeric_value"},
   {"arg":"p_text_value",     "type":"text",    "key":"text_value"},
   {"arg":"p_instrument",     "type":"text",    "key":"instrument"}]', false, null,
 'Quality. One result per characteristic; the client queues one action per result captured.'),
('disposition', 'quality', 'disposition_inspection', '[
   {"arg":"p_inspection_id", "type":"uuid",            "key":"inspection_id", "required":true},
   {"arg":"p_disposition",   "type":"erp.disposition", "key":"disposition",   "required":true},
   {"arg":"p_note",          "type":"text",            "key":"note"}]', false, null,
 'Quality. Accept, accept under concession, reject, return or destroy, recorded against the inspection.')
on conflict (device_task_code) do update set
  module_code = excluded.module_code, sql_function = excluded.sql_function,
  arguments = excluded.arguments, writes_nothing = excluded.writes_nothing,
  not_handled_reason = excluded.not_handled_reason, note = excluded.note;

-- ── The build guard: the register agrees with the catalogue ────────────────

create or replace function erp.device_task_handler_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with h as (
    select h.*,
           (select count(*) from pg_catalog.pg_proc p
             where p.pronamespace = 'erp'::regnamespace
               and p.proname = h.sql_function and p.prokind = 'f') as overloads,
           p.proargnames, p.proargtypes, p.pronargs, p.pronargdefaults
      from erp_ref.device_task_handler h
      left join lateral (
        select p.proargnames, p.proargtypes, p.pronargs, p.pronargdefaults
          from pg_catalog.pg_proc p
         where p.pronamespace = 'erp'::regnamespace
           and p.proname = h.sql_function and p.prokind = 'f'
         limit 1) p on h.sql_function is not null
  )

  -- 1. A task the register does not mention. §14.3 lists twenty-two; every one
  --    either applies through a function or says why it does not yet.
  select 'a device task has no handler registered', t.code,
         'erp_ref.device_task_handler must name a function or say why none applies'
    from erp_ref.device_task t
   where not exists (select 1 from erp_ref.device_task_handler h
                      where h.device_task_code = t.code)

  union all

  -- 2. A function that is not there. The drain would raise on every action
  --    for this task, and the operator would see a message about a missing
  --    routine instead of a reason.
  select 'a handler names a function that does not exist', h.device_task_code,
         'erp.' || h.sql_function
    from h
   where h.sql_function is not null and h.overloads = 0

  union all

  select 'a handler names a function that is overloaded', h.device_task_code,
         format('erp.%s has %s definitions and the register cannot say which', h.sql_function, h.overloads)
    from h
   where h.sql_function is not null and h.overloads > 1

  union all

  -- 3. Fewer arguments than the function requires without defaults.
  select 'a handler passes fewer arguments than the function requires', h.device_task_code,
         format('%s passed, %s required', jsonb_array_length(h.arguments),
                h.pronargs - h.pronargdefaults)
    from h
   where h.sql_function is not null and h.overloads = 1
     and jsonb_array_length(h.arguments) < h.pronargs - h.pronargdefaults

  union all

  select 'a handler passes more arguments than the function takes', h.device_task_code,
         format('%s passed, %s declared', jsonb_array_length(h.arguments), h.pronargs)
    from h
   where h.sql_function is not null and h.overloads = 1
     and jsonb_array_length(h.arguments) > h.pronargs

  union all

  -- 4. Each argument, in position, by name and by type. The call is built
  --    positionally, so a register that names the right arguments in the
  --    wrong order would pass a quantity where a location was expected.
  select 'a handler argument is out of place', h.device_task_code,
         format('position %s is %s in the register and %s on the function',
                a.ordinality, a.value ->> 'arg', h.proargnames[a.ordinality])
    from h
    cross join lateral jsonb_array_elements(h.arguments) with ordinality as a(value, ordinality)
   where h.sql_function is not null and h.overloads = 1
     and a.ordinality <= h.pronargs
     and (a.value ->> 'arg') is distinct from h.proargnames[a.ordinality]

  union all

  select 'a handler argument casts to a type the function does not take', h.device_task_code,
         format('%s is %s in the register and %s on the function', a.value ->> 'arg',
                a.value ->> 'type', pg_catalog.format_type(h.proargtypes[a.ordinality - 1], null))
    from h
    cross join lateral jsonb_array_elements(h.arguments) with ordinality as a(value, ordinality)
   where h.sql_function is not null and h.overloads = 1
     and a.ordinality <= h.pronargs
     and (a.value ->> 'type') is distinct from
         pg_catalog.format_type(h.proargtypes[a.ordinality - 1], null)

  union all

  select 'a handler argument declares a type the database does not know', h.device_task_code,
         a.value ->> 'type'
    from h
    cross join lateral jsonb_array_elements(h.arguments) as a(value)
   where pg_catalog.to_regtype(a.value ->> 'type') is null

  union all

  select 'a handler argument neither reads the payload nor carries a constant', h.device_task_code,
         coalesce(a.value ->> 'arg', a.value::text)
    from h
    cross join lateral jsonb_array_elements(h.arguments) as a(value)
   where not (a.value ? 'key') and not (a.value ? 'const')

  union all

  -- 5. The register's own promises, restated in case a row predates them.
  select 'a handler neither applies the task nor says why not', h.device_task_code,
         'sql_function, writes_nothing or not_handled_reason'
    from h
   where h.sql_function is null and not h.writes_nothing
     and coalesce(btrim(h.not_handled_reason), '') = ''

  union all

  select 'a handled task names no module', h.device_task_code, 'erp.' || h.sql_function
    from h
   where h.sql_function is not null and h.module_code is null

  order by 1, 2
$$;

comment on function erp.device_task_handler_report is
  'Specification v1.2 §14.5. Checks erp_ref.device_task_handler against '
  'erp_ref.device_task and pg_proc: every task has a row, every function named '
  'exists once, and every argument is in the right position with the right '
  'name and type. Read by erp.assert_device_task_handlers_sound().';

create or replace function erp.assert_device_task_handlers_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text;
  v_tasks integer; v_handled integer; v_reads integer; v_waiting integer;
begin
  select count(*), string_agg(format('  %s [%s] %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.device_task_handler_report();

  if v_count > 0 then
    raise exception 'ERPWARE_DEVICE_TASK_HANDLERS_UNSOUND: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail;
  end if;

  select count(*),
         count(*) filter (where h.sql_function is not null),
         count(*) filter (where h.writes_nothing),
         count(*) filter (where h.sql_function is null and not h.writes_nothing)
    into v_tasks, v_handled, v_reads, v_waiting
    from erp_ref.device_task_handler h;

  return format('device task handlers: %s task(s) — %s apply through a module function, %s read only, %s not yet handled',
                v_tasks, v_handled, v_reads, v_waiting);
end;
$$;

comment on function erp.assert_device_task_handlers_sound is
  'Fails where a device task has no handler row, where a handler names a '
  'function that does not exist or exists twice, or where an argument is in '
  'the wrong position, has the wrong name or type, or reads nothing.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('device_task_handlers', 'Device task handlers sound', 'assertion', 'platform',
   'erp', 'assert_device_task_handlers_sound', '', 'device_task_handler_report', '',
   'Every device task either applies through a module function whose arguments the register maps correctly, or says why nothing applies it yet.',
   true, 62)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  detail_function = excluded.detail_function;

-- ── §14.5 the drain ─────────────────────────────────────────────────────────

create or replace function erp.drain_device_actions(p_device_code text default null,
                                                     p_limit integer default 100)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_user    uuid := erp.current_principal_id();
  v_device  uuid;
  a         record;
  h         erp_ref.device_task_handler%rowtype;
  arg       jsonb;
  v_parts   text[];
  v_missing text;
  v_result  text;
  v_reason  text;
  n_applied integer := 0; n_conflicted integer := 0; n_held integer := 0;
  v_actions jsonb := '[]'::jsonb;
begin
  perform erp.authorise('inventory.move');

  if v_user is null then
    raise exception 'ERPWARE_NO_PRINCIPAL: a queued action is applied by the person who captured it'
      using errcode = '42501';
  end if;

  if p_device_code is not null then
    select d.id into v_device from erp.device d
     where d.tenant_id = v_tenant and d.code = p_device_code;
    if v_device is null then
      raise exception 'ERPWARE_DEVICE_NOT_REGISTERED: % is not a registered device', p_device_code
        using errcode = '42501';
    end if;
  end if;

  -- In the order captured, not received: a pick captured offline at nine and
  -- a count at ten arrive together at eleven, and the count assumes the pick.
  for a in
    select q.*, s.app_user_id as operator_id
      from (select x.* from erp.device_action x
             where x.tenant_id = v_tenant
               and x.status = 'queued'
               and (v_device is null or x.device_id = v_device)
             order by x.captured_at, x.received_at
             limit p_limit
             for update skip locked) q
      left join erp.device_session s
        on s.tenant_id = q.tenant_id and s.id = q.device_session_id
     order by q.captured_at, q.received_at
  loop
    v_reason := null; v_result := null;

    if a.device_session_id is null then
      -- §14.6. The device is not an actor; without a session there is nobody
      -- to attribute the movement to, and it does not post.
      v_reason := 'no operator session was open on the device when this was captured, '
                  'so there is nobody to attribute it to and it is not applied';

    elsif a.operator_id is distinct from v_user then
      -- Somebody else's work. Held, not applied by whoever drained the queue,
      -- because the module function attributes to its caller.
      n_held := n_held + 1;
      v_actions := v_actions || jsonb_build_object(
        'action_id', a.id, 'task', a.device_task_code, 'outcome', 'held',
        'reason', 'captured by another operator; it applies when they reconnect');
      continue;

    else
      select * into h from erp_ref.device_task_handler t
       where t.device_task_code = a.device_task_code;

      if not found then
        v_reason := format('no handler is registered for %s', a.device_task_code);
      elsif h.writes_nothing then
        v_reason := format('%s writes nothing, so there is nothing to apply: %s',
                           a.device_task_code, h.not_handled_reason);
      elsif h.sql_function is null then
        v_reason := format('nothing yet applies a %s captured on a device: %s',
                           a.device_task_code, h.not_handled_reason);
      else
        v_parts := '{}'; v_missing := null;
        for arg in select value from jsonb_array_elements(h.arguments) loop
          if arg ? 'const' then
            v_parts := v_parts || format('%L::%s', arg ->> 'const', arg ->> 'type');
          elsif a.payload ? (arg ->> 'key')
                and jsonb_typeof(a.payload -> (arg ->> 'key')) <> 'null' then
            v_parts := v_parts || format('($1 ->> %L)::%s', arg ->> 'key', arg ->> 'type');
          else
            if coalesce((arg ->> 'required')::boolean, false) then
              v_missing := concat_ws(', ', v_missing, arg ->> 'key');
            end if;
            v_parts := v_parts || format('null::%s', arg ->> 'type');
          end if;
        end loop;

        if v_missing is not null then
          v_reason := format('the payload carries no %s, which a %s needs',
                             v_missing, a.device_task_code);
        else
          -- The module decides. Its refusal — a task already done, an
          -- allocation no longer reserved, a location that does not exist —
          -- is the reason the operator sees, and its partial writes are
          -- undone with the exception.
          begin
            execute format('select (erp.%I(%s))::text', h.sql_function,
                           array_to_string(v_parts, ', '))
               into v_result using a.payload;
          exception when others then
            v_reason := left(sqlerrm, 500);
          end;
        end if;
      end if;
    end if;

    if v_reason is null then
      v_result := coalesce(nullif(v_result, ''), 'done');
      update erp.device_action
         set status = 'applied', applied_at = now(), applied_result = v_result
       where id = a.id;
      n_applied := n_applied + 1;
      v_actions := v_actions || jsonb_build_object(
        'action_id', a.id, 'task', a.device_task_code, 'outcome', 'applied',
        'result', v_result);
    else
      update erp.device_action
         set status = 'conflicted', conflict_reason = v_reason
       where id = a.id;
      n_conflicted := n_conflicted + 1;
      v_actions := v_actions || jsonb_build_object(
        'action_id', a.id, 'task', a.device_task_code, 'outcome', 'conflicted',
        'reason', v_reason);
    end if;
  end loop;

  return jsonb_build_object('applied', n_applied, 'conflicted', n_conflicted,
                            'held', n_held, 'actions', v_actions);
end;
$$;

comment on function erp.drain_device_actions is
  'Specification v1.2 §14.5. Applies the caller''s queued actions in the order '
  'they were captured, each through the module function '
  'erp_ref.device_task_handler names for its task. A refusal from the module, a '
  'payload missing what the task needs, a task nothing applies yet, or an '
  'action captured with no session open becomes a conflict with that reason; '
  'another operator''s actions are held for them. Never posts silently, never '
  'silently disappears.';

-- ── The doors ───────────────────────────────────────────────────────────────

create or replace function public.erp_drain_device_actions(p_device_code text default null,
                                                            p_limit integer default 100)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.drain_device_actions(p_device_code, p_limit);
$$;

create or replace function public.erp_device_task_handlers()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x ->> 'seq')::integer), '[]'::jsonb) from (
    select jsonb_build_object(
             'code', t.code, 'name', t.name, 'task_group', t.task_group, 'seq', t.seq,
             'module_code', h.module_code,
             'sql_function', case when h.sql_function is null then null
                                  else 'erp.' || h.sql_function end,
             'payload_keys', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'key', a.value ->> 'key',
                        'type', a.value ->> 'type',
                        'required', coalesce((a.value ->> 'required')::boolean, false))
                      order by a.ordinality)
                 from jsonb_array_elements(h.arguments) with ordinality as a(value, ordinality)
                where a.value ? 'key'), '[]'::jsonb),
             'writes_nothing', h.writes_nothing,
             'not_handled_reason', h.not_handled_reason,
             'note', h.note) as x
      from erp_ref.device_task t
      left join erp_ref.device_task_handler h on h.device_task_code = t.code) s;
$$;

create or replace function public.erp_device_actions()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by received_at desc), '[]'::jsonb) from (
    select jsonb_build_object(
             'id', a.id, 'device', d.code, 'site', s.code,
             'task_code', a.device_task_code, 'status', a.status,
             'input_method', a.input_method, 'keyed_reason', a.keyed_reason,
             'captured_at', a.captured_at, 'received_at', a.received_at,
             'applied_at', a.applied_at, 'applied_result', a.applied_result,
             'conflict_reason', a.conflict_reason,
             'payload', a.payload) as x,
           a.received_at
      from erp.device_action a
      join erp.device d on d.tenant_id = a.tenant_id and d.id = a.device_id
      join erp.site s on s.tenant_id = d.tenant_id and s.id = d.site_id
     order by a.received_at desc
     limit 500) t;
$$;

-- Supabase carries DEFAULT PRIVILEGES on schema public that grant EXECUTE to
-- anon, so a new door is callable without signing in until it is revoked.
revoke all on function
  public.erp_drain_device_actions(text, integer),
  public.erp_device_task_handlers(),
  public.erp_device_actions()
  from public, anon;

grant execute on function
  public.erp_drain_device_actions(text, integer),
  public.erp_device_task_handlers(),
  public.erp_device_actions()
  to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_drain_device_actions', 'erp.drain_device_actions',
   'Applies the caller''s own queued device actions through the module functions the handler register names. Gates on inventory.move as the queue itself does; each module function then authorises the work it performs, and a refusal becomes the conflict reason rather than an error.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- ── The decision, settled ───────────────────────────────────────────────────

update erp_meta.policy_decision set
  title = 'A queued device action is applied by the module that owns the work',
  status = 'accepted',
  decision = 'erp.drain_device_actions() applies the caller''s queued actions in the order they were captured, each through the module function erp_ref.device_task_handler names for its task. Seventeen of the twenty-two tasks apply this way; stock enquiry writes nothing by §14.3''s own definition; goods-in booking, handling unit build, short pick and pack have no function yet and the register says why in a sentence. An action for one of those, a payload missing what the task needs, a module''s refusal, or an action captured with no session open all become a conflict carrying that reason. Another operator''s actions are held for them.',
  rationale = 'The original rationale stands: which function applies each task and what makes an action no longer valid is per-module design, and a generic applier would be wrong for most of them. So the mapping is a register the build checks against pg_proc — position, name and type of every argument — rather than a CASE somebody has to remember to extend, and the module function decides validity for its own objects. The drain applies only the actions of the operator calling it, because the module functions attribute to their caller and §14.6 attributes every action to the person who performed it, not to whoever drained the queue.',
  evidence = 'erp_ref.device_task_handler, twenty-two rows; erp.assert_device_task_handlers_sound() in CI; erp.drain_device_actions() and public.erp_drain_device_actions() registered in erp_meta.public_write_allowance and revoked from anon; erp_test.device_drain_suite() proves a putaway and the count that followed it apply in captured order, that a task nothing applies conflicts with the register''s reason, that a payload missing its task id and a module''s own refusal each conflict with the reason, that an action with no session is never applied, that another operator''s action is held, and that draining twice applies nothing twice.',
  decided_at = now()
 where code = 'device_action_queue_is_not_drained';

-- ── The suite ───────────────────────────────────────────────────────────────

create or replace function erp_test.device_drain_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r        record;
  a1 uuid := gen_random_uuid();   -- the operator who captures most of this
  a2 uuid := gen_random_uuid();   -- a co-administrator, and the second operator
  op uuid := gen_random_uuid();   -- somebody with no warehouse rights
  csf uuid; csp uuid; css uuid; csi uuid;
  v_second uuid; v_op uuid; v_tok text; res jsonb;
  v_uom uuid; v_site uuid; v_recv uuid; v_bulk uuid; v_sup uuid; v_item uuid;
  v_grn uuid; v_wtask uuid; v_ctask uuid; v_ctask2 uuid;
  v_n integer; v_moves integer;
  k1 uuid; k2 uuid; k3 uuid; k4 uuid; k5 uuid; k6 uuid; k7 uuid; k8 uuid; k9 uuid;
  v_ok boolean; v_msg text;
begin
  select * into r from erp.provision_tenant(
    'zzdrn', 'Device Drain', 'admin@zzdrn.test', 'Drain Admin');
  insert into auth.users (id, email) values
    (a1, 'admin@zzdrn.test'), (a2, 'second@zzdrn.test'), (op, 'op@zzdrn.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zzdrn.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  csf := erp.configure_finance();
  csp := erp.configure_procurement(100000000);
  css := erp.configure_sales(15);
  csi := erp.configure_inventory('average');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
  perform erp.approve_change_set(css); perform erp.promote_change_set(css);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
  insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
  values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
  insert into erp.location (tenant_id, site_id, code, name, location_type, status)
  values (r.tenant_id, v_site, 'BULK-01', 'Bulk 01', 'bulk', 'active') returning id into v_bulk;
  insert into erp.party (tenant_id, code, name, status)
  values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;

  -- A hundred in receiving, a putaway task over them, and a count task on the
  -- receiving location as it stands now.
  v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
  perform erp.add_document_line(v_grn, v_item, 100, 1000, 'the stock');
  perform erp.transition_document(v_grn, 'post');
  perform erp.raise_putaway_tasks(v_site);
  select t.id into v_wtask from erp.warehouse_task t
   where t.tenant_id = r.tenant_id and t.kind = 'putaway' and t.status = 'open';
  perform erp.raise_count_tasks('cycle_a');
  select t.id into v_ctask from erp.count_task t
   where t.tenant_id = r.tenant_id and t.location_id = v_recv and t.status = 'open';

  -- ── The register agrees with the catalogue ────────────────────────────────

  begin
    v_msg := erp.assert_device_task_handlers_sound(); v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  return query select 'every device task applies through a named function, or says why not',
    v_ok and v_msg like '%22 task(s) — 17 apply%1 read only, 4 not yet handled%', v_msg;

  -- ── §14.5 captured offline, applied in order ──────────────────────────────

  perform erp.register_device('HH-01', 'MAIN', 'Handheld 1', 'handheld');
  perform erp.open_device_session('HH-01');

  -- Seven actions, captured a minute apart, arriving together. The putaway
  -- moves forty out of receiving; the count that follows it counts sixty,
  -- which is only right if the putaway applied first.
  k1 := (erp.record_device_action('HH-01', 'putaway', 'k1',
           jsonb_build_object('task_id', v_wtask, 'quantity', 40),
           'scanned', null, now() - interval '7 minutes') ->> 'action_id')::uuid;
  k2 := (erp.record_device_action('HH-01', 'count', 'k2',
           jsonb_build_object('task_id', v_ctask, 'quantity', 60),
           'scanned', null, now() - interval '6 minutes') ->> 'action_id')::uuid;
  k3 := (erp.record_device_action('HH-01', 'goods_in_booking', 'k3',
           '{"vehicle":"AB12 CDE"}'::jsonb,
           'scanned', null, now() - interval '5 minutes') ->> 'action_id')::uuid;
  k4 := (erp.record_device_action('HH-01', 'stock_enquiry', 'k4',
           jsonb_build_object('item_id', v_item),
           'scanned', null, now() - interval '4 minutes') ->> 'action_id')::uuid;
  k5 := (erp.record_device_action('HH-01', 'count', 'k5',
           '{"quantity": 12}'::jsonb,
           'scanned', null, now() - interval '3 minutes') ->> 'action_id')::uuid;
  k6 := (erp.record_device_action('HH-01', 'putaway', 'k6',
           jsonb_build_object('task_id', v_wtask, 'quantity', 60),
           'scanned', null, now() - interval '2 minutes') ->> 'action_id')::uuid;
  k7 := (erp.record_device_action('HH-01', 'putaway', 'k7',
           jsonb_build_object('task_id', v_wtask, 'quantity', 1),
           'scanned', null, now() - interval '1 minute') ->> 'action_id')::uuid;

  res := erp.drain_device_actions('HH-01');

  return query select 'a queued putaway applies through the warehouse task it names',
    (select a.status from erp.device_action a where a.id = k1) = 'applied'
    and (select t.quantity_done from erp.warehouse_task t where t.id = v_wtask) >= 40
    and exists (select 1 from erp.stock_movement m
                 where m.tenant_id = r.tenant_id and m.reason_code = 'putaway'),
    format('%s applied, %s conflicted, %s held', res ->> 'applied', res ->> 'conflicted', res ->> 'held');

  return query select 'and the count captured after it counts what the putaway left',
    (select a.status from erp.device_action a where a.id = k2) = 'applied'
    and (select t.status::text from erp.count_task t where t.id = v_ctask) = 'approved'
    and (select t.variance from erp.count_task t where t.id = v_ctask) = 0,
    'sixty counted against a hundred received and forty put away: in captured order, or the count is forty out';

  return query select 'what the module returned is recorded against the action',
    (select a.applied_result from erp.device_action a where a.id = k2) = 'approved'
    and (select a.applied_result from erp.device_action a where a.id = k1) like '{%"moved"%',
    coalesce((select a.applied_result from erp.device_action a where a.id = k2), 'nothing');

  return query select 'a task nothing applies yet conflicts with the register''s sentence',
    (select a.status from erp.device_action a where a.id = k3) = 'conflicted'
    and (select a.conflict_reason from erp.device_action a where a.id = k3)
        like 'nothing yet applies a goods_in_booking%vehicle arriving%',
    left((select a.conflict_reason from erp.device_action a where a.id = k3), 90);

  return query select 'a stock enquiry has nothing to apply, and says so',
    (select a.status from erp.device_action a where a.id = k4) = 'conflicted'
    and (select a.conflict_reason from erp.device_action a where a.id = k4)
        like 'stock_enquiry writes nothing%',
    '§14.3: the operator leaves the screen; nothing was written';

  return query select 'a payload missing what the task needs conflicts naming it',
    (select a.status from erp.device_action a where a.id = k5) = 'conflicted'
    and (select a.conflict_reason from erp.device_action a where a.id = k5)
        = 'the payload carries no task_id, which a count needs',
    (select a.conflict_reason from erp.device_action a where a.id = k5);

  return query select 'the putaway that finishes the task applies',
    (select a.status from erp.device_action a where a.id = k6) = 'applied'
    and (select t.status from erp.warehouse_task t where t.id = v_wtask) = 'done',
    'forty then sixty is the hundred the task was raised for';

  return query select 'and the one after it conflicts with the module''s own refusal',
    (select a.status from erp.device_action a where a.id = k7) = 'conflicted'
    and (select a.conflict_reason from erp.device_action a where a.id = k7)
        like 'ERPWARE_TASK_NOT_OPEN%',
    '§14.5: "a putaway whose location has been re-slotted" — the module says why, the operator reads it';

  return query select 'the drain reports every outcome',
    (res ->> 'applied')::integer = 3 and (res ->> 'conflicted')::integer = 4
    and (res ->> 'held')::integer = 0
    and jsonb_array_length(res -> 'actions') = 7,
    format('%s applied, %s conflicted, %s held', res ->> 'applied', res ->> 'conflicted', res ->> 'held');

  -- ── §14.6 no session, no actor, no posting ────────────────────────────────

  perform erp.close_device_session('end of shift');
  k8 := (erp.record_device_action('HH-01', 'count', 'k8',
           jsonb_build_object('task_id', v_ctask, 'quantity', 60)) ->> 'action_id')::uuid;
  res := erp.drain_device_actions('HH-01');
  return query select 'an action captured with no session open is never applied',
    (select a.status from erp.device_action a where a.id = k8) = 'conflicted'
    and (select a.conflict_reason from erp.device_action a where a.id = k8)
        like 'no operator session was open%'
    and (select a.applied_at from erp.device_action a where a.id = k8) is null,
    '§14.6: the device is not an actor';

  -- ── §14.6 somebody else's work is held for them ───────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.open_device_session('HH-01');
  perform erp.raise_count_tasks('cycle_a');
  select t.id into v_ctask2 from erp.count_task t
   where t.tenant_id = r.tenant_id and t.location_id = v_bulk and t.status = 'open';
  k9 := (erp.record_device_action('HH-01', 'count', 'k9',
           jsonb_build_object('task_id', v_ctask2, 'quantity', 100)) ->> 'action_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  res := erp.drain_device_actions('HH-01');
  return query select 'another operator''s action is held, not applied by whoever drains',
    (res ->> 'held')::integer = 1 and (res ->> 'applied')::integer = 0
    and (select a.status from erp.device_action a where a.id = k9) = 'queued',
    'the module attributes to its caller, and the caller is not who counted';

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  res := erp.drain_device_actions('HH-01');
  return query select 'and applies when they reconnect',
    (res ->> 'applied')::integer = 1
    and (select a.status from erp.device_action a where a.id = k9) = 'applied'
    and (select t.counted_by from erp.count_task t where t.id = v_ctask2) = v_second,
    'counted_by is the second operator, not the first';

  -- ── §14.5 reconnection never duplicates, at the applying end too ─────────

  select count(*) into v_moves from erp.stock_movement m where m.tenant_id = r.tenant_id;
  res := erp.drain_device_actions();
  return query select 'draining again applies nothing twice',
    (res ->> 'applied')::integer = 0 and (res ->> 'conflicted')::integer = 0
    and (select count(*) from erp.stock_movement m where m.tenant_id = r.tenant_id) = v_moves,
    format('%s movement(s) before and after', v_moves);

  select count(*) filter (where q.status = 'conflicted'), count(*) filter (where q.status = 'queued')
    into v_n, v_moves
    from erp.device_queue('HH-01') q;
  return query select 'the operator''s queue shows only what still needs them',
    v_n = 5 and v_moves = 0,
    format('%s conflicted, each with its reason; %s queued', v_n, v_moves);

  return query select 'and the device model still reads as sound with actions applied',
    erp.assert_device_operations_sound() is not null,
    'an applied action attributes to a session, and every conflict carries a reason';

  -- ── The person, not the hardware ──────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  res := public.erp_invite_principal('op@zzdrn.test', 'No rights');
  v_op := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  perform erp.claim_invitation(v_tok);
  begin
    perform erp.drain_device_actions('HH-01');
    v_ok := false; v_msg := 'somebody who may not move stock drained the queue';
  exception when others then
    v_ok := sqlerrm not like 'ERPWARE_DEVICE%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a person who may not move stock may not apply the queue either', v_ok, v_msg;

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  -- The goods receipt posted a journal, and the journal-balance check is a
  -- deferred constraint trigger. Fire it now, while the lines it checks still
  -- exist, rather than at commit after the organisation has gone.
  set constraints all immediate;
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2, op);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id)
    and not exists (select 1 from auth.users u where u.id in (a1, a2, op)),
    'devices, sessions and applied actions go with the organisation';
end;
$$;

comment on function erp_test.device_drain_suite is
  'Specification v1.2 §14.5 and §14.6, proven adversarially: seven actions '
  'captured a minute apart arrive together and apply in captured order; a '
  'task nothing applies, a payload missing its task id and a module''s own '
  'refusal each conflict with the reason; an action with no session is never '
  'applied; another operator''s action is held for them; draining twice '
  'applies nothing twice.';

create or replace function erp_test.assert_device_drain_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _device_drain_result on commit drop as
    select * from erp_test.device_drain_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_total, v_passed, v_detail
    from _device_drain_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_DEVICE_DRAIN_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('device drain: %s/%s', v_passed, v_total);
end;
$$;

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
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_product_decisions_enforced();
select erp.assert_device_operations_sound();
select erp.assert_device_task_handlers_sound();
select erp_test.assert_device_drain_suite();
