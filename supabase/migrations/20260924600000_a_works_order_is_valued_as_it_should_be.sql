set lock_timeout = '30s';

-- =============================================================================
-- 20260924600000  A works order is valued as it should be
-- -----------------------------------------------------------------------------
-- PR7, M2a: the first half of node M2 of docs/spec/simplification-review.md.
-- M2 is works order settlement; this half puts right what the ledger will be
-- told, so that the half that tells it (M2b) posts figures that are true and
-- can be undone.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * Each receipt of finished goods was valued at everything issued and every
--     hour booked so far, divided by that receipt alone. Two receipts of fifty
--     against an order for a hundred put its whole cost into stock twice: in
--     a probe organisation, 252,000 of stock for goods that cost 126,000. The
--     inventory account and the valuation drift apart from the first order.
--   * erp.works_order_variance() priced material at today's cost rather than
--     the standard frozen at release, against the whole order rather than what
--     was made, and added a yield line that counted the same shortfall again.
--   * Nothing could be undone. A component issued to the wrong order, output
--     taken in twice, an hour booked in error: there was no door for any of
--     them, and erp.reverse_stock_movement() moves neither the valuation nor
--     the order, and loses the order's number from the reversal.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * A production movement carries its works order (stock_movement.
--     works_order_id). Readers match on it, and on the order's number for the
--     movements written before it, which are append-only and stay as they are.
--   * Release freezes the standard in its two parts, material and labour, as
--     well as the whole.
--   * Output is taken in at the order's standard per unit, and the movement
--     carries what the valuation actually recorded, so the two cannot differ.
--     What it actually cost is what the variance measures.
--   * erp.works_order_variance() reads the frozen standard, allowed for what
--     was made: material, labour and relief (what went into stock, against the
--     standard allowed). The three add up to what the order still holds.
--   * Three doors undo: erp_return_works_order_issue (a component back to the
--     shelf), erp_reverse_works_order_output (finished goods taken back out),
--     and a booking of negative hours, which may not take an operation below
--     nought. Each moves the valuation and the order together.
--
-- Nothing here posts to the ledger. That is M2b's, and it rides on this.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. What the order is, recorded where it was needed
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.stock_movement add column if not exists works_order_id uuid;

do $fk$
begin
  if not exists (select 1 from pg_constraint where conname = 'stock_movement_tenant_id_works_order_id_fkey') then
    alter table erp.stock_movement
      add constraint stock_movement_tenant_id_works_order_id_fkey
      foreign key (tenant_id, works_order_id) references erp.works_order (tenant_id, id)
      on delete restrict;
  end if;
end
$fk$;

create index if not exists stock_movement_tenant_id_works_order_id_idx
  on erp.stock_movement (tenant_id, works_order_id) where works_order_id is not null;

comment on column erp.stock_movement.works_order_id is
  'The works order a production movement was made for (20260924600000). Movements '
  'written before it name the order only by its number, in reason_code.';

alter table erp.works_order add column if not exists standard_material_minor bigint;
alter table erp.works_order add column if not exists standard_labour_minor bigint;

comment on column erp.works_order.standard_material_minor is
  'The material part of the standard frozen at release (20260924600000).';
comment on column erp.works_order.standard_labour_minor is
  'The labour part of the standard frozen at release (20260924600000).';

-- An order released before this has only the whole. Its labour is what its
-- operations were planned to take at their rates, which have not moved; its
-- material is the rest.
update erp.works_order wo
   set standard_labour_minor = x.labour,
       standard_material_minor = wo.standard_cost_minor - x.labour
  from (select o.tenant_id, o.works_order_id,
               coalesce(sum(round((o.planned_setup_minutes + o.planned_run_minutes)
                                  / 60.0 * o.cost_rate_minor_per_hour)), 0)::bigint as labour
          from erp.works_order_operation o
         group by o.tenant_id, o.works_order_id) x
 where x.tenant_id = wo.tenant_id and x.works_order_id = wo.id
   and wo.standard_cost_minor is not null and wo.standard_labour_minor is null;

update erp.works_order wo
   set standard_labour_minor = 0, standard_material_minor = wo.standard_cost_minor
 where wo.standard_cost_minor is not null and wo.standard_labour_minor is null;

create or replace function erp.works_order_movement(p_movement_tenant uuid, p_movement_works_order uuid,
                                                    p_movement_reason text, p_works_order_id uuid,
                                                    p_order_number text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  -- Whether a movement belongs to a works order (20260924600000): by the order
  -- it carries, or, written before it carried one, by the order's number.
  select case when p_movement_works_order is not null then p_movement_works_order = p_works_order_id
              else p_movement_reason = p_order_number end
$$;

comment on function erp.works_order_movement(uuid, uuid, text, uuid, text) is
  'Whether a stock movement belongs to a works order: by works_order_id, or by the '
  'order''s number for movements written before the column (20260924600000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NOT_A_WORKS_ORDER_MOVEMENT',
  'Undoing, through a works order, a movement that is not one of that order''s issues or receipts.',
  'A works order returns only the components it was issued and reverses only the finished goods it took in.',
  'Choose an issue or a receipt of the works order from its movements.');

select erp.register_refusal('CLOVEERP_MOVEMENT_ALREADY_REVERSED',
  'Undoing a stock movement that has already been undone.',
  'A movement is undone once, by its mirror; undoing it again would move the stock twice.',
  'Nothing more is needed. If the stock is still wrong, record what did happen as a movement of its own.');

select erp.register_refusal('CLOVEERP_WORKS_ORDER_FINISHED',
  'Undoing an issue or a receipt on a works order that is closed or cancelled.',
  'A closed order has been settled on what it used and made; a cancelled one used and made nothing.',
  'Record the correction on the order still open, or as a stock adjustment with a reason.');

select erp.register_refusal('CLOVEERP_BOOKING_BELOW_NOUGHT',
  'Taking hours off an operation beyond those it has booked.',
  'Hours are corrected down by booking a negative amount, and an operation cannot have worked less than nothing.',
  'Take off no more than the operation has booked.');

select erp.register_refusal('CLOVEERP_UNDO_NEEDS_A_REASON',
  'Undoing an issue or a receipt of a works order without saying why.',
  'The mirror movement stands in the stock history beside the one it undoes, and the reason is what explains the pair.',
  'Say why it is being undone.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. Release freezes the standard in its parts
-- ─────────────────────────────────────────────────────────────────────────────

do $release$
declare
  v_sig constant text := 'erp.release_works_order(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o1$  select v_std + coalesce(sum(round((o.planned_setup_minutes + o.planned_run_minutes)$o1$;
  v_new1 constant text := $n1$  v_mat := v_std;

  select v_std + coalesce(sum(round((o.planned_setup_minutes + o.planned_run_minutes)$n1$;
  v_old2 constant text := $o2$     set standard_cost_minor = v_std, updated_at = now()$o2$;
  v_new2 constant text := $n2$     set standard_cost_minor = v_std,
         -- In its parts as well (20260924600000), so the variance can say which
         -- part the order missed by.
         standard_material_minor = v_mat,
         standard_labour_minor = v_std - v_mat,
         updated_at = now()$n2$;
  v_old3 constant text := $o3$  v_std    bigint := 0;$o3$;
  v_new3 constant text := $n3$  v_std    bigint := 0;
  v_mat    bigint := 0;$n3$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % labour anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % update anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % declaration anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$release$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. An issue carries its order, in the order's company's currency
-- ─────────────────────────────────────────────────────────────────────────────

do $issue$
declare
  v_sig constant text := 'erp.issue_to_works_order(uuid,uuid,numeric,uuid,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code)
  values (v_tenant, wo.entity_id, wo.site_id, 'production_issue',
          p_component_item_id, p_batch_id, v_loc, 'available', p_quantity,
          c.uom_id, v_cost,
          coalesce((select e.base_currency from erp.entity e
                     where e.tenant_id = v_tenant limit 1), 'GBP'),
          wo.order_number)$o$;
  v_new constant text := $n$    from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code, works_order_id)
  values (v_tenant, wo.entity_id, wo.site_id, 'production_issue',
          p_component_item_id, p_batch_id, v_loc, 'available', p_quantity,
          c.uom_id, v_cost,
          -- The order's company's currency (20260924600000); it was the first
          -- company's, whichever that was.
          coalesce((select e.base_currency from erp.entity e
                     where e.tenant_id = v_tenant and e.id = wo.entity_id), 'GBP'),
          wo.order_number, p_works_order_id)$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % movement anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old, v_new);
end
$issue$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. Output is taken in at the order's standard, and says what it recorded
-- ─────────────────────────────────────────────────────────────────────────────

do $receive$
declare
  v_sig constant text := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o1$  -- What it actually cost: the components issued plus the time booked. The
  -- output is valued at that, which is what makes the variance at close real
  -- rather than an assumption.
  select coalesce(sum(round(m.quantity * m.unit_cost_minor)), 0)::bigint
    into v_issued
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.reason_code = wo.order_number
     and m.movement_type = 'production_issue' and not m.is_reversal;$o1$;
  v_new1 constant text := $n1$  -- What it has actually cost so far: the components issued, less any
  -- returned, plus the time booked. Kept on the order to be read; it no longer
  -- values the receipt (20260924600000).
  select coalesce(sum(case when m.is_reversal then -1 else 1 end
                      * coalesce(m.cost_minor, round(m.quantity * m.unit_cost_minor))), 0)::bigint
    into v_issued
    from erp.stock_movement m
   where m.tenant_id = v_tenant
     and erp.works_order_movement(m.tenant_id, m.works_order_id, m.reason_code,
                                  p_works_order_id, wo.order_number)
     and m.movement_type = 'production_issue';$n1$;
  v_old2 constant text := $o2$  v_cost := case when p_quantity > 0
                 then round((v_issued + v_labour) / p_quantity)::bigint else 0 end;$o2$;
  v_new2 constant text := $n2$  -- Taken in at the order's standard per unit (20260924600000). Every
  -- receipt of a hundred is valued alike, where each was valued at the whole
  -- cost to date divided by itself, and what it actually cost against that is
  -- the variance, measured at close.
  v_cost := case when coalesce(wo.quantity, 0) > 0
                 then round(coalesce(wo.standard_cost_minor, v_issued + v_labour) / wo.quantity)::bigint
                 else 0 end;$n2$;
  v_old3 constant text := $o3$  perform erp.receive_cost(wo.item_id, wo.site_id, p_quantity, v_cost,
                           coalesce((select e.base_currency from erp.entity e
                                      where e.tenant_id = v_tenant limit 1), 'GBP'),
                           v_batch, null);$o3$;
  v_new3 constant text := $n3$  -- The movement carries what the valuation recorded: at standard for an
  -- item costed at standard, the unit given for one costed otherwise.
  v_cost := erp.receive_cost(wo.item_id, wo.site_id, p_quantity, v_cost,
                             coalesce((select e.base_currency from erp.entity e
                                        where e.tenant_id = v_tenant and e.id = wo.entity_id), 'GBP'),
                             v_batch, null);$n3$;
  v_old4 constant text := $o4$          p_quantity, wo.uom_id, v_cost,
          coalesce((select e.base_currency from erp.entity e
                     where e.tenant_id = v_tenant limit 1), 'GBP'),
          wo.order_number);$o4$;
  v_new4 constant text := $n4$          p_quantity, wo.uom_id, v_cost,
          coalesce((select e.base_currency from erp.entity e
                     where e.tenant_id = v_tenant and e.id = wo.entity_id), 'GBP'),
          wo.order_number, p_works_order_id);$n4$;
  v_old5 constant text := $o5$    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code)$o5$;
  v_new5 constant text := $n5$    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code, works_order_id)$n5$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % issued anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % unit anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % valuation anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old4, ''))) / length(v_old4);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % values anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old5, ''))) / length(v_old5);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % columns anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(replace(replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2),
                                  v_old3, v_new3), v_old4, v_new4), v_old5, v_new5);
end
$receive$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. Hours are corrected down, never below nought
-- ─────────────────────────────────────────────────────────────────────────────

do $book$
declare
  v_sig constant text := 'erp.book_operation_time(uuid,integer,numeric,numeric,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  update erp.works_order_operation
     set actual_minutes = actual_minutes + p_minutes,$o$;
  v_new constant text := $n$  -- Hours are taken off by booking a negative amount (20260924600000), and no
  -- operation may have worked less than nothing.
  if p_minutes < 0 and wo.status = 'closed' then
    raise exception 'CLOVEERP_WORKS_ORDER_FINISHED: % is closed, and its hours are settled', wo.order_number
      using errcode = '23514', hint = 'Record the correction on the order still open, or as a stock adjustment with a reason.';
  end if;
  if p_minutes < 0 and exists (
       select 1 from erp.works_order_operation o
        where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id
          and o.seq = p_operation_seq and o.actual_minutes + p_minutes < 0) then
    raise exception 'CLOVEERP_BOOKING_BELOW_NOUGHT: operation % on % has not booked % minutes to take off',
      p_operation_seq, wo.order_number, -p_minutes
      using errcode = '23514', hint = 'Take off no more than the operation has booked.';
  end if;

  update erp.works_order_operation
     set actual_minutes = actual_minutes + p_minutes,$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % operation anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old, v_new);
end
$book$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. The variance reads the frozen standard, allowed for what was made
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.works_order_variance(p_works_order_id uuid)
 returns table(kind text, standard_minor bigint, actual_minor bigint, variance_minor bigint, explanation text)
 language sql
 stable
 set search_path to ''
as $function$
  -- Against the standard frozen at release, allowed for what was made
  -- (20260924600000). The three lines add up to what the order still holds:
  -- material and labour put in, less what went into stock.
  with wo as (
    select w.*,
           case when coalesce(w.quantity, 0) > 0 then w.quantity_completed / w.quantity else 0 end as made
      from erp.works_order w
     where w.tenant_id = erp.current_tenant_id() and w.id = p_works_order_id
  ),
  movements as (
    select m.movement_type,
           sum(case when m.is_reversal then -1 else 1 end
               * coalesce(m.cost_minor, round(m.quantity * m.unit_cost_minor)))::bigint as amt
      from erp.stock_movement m, wo
     where m.tenant_id = wo.tenant_id
       and erp.works_order_movement(m.tenant_id, m.works_order_id, m.reason_code, wo.id, wo.order_number)
       and m.movement_type in ('production_issue', 'production_output')
     group by m.movement_type
  ),
  labour as (
    select coalesce(sum(round(o.actual_minutes / 60.0 * o.cost_rate_minor_per_hour)), 0)::bigint as act
      from erp.works_order_operation o, wo
     where o.tenant_id = wo.tenant_id and o.works_order_id = wo.id
  ),
  std as (
    select round(coalesce(wo.standard_material_minor, 0) * wo.made)::bigint as material,
           round(coalesce(wo.standard_labour_minor, 0) * wo.made)::bigint as labour
      from wo
  ),
  act as (
    select coalesce((select amt from movements where movement_type = 'production_issue'), 0) as material,
           (select act from labour) as labour,
           coalesce((select amt from movements where movement_type = 'production_output'), 0) as relieved
  )
  -- Split, because "we used more material" and "it took longer" are different
  -- problems with different owners, and one number cannot say which happened.
  select 'material', std.material, act.material, act.material - std.material,
         case when act.material > std.material
              then 'more material was consumed than the standard allows for what was made'
              else 'no more material was consumed than the standard allows for what was made' end
    from std, act
  union all
  select 'labour', std.labour, act.labour, act.labour - std.labour,
         case when act.labour > std.labour
              then 'the operations took longer than the standard allows for what was made'
              else 'the operations took no longer than the standard allows for what was made' end
    from std, act
  union all
  -- What went into stock, against the standard allowed for it. Nought where
  -- the finished good is taken in at the order's own standard, but for
  -- rounding; otherwise what an item costed at a standard of its own, or a
  -- receipt past the order, relieved differently.
  -- Here the standard is what went into stock ought to have been, the actual
  -- is what did, and the line is what the order holds for it: the allowance
  -- less the relief.
  select 'relief', std.material + std.labour, act.relieved,
         (std.material + std.labour) - act.relieved,
         'the standard allowed for what was made, against what went into stock'
    from std, act
$function$;

comment on function erp.works_order_variance(uuid) is
  'A works order''s material, labour and relief variances against the standard frozen '
  'at release, allowed for what was made (20260924600000). They add up to what the '
  'order still holds.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. What can be undone, and the doors that undo it
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.production_event drop constraint if exists production_event_event_kind_check;
alter table erp.production_event add constraint production_event_event_kind_check
  check (event_kind = any (array['released', 'started', 'issued', 'completed', 'scrapped',
                                 'time_booked', 'deviation', 'output_received', 'closed',
                                 'cancelled', 'returned', 'output_reversed']));

create or replace function erp.return_works_order_issue(p_movement_id bigint, p_reason text)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  m        erp.stock_movement%rowtype;
  wo       erp.works_order%rowtype;
  v_unit   bigint;
  v_new    bigint;
begin
  select * into m from erp.stock_movement
   where tenant_id = v_tenant and id = p_movement_id;
  if not found then
    raise exception 'CLOVEERP_MOVEMENT_NOT_FOUND: %', p_movement_id using errcode = '23503';
  end if;

  select * into wo from erp.works_order w
   where w.tenant_id = v_tenant
     and erp.works_order_movement(m.tenant_id, m.works_order_id, m.reason_code, w.id, w.order_number)
   for update;
  if not found or m.movement_type <> 'production_issue' or m.is_reversal then
    raise exception 'CLOVEERP_NOT_A_WORKS_ORDER_MOVEMENT: movement % is not a component issued to a works order', p_movement_id
      using errcode = '23514', hint = 'Choose an issue or a receipt of the works order from its movements.';
  end if;

  perform erp.authorise('production.execute', wo.entity_id, wo.site_id, null,
                        'works_order', wo.id);

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_UNDO_NEEDS_A_REASON: say why the issue to % is being returned', wo.order_number
      using errcode = '22023', hint = 'Say why it is being undone.';
  end if;
  if wo.status in ('closed', 'cancelled') then
    raise exception 'CLOVEERP_WORKS_ORDER_FINISHED: % is %, and what it used is settled', wo.order_number, wo.status
      using errcode = '23514', hint = 'Record the correction on the order still open, or as a stock adjustment with a reason.';
  end if;
  if exists (select 1 from erp.stock_movement r
              where r.tenant_id = v_tenant and r.reverses_movement_id = p_movement_id) then
    raise exception 'CLOVEERP_MOVEMENT_ALREADY_REVERSED: % has already been reversed', p_movement_id
      using errcode = '23514',
            hint = 'Nothing more is needed. If the stock is still wrong, record what did happen as a movement of its own.';
  end if;

  -- Back to the shelf at what it left at, and the valuation with it.
  v_unit := erp.receive_cost(m.item_id, m.site_id, m.quantity,
                             coalesce(round(m.cost_minor / nullif(m.quantity, 0))::bigint, m.unit_cost_minor, 0),
                             m.currency, m.batch_id, null);

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
    to_location_id, to_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code, reverses_movement_id, is_reversal, works_order_id)
  values (m.tenant_id, m.entity_id, m.site_id, m.movement_type, m.item_id, m.batch_id, m.serial_id,
          m.from_location_id, m.from_status, m.quantity, m.uom_id, v_unit, m.currency,
          wo.order_number, m.id, true, wo.id)
  returning id into v_new;

  -- One line, as the issue drew on one (found on review: an item on two
  -- lines took the return off both).
  update erp.works_order_component
     set issued_quantity = issued_quantity - m.quantity, updated_at = now()
   where id = (select c.id from erp.works_order_component c
                where c.tenant_id = v_tenant and c.works_order_id = wo.id
                  and c.item_id = m.item_id and c.issued_quantity >= m.quantity
                order by c.seq limit 1);
  if not found then
    raise exception 'CLOVEERP_NOT_A_WORKS_ORDER_MOVEMENT: % holds no issue of % to return it from', wo.order_number, m.quantity
      using errcode = '23514', hint = 'Choose an issue or a receipt of the works order from its movements.';
  end if;

  insert into erp.production_event (
    tenant_id, works_order_id, event_kind, item_id, batch_id, quantity, detail, actor_id)
  values (v_tenant, wo.id, 'returned', m.item_id, m.batch_id, m.quantity,
          jsonb_build_object('movement_id', m.id, 'returned_by', v_new, 'reason', btrim(p_reason)),
          erp.current_principal_id());

  return v_new;
end;
$$;

revoke all on function erp.return_works_order_issue(bigint, text) from public, anon;

comment on function erp.return_works_order_issue(bigint, text) is
  'Returns a component issued to an open works order to the shelf, with a reason: the '
  'stock, its valuation and the order''s issued quantity together (20260924600000). '
  'Authorises production.execute.';

create or replace function erp.withdraw_receipt_cost(p_item_id uuid, p_site_id uuid, p_quantity numeric,
                                                      p_cost_minor bigint, p_unit_cost_minor bigint)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_method erp.costing_method := erp.costing_method_for(p_item_id, p_site_id);
  ic       erp.item_cost%rowtype;
  r        record;
  v_left   numeric := p_quantity;
  v_take   numeric;
  v_unit   bigint := round(p_cost_minor / p_quantity)::bigint;
begin
  -- A receipt undone takes out what it put in, and nothing of the stock that
  -- was there before it (found on review: taken out at today's valuation, it
  -- moved the value of the stock already on hand into the order).
  if p_quantity <= 0 then
    raise exception 'CLOVEERP_COST_NONPOSITIVE: cannot withdraw % units', p_quantity using errcode = '23514';
  end if;

  if v_method = 'fifo' then
    -- The receipt's own layer, newest first among those at its price.
    for r in
      select * from erp.stock_valuation_layer l
       where l.tenant_id = v_tenant and l.item_id = p_item_id
         and l.site_id is not distinct from p_site_id
         and l.unit_cost_minor = p_unit_cost_minor and l.remaining > 0
       order by l.received_at desc, l.id desc
       for update
    loop
      exit when v_left <= 0;
      v_take := least(v_left, r.remaining);
      update erp.stock_valuation_layer set remaining = remaining - v_take, updated_at = now()
       where id = r.id;
      v_left := v_left - v_take;
    end loop;
    if v_left > 0 then
      raise exception 'CLOVEERP_RECEIPT_ALREADY_USED: % of the % units taken in have already left at their cost', v_left, p_quantity
        using errcode = '23514',
              hint = 'The goods have been issued, sold or moved since. Record what happened to them instead.';
    end if;
    perform erp.note_cost(p_item_id, p_site_id, p_quantity, v_unit, p_cost_minor);
    return v_unit;
  end if;

  select * into ic from erp.item_cost c
   where c.tenant_id = v_tenant and c.item_id = p_item_id
     and c.site_id is not distinct from p_site_id
   for update;
  if not found or ic.quantity_on_hand < p_quantity then
    raise exception 'CLOVEERP_RECEIPT_ALREADY_USED: fewer than % units are held at their cost to take back out', p_quantity
      using errcode = '23514',
            hint = 'The goods have been issued, sold or moved since. Record what happened to them instead.';
  end if;

  update erp.item_cost
     set quantity_on_hand = quantity_on_hand - p_quantity,
         value_minor = value_minor - p_cost_minor,
         unit_cost_minor = case when v_method = 'standard' then unit_cost_minor
                                when quantity_on_hand - p_quantity = 0 then unit_cost_minor
                                else round((value_minor - p_cost_minor) / (quantity_on_hand - p_quantity))::bigint end,
         updated_at = now()
   where id = ic.id;
  perform erp.note_cost(p_item_id, p_site_id, p_quantity, v_unit, p_cost_minor);
  return v_unit;
end;
$$;

revoke all on function erp.withdraw_receipt_cost(uuid, uuid, numeric, bigint, bigint) from public, anon;

comment on function erp.withdraw_receipt_cost(uuid, uuid, numeric, bigint, bigint) is
  'Takes a receipt back out of the valuation at exactly what it put in: its own FIFO '
  'layer, or its value off an average or standard position (20260924600000).';

create or replace function erp.reverse_works_order_output(p_movement_id bigint, p_reason text)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  m        erp.stock_movement%rowtype;
  wo       erp.works_order%rowtype;
  v_unit   bigint;
  v_new    bigint;
begin
  select * into m from erp.stock_movement
   where tenant_id = v_tenant and id = p_movement_id;
  if not found then
    raise exception 'CLOVEERP_MOVEMENT_NOT_FOUND: %', p_movement_id using errcode = '23503';
  end if;

  select * into wo from erp.works_order w
   where w.tenant_id = v_tenant
     and erp.works_order_movement(m.tenant_id, m.works_order_id, m.reason_code, w.id, w.order_number)
   for update;
  if not found or m.movement_type <> 'production_output' or m.is_reversal then
    raise exception 'CLOVEERP_NOT_A_WORKS_ORDER_MOVEMENT: movement % is not finished goods a works order took in', p_movement_id
      using errcode = '23514', hint = 'Choose an issue or a receipt of the works order from its movements.';
  end if;

  perform erp.authorise('production.execute', wo.entity_id, wo.site_id, null,
                        'works_order', wo.id);

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_UNDO_NEEDS_A_REASON: say why the receipt on % is being reversed', wo.order_number
      using errcode = '22023', hint = 'Say why it is being undone.';
  end if;
  if wo.status in ('closed', 'cancelled') then
    raise exception 'CLOVEERP_WORKS_ORDER_FINISHED: % is %, and what it made is settled', wo.order_number, wo.status
      using errcode = '23514', hint = 'Record the correction on the order still open, or as a stock adjustment with a reason.';
  end if;
  if exists (select 1 from erp.stock_movement r
              where r.tenant_id = v_tenant and r.reverses_movement_id = p_movement_id) then
    raise exception 'CLOVEERP_MOVEMENT_ALREADY_REVERSED: % has already been reversed', p_movement_id
      using errcode = '23514',
            hint = 'Nothing more is needed. If the stock is still wrong, record what did happen as a movement of its own.';
  end if;

  -- Out of stock at exactly what it went in at, from where it was put. Stock
  -- already shipped or moved is refused, by the valuation or by the movement
  -- itself: a finished good may not go below nought where it was put.
  v_unit := erp.withdraw_receipt_cost(m.item_id, m.site_id, m.quantity,
                                      coalesce(m.cost_minor, round(m.quantity * m.unit_cost_minor)::bigint),
                                      m.unit_cost_minor);

  insert into erp.stock_movement (
    tenant_id, entity_id, site_id, movement_type, item_id, batch_id, serial_id,
    from_location_id, from_status, quantity, uom_id, unit_cost_minor, currency,
    reason_code, reverses_movement_id, is_reversal, works_order_id)
  values (m.tenant_id, m.entity_id, m.site_id, m.movement_type, m.item_id, m.batch_id, m.serial_id,
          m.to_location_id, m.to_status, m.quantity, m.uom_id, v_unit, m.currency,
          wo.order_number, m.id, true, wo.id)
  returning id into v_new;

  -- The order made less than it said. It stays where its lifecycle has it:
  -- an order that reads completed still takes in the goods it goes on to make.
  update erp.works_order
     set quantity_completed = quantity_completed - m.quantity, updated_at = now()
   where tenant_id = v_tenant and id = wo.id;

  insert into erp.production_event (
    tenant_id, works_order_id, event_kind, item_id, batch_id, quantity, detail, actor_id)
  values (v_tenant, wo.id, 'output_reversed', m.item_id, m.batch_id, m.quantity,
          jsonb_build_object('movement_id', m.id, 'reversed_by', v_new, 'reason', btrim(p_reason)),
          erp.current_principal_id());

  return v_new;
end;
$$;

revoke all on function erp.reverse_works_order_output(bigint, text) from public, anon;

comment on function erp.reverse_works_order_output(bigint, text) is
  'Takes finished goods a works order took in back out of stock, with a reason: the '
  'stock, its valuation and the order''s completed quantity together (20260924600000). '
  'Authorises production.execute.';

create or replace function public.erp_return_works_order_issue(p_movement_id bigint, p_reason text)
returns bigint
language sql
set search_path = ''
as $$ select erp.return_works_order_issue(p_movement_id, p_reason) $$;

create or replace function public.erp_reverse_works_order_output(p_movement_id bigint, p_reason text)
returns bigint
language sql
set search_path = ''
as $$ select erp.reverse_works_order_output(p_movement_id, p_reason) $$;

-- The movements a works order made, to choose one from.
create or replace function public.erp_works_order_movements(p_works_order_id uuid, p_kind text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'movement_id', m.id,
           'movement_type', m.movement_type,
           'kind', case m.movement_type when 'production_issue' then 'issue' else 'receipt' end,
           'item', i.code,
           'quantity', m.quantity,
           'occurred_at', m.occurred_at,
           'undone', exists (select 1 from erp.stock_movement r
                              where r.tenant_id = m.tenant_id and r.reverses_movement_id = m.id))
         order by m.occurred_at, m.id), '[]'::jsonb)
    from erp.works_order wo
    join erp.stock_movement m
      on m.tenant_id = wo.tenant_id
     and erp.works_order_movement(m.tenant_id, m.works_order_id, m.reason_code, wo.id, wo.order_number)
     and m.movement_type in ('production_issue', 'production_output')
     and not m.is_reversal
    join erp.item i on i.tenant_id = m.tenant_id and i.id = m.item_id
   where wo.tenant_id = erp.current_tenant_id()
     and wo.id = p_works_order_id
     and (p_kind is null
          or ((p_kind = 'issue' and m.movement_type = 'production_issue')
              or (p_kind = 'receipt' and m.movement_type = 'production_output'))
             -- What a person may choose to undo: not what is undone already.
             and not exists (select 1 from erp.stock_movement r
                              where r.tenant_id = m.tenant_id and r.reverses_movement_id = m.id))
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_return_works_order_issue(bigint, text)',
    'erp_reverse_works_order_output(bigint, text)',
    'erp_works_order_movements(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_return_works_order_issue', 'erp.return_works_order_issue',
   'Returns a component issued to an open works order to the shelf, with a reason, moving the stock, its valuation and the order together; authorises production.execute.'),
  ('erp_reverse_works_order_output', 'erp.reverse_works_order_output',
   'Takes finished goods an open works order took in back out of stock, with a reason, moving the stock, its valuation and the order together; authorises production.execute.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/production', array['erp_return_works_order_issue', 'erp_reverse_works_order_output']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A works order''s issues and receipts undone from the Manufacturing screen (20260924600000).'
  from (values
    ('Return materials to stock'),
    ('A component issued to an order still open, back on the shelf at what it left at. The order''s issued quantity and the stock''s value move with it.'),
    ('Issue to return'),
    ('Why it is returned'),
    ('Reverse finished goods taken in'),
    ('Finished goods an order still open took in, taken back out of stock. The order made less than it said; its stage does not move.'),
    ('Receipt to reverse'),
    ('Why it is reversed'),
    ('Only issues not already returned can be returned, once each.'),
    ('Only receipts not already reversed can be reversed, once each, while the goods are still where they were put.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- Nothing issued below nought, and no operation worked less than nothing,
-- whoever writes (found on review: two corrections at once each saw the
-- other's minutes). Checked on what is written from here.
alter table erp.works_order_component drop constraint if exists works_order_component_issued_not_negative;
alter table erp.works_order_component add constraint works_order_component_issued_not_negative
  check (issued_quantity >= 0) not valid;
alter table erp.works_order_operation drop constraint if exists works_order_operation_minutes_not_negative;
alter table erp.works_order_operation add constraint works_order_operation_minutes_not_negative
  check (actual_minutes >= 0) not valid;

select erp.register_refusal('CLOVEERP_RECEIPT_ALREADY_USED',
  'Reversing finished goods a works order took in after they have been issued, sold or moved.',
  'A receipt is undone by taking out exactly what it put in; goods that have left since are no longer there to take.',
  'Record what happened to the goods instead, as the movement or document that moved them.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The suites whose answer this changes
-- ─────────────────────────────────────────────────────────────────────────────

-- The finished good is taken in at the order's standard, not at everything
-- spent so far divided by the receipt.
do $prod$
declare
  v_sig constant text := 'erp_test.production_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  return query select 'the finished good is valued at what it actually cost',
    (select c.unit_cost_minor from erp.item_cost c
      where c.item_id = v_fg and c.site_id = v_site) > 0
    and (select m.unit_cost_minor from erp.stock_movement m
          where m.item_id = v_fg and m.movement_type = 'production_output') =
        (select round(wo.actual_cost_minor / 100)::bigint from erp.works_order wo
          where wo.id = v_wo),
    'components issued plus time booked, divided by what came out';$o$;
  v_new constant text := $n$  return query select 'the finished good is taken in at the standard its order froze, and what it actually cost is the variance',
    (select c.unit_cost_minor from erp.item_cost c
      where c.item_id = v_fg and c.site_id = v_site) > 0
    and (select m.unit_cost_minor from erp.stock_movement m
          where m.item_id = v_fg and m.movement_type = 'production_output') =
        (select round(wo.standard_cost_minor / wo.quantity)::bigint from erp.works_order wo
          where wo.id = v_wo)
    and (select m.cost_minor from erp.stock_movement m
          where m.item_id = v_fg and m.movement_type = 'production_output') =
        (select round(wo.standard_cost_minor / wo.quantity * 100)::bigint from erp.works_order wo
          where wo.id = v_wo),
    'the standard per unit, frozen at release (20260924600000)';$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % valuation case found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old, v_new);
end
$prod$;

-- The costing suite's variance case read material at today's layers on an
-- order nothing had been made of. The layers are read once, at release, into
-- the order's material standard; what the variance allows is that standard
-- for what was made, which before anything is made is nought.
do $fifo$
declare
  v_sig constant text := 'erp_test.fifo_is_costed_from_its_layers_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    select v.standard_minor into v_unit
      from erp.works_order_variance(v_wo) v where v.kind = 'material';
    select v.variance_minor into v_cost
      from erp.works_order_variance(v_wo) v where v.kind = 'yield';

    v_cases := v_cases + 1;
    case_name := 'the works order variance prices material and yield costed first in, first out at their layers, where it priced both at nought';
    passed := coalesce(v_unit = 3000 and v_cost = 3600, false);
    detail := format('material standard %s, yield %s', v_unit, v_cost);$o$;
  v_new constant text := $n$    select wo.standard_material_minor into v_unit
      from erp.works_order wo where wo.id = v_wo;
    select v.standard_minor into v_cost
      from erp.works_order_variance(v_wo) v where v.kind = 'material';

    v_cases := v_cases + 1;
    case_name := 'the works order''s material standard prices components costed first in, first out at their layers, and its variance allows none of it before anything is made';
    passed := coalesce(v_unit = 3000 and v_cost = 0, false);
    detail := format('material standard %s, allowed so far %s', v_unit, v_cost);$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % variance case found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old, v_new);
end
$fifo$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The proof: erp_test.works_order_valuation_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.works_order_valuation_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_tok   text;
  v_second uuid;
  csf uuid; csp uuid; csi uuid; csr uuid;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid;
  v_fg uuid; v_comp uuid; v_bom uuid; v_rout uuid; v_grn uuid;
  v_wo uuid; v_wo2 uuid;
  v_issue bigint; v_out1 bigint; v_out2 bigint; v_back bigint;
  v_val0 bigint; v_val1 bigint; v_on0 numeric; v_on1 numeric;
  v_sum bigint; v_wip bigint;
  v_err text; v_err2 text; v_err3 text;
begin
  -- 1. The rule a movement belongs to its order by.
  return query select 'a movement belongs to a works order by the order it carries, or, written before it carried one, by its number',
    erp.works_order_movement(null, null, 'WO-1', '00000000-0000-4000-8000-000000000001', 'WO-1')
    and not erp.works_order_movement(null, '00000000-0000-4000-8000-000000000002', 'WO-1',
                                     '00000000-0000-4000-8000-000000000001', 'WO-1')
    and erp.works_order_movement(null, '00000000-0000-4000-8000-000000000001', 'something else',
                                 '00000000-0000-4000-8000-000000000001', 'WO-1'),
    'by works_order_id, and by reason_code only where there is none';

  begin
    select * into r from erp.provision_tenant(
      'zz-wov-' || v_hex, 'Works order valuation suite',
      'a@zz-wov-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-wov-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csr := erp.configure_production('manual');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'production', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG', 'Finished good', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C1', 'Component', v_uom, 'active') returning id into v_comp;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG-1', v_fg, v_site, 1, 'Finished good', 1, 1, 'active', current_date - 1)
    returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom, 10, v_comp, 1, v_uom, 0, false);
    insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
    values (r.tenant_id, 'FG-R1', v_fg, v_site, 1, 'Assemble', 'active', current_date - 1)
    returning id into v_rout;
    -- Ten of FG: ten minutes to set up and one a unit, at sixty an hour.
    insert into erp.routing_operation (
      tenant_id, routing_id, seq, code, name, work_centre_code,
      setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
    values (r.tenant_id, v_rout, 10, 'ASM', 'Assembly', 'WC1', 10, 1, 6000);

    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 100, 100, 'component');
    -- A hundred of the finished good on hand already, at five hundred, so an
    -- undone receipt can be seen to leave them as they were.
    perform erp.add_document_line(v_grn, v_fg, 100, 500, 'finished good already held');
    perform erp.transition_document(v_grn, 'post');

    -- 2. The standard, in its parts.
    v_wo := erp.raise_works_order(v_fg, v_site, 10);
    perform erp.release_works_order(v_wo);
    return query select 'release freezes the standard in its parts: ten of the component at a hundred, and twenty minutes at sixty an hour',
      (select wo.standard_material_minor = 1000 and wo.standard_labour_minor = 2000
              and wo.standard_cost_minor = 3000
         from erp.works_order wo where wo.id = v_wo),
      (select format('material %s, labour %s, whole %s', wo.standard_material_minor,
                     wo.standard_labour_minor, wo.standard_cost_minor)
         from erp.works_order wo where wo.id = v_wo);

    -- 3. Receipts at the standard per unit, whatever has been spent so far.
    v_issue := erp.issue_to_works_order(v_wo, v_comp, 10);
    perform erp.book_operation_time(v_wo, 10, 30, 0, 0);
    select c.value_minor, c.quantity_on_hand into v_val0, v_on0
      from erp.item_cost c where c.item_id = v_fg and c.site_id = v_site;
    perform erp.receive_works_order_output(v_wo, 4, null, v_recv);
    select m.id into v_out1 from erp.stock_movement m
     where m.works_order_id = v_wo and m.movement_type = 'production_output' order by m.id desc limit 1;
    select c.value_minor, c.quantity_on_hand into v_val1, v_on1
      from erp.item_cost c where c.item_id = v_fg and c.site_id = v_site;
    perform erp.receive_works_order_output(v_wo, 6, null, v_recv);
    select m.id into v_out2 from erp.stock_movement m
     where m.works_order_id = v_wo and m.movement_type = 'production_output' order by m.id desc limit 1;
    return query select 'each receipt is taken in at three hundred a unit, the order''s standard, where the first was valued at everything spent divided by four',
      (select m.unit_cost_minor = 300 and m.cost_minor = 1200 from erp.stock_movement m where m.id = v_out1)
      and (select m.unit_cost_minor = 300 and m.cost_minor = 1800 from erp.stock_movement m where m.id = v_out2)
      and (select m.works_order_id = v_wo from erp.stock_movement m where m.id = v_issue),
      (select string_agg(format('%s at %s', m.quantity, m.unit_cost_minor), ', ' order by m.id)
         from erp.stock_movement m where m.id in (v_out1, v_out2));

    return query select 'what the movement says it cost is what the valuation recorded',
      coalesce(v_val1, 0) - coalesce(v_val0, 0) = 1200 and coalesce(v_on1, 0) - coalesce(v_on0, 0) = 4,
      format('valuation moved by %s for %s units', coalesce(v_val1, 0) - coalesce(v_val0, 0),
             coalesce(v_on1, 0) - coalesce(v_on0, 0));

    -- 4. The variance, and what the order still holds.
    select sum(v.variance_minor) into v_sum from erp.works_order_variance(v_wo) v;
    v_wip := 1000 + 3000 - 3000;  -- issued, labour booked (30 min at 6000/h), relieved
    return query select 'the variance allows the standard for what was made, and its lines add up to what the order still holds',
      (select v.variance_minor from erp.works_order_variance(v_wo) v where v.kind = 'material') = 0
      and (select v.variance_minor from erp.works_order_variance(v_wo) v where v.kind = 'labour') = 1000
      and (select v.variance_minor from erp.works_order_variance(v_wo) v where v.kind = 'relief') = 0
      and v_sum = v_wip
      and not exists (select 1 from erp.works_order_variance(v_wo) v where v.kind = 'yield'),
      (select string_agg(format('%s %s', v.kind, v.variance_minor), ', ') from erp.works_order_variance(v_wo) v);

    -- 5. Output reversed.
    begin perform public.erp_reverse_works_order_output(v_out2, ' '); v_err := 'reversed';
    exception when others then v_err := left(sqlerrm, 160); end;
    v_back := public.erp_reverse_works_order_output(v_out2, 'Counted twice at the line');
    begin perform public.erp_reverse_works_order_output(v_out2, 'Again'); v_err2 := 'reversed';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    return query select 'finished goods taken in are taken back out with a reason, once, and the order made that much less',
      v_err like 'CLOVEERP_UNDO_NEEDS_A_REASON:%' and v_err2 like 'CLOVEERP_MOVEMENT_ALREADY_REVERSED:%'
      and (select wo.quantity_completed from erp.works_order wo where wo.id = v_wo) = 4
      and (select m.is_reversal and m.reverses_movement_id = v_out2 and m.works_order_id = v_wo
             from erp.stock_movement m where m.id = v_back)
      and (select v.actual_minor from erp.works_order_variance(v_wo) v where v.kind = 'material') = 1000
      and (select v.actual_minor from erp.works_order_variance(v_wo) v where v.kind = 'relief') = 1200
      -- The hundred held before at five hundred, and the four still taken in
      -- at three hundred: nothing of the stock already there moved.
      and (select c.value_minor = 50000 + 1200 and c.quantity_on_hand = 104
             from erp.item_cost c where c.item_id = v_fg and c.site_id = v_site),
      format('%s | %s | %s', v_err, v_err2,
             (select format('%s on hand worth %s', c.quantity_on_hand, c.value_minor)
                from erp.item_cost c where c.item_id = v_fg and c.site_id = v_site));

    -- 6. A component returned.
    v_back := public.erp_return_works_order_issue(v_issue, 'Six too many were issued; wrong count');
    return query select 'a component issued is returned to the shelf once, with the order''s issued quantity and the stock''s value',
      (select c.issued_quantity from erp.works_order_component c where c.works_order_id = v_wo) = 0
      and (select m.is_reversal and m.to_location_id is not null and m.works_order_id = v_wo
             from erp.stock_movement m where m.id = v_back)
      and (select v.actual_minor from erp.works_order_variance(v_wo) v where v.kind = 'material') = 0
      and (select c.quantity_on_hand from erp.item_cost c where c.item_id = v_comp and c.site_id = v_site) = 100,
      (select format('issued %s, on hand %s', c.issued_quantity,
                     (select ic.quantity_on_hand from erp.item_cost ic where ic.item_id = v_comp and ic.site_id = v_site))
         from erp.works_order_component c where c.works_order_id = v_wo);

    -- 7. Hours corrected down, not below nought.
    perform erp.book_operation_time(v_wo, 10, -10, 0, 0);
    begin perform erp.book_operation_time(v_wo, 10, -25, 0, 0); v_err := 'booked';
    exception when others then v_err := left(sqlerrm, 160); end;
    return query select 'hours are taken off by a negative booking, and not past what the operation booked',
      (select o.actual_minutes from erp.works_order_operation o where o.works_order_id = v_wo) = 20
      and v_err like 'CLOVEERP_BOOKING_BELOW_NOUGHT:%',
      v_err;

    -- 8. Nothing on a closed order, nothing that is not the order's.
    perform erp.issue_to_works_order(v_wo, v_comp, 1);
    v_wo2 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo2);
    perform erp.close_works_order(v_wo);
    begin perform public.erp_reverse_works_order_output(v_out1, 'Too late'); v_err := 'reversed';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin perform public.erp_return_works_order_issue(v_out1, 'Not an issue'); v_err2 := 'returned';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    begin perform erp.book_operation_time(v_wo, 10, -5, 0, 0); v_err3 := 'booked';
    exception when others then v_err3 := left(sqlerrm, 160); end;
    return query select 'an order closed is not undone, hours included, and a receipt is not returned as an issue',
      v_err like 'CLOVEERP_WORKS_ORDER_FINISHED:%' and v_err2 like 'CLOVEERP_NOT_A_WORKS_ORDER_MOVEMENT:%'
      and v_err3 like 'CLOVEERP_WORKS_ORDER_FINISHED:%',
      format('%s | %s | %s', v_err, v_err2, v_err3);

    -- 9. The list a person chooses from.
    return query select 'the movements a works order made are listed to choose from, each saying whether it was undone',
      jsonb_array_length(public.erp_works_order_movements(v_wo)) = 4
      and jsonb_array_length(public.erp_works_order_movements(v_wo, 'receipt')) = 1
      and (select count(*) from jsonb_array_elements(public.erp_works_order_movements(v_wo)) e
            where (e ->> 'undone')::boolean) = 2,
      public.erp_works_order_movements(v_wo)::text;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-wov-' || v_hex);
  detail := 'the organisation, its orders and their movements rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.works_order_valuation_suite() from public, anon;

create or replace function erp_test.assert_works_order_valuation_suite()
returns void
language plpgsql
security definer
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
    from erp_test.works_order_valuation_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_WORKS_ORDER_VALUATION_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'Finished goods valued at anything but the standard, a variance that does not add up to what the order holds, or an undo that moves the stock without the valuation, is the case that failed. Read it.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_WORKS_ORDER_VALUATION_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_works_order_valuation_suite() from public, anon;

comment on function erp_test.assert_works_order_valuation_suite() is
  'A works order''s output is taken in at its frozen standard, its variance adds up to '
  'what it holds, and its issues, receipts and hours can be undone, moving the stock, '
  'the valuation and the order together (20260924600000).';

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
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
