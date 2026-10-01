-- ═════════════════════════════════════════════════════════════════════════════
-- Stock arrives at its value, and imports go live together
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Three things the Xero and Unleashed importers left for last.
--
-- 1. Opening stock arrives at the value the legacy system states.
--
--    The stock door took a whole-penny unit cost and valued each row at
--    round(quantity × unit cost). Unleashed averages to fractions of a penny:
--    50,000 fixings at £0.043 are £2,150.00, and at the £0.04 the door could
--    take they were £2,000.00. The file said so line by line, and the value on
--    the shelf still did not match the value on the report.
--
--    A stock row may now carry value_minor, the value itself. The unit cost
--    stays the whole-penny display figure; the movement, the costing store,
--    the journal and the subledger carry the value. Validation refuses a value
--    more than a penny a unit from quantity × unit cost, which is a different
--    number rather than a rounding, and refuses an inexact value on a product
--    costed FIFO: a FIFO layer holds a whole-penny unit cost, so the value
--    could not survive the first issue. The refusal names both ways out.
--
--    erp.receive_cost_at() is erp.receive_cost() with the exact value: where
--    the value is quantity × unit cost it is receive_cost; where it is not, it
--    refuses FIFO, and for average cost (or a product with no cost yet) it
--    moves the value on hand by the difference and derives the unit cost from
--    it, as average costing already does on every receipt.
--
-- 2. Imported contacts and products go live together.
--
--    party_profile and item_profile load what they create as drafts, so that
--    nothing half-reviewed is sold or bought. erp.activate_import_batch() sets
--    a loaded batch's drafts active in one step — a product Unleashed called
--    obsolete stays discontinued — and records who did it and when. That ends
--    the rollback window: once people can trade with the records, removing
--    them is a correction on the desk, not a rollback. A trigger holds it for
--    every path that could roll a batch back. Anyone who may load master data
--    may activate it (master_data.import and master_data.write).
--
-- 3. The control total keeps its evidence.
--
--    An opening batch is staged with a control total: the figure the printed
--    report shows, less the lines held back (a negative quantity, a zero line).
--    The batch kept the result and not the working. erp.record_control_evidence()
--    keeps the printed figure and each line held back with its reason beside
--    the batch, refuses working that does not come to the control total, and
--    the cutover decision carries it with the rest of its evidence.
--
-- Deployed bodies are patched with asserted needles, as 20260918810000 does:
-- each needle must appear exactly once, or nothing is changed.
--
-- Proof: erp_test.exact_stock_and_activation_suite() (11 cases).

set lock_timeout = '30s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The stock row may carry its value
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.migration_domain d
   set row_keys = d.row_keys || '[{"key":"value_minor","type":"integer","required":false}]'::jsonb,
       description = 'Stock on hand by product, site and location, at unit cost, and at the value the legacy system states where the row carries value_minor. Each row becomes an opening_balance movement dated as at the cutover and a cost layer; the batch posts one journal, stock against migration clearing, with a stock subledger row per product.'
 where d.domain_code = 'stock'
   and not exists (select 1 from jsonb_array_elements(d.row_keys) k where k ->> 'key' = 'value_minor');

alter table erp.import_batch
  add column if not exists activated_at timestamptz,
  add column if not exists activated_by uuid,
  add column if not exists control_evidence jsonb;

comment on column erp.import_batch.activated_at is
  'When the drafts a party_profile or item_profile batch created were set active together. Set, the batch no longer rolls back (20261003900000).';
comment on column erp.import_batch.activated_by is
  'The principal who activated the batch (20261003900000).';
comment on column erp.import_batch.control_evidence is
  'The working behind an opening batch''s control total: the printed figure, the printed quantity, and each line held back with its reason and value (20261003900000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. A receipt at an exact value
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.receive_cost_at(
  p_item_id uuid, p_site_id uuid, p_quantity numeric, p_unit_cost_minor bigint, p_cost_minor bigint,
  p_currency character, p_batch_id uuid default null, p_movement_id bigint default null)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_round  bigint := round(p_quantity * p_unit_cost_minor)::bigint;
  v_method erp.costing_method;
  v_had    boolean;
  v_unit   bigint;
begin
  if p_cost_minor is null or p_cost_minor = v_round then
    return erp.receive_cost(p_item_id, p_site_id, p_quantity, p_unit_cost_minor, p_currency, p_batch_id, p_movement_id);
  end if;

  if p_cost_minor < 0 then
    raise exception 'CLOVEERP_COST_NEGATIVE: a receipt cannot be worth %', p_cost_minor
      using errcode = '23514', hint = 'Give the value the stock holds; a negative value is a correction, made on the desk.';
  end if;

  v_method := erp.costing_method_for(p_item_id, p_site_id);
  if v_method = 'fifo' then
    raise exception 'CLOVEERP_FIFO_COST_NOT_EXACT: % unit(s) at % is %, not %; a FIFO layer holds a whole-penny unit cost',
      p_quantity, p_unit_cost_minor, v_round, p_cost_minor
      using errcode = '23514',
            hint = 'Cost the product by average to keep the exact value, or load it at the whole-penny unit cost and value.';
  end if;

  select exists (select 1 from erp.item_cost c
                  where c.tenant_id = v_tenant and c.item_id = p_item_id
                    and c.site_id is not distinct from p_site_id)
    into v_had;

  v_unit := erp.receive_cost(p_item_id, p_site_id, p_quantity, p_unit_cost_minor, p_currency, p_batch_id, p_movement_id);

  -- Average cost holds a value and derives the unit cost from it, so the value
  -- moves by what the rounding lost. Standard cost debits inventory at the
  -- standard, whatever was paid; it is left as receive_cost leaves it.
  if v_method = 'average' or not v_had then
    update erp.item_cost c
       set value_minor = c.value_minor + (p_cost_minor - v_round),
           unit_cost_minor = case when c.quantity_on_hand > 0
                                  then round((c.value_minor + (p_cost_minor - v_round)) / c.quantity_on_hand)::bigint
                                  else c.unit_cost_minor end,
           updated_at = now()
     where c.tenant_id = v_tenant and c.item_id = p_item_id
       and c.site_id is not distinct from p_site_id;
    perform erp.note_cost(p_item_id, p_site_id, p_quantity, p_unit_cost_minor, p_cost_minor);
  end if;

  return v_unit;
end;
$$;

comment on function erp.receive_cost_at is
  'erp.receive_cost() at an exact value. Where the value is round(quantity × unit cost) it is receive_cost. '
  'Otherwise it refuses FIFO, whose layers hold a whole-penny unit cost, and for average cost moves the value '
  'on hand by the difference and derives the unit cost from it (20261003900000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Opening stock loads, validates and is counted at that value
-- ─────────────────────────────────────────────────────────────────────────────

do $stock$
declare
  v_sig  constant text := 'erp.load_opening_stock(uuid)';
  v_def  text := pg_get_functiondef('erp.load_opening_stock(uuid)'::regprocedure);
  v_swap constant text[] := array[
    'v_value := round(v_qty * v_cost)::bigint;',
    'v_value := coalesce((r.raw ->> ''value_minor'')::bigint, round(v_qty * v_cost)::bigint);',
    'to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,',
    'to_location_id, to_status, quantity, uom_id, unit_cost_minor, cost_minor, currency,',
    'v_loc, ''available'', v_qty, v_item.stock_uom_id, v_cost, b.currency,',
    'v_loc, ''available'', v_qty, v_item.stock_uom_id, v_cost, v_value, b.currency,',
    'perform erp.receive_cost(v_item.id, v_site.id, v_qty, v_cost, b.currency, v_batch, v_move);',
    'perform erp.receive_cost_at(v_item.id, v_site.id, v_qty, v_cost, v_value, b.currency, v_batch, v_move);'];
  v_hits integer;
begin
  if position('receive_cost_at' in v_def) > 0 then
    raise exception 'CLOVEERP_OPENING_STOCK_UNRECOGNISED: % already loads at the exact value', v_sig
      using hint = 'This migration has run against this body already; read the deployed body before patching it again.';
  end if;
  for i in 1 .. array_length(v_swap, 1) by 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_swap[i], ''))) / length(v_swap[i]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_OPENING_STOCK_UNRECOGNISED: expected "%" once in %, found %', v_swap[i], v_sig, v_hits
        using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
    end if;
    v_def := replace(v_def, v_swap[i], v_swap[i + 1]);
  end loop;
  execute v_def;
end
$stock$;

do $validate$
declare
  v_sig    constant text := 'erp.validate_opening_balances(uuid)';
  v_def    text := pg_get_functiondef('erp.validate_opening_balances(uuid)'::regprocedure);
  v_needle constant text := E'''message'', ''unit cost cannot be negative'');\n        end if;\n';
  v_hits   integer;
begin
  if position('value_minor' in v_def) > 0 then
    raise exception 'CLOVEERP_OPENING_VALIDATION_UNRECOGNISED: % already reads value_minor', v_sig
      using hint = 'This migration has run against this body already; read the deployed body before patching it again.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_OPENING_VALIDATION_UNRECOGNISED: expected the unit-cost check once in %, found %', v_sig, v_hits
      using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
  end if;
  execute replace(v_def, v_needle, v_needle || $add$
        -- The value the legacy system states, where the row carries it: within
        -- a penny a unit of quantity × unit cost, and exact only where a cost
        -- layer can hold it (20261003900000).
        if (r.raw ->> 'value_minor') is not null then
          if (r.raw ->> 'value_minor')::bigint < 0 then
            v_find := v_find || jsonb_build_object('severity', 'error',
              'message', 'value cannot be negative');
          elsif abs((r.raw ->> 'value_minor')::bigint
                    - (r.raw ->> 'quantity')::numeric * (r.raw ->> 'unit_cost_minor')::bigint)
                > greatest(abs((r.raw ->> 'quantity')::numeric), 1) then
            v_find := v_find || jsonb_build_object('severity', 'error',
              'message', format('value %s is not quantity × unit cost (%s) to within a penny a unit',
                                r.raw ->> 'value_minor',
                                round((r.raw ->> 'quantity')::numeric * (r.raw ->> 'unit_cost_minor')::bigint)));
          elsif v_item.id is not null
                and (r.raw ->> 'value_minor')::bigint
                    <> round((r.raw ->> 'quantity')::numeric * (r.raw ->> 'unit_cost_minor')::bigint)
                and erp.costing_method_for(v_item.id, v_site) = 'fifo' then
            v_find := v_find || jsonb_build_object('severity', 'error',
              'message', format('%s is costed FIFO, whose layers hold a whole-penny unit cost: cost it by average to keep %s, or load it at %s',
                                v_item.code, r.raw ->> 'value_minor',
                                round((r.raw ->> 'quantity')::numeric * (r.raw ->> 'unit_cost_minor')::bigint)));
          end if;
        end if;
$add$);
end
$validate$;

-- The parallel-run figure counts an opening movement at the value it carried.
do $figure$
declare
  v_sig    constant text := 'erp.migration_figure_stock(date)';
  v_def    text := pg_get_functiondef('erp.migration_figure_stock(date)'::regprocedure);
  v_needle constant text := 'then m.quantity * coalesce(m.unit_cost_minor, 0)';
  v_hits   integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 or position('cost_minor is not null' in v_def) > 0 then
    raise exception 'CLOVEERP_STOCK_FIGURE_UNRECOGNISED: expected the receipt arm once in %, found %', v_sig, v_hits
      using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
  end if;
  execute replace(v_def, v_needle,
    'then case when m.movement_type = ''opening_balance'' and m.cost_minor is not null then m.cost_minor::numeric else m.quantity * coalesce(m.unit_cost_minor, 0) end');
end
$figure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The working behind a control total
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.record_control_evidence(
  p_batch_id uuid, p_printed_minor bigint, p_printed_quantity numeric, p_exclusions jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_held   bigint;
  v_heldq  numeric;
  v_out    jsonb;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_IMPORT: %', p_batch_id
      using errcode = '23503', hint = 'Stage the opening batch first; the evidence is kept beside it.';
  end if;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);

  if not exists (select 1 from erp_ref.migration_domain d where d.object_type = b.object_type) then
    raise exception 'CLOVEERP_CONTROL_EVIDENCE_NOT_OPENING: % is a % batch, which has no control total', b.code, b.object_type
      using errcode = '23514', hint = 'Control evidence belongs to an opening balance batch.';
  end if;
  if b.status not in ('received', 'validated', 'previewed') then
    raise exception 'CLOVEERP_CONTROL_EVIDENCE_TOO_LATE: % is %', b.code, b.status
      using errcode = '23514', hint = 'The evidence is recorded before the batch loads; stage the file again to record it.';
  end if;
  if p_printed_minor is null or jsonb_typeof(coalesce(p_exclusions, '[]'::jsonb)) <> 'array'
     or exists (select 1 from jsonb_array_elements(coalesce(p_exclusions, '[]'::jsonb)) e
                 where jsonb_typeof(e) <> 'object' or coalesce(btrim(e ->> 'reason'), '') = ''
                    or coalesce(e ->> 'amount_minor', '0') !~ '^-?[0-9]+$'
                    or coalesce(e ->> 'quantity', '0') !~ '^-?[0-9]+(\.[0-9]+)?$') then
    raise exception 'CLOVEERP_CONTROL_EVIDENCE_MALFORMED: the printed total and a reason for each line held back are required'
      using errcode = '22023', hint = 'Give the figure the report prints, and each held-back line as {label, reason, amount_minor, quantity}.';
  end if;

  select coalesce(sum((e ->> 'amount_minor')::bigint), 0), coalesce(sum((e ->> 'quantity')::numeric), 0)
    into v_held, v_heldq
    from jsonb_array_elements(coalesce(p_exclusions, '[]'::jsonb)) e;

  if p_printed_minor - v_held <> b.control_total_minor then
    raise exception 'CLOVEERP_CONTROL_EVIDENCE_DISAGREES: printed % less % held back is %, and % was staged with %',
      p_printed_minor, v_held, p_printed_minor - v_held, b.code, b.control_total_minor
      using errcode = '23514', hint = 'The control total is the printed figure less the lines held back; stage the file again with the figure the report prints.';
  end if;
  if p_printed_quantity is not null and b.control_quantity is not null
     and p_printed_quantity - v_heldq <> b.control_quantity then
    raise exception 'CLOVEERP_CONTROL_EVIDENCE_DISAGREES: printed quantity % less % held back is not the % staged',
      p_printed_quantity, v_heldq, b.control_quantity
      using errcode = '23514', hint = 'The control quantity is the printed quantity less the lines held back; stage the file again.';
  end if;

  v_out := jsonb_build_object(
    'printed_minor', p_printed_minor, 'printed_quantity', p_printed_quantity,
    'held_back_minor', v_held, 'exclusions', coalesce(p_exclusions, '[]'::jsonb),
    'recorded_at', now(), 'recorded_by', erp.current_principal_id());
  update erp.import_batch set control_evidence = v_out, updated_at = now() where id = p_batch_id;
  return v_out;
end;
$$;

comment on function erp.record_control_evidence is
  'Keeps the working behind an opening batch''s control total — the printed figure and each line held back, '
  'with its reason — and refuses working that does not come to it (20261003900000).';

-- The cutover decision carries the working with the rest of its evidence.
do $cutover$
declare
  v_sig    constant text := 'erp.cut_over_domain(text,text)';
  v_def    text := pg_get_functiondef('erp.cut_over_domain(text,text)'::regprocedure);
  v_needle constant text := '''control_total_minor'', b.control_total_minor, ''loaded_by'', b.loaded_by,';
  v_hits   integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 or position('control_evidence' in v_def) > 0 then
    raise exception 'CLOVEERP_CUTOVER_UNRECOGNISED: expected the batch evidence once in %, found %', v_sig, v_hits
      using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
  end if;
  execute replace(v_def, v_needle, v_needle || ' ''control_evidence'', b.control_evidence,');
end
$cutover$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Activation
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.activate_import_batch(p_batch_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  b        erp.import_batch%rowtype;
  v_n      integer := 0;
begin
  select * into b from erp.import_batch x where x.tenant_id = v_tenant and x.id = p_batch_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_IMPORT: %', p_batch_id
      using errcode = '23503', hint = 'Choose a batch from the import batches list.';
  end if;
  perform erp.authorise('master_data.import', null, null, null, 'import_batch', p_batch_id);
  perform erp.authorise('master_data.write', null, null, null, 'import_batch', p_batch_id);

  if b.object_type not in ('party_profile', 'item_profile') then
    raise exception 'CLOVEERP_IMPORT_NOT_ACTIVATABLE: % is a % batch, which does not load drafts', b.code, b.object_type
      using errcode = '23514', hint = 'Contacts and products load as drafts and are activated; everything else is live when it loads.';
  end if;
  if b.status <> 'loaded' then
    raise exception 'CLOVEERP_IMPORT_NOT_LOADED: % is %', b.code, b.status
      using errcode = '23514', hint = 'Validate, preview and load the batch, then activate it.';
  end if;
  if b.activated_at is not null then
    raise exception 'CLOVEERP_IMPORT_ALREADY_ACTIVATED: % was activated on %', b.code, b.activated_at::date
      using errcode = '23514', hint = 'Nothing is left to activate; change a record on the desk.';
  end if;

  if b.object_type = 'party_profile' then
    update erp.party p set status = 'active', updated_at = now()
      from erp.import_row r
     where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id and r.loaded
       and coalesce((r.loaded_ref ->> 'created')::boolean, false)
       and p.tenant_id = v_tenant and p.id = (r.loaded_ref ->> 'party_id')::uuid
       and p.status = 'draft';
  else
    -- A product the legacy system called obsolete stays discontinued.
    update erp.item i set status = 'active',
           lifecycle = case when i.lifecycle = 'draft' then 'active'::erp.item_lifecycle else i.lifecycle end,
           updated_at = now()
      from erp.import_row r
     where r.tenant_id = v_tenant and r.import_batch_id = p_batch_id and r.loaded
       and coalesce((r.loaded_ref ->> 'created')::boolean, false)
       and i.tenant_id = v_tenant and i.id = (r.loaded_ref ->> 'item_id')::uuid
       and i.status = 'draft';
  end if;
  get diagnostics v_n = row_count;

  update erp.import_batch x
     set activated_at = now(), activated_by = erp.current_principal_id(), updated_at = now()
   where x.tenant_id = v_tenant and x.id = p_batch_id and x.activated_at is null;
  return v_n;
end;
$$;

comment on function erp.activate_import_batch is
  'Sets the drafts a loaded party_profile or item_profile batch created active together, and ends the batch''s '
  'rollback window. Needs master_data.import and master_data.write (20261003900000).';

create or replace function erp.guard_activated_import()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.activated_at is not null
     and (new.status is distinct from old.status or new.activated_at is distinct from old.activated_at) then
    raise exception 'CLOVEERP_IMPORT_ACTIVATED: % was activated on %, which ended its rollback window', old.code, old.activated_at::date
      using errcode = '23514',
            hint = 'People can trade with the records now; correct or withdraw them on the desk.';
  end if;
  return new;
end;
$$;

revoke all on function erp.guard_activated_import() from public, anon, authenticated;

drop trigger if exists t_import_batch_activated on erp.import_batch;
create trigger t_import_batch_activated
  before update on erp.import_batch
  for each row execute function erp.guard_activated_import();

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. The doors
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_activate_import_batch(p_batch_id uuid)
returns jsonb
language sql
volatile
set search_path = ''
as $$ select jsonb_build_object('activated', erp.activate_import_batch(p_batch_id)) $$;

create or replace function public.erp_record_control_evidence(
  p_batch_id uuid, p_printed_minor bigint, p_printed_quantity numeric, p_exclusions jsonb)
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.record_control_evidence(p_batch_id, p_printed_minor, p_printed_quantity, p_exclusions) $$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_activate_import_batch(uuid)',
    'erp_record_control_evidence(uuid, bigint, numeric, jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

comment on function public.erp_activate_import_batch(uuid) is
  'Sets a loaded contacts or products batch''s drafts active together; ends its rollback window (20261003900000).';
comment on function public.erp_record_control_evidence(uuid, bigint, numeric, jsonb) is
  'Keeps the printed figure and the held-back lines behind an opening batch''s control total (20261003900000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_activate_import_batch', 'erp.activate_import_batch',
   'Sets the drafts a loaded contacts or products batch created active and records who did it, which ends the rollback window; authorises master_data.import and master_data.write.'),
  ('erp_record_control_evidence', 'erp.record_control_evidence',
   'Keeps the working behind an opening batch''s control total beside the batch before it loads; authorises master_data.import and refuses working that does not come to the total.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- The batch list says which batches are live.
do $list$
declare
  v_sig    constant text := 'public.erp_import_batches(integer)';
  v_def    text := pg_get_functiondef('public.erp_import_batches(integer)'::regprocedure);
  v_needle constant text := '''rolled_back_at'', b.rolled_back_at,';
  v_hits   integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 or position('activated_at' in v_def) > 0 then
    raise exception 'CLOVEERP_IMPORT_LIST_UNRECOGNISED: expected the rollback date once in %, found %', v_sig, v_hits
      using hint = 'The deployed body is not the one this migration patches; restate it from pg_get_functiondef.';
  end if;
  execute replace(v_def, v_needle, v_needle || ' ''activated_at'', b.activated_at,');
end
$list$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.exact_stock_and_activation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  ra       record;
  v_uom    text;
  v_uom_id uuid;
  v_site   text;
  v_site_id uuid;
  v_loc    text := 'ZZL' || upper(substr(v_tag, 1, 5));
  v_avg    uuid;
  v_fifo   uuid;
  v_avg_code  text := 'ZZSA' || upper(v_tag);
  v_fifo_code text := 'ZZSF' || upper(v_tag);
  v_good   uuid; v_bad uuid; v_ff uuid; v_ib uuid; v_pb uuid;
  v_n      integer;
  v_err    text;
  v_fig    bigint;
  v_x      jsonb;
begin
  begin
    v_step := 'an organisation with its demonstration configuration';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant(
      'xsa-' || v_tag, 'Exact Stock Suite', 'a@xs-' || v_tag || '.test', 'A Admin');
    update erp.environment set is_live = false where tenant_id = ra.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'a@xs-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform erp.ensure_demo_configuration(ra.tenant_id, ra.admin_user_id);

    v_step := 'two products, one costed FIFO, and a location to hold them';
    select u.code, u.id into v_uom, v_uom_id from erp.uom u
     where u.tenant_id = ra.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active' order by u.code limit 1;
    select s.code, s.id into v_site, v_site_id from erp.site s
     where s.tenant_id = ra.tenant_id and s.status = 'active' order by s.code limit 1;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (ra.tenant_id, v_site_id, v_loc, 'Suite bulk', 'bulk', 'active');
    v_avg := erp.create_item(v_avg_code, 'Average fixing', v_uom_id);
    v_fifo := erp.create_item(v_fifo_code, 'FIFO fixing', v_uom_id);
    insert into erp.costing_policy (tenant_id, code, name, method, item_id, status)
    values (ra.tenant_id, 'ZZF' || upper(v_tag), 'Suite FIFO', 'fifo', v_fifo, 'active'),
           (ra.tenant_id, 'ZZA' || upper(v_tag), 'Suite average', 'average', v_avg, 'active');

    -- 1. The working behind a control total is kept.
    v_step := 'staging opening stock with its working';
    v_good := erp.stage_opening_balances('stock', current_date, jsonb_build_array(
      jsonb_build_object('item', v_avg_code, 'site', v_site, 'location', v_loc,
                         'quantity', 3, 'unit_cost_minor', 33, 'value_minor', 100)),
      100, null, 'XSG-' || v_tag);
    v_x := erp.record_control_evidence(v_good, 150, null, jsonb_build_array(
      jsonb_build_object('line', 9, 'label', 'OLD at MAIN', 'reason', 'negative quantity', 'amount_minor', 50, 'quantity', '-1')));
    v_cases := v_cases + 1;
    case_name := 'the printed total and each line held back are kept beside the batch';
    passed := (select b.control_evidence ->> 'printed_minor' from erp.import_batch b where b.id = v_good) = '150'
      and (select jsonb_array_length(b.control_evidence -> 'exclusions') from erp.import_batch b where b.id = v_good) = 1
      and (v_x ->> 'held_back_minor')::bigint = 50;
    detail := coalesce(v_x::text, 'nothing kept');
    return next;

    -- 2. Working that does not come to the control total is refused.
    v_err := null;
    begin
      perform erp.record_control_evidence(v_good, 160, null, jsonb_build_array(
        jsonb_build_object('label', 'OLD at MAIN', 'reason', 'negative quantity', 'amount_minor', 50)));
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'working that does not come to the control total is refused';
    passed := v_err like 'CLOVEERP_CONTROL_EVIDENCE_DISAGREES:%'
      and (select b.control_evidence ->> 'printed_minor' from erp.import_batch b where b.id = v_good) = '150';
    detail := coalesce(v_err, 'it was kept');
    return next;

    -- 3. A value within a penny a unit of quantity × unit cost validates.
    v_step := 'validating the good batch';
    v_n := erp.validate_import(v_good);
    v_cases := v_cases + 1;
    case_name := 'a value within a penny a unit of quantity × unit cost validates clean';
    passed := v_n = 0;
    detail := coalesce((select string_agg(r.findings::text, '; ') from erp.import_row r where r.import_batch_id = v_good), 'no rows');
    return next;

    -- 4. A value far from it, a negative one, and an inexact one on FIFO are refused.
    v_step := 'validating a bad batch';
    v_bad := erp.stage_opening_balances('stock', current_date, jsonb_build_array(
      jsonb_build_object('item', v_avg_code, 'site', v_site, 'location', v_loc, 'quantity', 3, 'unit_cost_minor', 33, 'value_minor', 500),
      jsonb_build_object('item', v_avg_code, 'site', v_site, 'location', v_loc, 'quantity', 3, 'unit_cost_minor', 33, 'value_minor', -1),
      jsonb_build_object('item', v_fifo_code, 'site', v_site, 'location', v_loc, 'quantity', 3, 'unit_cost_minor', 33, 'value_minor', 100)),
      599, null, 'XSB-' || v_tag);
    v_n := erp.validate_import(v_bad);
    v_cases := v_cases + 1;
    case_name := 'a value that is not quantity × unit cost, a negative value, and an inexact value on a FIFO product are each refused';
    passed := v_n = 3
      and (select r.findings::text from erp.import_row r where r.import_batch_id = v_bad and r.row_no = 1) like '%to within a penny a unit%'
      and (select r.findings::text from erp.import_row r where r.import_batch_id = v_bad and r.row_no = 2) like '%cannot be negative%'
      and (select r.findings::text from erp.import_row r where r.import_batch_id = v_bad and r.row_no = 3) like '%costed FIFO%average%';
    detail := coalesce((select string_agg(r.row_no || ': ' || r.findings::text, '; ' order by r.row_no)
                          from erp.import_row r where r.import_batch_id = v_bad), 'no rows');
    return next;

    -- 5. Loaded, the value is exact everywhere it is kept.
    v_step := 'loading the good batch';
    v_fig := erp.migration_figure_stock(current_date);
    perform erp.preview_import(v_good);
    perform erp.load_import(v_good);
    v_cases := v_cases + 1;
    case_name := 'the stated value is the movement''s cost, the value on hand, the journal and the batch total, and the control total reconciles';
    passed := (select m.cost_minor from erp.stock_movement m
                where m.tenant_id = ra.tenant_id and m.item_id = v_avg and m.movement_type = 'opening_balance') = 100
      and (select sum(c.value_minor) from erp.item_cost c where c.tenant_id = ra.tenant_id and c.item_id = v_avg) = 100
      and (select sum(jl.debit_minor) from erp.journal_line jl join erp.import_batch b on b.journal_id = jl.journal_id where b.id = v_good) = 100
      and (select b.loaded_total_minor from erp.import_batch b where b.id = v_good) = 100
      and (select bool_and(c.passes) from erp.opening_balance_reconciliation(v_good) c where c.check_code = 'control_total');
    detail := format('value on hand %s, loaded %s',
      (select sum(c.value_minor) from erp.item_cost c where c.tenant_id = ra.tenant_id and c.item_id = v_avg),
      (select b.loaded_total_minor from erp.import_batch b where b.id = v_good));
    return next;

    -- 6. The parallel-run figure counts it at that value.
    v_cases := v_cases + 1;
    case_name := 'the parallel-run stock figure moves by the stated value, not by quantity × unit cost';
    passed := erp.migration_figure_stock(current_date) - v_fig = 100;
    detail := format('moved by %s', erp.migration_figure_stock(current_date) - v_fig);
    return next;

    -- 7. FIFO takes a whole-penny value, and never an inexact one.
    v_step := 'loading a FIFO product';
    v_ff := erp.stage_opening_balances('stock', current_date, jsonb_build_array(
      jsonb_build_object('item', v_fifo_code, 'site', v_site, 'location', v_loc, 'quantity', 2, 'unit_cost_minor', 50, 'value_minor', 100)),
      100, null, 'XSF-' || v_tag);
    perform erp.validate_import(v_ff);
    perform erp.preview_import(v_ff);
    perform erp.load_import(v_ff);
    v_err := null;
    begin
      perform erp.receive_cost_at(v_fifo, v_site_id, 3, 33, 100, 'GBP');
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a FIFO product loads at a whole-penny value into a layer, and an inexact value is refused before it reaches one';
    passed := exists (select 1 from erp.stock_valuation_layer l
                       where l.tenant_id = ra.tenant_id and l.item_id = v_fifo and l.unit_cost_minor = 50 and l.quantity = 2)
      and v_err like 'CLOVEERP_FIFO_COST_NOT_EXACT:%'
      and not exists (select 1 from erp.stock_valuation_layer l
                       where l.tenant_id = ra.tenant_id and l.item_id = v_fifo and l.unit_cost_minor = 33);
    detail := coalesce(v_err, 'the inexact value was taken');
    return next;

    -- A contact and two products, loaded as drafts.
    v_step := 'loading a contact and two products';
    v_pb := erp.stage_import('party_profile', jsonb_build_array(
      jsonb_build_object('source', 'xero', 'legacy_key', 'Suite Party ' || v_tag,
                         'code', 'ZZPA' || upper(v_tag), 'name', 'Suite Party ' || v_tag)),
      'XSP-' || v_tag, 'suite');
    perform erp.validate_import(v_pb);
    perform erp.preview_import(v_pb);
    perform erp.load_import(v_pb);
    v_ib := erp.stage_import('item_profile', jsonb_build_array(
      jsonb_build_object('source', 'unleashed', 'code', 'ZZAI' || upper(v_tag), 'name', 'Goes live', 'stock_uom', v_uom),
      jsonb_build_object('source', 'unleashed', 'code', 'ZZAO' || upper(v_tag), 'name', 'Obsolete', 'stock_uom', v_uom,
                         'lifecycle', 'discontinued')),
      'XSI-' || v_tag, 'suite');
    perform erp.validate_import(v_ib);
    perform erp.preview_import(v_ib);
    perform erp.load_import(v_ib);

    -- 8. Activation needs master_data.write.
    v_step := 'activating without master_data.write';
    delete from erp.role_permission rp where rp.tenant_id = ra.tenant_id and rp.role_id = ra.role_id and rp.permission_code = 'master_data.write';
    v_err := null;
    begin
      perform erp.activate_import_batch(v_ib);
    exception when others then v_err := left(sqlerrm, 200); end;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (ra.tenant_id, ra.role_id, 'master_data.write') on conflict do nothing;
    v_cases := v_cases + 1;
    case_name := 'activating imported records needs master_data.write';
    passed := v_err like 'CLOVEERP_PERMISSION_DENIED:%master_data.write%'
      and (select i.status::text from erp.item i where i.tenant_id = ra.tenant_id and i.code = 'ZZAI' || upper(v_tag)) = 'draft';
    detail := coalesce(v_err, 'it activated');
    return next;

    -- 9. Activated, the drafts go live together; an obsolete product stays discontinued.
    v_step := 'activating';
    v_n := erp.activate_import_batch(v_ib) + erp.activate_import_batch(v_pb);
    v_cases := v_cases + 1;
    case_name := 'activation sets a batch''s drafts active together, keeps an obsolete product discontinued, and records who did it';
    passed := v_n = 3
      and (select i.status::text || '/' || i.lifecycle::text from erp.item i where i.tenant_id = ra.tenant_id and i.code = 'ZZAI' || upper(v_tag)) = 'active/active'
      and (select i.status::text || '/' || i.lifecycle::text from erp.item i where i.tenant_id = ra.tenant_id and i.code = 'ZZAO' || upper(v_tag)) = 'active/discontinued'
      and (select p.status::text from erp.party p where p.tenant_id = ra.tenant_id and p.code = 'ZZPA' || upper(v_tag)) = 'active'
      and (select b.activated_at is not null and b.activated_by is not null from erp.import_batch b where b.id = v_ib);
    detail := format('%s record(s) activated', v_n);
    return next;

    -- 10. Activation ends the rollback window.
    v_step := 'rolling back an activated batch';
    v_err := null;
    begin
      perform erp.rollback_import(v_ib);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'an activated batch does not roll back';
    passed := v_err like 'CLOVEERP_IMPORT_ACTIVATED:%'
      and (select b.status::text from erp.import_batch b where b.id = v_ib) = 'loaded'
      and exists (select 1 from erp.item i where i.tenant_id = ra.tenant_id and i.code = 'ZZAI' || upper(v_tag));
    detail := coalesce(v_err, 'it rolled back');
    return next;

    -- 11. Only a batch that loads drafts is activated.
    v_err := null;
    begin
      perform erp.activate_import_batch(v_good);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'an opening balance batch, which is live when it loads, is not activated';
    passed := v_err like 'CLOVEERP_IMPORT_NOT_ACTIVATABLE:%';
    detail := coalesce(v_err, 'it activated');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_EXACT_STOCK_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'xsa-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_EXACT_STOCK_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.exact_stock_and_activation_suite() from public, anon, authenticated;

create or replace function erp_test.assert_exact_stock_and_activation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.exact_stock_and_activation_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_EXACT_STOCK_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Opening stock would load at a value other than the one stated, a control total would lose its working, or an import would go live, or roll back, when it should not. Read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_EXACT_STOCK_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('exact stock and activation: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_exact_stock_and_activation_suite() from public, anon;

comment on function erp_test.assert_exact_stock_and_activation_suite() is
  'Opening stock loads at the value stated, a control total keeps its working, and imported records go live together and then stand (20261003900000).';

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
