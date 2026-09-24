set lock_timeout = '30s';

-- =============================================================================
-- 20260924400000  A works order moves by its transitions
-- -----------------------------------------------------------------------------
-- PR7, M1: node M1 of docs/spec/simplification-review.md, as checked against
-- the built database before this was written.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A works order had no lifecycle. erp.works_order.status is an enum, and the
-- five routines that move an order wrote it straight into the column: no
-- transition code, no permission named on any move, and not one line in the
-- state transition log. erp.lifecycle_column_register() has said so since
-- 20260921440000, and four of the nine side doors
-- erp_test.assert_no_state_side_doors() tolerates were these.
--
-- Two more things came out of reading the bodies:
--
--   * No door cancelled an order. The enum has `cancelled` and nothing ever
--     set it, so an order raised by mistake, or released and then not wanted,
--     sat open for ever, holding its material.
--   * A works order's allocations were written with no reference to the
--     order. erp.close_works_order() then released every committed works
--     order allocation for the same items at the same site — other orders'
--     as well as its own — and erp.works_order_availability()'s "committed
--     elsewhere" excluded the order's own commitment by a document_id that
--     was never set, so it never did.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * The works order's lifecycle, authored as configuration like every other
--     cycle: erp.works_order_lifecycle_item(), object type works_order,
--     installed by erp.configure_production() for a new organisation and
--     offered as version 2 of the production installer to one that has
--     version 1. Every move names the permission the door already asked for.
--   * One routine moves an order, erp.move_works_order(). An order that
--     started a lifecycle moves by its transition, through the engine, and
--     the column follows; one raised before its organisation took the
--     lifecycle moves as it always has. The five movers call it, so the
--     column is written in one place and the tolerance falls from nine to six.
--   * Raising an order starts its lifecycle where one is in force.
--   * erp_cancel_works_order(): an order not yet started is cancelled, with a
--     reason, and what it had committed is released.
--   * A works order's allocations carry the order, closing or cancelling it
--     releases only its own, and the allocations already written are matched
--     to the order that released them.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * The base content pack's document-typed `works_order` machine, and its
--     twenty-one register rows, stay. Nothing starts it and nothing reads it;
--     removing it is a reseed of configuration an organisation may hold,
--     which is the dead-configuration pull request's, as 20260922200000 set
--     out for the transfer order. The new lifecycle has a code of its own,
--     works_order_lifecycle, so the two cannot meet: a promotion upserts a
--     machine by its code and would otherwise have turned that document
--     machine into this one.
--   * Booking time on a closed order is still accepted. production_suite
--     books against one on purpose, and whether hours may follow a close is
--     a settlement question: M2's. An order never released, or cancelled, is
--     refused them now.
--   * erp.assert_every_transition_is_driven() reads document lifecycles
--     only, so it does not see this one. What fires each of its moves is
--     proved by erp_test.works_order_lifecycle_suite instead: every move the
--     lifecycle declares is named by a door that calls erp.move_works_order().
--   * Planning's scheduled supply still leaves works orders out: planning's
--     node, not this one.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_WORKS_ORDER_NOT_CANCELLABLE',
  'Cancelling a works order that has started, or has finished.',
  'Material has been issued to it, finished goods taken in or hours booked, or it is already closed or cancelled. What an order has consumed is accounted for by closing it.',
  'Close the order instead. An order not yet started can be cancelled.');

select erp.register_refusal('CLOVEERP_CANCELLATION_NEEDS_A_REASON',
  'Cancelling a works order without saying why.',
  'A cancelled order leaves the plan and releases its material, and the reason is what somebody reading the order later has to go on.',
  'Say why the order is being cancelled.');

select erp.register_refusal('CLOVEERP_WORKS_ORDER_NOT_RUNNING',
  'Taking out material, taking in finished goods or recording hours on a works order that has not been released, or has been cancelled.',
  'Work is recorded against an order on the floor. An order not yet released has nothing committed for it, and a cancelled one has left the plan.',
  'Release the order first, or record the work against the order it was done for.');

select erp.register_refusal('CLOVEERP_WORKS_ORDER_LIFECYCLE_DISAGREES',
  'Moving a works order whose lifecycle, as configured, arrives somewhere other than the order expects.',
  'The organisation''s works order lifecycle has been changed so that a move ends in a state the order does not have.',
  'Restore the works order lifecycle on the Configuration screen, or ask whoever changed it.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The lifecycle, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.works_order_lifecycle_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The works order's lifecycle (20260924400000), read by
  -- erp.configure_production() for a new install and by the upgrade register
  -- for an organisation on version 1, so the two cannot disagree. The moves
  -- are the ones the doors made before there was a lifecycle, each with the
  -- permission its door already asked for. No screen draws them: each is made
  -- by the door that does the work (erp.move_works_order()).
  select jsonb_build_object('kind','state_machine','key','works_order_lifecycle','payload',
        jsonb_build_object(
          'code','works_order_lifecycle','object_type','works_order','name','Works order',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','released','name','Released','is_committed',true,'sort_order',30),
            jsonb_build_object('code','in_progress','name','In progress','is_committed',true,'sort_order',40),
            jsonb_build_object('code','completed','name','Completed','is_committed',true,'sort_order',50),
            jsonb_build_object('code','closed','name','Closed','is_terminal',true,'is_committed',true,'sort_order',60),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','release','name','Release','from','draft','to','released','required_permission','production.release','sort_order',10),
            jsonb_build_object('code','start','name','Start','from','released','to','in_progress','required_permission','production.execute','sort_order',20),
            jsonb_build_object('code','complete','name','Complete','from','in_progress','to','completed','required_permission','production.execute','sort_order',30),
            jsonb_build_object('code','complete_at_once','name','Complete','from','released','to','completed','required_permission','production.execute','sort_order',31),
            jsonb_build_object('code','close','name','Close','from','completed','to','closed','required_permission','production.release','sort_order',40),
            jsonb_build_object('code','close_short','name','Close','from','in_progress','to','closed','required_permission','production.release','sort_order',41),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','production.release','sort_order',90),
            jsonb_build_object('code','cancel_released','name','Cancel','from','released','to','cancelled','required_permission','production.release','sort_order',91))))
$$;

comment on function erp.works_order_lifecycle_item() is
  'The works order''s lifecycle (20260924400000): the configuration item '
  'erp.configure_production() and the production upgrade register both read.';

do $configure$
declare
  v_sig constant text := 'erp.configure_production(erp.issue_method)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      jsonb_build_object('kind','config','key','production.issue_method','payload',
$o$;
  v_new constant text := $n$      -- The lifecycle (20260924400000), from its one helper.
      erp.works_order_lifecycle_item(),
      jsonb_build_object('kind','config','key','production.issue_method','payload',
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % issue method item found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The upgrade register: version 2 for an organisation on version 1
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 2,
       description = description
         || ' Version 2 (20260924400000): a works order moves by a lifecycle, with a '
         || 'permission on every move and a line in the history for each.'
 where install_code = 'production' and current_version = 1;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'production', 2, 'state_machine', 'works_order_lifecycle',
       (erp.works_order_lifecycle_item() -> 'payload') - 'entity', 100
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'production') is distinct from 2 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the production installer is not at version 2';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'production' and ui.to_version = 2
         and ui.object_kind = 'state_machine' and ui.object_key = 'works_order_lifecycle'
         and ui.payload = (erp.works_order_lifecycle_item() -> 'payload') - 'entity') <> 1
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'production' and ui.to_version = 2) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 2 of production is not the one item it ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. One routine moves an order
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.move_works_order(
  p_works_order_id uuid,
  p_transition_code text,
  p_to erp.works_order_status,
  p_reason text default null)
returns erp.works_order_status
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_to     text;
begin
  -- An order that started a lifecycle moves by its transition: the engine
  -- looks the move up in the version the order started under, asks for its
  -- permission and writes the history. The column follows it, so everything
  -- that reads the status reads the same answer.
  if exists (select 1 from erp.object_state os
              where os.tenant_id = v_tenant and os.object_type = 'works_order'
                and os.object_id = p_works_order_id) then
    v_to := erp.perform_transition('works_order', p_works_order_id, p_transition_code,
                                   '{}'::jsonb, p_reason);
    if v_to is distinct from p_to::text then
      raise exception 'CLOVEERP_WORKS_ORDER_LIFECYCLE_DISAGREES: % moved the order to %, where it should be %',
        p_transition_code, v_to, p_to
        using errcode = '23514',
              hint = 'Restore the works order lifecycle on the Configuration screen, or ask whoever changed it.';
    end if;
  end if;

  -- An order raised before its organisation took the lifecycle has none, and
  -- moves as it always has: its door has already asked for the permission.
  update erp.works_order
     set status = p_to, updated_at = now()
   where tenant_id = v_tenant and id = p_works_order_id;

  return p_to;
end;
$$;

revoke all on function erp.move_works_order(uuid, text, erp.works_order_status, text) from public, anon;

comment on function erp.move_works_order(uuid, text, erp.works_order_status, text) is
  'The one place a works order''s status is written (20260924400000): by its '
  'transition where the order started a lifecycle, and as before where it did not. '
  'Called by the doors that do the work, after they have authorised it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The doors move the order through it
-- ─────────────────────────────────────────────────────────────────────────────

-- Raising starts the lifecycle where one is in force. Where none is — an
-- organisation still on version 1 of production — the order is raised as it
-- always was, and moves by its column.
do $raise$
declare
  v_sig constant text := 'erp.raise_works_order(uuid,uuid,numeric,erp.works_order_kind,date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if v_rout.id is not null then
    insert into erp.works_order_operation ($o$;
  v_new constant text := $n$  begin
    perform erp.start_lifecycle('works_order', v_wo, v_entity, p_site_id,
                                p_machine_code => null::text);
  exception when foreign_key_violation then
    -- Only an organisation with no works order lifecycle at all raises an
    -- order without one. One that has a lifecycle and none in force here —
    -- expired, withdrawn, or for another site — is told so, rather than
    -- raising an order that moves with no permission and no history.
    if sqlerrm not like 'CLOVEERP_NO_LIFECYCLE:%'
       or exists (select 1 from erp.state_machine sm
                   where sm.tenant_id = v_tenant and sm.object_type = 'works_order') then
      raise;
    end if;
  end;

  if v_rout.id is not null then
    insert into erp.works_order_operation ($n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % routing anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$raise$;

-- Release: the allocations carry the order, and the move is the lifecycle's.
do $release$
declare
  v_sig constant text := 'erp.release_works_order(uuid,boolean)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$    insert into erp.allocation (
      tenant_id, entity_id, site_id, item_id, demand_kind, quantity, uom_id,
      status, required_by)
    values (v_tenant, wo.entity_id, wo.site_id, r.item_id, 'works_order',
            r.required_quantity - r.issued_quantity, r.uom_id, 'committed',
            wo.planned_end);$o$;
  v_new1 constant text := $n$    -- Against the order (20260924400000), so closing it releases its own
    -- commitment and nobody else's, and its availability can leave it out.
    -- Nothing is committed for a component already issued in full.
    if r.required_quantity - r.issued_quantity > 0 then
      insert into erp.allocation (
        tenant_id, entity_id, site_id, item_id, document_id, demand_kind, quantity, uom_id,
        status, required_by)
      values (v_tenant, wo.entity_id, wo.site_id, r.item_id, p_works_order_id, 'works_order',
              r.required_quantity - r.issued_quantity, r.uom_id, 'committed',
              wo.planned_end);
    end if;$n$;
  v_old2 constant text := $o$  update erp.works_order
     set status = 'released', standard_cost_minor = v_std, updated_at = now()
   where id = p_works_order_id;$o$;
  v_new2 constant text := $n$  update erp.works_order
     set standard_cost_minor = v_std, updated_at = now()
   where id = p_works_order_id;

  perform erp.move_works_order(p_works_order_id, 'release', 'released');$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % allocation anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % status anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$release$;

-- Issue: the first issue starts the order.
do $issue$
declare
  v_sig constant text := 'erp.issue_to_works_order(uuid,uuid,numeric,uuid,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  update erp.works_order
     set status = case when status = 'released'
                       then 'in_progress'::erp.works_order_status else status end,
         actual_start = coalesce(actual_start, now()),
         updated_at = now()
   where id = p_works_order_id;$o$;
  v_new constant text := $n$  update erp.works_order
     set actual_start = coalesce(actual_start, now()),
         updated_at = now()
   where id = p_works_order_id;

  if wo.status = 'released' then
    perform erp.move_works_order(p_works_order_id, 'start', 'in_progress');
  end if;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % status anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$issue$;

-- Receipt: a part starts the order, the rest completes it. The status is read
-- again here, because a backflush above has issued the components and may
-- already have started the order.
do $receive$
declare
  v_sig constant text := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  update erp.works_order
     set quantity_completed = quantity_completed + p_quantity,
         output_batch_id = coalesce(output_batch_id, v_batch),
         actual_cost_minor = v_issued + v_labour,
         status = case when quantity_completed + p_quantity >= quantity
                       then 'completed'::erp.works_order_status
                       else 'in_progress'::erp.works_order_status end,
         actual_end = case when quantity_completed + p_quantity >= quantity
                           then now() end,
         updated_at = now()
   where id = p_works_order_id;$o$;
  v_new constant text := $n$  update erp.works_order
     set quantity_completed = quantity_completed + p_quantity,
         output_batch_id = coalesce(output_batch_id, v_batch),
         actual_cost_minor = v_issued + v_labour,
         actual_end = case when quantity_completed + p_quantity >= quantity
                           then now() end,
         updated_at = now()
   where id = p_works_order_id
   returning status, quantity_completed >= quantity into wo.status, v_done;

  if v_done then
    perform erp.move_works_order(p_works_order_id,
      case when wo.status = 'released' then 'complete_at_once' else 'complete' end,
      'completed');
  elsif wo.status = 'released' then
    perform erp.move_works_order(p_works_order_id, 'start', 'in_progress');
  end if;$n$;
  v_old_decl constant text := $o$  v_labour  bigint;
$o$;
  v_new_decl constant text := $n$  v_labour  bigint;
  v_done    boolean;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % status anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_decl, ''))) / length(v_old_decl);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % declaration anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old, v_new), v_old_decl, v_new_decl);
end
$receive$;

-- Close: only the order's own commitment is released, and the move is the
-- lifecycle's.
do $close$
declare
  v_sig constant text := 'erp.close_works_order(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  update erp.allocation
     set status = 'released', updated_at = now()
   where tenant_id = v_tenant and site_id = wo.site_id
     and demand_kind = 'works_order' and status = 'committed'
     and item_id in (select c.item_id from erp.works_order_component c
                      where c.works_order_id = p_works_order_id);$o$;
  v_new1 constant text := $n$  -- Its own, and nobody else's (20260924400000). Every other order's
  -- commitment for the same items at the same site went with it before.
  -- An order raised before the lifecycle may still hold a commitment written
  -- without it that could not be matched to it, and that is released as it
  -- always was.
  update erp.allocation
     set status = 'released', updated_at = now()
   where tenant_id = v_tenant and demand_kind = 'works_order' and status = 'committed'
     and (document_id = p_works_order_id
          or (document_id is null and site_id = wo.site_id
              and not exists (select 1 from erp.object_state os
                               where os.tenant_id = v_tenant and os.object_type = 'works_order'
                                 and os.object_id = p_works_order_id)
              and item_id in (select c.item_id from erp.works_order_component c
                               where c.works_order_id = p_works_order_id)));$n$;
  v_old2 constant text := $o$  update erp.works_order set status = 'closed', updated_at = now()
   where id = p_works_order_id;$o$;
  v_new2 constant text := $n$  perform erp.move_works_order(p_works_order_id,
    case when wo.status = 'completed' then 'close' else 'close_short' end, 'closed');$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % allocation anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % status anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$close$;

-- Hours are recorded on an order on the floor (20260924400000). Not on one
-- never released, nor one cancelled, which this pull request makes possible:
-- a cancelled order is one nobody worked on. After a close they are still
-- accepted, as they were, until settlement decides whether they may be (M2).
do $book$
declare
  v_sig constant text := 'erp.book_operation_time(uuid,integer,numeric,numeric,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- Time is booked where the routing says to book it (20260922220000).$o$;
  v_new constant text := $n$  if wo.status in ('draft', 'planned', 'cancelled') then
    raise exception 'CLOVEERP_WORKS_ORDER_NOT_RUNNING: % is %, and hours are recorded on an order on the floor',
      wo.order_number, wo.status
      using errcode = '23514',
            hint = 'Release the order first, or record the work against the order it was done for.';
  end if;

  -- Time is booked where the routing says to book it (20260922220000).$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % routing anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$book$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. An order not yet started can be cancelled
-- ─────────────────────────────────────────────────────────────────────────────

-- The batch record says an order was cancelled, and why, as it says
-- everything else that happened to it.
alter table erp.production_event drop constraint if exists production_event_event_kind_check;
alter table erp.production_event add constraint production_event_event_kind_check
  check (event_kind = any (array['released', 'started', 'issued', 'completed', 'scrapped',
                                 'time_booked', 'deviation', 'output_received', 'closed',
                                 'cancelled']));

create or replace function erp.cancel_works_order(p_works_order_id uuid, p_reason text)
returns erp.works_order_status
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  wo       erp.works_order%rowtype;
  v_released integer;
begin
  select * into wo from erp.works_order
   where tenant_id = v_tenant and id = p_works_order_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_WORKS_ORDER: %', p_works_order_id using errcode = '23503';
  end if;

  perform erp.authorise('production.release', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'CLOVEERP_CANCELLATION_NEEDS_A_REASON: say why % is being cancelled', wo.order_number
      using errcode = '22023', hint = 'Say why the order is being cancelled.';
  end if;

  -- Not started: nothing issued, nothing taken in and no hours booked. An
  -- order that has consumed anything is accounted for by closing it.
  if wo.status not in ('draft', 'planned', 'released')
     or wo.quantity_completed > 0 or wo.quantity_scrapped > 0
     or exists (select 1 from erp.works_order_component c
                 where c.tenant_id = v_tenant and c.works_order_id = p_works_order_id
                   and c.issued_quantity > 0)
     or exists (select 1 from erp.works_order_operation o
                 where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id
                   and (o.actual_minutes > 0 or o.quantity_completed > 0 or o.quantity_scrapped > 0))
  then
    raise exception 'CLOVEERP_WORKS_ORDER_NOT_CANCELLABLE: % is %, and has been worked on or has finished',
      wo.order_number, wo.status
      using errcode = '23514',
            hint = 'Close the order instead. An order not yet started can be cancelled.';
  end if;

  -- Its own commitment, and, for an order raised before the lifecycle, one
  -- written without a reference that could not be matched to it, as close
  -- releases them.
  update erp.allocation
     set status = 'released', updated_at = now()
   where tenant_id = v_tenant and demand_kind = 'works_order' and status = 'committed'
     and (document_id = p_works_order_id
          or (document_id is null and site_id = wo.site_id
              and not exists (select 1 from erp.object_state os
                               where os.tenant_id = v_tenant and os.object_type = 'works_order'
                                 and os.object_id = p_works_order_id)
              and item_id in (select c.item_id from erp.works_order_component c
                               where c.tenant_id = v_tenant and c.works_order_id = p_works_order_id)));
  get diagnostics v_released = row_count;

  perform erp.move_works_order(p_works_order_id,
    case when wo.status = 'released' then 'cancel_released' else 'cancel' end,
    'cancelled', btrim(p_reason));

  insert into erp.production_event (
    tenant_id, works_order_id, event_kind, detail, actor_id)
  values (v_tenant, p_works_order_id, 'cancelled',
          jsonb_build_object('reason', btrim(p_reason), 'allocations_released', v_released,
                             'from', wo.status::text),
          erp.current_principal_id());

  return 'cancelled'::erp.works_order_status;
end;
$$;

revoke all on function erp.cancel_works_order(uuid, text) from public, anon;

comment on function erp.cancel_works_order(uuid, text) is
  'Cancels a works order nobody has started, with a reason, and releases what it '
  'had committed (20260924400000). Authorises production.release.';

create or replace function public.erp_cancel_works_order(p_works_order_id uuid, p_reason text)
returns text
language sql
set search_path = ''
as $$
  select erp.cancel_works_order(p_works_order_id, p_reason)::text
$$;

revoke all on function public.erp_cancel_works_order(uuid, text) from public, anon;
grant execute on function public.erp_cancel_works_order(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_cancel_works_order', 'erp.cancel_works_order',
   'Cancels a works order nobody has started, with a reason, and releases its committed material; authorises production.release.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/production', array['erp_cancel_works_order']);

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. The allocations already written find their order
--
-- Written by erp.release_works_order() in the transaction that recorded the
-- order's `released` event, so they share its created_at, its site, one of
-- its components, that component's quantity and its planned finish. Where two
-- orders released together
-- match the same allocations they are interchangeable, and are shared out
-- one to one.
-- ─────────────────────────────────────────────────────────────────────────────

-- Each side is numbered within what cannot tell its rows apart — the
-- organisation, site, item, quantity, planned finish and the transaction —
-- and the two are paired by number, so every allocation goes to exactly one
-- component of one order and none is left over where the counts agree.
with alloc as (
  select a.id, a.tenant_id, a.site_id, a.item_id, a.quantity, a.required_by, a.created_at,
         row_number() over (partition by a.tenant_id, a.site_id, a.item_id, a.quantity,
                                         a.required_by, a.created_at
                            order by a.id) as n
    from erp.allocation a
   where a.demand_kind = 'works_order' and a.document_id is null
),
component as (
  select wo.id as works_order_id, wo.tenant_id, wo.site_id, c.item_id,
         c.required_quantity as quantity, wo.planned_end as required_by, pe.created_at,
         row_number() over (partition by wo.tenant_id, wo.site_id, c.item_id, c.required_quantity,
                                         wo.planned_end, pe.created_at
                            order by wo.id, c.seq, c.id) as n
    from erp.works_order wo
    join erp.production_event pe
      on pe.tenant_id = wo.tenant_id and pe.works_order_id = wo.id and pe.event_kind = 'released'
    join erp.works_order_component c
      on c.tenant_id = wo.tenant_id and c.works_order_id = wo.id
   -- Nothing can be issued before a release, so what was committed was what
   -- the component required, and a component issued in full committed nothing.
   where c.required_quantity > 0
)
update erp.allocation a
   set document_id = c.works_order_id
  from alloc x
  join component c
    on c.tenant_id = x.tenant_id and c.site_id = x.site_id and c.item_id = x.item_id
   and c.quantity = x.quantity and c.required_by is not distinct from x.required_by
   and c.created_at = x.created_at and c.n = x.n
 where a.id = x.id;

-- Whatever is left could not be matched. Close and cancel go on releasing it
-- as they always did for an order raised before the lifecycle (A5, A6), so
-- nothing is committed for ever; the count is said here so a deploy log shows
-- it.
do $left$
declare v_n integer;
begin
  select count(*) into v_n from erp.allocation a
   where a.demand_kind = 'works_order' and a.document_id is null and a.status = 'committed';
  raise notice 'works order allocations committed and not matched to an order: %', v_n;
end
$left$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The demonstration takes version 2 of production in its catch-up
--
-- As the sales lifecycle's newer version is taken (20260923800000): in a block
-- of its own, before the trading, a refusal a note. Orders it raised before
-- keep moving by their column; the ones it raises from here have a lifecycle.
-- ─────────────────────────────────────────────────────────────────────────────

do $catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- ── Trading, up to the day this runs or the time this statement has ────────
$o$;
  v_new constant text := $n$  -- ── Production's newer version (20260924400000) ───────────────────────────
  begin
    if exists (select 1 from erp.module_installation i
                where i.tenant_id = v_tenant and i.install_code = 'production') then
      if exists (select 1 from erp.plan_module_upgrade('production')) then
        perform erp.upgrade_module_configuration('production');
        v_notes := v_notes || to_jsonb(format(
          'Production was upgraded to version %s.',
          (select mi.current_version from erp_ref.module_installer mi
            where mi.install_code = 'production')));
      end if;
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'Production was not upgraded, so its works orders move as they did: %s', sqlerrm));
  end;

  -- ── Trading, up to the day this runs or the time this statement has ────────
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % trading anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$catch_up$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The register says what is left, and the line comes down to it
--
-- A works order is still in the register: an order raised before its
-- organisation took the lifecycle has none, and erp.move_works_order() writes
-- its column as the doors did. It is the only routine that does, so three of
-- the four findings it had are gone and the tolerance follows them down.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.lifecycle_column_register()
 returns jsonb
 language sql
 immutable
 set search_path to ''
as $function$
  select jsonb_agg(jsonb_build_object(
           'schema_name', x.schema_name, 'table_name', x.table_name,
           'column_name', x.column_name, 'detail', x.detail))
    from (values
      ('erp', 'works_order', 'status',
       'A works order moves by its lifecycle since 20260924400000, and the column follows it. Its one writer is erp.move_works_order(), which also moves an order raised before its organisation took the lifecycle, by the column, as every order moved before. The row goes when no organisation is left on version 1 of production.'),
      ('erp', 'planned_order', 'status',
       'The same shape as a works order, and carrying two states — reviewed and firmed — that node M7 removes as dead. Its moves belong on the spine with the rest.'),
      ('erp', 'count_task', 'status',
       'The base type count exists in reference data and no installer ever makes a document type from it, so a count has no number, no lifecycle and no authorisation, and its status is a column somebody sets. Node I1 installs it.')
    ) as x(schema_name, table_name, column_name, detail)
$function$;

update erp_meta.enforcement_gate
   set tolerated_findings = 6,
       rationale = rationale
         || ' Six from 20260924400000: the works order''s four writers are one, erp.move_works_order().'
 where gate = 'no_state_side_doors' and tolerated_findings = 9;

do $gate$
begin
  if (select tolerated_findings from erp_meta.enforcement_gate
       where gate = 'no_state_side_doors') is distinct from 6 then
    raise exception 'CLOVEERP_ENFORCEMENT_GATE_UNMOVED: no_state_side_doors does not tolerate six';
  end if;
end
$gate$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. The proof: erp_test.works_order_lifecycle_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.works_order_lifecycle_suite()
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
  csf uuid; csp uuid; csi uuid; csr uuid; v_rout uuid;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid;
  v_fg uuid; v_comp uuid; v_bom uuid; v_grn uuid;
  v_wo uuid; v_wo2 uuid; v_wo3 uuid; v_wo4 uuid; v_old uuid;
  v_log text; v_status text; v_state text;
  v_err text; v_err2 text; v_err3 text;
  v_n integer;
begin
  -- 1. Every move the lifecycle declares is made by a door: a routine that
  --    moves the order through erp.move_works_order() names it.
  return query select 'every move the works order lifecycle declares is made by a door',
    not exists (
      select 1
        from jsonb_array_elements(erp.works_order_lifecycle_item() #> '{payload,transitions}') t
       where not exists (
         select 1 from pg_catalog.pg_proc p
          join pg_catalog.pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'erp' and p.proname <> 'works_order_lifecycle_item'
           and p.prosrc ~ 'erp\.move_works_order\('
           and strpos(p.prosrc, '''' || (t.value ->> 'code') || '''') > 0)),
    (select string_agg(t.value ->> 'code', ', ')
       from jsonb_array_elements(erp.works_order_lifecycle_item() #> '{payload,transitions}') t);

  -- The lifecycle an installer ships is the one the upgrade offers.
  return query select 'a new organisation and an upgraded one are given the same works order lifecycle',
    (select count(*) from erp_ref.module_upgrade_item ui
      where ui.install_code = 'production' and ui.object_key = 'works_order_lifecycle'
        and ui.payload = (erp.works_order_lifecycle_item() -> 'payload') - 'entity') = 1,
    'the upgrade item is the helper''s payload';

  begin
    select * into r from erp.provision_tenant(
      'zz-wol-' || v_hex, 'Works order lifecycle suite',
      'a@zz-wol-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-wol-' || v_hex || '.test', 'Second Admin');
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
    values (r.tenant_id, v_bom, 10, v_comp, 2, v_uom, 0, false);
    insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
    values (r.tenant_id, 'FG-R1', v_fg, v_site, 1, 'Assemble', 'active', current_date - 1)
    returning id into v_rout;
    insert into erp.routing_operation (
      tenant_id, routing_id, seq, code, name, work_centre_code,
      setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
    values (r.tenant_id, v_rout, 10, 'ASM', 'Assembly', 'WC1', 10, 1, 6000);

    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 1000, 100, 'component');
    perform erp.transition_document(v_grn, 'post');

    -- 2. Raising starts the lifecycle.
    v_wo := erp.raise_works_order(v_fg, v_site, 10);
    return query select 'raising a works order starts its lifecycle at draft',
      erp.object_current_state('works_order', v_wo) = 'draft'
      and exists (select 1 from erp.state_transition_log l
                   where l.object_type = 'works_order' and l.object_id = v_wo
                     and l.to_state_code = 'draft'),
      coalesce(erp.object_current_state('works_order', v_wo), 'no lifecycle');

    -- 3. Releasing is the lifecycle's move, and commits against the order.
    perform erp.release_works_order(v_wo);
    v_wo2 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo2);
    return query select 'releasing is the lifecycle''s release, and the column follows it',
      erp.object_current_state('works_order', v_wo) = 'released'
      and (select wo.status::text from erp.works_order wo where wo.id = v_wo) = 'released'
      and exists (select 1 from erp.state_transition_log l
                   where l.object_type = 'works_order' and l.object_id = v_wo
                     and l.transition_code = 'release'),
      format('lifecycle %s, column %s', erp.object_current_state('works_order', v_wo),
             (select wo.status from erp.works_order wo where wo.id = v_wo));

    return query select 'what a release commits carries the order, and its availability leaves its own commitment out',
      (select count(*) from erp.allocation a
        where a.tenant_id = r.tenant_id and a.document_id = v_wo and a.status = 'committed') = 1
      and (select a.committed_elsewhere from erp.works_order_availability(v_wo) a) = 10,
      format('%s committed against it, %s committed elsewhere',
             (select count(*) from erp.allocation a
               where a.tenant_id = r.tenant_id and a.document_id = v_wo and a.status = 'committed'),
             (select a.committed_elsewhere from erp.works_order_availability(v_wo) a));

    -- 4. The first issue starts it, the last receipt completes it.
    perform erp.issue_to_works_order(v_wo, v_comp, 20);
    v_state := erp.object_current_state('works_order', v_wo);
    perform erp.receive_works_order_output(v_wo, 10, null, v_recv);
    return query select 'the first issue starts the order and taking in all of it completes it',
      v_state = 'in_progress'
      and erp.object_current_state('works_order', v_wo) = 'completed'
      and (select wo.status::text from erp.works_order wo where wo.id = v_wo) = 'completed'
      and (select string_agg(l.transition_code, ',' order by l.occurred_at, l.id)
             from erp.state_transition_log l
            where l.object_type = 'works_order' and l.object_id = v_wo
              and l.transition_code is not null) = 'release,start,complete',
      (select string_agg(l.transition_code, ',' order by l.occurred_at, l.id)
         from erp.state_transition_log l
        where l.object_type = 'works_order' and l.object_id = v_wo);

    -- 5. Closing releases its own commitment and nobody else's.
    perform erp.close_works_order(v_wo);
    return query select 'closing an order releases its own commitment and leaves another order''s alone',
      erp.object_current_state('works_order', v_wo) = 'closed'
      and not exists (select 1 from erp.allocation a
                       where a.tenant_id = r.tenant_id and a.document_id = v_wo and a.status = 'committed')
      and exists (select 1 from erp.allocation a
                   where a.tenant_id = r.tenant_id and a.document_id = v_wo2 and a.status = 'committed'),
      format('the other order holds %s committed',
             (select count(*) from erp.allocation a
               where a.tenant_id = r.tenant_id and a.document_id = v_wo2 and a.status = 'committed'));

    -- 6. Cancelling: an order not started, with a reason.
    begin
      perform public.erp_cancel_works_order(v_wo2, '  ');
      v_err := 'cancelled';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform public.erp_cancel_works_order(v_wo2, 'The customer withdrew the order');
    v_wo3 := erp.raise_works_order(v_fg, v_site, 3);
    perform public.erp_cancel_works_order(v_wo3, 'Raised twice by mistake');
    return query select 'an order not started is cancelled, with a reason, and what it committed is released',
      v_err like 'CLOVEERP_CANCELLATION_NEEDS_A_REASON:%'
      and erp.object_current_state('works_order', v_wo2) = 'cancelled'
      and (select wo.status::text from erp.works_order wo where wo.id = v_wo2) = 'cancelled'
      and not exists (select 1 from erp.allocation a
                       where a.tenant_id = r.tenant_id and a.document_id = v_wo2 and a.status = 'committed')
      and exists (select 1 from erp.state_transition_log l
                   where l.object_type = 'works_order' and l.object_id = v_wo2
                     and l.transition_code = 'cancel_released'
                     and l.reason = 'The customer withdrew the order')
      and erp.object_current_state('works_order', v_wo3) = 'cancelled',
      format('%s | %s, %s', v_err, erp.object_current_state('works_order', v_wo2),
             erp.object_current_state('works_order', v_wo3));

    v_wo4 := erp.raise_works_order(v_fg, v_site, 4);
    perform erp.release_works_order(v_wo4);
    perform erp.book_operation_time(v_wo4, 10, 30, 0, 0);
    begin
      perform public.erp_cancel_works_order(v_wo4, 'Not wanted');
      v_err2 := 'cancelled';
    exception when others then v_err2 := left(sqlerrm, 200); end;
    begin
      perform public.erp_cancel_works_order(v_wo, 'Not wanted');
      v_err3 := 'cancelled';
    exception when others then v_err3 := left(sqlerrm, 200); end;
    return query select 'an order with hours booked, or one closed, is refused and is closed instead',
      v_err2 like 'CLOVEERP_WORKS_ORDER_NOT_CANCELLABLE:%'
      and v_err3 like 'CLOVEERP_WORKS_ORDER_NOT_CANCELLABLE:%'
      and erp.object_current_state('works_order', v_wo4) = 'released',
      format('%s | %s', v_err2, v_err3);

    begin
      perform erp.book_operation_time(v_wo2, 10, 15, 0, 0);
      v_err := 'booked';
    exception when others then v_err := left(sqlerrm, 200); end;
    return query select 'a cancelled order is refused hours, as nobody worked on it',
      v_err like 'CLOVEERP_WORKS_ORDER_NOT_RUNNING:%'
      and (select coalesce(sum(o.actual_minutes), 0) from erp.works_order_operation o
            where o.works_order_id = v_wo2) = 0,
      v_err;

    -- 7. An order raised with no lifecycle in force moves as it always has.
    --    Such an order is one raised with no lifecycle instance, which is
    --    what taking its instance away leaves.
    v_old := erp.raise_works_order(v_fg, v_site, 2);
    delete from erp.object_state os
     where os.tenant_id = r.tenant_id and os.object_type = 'works_order' and os.object_id = v_old;
    perform erp.release_works_order(v_old);
    perform erp.issue_to_works_order(v_old, v_comp, 4);
    perform erp.receive_works_order_output(v_old, 2, null, v_recv);
    perform erp.close_works_order(v_old);
    return query select 'an order raised before its organisation took the lifecycle still moves, by its column',
      not exists (select 1 from erp.object_state os
                   where os.object_type = 'works_order' and os.object_id = v_old)
      and (select wo.status::text from erp.works_order wo where wo.id = v_old) = 'closed',
      (select wo.status::text from erp.works_order wo where wo.id = v_old);

    -- 8. Every order with a lifecycle says what its column says.
    select count(*) into v_n
      from erp.works_order wo
      join erp.object_state os
        on os.tenant_id = wo.tenant_id and os.object_type = 'works_order' and os.object_id = wo.id
      join erp.state s on s.id = os.current_state_id
     where wo.tenant_id = r.tenant_id and s.code <> wo.status::text;
    return query select 'every works order''s lifecycle and its column agree',
      v_n = 0 and (select count(*) from erp.object_state os
                    where os.tenant_id = r.tenant_id and os.object_type = 'works_order') = 4,
      format('%s disagree', v_n);

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
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-wol-' || v_hex);
  detail := 'the organisation, its orders and their lifecycles rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.works_order_lifecycle_suite() from public, anon;

create or replace function erp_test.assert_works_order_lifecycle_suite()
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
    from erp_test.works_order_lifecycle_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_WORKS_ORDER_LIFECYCLE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A works order that moves past its lifecycle has no permission on the move and no history of it. Read the case that failed.';
  end if;
  if v_total <> 13 then
    raise exception 'CLOVEERP_WORKS_ORDER_LIFECYCLE_SUITE_SHRANK: % case(s), expected 13', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_works_order_lifecycle_suite() from public, anon;

comment on function erp_test.assert_works_order_lifecycle_suite() is
  'A works order moves by its lifecycle where it has one and by its column where it '
  'was raised before, cancels only unstarted, and releases only its own commitment '
  '(20260924400000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B4. The words the screen says for it
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A works order cancelled from the desk (20260924400000).'
  from (values
    ('Cancel a works order'),
    ('For an order nobody has started: nothing taken out, nothing taken in and no hours recorded. What it had set aside is released. An order that has started is closed instead.'),
    ('Why it is cancelled')
  ) as v(text)
on conflict (key, locale) do nothing;

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
